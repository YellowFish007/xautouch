/**
 * XTEAPIClient.h - 本地 HTTP API 封装
 *
 * 封装宿主 tweak 在 127.0.0.1:8080 提供的文件/脚本端点。
 * 所有方法都在主线程回调；JSON 中 code != 0 统一转换成 NSError。
 */
#import <Foundation/Foundation.h>

extern NSString *const XTEAPIErrorDomain;

@interface XTEAPIClient : NSObject

+ (instancetype)sharedClient;
/// deviceinfo 不可用时的兜底前缀（rootless 默认安装位置）
+ (NSString *)defaultResourceRoot;

#pragma mark - 设备信息

- (void)fetchDeviceInfo:(void (^)(NSDictionary *info, NSError *error))completion;
/// 读取 /deviceinfo 的 resource_root；失败时回退默认值并返回错误
- (void)fetchResourceRoot:(void (^)(NSString *root, NSError *error))completion;

#pragma mark - 文件管理

- (void)listDirectory:(NSString *)path
           completion:(void (^)(NSArray<NSDictionary *> *items, NSError *error))completion;
- (void)readFile:(NSString *)path
      completion:(void (^)(NSString *content, NSError *error))completion;
- (void)writeFile:(NSString *)path
          content:(NSString *)content
       completion:(void (^)(NSError *error))completion;
- (void)makeDirectory:(NSString *)path completion:(void (^)(NSError *error))completion;
- (void)removeDirectory:(NSString *)path completion:(void (^)(NSError *error))completion;
- (void)removeFile:(NSString *)path completion:(void (^)(NSError *error))completion;
- (void)renameFile:(NSString *)from to:(NSString *)to completion:(void (^)(NSError *error))completion;
- (void)copyFile:(NSString *)from to:(NSString *)to completion:(void (^)(NSError *error))completion;
- (void)moveFile:(NSString *)from to:(NSString *)to completion:(void (^)(NSError *error))completion;
- (void)recycleFile:(NSString *)path completion:(void (^)(NSError *error))completion;
- (void)encryptFile:(NSString *)path
         completion:(void (^)(NSString *resultPath, NSError *error))completion;

#pragma mark - 脚本

- (void)launchScriptFile:(NSString *)path
              completion:(void (^)(NSDictionary *result, NSError *error))completion;
- (void)checkSyntax:(NSString *)source
         completion:(void (^)(NSArray<NSDictionary *> *diagnostics, NSError *error))completion;
- (void)fetchScriptList:(void (^)(NSArray<NSString *> *names, NSError *error))completion;
- (void)saveScriptNamed:(NSString *)name
                 source:(NSString *)source
             completion:(void (^)(NSError *error))completion;
- (void)fetchAppList:(void (^)(NSArray *apps, NSError *error))completion;

#pragma mark - 静态资源原始字节（供图片预览使用）

/// relativePath 相对 resource_root/web，返回服务器原始响应体
- (void)fetchRawResource:(NSString *)relativePath
              completion:(void (^)(NSData *data, NSError *error))completion;

@end
