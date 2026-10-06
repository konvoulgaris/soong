#!/usr/bin/env bash
# Self-check for sync-skills.sh. Run: bash sync-skills.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/sync-skills.sh"
tmp="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
fresh() { # fresh -> a new empty repo, cwd set to it
  repo="$(mktemp -d "$tmp/repo.XXXXXX")"
  git init -q "$repo" 2>/dev/null
  cd "$repo" || exit 1
}
skill() { # skill <dir> <name> [body]
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: does %s\n---\n%s\n' "$2" "$2" "${3:-body}" > "$1/$2/SKILL.md"
}
run() { bash "$script" "$@" >/dev/null 2>&1; echo $?; }

# mirror: writes both agents' copies, bundled files included
fresh
skill docs/skills alpha
mkdir docs/skills/alpha/scripts && echo hi > docs/skills/alpha/scripts/x.sh
check "sync exits 0" 0 "$(run docs/skills)"
check "claude mirror"  "hi" "$(cat .claude/skills/alpha/scripts/x.sh)"
check "codex mirror"   "hi" "$(cat .agents/skills/alpha/scripts/x.sh)"
check "check clean after sync" 0 "$(run --check docs/skills)"

# check: reports drift and writes nothing
echo changed > docs/skills/alpha/scripts/x.sh
check "check exits 1 on drift" 1 "$(run --check docs/skills)"
check "check names the path" "Drift: .claude/skills/alpha" \
  "$(bash "$script" --check docs/skills 2>&1 | head -1)"
check "check did not write" "hi" "$(cat .claude/skills/alpha/scripts/x.sh)"
run docs/skills >/dev/null
check "sync repairs drift" "changed" "$(cat .agents/skills/alpha/scripts/x.sh)"

# a mirror edited by hand is overwritten, and an extra file in it is dropped
echo stray > .claude/skills/alpha/stray.md
check "stray file is drift" 1 "$(run --check docs/skills)"
run docs/skills >/dev/null
check "stray file removed" false "$([ -e .claude/skills/alpha/stray.md ] && echo true || echo false)"

# a mirror-only skill is an error, never a silent delete
skill .claude/skills beta
check "unadopted skill exits 1" 1 "$(run docs/skills)"
check "unadopted skill kept" true "$([ -d .claude/skills/beta ] && echo true || echo false)"

# adopt moves it into the canonical dir, then mirrors it to both
check "adopt exits 0" 0 "$(run --adopt docs/skills)"
check "adopted into source" true "$([ -f docs/skills/beta/SKILL.md ] && echo true || echo false)"
check "adopted mirrored to codex" true "$([ -f .agents/skills/beta/SKILL.md ] && echo true || echo false)"

# adopt creates the canonical dir when it does not exist yet
fresh
skill .agents/skills gamma
check "adopt into a new dir" 0 "$(run --adopt docs/skills)"
check "new dir holds the skill" true "$([ -f docs/skills/gamma/SKILL.md ] && echo true || echo false)"
check "claude gets it too" true "$([ -f .claude/skills/gamma/SKILL.md ] && echo true || echo false)"

# adopt refuses a name that differs between two places, and moves nothing
fresh
skill .claude/skills dup one
skill .agents/skills dup two
check "conflict exits 1" 1 "$(run --adopt docs/skills)"
check "conflict moved nothing" false "$([ -e docs/skills ] && echo true || echo false)"
skill .agents/skills dup one
check "identical copies adopt" 0 "$(run --adopt docs/skills)"

# validation
fresh
skill docs/skills alpha
printf -- '---\nname: wrong\ndescription: x\n---\n' > docs/skills/alpha/SKILL.md
check "name must match dir" 1 "$(run docs/skills)"
printf -- '---\nname: alpha\n---\n' > docs/skills/alpha/SKILL.md
check "description required" 1 "$(run docs/skills)"
fresh
check "empty dir exits 1" 1 "$(run docs/skills)"
mkdir -p docs/skills/nofile
check "dir without SKILL.md exits 1" 1 "$(run docs/skills)"

# usage and safety
fresh
skill docs/skills alpha
check "no argument exits 2" 2 "$(run)"
check "absolute dir exits 2" 2 "$(run /tmp/x)"
check "parent dir exits 2" 2 "$(run ../x)"
check "mirror as source exits 2" 2 "$(run .claude/skills)"
check "check with adopt exits 2" 2 "$(run --check --adopt docs/skills)"
check "unknown flag exits 2" 2 "$(run --nope docs/skills)"
ln -s docs .claude 2>/dev/null
check "symlinked mirror exits 1" 1 "$(run docs/skills)"
rm .claude
cd "$tmp" && mkdir plain && cd plain
check "outside a repo exits 2" 2 "$(run docs/skills)"

echo
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
