/**
 * XTCloudControl.h - 开放式云控客户端
 *
 * 对标 open-cloud-control-client.lua 的云控通道：主动连 ws://host:port/ws?token=...，
 * 收到 JSON 指令后复用 XTUDPControl 的动作分发；心跳 20s，3 次无 pong 重连，
 * 最多 5 次退避重连。状态写入 plist 并通过 SSE 广播。
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XTCloudConnectionState) {
    XTCloudConnectionStateDisconnected = 0,
    XTCloudConnectionStateConnecting,
    XTCloudConnectionStateConnected,
    XTCloudConnectionStateReconnecting
};

@interface XTCloudControl : NSObject

+ (instancetype)sharedInstance;

@property (nonatomic, assign, readonly) XTCloudConnectionState state;

- (BOOL)connectToServer:(NSString *)host port:(UInt16)port token:(NSString *)token;
- (void)disconnect;
- (BOOL)isConnected;
- (NSDictionary<NSString *, id> *)status;

/// cloud_conf.plist：server / port / token / autoConnect
- (NSDictionary<NSString *, id> *)config;
- (BOOL)saveConfig:(NSDictionary<NSString *, id> *)config;

/// 供 XTApplication 启动时调用：autoConnect=YES 时自动连接
- (void)startAutoConnectIfNeeded;

@end

NS_ASSUME_NONNULL_END
