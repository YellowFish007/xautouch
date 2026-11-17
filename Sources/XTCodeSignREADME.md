# XAutouch 代码签名 / 重签名链设计说明

本模块参照商业产品 XXTouch 的 `fastPathSign` 自签名工具，替换 `postinst` 中单一的
`ldid -S` 逻辑，提供 Objective-C 层与 shell 层两套等价实现：

| 层 | 文件 | 用途 |
|---|---|---|
| ObjC | `Sources/XTCodeSigner.h/.mm` | HTTP 路由 / tweak 运行时调用 |
| shell | `layout/DEBIAN/sign-tools.sh` | `postinst` 安装期签名（POSIX sh，兼容 iOS `/bin/sh`） |

两者共用同一套策略：**codesign 优先 → 失败回退 ldid → 都失败明确报错**，
并共用同一份默认 entitlements（`edu.example.xautouch` / `TEAMID` 占位）。

---

## 1. entitlements 内容

默认 plist（由 `defaultEntitlementsXML` / `xt_write_entitlements` 生成）包含：

| key | 值 | 作用 |
|---|---|---|
| `application-identifier` | `TEAMID.edu.example.xautouch` | 应用标识，team id + bundle id |
| `com.apple.developer.team-identifier` | `TEAMID` | 辅助 team 声明 |
| `keychain-access-groups` | `[TEAMID.edu.example.xautouch]` | 钥匙串访问组 |
| `com.apple.developer.ubiquity-container-identifiers` | `[TEAMID.edu.example.xautouch]` | iCloud 容器标识 |
| `get-task-allow` | `true` | 允许调试器附加 |
| `task_for_pid-allow` | `true` | 允许 `task_for_pid`（注入/触摸合成依赖） |
| `com.apple.security.application-groups` | `[group.edu.example.xautouch]` | App Group |

`TEAMID` 是明确的占位策略：真机部署时把 `XTCodeSigner.mm` 顶部的
`kXTCodeSignTeamID` 与 shell 脚本 here-doc 中的 `TEAMID` 一并替换为真实 team id 即可。

`signFileAtPath:entitlements:` 的 `entitlements` 参数语义：

- `nil`：使用上表默认 entitlements（推荐，等于 fastPathSign 的完整签名）；
- `@{}`：ad-hoc 签名（`ldid -S` / `codesign --sign -`，不带 entitlements）；
- 非空字典：序列化调用方提供的 plist 后签名。

---

## 2. 工具探测顺序与签名流程

探测顺序（`ensureTools` / `xt_sign_tool_paths`）：

1. `codesign`（优先）：`jbRoot/usr/bin` → `jbRoot/bin` → `/usr/bin` → `/bin` → `PATH`；
2. `ldid`（回退）：同上候选目录；
3. 两者都不存在：`code != 0` / 返回非 0，并在 stderr / `last_error` 写明
   "未找到签名工具"，绝不静默跳过。

签名路径：

```
codesign --force --sign - --entitlements <plist> --timestamp=none <file>
  └─失败→ ldid -S<plist> <file>
ad-hoc 时：
codesign --force --sign - --timestamp=none <file>
  └─失败→ ldid -S <file>
```

校验路径：

```
codesign --verify --verbose=4 <file>
ldid -e <file>                 # 解析输出为 plist，能导出 entitlements 即视为已签名
```

所有外部命令都通过 `NSTask` 的**参数数组**调用（shell 层全部参数加引号），
路径含空格安全，无 shell 注入风险；每个调用都有 8 秒超时守护（到点 kill）。

---

## 3. postinst 接线片段

`DEBIAN/sign-tools.sh` 会被 dpkg 作为控制文件安装到
`/var/lib/dpkg/info/app.xautouch.ios.sign-tools.sh`（保留可执行位）。
把原 `postinst` 第 77–84 行的签名循环整段替换为：

```sh
# 5b) 代码签名：codesign 优先 -> ldid 回退 -> 明确报错
SIGN_TOOLS="/var/lib/dpkg/info/app.xautouch.ios.sign-tools.sh"
[ -f "$SIGN_TOOLS" ] || SIGN_TOOLS="$PREFIX/bin/sign-tools.sh"

if [ -f "$SIGN_TOOLS" ]; then
    . "$SIGN_TOOLS"
    ENT_TMP="${TMPDIR:-/tmp}/xautouch-entitlements.$$.plist"
    xt_write_entitlements "$ENT_TMP"
    for BIN in /usr/lib/TweakInject/XAutouch.dylib "$ROOT/usr/lib/TweakInject/XAutouch.dylib"; do
        [ -f "$BIN" ] || continue
        chmod 755 "$BIN"
        chown root:wheel "$BIN"
        if xt_sign_file "$BIN" "$ENT_TMP"; then
            xt_verify_file "$BIN" || echo "XAutouch: verify failed: $BIN" >&2
        else
            echo "XAutouch: sign failed for $BIN, trying ldid -S fallback" >&2
            ldid -S "$BIN" >/dev/null 2>&1 || echo "XAutouch: ldid -S fallback also failed: $BIN" >&2
        fi
    done
    rm -f "$ENT_TMP"
    xt_sign_status
else
    echo "XAutouch: sign-tools.sh missing, fallback to plain ldid -S" >&2
    for BIN in /usr/lib/TweakInject/XAutouch.dylib "$ROOT/usr/lib/TweakInject/XAutouch.dylib"; do
        [ -f "$BIN" ] || continue
        chmod 755 "$BIN"
        ldid -S "$BIN" >/dev/null 2>&1 || echo "XAutouch: ldid -S failed: $BIN" >&2
    done
fi
```

建议同时在打包布局中复制一份到 `layout/usr/lib/xautouch/bin/sign-tools.sh`，
供运行时 HTTP 路由 / 守护进程复用；`postinst` 里的第二个候选路径已覆盖这种情况。

---

## 4. HTTP 路由建议

在 `Sources/XTRoutes.mm` 顶部 `#import "XTCodeSigner.h"`，并在「系统控制」段加入：

```objc
if ([path isEqualToString:@"/api/system/sign"]) {
    // POST: path       -> 目标绝对路径
    //       entitlements -> 可选 NSDictionary（省略=默认，{}=ad-hoc）
    NSString *p = [req stringForKey:@"path" defaultValue:@""];
    NSDictionary *ent = [req valueForKey:@"entitlements"];
    return [XTHTTPResponse json:[[XTCodeSigner sharedInstance]
              signFileAtPath:p entitlements:[ent isKindOfClass:[NSDictionary class]] ? ent : nil]];
}
if ([path isEqualToString:@"/api/system/verify"]) {
    // POST: path -> 目标绝对路径
    return [XTHTTPResponse json:[[XTCodeSigner sharedInstance]
              verifyFileAtPath:[req stringForKey:@"path" defaultValue:@""]]];
}
if ([path isEqualToString:@"/api/system/resign"]) {
    // POST: path -> .app / 目录绝对路径
    return [XTHTTPResponse json:[[XTCodeSigner sharedInstance]
              resignBundleAtPath:[req stringForKey:@"path" defaultValue:@""]]];
}
if ([path isEqualToString:@"/api/system/sign-status"]) {
    // GET: 工具可用性、签名计数、最后时间/错误、环境与建议
    return [XTHTTPResponse json:[[XTCodeSigner sharedInstance] signStatus]];
}
```

调用示例：

```sh
curl -s -X POST http://127.0.0.1:8080/api/system/sign \
     -d 'path=/usr/lib/TweakInject/XAutouch.dylib'
curl -s -X POST http://127.0.0.1:8080/api/system/verify \
     -d 'path=/usr/lib/TweakInject/XAutouch.dylib'
curl -s -X POST http://127.0.0.1:8080/api/system/resign \
     -d 'path=/Applications/Demo.app'
curl -s http://127.0.0.1:8080/api/system/sign-status
```

所有响应统一 `{code, message, ...}`：`code == 0` 成功；非 0 时 `message` /
`stderr` / `errors` 给出可读原因。

---

## 5. rootless / roothide / TrollStore 路径差异

| 环境 | jbRoot | 探测工具前缀 | TweakInject dylib |
|---|---|---|---|
| rootful | `""` | `/usr/bin` | `/usr/lib/TweakInject/XAutouch.dylib` |
| rootless | `/var/jb` | `/var/jb/usr/bin` | `/var/jb/usr/lib/TweakInject/XAutouch.dylib` |
| roothide | `/rootfs` | `/rootfs/usr/bin` | `/rootfs/usr/lib/TweakInject/XAutouch.dylib` |
| TrollStore | `/var/jb` | 通常无 dpkg 工具链，按 `/var/jb/usr/bin` 探测，常只能 ad-hoc | `/var/jb/usr/lib/...` |

`XTCodeSigner` 通过 `XTApplication` 的 `environment` / `jbRoot` 推导前缀：
先探测 `jbRoot/usr/bin`，再固定探测 `/var/jb`、`/rootfs`，最后 `PATH`，
因此四种环境都无需硬编码路径。`postinst` 用 `ROOT` 变量覆盖 dylib 目标路径。

---

## 6. 重签名实现细节

`resignBundleAtPath:` / `xt_resign_bundle`：

1. `NSFileManager subpathsOfDirectoryAtPath:` / `find <dir> -type f` 递归枚举；
2. 读取文件头 4 字节检测 magic：
   `0xfeedfacf` / `0xcefaedfe`（小端 Mach-O）、`0xcafebabe`（fat）及其大小端变体；
3. 跳过符号链接与非 Mach-O 文件；
4. 签名前 `chmod 755`；
5. 逐个签名并校验，失败项收集进 `errors` / `failed` 数组（含 `stage: sign|verify`、`file`、`message`、`stderr`）；
6. 有任一失败即返回非 0 `code`，并在 `message` 中给出失败数量。

---

## 7. 编译兼容说明

- `NSTask` / `NSPipe` 在 iPhoneOS SDK 中通常不公开头文件。
  `XTCodeSigner.mm` 使用 `__has_include(<Foundation/NSTask.h>)` 条件编译：
  SDK 有头文件时使用系统声明，否则使用文件内的最小前向声明。
  越狱运行时 Foundation 二进制内确实包含这两个类，因此 macOS + Theos 下可直接编译，
  不引入不存在的私有 API。
- `Makefile` 需在 `XAutouch_FILES` 中加入 `Sources/XTCodeSigner.mm`（无需额外 framework / linker flag）。
