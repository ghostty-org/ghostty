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

Build and install libghostty-vt first, either with Zig directly:

```shell-session
cd /path/to/ghostty
zig build -Demit-lib-vt -Doptimize=ReleaseFast --prefix /usr/local
```

or through the CMake wrapper:

```shell-session
cd /path/to/ghostty
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

To require a version, pass it to `find_package`:

```cmake
find_package(ghostty-vt 0.1 REQUIRED)
```

This accepts an installed version that is at least as new as the one
you asked for and has the same ABI. Before 1.0, any minor release may
change the ABI, so the major and minor versions must both match. From
1.0 on, only the major version must match. For example, here is which
installed versions each request accepts:

| Requested | 0.1.0 | 0.1.3 | 0.2.0 | 1.4.2 |
| --------- | ----- | ----- | ----- | ----- |
| `0.1`     | yes   | yes   | no    | no    |
| `0.1.2`   | no    | yes   | no    | no    |
| `1.0`     | no    | no    | no    | yes   |

## Notes for packagers

`zig build -Demit-lib-vt --prefix <prefix>` installs the following:

| Path                    | Contents                                                                                |
| ----------------------- | --------------------------------------------------------------------------------------- |
| `lib/`                  | The shared library and its version symlinks, and the static library (`libghostty-vt.a`) |
| `include/ghostty/`      | The C headers                                                                           |
| `lib/pkgconfig/`        | `libghostty-vt.pc` and `libghostty-vt-static.pc`                                        |
| `lib/cmake/ghostty-vt/` | The CMake package config                                                                |

On Windows, the DLL is installed to `bin/` instead, and `lib/` holds
the import library `ghostty-vt.lib` and the static library
`ghostty-vt-static.lib`.

### Changing the install directories

The paths above are the defaults. Zig's `--prefix-lib-dir`,
`--prefix-include-dir` and `--prefix-exe-dir` options change them, and
the pkg-config files and the CMake package config follow the libraries.
For example, with `--prefix-lib-dir lib64` they are installed to
`lib64/pkgconfig/` and `lib64/cmake/ghostty-vt/`.

### Staged installs with DESTDIR

Distro packages are usually built by installing into a staging
directory first. Set `DESTDIR` to that directory and pass the final
prefix with `--prefix`:

```shell-session
DESTDIR="$PWD/stage" zig build -Demit-lib-vt -Doptimize=ReleaseFast \
  --prefix /usr --prefix-lib-dir lib64
```

This puts the files in `$PWD/stage/usr`, but the installed files only
mention where the package will be after it is copied into place. Both
`.pc` files start with:

```
prefix=/usr
includedir=${prefix}/include
libdir=${prefix}/lib64
```

The CMake package config doesn't contain the prefix at all. It finds
the library and headers relative to its own location, so it also keeps
working if you move the whole install somewhere else. (The one
exception is a directory outside the prefix, such as an absolute
`--prefix-lib-dir` elsewhere. The config still finds it, but moving
the prefix alone would break that.)

### Build defaults

Two build defaults matter for packaging:

- **Debug info is kept.** libghostty-vt is not stripped by default, so
  you can split its debug info into a separate package with your usual
  tools. Pass `-Dstrip=true` to strip it instead. The one exception is
  `-Doptimize=ReleaseSmall`, which strips by default.
- **Xcode is not required on macOS.** `-Demit-lib-vt` builds only the
  plain libraries. Pass `-Demit-xcframework=true` if you also want the
  XCFramework for Apple app development, which needs Xcode.

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
