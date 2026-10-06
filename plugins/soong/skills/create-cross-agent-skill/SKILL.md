---
name: create-cross-agent-skill
description: Create a skill once and make it available to every agent in the repo, Claude Code and Codex alike. Writes the skill into the repo's canonical skills directory and mirrors it to .claude/skills and .agents/skills. Use when the user runs /create-cross-agent-skill, asks to add a skill to this repo for all agents, or wants existing Claude or Codex skills in a repo moved to one shared location and kept in sync. Requires the repo to be configured via soong-setup first.
---

# create-cross-agent-skill

Read [host operations](../soong-setup/reference/hosts.md) before running this workflow.

Claude Code reads repo skills from `.claude/skills/<name>/`. Codex reads them from
`.agents/skills/<name>/`. Both use the same `SKILL.md` format. This skill keeps one
canonical copy in the repo's skills directory and mirrors it to both.

## Script

`"$SOONG_PLUGIN_ROOT/skills/create-cross-agent-skill/scripts/sync-skills.sh"`

```
sync-skills.sh [--check | --adopt] SKILLS_DIR
```

- No flag: copy every skill in `SKILLS_DIR` to both mirrors.
- `--check`: write nothing. Print `Drift: <path>` and exit 1 on any difference.
- `--adopt`: first move skills that exist only in a mirror into `SKILLS_DIR`.

The sync is one way. The mirrors are generated: never edit them. A skill in a
mirror and not in `SKILLS_DIR` is an error, not a deletion. Exit 1 also covers
invalid skill metadata and adopt conflicts. Exit 2 is a usage error.

## Steps

1. **Read where skills live.**

   ```bash
   bash "$SOONG_PLUGIN_ROOT/skills/soong-setup/scripts/soong-setup.sh" check skills
   ```

   Exit 3 means the repo has not answered that question. Tell the user to run
   `/soong-setup skills`, and stop. Otherwise read the directory:

   ```bash
   bash "$SOONG_PLUGIN_ROOT/skills/soong-setup/scripts/soong-setup.sh" get | jq -r .skillsDir
   ```

2. **Adopt existing skills.** Check whether `.claude/skills` or `.agents/skills`
   holds skills that `SKILLS_DIR` does not. If so, tell the user which, and ask
   before moving them. On yes, run `sync-skills.sh --adopt SKILLS_DIR`. A conflict
   means one name has different content in two places. Show the user the paths
   the script printed and let them choose. Never pick a winner.

3. **Write the new skill** to `SKILLS_DIR/<name>/SKILL.md`, if the user asked for
   one. Use the `write-a-skill` skill when it is installed. The frontmatter needs
   `name`, equal to the directory name, and `description`. Keep bundled files
   inside the skill directory, because the whole directory is mirrored.

4. **Sync.**

   ```bash
   bash "$SOONG_PLUGIN_ROOT/skills/create-cross-agent-skill/scripts/sync-skills.sh" "$skills_dir"
   ```

5. **Report** which skills were created, adopted, and updated, and show the
   `--check` command so the user can add it to CI.

## Rules

- Edit `SKILLS_DIR` only. Edits to a mirror are overwritten by the next sync.
- Never delete a mirrored skill to make the script pass. Ask the user whether to
  adopt or remove it.
- Never move skills without the user's yes. Adoption changes the working tree.
- Do not sync from `~/.claude/skills` or `~/.codex/skills`. This skill is
  repo-scoped.
