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

### Forward-only comparison

Map the page's current status option back to a logical state via the relevant status
map (reverse lookup), then compare ranks on the ordering above:

```bash
rank() {
  case "$1" in
    backlog) echo 0;; inAnalysis) echo 1;; inDevelopment) echo 2;;
    inReview) echo 3;; readyToDeploy) echo 4;; *) echo -1;;
  esac
}
```

- Current status's logical state is unrecognized (`rank` = -1, not in the map) →
  hold. Never overwrite a status the map does not cover.
- Derived rank greater than current rank → advance (write the derived status).
- Derived rank equal to or less than current → hold (leave untouched).

A held page is reported as `unchanged` or `skipped`; the description sync still runs
where the task flow says it should.

## Discovery and self-healing

### Discovery (from the roadmap link)

Use the Notion MCP to fetch schemas; never guess property names.

1. Fetch the roadmap database schema. Its relation property names the target
   collection; that target is the tasks database. If a tasks database was supplied
   explicitly, use it and record the relation property that points at it.
2. From the tasks schema, find the PR property: a URL or rich-text property whose
   name is `PR` or `PRs`, or any case- and separator-insensitive form of "pull
   request" (`Pull Request`, `Pull Requests`, `pull-request`, `pullrequest`):

   ```bash
   grep -iE '^(pr|prs|pull[ _-]?request|pull[ _-]?requests)$'
   ```

3. The status property for each database is its `status`-type property, or a `select`
   named `Status`.
4. Build each status map by reading the database's real status options and matching
   each option name to a logical state by name (e.g. `Backlog`→`backlog`,
   `In Review`→`inReview`, `Ready for QA`/`Ready to Deploy`→`readyToDeploy`).
5. Persist the result under `derived` with a `derivedAt` timestamp using the upsert
   snippet in Configuration.

### Ambiguity

When derivation has a single clear answer, proceed silently. When a piece is
ambiguous (two or more candidate PR properties, or a status option that maps to no
logical state):

- running interactively: ask the user for that specific piece, then continue;
- running unattended: skip that database or that single state, and record it in the
  run report flags.

### Self-healing

At run time, validate `derived` against the live schemas. If the relation is gone,
the PR property is missing, or a needed status can no longer be resolved against the
current options, re-run discovery from the stored roadmap link, refresh `derived`,
and continue. The roadmap link is the only durable anchor; everything under `derived`
is disposable.

### Inline setup

If the config is missing or empty, or the roadmap in scope is not configured, run
setup inline: ask the user for the roadmap database (and optionally the tasks
database), run discovery, write the entry, and proceed. Offer to configure another
roadmap.

### First-ever unattended run with no config

If there is no usable config and the run cannot prompt (scheduled or headless), exit
cleanly with a message asking for one interactive run to configure. Never block.
Subsequent unattended runs work normally.
