#!/usr/bin/env bash
#
# Uncomment to test with an active terminal state.
# ARGS=" --terminal"

hyperfine \
  --warmup 10 \
  -n new \
  "./zig-out/bin/bench-screen-copy --mode=new${ARGS}" \
  -n old \
  "./zig-out/bin/bench-screen-copy --mode=old${ARGS}"

