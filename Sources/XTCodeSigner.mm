/**
 * XTCodeSigner.mm - 代码签名 / 重签名完整实现
 *
 * 设计要点：
 *  1. 工具探测顺序 codesign -> ldid，覆盖 jbRoot/usr/bin、系统标准路径与 PATH。
 *  2. 签名优先 codesign --force --sign - --entitlements <plist> --timestamp=none，
 *     失败回退 ldid -S<plist>（ad-hoc 时为 ldid -S）。
 *  3. 校验优先 codesign --verify --verbose=4，辅以 ldid -e 解析 entitlements。
 *  4. 所有 NSTask 设置 8 秒超时（dispatch_after kill），参数全部用数组传递，
 *     杜绝 shell 注入，路径含空格安全。
 *  5. 重签名遍历目录内所有 Mach-O（magic 检测），签名前 chmod 755，
 *     签名后校验失败收集进 errors 数组。
 */
#import "XTCodeSigner.h"
#import "XTApplication.h"
#import "XTLogger.h"
#include <stdint.h>

// NSTask / NSPipe 在 iOS SDK 中不公开头文件，但越狱运行时 Foundation 内含这两个类。
// __has_include 保证：SDK 提供头文件时用系统声明，否则用下方最小声明，
// 从而在 macOS + Theos(iPhoneOS SDK) 两种情况下都能直接编译。
#if __has_include(<Foundation/NSTask.h>)
#import <Foundation/NSTask.h>
#else
@interface NSPipe : NSObject
+ (instancetype)pipe;
@property (nonatomic, readonly) NSFileHandle *fileHandleForReading;
@property (nonatomic, readonly) NSFileHandle *fileHandleForWriting;
@end

@interface NSTask : NSObject
@property (nonatomic, copy, nullable) NSString *launchPath;
@property (nonatomic, copy, nullable) NSArray<NSString *> *arguments;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *environment;
@property (nonatomic, strong, nullable) id standardOutput;
@property (nonatomic, strong, nullable) id standardError;
@property (nonatomic, strong, nullable) id standardInput;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) int terminationStatus;
- (void)launch;
- (void)waitUntilExit;
- (void)kill;
@end
#endif

static NSString * const kXTCodeSignBundleID = @"edu.example.xautouch";
static NSString * const kXTCodeSignTeamID   = @"TEAMID";
static NSTimeInterval const kXTCodeSignTimeout = 8.0;

@implementation XTCodeSigner {
    NSString *_codesignPath;
    NSString *_ldidPath;
    BOOL _toolsProbed;
    NSInteger _signedCount;
    NSDate *_lastSignTime;
    NSString *_lastError;
    NSLock *_stateLock;
}

#pragma mark - 单例 / 生命周期

+ (instancetype)sharedInstance {
    static XTCodeSigner *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateLock = [NSLock new];
    }
    return self;
}

#pragma mark - 结果构造 / 状态记录

- (NSDictionary *)resultWithCode:(NSInteger)code
                         message:(nullable NSString *)message
                            file:(nullable NSString *)file
                          stdout:(nullable NSString *)stdout
                          stderr:(nullable NSString *)stderr {
    return @{@"code":@(code),
             @"message":message ?: @"",
             @"file":file ?: @"",
             @"stdout":stdout ?: @"",
             @"stderr":stderr ?: @""};
}

- (void)recordError:(NSString *)message {
    [_stateLock lock];
    _lastError = [message copy];
    [_stateLock unlock];
}

- (void)noteSignedFile:(NSString *)path {
    [_stateLock lock];
    _signedCount += 1;
    _lastSignTime = [NSDate date];
    [_stateLock unlock];
    XTLog(@"[XTCodeSigner] signed: %@", path);
}

#pragma mark - 工具探测

/** jbRoot / rootfs / 标准前缀候选目录（去重）。 */
- (NSArray<NSString *> *)toolSearchDirectories {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *jb = [[XTApplication sharedInstance] jbRoot] ?: @"";
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    if (jb.length) [roots addObject:jb];
    for (NSString *r in @[@"/var/jb", @"/rootfs"]) {
        if (![roots containsObject:r]) [roots addObject:r];
    }
    // 先搜索越狱前缀，再搜索系统标准路径，最后搜索 PATH
    for (NSString *root in roots) {
        [dirs addObject:[root stringByAppendingPathComponent:@"usr/bin"]];
        [dirs addObject:[root stringByAppendingPathComponent:@"bin"]];
        [dirs addObject:[root stringByAppendingPathComponent:@"usr/local/bin"]];
    }
    [dirs addObjectsFromArray:@[@"/usr/bin", @"/bin", @"/usr/sbin", @"/usr/local/bin"]];
    NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"] ?: @"";
    [dirs addObjectsFromArray:[pathEnv componentsSeparatedByString:@":"]];

    NSMutableArray<NSString *> *unique = [NSMutableArray array];
    for (NSString *dir in dirs) {
        if (dir.length == 0 || [unique containsObject:dir]) continue;
        [unique addObject:dir];
    }
    return unique;
}

/** 在候选目录中查找可执行工具，返回绝对路径；找不到返回 nil。 */
- (nullable NSString *)findExecutableNamed:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [self toolSearchDirectories]) {
        NSString *candidate = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDir] &&
            !isDir && [fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

- (nullable NSString *)currentCodesignPath {
    [_stateLock lock];
    NSString *path = [_codesignPath copy];
    [_stateLock unlock];
    return path;
}

- (nullable NSString *)currentLdidPath {
    [_stateLock lock];
    NSString *path = [_ldidPath copy];
    [_stateLock unlock];
    return path;
}

- (BOOL)ensureTools {
    if ([self currentCodesignPath].length || [self currentLdidPath].length) return YES;

    NSString *codesign = [self findExecutableNamed:@"codesign"]; // 优先
    NSString *ldid     = [self findExecutableNamed:@"ldid"];     // 回退

    [_stateLock lock];
    _codesignPath = [codesign copy];
    _ldidPath = [ldid copy];
    _toolsProbed = YES;
    [_stateLock unlock];

    if (!codesign.length && !ldid.length) {
        [self recordError:@"未找到签名工具 codesign / ldid（已探测 jbRoot/usr/bin、/usr/bin 与 PATH）"];
        XTLog(@"[XTCodeSigner] 工具探测失败：codesign 与 ldid 均不可用");
        return NO;
    }
    XTLog(@"[XTCodeSigner] tools: codesign=%@ ldid=%@", codesign ?: @"none", ldid ?: @"none");
    return YES;
}

#pragma mark - entitlements 生成

- (NSString *)defaultEntitlementsXML {
    NSString *appID = [NSString stringWithFormat:@"%@.%@", kXTCodeSignTeamID, kXTCodeSignBundleID];
    // 六个必需键 + team-identifier 辅助键；team id 使用 TEAMID 明确占位。
    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        @"<plist version=\"1.0\">\n"
        @"<dict>\n"
        @"\t<key>application-identifier</key>\n\t\t<string>%@</string>\n"
        @"\t<key>com.apple.developer.team-identifier</key>\n\t\t<string>%@</string>\n"
        @"\t<key>keychain-access-groups</key>\n\t\t<array>\n\t\t\t<string>%@</string>\n\t\t</array>\n"
        @"\t<key>com.apple.developer.ubiquity-container-identifiers</key>\n\t\t<array>\n\t\t\t<string>%@</string>\n\t\t</array>\n"
        @"\t<key>get-task-allow</key>\n\t\t<true/>\n"
        @"\t<key>task_for_pid-allow</key>\n\t\t<true/>\n"
        @"\t<key>com.apple.security.application-groups</key>\n\t\t<array>\n\t\t\t<string>group.%@</string>\n\t\t</array>\n"
        @"</dict>\n"
        @"</plist>\n",
        appID, kXTCodeSignTeamID, appID, appID, kXTCodeSignBundleID];
}

- (BOOL)writeEntitlementsToPath:(NSString *)path {
    if (path.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (dir.length && ![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSData *data = [[self defaultEntitlementsXML] dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok = [data writeToFile:path atomically:YES];
    if (!ok) {
        [self recordError:[NSString stringWithFormat:@"写入 entitlements 失败: %@", path]];
    }
    return ok;
}

/** 自定义 entitlements 字典 -> XML plist 数据；nil 数据表示调用方传了 ad-hoc 空字典。 */
- (nullable NSData *)plistDataForEntitlements:(nullable NSDictionary *)entitlements {
    if (entitlements.count == 0) return nil; // ad-hoc
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:entitlements
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:&error];
    if (!data) {
        [self recordError:[NSString stringWithFormat:@"entitlements 序列化失败: %@",
                           error.localizedDescription ?: @"unknown"]];
    }
    return data;
}

/** 写临时 entitlements 文件，返回路径；entitlements 为 nil/空时使用默认策略由调用方决定。 */
- (nullable NSString *)writeTemporaryEntitlements:(nullable NSData *)data {
    if (!data) return nil;
    NSString *dir = NSTemporaryDirectory() ?: @"/tmp";
    NSString *name = [NSString stringWithFormat:@"xautouch-ent-%d-%lld.plist",
                      (int)[[NSProcessInfo processInfo] processIdentifier],
                      (long long)([NSDate date].timeIntervalSinceReferenceDate * 1000000.0)];
    NSString *path = [dir stringByAppendingPathComponent:name];
    if (![data writeToFile:path atomically:YES]) {
        [self recordError:[NSString stringWithFormat:@"写临时 entitlements 失败: %@", path]];
        return nil;
    }
    return path;
}

#pragma mark - NSTask 执行封装（参数数组 + 8 秒超时）

- (NSDictionary *)runExecutable:(NSString *)exe
                      arguments:(NSArray<NSString *> *)arguments
                        timeout:(NSTimeInterval)timeout
                           file:(nullable NSString *)file {
    if (exe.length == 0) {
        return [self resultWithCode:-2 message:@"no executable" file:file stdout:@"" stderr:@"no executable"];
    }

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = exe;
    task.arguments = arguments ?: @[];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    // 先起读取线程，避免子进程输出超过管道缓冲时阻塞导致 waitUntilExit 死锁。
    __block NSData *outData = [NSData data];
    __block NSData *errData = [NSData data];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    dispatch_async(queue, ^{
        outData = [outPipe.fileHandleForReading readDataToEndOfFile] ?: [NSData data];
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    dispatch_async(queue, ^{
        errData = [errPipe.fileHandleForReading readDataToEndOfFile] ?: [NSData data];
        dispatch_group_leave(group);
    });

    // 8 秒超时：到点仍在运行则 kill。
    __block BOOL finished = NO;
    __block BOOL timedOut = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), queue, ^{
        if (!finished && task.isRunning) {
            timedOut = YES;
            [task kill];
        }
    });

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        finished = YES;
        NSString *reason = exception.reason ?: @"unknown launch exception";
        [self recordError:[NSString stringWithFormat:@"%@ 启动失败: %@", exe, reason]];
        return [self resultWithCode:-3 message:reason file:file stdout:@"" stderr:reason];
    }
    finished = YES;
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));

    NSString *stdoutText = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrText = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
    int status = task.terminationStatus;
    NSInteger code = timedOut ? -4 : (status == 0 ? 0 : status);
    NSString *message = timedOut
        ? [NSString stringWithFormat:@"%@ 超时（%.0f 秒）", [exe lastPathComponent], timeout]
        : [NSString stringWithFormat:@"%@ 退出码 %d", [exe lastPathComponent], status];
    if (code != 0) {
        [self recordError:[NSString stringWithFormat:@"%@ | stderr: %@", message, stderrText]];
    }
    return @{@"code":@(code),
             @"message":message,
             @"file":file ?: @"",
             @"stdout":stdoutText,
             @"stderr":stderrText,
             @"exe":exe,
             @"timed_out":@(timedOut)};
}

#pragma mark - 内部签名原语

/**
 * 内部签名：entitlementsFile 为 nil 表示 ad-hoc；否则使用指定 plist 文件。
 * 优先 codesign，失败回退 ldid。两个工具都失败时返回最后一个失败结果。
 */
- (NSDictionary *)signFileAtPath:(NSString *)path entitlementsFile:(nullable NSString *)entitlementsFile {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *lastFailure = nil;

    // 路径一：codesign（优先）
    NSString *codesign = [self currentCodesignPath];
    if (codesign.length) {
        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"--force", @"--sign", @"-", nil];
        if (entitlementsFile.length) {
            [args addObjectsFromArray:@[@"--entitlements", entitlementsFile]];
        }
        [args addObjectsFromArray:@[@"--timestamp=none", path]];
        NSDictionary *result = [self runExecutable:codesign arguments:args timeout:kXTCodeSignTimeout file:path];
        if ([result[@"code"] integerValue] == 0) {
            [self noteSignedFile:path];
            NSMutableDictionary *r = [result mutableCopy];
            r[@"tool"] = @"codesign";
            r[@"message"] = [NSString stringWithFormat:@"codesign 签名成功%@",
                             entitlementsFile.length ? @"（带 entitlements）" : @"（ad-hoc）"];
            return r;
        }
        XTLog(@"[XTCodeSigner] codesign 失败，回退 ldid: %@", result[@"stderr"] ?: @"");
        lastFailure = result;
    }

    // 路径二：ldid（回退）
    NSString *ldid = [self currentLdidPath];
    if (ldid.length) {
        NSArray<NSString *> *args = entitlementsFile.length
            ? @[[NSString stringWithFormat:@"-S%@", entitlementsFile], path] // -S<path> 连写
            : @[@"-S", path];                                                // ad-hoc
        NSDictionary *result = [self runExecutable:ldid arguments:args timeout:kXTCodeSignTimeout file:path];
        if ([result[@"code"] integerValue] == 0) {
            [self noteSignedFile:path];
            NSMutableDictionary *r = [result mutableCopy];
            r[@"tool"] = @"ldid";
            r[@"message"] = [NSString stringWithFormat:@"ldid 签名成功%@",
                             entitlementsFile.length ? @"（带 entitlements）" : @"（ad-hoc）"];
            return r;
        }
        lastFailure = result;
    }

    if (lastFailure) {
        NSMutableDictionary *r = [lastFailure mutableCopy];
        r[@"message"] = [NSString stringWithFormat:@"codesign/ldid 均签名失败: %@",
                         lastFailure[@"message"] ?: @""];
        NSInteger code = [lastFailure[@"code"] integerValue];
        r[@"code"] = code == 0 ? @(-5) : @(code);
        return r;
    }
    return [self resultWithCode:-2 message:@"no sign tool available" file:path stdout:@"" stderr:@""];
}

#pragma mark - 公开签名 / 校验 / 重签名

- (NSDictionary *)signFileAtPath:(NSString *)path entitlements:(NSDictionary *)entitlements {
    if (path.length == 0) {
        return [self resultWithCode:-1 message:@"empty file path" file:path stdout:@"" stderr:@""];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) {
        return [self resultWithCode:-1
                            message:[NSString stringWithFormat:@"file not found or is directory: %@", path]
                               file:path stdout:@"" stderr:@""];
    }
    if (![self ensureTools]) {
        return [self resultWithCode:-2
                            message:@"no usable sign tool (codesign/ldid)"
                               file:path stdout:@""
                             stderr:@"未找到 codesign 或 ldid；请安装 ldid 或检查 jbRoot/usr/bin、PATH"];
    }

    // nil -> 默认 entitlements；@{} -> ad-hoc；非空 -> 自定义字典
    BOOL adHoc = (entitlements != nil && entitlements.count == 0);
    NSString *tempEntitlements = nil;
    if (!adHoc) {
        NSData *data = entitlements.count
            ? [self plistDataForEntitlements:entitlements]
            : [[self defaultEntitlementsXML] dataUsingEncoding:NSUTF8StringEncoding];
        tempEntitlements = [self writeTemporaryEntitlements:data];
        if (!tempEntitlements) {
            return [self resultWithCode:-2 message:@"failed to prepare entitlements"
                                   file:path stdout:@"" stderr:@"无法写临时 entitlements plist"];
        }
    }

    NSDictionary *result = [self signFileAtPath:path entitlementsFile:tempEntitlements];
    if (tempEntitlements) [fm removeItemAtPath:tempEntitlements error:nil];
    return result;
}

- (NSDictionary *)verifyFileAtPath:(NSString *)path {
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [self resultWithCode:-1
                            message:[NSString stringWithFormat:@"file not found: %@", path]
                               file:path stdout:@"" stderr:@""];
    }
    if (![self ensureTools]) {
        return [self resultWithCode:-2 message:@"no usable verify tool"
                               file:path stdout:@"" stderr:@"未找到 codesign 或 ldid"];
    }

    NSMutableDictionary *result = [@{@"code":@0,
                                     @"message":@"signature verified",
                                     @"file":path,
                                     @"valid":@YES,
                                     @"entitlements":@{},
                                     @"stdout":@"",
                                     @"stderr":@""} mutableCopy];
    BOOL valid = NO;

    // codesign --verify --verbose=4
    NSString *codesign = [self currentCodesignPath];
    NSDictionary *csResult = nil;
    if (codesign.length) {
        csResult = [self runExecutable:codesign
                             arguments:@[@"--verify", @"--verbose=4", path]
                               timeout:kXTCodeSignTimeout
                                  file:path];
        result[@"codesign_stdout"] = csResult[@"stdout"] ?: @"";
        result[@"codesign_stderr"] = csResult[@"stderr"] ?: @"";
        valid = ([csResult[@"code"] integerValue] == 0);
        result[@"stdout"] = csResult[@"stdout"] ?: @"";
        result[@"stderr"] = csResult[@"stderr"] ?: @"";
    }

    // ldid -e 解析 entitlements（越狱 ad-hoc 签名的权威校验途径）
    NSString *ldid = [self currentLdidPath];
    if (ldid.length) {
        NSDictionary *ldResult = [self runExecutable:ldid
                                           arguments:@[@"-e", path]
                                             timeout:kXTCodeSignTimeout
                                                file:path];
        result[@"ldid_stdout"] = ldResult[@"stdout"] ?: @"";
        result[@"ldid_stderr"] = ldResult[@"stderr"] ?: @"";
        NSData *plistData = [ldResult[@"stdout"] dataUsingEncoding:NSUTF8StringEncoding];
        if (plistData.length) {
            NSError *error = nil;
            id plist = [NSPropertyListSerialization propertyListWithData:plistData
                                                                options:NSPropertyListImmutable
                                                                 format:NULL
                                                                  error:&error];
            if ([plist isKindOfClass:[NSDictionary class]]) {
                result[@"entitlements"] = plist;
            }
        }
        if ([ldResult[@"code"] integerValue] == 0 && [ldResult[@"stdout"] length] > 0) {
            valid = YES; // ldid 能导出 entitlements 即视为已签名
        }
    }

    result[@"valid"] = @(valid);
    if (!valid) {
        result[@"code"] = @(-6);
        result[@"message"] = @"signature verification failed (codesign/ldid 均未确认有效签名)";
        [self recordError:[NSString stringWithFormat:@"签名校验失败: %@", path]];
    }
    return result;
}

/** Mach-O magic 检测：64/32 位大小端 + fat/fat64 共 8 种字节序。 */
- (BOOL)isMachOAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return NO;
    NSData *head = [handle readDataOfLength:4];
    [handle closeFile];
    if (head.length < 4) return NO;

    const unsigned char *bytes = head.bytes;
    uint32_t magic = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
                     ((uint32_t)bytes[2] << 8)  | (uint32_t)bytes[3];
    switch (magic) {
        case 0xfeedfacf: // Mach-O 64 big-endian
        case 0xcffaedfe: // Mach-O 64 little-endian（常见）
        case 0xfeedface: // Mach-O 32 big-endian
        case 0xcefaedfe: // Mach-O 32 little-endian（常见）
        case 0xcafebabe: // fat big-endian
        case 0xbebafeca: // fat little-endian
        case 0xcafebabf: // fat64 big-endian
        case 0xbfbafeca: // fat64 little-endian
            return YES;
        default:
            return NO;
    }
}

- (NSDictionary *)resignBundleAtPath:(NSString *)path {
    if (path.length == 0) {
        return [self resultWithCode:-1 message:@"empty bundle path" file:path stdout:@"" stderr:@""];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        return [self resultWithCode:-1
                            message:[NSString stringWithFormat:@"bundle directory not found: %@", path]
                               file:path stdout:@"" stderr:@""];
    }
    if (![self ensureTools]) {
        return [self resultWithCode:-2 message:@"no usable sign tool"
                               file:path stdout:@"" stderr:@"未找到 codesign 或 ldid"];
    }

    // 整包共用一份默认 entitlements，避免重复写盘
    NSData *entData = [[self defaultEntitlementsXML] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *entitlementsFile = [self writeTemporaryEntitlements:entData];
    if (!entitlementsFile) {
        return [self resultWithCode:-2 message:@"failed to prepare entitlements"
                               file:path stdout:@"" stderr:@"无法写临时 entitlements plist"];
    }

    NSArray<NSString *> *subpaths = [fm subpathsOfDirectoryAtPath:path error:nil] ?: @[];
    NSMutableArray<NSString *> *signedFiles = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *errors = [NSMutableArray array];

    for (NSString *relative in subpaths) {
        NSString *full = [path stringByAppendingPathComponent:relative];
        BOOL childIsDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&childIsDir] || childIsDir) continue;

        // 跳过符号链接（attributes 返回 NSFileTypeSymbolicLink）
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        if ([attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) continue;
        if (![self isMachOAtPath:full]) continue;

        // 签名前 chmod 755
        [fm setAttributes:@{NSFilePosixPermissions:@(0755)} ofItemAtPath:full error:nil];

        NSDictionary *signResult = [self signFileAtPath:full entitlementsFile:entitlementsFile];
        if ([signResult[@"code"] integerValue] != 0) {
            [errors addObject:@{@"file":full,
                                @"stage":@"sign",
                                @"message":signResult[@"message"] ?: @"",
                                @"stderr":signResult[@"stderr"] ?: @""}];
            XTLog(@"[XTCodeSigner] 签名失败 %@: %@", full, signResult[@"message"] ?: @"");
            continue;
        }

        NSDictionary *verifyResult = [self verifyFileAtPath:full];
        if ([verifyResult[@"code"] integerValue] != 0) {
            [errors addObject:@{@"file":full,
                                @"stage":@"verify",
                                @"message":verifyResult[@"message"] ?: @"",
                                @"stderr":verifyResult[@"stderr"] ?: @""}];
            XTLog(@"[XTCodeSigner] 校验失败 %@: %@", full, verifyResult[@"message"] ?: @"");
        } else {
            [signedFiles addObject:full];
        }
    }

    [fm removeItemAtPath:entitlementsFile error:nil];
    if (errors.count) {
        [self recordError:[NSString stringWithFormat:@"重签名 %@ 失败 %lu 项",
                           path, (unsigned long)errors.count]];
    }

    NSMutableDictionary *result = [@{@"code":errors.count ? @(-7) : @0,
                                     @"message":errors.count
                                        ? [NSString stringWithFormat:@"重签名完成，%lu 个 Mach-O 失败",
                                           (unsigned long)errors.count]
                                        : @"重签名完成，全部 Mach-O 校验通过",
                                     @"dir":path,
                                     @"count":@(signedFiles.count + errors.count),
                                     @"signed":signedFiles,
                                     @"failed":errors,
                                     @"errors":errors,
                                     @"stdout":@"",
                                     @"stderr":@""} mutableCopy];
    return result;
}

#pragma mark - 状态

- (NSDictionary *)signStatus {
    [self ensureTools];
    NSString *codesign = [self currentCodesignPath] ?: @"";
    NSString *ldid = [self currentLdidPath] ?: @"";

    XTApplication *app = [XTApplication sharedInstance];
    NSString *environment = [app environment] ?: @"unknown";
    NSString *jbRoot = [app jbRoot] ?: @"";

    NSString *advice = nil;
    if (!codesign.length && !ldid.length) {
        advice = @"未找到签名工具：请先通过包管理器安装 ldid；codesign 仅存在于部分越狱环境。";
    } else if ([environment isEqualToString:@"rootless"] || [environment isEqualToString:@"trollstore"]) {
        advice = @"rootless/TrollStore：工具通常位于 /var/jb/usr/bin，请确认 ldid 已安装并被 postinst 探测到。";
    } else if ([environment isEqualToString:@"roothide"]) {
        advice = @"roothide：工具前缀为 /rootfs/usr/bin，请检查该目录下的 ldid / codesign。";
    } else {
        advice = @"rootful：工具通常位于 /usr/bin，签名前请确认根文件系统已 remount 为可写。";
    }

    NSInteger count = 0;
    NSDate *lastTime = nil;
    NSString *lastError = @"";
    [_stateLock lock];
    count = _signedCount;
    lastTime = _lastSignTime;
    lastError = _lastError ?: @"";
    [_stateLock unlock];

    NSString *lastTimeText = @"never";
    if (lastTime) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        lastTimeText = [formatter stringFromDate:lastTime] ?: @"unknown";
    }

    NSDictionary *data = @{
        @"codesign":codesign,
        @"ldid":ldid,
        @"tools_available":@(codesign.length > 0 || ldid.length > 0),
        @"preferred_tool":codesign.length ? @"codesign" : (ldid.length ? @"ldid" : @""),
        @"signed_count":@(count),
        @"last_sign_time":lastTimeText,
        @"last_error":lastError,
        @"environment":environment,
        @"jb_root":jbRoot,
        @"bundle_id":kXTCodeSignBundleID,
        @"team_id":kXTCodeSignTeamID,
        @"advice":advice
    };
    return @{@"code":@0,
             @"message":@"ok",
             @"data":data,
             @"file":@"",
             @"stdout":@"",
             @"stderr":@""};
}

@end
