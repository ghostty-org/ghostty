/*
 * Minimal reproducer for the libghostty DLL CRT initialization issue.
 *
 * Before the fix (DllMain calling __vcrt_initialize / __acrt_initialize),
 * loading ghostty.dll and calling any function that touches the C runtime
 * crashed with "access violation writing 0x0000000000000024" because Zig's
 * _DllMainCRTStartup does not initialize the MSVC C runtime for DLL targets.
 *
 * This test loads the DLL and calls ghostty_info, which exercises the CRT
 * (string handling, memory). If it returns a version string without
 * crashing, the CRT is properly initialized.
 *
 * Build:  zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
 * Run:    copy ..\..\zig-out\lib\ghostty.dll . && test_dll_init.exe
 *
 * Expected output (after fix):
 *   ghostty_info: <version string>
 */

#include <stdio.h>
#include <windows.h>

typedef struct {
    int build_mode;
    const char *version;
    size_t version_len;
} ghostty_info_s;

typedef ghostty_info_s (*ghostty_info_fn)(void);

int main(void) {
    HMODULE dll = LoadLibraryA("ghostty.dll");
    if (!dll) {
        fprintf(stderr, "LoadLibrary failed: %lu\n", GetLastError());
        return 1;
    }

    ghostty_info_fn info_fn = (ghostty_info_fn)GetProcAddress(dll, "ghostty_info");
    if (!info_fn) {
        fprintf(stderr, "GetProcAddress(ghostty_info) failed: %lu\n", GetLastError());
        return 1;
    }

    ghostty_info_s info = info_fn();
    fprintf(stderr, "ghostty_info: %.*s\n", (int)info.version_len, info.version);

    /* Skip FreeLibrary -- ghostty's global state cleanup and CRT
     * teardown ordering is not yet handled. The OS reclaims everything
     * on process exit. */
    return 0;
}
