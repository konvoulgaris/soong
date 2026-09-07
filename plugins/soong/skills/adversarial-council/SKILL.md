---
name: adversarial-council
description: Filter a set of architecture review findings down to the ones that need a decision from the user. Sends the findings to two adversarial-judge agents on different evidence lenses, runs one rebuttal round where they disagree, and returns what to drop, what to auto-apply, and what to ask. Use after architect-cobrain returns findings, or when the user runs /soong:adversarial-council.
---

# adversarial-council

Take a set of review findings about a spec, and decide which of them the user
actually has to answer. Two judges classify every finding from different
evidence. Where they disagree, they argue once. What survives goes to the user
one finding at a time.

You run this on the main thread. The judges are subagents; the council is not.
The council's output includes questions for the user, and a subagent cannot ask
the user anything.

## Arguments

| Argument | Values | Default | Effect |
| --- | --- | --- | --- |
| `--mode` | `spec` or `pr` | `spec` | Sets the lens pair, the cap (8 in spec, 15 in PR), the over-cap message, and what happens on agreement. |
| `--max-findings` | integer | none | Overrides the mode's cap. |
| `--no-max-findings` | flag | off | Disables the gate. |

`--max-findings` has no default of its own: the cap comes from `--mode`, so
`--mode pr` alone means a cap of 15. Callers do not pass a value their mode
already implies.

`--no-max-findings` wins over `--max-findings`. Passing both is not an error;
say which one you honoured.

An invocation with no arguments is spec mode with a cap of eight - exactly the
behaviour this skill had before the arguments existed.

## Inputs

You need all four. Two of them differ by mode:

| # | Spec mode | PR mode |
| --- | --- | --- |
| 1 | The findings, each with its severity | unchanged |
| 2 | The spec path | the pull request URL, its title, and its body |
| 3 | The pull request stack, as an ordered list | the change surface |
| 4 | The files or globs each finding touches | unchanged |

Each PR-mode input feeds the lens its spec-mode counterpart fed. The spec gave
both judges the statement of intent, and the pull request body now does. The
stack was the architect lens's whole evidence; the change surface is the
integration lens's.

Input 4 is what makes the verifier lens work, in either mode. A judge told to
check a finding against the code, without being told which files, rediscovers
the codebase from zero and reports what it happened to find.

The last one is what makes the verifier lens work. A judge told to check a
finding against the code, without being told which files, rediscovers the
codebase from zero and reports what it happened to find.

When you were invoked directly rather than by the `architect` skill and the
findings were not supplied, ask for them. Never produce a review of your own to
fill the gap. This skill judges findings; it does not generate them.

## Before dispatching: two gates

**No findings.** Nothing to filter. Say so and stop.

**Over the cap.** The cap is 8 in spec mode and 15 in PR mode, unless
`--max-findings` overrides it or `--no-max-findings` disables the gate.

Do not run the council. Hand every finding back unfiltered, and say they are
unfiltered. What you tell the user differs by mode:

* **Spec mode.** The spec needs rework rather than filtering. Nine or more
  findings means the spec is unsound, and filtering an unsound spec down to
  "only what needs your input" tells the user everything else was fine, which
  is the expensive kind of wrong.
* **PR mode.** The pull request is too large to review as one unit and should
  be split. "Rework the spec" would be nonsense here; "this is too big to
  review" is real reviewer feedback.

Whoever invoked you presents them: the `architect` skill walks them one at a
time in its Step 4, `review-pr` reports them as rows in its Step 4, and when
you were invoked directly you walk them yourself under "Asking the user" below.

Do not raise the cap to get a large set through, and do not drop findings to get
under it.

When `--no-max-findings` was passed, state the finding count up front. Then:
confirm before walking a queue larger than the mode's cap **if you own the
walk**; if a caller owns it - `architect` Step 4, or `review-pr` Step 4 - report
the count, say the gate was disabled, and let the caller decide. Never prompt
about a walk you are not performing.

## Dispatch

Send both judges in one message so they run at the same time. Use the Agent
tool with `subagent_type: adversarial-judge` for each.

Label the findings first. Cobrain emits no identifiers, so give each finding a
label, `F1` upward, in the order cobrain returned them. Use those same labels
for both judges, for both rebuttal dispatches, and in everything you report.
The labels are how you pair the two judges' verdicts, and a verdict you cannot
pair is a verdict you cannot resolve.

Do not renumber for the rebuttal round. A contested subset keeps its original
labels, so `F4` is the same finding in both rounds.

Each judge gets: the whole labelled finding set, the spec path, its own lens
named explicitly, and that lens's evidence.

* **Verifier lens** - also gets the files each finding touches.
* **Architect lens** - also gets the pull request stack, in order, with each
  step's stated dependency.

Name the lens in the prompt. The agent file describes both, and a judge not
told which one it holds will try to hold both, which is the one thing that
makes the two verdicts stop being independent.

## Resolution

Compare the two verdict sets, finding by finding. The rules are ordered, and
the first one that matches decides.

| # | Condition | Outcome |
| --- | --- | --- |
| 1 | both judges `abstain` | straight to the user, skipping any rebuttal |
| 2 | either judge `abstain` | contested |
| 3 | both judges same verdict | act on that verdict |
| 4 | verdicts differ | contested |

Rule 1 precedes rule 3 on purpose. Two judges that both `abstain` do agree, but
they agree that neither can judge the finding, and there is no verdict to act
on. A rebuttal between two judges who both said they lack evidence produces
nothing, so the finding skips the round and goes to the user with each judge's
stated reason. Nothing the council cannot judge is ever dropped.

An `abstain` from either judge is otherwise a split. Uncertainty never counts as
agreement.

Pair the verdicts by label. A finding a judge returned no verdict for counts as
`abstain`. A verdict for a label you did not send counts as nothing, and is
discarded. Never pair by position: a judge that reorders its report would
silently hand you the right verdict for the wrong finding, and no other rule
here can see that.

## Using the Interactions lists

Merge both judges' lists. Use the result only when presenting findings to the
user:

* Findings the judges called duplicates are asked as **one** question, naming
  every finding it covers.
* Where accepting finding A makes finding B moot, ask A first, and ask B only
  if the user's answer to A leaves it standing.

An entry on one judge's list and not the other's still applies. The lists say
which findings relate, not whether a finding is real, so there is nothing to
reconcile and one judge noticing a link is enough. An entry naming a finding
that does not exist is discarded, as with verdicts.

**In PR mode**, deduplication carries unchanged: duplicate findings are one
row, naming every finding it covers.

Dependency entries become **row grouping and ordering only**. PR mode collects
no answer and edits nothing, so no finding becomes moot and none is skipped.
Where an entry says B depends on A, the two are adjacent rows with A first, and
B's row says it follows from A. Both are reported. A dependent finding is never
dropped for being dependent.

The rebuttal round does not carry these lists. The rebuttal settles verdicts,
and an entry cannot change a verdict.

## The rebuttal round

Contested findings go to one rebuttal round, and one only. Dispatch both judges
again, in one message. Each sees the other's verdict and reasoning for the
contested findings, and each keeps its own lens.

Carry the contested subset only. Findings the judges already agreed on are not
re-litigated.

One round means one round. A finding still unsettled after the round goes to the
user, and you do not dispatch a third time to try to settle it. A second round
of disagreement reads as an invitation to run a third, and a council that keeps
arguing never reaches the user.

After the round, apply the same four ordered rules to the two fresh verdicts.
Only rule 3 can act on a finding now, and only on a shared `drop`,
`auto-resolve`, or `needs-user`. Rules 1, 2, and 4 all send the finding to the
user, because there is no further round to send it to:

* **Rule 3, converged.** Act on the shared verdict.
* **Rule 4, still split.** Ask the user, and show **both** judges' positions
  rather than one merged summary. A real disagreement between two informed
  judges is information, and merging it into one paragraph throws that
  information away.
* **Rules 1 and 2, an `abstain` on either side or both.** Ask the user, with
  each judge's stated reason. A shared `abstain` is never acted on, before the
  round or after it.

## PR mode reports; it does not walk

Spec mode ends in an interactive walk, and the `Asking the user` rules below
bind whoever owns it. PR mode ends in a table. The user is reviewing someone
else's pull request and has no decision to make inside the skill.

So in PR mode the `Asking the user` rules **do not apply**, and `review-pr`
Step 4 renders a report. A council that applied them would have `review-pr`
interrogate the user finding-by-finding about a stranger's pull request.

### Every finding you did not drop is a row

That is `auto-resolve`, `needs-user`, findings the judges stayed split on after
the rebuttal, findings either judge abstained on, findings left unjudged by a
failed judge, and every finding in an unfiltered handback. Each carries what its
case needs:

| Case | The row carries |
| --- | --- |
| `auto-resolve` | the finding and the recommended fix |
| `needs-user` | the finding and the judge's reasoning |
| Still split after the rebuttal | **both** judges' positions, not a merged summary |
| Abstained, either side or both | each judge's stated reason and what it said it would need |
| Unjudged, a judge failed | that it was not judged, and why |
| Unfiltered handback | the finding, marked unfiltered |

`drop` is the only verdict that removes a finding. A dropped `blocking` finding
still leaves its notice.

This is spelled out because the omission points the wrong way: read "no shared
verdict" as "did not survive" and the report prints a clean status on a pull
request whose one finding was the one the judges could not settle.

### The blocking-drop notice in PR mode

Print it **below the concerns table**, and let it force the status to
`Concerns` even when the table is empty. `Reviewable` beside a notice saying a
blocker was swallowed is a contradiction, and the reader believes the status.

The notice is still not a question and does not wait for an answer.

## Acting on agreement

* `drop` - dropped, and the user is not told, in both modes. One exception
  below.
* `auto-resolve` - **spec mode:** apply the fix to the spec yourself, before you
  walk the queue, and list every fix you applied when you report. Applying them
  first keeps you from asking the user about a spec you are about to change
  under them. **PR mode:** report the fix alongside the finding; you edit
  nothing, because the code is not the user's and `review-pr` is read-only.
* `needs-user` - **spec mode:** queued for the user. **PR mode:** reported as a
  concern, without the question text. A question with options, printed where no
  answer is collected, reads as a prompt waiting on the user; keep the judge's
  reasoning instead.

One `auto-resolve` you do not apply, **in spec mode**: a fix that would add,
remove, re-order, or re-split a pull request. That change makes cobrain's
findings stale, so it needs a fresh review rather than a quiet edit. Queue it
for the user instead, and say that it changes the stack.

This carve-out has no PR-mode analogue and does not apply there. PR mode has no
stack to re-split, and applies no fixes at all.

### The blocking exception

You may drop a finding marked `blocking`. A shared `drop` of a `blocking`
finding produces a one-line notice to the user.

The notice is not a question and does not wait for an answer. It exists so a
swallowed blocker is visible. Without it, the council's most consequential
decision would be its most silent one.

The exception applies to a shared `drop` in either round. A drop reached only
after arguing is still a drop.

## What you return

* The queue of findings for the user, each with its question, and with both
  positions where the judges stayed split.
* The list of fixes applied under `auto-resolve`.
* One-line notices for dropped `blocking` findings.
* A count of findings dropped silently.

## Asking the user

These rules govern the walk. You walk the queue yourself when you were invoked
directly. Under the `architect` skill, its Step 4 owns the walk and these rules
bind Step 4, so do not walk the queue here and leave Step 4 to walk it again.

Walk in the order cobrain returned the findings, except where an Interactions
entry says one finding must be asked before another. That ordering wins, because
asking a moot question wastes the attention this skill exists to save.

A finding the user's answer has made moot is not asked at all. Say it was
skipped and why. A skipped finding is resolved, not outstanding.

One finding per message. Never a batch, and never a numbered list of questions
in one message.

This holds however short the queue is, and it is the reason this skill exists:
a filtered list dumped in one message costs the user the same attention as an
unfiltered one.

Give your own read alongside the judges' verdicts. A judge can be wrong, and you
may say so with a reason. The council decides what reaches the user; it does not
outrank your judgment on what to do about it.

## When a judge fails

* **One judge fails, or returns output you cannot parse.** Every finding is
  contested. Never decide a finding on one judge's verdict.
* **The same judge fails again in the rebuttal round.** Every finding stays
  contested, so every finding goes to the user. There is no second rebuttal, and
  you do not fall back to the surviving judge's verdicts. One judge's opinion is
  not a council.
* **Both judges fail.** Report the failure and hand every finding back
  unfiltered, exactly as the over-the-cap gate does. They still reach the user
  one at a time.

A council failure must never make a finding disappear. Every path above ends
with the findings in front of the user rather than resolved without one.
