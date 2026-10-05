#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
root="$(cd "$(dirname "$0")/../.." && pwd)"
principles="$(cat "$root/skills/soong-setup/reference/principles.md")"
printf '%s' "$principles" | jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
