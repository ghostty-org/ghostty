# Packaging libghostty-vt for Distribution

libghostty-vt is a portable, high-performance C library for terminal emulation.
This document provides guidance to package maintainers on how to package
libghostty-vt for distribution.

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
`VERSION` is the version number with no prefix such as `1.0.0`:

```
https://release.files.ghostty.org/libghostty-vt/VERSION/libghostty-vt-VERSION.tar.gz
https://release.files.ghostty.org/libghostty-vt/VERSION/libghostty-vt-VERSION.tar.gz.minisig
```

The build needs a few Zig packages that aren't in the source tarball.
Rather than have Zig download them during the build, you can download a
dependency tarball that contains all of them, published next to each
source tarball:

```
https://release.files.ghostty.org/libghostty-vt/VERSION/libghostty-vt-VERSION-deps.tar.gz
https://release.files.ghostty.org/libghostty-vt/VERSION/libghostty-vt-VERSION-deps.tar.gz.minisig
```

The source tarball and the dependency tarball of one version belong
together. Don't mix tarballs from different versions. See
[Building libghostty-vt](#building-libghostty-vt) for how to use them.

This is the only place releases are published. The same directory also
holds prebuilt files for app developers:

- `ghostty-vt-VERSION.xcframework.zip`: an XCFramework for Apple platforms.
- `ghostty-vt-VERSION.wasm` and `ghostty-vt-VERSION-small.wasm`: the
  WebAssembly module, built with `ReleaseFast` and `ReleaseSmall`. See
  [WebAssembly](#webassembly).
- `ghostty-vt-VERSION-x86_64-windows-gnu.zip` and
  `ghostty-vt-VERSION-aarch64-windows-gnu.zip`: the Windows install tree
  described in [Installed Files](#installed-files), built with
  `ReleaseFast`.
- `libghostty-vt-VERSION-docs.zip`: the C API reference as HTML. The HTML
  reference for each release is also at <https://lib.ghostty.org/vt/X.Y.Z/>.

Every file has a `.minisig` signature next to it. `SHA256SUMS` lists the
checksums of both tarballs and the files above, and is signed too, as
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
  -m libghostty-vt-1.0.0.tar.gz
```

The source tarball unpacks to a `libghostty-vt-VERSION` directory, and the
dependency tarball to a `libghostty-vt-VERSION-deps` directory.

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

For example, libghostty-vt 1.0.0 requires Zig 0.17.0. Any Zig 0.17.x
works, but Zig 0.16 and Zig 0.18 do not.

## Building libghostty-vt

The following is a standard example of how to build libghostty-vt _for
system packages_. The build needs no internet access: Zig finds every
package it needs in the directory passed with `--system`.

1. First, download the source tarball and the dependency tarball of the
   same version, check both signatures as shown in
   [Source Tarballs](#source-tarballs), and unpack them side by side:

```sh
tar -xzf libghostty-vt-1.0.0.tar.gz
tar -xzf libghostty-vt-1.0.0-deps.tar.gz
cd libghostty-vt-1.0.0
```

1. Next, build libghostty-vt from the unpacked source tarball, with the
   unpacked dependency tarball as the `--system` directory:

```sh
DESTDIR=/tmp/pkg \
ZIG_GLOBAL_CACHE_DIR=/tmp/build-cache \
zig build \
  --prefix /usr \
  --system ../libghostty-vt-1.0.0-deps \
  -Doptimize=ReleaseFast \
  -Dcpu=baseline
```

The build options are covered in a later section, but this will build and
install libghostty-vt to `/tmp/pkg` with the prefix `/usr` (i.e. the shared
library will be in `/tmp/pkg/usr/lib/`). The installed pkg-config and CMake
files refer to `/usr`, where the files will be once your package is
installed, and never to `/tmp/pkg`.

The dependency tarball contains exactly the packages that
`deps/libghostty-vt.txt` lists. Each package is already unpacked into its
own directory, named by its Zig package hash. This is the layout Zig's own
package cache uses, which is why `--system` can read it directly:

```
libghostty-vt-1.0.0-deps/
  uucode-0.2.0-ZZjBPm6FVgBcY-79AHV8ckQj86z0JwOyVyj89VeZrEiv/
  N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE/
  ...
```

**Without the dependency tarball**, for example when building from a Git
checkout or a tip source tarball, fetch the packages yourself first. This
step needs internet access and Zig. `deps/libghostty-vt.txt` lists only
the packages the library needs, so it downloads far less than a Ghostty app
build would:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/offline-cache \
  ./nix/build-support/fetch-zig-cache.sh deps/libghostty-vt.txt
```

Then build as in step 2, with `--system /tmp/offline-cache/p` instead.

> [!IMPORTANT]
>
> `ZIG_GLOBAL_CACHE_DIR` in the build step must be a new, empty directory,
> not `~/.cache/zig` or the one the fetch step filled. With Zig 0.17, a
> cache that holds an archive of a package can crash the build with
> "reached unreachable code" instead of a useful error. An empty cache also
> proves that the build used only the packages in the `--system`
> directory.

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
`@rpath/libghostty-vt.X.dylib`. On Windows, the DLL `ghostty-vt.dll` and
its debug information `ghostty-vt.pdb` are installed to `bin/` instead,
and `lib/` holds the import library `ghostty-vt.lib` and the static
library `ghostty-vt-static.lib`. The DLL and import library names carry no
major version, so side-by-side installs are not supported on Windows.
Each release publishes this tree as a zip for x86_64 and aarch64, with
`LICENSE` and a `README.md` at its root.

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

- `--system`: The directory that holds the Zig packages, such as the
  unpacked dependency tarball. This disables any package fetching from
  the internet.

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
  [WebAssembly](#webassembly) for how to use it. Every function is still
  exported, so programs link and load against any build, but the
  functions of a left-out feature return `GHOSTTY_UNSUPPORTED`. Programs
  built against the full library may therefore lose functionality.
  System packages should keep the default, which includes every feature.

## Versioning and ABI

libghostty-vt's version is set by `lib_version` in `build.zig` and recorded
in the tarball's `LIB_VERSION` file. It is independent of the Ghostty app
version.

**libghostty-vt follows semantic versioning.** A release that breaks
compatibility gets a new major version and a new SONAME. Minor and patch releases only add to the library, so
dependent packages only need a rebuild when the major version changes:

| Update              | Rebuild dependent packages? |
| ------------------- | --------------------------- |
| 1.2.0 to 1.3.0      | No                          |
| A new major version | Yes                         |

The shared library's SONAME only includes the major version, so it is
`libghostty-vt.so.1` for every 1.x release. Programs can also check the
version themselves, with the macros in `<ghostty/vt/version.h>` when they
are compiled and with `ghostty_version()` when they run.

On Linux and FreeBSD, the shared library exports only the `ghostty_*`
functions, and each one carries a symbol version. You can see it with
`readelf --dyn-syms`, which lists names such as
`ghostty_terminal_new@@GHOSTTY_VT_1.0`. The functions of 1.0 carry
`GHOSTTY_VT_1.0`, and each later minor release adds a node that lists only
the functions it added.

On macOS, the shared library also records a compatibility version (`X.0.0`)
and a current version (`X.Y.Z`). The macOS loader doesn't check them, so
follow the same rebuild rule there.

Our CI compares the ABI of every change to a baseline, so that the ABI
doesn't break by accident. See [`test/abi/`](https://github.com/ghostty-org/ghostty/tree/main/test/abi) for how
the check works. CI also runs `zig build test-lib-vt-abi` for Linux, macOS
and WebAssembly. It compares the library to reference files, called goldens,
in `src/terminal/c/abi/`: one manifest of the public types per target, and
`symbols.txt`, the list of public functions. The check fails on anything
that isn't an addition, such as a new function, a new type, a new enum value
or a new field at the end of a sized struct. Maintainers record an intentional
addition with `zig build update-lib-vt-abi`. You don't need to run either
step to package the library.

## Package Names

Please name the runtime package according to your distribution's policy
for shared libraries. Policies that name packages after the SONAME, such
as Debian's, give `libghostty-vt1` for every 1.x release. Distributions such as Fedora, Arch and nixpkgs
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
find_package(ghostty-vt 1.0 REQUIRED)
target_link_libraries(myapp PRIVATE ghostty-vt::ghostty-vt)
```

The CMake package accepts any installed version with the same major
version, as long as it is at least as new as the request. See [`dist/cmake/README.md`](dist/cmake/README.md) for the other CMake
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
- Every other linked project: in its package directory,
  `libghostty-vt-VERSION-deps/<hash>` in the unpacked dependency tarball
  (or `/tmp/offline-cache/p/<hash>` if you fetched the packages yourself),
  where `<hash>` is the entry's `hash` field.

[`deps/README.md`](deps/README.md) describes this file and the other
generated dependency lists.

## Testing

To run the library's tests, use the same offline setup as the build:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/build-cache \
zig build test-lib-vt \
  --system ../libghostty-vt-1.0.0-deps
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
headers 1.0.0, library 1.0.0
```

## Platform Support

| Tier | Meaning                    | Platforms                                                                                                                                         |
| ---- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | Built and tested in CI     | Linux x86_64 and aarch64 (glibc and musl), macOS 13+, iOS 13+, FreeBSD x86_64 and aarch64, Windows x86_64 (gnu ABI), wasm32-freestanding, Android |
| 2    | Built in CI but not tested | riscv32 and thumb freestanding, Windows aarch64 (gnu ABI)                                                                                         |
| 3    | Best effort, not in CI     | wasm32-wasi, illumos, 32-bit x86                                                                                                                  |

On Windows, the library is built for the gnu ABI, which is what Zig picks
by default. Programs built with MSVC can still link it through the import
library, and CI does this for the CMake examples. Each release also
publishes a prebuilt zip for Windows aarch64. It is built like the x86_64
zip but isn't run, so it stays Tier 2.

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
  Disabled features drop their implementation and any escape sequence
  handling (the sequences are still consumed and safely ignored). Their
  C API functions stay exported and return `GHOSTTY_UNSUPPORTED`, and
  programs can check for a feature with `ghostty_build_info`. See the `Features` struct in `src/terminal/build_options.zig`
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
