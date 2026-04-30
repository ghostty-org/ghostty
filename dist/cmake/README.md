# CMake Support for libghostty-vt

The top-level `CMakeLists.txt` wraps the Zig build system so that CMake
projects can consume libghostty-vt without invoking `zig build` manually.
Running `cmake --build` triggers `zig build -Demit-lib-vt` automatically.

This means downstream projects do require a working Zig compiler on
`PATH` to build, but don't need to know any Zig-specific details.

## Using FetchContent (recommended)

Add the following to your project's `CMakeLists.txt`:

```cmake
include(FetchContent)
FetchContent_Declare(ghostty
    GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
    GIT_TAG main
)
FetchContent_MakeAvailable(ghostty)

add_executable(myapp main.c)
target_link_libraries(myapp PRIVATE ghostty-vt)
```

This fetches the Ghostty source, builds libghostty-vt via Zig during your
CMake build, and links it into your target. Headers are added to the
include path automatically.

### Using a local checkout

If you already have the Ghostty source checked out, skip the download by
pointing CMake at it:

```shell-session
cmake -B build -DFETCHCONTENT_SOURCE_DIR_GHOSTTY=/path/to/ghostty
cmake --build build
```

## Using find_package (install-based)

Build and install libghostty-vt first:

```shell-session
cd /path/to/ghostty
cmake -B build
cmake --build build
cmake --install build --prefix /usr/local
```

Then in your project:

```cmake
find_package(ghostty-vt REQUIRED)

add_executable(myapp main.c)
target_link_libraries(myapp PRIVATE ghostty-vt::ghostty-vt)
```

## Cross-compilation

For cross-compiling to a different Zig target triple, use
`ghostty_vt_add_target()` after `FetchContent_MakeAvailable`:

```cmake
FetchContent_MakeAvailable(ghostty)
ghostty_vt_add_target(NAME linux-amd64 ZIG_TARGET x86_64-linux-gnu)

add_executable(myapp main.c)
target_link_libraries(myapp PRIVATE ghostty-vt-static-linux-amd64)
```

### Using zig cc as the C/CXX compiler

When cross-compiling, the host C compiler can't link binaries for the
target platform. `GhosttyZigCompiler.cmake` provides
`ghostty_zig_compiler()` to set up `zig cc` as the C/CXX compiler for
the cross target. It creates wrapper scripts (shell on Unix, `.cmd` on
Windows) and configures `CMAKE_C_COMPILER`, `CMAKE_CXX_COMPILER`, and
`CMAKE_SYSTEM_NAME`.

The module is self-contained — copy it into your project (e.g. to
`cmake/`) and include it directly. It cannot be consumed via
FetchContent because it must run before `project()`, but
`FetchContent_MakeAvailable` triggers `project()` internally:

```cmake
cmake_minimum_required(VERSION 3.19)

include(cmake/GhosttyZigCompiler.cmake)
ghostty_zig_compiler(ZIG_TARGET x86_64-linux-gnu)

project(myapp LANGUAGES C CXX)

FetchContent_MakeAvailable(ghostty)
ghostty_vt_add_target(NAME linux-amd64 ZIG_TARGET x86_64-linux-gnu)

add_executable(myapp main.c)
target_link_libraries(myapp PRIVATE ghostty-vt-static-linux-amd64)
```

See `example/c-vt-cmake-cross/` for a complete working example.
