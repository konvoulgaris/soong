---
name: architect
description: Turn a feature request into a reviewed spec on a Notion roadmap item plus one Notion task per stacked PR, then print the /develop command that implements it. Checks first whether the roadmap already holds overlapping work, and stops without writing anything if the user decides the request duplicates it. Use when the user runs /architect, or asks to plan, architect, or spec out a feature that should land as a stack of PRs on Notion. Requires the repo to be configured via soong-setup first.
---

# architect

Take a request, brainstorm it into a spec, get that spec reviewed by the
`architect-cobrain` agent, address the review with the user, then write the result to
Notion as a roadmap item plus one task per stacked PR. Ends by printing the
`/develop` command that implements it.

This skill plans. It does not implement.

## Assumes

- The `superpowers` plugin (`superpowers:brainstorming`).
- The `conflict-scout` agent, which queries Notion for overlapping work.
- The `architect-cobrain` agent, which reviews the spec at Step 3.
- The `adversarial-council` skill, which filters cobrain's findings at Step 3.5.
- The `soong-setup` skill, which Step 1 sends the user to when the repo is not
  configured for Notion.
- The Notion MCP.

## Step 1: Check configuration

Two calls. The first asks whether this repo is configured for Notion; the second
reads the ids.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" check notion
bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" get
```

**Step A, `check notion`:**

- **Exit 0** — go to Step B.
- **Exit 3** — this repo is not configured for Notion. Say so, then invoke the
  `soong-setup` skill with the `notion` capability. When setup finishes, run
  `check notion` again: exit 0 means go to Step B, anything else means **stop
  here**. Do not brainstorm and do not touch Notion on a non-zero code.
- **Exit 1** — an error, not an unconfigured repo: no `jq`, or a corrupt config
  file. Report the message and stop. Never re-run setup to "fix" a corrupt file;
  setup refuses to overwrite one.
- **Exit 2** — not inside a git repository, or a usage error. Report it and stop.

**Step B, `get`:** read `roadmapDb`, `taskDb`, and `taskTemplate` from the JSON.

A non-zero exit here is a bug, not a user problem, because Step A just confirmed
the keys exist. Report the exit code and stop. Do not run setup again: the state
that produced this is not one setup can resolve.

`check notion` exit 3 does not mean the repo has never been set up. It means the
Notion keys are missing, which is also true of a repo configured for commits
alone. Say "not configured for Notion", not "never set up".

Confirm the Notion MCP is reachable now, in this step, rather than discovering at
Step 5 that a finished spec has nowhere to go.

## Step 1.5: Check for work that already exists

Before brainstorming. Nothing has been spent yet, so this is the cheapest place
in this skill to abandon.

Dispatch `conflict-scout` (Agent tool, `subagent_type: conflict-scout`) with the
user's request, the `roadmapDb` and `taskDb` ids from Step 1, and the fact that
this is run 1.

**Nothing found:** say so in one line and go to Step 2.

**Candidates found:** show them and ask one question with three answers. If the
scout said its sweep was too broad, say so when you present them, and ask the
same question anyway. A too-broad sweep is weak evidence, not a fourth answer.

| Answer | What you do |
| ------ | ----------- |
| **Abandon** | Stop. Print the conflicting card URLs so the user can go look at them. Write nothing, brainstorm nothing. |
| **Build on top** | Go to Step 2 carrying the conflicting cards in as context. The spec then states what it extends and what it must not duplicate, and Step 5 names those cards in the new roadmap item's body. |
| **Proceed anyway** | Go to Step 2 as if nothing was found. Record the dismissed card ids for Step 2.5. |

Ask once, with all three options visible. Do not ask three yes-or-no questions.

## Step 2: Brainstorm the spec, on the main thread

Invoke `superpowers:brainstorming` and run it here, in the main thread, so the
back-and-forth actually reaches the user.

**Produce the spec only.** Brainstorming normally ends by invoking
`superpowers:writing-plans`; do not follow that transition. Stop once the design doc is
written and the user approves it. The implementation plan belongs to `develop`, which
Step 6 hands off to.

A worktree-first hook fires on `superpowers:brainstorming`. This skill writes no code, so
a worktree buys nothing here, and the spec doc plus the Notion pages are the only output.
Create one if the hook insists, but keep the spec path in the repo the config maps to.

Frame the design as a **stack of PRs** from the start:

- Each PR is small, self-contained, and reviewable on its own.
- Each PR leaves the branch working; no PR depends on a later one to make sense.
- The stack has an order, and each step names what it depends on.

## Step 2.5: Re-check for existing work, now that the spec exists

After the user approves the design, before the cobrain dispatch.

Dispatch `conflict-scout` again, with the spec, the pull request stack, the files
each pull request touches, the two database ids, the fact that this is run 2, and
the card ids the user dismissed at Step 1.5. This is far better input than Step
1.5 had, so it catches overlap a one-line request could not expose.

The same three answers, with two differences:

- **Cards dismissed with "proceed anyway" at Step 1.5 are not re-asked.** Asking
  twice about the same card trains the user to dismiss by reflex. That is why the
  dismissed ids are passed in.
- **"Build on top" here revises the spec rather than restarting the brainstorm.**
  Go back into the design with the conflicting cards as context, then run this
  step again on the revised spec.

Abandoning here still costs a brainstorm. It saves the cobrain dispatch, the
two-judge council, the Step 4 walk, and the irreversible Notion writes.

### These conflicts are not Step 4 findings

Do not fold them into the Step 4 queue. "Abandon this spec" is a decision, not a
fix to apply to a spec, and the Step 3.5 council can drop a finding. A dropped
"this duplicates an in-flight roadmap item" is exactly the swallowed blocker that
Step 4's notices exist to prevent.

### The dismissed set

The dismissed card ids live in this conversation, not in a file. `architect` has
no ledger, unlike `develop`, which needs one because it resumes across sessions.

The cost is real and worth stating: if this conversation is compacted between
Step 1.5 and Step 2.5, the set is lost and this step re-asks about a card the
user already dismissed. That is one redundant question in a rare case, against a
persistent store in every case.

Record page ids, not titles. Titles are editable and can collide.

## Step 3: Review with architect-cobrain

Dispatch the `architect-cobrain` agent (Agent tool, `subagent_type: architect-cobrain`)
with the approved spec.

The agent is a **reviewer only**. It writes nothing to Notion and edits no files. It
returns findings and recommended steps.

Give it, explicitly: the spec path, the proposed PR stack as a list, and the files or
globs each PR touches. Naming the files keeps the agent verifying rather than
rediscovering the codebase from zero.

## Step 3.5: Filter the findings with the council

Invoke the `adversarial-council` skill with cobrain's findings, the spec path,
the pull request stack, and the files each finding touches.

For that last one, use the finding's own **Where** field. Cobrain may give only
a spec section or a PR number there, so when a finding names no files, pass the
files that PR touches from Step 3. The verifier lens is only as good as this
input, and the architect lens is forbidden from reading the implementation, so a
verifier left to guess is not backstopped by the other judge.

The council sends the findings to two `adversarial-judge` agents on different
evidence, argues out the disagreements, and returns four things: the findings
that need a decision from the user, the fixes it applied to the spec on its own,
a notice for any `blocking` finding it dropped, and a count of the findings it
dropped silently.

The council can hand everything back instead of filtering. With no findings
there is nothing to filter. With more than eight it says the spec needs rework.
If both judges fail it reports the failure. In each case every finding comes
back unfiltered, and Step 4 walks them.

## Step 4: Address the review with the user, before Notion

Walk a queue **one at a time**. Which queue depends on Step 3.5:

* **The council returned a queue.** Walk it in the order the council gives.
* **The council handed the findings back unfiltered**, because they were over
  the cap or because both judges failed. Walk the full cobrain finding set, in
  the order cobrain returned them.

Before walking either queue, relay every notice the council gave for a
`blocking` finding it dropped, and its count of findings dropped silently. The
notices are not questions and do not wait for an answer, but a swallowed blocker
the user never hears about is the one thing the notice exists to prevent.

The council may mark a finding as conditional on another finding's answer. When
the earlier answer makes it moot, do not ask it. Say it was skipped and why. A
skipped finding counts as resolved for the rule below, because asking a question
the user has already answered by implication is the waste this filtering exists
to remove.

An empty council queue means the council resolved everything. Say so, relay the
notices and the count, list the fixes the council applied, and go to Step 5.
That path is the one where the user sees nothing else, so the notices matter
most there. An empty cobrain finding set means the same without a council.

For each finding in whichever queue you are walking:

1. Show the finding and its recommendation.
2. Give your own read: agree, disagree, or a different fix. A reviewer can be wrong,
   whether it was cobrain or a judge; say so when it is, with a reason.
3. Get the user's decision.
4. Apply accepted changes to the spec.

Do not batch the findings into one message, and do not proceed to Notion until every
finding is resolved.

Re-dispatch `architect-cobrain` only when a PR was added, removed, or re-ordered.
Changes inside a single PR's scope get resolved here, on the main thread. A re-dispatch
starts from an empty context, so pass the revised stack and what changed, not the whole
spec again. A re-dispatch produces a new finding set, so Step 3.5 runs again on it.

## Step 5: Write to Notion

Only after Step 4 finishes.

Use the `write-notion-content` skill for **everything** written to Notion. It governs
the prose; this skill governs the placement. Do not also apply
`write-technical-content`: that skill excludes Notion content and gives opposite
instructions on articles and sentence form.

**On the roadmap item** (in `roadmapDb`):

- The technical detail of the change: components and boundaries touched, new contracts
  or behavior, what gets restructured or removed, and why.
- A **mermaid diagram** when it earns its place, i.e. when it shows a new flow or a
  changed architecture more clearly than prose. Skip it for a change a sentence covers.
- The PR stack as an ordered list, each entry naming its scope and its dependency.
- When the user chose "build on top" at Step 1.5 or Step 2.5, the cards this work
  extends, by title and URL, and what this item does not duplicate.

**One task per PR** (in `taskDb`), created from `taskTemplate` when set, otherwise the
database's default template:

- Titled for the single change it makes.
- Scoped to one reviewable PR.
- Linked to the roadmap item, and stating which task it stacks on.
- Created in stack order.

Confirm the created pages back to the user with their URLs.

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

## Rules

- Never implement. No code changes, in any step, including a step the user asks for
  mid-flow. Implementation belongs to `develop`, which may run in this same session.
- Notion writes are not reversible by this skill. Once Step 5 creates pages, undoing
  them is manual, so treat the Step 4 gate as the last checkpoint.
- If Step 5 fails partway, say which pages exist before retrying. Re-running it creates
  duplicates; there is no idempotency key.
