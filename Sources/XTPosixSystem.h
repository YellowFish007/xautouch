/**
 * XTPosixSystem.h - iOS shell 执行垫片
 */
#ifndef XT_POSIX_SYSTEM_H
#define XT_POSIX_SYSTEM_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 等价于 C 标准 system() 的子集：通过 /bin/sh -c 执行命令。
 * 返回：命令退出码；cmd 为 NULL 返回 1；启动失败返回 -1。
 */
int xt_system(const char *cmd);

#ifdef __cplusplus
}
#endif

#endif /* XT_POSIX_SYSTEM_H */
