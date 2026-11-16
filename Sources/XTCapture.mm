/**
 * XTCapture.mm - 屏幕截图
 * SpringBoard 进程内通过UIScreen 私有 API 抓取，保存 PNG 到沙盒目录。
 */
#import "XTCapture.h"
#import "XTApplication.h"
#import "XTLogger.h"
#import <UIKit/UIKit.h>

@implementation XTCapture
+ (instancetype)sharedInstance {
    static XTCapture *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (NSString *)directory {
    NSString *d = [NSString stringWithFormat:@"%@/captures", [XTApplication resourceRoot]];
    [[NSFileManager defaultManager] createDirectoryAtPath:d
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

- (NSString *)captureScreen {
    NSData *png = nil;
    // 私有 API：UIScreen 捕获整个屏幕（含系统 UI）
    if ([[UIScreen mainScreen] respondsToSelector:@selector(snapshotAfterUpdates:)]) {
        UIView *view = (UIView *)[[UIScreen mainScreen] performSelector:@selector(snapshotAfterUpdates:) withObject:@NO];
        if (view) png = UIImagePNGRepresentation([self imageFromView:view]);
    }
    if (!png) {
        XTLog(@"[XAutouch] 截图 API 不可用（需真机私有权限）");
        return nil;
    }
    NSString *name = [NSString stringWithFormat:@"cap_%lld.png", (long long)([[NSDate date] timeIntervalSince1970]*1000)];
    NSString *path = [[self directory] stringByAppendingPathComponent:name];
    [png writeToFile:path atomically:YES];
    XTLog(@"[XAutouch] 截图保存 %@", path);
    return path;
}

- (UIImage *)imageFromView:(UIView *)view {
    UIGraphicsBeginImageContextWithOptions(view.bounds.size, NO, 0);
    [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}
@end
