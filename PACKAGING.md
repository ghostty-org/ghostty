# Packaging Ghostty for Distribution

Ghostty relies on downstream package maintainers to distribute Ghostty to
end-users. This document provides guidance to package maintainers on how to
package Ghostty for distribution.

> [!IMPORTANT]
>
> This document is only accurate for the Ghostty source alongside it.
> **Do not use this document for older or newer versions of Ghostty!** If
> you are reading this document in a different version of Ghostty, please
> find the `PACKAGING.md` file alongside that version.

## Source Tarballs

Source tarballs with stable checksums are available for tagged releases
at `release.files.ghostty.org` in the following URL format where
`VERSION` is the version number with no prefix such as `1.0.0`:

```
https://release.files.ghostty.org/VERSION/ghostty-VERSION.tar.gz
https://release.files.ghostty.org/VERSION/ghostty-VERSION.tar.gz.minisig
```

Signature files are signed with
[minisign](https://jedisct1.github.io/minisign/)
using the following public key:

```
RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
```

**Tip source tarballs** are available on the
[GitHub releases page](https://github.com/ghostty-org/ghostty/releases/tag/tip).
Use the `ghostty-source.tar.gz` asset and _not the GitHub auto-generated
source tarball_. These tarballs are generated for every commit to
the `main` branch and are not associated with a specific version.

> [!WARNING]
>
> Source tarballs are _not the same_ as a Git checkout. Source tarballs
> contain some preprocessed files that allow building Ghostty with less
> dependencies. If you are building Ghostty from a Git checkout, the
> steps below are the same but they may require additional dependencies
> not listed here. See the `README.md` for more information on building
> from a Git checkout.
>
> For everyone except Ghostty developers, please use the source tarballs.
> We generate tip source tarballs for users following the development
> branch.

## Zig Version

[Zig](https://ziglang.org) is required to build Ghostty. Prior to Zig 1.0,
Zig releases often have breaking changes. Ghostty requires specific Zig versions
depending on the Ghostty version in order to build. To make things easier for
package maintainers, Ghostty always uses some _released_ version of Zig.

To find the version of Zig required to build Ghostty, check the `required_zig`
constant in `build.zig`. You don't need to know Zig to extract this information.
This version will always be an official released version of Zig.

For example, at the time of writing this document, Ghostty requires Zig 0.14.0.

## Building Ghostty

The following is a standard example of how to build Ghostty _for system
packages_. This is not the recommended way to build Ghostty for your
own system. For that, see the primary README.

1. First, we fetch our dependencies from the internet into a cached directory.
   This is the only step that requires internet access:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/offline-cache ./nix/build-support/fetch-zig-cache.sh
```

2. Next, we build Ghostty. This step requires no internet access:

```sh
DESTDIR=/tmp/ghostty \
zig build \
  --prefix /usr \
  --system /tmp/offline-cache/p \
  -Doptimize=ReleaseFast \
  -Dcpu=baseline
```

The build options are covered in the next section, but this will build
and install Ghostty to `/tmp/ghostty` with the prefix `/usr` (i.e. the
binary will be at `/tmp/ghostty/usr/bin/ghostty`). This style is common
for system packages which separate a build and install step, since the
install step can then be done with a `mv` or `cp` command (from `/tmp/ghostty`
to wherever the package manager expects it).

### Build Options

Ghostty uses the Zig build system. You can see all available build options by
running `zig build --help`. The following are options that are particularly
relevant to package maintainers:

- `--prefix`: The installation prefix. Combine with the `DESTDIR` environment
  variable to install to a temporary directory for packaging.

- `--system`: The path to the offline cache directory. This disables
  any package fetching from the internet. This flag also triggers all
  dependencies to be dynamically linked by default. This flag also makes
  the binary a PIE (Position Independent Executable) by default (override
  with `-Dpie`).

- `-Doptimize=ReleaseFast`: Build with optimizations enabled and safety checks
  disabled. This is the recommended build mode for distribution. I'd prefer
  a safe build but terminal emulators are performance-sensitive and the
  safe build is currently too slow. I plan to improve this in the future.
  Other build modes are available: `Debug`, `ReleaseSafe`, and `ReleaseSmall`.

- `-Dcpu=baseline`: Build for the "baseline" CPU of the target architecture.
  This avoids building for newer CPU features that may not be available on
  all target machines.

- `-Dtarget=$arch-$os-$abi`: Build for a specific target triple. This is
  often necessary for system packages to specify a specific minimum Linux
  version, glibc, etc. Run `zig targets` to a get a full list of available
  targets.

## WebAssembly (libghostty-vt)

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
