---
name: review-pr-queue
description: List every open pull request waiting on your review, across all repositories, ranked by impact, and say which can be reviewed immediately and which need undivided attention. Reads metadata only - never fetches a diff - so it is cheap enough to run every day. Prints a `/review-pr` command per row. Use when the user runs /review-pr-queue, or asks what reviews are waiting on them, what to review next, or to triage their review queue.
---

# review-pr-queue

Turn the pull requests awaiting your review into a ranked table that says which
one to open next.

This skill reads metadata and diffstats. It never fetches diff content, which is
what keeps it cheap enough to run habitually. The consequence: it knows what a
pull request touches, not what it means. Where the metadata does not support a
claim about intent, say what changed instead of inventing why.

## Step 1: Gather

Run the script one time:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/review-pr-queue/scripts/queue.sh"
```

Pass `--include-drafts` through when the user asked for drafts.

The script returns JSON with a `prs` array. Each row carries `url`, `title`,
`body`, `files`, `churn`, `score`, `classification`, `author`, `updatedAt`, and
`unreadable`. Rows are already sorted; do not re-sort them.

If the script exits non-zero, report its message in one line and stop.

If `prs` is empty, say the review queue is empty and stop. That is not an error,
and it needs no table.

## Step 2: Describe each pull request

One line per row, from `title`, `body`, and `files`. Say what the pull request
does rather than restating its title.

A title of `fix(auth): handle expiry` over a token refresh path and its tests
becomes a line about refresh behaviour, not the title again.

Where the metadata does not support a statement of intent, say what changed.
"Adds two files under `migrations/`" is a useful line. An invented purpose is
not.

A row with `unreadable: true` could not be read. Say so in its description
rather than guessing, and leave its classification blank.

## Step 3: Render the table

Columns: pull request, what it does, classification, and the review command.

- Link each pull request as `#<number>` pointing at its `url`.
- Print the `classification` verbatim: `Review now` or `Requires thinking`.
- The command column is `/review-pr <url>`, literally, for the user to copy.

Never print the `score`. It orders the rows and nothing else; showing it invites
more trust in a heuristic than it has earned.

Use the repository's palette from `DESIGN.md` where the terminal supports it:
gold for the header, `positron` for `Review now`, `caution` for
`Requires thinking`.

## Step 4: Stop

Do not invoke `review-pr`. Print its command and let the user choose.

Triage is cross-repository and cheap; `review-pr` is repository-local and
expensive, so chaining them would hit its adjacency stop most of the time.
