#!/usr/bin/env bash
#
# Run all of the test cases. All test cases are found by traversing
# the "cases" directory, finding all shell files, and executing the
# "./run-host.sh" command for each.

DIR=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

# We always copy the bin in case it was rebuilt
cp ${DIR}/../zig-out/bin/ghostty ${DIR}/

# Unix shortcut to just execute ./run-host for each one. We can do
# this less esoterically if we ever wanted.
find ${DIR}/cases \
  -type f \
  -name '*.sh' | \
  sort | \
  parallel \
  --will-cite \
  ${DIR}/run-host.sh \
    --case '{}' \
    --rewrite-abs-path \
    "$@"
