/**
 * XTEFileEditorController.mm - 编辑器实现
 *
 * 图片文件说明：宿主的 /read_file 走 NSString UTF-8 解码，无法返回二进制图片。
 * 因此优先使用宿主的静态资源端点（resource_root/web/...）取原始字节；
 * 其余位置的文件尝试按文本还原，失败时给出明确提示，不做静默降级。
 */
#import "XTEFileEditorController.h"
#import "XTEAPIClient.h"

static BOOL XTEIsImagePath(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    static NSSet *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif",
                                           @"bmp", @"webp", @"heic", @"heif", @"tiff"]];
    });
    return [extensions containsObject:extension];
}

@interface XTEFileEditorController ()
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *resourceRoot;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, assign) BOOL imageMode;
@end

@implementation XTEFileEditorController

#pragma mark - 初始化与界面

- (instancetype)initWithFilePath:(NSString *)path resourceRoot:(NSString *)root {
    self = [super init];
    if (self) {
        _filePath = [path copy] ?: @"";
        _resourceRoot = [root copy] ?: [[XTEAPIClient defaultResourceRoot] copy];
        _imageMode = XTEIsImagePath(_filePath);
        self.title = _filePath.lastPathComponent ?: @"编辑器";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.edgesForExtendedLayout = UIRectEdgeNone;

    if (self.imageMode) {
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:self.view.bounds];
        imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.backgroundColor = [UIColor blackColor];
        [self.view addSubview:imageView];
        self.imageView = imageView;
        [self loadImage];
    } else {
        UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
        textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIFont *monospace = [UIFont fontWithName:@"Menlo" size:14];
        textView.font = monospace ?: [UIFont systemFontOfSize:14];
        textView.autocorrectionType = UITextAutocorrectionTypeNo;
        textView.spellCheckingType = UITextSpellCheckingTypeNo;
        [self.view addSubview:textView];
        self.textView = textView;

        // 键盘上方“完成”，便于在 iPhone 上收起键盘
        UIToolbar *accessory = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];
        UIBarButtonItem *space = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem *done = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                  target:self action:@selector(dismissKeyboard)];
        accessory.items = @[space, done];
        textView.inputAccessoryView = accessory;

        [self loadText];
    }

    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:@"保存"
        style:UIBarButtonItemStylePlain target:self action:@selector(saveFile)];
    UIBarButtonItem *run = [[UIBarButtonItem alloc] initWithTitle:@"运行"
        style:UIBarButtonItemStylePlain target:self action:@selector(runScript)];
    UIBarButtonItem *check = [[UIBarButtonItem alloc] initWithTitle:@"语法检查"
        style:UIBarButtonItemStylePlain target:self action:@selector(checkSyntax)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    save.enabled = !self.imageMode;
    run.enabled = !self.imageMode;
    check.enabled = !self.imageMode;
    self.toolbarItems = @[save, space, run, space, check];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.toolbarHidden = NO;
}

- (void)dismissKeyboard {
    [self.textView resignFirstResponder];
}

#pragma mark - 文本读写

- (void)loadText {
    __weak __typeof__(self) weakSelf = self;
    [[XTEAPIClient sharedClient] readFile:self.filePath
        completion:^(NSString *content, NSError *error) {
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                [strongSelf showMessage:error.localizedDescription title:@"读取失败"];
                return;
            }
            strongSelf.textView.text = content ?: @"";
        }];
}

- (void)saveFile {
    if (self.imageMode) return;
    NSString *content = self.textView.text ?: @"";
    __weak __typeof__(self) weakSelf = self;
    [[XTEAPIClient sharedClient] writeFile:self.filePath content:content
        completion:^(NSError *error) {
            if (error) {
                [weakSelf showMessage:error.localizedDescription title:@"保存失败"];
            } else {
                [weakSelf showMessage:@"文件已保存" title:@"保存"];
            }
        }];
}

#pragma mark - 运行与语法检查

- (void)runScript {
    if (self.imageMode) return;
    __weak __typeof__(self) weakSelf = self;
    [[XTEAPIClient sharedClient] launchScriptFile:self.filePath
        completion:^(NSDictionary *result, NSError *error) {
            if (error) {
                [weakSelf showMessage:error.localizedDescription title:@"运行失败"];
                return;
            }
            [weakSelf showMessage:[weakSelf describeResult:result] title:@"运行脚本"];
        }];
}

- (NSString *)describeResult:(NSDictionary *)result {
    if (!result.count) return @"脚本执行完成。";
    NSMutableArray *lines = [NSMutableArray arrayWithCapacity:result.count];
    [result enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        [lines addObject:[NSString stringWithFormat:@"%@: %@", key, value]];
    }];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)checkSyntax {
    if (self.imageMode) return;
    __weak __typeof__(self) weakSelf = self;
    [[XTEAPIClient sharedClient] checkSyntax:self.textView.text ?: @""
        completion:^(NSArray<NSDictionary *> *diagnostics, NSError *error) {
            if (error) {
                [weakSelf showMessage:error.localizedDescription title:@"语法检查失败"];
                return;
            }
            NSString *body = @"语法检查通过，未发现问题。";
            if (diagnostics.count) {
                NSMutableArray *lines = [NSMutableArray arrayWithCapacity:diagnostics.count];
                for (NSDictionary *item in diagnostics) {
                    NSString *severity = item[@"severity"] ?: @"info";
                    NSString *message = item[@"message"] ?: @"";
                    NSInteger lineNumber = [item[@"line"] integerValue];
                    [lines addObject:[NSString stringWithFormat:@"第 %ld 行 [%@] %@",
                                      (long)lineNumber, severity, message]];
                }
                body = [lines componentsJoinedByString:@"\n"];
            }
            [weakSelf showMessage:body title:@"语法检查"];
        }];
}

#pragma mark - 图片预览

- (void)loadImage {
    __weak __typeof__(self) weakSelf = self;
    void (^render)(NSData *) = ^(NSData *data) {
        UIImage *image = [UIImage imageWithData:data];
        if (!image) {
            [weakSelf showMessage:
                @"图片内容无法解析。宿主 /read_file 只返回 UTF-8 文本；"
                @"请将图片放入 resource_root/web 目录下再通过本应用预览。"
                            title:@"图片预览失败"];
            return;
        }
        weakSelf.imageView.image = image;
    };

    NSString *webPrefix = [self.resourceRoot stringByAppendingPathComponent:@"web"];
    if ([self.filePath hasPrefix:webPrefix]) {
        NSString *relative = [[self.filePath substringFromIndex:webPrefix.length]
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        [[XTEAPIClient sharedClient] fetchRawResource:relative
            completion:^(NSData *data, NSError *error) {
                if (error) {
                    [weakSelf showMessage:error.localizedDescription title:@"图片预览失败"];
                    return;
                }
                render(data);
            }];
    } else {
        [[XTEAPIClient sharedClient] readFile:self.filePath
            completion:^(NSString *content, NSError *error) {
                if (error) {
                    [weakSelf showMessage:error.localizedDescription title:@"图片预览失败"];
                    return;
                }
                render([content dataUsingEncoding:NSUTF8StringEncoding]);
            }];
    }
}

#pragma mark - 提示

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title message:message
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
