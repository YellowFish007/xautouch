#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * XTUIService - SpringBoard 内显示的 UI 服务与配套控制能力
 *
 * 对应原版 uiservice-* 系列脚本（toast / show-pose / view / elerthelper）、
 * 音量键动作绑定配置，以及 xxt-check-update.lua 的版本检查。
 * 所有 UI 操作由实现内部切换到主线程执行，调用方可以在任意线程调用。
 */
@interface XTUIService : NSObject

+ (instancetype)sharedInstance;

#pragma mark - 屏幕文字提示 / 触点可视化 / 悬浮窗 / 弹窗

/// 屏幕文字提示。position: 0=顶部 1=居中 2=底部；sec<=0 时按 2 秒处理。
- (void)showToast:(NSString *)text duration:(NSTimeInterval)sec position:(NSInteger)position;

/// 触摸点圆圈。down=YES 显示；down=NO 移除坐标最接近的圆圈（无坐标时移除最后添加的）。
- (void)showPoseAtX:(double)x y:(double)y touchDown:(BOOL)down;

/// 显示可拖动的悬浮窗；重复调用只更新文字，不会叠加多个窗口。
- (void)showFloatingViewWithText:(NSString *)text;

/// 关闭悬浮窗。
- (void)hideFloatingView;

/// 弹窗。actions 为按钮标题数组，为空时自动补一个“确定”；completion 回调按钮索引（从 0 开始）。
- (void)showAlertTitle:(NSString *)title
               message:(NSString *)msg
               actions:(NSArray<NSString *> *)actions
            completion:(void (^ _Nullable)(NSInteger idx))completion;

#pragma mark - 音量键动作绑定

/**
 * 绑定动作到 key。key 接受 volume_up / volume_down / long_press（大小写不敏感）。
 * actionJSON 形如 {"action":"tap","x":100,"y":200}，
 * 也兼容原版配置中的纯字符串 "none"。配置写入 resourceRoot/volume_action_conf.plist。
 */
- (void)bindVolumeKey:(NSString *)key action:(NSString *)actionJSON;

/// 返回该键已绑定的动作 JSON 字符串；未绑定返回 nil。
- (nullable NSString *)volumeActionFor:(NSString *)key;

/// 由音量键事件调用：读取绑定动作并派发到触摸合成器 / 脚本引擎。
- (void)handleVolumeKey:(NSString *)key;

#pragma mark - 版本检查

/**
 * 请求 https://xxtouch.app/api/latest-version 并与本地版本比较。
 * 结果字典：{code, current, latest, hasUpdate, downloadUrl, changelog, error}，
 * code=0 表示请求与解析成功；completion 始终回主线程调用。
 */
- (void)triggerUpdateCheckWithCompletion:(void (^ _Nullable)(NSDictionary<NSString *, id> *info))completion;

/// 最近一次版本检查结果；未检查过时返回空字典。
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *updateInfo;

@end

NS_ASSUME_NONNULL_END
