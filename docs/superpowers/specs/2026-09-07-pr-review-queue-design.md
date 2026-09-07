# Design: review-pr-queue and review-pr skills

Date: 2026-09-07
Branch: `claude/github-pr-review-skill-6ab40e`

## Summary

Two new skills, two new agents, and a parameterisation of the existing
adversarial council.

* `review-pr-queue`, a skill that lists every open pull request waiting on the
  user's review, across all repositories, and ranks them by impact from
  metadata alone. It prints a table: link, what the pull request actually does,
  and whether it can be reviewed immediately or needs undivided attention.
* `review-pr`, a skill that reviews one pull request in depth. It refuses to run
  unless the current workspace is the pull request's own repository. It
  dispatches two reviewer agents over the diff, filters their findings through
  the adversarial council, and reports a table of concerns with a final status
  of `Reviewable` or `Concerns`.
* `pr-reviewer-correctness` and `pr-reviewer-design`, the two agents that
  produce findings from a diff.
* `adversarial-council` gains three arguments so it can judge pull request
  findings as well as spec findings, without changing what it does today.

### Problem this solves

Two separate problems.

The first is queue triage. GitHub shows a list of pull requests awaiting review
with no indication of which ones matter. A three-line copy change and a
four-hundred-line change to authentication look identical in that list. The
user cannot tell, without opening each one, which of them can be cleared in a
minute and which need a clear head. So the queue is either worked in arrival
order, which spends attention badly, or not worked at all.

The second is review depth. A careful review of a substantial pull request
means holding the change, its failure modes, and its downstream consumers in
mind at once. Done by hand it is slow, and done quickly it degrades into
commenting on formatting, because formatting is what is visible without
thinking. The output the user wants is the short list of things that are
actually wrong, and that list is exactly what is hardest to produce.

### Non-goals

* **Reviewing the user's own pull requests.** `review-pr-queue` lists pull
  requests where the user is a requested reviewer. Pull requests the user
  authored are `manage-pr`'s territory.
* **Posting to GitHub.** `review-pr` is read-only. It never posts a review, a
  comment, or an approval. Posting stays with `manage-pr`, which already owns
  the show-before-posting rule and the pull request guard hook's conventions.
* **Managing checkouts.** When the workspace is the wrong repository,
  `review-pr` stops. It does not clone, switch worktrees, or review from the
  diff alone.
* **Per-repository review configuration.** The sensitive-path list ships as a
  default in the skill. `soong-setup` records Notion databases and the commit
  scope rule, and adding a review configuration surface to it is out of scope.
* **Replacing `code-review`.** The existing `code-review` skill reports style
  and simplification findings by design. `review-pr` answers a different
  question and does not call it.

## Files

New:

```
plugins/soong/skills/review-pr-queue/SKILL.md
plugins/soong/skills/review-pr/SKILL.md
plugins/soong/agents/pr-reviewer-correctness.md
plugins/soong/agents/pr-reviewer-design.md
```

Modified:

```
plugins/soong/agents/adversarial-judge.md
plugins/soong/skills/adversarial-council/SKILL.md
plugins/soong/skills/architect/SKILL.md
plugins/soong/.claude-plugin/plugin.json
README.md
```

Both new skills are single-file. Neither has the two-mode routing that gives
`manage-pr` its `reference/` directory. If `review-pr`'s SKILL.md passes about
200 lines, the reviewer agent prompts move to `reference/`.

Version: `0.15.0` to `0.16.0`. This is a feature, and CLAUDE.md assigns
features a minor bump.

README.md gains the `gh` CLI under Requirements. Both skills call it directly
and fail without it.

## Component 1: review-pr-queue skill

### Purpose

Turn the set of pull requests awaiting the user's review into a ranked table
that says which one to open next. Cheap enough to run every morning.

### Cost constraint

The skill reads metadata and diffstats. It never fetches diff content. This is
the constraint that makes the skill habitual rather than occasional, and every
other decision in this component follows from it.

A consequence: the skill cannot know what a change does, only what it touches.
Where metadata does not support a claim about intent, the description says what
changed instead of inventing why.

### Scope

Cross-repository. The skill lists pull requests from every repository where the
user is a requested reviewer, and does not restrict itself to the current
workspace. A queue that shows one repository is not a queue.

This is the opposite of `review-pr`, which is strictly repository-local. The
two skills differ here on purpose: triage answers "what is waiting on me", and
that question has no repository.

### Flow

1. **Check `gh`.** Confirm the CLI is present and authenticated before any
   other call. On failure, stop and name the fix.
2. **Fetch the queue.** `gh search prs --review-requested=@me --state=open`.
3. **Zero results.** Say the queue is empty and stop. This is not an error.
4. **Per pull request, one call.** `gh pr view <url> --json` for: `title`,
   `body`, `additions`, `deletions`, `changedFiles`, `files`,
   `statusCheckRollup`, `reviewDecision`, `isDraft`, `updatedAt`, `author`.
5. **Score, describe, classify.** Per the three sections below.
6. **Render.** Table sorted by impact score, descending.

Drafts are excluded unless the user passes `--include-drafts`.

### Impact score

Three metadata signals:

* **Churn.** `additions + deletions`.
* **Path sensitivity.** Each changed path is matched against a default glob
  list. Authentication, database migrations, payments, CI configuration,
  dependency manifests, and lockfiles score high. Tests, documentation,
  fixtures, and snapshots score low.
* **Blast radius.** How many distinct top-level directories `changedFiles`
  spans. A change confined to one module is narrower than the same line count
  spread over six.

The score orders the table. It is not shown as a number, because a number
invites the user to trust a heuristic more precisely than it deserves.

### Description

One line per pull request, written from title, body, and changed paths, saying
what the pull request does rather than restating its title. A title of
`fix(auth): handle expiry` over changes to a token refresh path and its tests
becomes a line about refresh behaviour, not the title again.

Where the metadata does not support a statement of intent, the line says what
changed. "Adds two files under `migrations/`" is a useful line. An invented
purpose is not.

### Classification

Two values, and the rule is deliberately conservative:

* **`Review now`** requires all three: low churn, no sensitive path touched,
  and CI green.
* **`Requires thinking`** for everything else.

Any sensitive path forces `Requires thinking` regardless of size. A four-line
change to a migration is not a quick review, and the failure mode this rule
guards against is the user clearing it as one.

The asymmetry is intentional. A pull request wrongly marked `Requires thinking`
costs a little time. One wrongly marked `Review now` costs a careless approval.

### Output

A table, in the DESIGN.md palette: gold header, `positron` for `Review now`,
`caution` for `Requires thinking`.

Columns: pull request link, description, classification, and the command to
review it.

Each row carries a literal `/review-pr <url>`. The skill never invokes
`review-pr` itself. Triage is cheap and cross-repository; review is expensive
and repository-local, so chaining them automatically would fire the adjacency
stop most of the time. Printing the command follows the existing pattern where
`architect` ends by printing the `/develop` command.

## Component 2: review-pr skill

### Purpose

Review one pull request in depth and report only the concerns that are real.

### Step 0: the adjacency guard

This runs first, before any other work.

Resolve the target pull request's `owner/repo` from its URL, or from `gh pr
view` when given a number. Resolve the workspace's own repository with `gh repo
view --json nameWithOwner`, which resolves through the worktree's origin.

If they differ, stop. Report the pull request's repository, the workspace's
repository, and that nothing was reviewed. Do not clone, do not switch
worktrees, and do not review from the diff alone.

The guard runs before any agent is dispatched, so a mismatch costs nothing.

The reason for the stop rather than a fallback: both reviewer agents and the
verifier lens read files from disk to check whether a finding is true. Without
the right code present, every finding is unverifiable, and a review that
reports unverifiable findings as concerns is worse than no review.

### Step 1: gather

* `gh pr diff <url>` for the patch.
* `gh pr view <url>` for title, body, and CI status.
* The merge base, so agents read surrounding code at the revision the change
  was written against rather than at the workspace's HEAD.

**Empty or generated-only diff.** If the diff is empty, or touches nothing but
lockfiles and generated files, report that and stop. Do not dispatch agents and
do not call the council.

### Step 2: reviewer agents

Dispatch both in one message so they run concurrently.

* **`pr-reviewer-correctness`** — bugs, error handling, unhandled edge cases,
  concurrency, data loss, security.
* **`pr-reviewer-design`** — API and contract breakage, misleading names at
  module boundaries, structural problems that will cost more later, missing
  coverage on risky paths.

Both agent files state that style, formatting, naming preference, import
order, and "this could be simpler" are not findings.

Each finding carries a concrete failure scenario: inputs or state, and the
wrong outcome that follows. A finding whose failure scenario cannot be stated
is not reported. This requirement is the primary nitpick filter, because a
nitpick has no failure scenario, and being unable to write one is the signal
that a finding is a preference.

The council's `drop` verdict is the backstop, not the first line of defence.
Generating noise and paying two judges to remove it is the expensive way to get
a short list.

### Step 3: council

Send the findings to `adversarial-council` with `--mode pr --max-findings 15`.

### Step 4: output

A table of surviving concerns: location, the concern, and its failure scenario.

Then one status:

* **`Reviewable`** — nothing survived as blocking.
* **`Concerns`** — at least one blocking concern survived.

No status is reported when the evidence was incomplete. See Failure below.

## Component 3: adversarial-judge lens changes

### The problem

The council's value comes from its two judges holding different evidence. The
verifier reads the files a finding names. The architect is forbidden from
reading implementation at all and reasons only about the pull request stack and
its dependencies. Agreement between them means something precisely because it
was not reached from the same facts.

A pull request review has no spec and no pull request stack. If PR mode simply
pointed both existing lenses at the diff, they would hold identical evidence,
and their agreement would stop carrying information. The verdict that would
degrade first is `drop`, which is the verdict that removes nitpicks.

### The PR-mode lens pair

PR mode re-splits the evidence along an axis a diff has:

* **Verifier lens (PR mode).** Evidence is the diff and the files it touches at
  the merge base. The question is unchanged from spec mode: is this finding
  true of the code as it stands? Reads code freely.
* **Integration lens (PR mode).** Evidence is the code that consumes what
  changed — call sites and dependents, found by searching the repository — plus
  the pull request's stated intent. The question is whether the change breaks
  or misleads its callers, and whether it does what the pull request claims. It
  reads code, but different code: never the internals of the changed lines,
  only what depends on them.

The two judges therefore look at the change itself versus everything
downstream of it. The evidence sets are disjoint, so agreement still means
something.

### Implementation

`adversarial-judge.md` gains the integration lens as a third definition,
alongside the existing verifier and architect lenses. The council names one
lens per judge in the dispatch prompt, as it does today.

The verifier lens definition is shared between modes. Its current text
references the spec as evidence; that becomes "the spec or the pull request
diff, whichever the dispatch supplies".

The existing rule holds in both modes: a judge is told which lens it holds, and
a judge not told will try to hold both, which is the one thing that makes the
verdicts stop being independent.

## Component 4: adversarial-council arguments

Three arguments. Every default preserves today's behaviour exactly.

| Argument | Values | Default | Effect |
| --- | --- | --- | --- |
| `--mode` | `spec` or `pr` | `spec` | Lens pair, over-cap message, auto-resolve behaviour. |
| `--max-findings` | integer | 8 in spec mode, 15 in PR mode | The gate threshold. |
| `--no-max-findings` | flag | off | Disables the gate. |

The council is invoked as a skill with named inputs, the way `manage-pr` takes
`--non-interactive`. These are not command line flags on a script.

### What --mode switches

**Lens pair.** `spec` dispatches verifier and architect, as today. `pr`
dispatches verifier and integration.

**Over-cap message.** In `spec` mode, going over the cap means the spec is
unsound and needs rework rather than filtering — the existing reasoning,
unchanged. In `pr` mode it means the pull request is too large to review as one
unit and should be split, which is genuine reviewer feedback where "rework the
spec" would be nonsense.

Both paths keep the existing behaviour: hand back every finding, unfiltered,
and say they are unfiltered.

**Auto-resolve.** In `spec` mode the council edits the spec itself. In `pr` mode
it has nothing it may edit: the code is not the user's, and `review-pr` is
read-only. So `auto-resolve` in PR mode degrades to reporting the obvious fix
alongside the finding rather than applying it.

The existing carve-out — never auto-resolve a change that adds, removes,
re-orders, or re-splits a pull request in the stack — has no PR-mode analogue
and does not apply there.

### The --no-max-findings guard

The flag disables the stop, not the warning. The council accepts it, states the
finding count up front, and confirms before walking a queue larger than the
mode's cap.

Without the guard, the flag would produce a thirty-question walk, which defeats
the purpose of a filtering skill.

### What does not change

The resolution rules, the rebuttal round, the Interactions lists, the blocking
exception, and the judge-failure rules are all mode-independent and are not
modified. They carry to PR mode unchanged.

This is a deliberate limit on the change's blast radius. If one of them turns
out not to carry, that is a follow-up with evidence behind it rather than a
speculative edit now.

## Component 5: architect skill changes

Step 3.5 is updated to invoke the council with `--mode spec --max-findings 8`
explicitly.

This is behaviourally a no-op: both values are the defaults. It makes the
contract visible at the call site, so anyone changing the council's defaults
later can see who depends on them.

The council's own documentation records that an argument-free invocation means
spec mode with a cap of eight.

No other step of `architect` changes.

## Failure

Every path ends with the user knowing what happened, and with no partial work
presented as complete.

| Failure | Behaviour |
| --- | --- |
| `gh` missing or unauthenticated | Stop before any other call. Name the fix. |
| Empty review queue | Say so and stop. Not an error. |
| One `gh pr view` fails during triage | Keep the row, mark it unreadable, continue. One bad pull request must not kill the queue. |
| Repository mismatch in `review-pr` | Hard stop at Step 0, before any dispatch. |
| Pull request not found, or no permission | Stop, and say which of the two it was. |
| Empty or generated-only diff | Report it, skip the council. |
| One reviewer agent fails | Continue with the survivor's findings. Say the review is partial and which lens is missing. |
| Both reviewer agents fail | Report the failure. No status: neither `Reviewable` nor `Concerns`. |
| Council fails | Existing council rules apply: hand back every finding unfiltered, marked unfiltered. |

Two principles, both inherited from the council's own design:

* A failure never makes a finding disappear.
* A failure never produces a clean-looking verdict from missing evidence. This
  is why both reviewer agents failing yields no status at all: `Reviewable`
  from a review that did not happen is the most costly output this skill could
  produce.

## Flow

```
/review-pr-queue
  |
  +-- check gh ------------------------ fail --> stop, name fix
  +-- gh search prs --review-requested
  |     |
  |     +-- zero results -------------------> say empty, stop
  |
  +-- per PR: gh pr view --json (no diff)
  +-- score: churn x path sensitivity x blast radius
  +-- describe from title + body + paths
  +-- classify: Review now | Requires thinking
  +-- render table, each row printing /review-pr <url>

/review-pr <url>
  |
  +-- Step 0: adjacency guard
  |     |
  |     +-- workspace repo != PR repo ------> STOP, report both, nothing run
  |
  +-- Step 1: gh pr diff + gh pr view + merge base
  |     |
  |     +-- empty / generated-only diff ----> report, stop
  |
  +-- Step 2: dispatch both reviewer agents (one message)
  |     pr-reviewer-correctness    pr-reviewer-design
  |     |
  |     +-- both fail ---------------------> report, no status
  |     +-- one fails ---------------------> continue, say partial
  |
  +-- Step 3: adversarial-council --mode pr --max-findings 15
  |     verifier lens (the change)  integration lens (its dependents)
  |     |
  |     +-- over cap ----------------------> hand back unfiltered, "PR too large"
  |     +-- council fails -----------------> hand back unfiltered
  |
  +-- Step 4: table of concerns + Reviewable | Concerns
```

## Cost

`review-pr-queue`: one search call plus one metadata call per pull request. No
diff content, no agents. Designed to be run daily.

`review-pr`: one diff fetch, two reviewer agents, two judges, and up to two
more judges in a rebuttal round. Comparable to a council run under `architect`.
Run per pull request, deliberately.

## Testing

This repository has no automated harness for skills. Verification is manual,
and the plan states these as concrete steps.

1. `/review-pr-queue` against the real queue. Confirm it spans repositories,
   confirm no diff is fetched — visible in the tool calls — and confirm the
   classification on one known-trivial and one known-risky pull request.
2. `/review-pr <url>` from the **wrong** worktree. Confirm it stops at Step 0,
   reports both repository names, and dispatches nothing.
3. `/review-pr <url>` from the correct worktree, on a pull request with a known
   real bug. Confirm the bug survives to the concerns table.
4. `/review-pr <url>` on a formatting-only pull request. Confirm `Reviewable`
   and an empty or near-empty table.
5. `/architect` on a throwaway feature. Confirm the council behaves identically
   to before.

Steps 2 and 4 are the ones that catch this design being wrong: step 2 tests the
guard that makes `review-pr` safe, and step 4 tests the nitpick filter that is
its whole reason for existing. Step 5 is the regression test for the three
shared files.

## Open questions

None blocking. One deferred:

* Whether the council's Interactions lists and judge-failure rules need PR-mode
  adjustments. They are mode-independent today and are assumed to carry
  unchanged. Revisit with evidence from real runs rather than speculatively.

## Decisions and rejected alternatives

**Metadata-only triage, rejecting diff-reading triage.** Reading each pull
request's diff would produce better descriptions, but at a cost that makes the
skill occasional rather than habitual. A queue tool that is too expensive to
run every morning does not solve the problem. The accepted consequence is that
descriptions state what changed where they cannot state intent.

**Adjacency guard in `review-pr` only, rejecting the guard in both skills.**
Restricting triage to the current repository would make both skills
repository-local and simpler to describe, but would require running triage once
per repository to see the full queue. The guard belongs at the point of actual
need, which is the skill that reads files from disk.

**Hard stop, rejecting an offer to switch worktrees.** Offering to clone or
switch would be more convenient, but it puts checkout management inside a
review skill.

**Printing the command, rejecting direct invocation.** Triage is cheap and
cross-repository; review is expensive and repository-local. Chaining them would
fire the adjacency stop most of the time. Printing follows the existing
`architect` to `develop` pattern.

**Purpose-built reviewer agents, rejecting a wrapper around `code-review`.**
Wrapping the existing skill would be the cheapest build, but `code-review`
reports style and simplification findings by design. That would feed the
council exactly the nitpicks the user wants removed, and pay two judges to
remove them.

**Two reviewer agents plus the shared council, rejecting a self-contained
council inside `review-pr`.** A private council would avoid touching
`/architect`'s dependencies, but would duplicate the resolution rules, the
rebuttal round, the Interactions handling, and the failure rules — all of which
already work. Explicit arguments with behaviour-preserving defaults, plus the
step 5 regression test, address the risk of the shared change.

**Verifier plus integration lens, rejecting collapsed lenses and rejecting a
code-blind intent lens.** Collapsed lenses would need no judge changes but
would destroy the independence that makes `drop` meaningful. A second lens
reading only the pull request description would preserve independence cheaply,
but would abstain frequently, and abstentions all route to the user as
questions — which converts a filtering skill into a question generator.

**Explicit council arguments, rejecting an implicit mode inferred from the
inputs.** Inference would need no changes at existing call sites, but would
make the council's behaviour depend on input shape, which is invisible at the
call site and hard to test.

**Raising the cap in PR mode, rejecting a pre-filter to eight findings.**
Pre-filtering would leave the council untouched, but would silently discard
findings before anything adversarial examined them, which is the exact failure
the council exists to prevent.

**Read-only, rejecting posting behind a confirmation.** Posting would duplicate
`manage-pr`'s conventions and its hook interactions, and would turn a skill
that is safe to run on anyone's pull request into an outward-facing one.
