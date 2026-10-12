#!/usr/bin/env python3
"""通过 GitHub API 把远端对象取到本地（`git fetch` 走不通时的替代方案）。

用法：
    GH_TOKEN=<token> python3 scripts/api_fetch.py [branch]

为什么需要它
------------
`git fetch` 走 `github.com:443`，这个环境里经常被整体拦掉
（`CONNECT tunnel failed, response 502`）。而 `api.github.com` 通常还活着。

好在 git 的对象是**内容寻址**的：只要按内容把对象一个个写进本地库，得到的
SHA 必然与远端一致。于是「拉取」可以拆成三步：

1. 递归拉远端 tree / blob → `git hash-object -w` / `git mktree` 写入本地；
2. 拉远端提交元数据 → `git commit-tree` 重建提交对象；
3. 每一步都比对 SHA，全部对上才算成功。

重建提交时踩到的两个坑（实测得出，不是猜的）
--------------------------------------------
**坑 1：API 的 `commit.author.date` 里的 `Z` 是假的。**

    API 报        2026-10-12T02:59:42Z
    真实对象里是  1791773982 +0800      ← 墙钟时间就是 02:59:42，但时区是 +0800

也就是说 GitHub 返回的是提交**存储的墙钟时间**，却统一打了 `Z` 后缀。所以
`date` 字符串里的日期时间部分可以直接用（按 UTC 解释即得 epoch），**但偏移量
信息丢失了** —— 必须反查。实测这几个提交是 +0800。

**坑 2：API 建的提交，消息末尾没有换行。**

本地 `git commit` 生成的提交，消息末尾总有一个 `\n`；而通过
`PUT /repos/.../contents` 建的提交，消息就是原样字符串，**没有尾换行**。
用 `git commit-tree -F -` 重建时必须两者都试。

所以本脚本不是「猜一个元数据然后祈祷」，而是：**拿目标 SHA 反查**
（先试小候选集，再对偏移量做 15 分钟粒度的全量扫描），命中才写入。
一个都没命中就报错退出，绝不往库里塞无法验证的对象。

写完之后会把 `refs/remotes/origin/<branch>` 指到远端 head。
"""

from __future__ import annotations

import calendar
import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time

REPO = "18156940942/LUMI-AI-Camera"
STATUS_RE = re.compile(r"HTTP (\d{3})")


# --------------------------------------------------------------------------- #
# API：gh api 传输（Go 网络栈，比 urllib 走代理隧道稳）+ 只对网络错误重试
# --------------------------------------------------------------------------- #
def gh_api(path: str, attempts: int = 5) -> object:
    token = os.environ.get("GH_TOKEN")
    if not token:
        raise SystemExit("缺少 GH_TOKEN 环境变量")

    env = {**os.environ, "GH_TOKEN": token, "GH_HOST": "github.com"}
    # 端点不写前导斜杠：Git Bash 的 MSYS 会把 /repos/... 重写成 D:/…/repos/...
    args = ["gh", "api", f"repos/{REPO}/{path}"]
    last = ""

    for i in range(attempts):
        proc = subprocess.run(args, capture_output=True, env=env)
        if proc.returncode == 0:
            return json.loads(proc.stdout.decode("utf-8"))

        err = proc.stderr.decode("utf-8", "replace").strip()
        m = STATUS_RE.search(err)
        status = int(m.group(1)) if m else None
        if status is not None and status not in (429, 500, 502, 503, 504):
            raise SystemExit(f"API 错误（不可重试）：{err}")
        last = err
        if i < attempts - 1:
            print(f"  … 重试 {i + 1}/{attempts}: {err.splitlines()[0][:70]}", file=sys.stderr)
            time.sleep(2 ** i)

    raise SystemExit(f"API 连续失败：{last}")


def git(*args: str, stdin: bytes | None = None, env: dict | None = None) -> str:
    proc = subprocess.run(["git", *args], input=stdin, capture_output=True, env=env)
    if proc.returncode != 0:
        raise SystemExit(
            f"git {' '.join(args)} 失败：{proc.stderr.decode('utf-8', 'replace')[:400]}"
        )
    return proc.stdout.decode("utf-8").strip()


def object_exists(sha: str) -> bool:
    return subprocess.run(["git", "cat-file", "-e", sha], capture_output=True).returncode == 0


# --------------------------------------------------------------------------- #
# tree / blob
# --------------------------------------------------------------------------- #
def write_blob(sha: str, seen: set) -> None:
    if sha in seen or object_exists(sha):
        seen.add(sha)
        return
    info = gh_api(f"git/blobs/{sha}")
    if info["encoding"] != "base64":
        raise SystemExit(f"意外的 blob 编码: {info['encoding']}")
    got = git("hash-object", "-w", "--stdin", stdin=base64.b64decode(info["content"]))
    if got != sha:
        raise SystemExit(f"blob SHA 不匹配！期望 {sha}，本地算出 {got}")
    seen.add(sha)


def write_tree(sha: str, seen: set) -> None:
    if sha in seen or object_exists(sha):
        seen.add(sha)
        return
    info = gh_api(f"git/trees/{sha}")
    lines = []
    for e in info["tree"]:
        mode, typ, esha = e["mode"], e["type"], e["sha"]
        if typ == "tree":
            if mode != "040000":
                raise SystemExit(f"意外的 tree mode: {mode}")
            write_tree(esha, seen)
            lines.append(f"40000 tree {esha}\t{e['path']}")   # mktree 要 40000，不是 040000
        elif typ == "blob":
            write_blob(esha, seen)
            if mode not in ("100644", "100755", "120000"):
                raise SystemExit(f"意外的 blob mode: {mode}")
            lines.append(f"{mode} blob {esha}\t{e['path']}")
        else:
            raise SystemExit(f"意外的 object type: {typ}")

    got = git("mktree", stdin=("\n".join(lines) + "\n").encode("utf-8"))
    if got != sha:
        raise SystemExit(f"tree SHA 不匹配！期望 {sha}，本地算出 {got}")
    seen.add(sha)


# --------------------------------------------------------------------------- #
# commit
# --------------------------------------------------------------------------- #
def wall_epoch(date_str: str) -> int:
    """把 API 的日期字符串当作**墙钟时间**换算成 epoch。

    实测 GitHub 返回的是提交存储的墙钟时间 + 一个假的 `Z` 后缀，所以直接取
    日期时间部分、忽略时区标记、按 UTC 解释，得到的才是提交对象里那个 epoch。
    """
    s = re.sub(r"(?:Z|[+-]\d{2}:?\d{2})$", "", date_str.strip())
    return calendar.timegm(dt.datetime.fromisoformat(s).timetuple())


def local_offset() -> str:
    """本机当前时区偏移，形如 `+0800`（仅用于把候选顺序排得更聪明）。"""
    off = -time.timezone
    sign = "+" if off >= 0 else "-"
    off = abs(off)
    return f"{sign}{off // 3600:02d}{(off % 3600) // 60:02d}"


def _fmt_offset(mins: int) -> str:
    sign = "+" if mins >= 0 else "-"
    a = abs(mins)
    return f"{sign}{a // 60:02d}{a % 60:02d}"


def _try(tree: str, parents: list, name: str, email: str, epoch: int,
         a_off: str, c_off: str, msg: bytes) -> str:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
        "GIT_AUTHOR_DATE": f"{epoch} {a_off}",
        "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email,
        "GIT_COMMITTER_DATE": f"{epoch} {c_off}",
    }
    args = ["git", "commit-tree", tree]
    for p in parents:
        args += ["-p", p]
    proc = subprocess.run(args + ["-F", "-"], input=msg, capture_output=True, env=env)
    if proc.returncode != 0:
        raise SystemExit(f"commit-tree 失败：{proc.stderr.decode('utf-8', 'replace')[:300]}")
    return proc.stdout.decode("utf-8").strip()


def build_commit(meta: dict, seen: set) -> str:
    target = meta["sha"]
    if object_exists(target):
        return target

    write_tree(meta["commit"]["tree"]["sha"], seen)

    c = meta["commit"]
    tree = c["tree"]["sha"]
    parents = [p["sha"] for p in meta.get("parents", [])]
    name, email = c["author"]["name"], c["author"]["email"]
    a_epoch, c_epoch = wall_epoch(c["author"]["date"]), wall_epoch(c["committer"]["date"])
    msg = c["message"].encode("utf-8")

    # 消息尾换行的两种可能（API 建的提交没有尾换行，本地 git commit 有）
    msg_variants = [msg, msg + b"\n"]

    # 候选偏移：本机时区优先，然后 UTC
    cand = list(dict.fromkeys([local_offset(), "+0000"]))

    # ① 小候选集组合
    for a_off in cand:
        for c_off in cand:
            for m in msg_variants:
                if _try(tree, parents, name, email, a_epoch, a_off, c_off, m) == target:
                    return target

    # ② 全量扫描：author / committer 用同一偏移（实测的情况）
    for mins in range(-12 * 60, 14 * 60 + 1, 15):
        off = _fmt_offset(mins)
        for m in msg_variants:
            if _try(tree, parents, name, email, a_epoch, off, off, m) == target:
                return target

    raise SystemExit(
        f"无法重建提交 {target}（{c['message'].splitlines()[0]}）\n"
        f"  tree={tree}  parents={parents}\n"
        f"  author={name} <{email}> {c['author']['date']}\n"
        f"  候选偏移与消息尾换行都试过了，仍对不上 SHA。不为本地库写入无法验证的对象。"
    )


def main() -> int:
    branch = sys.argv[1] if len(sys.argv) > 1 else "main"

    remote_head = gh_api(f"commits/{branch}")["sha"]
    print(f"远端 {branch} = {remote_head}")

    commits = gh_api(f"commits?per_page=100&sha={branch}")
    commits = list(reversed(commits))          # 从最老的开始：父对象必须先存在

    seen: set = set()
    created = 0
    for meta in commits:
        existed = object_exists(meta["sha"])
        got = build_commit(meta, seen)
        if not existed:
            created += 1
            print(f"  ✓ 新建 {got[:8]}  {meta['commit']['message'].splitlines()[0][:52]}")

    print(f"\n新建提交 {created} 笔，全部 SHA 校验通过。")
    git("update-ref", f"refs/remotes/origin/{branch}", remote_head)
    print(f"refs/remotes/origin/{branch} → {remote_head[:12]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
