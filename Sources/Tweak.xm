/**
 * Tweak.xm - XAutouch 注入入口
 *
 * 注入目标：SpringBoard（系统桌面进程）。
 * SpringBoard 拥有处理用户触摸事件的权限，触摸合成在此进程内完成。
 *
 * 稳定性设计（1.0.0-3）：
 *
 *   1. 硬熔断（最重要）：
 *      加载时先在 /var/mobile/Library/Logs/xa-inject-crashed 写标记，
 *      全部初始化**成功走完**才删掉它。所以只要有任何一步崩了，
 *      标记就留在磁盘上；下一次 SpringBoard 启动看到标记直接返回，
 *      **连 hook 都不装**，桌面一定正常。
 *      这一条覆盖了 1.0.0-2 的漏洞：旧版标记在 didFinish 里才写，
 *      如果崩在 %ctor / dylib 构造阶段，熔断代码根本没机会执行，
 *      于是"Exit Safe Mode -> 重新注入 -> 再崩"无限循环。
 *
 *   2. 初始化推迟 1.5s，避开 SpringBoard 启动关键路径。
 *
 *   3. 每一步 @try/@catch，异常写日志而不是让进程崩。
 *
 * 诊断日志：/var/mobile/Library/Logs/xautouch-boot.log
 * 解除熔断：删掉 xa-inject-crashed 后 respring 即可重试。
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

#define XA_LOG_PATH   "/var/mobile/Library/Logs/xautouch-boot.log"
#define XA_CRASH_FLAG "/var/mobile/Library/Logs/xa-inject-crashed"

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

// 返回 YES 表示写成功；写不进去也不阻断注入，只是熔断能力降级
static BOOL XAMarkBooting(void) {
    FILE *f = fopen(XA_CRASH_FLAG, "w");
    if (!f) return NO;
    fputs("booting\n", f);
    fclose(f);
    return YES;
}

%group XAMain

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    XADiag("didFinish: enter");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL allOK = YES;
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
            allOK = NO;
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

        if (allOK) {
            unlink(XA_CRASH_FLAG);
            XADiag("boot: done（熔断标记已清除）");
        } else {
            XADiag("boot: FAILED，保留熔断标记，下次启动不再注入");
        }
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

        // 熔断：上次没走完就返回，连 %init 都不执行。
        // 这样无论崩在加载期、hook 期还是延迟初始化期，桌面都不会再被拖进 Safe Mode。
        if (XAFileExists(XA_CRASH_FLAG)) {
            XADiag("!!! 熔断生效：%s 存在，本次不注入", XA_CRASH_FLAG);
            XADiag("!!! 排查完想重试：删掉该文件后 respring");
            return;
        }

        XAMarkBooting();
        %init(XAMain);
        XADiag("=== ctor exit (hooked) ===");
    } @catch (NSException *e) {
        XADiag("ctor EXC %s | %s",
               e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
    }
}
