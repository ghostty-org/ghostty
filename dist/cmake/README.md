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
    URL https://release.files.ghostty.org/libghostty-vt/1.0.0/libghostty-vt-1.0.0.tar.gz
    URL_HASH SHA256=<sha256 of the tarball>
)
FetchContent_MakeAvailable(ghostty)

add_executable(myapp main.c)
target_link_libraries(myapp PRIVATE ghostty-vt)
```

This downloads the source tarball of a libghostty-vt release, builds
libghostty-vt via Zig during your CMake build, and links it into your
target. Headers are added to the include path automatically.

Replace `1.0.0` with the release you want, in both places in the URL. Then
replace the hash with the tarball's SHA-256 checksum, which you can find in
the `SHA256SUMS` file next to it. For 1.0.0, that is
`https://release.files.ghostty.org/libghostty-vt/1.0.0/SHA256SUMS`.
See [`PACKAGING-LIBGHOSTTY.md`](../../PACKAGING-LIBGHOSTTY.md) for the
other release files and how to verify their signatures.

Use the release tarball, not the archive GitHub generates for the
`vt-1.0.0` tag. The GitHub archive is missing a file that the build
needs to know it should build the library.

### Using a local checkout

If you already have the Ghostty source checked out, skip the download by
pointing CMake at it:

```shell-session
cmake -B build -DFETCHCONTENT_SOURCE_DIR_GHOSTTY=/path/to/ghostty
cmake --build build
```

## Using find_package (install-based)

Build and install libghostty-vt first. From an unpacked release tarball,
either use Zig directly:

```shell-session
cd libghostty-vt-1.0.0
zig build -Doptimize=ReleaseFast --prefix /usr/local
```

or through the CMake wrapper:

```shell-session
cd libghostty-vt-1.0.0
cmake -B build
cmake --build build
cmake --install build --prefix /usr/local
```

Both install the package config to `lib/cmake/ghostty-vt/`.

Then in your project:

```cmake
find_package(ghostty-vt REQUIRED)

add_executable(myapp main.c)
target_link_libraries(myapp PRIVATE ghostty-vt::ghostty-vt)
```

If you installed to a prefix CMake doesn't search by default, tell it
where to look:

```shell-session
cmake -B build -DCMAKE_PREFIX_PATH=/opt/ghostty
```

The package provides two targets:

| Target                          | Links against      |
| ------------------------------- | ------------------ |
| `ghostty-vt::ghostty-vt`        | the shared library |
| `ghostty-vt::ghostty-vt-static` | the static library |

The static target defines `GHOSTTY_STATIC`, so the headers don't mark functions
as imported from a DLL on Windows.

To require a version, pass it to `find_package`:

```cmake
find_package(ghostty-vt 1.0 REQUIRED)
```

This accepts an installed version that is at least as new as the one
you asked for and has the same major version. For example, here is which
installed versions each request accepts:

| Requested | 1.0.0 | 1.0.3 | 1.4.2 |
| --------- | ----- | ----- | ----- |
| `1.0`     | yes   | yes   | yes   |
| `1.0.2`   | no    | yes   | yes   |
| `1.4`     | no    | no    | yes   |

## Notes for packagers

[`PACKAGING-LIBGHOSTTY.md`](../../PACKAGING-LIBGHOSTTY.md) covers
packaging libghostty-vt: the build command, the installed files, the
install directories and the build options. Two details there affect the
CMake package config:

- It is installed next to the libraries, in `cmake/ghostty-vt/`. With
  `--prefix-lib-dir lib64`, for example, it is in
  `lib64/cmake/ghostty-vt/`.
- It doesn't record the prefix or `DESTDIR`. It finds the library and
  headers relative to its own location, so it keeps working if you move
  the whole install somewhere else. The one exception is a library
  directory outside the prefix, such as an absolute `--prefix-lib-dir`.
  The config still finds it, but moving the prefix alone would break
  that.

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
