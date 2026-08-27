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
rework rather than filtering. The findings then go to the user one at a time,
which is the behavior that existed before this skill.

The cap is a signal and not a resource limit. Nine or more findings means the
spec is unsound. Filtering an unsound spec down to "only what needs your input"
tells the user that everything else was fine, which is the wrong message and
the expensive kind of wrong.

Do not raise the cap to get a large set through, and do not drop findings to
get under it.

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
