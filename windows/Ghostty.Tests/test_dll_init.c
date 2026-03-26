/*
 * Minimal reproducer for the libghostty DLL CRT initialization issue.
 *
 * Before the fix (DllMain calling __vcrt_initialize / __acrt_initialize),
 * ghostty_init crashed with "access violation writing 0x0000000000000024"
 * because Zig's _DllMainCRTStartup does not initialize the MSVC C runtime
 * for DLL targets.
 *
 * Build:  zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
 * Run:    copy ..\..\zig-out\lib\ghostty.dll . && test_dll_init.exe
 *
 * Expected output (after fix):
 *   ghostty_info: <version string>
 *   ghostty_init: 0
 */

#include <stdio.h>
#include <windows.h>

typedef struct {
    int build_mode;
    const char *version;
    size_t version_len;
} ghostty_info_s;

typedef ghostty_info_s (*ghostty_info_fn)(void);
typedef int (*ghostty_init_fn)(size_t, char **);

int main(void) {
    HMODULE dll = LoadLibraryA("ghostty.dll");
    if (!dll) {
        fprintf(stderr, "LoadLibrary failed: %lu\n", GetLastError());
        return 1;
    }

    ghostty_info_fn info_fn = (ghostty_info_fn)GetProcAddress(dll, "ghostty_info");
    if (info_fn) {
        ghostty_info_s info = info_fn();
        fprintf(stderr, "ghostty_info: %.*s\n", (int)info.version_len, info.version);
    }

    ghostty_init_fn init_fn = (ghostty_init_fn)GetProcAddress(dll, "ghostty_init");
    if (init_fn) {
        char *argv[] = {"ghostty"};
        int result = init_fn(1, argv);
        fprintf(stderr, "ghostty_init: %d\n", result);
        if (result != 0) return 1;
    }

    /* Skip FreeLibrary -- ghostty's global state cleanup and CRT
     * teardown ordering is not yet handled. The OS reclaims everything
     * on process exit. */
    return 0;
}
