# manage-pr consolidation

Date: 2026-08-02

## Problem

Two skills cover one workflow. `manage-pr` writes a PR title and description.
`address-pr-feedback` replies to reviewers on that same PR. A user working on a
pull request has to know which of the two to reach for, and the shared rules
(no generated-by footer, Conventional Commits) are duplicated across both.

Three enforcement gaps sit on top of that split:

1. Nothing reminds the model to use the skill before it runs `gh pr create`.
   The `pr-guard.sh` hook validates the title format, so a model that guesses a
   valid format bypasses the skill entirely and never writes the PR record that
   `sync-pr-to-notion` depends on.
2. Nothing prevents the model from posting a review reply signed with an
   "Addressed by Claude Code" attribution tag.
3. `address-pr-feedback` posts its batch of replies without asking the user to
   approve them. The user approves each *decision* during the walk but never
   sees the *replies* before they go public.

## Solution

Merge both skills into a single `manage-pr` skill using a router plus reference
files, and extend `pr-guard.sh` to cover comment-posting commands.

### File layout

```
plugins/soong/skills/manage-pr/
  SKILL.md                    # router + shared rules
  reference/pr/compose.md     # title, description, PR record
  reference/pr/feedback.md    # interactive review-thread walk
plugins/soong/hooks/scripts/
  pr-guard.sh                 # extended
```

`plugins/soong/skills/address-pr-feedback/` is deleted. Its content moves to
`reference/pr/feedback.md`, with the fixes described below.

### Router: SKILL.md

The router is thin. It holds three things:

**Frontmatter description.** Must cover both trigger sets, since one skill now
answers for both jobs. It combines the existing `manage-pr` triggers ("open a
PR", "create a pull request", "write the PR title/description", `gh pr create`,
`gh pr edit`) with the existing `address-pr-feedback` triggers ("address the PR
feedback", "reply to the reviewers", "go through the review comments", "respond
to the PR comments").

**Dispatch table.**

| Intent | Read |
| --- | --- |
| Open or create a PR, edit a title or description, `gh pr create`, `gh pr edit` | `reference/pr/compose.md` |
| Reply to reviewers, address review comments, walk threads | `reference/pr/feedback.md` |

**Shared rules**, which apply in both modes and are therefore always in context:

- Never add a generated-by footer: no `Generated with ...`, no
  `Co-Authored-By: ...`, no robot emoji.
- Never sign a comment with an attribution tag such as "Addressed by Claude
  Code". The hook denies these; do not work around it.
- Never post a comment to GitHub without showing the user what will be posted
  and getting an explicit go-ahead.
- Never guess a Notion ticket id. Resolve it via the Notion MCP or omit it.

Mode-specific detail stays in the reference files. A model that reads only one
leaf still has the shared rules, because the router is always read first.

### reference/pr/compose.md

Carries the current `manage-pr` body unchanged in substance: the Conventional
Commits title format, the optional Notion ticket suffix, the plain-prose
description style, the `--non-interactive` argument, the steps, and the PR
record written to
`${XDG_STATE_HOME:-$HOME/.local/state}/soong/pr-records.json`.

One addition: document that the hook's title check only fires when `--title` is
parseable from the command line. A HEREDOC title, or a `gh pr edit` that changes
only the body, passes the hook unchecked. The hook is a backstop, not a
substitute for writing a correct title.

### reference/pr/feedback.md

Carries the current `address-pr-feedback` body: resolve the PR, gather
unresolved threads via GraphQL, walk them one at a time with options and a
recommendation per thread, make agreed code changes before drafting the reply
that describes them, and post in one batch at the end.

Two changes:

**The approval gate.** The current skill says, per thread, "do not ask the user
whether to tighten or edit it" and then posts the batch with no approval step at
all. That combination means the user never sees the replies before they are
public. Keep the per-thread rule, which usefully prevents a dozen rounds of
"want me to tighten this?", and add a single gate before the batch post: show
every drafted reply together, wait for one explicit go-ahead, then post. Showing
them side by side is also when tone inconsistencies across replies become
visible.

**The attribution rule.** Spell out that a reply never carries a
"Addressed by Claude Code"-style tag, since this is the mode that posts
comments. The router states it; the leaf repeats it where it applies.

### Hook: pr-guard.sh

One script, three branches on the command string.

**Branch 1: `gh pr create` and `gh pr edit`.** Existing behaviour kept. The
title-format check and the generated-by-footer check stay as `deny`. New: when
the command is otherwise clean, emit `additionalContext` advising the
`manage-pr` skill. A single hook response cannot usefully both deny and inject
context, since a deny already carries its reason string, so violations deny and
clean commands advise. Never both.

**Branch 2: comment-posting commands.** Matches `gh api .../comments`,
`gh api .../replies`, `gh pr comment`, and `gh pr review`. Denies when the
command matches any attribution pattern, case-insensitively:

```
(addressed|fixed|resolved|handled|generated|done|created)[[:space:]]+(by|with)[[:space:]]+claude
by[[:space:]]+claude[[:space:]]+code
co-authored-by
🤖
```

These patterns target attribution phrasing specifically. A reply that says
"addressed in abc123" passes. A reply that discusses Claude Code as a subject
("this breaks under Claude Code 2.x") passes. Only the signature shape is
denied.

A clean comment command gets `additionalContext`: follow the `manage-pr`
feedback mode and confirm the reply with the user before posting.

**Branch 3: everything else.** Exit silently.

**Body extraction.** The existing title parser handles `--title "x"` and
`-t 'x'` only. Reply bodies in this workflow arrive as HEREDOCs
(`--body "$(cat <<'EOF' ... EOF)"`), which a flag-anchored `grep -oE` cannot
capture. The attribution check therefore scans the whole command string rather
than attempting to extract the body. The patterns are narrow enough that
whole-command scanning does not false-positive, and this matches the existing
footer check, which already scans the command wholesale.

`hooks.json` needs no new entry. The matcher is already `Bash` and the same
script handles the new branch.

### Enforcement model

The two enforcement mechanisms differ deliberately.

Skill invocation is **advisory**. A hook cannot observe whether a skill ran
without a session-marker file, and the in-repo precedent
(`notion-content-reminder.sh`) is advisory `additionalContext`. This does not
guarantee the skill is used; a model that ignores the reminder still creates the
PR and still skips the PR record.

Attribution tags are **denied**. The rule is a pure string check, so denying it
costs no state and has no false-negative risk.

The user-approval rule cannot be hook-enforced in either direction, because a
hook cannot see whether the user was asked. It lives in the skill text and is
reinforced by the advisory on the posting call.

## Additional fixes

Found while reviewing the existing skills and hook:

- `pr-guard.sh` line 27 tells the model to invoke "the soong write-pr skill".
  No such skill exists. Point it at `manage-pr`.
- `pr-guard.sh` joins multiple denial reasons with `${reasons[*]}`, which uses a
  single space. Two violations run together into one unreadable sentence. Join
  with `; ` instead.
- `sync-pr-to-notion` cross-references "the `manage-pr` skill's PR record
  section". The section moves to `reference/pr/compose.md`; update the
  reference to name the file.
- Bump the minor version in `plugins/soong/.claude-plugin/plugin.json`. The
  merge plus new enforcement is a feature.

## Out of scope

- Session-marker files or any other stateful proof that a skill was invoked.
- Enforcing the title check when `--title` is not parseable from the command
  line.
- Any change to `merge`, `rebase`, `write-notion-content`, or
  `manage-notion-page` beyond the `sync-pr-to-notion` cross-reference fix.
