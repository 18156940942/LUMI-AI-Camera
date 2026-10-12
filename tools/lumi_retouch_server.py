#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI 精修中继（HTTP）
====================

这个脚本解决一个具体问题：**App 里不能有云端密钥**。

照片精修（尤其是生成式改动）要调云端模型，而云端密钥一旦编译进 iOS 客户端就等于泄漏
—— 反编译拿字符串是常规操作。App 内那条隐私说明写的就是正确做法：
「把密钥放在你自己的服务端，客户端只调用你的接口。」

本脚本就是这个「你自己的服务端」：

    iPhone (LUMI) ──HTTP──▶ 本脚本（持有密钥）──▶ 云端模型
                            │
                            └─ 不需要云端的活，就地用本地算法算完

两条通路
--------
1. **本地执行器（不需要任何密钥）**
   画质增强、风格化调色、人像美化 —— 这些都是确定性的像素运算，
   本地算比云端更快、免费、可复现，而且**照片根本不出你的电脑**。
2. **云端执行器（需要你配置）**
   只有「生成式改动」需要它，因为它的本质是**重绘画面内容**，本地算法做不到。
   没配置时它会明确报 `provider_not_configured`，**绝不返回一张假装处理过的图**。

快速开始
--------
    # 依赖
    pip install opencv-python numpy

    # 看一眼预设目录
    python lumi_retouch_server.py --list

    # 启动（只做本地精修，不需要任何密钥）
    python lumi_retouch_server.py

    # 想用人脸相关预设，先取一次人脸检测模型（约 230 KB，来源见下）
    python lumi_retouch_server.py --fetch-face-model

    # 要接云端生成式改动时再补上（密钥只存在于你的电脑上）
    export LUMI_CLOUD_URL="https://你的服务商/v1/images/edits"
    export LUMI_CLOUD_KEY="sk-..."
    export LUMI_CLOUD_MODEL="你的模型名"

端点
----
    GET  /              状态页（浏览器直接打开，能看健康状态与预设列表）
    GET  /health        JSON 健康检查
    GET  /presets       预设目录（与 App 读的是同一份 JSON）
    POST /retouch       multipart: image / preset / intensity / prompt
                        → 成功回 image/jpeg，失败回 JSON 错误

为什么不用 cgi 模块
-------------------
Python 3.13 已经**移除**了 `cgi`，而 multipart 解析以前靠它。
这里自己写了最小实现（见 `parse_multipart`），只处理本协议需要的部分。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from http import server
from pathlib import Path
from typing import Callable, Optional

# ---------------------------------------------------------------------------
# 依赖检查：缺什么就说清楚怎么装，不要一堆 ImportError 堆栈
# ---------------------------------------------------------------------------

try:
    import numpy as np
except ImportError:  # pragma: no cover
    print("缺少 numpy。请先安装：\n    pip install opencv-python numpy", file=sys.stderr)
    raise SystemExit(2)

try:
    import cv2
except ImportError:  # pragma: no cover
    print("缺少 opencv-python。请先安装：\n    pip install opencv-python numpy", file=sys.stderr)
    raise SystemExit(2)


ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / "LUMI" / "Resources" / "retouch_presets.json"
MODEL_DIR = Path(__file__).resolve().parent / "models"
FACE_MODEL_PATH = MODEL_DIR / "face_detection_yunet_2023mar.onnx"

# 人脸检测模型：OpenCV Zoo 的 YuNet。走 media.githubusercontent 是因为
# opencv_zoo 用 Git LFS 存二进制，普通 raw 地址只会拿到一个 131 字节的指针文件。
FACE_MODEL_URL = (
    "https://media.githubusercontent.com/media/opencv_zoo/main/"
    "models/face_detection_yunet/face_detection_yunet_2023mar.onnx"
)
FACE_MODEL_SHA256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"


# ---------------------------------------------------------------------------
# 错误
# ---------------------------------------------------------------------------

class RetouchError(Exception):
    """带错误码的异常。错误码会原样回给 App，App 会显示给用户。"""

    def __init__(self, code: str, message: str, http_status: int = 400) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.http_status = http_status


# ---------------------------------------------------------------------------
# 预设目录
# ---------------------------------------------------------------------------

@dataclass
class Catalog:
    raw: dict
    by_id: dict[str, dict] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path = CATALOG_PATH) -> "Catalog":
        if not path.exists():
            raise RetouchError("catalog_missing",
                               f"找不到预设目录：{path}", 500)
        data = json.loads(path.read_text(encoding="utf-8"))
        cat = cls(raw=data)
        for preset in data.get("presets", []):
            cat.by_id[preset["id"]] = preset
        return cat

    def get(self, preset_id: str) -> dict:
        preset = self.by_id.get(preset_id)
        if preset is None:
            known = ", ".join(sorted(self.by_id))
            raise RetouchError("unknown_preset",
                               f"未知预设「{preset_id}」。可用：{known}", 422)
        return preset


# ---------------------------------------------------------------------------
# multipart/form-data 解析（Python 3.13 没有 cgi 了，自己写）
# ---------------------------------------------------------------------------

@dataclass
class FormPart:
    name: str
    filename: Optional[str]
    data: bytes


def _extract_boundary(content_type: str) -> bytes:
    marker = "boundary="
    idx = content_type.find(marker)
    if idx < 0:
        raise RetouchError("bad_multipart", "Content-Type 里没有 boundary")
    boundary = content_type[idx + len(marker):].split(";")[0].strip().strip('"')
    if not boundary:
        raise RetouchError("bad_multipart", "boundary 为空")
    return boundary.encode("ascii", errors="replace")


def _parse_disposition(value: str) -> tuple[Optional[str], Optional[str]]:
    name = None
    filename = None
    for piece in value.split(";"):
        piece = piece.strip()
        if piece.startswith("name="):
            name = piece[5:].strip().strip('"')
        elif piece.startswith("filename="):
            filename = piece[9:].strip().strip('"')
    return name, filename


def parse_multipart(body: bytes, content_type: str) -> dict[str, FormPart]:
    """解析 multipart 表单。只处理本协议用到的部分，不做通用实现。"""
    boundary = _extract_boundary(content_type)
    delimiter = b"--" + boundary

    parts: dict[str, FormPart] = {}
    for chunk in body.split(delimiter):
        # 前导段（还没到第一个 boundary）与结束段（--）直接跳过
        if not chunk or chunk[:2] == b"--":
            continue
        # 每段以 CRLF 开头；结尾的 CRLF 属于分隔符，要去掉
        if chunk.startswith(b"\r\n"):
            chunk = chunk[2:]
        if chunk.endswith(b"\r\n"):
            chunk = chunk[:-2]

        head, sep, content = chunk.partition(b"\r\n\r\n")
        if not sep:
            continue

        disposition = ""
        for line in head.decode("utf-8", errors="replace").split("\r\n"):
            if line.lower().startswith("content-disposition:"):
                disposition = line.split(":", 1)[1].strip()
                break

        name, filename = _parse_disposition(disposition)
        if not name:
            continue
        parts[name] = FormPart(name=name, filename=filename, data=content)

    if not parts:
        raise RetouchError("bad_multipart", "表单里没有任何字段")
    return parts


# ---------------------------------------------------------------------------
# 图像工具
# ---------------------------------------------------------------------------

def decode_image(data: bytes) -> np.ndarray:
    """把字节解成 BGR 图。失败就明确报错，不返回占位图。"""
    if not data:
        raise RetouchError("empty_image", "上传的图片是空的")
    buf = np.frombuffer(data, dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        raise RetouchError("undecodable_image",
                           f"无法解码上传的数据（{len(data)} 字节）—— 可能不是 JPEG/PNG，或文件损坏")
    return img


def encode_jpeg(img: np.ndarray, quality: int = 95) -> bytes:
    params = [int(cv2.IMWRITE_JPEG_QUALITY), int(quality)]
    ok, buf = cv2.imencode(".jpg", img, params)
    if not ok:
        raise RetouchError("encode_failed", "JPEG 编码失败", 500)
    return buf.tobytes()


def f32(img: np.ndarray) -> np.ndarray:
    return img.astype(np.float32) / 255.0


def u8(arr: np.ndarray) -> np.ndarray:
    return np.clip(arr * 255.0 + 0.5, 0.0, 255.0).astype(np.uint8)


def strength_scale(intensity: int) -> float:
    """把 0…100 的强度映射到 0…1。默认 60 大致对应中等力度。"""
    return max(0.0, min(1.0, intensity / 100.0))


def _luma(bgr: np.ndarray) -> np.ndarray:
    """BT.601 亮度。用于只改亮度不改色的操作。"""
    b, g, r = bgr[:, :, 0], bgr[:, :, 1], bgr[:, :, 2]
    return (0.114 * b + 0.587 * g + 0.299 * r)


# ---------------------------------------------------------------------------
# 本地执行器
# ---------------------------------------------------------------------------

class LocalProvider:
    """确定性的本地图像处理。

    这里每一个操作都是**真实的像素运算**，可复现、可验证。
    没有「AI 猜出来」的成分，也没有任何联网请求。
    """

    name = "local"

    # -- 工具：把处理限制在亮度通道，避免破坏色彩 ------------------------

    @staticmethod
    def _apply_luma_curve(bgr: np.ndarray, curve: Callable[[np.ndarray], np.ndarray]) -> np.ndarray:
        """对亮度应用曲线，保持色相与饱和度方向不变。

        做法：算出新旧亮度之差（0…255 量纲），再把这个差值**等量加到三个通道**上。
        用加性偏移而不是按新亮度重算颜色，可以避免「提亮之后肤色变灰」。
        """
        old = _luma(bgr)                                   # 0…255
        new = np.clip(curve(old / 255.0), 0.0, 1.0) * 255.0  # 曲线在 0…1 上定义
        delta = (new - old)[:, :, None]
        out = np.clip(bgr.astype(np.float32) + delta, 0.0, 255.0)
        return out.astype(np.uint8)

    # -- 画质增强 ---------------------------------------------------------

    def enhance_denoise(self, img: np.ndarray, s: float) -> np.ndarray:
        """保边平滑，只作用于色度通道。

        噪声主要落在色度上，而人眼对亮度细节更敏感。所以这里把亮度原样保留，
        只平滑 a/b 两个色度通道 —— 噪点没了，细节还在。
        """
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
        d = int(round(3 + 5 * s))
        sigma = 12 + 48 * s
        lab[:, :, 1] = cv2.bilateralFilter(lab[:, :, 1], d, sigma, d)
        lab[:, :, 2] = cv2.bilateralFilter(lab[:, :, 2], d, sigma, d)
        return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)

    def enhance_sharpen(self, img: np.ndarray, s: float) -> np.ndarray:
        """反锐化掩模，只作用于亮度，避免彩色边缘出现伪色。"""
        amount = 0.35 + 1.15 * s
        sigma = 1.0
        def curve(lum: np.ndarray) -> np.ndarray:
            blur = cv2.GaussianBlur(lum, (0, 0), sigma)
            return lum + amount * (lum - blur)
        return self._apply_luma_curve(img, curve)

    def enhance_shadow(self, img: np.ndarray, s: float) -> np.ndarray:
        """只抬暗部。

        权重取 (1-L)^3：越暗的地方抬得越多，纯白处权重为 0 完全不动，
        所以不会出现「整张图发灰」。

        系数取 0.35：实测强度拉满时暗部约 +37 级，属于明显但不至于崩掉的范围；
        强度 60 时约 +22 级。再大就会把暗部细节直接糊平。
        """
        k = 0.35 * s
        def curve(lum: np.ndarray) -> np.ndarray:
            w = (1.0 - lum) ** 3
            return lum + k * w * (1.0 - lum)
        return self._apply_luma_curve(img, curve)

    def enhance_dehaze(self, img: np.ndarray, s: float) -> np.ndarray:
        """暗通道先验去雾（He et al. 的经典做法）。

        t = 1 - omega * darkchannel / A 为透射率，再按大气光补偿。
        这里用百分位估计大气光，并给透射率设下限，避免天空区域被算成死黑。
        """
        src = img.astype(np.float32)
        dark = dark_channel(src)                       # (H, W)
        atmosphere_color = estimate_atmosphere(src, dark)   # (3,) 逐通道，用于颜色恢复
        # 透射率是单通道的量，必须用**标量**大气光来算。
        # 直接用 (3,) 的数组会和 (H, W) 广播失败 —— 这是实测踩到的。
        atmosphere_gray = float(atmosphere_color.mean())
        omega = 0.75 * s
        transmission = 1.0 - omega * (dark / max(atmosphere_gray, 1.0))
        transmission = np.clip(transmission, 0.25, 1.0)[:, :, None]
        out = (src - atmosphere_color) / transmission + atmosphere_color
        return u8(np.clip(out / 255.0, 0.0, 1.0))

    def enhance_auto(self, img: np.ndarray, s: float) -> np.ndarray:
        """按画面统计自动决定各步力度。

        判断依据全部来自实际像素统计（平均亮度、暗部占比、高频能量），
        不是固定参数：
        - 偏暗 → 多抬暗部；偏亮 → 少抬
        - 细节能量低 → 多锐化
        - 色度方差大 → 多降噪
        """
        lum = _luma(img) / 255.0
        mean_lum = float(lum.mean())
        shadow_ratio = float((lum < 0.25).mean())

        # 高频能量（拉普拉斯方差归一化）—— 越低说明越糊/越平
        detail = float(cv2.Laplacian((lum * 255).astype(np.uint8), cv2.CV_32F).var())
        detail_norm = min(1.0, detail / 900.0)

        # 色度噪声估计：色度通道高频能量的标准差
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
        chroma_noise = float(np.mean([
            cv2.Laplacian(lab[:, :, i], cv2.CV_32F).std() for i in (1, 2)
        ]))
        noise_norm = min(1.0, max(0.0, (chroma_noise - 4.0) / 26.0))

        out = img
        if noise_norm > 0.12:
            out = self.enhance_denoise(out, s * noise_norm)
        if mean_lum < 0.52 or shadow_ratio > 0.08:
            strength = min(1.0, (0.52 - mean_lum) / 0.35 + shadow_ratio * 2.0)
            out = self.enhance_shadow(out, s * max(0.15, strength))
        if detail_norm < 0.75:
            out = self.enhance_sharpen(out, s * (0.75 - detail_norm) / 0.75)
        return out

    # -- 风格化调色 -------------------------------------------------------

    def grade_film(self, img: np.ndarray, s: float) -> np.ndarray:
        """胶片感：抬黑位 + 压高光 + 轻微青调阴影/暖调高光。"""
        x = f32(img)
        lift = 0.030 + 0.055 * s
        x = x * (1.0 - lift) + lift                       # 抬黑位
        x = np.clip(x - 0.10 * s * np.clip(x - 0.75, 0, None) ** 1.2, 0, 1)  # 压高光
        # 分离调色：暗部加青、亮部加暖
        luma = x.mean(axis=2, keepdims=True)
        shadow_w = (1.0 - luma) ** 2
        highlight_w = luma ** 2
        x[:, :, 0] = x[:, :, 0] + 0.050 * s * shadow_w[:, :, 0] - 0.022 * s * highlight_w[:, :, 0]
        x[:, :, 2] = x[:, :, 2] - 0.045 * s * shadow_w[:, :, 0] + 0.030 * s * highlight_w[:, :, 0]
        return u8(np.clip(x, 0, 1))

    def grade_clean(self, img: np.ndarray, s: float) -> np.ndarray:
        """通透干净：S 形对比曲线 + 适度提饱和。"""
        x = f32(img)
        def curve(lum: np.ndarray) -> np.ndarray:
            smooth = lum * lum * (3.0 - 2.0 * lum)     # smoothstep
            return lum + (1.0 + 0.35 * s) * (smooth - lum)
        out = self._apply_luma_curve(img, curve)
        return self._saturate(out, 1.0 + 0.18 * s)

    def grade_warm(self, img: np.ndarray, s: float) -> np.ndarray:
        """暖调：抬红、压蓝，并轻微抬中间调。"""
        x = f32(img)
        x[:, :, 2] = x[:, :, 2] * (1.0 + 0.10 * s)      # BGR，索引 2 是红
        x[:, :, 0] = x[:, :, 0] * (1.0 - 0.09 * s)      # 索引 0 是蓝
        x = np.clip(x, 0, 1)
        x = x ** (1.0 / (1.0 + 0.06 * s))
        return u8(x)

    def grade_mono(self, img: np.ndarray, s: float) -> np.ndarray:
        """黑白：按亮度加权转灰 + 对比曲线。

        权重刻意比人眼亮度曲线略带一点红，让肤色在黑白下更亮一点 ——
        这是黑白胶片的常见取向。
        """
        lum = (0.24 * img[:, :, 2] + 0.62 * img[:, :, 1] + 0.14 * img[:, :, 0]) / 255.0
        def curve(v: np.ndarray) -> np.ndarray:
            smooth = v * v * (3.0 - 2.0 * v)
            return v + (1.0 + 0.45 * s) * (smooth - v)
        out = np.clip(curve(lum), 0, 1) * 255.0
        return cv2.cvtColor(out.astype(np.uint8), cv2.COLOR_GRAY2BGR)

    # -- 人像美化 ---------------------------------------------------------

    @staticmethod
    def skin_mask(img: np.ndarray) -> np.ndarray:
        """肤色区域的软掩膜（0…1 浮点）。

        用 YCrCb 的经验区间，再对掩膜做一次大半径模糊变成软边 ——
        硬边掩膜会在脸上留下明显的处理边界，比不处理还难看。
        """
        ycrcb = cv2.cvtColor(img, cv2.COLOR_BGR2YCrCb)
        cr = ycrcb[:, :, 1]
        cb = ycrcb[:, :, 2]
        mask = ((cr >= 133) & (cr <= 175) & (cb >= 77) & (cb <= 129))
        mask = mask.astype(np.float32)
        radius = max(3, int(round(max(img.shape[:2]) * 0.012)) | 1)
        mask = cv2.GaussianBlur(mask, (radius, radius), 0)
        return np.clip(mask, 0.0, 1.0)

    def portrait_skin_soft(self, img: np.ndarray, s: float) -> np.ndarray:
        """保边柔化，且**只作用于肤色区域**。

        `orig - k*(orig - bilateral)` 就是「削掉低幅度的皮肤纹理、保留边缘」，
        所以毛孔与轮廓都还在，不会糊成一片。
        """
        d = int(round(5 + 7 * s))
        sigma = 18 + 42 * s
        smoothed = cv2.bilateralFilter(img, d, sigma, d)
        weight = (self.skin_mask(img) * (0.25 + 0.65 * s))[:, :, None]
        out = img.astype(np.float32) + weight * (smoothed.astype(np.float32) - img.astype(np.float32))
        return np.clip(out, 0, 255).astype(np.uint8)

    def portrait_brighten_face(self, img: np.ndarray, s: float, detector: "FaceDetector") -> np.ndarray:
        """检测人脸后只提亮脸部。

        **检测不到人脸时抛错，而不是整张图提亮了事** —— 后者会把背景一起洗白，
        而且用户完全不知道发生了什么。
        """
        boxes = detector.detect(img)
        if not boxes:
            raise RetouchError(
                "no_face_detected",
                "没有检测到人脸，因此没有做任何处理。换一张正脸更清晰、或人脸更大的照片再试。",
                422,
            )

        height, width = img.shape[:2]
        mask = np.zeros((height, width), np.float32)
        for (x, y, w, h, _score) in boxes:
            # 往外扩一点，避免提亮区域在脸边界处出现硬边
            pad_x, pad_y = int(w * 0.16), int(h * 0.20)
            x0 = max(0, x - pad_x)
            y0 = max(0, y - pad_y)
            x1 = min(width, x + w + pad_x)
            y1 = min(height, y + h + pad_y)
            mask[y0:y1, x0:x1] = 1.0

        feather = max(5, int(round(max(height, width) * 0.015)) | 1)
        mask = cv2.GaussianBlur(mask, (feather, feather), 0)
        mask = np.clip(mask, 0.0, 1.0)[:, :, None]

        gain = 0.10 + 0.28 * s
        luma = _luma(img)[:, :, None]
        # 暗部的脸提得多、本来就亮的少提，避免过曝
        adaptive = (1.0 - np.clip(luma / 255.0, 0, 1)) * 0.7 + 0.3
        delta = mask * gain * adaptive * 255.0
        out = img.astype(np.float32) + delta
        return np.clip(out, 0, 255).astype(np.uint8)

    # -- 饱和度工具 -------------------------------------------------------

    @staticmethod
    def _saturate(img: np.ndarray, factor: float) -> np.ndarray:
        hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV).astype(np.float32)
        hsv[:, :, 1] = np.clip(hsv[:, :, 1] * factor, 0, 255)
        return cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2BGR)


def dark_channel(src: np.ndarray, radius: int = 7) -> np.ndarray:
    """暗通道：每个像素在 RGB 三通道里取最小，再做一次腐蚀。"""
    min_channel = src.min(axis=2)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (radius * 2 + 1, radius * 2 + 1))
    return cv2.erode(min_channel, kernel)


def estimate_atmosphere(src: np.ndarray, dark: np.ndarray, top_ratio: float = 0.001) -> np.ndarray:
    """用暗通道最亮的那 0.1% 像素（对应原图）估计大气光 A。

    比「取全图最大亮度」稳得多 —— 后者会被一个白色物体带偏。
    """
    flat = dark.ravel()
    count = max(1, int(flat.size * top_ratio))
    idx = np.argpartition(flat, -count)[-count:]
    pixels = src.reshape(-1, 3)[idx]
    return np.clip(pixels.mean(axis=0), 1.0, 255.0)


# ---------------------------------------------------------------------------
# 人脸检测（YuNet）
# ---------------------------------------------------------------------------

def ascii_staging_dir() -> Optional[Path]:
    """找一个「路径全为 ASCII 且可写」的目录，用来放模型副本。

    这不是多此一举，而是**实测踩到的坑**：

    OpenCV 的 ONNX 读取在 Windows 上走的是窄字符（ANSI）路径，**绝对路径里只要
    含非 ASCII 字符就会失败** —— 报 `Can't read ONNX file`，但文件明明存在、
    大小也对。而本项目的工程目录恰好常常在 `C:\\Users\\<中文名>\\...` 下面，
    不处理的话「面部提亮」这条预设在中文用户机器上必然不可用。

    实测结论（同一台机器、同一个模型文件）：

        tools/models/xxx.onnx                                   ✅ 相对路径可以
        C:\\Users\\饭饭之叫\\...\\tools\\models\\xxx.onnx              ❌ 绝对路径含中文，失败
        C:\\ProgramData\\LUMI\\models\\xxx.onnx                    ✅ 绝对路径纯 ASCII，可以

    所以这里挑一个纯 ASCII 的落地目录，把模型拷过去。
    """
    candidates: list[Path] = []
    if os.name == "nt":
        for env_name in ("ProgramData", "PUBLIC"):
            value = os.environ.get(env_name)
            if value:
                candidates.append(Path(value) / "LUMI" / "models")
    else:
        candidates.append(Path("/tmp") / "LUMI" / "models")

    for base in candidates:
        try:
            if not str(base).isascii():
                continue
            base.mkdir(parents=True, exist_ok=True)
            probe = base / ".lumi-write-probe"
            probe.write_bytes(b"")
            probe.unlink()
            return base
        except Exception:  # noqa: BLE001
            continue
    return None


class FaceDetector:
    """OpenCV Zoo YuNet 人脸检测。

    检测前把图缩到最长边 `max_side`，检测框再映射回原尺寸。
    实测 5568×3712 的照片在 1024px 下约 25 ms，精度足够定位提亮区域。
    """

    def __init__(self, model_path: Path = FACE_MODEL_PATH, score_threshold: float = 0.6) -> None:
        self.model_path = model_path
        self.score_threshold = score_threshold
        self._lock = threading.Lock()
        self._detector = None
        self._loaded_via: Optional[str] = None
        self.max_side = 1024

    @property
    def available(self) -> bool:
        return self.model_path.exists()

    # -- 路径解析 ---------------------------------------------------------

    def _candidate_paths(self) -> list[tuple[str, str]]:
        """按优先级给出一串「可以拿去给 OpenCV 打开」的路径。

        返回 (说明, 路径)。前两类是零成本的尝试，最后一类要拷文件。
        """
        text = str(self.model_path)
        candidates: list[tuple[str, str]] = []

        if text.isascii():
            candidates.append(("绝对路径", text))

        # 相对路径：路径串里只要不含非 ASCII 就能打开，因为中文部分由系统在
        # 解析相对路径时处理，不经过窄字符 API
        try:
            relative = os.path.relpath(text, os.getcwd())
            if relative.isascii():
                candidates.append(("相对路径", relative))
        except ValueError:
            # 跨盘符时 Windows 上算不出相对路径，跳过即可
            pass

        return candidates

    def _stage_copy(self) -> Optional[tuple[str, str]]:
        """把模型拷到一个纯 ASCII 目录，返回 (说明, 路径)。"""
        stage_dir = ascii_staging_dir()
        if stage_dir is None:
            return None
        destination = stage_dir / self.model_path.name
        try:
            source_bytes = self.model_path.read_bytes()
            if not destination.exists() or destination.read_bytes() != source_bytes:
                destination.write_bytes(source_bytes)
        except Exception:  # noqa: BLE001
            return None
        if not str(destination).isascii():
            return None
        return ("ASCII 暂存副本", str(destination))

    @staticmethod
    def _compact(message: str) -> str:
        """OpenCV 的报错很长，取最后一行最关键的部分。"""
        lines = [line.strip() for line in message.splitlines() if line.strip()]
        return lines[-1] if lines else message

    def _ensure(self):
        if self._detector is not None:
            return self._detector
        if not self.available:
            raise RetouchError(
                "face_model_missing",
                "这条预设需要人脸检测模型，但还没取到。请在电脑上运行：\n"
                "    python lumi_retouch_server.py --fetch-face-model",
                501,
            )

        errors: list[str] = []

        def attempt(label: str, candidate: str) -> bool:
            try:
                self._detector = cv2.FaceDetectorYN.create(
                    candidate, "", (320, 320), self.score_threshold, 0.3, 5000
                )
                self._loaded_via = label
                return True
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{label}: {self._compact(str(exc))}")
                return False

        for label, candidate in self._candidate_paths():
            if attempt(label, candidate):
                return self._detector

        # 前面的都不行（典型情况：绝对路径含中文，且算不出可用的相对路径）。
        # 这时才付出拷贝一份的代价。
        staged = self._stage_copy()
        if staged is not None and attempt(*staged):
            return self._detector

        raise RetouchError(
            "face_model_load_failed",
            "人脸检测模型加载失败，已尝试过的路径都没成功：\n  "
            + "\n  ".join(errors or ["（没有任何候选路径）"])
            + "\n\n模型文件确实存在（"
            + f"{self.model_path.stat().st_size if self.model_path.exists() else 0} 字节）。"
            "最常见的原因是工程目录的绝对路径里有非 ASCII 字符（例如中文用户名），"
            "而 OpenCV 在 Windows 上读 ONNX 用的是窄字符路径。\n"
            "解决办法：确认 C:\\ProgramData 可写（脚本会自己把模型拷过去再用），"
            "或者把整个工程移到纯英文路径下。",
            500,
        )

    def detect(self, img: np.ndarray) -> list[tuple[int, int, int, int, float]]:
        detector = self._ensure()
        height, width = img.shape[:2]
        scale = min(1.0, self.max_side / max(height, width))
        if scale < 1.0:
            small = cv2.resize(img, (int(width * scale), int(height * scale)),
                               interpolation=cv2.INTER_AREA)
        else:
            small = img

        with self._lock:
            detector.setInputSize((small.shape[1], small.shape[0]))
            _count, faces = detector.detect(small)

        if faces is None:
            return []

        inv = 1.0 / scale
        results = []
        for face in faces:
            x, y, w, h = (face[0] * inv, face[1] * inv, face[2] * inv, face[3] * inv)
            results.append((int(x), int(y), int(w), int(h), float(face[14])))
        return results


# ---------------------------------------------------------------------------
# 云端执行器（生成式改动）
# ---------------------------------------------------------------------------

class CloudProvider:
    """生成式改动的执行器。

    **没配置就明确报错，绝不返回原图冒充结果。**

    默认按「OpenAI images/edits 形态」的 multipart 接口发请求 —— 这是目前
    最通用的一种形态。换成别的服务商时，只需要改 `_build_request` 与
    `_extract_image` 两处，其余逻辑不变。

    密钥来源优先级：命令行 > 环境变量 > 配置文件。
    无论哪种，**密钥都不会出现在这个仓库里**，也不会被打印出来。
    """

    def __init__(self,
                 url: Optional[str] = None,
                 key: Optional[str] = None,
                 model: Optional[str] = None,
                 timeout: float = 120.0) -> None:
        self.url = url or os.environ.get("LUMI_CLOUD_URL") or ""
        self.key = key or os.environ.get("LUMI_CLOUD_KEY") or ""
        self.model = model or os.environ.get("LUMI_CLOUD_MODEL") or ""
        self.timeout = timeout

    @property
    def configured(self) -> bool:
        return bool(self.url and self.key)

    @property
    def name(self) -> str:
        return f"cloud:{self.model or 'default'}"

    def _require(self) -> None:
        if not self.configured:
            raise RetouchError(
                "provider_not_configured",
                "这条预设是生成式改动，必须由云端模型完成，但还没配置云端服务商。\n"
                "请设置环境变量 LUMI_CLOUD_URL / LUMI_CLOUD_KEY（可选 LUMI_CLOUD_MODEL）"
                "后重启本脚本。未配置时不会做任何处理，也不会返回占位图。",
                501,
            )

    def _build_request(self, image_bytes: bytes, prompt: str) -> urllib.request.Request:
        boundary = "lumi-" + uuid.uuid4().hex
        body = bytearray()

        def add_field(name: str, value: str) -> None:
            body.extend(f"--{boundary}\r\n".encode())
            body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
            body.extend(value.encode("utf-8"))
            body.extend(b"\r\n")

        if self.model:
            add_field("model", self.model)
        add_field("prompt", prompt)
        add_field("n", "1")
        add_field("size", "auto")

        body.extend(f"--{boundary}\r\n".encode())
        body.extend(b'Content-Disposition: form-data; name="image"; filename="photo.jpg"\r\n')
        body.extend(b"Content-Type: image/jpeg\r\n\r\n")
        body.extend(image_bytes)
        body.extend(b"\r\n")
        body.extend(f"--{boundary}--\r\n".encode())

        request = urllib.request.Request(self.url, data=bytes(body), method="POST")
        request.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
        request.add_header("Authorization", f"Bearer {self.key}")
        request.add_header("User-Agent", "lumi-retouch-relay/1.0")
        return request

    @staticmethod
    def _extract_image(payload: bytes, content_type: str) -> bytes:
        """从响应里取出图片字节。

        接受三种常见形态：直接是图片、JSON 里带 b64_json、JSON 里带 url。
        都不匹配就明确报错 —— 猜不出来就说不出来。
        """
        import base64

        if content_type.lower().startswith("image/"):
            return payload

        try:
            data = json.loads(payload.decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            raise RetouchError(
                "cloud_bad_response",
                f"云端返回了无法解析的内容（Content-Type={content_type or '空'}，{len(payload)} 字节）",
                502,
            ) from exc

        # 形态一：{"data":[{"b64_json":"..."}]}
        items = data.get("data") if isinstance(data, dict) else None
        if isinstance(items, list) and items:
            first = items[0]
            if isinstance(first, dict):
                if isinstance(first.get("b64_json"), str):
                    return base64.b64decode(first["b64_json"])
                if isinstance(first.get("url"), str):
                    return CloudProvider._download(first["url"])

        # 形态二：{"image":"..."} / {"b64_json":"..."}
        for field_name in ("b64_json", "image", "image_base64"):
            if isinstance(data.get(field_name), str):
                raw = data[field_name]
                if raw.startswith("http"):
                    return CloudProvider._download(raw)
                return base64.b64decode(raw)

        if isinstance(data.get("url"), str):
            return CloudProvider._download(data["url"])

        raise RetouchError(
            "cloud_bad_response",
            "云端返回的 JSON 里找不到图片字段（支持 data[0].b64_json / data[0].url / b64_json / url）。"
            "如果你的服务商格式不同，请改 CloudProvider._extract_image。",
            502,
        )

    @staticmethod
    def _download(url: str) -> bytes:
        try:
            with urllib.request.urlopen(url, timeout=120) as resp:
                return resp.read()
        except Exception as exc:  # noqa: BLE001
            raise RetouchError("cloud_download_failed",
                               f"下载云端结果失败：{exc}", 502) from exc

    def generate(self, image_bytes: bytes, prompt: str) -> bytes:
        self._require()
        if not prompt.strip():
            raise RetouchError("missing_prompt", "生成式改动必须提供 prompt 描述。", 422)

        request = self._build_request(image_bytes, prompt)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as resp:
                payload = resp.read()
                content_type = resp.headers.get("Content-Type", "")
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read().decode("utf-8", errors="replace")[:400]
            except Exception:  # noqa: BLE001
                pass
            raise RetouchError("cloud_rejected",
                               f"云端返回 HTTP {exc.code}。{detail}".strip(), 502) from exc
        except Exception as exc:  # noqa: BLE001
            raise RetouchError("cloud_unreachable",
                               f"连不上云端服务商：{exc}", 502) from exc

        return self._extract_image(payload, content_type)


# ---------------------------------------------------------------------------
# 调度：预设 id → 执行器
# ---------------------------------------------------------------------------

class Executor:
    """按预设 id 分发到本地或云端。"""

    def __init__(self, catalog: Catalog, cloud: CloudProvider, jpeg_quality: int = 95) -> None:
        self.catalog = catalog
        self.local = LocalProvider()
        self.cloud = cloud
        self.faces = FaceDetector()
        self.jpeg_quality = max(1, min(100, jpeg_quality))

    def health(self) -> dict:
        return {
            "provider": "local",
            "cloudConfigured": self.cloud.configured,
            "cloudModel": self.cloud.model if self.cloud.configured else None,
            "faceModelAvailable": self.faces.available,
        }

    def run(self, preset_id: str, image_bytes: bytes, intensity: int, prompt: str) -> tuple[bytes, str]:
        preset = self.catalog.get(preset_id)
        engine = preset.get("engine", "local")
        s = strength_scale(intensity)

        if engine == "cloud" or preset.get("requiresPrompt"):
            result = self.cloud.generate(image_bytes, prompt)
            return result, self.cloud.name

        img = decode_image(image_bytes)
        dispatch: dict[str, Callable[[np.ndarray, float], np.ndarray]] = {
            "enhance.auto": self.local.enhance_auto,
            "enhance.denoise": self.local.enhance_denoise,
            "enhance.sharpen": self.local.enhance_sharpen,
            "enhance.shadow": self.local.enhance_shadow,
            "enhance.dehaze": self.local.enhance_dehaze,
            "grade.film": self.local.grade_film,
            "grade.clean": self.local.grade_clean,
            "grade.warm": self.local.grade_warm,
            "grade.mono": self.local.grade_mono,
            "portrait.skinSoft": self.local.portrait_skin_soft,
        }

        if preset_id == "portrait.brightenFace":
            out = self.local.portrait_brighten_face(img, s, self.faces)
        elif preset_id in dispatch:
            out = dispatch[preset_id](img, s)
        else:
            raise RetouchError(
                "preset_not_implemented",
                f"预设「{preset_id}」在本地执行器里没有实现。这是脚本的缺陷，请反馈。",
                500,
            )

        return encode_jpeg(out, self.jpeg_quality), self.local.name


# ---------------------------------------------------------------------------
# HTTP 服务
# ---------------------------------------------------------------------------

MAX_UPLOAD_BYTES = 64 * 1024 * 1024

STATUS_PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LUMI 精修中继</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; padding:24px; background:#101014; color:#e8e8ed;
         font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; }
  h1 { font-size:20px; margin:0 0 4px; }
  .sub { color:#9a9aa5; font-size:13px; margin-bottom:20px; }
  table { border-collapse:collapse; width:100%; margin:12px 0 24px; }
  th,td { text-align:left; padding:7px 10px; border-bottom:1px solid #2a2a32; font-size:13px; }
  th { color:#9a9aa5; font-weight:500; }
  .ok { color:#4ade80; } .warn { color:#fbbf24; } .bad { color:#f87171; }
  code { background:#1c1c22; padding:1px 6px; border-radius:4px; font-size:12px; }
  .card { background:#18181e; border:1px solid #2a2a32; border-radius:10px; padding:16px; margin-bottom:16px; }
</style></head><body>
<h1>LUMI 精修中继</h1>
<div class="sub">这个页面说明当前中继能做什么、不能做什么。状态全部是真实探测结果。</div>
<div id="root">加载中……</div>
<script>
fetch('/health').then(r=>r.json()).then(h=>{
  const badge = v => v ? '<span class="ok">已配置</span>' : '<span class="warn">未配置</span>';
  document.getElementById('root').innerHTML = `
    <div class="card">
      <table>
        <tr><th>运行中</th><td class="ok">是</td></tr>
        <tr><th>本地执行器</th><td class="ok">可用</td></tr>
        <tr><th>云端执行器（生成式改动）</th><td>${badge(h.cloudConfigured)}${h.cloudModel?' · '+h.cloudModel:''}</td></tr>
        <tr><th>人脸检测模型</th><td>${badge(h.faceModelAvailable)}${h.faceModelAvailable?'':' · 运行 --fetch-face-model 取一次'}</td></tr>
      </table>
      ${h.cloudConfigured ? '' : '<div class="sub">未配置云端时，「生成式改动」这一类会被明确拒绝，不会返回占位图。</div>'}
    </div>
    <div class="card"><div id="presets">读取预设…</div></div>`;
  return fetch('/presets').then(r=>r.json());
}).then(p=>{
  const rows = p.presets.map(x=>`<tr>
      <td><code>${x.id}</code></td><td>${x.title}</td>
      <td>${x.engine==='local'?'<span class="ok">本地</span>':'<span class="warn">云端</span>'}</td>
      <td class="sub">${x.detail}</td></tr>`).join('');
  document.getElementById('presets').innerHTML =
    `<table><tr><th>id</th><th>名称</th><th>执行方</th><th>说明</th></tr>${rows}</table>`;
}).catch(e=>{ document.getElementById('root').textContent = '读取状态失败：'+e; });
</script></body></html>
"""


class RetouchHandler(server.BaseHTTPRequestHandler):

    executor: Executor  # 由 make_server 注入
    server_version = "LumiRetouchRelay/1.0"
    started_at = time.time()
    job_count = 0
    job_lock = threading.Lock()

    # -- 工具 -------------------------------------------------------------

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error_json(self, error: RetouchError) -> None:
        self._send_json(error.http_status, {"error": {"code": error.code, "message": error.message}})

    # -- 路由 -------------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            body = STATUS_PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/health":
            payload = {
                "running": True,
                "uptime_seconds": round(time.time() - self.started_at, 1),
                "jobs": self.job_count,
                **self.executor.health(),
            }
            self._send_json(200, payload)
            return

        if path == "/presets":
            self._send_json(200, self.executor.catalog.raw)
            return

        self._send_error_json(RetouchError("not_found", f"没有这个端点：{path}", 404))

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path != "/retouch":
            self._send_error_json(RetouchError("not_found", f"没有这个端点：{path}", 404))
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0:
                raise RetouchError("empty_body", "请求体是空的")
            if length > MAX_UPLOAD_BYTES:
                raise RetouchError("too_large",
                                   f"上传 {length} 字节，超过上限 {MAX_UPLOAD_BYTES} 字节", 413)

            body = self.rfile.read(length)
            content_type = self.headers.get("Content-Type", "")
            parts = parse_multipart(body, content_type)

            image_part = parts.get("image")
            if image_part is None or not image_part.data:
                raise RetouchError("missing_image", "表单里缺少 image 字段")

            preset_id = (parts["preset"].data.decode("utf-8") if "preset" in parts else "").strip()
            if not preset_id:
                raise RetouchError("missing_preset", "表单里缺少 preset 字段")

            prompt = parts["prompt"].data.decode("utf-8") if "prompt" in parts else ""
            intensity_raw = parts["intensity"].data.decode("utf-8") if "intensity" in parts else "60"
            try:
                intensity = max(0, min(100, int(float(intensity_raw))))
            except ValueError:
                raise RetouchError("bad_intensity",
                                   f"intensity 必须是 0…100 的数字，收到 {intensity_raw!r}") from None

            started = time.time()
            result_bytes, provider = self.executor.run(
                preset_id, image_part.data, intensity, prompt
            )
            elapsed_ms = int((time.time() - started) * 1000)

            with RetouchHandler.job_lock:
                RetouchHandler.job_count += 1

            self.log_message("retouch %s  %d→%d bytes  %s  %dms",
                             preset_id, len(image_part.data), len(result_bytes),
                             provider, elapsed_ms)

            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(result_bytes)))
            self.send_header("X-Lumi-Preset", preset_id)
            self.send_header("X-Lumi-Provider", provider)
            self.send_header("X-Lumi-Elapsed-Ms", str(elapsed_ms))
            self.end_headers()
            self.wfile.write(result_bytes)

        except RetouchError as error:
            self.log_message("retouch 失败 [%s] %s", error.code, error.message.replace("\n", " "))
            self._send_error_json(error)
        except Exception as exc:  # noqa: BLE001
            self.log_message("retouch 未预期错误：%r", exc)
            self._send_error_json(RetouchError("internal_error", f"中继内部错误：{exc}", 500))


def make_server(host: str, port: int, executor: Executor):
    handler = type("BoundRetouchHandler", (RetouchHandler,), {"executor": executor})
    return server.ThreadingHTTPServer((host, port), handler)


# ---------------------------------------------------------------------------
# 命令行
# ---------------------------------------------------------------------------

def local_ip() -> str:
    """猜一个手机能访问到的本机地址（不会真的发包）。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except Exception:  # noqa: BLE001
        return "127.0.0.1"
    finally:
        sock.close()


def fetch_face_model() -> int:
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    if FACE_MODEL_PATH.exists():
        digest = hashlib.sha256(FACE_MODEL_PATH.read_bytes()).hexdigest()
        if digest == FACE_MODEL_SHA256:
            print(f"人脸检测模型已存在且校验通过：{FACE_MODEL_PATH}")
            return 0

    print(f"下载人脸检测模型（YuNet，约 230 KB）\n  {FACE_MODEL_URL}")
    try:
        request = urllib.request.Request(FACE_MODEL_URL, headers={"User-Agent": "lumi-relay/1.0"})
        with urllib.request.urlopen(request, timeout=120) as resp:
            data = resp.read()
    except Exception as exc:  # noqa: BLE001
        print(f"下载失败：{exc}", file=sys.stderr)
        return 1

    digest = hashlib.sha256(data).hexdigest()
    if digest != FACE_MODEL_SHA256:
        print(
            "下载到的文件校验不通过，已放弃写入。\n"
            f"  期望 SHA-256：{FACE_MODEL_SHA256}\n"
            f"  实际 SHA-256：{digest}\n"
            "（若拿到的是 131 字节的文本，说明命中了 Git LFS 指针，请改用 media.githubusercontent 地址）",
            file=sys.stderr,
        )
        return 1

    FACE_MODEL_PATH.write_bytes(data)
    print(f"已保存并通过校验：{FACE_MODEL_PATH}（{len(data)} 字节）")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="LUMI 精修中继：把 App 传来的照片做精修，本地算法或云端模型。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("快速开始")[1] if "快速开始" in __doc__ else None,
    )
    parser.add_argument("--host", default="0.0.0.0", help="监听地址（默认 0.0.0.0，允许手机访问）")
    parser.add_argument("--port", type=int, default=8091, help="监听端口（默认 8091，与监看中继的 8090 错开）")
    parser.add_argument("--list", action="store_true", help="列出预设后退出")
    parser.add_argument("--fetch-face-model", action="store_true",
                        help="下载人脸检测模型后退出（人脸提亮预设需要）")
    parser.add_argument("--cloud-url", default=None, help="云端生成式接口地址（也可用环境变量 LUMI_CLOUD_URL）")
    parser.add_argument("--cloud-key", default=None, help="云端密钥（也可用环境变量 LUMI_CLOUD_KEY）")
    parser.add_argument("--cloud-model", default=None, help="云端模型名（也可用环境变量 LUMI_CLOUD_MODEL）")
    parser.add_argument("--jpeg-quality", type=int, default=95, help="输出 JPEG 质量 1…100（默认 95）")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    if args.fetch_face_model:
        return fetch_face_model()

    try:
        catalog = Catalog.load()
    except RetouchError as error:
        print(f"✗ {error.message}", file=sys.stderr)
        return 1

    if args.list:
        print(f"共 {len(catalog.by_id)} 条预设：\n")
        current = None
        for preset in catalog.raw.get("presets", []):
            if preset["category"] != current:
                current = preset["category"]
                info = next((c for c in catalog.raw.get("categories", []) if c["id"] == current), {})
                print(f"  【{info.get('title', current)}】{info.get('summary', '')}")
            engine = preset["engine"]
            mark = "本地" if engine == "local" else "云端"
            needs = "（需填 prompt）" if preset.get("requiresPrompt") else ""
            print(f"    {preset['id']:<28} {preset['title']:<12} [{mark}]{needs}")
        return 0

    cloud = CloudProvider(url=args.cloud_url, key=args.cloud_key, model=args.cloud_model)
    executor = Executor(catalog, cloud, jpeg_quality=args.jpeg_quality)

    httpd = make_server(args.host, args.port, executor)

    print("=" * 66)
    print("  LUMI 精修中继已启动")
    print("=" * 66)
    print(f"  预设数量      : {len(catalog.by_id)}")
    print(f"  本地执行器    : 可用（不需要任何密钥，照片不出本机）")
    if cloud.configured:
        print(f"  云端执行器    : 已配置（模型 {cloud.model or '默认'}）")
    else:
        print(f"  云端执行器    : 未配置 —— 「生成式改动」类预设会被明确拒绝，不会返回占位图")
    print(f"  人脸检测模型  : {'已就绪' if executor.faces.available else '未取到（运行 --fetch-face-model）'}")
    print()
    print(f"  手机侧填这个地址（App → 设置 → 云端精修）：")
    print(f"      http://{local_ip()}:{args.port}")
    print()
    print(f"  电脑上先自测（浏览器打开）：")
    print(f"      http://127.0.0.1:{args.port}")
    print()
    print("  Ctrl+C 停止")
    print("=" * 66)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
