# 功能细节总表（源码生成，勿手改）

> 本文件由 `tools/gen_features.py` 扫描源码生成，内容与代码同步。改完源码后重跑：
> `python tools/gen_features.py`；CI 用 `--check` 校验是否过期。

## 0. 一眼概览

| 指标 | 数值 |
|---|---|
| 源文件（源码 + 头文件） | 46 个 / 10017 行 |
| 原版端点（路由 + 面板） | 83 条，已实现 83 条，缺失 **0** |
| 本工程新增端点 | 39 条（补充工程完整性，原版无） |
| 端点总计 | 122 条 = `/api/*` 路由 79 + 面板端点 43 |
| Lua 原生函数 `xtouch.*` | 19 个 |
| 随包资源 | 275 文件 / 11.7 MB |

口径说明：**原版对齐**＝商业 XXTouch 1.3.8 里存在同名端点（基线来自 `tests/audit.py`，
39 条设备端路由 + 44 条面板端点，去重 83 条）；**本工程新增**＝原版没有、为工程完整性补的。
判定用两份清单的并集，避免 `/api/webrtc/*` 这类「清单归在面板、实际走路由」的重复计数。

## 1. 模块清单（按规模排序）

| 文件 | 行数 | 功能域 | 职责 |
|---|---|---|---|
| `Sources/XTWebRTCMedia.mm` | 913 | 媒体传输 | 自包含屏幕/音频实时传输层 |
| `Sources/XTONNXEngine.mm` | 768 | 视觉 / OCR | ONNX Runtime 适配器（dlsym 运行时加载） |
| `Sources/XTCodeSigner.mm` | 658 | 签名链 | 代码签名 / 重签名完整实现 |
| `Sources/XTUIService.mm` | 632 | UI 服务 | UI 服务与配套控制（SpringBoard 进程内） |
| `Sources/XXTExplorer/XTEFileListController.mm` | 577 | 文件管理器 App | 文件浏览器实现 |
| `Sources/XTHTTPServer.mm` | 529 | HTTP 控制面 · 网络层 | 本地 HTTP/1.1 控制服务（网络层） |
| `Sources/XTApplication.mm` | 511 | 应用与生命周期 | 单例协调器：环境适配、设备信息、授权、系统控制、WebRTC 信令 |
| `Sources/XTCloudControl.mm` | 510 | 云控 | 开放式云控客户端实现 |
| `Sources/XTRoutes.mm` | 489 | HTTP 控制面 · 路由分发 | XTHTTPServer 路由实现 |
| `Sources/XTScriptEngine.mm` | 467 | Lua 脚本引擎 | 真实 Lua 5.4 VM + xtouch 原生桥接 + 脚本加解密 |
| `Sources/XTUDPControl.mm` | 458 | 远程控制 | UDP 控制服务实现 |
| `Sources/XTTouchSynthesizer.mm` | 381 | 触摸合成 | 系统级触摸合成（完整实现） |
| `Sources/XXTExplorer/XTEAPIClient.mm` | 361 | 文件管理器 App | 本地 HTTP API 封装实现 |
| `Sources/XTScreenShare.mm` | 331 | 其他 | 屏幕共享实现 |
| `Sources/XTNCNNEngine.mm` | 261 | 视觉 / OCR | ncnn 适配器（dlsym 运行时加载） |
| `Sources/XTTesseractEngine.mm` | 252 | 视觉 / OCR | Tesseract 适配器（dlsym 运行时加载） |
| `Sources/XTVisionEngineRegistry.mm` | 249 | 视觉 / OCR | 视觉引擎注册表 |
| `Sources/XTVision.mm` | 243 | 视觉 / OCR | 图像模板匹配（NCC）与 OCR 触发（Apple Vision） |
| `Sources/XXTExplorer/XTEFileEditorController.mm` | 233 | 文件管理器 App | 编辑器实现 |
| `Sources/Tweak.xm` | 147 | 注入入口 | XAutouch 注入入口 |
| `Sources/XTApplication.h` | 95 | 应用与生命周期 | — |
| `Sources/XTVisionEngine.h` | 87 | 视觉 / OCR | 可插拔视觉引擎协议与注册表 |
| `Sources/XTCodeSigner.h` | 76 | 签名链 | 代码签名 / 重签名子系统 |
| `Sources/XTUIService.h` | 65 | UI 服务 | XTUIService - SpringBoard 内显示的 UI 服务与配套控制能力 |
| `Sources/XXTExplorer/XTEAPIClient.h` | 60 | 文件管理器 App | 本地 HTTP API 封装 |
| `Sources/XTHTTPServer.h` | 55 | HTTP 控制面 · 网络层 | 完整的 HTTP 请求（支持 query string、form、JSON、multipart 文件上传） |
| `Sources/XTUDPControl.h` | 54 | 远程控制 | UDP 控制服务 |
| `Sources/XTLogger.mm` | 51 | 日志 | — |
| `Sources/XTCapture.mm` | 50 | 其他 | SpringBoard 进程内通过UIScreen 私有 API 抓取，保存 PNG 到沙盒目录。 |
| `Sources/XXTExplorer/XTEAppDelegate.mm` | 46 | 文件管理器 App | 应用启动流程 |
| `Sources/XTWebRTCMedia.h` | 42 | 媒体传输 | 自包含屏幕/音频实时传输层 |
| `Sources/XTCloudControl.h` | 39 | 云控 | 开放式云控客户端 |
| `Sources/XTTouchSynthesizer.h` | 39 | 触摸合成 | — |
| `Sources/XTScriptEngine.h` | 36 | Lua 脚本引擎 | — |
| `Sources/XTPosixSystem.c` | 35 | 平台垫片 | iOS 上的 shell 执行垫片 |
| `Sources/XTONNXEngine.h` | 30 | 视觉 / OCR | ONNX Runtime 视觉适配器 |
| `Sources/XTScreenShare.h` | 30 | 其他 | 屏幕共享 / MJPEG 取帧 |
| `Sources/XTNCNNEngine.h` | 27 | 视觉 / OCR | ncnn 视觉适配器 |
| `Sources/XTTesseractEngine.h` | 25 | 视觉 / OCR | Tesseract OCR 适配器 |
| `Sources/XTVision.h` | 23 | 视觉 / OCR | 视觉门面：内置 Apple Vision OCR + NCC 模板匹配，并作为可插拔引擎架构的默认实现。 |
| `Sources/XTPosixSystem.h` | 21 | 平台垫片 | iOS shell 执行垫片 |
| `Sources/XXTExplorer/XTEFileListController.h` | 18 | 文件管理器 App | 文件浏览器主界面 |
| `Sources/XXTExplorer/XTEAppDelegate.h` | 14 | 文件管理器 App | 应用生命周期与根界面容器 |
| `Sources/XXTExplorer/XTEFileEditorController.h` | 13 | 文件管理器 App | 脚本/文本文件编辑器与图片预览器 |
| `Sources/XTLogger.h` | 9 | 日志 | — |
| `Sources/XTCapture.h` | 7 | 其他 | — |

## 2. 设备端 HTTP 路由

共 79 条，全部在 `Sources/XTRoutes.mm` 分发。

### 2.1 原版对齐（44）

**app**（2）：`/api/app/register` `/api/app/state`

**config**（1）：`/api/config`

**file**（4）：`/api/file` `/api/file/` `/api/file/copy` `/api/file/move`

**key**（3）：`/api/key/down` `/api/key/press` `/api/key/up`

**log**（1）：`/api/log/stream`

**pasteboard**（2）：`/api/pasteboard/read` `/api/pasteboard/write`

**path**（4）：`/api/path/jbroot` `/api/path/jbroot/` `/api/path/rootfs` `/api/path/rootfs/`

**proc**（1）：`/api/proc`

**proc-dict**（1）：`/api/proc-dict/run`

**screen**（1）：`/api/screen/snapshot`

**script**（7）：`/api/script` `/api/script/` `/api/script/pause` `/api/script/resume` `/api/script/run` `/api/script/selected` `/api/script/stop`

**system**（3）：`/api/system/log` `/api/system/reboot` `/api/system/respring`

**touch**（10）：`/api/touch/down` `/api/touch/drag-curve` `/api/touch/drag-curve-async` `/api/touch/drag-linear` `/api/touch/drag-linear-async` `/api/touch/move` `/api/touch/tap` `/api/touch/up` `/api/touch/wheel` `/api/touch/wheel-async`

**webrtc**（4）：`/api/webrtc/answer` `/api/webrtc/ice` `/api/webrtc/poll` `/api/webrtc/stop`

### 2.2 本工程新增（35）

**cloud**（4）：`/api/cloud/config` `/api/cloud/connect` `/api/cloud/disconnect` `/api/cloud/status`

**record**（3）：`/api/record/play` `/api/record/start` `/api/record/stop`

**screen**（5）：`/api/screen/stream` `/api/screen/stream/frame` `/api/screen/stream/start` `/api/screen/stream/stats` `/api/screen/stream/stop`

**script**（1）：`/api/script/validate`

**system**（5）：`/api/system/check-update` `/api/system/resign` `/api/system/sign` `/api/system/sign-status` `/api/system/verify`

**text**（1）：`/api/text/input`

**udp**（4）：`/api/udp/start` `/api/udp/stats` `/api/udp/stop` `/api/udp/token`

**ui**（4）：`/api/ui/alert` `/api/ui/floating` `/api/ui/pose` `/api/ui/toast`

**vision**（4）：`/api/vision/engine` `/api/vision/engines` `/api/vision/ocr` `/api/vision/template`

**volume**（2）：`/api/volume/action` `/api/volume/bind`

**webrtc**（2）：`/api/webrtc/start` `/api/webrtc/stats`

## 3. Web 面板端点

共 43 个，供内置 Web 面板与第三方脚本调用。

**原版对齐（39）**：`/applist` `/bind_code` `/check_syntax` `/clear_all` `/clear_app_data` `/clear_gps` `/close_remote_access` `/daemon_spawn` `/device_auth_info` `/deviceinfo` `/encript_file` `/file_list` `/get_record_conf` `/get_selected_script_file` `/get_startup_conf` `/get_user_conf` `/get_volume_action_conf` `/halt` `/install_deb` `/is_remote_access_opened` `/launch_script_file` `/mkdir` `/open_remote_access` `/read_file` `/reboot2` `/recycle` `/remove_file` `/rename_file` `/respring` `/restart` `/rmdir` `/select_script_file` `/select_startup_script_file` `/set_startup_run_off` `/set_startup_run_on` `/set_user_conf` `/spawn` `/uicache` `/write_file`

**本工程新增（4）**：`/down` `/log` `/ocr` `/reboot`

## 4. Lua 原生函数

共 19 个，注册在 `Sources/XTScriptEngine.mm` 的 `xtouch` 表。

| 函数 | 函数 | 函数 | 函数 |
|---|---|---|---|
| `xtouch.curve` | `xtouch.down` | `xtouch.findImage` | `xtouch.input` |
| `xtouch.key` | `xtouch.log` | `xtouch.move` | `xtouch.ocr` |
| `xtouch.pasteboard_read` | `xtouch.pasteboard_write` | `xtouch.playback` | `xtouch.record_start` |
| `xtouch.record_stop` | `xtouch.sleep` | `xtouch.snapshot` | `xtouch.swipe` |
| `xtouch.tap` | `xtouch.up` | `xtouch.wheel` |  |

## 5. 随包资源

| 目录 | 文件数 | 体积 |
|---|---|---|
| `layout/usr/lib/xautouch/bin/` | 28 | 0.70 MB |
| `layout/usr/lib/xautouch/bundles/` | 12 | 0.01 MB |
| `layout/usr/lib/xautouch/lua/` | 119 | 1.48 MB |
| `layout/usr/lib/xautouch/models/` | 5 | 3.21 MB |
| `layout/usr/lib/xautouch/tessdata/` | 1 | 2.97 MB |
| `layout/usr/lib/xautouch/web/` | 110 | 3.28 MB |

## 6. 安装适配

| 文件 | 字节 | 类型 |
|---|---|---|
| `layout/DEBIAN/control` | 457 | 元数据 |
| `layout/DEBIAN/postinst` | 5454 | 维护脚本 |
| `layout/DEBIAN/postrm` | 746 | 维护脚本 |
| `layout/DEBIAN/preinst` | 1139 | 维护脚本 |
| `layout/DEBIAN/prerm` | 348 | 维护脚本 |
| `layout/DEBIAN/sign-tools.sh` | 10623 | 维护脚本 |

支持的越狱环境：rootful / rootless（`/var/jb`）/ roothide / TrollStore，
分支判断在 `layout/DEBIAN/postinst`；CI 三种 scheme 分别打包。

## 7. 与商业版的已知差异（如实标注）

| # | 项 | 现状 | 影响 |
|---|---|---|---|
| 1 | WebRTC 实时媒体 | 不自带 libwebrtc；用 VideoToolbox H.264 + 自定义帧协议 + 简化 JSON 信令 | 功能等价，但 SDP/ICE 不与标准 WebRTC 客户端互通，需用自带面板对接 |
| 2 | 推理运行时 | `onnxruntime` / `ncnn` **不随包**，运行时 `dlsym` 探测设备现成库 | 设备无库时 `.nb` 模型跑不了，自动回退系统 Vision / 内置 NCC，精度下降 |
| 3 | App UI 资源 | 无 `Assets.car` / nib / 主题包，UI 全用 UIKit 代码构建 | 观感与原版有差，功能不缺 |
| 4 | 签名链 | `TEAMID` 为占位 + ad-hoc 签名；`codesign`/`ldid` 双路替代原版 `fastPathSign` | 真机分发前需换成自己的开发者证书 |
| 5 | 原生 Lua 层 | 19 个 `xtouch.*` 覆盖文档核心 API | 原版 `.so` 的完整导出符号表未逐一比对；Lua 层功能因随包 256 个脚本文件一致而天然对齐 |
| 6 | 运行时验证 | CI 只保证编译成功 + 包结构正确 | 触摸合成、OCR、UI 服务的真机行为仍需在越狱设备上逐项验证 |

## 8. 怎么验证这份表是真的

```bash
python tests/verify.py                        # 静态自检（结构/语法/回归断言）
python tests/audit.py                         # 与商业 XXTouch 的 161 项逐项对拍
python tools/check_deb.py out/debs/*.deb      # 解开 deb 校验 payload 与 control
python tools/gen_features.py --check          # 校验本文件是否与源码同步
```

