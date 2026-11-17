#!/usr/bin/env bash
# Test an installed wasm32-emscripten archive with static and dynamic linking.
set -euo pipefail
prefix=$(cd "${1:-zig-out}" && pwd)
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
source_file="$root/src/terminal/c/emscripten-test.c"
archive="$prefix/lib/libghostty-vt.a"
flags=(
    -O2 -Wall -Wextra -Werror -UNDEBUG -I"$prefix/include"
    -sALLOW_MEMORY_GROWTH=1 -sEXIT_RUNTIME=1
    -sUSE_OFFSET_CONVERTER=1 -sSTACK_SIZE=1048576
)
emcc "$source_file" "$archive" "${flags[@]}" -o "$work/static.js"
run_test() {
    local output
    output=$(cd "$work" && timeout 120 node "$1")
    printf '%s\n' "$output"
    # Emscripten preload failures can exit zero before main is called.
    [[ "$output" == *"Emscripten allocation tests passed"* ]]
}
run_test static.js
emcc -O2 -sSIDE_MODULE=1 -shared -o "$work/libghostty-vt.so" \
    -Wl,--whole-archive "$archive" -Wl,--no-whole-archive
emcc "$source_file" "${flags[@]}" -DTEST_DYNAMIC -sMAIN_MODULE=1 \
    --preload-file "$work/libghostty-vt.so@/libghostty-vt.so" -o "$work/dynamic.js"
run_test dynamic.js
