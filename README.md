# soong

This repository is a personal archive of software-engineering tooling. It
collects, organizes, and versions reusable tools, skills, and agents for use
across projects.

The name is a nod to Noonien Soong, the Star Trek: The Next Generation
scientist who created the android Data.

## Installation

This repo is a Claude Code plugin marketplace. To install (you must be
authenticated to the private repo via `gh`/git):

```
/plugin marketplace add konvoulgaris/soong
/plugin install soong@soong
```

## Requirements

soong assumes these are installed. Some skills call them directly and fail without
them:

- **superpowers** — `/architect` runs `superpowers:brainstorming` to turn a request
  into a spec.
- **Notion MCP** — every skill that reads or writes a Notion card.
- **soong-setup** — run `/soong-setup` once per repo. `/architect` and `/develop`
  need the Notion databases it records, and the `conventional-commit-guard` hook reads the commit
  scope rule it records.
