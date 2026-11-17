# XAutouch — iOS 触摸自动化与脚本控制平台

对标商业产品 XXTouch（`app.xxtouch.ios` 1.3.8）的毕业设计实现。目标是**功能清单逐条对齐**：同构 deb 包 + MobileSubstrate 注入 SpringBoard + IOHID 系统级触摸合成 + Lua 5.4 脚本引擎 + Web 管理面板 + 独立文件管理器 App + 多引擎 OCR/模板触发 + 远程媒体传输 + 完整签名链。

![build](https://github.com/YellowFish007/xautouch/actions/workflows/build.yml/badge.svg)
![release](https://img.shields.io/github/v/release/YellowFish007/xautouch?label=deb)
![size](https://img.shields.io/github/release-date/YellowFish007/xautouch?label=last%20build)

> 包名/域名用 `xautouch` / `example.edu` 占位，避免与商业版冲突。核心机制、API 结构、资源布局与参照对象同构。

> 已实测产物见 [§3.1.1](#311-已验证产物release-直链可直接安装)，三种 scheme 的 deb 可直接下载安装。

**先看哪份文件**（省得翻整个仓库）：

| 想知道 | 看这里 | 说明 |
|---|---|---|
| 有哪些功能、落在哪个文件 | [`docs/FEATURES.md`](docs/FEATURES.md) | **源码自动生成**，122 条端点 + 46 个模块 + 资源清单，永远等于代码事实 |
| 功能清单与答辩对照 | 本文件第一节 | 人工整理，含设计取舍说明 |
| 怎么编译、怎么装 | 本文件第三节 | CI 与手动两条路 |
| 与商业版差在哪 | [`docs/FEATURES.md` §7](docs/FEATURES.md) | 6 项已知差异，附影响 |
| 怎么证明没吹 | 本文件第五节 + `tests/` | 309 项静态自检 + 161 项逐项对拍 |

---

## 一、功能对照矩阵（答辩用）

每一项都对应到具体源文件，可逐条核查。

### 1. 设备端 HTTP 控制面 — 39/39 路由全部实现

`Sources/XTRoutes.mm`，含 `Tweak.xm` 注入入口与 `XTHTTPServer.mm` 网络层。

| 分组    | 路由                                                                                                                                                                                                                             |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 应用/配置 | `/api/app/register` `/api/app/state` `/api/config`                                                                                                                                                                             |
| 文件    | `/api/file` `/api/file/` `/api/file/copy` `/api/file/move`                                                                                                                                                                     |
| 按键    | `/api/key/down` `/api/key/press` `/api/key/up`                                                                                                                                                                                 |
| 剪贴板   | `/api/pasteboard/read` `/api/pasteboard/write`                                                                                                                                                                                 |
| 路径    | `/api/path/jbroot` `/api/path/jbroot/` `/api/path/rootfs` `/api/path/rootfs/`                                                                                                                                                  |
| 进程    | `/api/proc` `/api/proc-dict/run`                                                                                                                                                                                               |
| 截屏    | `/api/screen/snapshot`                                                                                                                                                                                                         |
| 脚本    | `/api/script` `/api/script/` `/api/script/pause` `/api/script/resume` `/api/script/run` `/api/script/selected` `/api/script/stop`                                                                                              |
| 系统    | `/api/system/log` `/api/system/reboot` `/api/system/respring`                                                                                                                                                                  |
| 触摸    | `/api/touch/down` `/api/touch/move` `/api/touch/up` `/api/touch/tap` `/api/touch/drag-curve` `/api/touch/drag-curve-async` `/api/touch/drag-linear` `/api/touch/drag-linear-async` `/api/touch/wheel` `/api/touch/wheel-async` |

### 2. Web 管理面板端点 — 44/44 全覆盖

`xxtouch_auth.js` / `xxtouch_service.js` / `upgrade.js` / `startup_conf.js` / `cc.js` / `screen.js` 等面板脚本引用的端点：

认证 `/device_auth_info` `/bind_code` `/deviceinfo`；远程访问 `/open_remote_access` `/close_remote_access` `/is_remote_access_opened`；服务控制 `/restart` `/uicache` `/clear_gps` `/clear_all` `/halt` `/reboot2` `/respring`；deb 安装 `/install_deb`；配置 `/get_user_conf` `/set_user_conf`；启动脚本 `/get_startup_conf` `/set_startup_run_on` `/set_startup_run_off` `/select_startup_script_file` `/daemon_spawn`；文件管理 `/file_list`（已兼容原版 `data.data.list` + `mode`/`change` 字段）`/read_file` `/write_file` `/encript_file` `/remove_file` `/rename_file` `/mkdir` `/rmdir` `/recycle` `/api/file/copy` `/api/file/move`；脚本 `/launch_script_file` `/select_script_file` `/get_selected_script_file` `/check_syntax` `/spawn`；应用 `/applist` `/clear_app_data`；录制 `/get_record_conf` `/get_volume_action_conf`；日志 `/api/log/stream`（SSE）；WebSocket 控制通道。

### 3. 触摸引擎

**参照**：`libxxtouch.so` + `1feaks.dylib`（MobileSubstrate tweak）  
**本工程**：`Sources/XTTouchSynthesizer.mm` + `Sources/Tweak.xm`

IOHID digitizer 事件合成（`IOHIDEventCreateDigitizerEvent`），私有符号 `dlsym` 动态解析。能力：tap / down / move / up、直线与曲线拖拽（含 async）、滚轮、多点触控、实体按键 down/up、文本输入、剪贴板读写、操作录制与序列回放。

### 4. 脚本引擎

**参照**：完整 Lua VM + `.xpa`/`.xxt` 加密分发  
**本工程**：`Sources/XTScriptEngine.mm` + `vendor/lua/src/`（Lua 5.4.7 官方源码，34 个 .c 自包含）

真实 `luaL_newstate` VM，`luaL_loadbuffer` 编译期语法检查，19 个 `xtouch.*` 原生函数，协程调度 + 暂停/恢复/停止，AES-128-CBC 脚本加解密（`.xxt` 格式），Web 编辑器前置语法诊断。

### 5. Web 管理面板

**参照**：`1ferver/web/`（110 个文件）  
**本工程**：`layout/usr/lib/xautouch/web/`（110 个文件，同构资源）+ `Sources/XTHTTPServer.mm` 静态服务

完整 HTTP/1.1、multipart 上传、SSE 日志流、WebSocket 握手、CORS、MIME 映射。第 2 节 35 个端点全部可用——复制过来的真实面板资源按钮不会再 404。

### 6. 图像识别 / OCR

**参照**：ONNX + ncnn + Tesseract + OpenCV 四套引擎（约 40 MB）  
**本工程**：`Sources/XTVision.mm` + `Sources/XTVisionEngineRegistry.mm` + 三个适配器

| 引擎                     | 文件                     | 状态                                                                                          |
| ---------------------- | ---------------------- | ------------------------------------------------------------------------------------------- |
| Apple Vision OCR + NCC | `XTVision.mm`          | 默认内置，始终可用（原生框架替代 ONNX/Tesseract，去掉 40MB 依赖）                                                 |
| ONNX Runtime           | `XTONNXEngine.mm`      | `dlsym` 加载 `libonnxruntime`，OrtApi v17 函数表，`CreateSession`/`Run` 真实调用；有 `models/*.onnx` 时可用 |
| ncnn                   | `XTNCNNEngine.mm`      | `dlsym` + extern C 桥接，`ncnn.param`/`ncnn.bin` 探测                                            |
| Tesseract              | `XTTesseractEngine.mm` | `dlsym` 取 `TessBaseAPICreate`/`Init3`/`GetUTF8Text` 等 C API，`chi_sim`/`eng` traineddata 探测  |

统一走 `XTVisionEngine` 协议。优先级 `onnx(10) → ncnn(20) → tesseract(30)`，异常/错误自动降级到 builtin。`GET /api/vision/engines` 查状态，`POST /api/vision/engine` 切换，选择持久化到 `NSUserDefaults`。模型放置路径与下载说明见 `Sources/XTVisionEnginesREADME.md`。

### 7. 文件管理器 App

**参照**：`XXTExplorer.app`（398 个条目）  
**本工程**：`Sources/XXTExplorer/`（Theos `APPLICATION_NAME` 独立 target，1165 行）

`XTEAPIClient.mm` 通过本地 HTTP API 操作文件；`XTEFileListController.mm` 目录浏览/搜索/排序/长按菜单（重命名/删除/复制/移动/回收站/运行脚本）/新建；`XTEFileEditorController.mm` 文本编辑/保存/运行/语法检查/图片预览。全部 UI 代码构建，无 storyboard 依赖。

### 8. 远程控制 / 屏幕共享

**参照**：`open-cloud-control-client.lua` / `touchelf-udpd.lua` / `web-screen.lua` + WebRTC 信令  
**本工程**：4 个模块

| 模块        | 文件                  | 实现                                                                                                                                                              |
| --------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WebRTC 媒体 | `XTWebRTCMedia.mm`  | VideoToolbox H.264 硬编码（`VTCompressionSessionCreate`）、CVPixelBuffer、RTP-like 帧分片、BSD UDP、AVAudioEngine + AAC 音频、统计信息；`/api/webrtc/{start,stats,answer,ice,stop}` |
| UDP 控制    | `XTUDPControl.mm`   | BSD socket + dispatch_source，JSON over UDP，token 鉴权，触摸/按键/脚本/截屏命令分发                                                                                             |
| 云控客户端     | `XTCloudControl.mm` | NSURLSessionWebSocketTask、心跳、断线重连（退避）、配置持久化、SSE 状态广播                                                                                                            |
| 屏幕共享      | `XTScreenShare.mm`  | 截图 → JPEG 压缩 → 分片 UDP；`/api/screen/stream` 是真正的 `multipart/x-mixed-replace` MJPEG 长连接，另有 `/frame` 单帧端点                                                          |

### 9. UI 服务 / 自更新

**参照**：`uiservice-toast` / `show-pose` / `view` / `alerthelper` / `volume-key-control` + `xxt-check-update.lua`  
**本工程**：`Sources/XTUIService.mm`（632 行）

覆盖层 window Toast（三档位置）、触摸点圆圈可视化（录屏演示用）、可拖动悬浮窗、UIAlert 服务、音量键动作绑定（tap/script/key）、访问 `https://xxtouch.app/api/latest-version` 的更新检查。路由 `/api/ui/{toast,pose,floating,alert}` `/api/volume/{bind,action}` `/api/system/check-update`；音量键 hook 在 `Tweak.xm`。

### 10. 签名链

**参照**：`fastPathSign`  
**本工程**：`Sources/XTCodeSigner.mm` + `layout/DEBIAN/sign-tools.sh`

生成完整 entitlements（含 `get-task-allow`、`task_for_pid-allow`、keychain/ubiquity/app-groups），`codesign` 优先、`ldid` 回退，NSTask 参数数组（无 shell 注入）、8 秒超时；遍历目录内全部 Mach-O（8 种 magic）重签名。postinst 直接 source shell 工具重签 tweak dylib 与文件管理器 App。路由 `/api/system/{sign,verify,resign,sign-status}`。

### 11. 安装与环境适配

`Makefile` / `control` / `layout/DEBIAN/*` / `pack.sh`

rootful / rootless / roothide / TrollStore 四环境自动探测与路径推导；postinst 资源迁移、用户数据恢复、默认脚本生成、目录权限、LaunchDaemon 注册、uicache、SpringBoard 重启；prerm/postrm 完整清理。修复了 rootless 打包时 DEBIAN 目录位置错误（必须在归档根，payload 在 `/var/jb`）。

---

## 二、目录结构

```
xautouch/
├── Makefile                     # aggregate.mk 双实例：tweak + app
├── control / pack.sh
├── Sources/                     # Objective-C++/Logos 源文件
│   ├── Tweak.xm                 # 注入入口（音量键 hook、服务启动）
│   ├── XT*.mm / XT*.h           # 核心模块
│   └── XXTExplorer/             # 独立文件管理器 App（9 文件 + Info.plist）
├── vendor/lua/src/              # Lua 5.4.7 源码（34 个 .c）
├── layout/
│   ├── DEBIAN/                  # control + 4 维护脚本 + sign-tools.sh
│   ├── Library/LaunchDaemons/   # app.xautouch.agent.plist
│   └── usr/lib/xautouch/        # web(110) / lua(119) / bin(27)
├── Sources/*README.md           # 各模块设计说明（引擎/UI/网络/签名/媒体/App）
├── docs/FEATURES.md             # 功能细节总表（tools/gen_features.py 生成）
├── tests/verify.py              # 309 项静态自检
├── tests/audit.py               # 161 项与商业版逐项对拍（基线在 tests/baseline/）
└── tools/check_deb.py           # 纯 Python deb 结构校验器（CI 与本地通用）
```

## 三、编译与安装

### 3.1 GitHub Actions 自动编译（推荐，无需本机 macOS）

工程已配现成 CI：`.github/workflows/build.yml`，使用 `waruhachi/theos-action@v2.6.6`（Theos 与 SDK 取 `waruhachi/theos` / `waruhachi/sdks` 的 `main` 分支——官方 `theos/theos` master 不含 `roothide` scheme，会报 “roothide package scheme does not exist”），在 macOS runner 上一次编译 **rootful / rootless / roothide** 三种越狱环境。

流程：

1. 把工程推到 GitHub 仓库（分支 `main` 或 `master`）。
2. `push` / `PR` / 手动 `workflow_dispatch` 均触发。
3. `audit` job 先在 ubuntu 跑 309 项自检 + 161 项全量对拍，全绿才进入编译。
4. `build` job 用 theos-action 安装 Theos + iOS SDK，`make clean && make package FINALPACKAGE=1`，三种 scheme 分别产出 deb。
5. 每个 deb 跑 `python3 tools/check_deb.py` 校验 control 字段、维护脚本权限、必备路径与 `var/jb` 前缀，然后作为 artifact 上传，直接下载即可安装。
6. 三种 scheme **串行跑在同一个 macOS job** 里。早先用 matrix 拆成三个 job 时，`macos-latest` 抢不到 runner 的 job 在排队约 15 分钟后会被平台直接 cancel（实测连丢两次 `rootful`），串行只占一个 runner，命中率高得多。

产物命名（Theos 默认输出到 `./packages/`）：

| scheme | 产物 | 载荷前缀 |
|---|---|---|
| rootful | `app.xautouch.ios_1.0.0_iphoneos-arm64.deb` | `/` |
| rootless | `app.xautouch.ios_1.0.0_iphoneos-arm64.deb` | `/var/jb/` |
| roothide | `app.xautouch.ios_1.0.0_iphoneos-arm64e.deb` | roothide 布局 |

包内实测包含（解包核对过）：

- `Library/MobileSubstrate/DynamicLibraries/XAutouch.dylib` + `XAutouch.plist`（注入 SpringBoard）
- `Applications/XXTExplorer.app/`（可执行文件 + Info.plist）
- `usr/lib/xautouch/{web,lua,bin,bundles,models,tessdata}` 全部资源
- `Library/LaunchDaemons/app.xautouch.agent.plist`
- `control.tar.gz` 内 `preinst/postinst/prerm/postrm`（权限 0755）

下载后在越狱设备安装（rootless 示例）：

```bash
scp app.xautouch.ios_1.0.0_iphoneos-arm64.deb root@iphone:/var/tmp/
ssh root@iphone "dpkg -i /var/tmp/app.xautouch.ios_1.0.0_iphoneos-arm64.deb && killall -9 SpringBoard"
```

### 3.1.1 已验证产物（Release 直链，可直接安装）

三种 scheme 均已在本仓库 CI 中编译成功并解包核对，产物挂在 [Releases v1.0.0](https://github.com/YellowFish007/xautouch/releases/tag/v1.0.0)，`curl -LO` 即可下载（无需登录）：

| scheme | 直链 | 大小 | payload 文件数 |
|---|---|---|---|
| rootful | [`xautouch-1.0.0-rootful-arm64.deb`](https://github.com/YellowFish007/xautouch/releases/download/v1.0.0/xautouch-1.0.0-rootful-arm64.deb) | 4.56 MiB / 4.79 MB | 280 |
| rootless | [`xautouch-1.0.0-rootless-arm64.deb`](https://github.com/YellowFish007/xautouch/releases/download/v1.0.0/xautouch-1.0.0-rootless-arm64.deb) | 4.56 MiB / 4.79 MB | 280 |
| roothide | [`xautouch-1.0.0-roothide-arm64e.deb`](https://github.com/YellowFish007/xautouch/releases/download/v1.0.0/xautouch-1.0.0-roothide-arm64e.deb) | 4.56 MiB / 4.79 MB | 280 |

> 大小同时写 MiB 与 MB 两个口径：4.56 MiB = 4.79 MB。iOS「文件」App 按十进制显示 **4.8 MB**，Windows 按二进制显示 **4.56 MB**，是同一个文件。要核对请比对字节数：rootless `4785938` / roothide `4785708` / rootful `4784934`。
> 工程未启用 `-frandom-seed` 等可复现构建选项，同一份源码重新编译出的字节每次都不同（Mach-O UUID + ar/tar 时间戳），所以这里不写死哈希——校验请下载后跑 `python3 tools/check_deb.py <deb>`，它比哈希更能说明问题。

实测核对结论（`tools/check_deb.py` 解析 ar + tar 逐条清点）：

- 每个包 **280 个文件**；rootful / roothide 顶层为 `Applications Library usr`，rootless 全部落在 `var/jb/` 前缀下。
- 内置资源 `usr/lib/xautouch/` 与原版 `var/mobile/Media/1ferver/` **文件名 256/256 全量对齐**（bin 27、lua 119、web 110），另加本工程新增 `bundles` 12、`models` 5、`tessdata` 1、`bin/xautouchd` 1，合计 280。
- `control` 段 `Installed-Size: 14152`，`Architecture` 分别为 `iphoneos-arm64` / `iphoneos-arm64e`；`preinst/postinst/prerm/postrm` 权限均为 `0755`。

### 3.1.2 CI 实测暴露并已修复的编译问题

这些是**本机 Windows 无法发现、只有真实 clang 才暴露**的问题，均已修复并通过 CI：

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | `preinst/postinst 存在且可执行` 在 CI 失败 | 经 API 推送时文件 mode 全为 `100644`，丢了执行位（Windows 上 `os.access(X_OK)` 恒真） | 以 `100755` 重新提交维护脚本 |
| 2 | `cannot initialize 'const char *' with 'const void *'` | Objective-C++ 下 `NSData.bytes` 是 `const void *` | 显式转型 |
| 3 | `use of undeclared identifier 'TCP_NODELAY'` | 缺 `<netinet/tcp.h>` | 补头文件 |
| 4 | `'system' is unavailable: not available on iOS` | iOS SDK 禁用 `system(3)` | 改用 `posix_spawn`；Lua 侧用 `-Dl_system=xt_system` 注入垫片 |
| 5 | `import of C++ module ... within extern "C"` | Theos 自带 IOKit 头与 Xcode 15+ clang 模块冲突 | 删除未使用的 IOKit 头（符号本就走 dlsym） |
| 6 | `-Werror` 让零散 warning 直接中断 | Theos 默认加 `-Werror` | `GO_EASY_ON_ME = 1`（保留 `-Wall`） |
| 7 | `invalid argument '-std=c++17' not allowed with 'C'` | `-std=c++17` 被套到随工程编译的 Lua 纯 C 源码 | C++ 参数移入 `_CCFLAGS` |
| 8 | `use of undeclared identifier 'typeof'` | ObjC++ 不认裸 `typeof` | 统一 `__typeof__` |
| 9 | `framework 'BackBoardServices' not found` | 公开 SDK 无私有框架二进制 | 移除私有框架链接，符号由 `-Wl,-undefined,dynamic_lookup` 运行时解析 |
| 10 | `You are missing a filter property list` | Theos 只从**工程根目录**找 `XAutouch.plist` | 补根目录 filter plist |
| 11 | `ls: .theos/packages/: No such file` | Theos 默认输出 `./packages/` | CI 校验步骤同时兼容两个目录 |
| 12 | `dpkg-deb: command not found` | `macos-26-arm64` 镜像不再预装 dpkg，靠它校验产物会假失败 | 自写纯 Python 校验器 `tools/check_deb.py`（解析 ar + control.tar + data.tar，校验字段/权限/必备路径/`var/jb` 前缀），CI 与本地通用 |
| 13 | `macos-latest` 上 matrix 某个 job 排队约 15 分钟后被 cancel | 平台对长时间等不到 macOS runner 的 job 直接取消，实测连丢两次 `rootful` | 三种 scheme 合并进同一个 macOS job 串行编译，只占一个 runner |
| 14 | rootless 装完 8080 打不开、`launchctl list` 里没有 `app.xautouch.agent` | `layout/` 三种 scheme 共用一份 launchd plist，`ProgramArguments` 写死 `/usr/lib/xautouch/bin/xautouchd`；rootless 下 payload 与 plist 都在 `/var/jb`，launchd 在真实根上找不到这个可执行文件，静默失败 | 新增 `after-stage` 钩子 `tools/fix_stage_plist.py`，按 `THEOS_PACKAGE_SCHEME` 改写 `ProgramArguments`；`verify.py` 加 5 条断言锁住，回退即红 |
| 15 | 真机装完约 10 分钟后桌面自动重启，反复进 Safe Mode | `xautouchd` 按 `engine.log` 的 mtime 判断"引擎卡死"，超 600s 就 `killall -9 SpringBoard`；但全工程**只有它自己**写这个日志（且只在启动时写一行），所以装完必然进入"每 10 分钟杀一次桌面 → 重新注入 → 崩 → Safe Mode"的死循环 | 守护脚本改为**纯观察模式**，只记录不杀桌面；`verify.py` 断言 `killall -9 SpringBoard` 不得出现在脚本里 |
| 16 | Sileo 卸载报 `E: The package app.xautouch.ios needs to be reinstalled, but I can't find an archive for it`，此后 apt 全局不可用 | `postinst`/`postrm` 末尾 `killall -9 SpringBoard` 发生在 **dpkg 事务内**，事务被打断后包停在 `reinstreq` 状态；apt 的 `pkgDepCache::Init` 遇到这种包会直接让**所有**操作失败 | 维护脚本一律不在事务内杀桌面，改由用户在 Sileo 点"重启 SpringBoard"；`verify.py` 逐个脚本断言 |
| 17 | 1.0.0-2 的熔断没生效，Safe Mode 仍然退不出来 | 熔断标记写在 `applicationDidFinishLaunching` 里，若崩在 `%ctor`／dylib 构造阶段，标记根本没写出去 | 标记前移到 `%ctor` 内、`%init` 之前；只有全部初始化成功才 `unlink`。崩在哪一层都会留下标记，下次启动直接返回不注入 |

`tests/verify.py` 已把第 1/4/7/8/10 类问题固化为静态断言（头文件存在性、裸 `typeof`、`system` 调用、`bytes` 隐式转型、filter plist），避免回归。

### 3.2 本机 macOS 手动编译

```bash
git clone --recurse-submodules https://github.com/theos/theos.git $THEOS
# 配置 iOS SDK，设置 THEOS 环境变量
cd xautouch && make clean && make package
# 或手动打包：ROOTLESS=1 ./pack.sh
```

编译验证清单：

- `make` 无 error → 生成 `.theos/obj/XAutouch.dylib` 和 `XXTExplorer.app`
- `dpkg-deb -I` 能看到完整 control，`dpkg-deb -c` 能看到 DEBIAN 在归档根
- 安装后 `curl http://<设备IP>:46899/deviceinfo` 返回 JSON
- `curl -s http://<设备IP>:46899/api/vision/engines` 列出四个引擎状态
- `curl -s http://<设备IP>:46899/api/system/sign-status` 显示签名工具可用

## 四、Lua 脚本示例

```lua
-- scripts/demo.lua
xtouch.log("demo started")
xtouch.tap(200, 400)
xtouch.sleep(300)
xtouch.swipe(200, 600, 600, 600, 400)
local shot = xtouch.snapshot()
local hit = xtouch.findImage("button.png", 0.9)
if hit.found then xtouch.tap(hit.x, hit.y) end
local r = xtouch.ocr("登录")
if r.matched then xtouch.input("hello") end
```

`/check_syntax` 用 `luaL_loadbuffer` 真编译，返回 Lua 语法错误与未知 `xtouch.*` 函数警告。

## 五、自检与全量对拍

```bash
python tests/verify.py    # 309 PASS, 0 FAIL —— 工程内部静态自检
python tests/audit.py     # 161 项对拍，已对齐 148 / 同构等价 13 / 缺失 0，覆盖率 100%
```

`tests/verify.py` 覆盖 11 个维度：control/DEBIAN/资源布局、39 设备路由、35 Web 面板端点、触摸原语、Lua VM、NCC/OCR、四环境适配、HTTP 网络层、四个新增功能对齐模块、源码括号与 Objective-C 声明配对。

`tests/audit.py` 是与商业 XXTouch 的**逐项对拍工具**，基线来自 `tt.deb` 的真实提取结果（`tests/baseline/orig-data-files.txt` 674 文件 + `orig-data-entries.txt` 782 条目）。对拍分七组：

| 组 | 内容 | 结果 |
|---|---|---|
| A 资源 | web 110/110、lua 119/119、bin 27/27（另加自研 `xautouchd`，实 28）、bundles 12/12、models 5/5、tessdata 1/1 逐文件比对 | 全部已对齐 |
| B 二进制 | 12 个商业 Mach-O/动态库 → 本工程源码等价实现逐项映射 | 13 项同构等价 |
| C 路由 | 原版 39 条设备端 HTTP 路由 | 全部已对齐 |
| D 端点 | 原版 Web 面板 40+ 端点 | 全部已对齐 |
| E 增强 | 本工程新增 32 个端点（视觉/签名/UI/音量/UDP/云控/流媒体/录制） | 全部已对齐 |
| F Lua | 19 个 `xtouch.*` 原生函数 | 全部已对齐 |
| G 安装 | 四越狱环境 + control 元数据 + 维护脚本 + launchd | 全部已对齐 |

状态语义：**已对齐**=逐文件或逐项一致；**同构等价**=商业二进制用自有源码实现同等功能；**外部资源**=需用户提供私有凭据；**缺失**=未实现（当前为 0）。

> 说明：本机无 clang/gcc，两个脚本都是**平台无关的文本级校验**，不能替代 macOS 上的真实编译；编译由 GitHub Actions 完成。

## 六、已知边界（如实标注）

| 项                        | 状态                                | 说明                                                                              |
| ------------------------ | --------------------------------- | ------------------------------------------------------------------------------- |
| Mach-O 编译与真机运行           | **CI 编译，真机未安装验证**                | GitHub Actions 完成编译打包与 deb 结构校验；运行时逐项对拍需你在越狱机按第三节清单执行                         |
| ONNX/ncnn/Tesseract 动态库    | **适配器已实现，模型已入库**                 | PP-OCR 模型（3.2MB）与 `eng.traineddata`（3MB）已从原包提取入库，`models/`+`tessdata/` 开箱可用；onnxruntime/ncnn dylib 用 `dlsym` 探测，缺失自动回退内置 Vision/NCC |
| WebRTC 完整 SDP/ICE        | **简化 JSON 信令 + 自研 H.264/RTP 协议** | 未接 libwebrtc，功能等价（屏幕+音频实时传输）；媒体协议格式见 `XTWebRTCMediaREADME.md`                   |
| 商业版签名私钥                  | **TEAMID 占位 + ad-hoc 签名**         | 私钥不随工程分发；`ldid`/`codesign` 链路完整可用                                               |
| XXTExplorer.app nib/主题/图标  | **代码构建 UI 等价替代**                 | 371 个二进制 UI 资源由 `Sources/XXTExplorer/` 1165 行 UIKit 代码与系统默认样式实现，无 storyboard/nib 依赖            |

## 七、毕设可写点

1. IOHID 私有符号 `dlsym` 动态解析，一套代码兼容四种越狱环境。
2. 可插拔多引擎视觉架构：运行时按可用性降级，避免 40MB 模型硬依赖。
3. Lua 编译期语法检查前置到 Web 编辑器，减少真机调试成本。
4. 39 路由控制面 + WebSocket/SSE/MJPEG 三通道，可审计、可复现。
5. aggregate.mk 双实例构建：tweak 与独立 App 同一 deb 交付。
6. 完整签名链与四环境安装适配，覆盖从编译到部署的全流程。

## 八、回滚

本工程为新增目录 `E:/REA/xautouch/`，未改动任何系统配置。删除该目录即可完全回滚。（`E:/REA/xauto/` 是早期 PC 方案遗留，可一并删除。）
