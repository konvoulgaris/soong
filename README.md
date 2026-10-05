# soong

This repository is a personal archive of software-engineering tooling. It
collects, organizes, and versions reusable tools, skills, and agents for use
across projects.

The name is a nod to Noonien Soong, the Star Trek: The Next Generation
scientist who created the android Data.

## Installation

This repo is a plugin marketplace for Claude Code and Codex.
Authenticate to the private repository with `gh` or Git.
Install Soong in Claude Code:

```
/plugin marketplace add konvoulgaris/soong
/plugin install soong@soong
```

## Requirements

soong assumes these are installed. Some skills call them directly and fail without
them:

- **superpowers** — `/develop` uses its planning and implementation skills.
- **Notion MCP** — every skill that reads or writes a Notion card.
- **soong-setup** — run `/soong-setup` once per repo. `/develop` needs the
  Notion databases it records, and the `conventional-commit-guard` hook reads
  the commit scope rule it records.
- **`gh` CLI** — the PR workflow skills call it directly. Authenticate with
  `gh auth login`.

## Principles

With session hooks enabled and trusted, soong loads standing engineering principles: DRY, minimalism, the Unix philosophy, the rule of least power,
RISC, worse is better, YAGNI, no chartjunk, the Arch and Slackware preference
for explicit machinery over magic, and respect for the idiom already in the
code.

They are defaults, not dogma. Your own instructions override them.

See `plugins/soong/skills/soong-setup/reference/principles.md` for the exact text.

## Recommended

Not required, but they pair well with soong:

- **[i-have-adhd](https://github.com/ayghri/i-have-adhd)** — stops a coding
  agent from burying the answer. ADHD-friendly output. The name is satirical
  (I hope), but the results are true 😛

## Codex

Soong also provides a Codex marketplace and plugin manifest. The skills are
shared with Claude Code.

Add this repository as a marketplace:

```sh
codex plugin marketplace add konvoulgaris/soong
```

For a local checkout, run this command from the repository root:

```sh
codex plugin marketplace add .
```

Open the Plugins Directory in the desktop app. Select the Soong marketplace and
install Soong. Authenticate to the private repository with `gh` or Git first.
Restart the app after changing a local plugin. The installer uses a cached copy;
regenerating repository files does not refresh an installed copy.

The Codex catalog follows the official [plugin and marketplace format](https://developers.openai.com/plugins/build/plugins).

## Keep agent configuration in sync

Install Bash 3.2 or later and jq 1.6 or later. Edit these authoritative files:

- `CLAUDE.md`: authoritative repository instructions.
- `plugins/soong/plugin.json`: plugin identity, version, and metadata.
- `plugins/soong/hooks/hooks.json`: Claude hook definitions.

Edit shared skills, agent procedures, scripts, and references in
`plugins/soong/`. These files are used directly by both hosts.

Regenerate host configuration:

```sh
bash scripts/sync-agent-configs.sh
```

Check for drift without writing files:

```sh
bash scripts/sync-agent-configs.sh --check
```

The script generates `AGENTS.md`, both marketplace catalogs, both host plugin
manifests, and `plugins/soong/hooks/hooks.codex.json`. Do not edit generated files.
Check mode returns 1 for drift or invalid sources and 2 for invalid arguments.
The script works from any directory. It writes only repository-owned outputs.
It does not change personal configuration, credentials, or installed caches.
Run check mode in CI to detect uncommitted generated changes.

## Host differences

Skills resolve scripts from their installed paths. The shared
`plugins/soong/skills/soong-setup/reference/hosts.md` defines agent dispatch,
branch prefixes, and worktree operations. Codex receives named agent procedures
as subagent instructions. Claude agent model and tool metadata do not configure
Codex agents. Read-only instructions require host tool restrictions for enforced
access control.

Both hosts read the same engineering principles. Codex's generated hook file
includes the Bash convention guard, the Notion content reminder, and SessionStart
principles. Codex users must review and trust hooks before execution, as described
in the official [hook documentation](https://learn.chatgpt.com/docs/hooks).

Codex excludes Claude's Skill matcher and brainstorming prompt reminder.
Soong workflows use the installed worktree skill for isolation instead.
Some tool paths bypass hooks. A successful configuration check does not prove
hook execution or identical agent behavior.

Run the full shell test suite:

```sh
while IFS= read -r file; do
  bash "$file" || exit 1
done < <(find scripts plugins -name '*.test.sh' -type f | sort)
```

Run shell syntax checks:

```sh
while IFS= read -r file; do
  bash -n "$file" || exit 1
done < <(find scripts plugins -name '*.sh' -type f | sort)
```
