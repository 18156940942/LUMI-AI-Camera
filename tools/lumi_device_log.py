#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 iPhone 上的 LUMI 变成「看得见」的对象 —— 全程不需要 Mac。

为什么需要这个工具
==================

这个项目是在**没有 Mac 的 Windows** 上开发的。这带来一个死结：

    os_log 的输出只有 macOS 的「控制台」App 或 Xcode 能读。

也就是说，App 装到真机上之后一旦出问题，现场信息**根本取不出来** ——
这正是之前给 App 加了「设备自检与诊断」页面的原因（在 App 内复制报告）。
但那个办法要求你能操作手机、并且愿意把报告粘出来。

这个工具走的是另一条路：**用 libimobiledevice 经 USB 直接读设备日志**。
它在 Windows 上就能跑，于是「真机现场」第一次变得可观测。

它还能读**电池温度与电流** —— 这是唯一能量化「耗电、发热」的通道。

能力边界（必须说清楚）
======================

**能拿到**
  · 设备信息：机型、iOS 版本、构建号
  · 已安装应用列表（含 LUMI 的构建号 —— 前提是构建号被写进了 CFBundleVersion）
  · USB 设备日志流（**系统日志全都能看到**，含 AVCaptureSession 起停、帧率、
    应用前后台切换、看门狗、HangTracer、崩溃前兆）
  · 电池：温度、电流、电压、瞬时功率、循环次数
  · 崩溃报告

**拿不到**
  · **App 自己写的 `.info` 级 os_log 不会出现在这个流里。** iOS 的 syslog 中继
    只转发 `default`(=notice) 及以上级别。所以要让 App 的日志可见，代码里必须
    用 `.notice`/`.warning`/`.error`，而不是 `.info`。
    （`LUMI/Services/DiagnosticsLog.swift` 的 `emitToOSLog` 已按这条改过。）
  · **不能操作手机**：不能点按钮、不能授权、不能启动 App。
  · 不能截图（`idevicescreenshot` 需要 developer disk image，本项目没有）。

依赖
====

需要 `libimobiledevice` 的 Windows 命令行工具。首次使用先跑：

    python tools/lumi_device_log.py fetch-tools

它会下载官方 release（`libimobiledevice-win32/imobiledevice-net`，约 4.3 MB）
到 `tools/.imd/`，并校验 SHA-256。这个目录已被 .gitignore 排除。

用法
====

    python tools/lumi_device_log.py fetch-tools        # 首次：取工具
    python tools/lumi_device_log.py info               # 设备型号 / iOS 版本
    python tools/lumi_device_log.py apps               # 已装应用（看 LUMI 构建号）
    python tools/lumi_device_log.py battery            # 电池 / 温度 / 瞬时功率
    python tools/lumi_device_log.py watch --minutes 3  # 实时抓 LUMI 相关日志
    python tools/lumi_device_log.py watch --minutes 3 --power   # 同时采样功耗温度
    python tools/lumi_device_log.py crash              # 拉崩溃报告
    python tools/lumi_device_log.py report             # 汇总成一份纯文本报告
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = ROOT / "tools" / ".imd"

# 官方 release：libimobiledevice-win32/imobiledevice-net（libimobiledevice 的 Windows 移植）
TOOLS_URL = (
    "https://github.com/libimobiledevice-win32/imobiledevice-net/releases/download/"
    "v1.3.17/libimobiledevice.1.2.1-r1122-win-x64.zip"
)
TOOLS_SHA256 = "d7cb57a71270848c35c3f01006701535aadf6dfb52325863ea368c94a34a2cab"
TOOLS_VERSION = "1.2.1-r1122-win-x64"

# Apple Mobile Device Service 在 Windows 上把 usbmuxd 暴露在这个 TCP 端口
DEFAULT_USBMUXD = "127.0.0.1:27015"

# 默认过滤：只留与 LUMI 及相机链路相关的行。
#
# `LUMI\(` 覆盖了以进程名开头的所有条目（含 `LUMI(com.lumi.aicamera)`、
# `LUMI(AVFCapture)`、`LUMI(UIKitCore)` 等）；其余几条是别的进程替我们打的
# 关键信号 —— 例如 `cameracaptured` 会用 `FigCapture...` 报告前台 App 与
# 采集会话状态，`HangTracer` 是卡死前兆，`JetsamEvent` 是内存被强杀，
# `thermalmonitord` 是温控降频。
#
# 刻意**不包含**裸的 `watchdog`：`watchdogd` 每秒都在刷 `<private>`，
# 实测 20 秒就能淹掉 24 条命中里的绝大多数，而它真正对我们有意义的时刻
# （强杀 App）会以 `HangTracer` / 崩溃报告的形式出现。
DEFAULT_PATTERN = (
    r"LUMI\("
    r"|com\.lumi\.aicamera"
    r"|AVCapture"
    r"|CMCapture"
    r"|AVFCapture"
    r"|FigCapture"
    r"|CoreML"
    r"|HangTracer"
    r"|JetsamEvent"
    r"|thermalmonitord"
)


class ToolMissing(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# 工具定位与获取
# ---------------------------------------------------------------------------

def bin_dir() -> Path:
    d = TOOLS_DIR / TOOLS_VERSION
    if (d / "idevicesyslog.exe").exists():
        return d
    # 兼容手工放进 tools/.imd/ 的情况
    if (TOOLS_DIR / "idevicesyslog.exe").exists():
        return TOOLS_DIR
    return d


def tool(name: str) -> Path:
    d = bin_dir()
    exe = d / (name if name.endswith(".exe") else f"{name}.exe")
    if not exe.exists():
        raise ToolMissing(
            f"缺少 {exe.name}。先跑一次：\n    python tools/lumi_device_log.py fetch-tools"
        )
    return exe


def fetch_tools(force: bool = False) -> int:
    """下载并校验 libimobiledevice 工具包。"""
    target = TOOLS_DIR / TOOLS_VERSION
    if (target / "idevicesyslog.exe").exists() and not force:
        print(f"工具已就绪：{target}")
        return 0

    TOOLS_DIR.mkdir(parents=True, exist_ok=True)
    archive = TOOLS_DIR / f"{TOOLS_VERSION}.zip"

    if not archive.exists() or force:
        print(f"下载 {TOOLS_URL}")
        with urllib.request.urlopen(TOOLS_URL, timeout=180) as resp, open(archive, "wb") as fh:
            shutil.copyfileobj(resp, fh)

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    print(f"  SHA-256 {digest}")
    if digest != TOOLS_SHA256:
        print("  !! 校验失败，已删除下载文件。预期：", file=sys.stderr)
        print(f"     {TOOLS_SHA256}", file=sys.stderr)
        archive.unlink(missing_ok=True)
        return 1
    print("  校验通过")

    import zipfile

    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zf:
        zf.extractall(target)
    print(f"已解压到 {target}")

    (TOOLS_DIR / "README.txt").write_text(
        "由 tools/lumi_device_log.py fetch-tools 自动下载。\n"
        f"来源：{TOOLS_URL}\n"
        f"SHA-256：{TOOLS_SHA256}\n",
        encoding="utf-8",
    )
    return 0


def run_tool(name: str, args: list[str], timeout: int = 60) -> subprocess.CompletedProcess:
    exe = tool(name)
    env = {**os.environ, "USBMUXD_SOCKET_ADDRESS": DEFAULT_USBMUXD}
    return subprocess.run(
        [str(exe), *args],
        capture_output=True,
        timeout=timeout,
        env=env,
    )


# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

def cmd_info(_args: argparse.Namespace) -> int:
    keys = [
        ("DeviceName", "设备名"),
        ("ProductType", "机型代号"),
        ("ProductVersion", "iOS 版本"),
        ("BuildVersion", "构建号"),
        ("CPUArchitecture", "架构"),
    ]
    print("=== 设备 ===")
    for key, label in keys:
        try:
            out = run_tool("ideviceinfo", ["-k", key], timeout=25).stdout.decode(errors="replace").strip()
        except ToolMissing as exc:
            print(f"  {exc}", file=sys.stderr)
            return 1
        except subprocess.TimeoutExpired:
            out = "（超时）"
        print(f"  {label:<10} = {out}")

    # 机型代号 -> 人类可读
    model = run_tool("ideviceinfo", ["-k", "ProductType"], timeout=25).stdout.decode().strip()
    human = MODEL_NAMES.get(model)
    if human:
        print(f"  {'对应机型':<8} = {human}")
    return 0


MODEL_NAMES = {
    "iPhone16,2": "iPhone 15 Pro Max",
    "iPhone16,1": "iPhone 15 Pro",
    "iPhone15,4": "iPhone 15",
    "iPhone15,5": "iPhone 15 Plus",
    "iPhone14,7": "iPhone 14",
    "iPhone14,8": "iPhone 14 Plus",
    "iPhone15,2": "iPhone 14 Pro",
    "iPhone15,3": "iPhone 14 Pro Max",
}


def cmd_apps(args: argparse.Namespace) -> int:
    """已安装应用列表。

    重点看 LUMI 那行的第二列 —— 那是 ``CFBundleVersion``。
    如果构建时把 CI 运行号写进去，这里就能直接看出**手机上装的是哪一次构建**。
    """
    try:
        proc = run_tool("ideviceinstaller", ["-l"], timeout=180)
    except (ToolMissing, subprocess.TimeoutExpired) as exc:
        print(f"  ✗ 读取失败：{exc}", file=sys.stderr)
        return 1

    text = proc.stdout.decode("utf-8", errors="replace")
    if proc.returncode != 0 and not text.strip():
        print("  ✗ ideviceinstaller 无输出：", proc.stderr.decode(errors="replace")[:300], file=sys.stderr)
        return 1

    rows = [line for line in text.splitlines() if line.strip()]
    if not rows:
        print("  ✗ 没有读到应用列表", file=sys.stderr)
        return 1

    header, body = rows[0], rows[1:]
    if args.filter:
        body = [r for r in body if re.search(args.filter, r, re.I)]
    rows = [header, *body]

    shown = len(body)
    print(f"=== 已安装应用（{'匹配' if args.filter else '共'} {shown} 个）===")
    for row in rows:
        mark = "  ← LUMI" if "lumi" in row.lower() else ""
        print(f"  {row}{mark}")

    if args.filter and not body:
        print("  （没有匹配的行）")
    return 0


def read_battery() -> dict:
    """读电池/温度。返回原始 IORegistry 字典（失败返回空 dict）。"""
    proc = run_tool("idevicediagnostics", ["ioregentry", "AppleSmartBattery"], timeout=30)
    raw = proc.stdout
    if not raw:
        return {}
    try:
        return plistlib.loads(raw).get("IORegistry", {})
    except Exception:
        return {}


def battery_summary(d: dict) -> dict:
    """把原始寄存器值换算成有物理意义的量。"""
    if not d:
        return {"ok": False}

    def get(key, default=None):
        return d.get(key, default)

    out: dict = {"ok": True}
    if "Temperature" in d:
        out["temperature_c"] = d["Temperature"] / 100.0
    if "CurrentCapacity" in d:
        out["capacity_pct"] = int(d["CurrentCapacity"])
    if "Voltage" in d:
        out["voltage_v"] = d["Voltage"] / 1000.0
    if "Amperage" in d:
        # Amperage 是有符号 16 位：>32767 表示负值（放电）
        amp = int(d["Amperage"])
        if amp > 32767:
            amp -= 65536
        out["amperage_ma"] = amp
        if "Voltage" in d:
            out["power_w"] = abs(amp) / 1000.0 * d["Voltage"] / 1000.0
            out["direction"] = "充电中" if amp > 0 else "放电中"
    if "CycleCount" in d:
        out["cycle_count"] = d["CycleCount"]
    if "IsCharging" in d:
        out["is_charging"] = bool(d["IsCharging"])
    return out


def format_battery(s: dict, prefix: str = "  ") -> list[str]:
    if not s.get("ok"):
        return [f"{prefix}（读不到电池数据）"]
    lines = []
    if "temperature_c" in s:
        lines.append(f"{prefix}电池温度   = {s['temperature_c']:.1f} ℃")
    if "capacity_pct" in s:
        lines.append(f"{prefix}电量       = {s['capacity_pct']}%")
    if "voltage_v" in s:
        lines.append(f"{prefix}电压       = {s['voltage_v']:.3f} V")
    if "amperage_ma" in s:
        lines.append(f"{prefix}电流       = {s['amperage_ma']:+d} mA（{s.get('direction','-')}）")
    if "power_w" in s:
        lines.append(f"{prefix}瞬时功率   = {s['power_w']:.2f} W")
    if "cycle_count" in s:
        lines.append(f"{prefix}循环次数   = {s['cycle_count']}")
    return lines


def cmd_battery(args: argparse.Namespace) -> int:
    if args.repeat > 1:
        print(f"=== 采样 {args.repeat} 次，间隔 {args.interval} 秒 ===")
        samples = []
        for i in range(args.repeat):
            s = battery_summary(read_battery())
            samples.append(s)
            stamp = dt.datetime.now().strftime("%H:%M:%S")
            head = " · ".join(
                filter(None, [
                    f"{s.get('temperature_c', float('nan')):.1f}℃" if s.get("ok") else None,
                    f"{s.get('power_w', float('nan')):.2f}W" if s.get("ok") else None,
                    f"{s.get('capacity_pct')}%" if s.get("ok") else None,
                ])
            )
            print(f"  [{i + 1:>2}/{args.repeat}] {stamp}  {head}")
            if i < args.repeat - 1:
                time.sleep(args.interval)

        good = [s for s in samples if s.get("ok")]
        if good:
            print("\n=== 汇总 ===")
            temps = [s["temperature_c"] for s in good if "temperature_c" in s]
            if temps:
                print(f"  温度  最低 {min(temps):.1f} ℃ / 最高 {max(temps):.1f} ℃ / 变化 {max(temps) - min(temps):+.1f} ℃")
            amps = [s["amperage_ma"] for s in good if "amperage_ma" in s]
            if amps:
                # 只有在真的出现负电流时才提「放电」，否则会把最小的充电电流
                # 误报成放电峰值 —— 这个措辞错误会直接误导耗电判断。
                if min(amps) < 0:
                    print(f"  电流  最大充电 {max(amps)} mA / 最大放电 {min(amps)} mA")
                else:
                    print(f"  电流  全程充电中（{min(amps)} ~ {max(amps)} mA，无放电采样）")
        return 0

    print("=== 电池与热状态 ===")
    for line in format_battery(battery_summary(read_battery())):
        print(line)
    print()
    print("  提示：USB 连着时手机在充电，瞬时功率反映的是「充电功率」而不是「App 耗电」。")
    print("        要看 App 真实耗电，注意电流是否**由正转负**（说明功耗超过了 5V/3A 供电）。")
    return 0


def cmd_watch(args: argparse.Namespace) -> int:
    """实时抓设备日志。"""
    pattern = None if args.all else re.compile(args.pattern or DEFAULT_PATTERN)

    out_path = Path(args.out) if args.out else (
        ROOT / "device-logs" / f"lumi-{dt.datetime.now():%Y%m%d-%H%M%S}.log"
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)

    exe = tool("idevicesyslog")
    env = {**os.environ, "USBMUXD_SOCKET_ADDRESS": DEFAULT_USBMUXD}

    duration = args.minutes * 60
    print(f"=== 抓取设备日志，最长 {args.minutes} 分钟 ===")
    print(f"  过滤   : {'（不过滤，全部）' if pattern is None else 'LUMI / 相机 / 看门狗'}")
    print(f"  写入   : {out_path}")
    print(f"  功耗采样: {'每 10 秒一次' if args.power else '关闭'}")
    print()
    print("  >>> 现在去手机上操作。抓取期间不要拔线。")
    print()

    proc = subprocess.Popen(
        [str(exe)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, bufsize=0,
    )

    stop = threading.Event()
    power_samples: list[dict] = []

    def sample_power() -> None:
        while not stop.wait(10):
            s = battery_summary(read_battery())
            if s.get("ok"):
                power_samples.append(s)
                print(
                    f"    [功耗] {dt.datetime.now():%H:%M:%S}  "
                    f"{s.get('temperature_c', 0):.1f}℃  "
                    f"{s.get('amperage_ma', 0):+d} mA  "
                    f"{s.get('power_w', 0):.2f} W  "
                    f"{s.get('capacity_pct')}%",
                    flush=True,
                )

    sampler = threading.Thread(target=sample_power, daemon=True) if args.power else None
    if sampler:
        sampler.start()

    matched = 0
    total = 0
    started = time.time()

    try:
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(f"# LUMI 设备日志  {dt.datetime.now():%Y-%m-%d %H:%M:%S}\n")
            fh.write(f"# 过滤：{'全部' if pattern is None else (args.pattern or DEFAULT_PATTERN)}\n\n")
            for raw in proc.stdout:  # type: ignore[union-attr]
                if time.time() - started > duration:
                    break
                total += 1
                line = raw.decode("utf-8", errors="replace").rstrip("\n")
                fh.write(line + "\n")
                if pattern is not None:
                    if not pattern.search(line):
                        continue
                matched += 1
                print("  " + line, flush=True)
                if args.limit and matched >= args.limit:
                    break
    except KeyboardInterrupt:
        print("\n  （手动中断）")
    finally:
        stop.set()
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
        if sampler:
            sampler.join(timeout=3)

    print()
    print(f"=== 结束：收到 {total} 行，命中 {matched} 行 ===")
    print(f"  日志：{out_path}")

    if power_samples:
        temps = [s["temperature_c"] for s in power_samples if "temperature_c" in s]
        amps = [s["amperage_ma"] for s in power_samples if "amperage_ma" in s]
        print()
        print(f"  功耗采样 {len(power_samples)} 次：")
        if temps:
            print(f"    温度 {min(temps):.1f} → {max(temps):.1f} ℃（峰值 {max(temps):.1f}）")
        if amps:
            if min(amps) < 0:
                print(f"    电流 最大充电 {max(amps)} mA / 最大放电 {min(amps)} mA")
            else:
                print(f"    电流 全程充电中（{min(amps)} ~ {max(amps)} mA，未出现放电）")

    if matched == 0:
        print()
        print("  没有命中任何 LUMI 日志。常见原因：")
        print("    · App 没在前台运行（切到后台后系统不会持续打日志）")
        print("    · App 只是显示了界面，还没启动摄像头或分析管线")
        print("    · App 自己写的 .info 级日志**不会**走这个通道（见文件头说明）")
    return 0


def cmd_crash(args: argparse.Namespace) -> int:
    dest = Path(args.dir) if args.dir else (ROOT / "device-logs" / "crash")
    dest.mkdir(parents=True, exist_ok=True)
    try:
        proc = run_tool("idevicecrashreport", [str(dest), "-k", "-e"], timeout=240)
    except (ToolMissing, subprocess.TimeoutExpired) as exc:
        print(f"  ✗ 失败：{exc}", file=sys.stderr)
        return 1

    print(proc.stdout.decode(errors="replace")[:2000])
    if proc.returncode != 0:
        print(proc.stderr.decode(errors="replace")[:1000], file=sys.stderr)

    hits = sorted(p for p in dest.rglob("*") if "lumi" in p.name.lower())
    print()
    if hits:
        print(f"找到 {len(hits)} 份与 LUMI 相关的崩溃报告：")
        for p in hits:
            print(f"  {p}  ({p.stat().st_size:,} bytes)")
    else:
        print("没有与 LUMI 相关的崩溃报告。")
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    """一份可以粘进对话的纯文本报告。"""
    lines: list[str] = []
    stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines.append("=" * 62)
    lines.append("LUMI 真机现场报告（Windows 侧，usb）")
    lines.append(f"生成时间：{stamp}")
    lines.append("=" * 62)

    lines.append("")
    lines.append("【设备】")
    for key, label in [
        ("DeviceName", "设备名"),
        ("ProductType", "机型代号"),
        ("ProductVersion", "iOS 版本"),
        ("BuildVersion", "构建号"),
    ]:
        try:
            v = run_tool("ideviceinfo", ["-k", key], timeout=25).stdout.decode(errors="replace").strip()
        except Exception as exc:  # noqa: BLE001
            v = f"（{type(exc).__name__}）"
        lines.append(f"  {label:<8} = {v}")
    model = run_tool("ideviceinfo", ["-k", "ProductType"], timeout=25).stdout.decode().strip()
    if model in MODEL_NAMES:
        lines.append(f"  {'对应机型':<7} = {MODEL_NAMES[model]}")

    lines.append("")
    lines.append("【电池与热】")
    lines.extend(format_battery(battery_summary(read_battery())))

    lines.append("")
    lines.append("【已安装的 LUMI】")
    try:
        text = run_tool("ideviceinstaller", ["-l"], timeout=180).stdout.decode("utf-8", errors="replace")
        hits = [r for r in text.splitlines() if "lumi" in r.lower()]
        lines.extend([f"  {h}" for h in hits] or ["  （未找到 LUMI，可能没装上）"])
    except Exception as exc:  # noqa: BLE001
        lines.append(f"  （读取失败：{type(exc).__name__}）")

    lines.append("")
    lines.append("【说明】")
    lines.append("  · 本报告由 tools/lumi_device_log.py 生成，经 USB 读取，不经网络。")
    lines.append("  · 只读取设备公开的系统信息与电池寄存器，不触碰照片与 App 数据。")

    report = "\n".join(lines)
    print(report)

    if args.out:
        p = Path(args.out)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(report + "\n", encoding="utf-8")
        print()
        print(f"已写入 {p}")
    return 0


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="经 USB 读取 iPhone 上的 LUMI 现场信息（不需要 Mac）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("fetch-tools", help="下载 libimobiledevice 工具包（首次使用）")
    sub.add_parser("info", help="设备型号与系统版本")

    p_apps = sub.add_parser("apps", help="已安装应用（看 LUMI 的构建号）")
    p_apps.add_argument("--filter", help="只显示匹配此正则的行")

    p_bat = sub.add_parser("battery", help="电池 / 温度 / 瞬时功率")
    p_bat.add_argument("--repeat", type=int, default=1, help="采样次数（默认 1）")
    p_bat.add_argument("--interval", type=float, default=5.0, help="采样间隔秒（默认 5）")

    p_watch = sub.add_parser("watch", help="实时抓设备日志")
    p_watch.add_argument("--minutes", type=float, default=3.0, help="抓多久（默认 3 分钟）")
    p_watch.add_argument("--power", action="store_true", help="同时每 10 秒采样功耗与温度")
    p_watch.add_argument("--all", action="store_true", help="不过滤，输出全部日志")
    p_watch.add_argument("--pattern", help="自定义过滤正则")
    p_watch.add_argument("--out", help="写入的日志文件路径")
    p_watch.add_argument("--limit", type=int, default=0, help="命中多少行后提前停止（0=不限）")

    p_crash = sub.add_parser("crash", help="拉取崩溃报告")
    p_crash.add_argument("--dir", help="保存目录")

    p_rep = sub.add_parser("report", help="生成一份可粘贴的纯文本报告")
    p_rep.add_argument("--out", help="同时写文件")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command in (None, "fetch-tools"):
        return fetch_tools(force=getattr(args, "force", False))

    handlers = {
        "info": cmd_info,
        "apps": cmd_apps,
        "battery": cmd_battery,
        "watch": cmd_watch,
        "crash": cmd_crash,
        "report": cmd_report,
    }
    handler = handlers.get(args.command)
    if handler is None:
        parser.print_help()
        return 2

    try:
        return handler(args)
    except ToolMissing as exc:
        print(f"✗ {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
