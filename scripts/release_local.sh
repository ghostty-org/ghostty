#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load credentials (required)
if [[ -f "$SCRIPT_DIR/.env.release.local" ]]; then
    source "$SCRIPT_DIR/.env.release.local"
else
    echo "ERROR: Missing $SCRIPT_DIR/.env.release.local" >&2
    echo "Copy .env.release.local.example and fill in your credentials" >&2
    exit 1
fi

# Config
APP_NAME="Ghostree"
BUILD_CONFIG="ReleaseLocal"
BUILD_DIR="$REPO_ROOT/macos/build/$BUILD_CONFIG"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
ENTITLEMENTS="$REPO_ROOT/macos/GhosttyReleaseLocal.entitlements"

# Required credentials from .env.release.local
: "${SIGN_IDENTITY:?SIGN_IDENTITY not set in .env.release.local}"
: "${NOTARYTOOL_PROFILE:?NOTARYTOOL_PROFILE not set in .env.release.local}"

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

build_app() {
    log "Building $APP_NAME..."
    cd "$REPO_ROOT"
    zig build -Doptimize=ReleaseFast
}

sign_sparkle() {
    log "Signing Sparkle framework components..."
    local sparkle="$APP_PATH/Contents/Frameworks/Sparkle.framework"
    [[ -d "$sparkle" ]] || return 0  # Skip if no Sparkle

    # Sign in dependency order
    codesign -f -s "$SIGN_IDENTITY" -o runtime "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    codesign -f -s "$SIGN_IDENTITY" -o runtime "$sparkle/Versions/B/XPCServices/Installer.xpc"
    codesign -f -s "$SIGN_IDENTITY" -o runtime "$sparkle/Versions/B/Autoupdate"
    codesign -f -s "$SIGN_IDENTITY" -o runtime "$sparkle/Versions/B/Updater.app"
    codesign -f -s "$SIGN_IDENTITY" -o runtime "$sparkle"
}

sign_app() {
    log "Signing app bundle..."
    codesign -f -s "$SIGN_IDENTITY" -o runtime --entitlements "$ENTITLEMENTS" "$APP_PATH"

    log "Verifying signature..."
    codesign -vvv --deep --strict "$APP_PATH"
}

create_dmg() {
    log "Creating DMG..."
    rm -f "$DMG_PATH"

    # Use hdiutil (always available on macOS)
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
}

notarize() {
    log "Submitting for notarization..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
}

staple() {
    log "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler staple "$APP_PATH"
}

verify() {
    log "Verifying with Gatekeeper..."
    spctl -a -vv "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    xcrun stapler validate "$DMG_PATH"
}

main() {
    log "Starting $APP_NAME release build"

    build_app
    sign_sparkle
    sign_app
    create_dmg
    notarize
    staple
    verify

    log "Release complete!"
    log "DMG: $DMG_PATH"
    log "App: $APP_PATH"
}

main "$@"
