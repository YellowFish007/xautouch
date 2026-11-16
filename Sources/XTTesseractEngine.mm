/**
 * XTTesseractEngine.mm - Tesseract 适配器（dlsym 运行时加载）
 *
 * 调用链：TessBaseAPICreate → TessBaseAPIInit3 → pixRead →
 *        TessBaseAPISetImage2 → TessBaseAPIGetUTF8Text → pixDestroy → TessBaseAPIDelete
 * 所有符号名集中为常量。库/语言包/符号任一缺失时 available=NO。
 *
 * 说明：GetUTF8Text 只返回纯文本，不返回逐字框，因此 boxes 为空数组；
 *       若需要框信息，可扩展 bridge 调用 TessBaseAPIGetIterator。
 */
#import "XTTesseractEngine.h"
#import "XTApplication.h"
#import "XTCapture.h"
#import "XTLogger.h"
#import <dlfcn.h>
#import <stdlib.h>

#pragma mark - 符号常量（集中定义）

static NSString * const kXTTessLibraryName   = @"libtesseract.dylib";
static NSString * const kXTLeptLibraryName   = @"liblept.dylib";
static NSString * const kXTTessDataDir       = @"tessdata";
static NSString * const kXTTessLangChi       = @"chi_sim";
static NSString * const kXTTessLangEng       = @"eng";

static NSString * const kXTTessCreateSymbol  = @"TessBaseAPICreate";
static NSString * const kXTTessInitSymbol    = @"TessBaseAPIInit3";
static NSString * const kXTTessSetImgSymbol  = @"TessBaseAPISetImage2";
static NSString * const kXTTessGetTextSymbol = @"TessBaseAPIGetUTF8Text";
static NSString * const kXTTessDeleteSymbol  = @"TessBaseAPIDelete";
static NSString * const kXTPixReadSymbol     = @"pixRead";
static NSString * const kXTPixDestroySymbol  = @"pixDestroy";

#pragma mark - C API 签名

typedef void *XTTessAPI;                       // TessBaseAPI*
typedef XTTessAPI (*XTTessCreateFn)(void);
typedef int (*XTTessInitFn)(XTTessAPI handle, const char *datapath, const char *language);
typedef void (*XTTessSetImageFn)(XTTessAPI handle, void *pix);   // Pix* 前向为 void*
typedef char *(*XTTessGetTextFn)(XTTessAPI handle);
typedef void (*XTTessDeleteFn)(XTTessAPI handle);
typedef void *(*XTPixReadFn)(const char *path);                  // Pix*
typedef void (*XTPixDestroyFn)(void **pix);

static XTTessCreateFn  gTessCreate  = NULL;
static XTTessInitFn    gTessInit    = NULL;
static XTTessSetImageFn gTessSetImg = NULL;
static XTTessGetTextFn gTessGetText = NULL;
static XTTessDeleteFn  gTessDelete  = NULL;
static XTPixReadFn     gPixRead     = NULL;
static XTPixDestroyFn  gPixDestroy  = NULL;

#pragma mark - 工具

static NSString *XTTessDataPath(void) {
    return [[XTApplication resourceRoot] stringByAppendingPathComponent:kXTTessDataDir];
}

/// 按候选路径 dlopen；失败返回 NULL
static void *XTLoadTessLibrary(NSArray<NSString *> *paths) {
    for (NSString *path in paths) {
        void *h = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
        if (h) return h;
    }
    return NULL;
}

#pragma mark - 引擎实现

@implementation XTTesseractEngine

+ (NSString *)engineId { return @"tesseract"; }

- (instancetype)init {
    self = [super init];
    if (self) { _tessHandle = NULL; _leptHandle = NULL; }
    return self;
}

- (void)dealloc {
    if (_leptHandle) dlclose(_leptHandle);
    if (_tessHandle) dlclose(_tessHandle);
}

- (NSString *)engineDescription {
    return @"Tesseract C API（chi_sim/eng，dlsym）";
}

/// 懒加载并解析符号；任一必需符号缺失返回 NO
- (BOOL)loadLibrariesIfNeeded {
    @synchronized([XTTesseractEngine class]) {
        if (gTessCreate && gTessInit && gTessSetImg && gTessGetText && gTessDelete && gPixRead && gPixDestroy)
            return YES;

        if (!_tessHandle) {
            NSString *root = [XTApplication resourceRoot];
            NSString *jb = [[XTApplication sharedInstance] jbRoot];
            NSMutableArray<NSString *> *paths = [NSMutableArray array];
            void (^add)(NSString *) = ^(NSString *p) {
                if (p.length && ![paths containsObject:p]) [paths addObject:p];
            };
            add([root stringByAppendingPathComponent:[@"lib/" stringByAppendingPathComponent:kXTTessLibraryName]]);
            if (jb.length) add([jb stringByAppendingPathComponent:[@"/usr/lib/" stringByAppendingPathComponent:kXTTessLibraryName]]);
            add([@"/usr/lib/" stringByAppendingPathComponent:kXTTessLibraryName]);
            add([@"/var/jb/usr/lib/" stringByAppendingPathComponent:kXTTessLibraryName]);
            add(kXTTessLibraryName);
            _tessHandle = XTLoadTessLibrary(paths);
            if (!_tessHandle) return NO;
        }

        gTessCreate  = reinterpret_cast<XTTessCreateFn>(dlsym(_tessHandle, kXTTessCreateSymbol.UTF8String));
        gTessInit    = reinterpret_cast<XTTessInitFn>(dlsym(_tessHandle, kXTTessInitSymbol.UTF8String));
        gTessSetImg  = reinterpret_cast<XTTessSetImageFn>(dlsym(_tessHandle, kXTTessSetImgSymbol.UTF8String));
        gTessGetText = reinterpret_cast<XTTessGetTextFn>(dlsym(_tessHandle, kXTTessGetTextSymbol.UTF8String));
        gTessDelete  = reinterpret_cast<XTTessDeleteFn>(dlsym(_tessHandle, kXTTessDeleteSymbol.UTF8String));
        if (!gTessCreate || !gTessInit || !gTessSetImg || !gTessGetText || !gTessDelete) return NO;

        // Leptonica：先试全局符号（libtesseract 通常已链接 liblept），再显式 dlopen
        gPixRead    = reinterpret_cast<XTPixReadFn>(dlsym(RTLD_DEFAULT, kXTPixReadSymbol.UTF8String));
        gPixDestroy = reinterpret_cast<XTPixDestroyFn>(dlsym(RTLD_DEFAULT, kXTPixDestroySymbol.UTF8String));
        if (!gPixRead || !gPixDestroy) {
            if (!_leptHandle) {
                NSString *root = [XTApplication resourceRoot];
                NSString *jb = [[XTApplication sharedInstance] jbRoot];
                NSMutableArray<NSString *> *paths = [NSMutableArray array];
                void (^add)(NSString *) = ^(NSString *p) {
                    if (p.length && ![paths containsObject:p]) [paths addObject:p];
                };
                add([root stringByAppendingPathComponent:[@"lib/" stringByAppendingPathComponent:kXTLeptLibraryName]]);
                if (jb.length) add([jb stringByAppendingPathComponent:[@"/usr/lib/" stringByAppendingPathComponent:kXTLeptLibraryName]]);
                add([@"/usr/lib/" stringByAppendingPathComponent:kXTLeptLibraryName]);
                add([@"/var/jb/usr/lib/" stringByAppendingPathComponent:kXTLeptLibraryName]);
                add(kXTLeptLibraryName);
                _leptHandle = XTLoadTessLibrary(paths);
            }
            if (_leptHandle) {
                gPixRead    = reinterpret_cast<XTPixReadFn>(dlsym(_leptHandle, kXTPixReadSymbol.UTF8String));
                gPixDestroy = reinterpret_cast<XTPixDestroyFn>(dlsym(_leptHandle, kXTPixDestroySymbol.UTF8String));
            }
        }
        BOOL ok = gPixRead && gPixDestroy;
        if (ok) XTLog(@"[XAutouch] Tesseract 符号解析完成");
        return ok;
    }
}

/// 选择已安装的语言：两者都有则 chi_sim+eng
- (nullable NSString *)availableLanguage {
    NSString *dir = XTTessDataPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL chi = [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"chi_sim.traineddata"]];
    BOOL eng = [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"eng.traineddata"]];
    if (chi && eng) return @"chi_sim+eng";
    if (chi) return kXTTessLangChi;
    if (eng) return kXTTessLangEng;
    return nil;
}

- (BOOL)available {
    if (![self loadLibrariesIfNeeded]) return NO;
    return [self availableLanguage] != nil;
}

/// 执行一次 OCR，返回识别文本；失败返回 nil 并通过 errOut 说明原因
- (nullable NSString *)recognizeTextWithError:(NSString **)errOut {
    if (![self loadLibrariesIfNeeded]) {
        if (errOut) *errOut = @"tesseract library not loaded";
        return nil;
    }
    NSString *lang = [self availableLanguage];
    if (!lang) {
        if (errOut) *errOut = @"tessdata language pack missing";
        return nil;
    }
    NSString *shot = [[XTCapture sharedInstance] captureScreen];
    if (!shot) {
        if (errOut) *errOut = @"capture failed";
        return nil;
    }

    void *pix = gPixRead(shot.UTF8String);
    if (!pix) {
        if (errOut) *errOut = @"pixRead failed";
        return nil;
    }

    XTTessAPI api = gTessCreate();
    if (!api) {
        gPixDestroy(&pix);
        if (errOut) *errOut = @"TessBaseAPICreate failed";
        return nil;
    }
    // Init3 的 datapath 是 tessdata 的父目录
    int rc = gTessInit(api, [XTApplication resourceRoot].UTF8String, lang.UTF8String);
    if (rc != 0) {
        gTessDelete(api);
        gPixDestroy(&pix);
        if (errOut) *errOut = @"TessBaseAPIInit3 failed";
        return nil;
    }

    gTessSetImg(api, pix);                 // TessBaseAPISetImage2
    char *utf8 = gTessGetText(api);        // TessBaseAPIGetUTF8Text
    NSString *text = utf8 ? [NSString stringWithUTF8String:utf8] : nil;
    if (utf8) free(utf8);

    gTessDelete(api);
    gPixDestroy(&pix);
    if (!text) {
        if (errOut) *errOut = @"TessBaseAPIGetUTF8Text failed";
        return nil;
    }
    return text;
}

#pragma mark - 协议方法

- (NSDictionary *)findTemplate:(NSString *)name threshold:(double)threshold {
    if (!name.length) return @{@"error":@"empty template"};
    NSString *err = nil;
    NSString *text = [self recognizeTextWithError:&err];
    if (!text) return @{@"error":err ?: @"tesseract ocr failed"};

    BOOL found = [text containsString:name];
    XTLog(@"[XAutouch] Tesseract template %@ -> %@", name, found ? @"hit" : @"miss");
    return @{@"found":@(found), @"x":@0, @"y":@0, @"score":found ? @1.0 : @0.0,
             @"w":@0, @"h":@0, @"template":name, @"text":text};
}

- (NSDictionary *)ocrExpect:(NSString *)expect {
    NSString *err = nil;
    NSString *text = [self recognizeTextWithError:&err];
    if (!text) return @{@"error":err ?: @"tesseract ocr failed"};

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length) [texts addObject:trimmed];
    }
    BOOL matched = NO;
    if (expect.length) {
        for (NSString *t in texts) {
            if ([t isEqualToString:expect] || [t containsString:expect]) { matched = YES; break; }
        }
    } else matched = texts.count > 0;

    XTLog(@"[XAutouch] Tesseract OCR %lu 行 -> %@", (unsigned long)texts.count, matched ? @"hit" : @"miss");
    return @{@"matched":@(matched), @"texts":texts, @"boxes":@[],
             @"expect":expect ?: @"", @"count":@(texts.count)};
}

@end
