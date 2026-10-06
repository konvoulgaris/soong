#!/usr/bin/env bash
# Mirror one canonical skills directory to every agent that reads skills.
#
#   sync-skills.sh [--check | --adopt] SKILLS_DIR
#
# SKILLS_DIR is the canonical, repo-relative location (e.g. docs/skills). Each
# <SKILLS_DIR>/<name>/SKILL.md is copied, with its bundled files, to the
# directories the agents read:
#
#   .claude/skills/<name>   Claude Code
#   .agents/skills/<name>   Codex
#
# The sync is one-way. Edit SKILLS_DIR, never the mirrors.
#
#   --check  write nothing; print "Drift: <path>" and exit 1 on any difference
#   --adopt  first move skills that live only in a mirror into SKILLS_DIR
#
# A skill present in a mirror but not in SKILLS_DIR is an error, not a deletion:
# with no manifest, a stale mirror and a hand-written skill look the same.
# --adopt moves it. Adopting a name that exists in two places with different
# content is a conflict; nothing is moved.
#
# Exit codes: 0 ok, 1 drift or invalid skills, 2 usage error.
set -euo pipefail

die() { echo "sync-skills: $1" >&2; exit "${2:-1}"; }

mode=write
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) [ "$mode" = write ] || die "--check and --adopt are exclusive" 2; mode=check ;;
    --adopt) [ "$mode" = write ] || die "--check and --adopt are exclusive" 2; mode=adopt ;;
    -*) die "unknown flag: $1" 2 ;;
    *) [ -z "$dir" ] || die "unexpected extra argument: $1" 2; dir="$1" ;;
  esac
  shift
done
[ -n "$dir" ] || die "usage: sync-skills.sh [--check | --adopt] SKILLS_DIR" 2
dir="${dir%/}"
case "$dir" in
  /*|..|../*|*/..|*/../*|.|'') die "SKILLS_DIR must be a path inside the repo: $dir" 2 ;;
esac

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository" 2
cd "$root"
targets=(.claude/skills .agents/skills)
for t in "${targets[@]}"; do
  [ "$dir" != "$t" ] || die "SKILLS_DIR cannot be a mirror: $t" 2
done

# Skill names found under a directory: its immediate subdirectories.
names_in() { # names_in <dir>
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;
}

# No symlinks anywhere we read or write: cp -R and diff would follow them out of
# the repo.
for d in "$dir" "${targets[@]}"; do
  path="$d"
  while [ "$path" != . ]; do
    [ ! -L "$path" ] || die "refusing symlink: $path"
    path="$(dirname "$path")"
  done
  [ ! -d "$d" ] || [ -z "$(find "$d" -type l -print -quit)" ] \
    || die "refusing symlink inside $d"
done

if [ "$mode" = adopt ]; then
  all="$( { names_in "$dir"; for t in "${targets[@]}"; do names_in "$t"; done; } | sort -u)"
  conflicts=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    first=""
    for d in "$dir" "${targets[@]}"; do
      [ -d "$d/$name" ] || continue
      if [ -z "$first" ]; then first="$d/$name"; continue; fi
      if ! diff -rq "$first" "$d/$name" >/dev/null; then
        echo "Conflict: $first differs from $d/$name" >&2
        conflicts=1
      fi
    done
  done <<<"$all"
  [ "$conflicts" -eq 0 ] || die "resolve the conflicts above, then re-run --adopt"
  while IFS= read -r name; do
    [ -n "$name" ] && [ ! -d "$dir/$name" ] || continue
    for t in "${targets[@]}"; do
      if [ -d "$t/$name" ]; then
        mkdir -p "$dir"
        mv "$t/$name" "$dir/$name"
        echo "Adopted: $t/$name -> $dir/$name"
        break
      fi
    done
  done <<<"$all"
fi

names="$(names_in "$dir" | sort)"
[ -n "$names" ] || die "no skills found in $dir"

while IFS= read -r name; do
  skill="$dir/$name/SKILL.md"
  [ -f "$skill" ] || die "missing SKILL.md: $skill"
  awk -v want="$name" '
    NR == 1 { if ($0 != "---") exit 1; next }
    $0 == "---" { closed = 1; exit }
    $0 == "name: " want { ok = 1 }
    /^description: [^[:space:]]/ { description = 1 }
    END { if (!closed || !ok || !description) exit 1 }
  ' "$skill" || die "invalid skill metadata (name must be '$name', description required): $skill"
done <<<"$names"

for t in "${targets[@]}"; do
  stale="$(comm -13 <(printf '%s\n' "$names") <(names_in "$t" | sort))"
  [ -z "$stale" ] || die "in $t but not in $dir: $(echo $stale). Run --adopt to move, or delete it."
done

status=0
for t in "${targets[@]}"; do
  while IFS= read -r name; do
    if [ -d "$t/$name" ] && diff -rq "$dir/$name" "$t/$name" >/dev/null; then continue; fi
    if [ "$mode" = check ]; then
      echo "Drift: $t/$name" >&2
      status=1
    else
      rm -rf "${t:?}/$name"
      mkdir -p "$t"
      cp -R "$dir/$name" "$t/$name"
      echo "Updated: $t/$name"
    fi
  done <<<"$names"
done
exit "$status"
