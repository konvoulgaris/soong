# soong

This repository is a personal archive of software-engineering tooling. It
collects, organizes, and versions reusable tools, skills, and agents for use
across projects.

The name is a nod to Noonien Soong, the Star Trek: The Next Generation
scientist who created the android Data.

## Installation

This repo is a plugin marketplace for Claude Code.
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

soong loads standing engineering principles: DRY, minimalism, the Unix philosophy, the rule of least power,
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
- **[superpowers](https://github.com/obra/superpowers)** — brainstorming, planning,
  and debugging workflows. soong's guard keeps its specs and plans in
  `docs/superpowers/` out of your commits.

## Hooks

Brainstorming runs without review stops. When a brainstorming skill is invoked,
a hook tells the agent to ask its clarifying questions, then review the spec and
plan itself, and execute the plan without asking: with subagents when the plan
recommends them, inline otherwise.

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
