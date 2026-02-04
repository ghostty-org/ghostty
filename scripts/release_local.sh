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

# Worktrunk (pinned)
WORKTRUNK_VERSION="0.22.0"
WORKTRUNK_ASSET="worktrunk-aarch64-apple-darwin.tar.xz"
WORKTRUNK_URL="https://github.com/max-sixty/worktrunk/releases/download/v${WORKTRUNK_VERSION}/${WORKTRUNK_ASSET}"
WORKTRUNK_SHA256="1fd193d8ed95453dbeadd900035312a6df61ff3fad43dc85eb1a9f7b48895b3c"

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

embed_worktrunk() {
    log "Embedding Worktrunk CLI..."

    local tmpdir
    tmpdir="$(mktemp -d)"
    local archive="$tmpdir/$WORKTRUNK_ASSET"

    curl -L -o "$archive" "$WORKTRUNK_URL"

    local sum
    set -- $(shasum -a 256 "$archive")
    sum="$1"
    [[ "$sum" == "$WORKTRUNK_SHA256" ]] || err "Worktrunk sha256 mismatch: expected $WORKTRUNK_SHA256 got $sum"

    tar -xJf "$archive" -C "$tmpdir"

    local src="$tmpdir/worktrunk-aarch64-apple-darwin"
    [[ -f "$src/wt" ]] || err "Missing wt in extracted Worktrunk archive"
    [[ -f "$src/git-wt" ]] || err "Missing git-wt in extracted Worktrunk archive"

    local dst="$APP_PATH/Contents/Resources/worktrunk"
    mkdir -p "$dst"
    cp "$src/wt" "$dst/wt"
    cp "$src/git-wt" "$dst/git-wt"
    chmod +x "$dst/wt" "$dst/git-wt"

    rm -rf "$tmpdir"
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

sign_worktrunk() {
    local wt_dir="$APP_PATH/Contents/Resources/worktrunk"
    [[ -d "$wt_dir" ]] || return 0

    log "Signing Worktrunk CLI..."
    codesign -f -s "$SIGN_IDENTITY" -o runtime "$wt_dir/wt"
    codesign -f -s "$SIGN_IDENTITY" -o runtime "$wt_dir/git-wt"
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
    embed_worktrunk
    sign_sparkle
    sign_worktrunk
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
