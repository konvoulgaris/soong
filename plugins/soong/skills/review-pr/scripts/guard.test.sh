#!/usr/bin/env bash
# Self-check for guard.sh. Run: bash guard.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/guard.sh"
tmp="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin"

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
# fake_gh <pr-repo> <workspace-repo-or-FAIL>
# The `repo view` arm honours -q, because the script calls gh that way and a
# stub that ignores it would return raw JSON where real gh returns a value.
fake_gh() {
  cat > "$tmp/bin/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr view")     echo '{"headRepository":{"nameWithOwner":"$1"},
                        "number":7,"isDraft":false}' ;;
  "repo view")
    [ "$2" = FAIL ] && exit 1
    for a in "\$@"; do [ "\$a" = "-q" ] && { echo "$2"; exit 0; }; done
    echo '{"nameWithOwner":"$2"}' ;;
esac
SH
  chmod +x "$tmp/bin/gh"
}
url=https://github.com/o/r/pull/7

fake_gh o/r o/r
check "match exits 0" 0 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
check "match reports ok" true "$(bash "$script" "$url" | jq -r '.ok')"
check "match echoes the repo" o/r "$(bash "$script" "$url" | jq -r '.repo')"
check "match echoes the number" 7 "$(bash "$script" "$url" | jq -r '.number')"

fake_gh o/r other/repo
check "mismatch exits 3" 3 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
msg="$(bash "$script" "$url" 2>&1 >/dev/null)"
case "$msg" in *o/r*) a=yes ;; *) a=no ;; esac
case "$msg" in *other/repo*) b=yes ;; *) b=no ;; esac
check "mismatch names the PR repo" yes "$a"
check "mismatch names the workspace repo" yes "$b"

# An unresolvable workspace must stop, never pass.
fake_gh o/r FAIL
check "unresolvable workspace exits 3" 3 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
msg="$(bash "$script" "$url" 2>&1 >/dev/null)"
case "$msg" in *"could not"*|*"cannot"*) c=yes ;; *) c=no ;; esac
check "unresolvable workspace says so" yes "$c"

# Case-insensitive: GitHub owners and repos are not case-sensitive.
fake_gh O/R o/r
check "case difference still matches" 0 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"

check "missing argument exits 2" 2 "$(bash "$script" >/dev/null 2>&1; echo $?)"

[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
