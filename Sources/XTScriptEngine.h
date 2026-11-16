#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTScriptEngine : NSObject
+ (instancetype)sharedInstance;

#pragma mark - 执行（真实 Lua 5.4 VM）
- (NSArray<NSDictionary *> *)validateSource:(NSString *)source;
- (NSDictionary *)runScriptNamed:(NSString *)name;
- (NSDictionary *)runSource:(NSString *)source;
- (void)stop;
- (void)pause;
- (void)resume;
- (BOOL)isRunning;

#pragma mark - 脚本 / 文件管理
- (NSArray<NSString *> *)scriptList;
- (nullable NSString *)readFile:(NSString *)path;
- (BOOL)writeFile:(NSString *)path content:(NSString *)content;
- (BOOL)removeFile:(NSString *)path;
- (BOOL)renameFile:(NSString *)from to:(NSString *)to;
- (BOOL)copyFile:(NSString *)from to:(NSString *)to;
- (BOOL)moveFile:(NSString *)from to:(NSString *)to;
- (BOOL)mkdir:(NSString *)path;
- (BOOL)rmdir:(NSString *)path;
- (BOOL)recycle:(NSString *)path;
- (NSArray<NSDictionary *> *)fileListAt:(NSString *)dir;
- (nullable NSString *)encryptFile:(NSString *)path;
- (nullable NSString *)decryptFile:(NSString *)path;
- (void)selectScript:(NSString *)name;
- (NSString *)selectedScript;

@end

NS_ASSUME_NONNULL_END
