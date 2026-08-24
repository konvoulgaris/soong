---
name: walkthrough
description: Walk the user through an implementation one change at a time, explaining what changed and why. Reads the PR description and the branch diff, caps the walkthrough at the most significant changes, and presents each as problem, change, consequence. Accepts an optional scope argument to limit the walkthrough to one area. Triggers on /walkthrough, "walk me through this", "explain what we built", "what did we change and why".
---

# walkthrough

Explain the current branch to the user, one change at a time. This skill
explains work. It never does work.

The user runs this skill because the user does not know what the branch
changed. A pull request description is a wall of text that the user skims. A
diff is too long to read. This skill gives the user one change at a time, and
a place to stop and ask.

## What this skill never does

- **Never edit code.** This skill runs read commands only. If the walkthrough
  finds a bug, state the bug in one line and continue. A fix is a separate
  request from the user.
- **Never invent a reason.** Every step traces to a pull request bullet, a diff
  hunk, or a commit subject. When the reason for a change is not recoverable
  from these sources, say that the reason is not recorded. A guess that reads
  as a fact is worse than an admitted gap, because the user cannot tell the two
  apart.
- **Never dump.** No full diffs. No file contents. No wall of text. The word
  budget is the feature.
- **Never review.** This skill explains what exists. It does not judge the
  quality of what exists.

## Steps

1. **Gather the context.** Run the script one time:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/walkthrough/scripts/gather-context.sh"
   ```

   The script returns JSON with `branch`, `base`, `pr`, `commits`, and `files`.
   A `pr` of `null` means the branch has no pull request, which is a normal
   result.

   If the script exits non-zero, report the message from the script in one line
   and stop. Do not suggest a next action.

2. **Build the outline.** Take candidate steps from three sources, in this
   order of priority:

   1. The pull request description. Each bullet is one candidate. A person
      wrote these bullets, so the granularity is already correct.
   2. The diff. A file with large churn that no bullet covers is one candidate.
      When a pull request description exists, mark this candidate as absent
      from the description.
   3. The commit subjects. Use the subjects to name and to group candidates.
      Never make a commit subject a step on its own.

   Read the pull request and the diff every time. The pull request sets the
   outline. The diff catches the condition where the description is out of
   date.

   When `pr` is `null`, the diff and the commit subjects supply the whole
   outline. Say so in the opening message, and mark no candidate as absent
   from a description that does not exist.

3. **Apply the scope argument.** When the user gives an argument, keep only the
   candidates that match the argument. The argument can name an area, a path,
   or a symbol. Record what the scope excluded, and report the exclusion in the
   closing message.

4. **Apply the cap.** The cap is 8 steps. Below the cap, each candidate gets a
   step. Above the cap, rank the candidates by blast radius and keep the first
   8. A change to authentication, to a data boundary, or to a public contract
   outranks a rename, a comment, or a dependency bump. Put the remainder in one
   closing step named `Also changed`, with one line for each item. Never drop a
   change in silence.

   Use `Also changed` only for candidates that the cap or the scope excluded.
   Below the cap and with no scope argument, every candidate gets a full step
   and the closing step does not appear.

5. **Order the steps for a reader, not by rank.** Blast radius selects the
   steps. Blast radius does not order them. Put each step after the step it
   depends on, so that the walkthrough reads in dependency order:

   * A new module comes before the code that calls the module.
   * A schema or a contract comes before the code that reads it.
   * A test comes after the behaviour that the test covers.
   * A version bump, a lock file, and generated output come last.

   When two steps have no dependency between them, put the step with the
   larger blast radius first.

6. **Read the code for a step at the time you reach that step.** Do not read
   each file before step 1. Use `git diff` on the one file that the current
   step covers.

## The step format

Each step is one message. The budget is 150 words.

```
Step 3 of 5: getSerialNumbersForDevice

Problem. The endpoint had no authentication and no tenant filter. Any
deviceId plus passTypeIdentifier returned a device's serial numbers,
including serial numbers that belong to other tenants.

Change. The endpoint now requires a pass token that matches the device,
and the query scopes to that pass's tenant.

  const pass = await requirePassToken(req, deviceId)
  return serials.find({ tenant: pass.tenant, deviceId })

Consequence. A caller without a valid pass token gets 401. A caller with
one sees only its own tenant's serial numbers.

src/routes/devices.ts:88

Next, or expand this one?
```

### Rules for a step

1. Write three labelled sections: `Problem`, `Change`, `Consequence`. Each
   section holds 1 to 3 sentences.
2. Follow the `write-technical-content` skill: active voice, one instruction
   per sentence, one term for one concept. Use present tense, except in
   `Problem`, which describes a state that the change removed.
3. Add a snippet only when the prose alone cannot carry the change. A snippet
   is 5 lines maximum. Never show a diff block. Never show two snippets in one
   step.
4. Give one `file:line` reference as a markdown link, so that the user can
   click the reference. Give a second reference only when the change spans two
   places.
5. For a step that comes from the diff and not from the pull request
   description, add one line: `Not in the PR description.` This line marks
   drift between the description and the code, so add the line only when a
   description exists to drift from. When `pr` is `null`, every step comes
   from the diff, the line carries no information, and every step must omit
   the line.
6. End with an offer to continue or to expand.

Understanding a change is understanding a delta. An inventory of what changed
restates the diff, which the user can already read. The state before the change
is the part that the diff does not show.

## Interaction

Open with two lines, and then step 1 in the same message:

```
5 steps. 2 from the PR description, 3 found in the diff.
Say "next" to continue, or ask about anything.

Step 1 of 5: ...
```

When the branch has no pull request, name the source instead of a split:

```
4 steps, from the diff and the commits. This branch has no PR.
Say "next" to continue, or ask about anything.

Step 1 of 4: ...
```

Present one step and wait. The user has four options:

- Advance to the next step.
- Ask a question about the current step. Answer the question, and then offer
  the closing line of the step again.
- Ask to expand the current step.
- Name a step number to jump to, or ask to skip a step.

### Expand

Read more context for the current step: the code around the change, the path
that calls the changed function, or the fuller diff for that one file. Keep the
same budget. An expansion is a second short message. Offer to continue after
the expansion.

### Quiz

When the user asks for a quiz, ask one short question after each step, check
the answer, and then advance. Do not quiz the user unless the user asks. The
user asked for a walkthrough and not for an examination.

## Closing message

After the last step, write three lines maximum:

```
5 steps done. The change moves pass issuance behind the permission guard
and closes a cross-tenant read on the device endpoint.

Not walked: 3 config and dependency updates.
```

Give one sentence for what the branch does as a whole. Then give one line for
anything that the cap or the scope excluded. Omit the second line when the
walkthrough excluded nothing.

## Errors

| Case | Response |
| --- | --- |
| The script exits non-zero | Report the message from the script in one line and stop. |
| No pull request for the branch | Build the outline from the diff and say so. |
| `gh` is absent or not logged in | Treat the branch as one with no pull request. Say that the skill did not read a pull request. |
| The scope matches nothing | Say that the scope matched no change. Ask whether to walk the whole branch. |
