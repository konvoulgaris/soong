# Adversarial Council Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `adversarial-judge` agent and an `adversarial-council` skill to the `soong` plugin, and wire them into the `architect` skill, so that only the review findings needing a decision from the user reach the user.

**Architecture:** One agent file defines a single judge that the council dispatches twice with different evidence lenses. One `SKILL.md` holds the council's orchestration, which the main thread runs. The `architect` skill gains a step that calls the council and a changed step that walks the council's queue. All three artifacts are prose, so none gets unit tests; each gets a structural check, and the whole gets a static checklist plus the spec's seven behavioral scenarios.

**Tech Stack:** Markdown with YAML frontmatter. No scripts, no dependencies, no build step.

**Spec:** `docs/superpowers/specs/2026-08-27-adversarial-council-design.md`

---

## Orientation for the implementer

You are working in the `soong` repository, a personal archive of Claude Code
skills. Read these before you start:

* `CLAUDE.md` at the repository root. Two rules bind this work: Conventional
  Commits, and a version bump in `plugins/soong/.claude-plugin/plugin.json`
  for every change. This is a feature, so the minor version moves.
* The spec, in full. This plan implements it and does not restate its
  reasoning. Where the plan gives you text to write, that text is derived from
  the spec; where you are tempted to improve on it, re-read the spec's
  "Decisions and rejected alternatives" table first. Several obvious-looking
  improvements were considered and rejected there for reasons that are not
  obvious.
* `plugins/soong/agents/architect-cobrain.md`. This is the only existing agent
  in the plugin, and the judge you write is its sibling: same frontmatter
  shape, same read-only-`Bash` rule, same report discipline.
* `plugins/soong/skills/architect/SKILL.md`. You edit this file in Chunk 3.
  Read it now so the edit lands in a file you understand.
* `plugins/soong/skills/write-notion-content/SKILL.md` and
  `plugins/soong/skills/write-technical-content/SKILL.md`. Neither governs the
  files you write here, and knowing why matters: `write-notion-content` covers
  Notion content only, and `write-technical-content` explicitly excludes
  Notion content and gives opposite instructions on articles and sentence
  form. The artifacts in this plan are instructions addressed to a model, and
  the house voice for them is set by the existing skills in this plugin. Match
  those.

### What a "skill" and an "agent" are here

A skill is a markdown file with YAML frontmatter, at
`plugins/soong/skills/<name>/SKILL.md`. An agent is a markdown file with YAML
frontmatter, at `plugins/soong/agents/<name>.md`. In both cases the frontmatter
`name` and `description` decide when the model loads the file, and the body is
instructions addressed to the model rather than to a user.

There is no build step and no registration. The file's presence in the
directory is what installs it. `.claude-plugin/marketplace.json` lists plugins
and not skills or agents, so it does not change.

An agent's frontmatter also carries `model` and `tools`. The `tools` line is
the real grant; the body's prohibitions are instructions the model follows and
are not enforced. This distinction is why the judge's body must state the
read-only rule explicitly even though the body cannot enforce it.

### Testing philosophy for this plan

Nothing here is executable, so nothing here gets a unit test. The three
existing `.test.sh` files in this plugin all accompany bash scripts
(`pr-guard.sh`, `architect-setup.sh`, `gather-context.sh`), and this feature
ships no script.

What each task does instead:

* **A structural check.** After writing a file, assert the things a `grep` can
  actually assert: the frontmatter fields exist and hold the right values, the
  required sections are present, and the forbidden strings are absent. These
  catch the real failure mode for a prose artifact, which is a section quietly
  left out. Run them before you commit.
* **A static checklist** in the final task, which covers what `grep` cannot:
  whether the instructions are coherent when read end to end.
* **The spec's seven behavioral scenarios**, also in the final task. The
  checklist confirms a rule is written down; only a real run confirms it
  behaves. These are the only check here that catches a rule that reads
  correctly and acts wrongly.

The structural checks are written as one-line commands you run in the
terminal. They are not committed as files. A `.test.sh` asserting that a
markdown file contains a heading would be ceremony, and the spec says so.

### On writing the prose

The bodies you write are long. Two rules keep them useful:

* **State the rule, then the reason it exists**, when the reason is not
  obvious. The existing agents and skills in this plugin do this, and it is
  what stops a later reader from "simplifying" a rule that is load-bearing.
  The spec's rationale sections are the source for these.
* **Do not pad.** Every rule in the spec belongs in the artifact. Nothing else
  does. If you find yourself writing a sentence that neither states a rule nor
  explains one, delete it.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `plugins/soong/agents/adversarial-judge.md` | One judge. Classifies findings, reports Interactions. Read by the model when the council dispatches it. |
| `plugins/soong/skills/adversarial-council/SKILL.md` | The council's orchestration, run by the main thread: dispatch, resolve, rebuttal, escalate. |
| `plugins/soong/skills/architect/SKILL.md` | Modified. Gains Step 3.5, and Step 4 changes to walk a queue. |
| `plugins/soong/.claude-plugin/plugin.json` | Version bump, `0.7.1` to `0.8.0`. |

Six tasks across three chunks. Chunk 1 writes the judge, Chunk 2 writes the
council, Chunk 3 wires the `architect` skill and releases.

The order matters. The council's dispatch instructions reference the judge's
output shape, and the `architect` edit references the council's inputs and
outputs. Writing them in this order means each artifact's references point at
something that already exists.

---

## Chunk 1: The judge

### Task 1: The judge's frontmatter, purpose, and lenses

**Files:**

* Create: `plugins/soong/agents/adversarial-judge.md`

- [ ] **Step 1: Write the frontmatter**

The `model` line is the point of the agent. `architect-cobrain` runs on `fable`
and produces the findings; this agent runs on `opus` and filters them. The
`tools` line matches cobrain's exactly, because the judge needs the same
read-only access to the codebase.

```markdown
---
name: adversarial-judge
description: Judges a set of architecture review findings and classifies each one as drop, auto-resolve, needs-user, or abstain. Dispatched twice by the adversarial-council skill, once per evidence lens. Read-only - never edits files and never writes to Notion.
model: opus
tools: Read, Grep, Glob, Bash
---

# adversarial-judge

You judge review findings about an architecture spec. You decide which findings
need a decision from the user, and which do not. You change nothing.

A separate agent produced the findings you are given. You do not review the
spec, and you do not add findings of your own.
```

- [ ] **Step 2: Write the question the judge answers**

This section is the agent's whole job, so it comes before the mechanics. The
distinction it draws, between a finding being interesting and a finding needing
the user, is the one the agent exists to make.

```markdown
## The question

For each finding, answer one question: does resolving this finding need a
decision that only the user can make?

That is not the same question as whether the finding is interesting, or whether
it is correct. A real problem with one correct fix does not need the user; say
so and state the fix. A small problem with a genuine tradeoff does need the
user, because someone has to choose, and it is not you.

The user's attention is the scarce resource here. A finding you send up costs
some of it. A finding you drop costs nothing unless you were wrong.
```

- [ ] **Step 3: Write the lens section**

The council dispatches this same file twice, and the prompt names which lens
the judge holds. The body must therefore describe both, and be explicit that
the judge holds exactly one.

```markdown
## Your lens

The council dispatches two judges, and your prompt names which lens is yours.
You hold one lens, not both. Answer from your lens's evidence.

**The verifier lens.** You get the spec, the findings, and the files each
finding names. Read those files. Your question is whether the finding is true
of the codebase as it stands: does the code do what the finding says it does,
and is the problem still there?

**The architect lens.** You get the spec, the findings, and the pull request
stack with its order and stated dependencies. You do not need to read the
implementation. Your question is what resolving the finding would change: does
it change what gets built, or only how one step gets built?

The other judge holds the other lens and answers the same question from
different evidence. That is the design. When you and the other judge agree,
the agreement means something, because it was not reached from the same facts.
Do not try to cover the other lens as well. A judge that guesses at evidence it
does not hold produces agreement that carries no information.
```

- [ ] **Step 4: Structural check**

```bash
f=plugins/soong/agents/adversarial-judge.md
grep -q '^model: opus$' "$f" && echo "model ok" || echo "MODEL WRONG"
grep -q '^tools: Read, Grep, Glob, Bash$' "$f" && echo "tools ok" || echo "TOOLS WRONG"
grep -q '^name: adversarial-judge$' "$f" && echo "name ok" || echo "NAME WRONG"
grep -c '^## ' "$f"
```

Expected: `model ok`, `tools ok`, `name ok`, and `2` sections so far.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/agents/adversarial-judge.md
git commit -m "feat(architect): add the adversarial-judge agent's lenses"
```

### Task 2: The judge's output shape and prohibitions

**Files:**

* Modify: `plugins/soong/agents/adversarial-judge.md`

- [ ] **Step 1: Write the per-finding output section**

The four verdicts are a closed set, and the council's resolution rules depend
on that. `abstain` is the one a judge under pressure will avoid, so its
legitimacy is stated rather than implied.

```markdown
## What to return, per finding

Every finding you were given gets exactly one verdict. Do not skip one, and do
not invent one.

* `drop` - not real, already handled in the codebase, or too minor to spend
  anyone's attention on.
* `auto-resolve` - real, and one fix is obviously correct. State the fix.
* `needs-user` - real, and resolving it needs a decision the user owns: a
  tradeoff with no dominant answer, a scope or priority call, a product
  question, or a risk only the user can accept.
* `abstain` - you cannot judge this from your lens's evidence. State what you
  would need.

`abstain` is a real answer and not a failure. A guess dressed as a verdict is
worse than an abstention, because the council treats agreement as decisive and
your guess may be the half that agrees. Use it when your lens genuinely does
not reach the finding.

With each verdict:

* **Reasoning**, one or two sentences, from your lens's evidence. Say what you
  checked. If you inferred rather than verified, say that.
* **The question**, only when your verdict is `needs-user`. Write the decision
  as a question, with its options. The user reads this text, so you write it.
  A question that names no options is not finished.
```

- [ ] **Step 2: Write the Interactions section**

This is the payoff for the council batching all findings into one dispatch. A
judge that is not asked for it will not produce it.

```markdown
## What to return, once

One **Interactions** list, written once for the whole set rather than per
finding. It names:

* Findings that are the same concern in different words.
* Findings where accepting one makes another moot.

Name the findings each entry links, and state the relationship in one sentence.
An empty list is a fine answer when the findings are genuinely independent.

You can write this list only because you were given every finding at once. It
is why the council dispatches you once with the whole set instead of once per
finding.

An entry never changes a verdict, including your own. Verdicts are per finding.
The list changes how the main thread presents the findings to the user, and
nothing else.
```

- [ ] **Step 3: Write the prohibitions**

Two separate rules. The read-only rule mirrors cobrain's wording, because the
tool grant does not enforce it. The no-new-findings rule lives here as well as
in the council, so the constraint sits where the behavior originates.

```markdown
## You do not

- Edit, create, or delete any file.
- Rewrite the spec, or write an implementation plan, or write code.
- Report a finding of your own.

You have no Notion tools by design, so you cannot write to Notion at all.

You do have `Bash`, which means the no-edit rule above is not enforced by your
tool grant. Use `Bash` only to read: `git log`, `git diff`, `git show`, `ls`,
`rg`. No redirects, no `sed -i`, no `git` command that changes state.

### No new findings

You classify the findings you are given. A problem you notice that the findings
do not mention belongs in your reasoning for a related finding, and does not
become a new entry. The council discards any verdict for a finding it did not
send you, so inventing one produces nothing.

This is not a rule against noticing things. It is a rule about where a new
concern goes: into the reasoning the main thread reads, not into a list the
council will treat as review output.
```

- [ ] **Step 4: Write the report format**

```markdown
## Report format

Return the verdicts first, in the order the findings were given to you, then
the Interactions list. No preamble, no summary of the spec, no praise.

For each finding: its identifier, your verdict, your reasoning, and your
question when the verdict is `needs-user`.

When you were dispatched for a rebuttal round, you receive a subset of the
findings and the other judge's verdict and reasoning for each. Keep your lens.
Change your verdict when the other judge's evidence actually changes your
answer, and keep it when it does not. Agreeing to end the disagreement is the
one failure mode this round has: the council escalates a real split to the user
on purpose, and a manufactured agreement removes a decision the user should
have made.
```

- [ ] **Step 5: Structural check**

```bash
f=plugins/soong/agents/adversarial-judge.md
for s in "## The question" "## Your lens" "## What to return, per finding" \
         "## What to return, once" "## You do not" "## Report format"; do
  grep -qF "$s" "$f" && echo "ok: $s" || echo "MISSING: $s"
done
for v in '`drop`' '`auto-resolve`' '`needs-user`' '`abstain`'; do
  grep -qF "$v" "$f" && echo "ok: $v" || echo "MISSING: $v"
done
grep -qi 'notion' "$f" && echo "ok: notion prohibition present" || echo "MISSING: notion"
```

Expected: every line reports `ok`.

- [ ] **Step 6: Commit**

```bash
git add plugins/soong/agents/adversarial-judge.md
git commit -m "feat(architect): add the adversarial-judge agent's output contract"
```

---

## Chunk 2: The council

### Task 3: The council's frontmatter, inputs, and gates

**Files:**

* Create: `plugins/soong/skills/adversarial-council/SKILL.md`

- [ ] **Step 1: Write the frontmatter and the opening**

Note the invocation form in the description: `/soong:adversarial-council`, with
the plugin scope, matching how `walkthrough` documents its own.

```markdown
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
```

- [ ] **Step 2: Write the inputs section**

```markdown
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
```

- [ ] **Step 3: Write the two gates**

The cap is the subtle one. It is a signal about the spec, not a resource limit,
and an implementer who reads it as a limit will "fix" it by raising it.

```markdown
## Before dispatching: two gates

**No findings.** Nothing to filter. Say so and stop.

**More than eight findings.** Do not run the council. Tell the user that the
review returned more findings than the council filters, and that the spec needs
rework rather than filtering. The findings then go to the user one at a time,
which is the behavior that existed before this skill.

The cap is a signal and not a resource limit. Nine or more findings means the
spec is unsound. Filtering an unsound spec down to "only what needs your input"
tells the user that everything else was fine, which is the wrong message and
the expensive kind of wrong.

Do not raise the cap to get a large set through, and do not drop findings to
get under it.
```

- [ ] **Step 4: Write the dispatch section**

```markdown
## Dispatch

Send both judges in one message so they run at the same time. Use the Agent
tool with `subagent_type: adversarial-judge` for each.

Each judge gets: the whole finding set, the spec path, its own lens named
explicitly, and that lens's evidence.

* **Verifier lens** - also gets the files each finding touches.
* **Architect lens** - also gets the pull request stack, in order, with each
  step's stated dependency.

Name the lens in the prompt. The agent file describes both, and a judge not
told which one it holds will try to hold both, which is the one thing that
makes the two verdicts stop being independent.
```

- [ ] **Step 5: Structural check**

```bash
f=plugins/soong/skills/adversarial-council/SKILL.md
grep -q '^name: adversarial-council$' "$f" && echo "name ok" || echo "NAME WRONG"
grep -q '/soong:adversarial-council' "$f" && echo "invocation ok" || echo "INVOCATION WRONG"
grep -q 'subagent_type: adversarial-judge' "$f" && echo "dispatch ok" || echo "DISPATCH WRONG"
grep -qF 'eight findings' "$f" && echo "cap ok" || echo "CAP MISSING"
grep -q '^model:' "$f" && echo "ERROR: skills take no model field" || echo "no model field, ok"
```

Expected: `name ok`, `invocation ok`, `dispatch ok`, `cap ok`, `no model field, ok`.

- [ ] **Step 6: Commit**

```bash
git add plugins/soong/skills/adversarial-council/SKILL.md
git commit -m "feat(architect): add the adversarial-council skill's dispatch"
```

### Task 4: The council's resolution, rebuttal, and failure paths

**Files:**

* Modify: `plugins/soong/skills/adversarial-council/SKILL.md`

This is the load-bearing task in the plan. The rules below are ordered, and the
order is the only thing standing between a shared `abstain` and being treated
as a verdict to act on. Write them in this order, and do not reorder them for
readability.

- [ ] **Step 1: Write the resolution rules**

```markdown
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

A finding a judge returned no verdict for counts as `abstain`. A verdict for a
finding you did not send counts as nothing, and is discarded.
```

- [ ] **Step 2: Write the Interactions consumption**

```markdown
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
```

- [ ] **Step 3: Write the rebuttal round**

```markdown
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
```

- [ ] **Step 4: Write the acting and reporting sections**

```markdown
## Acting on agreement

* `drop` - dropped, and the user is not told. One exception below.
* `auto-resolve` - apply the fix to the spec, and list every fix you applied
  when you report.
* `needs-user` - queued for the user.

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

One finding per message. Never a batch, and never a numbered list of questions
in one message.

This holds however short the queue is, and it is the reason this skill exists:
a filtered list dumped in one message costs the user the same attention as an
unfiltered one.

Give your own read alongside the judges' verdicts. A judge can be wrong, and you
may say so with a reason. The council decides what reaches the user; it does not
outrank your judgment on what to do about it.
```

- [ ] **Step 5: Write the failure paths**

```markdown
## When a judge fails

* **One judge fails, or returns output you cannot parse.** Every finding is
  contested. Never decide a finding on one judge's verdict.
* **The same judge fails again in the rebuttal round.** Every finding stays
  contested, so every finding goes to the user. There is no second rebuttal, and
  you do not fall back to the surviving judge's verdicts. One judge's opinion is
  not a council.
* **Both judges fail.** Report the failure. Every finding goes to the user one
  at a time, which is the behavior that existed before this skill.

A council failure must never make a finding disappear. Every path above ends
with the findings in front of the user rather than resolved without one.
```

- [ ] **Step 6: Structural check**

The rule order is the thing most likely to be got wrong, so check it by line
number rather than by presence.

```bash
f=plugins/soong/skills/adversarial-council/SKILL.md
r1=$(grep -n '| 1 | both judges `abstain`' "$f" | cut -d: -f1)
r3=$(grep -n '| 3 | both judges same verdict' "$f" | cut -d: -f1)
[ -n "$r1" ] && [ -n "$r3" ] && [ "$r1" -lt "$r3" ] \
  && echo "rule order ok: rule 1 at $r1 precedes rule 3 at $r3" \
  || echo "RULE ORDER WRONG (r1=$r1 r3=$r3)"
for s in "## Resolution" "## Using the Interactions lists" "## The rebuttal round" \
         "## Acting on agreement" "### The blocking exception" "## What you return" \
         "## Asking the user" "## When a judge fails"; do
  grep -qF "$s" "$f" && echo "ok: $s" || echo "MISSING: $s"
done
grep -qF 'One round means one round' "$f" && echo "ok: one-round rule" || echo "MISSING: one-round rule"
grep -qF 'never acted on' "$f" && echo "ok: shared abstain rule" || echo "MISSING: shared abstain rule"
grep -qF "One judge's opinion is not a council" "$f" && echo "ok: no-fallback rule" || echo "MISSING: no-fallback rule"
```

Expected: `rule order ok` with rule 1's line number lower than rule 3's, then
every remaining line reports `ok`.

- [ ] **Step 7: Commit**

```bash
git add plugins/soong/skills/adversarial-council/SKILL.md
git commit -m "feat(architect): add the adversarial-council skill's resolution rules"
```

---

## Chunk 3: Wiring and release

### Task 5: Wire the council into the architect skill

**Files:**

* Modify: `plugins/soong/skills/architect/SKILL.md`

Read the whole file before editing. You are inserting one step and rewriting
another, and both must read as though they were always there.

- [ ] **Step 1: Insert Step 3.5**

Insert this section between the existing `## Step 3: Review with architect-cobrain`
section and the existing `## Step 4:` section.

```markdown
## Step 3.5: Filter the findings with the council

Invoke the `adversarial-council` skill with cobrain's findings, the spec path,
the pull request stack, and the files each finding touches.

The council sends the findings to two `adversarial-judge` agents on different
evidence, argues out the disagreements, and returns three things: the findings
that need a decision from the user, the fixes it applied to the spec on its own,
and a notice for any `blocking` finding it dropped.

The council can decline to run. With no findings there is nothing to filter.
With more than eight it says the spec needs rework instead, and hands every
finding back unfiltered. Step 4 handles both.
```

- [ ] **Step 2: Rewrite Step 4's opening**

The existing Step 4 opens by saying it walks the agent's findings. Replace that
opening with the two-queue contract, and leave the rest of Step 4 as it stands.

Find the existing opening:

```markdown
Walk the agent's findings **one at a time**, in the agent's priority order. For each one:
```

Replace it with:

```markdown
Walk a queue **one at a time**. Which queue depends on Step 3.5:

* **The council ran.** Walk the council's queue, in the order the council gives.
* **The council did not run**, because the findings were over the cap or because
  both judges failed. Walk the full cobrain finding set, in cobrain's priority
  order.

An empty council queue means the council resolved everything. Say so, list the
fixes the council applied, and go to Step 5. An empty cobrain finding set means
the same without a council.

For each finding in whichever queue you are walking:
```

- [ ] **Step 3: Check Step 4's remaining text still reads correctly**

Step 2 replaced the only line in Step 4 that named the queue. One reference to
"the agent" survives, in sub-step 2, and it now means either cobrain or a judge
depending on which queue you are walking.

Find this line:

```markdown
2. Give your own read: agree, disagree, or a different fix. The agent can be wrong; say
   so when it is, with a reason.
```

Replace it with:

```markdown
2. Give your own read: agree, disagree, or a different fix. A reviewer can be wrong,
   whether it was cobrain or a judge; say so when it is, with a reason.
```

Change nothing else in Step 4. The other three numbered sub-steps, the rule
against batching, and the paragraph about re-dispatching cobrain all stay as
they are.

Then confirm no stale reference is left:

```bash
sed -n '/^## Step 4:/,/^## Step 5:/p' plugins/soong/skills/architect/SKILL.md \
  | grep -n 'the agent' && echo "STALE REFERENCE ABOVE" || echo "ok: no stale agent reference"
```

Expected: `ok: no stale agent reference`.

One more edit in the same step. The paragraph about re-dispatching cobrain does
not yet know the council exists. Find it:

```markdown
Re-dispatch `architect-cobrain` only when a PR was added, removed, or re-ordered.
Changes inside a single PR's scope get resolved here, on the main thread. A re-dispatch
starts from an empty context, so pass the revised stack and what changed, not the whole
spec again.
```

Add one sentence to the end of it:

```markdown
Re-dispatch `architect-cobrain` only when a PR was added, removed, or re-ordered.
Changes inside a single PR's scope get resolved here, on the main thread. A re-dispatch
starts from an empty context, so pass the revised stack and what changed, not the whole
spec again. A re-dispatch produces a new finding set, so Step 3.5 runs again on it.
```

- [ ] **Step 4: Structural check**

```bash
f=plugins/soong/skills/architect/SKILL.md
grep -q '^## Step 3\.5' "$f" && echo "ok: step 3.5 present" || echo "MISSING: step 3.5"
s35=$(grep -n '^## Step 3\.5' "$f" | cut -d: -f1)
s3=$(grep -n '^## Step 3:' "$f" | cut -d: -f1)
s4=$(grep -n '^## Step 4:' "$f" | cut -d: -f1)
[ "$s3" -lt "$s35" ] && [ "$s35" -lt "$s4" ] \
  && echo "ok: order is 3 ($s3) then 3.5 ($s35) then 4 ($s4)" \
  || echo "ORDER WRONG (3=$s3 3.5=$s35 4=$s4)"
grep -qF 'adversarial-council' "$f" && echo "ok: council referenced" || echo "MISSING: council"
grep -qF 'The council did not run' "$f" && echo "ok: two-queue contract" || echo "MISSING: two-queue contract"
grep -qF 'one at a time' "$f" && echo "ok: one-at-a-time preserved" || echo "MISSING: one-at-a-time"
```

Expected: every line reports `ok`, with Step 3.5's line number between Step 3's
and Step 4's.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/architect/SKILL.md
git commit -m "feat(architect): filter cobrain findings through the council"
```

### Task 6: Verification and release

**Files:**

* Modify: `plugins/soong/.claude-plugin/plugin.json`

- [ ] **Step 1: Walk the verification checklist**

This is what the structural checks cannot cover. Read the three artifacts end to
end and confirm each item. Fix what fails before continuing.

**The judge:**

1. The four verdicts are a closed set, and `abstain` is described as a legitimate
   answer rather than a failure.
2. Both lenses are described, and the judge is told it holds exactly one.
3. The read-only rule names `Bash` explicitly and says the tool grant does not
   enforce it.
4. The no-new-findings rule says where a new concern goes instead.
5. The rebuttal instructions warn against agreeing to end the disagreement.

**The council:**

6. The four resolution rules are ordered, rule 1 precedes rule 3, and the text
   says why.
7. The rules are applied twice: once to the first verdicts, once to the rebuttal
   verdicts. Both applications say that a shared `abstain` is never acted on.
8. Every failure path ends with the findings in front of the user.
9. The cap is described as a signal about the spec, not a resource limit.
10. The one-finding-per-message rule appears, and is not weakened for short
    queues.

**The architect skill:**

11. Step 3.5 sits between Step 3 and Step 4 and passes all four inputs.
12. Step 4 names both queues, and the rest of Step 4 reads correctly for either.
13. Step 4 is still the last checkpoint before Notion. The council shortened the
    review and did not remove it.
14. Nothing in the file now tells the main thread to implement anything. This
    skill still only plans.

**All three:**

15. No artifact tells a judge or the council to write to Notion.
16. The invocation form is `/soong:adversarial-council` wherever it appears.

- [ ] **Step 2: Run the behavioral scenarios**

The checklist above is a static read. It confirms the rules are written down,
not that they behave. These seven scenarios are the spec's test plan, and they
are the only thing here that catches a rule that reads correctly and behaves
wrongly.

Each needs a real `architect` run on a spec built to produce the finding shape
under test. That means they cannot all be run at the moment you finish writing
the files: some depend on how the judges actually behave. Run what you can now,
and run the rest on the first real architect invocation. Record which ones you
have not yet exercised rather than marking this step done on a partial pass.

1. **Mixed finding kinds.** A spec producing one finding already handled in the
   code, one with an obviously correct fix, and one with a real tradeoff.
   Confirm the first is dropped silently, the second is applied and reported,
   and only the third reaches the user.
2. **The cap.** A spec producing nine or more findings. Confirm the council does
   not run, the user is told the spec needs rework, and the findings arrive one
   at a time.
3. **The blocking notice, both rounds.** A `blocking` finding both judges drop,
   once where they agree in the first round and once where they agree only after
   the rebuttal. Confirm the one-line notice appears in both, and that it does
   not ask for an answer.
4. **A lens split.** A finding the two lenses read differently. Confirm exactly
   one rebuttal round runs, and that a finding still split afterwards reaches the
   user with both positions shown rather than one merged summary.
5. **A pre-round double abstain.** A finding neither lens can judge. Confirm it
   reaches the user without a rebuttal round.
6. **A post-round abstain.** A finding that goes to a rebuttal round and comes
   back with an `abstain` on one or both sides. Confirm it reaches the user, that
   no third dispatch runs, and that a shared `abstain` is not acted on.
7. **The invariants, on any run.** Confirm no judge edited a file, and that the
   user was never shown two findings in one message.

Scenarios 3 through 6 are the ones worth engineering a spec for. They cover the
paths that only exist because of the ordered rules, and they are where a
plausible-looking rewrite of those rules would show up.

- [ ] **Step 3: Confirm the plugin loads the new files**

There is no build step, so this checks placement rather than registration.

```bash
test -f plugins/soong/agents/adversarial-judge.md && echo "ok: agent in place" || echo "MISSING: agent"
test -f plugins/soong/skills/adversarial-council/SKILL.md && echo "ok: skill in place" || echo "MISSING: skill"
head -1 plugins/soong/agents/adversarial-judge.md | grep -qx -- '---' && echo "ok: agent frontmatter opens at line 1" || echo "AGENT FRONTMATTER WRONG"
head -1 plugins/soong/skills/adversarial-council/SKILL.md | grep -qx -- '---' && echo "ok: skill frontmatter opens at line 1" || echo "SKILL FRONTMATTER WRONG"
grep -c 'adversarial' .claude-plugin/marketplace.json
```

Expected: four `ok` lines, then `0`. `marketplace.json` lists plugins, so it
must not mention the new skill or agent, and you do not edit it.

- [ ] **Step 4: Bump the version**

```bash
sed -i '' 's/"version": "0.7.1"/"version": "0.8.0"/' plugins/soong/.claude-plugin/plugin.json
grep '"version"' plugins/soong/.claude-plugin/plugin.json
```

Expected: `"version": "0.8.0"`.

A feature takes the minor version, per `CLAUDE.md`. If the current version is
not `0.7.1`, another change landed first: bump the minor from whatever is there
rather than forcing `0.8.0`.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/.claude-plugin/plugin.json
git commit -m "chore(release): bump soong to 0.8.0"
```

- [ ] **Step 6: Confirm the tree is clean and the diff is only what you meant**

This runs after the commit, so the working tree should be clean and the whole
feature is six commits back.

```bash
git status --short
git diff --stat HEAD~6
```

Expected: `git status --short` prints nothing, and the diff touches exactly four
paths: the new agent, the new skill, `architect/SKILL.md`, and `plugin.json`.

If you committed a different number of times than the plan's six, count back to
the commit before Task 1 rather than trusting `HEAD~6`.

---

## What this plan does not do

* **No script, and no test file.** Nothing here is executable. The structural
  checks are commands you run, not files you commit.
* **No change to `architect-cobrain`.** It keeps producing every finding it has.
  The council filters them, and cobrain does not need to know the council
  exists.
* **No change to `marketplace.json`.** It lists plugins, not skills or agents.
* **No third judge, no second rebuttal round, no configurable cap.** Each was
  considered and rejected in the spec. If one looks necessary while you are
  implementing, the spec's decisions table says why it is not.
