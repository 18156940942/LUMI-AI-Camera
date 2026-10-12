#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI 相机桥接（Windows / Nikon MTP）
====================================

把插在电脑上的尼康相机（Z6 II 等）当成一个可以**程序化读取**的照片源：
列出相机里的照片、下载到本地文件夹、供 App 那边收集成库。

它走的是 **Windows 自带的 WPD（Windows Portable Devices）API** ——
也就是资源管理器能浏览相机照片所走的那条官方路径。**不需要装任何驱动、不需要
替换系统驱动、不需要装尼康的软件。**

为什么是这个方案
----------------
相机在 MTP/PTP 模式下，Windows 会把它枚举成一个 WPD 便携设备（而不是 U 盘）。
访问它只有两条路：

  1. **WPD API**（本脚本走的路）—— 官方、稳定、只读、不影响资源管理器。
  2. **原始 USB + 自己发 PTP 命令** —— 这才是「解析相机协议」。
     代价是必须用 Zadig 把微软的相机驱动换成 WinUSB，**换完资源管理器就
     再也看不到相机里的照片了**，而且尼康的厂商私有命令没有公开文档。

第二条路只在一种情况下才值得走：需要**实时取景**（把相机屏幕的画面实时读出来）。
WPD 拿不到实时取景 —— 那是 PTP 厂商私有命令。想做实时取景，正确做法是用
**尼康官方的 Webcam Utility**（免费）把相机变成普通 USB 摄像头，
再交给 `tools/lumi_mjpeg_server.py` 推给手机，**完全不用碰驱动**。

这个脚本能做什么、不能做什么
----------------------------
能：列出相机里的照片 / 下载单张 / 批量下载新照片 / 持续监视（轮询）并自动下载。
不能：实时取景、遥控拍摄、改相机设置。

用法
----
    # 看相机里有什么
    python tools/lumi_camera_bridge.py --list

    # 把相机里全部照片下载到某个文件夹
    python tools/lumi_camera_bridge.py --download-all D:\\相机导入

    # 持续监视：每 5 秒看一次，有新照片就下载（这就是「自动导入」的来源）
    python tools/lumi_camera_bridge.py --watch D:\\相机导入 --interval 5

依赖
----
    pip install comtypes

（comtypes 用来调 WPD 的 COM 接口。它是纯 Python 侧的 COM 绑定，Windows 上装得上。）
"""

from __future__ import annotations

import argparse
import ctypes
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Optional

# ---------------------------------------------------------------------------
# 依赖
# ---------------------------------------------------------------------------

if sys.platform != "win32":
    print("这个脚本只能在 Windows 上运行 —— 它用的是 Windows 的 WPD API。", file=sys.stderr)
    raise SystemExit(2)

try:
    import comtypes
    from comtypes import GUID, CoCreateInstance
    from comtypes.client import GetModule
except ImportError:  # pragma: no cover
    print("缺少 comtypes。请先安装：\n    pip install comtypes", file=sys.stderr)
    raise SystemExit(2)


# ---------------------------------------------------------------------------
# WPD 常量
# ---------------------------------------------------------------------------

CLSID_PORTABLE_DEVICE = GUID("{728A21C5-3D9E-48D7-9810-864848F0F404}")
CLSID_DEVICE_VALUES = GUID("{0C15D503-D017-47CE-9016-7B3F978721CC}")
# 注意：这个 CLSID **不是** WPD 头文件里 PortableDeviceKeyCollection 的 coclass GUID
# （那个是 DADA2357-E0AD-492E-98DB-DD61C53BA353，在实机上「没有注册类」）。
# 真正注册的是下面这个 —— 从 HKLM\SOFTWARE\Classes\CLSID 里查出来的。
CLSID_KEY_COLLECTION = GUID("{DE2D022D-2480-43BE-97F0-D1FA2CF98F4F}")

# WPD 客户端信息键（WPD_CLIENT_* 的 fmtid 相同，靠 pid 区分）
FMTID_CLIENT = GUID("{204D9F0C-2292-4080-9F42-40664E70F859}")

# 设备接口 GUID：WPD 设备 ID 以它结尾
WPD_DEVICE_INTERFACE = GUID("{6AC27878-A6FA-4155-BA85-F98F491D4F33}")

# 对象属性键（WPD_OBJECT_*）
FMTID_OBJECT = GUID("{EF6B490D-5CD8-437A-AFFC-DA8B60EE4A3C}")
KEY_NAME = (FMTID_OBJECT, 4)          # WPD_OBJECT_NAME
KEY_PERSISTENT_ID = (FMTID_OBJECT, 5)  # WPD_OBJECT_PERSISTENT_UNIQUE_ID
KEY_PARENT = (FMTID_OBJECT, 3)         # WPD_OBJECT_PARENT_ID
KEY_CONTENT_TYPE = (FMTID_OBJECT, 7)   # WPD_OBJECT_CONTENT_TYPE
KEY_SIZE = (FMTID_OBJECT, 11)          # WPD_OBJECT_SIZE
KEY_ORIGINAL_NAME = (FMTID_OBJECT, 12)  # WPD_OBJECT_ORIGINAL_FILE_NAME
KEY_DATE_CREATED = (FMTID_OBJECT, 18)  # WPD_OBJECT_DATE_CREATED

# 默认资源（照片的字节流）
KEY_RESOURCE_DEFAULT = (GUID("{E81E79BE-34F0-41BF-B53F-F1A06AE87842}"), 0)

# WPD 的根对象 ID 是字面量 "DEVICE"，不是 NULL —— 传 NULL 会得到「无效指针」
ROOT_OBJECT_ID = "DEVICE"

# 内容类型 GUID（WPD_CONTENT_TYPE_*）。
#
# **必须同时认两种「文件夹」**：根存储是 FUNCTIONAL_OBJECT，而 DCIM 这类目录是
# FOLDER。只判 FUNCTIONAL_OBJECT 的话，DCIM 会被当成文件、遍历根本下不去 ——
# 实测踩过这个坑：遍历只走到「可移动存储 / DCIM」两层就停了，看着像相机里没照片。
GUID_FUNCTIONAL_OBJECT = GUID("{99ED0160-17FF-4C44-9D98-1D7A6F941921}")
GUID_FOLDER = GUID("{27E2E392-A111-48E0-AB0C-E17705A05F85}")
GUID_IMAGE = GUID("{ef2107d5-a52a-4243-a26b-52e3c6d1c90b}")
GUID_VIDEO = GUID("{9261e34d-0fc3-4233-8be5-e7c1c1ea8c96}")

FOLDER_CONTENT_TYPES = {
    str(GUID_FUNCTIONAL_OBJECT).lower(),
    str(GUID_FOLDER).lower(),
}

# Nikon 的 USB 厂商号
NIKON_VENDOR_ID = "04B0"

# 我们认识的图片/视频扩展名（相机上的原始文件）
MEDIA_EXTS = {".jpg", ".jpeg", ".nef", ".nrw", ".tif", ".tiff", ".heic", ".mov", ".mp4", ".avi"}


@dataclass
class CameraObject:
    """相机上的一个对象（可能是文件夹，也可能是照片）。"""
    object_id: str
    name: str
    original_name: str
    is_folder: bool
    size: int
    path: str          # 相机内的逻辑路径，例如 /DCIM/100NCZ_2/DSC_0001.JPG

    @property
    def suffix(self) -> str:
        return Path(self.original_name or self.name).suffix.lower()


class CameraError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# WPD 会话
# ---------------------------------------------------------------------------

class NikonCamera:
    """一个已打开的相机会话。

    用 `with NikonCamera.open() as camera:` 使用；退出时自动 Close。
    """

    def __init__(self, device_id: str, mod) -> None:
        self.device_id = device_id
        self._mod = mod
        self._device = None
        self._content = None
        self._properties = None
        self._resources = None
        # 已经读过的对象属性，避免重复往相机发请求（相机端很慢）
        self._meta_cache: dict[str, dict] = {}
        self._key_set_cache = None

    # -- 打开 / 关闭 ------------------------------------------------------

    @classmethod
    def find_devices(cls) -> list[tuple[str, str]]:
        """找出所有尼康相机，返回 [(WPD 设备 ID, 说明)]。

        `IPortableDeviceManager::GetDevices` 在这台机器上返回 0（它的
        in/out 参数在 comtypes 下的映射不可靠），所以改成从 PnP 设备树里找 ——
        这个方法实测稳定。
        """
        query = (
            "Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | "
            "Where-Object { $_.InstanceId -match 'VID_%s' } | "
            "ForEach-Object { $_.InstanceId + '|' + $_.FriendlyName }"
            % NIKON_VENDOR_ID
        )
        try:
            out = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-Command", query],
                capture_output=True, text=True, timeout=30,
            ).stdout
        except Exception as exc:  # noqa: BLE001
            raise CameraError(f"枚举 PnP 设备失败：{exc}") from exc

        devices: list[tuple[str, str]] = []
        for line in out.splitlines():
            line = line.strip()
            if "|" not in line:
                continue
            instance_id, _, friendly = line.partition("|")
            # 只取 WPD 类的设备（MTP/PTP 模式的相机）
            if not instance_id.upper().startswith("USB\\"):
                continue
            device_id = (
                "\\\\?\\"
                + instance_id.lower().replace("\\", "#")
                + "#"
                + str(WPD_DEVICE_INTERFACE).lower()
            )
            devices.append((device_id, friendly.strip() or instance_id))
        return devices

    @classmethod
    def open(cls, index: int = 0) -> "NikonCamera":
        mod = GetModule(r"C:\Windows\System32\PortableDeviceApi.dll")
        devices = cls.find_devices()
        if not devices:
            raise CameraError(
                "没有找到尼康相机。请确认：\n"
                "  · 相机已用 USB 线连到电脑并开机\n"
                "  · 相机的 USB 模式是 MTP/PTP（不是「仅充电」或「USB 供电」）\n"
                "  · 相机没有处于「存储卡读取中」或菜单占用状态"
            )
        if index >= len(devices):
            raise CameraError(f"只找到 {len(devices)} 台相机，取不到第 {index + 1} 台")

        device_id, friendly = devices[index]
        camera = cls(device_id, mod)

        values = CoCreateInstance(CLSID_DEVICE_VALUES, interface=mod.IPortableDeviceValues)
        _set_str(values, mod, (FMTID_CLIENT, 2), "LUMI Camera Bridge")
        _set_int(values, mod, (FMTID_CLIENT, 3), 1)
        _set_int(values, mod, (FMTID_CLIENT, 4), 0)
        _set_int(values, mod, (FMTID_CLIENT, 5), 0)

        device = CoCreateInstance(CLSID_PORTABLE_DEVICE, interface=mod.IPortableDevice)
        device.Open(device_id, values)
        camera._device = device
        camera._content = device.Content()
        camera._properties = camera._content.Properties()
        # 注意：资源接口是 IPortableDeviceContent::Transfer() 返回的，
        # 不是叫 Resources() —— 名字很容易搞错。
        camera._resources = camera._content.Transfer()
        camera.friendly_name = friendly
        return camera

    def close(self) -> None:
        if self._device is not None:
            try:
                self._device.Close()
            except Exception:  # noqa: BLE001
                pass
            self._device = None

    def __enter__(self) -> "NikonCamera":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # -- 枚举 -------------------------------------------------------------

    def _key_set(self):
        """构造（并缓存）一次要读的属性键集合。

        每次 metadata() 都重建一个 key collection 会让遍历慢好几倍 ——
        每个对象一次 COM 创建 + 4 次 Add。缓存下来后同一个 session 只建一次。
        """
        if self._key_set_cache is None:
            key_set = CoCreateInstance(CLSID_KEY_COLLECTION,
                                       interface=mod_key_collection(self._mod))
            for key in (KEY_NAME, KEY_ORIGINAL_NAME, KEY_CONTENT_TYPE, KEY_SIZE):
                key_set.Add(_pk(self._mod, key))
            self._key_set_cache = key_set
        return self._key_set_cache

    def children(self, parent_object_id: str) -> list[str]:
        """返回某个对象下的直接子对象 ID。

        `EnumObjects` 的 `ppenum` 是纯 out 参数，comtypes 直接把它作为返回值；
        `Next` 的 `pcFetched` 是 in-out，所以返回值是 (数组, 实际取到几个)。
        """
        enum = self._content.EnumObjects(0, parent_object_id, None)
        collected: list[str] = []
        while True:
            result = enum.Next(32)
            if isinstance(result, tuple):
                batch, _fetched = result
            else:
                batch = result
            items = [x for x in (batch or []) if isinstance(x, str) and x]
            if not items:
                break
            collected.extend(items)
        return collected

    def metadata(self, object_id: str) -> dict:
        if object_id in self._meta_cache:
            return self._meta_cache[object_id]

        values = self._properties.GetValues(object_id, self._key_set())

        meta: dict = {
            "name": _get_str(values, self._mod, KEY_NAME) or "",
            "original_name": _get_str(values, self._mod, KEY_ORIGINAL_NAME) or "",
            "content_type": _get_guid_str(values, self._mod, KEY_CONTENT_TYPE),
            "size": _get_int(values, self._mod, KEY_SIZE),
        }
        self._meta_cache[object_id] = meta
        return meta

    def walk(self, parent: str = ROOT_OBJECT_ID, prefix: str = "") -> list[CameraObject]:
        """遍历相机，返回全部**文件**对象（文件夹只用于下探）。

        刻意用显式栈而不是递归生成器：
        · 递归 + 生成器在 COM 回调里的对象生命周期不好把握（实测出现过段错误）；
        · 显式栈也天然不怕目录层次变深。
        """
        files: list[CameraObject] = []
        visited: set[str] = set()
        stack: list[tuple[str, str]] = [(parent, prefix)]

        while stack:
            current, current_prefix = stack.pop()
            if current in visited:
                continue
            visited.add(current)

            for child_id in self.children(current):
                meta = self.metadata(child_id)
                name = meta["original_name"] or meta["name"] or child_id
                logical = f"{current_prefix}/{name}"

                if meta["content_type"] in FOLDER_CONTENT_TYPES:
                    stack.append((child_id, logical))
                    continue

                files.append(CameraObject(
                    object_id=child_id,
                    name=meta["name"] or name,
                    original_name=meta["original_name"] or name,
                    is_folder=False,
                    size=meta["size"],
                    path=logical,
                ))
        return files

    # -- 下载 -------------------------------------------------------------

    def download(self, obj: CameraObject, chunk: int = 256 * 1024) -> bytes:
        """把一个对象读成完整字节流。

        分块读是为了给长下载留出可打断的余地；相机端 MTP 传输并不快。
        """
        optimal = ctypes.c_ulong(0)
        stream = self._resources.GetStream(
            obj.object_id, _pk(self._mod, KEY_RESOURCE_DEFAULT), 0, ctypes.byref(optimal)
        )
        buffer_size = max(chunk, int(optimal.value) or 0)
        buf = (ctypes.c_ubyte * buffer_size)()
        data = bytearray()
        while True:
            got = ctypes.c_ulong(0)
            stream.Read(buf, buffer_size, ctypes.byref(got))
            if got.value == 0:
                break
            data += bytes(buf[:got.value])
        return bytes(data)


# ---------------------------------------------------------------------------
# comtypes 参数辅助
# ---------------------------------------------------------------------------

def _pk(mod, pair):
    """构造一个 PROPERTYKEY。comtypes 要求结构体而不是元组。"""
    key = mod._tagpropertykey()
    key.fmtid, key.pid = pair
    return key


def mod_key_collection(mod):
    """IPortableDeviceKeyCollection 的接口类型。"""
    return mod.IPortableDeviceKeyCollection


def _set_str(values, mod, pair, text: str) -> None:
    values.SetStringValue(_pk(mod, pair), text)


def _set_int(values, mod, pair, number: int) -> None:
    values.SetUnsignedIntegerValue(_pk(mod, pair), number)


def _get_str(values, mod, pair) -> Optional[str]:
    try:
        return values.GetStringValue(_pk(mod, pair))
    except Exception:  # noqa: BLE001
        return None


def _get_int(values, mod, pair) -> int:
    try:
        return int(values.GetUnsignedLargeIntegerValue(_pk(mod, pair)))
    except Exception:  # noqa: BLE001
        try:
            return int(values.GetUnsignedIntegerValue(_pk(mod, pair)))
        except Exception:  # noqa: BLE001
            return 0


def _get_guid_str(values, mod, pair) -> str:
    """内容类型是 GUID，但用 GetGuidValue 取；取不到就返回空串。"""
    try:
        guid = values.GetGuidValue(_pk(mod, pair))
        return str(guid).lower()
    except Exception:  # noqa: BLE001
        return ""


# ---------------------------------------------------------------------------
# 命令行
# ---------------------------------------------------------------------------

def cmd_list(camera: NikonCamera, media_only: bool) -> int:
    items = camera.walk()
    if media_only:
        items = [i for i in items if i.suffix in MEDIA_EXTS]

    print(f"相机：{camera.friendly_name}")
    print(f"找到 {len(items)} 个文件\n")
    total = 0
    for item in items:
        total += item.size
        print(f"  {item.path:<48} {item.size / 1024:>9.0f} KB")
    print(f"\n合计 {total / 1024 / 1024:.1f} MB")
    return 0


def download_items(camera: NikonCamera, items: list[CameraObject], target: Path,
                   skip_existing: bool = True) -> tuple[int, int, int]:
    """下载一组对象，返回 (下载数, 跳过数, 失败数)。"""
    target.mkdir(parents=True, exist_ok=True)
    done = skipped = failed = 0
    for item in items:
        name = Path(item.original_name or item.name).name
        if not name:
            failed += 1
            continue
        destination = target / name
        if skip_existing and destination.exists() and destination.stat().st_size > 0:
            skipped += 1
            continue
        try:
            data = camera.download(item)
            # 先写临时文件再改名，避免中断时留下半个文件被当成「已下载」
            temp = destination.with_suffix(destination.suffix + ".part")
            temp.write_bytes(data)
            temp.replace(destination)
            print(f"  ↓ {name}  {len(data) / 1024:.0f} KB")
            done += 1
        except Exception as exc:  # noqa: BLE001
            print(f"  ✗ {name}  下载失败：{exc}", file=sys.stderr)
            failed += 1
    return done, skipped, failed


def cmd_download_all(camera: NikonCamera, target: Path, media_only: bool) -> int:
    items = camera.walk()
    if media_only:
        items = [i for i in items if i.suffix in MEDIA_EXTS]
    print(f"相机：{camera.friendly_name}    待处理 {len(items)} 个文件")
    print(f"目标：{target}\n")
    done, skipped, failed = download_items(camera, items, target)
    print(f"\n下载 {done}、跳过（已存在）{skipped}、失败 {failed}")
    return 0 if failed == 0 else 1


def cmd_watch(camera: NikonCamera, target: Path, interval: float, media_only: bool) -> int:
    print(f"监视中：每 {interval:.0f} 秒检查一次相机，有新照片就下载到 {target}")
    print("按 Ctrl+C 停止。\n")
    seen: set[str] = set()
    try:
        while True:
            try:
                items = camera.walk()
            except Exception as exc:  # noqa: BLE001
                # 相机可能被拔掉或进入休眠，不要直接崩掉
                print(f"  ！读取相机失败（{exc}），{interval:.0f} 秒后重试", file=sys.stderr)
                time.sleep(interval)
                continue
            if media_only:
                items = [i for i in items if i.suffix in MEDIA_EXTS]

            fresh = [i for i in items if i.path not in seen]
            if fresh:
                print(f"[{time.strftime('%H:%M:%S')}] 发现 {len(fresh)} 个新文件")
                done, _, failed = download_items(camera, fresh, target)
                if done or failed:
                    print(f"          下载 {done}、失败 {failed}")
            for item in items:
                seen.add(item.path)
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n已停止。")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="把尼康相机（MTP/PTP）里的照片列出来并下载到本地（走 Windows 自带的 WPD API）。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--index", type=int, default=0, help="第几台相机（默认第一台）")
    parser.add_argument("--all-files", action="store_true",
                        help="连非照片文件一起列/下载（默认只处理图片与视频）")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--list", action="store_true", help="列出相机里的文件")
    group.add_argument("--download-all", metavar="目录", help="把相机里全部照片下载到该目录")
    group.add_argument("--watch", metavar="目录", help="持续监视并自动下载新照片")
    parser.add_argument("--interval", type=float, default=5.0, help="监视间隔秒数（默认 5）")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    media_only = not args.all_files

    with NikonCamera.open(index=args.index) as camera:
        if args.list:
            return cmd_list(camera, media_only)
        if args.download_all:
            return cmd_download_all(camera, Path(args.download_all), media_only)
        if args.watch:
            return cmd_watch(camera, Path(args.watch), args.interval, media_only)
    return 0


if __name__ == "__main__":
    comtypes.CoInitialize()
    try:
        raise SystemExit(main())
    except CameraError as error:
        print(f"✗ {error}", file=sys.stderr)
        raise SystemExit(1)
