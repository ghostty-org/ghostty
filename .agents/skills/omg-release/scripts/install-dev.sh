#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 [--skip-build] [--push-tag]" >&2
  exit 64
}

skip_build=false
push_tag=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) skip_build=true ;;
    --push-tag) push_tag=true ;;
    *) usage ;;
  esac
  shift
done

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# Resolve a real Python before running build helpers. The system /usr/bin/python3
# shim consults SDKROOT and can request Command Line Tools for stale SDK paths.
unset SDKROOT
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "$DEVELOPER_DIR/Contents/Developer" &&
        ( -x "$DEVELOPER_DIR/Contents/Developer/usr/bin/xcodebuild" ||
          -x "$DEVELOPER_DIR/Contents/Developer/usr/bin/clang" ) ]]; then
    export DEVELOPER_DIR="$DEVELOPER_DIR/Contents/Developer"
  elif [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" &&
          ! -x "$DEVELOPER_DIR/usr/bin/clang" ]]; then
    unset DEVELOPER_DIR
  fi
fi
dev_tool="$repo_root/dist/macos/dev-tool.sh"
dev_python=$(bash "$dev_tool" resolve-python)
dev_python_dir=${dev_python%/*}
[[ -n "$dev_python_dir" ]] || dev_python_dir=/
export PATH="$dev_python_dir:${PATH:-}"

# Builds and the launched app must not inherit an agent's short-lived temp root.
launch_tmpdir=$(getconf DARWIN_USER_TEMP_DIR)
[[ -d "$launch_tmpdir" ]] || { echo "missing macOS user temporary directory" >&2; exit 1; }
export TMPDIR="$launch_tmpdir"

worktree_status=$(git status --porcelain=v1 --untracked-files=all)
[[ -z "$worktree_status" ]] || {
  echo "refusing to install OMG Dev from a dirty worktree; review, validate, and commit the intended test changes first" >&2
  printf '%s\n' "$worktree_status" >&2
  exit 1
}

head_commit=$(git rev-parse HEAD)
head_short=${head_commit:0:8}
build_settings=$(env -i \
  "HOME=$HOME" \
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
  xcodebuild \
    -project macos/Ghostty.xcodeproj \
    -scheme Ghostty \
    -configuration Debug \
    -showBuildSettings 2>/dev/null)
release_version=$(awk '/^[[:space:]]*MARKETING_VERSION = / { print $3; exit }' <<<"$build_settings")
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "invalid base OMG release version: $release_version" >&2
  exit 1
}

dev_version="${release_version}-dev.${head_short}"
dev_tag="dev-v${release_version}-${head_short}"
if git rev-parse -q --verify "refs/tags/$dev_tag" >/dev/null; then
  tagged_commit=$(git rev-list -n 1 "$dev_tag")
  [[ "$tagged_commit" == "$head_commit" ]] || {
    echo "dev tag collision: $dev_tag points to $tagged_commit" >&2
    exit 1
  }
fi

source_app="$repo_root/macos/build/Debug/OMG.app"
target_app="/Applications/OMG Dev.app"
source_bin="$source_app/Contents/MacOS/omg"
target_bin="$target_app/Contents/MacOS/omg"

dev_signing_identity=${OMG_DEV_SIGNING_IDENTITY:-}
if [[ -z "$dev_signing_identity" ]]; then
  dev_signing_identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '$1 ~ /^[0-9]+\)$/ { print $2; exit }')
fi
[[ -n "$dev_signing_identity" && "$dev_signing_identity" != "-" ]] || {
  echo "OMG Dev requires a persistent code-signing identity so macOS can retain folder permissions across installs" >&2
  echo "install one in Keychain Access or set OMG_DEV_SIGNING_IDENTITY explicitly" >&2
  exit 1
}

if [[ "$skip_build" != true ]]; then
  ghostty_version=$(plutil -extract GhosttyBaseVersion raw macos/Ghostty-Info.plist)
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    -u ALL_PROXY -u all_proxy \
    mise exec zig@0.16.0 -- zig build \
      -Doptimize=ReleaseFast \
      -Demit-xcframework=true \
      -Dxcframework-target=native \
      -Demit-macos-app=false \
      -Dversion-string="$ghostty_version"
  macos/build.nu \
    --scheme Ghostty \
    --configuration Debug \
    --action build \
    --marketing-version "$dev_version"
  bash "$dev_tool" python3 dist/macos/build-session-runtime.py \
    --output "$source_app/Contents/Resources/session-runtime"
fi

# --skip-build must validate the same complete artifact, never install a Swift
# app missing the native SSH helper or its remote platform dependencies.
bash "$dev_tool" python3 dist/macos/check-session-runtime.py \
  "$source_app/Contents/Resources/session-runtime"

[[ "$(git rev-parse HEAD)" == "$head_commit" ]] || {
  echo "HEAD changed during the Dev build; refusing to install or tag it" >&2
  exit 1
}
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || {
  echo "worktree changed during the Dev build; refusing to install or tag it" >&2
  exit 1
}

[[ -x "$source_bin" ]] || {
  echo "missing Debug app: $source_app" >&2
  exit 1
}

bundle_id=$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")
[[ "$bundle_id" == "com.jischeng.omg.debug" ]] || {
  echo "refusing to install non-Debug bundle: $bundle_id" >&2
  exit 1
}
source_version=$(plutil -extract CFBundleShortVersionString raw "$source_app/Contents/Info.plist")
[[ "$source_version" == "$dev_version" ]] || {
  echo "Debug app version is $source_version, expected $dev_version" >&2
  exit 1
}

OMG_SIGNING_MODE=development \
OMG_SIGNING_IDENTITY="$dev_signing_identity" \
OMG_SIGNING_KEYCHAIN= \
OMG_SIGNING_ENTITLEMENTS="$repo_root/macos/GhosttyDebug.entitlements" \
  dist/macos/sign_omg_app.sh "$source_app"
designated_requirement=$(codesign -d -r- "$source_app" 2>&1)
[[ "$designated_requirement" != *"cdhash"* ]] || {
  echo "OMG Dev still has an unstable ad-hoc designated requirement" >&2
  exit 1
}

version_output=$("$source_bin" --version 2>&1)
build_mode=$(awk '/build mode/{print $NF}' <<<"$version_output")
[[ "$build_mode" == ".ReleaseFast" ]] || {
  echo "refusing routine Dev install with GhosttyKit build mode $build_mode" >&2
  exit 1
}

OMG_TEST_BINARY="$source_bin" bash "$dev_tool" python3 dist/test_ssh_agent_wrappers.py

if pgrep -f '/Applications/OMG Dev.app/Contents/MacOS/omg' >/dev/null; then
  osascript -e 'tell application id "com.jischeng.omg.debug" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -f '/Applications/OMG Dev.app/Contents/MacOS/omg' >/dev/null || break
    sleep 0.25
  done
fi

if pgrep -f '/Applications/OMG Dev.app/Contents/MacOS/omg' >/dev/null; then
  echo "OMG Dev is still running; refusing to overwrite it" >&2
  exit 1
fi

rm -rf "$target_app"
ditto "$source_app" "$target_app"

codesign --verify --deep --strict "$target_app"
bash "$dev_tool" python3 dist/macos/check-session-runtime.py \
  "$target_app/Contents/Resources/session-runtime"
source_sha=$(shasum -a 256 "$source_bin" | awk '{print $1}')
target_sha=$(shasum -a 256 "$target_bin" | awk '{print $1}')
[[ "$source_sha" == "$target_sha" ]] || {
  echo "installed binary hash mismatch" >&2
  exit 1
}

installed_bundle_id=$(plutil -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist")
installed_version=$(plutil -extract CFBundleShortVersionString raw "$target_app/Contents/Info.plist")
installed_build=$(plutil -extract CFBundleVersion raw "$target_app/Contents/Info.plist")
ghostty_version=$(plutil -extract GhosttyBaseVersion raw "$target_app/Contents/Info.plist")

if ! git rev-parse -q --verify "refs/tags/$dev_tag" >/dev/null; then
  git tag -a "$dev_tag" \
    -m "OMG Dev $dev_version · Ghostty $ghostty_version · $head_commit"
  tag_created=yes
else
  tag_created=no
fi

if [[ "$push_tag" == true ]]; then
  git push origin "refs/tags/$dev_tag"
  tag_scope=origin
else
  tag_scope=local
fi

# LaunchServices can retain the installer's inherited environment for the app.
# Agent harnesses use short-lived TMPDIR directories that disappear after the
# tool call; terminal children need the user's persistent macOS temporary root.
env -u OMG_SSH_HANDOFF_HELPER -u OMG_SSH_HANDOFF_DIRECTORY -u OMG_SSH_HANDOFF_TOKEN \
  -u OMG_SESSION_RUNTIME_DESCRIPTOR -u OMG_RUNTIME_SOCKET -u OMG_RUNTIME_PANE_ID \
  TMPDIR="$launch_tmpdir" open "$target_app"
printf 'installed=%s\nbundle_id=%s\nomg_version=%s\nbundle_version=%s\ndev_tag=%s\ntag_created=%s\ntag_scope=%s\ncommit=%s\nbuild_mode=%s\nsigning_identity=%s\nsource_sha=%s\ninstalled_sha=%s\nlaunched=yes\n' \
  "$target_app" "$installed_bundle_id" "$installed_version" "$installed_build" \
  "$dev_tag" "$tag_created" "$tag_scope" "$head_commit" "$build_mode" \
  "$dev_signing_identity" "$source_sha" "$target_sha"
