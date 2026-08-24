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

echo
[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
