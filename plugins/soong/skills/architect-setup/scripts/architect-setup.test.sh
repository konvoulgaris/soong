#!/usr/bin/env bash
# Self-check for architect-setup.sh. Run: bash architect-setup.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/architect-setup.sh"
XDG_DATA_HOME="$(mktemp -d)"; export XDG_DATA_HOME
trap 'rm -rf "$XDG_DATA_HOME"' EXIT

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}

# get on an empty config exits 3, so the skill can branch to setup
out="$(bash "$script" get demo 2>/dev/null)"; check "get unset exits 3" 3 "$?"
check "get unset prints nothing" "" "$out"

# set stores both dbs and returns the record
bash "$script" set --roadmap-db R1 --task-db T1 demo >/dev/null 2>&1
check "set exits 0" 0 "$?"
check "roadmapDb stored" R1 "$(bash "$script" get demo | jq -r .roadmapDb)"
check "taskDb stored"    T1 "$(bash "$script" get demo | jq -r .taskDb)"
check "template null when omitted" null "$(bash "$script" get demo | jq -r .taskTemplate)"
check "get set exits 0" 0 "$(bash "$script" get demo >/dev/null 2>&1; echo $?)"

# template is optional but persisted when given
bash "$script" set --roadmap-db R2 --task-db T2 --task-template TPL demo >/dev/null 2>&1
check "template stored" TPL "$(bash "$script" get demo | jq -r .taskTemplate)"
check "set overwrites"  R2  "$(bash "$script" get demo | jq -r .roadmapDb)"

# empty template string clears rather than storing ""
bash "$script" set --roadmap-db R2 --task-db T2 --task-template "" demo >/dev/null 2>&1
check "empty template is null" null "$(bash "$script" get demo | jq -r .taskTemplate)"

# a second project does not clobber the first
bash "$script" set --roadmap-db R9 --task-db T9 other >/dev/null 2>&1
check "other project stored" R9 "$(bash "$script" get other | jq -r .roadmapDb)"
check "first project intact" R2 "$(bash "$script" get demo  | jq -r .roadmapDb)"

# missing required flags are rejected, not silently defaulted
bash "$script" set --task-db T only-task >/dev/null 2>&1
check "missing --roadmap-db exits 2" 2 "$?"
bash "$script" set --roadmap-db R only-roadmap >/dev/null 2>&1
check "missing --task-db exits 2" 2 "$?"
check "rejected set wrote nothing" 3 "$(bash "$script" get only-task >/dev/null 2>&1; echo $?)"

bash "$script" bogus >/dev/null 2>&1
check "unknown command exits 2" 2 "$?"

# corrupt config is reported, not overwritten
echo 'not json' > "$XDG_DATA_HOME/soong/architect.json"
bash "$script" set --roadmap-db R --task-db T demo >/dev/null 2>&1
check "corrupt config exits 1" 1 "$?"
check "corrupt config preserved" "not json" "$(cat "$XDG_DATA_HOME/soong/architect.json")"

echo
[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
