#!/usr/bin/env bash
# One-command Time Profiler session for Ghostties.
# Usage: scripts/profile.sh [app-path]
#
# Builds a Debug Ghostties.app, launches it under xctrace Time Profiler,
# records until you hit Ctrl-C, then opens the trace in Instruments.
#
# Requires: Xcode command-line tools + Instruments installed.

set -euo pipefail

BOLD='\033[1m'
DIM='\033[2m'
GRN='\033[0;32m'
YEL='\033[0;33m'
NC='\033[0m'

TRACE_OUT="/tmp/ghostties-$(date +%Y%m%d-%H%M%S).trace"
APP_PATH=""
STRESS_SESSIONS=""

# Parse args: optional --stress N, optional app path
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stress)
      STRESS_SESSIONS="${2:-5}"
      shift 2
      ;;
    *)
      APP_PATH="$1"
      shift
      ;;
  esac
done

echo -e "${BOLD}Ghostties Time Profiler${NC}"
if [[ -n "$STRESS_SESSIONS" ]]; then
  echo -e "${YEL}Stress mode: injecting ${STRESS_SESSIONS} fake running sessions (GHOSTTIES_STRESS_SESSIONS=${STRESS_SESSIONS})${NC}"
  echo -e "${DIM}No real Claude agents needed — coordinator tick fires every second with ${STRESS_SESSIONS} alive statuses.${NC}"
fi

# --- Locate the app ---
if [[ -n "$APP_PATH" ]]; then
  if [[ ! -d "$APP_PATH" ]]; then
    echo -e "${YEL}⚠  Provided path not found: $APP_PATH${NC}"
    exit 1
  fi
  echo -e "${DIM}Using provided app: $APP_PATH${NC}"
else
  # Prefer the installed release build; fall back to a freshly-built Debug build.
  RELEASE_APP="/Applications/Ghostties.app"
  BUILD_APP="$(dirname "$0")/../macos/build/Build/Products/Debug/Ghostties.app"

  if [[ -d "$RELEASE_APP" ]]; then
    APP_PATH="$RELEASE_APP"
    echo -e "${DIM}Using installed release build: $APP_PATH${NC}"
    echo -e "${DIM}(pass a path to profile a specific build: scripts/profile.sh path/to/Ghostties.app)${NC}"
  elif [[ -d "$BUILD_APP" ]]; then
    APP_PATH="$(realpath "$BUILD_APP")"
    echo -e "${DIM}Using Debug build: $APP_PATH${NC}"
  else
    echo -e "${YEL}No Ghostties.app found. Building Debug…${NC}"
    REPO_ROOT="$(dirname "$0")/.."
    xcodebuild \
      -project "$REPO_ROOT/macos/Ghostties.xcodeproj" \
      -scheme Ghostties \
      -configuration Debug \
      ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
      build 2>&1 | grep -E "error:|warning:|Build succeeded|Build FAILED" || true
    APP_PATH="$(realpath "$BUILD_APP")"
  fi
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Could not find or build Ghostties.app — aborting."
  exit 1
fi

echo ""
echo -e "${GRN}Recording with Time Profiler…${NC}"
echo -e "${DIM}App:    $APP_PATH${NC}"
echo -e "${DIM}Output: $TRACE_OUT${NC}"
echo -e "${DIM}Reproduce the slowness you want to investigate, then press Ctrl-C.${NC}"
echo ""

# Trap so we always open the trace even on early exit.
cleanup() {
  echo ""
  if [[ -e "$TRACE_OUT" ]]; then
    echo -e "${GRN}Opening trace in Instruments…${NC}"
    open "$TRACE_OUT"
  fi
}
trap cleanup EXIT

if [[ -n "$STRESS_SESSIONS" ]]; then
  GHOSTTIES_STRESS_SESSIONS="$STRESS_SESSIONS" xcrun xctrace record \
    --template "Time Profiler" \
    --launch "$APP_PATH" \
    --env "GHOSTTIES_STRESS_SESSIONS=$STRESS_SESSIONS" \
    --output "$TRACE_OUT" \
    --time-limit 300s
else
  xcrun xctrace record \
    --template "Time Profiler" \
    --launch "$APP_PATH" \
    --output "$TRACE_OUT" \
    --time-limit 300s
fi
