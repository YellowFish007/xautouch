#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void XTLog(NSString *fmt, ...);

@interface XTLogger : NSObject
+ (instancetype)sharedInstance;
- (NSArray<NSString *> *)recentLines:(NSUInteger)limit;
- (void)log:(NSString *)line;
@end
