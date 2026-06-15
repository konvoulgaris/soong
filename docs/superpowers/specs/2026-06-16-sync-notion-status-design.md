# sync-notion-status — Design

## Summary

`sync-notion-status` is a single self-contained soong skill that reconciles Notion
card status against real pull-request and code state. It runs interactively or
unattended (as a scheduled routine).

- With no argument, it scans every configured roadmap database and its child tasks.
- With a page URL or ID, it acts only on that one task or roadmap item.
- For tasks, it derives the correct status from the PRs linked on the page, then
  writes the status (forward-only) and syncs the card description.
- For roadmap items, it rolls the status and description up from the child tasks,
  then either confirms with the user (interactive) or queues the proposal as a
  Notion comment (unattended).

The skill is self-contained: it reads and writes Notion through the Notion MCP and
fetches PRs through `gh` directly. It defers only prose style to the
`write-notion-content` skill. It has no dependency on the Daisy plugin.

## Goals

- Keep Notion task status aligned with PR/code reality without a human driving it.
- Keep the card description aligned with what the PRs actually change.
- Roll task state up to the roadmap item, with a human checkpoint on the roadmap
  narrative.
- Require almost no setup: the user supplies a roadmap database link; the skill
  discovers everything else and self-heals when the schema drifts.

## Non-goals

- Never edits code, tests, or verification steps (same boundary as
  `sync-pr-to-notion`).
- Never moves a status backward, and never overwrites a status it does not
  recognize.
- Never applies a target status whose option does not exist in that database.
- Never invents a Notion card, database, or PR link.
- Does not replace the Daisy interactive driver skills (`drive-task`,
  `drive-roadmap-item`). This skill is the unattended reconciliation counterpart,
  not an interactive work-driver.

## Relationship to existing skills

- **`write-notion-content`** — used for all prose written to Notion (status is set
  directly via the MCP; only the description text defers here). The skill follows
  its rules: match the page template, few words, lists over prose, no em-dashes.
- **`sync-pr-to-notion`** — this skill reuses its *output style* (high-level,
  architecture-level description; no tests or verification text) but not its
  mechanics. `sync-pr-to-notion` resolves the card from `pr-records.json` by the
  local branch and diffs the branch locally; this skill instead starts from a
  Notion page, reads PR URLs off it, and fetches them through `gh` with no local
  checkout, so it works for arbitrary PRs and on headless runs.
- **`manage-pr`** — unrelated at run time, but its `pr-records.json` storage pattern
  (idempotent JSON under XDG state) is the model for this skill's config file.
- **Daisy** — intentionally not a dependency. The skill carries its own config and
  its own logical status model.

## Configuration

### Location

`${XDG_STATE_HOME:-$HOME/.local/state}/soong/notion-databases.json`, created and
merged idempotently, the same approach `manage-pr` uses for `pr-records.json`. The
file is never committed.

### Required input

Only the **roadmap database** (URL or ID). The tasks database is optional: if the
user does not supply it, the skill discovers it. Every other property and mapping is
derived by inspecting Notion schemas, not by interrogating the user.

### Shape

The roadmap link is the durable anchor. Everything the skill derives is stored under
a refreshable `derived` cache.

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
        "roadmapStatusMap": {
          "backlog": "Backlog",
          "inDevelopment": "In Dev",
          "readyToDeploy": "Ready for QA"
        },
        "tasksStatusMap": {
          "backlog": "Backlog",
          "inAnalysis": "In Analysis",
          "inDevelopment": "In Dev",
          "inReview": "In Review",
          "readyToDeploy": "Ready for QA"
        },
        "derivedAt": "<iso-8601>"
      }
    }
  ]
}
```

- A status map's left-hand keys are the fixed logical states. Its right-hand values
  are that database's actual option names.
- A logical state omitted from a map means the database has no such option, so the
  skill will never target that state for that database.

### Logical states

Fixed, used as the left-hand side of every status map and as the ordering for
forward-only comparison:

```
backlog < inAnalysis < inDevelopment < inReview < readyToDeploy
```

`inReview` is a task-only rung; roadmap items use `inDevelopment` as their single
in-flight bucket (see Roadmap roll-up).

## Discovery and self-healing

### Discovery (from the roadmap link)

1. Fetch the roadmap database schema. Its relation property names the target
   collection; that target is the **tasks database** (deterministic, since a Notion
   relation names its target). If a tasks database was supplied explicitly, use it
   and record the relation property that points at it.
2. From the tasks schema, find the **PR property**: a URL or rich-text property whose
   name matches `PR`, `PRs`, `Pull Request`, or `Pull Requests`.
3. The **status property** for each database is its `status`-type property, or a
   `select` property named `Status`.
4. Build each **status map** by reading the database's real status options and
   matching each option name to a logical state by name.
5. Persist the result under `derived` with a `derivedAt` timestamp.

### Ambiguity

When derivation has a single clear answer, the skill proceeds silently. When a piece
is ambiguous — for example two plausible PR properties, or a status option that does
not clearly map to any logical state — the skill:

- prompts for that specific piece when running interactively, and
- skips that database or that single state when running unattended, recording it in
  the run report flags.

### Self-healing

At run time, the skill validates `derived` against the live schemas. If the relation
is gone, the PR property is missing, or a needed status can no longer be resolved
against current options, the skill re-runs discovery from the stored roadmap link,
refreshes `derived`, and continues. The roadmap link is the only durable anchor;
everything under `derived` is disposable.

### First-ever unattended run with no config

If there is no usable config and the run cannot prompt (scheduled or headless), the
skill exits cleanly with a message asking for one interactive run to configure, and
never blocks. Subsequent unattended runs work normally.

## Task reconciliation flow

For each task page in scope:

### Derive the logical state

PR state for each linked URL comes from `gh pr view <url> --json
state,isDraft,mergedAt` (and related fields), with no local checkout.

| Condition on the task page                                              | Derived state   |
| ----------------------------------------------------------------------- | --------------- |
| No PRs in the PR property, and no technical detail on the page          | `backlog`       |
| No PRs, but technical detail present                                    | `inAnalysis`    |
| Has PR(s), and every linked PR is merged                                | `readyToDeploy` |
| Has PR(s), at least one open and non-draft                              | `inReview`      |
| Has PR(s), but only drafts (none merged, none ready for review)         | `inDevelopment` |

"Highest signal wins": a task only reaches `readyToDeploy` when every linked PR is
merged. Otherwise the most-advanced in-flight signal applies (ready-for-review beats
draft).

**Technical-detail test (for the `inAnalysis` rule):** either signal qualifies. If the
page has a designated technical section (a heading such as `Technical`,
`Implementation`, or `Analysis`), non-empty content there counts. Otherwise the skill
judges the page body: implementation detail (architecture, APIs, data models,
technical approach) counts; purely business or product framing (goals, value, user
stories) does not, and the page stays `backlog`.

### Apply the state (forward-only, availability-gated)

1. Resolve the derived state's option name from `tasksStatusMap`. If the logical
   state is not mapped (the database has no such option), do not change status; flag
   it.
2. Read the page's current status and compare current vs derived on the fixed
   ordering.
   - Derived ahead of current → write the new status.
   - Derived equal to or behind current, or the current status is not in the map
     (unrecognized) → leave status untouched; record as unchanged or skipped.
3. **Description sync** runs whenever the task has PRs, regardless of whether status
   moved. Fetch each PR's title, body, changed files, and diff via `gh`, synthesize
   one high-level architecture-style description across them, and write it to the card
   deferring prose to `write-notion-content`. No tests or verification text. A task
   with no PRs gets no description write. The description is re-synthesized on every
   run by design; change-detection caching (skipping re-synthesis when no linked PR's
   head moved) is a deliberate non-goal unless requested later.

### Task edge cases

- A PR URL `gh` cannot resolve (deleted or no access) is ignored for state derivation
  and flagged; the state is derived from the remaining PRs.
- A closed-unmerged PR counts as neither merged nor open. It contributes nothing
  toward `readyToDeploy`. If it is the only PR, the task falls to `inDevelopment`.

## Roadmap roll-up flow

A roadmap item has no PRs of its own. Its state and description roll up from its child
tasks. Children are reconciled first (the task flow above), then the roadmap item is
derived from their post-update states.

When the scope is a roadmap item (or a roadmap database with no argument), the skill
enumerates child tasks via the relation property, runs each through the task flow,
then computes the roadmap item.

### Derive roadmap status

| Children's states                                       | Roadmap state   |
| ------------------------------------------------------- | --------------- |
| All children `readyToDeploy`                            | `readyToDeploy` |
| Any child `inReview` or `inDevelopment`                 | `inDevelopment` |
| All children `backlog` or `inAnalysis` (none started)   | `backlog`       |

Rows are evaluated top-down; the first matching row wins. A roadmap item with no
child tasks matches no row and is left untouched (no-op, reported as unchanged).

The same forward-only and availability-gate rules apply: only advance, and only if
the option exists in the roadmap database.

### Derive roadmap description

Synthesize a high-level summary across the children's PRs and changes — the roadmap
analogue of `sync-pr-to-notion`. Architecture-level, no tests or verification, prose
deferred to `write-notion-content`.

### Interactive checkpoint (adaptive to run context)

- **Interactive run:** after child tasks are updated, present the roadmap item's
  proposed status (current → derived) and proposed description, and ask the user to
  confirm, edit, or skip before writing. The user owns the final roadmap narrative.
- **Unattended run:** child tasks are updated normally. The roadmap item is not
  written. The skill leaves a Notion comment on the roadmap page with the proposed
  status and description, and lists the item in the run report as awaiting review.
  Nothing on the roadmap page itself changes until a human acts.

### Run-context detection

Interactive vs unattended is inferred from whether the session can prompt (an
interactive TTY session vs a scheduled or headless run). The spec author will choose a
concrete, documented signal during implementation rather than leave it implicit.

## Run flow

1. **Load config.** If missing, or the scope's roadmap is not configured, run inline
   setup and discovery. If nothing usable and the run cannot prompt, exit cleanly.
2. **Resolve scope.** A page argument narrows to that task or roadmap item. No
   argument scans every configured roadmap (and its children).
3. **Validate and refresh `derived`** against live schemas; self-heal from the
   roadmap anchor if stale.
4. **Reconcile tasks first**: per task, derive state, write status forward-only, sync
   description if PRs.
5. **Reconcile roadmap items**: roll up children, then confirm (interactive) or
   comment-and-queue (unattended).
6. **Report.**

## Output

A terminal summary, one line per page: `current → new` status (or `unchanged` /
`skipped`), description synced yes/no, and a flags list covering:

- regressions skipped (derived state behind current),
- unmapped logical states (database has no matching option),
- ambiguous properties left unresolved,
- unresolvable PR URLs,
- roadmap items queued for review.

In unattended mode, the skill also leaves a Notion comment on each queued roadmap page
with its proposed status and description.

## Skill mechanics

- A single self-contained `SKILL.md` placed under
  `plugins/soong/skills/sync-notion-status/`, like the other soong skills. Skills are
  auto-discovered from that directory, so no manifest edit is required.
- Frontmatter: `name: sync-notion-status` and a `description:` carrying trigger
  phrases (for example "sync notion status", "reconcile the notion board", "update
  task statuses from PRs", and run-as-a-routine phrasings).
- The skill inlines its `jq` and `gh` shell usage, reads and writes Notion through the
  MCP, and defers prose only to `write-notion-content`.
- Optional argument: a page or database URL/ID that narrows scope.
- The skill documents the unattended caveat (first run must be interactive to
  configure) and how to schedule it via the `schedule` or `loop` skills.

## Boundaries (restated)

- Never edits code, tests, or verification.
- Never regresses a status, and never overwrites an unrecognized status.
- Never targets a status option that does not exist in the database.
- Never invents a card, database, or PR link.
