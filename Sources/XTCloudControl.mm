/**
 * XTCloudControl.mm - 开放式云控客户端实现
 *
 * 使用 iOS 13+ 的 NSURLSessionWebSocketTask（Foundation 公开 API），
 * 所有 JSON 解析在 serial delegate/工作队列中完成，不占用主线程。
 * 连接失败不崩溃：只更新状态、写 plist、发 SSE，并按 2^n 退避重试。
 */
#import "XTCloudControl.h"
#import "XTApplication.h"
#import "XTHTTPServer.h"
#import "XTUDPControl.h"
#import "XTLogger.h"
#import <math.h>

static const NSTimeInterval kXTCloudHeartbeatInterval = 20.0;
static const NSUInteger kXTCloudMissedPongLimit = 3;
static const NSUInteger kXTCloudMaxRetries = 5;
static const UInt16 kXTCloudDefaultPort = 46968;

static NSString *XTCloudStateName(XTCloudConnectionState state) {
    switch (state) {
        case XTCloudConnectionStateConnecting:   return @"connecting";
        case XTCloudConnectionStateConnected:    return @"connected";
        case XTCloudConnectionStateReconnecting: return @"reconnecting";
        default:                                 return @"disconnected";
    }
}

@interface XTCloudControl () <NSURLSessionDelegate, NSURLSessionWebSocketDelegate>
- (void)setState:(XTCloudConnectionState)state;
- (void)setLastError:(NSString *)message;
- (void)persistStatus;
- (void)broadcastStatus;
- (NSUInteger)bumpGeneration;
- (BOOL)isGenerationCurrent:(NSUInteger)generation;
- (void)teardownSocket;
- (void)connectInternalWithHost:(NSString *)host port:(UInt16)port
                          token:(NSString *)token generation:(NSUInteger)gen;
- (void)scheduleHeartbeat:(NSUInteger)gen;
- (void)pumpMessages:(NSURLSessionWebSocketTask *)task generation:(NSUInteger)gen;
- (void)handleMessage:(NSString *)text generation:(NSUInteger)gen;
- (void)sendObject:(NSDictionary *)obj generation:(NSUInteger)gen;
- (void)scheduleReconnectWithReason:(NSString *)reason;
@end

@implementation XTCloudControl {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_socket;
    NSTimer *_heartbeatTimer;
    NSOperationQueue *_delegateQueue;
    dispatch_queue_t _queue;
    NSLock *_lock;

    XTCloudConnectionState _state;
    NSString *_host;
    UInt16 _port;
    NSString *_token;
    NSString *_lastError;
    NSUInteger _generation;
    NSUInteger _missedPongs;
    NSUInteger _retryCount;
    uint64_t _messagesReceived;
    uint64_t _messagesSent;
    uint64_t _reconnectCount;
}

+ (instancetype)sharedInstance {
    static XTCloudControl *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.xautouch.cloud", DISPATCH_QUEUE_SERIAL);
        _delegateQueue = [[NSOperationQueue alloc] init];
        _delegateQueue.maxConcurrentOperationCount = 1;
        _lock = [NSLock new];
        _state = XTCloudConnectionStateDisconnected;
        _port = kXTCloudDefaultPort;
        if (@available(iOS 13.0, *)) {
            _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                     delegate:self
                                                delegateQueue:_delegateQueue];
        }
    }
    return self;
}

#pragma mark - 配置

- (NSString *)configPath {
    NSString *root = [XTApplication resourceRoot] ?: @"/var/jb/usr/lib/xautouch";
    return [root stringByAppendingPathComponent:@"cloud_conf.plist"];
}

- (NSDictionary<NSString *, id> *)config {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:[self configPath]] ?: @{};
    NSMutableDictionary *d = [@{@"server": @"",
                                @"port": @(kXTCloudDefaultPort),
                                @"token": @"",
                                @"autoConnect": @NO} mutableCopy];
    [d addEntriesFromDictionary:saved];
    d[@"code"] = @0;
    return d;
}

- (BOOL)saveConfig:(NSDictionary<NSString *, id> *)config {
    if (![config isKindOfClass:[NSDictionary class]]) return NO;
    NSMutableDictionary *d = [[self config] mutableCopy];
    [d removeObjectForKey:@"code"];
    for (NSString *key in config) {
        if ([key isEqualToString:@"code"]) continue;
        d[key] = config[key] ?: @"";
    }
    NSString *path = [self configPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL ok = [d writeToFile:path atomically:YES];
    if (ok) {
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0600)}
                                         ofItemAtPath:path error:nil];
        [self broadcastStatus];
    }
    return ok;
}

- (void)startAutoConnectIfNeeded {
    NSDictionary *conf = [self config];
    NSString *server = conf[@"server"];
    NSString *token = conf[@"token"];
    if ([conf[@"autoConnect"] boolValue] && [server length] > 0 && [token length] > 0) {
        UInt16 port = (UInt16)[conf[@"port"] unsignedIntValue] ?: kXTCloudDefaultPort;
        [self connectToServer:server port:port token:token];
    }
}

#pragma mark - 状态与持久化

- (XTCloudConnectionState)state {
    [_lock lock];
    XTCloudConnectionState s = _state;
    [_lock unlock];
    return s;
}

- (NSDictionary<NSString *, id> *)status {
    [_lock lock];
    NSDictionary *d = @{@"state": XTCloudStateName(_state),
                        @"connected": @(_state == XTCloudConnectionStateConnected),
                        @"server": _host ?: @"",
                        @"port": @(_port),
                        @"retry_count": @(_retryCount),
                        @"reconnect_count": @(_reconnectCount),
                        @"missed_pongs": @(_missedPongs),
                        @"messages_received": @(_messagesReceived),
                        @"messages_sent": @(_messagesSent),
                        @"last_error": _lastError ?: @""};
    [_lock unlock];
    return d;
}

- (void)setState:(XTCloudConnectionState)state {
    [_lock lock];
    _state = state;
    [_lock unlock];
    [self persistStatus];
    [self broadcastStatus];
}

- (void)setLastError:(NSString *)message {
    [_lock lock];
    _lastError = [message copy];
    [_lock unlock];
}

- (void)persistStatus {
    NSString *root = [XTApplication resourceRoot] ?: @"/var/jb/usr/lib/xautouch";
    NSString *path = [root stringByAppendingPathComponent:@"cloud_status.plist"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [self.status writeToFile:path atomically:YES];
}

- (void)broadcastStatus {
    [[XTHTTPServer sharedInstance] broadcastEvent:@"cloud_status" data:self.status];
}

#pragma mark - generation 管理

- (NSUInteger)bumpGeneration {
    [_lock lock];
    _generation++;
    NSUInteger g = _generation;
    [_lock unlock];
    return g;
}

- (BOOL)isGenerationCurrent:(NSUInteger)generation {
    [_lock lock];
    BOOL current = (generation == _generation);
    [_lock unlock];
    return current;
}

#pragma mark - 连接 / 断开

- (BOOL)connectToServer:(NSString *)host port:(UInt16)port token:(NSString *)token {
    if (@available(iOS 13.0, *)) {
        // 低于 iOS 13 时下面类型不存在，直接给出明确错误
    } else {
        [self setLastError:@"云控需要 iOS 13 或更高版本"];
        [self broadcastStatus];
        return NO;
    }
    if ([host length] == 0 || [token length] == 0) {
        [self setLastError:@"host/token 不能为空"];
        [self broadcastStatus];
        return NO;
    }

    [self teardownSocket];
    NSUInteger gen = [self bumpGeneration];
    NSString *safeHost = [host copy];
    NSString *safeToken = [token copy];

    [_lock lock];
    _host = safeHost;
    _port = port;
    _token = safeToken;
    _retryCount = 0;
    _missedPongs = 0;
    [_lock unlock];

    dispatch_async(_queue, ^{
        [self connectInternalWithHost:safeHost port:port token:safeToken generation:gen];
    });
    return YES;
}

- (void)connectInternalWithHost:(NSString *)host
                           port:(UInt16)port
                          token:(NSString *)token
                     generation:(NSUInteger)gen {
    if (![self isGenerationCurrent:gen]) return;
    [self setState:XTCloudConnectionStateConnecting];

    NSString *encoded = [token stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLQueryAllowedCharacterSet]] ?: token;
    NSString *urlString = [NSString stringWithFormat:@"ws://%@:%u/ws?token=%@",
                           host, (unsigned)port, encoded];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        XTLog(@"[XAutouch] 云控 URL 非法: %@", urlString);
        [self setLastError:@"invalid_server_url"];
        [self setState:XTCloudConnectionStateDisconnected];
        return;
    }

    NSURLSessionWebSocketTask *task = [_session webSocketTaskWithURL:url];
    _socket = task;
    [task resume];
    [self pumpMessages:task generation:gen];
    [self scheduleHeartbeat:gen];
    XTLog(@"[XAutouch] 云控连接中 %@:%u", host, (unsigned)port);
}

- (void)disconnect {
    [self teardownSocket];
    [self bumpGeneration];
    [_lock lock];
    _retryCount = 0;
    _missedPongs = 0;
    [_lock unlock];
    [self setState:XTCloudConnectionStateDisconnected];
}

- (BOOL)isConnected { return self.state == XTCloudConnectionStateConnected; }

- (void)teardownSocket {
    NSURLSessionWebSocketTask *task = _socket;
    _socket = nil;
    if (task) {
        [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    }
    [self invalidateHeartbeat];
}

#pragma mark - 心跳

- (void)scheduleHeartbeat:(NSUInteger)gen {
    void (^work)(void) = ^{
        NSTimer *old = _heartbeatTimer;
        _heartbeatTimer = nil;
        [old invalidate];
        _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:kXTCloudHeartbeatInterval
                                                          target:self
                                                        selector:@selector(heartbeatTick:)
                                                        userInfo:@(gen)
                                                         repeats:YES];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

- (void)invalidateHeartbeat {
    NSTimer *timer = _heartbeatTimer;
    _heartbeatTimer = nil;
    if (!timer) return;
    if ([NSThread isMainThread]) [timer invalidate];
    else dispatch_async(dispatch_get_main_queue(), ^{ [timer invalidate]; });
}

- (void)heartbeatTick:(NSTimer *)timer {
    NSUInteger gen = [timer.userInfo unsignedIntegerValue];
    if (![self isGenerationCurrent:gen]) return;

    [self sendObject:@{@"cmd": @"ping"} generation:gen];

    NSUInteger missed = 0;
    [_lock lock];
    _missedPongs++;
    missed = _missedPongs;
    [_lock unlock];

    if (missed >= kXTCloudMissedPongLimit) {
        dispatch_async(_queue, ^{
            if (![self isGenerationCurrent:gen]) return;
            [self scheduleReconnectWithReason:@"heartbeat_timeout"];
        });
    }
}

#pragma mark - 重连（2^n 退避，最多 5 次）

- (void)scheduleReconnectWithReason:(NSString *)reason {
    // 必须在 _queue 中调用
    [_lock lock];
    NSUInteger retry = _retryCount;
    NSString *host = [_host copy];
    UInt16 port = _port;
    NSString *token = [_token copy];
    [_lock unlock];

    [self setLastError:reason];
    if (host.length == 0 || token.length == 0) {
        [self setState:XTCloudConnectionStateDisconnected];
        return;
    }
    if (retry >= kXTCloudMaxRetries) {
        [self setState:XTCloudConnectionStateDisconnected];
        [self setLastError:@"retry_limit_exceeded"];
        [self broadcastStatus];
        XTLog(@"[XAutouch] 云控重连次数已用尽");
        return;
    }

    [self teardownSocket];
    NSUInteger gen = [self bumpGeneration];
    double delay = pow(2.0, (double)retry);   // 1,2,4,8,16 秒

    [_lock lock];
    _retryCount = retry + 1;
    _reconnectCount++;
    [_lock unlock];
    [self setState:XTCloudConnectionStateReconnecting];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   _queue, ^{
        if (![self isGenerationCurrent:gen]) return;
        [self connectInternalWithHost:host port:port token:token generation:gen];
    });
    XTLog(@"[XAutouch] 云控 %.0f 秒后重连（第 %lu 次），原因: %@",
          delay, (unsigned long)(retry + 1), reason);
}

#pragma mark - 收发

- (void)pumpMessages:(NSURLSessionWebSocketTask *)task generation:(NSUInteger)gen {
    if (task != _socket || ![self isGenerationCurrent:gen]) return;
    __weak XTCloudControl *weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message,
                                                NSError * _Nullable error) {
        __strong XTCloudControl *self = weakSelf;
        if (!self) return;
        if (error) {
            dispatch_async(self->_queue, ^{
                if (![self isGenerationCurrent:gen]) return;
                [self setLastError:error.localizedDescription ?: @"receive_error"];
                [self scheduleReconnectWithReason:@"receive_error"];
            });
            return;
        }
        NSString *text = nil;
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            text = message.string;
        } else if (message.data) {
            text = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
        }
        if (text.length > 0) {
            dispatch_async(self->_queue, ^{
                if (![self isGenerationCurrent:gen]) return;
                [self handleMessage:text generation:gen];
            });
        }
        [self pumpMessages:task generation:gen];
    }];
}

- (void)handleMessage:(NSString *)text generation:(NSUInteger)gen {
    NSError *jsonError = nil;
    id parsed = nil;
    @try {
        parsed = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                                 options:0 error:&jsonError];
    } @catch (NSException *exception) {
        parsed = nil;
    }
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        [self setLastError:@"invalid_json"];
        return;
    }
    [_lock lock];
    _messagesReceived++;
    [_lock unlock];

    NSDictionary *message = (NSDictionary *)parsed;
    NSString *raw = message[@"cmd"] ?: message[@"type"] ?: message[@"mode"] ?: @"";
    NSString *cmd = [[raw description] lowercaseString];

    if ([cmd isEqualToString:@"ping"] || [cmd isEqualToString:@"heart"]) {
        NSMutableDictionary *pong = [NSMutableDictionary dictionaryWithObject:@"pong" forKey:@"cmd"];
        if (message[@"seq"]) pong[@"seq"] = message[@"seq"];
        [self sendObject:pong generation:gen];
        return;
    }
    if ([cmd isEqualToString:@"pong"]) {
        [_lock lock];
        _missedPongs = 0;
        [_lock unlock];
        return;
    }

    __weak XTCloudControl *weakSelf = self;
    [[XTUDPControl sharedInstance] executeCommand:message onReply:^(NSDictionary *reply) {
        [weakSelf sendObject:reply generation:gen];
    }];
}

- (void)sendObject:(NSDictionary *)obj generation:(NSUInteger)gen {
    if (![self isGenerationCurrent:gen]) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!json) return;
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (!text) return;

    NSURLSessionWebSocketTask *task = _socket;
    if (!task) return;
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
    __weak XTCloudControl *weakSelf = self;
    [task sendMessage:message completionHandler:^(NSError * _Nullable error) {
        __strong XTCloudControl *self = weakSelf;
        if (!self || !error) return;
        if (![self isGenerationCurrent:gen]) return;
        [self setLastError:error.localizedDescription ?: @"send_error"];
        dispatch_async(self->_queue, ^{
            if (![self isGenerationCurrent:gen]) return;
            [self scheduleReconnectWithReason:@"send_error"];
        });
    }];
    [_lock lock];
    _messagesSent++;
    [_lock unlock];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didOpenWithProtocol:(nullable NSString *)protocol {
    __weak XTCloudControl *weakSelf = self;
    dispatch_async(_queue, ^{
        __strong XTCloudControl *self = weakSelf;
        if (!self || webSocketTask != self->_socket) return;
        [self setState:XTCloudConnectionStateConnected];
        [self->_lock lock];
        self->_missedPongs = 0;
        self->_retryCount = 0;
        [self->_lock unlock];
        XTLog(@"[XAutouch] 云控已连接");
    });
}

- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
            reason:(nullable NSData *)reason {
    if (webSocketTask != _socket) return;  // 主动 teardown，不重连
    __weak XTCloudControl *weakSelf = self;
    dispatch_async(_queue, ^{
        __strong XTCloudControl *self = weakSelf;
        if (!self || webSocketTask != self->_socket) return;
        NSString *why = [NSString stringWithFormat:@"remote_close(%ld)", (long)closeCode];
        [self scheduleReconnectWithReason:why];
    });
}

@end
