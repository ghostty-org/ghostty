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
#   - build.zig.zon.json
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
  echo "    git add build.zig.zon.nix build.zig.zon.txt build.zig.zon.json"
  echo "    git commit -m \"nix: update build.zig.zon.nix build.zig.zon.txt build.zig.zon.json\""
  echo ""
}

ROOT="$(realpath "$(dirname "$0")/../../")"
BUILD_ZIG_ZON="$ROOT/build.zig.zon"
BUILD_ZIG_ZON_NIX="$ROOT/build.zig.zon.nix"
BUILD_ZIG_ZON_TXT="$ROOT/build.zig.zon.txt"
BUILD_ZIG_ZON_JSON="$ROOT/build.zig.zon.json"

if [ -f "${BUILD_ZIG_ZON_NIX}" ]; then
  OLD_HASH_NIX=$(sha512sum "${BUILD_ZIG_ZON_NIX}" | awk '{print $1}')
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: build.zig.zon.nix missing."
  help
  exit 1
fi

if [ -f "${BUILD_ZIG_ZON_TXT}" ]; then
  OLD_HASH_TXT=$(sha512sum "${BUILD_ZIG_ZON_TXT}" | awk '{print $1}')
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: build.zig.zon.txt missing."
  help
  exit 1
fi

if [ -f "${BUILD_ZIG_ZON_JSON}" ]; then
  OLD_HASH_JSON=$(sha512sum "${BUILD_ZIG_ZON_JSON}" | awk '{print $1}')
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: build.zig.zon.json missing."
  help
  exit 1
fi

zon2nix "$BUILD_ZIG_ZON" --nix "$WORK_DIR/build.zig.zon.nix" --txt "$WORK_DIR/build.zig.zon.txt" --json "$WORK_DIR/build.zig.zon.json"
alejandra --quiet "$WORK_DIR/build.zig.zon.nix"
prettier --write "$WORK_DIR/build.zig.zon.json"

NEW_HASH_NIX=$(sha512sum "$WORK_DIR/build.zig.zon.nix" | awk '{print $1}')
NEW_HASH_TXT=$(sha512sum "$WORK_DIR/build.zig.zon.txt" | awk '{print $1}')
NEW_HASH_JSON=$(sha512sum "$WORK_DIR/build.zig.zon.json" | awk '{print $1}')

if [ "${OLD_HASH_NIX}" == "${NEW_HASH_NIX}" ] && [ "${OLD_HASH_TXT}" == "${NEW_HASH_TXT}" ] && [ "${OLD_HASH_JSON}" == "${NEW_HASH_JSON}" ]; then
  echo -e "\nOK: build.zig.zon.nix unchanged."
  echo -e "OK: build.zig.zon.txt unchanged."
  echo -e "OK: build.zig.zon.json unchanged."
  exit 0
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: build.zig.zon.nix, build.zig.zon.txt, or build.zig.zon.json needs to be updated.\n"
  echo "    * Old build.zig.zon.nix hash:  ${OLD_HASH_NIX}"
  echo "    * New build.zig.zon.nix hash:  ${NEW_HASH_NIX}"
  echo "    * Old build.zig.zon.txt hash:  ${OLD_HASH_TXT}"
  echo "    * New build.zig.zon.txt hash:  ${NEW_HASH_TXT}"
  echo "    * Old build.zig.zon.json hash: ${OLD_HASH_JSON}"
  echo "    * New build.zig.zon.json hash: ${NEW_HASH_JSON}"
  help
  exit 1
else
  mv "$WORK_DIR/build.zig.zon.nix" "$BUILD_ZIG_ZON_NIX"
  echo -e "\nOK: build.zig.zon.nix updated."
  mv "$WORK_DIR/build.zig.zon.txt" "$BUILD_ZIG_ZON_TXT"
  echo -e "OK: build.zig.zon.txt updated."
  mv "$WORK_DIR/build.zig.zon.json" "$BUILD_ZIG_ZON_JSON"
  echo -e "OK: build.zig.zon.json updated."
  exit 0
fi

