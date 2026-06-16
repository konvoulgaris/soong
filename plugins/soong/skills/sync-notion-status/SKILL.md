---
name: sync-notion-status
description: Use to reconcile Notion card status against real PR and code state. Always runs interactively, confirming every task and roadmap item before writing. Scans the cards shown by configured Notion roadmap views (or a single page passed as an argument), applying each view's filters so only those cards are touched, derives each task's status from the pull requests linked on its page via gh, advances status forward-only, and syncs the card description through write-notion-content. Rolls task state up to roadmap items. Triggers on "sync notion status", "reconcile the notion board", "update task statuses from PRs", "run the notion status routine".
---

# sync-notion-status

Reconcile Notion card status with what the pull requests and code actually show.
This skill reads PR state and writes status and descriptions to Notion. It never
touches code, tests, or verification.

## What it does

- With no argument, scans every configured roadmap view and the child tasks of the
  roadmap items that view shows. The view's filters and sort constrain the scan: only
  the cards the view actually displays are touched.
- With a page URL or ID argument, acts only on that one task or roadmap item.
- For a task: derives status from the PRs linked on its page, advances the status
  forward-only, and syncs the card description from the PRs.
- For a roadmap item: rolls status and description up from its child tasks, then
  confirms with the user before writing.

## What it does NOT do

- Never writes or edits code, tests, or verification steps.
- Never moves a status backward, and never overwrites a status it does not recognize.
- Never applies a status whose option does not exist in that database.
- Never invents a Notion card, database, or PR link.

## Always interactive

This skill always runs interactively. Both tasks and roadmap items are presented to
the user for confirmation before any write: each page's proposed status change and
proposed description are shown, and the user confirms, edits, or skips. Nothing is
written to Notion without confirmation. There is no unattended or comment-and-queue
mode; do not schedule this skill to run headless.

## Defer prose to write-notion-content

Before writing any prose to Notion, invoke the `write-notion-content` skill and apply
its rules to that text: match the page template, few words, lists over prose, one
sentence where possible, no em-dashes. This covers both prose write points: a task's
description and a roadmap item's description. Invoke it every time, not once per run.

Status fields are set directly via the Notion MCP; only the prose defers there.

## Configuration

### Location

`${XDG_STATE_HOME:-$HOME/.local/state}/soong/notion-databases.json`, created and
merged idempotently, the same approach `manage-pr` uses for `pr-records.json`. The
file is never committed.

### Required input

Only the roadmap *view* link (a saved-view URL). The user never supplies a tasks
database; it is resolved from the roadmap items' relation (see Discovery). Everything
else is derived from Notion schemas, not asked.

A roadmap view link is the durable anchor because it carries filters and sort: the
skill scans only the cards that view shows, not the whole underlying database.

### Shape

The roadmap view link is the durable anchor. Everything derived, including the
resolved database and the captured view filter/sort, is stored under a refreshable
`derived` cache.

```json
{
  "roadmaps": [
    {
      "roadmapView": "<roadmap-view-url>",
      "derived": {
        "roadmapDb": "<roadmap-db-id>",
        "viewFilter": { "and": [] },
        "viewSort": [],
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

`roadmapDb` is the database the view points at. `viewFilter` and `viewSort` are the
view's filter and sort definitions, captured at derivation and applied as query
criteria when scanning so only the cards the view shows are reconciled. A status map's
left-hand keys are the fixed logical states. Its right-hand values are that database's
actual option names. A logical state omitted from a map means the database has no such
option, so this skill never targets that state for that database.

### Reading the config

```bash
file="${XDG_STATE_HOME:-$HOME/.local/state}/soong/notion-databases.json"
jq -r '.roadmaps[].roadmapView' "$file"
```

Detect missing or empty config:

```bash
file="${XDG_STATE_HOME:-$HOME/.local/state}/soong/notion-databases.json"
if [ ! -f "$file" ] || [ "$(jq '.roadmaps | length' "$file" 2>/dev/null || echo 0)" = "0" ]; then
  echo "needs setup"
fi
```

### Writing (upsert one roadmap's derived cache, idempotent)

The caller sets `$roadmapView` (the anchor string) and `$derived` (a JSON object
string) before running this block.

```bash
dir="${XDG_STATE_HOME:-$HOME/.local/state}/soong"; file="$dir/notion-databases.json"
mkdir -p "$dir"; [ -f "$file" ] || echo '{"roadmaps":[]}' > "$file"
tmp="$(mktemp)"
jq --arg r "$roadmapView" --argjson d "$derived" '.roadmaps |= ( map(select(.roadmapView != $r)) + [{roadmapView: $r, derived: $d}] )' "$file" > "$tmp" && mv "$tmp" "$file"
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

- Current status's logical state is unrecognized (`rank` = -1, not in the map) ->
  hold. Never overwrite a status the map does not cover.
- Derived rank greater than current rank -> advance (write the derived status).
- Derived rank equal to or less than current -> hold (leave untouched).

A held page is reported as `unchanged` or `skipped`; the description sync still runs
where the task flow says it should.

## Discovery and self-healing

### Discovery (from the roadmap view link)

Use the Notion MCP to fetch schemas; never guess property names.

1. Resolve the roadmap view link to its underlying database and capture the view's
   filter and sort. Record the database id as `roadmapDb` and the filter/sort
   definitions as `viewFilter`/`viewSort`. A view with no filter records an empty
   filter, meaning the scan covers the whole database. If the MCP cannot expose the
   view's filter, see Ambiguity.
2. Fetch the roadmap database schema. Its relation property names the target
   collection; that target is the tasks database. Record the relation property and the
   resolved `tasksDb`. The tasks database is always resolved this way, never supplied.
3. From the tasks schema, find the PR property: a URL or rich-text property whose
   name is `PR` or `PRs`, or any case- and separator-insensitive form of "pull
   request" (`Pull Request`, `Pull Requests`, `pull-request`, `pullrequest`):

   ```bash
   grep -iE '^(pr|prs|pull[ _-]?request|pull[ _-]?requests)$'
   ```

4. The status property for each database is its `status`-type property, or a `select`
   named `Status`.
5. Build each status map by reading the database's real status options and matching
   each option name to a logical state by name (e.g. `Backlog`->`backlog`,
   `In Review`->`inReview`, `Ready for QA`/`Ready to Deploy`->`readyToDeploy`).
6. Persist the result under `derived` with a `derivedAt` timestamp using the upsert
   snippet in Configuration.

### Ambiguity

When derivation has a single clear answer, proceed silently. When a piece is
ambiguous (the view filter cannot be resolved, two or more candidate PR properties, or
a status option that maps to no logical state), ask the user for that specific piece,
then continue.

### Self-healing

At run time, validate `derived` against the live schemas and the live view. If the
view's filter or sort changed, the relation is gone, the PR property is missing, or a
needed status can no longer be resolved against the current options, re-run discovery
from the stored roadmap view link, refresh `derived`, and continue. The roadmap view
link is the only durable anchor; everything under `derived` is disposable.

### Inline setup

If the config is missing or empty, or the roadmap in scope is not configured, run
setup inline: ask the user for the roadmap view link, run discovery, write the entry,
and proceed. Offer to configure another roadmap.

## Task reconciliation flow

Task scope follows the roadmap view: only the tasks belonging to the roadmap items the
view shows are in scope. Reconcile those tasks. For each task page in scope:

### Read the linked PRs

Read the PR property. For each PR URL, fetch its state with `gh` (no local checkout):

```bash
gh pr view "$url" --json state,isDraft,mergedAt,title,body,files
```

Treat each PR as: `merged` (has `mergedAt`), `ready` (open, not draft), `draft`
(open, draft), or `closed` (closed without merge). A URL `gh` cannot resolve (deleted
or no access) is ignored for state and flagged; derive from the rest.

The description sync (below) needs the diff too; fetch it per PR with
`gh pr diff "$url"`.

### Derive the logical state

| Condition on the task page                                         | Derived state   |
| ------------------------------------------------------------------ | --------------- |
| No PRs in the PR property, and no technical detail on the page     | `backlog`       |
| No PRs, but technical detail present                               | `inAnalysis`    |
| Has PR(s), and every linked PR is merged                           | `readyToDeploy` |
| Has PR(s), at least one open and non-draft                         | `inReview`      |
| Has PR(s), but only drafts (none merged, none ready)               | `inDevelopment` |

Highest signal wins: a task reaches `readyToDeploy` only when every linked PR is
merged. Otherwise the most-advanced in-flight signal applies, where merged is
terminal and not ranked as in-flight (a ready-for-review PR beats a draft). A
closed-unmerged PR contributes nothing. When no in-flight PR remains and not every PR
is merged, the task falls to `inDevelopment`.

Technical-detail test for the `inAnalysis` rule (either signal qualifies): if the
page has a designated technical section (a heading such as `Technical`,
`Implementation`, or `Analysis`), non-empty content there counts. Otherwise judge the
page body. Implementation detail (architecture, APIs, data models, technical
approach) counts; purely business or product framing (goals, value, user stories)
does not, and the page stays `backlog`.

### Apply the state (forward-only, availability-gated)

1. Resolve the derived state's option name from `tasksStatusMap`. If the logical
   state is not mapped (no such option in this database), do not change status; flag
   it.
2. Read the page's current status, reverse-map it to a logical state, and apply the
   Forward-only comparison. Advance only when the derived rank is greater; otherwise
   hold and report `unchanged`/`skipped`. If the current status cannot be reverse-mapped
   (unrecognized option), hold and report `skipped`.
3. Description sync runs whenever the task has PRs, regardless of whether status
   moved. From each PR's title, body, changed files, and diff, synthesize one
   high-level architecture-style description across them, invoking `write-notion-content`
   for the prose. No tests or verification text. A task with no PRs gets no
   description write. The description is re-synthesized on every run by design;
   change-detection caching is a deliberate non-goal unless requested.
4. Before writing, present the task's proposed status (current -> derived) and proposed
   description and ask the user to confirm, edit, or skip. This skill always runs
   interactively (see Always interactive); nothing is written without confirmation.

## Roadmap roll-up flow

A roadmap item has no PRs of its own; its state and description roll up from its child
tasks. The roadmap items in scope are exactly those the configured view shows (its
filter and sort applied). Reconcile the children first (the task flow above), then
compute the roadmap item from their post-update states. Enumerate children via the
relation property.

### Derive roadmap status

| Children's states                                       | Roadmap state   |
| ------------------------------------------------------- | --------------- |
| All children `readyToDeploy`                            | `readyToDeploy` |
| Any child `inReview` or `inDevelopment`                 | `inDevelopment` |
| No in-flight child and not all `readyToDeploy`          | `backlog`       |

Rows are evaluated top-down; the first matching row wins. Row 3 is the catch-all floor
(it covers all children `backlog`/`inAnalysis` as well as mixes of `readyToDeploy` with
not-yet-started children, since neither is in-flight). A roadmap item with no child
tasks matches no row and is left untouched (no-op, reported as unchanged). The same
forward-only and availability-gate rules apply: only advance, and only if the option
exists in the roadmap database.

### Derive roadmap description

Synthesize a high-level summary across the children's PRs and changes, the roadmap
analogue of `sync-pr-to-notion`. Architecture-level, no tests or verification; invoke
`write-notion-content` for the prose.

### Interactive checkpoint

After the child tasks are computed, present the roadmap item's proposed status
(current -> derived) and proposed description, and ask the user to confirm, edit, or
skip before writing. The user owns the final roadmap narrative. This skill always runs
interactively (see Always interactive) and never writes a roadmap page without
confirmation.

## Run flow

1. Load config. If missing, or the scope's roadmap is not configured, run inline
   setup and discovery.
2. Resolve scope. A page argument narrows to that task or roadmap item. No argument
   scans every configured roadmap view and the children of the roadmap items that view
   shows. The view's filter and sort constrain the scan.
3. Validate and refresh `derived` against the live schemas and view; self-heal from
   the roadmap view anchor if stale.
4. Reconcile tasks first: per task, derive state, confirm with the user, then write
   status forward-only and sync description if PRs.
5. Reconcile roadmap items: roll up children, present, and confirm before writing.
6. Report.

## Output

Print a terminal summary, one line per page: `current -> new` status (or `unchanged` /
`skipped`), description synced yes/no, and a flags list covering:

- regressions skipped (derived state behind current),
- unmapped logical states (database has no matching option),
- ambiguous properties left unresolved,
- unresolvable PR URLs,
- pages the user chose to skip at the confirmation checkpoint.

## Arguments

Optional argument: a page or database URL/ID that narrows scope to a single task or
roadmap item. With no argument, scan every configured roadmap view.

## Rules

- Always interactive: confirm every task and roadmap item with the user before writing.
- Scans only the cards the configured roadmap view shows; never the whole database.
- Resolves the tasks database from roadmap relations; never asks for it.
- Never edits code, tests, or verification.
- Never regresses a status, and never overwrites an unrecognized status.
- Never targets a status option that does not exist in the database.
- Never invents a card, database, or PR link.
- Invoke `write-notion-content` for all Notion prose (task and roadmap descriptions).
