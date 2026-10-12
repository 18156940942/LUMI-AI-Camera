#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""协议一致性静态检查 —— 找出「声明了 Hashable 但存储属性不可哈希」的合成失败。

## 为什么需要它

Swift 只有在**所有存储属性都满足协议**时才能自动合成 `Hashable` / `Equatable`。
不满足时报错发生在编译期：

    error: type 'ShootingPreset' does not conform to protocol 'Hashable'
    note:  stored property type 'OverlayConfiguration' does not conform to
           protocol 'Hashable', preventing synthesized conformance

在 Windows 上没有 swiftc，这类错误只能等云端 CI 编译才暴露 —— 每暴露一个就要
重跑一轮 macOS 构建。这个脚本用静态分析把「成员类型不可哈希」提前找出来。

## 判定规则

- 声明里显式写了 `Hashable` 的 struct/class/enum → 视为需要检查
- 成员类型视为「可哈希」的情况：
  * 基础类型白名单（String / Int / Double / Date / UUID / CGPoint …）
  * 项目里显式声明了 `Hashable` 的类型
  * 任意 `enum`（无关联值的枚举 Swift 自动满足 Hashable）
  * 可选类型 `T?`、数组 `[T]`、字典 `[K: V]` → 递归看内部类型
- 其余 struct/class 成员视为可疑 → 报告

用法：
    python3 scripts/check_conformance.py            # 扫描 LUMI/ 与 LUMITests/
    python3 scripts/check_conformance.py <路径>      # 扫描指定文件或目录（自测用）
退出码 0 = 未发现问题；1 = 有可疑项。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# 基础类型白名单：这些类型本身满足 Hashable
BUILTIN_HASHABLE = {
    # Swift 标准库
    "String", "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Double", "Float", "Bool", "Character", "Date", "Data",
    "UUID", "URL", "TimeInterval", "IndexPath", "AnyHashable",
    # CoreGraphics / Foundation 值类型
    "CGFloat", "CGPoint", "CGSize", "CGRect", "CGVector", "CGColor",
    "Decimal", "DateComponents", "Calendar", "TimeZone", "Locale",
    # AVFoundation
    "CMTime", "CMTimeRange",
    # 容器与函数类型（不参与检查）
    "Void", "Any",
}

DECL_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<kind>struct|final class|class|enum)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?P<rest>[^{]*)\{",
    re.M,
)

# 存储属性签名：`var name: Type` 或 `var name: Type = default`。
# 刻意排除含 `{` 的行 —— 那是计算属性或闭包初始化，不是存储属性。
# 没有类型标注的属性（`var showThirds = true`）也不需要检查（Bool 必然可哈希）。
PROP_RE = re.compile(
    r"^[ \t]*(?:(?:public|internal|private|fileprivate|package|open)\s+)?"
    r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^={]+?)\s*(?:=\s*[^{]*)?$"
)


def indent_width(line: str) -> int:
    """按 4 空格一级估算缩进宽度（本代码库统一 4 空格）。"""
    stripped = line.lstrip(" \t")
    prefix = line[: len(line) - len(stripped)]
    return prefix.count(" ") + prefix.count("\t") * 4


def own_properties(lines: list[str], decl_index: int, decl_indent: int) -> list[tuple[str, str]]:
    """取该声明**自身层级**的存储属性。

    只认恰好深一级（decl_indent + 4）的行：
    - 更深 → 属于某个嵌套类型 / 计算属性的 body，跳过
    - 更浅或同级 → 说明该类型的块已经结束，停止

    这样既不会被嵌套类型串味（曾经把 `PoseRecommender.weights` 错记到嵌套的
    `Query` 名下），也不会被计算属性的大括号带偏。
    """
    props: list[tuple[str, str]] = []
    for line in lines[decl_index + 1:]:
        if not line.strip():
            continue
        width = indent_width(line)
        if width <= decl_indent:
            break
        if width != decl_indent + 4:
            continue
        match = PROP_RE.match(line)
        if match:
            props.append((match.group(1), match.group(2).strip()))
    return props


def collect(
    paths: list[Path],
) -> tuple[dict[str, str], dict[str, list[tuple[str, str]]], dict[str, str]]:
    """返回 (类型名 -> 声明的协议串, 类型名 -> [(属性名, 类型串)], 类型名 -> 种类)。"""
    protocols: dict[str, str] = {}
    properties: dict[str, list[tuple[str, str]]] = {}
    kinds: dict[str, str] = {}

    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        lines = text.split("\n")
        for index, line in enumerate(lines):
            match = DECL_RE.match(line)
            if not match:
                continue
            name = match.group("name")
            protocols[name] = match.group("rest") or ""
            kinds[name] = match.group("kind")
            properties[name] = own_properties(lines, index, indent_width(line))

    return protocols, properties, kinds


def base_identifiers(type_text: str) -> list[str]:
    """从类型串里取出所有可能的类型名（去掉可选、数组、字典、泛型、默认值）。"""
    cleaned = type_text.split("=")[0]
    cleaned = re.sub(r"[?\[\]():{}<>,]", " ", cleaned)
    return [token for token in cleaned.split() if token and token[0].isupper()]


def is_hashable(type_text: str, protocols: dict[str, str], kinds: dict[str, str],
                project_types: set[str]) -> tuple[bool, str]:
    identifiers = base_identifiers(type_text)
    if not identifiers:
        return True, ""
    for ident in identifiers:
        if ident in BUILTIN_HASHABLE:
            continue
        if ident not in project_types:
            # 系统框架里的未知类型（例如 CVPixelBuffer）——无法静态判断，放行
            continue
        if "Hashable" in protocols.get(ident, ""):
            continue
        if kinds.get(ident) == "enum":
            # 无关联值的枚举 Swift 自动满足 Hashable
            continue
        return False, ident
    return True, ""


def swift_files(targets: list[str]) -> list[Path]:
    if not targets:
        root = Path(__file__).resolve().parent.parent
        targets = [str(root / "LUMI"), str(root / "LUMITests")]
    files: list[Path] = []
    for target in targets:
        path = Path(target)
        if path.is_dir():
            files.extend(sorted(path.rglob("*.swift")))
        elif path.exists():
            files.append(path)
    return files


def main(argv: list[str]) -> int:
    files = swift_files(argv[1:])
    if not files:
        print("!! 没有找到 .swift 文件", file=sys.stderr)
        return 1

    protocols, properties, kinds = collect(files)
    project_types = set(protocols)

    problems: list[str] = []
    checked = 0
    for name, protocol_text in sorted(protocols.items()):
        if "Hashable" not in protocol_text:
            continue
        checked += 1
        for prop_name, prop_type in properties.get(name, []):
            ok, bad = is_hashable(prop_type, protocols, kinds, project_types)
            if not ok:
                problems.append(
                    f"{name}.{prop_name}: {prop_type.strip()}  ← 类型 {bad} 未满足 Hashable，"
                    f"会导致 {name} 合成失败"
                )

    print(f"Swift 文件    : {len(files)}")
    print(f"声明类型      : {len(protocols)}")
    print(f"检查 Hashable : {checked} 个")

    if problems:
        print("\n可疑项：", file=sys.stderr)
        for item in problems:
            print(f"  ✗ {item}", file=sys.stderr)
        return 1

    print("\n✓ 未发现 Hashable 合成隐患")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
