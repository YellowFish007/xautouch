/**
 * XTScriptEngine.mm - 真实 Lua 5.4 VM + xtouch 原生桥接 + 脚本加解密
 *
 * 不再使用逐行解析：luaL_loadbuffer 编译、lua_pcall 执行、lua 错误带回行号。
 * xtouch.* 模块全部注册为 C 函数，直接调用触摸/截图/视觉/日志单例。
 * 加密脚本使用 AES-128-CBC（CommonCrypto），格式 "XTAENC01" + 密文，输出 .xxt。
 */
#import "XTScriptEngine.h"
#import "XTApplication.h"
#import "XTTouchSynthesizer.h"
#import "XTCapture.h"
#import "XTVision.h"
#import "XTLogger.h"
#import "lua.h"
#import "lauxlib.h"
#import "lualib.h"
#import <CommonCrypto/CommonCrypto.h>

static XTScriptEngine *gXTEngine = nil;
static const unsigned char kXTKey[16] = {'X','A','u','t','o','u','c','h','2','0','2','6','G','r','a','d'};
static const unsigned char kXTIV[16]  = {'X','A','u','t','o','u','c','h','I','V','!','!','!','!','!','!'};
static NSString *const kXTMagic = @"XTAENC01";

@interface XTScriptEngine (XTInternal)
- (BOOL)isStopped;
- (void)waitIfPaused;
@end

#pragma mark - Lua C 桥接

#define XT_CONTROL(L) do { \
    if ([gXTEngine isStopped]) return luaL_error(L, "script stopped"); \
    [gXTEngine waitIfPaused]; \
} while (0)

static int xt_tap(lua_State *L) {
    XT_CONTROL(L);
    double x = luaL_checknumber(L, 1), y = luaL_checknumber(L, 2);
    [[XTTouchSynthesizer sharedInstance] tapAtX:x y:y];
    return 0;
}
static int xt_touchDown(lua_State *L) {
    XT_CONTROL(L);
    [[XTTouchSynthesizer sharedInstance] touchDown:luaL_checknumber(L,1) y:luaL_checknumber(L,2)
                                                id:(uint32_t)luaL_optinteger(L,3,1)];
    return 0;
}
static int xt_touchMove(lua_State *L) {
    XT_CONTROL(L);
    [[XTTouchSynthesizer sharedInstance] touchMove:luaL_checknumber(L,1) y:luaL_checknumber(L,2)
                                                id:(uint32_t)luaL_optinteger(L,3,1)];
    return 0;
}
static int xt_touchUp(lua_State *L) {
    XT_CONTROL(L);
    [[XTTouchSynthesizer sharedInstance] touchUp:luaL_checknumber(L,1) y:luaL_checknumber(L,2)
                                              id:(uint32_t)luaL_optinteger(L,3,1)];
    return 0;
}
static int xt_swipe(lua_State *L) {
    XT_CONTROL(L);
    [[XTTouchSynthesizer sharedInstance] swipeFromX:luaL_checknumber(L,1) y:luaL_checknumber(L,2)
                                                toX:luaL_checknumber(L,3) y:luaL_checknumber(L,4)
                                           duration:luaL_optnumber(L,5,300)];
    return 0;
}
static int xt_curve(lua_State *L) {
    XT_CONTROL(L);
    luaL_checktype(L, 1, LUA_TTABLE);
    NSMutableArray *pts = [NSMutableArray array];
    lua_pushnil(L);
    while (lua_next(L, 1) != 0) {
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "x"); double x = lua_tonumber(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "y"); double y = lua_tonumber(L, -1); lua_pop(L, 1);
            [pts addObject:@{@"x":@(x), @"y":@(y)}];
        }
        lua_pop(L, 1);
    }
    [[XTTouchSynthesizer sharedInstance] dragCurveThrough:pts
                                                  duration:luaL_optnumber(L,2,500) async:NO];
    return 0;
}
static int xt_wheel(lua_State *L) {
    XT_CONTROL(L);
    [[XTTouchSynthesizer sharedInstance] wheelAtX:luaL_checknumber(L,1) y:luaL_checknumber(L,2)
                                            delta:luaL_checknumber(L,3) async:NO];
    return 0;
}
static int xt_input(lua_State *L) {
    XT_CONTROL(L);
    [[XTTouchSynthesizer sharedInstance] inputText:[NSString stringWithUTF8String:luaL_checkstring(L,1)]];
    return 0;
}
static int xt_key(lua_State *L) {
    XT_CONTROL(L);
    [[XTTouchSynthesizer sharedInstance] pressKey:[NSString stringWithUTF8String:luaL_checkstring(L,1)]];
    return 0;
}
static int xt_pasteboardRead(lua_State *L) {
    XT_CONTROL(L);
    lua_pushstring(L, [[XTTouchSynthesizer sharedInstance] pasteboardRead].UTF8String);
    return 1;
}
static int xt_pasteboardWrite(lua_State *L) {
    XT_CONTROL(L);
    [[XTTouchSynthesizer sharedInstance] pasteboardWrite:[NSString stringWithUTF8String:luaL_checkstring(L,1)]];
    return 0;
}
static int xt_sleep(lua_State *L) {
    XT_CONTROL(L);
    long ms = (long)luaL_checknumber(L, 1);
    long left = ms;
    while (left > 0) {
        if ([gXTEngine isStopped]) return luaL_error(L, "script stopped");
        [gXTEngine waitIfPaused];
        long slice = MIN(left, 20L);
        usleep((useconds_t)(slice * 1000));
        left -= slice;
    }
    return 0;
}
static int xt_snapshot(lua_State *L) {
    XT_CONTROL(L);
    NSString *p = [[XTCapture sharedInstance] captureScreen] ?: @"";
    lua_pushstring(L, p.UTF8String);
    return 1;
}
static int xt_findImage(lua_State *L) {
    XT_CONTROL(L);
    NSDictionary *r = [[XTVision sharedInstance] findTemplate:[NSString stringWithUTF8String:luaL_checkstring(L,1)]
                                                     threshold:luaL_optnumber(L,2,0.9)];
    lua_newtable(L);
    lua_pushboolean(L, [r[@"found"] boolValue]); lua_setfield(L, -2, "found");
    lua_pushnumber(L, [r[@"x"] doubleValue]);    lua_setfield(L, -2, "x");
    lua_pushnumber(L, [r[@"y"] doubleValue]);    lua_setfield(L, -2, "y");
    lua_pushnumber(L, [r[@"score"] doubleValue]);lua_setfield(L, -2, "score");
    return 1;
}
static int xt_ocr(lua_State *L) {
    XT_CONTROL(L);
    NSDictionary *r = [[XTVision sharedInstance] ocrWithExpect:
                       lua_isnoneornil(L,1) ? nil : [NSString stringWithUTF8String:luaL_checkstring(L,1)]];
    lua_newtable(L);
    lua_pushboolean(L, [r[@"matched"] boolValue]); lua_setfield(L, -2, "matched");
    lua_newtable(L);
    NSArray *texts = r[@"texts"] ?: @[];
    for (NSUInteger i = 0; i < texts.count; i++) {
        lua_pushinteger(L, (lua_Integer)i + 1);
        lua_pushstring(L, [texts[i] UTF8String]);
        lua_settable(L, -3);
    }
    lua_setfield(L, -2, "texts");
    return 1;
}
static int xt_log(lua_State *L) {
    XT_CONTROL(L);
    XTLog(@"[XAutouch:lua] %s", luaL_checkstring(L, 1));
    return 0;
}
static int xt_recordStart(lua_State *L) {
    XT_CONTROL(L);
    [[XTTouchSynthesizer sharedInstance] startRecording];
    return 0;
}
static int xt_recordStop(lua_State *L) {
    XT_CONTROL(L);
    NSArray *events = [[XTTouchSynthesizer sharedInstance] stopRecording];
    NSData *d = [NSJSONSerialization dataWithJSONObject:events options:0 error:nil];
    lua_pushstring(L, [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"[]" UTF8String]);
    return 1;
}
static int xt_playback(lua_State *L) {
    XT_CONTROL(L);
    NSString *json = [NSString stringWithUTF8String:luaL_checkstring(L, 1)];
    NSArray *events = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                     options:0 error:nil];
    [[XTTouchSynthesizer sharedInstance] playbackEvents:events ?: @[]];
    return 0;
}

static const luaL_Reg kXTLib[] = {
    {"tap", xt_tap}, {"down", xt_touchDown}, {"move", xt_touchMove}, {"up", xt_touchUp},
    {"swipe", xt_swipe}, {"curve", xt_curve}, {"wheel", xt_wheel},
    {"input", xt_input}, {"key", xt_key},
    {"pasteboard_read", xt_pasteboardRead}, {"pasteboard_write", xt_pasteboardWrite},
    {"sleep", xt_sleep}, {"snapshot", xt_snapshot},
    {"findImage", xt_findImage}, {"ocr", xt_ocr}, {"log", xt_log},
    {"record_start", xt_recordStart}, {"record_stop", xt_recordStop}, {"playback", xt_playback},
    {NULL, NULL}
};

#pragma mark - XTScriptEngine

@implementation XTScriptEngine {
    lua_State *_L;
    BOOL _stopped;
    BOOL _paused;
    NSString *_selected;
}

+ (instancetype)sharedInstance {
    static XTScriptEngine *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        gXTEngine = self;
        _selected = @"";
        [self setupLua];
    }
    return self;
}

- (void)setupLua {
    _L = luaL_newstate();
    if (!_L) { XTLog(@"[XAutouch] Lua 状态机创建失败"); return; }
    luaL_openlibs(_L);
    luaL_newlib(_L, kXTLib);
    lua_setglobal(_L, "xtouch");
    lua_getglobal(_L, "xtouch");
    lua_setglobal(_L, "xt");  // 兼容简写
    XTLog(@"[XAutouch] Lua %s 就绪，xtouch 模块 %lu 函数", LUA_VERSION,
          (unsigned long)(sizeof(kXTLib)/sizeof(kXTLib[1]) - 1));
}

- (BOOL)isStopped { return _stopped; }
- (void)waitIfPaused {
    while (_paused && !_stopped) usleep(20000);
}

#pragma mark - 控制

- (void)stop  { _stopped = YES; _paused = NO; }
- (void)pause { _paused = YES; }
- (void)resume{ _paused = NO; }
- (BOOL)isRunning { return _L != nil && !_stopped; }

#pragma mark - 语法检查（真 Lua 编译器）

- (NSArray<NSDictionary *> *)validateSource:(NSString *)source {
    NSMutableArray *diags = [NSMutableArray array];
    if (!source.length) return diags;
    if (!_L) [self setupLua];
    int rc = luaL_loadbuffer(_L, source.UTF8String, [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                             "=script");
    if (rc != LUA_OK) {
        const char *err = lua_tostring(_L, -1);
        NSString *msg = err ? [NSString stringWithUTF8String:err] : @"syntax error";
        NSInteger line = 0;
        if (msg.length > 8) {
            NSRange lr = [msg rangeOfString:@":" options:0 range:NSMakeRange(7, MIN(20, (NSInteger)msg.length-7))];
            if (lr.location != NSNotFound) {
                NSUInteger tail = msg.length - lr.location - 1;
                NSRange nr = [msg rangeOfString:@":" options:0 range:NSMakeRange(lr.location+1, tail)];
                if (nr.location != NSNotFound)
                    line = [[msg substringWithRange:NSMakeRange(lr.location+1, nr.location-lr.location-1)] integerValue];
            }
        }
        [diags addObject:@{@"line":@(line), @"column":@1, @"severity":@"error", @"message":msg}];
        lua_pop(_L, 1);
    }

    // 语义检查：xtouch.<name> 是否为已注册函数
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                               @"xtouch\\.([A-Za-z_][A-Za-z0-9_]*)" options:0 error:nil];
    NSMutableSet *known = [NSMutableSet set];
    for (NSUInteger i = 0; kXTLib[i].name; i++) [known addObject:@(kXTLib[i].name)];
    [re enumerateMatchesInString:source options:0 range:NSMakeRange(0, source.length)
                       usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags f, BOOL *stop) {
        NSString *fn = [source substringWithRange:[r rangeAtIndex:1]];
        if (![known containsObject:fn]) {
            NSUInteger line = [[source substringToIndex:r.range.location] componentsSeparatedByString:@"\n"].count;
            [diags addObject:@{@"line":@(line), @"column":@1, @"severity":@"warning",
                               @"message":[NSString stringWithFormat:@"未知 xtouch 函数 %@", fn]}];
        }
    }];
    return diags;
}

#pragma mark - 执行

- (NSDictionary *)runSource:(NSString *)source {
    if (!source) return @{@"code":@2, @"error":@"empty script"};
    if (!_L) [self setupLua];
    _stopped = NO; _paused = NO;
    int rc = luaL_loadbuffer(_L, source.UTF8String, [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                             "=xautouch");
    if (rc != LUA_OK) {
        const char *raw = lua_tostring(_L, -1);
        NSString *err = raw ? [NSString stringWithUTF8String:raw] : @"syntax error";
        lua_pop(_L, 1);
        return @{@"code":@2, @"error":err};
    }
    XTLog(@"[XAutouch] 执行 Lua 脚本 (%lu bytes)", (unsigned long)source.length);
    rc = lua_pcall(_L, 0, 0, 0);
    if (rc != LUA_OK) {
        const char *raw2 = lua_tostring(_L, -1);
        NSString *err = raw2 ? [NSString stringWithUTF8String:raw2] : @"runtime error";
        lua_pop(_L, 1);
        return @{@"code":@3, @"error":err, @"stopped":@(_stopped)};
    }
    return @{@"code":@0, @"message":@"ok"};
}

- (NSString *)resolveScriptPath:(NSString *)name {
    if ([name isAbsolutePath]) return name.stringByStandardizingPath;
    NSString *base = [XTApplication resourceRoot];
    NSString *rel = name;
    if (![name containsString:@"/"]) {
        if (![name hasSuffix:@".lua"] && ![name hasSuffix:@".xxt"])
            rel = [name stringByAppendingString:@".lua"];
        rel = [@"scripts" stringByAppendingPathComponent:rel];
    }
    return [[base stringByAppendingPathComponent:rel] stringByStandardizingPath];
}

- (NSDictionary *)runScriptNamed:(NSString *)name {
    NSString *path = [self resolveScriptPath:name ?: @"main"];
    NSString *source = nil;
    if ([[path pathExtension] isEqualToString:@"xxt"]) {
        source = [self decryptFile:path];
    } else {
        source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    }
    if (!source) {
        XTLog(@"[XAutouch] 脚本不存在: %@", path);
        return @{@"code":@2, @"error":[NSString stringWithFormat:@"script not found: %@", path]};
    }
    NSDictionary *r = [self runSource:source];
    NSMutableDictionary *out = [r mutableCopy];
    out[@"name"] = name;
    out[@"path"] = path;
    return out;
}

#pragma mark - 文件管理

- (NSString *)resolvePath:(NSString *)p {
    if (!p.length) return [[XTApplication resourceRoot] stringByStandardizingPath];
    if ([p isAbsolutePath]) return p.stringByStandardizingPath;
    return [[[XTApplication resourceRoot] stringByAppendingPathComponent:p] stringByStandardizingPath];
}

- (NSArray<NSString *> *)scriptList {
    NSString *dir = [[XTApplication resourceRoot] stringByAppendingPathComponent:@"scripts"];
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    return [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id o, NSDictionary *b) {
        NSString *f = o;
        return [f hasSuffix:@".lua"] || [f hasSuffix:@".xxt"];
    }]];
}

- (nullable NSString *)readFile:(NSString *)path {
    NSString *full = [self resolvePath:path];
    NSString *root = [XTApplication resourceRoot];
    if (![full hasPrefix:root]) return nil;
    if ([[full pathExtension] isEqualToString:@"xxt"]) return [self decryptFile:full];
    return [NSString stringWithContentsOfFile:full encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)writeFile:(NSString *)path content:(NSString *)content {
    NSString *full = [self resolvePath:path];
    NSString *root = [XTApplication resourceRoot];
    if (![full hasPrefix:root]) return NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:[full stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [content writeToFile:full atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)removeFile:(NSString *)path {
    NSString *full = [self resolvePath:path];
    if (![full hasPrefix:[XTApplication resourceRoot]]) return NO;
    return [[NSFileManager defaultManager] removeItemAtPath:full error:nil];
}
- (BOOL)renameFile:(NSString *)from to:(NSString *)to {
    NSString *a = [self resolvePath:from], *b = [self resolvePath:to];
    if (![a hasPrefix:[XTApplication resourceRoot]] || ![b hasPrefix:[XTApplication resourceRoot]]) return NO;
    return [[NSFileManager defaultManager] moveItemAtPath:a toPath:b error:nil];
}
- (BOOL)copyFile:(NSString *)from to:(NSString *)to {
    NSString *a = [self resolvePath:from], *b = [self resolvePath:to];
    if (![a hasPrefix:[XTApplication resourceRoot]] || ![b hasPrefix:[XTApplication resourceRoot]]) return NO;
    return [[NSFileManager defaultManager] copyItemAtPath:a toPath:b error:nil];
}
- (BOOL)moveFile:(NSString *)from to:(NSString *)to { return [self renameFile:from to:to]; }
- (BOOL)mkdir:(NSString *)path {
    NSString *full = [self resolvePath:path];
    if (![full hasPrefix:[XTApplication resourceRoot]]) return NO;
    return [[NSFileManager defaultManager] createDirectoryAtPath:full
                                      withIntermediateDirectories:YES attributes:nil error:nil];
}
- (BOOL)rmdir:(NSString *)path { return [self removeFile:path]; }
- (BOOL)recycle:(NSString *)path {
    NSString *full = [self resolvePath:path];
    NSString *root = [XTApplication resourceRoot];
    if (![full hasPrefix:root]) return NO;
    NSString *trash = [root stringByAppendingPathComponent:@"recycle"];
    [[NSFileManager defaultManager] createDirectoryAtPath:trash withIntermediateDirectories:YES
                                                  attributes:nil error:nil];
    NSString *dest = [trash stringByAppendingPathComponent:full.lastPathComponent];
    return [[NSFileManager defaultManager] moveItemAtPath:full toPath:dest error:nil] ||
           [[NSFileManager defaultManager] removeItemAtPath:full error:nil];
}

- (NSArray<NSDictionary *> *)fileListAt:(NSString *)dir {
    NSString *full = [self resolvePath:dir];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:full error:nil] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in names) {
        NSString *p = [full stringByAppendingPathComponent:n];
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        BOOL isDir = NO;
        [fm fileExistsAtPath:p isDirectory:&isDir];
        [out addObject:@{@"name":n, @"path":p, @"is_dir":@(isDir),
                         @"size":@([attr[NSFileSize] unsignedLongLongValue]),
                         @"mtime":@([attr[NSFileModificationDate] timeIntervalSince1970])}];
    }
    return out;
}

#pragma mark - 脚本加解密（AES-128-CBC）

- (nullable NSString *)encryptFile:(NSString *)path {
    NSString *srcPath = [self resolveScriptPath:path];
    NSData *plain = [NSData dataWithContentsOfFile:srcPath];
    if (!plain) return nil;
    size_t outSize = plain.length + kCCBlockSizeAES128 + 16;
    NSMutableData *cipher = [NSMutableData dataWithLength:outSize];
    size_t num = 0;
    CCCryptorStatus st = CCCrypt(kCCEncrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                 kXTKey, kCCKeySizeAES128, kXTIV,
                                 plain.bytes, plain.length, cipher.mutableBytes, outSize, &num);
    if (st != kCCSuccess) return nil;
    [cipher setLength:num];
    NSMutableData *out = [NSMutableData dataWithData:[kXTMagic dataUsingEncoding:NSASCIIStringEncoding]];
    [out appendData:cipher];
    NSString *dest = [[srcPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"xxt"];
    return [out writeToFile:dest atomically:YES] ? dest : nil;
}

- (nullable NSString *)decryptFile:(NSString *)path {
    NSData *all = [NSData dataWithContentsOfFile:path];
    if (!all || all.length <= kXTMagic.length) return nil;
    NSData *cipher = [all subdataWithRange:NSMakeRange(kXTMagic.length, all.length - kXTMagic.length)];
    size_t outSize = cipher.length + kCCBlockSizeAES128;
    NSMutableData *plain = [NSMutableData dataWithLength:outSize];
    size_t num = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                 kXTKey, kCCKeySizeAES128, kXTIV,
                                 cipher.bytes, cipher.length, plain.mutableBytes, outSize, &num);
    if (st != kCCSuccess) return nil;
    [plain setLength:num];
    return [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding];
}

#pragma mark - 当前脚本

- (void)selectScript:(NSString *)name { _selected = [name copy] ?: @""; }
- (NSString *)selectedScript { return _selected ?: @""; }

@end
