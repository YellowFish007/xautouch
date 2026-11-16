# XAutouch - iOS 触摸自动化与脚本控制平台 (Theos / Logos 工程)
# 构建环境：macOS + Theos + iOS SDK
# 目标：iphoneos-arm64，兼容 rootful / rootless / roothide / TrollStore
#
# 本 Makefile 使用 aggregate.mk 同时构建两个实例：
#   1) tweak  XAutouch.dylib  —— 注入 SpringBoard 的自动化引擎
#   2) app    XXTExplorer.app —— 独立的等价文件管理器

# Theos 默认追加 -Werror（common.mk 中 GO_EASY_ON_ME 未设置时），
# 会让任意 warning（unused-variable 等）直接中断编译。
# 本项目仍需真实的三方/私有 API 适配，故关闭 warnings-as-errors，
# 但保留 -Wall，告警照常输出，便于逐项清理。
# 注意：必须在 include common.mk 之前定义。
GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

# 与 control 的 firmware >= 12.0 对齐，避免可用性告警触发 -Werror
TARGET = iphone:clang:latest:12.0
# iOS 12+ 全为 64 位；限定架构避免 armv7 上私有头文件与 IOKit 头文件报错
ARCHS = arm64 arm64e

# ---------------------------------------------------------------- 实例 1：tweak
TWEAK_NAME = XAutouch

# Lua 5.4 源码随工程 vendor，排除带 main() 的 lua.c / luac.c
LUA_SOURCES := $(filter-out vendor/lua/src/lua.c vendor/lua/src/luac.c,$(wildcard vendor/lua/src/*.c))

XAutouch_FILES = Sources/Tweak.xm \
                 Sources/XTApplication.mm \
                 Sources/XTTouchSynthesizer.mm \
                 Sources/XTHTTPServer.mm \
                 Sources/XTRoutes.mm \
                 Sources/XTScriptEngine.mm \
                 Sources/XTCapture.mm \
                 Sources/XTVision.mm \
                 Sources/XTVisionEngineRegistry.mm \
                 Sources/XTONNXEngine.mm \
                 Sources/XTNCNNEngine.mm \
                 Sources/XTTesseractEngine.mm \
                 Sources/XTWebRTCMedia.mm \
                 Sources/XTCodeSigner.mm \
                 Sources/XTUIService.mm \
                 Sources/XTUDPControl.mm \
                 Sources/XTCloudControl.mm \
                 Sources/XTScreenShare.mm \
                 Sources/XTLogger.mm \
                 Sources/XTPosixSystem.c \
                 $(LUA_SOURCES)

XAutouch_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore IOKit Vision \
                      VideoToolbox CoreMedia CoreVideo AVFoundation AudioToolbox ImageIO
XAutouch_PRIVATE_FRAMEWORKS = BackBoardServices SpringBoardServices GraphicsServices
XAutouch_CFLAGS = -fobjc-arc -Ivendor/lua/src -Wno-unused-parameter -Wno-objc-method-access -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Wno-comment -Dl_system=xt_system
# -std=c++17 / -fno-modules 只对 C++/ObjC++ 生效；若放进 _CFLAGS 会让随工程编译的
# Lua 5.4 纯 C 源码报 "invalid argument '-std=c++17' not allowed with 'C'"。
XAutouch_CCFLAGS = -std=c++17 -fno-modules
# Lua 源码已在 _FILES 中参与编译，LDFLAGS 不能再列一次（会重复符号）
XAutouch_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------------------------------------------------------------- 实例 2：文件管理器 App
APPLICATION_NAME = XXTExplorer

XXTExplorer_FILES = Sources/XXTExplorer/main.m \
                    Sources/XXTExplorer/XTEAppDelegate.mm \
                    Sources/XXTExplorer/XTEAPIClient.mm \
                    Sources/XXTExplorer/XTEFileListController.mm \
                    Sources/XXTExplorer/XTEFileEditorController.mm
XXTExplorer_FRAMEWORKS = Foundation UIKit CoreGraphics
XXTExplorer_CFLAGS = -fobjc-arc -Wno-unused-parameter
# main.m 是纯 ObjC/C，不能带 -std=c++17；C++ 参数只给 .mm
XXTExplorer_CCFLAGS = -std=c++17 -fno-modules
# 声明为资源随应用打包（阶段 1 编译期不拷贝，阶段 2 打包时嵌入 .app）
XXTExplorer_RESOURCE_FILES = Sources/XXTExplorer/Info.plist
XXTExplorer_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# ---------------------------------------------------------------- 聚合与安装后动作
after-install::
	install.exec "killall -9 SpringBoard || true"

include $(THEOS)/makefiles/aggregate.mk
