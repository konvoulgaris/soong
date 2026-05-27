#!/usr/bin/env bash
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

case "$cmd" in
  *"gh pr create"*|*"gh pr edit"*) ;;
  *) exit 0 ;;
esac

title=$(printf '%s' "$cmd" | grep -oE -- '(--title|-t)[ =]+("[^"]*"|'"'"'[^'"'"']*'"'"')' | head -1 | sed -E 's/^(--title|-t)[ =]+//; s/^["'"'"']//; s/["'"'"']$//')

reasons=()

if [ -n "$title" ]; then
  if ! printf '%s' "$title" | grep -qE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9./-]+\))?!?: .+'; then
    reasons+=("Title must follow Conventional Commits with optional scope, e.g. 'feat(scope): summary'. An optional Notion ticket id may be appended as a suffix. Got: \"$title\"")
  fi
fi

if printf '%s' "$cmd" | grep -qiE 'generated with|co-authored-by|🤖'; then
  reasons+=("PR must NOT contain a generated-by footer (no 'Generated with', 'Co-Authored-By', or robot emoji).")
fi

if [ ${#reasons[@]} -gt 0 ]; then
  printf '%s' "${reasons[*]} Follow the manage-pr skill to fix the title and description, then retry." \
    | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}'
  exit 0
fi
exit 0
