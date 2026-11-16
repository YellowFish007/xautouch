#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Theos 产出的 deb 的 data.tar.lzma 重压为 data.tar.xz。

为什么需要这一步：Theos 默认用 lzma（lzma-alone 格式）压缩 data 段，而 iOS 侧
Sileo/apt 的 libapt-pkg 对 lzma-alone 的支持取决于编译选项，实测在 Dopamine
rootless 上装本地 deb 会报

    E: Unsupported file /var/jb/var/cache/apt/archives/xxx.deb given on commandline

xz 是 dpkg/apt 全平台无条件的支持项，压缩率也不比 lzma 差，所以统一转 xz。
只替换压缩算法，tar 原始字节不动 —— 文件列表、权限、mtime 全部保持原样。

用法：
    python3 tools/repackage_deb.py dist/*.deb     # 原地替换
"""

import io
import lzma
import os
import sys

AR_MAGIC = b"!<arch>\n"
COMPRESSED = ("lzma", "xz", "gz", "bz2", "zst")


def read_ar(raw):
    """返回 [(name, mtime, mode, data)]，按出现顺序。"""
    if raw[:8] != AR_MAGIC:
        raise ValueError("不是 ar 归档")
    members, i = [], 8
    while i < len(raw):
        hdr = raw[i:i + 60]
        if len(hdr) < 60:
            break
        name = hdr[0:16].decode("ascii").strip().rstrip("/")
        mtime = hdr[16:28].decode("ascii").strip()
        mode = hdr[40:48].decode("ascii").strip()
        size = int(hdr[48:58].decode("ascii").strip())
        members.append((name, mtime, mode, raw[i + 60:i + 60 + size]))
        i += 60 + size + (size % 2)
    return members


def write_ar(members):
    out = io.BytesIO()
    out.write(AR_MAGIC)
    for name, mtime, mode, data in members:
        head = (
            name.ljust(16)
            + mtime.ljust(12)
            + "0".ljust(6)          # uid
            + "0".ljust(6)          # gid
            + mode.ljust(8)
            + str(len(data)).ljust(10)
            + "`\n"
        ).encode("ascii")
        out.write(head)
        out.write(data)
        if len(data) % 2:
            out.write(b"\n")
    return out.getvalue()


def decompress(name, blob):
    if name.endswith(".lzma"):
        return lzma.decompress(blob, format=lzma.FORMAT_ALONE)
    if name.endswith(".xz"):
        return lzma.decompress(blob, format=lzma.FORMAT_XZ)
    if name.endswith(".gz"):
        import gzip
        return gzip.decompress(blob)
    if name.endswith(".bz2"):
        import bz2
        return bz2.decompress(blob)
    if name.endswith(".zst"):
        import zstandard  # 可能没装，交给调用方兜底
        return zstandard.ZstdDecompressor().decompress(blob)
    return blob


def repackage(path, preset=6):
    raw = open(path, "rb").read()
    members = read_ar(raw)

    names = [m[0] for m in members]
    if "debian-binary" not in names:
        raise ValueError("缺 debian-binary，不是 deb")
    data_idx = [i for i, n in enumerate(names) if n.startswith("data.tar")]
    if not data_idx:
        raise ValueError("缺 data.tar")
    di = data_idx[0]
    old_name, mtime, mode, blob = members[di]

    if old_name == "data.tar.xz":
        print(f"{os.path.basename(path)}: 已是 xz，跳过")
        return False

    tar_bytes = decompress(old_name, blob)
    new_blob = lzma.compress(tar_bytes, format=lzma.FORMAT_XZ, preset=preset)
    members[di] = ("data.tar.xz", mtime, mode or "100644", new_blob)

    out = write_ar(members)
    with open(path, "wb") as fh:
        fh.write(out)
    print(
        f"{os.path.basename(path)}: {old_name} {len(blob)} B -> data.tar.xz {len(new_blob)} B"
        f"  (tar {len(tar_bytes)} B, 整体 {len(raw)} -> {len(out)} B)"
    )
    return True


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    rc = 0
    for p in argv:
        if not os.path.isfile(p):
            print(f"跳过不存在的文件: {p}", file=sys.stderr)
            rc = 1
            continue
        try:
            repackage(p)
        except Exception as exc:  # noqa: BLE001 - 逐个文件报错，不中断其它包
            print(f"{p}: 失败 {exc}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
