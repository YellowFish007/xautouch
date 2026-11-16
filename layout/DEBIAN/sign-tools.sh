#!/bin/sh
# XAutouch 代码签名工具（与 Sources/XTCodeSigner.mm 等价的 shell 实现）
#
# 用法：由 postinst source 后调用函数（不要直接执行本脚本）：
#   . /var/lib/dpkg/info/app.xautouch.ios.sign-tools.sh
#   xt_sign_file <file> [entitlements-plist]   # 签名；pl 省略时为 ad-hoc
#   xt_verify_file <file>                      # 校验签名
#   xt_resign_bundle <dir>                     # 重签名目录内所有 Mach-O
#   xt_sign_status                             # 打印工具/环境/建议状态
#
# 设计约束：POSIX sh，兼容 iOS /bin/sh；工具探测 codesign -> ldid；
# 参数均加引号（路径含空格安全）；签名失败累计到 stderr 并返回非 0。

# ---- 常量（可被 postinst 覆盖）----
XT_BUNDLE_ID="edu.example.xautouch"
XT_TEAM_ID="TEAMID"
XT_SIGN_TIMEOUT=8

# ---- 缓存（source 后在同一 shell 内有效）----
XT_CODESIGN=""
XT_LDID=""
_XT_PROBED=""

# 越狱前缀：roothide=/rootfs，rootless/trollstore=/var/jb，rootful 为空
_xt_jb_root() {
    if [ -d /rootfs/usr/lib ]; then
        echo "/rootfs"
    elif [ -d /var/jb/usr/lib ]; then
        echo "/var/jb"
    else
        echo ""
    fi
}

_xt_environment() {
    if [ -d /rootfs/usr/lib ]; then
        echo "roothide"
    elif [ -d /var/jb/usr/lib ]; then
        if [ ! -d /Applications/Cydia.app ] && [ ! -d /Applications/Sileo.app ]; then
            echo "trollstore"
        else
            echo "rootless"
        fi
    else
        echo "rootful"
    fi
}

# 查找工具：jbRoot/usr/bin -> /usr/bin -> PATH，输出绝对路径，失败返回 1
_xt_find_tool() {
    _xt_name="$1"
    _xt_root="$(_xt_jb_root)"
    for _xt_dir in "$_xt_root/usr/bin" "$_xt_root/bin" "$_xt_root/usr/local/bin" \
                   /usr/bin /bin /usr/sbin /usr/local/bin; do
        [ -n "$_xt_dir" ] || continue
        if [ -x "$_xt_dir/$_xt_name" ]; then
            echo "$_xt_dir/$_xt_name"
            return 0
        fi
    done
    # PATH 查找（IFS=: 拆分）
    _xt_saved_ifs="$IFS"
    IFS=:
    for _xt_dir in $PATH; do
        if [ -n "$_xt_dir" ] && [ -x "$_xt_dir/$_xt_name" ]; then
            IFS="$_xt_saved_ifs"
            echo "$_xt_dir/$_xt_name"
            return 0
        fi
    done
    IFS="$_xt_saved_ifs"
    return 1
}

# 探测并缓存工具路径；至少有一个可用返回 0
xt_sign_tool_paths() {
    if [ "$_XT_PROBED" = "1" ]; then
        [ -n "$XT_CODESIGN" ] || [ -n "$XT_LDID" ]
        return $?
    fi
    XT_CODESIGN="$(_xt_find_tool codesign)" || XT_CODESIGN=""
    XT_LDID="$(_xt_find_tool ldid)" || XT_LDID=""
    _XT_PROBED="1"
    [ -n "$XT_CODESIGN" ] || [ -n "$XT_LDID" ]
}

# 标准 iOS entitlements plist XML（team id 使用明确占位 TEAMID）
_xt_entitlements_xml() {
cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>TEAMID.edu.example.xautouch</string>
	<key>com.apple.developer.team-identifier</key>
	<string>TEAMID</string>
	<key>keychain-access-groups</key>
	<array>
		<string>TEAMID.edu.example.xautouch</string>
	</array>
	<key>com.apple.developer.ubiquity-container-identifiers</key>
	<array>
		<string>TEAMID.edu.example.xautouch</string>
	</array>
	<key>get-task-allow</key>
	<true/>
	<key>task_for_pid-allow</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.edu.example.xautouch</string>
	</array>
</dict>
</plist>
EOF
}

# 把默认 entitlements 写到 $1（自动建父目录）
xt_write_entitlements() {
    _xt_out="$1"
    [ -n "$_xt_out" ] || return 1
    mkdir -p "$(dirname "$_xt_out")" 2>/dev/null
    _xt_entitlements_xml > "$_xt_out" 2>/dev/null || return 1
    [ -s "$_xt_out" ]
}

# 超时执行命令：$1=秒数，其余为命令与参数
# 超时后 kill -9 子进程并返回非 0；POSIX sh 兼容（& / wait / kill）
_xt_run_timeout() {
    _xt_sec="$1"
    shift
    "$@" &
    _xt_cmd_pid=$!
    ( sleep "$_xt_sec" && kill -0 "$_xt_cmd_pid" 2>/dev/null && kill -9 "$_xt_cmd_pid" 2>/dev/null ) &
    _xt_watch_pid=$!
    wait "$_xt_cmd_pid"
    _xt_rc=$?
    kill "$_xt_watch_pid" 2>/dev/null
    wait "$_xt_watch_pid" 2>/dev/null
    return "$_xt_rc"
}

# 签名单文件：$1=文件，$2=entitlements plist（可省略=ad-hoc）
# 顺序：codesign（带/不带 entitlements）-> 失败回退 ldid -> 都失败返回非 0
xt_sign_file() {
    _xt_target="$1"
    _xt_ent="${2:-}"
    if [ -z "$_xt_target" ]; then
        echo "xt_sign_file: empty path" >&2
        return 1
    fi
    if [ ! -f "$_xt_target" ]; then
        echo "xt_sign_file: file not found: $_xt_target" >&2
        return 1
    fi
    if ! xt_sign_tool_paths; then
        echo "xt_sign_file: no codesign/ldid found (checked jbRoot/usr/bin, /usr/bin, PATH)" >&2
        return 1
    fi

    chmod 755 "$_xt_target" 2>/dev/null

    if [ -n "$XT_CODESIGN" ]; then
        if [ -n "$_xt_ent" ]; then
            _xt_run_timeout "$XT_SIGN_TIMEOUT" "$XT_CODESIGN" --force --sign - \
                --entitlements "$_xt_ent" --timestamp=none "$_xt_target"
        else
            _xt_run_timeout "$XT_SIGN_TIMEOUT" "$XT_CODESIGN" --force --sign - \
                --timestamp=none "$_xt_target"
        fi
        _xt_rc=$?
        if [ "$_xt_rc" -eq 0 ]; then
            echo "xt_sign_file: signed by codesign: $_xt_target"
            return 0
        fi
        echo "xt_sign_file: codesign failed (rc=$_xt_rc), fallback to ldid: $_xt_target" >&2
    fi

    if [ -n "$XT_LDID" ]; then
        if [ -n "$_xt_ent" ]; then
            _xt_run_timeout "$XT_SIGN_TIMEOUT" "$XT_LDID" "-S$_xt_ent" "$_xt_target"
        else
            _xt_run_timeout "$XT_SIGN_TIMEOUT" "$XT_LDID" -S "$_xt_target"
        fi
        _xt_rc=$?
        if [ "$_xt_rc" -eq 0 ]; then
            echo "xt_sign_file: signed by ldid: $_xt_target"
            return 0
        fi
        echo "xt_sign_file: ldid failed (rc=$_xt_rc): $_xt_target" >&2
        return "$_xt_rc"
    fi

    echo "xt_sign_file: no usable signer" >&2
    return 1
}

# 校验签名：codesign --verify --verbose=4 或 ldid -e 有输出即视为通过
xt_verify_file() {
    _xt_target="$1"
    if [ -z "$_xt_target" ] || [ ! -f "$_xt_target" ]; then
        echo "xt_verify_file: file not found: $_xt_target" >&2
        return 1
    fi
    if ! xt_sign_tool_paths; then
        echo "xt_verify_file: no codesign/ldid found" >&2
        return 1
    fi

    _xt_ok=1
    if [ -n "$XT_CODESIGN" ]; then
        if _xt_run_timeout "$XT_SIGN_TIMEOUT" "$XT_CODESIGN" --verify --verbose=4 "$_xt_target"; then
            _xt_ok=0
        fi
    fi
    if [ -n "$XT_LDID" ]; then
        _xt_check="${TMPDIR:-/tmp}/xautouch-entitlements-check.$$"
        if _xt_run_timeout "$XT_SIGN_TIMEOUT" "$XT_LDID" -e "$_xt_target" > "$_xt_check" 2>/dev/null; then
            if [ -s "$_xt_check" ]; then _xt_ok=0; fi
        fi
        rm -f "$_xt_check" 2>/dev/null
    fi

    if [ "$_xt_ok" -eq 0 ]; then
        echo "xt_verify_file: verified: $_xt_target"
        return 0
    fi
    echo "xt_verify_file: verification failed: $_xt_target" >&2
    return 1
}

# 读文件前 4 字节 magic，识别 Mach-O（64/32 位、fat/fat64、大小端）
_xt_is_macho() {
    _xt_file="$1"
    [ -f "$_xt_file" ] || return 1
    _xt_magic="$(head -c 4 "$_xt_file" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    if [ -z "$_xt_magic" ]; then
        _xt_magic="$(od -An -N4 -tx1 "$_xt_file" 2>/dev/null | tr -d ' \n')"
    fi
    case "$_xt_magic" in
        cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca|cafebabf|bfbafeca)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 重签名目录内所有 Mach-O：chmod 755 -> 签名 -> 校验，失败累计到 stderr
xt_resign_bundle() {
    _xt_dir="$1"
    if [ -z "$_xt_dir" ] || [ ! -d "$_xt_dir" ]; then
        echo "xt_resign_bundle: not a directory: $_xt_dir" >&2
        return 1
    fi
    if ! xt_sign_tool_paths; then
        echo "xt_resign_bundle: no codesign/ldid found" >&2
        return 1
    fi

    _xt_tmp="${TMPDIR:-/tmp}"
    _xt_ent="$_xt_tmp/xautouch-entitlements.$$.plist"
    _xt_list="$_xt_tmp/xautouch-macho-list.$$"
    if ! xt_write_entitlements "$_xt_ent"; then
        echo "xt_resign_bundle: failed to write entitlements" >&2
        return 1
    fi

    find "$_xt_dir" -type f > "$_xt_list" 2>/dev/null
    _xt_total=0
    _xt_signed=0
    _xt_failed=0
    # 用 < 重定向而非管道，保证计数变量在当前 shell 保留
    while IFS= read -r _xt_file; do
        [ -n "$_xt_file" ] || continue
        _xt_is_macho "$_xt_file" || continue
        _xt_total=$((_xt_total + 1))
        chmod 755 "$_xt_file" 2>/dev/null
        if xt_sign_file "$_xt_file" "$_xt_ent"; then
            if xt_verify_file "$_xt_file"; then
                _xt_signed=$((_xt_signed + 1))
            else
                echo "xt_resign_bundle: verify failed: $_xt_file" >&2
                _xt_failed=$((_xt_failed + 1))
            fi
        else
            echo "xt_resign_bundle: sign failed: $_xt_file" >&2
            _xt_failed=$((_xt_failed + 1))
        fi
    done < "$_xt_list"

    echo "xt_resign_bundle: total=$_xt_total signed=$_xt_signed failed=$_xt_failed"
    rm -f "$_xt_list" "$_xt_ent" 2>/dev/null
    [ "$_xt_failed" -eq 0 ]
}

# 状态输出：环境 / jbRoot / 工具路径 / 首选工具 / 建议；无工具时返回 1
xt_sign_status() {
    xt_sign_tool_paths || true
    _xt_env="$(_xt_environment)"
    _xt_root="$(_xt_jb_root)"
    _xt_pref="none"
    if [ -n "$XT_CODESIGN" ]; then
        _xt_pref="codesign"
    elif [ -n "$XT_LDID" ]; then
        _xt_pref="ldid"
    fi

    echo "environment=$_xt_env"
    echo "jb_root=$_xt_root"
    echo "codesign=${XT_CODESIGN:-none}"
    echo "ldid=${XT_LDID:-none}"
    echo "preferred_tool=$_xt_pref"

    if [ "$_xt_pref" = "none" ]; then
        echo "advice=未找到签名工具：请先安装 ldid（rootless 在 /var/jb/usr/bin，roothide 在 /rootfs/usr/bin）"
        return 1
    fi
    case "$_xt_env" in
        rootless|trollstore)
            echo "advice=rootless/TrollStore：工具前缀 /var/jb/usr/bin，确认 ldid 已安装"
            ;;
        roothide)
            echo "advice=roothide：工具前缀 /rootfs/usr/bin，确认 ldid/codesign 存在"
            ;;
        *)
            echo "advice=rootful：工具通常在 /usr/bin，签名前确认根分区可写"
            ;;
    esac
    return 0
}
