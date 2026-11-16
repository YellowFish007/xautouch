/**
 * XTEFileListController.mm - 文件浏览器实现
 *
 * 字段容错：以 XTScriptEngine.mm 的 fileListAt: 真实字段为准
 * （name / path / is_dir / size / mtime），同时兼容 isDir、date 等别名。
 * 目录通过 push 子控制器进入，子控制器首行显示 ".." 用于返回上级。
 */
#import "XTEFileListController.h"
#import "XTEAPIClient.h"
#import "XTEFileEditorController.h"

static NSString *const kXTECellIdentifier = @"XTEFileCell";

#pragma mark - 条目字段容错解析

static NSString *XTEItemName(NSDictionary *item) {
    NSString *name = item[@"name"];
    if (![name isKindOfClass:[NSString class]] || !name.length) name = item[@"filename"];
    if (![name isKindOfClass:[NSString class]] || !name.length) name = item[@"file_name"];
    if (![name isKindOfClass:[NSString class]] || !name.length) {
        id pathValue = item[@"path"];
        if ([pathValue isKindOfClass:[NSString class]]) name = [pathValue lastPathComponent];
    }
    return name.length ? name : @"(未命名)";
}

static NSString *XTEItemPath(NSDictionary *item) {
    NSString *path = item[@"path"];
    if (![path isKindOfClass:[NSString class]] || !path.length) path = item[@"full_path"];
    if (![path isKindOfClass:[NSString class]] || !path.length) path = XTEItemName(item);
    return path;
}

static BOOL XTEItemIsDir(NSDictionary *item) {
    id value = item[@"is_dir"] ?: item[@"isDir"] ?: item[@"directory"] ?: item[@"type"];
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)value lowercaseString];
        return [text isEqualToString:@"dir"] || [text isEqualToString:@"directory"] ||
               [text isEqualToString:@"1"] || [text isEqualToString:@"true"];
    }
    return NO;
}

static unsigned long long XTEItemSize(NSDictionary *item) {
    id value = item[@"size"] ?: item[@"bytes"] ?: item[@"file_size"];
    if ([value respondsToSelector:@selector(unsignedLongLongValue)]) {
        return [value unsignedLongLongValue];
    }
    return 0;
}

static NSTimeInterval XTEItemMtime(NSDictionary *item) {
    id value = item[@"mtime"] ?: item[@"date"] ?: item[@"modified"];
    if (![value respondsToSelector:@selector(doubleValue)]) return 0;
    double interval = [value doubleValue];
    if (interval > 100000000000.0) interval /= 1000.0; // 毫秒时间戳兼容
    return interval;
}

static NSString *XTEFormatSize(unsigned long long bytes) {
    if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
    if (bytes < 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    if (bytes < 1024ULL * 1024ULL * 1024ULL)
        return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
    return [NSString stringWithFormat:@"%.1f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
}

static NSString *XTEFormatDate(NSTimeInterval interval) {
    if (interval <= 0) return @"--";
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:interval]];
}

static UIImage *XTEIconForItem(NSDictionary *item) {
    // 使用 iOS 13+ SF Symbols，并用 @available 保护，避免旧 SDK/部署目标的可用性告警
    if (@available(iOS 13.0, *)) {
        BOOL isDir = XTEItemIsDir(item);
        NSString *lowerName = [XTEItemName(item) lowercaseString];
        BOOL isScript = [lowerName hasSuffix:@".lua"] || [lowerName hasSuffix:@".xxt"];
        NSString *symbol = isDir ? @"folder.fill"
                          : (isScript ? @"doc.text.fill" : @"doc.fill");
        return [UIImage systemImageNamed:symbol];
    }
    return nil;
}

@interface XTEFileListController ()
@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) NSArray<NSDictionary *> *allItems;
@property (nonatomic, strong) NSArray<NSDictionary *> *visibleItems;
@property (nonatomic, assign) NSInteger sortMode;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *sortControl;
@property (nonatomic, assign) BOOL isRootController;
@property (nonatomic, assign) BOOL isLoading;
@end

@implementation XTEFileListController

#pragma mark - 初始化

- (instancetype)initWithPath:(NSString *)path rootPath:(NSString *)rootPath {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _rootPath = [rootPath copy] ?: [[XTEAPIClient defaultResourceRoot] copy];
        _currentPath = [path copy] ?: [_rootPath copy];
        _isRootController = [_currentPath isEqualToString:_rootPath];
        _sortMode = 0;
        _allItems = @[];
        _visibleItems = @[];
        self.title = _isRootController ? @"XAutouch 文件" : (_currentPath.lastPathComponent ?: @"文件");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    self.tableView.rowHeight = 54.0;
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kXTECellIdentifier];

    // 下拉刷新
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self
                            action:@selector(loadItems)
                  forControlEvents:UIControlEventValueChanged];

    // 搜索栏（iOS 11+ 放导航栏，老版本与排序控件一起放进表格头部）
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.searchBar.delegate = self;
    self.definesPresentationContext = YES;
    BOOL useNavSearch = NO;
    if (@available(iOS 11.0, *)) {
        self.navigationItem.searchController = search;
        useNavSearch = YES;
    }
    self.searchController = search;

    // 排序分段控件
    CGFloat headerHeight = useNavSearch ? 44.0 : 88.0;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, headerHeight)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (!useNavSearch) {
        search.searchBar.frame = CGRectMake(0, 0, screenWidth, 44);
        search.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [header addSubview:search.searchBar];
    }
    UISegmentedControl *sort = [[UISegmentedControl alloc] initWithItems:@[@"名称", @"大小", @"时间"]];
    sort.frame = CGRectMake(12, useNavSearch ? 6 : 52, screenWidth - 24, 32);
    sort.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    sort.selectedSegmentIndex = 0;
    [sort addTarget:self action:@selector(sortChanged:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:sort];
    self.sortControl = sort;
    self.tableView.tableHeaderView = header;

    // 工具栏
    UIBarButtonItem *createFolder = [[UIBarButtonItem alloc] initWithTitle:@"新建文件夹"
        style:UIBarButtonItemStylePlain target:self action:@selector(createFolder)];
    UIBarButtonItem *createFile = [[UIBarButtonItem alloc] initWithTitle:@"新建文件"
        style:UIBarButtonItemStylePlain target:self action:@selector(createFile)];
    UIBarButtonItem *upload = [[UIBarButtonItem alloc] initWithTitle:@"上传"
        style:UIBarButtonItemStylePlain target:self action:@selector(uploadFile)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[createFolder, space, createFile, space, upload];

    // 长按菜单
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [self.tableView addGestureRecognizer:longPress];

    // 子控制器在 init 后即持有有效路径；根控制器等待 applyResourceRoot: 注入真实前缀
    if (!self.isRootController) [self loadItems];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.toolbarHidden = NO;
}

- (void)applyResourceRoot:(NSString *)root {
    NSString *resolved = root.length ? root : [XTEAPIClient defaultResourceRoot];
    self.rootPath = resolved;
    if (!self.isRootController) return;
    self.currentPath = resolved;
    self.title = @"XAutouch 文件";
    [self loadItems];
}

#pragma mark - 数据加载与筛选

- (void)loadItems {
    if (self.isLoading) return;
    self.isLoading = YES;
    if (!self.refreshControl.isRefreshing) [self.refreshControl beginRefreshing];

    __weak __typeof__(self) weakSelf = self;
    [[XTEAPIClient sharedClient] listDirectory:self.currentPath
        completion:^(NSArray<NSDictionary *> *items, NSError *error) {
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.isLoading = NO;
            [strongSelf.refreshControl endRefreshing];
            if (error) {
                [strongSelf showError:error];
                return;
            }
            strongSelf.allItems = items ?: @[];
            if (!strongSelf.isRootController) {
                strongSelf.title = strongSelf.currentPath.lastPathComponent ?: @"文件";
            }
            [strongSelf applyFilterAndSort];
        }];
}

- (NSArray<NSDictionary *> *)sortedItemsFrom:(NSArray<NSDictionary *> *)items {
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL aDir = XTEItemIsDir(a), bDir = XTEItemIsDir(b);
        if (aDir != bDir) return aDir ? NSOrderedAscending : NSOrderedDescending;
        if (self.sortMode == 1) {
            unsigned long long sa = XTEItemSize(a), sb = XTEItemSize(b);
            if (sa > sb) return NSOrderedAscending;
            if (sa < sb) return NSOrderedDescending;
        } else if (self.sortMode == 2) {
            NSTimeInterval ta = XTEItemMtime(a), tb = XTEItemMtime(b);
            if (ta > tb) return NSOrderedAscending;
            if (ta < tb) return NSOrderedDescending;
        }
        return [XTEItemName(a) localizedStandardCompare:XTEItemName(b)];
    }];
}

- (void)applyFilterAndSort {
    NSString *query = self.searchController.searchBar.text ?: @"";
    NSArray<NSDictionary *> *source = self.allItems;
    if (query.length) {
        NSString *needle = [query lowercaseString];
        source = [source filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) {
            return [[XTEItemName(item) lowercaseString] rangeOfString:needle].location != NSNotFound;
        }]];
    }
    self.visibleItems = [self sortedItemsFrom:source];
    [self.tableView reloadData];
}

- (void)sortChanged:(UISegmentedControl *)sender {
    self.sortMode = sender.selectedSegmentIndex;
    [self applyFilterAndSort];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    (void)searchController;
    [self applyFilterAndSort];
}

- (BOOL)hasParentRow {
    return !self.isRootController &&
           [self.currentPath hasPrefix:self.rootPath] &&
           ![self.currentPath isEqualToString:self.rootPath];
}

#pragma mark - UITableViewDataSource / UITableViewDelegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleItems.count + ([self hasParentRow] ? 1 : 0);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kXTECellIdentifier
                                                             forIndexPath:indexPath];
    UIImageView *iconView = [cell.contentView viewWithTag:1001];
    UILabel *nameLabel = [cell.contentView viewWithTag:1002];
    UILabel *detailLabel = [cell.contentView viewWithTag:1003];
    if (!iconView) {
        CGFloat width = [UIScreen mainScreen].bounds.size.width;
        iconView = [[UIImageView alloc] initWithFrame:CGRectMake(12, 12, 30, 30)];
        iconView.tag = 1001;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        [cell.contentView addSubview:iconView];

        nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(52, 6, width - 68, 22)];
        nameLabel.tag = 1002;
        nameLabel.font = [UIFont systemFontOfSize:15];
        nameLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:nameLabel];

        detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(52, 29, width - 68, 16)];
        detailLabel.tag = 1003;
        detailLabel.font = [UIFont systemFontOfSize:11];
        detailLabel.textColor = [UIColor grayColor];
        detailLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:detailLabel];
    }

    NSInteger parentOffset = [self hasParentRow] ? 1 : 0;
    if (indexPath.row < parentOffset) {
        iconView.image = nil;
        nameLabel.text = @"..  返回上级";
        detailLabel.text = self.rootPath;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    NSDictionary *item = self.visibleItems[indexPath.row - parentOffset];
    iconView.image = XTEIconForItem(item);
    nameLabel.text = XTEItemName(item);
    BOOL isDir = XTEItemIsDir(item);
    detailLabel.text = isDir
        ? [NSString stringWithFormat:@"文件夹  %@", XTEFormatDate(XTEItemMtime(item))]
        : [NSString stringWithFormat:@"%@  %@", XTEFormatSize(XTEItemSize(item)),
                                     XTEFormatDate(XTEItemMtime(item))];
    cell.accessoryType = isDir ? UITableViewCellAccessoryDisclosureIndicator
                               : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger parentOffset = [self hasParentRow] ? 1 : 0;
    if (indexPath.row < parentOffset) {
        if (self.navigationController.viewControllers.count > 1) {
            [self.navigationController popViewControllerAnimated:YES];
        }
        return;
    }

    NSDictionary *item = self.visibleItems[indexPath.row - parentOffset];
    NSString *path = XTEItemPath(item);
    if (XTEItemIsDir(item)) {
        XTEFileListController *child =
            [[XTEFileListController alloc] initWithPath:path rootPath:self.rootPath];
        [self.navigationController pushViewController:child animated:YES];
    } else {
        XTEFileEditorController *editor =
            [[XTEFileEditorController alloc] initWithFilePath:path resourceRoot:self.rootPath];
        [self.navigationController pushViewController:editor animated:YES];
    }
}

#pragma mark - 长按操作菜单

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;
    NSInteger parentOffset = [self hasParentRow] ? 1 : 0;
    if (indexPath.row < parentOffset) return;
    [self showActionsForItem:self.visibleItems[indexPath.row - parentOffset]];
}

- (void)showActionsForItem:(NSDictionary *)item {
    NSString *name = XTEItemName(item);
    NSString *path = XTEItemPath(item);
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:name message:path
                                 preferredStyle:UIAlertControllerStyleActionSheet];

    __weak __typeof__(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { [weakSelf promptRenameItem:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { [weakSelf transferItem:item move:NO]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"移动" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { [weakSelf transferItem:item move:YES]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"回收站" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [[XTEAPIClient sharedClient] recycleFile:path completion:^(NSError *error) {
                if (error) [weakSelf showError:error]; else [weakSelf loadItems];
            }];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"运行脚本" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [[XTEAPIClient sharedClient] launchScriptFile:path
                completion:^(NSDictionary *result, NSError *error) {
                    NSString *message = error ? error.localizedDescription
                        : [NSString stringWithFormat:@"执行完成：%@", result[@"message"] ?: @"ok"];
                    [weakSelf showMessage:message title:@"运行脚本"];
                }];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            UIAlertController *confirm =
                [UIAlertController alertControllerWithTitle:@"确认删除"
                    message:[NSString stringWithFormat:@"确定删除“%@”？", name]
                    preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *inner) {
                    void (^finished)(NSError *) = ^(NSError *error) {
                        if (error) [weakSelf showError:error]; else [weakSelf loadItems];
                    };
                    if (XTEItemIsDir(item)) {
                        [[XTEAPIClient sharedClient] removeDirectory:path completion:finished];
                    } else {
                        [[XTEAPIClient sharedClient] removeFile:path completion:finished];
                    }
                }]];
            [weakSelf presentViewController:confirm animated:YES completion:nil];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect =
        [self.tableView rectForRowAtIndexPath:[self.tableView indexPathForSelectedRow] ?:
         [NSIndexPath indexPathForRow:0 inSection:0]];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 重命名 / 复制 / 移动

- (void)promptTitle:(NSString *)title
            message:(NSString *)message
       initialText:(NSString *)initial
         onConfirm:(void (^)(NSString *text))confirm {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title message:message
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = initial ?: @"";
        textField.placeholder = @"名称或路径";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            NSString *text = alert.textFields.firstObject.text ?: @"";
            if (confirm) confirm(text);
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptRenameItem:(NSDictionary *)item {
    NSString *oldName = XTEItemName(item);
    NSString *path = XTEItemPath(item);
    __weak __typeof__(self) weakSelf = self;
    [self promptTitle:@"重命名" message:@"请输入新名称" initialText:oldName onConfirm:^(NSString *text) {
        NSString *newName = [text stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!newName.length || [newName isEqualToString:oldName]) return;
        NSString *destination = [path.stringByDeletingLastPathComponent
                                 stringByAppendingPathComponent:newName];
        [[XTEAPIClient sharedClient] renameFile:path to:destination completion:^(NSError *error) {
            if (error) [weakSelf showError:error]; else [weakSelf loadItems];
        }];
    }];
}

- (void)transferItem:(NSDictionary *)item move:(BOOL)move {
    NSString *name = XTEItemName(item);
    NSString *path = XTEItemPath(item);
    NSString *initial = [self.currentPath stringByAppendingPathComponent:name];
    __weak __typeof__(self) weakSelf = self;
    [self promptTitle:(move ? @"移动到" : @"复制到")
              message:@"输入目标路径（绝对路径，或相对当前目录）"
          initialText:initial
            onConfirm:^(NSString *text) {
        NSString *destination = [text stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!destination.length) return;
        if (![destination isAbsolutePath]) {
            destination = [weakSelf.currentPath stringByAppendingPathComponent:destination];
        }
        void (^finished)(NSError *) = ^(NSError *error) {
            if (error) [weakSelf showError:error]; else [weakSelf loadItems];
        };
        if (move) {
            [[XTEAPIClient sharedClient] moveFile:path to:destination completion:finished];
        } else {
            [[XTEAPIClient sharedClient] copyFile:path to:destination completion:finished];
        }
    }];
}

#pragma mark - 工具栏：新建与上传

- (void)createFolder {
    __weak __typeof__(self) weakSelf = self;
    [self promptTitle:@"新建文件夹" message:@"请输入文件夹名称" initialText:@""
           onConfirm:^(NSString *text) {
        NSString *name = [text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) return;
        NSString *path = [weakSelf.currentPath stringByAppendingPathComponent:name];
        [[XTEAPIClient sharedClient] makeDirectory:path completion:^(NSError *error) {
            if (error) [weakSelf showError:error]; else [weakSelf loadItems];
        }];
    }];
}

- (void)createFile {
    __weak __typeof__(self) weakSelf = self;
    [self promptTitle:@"新建文件" message:@"请输入文件名（如 script.lua）" initialText:@"untitled.lua"
           onConfirm:^(NSString *text) {
        NSString *name = [text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) return;
        NSString *path = [weakSelf.currentPath stringByAppendingPathComponent:name];
        [[XTEAPIClient sharedClient] writeFile:path content:@""
                                    completion:^(NSError *error) {
            if (error) { [weakSelf showError:error]; return; }
            [weakSelf loadItems];
            XTEFileEditorController *editor =
                [[XTEFileEditorController alloc] initWithFilePath:path resourceRoot:weakSelf.rootPath];
            [weakSelf.navigationController pushViewController:editor animated:YES];
        }];
    }];
}

- (void)uploadFile {
    // iOS 8+ 公开 API；import 模式把文档拷贝到 App 沙盒后读取。
    // iOS 14 起该初始化方法被标记废弃，用 pragma 局部屏蔽以免 Theos 的 -Werror 中断构建。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.data", @"public.text"]
                       inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;

    BOOL accessing = [sourceURL startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:sourceURL];
    if (accessing) [sourceURL stopAccessingSecurityScopedResource];

    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content) {
        [self showMessage:@"当前 HTTP 接口只能承载 UTF-8 文本，请选择脚本文本文件。"
                    title:@"无法上传"];
        return;
    }

    NSString *destination = [self.currentPath stringByAppendingPathComponent:sourceURL.lastPathComponent];
    __weak __typeof__(self) weakSelf = self;
    [[XTEAPIClient sharedClient] writeFile:destination content:content completion:^(NSError *error) {
        if (error) [weakSelf showError:error]; else [weakSelf loadItems];
    }];
}

#pragma mark - 提示

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title message:message
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSError *)error {
    [self showMessage:error.localizedDescription ?: @"未知错误" title:@"操作失败"];
}

@end
