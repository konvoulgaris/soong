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

## Inputs

You need all four:

* The findings, each with its severity.
* The spec path.
* The pull request stack, as an ordered list.
* The files or globs each finding touches.

The last one is what makes the verifier lens work. A judge told to check a
finding against the code, without being told which files, rediscovers the
codebase from zero and reports what it happened to find.

When you were invoked directly rather than by the `architect` skill and the
findings were not supplied, ask for them. Never produce a review of your own to
fill the gap. This skill judges findings; it does not generate them.

## Before dispatching: two gates

**No findings.** Nothing to filter. Say so and stop.

**More than eight findings.** Do not run the council. Tell the user that the
review returned more findings than the council filters, and that the spec needs
rework rather than filtering. Hand every finding back unfiltered, and say they
are unfiltered. Whoever invoked you walks them one at a time: the `architect`
skill does that in its Step 4, and when you were invoked directly you walk them
yourself, under the rules in "Asking the user" below.

The cap is a signal and not a resource limit. Nine or more findings means the
spec is unsound. Filtering an unsound spec down to "only what needs your input"
tells the user that everything else was fine, which is the wrong message and
the expensive kind of wrong.

Do not raise the cap to get a large set through, and do not drop findings to
get under it.

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

## Acting on agreement

* `drop` - dropped, and the user is not told. One exception below.
* `auto-resolve` - apply the fix to the spec yourself, before you walk the
  queue, and list every fix you applied when you report. Applying them first
  keeps you from asking the user about a spec you are about to change under
  them.
* `needs-user` - queued for the user.

One `auto-resolve` you do not apply: a fix that would add, remove, re-order, or
re-split a pull request. That change makes cobrain's findings stale, so it needs
a fresh review rather than a quiet edit. Queue it for the user instead, and say
that it changes the stack.

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
