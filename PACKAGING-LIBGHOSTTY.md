# Packaging libghostty-vt for Distribution

libghostty-vt is a C library for parsing terminal escape sequences and
maintaining terminal state, such as the screen, scrollback, styles and
cursor. It is extracted from Ghostty and needs nothing at runtime beyond
the C library. This document provides guidance to package maintainers on
how to package libghostty-vt for distribution.

libghostty-vt is released separately from Ghostty, with its own version
numbers and its own `vt-X.Y.Z` tags. The version of the Ghostty app doesn't
matter here. To package the Ghostty app, see `PACKAGING.md` in the Ghostty
repository instead.

> [!IMPORTANT]
>
> This document is only accurate for the libghostty-vt source alongside it.
> **Do not use this document for older or newer versions of libghostty-vt!**
> If you are reading this document in a different version of
> libghostty-vt, please find the `PACKAGING-LIBGHOSTTY.md` file alongside
> that version.

## Source Tarballs

Source tarballs with stable checksums are available for tagged releases
at `release.files.ghostty.org` in the following URL format where
`VERSION` is the version number with no prefix such as `0.1.0`:

```
https://release.files.ghostty.org/libghostty-vt/VERSION/libghostty-vt-VERSION.tar.gz
https://release.files.ghostty.org/libghostty-vt/VERSION/libghostty-vt-VERSION.tar.gz.minisig
```

This is the only place releases are published. The same directory also
holds prebuilt files for app developers:

- `ghostty-vt-VERSION.xcframework.zip`: an XCFramework for Apple platforms.
- `ghostty-vt-VERSION.wasm` and `ghostty-vt-VERSION-small.wasm`: the
  WebAssembly module, built with `ReleaseFast` and `ReleaseSmall`. See
  [WebAssembly](#webassembly).
- `libghostty-vt-VERSION-docs.zip`: the C API reference as HTML.

Every file has a `.minisig` signature next to it. `SHA256SUMS` lists the
checksums of the tarball and the files above, and is signed too, as
`SHA256SUMS.minisig`.
Signature files are signed with
[minisign](https://jedisct1.github.io/minisign/)
using the following public key, which is the same key that signs Ghostty
releases:

```
RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
```

For example, to check a downloaded tarball:

```sh
minisign -V -P RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV \
  -m libghostty-vt-0.1.0.tar.gz
```

The tarball unpacks to a `libghostty-vt-VERSION` directory.

**Tip source tarballs** are available on the
[GitHub releases page](https://github.com/ghostty-org/ghostty/releases/tag/tip).
Use the `libghostty-vt-source.tar.gz` asset. These tarballs are generated
for every commit to the `main` branch and are not associated with a
specific version, so they are not meant for distribution packages.

> [!WARNING]
>
> Source tarballs are _not the same_ as a Git checkout, and they are not
> the same as the archive GitHub generates for a `vt-VERSION` tag. A
> libghostty-vt source tarball contains only what the library needs, plus
> a `LIB_VERSION` file with its version. That file is what makes
> `zig build` build the library. Without it, as in a Git checkout or the
> GitHub archive, `zig build` builds the Ghostty app instead.
>
> Please use the source tarballs. If you must build from a Git checkout,
> add `-Demit-lib-vt` to every `zig build` command below.

## Zig Version

[Zig](https://ziglang.org) is required to build libghostty-vt. Prior to Zig
1.0, Zig releases often have breaking changes, so each libghostty-vt
release requires a specific Zig version. This will always be an official
released version of Zig.

To find the version of Zig required, check the `minimum_zig_version` field
in `build.zig.zon`. You don't need to know Zig to extract this information.
The build checks the Zig version and stops with an error if it doesn't
match. The major and minor versions must match exactly, and any patch
version at least as new is accepted.

For example, libghostty-vt 0.1.0 requires Zig 0.17.0. Any Zig 0.17.x
works, but Zig 0.16 and Zig 0.18 do not.

## Building libghostty-vt

The following is a standard example of how to build libghostty-vt _for
system packages_. Run these commands from the unpacked source tarball.

1. First, we fetch our dependencies from the internet into a cached
   directory. This is the only step that requires internet access.
   `deps/libghostty-vt.txt` lists only the packages the library needs, so
   this downloads far less than a Ghostty app build would:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/offline-cache \
  ./nix/build-support/fetch-zig-cache.sh deps/libghostty-vt.txt
```

2. Next, we build libghostty-vt. This step requires no internet access:

```sh
DESTDIR=/tmp/pkg \
ZIG_GLOBAL_CACHE_DIR=/tmp/build-cache \
zig build \
  --prefix /usr \
  --system /tmp/offline-cache/p \
  -Doptimize=ReleaseFast \
  -Dcpu=baseline
```

The build options are covered in a later section, but this will build and
install libghostty-vt to `/tmp/pkg` with the prefix `/usr` (i.e. the shared
library will be in `/tmp/pkg/usr/lib/`). The installed pkg-config and CMake
files refer to `/usr`, where the files will be once your package is
installed, and never to `/tmp/pkg`.

> [!IMPORTANT]
>
> `ZIG_GLOBAL_CACHE_DIR` in the build step must be a new, empty directory,
> not the one the fetch step filled. With Zig 0.17, reusing the fetch
> cache can crash the build with "reached unreachable code" instead of a
> useful error. An empty cache also proves that the build used only the
> packages you fetched.

## Installed Files

With `--prefix /usr`, the build installs the following files on Linux and
other Unix systems:

| Path                                                       | Contents                                              |
| ---------------------------------------------------------- | ----------------------------------------------------- |
| `/usr/lib/libghostty-vt.so.X.Y.Z`                          | The shared library                                    |
| `/usr/lib/libghostty-vt.so.X`                              | A symlink named after the SONAME, which programs load |
| `/usr/lib/libghostty-vt.so`                                | A symlink used when linking programs                  |
| `/usr/lib/libghostty-vt.a`                                 | The static library                                    |
| `/usr/include/ghostty/vt.h` and `/usr/include/ghostty/vt/` | The C headers. Programs only include `<ghostty/vt.h>` |
| `/usr/lib/pkgconfig/libghostty-vt.pc`                      | The pkg-config file for the shared library            |
| `/usr/lib/pkgconfig/libghostty-vt-static.pc`               | The pkg-config file for the static library            |
| `/usr/lib/cmake/ghostty-vt/`                               | The CMake package config                              |

On macOS, the shared library files are named `libghostty-vt.X.Y.Z.dylib`,
`libghostty-vt.X.dylib` and `libghostty-vt.dylib`, and programs load it as
`@rpath/libghostty-vt.X.dylib`. On Windows, the DLL is installed to `bin/`
instead, and `lib/` holds the import library `ghostty-vt.lib` and the
static library `ghostty-vt-static.lib`.

Most distributions split these into a runtime package with the versioned
shared library and its SONAME symlink, and a development package with
everything else.

## Build Options

libghostty-vt uses the Zig build system. You can see all available build
options by running `zig build --help`. The following are options that are
particularly relevant to package maintainers:

- `--prefix`: The installation prefix. Combine with the `DESTDIR`
  environment variable to install to a temporary directory for packaging.

- `--prefix-lib-dir` and `--prefix-include-dir`: Change where the
  libraries and headers are installed, relative to the prefix. The
  pkg-config files and the CMake package config are installed next to the
  libraries and point at the new locations. For example, use
  `--prefix-lib-dir lib64` for a distribution that keeps libraries in
  `/usr/lib64`.

- `--system`: The path to the offline cache directory. This disables
  any package fetching from the internet.

- `-Doptimize=ReleaseFast`: Build with optimizations enabled and safety
  checks disabled. This is the recommended build mode for distribution.
  Other build modes are available: `Debug`, `ReleaseSafe`, and
  `ReleaseSmall`.

- `-Dcpu=baseline`: Build for the "baseline" CPU of the target
  architecture. This avoids building for newer CPU features that may not
  be available on all target machines.

- `-Dtarget=$arch-$os-$abi`: Build for a specific target triple. This is
  often necessary for system packages to specify a specific minimum Linux
  version, glibc, etc. Run `zig targets` to get a full list of available
  targets.

- `-Dstrip`: libghostty-vt keeps its debug info by default, so you can
  split it into a separate debug package with your usual tools. Pass
  `-Dstrip=true` to strip it instead. `-Doptimize=ReleaseSmall` strips by
  default.

- `-Demit-xcframework`: Off by default, so building on macOS doesn't
  require Xcode. Pass `-Demit-xcframework=true` to also build the
  XCFramework.

- `-Dsimd`: On by default, except for WebAssembly and freestanding
  targets. It enables the SIMD-accelerated code paths, which use
  [simdutf](https://github.com/simdutf/simdutf) and
  [Highway](https://github.com/google/highway) and make parsing much
  faster. `-Dsimd=false` removes both, but it makes the library much
  slower, so please don't use it for general-purpose packages.

- `-fsys=simdutf` and `-fsys=highway`: Link against the system's simdutf
  or Highway instead of the copies bundled with libghostty-vt. Both are off
  by default, even with `--system`. When enabled, the pkg-config file
  lists them (as `simdutf` and `libhwy`) so programs that link the static
  library pick them up. A system simdutf also makes the library depend on
  the C++ standard library, which the bundled copy avoids. These are the
  only `-fsys` options that affect libghostty-vt. The others are for the
  Ghostty app.

- `-Dvt-features`: Leave out optional parts of the library. See
  [WebAssembly](#webassembly) for how to use it. A library built with
  fewer features has fewer functions, so programs built against the full
  library may not work with it. System packages should keep the default,
  which includes every feature.

## Versioning and ABI

libghostty-vt's version is set by `lib_version` in `build.zig` and recorded
in the tarball's `LIB_VERSION` file. It is independent of the Ghostty app
version.

**Before 1.0, any minor release may break compatibility.** A program built
against libghostty-vt 0.1 may not build or run with 0.2. Patch releases,
such as 0.1.1, never break compatibility. When libghostty-vt's minor
version changes, rebuild every package that depends on it:

| Update         | Rebuild dependent packages? |
| -------------- | --------------------------- |
| 0.1.0 to 0.1.1 | No                          |
| 0.1.1 to 0.2.0 | Yes                         |
| 1.2.0 to 1.3.0 | No                          |
| 1.3.0 to 2.0.0 | Yes                         |

The shared library's SONAME only includes the major version, so it is
`libghostty-vt.so.0` for every 0.x release. This means the system can't
tell 0.1 and 0.2 apart, which is why the rebuild is needed. Programs can
also check the version themselves, with the macros in
`<ghostty/vt/version.h>` when they are compiled and with
`ghostty_version()` when they run.

**From 1.0, libghostty-vt follows semantic versioning.** A release that
breaks compatibility gets a new major version and a new SONAME, such as
`libghostty-vt.so.2`. Minor and patch releases only add to the library.

On macOS, the shared library also records a compatibility version
(`0.N.0` before 1.0, then `X.0.0`) and a current version (`X.Y.Z`). The
macOS loader doesn't check them, so follow the same rebuild rule there.

## Package Names

Please name the runtime package according to your distribution's policy
for shared libraries. Policies that name packages after the SONAME, such
as Debian's, give `libghostty-vt0` for every 0.x release and
`libghostty-vt1` after 1.0. Distributions such as Fedora, Arch and nixpkgs
use `libghostty-vt` for every version. The source package, the pkg-config
module and the `-lghostty-vt` linker flag are always `libghostty-vt`.

## Using the Library

Programs can find libghostty-vt with pkg-config:

```sh
cc -o myapp main.c $(pkg-config --cflags --libs libghostty-vt)
```

To link the static library instead, use the `libghostty-vt-static` module
and pass `--static`:

```sh
cc -o myapp main.c $(pkg-config --static --cflags --libs libghostty-vt-static)
```

Or with CMake:

```cmake
find_package(ghostty-vt 0.1 REQUIRED)
target_link_libraries(myapp PRIVATE ghostty-vt::ghostty-vt)
```

Before 1.0, the CMake package only accepts a request from the same minor
version. A request for `0.1` accepts any installed 0.1.x but not 0.2.0.
From 1.0, it accepts any installed version with the same major version.
See [`dist/cmake/README.md`](dist/cmake/README.md) for the other CMake
targets, building through CMake, and cross-compiling.

## Third-Party Code

[`deps/libghostty-vt-third-party.json`](deps/libghostty-vt-third-party.json)
lists every third-party project used to build libghostty-vt, with its
version, upstream URL and SPDX license. Each entry's `use` field says how
the project is used:

- `"linked"`: Its code is compiled into libghostty-vt. List these in your
  package metadata, such as Fedora `bundled()` provides or a Debian
  copyright file.
- `"build"`: It only runs during the build and ships nothing.

For example, the entry for Highway looks like this (some fields left out):

```json
{
  "name": "highway",
  "version": "1.2.0",
  "url": "https://deps.files.ghostty.org/highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz",
  "hash": "N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE",
  "license": "Apache-2.0 OR BSD-3-Clause",
  "use": "linked"
}
```

The license texts are in these places:

- libghostty-vt: `LICENSE` at the root of the tarball.
- simdutf: `pkg/simdutf/vendor/`, since simdutf is included in the
  tarball.
- Every other linked project: in the directory the fetch step unpacked
  it to, `/tmp/offline-cache/p/<hash>` in the example above, where
  `<hash>` is the entry's `hash` field.

[`deps/README.md`](deps/README.md) describes this file and the other
generated dependency lists.

## Testing

To run the library's tests, use the same offline setup as the build:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/build-cache \
zig build test-lib-vt \
  --system /tmp/offline-cache/p
```

To check the installed files, compile and run a small program against
them. The `.pc` file refers to `/usr`, so the `--define-variable` flag
points pkg-config at `/tmp/pkg/usr` instead:

```sh
cat > smoke.c <<'EOF'
#include <stdio.h>
#include <ghostty/vt.h>

int main(void) {
  printf("headers %s, library %s\n", GHOSTTY_VT_VERSION, ghostty_version());
  return 0;
}
EOF
cc -o smoke smoke.c $(PKG_CONFIG_PATH=/tmp/pkg/usr/lib/pkgconfig \
  pkg-config --define-variable=prefix=/tmp/pkg/usr --cflags --libs libghostty-vt)
LD_LIBRARY_PATH=/tmp/pkg/usr/lib ./smoke
```

On macOS, use `DYLD_LIBRARY_PATH` instead of `LD_LIBRARY_PATH`. For a
release, the program prints the same version twice:

```
headers 0.1.0, library 0.1.0
```

## Platform Support

| Tier | Meaning                    | Platforms                                                                                                                               |
| ---- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | Built and tested in CI     | Linux x86_64 and aarch64 (glibc and musl), macOS 13+, iOS 13+, FreeBSD x86_64 and aarch64, Windows x86_64, wasm32-freestanding, Android |
| 2    | Built in CI but not tested | riscv32 and thumb freestanding                                                                                                          |
| 3    | Best effort, not in CI     | wasm32-wasi, illumos, Windows arm64, 32-bit x86                                                                                         |

## WebAssembly

libghostty-vt can be built for WebAssembly for use in browsers and other
wasm runtimes:

```sh
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

This produces `zig-out/bin/ghostty-vt.wasm`.

Some notes for packaging the wasm module:

- The build enables the `simd128` feature by default. Every browser engine
  has supported it for years (Chrome 91, Firefox 89, Safari 16.4) and it is
  a large performance win for VT parsing. If you target an unusual runtime
  without SIMD support, opt out with `-Dcpu=generic`.

- Optional feature areas can be compiled out with `-Dvt-features` to
  significantly reduce binary size. The flag takes comma-separated
  modifications applied to the default all-enabled feature set,
  `-Dcpu`-style: `+feature` (or bare `feature`) enables, `-feature`
  disables, and the special name `all` refers to every feature. Hyphens
  and underscores are interchangeable in feature names. For example, a
  read-only terminal viewer only needs the render state API:

  ```sh
  zig build -Demit-lib-vt -Dtarget=wasm32-freestanding \
    -Doptimize=ReleaseSmall -Dvt-features=-all,+render-state
  ```

  This roughly halves the compressed module size versus the default
  build. An interactive terminal typically wants
  `-Dvt-features=-all,+render-state,+input-encode,+selection,+color`.
  Disabled features drop both their C API exports and any escape
  sequence handling (the sequences are still consumed and safely
  ignored). See the `Features` struct in `src/terminal/build_options.zig`
  for the full list of features and what each one covers.

- `ReleaseSmall` is the recommended optimization mode for the web. Running
  the result through [Binaryen's](https://github.com/WebAssembly/binaryen)
  `wasm-opt -O3` shrinks it by roughly a further 10% without hurting
  performance.

- `ReleaseFast` measures 10-20% faster than `ReleaseSmall` on escape-heavy
  terminal workloads, but the artifact is dominated by DWARF debug info.
  If you want the speed, strip it: `wasm-opt -O3 --strip-dwarf` reduces a
  ReleaseFast build from over 5MB to roughly 1.1MB (versus roughly 0.8MB
  for ReleaseSmall). When invoking `wasm-opt`, pass the feature flags for
  what the module uses, e.g. `--enable-simd --enable-bulk-memory
--enable-sign-ext --enable-nontrapping-float-to-int --enable-multivalue
--enable-reference-types`.
