---
name: review-pr
description: Review one pull request in depth and report only the concerns that are real, not nitpicks. Dispatches two reviewer agents over the diff, filters their findings through the adversarial council, and reports a table of concerns with a final status of Reviewable or Concerns. Repository-local - it STOPS if the current workspace is not the pull request's own repository. Read-only; it never posts to GitHub. Use when the user runs /review-pr, asks for an in-depth or careful review of a pull request, or picks a row out of /review-pr-queue.
---

# review-pr

Review one pull request and report the concerns that are real.

This skill is read-only. It never posts a review, a comment, or an approval -
posting is `manage-pr`'s job.

## Step 0: The adjacency guard

Run this before anything else:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/review-pr/scripts/guard.sh" <url-or-number>
```

**Exit 3 means STOP.** Report the script's message verbatim and stop. Do not
clone, do not switch worktrees, do not offer to, and do not review from the diff
alone. Exit 2 is a `gh` or access problem: report it and stop.

The guard exists because the reviewer agents and the verifier lens read files
from disk. Without the right code present every finding is unverifiable, and a
review reporting unverifiable findings as concerns is worse than no review.

## Step 1: Gather

```bash
gh pr diff <url>
gh pr view <url> --json title,body,statusCheckRollup,baseRefName,headRefName
```

Resolve the merge base from the base branch the second call returns, and give it
to the agents. They read surrounding code there, so they see the code the change
was written against rather than the workspace's HEAD.

**If the diff is empty, or touches nothing but lockfiles and generated files:**
report that and stop. Do not dispatch agents and do not call the council.

## Step 2: Dispatch the reviewer agents

Send both in **one message** so they run at the same time:

* `pr-reviewer-correctness`
* `pr-reviewer-design`

Each gets the diff, the pull request's title and body, and the merge base.

Both agent files forbid style and preference findings, and require a failure
scenario or a consequence per finding. That is the primary nitpick filter. The
council's `drop` is the backstop, not the first line of defence.

Failure handling:

* **One agent fails.** Continue with the survivor's findings. Say the review is
  partial and which agent is missing. `Concerns` may still be printed;
  **`Reviewable` may not** - see Step 4.
* **Both fail.** Report the failure and stop. No status at all.

## Step 2b: Derive the change surface

```bash
gh pr diff <url> | bash "${CLAUDE_PLUGIN_ROOT}/skills/review-pr/scripts/surface.sh"
```

The script returns `paths` and `entries` - candidate boundary declarations with
their kind, whether they were added, removed, or altered, and the literal before
and after signatures.

**Prune the candidates** against one question: *can code outside the changed
file depend on this name?* Keep it if yes, wherever it appears in the file; drop
it if no, however much it changed. A route path and a config key are on the
surface even though they are statements inside a body, because a caller can
depend on them. Local variables and private helpers are not.

You own this pruning. The script extracts mechanically; a regex cannot decide
reachability across languages.

## Step 3: The council

Invoke `adversarial-council` with `--mode pr` and the four PR-mode inputs:

1. The findings, each with its severity.
2. The pull request URL, its title, and its body.
3. The change surface from Step 2b.
4. The files each finding touches - the reviewer agents name these per finding.

Do not pass `--max-findings`: `--mode pr` carries a cap of 15.

## Step 4: Report

A **report**, not a walk. Present everything at once and ask nothing - the user
is reviewing someone else's pull request and has no decision to make here. The
council's `Asking the user` rules do not apply.

Three parts:

1. **The concerns table**, one row per finding the council did not `drop`:
   location, the concern, its failure scenario or consequence, and the
   recommended fix where the council supplied one. Rows the judges linked as
   dependent are adjacent, dependency first.
2. **A blocking-drop notice**, one line per `blocking` finding both judges
   dropped, where any exist.
3. **One status.**

Every finding the council did not `drop` is a row - including `auto-resolve`,
`needs-user`, findings the judges split on, findings they abstained on,
findings left unjudged by a failed judge, and every finding in an unfiltered
handback. `drop` is the only verdict that removes one.

The status:

* **`Reviewable`** - the table is empty, no blocking-drop notice was printed,
  and both reviewer agents ran.
* **`Concerns`** - the table has at least one row, or a blocking-drop notice
  was printed.
* **`Partial: no concerns from <surviving agent>; <failed agent> did not run`**
  - where `Reviewable` would have been printed but one agent failed. Never
  phrase this so the failed agent is the subject of the no-concerns claim: it
  did not run, so it reported nothing either way.
* **No status at all** - both agents failed.

`Concerns` from a partial review is true: a concern was found, and finding more
would not change that. `Reviewable` is a claim about what is *not* there, and a
review missing a whole class of findings cannot support it.

Use the `DESIGN.md` palette where the terminal supports it: gold for the header,
`alert` for `blocking` rows, `caution` for non-blocking.

## Step 5: Stop

Report and stop. Do not post to GitHub. If the user wants to reply on the pull
request, that is `manage-pr`.
