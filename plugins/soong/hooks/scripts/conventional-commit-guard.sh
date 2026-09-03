#!/usr/bin/env bash
#
# Checks the subjects git and gh are about to write: PR titles, commit subjects,
# and PR comment bodies.
#
# Named for the Conventional Commits rules, which are the bulk of it -- type,
# optional scope, and the repo's own require-scope setting where one is
# configured. It also carries one rule that is not part of that standard: PR
# titles, bodies, and comments must not end in a generated-by footer or an
# attribution tag. That rule lives here because this is the hook that already
# sees those strings, not because it belongs to the same standard. Commit
# subjects are exempt from it, since this project's instructions require a
# co-authorship trailer on commits.
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

TYPES='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'

# The Conventional Commits rules, in one place for both the PR-title branch and
# the commit-subject branch. They were duplicated verbatim, and the commit right
# before this one widened the scope pattern to allow comma-separated scopes -- in
# one of the two copies is exactly how that goes wrong, since nothing would have
# kept them in sync.
#
# Prints one reason per line and returns 1 when the subject is bad, prints nothing
# and returns 0 when it is fine. The caller supplies the noun for the message, so
# a PR title and a commit subject still read as themselves. The generated-by
# footer rule is deliberately NOT here: the PR branches apply it and the commit
# branch must not, because this project requires a co-authorship trailer on
# commits.
# The plural is passed in rather than derived from the singular: lowercasing
# "PR title" to build "pr titles" mangles the acronym, and a two-word argument is
# cheaper than a rule for which nouns survive tr.
subject_reasons() { # subject_reasons <subject> <noun> <plural> <require_scope>
  local subj="$1" noun="$2" plural="$3" rule="$4"

  if printf '%s' "$subj" | grep -qiE "^($TYPES)\((\*|misc|placeholder|tbd|na|n/a)\)"; then
    echo "Do not use a placeholder or wildcard scope like 'feat(*):' or 'feat(misc):'. When no meaningful area applies, omit the scope entirely and write a plain 'feat:'. Got: \"$subj\""
  elif ! printf '%s' "$subj" | grep -qE "^($TYPES)(\([a-z0-9./-]+(,[a-z0-9./-]+)*\))?!?: .+"; then
    echo "$noun must follow Conventional Commits with optional scope, e.g. 'feat(scope): summary'. Got: \"$subj\""
  fi

  if [ "$rule" = "true" ] && ! has_scope "$subj"; then
    echo "This repo requires a scope on $plural. Write 'feat(scope): summary'. Got: \"$subj\""
  elif [ "$rule" = "false" ] && has_scope "$subj"; then
    echo "This repo does not use scopes on $plural. Write 'feat: summary'. Got: \"$subj\""
  fi
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

# Has the polish skill run on the current HEAD?
#
# The polish skill writes a `Polish-passes` trailer on the commit it makes, and
# manage-pr compose step 0 reads that trailer to decide whether to run polish
# before opening a pull request. That rule lived only in prose, which is exactly
# the kind of instruction an agent talks itself out of when the situation looks
# slightly off-spec. Checking it here turns it into a precondition: the `gh`
# call fails until polish has run, so there is nothing left to rationalise.
#
# Anchored on HEAD alone, not a range, matching the skill: a range would pass a
# branch that polished and then committed more work unreviewed, which is the
# stale case the check exists to catch.
#
# Fails open on everything -- an unborn HEAD, a non-repo cwd, a missing git.
# `git log -1 HEAD` exits 128 in a repo with no commits, and a guard that denies
# every `gh pr create` because it could not read a trailer is worse than one that
# quietly stops checking. Returns 1 (present, or unknowable) by default and 0
# only on a positive read of an absent trailer.
polish_missing() {
  command -v git >/dev/null 2>&1 || return 1
  local trailer
  trailer="$(git log -1 --format='%(trailers:key=Polish-passes,valueonly)' HEAD 2>/dev/null)" || return 1
  [ -z "$(printf '%s' "$trailer" | tr -d '[:space:]')" ]
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
      # scope_rule is called once into a variable, not per check: one command,
      # one config read.
      while IFS= read -r r; do
        [ -n "$r" ] && reasons+=("$r")
      done <<EOF
$(subject_reasons "$title" "PR title" "PR titles" "$(scope_rule)")
EOF
    fi

    if printf '%s' "$cmd" | grep -qiE 'generated with|co-authored-by|🤖'; then
      reasons+=("PR must NOT contain a generated-by footer (no 'Generated with', 'Co-Authored-By', or robot emoji).")
    fi

    # Everything above is a problem with the strings in this command, and the
    # tail below tells the reader to fix them. The polish precondition is not:
    # the command can be perfect and still be denied because the code behind it
    # was never reviewed. So it is collected separately, and carries its own
    # remedy -- told to "fix the title and description" over a correct title, a
    # reader edits something that was already right.
    #
    # Skipped when the command carries --no-polish, the same escape hatch
    # compose documents: the caller states the branch's code is not what this
    # pull request is about. `gh` rejects that as an unknown flag, so compose
    # appends it as a trailing shell comment -- `gh` never sees it, and this
    # hook, which reads the raw command string, does.
    polish_reason=""
    if ! printf '%s' "$cmd" | grep -qE -- '--no-polish' && polish_missing; then
      polish_reason="HEAD carries no 'Polish-passes' trailer, so the polish skill has not run on this code. Run the soong polish skill now -- it is unattended and needs no approval -- then retry. It rewrites code and commits by design; that is what the skill is for, and it does not need separate approval. Append '# --no-polish' only when the branch's code is not what this PR is about."
    fi

    if [ ${#reasons[@]} -gt 0 ]; then
      remedy="Invoke the soong manage-pr skill, which defines these conventions, to fix the title and description, then retry."
      [ -n "$polish_reason" ] && remedy="$remedy $polish_reason"
      deny "$(join_reasons "${reasons[@]}") $remedy"
    fi

    if [ -n "$polish_reason" ]; then
      deny "$polish_reason"
    fi

    advise "Creating or editing a PR. Follow the soong manage-pr skill for the title format and description style, and write the PR record it defines. Invoke it now if it is not already loaded."
    ;;
esac

# Branch 1.5: commit subjects. Gated entirely on the commits capability, so an
# unconfigured repo is untouched. Without that gate, installing this plugin would
# start denying `git commit -m "wip"` in every repo the user never set up, and
# commits are far higher-frequency than PR titles.
#
# The case is outside and the scope_rule call inside, not the other way round: a
# `require_scope=$(scope_rule)` at top level runs in a subshell, so the memo
# cache never reaches this branch and `ls` would pay for the config read anyway.
case "$cmd" in
  *"git commit"*)
    require_scope="$(scope_rule)"
    if [ -n "$require_scope" ]; then
      # Generated and reused subjects are exempt. git writes "fixup!"/"squash!"
      # itself and a later rebase absorbs them, and --amend with no -m reuses a
      # message that is not in this command. Denying either would break the
      # stacked-PR workflow develop builds.
      exempt=0
      printf '%s' "$cmd" | grep -qE -- '--(fixup|squash)(=|[[:space:]])' && exempt=1
      if printf '%s' "$cmd" | grep -qE -- '--amend' \
         && ! printf '%s' "$cmd" | grep -qE -- '(-m|--message)[[:space:]=]'; then
        exempt=1
      fi

      if [ "$exempt" -eq 0 ]; then
        # The first -m is the subject; later ones are body paragraphs.
        subject=$(printf '%s' "$cmd" \
          | grep -oE -- '(-m|--message)[ =]+("[^"]*"|'"'"'[^'"'"']*'"'"')' \
          | head -1 | sed -E 's/^(-m|--message)[ =]+//; s/^["'"'"']//; s/["'"'"']$//')

        if [ -n "$subject" ]; then
          creasons=()

          # Same rules as the PR title, from the same function. The footer check
          # the PR branch runs is absent here on purpose: this project requires a
          # co-authorship trailer on commits, so applying that rule would deny
          # what the project itself mandates.
          while IFS= read -r r; do
            [ -n "$r" ] && creasons+=("$r")
          done <<EOF
$(subject_reasons "$subject" "Commit subject" "commit subjects" "$require_scope")
EOF

          if [ ${#creasons[@]} -gt 0 ]; then
            deny "$(join_reasons "${creasons[@]}") Fix the commit subject and retry."
          fi
        fi
      fi

      # Outside the exempt guard on purpose. An exempted commit -- an amend, a
      # fixup, a message this hook cannot read -- still gets the reminder, because
      # the repo does have a convention and only this subject is unjudgeable.
      # Putting this inside the guard would make every exempt case silent.
      #
      # ponytail: -m only, and cwd only. A message in an editor, in -F <file>, or
      # piped via a heredoc is not in the command string, so it cannot be read and
      # must not be denied unread. And the project key comes from the cwd, so
      # `git -C /other/repo commit` is judged against this repo's rule rather than
      # the target's -- working that out means parsing -C and every cd in a
      # compound command, which is a shell interpreter. Upgrade path for both: a
      # per-repo commit-msg git hook, which brings its own install, upgrade, and
      # removal problems.
      advise "Commit subjects in this repo follow Conventional Commits, and the repo's scope rule is require_scope=$require_scope."
    fi
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
