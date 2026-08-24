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

# Commit subjects, newest first. jq -Rs splits on newlines and quotes each one.
commits="$(git log --format='%h %s' "$base..HEAD" 2>/dev/null \
  | jq -Rs 'split("\n") | map(select(length > 0))')"

# Churn per file. git prints "-" for binary files, so map that to 0 and keep
# the field a number: the skill ranks on these values. Rebuild the path from
# field 3 onward, because a path may itself contain a tab.
files="$(git diff --numstat "$base...HEAD" 2>/dev/null | jq -Rs '
  split("\n")
  | map(select(length > 0))
  | map(split("\t"))
  | map(select(length >= 3))
  | map({
      path: (.[2:] | join("\t")),
      added: (if .[0] == "-" then 0 else (.[0] | tonumber) end),
      removed: (if .[1] == "-" then 0 else (.[1] | tonumber) end)
    })')"

# No pull request is a normal result, not a failure. --argjson takes the bare
# word null, which is why the fallback is not an empty string.
pr="$(gh pr view --json number,title,body 2>/dev/null)"
[ -n "$pr" ] || pr=null

jq -n \
  --arg branch "$branch" \
  --arg base "$base" \
  --argjson pr "$pr" \
  --argjson commits "$commits" \
  --argjson files "$files" \
  '{branch: $branch, base: $base, pr: $pr, commits: $commits, files: $files}'
