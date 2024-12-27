#!/bin/bash

# Exit on any error
set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

# Build and install
zig build -Doptimize=ReleaseFast --prefix /usr install

# Create desktop entry
cat > /usr/share/applications/ghostty.desktop << 'EOL'
[Desktop Entry]
Version=1.0
Type=Application
Name=ghostty
Comment=Ghostty is a terminal emulator that differentiates itself by being fast, feature-rich, and native.
Exec=/usr/bin/ghostty
Categories=Development;
Terminal=false
EOL

# Set perms
chmod 644 /usr/share/applications/ghostty.desktop

# Update desktop database
update-desktop-database /usr/share/applications
