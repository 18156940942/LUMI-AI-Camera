#!/usr/bin/env python3
"""通过 GitHub API 提交文件（github.com 主站被阻断时的 git push 替代方案）。

用法：
    python3 scripts/api_commit.py <token> <file1> [file2 ...]

每个文件一次 PUT（各生成一笔提交）。文件内容取自 git HEAD 里的版本
（保证 LF 行尾与仓库一致），base64 后放进 JSON 请求体，绕开命令行长度限制。
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import urllib.error
import urllib.request


def git_show(path: str) -> bytes:
    result = subprocess.run(
        ["git", "show", f"HEAD:{path}"], capture_output=True, check=True
    )
    return result.stdout


def api(method: str, url: str, token: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "lumi-api-commit",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read())


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    token = sys.argv[1]
    files = sys.argv[2:]
    repo = "18156940942/LUMI-AI-Camera"

    for path in files:
        print(f"=== {path} ===")
        try:
            # 1. 取远程当前 blob sha
            info = api("GET", f"https://api.github.com/repos/{repo}/contents/{path}", token)
            blob_sha = info["sha"]
            print(f"  远程 blob sha: {blob_sha[:12]}…")

            # 2. 本地 HEAD 版本 → base64
            content = base64.b64encode(git_show(path)).decode()

            # 3. PUT
            result = api(
                "PUT",
                f"https://api.github.com/repos/{repo}/contents/{path}",
                token,
                {
                    "message": f"修复: {path}",
                    "content": content,
                    "sha": blob_sha,
                },
            )
            print(f"  ✓ 提交 {result['commit']['sha'][:12]}")
        except urllib.error.HTTPError as e:
            print(f"  ✗ HTTP {e.code}: {e.read().decode()[:300]}", file=sys.stderr)
            return 1
        except Exception as e:  # noqa: BLE001
            print(f"  ✗ {e}", file=sys.stderr)
            return 1

    print("\n全部文件已通过 API 提交。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
