#!/usr/bin/env bash
#
# This script checks if the flatpak/zig-packages.json file is up-to-date.
# If the `--update` flag is passed, it will update all necessary
# files to be up to date.
#
# The files owned by this are:
#
#   - flatpak/zig-packages.json
#
# All of these are auto-generated and should not be edited manually.

# Nothing in this script should fail.
set -eu
set -o pipefail

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
  echo "    ./flatpak/build-support/check-zig-cache.sh --update"
  echo "    git add flatpak/zig-packages.json"
  echo "    git commit -m \"flatpak: update zig-packages.json\""
  echo ""
}

# Turn Nix's base64 hashes into regular hexadecimal form
decode_hash() {
  input=$1
  input=${input#sha256-}
  echo "$input" | base64 -d | od -vAn -t x1 | tr -d ' \n'
}

ROOT="$(realpath "$(dirname "$0")/../../")"
ZIG_PACKAGES_JSON="$ROOT/flatpak/zig-packages.json"
BUILD_ZIG_ZON_JSON="$ROOT/build.zig.zon.json"

if [ ! -f "${BUILD_ZIG_ZON_JSON}" ]; then
  echo -e "\nERROR: build.zig.zon2json-lock missing."
  help
  exit 1
fi

if [ -f "${ZIG_PACKAGES_JSON}" ]; then
  OLD_HASH=$(sha512sum "${ZIG_PACKAGES_JSON}" | awk '{print $1}')
fi

while read -r url sha256 dest; do
  src_type=archive
  sha256=$(decode_hash "$sha256")
  git_commit=
  if [[ "$url" =~ ^git\+* ]]; then
    src_type=git
    sha256=
    url=${url#git+}
    git_commit=${url##*#}
    url=${url%%/\?ref*}
    url=${url%%#*}
  fi

  jq \
    -nec \
    --arg type "$src_type" \
    --arg url "$url" \
    --arg git_commit "$git_commit" \
    --arg dest "$dest" \
    --arg sha256 "$sha256" \
    '{
      type: $type,
      url: $url,
      commit: $git_commit,
      dest: $dest,
      sha256: $sha256,
    } | with_entries(select(.value != ""))'
done < <(jq -rc 'to_entries[] | [.value.url, .value.hash, "vendor/p/\(.key)"] | @tsv' "$BUILD_ZIG_ZON_JSON") |
  jq -s '.' >"$WORK_DIR/zig-packages.json"

NEW_HASH=$(sha512sum "$WORK_DIR/zig-packages.json" | awk '{print $1}')

if [ "${OLD_HASH}" == "${NEW_HASH}" ]; then
  echo -e "\nOK: flatpak/zig-packages.json unchanged."
  exit 0
elif [ "${1:-}" != "--update" ]; then
  echo -e "\nERROR: flatpak/zig-packages.json needs to be updated."
  echo ""
  echo "    * Old hash: ${OLD_HASH}"
  echo "    * New hash: ${NEW_HASH}"
  help
  exit 1
else
  mv "$WORK_DIR/zig-packages.json" "$ZIG_PACKAGES_JSON"
  echo -e "\nOK: flatpak/zig-packages.json updated."
  exit 0
fi
