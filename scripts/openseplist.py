#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OpenStep 风格 plist（old-style property list）解析器 —— 纯标准库，零依赖。

## 为什么需要它

`project.pbxproj` 是 OpenStep plist，Xcode 用它自己的 CFPropertyList 解析。
在 Windows 上没有 Xcode，而**正则校验只能看出「像不像」，看不出「语法对不对」**。

本项目为此付出过代价：连续两轮 CI 都因为极小的 pbxproj 语法错误被 Xcode 判为
    The project 'LUMI' is damaged and cannot be opened due to a parse error.
而当时的正则校验全部绿灯：

  1. 对象头丢失（只剩孤儿属性）—— 字符串切割组装导致
  2. `path = ;`（空值）—— 组路径为空字符串时产生

这两类问题，任何真正的文法解析器都能立刻发现。所以这里按文法实现一个。

## 文法（对应 CFPropertyList 的 old-style 解析）

    plist    := value
    value    := dict | array | quoted | data | unquoted
    dict     := '{' (key '=' value ';')* '}'
    array    := '(' (value (',' value)* ','? )? ')'
    quoted   := '"' (escape | char)* '"'
    data     := '<' hexdigit* '>'
    key      := quoted | unquoted
    unquoted := [A-Za-z0-9_$/:.+-]+

  注释：`/* … */` 与 `// 到行尾`

## 用法

    from openseplist import parse, PlistSyntaxError

    python3 scripts/openseplist.py LUMI.xcodeproj/project.pbxproj   # CLI 自检
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# 未加引号的字符串允许的字符集（与 CFPropertyList 的 old-style 解析一致）
UNQUOTED_CHARS = set(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    "_$/:.-+"
)
WHITESPACE = " \t\r\n"

_INT_RE = re.compile(r"-?\d+")
_FLOAT_RE = re.compile(r"-?\d+\.\d+")


class PlistSyntaxError(Exception):
    """带位置信息的语法错误。"""

    def __init__(self, message: str, line: int, column: int, snippet: str = "") -> None:
        self.line = line
        self.column = column
        self.snippet = snippet
        text = f"第 {line} 行第 {column} 列：{message}"
        if snippet:
            text += f"\n      该行内容: {snippet}"
        super().__init__(text)


class Parser:
    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0
        self.line = 1
        self.col = 1

    # ------------------------------------------------------------------ 底层

    def _peek(self) -> str:
        return self.text[self.pos] if self.pos < len(self.text) else ""

    def _advance(self, count: int = 1) -> None:
        for _ in range(count):
            if self.pos >= len(self.text):
                return
            if self.text[self.pos] == "\n":
                self.line += 1
                self.col = 1
            else:
                self.col += 1
            self.pos += 1

    def _error(self, message: str) -> PlistSyntaxError:
        start = self.text.rfind("\n", 0, self.pos) + 1
        end = self.text.find("\n", self.pos)
        if end == -1:
            end = len(self.text)
        snippet = self.text[start:end].strip()
        if len(snippet) > 88:
            snippet = snippet[:88] + "…"
        return PlistSyntaxError(message, self.line, self.col, snippet)

    def _skip_ws_and_comments(self) -> None:
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char in WHITESPACE:
                self._advance()
            elif char == "/" and self.text.startswith("//", self.pos):
                while self.pos < len(self.text) and self.text[self.pos] != "\n":
                    self._advance()
            elif char == "/" and self.text.startswith("/*", self.pos):
                end = self.text.find("*/", self.pos + 2)
                if end == -1:
                    raise self._error("块注释 /* 没有闭合")
                self._advance(end + 2 - self.pos)
            else:
                return

    # ------------------------------------------------------------------ 语法

    def parse(self):
        self._skip_ws_and_comments()
        value = self._parse_value()
        self._skip_ws_and_comments()
        if self.pos != len(self.text):
            raise self._error(f"顶层解析结束后仍有多余内容 {self._peek()!r}")
        return value

    def _parse_value(self):
        self._skip_ws_and_comments()
        char = self._peek()
        if char == "":
            raise self._error("期望一个值，但文件已结束")
        if char == "{":
            return self._parse_dict()
        if char == "(":
            return self._parse_array()
        if char == '"':
            return self._parse_quoted()
        if char == "<":
            return self._parse_data()
        if char in UNQUOTED_CHARS:
            return self._parse_unquoted()
        # 空值 `= ;` 会走到这里：期望值却遇到 ';'
        raise self._error(f"期望一个值（{{ ( \" 或数字），却遇到 {char!r}")

    def _parse_dict(self) -> dict:
        self._advance()  # 吃掉 '{'
        result: dict = {}
        while True:
            self._skip_ws_and_comments()
            char = self._peek()
            if char == "":
                raise self._error("字典 '{' 没有闭合")
            if char == "}":
                self._advance()
                return result
            key = self._parse_key()
            self._skip_ws_and_comments()
            if self._peek() != "=":
                raise self._error(f"键 {key!r} 之后期望 '='，却遇到 {self._peek()!r}")
            self._advance()  # 吃掉 '='
            value = self._parse_value()
            self._skip_ws_and_comments()
            if self._peek() != ";":
                raise self._error(
                    f"键 {key!r} 的值之后期望 ';'，却遇到 {self._peek()!r}"
                )
            self._advance()  # 吃掉 ';'
            result[key] = value

    def _parse_array(self) -> list:
        self._advance()  # 吃掉 '('
        items: list = []
        while True:
            self._skip_ws_and_comments()
            char = self._peek()
            if char == "":
                raise self._error("数组 '(' 没有闭合")
            if char == ")":
                self._advance()
                return items
            items.append(self._parse_value())
            self._skip_ws_and_comments()
            char = self._peek()
            if char == ",":  # 允许尾随逗号（Xcode 自己就会生成）
                self._advance()
                continue
            if char == ")":
                self._advance()
                return items
            raise self._error(f"数组元素之后期望 ',' 或 ')'，却遇到 {char!r}")

    def _parse_key(self) -> str:
        char = self._peek()
        if char == '"':
            return self._parse_quoted()
        if char in UNQUOTED_CHARS:
            return self._parse_unquoted()
        raise self._error(f"期望一个键，却遇到 {char!r}")

    def _parse_quoted(self) -> str:
        self._advance()  # 吃掉开引号
        out: list[str] = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "0": "\0"}
        while True:
            if self.pos >= len(self.text):
                raise self._error("字符串引号没有闭合")
            char = self.text[self.pos]
            if char == "\\":
                self._advance()
                nxt = self._peek()
                if nxt == "":
                    raise self._error("转义符之后文件结束")
                out.append(escapes.get(nxt, nxt))
                self._advance()
            elif char == '"':
                self._advance()
                return "".join(out)
            else:
                out.append(char)
                self._advance()

    def _parse_data(self) -> bytes:
        self._advance()  # 吃掉 '<'
        start = self.pos
        while self.pos < len(self.text) and self.text[self.pos] != ">":
            self._advance()
        if self.pos >= len(self.text):
            raise self._error("数据 '<' 没有闭合")
        raw = "".join(self.text[start:self.pos].split())
        self._advance()  # 吃掉 '>'
        try:
            return bytes.fromhex(raw)
        except ValueError:
            raise self._error(f"数据内容不是合法十六进制: {raw[:40]!r}") from None

    def _parse_unquoted(self):
        start = self.pos
        while self.pos < len(self.text) and self.text[self.pos] in UNQUOTED_CHARS:
            self._advance()
        token = self.text[start:self.pos]
        if _INT_RE.fullmatch(token):
            return int(token)
        if _FLOAT_RE.fullmatch(token):
            return float(token)
        return token


def parse(text: str):
    """解析 OpenStep plist 文本；语法错误会抛 PlistSyntaxError。"""
    return Parser(text).parse()


def load(path: str | Path):
    """读取并解析文件（UTF-8）。"""
    return parse(Path(path).read_text(encoding="utf-8"))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"用法: {Path(argv[0]).name} <plist 文件>", file=sys.stderr)
        return 2
    target = Path(argv[1])
    if not target.exists():
        print(f"!! 文件不存在: {target}", file=sys.stderr)
        return 1
    try:
        root = load(target)
    except PlistSyntaxError as error:
        print(f"✗ 语法错误 — {target}")
        print(f"  {error}")
        return 1
    if not isinstance(root, dict):
        print(f"✗ 顶层不是字典（实际是 {type(root).__name__}）")
        return 1
    objects = root.get("objects")
    print(f"✓ 解析成功 — {target}")
    print(f"  顶层键: {', '.join(sorted(root))}")
    if isinstance(objects, dict):
        print(f"  对象数: {len(objects)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
