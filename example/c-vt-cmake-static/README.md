# c-vt-cmake-static

Demonstrates consuming libghostty-vt as a **static** library from a CMake
project using `FetchContent`. Creates a terminal, writes VT sequences into
it, and formats the screen contents as plain text.

## Building

```shell-session
cd example/c-vt-cmake-static
cmake -B build
cmake --build build
./build/c_vt_cmake_static
```

To build against a local checkout instead of fetching from GitHub:

```shell-session
cmake -B build -DFETCHCONTENT_SOURCE_DIR_GHOSTTY=../..
cmake --build build
```
