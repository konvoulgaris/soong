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
- A change to `architect` Step 6: print `/develop <url>` instead of writing a
  handoff document.
- A ledger file so a stopped stack resumes instead of restarting.

**Out of scope**

- No new agent. The judging and reviewing agents this stack already has are
  enough.
- No changes to `merge`, `rebase`, `sync-pr-to-notion`, `manage-pr`,
  `adversarial-council`, or `architect-cobrain`.
- No new script. This skill is prose plus delegation, so the existing test
  suites stay untouched.
- No Notion schema requirement. The stack order is read from what `architect`
  already writes.

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

Decision 3 is the one the whole design turns on. The user's attention is spent
in a single sitting at the start, not N times through the stack. Decision 4
exists because decision 3 buys that at a price: an answer given before task 1
existed can be wrong by task 4, and the re-check is what keeps a stale answer
from propagating up a stack that amplifies a bad base.

Decision 7 was chosen as "also sync descriptions per task" and then reversed by
the user. Nothing writes to a card body. `architect` wrote that content
deliberately, and `sync-pr-to-notion` stays a thing the user runs by hand.

## Architecture

`develop` owns three things:

1. **The loop.** Tasks in stack order, one at a time.
2. **The ledger.** What got built, on which branch, as which pull request, and
   where to resume.
3. **Notion status.** One status field per card, on pull request open.

Everything else is delegated, unchanged:

| Step | Skill |
| --- | --- |
| Gap questions, on the main thread | `superpowers:brainstorming` |
| Per-task plan | `superpowers:writing-plans` |
| Implementation and its two review stages | `superpowers:subagent-driven-development` |
| Pull request title, body, and record | `soong:manage-pr` |

The gap questions run on the main thread because a subagent cannot reach the
user. `architect` Step 2 already says this, for the same reason.

## Startup

Nothing is created and nothing is written until step 5. Every earlier step can
stop for free.

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

   The two must agree on count, and each list entry must correspond to a task.
   They disagree, stop. Show both lists side by side and ask. Building a stack in
   the wrong order is expensive to undo, because every later branch sits on the
   wrong base.

3. **Apply skips.** For each task named in `--skip`, walk the "stacks on" chain
   across all tasks. Any unskipped task that depends on a skipped one blocks the
   skip: refuse, name every blocking dependent, and offer the two fixes, which
   are to skip those too or to not skip at all.

   This runs before any branch exists, so a refused skip costs one message.

4. **The gap pass.** Read every task card, skipped ones excluded. Per task, list
   what implementing it needs and the card does not answer.

   Show the whole list, including the tasks with no gaps, so the user can add a
   question the pass missed. A missed gap becomes a subagent's guess.

   Any gaps, invoke `brainstorming` for the questions. One question at a time, on
   the main thread. Answers are recorded in the ledger against their task.

   No second spec document. The card is the spec, and `architect` already ran the
   spec review loop over it.

5. **Create the worktree.** One worktree for the whole stack, off `main`.

   Never run in the worktree the user is sitting in: branches advance in place
   here, and swapping a branch under an open editor is the failure this avoids.

## The per-task loop

For each task in stack order, in that one worktree:

1. **Branch.** Off the previous task's branch. Task 1 branches off `main`. Name
   it `claude/<slug>` from the task title.

2. **Re-check the answers.** Read the diff the stack has built so far and check
   this task's recorded gap answers against it. An answer the built code
   contradicts stops the loop: record `stopped` in the ledger with which answer
   and what contradicts it, and leave every later task `pending`.

   Nothing contradicted, continue without asking. This is the common case, and it
   is what keeps the stack unattended.

3. **Plan.** Invoke `superpowers:writing-plans` from the card plus its recorded
   answers.

4. **Implement.** Invoke `superpowers:subagent-driven-development` on that plan.
   Its own two stages, spec compliance then code quality, are the quality gate.
   This skill adds no review of its own and skips neither of those.

5. **Open the pull request.** Invoke `soong:manage-pr` in compose mode with
   `--non-interactive`, based on the previous task's branch. Never `--draft`
   unless the user asked for a draft.

   `subagent-driven-development` normally ends by invoking
   `finishing-a-development-branch`. Do not follow that here. This step is the
   finish for one task, and the stack continues.

6. **Record it.** Write the ledger entry. Write `notionCard` into the pull
   request record so `sync-pr-to-notion` works later without the `gh` CLI.

   Then set the card's status. Read the card's own status options through the
   Notion MCP and pick the matching one. Nothing matches, skip the status write
   and say so. Never guess a Notion value: these writes do not reverse.

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
            "status": "pending | done | stopped",
            "branch": "<branch-or-null>",
            "pr": "<url-or-null>",
            "stoppedBecause": "<reason-or-null>"
          }
        },
        "worktree": "<path>",
        "updatedAt": "<iso8601>"
      }
    }
  }
  ```

Re-invoking `/develop` on the same roadmap link reads the ledger, reports what
is already built, and resumes at the first task that is not `done`. It re-runs
neither the gap pass nor any finished task.

Two things it deliberately does not do:

- **No automatic retry of a stopped task.** A stop means something needs the
  user, so retrying without them is a loop.
- **No worktree cleanup.** The user may want to inspect it, which is the same
  reason `finishing-a-development-branch` keeps a worktree on the pull request
  path.

## Failure modes

| Failure | Behavior |
| --- | --- |
| Repo unconfigured, exit 3 | Invoke `architect-setup`, re-check, stop on non-zero |
| Notion MCP unreachable | Stop at startup. No worktree, no branch |
| Roadmap list and task query disagree | Stop, show both, ask. No branch created |
| A skip later tasks depend on | Refuse, name the dependents. No branch created |
| A gap answer the built code contradicts | Stop at that task, ledger records why. Later tasks stay `pending` |
| `subagent-driven-development` reports BLOCKED | Stop at that task. Never re-dispatch it unchanged, and never hand-fix it on the main thread |
| No matching card status option | Skip the status write, say so, continue |
| The pull request guard hook denies `gh` | Fix the title or body per its reason and retry. Never bypass it |

## Rules

- Never run in the worktree the user is sitting in.
- One task, one branch, one pull request. Never batch two tasks into one.
- A task's base is the previous task's branch. Only task 1 is based on `main`.
- Never force-push. Each task's branch is only appended to.
- Never open a draft unless the user asked.
- Never skip either review stage, and never substitute a main-thread read for
  one.
- Notion writes do not reverse. Status is the only card write, and the body is
  never touched.
- Never guess a Notion status value, a card id, or a database id.

## Changes to architect

Four references to the `handoff` skill go away.

- **Line 10**, the summary sentence: it ends with a handoff prompt today, and
  ends by printing the `/develop` command instead.
- **Line 17**, the Assumes list: drop `handoff`.
- **Step 6**, lines 160 through 167: replace the handoff document with a single
  printed line, `/develop <roadmap-item-url>`.

Step 6 keeps its shape. It is still the last step, and it still hands the user
one copy-pasteable thing. What changes is that the thing is a command rather
than a prompt plus a document, and that it starts the **whole stack** rather
than the first pull request only.

## Verification

There is no test framework for a markdown skill. The repo's suites cover the
bash scripts, `pr-guard`, `architect-setup`, and `gather-context`, and this
change adds no script, so those suites stay green and untouched.

**Structural**, greppable:

- `plugins/soong/skills/develop/SKILL.md` exists, with `name: develop` and a
  description that triggers on `/develop`.
- Startup steps appear in order, 1 through 5.
- `architect` has no remaining reference to the `handoff` skill, and Step 6
  contains `/develop`.
- `plugin.json` version bumped to `0.9.0`, a minor bump for a feature.

**Behavioral.** These need a live run against a real roadmap item to exercise.
They are unexercised until then, and a passing structural check must not be read
as covering them:

1. A clean stack, no gaps, N tasks, produces N stacked pull requests with each
   based on the previous task's branch.
2. Gaps present asks every question up front, one at a time, then runs
   unattended.
3. A roadmap list that disagrees with the task query stops before any branch
   exists.
4. A skip that later tasks depend on is refused, and the refusal names them.
5. A gap answer contradicted at task 4 stops there, records why, and leaves
   tasks 5 and up untouched.
6. Re-invoking after that stop resumes at task 4 and rebuilds nothing.
7. A card whose status options do not match skips the status write and says so.
