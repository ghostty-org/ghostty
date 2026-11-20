#!/usr/bin/env bash
# Test an installed wasm32-emscripten archive with static and dynamic linking.
set -euo pipefail
prefix=$(cd "${1:-zig-out}" && pwd)
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
source_file="$root/example/c-vt-emscripten/src/main.c"
archive="$prefix/lib/libghostty-vt.a"
flags=(
    -O2 -Wall -Wextra -Werror -Wno-error=version-check -DNDEBUG -I"$prefix/include"
    -sALLOW_MEMORY_GROWTH=1 -sEXIT_RUNTIME=1
    -sSTACK_SIZE=1048576
)
thread_flags=()
dynamic_flags=()
case "${2:-}" in
    "") ;;
    --threads)
        thread_flags=(-pthread)
        dynamic_flags=(-Wno-error=experimental)
        # Keep the runtime thread available while the test joins its workers.
        # Exercise heap growth despite Emscripten's known performance warning.
        flags+=(-pthread -DTEST_THREADS -sPROXY_TO_PTHREAD=1 -sPTHREAD_POOL_SIZE=3
            -sDEFAULT_PTHREAD_STACK_SIZE=1048576 -Wno-error=pthreads-mem-growth)
        ;;
    *) echo "Usage: $0 [prefix] [--threads]" >&2; exit 1 ;;
esac
# Emscripten 4.0.14 removed this legacy return-address workaround.
# https://github.com/emscripten-core/emscripten/pull/24963
version=$(emcc -dumpversion)
IFS=. read -r version_major version_minor version_patch <<< "$version"
version_patch=${version_patch%%[^0-9]*}
if (( version_major < 4 || (version_major == 4 && version_minor == 0 && version_patch < 14) )); then
    flags+=(-sUSE_OFFSET_CONVERTER=1)
fi
emcc "$source_file" "$archive" "${flags[@]}" -o "$work/static.js"
run_test() {
    local output stderr_file="$work/$1.stderr" line
    local expected_logs=1 actual_logs=0 status=0
    if [[ "${2:-}" == --threads ]]; then expected_logs=3; fi
    output=$(cd "$work" && timeout 120 node "$1" 2>"$stderr_file") || status=$?
    cat "$stderr_file" >&2
    printf '%s\n' "$output"
    if (( status != 0 )); then return "$status"; fi
    while IFS= read -r line; do
        if [[ "$line" == '[warning](stream): invalid erase line command:'* ]]; then
            actual_logs=$((actual_logs + 1))
        fi
    done < "$stderr_file"
    if (( actual_logs != expected_logs )); then
        printf 'Expected %s stderr warnings, found %s\n' "$expected_logs" "$actual_logs" >&2
        return 1
    fi
    [[ "$output" == *"Emscripten stderr logging exercised"* ]]
    printf '%s\n' "Emscripten stderr logging tests passed"
    # Emscripten preload failures can exit zero before main is called.
    [[ "$output" == *"Emscripten allocation tests passed"* ]]
    if [[ "${2:-}" == --threads ]]; then
        [[ "$output" == *"Emscripten pthread tests passed"* ]]
    fi
}
run_test static.js "${2:-}"
emcc -O2 "${thread_flags[@]}" -sSIDE_MODULE=1 -shared -o "$work/libghostty-vt.so" \
    -Wl,--whole-archive "$archive" -Wl,--no-whole-archive
emcc "$source_file" "${flags[@]}" "${dynamic_flags[@]}" -DTEST_DYNAMIC -sMAIN_MODULE=1 \
    --preload-file "$work/libghostty-vt.so@/libghostty-vt.so" -o "$work/dynamic.js"
run_test dynamic.js "${2:-}"
