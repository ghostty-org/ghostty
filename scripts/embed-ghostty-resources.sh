#!/bin/bash
# embed-ghostty-resources.sh — Called from Xcode "Run Script" build phase.
# Copies vendored themes and shell-integration from macos/Resources/ghostty
# into the built .app bundle.
#
# Why this exists:
#   The zig build is broken on macOS 26 (undefined libc symbols — see
#   Session 14 notes), which causes `zig-out/share/ghostty/themes/` to
#   come up empty. Xcode's folder reference at ../zig-out/share/ghostty
#   then bundles an empty themes dir, and the app falls back to the user's
#   config path and errors out with: theme "X" not found.
#
#   Until the zig build is fixed, these resources are vendored into the
#   repo at macos/Resources/ghostty/ and copied into the bundle here.
#
# Safe to re-run. Idempotent. Uses rsync to only copy changed files.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${REPO_ROOT}/macos/Resources/ghostty"
TERMINFO_SRC_DIR="${REPO_ROOT}/macos/Resources/terminfo"

BUILT_PRODUCTS_DIR="${BUILT_PRODUCTS_DIR:-${REPO_ROOT}/macos/build/Build/Products/Debug}"
PRODUCT_NAME="${PRODUCT_NAME:-Ghostties}"

APP_BUNDLE="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"
DST_DIR="${APP_BUNDLE}/Contents/Resources/ghostty"
TERMINFO_DST_DIR="${APP_BUNDLE}/Contents/Resources/terminfo"

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "error: App bundle not found at ${APP_BUNDLE}"
    exit 1
fi

if [ ! -d "${SRC_DIR}" ]; then
    echo "error: Vendored resources not found at ${SRC_DIR}"
    echo "       See macos/Resources/ghostty/README.md for context."
    exit 1
fi

if [ ! -d "${TERMINFO_SRC_DIR}" ]; then
    echo "error: Vendored terminfo not found at ${TERMINFO_SRC_DIR}"
    echo "       Resource-dir detection (src/os/resourcesdir.zig) walks up"
    echo "       from the binary looking for Contents/Resources/terminfo/78/xterm-ghostty"
    echo "       as a sentinel. Without it, the bundle cannot locate vendored themes."
    exit 1
fi

echo "=== embed-ghostty-resources.sh: Copying themes + shell-integration + terminfo ==="

mkdir -p "${DST_DIR}"

# --no-times / --checksum would be overkill; default rsync is fine.
# Trailing slash on src means "copy contents of", merging with existing dir.
rsync -a --delete "${SRC_DIR}/themes/"            "${DST_DIR}/themes/"
rsync -a --delete "${SRC_DIR}/shell-integration/" "${DST_DIR}/shell-integration/"

# terminfo is the sentinel Ghostty uses to locate its resource dir
# (src/os/resourcesdir.zig:79-85). Must exist at Contents/Resources/terminfo/78/xterm-ghostty
# for the walk-up detection to succeed in the Release build.
rsync -a --delete "${TERMINFO_SRC_DIR}/"          "${TERMINFO_DST_DIR}/"

theme_count=$(find "${DST_DIR}/themes" -maxdepth 1 -type f | wc -l | tr -d ' ')
echo "  themes:            ${theme_count} files"
echo "  shell-integration: $(ls "${DST_DIR}/shell-integration" | tr '\n' ' ')"
echo "  terminfo sentinel: $([ -e "${TERMINFO_DST_DIR}/78/xterm-ghostty" ] && echo present || echo MISSING)"
echo "=== embed-ghostty-resources.sh: Done ==="
