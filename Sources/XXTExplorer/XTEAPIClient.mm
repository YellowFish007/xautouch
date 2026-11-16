/**
 * XTEAPIClient.mm - 本地 HTTP API 封装实现
 *
 * 底层统一走 requestPath:method:params:body:completion:：
 * 1) GET 参数做严格百分号编码（服务端用朴素的 '=' / '&' 切分，必须避免字面量冲突）；
 * 2) POST 用 JSON body（服务端 jsonObject 解析，可安全承载换行、等号等脚本文本）；
 * 3) 解析 JSON 并检查 code 字段，非 0 转成 NSError；
 * 4) 所有回调切回主线程。
 */
#import "XTEAPIClient.h"

NSString *const XTEAPIErrorDomain = @"XTEAPIErrorDomain";

static NSString *const kXTEBaseURL = @"http://127.0.0.1:46899";
static NSString *const kXTEFallbackRoot = @"/var/jb/usr/lib/xautouch";

static NSError *XTEMakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:XTEAPIErrorDomain
                              code:code
                          userInfo:@{NSLocalizedDescriptionKey: message ?: @"未知错误"}];
}

/// 只保留 unreserved 字符，其余（含 / = & + 空格与中文）全部转义
static NSString *XTEPercentEncode(NSString *value) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

@interface XTEAPIClient ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation XTEAPIClient

+ (instancetype)sharedClient {
    static XTEAPIClient *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

+ (NSString *)defaultResourceRoot {
    return kXTEFallbackRoot;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 8.0;
        configuration.timeoutIntervalForResource = 15.0;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

#pragma mark - 底层请求

- (NSURLRequest *)requestWithPath:(NSString *)path
                           method:(NSString *)method
                           params:(NSDictionary *)params
                             body:(NSDictionary *)body {
    NSMutableString *urlString = [NSMutableString stringWithString:kXTEBaseURL];
    [urlString appendString:path ?: @"/"];

    if (params.count) {
        NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:params.count];
        [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            [pairs addObject:[NSString stringWithFormat:@"%@=%@",
                              XTEPercentEncode(key), XTEPercentEncode(value ?: @"")]];
        }];
        [urlString appendFormat:@"?%@", [pairs componentsJoinedByString:@"&"]];
    }

    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = method ?: @"GET";
    if (body) {
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    return request;
}

- (void)requestPath:(NSString *)path
             method:(NSString *)method
             params:(NSDictionary *)params
               body:(NSDictionary *)body
         completion:(void (^)(NSDictionary *json, NSError *error))completion {
    NSURLRequest *request = [self requestWithPath:path method:method params:params body:body];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(nil, XTEMakeError(-9, @"API 客户端已释放"));
                });
                return;
            }

            NSDictionary *json = nil;
            NSError *resultError = nil;
            if (error) {
                resultError = error;
            } else {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                NSInteger status = http.statusCode;
                if (status < 200 || status >= 300) {
                    resultError = XTEMakeError(status,
                        [NSString stringWithFormat:@"HTTP %ld", (long)status]);
                } else {
                    id object = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                               options:0 error:nil];
                    if (![object isKindOfClass:[NSDictionary class]]) {
                        resultError = XTEMakeError(-1, @"服务器响应不是合法 JSON");
                    } else {
                        json = object;
                        NSInteger code = [json[@"code"] integerValue];
                        if (code != 0) {
                            NSString *message = json[@"message"] ?: json[@"error"];
                            if (![message isKindOfClass:[NSString class]] || !message.length) {
                                message = [NSString stringWithFormat:@"接口返回错误码 %ld", (long)code];
                            }
                            resultError = XTEMakeError(code, message);
                        }
                    }
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(json, resultError);
            });
        }];
    [task resume];
}

#pragma mark - 设备信息

- (void)fetchDeviceInfo:(void (^)(NSDictionary *, NSError *))completion {
    [self requestPath:@"/deviceinfo" method:@"GET" params:nil body:nil
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(json, error);
           }];
}

- (void)fetchResourceRoot:(void (^)(NSString *, NSError *))completion {
    [self fetchDeviceInfo:^(NSDictionary *info, NSError *error) {
        NSString *root = info[@"resource_root"];
        if (![root isKindOfClass:[NSString class]] || !root.length) {
            root = kXTEFallbackRoot;
            if (!error) error = XTEMakeError(-4, @"/deviceinfo 缺少 resource_root 字段");
        }
        if (completion) completion(root, error);
    }];
}

#pragma mark - 文件管理

- (void)listDirectory:(NSString *)path
           completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    [self requestPath:@"/file_list" method:@"GET"
               params:@{@"path": path ?: @""} body:nil
           completion:^(NSDictionary *json, NSError *error) {
               if (error) { if (completion) completion(nil, error); return; }
               id items = json[@"data"];
               if (![items isKindOfClass:[NSArray class]]) items = @[];
               if (completion) completion(items, nil);
           }];
}

- (void)readFile:(NSString *)path
      completion:(void (^)(NSString *, NSError *))completion {
    [self requestPath:@"/read_file" method:@"GET"
               params:@{@"path": path ?: @""} body:nil
           completion:^(NSDictionary *json, NSError *error) {
               if (error) { if (completion) completion(nil, error); return; }
               id content = json[@"data"];
               if (![content isKindOfClass:[NSString class]]) content = @"";
               if (completion) completion(content, nil);
           }];
}

- (void)writeFile:(NSString *)path
          content:(NSString *)content
       completion:(void (^)(NSError *))completion {
    [self requestPath:@"/write_file" method:@"POST" params:nil
                 body:@{@"path": path ?: @"", @"content": content ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(error);
           }];
}

- (void)makeDirectory:(NSString *)path completion:(void (^)(NSError *))completion {
    [self requestPath:@"/mkdir" method:@"POST" params:nil
                 body:@{@"path": path ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(error);
           }];
}

- (void)removeDirectory:(NSString *)path completion:(void (^)(NSError *))completion {
    [self requestPath:@"/rmdir" method:@"POST" params:nil
                 body:@{@"path": path ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(error);
           }];
}

- (void)removeFile:(NSString *)path completion:(void (^)(NSError *))completion {
    [self requestPath:@"/remove_file" method:@"POST" params:nil
                 body:@{@"path": path ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(error);
           }];
}

- (void)renameFile:(NSString *)from to:(NSString *)to completion:(void (^)(NSError *))completion {
    [self requestPath:@"/rename_file" method:@"POST" params:nil
                 body:@{@"from": from ?: @"", @"to": to ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(error);
           }];
}

- (void)copyFile:(NSString *)from to:(NSString *)to completion:(void (^)(NSError *))completion {
    [self requestPath:@"/api/file/copy" method:@"POST" params:nil
                 body:@{@"from": from ?: @"", @"to": to ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(error);
           }];
}

- (void)moveFile:(NSString *)from to:(NSString *)to completion:(void (^)(NSError *))completion {
    [self requestPath:@"/api/file/move" method:@"POST" params:nil
                 body:@{@"from": from ?: @"", @"to": to ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(error);
           }];
}

- (void)recycleFile:(NSString *)path completion:(void (^)(NSError *))completion {
    [self requestPath:@"/recycle" method:@"POST" params:nil
                 body:@{@"path": path ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(error);
           }];
}

- (void)encryptFile:(NSString *)path
         completion:(void (^)(NSString *, NSError *))completion {
    [self requestPath:@"/encript_file" method:@"GET"
               params:@{@"path": path ?: @""} body:nil
           completion:^(NSDictionary *json, NSError *error) {
               if (error) { if (completion) completion(nil, error); return; }
               id result = json[@"data"];
               if (![result isKindOfClass:[NSString class]]) {
                   if (completion) completion(nil, XTEMakeError(-6, @"加密结果格式异常"));
                   return;
               }
               if (completion) completion(result, nil);
           }];
}

#pragma mark - 脚本

- (void)launchScriptFile:(NSString *)path
              completion:(void (^)(NSDictionary *, NSError *))completion {
    [self requestPath:@"/launch_script_file" method:@"GET"
               params:@{@"path": path ?: @""} body:nil
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(json, error);
           }];
}

- (void)checkSyntax:(NSString *)source
         completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    [self requestPath:@"/check_syntax" method:@"POST" params:nil
                 body:@{@"source": source ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (error) { if (completion) completion(nil, error); return; }
               id diagnostics = json[@"diagnostics"];
               if (![diagnostics isKindOfClass:[NSArray class]]) diagnostics = @[];
               if (completion) completion(diagnostics, nil);
           }];
}

- (void)fetchScriptList:(void (^)(NSArray<NSString *> *, NSError *))completion {
    [self requestPath:@"/api/script" method:@"GET" params:nil body:nil
           completion:^(NSDictionary *json, NSError *error) {
               if (error) { if (completion) completion(nil, error); return; }
               id names = json[@"data"];
               if (![names isKindOfClass:[NSArray class]]) names = @[];
               if (completion) completion(names, nil);
           }];
}

- (void)saveScriptNamed:(NSString *)name
                 source:(NSString *)source
             completion:(void (^)(NSError *))completion {
    [self requestPath:@"/api/script" method:@"POST" params:nil
                 body:@{@"name": name ?: @"untitled.lua", @"source": source ?: @""}
           completion:^(NSDictionary *json, NSError *error) {
               if (completion) completion(error);
           }];
}

- (void)fetchAppList:(void (^)(NSArray *, NSError *))completion {
    [self requestPath:@"/applist" method:@"GET" params:nil body:nil
           completion:^(NSDictionary *json, NSError *error) {
               if (error) { if (completion) completion(nil, error); return; }
               id apps = json[@"data"];
               if (![apps isKindOfClass:[NSArray class]]) apps = @[];
               if (completion) completion(apps, nil);
           }];
}

#pragma mark - 静态资源原始字节

- (void)fetchRawResource:(NSString *)relativePath
              completion:(void (^)(NSData *, NSError *))completion {
    // 服务端不对 URL path 做百分号解码，因此逐段编码并保留 '/' 分隔符。
    NSMutableArray *segments = [NSMutableArray array];
    for (NSString *segment in [relativePath componentsSeparatedByString:@"/"]) {
        if (segment.length) [segments addObject:XTEPercentEncode(segment)];
    }
    NSString *urlString = [NSString stringWithFormat:@"%@/%@", kXTEBaseURL,
                           [segments componentsJoinedByString:@"/"]];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(nil, XTEMakeError(-9, @"API 客户端已释放"));
                });
                return;
            }
            NSError *resultError = error;
            if (!resultError) {
                NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
                if (status < 200 || status >= 300) {
                    resultError = XTEMakeError(status,
                        [NSString stringWithFormat:@"静态资源请求失败 HTTP %ld", (long)status]);
                } else if (!data.length) {
                    resultError = XTEMakeError(-5, @"静态资源为空");
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(resultError ? nil : data, resultError);
            });
        }];
    [task resume];
}

@end
