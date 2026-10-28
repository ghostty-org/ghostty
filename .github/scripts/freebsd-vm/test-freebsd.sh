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
# There is usually one binary. When there are several, they run at the same
# time, each writing to its own log so that their output never mixes. A line
# appears as each binary finishes. Once all of them have finished, the script
# prints each log in full. A run looks like this:
#
#     running ghostty-vt-c-test
#     finished ghostty-vt-c-test in 431s (exit 0)
#     ::group::ghostty-vt-c-test
#     ...
#     3714 passed; 38 skipped; 0 failed.
#     ::endgroup::
#     ran every test binary in 431s
#
# GitHub's log page folds each log between its ::group:: and ::endgroup::
# lines. The run fails if any binary fails or runs out of time.
#
# Settings:
#
#   GHOSTTY_FREEBSD_VM_TEST_TIMEOUT  How many seconds each binary may run
#                                    before it is stopped and fails. The
#                                    default is 1800.
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

cd "$src"
started=$(date +%s)
# shellcheck disable=SC2086 # names is a list of words.
echo "running" $names
for name in $names; do
	(
		began=$(date +%s)
		if timeout "$timeout" "$tests/$name" >"$out/$name.log" 2>&1; then
			code=0
		else
			code=$?
		fi
		took=$(($(date +%s) - began))
		echo "$code $took" >"$out/$name.result"
		echo "finished $name in ${took}s (exit $code)"
	) &
done
wait

for name in $names; do
	echo "::group::$name"
	cat "$out/$name.log"
	echo "::endgroup::"
	read -r code took <"$out/$name.result"
	if [ "$code" -eq 124 ]; then
		echo "::error title=FreeBSD test timed out::$name ran for more than ${timeout}s"
		status=1
	elif [ "$code" -ne 0 ]; then
		echo "::error title=FreeBSD test failed::$name exited with status $code"
		status=1
	fi
done

echo "ran every test binary in $(($(date +%s) - started))s"
exit $status
