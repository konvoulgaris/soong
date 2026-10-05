#!/usr/bin/env bash
# Tests for superpowers-commit-guard.sh. Run by hand: bash superpowers-commit-guard.test.sh
# Feeds hook JSON on stdin and asserts on stdout. Exits non-zero on any failure.
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/superpowers-commit-guard.sh"

fixture=$(mktemp -d) || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$fixture"' EXIT
cd "$fixture" || exit 1
git init -q
git config user.email t@t
git config user.name t
# A global gitignore that lists docs/superpowers would refuse the fixture's adds.
git config core.excludesFile /dev/null
mkdir -p docs/superpowers src
echo a > docs/superpowers/spec.md
echo a > src/a.txt
git add docs/superpowers/spec.md src/a.txt
git commit -q --no-verify -m "chore: seed"

pass=0
fail=0

verdict() {
  local out
  out=$(jq -Rs --arg cwd "$PWD" '{cwd:$cwd,tool_input:{command:.}}' <<<"$1" | bash "$HOOK")
  if [ -z "$out" ]; then printf 'silent'
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then printf 'deny'
  else printf 'malformed'; fi
}

check() {
  local want="$1" desc="$2" cmd="$3" got
  got=$(verdict "$cmd")
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL  %s: got %s, want %s\n' "$desc" "$got" "$want"; fi
}

check silent "ls" "ls"
check silent "commit with nothing staged" 'git commit -m "x"'
check deny "add names the notes" "git add docs/superpowers/spec.md"
check silent "restore --staged names the notes" "git restore --staged docs/superpowers"

echo b > src/a.txt && git add src/a.txt
check silent "commit with unrelated staged file" 'git commit -m "x"'

echo b > docs/superpowers/spec.md && git add docs/superpowers/spec.md
check deny "commit with notes staged" 'git commit -m "x"'
check deny "commit through -C" "git -C $PWD commit -m x"
git restore --staged docs/superpowers
check deny "commit -a picks up a modified tracked note" 'git commit -am "x"'
check silent "plain commit once unstaged" 'git commit -m "x"'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
