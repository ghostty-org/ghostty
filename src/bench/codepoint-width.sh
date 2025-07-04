#!/usr/bin/env bash
#
# This is a trivial helper script to help run the codepoint-width benchmark.
# You probably want to tweak this script depending on what you're
# trying to measure.

# Options:
# - "ascii", uniform random ASCII bytes
# - "utf8", uniform random unicode characters, encoded as utf8
# - "rand", pure random data, will contain many invalid code sequences.
DATA="utf8"
SIZE="25000000"

# Add additional arguments
ARGS=""

# Generate the benchmark input ahead of time so it's not included in the time.
./zig-out/bin/bench-stream --mode=gen-$DATA | head -c $SIZE > /tmp/ghostty_bench_data
#cat ~/Downloads/JAPANESEBIBLE.txt > /tmp/ghostty_bench_data

# Uncomment to instead use the contents of `stream.txt` as input.
# yes $(cat ./stream.txt) | head -c $SIZE > /tmp/ghostty_bench_data

hyperfine \
  --warmup 10 \
  -n noop \
  "./zig-out/bin/bench-codepoint-width --mode=noop${ARGS} </tmp/ghostty_bench_data" \
  -n wcwidth \
  "./zig-out/bin/bench-codepoint-width --mode=wcwidth${ARGS} </tmp/ghostty_bench_data" \
  -n zg \
  "./zig-out/bin/bench-codepoint-width --mode=zg${ARGS} </tmp/ghostty_bench_data" \
  -n table \
  "./zig-out/bin/bench-codepoint-width --mode=table${ARGS} </tmp/ghostty_bench_data" \
  -n simd \
  "./zig-out/bin/bench-codepoint-width --mode=simd${ARGS} </tmp/ghostty_bench_data"

