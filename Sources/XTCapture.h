#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface XTCapture : NSObject
+ (instancetype)sharedInstance;
- (nullable NSString *)captureScreen;   // 返回截图文件路径
@end
NS_ASSUME_NONNULL_END
