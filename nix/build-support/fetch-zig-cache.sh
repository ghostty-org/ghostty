#!/bin/sh

# Downloads Ghostty's Zig dependencies ahead of time, so the build itself
# can run without network access. This is mainly for package maintainers
# whose build environments are offline.
#
# Usage:
#
#   ZIG_GLOBAL_CACHE_DIR=<dir> ./nix/build-support/fetch-zig-cache.sh [LIST]
#
# LIST is a text file with one dependency URL per line. It defaults to
# deps/packages.txt, which lists every dependency of Ghostty. To package only
# libghostty-vt, pass deps/libghostty-vt.txt, which lists only what the
# library needs.
#
# Each package is unpacked into <dir>/p/<hash>. Point `zig build --system` at
# that directory to build with no network access.
#
# Example: build libghostty-vt offline.
#
#   # With network access:
#   ZIG_GLOBAL_CACHE_DIR=/tmp/offline-cache \
#     ./nix/build-support/fetch-zig-cache.sh deps/libghostty-vt.txt
#
#   # Later, without network access:
#   ZIG_GLOBAL_CACHE_DIR=/tmp/build-cache zig build \
#     --system /tmp/offline-cache/p \
#     -Demit-lib-vt -Demit-xcframework=false
#
# Give the offline build its own empty ZIG_GLOBAL_CACHE_DIR, as above. Zig
# 0.17 can crash with "reached unreachable code" when the default cache
# (~/.cache/zig) holds an archive of a package that the --system directory
# lacks. A fresh cache also ensures the build uses only the packages you
# fetched.
#
# Environment variables:
#
#   ZIG_GLOBAL_CACHE_DIR  Required. Where to put the packages.
#   ZIG_ZON_JSON          Optional. The file that maps each URL to its package
#                         hash. Defaults to deps/packages.json in this
#                         repository.
#
# Why this script exists
#
# Zig's own tools do not cover this yet:
#
#   - `zig build --fetch` does not download the dependencies of dependencies
#     (https://github.com/ziglang/zig/issues/20976).
#   - As of Zig 0.17, `zig fetch <url>` only saves a compressed archive,
#     p/<hash>.tar.gz. `zig build --system` only reads unpacked directories,
#     so it cannot use that archive.
#
# Instead, this script writes a temporary, empty Zig project that depends on
# every URL in LIST, then runs `zig build --fetch` on it. Zig unpacks each
# package exactly as a normal build would. Once Zig fixes the issues above,
# this script can go away.

set -e

if [ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
  echo "ZIG_GLOBAL_CACHE_DIR must be set to the directory to fetch into." >&2
  echo "usage: ZIG_GLOBAL_CACHE_DIR=<dir> $0 [LIST]" >&2
  exit 1
fi

SCRIPT_PATH="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$SCRIPT_PATH/../.."
ZON_TXT_FILE="${1:-$ROOT/deps/packages.txt}"
ZON_JSON_FILE="${ZIG_ZON_JSON:-$ROOT/deps/packages.json}"

if [ ! -f "$ZON_TXT_FILE" ]; then
  echo "dependency list not found: $ZON_TXT_FILE" >&2
  exit 1
fi
if [ ! -f "$ZON_JSON_FILE" ]; then
  echo "dependency hashes not found: $ZON_JSON_FILE" >&2
  exit 1
fi

# The temporary project builds from its own directory, so make the cache path
# absolute before changing directories.
mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"
ZIG_GLOBAL_CACHE_DIR="$(CDPATH='' cd -- "$ZIG_GLOBAL_CACHE_DIR" && pwd)"
export ZIG_GLOBAL_CACHE_DIR
PKG_DIR="$ZIG_GLOBAL_CACHE_DIR/p"

PROJECT_DIR="$(mktemp -d)"
trap 'rm -rf "$PROJECT_DIR"' EXIT

# Build an index with one "<hash><TAB><url>" line per package. This reads
# deps/packages.json as text rather than parsing it, so the script needs only
# POSIX tools. That works because the file is generated and formatted by
# prettier: each package is a key indented by two spaces, followed by its
# "url" field indented by four.
awk '
  /^  "[^"]*": \{/ { key = $0; sub(/^  "/, "", key); sub(/".*/, "", key) }
  /^    "url": "/ {
    url = $0
    sub(/^    "url": "/, "", url)
    sub(/",?[[:space:]]*$/, "", url)
    print key "\t" url
  }
' "$ZON_JSON_FILE" >"$PROJECT_DIR/index"

cat >"$PROJECT_DIR/build.zig" <<'EOF'
pub fn build(_: *@import("std").Build) void {}
EOF

count=0
{
  # Zig requires a fingerprint that matches the package name. This is the
  # value Zig computes for the name fetch_shim.
  printf '.{\n'
  printf '    .name = .fetch_shim,\n'
  printf '    .version = "0.0.0",\n'
  printf '    .fingerprint = 0x5d559c7454d9543b,\n'
  printf '    .paths = .{""},\n'
  printf '    .dependencies = .{\n'
  while IFS= read -r url || [ -n "$url" ]; do
    [ -z "$url" ] && continue
    hash="$(awk -F '\t' -v url="$url" '$2 == url { print $1; exit }' "$PROJECT_DIR/index")"
    if [ -z "$hash" ]; then
      echo "no hash for $url in $ZON_JSON_FILE" >&2
      exit 1
    fi
    echo "Fetching: $url" >&2
    printf '        .d%d = .{ .url = "%s", .hash = "%s" },\n' "$count" "$url" "$hash"
    count=$((count + 1))
  done <"$ZON_TXT_FILE"
  printf '    },\n'
  printf '}\n'
} >"$PROJECT_DIR/build.zig.zon"

(
  cd "$PROJECT_DIR"
  zig build --fetch=needed --pkg-dir "$PKG_DIR" --cache-dir "$PROJECT_DIR/.zig-cache"
) || {
  echo "Failed to fetch the packages in $ZON_TXT_FILE" >&2
  exit 1
}
