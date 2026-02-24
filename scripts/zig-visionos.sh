#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORK_COMMIT="34470b281dec31c254a11571f8d3c81ea0755dcc"
FORK_URL="https://github.com/douglance/zig/archive/${FORK_COMMIT}.tar.gz"
TOOLCHAIN_DIR="${ROOT_DIR}/.toolchains/zig-visionos"
STD_SRC_DIR="${TOOLCHAIN_DIR}/zig-${FORK_COMMIT}"
STD_LIB_DIR="${STD_SRC_DIR}/lib"

ensure_stdlib() {
    if [[ -f "${STD_LIB_DIR}/std/std.zig" ]]; then
        return
    fi

    mkdir -p "${TOOLCHAIN_DIR}"
    local tmp_dir
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zig-visionos.XXXXXX")"
    local archive_path="${tmp_dir}/zig.tar.gz"

    curl --fail --location --silent --show-error "${FORK_URL}" --output "${archive_path}"
    tar -xzf "${archive_path}" -C "${tmp_dir}"

    local extracted
    extracted="$(find "${tmp_dir}" -mindepth 1 -maxdepth 1 -type d -name "zig-*" | head -n1)"
    if [[ -z "${extracted}" ]]; then
        echo "failed to extract zig fork archive from ${FORK_URL}" >&2
        exit 1
    fi

    if [[ ! -d "${STD_SRC_DIR}" ]]; then
        mv "${extracted}" "${STD_SRC_DIR}"
    fi

    if [[ ! -f "${STD_LIB_DIR}/std/std.zig" ]]; then
        echo "failed to locate Zig stdlib in ${STD_LIB_DIR}" >&2
        exit 1
    fi
}

if [[ "${1:-}" == "prepare" ]]; then
    ensure_stdlib
    echo "Prepared ${STD_LIB_DIR}"
    exit 0
fi

if [[ "${1:-}" == "--print-lib-dir" ]]; then
    ensure_stdlib
    echo "${STD_LIB_DIR}"
    exit 0
fi

ensure_stdlib

if [[ "$#" -eq 0 ]]; then
    echo "usage: $0 <zig-command> [args...]" >&2
    echo "example: $0 build -Dtarget=aarch64-visionos" >&2
    exit 1
fi

zig_command="$1"
shift
exec zig "${zig_command}" --zig-lib-dir "${STD_LIB_DIR}" "$@"
