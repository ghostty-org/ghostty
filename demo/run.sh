#!/bin/bash
# Build and run the GhosttyDemo app as a proper .app bundle
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="GhosttyDemo"

# Kill existing instance
echo "Killing existing $APP_NAME..."
pkill -9 "$APP_NAME" 2>/dev/null || true
sleep 0.5

# Build
swift build

# Generate .app bundle at project root (not buried in .build/)
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp ".build/debug/$APP_NAME" "$APP_MACOS/$APP_NAME"

# Info.plist
cat > "$APP_CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>GhosttyDemo</string>
    <key>CFBundleDisplayName</key>
    <string>GhosttyDemo</string>
    <key>CFBundleIdentifier</key>
    <string>com.ghostty.demo</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>GhosttyDemo</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign
codesign --force --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "Launching $APP_NAME.app..."
open "$APP_BUNDLE"
