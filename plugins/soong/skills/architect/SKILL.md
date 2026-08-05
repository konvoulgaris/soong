---
name: architect
description: Turn a feature request into a reviewed spec on a Notion roadmap item plus one Notion task per stacked PR, then hand off a prompt to start implementation. Use when the user runs /architect, or asks to plan, architect, or spec out a feature that should land as a stack of PRs on Notion. Requires the repo to be configured via architect-setup first.
---

# architect

Take a request, brainstorm it into a spec, get that spec reviewed by the
`architect-cobrain` agent, address the review with the user, then write the result to
Notion as a roadmap item plus one task per stacked PR. Ends with a handoff prompt.

This skill plans. It does not implement.

## Assumes

- The `superpowers` plugin (`superpowers:brainstorming`).
- The `handoff` skill.
- The Notion MCP.

## Step 1: Check configuration

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/architect-setup/scripts/architect-setup.sh" get
```

- **Exit 0** — read `roadmapDb`, `taskDb`, and `taskTemplate` from the JSON. Continue.
- **Exit 3** — this repo is not configured. Say so, then invoke the `architect-setup`
  skill. If setup stops without writing a mapping, **stop here too**; do not brainstorm
  and do not touch Notion.
- **Exit 1 or 2** — report the error and stop.

## Step 2: Brainstorm the spec, on the main thread

Invoke `superpowers:brainstorming` and run it here, in the main thread, so the
back-and-forth actually reaches the user.

**Produce the spec only.** Brainstorming normally ends by invoking `writing-plans`; do
not follow that transition. Stop once the design doc is written and the user approves it.
The implementation plan is the next session's job, per Step 6.

Frame the design as a **stack of PRs** from the start:

- Each PR is small, self-contained, and reviewable on its own.
- Each PR leaves the branch working; no PR depends on a later one to make sense.
- The stack has an order, and each step names what it depends on.

## Step 3: Review with architect-cobrain

Dispatch the `architect-cobrain` agent (Agent tool, `subagent_type: architect-cobrain`)
with the approved spec.

The agent is a **reviewer only**. It writes nothing to Notion and edits no files. It
returns findings and recommended steps.

Give it: the spec (or its path), the proposed PR stack, and enough repo context to judge
the split.

## Step 4: Address the review with the user, before Notion

Walk the agent's findings **one at a time**, in the agent's priority order. For each one:

1. Show the finding and its recommendation.
2. Give your own read: agree, disagree, or a different fix. The agent can be wrong; say
   so when it is, with a reason.
3. Get the user's decision.
4. Apply accepted changes to the spec.

Do not batch the findings into one message, and do not proceed to Notion until every
finding is resolved. If the changes reshape the PR stack substantially, re-dispatch
`architect-cobrain` on the revised spec.

## Step 5: Write to Notion

Only after Step 4 finishes.

Use the `write-notion-content` and `write-technical-content` skills for **everything**
written to Notion. They govern the prose; this skill governs the placement.

**On the roadmap item** (in `roadmapDb`):

- The technical detail of the change: components and boundaries touched, new contracts
  or behavior, what gets restructured or removed, and why.
- A **mermaid diagram** when it earns its place, i.e. when it shows a new flow or a
  changed architecture more clearly than prose. Skip it for a change a sentence covers.
- The PR stack as an ordered list, each entry naming its scope and its dependency.

**One task per PR** (in `taskDb`), created from `taskTemplate` when set, otherwise the
database's default template:

- Titled for the single change it makes.
- Scoped to one reviewable PR.
- Linked to the roadmap item, and stating which task it stacks on.
- Created in stack order.

Confirm the created pages back to the user with their URLs.

## Step 6: Hand off

Invoke the `handoff` skill to write the handoff document, then give the user a single
copy-pasteable prompt that starts implementation of the stacked PRs in a fresh session.

The prompt names the roadmap item, the first task in the stack, the handoff doc path, and
the skills the next session needs. It starts implementation at the **first** PR, not the
whole stack at once.

## Rules

- Never write to Notion before the review findings are resolved with the user.
- Never implement. No code changes, in any step.
- Stop if the repo is not configured and setup does not complete.
- Every PR in the stack is independently reviewable, or the split is wrong.
- Defer all Notion prose style to `write-notion-content` and `write-technical-content`.
- A mermaid diagram is for clarity, not decoration. Omit it when prose is clearer.
