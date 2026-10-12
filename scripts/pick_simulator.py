#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
挑一台可用的 iPhone 模拟器（供 CI 使用）
=======================================

为什么需要它？
--------------
GitHub 的 macOS runner 镜像会随 Xcode 版本更新模拟器列表。
把 `-destination "platform=iOS Simulator,name=iPhone 15 Pro"` 写死在 workflow 里，
迟早会因为「那台机器上已经没有这个型号了」而整条流水线失败 —— 而且报错信息
通常是含糊的「Unable to find a destination matching the provided destination specifier」。

所以改成：读取 `xcrun simctl list devices available --json`，动态挑一台运行版本最高的 iPhone。

用法（只能在 macOS 上跑）：
    UDID=$(python3 scripts/pick_simulator.py)
    xcodebuild test -destination "id=$UDID"

输出约定：
    stdout —— 仅一行 UDID，方便直接赋值给 shell 变量
    stderr —— 人类可读的说明，例如 "iOS 18.2 / iPhone 16"
"""

from __future__ import annotations

import json
import re
import subprocess
import sys


def runtime_sort_key(runtime_identifier: str) -> tuple:
    """把 'com.apple.CoreSimulator.SimRuntime.iOS-18-2' 变成可排序的元组 (18, 2)。

    注意不能直接按字符串排序：字符串比较下 "iOS-9-0" > "iOS-18-2"，会挑错版本。
    """
    tail = runtime_identifier.rsplit(".", 1)[-1]          # iOS-18-2
    numbers = re.findall(r"\d+", tail)
    if not numbers:
        return (0,)
    return tuple(int(n) for n in numbers)


def device_sort_key(name: str) -> tuple:
    """把模拟器名称变成可排序的元组，语义是「机型越新越大」。

    踩过的坑：直接按名称字符串排序时 "iPhone SE (3rd generation)" 会排在
    "iPhone 15 Pro" **之后**（因为 'S' > '1'），于是「取最后一台」挑到的是 SE。
    所以要先抽出机型代数再比较；没有代数的型号（SE / 简单款）按 0 处理。
    """
    match = re.search(r"iPhone\s+(\d+)", name)
    generation = int(match.group(1)) if match else 0
    # 同代数下把 Pro / Pro Max 排前面（屏幕更大、更接近目标机型）
    tier = 2 if "Pro Max" in name else (1 if "Pro" in name else 0)
    return (generation, tier, name)


def main() -> int:
    try:
        raw = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except FileNotFoundError:
        print("找不到 xcrun —— 本脚本只能在 macOS 上运行。", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"xcrun simctl 执行失败：{error.stderr or error}", file=sys.stderr)
        return 1

    try:
        devices_by_runtime = json.loads(raw)["devices"]
    except (json.JSONDecodeError, KeyError) as error:
        print(f"无法解析 simctl 输出：{error}", file=sys.stderr)
        return 1

    candidates: list[tuple[tuple, str, str]] = []
    for runtime, devices in devices_by_runtime.items():
        if "iOS" not in runtime:            # 排除 watchOS / tvOS / visionOS
            continue
        for device in devices:
            if not device.get("isAvailable"):
                continue
            if not device.get("name", "").startswith("iPhone"):
                continue
            candidates.append((runtime_sort_key(runtime), device["udid"], device["name"]))

    if not candidates:
        print("找不到任何可用的 iPhone 模拟器。", file=sys.stderr)
        print("提示：可在 workflow 里先执行 "
              "`xcrun simctl runtime list` 检查运行时是否已安装。", file=sys.stderr)
        return 1

    # 运行版本最高的优先；同版本下挑机型代数最新的
    candidates.sort(key=lambda item: (item[0], device_sort_key(item[2])))
    _, udid, name = candidates[-1]

    print(f"{name}", file=sys.stderr)          # 人类可读
    print(udid)                                 # 供 shell 取值
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
