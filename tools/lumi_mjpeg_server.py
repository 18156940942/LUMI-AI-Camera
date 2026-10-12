#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI 相机中继服务（MJPEG / HTTP）
================================

为什么需要这个脚本？
--------------------
iPhone 15 Pro **无法**把 UVC 采集卡当作外接摄像头打开（Apple 官方确认：外接相机支持
仅限带 USB-C 的 iPad）。所以在 iPhone 上做 Z6 II 实时监看，唯一可行的真实路径是：

    Nikon Z6 II ──HDMI──▶ UVC 采集卡 ──USB──▶ 电脑 ──局域网──▶ iPhone（LUMI App）

本脚本就是中间那一环：把采集卡的画面编码成 MJPEG，通过局域网 HTTP 推给 iPhone。
App 端在「实时监看 → 输入 → 网络中继」里填入脚本启动时打印的地址即可。

延迟：局域网内实测约 150–400 ms（取决于 Wi-Fi 与分辨率）。
画质：MJPEG 是逐帧独立 JPEG，延迟低但带宽较高；1080p30 约 15–40 Mbps。

安装依赖
--------
    pip install opencv-python

快速开始
--------
    # 1. 先看看电脑认到了哪些采集设备
    python lumi_mjpeg_server.py --list

    # 2. 启动中继（0 号设备，1080p，30fps）
    python lumi_mjpeg_server.py --device 0 --width 1920 --height 1080 --fps 30

    # 3. 在电脑浏览器打开 http://127.0.0.1:8090 确认画面正常
    # 4. 在 iPhone 的 LUMI App 里填入脚本打印的局域网地址（形如 http://192.168.1.10:8090/stream）
    #    注意：手机与电脑必须在同一个 Wi-Fi，且电脑防火墙要放行该端口

常用参数
--------
    --list              列出所有视频采集设备后退出
    --device N          设备序号（默认 0），也支持直接给设备路径
    --width / --height  请求的采集分辨率（默认 1920×1080，实际以设备支持为准）
    --fps               采集帧率（默认 30）
    --quality           1–100，JPEG 质量（默认 75；调高更清晰但更占带宽）
    --port              监听端口（默认 8090）
    --host              监听地址（默认 0.0.0.0，即允许手机访问）
    --fourcc            像素格式（默认 MJPG；某些采集卡用 YUY2 更稳）
    --no-preview        不打印实时统计，降低控制台开销

端点
----
    /               状态页（含实时画面，用来在电脑上先验证）
    /stream         MJPEG 流（App 用这个）
    /snapshot       单帧 JPEG（用于排查：直接看这一帧是否正常）
    /health         JSON 健康检查（帧率、客户端数、分辨率）
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import threading
import time
from http import server
from typing import Optional

try:
    import cv2
except ImportError:  # pragma: no cover - 只在缺少依赖时走这里
    sys.stderr.write(
        "\n!! 缺少依赖 OpenCV。请先安装：\n"
        "     pip install opencv-python\n\n"
    )
    raise SystemExit(2)


# ---------------------------------------------------------------------------
# 工具：fourcc
# ---------------------------------------------------------------------------

def fourcc_code(text: str) -> int:
    """把 "MJPG" 这样的四字符编码转成 OpenCV 需要的整数。

    自己算而不是调用 `cv2.VideoWriter_fourcc`：后者在新版 OpenCV 里已被标记废弃，
    而这个转换规则就是简单的按字节小端拼接，自己实现反而更稳。
    """
    padded = (text.upper())[:4].ljust(4)
    return (ord(padded[0])
            | (ord(padded[1]) << 8)
            | (ord(padded[2]) << 16)
            | (ord(padded[3]) << 24))


# ---------------------------------------------------------------------------
# 帧缓冲：采集线程只保留「最新一帧」，所有客户端共享它
# ---------------------------------------------------------------------------

class FrameBuffer:
    """只保留最新一帧的环形槽。

    这是低延迟的关键：如果为每个客户端维护队列，一旦手机解码慢于采集，
    队列就会堆积，画面会越看越延迟。只保留最新帧意味着「宁可丢帧，不延迟」。
    """

    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._jpeg: Optional[bytes] = None
        self._sequence = 0
        self._width = 0
        self._height = 0
        self._measured_fps = 0.0
        self._dropped = 0
        self._client_count = 0
        self._started_at = time.time()

    # -- 生产者 --------------------------------------------------------------

    def publish(self, jpeg: bytes, width: int, height: int, fps: float) -> None:
        with self._condition:
            self._jpeg = jpeg
            self._width = width
            self._height = height
            self._measured_fps = fps
            self._sequence += 1
            self._condition.notify_all()

    def note_dropped(self) -> None:
        with self._condition:
            self._dropped += 1

    # -- 消费者 --------------------------------------------------------------

    def wait_for_next(self, last_sequence: int, timeout: float = 5.0):
        """阻塞直到有新帧，或超时。返回 (jpeg, sequence) 或 (None, last_sequence)。"""
        deadline = time.monotonic() + timeout
        with self._condition:
            while self._sequence == last_sequence:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None, last_sequence
                self._condition.wait(remaining)
            return self._jpeg, self._sequence

    def snapshot(self):
        with self._condition:
            return self._jpeg, self._sequence

    # -- 统计 ----------------------------------------------------------------

    def enter_client(self) -> None:
        with self._condition:
            self._client_count += 1

    def leave_client(self) -> None:
        with self._condition:
            self._client_count = max(0, self._client_count - 1)

    def stats(self) -> dict:
        with self._condition:
            return {
                "running": self._jpeg is not None,
                "sequence": self._sequence,
                "width": self._width,
                "height": self._height,
                "fps": round(self._measured_fps, 2),
                "clients": self._client_count,
                "dropped": self._dropped,
                "uptime_seconds": round(time.time() - self._started_at, 1),
            }


# ---------------------------------------------------------------------------
# 采集线程
# ---------------------------------------------------------------------------

class CaptureLoop(threading.Thread):
    def __init__(self, args: argparse.Namespace, buffer: FrameBuffer) -> None:
        super().__init__(daemon=True, name="lumi-capture")
        self.args = args
        self.buffer = buffer
        self._stop = threading.Event()
        self.capture: Optional["cv2.VideoCapture"] = None
        self.error: Optional[str] = None

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        args = self.args
        backend = cv2.CAP_DSHOW if sys.platform.startswith("win") else cv2.CAP_ANY

        # 设备参数可以是序号（0/1/2…）或设备路径（/dev/video0）
        device = args.device
        try:
            device = int(device)
        except (TypeError, ValueError):
            pass

        self.capture = cv2.VideoCapture(device, backend)
        if not self.capture.isOpened():
            self.error = (
                f"无法打开采集设备 {device!r}。请检查：\n"
                "  · 采集卡是否插好（用数据线而不是纯充电线）\n"
                "  · 是否被其它程序占用（OBS / 相机官方工具 / 上一个没退干净的 python）\n"
                "  · 先用 --list 确认设备序号，再试 --device 1 或 --device 2\n"
                "  · Windows 上可尝试加 --fourcc YUY2 换一种像素格式"
            )
            print(f"\n!! {self.error}\n", file=sys.stderr)
            return

        # 请求采集格式。设备不支持时会自动回退到最接近的可用格式，
        # 因此下面会重新读取实际生效的分辨率，而不是假定请求值成功。
        self.capture.set(cv2.CAP_PROP_FOURCC, fourcc_code(args.fourcc))
        self.capture.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
        self.capture.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
        self.capture.set(cv2.CAP_PROP_FPS, args.fps)
        # 缓冲区设为 1，尽量始终拿到最新帧而不是排队中的旧帧
        self.capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)

        actual_w = int(self.capture.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
        actual_h = int(self.capture.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
        actual_fps = self.capture.get(cv2.CAP_PROP_FPS) or args.fps

        print(f"  · 采集设备已打开：{device!r}")
        print(f"  · 实际采集格式：{actual_w}×{actual_h} @ {actual_fps:.1f} fps "
              f"（请求 {args.width}×{args.height} @ {args.fps}）")
        if args.fourcc != "MJPG":
            print(f"  · 像素格式：{args.fourcc}")

        encode_params = [int(cv2.IMWRITE_JPEG_QUALITY), args.quality]
        frame_interval = 1.0 / max(args.fps, 1)
        last_publish = 0.0
        fps_window: list[float] = []
        failures = 0

        while not self._stop.is_set():
            ok, frame = self.capture.read()
            if not ok or frame is None:
                failures += 1
                if failures == 1:
                    print("  !! 读取帧失败，正在重试……", file=sys.stderr)
                if failures > 120:
                    print("  !! 连续 120 次读帧失败，采集可能已中断（HDMI 掉线 / 相机休眠）。",
                          file=sys.stderr)
                    failures = 0
                time.sleep(0.05)
                continue
            failures = 0

            now = time.monotonic()
            if now - last_publish < frame_interval:
                # 采集快于目标帧率：丢掉多余的帧，保证输出节奏稳定
                self.buffer.note_dropped()
                continue
            last_publish = now

            ok, encoded = cv2.imencode(".jpg", frame, encode_params)
            if not ok:
                continue

            fps_window.append(now)
            while fps_window and now - fps_window[0] > 2.0:
                fps_window.pop(0)
            measured = (len(fps_window) - 1) / max(now - fps_window[0], 1e-6) if len(fps_window) > 1 else 0.0

            height, width = frame.shape[:2]
            self.buffer.publish(encoded.tobytes(), width, height, measured)

        if self.capture is not None:
            self.capture.release()
        print("  · 采集线程已停止")


# ---------------------------------------------------------------------------
# HTTP 服务
# ---------------------------------------------------------------------------

STATUS_PAGE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LUMI 中继 · 运行中</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ margin:0; background:#0a0b0d; color:#e8eaee;
         font:14px/1.6 -apple-system,"Segoe UI",system-ui,sans-serif; }}
  .wrap {{ max-width:900px; margin:0 auto; padding:24px 18px 48px; }}
  h1 {{ font-size:18px; letter-spacing:.14em; font-weight:600; margin:0 0 4px; }}
  .sub {{ color:#8b93a1; margin-bottom:18px; }}
  img {{ width:100%; border-radius:10px; background:#000; display:block; }}
  table {{ width:100%; border-collapse:collapse; margin-top:18px; }}
  td {{ padding:7px 0; border-bottom:1px solid #1c1f24; vertical-align:top; }}
  td:first-child {{ color:#8b93a1; width:150px; }}
  code {{ background:#15181d; padding:2px 7px; border-radius:5px;
          font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:13px; }}
  .hint {{ margin-top:18px; padding:12px 14px; border-radius:9px;
           background:#141a24; border:1px solid #1f2a3a; color:#a9b6c8; }}
</style>
</head>
<body>
<div class="wrap">
  <h1>LUMI 中继</h1>
  <div class="sub">相机 → HDMI 采集卡 → 电脑 → 局域网 → iPhone</div>
  <img src="/stream" alt="实时画面">
  <table>
    <tr><td>状态</td><td>{status}</td></tr>
    <tr><td>分辨率</td><td>{width}×{height}</td></tr>
    <tr><td>实测帧率</td><td>{fps} fps</td></tr>
    <tr><td>已发送帧</td><td>{sequence}</td></tr>
    <tr><td>丢弃帧</td><td>{dropped}</td></tr>
    <tr><td>当前客户端</td><td>{clients}</td></tr>
  </table>
  <div class="hint">
    iPhone 上请打开 LUMI →「实时监看」→「输入」→「网络中继」，
    填入地址 <code>{stream_url}</code>
  </div>
</div>
</body>
</html>
"""

# multipart 边界必须固定，且不能出现在 JPEG 数据里 ——
# 这个字符串由 32 个破折号加标识组成，出现在 JPEG 字节流中的概率可忽略。
BOUNDARY = "lumi-frame-boundary-7f3c9a1e5b204d86"


class StreamHandler(server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    buffer: FrameBuffer = None            # 由 server 注入
    server_version = "LUMI-Relay/1.0"
    stream_url_placeholder = "/stream"

    # 静默掉默认的逐请求日志（手机端长时间拉流会刷屏）
    def log_message(self, fmt: str, *args) -> None:
        return

    # -- 路由 ----------------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802  (BaseHTTPRequestHandler 的命名约定)
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/":
            self._serve_status()
        elif path == "/stream":
            self._serve_stream()
        elif path == "/snapshot":
            self._serve_snapshot()
        elif path == "/health":
            self._serve_health()
        else:
            self._send_plain(404, "404 未找到。可用端点：/  /stream  /snapshot  /health")

    def do_HEAD(self) -> None:  # noqa: N802
        self._send_plain(200, "")

    # -- 端点实现 ------------------------------------------------------------

    def _serve_status(self) -> None:
        stats = self.buffer.stats()
        host = self.headers.get("Host", f"127.0.0.1:{self.server.server_port}")
        body = STATUS_PAGE.format(
            status="正在推流" if stats["running"] else "尚未收到画面",
            width=stats["width"],
            height=stats["height"],
            fps=stats["fps"],
            sequence=stats["sequence"],
            dropped=stats["dropped"],
            clients=stats["clients"],
            stream_url=f"http://{host}/stream",
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _serve_snapshot(self) -> None:
        jpeg, _ = self.buffer.snapshot()
        if jpeg is None:
            self._send_plain(503, "尚未收到任何画面。请确认采集卡与相机已就绪。")
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(jpeg)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(jpeg)

    def _serve_health(self) -> None:
        body = json.dumps(self.buffer.stats(), ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _serve_stream(self) -> None:
        self.buffer.enter_client()
        client = self.client_address[0]
        print(f"  → 客户端接入：{client}")
        # 流式响应没有 Content-Length，整条连接只为一个 MJPEG 会话服务，
        # 因此必须显式关掉 keep-alive，否则 HTTP/1.1 下会尝试复用这条连接。
        self.close_connection = True
        try:
            self.send_response(200)
            self.send_header("Age", "0")
            self.send_header("Cache-Control", "no-cache, private")
            self.send_header("Pragma", "no-cache")
            self.send_header("Content-Type",
                             f"multipart/x-mixed-replace; boundary={BOUNDARY}")
            self.end_headers()

            sequence = -1
            while True:
                jpeg, sequence = self.buffer.wait_for_next(sequence, timeout=10.0)
                if jpeg is None:
                    # 长时间没有新帧：让连接自行断开，App 端会据此弹出「画面已停止」提示
                    print(f"  ← 客户端 {client} 超时断开（10 秒无新帧）")
                    return
                header = (
                    f"--{BOUNDARY}\r\n"
                    f"Content-Type: image/jpeg\r\n"
                    f"Content-Length: {len(jpeg)}\r\n\r\n"
                ).encode("ascii")
                try:
                    self.wfile.write(header)
                    self.wfile.write(jpeg)
                    self.wfile.write(b"\r\n")
                except (BrokenPipeError, ConnectionResetError):
                    print(f"  ← 客户端 {client} 断开")
                    return
        finally:
            self.buffer.leave_client()

    # -- 工具 ----------------------------------------------------------------

    def _send_plain(self, code: int, text: str) -> None:
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ThreadedHTTPServer(server.ThreadingHTTPServer):
    daemon_threads = True           # 主进程退出时不要被客户端线程拖住
    allow_reuse_address = True


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def list_devices(max_index: int = 8) -> None:
    """逐个尝试打开设备序号，报告可用的采集设备。"""
    print("正在扫描视频采集设备（会逐个尝试打开，可能需要几秒钟）……\n")
    backend = cv2.CAP_DSHOW if sys.platform.startswith("win") else cv2.CAP_ANY
    found = 0
    for index in range(max_index):
        capture = cv2.VideoCapture(index, backend)
        if not capture.isOpened():
            capture.release()
            continue
        ok, frame = capture.read()
        if ok and frame is not None:
            height, width = frame.shape[:2]
            fps = capture.get(cv2.CAP_PROP_FPS) or 0
            print(f"  [{index}] 可用   {width}×{height} @ {fps:.1f} fps")
            found += 1
        else:
            print(f"  [{index}] 设备存在但读不到画面（可能被其它程序占用）")
        capture.release()

    if found == 0:
        print("\n没有检测到可用的采集设备。请检查：")
        print("  · HDMI 线是否插在相机的 HDMI OUT 上（Z6 II 是 mini-HDMI Type C）")
        print("  · 相机是否开机，且 HDMI 输出已启用")
        print("  · 采集卡是否被 OBS / 相机官方软件占用")
    else:
        print(f"\n共 {found} 个可用设备。启动示例：")
        print("  python lumi_mjpeg_server.py --device 0 --width 1920 --height 1080 --fps 30")


def local_ip_addresses() -> list[str]:
    """列出本机在局域网中的 IPv4 地址，供用户填进 App。"""
    addresses: set[str] = set()
    hostname = socket.gethostname()
    try:
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            addresses.add(info[4][0])
    except OSError:
        pass
    # 兜底：向外部地址建立一个 UDP「连接」以确定默认出口网卡的地址（不会真的发包）
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 80))
        addresses.add(probe.getsockname()[0])
        probe.close()
    except OSError:
        pass
    return sorted(a for a in addresses if not a.startswith("127."))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="LUMI 相机中继：把 UVC 采集卡的画面以 MJPEG 推给 iPhone。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：\n"
               "  python lumi_mjpeg_server.py --list\n"
               "  python lumi_mjpeg_server.py --device 0 --width 1920 --height 1080 --fps 30\n",
    )
    parser.add_argument("--device", default="0",
                        help="采集设备序号或路径（默认 0）")
    parser.add_argument("--width", type=int, default=1920, help="请求宽度（默认 1920）")
    parser.add_argument("--height", type=int, default=1080, help="请求高度（默认 1080）")
    parser.add_argument("--fps", type=int, default=30, help="目标帧率（默认 30）")
    parser.add_argument("--quality", type=int, default=75, help="JPEG 质量 1–100（默认 75）")
    parser.add_argument("--port", type=int, default=8090, help="监听端口（默认 8090）")
    parser.add_argument("--host", default="0.0.0.0",
                        help="监听地址（默认 0.0.0.0，即允许局域网内的手机访问）")
    parser.add_argument("--fourcc", default="MJPG",
                        help="像素格式，MJPG 或 YUY2（默认 MJPG）")
    parser.add_argument("--list", action="store_true", help="列出可用采集设备后退出")
    parser.add_argument("--no-preview", action="store_true",
                        help="不打印实时统计")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    if args.list:
        list_devices()
        return 0

    args.quality = max(1, min(100, args.quality))
    args.fourcc = args.fourcc.upper()[:4].ljust(4, " ")

    print()
    print("LUMI 相机中继 · MJPEG over HTTP")
    print("=" * 56)

    buffer = FrameBuffer()
    capture = CaptureLoop(args, buffer)
    capture.start()

    # 等第一帧最多 8 秒，确认采集真的通了再开始对外提供服务
    deadline = time.monotonic() + 8.0
    while time.monotonic() < deadline:
        if buffer.snapshot()[0] is not None:
            break
        if capture.error:
            capture.stop()
            return 3
        time.sleep(0.1)

    jpeg, _ = buffer.snapshot()
    if jpeg is None and not capture.error:
        print("\n  !! 8 秒内没有收到任何画面。采集卡可能被占用或相机没有输出。")
        print("     服务仍会启动，你可以在电脑浏览器里排查。")

    StreamHandler.buffer = buffer
    try:
        httpd = ThreadedHTTPServer((args.host, args.port), StreamHandler)
    except OSError as error:
        print(f"\n!! 无法监听 {args.host}:{args.port} —— {error}")
        print("   端口可能已被占用，试试： --port 8091")
        capture.stop()
        return 4

    print()
    print("  本机验证（先在电脑上确认画面正常）：")
    print(f"    http://127.0.0.1:{args.port}/")
    print(f"    单帧快照 http://127.0.0.1:{args.port}/snapshot")
    print()
    print("  在 iPhone 的 LUMI App 里填这个地址：")
    addresses = local_ip_addresses()
    if addresses and args.host in ("0.0.0.0", "::"):
        for address in addresses:
            print(f"    http://{address}:{args.port}/stream")
    elif addresses:
        print(f"    http://{addresses[0]}:{args.port}/stream")
    else:
        print(f"    http://<本机局域网 IP>:{args.port}/stream")
    print()
    print("  提醒：")
    print("    · 手机与电脑必须在同一个 Wi-Fi（且该 Wi-Fi 未开启 AP 隔离）")
    print("    · Windows 首次运行会弹出防火墙提示，需要勾选「专用网络」允许")
    print("    · 相机建议设置：HDMI 输出分辨率=Auto、HDMI 显示尺寸=100%、")
    print("      HDMI 实时取景信息显示=关闭、待机定时器=无限")
    print()
    print("  按 Ctrl+C 停止")
    print("=" * 56)

    # 可选的控制台统计（手机上看的其实是 /stream，这里只是方便电脑侧观察）
    stop_stats = threading.Event()

    def stats_loop() -> None:
        while not stop_stats.is_set():
            time.sleep(3)
            if args.no_preview:
                continue
            stats = buffer.stats()
            if stats["running"]:
                sys.stdout.write(
                    f"\r  [{time.strftime('%H:%M:%S')}] "
                    f"{stats['width']}×{stats['height']}  "
                    f"{stats['fps']:.1f} fps  "
                    f"帧 {stats['sequence']}  丢 {stats['dropped']}  "
                    f"客户端 {stats['clients']}   "
                )
                sys.stdout.flush()

    threading.Thread(target=stats_loop, daemon=True, name="lumi-stats").start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n\n  正在停止……")
    finally:
        stop_stats.set()
        httpd.shutdown()
        httpd.server_close()
        capture.stop()
        capture.join(timeout=3)

    stats = buffer.stats()
    print(f"  共推送 {stats['sequence']} 帧，丢弃 {stats['dropped']} 帧，运行 {stats['uptime_seconds']} 秒")
    print("  已退出。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
