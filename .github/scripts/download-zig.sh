#!/usr/bin/env bash
#
# Download a Zig release tarball from the community mirrors and verify it.
#
#   download-zig.sh VERSION OUTPUT [TARGET]
#
# TARGET defaults to "$(uname -m)-linux". The tarball is written to OUTPUT
# only once its signature has been verified, so OUTPUT is never a partial or
# unverified file.
#
# Mirrors are tried in random order, with ziglang.org itself last, and a
# mirror that is unreachable or too slow is skipped rather than waited on.
# Every download is checked with minisign against the Zig Software
# Foundation's public key, and the signature's trusted comment must name the
# file that was asked for, so a mirror cannot substitute another release.
#
# See https://ziglang.org/download/community-mirrors/
#
# Requires: bash, curl, minisign, shuf.

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 VERSION OUTPUT [TARGET]" >&2
  exit 2
fi

version=$1
output=$2
target=${3:-$(uname -m)-linux}
file="zig-${target}-${version}.tar.xz"

# https://ziglang.org/download/
public_key="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"

# Used when the canonical list cannot be fetched, which is likely to be the
# case exactly when ziglang.org is having trouble.
fallback_mirrors=(
  https://pkg.hexops.org/zig
  https://zigmirror.hryx.net/zig
  https://zig.linus.dev/zig
  https://zig.squirl.dev
  https://zig.mirror.mschae23.de/zig
  https://ziglang.freetls.fastly.net
  https://zig.tilok.dev
  https://zig-mirror.tsimnet.eu/zig
  https://zig.karearl.com/zig
  https://pkg.earth/zig
  https://fs.liujiacai.net/zigbuilds
  https://zigmirror.com
  https://zig.chainsafe.dev
  https://zig.savalione.com
  https://zig.bcr.ist
  https://zig.vortan.dev/zig
  https://pkg.alexrp.com/zig
)

# Give up on a server that cannot be reached quickly, or that drops below
# 100 KiB/s for 15 seconds, and move on to the next one.
curl_opts=(
  --fail
  --silent
  --show-error
  --location
  --connect-timeout 10
  --speed-limit 102400
  --speed-time 15
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if curl "${curl_opts[@]}" --max-time 20 \
  --output "$work/mirrors.txt" \
  https://ziglang.org/download/community-mirrors.txt; then
  mapfile -t mirrors < <(grep -E '^https://' "$work/mirrors.txt" | shuf)
else
  echo "unable to fetch the mirror list, using the built-in one" >&2
  mirrors=()
fi
if [ "${#mirrors[@]}" -eq 0 ]; then
  mapfile -t mirrors < <(printf '%s\n' "${fallback_mirrors[@]}" | shuf)
fi

# Mirrors serve every file flat under their base URL; ziglang.org itself keeps
# releases in a directory per version.
urls=()
for mirror in "${mirrors[@]}"; do
  urls+=("${mirror%/}/${file}")
done
urls+=("https://ziglang.org/download/${version}/${file}")

for url in "${urls[@]}"; do
  echo "trying ${url}" >&2
  rm -f "$work/$file" "$work/$file.minisig"

  if ! curl "${curl_opts[@]}" --output "$work/$file" "${url}?source=ghostty-ci" ||
    ! curl "${curl_opts[@]}" --output "$work/$file.minisig" "${url}.minisig?source=ghostty-ci"; then
    echo "download failed from ${url}" >&2
    continue
  fi

  if ! comment=$(minisign -V -Q -P "$public_key" -m "$work/$file" -x "$work/$file.minisig"); then
    echo "signature verification failed for ${url}" >&2
    continue
  fi

  # The trusted comment is signed too, and names the file the signature was
  # made for. Without this check a mirror could serve a different, validly
  # signed tarball under this name.
  if ! grep -q -E "(^|[[:space:]])file:${file//./\\.}([[:space:]]|$)" <<<"$comment"; then
    echo "signature from ${url} is for a different file: ${comment}" >&2
    continue
  fi

  mv "$work/$file" "$output"
  echo "downloaded and verified ${file} from ${url}" >&2
  exit 0
done

echo "unable to download ${file} from any mirror" >&2
exit 1
