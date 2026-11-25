ARG DISTRO_VERSION="13"
FROM docker.io/library/debian:${DISTRO_VERSION}

# Install Dependencies
RUN DEBIAN_FRONTEND="noninteractive" apt-get -qq update && \
    apt-get -qq -y --no-install-recommends install \
    # Build Tools
    blueprint-compiler \
    build-essential \
    curl \
    libbz2-dev \
    libonig-dev \
    libxml2-utils \
    lintian \
    lsb-release \
    minisign \
    libxml2-utils \
    pandoc \
    # Ghostty Dependencies
    libadwaita-1-dev \
    libgtk-4-dev \
    libgtk4-layer-shell-dev && \
    # Clean up for better caching
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY ./build.zig ./build.zig.zon /src/
COPY ./.github/scripts/download-zig.sh /usr/local/bin/

# Install zig from the community mirrors
# https://ziglang.org/download/community-mirrors/

RUN export ZIG_VERSION=$(sed -n -E 's/^\s*\.?minimum_zig_version\s*=\s*"([^"]+)".*/\1/p' build.zig.zon) && \
    download-zig.sh "$ZIG_VERSION" /tmp/zig.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    rm /tmp/zig.tar.xz && \
    ln -s "/opt/zig-$(uname -m)-linux-$ZIG_VERSION/zig" /usr/local/bin/zig

COPY . /src

RUN zig build \
    -Doptimize=Debug \
    -Dcpu=baseline

RUN ./zig-out/bin/ghostty +version
