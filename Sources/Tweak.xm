/**
 * Tweak.xm - XAutouch 注入入口
 *
 * 注入目标：SpringBoard（系统桌面进程）。
 * SpringBoard 拥有处理用户触摸事件的权限，触摸合成在此进程内完成。
 * 启动时拉起 HTTP 控制服务与脚本引擎；通过,%hook 拦截 SpringBoard 生命周期
 * 保证服务随桌面存活。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "XTApplication.h"
#import "XTLogger.h"
#import "XTUDPControl.h"
#import "XTCloudControl.h"

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    XTLog(@"[XAutouch] SpringBoard 已启动，初始化自动化引擎");
    [[XTApplication sharedInstance] start];
    // UDP 控制服务随桌面启动（对标原版 touchelf-udpd.lua）
    [[XTApplication sharedInstance] udpStart:46900];
    // 云控按配置里的 autoConnect 决定是否外联，不默认连公网
    [[XTCloudControl sharedInstance] startAutoConnectIfNeeded];
}

// 音量键动作绑定（对标 uiservice-volume-key-control-service.lua）。
// Logos 对私有选择器在编译期不校验，运行时若 SpringBoard 无此方法则不会命中，
// 不影响其他功能；绑定动作本身由 XTUIService 从 plist 读取并执行。
- (void)_volumeDownKeyDown:(id)sender {
    %orig;
    [[XTApplication sharedInstance] handleVolumeKey:@"volume_down"];
}
- (void)_volumeUpKeyDown:(id)sender {
    %orig;
    [[XTApplication sharedInstance] handleVolumeKey:@"volume_up"];
}

- (void)dealloc {
    [[XTApplication sharedInstance] stop];
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        XTLog(@"[XAutouch] ctor loaded in %@", NSBundle.mainBundle.bundleIdentifier);
        // rootless 环境下资源安装在 /var/jb/usr/lib/xautouch，rootful 在 /usr/lib/xautouch
        NSArray *roots = @[@"/var/jb/usr/lib/xautouch", @"/usr/lib/xautouch"];
        for (NSString *root in roots) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:root]) {
                [[XTApplication sharedInstance] setResourceRoot:root];
                break;
            }
        }
    }
}
