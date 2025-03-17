ARG DISTRO_VERSION="12"
FROM docker.io/library/debian:${DISTRO_VERSION}

# Install Dependencies
RUN DEBIAN_FRONTEND="noninteractive" apt-get -qq update && \
    apt-get -qq -y --no-install-recommends install \
    # Build Tools
    build-essential \
    libbz2-dev \
    libonig-dev \
    libxml2-utils \
    lintian \
    lsb-release \
    libxml2-utils \
    pandoc \
    wget \
    # Ghostty Dependencies
    libadwaita-1-dev \
    libgtk-4-dev && \
    # TODO: Add when this is updated to Debian 13++
    # gtk4-layer-shell
    # Clean up for better caching
    rm -rf /var/lib/apt/lists/*

# work around the fact that Debian 12 doesn't ship a pkg-config file for bzip2
RUN . /etc/os-release; if [ $VERSION_ID -le 12 ]; then ln -s libbz2.so /usr/lib/$(gcc -dumpmachine)/libbzip2.so; fi

# Install zig
# https://ziglang.org/download/
ARG ZIG_VERSION="0.14.0"
RUN wget -q "https://ziglang.org/download/$ZIG_VERSION/zig-linux-$(uname -m)-$ZIG_VERSION.tar.xz" && \
    tar -xf "zig-linux-$(uname -m)-$ZIG_VERSION.tar.xz" -C /opt && \
    rm zig-linux-* && \
    ln -s "/opt/zig-linux-$(uname -m)-$ZIG_VERSION/zig" /usr/local/bin/zig

WORKDIR /src

COPY ./dist/linux /src/dist/linux
COPY ./images /src/images
COPY ./include /src/include
COPY ./pkg /src/pkg
COPY ./po /src/po
COPY ./nix /src/nix
COPY ./vendor /src/vendor
COPY ./build.zig /src/build.zig
COPY ./build.zig.zon /src/build.zig.zon
COPY ./build.zig.zon.txt /src/build.zig.zon.txt

RUN ZIG_GLOBAL_CACHE_DIR=/zig/global-cache ./nix/build-support/fetch-zig-cache.sh

COPY ./src /src/src

# Debian 12 doesn't have gtk4-layer-shell, so we have to manually compile it ourselves
RUN zig build -Doptimize=Debug -Dcpu=baseline -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -fno-sys=blueprint-compiler --system /zig/global-cache/p

