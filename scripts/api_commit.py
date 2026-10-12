#!/usr/bin/env python3
"""通过 GitHub API 提交文件（`git push` 走不通时的替代通道）。

用法：
    GH_TOKEN=<token> python3 scripts/api_commit.py <file1> [file2 ...]

为什么需要这个脚本
------------------
`git push` 走的是 `github.com:443`，这个环境里经常被整体拦掉（`CONNECT tunnel
failed, response 502`）。`api.github.com` 通常还活着，所以改走 REST API 提交。

为什么用 `gh api` 而不是 Python 的 urllib
------------------------------------------
实测过两种传输，差异很有意思：

- **`gh api`（Go 网络栈）**：稳定，`gh api user` 一直能通；
- **Python `urllib`（走同一个代理的 CONNECT 隧道）**：间歇性 502，重试 5 次也
  可能全失败。

所以主通道用 `gh api --input -`。用 `--input -` 从 stdin 读 JSON 体，还能顺手
绕开「内容太长导致 `Argument list too long`」的问题（`gh api -f content=...`
会在这一步失败）。

文件内容取自 `git HEAD`（而不是工作区），这样推上去的版本 LF 行尾与仓库一致，
不受本地 CRLF 影响。
"""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import time

REPO = "18156940942/LUMI-AI-Camera"
RETRYABLE_STATUS = {429, 500, 502, 503, 504}
_STATUS_RE = re.compile(r"HTTP (\d{3})")


class ApiError(RuntimeError):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def git_show(path: str) -> bytes:
    """取 `git HEAD` 里的文件内容（不是工作区版本）。"""
    result = subprocess.run(
        ["git", "show", f"HEAD:{path}"], capture_output=True, check=True
    )
    return result.stdout


def gh_api(method: str, path: str, body: dict | None = None, attempts: int = 5) -> dict:
    """调 GitHub REST API，返回解析后的 JSON。

    只对**网络类**错误重试（超时、连接中断、5xx、429）。确定性错误（404/401/403、
    JSON 解析失败、URL 编码失败）重试多少次结果都一样，直接抛出去。
    """
    token = os.environ.get("GH_TOKEN")
    if not token:
        raise ApiError("缺少 GH_TOKEN 环境变量")

    env = {**os.environ, "GH_TOKEN": token, "GH_HOST": "github.com"}
    # 端点不要写前导斜杠：在 Git Bash 下，原生程序收到的 `/repos/...` 会被 MSYS
    # 当成 POSIX 路径改写成 `D:/…/repos/...`（gh 会报 "invalid API endpoint"）。
    # 从 Python 的 subprocess 直接调用不会有这个问题，但省略斜杠对两者都安全。
    args = ["gh", "api", "--method", method, f"repos/{REPO}/{path}"]
    payload = None
    if body is not None:
        args += ["--input", "-"]
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")

    last: ApiError | None = None
    for i in range(attempts):
        proc = subprocess.run(args, input=payload, capture_output=True, env=env)
        if proc.returncode == 0:
            return json.loads(proc.stdout.decode("utf-8"))

        err = proc.stderr.decode("utf-8", "replace").strip()
        m = _STATUS_RE.search(err)
        status = int(m.group(1)) if m else None

        # 404 = 文件在远端还不存在（新文件），调用方会处理，不要重试
        if status == 404:
            raise ApiError(err, 404)

        retryable = status is None or status in RETRYABLE_STATUS
        if retryable and i < attempts - 1:
            last = ApiError(err, status)
            label = f"HTTP {status}" if status else "连接失败"
            print(f"  … {label}，重试 {i + 1}/{attempts}", file=sys.stderr)
            time.sleep(2 ** i)
            continue

        raise ApiError(err, status)

    assert last is not None
    raise last


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    files = sys.argv[1:]
    failed: list[str] = []

    for path in files:
        print(f"=== {path} ===")
        try:
            # 1. 取远程当前 blob sha（新文件时远端 404，此时不需要 sha）
            blob_sha = None
            try:
                info = gh_api("GET", f"contents/{path}")
                blob_sha = info["sha"]
                print(f"  远程 blob sha: {blob_sha[:12]}…")
            except ApiError as e:
                if e.status != 404:
                    raise
                print("  远端不存在 → 按新文件提交")

            # 2. 本地 HEAD 版本 → base64
            content = base64.b64encode(git_show(path)).decode()

            # 3. PUT（有 sha 才是更新，没有就是新增）
            body: dict = {"message": f"文档更新: {path}", "content": content}
            if blob_sha:
                body["sha"] = blob_sha

            result = gh_api("PUT", f"contents/{path}", body)
            print(f"  ✓ 提交 {result['commit']['sha'][:12]}")
        except subprocess.CalledProcessError as e:
            print(f"  ✗ git 读不到 HEAD:{path}（是否忘了 commit？）", file=sys.stderr)
            failed.append(path)
        except ApiError as e:
            print(f"  ✗ {e}", file=sys.stderr)
            failed.append(path)

    if failed:
        print(f"\n{len(failed)} 个文件未提交：{', '.join(failed)}", file=sys.stderr)
        return 1

    print(f"\n全部 {len(files)} 个文件已通过 API 提交。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
