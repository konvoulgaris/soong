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

Deleting that directory removes `address-pr-feedback` from the installed skill
roster. Anyone who invokes it by name loses it. The merged skill's frontmatter
description absorbs its trigger phrases, so intent-based invocation keeps
working; only the literal name goes away. This is intended, not a migration to
smooth over.

### Router: SKILL.md

The router is thin. It holds four things:

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

**Argument handling.** `merge/SKILL.md:52-56` invokes this skill with
`--non-interactive`. The router passes any argument string through to the leaf
unchanged and does not interpret it. `--non-interactive` is meaningful only in
compose mode and is documented there. A router that receives it dispatches to
`compose.md` as normal.

**Shared rules**, which apply in both modes:

- Never add a generated-by footer: no `Generated with ...`, no
  `Co-Authored-By: ...`, no robot emoji.
- Never sign a comment with an attribution tag such as "Addressed by Claude
  Code". The hook denies these; do not work around it.
- Never post a comment to GitHub without showing the user what will be posted
  and getting an explicit go-ahead.
- Never guess a Notion ticket id. Resolve it via the Notion MCP or omit it.

These live in the router so a model that reads only one leaf still has them.
That holds whenever the skill is invoked at all. It does not hold when the
skill is skipped, which the hook cannot prevent — see "Enforcement model".

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

Three changes:

**The approval gate.** The current skill says, per thread, "do not ask the user
whether to tighten or edit it" and then posts the batch with no approval step at
all. That combination means the user never sees the replies before they are
public. Add a single gate before the batch post: show every drafted reply
together, wait for one explicit go-ahead, then post. Showing them side by side
is also when tone inconsistencies across replies become visible.

**Reword the per-thread rule so it does not contradict that gate.** The current
text at `address-pr-feedback/SKILL.md:109-111` reads "Do not prompt the user to
tighten, edit, or sign off on it." Unscoped, that forbids the new batch gate.
Scope it explicitly to the per-thread walk: no sign-off is requested *on an
individual draft as it is written*; one sign-off is requested on the assembled
batch before posting. Both sentences must appear in the leaf, and the
per-thread one must say "per thread" or the leaf reads as self-contradictory.
The intent behind the original rule is preserved: no dozen rounds of "want me
to tighten this?".

**The attribution rule.** Spell out that a reply never carries an "Addressed by
Claude Code"-style tag, since this is the mode that posts comments.

### Hook: pr-guard.sh

One script. Branches are **mutually exclusive and ordered**: the first matching
branch emits its JSON and exits. A compound command such as
`gh pr edit 5 --body x && gh pr comment 5 -b y` matches branch 1 and stops
there. This is deliberate — a hook must emit at most one JSON object on stdout,
and two would be malformed. Comment-branch coverage of a compound command is
sacrificed to keep the output well-formed; compound PR commands are rare and
the model is advised toward the skill either way.

**Branch 1: `gh pr create` and `gh pr edit`.** Existing behaviour kept. The
title-format check and the generated-by-footer check stay as `deny`. When the
command is otherwise clean, emit `additionalContext` advising the skill. A
single hook response cannot usefully both deny and inject context, since a deny
already carries its reason string, so violations deny and clean commands
advise. Never both.

**Branch 2: comment-posting commands.** Matched in two arms, because the two
command families need different treatment:

- `gh pr comment` and `gh pr review` match unconditionally.
- `gh api` calls to `.../comments` or `.../replies` match only when they also
  carry a body flag (`-f body=`, `-F body=`, `--field body=`,
  `--raw-field body=`) or an explicit write method (`--method POST`,
  `-X POST`). A `gh api` call to those paths **without** one of those flags is
  not a branch-2 match and falls through to branch 3.

Arm 1 is unconditional even though bodyless forms exist (`gh pr review
--approve`, `gh pr review --list`). Those receive the branch-2 advisory telling
the model to confirm a reply that does not exist. That is harmless noise, and
the alternative — filtering arm 1 on body flags — is precisely the bug described
below.

The write-detection filter applies to the `gh api` arm **only**. Applying it to
all three families silently drops every `gh pr comment` and `gh pr review`
invocation, because those commands take `-b` / `--body` / `--body-file`, not
`gh api`'s field flags — none of them can satisfy a field-flag filter. The
filter exists solely to spare read-only `gh api repos/o/r/pulls/1/comments`
listing calls, which the feedback walk makes routinely, from drawing a
"confirm before posting" advisory that makes no sense for a read.

`gh pr comment --body-file` puts the reply text in a file, so no signature
appears in the command string and the deny check cannot see it. Such a command
matches branch 2 and receives the advisory, but the attribution check passes
vacuously. This is an accepted limitation of whole-command scanning; the skill
text is the only guard for file-sourced bodies.

Denies when the command matches either the attribution signature pattern or
the footer-trailer pattern, both case-insensitively.

Signature pattern, where `M` is the marker class
`[-*_~>—[:space:]🤖]*`:

```
^M(addressed|fixed|resolved|handled|generated|created|done)[[:space:]]+(by|with)[[:space:]]+claude([[:space:]]+code)?M[.!]?M$
```

Footer-trailer pattern, restoring the two checks branch 1 already makes. `M2` is
the marker class without the emoji, `[-*_~>—[:space:]]*`:

```
^[[:space:]]*co-authored-by:|^M2🤖M2$
```

Both alternatives are anchored. `co-authored-by:` is a trailer and anchors
naturally at line start. The bare emoji is anchored to a whole line for the same
reason the signature pattern is: unanchored, it denies any reply that merely
*mentions* the emoji, and this repo's review threads discuss a hook that greps
for it. `grep -qiE "generated with|co-authored-by|🤖"` — a literal quote of
`pr-guard.sh:22` — is a realistic reply here and must not be denied.

Anchoring costs nothing in coverage: `🤖 Addressed by Claude Code` is already
caught by the signature pattern, whose marker class includes the emoji. The
trailer alternative exists only for a bare emoji standing alone as a sign-off.

Note this makes branch 2 narrower than branch 1, which still greps `🤖`
unanchored (`pr-guard.sh:22`). That divergence is deliberate and left alone:
branch 1 scans PR titles and bodies, where a quoted grep pattern is far less
likely than in a review reply about this hook. Aligning branch 1 is out of
scope.

The signature pattern is **line-anchored**. That is what makes it a signature
check rather than a prose check. `grep -E` applies `^` and `$` per line, so the
phrase must stand alone on its own line.

The marker class is applied **symmetrically**, on both sides of the phrase.
Leading-only absorption lets the most likely sign-off format through:
`*Addressed by Claude Code*` in plain markdown italics passes a
leading-only pattern because of its closing `*`, as do `_..._` and a trailing
`🤖`. Mirroring costs nothing, since the pattern is anchored either way.

The class covers list and rule markers (`-`, `*`, `_`, `~`), blockquote (`>`),
em-dash (`—`), whitespace, and the robot emoji. HTML wrappers such as
`<sub>Addressed by Claude Code</sub>` are not covered and are accepted as a
miss; that is diminishing returns.

Anchoring is load-bearing, not decoration. An unanchored
`by[[:space:]]+claude[[:space:]]+code` denies ordinary sentences — "invoked by
Claude Code", "read by Claude Code", "performed by Claude Code hooks" — which is
exactly the vocabulary of PR review in this repo, a Claude Code plugin whose
review threads discuss hooks and skills that Claude Code executes. Unanchored
verbs also match across sentence boundaries, because `[[:space:]]` matches
newlines: `Done.\nBy Claude Code convention...` trips a bare `done ... by
claude`. Both failures were reproduced against the unanchored form before
anchoring was adopted.

Verified behaviour of the anchored, mirrored pattern:

| Body line | Result |
| --- | --- |
| `Addressed by Claude Code` | deny |
| `🤖 Addressed by Claude Code` | deny |
| `Fixed by Claude Code.` | deny |
| `  Resolved with Claude` | deny |
| `-- Generated by Claude Code` | deny |
| `*Addressed by Claude Code*` | deny |
| `_Addressed by Claude Code_` | deny |
| `-- Addressed by Claude Code --` | deny |
| `> Addressed by Claude Code` | deny |
| `Addressed by Claude Code 🤖` | deny |
| `— Addressed by Claude Code` | deny |
| `Handled by Claude` | deny |
| `Done. The hook is now invoked by Claude Code before every Bash call.` | pass |
| `Skill files are read by Claude Code at session start` | pass |
| `the check is performed by Claude Code hooks at PreToolUse` | pass |
| `That case is handled by Claude Code hooks already.` | pass |
| `Resolved with claude-flavoured tooling in mind, see docs.` | pass |
| `addressed in abc123` | pass |
| `this breaks under Claude Code 2.x` | pass |
| `Fixed the parser so it handles HEREDOCs.` | pass |

Trailer pattern:

| Body line | Result |
| --- | --- |
| `Co-Authored-By: Claude <noreply@anthropic.com>` | deny |
| `🤖` | deny |
| `-- 🤖` | deny |
| `The co-authored-by trailer is stripped by the hook.` | pass |
| `The 🤖 emoji is banned in PR bodies, see the shared rules.` | pass |
| `grep -qiE "generated with\|co-authored-by\|🤖"` | pass |
| `Added a test asserting 🤖 is rejected.` | pass |
| `Nice, the bot works 🤖` | pass |

A signature on its own line at the end of a multi-line body is caught;
`Done.` followed by a new line beginning `By Claude Code convention` is not.

A clean comment command gets `additionalContext`.

**Branch 3: everything else.** Exit silently.

**Body extraction.** The existing title parser handles `--title "x"` and
`-t 'x'` only. Reply bodies arrive as HEREDOCs
(`--body "$(cat <<'EOF' ... EOF)"`), which a flag-anchored `grep -oE` cannot
capture. The attribution check therefore scans the whole command string. This
is safe because the pattern is line-anchored and the HEREDOC's newlines survive
into the hook's `tool_input.command` — confirmed by feeding real hook JSON
through `jq -r '.tool_input.command'` and matching against it. Whole-command
scanning also matches the existing footer check, which already works this way.

**Reason joining.** The current script joins denial reasons with
`${reasons[*]}`, which uses a single space and runs two violations into one
unreadable sentence. `IFS='; '` does **not** fix this: `[*]` expansion uses only
the *first* character of `IFS`, producing `First.;Second.` with no space.
Verified. Join explicitly instead — a `printf '%s; '` loop over the array, or an
equivalent join that emits both characters.

`hooks.json` needs no new entry. The matcher is already `Bash` and the same
script handles the new branch.

**Advisory strings.** Verbatim, so two implementers write the same text.

Branch 1:

> Creating or editing a PR. Follow the soong manage-pr skill for the title
> format and description style, and write the PR record it defines. Invoke it
> now if it is not already loaded.

Branch 2:

> Posting a PR comment. Follow the soong manage-pr skill's feedback mode. Show
> the user the reply and get an explicit go-ahead before posting, and never sign
> a reply with an attribution tag.

### Enforcement model

The two mechanisms differ deliberately.

Skill invocation is **advisory**. A hook cannot observe whether a skill ran
without a session-marker file, and the in-repo precedent
(`notion-content-reminder.sh`) is advisory `additionalContext`. This does not
guarantee the skill is used; a model that ignores the reminder still creates the
PR and still skips the PR record. Gap 1 is mitigated, not closed.

Note that `notion-content-reminder.sh` fires on an MCP tool matcher, not a Bash
matcher. This change is the first use of `additionalContext` from a Bash-matched
hook in this repo. Confirm the field is honoured there during implementation; if
it is not, the advisory is a no-op and the branch-1 change should be dropped
rather than reworked.

Attribution tags are **denied**. The rule is a string check, so denying it costs
no state. It is not exhaustive: a determined rewording, an HTML-wrapped
signature, or a body passed via `--body-file` all slip through. The deny catches
the shapes a model actually produces, and the skill text carries the rule for
everything else.

The user-approval rule cannot be hook-enforced in either direction, because a
hook cannot see whether the user was asked. It lives in the skill text and is
reinforced by the branch-2 advisory.

## Verification

The hook is now three branches and several patterns, and every regex defect in
this document was found by running the pattern, not by reading it. Two of them
survived a careful review pass and were caught only when a test named the
command family explicitly. Implementation adds
`plugins/soong/hooks/scripts/pr-guard.test.sh`, a plain bash script beside the
hook that feeds JSON to `pr-guard.sh` on stdin and asserts on stdout. No
framework. It exits non-zero on the first failure and is run by hand.

Cases:

**Patterns.** Every row of both tables above, asserting deny or pass. A
multi-line body whose last line is a bare signature: deny. `Done.` followed by a
line starting `By Claude Code convention`: pass.

**Command matching.** One case per command family, named for the family, since
the absence of exactly these is what let the write-detection bug through:

- `gh pr comment 5 -b '<signature>'`: deny.
- `gh pr review 5 --comment -b '<signature>'`: deny.
- `gh api .../replies -f body='<signature>'`: deny.
- `gh pr comment 5 -b 'Fixed the parser.'`: advisory, no deny.
- `gh api repos/o/r/pulls/1/comments` with no body flag: no output at all.
- `gh api graphql -f query='...reviewThreads...'`: no output at all.

**Restored footer checks on branch 2.** `gh pr comment` with a
`Co-Authored-By:` trailer: deny. With a bare `🤖` on its own line: deny. With a
body quoting `pr-guard.sh`'s own grep pattern, emoji included: **pass** — the
regression test for the unanchored form. Prose mentioning the emoji mid-sentence
passes. The trailer table's prose rows exist because their absence is what let
the unanchored alternative through review.

**Plumbing.**

- A HEREDOC body fed through real hook JSON (`jq -r '.tool_input.command'`)
  rather than a bare string, so newline survival is actually exercised.
- Two simultaneous title violations, asserting the joined reason contains `; `
  with the space.
- A compound `gh pr edit ... && gh pr comment ...`, asserting exactly one JSON
  object on stdout **and** that it is branch 1's, confirming the ordering
  guarantee rather than just the count.
- Output of every branch parsing as valid JSON.

## Additional fixes

Found while reviewing the existing skills and hook:

- `pr-guard.sh` line 27 tells the model to invoke "the soong write-pr skill".
  No such skill exists. Point it at `manage-pr`. This defect is already recorded
  at `docs/superpowers/plans/2026-07-30-technical-content-skill-and-notion-reminder-hook.md:836`.
- `sync-pr-to-notion/SKILL.md:34` cross-references "the `manage-pr` skill's PR
  record section". The section moves; update the reference to name
  `reference/pr/compose.md`.
- Bump the minor version in `plugins/soong/.claude-plugin/plugin.json`
  (currently `0.4.0`). The merge plus new enforcement is a feature.

## Out of scope

- Session-marker files or any other stateful proof that a skill was invoked.
- Enforcing the title check when `--title` is not parseable from the command
  line.
- Comment-branch checks on compound commands whose first clause is a PR
  create/edit.
- Any change to `merge`, `rebase`, `write-notion-content`, or
  `manage-notion-page` beyond the `sync-pr-to-notion` cross-reference fix.
