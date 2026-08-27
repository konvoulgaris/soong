# develop skill design

A skill that takes a Notion roadmap item and builds its whole task stack as
stacked pull requests, in one session.

`architect` plans. `develop` implements. This skill is the second half, and it
replaces the handoff document that `architect` currently ends with.

## Goal

One command, `/develop <roadmap-item-notion-link>`, walks every task on that
roadmap item and lands each one as its own reviewable pull request, based on the
previous task's branch. The user answers questions once, up front, and then the
stack builds unattended.

## Scope

**In scope**

- A new skill at `plugins/soong/skills/develop/SKILL.md`.
- Three new arguments on `manage-pr` compose mode: `--base`, `--notion-card`, and
  `--draft`.
- A change to `architect` Step 6: print `/develop <url>` instead of writing a
  handoff document.
- A ledger file so a stopped stack resumes instead of restarting.

**Out of scope**

- No new agent. The reviewing agents this stack already has are enough.
- No changes to `merge`, `rebase`, `sync-pr-to-notion`, `adversarial-council`, or
  `architect-cobrain`.
- No new script. This skill is prose plus delegation, so the existing test
  suites stay untouched.
- No Notion schema requirement. The stack order is read from what `architect`
  already writes.

## Arguments

```
/develop <roadmap-item-notion-link> [--skip <task-title>]... [--draft]
```

- **`<roadmap-item-notion-link>`** — required, first positional. A Notion URL or
  page id for the roadmap item. This is the ledger key, so the same link resumes
  the same stack.
- **`--skip <task-title>`** — repeatable. The task's **title**, matched against
  the task pages resolved in startup step 2, case-insensitively and ignoring
  surrounding whitespace. A title that matches no task, or more than one, stops
  before anything is created. Titles are resolved to page ids at that point, and
  the ledger stores ids only.
- **`--draft`** — open every pull request in the stack as a draft. Off by
  default, and the only thing that turns it on.

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

## Decisions

| # | Question | Chosen | Rejected |
| --- | --- | --- | --- |
| 1 | What runs per task | Orchestrate, delegating to existing skills | Implement inline; dispatch one subagent per task |
| 2 | How the stack order is resolved | Roadmap ordered list, cross-checked against a task query | Parse "stacks on" alone; require a new order property |
| 3 | When the user is asked | One gap pass up front, whole stack | Full brainstorming per task; gap check per task |
| 4 | A gap answer that no longer fits | Re-check per task, stop only on contradiction | Always stop mid-stack; proceed and flag it |
| 5 | Git shape | One worktree for the stack, branches advance in place | One worktree per task; conditional isolation |
| 6 | Task exclusion | Refuse a skip that later tasks depend on | Collapse the gap; build dependents anyway |
| 7 | Notion writeback | Record the card, set status only | Also sync descriptions per task; record the id alone |
| 8 | Who asks the gap questions | This skill asks them inline | Invoke `superpowers:brainstorming` |
| 9 | How a stacked base reaches `gh` | Add `--base` to `manage-pr` compose | Run `gh pr create` from this skill |

Decision 3 is the one the whole design turns on. The user's attention is spent
in a single sitting at the start, not N times through the stack. Decision 4
exists because decision 3 buys that at a price: an answer given before task 1
existed can be wrong by task 4, and the re-check is what keeps a stale answer
from propagating up a stack that amplifies a bad base.

Decision 7 was chosen as "also sync descriptions per task" and then reversed by
the user. Nothing writes to a card body. `architect` wrote that content
deliberately, and `sync-pr-to-notion` stays a thing the user runs by hand.

Decision 8 replaces an earlier plan to invoke `brainstorming` for the questions.
That skill's checklist is nine mandatory items ending in a written design
document, its own review loop, a user approval gate, and a terminal jump to
`writing-plans`; and invoking it fires a hook that demands a worktree as the
very first action. All of that had to be suppressed to leave the one behavior
this skill wants, which is asking recorded questions one at a time. Asking them
inline is that behavior with nothing to suppress. `adversarial-council` already
questions the user on the main thread without borrowing a skill.

Decision 9 is what makes the stack a stack. `manage-pr` compose runs
`gh pr create`, and `gh pr create` with no `--base` targets the repository's
default branch, so without this every pull request in the stack would point at
`main` and the stacking would be silently lost.

## Architecture

`develop` owns four things:

1. **The loop.** Tasks in stack order, one at a time.
2. **The gap questions.** Asked inline, on the main thread, one at a time.
3. **The ledger.** What got built, on which branch, as which pull request, and
   where to resume.
4. **Notion status.** One status field per card, on pull request open.

The rest is delegated:

| Step | Skill |
| --- | --- |
| Per-task plan | `superpowers:writing-plans` |
| Implementation and its two review stages | `superpowers:subagent-driven-development` |
| Pull request title, body, and record | `soong:manage-pr` |

The gap questions are asked by this skill rather than delegated, because a
subagent cannot reach the user and `brainstorming` cannot be reduced to just its
question loop. See decision 8.

## First run

A run is a **first run** when the ledger has no entry for this roadmap item, and
a **resume** when it does. The two paths differ, so they are specified
separately. Resume is below.

On a first run, nothing is created and nothing is written until step 6. Every
earlier step can stop for free.

1. **Check configuration.** Run the same script `architect` Step 1 runs:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/architect-setup/scripts/architect-setup.sh" get
   ```

   Exit 0 continues. Exit 3 means this repo is unconfigured: invoke
   `architect-setup`, then run `get` again and stop on anything non-zero. Exit 1
   is a corrupt config, exit 2 is not a git repository. Both stop.

   Confirm the Notion MCP is reachable in this step, rather than finding out at
   task 4 that the stack has nowhere to report.

2. **Resolve the stack.** Two sources, cross-checked:

   - **Order** comes from the ordered list in the roadmap item body. That list is
     positional, so it is the authority on sequence.
   - **Page ids** come from querying `taskDb` for tasks linked to the roadmap
     item. A prose list cannot give a page id.

   Check two things, in this order:

   - **Count.** The list has as many entries as the query returned. This is
     exact, and a mismatch stops.
   - **Correspondence.** Each list entry maps to exactly one task page. This is
     a judgment call, not a string equality: `architect` writes list entries
     naming a scope and a dependency, and task titles naming a single change, so
     the two describe the same work in different words. Map on the work
     described. Any entry that maps to no task, or to more than one, stops.

   On a stop, show the two lists side by side, say which entries could not be
   mapped, and ask. Do not guess an order. Building a stack in the wrong order is
   expensive to undo, because every later branch sits on the wrong base.

3. **Resolve and validate skips.** For each `--skip` title, match it to a task
   per the Arguments rules. Then, for each matched task, walk the "stacks on"
   statement on every unskipped task. Any unskipped task that depends on a
   skipped one, directly or transitively, blocks the skip: refuse, name every
   blocking dependent, and offer the two fixes, which are to skip those too or to
   not skip at all.

   **Known ceiling.** `architect` writes linear stacks, so in practice a skip is
   accepted only for a contiguous tail of the stack, and refused for anything
   with work above it. That is the intended behavior and not a defect: the refusal
   is what stops a task from being built on a base that was never created. Say so
   plainly in the refusal, so the user is not left guessing why a middle task
   cannot be skipped alone.

   This step reads the "stacks on" prose that decision 2 declined to trust for
   **ordering**. Trusting it for **dependency** is deliberate: ordering has a
   better source in the roadmap list, and dependency has none. A "stacks on"
   statement that names no task, on any task, stops this step rather than being
   read as "depends on nothing".

   Skips are validated before any branch exists, so a refused skip costs one
   message.

4. **The gap pass.** Read every task card, skipped ones excluded. Per task, list
   what implementing it needs and the card does not answer.

   Show the whole list, including the tasks with no gaps, so the user can add a
   question the pass missed. A missed gap becomes a subagent's guess.

   Then ask the questions **inline, one at a time**, on the main thread. Do not
   invoke `brainstorming`; see decision 8. Do not batch the questions into one
   message, and do not write a design document. The card is the spec, and
   `architect` already ran the spec review loop over it.

   Hold the answers in the conversation for now. They are written to the ledger in
   step 6, because this step must stay free to stop.

5. **Create the worktree.** One worktree for the whole stack, off `main`.

   The worktree's path is derived, per **Names** above, so it is the same for
   every run of this roadmap item. Check `git worktree list` for that exact path
   before creating one. A previous run can have died between this step and step 6,
   leaving a worktree on disk with no ledger entry to point at it. Reuse it and
   say so. Without this check that run's worktree is orphaned and a second one is
   created beside it.

   That crash also means the gap questions get asked again, since a run with no
   ledger entry is a first run by definition. Say plainly that the earlier answers
   were lost, rather than re-asking as though nothing happened.

   Confirm the worktree directory is ignored before creating anything inside it.
   This repository ignores `.claude/worktrees/` through `.git/info/exclude`, which
   is local to one clone and never travels with it, so a fresh clone would leave
   the path untracked rather than ignored. Add it to `.gitignore` and commit that
   if it is not already ignored there.

   Never run in the worktree the user is sitting in: branches advance in place
   here, and swapping a branch under an open editor is the failure this avoids.

6. **Write the ledger entry.** Create the entry for this roadmap item: the
   resolved order, the resolved skip ids, the answers from step 4, the worktree
   path from step 5, and every unskipped task at `pending`, with its **derived
   branch name** recorded and its pull request null.

   Record the branch name now, at the one point where every task title is in
   hand, rather than leaving it to be re-derived later. A resume reads `order`
   from the ledger and re-queries Notion only to confirm the tasks still exist,
   so it never has the titles; and a card retitled between runs would derive a
   different name and orphan the branch the earlier run created. The name is
   recorded before any branch exists, so it is a plan, not a claim that the
   branch is there.

   This is the first write of the run, and it is what makes the run resumable.

## The per-task loop

For each unskipped task in stack order, in that one worktree:

1. **Check for interrupted work, before branching.** Read this task's branch
   name from the ledger, where first-run step 6 recorded it. Every task has one
   from the moment the entry exists, whether or not the branch itself does.

   Go to "A task that was interrupted" and resolve it there first if any of these
   holds:

   - The task is `in-progress`.
   - The task is `stopped`. The ledger promises no automatic retry, so a stopped
     task is never resumed by falling through to the next step.
   - The task is `pending` and its recorded branch already exists in the
     repository. That combination means a previous run created the branch and
     died before marking it.

   None of those, continue. This check owns the collision, and step 3's re-check
   and everything after it assume a branch this run created.

2. **Branch.** Create the recorded branch off the previous unskipped task's
   branch. The first task built is based on `main`.

   Mark the task `in-progress` before any work happens on it. The branch name is
   already recorded, so this writes the status only.

3. **Re-check the answers.** Read the diff the stack has built so far,
   `git diff main...HEAD`, and check this task's recorded answers against it.

   An answer is **contradicted** when the built code makes it false or
   impossible, not when it merely went unused. Two worked examples:

   - *Contradicted.* The answer said the new setting is read from a config file.
     Task 2 shipped the setting as a required environment variable and deleted the
     config reader. The answer is now impossible to honor.
   - *Not contradicted.* The answer said to name the flag `--verbose`. Nothing
     built so far names any flag. The answer is untouched, so the loop continues
     without asking.

   A contradiction stops the loop: record `stopped` in the ledger with which
   answer and what contradicts it, and leave every later task `pending`.

   This check is a no-op on the first task built, where the diff is empty. That
   is expected, since an answer cannot be contradicted by nothing.

4. **Plan.** Invoke `superpowers:writing-plans` from the card plus its recorded
   answers.

   The plan file it writes is a working artifact, not a deliverable. Write it
   outside the repository, under the session scratchpad, so it never appears in
   any pull request's diff. `writing-plans` runs its own per-chunk review loop;
   let it, and do not skip it.

5. **Implement.** Invoke `superpowers:subagent-driven-development` on that plan.
   Its own two stages, spec compliance then code quality, are the quality gate.
   This skill adds no review of its own and skips neither of those.

   That skill normally ends by invoking `finishing-a-development-branch`. Do not
   follow that transition. Steps 6 through 8 here are the finish for one task, and
   the stack continues.

   It also dispatches a final reviewer over the whole implementation before that
   transition. Let that run: per task it reviews the stack as built so far, which
   is the state the next task will build on. It is a third review this skill
   inherits rather than adds, and it is not one of the two per-task stages, so
   the rule against skipping those does not cover it.

6. **Push the branch.** `git push -u origin <branch>`. `gh pr create` cannot open
   a pull request for a branch the remote does not have.

   This is its own step because a run can die between it and the next one, and
   the interrupted-work path has to tell those two states apart.

7. **Open the pull request.** Invoke `soong:manage-pr` in compose mode with:

   - `--non-interactive`, because the stack is meant to run unattended.
   - `--base <previous unskipped task's branch>`, or `main` for the first task
     built. This is the same base step 2 branched from, read from the ledger, not
     recomputed. Without it the pull request would target the repository default
     branch and the stack would not be a stack.
   - `--notion-card <this task's page url>`, so compose writes the card into the
     pull request record itself rather than this skill overwriting the record
     afterward.
   - `--draft` only if the user passed `--draft`.

8. **Record it.** Mark the task `done` in the ledger with its branch and pull
   request url.

   Then set the card's status. Read the card's own status options through the
   Notion MCP and pick the matching one. Nothing matches, skip the status write
   and say so. Never guess a Notion value: these writes do not reverse.

## Resume

A run is a resume when the ledger already has an entry for this roadmap item.
Report what is already built, then continue. The differences from a first run:

- **Step 1, configuration:** runs unchanged. Cheap, and the config can have
  changed.
- **Step 2, resolve the stack:** the ledger's `order` wins. Re-query Notion only
  to confirm every task in `order` still exists. A task that vanished stops the
  resume. A task that Notion has and the ledger does not is **reported, not
  added**: the stack in progress was planned around the order it started with,
  and appending to it mid-flight would build the new task on an arbitrary base.
  Say it was found and skipped, and that re-running from a fresh ledger entry
  would include it.
- **Step 3, skips:** the ledger's `skipped` wins. A `--skip` on a resume that
  does not match the recorded set stops rather than silently re-deciding: say
  which set is recorded and let the user choose.
- **`--draft` on a resume:** the ledger's `draft` wins, so the stack stays
  consistent with the pull requests already opened. A `--draft` that disagrees
  with the recorded value is reported and ignored, not applied to the remaining
  tasks: half a stack of drafts is worse than either whole. Say which value is
  recorded, so the user can act on it themselves.
- **Step 4, the gap pass:** does not run. The answers are in the ledger.
- **Step 5, the worktree:** reuse the recorded path. Verify it exists and is a
  worktree of this repository. Missing, because the user removed it, create a new
  one off `main`, record the new path, and say so, since the branches themselves
  survive in the repository.
- **Step 6, ledger entry:** already exists. Update, do not overwrite.

Then enter the loop at the first task that is not `done`, and rebuild nothing
below it.

### A task that was interrupted

This section covers two dispositions that loop step 1 routes here: a task a
previous run died inside, and a task that `stopped` deliberately. The second is
settled at the end and never resumed. For the first, the ledger cannot say how
far the run got, because it died before writing that down, so establish the state
from git and `gh` rather than from the ledger.

Establish two facts, in this order. Check the branch out first, so both commands
read the right branch.

```bash
gh pr list --head <branch> --state all --json number,url,state   # any pull request?
git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 \
  && git log --oneline '@{u}'..HEAD                              # unpushed commits?
```

Query `--state all`, not `--state open`: a pull request closed or merged between
runs is not the same as no pull request, and treating it as one would open a
second pull request for the same task.

**Unpushed commits** means either that `git rev-parse` failed, so the branch has
no upstream and nothing is pushed, or that `git log` printed something. Push
before doing anything else in the first two cases below, because a stale remote
makes the next task branch off a tip that was never published.

That gives three states, each resumed at a different step:

- **An open pull request exists.** The run died between opening it and recording
  it. Do not re-run the earlier steps and do not call `gh pr create` again, which
  fails on a branch that already has an open pull request. Push if there are
  unpushed commits, then do loop step 8 alone: record the found url and set the
  card status. Then continue to the next task.
- **Pushed, no open pull request.** The run died between the push and the pull
  request. The work is safe on the remote, so re-planning and re-implementing it
  would duplicate it. Push anything outstanding, then resume at loop step 7 and
  open the pull request.

  A pull request that `--state all` reports as **closed or merged** is not this
  state. Report it and stop: something outside this run acted on the branch, and
  opening a second pull request for the same task is not a decision to make
  unattended.
- **Nothing pushed.** The only genuinely ambiguous state: the commits are local
  and partial, and nothing outside this machine knows about them. Report what the
  branch contains and ask whether to continue on it or reset it.

Never delete the branch, force-push it, or start a second one. Only the last case
asks the user, because only there can guessing destroy work that is not
recoverable. The first two are recoverable precisely because the remote can still
see them.

A `stopped` task reaches this section too, and it is not an interruption: the
ledger records why it stopped, and the user has to resolve that before it can be
built. Report `stoppedBecause` and stop. Do not resume it at any step.

## The ledger

A stop at task 4 must not mean rebuilding tasks 1 through 3.

- **File:** `${XDG_STATE_HOME:-$HOME/.local/state}/soong/develop-ledger.json`.
  Regenerable state, so it shares a home with the pull request records rather
  than the `architect` config, and it is never committed.
- **Keyed** by project, then roadmap item id. The project name comes from the
  **common** git dir, never `--show-toplevel`, so every linked worktree of one
  repo shares one entry:

  ```bash
  common="$(git rev-parse --path-format=absolute --git-common-dir)"
  top="${common%/.git}"; top="${top%/}"; project="${top##*/}"
  ```

- **Shape:**

  ```json
  {
    "<project>": {
      "<roadmap-item-id>": {
        "order": ["<task-id>", "..."],
        "skipped": ["<task-id>"],
        "answers": { "<task-id>": [{ "question": "...", "answer": "..." }] },
        "tasks": {
          "<task-id>": {
            "status": "pending | in-progress | done | stopped",
            "branch": "<derived-at-entry-creation>",
            "pr": "<url-or-null>",
            "stoppedBecause": "<reason-or-null>"
          }
        },
        "worktree": "<path>",
        "draft": false,
        "updatedAt": "<iso8601>"
      }
    }
  }
  ```

Every field is written by a named step and read by a named step:

| Field | Written | Read |
| --- | --- | --- |
| `order` | First run step 6 | Resume step 2, the loop |
| `skipped` | First run step 6 | Resume step 3, the loop |
| `answers` | First run step 6 | Loop steps 3 and 4 |
| `tasks[].status` | First run step 6 at `pending`, then loop steps 2, 3, 8 | Resume, to find the first task not `done`; loop step 1 and the interrupted-work path |
| `tasks[].branch` | First run step 6, from the task title | Loop step 1 to detect an existing branch, step 2 to create it, steps 6 and 7 to push and to set `--base`, and the interrupted-work path |
| `tasks[].pr` | Loop step 8 | Reported on resume |
| `tasks[].stoppedBecause` | Loop step 3 | Reported on resume, by the interrupted-work path |
| `worktree` | First run step 6, and resume step 5 if recreated | Resume step 5, and every loop step, which all run inside it |
| `draft` | First run step 6 | Loop step 7 |

Merge into the file idempotently, the same way `manage-pr` writes the pull
request record, so a concurrent run on another repository cannot lose an entry.

Two things the ledger deliberately does not do:

- **No automatic retry of a stopped task.** A stop means something needs the
  user, so retrying without them is a loop.
- **No worktree cleanup.** The user may want to inspect it, which is the same
  reason `finishing-a-development-branch` keeps a worktree on the pull request
  path.

## Changes to manage-pr

Compose mode gains three arguments. All are additive, and all default to today's
behavior when absent, so every existing caller is unaffected.

- **`--base <branch>`** — pass `--base <branch>` to `gh pr create`. Absent, run
  `gh pr create` as it does today and let `gh` choose the default branch.

  This also binds the `<base>` placeholder already used in compose step 1, which
  is currently unbound, and binding it there matters as much as binding it in the
  `gh` call. Step 1 reads `git log --oneline <base>..HEAD` and
  `git diff <base>...HEAD` to draft the title and description. Bound to the
  previous task's branch, that is this task's own diff, which is what the pull
  request should describe. Left unbound while only the `gh` call is fixed, every
  pull request in the stack would be described from the whole stack's diff.
- **`--notion-card <url-or-id>`** — use this card in the pull request record
  instead of resolving one. Absent, resolve as it does today. This does not
  license guessing: the caller supplies a card it already has, and the existing
  rule against inventing one is unchanged.
- **`--draft`** — pass `--draft` to `gh pr create`, opening the pull request as a
  draft. Absent, open it ready for review, which is today's behavior. Compose has
  no draft argument today, so without this a caller asking for a draft would be
  silently ignored.

## Changes to architect

Five references to the `handoff` skill go away, across three files.

In `plugins/soong/skills/architect/SKILL.md`:

- **The `description` frontmatter**, which ends "then hand off a prompt to start
  implementation". This one is grep-clean for the word `handoff` but is the text
  that drives skill triggering, so it has to change with the rest.
- **Line 10**, the summary sentence: it ends with a handoff prompt today, and
  ends by printing the `/develop` command instead.
- **Line 17**, the Assumes list: drop `handoff`.
- **Step 6**, lines 160 through 167: replace the handoff document with a single
  printed line, `/develop <roadmap-item-url>`.
- **The Rules**, which say implementation is "the next session's job". `/develop`
  may now run in the same session, so this becomes a statement that `architect`
  itself never implements, which is the part that matters.

In `README.md`, the Requirements section lists `handoff` as a dependency
justified solely by `/architect` using it. That justification is gone, so the
entry goes.

Step 6 keeps its shape. It is still the last step, and it still hands the user
one copy-pasteable thing. What changes is that the thing is a command rather
than a prompt plus a document, and that it starts the **whole stack** rather
than the first pull request only.

## Failure modes

| Failure | Behavior |
| --- | --- |
| Repo unconfigured, exit 3 | Invoke `architect-setup`, re-check, stop on non-zero |
| Notion MCP unreachable | Stop at startup. No worktree, no branch, no ledger |
| Roadmap list and task query disagree on count or mapping | Stop, show both, ask. Nothing created |
| A `--skip` title matching no task or several | Stop. Nothing created |
| A skip later tasks depend on | Refuse, name the dependents, explain the tail-only ceiling. Nothing created |
| A "stacks on" statement naming no task | Stop at skip validation. Never read as "depends on nothing" |
| A gap answer the built code contradicts | Stop at that task, ledger records why. Later tasks stay `pending` |
| `subagent-driven-development` reports BLOCKED | Stop at that task. Never re-dispatch it unchanged, and never hand-fix it on the main thread |
| A branch that already exists at loop step 1 | Resolve it in the interrupted-task path. Never force-push and never start a second branch |
| An open pull request on an interrupted task's branch | Do loop step 8 alone. Never re-run `gh pr create` on it |
| An interrupted task pushed with no pull request | Resume at loop step 7. Never re-implement it |
| An interrupted task with unpushed commits and no pull request | Ask the user. The only state where guessing loses work |
| An interrupted task whose pull request was closed or merged elsewhere | Report it and stop. Never open a second one for the same task |
| A worktree path that is ignored only via `.git/info/exclude` | Add it to `.gitignore` and commit that first |
| A `stopped` task reached on resume | Report `stoppedBecause` and stop. Never retry it automatically |
| A worktree on disk with no ledger entry | Reuse it, say the earlier answers were lost |
| A `--draft` on a resume that disagrees with the ledger | Report it, keep the recorded value |
| A recorded worktree that is gone on resume | Create a new one off `main`, record it, say so |
| A task in Notion that the ledger's order lacks | Report it, do not add it to the running stack |
| No matching card status option | Skip the status write, say so, continue |
| The pull request guard hook denies `gh` | Fix the title or body per its reason and retry. Never bypass it |

## Rules

- Never run in the worktree the user is sitting in.
- One task, one branch, one pull request. Never batch two tasks into one.
- A task's base is the previous unskipped task's branch. Only the first task
  built is based on `main`.
- Never force-push. Each task's branch is only appended to.
- Never open a draft unless the user passed `--draft`.
- Never skip either review stage, and never substitute a main-thread read for
  one.
- Ask the gap questions inline, one at a time. Never batch them, and never write
  a design document for a task.
- Keep plan files out of the repository, so no pull request carries another
  task's plan.
- Notion writes do not reverse. Status is the only card write, and the body is
  never touched.
- Never guess a Notion status value, a card id, or a database id.

## Verification

There is no test framework for a markdown skill. The repo's suites cover the
bash scripts, `pr-guard`, `architect-setup`, and `gather-context`, and this
change adds no script, so those suites stay green and untouched.

**Structural**, greppable:

- `plugins/soong/skills/develop/SKILL.md` exists, with `name: develop` and a
  description that triggers on `/develop`.
- It has an `## Arguments` section naming the positional roadmap link, `--skip`,
  and `--draft`.
- First-run steps appear in order, 1 through 6, the loop's steps appear in order,
  1 through 8, with the interrupted-work check first, and a `## Resume` section
  exists.
- A `## Names` section defines both the branch and the worktree name, and it
  appears before the steps that use them.
- Its `manage-pr` invocation names `--base`, `--notion-card`, and `--draft`, and
  its ledger write names `worktree`. These are the specific defects a plain "the
  file exists" check would have missed.
- A push step exists before the pull request is opened.
- The interrupted-task path distinguishes three states: a pull request open,
  pushed without one, and not pushed.
- `manage-pr`'s compose reference documents `--base`, `--notion-card`, and
  `--draft`. A `--draft` the caller passes and the callee never accepts is the
  same defect as the original missing `--base`, one flag over.
- No `handoff` reference remains in `plugins/`, in `README.md`, or in
  `architect`'s description frontmatter, and `architect` Step 6 contains
  `/develop`.
- `plugin.json` version bumped to `0.9.0`, a minor bump for a feature.

**Behavioral.** These need a live run against a real roadmap item to exercise.
They are unexercised until then, and a passing structural check must not be read
as covering them:

1. A clean stack, no gaps, N tasks, produces N stacked pull requests with each
   based on the previous task's branch, verified by reading each pull request's
   base rather than assuming it.
2. Gaps present asks every question up front, one at a time, inline, then runs
   unattended.
3. A roadmap list that disagrees with the task query stops before any branch or
   ledger entry exists.
4. A skip that later tasks depend on is refused, and the refusal names them.
5. A gap answer contradicted at task 4 stops there, records why, and leaves
   tasks 5 and up untouched.
6. Re-invoking after that stop resumes at task 4, reuses the recorded worktree,
   does not re-ask the gap questions, and rebuilds nothing.
7. A card whose status options do not match skips the status write and says so.
8. A run interrupted mid-task resumes by asking about the existing branch rather
   than recreating or force-pushing it.
