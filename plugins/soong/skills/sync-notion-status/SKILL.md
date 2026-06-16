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

## Configuration

### Location

`${XDG_STATE_HOME:-$HOME/.local/state}/soong/notion-databases.json`, created and
merged idempotently, the same approach `manage-pr` uses for `pr-records.json`. The
file is never committed.

### Required input

Only the roadmap database (URL or ID). The tasks database is optional: if the user
does not supply it, discover it (see Discovery). Everything else is derived from
Notion schemas, not asked.

### Shape

The roadmap link is the durable anchor. Everything derived is stored under a
refreshable `derived` cache.

```json
{
  "roadmaps": [
    {
      "roadmap": "<roadmap-db-id-or-url>",
      "derived": {
        "tasksDb": "<tasks-db-id>",
        "tasksRelationProperty": "Tasks",
        "roadmapStatusProperty": "Status",
        "tasksStatusProperty": "Status",
        "prProperty": "PR",
        "roadmapStatusMap": {"backlog": "Backlog", "inDevelopment": "In Dev", "readyToDeploy": "Ready for QA"},
        "tasksStatusMap": {"backlog": "Backlog", "inAnalysis": "In Analysis", "inDevelopment": "In Dev", "inReview": "In Review", "readyToDeploy": "Ready for QA"},
        "derivedAt": "<iso-8601>"
      }
    }
  ]
}
```

A status map's left-hand keys are the fixed logical states. Its right-hand values are
that database's actual option names. A logical state omitted from a map means the
database has no such option, so this skill never targets that state for that database.

### Reading the config

```bash
file="${XDG_STATE_HOME:-$HOME/.local/state}/soong/notion-databases.json"
jq -r '.roadmaps[].roadmap' "$file"
```

Detect missing or empty config:

```bash
file="${XDG_STATE_HOME:-$HOME/.local/state}/soong/notion-databases.json"
if [ ! -f "$file" ] || [ "$(jq '.roadmaps | length' "$file" 2>/dev/null || echo 0)" = "0" ]; then
  echo "needs setup"
fi
```

### Writing (upsert one roadmap's derived cache, idempotent)

The caller sets `$roadmap` (the anchor string) and `$derived` (a JSON object string)
before running this block.

```bash
dir="${XDG_STATE_HOME:-$HOME/.local/state}/soong"; file="$dir/notion-databases.json"
mkdir -p "$dir"; [ -f "$file" ] || echo '{"roadmaps":[]}' > "$file"
tmp="$(mktemp)"
jq --arg r "$roadmap" --argjson d "$derived" '.roadmaps |= ( map(select(.roadmap != $r)) + [{roadmap: $r, derived: $d}] )' "$file" > "$tmp" && mv "$tmp" "$file"
```

### Logical states

Fixed. They are the left-hand side of every status map and the ordering for
forward-only comparison:

```
backlog < inAnalysis < inDevelopment < inReview < readyToDeploy
```

`inReview` is a task-only rung; roadmap items use `inDevelopment` as their single
in-flight bucket (see Roadmap roll-up flow).
