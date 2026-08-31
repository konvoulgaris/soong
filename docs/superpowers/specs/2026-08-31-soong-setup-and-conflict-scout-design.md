# Design: soong-setup, the scope rule, and conflict-scout

Date: 2026-08-31
Branch: `claude/soong-setup-generic-versioning-646d90`

## Summary

Three changes, related by one idea: per-repo configuration stops being the
`architect` skill's private concern and becomes something any skill in the plugin
can declare a requirement against.

* **`soong-setup`** replaces `architect-setup`. One config file per user, flat
  keys per repo, and a capability table that says which keys each capability
  needs. A skill asks "am I configured for X?" and gets a precise answer. The
  same script answers "what is missing across everything?" without any skill
  being invoked.
* **A scope rule for Conventional Commits.** A repo declares whether its commit
  and pull request subjects carry a scope. `pr-guard` enforces the declaration in
  both directions: a repo that requires a scope denies subjects without one, and a
  repo that does not use scopes denies subjects with one. The rule reaches pull
  request titles and `git commit -m` messages. A repo that has answered neither
  way is unaffected, which is what keeps the plugin from denying commits in every
  repository the user has not set up.
* **`conflict-scout`**, an agent that searches the configured Notion databases
  for existing roadmap items and tasks that overlap a proposed feature. The
  `architect` skill runs it twice, and on a hit asks the user whether to abandon,
  build on top, or proceed anyway.

### Problem this solves

**Configuration is welded to one skill.** The config file is named
`architect.json`, the script lives under `skills/architect-setup/scripts/`, and
both `architect` and `develop` reach across into that directory to call it. The
next skill that needs a per-repo setting has three bad options: add a second
config file and a second setup skill, add a key to a file whose name no longer
describes it, or hard-code the setting. The scope rule below is exactly that next
skill, so the problem is immediate rather than hypothetical.

**A repo cannot state its commit conventions.** `pr-guard` accepts a pull request
title with or without a scope, because it cannot know which the repo wants. A
repo where every commit is scoped gets no help catching an unscoped one, and a
repo that never uses scopes gets no help catching a stray `feat(api):`. The guard
also never looks at commit messages at all, so the convention is enforced at the
pull request boundary and nowhere earlier.

**`architect` cannot see work that already exists.** It takes a request,
brainstorms a spec, reviews it, and writes a roadmap item plus a task per pull
request. Nothing in that sequence asks whether the roadmap already holds an item
for this work, or whether an in-flight task touches the same files. The user finds
out after the Notion pages exist, and Notion writes are not reversible by the
skill.

## Section 1: soong-setup

### The config file

```
${XDG_DATA_HOME:-$HOME/.local/share}/soong/soong.json
```

```json
{
  "<project>": {
    "roadmapDb":    "<notion-database-id>",
    "taskDb":       "<notion-database-id>",
    "taskTemplate": "<notion-page-id>",
    "requireScope": true,
    "updatedAt":    "2026-08-31T12:00:00Z"
  }
}
```

`taskTemplate` is `null` when the user skipped it. `requireScope` is absent when
the user has never answered the question; see "The third state" below.

The file stays under `XDG_DATA_HOME` because it is user configuration. The pull
request records that `manage-pr` writes are regenerable state and stay under
`XDG_STATE_HOME`.

The project key is the repository directory name taken from the main checkout, so
every linked worktree of one repository shares a single record. The existing
`default_project` function already does this by reading `--git-common-dir`, and it
carries over unchanged.

Keys are flat rather than grouped per capability. The capability table below is
the thing that knows which key belongs to which capability, so grouping in the
file would duplicate that knowledge and lengthen every `jq` path.

### Migrating from architect.json

**When `soong.json` does not exist and `architect.json` does, the whole file is
copied forward, once, before any command acts on it.** Every project carries
over, not just the one being read or written. The copy is verbatim: no key is
added, transformed, or dropped. It runs before project resolution, so it is
command-agnostic — `get`, `check`, and `set` all get it for free.

A corrupt or non-object `architect.json` is never copied. It reports exit 1 by
name, and `soong.json` is not created, so a bad file cannot be laundered into the
new name.

`architect.json` is never written to and never deleted. It stays on disk,
byte-identical, as a backup.

The read fallback in `read_file()` survives this, for one remaining case: a
legacy file too corrupt to migrate. Without it, a read would report "no mapping"
and exit 3, sending the user into setup, which then refuses to overwrite the
corrupt file — a deadlock. With it, the read names the broken file and exits 1.

### Why the copy is the whole file, not one project

An earlier design seeded nothing and relied on the read fallback alone, with
`set` writing only the keys it was given. That loses data. A repo configured
before the rename, whose owner answers only the `commits` question, gets a fresh
`soong.json` holding `requireScope` and nothing else; the Notion ids are still in
`architect.json` but unreachable, because the no-merge rule below means a present
`soong.json` makes the legacy file invisible. `/architect` would then report the
repo unconfigured, having been configured for months.

Migrating the file up front removes that whole class of failure, and it removes
it for every project at once rather than one `set` at a time.

A repo with both files present reads `soong.json` and ignores `architect.json`
entirely, rather than merging them. Merging two files whose keys overlap needs a
precedence rule the user cannot see. Migration is gated on `soong.json` being
absent, so the two rules do not fight: the copy happens once, and after that the
legacy file is inert.

**A migrated repo keeps its Notion configuration and gains no scope rule.**
`requireScope` was never a key `architect.json` held, so it arrives absent, which
is the not-enforced state. `check commits` reports it missing and `pr-guard` fails
open until the user answers the question. That is correct rather than an
oversight: a repo configured before the rename has never been asked, so it lands
in the same state as a repo that was never configured at all.

### The capability table

The script owns the mapping from capability to required keys.

| Capability | Required keys           | Optional keys  |
| ---------- | ---------------------- | -------------- |
| `notion`   | `roadmapDb`, `taskDb`  | `taskTemplate` |
| `commits`  | `requireScope`         |                |

Adding a capability means adding a row. That is the whole mechanism, and it is
what replaces a version counter: "what is missing" is computed from which
required keys are absent, per capability, rather than tracked as a number that
has to be migrated forward.

A capability's keys are independent. Configuring `commits` does not require
configuring `notion`, and `set` never clears a key it was not given.

### Commands

**`get [project]`** prints the project's whole record as JSON.

| Exit | Meaning                                                    |
| ---- | ---------------------------------------------------------- |
| 0    | record printed                                             |
| 1    | error: no `jq`, unreadable config, corrupt config          |
| 2    | usage error, or not inside a git repository                |
| 3    | this project has no record                                 |

Unchanged from `architect-setup.sh get`, including the exit codes, so a caller
that branches on them keeps working.

**`check <capability> [--project NAME]`** answers "is this capability configured?"

| Exit | Meaning                                                       |
| ---- | ------------------------------------------------------------- |
| 0    | every required key is present                                 |
| 1    | error, as `get`                                               |
| 2    | usage error, unknown capability, or not a git repository       |
| 3    | keys are missing; their names go to stderr                    |

An unknown capability is exit 2, not exit 3. A typo in a skill's `check` call
must not read as "the user needs to run setup."

That rule decides the argument shape. A bare argument to `check` is **always** a
capability, and a project is named with `--project NAME`. With a bare project
allowed, `check comits` would be indistinguishable from a sweep of a project
called `comits`, and would exit 3 — sending the user into setup because a skill
misspelled a word. `set` keeps its bare positional project, because it has no
argument that could be either thing.

**"Present" means `has(key)`, not truthiness.** `requireScope: false` is a fully
configured `commits` capability, and `taskTemplate: null` is a deliberate skip. A
`jq -e` truthiness test would read both as missing. The existing `get`
implementation already carries a comment about this trap, for the same reason, and
`check` hits it twice over. Every presence test in `check` uses `has`.

**`check [--project NAME]`** with no capability sweeps every capability in the table and
prints one line each: the capability, whether it is satisfied, and the names of
any missing keys. Exit 0 when all are satisfied, exit 3 when any is not.

This is the report that answers the original ask. A new capability added to the
table shows up here as unsatisfied for every repo that has not answered its
questions, without any skill having to run first and without a stored version
number to compare against.

**`set`** takes the existing flags plus one:

```
soong-setup.sh set [--roadmap-db ID] [--task-db ID] [--task-template ID]
                   [--require-scope true|false] [project]
```

Two changes from `architect-setup.sh set`:

* `--roadmap-db` and `--task-db` stop being unconditionally required, because a
  repo may configure `commits` alone. `set` requires at least one flag, and
  rejects a call with none.
* `set` merges into the existing record rather than replacing it. Today it
  assigns a whole object, which would erase `requireScope` on any later Notion
  reconfiguration. Merging is what makes the capabilities independent.

`--require-scope` accepts `true` or `false` only. Any other value is exit 2.

Everything else about `set` carries over from `architect-setup.sh` unchanged: the
`chmod 700` on the config directory, because the key names alone leak the user's
project list; the `chmod 600` on the file; and the write through a `mktemp` file
in the target directory followed by a rename, so the write is atomic and cannot
cross devices. The temp file prefix changes from `.architect.` to `.soong.`.

### The third state

`requireScope` has three states, and the distinction is load-bearing:

| State   | Meaning                                                  |
| ------- | -------------------------------------------------------- |
| `true`  | Subjects must carry a scope.                             |
| `false` | Subjects must not carry a scope.                         |
| absent  | The scope rule is not enforced. Everything else is.      |

Absent is not `false`. If absent meant `false`, installing the plugin would start
denying `fix(hooks): ...` in every repository the user has not set up, including
this one. Only `set --require-scope` moves a repo out of the absent state, in
either direction.

### The skill

`plugins/soong/skills/soong-setup/SKILL.md`, replacing
`plugins/soong/skills/architect-setup/SKILL.md`.

```
/soong-setup [capability]
```

With no argument it runs the full sweep, shows what is missing, and asks only for
the missing keys. With a capability it configures that capability alone.

The existing rules carry over unchanged, and they matter most:

* Never invent, guess, or infer a Notion database or template id. Ask, then
  verify through the Notion MCP.
* Verify every database before writing anything. Show the user the resolved
  database titles so a wrong paste is visible.
* If a database does not resolve, or the user cannot supply one, stop and write
  nothing. Say which database was invalid.
* Ask one question at a time.

The `commits` capability asks one question: does this repository require a scope
on commit and pull request subjects? It needs no MCP verification, because the
answer is a boolean rather than an id the script cannot validate.

### Callers

Both `architect` Step 1 and `develop` first-run step 1 need two things: a
yes-or-no answer about the `notion` capability, and the ids themselves. So both
run the same two calls, in this order.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" check notion
bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" get
```

**Step A, `check notion`:**

| Exit | Action                                                                                              |
| ---- | --------------------------------------------------------------------------------------------------- |
| 0    | go to Step B                                                                                        |
| 1    | report the corrupt config and stop. Never run setup to "fix" it; `set` refuses to overwrite one      |
| 2    | report the non-repository or usage error and stop                                                     |
| 3    | say the repo is not configured for Notion, invoke `soong-setup notion`, then re-run Step A once. Anything other than 0 on the re-run stops |

**Step B, `get`:** read `roadmapDb`, `taskDb`, and `taskTemplate` from the JSON.
A non-zero exit here is a bug rather than a user problem, because Step A just
confirmed the keys exist. Report the exit code and stop; do not run setup again,
because the state that produced it is not one setup can resolve.

The exit codes are the same numbers `architect-setup.sh get` used, but exit 3
does not mean the same thing, and the callers' prose must change accordingly.
`get` exit 3 meant "this repo has no record at all." `check notion` exit 3 means
"the `notion` keys are missing," which is also true of a repo that has a record
holding `requireScope` alone. A caller that says "this repo is not configured" on
exit 3 is still correct; one that says "this repo has never been set up" is not.

## Section 2: the scope rule in pr-guard

### Reading the config from a hook

`pr-guard.sh` runs as a `PreToolUse` hook on every `Bash` call. It reads
`requireScope` by calling `soong-setup.sh get` and extracting the key.

**The read is lazy and memoized,** behind a `scope_rule()` function that computes
on first call and caches. This matters more than it looks: the hook fires on every
Bash tool call, and the read spawns three processes — `soong-setup.sh`, the
`git rev-parse` inside it, and `jq`. Measured unconditionally at the top of the
script, that took a trivial `ls` from ~32 ms to ~88 ms per call, roughly 3x, paid
by every command that has nothing to do with pull requests. Behind the function,
only a command that reaches a branch needing the value pays for it.

The cache uses a separate loaded flag rather than testing whether the value is
empty, because the empty string is a legitimate cached result: it is the
not-configured state, and re-reading it on every reference would defeat the point.

One trap for anyone adding a branch that needs the value: call
`require_scope=$(scope_rule)` **inside** the branch, not at the top of the script.
A top-level capture runs in a subshell, so the cache never reaches the branch and
a single command reads the config twice.

**It locates the script relative to its own path,** not through
`CLAUDE_PLUGIN_ROOT`:

```bash
setup="$(cd "$(dirname "$0")/../../skills/soong-setup/scripts" && pwd)/soong-setup.sh"
```

No hook script in this plugin references `CLAUDE_PLUGIN_ROOT` today, and the
variable is set for the hook *command* in `hooks.json` rather than guaranteed
inside the subprocess. Depending on it would give a silent failure: the call
fails, the fail-open rule below turns that into "no scope rule," and the feature
appears to work while enforcing nothing anywhere. Deriving the path from `$0`
keeps one implementation of the project-key derivation, which is the reason for
calling the script at all rather than parsing `soong.json` directly.

Any failure means the scope rule is not enforced: a missing script, a non-zero
exit, a missing `jq`, a missing config file, a corrupt config, or a
`requireScope` that is absent. All collapse to the same behavior, and none
surfaces an error to the user.

The guard also inherits the script's git-repository dependency. `get` resolves
the project key through `git rev-parse --git-common-dir`, so a `gh pr create` or
`git commit` run outside a repository exits 2 and takes the fail-open path. That
is correct — there is no repo whose convention could apply — but it is worth
naming, because the guard itself fires on every Bash call regardless of the
working directory.

Fail-open is deliberate. A guard that starts failing loudly on every Bash command
because a config file got corrupted is worse than one that quietly stops checking
scope. The rest of the guard — the Conventional Commits shape on pull request
titles, the placeholder scope check, the generated-by footer checks — is
unaffected by a failed config read and keeps running.

Because a silent failure is the risk here, the test file gets one case that
asserts the resolved path exists, so a future directory move fails a test rather
than disabling the rule.

### Pull request titles

Branch 1 of the guard already extracts the title from `--title`/`-t` and checks
it. The scope rule splits that check by state.

The placeholder check runs first in all three states, unchanged. `feat(*)`,
`feat(misc)`, `feat(tbd)` and friends are denied because a placeholder satisfies
"has a scope" while carrying no information. Under `false` it is redundant but
harmless.

| State  | Additionally denied | Message                                                              |
| ------ | ------------------- | -------------------------------------------------------------------- |
| `true` | `feat: summary`     | This repo requires a scope. Write `feat(scope): summary`.             |
| `false`| `feat(api): x`      | This repo does not use scopes. Write `feat: summary`.                 |
| absent | nothing             |                                                                       |

The existing regex keeps the scope group optional and the state check is a
separate test on the title, rather than three variant regexes. One pattern
establishes the Conventional Commits shape; a second, smaller test asks whether a
scope is present. Splitting it that way keeps the shape rule in one place.

### Commit messages

A new branch matches `git commit`. It extracts the subject from `-m` /
`--message`; the first occurrence is the subject, and later `-m` flags are body
paragraphs that are not checked for shape.

**The whole branch is gated on the `commits` capability being configured.** When
`requireScope` is absent, the branch does nothing at all — it does not check the
scope rule, and it does not check the Conventional Commits shape either.

That gate is the point. Without it, installing this plugin would start denying
`git commit -m "wip"` in every repository the user has never set up, which is the
same blast radius the "third state" section rejects for the scope rule. Commit
messages are far higher-frequency than pull request titles, so shipping a new
universal denial on them is the more damaging of the two. A repo opts into commit
checking by answering the `commits` question, in either direction.

Pull request titles keep their existing unconditional shape check. That is not a
new denial — the guard has always applied it — so leaving it alone changes
nothing for anyone.

Once the capability is configured, the branch applies the Conventional Commits
shape and the scope rule for the stored state.

**It does not apply the generated-by footer checks.** Those exist for pull
requests and comments. This project's own instructions require a
`Co-Authored-By: Claude Opus 5` trailer on commits, so applying the pull request
footer rule to commits would deny the thing the project requires.

**Generated subjects and amends are exempt from the shape check.** The branch
skips it when the command carries `--fixup` or `--squash`, because git generates
`fixup! <subject>` and `squash! <subject>`, which cannot satisfy Conventional
Commits and are meant to be absorbed by a later rebase. It also skips `--amend`
with no `-m`, which reuses or re-edits an existing message. These are routine in
the stacked-pull-request workflow `develop` builds, so denying them would break
the plugin's own main path.

### Branch order

The existing script comments explain that pull request create and edit is
ordered first because a hook must emit at most one JSON object, so a compound
command that does two guarded things stops at the first.

The commit branch goes **after** the pull request branch and **before** the
comment branch. Textually that is after the pull request `case` block closes and
before the `is_comment_cmd=0` assignment, because the comment branch's detection
runs a `case` over the whole command string and then acts on the result.

So `git commit -m "..." && gh pr create --title "..."` is judged on its title,
not its commit subject. That ordering is a deliberate preference for
the check that has always existed and applies to every repo over the one that is
new and per-repo; a user whose compound command is denied for the title fixes the
title and runs again, at which point the commit subject is checked on its own.

### The ceiling

The hook sees the command string. So it can check `git commit -m "..."` and
cannot check:

* `git commit` with no `-m`, which opens an editor
* `git commit -F <file>`, where the message is in a file
* a message piped in through a heredoc

It also reads the **wrong repo's** convention for a commit aimed somewhere else.
`soong-setup.sh get` derives the project key from the hook process's working
directory, so `git -C /other/repo commit -m ...`, or a `cd /other/repo && git
commit` inside a compound command, is judged against the cwd repo's
`requireScope` rather than the target's. That is a silently wrong answer rather
than a fail-open one.

It stays that way. Parsing `-C` and every `cd` in a compound command to work out
which repository a commit will land in is a shell interpreter, and the wrong
answer here costs a denial the user overrides by fixing the subject. Worth naming
so it reads as a known limit.

For those the guard advises rather than denies, and only when the `commits`
capability is configured — an unconfigured repo hears nothing. It cannot deny
what it cannot read, and a denial based on an unread message would block a
legitimate commit.

`-m` is what an agent actually uses, so that is where the enforcement lands. The
alternative — installing a `commit-msg` git hook per repository — is a separate
mechanism with its own installation, upgrade, and removal problems, and it is not
in scope here. The limit gets a `ponytail:` comment naming the ceiling and that
upgrade path.

### Tests

`plugins/soong/hooks/scripts/pr-guard.test.sh` needs a sandbox before it can hold
any of the cases below. Today it sets no `XDG_DATA_HOME`, creates no repository,
and does not control its working directory — it only pipes commands at the hook.
Once the hook reads config, that suite would read whichever `soong.json` the
developer running it happens to have, and every scope case would pass or fail by
machine.

So the suite first gains what `soong-setup.test.sh` already has: a `mktemp -d`
`XDG_DATA_HOME`, exported, with a `trap` cleanup; a scratch `git init` repository
to `cd` into, so the project key is a fixture name rather than the real checkout;
and a helper that writes one of the three `requireScope` states before each case.
That work comes before the first scope-rule test, not after.

The suite then gains cases for:

* each of the three states, on pull request titles, both denied and allowed
* `true` and `false`, on `git commit -m`, both denied and allowed
* absent, on `git commit -m`: nothing is checked, including the shape, so
  `git commit -m "wip"` is allowed
* a placeholder scope under `true`, still denied
* a corrupt config, a missing config, and a missing `jq`: the guard still runs
  its other checks and enforces no scope rule
* the resolved path to `soong-setup.sh` exists, so a future directory move fails
  a test rather than silently disabling the rule
* `git commit -F file` and a bare `git commit`: advised, not denied
* `--amend` with no `-m`, `--fixup`, and `--squash`: shape check skipped
* a commit with a `Co-Authored-By` trailer: allowed
* `git commit -m "wip" && gh pr create --title "bad"` under `true`: denied on the
  title, and the hook emits exactly one JSON object

## Section 3: conflict-scout

`plugins/soong/agents/conflict-scout.md`.

```yaml
name: conflict-scout
description: <one line, ending in the read-only claim>
model: sonnet
```

**No `tools` key** — and this diverges from the other two agents rather than
matching them. `architect-cobrain` and `adversarial-judge` both pin
`tools: Read, Grep, Glob, Bash`, which is right for them: both are deliberately
barred from Notion, so a closed list is the enforcement.

`conflict-scout` cannot copy that. Querying Notion is its entire job, and a Notion
MCP tool name carries a per-installation id (`mcp__<uuid>__notion-*`) — the same
unportability this repo already works around in `hooks.json`, which matches those
tools with a `mcp__.*__notion-...` wildcard. A frontmatter `tools:` list has no
such wildcard, so a literal name would be correct on one machine and wrong on
every other.

So the key is omitted, which inherits the session's tools, MCP included, and the
read-only constraint is carried in prose in the agent body. The agent says this
about itself, so the omission does not read as an oversight to the next person who
compares the three files.

`model: sonnet` sits alongside the existing `fable` and `opus`, so this is the
third tier the plugin uses rather than a new convention.

Read-only. It never writes to Notion and never edits a file, the same posture as
`architect-cobrain` and `adversarial-judge`.

Sonnet rather than Haiku because the agent's whole job is judging semantic
overlap between prose. Deciding that "add retry to the webhook sender" collides
with "make outbound delivery idempotent" — different vocabulary, same code — is
judgment rather than pattern matching, and a miss costs a duplicate roadmap item
plus a wasted brainstorm and cobrain dispatch. The token difference across a
handful of Notion queries does not compare.

Sonnet rather than Opus because the search space is small and the output is a
short candidate list, not a design.

### Input

The dispatcher passes, explicitly:

* the feature description — the user's request on run 1, the approved spec plus
  the pull request stack plus the files each pull request touches on run 2
* `roadmapDb` and `taskDb`
* which run this is, because the expected precision differs
* on run 2, the cards the user already dismissed with "proceed anyway"

### The sweep

Notion search is keyword-driven, so a single query on the feature name finds only
the items that happen to share vocabulary. The agent runs a fan of queries from
several angles:

1. the feature name and its obvious synonyms
2. the component and module names the change touches
3. file paths and directory names — run 2 has these, run 1 infers what it can
   from the repository
4. domain nouns from the description
5. status, as a ranking signal: items already in flight outrank items sitting in
   a backlog

It queries both databases. It reads the promising candidates in full rather than
judging from titles, because the title is the least reliable part of a card.

It prefers a false positive to a miss. A missed conflict costs a duplicate
roadmap item and a wasted brainstorm. A false positive costs one question that
the user answers with "proceed anyway."

### Output

A short list, most severe first. Roadmap items rank above tasks. `unrelated`
candidates are dropped rather than reported.

```
- Card:     <title> + URL
- Kind:     roadmap item | task
- Status:   <the card's status>
- Overlap:  direct | adjacent | shares-files
- Why:      one or two sentences, quoting the card
- Verdict:  conflicts | builds-on | unrelated
```

More than about six candidates means the sweep was too broad. The agent returns
its six strongest candidates and says the sweep was too broad, rather than
dumping the whole list, because a long list is indistinguishable from noise at the
gate that has to act on it.

The dispatching gate treats that as an ordinary hit: it presents the six and asks
the same three-answer question, prefixed with the agent's own warning that it
found more than it could rank confidently. It is not a fourth answer. A too-broad
sweep is weak evidence, not a reason to stop, and the user is the one who can
tell at a glance whether any of the six is real.

When it finds nothing it says so plainly. That is the common case and it must be
cheap to read.

## Section 4: the two gates in architect

### Gate 1: new Step 1.5

After the configuration check, before brainstorming. Nothing has been spent yet,
so this is the cheapest place in the skill to abandon.

Dispatch `conflict-scout` with the user's request and the two database ids. Those
ids come from Step 1's second call, `get`, which is the only reason Step 1 reads
them before anything needs them.

Nothing found: say so in one line, continue to Step 2.

Candidates found: present them and ask one question with three answers.

| Answer            | Effect                                                                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Abandon**       | Stop. Print the conflicting card URLs. Write nothing, brainstorm nothing.                                                                                      |
| **Build on top**  | Continue to Step 2, carrying the conflicting cards in as context. The spec states what it extends and what it must not duplicate, and Step 5 names the existing cards by title and URL in the new roadmap item's body. |
| **Proceed anyway**| Continue as if nothing was found. Record the dismissed cards so Gate 2 does not re-ask them.                                                                    |

### Gate 2: new Step 2.5

After the user approves the design in Step 2, before the Step 3 cobrain dispatch.

Dispatch `conflict-scout` again with the spec, the pull request stack, and the
files each pull request touches. This is much better input than Gate 1 had, so it
catches overlap that a one-line request could not expose.

The same three answers, with two differences:

* Cards the user dismissed with "proceed anyway" at Gate 1 are not re-asked.
  Asking twice about the same card trains the user to dismiss by reflex.
* "Build on top" means revising the spec rather than restarting the brainstorm:
  go back into the design with the conflicting cards as context, then re-run this
  step on the revised spec.

Abandoning here still costs a brainstorm. It saves the cobrain dispatch, the
two-judge council, the Step 4 walk, and the irreversible Notion writes.

### The dismissed set

Both gates depend on a set of card ids the user dismissed with "proceed anyway",
and Step 2.5 can loop, so the set has to survive a loop.

**It lives in main-thread context.** `architect` has no ledger — unlike
`develop`, which needs one because it resumes across sessions — and adding one for
a set that matters only between two adjacent steps of a single run is a store
whose invalidation rules would outweigh what it holds.

The cost is honest: a context compaction between Step 1.5 and Step 2.5 loses the
set, and Step 2.5 then re-asks about a card the user already dismissed. That is
one redundant question in a rare case, against a persistent store in every case.
The skill states the cost so the behavior reads as a known limit rather than a
bug.

Each dismissal is recorded as the card's Notion page id, not its title. Titles are
editable and can collide.

### Why Gate 2 is not a Step 4 finding

Gate 2's conflicts do not join the Step 4 finding queue.

"Abandon this spec" is a decision, not a fix to apply to a spec, and the Step 3.5
council can drop a finding. A dropped "this duplicates an in-flight roadmap item"
is precisely the swallowed blocker that Step 4's notice machinery exists to
prevent, and routing the conflict through a filter that can drop it reintroduces
the failure the gate was added to remove.

### develop gets no gate

`develop` implements a roadmap item that already exists. Conflict detection
belongs where the item is created, and a gate in `develop` would ask the user to
reconsider work they have already committed to by running the command.

## Files

Renames are `git mv` plus edits, so the history follows the file.

| File                                                        | Change  |
| ----------------------------------------------------------- | ------- |
| `plugins/soong/skills/soong-setup/SKILL.md`                  | moved from `architect-setup/SKILL.md`, then rewritten for the capability argument and the `commits` question |
| `plugins/soong/skills/soong-setup/scripts/soong-setup.sh`     | moved from `architect-setup.sh`, then `check` added and `set` made merging |
| `plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh`| moved from `architect-setup.test.sh`, then extended for `check`, the merge semantics, and the `architect.json` fallback |
| `plugins/soong/skills/architect-setup/`                       | gone once the three files above are moved out of it |
| `plugins/soong/agents/conflict-scout.md`                      | added |
| `plugins/soong/hooks/scripts/pr-guard.sh`                     | scope rule, commit branch |
| `plugins/soong/hooks/scripts/pr-guard.test.sh`                | cases for both |
| `plugins/soong/skills/architect/SKILL.md`                     | Step 1 caller, new Step 1.5, new Step 2.5, Step 5 names the extended cards, frontmatter, Assumes |
| `plugins/soong/skills/develop/SKILL.md`                       | first-run step 1 caller (line 74) and its prose (line 78), frontmatter (line 3), Assumes (line 21), error table (line 442) |
| `README.md`                                                   | requirements name the new setup skill |
| `plugins/soong/.claude-plugin/plugin.json`                    | `0.10.1` to `0.11.0` |

The specs and plans under `docs/superpowers/` also mention `architect-setup`.
They are a historical record of what was designed at the time, so they are left
alone.

### On the version bump

`0.10.1` to `0.11.0` follows this repo's rule, which puts features in the minor.
But the change renames a user-facing skill: `/architect-setup` stops existing, and
`/soong-setup` replaces it. A user who has that command in muscle memory or in a
saved prompt gets a miss.

So the minor bump is correct per the rule and still understates what changed. The
release note has to say the command was renamed. There is no alias, because a
deprecated alias for a personal-archive plugin is a second name to keep working
forever in exchange for saving one correction.

## Out of scope

* A `commit-msg` git hook, which would cover the messages the `PreToolUse` hook
  cannot read. Named as the upgrade path in a `ponytail:` comment.
* A global setup version number with a migration ladder. The capability table
  computes what is missing, so a stored version has nothing to add.
* Backfilling `requireScope` for already-configured repositories. Absent means
  not enforced, so an existing repo behaves exactly as it does today until its
  owner answers the question.
* Any conflict check in `develop`.
