#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按打包 scheme 修正 stage 目录里 launchd plist 的可执行文件路径。

背景：`layout/` 是三种 scheme 共用的一份静态文件，但 launchd 的
`ProgramArguments` 必须是**绝对路径**。rootless 把包内容装到 `/var/jb/` 下，
plist 自己也落在 `/var/jb/Library/LaunchDaemons/`，若里面仍写
`/usr/lib/xautouch/bin/xautouchd`，launchd 在真实根文件系统上找不到该文件，
守护进程直接起不来（装完 8080 面板必然打不开）。

用法：
    python3 tools/fix_stage_plist.py <scheme> [stage_dir]

scheme: rootful / rootless / roothide；stage_dir 默认 `.theos/_`。
"""

import os
import plistlib
import sys

PLIST_NAME = "app.xautouch.agent.plist"
BIN_REL = "usr/lib/xautouch/bin/xautouchd"

# 各 scheme 下守护进程的真实绝对路径。
# rootful: 根文件系统就是 /
# rootless: 可写区在 /var/jb，Theos 会把 payload 一并前移
# roothide: payload 装到真实 / 由 jbroot 重定向，路径保持 / 前缀
PREFIX = {
    "rootful": "",
    "rootless": "/var/jb",
    "roothide": "",
}


def main():
    scheme = sys.argv[1] if len(sys.argv) > 1 else "rootful"
    stage = sys.argv[2] if len(sys.argv) > 2 else ".theos/_"

    if scheme not in PREFIX:
        print(f"fix_stage_plist: 未知 scheme {scheme!r}", file=sys.stderr)
        return 2
    if not os.path.isdir(stage):
        print(f"fix_stage_plist: stage 目录不存在 {stage}", file=sys.stderr)
        return 2

    want = PREFIX[scheme] + "/" + BIN_REL
    found = 0
    fixed = 0

    for dirpath, _dirnames, filenames in os.walk(stage):
        if PLIST_NAME not in filenames:
            continue
        found += 1
        path = os.path.join(dirpath, PLIST_NAME)
        with open(path, "rb") as fh:
            data = plistlib.load(fh)

        args = data.get("ProgramArguments") or []
        before = args[0] if args else None
        if before == want:
            print(f"fix_stage_plist: {os.path.relpath(path, stage)} 已是 {want}")
            continue

        args = [want] + args[1:]
        data["ProgramArguments"] = args
        # 二进制 plist：launchd 与 Sileo 都支持，且不会被文本 sed 误伤
        with open(path, "wb") as fh:
            plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
        fixed += 1
        print(f"fix_stage_plist: {os.path.relpath(path, stage)}  {before} -> {want}")

    if found == 0:
        print(f"fix_stage_plist: 在 {stage} 里没找到 {PLIST_NAME}", file=sys.stderr)
        return 1

    print(f"fix_stage_plist: scheme={scheme} 命中 {found} 个，改写 {fixed} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
