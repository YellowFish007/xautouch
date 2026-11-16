/**
 * XTWebRTCMedia.mm - 自包含屏幕/音频实时传输层
 *
 * 设计取舍：不引入 libwebrtc（体积/依赖过大，SpringBoard 注入不现实），
 * 用 iOS 系统公开框架拼出一条真实可用的媒体链路：
 *
 *   视频：XTCapture 截图(PNG) -> CGImage -> CVPixelBuffer(BGRA) ->
 *         VTCompressionSession(H.264) -> Annex-B NALU -> 自定义帧协议分片 -> UDP
 *   音频：AVAudioEngine 麦克风 tap -> PCM -> AudioConverter(AAC) -> 同一 UDP(type=audio)
 *   控制：复用现有 /api/touch/* HTTP 路由，媒体层不重复实现
 *
 * 线程模型：
 *   _captureQueue  串行：截图 + 编码（VTCompressionSession 只在此队列创建/销毁）
 *   _audioQueue    串行：AAC 编码（AudioConverter 只在此队列使用/销毁）
 *   _socketQueue   串行：socket 创建/关闭 + sendto（_sockfd/_peerAddr 只在此队列改）
 *   VT 编码回调    系统线程：只做内存拷贝 + dispatch_async，不做任何阻塞/网络操作
 *
 * ARC：Objective-C 对象由 ARC 管理；CoreFoundation / CoreVideo / CoreMedia /
 * AudioToolbox 返回的 C 指针一律手工 CFRelease / Dispose / close。
 */

#import "XTWebRTCMedia.h"
#import "XTCapture.h"
#import "XTLogger.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#import <atomic>
#import <string.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#pragma mark - 协议常量

/** UDP 包固定头长度（字节）。字段全部按网络字节序(大端)填充。 */
static const size_t kXTPacketHeaderSize = 32;
/** 单个 UDP 数据报上限（含头），保证不超过常见链路 MTU 1200。 */
static const size_t kXTPayloadMTU = 1200;
/** 包头 magic: "XTMD" */
static const uint8_t kXTMagic[4] = {'X', 'T', 'M', 'D'};
/** payload 类型 */
static const uint8_t kXTFrameTypeVideo = 0;
static const uint8_t kXTFrameTypeAudio = 1;
/** AAC 配置：48kHz 单声道，每包 1024 帧 */
static const UInt32 kXTAACFramesPerPacket = 1024;
static const double kXTAACSampleRate = 48000.0;

/**
 * 自定义帧协议（32 字节头 + payload），布局：
 *   offset size field
 *   0      4    magic 'X''T''M''D'
 *   4      4    seq        包序号(uint32, 每发一个 datagram 递增)
 *   8      4    timestamp  微秒时间戳高 32 位(uint64 拆两半存)
 *   12     4    timestamp  微秒时间戳低 32 位
 *   16     4    naluLen    完整逻辑帧的 payload 字节数(uint32)
 *   20     4    frameId    逻辑帧编号(uint32, 用于接收端重组)
 *   24     2    fragIdx    当前分片索引(uint16, 0-based)
 *   26     2    fragCnt    总分片数(uint16)
 *   28     1    type       0=video, 1=audio
 *   29     1    flags      video: bit0=keyframe(SPS/PPS 随帧)
 *   30     2    reserved   0
 *   32     ...  payload    本分片的字节数据(<= 1200-32 = 1168)
 *
 * 任务给定的核心字段 [magic:4][seq:4][timestamp:8][naluLen:4][payload]
 * 全部保留，其中在 naluLen 与 payload 之间插入了分片/帧编号/类型控制字段以
 * 支持分片与重组。接收端重组算法见 XTWebRTCMediaREADME.md。
 */
typedef struct {
    const uint8_t *data;
    size_t length;
    size_t offset;
} XTAACContext;

#pragma mark - 私有接口（须在 C 回调之前声明，供回调调用）

@interface XTWebRTCMedia ()
- (void)handleEncodedSample:(CMSampleBufferRef)sampleBuffer;
- (void)sendFrameData:(NSData *)data type:(uint8_t)type keyframe:(BOOL)keyframe timestampUS:(uint64_t)tsUS;
- (void)sendPacket:(NSData *)packet;
- (void)captureOneFrame;
- (NSString *)capturePNGPathOnMainThread;
- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image;
- (VTCompressionSessionRef)createEncoderWithWidth:(int32_t)width height:(int32_t)height;
- (void)noteDropped;
- (void)noteEncodedFrame;
- (void)setupSocketWithHost:(NSString *)host port:(uint16_t)port;
- (void)startCaptureTimer;
- (void)startAudioCapture;
- (void)setupAACConverter;
- (void)encodePCMToAAC:(NSData *)pcm;
- (void)startSilenceFallback;
- (NSDictionary *)parseSDPJSON:(NSString *)sdp;
- (NSDictionary *)parseICE:(NSString *)candidate;
@end

#pragma mark - C 回调

/** 判断字符串是否为合法 IPv4（供 ICE candidate 解析用） */
static BOOL XTIsIPv4(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    struct in_addr a;
    return inet_pton(AF_INET, s.UTF8String, &a) == 1;
}

/** VideoToolbox 编码输出回调：系统线程调用，禁止阻塞。 */
static void XTCompressionOutputCallback(void *outputCallbackRefCon,
                                        void *sourceFrameRefCon,
                                        OSStatus status,
                                        VTEncodeInfoFlags infoFlags,
                                        CMSampleBufferRef sampleBuffer) {
    (void)sourceFrameRefCon;
    (void)infoFlags;
    if (status != noErr || sampleBuffer == NULL) return;
    XTWebRTCMedia *me = (__bridge XTWebRTCMedia *)outputCallbackRefCon;
    [me handleEncodedSample:sampleBuffer];
}

/** AudioConverter 输入回调：从 XTAACContext 提供 PCM 数据。 */
static OSStatus XTAACInputProc(AudioConverterRef inAudioConverter,
                               UInt32 *ioNumberDataPackets,
                               AudioBufferList *ioData,
                               AudioStreamPacketDescription **outDataPacketDescription,
                               void *inUserData) {
    (void)inAudioConverter;
    XTAACContext *ctx = (XTAACContext *)inUserData;
    UInt32 want = *ioNumberDataPackets;
    UInt32 avail = (UInt32)(ctx->length / sizeof(float));
    UInt32 give = (want < avail) ? want : avail;
    if (give == 0) {
        *ioNumberDataPackets = 0;
        ioData->mBuffers[0].mDataByteSize = 0;
        return noErr;
    }
    ioData->mBuffers[0].mData = (void *)(ctx->data + ctx->offset);
    ioData->mBuffers[0].mDataByteSize = give * (UInt32)sizeof(float);
    ioData->mBuffers[0].mNumberChannels = 1;
    ctx->offset += give * sizeof(float);
    *ioNumberDataPackets = give;
    if (outDataPacketDescription) *outDataPacketDescription = NULL;
    return noErr;
}

#pragma mark - 实现

@implementation XTWebRTCMedia {
    // 工作队列
    dispatch_queue_t _captureQueue;
    dispatch_queue_t _socketQueue;
    dispatch_queue_t _audioQueue;
    dispatch_source_t _captureTimer;
    dispatch_source_t _silenceTimer;

    // UDP 传输（仅 _socketQueue 访问）
    int _sockfd;
    struct sockaddr_in _peerAddr;
    BOOL _peerReady;

    // 编码器（_vtSession 仅 _captureQueue 创建/编码；_aacConverter 仅 _audioQueue 使用）
    VTCompressionSessionRef _vtSession;
    AudioConverterRef _aacConverter;
    AVAudioEngine *_audioEngine;
    BOOL _audioUseSilence;

    // 会话配置
    NSString *_host;
    uint16_t _port;
    NSInteger _fps;
    NSInteger _bitrate;
    BOOL _audioEnabled;

    // 状态标志（原子，跨线程读）
    std::atomic<BOOL> _running;
    std::atomic<uint32_t> _packetSeq;
    std::atomic<uint32_t> _frameId;

    // 统计（受 _statsLock 保护）
    NSLock *_statsLock;
    uint64_t _framesEncoded;   // 累计编码视频帧
    uint64_t _framesSent;      // 累计发送逻辑帧(video+audio)
    uint64_t _packetsSent;     // 累计 UDP 数据报
    uint64_t _bytesSent;       // 累计发送字节
    uint64_t _dropped;         // 累计丢弃
    uint64_t _fpsWindowFrames; // fps 统计窗口内帧数
    NSDate *_fpsWindowStart;
    NSDate *_statsStart;
}

// running 属性由我们自己的 atomic ivar 实现，禁止编译器再 synthesize 同名 ivar
@dynamic running;

+ (instancetype)sharedInstance {
    static XTWebRTCMedia *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _captureQueue = dispatch_queue_create("com.xautouch.rtc.capture", DISPATCH_QUEUE_SERIAL);
        _socketQueue  = dispatch_queue_create("com.xautouch.rtc.socket",  DISPATCH_QUEUE_SERIAL);
        _audioQueue   = dispatch_queue_create("com.xautouch.rtc.audio",   DISPATCH_QUEUE_SERIAL);
        _statsLock = [NSLock new];
        _sockfd = -1;
        _fps = 15;
        _bitrate = 1500000;
        _audioEnabled = YES;
        _running.store(NO);
        _statsStart = [NSDate date];
        _fpsWindowStart = [NSDate date];
    }
    return self;
}

- (void)dealloc {
    [self stopSession];
}

- (BOOL)isRunning {
    return _running.load();
}

#pragma mark - 会话生命周期

- (void)startSessionWithConfig:(NSDictionary *)config {
    if (_running.load()) [self stopSession];
    if (![config isKindOfClass:[NSDictionary class]]) return;

    // 合并简化 SDP(JSON 字符串)到配置
    NSMutableDictionary *cfg = [config mutableCopy];
    NSString *sdp = config[@"sdp"];
    if ([sdp isKindOfClass:[NSString class]] && sdp.length) {
        NSDictionary *parsed = [self parseSDPJSON:sdp];
        [cfg addEntriesFromDictionary:parsed];
    }

    NSString *host = cfg[@"host"];
    id portObj = cfg[@"port"] ?: @(5000);
    uint16_t port = (uint16_t)[portObj unsignedIntegerValue];
    if (![host isKindOfClass:[NSString class]] || host.length == 0 || port == 0) {
        XTLog(@"[XTWebRTCMedia] 启动失败：缺少合法 host/port");
        return;
    }

    _host = [host copy];
    _port = port;
    id v = cfg[@"fps"];     if (v) _fps = [v integerValue];
    v = cfg[@"bitrate"];    if (v) _bitrate = [v integerValue];
    v = cfg[@"audio"];      if (v) _audioEnabled = [v boolValue];
    if (_fps < 1) _fps = 15;
    if (_bitrate < 100000) _bitrate = 1500000;

    // 重置统计
    [_statsLock lock];
    _framesEncoded = 0;
    _framesSent = 0;
    _packetsSent = 0;
    _bytesSent = 0;
    _dropped = 0;
    _fpsWindowFrames = 0;
    _statsStart = [NSDate date];
    _fpsWindowStart = [NSDate date];
    [_statsLock unlock];

    // 建立 UDP socket（目的地址在 socketQueue 上锁定）
    [self setupSocketWithHost:_host port:port];
    if (_sockfd < 0) {
        XTLog(@"[XTWebRTCMedia] 启动失败：socket/host 无效 (%@:%d)", _host, (int)port);
        return;
    }

    if (_audioEnabled) [self startAudioCapture];
    [self startCaptureTimer];

    _running.store(YES);
    XTLog(@"[XTWebRTCMedia] 会话启动 %@:%d fps=%ld br=%ld audio=%d",
          _host, (int)port, (long)_fps, (long)_bitrate, (int)_audioEnabled);
}

- (void)stopSession {
    // 先置运行状态，阻断新任务产生
    _running.store(NO);

    // 取消定时器
    if (_captureTimer) {
        dispatch_source_cancel(_captureTimer);
        _captureTimer = nil;
    }
    if (_silenceTimer) {
        dispatch_source_cancel(_silenceTimer);
        _silenceTimer = nil;
    }

    // 停止音频引擎（tap 必须先移除）
    if (_audioEngine) {
        [_audioEngine.inputNode removeTapOnBus:0];
        [_audioEngine stop];
        _audioEngine = nil;
    }
    _audioUseSilence = NO;

    // weakSelf 避免 dealloc 路径中 block 强捕获正在释放的 self
    __weak typeof(self) weakSelf = self;

    // 在 captureQueue 上异步释放编码器：保证在途的 captureOneFrame 先完成，
    // 又不在主线程同步等待它（captureOneFrame 会同步切主线程截图，避免死锁）。
    dispatch_async(_captureQueue, ^{
        typeof(self) me = weakSelf;
        if (me && me->_vtSession) {
            VTCompressionSessionInvalidate(me->_vtSession);
            CFRelease(me->_vtSession);
            me->_vtSession = NULL;
        }
    });

    // 在 audioQueue 上同步释放转换器：tap 与静音定时器已停，等待在途编码完成后销毁
    dispatch_sync(_audioQueue, ^{
        typeof(self) me = weakSelf;
        if (me && me->_aacConverter) {
            AudioConverterDispose(me->_aacConverter);
            me->_aacConverter = NULL;
        }
    });

    // 在 socketQueue 上同步关闭 socket（本方法不会从 socketQueue 调用，无死锁风险）
    dispatch_sync(_socketQueue, ^{
        typeof(self) me = weakSelf;
        if (!me) return;
        if (me->_sockfd >= 0) {
            close(me->_sockfd);
            me->_sockfd = -1;
        }
        me->_peerReady = NO;
    });

    XTLog(@"[XTWebRTCMedia] 会话已停止");
}

#pragma mark - 统计

- (NSDictionary<NSString *, NSNumber *> *)sessionStats {
    [_statsLock lock];
    uint64_t frames = _framesSent;
    uint64_t packets = _packetsSent;
    uint64_t bytes = _bytesSent;
    uint64_t dropped = _dropped;
    uint64_t winFrames = _fpsWindowFrames;
    NSDate *winStart = _fpsWindowStart;
    NSDate *start = _statsStart;
    [_statsLock unlock];

    NSDate *now = [NSDate date];
    double winElapsed = [now timeIntervalSinceDate:winStart];
    if (winElapsed < 0.1) winElapsed = 0.1;
    double fps = (double)winFrames / winElapsed;

    double totalElapsed = [now timeIntervalSinceDate:start];
    if (totalElapsed < 0.1) totalElapsed = 0.1;
    double bitrate = (double)bytes * 8.0 / totalElapsed;

    return @{
        @"running":     @(_running.load()),
        @"fps":         @(fps),
        @"bitrate":     @(bitrate),
        @"framesSent":  @(frames),
        @"packetsSent": @(packets),
        @"bytesSent":   @(bytes),
        @"dropped":     @(dropped)
    };
}

- (void)noteDropped {
    [_statsLock lock];
    _dropped++;
    [_statsLock unlock];
}

- (void)noteEncodedFrame {
    [_statsLock lock];
    _fpsWindowFrames++;
    NSDate *now = [NSDate date];
    if ([now timeIntervalSinceDate:_fpsWindowStart] >= 1.0) {
        _fpsWindowStart = now;
        _fpsWindowFrames = 1;
    }
    [_statsLock unlock];
}

#pragma mark - SDP / ICE 解析

- (NSDictionary *)parseSDPJSON:(NSString *)sdp {
    if (![sdp isKindOfClass:[NSString class]] || sdp.length == 0) return @{};
    NSData *data = [sdp dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    // 兼容直接 "host:port" 形式
    if ([sdp rangeOfString:@" "].location == NSNotFound && [sdp containsString:@":"]) {
        NSArray *parts = [sdp componentsSeparatedByString:@":"];
        if (parts.count == 2 && XTIsIPv4(parts[0])) {
            return @{@"host": parts[0], @"port": parts[1]};
        }
    }
    return @{};
}

- (NSDictionary *)parseICE:(NSString *)candidate {
    if (![candidate isKindOfClass:[NSString class]] || candidate.length == 0) return nil;
    // 标准格式：candidate:<foundation> <comp> <transport> <prio> <addr> <port> typ <type>
    NSArray *toks = [candidate componentsSeparatedByString:@" "];
    for (NSInteger i = 0; i + 1 < (NSInteger)toks.count; i++) {
        NSString *tok = toks[i];
        if (XTIsIPv4(tok)) {
            NSInteger pv = [toks[i + 1] integerValue];
            if (pv > 0 && pv <= 65535) {
                return @{@"host": tok, @"port": @(pv)};
            }
        }
    }
    // 兼容 host:port 形式
    if ([candidate rangeOfString:@" "].location == NSNotFound && [candidate containsString:@":"]) {
        NSArray *parts = [candidate componentsSeparatedByString:@":"];
        if (parts.count == 2 && XTIsIPv4(parts[0])) {
            NSInteger pv = [parts[1] integerValue];
            if (pv > 0 && pv <= 65535) {
                return @{@"host": parts[0], @"port": @(pv)};
            }
        }
    }
    return nil;
}

- (void)handleRemoteMessage:(NSDictionary *)msg {
    if (![msg isKindOfClass:[NSDictionary class]]) return;
    NSString *type = msg[@"type"] ?: @"";

    if ([type isEqualToString:@"answer"]) {
        NSString *sdp = msg[@"sdp"] ?: msg[@"answer"] ?: @"";
        NSDictionary *cfg = [self parseSDPJSON:sdp];
        if (cfg.count) [self startSessionWithConfig:cfg];
    } else if ([type isEqualToString:@"ice"]) {
        NSString *cand = msg[@"candidate"] ?: @"";
        NSDictionary *addr = [self parseICE:cand];
        if (!addr) return;
        NSString *host = addr[@"host"];
        uint16_t port = (uint16_t)[addr[@"port"] unsignedIntegerValue];
        __weak typeof(self) weakSelf = self;
        dispatch_async(_socketQueue, ^{
            typeof(self) me = weakSelf;
            if (!me) return;
            struct sockaddr_in na;
            memset(&na, 0, sizeof(na));
            na.sin_family = AF_INET;
            na.sin_port = htons(port);
            if (inet_pton(AF_INET, host.UTF8String, &na.sin_addr) == 1) {
                memcpy(&me->_peerAddr, &na, sizeof(na));
                me->_peerReady = YES;
            }
        });
    } else if ([type isEqualToString:@"stop"]) {
        [self stopSession];
    }
}

#pragma mark - Socket

- (void)setupSocketWithHost:(NSString *)host port:(uint16_t)port {
    __weak typeof(self) weakSelf = self;
    dispatch_sync(_socketQueue, ^{
        typeof(self) me = weakSelf;
        if (!me) return;
        int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd < 0) { me->_sockfd = -1; return; }
        // 非阻塞：sendto 在拥堵时返回 EAGAIN，不阻塞 socketQueue
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        if (inet_pton(AF_INET, host.UTF8String, &addr.sin_addr) != 1) {
            close(fd);
            me->_sockfd = -1;
            return;
        }
        memcpy(&me->_peerAddr, &addr, sizeof(addr));
        me->_peerReady = YES;
        me->_sockfd = fd;
    });
}

- (void)sendPacket:(NSData *)packet {
    // 仅 _socketQueue 调用
    if (_sockfd < 0 || !_peerReady || packet.length == 0) return;
    ssize_t n = sendto(_sockfd, packet.bytes, packet.length, 0,
                       (const struct sockaddr *)&_peerAddr, sizeof(_peerAddr));
    [_statsLock lock];
    if (n > 0) {
        _packetsSent++;
        _bytesSent += (uint64_t)n;
    } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        _dropped++;
    }
    [_statsLock unlock];
}

#pragma mark - 视频采集与编码

- (void)startCaptureTimer {
    if (_captureTimer) {
        dispatch_source_cancel(_captureTimer);
        _captureTimer = nil;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _captureQueue);
    uint64_t interval = (uint64_t)((1.0 / (double)MAX(1, (int)_fps)) * (double)NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 4);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) me = weakSelf;
        if (me && me->_running.load()) [me captureOneFrame];
    });
    _captureTimer = timer;
    dispatch_resume(timer);
}

- (NSString *)capturePNGPathOnMainThread {
    // UIScreen 私有截图 API 要求主线程；非主线程时同步切回主线程，避免死锁。
    if ([NSThread isMainThread]) {
        return [[XTCapture sharedInstance] captureScreen];
    }
    __block NSString *path = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        path = [[XTCapture sharedInstance] captureScreen];
    });
    return path;
}

- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0) return NULL;

    // 优先 IOSurface-backed（VT 编码零拷贝）；失败则退回普通 CVPixelBuffer
    NSDictionary *attrs = @{(__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef px = NULL;
    CVReturn rv = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)attrs, &px);
    if (rv != kCVReturnSuccess || px == NULL) {
        rv = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                 kCVPixelFormatType_32BGRA, NULL, &px);
    }
    if (rv != kCVReturnSuccess || px == NULL) return NULL;

    if (CVPixelBufferLockBaseAddress(px, 0) != kCVReturnSuccess) {
        CFRelease(px);
        return NULL;
    }
    void *base = CVPixelBufferGetBaseAddress(px);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(px);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    // BGRA 字节序对应 kCGBitmapByteOrder32Little + AlphaPremultipliedFirst
    CGContextRef ctx = CGBitmapContextCreate(base, width, height, 8, bytesPerRow, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(px, 0);
    return px;   // 返回 +1 retain，由调用方 CFRelease
}

- (VTCompressionSessionRef)createEncoderWithWidth:(int32_t)width height:(int32_t)height {
    VTCompressionSessionRef session = NULL;
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault,
                                             width, height,
                                             kCMVideoCodecType_H264,
                                             NULL, NULL, NULL,
                                             &XTCompressionOutputCallback,
                                             (__bridge void *)self,
                                             &session);
    if (st != noErr || session == NULL) return NULL;

    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Baseline_AutoLevel);

    int32_t br = (int32_t)_bitrate;
    CFNumberRef brNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &br);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, brNum);
    CFRelease(brNum);

    int32_t fps = (int32_t)_fps;
    CFNumberRef fpsNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &fps);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsNum);
    CFRelease(fpsNum);

    // 关键帧间隔 = 2 秒，便于接收端快速起播
    int32_t keyInterval = (int32_t)(_fps * 2);
    CFNumberRef kiNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyInterval);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, kiNum);
    CFRelease(kiNum);

    VTCompressionSessionPrepareToEncodeFrames(session);
    return session;
}

- (void)captureOneFrame {
    @autoreleasepool {
        // 1) 截图 -> CGImage
        NSString *pngPath = [self capturePNGPathOnMainThread];
        if (pngPath.length == 0) { [self noteDropped]; return; }
        NSURL *url = [NSURL fileURLWithPath:pngPath];
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        CGImageRef cgImage = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        if (src) CFRelease(src);
        // 截图是临时文件，读完即删，避免 captures 目录堆积
        [[NSFileManager defaultManager] removeItemAtPath:pngPath error:nil];
        if (!cgImage) { [self noteDropped]; return; }

        // 2) CGImage -> CVPixelBuffer
        CVPixelBufferRef px = [self pixelBufferFromCGImage:cgImage];
        CGImageRelease(cgImage);
        if (!px) { [self noteDropped]; return; }

        // 3) 懒创建编码器（尺寸取第一帧）
        if (!_vtSession) {
            int32_t w = (int32_t)CVPixelBufferGetWidth(px);
            int32_t h = (int32_t)CVPixelBufferGetHeight(px);
            _vtSession = [self createEncoderWithWidth:w height:h];
        }
        if (!_vtSession) {
            CFRelease(px);
            [self noteDropped];
            return;
        }

        // 4) 编码（timescale=1e6，便于直接得到微秒时间戳）
        CMTime ts = CMTimeMakeWithSeconds(CFAbsoluteTimeGetCurrent(), 1000000);
        OSStatus st = VTCompressionSessionEncodeFrame(_vtSession, px, ts, kCMTimeInvalid,
                                                      NULL, NULL, NULL);
        CFRelease(px);
        if (st != noErr) {
            [self noteDropped];
        } else {
            [_statsLock lock];
            _framesEncoded++;
            [_statsLock unlock];
            [self noteEncodedFrame];
        }
    }
}

- (void)handleEncodedSample:(CMSampleBufferRef)sampleBuffer {
    // 系统编码线程调用：只做内存拷贝 + 异步投递，不调用 sendto / 锁外阻塞操作
    @autoreleasepool {
        // 关键帧判定
        BOOL keyframe = NO;
        CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
        if (atts && CFArrayGetCount(atts) > 0) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(atts, 0);
            keyframe = !CFDictionaryContainsKey(d, kCMSampleAttachmentKey_NotSync);
        }

        NSMutableData *annexB = [NSMutableData dataWithCapacity:4096];
        static const uint8_t startCode[4] = {0x00, 0x00, 0x00, 0x01};

        // 关键帧头部写 SPS/PPS（Annex-B start code 前缀）
        if (keyframe) {
            CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
            if (fmt) {
                const uint8_t *sps = NULL; size_t spsLen = 0;
                const uint8_t *pps = NULL; size_t ppsLen = 0;
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &spsLen, NULL, NULL);
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &ppsLen, NULL, NULL);
                if (sps && spsLen > 0) {
                    [annexB appendBytes:startCode length:4];
                    [annexB appendBytes:sps length:spsLen];
                }
                if (pps && ppsLen > 0) {
                    [annexB appendBytes:startCode length:4];
                    [annexB appendBytes:pps length:ppsLen];
                }
            }
        }

        // 视频数据：VT 默认输出 AVCC（4 字节大端长度前缀），逐 NALU 换成 Annex-B start code
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
        if (!block) return;
        size_t total = 0;
        char *ptr = NULL;
        if (CMBlockBufferGetDataPointer(block, 0, NULL, &total, &ptr) != noErr || !ptr) return;
        const uint8_t *bytes = (const uint8_t *)ptr;
        size_t off = 0;
        while (off + 4 <= total) {
            uint32_t nlen = ((uint32_t)bytes[off] << 24) | ((uint32_t)bytes[off + 1] << 16) |
                            ((uint32_t)bytes[off + 2] << 8)  | (uint32_t)bytes[off + 3];
            off += 4;
            if (nlen == 0 || off + nlen > total) break;
            [annexB appendBytes:startCode length:4];
            [annexB appendBytes:(bytes + off) length:nlen];
            off += nlen;
        }

        // 时间戳（优先用 CMSampleBuffer 的 PTS，回退到当前时间）
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        Float64 sec = CMTimeGetSeconds(pts);
        uint64_t tsUS = (sec > 0) ? (uint64_t)(sec * 1000000.0)
                                  : (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000000.0);

        if (annexB.length > 0) {
            [self sendFrameData:annexB type:kXTFrameTypeVideo keyframe:keyframe timestampUS:tsUS];
        }
    }
}

#pragma mark - 分片发送

- (void)sendFrameData:(NSData *)data type:(uint8_t)type keyframe:(BOOL)keyframe timestampUS:(uint64_t)tsUS {
    if (data.length == 0) return;
    const NSUInteger maxPayload = kXTPayloadMTU - kXTPacketHeaderSize;  // 1168
    NSUInteger total = data.length;
    uint16_t fragCnt = (uint16_t)((total + maxPayload - 1) / maxPayload);
    if (fragCnt == 0) fragCnt = 1;

    uint32_t fid = _frameId.fetch_add(1, std::memory_order_relaxed);
    const uint8_t *bytes = data.bytes;
    uint32_t tsHi = htonl((uint32_t)(tsUS >> 32));
    uint32_t tsLo = htonl((uint32_t)(tsUS & 0xFFFFFFFFULL));
    uint32_t nlenBE = htonl((uint32_t)total);
    uint32_t fidBE = htonl(fid);

    [_statsLock lock];
    _framesSent++;
    [_statsLock unlock];

    for (uint16_t idx = 0; idx < fragCnt; idx++) {
        NSUInteger off = (NSUInteger)idx * maxPayload;
        NSUInteger len = MIN(maxPayload, total - off);

        uint8_t hdr[kXTPacketHeaderSize];
        memset(hdr, 0, sizeof(hdr));
        hdr[0] = kXTMagic[0]; hdr[1] = kXTMagic[1]; hdr[2] = kXTMagic[2]; hdr[3] = kXTMagic[3];

        uint32_t seq = _packetSeq.fetch_add(1, std::memory_order_relaxed);
        uint32_t seqBE = htonl(seq);
        memcpy(hdr + 4,  &seqBE, 4);
        memcpy(hdr + 8,  &tsHi,  4);
        memcpy(hdr + 12, &tsLo,  4);
        memcpy(hdr + 16, &nlenBE, 4);
        memcpy(hdr + 20, &fidBE, 4);
        uint16_t idxBE = htons(idx);
        uint16_t cntBE = htons(fragCnt);
        memcpy(hdr + 24, &idxBE, 2);
        memcpy(hdr + 26, &cntBE, 2);
        hdr[28] = type;
        hdr[29] = (type == kXTFrameTypeVideo && keyframe) ? 1 : 0;
        // 30..31 reserved 保持 0

        NSMutableData *pkt = [NSMutableData dataWithCapacity:kXTPacketHeaderSize + len];
        [pkt appendBytes:hdr length:kXTPacketHeaderSize];
        [pkt appendBytes:(bytes + off) length:len];

        // 编码回调/音频线程不直接 sendto，异步投递到 socketQueue（无阻塞）
        __weak typeof(self) weakSelf = self;
        dispatch_async(_socketQueue, ^{
            [weakSelf sendPacket:pkt];
        });
    }
}

#pragma mark - 音频采集与 AAC 编码

- (void)setupAACConverter {
    // 输入：单声道 Float32 非交错 PCM
    AudioStreamBasicDescription inASBD;
    memset(&inASBD, 0, sizeof(inASBD));
    inASBD.mSampleRate = kXTAACSampleRate;
    inASBD.mFormatID = kAudioFormatLinearPCM;
    inASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    inASBD.mChannelsPerFrame = 1;
    inASBD.mBitsPerChannel = 32;
    inASBD.mFramesPerPacket = 1;
    inASBD.mBytesPerFrame = 4;
    inASBD.mBytesPerPacket = 4;

    // 输出：MPEG-4 AAC LC，1024 帧/包
    AudioStreamBasicDescription outASBD;
    memset(&outASBD, 0, sizeof(outASBD));
    outASBD.mSampleRate = kXTAACSampleRate;
    outASBD.mFormatID = kAudioFormatMPEG4AAC;
    outASBD.mChannelsPerFrame = 1;
    outASBD.mFramesPerPacket = kXTAACFramesPerPacket;

    AudioConverterRef conv = NULL;
    OSStatus st = AudioConverterNew(&inASBD, &outASBD, &conv);
    if (st != noErr || !conv) {
        XTLog(@"[XTWebRTCMedia] AudioConverter 创建失败 status=%d", (int)st);
        _aacConverter = NULL;
        return;
    }
    _aacConverter = conv;
}

- (void)encodePCMToAAC:(NSData *)pcm {
    // 仅 _audioQueue 调用
    if (!_aacConverter || pcm.length == 0) return;

    // AAC 编码器要求每次至少 1024 帧；不足则补静音
    NSMutableData *buf = [pcm mutableCopy];
    NSUInteger minBytes = (NSUInteger)kXTAACFramesPerPacket * sizeof(float);
    if (buf.length < minBytes) buf.length = minBytes;

    XTAACContext ctx;
    ctx.data = buf.bytes;
    ctx.length = buf.length;
    ctx.offset = 0;

    uint8_t outBuf[8192];
    AudioBufferList out;
    out.mNumberBuffers = 1;
    out.mBuffers[0].mNumberChannels = 1;
    out.mBuffers[0].mDataByteSize = sizeof(outBuf);
    out.mBuffers[0].mData = outBuf;

    AudioStreamPacketDescription desc[64];
    UInt32 packets = 64;
    OSStatus st = AudioConverterFillComplexBuffer(_aacConverter, XTAACInputProc, &ctx,
                                                  &packets, &out, desc);
    if (st != noErr || packets == 0 || out.mBuffers[0].mDataByteSize == 0) return;

    NSData *aac = [NSData dataWithBytes:outBuf length:out.mBuffers[0].mDataByteSize];
    uint64_t ts = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000000.0);
    [self sendFrameData:aac type:kXTFrameTypeAudio keyframe:NO timestampUS:ts];
}

- (void)startSilenceFallback {
    // SpringBoard 注入环境通常拿不到麦克风权限，AVAudioEngine 启动会失败。
    // 降级为按 AAC 帧率生成静音 PCM 并真实编码发送，保证音频轨存在且链路不空转。
    _audioUseSilence = YES;
    if (_silenceTimer) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _audioQueue);
    uint64_t interval = (uint64_t)((kXTAACFramesPerPacket / kXTAACSampleRate) * (double)NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 4);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) me = weakSelf;
        if (!me || !me->_running.load() || !me->_aacConverter) return;
        NSMutableData *silence = [NSMutableData dataWithLength:
                                  (NSUInteger)kXTAACFramesPerPacket * sizeof(float)];
        [me encodePCMToAAC:silence];
    });
    _silenceTimer = timer;
    dispatch_resume(timer);
}

- (void)startAudioCapture {
    [self setupAACConverter];
    if (!_aacConverter) {
        [self startSilenceFallback];
        return;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *mono = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                           sampleRate:kXTAACSampleRate
                                                             channels:1
                                                          interleaved:NO];
    dispatch_queue_t aq = _audioQueue;
    __weak typeof(self) weakSelf = self;
    [input installTapOnBus:0 bufferSize:(AVAudioFrameCount)kXTAACFramesPerPacket format:mono
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        typeof(self) me = weakSelf;
        if (!me) return;
        uint32_t frames = buffer.frameLength;
        float *ch = buffer.floatChannelData ? buffer.floatChannelData[0] : NULL;
        if (!ch || frames == 0) return;
        NSData *pcm = [NSData dataWithBytes:ch length:(NSUInteger)frames * sizeof(float)];
        dispatch_async(aq, ^{
            [me encodePCMToAAC:pcm];
        });
    }];

    [engine prepare];
    NSError *err = nil;
    BOOL ok = [engine startAndReturnError:&err];
    if (!ok) {
        XTLog(@"[XTWebRTCMedia] AVAudioEngine 启动失败(%@)，降级静音音轨", err.localizedDescription);
        [input removeTapOnBus:0];
        [self startSilenceFallback];
        return;
    }
    _audioEngine = engine;
    _audioUseSilence = NO;
}

@end
