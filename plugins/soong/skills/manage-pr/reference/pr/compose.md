# manage-pr: compose

Create or edit a pull request so its **title** and **description** follow the
conventions below.

The shared rules in `SKILL.md` apply here — no generated-by footer, no
attribution tag, never guess a Notion ticket id.

## Title

The title MUST be a single Conventional Commit line:

```
<type>(<scope>)!: <summary>
```

- **type** — one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
  `build`, `ci`, `chore`, `revert`.
- **scope** — optional, in parentheses, lowercase: `[a-z0-9./-]`. Use it only when it
  names a real area touched, e.g. `feat(hooks):`. When no meaningful area applies, omit
  the scope and parentheses entirely — write a plain `feat:`. Never use a placeholder or
  wildcard scope like `feat(*):` or `feat(misc):`.
- **`!`** — optional, marks a breaking change.
- **summary** — required, imperative, lowercase, no trailing period.

An optional **Notion ticket id** may be appended as a suffix. Resolve it via the
Notion MCP when the work maps to a ticket; otherwise omit it. Never invent one.

Examples:

- `feat(hooks): enforce PR conventions via plugin hook`
- `fix: handle empty commit range`
- `refactor(api)!: drop legacy auth header`

Avoid:

- `feat(*): add new command` — drop the placeholder scope, write `feat: add new command`.

## Description

Plain, simple prose. Describe what the PR does and why, in a few sentences or short
bullets. No section-header boilerplate unless the repo's PR template requires it.

## Arguments

- `--non-interactive` (alias `--skip-interactive`) — do not pause for confirmation.
  Draft the title and description from the diff and run the `gh` command directly.
  Resolve the Notion ticket only if it can be determined without asking the user
  (e.g. from an existing PR record or an unambiguous MCP match); otherwise omit it
  rather than prompting. Use this when another skill (e.g. `merge`) invokes
  `manage-pr` as an automated finishing step.

When no argument is given, behave interactively: surface the drafted title and
description and let the user adjust before running `gh`.

## Steps

1. Inspect the branch: `git log --oneline <base>..HEAD` and `git diff <base>...HEAD`
   so the title and description reflect **all** commits, not just the latest.
2. Draft a Conventional Commit title and a short prose description following the
   rules above. Add a Notion ticket suffix only if one genuinely applies. Unless
   `--non-interactive` was passed, show the draft to the user and let them adjust
   before continuing.
3. Run `gh pr create` (or `gh pr edit`) passing the title and body via a HEREDOC.
4. If the PR-guard hook denies the command, read its reason, fix the title or body,
   and retry — do not bypass the hook.
5. Write the PR record (see below) so `sync-pr-to-notion` can later find the linked
   card without the `gh` CLI.

## The hook is a backstop, not a substitute

The PR-guard hook's title check only fires when `--title` is parseable from the
command line. A title passed via HEREDOC, or a `gh pr edit` that changes only the
body, passes the hook unchecked. Write a correct title because it is the
convention, not because the hook will catch you.

## PR record

After the PR command succeeds, persist a small JSON record outside the repo, so it
is never committed and is queryable later with `jq`.

- **File:** `${XDG_STATE_HOME:-$HOME/.local/state}/soong/pr-records.json`
- **Shape:** keyed by project, then branch:

  ```json
  {
    "<project>": {
      "<branch>": {
        "notionCard": "<url-or-id-or-null>",
        "lastCommit": "<sha>",
        "updatedAt": "<iso-8601>"
      }
    }
  }
  ```

- **project** — the repo name. Derive it from the **common** git dir, never from
  `--show-toplevel`: inside a linked worktree `--show-toplevel` returns the worktree
  directory, which would key the record on the throwaway branch name instead of the repo.
- **branch** — current branch (`git rev-parse --abbrev-ref HEAD`).
- **notionCard** — the card resolved via the existing `manage-notion-page` flow; store
  `null` if none was resolved. Never invent one.
- **lastCommit** — `git rev-parse HEAD`.

Create the directory and merge into the file idempotently. Example:

```bash
dir="${XDG_STATE_HOME:-$HOME/.local/state}/soong"; file="$dir/pr-records.json"
mkdir -p "$dir"; [ -f "$file" ] || echo '{}' > "$file"
common="$(git rev-parse --path-format=absolute --git-common-dir)"  # main .git in worktrees too
top="${common%/.git}"; top="${top%/}"; project="${top##*/}"
branch="$(git rev-parse --abbrev-ref HEAD)"
sha="$(git rev-parse HEAD)"
card="${CARD:-null}"   # url/id resolved via manage-notion-page, or null
tmp="$(mktemp)"
jq --arg p "$project" --arg b "$branch" --arg c "$card" --arg s "$sha" \
   --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '.[$p][$b] = {notionCard: (if $c == "null" then null else $c end), lastCommit: $s, updatedAt: $t}' \
   "$file" > "$tmp" && mv "$tmp" "$file"
```

## Rules

- Never add a generated-by footer of any kind.
- Never guess a Notion ticket id; resolve it via the Notion MCP or omit it.
- The title is the contract the hook checks — make it valid before running `gh`.
- Always write the PR record after a successful PR command; store `null` for the card
  if none was resolved rather than guessing.
