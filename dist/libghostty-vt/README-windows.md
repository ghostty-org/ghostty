# libghostty-vt for Windows

[libghostty-vt](https://lib.ghostty.org/vt/) is binary packaged for Windows in
zip files. If you're reading this from an unzipped release file, please
reference the filename to determine what architecture it was built for
(`x86_64` or `aarch64`). If you're reading this from a Git checkout,
this README is packed with the releases [documented here](https://lib.ghostty.org/vt/installing.html).

In all cases, the binary files are built for the gnu ABI and work with
MSVC, clang, and mingw programs.

| Path                        | Contents                                         |
| --------------------------- | ------------------------------------------------ |
| `bin/ghostty-vt.dll`        | The DLL                                          |
| `bin/ghostty-vt.pdb`        | Debug information for the DLL                    |
| `lib/ghostty-vt.lib`        | The import library, for linking against the DLL  |
| `lib/ghostty-vt-static.lib` | The static library                               |
| `include/ghostty/`          | The C headers. Programs include `<ghostty/vt.h>` |
| `lib/cmake/ghostty-vt/`     | The CMake package config                         |
| `lib/pkgconfig/`            | The pkg-config files                             |

The DLL does not require a redistributable. The DLL only imports system
standard dependencies: `ntdll`, `kernel32`, and the universal C runtime.

**At run time,** the DLL must be on `PATH` or next to your `.exe`. Copy
`ghostty-vt.pdb` next to the DLL too, so stack traces show function names.

## CMake

Point `CMAKE_PREFIX_PATH` at this directory:

```cmake
find_package(ghostty-vt CONFIG REQUIRED)
target_link_libraries(hello PRIVATE ghostty-vt::ghostty-vt)
```

```sh
cmake -B build -DCMAKE_PREFIX_PATH=C:/path/to/this/directory
```

## pkg-config

```sh
export PKG_CONFIG_PATH=/c/path/to/this/directory/lib/pkgconfig
cc -o hello.exe hello.c $(pkg-config --cflags --libs libghostty-vt)
```

## Command Line

With MSVC or clang, link the import library:

```sh
cl /I include hello.c lib\ghostty-vt.lib
clang -I include hello.c lib\ghostty-vt.lib -o hello.exe
```

## Static Library

`ghostty-vt-static.lib` works with clang, mingw and Zig, but not with MSVC's
`link.exe`. It uses mingw runtime symbols and object sections that `link.exe`
rejects. With MSVC, use the DLL.

The CMake target `ghostty-vt::ghostty-vt-static` and `libghostty-vt-static.pc`
define `GHOSTTY_STATIC` for you. If you call the compiler yourself, define it,
or the headers declare every function as imported from the DLL. Also link
ntdll:

```sh
clang -DGHOSTTY_STATIC -I include hello.c lib\ghostty-vt-static.lib -lntdll -o hello.exe
```

## Verifying

Every release file has a [minisign](https://jedisct1.github.io/minisign/)
signature next to it, and a line in `SHA256SUMS` in the same release directory.
To check the zip:

```sh
minisign -V -P RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV -m ghostty-vt-VERSION-x86_64-windows-gnu.zip
```

## More

The documentation is at <https://lib.ghostty.org/vt/>. The license is in
`LICENSE`.
