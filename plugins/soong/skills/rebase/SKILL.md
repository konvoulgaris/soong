---
name: rebase
description: Rebase the current feature branch onto a new base branch, keeping only the changes made on the feature branch and dropping any commits inherited from the old base. Use when the user asks to "rebase", change a feature branch's base, move a branch onto a different base, or re-point a branch at a new base branch without carrying over the previous base's history.
---

# rebase

Move the current feature branch onto a **new base branch** so it carries only the
commits that were authored on the feature branch — not the commits it inherited
from its old base. The result: your changes replayed cleanly on top of the new base.

This is `git rebase --onto`, not a plain `git rebase`. A plain rebase would try to
replay every commit that is not on the new base, which can drag in the old base's
history. `--onto` lets you keep exactly the feature commits and nothing else.

## Resolve the branches

You need three things. Resolve them and report all three before rebasing.

1. **New base** — the branch to rebase onto. The user usually names it. If not,
   ask; never guess.
2. **Old base** — the branch the feature was originally cut from. Detect in this
   order, first that works:
   1. PR base: `gh pr view --json baseRefName -q .baseRefName` (if a PR exists).
   2. Upstream tracking branch minus the remote prefix:
      `git rev-parse --abbrev-ref --symbolic-full-name @{u}`.
   3. Fall back to `development`.
3. **Fork point** — where the feature diverged from the old base:
   `git merge-base HEAD origin/<old-base>`. This commit is the cutoff; everything
   after it on the current branch is "our changes" and gets replayed.

If the resolved old base and new base are the same branch, there is nothing to do —
stop and tell the user.

## Resolve the toolchain

Figure out how this repo installs dependencies and verifies a build before
running anything — do not assume a language or tool. Look at the project's
CLAUDE.md / README, the build config, and lockfiles to find the right commands
(e.g. dependency install, type/compile check, build). Prefer whatever the
project documents.

## Steps

Track these as todos and do them in order.

1. `git status`. If the working tree is dirty, stash everything (including untracked):
   `git stash push -u -m "pre-rebase"`. Note that a stash was created so you pop it later.
2. `git fetch origin <old-base> <new-base>`.
3. Compute the fork point: `git merge-base HEAD origin/<old-base>`.
4. Sanity-check what will be replayed before doing it:
   `git log --oneline <fork-point>..HEAD`. These are the only commits that should
   survive. Confirm they are all yours and none belong to the old base.
5. Rebase onto the new base:
   `git rebase --onto origin/<new-base> <fork-point> <current-branch>`.
6. If conflicts: resolve each conflicted file by reading **both** sides and keeping
   the correct result. Do not default to either side. After resolving each step,
   `git add` the resolved files and `git rebase --continue`. Repeat until the rebase
   finishes. Check for leftover markers in the resolved files only:
   `grep -rn '<<<<<<<\|>>>>>>>' <resolved-paths>` (these markers are unambiguous;
   `=======` alone produces false positives, so don't grep for it).
7. If a dependency manifest or lockfile changed during the rebase, take the new
   base branch's version of the lockfile and re-run the install command.
8. Run the project's build/verify check. If it fails, fix it before continuing —
   never leave a broken rebase. Always run this; do not skip it.
9. If you created a stash in step 1, `git stash pop` now.
10. Verify the result: `git log --oneline origin/<new-base>..HEAD` should show only
    your feature commits sitting on top of the new base, with no commits from the
    old base.
11. `git push --force-with-lease`. A rebase rewrites history, so a force push is
    required — but use `--force-with-lease`, never a plain `--force`, so you do not
    clobber commits someone else pushed.

## Rules

- Always use `git rebase --onto`. A plain `git rebase <new-base>` can replay the old
  base's commits onto the new base — exactly what we are avoiding.
- Resolve conflicts file-by-file. Never use `--no-verify`, and never use blanket
  `-X ours` / `-X theirs` strategies.
- Force-push only with `--force-with-lease`, never plain `--force`.
- This is a rebase, not a merge. Do not merge unless the user explicitly asks.
- If the rebase surfaces a pre-existing build break that looks like stale or
  missing dependencies, run the install command once before reporting it as a
  real failure.
- If you are unsure which branch is the old base or the new base, ask the user
  rather than guessing — rebasing onto the wrong base is disruptive to undo.
