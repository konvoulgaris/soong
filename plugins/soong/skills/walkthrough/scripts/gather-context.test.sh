#!/usr/bin/env bash
# Self-check for gather-context.sh. Run: bash gather-context.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/gather-context.sh"
tmp="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# gh must never run during the tests: the walkthrough must not depend on the
# network or on a logged-in account. A stub on PATH that always fails puts the
# script on its no-pull-request path.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}

# Never pipe into `grep -q` under `set -o pipefail`: grep exits on the first
# match, the writer takes SIGPIPE, and pipefail turns the whole pipeline into a
# failure even though the text matched. Capture first, then match on the text.
has() { # has <text> <pattern>
  printf '%s' "$1" | grep -qi -- "$2" && echo yes || echo no
}
stderr_of() { # stderr_of <dir> — the script's stderr, stdout discarded
  ( cd "$1" && bash "$script" 2>&1 >/dev/null )
}

# Build a repo with a main branch and a feature branch holding one commit.
# Every test below runs against a repo made here, never against the checkout.
make_repo() { # make_repo <dir>
  local d="$1"
  git init -q -b main "$d"
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  echo one > "$d/a.txt"
  git -C "$d" add a.txt
  git -C "$d" commit -q -m "chore: initial"
}

# --- failure cases -----------------------------------------------------------

# Outside a git repository the script must exit non-zero, not print JSON.
out="$(cd "$tmp" && bash "$script" 2>/dev/null)"
code="$(cd "$tmp" && bash "$script" >/dev/null 2>&1; echo $?)"
check "outside a repo exits non-zero" "yes" "$([ "$code" -ne 0 ] && echo yes || echo no)"
check "outside a repo prints no stdout" "" "$out"
check "outside a repo explains itself" "yes" \
  "$(has "$(stderr_of "$tmp")" 'git repository')"

# On the base branch itself there are no commits to walk.
repo="$tmp/nocommits"
make_repo "$repo"
code="$(cd "$repo" && bash "$script" >/dev/null 2>&1; echo $?)"
check "no commits against base exits non-zero" "yes" \
  "$([ "$code" -ne 0 ] && echo yes || echo no)"
check "no commits against base explains itself" "yes" \
  "$(has "$(stderr_of "$repo")" 'no commits')"

# --- happy path --------------------------------------------------------------

# A feature branch with two commits, one of which has a quote and a backslash
# in its subject. Nothing here may break the JSON.
repo="$tmp/feature"
make_repo "$repo"
git -C "$repo" checkout -q -b feature
echo two > "$repo/b.txt"
git -C "$repo" add b.txt
git -C "$repo" commit -q -m 'feat: add "quoted" \ thing'
printf 'three\nfour\n' >> "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -q -m "fix: extend a"

json="$(cd "$repo" && bash "$script" 2>/dev/null)"
check "happy path exits 0" 0 "$(cd "$repo" && bash "$script" >/dev/null 2>&1; echo $?)"
check "output is valid JSON" 0 "$(printf '%s' "$json" | jq -e . >/dev/null 2>&1; echo $?)"
check "branch is reported" "feature" "$(printf '%s' "$json" | jq -r .branch)"
check "base is reported" "main" "$(printf '%s' "$json" | jq -r .base)"
check "commit count" 2 "$(printf '%s' "$json" | jq '.commits | length')"
check "quoted subject survives" "yes" \
  "$(has "$(printf '%s' "$json" | jq -r '.commits[]')" 'add "quoted" \\ thing')"
check "file count" 2 "$(printf '%s' "$json" | jq '.files | length')"
check "churn is recorded" 2 \
  "$(printf '%s' "$json" | jq '[.files[] | select(.path == "a.txt")] | .[0].added')"
# The key must be present and null. An absent key also reads as null through
# `.pr`, so assert on has("pr") too or this check passes vacuously.
check "pr key is present" "true" "$(printf '%s' "$json" | jq -r 'has("pr")')"
check "no pull request is null" "true" "$(printf '%s' "$json" | jq -r '.pr == null')"

# A binary file reports churn as 0 rather than git's "-", which is not a number.
repo="$tmp/binary"
make_repo "$repo"
git -C "$repo" checkout -q -b feature
printf '\x00\x01\x02\x03' > "$repo/blob.bin"
git -C "$repo" add blob.bin
git -C "$repo" commit -q -m "chore: add a binary"
json="$(cd "$repo" && bash "$script" 2>/dev/null)"
check "binary file yields valid JSON" 0 "$(printf '%s' "$json" | jq -e . >/dev/null 2>&1; echo $?)"
check "binary churn is numeric" "number" \
  "$(printf '%s' "$json" | jq -r '.files[0].added | type')"

# A path with a space must arrive intact.
repo="$tmp/spaces"
make_repo "$repo"
git -C "$repo" checkout -q -b feature
mkdir -p "$repo/some dir"
echo x > "$repo/some dir/file name.txt"
git -C "$repo" add .
git -C "$repo" commit -q -m "chore: spaced path"
json="$(cd "$repo" && bash "$script" 2>/dev/null)"
check "spaced path survives" "yes" \
  "$(has "$(printf '%s' "$json" | jq -r '.files[].path')" 'some dir/file name.txt')"

# --- worktrees ---------------------------------------------------------------

# The plugin is developed inside linked worktrees, so the script must resolve
# branch and base from within one. `git rev-parse --show-toplevel` would return
# the worktree directory here, which is why the script never calls it.
repo="$tmp/wt-main"
make_repo "$repo"
if git -C "$repo" worktree add -q -b wt-feature "$tmp/wt-linked" >/dev/null 2>&1; then
  echo change > "$tmp/wt-linked/c.txt"
  git -C "$tmp/wt-linked" add c.txt
  git -C "$tmp/wt-linked" commit -q -m "feat: from a worktree"
  json="$(cd "$tmp/wt-linked" && bash "$script" 2>/dev/null)"
  check "worktree exits 0" 0 "$(cd "$tmp/wt-linked" && bash "$script" >/dev/null 2>&1; echo $?)"
  check "worktree branch resolves" "wt-feature" "$(printf '%s' "$json" | jq -r .branch)"
  check "worktree base resolves" "main" "$(printf '%s' "$json" | jq -r .base)"
  check "worktree sees its commit" 1 "$(printf '%s' "$json" | jq '.commits | length')"
else
  echo "skip - worktree checks (git worktree add failed)"
fi

# Detached HEAD has no branch name to report, so the script must refuse rather
# than emit an empty or bogus branch.
repo="$tmp/detached"
make_repo "$repo"
git -C "$repo" checkout -q --detach HEAD
code="$(cd "$repo" && bash "$script" >/dev/null 2>&1; echo $?)"
check "detached HEAD exits non-zero" "yes" "$([ "$code" -ne 0 ] && echo yes || echo no)"
check "detached HEAD prints no stdout" "" "$(cd "$repo" && bash "$script" 2>/dev/null)"
check "detached HEAD explains itself" "yes" "$(has "$(stderr_of "$repo")" 'detached')"

echo
[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
