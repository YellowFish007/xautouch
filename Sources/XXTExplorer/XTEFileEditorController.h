/**
 * XTEFileEditorController.h - 脚本/文本文件编辑器与图片预览器
 *
 * 文本走 /read_file 与 /write_file；脚本可运行（/launch_script_file）
 * 和语法检查（/check_syntax）；图片走 HTTP 原始字节并用 UIImageView 显示。
 */
#import <UIKit/UIKit.h>

@interface XTEFileEditorController : UIViewController

- (instancetype)initWithFilePath:(NSString *)path resourceRoot:(NSString *)root;

@end
