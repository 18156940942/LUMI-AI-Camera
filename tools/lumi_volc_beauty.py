#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""火山引擎「AI 美颜」云端精修适配层。

它做什么
========

把「一条 LUMI 精修预设」翻译成「一次火山引擎美颜调用」，并把结果图片取回来。

调用链（异步两步，这是火山那边的设计）：

    LUMI App ──► 你的转发端点 ──► POST /openapi/ai_effect/submit  → task_id
                                        │
                                        └─► POST /openapi/ai_effect/query （轮询）
                                                │
                                                └─► result_url → 下载图片 → 回给 App

接口契约（**已核实**，来源见文件末尾）
======================================

    Host            https://kickart.volces.com
    提交            POST /openapi/ai_effect/submit
    查询            POST /openapi/ai_effect/query
    鉴权            Authorization: Bearer {API_KEY}
    Content-Type    application/json
    美颜模板        template_id = "245621002"   （美颜 API V2.0 传统修图，支持自定义参数）
    一键模板        template_id = "245621001"   （AI美颜-Pro，extra 固定为 beautyPro_481）
    图片传入        payload.resource_list —— 元素是公网 URL 或 Base64 Data URI；
                    官方**强烈建议用 Data URI**（公网 URL 会引入上传与可访问性问题）
    提交返回        {"code":0,"message":"success","request_id":"…","data":{"task_id":"…"}}

哪些是核实过的、哪些还需要你用真实账号校准一次
================================================

**已核实**（来自火山官方文档与官方 Go 示例代码）：
  · host / 两个路径 / Bearer 鉴权 / Content-Type
  · 请求体外层结构 `{template_id, payload:{resource_list, extra}, callback_url?}`
  · 响应外层结构 `{code, message, request_id, data:{task_id}}`
  · 两个 template_id、`beautyToolConfigKey` 为必填且取值 `beautyCustom_v1`
  · **`extra` 的分组嵌套**：参数分组（`beauty` / `style_makeup` / `reshape` /
    `bodyshaping` / `image_quality` / `filter`）必须嵌在 `extra.default` 之下 ——
    官方文档给了完整 JSON 样例，且明确「default 为默认参数组必传」
    （见「美颜 API V2.0 传统修图接口文档 (APIKey版)」）
  · 各美化小项的**参数名**（见 PRESETS 里的注释）

**仍需校准**（做了容错 + 探针，真实调用一次即可确认）：
  · 查询接口的入参字段名（我按 `task_id` 发，同时容错 `TaskId` / `taskId`）
  · 查询响应里 `result_url` 的字段路径（做了多路径回退）

所以第一次使用请先跑：

    python tools/lumi_volc_beauty.py --probe --image 你的照片.jpg

它会把**原始请求体与原始响应**都打出来。对着真实响应把 `build_extra()` 或
`extract_result_url()` 微调一下即可 —— 通常一次就够。

用法
====

    export KICKART_API_KEY=你的key

    python tools/lumi_volc_beauty.py --presets                 # 看有哪些预设与参数映射
    python tools/lumi_volc_beauty.py --selftest                # 不需要 key：自检解析逻辑
    python tools/lumi_volc_beauty.py --probe --image a.jpg      # 真实调用一次，打印原始收发
    python tools/lumi_volc_beauty.py --image a.jpg --preset volc.natural --out out.jpg

    # 作为 HTTP 服务跑（给 App 用；也可部署成云函数，见 docs/07）
    python tools/lumi_volc_beauty.py --serve --port 8091

API Key 从哪来
==============

火山引擎控制台 → 创作 Agent(Kickart) → API Key → +New。
控制台地址：https://console.volcengine.com/kickart/fusion/setting/api-key
（必须**主账号**登录；IAM 子账号方式见官方「创建火山引擎API Key」文档，
权限限制需勾选「智能创作云」。）

**注意**：美颜 API 按「创点」计费，需要先购买支持后付费 API 的创点套餐
并开通服务权限，否则会返回权限错误。创点购买是商务流程，不是自助开通 ——
创点购买链接需联系火山技术支持获取；遇到权限错误请找商务代表。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any

# ---------------------------------------------------------------------------
# 已核实的通信常量
# ---------------------------------------------------------------------------

HOST = "https://kickart.volces.com"
SUBMIT_PATH = "/openapi/ai_effect/submit"
QUERY_PATH = "/openapi/ai_effect/query"

#: 美颜 API V2.0 传统修图 —— 支持逐项传参，我们用它。
TEMPLATE_BEAUTY_V2 = "245621002"
#: AI 美颜-Pro —— 一键式，extra 固定。
TEMPLATE_BEAUTY_PRO = "245621001"

#: 必填的公共参数。取值来自官方文档。
BEAUTY_TOOL_CONFIG_KEY_CUSTOM = "beautyCustom_v1"
BEAUTY_TOOL_CONFIG_KEY_PRO = "beautyPro_481"

ENV_API_KEY = "KICKART_API_KEY"


class VolcError(RuntimeError):
    """火山接口返回的业务错误，或本地配置错误。"""

    def __init__(self, message: str, *, code: int | None = None, http_status: int | None = None):
        super().__init__(message)
        self.code = code
        self.http_status = http_status

    def __str__(self) -> str:  # pragma: no cover - 仅用于日志
        parts = [super().__str__()]
        if self.code is not None:
            parts.append(f"code={self.code}")
        if self.http_status is not None:
            parts.append(f"http={self.http_status}")
        return "  ".join(parts)


# ---------------------------------------------------------------------------
# 预设 → 火山参数
# ---------------------------------------------------------------------------
#
# 参数名**全部来自官方文档的分组参数列表**（美颜 / 风格妆 / 微整形 / 美体 / 画质 / 滤镜）。
# 数值范围：绝大多数是 [0,100]；带正负的是双向（如 face_cutface 为 [-50,50]）。
#
# 强度换算：LUMI 的强度是 0–100，这里按「强度/100 × 该预设的基准值」缩放，
# 所以同一条预设也能被用户用滑杆调弱。这是**我们的约定**，不是火山的要求。

@dataclass
class VolcPreset:
    """一条云端预设：LUMI 侧 id + 火山侧参数。"""

    id: str
    title: str
    detail: str
    #: 火山 extra 里的分组参数。值可以是固定数字，也可以是 "基准值" 供强度缩放。
    groups: dict[str, dict[str, float]]
    #: 是否让强度滑杆参与缩放。一键式预设用不上。
    scalable: bool = True
    #: 参数名 → 中文说明，用于界面上如实解释这一条到底做了什么。
    notes: tuple[str, ...] = field(default_factory=tuple)


PRESETS: dict[str, VolcPreset] = {
    "volc.natural": VolcPreset(
        id="volc.natural",
        title="云端自然美颜",
        detail="磨皮 + 肤色统一 + 轻微亮眼。最保守的一条，适合大多数场合先试。",
        groups={
            "beauty": {"unify_skin_color": 55, "sharp": 20, "clear": 15},
            "reshape": {"eye_brighten": 20},
        },
        notes=("肤色统一(unify_skin_color)", "锐化(sharp)", "清晰(clear)", "眼睛-亮眼(eye_brighten)"),
    ),
    "volc.clean": VolcPreset(
        id="volc.clean",
        title="云端干净肤色",
        detail="磨皮 + 去油光 + 美白（粉白）。针对出油、肤质不均的皮肤。",
        groups={
            "beauty": {"yaguang": 60, "unify_skin_color": 60, "whiten_fenbai": 35, "clear": 20},
        },
        notes=("去油光(yaguang)", "肤色统一(unify_skin_color)", "美白-粉白(whiten_fenbai)", "清晰(clear)"),
    ),
    "volc.slimface": VolcPreset(
        id="volc.slimface",
        title="云端微调脸型",
        detail="瘦脸 + 小头 + 亮眼 + 白牙。会改变五官形态 —— 这是液化类处理，不是调色。",
        groups={
            "reshape": {
                "slimface_nature": 35,
                "face_shrinkhead": 20,
                "eye": 15,
                "eye_brighten": 25,
                "whiten_teeth": 20,
                "liuchanglian": 25,
            },
        },
        notes=("面部-瘦脸-自然脸(slimface_nature)", "面部-小头(face_shrinkhead)",
               "眼睛-大小(eye)", "眼睛-亮眼(eye_brighten)",
               "嘴巴-白牙(whiten_teeth)", "流畅脸(liuchanglian)"),
    ),
    "volc.full": VolcPreset(
        id="volc.full",
        title="云端全套精修",
        detail="肤质 + 脸型 + 眼睛 + 牙齿一次做完。改动最明显，也最容易过度。",
        groups={
            "beauty": {"yaguang": 45, "unify_skin_color": 60, "whiten_fenbai": 30,
                       "neck_wrinkles": 30, "sharp": 20, "clear": 20},
            "reshape": {"slimface_nature": 30, "face_shrinkhead": 15, "xiahexian": 20,
                        "eye": 12, "eye_brighten": 25, "nose": 8, "whiten_teeth": 20},
        },
        notes=("去油光", "肤色统一", "美白-粉白", "去颈纹", "锐化", "清晰",
               "瘦脸-自然脸", "小头", "下颌线", "眼睛大小", "亮眼", "瘦鼻", "白牙"),
    ),
    "volc.body": VolcPreset(
        id="volc.body",
        title="云端美体",
        detail="瘦身 + 瘦腰 + 长腿。**会大幅改变画面内容**，半身/全身构图才适用。",
        groups={
            # 分组名与参数名均来自官方「美体 (bodyshaping)」分组列表：
            # 瘦身 slimbody / 长腿 leglength / 瘦腰 slimwaist，范围 [0,100]
            "bodyshaping": {
                "slimbody": 30,
                "slimwaist": 25,
                "leglength": 20,
            },
        },
        notes=("瘦身(slimbody)", "瘦腰(slimwaist)", "长腿(leglength)"),
    ),
}


def build_extra(preset: VolcPreset, intensity: int) -> dict[str, Any]:
    """把一条预设 + 用户强度，翻译成火山 `extra` 对象。

    强度是 LUMI 自己的概念（0–100）。这里按 ``scale = intensity / 100`` 等比缩放
    每一项的基准值，并夹到该参数允许的区间内。

    **分组嵌套**（已按官方 JSON 样例定稿）：参数分组必须嵌在 ``extra.default``
    之下，文档明确「default 为默认参数组必传」：

        extra = {
          "beautyToolConfigKey": "beautyCustom_v1",
          "default": {
            "beauty":  {"unify_skin_color": 55, ...},
            "reshape": {"eye_brighten": 20, ...}
          }
        }
    """
    scale = max(0.0, min(1.0, intensity / 100.0))
    default: dict[str, dict[str, int]] = {}

    for group, params in preset.groups.items():
        if not params:
            continue
        bucket: dict[str, int] = {}
        for key, base in params.items():
            value = base if not preset.scalable else base * scale
            # 双向参数（-50..50）按同样的比例缩放，所以直接取整即可
            bucket[key] = int(round(value))
        default[group] = bucket

    return {
        "beautyToolConfigKey": BEAUTY_TOOL_CONFIG_KEY_CUSTOM,
        "default": default,
    }


# ---------------------------------------------------------------------------
# 客户端
# ---------------------------------------------------------------------------

@dataclass
class VolcBeautyClient:
    """火山美颜 API 的最小客户端。

    刻意只依赖标准库 —— 它要能被塞进任何云函数运行时，包括不装第三方包的。
    """

    api_key: str
    host: str = HOST
    timeout: float = 60.0
    poll_interval: float = 1.5
    poll_timeout: float = 150.0
    debug: bool = False

    # -- 底层 ---------------------------------------------------------------

    def _post(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        if self.debug:
            print(f"[volc] POST {self.host}{path}", file=sys.stderr)
            print(f"[volc] 请求体（图片已截断）:", file=sys.stderr)
            print("        " + _redact(raw.decode("utf-8"))[:2000], file=sys.stderr)

        req = urllib.request.Request(
            f"{self.host}{path}",
            data=raw,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "lumi-volc-beauty/1.0",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = resp.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise VolcError(f"火山接口 HTTP {exc.code}：{detail[:500]}", http_status=exc.code) from exc
        except Exception as exc:  # noqa: BLE001
            raise VolcError(f"连不上火山接口（{type(exc).__name__}: {exc}）") from exc

        if self.debug:
            print("[volc] 原始响应:", file=sys.stderr)
            print("        " + payload.decode("utf-8", errors="replace")[:2000], file=sys.stderr)

        try:
            data = json.loads(payload.decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            raise VolcError(f"响应不是合法 JSON：{payload[:300]!r}") from exc

        code = data.get("code")
        # 官方约定：code == 0 表示成功；非 0 见 message
        if code not in (0, None) and str(code) != "0":
            raise VolcError(
                f"火山返回业务错误：{data.get('message') or '(无 message)'}",
                code=int(code) if isinstance(code, int) else None,
            )
        return data

    # -- 两段式调用 ---------------------------------------------------------

    def submit(self, image_bytes: bytes, extra: dict[str, Any],
               template_id: str = TEMPLATE_BEAUTY_V2,
               mime: str = "image/jpeg") -> str:
        """提交异步任务，返回 task_id。"""
        data_uri = "data:" + mime + ";base64," + base64.b64encode(image_bytes).decode("ascii")
        body = {
            "template_id": template_id,
            "payload": {
                "resource_list": [data_uri],
                "extra": extra,
            },
        }
        resp = self._post(SUBMIT_PATH, body)
        task_id = _dig(resp, ("data", "task_id"))
        if not task_id:
            raise VolcError(f"提交成功但没拿到 task_id，响应：{json.dumps(resp, ensure_ascii=False)[:400]}")
        return str(task_id)

    def query(self, task_id: str) -> dict[str, Any]:
        """查询任务。入参字段名做多写法容错（文档未给样例）。"""
        last: VolcError | None = None
        for field_name in ("task_id", "taskId", "TaskId"):
            try:
                return self._post(QUERY_PATH, {field_name: task_id})
            except VolcError as exc:
                last = exc
                # 只有「参数名不对」这类错误才值得换一种写法重试
                if exc.http_status is not None and exc.http_status < 500:
                    continue
                raise
        assert last is not None
        raise last

    def wait(self, task_id: str) -> str:
        """轮询到完成，返回结果图片 URL。"""
        deadline = time.time() + self.poll_timeout
        last_status = None
        while time.time() < deadline:
            resp = self.query(task_id)
            url = extract_result_url(resp)
            if url:
                return url
            # 记录一次状态，便于失败时说明「卡在哪一步」
            status = _dig(resp, ("data", "status")) or _dig(resp, ("data", "task_status"))
            if status != last_status:
                last_status = status
            time.sleep(self.poll_interval)
        raise VolcError(
            f"等待任务超时（{self.poll_timeout:.0f} 秒）。最后一次状态：{last_status}。"
            f"任务 id 仍然有效，可以用它单独查询。"
        )

    def beautify(self, image_bytes: bytes, preset: VolcPreset, intensity: int,
                 template_id: str = TEMPLATE_BEAUTY_V2) -> bytes:
        """完整链路：提交 → 轮询 → 下载。返回结果图片字节。"""
        task_id = self.submit(image_bytes, build_extra(preset, intensity), template_id=template_id)
        url = self.wait(task_id)
        return download(url, timeout=self.timeout)


# ---------------------------------------------------------------------------
# 响应解析（纯函数，可单测）
# ---------------------------------------------------------------------------

def extract_result_url(resp: dict[str, Any]) -> str | None:
    """从查询响应里找结果图片 URL。

    文档只说「取 result_url」，没给完整路径，所以这里按几个最可能的位置回退查找。
    命中任一即可；全都没有就返回 None（调用方会继续轮询）。
    """
    candidates = (
        ("data", "result_url"),
        ("data", "result", "url"),
        ("data", "result_urls"),
        ("data", "output", "url"),
        ("data", "video_url"),      # 兜底：同一个 OpenAPI 也用于视频
        ("result_url",),
    )
    for path in candidates:
        value = _dig(resp, path)
        if isinstance(value, str) and value.startswith("http"):
            return value
        # 有的接口返回数组
        if isinstance(value, list) and value and isinstance(value[0], str) and value[0].startswith("http"):
            return value[0]
    return None


def _dig(obj: Any, path: tuple[str, ...]) -> Any:
    cur = obj
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur


def _redact(text: str) -> str:
    """把 base64 图片截断 —— 日志里不该出现几 MB 的 base64。"""
    if "base64," not in text:
        return text
    head, _, tail = text.partition("base64,")
    return head + "base64,<" + str(len(tail)) + " chars 已省略>"


def download(url: str, timeout: float = 60.0) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "lumi-volc-beauty/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except Exception as exc:  # noqa: BLE001
        raise VolcError(f"下载结果图片失败：{type(exc).__name__}: {exc}") from exc


# ---------------------------------------------------------------------------
# 自检（不需要 API Key）
# ---------------------------------------------------------------------------

def selftest() -> int:
    """不联网地验证：参数映射、强度缩放、响应解析、图片截断。

    这些是「错了会安静地给出错误结果」的地方，必须有断言守着。
    """
    failures: list[str] = []

    def check(name: str, cond: bool, extra: str = "") -> None:
        if cond:
            print(f"  ✓ {name}")
        else:
            failures.append(name)
            print(f"  ✗ {name}  {extra}")

    print("=== 1. extra 结构 ===")
    p = PRESETS["volc.natural"]
    e100 = build_extra(p, 100)
    check("含 beautyToolConfigKey 且值正确",
          e100.get("beautyToolConfigKey") == BEAUTY_TOOL_CONFIG_KEY_CUSTOM, str(e100.get("beautyToolConfigKey")))
    check("参数分组嵌在 extra.default 之下（官方要求，必传）",
          isinstance(e100.get("default"), dict), str(list(e100)))
    d100 = e100["default"]
    check("强度 100 时保持基准值",
          d100.get("beauty", {}).get("unify_skin_color") == 55, str(e100))
    check("分组存在", "beauty" in d100 and "reshape" in d100, str(list(d100)))
    check("所有值都是整数",
          all(isinstance(v, int) for g in d100.values() for v in g.values()))
    check("分组之外没有散落的参数（嵌套层级不能搞错）",
          all(not (isinstance(v, dict)) for k, v in e100.items() if k != "default"), str(list(e100)))

    print("\n=== 2. 强度缩放 ===")
    e0 = build_extra(p, 0)
    e50 = build_extra(p, 50)
    check("强度 0 → 全部归零", all(v == 0 for g in e0["default"].values() for v in g.values()), str(e0))
    check("强度 50 → 约为基准一半",
          e50["default"]["beauty"]["unify_skin_color"] == 28, str(e50["default"]["beauty"]["unify_skin_color"]))
    check("强度超界被夹住（150 → 等同 100）", build_extra(p, 150) == e100)
    check("强度负值被夹住（-20 → 等同 0）", build_extra(p, -20) == e0)

    print("\n=== 3. 每条预设都能构造出合法 extra ===")
    for pid, preset in PRESETS.items():
        extra = build_extra(preset, 60)
        ok = (extra.get("beautyToolConfigKey") == BEAUTY_TOOL_CONFIG_KEY_CUSTOM
              and isinstance(extra.get("default"), dict)
              and extra["default"])
        check(f"{pid} 有分组（嵌在 default 下）", ok, str(extra))

    print("\n=== 4. 结果 URL 解析（多路径回退）===")
    cases = [
        ({"code": 0, "data": {"result_url": "https://a/x.jpg"}}, "https://a/x.jpg"),
        ({"data": {"result": {"url": "https://a/y.jpg"}}}, "https://a/y.jpg"),
        ({"data": {"result_urls": ["https://a/z.jpg"]}}, "https://a/z.jpg"),
        ({"data": {}}, None),
        ({"data": {"result_url": ""}}, None),
        ({"data": {"result_url": "ftp://nope"}}, None),
    ]
    for resp, expect in cases:
        got = extract_result_url(resp)
        check(f"{json.dumps(resp, ensure_ascii=False)[:52]} → {expect}", got == expect, f"实际 {got}")

    print("\n=== 5. 日志脱敏 ===")
    long_b64 = "data:image/jpeg;base64," + "A" * 5_000_000
    out = _redact(long_b64)
    check("base64 被截断", len(out) < 200, f"长度 {len(out)}")
    check("保留了长度信息", "5000000 chars" in out, out[:80])

    print("\n=== 6. 错误对象 ===")
    err = VolcError("测试", code=40001, http_status=400)
    check("code 与 http 都带上", "40001" in str(err) and "400" in str(err), str(err))

    print()
    if failures:
        print(f"✗ {len(failures)} 项未通过：")
        for f in failures:
            print(f"    {f}")
        return 1
    print(f"✓ 全部通过（{len(PRESETS)} 条预设）")
    return 0


# ---------------------------------------------------------------------------
# 命令行
# ---------------------------------------------------------------------------

def cmd_presets() -> int:
    print(f"火山引擎美颜 · 预设映射（模板 {TEMPLATE_BEAUTY_V2}）")
    print(f"Host: {HOST}")
    print()
    for pid, preset in PRESETS.items():
        print(f"[{pid}] {preset.title}")
        print(f"  {preset.detail}")
        print(f"  对应火山参数：")
        for note in preset.notes:
            print(f"    · {note}")
        print(f"  强度 100 时的 extra：")
        print("    " + json.dumps(build_extra(preset, 100), ensure_ascii=False))
        print()
    return 0


def cmd_probe(image: str, preset_id: str, intensity: int, api_key: str) -> int:
    """真实发一次请求，把原始收发都打出来 —— 校准用。"""
    preset = PRESETS.get(preset_id)
    if preset is None:
        print(f"✗ 未知预设 {preset_id}。可用：{', '.join(PRESETS)}", file=sys.stderr)
        return 2
    data = open(image, "rb").read()
    print(f"图片：{image}  {len(data):,} bytes")
    print(f"预设：{preset_id}（强度 {intensity}）")
    print(f"extra：{json.dumps(build_extra(preset, intensity), ensure_ascii=False)}")
    print()
    print("—— 下面会把原始请求体与原始响应都打出来（base64 已截断）——")
    print()
    client = VolcBeautyClient(api_key=api_key, debug=True)
    try:
        task_id = client.submit(data, build_extra(preset, intensity))
    except VolcError as exc:
        print(f"\n✗ 提交失败：{exc}", file=sys.stderr)
        print("\n排查提示：", file=sys.stderr)
        print("  · 401/403 → API Key 不对，或没开通美颜 API 权限（需要先买「创点」）", file=sys.stderr)
        print("  · 参数类错误 → 把上面的原始响应发我，我调 build_extra() 的分组层级", file=sys.stderr)
        return 1
    print(f"\n✓ 提交成功，task_id = {task_id}")
    try:
        url = client.wait(task_id)
    except VolcError as exc:
        print(f"\n✗ 查询失败：{exc}", file=sys.stderr)
        return 1
    print(f"✓ 出图：{url}")
    print("\n如果上面每一步都对上了，说明契约与实现一致，可以正式用了。")
    return 0


def cmd_run(image: str, preset_id: str, intensity: int, out: str, api_key: str) -> int:
    preset = PRESETS.get(preset_id)
    if preset is None:
        print(f"✗ 未知预设 {preset_id}。可用：{', '.join(PRESETS)}", file=sys.stderr)
        return 2
    data = open(image, "rb").read()
    client = VolcBeautyClient(api_key=api_key)
    try:
        result = client.beautify(data, preset, intensity)
    except VolcError as exc:
        print(f"✗ 失败：{exc}", file=sys.stderr)
        return 1
    if out is None:
        out = os.path.splitext(image)[0] + f".{preset_id.replace('.', '-')}.jpg"
    open(out, "wb").write(result)
    print(f"✓ 已写出 {out}  {len(result):,} bytes（原图 {len(data):,} bytes）")
    return 0


def cmd_serve(port: int, host: str, api_key: str, token: str) -> int:
    """给 App 用的 HTTP 服务。

    契约与 `tools/lumi_retouch_server.py` **完全一致**，所以 App 侧不用改：
      GET  /health           → 状态
      GET  /presets          → 预设列表
      POST /retouch          → 表单：image（文件）+ preset + intensity + prompt?
                                返回：图片二进制

    这样 App 里只需把「中继地址」填成这个服务的地址即可。
    """
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    # 刻意不用标准库的 `cgi`：它在 Python 3.13 已被移除，
    # 而云函数运行时未必停在旧版本。下面用 `_parse_multipart()` 自己解析。

    class Handler(BaseHTTPRequestHandler):
        server_version = "lumi-volc-beauty"

        def _json(self, code: int, obj: dict) -> None:
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _authorized(self) -> bool:
            if not token:
                return True
            return self.headers.get("Authorization", "") == f"Bearer {token}"

        def do_GET(self) -> None:  # noqa: N802
            if not self._authorized():
                self._json(401, {"error": "unauthorized"})
                return
            if self.path.startswith("/health"):
                self._json(200, {
                    "ok": True,
                    "provider": "volcengine-beauty",
                    "template_id": TEMPLATE_BEAUTY_V2,
                    "has_api_key": bool(api_key),
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
            # 复用标准库解析 multipart（与本地中继同一形态）
            content_type = self.headers.get("Content-Type", "")
            if "multipart/form-data" not in content_type:
                self._json(400, {"error": "需要 multipart/form-data"})
                return
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            fields, files = _parse_multipart(content_type, raw)
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
                result = VolcBeautyClient(api_key=api_key).beautify(image, preset, intensity)
            except VolcError as exc:
                self._json(502, {"error": str(exc), "code": exc.code, "http_status": exc.http_status})
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(result)))
            self.end_headers()
            self.wfile.write(result)

        def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
            sys.stderr.write("[volc-beauty] " + fmt % args + "\n")

    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"火山美颜转发已启动：http://{host}:{port}")
    print(f"  健康检查  GET  /health")
    print(f"  精修      POST /retouch（字段 image / preset / intensity）")
    print(f"  API Key   {'已配置' if api_key else '**未配置** —— 调用会返回 502'}")
    print(f"  访问口令  {'已启用' if token else '未启用（任何人都能调你的额度，建议设一个）'}")
    print()
    print("把 App 里「设置 → 云端精修 → 中继地址」填成这台机器的地址即可。")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    return 0


def _parse_multipart(content_type: str, body: bytes) -> tuple[dict[str, str], dict[str, bytes]]:
    """极简 multipart 解析。

    刻意不依赖第三方库：云函数运行时通常只有标准库。
    只需要支持本项目实际会发的形态：普通字段 + 一个图片文件字段。
    """
    import re

    m = re.search(r"boundary=([^;]+)", content_type)
    if not m:
        return {}, {}
    boundary = m.group(1).strip().strip('"').encode()
    fields: dict[str, str] = {}
    files: dict[str, bytes] = {}

    for part in body.split(b"--" + boundary):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        head, _, payload = part.partition(b"\r\n\r\n")
        if not _:
            continue
        header_text = head.decode("utf-8", errors="replace")
        name_m = re.search(r'name="([^"]*)"', header_text)
        if not name_m:
            continue
        name = name_m.group(1)
        payload = payload.rstrip(b"\r\n")
        if "filename=" in header_text:
            files[name] = payload
        else:
            fields[name] = payload.decode("utf-8", errors="replace")
    return fields, files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="火山引擎「AI 美颜」云端精修适配层",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--presets", action="store_true", help="列出预设与参数映射")
    parser.add_argument("--selftest", action="store_true", help="不联网自检（不需要 API Key）")
    parser.add_argument("--probe", action="store_true", help="真实调用一次，打印原始收发（校准用）")
    parser.add_argument("--image", help="输入图片路径")
    parser.add_argument("--out", help="输出图片路径")
    parser.add_argument("--preset", default="volc.natural", help=f"预设 id（默认 volc.natural）")
    parser.add_argument("--intensity", type=int, default=60, help="强度 0-100（默认 60）")
    parser.add_argument("--serve", action="store_true", help="作为 HTTP 服务运行（给 App 用）")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8091)
    parser.add_argument("--token", default=os.environ.get("RETOUCH_TOKEN", ""),
                        help="可选访问口令；设置后 App 需要带 Authorization: Bearer")
    args = parser.parse_args(argv)

    api_key = os.environ.get(ENV_API_KEY, "").strip()

    if args.selftest:
        return selftest()
    if args.presets:
        return cmd_presets()
    if args.serve:
        return cmd_serve(args.port, args.host, api_key, args.token)

    if not api_key:
        print(f"✗ 没有 API Key。请先设置环境变量：", file=sys.stderr)
        print(f"    export {ENV_API_KEY}=你的key", file=sys.stderr)
        print("  （火山控制台 → 创作 Agent(Kickart) → API Key → +New）", file=sys.stderr)
        return 2
    if not args.image:
        parser.error("需要 --image")
        return 2

    if args.probe:
        return cmd_probe(args.image, args.preset, args.intensity, api_key)
    return cmd_run(args.image, args.preset, args.intensity, args.out, api_key)


if __name__ == "__main__":
    raise SystemExit(main())
