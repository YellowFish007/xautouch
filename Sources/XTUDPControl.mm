/**
 * XTUDPControl.mm - UDP 控制服务实现
 *
 * 设计要点：
 *   1. BSD SOCK_DGRAM + dispatch_source(DISPATCH_SOURCE_TYPE_READ)，非阻塞收包；
 *   2. JSON 解析与截图压缩全部在后台队列，绝不在主线程处理大帧；
 *   3. token 持久化在 resourceRoot/device_token，首次启动自动生成；
 *   4. 端口占用只记 last_error 并返回 NO，不抛异常、不杀进程。
 */
#import "XTUDPControl.h"
#import "XTApplication.h"
#import "XTCapture.h"
#import "XTScriptEngine.h"
#import "XTTouchSynthesizer.h"
#import "XTLogger.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <stdlib.h>

/// 单个数据报载荷上限：768 原始字节 -> base64 1024 字符 + JSON 头 < 1200 字节
static const NSUInteger kXTUDPChunkBytes = 768;
static const NSUInteger kXTUDPBufferSize = 65535;
static const NSUInteger kXTUDPMaxDatagramsPerEvent = 64;

#pragma mark - 工具

/// 用 libc 的 arc4random_buf 生成 128bit 随机 token（无需额外 framework）
static NSString *XTRandomToken(void) {
    unsigned char bytes[16] = {0};
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return [hex copy];
}

/// 把二进制按固定大小切片，保证分片后的 JSON 数据报小于 MTU
static NSArray<NSData *> *XTChunkData(NSData *data, NSUInteger chunkBytes) {
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

static CGFloat XTNumber(id value, CGFloat fallback) {
    if ([value respondsToSelector:@selector(doubleValue)]) return (CGFloat)[value doubleValue];
    return fallback;
}

static uint32_t XTFinger(id value, uint32_t fallback) {
    if (!value) return fallback;
    uint32_t v = (uint32_t)[value unsignedIntValue];
    return v == 0 ? fallback : v;
}

@interface XTUDPControl ()
- (NSString *)tokenFilePath;
- (NSString *)loadOrCreateToken;
- (void)setLastError:(NSString *)message;
- (void)countDrop;
- (BOOL)sendBytes:(const void *)bytes length:(NSUInteger)length toAddress:(NSData *)address;
- (BOOL)startLockedOnPort:(UInt16)port;
- (void)sendScreenWithCommand:(NSDictionary *)command reply:(XTUDPCommandReplyBlock)reply;
@end

@implementation XTUDPControl {
    int _fd;
    UInt16 _port;
    BOOL _running;
    NSString *_token;
    dispatch_queue_t _queue;
    dispatch_source_t _readSource;
    NSLock *_statsLock;
    uint64_t _received;
    uint64_t _dropped;
    uint64_t _sent;
    NSString *_lastError;
}

+ (instancetype)sharedInstance {
    static XTUDPControl *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fd = -1;
        _port = 46900;
        _queue = dispatch_queue_create("com.xautouch.udp.control", DISPATCH_QUEUE_SERIAL);
        _statsLock = [NSLock new];
        _token = [self loadOrCreateToken];
    }
    return self;
}

#pragma mark - token

- (NSString *)tokenFilePath {
    NSString *root = [XTApplication resourceRoot] ?: @"/var/jb/usr/lib/xautouch";
    return [root stringByAppendingPathComponent:@"device_token"];
}

- (NSString *)loadOrCreateToken {
    NSString *path = [self tokenFilePath];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *saved = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (saved.length > 0) return saved;

    NSString *token = XTRandomToken();
    NSData *data = [[token stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if ([data writeToFile:path atomically:YES]) {
        [fm setAttributes:@{NSFilePosixPermissions: @(0600)} ofItemAtPath:path error:nil];
    } else {
        XTLog(@"[XAutouch] UDP token 写入失败: %@", path);
    }
    return token;
}

- (nullable NSString *)token { return _token; }

#pragma mark - 生命周期

- (BOOL)start { return [self startOnPort:46900]; }

- (BOOL)startOnPort:(UInt16)port {
    if (_running) return YES;
    // 与 stop 串行化，保证旧 socket 的 cancel handler 先关闭旧 fd，避免 fd 复用后被误关
    __block BOOL ok = NO;
    dispatch_sync(_queue, ^{ ok = [self startLockedOnPort:port]; });
    return ok;
}

- (BOOL)startLockedOnPort:(UInt16)port {
    if (_running) return YES;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { [self setLastError:[NSString stringWithUTF8String:strerror(errno)]]; return NO; }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    int sndbuf = 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    // dispatch_source 用水平触发，必须非阻塞并一次排空队列
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        [self setLastError:[NSString stringWithFormat:@"bind %u 失败: %s", port, strerror(errno)]];
        XTLog(@"[XAutouch] UDP 绑定 %u 失败: %s", port, strerror(errno));
        close(fd);
        return NO;
    }

    _fd = fd;
    _port = port;
    _running = YES;

    __weak XTUDPControl *weakSelf = self;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                                      (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(source, ^{
        __strong XTUDPControl *self = weakSelf;
        if (!self || !self->_running) return;
        [self drainPackets];
    });
    dispatch_source_set_cancel_handler(source, ^{
        if (_fd == fd) _fd = -1;
        if (fd >= 0) close(fd);
    });
    _readSource = source;
    dispatch_resume(source);

    XTLog(@"[XAutouch] UDP 控制服务已启动 :%u token=%@", port, _token);
    return YES;
}

- (void)stop {
    if (!_running) return;
    dispatch_sync(_queue, ^{
        if (!_running) return;
        _running = NO;
        dispatch_source_t source = _readSource;
        _readSource = nil;
        if (source) dispatch_source_cancel(source);
        XTLog(@"[XAutouch] UDP 控制服务已停止");
    });
}

- (BOOL)isRunning { return _running; }
- (UInt16)port    { return _port; }

- (NSDictionary<NSString *, id> *)stats {
    [_statsLock lock];
    NSDictionary *d = @{@"running": @(_running),
                        @"port": @(_port),
                        @"received": @(_received),
                        @"dropped": @(_dropped),
                        @"sent": @(_sent),
                        @"last_error": _lastError ?: @""};
    [_statsLock unlock];
    return d;
}

- (void)setLastError:(NSString *)message {
    [_statsLock lock];
    _lastError = [message copy];
    [_statsLock unlock];
}

- (void)countDrop {
    [_statsLock lock];
    _dropped++;
    [_statsLock unlock];
}

#pragma mark - 收包

- (void)drainPackets {
    NSMutableData *buffer = [NSMutableData dataWithLength:kXTUDPBufferSize];
    for (NSUInteger i = 0; i < kXTUDPMaxDatagramsPerEvent; i++) {
        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        ssize_t n = recvfrom(_fd, buffer.mutableBytes, kXTUDPBufferSize, 0,
                             (struct sockaddr *)&peer, &peerLen);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
            [self setLastError:[NSString stringWithUTF8String:strerror(errno)]];
            return;
        }
        if (n == 0) continue;

        [_statsLock lock];
        _received++;
        [_statsLock unlock];

        NSData *packet = [NSData dataWithBytes:buffer.bytes length:(NSUInteger)n];
        NSData *peerData = [NSData dataWithBytes:&peer length:sizeof(peer)];
        [self handlePacket:packet peer:peerData];
    }
}

- (void)handlePacket:(NSData *)packet peer:(NSData *)peerData {
    NSError *jsonError = nil;
    id parsed = nil;
    @try {
        parsed = [NSJSONSerialization JSONObjectWithData:packet options:0 error:&jsonError];
    } @catch (NSException *exception) {
        parsed = nil;
    }
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        [self countDrop];
        [self setLastError:@"invalid_json"];
        NSMutableDictionary *err = [@{@"cmd": @"error", @"reason": @"invalid_json"} mutableCopy];
        err[@"detail"] = jsonError.localizedDescription ?: @"";
        [self sendJSON:err toAddress:peerData];
        return;
    }

    NSDictionary *command = (NSDictionary *)parsed;
    NSString *token = command[@"token"];
    if (![token isKindOfClass:[NSString class]] || ![token isEqualToString:_token]) {
        [self countDrop];
        [self setLastError:@"unauthorized"];
        NSMutableDictionary *err = [@{@"cmd": @"error", @"reason": @"unauthorized"} mutableCopy];
        if (command[@"seq"]) err[@"seq"] = command[@"seq"];
        [self sendJSON:err toAddress:peerData];
        return;
    }

    BOOL handled = [self executeCommand:command onReply:^(NSDictionary *reply) {
        [self sendJSON:reply toAddress:peerData];
    }];
    if (!handled) {
        [self countDrop];
        [self setLastError:@"unknown_command"];
        NSMutableDictionary *err = [@{@"cmd": @"error", @"reason": @"unknown_command"} mutableCopy];
        if (command[@"seq"]) err[@"seq"] = command[@"seq"];
        [self sendJSON:err toAddress:peerData];
    }
}

#pragma mark - 发送

- (BOOL)sendBytes:(const void *)bytes length:(NSUInteger)length toAddress:(NSData *)address {
    if (!address || address.length != sizeof(struct sockaddr_in) || !bytes || length == 0) return NO;
    if (_fd < 0 || !_running) return NO;
    ssize_t n = sendto(_fd, bytes, length, 0,
                       (const struct sockaddr *)address.bytes, (socklen_t)address.length);
    if (n < 0) {
        [self setLastError:[NSString stringWithUTF8String:strerror(errno)]];
        return NO;
    }
    [_statsLock lock];
    _sent++;
    [_statsLock unlock];
    return YES;
}

- (BOOL)sendJSON:(NSDictionary<NSString *, id> *)obj toAddress:(NSData *)address {
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!json || json.length > 60000) return NO;
    return [self sendBytes:json.bytes length:json.length toAddress:address];
}

#pragma mark - 动作分发（UDP 与云控共用）

- (BOOL)executeCommand:(NSDictionary<NSString *, id> *)command {
    return [self executeCommand:command onReply:nil];
}

- (BOOL)executeCommand:(NSDictionary<NSString *, id> *)command
               onReply:(XTUDPCommandReplyBlock)reply {
    if (![command isKindOfClass:[NSDictionary class]]) return NO;

    // 兼容参照对象 {type:"touch/down", body:{...}} 与简单 {cmd:"down", x:..} 两种写法
    NSDictionary *body = [command[@"body"] isKindOfClass:[NSDictionary class]] ? command[@"body"] : command;
    NSString *raw = command[@"cmd"] ?: command[@"type"] ?: command[@"mode"] ?: @"";
    NSString *cmd = [[raw description] lowercaseString];
    id seq = command[@"seq"] ?: body[@"seq"];

    XTTouchSynthesizer *touch = [XTTouchSynthesizer sharedInstance];

    if ([cmd isEqualToString:@"ping"] || [cmd isEqualToString:@"heart"]) {
        if (reply) {
            NSMutableDictionary *pong = [NSMutableDictionary dictionaryWithObject:@"pong" forKey:@"cmd"];
            if (seq) pong[@"seq"] = seq;
            reply(pong);
        }
        return YES;
    }

    if ([cmd isEqualToString:@"tap"] || [cmd isEqualToString:@"touch/tap"]) {
        [touch tapAtX:XTNumber(body[@"x"], 0) y:XTNumber(body[@"y"], 0)];
        return YES;
    }
    if ([cmd isEqualToString:@"down"] || [cmd isEqualToString:@"touch/down"]) {
        [touch touchDown:XTNumber(body[@"x"], 0) y:XTNumber(body[@"y"], 0)
                      id:XTFinger(body[@"id"] ?: body[@"finger"], 1)];
        return YES;
    }
    if ([cmd isEqualToString:@"move"] || [cmd isEqualToString:@"touch/move"]) {
        [touch touchMove:XTNumber(body[@"x"], 0) y:XTNumber(body[@"y"], 0)
                      id:XTFinger(body[@"id"] ?: body[@"finger"], 1)];
        return YES;
    }
    if ([cmd isEqualToString:@"up"] || [cmd isEqualToString:@"touch/up"]) {
        [touch touchUp:XTNumber(body[@"x"], 0) y:XTNumber(body[@"y"], 0)
                    id:XTFinger(body[@"id"] ?: body[@"finger"], 1)];
        return YES;
    }

    if ([cmd isEqualToString:@"key"] || [cmd hasPrefix:@"key/"]) {
        NSString *key = body[@"key"] ?: body[@"code"] ?: body[@"name"] ?: @"";
        if ([cmd isEqualToString:@"key/down"])      [touch keyDown:key];
        else if ([cmd isEqualToString:@"key/up"])   [touch keyUp:key];
        else                                        [touch pressKey:key];
        return YES;
    }
    if ([cmd isEqualToString:@"text"] || [cmd isEqualToString:@"input"]) {
        NSString *text = body[@"text"] ?: body[@"content"] ?: @"";
        [touch inputText:[text description]];
        return YES;
    }

    if ([cmd isEqualToString:@"script"] || [cmd hasPrefix:@"script/"]) {
        NSString *source = body[@"source"];
        NSString *name   = body[@"name"] ?: body[@"script"] ?: body[@"file"];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            XTScriptEngine *engine = [XTScriptEngine sharedInstance];
            NSDictionary *result = nil;
            if ([source isKindOfClass:[NSString class]] && [source length] > 0) {
                result = [engine runSource:source];
            } else if ([name isKindOfClass:[NSString class]] && [name length] > 0) {
                result = [engine runScriptNamed:name];
            } else {
                result = @{@"code": @(-1), @"message": @"missing script source or name"};
            }
            if (reply) {
                NSMutableDictionary *r = [@{@"cmd": @"script_result",
                                            @"result": result ?: @{}} mutableCopy];
                if (seq) r[@"seq"] = seq;
                reply(r);
            }
        });
        return YES;
    }

    if ([cmd isEqualToString:@"screen"] || [cmd isEqualToString:@"screen/snapshot"]) {
        [self sendScreenWithCommand:command reply:reply];
        return YES;
    }

    return NO;
}

#pragma mark - 截图分包

- (void)sendScreenWithCommand:(NSDictionary *)command reply:(XTUDPCommandReplyBlock)reply {
    if (!reply) return;
    id seq = [command[@"seq"] copy];
    XTUDPCommandReplyBlock safeReply = [reply copy];

    // 大帧处理全部丢到后台队列，避免阻塞 UDP 收包队列；截图本身再切回主线程
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __block NSString *path = nil;
        if ([NSThread isMainThread]) {
            path = [[XTCapture sharedInstance] captureScreen];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                path = [[XTCapture sharedInstance] captureScreen];
            });
        }
        NSData *png = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (!png) {
            NSMutableDictionary *err = [@{@"cmd": @"error", @"reason": @"capture_failed"} mutableCopy];
            if (seq) err[@"seq"] = seq;
            safeReply(err);
            return;
        }

        NSArray<NSData *> *chunks = XTChunkData(png, kXTUDPChunkBytes);
        NSUInteger total = chunks.count;
        for (NSUInteger i = 0; i < total; i++) {
            NSMutableDictionary *packet = [@{@"seq": @(i + 1),
                                             @"total": @(total),
                                             @"data": [chunks[i] base64EncodedStringWithOptions:0]} mutableCopy];
            if (seq) packet[@"req_seq"] = seq;
            safeReply(packet);
        }
        XTLog(@"[XAutouch] UDP 截图回包 %lu 片", (unsigned long)total);
    });
}

@end
