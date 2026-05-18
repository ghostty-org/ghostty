#!/usr/bin/env bash
# Build the libghostty OpenGL embedding harness (Workstream A4).
#
# Requires:
#   - libghostty built first: zig build -Dapp-runtime=none
#     (produces ../zig-out/lib/ghostty-internal.so)
#   - GLFW 3 development files (pkg-config glfw3)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
lib="$root/zig-out/lib/ghostty-internal.so"

if [[ ! -f "$lib" ]]; then
  echo "error: $lib not found — run 'zig build -Dapp-runtime=none' first" >&2
  exit 1
fi

cc -std=c11 -Wall -Wextra -g \
  -o "$here/harness" \
  "$here/main.c" \
  -I "$root/include" \
  $(pkg-config --cflags glfw3) \
  "$lib" \
  $(pkg-config --libs glfw3) \
  -lpthread -lm -ldl \
  -Wl,-rpath,"$root/zig-out/lib"

echo "built: $here/harness"
