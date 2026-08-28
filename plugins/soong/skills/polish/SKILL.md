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
ask for approval between the passes. Tell both passes they are running
unattended too: they apply their own findings, and a pass that stops to ask
blocks a caller such as `develop` that invoked the whole chain to run without
a user present.

## Steps

1. **Check the working tree.** Resolve the base first, taking the first that
   works, the same order `merge` uses:

   1. PR base: `gh pr view --json baseRefName -q .baseRefName` (if a PR exists).
   2. Upstream tracking branch, minus the remote prefix:
      `git rev-parse --abbrev-ref --symbolic-full-name @{u}`.
   3. The repository default branch.

   Then check for work to review:

   ```bash
   git status --porcelain
   git rev-list --count <base>..HEAD
   ```

   If the tree is clean **and** the count is zero, there is nothing to review.
   Say so in one line and stop.

   If either is non-empty, continue. Both passes work on the changed code.

2. **Pass 1: review and fix.** Invoke the `code-review` skill with:

   ```
   max --fix
   ```

   `max` is the effort level. `--fix` applies the findings to the working
   tree. Record each finding the pass reports.

3. **Pass 2: simplify.** Invoke the `simplify` skill with no argument. It
   reviews the changed code for reuse, simplification, efficiency, and
   altitude, and applies the fixes. Record each change it reports.

4. **Verify.** Figure out how this repo verifies a build before running
   anything - do not assume a language or tool. Look at the project's
   CLAUDE.md / README, the build config, and lockfiles to find the right
   command. Prefer whatever the project documents. A repo can also keep its
   checks as scripts beside the code rather than in a root-level runner, so
   look there too before concluding there is none.

   If the check fails, do not commit. Report the failure with the command
   output and stop. A failing check after an autofix means a pass broke
   something, and the user needs the broken state to look at.

   If the project declares no check, say so in the report. Never claim
   verification that did not run.

5. **Commit.** If the current branch is the repository default branch, branch
   **before** committing, so the default branch never carries the commit:

   ```bash
   git switch -c polish/$(git rev-parse --short HEAD)
   ```

   Never do this when another skill invoked polish. A caller has already named
   the branch it expects to push and to open a pull request from, and switching
   underneath it strands the work on a branch the caller does not know. When
   polish is invoked by a caller and the branch is the default branch, stop and
   say so instead.

   Then stage the files the two passes touched and commit:

   ```bash
   git commit -m "refactor: apply code review and simplification findings"
   ```

   Stage by path. Never `git add -A`: the tree can hold unrelated edits, and a
   caller such as `merge` may have just restored a stash, so a blanket stage
   sweeps work neither pass reviewed into this commit.

   Use `fix:` instead of `refactor:` when pass 1 fixed a real bug. Add a body
   only when the fixes are not obvious from the diff. Never add a generated-by
   footer or a Claude attribution tag.

   **The subject after the type prefix is a contract.** `manage-pr` compose
   step 0 greps for the literal text `apply code review and simplification
   findings` to decide whether polish already ran. Reword it and compose
   re-runs a full review on every pull request create or edit. Change both
   files together or neither.

   Then capture the new commit for the report:

   ```bash
   git rev-parse --short HEAD
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

Checked with `<the project's own check>`. Committed as a1b2c3d.
```

Rules for the report:

- One line per finding, one sentence, present the problem not the process.
- Omit a heading with nothing under it. A pass that found nothing gets one
  line: `Review found nothing.` or `Nothing to simplify.`
- The last line names the check that ran and the commit SHA. When no check
  ran, say `No project check configured.`
- Never list a finding a pass reported but did not apply. If a pass skipped a
  finding, add one more line after the check line: `Not applied: <one
  sentence>.`

## Rules

- Never commit over a failing check. A failing check after an autofix means a
  pass broke something, and the user needs the broken state to look at.
- Never claim verification that did not run. When the project declares no
  check, say so.
- Never `git add -A`. Stage the files the two passes touched, by path.
- Never switch branches when a caller invoked polish.
- Never reword the commit subject without changing compose step 0's grep in
  the same change.
- Never add a generated-by footer or a Claude attribution tag.
- Never list a finding a pass reported but did not apply.

## Errors

| Case | Response |
| --- | --- |
| Working tree clean, no commits ahead of base | Say there is nothing to review and stop. |
| A pass reports no findings | Continue to the next pass. Note the empty result in the report. |
| The verification check fails | Report the failing command and its output. Do not commit. Do not attempt a fix. |
| A pass leaves a merge conflict marker or a broken file | Report the file and stop before the commit. |
| On the default branch, invoked by another skill | Stop and say so. Do not switch branches under a caller. |
