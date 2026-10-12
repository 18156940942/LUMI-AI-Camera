#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI —— SwiftUI 观察链完整性检查
================================

为什么需要这个脚本
------------------
这是一个**真实踩过的坑**，而且它让 App 在真机上直接卡死：

    final class AppState: ObservableObject {
        let settings: SettingsStore      // ← 普通 let，不是 @Published
    }

    struct RootView: View {
        @EnvironmentObject private var app: AppState        // 只订阅了 AppState
        ...
        get: { !app.settings.hasAcknowledgedPrivacy }       // 却去读子 Store
    }

子 Store 变化时发出的是 `SettingsStore.objectWillChange`，而 `RootView` 订阅的是
`AppState.objectWillChange`。SwiftUI 只重算订阅了变化对象的视图，所以 `RootView.body`
从不重算、Binding 的 `get` 从不重读 —— 值明明改成了 `true`，全屏隐私页却一直盖着。
表现就是**「点我已了解，进入 LUMI」没反应**。

这类缺陷有三个特点，决定了它必须靠静态检查兜住：

  1. **能编译**，编译器不会报任何错；
  2. **能过单元测试**，因为它不涉及任何可断言的逻辑（要做 UI 测试才能发现）；
  3. **只有真机点一下才暴露**，而本项目恰恰没有 Mac，改一次要等十几分钟云端构建。

同样的模式还会造成「首页收藏数不刷新」「诊断报告写进过期的姿势库条目数」等
更隐蔽的问题 —— 不崩溃，只是安静地显示错的数据。

检查规则
--------
对每个 Swift 文件：

  1. 收集它通过 `@EnvironmentObject` 订阅了哪些类型；
  2. 找出它把哪个变量声明为 `AppState`（通常叫 `app`）；
  3. 扫描该变量上的每一处属性访问 `app.<属性>`；
  4. 如果 `<属性>` 是 `AppState` 持有的子 Store，或是一个**间接读了子 Store 的计算属性**，
     而该 View 又没有订阅这个子 Store 的类型 → 报错。

注释会被先剥掉，避免文档里举例说明的写法被误报。

用法
----
    python3 scripts/check_observation.py

发现问题时返回非 0 退出码。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "LUMI"

# 已知的全局环境对象类型（视图通过 @EnvironmentObject 订阅它们）
ENV_TYPES = {
    "AppState",
    "SettingsStore",
    "FavoritesStore",
    "PoseLibrary",
    "VideoInputManager",
    "PhotoLibraryStore",
    "DiagnosticsLog",
}


# ---------------------------------------------------------------------------
# 剥注释：必须做，否则文档注释里举例写出的 `app.settings.x` 会被误报
# ---------------------------------------------------------------------------

def strip_comments(src: str) -> str:
    """去掉行注释与块注释，保留其余字符（长度不保证一致，行号会失效，
    因此本函数改为「用等长空白替换注释」，以便报告准确行号。"""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        # 行注释
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        # 块注释（Swift 支持嵌套）
        if src.startswith("/*", i):
            depth, k = 1, i + 2
            while k < n and depth:
                if src.startswith("/*", k):
                    depth += 1
                    k += 2
                elif src.startswith("*/", k):
                    depth -= 1
                    k += 2
                else:
                    k += 1
            for m in range(i, min(k, n)):
                if out[m] != "\n":
                    out[m] = " "
            i = k
            continue
        # 字符串字面量：整体跳过，避免其中的 // 被当成注释
        if src[i] == '"':
            k = i + 1
            while k < n:
                if src[k] == "\\":
                    k += 2
                    continue
                if src[k] == '"':
                    k += 1
                    break
                k += 1
            i = k
            continue
        i += 1
    return "".join(out)


def brace_body(text: str, brace_index: int) -> str:
    """从 `{` 的下标开始，返回配对花括号之间的内容。"""
    depth = 0
    i = brace_index
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace_index + 1:i]
        i += 1
    return text[brace_index + 1:]


# ---------------------------------------------------------------------------
# 解析 AppState：哪些属性是子 Store，哪些计算属性间接读了子 Store
# ---------------------------------------------------------------------------

def parse_app_state(text: str) -> tuple[dict[str, str], dict[str, set[str]]]:
    """返回 (store_props, computed_deps)。

    store_props   : {属性名: 类型名}      例如 {"settings": "SettingsStore"}
    computed_deps : {计算属性名: {类型名}} 例如 {"inputAvailabilitySummary": {"VideoInputManager"}}
    """
    cleaned = strip_comments(text)

    store_props: dict[str, str] = {}
    for m in re.finditer(r"^\s{4}let\s+(\w+)\s*:\s*(\w+)\s*$", cleaned, re.M):
        store_props[m.group(1)] = m.group(2)

    # 去掉 init 参数区，避免把 `settings: SettingsStore` 之类误当成计算属性
    computed_deps: dict[str, set[str]] = {}
    init_at = cleaned.find("    init(")
    scan_from = init_at if init_at > 0 else len(cleaned)
    head = cleaned[:init_at] if init_at > 0 else cleaned
    tail = cleaned[init_at:] if init_at > 0 else ""

    # 计算属性形如 `    var name: Type {`（不带 `=`，即不是 stored property）
    for source in (head, tail):
        for m in re.finditer(r"^\s{4}var\s+(\w+)\s*:\s*[^{=\n]+\{\s*$", source, re.M):
            body = brace_body(source, m.end() - 1)
            deps = {store_props[n] for n in store_props if re.search(rf"\b{re.escape(n)}\b", body)}
            if deps:
                computed_deps[m.group(1)] = deps

    return store_props, computed_deps


# ---------------------------------------------------------------------------
# 检查单个 Swift 文件
# ---------------------------------------------------------------------------

def check_file(path: Path, store_props: dict[str, str], computed_deps: dict[str, set[str]]) -> list[str]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = strip_comments(raw)

    declared: dict[str, str] = {}
    for m in re.finditer(
        r"@EnvironmentObject\s+(?:private\s+)?var\s+(\w+)\s*:\s*(\w+)", text
    ):
        declared[m.group(1)] = m.group(2)

    if not declared:
        return []

    app_state_vars = [name for name, typ in declared.items() if typ == "AppState"]
    if not app_state_vars:
        return []

    # 这个文件订阅到的全部类型（`app` 本身不解决子 Store 的刷新问题）
    observed = {t for n, t in declared.items() if t != "AppState"}

    violations: list[str] = []
    for var in app_state_vars:
        for m in re.finditer(rf"\b{re.escape(var)}\.(\w+)", text):
            prop = m.group(1)
            needed: set[str] = set()
            if prop in store_props:
                needed = {store_props[prop]}
            elif prop in computed_deps:
                needed = set(computed_deps[prop])
            if not needed:
                continue
            missing = needed - observed
            if not missing:
                continue
            line = text[:m.start()].count("\n") + 1
            violations.append(
                f"{path.relative_to(ROOT)}:{line}  读了 `{var}.{prop}`，"
                f"但没有订阅 {', '.join(sorted(missing))}"
            )
    return violations


def main() -> int:
    app_state_path = APP_DIR / "App" / "AppState.swift"
    if not app_state_path.exists():
        print(f"✗ 找不到 {app_state_path}")
        return 1

    store_props, computed_deps = parse_app_state(app_state_path.read_text(encoding="utf-8"))

    print("LUMI —— SwiftUI 观察链完整性检查")
    print(f"  AppState 持有的子 Store：{len(store_props)} 个")
    for name, typ in store_props.items():
        print(f"    · {name} : {typ}")
    if computed_deps:
        print(f"  间接依赖子 Store 的计算属性：{len(computed_deps)} 个")
        for name, deps in computed_deps.items():
            print(f"    · {name} → {', '.join(sorted(deps))}")

    files = sorted(APP_DIR.rglob("*.swift"))
    all_violations: list[str] = []
    for f in files:
        all_violations += check_file(f, store_props, computed_deps)

    print()
    print(f"  扫描了 {len(files)} 个 Swift 文件")
    if all_violations:
        print()
        print(f"✗ 发现 {len(all_violations)} 处观察链断裂：")
        for v in all_violations:
            print(f"   {v}")
        print()
        print("   修法：给该 View 补上对应的 @EnvironmentObject 声明，")
        print("        例如 `@EnvironmentObject private var settings: SettingsStore`，")
        print("        并把 `app.settings.x` 改成 `settings.x`。")
        return 1

    print("✓ 所有 View 都订阅了它们实际读取的 Store")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
