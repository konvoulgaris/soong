#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/brainstorm-worktree-first.sh"

if output=$(printf '%s\n' '{"prompt":"update a dependency"}' | bash "$script") && [ -z "$output" ]; then
  :
else
  echo 'FAIL: unrelated prompt produced output' >&2
  exit 1
fi

printf '%s\n' '{"prompt":"brainstorm a release workflow"}' | bash "$script" |
  jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and (.hookSpecificOutput.additionalContext | contains("create an isolated git worktree"))' >/dev/null

echo 'PASS: brainstorm prompt worktree reminder'
