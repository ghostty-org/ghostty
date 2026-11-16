# c-vt-cmake

Builds and links libghostty-vt from a CMake project with `FetchContent`.
It creates a terminal, writes VT sequences into it, and formats the screen
contents as plain text.

## Building

```shell-session
cd example/c-vt-cmake
cmake -B build
cmake --build build
./build/c_vt_cmake
```

To build against a local checkout instead of fetching from GitHub:

```shell-session
cmake -B build -DFETCHCONTENT_SOURCE_DIR_GHOSTTY=../..
cmake --build build
```
