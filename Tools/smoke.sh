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
#   semantic the M3-06 ⌘K Ask checks on the same corpus with fixed mtimes:
#           ⏎ → answer card, Copy, open-scrolled-to-chunk, the temporal filter
#           and the offline notice
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

STAMP="$(date +%s)-$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/filaway-smoke-XXXXXX")"
ROOT="$WORK/Notes"
EDITOR_ROOT="$WORK/EditorNotes"
SEARCH_ROOT="$WORK/SearchNotes"
SEMANTIC_ROOT="$WORK/SemanticNotes"
KILL_ROOT="$WORK/KillNotes"
SETTINGS_ROOT="$WORK/SettingsNotes"
SUPPORT="$WORK/Support"
SUITE="com.tejaspanse.filaway.smoke.$STAMP"
# The settings phases need their own defaults domain: they write preferences the
# capture phases must not inherit, and phase `settings2` reads them back.
SETTINGS_SUITE="com.tejaspanse.filaway.smoke.settings.$STAMP"
mkdir -p "$ROOT" "$EDITOR_ROOT" "$SEARCH_ROOT" "$SEMANTIC_ROOT" "$KILL_ROOT" "$SETTINGS_ROOT"

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

# The semantic phase reuses the same three notes, then pins their modification
# times so FR-5.3's "two days ago" has exactly one note to find. Titles, the
# command and the ages are asserted in Features/Search/SemanticSmokeCheck.swift
# — keep in step.
seed_semantic_corpus() {
  local root="$1"
  seed_search_corpus "$root"
  touch -t "$(date -v-10d +%Y%m%d%H%M)" "$root/Commands/Staging docs.md"
  touch -t "$(date -v-2d  +%Y%m%d%H%M)" "$root/Auth API debug.md"
  touch -t "$(date -v-20d +%Y%m%d%H%M)" "$root/Docker cheats.md"
}
seed_semantic_corpus "$SEMANTIC_ROOT"

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
  local root="$ROOT" suite="$SUITE"
  [ "$phase" = "editor" ] && root="$EDITOR_ROOT"
  [ "$phase" = "search" ] && root="$SEARCH_ROOT"
  [ "$phase" = "semantic" ] && root="$SEMANTIC_ROOT"
  [ "$phase" = "killcheck" ] && root="$KILL_ROOT"
  case "$phase" in
    settings|settings2) root="$SETTINGS_ROOT"; suite="$SETTINGS_SUITE" ;;
  esac
  echo
  echo "=== smoke phase: $phase ==============================================="
  FILAWAY_SMOKE="$phase" \
  FILAWAY_NOTES_ROOT="$root" \
  FILAWAY_SUPPORT_ROOT="$SUPPORT" \
  FILAWAY_DEFAULTS_SUITE="$suite" \
  FILAWAY_AI_MODE="${FILAWAY_AI_MODE:-replay}" \
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
run_kill_phase
run_phase killcheck 60
run_phase 1 90
run_phase 2 60
run_phase settings 90
run_phase settings2 60
# Last: the embedder compiles the bundled Core ML package on first use, which
# can take a few seconds on a cold Application Support.
run_phase semantic 240

echo
echo "SMOKE result failures=$failures"
exit $((failures > 120 ? 120 : failures))
