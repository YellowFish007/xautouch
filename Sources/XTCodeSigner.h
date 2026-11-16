/**
 * XTCodeSigner.h - 代码签名 / 重签名子系统
 *
 * 参照商业产品 XXTouch 的 fastPathSign 自签名工具设计，替换 postinst 中单一的
 * `ldid -S` 逻辑。签名链优先 codesign，失败回退 ldid；两条路径都带超时保护。
 * 所有对外方法返回结果字典，统一格式：
 *   {code: 0/非0, message: NSString, file/dir: NSString, stdout: NSString,
 *    stderr: NSString, ...扩展字段}
 * code == 0 表示成功，非 0 表示失败且 message 为可读原因（绝不静默失败）。
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTCodeSigner : NSObject

#pragma mark - 单例

+ (instancetype)sharedInstance;

#pragma mark - 签名 / 校验 / 重签名

/**
 * 对单个 Mach-O 文件签名。
 *
 * @param path        目标文件绝对路径（不允许 shell 命令，内部使用 NSTask 参数数组）
 * @param entitlements 权限字典：
 *        - nil   : 使用内置默认 entitlements（含 get-task-allow / task_for_pid-allow 等）
 *        - @{}   : ad-hoc 签名（ldid -S / codesign --sign -，不附带 entitlements）
 *        - 非空  : 用该字典序列化为 plist 后签名
 * @return {code, message, file, tool, stdout, stderr, exe, timed_out}
 */
- (NSDictionary *)signFileAtPath:(NSString *)path entitlements:(nullable NSDictionary *)entitlements;

/**
 * 校验签名：codesign --verify --verbose=4 + ldid -e 解析 entitlements。
 * 任一工具确认签名有效即视为通过（越狱设备上 ldid 签名通常只有 ldid 能识别）。
 *
 * @return {code, message, file, valid, entitlements, codesign_stdout/stderr,
 *          ldid_stdout/stderr, stdout, stderr}
 */
- (NSDictionary *)verifyFileAtPath:(NSString *)path;

/**
 * 重签名 bundle 目录（.app / tweak 目录 / 任意目录）内所有 Mach-O：
 * 签名前 chmod 755，签名后逐个校验，失败收集到 errors 数组。
 *
 * @return {code, message, dir, count, signed, failed, errors, stdout, stderr}
 */
- (NSDictionary *)resignBundleAtPath:(NSString *)path;

#pragma mark - 状态 / 工具 / entitlements

/**
 * 签名子系统状态。
 * @return {code, message, data:{codesign, ldid, tools_available, preferred_tool,
 *         signed_count, last_sign_time, last_error, environment, jb_root,
 *         bundle_id, team_id, advice}}
 */
- (NSDictionary *)signStatus;

/**
 * 探测 codesign（优先）/ ldid 是否可用：覆盖 jbRoot/usr/bin、/usr/bin、PATH。
 * 至少一个可用返回 YES；两者都没有时记录 last_error 并返回 NO。
 */
- (BOOL)ensureTools;

/** 内置默认 entitlements plist XML（基于 edu.example.xautouch / TEAMID 派生）。 */
- (NSString *)defaultEntitlementsXML;

/** 把默认 entitlements 写入指定路径，自动创建父目录；失败返回 NO。 */
- (BOOL)writeEntitlementsToPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
