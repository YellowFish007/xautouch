/**
 * XTUDPControl.h - UDP 控制服务
 *
 * 对标 touchelf-udpd.lua 的守护思路：BSD UDP socket + dispatch_source 读源，
 * 在 SpringBoard 进程内直接接收 JSON 控制指令并调用触摸/脚本引擎。
 * 协议、token 校验与统计接口见 XTNetworkServicesREADME.md。
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 命令回包回调

/// 统一动作分发的回包回调。screen 命令会调用多次（分片）；其余命令调用 0 或 1 次。
typedef void (^XTUDPCommandReplyBlock)(NSDictionary<NSString *, id> *reply);

#pragma mark - UDP 控制服务

@interface XTUDPControl : NSObject

+ (instancetype)sharedInstance;

/// 默认监听端口 46900；start 成功后 port 返回实际端口。
- (BOOL)start;
- (BOOL)startOnPort:(UInt16)port;
- (void)stop;
- (BOOL)isRunning;
- (UInt16)port;
- (nullable NSString *)token;

/// 收包数 / 丢弃数 / 发包数 / 最后错误
- (NSDictionary<NSString *, id> *)stats;

/**
 * 动作分发（UDP 与云控共用）。调用方负责鉴权。
 * @param command 已解析的 JSON 字典，支持 cmd 以及参照对象的 type/mode/body 写法
 * @param reply   回包回调，可为 nil；回调可能在后台队列异步触发多次
 * @return YES 表示该命令被识别，NO 表示未知命令（调用方应回 unknown_command）
 */
- (BOOL)executeCommand:(NSDictionary<NSString *, id> *)command
               onReply:(nullable XTUDPCommandReplyBlock)reply;

/// 便捷封装，丢弃回包。
- (BOOL)executeCommand:(NSDictionary<NSString *, id> *)command;

/**
 * 把 JSON 对象作为 UDP 数据报发出（内部使用）。
 * address 必须是长度为 sizeof(struct sockaddr_in) 的 NSData。
 */
- (BOOL)sendJSON:(NSDictionary<NSString *, id> *)obj toAddress:(NSData *)address;

@end

NS_ASSUME_NONNULL_END
