#!/usr/bin/env bash
input=$(cat)
skill=$(printf '%s' "$input" | jq -r '.tool_input.skill // ""')

case "$skill" in
  *brainstorm*) ;;
  *) exit 0 ;;
esac

printf '%s' "Before exploring project context or asking any clarifying questions, your VERY FIRST action must be to create an isolated git worktree and feature branch for this work (use the using-git-worktrees skill). After creating it, explicitly verify the worktree and branch exist (e.g. 'git worktree list' and 'git branch --show-current') and confirm to the user before proceeding with any other brainstorming step." \
  | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:.}}'
