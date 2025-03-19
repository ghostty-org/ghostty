#!/bin/sh

# NOTE THIS IS A TEMPORARY SCRIPT TO SUPPORT PACKAGE MAINTAINERS.
#
# A future Zig version will hopefully fix the issue where
# `zig build --fetch` doesn't fetch transitive dependencies[1]. When that
# is resolved, we won't need any special machinery for the general use case
# at all and packagers can just use `zig build --fetch`.
#
# [1]: https://github.com/ziglang/zig/issues/20976

if [ -z ${ZIG_GLOBAL_CACHE_DIR+x} ]
then
  echo "must set ZIG_GLOBAL_CACHE_DIR!"
  exit 1
fi

# Go through each line of our build.zig.zon.txt and fetch it.
SCRIPT_PATH="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ZON_TXT_FILE="$SCRIPT_PATH/../../build.zig.zon.txt"
while IFS= read -r url; do
  echo "Fetching: $url"
  zig fetch "$url" >/dev/null 2>&1 || {
    echo "Failed to fetch: $url" >&2
    exit 1
  }
done < "$ZON_TXT_FILE"
