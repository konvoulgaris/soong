# worktree-cleanup

Find and remove stale git worktrees across your machine. Scans for git
repositories, inspects each worktree, and removes the ones that are safe to
delete — worktree, branch, and directory together.

Pure bash, no dependencies. Works on macOS (bash 3.2) and Linux.

## What counts as stale

A worktree is removed only when **all** hold:

- its branch has no counterpart on `origin` (no remote branch, no `origin/`
  ref), and
- it has no uncommitted changes, and
- neither its last git commit **nor** its last Claude Code session activity
  falls within the staleness window (default 30 days).

Worktrees with unstaged changes are always kept and listed at the end. A recent
Claude session protects a worktree just like a recent commit — an active
session counts as work in progress.

The main repository checkout is never touched.

## Usage

```bash
./worktree-cleanup.sh [root]              # interactive review UI
./worktree-cleanup.sh --auto [root]       # non-interactive, delete all stale
./worktree-cleanup.sh --auto --dry-run    # preview, delete nothing
./worktree-cleanup.sh --days 14           # change staleness window
```

`root` defaults to `$HOME`. Common system and cache directories (`Library`,
`node_modules`, cloud-sync folders, etc.) are skipped during the scan.

### Flags

| Flag         | Effect                                                      |
| ------------ | ---------------------------------------------------------- |
| `--auto`     | Skip the interactive UI; delete every stale worktree.      |
| `--dry-run`  | Report what would be deleted without deleting.             |
| `--days N`   | Set the staleness window in days (default 30).             |

`DRY_RUN=1` is equivalent to `--dry-run`. Flags may appear in any order.

## Modes

**Interactive (default).** A full-screen UI: a scan dashboard with a progress
bar, then a navigable list of candidate worktrees. Stale entries are
pre-selected.

- `↑`/`↓` or `j`/`k` — move
- `space` — toggle the current worktree
- `a` — select all
- `s` — select all stale
- `n` — select none
- `enter` — delete the selected worktrees
- `q` — cancel without deleting

**Auto (`--auto`).** Plain line-by-line output suitable for logs or cron.
Deletes the full stale set with no prompts:

```
Indexing /Users/you...
Indexed 17 repositories
Checking worktrees...
Found 6 candidates, 0 stale
Nothing to clean.
```

## States

| State    | Meaning                                    | Action           |
| -------- | ------------------------------------------ | ---------------- |
| `STALE`  | No remote, clean, past the window          | Removed          |
| `DIRTY`  | Has uncommitted changes                    | Kept, reported   |
| `RECENT` | Commit or session activity inside window   | Kept             |
| `REMOTE` | Branch exists on `origin`                  | Kept             |

## Theme

Terminal colors follow the repository [DESIGN.md](../../DESIGN.md) palette
(themed after Lt. Commander Data), with a basic-ANSI fallback for terminals
without 256-color support.
