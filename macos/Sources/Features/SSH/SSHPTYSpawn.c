#include "SSHPTYSpawn.h"
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>

pid_t ghostty_ssh_spawn_pty(const char *executable, char *const arguments[],
                          char *const environment[], int master, int slave) {
    const pid_t child = fork();
    if (child != 0) return child;

    // Do not call Swift, Objective-C, malloc, or Foundation in this child.
    close(master);
    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    const int signals[] = { SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE };
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        sigaction(signals[i], &action, 0);
    }
    sigset_t mask;
    sigemptyset(&mask);
    sigprocmask(SIG_SETMASK, &mask, 0);
    if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0) _exit(126);
    if (dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 ||
        dup2(slave, STDERR_FILENO) < 0) _exit(126);
    if (slave > STDERR_FILENO) close(slave);
    execve(executable, arguments, environment);
    _exit(127);
}
