# XAutouch 可插拔视觉引擎

## 1. 总览

四套视觉引擎，统一走 `XTVisionEngine` 协议（`Sources/XTVisionEngine.h`）：

| engineId | 实现 | 能力 | 依赖 |
|---|---|---|---|
| `builtin` | `XTVision.mm` 内的 Apple Vision + 自写 NCC | 模板匹配 + OCR | iOS 系统框架，始终可用 |
| `onnx` | `XTONNXEngine` | 检测模型 + CTC OCR | `libonnxruntime.1.17.3.dylib`、`models/*.onnx` |
| `ncnn` | `XTNCNNEngine` | 检测 + 标签文本 | `libncnn.dylib`、`models/ncnn.param`、`models/ncnn.bin`、extern C 桥接 |
| `tesseract` | `XTTesseractEngine` | OCR（chi_sim/eng） | `libtesseract.dylib`、`liblept.dylib`、`tessdata/*.traineddata` |

`builtin` 不是注册进 Registry 的对象，而是 Registry 没有任何可用外部引擎时的兜底实现，保留在 `XTVision.mm` 中。

优先级（数值越小越优先）：`onnx(10)` → `ncnn(20)` → `tesseract(30)`。用户显式选择优先于优先级；被选引擎不可用时按优先级自动降级；全部不可用时回落到 `builtin`。

## 2. HTTP 切换方式

### 2.1 查询引擎列表与状态

```
GET /api/vision/engines
```

返回示例：

```json
{
  "code": 0,
  "data": [
    {"id":"onnx","description":"ONNX Runtime 1.17.3 / API v17","available":true,"selected":false},
    {"id":"ncnn","description":"ncnn（extern C 桥接 / dlsym）","available":false,"selected":false},
    {"id":"tesseract","description":"Tesseract C API（chi_sim/eng，dlsym）","available":true,"selected":true}
  ]
}
```

### 2.2 查询/设置当前引擎

```
GET  /api/vision/engine
POST /api/vision/engine        body: {"id":"onnx"}
```

- `GET` 返回 `activeId`（用户持久化的选择）、`effectiveId`（实际生效引擎，含降级后的结果）、`fallbackOrder`。
- `POST` 把 `id` 写入 `NSUserDefaults` suite `edu.example.xautouch` 的 `XTVisionActiveEngineId`，立即生效，重启后保留。
- 传 `{"id":"builtin"}` 或 `{"id":""}` 可清除选择，回到自动优先级模式。
- 设置一个不存在的 id 不会报错，但 `activeEngine` 会走降级链；用 `GET` 复查 `effectiveId` 即可确认。

现有视觉路由保持不变：`/api/vision/template`、`/api/vision/ocr`、`/ocr`。它们内部经 Registry 转发，因此切换引擎后无需改调用方。

## 3. 模型文件放置与获取

所有路径相对于 `[XTApplication resourceRoot]`（默认 `/var/jb/usr/lib/xautouch`）：

```
<resourceRoot>/
├── lib/
│   ├── libonnxruntime.1.17.3.dylib
│   ├── libncnn.dylib
│   ├── libtesseract.dylib
│   └── liblept.dylib            # 可选，若已被 libtesseract 依赖则可省
├── models/
│   ├── detect.onnx              # ONNX 检测（findTemplate）
│   ├── ocr.onnx                 # ONNX CTC OCR（ocrExpect）
│   ├── ocr_chars.txt            # 可选，CTC 字符集，每行一个字符；index 0 为 blank
│   ├── detect_labels.txt        # 可选，检测类别标签，每行一个
│   ├── ncnn.param               # ncnn 网络结构
│   └── ncnn.bin                 # ncnn 权重
└── tessdata/
    ├── chi_sim.traineddata
    └── eng.traineddata
```

下载占位（把 `[MODEL_URL]` 替换为实际发布地址后解压到上述目录）：

| 文件 | 获取方式占位 |
|---|---|
| `libonnxruntime.1.17.3.dylib` | `[MODEL_URL]/onnxruntime/1.17.3/libonnxruntime.1.17.3.dylib` |
| `detect.onnx` | `[MODEL_URL]/models/detect.onnx` |
| `ocr.onnx` | `[MODEL_URL]/models/ocr.onnx` |
| `ncnn.param` / `ncnn.bin` | `[MODEL_URL]/models/ncnn_bundle.zip` |
| `chi_sim.traineddata` | `[MODEL_URL]/tessdata/chi_sim.traineddata`（亦可用 tesseract 官方 tessdata_fast 仓库） |
| `eng.traineddata` | `[MODEL_URL]/tessdata/eng.traineddata` |

建议 deb 包把 `lib/` 与 `models/` 作为可选依赖包发布：用户不装这些包时，三个适配器 `available=NO`，自动回落到 `builtin`，不会崩溃。

### 3.1 模型输出格式约定

- `detect.onnx`：单输出，最后一维为每条框 `[x1, y1, x2, y2, score, class]`。坐标 0..1 视为归一化，>1 视为像素。`detect_labels.txt` 存在时按行号对应 class。
- `ocr.onnx`：单输出，CTC 结构 `[N, T, C]` 或 `[T, C]`，字符集默认 ASCII，可由 `ocr_chars.txt` 覆盖（首行为 blank）。
- ncnn 桥接：输出 JSON 数组 `[{"x":12,"y":34,"w":80,"h":80,"score":0.91,"label":"..."}]`。

### 3.2 ncnn 桥接函数构建示例

`libncnn.dylib` 需要导出下面两个 `extern "C"` 函数之一（推荐带模型路径的 `ex` 版本）。源码片段（单独编译进 libncnn.dylib，不参与本工程编译）：

```cpp
extern "C" int xt_ncnn_detect_ex(const char *param, const char *bin,
                                 const unsigned char *rgba, int w, int h,
                                 float threshold, char *outJson, int outCap);
```

实现内部用 `ncnn::Net::load_param(param)` / `load_model(bin)`，把 RGBA 转成 `ncnn::Mat::from_pixels_resize(rgba, ncnn::Mat::PIXEL_RGBA2BGR, w, h, targetW, targetH)`，执行 `extract` 后把框序列化为上述 JSON 写入 `outJson`，返回写入字节数。

## 4. 编译不依赖第三方库的机制

1. 三个适配器的 `.h` 只 import Foundation 与 `XTVisionEngine.h`。Ort 指针在 `XTONNXEngine.h` 中一律声明为 `void *`，其余两个适配器只持有 `void *` dlopen 句柄。
2. ONNX Runtime 的 `OrtApi` 函数表只在 `XTONNXEngine.mm` 内按 v1.17.3 官方头文件 ABI 逐项声明前 101 项；通过 `OrtGetApiBase` → `GetApi(17)` 取得，再调用 `CreateSession` / `Run`。没有 `#include <onnxruntime_c_api.h>`，没有链接 `-lonnxruntime`。
3. ncnn / Tesseract / Leptonica 全部通过 `dlopen` + `dlsym` 按符号名取函数指针，签名用 `typedef` 显式声明，没有 import 头文件。
4. 动态库按 `[XTApplication resourceRoot]/lib` → `jbRoot/usr/lib` → `/usr/lib` → `/var/jb/usr/lib` → 裸库名（交给 dyld）顺序探测。
5. `Makefile` 不需要新增 framework 或 `-l` 参数：`dlopen/dlsym` 属于 iOS 的 `libSystem`，`CoreGraphics/UIKit` 已在现有 frameworks 中。

## 5. 如何验证引擎是否生效

1. `GET /api/vision/engines` 看目标引擎 `available` 是否为 `true`。`false` 时按第 3 节检查库与模型是否放对目录。
2. `POST /api/vision/engine {"id":"onnx"}` 后 `GET /api/vision/engine`，确认 `effectiveId` 为 `onnx`；若变成别的 id，说明该引擎不可用并已自动降级。
3. 调用 `GET /api/vision/ocr?expect=...` 或 `/api/vision/template?template=...&threshold=0.9`，返回的 `result` 里带引擎特有字段即为对应引擎在工作：
   - onnx OCR 返回 CTC 解码文本；onnx 检测返回检测框坐标/分数。
   - ncnn 返回桥接 JSON 解析出的 `label` 文本与框。
   - tesseract 返回 `texts` 按行切分，`boxes` 为空数组。
   - builtin OCR 返回 Apple Vision 的 `boxes`（含 `confidence`），NCC 返回 `score`/`w`/`h`。
4. 日志过滤 `[XAutouch]`：加载成功会打印 `ONNX Runtime 加载成功` / `ncnn 加载成功` / `Tesseract 符号解析完成`；降级会打印 `返回 error，降级`。
5. 删除某个 `.dylib` 或模型文件后重启 SpringBoard，重复步骤 1，应看到 `available:false` 且 `effectiveId` 自动切到下一引擎，接口仍返回正常结构而非崩溃。

## 6. 调用链路

```
XTRoutes (/api/vision/*)
  → XTVision findTemplate/ocrWithExpect
    → XTVisionEngineRegistry findTemplate/ocrExpect  (@try/@catch + 降级)
      → activeEngine (用户选择优先 → 优先级顺序 → nil)
        → XTONNXEngine / XTNCNNEngine / XTTesseractEngine  (dlsym + 模型探测)
      → 返回 nil 时
    → XTVision 内置 NCC / Apple Vision
```
