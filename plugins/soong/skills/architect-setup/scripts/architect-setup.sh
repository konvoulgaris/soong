#!/usr/bin/env bash
# Read or write the architect Notion mapping for a repo.
#
#   architect-setup.sh get [project]
#   architect-setup.sh set --roadmap-db ID --task-db ID [--task-template ID|--task-template ""] [project]
#
# Config: ${XDG_DATA_HOME:-$HOME/.local/share}/soong/architect.json
# Shape:  { "<project>": { roadmapDb, taskDb, taskTemplate, updatedAt } }
#
# get exits 3 when the project has no mapping, so a caller can branch on it.
set -uo pipefail

command -v jq >/dev/null || { echo "architect-setup: jq is required" >&2; exit 1; }

dir="${XDG_DATA_HOME:-$HOME/.local/share}/soong"
file="$dir/architect.json"

# ponytail: repo name only, not remote URL. Two clones of one repo share a mapping.
default_project() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "architect-setup: not inside a git repository" >&2; exit 2; }
  basename "$top"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  get)
    project="${1:-$(default_project)}"
    [ -f "$file" ] || { echo "architect-setup: no config for '$project'" >&2; exit 3; }
    out="$(jq -e --arg p "$project" '.[$p] // empty' "$file" 2>/dev/null)" || {
      echo "architect-setup: no config for '$project'" >&2; exit 3; }
    [ -n "$out" ] || { echo "architect-setup: no config for '$project'" >&2; exit 3; }
    echo "$out"
    ;;

  set)
    roadmap=""; task=""; template=""; template_set=0; project=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --roadmap-db)    shift; [ $# -gt 0 ] || { echo "--roadmap-db needs a value" >&2; exit 2; }; roadmap="$1" ;;
        --roadmap-db=*)  roadmap="${1#--roadmap-db=}" ;;
        --task-db)       shift; [ $# -gt 0 ] || { echo "--task-db needs a value" >&2; exit 2; }; task="$1" ;;
        --task-db=*)     task="${1#--task-db=}" ;;
        --task-template) shift; [ $# -gt 0 ] || { echo "--task-template needs a value" >&2; exit 2; }; template="$1"; template_set=1 ;;
        --task-template=*) template="${1#--task-template=}"; template_set=1 ;;
        -*) echo "architect-setup: unknown flag: $1" >&2; exit 2 ;;
        *) project="$1" ;;
      esac
      shift
    done

    [ -n "$roadmap" ] || { echo "architect-setup: --roadmap-db is required" >&2; exit 2; }
    [ -n "$task" ]    || { echo "architect-setup: --task-db is required" >&2; exit 2; }
    [ -n "$project" ] || project="$(default_project)"

    mkdir -p "$dir"
    [ -f "$file" ] || echo '{}' > "$file"
    jq -e . "$file" >/dev/null 2>&1 || { echo "architect-setup: $file is not valid JSON" >&2; exit 1; }

    tmp="$(mktemp)" || exit 1
    trap 'rm -f "$tmp"' EXIT
    jq --arg p "$project" --arg r "$roadmap" --arg k "$task" \
       --arg tpl "$template" --argjson tplset "$template_set" \
       --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.[$p] = {
          roadmapDb: $r,
          taskDb: $k,
          taskTemplate: (if $tplset == 1 and ($tpl | length) > 0 then $tpl else null end),
          updatedAt: $t
        }' "$file" > "$tmp" && mv "$tmp" "$file"
    trap - EXIT
    chmod 600 "$file" 2>/dev/null || true

    jq -e --arg p "$project" '.[$p]' "$file"
    ;;

  ""|-h|--help|help)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    [ -z "$cmd" ] && exit 2 || exit 0
    ;;

  *)
    echo "architect-setup: unknown command '$cmd' (want: get, set)" >&2
    exit 2
    ;;
esac
