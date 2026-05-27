---
name: write-pr
description: Use when writing or rewriting a pull request's title and description — creating a new PR or editing an existing one. Enforces the Conventional-Commits-with-scope title format, an optional Notion ticket id suffix, and a simple-prose description style — and explicitly forbids generated-by footers. Triggers on "open a PR", "create a pull request", "write the PR title/description", or any `gh pr create` / `gh pr edit`.
---

# write-pr

Create or edit a pull request so its **title** and **description** follow the
conventions below. The plugin's PR-guard hook blocks `gh pr create` / `gh pr edit`
that violate these rules, so getting them right here is what lets the command through.

## Title

The title MUST be a single Conventional Commit line:

```
<type>(<scope>)!: <summary>
```

- **type** — one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
  `build`, `ci`, `chore`, `revert`.
- **scope** — optional, in parentheses, lowercase: `[a-z0-9./-]`. Use it to name the
  area touched, e.g. `feat(hooks):`.
- **`!`** — optional, marks a breaking change.
- **summary** — required, imperative, lowercase, no trailing period.

An optional **Notion ticket id** may be appended as a suffix. Resolve it via the
Notion MCP when the work maps to a ticket; otherwise omit it. Never invent one.

Examples:

- `feat(hooks): enforce PR conventions via plugin hook`
- `fix: handle empty commit range`
- `refactor(api)!: drop legacy auth header`

## Description

Plain, simple prose. Describe what the PR does and why, in a few sentences or short
bullets. No section-header boilerplate unless the repo's PR template requires it.

## Forbidden

The title and body MUST NOT contain a generated-by footer. Specifically, no:

- `Generated with ...`
- `Co-Authored-By: ...`
- the 🤖 robot emoji

## Steps

1. Inspect the branch: `git log --oneline <base>..HEAD` and `git diff <base>...HEAD`
   so the title and description reflect **all** commits, not just the latest.
2. Draft a Conventional Commit title and a short prose description following the
   rules above. Add a Notion ticket suffix only if one genuinely applies.
3. Run `gh pr create` (or `gh pr edit`) passing the title and body via a HEREDOC.
4. If the PR-guard hook denies the command, read its reason, fix the title or body,
   and retry — do not bypass the hook.

## Rules

- Never add a generated-by footer of any kind.
- Never guess a Notion ticket id; resolve it via the Notion MCP or omit it.
- The title is the contract the hook checks — make it valid before running `gh`.
