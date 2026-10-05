---
name: polish
description: Run a code review with autofix, then a simplification pass, then commit the result. Use when the user runs /polish, or asks to review and clean up the current changes in one shot, autofix the review findings, or "review and simplify and commit". Runs unattended - it applies fixes and commits without asking.
---

# polish

Read [host operations](../soong-setup/reference/hosts.md) before running this workflow.

Review the changed code, fix what is broken, simplify what is left, then
commit. You do the work yourself. Do not dispatch an agent.

This skill runs unattended. The user chose autofix and auto-commit, so apply
every finding and do not ask for approval.

## Steps

1. **Find the changed code.** When a caller passed a base, use it. Absent one,
   resolve it:

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
   Say so in one line and stop. Otherwise the changed code is
   `git diff <base>...HEAD` plus the working tree. Review the changed lines and
   the code they touch. Do not fix a problem that was already there before this
   branch.

2. **Pass 1: correctness.** Find bugs that make the code do the wrong thing,
   then fix them.

   Look for: off-by-one and boundary errors, wrong comparison operators,
   inverted conditions, missing null and empty cases, missing tenant or scope
   filters on queries, unhandled error paths, resource leaks, race conditions,
   and state mutated where a copy was meant.

   For each candidate, write the failure first: the input or state that reaches
   it, and the wrong output or crash it produces. A candidate with no such
   failure is not a bug. Drop it. Apply the smallest fix that removes the
   failure.

3. **Pass 2: simplification.** Only after pass 1 is applied. Simplifying over
   buggy code simplifies the wrong thing.

   Look for: code that reimplements something the repository or the standard
   library already provides, an abstraction with one implementation, a
   parameter or branch nothing reaches, a hand-rolled loop where an existing
   helper fits, and repeated work that a single call covers.

   Match the surrounding code. Never change behaviour in this pass. Never touch
   a file outside the changed set. If a fix needs a decision you cannot make,
   leave the code alone and report it as not applied.

4. **Verify.** Figure out how this repo verifies a build before running
   anything. Look at AGENTS.md / CLAUDE.md / README, the build config, and
   lockfiles. Prefer what the project documents. Checks can live as scripts
   beside the code, so look there too. When a caller already resolved the check,
   use it.

   If the failure looks like stale or missing dependencies, run the install
   command once before treating it as real.

   If the check still fails, do not commit. Report the failure with the command
   output and stop.

   If the project declares no check, say so. Never claim verification that did
   not run.

5. **Commit.** If the current branch is the repository default branch, branch
   **before** committing:

   ```bash
   git switch -c polish/$(git rev-parse --short HEAD)
   ```

   Never do this when another skill invoked polish. A caller has already named
   the branch it expects to push. When a caller invoked polish on the default
   branch, stop and say so.

   Stage the files you edited, by path, and commit:

   ```bash
   git add <path> [<path>...]
   git commit -m "refactor: apply code review and simplification findings"
   ```

   Use `fix:` instead of `refactor:` when you fixed a real bug. Add a body only
   when the fixes are not obvious from the diff. When you changed nothing, do
   not commit.

   Never `git add -A` or `git commit -a`: the tree can hold unrelated edits.
   Never add a generated-by footer or a Claude attribution tag.

## The report

One sentence per finding. No preamble, no restatement of the diff, no next-step
suggestions.

```
Reviewed 6 files.

Fixed
- Token expiry check used `<`, so a token expiring this second passed.

Simplified
- Replaced the hand-rolled retry loop with the existing `withRetry` helper.

Checked with `<the project's own check>`. Committed as a1b2c3d.
```

- Omit a heading with nothing under it. A pass that found nothing gets one
  line: `Review found nothing.` or `Nothing to simplify.`
- The last line names the check that ran and the commit SHA. When no check
  ran, say `No project check configured.`
- List a finding you did not apply after the check line:
  `Not applied: <one sentence>.`

## Errors

| Case | Response |
| --- | --- |
| A fix leaves a merge conflict marker or a broken file | Report the file and stop before the commit. |
| On the default branch, invoked by another skill | Stop and say so. Do not switch branches under a caller. |
