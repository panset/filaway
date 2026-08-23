#!/usr/bin/env bash
#
# Headless UI smoke test for the shell (plan §8: no Xcode ⇒ no XCTest UI tests,
# and the screen may be locked).
#
# Runs build/Filaway.app three times against a throwaway notes root and a
# throwaway preferences domain:
#
#   editor  the M1-10 editor checks, on a note read back from disk
#   search  the M1-12 ⌘K checks on a three-note corpus seeded *before* launch:
#           as-you-type hits, ↑/↓/⏎/Esc, open-scrolled-to-match, fuzzy titles,
#           recents on an empty query
#   organize  M2: seed the library a committed AI fixture was recorded against,
#           type the session, end it at the fixture's instant, then Accept →
#           the bytes move → Activity has the event → Undo restores them
#   organize-auto     the same session in auto mode: applied unasked, card
#           offers Undo
#   organize-offline  the provider fails with a network error: nothing changes,
#           the session is queued durably, no modal, capture still works
#   kill    type → wait out the 750 ms debounce → type again → the script sends
#           SIGKILL (no terminate handler, no flush)
#   killcheck relaunch after the SIGKILL: the debounced burst is on disk and the
#           library opens cleanly (FR-2.3, NFR-3)
#   1       empty sidebar → ⌘N → type → autosave lands → rename renames the
#           file → an external edit reaches the sidebar → quit mid-burst
#   2       relaunch on the same root: last note restored, last burst survived
#   settings   ⌘, opens Settings; the Figure 4 rows write through AppSettings;
#              the idle interval clamps; AIConnectionManager walks
#   settings2  relaunch: every one of those preferences came back
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

# A newly launched app cannot create a window while the screen is locked
# (macOS 26). Every phase then fails at "library open" with no window lines at
# all, because SwiftUI never builds the scene and `AppModel.bootstrap()` never
# runs — a confusing 26-failure report for an environment problem. Say so.
#
# `grep -c`, not `grep -q`: under `set -o pipefail` a quiet grep exits early,
# `ioreg` dies of SIGPIPE, and the pipeline reports 141 even on a match.
SCREEN_LOCKED=0
if [ "$(ioreg -n Root -d1 -a 2>/dev/null | grep -c CGSSessionScreenIsLocked)" != "0" ]; then
  SCREEN_LOCKED=1
  echo "smoke: WARNING — the screen is locked. A launched app gets no window, so"
  echo "smoke:           every phase will fail at library-open. Unlock and re-run."
fi

STAMP="$(date +%s)-$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/filaway-smoke-XXXXXX")"
ROOT="$WORK/Notes"
EDITOR_ROOT="$WORK/EditorNotes"
SEARCH_ROOT="$WORK/SearchNotes"
KILL_ROOT="$WORK/KillNotes"
SETTINGS_ROOT="$WORK/SettingsNotes"
SUPPORT="$WORK/Support"
SUITE="com.tejaspanse.filaway.smoke.$STAMP"
# The settings phases need their own defaults domain: they write preferences the
# capture phases must not inherit, and phase `settings2` reads them back.
SETTINGS_SUITE="com.tejaspanse.filaway.smoke.settings.$STAMP"
# One root per organize phase: each seeds the same fixture corpus from scratch
# and each needs its own Application Support so the baselines and the Activity
# journal start empty.
ORGANIZE_ROOT="$WORK/OrganizeNotes"
ORGANIZE_AUTO_ROOT="$WORK/OrganizeAutoNotes"
ORGANIZE_OFFLINE_ROOT="$WORK/OrganizeOfflineNotes"
mkdir -p "$ROOT" "$EDITOR_ROOT" "$SEARCH_ROOT" "$KILL_ROOT" "$SETTINGS_ROOT" \
         "$ORGANIZE_ROOT" "$ORGANIZE_AUTO_ROOT" "$ORGANIZE_OFFLINE_ROOT"

# Committed replay fixtures — `FILAWAY_AI_MODE=replay` reads them through
# `AIRecordingStore.fromEnvironment()`. No key, no network, no cost.
FIXTURES="$PWD/Tests/Fixtures/ai-recordings"

# Three notes on disk before the app ever runs, so the search phase also proves
# a cold launch indexes a library Filaway has never seen. Titles and the tail
# phrase are asserted in Features/Search/SearchSmokeCheck.swift — keep in step.
seed_search_corpus() {
  local root="$1"
  mkdir -p "$root/Commands"
  {
    echo "Notes from the staging spike."
    echo
    # ~160 lines of filler: the code block below has to start well past one
    # screenful, so "the editor scrolled to the match" is a real assertion.
    i=1
    while [ "$i" -le 160 ]; do
      echo "Line $i — background on the staging environment and its quirks."
      i=$((i + 1))
    done
    echo
    echo "curl to fetch docs from staging:"
    echo
    echo '```bash'
    echo 'curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs'
    echo '```'
    echo
    echo "remember: token expires hourly"
  } > "$root/Commands/Staging docs.md"

  {
    echo "The 401 only happens after the bearer token rotates."
    echo
    echo "- [ ] rotate the staging token"
    echo "- [ ] check the refresh window"
  } > "$root/Auth API debug.md"

  {
    echo "Handy container commands."
    echo
    echo '```bash'
    echo 'curl -fsS http://localhost:8080/healthz'
    echo '```'
  } > "$root/Docker cheats.md"
}
seed_search_corpus "$SEARCH_ROOT"

failures=0
app_pid=""

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill -9 "$app_pid" 2>/dev/null
  fi
  defaults delete "$SUITE" >/dev/null 2>&1
  defaults delete "$SETTINGS_SUITE" >/dev/null 2>&1
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
  rm -f "$HOME/Library/Preferences/$SETTINGS_SUITE.plist"
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
  local root="$ROOT" suite="$SUITE" support="$SUPPORT" fail=""
  [ "$phase" = "editor" ] && root="$EDITOR_ROOT"
  [ "$phase" = "search" ] && root="$SEARCH_ROOT"
  [ "$phase" = "killcheck" ] && root="$KILL_ROOT"
  case "$phase" in
    settings|settings2) root="$SETTINGS_ROOT"; suite="$SETTINGS_SUITE" ;;
    organize)         root="$ORGANIZE_ROOT";         support="$WORK/SupportOrganize" ;;
    organize-auto)    root="$ORGANIZE_AUTO_ROOT";    support="$WORK/SupportOrganizeAuto" ;;
    organize-offline) root="$ORGANIZE_OFFLINE_ROOT"; support="$WORK/SupportOrganizeOffline"
                      fail="network" ;;
  esac
  echo
  echo "=== smoke phase: $phase ==============================================="
  FILAWAY_SMOKE="$phase" \
  FILAWAY_NOTES_ROOT="$root" \
  FILAWAY_SUPPORT_ROOT="$support" \
  FILAWAY_DEFAULTS_SUITE="$suite" \
  FILAWAY_AI_MODE="replay" \
  FILAWAY_AI_FIXTURES="$FIXTURES" \
  FILAWAY_AI_FAIL="$fail" \
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

# FR-2.3 / NFR-3: the app is SIGKILLed mid-edit — no terminate handler, no
# flush. The phase parks on "SMOKE ready-for-kill"; we kill it there.
run_kill_phase() {
  # Polled at 200 ms so SIGKILL lands close to the last keystroke — killing a
  # second later would let the 750 ms debounce flush it and make the assertion
  # vacuous.
  local out="$WORK/kill.log" waited=0 limit=300
  echo
  echo "=== smoke phase: kill ==============================================="
  FILAWAY_SMOKE="kill" \
  FILAWAY_NOTES_ROOT="$KILL_ROOT" \
  FILAWAY_SUPPORT_ROOT="$SUPPORT" \
  FILAWAY_DEFAULTS_SUITE="$SUITE" \
  FILAWAY_AI_MODE="replay" \
  FILAWAY_AI_FIXTURES="$FIXTURES" \
    "$APP" > "$out" 2>&1 &
  app_pid=$!

  while [ "$waited" -lt "$limit" ]; do
    grep -q "SMOKE ready-for-kill" "$out" 2>/dev/null && break
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.2
    waited=$((waited + 1))
  done

  local ready=1
  grep -q "SMOKE ready-for-kill" "$out" 2>/dev/null || ready=0
  kill -9 "$app_pid" 2>/dev/null
  wait "$app_pid" 2>/dev/null
  app_pid=""
  cat "$out"

  if [ "$ready" = "1" ]; then
    echo "smoke: phase kill — SIGKILL delivered mid-edit"
  else
    echo "SMOKE FAIL phase-kill — never reached the kill point"
    failures=$((failures + 1))
  fi
}

run_phase editor 90
run_phase search 120
run_phase organize 150
run_phase organize-auto 150
run_phase organize-offline 120
run_kill_phase
run_phase killcheck 60
run_phase 1 90
run_phase 2 60
run_phase settings 90
run_phase settings2 60

echo
if [ "$failures" -gt 0 ] && [ "$SCREEN_LOCKED" = "1" ]; then
  echo "smoke: the screen was locked for this run — the failures above are almost"
  echo "smoke: certainly that, not the code. Unlock the screen and re-run."
fi
echo "SMOKE result failures=$failures"
exit $((failures > 120 ? 120 : failures))
