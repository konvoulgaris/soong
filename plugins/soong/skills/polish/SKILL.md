---
name: polish
description: Run a code review with autofix, then a simplification pass, then commit the result. Use when the user runs /polish, or asks to review and clean up the current changes in one shot, autofix the review findings, or "review and simplify and commit". Runs unattended - it applies fixes and commits without asking.
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

1. **Check the working tree.** When a caller passed a base, use it. `merge`,
   `rebase`, and `develop` all resolve a base before they invoke anything, so
   re-deriving one discards a value the caller already has and costs a `gh` round
   trip. Absent one, resolve it:

   1. PR base: `gh pr view --json baseRefName -q .baseRefName` (if a PR exists).
   2. Upstream tracking branch, minus the remote prefix:
      `git rev-parse --abbrev-ref --symbolic-full-name @{u}`.
   3. The repository default branch.

   `merge` and `rebase` fall back to `development` at tier 3 rather than the
   default branch. Do not copy that: those skills run on repos where
   `development` is the integration branch, and polish runs anywhere.

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
   --fix
   ```

   `--fix` applies the findings to the working tree. Do not pass an effort
   level: absent one, `code-review` reuses the level the user last chose, which
   is the level they want. Record each finding the pass reports.

3. **Pass 2: simplify.** Invoke the `simplify` skill with no argument. It
   reviews the changed code for reuse, simplification, efficiency, and
   altitude, and applies the fixes. Record each change it reports.

4. **Verify.** Figure out how this repo verifies a build before running
   anything - do not assume a language or tool. Look at the project's
   CLAUDE.md / README, the build config, and lockfiles to find the right
   command. Prefer whatever the project documents. A repo can also keep its
   checks as scripts beside the code rather than in a root-level runner, so
   look there too before concluding there is none.

   When a caller already resolved the check, use what it found rather than
   repeating the discovery.

   If the failure looks like stale or missing dependencies, run the install
   command once before treating it as real - the same rule `merge` and `rebase`
   carry. A pass that touched a manifest produces exactly this false positive.

   If the check still fails, do not commit. Report the failure with the command
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

   Then stage the files the two passes touched, by path, and commit:

   ```bash
   git add <path> [<path>...]
   git commit -m "refactor: apply code review and simplification findings" \
              -m "Polish-passes: review,simplify"
   ```

   The `Polish-passes` trailer is the marker `manage-pr` compose step 0 reads to
   decide whether polish already ran. Keep it on every polish commit. The
   subject is prose and may be reworded; the trailer is the contract.

   Never `git add -A`, and never `git commit -a`: the tree can hold unrelated
   edits, and a caller such as `merge` may have just restored a stash, so a
   blanket stage sweeps work neither pass reviewed into this commit. List the
   paths the two passes reported.

   Use `fix:` instead of `refactor:` when pass 1 fixed a real bug. Add a body
   only when the fixes are not obvious from the diff. Never add a generated-by
   footer or a Claude attribution tag.

   Then capture the new commit for the report:

   ```bash
   git rev-parse --short HEAD
   ```

## The report

The report is the whole user-facing output. One sentence per finding. No
preamble, no restatement of the diff, no next-step suggestions.

```
Reviewed 6 files.

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

The steps state their own guards. These three fail silently and across files,
so check them before every commit:

- Never `git add -A` or `git commit -a`. Stage by path.
- Never omit the `Polish-passes` trailer. It is how a caller knows polish ran.
- Never add a generated-by footer or a Claude attribution tag.

## Errors

| Case | Response |
| --- | --- |
| A pass leaves a merge conflict marker or a broken file | Report the file and stop before the commit. |
| On the default branch, invoked by another skill | Stop and say so. Do not switch branches under a caller. |
