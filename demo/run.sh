#!/bin/bash
# Build and run the GhosttyDemo app as a proper .app bundle
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="GhosttyDemo"
BUILD_DIR="$SCRIPT_DIR/.build/debug"

swift build

APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"

mkdir -p "$APP_MACOS"
cp "$BUILD_DIR/$APP_NAME" "$APP_MACOS/$APP_NAME"

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
    <key>NSAppleEventsUsageDescription</key>
    <string>GhosttyDemo needs to control Ghostty via AppleScript to manage terminal windows.</string>
    <key>NSAppleScriptEnabled</key>
    <true/>
</dict>
</plist>
EOF

# Entitlements for accessibility
cat > "$BUILD_DIR/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.device.api</key>
    <true/>
</dict>
</plist>
EOF

# Sign with entitlements (uses ad-hoc signature since we don't have a cert)
codesign --force --sign - --entitlements "$BUILD_DIR/entitlements.plist" "$APP_BUNDLE" 2>/dev/null || true

echo "Launching $APP_NAME..."
open "$APP_BUNDLE"
