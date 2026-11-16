# XTWebRTCMedia 媒体传输层说明

## 1. 定位与设计取舍

本模块把工程的 WebRTC 能力从"仅信令层"补成"真实媒体传输层"，但**不引入 libwebrtc**（体积大、SpringBoard 注入下编译/运行都不现实）。做法是用 iOS 系统公开框架拼出一条真实可用的单向媒体链路：

```
[设备]  XTCapture 截图(PNG)
          -> CGImageSource 解码为 CGImage
          -> CVPixelBufferCreate(kCVPixelFormatType_32BGRA)
          -> VTCompressionSession 编码 H.264 (Baseline)
          -> AVCC 长度前缀转换为 Annex-B (0x00000001 start code)
          -> 自定义 RTP-like 帧协议分片
          -> BSD UDP socket sendto  -->  目标 host:port

[设备]  AVAudioEngine 麦克风 tap (PCM Float32 48k mono)
          -> AudioConverter 编码 AAC LC (1024 frames/packet)
          -> 同一 UDP socket，type=audio

[控制]  远端反向触摸事件仍走现有 /api/touch/* HTTP 路由，媒体层不重复实现。
```

会话协商沿用现有 `/api/webrtc/*` 信令路由，但 SDP 是**简化 JSON**（不是真正的 WebRTC SDP），见第 3、4 节。

## 2. 分包协议

### 2.1 数据报头（32 字节，固定）

所有整数字段按**网络字节序（大端）**填充；发送端用 `htonl/htons`，接收端用 `ntohl/ntohs`。

| 偏移 | 长度 | 字段 | 含义 |
|-----:|-----:|------|------|
| 0 | 4 | magic | 固定 `'X' 'T' 'M' 'D'` (0x58 0x54 0x4D 0x44)，用于校验与丢包错包过滤 |
| 4 | 4 | seq | 包序号 `uint32`，每发一个 UDP 数据报 +1，可用于乱序检测 |
| 8 | 4 | timestamp_hi | 微秒时间戳高 32 位 `uint32` |
| 12 | 4 | timestamp_lo | 微秒时间戳低 32 位 `uint32`，与 hi 合成 `uint64` |
| 16 | 4 | naluLen | 完整逻辑帧 payload 的总字节数 `uint32`（不是本分片长度） |
| 20 | 4 | frameId | 逻辑帧编号 `uint32`，同一帧的所有分片相同 |
| 24 | 2 | fragIdx | 当前分片序号 `uint16`，0-based |
| 26 | 2 | fragCnt | 该帧总分片数 `uint16` |
| 28 | 1 | type | `0`=video(H.264 Annex-B)，`1`=audio(AAC 裸流) |
| 29 | 1 | flags | video：`bit0=1` 表示关键帧（本帧携带 SPS/PPS）；audio 恒为 0 |
| 30 | 2 | reserved | 保留，填 0 |
| 32 | ... | payload | 本分片数据；单个数据报总长 ≤ 1200 字节，故 payload ≤ 1168 字节 |

任务给定的核心字段 `[magic:4][seq:4][timestamp:8][naluLen:4][payload]` 全部保留；为支持分片与重组，在 `naluLen` 与 `payload` 之间插入了 `frameId/fragIdx/fragCnt/type/flags/reserved` 共 16 字节控制字段。

### 2.2 分片规则

- 一个逻辑帧（一帧视频 = 一段完整 Annex-B，含 SPS/PPS + 若干 NALU；一帧音频 = 一个 AAC packet）按 1168 字节切分。
- `fragCnt = ceil(naluLen / 1168)`，`fragIdx` 从 0 递增。
- 分片通过 GCD 串行队列异步 `sendto`，网络 I/O 不阻塞 VideoToolbox 编码回调。
- socket 设为 `O_NONBLOCK`，`EAGAIN/EWOULDBLOCK` 计为可恢复丢包，不阻塞队列。

### 2.3 接收端重组算法（伪代码）

```
map<frameId, FrameAssembly> frames

onDatagram(pkt):
    if pkt.magic != 'XTMD': discard
    if pkt.payloadLen != pkt.len - 32: discard            # 截断校验
    a = frames[pkt.frameId] or create(capacity=pkt.naluLen)
    a.type = pkt.type; a.keyframe = pkt.flags & 1
    a.timestamp = (pkt.timestamp_hi << 32) | pkt.timestamp_lo
    a.chunks[pkt.fragIdx] = pkt.payload
    if a.chunks.count == pkt.fragCnt:                     # 全部到齐
        frame = concat(a.chunks[0..fragCnt-1])
        assert frame.length == pkt.naluLen
        emit(frame, a.type, a.keyframe, a.timestamp)
        frames.remove(pkt.frameId)
    if a.age > 2s: frames.remove(pkt.frameId)             # 超时丢弃，防止内存泄漏
```

关键点：`frameId` 标识逻辑帧，`fragCnt` 决定何时拼齐；`naluLen` 用于校验完整性。乱序由 `fragIdx` 作为数组下标自然处理。

## 3. 与现有信令层的接线

信令路由**不需要新增**，继续用 `/api/webrtc/poll` `/answer` `/ice` `/stop`。改动只在 `XTApplication.mm`（负责人统一改）：

1. `webrtcAnswer:(NSString *)sdp`：把 `sdp` 解析为简化 JSON（含 `host/port/fps/bitrate/audio`），调用
   `[[XTWebRTCMedia sharedInstance] startSessionWithConfig:cfg];`
   同时保留原有 `_rtcQueue` 入队逻辑（Web 端仍可 poll 到该消息）。
2. `webrtcIce:(NSString *)candidate`：调用
   `[[XTWebRTCMedia sharedInstance] handleRemoteMessage:@{@"type":@"ice", @"candidate":candidate}];`
   用于运行时切换目标地址（ICE 候选）。
3. `webrtcStop`：调用
   `[[XTWebRTCMedia sharedInstance] stopSession];`
4. `webrtcPoll`：在返回字典里附加 `@"stats": [[XTWebRTCMedia sharedInstance] sessionStats]`，
   让 Web 面板能显示 fps/码率/帧数。

`handleRemoteMessage:` 也支持直接传入 `@{@"type":@"answer", @"sdp":...}` / `@{@"type":@"stop"}`，
便于把 `_rtcQueue` 里的消息统一转发给媒体层：`for (NSDictionary *m in pending) [[XTWebRTCMedia sharedInstance] handleRemoteMessage:m];`

## 4. Web 端接收思路（浏览器）

UDP 不能被浏览器直接接收，需要一个**网关**把 UDP 数据报转成 WebSocket 二进制帧：

```
设备 --UDP--> [UDP→WS 网关(Node/Python，监听某端口)] --WebSocket binary--> 浏览器
```

浏览器侧思路（非完整工程代码，仅关键路径）：

```js
const ws = new WebSocket('ws://gateway:port');
ws.binaryType = 'arraybuffer';

ws.onmessage = (e) => {
  const dv = new DataView(e.data);
  if (dv.getUint32(0) !== 0x58544d44) return;            // magic 'XTMD'
  const tsHi = dv.getUint32(8), tsLo = dv.getUint32(12);
  const ts = (tsHi * 2 ** 32 + tsLo) / 1e6;              // 秒
  const naluLen = dv.getUint32(16), frameId = dv.getUint32(20);
  const fragIdx = dv.getUint16(24), fragCnt = dv.getUint16(26);
  const type = dv.getUint8(28), keyframe = dv.getUint8(29) & 1;
  const payload = new Uint8Array(e.data, 32);
  // 按第 2.3 节重组；拼齐后得到完整 Annex-B H.264 或 AAC 包
};

// 播放方案 A（推荐，最简）：WebCodecs 直接解 Annex-B
const decoder = new VideoDecoder({
  output: frame => { ctx.drawImage(frame, 0, 0); frame.close(); },
  error: e => console.error(e)
});
decoder.configure({ codec: 'avc1.42001e', avc: { format: 'annexb' } });
// 拼齐的 video 帧直接 decoder.decode(new EncodedVideoChunk({
//   type: keyframe ? 'key' : 'delta', timestamp: ts * 1e6, data: frame }))

// 播放方案 B：MediaSource + SourceBuffer
//   mime: 'video/mp4; codecs="avc1.42E01E"'
//   需先把 Annex-B 转成 AVCC 长度前缀，并封装成 fMP4(moof/mdat) 片段再 appendBuffer。
//   音频 AAC 裸流可用 AudioDecoder 或封装 ADTS 后交给 WebAudio。
```

说明：WebCodecs `avc.format:'annexb'` 在较新 Chromium 可用；若目标浏览器不支持，走方案 B 的 fMP4 封装。

## 5. 框架依赖清单（Makefile）

在现有 `XAutouch_FRAMEWORKS` 末尾追加（均为 iOS 公开 framework）：

```
VideoToolbox CoreMedia CoreVideo ImageIO AVFoundation AudioToolbox
```

`Foundation / UIKit / CoreGraphics` 已在现有列表中，无需重复。
socket 相关 `sys/socket.h` 等属 libc，不需要额外 framework。
**无需新增私有 framework**，也无需添加 `libwebrtc` 之类第三方库。

源文件在 `XAutouch_FILES` 追加一行：

```
Sources/XTWebRTCMedia.mm
```

`XAutouch_CFLAGS` 已有 `-fobjc-arc -std=c++17`，满足本模块 ARC 与 C++17（`std::atomic`）要求，无需改动。

## 6. 运行时依赖与降级

本模块可编译、可运行，但下列能力依赖系统/授权条件，已内置语义正确的降级路径：

| 能力 | 条件 | 降级行为 |
|------|------|----------|
| 截图 | 依赖 `XTCapture` 的 `UIScreen snapshotAfterUpdates:` 私有 API；非主线程会同步切主线程 | 截图失败/API 不可用时该帧计入 `dropped`，跳过本次编码，不崩溃 |
| 编码器 | `VTCompressionSession` 需要真机（模拟器不支持 H.264 硬编码） | 创建失败时该帧丢弃并记录；目标为 iphoneos-arm64 真机，正常可用 |
| CVPixelBuffer | 优先 IOSurface-backed；某些上下文不可用 | 自动退回普通 `CVPixelBufferCreate`（代码已实现） |
| 麦克风 | `AVAudioEngine` 需麦克风授权与可用 AudioSession；SpringBoard 注入通常拿不到 | `startAndReturnError` 失败时自动切换到"静音 AAC 帧"定时器，按 48kHz/1024 帧真实编码发送，保证音频轨存在、链路不空转 |
| UDP 目标 | 需从 answer/ICE 解析出可达的 host:port | 地址无效则不启动会话并写日志；ICE 到达后可运行时热切换目标地址 |

所有降级路径都是真实代码，没有空函数或 TODO。统计字段 `dropped` 可观测降级频率。

## 7. 统计字段（sessionStats）

| 键 | 含义 |
|----|------|
| `running` | 会话是否运行中 |
| `fps` | 最近 1 秒窗口内的编码帧率 |
| `bitrate` | 自会话开始累计发送字节折算的bps |
| `framesSent` | 累计发送逻辑帧数（视频帧 + 音频帧） |
| `packetsSent` | 累计 UDP 数据报数 |
| `bytesSent` | 累计发送字节数 |
| `dropped` | 累计丢弃（截图失败/编码失败/sendto 错误） |
