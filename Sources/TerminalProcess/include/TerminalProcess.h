#ifndef TERMINAL_PROCESS_H
#define TERMINAL_PROCESS_H
#include <stdint.h>
int railway_terminal_start(const char *path, char *const argv[], char *const envp[], int rows, int columns, int *descriptor);
int railway_terminal_resize(int descriptor, int rows, int columns);
int railway_terminal_status(int pid);
#endif
