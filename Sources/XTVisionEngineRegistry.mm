/**
 * XTVisionEngineRegistry.mm - 视觉引擎注册表
 *
 * 职责：
 *   - 维护已注册引擎及优先级；
 *   - 持久化用户选择的引擎 id（suite: edu.example.xautouch）；
 *   - active 引擎不可用时按 fallbackOrder 自动降级；
 *   - 所有对引擎的方法调用均包在 @try/@catch 中，异常按失败处理并继续降级；
 *   - 全部外部引擎不可用时返回 nil，由 XTVision.mm 使用内置 NCC/Vision 实现兜底。
 */
#import "XTVisionEngineRegistry.h"
#import "XTONNXEngine.h"
#import "XTNCNNEngine.h"
#import "XTTesseractEngine.h"
#import "XTLogger.h"

static NSString * const kXTSuiteName        = @"edu.example.xautouch";
static NSString * const kXTActiveIdKey      = @"XTVisionActiveEngineId";
static NSInteger const kXTDefaultPriority   = 100;

/// 安全读取类方法 engineId（Class 本身不声明该选择器，故桥接为 id）
static NSString *XTEngineIdOf(id<XTVisionEngine> engine) {
    if (!engine) return nil;
    Class cls = [engine class];
    if (![cls respondsToSelector:@selector(engineId)]) return nil;
    NSString *eid = [(id)cls engineId];
    return [eid isKindOfClass:[NSString class]] ? eid : nil;
}

/// 判断结果字典是否可用（不含非空 error 字段）
static BOOL XTResultUsable(NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) return NO;
    id err = [result objectForKey:@"error"];
    if (!err) return YES;
    if ([err isKindOfClass:[NSString class]]) return [err length] == 0;
    return NO;
}

@interface XTVisionEngineRegistry () {
    NSLock *_lock;                                  // 保护 _entries
    NSMutableArray<NSMutableDictionary *> *_entries; // @{@"engine":id, @"priority":NSNumber}
}
@end

@implementation XTVisionEngineRegistry

+ (instancetype)sharedRegistry {
    static XTVisionEngineRegistry *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

+ (void)registerBuiltInEngines {
    XTVisionEngineRegistry *reg = [self sharedRegistry];
    [reg registerEngine:[XTONNXEngine new]       priority:10];
    [reg registerEngine:[XTNCNNEngine new]       priority:20];
    [reg registerEngine:[XTTesseractEngine new]  priority:30];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [NSLock new];
        _entries = [NSMutableArray array];
    }
    return self;
}

#pragma mark - 注册 / 查询

- (void)registerEngine:(id<XTVisionEngine>)engine {
    [self registerEngine:engine priority:kXTDefaultPriority];
}

- (void)registerEngine:(id<XTVisionEngine>)engine priority:(NSInteger)priority {
    NSString *eid = XTEngineIdOf(engine);
    if (!eid.length) return;

    [_lock lock];
    for (NSDictionary *entry in _entries) {
        if ([XTEngineIdOf(entry[@"engine"]) isEqualToString:eid]) {
            [_lock unlock];
            return; // 幂等：同 id 不重复注册
        }
    }
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"engine"] = engine;
    entry[@"priority"] = @(priority);
    [_entries addObject:entry];
    [_entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger pa = [a[@"priority"] integerValue];
        NSInteger pb = [b[@"priority"] integerValue];
        if (pa < pb) return NSOrderedAscending;
        if (pa > pb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    [_lock unlock];
    XTLog(@"[XAutouch] 注册视觉引擎 %@ priority=%ld", eid, (long)priority);
}

/// 在锁内取引擎快照（调用方负责加锁）
- (NSArray<id<XTVisionEngine>> *)enginesLocked {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:_entries.count];
    for (NSDictionary *entry in _entries) {
        id<XTVisionEngine> e = entry[@"engine"];
        if (e) [out addObject:e];
    }
    return out;
}

- (NSArray<id<XTVisionEngine>> *)engines {
    [_lock lock];
    NSArray *out = [self enginesLocked];
    [_lock unlock];
    return out;
}

- (nullable id<XTVisionEngine>)selectEngineById:(NSString *)engineId {
    if (!engineId.length) return nil;
    [_lock lock];
    id<XTVisionEngine> found = nil;
    for (NSDictionary *entry in _entries) {
        if ([XTEngineIdOf(entry[@"engine"]) isEqualToString:engineId]) {
            found = entry[@"engine"];
            break;
        }
    }
    [_lock unlock];
    return found;
}

- (NSArray<NSString *> *)fallbackOrder {
    NSMutableArray *ids = [NSMutableArray array];
    for (id<XTVisionEngine> e in [self engines]) {
        NSString *eid = XTEngineIdOf(e);
        if (eid) [ids addObject:eid];
    }
    return ids;
}

#pragma mark - 持久化选择

- (nullable NSString *)activeEngineId {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kXTSuiteName];
    NSString *eid = [defs objectForKey:kXTActiveIdKey];
    [defs synchronize];
    return [eid isKindOfClass:[NSString class]] ? eid : nil;
}

- (void)setActiveEngineId:(NSString *)engineId {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kXTSuiteName];
    if (engineId.length) [defs setObject:engineId forKey:kXTActiveIdKey];
    else [defs removeObjectForKey:kXTActiveIdKey];
    [defs synchronize];
    XTLog(@"[XAutouch] 视觉引擎选择已保存: %@", engineId ?: @"(clear)");
}

#pragma mark - 可用性探测 / 降级

/// 调用 available 时捕获异常，异常一律视为不可用
- (BOOL)engineAvailableSafe:(id<XTVisionEngine>)engine {
    if (!engine) return NO;
    @try {
        return [engine available] ? YES : NO;
    } @catch (NSException *ex) {
        XTLog(@"[XAutouch] 引擎 %@ available 异常: %@", XTEngineIdOf(engine) ?: @"?", ex.reason ?: @"unknown");
        return NO;
    }
}

- (nullable id<XTVisionEngine>)activeEngine {
    NSArray *snapshot = [self engines];
    NSString *wanted = [self activeEngineId];

    // 1) 用户显式选择且可用 → 优先使用
    if (wanted.length) {
        for (id<XTVisionEngine> e in snapshot) {
            if ([XTEngineIdOf(e) isEqualToString:wanted] && [self engineAvailableSafe:e]) return e;
        }
    }
    // 2) 否则按优先级顺序取第一个可用引擎（自动降级）
    for (id<XTVisionEngine> e in snapshot) {
        if ([self engineAvailableSafe:e]) return e;
    }
    // 3) 全部不可用 → nil，由调用方走内置实现
    return nil;
}

- (NSArray<NSDictionary<NSString *, id> *> *)engineStatuses {
    NSString *wanted = [self activeEngineId];
    NSMutableArray *out = [NSMutableArray array];
    for (id<XTVisionEngine> e in [self engines]) {
        NSString *eid = XTEngineIdOf(e) ?: @"unknown";
        NSString *desc = @"";
        @try { desc = [e engineDescription] ?: @""; } @catch (__unused NSException *ex) { desc = @""; }
        BOOL avail = [self engineAvailableSafe:e];
        [out addObject:@{@"id":eid,
                         @"description":desc,
                         @"available":@(avail),
                         @"selected":@([eid isEqualToString:wanted])}];
    }
    return out;
}

#pragma mark - 转发调用（异常捕获 + 自动降级）

/// 候选顺序：当前 active 引擎优先，其余按优先级补齐，去重
- (NSArray<id<XTVisionEngine>> *)candidateEngines {
    NSMutableArray *out = [NSMutableArray array];
    id<XTVisionEngine> active = [self activeEngine];
    if (active) [out addObject:active];
    for (id<XTVisionEngine> e in [self engines]) {
        if (![out containsObject:e]) [out addObject:e];
    }
    return out;
}

- (nullable NSDictionary<NSString *, id> *)findTemplate:(NSString *)name threshold:(double)threshold {
    for (id<XTVisionEngine> e in [self candidateEngines]) {
        if (![self engineAvailableSafe:e]) continue;
        @try {
            NSDictionary *r = [e findTemplate:name threshold:threshold];
            if (XTResultUsable(r)) return r;
            XTLog(@"[XAutouch] 引擎 %@ findTemplate 返回 error，降级: %@",
                  XTEngineIdOf(e) ?: @"?", [r objectForKey:@"error"] ?: @"(nil)");
        } @catch (NSException *ex) {
            XTLog(@"[XAutouch] 引擎 %@ findTemplate 异常，降级: %@", XTEngineIdOf(e) ?: @"?", ex.reason ?: @"unknown");
        }
    }
    return nil;
}

- (nullable NSDictionary<NSString *, id> *)ocrExpect:(nullable NSString *)expect {
    for (id<XTVisionEngine> e in [self candidateEngines]) {
        if (![self engineAvailableSafe:e]) continue;
        @try {
            NSDictionary *r = [e ocrExpect:expect];
            if (XTResultUsable(r)) return r;
            XTLog(@"[XAutouch] 引擎 %@ ocr 返回 error，降级: %@",
                  XTEngineIdOf(e) ?: @"?", [r objectForKey:@"error"] ?: @"(nil)");
        } @catch (NSException *ex) {
            XTLog(@"[XAutouch] 引擎 %@ ocr 异常，降级: %@", XTEngineIdOf(e) ?: @"?", ex.reason ?: @"unknown");
        }
    }
    return nil;
}

@end
