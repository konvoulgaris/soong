# Design: walkthrough skill

Date: 2026-08-24
Branch: `claude/walkthrough-feature-ai-9a9c15`

## Summary

A new skill, `walkthrough`, that explains a branch's implementation to the user
one change at a time. The skill reads the pull request description and the
branch diff, selects the most significant changes, and presents each change as
problem, change, consequence. The walkthrough is interactive: the user advances
one step at a time and can ask for more detail on any step.

The skill adds one script, `scripts/gather-context.sh`, that collects the pull
request and diff metadata in a single call.

### Problem this solves

When a developer builds a feature with an agent, the developer often does not
know what the agent changed or why. A pull request description is a wall of
text that the developer skims. A diff is too long to read. Neither format
supports the one thing that produces understanding: the ability to stop at the
step where you got lost and ask about it.

### Non-goals

* The skill does not edit code. It is read only.
* The skill does not review code. It explains what exists, and does not judge
  it.
* The skill does not write a document. The walkthrough is a conversation, not
  a file.

## Files

```
plugins/soong/skills/walkthrough/
├── SKILL.md                    # process and step format, inline
└── scripts/gather-context.sh   # collects PR and diff metadata, emits JSON
```

One further change: bump `version` in
`plugins/soong/.claude-plugin/plugin.json` from `0.6.1` to `0.7.0`. The
repository `CLAUDE.md` requires a minor bump for a feature.

No hook. No entry in `.claude-plugin/marketplace.json`, which lists plugins and
not skills.

### Frontmatter

```yaml
---
name: walkthrough
description: Walk the user through an implementation one change at a time,
  explaining what changed and why. Reads the PR description and the branch
  diff, caps the walkthrough at the most significant changes, and presents
  each as problem, change, consequence. Accepts an optional scope argument to
  limit the walkthrough to one area. Triggers on /walkthrough, "walk me
  through this", "explain what we built", "what did we change and why".
---
```

The user invokes the skill as `/soong:walkthrough`, with an optional scope
argument: `/soong:walkthrough auth changes` or
`/soong:walkthrough src/gateway/`.

## Component 1: gather-context.sh

### Purpose

Collect every fact the skill needs about the branch in one call. The script
runs once, at the start of the walkthrough.

### Rationale

Three reasons to use a script instead of letting the skill run the commands:

1. A raw `git diff` in the transcript costs a large amount of context. The
   script returns a file list with churn counts instead.
2. The pull request lookup must not fail the walkthrough when no pull request
   exists. A script handles that case once, in one place.
3. Base branch resolution has two paths (the pull request base, or the merge
   base against the default branch). A script makes the resolution
   deterministic.

### Output

The script writes JSON to stdout:

```json
{
  "branch": "claude/walkthrough-feature-ai-9a9c15",
  "base": "main",
  "pr": {
    "number": 42,
    "title": "feat(auth): scope device endpoint to tenant",
    "body": "* New PUBLIC_BASE_URL feeds webServiceURL...\n* ..."
  },
  "commits": [
    "abc1234 feat(auth): require pass token on device endpoint",
    "def5678 fix(gateway): scope proxy entry to /v1"
  ],
  "files": [
    { "path": "src/routes/devices.ts", "added": 40, "removed": 3 },
    { "path": "src/config/env.ts", "added": 4, "removed": 0 }
  ]
}
```

When no pull request exists for the branch, `pr` is `null`. This is a normal
result and not an error.

### Steps

1. Resolve the branch name with `git rev-parse --abbrev-ref HEAD`.
2. Resolve the base branch. Try `gh pr view --json baseRefName` first. If no
   pull request exists, use the merge base against `main`, or against `master`
   if `main` does not exist.
3. Read the pull request with `gh pr view --json number,title,body`. On any
   failure, set `pr` to `null` and continue.
4. Read the commit subjects with `git log --oneline <base>..HEAD`.
5. Read the file list with `git diff --numstat <base>...HEAD`.
6. Print the JSON.

The script uses `jq` to build the JSON, so that a commit subject or a pull
request body with a quote character cannot break the output. `jq` is already a
dependency of the `sync-pr-to-notion` skill in this plugin.

### What the script does not return

The script does not return the diff body. The file list with churn counts is
the map. The skill reads specific hunks with `git diff` as it builds each
step, and only for the files that a step covers.

### Failure

The script exits non-zero with a one line message to stderr in three cases:

* The working directory is not a git repository.
* No base branch can be resolved.
* The branch has no commits against the base.

The skill stops on a non-zero exit and reports the message. The skill does not
attempt a recovery and does not suggest a next action.

### Worktree note

The script must not use `git rev-parse --show-toplevel` to find the repository
root, because inside a linked worktree that command returns the worktree
directory. The script does not need the repository name, so this note applies
only if a future change adds a lookup keyed on the project name. The
`sync-pr-to-notion` skill documents the correct approach.

## Component 2: outline construction

After the script returns, the skill builds a numbered list of steps. The skill
does not print the full list. The skill prints a count and starts step 1.

### Sources

Three sources, in priority order:

1. **The pull request description.** Each bullet in the description is a
   candidate step. A human wrote these bullets, so the granularity is already
   correct.
2. **The diff.** A file with real churn that no pull request bullet covers
   becomes a candidate step. The skill marks the step as absent from the pull
   request description.
3. **The commit subjects.** These are a tie breaker. The skill uses them to
   name and to group steps, and never as a step on their own.

Both sources are always read. The pull request description sets the outline,
and the diff catches the case where the description is out of date.

### Selection

The cap is 8 steps.

Below the cap, every candidate gets a step. Above the cap, the skill ranks
candidates by blast radius and keeps the top 8. A change to authentication, to
a data boundary, or to a public contract outranks a rename, a comment, or a
dependency bump.

The remainder becomes one closing step, `Also changed`, with one line for each
item. Nothing is dropped in silence.

### Scope argument

When the user supplies a scope argument, the skill filters the candidates
against it before the cap applies. The scope can name an area
(`auth changes`), a path (`src/gateway/`), or a symbol
(`getSerialNumbersForDevice`).

The skill states what the scope excluded, so that the user knows the
walkthrough is partial.

### Opening message

The opening message is two lines, and then step 1 in the same message:

```
5 steps. 2 from the PR description, 3 found in the diff.
Say "next" to continue, or ask about anything.

Step 1 of 5: ...
```

The skill does not write a separate drift report. A step that the pull request
description does not cover carries that fact on the step itself.

## Component 3: step format

Each step is one message. The budget is 150 words.

### Shape

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

### Rules

1. Three labelled sections: `Problem`, `Change`, `Consequence`. Each section is
   1 to 3 sentences.
2. The prose follows the `write-technical-content` skill: active voice, present
   tense, one instruction per sentence, one term for one concept. `Problem` is
   the exception to present tense, because it describes a state that the change
   removed.
3. A snippet is optional. A snippet is 5 lines maximum. Include a snippet only
   when the prose alone cannot carry the change. Never include a diff block,
   and never include two snippets in one step.
4. One `file:line` reference, formatted as a markdown link so that the user can
   click it. Add a second reference only when the change genuinely spans two
   places.
5. A step that comes from the diff and not from the pull request description
   adds one line: `Not in the PR description.`
6. The last line offers to continue or to expand.

### Why problem, change, consequence

Understanding a change is understanding a delta. A `what changed` inventory
restates the diff, which the user can already read. The before state is the
part that the diff does not show and that the user has lost.

## Component 4: interaction

### Default loop

The skill presents a step and waits. The user has three options:

* Advance. `next`, or any equivalent.
* Ask a question about the current step. The skill answers, then re-offers.
* Ask to expand the current step.

### Expand

On `expand`, the skill reads more context for the current step: the
surrounding code, the call path into the changed function, or the fuller diff
for that file. The same budget applies, so an expansion is a second short
message and not a dump. After an expansion the skill re-offers `next` or a
further expansion.

### Quiz

On request, the skill asks one short question after each step, checks the
answer, and then advances. This is not the default. The user asked for a
walkthrough and not for an examination, so the skill offers the quiz only when
the user asks for it.

### Jumping

The user can name a step number to jump to it. The user can also ask to skip a
step.

## Component 5: guard rails

### Never edit code

The skill is read only. It runs `git`, `gh`, and read commands, and nothing
else. If the walkthrough surfaces a bug, the skill states the bug in one line
and continues. A fix is a separate request from the user.

### Never invent

Every step traces to a pull request bullet, a diff hunk, or a commit subject.
The skill does not present an inferred intent as a fact. When the reason for a
change is not recoverable from the sources, the step says that the reason is
not recorded. A guess that reads as a fact is worse than an admitted gap,
because the user cannot tell the two apart.

### Never dump

No full diffs. No file contents. No wall of text. The word budget is the
feature and not a limitation.

## Closing message

After the last step, the skill writes three lines at most:

```
5 steps done. The change moves pass issuance behind the permission guard
and closes a cross-tenant read on the device endpoint.

Not walked: 3 config and dependency updates.
```

One sentence for what the branch does as a whole. Then one line for anything
that the cap or the scope excluded. The second line is omitted when nothing
was excluded.

## Error handling

| Case | Behaviour |
| --- | --- |
| Not a git repository | Script exits non-zero. Skill reports and stops. |
| No commits against base | Script exits non-zero. Skill reports and stops. |
| No pull request for the branch | `pr` is `null`. Skill builds the outline from the diff and says so. |
| `gh` not installed or not authenticated | Treated as no pull request. Skill notes that the pull request was not read. |
| Scope matches nothing | Skill reports that the scope matched no change, and asks whether to walk the whole branch. |

## Testing

The skill is prose and one script, so the testable unit is the script.

Manual verification of `gather-context.sh`, on this repository:

1. Run on a branch with an open pull request. Confirm that `pr` is populated
   and that `base` matches the pull request base.
2. Run on a branch with no pull request. Confirm that `pr` is `null` and that
   the script still exits zero.
3. Run on a branch with a commit subject that contains a double quote. Confirm
   that the output is valid JSON, by piping the output to `jq .`.
4. Run inside a linked worktree. Confirm that branch and base resolve
   correctly.
5. Run on the default branch, with no commits against the base. Confirm a non
   zero exit and a one line message.

Verification of the skill itself is a manual walkthrough run on a real branch,
checked against the rules: step count within the cap, each step within the
word budget, no snippet longer than 5 lines, and every step traceable to a
source.

## Open questions

None.
