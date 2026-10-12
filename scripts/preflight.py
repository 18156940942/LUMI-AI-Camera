#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI —— 提交前预检（Windows 可用，不需要 Mac）
=============================================

在没有 Xcode 的机器上，把「推去云端编译之前能查出来的问题」全部查出来：

  1. 姿势库 JSON ↔ Swift 枚举交叉校验
     JSON 里的每个枚举原始值（场景/风格/景别/下巴/视线/手位/重心/腿位/机位…）
     都必须能在 LUMI/Models/PoseTypes.swift 里找到对应 case。
     这是最容易出错、也最难在 Mac 上定位的一类问题：
     JSON 里写错一个枚举值，运行时只会得到一句「姿势库解析失败」。

  2. 姿势库内容完整性
     id 唯一、场景与风格全覆盖、难度/构图比例在合理区间、旋转方向与角度自洽。

  3. Xcode 工程文件结构
     重新生成 project.pbxproj 并校验 UUID 引用完整性、Sources/Resources 覆盖度。

  4. Swift 源码交叉引用
     测试与 App 源码里引用的类型名是否真实存在（抓拼写错误）。

  5. 协议一致性
     `Hashable` 能否合成、`init` 是否漏赋值。

  7. 精修预设
     预设目录结构、JSON ↔ Swift 枚举一致性，以及**把每条本地精修预设真跑一遍**。
     踩过的坑：暗通道去雾里把内置 `max()` 用在数组上、以及 (H,W) 与 (3,) 广播失败 ——
     两类错误都只在真正执行时才暴露，手机上看到的就是一句「中继内部错误」。

  6. SwiftUI 观察链完整性
     View 读了某个 Store 却没有通过 `@EnvironmentObject` 订阅它。
     `AppState` 持有的子 Store 是普通 `let`，不会转发 `objectWillChange`，
     所以「只订阅 AppState 却读 app.settings.x」的视图永远不会重算 ——
     能编译、能过单元测试，只有上真机点一下才暴露。这类缺陷必须在这里拦住。

用法：
    python3 scripts/preflight.py

任何一步失败都会返回非 0 退出码，适合直接接进 CI 的前置步骤。
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable

PASSED: list[str] = []
FAILED: list[str] = []


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

def head(title: str) -> None:
    print()
    print("=" * 68)
    print(f"  {title}")
    print("=" * 68)


def ok(msg: str) -> None:
    PASSED.append(msg)
    print(f"  ✓ {msg}")


def bad(msg: str) -> None:
    FAILED.append(msg)
    print(f"  ✗ {msg}")


def note(msg: str) -> None:
    print(f"    · {msg}")


# ---------------------------------------------------------------------------
# 1. 从 Swift 源码里解析枚举的 case 名
# ---------------------------------------------------------------------------

def parse_swift_enums(path: Path) -> dict[str, set[str]]:
    """返回 {枚举名: {case 原始值}}。

    只处理 `case name` 与 `case name = "raw"` 两种形式（本项目全部是这两种）。
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    enums: dict[str, set[str]] = {}

    for match in re.finditer(
        r"enum\s+([A-Za-z_][A-Za-z0-9_]*)[^{]*\{", text
    ):
        name = match.group(1)
        # 从 '{' 之后开始，做花括号配对找出枚举体
        start = match.end() - 1
        depth = 0
        index = start
        while index < len(text):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        body = text[start + 1:index]

        cases: set[str] = set()
        for case_match in re.finditer(
            r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*=\s*\"([^\"]*)\")?",
            body,
            re.M,
        ):
            cases.add(case_match.group(2) or case_match.group(1))
        if cases:
            enums[name] = cases
    return enums


# ---------------------------------------------------------------------------
# 2. 姿势库校验
# ---------------------------------------------------------------------------

# JSON 路径 → 对应的 Swift 枚举名（nil 表示该字段是字符串/数值，不做枚举校验）
FIELD_ENUMS = {
    "shotType": "ShotType",
    "chin": "ChinCue",
    "shoulders": "ShoulderCue",
    "nearestHand": "HandPlacement",
    "otherHand": "HandPlacement",
    "weight": "WeightCue",
    "legs": "LegCue",
    "cameraAngle": "CameraAngle",
}
LIST_ENUMS = {
    "scenes": "PoseScene",
    "styles": "PoseStyle",
}
NESTED_ENUMS = {
    ("gaze", "anchor"): "GazeAnchor",
}
ROTATION_ENUMS = {
    "bodyRotation": "RotationDirection",
    "headTurn": "RotationDirection",
}


def validate_pose_library() -> None:
    head("1/7  姿势库 JSON ↔ Swift 枚举 交叉校验")

    json_path = ROOT / "LUMI" / "Resources" / "pose_library.json"
    types_path = ROOT / "LUMI" / "Models" / "PoseTypes.swift"

    if not json_path.exists():
        bad(f"找不到 {json_path}")
        return
    if not types_path.exists():
        bad(f"找不到 {types_path}")
        return

    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        bad(f"JSON 解析失败：{error}")
        return

    enums = parse_swift_enums(types_path)
    note(f"从 PoseTypes.swift 解析到 {len(enums)} 个枚举：{', '.join(sorted(enums))}")

    poses = data.get("poses", [])
    if not poses:
        bad("pose_library.json 里没有任何姿势")
        return

    errors: list[str] = []
    ids: set[str] = set()
    scene_hits: dict[str, int] = {}
    style_hits: dict[str, int] = {}
    headrooms: list[float] = []

    def check_enum(value, enum_name: str, where: str) -> None:
        allowed = enums.get(enum_name)
        if allowed is None:
            errors.append(f"{where}: 源码里找不到枚举 {enum_name}")
            return
        if value not in allowed:
            errors.append(
                f"{where}: 值 \"{value}\" 不是 {enum_name} 的合法 case"
                f"（合法值：{', '.join(sorted(allowed))}）"
            )

    for index, pose in enumerate(poses):
        pid = pose.get("id", f"<第 {index + 1} 条缺少 id>")
        if not isinstance(pid, str) or not pid:
            errors.append(f"{pid}: id 缺失或不是字符串")
            continue
        if pid in ids:
            errors.append(f"{pid}: id 重复")
        ids.add(pid)

        for field, enum_name in FIELD_ENUMS.items():
            if field not in pose:
                errors.append(f"{pid}: 缺少字段 {field}")
                continue
            value = pose[field]
            if field == "otherHand" and value is None:
                continue
            check_enum(value, enum_name, f"{pid}.{field}")

        for field, enum_name in LIST_ENUMS.items():
            values = pose.get(field)
            if not isinstance(values, list) or not values:
                errors.append(f"{pid}: {field} 缺失或为空数组")
                continue
            for value in values:
                check_enum(value, enum_name, f"{pid}.{field}")
            if field == "scenes":
                for value in values:
                    scene_hits[value] = scene_hits.get(value, 0) + 1
            else:
                for value in values:
                    style_hits[value] = style_hits.get(value, 0) + 1

        for (outer, inner), enum_name in NESTED_ENUMS.items():
            nested = pose.get(outer)
            if not isinstance(nested, dict) or inner not in nested:
                errors.append(f"{pid}: 缺少 {outer}.{inner}")
                continue
            check_enum(nested[inner], enum_name, f"{pid}.{outer}.{inner}")

        for field, enum_name in ROTATION_ENUMS.items():
            rotation = pose.get(field)
            if not isinstance(rotation, dict):
                errors.append(f"{pid}: 缺少或格式错误的 {field}")
                continue
            degrees = rotation.get("degrees")
            # 身体可以转身到近乎背对（0…180°），头部生理上最多转到 ~90°
            limit = 180 if field == "bodyRotation" else 90
            if not isinstance(degrees, int) or not (0 <= degrees <= limit):
                errors.append(
                    f"{pid}.{field}.degrees = {degrees!r}，应为 0…{limit} 的整数"
                )
            check_enum(rotation.get("direction"), enum_name, f"{pid}.{field}.direction")
            # 方向与角度必须自洽：标记为 none 就不该有角度，反之亦然
            direction, deg = rotation.get("direction"), rotation.get("degrees")
            if direction == "none" and deg != 0:
                errors.append(f"{pid}.{field}: direction=none 但 degrees={deg}")
            if direction in ("left", "right") and deg == 0:
                errors.append(f"{pid}.{field}: direction={direction} 但 degrees=0")

        difficulty = pose.get("difficulty")
        if not isinstance(difficulty, int) or not (1 <= difficulty <= 3):
            errors.append(f"{pid}: difficulty={difficulty!r} 应为 1…3")

        composition = pose.get("composition")
        if not isinstance(composition, dict):
            errors.append(f"{pid}: 缺少 composition")
        else:
            for field in ("horizontalAnchor", "headAnchor"):
                value = composition.get(field)
                if not isinstance(value, (int, float)) or not (0 <= value <= 1):
                    errors.append(f"{pid}.composition.{field} = {value!r}，应在 0…1")
            headroom = composition.get("headroomRatio")
            if not isinstance(headroom, (int, float)) or not (0 < headroom <= 1):
                errors.append(f"{pid}.composition.headroomRatio = {headroom!r}，应在 0…1")
            else:
                headrooms.append(headroom)
            if not isinstance(composition.get("needsLeadRoom"), bool):
                errors.append(f"{pid}.composition.needsLeadRoom 必须是布尔值")

        for field in ("name", "summary", "environment", "photographerTips"):
            value = pose.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{pid}: {field} 为空")
        if not pose.get("keywords"):
            errors.append(f"{pid}: keywords 为空")

    if errors:
        for item in errors[:25]:
            bad(item)
        if len(errors) > 25:
            note(f"…… 另有 {len(errors) - 25} 条同类问题未列出")
        return

    ok(f"{len(poses)} 条姿势全部通过枚举/区间/id 唯一性校验")
    ok(f"场景覆盖 {len(scene_hits)} 类、风格覆盖 {len(style_hits)} 类")
    note(f"头顶留白比例区间：{min(headrooms):.2f} – {max(headrooms):.2f}")

    from_swift = enums.get("PoseScene", set())
    missing_scene = from_swift - set(scene_hits)
    if missing_scene:
        bad(f"以下场景在姿势库里没有任何姿势：{', '.join(sorted(missing_scene))}")
    else:
        ok(f"PoseScene 的 {len(from_swift)} 个 case 全部有对应姿势")

    from_swift_style = enums.get("PoseStyle", set())
    missing_style = from_swift_style - set(style_hits)
    if missing_style:
        bad(f"以下风格在姿势库里没有任何姿势：{', '.join(sorted(missing_style))}")
    else:
        ok(f"PoseStyle 的 {len(from_swift_style)} 个 case 全部有对应姿势")


# ---------------------------------------------------------------------------
# 3. 运行子脚本
# ---------------------------------------------------------------------------

def run_script(title: str, script: str, *args: str) -> None:
    head(title)
    result = subprocess.run(
        [PY, str(ROOT / "scripts" / script), *args],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    output = (result.stdout or "") + (result.stderr or "")
    for line in output.rstrip().splitlines():
        print(f"  {line}")
    if result.returncode == 0:
        ok(f"{script} 通过")
    else:
        bad(f"{script} 未通过（退出码 {result.returncode}）")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    print("LUMI AI Camera —— 提交前预检")
    print(f"工程根目录：{ROOT}")

    validate_pose_library()
    run_script("2/7  重新生成 Xcode 工程文件", "generate_xcodeproj.py")
    run_script("3/7  校验 Xcode 工程结构（含 OpenStep 文法解析）", "validate_project.py")
    run_script("4/7  Swift 源码交叉引用检查", "check_symbols.py", "--all")
    run_script("5/7  协议一致性检查（Hashable 合成 / init 完整性）", "check_conformance.py")
    run_script("6/7  SwiftUI 观察链完整性检查", "check_observation.py")
    run_script("7/7  精修预设检查（含本地算法实跑冒烟测试）", "check_retouch_presets.py")

    head("预检结果")
    for item in PASSED:
        print(f"  ✓ {item}")
    for item in FAILED:
        print(f"  ✗ {item}")

    if FAILED:
        print(f"\n共 {len(FAILED)} 项未通过。请先修复再推送到云端编译。")
        return 1

    print(f"\n全部 {len(PASSED)} 项通过。可以推送到 GitHub 触发云端 macOS 构建了。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
