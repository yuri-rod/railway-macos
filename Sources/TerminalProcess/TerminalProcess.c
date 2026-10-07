#include "TerminalProcess.h"
#include <util.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <errno.h>

int railway_terminal_start(const char *path, char *const argv[], char *const envp[], int rows, int columns, int *descriptor) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    int pid = forkpty(descriptor, NULL, NULL, &size);
    if (pid == 0) {
        execve(path, argv, envp);
        _exit(127);
    }
    if (pid > 0) {
        fcntl(*descriptor, F_SETFL, fcntl(*descriptor, F_GETFL) | O_NONBLOCK);
        fcntl(*descriptor, F_SETFD, FD_CLOEXEC);
    }
    return pid;
}
int railway_terminal_resize(int descriptor, int rows, int columns) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    return ioctl(descriptor, TIOCSWINSZ, &size);
}
int railway_terminal_status(int pid) {
    int status;
    int result = waitpid(pid, &status, WNOHANG);
    if (result <= 0) return -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
