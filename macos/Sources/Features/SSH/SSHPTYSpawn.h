#ifndef GHOSTTY_SSH_PTY_SPAWN_H
#define GHOSTTY_SSH_PTY_SPAWN_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// All arguments must be allocated before this call. The child only uses
/// async-signal-safe libc calls before execve; no Swift runtime runs after fork.
pid_t ghostty_ssh_spawn_pty(const char *executable, char *const arguments[],
                          char *const environment[], int master, int slave);

#ifdef __cplusplus
}
#endif
#endif
