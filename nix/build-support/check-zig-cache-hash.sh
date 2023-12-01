#!/usr/bin/env bash

# Nothing in this script should fail.
set -e

CACHE_HASH_FILE="$(realpath "$(dirname "$0")/../zig_cache_hash.nix")"

help() {
  echo ""
  echo "To fix, please (manually) re-run the script from the repository root,"
  echo "commit, and push the update:"
  echo ""
  echo "    ./nix/build-support/check-zig-cache-hash.sh --update"
  echo "    git add nix/zig_cache_hash.nix"
  echo "    git commit -m \"nix: update Zig cache hash\""
  echo "    git push"
  echo ""
}

if [ -f "${CACHE_HASH_FILE}" ]; then
  OLD_CACHE_HASH="$(nix eval --raw --file "${CACHE_HASH_FILE}")"
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: Zig cache hash file missing."
  help
  exit 1
fi

TMP_CACHE_DIR="$(mktemp --directory --suffix nix-zig-cache)"
# This is not 100% necessary in CI but is helpful when running locally to keep
# a local workstation clean.
trap 'rm -rf "${TMP_CACHE_DIR}"' EXIT

# Run Zig and download the cache to the temporary directory.
zig build --fetch --global-cache-dir "${TMP_CACHE_DIR}"

# Now, calculate the hash.
ZIG_CACHE_HASH="sha256-$(nix-hash --type sha256 --to-base64 "$(nix-hash --type sha256 "${TMP_CACHE_DIR}")")"

if [ "${OLD_CACHE_HASH}" == "${ZIG_CACHE_HASH}" ]; then
  echo -e "\nOK: Zig cache store hash unchanged."
  exit 0
elif [ "$1" != "--update" ]; then
  echo -e "\nERROR: The Zig cache store hash has updated."
  echo ""
  echo "    * Old hash: ${OLD_CACHE_HASH}"
  echo "    * New hash: ${ZIG_CACHE_HASH}"
  help
  exit 1
else
  echo -e "\nNew Zig cache store hash: ${ZIG_CACHE_HASH}"
fi

# Write out the cache file
cat > "${CACHE_HASH_FILE}" <<EOS
# This file is auto-generated! check build-support/check-zig-cache-hash.sh for
# more details.
"${ZIG_CACHE_HASH}"
EOS

echo -e "\nOK: Wrote new hash to file: ${CACHE_HASH_FILE}"
