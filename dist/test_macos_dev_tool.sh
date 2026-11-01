#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool="$repo_root/dist/macos/dev-tool.sh"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

write_fake_python() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'SH'
#!/bin/sh
{
  printf 'EXEC=%s\n' "$0"
  printf 'SDKROOT=%s\n' "${SDKROOT-<unset>}"
  for argument do printf 'ARG=%s\n' "$argument"; done
} > "$DEV_TOOL_CAPTURE"
SH
  chmod +x "$path"
}

write_fake_tool() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'SH'
#!/bin/sh
{
  printf 'SDKROOT=%s\n' "${SDKROOT-<unset>}"
  for argument do printf 'ARG=%s\n' "$argument"; done
} > "$DEV_TOOL_CAPTURE"
SH
  chmod +x "$path"
}

selector="$tmp/xcode-select"
cat > "$selector" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$DEV_TOOL_XCODE_CAPTURE"
exit 1
SH
chmod +x "$selector"

write_fake_python "$tmp/real/python3"
mkdir -p "$tmp/shim"
ln -s /usr/bin/python3 "$tmp/shim/python3"
capture="$tmp/capture"
xcode_capture="$tmp/xcode-select-calls"

(
  cd "$tmp"
  SDKROOT="$tmp/missing-sdk" \
    DEVELOPER_DIR="$tmp/missing-developer" \
    OMG_DEV_TOOL_XCODE_SELECT="$selector" \
    DEV_TOOL_XCODE_CAPTURE="$xcode_capture" \
    DEV_TOOL_CAPTURE="$capture" \
    PATH="shim:real" \
    /bin/bash "$tool" python3 alpha "two words"
)
grep -Fq "EXEC=$tmp/real/python3" "$capture"
grep -Fq 'SDKROOT=<unset>' "$capture"
grep -Fq 'ARG=two words' "$capture"

(
  SDKROOT="$tmp/missing-sdk" \
    DEV_TOOL_CAPTURE="$capture" \
    PATH="$tmp/real" \
    /bin/bash "$tool" python3 only-interpreter-in-path
)
grep -Fq "EXEC=$tmp/real/python3" "$capture"
grep -Fq 'SDKROOT=<unset>' "$capture"

resolved=$(
  cd "$tmp"
  SDKROOT="$tmp/missing-sdk" \
    DEVELOPER_DIR="$tmp/missing-developer" \
    OMG_DEV_TOOL_XCODE_SELECT="$selector" \
    DEV_TOOL_XCODE_CAPTURE="$xcode_capture" \
    PATH="shim:real" \
    /bin/bash "$tool" resolve-python
)
[[ "$resolved" == "$tmp/real/python3" ]]

xcode_developer="$tmp/Xcode.app/Contents/Developer"
write_fake_python "$xcode_developer/usr/bin/python3"
write_fake_tool "$xcode_developer/usr/bin/xcodebuild"
(
  SDKROOT="$tmp/missing-sdk" \
    DEVELOPER_DIR="$tmp/Xcode.app" \
    OMG_DEV_TOOL_XCODE_SELECT="$selector" \
    DEV_TOOL_XCODE_CAPTURE="$xcode_capture" \
    DEV_TOOL_CAPTURE="$capture" \
    PATH="$tmp/shim" \
    /bin/bash "$tool" python3 alpha
)
grep -Fq "EXEC=$xcode_developer/usr/bin/python3" "$capture"
grep -Fq 'SDKROOT=<unset>' "$capture"

clt_developer="$tmp/CommandLineTools"
write_fake_python "$clt_developer/usr/bin/python3"
write_fake_tool "$clt_developer/usr/bin/clang"
(
  SDKROOT="$tmp/missing-sdk" \
    DEVELOPER_DIR="$clt_developer" \
    OMG_DEV_TOOL_XCODE_SELECT="$selector" \
    DEV_TOOL_XCODE_CAPTURE="$xcode_capture" \
    DEV_TOOL_CAPTURE="$capture" \
    PATH="$tmp/shim" \
    /bin/bash "$tool" python3 clt-interpreter
)
grep -Fq "EXEC=$clt_developer/usr/bin/python3" "$capture"
grep -Fq 'SDKROOT=<unset>' "$capture"

write_fake_tool "$tmp/tools/xcrun"
write_fake_tool "$tmp/tools/swiftlint"
(
  SDKROOT="$tmp/missing-sdk" \
    DEVELOPER_DIR="$clt_developer" \
    DEV_TOOL_CAPTURE="$capture" \
    PATH="$tmp/tools" \
    /bin/bash "$tool" xcrun --show-sdk-path
)
grep -Fq 'SDKROOT=<unset>' "$capture"
grep -Fq 'ARG=--show-sdk-path' "$capture"
(
  SDKROOT="$tmp/missing-sdk" \
    DEVELOPER_DIR="$tmp/missing-developer" \
    DEV_TOOL_CAPTURE="$capture" \
    PATH="$tmp/tools" \
    /bin/bash "$tool" swiftlint lint --strict
)
grep -Fq 'SDKROOT=<unset>' "$capture"
grep -Fq 'ARG=--strict' "$capture"

error="$tmp/no-python-error"
if (
  cd "$tmp"
  SDKROOT="$tmp/missing-sdk" \
    DEVELOPER_DIR="$tmp/missing-developer" \
    OMG_DEV_TOOL_XCODE_SELECT="$selector" \
    DEV_TOOL_XCODE_CAPTURE="$xcode_capture" \
    PATH="" \
    /bin/bash "$tool" python3 ignored
) 2>"$error"; then
  echo "expected missing Python to fail" >&2
  exit 1
fi
grep -Fq "Apple /usr/bin/python3 installer shim was skipped" "$error"
[[ "$(tail -n 1 "$xcode_capture")" == "-p" ]]

rm -f "$capture"
if SDKROOT="$tmp/missing-sdk" \
  DEVELOPER_DIR="$tmp/missing-developer" \
  OMG_DEV_TOOL_XCODE_SELECT="$selector" \
  DEV_TOOL_XCODE_CAPTURE="$xcode_capture" \
  DEV_TOOL_CAPTURE="$capture" \
  PATH="$tmp/tools" \
  /bin/bash "$tool" xcrun --show-sdk-path 2>"$error"; then
  echo "expected xcrun to fail without a selected developer directory" >&2
  exit 1
fi
grep -Fq "xcrun was not started" "$error"
[[ ! -e "$capture" ]]
[[ "$(tail -n 1 "$xcode_capture")" == "-p" ]]

echo "dev-tool shell contract checks passed"
