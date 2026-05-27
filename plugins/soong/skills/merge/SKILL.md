---
name: merge
description: Merge a base branch into the current feature branch and push the result, resolving conflicts file-by-file. Use when the user asks to "merge", "merge back", catch a feature branch up with its base, or pull base-branch changes into the current branch. "Base" most likely means the branch the feature was cut from or the PR's base branch, not necessarily a branch literally named "development".
---

# merge

Merge the **base branch** into the current feature branch and push. "Base" almost
always means the branch this feature was cut from or the PR's base branch — resolve
it, don't assume a branch literally called `development`.

## Resolve the base branch

Detect the base in this order, taking the first that works:

1. PR base: `gh pr view --json baseRefName -q .baseRefName` (if a PR exists).
2. Upstream tracking branch of the current branch, minus the remote prefix:
   `git rev-parse --abbrev-ref --symbolic-full-name @{u}`.
3. Fall back to `development`.

Report which base you resolved before merging.

## Resolve the toolchain

Figure out how this repo installs dependencies and verifies a build before
running anything — do not assume a language or tool. Look at the project's
CLAUDE.md / README, the build config, and lockfiles to find the right commands
(e.g. dependency install, type/compile check, build). Prefer whatever the
project documents.

## Steps

Track these as todos and do them in order.

1. `git status`. If the working tree is dirty, stash everything (including untracked):
   `git stash push -u -m "pre-merge"`. Note that a stash was created so you pop it later.
2. `git fetch origin <base>`.
3. `git merge origin/<base> --no-edit`.
4. If conflicts: resolve each conflicted file by reading **both** sides and keeping
   the correct result. Do not default to either side. After resolving, check for
   leftover markers in the merged files only:
   `git diff --name-only --diff-filter=U` is empty, then
   `grep -rn '<<<<<<<\|>>>>>>>' <merged-paths>` (these markers are unambiguous;
   `=======` alone produces false positives, so don't grep for it).
5. If a dependency manifest or lockfile changed in the merge, take the base
   branch's version of the lockfile and re-run the install command.
6. Run the project's build/verify check. If it fails, fix it before committing —
   never commit a broken merge. Always run this; do not skip it.
7. `git add` the resolved files, then `git commit --no-edit` to keep the merge message.
8. If you created a stash in step 1, `git stash pop` now.
9. `git push` (normal push — a merge commit or fast-forward needs no force).
10. Check for an open PR on this branch: `gh pr view --json number -q .number`. If one
    exists, a merge is a natural finishing step, so use the `manage-pr` skill to refresh
    the PR title and description — invoke it with `--non-interactive` so it drafts and
    updates the PR without pausing for confirmation. If no PR exists, skip this step
    silently.

## Rules

- Resolve conflicts file-by-file. Never use `--no-verify`, and never use blanket
  `-X ours` / `-X theirs` strategies.
- Never force-push.
- This is a merge, not a rebase. Do not rebase unless the user explicitly asks.
- If the merge surfaces a pre-existing build break that looks like stale or
  missing dependencies, run the install command once before reporting it as a
  real failure.
