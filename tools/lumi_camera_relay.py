#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI 相机中继（digiCamControl 桥接）
====================================

把「相机 → 电脑」这段交给 **digiCamControl**（免费开源），本脚本负责把它的输出
接给手机上的 LUMI App。

为什么这么分工
--------------
相机的实时取景是 PTP 厂商私有命令，没有公开文档。自己实现的话要用 Zadig 把
微软的相机驱动换成 WinUSB —— **换完之后资源管理器就看不到相机照片了，
digiCamControl 也会跟着失效**。而 digiCamControl 已经把这件事做好了：
它走尼康官方 SDK，官网支持列表里明确写着 Z6 II 支持遥控与实时取景。

所以：**相机侧用现成的，我这边只做「搬运」。**

本脚本提供什么
--------------
把 digiCamControl 的两个接口收拢成 App 可以直接用的一个地址：

    GET  /health            中继与 digiCamControl 的状态（真实探测，不猜）
    GET  /live              实时取景 MJPEG（转发 digiCamControl 的 5514/live）
    GET  /photos            相机照片目录（JSON）
    GET  /photo/<文件名>     取一张照片
    POST /capture           遥控快门
    GET  /                  状态页（浏览器直接用）

后台还会**轮询 digiCamControl 的会话列表，把新照片自动下载到本地文件夹** ——
这就是「自动导入」的来源。

先说清楚：哪些验证过、哪些没有
------------------------------
**没有验证**：本脚本对 digiCamControl 的实际响应格式是按官方文档写的，
装好之前无法实测。所以提供了 `--probe` 模式：把每个接口的原始响应原样打印出来，
先看清楚真实格式，再来校准。**不要相信任何没跑过的解析代码。**

**已实测**：本机端口占用、防火墙状态、以及相机在 WPD 下的可达性。

前置条件
--------
1. 装 digiCamControl：https://www.digicamcontrol.com/download
2. 在它的 **File → Settings → Webserver** 里勾上
   「Use web server」与「Allow interaction via webserver」，端口 **5513**，然后**重启它**。
   实时取景的 MJPEG 在 **5514**，需要先在界面里开启实时取景。
3. 相机用 USB 连电脑、开机、USB 模式设为 MTP/PTP。

用法
----
    # 先探一下接口真实长什么样（装好 digiCamControl 之后第一步就跑这个）
    python tools/lumi_camera_relay.py --probe

    # 启动中继
    python tools/lumi_camera_relay.py

依赖
----
    仅标准库。不需要 opencv、不需要 comtypes。
"""

from __future__ import annotations

import argparse
import json
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from http import server
from pathlib import Path
from typing import Optional

DEFAULT_DCC_HOST = "127.0.0.1"
DEFAULT_DCC_PORT = 5513          # digiCamControl 的 webserver
DEFAULT_LIVE_PORT = 5514         # digiCamControl 的 MJPEG 实时取景
DEFAULT_PORT = 8092              # 本中继的端口（避开 8090 监看 / 8091 精修）

# 我们认识的图片扩展名
MEDIA_EXTS = {".jpg", ".jpeg", ".nef", ".nrw", ".tif", ".tiff", ".heic"}


# ---------------------------------------------------------------------------
# digiCamControl 客户端
# ---------------------------------------------------------------------------

class DccError(RuntimeError):
    pass


@dataclass
class DccClient:
    """digiCamControl webserver 的最小客户端。"""

    host: str = DEFAULT_DCC_HOST
    port: int = DEFAULT_DCC_PORT
    live_port: int = DEFAULT_LIVE_PORT
    timeout: float = 15.0

    # -- 基础 -------------------------------------------------------------

    @property
    def base(self) -> str:
        return f"http://{self.host}:{self.port}"

    @property
    def live_base(self) -> str:
        return f"http://{self.host}:{self.live_port}"

    def _get(self, path: str, raw: bool = False, timeout: Optional[float] = None):
        url = path if path.startswith("http") else self.base + path
        request = urllib.request.Request(url, headers={"User-Agent": "lumi-camera-relay/1.0"})
        try:
            with urllib.request.urlopen(request, timeout=timeout or self.timeout) as resp:
                data = resp.read()
                content_type = resp.headers.get("Content-Type", "")
        except urllib.error.HTTPError as exc:
            raise DccError(f"digiCamControl 返回 HTTP {exc.code}：{url}") from exc
        except Exception as exc:  # noqa: BLE001
            raise DccError(f"连不上 digiCamControl（{url}）：{exc}") from exc

        if raw:
            return data, content_type
        text = data.decode("utf-8", errors="replace")
        return text, content_type

    # -- 高层操作 ---------------------------------------------------------

    def ping(self) -> bool:
        """digiCamControl 的 webserver 是否活着。

        用一个一定会返回 200 的静态资源探测（liveview.jpg 在未开实时取景时
        也会返回内容或明确错误），失败就认为没通。
        """
        try:
            self._get("/", timeout=3.0)
            return True
        except DccError:
            return False

    def session(self) -> dict:
        """取当前会话数据（照片列表）。

        **返回格式未实测** —— 官方文档只说 `session.json`「download current session
        data」，没给结构。先原样返回，由调用方按真实数据适配。
        """
        text, _ = self._get("/session.json")
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise DccError(f"session.json 不是合法 JSON：{text[:200]}") from exc

    def last_captured(self) -> str:
        """最后拍下的文件名。拍摄进行中时 digiCamControl 返回 '-'。"""
        text, _ = self._get("/?slc=get&param1=lastcaptured&param2=")
        return text.strip()

    def capture(self) -> str:
        """遥控快门。"""
        text, _ = self._get("/?CMD=Capture")
        return text.strip()

    def live_view_start(self) -> str:
        text, _ = self._get("/?CMD=LiveViewWnd_Show")
        return text.strip()

    def live_view_stop(self) -> str:
        text, _ = self._get("/?CMD=LiveViewWnd_Hide")
        return text.strip()

    def image(self, name: str) -> bytes:
        """按文件名取一张照片（原图）。"""
        data, _ = self._get("/image/" + urllib.parse.quote(name), raw=True, timeout=120.0)
        return data

    def thumbnail(self, name: str, size: str = "small") -> bytes:
        data, _ = self._get(f"/thumb/{size}/" + urllib.parse.quote(name), raw=True)
        return data

    def set_session_folder(self, folder: str) -> str:
        """设置 digiCamControl 保存照片的目录。"""
        text, _ = self._get(f"/?slc=set&param1=session.folder&param2={urllib.parse.quote(folder)}")
        return text.strip()

    # -- 实时取景代理 -----------------------------------------------------

    def open_live_stream(self):
        """打开 MJPEG 实时取景流，返回响应对象。

        调用方负责关闭。digiCamControl 的地址是 `http://host:5514/live`，
        它要求先在界面里手动开启实时取景（见 live_view_start）。
        """
        request = urllib.request.Request(
            self.live_base + "/live", headers={"User-Agent": "lumi-camera-relay/1.0"}
        )
        try:
            return urllib.request.urlopen(request, timeout=30.0)
        except Exception as exc:  # noqa: BLE001
            raise DccError(f"打不开实时取景流（{self.live_base}/live）：{exc}") from exc


# ---------------------------------------------------------------------------
# 照片收集器
# ---------------------------------------------------------------------------

def extract_file_names(session_payload, limit: int = 500) -> list[str]:
    """从 session.json 里尽量稳地捞出文件名。

    **这里刻意写得宽松**：session.json 的真实结构还没实测过，可能是一个数组、
    可能是 {files:[...]}、也可能是嵌套的。与其按猜测写一个脆弱的解析器，
    不如递归扫一遍所有字符串值，只留下看起来像照片文件名的。

    等 `--probe` 拿到真实结构之后，再把这里收窄成精确解析。
    """
    names: list[str] = []

    def looks_like_media(text: str) -> bool:
        return Path(text).suffix.lower() in MEDIA_EXTS

    def walk(node) -> None:
        if len(names) >= limit:
            return
        if isinstance(node, str):
            # 可能是文件名，也可能是完整路径；只取最后一段
            candidate = node.replace("\\", "/").rsplit("/", 1)[-1]
            if looks_like_media(candidate):
                names.append(candidate)
        elif isinstance(node, dict):
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(session_payload)
    # 去重但保持顺序
    seen: set[str] = set()
    ordered: list[str] = []
    for name in names:
        if name not in seen:
            seen.add(name)
            ordered.append(name)
    return ordered


# ---------------------------------------------------------------------------
# HTTP 服务
# ---------------------------------------------------------------------------

STATUS_PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LUMI 相机中继</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; padding:24px; background:#101014; color:#e8e8ed;
         font:14px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; }
  h1 { font-size:20px; margin:0 0 4px; }
  .sub { color:#9a9aa5; font-size:13px; margin-bottom:20px; }
  .card { background:#18181e; border:1px solid #2a2a32; border-radius:10px;
          padding:16px; margin-bottom:16px; }
  table { border-collapse:collapse; width:100%; }
  th,td { text-align:left; padding:6px 10px; border-bottom:1px solid #2a2a32; font-size:13px; }
  th { color:#9a9aa5; font-weight:500; }
  .ok { color:#4ade80; } .warn { color:#fbbf24; } .bad { color:#f87171; }
  code { background:#1c1c22; padding:1px 6px; border-radius:4px; font-size:12px; }
</style></head><body>
<h1>LUMI 相机中继</h1>
<div class="sub">把 digiCamControl 的实时取景与照片收拢成一个地址，给手机上的 LUMI 用。</div>
<div id="root">加载中……</div>
<script>
fetch('/health').then(r=>r.json()).then(h=>{
  const badge = v => v ? '<span class="ok">正常</span>' : '<span class="bad">未连通</span>';
  document.getElementById('root').innerHTML = `
    <div class="card"><table>
      <tr><th>digiCamControl（5513）</th><td>${badge(h.dccReachable)}</td></tr>
      <tr><th>实时取景（5514/live）</th><td>${badge(h.liveReachable)}</td></tr>
      <tr><th>已同步照片</th><td>${h.syncedCount} 张</td></tr>
      <tr><th>本地目录</th><td><code>${h.folder}</code></td></tr>
    </table></div>
    <div class="card">
      <div class="sub">手机侧填这个地址（App → 实时监看 → 网络中继）：<br>
      <code>http://${h.localIP}:${h.port}/live</code></div>
      <div class="sub">照片目录：<code>http://${h.localIP}:${h.port}/photos</code></div>
    </div>`;
}).catch(e=>{ document.getElementById('root').textContent = '读取状态失败：'+e; });
</script></body></html>
"""


def local_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except Exception:  # noqa: BLE001
        return "127.0.0.1"
    finally:
        sock.close()


@dataclass
class RelayState:
    client: DccClient
    folder: Path
    synced: set[str] = field(default_factory=set)
    last_error: Optional[str] = None
    sync_count: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)

    def downloaded_files(self) -> list[Path]:
        if not self.folder.is_dir():
            return []
        items = [p for p in self.folder.iterdir()
                 if p.is_file() and p.suffix.lower() in MEDIA_EXTS]
        return sorted(items, key=lambda p: p.stat().st_mtime, reverse=True)


class CameraRelayHandler(server.BaseHTTPRequestHandler):

    state: RelayState
    server_version = "LumiCameraRelay/1.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    def _json(self, status: int, payload) -> None:
        body = json.dumps(payload, ensure_ascii=False, indent=1).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, code: str, message: str) -> None:
        self._json(status, {"error": {"code": code, "message": message}})

    # -- GET --------------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        state = type(self).state

        if path in ("/", "/index.html"):
            body = STATUS_PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/health":
            dcc_ok = False
            try:
                dcc_ok = state.client.ping()
            except Exception:  # noqa: BLE001
                pass
            live_ok = False
            try:
                with state.client.open_live_stream() as stream:
                    live_ok = stream.status == 200
            except Exception:  # noqa: BLE001
                live_ok = False
            self._json(200, {
                "running": True,
                "dccReachable": dcc_ok,
                "liveReachable": live_ok,
                "syncedCount": len(state.downloaded_files()),
                "folder": str(state.folder),
                "lastError": state.last_error,
                "localIP": local_ip(),
                "port": self.server.server_address[1],
            })
            return

        if path == "/photos":
            files = state.downloaded_files()
            self._json(200, {
                "count": len(files),
                "photos": [
                    {
                        "name": p.name,
                        "size": p.stat().st_size,
                        "modified": p.stat().st_mtime,
                        "url": f"/photo/{p.name}",
                    }
                    for p in files
                ],
            })
            return

        if path.startswith("/photo/"):
            name = urllib.parse.unquote(path[len("/photo/"):])
            # 只允许取本地目录里的直接文件 —— 文件名来自 URL，必须当作不可信输入
            if "/" in name or "\\" in name or name.startswith("."):
                self._error(400, "bad_name", "文件名不合法")
                return
            target = state.folder / name
            if not target.is_file():
                self._error(404, "not_found", f"没有这张照片：{name}")
                return
            data = target.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if path == "/live":
            # 把 digiCamControl 的 MJPEG 原样转发过去。
            # 不重新编码：中间少一道解码/编码，延迟更低，画质也不受影响。
            try:
                upstream = state.client.open_live_stream()
            except DccError as exc:
                self._error(502, "live_unavailable",
                            f"{exc}\n提示：实时取景需要先在 digiCamControl 界面里手动开启。")
                return
            self.send_response(200)
            self.send_header("Content-Type",
                             upstream.headers.get("Content-Type", "multipart/x-mixed-replace"))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                while True:
                    chunk = upstream.read(32 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except Exception:  # noqa: BLE001
                pass
            finally:
                upstream.close()
            return

        self._error(404, "not_found", f"没有这个端点：{path}")

    # -- POST -------------------------------------------------------------

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path != "/capture":
            self._error(404, "not_found", f"没有这个端点：{path}")
            return
        try:
            result = type(self).state.client.capture()
            self._json(200, {"ok": True, "response": result})
        except DccError as exc:
            self._error(502, "capture_failed", str(exc))


# ---------------------------------------------------------------------------
# 后台同步
# ---------------------------------------------------------------------------

def sync_loop(state: RelayState, interval: float, stop: threading.Event) -> None:
    """轮询 digiCamControl 的会话列表，把新照片下载到本地。

    这就是「自动导入」的来源。相机端 MTP 传输不快，所以单线程串行即可。
    """
    while not stop.is_set():
        try:
            payload = state.client.session()
            names = extract_file_names(payload)
            state.last_error = None
        except DccError as exc:
            state.last_error = str(exc)
            stop.wait(interval)
            continue

        for name in names:
            if stop.is_set():
                return
            destination = state.folder / name
            if destination.exists() and destination.stat().st_size > 0:
                continue
            try:
                data = state.client.image(name)
                if not data:
                    continue
                # 先写临时文件再改名：中断不会留下半个文件被当成「已下载」
                temp = destination.with_suffix(destination.suffix + ".part")
                temp.write_bytes(data)
                temp.replace(destination)
                with state.lock:
                    state.sync_count += 1
                print(f"  ↓ 同步 {name}  {len(data) / 1024:.0f} KB")
            except DccError as exc:
                state.last_error = f"{name}: {exc}"
                print(f"  ✗ {name} 下载失败：{exc}", file=sys.stderr)

        stop.wait(interval)


# ---------------------------------------------------------------------------
# 命令行
# ---------------------------------------------------------------------------

def probe(client: DccClient) -> int:
    """把每个接口的原始响应原样打出来。

    **装好 digiCamControl 之后第一件事就跑这个。** 官方文档只给了端点，
    没给响应结构；先看清真实数据，再写解析，比按猜测写一个脆弱解析器强得多。
    """
    print("=" * 70)
    print("  digiCamControl 接口探测")
    print("=" * 70)
    print(f"  webserver : {client.base}")
    print(f"  实时取景  : {client.live_base}/live")
    print()

    checks = [
        ("webserver 是否可达", lambda: client._get("/")[1]),
        ("session.json 原始内容", lambda: client._get("/session.json")[0][:1500]),
        ("lastcaptured", client.last_captured),
    ]
    for label, fn in checks:
        print(f"--- {label} ---")
        try:
            print("   ", str(fn())[:1500])
        except Exception as exc:  # noqa: BLE001
            print(f"    ✗ {type(exc).__name__}: {exc}")
        print()

    print("--- 实时取景流（只读头部，不拉全流）---")
    try:
        stream = client.open_live_stream()
        print("    HTTP", stream.status)
        print("    Content-Type:", stream.headers.get("Content-Type"))
        chunk = stream.read(256)
        print(f"    首 256 字节（{'JPEG 头' if chunk[:2] == b'\\xff\\xd8' else '非 JPEG'}）:", chunk[:32])
        stream.close()
    except Exception as exc:  # noqa: BLE001
        print(f"    ✗ {type(exc).__name__}: {exc}")
        print("    提示：实时取景需要先在 digiCamControl 界面里手动开启。")

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="把 digiCamControl 的实时取景与照片收拢成一个地址，给 LUMI App 用。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--host", default="0.0.0.0", help="本中继监听地址（默认 0.0.0.0）")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"本中继端口（默认 {DEFAULT_PORT}）")
    parser.add_argument("--dcc-host", default=DEFAULT_DCC_HOST, help="digiCamControl 所在主机")
    parser.add_argument("--dcc-port", type=int, default=DEFAULT_DCC_PORT, help="digiCamControl webserver 端口（默认 5513）")
    parser.add_argument("--live-port", type=int, default=DEFAULT_LIVE_PORT, help="digiCamControl 实时取景端口（默认 5514）")
    parser.add_argument("--folder", default=None,
                        help="照片同步到哪个目录（默认 用户目录/LUMI-Camera）")
    parser.add_argument("--interval", type=float, default=5.0, help="轮询间隔秒数（默认 5）")
    parser.add_argument("--probe", action="store_true",
                        help="只探测 digiCamControl 的接口响应，不启动中继")
    parser.add_argument("--no-sync", action="store_true", help="不自动同步照片，只做实时取景转发")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    folder = Path(args.folder) if args.folder else (Path.home() / "LUMI-Camera")
    folder.mkdir(parents=True, exist_ok=True)

    client = DccClient(host=args.dcc_host, port=args.dcc_port, live_port=args.live_port)

    if args.probe:
        return probe(client)

    state = RelayState(client=client, folder=folder)
    handler = type("BoundCameraRelayHandler", (CameraRelayHandler,), {"state": state})
    httpd = server.ThreadingHTTPServer((args.host, args.port), handler)

    stop = threading.Event()
    if not args.no_sync:
        threading.Thread(target=sync_loop, args=(state, args.interval, stop), daemon=True).start()

    print("=" * 66)
    print("  LUMI 相机中继已启动")
    print("=" * 66)
    print(f"  digiCamControl : {client.base}（webserver）")
    print(f"  实时取景源     : {client.live_base}/live")
    print(f"  照片同步目录   : {folder}")
    print(f"  自动同步       : {'关闭' if args.no_sync else f'每 {args.interval:.0f} 秒一次'}")
    print()
    print("  手机侧填（App → 实时监看 → 网络中继）：")
    print(f"      http://{local_ip()}:{args.port}/live")
    print()
    print("  电脑上先自测（浏览器打开）：")
    print(f"      http://127.0.0.1:{args.port}")
    print()
    print("  Ctrl+C 停止")
    print("=" * 66)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        stop.set()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
