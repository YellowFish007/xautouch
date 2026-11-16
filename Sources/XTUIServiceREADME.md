# XTUIService 使用说明

`XTUIService` 是 SpringBoard 进程内的 UI 服务单例，把原版 XXTouch 一组 `uiservice-*` 脚本的能力用 Objective-C 原生实现，并补上音量键动作绑定与版本检查。头文件：`Sources/XTUIService.h`，实现：`Sources/XTUIService.mm`。

## 1. 与原版脚本的对应关系

| 原版脚本 | 本模块接口 | 说明 |
| --- | --- | --- |
| `uiservice-toast-service.lua`（`send-toast`） | `showToast:duration:position:` | 黑底白字圆角标签，`position` 0/1/2 对应顶部/居中/底部，NSTimer 到期淡出 |
| `uiservice-show-pose-service.lua`（`show-pose`） | `showPoseAtX:y:touchDown:` | 按下显示彩色圆圈+白色描边，抬手放大淡出；多点按最近坐标匹配 |
| `uiservice-view-service.lua`（悬浮窗视图） | `showFloatingViewWithText:` / `hideFloatingView` | 可拖动面板 + 关闭按钮，重复调用只更新文字 |
| `ui-elerthelper-service.lua` / `lua/alerthelper.lua`（弹窗） | `showAlertTitle:message:actions:completion:` | 用独立 UIWindow + 新建 `UIViewController` 承载 `UIAlertController`，按标题数组生成按钮并回调索引 |
| 音量键绑定配置（原版 `volume_action_conf.plist`） | `bindVolumeKey:action:` / `volumeActionFor:` / `handleVolumeKey:` | 配置落在 `resourceRoot/volume_action_conf.plist`，键为 `volume_up` / `volume_down` / `long_press` |
| `bin/xxt-check-update.lua` | `triggerUpdateCheckWithCompletion:` / `updateInfo` | GET `https://xxtouch.app/api/latest-version`，超时 15 秒，结果字典回主线程 |
| `web/upgrade.js` | 见下方 `/api/system/check-update` | Web 面板升级入口调用后端路由，本模块只负责返回检查结果 |

## 2. 线程与窗口约定

- 所有公开方法内部都 `dispatch_async(dispatch_get_main_queue(), ...)`，调用方可以在任意线程调用。
- Toast / Pose / 悬浮窗 / Alert 各自创建一个 `UIWindow`，由单例 **strong 持有**，窗口层级分别为 `UIWindowLevelAlert + 1/2/3/4`。
- 纯展示层（Toast / Pose）设置 `userInteractionEnabled = NO`，不会吞掉桌面触摸；悬浮窗面板与 Alert 需要交互。
- 除 Alert 使用 `makeKeyAndVisible` 保证弹窗可交互外，其余窗口只设 `hidden = NO`，不抢占 keyWindow，避免干扰 SpringBoard 的输入焦点。
- 悬浮窗拖动用 `UIPanGestureRecognizer`，并把面板中心限制在屏幕范围内。

## 3. HTTP 路由建议（加到 `XTRoutes.mm`）

| 路由 | 方法 | 参数 | 返回 |
| --- | --- | --- | --- |
| `/api/ui/toast` | POST | `text`、`duration`（秒）、`position`（0/1/2） | `{code:0}` |
| `/api/ui/pose` | POST | `x`、`y`、`down`（1 显示 / 0 移除） | `{code:0}` |
| `/api/ui/floating` | POST | `text` | `{code:0}` |
| `/api/ui/floating` | DELETE | 无 | `{code:0}` |
| `/api/ui/alert` | POST | `title`、`message`、`actions`（数组） | `{code:0}`（按钮点击结果通过 `broadcastEvent:@"ui_alert_choice"` 推送） |
| `/api/volume/bind` | POST | `key`、`action`（JSON 字符串） | `{code:0, data:{key, action}}` |
| `/api/volume/action` | GET | `key` | `{code:0, data:actionJSON}` |
| `/api/system/check-update` | GET | 无 | `{code:0, data:{code,current,latest,hasUpdate,downloadUrl,changelog,error}}` |

路由内部先把参数取出，再调用 `XTUIService` 单例；UI 类调用即刻返回（`code:0` 表示已受理），弹窗按钮索引通过 SSE/WebSocket 广播事件 `ui_alert_choice` 异步回传。

## 4. 音量键动作 JSON 格式

持久化在原版同名的 `volume_action_conf.plist`，值为 JSON 字符串；也兼容原版纯字符串 `"none"`。

```json
{"action":"tap","x":100,"y":200}
{"action":"script","name":"main.lua"}
{"action":"key","key":"HOME"}
{"action":"none"}
```

- `tap`：调用 `XTTouchSynthesizer tapAtX:y:`
- `script`：调用 `XTScriptEngine runScriptNamed:`
- `key`：调用 `XTTouchSynthesizer pressKey:`
- 触摸/脚本执行派发到全局后台队列，不阻塞 SpringBoard 主线程；完成后主线程广播 `volume_key` 事件。

## 5. 自更新结果字典

`triggerUpdateCheckWithCompletion:` 与 `updateInfo` 返回：

```
{ code, current, latest, hasUpdate, downloadUrl, changelog, error }
```

- `code`：`0` 成功；`-1` 网络错误、`-2` HTTP 非 200、`-3` 空响应、`-4` JSON 非法、`-5` 缺少版本字段。
- 响应兼容两种结构：顶层直接是版本对象，或包在 `app.xxtouch.ios` 键下（原版接口即后者）。
- 字段容错：`latest`/`version`/`v`、`download_url`/`downloadUrl`/`url`/`tipa-url`/`download`、`changelog`/`description`/`description_zh_*`/`notes`。
- `current` 优先读 `resourceRoot/control` 的 `Version:` 行，读不到回退 `1.0.0`。
- `hasUpdate` 为按点分段整数比较后的结果；`completion` 始终回主线程调用，并广播 `update_checked` 事件。

## 6. SpringBoard 显示 UI 的注意事项

1. SpringBoard 自身没有可用的 `rootViewController`，`UIAlertController` 不能直接 present。本模块新建 `UIWindow`，把 `[[UIViewController alloc] init]` 设为 `rootViewController` 再 present，这是可行的替代方案。
2. `UIWindow` 必须 strong 持有，创建后不能是栈上临时变量，否则会立即释放导致界面不显示。
3. 覆盖层窗口不要随便 `makeKeyAndVisible`，否则 SpringBoard 会失去 keyWindow，状态栏/控制中心输入异常；只有需要文本交互的 Alert 使用。
4. 所有 UI 操作必须在主线程；Hook 里收到音量键事件时不要直接改 UI。
5. 纯展示窗口设 `userInteractionEnabled = NO`，避免遮挡桌面手势；悬浮窗面板本身允许交互。
6. 圆圈、标签、面板均使用系统公开 UIKit API，不需要私有方法；`QuartzCore` 已在 Makefile 的 framework 列表中。
7. 重复调用要有幂等性：Toast 复用同一个 label 并 resets timer；Pose 按坐标匹配抬手圆圈；悬浮窗复用同一个 panel；Alert 先 dismiss 旧弹窗再 present 新弹窗。
