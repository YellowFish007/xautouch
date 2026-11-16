/**
 * XTVision.mm - 图像模板匹配（NCC）与 OCR 触发（Apple Vision）
 *
 * 模板匹配：把截图与模板解码为灰度像素，滑动窗口计算归一化互相关，
 *           返回最佳匹配坐标与分数；step 自适应，避免在主线程做超大循环。
 * OCR：VNRecognizeTextRequest 同步执行并回收 topCandidates 文本与归一化文本框，
 *      expect 命中判断支持精确与包含两种模式。
 */
#import "XTVision.h"
#import "XTCapture.h"
#import "XTApplication.h"
#import "XTLogger.h"
#import "XTVisionEngine.h"
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

#pragma mark - 像素解码

typedef struct {
    unsigned char *gray;
    size_t w, h;
} XTGrayImage;

static XTGrayImage XTDecodeGray(CGImageRef cg) {
    XTGrayImage img = {0};
    if (!cg) return img;
    img.w = CGImageGetWidth(cg);
    img.h = CGImageGetHeight(cg);
    size_t bytesPerRow = img.w * 4;
    img.gray = (unsigned char *)calloc(img.w * img.h, 1);
    if (!img.gray) return img;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, img.w, img.h, 8, bytesPerRow, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(img.gray); img.gray = NULL; return img; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, img.w, img.h), cg);
    unsigned char *rgba = (unsigned char *)CGBitmapContextGetData(ctx);
    for (size_t i = 0; i < img.w * img.h; i++) {
        // Rec.601 亮度
        img.gray[i] = (unsigned char)((77*rgba[i*4] + 150*rgba[i*4+1] + 29*rgba[i*4+2]) >> 8);
    }
    CGContextRelease(ctx);
    return img;
}

static void XTFreeGray(XTGrayImage img) { if (img.gray) free(img.gray); }

@interface XTVision ()
- (NSDictionary *)builtinFindTemplate:(NSString *)name threshold:(double)threshold;
- (NSDictionary *)builtinOCR:(nullable NSString *)expect;
@end

@implementation XTVision
+ (instancetype)sharedInstance {
    static XTVision *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[self alloc] init];
        // 注册 ONNX / ncnn / Tesseract 适配器；模型或 dylib 缺失时它们会自报 unavailable。
        [XTVisionEngineRegistry registerBuiltInEngines];
    });
    return inst;
}

- (BOOL)ocrAvailable { return YES; }

#pragma mark - 多引擎调度

- (NSArray<NSDictionary *> *)engineStatuses {
    NSMutableArray *out = [NSMutableArray array];
    NSString *active = [self activeEngineId] ?: @"builtin";
    [out addObject:@{@"id":@"builtin", @"name":@"Apple Vision + NCC（内置）",
                     @"description":@"Apple Vision OCR + 自写 NCC 模板匹配",
                     @"available":@YES, @"selected":@([active isEqualToString:@"builtin"])}];
    [out addObjectsFromArray:[[XTVisionEngineRegistry sharedRegistry] engineStatuses] ?: @[]];
    return out;
}

- (BOOL)selectEngine:(NSString *)engineId {
    if ([engineId isEqualToString:@"builtin"]) {
        [[XTVisionEngineRegistry sharedRegistry] setActiveEngineId:@""];
        return YES;
    }
    id<XTVisionEngine> e = [[XTVisionEngineRegistry sharedRegistry] selectEngineById:engineId];
    if (!e) return NO;
    [[XTVisionEngineRegistry sharedRegistry] setActiveEngineId:engineId];
    return YES;
}

- (nullable NSString *)activeEngineId {
    NSString *eid = [[XTVisionEngineRegistry sharedRegistry] activeEngineId];
    return eid.length ? eid : @"builtin";
}

- (NSDictionary *)findTemplate:(NSString *)name threshold:(double)threshold {
    // Registry 内部按 active 优先 -> 优先级降级，并捕获异常/错误结果。
    NSDictionary *r = [[XTVisionEngineRegistry sharedRegistry] findTemplate:name threshold:threshold];
    if (r) return r;
    return [self builtinFindTemplate:name threshold:threshold];
}

- (NSDictionary *)ocrWithExpect:(NSString *)expect {
    NSDictionary *r = [[XTVisionEngineRegistry sharedRegistry] ocrExpect:expect];
    if (r) return r;
    return [self builtinOCR:expect];
}

#pragma mark - NCC 模板匹配

- (nullable CGImageRef)loadTemplate:(NSString *)name {
    NSString *path = name;
    if (![name isAbsolutePath]) {
        NSString *root = [XTApplication resourceRoot];
        path = [[root stringByAppendingPathComponent:@"templates"] stringByAppendingPathComponent:name];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            path = [root stringByAppendingPathComponent:name];
    }
    UIImage *ui = [UIImage imageWithContentsOfFile:path];
    return ui.CGImage;
}

- (NSDictionary *)builtinFindTemplate:(NSString *)name threshold:(double)threshold {
    if (!name.length) return @{@"found":@NO, @"x":@0, @"y":@0, @"score":@0, @"error":@"empty template"};

    NSString *shot = [[XTCapture sharedInstance] captureScreen];
    UIImage *shotImg = shot ? [UIImage imageWithContentsOfFile:shot] : nil;
    CGImageRef templateCG = [self loadTemplate:name];
    if (!shotImg || !templateCG) {
        if (templateCG) CGImageRelease(templateCG);
        return @{@"found":@NO, @"x":@0, @"y":@0, @"score":@0,
                 @"error":shotImg ? @"template not found" : @"capture failed"};
    }

    XTGrayImage tpl = XTDecodeGray(templateCG);
    XTGrayImage src = XTDecodeGray(shotImg.CGImage);
    CGImageRelease(templateCG);
    if (!tpl.gray || !src.gray || tpl.w > src.w || tpl.h > src.h) {
        XTFreeGray(tpl); XTFreeGray(src);
        return @{@"found":@NO, @"x":@0, @"y":@0, @"score":@0, @"error":@"invalid size"};
    }

    double n = (double)tpl.w * tpl.h;
    double tSum = 0, tSq = 0;
    for (size_t i = 0; i < tpl.w * tpl.h; i++) { tSum += tpl.gray[i]; tSq += (double)tpl.gray[i]*tpl.gray[i]; }
    double tMean = tSum / n;
    double tVar = tSq - tSum*tMean;
    if (tVar < 1e-6) { XTFreeGray(tpl); XTFreeGray(src);
        return @{@"found":@NO, @"x":@0, @"y":@0, @"score":@0, @"error":@"template has no variance"}; }

    // 步长自适应：模板越大步长越大，单次匹配控制在约 4M 次采样内
    size_t step = MAX(1, (size_t)sqrt((double)(src.w * src.h * tpl.w * tpl.h) / 4e6));
    double best = -1.0;
    size_t bestX = 0, bestY = 0;

    for (size_t y = 0; y + tpl.h <= src.h; y += step) {
        for (size_t x = 0; x + tpl.w <= src.w; x += step) {
            double sSum = 0, sSq = 0, cross = 0;
            for (size_t ty = 0; ty < tpl.h; ty++) {
                const unsigned char *sRow = src.gray + (y + ty) * src.w + x;
                const unsigned char *tRow = tpl.gray + ty * tpl.w;
                for (size_t tx = 0; tx < tpl.w; tx++) {
                    double s = sRow[tx], t = tRow[tx];
                    sSum += s; sSq += s*s; cross += s*t;
                }
            }
            double sMean = sSum / n;
            double sVar = sSq - sSum*sMean;
            double denom = sqrt(tVar * sVar);
            if (denom < 1e-6) continue;
            double score = (cross - tSum*sMean) / denom;
            if (score > best) { best = score; bestX = x; bestY = y; }
        }
    }
    size_t tw = tpl.w, th = tpl.h;
    XTFreeGray(tpl); XTFreeGray(src);

    BOOL found = best >= threshold;
    XTLog(@"[XAutouch] NCC %@ best=%.4f threshold=%.2f -> %@", name, best, threshold, found ? @"hit" : @"miss");
    return @{@"found":@(found), @"x":@(bestX), @"y":@(bestY),
             @"score":@(best), @"template":name,
             @"w":@(tw), @"h":@(th)};
}

#pragma mark - OCR

- (NSDictionary *)builtinOCR:(NSString *)expect {
    NSString *shot = [[XTCapture sharedInstance] captureScreen];
    UIImage *img = shot ? [UIImage imageWithContentsOfFile:shot] : nil;
    if (!img || !img.CGImage) return @{@"matched":@NO, @"texts":@[], @"error":@"capture failed"};

    CGImageRef cg = img.CGImage;
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    NSError *err = nil;
    BOOL ok = [handler performRequests:@[req] error:&err];
    if (!ok || err)
        return @{@"matched":@NO, @"texts":@[], @"error":err.localizedDescription ?: @"vision failed"};

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *boxes = [NSMutableArray array];
    CGFloat W = (CGFloat)CGImageGetWidth(cg), H = (CGFloat)CGImageGetHeight(cg);
    for (VNRecognizedTextObservation *obs in req.results) {
        VNRecognizedText *top = [[obs topCandidates:1] firstObject];
        if (!top) continue;
        [texts addObject:top.string];
        CGRect bb = obs.boundingBox;   // 归一化，原点左下
        [boxes addObject:@{@"text":top.string,
                           @"x":@(bb.origin.x * W),
                           @"y":@((1 - bb.origin.y - bb.size.height) * H),
                           @"w":@(bb.size.width * W),
                           @"h":@(bb.size.height * H),
                           @"confidence":@(top.confidence)}];
    }

    BOOL matched = NO;
    if (expect.length) {
        for (NSString *t in texts) {
            if ([t isEqualToString:expect] || [t containsString:expect]) { matched = YES; break; }
        }
    } else {
        matched = texts.count > 0;
    }
    XTLog(@"[XAutouch] OCR %lu 行，expect=%@ -> %@", (unsigned long)texts.count, expect ?: @"(any)", matched ? @"hit" : @"miss");
    return @{@"matched":@(matched), @"texts":texts, @"boxes":boxes,
             @"expect":expect ?: @"", @"count":@(texts.count)};
}

@end
