#!/usr/bin/env bash
set -uo pipefail

STALE_DAYS=30
DRY_RUN="${DRY_RUN:-0}"
AUTO=0
SCAN_ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --auto) AUTO=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --days) shift; [ $# -gt 0 ] || { echo "--days needs a value" >&2; exit 2; }; STALE_DAYS="$1" ;;
    --days=*) STALE_DAYS="${1#--days=}" ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) SCAN_ROOT="$1" ;;
  esac
  shift
done
[ -z "$SCAN_ROOT" ] && SCAN_ROOT="$HOME"

case "$STALE_DAYS" in
  ''|*[!0-9]*) echo "--days must be a positive integer" >&2; exit 2 ;;
esac
[ "$STALE_DAYS" -lt 1 ] && { echo "--days must be >= 1" >&2; exit 2; }

PRUNE_NAMES=(
  Library "Application Support" .Trash .cache Caches
  node_modules .npm .pnpm-store .cargo .rustup .gradle .m2
  Applications .vscode .docker .colima .orbstack .lima
  "Google Drive" Dropbox OneDrive iCloud Photos Music Movies
  venv .venv __pycache__ .tox site-packages
)

build_find_args() {
  FIND_ARGS=("$SCAN_ROOT")
  local n first=1
  FIND_ARGS+=("(")
  for n in "${PRUNE_NAMES[@]}"; do
    if [ "$first" -eq 1 ]; then first=0; else FIND_ARGS+=("-o"); fi
    FIND_ARGS+=("-name" "$n")
  done
  FIND_ARGS+=(")" "-prune" "-o" "-type" "d" "-name" ".git" "-print")
}

now_epoch=$(date +%s)
cutoff=$((now_epoch - STALE_DAYS * 86400))

ESC=$'\033'
C_RESET="${ESC}[0m"
C_BOLD="${ESC}[1m"
C_INV="${ESC}[7m"

if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
  C_GOLD="${ESC}[38;5;179m"
  C_DIM="${ESC}[38;5;94m"
  C_SKIN="${ESC}[38;5;223m"
  C_GREEN="${ESC}[38;5;108m"
  C_RED="${ESC}[38;5;130m"
  C_YELLOW="${ESC}[38;5;179m"
else
  C_GOLD="${ESC}[33m"
  C_DIM="${ESC}[2m"
  C_SKIN="${ESC}[37m"
  C_GREEN="${ESC}[32m"
  C_RED="${ESC}[31m"
  C_YELLOW="${ESC}[33m"
fi
C_CYAN="$C_GOLD"
C_BLUE="$C_SKIN"

PAD_LEFT=4
PAD_TOP=2

hide_cursor() { printf '%s[?25l' "$ESC"; }
show_cursor() { printf '%s[?25h' "$ESC"; }
clear_screen() { printf '%s[2J%s[H' "$ESC" "$ESC"; }
home_screen() { printf '%s[H' "$ESC"; }
move_to() { printf '%s[%d;%dH' "$ESC" "$1" "$2"; }
clear_line() { printf '%s[2K' "$ESC"; }
clear_below() { printf '%s[J' "$ESC"; }

at() { move_to $(( PAD_TOP + $1 )) "$PAD_LEFT"; }

cols() { tput cols 2>/dev/null || echo 80; }
rows() { tput lines 2>/dev/null || echo 24; }

TTY_SAVED=""

enter_raw() {
  TTY_SAVED=$(stty -g 2>/dev/null)
  stty -icanon -echo min 1 time 0 2>/dev/null
}

cleanup_term() {
  [ "$AUTO" = "1" ] && return
  show_cursor
  [ -n "$TTY_SAVED" ] && stty "$TTY_SAVED" 2>/dev/null
  printf '%s' "$C_RESET"
}

on_interrupt() {
  cleanup_term
  clear_screen
  exit 130
}
trap cleanup_term EXIT
trap on_interrupt INT TERM

CLAUDE_PROJECTS="$HOME/.claude/projects"

WT_PATH=()
WT_BRANCH=()
WT_ROOT=()
WT_STATE=()
WT_SIZE=()
WT_LAST=()
WT_SESSION=()
WT_SELECTED=()

dir_size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

human_kb() {
  local kb=$1
  if [ "$kb" -ge 1048576 ]; then
    awk "BEGIN{printf \"%.1fGB\", $kb/1048576}"
  elif [ "$kb" -ge 1024 ]; then
    awk "BEGIN{printf \"%.1fMB\", $kb/1024}"
  else
    printf '%dKB' "$kb"
  fi
}

age_days() {
  local last=$1
  [ "$last" -eq 0 ] && { echo "?"; return; }
  echo $(( (now_epoch - last) / 86400 ))
}

mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

session_last_activity() {
  local wt=$1 slug dir newest m f
  slug=$(printf '%s' "$wt" | sed 's#[/.]#-#g')
  dir="$CLAUDE_PROJECTS/$slug"
  [ -d "$dir" ] || { echo 0; return; }
  newest=0
  while IFS= read -r f; do
    m=$(mtime_of "$f")
    [ -n "$m" ] && [ "$m" -gt "$newest" ] && newest=$m
  done < <(find "$dir" -name '*.jsonl' 2>/dev/null)
  echo "$newest"
}

spinner_frame() {
  local i=$(( $1 % 4 ))
  case $i in
    0) printf '|' ;;
    1) printf '/' ;;
    2) printf -- '-' ;;
    3) printf '\\' ;;
  esac
}

draw_bar() {
  local cur=$1 total=$2 width=$3 filled empty i pct
  [ "$total" -le 0 ] && total=1
  pct=$(( cur * 100 / total ))
  filled=$(( cur * width / total ))
  [ "$filled" -gt "$width" ] && filled=$width
  empty=$(( width - filled ))
  printf '%s[' "$C_CYAN"
  for ((i=0;i<filled;i++)); do printf '█'; done
  printf '%s' "$C_DIM"
  for ((i=0;i<empty;i++)); do printf '·'; done
  printf '%s]%s %3d%%' "$C_CYAN" "$C_RESET" "$pct"
}

scan_header() {
  local w; w=$(cols)
  home_screen
  at 0; clear_line
  printf '%s%sworktree cleanup%s %s· indexing%s' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
  at 1; clear_line
  printf '%sscan root: %s   stale after %dd%s' "$C_DIM" "$SCAN_ROOT" "$STALE_DAYS" "$C_RESET"
  at 2; clear_line; hline $(( w - PAD_LEFT * 2 ))
}

REPOS=()

discover_repos() {
  local git_dir repo found=0 bw
  bw=$(( $(cols) - 12 )); [ "$bw" -gt 40 ] && bw=40

  clear_screen
  scan_header
  while IFS= read -r git_dir; do
    repo=$(cd "$(dirname "$git_dir")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || continue
    REPOS+=("$repo")
    found=$((found + 1))
    scan_header
    at 4; clear_line
    printf '%s%s%s  discovering repositories   %sfound %s%d%s' \
      "$C_CYAN" "$(spinner_frame $found)" "$C_RESET" "$C_DIM" "$C_BOLD" "$found" "$C_RESET"
    at 6; clear_line
    printf '%s%.*s%s' "$C_DIM" $(( $(cols) - PAD_LEFT * 2 )) "$repo" "$C_RESET"
  done < <(build_find_args; find "${FIND_ARGS[@]}" 2>/dev/null)

  if [ "${#REPOS[@]}" -gt 1 ]; then
    local tmp
    tmp=$(printf '%s\n' "${REPOS[@]}" | sort -u)
    REPOS=()
    while IFS= read -r repo; do REPOS+=("$repo"); done <<< "$tmp"
  fi
}

scan_worktrees() {
  local repo path branch line i total bw done_count

  hide_cursor
  discover_repos

  total=${#REPOS[@]}
  bw=$(( $(cols) - 12 )); [ "$bw" -gt 40 ] && bw=40
  done_count=0

  for ((i=0;i<total;i++)); do
    repo="${REPOS[$i]}"
    done_count=$((done_count + 1))

    scan_header
    at 4; clear_line
    printf '%sinspecting worktrees%s   %s%d%s / %d repos   %d candidates' \
      "$C_BOLD" "$C_RESET" "$C_CYAN" "$done_count" "$C_RESET" "$total" "${#WT_PATH[@]}"
    at 5; clear_line
    draw_bar "$done_count" "$total" "$bw"
    at 7; clear_line
    printf '%s%.*s%s' "$C_DIM" $(( $(cols) - PAD_LEFT * 2 )) "$repo" "$C_RESET"

    path=""
    branch=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) path="${line#worktree }" ;;
        "branch "*) branch="${line#branch }"; branch="${branch#refs/heads/}" ;;
        "detached") branch="" ;;
        "")
          [ -n "$path" ] && classify "$repo" "$path" "$branch"
          path=""; branch=""
          ;;
      esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
    [ -n "$path" ] && classify "$repo" "$path" "$branch"
  done
}

classify() {
  local repo=$1 path=$2 branch=$3
  local main_path remote_ls last dirty size state has_remote_ref session

  main_path=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)
  [ "$path" = "$main_path" ] && return
  [ -z "$branch" ] && return

  has_remote_ref=0
  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    has_remote_ref=1
  fi
  remote_ls=$(git -C "$repo" ls-remote --heads origin "$branch" 2>/dev/null)
  [ -n "$remote_ls" ] && has_remote_ref=1

  last=$(git -C "$path" log -1 --format=%ct 2>/dev/null || echo 0)
  dirty=$(git -C "$path" status --porcelain 2>/dev/null)
  size=$(dir_size_kb "$path"); [ -z "$size" ] && size=0
  session=$(session_last_activity "$path")

  if [ "$has_remote_ref" -eq 1 ]; then
    state="remote"
  elif [ -n "$dirty" ]; then
    state="dirty"
  elif [ "$last" -ge "$cutoff" ] || [ "$session" -ge "$cutoff" ]; then
    state="recent"
  else
    state="stale"
  fi

  WT_PATH+=("$path")
  WT_BRANCH+=("$branch")
  WT_ROOT+=("$main_path")
  WT_STATE+=("$state")
  WT_SIZE+=("$size")
  WT_LAST+=("$last")
  WT_SESSION+=("$session")
  if [ "$state" = "stale" ]; then
    WT_SELECTED+=("1")
  else
    WT_SELECTED+=("0")
  fi
}

state_label() {
  case "$1" in
    stale)  printf '%sSTALE %s' "$C_GREEN" "$C_RESET" ;;
    dirty)  printf '%sDIRTY %s' "$C_YELLOW" "$C_RESET" ;;
    recent) printf '%sRECENT%s' "$C_BLUE" "$C_RESET" ;;
    remote) printf '%sREMOTE%s' "$C_DIM" "$C_RESET" ;;
  esac
}

KEY=""

read_key() {
  local k b1 b2
  KEY=""
  IFS= read -rsn1 k
  if [ "$k" = "$ESC" ]; then
    IFS= read -rsn1 -t 1 b1
    IFS= read -rsn1 -t 1 b2
    case "$b1$b2" in
      '[A'|'OA') KEY=up ;;
      '[B'|'OB') KEY=down ;;
      '[C'|'OC') KEY=right ;;
      '[D'|'OD') KEY=left ;;
      *) KEY=esc ;;
    esac
  elif [ "$k" = "" ]; then
    KEY=enter
  elif [ "$k" = " " ]; then
    KEY=space
  else
    KEY="$k"
  fi
}

draw_box_top() { printf '%s%s' "$C_DIM" "$ESC(0l"; local i; for ((i=0;i<$1-2;i++)); do printf 'q'; done; printf 'k%s%s' "$ESC(B" "$C_RESET"; }

hline() {
  local w=$1 i
  printf '%s' "$C_DIM"
  for ((i=0;i<w;i++)); do printf '─'; done
  printf '%s' "$C_RESET"
}

age_label() {
  local a; a=$(age_days "$1")
  [ "$a" = "?" ] && { printf -- '--'; return; }
  printf '%dd' "$a"
}

last_activity() {
  local idx=$1 g=${WT_LAST[$1]} s=${WT_SESSION[$1]}
  if [ "$s" -gt "$g" ]; then echo "$s"; else echo "$g"; fi
}

DISPLAY_KIND=()
DISPLAY_REF=()

build_display() {
  DISPLAY_KIND=(); DISPLAY_REF=()
  local i prev_root=""
  for ((i=0;i<${#WT_PATH[@]};i++)); do
    if [ "${WT_ROOT[$i]}" != "$prev_root" ]; then
      DISPLAY_KIND+=("H"); DISPLAY_REF+=("$i")
      prev_root="${WT_ROOT[$i]}"
    fi
    DISPLAY_KIND+=("I"); DISPLAY_REF+=("$i")
  done
}

review_screen() {
  local cursor=0 top=0 key n visible h w i idx line prefix
  local d dcount dcursor
  n=${#WT_PATH[@]}
  w=$(cols)

  if [ "$n" -eq 0 ]; then
    clear_screen
    at 0
    printf '%sNo removable worktrees found under %s%s' "$C_GREEN" "$SCAN_ROOT" "$C_RESET"
    at 2
    printf '%spress any key%s' "$C_DIM" "$C_RESET"
    read_key
    return 1
  fi

  build_display
  dcount=${#DISPLAY_KIND[@]}

  clear_screen
  while true; do
    h=$(rows)
    visible=$(( h - PAD_TOP - 8 ))
    [ "$visible" -lt 1 ] && visible=1

    dcursor=0
    for ((d=0;d<dcount;d++)); do
      [ "${DISPLAY_KIND[$d]}" = "I" ] && [ "${DISPLAY_REF[$d]}" -eq "$cursor" ] && { dcursor=$d; break; }
    done
    if [ "$dcursor" -lt "$top" ]; then top=$dcursor; fi
    if [ "$dcursor" -ge $(( top + visible )) ]; then top=$(( dcursor - visible + 1 )); fi

    home_screen
    at 0; clear_line
    printf '%s%sworktree review%s %s(space toggle · a all · s stale · n none · enter delete · q cancel)%s' \
      "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
    at 1; clear_line
    printf '%s      %-6s  %7s  %-8s  %s%s' \
      "$C_DIM" "state" "size" "activity" "branch" "$C_RESET"
    at 2; clear_line; hline $(( w - PAD_LEFT * 2 ))

    for ((i=0;i<visible;i++)); do
      d=$(( top + i ))
      at $(( 3 + i )); clear_line
      [ "$d" -ge "$dcount" ] && continue
      idx="${DISPLAY_REF[$d]}"

      if [ "${DISPLAY_KIND[$d]}" = "H" ]; then
        printf '%s%s%s' "$C_GOLD$C_BOLD" "${WT_ROOT[$idx]}" "$C_RESET"
        continue
      fi

      if [ "${WT_SELECTED[$idx]}" = "1" ]; then prefix="${C_RED}[x]${C_RESET}"; else prefix="[ ]"; fi
      line=$(printf '%s %s  %7s  %-8s  %s' \
        "$prefix" "$(state_label "${WT_STATE[$idx]}")" \
        "$(human_kb "${WT_SIZE[$idx]}")" \
        "$(age_label "$(last_activity "$idx")")" \
        "${WT_BRANCH[$idx]}")

      if [ "$idx" -eq "$cursor" ]; then
        printf '  %s %s %s' "$C_INV" "$line" "$C_RESET"
      else
        printf '    %s' "$line"
      fi
    done

    at $(( 3 + visible )); clear_line; hline $(( w - PAD_LEFT * 2 ))
    local sel_count=0 sel_kb=0
    for ((i=0;i<n;i++)); do
      if [ "${WT_SELECTED[$i]}" = "1" ]; then
        sel_count=$((sel_count + 1))
        sel_kb=$(( sel_kb + WT_SIZE[i] ))
      fi
    done
    at $(( 4 + visible )); clear_line
    printf '%s%sSTALE%s no remote, old  %sRECENT%s active  %sDIRTY%s unsaved  %sREMOTE%s pushed%s' \
      "$C_DIM" "$C_GREEN" "$C_RESET$C_DIM" "$C_BLUE" "$C_RESET$C_DIM" "$C_YELLOW" "$C_RESET$C_DIM" "$C_DIM" "$C_RESET$C_DIM" "$C_RESET"
    at $(( 5 + visible )); clear_line
    printf '%sselected %s%d%s of %d   will free %s%s%s' \
      "$C_DIM" "$C_BOLD" "$sel_count" "$C_RESET$C_DIM" "$n" "$C_BOLD" "$(human_kb "$sel_kb")" "$C_RESET"
    clear_below

    read_key; key="$KEY"
    case "$key" in
      up|k)    cursor=$(( cursor > 0 ? cursor - 1 : 0 )) ;;
      down|j)  cursor=$(( cursor < n - 1 ? cursor + 1 : n - 1 )) ;;
      space)
        if [ "${WT_SELECTED[$cursor]}" = "1" ]; then WT_SELECTED[$cursor]="0"; else WT_SELECTED[$cursor]="1"; fi
        ;;
      a) for ((i=0;i<n;i++)); do WT_SELECTED[$i]="1"; done ;;
      s) for ((i=0;i<n;i++)); do [ "${WT_STATE[$i]}" = "stale" ] && WT_SELECTED[$i]="1"; done ;;
      n) for ((i=0;i<n;i++)); do WT_SELECTED[$i]="0"; done ;;
      enter) return 0 ;;
      q|esc) return 1 ;;
    esac
  done
}

do_delete() {
  local i repo path branch size ok
  local deleted=0 freed=0
  local h; h=$(rows)

  clear_screen
  at 0
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s%sdry-run%s %s(nothing deleted)%s' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$C_DIM" "$C_RESET"
  else
    printf '%s%sdeleting%s' "$C_BOLD" "$C_RED" "$C_RESET"
  fi
  at 1; hline $(( $(cols) - PAD_LEFT * 2 ))

  local n=${#WT_PATH[@]}
  local rowline=3
  for ((i=0;i<n;i++)); do
    [ "${WT_SELECTED[$i]}" = "1" ] || continue
    repo="${WT_ROOT[$i]}"; path="${WT_PATH[$i]}"; branch="${WT_BRANCH[$i]}"; size="${WT_SIZE[$i]}"

    at "$rowline"; clear_line
    printf '%s→%s %s' "$C_YELLOW" "$C_RESET" "$(basename "$path")"

    ok=0
    if [ "$DRY_RUN" = "1" ]; then
      ok=2
    elif git -C "$repo" worktree remove --force "$path" 2>/dev/null; then
      git -C "$repo" branch -D "$branch" >/dev/null 2>&1
      rm -rf "$path" 2>/dev/null
      git -C "$repo" worktree prune >/dev/null 2>&1
      ok=1
    fi

    at "$rowline"; clear_line
    if [ "$ok" -eq 2 ]; then
      deleted=$((deleted + 1)); freed=$(( freed + size ))
      printf '%s◦%s %-34.34s %s%s (dry-run)%s' "$C_YELLOW" "$C_RESET" "$(basename "$path")" "$C_DIM" "$(human_kb "$size")" "$C_RESET"
    elif [ "$ok" -eq 1 ]; then
      deleted=$((deleted + 1)); freed=$(( freed + size ))
      printf '%s✓%s %-34.34s %s%s%s' "$C_GREEN" "$C_RESET" "$(basename "$path")" "$C_DIM" "$(human_kb "$size")" "$C_RESET"
    else
      printf '%s✗%s %-34.34s %sfailed%s' "$C_RED" "$C_RESET" "$(basename "$path")" "$C_RED" "$C_RESET"
    fi
    rowline=$((rowline + 1))
    [ "$rowline" -ge $(( h - PAD_TOP - 3 )) ] && rowline=3
  done

  summary_screen "$deleted" "$freed"
}

summary_screen() {
  local deleted=$1 freed=$2 i root prev_root root_idx child_idx path branch
  local h; h=$(rows)

  clear_screen
  at 0
  printf '%s%scleanup complete%s' "$C_BOLD" "$C_GREEN" "$C_RESET"
  at 1; hline $(( $(cols) - PAD_LEFT * 2 ))

  at 3
  if [ "$DRY_RUN" = "1" ]; then
    printf 'Would delete %s%d%s worktrees   would free %s%s%s' \
      "$C_BOLD" "$deleted" "$C_RESET" "$C_BOLD$C_YELLOW" "$(human_kb "$freed")" "$C_RESET"
  else
    printf 'Deleted %s%d%s worktrees   space freed %s%s%s' \
      "$C_BOLD" "$deleted" "$C_RESET" "$C_BOLD$C_GREEN" "$(human_kb "$freed")" "$C_RESET"
  fi

  local dirty_rows=5 any_dirty=0
  local n=${#WT_PATH[@]}
  prev_root=""; root_idx=0; child_idx=0

  for ((i=0;i<n;i++)); do
    [ "${WT_STATE[$i]}" = "dirty" ] || continue
    if [ "$any_dirty" -eq 0 ]; then
      at "$dirty_rows"
      printf '%sKept (unstaged changes):%s' "$C_YELLOW" "$C_RESET"
      dirty_rows=$((dirty_rows + 1))
      any_dirty=1
    fi
    root="${WT_ROOT[$i]}"; path="${WT_PATH[$i]}"; branch="${WT_BRANCH[$i]}"
    if [ "$root" != "$prev_root" ]; then
      root_idx=$((root_idx + 1)); child_idx=0
      at "$dirty_rows"; printf '%s%d.%s %s' "$C_BOLD" "$root_idx" "$C_RESET" "$root"
      dirty_rows=$((dirty_rows + 1)); prev_root="$root"
    fi
    child_idx=$((child_idx + 1))
    move_to $(( PAD_TOP + dirty_rows )) $(( PAD_LEFT + 3 ))
    printf '%s%d.%s %s %s(%s)%s' "$C_DIM" "$child_idx" "$C_RESET" "$(basename "$path")" "$C_DIM" "$branch" "$C_RESET"
    dirty_rows=$((dirty_rows + 1))
    [ "$dirty_rows" -ge $(( h - PAD_TOP - 2 )) ] && break
  done

  move_to $(( h - 1 )) "$PAD_LEFT"
  printf '%spress any key to exit%s' "$C_DIM" "$C_RESET"
  read_key
}

run_auto() {
  local git_dir repo path branch line i n deleted=0 freed=0 size ok
  local prev_root root_idx child_idx root

  echo "Indexing $SCAN_ROOT (stale after ${STALE_DAYS}d)..."
  while IFS= read -r git_dir; do
    repo=$(cd "$(dirname "$git_dir")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || continue
    REPOS+=("$repo")
  done < <(build_find_args; find "${FIND_ARGS[@]}" 2>/dev/null)

  if [ "${#REPOS[@]}" -gt 1 ]; then
    local tmp
    tmp=$(printf '%s\n' "${REPOS[@]}" | sort -u)
    REPOS=()
    while IFS= read -r repo; do REPOS+=("$repo"); done <<< "$tmp"
  fi
  echo "Indexed ${#REPOS[@]} repositories"

  echo "Checking worktrees..."
  for ((i=0;i<${#REPOS[@]};i++)); do
    repo="${REPOS[$i]}"
    path=""; branch=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) path="${line#worktree }" ;;
        "branch "*) branch="${line#branch }"; branch="${branch#refs/heads/}" ;;
        "detached") branch="" ;;
        "")
          [ -n "$path" ] && classify "$repo" "$path" "$branch"
          path=""; branch=""
          ;;
      esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
    [ -n "$path" ] && classify "$repo" "$path" "$branch"
  done

  n=${#WT_PATH[@]}
  local stale=0
  for ((i=0;i<n;i++)); do [ "${WT_STATE[$i]}" = "stale" ] && stale=$((stale + 1)); done
  echo "Found $n candidates, $stale stale"

  if [ "$stale" -eq 0 ]; then
    echo "Nothing to clean."
    return
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "Dry-run (nothing will be deleted):"
  else
    echo "Cleaning..."
  fi

  for ((i=0;i<n;i++)); do
    [ "${WT_STATE[$i]}" = "stale" ] || continue
    repo="${WT_ROOT[$i]}"; path="${WT_PATH[$i]}"; branch="${WT_BRANCH[$i]}"; size="${WT_SIZE[$i]}"
    if [ "$DRY_RUN" = "1" ]; then
      echo "  would remove $(basename "$path") ($branch, $(human_kb "$size"))"
      deleted=$((deleted + 1)); freed=$(( freed + size ))
    elif git -C "$repo" worktree remove --force "$path" 2>/dev/null; then
      git -C "$repo" branch -D "$branch" >/dev/null 2>&1
      rm -rf "$path" 2>/dev/null
      git -C "$repo" worktree prune >/dev/null 2>&1
      deleted=$((deleted + 1)); freed=$(( freed + size ))
      echo "  removed $(basename "$path") ($branch, $(human_kb "$size"))"
    else
      echo "  FAILED $(basename "$path") ($branch)"
    fi
  done

  echo
  if [ "$DRY_RUN" = "1" ]; then
    echo "Would delete $deleted worktrees, would free $(human_kb "$freed")"
  else
    echo "Deleted $deleted worktrees, space freed $(human_kb "$freed")"
  fi

  prev_root=""; root_idx=0
  local any_dirty=0
  for ((i=0;i<n;i++)); do
    [ "${WT_STATE[$i]}" = "dirty" ] || continue
    if [ "$any_dirty" -eq 0 ]; then
      echo
      echo "Kept (unstaged changes):"
      any_dirty=1
    fi
    root="${WT_ROOT[$i]}"; path="${WT_PATH[$i]}"; branch="${WT_BRANCH[$i]}"
    if [ "$root" != "$prev_root" ]; then
      root_idx=$((root_idx + 1)); child_idx=0
      echo "  $root_idx. $root"
      prev_root="$root"
    fi
    child_idx=$((child_idx + 1))
    echo "     $child_idx. $(basename "$path") ($branch)"
  done
}

main() {
  scan_worktrees

  if [ "${#WT_PATH[@]}" -eq 0 ]; then
    clear_screen
    at 0
    printf '%sNo removable worktrees found under %s%s' "$C_GREEN" "$SCAN_ROOT" "$C_RESET"
    at 2
    printf '%spress any key%s' "$C_DIM" "$C_RESET"
    read_key
    return
  fi

  if review_screen; then
    do_delete
  else
    clear_screen
  fi
}

if [ "$AUTO" = "1" ]; then
  run_auto
  exit 0
fi

if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "worktree-cleanup: needs an interactive terminal" >&2
  exit 1
fi

enter_raw
main
clear_screen
