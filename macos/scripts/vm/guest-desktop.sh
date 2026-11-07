#!/bin/bash

set -euo pipefail

input=/tmp/omg-input
ms() { /usr/bin/python3 -c 'import time;print(int(time.time()*1000))'; }
osa() { /usr/bin/osascript "$@" 2>/dev/null; }
front() { osa -e 'tell application "System Events" to tell process "omg" to set frontmost to true'; }
windows() { osa -e 'tell application "System Events" to tell process "omg" to count windows'; }
frame() { osa -e 'tell application "System Events" to tell process "omg" to get {position, size} of front window'; }
wait_windows() {
    local want="$1" attempts="$2" attempt
    for attempt in $(seq 1 "$attempts"); do
        [[ "$(windows)" -ge "$want" ]] && return 0
        sleep 0.05
    done
    return 1
}
wait_frame() {
    local want="$1" attempts="$2" attempt
    for attempt in $(seq 1 "$attempts"); do
        [[ "$(frame)" == "$want" ]] && return 0
        sleep 0.05
    done
    return 1
}

screen="$(osa -l JavaScript -e 'ObjC.import("AppKit"); var s = $.NSScreen.mainScreen.frame.size; s.width + "x" + s.height')"
displays="$(osa -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.screens.js.length')"
screen_frame="0, 0, ${screen%x*}, ${screen#*x}"
echo "displays=$displays screen=$screen"

launch=()
for _ in 1 2 3; do
    pkill -x omg 2>/dev/null || true
    sleep 1.5
    start=$(ms)
    open -n /Applications/OMG.app --stdout /tmp/omg-stdout.log --stderr /tmp/omg-stderr.log
    wait_windows 1 400 || { echo "launch failed" >&2; exit 1; }
    launch+=($(( $(ms) - start )))
    sleep 1
done
echo "launch_ms=${launch[*]}"

front
new_window=()
for _ in 1 2 3; do
    before="$(windows)"
    start=$(ms)
    osa -e 'tell application "System Events" to tell process "omg" to keystroke "n" using command down'
    wait_windows $((before + 1)) 200 || { echo "new window failed" >&2; exit 1; }
    new_window+=($(( $(ms) - start )))
    sleep 0.7
done
echo "new_window_ms=${new_window[*]}"

front
osa -e 'tell application "System Events" to tell process "omg" to keystroke "n" using command down'
sleep 1.5
osa -e 'tell application "System Events" to tell process "omg" to keystroke "echo OMG_DRAG_SELECT_ALPHA_BETA_GAMMA"'
osa -e 'tell application "System Events" to tell process "omg" to key code 36'
sleep 0.7

read -r x y _ _ <<<"$(frame | tr -d ',')"
printf '' | pbcopy
start=$(ms)
"$input" drag $((x + 250)) $((y + 70)) $((x + 680)) $((y + 70)) 24
sleep 0.4
osa -e 'tell application "System Events" to tell process "omg" to keystroke "c" using command down'
sleep 0.4
selection="$(pbpaste)"
drag_ms=$(( $(ms) - start ))
echo "drag_select_ms=$drag_ms selection=$selection"
[[ "$selection" == *DRAG_SELECT_ALPHA_BETA_GAMMA* ]] ||
    { echo "mouse drag did not select the terminal text" >&2; exit 1; }

full_in=()
full_out=()
for _ in 1 2; do
    start=$(ms)
    osa -e 'tell application "System Events" to tell process "omg" to keystroke "f" using {command down, control down}'
    wait_frame "$screen_frame" 200 || { echo "fullscreen enter failed" >&2; exit 1; }
    full_in+=($(( $(ms) - start )))
    sleep 3
    start=$(ms)
    osa -e 'tell application "System Events" to tell process "omg" to keystroke "f" using {command down, control down}'
    for attempt in $(seq 1 200); do
        [[ "$(frame)" != "$screen_frame" ]] && break
        sleep 0.05
    done
    full_out+=($(( $(ms) - start )))
    sleep 1
done
echo "fullscreen_in_ms=${full_in[*]} fullscreen_out_ms=${full_out[*]}"

front
latency=()
for run in 1 2 3 4 5; do
    marker="/tmp/omg-latency-$$-$run"
    rm -f "$marker"
    osa -e "tell application \"System Events\" to tell process \"omg\" to keystroke \"touch $marker\""
    sleep 0.2
    start=$(ms)
    "$input" key 36
    for attempt in $(seq 1 500); do
        [[ -f "$marker" ]] && break
        sleep 0.002
    done
    latency+=($(( $(ms) - start )))
    rm -f "$marker"
done
echo "return_to_shell_ms=${latency[*]}"

front
osa -e 'tell application "System Events" to tell process "omg" to keystroke "n" using command down'
sleep 1
marker="/tmp/omg-scroll-$$"
rm -f "$marker"
osa -e "tell application \"System Events\" to tell process \"omg\" to keystroke \"seq 1 50000; touch $marker\""
sleep 0.3
start=$(ms)
"$input" key 36
for attempt in $(seq 1 2000); do
    [[ -f "$marker" ]] && break
    sleep 0.005
done
write_ms=$(( $(ms) - start ))
rm -f "$marker"
echo "pty_lines=50000 pty_write_ms=$write_ms pty_lines_per_sec=$(( 50000 * 1000 / (write_ms > 0 ? write_ms : 1) ))"
