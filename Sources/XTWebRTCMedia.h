/**
 * XTWebRTCMedia.h - 自包含屏幕/音频实时传输层
 *
 * 不依赖 libwebrtc。主线：XTCapture 截图 -> CGImage -> CVPixelBuffer ->
 * VideoToolbox H.264 Annex-B -> 自定义 RTP-like 帧协议 -> BSD UDP socket。
 * 音频：AVAudioEngine 采集 + AudioToolbox AAC 编码，复用同一 socket(type=audio)。
 *
 * 本文件只声明公开接口；所有配置解析、编码、传输细节见 XTWebRTCMedia.mm。
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTWebRTCMedia : NSObject

+ (instancetype)sharedInstance;

/// 会话是否处于运行状态（线程安全读取）
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// 启动会话。config 支持的键：
///   host(NSString) / port(NSNumber)          目标地址，必填其一来源（见 sdp）
///   sdp(NSString)                            简化 JSON 字符串，可解析出 host/port/fps/bitrate/codec/audio/width/height
///   fps(NSNumber)                            采集帧率，默认 15
///   bitrate(NSNumber)                        视频目标码率(bps)，默认 1500000
///   width/height(NSNumber)                   可选；不传则由第一帧截图尺寸决定
///   audio(NSNumber BOOL)                     是否启用音频，默认 YES
- (void)startSessionWithConfig:(NSDictionary *)config;

/// 停止会话：取消采集/音频定时器、释放编码器与 socket、清空会话状态（保留统计快照可读）
- (void)stopSession;

/// 统计快照。返回键：running/fps/bitrate/framesSent/packetsSent/bytesSent/dropped
- (NSDictionary<NSString *, NSNumber *> *)sessionStats;

/// 处理来自信令层(/api/webrtc/answer|ice|stop)的消息。
/// msg 的 type 支持：answer / ice / stop，字段与 XTApplication 现有 _rtcQueue 一致。
- (void)handleRemoteMessage:(NSDictionary *)msg;

@end

NS_ASSUME_NONNULL_END
