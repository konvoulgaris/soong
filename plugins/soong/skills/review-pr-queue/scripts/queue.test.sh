#!/usr/bin/env bash
# Self-check for queue.sh. Run: bash queue.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/queue.sh"
tmp="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin"

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}

# fake_gh <<'JSON' installs a gh stub that replays canned output per subcommand.
fake_gh() { cat > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"; }

# gh missing entirely: PATH without gh at all
fake_gh <<'SH'
#!/usr/bin/env bash
exit 127
SH
check "gh unusable exits 2" 2 "$(bash "$script" >/dev/null 2>&1; echo $?)"

fake_gh <<'SH'
#!/usr/bin/env bash
case "$1" in
  auth) exit 1 ;;
  *) exit 0 ;;
esac
SH
check "gh unauthenticated exits 2" 2 "$(bash "$script" >/dev/null 2>&1; echo $?)"
out="$(bash "$script" 2>&1 >/dev/null)"
case "$out" in *"gh auth login"*) r=yes ;; *) r=no ;; esac
check "unauthenticated names the fix" yes "$r"

# --- scoring and classification -------------------------------------------
# Task 1 left an UNAUTHENTICATED stub installed. queue.sh runs its gh preflight
# before the --score-one early exit, so without a healthy stub here every
# scoring call below dies at exit 2 and returns an empty string. Install one.
fake_gh <<'SH'
#!/usr/bin/env bash
exit 0
SH

# score_one <json> -> "<score> <classification>"
score_one() { printf '%s' "$1" | bash "$script" --score-one; }

tiny='{"url":"u","additions":3,"deletions":1,"changedFiles":1,
  "files":[{"path":"src/copy.ts"}],"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "tiny safe green PR is Review now" "Review now" "$(score_one "$tiny" | cut -d' ' -f2-)"

big='{"url":"u","additions":400,"deletions":100,"changedFiles":20,
  "files":[{"path":"src/a.ts"},{"path":"lib/b.ts"}],"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "large safe PR requires thinking" "Requires thinking" "$(score_one "$big" | cut -d' ' -f2-)"

mig='{"url":"u","additions":4,"deletions":0,"changedFiles":1,
  "files":[{"path":"db/migrations/001_add.sql"}],"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "tiny migration requires thinking" "Requires thinking" "$(score_one "$mig" | cut -d' ' -f2-)"

red='{"url":"u","additions":3,"deletions":0,"changedFiles":1,
  "files":[{"path":"src/copy.ts"}],"statusCheckRollup":[{"conclusion":"FAILURE"}]}'
check "red CI requires thinking" "Requires thinking" "$(score_one "$red" | cut -d' ' -f2-)"

# A sensitive path must outrank a much larger safe diff.
s_mig="$(score_one "$mig" | cut -d' ' -f1)"
s_big="$(score_one "$big" | cut -d' ' -f1)"
# Default to 0 so an empty score is a visible failure, not a misleading "no".
check "sensitive outranks large-and-safe" yes \
  "$([ "${s_mig:-0}" -gt "${s_big:-0}" ] && echo yes || echo no)"

# Test-only churn is discounted, so it stays Review now.
snap='{"url":"u","additions":300,"deletions":0,"changedFiles":2,
  "files":[{"path":"src/__snapshots__/a.snap"},{"path":"tests/a.test.ts"}],
  "statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "all-lowsignal churn stays Review now" "Review now" "$(score_one "$snap" | cut -d' ' -f2-)"

# Half test, half real: the real half still counts.
mixed='{"url":"u","additions":200,"deletions":0,"changedFiles":2,
  "files":[{"path":"src/big.ts"},{"path":"tests/a.test.ts"}],
  "statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "mixed churn requires thinking" "Requires thinking" "$(score_one "$mixed" | cut -d' ' -f2-)"

# No CI at all is not green.
noci='{"url":"u","additions":3,"deletions":0,"changedFiles":1,
  "files":[{"path":"src/copy.ts"}],"statusCheckRollup":[]}'
check "absent CI requires thinking" "Requires thinking" "$(score_one "$noci" | cut -d' ' -f2-)"

[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
