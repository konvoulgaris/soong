---
name: sync-pr-to-notion
description: Use when asked to sync a branch's changes into its linked Notion card, or to update the Notion ticket for a PR. Looks up the card from the PR record written by manage-pr (keyed by project and branch), asks the user for the card if none is recorded, then writes a high-level architecture-style description of the branch's changes to the card via the write-notion-content skill. Never edits code, tests, or verification steps. Triggers on "sync the PR to notion", "update the notion card for this branch", "describe these changes on notion".
---

# sync-pr-to-notion

Update the Notion card linked to the current branch with a high-level description of
what the branch changes. This skill describes work; it does not do work.

## What it does NOT do

- **Never write or edit code.** This skill only reads the diff and writes prose to Notion.
- **Never describe tests, test plans, or how to verify the change.** Skip CI, QA, and
  "how to test" entirely. The Notion card is for the *what* and *why*, not the *how to check*.
- **Never invent a Notion card.** If none is found, ask the user.

## Steps

1. **Resolve the branch.** `git rev-parse --abbrev-ref HEAD` and the project name, taken
   from the **common** git dir (see step 2). Never use `--show-toplevel`: inside a linked
   worktree it returns the worktree directory, so the lookup would miss the record that
   `manage-pr` wrote under the repo name.

2. **Look up the linked card** in the PR record `manage-pr` wrote — no `gh` CLI needed:

   ```bash
   file="${XDG_STATE_HOME:-$HOME/.local/state}/soong/pr-records.json"
   common="$(git rev-parse --path-format=absolute --git-common-dir)"  # main .git in worktrees too
   top="${common%/.git}"; top="${top%/}"; project="${top##*/}"
   branch="$(git rev-parse --abbrev-ref HEAD)"
   jq -r --arg p "$project" --arg b "$branch" '.[$p][$b].notionCard // empty' "$file"
   ```

3. **If no card** (empty output, missing file, or `null`): ask the user to specify the
   Notion card, then write a record for this branch so future runs find it (same shape
   and merge approach as the "PR record" section in the `manage-pr` skill's
   `reference/pr/compose.md`). Then proceed.

4. **Read the changes at a high level.** Diff the branch against its base locally:

   ```bash
   git log --oneline <base>..HEAD
   git diff <base>...HEAD
   ```

   Read for *intent and structure*, not line detail.

5. **Describe the changes like an architecture design.** Summarize the shape of the
   change: which components/modules/boundaries are affected, what new behavior or
   contracts are introduced, what was removed or restructured, and why. Stay at the
   design level — no code, no test/verification notes.

6. **Write to the card using the `write-notion-content` skill.** Follow that skill's
   style rules to its best ability: match the card's existing template, few words,
   lists over prose, one sentence where possible, no em-dashes. Use the Notion MCP to
   apply the content to the resolved card.

## Rules

- Describe, never implement. No code changes of any kind.
- High-level / architecture framing only — components, contracts, boundaries, rationale.
- Never mention tests or how to verify.
- Resolve the card from the PR record; ask the user only if it is missing, and persist
  it once given.
- Defer all Notion writing style to `write-notion-content`.
