# c-vt-cmake-cross

Cross-compiles libghostty-vt with `ghostty_vt_add_target()` and links it
statically. The target OS is chosen automatically:

| Host    | Target          |
| ------- | --------------- |
| Linux   | Windows (MinGW) |
| Windows | Linux (glibc)   |
| macOS   | Linux (glibc)   |

Override with `-DZIG_TARGET=...` if needed.

## Building

```shell-session
cd example/c-vt-cmake-cross
cmake -B build -DFETCHCONTENT_SOURCE_DIR_GHOSTTY=../..
cmake --build build
file build/c_vt_cmake_cross
```
