#!/usr/bin/env bash

# TODO: This script is temporary, remove it from the repo


SIZE="25M"

hyperfine \
  --warmup 10 \
  -n memcpy \
  "./zig-out/bin/bench-stream --mode=gen-ascii | head -c ${SIZE} | ./zig-out/bin/bench-stream --mode=noop" \
  -n scalar \
  "./zig-out/bin/bench-stream --mode=gen-ascii | head -c ${SIZE} | ./zig-out/bin/bench-stream --mode=scalar" \
  -n simd \
  "./zig-out/bin/bench-stream --mode=gen-ascii | head -c ${SIZE} | ./zig-out/bin/bench-stream --mode=simd"
