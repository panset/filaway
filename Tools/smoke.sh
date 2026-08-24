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
#   paste      M4-03: a curl line goes on the real pasteboard, ⌘V lands it
#              verbatim, the affordance appears, Wrap fences it, ⌘Z undoes it
#              in one step, prose offers nothing, the setting turns it off
#   onboarding M4-01: first launch shows the three-step flow; a temp folder is
#              chosen; the mock key validates; finishing writes the bookmark and
#              opens the library at the chosen folder
#   onboarding2  relaunch: no flow, same library
#   onboardingskip  the "Skip for now" path: the gentle sidebar prompt appears
#   onboarding-ollama  P2-03: Figure 3's local-model card — selected, tested
#              against an injected validator (no daemon), Continue unlocks, and
#              Finish writes ai.provider / ai.ollama.baseURL / ai.ollama.model
#   onboarding-ollama2  relaunch: the provider preference persisted
#   organize-ollama-suite  GATED, P2-09. Three live scenarios on the library
#              shapes real dogfooding failed on: a folderless library with a
#              bulleted feedback session (ask), the same library with a command
#              note (auto), and a library whose right answer is a folder that
#              already exists (auto). A rejected plan is a phase failure.
#   organize-ollama  GATED. The organize session against a *live* local model.
#              Runs only with FILAWAY_SMOKE_OLLAMA=1 and a daemon answering
#              localhost:11434; otherwise it prints SKIPPED and costs nothing.
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

# **`-ApplePersistenceIgnoreState YES` is not optional here.** The `kill` phase
# SIGKILLs the app on purpose, and the watchdog SIGKILLs any phase that
# overstays, so Filaway accumulates a crash history by design. Once macOS
# decides the app "quit unexpectedly", `NSPersistentUIRestorer` puts up a
# *modal* "reopen its windows?" alert from inside `_handleAEOpenEvent` — before
# `applicationDidFinishLaunching` runs, before any smoke phase starts, and with
# nobody to answer it. Every phase then hangs silently until the watchdog kills
# it, which adds another crash to the history. The flag skips the persistent-UI
# machinery entirely. Symptom, if it ever comes back: a phase that produces no
# output at all and is killed at its timeout. `sample <pid>` names it.
STAMP="$(date +%s)-$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/filaway-smoke-XXXXXX")"
ROOT="$WORK/Notes"
EDITOR_ROOT="$WORK/EditorNotes"
SEARCH_ROOT="$WORK/SearchNotes"
SEMANTIC_ROOT="$WORK/SemanticNotes"
KILL_ROOT="$WORK/KillNotes"
SETTINGS_ROOT="$WORK/SettingsNotes"
WIRING_ROOT="$WORK/WiringNotes"
A11Y_ROOT="$WORK/A11yNotes"
PASTE_ROOT="$WORK/PasteNotes"
# M4-01 chooses these through the flow, so they are *not* passed as
# FILAWAY_NOTES_ROOT — the point of the phase is that the bookmark decides.
ONBOARD_ROOT="$WORK/OnboardChosen"
ONBOARD_SKIP_ROOT="$WORK/OnboardSkipChosen"
ONBOARD_OLLAMA_ROOT="$WORK/OnboardOllamaChosen"
SUPPORT="$WORK/Support"
SUITE="com.tejaspanse.filaway.smoke.$STAMP"
# The settings phases need their own defaults domain: they write preferences the
# capture phases must not inherit, and phase `settings2` reads them back.
SETTINGS_SUITE="com.tejaspanse.filaway.smoke.settings.$STAMP"
# M4-02/M4-06 each get their own domain and Application Support: `settings-wiring`
# rewrites every FR-8.1 preference and rebuilds a semantic index from scratch,
# and `a11y` must not inherit either.
WIRING_SUITE="com.tejaspanse.filaway.smoke.wiring.$STAMP"
A11Y_SUITE="com.tejaspanse.filaway.smoke.a11y.$STAMP"
# One root per organize phase: each seeds the same fixture corpus from scratch
# and each needs its own Application Support so the baselines and the Activity
# journal start empty.
ORGANIZE_ROOT="$WORK/OrganizeNotes"
ORGANIZE_AUTO_ROOT="$WORK/OrganizeAutoNotes"
ORGANIZE_OFFLINE_ROOT="$WORK/OrganizeOfflineNotes"
# P2-03's gated live phase gets its own everything, because it is the one phase
# that talks to a real model and must not inherit a replayed baseline.
ORGANIZE_OLLAMA_ROOT="$WORK/OrganizeOllamaNotes"
# P2-09's live suite makes a *fresh library per scenario* underneath this one
# (`AppModel.reopenLibrary`), so this directory is a parent, not a corpus.
ORGANIZE_OLLAMA_SUITE_ROOT="$WORK/OrganizeOllamaSuiteNotes"

# Committed replay fixtures — `FILAWAY_AI_MODE=replay` reads them through
# `AIRecordingStore.fromEnvironment()`. No key, no network, no cost.
FIXTURES="$PWD/Tests/Fixtures/ai-recordings"

# Onboarding needs a suite with no `onboarding.completed` in it, and the skip
# variant needs one the connected variant has not already answered.
ONBOARD_SUITE="com.tejaspanse.filaway.smoke.onboard.$STAMP"
ONBOARD_SKIP_SUITE="com.tejaspanse.filaway.smoke.onboardskip.$STAMP"
ONBOARD_OLLAMA_SUITE="com.tejaspanse.filaway.smoke.onboardollama.$STAMP"
OLLAMA_SUITE="com.tejaspanse.filaway.smoke.ollama.$STAMP"
OLLAMA_SUITE_SUITE="com.tejaspanse.filaway.smoke.ollamasuite.$STAMP"
mkdir -p "$ROOT" "$EDITOR_ROOT" "$SEARCH_ROOT" "$SEMANTIC_ROOT" "$KILL_ROOT" \
         "$SETTINGS_ROOT" "$PASTE_ROOT" "$WIRING_ROOT" "$A11Y_ROOT" \
         "$ORGANIZE_ROOT" "$ORGANIZE_AUTO_ROOT" "$ORGANIZE_OFFLINE_ROOT" \
         "$ORGANIZE_OLLAMA_ROOT" "$ORGANIZE_OLLAMA_SUITE_ROOT" \
         "$ONBOARD_ROOT" "$ONBOARD_SKIP_ROOT" "$ONBOARD_OLLAMA_ROOT"

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

# M4-02's `settings-wiring` phase needs notes *inside* the folder it excludes,
# so "excluding a folder purges what was already indexed" (FR-4.5) has chunks to
# purge. `Personal` is the folder name SettingsSmokeCheck.excludedFolder names —
# keep the two in step.
seed_wiring_corpus() {
  local root="$1"
  mkdir -p "$root/Personal" "$root/Commands"
  {
    echo "Private journal entry about the weekend and the garden."
    echo
    echo "Nothing here should ever reach a model."
  } > "$root/Personal/Weekend.md"
  {
    echo "Second private note, so the folder is not a single-chunk edge case."
    echo
    echo "More prose about nothing in particular, at some length, so the"
    echo "chunker has a paragraph or two to work with rather than one line."
  } > "$root/Personal/Garden.md"
  {
    echo "Public note that must survive the purge."
    echo
    echo '```bash'
    echo 'curl -fsS http://localhost:8080/healthz'
    echo '```'
  } > "$root/Commands/Health check.md"
}
seed_wiring_corpus "$WIRING_ROOT"
seed_search_corpus "$A11Y_ROOT"

failures=0
app_pid=""

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill -9 "$app_pid" 2>/dev/null
  fi
  for suite in "$SUITE" "$SETTINGS_SUITE" "$WIRING_SUITE" "$A11Y_SUITE" \
               "$ONBOARD_SUITE" "$ONBOARD_SKIP_SUITE" "$ONBOARD_OLLAMA_SUITE" \
               "$OLLAMA_SUITE" "$OLLAMA_SUITE_SUITE"; do
    defaults delete "$suite" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$suite.plist"
  done
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
  # FILAWAY_SMOKE_ONLY="organize-ollama settings" runs just those phases — for
  # iterating on one phase without paying for the suite. Unset = every phase.
  if [ -n "${FILAWAY_SMOKE_ONLY:-}" ]; then
    case " $FILAWAY_SMOKE_ONLY " in
      *" $phase "*) ;;
      *) return ;;
    esac
  fi
  # **Defaults, and they are load-bearing.** `set -u` is on, so an unset
  # `ai_mode` is a fatal expansion error inside the launch command — which runs
  # in a subshell because of the `> >(tee …)` process substitution, so the
  # subshell dies, runs the inherited EXIT trap, and deletes `$WORK` out from
  # under every later phase. Every phase but `organize-ollama` replays (ADR-035).
  local ai_mode="replay" ai_provider=""
  local root="$ROOT" suite="$SUITE" support="$SUPPORT" fail="" onboard_root="" shots=""
  [ "$phase" = "editor" ] && root="$EDITOR_ROOT"
  [ "$phase" = "search" ] && root="$SEARCH_ROOT"
  [ "$phase" = "semantic" ] && root="$SEMANTIC_ROOT"
  [ "$phase" = "killcheck" ] && root="$KILL_ROOT"
  local onboard_root=""
  case "$phase" in
    settings|settings2) root="$SETTINGS_ROOT"; suite="$SETTINGS_SUITE" ;;
    settings-wiring) root="$WIRING_ROOT"; suite="$WIRING_SUITE"; support="$WORK/SupportWiring" ;;
    a11y)            root="$A11Y_ROOT";   suite="$A11Y_SUITE";   support="$WORK/SupportA11y"
                     # NFR-7's light/dark bitmaps. Written into the throwaway
                     # work directory and never committed; `--keep` is how a
                     # human gets to look at them.
                     shots="$WORK/shots" ;;
    organize)         root="$ORGANIZE_ROOT";         support="$WORK/SupportOrganize" ;;
    organize-auto)    root="$ORGANIZE_AUTO_ROOT";    support="$WORK/SupportOrganizeAuto" ;;
    organize-offline) root="$ORGANIZE_OFFLINE_ROOT"; support="$WORK/SupportOrganizeOffline"
                      fail="network" ;;
    paste) root="$PASTE_ROOT" ;;
    # The onboarding phases pass an *empty* FILAWAY_NOTES_ROOT so the app falls
    # through to the bookmark the flow writes — which is the whole assertion.
    onboarding|onboarding2)
      root=""; suite="$ONBOARD_SUITE"; onboard_root="$ONBOARD_ROOT" ;;
    onboardingskip)
      root=""; suite="$ONBOARD_SKIP_SUITE"; onboard_root="$ONBOARD_SKIP_ROOT" ;;
    onboarding-ollama|onboarding-ollama2)
      root=""; suite="$ONBOARD_OLLAMA_SUITE"; onboard_root="$ONBOARD_OLLAMA_ROOT"
      support="$WORK/SupportOnboardOllama" ;;
    # P2-03: the one phase that is not replayed. `FILAWAY_AI_PROVIDER=ollama`
    # pins the backend regardless of the preference (ADR-069), and the caller
    # has already proved the daemon answers.
    organize-ollama)
      root="$ORGANIZE_OLLAMA_ROOT"; suite="$OLLAMA_SUITE"
      support="$WORK/SupportOrganizeOllama"
      ai_mode="live"; ai_provider="ollama" ;;
    # P2-09: the same live backend, three scenarios, a library per scenario.
    organize-ollama-suite)
      root="$ORGANIZE_OLLAMA_SUITE_ROOT"; suite="$OLLAMA_SUITE_SUITE"
      support="$WORK/SupportOrganizeOllamaSuite"
      ai_mode="live"; ai_provider="ollama" ;;
  esac
  echo
  echo "=== smoke phase: $phase ==============================================="
  FILAWAY_SMOKE="$phase" \
  FILAWAY_NOTES_ROOT="$root" \
  FILAWAY_ONBOARD_ROOT="$onboard_root" \
  FILAWAY_SUPPORT_ROOT="$support" \
  FILAWAY_DEFAULTS_SUITE="$suite" \
  FILAWAY_AI_MODE="$ai_mode" \
  FILAWAY_AI_PROVIDER="$ai_provider" \
  FILAWAY_AI_FIXTURES="$FIXTURES" \
  FILAWAY_AI_FAIL="$fail" \
  FILAWAY_SMOKE_SHOTS="$shots" \
    "$APP" -ApplePersistenceIgnoreState YES > >(tee -a "$WORK/transcript.log") 2>&1 &
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
  # `kill` has its own runner, so it needs its own copy of the filter — without
  # it, `FILAWAY_SMOKE_ONLY="organize"` still pays for a SIGKILL phase.
  if [ -n "${FILAWAY_SMOKE_ONLY:-}" ]; then
    case " $FILAWAY_SMOKE_ONLY " in
      *" kill "*) ;;
      *) return ;;
    esac
  fi
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
    "$APP" -ApplePersistenceIgnoreState YES > "$out" 2>&1 &
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
  cat "$out" >> "$WORK/transcript.log"

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
# M4-02: preferences reaching the live objects. Slow, because it builds a real
# semantic index (the bundled Core ML package compiles on first use).
run_phase settings-wiring 300
# M4-06: the accessibility walk and the light/dark captures.
run_phase a11y 120
run_phase paste 90
run_phase onboarding 120
run_phase onboarding2 60
run_phase onboardingskip 120
# P2-03: Figure 3's local-model card. No daemon — `OnboardingModel` injects a
# scripted validator for every smoke run, so this runs on any machine.
run_phase onboarding-ollama 120
run_phase onboarding-ollama2 60
# Last: the embedder compiles the bundled Core ML package on first use, which
# can take a few seconds on a cold Application Support.
run_phase semantic 240

# P2-03, gated: the organize session against a **live** local model. It is opt
# in twice over — the flag says "spend the minutes", and the daemon has to
# actually answer — because it costs a real generation (tens of seconds on an
# 8B model) and no CI runner has Ollama on it. Skipping is not a failure.
run_ollama_phase() {
  if [ "${FILAWAY_SMOKE_OLLAMA:-0}" != "1" ]; then
    echo
    echo "=== smoke phase: organize-ollama === SKIPPED (set FILAWAY_SMOKE_OLLAMA=1)"
    return
  fi
  if ! curl -s -m 2 "${FILAWAY_SMOKE_OLLAMA_URL:-http://localhost:11434}/api/tags" >/dev/null 2>&1; then
    echo
    echo "=== smoke phase: organize-ollama === SKIPPED (no Ollama)"
    return
  fi
  run_phase organize-ollama 240
  # Three live generations plus three library rebuilds. The per-scenario budget
  # inside the phase is 190 s; this is the outer stop.
  run_phase organize-ollama-suite 700
}
run_ollama_phase

# M4-06: AppKit's "reentrant operation in its NSTableView delegate", which it
# says "will become an assert in the future". It fires **once per population of
# the sidebar List** — a phase on an empty notes root logs none, a seeded phase
# logs one, `semantic` logs one per repopulation. It predates M4-06 and is not
# fixed; what is known and what has been ruled out is in
# `docs/a11y-checklist.md` § 5.
#
# Reported, not failed. Failing here would make `make smoke` red for every
# agent over a warning none of them introduced. The count is the regression
# signal: it should track the number of seeded phases, and going up means
# something new started reloading the sidebar.
reentrant="$(grep -c "reentrant operation" "$WORK/transcript.log" 2>/dev/null || echo 0)"
if [ "$reentrant" != "0" ]; then
  echo "SMOKE note appkit-reentrancy — $reentrant occurrences (known, unfixed: docs/a11y-checklist.md §5)"
elif [ "$SCREEN_LOCKED" = "1" ]; then
  echo "smoke: note — the NSTableView reentrancy count needs a window to mean anything"
else
  echo "SMOKE ok   appkit-reentrancy — none logged (it was $reentrant; if this sticks, close out §5)"
fi

echo
if [ "$failures" -gt 0 ] && [ "$SCREEN_LOCKED" = "1" ]; then
  echo "smoke: the screen was locked for this run — the failures above are almost"
  echo "smoke: certainly that, not the code. Unlock the screen and re-run."
fi
echo "SMOKE result failures=$failures"
exit $((failures > 120 ? 120 : failures))
