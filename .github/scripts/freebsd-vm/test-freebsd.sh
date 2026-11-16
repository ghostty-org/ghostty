#!/bin/sh
# test-freebsd.sh runs the libghostty-vt test binaries on FreeBSD.
#
# Usage: test-freebsd.sh TESTS SRC
#
#   TESTS  A directory of test binaries built for FreeBSD. The script runs
#          every file in it whose name ends in -test, such as the
#          ghostty-vt-c-test that zig build test-lib-vt-build
#          -Demit-test-exe installs.
#   SRC    A copy of the Ghostty repository. Some tests read files from it
#          while they run, so every binary runs from its top directory.
#
# It runs inside the FreeBSD VM. You rarely need to run it yourself, because
# vm.sh test copies both directories into the VM and then runs it.
#
# Each binary runs as one process per CPU, each running its share of the
# tests (the --shard option of src/build/test_runner.zig), the same way
# `zig build test-lib-vt` runs them. Every process writes to its own log
# so that their output never mixes. A line appears as each one finishes.
# Once all of them have finished, the script prints each log in full. A
# run looks like this:
#
#     running ghostty-vt-c-test in 8 shards
#     finished ghostty-vt-c-test shard 3/8 in 54s (exit 0)
#     ...
#     ::group::ghostty-vt-c-test shard 0/8
#     ...
#     All 485 tests passed.
#     ::endgroup::
#     ...
#     ran every test binary in 61s
#
# GitHub's log page folds each log between its ::group:: and ::endgroup::
# lines. The run fails if any process fails or runs out of time.
#
# Settings:
#
#   GHOSTTY_FREEBSD_VM_TEST_TIMEOUT  How many seconds each process may run
#                                    before it is stopped and fails. The
#                                    default is 1800.
#   GHOSTTY_FREEBSD_VM_TEST_SHARDS   How many processes to split each
#                                    binary across. The default is the
#                                    number of CPUs.
set -eu

tests=$1
src=$2
timeout=${GHOSTTY_FREEBSD_VM_TEST_TIMEOUT:-1800}
status=0

if [ "$(uname -s)" != FreeBSD ]; then
	echo "test-freebsd.sh: run this inside the FreeBSD VM. vm.sh test does that." >&2
	exit 2
fi

names=$(cd "$tests" && find . -maxdepth 1 -type f -name '*-test' | sed 's|^\./||' | sort)
if [ -z "$names" ]; then
	echo "::error title=No FreeBSD tests::$tests holds no *-test binaries"
	exit 1
fi

out=$(mktemp -d -t ghostty-tests)
trap 'rm -rf "$out"' EXIT

shards=${GHOSTTY_FREEBSD_VM_TEST_SHARDS:-$(sysctl -n hw.ncpu)}
case $shards in
'' | *[!0-9]* | 0) shards=1 ;;
esac

cd "$src"
started=$(date +%s)
# shellcheck disable=SC2086 # names is a list of words.
echo "running" $names "in $shards shards"
for name in $names; do
	shard=0
	while [ "$shard" -lt "$shards" ]; do
		(
			began=$(date +%s)
			if timeout "$timeout" "$tests/$name" "--shard=$shard/$shards" \
				>"$out/$name.$shard.log" 2>&1; then
				code=0
			else
				code=$?
			fi
			took=$(($(date +%s) - began))
			echo "$code $took" >"$out/$name.$shard.result"
			echo "finished $name shard $shard/$shards in ${took}s (exit $code)"
		) &
		shard=$((shard + 1))
	done
done
wait

for name in $names; do
	shard=0
	while [ "$shard" -lt "$shards" ]; do
		echo "::group::$name shard $shard/$shards"
		cat "$out/$name.$shard.log"
		echo "::endgroup::"
		read -r code took <"$out/$name.$shard.result"
		if [ "$code" -eq 124 ]; then
			echo "::error title=FreeBSD test timed out::$name shard $shard/$shards ran for more than ${timeout}s"
			status=1
		elif [ "$code" -ne 0 ]; then
			echo "::error title=FreeBSD test failed::$name shard $shard/$shards exited with status $code"
			status=1
		fi
		shard=$((shard + 1))
	done
done

echo "ran every test binary in $(($(date +%s) - started))s"
exit $status
