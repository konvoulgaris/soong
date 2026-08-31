#!/usr/bin/env bash
# Read or write soong's per-repo configuration.
#
#   soong-setup.sh get [project]
#   soong-setup.sh set [--roadmap-db ID] [--task-db ID] [--task-template ID]
#                     [--require-scope true|false] [project]
#
# Config: ${XDG_DATA_HOME:-$HOME/.local/share}/soong/soong.json
# Shape:  { "<project>": { roadmapDb, taskDb, taskTemplate, requireScope,
#                          updatedAt } }
#
# set merges into the existing record: it writes only the keys it was given, so
# configuring one capability never clears another. At least one flag is needed.
#
# Exit codes, so a caller can branch:
#   0  ok
#   1  error (no jq, unreadable or corrupt config, failed write)
#   2  usage error, or not inside a git repository
#   3  get only: this project has no mapping yet
set -uo pipefail

die() { echo "soong-setup: $1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
Read or write soong's per-repo configuration.

  soong-setup.sh get [project]
  soong-setup.sh set [--roadmap-db ID] [--task-db ID] [--task-template ID]
                    [--require-scope true|false] [project]

Config: ${XDG_DATA_HOME:-$HOME/.local/share}/soong/soong.json
get exits 3 when the project has no mapping, so a caller can branch on it.
set merges: it writes only the keys you pass, and needs at least one flag.
EOF
}

if [ -n "${XDG_DATA_HOME:-}" ]; then
  dir="$XDG_DATA_HOME/soong"
else
  [ -n "${HOME:-}" ] || die "set XDG_DATA_HOME or HOME so the config has a home" 2
  dir="$HOME/.local/share/soong"
fi
file="$dir/soong.json"
legacy="$dir/architect.json"

# Reads prefer soong.json and fall back to the pre-rename name, so a repo
# configured before the rename keeps working with no migration step. Writes
# always target soong.json, so the first set migrates the repo. The fallback is
# read-only and one directional: nothing writes back to architect.json, and the
# two files are never merged, because a merge needs a precedence rule the user
# cannot see.
read_file() {
  if [ -f "$file" ]; then
    echo "$file"
  elif [ -f "$legacy" ]; then
    echo "$legacy"
  else
    return 1
  fi
}

# One repo is one mapping, so key on the main checkout even from a linked
# worktree: --show-toplevel would return the worktree dir and split the mapping
# per branch. --git-common-dir points at the main .git in both cases.
default_project() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  local top="${common%/.git}"          # bare repos keep the .git-less path as-is
  top="${top%/}"
  [ -n "$top" ] || return 1
  echo "${top##*/}"
}

resolve_project() {
  if [ -n "${1:-}" ]; then
    echo "$1"
  else
    default_project || die "not inside a git repository" 2
  fi
}

cmd="${1:-}"; shift || true

case "$cmd" in
  get)
    [ $# -le 1 ] || die "get takes at most one project argument" 2
    command -v jq >/dev/null || die "jq is required"
    project="$(resolve_project "${1:-}")" || exit $?
    src="$(read_file)" || die "no config for '$project'" 3
    jq -e . "$src" >/dev/null 2>&1 || die "$src is not valid JSON"
    jq -e 'type == "object"' "$src" >/dev/null 2>&1 || die "$src is not a JSON object"
    # --exit-status would also fire on a stored false/null, so test for the key.
    jq -e --arg p "$project" 'has($p)' "$src" >/dev/null 2>&1 \
      || die "no config for '$project'" 3
    jq --arg p "$project" '.[$p]' "$src"
    ;;

  set)
    roadmap=""; task=""; template=""; template_seen=0; scope=""
    project=""; have_project=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --roadmap-db|--task-db|--task-template|--require-scope)
          flag="$1"; shift
          [ $# -gt 0 ] || die "$flag needs a value" 2
          case "$1" in -*) die "$flag needs a value, got '$1'" 2 ;; esac
          case "$flag" in
            --roadmap-db) roadmap="$1" ;;
            --task-db) task="$1" ;;
            --task-template) template="$1"; template_seen=1 ;;
            --require-scope)
              case "$1" in
                true|false) scope="$1" ;;
                *) die "--require-scope takes true or false, got '$1'" 2 ;;
              esac
              ;;
          esac
          ;;
        --roadmap-db=*)    roadmap="${1#--roadmap-db=}" ;;
        --task-db=*)       task="${1#--task-db=}" ;;
        --task-template=*) template="${1#--task-template=}"; template_seen=1 ;;
        --require-scope=*)
          scope="${1#--require-scope=}"
          case "$scope" in
            true|false) ;;
            *) die "--require-scope takes true or false, got '$scope'" 2 ;;
          esac
          ;;
        -*) die "unknown flag: $1" 2 ;;
        *)
          [ "$have_project" -eq 0 ] || die "unexpected extra argument: $1" 2
          project="$1"; have_project=1
          ;;
      esac
      shift
    done

    # No flag is individually required any more: a repo may configure the
    # commits capability without ever supplying a Notion database. But a set
    # with nothing to set is a usage error, not a no-op write.
    [ -n "$roadmap$task$template$scope" ] || [ "$template_seen" -eq 1 ] \
      || die "set needs at least one flag" 2

    command -v jq >/dev/null || die "jq is required"
    project="$(resolve_project "$project")" || exit $?

    mkdir -p "$dir" || die "cannot create $dir"
    chmod 700 "$dir" 2>/dev/null || true    # the key names alone leak project list
    [ -f "$file" ] || echo '{}' > "$file" || die "cannot write $file"
    jq -e 'type == "object"' "$file" >/dev/null 2>&1 \
      || die "$file is not a JSON object; fix or remove it"

    # Same dir as the target, so the rename is atomic and cannot cross devices.
    tmp="$(mktemp "$dir/.soong.XXXXXX")" || die "cannot create a temp file in $dir"
    trap 'rm -f "$tmp"' EXIT

    jq --arg p "$project" --arg r "$roadmap" --arg k "$task" --arg tpl "$template" \
       --arg scope "$scope" --argjson tplseen "$template_seen" \
       --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '(.[$p] //= {})
        | (if ($r | length) > 0 then .[$p].roadmapDb = $r else . end)
        | (if ($k | length) > 0 then .[$p].taskDb    = $k else . end)
        | (if $tplseen == 1
           then .[$p].taskTemplate = (if ($tpl | length) > 0 then $tpl else null end)
           else . end)
        | (if ($scope | length) > 0 then .[$p].requireScope = ($scope == "true") else . end)
        | .[$p].updatedAt = $t' "$file" > "$tmp" || die "failed to build the new config"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$file" || die "failed to write $file"
    trap - EXIT

    jq --arg p "$project" '.[$p]' "$file"
    ;;

  -h|--help|help)
    usage
    ;;

  "")
    usage >&2
    exit 2
    ;;

  *)
    die "unknown command '$cmd' (want: get, set)" 2
    ;;
esac
