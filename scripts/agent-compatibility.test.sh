#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
status=0
while IFS= read -r script; do
  test_file="${script%.sh}.test.sh"
  if [ ! -f "$test_file" ]; then
    echo "FAIL: missing script test: $script" >&2
    status=1
  fi
done < <(rg --files -g '*.sh' -g '!*.test.sh' "$root")
for skill in "$root"/plugins/soong/skills/*/SKILL.md; do
  if ! grep -q 'reference/hosts.md' "$skill"; then
    echo "FAIL: missing host reference: $skill" >&2
    status=1
  fi
  if grep -Eq 'CLAUDE_PLUGIN_ROOT|subagent_type|model: sonnet|Agent tool' "$skill"; then
    echo "FAIL: unconditional Claude execution instructions: $skill" >&2
    status=1
  fi
done
if grep -Eq 'subagent_type|model: sonnet|Agent tool' "$root/plugins/soong/skills/manage-pr/reference/pr/feedback.md"; then
  echo 'FAIL: Claude-specific PR feedback dispatch' >&2
  status=1
fi
if ! grep -q 'name.*develop-<roadmap-item-id>' "$root/plugins/soong/skills/soong-setup/reference/hosts.md"; then
  echo 'FAIL: managed worktree creation lacks roadmap identity' >&2
  status=1
fi
if rg -q 'pr-reviewer|review-pr-queue|review-pr' "$root/plugins/soong/agents" "$root/plugins/soong/skills"; then
  echo 'FAIL: removed pull request review workflow remains' >&2
  status=1
fi
for path in architect-cobrain.md adversarial-judge.md conflict-scout.md; do
  if [ -e "$root/plugins/soong/agents/$path" ]; then
    echo "FAIL: removed architecture agent remains: $path" >&2
    status=1
  fi
done
for path in architect adversarial-council; do
  if [ -e "$root/plugins/soong/skills/$path" ]; then
    echo "FAIL: removed architecture skill remains: $path" >&2
    status=1
  fi
done
if rg -q 'architect-cobrain|adversarial-council|adversarial-judge|conflict-scout' "$root/plugins/soong/agents" "$root/plugins/soong/skills" --glob '*.md'; then
  echo 'FAIL: removed architecture workflow remains in Markdown' >&2
  status=1
fi
if [ -e "$root/plugins/soong/skills/walkthrough" ]; then
  echo 'FAIL: removed walkthrough skill remains' >&2
  status=1
fi
exit "$status"
