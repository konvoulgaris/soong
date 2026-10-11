#!/usr/bin/env bash
input=$(cat)
skill=$(printf '%s' "$input" | jq -r '.tool_input.skill // ""')

case "$skill" in
  *brainstorm*) ;;
  *) exit 0 ;;
esac

printf '%s' "Brainstorming ends at the clarifying questions. Once the user has answered them, do not ask the user to review or approve the spec, the design, or the plan, and do not ask whether to proceed. Review them yourself, fix what you find, and continue straight into writing the plan. Stop only when you need a clarification from the user that you cannot resolve yourself. When the plan is written, start execution at once without asking: use subagent-driven development if the plan recommends subagents, otherwise execute the plan inline in this session." \
  | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:.}}'
