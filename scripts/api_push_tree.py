#!/usr/bin/env python3
"""用 GitHub **Git Data API** 造「一个」提交（而不是每个文件一笔）。

用法：
    GH_TOKEN=<token> python3 scripts/api_push_tree.py -m "提交说明" <file1> [file2 ...]

为什么需要它
------------
`git push` 走 `github.com:443`，这个环境里常被整体拦掉。``scripts/api_commit.py``
是替代通道，但它用的是 `PUT /contents`，**一个文件一笔提交**：

- 18 个文件 → 18 笔提交 → 触发 18 次 CI（并发组虽然会取消旧的，但白跑）；
- 历史里塞进十几笔「文档更新: xxx」，把本来已经对齐的历史弄乱。

Git Data API 允许直接组装 git 对象，所以这里一次提交带上任意多个文件：

    blobs  →  tree(base_tree = 远端当前树)  →  commit(parents = [远端 main])  →  更新 ref

文件内容取自 `git HEAD`（不是工作区），这样推上去的是 LF 版本，与仓库一致。
"""

from __future__ import annotations

import base64
import subprocess
import sys

from api_commit import ApiError, gh_api, git_show  # 同目录，复用已验证的传输层


def git_mode(path: str) -> str:
    """从索引里取文件模式（100644 / 100755），不猜。"""
    out = subprocess.run(
        ["git", "ls-files", "-s", "--", path], capture_output=True, check=True
    ).stdout.decode("utf-8")
    if not out.strip():
        raise ApiError(f"{path} 不在 git 索引里（忘了 git add？）")
    return out.split()[0]


def main() -> int:
    argv = sys.argv[1:]
    message = None
    if argv and argv[0] in ("-m", "--message"):
        if len(argv) < 2:
            print("缺少提交说明", file=sys.stderr)
            return 2
        message = argv[1]
        argv = argv[2:]

    if not argv or not message:
        print(__doc__, file=sys.stderr)
        return 2

    files = argv

    # 1) 远端 main 的 head 与 tree —— 作为新 tree 的 base 和新提交的父提交
    head = gh_api("GET", "commits/main")
    head_sha = head["sha"]
    base_tree_sha = head["commit"]["tree"]["sha"]
    print(f"远端 main = {head_sha[:12]}   tree = {base_tree_sha[:12]}")

    # 2) 每个文件建一个 blob（内容来自 git HEAD，保证是 LF 版本）
    entries = []
    for path in files:
        data = git_show(path)
        mode = git_mode(path)
        blob = gh_api(
            "POST",
            "git/blobs",
            {"content": base64.b64encode(data).decode("ascii"), "encoding": "base64"},
        )
        entries.append({"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]})
        print(f"  blob {blob['sha'][:12]}  {len(data):>9,} bytes  {mode}  {path}")

    # 3) 建 tree：base_tree 让未列出的文件保持原样（不需要先拉全量树）
    tree = gh_api("POST", "git/trees", {"base_tree": base_tree_sha, "tree": entries})
    print(f"tree   = {tree['sha'][:12]}")

    # 4) 建 commit
    commit = gh_api(
        "POST",
        "git/commits",
        {"message": message, "tree": tree["sha"], "parents": [head_sha]},
    )
    print(f"commit = {commit['sha'][:12]}")

    # 5) 更新 ref。父提交就是刚读到的 head，因此这是一次快进推进，
    #    不需要 force，也不会覆盖并发推上来的提交（真发生冲突时非快进会报错）。
    gh_api("PATCH", "git/refs/heads/main", {"sha": commit["sha"], "force": False})
    print("✓ refs/heads/main 已更新")

    # 6) 复核：远端 head 必须正好是我们刚建的提交
    check = gh_api("GET", "commits/main")
    if check["sha"] != commit["sha"]:
        raise ApiError(f"复核失败：远端 head 是 {check['sha'][:12]}，期望 {commit['sha'][:12]}")
    print("✓ 复核通过：远端 head 与新提交一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
