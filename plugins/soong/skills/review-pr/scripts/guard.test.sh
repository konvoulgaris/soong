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
# fake_gh <pr-upstream-repo> <workspace-repo-or-FAIL> [head-repo]
# `pr view` returns the canonical upstream url, plus a SEPARATE head repo so a
# fork pull request can be simulated. Feeding both arms the same value is what
# let the fork bug through: a suite that cannot distinguish head from upstream
# cannot catch a script that reads the wrong one.
# The `repo view` arm honours -q, because the script calls gh that way and a
# stub that ignores it would return raw JSON where real gh returns a value.
fake_gh() {
  cat > "$tmp/bin/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr view")     echo '{"url":"https://github.com/$1/pull/7","number":7,
                        "headRepository":{"nameWithOwner":"${3:-$1}"}}' ;;
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

# A fork pull request, reviewed from the correct UPSTREAM checkout, must pass.
# headRepository is the fork here; only the url names the upstream.
fake_gh o/r o/r contributor/r-fork
check "fork PR from the upstream checkout exits 0" 0 \
  "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
check "fork PR reports the upstream repo" o/r "$(bash "$script" "$url" | jq -r '.repo')"

# And the fork checkout itself is still the wrong place to review it.
fake_gh o/r contributor/r-fork contributor/r-fork
check "fork PR from the fork checkout exits 3" 3 \
  "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"

# A pull request with no resolvable number must not report success: exit 0
# means proceed, and the caller branches on this JSON.
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view")     echo '{"url":"https://github.com/o/r/pull/7"}' ;;
  "repo view")   for a in "$@"; do [ "$a" = "-q" ] && { echo "o/r"; exit 0; }; done ;;
esac
SH
chmod +x "$tmp/bin/gh"
check "absent PR number exits 2" 2 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"

# The environment preflights must exit 2, never 0. Every other check installs a
# healthy stub, so without these a mutation turning a preflight into exit 0 is
# invisible - the one direction this guard must never fail in.
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
exit 127
SH
chmod +x "$tmp/bin/gh"
check "gh unusable exits 2" 2 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"

cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in auth) exit 1 ;; *) exit 0 ;; esac
SH
chmod +x "$tmp/bin/gh"
check "gh unauthenticated exits 2" 2 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
out="$(bash "$script" "$url" 2>&1 >/dev/null)"
case "$out" in *"gh auth login"*) r=yes ;; *) r=no ;; esac
check "unauthenticated names the fix" yes "$r"

[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
