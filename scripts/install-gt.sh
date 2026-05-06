#!/usr/bin/env bash
# install-gt.sh — Build and install the gt CLI binary.
#
# Usage: bash scripts/install-gt.sh
#
# Installs to /usr/local/bin/gt if writable, otherwise ~/.local/bin/gt.
# Safe to run multiple times (idempotent).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_DIR="$REPO_ROOT/cli"
PRODUCT="gt"
BUILT_BINARY="$CLI_DIR/.build/arm64-apple-macosx/release/$PRODUCT"

echo "Building $PRODUCT (release)…"
(cd "$CLI_DIR" && swift build -c release --product "$PRODUCT") || {
    echo "Build failed." >&2
    exit 1
}

if [[ ! -f "$BUILT_BINARY" ]]; then
    echo "Binary not found at $BUILT_BINARY after build." >&2
    exit 1
fi

# Prefer /usr/local/bin; fall back to ~/.local/bin.
if [[ -w "/usr/local/bin" ]]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

INSTALL_PATH="$INSTALL_DIR/$PRODUCT"

# Create or replace the symlink idempotently.
ln -sf "$BUILT_BINARY" "$INSTALL_PATH"

echo "Installed: $INSTALL_PATH -> $BUILT_BINARY"

# Confirm the binary is reachable if INSTALL_DIR is on PATH.
if command -v "$PRODUCT" &>/dev/null; then
    FOUND_PATH="$(command -v "$PRODUCT")"
    echo "Verified: $PRODUCT is on PATH at $FOUND_PATH"
else
    echo ""
    echo "Note: $INSTALL_DIR is not on your PATH."
    echo "Add the following to your shell config (~/.zshrc or ~/.bashrc):"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi
