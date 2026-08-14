# Ghostty development image: Zig toolchain + Linux/GTK build dependencies.
# Used by the root Makefile (`make docker-image`, `make build`, `make test`, …).
#
# Zig version is read from build.zig.zon's minimum_zig_version unless
# ZIG_VERSION is passed as a build-arg.

ARG DISTRO_VERSION=13
FROM docker.io/library/debian:${DISTRO_VERSION}

ARG ZIG_VERSION=
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        blueprint-compiler \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        gettext \
        git \
        libadwaita-1-dev \
        libgtk-4-dev \
        libgtk4-layer-shell-dev \
        libonig-dev \
        libxml2-utils \
        pandoc \
        pkg-config \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Only need build.zig.zon to resolve the Zig version when ZIG_VERSION is unset.
COPY build.zig.zon /tmp/build.zig.zon

RUN set -eux; \
    if [ -z "${ZIG_VERSION}" ]; then \
      ZIG_VERSION="$(sed -n -E 's/^[[:space:]]*\.?minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' /tmp/build.zig.zon)"; \
    fi; \
    test -n "${ZIG_VERSION}"; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      aarch64|arm64) zig_arch=aarch64 ;; \
      x86_64|amd64) zig_arch=x86_64 ;; \
      *) echo "unsupported arch: ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/zig.tar.xz \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz"; \
    tar -xJf /tmp/zig.tar.xz -C /opt; \
    ln -sf "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
    rm -f /tmp/zig.tar.xz /tmp/build.zig.zon; \
    zig version

ENV ZIG_GLOBAL_CACHE_DIR=/zig-cache
VOLUME ["/zig-cache"]

CMD ["bash"]
