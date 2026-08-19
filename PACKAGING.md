# Packaging Guide

This document describes how Linux distribution packages (.deb, .rpm, .pkg.tar.zst) are built and released for Ghostty.

## Overview

Ghostty provides automated package builds for:

| Format | Distributions | Architectures |
|--------|--------------|---------------|
| `.deb` | Debian, Ubuntu, Linux Mint, Pop!_OS | amd64, arm64, armhf |
| `.rpm` | Fedora, RHEL, CentOS, openSUSE | x86_64, aarch64, armv7hl |
| `.pkg.tar.zst` | Arch Linux, Manjaro, EndeavourOS | x86_64, aarch64, armv7h |

In addition to these, Ghostty also supports:
- **Flatpak** - See `flatpak/` directory
- **Snap** - See `snap/` directory
- **Nix** - See `flake.nix`

## Release Triggers

Packages are automatically built when:

1. **Tag push** - A git tag matching `v[0-9]+.[0-9]+.[0-9]+*` is pushed (e.g., `v1.0.0`, `v1.2.3-rc1`)
2. **Release publish** - A GitHub Release is published via the UI
3. **Manual dispatch** - Triggered manually via GitHub Actions UI (for testing)

## Where to Find Artifacts

After a successful build, all packages are uploaded to the corresponding **GitHub Release** page:

```
https://github.com/opentreecz/terminal-ghostty/releases/tag/v<VERSION>
```

Each release includes:
- `ghostty_<VERSION>_amd64.deb`
- `ghostty_<VERSION>_arm64.deb`
- `ghostty_<VERSION>_armhf.deb`
- `ghostty-<VERSION>-1.<dist>.<arch>.rpm`
- `ghostty-<VERSION>-1-<arch>.pkg.tar.zst`
- `SHA256SUMS.txt` (checksums for all artifacts)

## Package Contents

All packages include:

- `/usr/bin/ghostty` - Main binary
- `/usr/share/applications/com.mitchellh.ghostty.desktop` - Desktop entry
- `/usr/share/metainfo/com.mitchellh.ghostty.metainfo.xml` - AppStream metadata
- `/usr/share/ghostty/` - Resources (terminfo, shell integration, themes)
- `/usr/lib/systemd/user/ghostty.service` - Systemd user service
- `/usr/share/dbus-1/services/com.mitchellh.ghostty.service` - D-Bus service
- `/usr/share/icons/hicolor/128x128/apps/com.mitchellh.ghostty.png` - Application icon

## Runtime Dependencies

| Debian/Ubuntu | Fedora/RHEL | Arch Linux |
|---------------|-------------|------------|
| libgtk-4-1 | gtk4 | gtk4 |
| libadwaita-1-0 | libadwaita | libadwaita |
| libfontconfig1 | fontconfig | fontconfig |
| libfreetype6 | freetype | freetype2 |
| libharfbuzz0b | harfbuzz | harfbuzz |
| libpng16-16 | libpng | libpng |
| zlib1g | zlib | zlib |

## Building Packages Locally

### Prerequisites

- Zig >= 0.16.0 (see [ziglang.org/download](https://ziglang.org/download/))
- Build dependencies for your distribution (see `packaging/debian/control` or `packaging/rpm/ghostty.spec`)

### Cross-Compilation with Zig

Zig has excellent built-in cross-compilation support. To build for a different architecture:

```bash
# Build for aarch64
zig build -Doptimize=ReleaseFast -Dpie=true -Dtarget=aarch64-linux-gnu

# Build for armhf
zig build -Doptimize=ReleaseFast -Dpie=true -Dtarget=arm-linux-gnueabihf

# Build for native (x86_64)
zig build -Doptimize=ReleaseFast -Dpie=true
```

### Build .deb locally

```bash
# Install dependencies (Debian/Ubuntu)
sudo apt-get install pkg-config libgtk-4-dev libadwaita-1-dev \
  libfontconfig1-dev libfreetype6-dev libharfbuzz-dev libpng-dev \
  zlib1g-dev libbz2-dev libonig-dev

# Build
zig build -Doptimize=ReleaseFast -Dpie=true

# Package (see .github/workflows/release-packages.yml for full steps)
```

### Build .rpm locally

```bash
# Install dependencies (Fedora)
sudo dnf install pkg-config gtk4-devel libadwaita-devel fontconfig-devel \
  freetype-devel harfbuzz-devel libpng-devel zlib-devel bzip2-devel \
  oniguruma-devel rpm-build

# Build and package
zig build -Doptimize=ReleaseFast -Dpie=true
rpmbuild -bb packaging/rpm/ghostty.spec
```

### Build Arch package locally

```bash
# Install dependencies
sudo pacman -S zig pkg-config gtk4 libadwaita fontconfig freetype2 \
  harfbuzz libpng zlib bzip2 oniguruma

# Build with makepkg
cd packaging/arch
makepkg -sf
```

## Testing the Workflow

To test the release workflow without creating a real release:

1. Go to **Actions** > **Release Linux Packages**
2. Click **Run workflow**
3. Enter a version number (e.g., `0.0.1-test`)
4. Click **Run workflow**

Artifacts will be available for download from the workflow run (not attached to a release).

## Dependabot

This project uses [Dependabot](https://docs.github.com/en/code-security/dependabot) to keep dependencies up to date:

- **GitHub Actions** - Checked daily, grouped into a single PR

### Zig Dependencies

Zig package ecosystem is not yet supported by Dependabot. Dependencies in `build.zig.zon` must be updated manually. Track progress at: https://github.com/dependabot/dependabot-core/issues/6746

### Reviewing Dependabot PRs

1. Check the PR description for changelog/compatibility notes
2. Ensure CI passes (the existing CI workflow runs full test matrix)
3. Merge if all checks pass

## Troubleshooting

### Common Build Failures

| Issue | Solution |
|-------|----------|
| Zig version mismatch | Ensure Zig >= 0.16.0 is installed |
| Missing GTK4 headers | Install `libgtk-4-dev` (Debian) or `gtk4-devel` (Fedora) |
| Submodule not initialized | Run `git submodule update --init --recursive` |
| Cross-compilation failure | Zig handles cross-compilation natively; check target triple |
| Out of memory during build | Zig builds can use significant RAM; ensure at least 4GB available |

### Architecture Notes

- **amd64/x86_64**: Native build on GitHub Actions runners
- **arm64/aarch64**: Cross-compiled by Zig (no QEMU needed for compilation)
- **armhf/armv7h**: Cross-compiled by Zig (no QEMU needed for compilation)

Note: While Zig cross-compiles without QEMU, system library headers for the target architecture may still be needed for linking against system libraries (GTK4, etc.).

## Packaging File Locations

```
packaging/
├── arch/
│   └── PKGBUILD          # Arch Linux package definition
├── debian/
│   ├── compat            # Debhelper compatibility level
│   ├── control           # Package metadata and dependencies
│   ├── copyright         # License information (MIT)
│   └── rules             # Build rules
└── rpm/
    └── ghostty.spec      # RPM specification file
```

## Related Packaging

- **Flatpak**: `flatpak/com.mitchellh.ghostty.yml`
- **Snap**: `snap/snapcraft.yaml`
- **Nix**: `flake.nix`, `default.nix`
- **Docker (Debian)**: `src/build/docker/debian/Dockerfile`

## Workflow File

The main workflow file is located at:
```
.github/workflows/release-packages.yml
```
