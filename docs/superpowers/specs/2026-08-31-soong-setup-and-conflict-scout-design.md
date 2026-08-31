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
  request titles and `git commit -m` messages.
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

`get` and `check` read `soong.json`. When `soong.json` does not exist and
`architect.json` does, they read `architect.json` instead. No copy, no prompt, no
migration step the user has to run.

`set` always writes `soong.json`. So the first `set` after this change
effectively migrates the repo, and `architect.json` becomes dead once every
configured repo has been written once. The fallback is read-only and one
direction: nothing writes back to `architect.json`.

A repo with both files present reads `soong.json` and ignores `architect.json`
entirely, rather than merging them. Merging two files whose keys overlap needs a
precedence rule the user cannot see, and the situation only arises after a `set`,
which wrote every key it knows.

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

**`check <capability> [project]`** answers "is this capability configured?"

| Exit | Meaning                                                       |
| ---- | ------------------------------------------------------------- |
| 0    | every required key is present                                 |
| 1    | error, as `get`                                               |
| 2    | usage error, unknown capability, or not a git repository       |
| 3    | keys are missing; their names go to stderr                    |

An unknown capability is exit 2, not exit 3. A typo in a skill's `check` call
must not read as "the user needs to run setup."

**`check [project]`** with no capability sweeps every capability in the table and
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

`architect` Step 1 and `develop` first-run step 1 both call

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" check notion
```

and invoke `soong-setup` rather than `architect-setup` on exit 3. Their exit-code
branching is otherwise unchanged: 0 continues, 1 reports a corrupt config and
stops, 2 reports a non-repository and stops, 3 runs setup and re-checks.

`architect` Step 1 additionally still needs the ids themselves, so it calls `get`
after a successful `check` and reads `roadmapDb`, `taskDb`, and `taskTemplate`
from the JSON.

## Section 2: the scope rule in pr-guard

### Reading the config from a hook

`pr-guard.sh` runs as a `PreToolUse` hook on every `Bash` call. It reads
`requireScope` by calling `soong-setup.sh get` and extracting the key.

Any failure means the scope rule is not enforced: a non-zero exit, a missing
`jq`, a missing config file, a corrupt config, or a `requireScope` that is
absent. All collapse to the same behavior, and none surfaces an error to the
user.

This is deliberate. A guard that starts failing loudly on every Bash command
because a config file got corrupted is worse than one that quietly stops checking
scope. The rest of the guard — the Conventional Commits shape, the placeholder
scope check, the generated-by footer checks — is unaffected by a failed config
read and keeps running.

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

A new branch matches `git commit`. It extracts the subject from:

* `-m` / `--message` — the first occurrence is the subject. Later `-m` flags are
  body paragraphs and are not checked for shape.
* `-F` / `--file` — the message is not in the command.

The branch applies two checks to the subject: the Conventional Commits shape, and
the scope rule in whichever state the config says.

**It does not apply the generated-by footer checks.** Those exist for pull
requests and comments. This project's own instructions require a
`Co-Authored-By: Claude Opus 5` trailer on commits, so applying the pull request
footer rule to commits would deny the thing the project requires.

### The ceiling

The hook sees the command string. So it can check `git commit -m "..."` and
cannot check:

* `git commit` with no `-m`, which opens an editor
* `git commit -F <file>`, where the message is in a file
* a message piped in through a heredoc

For those the guard advises rather than denies. It cannot deny what it cannot
read, and a denial based on an unread message would block a legitimate commit.

`-m` is what an agent actually uses, so that is where the enforcement lands. The
alternative — installing a `commit-msg` git hook per repository — is a separate
mechanism with its own installation, upgrade, and removal problems, and it is not
in scope here. The limit gets a `ponytail:` comment naming the ceiling and that
upgrade path.

### Tests

`plugins/soong/hooks/scripts/pr-guard.test.sh` already covers this script and
gains cases for:

* each of the three states, on pull request titles, both denied and allowed
* each of the three states, on `git commit -m`
* a placeholder scope under `true`, still denied
* a corrupt config, a missing config, and a missing `jq`: the guard still runs
  its other checks and enforces no scope rule
* `git commit -F file` and a bare `git commit`: advised, not denied
* a commit with a `Co-Authored-By` trailer: allowed

## Section 3: conflict-scout

`plugins/soong/agents/conflict-scout.md`.

```yaml
model: sonnet
tools: Read, Grep, Glob, Bash, <Notion MCP read tools>
```

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

More than about six candidates means the sweep was too broad. The agent says so
rather than dumping the list, because a long list is indistinguishable from noise
at the gate that has to act on it.

When it finds nothing it says so plainly. That is the common case and it must be
cheap to read.

## Section 4: the two gates in architect

### Gate 1: new Step 1.5

After the configuration check, before brainstorming. Nothing has been spent yet,
so this is the cheapest place in the skill to abandon.

Dispatch `conflict-scout` with the user's request and the two database ids.

Nothing found: say so in one line, continue to Step 2.

Candidates found: present them and ask one question with three answers.

| Answer            | Effect                                                                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Abandon**       | Stop. Print the conflicting card URLs. Write nothing, brainstorm nothing.                                                                                      |
| **Build on top**  | Continue to Step 2, carrying the conflicting cards in as context. The spec then states what it extends and what it must not duplicate, and Step 5 links the new roadmap item to the existing one rather than opening a parallel track. |
| **Proceed anyway**| Continue as if nothing was found. Record the dismissed cards so Gate 2 does not re-ask them.                                                                    |

### Gate 2: after the brainstorm, before cobrain

After the user approves the design in Step 2, before the Step 3 cobrain dispatch.

Dispatch `conflict-scout` again with the spec, the pull request stack, and the
files each pull request touches. This is much better input than Gate 1 had, so it
catches overlap that a one-line request could not expose.

The same three answers, with two differences:

* Cards the user dismissed with "proceed anyway" at Gate 1 are not re-asked.
  Asking twice about the same card trains the user to dismiss by reflex.
* "Build on top" means revising the spec rather than restarting the brainstorm:
  go back into the design with the conflicting cards as context, then re-run this
  gate on the revised spec.

Abandoning here still costs a brainstorm. It saves the cobrain dispatch, the
two-judge council, the Step 4 walk, and the irreversible Notion writes.

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

| File                                                        | Change  |
| ----------------------------------------------------------- | ------- |
| `plugins/soong/skills/soong-setup/SKILL.md`                  | added, replaces `architect-setup/SKILL.md` |
| `plugins/soong/skills/soong-setup/scripts/soong-setup.sh`     | added, replaces `architect-setup.sh` |
| `plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh`| added, extends the existing test file |
| `plugins/soong/skills/architect-setup/`                       | removed |
| `plugins/soong/agents/conflict-scout.md`                      | added |
| `plugins/soong/hooks/scripts/pr-guard.sh`                     | scope rule, commit branch |
| `plugins/soong/hooks/scripts/pr-guard.test.sh`                | cases for both |
| `plugins/soong/skills/architect/SKILL.md`                     | Step 1 caller, Step 1.5, Gate 2, frontmatter, Assumes |
| `plugins/soong/skills/develop/SKILL.md`                       | step 1 caller, frontmatter, Assumes, error table |
| `README.md`                                                   | requirements name the new setup skill |
| `plugins/soong/.claude-plugin/plugin.json`                    | minor version bump |

## Out of scope

* A `commit-msg` git hook, which would cover the messages the `PreToolUse` hook
  cannot read. Named as the upgrade path in a `ponytail:` comment.
* A global setup version number with a migration ladder. The capability table
  computes what is missing, so a stored version has nothing to add.
* Backfilling `requireScope` for already-configured repositories. Absent means
  not enforced, so an existing repo behaves exactly as it does today until its
  owner answers the question.
* Any conflict check in `develop`.
