#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI —— Xcode 工程文件结构校验
==============================

在 Windows 上没有 Xcode，无法直接「打开工程看看」。这个脚本用最小实现解析
project.pbxproj（OpenStep plist）的关键结构，把最容易出错的问题提前抓出来：

  1. 有 UUID 被引用但没定义 → Xcode 打开就报 "The project cannot be opened"
  2. 有 UUID 定义但从未被引用（孤儿对象）→ 通常是漏挂到 build phase
  3. Sources 阶段漏文件 → 编译时报「Cannot find type 'XXX' in scope」
  4. 资源没进 Resources 阶段 → 运行时 pose_library.json 读不到
  5. 【结构】objects 里每个条目必须是完整闭合的 `UUID /* … */ = { … };` 对象
     → 字符串切割组装 pbxproj 时极易产生「孤儿属性 / 未闭合大括号」，
       这种损坏 Xcode 同样报 "The project is damaged"，但 UUID 检查发现不了
       （第一轮 CI 就栽在这上面，所以加了这个检查）

用法：
    python3 scripts/validate_project.py
退出码 0 = 全部通过；1 = 有问题（stderr 会列出）。
"""

from __future__ import annotations

import collections
import os
import re
import sys
from pathlib import Path

UUID_RE = re.compile(r"\b([0-9A-F]{24})\b")
# 「定义」= 行首缩进两个 tab 后紧跟 UUID 再跟注释（mainGroup 这类无注释的单独处理）
DEF_RE = re.compile(r"^\t\t([0-9A-F]{24})(?:\s+/\*.*?\*/)?\s*=", re.M)

# 结构检查用：对象头前缀（两个 tab + 24 位 UUID + 注释 + ` = {`）。
# 不锚定行尾 —— PBXBuildFile 的条目是单行对象（`… = {isa = …; fileRef = …; };`），
# 而 PBXProject 等是跨行对象（`… = {` 独占一行）。
ENTRY_HEADER_RE = re.compile(r"^\t\t[0-9A-F]{24} /\*.*?\*/ = \{")
# 多行对象的闭合行（两个 tab + `};`）
ENTRY_CLOSER_RE = re.compile(r"^\t\t\};$")


def strip_quoted(line: str) -> str:
    """把双引号字符串替换成空串，避免字符串里的 { } 干扰大括号计数。"""
    return re.sub(r'"[^"]*"', '""', line)


def check_objects_structure(text: str) -> list[str]:
    """逐 section 验证 objects 内每个条目都是「UUID 头 + 闭合 };" 的完整对象。

    这是对 UUID 引用检查的补充：当某个对象丢了头（只剩孤儿属性）时，
    它的 UUID 可能仍出现在别处（比如 dependencies 数组里），
    UUID 检查全绿，但 Xcode 会因为 OpenStep plist 语法错误拒绝打开工程。
    """
    problems: list[str] = []

    match = re.search(r"^\tobjects = \{$(.*?)^\t\};$", text, re.S | re.M)
    if not match:
        return ["找不到 objects = { … } 块（整体结构损坏）"]
    body = match.group(1)

    sections = re.findall(
        r"/\* Begin (\w+) section \*/\n(.*?)/\* End \1 section \*/", body, re.S
    )
    if not sections:
        return ["objects 块里找不到任何 section 标记"]

    for name, sec in sections:
        depth = 0
        entries = 0
        for idx, line in enumerate(sec.split("\n"), start=1):
            if not line.strip():
                continue
            if depth == 0:
                if not ENTRY_HEADER_RE.match(line):
                    problems.append(
                        f"{name} section 第 {idx} 行：期望对象头 "
                        f"'UUID /* … */ = {{'，实际是 {line.strip()[:60]!r}"
                        f"（孤儿属性或未闭合对象）"
                    )
                    continue
                entries += 1
                clean = strip_quoted(line)
                depth = clean.count("{") - clean.count("}")
                if depth == 0:
                    # 单行对象：必须以 }; 收尾
                    if not line.rstrip().endswith("};"):
                        problems.append(
                            f"{name} section 第 {idx} 行：单行对象没有以 '}};' 收尾"
                        )
                elif depth < 0:
                    problems.append(
                        f"{name} section 第 {idx} 行：'}}' 多于 '{{'，大括号失衡"
                    )
                    depth = 0
                # depth > 0：跨行对象已开启，等后续行闭合
            else:
                clean = strip_quoted(line)
                depth += clean.count("{") - clean.count("}")
                if depth == 0 and not ENTRY_CLOSER_RE.match(line):
                    problems.append(
                        f"{name} section 第 {idx} 行：对象以异常行收尾 {line.strip()[:60]!r}"
                    )
                if depth < 0:
                    problems.append(
                        f"{name} section 第 {idx} 行：多余的 '}}'，大括号失衡"
                    )
                    depth = 0
        if depth != 0:
            problems.append(f"{name} section：存在未闭合对象（depth 停在 {depth}）")
        if entries == 0:
            problems.append(f"{name} section：一个对象都没有")

    return problems


def collect_swift(root: Path, subdir: str) -> list[str]:
    base = root / subdir
    out: list[str] = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.endswith(".swift"):
                out.append((Path(dirpath) / name).relative_to(root).as_posix())
    return sorted(out)


def section(text: str, name: str) -> str:
    match = re.search(
        rf"/\* Begin {re.escape(name)} section \*/(.*?)/\* End {re.escape(name)} section \*/",
        text,
        re.S,
    )
    return match.group(1) if match else ""


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    pbxproj = root / "LUMI.xcodeproj" / "project.pbxproj"

    if not pbxproj.exists():
        print(f"!! 找不到 {pbxproj}\n   请先运行: python3 scripts/generate_xcodeproj.py", file=sys.stderr)
        return 1

    text = pbxproj.read_text(encoding="utf-8")
    failures: list[str] = []

    # ---------- 0. OpenStep plist 结构完整性（最先查：结构坏了后面都不可信） ----------
    failures.extend(check_objects_structure(text))

    # ---------- 1. UUID 引用完整性 ----------
    defined = collections.Counter(DEF_RE.findall(text))
    referenced = set(UUID_RE.findall(text))

    duplicates = [u for u, count in defined.items() if count > 1]
    if duplicates:
        failures.append(f"UUID 被重复定义: {duplicates}")

    missing = sorted(referenced - set(defined))
    if missing:
        failures.append(f"UUID 被引用但未定义（Xcode 会打不开工程）: {missing}")

    orphans = sorted(set(defined) - referenced)
    if orphans:
        failures.append(f"UUID 定义了但从未被引用（疑似漏挂 build phase）: {orphans}")

    # ---------- 2. 必需结构 ----------
    required_strings = {
        "archiveVersion": "archiveVersion = 1;",
        "objectVersion": "objectVersion = 56;",
        "PBXProject": "isa = PBXProject;",
        "INFOPLIST_FILE": "INFOPLIST_FILE = LUMI/Resources/Info.plist;",
        "GENERATE_INFOPLIST_FILE=NO": "GENERATE_INFOPLIST_FILE = NO;",
        "iOS 17 部署目标": "IPHONEOS_DEPLOYMENT_TARGET = 17.0;",
        "bundle id": "PRODUCT_BUNDLE_IDENTIFIER = com.lumi.aicamera;",
        "测试 TEST_HOST": "TEST_HOST = ",
        "Swift 版本": "SWIFT_VERSION = 5.0;",
        "可支持 iPhone+iPad": 'TARGETED_DEVICE_FAMILY = "1,2";',
    }
    for label, needle in required_strings.items():
        if needle not in text:
            failures.append(f"缺少必需配置: {label} ({needle})")

    if text.count("isa = PBXNativeTarget;") != 2:
        failures.append("应当恰好有 2 个 native target（LUMI + LUMITests）")
    if "isa = PBXTargetDependency;" not in text:
        failures.append("LUMITests 缺少对 App target 的依赖")
    if text.count("isa = XCBuildConfiguration;") != 6:
        failures.append("应当恰好有 6 个 build configuration（project/app/test × Debug/Release）")

    if not re.search(r"rootObject = [0-9A-F]{24} /\* Project object \*/;", text):
        failures.append("rootObject 缺失或格式不对")

    # ---------- 3. Sources 阶段是否覆盖磁盘上的全部 Swift 文件 ----------
    expected_app = collect_swift(root, "LUMI")
    expected_test = collect_swift(root, "LUMITests")
    expected_all = expected_app + expected_test

    sources_body = section(text, "PBXSourcesBuildPhase")
    in_sources = set(re.findall(r"/\* (\S+\.swift) in Sources \*/", sources_body))

    expected_names = {Path(p).name for p in expected_all}
    only_on_disk = expected_names - in_sources
    only_in_project = in_sources - expected_names

    if only_on_disk:
        failures.append(
            f"磁盘上存在但没进 Sources 阶段（会编译失败）: {sorted(only_on_disk)}"
        )
    if only_in_project:
        failures.append(
            f"工程里引用了但磁盘上不存在（会报 missing file）: {sorted(only_in_project)}"
        )

    # ---------- 4. Resources 阶段 ----------
    resources_body = section(text, "PBXResourcesBuildPhase")
    for resource in ("Assets.xcassets", "pose_library.json"):
        if f"{resource} in Resources" not in resources_body:
            failures.append(f"资源未加入 Copy Bundle Resources: {resource}")

    if "Info.plist in Resources" in resources_body:
        failures.append(
            "Info.plist 不应出现在 Resources 阶段（会与 INFOPLIST_FILE 冲突、告警）"
        )

    # ---------- 输出 ----------
    app_source_count = len([p for p in expected_all if p.startswith("LUMI/")])
    test_source_count = len([p for p in expected_all if p.startswith("LUMITests/")])
    resource_entries = len(re.findall("in Resources \\*/", resources_body))

    print(f"工程文件    : {pbxproj}")
    print(f"定义对象    : {len(defined)}")
    print(f"引用 UUID   : {len(referenced)}")
    print(f"Sources 条目: {len(in_sources)}  （App {app_source_count} + 测试 {test_source_count}）")
    print(f"资源条目    : {resource_entries}")

    if failures:
        print("\n发现问题：", file=sys.stderr)
        for item in failures:
            print(f"  ✗ {item}", file=sys.stderr)
        return 1

    print("\n✓ 工程文件结构校验全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
