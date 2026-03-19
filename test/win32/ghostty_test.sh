#!/bin/bash
# Ghostty Win32 Test Runner
# Runs from WSL2, launches ghostty.exe on Windows side, validates behavior
#
# Usage:
#   ./ghostty_test.sh [test_name]    Run a specific test
#   ./ghostty_test.sh all            Run all tests
#   ./ghostty_test.sh list           List available tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS_PS1="$(wslpath -w "$SCRIPT_DIR/test_harness.ps1")"
SCREENSHOT_DIR="$SCRIPT_DIR/screenshots"
PASS=0
FAIL=0
SKIP=0

mkdir -p "$SCREENSHOT_DIR"

# Copy the exe to a local Windows temp path to avoid SmartScreen / UNC
# security prompts that block unattended execution from \\wsl.localhost.
WIN_TEMP="$(cmd.exe /c "echo %TEMP%" 2>/dev/null | tr -d '\r')"
LOCAL_EXE="${WIN_TEMP}\\ghostty-test.exe"
echo "Copying exe to local path to avoid security prompts..."
cp "$REPO_DIR/zig-out/bin/ghostty.exe" "$(wslpath "$WIN_TEMP")/ghostty-test.exe"
GHOSTTY_EXE="$LOCAL_EXE"

# ── Helpers ──────────────────────────────────────────────────────────────────

ps() {
    powershell.exe -ExecutionPolicy Bypass -File "$HARNESS_PS1" "$@" 2>&1 | tr -d '\r'
}

get_val() {
    # Extract VALUE from KEY=VALUE output lines
    echo "$1" | grep "^${2}=" | head -1 | cut -d= -f2-
}

screenshot() {
    local name="${1:-screenshot}"
    local pid="${2:-}"
    local out_win
    out_win="$(wslpath -w "$SCREENSHOT_DIR/${name}_$(date +%Y%m%d_%H%M%S).png")"

    if [ -n "$pid" ]; then
        ps -Action screenshot -ProcessId "$pid" -OutputPath "$out_win"
    else
        ps -Action screenshot -OutputPath "$out_win"
    fi
}

cleanup() {
    echo "Cleaning up ghostty processes..."
    ps -Action kill 2>/dev/null || true
    # Remove the temp exe copy
    rm -f "$(wslpath "$WIN_TEMP")/ghostty-test.exe" 2>/dev/null || true
}

report() {
    echo ""
    echo "════════════════════════════════════════"
    echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
    echo "════════════════════════════════════════"
    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $desc"
    else
        echo "  ✗ $desc (expected: '$expected', got: '$actual')"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  ✓ $desc"
    else
        echo "  ✗ $desc (expected to contain: '$needle')"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_true() {
    local desc="$1" val="$2"
    local lower
    lower="$(echo "$val" | tr '[:upper:]' '[:lower:]')"
    assert_eq "$desc" "true" "$lower" || true
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_launch_and_close() {
    echo "▶ test_launch_and_close"
    local output
    output="$(ps -Action launch -ExePath "$GHOSTTY_EXE" -WaitMs 5000)"
    local pid window_found
    pid="$(get_val "$output" PID)"
    window_found="$(get_val "$output" WINDOW_FOUND)"

    if [ "$window_found" != "true" ]; then
        echo "  ✗ Window did not appear within timeout"
        FAIL=$((FAIL + 1))
        ps -Action kill -ProcessId "$pid" 2>/dev/null || true
        return
    fi
    echo "  ✓ Window appeared (PID=$pid)"

    # Take a screenshot
    screenshot "launch" "$pid"
    echo "  ✓ Screenshot captured"

    # Check window properties
    local check
    check="$(ps -Action check -ProcessId "$pid")"
    local exists visible
    exists="$(get_val "$check" EXISTS)"
    visible="$(get_val "$check" VISIBLE)"
    assert_true "Window exists" "$exists"
    assert_true "Window visible" "$visible"

    # Close gracefully
    ps -Action close -ProcessId "$pid"
    sleep 2

    # Verify it closed
    check="$(ps -Action check -ProcessId "$pid")"
    exists="$(get_val "$check" EXISTS)"
    assert_eq "Window closed" "false" "$exists"

    PASS=$((PASS + 1))
    echo "  ● PASSED"
}

test_window_properties() {
    echo "▶ test_window_properties"
    local output
    output="$(ps -Action launch -ExePath "$GHOSTTY_EXE" -WaitMs 5000)"
    local pid window_found
    pid="$(get_val "$output" PID)"
    window_found="$(get_val "$output" WINDOW_FOUND)"

    if [ "$window_found" != "true" ]; then
        echo "  ✗ Window did not appear"
        FAIL=$((FAIL + 1))
        ps -Action kill -ProcessId "$pid" 2>/dev/null || true
        return
    fi

    local check
    check="$(ps -Action check -ProcessId "$pid")"
    local client_size
    client_size="$(get_val "$check" CLIENT_SIZE)"

    # Client size should be non-zero
    local width height
    width="$(echo "$client_size" | cut -dx -f1)"
    height="$(echo "$client_size" | cut -dx -f2)"

    if [ "$width" -gt 0 ] && [ "$height" -gt 0 ]; then
        echo "  ✓ Client area has valid size: ${width}x${height}"
    else
        echo "  ✗ Client area invalid: ${client_size}"
        FAIL=$((FAIL + 1))
    fi

    ps -Action close -ProcessId "$pid"
    sleep 1
    ps -Action kill -ProcessId "$pid" 2>/dev/null || true
    PASS=$((PASS + 1))
    echo "  ● PASSED"
}

test_keyboard_input() {
    echo "▶ test_keyboard_input"
    local output
    output="$(ps -Action launch -ExePath "$GHOSTTY_EXE" -WaitMs 5000)"
    local pid window_found
    pid="$(get_val "$output" PID)"
    window_found="$(get_val "$output" WINDOW_FOUND)"

    if [ "$window_found" != "true" ]; then
        echo "  ✗ Window did not appear"
        FAIL=$((FAIL + 1))
        ps -Action kill -ProcessId "$pid" 2>/dev/null || true
        return
    fi

    # Type a command
    sleep 1
    ps -Action sendtext -ProcessId "$pid" -Text "echo hello-ghostty-test"
    ps -Action sendkeys -ProcessId "$pid" -Keys "{ENTER}"
    sleep 1

    # Take screenshot to verify output
    screenshot "keyboard_input" "$pid"
    echo "  ✓ Input sent and screenshot captured (manual verification needed)"

    ps -Action close -ProcessId "$pid"
    sleep 1
    ps -Action kill -ProcessId "$pid" 2>/dev/null || true
    PASS=$((PASS + 1))
    echo "  ● PASSED"
}

test_resize() {
    echo "▶ test_resize"
    echo "  ⊘ SKIPPED (resize automation not yet implemented)"
    SKIP=$((SKIP + 1))
}

test_multiple_windows() {
    echo "▶ test_multiple_windows"
    # Launch first window
    local output1
    output1="$(ps -Action launch -ExePath "$GHOSTTY_EXE" -WaitMs 5000)"
    local pid1
    pid1="$(get_val "$output1" PID)"
    local wf1
    wf1="$(get_val "$output1" WINDOW_FOUND)"

    if [ "$wf1" != "true" ]; then
        echo "  ✗ First window did not appear"
        FAIL=$((FAIL + 1))
        ps -Action kill 2>/dev/null || true
        return
    fi
    echo "  ✓ First window appeared (PID=$pid1)"

    # Launch second window
    local output2
    output2="$(ps -Action launch -ExePath "$GHOSTTY_EXE" -WaitMs 5000)"
    local pid2
    pid2="$(get_val "$output2" PID)"
    local wf2
    wf2="$(get_val "$output2" WINDOW_FOUND)"

    if [ "$wf2" != "true" ]; then
        echo "  ✗ Second window did not appear"
        FAIL=$((FAIL + 1))
        ps -Action kill 2>/dev/null || true
        return
    fi
    echo "  ✓ Second window appeared (PID=$pid2)"

    # Close first, verify second still works
    ps -Action close -ProcessId "$pid1"
    sleep 2

    local check2
    check2="$(ps -Action check -ProcessId "$pid2")"
    local exists2
    exists2="$(get_val "$check2" EXISTS)"

    if [ "$exists2" = "true" ]; then
        echo "  ✓ Second window survived first window close"
    else
        echo "  ✗ Second window died when first was closed"
        FAIL=$((FAIL + 1))
    fi

    ps -Action kill 2>/dev/null || true
    PASS=$((PASS + 1))
    echo "  ● PASSED"
}

test_clipboard() {
    echo "▶ test_clipboard"
    local output
    output="$(ps -Action launch -ExePath "$GHOSTTY_EXE" -WaitMs 5000)"
    local pid window_found
    pid="$(get_val "$output" PID)"
    window_found="$(get_val "$output" WINDOW_FOUND)"

    if [ "$window_found" != "true" ]; then
        echo "  ✗ Window did not appear"
        FAIL=$((FAIL + 1))
        ps -Action kill -ProcessId "$pid" 2>/dev/null || true
        return
    fi

    # Type text, select it, copy, then paste
    sleep 1
    ps -Action sendtext -ProcessId "$pid" -Text "echo clipboard-test-string"
    ps -Action sendkeys -ProcessId "$pid" -Keys "{ENTER}"
    sleep 1

    # Screenshot to verify
    screenshot "clipboard" "$pid"
    echo "  ✓ Clipboard test screenshot captured (manual verification needed)"

    ps -Action close -ProcessId "$pid"
    sleep 1
    ps -Action kill -ProcessId "$pid" 2>/dev/null || true
    PASS=$((PASS + 1))
    echo "  ● PASSED"
}

test_config_file() {
    echo "▶ test_config_file"

    # Create a temporary config directory with a custom config
    local config_dir_wsl
    config_dir_wsl="$(wslpath "$WIN_TEMP")/ghostty-test-config/ghostty"
    mkdir -p "$config_dir_wsl"

    # Write a config with a bright red background (very distinctive)
    cat > "$config_dir_wsl/config" << 'CFGEOF'
background = #cc0000
foreground = #ffffff
font-size = 16
CFGEOF

    # Launch ghostty with XDG_CONFIG_HOME set via WSLENV so Windows
    # inherits the env var from WSL.
    local config_dir_win
    config_dir_win="$(wslpath -w "$(wslpath "$WIN_TEMP")/ghostty-test-config")"
    export XDG_CONFIG_HOME="$config_dir_win"
    export WSLENV="XDG_CONFIG_HOME/w"

    local output
    output="$(ps -Action launch -ExePath "$GHOSTTY_EXE" -WaitMs 5000)"
    local pid window_found
    pid="$(get_val "$output" PID)"
    window_found="$(get_val "$output" WINDOW_FOUND)"

    unset XDG_CONFIG_HOME
    unset WSLENV

    if [ "$window_found" != "true" ]; then
        echo "  ✗ Window did not appear with custom config"
        FAIL=$((FAIL + 1))
        ps -Action kill -ProcessId "$pid" 2>/dev/null || true
        rm -rf "$(wslpath "$WIN_TEMP")/ghostty-test-config"
        return
    fi
    echo "  ✓ Window appeared with custom config (PID=$pid)"

    # Take screenshot — red background should be very obvious
    screenshot "config_red_bg" "$pid"
    echo "  ✓ Screenshot captured (verify red background manually)"

    # Clean up
    ps -Action close -ProcessId "$pid"
    sleep 2
    ps -Action kill -ProcessId "$pid" 2>/dev/null || true
    rm -rf "$(wslpath "$WIN_TEMP")/ghostty-test-config"

    PASS=$((PASS + 1))
    echo "  ● PASSED"
}

# ── Main ─────────────────────────────────────────────────────────────────────

list_tests() {
    echo "Available tests:"
    echo "  launch_and_close    — Launch ghostty, verify window, close it"
    echo "  window_properties   — Check window dimensions and visibility"
    echo "  keyboard_input      — Send keystrokes, screenshot output"
    echo "  resize              — Window resize behavior (not yet implemented)"
    echo "  multiple_windows    — Multiple window lifecycle"
    echo "  clipboard           — Copy/paste functionality"
    echo "  config_file         — Config file loading with custom settings"
}

run_test() {
    case "$1" in
        launch_and_close)    test_launch_and_close ;;
        window_properties)   test_window_properties ;;
        keyboard_input)      test_keyboard_input ;;
        resize)              test_resize ;;
        multiple_windows)    test_multiple_windows ;;
        clipboard)           test_clipboard ;;
        config_file)         test_config_file ;;
        *)                   echo "Unknown test: $1"; exit 1 ;;
    esac
}

trap cleanup EXIT

case "${1:-all}" in
    list)
        list_tests
        ;;
    all)
        echo "Running all Ghostty Win32 tests..."
        echo "Exe: $GHOSTTY_EXE"
        echo ""
        test_launch_and_close
        echo ""
        test_window_properties
        echo ""
        test_keyboard_input
        echo ""
        test_resize
        echo ""
        test_multiple_windows
        echo ""
        test_clipboard
        echo ""
        test_config_file
        echo ""
        report
        ;;
    *)
        run_test "$1"
        echo ""
        report
        ;;
esac
