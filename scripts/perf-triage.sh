#!/usr/bin/env bash
# Run when Ghostties feels slow. Diagnoses system load before blaming the app.
# Diagnostic order: system load → stale processes → terminal config → terminal code
# HARD RULE: never killall ghostty / killall ghostties — your terminal binary shares the name

set -euo pipefail

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

warn()  { echo -e "${YEL}⚠  $*${NC}"; }
ok()    { echo -e "${GRN}✓  $*${NC}"; }
info()  { echo -e "${DIM}   $*${NC}"; }
fatal() { echo -e "${RED}✗  $*${NC}"; }
h()     { echo -e "\n${BOLD}$*${NC}"; }

CPU_COUNT=$(sysctl -n hw.logicalcpu)
LOAD_WARN=$CPU_COUNT

h "1 / 6 — System load"
LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')
LOAD_INT=${LOAD%.*}
if (( LOAD_INT >= LOAD_WARN )); then
  fatal "Load avg (1-min): ${LOAD}  — above CPU count (${CPU_COUNT}). System is saturated. Ghostties is a victim, not the cause."
  echo -e "     ${DIM}Check Claude session count (step 2) and Activity Monitor CPU first.${NC}"
else
  ok "Load avg (1-min): ${LOAD}  (CPU count: ${CPU_COUNT})"
fi

h "2 / 6 — Claude CLI sessions"
CLAUDE_COUNT=$(ps aux | grep -c '[c]laude' || true)
if (( CLAUDE_COUNT > 4 )); then
  warn "${CLAUDE_COUNT} active 'claude' processes detected. M1 Pro comfortable ceiling is 3–4. Each extra spawn is a load tax."
  info "Consider closing idle sessions before investigating Ghostties."
  ps aux | grep '[c]laude' | awk '{printf "     PID %-6s  CPU %-5s  MEM %-5s  %s\n", $2, $3, $4, $11}' | head -12
else
  ok "${CLAUDE_COUNT} claude process(es)"
fi

h "3 / 6 — Stale claude processes (>24h)"
STALE=$(ps aux | awk '
  /[c]laude/ {
    split($10, t, ":")
    hours = t[1]
    if (length(hours) > 2) { print $0 }
  }
')
if [[ -n "$STALE" ]]; then
  warn "Stale claude processes found (runtime >24h) — these are zombie pattern from 2026-05-05 incident:"
  echo "$STALE" | awk '{printf "     PID %-6s  TIME %-10s  %s\n", $2, $10, $11}' | head -8
  info "Review and terminate them manually if safe (not this script's job)."
else
  ok "No stale claude processes"
fi

h "4 / 6 — Ghostties.app process"
GHOST=$(ps aux | grep '[G]hostties' | head -5)
if [[ -z "$GHOST" ]]; then
  info "Ghostties.app not running (or running as 'ghostty' binary)"
  GHOST=$(ps aux | grep '[g]hostty' | grep -v 'grep' | head -5)
  if [[ -n "$GHOST" ]]; then
    echo "$GHOST" | awk '{printf "     PID %-6s  CPU %-5s  MEM %-5s  VSZ %-10s  %s\n", $2, $3, $4, $5, $11}'
  fi
else
  echo "$GHOST" | awk '{printf "     PID %-6s  CPU %-5s%%  MEM %-5s%%  VSZ %-10s KB\n", $2, $3, $4, $5}'
  CPU=$(echo "$GHOST" | awk '{print $3}' | head -1)
  CPU_INT=${CPU%.*}
  if (( CPU_INT > 40 )); then
    warn "Ghostties CPU ${CPU}% — elevated. Worth profiling (scripts/profile.sh)."
  else
    ok "Ghostties CPU: ${CPU}%"
  fi
fi

h "5 / 6 — Recent app logs (last 5 min)"
echo ""
log show \
  --predicate 'subsystem == "com.mitchellh.ghostty"' \
  --last 5m \
  --style syslog \
  2>/dev/null | tail -30 || info "No logs found for com.mitchellh.ghostty in last 5 min"

h "6 / 6 — macOS hang/spin reports for Ghostties"
DIAG_DIR="$HOME/Library/Logs/DiagnosticReports"
RECENT_HANG=$(ls -t "$DIAG_DIR"/Ghostties* 2>/dev/null | head -3 || true)
if [[ -n "$RECENT_HANG" ]]; then
  warn "macOS captured hang/crash reports — macOS diagnosed something:"
  echo "$RECENT_HANG" | while read -r f; do
    SIZE=$(du -h "$f" | cut -f1)
    DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$f")
    echo -e "     ${YEL}${DATE}${NC}  ${DIM}${SIZE}${NC}  $f"
  done
  info "Open the most recent file in Console.app or share with 'open \$(ls -t $DIAG_DIR/Ghostties* | head -1)'"
else
  ok "No Ghostties hang/spin reports in ~/Library/Logs/DiagnosticReports"
fi

echo ""
echo -e "${DIM}─────────────────────────────────────────────────────────────────${NC}"
echo -e "${DIM}If all 6 checks are green and Ghostties still feels slow, THEN look at the app.${NC}"
echo -e "${DIM}Next step: scripts/profile.sh (when it exists) or open Instruments > Time Profiler.${NC}"
echo ""
