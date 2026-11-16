/**
 * XTHTTPServer.mm - 本地 HTTP/1.1 控制服务（网络层）
 *
 * 零第三方依赖：BSD socket + GCD。完整实现：
 *   - 分块读取请求直到 Content-Length 满足（支持大 body / deb 上传）
 *   - query string / form / JSON / multipart 解析
 *   - 二进制响应（截图 PNG、静态 Web 资源），Content-Length 按字节计算
 *   - CORS（与 user_conf.allow_cors 联动）
 *   - SSE 日志流 /api/log/stream
 *   - WebSocket 升级与控制帧（cc.js 控制通道）
 *
 * 路由实现见 XTRoutes.mm（XTHTTPServer+XTRoutes category）。
 */
#import "XTHTTPServer.h"
#import "XTApplication.h"
#import "XTLogger.h"
#import "XTScreenShare.h"
#import "XTUDPControl.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <time.h>
#import <CommonCrypto/CommonDigest.h>

// 注：dispatchRequest: 的实现在 XTRoutes.mm 的 category 中。
// 主实现文件不重复声明该 selector，由 CFLAGS 的 -Wno-incomplete-implementation
// 抑制 clang 对跨文件 category 实现的误报。

#pragma mark - XTHTTPRequest

@implementation XTHTTPRequest {
    NSDictionary *_queryCache;
    NSDictionary *_formCache;
    NSDictionary *_multipartCache;
}

- (NSString *)body {
    if (!_bodyData) return @"";
    return [[NSString alloc] initWithData:_bodyData encoding:NSUTF8StringEncoding] ?: @"";
}

- (NSDictionary<NSString *, id> *)query {
    if (_queryCache) return _queryCache;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSArray *parts = [self.path componentsSeparatedByString:@"?"];
    if (parts.count > 1) {
        for (NSString *pair in [parts[1] componentsSeparatedByString:@"&"]) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count < 2) continue;
            NSString *k = [kv[0] stringByRemovingPercentEncoding] ?: kv[0];
            NSString *v = [[kv[1] stringByReplacingOccurrencesOfString:@"+" withString:@" "]
                           stringByRemovingPercentEncoding] ?: kv[1];
            out[k] = v;
        }
    }
    _queryCache = out;
    return out;
}

- (NSDictionary<NSString *, id> *)form {
    if (_formCache) return _formCache;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *ct = self.headers[@"Content-Type"] ?: self.headers[@"content-type"] ?: @"";
    if ([ct containsString:@"application/x-www-form-urlencoded"]) {
        for (NSString *pair in [self.body componentsSeparatedByString:@"&"]) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count < 2) continue;
            NSString *k = [kv[0] stringByRemovingPercentEncoding] ?: kv[0];
            NSString *v = [[kv[1] stringByReplacingOccurrencesOfString:@"+" withString:@" "]
                           stringByRemovingPercentEncoding] ?: kv[1];
            out[k] = v;
        }
    }
    _formCache = out;
    return out;
}

- (id)jsonObject {
    if (!_bodyData) return nil;
    return [NSJSONSerialization JSONObjectWithData:_bodyData options:0 error:nil];
}

/// multipart/form-data 解析：返回 @{field : @{@"filename":..., @"data":NSData, ...}}
- (NSDictionary *)multipartParts {
    if (_multipartCache) return _multipartCache;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *ct = self.headers[@"Content-Type"] ?: self.headers[@"content-type"] ?: @"";
    NSString *boundary = nil;
    NSRange br = [ct rangeOfString:@"boundary="];
    if (br.location != NSNotFound) {
        boundary = [[ct substringFromIndex:br.location + br.length]
                    componentsSeparatedByString:@";"].firstObject;
        boundary = [boundary stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (boundary.length) {
        NSString *text = [[NSString alloc] initWithData:_bodyData encoding:NSUTF8StringEncoding];
        NSString *delim = [NSString stringWithFormat:@"--%@", boundary];
        for (NSString *chunk in [text componentsSeparatedByString:delim]) {
            if (![chunk containsString:@"Content-Disposition:"]) continue;
            NSRange hb = [chunk rangeOfString:@"\r\n\r\n"];
            if (hb.location == NSNotFound) continue;
            NSString *hd = [chunk substringToIndex:hb.location];
            NSData *payload = [_bodyData subdataWithRange:NSMakeRange(hb.location + 4,
                                    _bodyData.length - hb.location - 4)];
            // 去掉结尾 CRLF
            if (payload.length >= 2) {
                const char *bytes = (const char *)payload.bytes;
                if (bytes[payload.length-2] == '\r' && bytes[payload.length-1] == '\n') {
                    payload = [payload subdataWithRange:NSMakeRange(0, payload.length-2)];
                }
            }
            NSString *field = nil, *filename = nil;
            for (NSString *line in [hd componentsSeparatedByString:@"\r\n"]) {
                if (![line hasPrefix:@"Content-Disposition:"]) continue;
                NSRange nr = [line rangeOfString:@"name=\""];
                if (nr.location != NSNotFound) {
                    NSUInteger s = nr.location + nr.length;
                    NSRange e = [line rangeOfString:@"\"" options:0 range:NSMakeRange(s, line.length-s)];
                    if (e.location != NSNotFound) field = [line substringWithRange:NSMakeRange(s, e.location-s)];
                }
                NSRange fr = [line rangeOfString:@"filename=\""];
                if (fr.location != NSNotFound) {
                    NSUInteger s = fr.location + fr.length;
                    NSRange e = [line rangeOfString:@"\"" options:0 range:NSMakeRange(s, line.length-s)];
                    if (e.location != NSNotFound) filename = [line substringWithRange:NSMakeRange(s, e.location-s)];
                }
            }
            if (field.length) {
                out[field] = @{@"filename": filename ?: @"", @"data": payload,
                               @"content-type": hd ?: @""};
            }
        }
    }
    _multipartCache = out;
    return out;
}

- (id)valueForKey:(NSString *)key {
    id v = self.query[key];
    if (v) return v;
    v = self.form[key];
    if (v) return v;
    id jv = [self jsonObject];
    if ([jv isKindOfClass:[NSDictionary class]] && jv[key]) return jv[key];
    NSDictionary *part = [self multipartParts][key];
    if (part) return ((NSDictionary *)part)[@"data"];
    return nil;
}

- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)def {
    id v = [self valueForKey:key];
    if (!v) return def;
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    if ([v isKindOfClass:[NSData class]])
        return [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding] ?: def;
    return [v description] ?: def;
}

- (double)doubleForKey:(NSString *)key defaultValue:(double)def {
    id v = [self valueForKey:key];
    if (!v) return def;
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def;
}

- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def {
    id v = [self valueForKey:key];
    if (!v) return def;
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : def;
}

- (NSDictionary *)filePartForField:(NSString *)field {
    NSDictionary *part = [self multipartParts][field];
    if ([part isKindOfClass:[NSDictionary class]]) return part;
    return nil;
}
@end

#pragma mark - XTHTTPResponse

@implementation XTHTTPResponse
- (instancetype)init { self = [super init]; if (self) { _statusCode = 200; _contentType = @"application/json; charset=utf-8"; } return self; }
+ (instancetype)json:(id)obj {
    XTHTTPResponse *r = [self new];
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj ?: @{} options:0 error:nil];
    r.body = d ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}
+ (instancetype)text:(NSString *)text {
    XTHTTPResponse *r = [self new];
    r.contentType = @"text/plain; charset=utf-8";
    r.body = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    return r;
}
+ (instancetype)data:(NSData *)data contentType:(NSString *)ct {
    XTHTTPResponse *r = [self new];
    r.contentType = ct;
    r.body = data ?: [NSData data];
    return r;
}
+ (instancetype)error:(NSInteger)code message:(NSString *)msg {
    XTHTTPResponse *r = [self json:@{@"code":@(code), @"message":msg ?: @"error"}];
    r.statusCode = code;
    return r;
}
@end

#pragma mark - XTHTTPServer

@implementation XTHTTPServer {
    int _listenFd;
    dispatch_queue_t _queue;
    dispatch_queue_t _sseQueue;
    NSMutableArray<NSNumber *> *_sseClients;
    BOOL _running;
    UInt16 _port;
}

+ (instancetype)sharedInstance {
    static XTHTTPServer *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.xautouch.http", DISPATCH_QUEUE_CONCURRENT);
        _sseQueue = dispatch_queue_create("com.xautouch.http.sse", DISPATCH_QUEUE_SERIAL);
        _sseClients = [NSMutableArray array];
        _listenFd = -1;
        _port = 46899;
        _corsEnabled = YES;
    }
    return self;
}

- (void)startOnPort:(UInt16)port {
    if (_running) return;
    _port = port;
    _listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenFd < 0) { XTLog(@"[XAutouch] socket 失败: %s", strerror(errno)); return; }
    int yes = 1;
    setsockopt(_listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(_listenFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        XTLog(@"[XAutouch] 绑定 %d 失败: %s", port, strerror(errno));
        close(_listenFd); _listenFd = -1; return;
    }
    listen(_listenFd, 64);
    _running = YES;
    XTLog(@"[XAutouch] HTTP 服务已启动 :%d", port);

    dispatch_async(_queue, ^{
        while (self->_running) {
            struct sockaddr_in client;
            socklen_t clen = sizeof(client);
            int fd = accept(self->_listenFd, (struct sockaddr *)&client, &clen);
            if (fd < 0) { if (!self->_running) break; continue; }
            int nodelay = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
            dispatch_async(self->_queue, ^{ [self handleClient:fd]; });
        }
    });
}

- (void)stop {
    _running = NO;
    if (_listenFd >= 0) { close(_listenFd); _listenFd = -1; }
    dispatch_sync(_sseQueue, ^{
        for (NSNumber *n in _sseClients) close(n.intValue);
        [_sseClients removeAllObjects];
    });
}

#pragma mark - 连接处理

/// 读到 \r\n\r\n 或超时；返回 header 数据长度
static ssize_t XTReadHeaders(int fd, NSMutableData *buf) {
    char chunk[4096];
    while (buf.length < 1024 * 1024) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) return n;
        [buf appendBytes:chunk length:n];
        NSData *needle = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        NSRange r = [buf rangeOfData:needle options:0 range:NSMakeRange(0, buf.length)];
        if (r.location != NSNotFound) return r.location + r.length;
    }
    return -1;
}

- (void)handleClient:(int)fd {
    NSMutableData *buf = [NSMutableData data];
    ssize_t headerEnd = XTReadHeaders(fd, buf);
    if (headerEnd <= 0) { close(fd); return; }

    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, (NSUInteger)headerEnd)]
                                           encoding:NSUTF8StringEncoding] ?: @"";
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    if (requestLine.count < 2) { close(fd); return; }

    XTHTTPRequest *req = [XTHTTPRequest new];
    req.method = requestLine[0];
    NSString *rawPath = requestLine[1];
    req.path = [rawPath stringByRemovingPercentEncoding] ?: rawPath;

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange c = [lines[i] rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        NSString *k = [lines[i] substringToIndex:c.location];
        NSString *v = [[lines[i] substringFromIndex:c.location+1]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        headers[k] = v;
    }
    req.headers = headers;

    // 按 Content-Length 补齐 body
    NSString *clStr = headers[@"Content-Length"] ?: headers[@"content-length"] ?: @"0";
    NSUInteger contentLength = (NSUInteger)[clStr integerValue];
    NSUInteger have = buf.length - (NSUInteger)headerEnd;
    if (have > contentLength) {
        req.bodyData = [buf subdataWithRange:NSMakeRange((NSUInteger)headerEnd, contentLength)];
    } else {
        NSMutableData *body = [NSMutableData dataWithData:
                               [buf subdataWithRange:NSMakeRange((NSUInteger)headerEnd, have)]];
        char chunk[16384];
        while (body.length < contentLength) {
            ssize_t n = recv(fd, chunk, MIN((size_t)sizeof(chunk), contentLength - body.length), 0);
            if (n <= 0) break;
            [body appendBytes:chunk length:(NSUInteger)n];
        }
        req.bodyData = body;
    }

    // WebSocket 升级
    if ([headers[@"Upgrade"] caseInsensitiveCompare:@"websocket"] == NSOrderedSame) {
        [self handleWebSocketHandshake:fd request:req headers:headers];
        return;
    }
    // SSE 长连接
    NSString *p = [req.path componentsSeparatedByString:@"?"].firstObject;
    if ([p isEqualToString:@"/api/log/stream"]) { [self handleSSE:fd]; return; }
    // MJPEG 屏幕流长连接（对标原版 web-screen.lua）
    if ([p isEqualToString:@"/api/screen/stream"]) { [self handleMJPEGStream:fd]; return; }

    XTHTTPResponse *resp = [self dispatchRequest:req] ?: [XTHTTPResponse error:-1 message:@"unknown route"];
    [self writeResponse:fd response:resp keepAlive:NO];
    close(fd);
}

- (void)writeResponse:(int)fd response:(XTHTTPResponse *)resp keepAlive:(BOOL)keep {
    NSString *ct = resp.contentType ?: @"application/json; charset=utf-8";
    NSMutableString *h = [NSMutableString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\n",
        (long)resp.statusCode, resp.statusCode == 200 ? @"OK" : @"Error",
        ct, (unsigned long)resp.body.length];
    if (self.corsEnabled) {
        [h appendString:@"Access-Control-Allow-Origin: *\r\n"];
        [h appendString:@"Access-Control-Allow-Methods: GET,POST,PUT,DELETE,OPTIONS\r\n"];
        [h appendString:@"Access-Control-Allow-Headers: *\r\n"];
    }
    [h appendString:@"Cache-Control: no-store\r\n"];
    if (!keep) [h appendString:@"Connection: close\r\n"];
    for (NSString *k in resp.extraHeaders) {
        [h appendFormat:@"%@: %@\r\n", k, resp.extraHeaders[k]];
    }
    [h appendString:@"\r\n"];

    NSMutableData *out = [NSMutableData dataWithData:[h dataUsingEncoding:NSUTF8StringEncoding]];
    [out appendData:resp.body];
    const char *bytes = (const char *)out.bytes;
    NSUInteger sent = 0;
    while (sent < out.length) {
        ssize_t n = send(fd, bytes + sent, out.length - sent, 0);
        if (n <= 0) break;
        sent += (NSUInteger)n;
    }
}

#pragma mark - MJPEG 屏幕流

- (void)handleMJPEGStream:(int)fd {
    const char *hdr = "HTTP/1.1 200 OK\r\n"
                      "Content-Type: multipart/x-mixed-replace; boundary=--xautouchframe\r\n"
                      "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
    if (send(fd, hdr, strlen(hdr), 0) <= 0) { close(fd); return; }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        XTScreenShare *share = [XTScreenShare sharedInstance];
        if (![share isRunning]) [share startWithFPS:15 quality:0.7];
        while (1) {
            @autoreleasepool {
                NSData *jpg = [share nextJPEGFrameWithTimeout:2.0];
                if (!jpg) break;
                NSString *partHdr = [NSString stringWithFormat:
                    @"--xautouchframe\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n\r\n",
                    (unsigned long)jpg.length];
                const char *ph = partHdr.UTF8String;
                if (send(fd, ph, strlen(ph), 0) <= 0) break;
                const unsigned char *b = (const unsigned char *)jpg.bytes;
                NSUInteger sent = 0;
                while (sent < jpg.length) {
                    ssize_t n = send(fd, b + sent, jpg.length - sent, 0);
                    if (n <= 0) break;
                    sent += (NSUInteger)n;
                }
                if (sent < jpg.length) break;
                const char *crlf = "\r\n";
                if (send(fd, crlf, 2, 0) <= 0) break;
            }
        }
        close(fd);
    });
}

#pragma mark - SSE

- (void)addSSEClient:(int)fd {
    dispatch_async(_sseQueue, ^{ [_sseClients addObject:@(fd)]; });
}

- (void)handleSSE:(int)fd {
    [self addSSEClient:fd];
    const char *hello = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                        "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
                        "data: {\"code\":0,\"message\":\"connected\"}\n\n";
    send(fd, hello, strlen(hello), 0);
    // 保活循环：客户端断开时 send 失败退出
    while (YES) {
        char probe = 0;
        ssize_t n = recv(fd, &probe, 1, MSG_PEEK | MSG_DONTWAIT);
        if (n == 0) break;
        const char *ping = ": keepalive\n\n";
        if (send(fd, ping, strlen(ping), 0) < 0) break;
        struct timespec ts = {2, 0};
        nanosleep(&ts, NULL);
    }
    dispatch_async(_sseQueue, ^{
        [_sseClients removeObject:@(fd)];
        close(fd);
    });
}

- (void)broadcastEvent:(NSString *)event data:(id)data {
    id json = data ?: @{};
    NSData *jd = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    NSString *payload = [NSString stringWithFormat:@"event: %@\ndata: %@\n\n",
                         event ?: @"message",
                         [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] ?: @"{}"];
    const char *bytes = payload.UTF8String;
    dispatch_async(_sseQueue, ^{
        NSMutableArray *dead = [NSMutableArray array];
        for (NSNumber *n in _sseClients) {
            if (send(n.intValue, bytes, strlen(bytes), 0) < 0) [dead addObject:n];
        }
        for (NSNumber *n in dead) { [_sseClients removeObject:n]; close(n.intValue); }
    });
}

#pragma mark - WebSocket (cc.js 控制通道)

static NSString *XTWebSocketAccept(NSString *key) {
    NSString *combined = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(combined.UTF8String, (CC_LONG)combined.length, digest);
    NSData *d = [NSData dataWithBytes:digest length:sizeof(digest)];
    return [d base64EncodedStringWithOptions:0];
}

- (void)handleWebSocketHandshake:(int)fd request:(XTHTTPRequest *)req headers:(NSDictionary *)h {
    NSString *key = h[@"Sec-WebSocket-Key"] ?: h[@"sec-websocket-key"] ?: @"";
    NSString *accept = XTWebSocketAccept(key);
    NSString *resp = [NSString stringWithFormat:
        @"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
        @"Connection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n", accept];
    send(fd, resp.UTF8String, resp.length, 0);
    XTLog(@"[XAutouch] WebSocket 客户端已连接 %@", req.path);

    // 简单帧循环：解掩码、UTF8 文本 -> 当作 JSON 请求分发 -> 回写文本帧
    while (YES) {
        unsigned char hdr[2];
        ssize_t n = recv(fd, hdr, 2, MSG_WAITALL);
        if (n != 2) break;
        BOOL masked = hdr[1] & 0x80;
        NSUInteger len = hdr[1] & 0x7F;
        if (len == 126) { unsigned char e[2]; if (recv(fd, e, 2, MSG_WAITALL) != 2) break;
                          len = (e[0] << 8) | e[1]; }
        else if (len == 127) { unsigned char e[8]; if (recv(fd, e, 8, MSG_WAITALL) != 8) break;
                               len = 0; for (int i=0;i<8;i++) len = (len << 8) | e[i]; }
        unsigned char mask[4] = {0};
        if (masked && recv(fd, mask, 4, MSG_WAITALL) != 4) break;
        NSMutableData *payload = [NSMutableData dataWithLength:len];
        if (recv(fd, payload.mutableBytes, len, MSG_WAITALL) != (ssize_t)len) break;
        if (masked) {
            unsigned char *p = (unsigned char *)payload.mutableBytes;
            for (NSUInteger i=0;i<len;i++) p[i] ^= mask[i%4];
        }
        NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] ?: @"";
        XTHTTPRequest *wr = [XTHTTPRequest new];
        wr.method = @"POST"; wr.path = text; wr.bodyData = payload;
        XTHTTPResponse *wrsp = [self dispatchRequest:wr] ?: [XTHTTPResponse error:-1 message:@"unknown"];

        NSMutableData *frame = [NSMutableData data];
        unsigned char fh = 0x81;
        [frame appendBytes:&fh length:1];
        NSUInteger ol = wrsp.body.length;
        if (ol < 126) [frame appendBytes:&ol length:1];
        else { unsigned char e = 126; unsigned short be = htons((unsigned short)ol);
               [frame appendBytes:&e length:1]; [frame appendBytes:&be length:2]; }
        [frame appendData:wrsp.body];
        if (send(fd, frame.bytes, frame.length, 0) < 0) break;
    }
    close(fd);
}

@end
