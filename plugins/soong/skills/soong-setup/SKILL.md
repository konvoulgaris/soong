---
name: soong-setup
description: Record what this repo needs for soong's skills to run - which Notion roadmap and task databases it maps to, and whether its commits carry a Conventional Commits scope. Use when the user runs /soong-setup, when another skill reports the repo is not configured, or when the user wants to change what a repo is configured for. Stops without writing anything if the user does not supply valid Notion databases.
---

# soong-setup

Configure this repo for soong's skills. Other skills ask this one's script whether
what they need is present, and send the user here when it is not.

Start by telling the user, in one line, what this does. For example:

> `soong-setup` records what this repo needs for soong's skills: the Notion
> databases `/architect` writes to, and whether commits here carry a scope.

## Arguments

```
/soong-setup [capability]
```

With no argument, sweep every capability and ask only for what is missing. With a
capability, configure that one alone.

## Config

- **File:** `${XDG_DATA_HOME:-$HOME/.local/share}/soong/soong.json`. This is user
  config, so it lives under `XDG_DATA_HOME`. The PR records that `manage-pr` writes
  are regenerable state and live under `XDG_STATE_HOME` instead.
- **Script:** `${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh`
- Keyed by the repo directory name, taken from the main checkout, so every linked
  worktree of one repo shares a single mapping.
- A config written before the rename, as `architect.json`, is copied forward
  automatically the first time any command runs. The old file stays on disk as a
  backup and is never written to.

## Capabilities

| Capability | Keys                                  | Used by                |
| ---------- | ------------------------------------- | ---------------------- |
| `notion`   | `roadmapDb`, `taskDb`, `taskTemplate` | `architect`, `develop` |
| `commits`  | `requireScope`                        | the `pr-guard` hook    |

`taskTemplate` is optional. Every other key is required by its capability.

## Steps

1. **See what is missing.**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" check [capability]
   ```

   Exit 0 means nothing is missing: show the user the current state, ask whether
   to change anything, and stop if not. Exit 3 lists what is missing: continue,
   and ask only for those. Exit 1 means the config is corrupt, and `set` will
   refuse to overwrite it: report the message and stop, because answering the
   questions below cannot succeed. Exit 2 means this is not a git repository, or
   the capability name is wrong: report it and stop.

2. **For `notion`, ask for the roadmap item database.** Ask for a Notion database
   URL or id.

3. **Ask for the task database.** Same. One Notion task in this database is one PR
   in a stack.

4. **Verify both databases with the Notion MCP** before writing anything. Fetch
   each one and confirm it resolves to a database the user can access. Show the
   user the resolved database titles so they can catch a wrong paste.

   If either database does not resolve, or the user cannot supply one, **stop
   here.** Write nothing. Say which database was invalid and that `/architect`
   stays unavailable for this repo until setup completes.

5. **Offer the task template.** List the templates available on the task database
   and let the user pick one, or skip. The template is optional; `architect` falls
   back to the database's own default when it is null.

6. **For `commits`, ask one question:** does this repo require a scope on commit
   and PR subjects?

   > Do commits and PR titles in this repo carry a scope, as in
   > `feat(scope): summary`? Answering yes denies subjects without a scope.
   > Answering no denies subjects with one.

   There is no third answer here. Leaving the question unanswered is what the repo
   already does, and the user reaches this step by choosing to answer it. Say what
   each answer turns on, because both directions deny something that is legal
   today.

7. **Write what was gathered.** Pass only the flags for the capabilities you asked
   about; the script merges, so it does not disturb the rest.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" set \
     [--roadmap-db "<id>"] [--task-db "<id>"] [--task-template "<id>"] \
     [--require-scope true|false]
   ```

8. **Confirm** the stored record back to the user, and name which skills just
   became available.

## Rules

- Never invent, guess, or infer a database or template id. Ask, then verify via MCP.
  The script stores whatever string it is given: it cannot tell a real database id
  from a typo, so MCP verification is the only check that exists.
- Ask one question at a time.
- Never answer the `commits` question on the user's behalf by reading the repo's
  git history. A repo whose commits are inconsistent is exactly the repo where the
  user's intent is the only signal that matters.
