#!/usr/bin/env bash
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')

case "$tool" in
  *notion-create-pages|*notion-update-page|*notion-create-comment) ;;
  *) exit 0 ;;
esac

printf '%s' "Writing Notion content. Follow the soong write-notion-content skill for style and format. Invoke it now if it is not already loaded." \
  | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:.}}'
