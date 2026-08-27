# develop Skill Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/develop` skill that takes a Notion roadmap item and builds its whole task stack as stacked pull requests in one session, and retire the handoff document `architect` ends with.

**Architecture:** Three markdown files change and one is created. The new skill orchestrates existing skills rather than implementing anything itself, so there is no code and no new script. `manage-pr` compose mode gains three additive arguments, without which the stack would not stack.

**Tech Stack:** Markdown skill files in a Claude Code plugin. No build step, no registration: file presence installs a skill. Verification is `grep` plus a read, because there is no test framework for prose.

**Spec:** `docs/superpowers/specs/2026-08-27-develop-skill-design.md`

---

## How to work on this plan

**Every prose block below is given verbatim.** Transcribe it exactly. Do not
improve the wording, do not re-derive it from the spec, and do not summarize it.
The spec went through five review rounds and 27 findings; most of those findings
were single clauses whose absence made a stated behavior unreachable. A reworded
clause is a regression that no `grep` in this plan will catch.

**If a verbatim block looks wrong, say so and stop.** Do not silently fix it and
do not reword the deliverable to satisfy a check in this plan. A check in this
plan can be wrong; the deliverable is what ships. Report the conflict.

**One task, one commit.** Conventional Commits, per the repo's `CLAUDE.md`.

## File Structure

| Path | Change | Responsibility |
| --- | --- | --- |
| `plugins/soong/skills/develop/SKILL.md` | Create | The whole skill: arguments, names, first run, the loop, resume, ledger, failure modes, rules |
| `plugins/soong/skills/manage-pr/reference/pr/compose.md` | Modify | Three new arguments, and passing them to `gh pr create` |
| `plugins/soong/skills/architect/SKILL.md` | Modify | Retire the handoff document; print `/develop` instead |
| `README.md` | Modify | Drop the `handoff` requirement |
| `plugins/soong/.claude-plugin/plugin.json` | Modify | Version `0.8.0` to `0.9.0` |

`marketplace.json` is **not** touched. It lists plugins, not skills.

---

## Chunk 1: The skill

### Task 1: Create the develop skill

**Files:**
- Create: `plugins/soong/skills/develop/SKILL.md`

This is the largest task in the plan and the only one that creates a file. The
spec is the source; every section below gives the text to write.

- [ ] **Step 1: Write the frontmatter and the opening**

The `description` is what makes the skill trigger, so it names the command and
the phrases a user would actually type.

```markdown
---
name: develop
description: Take a Notion roadmap item and build its whole task stack as stacked pull requests, one pull request per task, asking any questions the task cards leave open before writing code. Use when the user runs /develop, or asks to implement a roadmap item, build out a stack of tasks, or start development on an architected feature. Requires the repo to be configured via architect-setup first.
---

# develop

Take a Notion roadmap item, walk every task on it in stack order, and land each
one as its own reviewable pull request based on the previous task's branch.

`architect` plans. This skill implements. It is the second half, and it replaces
the handoff document `architect` used to end with.

The user answers questions once, up front. Then the stack builds unattended.

## Assumes

- The `superpowers` plugin (`writing-plans`, `subagent-driven-development`).
- The `manage-pr` skill, with `--base`, `--notion-card`, and `--draft`.
- The Notion MCP.
- The repo configured via `architect-setup`.
```

- [ ] **Step 2: Write the Arguments section**

Verbatim from the spec:

```markdown
## Arguments

```
/develop <roadmap-item-notion-link> [--skip <task-title>]... [--draft]
```

- **`<roadmap-item-notion-link>`** — required, first positional. A Notion URL or
  page id for the roadmap item. This is the ledger key, so the same link resumes
  the same stack.
- **`--skip <task-title>`** — repeatable. The task's **title**, matched against
  the task pages resolved in first-run step 2, case-insensitively and ignoring
  surrounding whitespace. A title that matches no task, or more than one, stops
  before anything is created. Titles are resolved to page ids at that point, and
  the ledger stores ids only.
- **`--draft`** — open every pull request in the stack as a draft. Off by
  default, and the only thing that turns it on.
```

Note the one deliberate change from the spec's wording: "startup step 2" becomes
"first-run step 2", because the spec renamed that section after the Arguments
text was written.

- [ ] **Step 3: Write the Names section**

This section must appear **before** the steps that use it. Verbatim:

```markdown
## Names

Two names are derived, not chosen, so that a later run can find what an earlier
run created. Both are computed before anything is created, and neither depends on
the ledger.

- **A task's branch** is `claude/<slug>`, where `<slug>` is the task title
  lowercased, with every run of non-alphanumeric characters replaced by a single
  hyphen and leading and trailing hyphens removed.
- **The stack's worktree** is `.claude/worktrees/develop-<roadmap-item-id>`,
  under the repository's main checkout. The roadmap item id is the argument the
  user passed, so this is computable on the very first step of any run.

Deriving both from data that exists before the run starts is what makes the
interrupted-work check and the worktree reuse check possible. A name invented at
creation time could not be recomputed by the run that has to find it.

The branch name is derived once, in first-run step 6, and recorded in the ledger
for every task. Later steps and later runs read it from there. The worktree path
is derived from the roadmap item id on every run, which needs nothing but the
argument the user passed.
```

- [ ] **Step 4: Write the First run section**

Copy first-run steps 1 through 6 from the spec's `## First run` section
verbatim, including the preamble sentence "On a first run, nothing is created and
nothing is written until step 6. Every earlier step can stop for free." and the
sentence defining what a first run is.

Every sub-clause matters and several exist because a review round found their
absence produced a wrong outcome. Do not drop:

- Step 1's four exit codes and the Notion MCP reachability sentence.
- Step 2's **two** checks in order, count then correspondence, the sentence
  saying correspondence is a judgment call rather than string equality, and the
  closing paragraph that says what a stop does: show the two lists side by side,
  say which entries could not be mapped, ask, and do not guess an order. That
  paragraph is the only place the consequence of a failed check is specified.
- Step 3's "Known ceiling" paragraph and the trust-asymmetry paragraph, plus the
  rule that a "stacks on" statement naming no task stops the step.
- Step 4's three paragraphs, all of them: "Show the whole list, including the
  tasks with no gaps", which is what lets the user add a question the pass
  missed; the "inline, one at a time" paragraph forbidding batching and
  forbidding a design document, which is the whole of decisions 3 and 8; and
  "Hold the answers in the conversation for now".
- Step 5's worktree-reuse check, the lost-answers sentence, and the `.gitignore`
  paragraph.
- Step 6's paragraph explaining why the branch name is recorded now.

- [ ] **Step 5: Write the per-task loop**

Copy the spec's `## The per-task loop` section verbatim, all eight steps. The
numbering is load-bearing: other sections reference steps 7 and 8 by number.

Do not drop:

- Step 1's three triggers, including `stopped`, and the sentence saying to read
  the branch from the ledger rather than deriving it.
- Step 3's two worked examples and the definition of "contradicted".
- Step 4's instruction to write the plan file outside the repository.
- Step 5's two suppression paragraphs: `finishing-a-development-branch` is not
  followed, and the inherited final reviewer is allowed to run.
- Step 2's sentence that the branch name is already recorded, so it writes the
  status only.
- Step 6 as its own step, with the sentence saying why.
- All four bullets of step 7's compose invocation.
- Step 8's Notion status paragraph in full: read the card's own options, pick the
  match, skip and say so when nothing matches, and never guess a Notion value.
  A step 8 transcribed as a bare "mark the task done" would still pass the
  step-count check.

- [ ] **Step 6: Write the Resume section and the interrupted-work subsection**

Copy the spec's `## Resume` section verbatim, all seven bullets plus the closing
line. Six bullets are labelled `Step 1` through `Step 6`; the seventh is
`--draft on a resume`, which overrides no numbered step and is therefore the one
easiest to miss when mapping bullets onto first-run steps. Transcribe it too.

Then its `### A task that was interrupted` subsection verbatim, including
the fenced command block, the `--state all` paragraph, the "Unpushed commits"
definition paragraph, all three state bullets, the never-delete paragraph, and
the closing `stopped` paragraph.

- [ ] **Step 7: Write the ledger, failure modes, and rules**

Copy the spec's `## The ledger` section verbatim: the file path, the project-key
bash block, the JSON shape, the nine-row field table, the idempotent-merge
sentence, and the two things it does not do.

Then copy the spec's `## Failure modes` table verbatim, all **21** data rows, and
its `## Rules` list verbatim, all **10** bullets.

Count them in the spec rather than trusting these numbers:

```bash
spec=docs/superpowers/specs/2026-08-27-develop-skill-design.md
sed -n '/^## Failure modes/,/^## Rules/p' "$spec" | grep -c '^| '   # 23: 21 rows + header + separator
sed -n '/^## Rules/,/^## Verification/p' "$spec" | grep -c '^- '     # 10
```

The five tail rows are the ones most easily lost, and each was added by a review
round: the `--draft`-on-resume disagreement, a recorded worktree gone on resume, a
task in Notion the ledger's order lacks, no matching card status option, and the
pull-request guard hook denying `gh`.

- [ ] **Step 8: Verify structurally**

```bash
f=plugins/soong/skills/develop/SKILL.md
grep -q '^name: develop$' "$f" && echo "ok: name" || echo "MISSING: name"
grep -q '^description:.*/develop' "$f" && echo "ok: description triggers on /develop" || echo "MISSING: /develop in the description"
grep -q '^description:.*roadmap item' "$f" && echo "ok: description names a roadmap item" || echo "MISSING: trigger phrase"
for s in '## Arguments' '## Names' '## First run' '## The per-task loop' '## Resume' '## The ledger' '## Failure modes' '## Rules'; do
  grep -qF "$s" "$f" && echo "ok: $s" || echo "MISSING: $s"
done
```

Then check the two orderings the spec depends on, and the loop's numbering:

```bash
f=plugins/soong/skills/develop/SKILL.md
names=$(grep -n '^## Names' "$f" | cut -d: -f1)
first=$(grep -n '^## First run' "$f" | cut -d: -f1)
loop=$(grep -n '^## The per-task loop' "$f" | cut -d: -f1)
[ "$names" -lt "$first" ] && echo "ok: Names precedes First run" || echo "WRONG ORDER: Names must precede First run"
[ "$first" -lt "$loop" ] && echo "ok: First run precedes the loop" || echo "WRONG ORDER"
resume=$(grep -n '^## Resume' "$f" | cut -d: -f1)
sed -n "${first},$((loop-1))p" "$f" | grep -cE '^[0-9]+\. \*\*' | grep -qx 6 \
  && echo "ok: first run has 6 steps" || echo "WRONG: first-run step count is not 6"
sed -n "${loop},$((resume-1))p" "$f" | grep -cE '^[0-9]+\. \*\*' | grep -qx 8 \
  && echo "ok: loop has 8 steps" || echo "WRONG: loop step count is not 8"
```

Both counts are bounded by the next heading rather than running to end of file.
An unbounded count would inflate if any later section introduced a numbered list.

Row counts for the two tables, which the numeric assertions in Steps 6 and 7
otherwise only ask an implementer to trust:

```bash
f=plugins/soong/skills/develop/SKILL.md
sed -n '/^## Failure modes/,/^## Rules/p' "$f" | grep -c '^| ' | grep -qx 23 \
  && echo "ok: 21 failure-mode rows" || echo "WRONG: failure-mode row count"
sed -n '/^| Field |/,/^$/p' "$f" | grep -c '^| ' | grep -qx 11 \
  && echo "ok: 9 ledger field rows" || echo "WRONG: ledger field row count"
```

The specific clauses whose absence a plain "file exists" check would miss, each
one a wrong-outcome finding from a review round:

```bash
f=plugins/soong/skills/develop/SKILL.md
grep -qF -- '--base' "$f" && echo "ok: names --base" || echo "MISSING: --base, the stack would not stack"
grep -qF -- '--notion-card' "$f" && echo "ok: names --notion-card" || echo "MISSING: --notion-card"
grep -qF -- '--state all' "$f" && echo "ok: --state all" || echo "MISSING: --state all, a closed PR would open a second"
grep -qF 'git push -u origin' "$f" && echo "ok: pushes" || echo "MISSING: push, gh pr create would fail"
grep -qF '"worktree":' "$f" && echo "ok: ledger has a worktree field" || echo "MISSING: worktree field"
grep -qF '- The task is `stopped`' "$f" && echo "ok: stopped is a loop step 1 trigger" || echo "MISSING: stopped trigger"
grep -qF 'Do not resume it at any step' "$f" && echo "ok: stopped is settled" || echo "MISSING: stopped disposition"
```

Newline-tolerant checks, for sentences that wrap. A single-line literal for a
wrapped sentence is a false negative, which is how one such check failed on an
earlier branch in this repo:

```bash
f=plugins/soong/skills/develop/SKILL.md
flat=$(tr '\n' ' ' < "$f" | tr -s ' ')
for phrase in \
  'nothing is created and nothing is written until step 6' \
  'A name invented at creation time could not be recomputed' \
  'Never run in the worktree the user is sitting in'; do
  printf '%s' "$flat" | grep -qF "$phrase" \
    && echo "ok: $phrase" || echo "MISSING: $phrase"
done
```

- [ ] **Step 9: Commit**

```bash
git add plugins/soong/skills/develop/SKILL.md
git commit -m "feat(develop): add the develop skill"
```

---

## Chunk 2: The delegate and the caller

### Task 2: Add three arguments to manage-pr compose

**Files:**
- Modify: `plugins/soong/skills/manage-pr/reference/pr/compose.md`

Without `--base` every pull request in the stack targets the repository default
branch and the stacking is silently lost. This is the task the whole feature
depends on.

- [ ] **Step 1: Add the three arguments to the Arguments section**

The section currently documents only `--non-interactive`. Append these three
bullets after it, before the line beginning "When no argument is given":

```markdown
- `--base <branch>` — pass `--base <branch>` to `gh pr create`, and use `<branch>`
  as the base in step 1's `git log` and `git diff`. Absent, run `gh pr create` as
  it does today and let `gh` choose the default branch.
- `--notion-card <url-or-id>` — use this card in the PR record instead of
  resolving one. Absent, resolve as it does today. This does not license
  guessing: the caller supplies a card it already has, and the rule against
  inventing one is unchanged.
- `--draft` — pass `--draft` to `gh pr create`, opening the PR as a draft.
  Absent, open it ready for review, which is today's behavior.
```

- [ ] **Step 2: Bind the base in step 1**

Step 1 currently reads:

```markdown
1. Inspect the branch: `git log --oneline <base>..HEAD` and `git diff <base>...HEAD`
   so the title and description reflect **all** commits, not just the latest.
```

Replace it with:

```markdown
1. Inspect the branch: `git log --oneline <base>..HEAD` and `git diff <base>...HEAD`
   so the title and description reflect **all** commits, not just the latest.
   `<base>` is `--base` when it was passed, otherwise the repo's default branch.
   Binding it matters as much as binding it in the `gh` call: for a stacked PR,
   the base is the previous branch in the stack, and that diff is this PR's own
   change. Left unbound, a stacked PR would be described from the whole stack's
   diff.
```

- [ ] **Step 3: Pass the flags to gh**

Step 3 currently reads:

```markdown
3. Run `gh pr create` (or `gh pr edit`) passing the title and body via a HEREDOC.
```

Replace it with:

```markdown
3. Run `gh pr create` (or `gh pr edit`) passing the title and body via a HEREDOC.
   Add `--base <branch>` and `--draft` when those arguments were passed.
```

- [ ] **Step 4: Point the record at the supplied card**

In the PR record section, the `notionCard` bullet currently reads:

```markdown
- **notionCard** — the card resolved via the existing `manage-notion-page` flow; store
  `null` if none was resolved. Never invent one.
```

Replace it with:

```markdown
- **notionCard** — `--notion-card` when it was passed, otherwise the card resolved
  via the existing `manage-notion-page` flow; store `null` if none was resolved.
  Never invent one.
```

- [ ] **Step 5: Verify**

```bash
f=plugins/soong/skills/manage-pr/reference/pr/compose.md
for a in '--base' '--notion-card' '--draft'; do
  grep -qF -- "$a" "$f" && echo "ok: documents $a" || echo "MISSING: $a"
done
grep -qF '`<base>` is `--base` when it was passed' "$f" \
  && echo "ok: base is bound in step 1" || echo "MISSING: step 1 base binding"
grep -qF 'Add `--base <branch>` and `--draft` when those arguments were passed' "$f" \
  && echo "ok: flags reach gh" || echo "MISSING: flags never reach gh"
grep -qF '`--notion-card` when it was passed' "$f" \
  && echo "ok: record uses the supplied card" || echo "MISSING: record binding"
```

Then confirm nothing regressed for existing callers. Every new argument must be
described as optional with today's behavior as the default:

```bash
f=plugins/soong/skills/manage-pr/reference/pr/compose.md
grep -c 'Absent,' "$f" | grep -qx 3 \
  && echo "ok: all three default to today's behavior" \
  || echo "CHECK: expected 3 'Absent,' clauses"
```

- [ ] **Step 6: Run the PR-guard suite, which tests this skill's conventions**

The hook that guards PR titles and bodies has a test suite. This task changes the
skill the hook enforces, so the suite must still pass unchanged.

```bash
bash plugins/soong/hooks/scripts/pr-guard.test.sh
```

Expected: exit 0, and the same test count as on `main`. The suites live beside
their scripts as `*.test.sh`; there is no `tests/` directory. If the count
changed, stop and report: this task should not affect them.

- [ ] **Step 7: Commit**

```bash
git add plugins/soong/skills/manage-pr/reference/pr/compose.md
git commit -m "feat(manage-pr): add --base, --notion-card, and --draft to compose"
```

### Task 3: Retire the handoff document from architect

**Files:**
- Modify: `plugins/soong/skills/architect/SKILL.md`
- Modify: `README.md`

Five references across two files. Four are the word `handoff`; the fifth is the
`description` frontmatter, which is grep-clean for that word but is the text that
drives skill triggering.

- [ ] **Step 1: The description frontmatter**

Before:

```
description: Turn a feature request into a reviewed spec on a Notion roadmap item plus one Notion task per stacked PR, then hand off a prompt to start implementation. Use when the user runs /architect, or asks to plan, architect, or spec out a feature that should land as a stack of PRs on Notion. Requires the repo to be configured via architect-setup first.
```

After:

```
description: Turn a feature request into a reviewed spec on a Notion roadmap item plus one Notion task per stacked PR, then print the /develop command that implements it. Use when the user runs /architect, or asks to plan, architect, or spec out a feature that should land as a stack of PRs on Notion. Requires the repo to be configured via architect-setup first.
```

- [ ] **Step 2: The summary sentence**

Before:

```
Notion as a roadmap item plus one task per stacked PR. Ends with a handoff prompt.
```

After:

```
Notion as a roadmap item plus one task per stacked PR. Ends by printing the
`/develop` command that implements it.
```

- [ ] **Step 3: The Assumes list**

Before:

```
- The `superpowers` plugin (`superpowers:brainstorming`).
- The `handoff` skill.
- The Notion MCP.
```

After:

```
- The `superpowers` plugin (`superpowers:brainstorming`).
- The Notion MCP.
```

- [ ] **Step 4: Step 6**

Before:

```
## Step 6: Hand off

Invoke the `handoff` skill to write the handoff document, then give the user a single
copy-pasteable prompt that starts implementation of the stacked PRs in a fresh session.

The prompt names the roadmap item, the first task in the stack, the handoff doc path, and
the skills the next session needs. It starts implementation at the **first** PR, not the
whole stack at once.
```

After:

```
## Step 6: Hand off

Print one copy-pasteable line:

```
/develop <roadmap-item-url>
```

That is the whole handoff. `develop` reads the roadmap item and its tasks from
Notion, so it needs nothing else: no handoff document, and no prompt naming the
first task or the skills to use.

It starts the **whole stack**, not the first PR only. `develop` walks every task
in order, and asks whatever the task cards left open before it writes code.
```

- [ ] **Step 5: The Rules**

Before:

```
- Never implement. No code changes, in any step, including a step the user asks for
  mid-flow. Implementation is the next session's job.
```

After:

```
- Never implement. No code changes, in any step, including a step the user asks for
  mid-flow. Implementation belongs to `develop`, which may run in this same session.
```

- [ ] **Step 6: README**

Before:

```
- **handoff** — `/architect` uses it to write the handoff document for the next
  session.
```

After: delete both lines. They are a self-contained bullet between the
`superpowers` and `Notion MCP` entries, so deleting them leaves a valid list.
Nothing replaces them: `develop` needs no new requirement entry, because
`superpowers` and the Notion MCP are already listed.

- [ ] **Step 7: Verify no reference survives**

A bare `grep -rn 'handoff'` does **not** work here, and this is worth
understanding before writing a check of your own. Three correct pieces of prose
contain the word: Step 4's replacement text says "That is the whole handoff" and
"no handoff document", and Task 1 writes "it replaces the handoff document
`architect` used to end with" into the new skill. A check that flags those would
be unsatisfiable without rewording the deliverable, which this plan forbids.

Grep for the stale **constructs** instead. Note `handoff doc path`, not
`handoff doc`: the shorter pattern matches "handoff document" inside both
legitimate sentences, so it flags correct work exactly as a bare `handoff` grep
does. This pattern was tested in both directions, against the pre-edit files
where it must hit all five references, and against the post-edit text where it
must be silent:

```bash
grep -rEn '`handoff` skill|handoff doc path|handoff prompt|write the handoff document' \
  plugins/ README.md \
  && echo "STALE REFERENCE ABOVE" || echo "ok: no stale handoff reference"
```

Then the prose check, case-insensitively, because the heading is capitalized and
a case-sensitive grep would miss it and report success for the wrong reason:

```bash
grep -in 'hand off' plugins/soong/skills/architect/SKILL.md
```

Expected: exactly one hit, the `## Step 6: Hand off` heading, which stays. Zero
hits means Step 4 removed the heading, which it should not. Two or more means
stale prose survives.

```bash
f=plugins/soong/skills/architect/SKILL.md
grep -qF '/develop <roadmap-item-url>' "$f" && echo "ok: prints /develop" || echo "MISSING: /develop"
grep -qF 'print the /develop command' "$f" && echo "ok: description updated" || echo "MISSING: description"
grep -c '^## Step' "$f" | grep -qx 7 && echo "ok: still 7 steps" || echo "CHECK: step count changed"
```

- [ ] **Step 8: Run the architect-setup suite**

This task touches the skill that reads that config.

```bash
bash plugins/soong/skills/architect-setup/scripts/architect-setup.test.sh
```

Expected: exit 0, unchanged.

- [ ] **Step 9: Commit**

```bash
git add plugins/soong/skills/architect/SKILL.md README.md
git commit -m "feat(architect): hand off to /develop instead of a handoff document"
```

---

## Chunk 3: Release and verification

### Task 4: Bump the version

**Files:**
- Modify: `plugins/soong/.claude-plugin/plugin.json`

- [ ] **Step 1: Bump the minor version**

A feature, so the minor version. `0.8.0` becomes `0.9.0`.

```bash
f=plugins/soong/.claude-plugin/plugin.json
python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
assert d["version"] == "0.8.0", f"expected 0.8.0, found {d['version']}"
d["version"] = "0.9.0"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
print("bumped to", d["version"])
PY
```

If the assert fires, another change landed first. Stop and report the version
found rather than bumping from an unexpected base.

- [ ] **Step 2: Verify the file is still valid JSON and nothing else moved**

```bash
f=plugins/soong/.claude-plugin/plugin.json
python3 -c "import json;print(json.load(open('$f'))['version'])" | grep -qx 0.9.0 \
  && echo "ok: 0.9.0" || echo "WRONG version"
git diff --stat "$f"
```

Expected: one file, one insertion, one deletion. More than that means the
rewrite reformatted something; check the diff before committing.

- [ ] **Step 3: Commit**

```bash
git add plugins/soong/.claude-plugin/plugin.json
git commit -m "chore(release): bump soong to 0.9.0"
```

### Task 5: Verify the whole change

**Files:** none. This task only reads and reports.

Report every check with its actual output. Do not fix anything found here; report
it. A defect at this stage may be in this plan rather than in the work.

- [ ] **Step 1: Every structural check from every task, re-run together**

Re-run the verification blocks from Task 1 Step 8, Task 2 Step 5, Task 3 Step 7,
and Task 4 **Step 2**. All must pass on the final state, not just at the moment
each task ran.

Task 4 Step 2, not Step 1: Step 1 is the mutation, and its
`assert d["version"] == "0.8.0"` fires once the bump has landed. Running it again
stops on a spurious assert.

- [ ] **Step 2: The three pre-existing test suites**

All three live beside their scripts:

```bash
bash plugins/soong/hooks/scripts/pr-guard.test.sh
bash plugins/soong/skills/architect-setup/scripts/architect-setup.test.sh
bash plugins/soong/skills/walkthrough/scripts/gather-context.test.sh
```

All three must exit 0. `pr-guard` reports **60 passed**; the other two print
"all checks passed" without a count. This change adds no script, so any change
in those outputs is a finding. Find them yourself rather than trusting this list
if one is missing:

```bash
find plugins -name '*.test.sh'
```

- [ ] **Step 3: The changed-file set**

```bash
git diff --stat origin/main..HEAD
```

Expected exactly seven paths: the four under `plugins/`, `README.md`, and the two
docs (this plan and the spec). Confirm `marketplace.json` is **not** among them.
Report the actual list.

- [ ] **Step 4: The static checklist**

Read `plugins/soong/skills/develop/SKILL.md` end to end and confirm each of
these. Report each as pass or fail with a quote:

1. `## Names` appears before `## First run`, and defines both the branch and the
   worktree name.
2. First run has six steps, in order, and says nothing is written until step 6.
3. The loop has eight steps, and step 1 is the interrupted-work check.
4. Loop step 7 names all four compose arguments.
5. The interrupted-work path distinguishes three states and uses `--state all`.
6. `stopped` is a loop step 1 trigger and is settled in the interrupted section.
7. The ledger's field table has nine rows, and every field in the JSON shape
   appears in it.
8. The Rules forbid force-pushing, batching two tasks into one PR, and writing to
   a card body.

- [ ] **Step 5: The behavioral scenarios, and their honest status**

The spec lists eight behavioral scenarios. **None can be exercised without a live
run** against a real Notion roadmap item, real Notion databases, and a real
remote. Do not claim any of them passes.

For each of the eight, report exactly one of:

- **Statically checkable** — the instruction text exists and is unambiguous.
  Quote it.
- **Needs a live run** — the behavior depends on runtime state this task cannot
  produce. Say what state.

Report the split. Do not run a partial simulation and describe it as a pass. A
passing structural checklist that implies behavioral coverage is the exact trap
the spec's Verification section warns about.

- [ ] **Step 6: Report**

Write one summary: what passed, what needs a live run, and anything found that
looks like a defect in this plan rather than in the work. Do not commit; this
task changes nothing.

### Task 6: Open the pull request

**Files:** none.

- [ ] **Step 1: Confirm the tree is clean and the branch is current**

```bash
git status --short
git log --oneline origin/main..HEAD
```

- [ ] **Step 2: Push**

```bash
git push -u origin claude/develop-skill
```

- [ ] **Step 3: Open the PR via the manage-pr skill**

Invoke `soong:manage-pr` in compose mode. Base is `main`. Not a draft unless the
user asks.

The body must state plainly that **none of the eight behavioral scenarios has
been exercised**, and which of them need a live run. It must not let the passing
structural checks imply behavioral coverage.

That skill's own rules govern the title and body. Read them there rather than
guessing: it forbids footers and attribution tags of every kind, and it forbids
guessing a Notion ticket id.

- [ ] **Step 4: Write the PR record**

Per the compose reference's PR record section. `notionCard` is `null` unless a
real card applies; never invent one.

---

## Notes for whoever executes this

**What this plan does not do.** It writes no code, because the deliverable is
prose. Every "test" here is a `grep` or a read. That is a real limit: a `grep`
confirms a rule is *written*, not that it is *reachable*, *supplied*, or
*honored downstream*. Five review rounds on the spec found 27 findings and
**every one of them** was of that class, living at a seam between two files
rather than inside either. Task 5's static checklist exists because greps cannot
see those, and even it cannot see all of them.

**The one thing most likely to go wrong.** Task 1 transcribes several hundred
lines of prose. The failure mode is not a typo; it is a dropped clause that no
check in this plan looks for. When in doubt, copy more rather than less, and if a
sentence seems redundant, keep it: several were added specifically because a
review round found a stated behavior unreachable without them.
