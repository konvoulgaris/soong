#!/usr/bin/env bash
# Derive a change surface from a unified diff on stdin.
# Emits JSON: {"paths":[...], "entries":[{name,kind,change,before,after}]}
#
# This extracts CANDIDATES. Deciding whether a candidate is reachable from
# outside its file is the caller's judgment, per the spec's inclusion test.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "jq is not installed." >&2; exit 2; }
diff="$(cat)"
paths="$(printf '%s\n' "$diff" | sed -n 's|^diff --git a/.* b/\(.*\)$|\1|p' \
  | jq -R -s -c 'split("\n") | map(select(length > 0)) | unique')"
decl_re='^[+-][[:space:]]*(export[[:space:]]+)?(async[[:space:]]+)?(func|function|def|class|interface|type|struct|enum)[[:space:]]+[A-Za-z_]'
# A Go method carries a receiver before its name: func (s *Server) Handle(...)
recv_re='^[+-][[:space:]]*func[[:space:]]*\([^)]*\)[[:space:]]+[A-Za-z_]'
# An exported binding holding a function is reachable like a declaration:
# export const handler = (x) => ..., export let f = function ...
assign_fn_re='^[+-][[:space:]]*export[[:space:]]+(const|let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(async[[:space:]]+)?(\(|function)'
# Column and index names, which callers depend on by name.
sql_re='(ADD|DROP|RENAME|ALTER)[[:space:]]+(COLUMN|INDEX)[[:space:]]+|CREATE[[:space:]]+(UNIQUE[[:space:]]+)?INDEX[[:space:]]+'
route_re='\.(route|get|post|put|patch|delete)\('
env_re='(os\.environ|process\.env|getenv)'
const_re='^[+-][[:space:]]*(export[[:space:]]+)?(const|var|let)?[[:space:]]*[A-Z][A-Z0-9_]{2,}[[:space:]]*='
entries="[]"
add_entry(){ entries="$(printf '%s' "$entries" | jq -c --arg n "$1" --arg k "$2" --arg c "$3" --arg b "$4" --arg a "$5" '. + [{name:$n,kind:$k,change:$c,before:$b,after:$a}]')"; }
names=(); kinds=(); befores=(); afters=()
name_index(){ local i=0 n; for n in "${names[@]+"${names[@]}"}"; do [ "$n" = "$1" ] && { echo "$i"; return; }; i=$((i+1)); done; echo -1; }
# Only lines that could carry a boundary name reach the loop. A diff is mostly
# context and ordinary code, and spawning a grep per line made a 4000-line
# diff take minutes.
# One pass, so a line matching two patterns is not fed to the loop twice -
# a duplicate line becomes a duplicate entry.
interesting="$(printf '%s\n' "$diff" | grep -E '^[+-]' \
  | grep -Ei "$decl_re|$recv_re|$assign_fn_re|$const_re|$route_re|$env_re|$sql_re" \
    2>/dev/null)"

while IFS= read -r line; do
  case "$line" in ---*|+++*) continue;; esac
  case "$line" in +*) side=after;; -*) side=before;; *) continue;; esac
  body="${line#?}"
  if [[ "$line" =~ $decl_re ]]; then
    name="$(printf '%s' "$body" | sed -nE 's/.*(func|function|def|class|interface|type|struct|enum)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/p')"
    [ -n "$name" ] || continue
    i="$(name_index "$name")"
    if [ "$i" -lt 0 ]; then names+=("$name"); kinds+=("declaration"); befores+=(""); afters+=(""); i=$((${#names[@]}-1)); fi
    if [ "$side" = before ]; then befores[$i]="$body"; else afters[$i]="$body"; fi
    continue
  fi
  if [[ "$line" =~ $recv_re ]]; then
    name="$(printf '%s' "$body" | sed -nE 's/.*func[[:space:]]*\([^)]*\)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/p')"
    [ -n "$name" ] || continue
    i="$(name_index "$name")"
    if [ "$i" -lt 0 ]; then names+=("$name"); kinds+=("declaration"); befores+=(""); afters+=(""); i=$((${#names[@]}-1)); fi
    if [ "$side" = before ]; then befores[$i]="$body"; else afters[$i]="$body"; fi
    continue
  fi
  if [[ "$line" =~ $assign_fn_re ]]; then
    name="$(printf '%s' "$body" | sed -nE 's/.*export[[:space:]]+(const|let|var)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/p')"
    [ -n "$name" ] || continue
    i="$(name_index "$name")"
    if [ "$i" -lt 0 ]; then names+=("$name"); kinds+=("declaration"); befores+=(""); afters+=(""); i=$((${#names[@]}-1)); fi
    if [ "$side" = before ]; then befores[$i]="$body"; else afters[$i]="$body"; fi
    continue
  fi
  if [[ "$(printf '%s' "$body" | tr '[:lower:]' '[:upper:]')" =~ $sql_re ]]; then
    k="$(printf '%s' "$body" | sed -nE 's/.*(ADD|DROP|RENAME|ALTER)[[:space:]]+(COLUMN|INDEX)[[:space:]]+"?([A-Za-z_][A-Za-z0-9_]*)"?.*/\3/pI; s/.*CREATE[[:space:]]+(UNIQUE[[:space:]]+)?INDEX[[:space:]]+"?([A-Za-z_][A-Za-z0-9_]*)"?.*/\2/pI' | head -1)"
    [ -n "$k" ] && add_entry "$k" schema "$([ "$side" = after ] && echo added || echo removed)" "" "$body"
    continue
  fi
  if [[ "$body" =~ $route_re ]]; then
    r="$(printf '%s' "$body" | sed -nE 's|.*["'"'"']([/][^"'"'"']*)["'"'"'].*|\1|p')"
    [ -n "$r" ] && add_entry "$r" route "$([ "$side" = after ] && echo added || echo removed)" "" "$body"
    continue
  fi
  if [[ "$body" =~ $env_re ]]; then
    k="$(printf '%s' "$body" | sed -nE 's/.*["'"'"']([A-Z_][A-Z0-9_]*)["'"'"'].*/\1/p')"
    [ -n "$k" ] && add_entry "$k" env "$([ "$side" = after ] && echo added || echo removed)" "" "$body"
    continue
  fi
  if [[ "$line" =~ $const_re ]]; then
    k="$(printf '%s' "$body" | sed -nE 's/^[[:space:]]*(export[[:space:]]+)?(const|var|let)?[[:space:]]*([A-Z][A-Z0-9_]{2,})[[:space:]]*=.*/\3/p')"
    [ -n "$k" ] && add_entry "$k" config "$([ "$side" = after ] && echo added || echo removed)" "" "$body"
    continue
  fi
done <<EOF
$interesting
EOF
i=0
for n in "${names[@]+"${names[@]}"}"; do
  b="${befores[$i]}"; a="${afters[$i]}"
  if [ -n "$b" ] && [ -n "$a" ]; then ch=altered; elif [ -n "$a" ]; then ch=added; else ch=removed; fi
  add_entry "$n" "${kinds[$i]}" "$ch" "$b" "$a"
  i=$((i+1))
done
jq -cn --argjson p "$paths" --argjson e "$entries" '{paths:$p, entries:$e}'
