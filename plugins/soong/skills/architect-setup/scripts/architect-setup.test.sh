#!/usr/bin/env bash
# Self-check for architect-setup.sh. Run: bash architect-setup.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/architect-setup.sh"
XDG_DATA_HOME="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
export XDG_DATA_HOME
config="$XDG_DATA_HOME/soong/architect.json"
trap 'rm -rf "$XDG_DATA_HOME"' EXIT

# A repo to key off, so the tests never depend on the checkout they run from.
repo="$XDG_DATA_HOME/keytest"
git init -q "$repo" 2>/dev/null

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
run() { bash "$script" "$@" >/dev/null 2>&1; echo $?; }   # exit code only
seed() { mkdir -p "$(dirname "$config")"; printf '%s' "$1" > "$config"; }

# get on an empty config exits 3, so the skill can branch to setup
out="$(bash "$script" get demo 2>/dev/null)"
check "get unset exits 3" 3 "$(run get demo)"
check "get unset prints nothing" "" "$out"

# set stores both dbs and returns the record
check "set exits 0" 0 "$(run set --roadmap-db R1 --task-db T1 demo)"
rec="$(bash "$script" get demo)"
check "roadmapDb stored"           R1   "$(jq -r .roadmapDb   <<<"$rec")"
check "taskDb stored"              T1   "$(jq -r .taskDb      <<<"$rec")"
check "template null when omitted" null "$(jq -r .taskTemplate <<<"$rec")"

# template is optional but persisted when given
bash "$script" set --roadmap-db R2 --task-db T2 --task-template TPL demo >/dev/null 2>&1
rec="$(bash "$script" get demo)"
check "template stored" TPL "$(jq -r .taskTemplate <<<"$rec")"
check "set overwrites"  R2  "$(jq -r .roadmapDb    <<<"$rec")"

# --flag=value form works too
check "eq-form exits 0" 0 "$(run set --roadmap-db=R3 --task-db=T3 --task-template=TPL3 demo)"
check "eq-form stored"  R3 "$(bash "$script" get demo | jq -r .roadmapDb)"

# empty template string clears rather than storing ""
bash "$script" set --roadmap-db R2 --task-db T2 --task-template= demo >/dev/null 2>&1
check "empty template is null" null "$(bash "$script" get demo | jq -r .taskTemplate)"

# a second project does not clobber the first
bash "$script" set --roadmap-db R9 --task-db T9 other >/dev/null 2>&1
check "other project stored" R9 "$(bash "$script" get other | jq -r .roadmapDb)"
check "first project intact" R2 "$(bash "$script" get demo  | jq -r .roadmapDb)"

# a stored false is a real value, not "unconfigured" (jq -e would conflate them)
seed '{"falsy":false}'
check "stored false is found" 0 "$(run get falsy)"
check "stored false is echoed" false "$(bash "$script" get falsy)"

# missing required flags are rejected, not silently defaulted
check "missing --roadmap-db exits 2" 2 "$(run set --task-db T only-task)"
check "missing --task-db exits 2"    2 "$(run set --roadmap-db R only-roadmap)"
check "rejected set wrote nothing"   3 "$(run get only-task)"

# a flag given where a value belongs is an error, not a stored database id
check "flag as value exits 2" 2 "$(run set --roadmap-db --task-db T2 proj)"
check "flag-as-value stored nothing" 3 "$(run get proj)"
# a flag with no value at all, at the end of the line
check "trailing flag needs a value" 2 "$(run set --roadmap-db R --task-db)"

# extra positionals are an error, not a silent retarget
check "extra positional exits 2" 2 "$(run set --roadmap-db R --task-db T alpha beta)"
check "extra positional wrote nothing" 3 "$(run get alpha)"
check "get extra arg exits 2" 2 "$(run get alpha beta)"

check "unknown command exits 2" 2 "$(run bogus)"
check "unknown flag exits 2"    2 "$(run set --nope X --roadmap-db R --task-db T p)"
check "no args exits 2"         2 "$(run)"
check "--help exits 0"          0 "$(run --help)"

# corrupt config is an error (exit 1), never "unconfigured" (exit 3): a 3 here
# would send the caller into setup, which then refuses to overwrite. Deadlock.
seed 'not json'
check "corrupt config get exits 1" 1 "$(run get demo)"
check "corrupt config set exits 1" 1 "$(run set --roadmap-db R --task-db T demo)"
check "corrupt config preserved" "not json" "$(cat "$config")"

# a parseable non-object is also an error, not a jq crash
seed '[1,2]'
check "array config get exits 1" 1 "$(run get demo)"
check "array config set exits 1" 1 "$(run set --roadmap-db R --task-db T demo)"
check "array config preserved" "[1,2]" "$(cat "$config")"

# a failed write must not report success, and must leave the old value in place
seed '{}'
bash "$script" set --roadmap-db OLD --task-db OLDT demo >/dev/null 2>&1
if chflags uchg "$config" 2>/dev/null; then
  check "failed write exits nonzero" nonzero \
    "$([ "$(run set --roadmap-db NEW --task-db NEWT demo)" -ne 0 ] && echo nonzero || echo zero)"
  check "failed write kept old value" OLD "$(jq -r '.demo.roadmapDb' "$config")"
  chflags nouchg "$config"
  check "failed write left no temp file" 0 \
    "$(find "$(dirname "$config")" -name '.architect.*' | wc -l | tr -d ' ')"
else
  echo "skip - failed-write checks (chflags unavailable)"
fi

# the key is the repo, not the worktree: one repo is one mapping
if [ -d "$repo/.git" ]; then
  ( cd "$repo" && bash "$script" set --roadmap-db RKEY --task-db TKEY >/dev/null 2>&1 )
  check "keyed by repo name" RKEY "$( (cd "$repo" && bash "$script" get) | jq -r .roadmapDb)"
  check "key is the repo dir" 0 "$(jq -e 'has("keytest")' "$config" >/dev/null; echo $?)"
  if git -C "$repo" worktree add -q "$XDG_DATA_HOME/wt" -b wt-branch 2>/dev/null; then
    check "worktree reads the repo mapping" RKEY \
      "$( (cd "$XDG_DATA_HOME/wt" && bash "$script" get) | jq -r .roadmapDb)"
    # writing from the worktree updates the repo's key, it does not add one
    before="$(jq -r 'keys | length' "$config")"
    ( cd "$XDG_DATA_HOME/wt" && bash "$script" set --roadmap-db RWT --task-db TWT >/dev/null 2>&1 )
    check "worktree write added no key" "$before" "$(jq -r 'keys | length' "$config")"
    check "worktree write hit the repo key" RWT "$(jq -r '.keytest.roadmapDb' "$config")"
  else
    echo "skip - worktree checks (git worktree add failed)"
  fi
else
  echo "skip - repo-key checks (git init failed)"
fi

# outside a git repo: a usage error (2), never a silent write under an empty key
cd /
check "set outside a repo exits 2" 2 "$(run set --roadmap-db R --task-db T)"
check "get outside a repo exits 2" 2 "$(run get)"
check "no empty-string key written" 1 "$(jq -e 'has("")' "$config" >/dev/null 2>&1; echo $?)"

echo
[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
