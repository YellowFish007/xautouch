/**
 * XTONNXEngine.mm - ONNX Runtime 适配器（dlsym 运行时加载）
 *
 * 关键实现点：
 *   1. dlopen libonnxruntime.1.17.3.dylib，dlsym 得到 OrtGetApiBase，
 *      再取 OrtApi(ORT_API_VERSION=17) 函数表；
 *   2. XTOrtApi 结构是 onnxruntime v1.17.3 onnxruntime_c_api.h 中 OrtApi 的
 *      前 101 项 ABI 精确副本（成员顺序/签名逐项一致），因此无需 import Ort 头文件；
 *   3. 用 OrtApi 的 CreateSession / Run 真正执行推理，不走空实现；
 *   4. 库、模型、字符集任一缺失时 available=NO，所有公开方法返回带 error 的字典。
 *
 * 约定：
 *   detect.onnx 输出最后一维为每条检测框 [x1,y1,x2,y2,score,class]（归一化或像素坐标）；
 *   ocr.onnx 输出为 CTC 结构 [N,T,C]，字符集默认 ASCII，可由 ocr_chars.txt 覆盖。
 */
#import "XTONNXEngine.h"
#import "XTApplication.h"
#import "XTCapture.h"
#import "XTLogger.h"
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

#pragma mark - ONNX Runtime C ABI（v1.17.3，最小值集）

#define ORT_API_VERSION_X 17
#define ORT_API_CALL
typedef char XTOrtChar;

typedef struct OrtEnv OrtEnv;
typedef struct OrtStatus OrtStatus;
typedef struct OrtMemoryInfo OrtMemoryInfo;
typedef struct OrtValue OrtValue;
typedef struct OrtSession OrtSession;
typedef struct OrtRunOptions OrtRunOptions;
typedef struct OrtTypeInfo OrtTypeInfo;
typedef struct OrtTensorTypeAndShapeInfo OrtTensorTypeAndShapeInfo;
typedef struct OrtSessionOptions OrtSessionOptions;
typedef struct OrtAllocator OrtAllocator;
struct OrtAllocator {
    uint32_t version;
    void* (ORT_API_CALL* Alloc)(struct OrtAllocator* this_, size_t size);
    void (ORT_API_CALL* Free)(struct OrtAllocator* this_, void* p);
    const struct OrtMemoryInfo* (ORT_API_CALL* Info)(const struct OrtAllocator* this_);
};
typedef struct OrtKernelInfo OrtKernelInfo;
typedef struct OrtKernelContext OrtKernelContext;
typedef struct OrtCustomOp OrtCustomOp;
typedef struct OrtCustomOpDomain OrtCustomOpDomain;

typedef enum OrtLoggingLevel {
    ORT_LOGGING_LEVEL_VERBOSE, ORT_LOGGING_LEVEL_INFO, ORT_LOGGING_LEVEL_WARNING,
    ORT_LOGGING_LEVEL_ERROR, ORT_LOGGING_LEVEL_FATAL
} OrtLoggingLevel;

typedef enum OrtErrorCode {
    ORT_OK, ORT_FAIL, ORT_INVALID_ARGUMENT, ORT_NO_SUCHFILE, ORT_NO_MODEL,
    ORT_ENGINE_ERROR, ORT_RUNTIME_EXCEPTION, ORT_INVALID_PROTOBUF, ORT_MODEL_LOADED,
    ORT_NOT_IMPLEMENTED, ORT_INVALID_GRAPH, ORT_EP_FAIL
} OrtErrorCode;

typedef enum ExecutionMode { ORT_SEQUENTIAL = 0, ORT_PARALLEL = 1 } ExecutionMode;
typedef enum GraphOptimizationLevel {
    ORT_DISABLE_ALL = 0, ORT_ENABLE_BASIC = 1, ORT_ENABLE_EXTENDED = 2, ORT_ENABLE_ALL = 99
} GraphOptimizationLevel;

typedef enum ONNXTensorElementDataType {
    ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT16,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT16,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_STRING,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT32,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT64,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_COMPLEX64,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_COMPLEX128,
    ONNX_TENSOR_ELEMENT_DATA_TYPE_BFLOAT16
} ONNXTensorElementDataType;

typedef enum ONNXType {
    ONNX_TYPE_UNKNOWN, ONNX_TYPE_TENSOR, ONNX_TYPE_SEQUENCE, ONNX_TYPE_MAP,
    ONNX_TYPE_OPAQUE, ONNX_TYPE_SPARSETENSOR, ONNX_TYPE_OPTIONAL
} ONNXType;

typedef enum OrtAllocatorType {
    OrtInvalidAllocator = -1, OrtDeviceAllocator = 0, OrtArenaAllocator = 1
} OrtAllocatorType;

typedef enum OrtMemType {
    OrtMemTypeCPUInput = -2, OrtMemTypeCPUOutput = -1,
    OrtMemTypeCPU = OrtMemTypeCPUOutput, OrtMemTypeDefault = 0
} OrtMemType;

typedef void (ORT_API_CALL *OrtLoggingFunction)(void *param, OrtLoggingLevel severity,
                                                const char *category, const char *logid,
                                                const char *code_location, const char *message);

/// 与 v1.17.3 官方 onnxruntime_c_api.h 中 struct OrtApi 的前 101 项逐项一致
struct XTOrtApi {
    OrtStatus*(ORT_API_CALL* CreateStatus)(OrtErrorCode code, const char* msg);
    OrtErrorCode(ORT_API_CALL* GetErrorCode)(const OrtStatus* status);
    const char*(ORT_API_CALL* GetErrorMessage)(const OrtStatus* status);
    OrtStatus* (ORT_API_CALL* CreateEnv)(OrtLoggingLevel log_severity_level, const char* logid, OrtEnv** out);
    OrtStatus* (ORT_API_CALL* CreateEnvWithCustomLogger)(OrtLoggingFunction logging_function, void* logger_param, OrtLoggingLevel log_severity_level, const char* logid, OrtEnv** out);
    OrtStatus* (ORT_API_CALL* EnableTelemetryEvents)(const OrtEnv* env);
    OrtStatus* (ORT_API_CALL* DisableTelemetryEvents)(const OrtEnv* env);
    OrtStatus* (ORT_API_CALL* CreateSession)(const OrtEnv* env, const XTOrtChar* model_path, const OrtSessionOptions* options, OrtSession** out);
    OrtStatus* (ORT_API_CALL* CreateSessionFromArray)(const OrtEnv* env, const void* model_data, size_t model_data_length, const OrtSessionOptions* options, OrtSession** out);
    OrtStatus* (ORT_API_CALL* Run)(OrtSession* session, const OrtRunOptions* run_options, const char* const* input_names, const OrtValue* const* inputs, size_t input_len, const char* const* output_names, size_t output_names_len, OrtValue** outputs);
    OrtStatus* (ORT_API_CALL* CreateSessionOptions)(OrtSessionOptions** options);
    OrtStatus* (ORT_API_CALL* SetOptimizedModelFilePath)(OrtSessionOptions* options, const XTOrtChar* optimized_model_filepath);
    OrtStatus* (ORT_API_CALL* CloneSessionOptions)(const OrtSessionOptions* in_options, OrtSessionOptions** out_options);
    OrtStatus* (ORT_API_CALL* SetSessionExecutionMode)(OrtSessionOptions* options, ExecutionMode execution_mode);
    OrtStatus* (ORT_API_CALL* EnableProfiling)(OrtSessionOptions* options, const XTOrtChar* profile_file_prefix);
    OrtStatus* (ORT_API_CALL* DisableProfiling)(OrtSessionOptions* options);
    OrtStatus* (ORT_API_CALL* EnableMemPattern)(OrtSessionOptions* options);
    OrtStatus* (ORT_API_CALL* DisableMemPattern)(OrtSessionOptions* options);
    OrtStatus* (ORT_API_CALL* EnableCpuMemArena)(OrtSessionOptions* options);
    OrtStatus* (ORT_API_CALL* DisableCpuMemArena)(OrtSessionOptions* options);
    OrtStatus* (ORT_API_CALL* SetSessionLogId)(OrtSessionOptions* options, const char* logid);
    OrtStatus* (ORT_API_CALL* SetSessionLogVerbosityLevel)(OrtSessionOptions* options, int session_log_verbosity_level);
    OrtStatus* (ORT_API_CALL* SetSessionLogSeverityLevel)(OrtSessionOptions* options, int session_log_severity_level);
    OrtStatus* (ORT_API_CALL* SetSessionGraphOptimizationLevel)(OrtSessionOptions* options, GraphOptimizationLevel graph_optimization_level);
    OrtStatus* (ORT_API_CALL* SetIntraOpNumThreads)(OrtSessionOptions* options, int intra_op_num_threads);
    OrtStatus* (ORT_API_CALL* SetInterOpNumThreads)(OrtSessionOptions* options, int inter_op_num_threads);
    OrtStatus* (ORT_API_CALL* CreateCustomOpDomain)(const char* domain, OrtCustomOpDomain** out);
    OrtStatus* (ORT_API_CALL* CustomOpDomain_Add)(OrtCustomOpDomain* custom_op_domain, const OrtCustomOp* op);
    OrtStatus* (ORT_API_CALL* AddCustomOpDomain)(OrtSessionOptions* options, OrtCustomOpDomain* custom_op_domain);
    OrtStatus* (ORT_API_CALL* RegisterCustomOpsLibrary)(OrtSessionOptions* options, const char* library_path, void** library_handle);
    OrtStatus* (ORT_API_CALL* SessionGetInputCount)(const OrtSession* session, size_t* out);
    OrtStatus* (ORT_API_CALL* SessionGetOutputCount)(const OrtSession* session, size_t* out);
    OrtStatus* (ORT_API_CALL* SessionGetOverridableInitializerCount)(const OrtSession* session, size_t* out);
    OrtStatus* (ORT_API_CALL* SessionGetInputTypeInfo)(const OrtSession* session, size_t index, OrtTypeInfo** type_info);
    OrtStatus* (ORT_API_CALL* SessionGetOutputTypeInfo)(const OrtSession* session, size_t index, OrtTypeInfo** type_info);
    OrtStatus* (ORT_API_CALL* SessionGetOverridableInitializerTypeInfo)(const OrtSession* session, size_t index, OrtTypeInfo** type_info);
    OrtStatus* (ORT_API_CALL* SessionGetInputName)(const OrtSession* session, size_t index, OrtAllocator* allocator, char** value);
    OrtStatus* (ORT_API_CALL* SessionGetOutputName)(const OrtSession* session, size_t index, OrtAllocator* allocator, char** value);
    OrtStatus* (ORT_API_CALL* SessionGetOverridableInitializerName)(const OrtSession* session, size_t index, OrtAllocator* allocator, char** value);
    OrtStatus* (ORT_API_CALL* CreateRunOptions)(OrtRunOptions** out);
    OrtStatus* (ORT_API_CALL* RunOptionsSetRunLogVerbosityLevel)(OrtRunOptions* options, int log_verbosity_level);
    OrtStatus* (ORT_API_CALL* RunOptionsSetRunLogSeverityLevel)(OrtRunOptions* options, int log_severity_level);
    OrtStatus* (ORT_API_CALL* RunOptionsSetRunTag)(OrtRunOptions* options, const char* run_tag);
    OrtStatus* (ORT_API_CALL* RunOptionsGetRunLogVerbosityLevel)(const OrtRunOptions* options, int* log_verbosity_level);
    OrtStatus* (ORT_API_CALL* RunOptionsGetRunLogSeverityLevel)(const OrtRunOptions* options, int* log_severity_level);
    OrtStatus* (ORT_API_CALL* RunOptionsGetRunTag)(const OrtRunOptions* options, const char** run_tag);
    OrtStatus* (ORT_API_CALL* RunOptionsSetTerminate)(OrtRunOptions* options);
    OrtStatus* (ORT_API_CALL* RunOptionsUnsetTerminate)(OrtRunOptions* options);
    OrtStatus* (ORT_API_CALL* CreateTensorAsOrtValue)(OrtAllocator* allocator, const int64_t* shape, size_t shape_len, ONNXTensorElementDataType type, OrtValue** out);
    OrtStatus* (ORT_API_CALL* CreateTensorWithDataAsOrtValue)(const OrtMemoryInfo* info, void* p_data, size_t p_data_len, const int64_t* shape, size_t shape_len, ONNXTensorElementDataType type, OrtValue** out);
    OrtStatus* (ORT_API_CALL* IsTensor)(const OrtValue* value, int* out);
    OrtStatus* (ORT_API_CALL* GetTensorMutableData)(OrtValue* value, void** out);
    OrtStatus* (ORT_API_CALL* FillStringTensor)(OrtValue* value, const char* const* s, size_t s_len);
    OrtStatus* (ORT_API_CALL* GetStringTensorDataLength)(const OrtValue* value, size_t* len);
    OrtStatus* (ORT_API_CALL* GetStringTensorContent)(const OrtValue* value, void* s, size_t s_len, size_t* offsets, size_t offsets_len);
    OrtStatus* (ORT_API_CALL* CastTypeInfoToTensorInfo)(const OrtTypeInfo* type_info, const OrtTensorTypeAndShapeInfo** out);
    OrtStatus* (ORT_API_CALL* GetOnnxTypeFromTypeInfo)(const OrtTypeInfo* type_info, enum ONNXType* out);
    OrtStatus* (ORT_API_CALL* CreateTensorTypeAndShapeInfo)(OrtTensorTypeAndShapeInfo** out);
    OrtStatus* (ORT_API_CALL* SetTensorElementType)(OrtTensorTypeAndShapeInfo* info, enum ONNXTensorElementDataType type);
    OrtStatus* (ORT_API_CALL* SetDimensions)(OrtTensorTypeAndShapeInfo* info, const int64_t* dim_values, size_t dim_count);
    OrtStatus* (ORT_API_CALL* GetTensorElementType)(const OrtTensorTypeAndShapeInfo* info, enum ONNXTensorElementDataType* out);
    OrtStatus* (ORT_API_CALL* GetDimensionsCount)(const OrtTensorTypeAndShapeInfo* info, size_t* out);
    OrtStatus* (ORT_API_CALL* GetDimensions)(const OrtTensorTypeAndShapeInfo* info, int64_t* dim_values, size_t dim_values_length);
    OrtStatus* (ORT_API_CALL* GetSymbolicDimensions)(const OrtTensorTypeAndShapeInfo* info, const char* dim_params[], size_t dim_params_length);
    OrtStatus* (ORT_API_CALL* GetTensorShapeElementCount)(const OrtTensorTypeAndShapeInfo* info, size_t* out);
    OrtStatus* (ORT_API_CALL* GetTensorTypeAndShape)(const OrtValue* value, OrtTensorTypeAndShapeInfo** out);
    OrtStatus* (ORT_API_CALL* GetTypeInfo)(const OrtValue* value, OrtTypeInfo** out);
    OrtStatus* (ORT_API_CALL* GetValueType)(const OrtValue* value, enum ONNXType* out);
    OrtStatus* (ORT_API_CALL* CreateMemoryInfo)(const char* name, enum OrtAllocatorType type, int id, enum OrtMemType mem_type, OrtMemoryInfo** out);
    OrtStatus* (ORT_API_CALL* CreateCpuMemoryInfo)(enum OrtAllocatorType type, enum OrtMemType mem_type, OrtMemoryInfo** out);
    OrtStatus* (ORT_API_CALL* CompareMemoryInfo)(const OrtMemoryInfo* info1, const OrtMemoryInfo* info2, int* out);
    OrtStatus* (ORT_API_CALL* MemoryInfoGetName)(const OrtMemoryInfo* ptr, const char** out);
    OrtStatus* (ORT_API_CALL* MemoryInfoGetId)(const OrtMemoryInfo* ptr, int* out);
    OrtStatus* (ORT_API_CALL* MemoryInfoGetMemType)(const OrtMemoryInfo* ptr, OrtMemType* out);
    OrtStatus* (ORT_API_CALL* MemoryInfoGetType)(const OrtMemoryInfo* ptr, OrtAllocatorType* out);
    OrtStatus* (ORT_API_CALL* AllocatorAlloc)(OrtAllocator* ort_allocator, size_t size, void** out);
    OrtStatus* (ORT_API_CALL* AllocatorFree)(OrtAllocator* ort_allocator, void* p);
    OrtStatus* (ORT_API_CALL* AllocatorGetInfo)(const OrtAllocator* ort_allocator, const struct OrtMemoryInfo** out);
    OrtStatus* (ORT_API_CALL* GetAllocatorWithDefaultOptions)(OrtAllocator** out);
    OrtStatus* (ORT_API_CALL* AddFreeDimensionOverride)(OrtSessionOptions* options, const char* dim_denotation, int64_t dim_value);
    OrtStatus* (ORT_API_CALL* GetValue)(const OrtValue* value, int index, OrtAllocator* allocator, OrtValue** out);
    OrtStatus* (ORT_API_CALL* GetValueCount)(const OrtValue* value, size_t* out);
    OrtStatus* (ORT_API_CALL* CreateValue)(const OrtValue* const* in, size_t num_values, enum ONNXType value_type, OrtValue** out);
    OrtStatus* (ORT_API_CALL* CreateOpaqueValue)(const char* domain_name, const char* type_name, const void* data_container, size_t data_container_size, OrtValue** out);
    OrtStatus* (ORT_API_CALL* GetOpaqueValue)(const char* domain_name, const char* type_name, const OrtValue* in, void* data_container, size_t data_container_size);
    OrtStatus* (ORT_API_CALL* KernelInfoGetAttribute_float)(const OrtKernelInfo* info, const char* name, float* out);
    OrtStatus* (ORT_API_CALL* KernelInfoGetAttribute_int64)(const OrtKernelInfo* info, const char* name, int64_t* out);
    OrtStatus* (ORT_API_CALL* KernelInfoGetAttribute_string)(const OrtKernelInfo* info, const char* name, char* out, size_t* size);
    OrtStatus* (ORT_API_CALL* KernelContext_GetInputCount)(const OrtKernelContext* context, size_t* out);
    OrtStatus* (ORT_API_CALL* KernelContext_GetOutputCount)(const OrtKernelContext* context, size_t* out);
    OrtStatus* (ORT_API_CALL* KernelContext_GetInput)(const OrtKernelContext* context, size_t index, const OrtValue** out);
    OrtStatus* (ORT_API_CALL* KernelContext_GetOutput)(OrtKernelContext* context, size_t index, const int64_t* dim_values, size_t dim_count, OrtValue** out);
    void (ORT_API_CALL* ReleaseEnv)(OrtEnv* input);
    void (ORT_API_CALL* ReleaseStatus)(OrtStatus* input);
    void (ORT_API_CALL* ReleaseMemoryInfo)(OrtMemoryInfo* input);
    void (ORT_API_CALL* ReleaseSession)(OrtSession* input);
    void (ORT_API_CALL* ReleaseValue)(OrtValue* input);
    void (ORT_API_CALL* ReleaseRunOptions)(OrtRunOptions* input);
    void (ORT_API_CALL* ReleaseTypeInfo)(OrtTypeInfo* input);
    void (ORT_API_CALL* ReleaseTensorTypeAndShapeInfo)(OrtTensorTypeAndShapeInfo* input);
    void (ORT_API_CALL* ReleaseSessionOptions)(OrtSessionOptions* input);
};
typedef struct XTOrtApi XTOrtApi;

struct XTOrtApiBase {
    const XTOrtApi* (ORT_API_CALL* GetApi)(uint32_t version);
    const char* (ORT_API_CALL* GetVersionString)(void);
};
typedef const struct XTOrtApiBase* (ORT_API_CALL* XTOrtGetApiBaseFn)(void);

#pragma mark - 运行时加载

static void *gORTHandle = NULL;
static const XTOrtApi *gORTApi = NULL;
static NSString *gORTVersion = nil;

static NSString *XTORTModelPath(NSString *file) {
    return [[[XTApplication resourceRoot] stringByAppendingPathComponent:@"models"] stringByAppendingPathComponent:file];
}

static const XTOrtApi *XTEnsureORT(void) {
    @synchronized([XTONNXEngine class]) {
        if (gORTApi) return gORTApi;
        NSString *root = [XTApplication resourceRoot];
        NSString *jb = [[XTApplication sharedInstance] jbRoot];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        void (^add)(NSString *) = ^(NSString *p) {
            if (p.length && ![paths containsObject:p]) [paths addObject:p];
        };
        add([root stringByAppendingPathComponent:@"lib/libonnxruntime.1.17.3.dylib"]);
        if (jb.length) add([jb stringByAppendingPathComponent:@"/usr/lib/libonnxruntime.1.17.3.dylib"]);
        add(@"/usr/lib/libonnxruntime.1.17.3.dylib");
        add(@"/var/jb/usr/lib/libonnxruntime.1.17.3.dylib");
        add(@"libonnxruntime.1.17.3.dylib"); // 交由 dyld 按 DYLD_LIBRARY_PATH 搜索

        for (NSString *path in paths) {
            void *h = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
            if (!h) continue;
            XTOrtGetApiBaseFn getBase = (XTOrtGetApiBaseFn)dlsym(h, "OrtGetApiBase");
            if (!getBase) { dlclose(h); continue; }
            const struct XTOrtApiBase *base = getBase();
            if (!base || !base->GetApi) { dlclose(h); continue; }
            const XTOrtApi *api = base->GetApi(ORT_API_VERSION_X);
            if (!api || !api->CreateSession || !api->Run || !api->ReleaseStatus) { dlclose(h); continue; }
            gORTHandle = h;
            gORTApi = api;
            if (base->GetVersionString) {
                const char *v = base->GetVersionString();
                gORTVersion = v ? [NSString stringWithUTF8String:v] : @"1.17.3";
            }
            XTLog(@"[XAutouch] ONNX Runtime 加载成功: %@ (api v%d)", path, ORT_API_VERSION_X);
            return api;
        }
        return NULL;
    }
}

static NSString *XTORTError(const XTOrtApi *api, OrtStatus *status) {
    if (!status) return nil;
    NSString *msg = nil;
    if (api->GetErrorMessage) {
        const char *c = api->GetErrorMessage(status);
        if (c) msg = [NSString stringWithUTF8String:c];
    }
    if (api->ReleaseStatus) api->ReleaseStatus(status);
    return msg.length ? msg : @"ONNX Runtime error";
}

#pragma mark - 图像 / 张量辅助

static unsigned char *XTResizeGray(CGImageRef cg, NSInteger w, NSInteger h) {
    if (!cg || w <= 0 || h <= 0) return NULL;
    size_t bytesPerRow = (size_t)w * 4;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)w, (size_t)h, 8, bytesPerRow, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
    unsigned char *rgba = (unsigned char *)CGBitmapContextGetData(ctx);
    size_t n = (size_t)w * h;
    unsigned char *gray = (unsigned char *)malloc(n);
    if (gray && rgba) {
        for (size_t i = 0; i < n; i++)
            gray[i] = (unsigned char)((77*rgba[i*4] + 150*rgba[i*4+1] + 29*rgba[i*4+2]) >> 8);
    }
    CGContextRelease(ctx);
    return gray;
}

typedef struct {
    int64_t dims[4];
    size_t dimsCount;
    void *buffer;             // malloc，ORT 不拥有所有权
    size_t bufferBytes;
    OrtValue *value;
    char *inputName;          // 由 OrtAllocator 分配
    char *outputName;         // 由 OrtAllocator 分配
    OrtAllocator *allocator;
} XTORTIO;

typedef struct {
    float *data;              // malloc，调用方释放
    size_t count;
    int64_t dims[4];
    size_t dimsCount;
} XTORTOut;

static void XTORTIORelease(const XTOrtApi *api, XTORTIO *io) {
    if (!io) return;
    if (io->value && api->ReleaseValue) api->ReleaseValue(io->value);
    if (io->allocator) {
        if (io->inputName)  io->allocator->Free(io->allocator, io->inputName);
        if (io->outputName) io->allocator->Free(io->allocator, io->outputName);
    }
    if (io->buffer) free(io->buffer);
    memset(io, 0, sizeof(*io));
}

#pragma mark - 引擎实现

@implementation XTONNXEngine

+ (NSString *)engineId { return @"onnx"; }

- (instancetype)init {
    self = [super init];
    if (self) {
        _ortEnv = NULL; _ortOptions = NULL; _ortMemoryInfo = NULL;
        _ortSessionOCR = NULL; _ortSessionDetect = NULL;
    }
    return self;
}

- (void)dealloc {
    const XTOrtApi *api = gORTApi;
    if (api) {
        if (_ortSessionOCR)    api->ReleaseSession((OrtSession *)_ortSessionOCR);
        if (_ortSessionDetect) api->ReleaseSession((OrtSession *)_ortSessionDetect);
        if (_ortMemoryInfo)    api->ReleaseMemoryInfo((OrtMemoryInfo *)_ortMemoryInfo);
        if (_ortOptions)       api->ReleaseSessionOptions((OrtSessionOptions *)_ortOptions);
        if (_ortEnv)           api->ReleaseEnv((OrtEnv *)_ortEnv);
    }
}

- (NSString *)engineDescription {
    const XTOrtApi *api = XTEnsureORT();
    if (!api) return @"ONNX Runtime（动态库未加载）";
    return [NSString stringWithFormat:@"ONNX Runtime %@ / API v17", gORTVersion ?: @"1.17.3"];
}

- (BOOL)available {
    const XTOrtApi *api = XTEnsureORT();
    if (!api) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL hasOCR = [fm fileExistsAtPath:XTORTModelPath(@"ocr.onnx")];
    BOOL hasDet = [fm fileExistsAtPath:XTORTModelPath(@"detect.onnx")];
    return hasOCR || hasDet;
}

/// 创建全局 OrtEnv / SessionOptions / CPU MemoryInfo（一次）
- (BOOL)ensureContextWithAPI:(const XTOrtApi *)api error:(NSString **)errOut {
    if (_ortEnv && _ortOptions && _ortMemoryInfo) return YES;

    OrtEnv *env = NULL;
    OrtStatus *st = api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "xautouch", &env);
    if (st || !env) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"CreateEnv failed";
        if (!st && env) api->ReleaseEnv(env);
        return NO;
    }
    _ortEnv = env;

    OrtSessionOptions *opts = NULL;
    st = api->CreateSessionOptions(&opts);
    if (st || !opts) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"CreateSessionOptions failed";
        if (!st && opts) api->ReleaseSessionOptions(opts);
        api->ReleaseEnv(env); _ortEnv = NULL;
        return NO;
    }
    api->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_BASIC);
    api->SetIntraOpNumThreads(opts, 1); // 后台插件限制线程，避免抢主线程
    _ortOptions = opts;

    OrtMemoryInfo *mi = NULL;
    st = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mi);
    if (st || !mi) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"CreateCpuMemoryInfo failed";
        if (!st && mi) api->ReleaseMemoryInfo(mi);
        api->ReleaseSessionOptions(opts); _ortOptions = NULL;
        api->ReleaseEnv(env); _ortEnv = NULL;
        return NO;
    }
    _ortMemoryInfo = mi;
    return YES;
}

/// 对应 ORT 的 OrtSessionCreate：从模型文件创建并缓存 session
- (OrtSession *)sessionForModelFile:(NSString *)file api:(const XTOrtApi *)api error:(NSString **)errOut {
    void **slot = [file isEqualToString:@"ocr.onnx"] ? &_ortSessionOCR : &_ortSessionDetect;
    if (*slot) return (OrtSession *)*slot;

    NSString *path = XTORTModelPath(file);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (errOut) *errOut = [NSString stringWithFormat:@"model missing: %@", path];
        return NULL;
    }
    OrtSession *session = NULL;
    OrtStatus *st = api->CreateSession((OrtEnv *)_ortEnv, path.UTF8String,
                                       (OrtSessionOptions *)_ortOptions, &session);
    if (st || !session) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"CreateSession failed";
        if (!st && session) api->ReleaseSession(session);
        return NULL;
    }
    *slot = session;
    XTLog(@"[XAutouch] ONNX 会话已创建: %@", file);
    return session;
}

/// 按模型输入信息构建 NCHW/CHW/HW 张量
- (BOOL)buildInputForSession:(OrtSession *)session
                         api:(const XTOrtApi *)api
                       image:(UIImage *)image
                          io:(XTORTIO *)io
                       error:(NSString **)errOut {
    memset(io, 0, sizeof(*io));
    OrtAllocator *alloc = NULL;
    OrtStatus *st = api->GetAllocatorWithDefaultOptions(&alloc);
    if (st || !alloc) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"GetAllocatorWithDefaultOptions failed";
        return NO;
    }
    io->allocator = alloc;

    size_t inCount = 0;
    st = api->SessionGetInputCount(session, &inCount);
    if (st || inCount < 1) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"model has no input";
        XTORTIORelease(api, io);
        return NO;
    }
    st = api->SessionGetInputName(session, 0, alloc, &io->inputName);
    if (st || !io->inputName) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"SessionGetInputName failed";
        XTORTIORelease(api, io);
        return NO;
    }

    OrtTypeInfo *ti = NULL;
    st = api->SessionGetInputTypeInfo(session, 0, &ti);
    if (st || !ti) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"SessionGetInputTypeInfo failed";
        XTORTIORelease(api, io);
        return NO;
    }
    const OrtTensorTypeAndShapeInfo *tsi = NULL;
    st = api->CastTypeInfoToTensorInfo(ti, &tsi);
    if (st || !tsi) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"CastTypeInfoToTensorInfo failed";
        api->ReleaseTypeInfo(ti);
        XTORTIORelease(api, io);
        return NO;
    }
    size_t rawCount = 0;
    api->GetDimensionsCount(tsi, &rawCount);
    if (rawCount > 4) rawCount = 4;
    int64_t raw[4] = {0, 0, 0, 0};
    if (rawCount) api->GetDimensions(tsi, raw, rawCount);
    ONNXTensorElementDataType et = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
    api->GetTensorElementType(tsi, &et);
    // tsi 由 ti 持有，释放 ti 即失效，不可单独 Release
    api->ReleaseTypeInfo(ti);

    if (et != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT && et != ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8) {
        if (errOut) *errOut = @"unsupported input element type (only float/uint8)";
        XTORTIORelease(api, io);
        return NO;
    }

    NSInteger imgW = (NSInteger)CGImageGetWidth(image.CGImage);
    NSInteger imgH = (NSInteger)CGImageGetHeight(image.CGImage);
    int64_t N = 1, C = 1, H = imgH, W = imgW;
    if (rawCount == 4) {
        N = raw[0] > 0 ? raw[0] : 1; C = raw[1] > 0 ? raw[1] : 1;
        H = raw[2] > 0 ? raw[2] : imgH; W = raw[3] > 0 ? raw[3] : imgW;
    } else if (rawCount == 3) {
        C = raw[0] > 0 ? raw[0] : 1; H = raw[1] > 0 ? raw[1] : imgH; W = raw[2] > 0 ? raw[2] : imgW;
        N = 1;
    } else if (rawCount == 2) {
        H = raw[0] > 0 ? raw[0] : imgH; W = raw[1] > 0 ? raw[1] : imgW;
        N = 1; C = 1;
    }
    if (W <= 0 || H <= 0 || W > 4096 || H > 4096 || C > 4 || N > 8) {
        if (errOut) *errOut = @"invalid model input shape";
        XTORTIORelease(api, io);
        return NO;
    }

    if (rawCount == 4) { io->dims[0]=N; io->dims[1]=C; io->dims[2]=H; io->dims[3]=W; io->dimsCount=4; }
    else if (rawCount == 3) { io->dims[0]=C; io->dims[1]=H; io->dims[2]=W; io->dimsCount=3; }
    else { io->dims[0]=H; io->dims[1]=W; io->dimsCount=2; }

    size_t plane = (size_t)H * (size_t)W;
    size_t total = plane * (size_t)C * (size_t)N;
    BOOL isFloat = (et == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT);
    io->bufferBytes = total * (isFloat ? sizeof(float) : 1);
    io->buffer = calloc(total, isFloat ? sizeof(float) : 1);
    if (!io->buffer) {
        if (errOut) *errOut = @"input buffer allocation failed";
        XTORTIORelease(api, io);
        return NO;
    }
    unsigned char *gray = XTResizeGray(image.CGImage, W, H);
    if (!gray) {
        if (errOut) *errOut = @"image decode failed";
        XTORTIORelease(api, io);
        return NO;
    }
    for (size_t n = 0; n < (size_t)N; n++) {
        for (size_t c = 0; c < (size_t)C; c++) {
            size_t base = (n * (size_t)C + c) * plane;
            for (size_t p = 0; p < plane; p++) {
                if (isFloat) ((float *)io->buffer)[base + p] = gray[p] / 255.0f;
                else ((unsigned char *)io->buffer)[base + p] = gray[p];
            }
        }
    }
    free(gray);

    st = api->CreateTensorWithDataAsOrtValue((OrtMemoryInfo *)_ortMemoryInfo,
                                             io->buffer, io->bufferBytes,
                                             io->dims, io->dimsCount, et, &io->value);
    if (st || !io->value) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"CreateTensorWithDataAsOrtValue failed";
        XTORTIORelease(api, io);
        return NO;
    }

    size_t outCount = 0;
    st = api->SessionGetOutputCount(session, &outCount);
    if (st || outCount < 1) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"model has no output";
        XTORTIORelease(api, io);
        return NO;
    }
    st = api->SessionGetOutputName(session, 0, alloc, &io->outputName);
    if (st || !io->outputName) {
        if (errOut) *errOut = XTORTError(api, st) ?: @"SessionGetOutputName failed";
        XTORTIORelease(api, io);
        return NO;
    }
    return YES;
}

/// 真正执行 OrtApi::Run，并把第一路输出拷成 float 数组
- (BOOL)runModelFile:(NSString *)file
               image:(UIImage *)image
                out:(XTORTOut *)out
               error:(NSString **)errOut {
    memset(out, 0, sizeof(*out));
    const XTOrtApi *api = XTEnsureORT();
    if (!api) { if (errOut) *errOut = @"ONNX Runtime not loaded"; return NO; }
    @synchronized(self) {
        NSString *ctxErr = nil;
        if (![self ensureContextWithAPI:api error:&ctxErr]) {
            if (errOut) *errOut = ctxErr;
            return NO;
        }
        OrtSession *session = [self sessionForModelFile:file api:api error:errOut];
        if (!session) return NO;

        XTORTIO io;
        if (![self buildInputForSession:session api:api image:image io:&io error:errOut]) return NO;

        const char *const inNames[]  = { io.inputName };
        const OrtValue *const inVals[] = { io.value };
        const char *const outNames[] = { io.outputName };
        OrtValue *outValue = NULL;
        // OrtRun：同步执行，run_options 传 NULL 使用默认配置
        OrtStatus *st = api->Run(session, NULL, inNames, inVals, 1, outNames, 1, &outValue);
        if (st || !outValue) {
            if (errOut) *errOut = XTORTError(api, st) ?: @"OrtRun failed";
            if (outValue) api->ReleaseValue(outValue);
            XTORTIORelease(api, &io);
            return NO;
        }
        XTORTIORelease(api, &io);

        void *raw = NULL;
        st = api->GetTensorMutableData(outValue, &raw);
        if (st || !raw) {
            if (errOut) *errOut = XTORTError(api, st) ?: @"GetTensorMutableData failed";
            api->ReleaseValue(outValue);
            return NO;
        }
        OrtTensorTypeAndShapeInfo *osi = NULL;
        st = api->GetTensorTypeAndShape(outValue, &osi);
        if (st || !osi) {
            if (errOut) *errOut = XTORTError(api, st) ?: @"GetTensorTypeAndShape failed";
            api->ReleaseValue(outValue);
            return NO;
        }
        size_t dc = 0;
        api->GetDimensionsCount(osi, &dc);
        if (dc > 4) dc = 4;
        int64_t dims[4] = {0, 0, 0, 0};
        if (dc) api->GetDimensions(osi, dims, dc);
        ONNXTensorElementDataType oet = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
        api->GetTensorElementType(osi, &oet);
        size_t count = 1;
        for (size_t i = 0; i < dc; i++) count *= (size_t)MAX(1, (int)dims[i]);
        api->ReleaseTensorTypeAndShapeInfo(osi);

        out->data = (float *)malloc(count * sizeof(float));
        if (!out->data) {
            if (errOut) *errOut = @"output buffer allocation failed";
            api->ReleaseValue(outValue);
            return NO;
        }
        if (oet == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
            memcpy(out->data, raw, count * sizeof(float));
        } else if (oet == ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8) {
            unsigned char *b = (unsigned char *)raw;
            for (size_t i = 0; i < count; i++) out->data[i] = b[i] / 255.0f;
        } else if (oet == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
            int64_t *b = (int64_t *)raw;
            for (size_t i = 0; i < count; i++) out->data[i] = (float)b[i];
        } else {
            if (errOut) *errOut = @"unsupported output element type";
            free(out->data); out->data = NULL;
            api->ReleaseValue(outValue);
            return NO;
        }
        out->count = count;
        out->dimsCount = dc;
        for (size_t i = 0; i < dc; i++) out->dims[i] = dims[i];
        api->ReleaseValue(outValue);
        return YES;
    }
}

#pragma mark - 协议方法

- (NSDictionary *)findTemplate:(NSString *)name threshold:(double)threshold {
    if (!name.length) return @{@"error":@"empty template"};
    NSString *shot = [[XTCapture sharedInstance] captureScreen];
    UIImage *img = shot ? [UIImage imageWithContentsOfFile:shot] : nil;
    if (!img || !img.CGImage) return @{@"error":@"capture failed"};

    XTORTOut out;
    NSString *err = nil;
    if (![self runModelFile:@"detect.onnx" image:img out:&out error:&err])
        return @{@"error":err ?: @"onnx detect failed"};

    // 输出约定：最后一维为 [x1,y1,x2,y2,score,class]
    NSUInteger stride = out.dimsCount ? (NSUInteger)MAX(1, (int)out.dims[out.dimsCount-1]) : 6;
    if (stride < 6 || out.count < 6) {
        free(out.data);
        return @{@"error":@"unexpected detect output layout"};
    }

    // 可选类别标签过滤：detect_labels.txt 中若含 name，则只取对应类别
    NSInteger wantClass = -1;
    NSString *labelPath = XTORTModelPath(@"detect_labels.txt");
    NSString *labelsText = [NSString stringWithContentsOfFile:labelPath encoding:NSUTF8StringEncoding error:nil];
    if (labelsText.length) {
        NSArray *lines = [labelsText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSUInteger i = 0; i < lines.count; i++) {
            if ([[lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:name]) {
                wantClass = (NSInteger)i; break;
            }
        }
    }

    double best = -1;
    int bestIdx = -1;
    NSUInteger rows = out.count / stride;
    for (NSUInteger r = 0; r < rows; r++) {
        const float *row = out.data + r * stride;
        double score = row[4];
        if (wantClass >= 0 && (NSInteger)row[5] != wantClass) continue;
        if (score > best) { best = score; bestIdx = (int)r; }
    }
    if (bestIdx < 0) { free(out.data); return @{@"error":@"no candidate class matched"}; }

    const float *box = out.data + bestIdx * stride;
    CGFloat W = (CGFloat)CGImageGetWidth(img.CGImage);
    CGFloat H = (CGFloat)CGImageGetHeight(img.CGImage);
    // 坐标若为 0..1 归一化则乘回像素； >1 视为已是像素坐标
    CGFloat sx = box[0] <= 1.0f ? W : 1.0f;
    CGFloat sy = box[1] <= 1.0f ? H : 1.0f;
    CGFloat x = box[0] * sx, y = box[1] * sy;
    CGFloat w = (box[2] - box[0]) * sx, h = (box[3] - box[1]) * sy;
    BOOL found = best >= threshold;
    free(out.data);
    XTLog(@"[XAutouch] ONNX detect %@ score=%.4f -> %@", name, best, found ? @"hit" : @"miss");
    return @{@"found":@(found), @"x":@(x), @"y":@(y), @"score":@(best),
             @"w":@(w), @"h":@(h), @"template":name};
}

- (NSDictionary *)ocrExpect:(NSString *)expect {
    NSString *shot = [[XTCapture sharedInstance] captureScreen];
    UIImage *img = shot ? [UIImage imageWithContentsOfFile:shot] : nil;
    if (!img || !img.CGImage) return @{@"error":@"capture failed"};

    XTORTOut out;
    NSString *err = nil;
    if (![self runModelFile:@"ocr.onnx" image:img out:&out error:&err])
        return @{@"error":err ?: @"onnx ocr failed"};

    // CTC 字符集：charset[0] 为 blank，可由 ocr_chars.txt 覆盖
    NSString *charsetPath = XTORTModelPath(@"ocr_chars.txt");
    NSString *custom = [NSString stringWithContentsOfFile:charsetPath encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray<NSString *> *chars = [NSMutableArray arrayWithObject:@""]; // index 0 = blank
    if (custom.length) {
        for (NSString *line in [custom componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            if (line.length) [chars addObject:line];
        }
    } else {
        const char *ascii = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ ";
        for (const char *p = ascii; *p; p++) [chars addObject:[NSString stringWithFormat:@"%c", *p]];
    }

    // 输出 [N,T,C] 或 [T,C]：倒数第二维为时间步，最后一维为类别数
    NSUInteger classes = out.dimsCount >= 1 ? (NSUInteger)MAX(1, (int)out.dims[out.dimsCount-1]) : 0;
    NSUInteger steps = out.dimsCount >= 2 ? (NSUInteger)MAX(1, (int)out.dims[out.dimsCount-2]) : 0;
    if (classes < 2 || steps < 1 || classes > chars.count) {
        free(out.data);
        return @{@"error":@"unexpected ocr output layout / charset size mismatch"};
    }

    NSMutableString *text = [NSMutableString string];
    NSUInteger prev = NSNotFound;
    for (NSUInteger t = 0; t < steps; t++) {
        const float *row = out.data + t * classes;
        NSUInteger best = 0;
        float bv = -1e30f;
        for (NSUInteger c = 0; c < classes && c < chars.count; c++) {
            if (row[c] > bv) { bv = row[c]; best = c; }
        }
        if (best != 0 && best != prev) [text appendString:chars[best]];
        prev = best;
    }
    free(out.data);

    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *texts = trimmed.length ? @[trimmed] : @[];
    BOOL matched = NO;
    if (expect.length) {
        for (NSString *t in texts) {
            if ([t isEqualToString:expect] || [t containsString:expect]) { matched = YES; break; }
        }
    } else matched = texts.count > 0;

    XTLog(@"[XAutouch] ONNX OCR '%@' -> %@", trimmed, matched ? @"hit" : @"miss");
    return @{@"matched":@(matched), @"texts":texts, @"boxes":@[],
             @"expect":expect ?: @"", @"count":@(texts.count)};
}

@end
