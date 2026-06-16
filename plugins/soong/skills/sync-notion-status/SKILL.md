---
name: sync-notion-status
description: Use to reconcile Notion card status against real PR and code state, on demand or as an unattended routine. Scans configured Notion roadmap databases (or a single page passed as an argument), derives each task's status from the pull requests linked on its page via gh, advances status forward-only, and syncs the card description through write-notion-content. Rolls task state up to roadmap items, confirming interactively or queuing a Notion comment when unattended. Triggers on "sync notion status", "reconcile the notion board", "update task statuses from PRs", "run the notion status routine".
---

# sync-notion-status

Reconcile Notion card status with what the pull requests and code actually show.
This skill reads PR state and writes status and descriptions to Notion. It never
touches code, tests, or verification.

## What it does

- With no argument, scans every configured roadmap database and its child tasks.
- With a page URL or ID argument, acts only on that one task or roadmap item.
- For a task: derives status from the PRs linked on its page, advances the status
  forward-only, and syncs the card description from the PRs.
- For a roadmap item: rolls status and description up from its child tasks, then
  confirms with the user (interactive) or leaves a Notion comment (unattended).

## What it does NOT do

- Never writes or edits code, tests, or verification steps.
- Never moves a status backward, and never overwrites a status it does not recognize.
- Never applies a status whose option does not exist in that database.
- Never invents a Notion card, database, or PR link.

## Defer prose to write-notion-content

All description text written to Notion follows the `write-notion-content` skill:
match the page template, few words, lists over prose, one sentence where possible,
no em-dashes. Status fields are set directly via the Notion MCP; only the prose
defers there.
