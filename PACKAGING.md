# Packaging Ghostty for Distribution

Ghostty relies on downstream package maintainers to distribute Ghostty to
end-users. This document provides guidance to package maintainers on how to
package Ghostty for distribution.

> [!NOTE]
>
> While Ghostty went through an extensive private beta testing period,
> packaging Ghostty is immature and may require additional build script
> tweaks and documentation improvement. I'm extremely motivated to work with
> package maintainers to improve the packaging process. Please open issues
> to discuss any packaging issues you encounter.

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

## Zig Version

[Zig](https://ziglang.org) is required to build Ghostty. Prior to Zig 1.0,
Zig releases often have breaking changes. Ghostty requires specific Zig versions
depending on the Ghostty version in order to build. To make things easier for
package maintainers, Ghostty always uses some _released_ version of Zig.

To find the version of Zig required to build Ghostty, check the `required_zig`
constant in `build.zig`. You don't need to know Zig to extract this information.
This version will always be an official released version of Zig.

For example, at the time of writing this document, Ghostty requires Zig 0.13.0.

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

> [!NOTE]
>
> **Version 1.1.1 and 1.1.2 are missing `fetch-zig-cache.sh`.** This was
> an oversight on the release process. You can use the script from version
> 1.1.0 to fetch the Zig cache for these versions. Future versions will
> restore the script.

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

> [!WARNING]
>
> **The GLFW runtime is not meant for distribution.** The GLFW runtime
> (`-Dapp-runtime=glfw`) is meant for development and testing only. It is
> missing many features, has known memory leak scenarios, known crashes,
> and more. Please do not package the GLFW-based Ghostty runtime for
> distribution.
