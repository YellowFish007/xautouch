/**
 * XTTesseractEngine.h - Tesseract OCR 适配器
 *
 * 编译期不依赖 tesseract/leptonica 头文件：全部通过 dlopen + dlsym 调用 C API。
 * 动态库或语言包缺失时 available=NO，公开方法返回带 error 的字典。
 *
 * 需要的运行时文件（resourceRoot 下）：
 *   lib/libtesseract.dylib      Tesseract 主库
 *   lib/liblept.dylib           Leptonica（若已被 libtesseract 依赖并可 RTLD_DEFAULT 解析则可省略）
 *   tessdata/chi_sim.traineddata
 *   tessdata/eng.traineddata
 */
#import <Foundation/Foundation.h>
#import "XTVisionEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTTesseractEngine : NSObject <XTVisionEngine> {
@protected
    void *_tessHandle;   // dlopen 返回的句柄（libtesseract）
    void *_leptHandle;   // dlopen 返回的句柄（liblept，可为 NULL）
}
@end

NS_ASSUME_NONNULL_END
