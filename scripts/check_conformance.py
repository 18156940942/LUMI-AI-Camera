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
# 允许 @Published 等属性包装器与访问修饰符前缀。
# 注意：调用前会先把声明行末尾的 `{`（属性观察器 / 计算属性）剥掉，
# 并拒绝任何仍含 `{` 的行（闭包初始化等无法静态判断）。
PROP_RE = re.compile(
    r"^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|package|open)\s+)?"
    r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^={]+?)\s*(?:=(.*))?$"
)

INIT_RE = re.compile(
    r"^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*\s+)*"
    r"(?:(?:public|internal|private|fileprivate|package|open)\s+)*"
    r"(?:convenience\s+|required\s+|override\s+)*init\s*[(!]"
)

STRING_RE = re.compile(r'"(?:[^"\\]|\\.)*"')


def strip_string_literals(line: str) -> str:
    """把字符串字面量替换成空串，避免其中的大括号干扰计数。"""
    return STRING_RE.sub('""', line)


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


def stored_properties(
    lines: list[str], decl_index: int, decl_indent: int
) -> list[tuple[str, str, bool]]:
    """取存储属性，附「是否有默认值」，用于初始化完整性检查。

    与 `own_properties` 的区别：
    - 支持 `@Published` 等属性包装器
    - 区分「带观察器的存储属性」和「计算属性」：声明行以 `{` 结尾时，看块里
      有没有 didSet / willSet —— 有则是存储属性，没有则按计算属性跳过
    """
    out: list[tuple[str, str, bool]] = []
    index = decl_index + 1
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            index += 1
            continue
        width = indent_width(line)
        if width <= decl_indent:
            break
        if width != decl_indent + 4:
            index += 1
            continue

        candidate = line.rstrip()
        opens_block = candidate.endswith("{")
        if opens_block:
            candidate = candidate[:-1].rstrip()
        if "{" in candidate or "}" in candidate:
            # 闭包初始化等无法静态判断，跳过
            index += 1
            continue

        match = PROP_RE.match(candidate)
        if not match:
            index += 1
            continue

        name = match.group(1)
        type_text = match.group(2).strip()
        has_default = match.group(3) is not None

        if opens_block:
            probe = index + 1
            is_stored = False
            while probe < len(lines):
                body_line = lines[probe]
                if not body_line.strip():
                    probe += 1
                    continue
                if indent_width(body_line) <= decl_indent + 4:
                    break
                if "didSet" in body_line or "willSet" in body_line:
                    is_stored = True
                    break
                probe += 1
            if not is_stored:
                index += 1
                continue

        out.append((name, type_text, has_default))
        index += 1
    return out


def init_bodies(lines: list[str], decl_index: int, decl_indent: int) -> list[str]:
    """取该类型自身层级上所有 `init` 的完整 body 文本（用大括号配对界定）。"""
    bodies: list[str] = []
    index = decl_index + 1
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            index += 1
            continue
        width = indent_width(line)
        if width <= decl_indent:
            break
        if width == decl_indent + 4 and INIT_RE.match(line):
            collected: list[str] = []
            depth = 0
            started = False
            cursor = index
            while cursor < len(lines):
                current = strip_string_literals(lines[cursor])
                depth += current.count("{") - current.count("}")
                if depth > 0:
                    started = True
                collected.append(lines[cursor])
                if started and depth <= 0:
                    break
                cursor += 1
            bodies.append("\n".join(collected))
            index = cursor + 1
            continue
        index += 1
    return bodies


def collect(
    paths: list[Path],
) -> tuple[dict[str, str], dict[str, list[tuple[str, str]]], dict[str, str],
           dict[str, list[tuple[str, str, bool]]], dict[str, list[str]]]:
    """汇总所有类型的协议、属性、初始化信息。"""
    protocols: dict[str, str] = {}
    properties: dict[str, list[tuple[str, str]]] = {}
    kinds: dict[str, str] = {}
    stored: dict[str, list[tuple[str, str, bool]]] = {}
    inits: dict[str, list[str]] = {}

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
            indent = indent_width(line)
            protocols[name] = match.group("rest") or ""
            kinds[name] = match.group("kind")
            properties[name] = own_properties(lines, index, indent)
            stored[name] = stored_properties(lines, index, indent)
            inits[name] = init_bodies(lines, index, indent)

    return protocols, properties, kinds, stored, inits


ASSIGN_RE = re.compile(r"(?:self\.)?([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)")


def check_initialization(
    stored: dict[str, list[tuple[str, str, bool]]], inits: dict[str, list[str]]
) -> list[str]:
    """检查显式写了 init 的类型是否初始化了全部无默认值的存储属性。

    Swift 的规则：类的指定初始化器返回前，每个没有默认值的存储属性都必须被赋值。
    漏掉一个就是编译错误 `return from initializer without initializing all stored
    properties` —— SettingsStore 就是这样漏了 showsFrameStats。

    只检查**自己写了 init** 的类型（依赖成员逐一初始化的 struct 不受影响）。
    """
    problems: list[str] = []
    for name, props in sorted(stored.items()):
        bodies = inits.get(name)
        if not bodies:
            continue
        assigned: set[str] = set()
        for body in bodies:
            assigned.update(ASSIGN_RE.findall(body))
        for prop_name, type_text, has_default in props:
            if has_default:
                continue
            # 可选类型（`T?` / `T!`）由 Swift 自动初始化为 nil，不算漏赋值
            if type_text.rstrip().endswith(("?", "!")):
                continue
            if prop_name in assigned:
                continue
            problems.append(
                f"{name}.{prop_name} ({type_text}) 没有默认值且非可选，"
                f"但 init 里没有给它赋值 → 编译报 "
                f"'return from initializer without initializing all stored properties'"
            )
    return problems


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

    protocols, properties, kinds, stored, inits = collect(files)
    project_types = set(protocols)

    # ---- 检查 1：Hashable 合成 ----
    hashable_problems: list[str] = []
    checked = 0
    for name, protocol_text in sorted(protocols.items()):
        if "Hashable" not in protocol_text:
            continue
        checked += 1
        for prop_name, prop_type in properties.get(name, []):
            ok, bad = is_hashable(prop_type, protocols, kinds, project_types)
            if not ok:
                hashable_problems.append(
                    f"{name}.{prop_name}: {prop_type.strip()}  ← 类型 {bad} 未满足 Hashable，"
                    f"会导致 {name} 合成失败"
                )

    # ---- 检查 2：初始化完整性 ----
    init_problems = check_initialization(stored, inits)

    print(f"Swift 文件    : {len(files)}")
    print(f"声明类型      : {len(protocols)}")
    print(f"检查 Hashable : {checked} 个")
    print(f"检查 init     : {len([n for n in inits if inits[n]])} 个类型")

    if hashable_problems or init_problems:
        if hashable_problems:
            print("\nHashable 合成隐患：", file=sys.stderr)
            for item in hashable_problems:
                print(f"  ✗ {item}", file=sys.stderr)
        if init_problems:
            print("\n初始化不完整：", file=sys.stderr)
            for item in init_problems:
                print(f"  ✗ {item}", file=sys.stderr)
        return 1

    print("\n✓ 协议一致性与初始化完整性检查全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
