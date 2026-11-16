/**
 * XTTouchSynthesizer.mm - 系统级触摸合成（完整实现）
 *
 * 通过 IOHit HID digitizer 事件派发到 WindowServer，等价于真实手指触摸。
 * 覆盖：单点 down/move/up/tap、滑动、曲线拖拽、滚轮、多点、实体按键
 *       down/up、文本输入、剪贴板、操作录制与回放。
 * 私有符号使用 dlsym 动态解析，兼容不同 iOS 版本与 rootful/rootless。
 */
#import "XTTouchSynthesizer.h"
#import "XTLogger.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <UIKit/UIKit.h>
// 不 import <IOKit/hid/IOHIDEvent.h>：Theos 自带 IOKit 头在 Xcode 15+ 下
// 会因 "@import 出现在 extern \"C\" 内" 触发 -Werror 编译失败。
// 本文件的 IOHID 符号全部经 dlsym 动态解析，常量用下方自定义宏，
// 因此该头文件并非必需，移除后功能不变且跨 Xcode 版本可编译。

#ifndef kIOHIDDigitizerEventTouch
#define kIOHIDDigitizerEventTouch    0x00000002
#define kIOHIDDigitizerEventPosition 0x00000004
#define kIOHIDDigitizerEventRange    0x00000008
#define kIOHIDDigitizerEventIdentity 0x00000010
#endif

typedef void     *(*XTCreateClientFn)(CFAllocatorRef);
typedef void      (*XTDispatchEventFn)(void *client, void *event);
typedef void     *(*XTDigitizerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                        uint32_t, uint32_t, uint32_t, double, double, double,
                                        double, double, double, double, bool, bool,
                                        uint32_t, uint32_t, double, double);
typedef void     *(*XTKeyboardEventFn)(CFAllocatorRef, uint64_t, uint16_t, uint16_t, bool);
typedef void     *(*XTScrollEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                     double, double, double);
typedef void      (*XTSetFloatFn)(void *event, uint32_t field, double value);

@implementation XTTouchSynthesizer {
    void *_client;
    XTDispatchEventFn _dispatch;
    XTDigitizerEventFn _createDigitizer;
    XTKeyboardEventFn _createKeyboard;
    XTScrollEventFn   _createScroll;
    XTSetFloatFn      _setFloat;
    NSMutableDictionary<NSNumber *, NSNumber *> *_active; // 触点 id -> 是否按下
    BOOL _ready;
    BOOL _recording;
    NSMutableArray<NSDictionary *> *_recorded;
    NSDate *_recordStart;
    NSLock *_recordLock;
}

+ (instancetype)sharedInstance {
    static XTTouchSynthesizer *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _active = [NSMutableDictionary dictionary];
        _recordLock = [NSLock new];
        _recorded = [NSMutableArray array];
        [self resolveSymbols];
    }
    return self;
}

- (void)resolveSymbols {
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!io) io = RTLD_DEFAULT;
    XTCreateClientFn create = (XTCreateClientFn)dlsym(io, "IOHIDEventSystemClientCreate");
    _dispatch       = (XTDispatchEventFn)dlsym(io, "IOHIDEventSystemClientDispatchEvent");
    _createDigitizer= (XTDigitizerEventFn)dlsym(io, "IOHIDEventCreateDigitizerEvent");
    _createKeyboard = (XTKeyboardEventFn)dlsym(io, "IOHIDEventCreateKeyboardEvent");
    _createScroll   = (XTScrollEventFn)dlsym(io, "IOHIDEventCreateScrollWheelEvent");
    _setFloat       = (XTSetFloatFn)dlsym(io, "IOHIDEventSetFloatValue");
    if (create) _client = create(kCFAllocatorDefault);
    _ready = (_client && _dispatch && _createDigitizer);
    XTLog(@"[XAutouch] IOHID %@；keyboard=%@ scroll=%@",
          _ready ? @"就绪" : @"不可用", _createKeyboard ? @"yes" : @"no", _createScroll ? @"yes" : @"no");
}

#pragma mark - 底层事件

static uint64_t XTNow(void) { return mach_absolute_time(); }

- (void *)digitizerAtX:(double)x y:(double)y id:(uint32_t)tid mask:(uint32_t)mask {
    if (!_createDigitizer) return NULL;
    void *evt = _createDigitizer(kCFAllocatorDefault, XTNow(),
                                 2 /* kIOHIDDigitizerTransducerTypeFinger */,
                                 tid, tid, mask, 0,
                                 x, y, 0.0,      // position + z
                                 0.25, 0, 0, 0,  // pressure / tilt / twist
                                 true,           // range
                                 (mask & kIOHIDDigitizerEventTouch) ? true : false,
                                 0, 0, 0, 0);
    if (evt && _setFloat) {
        // 字段基址：kIOHIDEventTypeDigitizer(11) << 16；X=1, Y=2, pressure=4
        _setFloat(evt, (11 << 16) | 1, x);
        _setFloat(evt, (11 << 16) | 2, y);
    }
    return evt;
}

- (void)send:(void *)evt {
    if (!evt) return;
    if (_ready && _dispatch) _dispatch(_client, evt);
    else XTLog(@"[XAutouch] IOHID 不可用，事件未派发（需真机 IOKit 权限）");
    CFRelease(evt);
}

- (void)dispatchDigitizerX:(double)x y:(double)y id:(uint32_t)tid mask:(uint32_t)mask {
    [self send:[self digitizerAtX:x y:y id:tid mask:mask]];
}

#pragma mark - 录制

- (BOOL)isRecording { return _recording; }

- (void)startRecording {
    [_recordLock lock];
    [_recorded removeAllObjects];
    _recordStart = [NSDate date];
    _recording = YES;
    [_recordLock unlock];
    XTLog(@"[XAutouch] 开始录制");
}

- (NSArray<NSDictionary *> *)stopRecording {
    [_recordLock lock];
    _recording = NO;
    NSArray *result = [_recorded copy];
    [_recordLock unlock];
    XTLog(@"[XAutouch] 停止录制，共 %lu 事件", (unsigned long)result.count);
    return result;
}

- (void)record:(NSString *)type extras:(NSDictionary *)extras {
    if (!_recording) return;
    [_recordLock lock];
    NSMutableDictionary *e = [NSMutableDictionary dictionaryWithDictionary:extras];
    e[@"type"] = type;
    e[@"t"] = @((long long)([_recordStart timeIntervalSinceNow] * -1000.0));
    [_recorded addObject:e];
    [_recordLock unlock];
}

#pragma mark - 单点 / 多点（raw + 公开包装）

- (void)rawTapX:(CGFloat)x y:(CGFloat)y {
    uint32_t tid = 1;
    uint32_t downMask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition |
                        kIOHIDDigitizerEventRange | kIOHIDDigitizerEventIdentity;
    [self dispatchDigitizerX:x y:y id:tid mask:downMask];
    _active[@(tid)] = @YES;
    usleep(60000);
    [self dispatchDigitizerX:x y:y id:tid mask:kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventRange];
    [_active removeObjectForKey:@(tid)];
}

- (void)tapAtX:(CGFloat)x y:(CGFloat)y {
    [self record:@"tap" extras:@{@"x":@(x), @"y":@(y)}];
    [self rawTapX:x y:y];
}

- (void)touchDown:(CGFloat)x y:(CGFloat)y id:(uint32_t)tid {
    [self record:@"down" extras:@{@"x":@(x), @"y":@(y), @"id":@(tid)}];
    [self dispatchDigitizerX:x y:y id:tid mask:kIOHIDDigitizerEventTouch |
                                            kIOHIDDigitizerEventPosition |
                                            kIOHIDDigitizerEventRange |
                                            kIOHIDDigitizerEventIdentity];
    _active[@(tid)] = @YES;
}

- (void)touchMove:(CGFloat)x y:(CGFloat)y id:(uint32_t)tid {
    [self record:@"move" extras:@{@"x":@(x), @"y":@(y), @"id":@(tid)}];
    [self dispatchDigitizerX:x y:y id:tid mask:kIOHIDDigitizerEventPosition |
                                            kIOHIDDigitizerEventRange |
                                            ([[_active objectForKey:@(tid)] boolValue] ? kIOHIDDigitizerEventTouch : 0)];
}

- (void)touchUp:(CGFloat)x y:(CGFloat)y id:(uint32_t)tid {
    [self record:@"up" extras:@{@"x":@(x), @"y":@(y), @"id":@(tid)}];
    [self dispatchDigitizerX:x y:y id:tid mask:kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventRange];
    [_active removeObjectForKey:@(tid)];
}

- (void)rawSwipeX1:(CGFloat)x1 y1:(CGFloat)y1 x2:(CGFloat)x2 y2:(CGFloat)y2 duration:(NSTimeInterval)ms {
    uint32_t tid = 2;
    [self touchDown:x1 y:y1 id:tid];
    NSInteger steps = MAX(1, (NSInteger)(ms / 16.0));
    for (NSInteger i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        [self dispatchDigitizerX:x1 + (x2-x1)*t y:y1 + (y2-y1)*t id:tid
                            mask:kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventRange];
        usleep((useconds_t)MAX(1, ms * 1000 / steps));
    }
    [self touchUp:x2 y:y2 id:tid];
}

- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1 toX:(CGFloat)x2 y:(CGFloat)y2 duration:(NSTimeInterval)ms {
    [self record:@"swipe" extras:@{@"x1":@(x1), @"y1":@(y1), @"x2":@(x2), @"y2":@(y2), @"duration":@(ms)}];
    [self rawSwipeX1:x1 y1:y1 x2:x2 y2:y2 duration:ms];
}

- (void)multiTouch:(NSArray<NSDictionary *> *)touches {
    [self record:@"multi" extras:@{@"touches":touches ?: @[]}];
    for (NSDictionary *t in touches) {
        [self touchDown:[t[@"x"] doubleValue] y:[t[@"y"] doubleValue]
                     id:(uint32_t)[t[@"id"] unsignedIntegerValue]];
    }
}

#pragma mark - 拖拽 / 滚轮

- (void)dragLinearFromX:(CGFloat)x1 y:(CGFloat)y1 toX:(CGFloat)x2 y:(CGFloat)y2
               duration:(NSTimeInterval)ms async:(BOOL)async {
    if (async) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self rawSwipeX1:x1 y1:y1 x2:x2 y2:y2 duration:ms];
        });
        return;
    }
    [self rawSwipeX1:x1 y1:y1 x2:x2 y2:y2 duration:ms];
}

- (void)dragCurveThrough:(NSArray *)points duration:(NSTimeInterval)ms async:(BOOL)async {
    void (^work)(void) = ^{
        if (points.count < 2) return;
        uint32_t tid = 3;
        NSTimeInterval step = MAX(8.0, ms / MAX(1, (double)points.count));
        [self touchDown:[points[0][@"x"] doubleValue] y:[points[0][@"y"] doubleValue] id:tid];
        for (NSUInteger i = 1; i < points.count; i++) {
            double x0 = [points[i-1][@"x"] doubleValue], y0 = [points[i-1][@"y"] doubleValue];
            double x1 = [points[i][@"x"] doubleValue],   y1 = [points[i][@"y"] doubleValue];
            NSInteger sub = 6;
            for (NSInteger s = 1; s <= sub; s++) {
                double t = (double)s / sub;
                // Catmull-Rom 风格平滑（这里用 ease-in-out 插值近似曲线轨迹）
                double e = t*t*(3 - 2*t);
                [self dispatchDigitizerX:x0 + (x1-x0)*e y:y0 + (y1-y0)*e id:tid
                                    mask:kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventRange];
                usleep((useconds_t)MAX(1, step * 1000 / sub));
            }
        }
        NSDictionary *last = points.lastObject;
        [self touchUp:[last[@"x"] doubleValue] y:[last[@"y"] doubleValue] id:tid];
    };
    [self record:@"curve" extras:@{@"points":points ?: @[], @"duration":@(ms)}];
    if (async) dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), work);
    else work();
}

- (void)wheelAtX:(CGFloat)x y:(CGFloat)y delta:(CGFloat)delta async:(BOOL)async {
    void (^work)(void) = ^{
        if (self->_createScroll) {
            void *evt = self->_createScroll(kCFAllocatorDefault, XTNow(),
                                            0 /* kIOHIDScrollEventTypeScrollWheel */,
                                            1 /* kIOHIDScrollUnitPixel */, 0, delta, 0);
            [self send:evt];
        } else {
            XTLog(@"[XAutouch] scroll 符号不可用，退化为按键模拟");
            [self pressKey:delta > 0 ? @"SCROLL_DOWN" : @"SCROLL_UP"];
        }
    };
    [self record:@"wheel" extras:@{@"x":@(x), @"y":@(y), @"delta":@(delta)}];
    if (async) dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), work);
    else work();
}

#pragma mark - 键盘 / 文本 / 剪贴板

/// 键名 -> (usage page, usage)。系统键走 Consumer page(0x0C)，字符键走 Keyboard page(0x07)。
- (NSDictionary *)usageFor:(NSString *)key {
    NSDictionary *sys = @{
        @"HOME":@[@(0x0C), @(0x40)], @"POWER":@[@(0x0C), @(0x30)],
        @"VOLUME_UP":@[@(0x0C), @(0xE9)], @"VOLUME_DOWN":@[@(0x0C), @(0xEA)],
        @"MUTE":@[@(0x0C), @(0xE2)], @"SCROLL_UP":@[@(0x0C), @(0x23)],
        @"SCROLL_DOWN":@[@(0x0C), @(0x21)], @"BACK":@[@(0x0C), @(0x24)],
        @"ENTER":@[@(0x07), @(0x28)], @"RETURN":@[@(0x07), @(0x28)],
        @"TAB":@[@(0x07), @(0x2B)], @"SPACE":@[@(0x07), @(0x2C)],
        @"DELETE":@[@(0x07), @(0x2A)], @"ESCAPE":@[@(0x07), @(0x29)]
    };
    NSString *upper = key.uppercaseString;
    if (sys[upper]) return sys[upper];
    if (key.length == 1) {
        unichar c = [key characterAtIndex:0];
        if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
            return @{@"page":@(0x07), @"usage":@(c)}; // HID 字母/数字 usage == ASCII
    }
    return @{@"page":@(0x07), @"usage":@(0)};
}

- (void)emitKey:(NSString *)key down:(BOOL)down {
    if (!_createKeyboard) { XTLog(@"[XAutouch] keyboard 事件符号不可用: %@", key); return; }
    NSDictionary *u = [self usageFor:key];
    void *evt = _createKeyboard(kCFAllocatorDefault, XTNow(),
                                (uint16_t)[u[@"page"] unsignedIntValue],
                                (uint16_t)[u[@"usage"] unsignedIntValue], down);
    [self send:evt];
}

- (void)keyDown:(NSString *)key { [self record:@"key_down" extras:@{@"key":key ?: @""}]; [self emitKey:key down:YES]; }
- (void)keyUp:(NSString *)key   { [self record:@"key_up"   extras:@{@"key":key ?: @""}]; [self emitKey:key down:NO]; }
- (void)pressKey:(NSString *)key { [self emitKey:key down:YES]; usleep(50000); [self emitKey:key down:NO]; }

/// 沿响应链找第一响应者，避免依赖不存在的私有选择器
- (nullable UIResponder *)firstResponder {
    UIApplication *app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(firstResponder)]) {
        UIResponder *r = [app performSelector:@selector(firstResponder)];
        if (r) return r;
    }
    for (UIWindow *w in app.windows) {
        UIResponder *found = [self findResponderInView:w];
        if (found) return found;
    }
    return nil;
}

- (nullable UIResponder *)findResponderInView:(UIView *)v {
    if (v.isFirstResponder) return v;
    for (UIView *sub in v.subviews) {
        UIResponder *r = [self findResponderInView:sub];
        if (r) return r;
    }
    return nil;
}

- (void)inputText:(NSString *)text {
    if (text.length == 0) return;
    [self record:@"input" extras:@{@"text":text}];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIResponder *first = [self firstResponder];
        if ([first respondsToSelector:@selector(insertText:)]) {
            [first performSelector:@selector(insertText:) withObject:text];
            XTLog(@"[XAutouch] 输入文本 %@", text);
        } else {
            XTLog(@"[XAutouch] 无第一响应者，文本输入丢弃");
        }
    });
}

- (NSString *)pasteboardRead { return [UIPasteboard generalPasteboard].string ?: @""; }
- (void)pasteboardWrite:(NSString *)text { [UIPasteboard generalPasteboard].string = text ?: @""; }

#pragma mark - 回放

- (void)playbackEvents:(NSArray<NSDictionary *> *)events {
    if (![events isKindOfClass:[NSArray class]]) return;
    XTLog(@"[XAutouch] 回放 %lu 事件", (unsigned long)events.count);
    long long last = 0;
    for (NSDictionary *e in events) {
        long long t = [e[@"t"] longLongValue];
        if (t > last) usleep((useconds_t)((t - last) * 1000));
        last = t;
        NSString *type = e[@"type"] ?: @"";
        if ([type isEqualToString:@"tap"]) [self rawTapX:[e[@"x"] doubleValue] y:[e[@"y"] doubleValue]];
        else if ([type isEqualToString:@"down"]) [self dispatchDigitizerX:[e[@"x"] doubleValue] y:[e[@"y"] doubleValue]
                    id:(uint32_t)[e[@"id"] unsignedIntegerValue] mask:kIOHIDDigitizerEventTouch|kIOHIDDigitizerEventPosition|kIOHIDDigitizerEventRange|kIOHIDDigitizerEventIdentity];
        else if ([type isEqualToString:@"move"]) [self dispatchDigitizerX:[e[@"x"] doubleValue] y:[e[@"y"] doubleValue]
                    id:(uint32_t)[e[@"id"] unsignedIntegerValue] mask:kIOHIDDigitizerEventPosition|kIOHIDDigitizerEventRange|kIOHIDDigitizerEventTouch];
        else if ([type isEqualToString:@"up"]) [self dispatchDigitizerX:[e[@"x"] doubleValue] y:[e[@"y"] doubleValue]
                    id:(uint32_t)[e[@"id"] unsignedIntegerValue] mask:kIOHIDDigitizerEventPosition|kIOHIDDigitizerEventRange];
        else if ([type isEqualToString:@"swipe"]) [self rawSwipeX1:[e[@"x1"] doubleValue] y1:[e[@"y1"] doubleValue]
                    x2:[e[@"x2"] doubleValue] y2:[e[@"y2"] doubleValue] duration:[e[@"duration"] doubleValue]];
        else if ([type isEqualToString:@"curve"]) [self dragCurveThrough:e[@"points"] ?: @[] duration:[e[@"duration"] doubleValue] async:NO];
        else if ([type isEqualToString:@"wheel"]) [self wheelAtX:[e[@"x"] doubleValue] y:[e[@"y"] doubleValue] delta:[e[@"delta"] doubleValue] async:NO];
        else if ([type isEqualToString:@"key_down"]) [self emitKey:e[@"key"] down:YES];
        else if ([type isEqualToString:@"key_up"]) [self emitKey:e[@"key"] down:NO];
        else if ([type isEqualToString:@"input"]) dispatch_async(dispatch_get_main_queue(), ^{
            UIResponder *f = [self firstResponder];
            if ([f respondsToSelector:@selector(insertText:)]) [f performSelector:@selector(insertText:) withObject:e[@"text"]];
        });
    }
}

@end
