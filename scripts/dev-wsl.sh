#!/usr/bin/env bash
set -euo pipefail

if ! command -v cc >/dev/null 2>&1; then
  echo "Missing C compiler (cc). Install build-essential or equivalent." >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "Missing zig. Install Zig 0.15.2+ and ensure it is on PATH." >&2
  exit 1
fi

echo "== Versions =="
command -v cc
command -v zig
cc --version
zig version
