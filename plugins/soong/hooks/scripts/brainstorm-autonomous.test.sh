#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/brainstorm-autonomous.sh"

if output=$(printf '%s\n' '{"tool_input":{"skill":"soong:develop"}}' | bash "$script") && [ -z "$output" ]; then
  :
else
  echo 'FAIL: unrelated skill produced output' >&2
  exit 1
fi

printf '%s\n' '{"tool_input":{"skill":"superpowers:brainstorming"}}' | bash "$script" |
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | contains("do not ask the user to review") and contains("subagent-driven development") and contains("inline"))' >/dev/null

echo 'PASS: brainstorming autonomy reminder'
