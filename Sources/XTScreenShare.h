/**
 * XTScreenShare.h - 屏幕共享 / MJPEG 取帧
 *
 * 对标 web-screen.lua：按 fps 抓屏 -> PNG 解码 -> JPEG 压缩 ->
 * 分片 UDP 发送到 screen_target.plist 指定的 host:port；未配置时仅本地缓存。
 * 同时通过 NSCondition 为 HTTP /api/screen/stream 提供逐帧 MJPEG 输出。
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTScreenShare : NSObject

+ (instancetype)sharedInstance;

/// fps 会被限制在 1..30；quality 限制在 0.05..1.0。返回是否成功启动。
- (BOOL)startWithFPS:(NSInteger)fps quality:(CGFloat)quality;
- (void)stop;
- (BOOL)isRunning;
- (NSDictionary<NSString *, id> *)lastFrameStats;

/**
 * MJPEG 长连接取帧：等待下一帧产生，超时返回 nil。
 * 供 XTRoutes 的 /api/screen/stream 循环调用，每次返回一帧完整 JPEG。
 */
- (nullable NSData *)nextJPEGFrameWithTimeout:(NSTimeInterval)t;

@end

NS_ASSUME_NONNULL_END
