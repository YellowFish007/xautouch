/**
 * Tweak.xm - XAutouch 注入入口
 *
 * 注入目标：SpringBoard（系统桌面进程）。
 * SpringBoard 拥有处理用户触摸事件的权限，触摸合成在此进程内完成。
 *
 * 稳定性设计（1.0.0-2）：
 * 1. 初始化推迟到 didFinish 之后 1.5s，避开 SpringBoard 启动关键路径；
 * 2. 每一步用 @try/@catch 包住，异常写日志而不是让进程崩；
 * 3. 启动前写 flag、走完才删；若上次停在半路，本次不注入，避免无限 Safe Mode；
 * 4. 不再 hook -dealloc（在 dealloc 里创建单例风险高、收益低）。
 *
 * 诊断日志：/var/mobile/Library/Logs/xautouch-boot.log
 * 强制重试：删掉上面这个日志文件后 respring 即可。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "XTApplication.h"
#import "XTLogger.h"
#import "XTUDPControl.h"
#import "XTCloudControl.h"
#import <stdio.h>
#import <stdarg.h>
#import <unistd.h>
#import <sys/stat.h>

#define XA_LOG_PATH  "/var/mobile/Library/Logs/xautouch-boot.log"
#define XA_FLAG_PATH "/var/mobile/Library/Logs/xa-booting"

// 直接写文件，不依赖 ObjC 单例与日志类，ctor 最早期也能用
static void XADiag(const char *fmt, ...) {
    FILE *f = fopen(XA_LOG_PATH, "a");
    if (!f) f = fopen("/tmp/xautouch-boot.log", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fflush(f);
    fclose(f);
}

static BOOL XAFileExists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

// flag 还在 = 上次启动没走完，中途崩了。清掉让下一次启动能重试。
static BOOL XAPreviousBootCrashed(void) {
    if (!XAFileExists(XA_FLAG_PATH)) return NO;
    unlink(XA_FLAG_PATH);
    return YES;
}

%group XAMain

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    XADiag("didFinish: enter");
    FILE *flag = fopen(XA_FLAG_PATH, "w");
    if (flag) fclose(flag);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XADiag("boot: begin");

        @try {
            for (NSString *root in @[@"/var/jb/usr/lib/xautouch", @"/usr/lib/xautouch"]) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:root]) {
                    [[XTApplication sharedInstance] setResourceRoot:root];
                    XADiag("boot: root=%s", root.UTF8String);
                    break;
                }
            }
            XADiag("boot: XTApplication start");
            [[XTApplication sharedInstance] start];
            XADiag("boot: XTApplication ok");
        } @catch (NSException *e) {
            XADiag("boot: start EXC %s | %s",
                   e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
        }

        @try {
            [[XTApplication sharedInstance] udpStart:46900];
            XADiag("boot: udp ok");
        } @catch (NSException *e) {
            XADiag("boot: udp EXC %s", e.reason.UTF8String ?: "?");
        }

        @try {
            [[XTCloudControl sharedInstance] startAutoConnectIfNeeded];
            XADiag("boot: cloud ok");
        } @catch (NSException *e) {
            XADiag("boot: cloud EXC %s", e.reason.UTF8String ?: "?");
        }

        unlink(XA_FLAG_PATH);
        XADiag("boot: done");
    });
}

// 音量键动作绑定（对标 uiservice-volume-key-control-service.lua）。
// 运行时若 SpringBoard 无此方法则不会命中，不影响其他功能。
- (void)_volumeDownKeyDown:(id)sender {
    %orig;
    @try {
        [[XTApplication sharedInstance] handleVolumeKey:@"volume_down"];
    } @catch (NSException *e) {
        XADiag("vol down EXC %s", e.reason.UTF8String ?: "?");
    }
}

- (void)_volumeUpKeyDown:(id)sender {
    %orig;
    @try {
        [[XTApplication sharedInstance] handleVolumeKey:@"volume_up"];
    } @catch (NSException *e) {
        XADiag("vol up EXC %s", e.reason.UTF8String ?: "?");
    }
}

%end

%end  // %group XAMain

%ctor {
    @try {
        XADiag("=== ctor enter (bundle=%s) ===",
               NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "?");

        if (XAPreviousBootCrashed()) {
            XADiag("!!! 上次启动中途崩溃，本次跳过注入，SpringBoard 保持正常");
            XADiag("!!! 删掉 %s 后 respring 可重试", XA_LOG_PATH);
            return;
        }

        %init(XAMain);
        XADiag("=== ctor exit (hooked) ===");
    } @catch (NSException *e) {
        XADiag("ctor EXC %s | %s",
               e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
    }
}
