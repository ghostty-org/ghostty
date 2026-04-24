#!/bin/bash
# build-cef-wrapper.sh — Builds libcef_dll_wrapper.a from CEF sources.
# Called as an early Xcode "Run Script" build phase (before compile+link).
# Produces a static library that the main app links against.
#
# The built library is cached at vendor/cef-build/libcef_dll_wrapper.a
# and only recompiled when source files change.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF_DIR="${REPO_ROOT}/vendor/cef"

# --- Guard: skip if CEF not downloaded ---

if [ ! -d "${CEF_DIR}/libcef_dll" ]; then
    echo "note: CEF not found — skipping wrapper build (stub mode)"
    exit 0
fi

# --- Configuration ---

CEF_BUILD_DIR="${REPO_ROOT}/vendor/cef-build"
WRAPPER_LIB="${CEF_BUILD_DIR}/libcef_dll_wrapper.a"
WRAPPER_OBJ_DIR="${CEF_BUILD_DIR}/obj"
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)

mkdir -p "${WRAPPER_OBJ_DIR}"

# --- Collect sources ---

WRAPPER_SOURCES=()
while IFS= read -r -d '' f; do
    WRAPPER_SOURCES+=("$f")
done < <(find "${CEF_DIR}/libcef_dll" \( -name "*.cc" -o -name "*.mm" \) -print0)

# --- Check if rebuild needed ---

if [ -f "${WRAPPER_LIB}" ]; then
    NEEDS_REBUILD=false
    for src in "${WRAPPER_SOURCES[@]}"; do
        if [ "${src}" -nt "${WRAPPER_LIB}" ]; then
            NEEDS_REBUILD=true
            break
        fi
    done
    if [ "${NEEDS_REBUILD}" = false ]; then
        echo "  libcef_dll_wrapper.a up to date (${#WRAPPER_SOURCES[@]} files)"
        exit 0
    fi
fi

echo "  Building libcef_dll_wrapper.a (${#WRAPPER_SOURCES[@]} files, ${JOBS} jobs)..."

# --- Compile all sources ---

# Remove stale objects.
rm -rf "${WRAPPER_OBJ_DIR}"
mkdir -p "${WRAPPER_OBJ_DIR}"

compile_one() {
    local src="$1"
    local obj_dir="${WRAPPER_OBJ_DIR}"
    local cef_dir="${CEF_DIR}"
    local rel="${src#${cef_dir}/libcef_dll/}"
    # Strip any extension (.cc or .mm) and append .o exactly once.
    # The prior two-step strip+append produced .o.o on files that didn't
    # match the first pattern, and the odd-length member names broke
    # 8-byte alignment inside libcef_dll_wrapper.a on some `ar` versions.
    local obj="${obj_dir}/${rel%.*}.o"
    mkdir -p "$(dirname "${obj}")"
    clang++ -std=c++20 -arch arm64 -O2 \
        -mmacosx-version-min=13.0 \
        -I"${cef_dir}" \
        -DWRAPPING_CEF_SHARED \
        -fno-exceptions \
        -Wno-undefined-var-template -Wno-comma \
        -c "${src}" -o "${obj}"
}
export -f compile_one
export WRAPPER_OBJ_DIR CEF_DIR

# Use `bash -c '...' _` instead of `xargs -I{}`. The -I form assembles a
# template per input and hits xargs's per-template length cap on long
# absolute paths (e.g. CI runners). Passing the source path as a positional
# argument has no such limit.
printf '%s\n' "${WRAPPER_SOURCES[@]}" | \
    xargs -P "${JOBS}" -n 1 bash -c 'compile_one "$1"' _

# --- Archive into static library ---

find "${WRAPPER_OBJ_DIR}" -name "*.o" -print0 | xargs -0 ar rcs "${WRAPPER_LIB}"
ranlib -no_warning_for_no_symbols "${WRAPPER_LIB}"

echo "  libcef_dll_wrapper.a built ($(du -h "${WRAPPER_LIB}" | cut -f1))"
