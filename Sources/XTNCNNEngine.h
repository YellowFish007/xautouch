/**
 * XTNCNNEngine.h - ncnn 视觉适配器
 *
 * 编译期不依赖 ncnn 头文件：通过 dlopen + dlsym 调用 extern "C" 桥接函数，
 * 模型与动态库全部运行时探测。库/模型缺失时 available=NO。
 *
 * 需要的运行时文件（resourceRoot 下）：
 *   lib/libncnn.dylib          动态库（也在 jbRoot/usr/lib 下探测）
 *   models/ncnn.param          网络结构
 *   models/ncnn.bin            权重
 *
 * 桥接函数（由随包 libncnn.dylib 或独立 wrapper 导出，签名见 .mm）：
 *   xt_ncnn_detect_ex(...)  首选，可传入 param/bin 路径
 *   xt_ncnn_detect(...)     兼容简化签名
 */
#import <Foundation/Foundation.h>
#import "XTVisionEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTNCNNEngine : NSObject <XTVisionEngine> {
@protected
    void *_ncnnHandle;   // dlopen 返回的句柄
}
@end

NS_ASSUME_NONNULL_END
