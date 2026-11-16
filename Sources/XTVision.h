#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/**
 * 视觉门面：内置 Apple Vision OCR + NCC 模板匹配，并作为可插拔引擎架构的默认实现。
 * 外部引擎（ONNX / ncnn / Tesseract）由 XTVisionEngineRegistry 在运行时探测，
 * 有模型且可用时优先，否则自动回退到内置实现。
 */
@interface XTVision : NSObject
+ (instancetype)sharedInstance;
- (NSDictionary *)findTemplate:(NSString *)name threshold:(double)threshold;
- (NSDictionary *)ocrWithExpect:(nullable NSString *)expect;
- (BOOL)ocrAvailable;

#pragma mark - 多引擎
/// 所有引擎状态（含可用性与描述）
- (NSArray<NSDictionary *> *)engineStatuses;
/// 切换当前引擎（engineId 来自 engineStatuses）；返回是否成功
- (BOOL)selectEngine:(NSString *)engineId;
- (nullable NSString *)activeEngineId;

@end
NS_ASSUME_NONNULL_END
