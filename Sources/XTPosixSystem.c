/**
 * XTPosixSystem.c - iOS 上的 shell 执行垫片
 *
 * iOS SDK 把 system(3) 标记为 unavailable，标准实现不可用。
 * 这里用 posix_spawn 调 /bin/sh -c 提供等价能力，供：
 *   - Lua 5.4 的 os.execute（通过 -Dl_system(cmd)=xt_system(cmd) 注入）
 *   - 需要 shell 语义的内部调用
 *
 * 与 C 标准 system() 的差异：不忽略 SIGINT/SIGQUIT（iOS 上无作业控制），
 * 命令不存在时返回 127，异常终止返回 -1。
 */
#include "XTPosixSystem.h"

#include <spawn.h>
#include <sys/wait.h>
#include <errno.h>

extern char **environ;

int xt_system(const char *cmd) {
    if (cmd == NULL) return 1;          /* 与 system() 一致：有 shell 时返回非 0 */
    if (cmd[0] == '\0') return 0;

    const char *argv[] = { "/bin/sh", "-c", cmd, NULL };
    pid_t pid = -1;
    int rc = posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *const *)argv, environ);
    if (rc != 0) {
        errno = rc;
        return -1;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;                          /* 被信号终止：无退出码 */
}
