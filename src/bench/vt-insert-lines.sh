#!/usr/bin/env bash
#
# Uncomment to test with an active terminal state.
# ARGS=" --terminal"

hyperfine \
  --warmup 10 \
  -n new \
  "./zig-out/bin/bench-vt-insert-lines --mode=new${ARGS}" \
  -n old \
  "./zig-out/bin/bench-vt-insert-lines --mode=old${ARGS}"

