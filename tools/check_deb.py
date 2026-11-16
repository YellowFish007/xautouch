#!/usr/bin/env python3
"""check_deb.py —— 纯 Python 的 deb 结构校验器（不依赖 dpkg-deb，macOS/Windows 都能跑）。

为什么不用 dpkg-deb 校验：GitHub 的 macos runner 镜像并非总带 dpkg，
一旦缺失整条流水线会以 "dpkg-deb: command not found" 假失败告终。
这里直接解析 ar 容器 + control.tar.* / data.tar.*，判断逻辑不依赖平台工具。

校验项：
  1. ar 容器含 debian-binary / control.tar.* / data.tar.*
  2. control 必需字段齐全，Version 与 Architecture 合法
  3. preinst / postinst / prerm / postrm 存在且带可执行位
  4. payload 必备路径齐全（tweak dylib + plist、XXTExplorer、launchd、资源目录）
  5. rootless 包必须带 var/jb 前缀，rootful / roothide 不能带
  6. 打印文件数、各顶层目录统计

用法：
  python3 tools/check_deb.py dist/*.deb
  python3 tools/check_deb.py --scheme rootful app.xautouch.ios_1.0.0_iphoneos-arm64.deb
退出码：全部通过 0，任一失败 1
"""
import io
import os
import sys
import tarfile

REQUIRED_CONTROL = ("Package", "Name", "Version", "Architecture", "Description", "Maintainer")
MAINTAINER_SCRIPTS = ("preinst", "postinst", "prerm", "postrm")


def read_ar(path):
    """解析 ar 容器，返回 {成员名: bytes}。deb 的 ar 成员头固定 60 字节。"""
    raw = open(path, "rb").read()
    if raw[:8] != b"!<arch>\n":
        raise ValueError("不是 ar 归档（缺少 !<arch> 魔数）")
    i, out = 8, {}
    while i + 60 <= len(raw):
        hdr = raw[i:i + 60]
        name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode("ascii").strip())
        except ValueError:
            break
        out[name] = raw[i + 60:i + 60 + size]
        i += 60 + size + (size % 2)
    return out


def open_tar(blob):
    """自动识别 gz / xz / lzma / 未压缩。"""
    return tarfile.open(fileobj=io.BytesIO(blob), mode="r:*")


def norm(name):
    while name.startswith("./"):
        name = name[2:]
    return name


def check(path, scheme=None):
    errs, warns = [], []
    mem = read_ar(path)

    if b"2.0" not in mem.get("debian-binary", b""):
        errs.append("debian-binary 缺失或版本非 2.0")

    ctl_key = next((k for k in mem if k.startswith("control.tar")), None)
    dat_key = next((k for k in mem if k.startswith("data.tar")), None)
    if not ctl_key:
        return ["缺少 control.tar.*"], []
    if not dat_key:
        return ["缺少 data.tar.*"], []

    ct = open_tar(mem[ctl_key])
    files = {norm(m.name): m for m in ct.getmembers()}

    if "control" not in files:
        errs.append("control 文件缺失")
        meta = {}
    else:
        text = ct.extractfile(files["control"]).read().decode("utf-8", "replace")
        meta = {}
        for line in text.splitlines():
            if ":" in line and not line.startswith(" "):
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip()
        for k in REQUIRED_CONTROL:
            if not meta.get(k):
                errs.append(f"control 缺字段 {k}")
        if meta.get("Package") != "app.xautouch.ios":
            errs.append(f"Package 异常: {meta.get('Package')}")

    for s in MAINTAINER_SCRIPTS:
        m = files.get(s)
        if not m:
            errs.append(f"维护脚本缺失: {s}")
        elif not (m.mode & 0o111):
            errs.append(f"维护脚本无执行位: {s} mode={oct(m.mode)}")

    dt = open_tar(mem[dat_key])
    payload = {norm(m.name): m for m in dt.getmembers() if m.isfile()}
    names = set(payload)

    arch = meta.get("Architecture", "")
    if scheme == "roothide":
        if arch != "iphoneos-arm64e":
            errs.append(f"roothide 期望 iphoneos-arm64e，实为 {arch}")
    elif scheme in ("rootful", "rootless"):
        if arch != "iphoneos-arm64":
            errs.append(f"{scheme} 期望 iphoneos-arm64，实为 {arch}")

    jb = [n for n in names if n.startswith("var/jb/")]
    if scheme == "rootless":
        if len(jb) != len(names):
            errs.append(f"rootless 包有 {len(names) - len(jb)} 个文件不在 var/jb 下")
    elif scheme in ("rootful", "roothide"):
        if jb:
            errs.append(f"{scheme} 包不应含 var/jb 前缀，实有 {len(jb)} 个")

    # 必备路径：统一按去掉 var/jb 前缀后比对
    def rel(n):
        return n[len("var/jb/"):] if n.startswith("var/jb/") else n

    rels = {rel(n) for n in names}
    must = [
        "Library/MobileSubstrate/DynamicLibraries/XAutouch.dylib",
        "Library/MobileSubstrate/DynamicLibraries/XAutouch.plist",
        "Applications/XXTExplorer.app/XXTExplorer",
        "Applications/XXTExplorer.app/Info.plist",
        "Library/LaunchDaemons/app.xautouch.agent.plist",
    ]
    for m in must:
        if m not in rels:
            errs.append(f"payload 缺 {m}")

    for sub in ("web", "lua", "bin"):
        n = sum(1 for x in rels if x.startswith(f"usr/lib/xautouch/{sub}/"))
        if n == 0:
            errs.append(f"资源目录为空: usr/lib/xautouch/{sub}/")
        else:
            warns.append(f"usr/lib/xautouch/{sub}/ {n} 文件")

    dylib = next((v for k, v in payload.items()
                  if rel(k).endswith("XAutouch.dylib")), None)
    if dylib and not (dylib.mode & 0o111):
        errs.append("tweak dylib 无执行位，SpringBoard 无法 dlopen")

    tops = {}
    for n in rels:
        tops[n.split("/")[0]] = tops.get(n.split("/")[0], 0) + 1

    print(f"== {os.path.basename(path)}")
    print(f"   control: Package={meta.get('Package')} Version={meta.get('Version')} "
          f"Architecture={arch} Installed-Size={meta.get('Installed-Size')}")
    print(f"   payload: {len(names)} 文件；顶层 " +
          ", ".join(f"{k}={v}" for k, v in sorted(tops.items())) +
          f"；var/jb 前缀 {len(jb)}/{len(names)}")
    if warns:
        print("   " + "；".join(warns))
    for e in errs:
        print(f"   [FAIL] {e}")
    return errs, warns


def main():
    args = sys.argv[1:]
    scheme = None
    if "--scheme" in args:
        i = args.index("--scheme")
        scheme = args[i + 1]
        del args[i:i + 2]
    if not args:
        print("用法: check_deb.py [--scheme rootful|rootless|roothide] <deb> [...]")
        return 2
    bad = 0
    for p in args:
        s = scheme
        if s is None:
            for cand in ("rootful", "rootless", "roothide"):
                if cand in os.path.basename(p):
                    s = cand
        errs, _ = check(p, s)
        bad += len(errs)
    print(f"\n{'PASS' if bad == 0 else 'FAIL'}: {len(args)} 个包，{bad} 个问题")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
