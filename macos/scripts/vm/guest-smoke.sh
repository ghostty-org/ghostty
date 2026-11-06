#!/bin/bash

set -euo pipefail

token="${1:?smoke token is required}"
[[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "invalid smoke token" >&2; exit 2; }

marker="OMG_VM_SMOKE_$token"
marker_file="/tmp/omg-vm-smoke-$token"

/usr/bin/osascript -e 'tell application "System Events" to tell process "omg" to set frontmost to true'
/usr/bin/osascript -e 'tell application "System Events" to tell process "omg" to keystroke "n" using command down'
sleep 2
/usr/bin/osascript -e "tell application \"System Events\" to tell process \"omg\" to keystroke \"echo $marker; touch $marker_file\""
/usr/bin/osascript -e 'tell application "System Events" to tell process "omg" to key code 36'

for attempt in $(seq 1 20); do
    [[ -f "$marker_file" ]] && break
    sleep 1
done

[[ -f "$marker_file" ]] || { echo "typed command did not run in the guest shell" >&2; exit 1; }
rm -f "$marker_file"
echo "$marker"
