/**
 * XTVisionEngine.h - 可插拔视觉引擎协议与注册表
 *
 * 设计目标：
 *   1. XTVision 只依赖本文件定义的协议，不再直接依赖任何第三方视觉库；
 *   2. ONNX / ncnn / Tesseract 三个适配器全部通过 dlsym 运行时加载，
 *      库文件或模型文件缺失时 available=NO，注册表自动降级；
 *   3. 内置实现（Apple Vision + 自写 NCC）保持在 XTVision.mm 中，
 *      当注册表没有任何可用引擎时由 XTVision.mm 自己兜底。
 *
 * 返回值约定（所有引擎统一）：
 *   findTemplate:  @{found, x, y, score, w, h, template} 或 @{error:...}
 *   ocrExpect:     @{matched, texts, boxes, count, expect} 或 @{error:...}
 *   出现 error 字段视为调用失败，注册表会降级到下一个引擎。
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 引擎协议

@protocol XTVisionEngine <NSObject>

/// 引擎唯一标识，例如 @"onnx" / @"ncnn" / @"tesseract"
+ (NSString *)engineId;

/// 运行时探测：动态库可加载、依赖符号可解析、模型/语言包文件齐备才返回 YES
- (BOOL)available;

/// 模板匹配。name 可以是绝对路径，也可以是 resourceRoot/templates 下的文件名
- (NSDictionary<NSString *, id> *)findTemplate:(NSString *)name threshold:(double)threshold;

/// OCR。expect 为期望文本（nil 表示任意文本），命中判断由引擎自行完成
- (NSDictionary<NSString *, id> *)ocrExpect:(nullable NSString *)expect;

/// 人类可读描述，供 /api/vision/engines 与日志使用
- (NSString *)engineDescription;

@end

#pragma mark - 注册表

@interface XTVisionEngineRegistry : NSObject

/// 全局单例
+ (instancetype)sharedRegistry;

/// 一次性注册三个外部适配器（ONNX / ncnn / Tesseract）。幂等，可重复调用
+ (void)registerBuiltInEngines;

/// 注册引擎。未指定优先级时使用 100；数值越小优先级越高
- (void)registerEngine:(id<XTVisionEngine>)engine;

/// 按显式优先级注册（数值越小越优先）。重复 engineId 会被忽略
- (void)registerEngine:(id<XTVisionEngine>)engine priority:(NSInteger)priority;

/// 全部已注册引擎，按优先级升序（高优先级在前）
- (NSArray<id<XTVisionEngine>> *)engines;

/// 按 engineId 查找（不检查 available）
- (nullable id<XTVisionEngine>)selectEngineById:(NSString *)engineId;

/// 当前生效引擎。用户选定引擎不可用时按 fallbackOrder 自动降级；
/// 全部不可用时返回 nil，调用方应使用 XTVision.mm 中的内置实现
- (nullable id<XTVisionEngine>)activeEngine;

/// 用户持久化选择的 engineId（NSUserDefaults suite: edu.example.xautouch）
- (nullable NSString *)activeEngineId;

/// 设置并持久化 engineId。传入不存在的 id 会被接受，但 activeEngine 会降级
- (void)setActiveEngineId:(NSString *)engineId;

/// 全部已注册引擎 id，按优先级升序
- (NSArray<NSString *> *)fallbackOrder;

/// 引擎状态快照：@{@"id":..., @"description":..., @"available":@(YES/NO), @"selected":@(YES/NO)}
- (NSArray<NSDictionary<NSString *, id> *> *)engineStatuses;

#pragma mark 转发调用（带异常捕获与自动降级）

/// 依次尝试可用引擎，返回第一个不含 error 的结果；全部失败返回 nil（交给内置实现）
- (nullable NSDictionary<NSString *, id> *)findTemplate:(NSString *)name threshold:(double)threshold;
- (nullable NSDictionary<NSString *, id> *)ocrExpect:(nullable NSString *)expect;

@end

NS_ASSUME_NONNULL_END
