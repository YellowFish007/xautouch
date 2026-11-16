/**
 * XTRoutes.mm - XTHTTPServer 路由实现
 *
 * 完整覆盖参照对象的设备端 39 条路由和 Web 面板全部端点：
 *   设备端：/api/app/* /api/config /api/file* /api/key/* /api/pasteboard/*
 *           /api/path/* /api/proc* /api/screen/* /api/script/* /api/system/*
 *           /api/touch/*（含 drag-curve / drag-linear / wheel 及 async 变体）
 *   Web 端：认证、远程访问、服务控制、deb 安装、用户配置、文件管理、
 *           脚本编辑/加密、应用列表、录制配置、WebRTC 信令、SSE 日志。
 *   静态资源：从 resourceRoot/web 提供真实 Web 面板。
 */
#import "XTHTTPServer.h"
#import "XTApplication.h"
#import "XTTouchSynthesizer.h"
#import "XTScriptEngine.h"
#import "XTCapture.h"
#import "XTVision.h"
#import "XTLogger.h"
#import "XTScreenShare.h"
#import "XTUDPControl.h"
#import "XTVisionEngine.h"

@interface XTHTTPServer (XTRoutes)
- (XTHTTPResponse *)ok;
- (XTHTTPResponse *)okData:(id)data;
- (XTHTTPResponse *)serveWebPath:(NSString *)path;
@end

@implementation XTHTTPServer (XTRoutes)

- (XTHTTPResponse *)ok { return [XTHTTPResponse json:@{@"code":@0, @"message":@"ok"}]; }
- (XTHTTPResponse *)okData:(id)data {
    NSMutableDictionary *d = [@{@"code":@0} mutableCopy];
    d[@"data"] = data ?: @[];
    return [XTHTTPResponse json:d];
}

#pragma mark - 主分发

- (XTHTTPResponse *)dispatchRequest:(XTHTTPRequest *)req {
    NSString *path = [req.path componentsSeparatedByString:@"?"].firstObject ?: @"/";
    NSString *m = req.method ?: @"GET";
    XTApplication *app = [XTApplication sharedInstance];
    XTTouchSynthesizer *touch = [XTTouchSynthesizer sharedInstance];
    XTScriptEngine *engine = [XTScriptEngine sharedInstance];

    XTLog(@"[XAutouch] %@ %@", m, path);

    // ==================== 设备信息 / 配置 ====================
    if ([path isEqualToString:@"/deviceinfo"]) return [XTHTTPResponse json:[app deviceInfo]];
    if ([path isEqualToString:@"/api/config"])  return [XTHTTPResponse json:[app config]];
    if ([path isEqualToString:@"/api/app/register"]) {
        NSString *bundle = [req stringForKey:@"bundle" defaultValue:[req stringForKey:@"app" defaultValue:@""]];
        return [XTHTTPResponse json:[app registerApp:bundle]];
    }
    if ([path isEqualToString:@"/api/app/state"]) return [XTHTTPResponse json:[app appState]];
    if ([path isEqualToString:@"/applist"])       return [XTHTTPResponse json:@{@"code":@0, @"data":[app appList]}];
    if ([path isEqualToString:@"/clear_app_data"]) {
        [app clearAppData:[req stringForKey:@"bundle" defaultValue:@""]];
        return [self ok];
    }

    // ==================== 授权 / 远程访问 ====================
    if ([path isEqualToString:@"/device_auth_info"]) return [XTHTTPResponse json:[app authInfo]];
    if ([path isEqualToString:@"/bind_code"]) {
        NSString *code = [req stringForKey:@"bind_code" defaultValue:[req stringForKey:@"code" defaultValue:@""]];
        NSInteger exp  = [req integerForKey:@"mustbeless" defaultValue:0];
        return [XTHTTPResponse json:[app bindCode:code expires:exp]];
    }
    if ([path isEqualToString:@"/open_remote_access"])  { app.remoteAccessEnabled = YES; return [self ok]; }
    if ([path isEqualToString:@"/close_remote_access"]) { app.remoteAccessEnabled = NO;  return [self ok]; }
    if ([path isEqualToString:@"/is_remote_access_opened"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":@{@"opened":@(app.remoteAccessEnabled)}}];
    if ([path isEqualToString:@"/get_user_conf"]) return [XTHTTPResponse json:[app userConf]];
    if ([path isEqualToString:@"/set_user_conf"]) {
        NSDictionary *conf = [req jsonObject] ?: req.query;
        [app setUserConf:conf];
        self.corsEnabled = [[conf objectForKey:@"allow_cors"] boolValue];
        return [self ok];
    }

    // ==================== 触摸原语（完整 9 条）====================
    if ([path isEqualToString:@"/api/touch/tap"]) {
        [touch tapAtX:[req doubleForKey:@"x" defaultValue:0] y:[req doubleForKey:@"y" defaultValue:0]];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/touch/down"]) {
        [touch touchDown:[req doubleForKey:@"x" defaultValue:0] y:[req doubleForKey:@"y" defaultValue:0]
                      id:(uint32_t)[req integerForKey:@"id" defaultValue:1]];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/touch/move"]) {
        [touch touchMove:[req doubleForKey:@"x" defaultValue:0] y:[req doubleForKey:@"y" defaultValue:0]
                      id:(uint32_t)[req integerForKey:@"id" defaultValue:1]];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/touch/up"]) {
        [touch touchUp:[req doubleForKey:@"x" defaultValue:0] y:[req doubleForKey:@"y" defaultValue:0]
                    id:(uint32_t)[req integerForKey:@"id" defaultValue:1]];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/touch/drag-linear"] || [path isEqualToString:@"/api/touch/drag-linear-async"]) {
        BOOL async = [path hasSuffix:@"-async"];
        [touch dragLinearFromX:[req doubleForKey:@"x1" defaultValue:0] y:[req doubleForKey:@"y1" defaultValue:0]
                           toX:[req doubleForKey:@"x2" defaultValue:0] y:[req doubleForKey:@"y2" defaultValue:0]
                      duration:[req doubleForKey:@"duration" defaultValue:300] async:async];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/touch/drag-curve"] || [path isEqualToString:@"/api/touch/drag-curve-async"]) {
        BOOL async = [path hasSuffix:@"-async"];
        NSArray *pts = [req valueForKey:@"points"] ?: [req valueForKey:@"path"] ?: @[];
        [touch dragCurveThrough:pts duration:[req doubleForKey:@"duration" defaultValue:500] async:async];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/touch/wheel"] || [path isEqualToString:@"/api/touch/wheel-async"]) {
        BOOL async = [path hasSuffix:@"-async"];
        [touch wheelAtX:[req doubleForKey:@"x" defaultValue:0] y:[req doubleForKey:@"y" defaultValue:0]
                  delta:[req doubleForKey:@"delta" defaultValue:1] async:async];
        return [self ok];
    }

    // ==================== 按键 / 文本 / 剪贴板 ====================
    if ([path isEqualToString:@"/api/key/down"] || [path isEqualToString:@"/api/key/up"]) {
        NSString *key = [req stringForKey:@"key" defaultValue:@""];
        if ([path hasSuffix:@"/down"]) [touch keyDown:key]; else [touch keyUp:key];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/key/press"]) {
        [touch pressKey:[req stringForKey:@"key" defaultValue:@"HOME"]];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/text/input"]) {
        [touch inputText:[req stringForKey:@"text" defaultValue:@""]];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/pasteboard/read"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":([touch pasteboardRead] ?: @"")}];
    if ([path isEqualToString:@"/api/pasteboard/write"]) {
        [touch pasteboardWrite:[req stringForKey:@"text" defaultValue:@""]];
        return [self ok];
    }

    // ==================== 路径 / 进程 ====================
    if ([path isEqualToString:@"/api/path/jbroot"] || [path isEqualToString:@"/api/path/jbroot/"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":[app jbRoot]}];
    if ([path isEqualToString:@"/api/path/rootfs"] || [path isEqualToString:@"/api/path/rootfs/"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":[app rootfs]}];
    if ([path isEqualToString:@"/api/proc"])       return [XTHTTPResponse json:[app procInfo]];
    if ([path isEqualToString:@"/api/proc-dict/run"])
        return [XTHTTPResponse json:[app runProcDict:[req stringForKey:@"dict" defaultValue:@""]]];

    // ==================== 截屏 / 视觉 ====================
    if ([path isEqualToString:@"/api/screen/snapshot"]) {
        NSString *p = [[XTCapture sharedInstance] captureScreen];
        return p ? [XTHTTPResponse json:@{@"code":@0, @"path":p}]
                 : [XTHTTPResponse error:-2 message:@"capture failed"];
    }
    if ([path isEqualToString:@"/api/vision/template"]) {
        NSDictionary *r = [[XTVision sharedInstance] findTemplate:
                           [req stringForKey:@"template" defaultValue:@""]
                                                        threshold:[req doubleForKey:@"threshold" defaultValue:0.9]];
        return [XTHTTPResponse json:@{@"code":@0, @"result":r}];
    }
    if ([path isEqualToString:@"/api/vision/ocr"] || [path isEqualToString:@"/ocr"]) {
        NSDictionary *r = [[XTVision sharedInstance] ocrWithExpect:[req stringForKey:@"expect" defaultValue:nil]];
        return [XTHTTPResponse json:@{@"code":@0, @"result":r}];
    }
    if ([path isEqualToString:@"/api/vision/engines"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":[[XTVision sharedInstance] engineStatuses]}];
    if ([path isEqualToString:@"/api/vision/engine"]) {
        if ([m isEqualToString:@"POST"]) {
            BOOL ok = [[XTVision sharedInstance] selectEngine:[req stringForKey:@"id" defaultValue:@""]];
            return ok ? [self ok] : [XTHTTPResponse error:-2 message:@"engine not found"];
        }
        NSString *effective = [[XTVisionEngineRegistry sharedRegistry] activeEngineId] ?: @"builtin";
        return [XTHTTPResponse json:@{@"code":@0,
                                      @"active":[[XTVision sharedInstance] activeEngineId] ?: @"builtin",
                                      @"effectiveId":effective,
                                      @"engines":[[XTVision sharedInstance] engineStatuses]}];
    }

    // ==================== 脚本 API ====================
    if ([path isEqualToString:@"/api/script"] || [path isEqualToString:@"/api/script/"]) {
        if ([m isEqualToString:@"POST"]) {
            NSString *name = [req stringForKey:@"name" defaultValue:@"untitled.lua"];
            NSString *src  = [req stringForKey:@"source" defaultValue:@""];
            return [engine writeFile:name content:src]
                 ? [self ok] : [XTHTTPResponse error:-2 message:@"write failed"];
        }
        return [XTHTTPResponse json:@{@"code":@0, @"data":[engine scriptList]}];
    }
    if ([path isEqualToString:@"/api/script/run"]) {
        NSString *n = [req stringForKey:@"name" defaultValue:[req stringForKey:@"file" defaultValue:@"main"]];
        return [XTHTTPResponse json:[engine runScriptNamed:n]];
    }
    if ([path isEqualToString:@"/api/script/selected"]) {
        if ([m isEqualToString:@"POST"]) {
            [engine selectScript:[req stringForKey:@"name" defaultValue:@""]];
            return [self ok];
        }
        return [XTHTTPResponse json:@{@"code":@0, @"data":[engine selectedScript]}];
    }
    if ([path isEqualToString:@"/api/script/pause"])  { [engine pause];  return [self ok]; }
    if ([path isEqualToString:@"/api/script/resume"]) { [engine resume]; return [self ok]; }
    if ([path isEqualToString:@"/api/script/stop"])   { [engine stop];   return [self ok]; }

    // ==================== 文件管理（Web 面板）====================
    if ([path isEqualToString:@"/file_list"] || [path isEqualToString:@"/api/file/"]) {
        // 原版面板取 data.data.list，且每项用 name/mode/change；
        // 同时保留 data 为数组，兼容 /api/file/ 的调用方。
        NSString *dir = [req stringForKey:@"path" defaultValue:
                         [req stringForKey:@"directory" defaultValue:
                          [req stringForKey:@"dir" defaultValue:@""]]];
        NSArray *items = [engine fileListAt:dir] ?: @[];
        NSMutableArray *legacy = [NSMutableArray arrayWithCapacity:items.count];
        for (NSDictionary *it in items) {
            NSMutableDictionary *x = [it mutableCopy];
            x[@"mode"] = x[@"mode"] ?: @"-rw-r--r--";
            x[@"change"] = x[@"change"] ?: x[@"mtime"] ?: @0;
            [legacy addObject:x];
        }
        return [XTHTTPResponse json:@{@"code":@0,
                                      @"data":legacy,
                                      @"list":legacy}];
    }
    if ([path isEqualToString:@"/api/file"]) {
        NSString *f = [req stringForKey:@"path" defaultValue:@""];
        if ([m isEqualToString:@"POST"]) {
            return [engine writeFile:f content:[req stringForKey:@"content" defaultValue:@""]]
                 ? [self ok] : [XTHTTPResponse error:-2 message:@"write failed"];
        }
        return [XTHTTPResponse json:@{@"code":@0, @"data":[engine readFile:f] ?: @""}];
    }
    if ([path isEqualToString:@"/read_file"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":[engine readFile:
                 [req stringForKey:@"path" defaultValue:@""]] ?: @""}];
    if ([path isEqualToString:@"/write_file"]) {
        BOOL ok = [engine writeFile:[req stringForKey:@"path" defaultValue:@""]
                            content:[req stringForKey:@"content" defaultValue:@""]];
        return ok ? [self ok] : [XTHTTPResponse error:-2 message:@"write failed"];
    }
    if ([path isEqualToString:@"/remove_file"]) {
        BOOL ok = [engine removeFile:[req stringForKey:@"path" defaultValue:@""]];
        return ok ? [self ok] : [XTHTTPResponse error:-2 message:@"remove failed"];
    }
    if ([path isEqualToString:@"/rename_file"]) {
        BOOL ok = [engine renameFile:[req stringForKey:@"from" defaultValue:@""]
                                  to:[req stringForKey:@"to" defaultValue:@""]];
        return ok ? [self ok] : [XTHTTPResponse error:-2 message:@"rename failed"];
    }
    if ([path isEqualToString:@"/mkdir"]) {
        BOOL ok = [engine mkdir:[req stringForKey:@"path" defaultValue:@""]];
        return ok ? [self ok] : [XTHTTPResponse error:-2 message:@"mkdir failed"];
    }
    if ([path isEqualToString:@"/rmdir"]) {
        BOOL ok = [engine rmdir:[req stringForKey:@"path" defaultValue:@""]];
        return ok ? [self ok] : [XTHTTPResponse error:-2 message:@"rmdir failed"];
    }
    if ([path isEqualToString:@"/recycle"]) {
        BOOL ok = [engine recycle:[req stringForKey:@"path" defaultValue:@""]];
        return ok ? [self ok] : [XTHTTPResponse error:-2 message:@"recycle failed"];
    }
    if ([path isEqualToString:@"/api/file/copy"]) {
        BOOL ok = [engine copyFile:[req stringForKey:@"from" defaultValue:@""]
                                to:[req stringForKey:@"to" defaultValue:@""]];
        return ok ? [self ok] : [XTHTTPResponse error:-2 message:@"copy failed"];
    }
    if ([path isEqualToString:@"/api/file/move"]) {
        BOOL ok = [engine moveFile:[req stringForKey:@"from" defaultValue:@""]
                                to:[req stringForKey:@"to" defaultValue:@""]];
        return ok ? [self ok] : [XTHTTPResponse error:-2 message:@"move failed"];
    }
    if ([path isEqualToString:@"/encript_file"]) {
        NSString *res = [engine encryptFile:[req stringForKey:@"path" defaultValue:@""]];
        return res ? [XTHTTPResponse json:@{@"code":@0, @"data":res}]
                   : [XTHTTPResponse error:-2 message:@"encrypt failed"];
    }
    if ([path isEqualToString:@"/launch_script_file"]) {
        return [XTHTTPResponse json:[engine runScriptNamed:
                 [req stringForKey:@"path" defaultValue:[req stringForKey:@"name" defaultValue:@"main"]]]];
    }
    if ([path isEqualToString:@"/select_script_file"]) {
        [engine selectScript:[req stringForKey:@"path" defaultValue:@""]];
        return [self ok];
    }
    if ([path isEqualToString:@"/get_selected_script_file"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":[engine selectedScript]}];

    // ==================== 脚本编辑 / 语法检查 ====================
    if ([path isEqualToString:@"/check_syntax"] || [path isEqualToString:@"/api/script/validate"]) {
        NSString *src = [req stringForKey:@"source" defaultValue:[req stringForKey:@"content" defaultValue:@""]];
        return [XTHTTPResponse json:@{@"code":@0, @"diagnostics":[engine validateSource:src]}];
    }
    if ([path isEqualToString:@"/spawn"]) {
        NSString *cmd = [req stringForKey:@"cmd" defaultValue:[req stringForKey:@"command" defaultValue:@""]];
        return [XTHTTPResponse json:[app spawn:cmd]];
    }

    // ==================== 系统控制 ====================
    if ([path isEqualToString:@"/restart"])      { [app restartService]; return [self ok]; }
    if ([path isEqualToString:@"/respring"] || [path isEqualToString:@"/api/system/respring"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [app respring]; });
        return [self ok];
    }
    if ([path isEqualToString:@"/reboot"] || [path isEqualToString:@"/reboot2"] || [path isEqualToString:@"/api/system/reboot"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [app reboot]; });
        return [self ok];
    }
    if ([path isEqualToString:@"/halt"])          { dispatch_async(dispatch_get_main_queue(), ^{ [app halt]; }); return [self ok]; }
    if ([path isEqualToString:@"/uicache"])       { [app uicache]; return [self ok]; }
    if ([path isEqualToString:@"/clear_gps"])     { [app clearGPS]; return [self ok]; }
    if ([path isEqualToString:@"/clear_all"])     { [app clearAll]; return [self ok]; }
    if ([path isEqualToString:@"/api/system/log"] || [path isEqualToString:@"/log"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":[[XTLogger sharedInstance] recentLines:200]}];

    // ==================== deb 安装（multipart 上传）====================
    if ([path isEqualToString:@"/install_deb"]) {
        NSDictionary *part = [req filePartForField:@"file"] ?: [req filePartForField:@"deb"];
        if (!part) return [XTHTTPResponse error:-2 message:@"no deb file uploaded"];
        NSString *name = [part[@"filename"] lastPathComponent] ?: @"upload.deb";
        NSString *tmp  = [NSString stringWithFormat:@"%@/tmp/%@", [XTApplication resourceRoot], name];
        [[NSFileManager defaultManager] createDirectoryAtPath:[tmp stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = part[@"data"];
        BOOL written = [data writeToFile:tmp atomically:YES];
        if (!written) return [XTHTTPResponse error:-2 message:@"save uploaded deb failed"];
        NSDictionary *r = [app installDebAtPath:tmp];
        return [XTHTTPResponse json:r];
    }

    // ==================== 启动脚本 / daemon_spawn（原版面板端点）====================
    if ([path isEqualToString:@"/get_startup_conf"]) return [XTHTTPResponse json:[app startupConf]];
    if ([path isEqualToString:@"/set_startup_run_on"])  return [XTHTTPResponse json:[app setStartupRun:YES]];
    if ([path isEqualToString:@"/set_startup_run_off"]) return [XTHTTPResponse json:[app setStartupRun:NO]];
    if ([path isEqualToString:@"/select_startup_script_file"])
        return [XTHTTPResponse json:[app selectStartupScript:
                [req stringForKey:@"filename" defaultValue:[req stringForKey:@"script" defaultValue:@""]]]];
    if ([path isEqualToString:@"/daemon_spawn"])
        return [XTHTTPResponse json:[app daemonSpawn:
                [req stringForKey:@"filename" defaultValue:[req stringForKey:@"path" defaultValue:@""]]]];

    // ==================== 录制配置 ====================
    if ([path isEqualToString:@"/get_record_conf"])       return [XTHTTPResponse json:[app recordConf]];
    if ([path isEqualToString:@"/get_volume_action_conf"]) return [XTHTTPResponse json:[app volumeActionConf]];
    if ([path isEqualToString:@"/api/record/start"]) { [touch startRecording]; return [self ok]; }
    if ([path isEqualToString:@"/api/record/stop"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":[touch stopRecording]}];
    if ([path isEqualToString:@"/api/record/play"]) {
        [touch playbackEvents:[req valueForKey:@"events"] ?: @[]];
        return [self ok];
    }

    // ==================== WebRTC 信令 ====================
    if ([path isEqualToString:@"/api/webrtc/poll"])   return [XTHTTPResponse json:[app webrtcPoll]];
    if ([path isEqualToString:@"/api/webrtc/answer"]) { [app webrtcAnswer:[req stringForKey:@"sdp" defaultValue:@""]]; return [self ok]; }
    if ([path isEqualToString:@"/api/webrtc/ice"])    { [app webrtcIce:[req stringForKey:@"candidate" defaultValue:@""]]; return [self ok]; }
    if ([path isEqualToString:@"/api/webrtc/stop"])   { [app webrtcStop]; return [self ok]; }
    if ([path isEqualToString:@"/api/webrtc/start"]) {
        NSDictionary *cfg = [req jsonObject] ?: req.query;
        [app webrtcMediaStart:cfg];
        return [XTHTTPResponse json:[app webrtcMediaStats]];
    }
    if ([path isEqualToString:@"/api/webrtc/stats"]) return [XTHTTPResponse json:[app webrtcMediaStats]];

    // ==================== 签名链 ====================
    if ([path isEqualToString:@"/api/system/sign-status"]) return [XTHTTPResponse json:[app signStatus]];
    if ([path isEqualToString:@"/api/system/sign"]) {
        NSDictionary *ent = [req jsonObject][@"entitlements"];
        return [XTHTTPResponse json:[app signFile:[req stringForKey:@"path" defaultValue:@""]
                                      entitlements:ent]];
    }
    if ([path isEqualToString:@"/api/system/verify"])
        return [XTHTTPResponse json:[app verifySignature:[req stringForKey:@"path" defaultValue:@""]]];
    if ([path isEqualToString:@"/api/system/resign"])
        return [XTHTTPResponse json:[app resignBundle:[req stringForKey:@"path" defaultValue:@""]]];

    // ==================== UI 服务 / 自更新 ====================
    if ([path isEqualToString:@"/api/ui/toast"]) {
        [app showToast:[req stringForKey:@"text" defaultValue:@""]
              duration:[req doubleForKey:@"duration" defaultValue:2.0]
              position:[req integerForKey:@"position" defaultValue:1]];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/ui/pose"]) {
        [app showPoseAtX:[req doubleForKey:@"x" defaultValue:0]
                       y:[req doubleForKey:@"y" defaultValue:0]
               touchDown:[req integerForKey:@"down" defaultValue:1] != 0];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/ui/floating"]) {
        if ([m isEqualToString:@"DELETE"]) { [app hideFloatingView]; return [self ok]; }
        [app showFloatingViewWithText:[req stringForKey:@"text" defaultValue:@""]];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/ui/alert"]) {
        NSArray *acts = [req valueForKey:@"actions"] ?: @[@"OK"];
        [app showAlertTitle:[req stringForKey:@"title" defaultValue:@""]
                    message:[req stringForKey:@"message" defaultValue:@""]
                    actions:acts completion:^(NSInteger idx) {
            [[XTHTTPServer sharedInstance] broadcastEvent:@"ui_alert_choice" data:@{@"index":@(idx)}];
        }];
        return [self ok];
    }
    if ([path isEqualToString:@"/api/system/check-update"]) return [XTHTTPResponse json:[app updateCheck]];
    if ([path isEqualToString:@"/api/volume/bind"])
        return [XTHTTPResponse json:[app volumeBind:[req stringForKey:@"key" defaultValue:@""]
                                             action:[req stringForKey:@"action" defaultValue:@""]]];
    if ([path isEqualToString:@"/api/volume/action"]) {
        NSString *a = [app volumeActionFor:[req stringForKey:@"key" defaultValue:@""]];
        return [XTHTTPResponse json:@{@"code":@0, @"data":a ?: @"none", @"action":a ?: @"none"}];
    }

    // ==================== UDP / 云控 / 屏幕共享 ====================
    if ([path isEqualToString:@"/api/udp/start"])
        return [XTHTTPResponse json:[app udpStart:(UInt16)[req integerForKey:@"port" defaultValue:46900]]];
    if ([path isEqualToString:@"/api/udp/stop"])  { [app udpStop]; return [self ok]; }
    if ([path isEqualToString:@"/api/udp/stats"]) return [XTHTTPResponse json:[app udpStats]];
    if ([path isEqualToString:@"/api/udp/token"])
        return [XTHTTPResponse json:@{@"code":@0, @"data":[[XTUDPControl sharedInstance] token] ?: @""}];
    if ([path isEqualToString:@"/api/cloud/connect"])
        return [XTHTTPResponse json:[app cloudConnect:
                [req stringForKey:@"server" defaultValue:
                 [req stringForKey:@"host" defaultValue:@""]]
                                                 port:(UInt16)[req integerForKey:@"port" defaultValue:0]
                                                token:[req stringForKey:@"token" defaultValue:@""]]];
    if ([path isEqualToString:@"/api/cloud/disconnect"]) { [app cloudDisconnect]; return [self ok]; }
    if ([path isEqualToString:@"/api/cloud/status"]) return [XTHTTPResponse json:[app cloudStatus]];
    if ([path isEqualToString:@"/api/cloud/config"]) {
        if ([m isEqualToString:@"POST"]) {
            NSDictionary *cfg = [req jsonObject] ?: req.query;
            return [XTHTTPResponse json:@{@"code":@([app cloudSaveConfig:cfg] ? 0 : -1)}];
        }
        return [XTHTTPResponse json:[app cloudConfig]];
    }
    if ([path isEqualToString:@"/api/screen/stream/start"])
        return [XTHTTPResponse json:[app screenStart:[req integerForKey:@"fps" defaultValue:15]
                                              quality:[req doubleForKey:@"quality" defaultValue:0.7]]];
    if ([path isEqualToString:@"/api/screen/stream/stop"]) { [app screenStop]; return [self ok]; }
    if ([path isEqualToString:@"/api/screen/stream/stats"]) return [XTHTTPResponse json:[app screenStats]];
    if ([path isEqualToString:@"/api/screen/stream/frame"]) {
        NSData *jpg = [[XTScreenShare sharedInstance] nextJPEGFrameWithTimeout:2.0];
        return jpg ? [XTHTTPResponse data:jpg contentType:@"image/jpeg"]
                   : [XTHTTPResponse error:-2 message:@"no frame"];
    }

    // ==================== OPTIONS（CORS 预检）=====================
    if ([m isEqualToString:@"OPTIONS"]) return [self ok];

    // ==================== 静态 Web 资源 ====================
    return [self serveWebPath:path];
}

#pragma mark - 静态文件服务

- (XTHTTPResponse *)serveWebPath:(NSString *)path {
    NSString *webRoot = [[XTApplication resourceRoot] stringByAppendingPathComponent:@"web"];
    NSString *rel = [path isEqualToString:@"/"] ? @"index.html" : [path stringByTrimmingCharactersInSet:
                     [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *full = [[webRoot stringByAppendingPathComponent:rel] stringByStandardizingPath];
    if (![full hasPrefix:webRoot]) return [XTHTTPResponse error:403 message:@"forbidden"];

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir)
        return [XTHTTPResponse error:404 message:@"not found"];

    NSData *data = [NSData dataWithContentsOfFile:full];
    if (!data) return [XTHTTPResponse error:404 message:@"read failed"];

    NSDictionary *mime = @{
        @"html":@"text/html; charset=utf-8", @"htm":@"text/html; charset=utf-8",
        @"js":@"application/javascript; charset=utf-8", @"css":@"text/css; charset=utf-8",
        @"json":@"application/json; charset=utf-8", @"png":@"image/png",
        @"jpg":@"image/jpeg", @"jpeg":@"image/jpeg", @"gif":@"image/gif",
        @"svg":@"image/svg+xml", @"ico":@"image/x-icon", @"webp":@"image/webp",
        @"woff":@"font/woff", @"woff2":@"font/woff2", @"ttf":@"font/ttf",
        @"map":@"application/json", @"txt":@"text/plain; charset=utf-8",
        @"wasm":@"application/wasm", @"mp4":@"video/mp4", @"xml":@"application/xml"
    };
    NSString *ext = full.pathExtension.lowercaseString;
    NSString *ct = mime[ext] ?: @"application/octet-stream";
    XTHTTPResponse *r = [XTHTTPResponse data:data contentType:ct];
    r.extraHeaders = @{@"Cache-Control":@"public, max-age=60"};
    return r;
}

@end
