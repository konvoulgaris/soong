#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
resource="$root/skills/soong-setup/reference/principles.md"
if [ ! -f "$resource" ]; then
  echo 'FAIL: shared principles are missing' >&2
  exit 1
fi
printf '{}\n' | bash "$root/hooks/scripts/engineering-principles.sh" |
  jq -e --rawfile principles "$resource" '.hookSpecificOutput.hookEventName == "SessionStart" and .hookSpecificOutput.additionalContext == ($principles | rtrimstr("\n"))' >/dev/null
printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}\n' |
  PLUGIN_ROOT="$root" bash "$root/hooks/scripts/engineering-principles.sh" |
  jq -e '.hookSpecificOutput.additionalContext | contains("DRY") and contains("Pull requests")' >/dev/null
echo 'PASS: shared principles payload'
