---
name: manage-pr
description: Use for any work on a pull request — writing or rewriting its title and description when creating or editing a PR, and responding to reviewers on your own open PR. Enforces the Conventional-Commits-with-scope title format, an optional Notion ticket id suffix, and a simple-prose description style. Runs the polish skill on the branch before opening or editing a PR. Walks unresolved review threads one-by-one with the user, then posts all replies in one batch after approval. Forbids generated-by footers and Claude attribution tags on both. Also persists a project/branch -> notion card + last commit record outside the repo for later querying. Triggers on "open a PR", "create a pull request", "write the PR title/description", "address the PR feedback", "reply to the reviewers", "go through the review comments", "respond to the PR comments", or any `gh pr create` / `gh pr edit` / `gh pr comment`.
---

# manage-pr

Everything that touches a pull request: composing its title and description, and
replying to reviewers on it. The plugin's PR-guard hook checks both, so getting
these conventions right is what lets the `gh` command through.

## Which mode

Read the reference file for the job at hand. Do not read both.

| Intent | Read |
| --- | --- |
| Open or create a PR, edit a title or description, `gh pr create`, `gh pr edit` | `reference/pr/compose.md` |
| Reply to reviewers, address review comments, walk threads | `reference/pr/feedback.md` |

## Arguments

Pass any argument string through to the reference file unchanged. The router does
not interpret it. `--non-interactive` is meaningful only in compose mode and is
documented there.

## Shared rules

These apply in both modes.

- **Never add a generated-by footer.** No `Generated with ...`, no
  `Co-Authored-By: ...`, no 🤖 robot emoji. This holds for a PR title, a PR body,
  and a review reply alike.
- **Never sign anything with an attribution tag** such as "Addressed by Claude
  Code". The hook denies these. Do not reword to slip past it.
- **Never post a comment to GitHub without showing the user what will be posted
  and getting an explicit go-ahead.**
- **Never guess a Notion ticket id.** Resolve it via the Notion MCP or omit it.
- **Polish before you compose.** Compose mode reviews the branch before it
  opens a pull request. `reference/pr/compose.md` step 0 holds the rule.
  Feedback mode never polishes.
- **A step that says "do not ask" has already granted the authorization.**
  These skills state where a decision was made. Asking anyway is not caution: it
  re-opens a settled decision, and it stalls a caller such as `develop` that runs
  the whole chain with nobody at the keyboard. Announce what you are doing and do
  it. This does not license the reverse — a step that says to ask still asks.

If the PR-guard hook denies a command, read its reason and do what it says: fix
the title or body, or run the skill it names. Do not bypass the hook.
