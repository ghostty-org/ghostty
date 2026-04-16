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
FetchContent_Declare(winghostty
    GIT_REPOSITORY https://github.com/amanthanvi/winghostty.git
    GIT_TAG main
)
FetchContent_MakeAvailable(winghostty)

add_executable(myapp main.c)
target_link_libraries(myapp PRIVATE ghostty-vt)
```

This fetches the winghostty source, builds libghostty-vt via Zig during your
CMake build, and links it into your target. Headers are added to the
include path automatically.

### Using a local checkout

If you already have the winghostty source checked out, skip the download by
pointing CMake at it:

```shell-session
cmake -B build -DFETCHCONTENT_SOURCE_DIR_WINGHOSTTY=/path/to/winghostty
cmake --build build
```

## Using find_package (install-based)

Build and install libghostty-vt first:

```shell-session
cd /path/to/winghostty
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

## Files

- `ghostty-vt-config.cmake.in` — template for the CMake package config
  file installed alongside the library, enabling `find_package()` support.

## Example

See `example/c-vt-cmake/` for a complete working example.
