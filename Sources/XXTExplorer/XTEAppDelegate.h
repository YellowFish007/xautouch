/**
 * XTEAppDelegate.h - 应用生命周期与根界面容器
 *
 * 负责创建 UIWindow 和 UINavigationController，并在启动时通过 /deviceinfo
 * 取得宿主的真实 resource_root，注入文件列表控制器。
 */
#import <UIKit/UIKit.h>

@interface XTEAppDelegate : UIResponder <UIApplicationDelegate>

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong, readonly) UINavigationController *navigationController;

@end
