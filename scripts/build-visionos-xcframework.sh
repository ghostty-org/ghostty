#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

./scripts/zig-visionos.sh prepare

exec ./scripts/zig-visionos.sh build \
    -Dtarget=aarch64-macos \
    -Demit-exe=false \
    -Demit-macos-app=false \
    -Demit-xcframework=true \
    -Dxcframework-visionos=true \
    -Demit-docs=false \
    -Demit-webdata=false \
    -Doptimize=ReleaseFast \
    "$@"
