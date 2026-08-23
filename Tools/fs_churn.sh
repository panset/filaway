#!/usr/bin/env bash
# fs_churn.sh — hammer a Filaway notes folder from outside the app (DS-4).
#
# Creates, edits, moves, renames and deletes .md files in a loop so the running
# app's FSEvents watcher and reconciler are exercised the way a user with BBEdit,
# Finder and a git checkout would exercise them. The DoD for M1 is: no note lost,
# no duplicates in the sidebar, moves tracked, and a conflict copy created only
# when the editor buffer was dirty.
#
# Usage:
#   Tools/fs_churn.sh                          # 200 ops in a fresh temp root
#   Tools/fs_churn.sh --root ~/Notes -n 500    # against a live library
#   Tools/fs_churn.sh --root ~/Notes --delay 0.3 --seed 7
#
# Options:
#   --root DIR     notes root to churn (default: a fresh mktemp -d)
#   -n, --ops N    number of operations (default 200)
#   --delay SEC    pause between operations (default 0.05)
#   --seed N       RANDOM seed, for a repeatable sequence (default: time-based)
#   --keep         keep a generated temp root instead of deleting it
#   -q, --quiet    only print the summary
#   -h, --help     this text
#
# The equivalent churn runs in-process in Tests/FilawayCoreTests/ChurnTests.swift,
# which asserts the invariants automatically; this script is for watching the UI.

set -euo pipefail

ROOT=""
OPS=200
DELAY=0.05
SEED=$(date +%s)
KEEP=0
QUIET=0
GENERATED=0

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    -n|--ops) OPS="$2"; shift 2 ;;
    --delay) DELAY="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fs_churn.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$ROOT" ]]; then
  ROOT="$(mktemp -d)/Notes"
  GENERATED=1
fi
mkdir -p "$ROOT"

RANDOM=$SEED
FOLDERS=("" "Commands" "Ideas" "Commands/Docker" "Ideas/Weekly")
for folder in "${FOLDERS[@]}"; do
  [[ -n "$folder" ]] && mkdir -p "$ROOT/$folder"
done

created=0; edited=0; moved=0; renamed=0; deleted=0; skipped=0

log() { [[ $QUIET -eq 1 ]] || echo "$@"; }

# Every .md file under the root, one per line.
list_notes() { find "$ROOT" -type f -name '*.md' 2>/dev/null || true; }

random_note() { list_notes | sort -R | head -1; }

random_folder() { echo "${FOLDERS[$((RANDOM % ${#FOLDERS[@]}))]}"; }

note_path() {
  local folder="$1" stem="$2"
  if [[ -z "$folder" ]]; then echo "$ROOT/$stem.md"; else echo "$ROOT/$folder/$stem.md"; fi
}

# A free filename in `folder`, suffixing " 2", " 3", … like the app does.
free_path() {
  local folder="$1" stem="$2" candidate
  candidate="$(note_path "$folder" "$stem")"
  local n=2
  while [[ -e "$candidate" ]]; do
    candidate="$(note_path "$folder" "$stem $n")"
    n=$((n + 1))
  done
  echo "$candidate"
}

op_create() {
  local path; path="$(free_path "$(random_folder)" "churn $RANDOM")"
  {
    echo "# ${path##*/}"
    echo
    echo "Written by fs_churn.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    echo
    echo '```sh'
    echo "curl -sS https://example.com/$RANDOM"
    echo '```'
  } > "$path"
  created=$((created + 1))
  log "create  ${path#"$ROOT"/}"
}

op_edit() {
  local path; path="$(random_note)"
  [[ -z "$path" ]] && { skipped=$((skipped + 1)); return; }
  echo "" >> "$path"
  echo "External edit $RANDOM at $(date -u +%H:%M:%S)." >> "$path"
  edited=$((edited + 1))
  log "edit    ${path#"$ROOT"/}"
}

# Rewrite in place the way an editor with atomic save does: temp file + rename.
op_rewrite() {
  local path; path="$(random_note)"
  [[ -z "$path" ]] && { skipped=$((skipped + 1)); return; }
  local tmp; tmp="$(mktemp)"
  { cat "$path"; echo "Rewritten $RANDOM."; } > "$tmp"
  mv "$tmp" "$path"
  edited=$((edited + 1))
  log "rewrite ${path#"$ROOT"/}"
}

op_move() {
  local path; path="$(random_note)"
  [[ -z "$path" ]] && { skipped=$((skipped + 1)); return; }
  local stem; stem="$(basename "$path" .md)"
  local target; target="$(free_path "$(random_folder)" "$stem")"
  [[ "$target" == "$path" ]] && { skipped=$((skipped + 1)); return; }
  mv "$path" "$target"
  moved=$((moved + 1))
  log "move    ${path#"$ROOT"/} -> ${target#"$ROOT"/}"
}

op_rename() {
  local path; path="$(random_note)"
  [[ -z "$path" ]] && { skipped=$((skipped + 1)); return; }
  local folder; folder="$(dirname "$path")"
  local target; target="$folder/renamed $RANDOM.md"
  mv "$path" "$target"
  renamed=$((renamed + 1))
  log "rename  ${path#"$ROOT"/} -> ${target#"$ROOT"/}"
}

op_delete() {
  local path; path="$(random_note)"
  [[ -z "$path" ]] && { skipped=$((skipped + 1)); return; }
  rm -f "$path"
  deleted=$((deleted + 1))
  log "delete  ${path#"$ROOT"/}"
}

log "fs_churn: root=$ROOT ops=$OPS seed=$SEED delay=$DELAY"

for ((i = 0; i < OPS; i++)); do
  case $((RANDOM % 10)) in
    0|1|2) op_create ;;
    3|4|5) op_edit ;;
    6)     op_rewrite ;;
    7)     op_move ;;
    8)     op_rename ;;
    9)     op_delete ;;
  esac
  sleep "$DELAY"
done

remaining=$(list_notes | wc -l | tr -d ' ')
echo "fs_churn: $OPS ops — created=$created edited=$edited moved=$moved renamed=$renamed deleted=$deleted skipped=$skipped"
echo "fs_churn: $remaining .md files remain under $ROOT"

if [[ $GENERATED -eq 1 && $KEEP -eq 0 ]]; then
  rm -rf "$(dirname "$ROOT")"
  echo "fs_churn: temp root removed (pass --keep to retain it)"
fi
