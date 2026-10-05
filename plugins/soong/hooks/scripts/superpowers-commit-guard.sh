#!/usr/bin/env bash
#
# Superpowers specs and plans under docs/superpowers/ are local working notes.
# This denies a `git commit` that would record them, and a `git add` that names
# them, in any repo the plugin is installed in.
#
# It reads the index of the repo the command runs in, so a repo with no
# docs/superpowers/ costs one `git diff` and passes. Chained `git add -A && git
# commit` cannot be seen here, because the index is read before the add runs;
# the repo's own .gitignore and pre-commit hook are the backstop for that.
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

deny() {
  printf '%s' "$1" \
    | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}'
  exit 0
}

# git as a command word, then the subcommand, allowing options in between
# (`git -C dir commit`). Stops at a pipe, `;` or `&` so a later command's words
# do not count.
subcommand() {
  printf '%s' "$cmd" | grep -Eq "(^|[^[:alnum:]_-])git[[:space:]]([^|;&]*[[:space:]])?$1([[:space:]]|\$)"
}

if subcommand add && printf '%s' "$cmd" | grep -q 'docs/superpowers'; then
  deny "docs/superpowers/ holds local working notes and must not be added to git. Leave the files untracked."
fi

subcommand commit || exit 0
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0

files=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
# `commit -a` stages tracked modifications at commit time, after this hook runs.
if printf '%s' "$cmd" | grep -Eq 'commit[^|;&]*([[:space:]]-[a-zA-Z]*a|--all)'; then
  files="$files
$(git diff --name-only --diff-filter=ACMR 2>/dev/null)"
fi

if printf '%s' "$files" | grep -q '^docs/superpowers/'; then
  deny "This commit would include files in docs/superpowers/, which are local working notes. Unstage them with: git restore --staged docs/superpowers"
fi
