# Notion Reminder Hook and write-technical-content Skill Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `PreToolUse` hook that reminds the agent to follow the
`write-notion-content` skill before a Notion prose write, and add a new
`write-technical-content` skill that applies ASD-STE100 rules to technical
documentation.

**Architecture:** Two independent additions to the `soong` Claude Code plugin.
The hook is one bash script registered in `plugins/soong/hooks/hooks.json`; it
reads the tool name from the hook payload on stdin and prints an
`additionalContext` reminder for three Notion MCP tools. The skill is a
`SKILL.md` plus one bundled reference file; it has no hook and no executable
part.

**Tech Stack:** Bash, `jq`, Claude Code plugin hooks (`PreToolUse` with
`hookSpecificOutput.additionalContext`), Claude Code skills (Markdown with YAML
frontmatter).

**Spec:** [2026-07-30-technical-content-skill-and-notion-reminder-hook-design.md](../specs/2026-07-30-technical-content-skill-and-notion-reminder-hook-design.md)

---

## Context you need before starting

This repository is a Claude Code plugin marketplace. Everything lives under
`plugins/soong/`. There is **no test framework, no package manager, and no build
step**. "Running the tests" here means piping a JSON payload into a bash script
and checking stdout and the exit code by hand. Do not add a test framework, and
do not add `npm`, `pytest`, or a `Makefile`.

Read these three files before you touch anything. They are short, and every
convention in this plan comes from them:

```bash
cat plugins/soong/hooks/hooks.json
cat plugins/soong/hooks/scripts/brainstorm-skill-worktree-first.sh
cat plugins/soong/skills/write-notion-content/SKILL.md
```

Conventions those files establish, which you must match:

- Hook scripts live in `plugins/soong/hooks/scripts/`, are mode `755`, start with
  `#!/usr/bin/env bash`, and have **no** `set -euo pipefail`. Do not add one; it
  would deviate from all three existing scripts.
- A hook script reads the whole payload once with `input=$(cat)`, then pipes that
  variable into `jq`. Reading stdin twice does not work, because the first read
  consumes it.
- Output is built with `jq -Rs` so the message is correctly JSON-escaped. Never
  hand-build the JSON with `printf`.
- Each entry in `hooks.json` has a `statusMessage`.
- Skills live at `plugins/soong/skills/<name>/SKILL.md` with YAML frontmatter
  holding `name` and `description`.

**How a `PreToolUse` hook signals "no opinion":** exit `0` with empty stdout. Only
exit code `2` blocks a tool call. This hook must never block, so every path other
than the reminder path is a bare `exit 0`.

**Terminology:** in this plan, "the reminder" is the one-line string the hook
injects. "The three prose tools" means `notion-create-pages`,
`notion-update-page`, and `notion-create-comment`.

---

## File Structure

**Change 1, the hook.** Two files, one new and one modified.

- Create `plugins/soong/hooks/scripts/notion-content-reminder.sh`. Sole
  responsibility: decide whether the current tool call writes Notion prose, and
  if so print the reminder. It holds no state and reads no other file.
- Modify `plugins/soong/hooks/hooks.json`. Registers the script as a third
  `PreToolUse` entry. This is the only file that knows the matcher regex.

The matcher lives in `hooks.json` and the `case` re-check lives in the script.
The two are loose at opposite ends: the matcher is unanchored and matches any
name containing one of the three strings, while the script's `case` patterns are
right-anchored and match only names ending in them. A call must pass both, so the
pair is stricter than either layer alone. Keep the two lists in sync when adding
a tool.

**Change 2, the skill.** Two new files.

- Create `plugins/soong/skills/write-technical-content/SKILL.md`. Holds the 12
  writing rules, the scope boundaries, and the pointer at the reference file.
- Create
  `plugins/soong/skills/write-technical-content/reference/approved-words.md`.
  Holds the substitution table and the protected-terms list. Split out from
  `SKILL.md` so the table is loaded only when a word choice is actually in
  question.

**Shared.** `plugins/soong/.claude-plugin/plugin.json`, version `0.3.0` to
`0.4.0`, bumped once at the end for both features.

---

## Chunk 1: Notion content reminder hook

### Task 1: The reminder script

**Files:**
- Create: `plugins/soong/hooks/scripts/notion-content-reminder.sh`
- Test: none. Verification is the two `echo | bash` commands in steps 2 and 5.

- [ ] **Step 1: Write the failing check**

There is no test file to write, so the check is a command you run against a
script that does not exist yet. Save this to your scratch space or just keep it
to hand, you will run it three times in this task:

```bash
echo '{"tool_name":"mcp__abc__notion-create-pages"}' | bash plugins/soong/hooks/scripts/notion-content-reminder.sh
```

- [ ] **Step 2: Run it to make sure it fails**

Run the command from step 1.

Expected: a failure, because the file is absent.

```
bash: plugins/soong/hooks/scripts/notion-content-reminder.sh: No such file or directory
```

If you instead see JSON, you are in the wrong directory or the file already
exists. Stop and check `pwd` and `git status`.

- [ ] **Step 3: Write the minimal script**

Create `plugins/soong/hooks/scripts/notion-content-reminder.sh` with exactly
this content:

```bash
#!/usr/bin/env bash
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')

case "$tool" in
  *notion-create-pages|*notion-update-page|*notion-create-comment) ;;
  *) exit 0 ;;
esac

printf '%s' "Writing Notion content. Follow the soong write-notion-content skill for style and format. Invoke it now if it is not already loaded." \
  | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:.}}'
```

Three things to note, so you do not "improve" them:

- The `case` patterns are `*notion-...` with a leading star, because the real
  tool name carries an install-specific server id prefix, for example
  `mcp__386f596a-2fe4-43ab-a2c1-f5937451fad2__notion-create-pages`.
- The matched branch body is a bare `;;`, meaning "fall through to the reminder".
  The `*)` branch exits. This mirrors `brainstorm-skill-worktree-first.sh`.
- The reminder points at the skill instead of restating its rules, so the two
  cannot drift apart.

- [ ] **Step 4: Make it executable**

```bash
chmod 755 plugins/soong/hooks/scripts/notion-content-reminder.sh
```

Verify it matches the three existing scripts:

```bash
ls -l plugins/soong/hooks/scripts/
```

Expected: all four scripts show `-rwxr-xr-x`.

- [ ] **Step 5: Run the check to verify it passes**

```bash
echo '{"tool_name":"mcp__abc__notion-create-pages"}' | bash plugins/soong/hooks/scripts/notion-content-reminder.sh
```

Expected, pretty-printed across six lines, because `jq` formats its output by
default:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Writing Notion content. Follow the soong write-notion-content skill for style and format. Invoke it now if it is not already loaded."
  }
}
```

The multi-line shape is correct and matches the three existing hooks, which also
pipe into a bare `jq`. Claude Code parses the JSON, so the whitespace does not
matter. There is no trailing `\n` inside the string, because `printf` emits none.

- [ ] **Step 6: Verify the other two prose tools fire**

```bash
for t in notion-update-page notion-create-comment; do echo "{\"tool_name\":\"mcp__abc__$t\"}" | bash plugins/soong/hooks/scripts/notion-content-reminder.sh; done
```

Expected: the same JSON object as step 5, printed twice, so twelve lines total.

- [ ] **Step 7: Verify excluded tools stay silent**

This is the important negative check. A read or a schema call must produce no
output and exit `0`.

```bash
for t in notion-fetch notion-search notion-get-users notion-create-database notion-update-data-source notion-duplicate-page notion-move-pages notion-create-view; do printf '%s: ' "$t"; echo "{\"tool_name\":\"mcp__abc__$t\"}" | bash plugins/soong/hooks/scripts/notion-content-reminder.sh; echo "exit=$?"; done
```

Expected: eight lines, each `<toolname>: exit=0`, with nothing between the colon
and `exit=0`.

If `notion-create-database` prints JSON, your `case` pattern is too broad. The
patterns must be `*notion-create-pages` and not `*notion-create*`.

- [ ] **Step 8: Verify a non-Notion tool stays silent**

```bash
echo '{"tool_name":"Bash"}' | bash plugins/soong/hooks/scripts/notion-content-reminder.sh; echo "exit=$?"
```

Expected: `exit=0`, no other output.

- [ ] **Step 9: Verify a malformed payload does not block**

A hook must not break the session when the payload is not what it expects.

```bash
echo 'not json' | bash plugins/soong/hooks/scripts/notion-content-reminder.sh; echo "exit=$?"
echo '{}' | bash plugins/soong/hooks/scripts/notion-content-reminder.sh; echo "exit=$?"
```

Expected: both report `exit=0`. The first also prints a `jq` parse error to
stderr, which is fine; stderr is not the hook's output channel, and any exit code
other than `2` is non-blocking.

- [ ] **Step 10: Commit**

```bash
git add plugins/soong/hooks/scripts/notion-content-reminder.sh
git commit -m "feat(hooks): add notion content style reminder script"
```

### Task 2: Register the hook

**Files:**
- Modify: `plugins/soong/hooks/hooks.json`
- Test: none. Verification is `jq empty` plus a read-back of the new entry.

- [ ] **Step 1: Confirm the current file is valid, so a later failure is yours**

```bash
jq empty plugins/soong/hooks/hooks.json && echo OK
```

Expected: `OK`.

- [ ] **Step 2: Add the third PreToolUse entry**

In `plugins/soong/hooks/hooks.json`, the `PreToolUse` array currently holds two
objects, one matching `Bash` and one matching `Skill`. Add a third object to the
end of that array, after the `Skill` entry's closing brace and its comma:

```json
      {
        "matcher": "mcp__.*__notion-(create-pages|update-page|create-comment)",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/notion-content-reminder.sh\"",
            "statusMessage": "Reminding to follow Notion content style"
          }
        ]
      }
```

Do not touch the `UserPromptSubmit` array. Do not reorder the existing two
entries.

Note on the matcher: it is a regex, unanchored, so it also matches any future
tool whose name merely contains one of the three strings, such as
`notion-update-page-icon`. That is accepted. The script's `case` patterns are
right-anchored and would reject that name, so the two layers compose to
something stricter than the matcher alone. Do not try to anchor or tighten the
matcher here; the script is the precise layer.

Note on `${CLAUDE_PLUGIN_ROOT}`: keep the escaped quotes exactly as written. The
variable is expanded by Claude Code, not by your shell, and the quotes protect
against a plugin path containing a space.

- [ ] **Step 3: Verify the JSON still parses**

```bash
jq empty plugins/soong/hooks/hooks.json && echo OK
```

Expected: `OK`. A trailing comma or a missing brace fails here.

- [ ] **Step 4: Verify the entry landed where you meant**

```bash
jq '.hooks.PreToolUse | length, (.[2].matcher), (.[2].hooks[0].statusMessage)' plugins/soong/hooks/hooks.json
```

Expected:

```
3
"mcp__.*__notion-(create-pages|update-page|create-comment)"
"Reminding to follow Notion content style"
```

- [ ] **Step 5: Verify every entry still has a statusMessage**

This guards the convention the three existing entries set.

```bash
jq '[.hooks | .. | objects | select(has("command")) | has("statusMessage")] | all' plugins/soong/hooks/hooks.json
```

Expected: `true`.

- [ ] **Step 6: Verify the matcher regex against the real tool names**

Check that the matcher hits the three prose tools and misses the rest. The
matcher is a regex, so use `grep -E`, not the shell globs from Task 1:

```bash
printf '%s\n' notion-create-pages notion-update-page notion-create-comment notion-create-database notion-update-data-source notion-duplicate-page notion-fetch notion-search notion-move-pages \
  | sed 's/^/mcp__386f596a__/' \
  | grep -E 'mcp__.*__notion-(create-pages|update-page|create-comment)'
```

Expected: exactly three lines, the `create-pages`, `update-page`, and
`create-comment` ones.

- [ ] **Step 7: Verify the command path the hook will actually run**

`${CLAUDE_PLUGIN_ROOT}` resolves to `plugins/soong` at runtime. Confirm the file
is there under that relative path:

```bash
test -x plugins/soong/hooks/scripts/notion-content-reminder.sh && echo "present and executable"
```

Expected: `present and executable`.

- [ ] **Step 8: Commit**

```bash
git add plugins/soong/hooks/hooks.json
git commit -m "feat(hooks): register notion content style reminder"
```

---

## Chunk 2: write-technical-content skill

### Task 3: The reference file

Build the reference file before `SKILL.md`, because `SKILL.md` points at it and
you want the target to exist.

**Files:**
- Create: `plugins/soong/skills/write-technical-content/reference/approved-words.md`
- Test: none. Verification is the greps in steps 3 and 4.

- [ ] **Step 1: Create the directory**

```bash
mkdir -p plugins/soong/skills/write-technical-content/reference
```

The directory is `reference/`, singular. No existing skill in this repository
bundles resources, so there is no in-repo convention to match, and the spec fixes
the name.

- [ ] **Step 2: Write the file**

Create
`plugins/soong/skills/write-technical-content/reference/approved-words.md` with
exactly this content. This is the whole file, not a sample; do not add rows.

````markdown
# Approved words

Use the approved column. This table is a guide to consistency in software
documentation, not the ASD-STE100 dictionary. The full approved word list holds
about 900 entries, and its publisher sets its own terms, so it stays out of
scope here.

A term belongs in the left column only if it carries no software meaning. Check
four senses: an identifier, a keyword, a protocol term, and a lifecycle state. A
term that carries one needs a sense-narrowing parenthetical, or it belongs in the
protected list at the end of this file.

The same test applies to the approved column. Never offer a replacement that the
reader could read as code. This is why `let` is absent from every approved cell,
and why `build`, `create`, and `support` appear there only as ordinary verbs.

| Not approved | Approved |
| --- | --- |
| utilize, make use of, leverage | use |
| commence, initiate (in the sense of begin), kick off | start |
| terminate (in the sense of end a task) | stop |
| prior to | before |
| subsequent to, following (as a time relation) | after |
| in order to | to |
| due to the fact that, owing to | because |
| in the event that | if |
| at this point in time | now |
| is able to, has the ability to | can |
| perform an update, do an update | update |
| provide support for | support |
| a number of, a variety of | some, many |
| facilitate | help |
| functionality | feature |
| methodology | approach, process |
| endeavour, attempt | try |
| ascertain, determine (in the sense of find out) | find |
| require (in the sense of necessitate), necessitate | need |
| modify, alter | change |
| implement (as a synonym for write) | add, build, write |
| execute (a command) | run |
| obtain, acquire | get |
| transmit | send |
| in the case of | for |
| with regard to, in terms of | for, about |
| a large number of | many |
| the majority of | most |
| approximately | about |
| additionally, furthermore | also |
| however | but |
| in conjunction with | with |
| by means of | with, by |
| in the vicinity of | near |
| subsequently | then |
| in advance of | before |
| spin up, stand up | start, create |
| reach out to | ask, contact |
| going forward | after this |

## How to read the table

A parenthetical narrows a row to one sense.

- `execute (a command)` becomes "run". `execute` in the sense of a program
  executing its own code stays.
- `implement (as a synonym for write)` becomes "add", "build", or "write".
  `implement` against an interface or a specification stays, as in "implement the
  `Reader` interface".
- `following (as a time relation)` becomes "after". `following` meaning the next
  thing shown stays, as in "see the following example".
- `terminate (in the sense of end a task)` becomes "stop". `terminate` as a
  lifecycle event stays, as in "the process terminated with exit code 1" or "the
  pod is terminating". A terminated thing has ended. A stopped thing can start
  again.
- `initiate (in the sense of begin)` becomes "start". `initiate` naming the
  initiating side of a two-party exchange stays, as in "the client initiates the
  TLS handshake".
- `determine (in the sense of find out)` becomes "find". `determine` meaning
  compute or decide stays, as in "the resolver determines the target host".
- `require (in the sense of necessitate)` becomes "need". `require` as a language
  construct stays, as in `require('fs')`, and the RFC 2119 sense stays, as in
  "this field is required".

If you replace "however" with "but", change the punctuation. Write "..., but
...", not "...; but, ...".

## Terms the table must not touch

Some words look like filler and are not. These words carry a precise meaning in
software. Rule 5 of the skill, one word and one meaning, protects these terms
rather than replacing them.

- `verify` and `validate` are separate. Validation asks whether input satisfies
  the rules. Verification asks whether an artifact matches its specification.
  Neither is "check".
- `deprecate` is a lifecycle state, not a removal. It means the feature still
  works and still ships, its use is discouraged, and removal comes later.
  If you write "remove", the reader learns the feature is already gone.
- `enable` is standard for flags and configuration. Keep "enable TLS". Do not
  write "let TLS". For the same reason, never reach for `let` as a plain-language
  replacement: it is also a binding keyword in JavaScript and Rust.
- `currently` marks a state that holds now and is expected to change, which is
  how a known limitation is written. Keep "the API currently returns only the
  first 100 rows". If you write "now returns", you announce a change instead, and
  the note reads as a regression.
- `function` and `method` name language constructs. Never introduce either as a
  plain-language replacement for something else, because the reader looks for
  code. This is why `functionality` maps to "feature" and `methodology` maps to
  "approach".
````

- [ ] **Step 3: Verify the table has the expected shape**

Count the substitution rows. Every row starts with `| ` and the count excludes
the header and the separator:

```bash
grep -c '^| ' plugins/soong/skills/write-technical-content/reference/approved-words.md
```

Expected: `41`. That is 39 substitution rows plus the header row plus the
separator row.

- [ ] **Step 4: Verify the protected terms are absent from the table**

This is the check that catches the class of error the spec review round found
three times. A protected term must never appear in the left column.

```bash
grep '^| ' plugins/soong/skills/write-technical-content/reference/approved-words.md | grep -nE '^\| *(verify|validate|deprecate|enable)\b' && echo "FAIL: protected term used as a row" || echo "OK: no protected term in the table"
```

Expected: `OK: no protected term in the table`.

- [ ] **Step 5: Verify the protected-terms section names each protected term**

The section covers six terms across four bullets, because two bullets each cover
a pair: `verify` with `validate`, and `function` with `method`. This check
samples one term per bullet.

```bash
for t in verify deprecate enable function; do printf '%s: ' "$t"; grep -c "\`$t\`" plugins/soong/skills/write-technical-content/reference/approved-words.md; done
```

Expected: each count is `1` or more.

- [ ] **Step 6: Commit**

```bash
git add plugins/soong/skills/write-technical-content/reference/approved-words.md
git commit -m "feat(write-technical-content): add approved words reference"
```

### Task 4: The skill

**Files:**
- Create: `plugins/soong/skills/write-technical-content/SKILL.md`
- Test: none. Verification is the frontmatter and rule checks in steps 3 to 5.

- [ ] **Step 1: Write the failing check**

The skill file does not exist yet, so its frontmatter cannot parse. Run:

```bash
head -5 plugins/soong/skills/write-technical-content/SKILL.md
```

- [ ] **Step 2: Run it to make sure it fails**

Expected:

```
head: plugins/soong/skills/write-technical-content/SKILL.md: No such file or directory
```

- [ ] **Step 3: Write the skill**

Create `plugins/soong/skills/write-technical-content/SKILL.md` with exactly this
content:

```markdown
---
name: write-technical-content
description: Applies ASD-STE100 Simplified Technical English to technical documentation. Use when writing or editing READMEs, API docs, runbooks, ADRs, migration guides, code comments, and error or log messages. Enforces one instruction per sentence, active voice, present tense, and consistent terminology. Does not cover commit messages, PR descriptions, or Notion content.
---

# write-technical-content

Rules for writing technical documentation, derived from ASD-STE100 Simplified
Technical English and adapted for software.

## Rules

1. One instruction per sentence.
2. Procedural sentence: 20 words maximum. Descriptive sentence: 25 words
   maximum.
3. Active voice. Imperative mood for instructions. Write "Run the migration",
   not "The migration should be run".
4. Present tense. Do not write "will".
5. One word, one meaning. Choose one term for each concept and repeat it. Never
   vary a term for style.
6. Keep articles and complete sentence structure. Simplified Technical English
   is not terse-speak.
7. No ambiguous pronouns. If more than one noun could be the referent, repeat
   the noun instead of writing "it" or "this".
8. A warning or a caution comes before the step it applies to, never after.
9. Six items maximum in one procedure step list. Split a longer list.
10. No gerund as a noun. Write "To configure the server, edit the file", not
    "Configuring the server is done by editing the file".
11. No slang, no idioms, no humour, no jargon used for flavour.
12. Procedural paragraph: six sentences maximum. Descriptive paragraph: ten
    sentences maximum.

## Word choice

Before you choose a verb or a noun that has a shorter equivalent, read
`reference/approved-words.md` and use the approved column.

## Scope

This skill covers documentation. Three kinds of text belong elsewhere:

* PR titles and descriptions: use `manage-pr`.
* Notion content: use `write-notion-content`.
* Commit messages: follow the Conventional Commits rule in the repository
  `CLAUDE.md`. No skill governs commit message style, and `manage-pr` does not:
  it owns the PR title, which borrows Conventional Commit syntax.

The Notion boundary matters because the two skills give opposite instructions.
`write-notion-content` cuts articles and filler. This skill keeps articles and
complete sentences. The destination decides: content going into Notion follows
`write-notion-content`, and this skill does not apply.

These rules govern the documentation this skill produces, and nothing more. The
skill claims no precedence over other active modes or skills.
```

- [ ] **Step 4: Verify the frontmatter parses**

```bash
head -5 plugins/soong/skills/write-technical-content/SKILL.md
```

Expected: a `---` line, then `name: write-technical-content`, then a
`description:` line, then `---`, then a blank line.

Check the delimiters are a matched pair at the top of the file:

```bash
grep -n '^---$' plugins/soong/skills/write-technical-content/SKILL.md | head -2
```

Expected: `1:---` and `4:---`. If the second number is not `4`, the description
wrapped onto a second line; put it back on one line, because the frontmatter
parser needs a single-line scalar here.

- [ ] **Step 5: Verify all 12 rules are present and the pointer is right**

```bash
grep -cE '^[0-9]+\. ' plugins/soong/skills/write-technical-content/SKILL.md
grep -c 'reference/approved-words.md' plugins/soong/skills/write-technical-content/SKILL.md
```

Expected: `12`, then `1`.

- [ ] **Step 6: Verify the pointer resolves**

The pointer is relative to the skill directory. Confirm the target is really
there:

```bash
test -f plugins/soong/skills/write-technical-content/reference/approved-words.md && echo "pointer resolves"
```

Expected: `pointer resolves`.

- [ ] **Step 7: Verify the skill does not contradict itself on articles**

Rule 6 keeps articles, and the sibling skill cuts them. Confirm the Scope
section names that tension, so a reader hitting both skills is not left guessing:

```bash
grep -c 'write-notion-content' plugins/soong/skills/write-technical-content/SKILL.md
```

Expected: `2` or more, one in the Scope list and one in the paragraph that
resolves the conflict.

- [ ] **Step 8: Commit**

```bash
git add plugins/soong/skills/write-technical-content/SKILL.md
git commit -m "feat(skills): add write-technical-content skill"
```

---

## Chunk 3: Version bump and final verification

### Task 5: Bump the plugin version

**Files:**
- Modify: `plugins/soong/.claude-plugin/plugin.json`

- [ ] **Step 1: Confirm the current version**

```bash
jq -r .version plugins/soong/.claude-plugin/plugin.json
```

Expected: `0.3.0`. If it is anything else, someone else has bumped it; bump the
minor component of whatever you find instead of hard-coding `0.4.0`.

- [ ] **Step 2: Bump it**

Edit `plugins/soong/.claude-plugin/plugin.json` and change the `version` value
from `0.3.0` to `0.4.0`. Change nothing else in the file.

This is a minor bump because both changes are features, per the versioning rule
in `CLAUDE.md`. One bump covers both.

- [ ] **Step 3: Verify**

```bash
jq -r .version plugins/soong/.claude-plugin/plugin.json
jq empty plugins/soong/.claude-plugin/plugin.json && echo OK
```

Expected: `0.4.0`, then `OK`.

- [ ] **Step 4: Commit**

```bash
git add plugins/soong/.claude-plugin/plugin.json
git commit -m "chore: bump plugin version to 0.4.0"
```

### Task 6: Whole-change verification

No new code here. This task proves the two features work together and the tree
is clean.

- [ ] **Step 1: Re-run the hook's positive and negative checks**

```bash
echo '{"tool_name":"mcp__abc__notion-update-page"}' | bash plugins/soong/hooks/scripts/notion-content-reminder.sh
echo '{"tool_name":"mcp__abc__notion-fetch"}' | bash plugins/soong/hooks/scripts/notion-content-reminder.sh; echo "exit=$?"
```

Expected: the reminder JSON object, then `exit=0` with nothing before it.

- [ ] **Step 2: Verify every JSON file in the plugin parses**

```bash
for f in plugins/soong/hooks/hooks.json plugins/soong/.claude-plugin/plugin.json .claude-plugin/marketplace.json; do printf '%s: ' "$f"; jq empty "$f" && echo OK; done
```

Expected: three `OK` lines.

- [ ] **Step 3: Verify the three new files exist**

The two modified files, `hooks.json` and `plugin.json`, are already covered by
step 2.

```bash
ls -l plugins/soong/hooks/scripts/notion-content-reminder.sh \
      plugins/soong/skills/write-technical-content/SKILL.md \
      plugins/soong/skills/write-technical-content/reference/approved-words.md
```

Expected: three lines. The script is `-rwxr-xr-x`; the two Markdown files do not
need the executable bit.

- [ ] **Step 4: Verify the working tree is clean and the history reads correctly**

```bash
git status --short
git log --oneline e21f360..HEAD
```

Expected: no output from `git status`. The log shows eleven commits on top of the
spec and plan commits. Five carry the task list, and six are corrections that
code review produced during execution:

```
chore: bump plugin version to 0.4.0
fix(write-technical-content): correct the commit message hand-off and rule 7
feat(skills): add write-technical-content skill
fix(write-technical-content): extend the admission criterion to the approved column
docs: sync spec and plan tables with the corrected reference file
fix(write-technical-content): protect software terms the table would break
feat(write-technical-content): add approved words reference
docs(plans): update task 6 history checks for the mid-execution docs commit
docs: correct how the two notion hook matching layers compose
feat(hooks): register notion content style reminder
feat(hooks): add notion content style reminder script
```

The `fix:` and `docs:` commits are not from this task list. Code review of tasks
2, 3, and 4 found defects in the content this plan specified: the spec
misdescribed how the two matching layers compose, five substitution rows would
have destroyed a precise software meaning, the admission criterion screened only
one column, and the scope section sent commit messages to a skill that does not
cover them. Each correction updated the affected file and both documents.

- [ ] **Step 5: Confirm nothing outside the planned files changed**

```bash
git diff --stat docs/superpowers/specs/2026-07-30-technical-content-skill-and-notion-reminder-hook-design.md
git diff --name-only 0f793ee HEAD
```

Expected: the first command prints nothing, because the spec has no uncommitted
changes. The second lists seven paths: the five implementation paths (the hook
script, `hooks.json`, the two skill files, and `plugin.json`) plus the spec and
plan files, which the mid-execution corrections touched. If you see an eighth,
find out what it is before you open a PR.

---

## Live verification, and what this plan does not prove

Everything above tests the script in isolation. It does not prove Claude Code
loads the hook, because that needs a plugin reinstall or a session restart, which
you cannot do from inside this session.

To check the live behaviour after merging, reinstall the plugin, start a new
session, and make a Notion page write. The reminder should appear as injected
context before the tool runs, and the status line should read "Reminding to
follow Notion content style".

Two known limits, both accepted in the spec:

* If `jq` is absent from `PATH`, the script fails and prints nothing. A
  `PreToolUse` hook that prints nothing does not block, so the Notion write still
  goes through. This is the right failure direction for an advisory hook.
* If the Notion MCP server is absent or its tools are renamed, the matcher never
  fires and nothing happens.

## Out of scope

Do not fix these as part of this plan, even though you will see them:

* `plugins/soong/hooks/scripts/pr-guard.sh:27` tells the reader to invoke the
  "write-pr" skill. That skill is named `manage-pr`. This is a real
  pre-existing bug and it belongs in its own change.
* `README.md` does not enumerate skills, so it needs no update here.
