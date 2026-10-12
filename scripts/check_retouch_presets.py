#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI —— 精修预设检查
====================

这个脚本的存在理由，是**两个实测踩到的 bug**：

  1. `enhance_dehaze` 里写了 `max(atmosphere, 1.0)`。`atmosphere` 是长度为 3 的
     数组，Python 内置 `max()` 会去比较数组的「真值」，直接抛
     `ValueError: The truth value of an array with more than one element is ambiguous`。
  2. 修掉上面那个之后，随即撞上第二个：暗通道是 `(H, W)` 单通道，而大气光是 `(3,)`，
     两者相除广播失败 —— `operands could not be broadcast together`。

这两个都是**只有真正跑过才会暴露**的错误，而且它们全都发生在电脑端、不在 App 里 ——
也就是说，手机上点一次「精修」失败一次，用户只会看到「中继内部错误」。
所以必须在这里拦住。

检查分三层
----------
  A. **目录结构**（纯 Python，任何环境都能跑）
     预设 id 唯一、id 前缀与类别一致、engine 合法、云端预设必须要求 prompt、
     本地预设不得要求 prompt、标题与说明非空。

  B. **JSON ↔ Swift 枚举一致性**
     与姿势库同一套做法：JSON 里出现的类别必须在 `RetouchCategory` 里有对应 case，
     反过来每个 case 也必须有对应类别。

  C. **实跑冒烟测试**（需要 opencv + numpy，缺失时跳过并明确说明）
     对每条本地预设，在一张合成图上真跑一遍，断言：
       - 输出是合法 JPEG
       - 尺寸与原图一致
       - 像素确实变了（除了本来就该"没变化"的情况）
     另外专门断言：合成图上没有脸，`portrait.brightenFace` 必须**明确拒绝**，
     绝不能返回一张没处理过的图冒充结果。

用法
----
    python3 scripts/check_retouch_presets.py

任何一项失败返回非 0 退出码。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "LUMI" / "Resources" / "retouch_presets.json"
SWIFT_TYPES = ROOT / "LUMI" / "Retouch" / "RetouchModels.swift"
TOOLS = ROOT / "tools"

VALID_ENGINES = {"local", "cloud"}


def head(title: str) -> None:
    print()
    print("=" * 68)
    print(f"  {title}")
    print("=" * 68)


# ---------------------------------------------------------------------------
# A. 目录结构
# ---------------------------------------------------------------------------

def check_structure(catalog: dict) -> list[str]:
    errors: list[str] = []

    categories = catalog.get("categories") or []
    presets = catalog.get("presets") or []

    if not categories:
        errors.append("categories 为空")
    if not presets:
        errors.append("presets 为空")

    category_ids: set[str] = set()
    for cat in categories:
        cid = cat.get("id", "")
        if not cid:
            errors.append("有一个类别缺少 id")
            continue
        if cid in category_ids:
            errors.append(f"类别 id 重复：{cid}")
        category_ids.add(cid)
        for field_name in ("title", "summary"):
            if not (cat.get(field_name) or "").strip():
                errors.append(f"类别 {cid} 的 {field_name} 为空")

    seen: set[str] = set()
    for preset in presets:
        pid = preset.get("id", "")
        if not pid:
            errors.append("有一条预设缺少 id")
            continue
        if pid in seen:
            errors.append(f"预设 id 重复：{pid}")
        seen.add(pid)

        if not re.fullmatch(r"[a-z]+\.[A-Za-z]+", pid):
            errors.append(f"{pid}: id 应形如 `类别.名称`（小写类别 + 驼峰名称）")

        category = preset.get("category", "")
        if category not in category_ids:
            errors.append(f"{pid}: category「{category}」不在 categories 里")
        elif not pid.startswith(category + "."):
            errors.append(f"{pid}: id 前缀与 category「{category}」不一致")

        engine = preset.get("engine", "")
        if engine not in VALID_ENGINES:
            errors.append(f"{pid}: engine「{engine}」不合法（只能是 {'/'.join(sorted(VALID_ENGINES))}）")

        requires_prompt = preset.get("requiresPrompt")
        if not isinstance(requires_prompt, bool):
            errors.append(f"{pid}: requiresPrompt 必须是布尔值")
        else:
            if engine == "cloud" and not requires_prompt:
                errors.append(f"{pid}: 云端预设必须 requiresPrompt=true（不然用户没法描述要改什么）")
            if engine == "local" and requires_prompt:
                errors.append(f"{pid}: 本地预设不该要求 prompt（本地算法用不上文字描述）")

        for field_name in ("title", "detail"):
            if not (preset.get(field_name) or "").strip():
                errors.append(f"{pid}: {field_name} 为空")

    # 每个类别至少有一条预设，否则界面上会出现一个点进去什么都没有的分组
    used = {p.get("category") for p in presets}
    for cid in sorted(category_ids - used):
        errors.append(f"类别 {cid} 下没有任何预设")

    return errors


# ---------------------------------------------------------------------------
# B. JSON ↔ Swift 枚举
# ---------------------------------------------------------------------------

def swift_enum_cases(path: Path, enum_name: str) -> set[str]:
    """从 Swift 源码里取出枚举的 case 名（不处理带 raw value 的写法，本项目不需要）。"""
    text = path.read_text(encoding="utf-8", errors="replace")
    match = re.search(rf"enum\s+{enum_name}\s*:[^{{]*\{{", text)
    if not match:
        return set()
    start = match.end() - 1
    depth, i = 0, start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = text[start + 1:i]
    return {m.group(1) for m in re.finditer(r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)", body, re.M)}


def check_swift_alignment(catalog: dict) -> list[str]:
    errors: list[str] = []
    if not SWIFT_TYPES.exists():
        return [f"找不到 {SWIFT_TYPES.relative_to(ROOT)}"]

    swift_cases = swift_enum_cases(SWIFT_TYPES, "RetouchCategory")
    if not swift_cases:
        return ["在 RetouchModels.swift 里没解析到 RetouchCategory 的 case"]

    json_categories = {c.get("id") for c in catalog.get("categories", [])}

    only_json = sorted(json_categories - swift_cases)
    only_swift = sorted(swift_cases - json_categories)
    if only_json:
        errors.append(f"JSON 里有但 Swift 枚举里没有的类别：{', '.join(only_json)}")
    if only_swift:
        errors.append(f"Swift 枚举里有但 JSON 里没有的类别：{', '.join(only_swift)}")

    return errors


# ---------------------------------------------------------------------------
# C. 实跑冒烟测试
# ---------------------------------------------------------------------------

def synthetic_image():
    """造一张能同时踩到各条算法路径的合成图。

    需要包含：亮度梯度（暗部/高光）、噪声（降噪）、中频纹理（锐化）、
    以及一块肤色区域（肤色掩膜）。刻意**不含人脸**，用来验证拒绝路径。
    """
    import numpy as np

    height, width = 240, 320
    # 竖直亮度梯度
    ramp = np.linspace(20, 235, height, dtype=np.float32)[:, None]
    img = np.repeat(ramp, width, axis=1)
    img = np.stack([img * 0.9, img, img * 1.05], axis=2)

    # 中频纹理（棋盘），给锐化与去雾一点东西可做
    # 注意加了一维：img 是 (H, W, 3)，纹理是 (H, W)，不补维会广播失败
    yy, xx = np.mgrid[0:height, 0:width]
    checker = (((xx // 8 + yy // 8) % 2) * 14).astype(np.float32)[:, :, None]
    img = img + checker

    # 肤色块（YCrCb 的 Cr/Cb 落在 133–175 / 77–129 区间）
    skin_bgr = np.array([150.0, 180.0, 215.0])
    img[120:200, 90:200] = skin_bgr

    # 噪声
    rng = np.random.default_rng(20261012)
    img = img + rng.normal(0, 7.0, img.shape)

    return np.clip(img, 0, 255).astype(np.uint8)


def run_smoke(catalog: dict) -> tuple[list[str], str]:
    """返回 (错误列表, 说明文字)。cv2 不可用时返回跳过原因。"""
    try:
        import cv2
        import numpy as np
    except ImportError as exc:
        return [], f"跳过（缺少 {exc.name}，装了 opencv-python + numpy 才会跑这一层）"

    sys.path.insert(0, str(TOOLS))
    import lumi_retouch_server as relay  # noqa: E402

    errors: list[str] = []
    image = synthetic_image()
    source_bytes = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), 95])[1].tobytes()

    try:
        loaded = relay.Catalog.load()
        executor = relay.Executor(loaded, relay.CloudProvider(), jpeg_quality=95)
    except Exception as exc:  # noqa: BLE001
        return [f"中继模块初始化失败：{exc!r}"], ""

    local_presets = [p["id"] for p in catalog["presets"] if p.get("engine") == "local"]
    tallies = {"ok": 0, "fail": 0}

    for preset_id in local_presets:
        # 面部提亮在合成图上没有脸，正确的行为是明确拒绝 —— 单独断言
        if preset_id == "portrait.brightenFace":
            try:
                executor.run(preset_id, source_bytes, 60, "")
                errors.append(f"{preset_id}: 合成图上没有脸却返回了成功结果 —— 这等于交了一张没处理过的图")
                tallies["fail"] += 1
            except relay.RetouchError as error:
                if error.code in ("no_face_detected", "face_model_missing"):
                    tallies["ok"] += 1
                else:
                    errors.append(f"{preset_id}: 应该报 no_face_detected / face_model_missing，"
                                  f"实际报的是 {error.code}")
                    tallies["fail"] += 1
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{preset_id}: 抛了非预期异常 {exc!r}")
                tallies["fail"] += 1
            continue

        try:
            out_bytes, _provider = executor.run(preset_id, source_bytes, 60, "")
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{preset_id}: 执行失败 —— {type(exc).__name__}: {exc}")
            tallies["fail"] += 1
            continue

        if not out_bytes.startswith(b"\xff\xd8"):
            errors.append(f"{preset_id}: 输出不是 JPEG（头 {out_bytes[:4]!r}）")
            tallies["fail"] += 1
            continue

        decoded = cv2.imdecode(np.frombuffer(out_bytes, np.uint8), cv2.IMREAD_COLOR)
        if decoded is None:
            errors.append(f"{preset_id}: 输出无法解码")
            tallies["fail"] += 1
            continue

        if decoded.shape != image.shape:
            errors.append(f"{preset_id}: 输出尺寸 {decoded.shape} 与原图 {image.shape} 不一致")
            tallies["fail"] += 1
            continue

        diff = float(np.abs(decoded.astype(np.float32) - image.astype(np.float32)).mean())
        if diff < 0.2:
            errors.append(f"{preset_id}: 像素几乎没变化（平均差 {diff:.3f}）—— 预设可能是空操作")
            tallies["fail"] += 1
            continue

        tallies["ok"] += 1

    summary = f"实跑 {len(local_presets)} 条本地预设：通过 {tallies['ok']}、失败 {tallies['fail']}"
    return errors, summary


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    print("LUMI —— 精修预设检查")

    if not CATALOG.exists():
        print(f"  ✗ 找不到预设目录：{CATALOG}")
        return 1

    try:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        print(f"  ✗ JSON 解析失败：{error}")
        return 1

    failures: list[str] = []

    head("A. 目录结构")
    structure_errors = check_structure(catalog)
    if structure_errors:
        for item in structure_errors:
            print(f"  ✗ {item}")
        failures += structure_errors
    else:
        categories = len(catalog.get("categories", []))
        presets = len(catalog.get("presets", []))
        local = sum(1 for p in catalog["presets"] if p.get("engine") == "local")
        cloud = presets - local
        print(f"  ✓ {presets} 条预设分属 {categories} 个类别（本地 {local} / 云端 {cloud}）")
        print("  ✓ id 唯一、前缀与类别一致、engine 合法、prompt 要求自洽")

    head("B. JSON ↔ Swift 枚举一致性")
    swift_errors = check_swift_alignment(catalog)
    if swift_errors:
        for item in swift_errors:
            print(f"  ✗ {item}")
        failures += swift_errors
    else:
        cases = ", ".join(sorted(swift_enum_cases(SWIFT_TYPES, "RetouchCategory")))
        print(f"  ✓ 类别与 RetouchCategory 完全对应：{cases}")

    head("C. 实跑冒烟测试")
    smoke_errors, smoke_note = run_smoke(catalog)
    if smoke_note:
        print(f"  · {smoke_note}")
    if smoke_errors:
        for item in smoke_errors:
            print(f"  ✗ {item}")
        failures += smoke_errors
    elif smoke_note.startswith("跳过"):
        pass
    else:
        print(f"  ✓ {smoke_note}")
        print("  ✓ 面部提亮在无脸图上正确拒绝（没有返回未处理的图冒充结果）")

    print()
    if failures:
        print(f"共 {len(failures)} 项未通过。")
        return 1

    print("精修预设检查通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
