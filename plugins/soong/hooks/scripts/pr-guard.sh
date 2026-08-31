#!/usr/bin/env bash
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# The repo's Conventional Commits scope rule: "true", "false", or empty for
# "not configured". Read through soong-setup.sh so the project-key derivation
# lives in exactly one place.
#
# Lazy and memoized on purpose. This hook is a PreToolUse hook on every Bash
# call, so an unconditional read here charges three extra processes (soong-setup,
# its internal git rev-parse, and jq) to `ls` and every other command no branch
# below cares about. Measured over 20 invocations of `ls`, three runs each:
# 93-96 ms per call with the read unconditional, 28-36 ms with it deferred to the
# branches that need it — roughly a third of the cost.
# The PR branches pay the read exactly once, because the result is cached.
#
# _scope_loaded is a separate flag rather than a test on the value: the empty
# string is the legitimate cached answer for "not configured", so testing
# emptiness would re-read on every call in the common case.
_scope_rule=""
_scope_loaded=""
scope_rule() {
  if [ -z "$_scope_loaded" ]; then
    _scope_loaded=1
    # Resolved from $0 rather than CLAUDE_PLUGIN_ROOT: no hook script here uses
    # that variable, and it is set for the hook command rather than guaranteed
    # inside this subprocess. Depending on it would fail silently, because the
    # fail-open rule below turns a failed read into "no scope rule" — a feature
    # that looks like it works while enforcing nothing.
    local setup_sh
    setup_sh="$(cd "$(dirname "$0")/../../skills/soong-setup/scripts" 2>/dev/null && pwd)/soong-setup.sh"
    if [ -f "$setup_sh" ] && command -v jq >/dev/null 2>&1; then
      # Fail open on everything: a missing config, a corrupt one, a non-repo cwd,
      # a missing jq. A guard that dies loudly on every Bash call because a config
      # file got corrupted is worse than one that quietly stops checking scope.
      _scope_rule="$(bash "$setup_sh" get 2>/dev/null \
        | jq -r 'if type == "object" and has("requireScope")
                 then (.requireScope | tostring) else "" end' 2>/dev/null)"
      case "$_scope_rule" in true|false) ;; *) _scope_rule="" ;; esac
    fi
  fi
  printf '%s' "$_scope_rule"
}

# Does a Conventional Commits subject carry a scope? Kept separate from the shape
# check so the shape rule stays in one place and this only answers the one
# question.
has_scope() {
  printf '%s' "$1" | grep -qE '^[a-z]+\([^)]*\)!?:'
}

# Marker class: list/rule markers, blockquote, em-dash, whitespace, robot emoji.
# Applied symmetrically so markdown italics (*sig*) cannot slip past the anchor.
M='[-*_~>—[:space:]🤖]*'
# Same class without the emoji, for the anchored bare-emoji alternative.
M2='[-*_~>—[:space:]]*'

# A closing quote may sit between the phrase and end-of-line once a body has been
# normalised out of its flag (see body_lines).
Q="[\"']?"

# Attribution signature standing alone on its own line.
SIG="^${M}(addressed|fixed|resolved|handled|generated|created|done)[[:space:]]+(by|with)[[:space:]]+claude([[:space:]]+code)?${M}[.!]?${M}${Q}${M}\$"
# Footer trailers. Both anchored: unanchored, the emoji denies any reply that
# merely mentions it, and this repo's threads discuss a hook that greps for it.
TRAILER="^[[:space:]]*co-authored-by:|^${M2}🤖${M2}${Q}${M2}\$"
# Generated-with footer. No space after the class: it is starred and matches
# empty, so a literal space there would let an unmarked line slip.
GENWITH="^${M}generated with"

# The patterns above are line-anchored, which is what makes them signature checks
# rather than prose checks. But a single-line command embeds the body mid-string
# (`-b 'Addressed by Claude Code'`), so there is no line break before the phrase
# and `^` never matches. Multi-line HEREDOC bodies anchor fine; single-line body
# flags do not. Insert a break after each body-flag delimiter and after a HEREDOC
# opener so the body's first line becomes a real line.
body_lines() {
  printf '%s' "$1" | sed -E \
    -e "s/(-b|--body|-f[[:space:]]*body=|-F[[:space:]]*body=|--field[[:space:]]*body=|--raw-field[[:space:]]*body=)[[:space:]]*['\"]?/\1\n/g" \
    -e "s/\\\$\(cat <<-?'?[A-Za-z_]+'?/\n/g"
}

deny() {
  printf '%s' "$1" \
    | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}'
  exit 0
}

advise() {
  printf '%s' "$1" \
    | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:.}}'
  exit 0
}

join_reasons() {
  local out=""
  for r in "$@"; do
    [ -n "$out" ] && out="$out; "
    out="$out$r"
  done
  printf '%s' "$out"
}

# Branch 1: PR create/edit. Ordered first, so a compound command that also posts
# a comment stops here — a hook must emit at most one JSON object.
case "$cmd" in
  *"gh pr create"*|*"gh pr edit"*)
    title=$(printf '%s' "$cmd" | grep -oE -- '(--title|-t)[ =]+("[^"]*"|'"'"'[^'"'"']*'"'"')' | head -1 | sed -E 's/^(--title|-t)[ =]+//; s/^["'"'"']//; s/["'"'"']$//')

    reasons=()

    if [ -n "$title" ]; then
      if printf '%s' "$title" | grep -qiE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)\((\*|misc|placeholder|tbd|na|n/a)\)'; then
        reasons+=("Do not use a placeholder or wildcard scope like 'feat(*):' or 'feat(misc):'. When no meaningful area applies, omit the scope entirely and write a plain 'feat:'. Got: \"$title\"")
      elif ! printf '%s' "$title" | grep -qE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9./-]+(,[a-z0-9./-]+)*\))?!?: .+'; then
        reasons+=("Title must follow Conventional Commits with optional scope, e.g. 'feat(scope): summary'. An optional Notion ticket id may be appended as a suffix. Got: \"$title\"")
      fi

      # Called once into a variable, not twice: one command, one config read.
      require_scope=$(scope_rule)
      if [ "$require_scope" = "true" ] && ! has_scope "$title"; then
        reasons+=("This repo requires a scope on PR titles. Write 'feat(scope): summary'. Got: \"$title\"")
      elif [ "$require_scope" = "false" ] && has_scope "$title"; then
        reasons+=("This repo does not use scopes on PR titles. Write 'feat: summary'. Got: \"$title\"")
      fi
    fi

    if printf '%s' "$cmd" | grep -qiE 'generated with|co-authored-by|🤖'; then
      reasons+=("PR must NOT contain a generated-by footer (no 'Generated with', 'Co-Authored-By', or robot emoji).")
    fi

    if [ ${#reasons[@]} -gt 0 ]; then
      deny "$(join_reasons "${reasons[@]}") Invoke the soong manage-pr skill, which defines these conventions, to fix the title and description, then retry."
    fi

    advise "Creating or editing a PR. Follow the soong manage-pr skill for the title format and description style, and write the PR record it defines. Invoke it now if it is not already loaded."
    ;;
esac

# Branch 2: comment-posting commands, in two arms.
#
# Arm 1 -- gh pr comment / gh pr review -- matches unconditionally. Those take
# -b/--body/--body-file, not gh api's field flags, so gating them on a field-flag
# filter would drop every invocation.
#
# Arm 2 -- gh api to a comments/replies path -- matches only with a body flag or
# an explicit write method, sparing the read-only listing calls the feedback walk
# makes routinely. A gh api call without one falls through to branch 3.
is_comment_cmd=0
case "$cmd" in
  *"gh pr comment"*|*"gh pr review"*)
    is_comment_cmd=1
    ;;
  *"gh api"*comments*|*"gh api"*replies*)
    if printf '%s' "$cmd" | grep -qE '(-f|-F|--field|--raw-field)[[:space:]=]*body=|--method[[:space:]]+POST|-X[[:space:]]+POST'; then
      is_comment_cmd=1
    fi
    ;;
esac

if [ "$is_comment_cmd" -eq 1 ]; then
  body=$(body_lines "$cmd")

  if printf '%s' "$body" | grep -qiE "$SIG"; then
    deny "Do not sign a PR comment with an attribution tag such as 'Addressed by Claude Code'. State what changed and link the commit instead. See the soong manage-pr skill's feedback mode."
  fi

  if printf '%s' "$body" | grep -qiE "$TRAILER|$GENWITH"; then
    deny "PR comment must NOT contain a generated-by footer (no 'Generated with', 'Co-Authored-By', or a bare robot emoji). See the soong manage-pr skill's feedback mode."
  fi

  advise "Posting a PR comment. Follow the soong manage-pr skill's feedback mode. Show the user the reply and get an explicit go-ahead before posting, and never sign a reply with an attribution tag."
fi

# Branch 3: everything else.
exit 0
