#!/usr/bin/env bash
#
# Headless UI smoke test for the shell (plan §8: no Xcode ⇒ no XCTest UI tests,
# and the screen may be locked).
#
# Runs build/Filaway.app three times against a throwaway notes root and a
# throwaway preferences domain:
#
#   editor  the M1-10 editor checks, on a note read back from disk
#   1       empty sidebar → ⌘N → type → autosave lands → rename renames the
#           file → an external edit reaches the sidebar → quit mid-burst
#   2       relaunch on the same root: last note restored, last burst survived
#
# Exits non-zero on any failure. Never leaves the app running.
#
#   Tools/smoke.sh            # build if needed, run every phase
#   Tools/smoke.sh --keep     # keep the temp notes root for inspection
#
set -uo pipefail

cd "$(dirname "$0")/.."

APP="build/Filaway.app/Contents/MacOS/Filaway"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

if [ ! -x "$APP" ]; then
  echo "smoke: building the app bundle first"
  Tools/make_app.sh >/dev/null || { echo "smoke: make_app.sh failed"; exit 1; }
fi

STAMP="$(date +%s)-$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/filaway-smoke-XXXXXX")"
ROOT="$WORK/Notes"
EDITOR_ROOT="$WORK/EditorNotes"
SUPPORT="$WORK/Support"
SUITE="com.tejaspanse.filaway.smoke.$STAMP"
mkdir -p "$ROOT" "$EDITOR_ROOT"

failures=0
app_pid=""

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill -9 "$app_pid" 2>/dev/null
  fi
  defaults delete "$SUITE" >/dev/null 2>&1
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
  if [ "$KEEP" = "1" ]; then
    echo "smoke: kept $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

# run_phase <name> <timeout-seconds>
run_phase() {
  local phase="$1" limit="$2" status
  local root="$ROOT"
  [ "$phase" = "editor" ] && root="$EDITOR_ROOT"
  echo
  echo "=== smoke phase: $phase ==============================================="
  FILAWAY_SMOKE="$phase" \
  FILAWAY_NOTES_ROOT="$root" \
  FILAWAY_SUPPORT_ROOT="$SUPPORT" \
  FILAWAY_DEFAULTS_SUITE="$SUITE" \
    "$APP" 2>&1 &
  app_pid=$!

  ( sleep "$limit"; kill -9 "$app_pid" 2>/dev/null ) &
  local watchdog=$!

  wait "$app_pid"
  status=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  app_pid=""

  if [ "$status" -ge 128 ]; then
    echo "SMOKE FAIL phase-$phase — killed after ${limit}s (signal $((status - 128)))"
    status=1
  fi
  failures=$((failures + status))
  echo "smoke: phase $phase exited $status"
}

run_phase editor 90
run_phase 1 90
run_phase 2 60

echo
echo "SMOKE result failures=$failures"
exit $((failures > 120 ? 120 : failures))
