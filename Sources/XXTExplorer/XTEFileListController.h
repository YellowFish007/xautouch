/**
 * XTEFileListController.h - 文件浏览器主界面
 *
 * 目录浏览、下拉刷新、搜索、排序、长按操作与新建/上传工具栏。
 * 所有数据来自 /file_list，所有操作经 XTEAPIClient 完成。
 */
#import <UIKit/UIKit.h>

@interface XTEFileListController : UITableViewController
    <UISearchResultsUpdating, UISearchBarDelegate, UIDocumentPickerDelegate>

/// path == rootPath 时为根控制器，首次加载由 AppDelegate 调用 applyResourceRoot: 触发
- (instancetype)initWithPath:(NSString *)path rootPath:(NSString *)rootPath;

/// 注入 /deviceinfo 返回的真实资源根目录并重新加载
- (void)applyResourceRoot:(NSString *)root;

@end
