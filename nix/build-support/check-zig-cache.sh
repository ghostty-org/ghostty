#!/usr/bin/env bash
#
# Checks that the files generated from build.zig.zon are up to date, and
# exits with an error if any of them are not. Pass --update to regenerate
# them instead.
#
#   ./nix/build-support/check-zig-cache.sh           # check
#   ./nix/build-support/check-zig-cache.sh --update  # regenerate
#
# The files owned by this are:
#
#   - build.zig.zon.nix
#   - build.zig.zon.txt
#   - build.zig.zon.json
#   - flatpak/zig-packages.json
#   - build.zig.zon.lib-vt.txt (written by gen-lib-vt-deps.sh)
#   - build.zig.zon.lib-vt.third-party.json (written by gen-lib-vt-deps.sh)
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
  echo "    ./nix/build-support/check-zig-cache.sh --update"
  echo "    git add build.zig.zon.nix build.zig.zon.txt build.zig.zon.json flatpak/zig-packages.json build.zig.zon.lib-vt.txt build.zig.zon.lib-vt.third-party.json"
  echo "    git commit -m \"nix: update generated Zig dependency files\""
  echo ""
}

ROOT="$(realpath "$(dirname "$0")/../../")"
BUILD_ZIG_ZON="$ROOT/build.zig.zon"
BUILD_ZIG_ZON_NIX="$ROOT/build.zig.zon.nix"
BUILD_ZIG_ZON_TXT="$ROOT/build.zig.zon.txt"
BUILD_ZIG_ZON_JSON="$ROOT/build.zig.zon.json"
ZIG_PACKAGES_JSON="$ROOT/flatpak/zig-packages.json"
LIB_VT_TXT="$ROOT/build.zig.zon.lib-vt.txt"
LIB_VT_THIRD_PARTY="$ROOT/build.zig.zon.lib-vt.third-party.json"

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

if [ -f "${ZIG_PACKAGES_JSON}" ]; then
  OLD_HASH_FLATPAK=$(sha512sum "${ZIG_PACKAGES_JSON}" | awk '{print $1}')
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: flatpak/zig-packages.json missing."
  help
  exit 1
fi

if [ -f "${LIB_VT_TXT}" ]; then
  OLD_HASH_LIB_VT_TXT=$(sha512sum "${LIB_VT_TXT}" | awk '{print $1}')
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: build.zig.zon.lib-vt.txt missing."
  help
  exit 1
fi

if [ -f "${LIB_VT_THIRD_PARTY}" ]; then
  OLD_HASH_LIB_VT_THIRD_PARTY=$(sha512sum "${LIB_VT_THIRD_PARTY}" | awk '{print $1}')
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: build.zig.zon.lib-vt.third-party.json missing."
  help
  exit 1
fi

zon2nix "$BUILD_ZIG_ZON" --17 --nix "$WORK_DIR/build.zig.zon.nix" --txt "$WORK_DIR/build.zig.zon.txt" --json "$WORK_DIR/build.zig.zon.json" --flatpak "$WORK_DIR/zig-packages.json"
alejandra --quiet "$WORK_DIR/build.zig.zon.nix"
prettier --log-level warn --write "$WORK_DIR/build.zig.zon.json"
prettier --log-level warn --write "$WORK_DIR/zig-packages.json"

# Generate the libghostty-vt files from the new build.zig.zon.json, not the
# committed one. A change to build.zig.zon and its effect on the library's
# list are then checked in the same run.
"$ROOT/nix/build-support/gen-lib-vt-deps.sh" "$WORK_DIR/build.zig.zon.json" "$WORK_DIR/build.zig.zon.lib-vt.txt" "$WORK_DIR/build.zig.zon.lib-vt.third-party.json"
prettier --log-level warn --write "$WORK_DIR/build.zig.zon.lib-vt.third-party.json"

NEW_HASH_NIX=$(sha512sum "$WORK_DIR/build.zig.zon.nix" | awk '{print $1}')
NEW_HASH_TXT=$(sha512sum "$WORK_DIR/build.zig.zon.txt" | awk '{print $1}')
NEW_HASH_JSON=$(sha512sum "$WORK_DIR/build.zig.zon.json" | awk '{print $1}')
NEW_HASH_FLATPAK=$(sha512sum "$WORK_DIR/zig-packages.json" | awk '{print $1}')
NEW_HASH_LIB_VT_TXT=$(sha512sum "$WORK_DIR/build.zig.zon.lib-vt.txt" | awk '{print $1}')
NEW_HASH_LIB_VT_THIRD_PARTY=$(sha512sum "$WORK_DIR/build.zig.zon.lib-vt.third-party.json" | awk '{print $1}')

if [ "${OLD_HASH_NIX}" == "${NEW_HASH_NIX}" ] && [ "${OLD_HASH_TXT}" == "${NEW_HASH_TXT}" ] && [ "${OLD_HASH_JSON}" == "${NEW_HASH_JSON}" ] && [ "${OLD_HASH_FLATPAK}" == "${NEW_HASH_FLATPAK}" ] && [ "${OLD_HASH_LIB_VT_TXT}" == "${NEW_HASH_LIB_VT_TXT}" ] && [ "${OLD_HASH_LIB_VT_THIRD_PARTY}" == "${NEW_HASH_LIB_VT_THIRD_PARTY}" ]; then
  echo -e "\nOK: build.zig.zon.nix unchanged."
  echo -e "OK: build.zig.zon.txt unchanged."
  echo -e "OK: build.zig.zon.json unchanged."
  echo -e "OK: flatpak/zig-packages.json unchanged."
  echo -e "OK: build.zig.zon.lib-vt.txt unchanged."
  echo -e "OK: build.zig.zon.lib-vt.third-party.json unchanged."
  exit 0
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: one or more generated dependency files need to be updated.\n"
  echo "    * Old build.zig.zon.nix hash:         ${OLD_HASH_NIX}"
  echo "    * New build.zig.zon.nix hash:         ${NEW_HASH_NIX}"
  echo "    * Old build.zig.zon.txt hash:         ${OLD_HASH_TXT}"
  echo "    * New build.zig.zon.txt hash:         ${NEW_HASH_TXT}"
  echo "    * Old build.zig.zon.json hash:        ${OLD_HASH_JSON}"
  echo "    * New build.zig.zon.json hash:        ${NEW_HASH_JSON}"
  echo "    * Old flatpak/zig-packages.json hash: ${OLD_HASH_FLATPAK}"
  echo "    * New flatpak/zig-packages.json hash: ${NEW_HASH_FLATPAK}"
  echo "    * Old build.zig.zon.lib-vt.txt hash:  ${OLD_HASH_LIB_VT_TXT}"
  echo "    * New build.zig.zon.lib-vt.txt hash:  ${NEW_HASH_LIB_VT_TXT}"
  echo "    * Old build.zig.zon.lib-vt.third-party.json hash: ${OLD_HASH_LIB_VT_THIRD_PARTY}"
  echo "    * New build.zig.zon.lib-vt.third-party.json hash: ${NEW_HASH_LIB_VT_THIRD_PARTY}"
  help
  exit 1
else
  mv "$WORK_DIR/build.zig.zon.nix" "$BUILD_ZIG_ZON_NIX"
  echo -e "\nOK: build.zig.zon.nix updated."
  mv "$WORK_DIR/build.zig.zon.txt" "$BUILD_ZIG_ZON_TXT"
  echo -e "OK: build.zig.zon.txt updated."
  mv "$WORK_DIR/build.zig.zon.json" "$BUILD_ZIG_ZON_JSON"
  echo -e "OK: build.zig.zon.json updated."
  mv "$WORK_DIR/zig-packages.json" "$ZIG_PACKAGES_JSON"
  echo -e "OK: flatpak/zig-packages.json updated."
  mv "$WORK_DIR/build.zig.zon.lib-vt.txt" "$LIB_VT_TXT"
  echo -e "OK: build.zig.zon.lib-vt.txt updated."
  mv "$WORK_DIR/build.zig.zon.lib-vt.third-party.json" "$LIB_VT_THIRD_PARTY"
  echo -e "OK: build.zig.zon.lib-vt.third-party.json updated."
  exit 0
fi
