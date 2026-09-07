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
  findings as well as spec findings. The defaults preserve its current
  behaviour, so `/architect` is unaffected, but PR mode is not merely a
  configuration of spec mode: it changes the lens pair, the over-cap message,
  what `auto-resolve` and `needs-user` mean, and whether the run ends in an
  interactive walk or a report.

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

Both new skills are single-file, and neither gets a `reference/` directory.
Neither has the two-mode routing that gives `manage-pr` its own, and the
reviewer prompts live in the two agent files rather than in the skill, so there
is nothing a `reference/` directory would hold.

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

If the workspace's repository cannot be resolved at all — no `origin`, or a
local-only or bare checkout — stop the same way. An unresolvable workspace is
not a passing check: it is a check that did not run, and treating it as a match
would review a pull request against whatever code happens to be on disk.

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

### Step 2b: derive the change surface

While the reviewer agents run, derive the change surface from the diff — the
boundary declarations the change adds, removes, or alters. Component 3 defines
what belongs on it and what each entry carries.

`review-pr` owns this, not the council and not a judge. The council never sees
the diff, and a judge that derived its own surface from the patch would be
reading the evidence the surface exists to keep it away from.

### Step 3: council

Send `adversarial-council` the four PR-mode inputs — the findings with their
severities, the pull request URL with its title and body, the change surface,
and the files each finding touches — with `--mode pr`. That mode carries a cap
of 15, so no `--max-findings` is passed.

### Step 4: output

A **report**, not an interactive walk. `review-pr` presents everything at once
and asks nothing: the user is reviewing someone else's pull request, and there
is no decision to collect. The council's `Asking the user` rules do not apply
here — Component 4 states this explicitly, because a reader coming from the
council file would otherwise apply them.

The report has three parts:

1. **The concerns table**, one row per finding the council did not drop:
   location, the concern, its failure scenario, and the recommended fix where
   the council supplied one. `auto-resolve` findings fill the fix column;
   everything else leaves it empty. Rows for findings the judges linked as
   dependent are adjacent, dependency first.
2. **A blocking-drop notice**, one line per `blocking` finding both judges
   dropped, where any exist.
3. **One status.**

**Every finding the council did not `drop` is a row.** That is `auto-resolve`,
`needs-user`, findings the judges stayed split on, findings either judge
abstained on, findings left unjudged by a failed judge, and every finding in an
unfiltered handback. Component 4 gives the per-case row contents. `drop` is the
only verdict that removes a finding, and a dropped `blocking` finding still
leaves a notice.

The status:

* **`Reviewable`** — the table is empty and no blocking-drop notice was
  printed.
* **`Concerns`** — the table has at least one row, or a blocking-drop notice
  was printed.

Stating the status against the rendered table rather than against verdict
categories is deliberate: it cannot drift out of step with the row rule above,
and it has no branch that a new verdict outcome could fall through.

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
* **Integration lens (PR mode).** Evidence is a **change surface** — not the
  patch — plus the code that consumes it and the pull request's stated intent.
  The question is whether the change breaks or misleads its callers, and
  whether it does what the pull request claims.

**The change surface** is what the integration judge receives in place of the
diff. `review-pr` derives it in Step 2b, from the same diff it gives the reviewer
agents, and passes it to the council in Step 3.

The test for inclusion is one question: **can code outside the changed file
depend on this name?** If yes it belongs on the surface, wherever it appears in
the file. If no, it does not, however much it changed.

That test decides the cases a list cannot. `export` is language-specific and
means nothing in this plugin's own Markdown and JSON targets; a Go
lowercase-but-package-visible identifier, a Python module without `__all__`, and
a TypeScript `export type` are three different judgments that the question
settles uniformly.

Included, when the test passes:

* Changed file paths, always. A path entry carries only the path; the entry
  format below applies to named declarations.
* Function, method, and class signatures reachable from outside the file.
* Types, interfaces, and schemas.
* Configuration keys, environment variable names, feature flags.
* Route paths, event names, queue and topic names, CLI flags.
* Database column and index names.

Excluded: local variables, private helpers, control flow, and any renaming
confined to one file.

**A depended-upon name counts even inside a function body.** A route
registration and a config key read are statements, and they are on the surface
because a caller can depend on them. The surface is defined by reachability, not
by syntactic position — which is why the test is a question about dependency
rather than a rule about bodies.

**Each entry carries:** the name, its kind, whether it was added, removed, or
altered, and for an alteration the **before and after signature rendered
literally**, not a prose description of the difference. `handle(id: string)` to
`handle(id: string, opts?: Opts)` is the entry; "added an optional parameter" is
not, because the judge needs the shape to find and assess call sites.

The judge then searches the repository for the dependents of those names, and
reads that code freely.

### Council inputs in PR mode

The council's Inputs section demands four: the findings, the spec path, the pull
request stack, and the files each finding touches. Two of those do not exist in
PR mode, so the contract is restated rather than left to inference:

| Spec mode | PR mode |
| --- | --- |
| The findings, each with its severity | unchanged |
| The spec path | the pull request URL, its title, and its body |
| The pull request stack, in order | the change surface |
| The files each finding touches | unchanged |

The mapping is not arbitrary: each PR-mode input feeds the lens its spec-mode
counterpart fed. The spec gave both judges the statement of intent, and the
pull request body now does. The stack was the architect lens's whole evidence,
and the change surface is the integration lens's.

The rule behind the fourth input carries verbatim: a verifier told to check a
finding without being told which files rediscovers the codebase from zero. In PR
mode the reviewer agents name the files with each finding, so `review-pr` has
them and passes them.

This is the precise answer to a question the lens boundary would otherwise
leave open. The integration judge must know *what* changed in order to find
dependents, but if it received the whole patch the two evidence sets would
overlap and the lens pair's justification would collapse. The change surface is
the minimum that supports the search while staying disjoint from the diff.

**A prohibition is still required.** The integration judge runs with Read,
Grep, Glob, and Bash, and Step 0 guarantees the pull request's own repository is
the workspace. Handed the changed paths, it *can* open those files and read the
changed bodies, and "search for dependents and read that code freely" invites
exactly that. So the integration lens carries the explicit rule:

> Read the dependents. Do not open the changed files' bodies, including to
> check whether a finding is true. That is the verifier's question.

This mirrors the spec-mode architect lens, whose equivalent prohibition is what
makes it work. The change surface reduces what the judge must go looking for —
it arrives already knowing what changed, so it has no reason to read the diff —
but withholding the patch from the input does not by itself keep the evidence
sets apart. Input disjointness plus a prohibition does.

Calling this structural rather than a rule would be the comfortable version and
it would be wrong, in a way that only shows up as two judges quietly agreeing
from the same evidence.

### Implementation

`adversarial-judge.md` gains the integration lens as a third definition,
alongside the existing verifier and architect lenses. The council names one
lens per judge in the dispatch prompt, as it does today.

The verifier lens definition is shared between modes, and two of its sentences
need editing rather than one:

* Its evidence clause names the spec. That becomes "the spec or the pull
  request diff, whichever the dispatch supplies".
* It ends by deferring pull-request-stack reordering to "the other lens's
  question". In PR mode there is no stack and the other lens is integration, so
  the sentence is rewritten to defer to whatever the other lens actually holds:
  stack ordering in spec mode, downstream impact in PR mode.

Leaving the second sentence alone would tell a PR-mode verifier to defer a
question nobody was asked, and point it at a lens that does not exist in that
mode.

The architect lens definition is not modified. It keeps its evidence, its
prohibition, and its wording, and spec mode dispatches it exactly as today.

The existing rule holds in both modes: a judge is told which lens it holds, and
a judge not told will try to hold both, which is the one thing that makes the
verdicts stop being independent.

## Component 4: adversarial-council arguments

Three arguments. The defaults preserve today's behaviour exactly.

| Argument | Values | Default | Effect |
| --- | --- | --- | --- |
| `--mode` | `spec` or `pr` | `spec` | Sets the lens pair, the cap (8 in spec, 15 in PR), the over-cap message, and the acting-on-agreement behaviour. |
| `--max-findings` | integer | none | Overrides the mode's cap. |
| `--no-max-findings` | flag | off | Disables the gate. |

The council is invoked as a skill with named inputs, the way `manage-pr` takes
`--non-interactive`. These are not command line flags on a script.

`--max-findings` has no default of its own. The cap comes from `--mode`, and
`--max-findings` exists only to override it. So `--mode pr` alone yields a cap
of 15, unambiguously.

Consequently neither new call site passes it. `review-pr` invokes the council
with `--mode pr`, and `architect` with `--mode spec`. A caller that passes the
value its mode already implies is stating a default in a second place, which is
the thing that goes stale.

**Precedence.** `--no-max-findings` wins over `--max-findings`. Passing both is
not an error: the explicit disable is the more specific instruction, and the
council says which one it honoured.

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

**PR mode reports; it does not walk.** This is the switch the other two
verdict changes follow from, so it comes first.

Spec mode ends in an interactive walk: the council's `Asking the user` rules
bind whoever owns it to one finding per message, never a batch. PR mode ends in
a table. The user is reviewing someone else's pull request, and there is no
decision for them to make inside the skill — they read the concerns and then go
comment, approve, or think.

So the council's `Asking the user` rules **do not bind `review-pr` Step 4**, and
Step 4 is a report rather than a walk. An implementer who applied those rules
would have `review-pr` interrogate the user finding-by-finding about a stranger's
pull request, which contradicts everything else in Component 2.

**Acting on agreement.** Both non-`drop` verdicts degrade in PR mode, because
both were defined against a walk the council can act on:

* `auto-resolve` — in spec mode the council edits the spec before walking. In PR
  mode it may edit nothing: the code is not the user's, and `review-pr` is
  read-only. So it means *report the obvious fix alongside the finding*.
* `needs-user` — in spec mode this is queued as a question with options, which
  the judge authors and the user answers. In PR mode nothing is queued and
  nothing is answered, so it means *report the finding as a concern*. The
  judge-authored question text is dropped rather than rendered: a question with
  options, printed where no answer is collected, reads as a prompt that is
  waiting for the user. The judge's reasoning is kept; only the question is
  discarded.

`drop` is the one verdict unchanged in both modes.

This is a change to the council's "Acting on agreement" section, not merely a
new mode setting, and the spec records it as such.

The existing carve-out — never auto-resolve a change that adds, removes,
re-orders, or re-splits a pull request in the stack — has no PR-mode analogue
and does not apply there.

**Where a degraded finding lands.** Both `auto-resolve` and `needs-user`
findings appear in `review-pr`'s concerns table like any other survivor, and
both count toward `Concerns`. `auto-resolve` fills the recommended-fix column;
`needs-user` leaves it empty.

**Where a finding with no shared verdict lands.** The three verdicts above are
the outcomes of resolution rule 3, where both judges agreed. Rules 1, 2, and 4
— both judges abstain, either judge abstains, and verdicts still differ after
the rebuttal — produce no verdict to act on. So do the judge-failure rules,
which make *every* finding contested when one judge fails.

All of them are concern rows, and all count toward `Concerns`:

* **Still split after the rebuttal.** One row, showing **both** judges'
  positions rather than a merged summary, per the council's existing rule. A
  real disagreement between two informed judges is information.
* **Abstained, on either side or both.** One row, carrying each judge's stated
  reason and what it said it would need.
* **Contested because a judge failed.** One row, saying the finding was not
  judged and why.

The recommended-fix column is empty for all three.

This is spelled out because the omission pointed the wrong way. An implementer
who saw only rule 3's outcomes mapped could read "no shared verdict" as "did
not survive", and print `Reviewable` on a pull request whose one finding was
the one the judges could not settle. The council's own principle governs here:
a finding it cannot judge is never resolved without the user seeing it. In a
report, being seen means being a row.

**Where unfiltered handbacks land.** When the council goes over the cap or
fails outright, it returns every finding with no verdicts at all. Each becomes
a concern row, marked unfiltered, and the status is `Concerns`. The arithmetic
would force that anyway — an over-cap set is at least 16 findings and a failure
handback at least one — but the rule is stated rather than derived.

This is explicit because the alternative is the worst bug this design could
have: a real bug is given a verdict that means "not a plain concern", degrades
to a report, and — with no home in the output — disappears, yielding
`Reviewable` on a pull request with a known defect. In PR mode `auto-resolve`
means *the fix is obvious* and `needs-user` means *the call is yours*. Neither
means *the finding is minor*. **Only `drop` removes a finding.**

### The --no-max-findings guard

The flag disables the stop, not the warning. The council accepts it and states
the finding count up front.

Who confirms depends on who walks the queue, which the council already tracks:

* **Invoked directly**, so the council walks the queue itself: it confirms
  before walking a queue larger than the mode's cap.
* **Invoked by a caller that owns the walk** — `architect` Step 4, or
  `review-pr` Step 4: the council does not confirm. It reports the count and
  says the gate was disabled, and the caller decides. The council must not
  prompt about a walk it is not performing.

Without the guard, the flag would produce a thirty-question walk, which defeats
the purpose of a filtering skill.

**No caller passes this flag.** Neither new skill requests it, and `architect`
does not. It exists for direct invocation, where the user has asked for an
unfiltered walk and has said so explicitly. If that case never arises in
practice, the flag should be removed rather than kept for symmetry.

### What does not change

Genuinely mode-independent, and not modified:

* The four verdict-pairing rules, and pairing by label rather than position.
* The rebuttal round: one round, the contested subset only, original labels.
* The judge-failure rules.
* The blocking exception itself: a shared `drop` of a `blocking` finding is
  permitted, and produces a notice. Where that notice goes in PR mode, and what
  it does to the status, is specified below.
* Interactions **deduplication**: findings the judges called duplicates are
  reported as one row, naming every finding it covers. Spec mode asks them as
  one question; the collapsing is the same.

**Two rules need a PR-mode reading**, and neither is deferred:

**The `Asking the user` rules do not apply.** PR mode reports rather than
walks, per "PR mode reports; it does not walk" above. One finding per message,
moot-skipping, and asking A before B are all walk rules, and there is no walk.

**Interactions dependency entries become row grouping and ordering.** In spec
mode, "where accepting finding A makes finding B moot, ask A first" depends on
an acceptance the council can act on. PR mode has no acceptance: nothing is
edited and no answer is collected, so no finding ever becomes moot and nothing
is skipped.

What survives is presentational. Where an entry says B depends on A, the two
are adjacent rows with A first, and B's row says it follows from A. Both are
reported. **A dependent finding is never dropped for being dependent** — that
would silently discard a real concern on the strength of a relationship, which
is the one thing PR mode has no mechanism to resolve.

Deduplication still collapses: findings the judges called duplicates are one
row, naming what it covers.

### The blocking-drop notice in PR mode

The blocking exception lets both judges agree to `drop` a finding marked
`blocking`, and requires a one-line notice so a swallowed blocker stays
visible.

In PR mode that notice is printed **below the concerns table**, and it forces
the status to `Concerns` even when the table is empty.

Without this rule the exception would produce the design's worst output: a
pull request whose only finding was blocking, dropped by both judges, printed
as `Reviewable` with a footnote saying a blocker was swallowed. `Reviewable`
next to that notice is a contradiction, and the reader believes the status.

This is a genuine PR-mode addition. Spec mode has no equivalent, because there
the notice lands in a walk the user is already reading rather than beside a
one-word verdict.

The notice keeps the exception's other properties: it is not a question, and it
does not wait for an answer.

## Component 5: architect skill changes

Step 3.5 is updated to invoke the council with `--mode spec`.

This is behaviourally a no-op — `spec` is the default mode, and it carries the
cap of 8 that Step 3.5 gets today — but it makes the mode visible at the call
site, so anyone adding a third mode later can see which callers assumed the
default.

It does not pass `--max-findings`. The cap follows from the mode, and repeating
it here would state the same default in two places.

The council's own documentation records that an argument-free invocation means
spec mode with a cap of eight.

No other step of `architect` changes. In particular Step 4 keeps ownership of
the walk, and the council continues not to present findings itself.

## Failure

Every path ends with the user knowing what happened, and with no partial work
presented as complete.

| Failure | Behaviour |
| --- | --- |
| `gh` missing or unauthenticated | Stop before any other call. Name the fix. |
| Empty review queue | Say so and stop. Not an error. |
| One `gh pr view` fails during triage | Keep the row, mark it unreadable, continue. One bad pull request must not kill the queue. |
| Repository mismatch in `review-pr` | Hard stop at Step 0, before any dispatch. |
| Workspace repository unresolvable — no `origin`, or a local-only or bare checkout | Hard stop at Step 0, same as a mismatch. Say the workspace repository could not be resolved and name the pull request's. Never proceed on the assumption that an unresolvable workspace is the right one. |
| Pull request not found, or no permission | Stop, and say which of the two it was. |
| Empty or generated-only diff | Report it, skip the council. |
| One reviewer agent fails | Continue with the survivor's findings, and report them. Say the review is partial and which agent is missing. `Concerns` may be printed. **`Reviewable` may not** — it is replaced by `Partial: no concerns found by <agent>`. |
| Both reviewer agents fail | Report the failure. No status: neither `Reviewable` nor `Concerns`. |
| Council fails | Existing council rules apply: hand back every finding unfiltered, marked unfiltered. |

Two principles, both inherited from the council's own design:

* A failure never makes a finding disappear.
* A failure never produces a clean-looking verdict from missing evidence.

The second principle is why the status is withheld in the two failure rows
above, and why the withholding is asymmetric. `Concerns` from a partial review
is true — a concern was found, and finding more would not change that.
`Reviewable` from a partial review is a claim about what is *not* there, and a
review missing a whole class of findings cannot support it. A design-heavy pull
request reviewed by the correctness agent alone would otherwise print
`Reviewable` having never examined a contract change.

Both agents failing yields no status at all, because then even `Concerns` has
nothing behind it.

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
  |     +-- workspace repo unresolvable ----> STOP, same
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
  +-- Step 2b: derive change surface from the diff  (review-pr owns this)
  |
  +-- Step 3: adversarial-council --mode pr        (mode carries cap 15)
  |     inputs: findings | PR url+title+body | change surface | files touched
  |     verifier lens              integration lens
  |     (patch + changed files)    (change surface + dependents,
  |                                 must not open changed bodies)
  |     |
  |     +-- over cap ----------------------> hand back unfiltered, "PR too large"
  |     +-- council fails -----------------> hand back unfiltered
  |     |
  |     +-- drop ---------------------------> gone
  |     +-- drop of a `blocking` finding ---> notice, forces Concerns
  |     +-- auto-resolve -------------------> concern + recommended fix
  |     +-- needs-user --------------------> concern (question text dropped)
  |
  +-- Step 4: report, not a walk
        table of concerns (+ fix column)
        + blocking-drop notices
        + Reviewable | Concerns
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
   reports both repository names, and dispatches nothing. Repeat in a directory
   with no `origin` and confirm the same stop.
3. `/review-pr <url>` from the correct worktree, on a pull request with a known
   real bug. Confirm the bug survives to the concerns table.
4. `/review-pr <url>` on a formatting-only pull request. Confirm `Reviewable`
   and an empty or near-empty table.
5. `/review-pr <url>` on a pull request with a real bug that has one obvious
   fix — the shape the council resolves as `auto-resolve`. Confirm the finding
   appears in the table with its fix, and that the status is `Concerns` and not
   `Reviewable`. Confirm the same for a `needs-user` finding, whose row appears
   with an empty fix column and no dangling question text.
6. `/review-pr <url>` on a pull request that produces a single `blocking`
   finding both judges drop. Confirm the notice prints and the status is
   `Concerns` despite an empty table.
7. `/architect` on a throwaway feature. Confirm the council behaves identically
   to before.

Steps 2, 4, 5, and 6 are the ones that catch this design being wrong. Step 2
tests the guard that makes `review-pr` safe. Step 4 tests the nitpick filter
that is its whole reason for existing. Steps 5 and 6 test the three paths where
a real finding could fall out of the output and yield `Reviewable` on a
defective pull request — a degraded `auto-resolve`, a degraded `needs-user`, and
a dropped blocker. Step 7 is the regression test for the three shared files.

Step 6 is the hardest to stage, since it depends on the judges agreeing to drop
something marked blocking. If a natural case cannot be found, verify it by
handing the council a synthetic finding set rather than skipping the step.

## Open questions

None blocking, and none deferred. An earlier draft deferred whether the
council's Interactions lists and judge-failure rules carry to PR mode. Both are
settled in Component 4 under "What does not change":

* Deduplication carries: duplicate findings are one row.
* The judge-failure rules carry unchanged, and Component 4 says where the
  findings they leave contested go in the report.
* Interactions **dependency** entries carry as row grouping and ordering only.
  PR mode collects no answer and edits nothing, so no finding becomes moot and
  none is skipped. Both findings are reported, adjacent, dependency first.
* The `Asking the user` rules do not carry. PR mode reports rather than walks.

One thing to watch rather than decide now:

* `--no-max-findings` has no caller. If direct invocation never needs it, remove
  it rather than keeping it for symmetry.

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
step 7 regression test, address the risk of the shared change.

**Verifier plus integration lens, rejecting collapsed lenses and rejecting a
code-blind intent lens.** Collapsed lenses would need no judge changes but
would destroy the independence that makes `drop` meaningful. A second lens
reading only the pull request description would preserve independence cheaply,
but would abstain frequently. In a mode that reports rather than asks, every
abstention becomes a row saying the lens could not judge the finding, which
fills the table with non-findings and leaves the nitpick filtering to the
verifier alone. A lens that mostly abstains is not a second opinion.

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

**A change surface for the integration lens, rejecting giving it the full
patch.** Handing the integration judge the diff would be simpler to implement
and to describe. But both judges would then hold the patch, the evidence sets
would overlap, and the lens pair's entire justification — that agreement means
something because it was reached from different facts — would fail. Deriving a
signature-level surface is extra work in `review-pr` that buys the property the
design depends on. It does not remove the need for a prohibition: the judge can
reach the changed files on disk regardless of what it was handed, so the lens
carries an explicit rule not to open them, exactly as the spec-mode architect
lens does.

**A reachability test for the change surface, rejecting a closed list of
declaration kinds.** A list has to answer "is this exported?" in every language
the skill might meet, and the word means nothing for the Markdown and JSON this
plugin itself targets. One question — can code outside this file depend on the
name — decides those cases uniformly, and also settles the awkward ones a list
gets wrong, like a route registration or a config key read that lives inside a
function body but is depended on from outside it.

**PR mode reports, rejecting reusing the council's interactive walk.** The walk
exists because a spec author has decisions to make and the council can act on
them. A reviewer of someone else's pull request has none to make inside the
skill, and applying the one-finding-per-message rule there would interrogate the
user about a stranger's code. Naming PR mode a report is also what makes the
degraded verdicts coherent: there is no answer to collect, so `needs-user`
cannot mean "ask", and Interactions dependency entries cannot mean "skip if
moot".

**A dropped blocker forces `Concerns`, rejecting `Reviewable` plus a notice.**
An earlier draft's status rule allowed a pull request whose only finding was a
dropped blocker to print `Reviewable` with a footnote saying a blocker was
swallowed. The status is the part a reader trusts, and a one-word verdict
contradicted by its own footnote is worse than either half alone.

**Cap derived from `--mode`, rejecting a mode-dependent default on
`--max-findings`.** An earlier draft gave `--max-findings` a default of "8 in
spec mode, 15 in PR mode" and had both callers pass the value explicitly. That
states the same default twice and leaves a reader unable to tell what `--mode
pr` alone does. The cap now belongs to the mode, and `--max-findings` only
overrides it.

**Degraded verdicts stay concerns, rejecting a separate resolved-findings
section.** Reporting degraded `auto-resolve` or `needs-user` findings apart
from the concerns table would read as "handled", and a `Reviewable` status
alongside a list of real bugs is the costliest output this skill could produce.
In PR mode `auto-resolve` means the fix is obvious and `needs-user` means the
call is the user's. Neither means the finding is minor, and only `drop` removes
one.
