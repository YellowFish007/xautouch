/**
 * XTUIService.mm - UI 服务与配套控制（SpringBoard 进程内）
 *
 * 参照原版 uiservice-toast-service / uiservice-show-pose-service /
 * uiservice-view-service / ui-elerthelper-service / xxt-check-update.lua。
 *
 * 约定：
 * 1. 所有 UI 操作一律 dispatch_async 到主线程；UIWindow 由本类 strong 持有。
 * 2. 覆盖层窗口均不抢占 keyWindow（alert 除外），避免干扰 SpringBoard 输入。
 * 3. 音量键动作配置与 XTApplication 的 volumeActionConf 共用同一个 plist。
 * 4. 版本检查使用 NSURLSession 异步请求，completion 回主线程。
 */
#import "XTUIService.h"
#import "XTApplication.h"
#import "XTHTTPServer.h"
#import "XTTouchSynthesizer.h"
#import "XTScriptEngine.h"
#import "XTLogger.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static NSString * const kXTUpdateURL      = @"https://xxtouch.app/api/latest-version";
static NSString * const kXTDefaultVersion = @"1.0.0";
static NSString * const kXTVolumeConfFile = @"volume_action_conf.plist";
static NSTimeInterval const kXTRequestTimeout = 15.0;

/// 所有公开方法统一走这里，保证 UI 代码不在调用方线程执行
static void XTMainAsync(void (^block)(void)) {
    dispatch_async(dispatch_get_main_queue(), block);
}

static UIColor *XTPoseColor(void) {
    return [UIColor colorWithRed:0.10 green:0.62 blue:1.0 alpha:0.85];
}

@implementation XTUIService {
    // Toast
    UIWindow *_toastWindow;
    UILabel *_toastLabel;
    NSTimer *_toastTimer;

    // Pose
    UIWindow *_poseWindow;
    NSMutableDictionary<NSNumber *, UIView *> *_poseViews;
    NSUInteger _poseSeed;
    NSLock *_poseLock;

    // 悬浮窗
    UIWindow *_floatingWindow;
    UIView *_floatingPanel;
    UILabel *_floatingLabel;

    // Alert
    UIWindow *_alertWindow;
    UIViewController *_alertHost;
    UIAlertController *_currentAlert;
    void (^_alertCompletion)(NSInteger);

    // 配置 / 更新
    NSLock *_confLock;
    NSURLSession *_session;
    NSDictionary<NSString *, id> *_updateInfo;
    NSLock *_updateLock;
}

+ (instancetype)sharedInstance {
    static XTUIService *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _poseViews = [NSMutableDictionary dictionary];
        _poseLock = [NSLock new];
        _confLock = [NSLock new];
        _updateLock = [NSLock new];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = kXTRequestTimeout;
        configuration.timeoutIntervalForResource = kXTRequestTimeout * 2.0;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

#pragma mark - Toast

- (UIWindow *)xt_toastWindowCreateIfNeeded {
    if (_toastWindow) return _toastWindow;
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = UIWindowLevelAlert + 1.0;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO; // 纯展示层，不能吞掉桌面触摸
    UIViewController *host = [[UIViewController alloc] init];
    host.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = host;
    _toastWindow = window;
    return window;
}

- (void)xt_cancelToastTimer {
    if (_toastTimer) {
        [_toastTimer invalidate];
        _toastTimer = nil;
    }
}

- (void)xt_hideToast {
    [self xt_cancelToastTimer];
    __weak __typeof__(self) weakSelf = self;
    [UIView animateWithDuration:0.25 animations:^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        strongSelf->_toastLabel.alpha = 0.0;
    } completion:^(BOOL finished) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        strongSelf->_toastWindow.hidden = YES;
    }];
}

- (void)showToast:(NSString *)text duration:(NSTimeInterval)sec position:(NSInteger)position {
    NSString *content = [text isKindOfClass:[NSString class]] ? [text copy] : @"";
    NSTimeInterval duration = (sec > 0) ? sec : 2.0;
    XTMainAsync(^{
        [self xt_cancelToastTimer];
        UIWindow *window = [self xt_toastWindowCreateIfNeeded];
        window.frame = [UIScreen mainScreen].bounds;
        window.hidden = NO;

        UIViewController *host = window.rootViewController;
        if (!_toastLabel) {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.textColor = UIColor.whiteColor;
            label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 0;
            label.lineBreakMode = NSLineBreakByWordWrapping;
            label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
            label.layer.cornerRadius = 10.0;
            label.layer.masksToBounds = YES;
            label.userInteractionEnabled = NO;
            [host.view addSubview:label];
            _toastLabel = label;
        }

        UILabel *label = _toastLabel;
        label.text = content;
        CGFloat screenWidth = CGRectGetWidth(window.bounds);
        CGFloat screenHeight = CGRectGetHeight(window.bounds);
        CGFloat maxWidth = MAX(80.0, screenWidth - 60.0);
        CGSize fitted = [label sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
        CGFloat width = MIN(MAX(120.0, fitted.width + 32.0), maxWidth);
        CGFloat height = MAX(40.0, fitted.height + 20.0);

        CGFloat y;
        if (position == 0) {
            y = 80.0;
        } else if (position == 2) {
            y = screenHeight - 140.0 - height;
        } else {
            y = (screenHeight - height) * 0.5;
        }
        label.frame = CGRectMake((screenWidth - width) * 0.5, y, width, height);
        label.alpha = 0.0;
        [UIView animateWithDuration:0.22 animations:^{ label.alpha = 1.0; }];

        _toastTimer = [NSTimer scheduledTimerWithTimeInterval:duration
                                                        target:self
                                                      selector:@selector(xt_hideToast)
                                                      userInfo:nil
                                                       repeats:NO];
    });
    [[XTHTTPServer sharedInstance] broadcastEvent:@"ui_toast"
                                             data:@{@"text":content, @"position":@(position)}];
}

#pragma mark - Pose 可视化

- (UIWindow *)xt_poseWindowCreateIfNeeded {
    if (_poseWindow) return _poseWindow;
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = UIWindowLevelAlert + 2.0;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    UIViewController *host = [[UIViewController alloc] init];
    host.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = host;
    window.hidden = YES;
    _poseWindow = window;
    return window;
}

- (void)showPoseAtX:(double)x y:(double)y touchDown:(BOOL)down {
    XTMainAsync(^{
        UIWindow *window = [self xt_poseWindowCreateIfNeeded];
        window.frame = [UIScreen mainScreen].bounds;
        __weak __typeof__(self) weakSelf = self;

        if (down) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(x - 22.0, y - 22.0, 44.0, 44.0)];
            dot.backgroundColor = XTPoseColor();
            dot.layer.cornerRadius = 22.0;
            dot.layer.borderWidth = 2.0;
            dot.layer.borderColor = UIColor.whiteColor.CGColor;
            dot.layer.shadowColor = UIColor.blackColor.CGColor;
            dot.layer.shadowOpacity = 0.35;
            dot.layer.shadowRadius = 4.0;
            dot.alpha = 0.0;
            dot.transform = CGAffineTransformMakeScale(0.35, 0.35);
            [window.rootViewController.view addSubview:dot];

            [_poseLock lock];
            NSNumber *key = @(++_poseSeed);
            _poseViews[key] = dot;
            [_poseLock unlock];

            window.hidden = NO;
            [UIView animateWithDuration:0.16 animations:^{
                dot.alpha = 1.0;
                dot.transform = CGAffineTransformIdentity;
            }];
        } else {
            [_poseLock lock];
            NSNumber *targetKey = nil;
            CGFloat bestDistance = CGFLOAT_MAX;
            for (NSNumber *key in _poseViews) {
                UIView *view = _poseViews[key];
                CGFloat dx = CGRectGetMidX(view.frame) - (CGFloat)x;
                CGFloat dy = CGRectGetMidY(view.frame) - (CGFloat)y;
                CGFloat distance = dx * dx + dy * dy;
                if (distance < bestDistance) {
                    bestDistance = distance;
                    targetKey = key;
                }
            }
            // 抬手坐标与按下坐标偏差过大时（如拖拽），退化为移除最后加入的圆圈
            if (!targetKey || bestDistance > 160.0 * 160.0) {
                NSUInteger newest = 0;
                for (NSNumber *key in _poseViews) {
                    if (key.unsignedIntegerValue >= newest) {
                        newest = key.unsignedIntegerValue;
                        targetKey = key;
                    }
                }
            }
            UIView *dot = targetKey ? _poseViews[targetKey] : nil;
            if (targetKey) [_poseViews removeObjectForKey:targetKey];
            [_poseLock unlock];
            if (!dot) return;

            [UIView animateWithDuration:0.18 animations:^{
                dot.transform = CGAffineTransformMakeScale(1.5, 1.5);
                dot.alpha = 0.0;
            } completion:^(BOOL finished) {
                [dot removeFromSuperview];
                __strong __typeof__(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf->_poseLock lock];
                BOOL empty = (strongSelf->_poseViews.count == 0);
                [strongSelf->_poseLock unlock];
                if (empty) window.hidden = YES;
            }];
        }
    });
    [[XTHTTPServer sharedInstance] broadcastEvent:@"ui_pose"
                                             data:@{@"x":@(x), @"y":@(y), @"down":@(down)}];
}

#pragma mark - 悬浮窗

- (UIWindow *)xt_floatingWindowCreateIfNeeded {
    if (_floatingWindow) return _floatingWindow;
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = UIWindowLevelAlert + 3.0;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = YES; // 悬浮面板需要接收拖拽手势
    UIViewController *host = [[UIViewController alloc] init];
    host.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = host;
    _floatingWindow = window;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(16.0, 100.0, 240.0, 92.0)];
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    panel.layer.cornerRadius = 12.0;
    panel.layer.masksToBounds = YES;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    [host.view addSubview:panel];
    _floatingPanel = panel;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14.0, 12.0, 190.0, 68.0)];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:14.0];
    label.numberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    [panel addSubview:label];
    _floatingLabel = label;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(208.0, 6.0, 28.0, 28.0);
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:22.0];
    [close addTarget:self action:@selector(xt_closeFloatingTapped) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(xt_panFloating:)];
    [panel addGestureRecognizer:pan];
    return window;
}

- (void)xt_closeFloatingTapped {
    [self hideFloatingView];
}

- (void)xt_panFloating:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:_floatingWindow];
    CGPoint center = _floatingPanel.center;
    center.x += translation.x;
    center.y += translation.y;
    CGFloat halfWidth = CGRectGetWidth(_floatingPanel.frame) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(_floatingPanel.frame) * 0.5;
    center.x = MIN(MAX(halfWidth, center.x), CGRectGetWidth(_floatingWindow.bounds) - halfWidth);
    center.y = MIN(MAX(halfHeight, center.y), CGRectGetHeight(_floatingWindow.bounds) - halfHeight);
    _floatingPanel.center = center;
    [recognizer setTranslation:CGPointZero inView:_floatingWindow];
}

- (void)showFloatingViewWithText:(NSString *)text {
    NSString *content = [text isKindOfClass:[NSString class]] ? [text copy] : @"";
    XTMainAsync(^{
        UIWindow *window = [self xt_floatingWindowCreateIfNeeded];
        _floatingLabel.text = content;
        window.frame = [UIScreen mainScreen].bounds;
        window.hidden = NO;
    });
    [[XTHTTPServer sharedInstance] broadcastEvent:@"ui_floating" data:@{@"text":content, @"visible":@YES}];
}

- (void)hideFloatingView {
    XTMainAsync(^{
        _floatingWindow.hidden = YES;
    });
    [[XTHTTPServer sharedInstance] broadcastEvent:@"ui_floating" data:@{@"visible":@NO}];
}

#pragma mark - Alert

- (UIWindow *)xt_alertWindowCreateIfNeeded {
    if (_alertWindow) return _alertWindow;
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = UIWindowLevelAlert + 4.0;
    window.backgroundColor = UIColor.clearColor;
    // Alert 需要交互：用新建的干净 VC 承载，绕开 SpringBoard 没有 rootVC 的限制
    UIViewController *host = [[UIViewController alloc] init];
    host.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = host;
    window.hidden = YES;
    _alertWindow = window;
    _alertHost = host;
    return window;
}

- (void)xt_presentAlert:(UIAlertController *)alert {
    if (_currentAlert) {
        UIAlertController *previous = _currentAlert;
        _currentAlert = nil;
        [previous dismissViewControllerAnimated:NO completion:^{
            XTMainAsync(^{ [self xt_presentAlert:alert]; });
        }];
        return;
    }
    _currentAlert = alert;
    [_alertWindow makeKeyAndVisible];
    if (!_alertHost.presentedViewController) {
        [_alertHost presentViewController:alert animated:YES completion:nil];
    }
}

- (void)showAlertTitle:(NSString *)title
               message:(NSString *)msg
               actions:(NSArray<NSString *> *)actions
            completion:(void (^)(NSInteger idx))completion {
    NSString *safeTitle = [title isKindOfClass:[NSString class]] ? [title copy] : @"";
    NSString *safeMessage = [msg isKindOfClass:[NSString class]] ? [msg copy] : @"";
    NSArray<NSString *> *titles = ([actions isKindOfClass:[NSArray class]] && actions.count > 0)
                                ? [actions copy] : @[@"确定"];
    void (^callback)(NSInteger) = completion;

    XTMainAsync(^{
        [self xt_alertWindowCreateIfNeeded];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:safeTitle
                                                                       message:safeMessage
                                                                preferredStyle:UIAlertControllerStyleAlert];
        __weak __typeof__(self) weakSelf = self;
        [titles enumerateObjectsUsingBlock:^(NSString *buttonTitle, NSUInteger index, BOOL *stop) {
            NSString *text = [buttonTitle isKindOfClass:[NSString class]] ? buttonTitle : [buttonTitle description];
            UIAlertAction *action = [UIAlertAction actionWithTitle:text
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction * _Nonnull chosen) {
                __strong __typeof__(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                void (^handler)(NSInteger) = strongSelf->_alertCompletion;
                strongSelf->_alertCompletion = nil;
                strongSelf->_currentAlert = nil;
                if (handler) handler((NSInteger)index);
            }];
            [alert addAction:action];
        }];
        _alertCompletion = [callback copy];
        [self xt_presentAlert:alert];
    });
    [[XTHTTPServer sharedInstance] broadcastEvent:@"ui_alert"
                                             data:@{@"title":safeTitle, @"message":safeMessage}];
}

#pragma mark - 音量键动作绑定

- (NSString *)xt_canonicalVolumeKey:(NSString *)key {
    NSString *lower = [[key isKindOfClass:[NSString class]] ? key : @"" lowercaseString];
    if ([lower containsString:@"long"]) return @"long_press";
    if ([lower containsString:@"up"])   return @"volume_up";
    if ([lower containsString:@"down"]) return @"volume_down";
    return lower;
}

- (NSString *)xt_volumeConfPath {
    return [[XTApplication resourceRoot] stringByAppendingPathComponent:kXTVolumeConfFile];
}

- (void)bindVolumeKey:(NSString *)key action:(NSString *)actionJSON {
    NSString *canonical = [self xt_canonicalVolumeKey:key];
    if (canonical.length == 0) return;
    NSString *json = [actionJSON isKindOfClass:[NSString class]] ? [actionJSON copy] : @"{\"action\":\"none\"}";

    [_confLock lock];
    NSString *path = [self xt_volumeConfPath];
    NSMutableDictionary *conf = [[NSDictionary dictionaryWithContentsOfFile:path] ?: @{} mutableCopy];
    conf[canonical] = json;
    [conf writeToFile:path atomically:YES];
    [_confLock unlock];

    XTLog(@"[XAutouch] 音量键绑定 %@ -> %@", canonical, json);
    [[XTHTTPServer sharedInstance] broadcastEvent:@"volume_bound" data:@{@"key":canonical, @"action":json}];
}

- (nullable NSString *)volumeActionFor:(NSString *)key {
    NSString *canonical = [self xt_canonicalVolumeKey:key];
    if (canonical.length == 0) return nil;
    [_confLock lock];
    NSDictionary *conf = [NSDictionary dictionaryWithContentsOfFile:[self xt_volumeConfPath]] ?: @{};
    id value = conf[canonical];
    [_confLock unlock];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (void)handleVolumeKey:(NSString *)key {
    NSString *canonical = [self xt_canonicalVolumeKey:key];
    if (canonical.length == 0) return;
    NSString *json = [self volumeActionFor:canonical];
    NSString *actionType = @"none";

    if (json.length > 0 && ![json isEqualToString:@"none"]) {
        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            NSDictionary *action = (NSDictionary *)parsed;
            NSString *type = [action[@"action"] isKindOfClass:[NSString class]] ? action[@"action"] : @"none";
            actionType = type;

            // 触摸合成 / 脚本执行放到后台队列，避免阻塞 SpringBoard 主线程
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                if ([type isEqualToString:@"tap"]) {
                    double x = [action[@"x"] doubleValue];
                    double y = [action[@"y"] doubleValue];
                    [[XTTouchSynthesizer sharedInstance] tapAtX:(CGFloat)x y:(CGFloat)y];
                } else if ([type isEqualToString:@"script"]) {
                    NSString *name = [action[@"name"] isKindOfClass:[NSString class]] ? action[@"name"] : @"";
                    [[XTScriptEngine sharedInstance] runScriptNamed:name];
                } else if ([type isEqualToString:@"key"]) {
                    NSString *pressed = [action[@"key"] isKindOfClass:[NSString class]] ? action[@"key"] : @"";
                    [[XTTouchSynthesizer sharedInstance] pressKey:pressed];
                }
            });
        }
    }

    XTMainAsync(^{
        [[XTHTTPServer sharedInstance] broadcastEvent:@"volume_key"
                                                 data:@{@"key":canonical, @"action":actionType}];
    });
}

#pragma mark - 版本检查

- (NSString *)xt_localVersion {
    NSString *path = [[XTApplication resourceRoot] stringByAppendingPathComponent:@"control"];
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (content.length > 0) {
        NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:
                                     [NSCharacterSet newlineCharacterSet]];
        for (NSString *line in lines) {
            if ([line.lowercaseString hasPrefix:@"version:"]) {
                NSString *version = [[line substringFromIndex:8] stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceCharacterSet]];
                if (version.length > 0) return version;
            }
        }
    }
    return kXTDefaultVersion;
}

- (NSString *)xt_firstStringIn:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
        if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    }
    return @"";
}

- (NSComparisonResult)xt_compareVersion:(NSString *)left to:(NSString *)right {
    NSArray<NSString *> *a = [left componentsSeparatedByString:@"."];
    NSArray<NSString *> *b = [right componentsSeparatedByString:@"."];
    NSUInteger count = MAX(a.count, b.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger av = (i < a.count) ? [a[i] integerValue] : 0;
        NSInteger bv = (i < b.count) ? [b[i] integerValue] : 0;
        if (av > bv) return NSOrderedDescending;
        if (av < bv) return NSOrderedAscending;
    }
    return NSOrderedSame;
}

- (NSDictionary *)xt_parseUpdateData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    NSString *current = [self xt_localVersion];
    NSMutableDictionary *result = [@{@"code":@0,
                                     @"current":current,
                                     @"latest":@"",
                                     @"hasUpdate":@NO,
                                     @"downloadUrl":@"",
                                     @"changelog":@"",
                                     @"error":@""} mutableCopy];
    if (error) {
        result[@"code"] = @(-1);
        result[@"error"] = error.localizedDescription ?: @"network error";
        return result;
    }
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                            ? (NSHTTPURLResponse *)response : nil;
    if (http && http.statusCode != 200) {
        result[@"code"] = @(-2);
        result[@"error"] = [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
        return result;
    }
    if (data.length == 0) {
        result[@"code"] = @(-3);
        result[@"error"] = @"empty response";
        return result;
    }

    id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) {
        result[@"code"] = @(-4);
        result[@"error"] = @"invalid json";
        return result;
    }
    NSDictionary *info = (NSDictionary *)root;
    NSDictionary *packageInfo = info[@"app.xxtouch.ios"];
    if ([packageInfo isKindOfClass:[NSDictionary class]]) info = packageInfo;

    NSString *latest = [self xt_firstStringIn:info keys:@[@"latest", @"version", @"v"]];
    if (latest.length == 0) {
        result[@"code"] = @(-5);
        result[@"error"] = @"no version field";
        return result;
    }
    NSString *download = [self xt_firstStringIn:info
                                          keys:@[@"download_url", @"downloadUrl", @"url",
                                                 @"tipa-url", @"download"]];
    NSString *changelog = [self xt_firstStringIn:info
                                          keys:@[@"changelog", @"description",
                                                 @"description_zh_Hans", @"description_zh_hans",
                                                 @"description_zh", @"notes"]];
    result[@"latest"] = latest;
    result[@"downloadUrl"] = download;
    result[@"changelog"] = changelog;
    result[@"hasUpdate"] = @([self xt_compareVersion:latest to:current] == NSOrderedDescending);
    return result;
}

- (void)triggerUpdateCheckWithCompletion:(void (^)(NSDictionary<NSString *, id> *info))completion {
    void (^callback)(NSDictionary *) = completion;
    NSURL *url = [NSURL URLWithString:kXTUpdateURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:kXTRequestTimeout];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak __typeof__(self) weakSelf = self;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
                                             completionHandler:^(NSData * _Nullable data,
                                                                 NSURLResponse * _Nullable response,
                                                                 NSError * _Nullable error) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        NSDictionary *result = [strongSelf xt_parseUpdateData:data response:response error:error];
        XTMainAsync(^{
            __strong __typeof__(weakSelf) innerSelf = weakSelf;
            if (innerSelf) {
                [innerSelf->_updateLock lock];
                innerSelf->_updateInfo = result;
                [innerSelf->_updateLock unlock];
            }
            if (callback) callback(result);
            [[XTHTTPServer sharedInstance] broadcastEvent:@"update_checked" data:result];
        });
    }];
    [task resume];
}

- (NSDictionary<NSString *, id> *)updateInfo {
    [_updateLock lock];
    NSDictionary *info = _updateInfo ?: @{};
    [_updateLock unlock];
    return info;
}

@end
