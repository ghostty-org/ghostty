# Windows Tests

Manual test programs for Windows-specific functionality.

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads ghostty.dll
at runtime and calls ghostty_info + ghostty_init to verify the MSVC C
runtime is properly initialized.

### Build

```
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

### Run

```
copy ..\..\zig-out\lib\ghostty.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```
ghostty_info: <version string>
ghostty_init: 0
```
