#!/usr/bin/env bash
# Self-check for soong-setup.sh. Run: bash soong-setup.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/soong-setup.sh"
XDG_DATA_HOME="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
export XDG_DATA_HOME
config="$XDG_DATA_HOME/soong/soong.json"
legacy="$XDG_DATA_HOME/soong/architect.json"
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
seed_legacy() { mkdir -p "$(dirname "$legacy")"; printf '%s' "$1" > "$legacy"; }

# get on an empty config exits 3, so the skill can branch to setup
out="$(bash "$script" get demo 2>/dev/null)"
check "get unset exits 3" 3 "$(run get demo)"
check "get unset prints nothing" "" "$out"

# set stores both dbs and returns the record
check "set exits 0" 0 "$(run set --roadmap-db R1 --task-db T1 demo)"
rec="$(bash "$script" get demo)"
check "roadmapDb stored"           R1   "$(jq -r .roadmapDb   <<<"$rec")"
check "taskDb stored"              T1   "$(jq -r .taskDb      <<<"$rec")"
check "template absent when omitted" false "$(bash "$script" get demo | jq -r 'has("taskTemplate")')"

# template is optional but persisted when given
bash "$script" set --roadmap-db R2 --task-db T2 --task-template TPL demo >/dev/null 2>&1
rec="$(bash "$script" get demo)"
check "template stored" TPL "$(jq -r .taskTemplate <<<"$rec")"
check "set overwrites"  R2  "$(jq -r .roadmapDb    <<<"$rec")"

# --flag=value form works too
check "eq-form exits 0" 0 "$(run set --roadmap-db=R3 --task-db=T3 --task-template=TPL3 demo)"
check "eq-form stored"  R3 "$(bash "$script" get demo | jq -r .roadmapDb)"

# a stored template survives a later set that omits the flag. This is the third
# state template_seen exists for: "not passed" must leave the stored value alone,
# where "passed empty" below clears it. The other two states were covered and this
# one was not, which left the merge's most load-bearing branch unexercised.
bash "$script" set --roadmap-db RK --task-db TK --task-template KEEP demo >/dev/null 2>&1
bash "$script" set --roadmap-db RK2 demo >/dev/null 2>&1
check "template survives omission" KEEP "$(bash "$script" get demo | jq -r .taskTemplate)"
check "omitting template still updates the rest" RK2 "$(bash "$script" get demo | jq -r .roadmapDb)"

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
    "$(find "$(dirname "$config")" -name '.soong.*' | wc -l | tr -d ' ')"
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

# --- soong.json with an architect.json fallback -----------------------------
rm -f "$config" "$legacy"
seed_legacy '{"legacyonly":{"roadmapDb":"LR","taskDb":"LT","taskTemplate":null}}'
check "falls back to architect.json"  0    "$(run get legacyonly)"
check "fallback reads the record"     LR   "$(bash "$script" get legacyonly | jq -r .roadmapDb)"

# soong.json wins outright; the two files are never merged
seed '{"both":{"roadmapDb":"NEW","taskDb":"NT","taskTemplate":null}}'
seed_legacy '{"both":{"roadmapDb":"OLD","taskDb":"OT","taskTemplate":null},"legacyonly":{"roadmapDb":"LR","taskDb":"LT","taskTemplate":null}}'
check "soong.json wins"            NEW "$(bash "$script" get both | jq -r .roadmapDb)"
check "no merge from the legacy file" 3 "$(run get legacyonly)"

# set always writes the new file and never touches the old one
rm -f "$config"
seed_legacy '{"migrate":{"roadmapDb":"OLD","taskDb":"OT","taskTemplate":null}}'
bash "$script" set --roadmap-db NEWR --task-db NEWT migrate >/dev/null 2>&1
check "set wrote soong.json"       NEWR "$(jq -r '.migrate.roadmapDb' "$config")"
check "set left architect.json be" OLD  "$(jq -r '.migrate.roadmapDb' "$legacy")"
rm -f "$legacy"

# --- one-time migration of architect.json to soong.json ----------------------
# The fallback alone was not enough: reads preferred soong.json and writes always
# created it, so the first set on an unmigrated repo left the Notion mapping
# stranded in architect.json where nothing would read it again. Copy the whole
# file forward once instead, so every project carries over, not just the one
# being written.
rm -f "$config" "$legacy"
seed_legacy '{"mig1":{"roadmapDb":"LR1","taskDb":"LT1","taskTemplate":null}}'
check "get migrates on read"        0    "$(run get mig1)"
check "migration wrote soong.json"  0    "$([ -f "$config" ]; echo $?)"
check "migrated content matches"    LR1  "$(jq -r '.mig1.roadmapDb' "$config")"

# the bug: a partial set on an unmigrated repo used to drop the Notion mapping
rm -f "$config" "$legacy"
seed_legacy '{"legacyrepo":{"roadmapDb":"LEGACY_R","taskDb":"LEGACY_T","taskTemplate":null}}'
bash "$script" set --require-scope true legacyrepo >/dev/null 2>&1
rec="$(bash "$script" get legacyrepo)"
check "scope set on legacy repo"    true      "$(jq -r .requireScope <<<"$rec")"
check "legacy roadmapDb survived"   LEGACY_R  "$(jq -r .roadmapDb    <<<"$rec")"
check "legacy taskDb survived"      LEGACY_T  "$(jq -r .taskDb       <<<"$rec")"

# the whole file migrates, not just the project being touched
rm -f "$config" "$legacy"
seed_legacy '{"a":{"roadmapDb":"AR"},"b":{"roadmapDb":"BR"},"c":{"roadmapDb":"CR"}}'
bash "$script" set --require-scope true a >/dev/null 2>&1
check "untouched project b carried over" BR "$(bash "$script" get b | jq -r .roadmapDb)"
check "untouched project c carried over" CR "$(bash "$script" get c | jq -r .roadmapDb)"

# the legacy file is a backup: nothing writes to it, ever
rm -f "$config" "$legacy"
seed_legacy '{"keepme":{"roadmapDb":"KR","taskDb":"KT","taskTemplate":null}}'
cp "$legacy" "$XDG_DATA_HOME/legacy.orig"
bash "$script" set --roadmap-db NEWR keepme >/dev/null 2>&1
check "architect.json byte-identical" 0 \
  "$(cmp -s "$legacy" "$XDG_DATA_HOME/legacy.orig"; echo $?)"
check "soong.json took the write" NEWR "$(jq -r '.keepme.roadmapDb' "$config")"

# migration is idempotent: the second run sees soong.json and does nothing
rm -f "$config" "$legacy"
seed_legacy '{"idem":{"roadmapDb":"IR"}}'
bash "$script" get idem >/dev/null 2>&1
first="$(cat "$config")"
bash "$script" get idem >/dev/null 2>&1
check "second run is a no-op" "$first" "$(cat "$config")"

# a corrupt legacy file is never copied forward: that would launder garbage into
# soong.json and make the next read fail on the new name instead of the old one
rm -f "$config" "$legacy"
seed_legacy 'not json'
check "corrupt legacy get exits 1"  1 "$(run get anything)"
check "corrupt legacy wrote no soong.json" 1 "$([ -f "$config" ]; echo $?)"
check "corrupt legacy set exits 1"  1 "$(run set --roadmap-db R anything)"
check "corrupt legacy still no soong.json" 1 "$([ -f "$config" ]; echo $?)"
check "corrupt legacy preserved" "not json" "$(cat "$legacy")"
check "corrupt legacy left no temp file" 0 \
  "$(find "$(dirname "$config")" -name '.soong.*' | wc -l | tr -d ' ')"

# a parseable non-object legacy file is refused the same way
rm -f "$config" "$legacy"
seed_legacy '[1,2]'
check "array legacy get exits 1" 1 "$(run get anything)"
check "array legacy wrote no soong.json" 1 "$([ -f "$config" ]; echo $?)"
rm -f "$legacy"

# migration is not command-specific: it runs before the command resolves its
# project, so it will cover the check command when that arrives. Verified here
# through the one existing command that fails after migration would have run.
rm -f "$config" "$legacy"
seed_legacy '{"early":{"roadmapDb":"ER"}}'
( cd / && bash "$script" get >/dev/null 2>&1 )
check "migration ran before project resolution" ER "$(jq -r '.early.roadmapDb' "$config")"

# usage and unknown commands never touch the config at all
rm -f "$config" "$legacy"
seed_legacy '{"untouched":{"roadmapDb":"UR"}}'
bash "$script" --help >/dev/null 2>&1
check "--help did not migrate" 1 "$([ -f "$config" ]; echo $?)"
bash "$script" bogus >/dev/null 2>&1
check "unknown command did not migrate" 1 "$([ -f "$config" ]; echo $?)"
rm -f "$config" "$legacy"

# the migrated file gets the same locked-down mode as a written one
rm -f "$config" "$legacy"
seed_legacy '{"perm":{"roadmapDb":"PR"}}'
bash "$script" get perm >/dev/null 2>&1
if mode="$(stat -f '%Lp' "$config" 2>/dev/null)"; then
  check "migrated file is mode 600" 600 "$mode"
else
  echo "skip - migrated file mode check (stat -f unavailable)"
fi
rm -f "$config" "$legacy"

# migration does not fire when soong.json already exists
rm -f "$config" "$legacy"
seed '{"only":{"roadmapDb":"NEW"}}'
seed_legacy '{"only":{"roadmapDb":"OLD"},"ghost":{"roadmapDb":"GR"}}'
bash "$script" get only >/dev/null 2>&1
check "existing soong.json untouched" NEW "$(jq -r '.only.roadmapDb' "$config")"
check "no key added from the legacy file" 1 \
  "$(jq -e 'has("ghost")' "$config" >/dev/null 2>&1; echo $?)"
rm -f "$config" "$legacy"

# --- set merges, so one capability does not clobber another ------------------
rm -f "$config"
bash "$script" set --roadmap-db R --task-db T mergetest >/dev/null 2>&1
bash "$script" set --require-scope true mergetest >/dev/null 2>&1
rec="$(bash "$script" get mergetest)"
check "scope stored alone"      true "$(jq -r .requireScope <<<"$rec")"
check "notion keys survived"    R    "$(jq -r .roadmapDb    <<<"$rec")"

bash "$script" set --roadmap-db R2 mergetest >/dev/null 2>&1
rec="$(bash "$script" get mergetest)"
check "notion key updated"      R2   "$(jq -r .roadmapDb    <<<"$rec")"
check "scope survived a notion set" true "$(jq -r .requireScope <<<"$rec")"
check "taskDb survived a partial set" T "$(jq -r .taskDb     <<<"$rec")"

# --require-scope takes true or false only
check "require-scope false ok"  0 "$(run set --require-scope false scopetest)"
check "require-scope stored"    false "$(bash "$script" get scopetest | jq -r .requireScope)"
check "require-scope yes fails" 2 "$(run set --require-scope yes badscope)"
check "require-scope 1 fails"   2 "$(run set --require-scope 1 badscope)"
check "bad require-scope wrote nothing" 3 "$(run get badscope)"

# set with no flags at all is a usage error, not a no-op write
check "set with no flags exits 2" 2 "$(run set noflags)"
check "set with no flags wrote nothing" 3 "$(run get noflags)"

# a partial set on a repo that does not exist yet still creates it
check "partial set creates" 0 "$(run set --task-db ONLYT newrepo)"
check "partial set stored"  ONLYT "$(bash "$script" get newrepo | jq -r .taskDb)"
check "unset key is absent" false "$(bash "$script" get newrepo | jq -r 'has("roadmapDb")')"

# merging into a non-object record fails loudly rather than silently replacing
# it: a scalar under a project key is a hand-corrupted config, so exit 1 and
# leave the file alone. The old replace-everything set used to overwrite it.
seed '{"scalar":"oops"}'
check "merge into a scalar exits 1" 1 "$(run set --task-db T scalar)"
check "scalar record preserved" '{"scalar":"oops"}' "$(cat "$config")"
check "failed merge left no temp file" 0 \
  "$(find "$(dirname "$config")" -name '.soong.*' | wc -l | tr -d ' ')"

# --- check <capability> ------------------------------------------------------
# A project is passed with --project, never as a bare argument: a bare argument is
# always a capability, so a typo cannot be mistaken for a project name.
rm -f "$config"
check "check on an unconfigured repo exits 3" 3 "$(run check notion --project nothing)"

bash "$script" set --roadmap-db R --task-db T chk >/dev/null 2>&1
check "notion satisfied"        0 "$(run check notion --project chk)"
check "commits not satisfied"   3 "$(run check commits --project chk)"

# a stored false satisfies commits: presence is has(), not truthiness
bash "$script" set --require-scope false chk >/dev/null 2>&1
check "commits satisfied by false" 0 "$(run check commits --project chk)"

# a partial notion config is not satisfied, and says which key is missing
bash "$script" set --task-db T2 partial >/dev/null 2>&1
check "partial notion exits 3" 3 "$(run check notion --project partial)"
missing="$(bash "$script" check notion --project partial 2>&1 >/dev/null)"
case "$missing" in
  *roadmapDb*) check "names the missing key" 0 0 ;;
  *) check "names the missing key" "roadmapDb in stderr" "$missing" ;;
esac

# taskTemplate is optional, so its absence does not fail the capability
check "template not required" 0 "$(run check notion --project chk)"

# a typo is a caller bug, never "the user needs to run setup"
check "unknown capability exits 2" 2 "$(run check notyacapability --project chk)"
check "bare typo is not a project"  2 "$(run check comits)"
check "two capabilities exit 2"     2 "$(run check notion commits)"
check "--project with no value"     2 "$(run check notion --project)"

# --- check with no capability sweeps everything ------------------------------
check "sweep exits 3 when any capability is missing" 3 "$(run check --project partial)"
bash "$script" set --require-scope true --roadmap-db R3 partial >/dev/null 2>&1
check "sweep exits 0 when all are satisfied" 0 "$(run check --project partial)"
sweep="$(bash "$script" check --project chk 2>&1)"
case "$sweep" in
  *notion*commits*|*commits*notion*) check "sweep lists both capabilities" 0 0 ;;
  *) check "sweep lists both capabilities" "notion and commits" "$sweep" ;;
esac

# a corrupt config is an error, never "unconfigured"
seed 'not json at all'
check "check on corrupt config exits 1" 1 "$(run check notion --project chk)"
check "sweep on corrupt config exits 1" 1 "$(run check --project chk)"
rm -f "$config"

# a scalar under a project key is a hand-corrupted config, not "unconfigured":
# set refuses to merge into it (exit 1), so a 3 here would send the caller into a
# setup that then refuses to write. Same deadlock the corrupt-file checks guard.
seed '{"scalarchk":"oops"}'
check "check on a scalar record exits 1" 1 "$(run check notion --project scalarchk)"
check "sweep on a scalar record exits 1" 1 "$(run check --project scalarchk)"
check "scalar record still satisfies nothing for others" 3 "$(run check notion --project elsewhere)"
rm -f "$config"

# check migrates the legacy config forward like every other config-touching
# command: without it, a repo configured before the rename reads as unconfigured
# and every skill's check sends the user back into setup.
rm -f "$config" "$legacy"
seed_legacy '{"legacycheck":{"roadmapDb":"LR","taskDb":"LT"}}'
check "check satisfies a legacy config" 0 "$(run check notion --project legacycheck)"
check "check migrated soong.json"       0 "$([ -f "$config" ]; echo $?)"
check "migrated content matches"        LR "$(jq -r '.legacycheck.roadmapDb' "$config")"
rm -f "$config" "$legacy"

echo
[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
