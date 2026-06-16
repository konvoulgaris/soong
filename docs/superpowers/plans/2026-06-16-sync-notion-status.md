# sync-notion-status Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `sync-notion-status` soong skill — a single SKILL.md that reconciles Notion card status against PR/code reality, interactively or as an unattended routine.

**Architecture:** The deliverable is one instruction document, `plugins/soong/skills/sync-notion-status/SKILL.md`, written in the soong house style (prose steps, inlined `jq`/`gh` bash, cross-references to sibling skills by name in backticks, no code comments). The skill is auto-discovered from the skills directory — no manifest edit. It carries a small JSON config under XDG state (`notion-databases.json`), keyed on a roadmap database link, with everything else discovered from Notion schemas and self-healed at run time. It reads/writes Notion through the Notion MCP and fetches PRs through `gh`; it defers prose only to `write-notion-content`.

**Tech Stack:** Markdown (SKILL.md with YAML frontmatter), Bash, `jq`, `gh` CLI, the Notion MCP. Reference spec: `docs/superpowers/specs/2026-06-16-sync-notion-status-design.md`.

---

## How to verify a skill (read this first)

A SKILL.md is a **prompt document, not executable code**. There are no unit tests to write, and the repo's "add a test file" convention applies to Go/TS source, not markdown skills (no existing soong skill has a test file). So the verification discipline for this plan is different from code TDD, but no less strict:

1. **Every embedded bash snippet must actually run.** The config read/write, the `jq` queries, and the `gh` invocations are real shell. Each task that introduces a snippet includes a step that runs it against a fixture and checks the output. Write the snippet, run it, see it work, then paste it into the SKILL.md verbatim.
2. **The skill must be structurally valid and complete.** Frontmatter present and well-formed; every spec section represented; no TODO/placeholder text; cross-referenced skills named exactly as they exist on disk.
3. **Commit after each task.** Conventional Commits (`feat(skills): ...`), per the project CLAUDE.md.

Snippets are developed in a scratch dir so runs never touch the real `notion-databases.json`. Each bash step sets `export XDG_STATE_HOME="$(mktemp -d)"` (or an explicit scratch path) so the fixture config is isolated. The MCP-driven parts (schema fetch, page reads/writes, comments) cannot be unit-run from bash — for those, verification is a careful read-through against the spec plus an explicit "expected tool calls" description in the SKILL.md, which the reviewer checks.

---

## File Structure

- **Create:** `plugins/soong/skills/sync-notion-status/SKILL.md` — the entire skill. One file, one responsibility (the reconciliation routine). This mirrors every other soong skill, each of which is a single self-contained SKILL.md.

No other files are created or modified. No manifest change (skills auto-discovered). No test files (not applicable to instruction documents — see above).

The SKILL.md itself is organized into these sections, in order, matching the spec:

1. Frontmatter (`name`, `description` with trigger phrases)
2. Overview + boundaries (what it does / does NOT do)
3. Config: location, shape, logical states
4. Discovery, ambiguity, self-healing, first-run-unattended
5. Task reconciliation flow (derive state table, apply forward-only, description sync, edge cases)
6. Roadmap roll-up flow (status table, description, interactive/unattended checkpoint, run-context detection)
7. Run flow (the end-to-end ordering)
8. Output (terminal summary + Notion comments)
9. Rules (boundaries restated)

Because it is a single file that will run 250–350 lines, the plan builds it section by section and re-reads the growing file between tasks to keep it coherent.

---

## Chunk 1: Config foundation and runnable helpers

This chunk produces the config file format and every bash snippet the skill embeds, each verified by running it. It also scaffolds the SKILL.md with frontmatter and the static sections (overview, boundaries, logical states). By the end of this chunk the skill exists and its mechanical parts (config read/write, ordering comparison) are proven to work.

### Task 1: Scaffold the skill file with frontmatter and overview

**Files:**
- Create: `plugins/soong/skills/sync-notion-status/SKILL.md`

- [ ] **Step 1: Verify the sibling skills referenced by name actually exist**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
ls plugins/soong/skills/write-notion-content/SKILL.md \
   plugins/soong/skills/sync-pr-to-notion/SKILL.md \
   plugins/soong/skills/manage-pr/SKILL.md
```
Expected: all three paths print with no "No such file" error. These are the skills the new SKILL.md will name in backticks; they must exist so the references are valid.

- [ ] **Step 2: Create the skill file with frontmatter, overview, and boundaries**

Create `plugins/soong/skills/sync-notion-status/SKILL.md` with exactly this content:

````markdown
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
````

- [ ] **Step 3: Verify the frontmatter parses and the file is well-formed**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
f=plugins/soong/skills/sync-notion-status/SKILL.md
awk 'NR==1{if($0!="---"){print "BAD: no opening ---"; exit 1}} /^---$/{c++} END{if(c<2){print "BAD: frontmatter not closed"; exit 1} print "frontmatter OK"}' "$f"
grep -q '^name: sync-notion-status$' "$f" && echo "name OK"
grep -q '^description: ' "$f" && echo "description OK"
```
Expected: `frontmatter OK`, `name OK`, `description OK`.

- [ ] **Step 4: Verify no stray placeholders**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
! grep -nE 'TODO|TBD|FIXME|\bXXX\b|<placeholder>' plugins/soong/skills/sync-notion-status/SKILL.md && echo "no placeholders"
```
Expected: `no placeholders`.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add plugins/soong/skills/sync-notion-status/SKILL.md
git commit -m "feat(skills): scaffold sync-notion-status skill"
```

---

### Task 2: Config file — location, shape, and a proven read/write snippet

**Files:**
- Modify: `plugins/soong/skills/sync-notion-status/SKILL.md` (append the Config section)

This task locks the config format from the spec and produces the exact `jq` snippets the skill will use to read the roadmap anchor and to merge a refreshed `derived` cache. Both snippets are run against a scratch file before being pasted in.

- [ ] **Step 1: Prove the config read snippet against a fixture**

Run (creates an isolated fixture, then reads it the way the skill will):
```bash
export XDG_STATE_HOME="$(mktemp -d)"
dir="${XDG_STATE_HOME}/soong"; file="$dir/notion-databases.json"
mkdir -p "$dir"
cat > "$file" <<'JSON'
{
  "roadmaps": [
    {
      "roadmap": "https://notion.so/roadmap-abc",
      "derived": {
        "tasksDb": "tasks-xyz",
        "tasksRelationProperty": "Tasks",
        "roadmapStatusProperty": "Status",
        "tasksStatusProperty": "Status",
        "prProperty": "PR",
        "roadmapStatusMap": {"backlog":"Backlog","inDevelopment":"In Dev","readyToDeploy":"Ready for QA"},
        "tasksStatusMap": {"backlog":"Backlog","inAnalysis":"In Analysis","inDevelopment":"In Dev","inReview":"In Review","readyToDeploy":"Ready for QA"},
        "derivedAt": "2026-06-16T00:00:00Z"
      }
    }
  ]
}
JSON
echo "--- all roadmap anchors ---"
jq -r '.roadmaps[].roadmap' "$file"
echo "--- derived for a specific roadmap ---"
jq -r --arg r "https://notion.so/roadmap-abc" '.roadmaps[] | select(.roadmap==$r) | .derived.tasksDb' "$file"
```
Expected output:
```
--- all roadmap anchors ---
https://notion.so/roadmap-abc
--- derived for a specific roadmap ---
tasks-xyz
```

- [ ] **Step 2: Prove the "missing or empty config" detection snippet**

Run:
```bash
export XDG_STATE_HOME="$(mktemp -d)"
file="${XDG_STATE_HOME}/soong/notion-databases.json"
# No file yet:
if [ ! -f "$file" ] || [ "$(jq '.roadmaps | length' "$file" 2>/dev/null || echo 0)" = "0" ]; then
  echo "needs setup"
else
  echo "configured"
fi
```
Expected: `needs setup`.

- [ ] **Step 3: Prove the idempotent merge snippet (upsert a roadmap's derived cache)**

Run:
```bash
export XDG_STATE_HOME="$(mktemp -d)"
dir="${XDG_STATE_HOME}/soong"; file="$dir/notion-databases.json"
mkdir -p "$dir"; [ -f "$file" ] || echo '{"roadmaps":[]}' > "$file"
roadmap="https://notion.so/roadmap-abc"
derived='{"tasksDb":"tasks-xyz","prProperty":"PR","derivedAt":"2026-06-16T00:00:00Z"}'
tmp="$(mktemp)"
jq --arg r "$roadmap" --argjson d "$derived" '
  .roadmaps |= ( map(select(.roadmap != $r)) + [{roadmap: $r, derived: $d}] )
' "$file" > "$tmp" && mv "$tmp" "$file"
# Run again with updated derived to prove idempotent upsert (no duplicate entry):
derived2='{"tasksDb":"tasks-xyz","prProperty":"PullRequest","derivedAt":"2026-06-17T00:00:00Z"}'
tmp="$(mktemp)"
jq --arg r "$roadmap" --argjson d "$derived2" '
  .roadmaps |= ( map(select(.roadmap != $r)) + [{roadmap: $r, derived: $d}] )
' "$file" > "$tmp" && mv "$tmp" "$file"
echo "entry count: $(jq '.roadmaps | length' "$file")"
echo "prProperty now: $(jq -r '.roadmaps[0].derived.prProperty' "$file")"
```
Expected:
```
entry count: 1
prProperty now: PullRequest
```
(One entry, updated in place — proves re-deriving refreshes rather than appends.)

- [ ] **Step 4: Append the Config section to the SKILL.md**

Append this section (it embeds the snippets just proven):

````markdown
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
jq -r '.roadmaps[].roadmap' "$file"        # all configured roadmap anchors
```

Detect missing or empty config:

```bash
file="${XDG_STATE_HOME:-$HOME/.local/state}/soong/notion-databases.json"
if [ ! -f "$file" ] || [ "$(jq '.roadmaps | length' "$file" 2>/dev/null || echo 0)" = "0" ]; then
  echo "needs setup"
fi
```

### Writing (upsert one roadmap's derived cache, idempotent)

```bash
dir="${XDG_STATE_HOME:-$HOME/.local/state}/soong"; file="$dir/notion-databases.json"
mkdir -p "$dir"; [ -f "$file" ] || echo '{"roadmaps":[]}' > "$file"
tmp="$(mktemp)"
jq --arg r "$roadmap" --argjson d "$derived" \
  '.roadmaps |= ( map(select(.roadmap != $r)) + [{roadmap: $r, derived: $d}] )' \
  "$file" > "$tmp" && mv "$tmp" "$file"
```

### Logical states

Fixed. They are the left-hand side of every status map and the ordering for
forward-only comparison:

```
backlog < inAnalysis < inDevelopment < inReview < readyToDeploy
```

`inReview` is a task-only rung; roadmap items use `inDevelopment` as their single
in-flight bucket.
````

- [ ] **Step 5: Verify the appended snippets are byte-for-byte the proven ones**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
f=plugins/soong/skills/sync-notion-status/SKILL.md
grep -q 'roadmaps |= ( map(select(.roadmap != \$r))' "$f" && echo "merge snippet present"
grep -q 'backlog < inAnalysis < inDevelopment < inReview < readyToDeploy' "$f" && echo "ordering present"
! grep -nE 'TODO|TBD|FIXME' "$f" && echo "no placeholders"
```
Expected: `merge snippet present`, `ordering present`, `no placeholders`.

- [ ] **Step 6: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add plugins/soong/skills/sync-notion-status/SKILL.md
git commit -m "feat(skills): add sync-notion-status config format and helpers"
```

---

### Task 3: Forward-only ordering comparison — a proven snippet

**Files:**
- Modify: `plugins/soong/skills/sync-notion-status/SKILL.md` (extend the logical-states area with the comparison helper)

The single most load-bearing mechanic is "is the derived state ahead of the current state?" This task proves a tiny rank-comparison snippet covering the advance, equal, behind, and unrecognized cases, then embeds it.

- [ ] **Step 1: Prove the rank comparison across all four cases**

Run:
```bash
rank() {
  case "$1" in
    backlog) echo 0;; inAnalysis) echo 1;; inDevelopment) echo 2;;
    inReview) echo 3;; readyToDeploy) echo 4;; *) echo -1;;  # -1 = unrecognized
  esac
}
# advance? prints "advance", "hold", or "unrecognized"
decide() {
  cur="$(rank "$1")"; der="$(rank "$2")"
  if [ "$cur" -lt 0 ]; then echo "unrecognized"; return; fi
  if [ "$der" -gt "$cur" ]; then echo "advance"; else echo "hold"; fi
}
echo "backlog -> inReview : $(decide backlog inReview)"          # advance
echo "inReview -> inReview : $(decide inReview inReview)"        # hold (equal)
echo "readyToDeploy -> inDevelopment : $(decide readyToDeploy inDevelopment)"  # hold (behind)
echo "WeirdCustom -> inReview : $(decide WeirdCustom inReview)"  # unrecognized
```
Expected:
```
backlog -> inReview : advance
inReview -> inReview : hold
readyToDeploy -> inDevelopment : hold
WeirdCustom -> inReview : unrecognized
```

- [ ] **Step 2: Append the comparison guidance to the SKILL.md (right after Logical states)**

Append:
````markdown
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
````

- [ ] **Step 3: Verify**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -q 'Forward-only comparison' plugins/soong/skills/sync-notion-status/SKILL.md && echo "section present"
grep -q 'readyToDeploy) echo 4' plugins/soong/skills/sync-notion-status/SKILL.md && echo "rank fn present"
```
Expected: `section present`, `rank fn present`.

- [ ] **Step 4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add plugins/soong/skills/sync-notion-status/SKILL.md
git commit -m "feat(skills): add forward-only comparison to sync-notion-status"
```

---

### Task 4: Discovery, ambiguity, self-healing, first-run-unattended

**Files:**
- Modify: `plugins/soong/skills/sync-notion-status/SKILL.md` (append the Discovery section)

These steps are MCP-driven (schema reads), so they are authored as precise instructions rather than runnable bash. Verification is a spec cross-check plus a structural grep. The one runnable piece — the PR-property name matcher — is proven.

- [ ] **Step 1: Prove the PR-property name matcher**

Run (simulates choosing the PR property from a list of schema property names):
```bash
match_pr() {
  # reads property names on stdin, prints those that look like a PR field
  grep -iE '^(pr|prs|pull[ _-]?request|pull[ _-]?requests)$'
}
printf '%s\n' "Status" "PR" "Assignee" "Pull Requests" | match_pr
```
Expected:
```
PR
Pull Requests
```
(Two matches here means *ambiguous* — the skill must prompt or skip. A single match means proceed silently.)

- [ ] **Step 2: Append the Discovery section**

Append:
````markdown
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
   # property names on stdin -> candidate PR properties
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
ambiguous — two or more candidate PR properties, or a status option that maps to no
logical state — then:

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
````

- [ ] **Step 3: Cross-check against the spec and verify structure**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
f=plugins/soong/skills/sync-notion-status/SKILL.md
for s in "Discovery and self-healing" "### Ambiguity" "### Self-healing" "### Inline setup" "First-ever unattended run"; do
  grep -q "$s" "$f" && echo "OK: $s" || echo "MISSING: $s"
done
```
Expected: five `OK:` lines, no `MISSING:`.

- [ ] **Step 4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add plugins/soong/skills/sync-notion-status/SKILL.md
git commit -m "feat(skills): add discovery and self-healing to sync-notion-status"
```

---

## Chunk 2: Reconciliation logic, run flow, and output

This chunk adds the decision logic (task state table, roadmap roll-up), the run ordering, and the output behavior, then does a final whole-file coherence pass.

### Task 5: Task reconciliation flow

**Files:**
- Modify: `plugins/soong/skills/sync-notion-status/SKILL.md` (append the Task reconciliation section)

The PR-state read is `gh`-driven. The classification logic is deterministic and is proven with a small snippet over canned PR-state inputs; the `gh` call itself is specified exactly.

- [ ] **Step 1: Prove the PR-set classifier**

Run (classifies a set of PRs given each PR's merged/draft/open state; "highest signal wins"):
```bash
# stdin: one PR per line, each "merged|ready|draft|closed"
classify() {
  any=0; allmerged=1; ready=0; draftonly=1
  while read -r s; do
    [ -z "$s" ] && continue
    any=1
    case "$s" in
      merged) draftonly=0;;
      ready)  allmerged=0; ready=1; draftonly=0;;
      draft)  allmerged=0;;
      closed) allmerged=0; draftonly=0;;
    esac
  done
  if [ "$any" = 0 ]; then echo "no-prs"; return; fi
  if [ "$allmerged" = 1 ]; then echo "readyToDeploy"; return; fi
  if [ "$ready" = 1 ]; then echo "inReview"; return; fi
  if [ "$draftonly" = 1 ]; then echo "inDevelopment"; return; fi
  echo "inDevelopment"   # e.g. merged + closed but none ready
}
echo "all merged           : $(printf 'merged\nmerged\n' | classify)"
echo "one ready            : $(printf 'merged\nready\n' | classify)"
echo "drafts only          : $(printf 'draft\ndraft\n' | classify)"
echo "closed-unmerged only : $(printf 'closed\n' | classify)"
echo "none                 : $(printf '' | classify)"
```
Expected:
```
all merged           : readyToDeploy
one ready            : inReview
drafts only          : inDevelopment
closed-unmerged only : inDevelopment
none                 : no-prs
```

- [ ] **Step 2: Append the Task reconciliation section**

Append:
````markdown
## Task reconciliation flow

For each task page in scope:

### Read the linked PRs

Read the PR property. For each PR URL, fetch its state with `gh` (no local checkout):

```bash
gh pr view "$url" --json state,isDraft,mergedAt,title,body,files
```

Treat each PR as: `merged` (has `mergedAt`), `ready` (open, not draft), `draft`
(open, draft), or `closed` (closed without merge). A URL `gh` cannot resolve
(deleted or no access) is ignored for state and flagged; derive from the rest.

### Derive the logical state

| Condition on the task page                                         | Derived state   |
| ------------------------------------------------------------------ | --------------- |
| No PRs in the PR property, and no technical detail on the page     | `backlog`       |
| No PRs, but technical detail present                               | `inAnalysis`    |
| Has PR(s), and every linked PR is merged                           | `readyToDeploy` |
| Has PR(s), at least one open and non-draft                         | `inReview`      |
| Has PR(s), but only drafts (none merged, none ready)               | `inDevelopment` |

Highest signal wins: a task reaches `readyToDeploy` only when every linked PR is
merged. A closed-unmerged PR contributes nothing toward `readyToDeploy`; if it is the
only PR, the task falls to `inDevelopment`.

Technical-detail test for the `inAnalysis` rule (either signal qualifies): if the
page has a designated technical section (a heading such as `Technical`,
`Implementation`, or `Analysis`), non-empty content there counts. Otherwise judge the
page body — implementation detail (architecture, APIs, data models, technical
approach) counts; purely business or product framing (goals, value, user stories)
does not, and the page stays `backlog`.

### Apply the state (forward-only, availability-gated)

1. Resolve the derived state's option name from `tasksStatusMap`. If the logical
   state is not mapped (no such option in this database), do not change status; flag
   it.
2. Read the page's current status, reverse-map it to a logical state, and apply the
   Forward-only comparison. Advance only when the derived rank is greater; otherwise
   hold and report `unchanged`/`skipped`.
3. Description sync runs whenever the task has PRs, regardless of whether status
   moved. From each PR's title, body, changed files, and diff, synthesize one
   high-level architecture-style description across them and write it to the card,
   deferring prose to `write-notion-content`. No tests or verification text. A task
   with no PRs gets no description write. The description is re-synthesized on every
   run by design; change-detection caching is a deliberate non-goal unless requested.
````

- [ ] **Step 3: Verify the table and rules are present and consistent with the spec**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
f=plugins/soong/skills/sync-notion-status/SKILL.md
grep -q 'Has PR(s), and every linked PR is merged' "$f" && echo "ready row OK"
grep -q 'at least one open and non-draft' "$f" && echo "inReview row OK"
grep -q 'only drafts' "$f" && echo "inDevelopment row OK"
grep -q 'gh pr view "\$url" --json state,isDraft,mergedAt,title,body,files' "$f" && echo "gh call OK"
grep -q 'deferring prose to `write-notion-content`' "$f" && echo "prose deferral OK"
```
Expected: five `OK` lines.

- [ ] **Step 4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add plugins/soong/skills/sync-notion-status/SKILL.md
git commit -m "feat(skills): add task reconciliation flow to sync-notion-status"
```

---

### Task 6: Roadmap roll-up flow

**Files:**
- Modify: `plugins/soong/skills/sync-notion-status/SKILL.md` (append the Roadmap section)

- [ ] **Step 1: Prove the roll-up classifier**

Run (rolls a set of child logical states up to a roadmap state; first matching rule wins, empty = no-op):
```bash
# stdin: one child logical state per line
rollup() {
  any=0; allready=1; inflight=0
  while read -r s; do
    [ -z "$s" ] && continue
    any=1
    case "$s" in
      readyToDeploy) ;;                       # keeps allready possible
      inReview|inDevelopment) allready=0; inflight=1;;
      backlog|inAnalysis) allready=0;;
      *) allready=0;;
    esac
  done
  if [ "$any" = 0 ]; then echo "no-op"; return; fi
  if [ "$allready" = 1 ]; then echo "readyToDeploy"; return; fi
  if [ "$inflight" = 1 ]; then echo "inDevelopment"; return; fi
  echo "backlog"
}
echo "all ready      : $(printf 'readyToDeploy\nreadyToDeploy\n' | rollup)"
echo "mixed inflight : $(printf 'readyToDeploy\ninReview\n' | rollup)"
echo "none started   : $(printf 'backlog\ninAnalysis\n' | rollup)"
echo "empty          : $(printf '' | rollup)"
```
Expected:
```
all ready      : readyToDeploy
mixed inflight : inDevelopment
none started   : backlog
empty          : no-op
```

- [ ] **Step 2: Append the Roadmap section**

Append:
````markdown
## Roadmap roll-up flow

A roadmap item has no PRs of its own; its state and description roll up from its child
tasks. Reconcile the children first (the task flow above), then compute the roadmap
item from their post-update states. Enumerate children via the relation property.

### Derive roadmap status

| Children's states                                       | Roadmap state   |
| ------------------------------------------------------- | --------------- |
| All children `readyToDeploy`                            | `readyToDeploy` |
| Any child `inReview` or `inDevelopment`                 | `inDevelopment` |
| All children `backlog` or `inAnalysis` (none started)   | `backlog`       |

Rows are evaluated top-down; the first matching row wins. A roadmap item with no child
tasks matches no row and is left untouched (no-op, reported as unchanged). The same
forward-only and availability-gate rules apply: only advance, and only if the option
exists in the roadmap database.

### Derive roadmap description

Synthesize a high-level summary across the children's PRs and changes — the roadmap
analogue of `sync-pr-to-notion`. Architecture-level, no tests or verification, prose
deferred to `write-notion-content`.

### Interactive checkpoint (adaptive to run context)

- Interactive run: after child tasks are updated, present the roadmap item's proposed
  status (`current → derived`) and proposed description, and ask the user to confirm,
  edit, or skip before writing. The user owns the final roadmap narrative.
- Unattended run: update child tasks normally, but do not write the roadmap item.
  Leave a Notion comment on the roadmap page with the proposed status and description,
  and list the item in the run report as awaiting review. Nothing on the roadmap page
  itself changes until a human acts.

### Run-context detection

Treat the run as interactive when the session can prompt the user, and unattended
otherwise. Concretely: if standard input is not a TTY (`[ -t 0 ]` is false), or the
invocation was made by a scheduled/headless runner, treat it as unattended. When in
doubt, prefer the unattended path (comment and queue) so nothing is written to a
roadmap page without a human in the loop.
````

- [ ] **Step 3: Verify**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
f=plugins/soong/skills/sync-notion-status/SKILL.md
grep -q 'first matching row wins' "$f" && echo "precedence OK"
grep -q 'left untouched (no-op' "$f" && echo "empty case OK"
grep -q 'Leave a Notion comment on the roadmap page' "$f" && echo "unattended comment OK"
grep -q '\[ -t 0 \]' "$f" && echo "tty detection OK"
```
Expected: four `OK` lines.

- [ ] **Step 4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add plugins/soong/skills/sync-notion-status/SKILL.md
git commit -m "feat(skills): add roadmap roll-up to sync-notion-status"
```

---

### Task 7: Run flow, output, and rules

**Files:**
- Modify: `plugins/soong/skills/sync-notion-status/SKILL.md` (append Run flow, Output, Rules)

- [ ] **Step 1: Append the final sections**

Append:
````markdown
## Run flow

1. Load config. If missing, or the scope's roadmap is not configured, run inline
   setup and discovery. If nothing usable and the run cannot prompt, exit cleanly.
2. Resolve scope. A page argument narrows to that task or roadmap item. No argument
   scans every configured roadmap and its children.
3. Validate and refresh `derived` against live schemas; self-heal from the roadmap
   anchor if stale.
4. Reconcile tasks first: per task, derive state, write status forward-only, sync
   description if PRs.
5. Reconcile roadmap items: roll up children, then confirm (interactive) or
   comment-and-queue (unattended).
6. Report.

## Output

Print a terminal summary, one line per page: `current → new` status (or `unchanged` /
`skipped`), description synced yes/no, and a flags list covering:

- regressions skipped (derived state behind current),
- unmapped logical states (database has no matching option),
- ambiguous properties left unresolved,
- unresolvable PR URLs,
- roadmap items queued for review.

In unattended mode, also leave a Notion comment on each queued roadmap page with its
proposed status and description.

## Arguments

Optional argument: a page or database URL/ID that narrows scope to a single task or
roadmap item. With no argument, scan every configured roadmap.

## Scheduling

To run unattended, schedule this skill via the `schedule` or `loop` skills. The first
run on a new machine must be interactive so setup can capture the roadmap database;
after that, scheduled runs work without prompts.

## Rules

- Never edits code, tests, or verification.
- Never regresses a status, and never overwrites an unrecognized status.
- Never targets a status option that does not exist in the database.
- Never invents a card, database, or PR link.
- Defer all Notion prose style to `write-notion-content`.
````

- [ ] **Step 2: Verify the final sections and full-file placeholder scan**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
f=plugins/soong/skills/sync-notion-status/SKILL.md
for s in "## Run flow" "## Output" "## Arguments" "## Scheduling" "## Rules"; do
  grep -q "$s" "$f" && echo "OK: $s" || echo "MISSING: $s"
done
! grep -nE 'TODO|TBD|FIXME|\bXXX\b' "$f" && echo "no placeholders"
```
Expected: five `OK:` lines and `no placeholders`.

- [ ] **Step 3: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add plugins/soong/skills/sync-notion-status/SKILL.md
git commit -m "feat(skills): add run flow, output, and rules to sync-notion-status"
```

---

### Task 8: Whole-file coherence pass and final verification

**Files:**
- Modify: `plugins/soong/skills/sync-notion-status/SKILL.md` (edits only if the read-through finds problems)

- [ ] **Step 1: Read the entire file top to bottom**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
cat -n plugins/soong/skills/sync-notion-status/SKILL.md
```
Read for: section order matches the spec; no contradiction between the task table and the roadmap table; logical-state names spelled identically everywhere (`backlog`, `inAnalysis`, `inDevelopment`, `inReview`, `readyToDeploy`); every sibling skill named in backticks exists; tone matches the terse soong style (no em-dashes in the prose the skill itself emits — check the skill's own copy, not this plan).

- [ ] **Step 2: Verify spec coverage — every spec section is represented**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
f=plugins/soong/skills/sync-notion-status/SKILL.md
for s in "What it does" "What it does NOT do" "Configuration" "Logical states" \
         "Discovery and self-healing" "Inline setup" "Task reconciliation flow" \
         "Roadmap roll-up flow" "Run-context detection" "Run flow" "Output" "Rules"; do
  grep -q "$s" "$f" && echo "OK: $s" || echo "MISSING: $s"
done
```
Expected: all `OK:`, no `MISSING:`.

- [ ] **Step 3: Verify the logical-state vocabulary is internally consistent**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
f=plugins/soong/skills/sync-notion-status/SKILL.md
# These five should each appear; no stray variants like "in_review" or "ready-to-deploy".
for s in backlog inAnalysis inDevelopment inReview readyToDeploy; do
  printf '%s: %s\n' "$s" "$(grep -oc "$s" "$f")"
done
! grep -nE 'in_review|ready-to-deploy|in_development|in_analysis' "$f" && echo "no snake/kebab variants"
```
Expected: each state's count ≥ 1, and `no snake/kebab variants`.

- [ ] **Step 4: Confirm the skill is auto-discoverable (no manifest edit needed)**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
test -f plugins/soong/skills/sync-notion-status/SKILL.md && echo "in skills dir OK"
git -C "$(git rev-parse --show-toplevel)" status --porcelain
```
Expected: `in skills dir OK`, and a clean status (all prior tasks committed). The skill sits beside its siblings under `plugins/soong/skills/`, so it is discovered without touching `.claude-plugin/marketplace.json` or `plugin.json`.

- [ ] **Step 5: Final commit (only if Step 1 produced edits)**

```bash
cd "$(git rev-parse --show-toplevel)"
git add plugins/soong/skills/sync-notion-status/SKILL.md
git commit -m "refactor(skills): tighten sync-notion-status for coherence" || echo "nothing to commit"
```

---

## Done

The skill is complete when:
- `plugins/soong/skills/sync-notion-status/SKILL.md` exists with valid frontmatter and all nine sections.
- Every embedded bash snippet has been run and produced the expected output.
- No placeholders, consistent logical-state vocabulary, all sibling-skill references valid.
- All work committed with Conventional Commits.

There is no separate test suite and no build step: the deliverable is an instruction document, verified by running its embedded shell and by structural review, as described at the top of this plan.
