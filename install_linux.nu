#!/usr/bin/env nu

# Check if running as root
if ((id -u | into int) != 0) {
    echo "Please run as root (sudo)"
    exit 1
}

# Build and install (errors will automatically cause exit in nu)
zig build -Doptimize=ReleaseFast --prefix /usr install

# Create desktop entry
$"[Desktop Entry]
Version=1.0
Type=Application
Name=ghostty
Comment=Ghostty is a terminal emulator that differentiates itself by being fast, feature-rich, and native.
Exec=/usr/bin/ghostty
Categories=Development;
Terminal=false" | save --force /usr/share/applications/ghostty.desktop

# Set proper permissions
chmod 644 /usr/share/applications/ghostty.desktop

# Update desktop database
update-desktop-database /usr/share/applications
