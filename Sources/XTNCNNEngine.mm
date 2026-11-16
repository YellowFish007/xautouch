/**
 * XTNCNNEngine.mm - ncnn 适配器（dlsym 运行时加载）
 *
 * 通过 extern "C" 桥接函数调用 ncnn，避免 ABI/头文件编译依赖。
 * 所有符号名集中为常量，便于不同版本 dylib 适配。
 * 库缺失、桥接符号缺失、param/bin 缺失时 available=NO，公开方法返回 error 字典。
 *
 * 桥接函数输出 JSON（写入 outJson，返回写入字节数；<=0 表示失败）：
 *   [{"x":12,"y":34,"w":80,"h":80,"score":0.91,"label":"..."} , ...]
 */
#import "XTNCNNEngine.h"
#import "XTApplication.h"
#import "XTCapture.h"
#import "XTLogger.h"
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

#pragma mark - 符号常量（集中定义，便于适配不同 dylib）

static NSString * const kXTNCNNLibraryName      = @"libncnn.dylib";
static NSString * const kXTNCNNDetectExSymbol   = @"xt_ncnn_detect_ex";
static NSString * const kXTNCNNDetectSymbol     = @"xt_ncnn_detect";
static NSString * const kXTNCNNNetCtorSymbol    = @"_ZN4ncnn6NetC1Ev"; // ncnn::Net 构造函数，仅作库指纹
static NSString * const kXTNCNNParamFile        = @"ncnn.param";
static NSString * const kXTNCNNBinFile          = @"ncnn.bin";
static NSUInteger const kXTNCNNOutputCapacity   = 8192;

#pragma mark - 桥接函数签名

/// 首选：显式传入模型路径。返回写入 outJson 的字节数，<=0 为失败
typedef int (*XTNCNNDetectExFn)(const char *paramPath, const char *binPath,
                                const unsigned char *rgba, int width, int height,
                                float threshold, char *outJson, int outCap);

/// 兼容：桥接内部使用默认模型路径
typedef int (*XTNCNNDetectFn)(const unsigned char *rgba, int width, int height,
                              float threshold, char *outJson, int outCap);

static XTNCNNDetectExFn gXTNCNNDetectEx = NULL;
static XTNCNNDetectFn   gXTNCNNDetect   = NULL;

#pragma mark - 工具

static NSString *XTNCNNModelPath(NSString *file) {
    return [[[XTApplication resourceRoot] stringByAppendingPathComponent:@"models"] stringByAppendingPathComponent:file];
}

static unsigned char *XTNCNNDecodeRGBA(UIImage *img, int *outW, int *outH) {
    CGImageRef cg = img.CGImage;
    if (!cg) return NULL;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    size_t bpr = w * 4;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, bpr, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
    unsigned char *src = (unsigned char *)CGBitmapContextGetData(ctx);
    unsigned char *dst = (unsigned char *)malloc(bpr * h);
    if (dst && src) memcpy(dst, src, bpr * h);
    CGContextRelease(ctx);
    if (!dst) return NULL;
    if (outW) *outW = (int)w;
    if (outH) *outH = (int)h;
    return dst;
}

#pragma mark - 引擎实现

@implementation XTNCNNEngine

+ (NSString *)engineId { return @"ncnn"; }

- (instancetype)init {
    self = [super init];
    if (self) _ncnnHandle = NULL;
    return self;
}

- (void)dealloc {
    if (_ncnnHandle) dlclose(_ncnnHandle);
}

- (NSString *)engineDescription {
    return @"ncnn（extern C 桥接 / dlsym）";
}

/// 懒加载 dylib 并解析全部符号；失败返回 NO
- (BOOL)loadLibraryIfNeeded {
    @synchronized([XTNCNNEngine class]) {
        if (_ncnnHandle) return YES;
        NSString *root = [XTApplication resourceRoot];
        NSString *jb = [[XTApplication sharedInstance] jbRoot];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        void (^add)(NSString *) = ^(NSString *p) {
            if (p.length && ![paths containsObject:p]) [paths addObject:p];
        };
        add([root stringByAppendingPathComponent:[@"lib" stringByAppendingPathComponent:kXTNCNNLibraryName]]);
        if (jb.length) add([jb stringByAppendingPathComponent:[@"/usr/lib/" stringByAppendingPathComponent:kXTNCNNLibraryName]]);
        add([@"/usr/lib/" stringByAppendingPathComponent:kXTNCNNLibraryName]);
        add([@"/var/jb/usr/lib/" stringByAppendingPathComponent:kXTNCNNLibraryName]);
        add(kXTNCNNLibraryName); // 交给 dyld 搜索

        for (NSString *path in paths) {
            void *h = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
            if (!h) continue;
            XTNCNNDetectExFn ex = reinterpret_cast<XTNCNNDetectExFn>(dlsym(h, kXTNCNNDetectExSymbol.UTF8String));
            XTNCNNDetectFn   fn = reinterpret_cast<XTNCNNDetectFn>(dlsym(h, kXTNCNNDetectSymbol.UTF8String));
            if (!ex && !fn) { dlclose(h); continue; }
            gXTNCNNDetectEx = ex;
            gXTNCNNDetect   = fn;
            _ncnnHandle = h;
            // 指纹仅用于日志：某些 wrapper 把 ncnn 静态链接，可能不导出该 C++ 符号
            void *ctor = dlsym(h, kXTNCNNNetCtorSymbol.UTF8String);
            XTLog(@"[XAutouch] ncnn 加载成功: %@ ex=%@ fn=%@ ctor=%@",
                  path, ex ? @"yes" : @"no", fn ? @"yes" : @"no", ctor ? @"yes" : @"no");
            return YES;
        }
        return NO;
    }
}

- (BOOL)available {
    if (![self loadLibraryIfNeeded]) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:XTNCNNModelPath(kXTNCNNParamFile)] &&
           [fm fileExistsAtPath:XTNCNNModelPath(kXTNCNNBinFile)];
}

/// 调用桥接并解析 JSON；失败返回 @{@"error":...}
- (NSDictionary *)detectWithThreshold:(float)threshold error:(NSString **)errOut {
    if (![self loadLibraryIfNeeded]) {
        if (errOut) *errOut = @"ncnn library not loaded";
        return nil;
    }
    NSString *param = XTNCNNModelPath(kXTNCNNParamFile);
    NSString *bin = XTNCNNModelPath(kXTNCNNBinFile);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:param] || ![fm fileExistsAtPath:bin]) {
        if (errOut) *errOut = @"ncnn model files missing";
        return nil;
    }

    NSString *shot = [[XTCapture sharedInstance] captureScreen];
    UIImage *img = shot ? [UIImage imageWithContentsOfFile:shot] : nil;
    int w = 0, h = 0;
    unsigned char *rgba = img ? XTNCNNDecodeRGBA(img, &w, &h) : NULL;
    if (!rgba) {
        if (errOut) *errOut = img ? @"image decode failed" : @"capture failed";
        return nil;
    }

    char *buffer = (char *)calloc(kXTNCNNOutputCapacity, 1);
    if (!buffer) {
        free(rgba);
        if (errOut) *errOut = @"output buffer allocation failed";
        return nil;
    }
    int written = 0;
    if (gXTNCNNDetectEx) {
        written = gXTNCNNDetectEx(param.UTF8String, bin.UTF8String, rgba, w, h,
                                  threshold, buffer, (int)kXTNCNNOutputCapacity);
    } else if (gXTNCNNDetect) {
        written = gXTNCNNDetect(rgba, w, h, threshold, buffer, (int)kXTNCNNOutputCapacity);
    }
    free(rgba);

    if (written <= 0) {
        free(buffer);
        if (errOut) *errOut = @"ncnn bridge returned failure";
        return nil;
    }
    if ((NSUInteger)written > kXTNCNNOutputCapacity) written = (int)kXTNCNNOutputCapacity;
    NSData *jsonData = [NSData dataWithBytes:buffer length:(NSUInteger)written];
    free(buffer);
    id json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if (!json) {
        if (errOut) *errOut = @"ncnn bridge output is not valid JSON";
        return nil;
    }
    return @{@"_imageW":@(w), @"_imageH":@(h), @"_json":json};
}

/// 把桥接 JSON 归一化为 boxes 数组：@{x,y,w,h,score,label}
- (NSArray<NSDictionary *> *)normalizeBoxesFromResult:(NSDictionary *)result {
    id json = result[@"_json"];
    NSArray *arr = nil;
    if ([json isKindOfClass:[NSArray class]]) arr = json;
    else if ([json isKindOfClass:[NSDictionary class]]) arr = json[@"boxes"];
    if (![arr isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *out = [NSMutableArray array];
    for (id item in arr) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        double x = [item[@"x"] doubleValue], y = [item[@"y"] doubleValue];
        double bw = [item[@"w"] doubleValue], bh = [item[@"h"] doubleValue];
        double score = [item[@"score"] doubleValue];
        NSString *label = item[@"label"] ?: item[@"text"] ?: @"";
        if (![label isKindOfClass:[NSString class]]) label = @"";
        [out addObject:@{@"x":@(x), @"y":@(y), @"w":@(bw), @"h":@(bh),
                         @"score":@(score), @"label":label}];
    }
    return out;
}

- (NSDictionary *)findTemplate:(NSString *)name threshold:(double)threshold {
    if (!name.length) return @{@"error":@"empty template"};
    NSString *err = nil;
    NSDictionary *res = [self detectWithThreshold:(float)threshold error:&err];
    if (!res) return @{@"error":err ?: @"ncnn detect failed"};

    NSArray *boxes = [self normalizeBoxesFromResult:res];
    if (!boxes.count) return @{@"error":@"ncnn returned no boxes"};

    // 模板名若命中某个 label，只在该类中找；否则取全体最高分
    NSDictionary *best = nil;
    for (NSDictionary *b in boxes) {
        NSString *label = b[@"label"];
        if (label.length && [label isEqualToString:name]) { best = b; break; }
    }
    if (!best) {
        for (NSDictionary *b in boxes) {
            if (!best || [b[@"score"] doubleValue] > [best[@"score"] doubleValue]) best = b;
        }
    }
    double score = [best[@"score"] doubleValue];
    BOOL found = score >= threshold;
    XTLog(@"[XAutouch] ncnn detect %@ score=%.4f -> %@", name, score, found ? @"hit" : @"miss");
    return @{@"found":@(found), @"x":best[@"x"], @"y":best[@"y"],
             @"w":best[@"w"], @"h":best[@"h"], @"score":@(score), @"template":name};
}

- (NSDictionary *)ocrExpect:(NSString *)expect {
    // 低阈值跑一遍，收集桥接返回的 label/text 作为识别文本
    NSString *err = nil;
    NSDictionary *res = [self detectWithThreshold:0.1f error:&err];
    if (!res) return @{@"error":err ?: @"ncnn ocr failed"};

    NSArray *boxes = [self normalizeBoxesFromResult:res];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *b in boxes) {
        NSString *label = b[@"label"];
        if (label.length) [texts addObject:label];
    }
    if (!texts.count) return @{@"error":@"ncnn bridge returned no text labels"};

    BOOL matched = NO;
    if (expect.length) {
        for (NSString *t in texts) {
            if ([t isEqualToString:expect] || [t containsString:expect]) { matched = YES; break; }
        }
    } else matched = texts.count > 0;

    XTLog(@"[XAutouch] ncnn OCR %lu 行 -> %@", (unsigned long)texts.count, matched ? @"hit" : @"miss");
    return @{@"matched":@(matched), @"texts":texts, @"boxes":boxes,
             @"expect":expect ?: @"", @"count":@(texts.count)};
}

@end
