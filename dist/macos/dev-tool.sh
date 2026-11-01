#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 {python3|resolve-python|xcrun|swiftlint} [arguments...]" >&2
  exit 64
}

tool=${1:-}
[[ -n "$tool" ]] || usage
shift

# Build SDKs can be removed by Xcode updates. Let the selected developer tools
# resolve the current SDK instead of inheriting a stale absolute SDKROOT.
unset SDKROOT
normalize_developer_dir() {
  local developer_dir=$1
  if [[ "$developer_dir" != /* ]]; then
    developer_dir=$(cd -P -- "$developer_dir" 2>/dev/null && pwd -P) || return 1
  fi
  if [[ -d "$developer_dir/Contents/Developer" ]]; then
    developer_dir="$developer_dir/Contents/Developer"
  fi
  [[ -x "$developer_dir/usr/bin/xcodebuild" ||
     -x "$developer_dir/usr/bin/clang" ]] || return 1
  printf '%s\n' "$developer_dir"
}

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  if normalized_developer_dir=$(normalize_developer_dir "$DEVELOPER_DIR"); then
    export DEVELOPER_DIR="$normalized_developer_dir"
  else
    unset DEVELOPER_DIR
  fi
fi

selected_developer_dir() {
  local developer_dir
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    printf '%s\n' "$DEVELOPER_DIR"
    return 0
  fi
  developer_dir=$("${OMG_DEV_TOOL_XCODE_SELECT:-/usr/bin/xcode-select}" -p 2>/dev/null || true)
  [[ -n "$developer_dir" ]] || return 1
  normalize_developer_dir "$developer_dir"
}

is_apple_python_shim() {
  [[ -e /usr/bin/python3 && "$1" -ef /usr/bin/python3 ]]
}

python_candidate_in() {
  local path_entry=${1:-.}
  local candidate
  if [[ "$path_entry" != /* ]]; then
    path_entry=$(cd -P -- "$path_entry" 2>/dev/null && pwd -P) || return 1
  fi
  candidate="$path_entry/python3"
  if [[ -x "$candidate" && ! -d "$candidate" ]] && ! is_apple_python_shim "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

resolve_python() {
  local path_value entry candidate developer_dir
  local toolchain_python

  path_value=${PATH:-}
  while [[ "$path_value" == *:* ]]; do
    entry=${path_value%%:*}
    path_value=${path_value#*:}
    if candidate=$(python_candidate_in "$entry"); then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if candidate=$(python_candidate_in "$path_value"); then
    printf '%s\n' "$candidate"
    return 0
  fi

  if developer_dir=$(selected_developer_dir); then
    for candidate in \
      "$developer_dir/usr/bin/python3" \
      "$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/python3" \
      "$developer_dir"/Toolchains/*/usr/bin/python3
    do
      if [[ -x "$candidate" && ! -d "$candidate" ]] && ! is_apple_python_shim "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  echo "OMG development tooling requires Python 3. Install Python 3 or select a valid Xcode/Command Line Tools developer directory. The Apple /usr/bin/python3 installer shim was skipped; no installer was launched." >&2
  return 1
}

case "$tool" in
  python3|resolve-python)
    python=$(resolve_python) || exit $?
    if [[ "$tool" == resolve-python ]]; then
      printf '%s\n' "$python"
      exit 0
    fi
    [[ $# -gt 0 ]] || usage
    python_dir=${python%/*}
    [[ -n "$python_dir" ]] || python_dir=/
    export PATH="$python_dir:${PATH:-}"
    exec "$python" "$@"
    ;;
  xcrun)
    [[ $# -gt 0 ]] || usage
    if ! selected_developer_dir >/dev/null; then
      echo "No usable Xcode or Command Line Tools developer directory is selected; xcrun was not started." >&2
      exit 69
    fi
    xcrun_path=$(command -v xcrun || true)
    if [[ -z "$xcrun_path" ]]; then
      echo "xcrun was not found; install or select Xcode/Command Line Tools." >&2
      exit 69
    fi
    exec "$xcrun_path" "$@"
    ;;
  swiftlint)
    [[ $# -gt 0 ]] || usage
    swiftlint_path=$(command -v swiftlint || true)
    if [[ -z "$swiftlint_path" ]]; then
      echo "swiftlint was not found in PATH." >&2
      exit 69
    fi
    exec "$swiftlint_path" "$@"
    ;;
  *)
    usage
    ;;
esac
