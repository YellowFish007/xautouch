# XAutouch Explorer（XXTExplorer）

参照商业产品 XXTouch 中 `XXTExplorer.app` 实现的等价文件管理器，是 Theos/Logos 工程中的**独立 application target**，与宿主 tweak 一起由 `aggregate.mk` 构建。

- Bundle ID：`edu.example.xautouch.explorer`
- Display Name：`XAutouch Explorer`
- 可执行文件 / 实例名：`XXTExplorer`
- 最低系统：iOS 12.0，arm64
- 界面全部由代码构建，无 storyboard / xib
- ARC，公开 UIKit / Foundation API，不调用私有 API
- **App 不直接读写越狱根文件系统**，所有文件操作通过 `http://127.0.0.1:8080` 的本地 HTTP API 完成

## 源码职责

| 文件 | 职责 |
| --- | --- |
| `main.m` | `UIApplicationMain` 入口 |
| `XTEAppDelegate.h/.mm` | 创建 window + `UINavigationController`；启动时请求 `/deviceinfo` 取 `resource_root` 注入列表页 |
| `XTEAPIClient.h/.mm` | `NSURLSession` GET/POST 封装、JSON 解析、`code != 0` 转 `NSError`、主线程回调；每个端点一个方法 |
| `XTEFileListController.h/.mm` | 目录浏览、返回上级、下拉刷新、搜索、名称/大小/时间排序、长按菜单、新建文件夹/文件、上传 |
| `XTEFileEditorController.h/.mm` | 文本/脚本编辑、保存、运行、语法检查；图片文件用 `UIImageView` 预览 |
| `Info.plist` | Bundle 元数据 |

## 与 tweak 的 HTTP 通信关系

宿主 tweak 的 `XTHTTPServer` 监听 `127.0.0.1:8080`（端口在 `XTRoutes.mm` / `XTApplication.mm` 中写死）。App 启动后：

1. `GET /deviceinfo` → 读取 `resource_root`（rootful 通常为 `/usr/lib/xautouch`，rootless 为 `/var/jb/usr/lib/xautouch`），作为用户资源根目录。失败时回退到 `/var/jb/usr/lib/xautouch`。
2. `GET /file_list?path=<dir>` → 列出目录，响应 `{code:0, data:[...]}`。
3. 其余操作全部走 `XTEAPIClient` 中对应方法。

`fileListAt:`（`Sources/XTScriptEngine.mm`）返回的真实字段为：

| 字段 | 含义 | App 解析 |
| --- | --- | --- |
| `name` | 文件名 | 显示名 |
| `path` | 完整路径 | 后续操作参数 |
| `is_dir` | 是否目录（NSNumber BOOL） | 图标 / 进入子目录 |
| `size` | 字节数（NSNumber） | 大小列，格式化为 B/KB/MB/GB |
| `mtime` | Unix 时间戳（秒，NSNumber） | 时间列 |

为容错，App 同时兼容 `isDir`/`directory`/`type`、`date`/`modified`、`bytes`/`file_size`、`filename`/`full_path` 等别名，并以真实字段优先。

端点映射：

| App 操作 | 端点 | 参数 |
| --- | --- | --- |
| 设备信息 | `GET /deviceinfo` | — |
| 列目录 | `GET /file_list` | `path` |
| 读文件 | `GET /read_file` | `path` |
| 写文件 / 新建文件 / 上传 | `POST /write_file` | JSON body `path`, `content` |
| 新建文件夹 | `POST /mkdir` | JSON body `path` |
| 删除目录 / 文件 | `POST /rmdir` / `POST /remove_file` | JSON body `path` |
| 重命名 | `POST /rename_file` | JSON body `from`, `to` |
| 复制 / 移动 | `POST /api/file/copy` / `POST /api/file/move` | JSON body `from`, `to` |
| 回收站 | `POST /recycle` | JSON body `path` |
| 加密脚本 | `GET /encript_file` | `path` |
| 运行脚本 | `GET /launch_script_file` | `path` |
| 语法检查 | `POST /check_syntax` | JSON body `source` |
| 应用列表 | `GET /applist` | — |
| 脚本列表 / 保存脚本 | `GET` / `POST /api/script` | `name`, `source` |
| 图片原始字节 | `GET /<resource_root/web 下的相对路径>` | 走宿主静态资源服务 |

GET 参数做严格百分号编码（服务端的 query/form 解析用朴素的 `=`/`&` 切分，必须避免字面量冲突）；POST 统一用 `application/json` body（服务端的 `jsonObject` 解析，可安全承载换行、等号等脚本文本）。

## 在 macOS + Theos 下编译

Makefile **未改动**。请在现有 tweak 实例定义与 `include $(THEOS_MAKE_PATH)/tweak.mk` **之后**、`include $(THEOS)/makefiles/aggregate.mk` **之前**加入：

```make
# ---- XAutouch Explorer (application target) ----
APPLICATION_NAME = XXTExplorer

XXTExplorer_FILES = Sources/XXTExplorer/main.m \
                    Sources/XXTExplorer/XTEAppDelegate.mm \
                    Sources/XXTExplorer/XTEAPIClient.mm \
                    Sources/XXTExplorer/XTEFileListController.mm \
                    Sources/XXTExplorer/XTEFileEditorController.mm

XXTExplorer_FRAMEWORKS = Foundation UIKit CoreGraphics
XXTExplorer_CFLAGS = -fobjc-arc -std=c++17 -Wno-unused-parameter
XXTExplorer_RESOURCE_FILES = Sources/XXTExplorer/Info.plist
XXTExplorer_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
```

说明：

- 现代 Theos 声明 application 实例用 `APPLICATION_NAME = XXTExplorer`，**不是** `XXTExplorer_APP_NAME`。按 Theos 约定，每个实例的配置文件前缀就是实例名本身：`XXTExplorer_FILES`、`XXTExplorer_FRAMEWORKS`、`XXTExplorer_CFLAGS`。可执行文件名为实例名 `XXTExplorer`，与 `Info.plist` 的 `CFBundleExecutable` 一致；如果改实例名，必须同步改 plist。
- `Info.plist` 放在 `Sources/XXTExplorer/` 下，所以要用 `XXTExplorer_RESOURCE_FILES` 显式加入 bundle；若改用 Theos 默认的 `Resources/Info.plist`，可删除该变量并把文件移到 `Resources/`。
- 建议显式声明 `TARGET = iphone:clang:latest:12.0`（与 `control` 的 `firmware (>= 12.0)` 一致）。Theos 默认开启 `-Wall -Werror`，明确部署目标可以避免可用性告警导致构建失败。
- 如果 `APPLICATION_NAME` 在你机器的 Theos 版本上不生效（老版本模板曾用 `APP_NAME`），把第一行改成 `APP_NAME = XXTExplorer` 重试；其余 `XXTExplorer_*` 变量不变。
- `control` 无需为 app 单独写 stanza：aggregate 会把 tweak 的 dylib 与 app 一起打进同一个 deb。

构建命令与 tweak 相同：`make package`（或 `make install` 直接安装到设备）。安装后如果出现图标未注册，执行一次 `uicache` 或重启 SpringBoard。

## 已知限制与假设

1. **图片预览**：宿主 `/read_file` 用 `NSString` UTF-8 解码，无法返回二进制图片。因此编辑器优先通过宿主的静态资源服务（`resource_root/web/...`）取原始字节；其他位置的图片会尝试按文本还原，失败时给出明确提示。这是当前 HTTP API 能力的边界，不是 UI 未实现。
2. **上传**：宿主没有通用二进制上传端点，编辑器/列表页的上传走 `/write_file`，仅支持 UTF-8 文本（脚本、配置、文本）。选择二进制文件时会提示。
3. **加密脚本 `.xxt`**：`/read_file` 会解密后返回明文供编辑，但 `/write_file` 写回的是明文。编辑并保存 `.xxt` 会把它变成明文文件，如需保持加密请重新用 `/encript_file`。
4. 返回上级采用 push 子控制器的方式，子控制器首行提供 `..  返回上级`；自动返回按钮同时可用。
5. 时间显示格式为 `yyyy-MM-dd HH:mm`（本地时区）。
6. 启动阶段若 `/deviceinfo` 请求失败，使用默认前缀 `/var/jb/usr/lib/xautouch`，随后目录请求的错误会直接提示给用户。
