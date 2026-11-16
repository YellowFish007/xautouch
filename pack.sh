#!/bin/sh
# pack.sh - 把 Theos 编译产物 + layout 打包成 deb
#
# 用法（macOS + Theos 环境）：
#   make package          # Theos 标准打包（推荐）
#   ./pack.sh             # rootful 手动打包
#   ROOTLESS=1 ./pack.sh  # rootless 打包（/var/jb 前缀，推荐 iOS 15+）
set -e
PKG=app.xautouch.ios
VER=1.0.0
OUT=out
STAGE="$OUT/$PKG"

rm -rf "$STAGE"
mkdir -p "$STAGE"

if [ "${ROOTLESS:-0}" = "1" ]; then
    # rootless/roothide：payload 挂到 /var/jb，但 DEBIAN 必须留在归档根，
    # 否则 dpkg-deb 找不到 control，安装会直接失败。
    mkdir -p "$STAGE/var/jb"
    ( cd layout && tar cf - --exclude=DEBIAN . ) | ( cd "$STAGE/var/jb" && tar xf - )
    mkdir -p "$STAGE/DEBIAN"
    cp -R layout/DEBIAN/. "$STAGE/DEBIAN/"
    DYLIB_DIR="$STAGE/var/jb/usr/lib/TweakInject"
    DEST="$OUT/${PKG}_${VER}_iphoneos-arm64-rootless.deb"
else
    cp -R layout/. "$STAGE/"
    DYLIB_DIR="$STAGE/usr/lib/TweakInject"
    DEST="$OUT/${PKG}_${VER}_iphoneos-arm64.deb"
fi

mkdir -p "$DYLIB_DIR"
if [ -f ".theos/obj/XAutouch.dylib" ]; then
    cp .theos/obj/XAutouch.dylib "$DYLIB_DIR/XAutouch.dylib"
    chmod 755 "$DYLIB_DIR/XAutouch.dylib"
else
    echo "警告: 未找到 .theos/obj/XAutouch.dylib，请先执行 make" >&2
fi

# 维护脚本可执行；control 保持 644
chmod 644 "$STAGE/DEBIAN/control" 2>/dev/null || true
for s in preinst postinst prerm postrm sign-tools.sh; do
    [ -f "$STAGE/DEBIAN/$s" ] && chmod 755 "$STAGE/DEBIAN/$s"
done
dpkg-deb -Zxz --build "$STAGE" "$DEST"
echo "打包完成: $DEST"
