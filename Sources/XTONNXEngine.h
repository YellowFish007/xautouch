/**
 * XTONNXEngine.h - ONNX Runtime 视觉适配器
 *
 * 编译期不依赖 onnxruntime_headers：所有 Ort 对象在本头文件中一律以 void * 持有，
 * 真正的函数表结构只存在于 XTONNXEngine.mm 中，并通过 OrtGetApiBase + dlsym 运行时取得。
 *
 * 需要的运行时文件（放在 resourceRoot 下）：
 *   lib/libonnxruntime.1.17.3.dylib   动态库（也在 jbRoot/usr/lib 下探测）
 *   models/detect.onnx                检测模型，供 findTemplate 使用
 *   models/ocr.onnx                   OCR 模型，供 ocrExpect 使用
 *   models/ocr_chars.txt             可选，CTC 字符集，每行一个字符
 *   models/detect_labels.txt         可选，检测类别标签，每行一个标签
 */
#import <Foundation/Foundation.h>
#import "XTVisionEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTONNXEngine : NSObject <XTVisionEngine> {
@protected
    // 以下均为 ONNX Runtime 不透明指针，用 void * 持有以避免引入 Ort 头文件
    void *_ortEnv;           // OrtEnv*
    void *_ortOptions;       // OrtSessionOptions*
    void *_ortMemoryInfo;    // OrtMemoryInfo*
    void *_ortSessionOCR;    // OrtSession*（ocr.onnx）
    void *_ortSessionDetect; // OrtSession*（detect.onnx）
}
@end

NS_ASSUME_NONNULL_END
