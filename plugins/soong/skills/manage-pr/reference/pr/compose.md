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
  names a real area touched, e.g. `feat(hooks):`. When a change spans two or three
  areas, separate them with commas and no spaces: `refactor(notifications,types):`.
  Every segment must be non-empty. When no meaningful area applies, omit the scope and
  parentheses entirely — write a plain `feat:`. Never use a placeholder or wildcard
  scope like `feat(*):` or `feat(misc):`.
- **`!`** — optional, marks a breaking change.
- **summary** — required, imperative, lowercase, no trailing period.

An optional **Notion ticket id** may be appended as a suffix. Resolve it via the
Notion MCP when the work maps to a ticket; otherwise omit it. Never invent one.

Examples:

- `feat(hooks): enforce PR conventions via plugin hook`
- `fix: handle empty commit range`
- `refactor(api)!: drop legacy auth header`
- `refactor(notifications,types,schemas): always sync every property`

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
- `--base <branch>` — pass `--base <branch>` to `gh pr create`, and use `<branch>`
  as the base in step 1's `git log` and `git diff`. Absent, run `gh pr create` as
  it does today and let `gh` choose the default branch.
- `--notion-card <url-or-id>` — use this card in the PR record instead of
  resolving one. Absent, resolve as it does today. This does not license
  guessing: the caller supplies a card it already has, and the rule against
  inventing one is unchanged.
- `--draft` — pass `--draft` to `gh pr create`, opening the PR as a draft.
  Absent, open it ready for review, which is today's behavior.
- `--no-polish` — skip step 0. Use it when the branch's code is not what this
  pull request is about: the caller already reviewed it, the PR intentionally
  opens over unfinished code, or the caller is finishing an operation of its own.
  Absent, polish runs whenever `HEAD` does not carry its trailer.

  The PR-guard hook reads this flag off the raw command line to skip its own
  trailer check, so it must appear in the command you run. `gh` rejects it as an
  unknown flag, so append it as a trailing shell comment, which `gh` never sees:

  ```bash
  gh pr create --title "..." --body "..."  # --no-polish
  ```

  Never write that comment to quiet a hook denial. It records a decision the
  caller already made, and synthesising one turns the single documented escape
  hatch into a way around the check.

When no argument is given, behave interactively: surface the drafted title and
description and let the user adjust before running `gh`.

## Steps

0. **Polish the branch first.** Run the `polish` skill before anything else in
   this mode, unless it already ran on the current code.

   This applies when the branch's code is what is going under review: a
   `gh pr create`, or a `gh pr edit` that follows new commits. Skip it for an
   edit that only rewords an existing pull request's title or body. The user
   asked for wording, and rewriting code behind that ask is a change nobody
   requested.

   It applies to an already-open pull request too, when `HEAD` carries no
   trailer because polish never ran at create time. The trailer is a fact about
   the code, not about when the pull request was opened, so an open PR whose
   code was never reviewed is the same case as an unopened one. Polish it, push,
   and say in one line that the branch was polished and the PR carries an extra
   commit. Announce it, do not ask: the user asked for work on this pull
   request, and this step is part of that work.

   Check the marker `polish` writes, on `HEAD` alone:

   ```bash
   git log -1 --format='%(trailers:key=Polish-passes,valueonly)' HEAD
   ```

   Empty output means polish has not run on this commit. Anchor on `HEAD`, not
   a range: a range matches a branch that polished and then committed more work,
   which is the stale case this check exists to catch.

   When polish has not run, invoke it immediately. Pass `<base>` so polish does
   not re-derive one. Do not ask the user first,
   and do not ask for a Notion card first. Polish rewrites code, so a card
   resolved before it runs is resolved against code that is about to change.

   "Do not ask" is the authorization. Polish rewrites code and commits, and this
   step is where the user granted that — weighing it again at run time is
   re-litigating a settled decision, not caution. The plugin's PR-guard hook
   enforces it: a `gh pr create` or `gh pr edit` whose `HEAD` carries no trailer
   is denied, so asking for permission here does not lead to a working `gh` call
   anyway. When the hook denies with that reason, run polish. Do not ask, and do
   not reach for `--no-polish`.

   If polish stops on a failing check, stop here too. Report what polish
   reported and do not open the PR. A branch that fails its own check is not
   ready for review.

   Polish can add a commit. When it does, push the branch before step 3 runs
   `gh`, so the remote tip matches `HEAD`. A caller that pushed before invoking
   compose cannot do this itself, because it has no re-entry point between this
   step and step 3.

   Skip this step when `--no-polish` was passed or when `HEAD` already carries
   the trailer. Polish's own step 1 decides whether there is anything to review,
   so do not pre-empt that here.

   Refuse this step when the current branch is the repository default branch
   (`git symbolic-ref --short HEAD`): a pull request is not opened from the
   default branch, and polish refuses to switch branches under a caller.

   `<base>` here is `--base` when it was passed, otherwise the repository
   default branch - the same binding step 1 states, repeated because this step
   runs first.

1. Inspect the branch: `git log --oneline <base>..HEAD` and `git diff <base>...HEAD`
   so the title and description reflect **all** commits, not just the latest.
   `<base>` is `--base` when it was passed, otherwise the repo's default branch.
   Binding it matters as much as binding it in the `gh` call: for a stacked PR,
   the base is the previous branch in the stack, and that diff is this PR's own
   change. Left unbound, a stacked PR would be described from the whole stack's
   diff.
2. Draft a Conventional Commit title and a short prose description following the
   rules above. Add a Notion ticket suffix only if one genuinely applies. Unless
   `--non-interactive` was passed, show the draft to the user and let them adjust
   before continuing.
3. Run `gh pr create` (or `gh pr edit`) passing the title and body via a HEREDOC.
   Add `--base <branch>` and `--draft` when those arguments were passed.
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
- **notionCard** — `--notion-card` when it was passed, otherwise the card resolved
  via the existing `manage-notion-page` flow; store `null` if none was resolved.
  Never invent one.
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
