#!/usr/bin/env bash
# Read or write soong's per-repo configuration.
#
#   soong-setup.sh get [project]
#   soong-setup.sh check [capability] [--project NAME]
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
# On first use, a pre-rename architect.json in the same directory is copied
# forward to soong.json verbatim. The legacy file is kept, untouched, as a backup.
#
# Exit codes, so a caller can branch:
#   0  ok
#   1  error (no jq, unreadable or corrupt config, failed write)
#   2  usage error, or not inside a git repository
#   3  not configured: get has no mapping for this project, or check
#      found a capability whose required keys are absent
set -uo pipefail

die() { echo "soong-setup: $1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
Read or write soong's per-repo configuration.

  soong-setup.sh get [project]
  soong-setup.sh check [capability] [--project NAME]
  soong-setup.sh set [--roadmap-db ID] [--task-db ID] [--task-template ID]
                    [--require-scope true|false] [project]

Config: ${XDG_DATA_HOME:-$HOME/.local/share}/soong/soong.json
get exits 3 when the project has no mapping, so a caller can branch on it.
check exits 3 when a capability's required keys are absent, 0 when they are all
present, and 2 for an unknown capability. With no capability it sweeps all of
them. Capabilities: notion, commits.
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

# Capability -> required keys. This table is what replaces a stored setup version
# number: what is missing is computed from which required keys are absent, so a
# new capability shows up as unsatisfied for every repo that has not answered its
# questions, with nothing to migrate.
#
# One row is the whole cost on the read side -- check and the sweep pick it up
# with no other edit. Writing is not generic in the same way: set still needs a
# local, two flag-parsing arms, and a jq clause per key, because --require-scope
# coerces to a boolean where the others stay strings. Worth knowing before
# claiming a new capability is a one-line change.
#
# Optional keys are deliberately absent from this table. taskTemplate is optional
# for notion, so it appears nowhere and never blocks a capability.
capabilities="notion commits"
required_keys() {
  case "$1" in
    notion)  echo "roadmapDb taskDb" ;;
    commits) echo "requireScope" ;;
    *)       return 1 ;;
  esac
}

# Copy the pre-rename config forward, once, before anything reads or writes it.
# Reads preferred soong.json and writes always created it, so the first set on an
# unmigrated repo stranded that repo's Notion mapping in architect.json where
# nothing would read it again. Migrating the whole file instead carries every
# project over, not just the one being written.
#
# Only fires when soong.json is absent and architect.json is present, so a second
# run is a no-op. A corrupt legacy file is left where it is rather than laundered
# into the new name: the caller then hits the same corrupt-config error it always
# did, reported against architect.json. The legacy file is never modified or
# removed, so it stays on disk as a backup.
migrate_legacy() {
  [ -f "$file" ] && return 0
  [ -f "$legacy" ] || return 0

  jq -e 'type == "object"' "$legacy" >/dev/null 2>&1 \
    || die "$legacy is not a JSON object; fix or remove it"

  mkdir -p "$dir" || die "cannot create $dir"
  chmod 700 "$dir" 2>/dev/null || true

  # Same dir as the target, so the rename is atomic and a half-copied file can
  # never appear at soong.json.
  local tmp
  tmp="$(mktemp "$dir/.soong.XXXXXX")" || die "cannot create a temp file in $dir"
  trap 'rm -f "$tmp"' EXIT
  cat "$legacy" > "$tmp" || die "failed to copy $legacy forward"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file" || die "failed to write $file"
  trap - EXIT
}

# The config to read, or exit 1 when there is none.
#
# There is no legacy fallback here, because there is nothing left for one to do.
# Every caller runs migrate_legacy first, and that leaves only three states: the
# copy just succeeded so soong.json exists, soong.json already existed, or
# neither file is there. A corrupt architect.json never reaches this point at all
# -- migrate_legacy reports it by name and dies, and die is exit, so the whole
# process stops rather than falling through to a fallback.
read_file() {
  [ -f "$file" ] || return 1
  echo "$file"
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
    migrate_legacy
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
    migrate_legacy
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

  check)
    command -v jq >/dev/null || die "jq is required"

    # A bare first argument is a capability, never a project. So `check comits`
    # (a typo) is exit 2, not a sweep of a project named "comits" -- a typo in a
    # skill's check call must never read as "the user needs to run setup", which
    # is what exit 3 means to every caller.
    #
    # That costs the one-argument sweep form: `check <project>` is spelled
    # `check --project <name>`. Only the test suite passes a project explicitly;
    # every real caller relies on the default, so the flag costs nothing at the
    # call sites that exist and removes a whole class of silent misread.
    cap=""; project_arg=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --project)
          shift
          [ $# -gt 0 ] || die "--project needs a value" 2
          project_arg="$1"
          ;;
        --project=*) project_arg="${1#--project=}" ;;
        -*) die "unknown flag: $1" 2 ;;
        *)
          # Validate before the duplicate check, so `check notion badcap` names
          # badcap rather than complaining about the count.
          required_keys "$1" >/dev/null 2>&1 \
            || die "unknown capability '$1' (want: $capabilities)" 2
          [ -z "$cap" ] || die "check takes at most one capability" 2
          cap="$1"
          ;;
      esac
      shift
    done

    # Migrate before resolving the project, like every other config-touching
    # command: a repo configured before the rename must read as configured here,
    # or every skill's check sends the user back into a setup they already did.
    migrate_legacy
    project="$(resolve_project "$project_arg")" || exit $?

    src="$(read_file)" || src=""
    if [ -n "$src" ]; then
      jq -e . "$src" >/dev/null 2>&1 || die "$src is not valid JSON"
      jq -e 'type == "object"' "$src" >/dev/null 2>&1 || die "$src is not a JSON object"
      # A scalar where a record belongs is a hand-corrupted config, and set
      # refuses to merge into it. Report that as an error, not as exit 3: a 3
      # would send the caller into a setup that then refuses to write. Checked
      # once here rather than inferred from a failing has() below, where a jq
      # error and a genuinely absent key are indistinguishable.
      jq -e --arg p "$project" '(.[$p] // {}) | type == "object"' "$src" >/dev/null 2>&1 \
        || die "$src has a non-object record for '$project'; fix or remove it"
    fi

    # Presence is has(), never truthiness: requireScope false is a configured
    # commits capability, and a jq -e test would read it as missing.
    missing_for() { # missing_for <capability> -> prints missing key names
      local c="$1" k out=""
      for k in $(required_keys "$c"); do
        if [ -z "$src" ] \
          || ! jq -e --arg p "$project" --arg k "$k" \
                 '(.[$p] // {}) | has($k)' "$src" >/dev/null 2>&1; then
          out="$out $k"
        fi
      done
      printf '%s' "${out# }"
    }

    if [ -n "$cap" ]; then
      gaps="$(missing_for "$cap")"
      [ -z "$gaps" ] || die "$cap is missing: $gaps" 3
      exit 0
    fi

    rc=0
    for c in $capabilities; do
      gaps="$(missing_for "$c")"
      if [ -z "$gaps" ]; then
        echo "$c: configured"
      else
        echo "$c: missing $gaps"
        rc=3
      fi
    done
    exit "$rc"
    ;;

  -h|--help|help)
    usage
    ;;

  "")
    usage >&2
    exit 2
    ;;

  *)
    die "unknown command '$cmd' (want: get, check, set)" 2
    ;;
esac
