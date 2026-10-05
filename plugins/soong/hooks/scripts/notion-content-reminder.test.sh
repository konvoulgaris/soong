#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/notion-content-reminder.sh"

if output=$(printf '%s\n' '{"tool_name":"mcp__notion__search"}' | bash "$script") && [ -z "$output" ]; then
  :
else
  echo 'FAIL: unrelated tool produced output' >&2
  exit 1
fi

printf '%s\n' '{"tool_name":"mcp__notion__notion-update-page"}' | bash "$script" |
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | contains("write-notion-content"))' >/dev/null

echo 'PASS: Notion content reminder'
