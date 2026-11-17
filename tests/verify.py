"""
verify.py - XAutouch 全量设计自检（Windows/任意平台可跑）

不是产品，是校验工具。验证与平台无关的部分是否自洽：
  * deb 元数据 / 维护脚本 / 资源布局 / LaunchDaemon
  * 参照对象 39 条设备端路由 + Web 面板端点覆盖
  * 触摸原语、Lua VM、NCC/OCR、四环境适配的实现证据
  * 构建配置包含全部源文件与 vendored Lua
  * 旧版占位实现已彻底移除

运行： python tests/verify.py
"""
import glob
import os, sys, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources")
passed = failed = 0

def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  [PASS] {name}")
    else:
        failed += 1
        print(f"  [FAIL] {name} {detail}")

def read(rel):
    p = os.path.join(ROOT, rel)
    return open(p, encoding="utf-8", errors="ignore").read() if os.path.isfile(p) else ""

print("== 1. control 元数据 ==")
ctrl = read("control")
for key in ("Package", "Name", "Depends", "Version", "Architecture", "Description"):
    check(f"control 含 {key}", re.search(rf"^{key}:", ctrl, re.M) is not None)
check("架构为 iphoneos-arm64", "iphoneos-arm64" in ctrl)
check("依赖 MobileSubstrate", "mobilesubstrate" in ctrl)
# Replaces 指向包自身会让 apt 解析 deb 时失败（Sileo 报 "Unsupported file"）
_repl = re.search(r"^Replaces:(.*)$", ctrl, re.M)
check("control 的 Replaces 不含包自身",
      _repl is None or "app.xautouch.ios" not in _repl.group(1))
check("提供 deb 重压脚本 tools/repackage_deb.py",
      os.path.isfile(os.path.join(ROOT, "tools", "repackage_deb.py")))
check("CI 在打包后把 data 段重压为 xz",
      "repackage_deb.py" in read(".github/workflows/build.yml"))

print("== 2. deb 布局与维护脚本 ==")
deb = os.path.join(ROOT, "layout", "DEBIAN")
check("DEBIAN/control 存在", os.path.isfile(os.path.join(deb, "control")))
for s in ("preinst", "postinst", "prerm", "postrm"):
    p = os.path.join(deb, s)
    check(f"DEBIAN/{s} 存在且可执行", os.path.isfile(p) and os.access(p, os.X_OK))
prefix = os.path.join(ROOT, "layout", "usr", "lib", "xautouch")
for d in ("web", "lua", "bin"):
    n = len(os.listdir(os.path.join(prefix, d))) if os.path.isdir(os.path.join(prefix, d)) else 0
    check(f"资源 {d} 已就位 ({n} 项)", n > 0)
post = read("layout/DEBIAN/postinst")
for env in ("rootful", "rootless", "roothide", "trollstore"):
    check(f"postinst 适配 {env}", env in post)
check("watchdog 守护脚本存在", os.path.isfile(os.path.join(prefix, "bin", "xautouchd")))
# Theos 打包会拒绝 CRLF 的 control（deb.mk: "control file contains Windows line endings"）。
# Windows 上任何一次文本模式写入都会把 \n 变 \r\n，所以必须用二进制方式校验。
for rel in ("control", "layout/DEBIAN/control", "layout/DEBIAN/preinst",
            "layout/DEBIAN/postinst", "layout/DEBIAN/prerm", "layout/DEBIAN/postrm"):
    p = os.path.join(ROOT, rel)
    raw = open(p, "rb").read() if os.path.isfile(p) else b""
    check(f"{rel} 使用 LF 换行", bool(raw) and b"\r\n" not in raw)
plist = read("layout/Library/LaunchDaemons/app.xautouch.agent.plist")
check("LaunchDaemon 指向 xautouchd", "xautouchd" in plist)
# 1.0.0-2 真机上把环境搞坏的两个根因，必须被断言锁死，回退即红：
#   a) 守护脚本按 engine.log 的 mtime 判断卡死，超时 killall SpringBoard。
#      但全工程只有它自己写这个日志，于是每 10 分钟杀一次桌面。
#   b) 维护脚本在 dpkg 事务内 killall SpringBoard，事务被打断后包停在
#      reinstreq 状态，apt 从此全局报错，连 Sileo 都无法卸载。
watchdog = read("layout/usr/lib/xautouch/bin/xautouchd")
check("watchdog 不 kill SpringBoard", "killall -9 SpringBoard" not in watchdog)
check("watchdog 不按日志 mtime 触发 respring", "engine stale" not in watchdog)
for script in ("preinst", "postinst", "prerm", "postrm"):
    body = read(f"layout/DEBIAN/{script}")
    check(f"{script} 不在事务内杀桌面", "killall -9 SpringBoard" not in body)
# 硬熔断：标记必须在 %ctor 里、%init 之前写，否则崩在加载期时熔断失效
tweak = read("Sources/Tweak.xm")
check("注入前先写崩溃标记", tweak.index("XAMarkBooting()") < tweak.index("%init(XAMain)"))
check("标记存在时直接返回不注入",
      "XAFileExists(XA_CRASH_FLAG)" in tweak and "return;" in tweak)
check("初始化成功才清除标记", "unlink(XA_CRASH_FLAG)" in tweak)
# 面板端口：文档与商业版都是 8080，1.0.0-3 的代码写成 46899，装完照文档打不开。
srcs = [p for p in glob.glob(os.path.join(ROOT, "Sources", "**", "*.*"), recursive=True)
        if p.endswith((".mm", ".h", ".xm", ".m"))]
check("源码内不残留旧端口 46899",
      not any("46899" in open(p, encoding="utf-8", errors="ignore").read() for p in srcs))
check("HTTP 服务默认端口为 8080", "startOnPort:8080" in read("Sources/XTApplication.mm"))
# layout/ 三种 scheme 共用，plist 里的绝对路径只在 rootful 成立；
# rootless 必须在打包前改写成 /var/jb 前缀，否则守护进程起不来。
check("提供按 scheme 改写 launchd 路径的钩子",
      os.path.isfile(os.path.join(ROOT, "tools", "fix_stage_plist.py")))
check("Makefile 在打包前调用该钩子",
      "fix_stage_plist.py" in read("Makefile") and "after-stage::" in read("Makefile"))
check("钩子按 rootless 加 /var/jb 前缀", '"/var/jb"' in read("tools/fix_stage_plist.py"))
check("postinst 优先用 launchctl bootstrap", "launchctl bootstrap system" in post)
check("postinst 签名覆盖 DynamicLibraries 目录",
      "MobileSubstrate/DynamicLibraries/XAutouch.dylib" in post)
check("资源路径与代码一致 (usr/lib/xautouch)",
      "usr/lib/xautouch" in read("Sources/XTApplication.mm") or "/usr/lib/xautouch" in read("Sources/XTApplication.mm"))

print("== 3. Theos 源文件 ==")
needed = ["Tweak.xm", "XTApplication.mm", "XTTouchSynthesizer.mm", "XTHTTPServer.mm",
          "XTRoutes.mm", "XTScriptEngine.mm", "XTCapture.mm", "XTVision.mm", "XTLogger.mm"]
for f in needed:
    p = os.path.join(SRC, f)
    check(f"Sources/{f} 存在且非空", os.path.isfile(p) and os.path.getsize(p) > 500)
mk = read("Makefile")
check("Makefile 引用 XTRoutes.mm", "XTRoutes.mm" in mk)
check("Makefile 编译 vendored Lua", "LUA_SOURCES" in mk and "vendor/lua/src" in mk)
check("Makefile 含 Lua include path", "-Ivendor/lua/src" in mk)
check("Makefile 链接 Vision 框架", "Vision" in mk)
lua_sources = [f for f in os.listdir(os.path.join(ROOT, "vendor", "lua", "src"))
               if f.endswith(".c") and f not in ("lua.c", "luac.c")] if os.path.isdir(os.path.join(ROOT, "vendor", "lua", "src")) else []
check(f"vendored Lua 源码完整 ({len(lua_sources)} 个 .c)", len(lua_sources) >= 30)

print("== 4. 设备端 39 路由 ==")
routes = """
/api/app/register /api/app/state /api/config
/api/file /api/file/ /api/file/copy /api/file/move
/api/key/down /api/key/press /api/key/up
/api/pasteboard/read /api/pasteboard/write
/api/path/jbroot /api/path/jbroot/ /api/path/rootfs /api/path/rootfs/
/api/proc /api/proc-dict/run /api/screen/snapshot
/api/script /api/script/ /api/script/pause /api/script/resume
/api/script/run /api/script/selected /api/script/stop
/api/system/log /api/system/reboot /api/system/respring
/api/touch/down /api/touch/move /api/touch/up /api/touch/tap
/api/touch/drag-curve /api/touch/drag-curve-async
/api/touch/drag-linear /api/touch/drag-linear-async
/api/touch/wheel /api/touch/wheel-async
""".split()
rt = read("Sources/XTRoutes.mm")
for r in routes:
    check(f"设备路由 {r}", f'"{r}"' in rt)

print("== 5. Web 面板端点 ==")
web_eps = """
/deviceinfo /device_auth_info /bind_code
/open_remote_access /close_remote_access /is_remote_access_opened
/restart /uicache /clear_gps /clear_all /halt /reboot2 /respring
/install_deb /get_user_conf /set_user_conf
/file_list /read_file /write_file /encript_file /remove_file /rename_file
/mkdir /rmdir /recycle /launch_script_file /select_script_file /get_selected_script_file
/check_syntax /spawn /api/log/stream /applist /clear_app_data
/get_record_conf /get_volume_action_conf
/api/webrtc/poll /api/webrtc/answer /api/webrtc/ice /api/webrtc/stop
""".split()
all_src = rt + read("Sources/XTHTTPServer.mm")
for r in web_eps:
    check(f"Web 端点 {r}", f'"{r}"' in all_src)

print("== 6. 核心机制实现证据 ==")
touch = read("Sources/XTTouchSynthesizer.mm")
for kw, desc in [("IOHIDEventCreateDigitizerEvent", "IOHID 触摸合成"),
                 ("IOHIDEventCreateKeyboardEvent", "实体按键事件"),
                 ("IOHIDEventCreateScrollWheelEvent", "滚轮事件"),
                 ("startRecording", "录制"), ("playbackEvents", "回放"),
                 ("pasteboardRead", "剪贴板"), ("dragCurveThrough", "曲线拖拽")]:
    check(desc, kw in touch)
check("已移除不存在的 firstResponderPrivate", "firstResponderPrivate" not in touch)

eng = read("Sources/XTScriptEngine.mm")
for kw, desc in [("luaL_newstate", "真实 Lua VM"), ("lua_pcall", "Lua 执行"),
                 ("luaL_loadbuffer", "Lua 编译期语法检查"),
                 ("kXTLib", "xtouch 原生模块表"), ("CCCrypt", "AES 脚本加密"),
                 ("decryptFile", "加密脚本解密执行")]:
    check(desc, kw in eng)
check("已移除逐行解析旧实现", "executeLine:" not in eng and "for (NSString *raw in" not in eng)

vis = read("Sources/XTVision.mm")
for kw, desc in [("cross - tSum*sMean", "NCC 互相关计算"),
                 ("VNRecognizeTextRequest", "Apple Vision OCR"),
                 ("boundingBox", "OCR 文字定位")]:
    check(desc, kw in vis)
check("已移除模板匹配占位", "需接入 NCC" not in vis and "坐标以屏幕中心占位" not in vis and "扩展点" not in vis)

app = read("Sources/XTApplication.mm")
for kw, desc in [("detectEnvironment", "越狱环境检测"),
                 ("installDebAtPath", "deb 安装"), ("clearAppData", "应用数据清理"),
                 ("webrtcPoll", "WebRTC 信令"), ("spawn:", "命令执行")]:
    check(desc, kw in app)

print("== 7. HTTP 网络层 ==")
srv = read("Sources/XTHTTPServer.mm")
for kw, desc in [("Content-Length", "完整 body 读取"),
                 ("multipartParts", "multipart 文件上传"),
                 ("text/event-stream", "SSE 日志流"),
                 ("Sec-WebSocket-Accept", "WebSocket 握手"),
                 ("Access-Control-Allow-Origin", "CORS"),
                 ("rangeOfData", "header 分块解析")]:
    check(desc, kw in srv)
check("Content-Length 按字节计算", "resp.body.length" in srv)

print("== 8. 源码结构静态检查 ==")
headers = ["XTHTTPServer.h", "XTApplication.h", "XTTouchSynthesizer.h",
           "XTScriptEngine.h", "XTVision.h", "XTCapture.h", "XTLogger.h"]
for f in needed + headers:
    text = read(f"Sources/{f}")
    stripped = re.sub(r'@?"(?:\\.|[^"\\])*"', '', text)
    stripped = re.sub(r'/\*.*?\*/', '', stripped, flags=re.S)
    stripped = re.sub(r'//[^\n]*', '', stripped)
    delta = stripped.count('{') - stripped.count('}')
    check(f"{f} 大括号平衡", delta == 0, f"delta={delta}")
    n_iface = len(re.findall(r'@interface\b', stripped))
    n_impl = len(re.findall(r'@implementation\b', stripped))
    n_proto = len(re.findall(r'@protocol\b', stripped))
    n_end = len(re.findall(r'@end\b', stripped))
    check(f"{f} @interface/@protocol/@implementation/@end 配对",
          n_iface + n_impl + n_proto == n_end,
          f"{n_iface}+{n_impl}+{n_proto} != {n_end}")

print("== 9. 商业产品全功能对齐模块 ==")

# 9.1 独立文件管理器 App（对标 XXTExplorer.app）
app_dir = os.path.join(SRC, "XXTExplorer")
for f in ("main.m", "XTEAppDelegate.h", "XTEAppDelegate.mm", "XTEAPIClient.h",
          "XTEAPIClient.mm", "XTEFileListController.h", "XTEFileListController.mm",
          "XTEFileEditorController.h", "XTEFileEditorController.mm", "Info.plist"):
    p = os.path.join(app_dir, f)
    check(f"XXTExplorer/{f} 存在且非空", os.path.isfile(p) and os.path.getsize(p) > 100)
api = read("Sources/XXTExplorer/XTEAPIClient.mm")
for kw, desc in [("file_list", "App 列目录 API"), ("write_file", "App 写文件"),
                 ("launch_script_file", "App 运行脚本"), ("check_syntax", "App 语法检查"),
                 ("NSURLSession", "App 网络层")]:
    check(desc, kw in api)
flc = read("Sources/XXTExplorer/XTEFileListController.mm")
for kw, desc in [("UISearchController", "App 搜索"), ("sort", "App 排序"),
                 ("长按", "App 长按菜单"), ("UITableView", "App 列表")]:
    check(desc, kw in flc)
check("Makefile 构建 App target", "APPLICATION_NAME = XXTExplorer" in mk and "application.mk" in mk)
check("Makefile 声明 Info.plist 资源", "XXTExplorer_RESOURCE_FILES" in mk and "Info.plist" in mk)
check("Makefile 用 aggregate.mk 聚合双实例", "aggregate.mk" in mk)
check("Makefile 设置 iOS 12 最低版本", "TARGET = iphone:clang:latest:12.0" in mk)

# 9.2 WebRTC 媒体传输（对标原版远程控制）
media_h = read("Sources/XTWebRTCMedia.h")
media = read("Sources/XTWebRTCMedia.mm")
for kw, desc in [("startSessionWithConfig", "媒体会话接口"), ("sessionStats", "媒体统计"),
                 ("handleRemoteMessage", "媒体信令处理")]:
    check(desc, kw in media_h)
for kw, desc in [("VTCompressionSessionCreate", "VideoToolbox H.264 编码"),
                 ("CVPixelBufferCreate", "像素缓冲"), ("sendto", "UDP 发送"),
                 ("AVAudioEngine", "音频采集"), ("kVTCompressionPropertyKey_ProfileLevel", "编码规格")]:
    check(desc, kw in media)
check("媒体层已接线到 XTApplication", "XTWebRTCMedia" in app)
check("媒体路由存在", "/api/webrtc/stats" in rt and "/api/webrtc/start" in rt)

# 9.3 多视觉引擎（对标 ONNX/ncnn/Tesseract/OpenCV 四引擎）
veh = read("Sources/XTVisionEngine.h")
ver = read("Sources/XTVisionEngineRegistry.mm")
check("视觉引擎协议定义", "@protocol XTVisionEngine" in veh)
for kw, desc in [("registerBuiltInEngines", "引擎注册入口"),
                 ("fallbackOrder", "降级顺序"), ("@try", "异常隔离")]:
    check(desc, kw in ver)
for engine, kw, desc in [
        ("XTONNXEngine.mm", "libonnxruntime", "ONNX Runtime dlsym 探测"),
        ("XTNCNNEngine.mm", "libncnn", "ncnn dlsym 探测"),
        ("XTTesseractEngine.mm", "TessBaseAPICreate", "Tesseract C API 探测")]:
    src_e = read("Sources/" + engine)
    check(desc, kw in src_e and "dlsym" in src_e)
vis_new = read("Sources/XTVision.mm")
check("视觉门面接入引擎注册表", "XTVisionEngineRegistry" in vis_new and "engineStatuses" in vis_new)
check("引擎切换路由存在", "/api/vision/engine" in rt and "/api/vision/engines" in rt)
check("Makefile 编译全部视觉引擎",
      all(x in mk for x in ("XTVisionEngineRegistry.mm", "XTONNXEngine.mm",
                            "XTNCNNEngine.mm", "XTTesseractEngine.mm")))

# 9.4 完整签名链（对标 fastPathSign）
sign_h = read("Sources/XTCodeSigner.h")
sign = read("Sources/XTCodeSigner.mm")
for kw, desc in [("signFileAtPath", "单文件签名接口"), ("verifyFileAtPath", "签名校验"),
                 ("resignBundleAtPath", "bundle 重签名"), ("defaultEntitlementsXML", "权限生成")]:
    check(desc, kw in sign_h)
for kw, desc in [("NSTask", "外部工具调用"), ("codesign", "codesign 路径"),
                 ("ldid", "ldid 回退路径"), ("get-task-allow", "调试权限"),
                 ("task_for_pid-allow", "进程注入权限"), ("subpathsOfDirectoryAtPath", "Mach-O 遍历")]:
    check(desc, kw in sign)
check("签名工具脚本存在", os.path.isfile(os.path.join(deb, "sign-tools.sh")))
check("postinst 接入签名工具", "sign-tools" in post)
check("签名路由存在", all(x in rt for x in ("/api/system/sign", "/api/system/verify",
                                            "/api/system/resign", "/api/system/sign-status")))

# 9.5 UI 服务 / 自更新（对标 uiservice-* 系列）
ui_h = read("Sources/XTUIService.h")
ui = read("Sources/XTUIService.mm")
for kw, desc in [("showToast", "Toast 提示"), ("showPoseAtX", "触点可视化"),
                 ("showFloatingView", "悬浮窗"), ("showAlertTitle", "弹窗服务"),
                 ("handleVolumeKey", "音量键动作"), ("triggerUpdateCheckWithCompletion", "自更新检查")]:
    check(desc, kw in ui_h)
check("Toast 用覆盖 window", "UIWindow" in ui)
check("自更新访问 xxtouch.app", "xxtouch.app/api/latest-version" in ui)
check("UI 路由存在", all(x in rt for x in ("/api/ui/toast", "/api/ui/pose",
                                           "/api/ui/floating", "/api/ui/alert",
                                           "/api/system/check-update")))
check("Tweak 已接音量键 hook", "volume" in read("Sources/Tweak.xm").lower())

# 9.6 UDP / 云控 / 屏幕共享（对标 udpd/cloud/screen）
for f, kws in [
    ("XTUDPControl.mm", ["dispatch_source", "sendto", "recvfrom", "executeCommand:"]),
    ("XTCloudControl.mm", ["NSURLSessionWebSocketTask", "connectToServer", "heartbeat"]),
    ("XTScreenShare.mm", ["UIImageJPEGRepresentation", "nextJPEGFrameWithTimeout"]),
]:
    s = read("Sources/" + f)
    for kw in kws:
        check(f"{f} 含 {kw}", kw in s)
check("网络服务路由存在", all(x in rt for x in ("/api/udp/start", "/api/udp/token",
                                                "/api/cloud/connect", "/api/screen/stream/start",
                                                "/api/screen/stream/frame")))
srv2 = read("Sources/XTHTTPServer.mm")
check("MJPEG 长连接端点实现", "/api/screen/stream" in srv2 and "multipart/x-mixed-replace" in srv2)
check("云控参数对齐 server 字段", '"server"' in rt)
check("UI alert 事件名对齐", "ui_alert_choice" in rt)
check("Tweak 启动 UDP 服务", "udpStart" in read("Sources/Tweak.xm"))

print("== 10. 原版 Web 面板端点全量覆盖 ==")
orig_web = """/api/log/stream /api/webrtc/answer /api/webrtc/ice /api/webrtc/poll /api/webrtc/stop
/bind_code /check_syntax /clear_app_data /close_remote_access /daemon_spawn /device_auth_info
/deviceinfo /encript_file /get_record_conf /get_selected_script_file /get_startup_conf
/get_user_conf /get_volume_action_conf /is_remote_access_opened /launch_script_file /mkdir
/open_remote_access /read_file /recycle /remove_file /rename_file /restart /rmdir
/select_script_file /set_user_conf /spawn /write_file
/set_startup_run_on /set_startup_run_off /select_startup_script_file""".split()
all_rt = read("Sources/XTRoutes.mm") + read("Sources/XTHTTPServer.mm")
for e in orig_web:
    check(f"原版面板端点 {e}", f'"{e}"' in all_rt)
check("file_list 兼容原版 data.list", "list" in rt and "change" in rt)
check("control 去掉未用的 preferenceloader", "preferenceloader" not in ctrl)

print("== 11. 本地头文件与跨平台编译隐患 ==")
import re as _re
_incdirs = ["Sources", "vendor/lua/src", "include"]
_missing = []
_crossfile = []
for _dp, _dn, _fn in os.walk(SRC):
    for _f in _fn:
        if not _f.endswith((".m", ".mm", ".h", ".xm")):
            continue
        _p = os.path.join(_dp, _f)
        for _i, _line in enumerate(open(_p, encoding="utf-8", errors="ignore"), 1):
            _m = _re.match(r'\s*#(?:import|include)\s+"([^"]+)"', _line)
            if not _m:
                continue
            _h = _m.group(1)
            _cands = [os.path.join(_dp, _h)] + [os.path.join(d, _h) for d in _incdirs]
            if not any(os.path.isfile(c) for c in _cands):
                _missing.append(f"{os.path.relpath(_p, ROOT)}:{_i} -> {_h}")
            # 形如 "XTVisionEngineRegistry.h" 但实际只有 .mm 的跨文件头误引用
            if _h.endswith(".h") and not any(os.path.isfile(c) for c in _cands):
                _crossfile.append(_h)
check("所有本地 #import 目标文件存在", not _missing)
for _m in _missing:
    print(f"    [缺失] {_m}")

# iOS 不可用 API 与版本敏感 API 必须做运行时判断
_code_lines = []
for _dp, _dn, _fn in os.walk(SRC):
    for _f in _fn:
        if not _f.endswith((".mm", ".m")):
            continue
        for _line in open(os.path.join(_dp, _f), encoding="utf-8", errors="ignore"):
            _s = _line.strip()
            if _s.startswith("//") or _s.startswith("*") or _s.startswith("/*"):
                continue
            _code_lines.append(_s)
_code = "\n".join(_code_lines)
check("未使用 iOS 上不可用的 system()", _re.search(r"[^a-zA-Z_]system\s*\(", _code) is None)
check("进程调用改用 posix_spawn", "posix_spawn" in read("Sources/XTApplication.mm"))
check("Vision OCR 有 @available 版本保护",
      "@available(iOS 13.0" in read("Sources/XTVision.mm"))
check("Makefile 限定 64 位架构", "ARCHS" in read("Makefile") and "arm64" in read("Makefile"))

# Objective-C++ 下裸 typeof() 不可用，必须写 __typeof__()
_ocpp = "".join(read(os.path.relpath(os.path.join(dp, f), ROOT))
                for dp, _, fs in os.walk(SRC) for f in fs if f.endswith((".mm", ".m")))
check("未使用 Objective-C++ 不兼容的裸 typeof()",
      _re.search(r"(?<!__)\btypeof\s*\(", _ocpp) is None)
# void* 不能隐式转成具体指针（C++ 严格模式）
check("NSData bytes 赋值均显式转型",
      _re.search(r"^\s*(const\s+)?(unsigned\s+)?(char|uint8_t|uint16_t|uint32_t)\s*\*\s*\w+\s*=\s*[^;()]*\.(mutable)?[Bb]ytes\s*;",
                 _ocpp, _re.M) is None)
check("NSData bytes 赋值语句均显式转型",
      _re.search(r"^\s*\w+\.(data|buf)\s*=\s*[^;()]*\.bytes\s*;", _ocpp, _re.M) is None)
check("签名器未重复定义系统类 NSPipe",
      "@interface NSPipe" not in read("Sources/XTCodeSigner.mm"))
check("Lua os.execute 走 iOS 垫片", "-Dl_system=xt_system" in read("Makefile")
      and os.path.isfile(os.path.join(SRC, "XTPosixSystem.c")))
check("C++ 参数放在 _CCFLAGS", "_CCFLAGS" in read("Makefile")
      and "-std=c++17" not in [x for x in read("Makefile").split("\n")
                               if x.startswith("XAutouch_CFLAGS")][0])
# Theos 打包 tweak 时从「工程根目录」找注入过滤 plist（XAutouch.plist / Filter.plist），
# 缺失会让 stage 阶段直接失败。
_filter = os.path.join(ROOT, "XAutouch.plist")
check("MobileSubstrate 过滤 plist 在工程根目录", os.path.isfile(_filter))
check("过滤 plist 注入 SpringBoard",
      os.path.isfile(_filter) and "com.apple.springboard" in open(_filter, encoding="utf-8").read())
check("垫片源码在 _FILES 参与编译", "XTPosixSystem.c" in read("Makefile"))

print(f"\n结果: {passed} PASS, {failed} FAIL")
sys.exit(1 if failed else 0)
