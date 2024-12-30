#!/bin/bash

# Set variables
APP_NAME="ghostty"
VERSION="v1.0.0" # TODO: Have to set this to take from github-action
echo "Using version: $VERSION"
ARCH="amd64"
BUILD_DIR="$(pwd)/build"
DEB_DIR="$BUILD_DIR/${APP_NAME}_${VERSION}_${ARCH}"
CACHE_DIR="/tmp/offline-cache"
DESTDIR="$DEB_DIR/usr"
BIN_DIR="$DESTDIR/bin"
DESKTOP_DIR="$DEB_DIR/usr/share/applications"

# Clean up old build directories
rm -rf "$BUILD_DIR"

# Step 1: Create directory structure
mkdir -p "$DEB_DIR/DEBIAN"
mkdir -p "$BIN_DIR"
mkdir -p "$DESKTOP_DIR"

# Step 2: Fetch dependencies (requires internet access)
echo "Setting up Zig cache directory..."
mkdir -p "$CACHE_DIR"

echo "Fetching Zig dependencies..."
export ZIG_GLOBAL_CACHE_DIR="$CACHE_DIR"
./nix/build-support/fetch-zig-cache.sh

# Step 3: Build the application
echo "Building $APP_NAME..."
zig build --prefix /usr --system "$CACHE_DIR/p" -Doptimize=ReleaseFast -Dcpu=baseline
if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Step 4: Verify that the binary was built successfully
if [ -f "/usr/bin/$APP_NAME" ]; then
    # Copy the binary to the destination directory
    cp "/usr/bin/$APP_NAME" "$BIN_DIR/"
else
    echo "Error: Binary not found at /usr/bin/$APP_NAME"
    exit 1
fi

# Step 5: Create DEBIAN/control file
echo "Creating control file..."
CONTROL_FILE="$DEB_DIR/DEBIAN/control"
cat <<EOF > "$CONTROL_FILE"
Package: $APP_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: Ronit Gandhi <ronitgandhi96@gmail.com>
Description: Ghostty - A fast, feature-rich, and cross-platform terminal emulator that uses platform-native UI and GPU acceleration.
EOF

# Step 6: Create .desktop file for application menu/search
echo "Creating .desktop file..."
DESKTOP_FILE="$DESKTOP_DIR/$APP_NAME.desktop"
cat <<EOF > "$DESKTOP_FILE"
[Desktop Entry]
Version=1.0
Name=Ghostty
Comment=A fast, feature-rich, and cross-platform terminal emulator that uses platform-native UI and GPU acceleration.
Exec=$APP_NAME
Icon=$APP_NAME
Terminal=true
Type=Application
Categories=Utility;System;
EOF

# Step 7: Set permissions
echo "Setting permissions..."
chmod -R 755 "$DEB_DIR"
chmod 644 "$CONTROL_FILE"
chmod 644 "$DESKTOP_FILE"
chmod +x "$BIN_DIR/$APP_NAME"  # Ensure the binary is executable

# Step 8: Build .deb package
echo "Building .deb package..."
dpkg-deb --build "$DEB_DIR"
if [ $? -eq 0 ]; then
    echo "$APP_NAME version $VERSION .deb package created successfully!"
    echo "File: $BUILD_DIR/${APP_NAME}_${VERSION}_${ARCH}.deb"
else
    echo "Failed to build .deb package!"
    exit 1
fi
