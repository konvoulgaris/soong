# Design: Notion content reminder hook + write-technical-content skill

Date: 2026-07-30
Branch: `claude/technical-content-skill-hook-5979cf`

## Summary

Two independent changes to the `soong` plugin:

1. A `PreToolUse` hook that fires on Notion MCP write tools and injects a
   reminder to follow the existing `write-notion-content` skill.
2. A new skill, `write-technical-content`, that applies ASD-STE100 (Simplified
   Technical English) rules to technical documentation. No hooks.

## Change 1: Notion content reminder hook

### Problem

The `write-notion-content` skill defines how Notion content should read, but
nothing prompts the agent to consult it before a Notion write. The skill gets
skipped, and content lands in Notion with the wrong style.

### Approach

Advisory reminder, not a hard gate.

A hard gate was considered and rejected. Hooks receive only the tool name and
tool input; they cannot see which skills are loaded. A real gate would need a
session state file written by a `Skill` hook and read by the Notion hook, which
is two scripts plus a state directory to maintain a check that only re-states
what the reminder already says. The reminder is one script, holds no state, and
cannot deadlock.

### Implementation

New file: `plugins/soong/hooks/scripts/notion-content-reminder.sh`

Behaviour, following the structure of `brainstorm-skill-worktree-first.sh`:

1. Read the whole payload once into a variable: `input=$(cat)`. Do not pipe
   stdin into `jq` twice; stdin is consumed on the first read.
2. Extract the tool name:
   `tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')`.
3. Re-check the name with a `case` block, and exit 0 on no match:

   ```bash
   case "$tool" in
     *notion-create-pages|*notion-update-page|*notion-create-comment) ;;
     *) exit 0 ;;
   esac
   ```

4. Otherwise print a `hookSpecificOutput` object with
   `hookEventName: "PreToolUse"` and an `additionalContext` string, built with
   `jq -Rs`, matching the pattern already used by
   `brainstorm-skill-worktree-first.sh`.

File mode is 755, as with the three existing scripts.

Reminder text (one line, points at the skill rather than restating its rules so
the two cannot drift):

> Writing Notion content. Follow the soong write-notion-content skill for style
> and format. Invoke it now if it is not already loaded.

Registration in `plugins/soong/hooks/hooks.json`, as a third entry under
`PreToolUse`, with `statusMessage: "Reminding to follow Notion content style"`
to match the convention set by the three existing entries.

MCP tool names carry an install-specific server id prefix, for example
`mcp__386f596a-2fe4-43ab-a2c1-f5937451fad2__notion-create-pages`. The matcher
must therefore be a regex over the name suffix, not a literal:

```
mcp__.*__notion-(create-pages|update-page|create-comment)
```

Matchers are unanchored, so this also matches any future tool whose name merely
contains one of these strings. The `case` re-check in the script is likewise
suffix-based, so it does not add precision. Both are deliberately loose: a false
positive costs one line of injected context, which is harmless.

Scope is the three tools that write prose a reader sees:

- `notion-create-pages` writes page bodies.
- `notion-update-page` replaces or appends page content.
- `notion-create-comment` writes comment text.

Everything else is excluded, on the rule that the hook fires only where the
agent authors prose:

- Read-only calls: `notion-fetch`, `notion-search`, `notion-query-*`,
  `notion-get-*`.
- Schema calls, which define properties rather than prose:
  `notion-create-database`, `notion-update-data-source`.
- Structural and copy calls, which write no new prose: `notion-move-pages`,
  `notion-create-view`, `notion-update-view`, `notion-create-attachment`,
  `notion-duplicate-page`.

### Failure modes

- No `jq` on PATH: the script fails, the hook produces no output. A `PreToolUse`
  hook that emits nothing does not block the tool call, so the Notion write
  still proceeds. Acceptable for an advisory hook.
- Notion MCP server absent or renamed: the matcher never fires, nothing happens.

## Change 2: `write-technical-content` skill

### Layout

```
plugins/soong/skills/write-technical-content/
  SKILL.md
  reference/approved-words.md
```

### Frontmatter

`name: write-technical-content`

Description triggers on technical documentation: READMEs, API docs, runbooks,
ADRs, migration guides, code comments, error and log messages.

Explicit non-scope, stated in the description and again in the body:

- Commit messages and PR titles or descriptions belong to `manage-pr`.
- Notion content belongs to `write-notion-content`.

### SKILL.md rules

ASD-STE100 rules, adapted for software documentation:

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
7. No ambiguous pronouns. Repeat the noun instead of writing "it" or "this".
8. A warning or a caution comes before the step it applies to, never after.
9. Six items maximum in one procedure step list. Split a longer list.
10. No gerund as a noun. Write "To configure the server, edit the file", not
    "Configuring the server is done by editing the file".
11. No slang, no idioms, no humour, no jargon used for flavour.
12. Procedural paragraph: six sentences maximum. Descriptive paragraph: ten
    sentences maximum. This keeps the procedural and descriptive split that
    ASD-STE100 draws, and that rule 2 already follows for sentence length.

### Pointer to the reference file

The SKILL.md body ends with one line telling the agent when to open the bundled
table:

> Before you choose a verb or a noun that has a shorter equivalent, read
> `reference/approved-words.md` and use the approved column.

Without this line the bundled file is never read. The directory is named
`reference/` for this skill; no existing skill in this repository bundles
resources, so there is no in-repo convention to match.

### Scope boundaries section

Two boundaries, stated in the body as well as the description:

- Commit messages and PR titles or descriptions: `manage-pr` owns those.
- Notion content: `write-notion-content` owns that.

The Notion boundary matters because the two skills give opposite instructions.
`write-notion-content` rule 3 cuts articles and filler; this skill keeps
articles and complete sentences. Both can plausibly be loaded at once, for
example when writing a runbook that lives on a Notion page. The rule for that
case: the destination decides. Content going into Notion follows
`write-notion-content`, and this skill does not apply.

The skill states its own rules for the documentation it produces. It makes no
claim of precedence over other active modes or skills.

### reference/approved-words.md

A two-column table, "Not approved" to "Approved", weighted toward wording that
appears in software documentation. The table below is the full content of the
file, not a sample:

| Not approved | Approved |
| --- | --- |
| utilize, make use of, leverage | use |
| commence, initiate, kick off | start |
| terminate | stop |
| prior to | before |
| subsequent to, following (as a time relation) | after |
| in order to | to |
| due to the fact that, owing to | because |
| in the event that | if |
| at this point in time, currently | now |
| is able to, has the ability to | can |
| perform an update, do an update | update |
| provide support for | support |
| a number of, a variety of | some, many |
| facilitate | help, let |
| functionality | feature |
| methodology | approach, process |
| endeavour, attempt | try |
| ascertain, determine | find |
| require, necessitate | need |
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

Two notes on how to read the table:

- A parenthetical narrows a row to one sense. `execute (a command)` becomes
  "run"; `execute` in the sense of a program executing its own code stays.
  `implement (as a synonym for write)` becomes "add", "build", or "write";
  `implement` against an interface or a specification stays, as in "implement the
  `Reader` interface". `following (as a time relation)` becomes "after";
  `following` meaning the next thing shown stays, as in "see the following
  example".
- Replacing "however" with "but" changes the punctuation. Write "..., but ...",
  not "...; but,  ...".

### Terms the table must not touch

Some words look like filler and are not. They carry a precise meaning in
software, and rule 5 (one word, one meaning) protects them rather than replacing
them. The reference file names them so no reader collapses them:

- `verify` and `validate` are separate. Validation asks whether input satisfies
  the rules. Verification asks whether an artifact matches its specification.
  Neither is "check".
- `deprecate` is a lifecycle state, not a removal. It means the feature still
  works and still ships, its use is discouraged, and removal comes later.
  Writing "remove" tells the reader the feature is already gone.
- `enable` is standard for flags and configuration. Keep "enable TLS". Do not
  write "let TLS".
- `function` and `method` name language constructs. Never introduce either as a
  plain-language replacement for something else, because the reader will look
  for code. This is why `functionality` maps to "feature" and `methodology` maps
  to "approach".

The table is a guide to consistency, not the ASD-STE100 dictionary. The full
approved word list is out of scope: it holds roughly 900 entries and is
published under its own terms.

## Versioning

`plugins/soong/.claude-plugin/plugin.json`: bump `version` from `0.3.0` to
`0.4.0`. Two features, so a minor bump, per CLAUDE.md.

## Testing

No test framework exists in this repository. Verification is manual:

1. Pipe a crafted payload into `notion-content-reminder.sh` with a Notion write
   tool name, and confirm the JSON reminder on stdout:

   ```bash
   echo '{"tool_name":"mcp__abc__notion-create-pages"}' | bash plugins/soong/hooks/scripts/notion-content-reminder.sh
   ```

2. Pipe a payload with a read-only Notion tool name, and confirm empty output
   and exit code 0:

   ```bash
   echo '{"tool_name":"mcp__abc__notion-fetch"}' | bash plugins/soong/hooks/scripts/notion-content-reminder.sh; echo "exit=$?"
   ```

3. Confirm `hooks.json` stays valid JSON:

   ```bash
   jq empty plugins/soong/hooks/hooks.json
   ```

4. Confirm the new `SKILL.md` frontmatter parses, by reading the first lines and
   checking that the `---` block holds a `name` and a `description` key:

   ```bash
   head -5 plugins/soong/skills/write-technical-content/SKILL.md
   ```

   The plugin must be reinstalled or the session restarted before the skill
   appears in the skill list, so listing is not part of this check.
