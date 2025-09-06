#!/usr/bin/env bash
#
# This script runs a given test case and captures a screenshot. This script
# expects to run in the Docker image so it just captures the full screen rather
# than a specific window.
#
# This script also compares the output to the expected value. The expected
# value is the case file with ".png" appended. If the "--update" flag is
# appended, the test case is updated.

#--------------------------------------------------------------------
# Helpers

function has_func() {
    declare -f -F $1 > /dev/null
    return $?
}

# Colors
export BOLD="\\e[1m"
export RED="\\e[1;31m"
export GREEN="\\e[1;32m"
export YELLOW="\\e[1;33m"
export WHITE="\\e[1;37m"
export RESET="\\e[0;39m"

#--------------------------------------------------------------------
# Flag parsing

ARG_REWRITE=0
ARG_UPDATE=0
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -e|--exec) ARG_EXEC="$2"; shift ;;
        -c|--case) ARG_CASE="$2"; shift ;;
        -o|--output) ARG_OUT="$2"; shift ;;
        -u|--update) ARG_UPDATE=1 ;;
        --rewrite-abs-path) ARG_REWRITE=1 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Rewrite the path to be valid for us. This regex can be fooled in many ways
# but its good enough for my PC (mitchellh) and CI. Contributors feel free
# to harden it.
if [ "$ARG_REWRITE" -eq 1 ]; then
  ARG_CASE=$(echo $ARG_CASE | sed -e 's/.*cases/\/src\/cases/')
fi

# If we're updating, then just update the file in-place
GOLDEN_OUT="${ARG_CASE}.${ARG_EXEC}.png"
ARG_OUT="${ARG_CASE}.${ARG_EXEC}.actual.png"
if [ "$ARG_UPDATE" -eq 1 ]; then ARG_OUT=$GOLDEN_OUT; fi

bad=0
if [ -z "$ARG_EXEC" ]; then bad=1; fi
if [ -z "$ARG_CASE" ]; then bad=1; fi
if [ -z "$ARG_OUT" ]; then bad=1; fi
if [ $bad -ne 0 ]; then
  echo "Usage: run.sh --exec <terminal> --case <path to case> --output <path to png>"
  exit 1
fi

# Load our test case
# shellcheck disable=SC1090
source ${ARG_CASE}
if ! has_func "test_do"; then
  echo "Test case is invalid."
  exit 1
fi

# NOTE: This is a huge hack right now.
if [ "$ARG_EXEC" = "ghostty" ]; then
  ARG_EXEC="/tmp/ghostty";

  # Copy so we don't read/write race when running in parallel
  cp /src/ghostty ${ARG_EXEC}

  # We build in Nix (maybe). To be sure, we replace the interpreter so
  # it doesn't point to a Nix path. If we don't build in Nix, this should
  # still be safe.
  patchelf --set-interpreter /lib/ld-linux-"$(uname -m)".so.1 ${ARG_EXEC}
fi

#--------------------------------------------------------------------
# Some terminals require XDG be properly setup. We create a new
# set of XDG directories for this.
export XDG_BASE_DIR="/work/xdg"
export XDG_RUNTIME_DIR="${XDG_BASE_DIR}/runtime"
mkdir -p ${XDG_BASE_DIR} ${XDG_RUNTIME_DIR}
chmod 0700 $XDG_RUNTIME_DIR

# Configure i3
cat <<EOF >${XDG_BASE_DIR}/i3.cfg
# i3 config file (v4)

exec ${ARG_EXEC}

bar {
    mode invisible
}
EOF

#--------------------------------------------------------------------

printf "${RESET}${BOLD}[$(basename $ARG_EXEC)]${RESET} $ARG_CASE ... ${RESET}"

# Start up the program under test by launching i3. We use i3 so we can
# more carefully control the window settings, test resizing, etc.
WM_LOG="${XDG_BASE_DIR}/wm.log"
i3 -c ${XDG_BASE_DIR}/i3.cfg >${WM_LOG} 2>&1 &

# Wait for startup
# TODO: we can probably use xdotool or wmctrl or something to detect if any
# windows actually launched and make error handling here better.
sleep 2

# Run our test case (should be defined in test case file)
test_do

# Sleep a second to let it render
sleep 1

# Uncomment this and use run-host.sh to get logs of the terminal emulator
# cat $WM_LOG

import -window root ${ARG_OUT}

DIFF=$(compare -metric AE ${ARG_OUT} ${GOLDEN_OUT} null: 2>&1)
if [ $? -eq 2 ] ; then
  printf "${RED}ERROR${RESET}\n"
  exit 1
else
  if [ $DIFF -gt 0 ]; then
    printf "${RED}Fail (Diff: ${WHITE}${DIFF}${RED})${RESET}\n"
    exit 1
  else
    printf "${GREEN}Pass (Diff: ${WHITE}${DIFF}${GREEN})${RESET}\n"
  fi
fi

