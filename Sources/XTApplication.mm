/**
 * XTApplication.mm - 单例协调器：环境适配、设备信息、授权、系统控制、WebRTC 信令
 *
 * 覆盖参照对象的四种越狱环境（rootful / rootless / roothide / TrollStore），
 * 所有路径由 environment 推导，避免硬编码 /var/jb。
 */
#import "XTApplication.h"
#import "XTHTTPServer.h"
#import "XTScriptEngine.h"
#import "XTLogger.h"
#import "XTWebRTCMedia.h"
#import "XTCodeSigner.h"
#import "XTUIService.h"
#import "XTUDPControl.h"
#import "XTCloudControl.h"
#import "XTScreenShare.h"
#import <UIKit/UIKit.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <sys/proc.h>
#import <sys/wait.h>
#import <spawn.h>
#import <unistd.h>

extern char **environ;

@implementation XTApplication {
    NSString *_environment;
    NSMutableArray<NSDictionary *> *_rtcQueue;
    NSMutableDictionary *_appState;
    NSLock *_rtcLock;
}
static NSString *_resourceRoot = @"/var/jb/usr/lib/xautouch";

+ (NSString *)resourceRoot { return _resourceRoot; }

+ (instancetype)sharedInstance {
    static XTApplication *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _remoteAccessEnabled = YES;
        _rtcQueue = [NSMutableArray array];
        _rtcLock = [NSLock new];
        _appState = [NSMutableDictionary dictionary];
        _environment = [self detectEnvironment];
    }
    return self;
}

#pragma mark - 环境适配

- (NSString *)detectEnvironment {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/rootfs/usr/lib"]) return @"roothide";
    if ([fm fileExistsAtPath:@"/var/jb/usr/lib"]) {
        // TrollStore 版没有 Cydia/Sileo，但仍可能用 /var/jb 布局
        if (![fm fileExistsAtPath:@"/Applications/Cydia.app"] &&
            ![fm fileExistsAtPath:@"/Applications/Sileo.app"] &&
            [[NSBundle mainBundle].bundlePath containsString:@"/Applications"]) return @"trollstore";
        return @"rootless";
    }
    return @"rootful";
}

- (NSString *)environment { return _environment ?: @"rootful"; }
- (NSString *)jbRoot {
    if ([_environment isEqualToString:@"roothide"]) return @"/rootfs";
    if ([_environment isEqualToString:@"rootless"] || [_environment isEqualToString:@"trollstore"]) return @"/var/jb";
    return @"";
}
- (NSString *)rootfs { return [_environment isEqualToString:@"roothide"] ? @"/rootfs" : @"/"; }

- (void)setResourceRoot:(NSString *)root {
    _resourceRoot = [root copy];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in @[@"scripts", @"captures", @"logs", @"templates", @"recycle", @"tmp"]) {
        NSString *d = [_resourceRoot stringByAppendingPathComponent:sub];
        [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

- (void)start {
    XTLog(@"[XAutouch] 启动 - env=%@ root=%@", [self environment], _resourceRoot);
    [[XTHTTPServer sharedInstance] startOnPort:46899];
    (void)[XTScriptEngine sharedInstance]; // 触发 Lua VM 初始化
}

- (void)stop {
    [[XTHTTPServer sharedInstance] stop];
    [[XTScriptEngine sharedInstance] stop];
}

- (void)respring {
    Class sb = NSClassFromString(@"SpringBoard");
    id app = [sb performSelector:@selector(sharedApplication)];
    if ([app respondsToSelector:@selector(relaunch)]) [app performSelector:@selector(relaunch)];
    else [self spawn:@"killall -9 SpringBoard"];
}

#pragma mark - 设备信息 / 配置

- (NSDictionary *)deviceInfo {
    UIDevice *d = [UIDevice currentDevice];
    return @{@"code":@0,
             @"devname":d.name ?: @"iPhone",
             @"sysversion":d.systemVersion ?: @"",
             @"zeversion":@"1.0.0",
             @"devtype":d.model ?: @"iPhone",
             @"webserver_url":@"http://127.0.0.1:46899",
             @"pkgtype":[self environment],
             @"bundle_id":[[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
             @"root":[self jbRoot],
             @"rootfs":[self rootfs],
             @"resource_root":_resourceRoot};
}

- (NSDictionary *)config {
    return @{@"code":@0,
             @"version":@"1.0.0",
             @"environment":[self environment],
             @"features":@[@"touch", @"script", @"web", @"ocr", @"template", @"record", @"webrtc"],
             @"port":@46899};
}

#pragma mark - 授权 / 用户配置

- (NSString *)confPath { return [_resourceRoot stringByAppendingPathComponent:@"user_conf.plist"]; }

- (NSDictionary *)userConf {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:[self confPath]] ?: @{};
    NSMutableDictionary *d = [@{@"allow_cors":@YES,
                                @"touchelf_httpd":@YES,
                                @"bind_code":@"",
                                @"bind_expire":@0,
                                @"language":@"zh-CN"} mutableCopy];
    [d addEntriesFromDictionary:saved];
    d[@"code"] = @0;
    return d;
}

- (void)setUserConf:(NSDictionary *)conf {
    NSMutableDictionary *d = [[self userConf] mutableCopy];
    [d removeObjectForKey:@"code"];
    for (NSString *k in conf) {
        if ([k isEqualToString:@"code"]) continue;
        d[k] = conf[k] ?: @"";
    }
    [d writeToFile:[self confPath] atomically:YES];
    [XTHTTPServer sharedInstance].corsEnabled = [d[@"allow_cors"] boolValue];
}

- (NSDictionary *)authInfo {
    NSDictionary *c = [self userConf];
    BOOL bound = [c[@"bind_code"] length] > 0;
    return @{@"code":@0, @"bound":@(bound),
             @"bind_code":c[@"bind_code"] ?: @"",
             @"expire":c[@"bind_expire"] ?: @0,
             @"device":[self deviceInfo]};
}

- (NSDictionary *)bindCode:(NSString *)code expires:(NSInteger)seconds {
    // 规则对齐参照对象：仅 3-9a-zA-Z，长度 10-20；mustbeless 为 0 或 604800
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[3-9a-zA-Z]{10,20}$"
                                                                        options:0 error:nil];
    BOOL valid = code.length >= 10 && code.length <= 20 &&
                 [re numberOfMatchesInString:code options:0 range:NSMakeRange(0, code.length)] == 1;
    if (!valid) return @{@"code":@-1, @"message":@"invalid bind_code (need 10-20 chars of 3-9a-zA-Z)"};
    if (seconds != 0 && seconds != 604800)
        return @{@"code":@-1, @"message":@"mustbeless must be 0 or 604800"};

    NSMutableDictionary *c = [[self userConf] mutableCopy];
    [c removeObjectForKey:@"code"];
    c[@"bind_code"] = code;
    c[@"bind_expire"] = @(seconds);
    [c writeToFile:[self confPath] atomically:YES];
    return @{@"code":@0, @"message":@"bound", @"expire":@(seconds)};
}

#pragma mark - 应用管理

- (NSDictionary *)registerApp:(NSString *)bundle {
    if (!bundle.length) return @{@"code":@-1, @"message":@"empty bundle"};
    _appState[@"bundle"] = bundle;
    _appState[@"registered_at"] = @([[NSDate date] timeIntervalSince1970]);
    return @{@"code":@0, @"bundle":bundle};
}

- (NSDictionary *)appState {
    NSMutableDictionary *d = [@{@"code":@0, @"running":@([[XTScriptEngine sharedInstance] isRunning])} mutableCopy];
    [d addEntriesFromDictionary:_appState];
    return d;
}

- (NSArray<NSDictionary *> *)appList {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    if (workspace) {
        id ws = [workspace performSelector:@selector(defaultWorkspace)];
        if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
            NSArray *apps = [ws performSelector:@selector(allInstalledApplications)] ?: @[];
            for (id a in apps) {
                NSString *bid = [a respondsToSelector:@selector(bundleIdentifier)] ? [a bundleIdentifier] : nil;
                NSString *name = [a respondsToSelector:@selector(localizedName)] ? [a localizedName] : nil;
                if (bid) [out addObject:@{@"bundle":bid, @"name":name ?: bid}];
            }
        }
    }
    if (out.count == 0) {
        // 降级：扫描已安装 App 目录
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *dir in @[@"/Applications", [self jbRoot], @"/var/containers/Bundle/Application"]) {
            if (dir.length == 0) continue;
            NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
            for (NSString *item in items) {
                if (![item hasSuffix:@".app"]) continue;
                NSString *p = [dir stringByAppendingPathComponent:item];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                      [p stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bid = info[@"CFBundleIdentifier"] ?: item;
                [out addObject:@{@"bundle":bid, @"name":info[@"CFBundleDisplayName"] ?: item}];
            }
        }
    }
    return out;
}

- (void)clearAppData:(NSString *)bundle {
    if (!bundle.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = @"/var/mobile/Containers/Data/Application";
    NSArray *dirs = [fm contentsOfDirectoryAtPath:home error:nil] ?: @[];
    for (NSString *d in dirs) {
        NSString *p = [home stringByAppendingPathComponent:d];
        NSString *pl = [p stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:pl];
        if ([meta[@"MCMMetadataIdentifier"] isEqualToString:bundle]) {
            for (NSString *sub in @[@"Library/Caches", @"tmp"]) {
                [fm removeItemAtPath:[p stringByAppendingPathComponent:sub] error:nil];
            }
        }
    }
}

#pragma mark - 进程 / 命令

- (NSDictionary *)procInfo {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    sysctl(mib, 4, NULL, &len, NULL, 0);
    int count = (int)(len / sizeof(struct kinfo_proc));
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    return @{@"code":@0,
             @"count":@(count),
             @"pid":@(pi.processIdentifier),
             @"name":pi.processName,
             @"uptime":@(pi.systemUptime),
             @"memory":@(pi.physicalMemory)};
}

- (NSDictionary *)spawn:(NSString *)command {
    if (!command.length) return @{@"code":@-1, @"error":@"empty command"};
    NSString *outPath = [NSString stringWithFormat:@"%@/tmp/spawn.out", _resourceRoot];
    NSString *full = [NSString stringWithFormat:@"(%@) > \"%@\" 2>&1", command, outPath];
    // system() 在 iOS SDK 不可用；用 posix_spawn 调 /bin/sh -c 等价执行。
    const char *argv[] = { "/bin/sh", "-c", full.UTF8String, NULL };
    pid_t pid = -1;
    int spawnRC = posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *const *)argv, environ);
    int rc = -1;
    if (spawnRC == 0) {
        int status = 0;
        waitpid(pid, &status, 0);
        rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    NSString *out = [NSString stringWithContentsOfFile:outPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    return @{@"code":@(rc), @"command":command, @"output":out};
}

- (NSDictionary *)runProcDict:(NSString *)dictJSON {
    NSData *d = [dictJSON dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![cmd isKindOfClass:[NSDictionary class]]) return @{@"code":@-1, @"error":@"invalid dict"};
    NSString *command = cmd[@"command"] ?: cmd[@"cmd"];
    if (![command isKindOfClass:[NSString class]]) return @{@"code":@-1, @"error":@"no command"};
    return [self spawn:command];
}

#pragma mark - 系统控制

- (void)reboot { [self spawn:@"reboot"]; }
- (void)halt   { [self spawn:@"halt"]; }
- (void)uicache{ [self spawn:@"uicache -r"]; }
- (void)clearGPS {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in @[@"/var/mobile/Library/Caches/com.apple.locationd",
                          @"/var/mobile/Library/Caches/locationd",
                          [NSString stringWithFormat:@"%@/tmp/gps", _resourceRoot]]) {
        [fm removeItemAtPath:p error:nil];
    }
}
- (void)clearAll {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in @[@"captures", @"logs", @"recycle", @"tmp"]) {
        NSString *p = [_resourceRoot stringByAppendingPathComponent:sub];
        [fm removeItemAtPath:p error:nil];
        [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    }
}
- (void)restartService { [self respring]; }

- (NSDictionary *)installDebAtPath:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return @{@"code":@-1, @"error":@"deb not found"};
    NSDictionary *r = [self spawn:[NSString stringWithFormat:@"dpkg -i '%@'", path]];
    [[XTHTTPServer sharedInstance] broadcastEvent:@"deb_installed" data:@{@"path":path, @"result":r[@"code"]}];
    return r;
}

#pragma mark - 启动脚本 / 守护进程

- (NSString *)startupConfPath {
    return [_resourceRoot stringByAppendingPathComponent:@"startup_conf.plist"];
}

- (NSDictionary *)startupConf {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:[self startupConfPath]] ?: @{};
    NSMutableDictionary *d = [@{@"startup_run":@NO,
                                @"startup_script":@"",
                                @"code":@0} mutableCopy];
    [d addEntriesFromDictionary:saved];
    d[@"code"] = @0;
    return d;
}

- (NSDictionary *)setStartupRun:(BOOL)on {
    NSMutableDictionary *d = [[self startupConf] mutableCopy];
    [d removeObjectForKey:@"code"];
    d[@"startup_run"] = @(on);
    BOOL ok = [d writeToFile:[self startupConfPath] atomically:YES];
    return @{@"code":@(ok ? 0 : -1), @"startup_run":@(on)};
}

- (NSDictionary *)selectStartupScript:(NSString *)name {
    NSMutableDictionary *d = [[self startupConf] mutableCopy];
    [d removeObjectForKey:@"code"];
    d[@"startup_script"] = name ?: @"";
    BOOL ok = [d writeToFile:[self startupConfPath] atomically:YES];
    return @{@"code":@(ok ? 0 : -1), @"script":name ?: @""};
}

- (NSDictionary *)daemonSpawn:(NSString *)filename {
    if (!filename.length) return @{@"code":@-1, @"error":@"empty filename"};
    NSString *path = [filename isAbsolutePath] ? filename :
                     [_resourceRoot stringByAppendingPathComponent:filename];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return @{@"code":@-1, @"error":@"file not found", @"path":path};
    NSString *cmd = [NSString stringWithFormat:@"chmod 755 '%@' && '%@'", path, path];
    NSDictionary *r = [self spawn:cmd];
    [[XTHTTPServer sharedInstance] broadcastEvent:@"daemon_spawn" data:@{@"path":path, @"result":r[@"code"] ?: @0}];
    return r;
}

#pragma mark - 录制配置 / WebRTC 信令

- (NSDictionary *)recordConf {
    NSString *p = [_resourceRoot stringByAppendingPathComponent:@"record_conf.plist"];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:p] ?: @{};
    NSMutableDictionary *d = [@{@"tap_interval":@(0.15), @"swipe_duration":@(300),
                                @"record_key_events":@YES, @"record_text":@YES} mutableCopy];
    [d addEntriesFromDictionary:saved];
    d[@"code"] = @0;
    return d;
}

- (NSDictionary *)volumeActionConf {
    NSString *p = [_resourceRoot stringByAppendingPathComponent:@"volume_action_conf.plist"];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:p] ?: @{};
    NSMutableDictionary *d = [@{@"volume_up":@"none", @"volume_down":@"none",
                                @"long_press":@"none"} mutableCopy];
    [d addEntriesFromDictionary:saved];
    d[@"code"] = @0;
    return d;
}

- (NSDictionary *)webrtcPoll {
    [_rtcLock lock];
    NSArray *pending = [_rtcQueue copy];
    [_rtcQueue removeAllObjects];
    [_rtcLock unlock];
    return @{@"code":@0, @"messages":pending};
}
- (void)webrtcAnswer:(NSString *)sdp {
    if (!sdp.length) return;
    NSDictionary *msg = @{@"type":@"answer", @"sdp":sdp};
    [_rtcLock lock];
    [_rtcQueue addObject:msg];
    [_rtcLock unlock];
    [[XTWebRTCMedia sharedInstance] handleRemoteMessage:msg];
}
- (void)webrtcIce:(NSString *)candidate {
    if (!candidate.length) return;
    NSDictionary *msg = @{@"type":@"ice", @"candidate":candidate};
    [_rtcLock lock];
    [_rtcQueue addObject:msg];
    [_rtcLock unlock];
    [[XTWebRTCMedia sharedInstance] handleRemoteMessage:msg];
}
- (void)webrtcStop {
    [_rtcLock lock];
    [_rtcQueue addObject:@{@"type":@"stop"}];
    [_rtcLock unlock];
    [[XTWebRTCMedia sharedInstance] stopSession];
}

- (NSDictionary *)webrtcMediaStats {
    return [[XTWebRTCMedia sharedInstance] sessionStats];
}

- (void)webrtcMediaStart:(NSDictionary *)config {
    [[XTWebRTCMedia sharedInstance] startSessionWithConfig:config];
}

#pragma mark - 签名链

- (NSDictionary *)signFile:(NSString *)path entitlements:(NSDictionary *)ent {
    return [[XTCodeSigner sharedInstance] signFileAtPath:path entitlements:ent];
}
- (NSDictionary *)verifySignature:(NSString *)path {
    return [[XTCodeSigner sharedInstance] verifyFileAtPath:path];
}
- (NSDictionary *)resignBundle:(NSString *)path {
    return [[XTCodeSigner sharedInstance] resignBundleAtPath:path];
}
- (NSDictionary *)signStatus {
    return [[XTCodeSigner sharedInstance] signStatus];
}

#pragma mark - UI 服务 / 自更新 / 音量键

- (void)showToast:(NSString *)text duration:(double)sec position:(NSInteger)pos {
    [[XTUIService sharedInstance] showToast:text duration:sec position:pos];
}
- (void)showPoseAtX:(double)x y:(double)y touchDown:(BOOL)down {
    [[XTUIService sharedInstance] showPoseAtX:x y:y touchDown:down];
}
- (void)showFloatingViewWithText:(NSString *)text {
    [[XTUIService sharedInstance] showFloatingViewWithText:text];
}
- (void)hideFloatingView { [[XTUIService sharedInstance] hideFloatingView]; }
- (void)showAlertTitle:(NSString *)title message:(NSString *)msg
               actions:(NSArray<NSString *> *)actions
            completion:(void (^)(NSInteger))completion {
    [[XTUIService sharedInstance] showAlertTitle:title message:msg actions:actions completion:completion];
}
- (nullable NSString *)volumeActionFor:(NSString *)key {
    return [[XTUIService sharedInstance] volumeActionFor:key];
}
- (void)handleVolumeKey:(NSString *)key {
    [[XTUIService sharedInstance] handleVolumeKey:key];
}

- (NSDictionary *)updateCheck {
    // 自更新是网络查询：同步等待最多 15 秒，结果一次性返回给 Web 面板。
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *result = @{@"code":@-1, @"error":@"timeout"};
    [[XTUIService sharedInstance] triggerUpdateCheckWithCompletion:^(NSDictionary *info) {
        result = info ?: @{@"code":@-1, @"error":@"empty response"};
        dispatch_semaphore_signal(sem);
    }];
    dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, t) != 0) return @{@"code":@-1, @"error":@"timeout"};
    return result;
}

- (NSDictionary *)volumeBind:(NSString *)key action:(NSString *)actionJSON {
    [[XTUIService sharedInstance] bindVolumeKey:key action:actionJSON];
    return @{@"code":@0, @"key":key ?: @"", @"action":actionJSON ?: @""};
}

#pragma mark - UDP / 云控 / 屏幕共享

- (NSDictionary *)udpStart:(UInt16)port {
    BOOL ok = port ? [[XTUDPControl sharedInstance] startOnPort:port]
                   : [[XTUDPControl sharedInstance] start];
    return @{@"code":@(ok ? 0 : -1), @"port":@([[XTUDPControl sharedInstance] port])};
}
- (void)udpStop { [[XTUDPControl sharedInstance] stop]; }
- (NSDictionary *)udpStats { return [[XTUDPControl sharedInstance] stats]; }

- (NSDictionary *)cloudConnect:(NSString *)host port:(UInt16)port token:(NSString *)token {
    BOOL ok = [[XTCloudControl sharedInstance] connectToServer:host port:port token:token];
    return @{@"code":@(ok ? 0 : -1), @"status":[[XTCloudControl sharedInstance] status]};
}
- (void)cloudDisconnect { [[XTCloudControl sharedInstance] disconnect]; }
- (NSDictionary *)cloudStatus { return [[XTCloudControl sharedInstance] status]; }
- (NSDictionary *)cloudConfig { return [[XTCloudControl sharedInstance] config]; }
- (BOOL)cloudSaveConfig:(NSDictionary *)cfg { return [[XTCloudControl sharedInstance] saveConfig:cfg]; }

- (NSDictionary *)screenStart:(NSInteger)fps quality:(double)q {
    BOOL ok = [[XTScreenShare sharedInstance] startWithFPS:fps quality:q];
    return @{@"code":@(ok ? 0 : -1), @"stats":[[XTScreenShare sharedInstance] lastFrameStats]};
}
- (void)screenStop { [[XTScreenShare sharedInstance] stop]; }
- (NSDictionary *)screenStats { return [[XTScreenShare sharedInstance] lastFrameStats]; }

@end
