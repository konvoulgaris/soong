#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo with spaces"
mkdir -p "$repo/scripts" "$repo/plugins/soong/skills/example" "$repo/plugins/soong/hooks"
if [ ! -f "$root/scripts/sync-agent-configs.sh" ]; then
  echo 'FAIL: sync-agent-configs.sh is missing' >&2
  exit 1
fi
cp "$root/scripts/sync-agent-configs.sh" "$repo/scripts/"
cat > "$repo/plugins/soong/plugin.json" <<'JSON'
{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"soong","version":"0.21.0","description":"Shared workflows","author":{"name":"konvoulgaris"}}
JSON
printf '# Repository rules\n' > "$repo/CLAUDE.md"
printf '%s\n' '---' 'name: example' 'description: Example workflow' '---' > "$repo/plugins/soong/skills/example/SKILL.md"
cp "$root/plugins/soong/hooks/hooks.json" "$repo/plugins/soong/hooks/"
mkdir -p "$repo/plugins/soong/hooks/scripts"
cp "$root"/plugins/soong/hooks/scripts/*.sh "$repo/plugins/soong/hooks/scripts/"
run() { (cd "$tmp" && bash "$repo/scripts/sync-agent-configs.sh" "$@"); }
expect_status() {
  local result=0
  run "${@:2}" > "$tmp/output" 2>&1 || result=$?
  if [ "$result" -ne "$1" ]; then
    cat "$tmp/output" >&2
    echo "FAIL: expected exit $1, got $result" >&2
    exit 1
  fi
}
expect_status 0
outputs=(AGENTS.md .claude-plugin/marketplace.json .agents/plugins/marketplace.json plugins/soong/.claude-plugin/plugin.json plugins/soong/.codex-plugin/plugin.json plugins/soong/hooks/hooks.codex.json)
for file in "${outputs[@]}"; do
  test -f "$repo/$file"
done
cmp "$repo/CLAUDE.md" "$repo/AGENTS.md"
jq -e '.version == "0.21.0"' "$repo/plugins/soong/.claude-plugin/plugin.json" >/dev/null
jq -e '.version == "0.21.0" and .skills == "./skills/" and .hooks == "./hooks/hooks.codex.json"' "$repo/plugins/soong/.codex-plugin/plugin.json" >/dev/null
jq -e '.plugins[0].source.path == "./plugins/soong" and .plugins[0].policy.installation == "AVAILABLE"' "$repo/.agents/plugins/marketplace.json" >/dev/null
cp -R "$repo" "$tmp/snapshot"
expect_status 0
diff -r "$repo" "$tmp/snapshot"
expect_status 0 --check
printf 'drift\n' >> "$repo/AGENTS.md"
cp "$repo/AGENTS.md" "$tmp/drift"
expect_status 1 --check
cmp "$repo/AGENTS.md" "$tmp/drift"
expect_status 0
rm "$repo/.agents/plugins/marketplace.json"
expect_status 1 --check
test ! -e "$repo/.agents/plugins/marketplace.json"
expect_status 0
cp "$repo/plugins/soong/plugin.json" "$tmp/manifest"
printf '{}\n' > "$repo/plugins/soong/plugin.json"
expect_status 1
diff "$repo/AGENTS.md" "$tmp/snapshot/AGENTS.md"
cp "$tmp/manifest" "$repo/plugins/soong/plugin.json"
cp "$repo/plugins/soong/hooks/hooks.json" "$tmp/hooks"
jq 'del(.hooks.SessionStart)' "$tmp/hooks" > "$repo/plugins/soong/hooks/hooks.json"
expect_status 1
for file in "${outputs[@]}"; do
  cmp "$repo/$file" "$tmp/snapshot/$file"
done
cp "$tmp/hooks" "$repo/plugins/soong/hooks/hooks.json"
expect_status 2 --unknown

rm "$repo/AGENTS.md"
printf 'outside\n' > "$tmp/outside"
ln -s "$tmp/outside" "$repo/AGENTS.md"
expect_status 1
[ "$(cat "$tmp/outside")" = outside ]
rm "$repo/AGENTS.md"
expect_status 0
rm -rf "$repo/.agents"
mkdir "$tmp/external"
ln -s "$tmp/external" "$repo/.agents"
expect_status 1
test ! -e "$tmp/external/plugins"
rm "$repo/.agents"
expect_status 0
printf 'invalid skill\n' > "$repo/plugins/soong/skills/example/SKILL.md"
expect_status 1
echo 'PASS: deterministic generation, drift, validation, cwd, spaces, and symlinks'
