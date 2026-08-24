#!/usr/bin/env bash
# Collect the facts a walkthrough needs about the current branch, as JSON.
# Emits: branch, base, pr (or null), commits, files.
set -uo pipefail

die() { echo "$1" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 \
  || die "not inside a git repository"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$branch" ] && [ "$branch" != HEAD ] \
  || die "cannot resolve the current branch: HEAD is detached"

# Base: the pull request base when there is a pull request, else main/master.
base="$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null)"
if [ -z "$base" ]; then
  for candidate in main master; do
    if git rev-parse --verify -q "$candidate" >/dev/null 2>&1; then
      base="$candidate"; break
    fi
  done
fi
[ -n "$base" ] || die "cannot resolve a base branch (looked for main, master)"
[ "$base" != "$branch" ] || die "no commits to walk: on the base branch $base"

git rev-parse --verify -q "$base" >/dev/null 2>&1 \
  || die "base branch $base does not exist locally"

count="$(git rev-list --count "$base..HEAD" 2>/dev/null)"
[ "${count:-0}" -gt 0 ] || die "no commits on $branch against $base"

printf '{"branch":%s,"base":%s}\n' \
  "$(printf '%s' "$branch" | jq -Rs .)" \
  "$(printf '%s' "$base" | jq -Rs .)"
