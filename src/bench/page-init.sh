#!/usr/bin/env bash
#
# This is a trivial helper script to help run the page init benchmark.
# You probably want to tweak this script depending on what you're
# trying to measure.

# Uncomment to test with an active terminal state.
# ARGS=" --terminal"

hyperfine \
  --warmup 10 \
  -n alloc \
  "./zig-out/bin/bench-page-init --mode=alloc${ARGS} </tmp/ghostty_bench_data" \
  -n pool \
  "./zig-out/bin/bench-page-init --mode=pool${ARGS} </tmp/ghostty_bench_data"

