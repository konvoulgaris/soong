#!/usr/bin/env bash
set -euo pipefail
mode=write
case "${1:-}" in
  '') [ "$#" -eq 0 ] || exit 2 ;;
  --check) [ "$#" -eq 1 ] || exit 2; mode=check ;;
  *) echo 'Usage: sync-agent-configs.sh [--check]' >&2; exit 2 ;;
esac
command -v jq >/dev/null || { echo 'sync-agent-configs: jq is required' >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
manifest=plugins/soong/plugin.json
hooks=plugins/soong/hooks/hooks.json
jq -e '
  type == "object" and
  ."$schema" == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json" and
  .name == "soong" and
  (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.description | type == "string" and length > 0) and
  (.author.name | type == "string" and length > 0) and
  (keys - ["$schema", "name", "version", "description", "author", "homepage", "repository", "license", "keywords"] | length == 0)
' "$manifest" >/dev/null || { echo 'sync-agent-configs: invalid plugin metadata' >&2; exit 1; }
[ -s CLAUDE.md ] || { echo 'sync-agent-configs: CLAUDE.md is missing or empty' >&2; exit 1; }
skills=(plugins/soong/skills/*/SKILL.md)
[ -f "${skills[0]}" ] || { echo 'sync-agent-configs: no skills found' >&2; exit 1; }
for skill in "${skills[@]}"; do
  awk '
    NR == 1 { if ($0 != "---") exit 1; next }
    $0 == "---" { closed = 1; exit }
    /^name: [^[:space:]]/ { name = 1 }
    /^description: [^[:space:]]/ { description = 1 }
    END { if (!closed || !name || !description) exit 1 }
  ' "$skill" || { echo "sync-agent-configs: invalid skill metadata: $skill" >&2; exit 1; }
done
jq -e '
  (.hooks | type == "object") and
  (.hooks.PreToolUse | type == "array" and length > 0) and
  (.hooks.SessionStart | type == "array" and length > 0) and
  all(.hooks.PreToolUse[]; (.matcher | type == "string")) and
  all((.hooks.PreToolUse[], .hooks.SessionStart[]);
    (.hooks | type == "array" and length > 0) and
    all(.hooks[]; .type == "command" and (.command | type == "string" and length > 0)))
' "$hooks" >/dev/null || { echo 'sync-agent-configs: invalid hook definitions' >&2; exit 1; }
for script in conventional-commit-guard.sh engineering-principles.sh notion-content-reminder.sh; do
  [ -f "plugins/soong/hooks/scripts/$script" ] || { echo "sync-agent-configs: missing hook script: $script" >&2; exit 1; }
done
outputs=(AGENTS.md .claude-plugin/marketplace.json .agents/plugins/marketplace.json plugins/soong/.claude-plugin/plugin.json plugins/soong/.codex-plugin/plugin.json plugins/soong/hooks/hooks.codex.json)
for output in "${outputs[@]}"; do
  path="$output"
  while [ "$path" != . ]; do
    [ ! -L "$path" ] || { echo "sync-agent-configs: refusing symlink: $path" >&2; exit 1; }
    path="$(dirname "$path")"
  done
  [ ! -e "$output" ] || [ -f "$output" ] || { echo "sync-agent-configs: not a file: $output" >&2; exit 1; }
done
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for output in "${outputs[@]}"; do
  mkdir -p "$tmp/$(dirname "$output")"
done
cp CLAUDE.md "$tmp/AGENTS.md"
jq -S 'del(."$schema")' "$manifest" > "$tmp/plugins/soong/.claude-plugin/plugin.json"
jq -S 'del(."$schema") + {skills:"./skills/", hooks:"./hooks/hooks.codex.json"}' "$manifest" > "$tmp/plugins/soong/.codex-plugin/plugin.json"
jq -S '{name:.name, owner:.author, plugins:[{name:.name, source:"./plugins/soong", description:.description}]}' "$manifest" > "$tmp/.claude-plugin/marketplace.json"
jq -S '{name:.name, interface:{displayName:.name}, plugins:[{name:.name, source:{source:"local", path:"./plugins/soong"}, policy:{installation:"AVAILABLE", authentication:"ON_INSTALL"}, category:"Productivity"}]}' "$manifest" > "$tmp/.agents/plugins/marketplace.json"
jq -S '
  {hooks: {
    PreToolUse: [.hooks.PreToolUse[] | select(.matcher == "Bash" or (.matcher | startswith("mcp__")))],
    SessionStart: .hooks.SessionStart
  }} |
  walk(if type == "object" and has("command") then
    .command |= gsub("CLAUDE_PLUGIN_ROOT"; "PLUGIN_ROOT")
  else . end)
' "$hooks" > "$tmp/plugins/soong/hooks/hooks.codex.json"
status=0
for output in "${outputs[@]}"; do
  if ! cmp -s "$tmp/$output" "$output"; then
    if [ "$mode" = check ]; then
      echo "Drift: $output" >&2
      status=1
    else
      mkdir -p "$(dirname "$output")"
      cp "$tmp/$output" "$output"
      echo "Updated: $output"
    fi
  fi
done
exit "$status"
