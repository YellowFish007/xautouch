#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTApplication : NSObject

@property (nonatomic, class, readonly) NSString *resourceRoot;
@property (nonatomic, assign) BOOL remoteAccessEnabled;

+ (instancetype)sharedInstance;
- (void)setResourceRoot:(NSString *)root;
- (void)start;
- (void)stop;
- (void)respring;

#pragma mark - 设备 / 配置 / 授权
- (NSDictionary *)deviceInfo;
- (NSDictionary *)config;
- (NSDictionary *)authInfo;
- (NSDictionary *)bindCode:(NSString *)code expires:(NSInteger)seconds;
- (NSDictionary *)userConf;
- (void)setUserConf:(NSDictionary *)conf;

#pragma mark - 应用 / 路径 / 进程
- (NSDictionary *)registerApp:(NSString *)bundle;
- (NSDictionary *)appState;
- (NSArray<NSDictionary *> *)appList;
- (void)clearAppData:(NSString *)bundle;
- (NSString *)jbRoot;
- (NSString *)rootfs;
- (NSString *)environment;
- (NSDictionary *)procInfo;
- (NSDictionary *)runProcDict:(NSString *)dictJSON;

#pragma mark - 系统控制
- (void)reboot;
- (void)halt;
- (void)uicache;
- (void)clearGPS;
- (void)clearAll;
- (void)restartService;
- (NSDictionary *)spawn:(NSString *)command;
- (NSDictionary *)installDebAtPath:(NSString *)path;

#pragma mark - 启动脚本 / 守护进程
- (NSDictionary *)startupConf;
- (NSDictionary *)setStartupRun:(BOOL)on;
- (NSDictionary *)selectStartupScript:(NSString *)name;
- (NSDictionary *)daemonSpawn:(NSString *)filename;

#pragma mark - 录制配置 / WebRTC 信令
- (NSDictionary *)recordConf;
- (NSDictionary *)volumeActionConf;
- (NSDictionary *)webrtcPoll;
- (void)webrtcAnswer:(NSString *)sdp;
- (void)webrtcIce:(NSString *)candidate;
- (void)webrtcStop;
- (NSDictionary *)webrtcMediaStats;
- (void)webrtcMediaStart:(NSDictionary *)config;

#pragma mark - 签名链
- (NSDictionary *)signFile:(NSString *)path entitlements:(NSDictionary *)ent;
- (NSDictionary *)verifySignature:(NSString *)path;
- (NSDictionary *)resignBundle:(NSString *)path;
- (NSDictionary *)signStatus;

#pragma mark - UI 服务 / 自更新 / 音量键
- (void)showToast:(NSString *)text duration:(double)sec position:(NSInteger)pos;
- (void)showPoseAtX:(double)x y:(double)y touchDown:(BOOL)down;
- (void)showFloatingViewWithText:(NSString *)text;
- (void)hideFloatingView;
- (void)showAlertTitle:(NSString *)title message:(NSString *)msg
               actions:(NSArray<NSString *> *)actions
            completion:(nullable void (^)(NSInteger idx))completion;
- (NSDictionary *)updateCheck;
- (NSDictionary *)volumeBind:(NSString *)key action:(NSString *)actionJSON;
- (nullable NSString *)volumeActionFor:(NSString *)key;
- (void)handleVolumeKey:(NSString *)key;

#pragma mark - UDP / 云控 / 屏幕共享
- (NSDictionary *)udpStart:(UInt16)port;
- (void)udpStop;
- (NSDictionary *)udpStats;
- (NSDictionary *)cloudConnect:(NSString *)host port:(UInt16)port token:(NSString *)token;
- (void)cloudDisconnect;
- (NSDictionary *)cloudStatus;
- (NSDictionary *)cloudConfig;
- (BOOL)cloudSaveConfig:(NSDictionary *)cfg;
- (NSDictionary *)screenStart:(NSInteger)fps quality:(double)q;
- (void)screenStop;
- (NSDictionary *)screenStats;

@end

NS_ASSUME_NONNULL_END
