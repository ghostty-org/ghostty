# syntax=docker/dockerfile:1.7
#
# Reproducible build for libghostty + the Qt frontend (ghastty).
#
# Usage:
#   docker build -t ghastty .
#   docker run --rm -v "$PWD/out:/host-out" ghastty \
#     sh -c 'cp -a /out/. /host-out/'
#
# The runtime container does not ship a usable terminal — the Qt
# frontend wants a Wayland socket from the host. This image is for
# building (and CI testing) only.
#
# Stage layout:
#   - base       : Fedora + the Qt/Wayland deps both stages need
#   - zig        : pinned Zig toolchain (kept separate so a deps-only
#                  rebuild doesn't re-fetch Zig)
#   - libghostty : zig build of libghostty (-Dapp-runtime=none) + tests
#   - qt         : cmake build of qt/ against the libghostty artifact
#   - out        : minimal final stage holding only the built binaries
#
# Why Fedora rather than Debian? We need recent Qt 6 (>= 6.6 for the
# non-deprecated LayerShellQt screen API) and recent LayerShellQt.
# Fedora 42 ships Qt 6.9 and a current LayerShellQt; Debian trixie was
# stuck on Qt 6.8.2 + LayerShellQt 6.3.4 which deprecated
# setScreenConfiguration.

ARG FEDORA_VERSION=42

# Pinned to the project's minimum_zig_version (build.zig.zon).
ARG ZIG_VERSION=0.15.2

# ---------------------------------------------------------------------
# base — system packages shared across the build stages.
# ---------------------------------------------------------------------
FROM fedora:${FEDORA_VERSION} AS base

# Single dnf layer so the package cache is dropped before the next
# stage. The list mixes:
#   - build tooling (cmake, ninja, pkg-config, gcc, gcc-c++)
#   - libghostty build deps via Zig (most are vendored; libxml2-devel
#     is pulled in by the Sentry/breakpad path on Linux)
#   - Qt 6 modules the frontend uses (Gui, Widgets, OpenGL, DBus,
#     Multimedia, Svg) plus LayerShellQt
#   - native-protocol deps the frontend hits directly (xkbcommon,
#     wayland-client, wayland-scanner, xcb)
RUN dnf install -y --setopt=install_weak_deps=False \
      ca-certificates \
      curl \
      xz \
      tar \
      git \
      pkgconfig \
      cmake \
      ninja-build \
      gcc \
      gcc-c++ \
      qt6-qtbase-devel \
      qt6-qtbase-private-devel \
      qt6-qtmultimedia-devel \
      qt6-qtsvg-devel \
      layer-shell-qt-devel \
      libxkbcommon-devel \
      wayland-devel \
      wayland-protocols-devel \
      libxcb-devel \
      libxml2-devel \
    && dnf clean all

# ---------------------------------------------------------------------
# zig — fetch and unpack the pinned Zig toolchain.
#
# Kept separate from `base` so changing dnf deps does not invalidate
# the (large) Zig download layer.
# ---------------------------------------------------------------------
FROM base AS zig
ARG ZIG_VERSION

RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) zig_arch=x86_64 ;; \
      aarch64) zig_arch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    tarball="zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz"; \
    curl -fsSL -o "/tmp/${tarball}" \
      "https://ziglang.org/download/${ZIG_VERSION}/${tarball}"; \
    mkdir -p /opt/zig; \
    tar -xJf "/tmp/${tarball}" -C /opt/zig --strip-components=1; \
    rm "/tmp/${tarball}"; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

# ---------------------------------------------------------------------
# libghostty — Zig build of the libghostty shared library + tests.
#
# We mount the source tree rather than COPY so a `docker build` run
# does not bake the entire repo into this layer. Caches:
#   - /root/.cache/zig    : Zig's per-user cache (compiled deps)
#   - /src/.zig-cache     : project-local cache (incremental rebuilds)
# ---------------------------------------------------------------------
FROM zig AS libghostty
WORKDIR /src
COPY . /src

# `-Dapp-runtime=none` makes the Zig build emit libghostty (the .so
# our Qt frontend links against) and skips the GTK frontend. Tests
# run first so a regression in libghostty fails the build cleanly,
# rather than later in the slower Qt stage.
RUN --mount=type=cache,target=/root/.cache/zig \
    --mount=type=cache,target=/src/.zig-cache \
    set -eux; \
    zig build test -Dapp-runtime=none -Doptimize=Debug; \
    zig build -Dapp-runtime=none -Doptimize=ReleaseFast

# ---------------------------------------------------------------------
# qt — CMake build of the Qt frontend against the libghostty artifact.
# ---------------------------------------------------------------------
FROM libghostty AS qt
WORKDIR /src/qt

# The CMake project links against zig-out/lib/ghostty-internal.so and
# materialises libghostty.so as a build-tree symlink (see qt/CMakeLists.txt).
# `--install` lays the binary, .so, .desktop entry and icon into /out
# under the standard FHS layout (bin/, lib/, share/...).
RUN set -eux; \
    cmake -S /src/qt -B /src/qt/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release; \
    cmake --build /src/qt/build --parallel "$(nproc)"; \
    cmake --install /src/qt/build --prefix /out

# ---------------------------------------------------------------------
# out — only the final artifacts. Run this image to extract them.
# ---------------------------------------------------------------------
FROM fedora:${FEDORA_VERSION} AS out
COPY --from=qt /out /out

# Default command lists the artifacts so `docker run --rm ghastty`
# is informative without --entrypoint heroics.
CMD ["sh", "-c", "find /out -type f -o -type l | sort"]
