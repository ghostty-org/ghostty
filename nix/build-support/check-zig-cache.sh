#!/usr/bin/env bash
#
# This script checks if the build.zig.zon.nix file is up-to-date.
# If the `--update` flag is passed, it will update all necessary
# files to be up to date.
#
# The files owned by this are:
#
#   - build.zig.zon.nix
#   - build.zig.zon.txt
#   - build.zig.zon2json-lock
#
# All of these are auto-generated and should not be edited manually.

# Nothing in this script should fail.
set -e

WORK_DIR=$(mktemp -d)

if [[ ! "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
  echo "could not create temp dir"
  exit 1
fi

function cleanup {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

help() {
  echo ""
  echo "To fix, please (manually) re-run the script from the repository root,"
  echo "commit, and submit a PR with the update:"
  echo ""
  echo "    ./nix/build-support/check-zig-cache-hash.sh --update"
  echo "    git add build.zig.zon.nix"
  echo "    git commit -m \"nix: update build.zig.zon.nix\""
  echo ""
}

ROOT="$(realpath "$(dirname "$0")/../../")"
BUILD_ZIG_ZON="$ROOT/build.zig.zon"
BUILD_ZIG_ZON_LOCK="$ROOT/build.zig.zon2json-lock"
BUILD_ZIG_ZON_NIX="$ROOT/build.zig.zon.nix"
BUILD_ZIG_ZON_TXT="$ROOT/build.zig.zon.txt"

if [ -f "${BUILD_ZIG_ZON_NIX}" ]; then
  OLD_HASH=$(sha512sum "${BUILD_ZIG_ZON_NIX}" | awk '{print $1}')
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: build.zig.zon.nix missing."
  help
  exit 1
fi

rm -f "$BUILD_ZIG_ZON_LOCK"
zon2nix "$BUILD_ZIG_ZON" > "$WORK_DIR/build.zig.zon.nix"
alejandra --quiet "$WORK_DIR/build.zig.zon.nix"

NEW_HASH=$(sha512sum "$WORK_DIR/build.zig.zon.nix" | awk '{print $1}')

if [ "${OLD_HASH}" == "${NEW_HASH}" ]; then
  echo -e "\nOK: build.zig.zon.nix unchanged."
  exit 0
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: build.zig.zon.nix needs to be updated."
  echo ""
  echo "    * Old hash: ${OLD_HASH}"
  echo "    * New hash: ${NEW_HASH}"
  help
  exit 1
else
  jq -r '.[] .url' "$BUILD_ZIG_ZON_LOCK" | sort > "$BUILD_ZIG_ZON_TXT"
  mv "$WORK_DIR/build.zig.zon.nix" "$BUILD_ZIG_ZON_NIX"
  echo -e "\nOK: build.zig.zon.nix updated."
  exit 0
fi

