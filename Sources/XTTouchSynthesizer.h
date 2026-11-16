#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTTouchSynthesizer : NSObject
+ (instancetype)sharedInstance;

#pragma mark - 单点 / 多点
- (void)tapAtX:(CGFloat)x y:(CGFloat)y;
- (void)touchDown:(CGFloat)x y:(CGFloat)y id:(uint32_t)tid;
- (void)touchMove:(CGFloat)x y:(CGFloat)y id:(uint32_t)tid;
- (void)touchUp:(CGFloat)x y:(CGFloat)y id:(uint32_t)tid;
- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1 toX:(CGFloat)x2 y:(CGFloat)y2 duration:(NSTimeInterval)durationMs;
- (void)multiTouch:(NSArray<NSDictionary *> *)touches;

#pragma mark - 拖拽 / 滚轮
/// points: @[@{@"x":..,@"y":..}, ...]；async=YES 时后台执行立即返回
- (void)dragLinearFromX:(CGFloat)x1 y:(CGFloat)y1 toX:(CGFloat)x2 y:(CGFloat)y2
               duration:(NSTimeInterval)ms async:(BOOL)async;
- (void)dragCurveThrough:(NSArray *)points duration:(NSTimeInterval)ms async:(BOOL)async;
- (void)wheelAtX:(CGFloat)x y:(CGFloat)y delta:(CGFloat)delta async:(BOOL)async;

#pragma mark - 键盘 / 文本 / 剪贴板
- (void)pressKey:(NSString *)keyName;
- (void)keyDown:(NSString *)keyName;
- (void)keyUp:(NSString *)keyName;
- (void)inputText:(NSString *)text;
- (nullable NSString *)pasteboardRead;
- (void)pasteboardWrite:(NSString *)text;

#pragma mark - 录制 / 回放
- (void)startRecording;
- (NSArray<NSDictionary *> *)stopRecording;
- (BOOL)isRecording;
- (void)playbackEvents:(NSArray<NSDictionary *> *)events;

@end

NS_ASSUME_NONNULL_END
