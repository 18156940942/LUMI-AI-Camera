#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阿里云「人脸美颜」云端精修适配层。

角色与 tools/lumi_volc_beauty.py 完全一致：把「一条 LUMI 精修预设」翻译成
一次云端美颜调用，把结果图片取回来。App 侧接口（/health /presets /retouch）
与本地中继、火山适配层保持同一形态，**App 不需要任何改动**。

为什么选阿里云（相对火山引擎）
==============================
  · 个人实名认证即可自助开通，不需要商务流程买「创点」；
  · 按量 0.03 元/次，每月前 100 次免费；
  · FaceBeauty 是**同步**接口 —— 一次调用直接返回结果 URL，
    不像火山那样要提交任务再轮询。

调用链（同步一步）
==================
    LUMI App ──► 本脚本转发端点 ──► POST facebody.cn-shanghai.aliyuncs.com
                                    Action=FaceBeauty
                                    (Sharp / Smooth / White，均为 0~1 浮点)
                ◄── Data.ImageURL（临时地址，30 分钟有效）
                ◄── 本脚本立即下载图片 ──► 回给 App

为什么结果要立刻下载：官方明确该 URL 30 分钟后失效。本脚本每次调用完
当场取回字节流，App 拿到的永远是图片本体，不受有效期影响。

已核实（来自阿里云官方文档「人脸美颜 FaceBeauty」）：
  · endpoint = facebody.cn-shanghai.aliyuncs.com，Action = FaceBeauty
  · 必填参数：ImageURL（或 SDK 文件流直传）＋ Sharp + Smooth + White（0~1）
  · 输入限制：JPEG/JPG/PNG/BMP，≤3MB，分辨率 10×10 ~ <2000×2000
  · 返回：Data.ImageURL（临时，30 分钟）
  · 计费：按量 0.03 元/次（每月前 100 次免费），调用失败不计费

能力边界（如实说，不假装）：
  · FaceBeauty 只有磨皮 / 锐化 / 美白三档，**没有瘦脸、美体、美妆**；
    火山那套 volc.slimface / volc.body 对应的能力这里不存在，
    所以预设目录里就没有它们，而不是做了个没效果的同名预设。
  · 想要瘦脸需要另接 FaceTidyup（智能瘦脸）、美体要接 BeautifyBody ——
    都是独立接口，本脚本刻意先不碰，等真有需要再加。

用法
====

    set ALIYUN_AK=你的AccessKey ID
    set ALIYUN_SK=你的AccessKey Secret

    python tools/lumi_aliyun_beauty.py --presets                 # 看预设与参数映射
    python tools/lumi_aliyun_beauty.py --selftest                # 不联网自检
    python tools/lumi_aliyun_beauty.py --probe --image a.jpg      # 真实调用一次
    python tools/lumi_aliyun_beauty.py --image a.jpg --out out.jpg

    # 作为 HTTP 服务跑（给 App 用）
    python tools/lumi_aliyun_beauty.py --serve --port 8092

依赖（只在这一条链路上需要，装进 venv）：
    pip install alibabacloud_facebody20191230

AK/SK 从哪来
============
阿里云控制台 → 右上角头像 → AccessKey 管理 → 创建 AccessKey。
（建议用 RAM 子账号并授予 AliyunVIAPIFullAccess，不要用主账号密钥长期跑。）
开通服务：控制台搜「视觉智能开放平台」→ 人脸人体 → 开通（个人实名即可）。
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

ENDPOINT = "facebody.cn-shanghai.aliyuncs.com"
ACTION = "FaceBeauty"
#: 官方输入上限：3MB（文档两处写 3/4MB，取保守值）
MAX_IMAGE_BYTES = 3 * 1024 * 1024
#: 2000×2000 上限，超了就等比缩到最长边 1900
MAX_SIDE = 1900


class AliError(Exception):
    """阿里云接口返回的业务错误，或本地配置错误。"""

    def __init__(self, message: str, http_status: int | None = None) -> None:
        super().__init__(message)
        self.http_status = http_status


# ---------------------------------------------------------------------------
# 预设 → 阿里云参数
# ---------------------------------------------------------------------------

@dataclass
class AliPreset:
    """一条云端预设：LUMI 侧 id + FaceBeauty 三参数基准值（0~1）。"""

    id: str
    title: str
    detail: str
    sharp: float
    smooth: float
    white: float


PRESETS: dict[str, AliPreset] = {
    "ali.natural": AliPreset(
        id="ali.natural",
        title="云端自然美颜",
        detail="轻磨皮 + 轻美白 + 保清晰。最保守的一条，适合大多数场合先试。",
        sharp=0.30, smooth=0.30, white=0.10,
    ),
    "ali.clean": AliPreset(
        id="ali.clean",
        title="云端干净肤色",
        detail="重磨皮 + 中美白。针对出油、肤质不均的皮肤，会明显柔化细节。",
        sharp=0.20, smooth=0.60, white=0.30,
    ),
    "ali.fresh": AliPreset(
        id="ali.fresh",
        title="云端透亮人像",
        detail="锐化 + 中磨皮 + 中美白。追求「干净但保留质感」的中间档。",
        sharp=0.45, smooth=0.45, white=0.25,
    ),
}


def build_request(preset: AliPreset, intensity: int) -> dict[str, float]:
    """把一条预设 + 用户强度，翻译成 FaceBeauty 的三个 0~1 参数。

    强度是 LUMI 自己的概念（0–100）。按 ``scale = intensity / 100`` 等比
    缩放每项基准值，并夹到 [0, 1]。
    """
    scale = max(0.0, min(1.0, intensity / 100.0))
    return {
        "Sharp": round(min(1.0, max(0.0, preset.sharp * scale)), 4),
        "Smooth": round(min(1.0, max(0.0, preset.smooth * scale)), 4),
        "White": round(min(1.0, max(0.0, preset.white * scale)), 4),
    }


def _maybe_downscale(image: bytes) -> bytes:
    """超过官方限制时尽力压一压；办不到就如实报错。"""
    if len(image) <= MAX_IMAGE_BYTES:
        return image
    try:
        import cv2  # noqa: PLC0415 —— 可选依赖，没有就报错
        import numpy as np  # noqa: PLC0415
    except ImportError:
        raise AliError(
            f"图片 {len(image)} 字节，超过阿里云 {MAX_IMAGE_BYTES} 字节上限；"
            "本机没装 opencv，无法自动缩图。请换小图或手动缩小后再试。"
        ) from None
    import numpy as np

    buf = np.frombuffer(image, dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        raise AliError("图片解码失败（不是合法的 JPEG/PNG？）")
    h, w = img.shape[:2]
    longest = max(h, w)
    if longest > MAX_SIDE:
        ratio = MAX_SIDE / longest
        img = cv2.resize(img, (int(w * ratio), int(h * ratio)), interpolation=cv2.INTER_AREA)
    ok, enc = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 92])
    if not ok or len(enc.tobytes()) > MAX_IMAGE_BYTES:
        raise AliError("缩图后仍超过阿里云大小上限，请手动处理后再试。")
    return enc.tobytes()


# ---------------------------------------------------------------------------
# 客户端（阿里云官方 SDK；本地文件用 SDK 的 advance 文件流直传，免 OSS）
# ---------------------------------------------------------------------------

@dataclass
class AliBeautyClient:
    """阿里云人脸美颜的最小客户端。

    依赖官方 SDK ``alibabacloud_facebody20191230``（装在 venv 里）。
    本地图片走 SDK 的 advance 文件流通道，**不需要**先传 OSS。
    """

    access_key_id: str
    access_key_secret: str
    endpoint: str = ENDPOINT
    timeout: float = 60.0
    debug: bool = False

    def _client(self) -> Any:
        try:
            from alibabacloud_facebody20191230.client import Client as FacebodyClient
            from alibabacloud_tea_openapi import models as open_models
        except ImportError as exc:
            raise AliError(
                "缺少阿里云 SDK：请先在当前 Python 环境执行 "
                "pip install alibabacloud_facebody20191230"
            ) from exc
        config = open_models.Config(
            access_key_id=self.access_key_id,
            access_key_secret=self.access_key_secret,
            endpoint=self.endpoint,
            read_timeout=int(self.timeout * 1000),
            connect_timeout=int(self.timeout * 1000),
        )
        return FacebodyClient(config)

    def beautify(self, image: bytes, preset: AliPreset, intensity: int) -> bytes:
        from alibabacloud_facebody20191230 import models as facebody_models
        from alibabacloud_tea_util import models as util_models

        image = _maybe_downscale(image)
        params = build_request(preset, intensity)
        if self.debug:
            print(f"[ali] POST https://{self.endpoint}/ Action={ACTION} {params}", file=sys.stderr)

        # advance 通道：文件流封装在 FaceBeautyAdvanceRequest.image_urlobject（BinaryIO），
        # 免 OSS 上传。注意：不是 FaceBeautyRequest + 独立 stream 参数（那是旧版签名）
        request = facebody_models.FaceBeautyAdvanceRequest(
            image_urlobject=io.BytesIO(image),
            sharp=params["Sharp"], smooth=params["Smooth"], white=params["White"],
        )
        runtime = util_models.RuntimeOptions(read_timeout=int(self.timeout * 1000),
                                             connect_timeout=int(self.timeout * 1000))
        client = self._client()
        try:
            resp = client.face_beauty_advance(request, runtime)
        except Exception as exc:  # noqa: BLE001 —— SDK 抛的类型随版本变，统一转译
            raise AliError(f"阿里云调用失败：{type(exc).__name__}: {exc}") from exc

        data = (resp.body.to_map() if resp is not None and resp.body else {}) or {}
        if self.debug:
            print("[ali] 原始响应:", json.dumps(data, ensure_ascii=False)[:500], file=sys.stderr)
        # to_map() 出的是 camelCase 线上格式（Data.ImageURL）；
        # 这里同时容错 snake_case，防止 SDK 版本差异
        inner = data.get("Data") or data.get("data") or {}
        result_url = inner.get("ImageURL") or inner.get("imageUrl") or inner.get("image_url")
        if not result_url:
            raise AliError(f"阿里云返回里没有 Data.ImageURL：{json.dumps(data, ensure_ascii=False)[:300]}")

        # 结果 URL 30 分钟失效 —— 立刻取回字节流
        try:
            req = urllib.request.Request(result_url, headers={"User-Agent": "lumi-aliyun-beauty/1.0"})
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.read()
        except Exception as exc:  # noqa: BLE001
            raise AliError(f"下载美颜结果失败：{type(exc).__name__}: {exc}") from exc


# ---------------------------------------------------------------------------
# 自检（不联网、不需要 AK/SK）
# ---------------------------------------------------------------------------

def selftest() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, extra: str = "") -> None:
        if cond:
            print(f"  ✓ {name}")
        else:
            failures.append(name)
            print(f"  ✗ {name}  {extra}")

    print("=== 1. 参数映射 ===")
    p = PRESETS["ali.natural"]
    r100 = build_request(p, 100)
    check("强度 100 保持基准值", r100 == {"Sharp": 0.30, "Smooth": 0.30, "White": 0.10}, str(r100))
    check("三个参数都在 0~1", all(0.0 <= v <= 1.0 for v in r100.values()), str(r100))
    r0 = build_request(p, 0)
    check("强度 0 → 全部归零", all(v == 0.0 for v in r0.values()), str(r0))
    r50 = build_request(p, 50)
    check("强度 50 约为基准一半", abs(r50["Sharp"] - 0.15) < 1e-9, str(r50))
    check("强度超界被夹住（150 → 等同 100）", build_request(p, 150) == r100)
    check("强度负值被夹住（-20 → 等同 0）", build_request(p, -20) == r0)

    print("\n=== 2. 每条预设都能构造出合法参数 ===")
    for pid, preset in PRESETS.items():
        r = build_request(preset, 60)
        ok = all(0.0 <= v <= 1.0 for v in r.values()) and set(r) == {"Sharp", "Smooth", "White"}
        check(f"{pid} 参数合法", ok, str(r))

    print("\n=== 3. multipart 解析（与 App 同形态） ===")
    from lumi_volc_beauty import _parse_multipart  # noqa: PLC0415 —— 复用同一实现

    body = (b"--B\r\nContent-Disposition: form-data; name=\"preset\"\r\n\r\nali.natural\r\n"
            b"--B\r\nContent-Disposition: form-data; name=\"image\"; filename=\"a.jpg\"\r\n"
            b"Content-Type: image/jpeg\r\n\r\n\x89PNGDATA\r\n--B--\r\n")
    fields, files = _parse_multipart("multipart/form-data; boundary=B", body)
    check("普通字段解析", fields.get("preset") == "ali.natural", str(fields))
    check("文件字段解析", files.get("image") == b"\x89PNGDATA", str(list(files)))

    print("\n=== 4. 诚实性：不提供能力外的预设 ===")
    check("没有假装的瘦脸/美体预设", all("slim" not in k and "body" not in k for k in PRESETS),
          str(list(PRESETS)))

    print()
    if failures:
        print(f"✗ {len(failures)} 项失败")
        return 1
    print(f"✓ 全部通过（{len(PRESETS)} 条预设）")
    return 0


# ---------------------------------------------------------------------------
# HTTP 转发服务（与本地中继、火山适配层同一接口形态）
# ---------------------------------------------------------------------------

def serve(host: str, port: int, token: str, debug: bool) -> int:
    from lumi_volc_beauty import _parse_multipart  # noqa: PLC0415

    ak = os.environ.get("ALIYUN_AK", "")
    sk = os.environ.get("ALIYUN_SK", "")

    class Handler(BaseHTTPRequestHandler):
        def _json(self, status: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _authorized(self) -> bool:
            if not token:
                return True
            auth = self.headers.get("Authorization", "")
            return auth == f"Bearer {token}"

        def do_GET(self) -> None:  # noqa: N802
            if self.path.startswith("/health"):
                self._json(200, {
                    "ok": True,
                    "provider": "aliyun-facebeauty",
                    "endpoint": ENDPOINT,
                    "has_credentials": bool(ak and sk),
                    "presets": len(PRESETS),
                })
                return
            if self.path.startswith("/presets"):
                self._json(200, {"presets": [
                    {"id": p.id, "title": p.title, "detail": p.detail} for p in PRESETS.values()
                ]})
                return
            self._json(404, {"error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            if not self.path.startswith("/retouch"):
                self._json(404, {"error": "not found"})
                return
            if not self._authorized():
                self._json(401, {"error": "unauthorized"})
                return
            content_type = self.headers.get("Content-Type", "")
            if "multipart/form-data" not in content_type:
                self._json(400, {"error": "需要 multipart/form-data"})
                return
            length = int(self.headers.get("Content-Length", "0"))
            fields, files = _parse_multipart(content_type, self.rfile.read(length))
            image = files.get("image")
            if not image:
                self._json(400, {"error": "缺少 image 文件字段"})
                return
            preset_id = (fields.get("preset") or "").strip()
            try:
                intensity = int(float(fields.get("intensity") or "60"))
            except ValueError:
                intensity = 60
            preset = PRESETS.get(preset_id)
            if preset is None:
                self._json(400, {"error": f"未知预设 {preset_id!r}", "available": list(PRESETS)})
                return
            try:
                result = AliBeautyClient(ak, sk, debug=debug).beautify(image, preset, intensity)
            except AliError as exc:
                self._json(502, {"error": str(exc)})
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(result)))
            self.end_headers()
            self.wfile.write(result)

        def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
            sys.stderr.write("[ali-beauty] " + fmt % args + "\n")

    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"阿里云美颜转发已启动：http://{host}:{port}")
    print(f"  健康检查  GET  /health")
    print(f"  精修      POST /retouch（字段 image / preset / intensity）")
    print(f"  AK/SK     {'已配置' if ak and sk else '**未配置** —— 调用会返回 502'}")
    print(f"  访问口令  {'已启用' if token else '未启用（建议设一个）'}")
    print()
    print("把 App 里「设置 → 云端精修 → 中继地址」填成这台机器的地址即可。")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="阿里云「人脸美颜」云端精修适配层",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--presets", action="store_true", help="列出预设与参数映射")
    parser.add_argument("--selftest", action="store_true", help="不联网自检（不需要 AK/SK）")
    parser.add_argument("--probe", action="store_true", help="真实调用一次，打印原始收发（校准用）")
    parser.add_argument("--image", help="输入图片路径")
    parser.add_argument("--out", help="输出图片路径")
    parser.add_argument("--preset", default="ali.natural", help="预设 id（默认 ali.natural）")
    parser.add_argument("--intensity", type=int, default=60, help="强度 0-100（默认 60）")
    parser.add_argument("--serve", action="store_true", help="启动 HTTP 转发服务")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8092)
    parser.add_argument("--token", default=os.environ.get("RETOUCH_TOKEN", ""),
                        help="HTTP 服务访问口令（也可用 RETOUCH_TOKEN 环境变量）")
    parser.add_argument("--debug", action="store_true", help="打印请求与响应细节")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()

    if args.presets:
        print(f"阿里云人脸美颜 · 预设映射（Action={ACTION}，参数 Sharp/Smooth/White ∈ [0,1]）")
        print(f"Endpoint: https://{ENDPOINT}")
        print()
        for preset in PRESETS.values():
            print(f"[{preset.id}] {preset.title}")
            print(f"  {preset.detail}")
            print(f"  强度 100 时的参数：{build_request(preset, 100)}")
            print()
        return 0

    if args.serve:
        return serve(args.host, args.port, args.token, args.debug)

    if not args.image:
        parser.print_help()
        return 2

    ak = os.environ.get("ALIYUN_AK", "")
    sk = os.environ.get("ALIYUN_SK", "")
    if not (ak and sk):
        print("缺少 ALIYUN_AK / ALIYUN_SK 环境变量。", file=sys.stderr)
        print("阿里云控制台 → AccessKey 管理 → 创建；子账号需授 AliyunVIAPIFullAccess。",
              file=sys.stderr)
        return 2
    preset = PRESETS.get(args.preset)
    if preset is None:
        print(f"未知预设 {args.preset!r}，可用：{', '.join(PRESETS)}", file=sys.stderr)
        return 2
    with open(args.image, "rb") as f:
        image = f.read()
    result = AliBeautyClient(ak, sk, debug=args.debug).beautify(image, preset, args.intensity)
    out = args.out or f"aliyun_{args.preset.replace('.', '_')}.jpg"
    with open(out, "wb") as f:
        f.write(result)
    print(f"完成：{out}（{len(result)} 字节）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
