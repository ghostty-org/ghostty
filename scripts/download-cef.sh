#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# Download CEF (Chromium Embedded Framework) for macOS ARM64
# Used by the embedded browser feature in Ghostties
# ─────────────────────────────────────────────────────────────────────

CEF_PLATFORM="macosarm64"
CEF_DIST="standard"
CEF_DIR="vendor/cef"
CEF_INDEX_URL="https://cef-builds.spotifycdn.com/index.json"
CEF_BASE_URL="https://cef-builds.spotifycdn.com"

# ─── Resolve version ────────────────────────────────────────────────
# Query the CEF builds API for the latest stable macOS ARM64 version.
# The API returns JSON with platform keys; we need macosx_arm64.
resolve_latest_stable() {
  echo "Querying CEF builds API for latest stable macOS ARM64 version..."
  local json
  json=$(curl -sfSL "$CEF_INDEX_URL") || {
    echo "ERROR: Failed to fetch CEF builds index from $CEF_INDEX_URL" >&2
    exit 1
  }

  # Extract the first stable version for macosx_arm64
  # The JSON structure is: { "macosx_arm64": { "versions": [ { "channel": "stable", "cef_version": "...", "chromium_version": "...", "files": [...] }, ... ] } }
  local version_info
  version_info=$(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
platform = data.get('macosarm64', data.get('macosx_arm64', {}))
for v in platform.get('versions', []):
    if v.get('channel') == 'stable':
        # Find the standard distribution file
        sha = ''
        for f in v.get('files', []):
            if f.get('type') == 'standard':
                sha = f.get('sha1', '')  # Some have sha1 only
                break
        print(v['cef_version'])
        print(v.get('chromium_version', ''))
        print(sha)
        break
") || {
    echo "ERROR: Failed to parse CEF builds index JSON" >&2
    exit 1
  }

  CEF_VERSION=$(echo "$version_info" | sed -n '1p')
  CHROMIUM_VERSION=$(echo "$version_info" | sed -n '2p')

  if [ -z "$CEF_VERSION" ]; then
    echo "ERROR: Could not find a stable macOS ARM64 CEF version in the builds index" >&2
    exit 1
  fi

  echo "Found CEF $CEF_VERSION (Chromium $CHROMIUM_VERSION)"
}

resolve_latest_stable

# ─── Check existing installation ────────────────────────────────────
if [ -f "$CEF_DIR/.version" ]; then
  EXISTING_VERSION=$(cat "$CEF_DIR/.version")
  if [ "$EXISTING_VERSION" = "$CEF_VERSION" ]; then
    echo "CEF already downloaded (version $CEF_VERSION)"
    exit 0
  fi
  echo "Existing CEF version $EXISTING_VERSION differs from target $CEF_VERSION"
  echo "Removing old installation..."
  rm -rf "$CEF_DIR"
fi

# ─── Build download URL ─────────────────────────────────────────────
# Filename format: cef_binary_<cef_version>+chromium-<chromium_version>_<platform>.tar.bz2
CEF_FILENAME="cef_binary_${CEF_VERSION}+chromium-${CHROMIUM_VERSION}_${CEF_PLATFORM}.tar.bz2"
CEF_URL="${CEF_BASE_URL}/${CEF_FILENAME}"

echo ""
echo "Downloading CEF binary distribution..."
echo "  URL: $CEF_URL"
echo "  This is ~300MB, please be patient."
echo ""

# ─── Download ────────────────────────────────────────────────────────
TMPDIR_DL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DL"' EXIT

DOWNLOAD_PATH="${TMPDIR_DL}/${CEF_FILENAME}"
curl -fSL --progress-bar -o "$DOWNLOAD_PATH" "$CEF_URL" || {
  echo "ERROR: Download failed from $CEF_URL" >&2
  echo "Check that this CEF version is available for $CEF_PLATFORM." >&2
  exit 1
}

echo "Download complete. Size: $(du -h "$DOWNLOAD_PATH" | cut -f1)"

# ─── Verify checksum (fetch from API) ───────────────────────────────
echo "Fetching SHA-1 checksum from CEF builds API..."
EXPECTED_SHA1=$(curl -sfSL "$CEF_INDEX_URL" | python3 -c "
import json, sys
data = json.load(sys.stdin)
platform = data.get('macosarm64', data.get('macosx_arm64', {}))
for v in platform.get('versions', []):
    if v.get('channel') == 'stable':
        for f in v.get('files', []):
            if f.get('type') == 'standard':
                print(f.get('sha1', ''))
                break
        break
" 2>/dev/null || true)

if [ -n "$EXPECTED_SHA1" ]; then
  ACTUAL_SHA1=$(shasum -a 1 "$DOWNLOAD_PATH" | awk '{print $1}')
  if [ "$ACTUAL_SHA1" = "$EXPECTED_SHA1" ]; then
    echo "SHA-1 checksum verified: $ACTUAL_SHA1"
  else
    echo "ERROR: SHA-1 checksum mismatch!" >&2
    echo "  Expected: $EXPECTED_SHA1" >&2
    echo "  Actual:   $ACTUAL_SHA1" >&2
    exit 1
  fi
else
  echo "Warning: No SHA-1 checksum available from API, skipping verification."
fi

# ─── Remove macOS quarantine attribute ───────────────────────────────
# CEF archives downloaded from the internet get quarantined by macOS
xattr -d com.apple.quarantine "$DOWNLOAD_PATH" 2>/dev/null || true

# ─── Extract ─────────────────────────────────────────────────────────
echo "Extracting to $CEF_DIR/..."
mkdir -p "$CEF_DIR"

# Extract and strip the top-level directory from the archive
tar -xjf "$DOWNLOAD_PATH" -C "$CEF_DIR" --strip-components=1 || {
  echo "ERROR: Failed to extract archive" >&2
  rm -rf "$CEF_DIR"
  exit 1
}

# ─── Write version marker ───────────────────────────────────────────
echo "$CEF_VERSION" > "$CEF_DIR/.version"

echo ""
echo "CEF downloaded and extracted successfully."
echo "  Version:  CEF $CEF_VERSION"
echo "  Chromium: $CHROMIUM_VERSION"
echo "  Location: $CEF_DIR/"
echo "  Contents: $(find "$CEF_DIR" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ') top-level items"
