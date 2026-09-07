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

[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
