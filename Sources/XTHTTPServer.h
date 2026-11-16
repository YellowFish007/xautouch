#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 请求/响应模型

/// 完整的 HTTP 请求（支持 query string、form、JSON、multipart 文件上传）
@interface XTHTTPRequest : NSObject
@property (nonatomic, copy)   NSString *method;
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, copy)   NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong) NSData *bodyData;
@property (nonatomic, copy, readonly) NSString *body;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *query;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *form;
- (nullable id)jsonObject;
- (nullable id)valueForKey:(NSString *)key;          // query -> form -> json -> multipart
- (nullable NSString *)stringForKey:(NSString *)key defaultValue:(nullable NSString *)def;
- (double)doubleForKey:(NSString *)key defaultValue:(double)def;
- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def;
/// multipart 文件：@{@"filename":..., @"content-type":..., @"data":NSData}
- (nullable NSDictionary *)filePartForField:(NSString *)field;
@end

@interface XTHTTPResponse : NSObject
@property (nonatomic, assign) NSInteger statusCode;   // 默认 200
@property (nonatomic, copy)   NSString *contentType;  // 默认 application/json
@property (nonatomic, strong) NSData *body;
@property (nonatomic, copy)   NSDictionary<NSString *, NSString *> *extraHeaders;
+ (instancetype)json:(id)obj;
+ (instancetype)text:(NSString *)text;
+ (instancetype)data:(NSData *)data contentType:(NSString *)ct;
+ (instancetype)error:(NSInteger)code message:(NSString *)msg;
@end

#pragma mark - 服务

/// 本地 HTTP 控制服务。完整实现 XXTouch 设备端 39 路由 + Web 面板端点。
@interface XTHTTPServer : NSObject
@property (nonatomic, assign, readonly) UInt16 port;
@property (nonatomic, assign) BOOL corsEnabled;

+ (instancetype)sharedInstance;
- (void)startOnPort:(UInt16)port;   // 默认 46899
- (void)stop;
/// 路由分发（实现于 XTRoutes.mm）
- (nullable XTHTTPResponse *)dispatchRequest:(XTHTTPRequest *)req;
/// 由路由层调用：把 SSE 客户端加入广播列表 / WebSocket 客户端注册
- (void)addSSEClient:(int)fd;
- (void)broadcastEvent:(NSString *)event data:(id)data;
/// MJPEG 长连接（/api/screen/stream）：循环取帧并写 multipart/x-mixed-replace
- (void)handleMJPEGStream:(int)fd;
@end

NS_ASSUME_NONNULL_END
