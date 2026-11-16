/**
 * XTEAppDelegate.mm - 应用启动流程
 *
 * 启动顺序：先建立可见窗口（列表页处于等待状态），再异步请求
 * /deviceinfo 读取 resource_root，拿到真实前缀后让列表页加载目录。
 * 这样即使本地服务尚未就绪，也不会出现长时间黑屏。
 */
#import "XTEAppDelegate.h"
#import "XTEAPIClient.h"
#import "XTEFileListController.h"

@interface XTEAppDelegate ()
@property (nonatomic, strong, readwrite) UINavigationController *navigationController;
@end

@implementation XTEAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 先用 rootless 默认值占位；真实值由 /deviceinfo 的 resource_root 覆盖。
    NSString *initialRoot = [XTEAPIClient defaultResourceRoot];
    XTEFileListController *listController =
        [[XTEFileListController alloc] initWithPath:initialRoot rootPath:initialRoot];

    UINavigationController *navController =
        [[UINavigationController alloc] initWithRootViewController:listController];
    navController.toolbarHidden = NO;
    self.navigationController = navController;

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = navController;
    [self.window makeKeyAndVisible];

    // APIClient 保证回调在主线程；weak 避免 block 持有列表控制器。
    __weak typeof(listController) weakList = listController;
    [[XTEAPIClient sharedClient] fetchResourceRoot:^(NSString *root, NSError *error) {
        XTEFileListController *strongList = weakList;
        if (!strongList) return;
        // 失败时 APIClient 已回退到默认前缀；列表页的目录请求会给出具体错误提示。
        [strongList applyResourceRoot:root];
    }];

    return YES;
}

@end
