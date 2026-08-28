---
name: polish
description: Run a maximum-effort code review with autofix, then a simplification pass, then commit the result. Use when the user runs /polish, or asks to review and clean up the current changes in one shot, autofix the review findings, or "review and simplify and commit". Runs unattended - it applies fixes and commits without asking.
---

# polish

Two passes over the current changes, both applied, one commit, one short
report.

Pass 1 finds correctness bugs and fixes them. Pass 2 removes the complexity
that pass 1 does not care about. The order is fixed: a simplification pass
over buggy code simplifies the wrong thing.

This skill runs unattended. The user chose autofix and auto-commit, so do not
ask for approval between the passes.

## Steps

1. **Check the working tree.**

   ```bash
   git status --porcelain
   ```

   If the tree is clean and the branch has no commits ahead of its base, there
   is nothing to review. Say so in one line and stop.

   If the tree is dirty, that is normal. Both passes work on the changed code.

2. **Record the starting point.**

   ```bash
   git rev-parse HEAD
   ```

   Keep this SHA. Step 6 uses it to describe what the two passes changed.

3. **Pass 1: review and fix.** Invoke the `code-review` skill with:

   ```
   max --fix
   ```

   `max` is the effort level. `--fix` applies the findings to the working
   tree. Record each finding the pass reports.

4. **Pass 2: simplify.** Invoke the `simplify` skill with no argument. It
   reviews the changed code for reuse, simplification, efficiency, and
   altitude, and applies the fixes. Record each change it reports.

5. **Verify.** Run the project's own check, in this order of preference:

   1. A test or lint script named in `CLAUDE.md`.
   2. `npm test` when `package.json` declares a `test` script, or the
      equivalent for the project's language.
   3. Nothing, when the project declares no check.

   If the check fails, do not commit. Report the failure with the command
   output and stop. A failing check after an autofix means a pass broke
   something, and the user needs the broken state to look at.

   If the project declares no check, say so in the report. Never claim
   verification that did not run.

6. **Commit.** Stage everything the two passes touched and commit with a
   Conventional Commit:

   ```bash
   git add -A && git commit -m "refactor: apply code review and simplification findings"
   ```

   Use `fix:` instead of `refactor:` when pass 1 fixed a real bug. Add a body
   only when the fixes are not obvious from the diff. Never add a generated-by
   footer or a Claude attribution tag.

   If the branch is the default branch, branch first:

   ```bash
   git switch -c polish/$(git rev-parse --short HEAD)
   ```

## The report

The report is the whole user-facing output. One sentence per finding. No
preamble, no restatement of the diff, no next-step suggestions.

```
Reviewed 6 files at max effort.

Fixed
- Token expiry check used `<`, so a token expiring this second passed.
- The tenant filter was missing on the device serial lookup.

Simplified
- Replaced the hand-rolled retry loop with the existing `withRetry` helper.
- Dropped the single-implementation `PassStore` interface.

Checked with `npm test`. Committed as a1b2c3d.
```

Rules for the report:

- One line per finding, one sentence, present the problem not the process.
- Omit a heading with nothing under it. A pass that found nothing gets one
  line: `Review found nothing.` or `Nothing to simplify.`
- The last line names the check that ran and the commit SHA. When no check
  ran, say `No project check configured.`
- Never list a finding a pass reported but did not apply. If a pass skipped a
  finding, that goes in a fifth line: `Not applied: <one sentence>.`

## Errors

| Case | Response |
| --- | --- |
| Working tree clean, no commits ahead of base | Say there is nothing to review and stop. |
| A pass reports no findings | Continue to the next pass. Note the empty result in the report. |
| The verification check fails | Report the failing command and its output. Do not commit. Do not attempt a fix. |
| A pass leaves a merge conflict marker or a broken file | Report the file and stop before the commit. |
