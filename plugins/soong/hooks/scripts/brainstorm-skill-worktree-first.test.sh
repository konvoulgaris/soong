#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/brainstorm-skill-worktree-first.sh"

if output=$(printf '%s\n' '{"tool_input":{"skill":"soong:develop"}}' | bash "$script") && [ -z "$output" ]; then
  :
else
  echo 'FAIL: unrelated skill produced output' >&2
  exit 1
fi

printf '%s\n' '{"tool_input":{"skill":"superpowers:brainstorming"}}' | bash "$script" |
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | contains("create an isolated git worktree"))' >/dev/null

echo 'PASS: brainstorming skill worktree reminder'
