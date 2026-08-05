---
name: architect-setup
description: Record which Notion roadmap database, task database, and task template this repo uses, so the architect skill knows where to write. Use when the user runs /architect-setup, when architect reports the repo is not configured, or when the user wants to change the Notion databases the architect writes to. Stops without writing anything if the user does not supply valid Notion databases.
---

# architect-setup

Map this repo to its Notion databases. `architect` reads this mapping; without it,
`architect` cannot run.

Start by telling the user, in one line, what this does. For example:

> `architect-setup` records which Notion roadmap and task databases this repo maps to,
> so `/architect` knows where to write specs and stacked PR tasks.

## Config

- **File:** `${XDG_DATA_HOME:-$HOME/.local/share}/soong/architect.json`. This is user
  config, so it lives under `XDG_DATA_HOME`. The PR records that `manage-pr` writes are
  regenerable state and live under `XDG_STATE_HOME` instead.
- **Script:** `${CLAUDE_PLUGIN_ROOT}/skills/architect-setup/scripts/architect-setup.sh`
- **Shape:** `{ "<project>": { roadmapDb, taskDb, taskTemplate, updatedAt } }`
- Keyed by the repo directory name, taken from the main checkout, so every linked
  worktree of one repo shares a single mapping.

## Steps

1. **Show the current mapping,** if any, and ask whether to replace it:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/architect-setup/scripts/architect-setup.sh" get
   ```

   Exit 3 means this repo has no mapping yet: continue. Exit 1 means the config is
   corrupt, and `set` will refuse to overwrite it: report the message and stop, because
   answering the questions below cannot succeed. Exit 2 means this is not a git
   repository: stop. Skip this step when `architect` already reported exit 3.

2. **Ask for the roadmap item database.** Ask for a Notion database URL or id.

3. **Ask for the task database.** Same. One Notion task in this database is one PR in a
   stack.

4. **Verify both databases with the Notion MCP** before writing anything. Fetch each one
   and confirm it resolves to a database the user can access. Show the user the resolved
   database titles so they can catch a wrong paste.

   If either database does not resolve, or the user cannot supply one, **stop here.**
   Write nothing. Say which database was invalid and that `/architect` stays unavailable
   for this repo until setup completes.

5. **Offer the task template.** List the templates available on the task database and let
   the user pick one, or skip. The template is optional; `architect` falls back to the
   database's own default when it is null.

6. **Write the mapping:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/architect-setup/scripts/architect-setup.sh" set \
     --roadmap-db "<id>" --task-db "<id>" [--task-template "<id>"]
   ```

7. **Confirm** the stored record back to the user and tell them `/architect` is ready.

## Rules

- Never invent, guess, or infer a database or template id. Ask, then verify via MCP.
  The script stores whatever string it is given: it cannot tell a real database id from
  a typo, so MCP verification is the only check that exists.
- Ask one question at a time.
