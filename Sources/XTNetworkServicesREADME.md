# XAutouch 网络服务模块说明

本目录的三个模块对标 XXTouch 的三个 Lua 脚本，全部以 Objective-C++ 实现在 SpringBoard 进程内：

| 模块 | 对标脚本 | 职责 |
| --- | --- | --- |
| `XTUDPControl` | `touchelf-udpd.lua` | UDP 控制服务，JSON over UDP 指令、token 校验、统一动作分发 |
| `XTCloudControl` | `open-cloud-control-client.lua` | 云控 WebSocket 客户端，心跳/重连/状态持久化 |
| `XTScreenShare` | `web-screen.lua` | 定时抓屏、JPEG 压缩、UDP 分片发送、MJPEG 取帧 |

> 参照 Lua 脚本本身只是参考实现：`touchelf-udpd.lua` 实际只做发现应答（14099/8001），`open-cloud-control-client.lua` 实际是一个 46968 端口的 WebSocket **服务端**，而 `web-screen.lua` 是同端口的远程控制 WebSocket 服务端。本工程按任务书要求把三者实现为「本地 UDP 控制服务 / 主动外连云控客户端 / 屏幕推流 + MJPEG 输出」，同时在命令解析上兼容参照脚本的 `type/mode/body` 与 `touch/*` `key/*` 命名。

---

## 1. XTUDPControl — UDP 控制服务

### 1.1 实现要点

- 单例 `+sharedInstance`；`-start` 默认端口 **46900**，`-startOnPort:` 可指定端口。
- BSD `socket(AF_INET, SOCK_DGRAM, 0)` + `dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, serial_queue)`。
- socket 设为 `O_NONBLOCK`，每次读事件最多排空 64 个数据报；接收缓冲区 65535 字节。
- 端口占用/绑定失败只写 `last_error` 并返回 `NO`，不崩溃。
- 所有 JSON 解析、截图 base64 分片在后台 serial queue（截图本身切主线程），不在主线程解析大帧。

### 1.2 报文协议（JSON over UDP）

请求（客户端 → 设备）：

```json
{"cmd":"tap","x":320,"y":640,"seq":12,"token":"<32位hex>"}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `cmd` | string | `tap` / `down` / `move` / `up` / `key` / `text` / `script` / `ping` / `screen` |
| `x`,`y` | number | 触摸坐标；`down/move/up` 可用 `id` 或 `finger` 指定手指（默认 1） |
| `key` 或 `code` | string | `key` 的键名；也可用 `key/down`、`key/up` 区分按下/抬起 |
| `text` | string | `text` 命令的输入文本 |
| `name` 或 `source` | string | `script` 命令的脚本名或源码 |
| `seq` | number | 客户端序号，回包原样带回 |
| `token` | string | 鉴权 token |

兼容写法：`cmd` 可由 `type` / `mode` 替代（如 `type:"touch/down"`），参数可放在 `body` 字典里；`heart` 等同 `ping`。

响应（设备 → 客户端）：

| 场景 | 报文 |
| --- | --- |
| ping | `{"cmd":"pong","seq":N}` |
| 脚本执行结果 | `{"cmd":"script_result","result":{...},"seq":N}` |
| 截图分片 | `{"seq":i,"total":T,"data":"<base64 PNG片段>","req_seq":N}` |
| JSON 解析失败 | `{"cmd":"error","reason":"invalid_json","detail":"..."}` |
| token 错误 | `{"cmd":"error","reason":"unauthorized","seq":N}` |
| 未知命令 | `{"cmd":"error","reason":"unknown_command","seq":N}` |

截图分片每片原始 768 字节 → base64 1024 字符，加 JSON 头后 < 1200 字节（低于以太网 MTU），按 `seq` 从 1 到 `total` 拼接后 base64 解码得到完整 PNG。

### 1.3 token

- 路径：`<resourceRoot>/device_token`（默认 `/var/jb/usr/lib/xautouch/device_token`）。
- 首次启动用 `arc4random_buf` 生成 16 字节随机数，转 32 位小写 hex，写入文件并设权限 `0600`。
- 每次收包校验 `token` 完全一致，不匹配丢弃并回 `unauthorized`。
- `-token` 可读取当前 token（供 Web 面板展示/配网使用，注意不要暴露给公网）。

### 1.4 对外接口

```objc
+ (instancetype)sharedInstance;
- (BOOL)start;
- (BOOL)startOnPort:(UInt16)port;
- (void)stop;
- (BOOL)isRunning;
- (UInt16)port;
- (nullable NSString *)token;
- (NSDictionary *)stats;   // running/port/received/dropped/sent/last_error
- (BOOL)executeCommand:(NSDictionary *)command
               onReply:(nullable void (^)(NSDictionary *reply))reply;
- (BOOL)executeCommand:(NSDictionary *)command;
- (BOOL)sendJSON:(NSDictionary *)obj toAddress:(NSData *)sockaddrData;
```

`executeCommand:onReply:` 是 UDP 与云控共用的动作分发入口，调用方负责鉴权；`screen` 的回包回调会异步触发多次。

---

## 2. XTCloudControl — 云控客户端

### 2.1 连接

- `-connectToServer:port:token:` 连接 `ws://host:port/ws?token=<percent-encoded>`。
- 使用 iOS 13+ 的 `NSURLSessionWebSocketTask`（Foundation 公开 API），delegate 队列为 serial `NSOperationQueue`。
- `-disconnect` / `-isConnected` / `-status` / `-config` / `-saveConfig:` / `-startAutoConnectIfNeeded`。
- 收到文本/二进制帧统一按 UTF-8 JSON 解析，随后调用 `[[XTUDPControl sharedInstance] executeCommand:onReply:]`，回包写回 WebSocket；`ping`/`heart` 回 `pong`。

### 2.2 心跳与重连

- 主线程 `NSTimer` 每 **20 秒**发送 `{"cmd":"ping"}`。
- 连续 **3** 次没有收到 `pong` 触发主动断开并重连。
- 重连最多 **5** 次，退避时间为 `2^n` 秒（1、2、4、8、16）。
- 每次连接/断开/重连都递增 generation，过期回调一律忽略，避免旧连接串扰。
- 连接失败只更新状态/统计和 `last_error`，不崩溃。

### 2.3 持久化与事件

- 配置：`<resourceRoot>/cloud_conf.plist`，字段 `server`(string) / `port`(number，默认 46968) / `token`(string) / `autoConnect`(bool)；`-saveConfig:` 会合并默认值后写盘并设权限 `0600`。
- 状态：`<resourceRoot>/cloud_status.plist`，字段见 `-status`。
- 状态变化通过 `[[XTHTTPServer sharedInstance] broadcastEvent:@"cloud_status" data:...]` 走现有 SSE 通道广播。

---

## 3. XTScreenShare — 屏幕共享

### 3.1 实现要点

- `-startWithFPS:quality:`（fps 限制 1..30，quality 限制 0.05..1.0）；`-stop` / `-isRunning` / `-lastFrameStats`。
- 私有 serial queue 上的 `dispatch_source` 定时器按 fps 触发；上一帧耗时大于帧间隔则丢帧（`dropped_frames`）。
- 截图走 `XTCapture captureScreen`（主线程），PNG 文件读完即删，避免高频抓屏堆积文件；`UIImage` 解码后按 quality 转 JPEG。
- 每帧写入 `<resourceRoot>/screen_last.jpg`，并通过 `NSCondition` 通知 MJPEG 等待者。

### 3.2 目标配置

`<resourceRoot>/screen_target.plist`：

```xml
<dict>
  <key>host</key><string>192.168.1.100</string>
  <key>port</key><integer>47000</integer>
</dict>
```

- host 支持 IPv4 字面量或主机名（`getaddrinfo` 解析）。
- 未配置或解析失败时只做本地缓存，服务仍正常运行（统计里 `has_target=NO`）。
- 使用**独立 UDP socket**（`bind` 到随机本地端口后 `connect` 到目标），不占用 XTUDPControl 的 46900 端口。

### 3.3 帧协议（UDP）

```json
{"cmd":"frame","seq":1,"total":42,"w":1170,"h":2532,"data":"<base64 JPEG片段>"}
```

分片规则同 UDP 截图：每片 768 原始字节，`seq` 从 1 到 `total`。

### 3.4 MJPEG 取帧

- `-nextJPEGFrameWithTimeout:` 在 `NSCondition` 上等待**下一帧**（不是重复返回同一帧），超时返回 `nil`。
- HTTP 路由 `/api/screen/stream` 循环调用本方法，把返回的 JPEG 按 `multipart/x-mixed-replace` 边界写出即可；客户端断开时 recv/send 失败自然退出循环。
- `-stop` 会 broadcast 条件，唤醒所有等待者。

---

## 4. HTTP 路由建议（在 XTRoutes.mm 中接线）

| 路由 | 方法 | 说明 |
| --- | --- | --- |
| `/api/udp/start` | POST | 可选 `port` 参数，启动 UDP 服务，返回 `ok/stats` |
| `/api/udp/stop` | POST | 停止 UDP 服务 |
| `/api/udp/stats` | GET | 返回 XTUDPControl `-stats` |
| `/api/udp/token` | GET | 返回当前 token（仅局域网/Web 面板使用） |
| `/api/cloud/connect` | POST | `server`/`port`/`token` 参数，调用 `-connectToServer:port:token:` |
| `/api/cloud/disconnect` | POST | 断开云控 |
| `/api/cloud/status` | GET | 返回 `-status` |
| `/api/cloud/config` | GET/POST | 读/写 `cloud_conf.plist` |
| `/api/screen/stream/start` | POST | `fps`/`quality` 参数，启动屏幕共享 |
| `/api/screen/stream/stop` | POST | 停止屏幕共享 |
| `/api/screen/stream/stats` | GET | 返回 `-lastFrameStats` |
| `/api/screen/stream` | GET | MJPEG 长连接，循环写 `nextJPEGFrameWithTimeout:` 的结果 |

SSE 事件 `cloud_status` 会复用现有 `/api/log/stream` 广播通道，无需新增 SSE 实现。

---

## 5. 安全说明

- UDP 与云控都必须带 token；UDP 不匹配直接丢弃并回 `unauthorized`，不计入正常指令。
- token 与配置文件写盘后权限设为 `0600`。
- 默认 HTTP 服务监听 `0.0.0.0:46899`，只有 token 保护 UDP/WebSocket；生产部署请配合防火墙或只绑内网，Web 面板暴露 token 的路由不要对公网开放。
- 截图/屏幕分片通过 base64 放在 JSON 里，单包 < 1200 字节；接收端需校验 `total` 与所有 `seq` 到齐后再拼接，避免乱序/重放。

---

## 6. 框架依赖与编译

- 依赖 `Foundation`、`UIKit`、`QuartzCore`（均已在 Makefile 的 `XAutouch_FRAMEWORKS` 中）。
- `NSURLSessionWebSocketTask` 位于 Foundation，需 iOS 13+ 运行时；代码内有 `@available(iOS 13.0, *)` 保护，低版本只返回错误。
- socket/GCD 使用系统 C API：`<sys/socket.h>`、`<netinet/in.h>`、`<arpa/inet.h>`、`<netdb.h>`、`<unistd.h>`、`<fcntl.h>`、`<errno.h>`、`<string.h>`、`<stdlib.h>`、`<math.h>`、`libdispatch`。
- token 随机源用 `arc4random_buf`（libc），**不需要**额外链接 `Security.framework`。
- 全部源码 ARC 兼容（Makefile 已有 `-fobjc-arc`），无私有 API，无 TODO/占位实现。
