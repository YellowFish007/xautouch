/**
 * XTScreenShare.mm - 屏幕共享实现
 *
 * 帧循环在私有 serial queue 的 dispatch timer 中跑；截图经主线程获取，
 * PNG 解码/JPEG 压缩/base64 分片全部在后台队列。
 * 独立 UDP socket，不依赖 XTUDPControl 的监听 socket。
 */
#import "XTScreenShare.h"
#import "XTApplication.h"
#import "XTCapture.h"
#import "XTLogger.h"
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>

/// base64 后 768 -> 1024 字符，加上 cmd/seq/total/w/h 的 JSON 头仍小于 1200 字节
static const NSUInteger kXTScreenChunkBytes = 768;

static NSArray<NSData *> *XTScreenChunkData(NSData *data, NSUInteger chunkBytes) {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger offset = 0;
    while (offset < data.length) {
        NSUInteger len = MIN(chunkBytes, data.length - offset);
        [out addObject:[data subdataWithRange:NSMakeRange(offset, len)]];
        offset += len;
    }
    if (out.count == 0) [out addObject:[NSData data]];
    return out;
}

@interface XTScreenShare ()
- (void)captureAndSend;
- (BOOL)resolveHost:(NSString *)host port:(UInt16)port into:(struct sockaddr_in *)out;
- (BOOL)sendJSON:(NSDictionary *)obj;
- (void)setLastError:(NSString *)message;
@end

@implementation XTScreenShare {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    BOOL _running;
    NSInteger _fps;
    CGFloat _quality;
    NSTimeInterval _interval;

    int _fd;
    struct sockaddr_in _target;
    BOOL _hasTarget;

    NSLock *_statsLock;
    uint64_t _seq;
    uint64_t _sentFrames;
    uint64_t _droppedFrames;
    uint64_t _failedFrames;
    NSTimeInterval _lastCost;
    NSUInteger _lastWidth;
    NSUInteger _lastHeight;
    NSString *_lastError;

    NSCondition *_condition;
    NSData *_lastJPEG;
    NSUInteger _frameGeneration;
}

+ (instancetype)sharedInstance {
    static XTScreenShare *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.xautouch.screen.share", DISPATCH_QUEUE_SERIAL);
        _statsLock = [NSLock new];
        _condition = [NSCondition new];
        _fd = -1;
        _fps = 10;
        _quality = 0.6;
        _interval = 1.0 / 10.0;
        memset(&_target, 0, sizeof(_target));
    }
    return self;
}

#pragma mark - 目标配置

- (NSString *)targetPlistPath {
    NSString *root = [XTApplication resourceRoot] ?: @"/var/jb/usr/lib/xautouch";
    return [root stringByAppendingPathComponent:@"screen_target.plist"];
}

- (BOOL)resolveHost:(NSString *)host port:(UInt16)port into:(struct sockaddr_in *)out {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    struct addrinfo *res = NULL;
    NSString *portString = [NSString stringWithFormat:@"%u", (unsigned)port];
    int rc = getaddrinfo(host.UTF8String, portString.UTF8String, &hints, &res);
    if (rc != 0 || !res) return NO;
    if (res->ai_addrlen < sizeof(struct sockaddr_in)) { freeaddrinfo(res); return NO; }
    memcpy(out, res->ai_addr, sizeof(struct sockaddr_in));
    freeaddrinfo(res);
    return YES;
}

- (BOOL)setupTargetSocket {
    NSDictionary *conf = [NSDictionary dictionaryWithContentsOfFile:[self targetPlistPath]] ?: @{};
    NSString *host = conf[@"host"];
    UInt16 port = (UInt16)[conf[@"port"] unsignedIntValue];
    if ([host length] == 0 || port == 0) {
        XTLog(@"[XAutouch] 未配置 screen_target.plist，仅本地缓存最后一帧");
        return NO;
    }
    struct sockaddr_in target;
    if (![self resolveHost:host port:port into:&target]) {
        [self setLastError:[NSString stringWithFormat:@"无法解析目标 %@", host]];
        return NO;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { [self setLastError:[NSString stringWithUTF8String:strerror(errno)]]; return NO; }
    int sndbuf = 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = htons(0);
    if (bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0 ||
        connect(fd, (struct sockaddr *)&target, sizeof(target)) < 0) {
        [self setLastError:[NSString stringWithUTF8String:strerror(errno)]];
        close(fd);
        return NO;
    }

    _fd = fd;
    _target = target;
    _hasTarget = YES;
    XTLog(@"[XAutouch] 屏幕共享目标 %@:%u", host, (unsigned)port);
    return YES;
}

#pragma mark - 生命周期

- (BOOL)startWithFPS:(NSInteger)fps quality:(CGFloat)quality {
    _fps = MAX(1, MIN(30, fps ?: 10));
    _quality = MAX(0.05, MIN(1.0, quality > 0 ? quality : 0.6));
    _interval = 1.0 / (double)_fps;
    if (_running) [self stop];

    _hasTarget = NO;
    [self setupTargetSocket];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(_interval * NSEC_PER_SEC),
                              (uint64_t)(0.01 * NSEC_PER_SEC));
    __weak XTScreenShare *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong XTScreenShare *self = weakSelf;
        if (self && self->_running) [self captureAndSend];
    });
    dispatch_source_set_cancel_handler(timer, ^{
        // socket 在 stop 中关闭，这里只释放 source
    });
    _timer = timer;
    _running = YES;
    dispatch_resume(timer);
    XTLog(@"[XAutouch] 屏幕共享已启动 %ldfps q=%.2f", (long)_fps, _quality);
    return YES;
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    dispatch_source_t timer = _timer;
    _timer = nil;
    if (timer) dispatch_source_cancel(timer);
    if (_fd >= 0) { close(_fd); _fd = -1; }
    _hasTarget = NO;
    [_condition lock];
    [_condition broadcast];   // 唤醒 MJPEG 长连接等待者
    [_condition unlock];
    XTLog(@"[XAutouch] 屏幕共享已停止");
}

- (BOOL)isRunning { return _running; }

- (void)setLastError:(NSString *)message {
    [_statsLock lock];
    _lastError = [message copy];
    [_statsLock unlock];
}

#pragma mark - 抓帧

- (void)captureAndSend {
    NSDate *frameStart = [NSDate date];
    // 上一次耗时超过帧间隔则直接丢帧，避免队列堆积
    if (_lastCost > _interval) {
        [_statsLock lock];
        _droppedFrames++;
        [_statsLock unlock];
        return;
    }

    // 截图使用 UIKit，必须主线程；文件读取/压缩留在后台队列
    __block NSString *path = nil;
    if ([NSThread isMainThread]) {
        path = [[XTCapture sharedInstance] captureScreen];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            path = [[XTCapture sharedInstance] captureScreen];
        });
    }
    NSData *png = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];  // 防止高频抓屏堆积文件

    UIImage *image = png ? [UIImage imageWithData:png] : nil;
    NSData *jpeg = nil;
    if (image) {
        // ObjC 侧只有 UIImageJPEGRepresentation 这个 C 函数
        // （Swift 的 image.jpegData(compressionQuality:) 并非 ObjC selector）
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        jpeg = UIImageJPEGRepresentation(image, _quality);
#pragma clang diagnostic pop
    }
    if (!jpeg) {
        [self setLastError:@"capture_or_encode_failed"];
        [_statsLock lock];
        _failedFrames++;
        [_statsLock unlock];
        return;
    }

    NSUInteger width = (NSUInteger)image.size.width;
    NSUInteger height = (NSUInteger)image.size.height;

    // 更新 MJPEG 等待队列：新帧唤醒所有 /api/screen/stream 长连接
    [_condition lock];
    _lastJPEG = jpeg;
    _frameGeneration++;
    [_condition broadcast];
    [_condition unlock];

    NSString *root = [XTApplication resourceRoot] ?: @"/var/jb/usr/lib/xautouch";
    [jpeg writeToFile:[root stringByAppendingPathComponent:@"screen_last.jpg"] atomically:YES];

    if (_hasTarget && _fd >= 0) {
        NSArray<NSData *> *chunks = XTScreenChunkData(jpeg, kXTScreenChunkBytes);
        NSUInteger total = chunks.count;
        for (NSUInteger i = 0; i < total; i++) {
            NSDictionary *packet = @{@"cmd": @"frame",
                                     @"seq": @(i + 1),
                                     @"total": @(total),
                                     @"w": @(width),
                                     @"h": @(height),
                                     @"data": [chunks[i] base64EncodedStringWithOptions:0]};
            [self sendJSON:packet];
        }
    }

    [_statsLock lock];
    _seq++;
    _sentFrames++;
    _lastWidth = width;
    _lastHeight = height;
    _lastCost = [[NSDate date] timeIntervalSinceDate:frameStart];
    [_statsLock unlock];
}

#pragma mark - 发送 / 统计

- (BOOL)sendJSON:(NSDictionary *)obj {
    if (_fd < 0 || !_hasTarget) return NO;
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!json || json.length > 60000) return NO;
    ssize_t n = send(_fd, json.bytes, json.length, 0);
    if (n < 0) {
        [self setLastError:[NSString stringWithUTF8String:strerror(errno)]];
        return NO;
    }
    return YES;
}

- (NSDictionary<NSString *, id> *)lastFrameStats {
    [_statsLock lock];
    NSDictionary *stats = @{@"running": @(_running),
                            @"fps": @(_fps),
                            @"quality": @(_quality),
                            @"seq": @(_seq),
                            @"sent_frames": @(_sentFrames),
                            @"dropped_frames": @(_droppedFrames),
                            @"failed_frames": @(_failedFrames),
                            @"width": @(_lastWidth),
                            @"height": @(_lastHeight),
                            @"last_cost_ms": @(_lastCost * 1000.0),
                            @"has_target": @(_hasTarget),
                            @"last_error": _lastError ?: @""};
    [_statsLock unlock];
    return stats;
}

#pragma mark - MJPEG 取帧

- (nullable NSData *)nextJPEGFrameWithTimeout:(NSTimeInterval)t {
    NSTimeInterval timeout = MAX(0.05, t);
    [_condition lock];
    NSUInteger startGeneration = _frameGeneration;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (_frameGeneration == startGeneration && _running &&
           [deadline timeIntervalSinceNow] > 0) {
        [_condition waitUntilDate:deadline];
    }
    NSData *frame = (_frameGeneration == startGeneration) ? nil : [_lastJPEG copy];
    [_condition unlock];
    return frame;
}

@end
