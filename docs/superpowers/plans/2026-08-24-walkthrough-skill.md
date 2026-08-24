# Walkthrough Skill Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `walkthrough` skill to the `soong` plugin that explains a branch's implementation to the user one change at a time.

**Architecture:** One bash script gathers the pull request and diff metadata and emits JSON. One `SKILL.md` holds the process and the step format inline. The script is the only testable unit; the skill body is prose and gets a verification checklist instead of tests.

**Tech Stack:** bash, `git`, `gh`, `jq`. No new dependencies: `jq` and `gh` are already used by the `sync-pr-to-notion` and `manage-pr` skills in this plugin.

**Spec:** `docs/superpowers/specs/2026-08-24-walkthrough-skill-design.md`

---

## Orientation for the implementer

You are working in the `soong` repository, a personal archive of Claude Code
skills. Read these before you start:

* `CLAUDE.md` at the repository root. Two rules bind this work: Conventional
  Commits, and a version bump in `plugins/soong/.claude-plugin/plugin.json`
  for every change.
* `plugins/soong/skills/sync-pr-to-notion/SKILL.md`. This is the closest
  existing skill: single file, read only, resolves a branch and a base.
* `plugins/soong/skills/architect-setup/scripts/architect-setup.test.sh`. This
  is the test convention you must match. Plain bash, a `check` helper, temp
  directories, `skip` when a precondition fails.
* `plugins/soong/skills/write-technical-content/SKILL.md`. The step prose in
  the skill body must obey these rules, and so must the skill body itself.

### What a "skill" is here

A skill is a markdown file with YAML frontmatter, under
`plugins/soong/skills/<name>/SKILL.md`. The frontmatter `name` and
`description` decide when the model loads the skill. The body is instructions
addressed to the model, not to a user. There is no build step and no
registration: the file's presence in the directory is what installs it.

### Testing philosophy for this plan

The script gets real tests, written before the implementation. The tests build
throwaway git repositories with `mktemp -d`, so they never depend on the
checkout they run from and never touch the network.

The `SKILL.md` files do not get unit tests. Prose has no assertions worth
writing, and a test framework for markdown would be ceremony. They get a
verification checklist in Task 5 instead.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `plugins/soong/skills/walkthrough/SKILL.md` | Process and step format. Read by the model. |
| `plugins/soong/skills/walkthrough/scripts/gather-context.sh` | Collect branch, base, pull request, commits, and file churn. Emit JSON. |
| `plugins/soong/skills/walkthrough/scripts/gather-context.test.sh` | Self-check for the script. |
| `plugins/soong/.claude-plugin/plugin.json` | Version bump, `0.6.1` to `0.7.0`. |

Four tasks build these, then a fifth verifies the whole.

---

## Chunk 1: The gathering script

### Task 1: Script skeleton and failure cases

The script's failure behaviour is the part most likely to be wrong, so it is
built first. A walkthrough that dies with a raw `git` error inside a
non-repository is worse than one that says what happened.

**Files:**
- Create: `plugins/soong/skills/walkthrough/scripts/gather-context.test.sh`
- Create: `plugins/soong/skills/walkthrough/scripts/gather-context.sh`

- [ ] **Step 1: Write the failing test**

Create `plugins/soong/skills/walkthrough/scripts/gather-context.test.sh`:

```bash
#!/usr/bin/env bash
# Self-check for gather-context.sh. Run: bash gather-context.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/gather-context.sh"
tmp="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# gh must never run during the tests: the walkthrough must not depend on the
# network or on a logged-in account. A stub on PATH that always fails puts the
# script on its no-pull-request path.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}

# Build a repo with a main branch and a feature branch holding one commit.
# Every test below runs against a repo made here, never against the checkout.
make_repo() { # make_repo <dir>
  local d="$1"
  git init -q -b main "$d"
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  echo one > "$d/a.txt"
  git -C "$d" add a.txt
  git -C "$d" commit -q -m "chore: initial"
}

# --- failure cases -----------------------------------------------------------

# Outside a git repository the script must exit non-zero, not print JSON.
out="$(cd "$tmp" && bash "$script" 2>/dev/null)"
code="$(cd "$tmp" && bash "$script" >/dev/null 2>&1; echo $?)"
check "outside a repo exits non-zero" "yes" "$([ "$code" -ne 0 ] && echo yes || echo no)"
check "outside a repo prints no stdout" "" "$out"
check "outside a repo explains itself" "yes" \
  "$(cd "$tmp" && bash "$script" 2>&1 >/dev/null | grep -qi 'git repository' && echo yes || echo no)"

# On the base branch itself there are no commits to walk.
repo="$tmp/nocommits"
make_repo "$repo"
code="$(cd "$repo" && bash "$script" >/dev/null 2>&1; echo $?)"
check "no commits against base exits non-zero" "yes" \
  "$([ "$code" -ne 0 ] && echo yes || echo no)"
check "no commits against base explains itself" "yes" \
  "$(cd "$repo" && bash "$script" 2>&1 >/dev/null | grep -qi 'no commits' && echo yes || echo no)"

echo
[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash plugins/soong/skills/walkthrough/scripts/gather-context.test.sh
```

Expected: the run fails because `gather-context.sh` does not exist. Every
`check` that expects an explanation reports `FAIL`, and the script exits 1.

- [ ] **Step 3: Write the minimal implementation**

Create `plugins/soong/skills/walkthrough/scripts/gather-context.sh`:

```bash
#!/usr/bin/env bash
# Collect the facts a walkthrough needs about the current branch, as JSON.
# Emits: branch, base, pr (or null), commits, files.
set -uo pipefail

die() { echo "$1" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 \
  || die "not inside a git repository"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$branch" ] && [ "$branch" != HEAD ] \
  || die "cannot resolve the current branch"

# Base: the pull request base when there is a pull request, else main/master.
base="$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null)"
if [ -z "$base" ]; then
  for candidate in main master; do
    if git rev-parse --verify -q "$candidate" >/dev/null 2>&1; then
      base="$candidate"; break
    fi
  done
fi
[ -n "$base" ] || die "cannot resolve a base branch (looked for main, master)"
[ "$base" != "$branch" ] || die "no commits to walk: on the base branch $base"

git rev-parse --verify -q "$base" >/dev/null 2>&1 \
  || die "base branch $base does not exist locally"

count="$(git rev-list --count "$base..HEAD" 2>/dev/null)"
[ "${count:-0}" -gt 0 ] || die "no commits on $branch against $base"

printf '{"branch":%s,"base":%s}\n' \
  "$(printf '%s' "$branch" | jq -Rs .)" \
  "$(printf '%s' "$base" | jq -Rs .)"
```

Make it executable:

```bash
chmod +x plugins/soong/skills/walkthrough/scripts/gather-context.sh
```

Note the `git rev-parse --git-dir` guard rather than `--show-toplevel`: inside
a linked worktree `--show-toplevel` returns the worktree directory. The spec
records this. The script never needs the repository root, so the cheap
existence check is the right one.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash plugins/soong/skills/walkthrough/scripts/gather-context.test.sh
```

Expected: `all checks passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/walkthrough/scripts/
git commit -m "feat(walkthrough): add context gathering script skeleton"
```

---

### Task 2: Commits, files, and JSON validity

Now the script returns real content. The one hazard is quoting: a commit
subject containing a double quote must not break the JSON. Every string goes
through `jq -Rs`, and a test proves it.

**Files:**
- Modify: `plugins/soong/skills/walkthrough/scripts/gather-context.test.sh`
- Modify: `plugins/soong/skills/walkthrough/scripts/gather-context.sh`

- [ ] **Step 1: Write the failing test**

In `gather-context.test.sh`, insert this block immediately before the final
`echo` and the exit lines:

```bash
# --- happy path --------------------------------------------------------------

# A feature branch with two commits, one of which has a quote and a backslash
# in its subject. Nothing here may break the JSON.
repo="$tmp/feature"
make_repo "$repo"
git -C "$repo" checkout -q -b feature
echo two > "$repo/b.txt"
git -C "$repo" add b.txt
git -C "$repo" commit -q -m 'feat: add "quoted" \ thing'
printf 'three\nfour\n' >> "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -q -m "fix: extend a"

json="$(cd "$repo" && bash "$script" 2>/dev/null)"
check "happy path exits 0" 0 "$(cd "$repo" && bash "$script" >/dev/null 2>&1; echo $?)"
check "output is valid JSON" 0 "$(printf '%s' "$json" | jq -e . >/dev/null 2>&1; echo $?)"
check "branch is reported" "feature" "$(printf '%s' "$json" | jq -r .branch)"
check "base is reported" "main" "$(printf '%s' "$json" | jq -r .base)"
check "commit count" 2 "$(printf '%s' "$json" | jq '.commits | length')"
check "quoted subject survives" "yes" \
  "$(printf '%s' "$json" | jq -r '.commits[]' | grep -qF 'add "quoted" \ thing' && echo yes || echo no)"
check "file count" 2 "$(printf '%s' "$json" | jq '.files | length')"
check "churn is recorded" 2 \
  "$(printf '%s' "$json" | jq '[.files[] | select(.path == "a.txt")] | .[0].added')"
check "no pull request is null, not absent" "null" \
  "$(printf '%s' "$json" | jq -r '.pr | if . == null then "null" else "object" end')"

# A binary file reports churn as 0 rather than git's "-", which is not a number.
repo="$tmp/binary"
make_repo "$repo"
git -C "$repo" checkout -q -b feature
printf '\x00\x01\x02\x03' > "$repo/blob.bin"
git -C "$repo" add blob.bin
git -C "$repo" commit -q -m "chore: add a binary"
json="$(cd "$repo" && bash "$script" 2>/dev/null)"
check "binary file yields valid JSON" 0 "$(printf '%s' "$json" | jq -e . >/dev/null 2>&1; echo $?)"
check "binary churn is numeric" "number" \
  "$(printf '%s' "$json" | jq -r '.files[0].added | type')"

# A path with a space must arrive intact.
repo="$tmp/spaces"
make_repo "$repo"
git -C "$repo" checkout -q -b feature
mkdir -p "$repo/some dir"
echo x > "$repo/some dir/file name.txt"
git -C "$repo" add .
git -C "$repo" commit -q -m "chore: spaced path"
json="$(cd "$repo" && bash "$script" 2>/dev/null)"
check "spaced path survives" "yes" \
  "$(printf '%s' "$json" | jq -r '.files[].path' | grep -qF 'some dir/file name.txt' && echo yes || echo no)"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash plugins/soong/skills/walkthrough/scripts/gather-context.test.sh
```

Expected: the failure cases still pass. The new checks fail, because the
script emits only `branch` and `base`. `jq -r .commits` returns nothing and
`jq '.commits | length'` errors.

- [ ] **Step 3: Write the minimal implementation**

Replace the final `printf` in `gather-context.sh` with the following:

```bash
# Commit subjects, newest first. jq -Rs splits on newlines and quotes each one.
commits="$(git log --format='%h %s' "$base..HEAD" 2>/dev/null \
  | jq -Rs 'split("\n") | map(select(length > 0))')"

# Churn per file. git prints "-" for binary files, so map that to 0 and keep
# the field a number: the skill ranks on these values.
files="$(git diff --numstat "$base...HEAD" 2>/dev/null | jq -Rs '
  split("\n")
  | map(select(length > 0))
  | map(split("\t"))
  | map(select(length >= 3))
  | map({
      path: (.[2:] | join("\t")),
      added: (if .[0] == "-" then 0 else (.[0] | tonumber) end),
      removed: (if .[1] == "-" then 0 else (.[1] | tonumber) end)
    })')"

pr="$(gh pr view --json number,title,body 2>/dev/null)"
[ -n "$pr" ] || pr=null

jq -n \
  --arg branch "$branch" \
  --arg base "$base" \
  --argjson pr "$pr" \
  --argjson commits "$commits" \
  --argjson files "$files" \
  '{branch: $branch, base: $base, pr: $pr, commits: $commits, files: $files}'
```

Two details that matter. `.[2:] | join("\t")` rebuilds the path rather than
taking `.[2]`, because a path may itself contain a tab. `--argjson pr` accepts
the literal `null`, which is why the fallback is the bare word and not an
empty string.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash plugins/soong/skills/walkthrough/scripts/gather-context.test.sh
```

Expected: `all checks passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/walkthrough/scripts/
git commit -m "feat(walkthrough): emit commits, file churn, and PR in gathered JSON"
```

---

### Task 3: Worktree and detached HEAD

This repository is used with linked worktrees, and this plan is being executed
inside one. A script that resolves the branch wrongly in a worktree fails
exactly where it will be used.

**Files:**
- Modify: `plugins/soong/skills/walkthrough/scripts/gather-context.test.sh`
- Modify: `plugins/soong/skills/walkthrough/scripts/gather-context.sh` (only if the tests fail)

- [ ] **Step 1: Write the failing test**

Insert before the final `echo` in `gather-context.test.sh`:

```bash
# --- worktrees ---------------------------------------------------------------

# The plugin is developed inside linked worktrees, so the script must resolve
# branch and base from within one.
repo="$tmp/wt-main"
make_repo "$repo"
if git -C "$repo" worktree add -q -b wt-feature "$tmp/wt-linked" >/dev/null 2>&1; then
  echo change > "$tmp/wt-linked/c.txt"
  git -C "$tmp/wt-linked" add c.txt
  git -C "$tmp/wt-linked" commit -q -m "feat: from a worktree"
  json="$(cd "$tmp/wt-linked" && bash "$script" 2>/dev/null)"
  check "worktree exits 0" 0 "$(cd "$tmp/wt-linked" && bash "$script" >/dev/null 2>&1; echo $?)"
  check "worktree branch resolves" "wt-feature" "$(printf '%s' "$json" | jq -r .branch)"
  check "worktree base resolves" "main" "$(printf '%s' "$json" | jq -r .base)"
  check "worktree sees its commit" 1 "$(printf '%s' "$json" | jq '.commits | length')"
else
  echo "skip - worktree checks (git worktree add failed)"
fi

# Detached HEAD has no branch name to report, so the script must refuse rather
# than emit an empty or bogus branch.
repo="$tmp/detached"
make_repo "$repo"
git -C "$repo" checkout -q --detach HEAD
code="$(cd "$repo" && bash "$script" >/dev/null 2>&1; echo $?)"
check "detached HEAD exits non-zero" "yes" "$([ "$code" -ne 0 ] && echo yes || echo no)"
check "detached HEAD prints no stdout" "" "$(cd "$repo" && bash "$script" 2>/dev/null)"
```

- [ ] **Step 2: Run the test**

```bash
bash plugins/soong/skills/walkthrough/scripts/gather-context.test.sh
```

Expected: these checks pass already. The Task 1 implementation guards
detached HEAD with `[ "$branch" != HEAD ]`, and `git rev-parse` works normally
in a linked worktree.

This is deliberate. The tests exist to prove the property holds and to catch a
later regression, not because the code is missing. If any check fails, fix
`gather-context.sh` and re-run until all pass. Do not weaken a test to make it
pass.

- [ ] **Step 3: Commit**

```bash
git add plugins/soong/skills/walkthrough/scripts/gather-context.test.sh
git commit -m "test(walkthrough): cover worktree and detached HEAD resolution"
```

---

## Chunk 2: The skill and release

### Task 4: Write SKILL.md

The script is done. This task writes the instructions the model follows.

Write the body in Simplified Technical English, per
`plugins/soong/skills/write-technical-content/SKILL.md`: active voice, present
tense, one instruction per sentence, one term for one concept, no em-dashes.
The skill instructs the model to produce STE prose, so the skill itself must
read that way.

**Files:**
- Create: `plugins/soong/skills/walkthrough/SKILL.md`

- [ ] **Step 1: Write the frontmatter and the opening**

```markdown
---
name: walkthrough
description: Walk the user through an implementation one change at a time, explaining what changed and why. Reads the PR description and the branch diff, caps the walkthrough at the most significant changes, and presents each as problem, change, consequence. Accepts an optional scope argument to limit the walkthrough to one area. Triggers on /walkthrough, "walk me through this", "explain what we built", "what did we change and why".
---

# walkthrough

Explain the current branch to the user, one change at a time. This skill
explains work. It never does work.

The user runs this skill because the user does not know what the branch
changed. A pull request description is a wall of text that the user skims. A
diff is too long to read. This skill gives the user one change at a time, and
a place to stop and ask.
```

- [ ] **Step 2: Write the guard rails section**

Guard rails come before the procedure, because a warning belongs before the
step it governs.

```markdown
## What this skill never does

- **Never edit code.** This skill runs read commands only. If the walkthrough
  finds a bug, state the bug in one line and continue. A fix is a separate
  request from the user.
- **Never invent a reason.** Every step traces to a pull request bullet, a
  diff hunk, or a commit subject. When the reason for a change is not
  recoverable from these sources, say that the reason is not recorded. A guess
  that reads as a fact is worse than an admitted gap, because the user cannot
  tell the two apart.
- **Never dump.** No full diffs. No file contents. No wall of text. The word
  budget is the feature.
- **Never review.** This skill explains what exists. It does not judge the
  quality of what exists.
```

- [ ] **Step 3: Write the gathering and outline steps**

```markdown
## Steps

1. **Gather the context.** Run the script once:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/walkthrough/scripts/gather-context.sh"
   ```

   The script returns JSON with `branch`, `base`, `pr`, `commits`, and
   `files`. A `pr` of `null` means the branch has no pull request, which is a
   normal result.

   If the script exits non-zero, report its message in one line and stop. Do
   not suggest a next action.

2. **Build the outline.** Take candidate steps from three sources, in this
   order of priority:

   1. The pull request description. Each bullet is one candidate. A human
      wrote these bullets, so the granularity is already correct.
   2. The diff. A file with real churn that no bullet covers is one candidate.
      Mark this candidate as absent from the pull request description.
   3. The commit subjects. Use these to name and to group candidates. Never
      make a commit subject a step on its own.

   Read both the pull request and the diff every time. The pull request sets
   the outline. The diff catches the case where the description is out of
   date.

3. **Apply the scope argument.** When the user supplies an argument, keep only
   the candidates that match it. The argument can name an area, a path, or a
   symbol. Record what the scope excluded, and report it in the closing
   message.

4. **Apply the cap.** The cap is 8 steps. Below the cap, every candidate gets
   a step. Above the cap, rank the candidates by blast radius and keep the top
   8. A change to authentication, to a data boundary, or to a public contract
   outranks a rename, a comment, or a dependency bump. Put the remainder in
   one closing step named `Also changed`, with one line for each item. Never
   drop a change in silence.

5. **Read the code for a step only when you reach that step.** Do not read
   every file before step 1. Use `git diff` on the one file the current step
   covers.
```

- [ ] **Step 4: Write the step format section**

```markdown
## The step format

Each step is one message. The budget is 150 words.

```
Step 3 of 5: getSerialNumbersForDevice

Problem. The endpoint had no authentication and no tenant filter. Any
deviceId plus passTypeIdentifier returned a device's serial numbers,
including serial numbers that belong to other tenants.

Change. The endpoint now requires a pass token that matches the device,
and the query scopes to that pass's tenant.

  const pass = await requirePassToken(req, deviceId)
  return serials.find({ tenant: pass.tenant, deviceId })

Consequence. A caller without a valid pass token gets 401. A caller with
one sees only its own tenant's serial numbers.

src/routes/devices.ts:88

Next, or expand this one?
```

### Rules for a step

1. Three labelled sections: `Problem`, `Change`, `Consequence`. Each section
   is 1 to 3 sentences.
2. Follow the `write-technical-content` skill: active voice, one instruction
   per sentence, one term for one concept. Use present tense, except in
   `Problem`, which describes a state that the change removed.
3. A snippet is optional. A snippet is 5 lines maximum. Add a snippet only
   when the prose alone cannot carry the change. Never show a diff block.
   Never show two snippets in one step.
4. Give one `file:line` reference as a markdown link, so that the user can
   click it. Give a second reference only when the change spans two places.
5. A step that comes from the diff and not from the pull request description
   adds one line: `Not in the PR description.`
6. End with an offer to continue or to expand.

Understanding a change is understanding a delta. An inventory of what changed
restates the diff, which the user can already read. The state before the
change is the part the diff does not show.
```

- [ ] **Step 5: Write the interaction and closing sections**

```markdown
## Interaction

Open with two lines, then step 1 in the same message:

```
5 steps. 2 from the PR description, 3 found in the diff.
Say "next" to continue, or ask about anything.

Step 1 of 5: ...
```

Present one step and wait. The user has four options:

- Advance to the next step.
- Ask a question about the current step. Answer it, then offer the step's
  closing line again.
- Ask to expand the current step.
- Name a step number to jump to, or ask to skip a step.

### Expand

Read more context for the current step: the code around the change, the path
that calls the changed function, or the fuller diff for that one file. Keep
the same budget. An expansion is a second short message. Offer to continue
afterwards.

### Quiz

When the user asks for a quiz, ask one short question after each step, check
the answer, and then advance. Do not quiz the user unless the user asks. The
user asked for a walkthrough and not for an examination.

## Closing message

After the last step, write three lines at most:

```
5 steps done. The change moves pass issuance behind the permission guard
and closes a cross-tenant read on the device endpoint.

Not walked: 3 config and dependency updates.
```

Give one sentence for what the branch does as a whole. Then give one line for
anything the cap or the scope excluded. Omit the second line when nothing was
excluded.

## Errors

| Case | Response |
| --- | --- |
| The script exits non-zero | Report its message in one line and stop. |
| No pull request for the branch | Build the outline from the diff and say so. |
| `gh` is absent or not logged in | Treat as no pull request. Say that the pull request was not read. |
| The scope matches nothing | Say that the scope matched no change. Ask whether to walk the whole branch. |
```

- [ ] **Step 6: Verify the frontmatter parses**

```bash
head -5 plugins/soong/skills/walkthrough/SKILL.md
awk '/^---$/{n++; next} n==1' plugins/soong/skills/walkthrough/SKILL.md | head -3
```

Expected: the file opens with `---`, and the `awk` command prints the `name`
and `description` lines. The `description` must be one line: a line break
inside it breaks the YAML.

- [ ] **Step 7: Check the skill against its own rules**

Read the finished body once and confirm:

- No em-dashes.
- No sentence uses "will".
- No passive voice in an instruction.
- Every list of procedure steps holds six items or fewer, or is split.

Fix anything that fails, then continue.

- [ ] **Step 8: Commit**

```bash
git add plugins/soong/skills/walkthrough/SKILL.md
git commit -m "feat(walkthrough): add the walkthrough skill"
```

---

### Task 5: Version bump and end-to-end verification

**Files:**
- Modify: `plugins/soong/.claude-plugin/plugin.json`

- [ ] **Step 1: Bump the version**

The repository `CLAUDE.md` requires a minor bump for a feature.

```bash
jq '.version = "0.7.0"' plugins/soong/.claude-plugin/plugin.json > /tmp/plugin.json \
  && mv /tmp/plugin.json plugins/soong/.claude-plugin/plugin.json
jq -r .version plugins/soong/.claude-plugin/plugin.json
```

Expected: `0.7.0`.

- [ ] **Step 2: Run the full test suite**

```bash
bash plugins/soong/skills/walkthrough/scripts/gather-context.test.sh
```

Expected: `all checks passed`, exit 0.

- [ ] **Step 3: Run the script against this real branch**

```bash
bash plugins/soong/skills/walkthrough/scripts/gather-context.sh | jq .
```

Expected: valid JSON. `branch` is the current branch. `base` is `main`.
`commits` holds this plan's commits. `files` lists the files this plan
created. This is the first run against a real linked worktree with real
history, so read the output rather than only checking the exit code.

- [ ] **Step 4: Confirm the file layout**

```bash
find plugins/soong/skills/walkthrough -type f | sort
test -x plugins/soong/skills/walkthrough/scripts/gather-context.sh \
  && echo "script is executable" || echo "SCRIPT IS NOT EXECUTABLE"
```

Expected: three files, and `script is executable`.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/.claude-plugin/plugin.json
git commit -m "chore(soong): bump version to 0.7.0"
```

---

## Definition of done

- [ ] `gather-context.test.sh` passes with no failures and no unexpected skips.
- [ ] `gather-context.sh` returns valid JSON on this branch, verified through `jq`.
- [ ] The script exits non-zero with a readable message outside a repository, on a base branch, and on a detached HEAD.
- [ ] `SKILL.md` has valid frontmatter with a single-line description.
- [ ] `SKILL.md` obeys the `write-technical-content` rules.
- [ ] `plugin.json` reads `0.7.0`.
- [ ] Every commit follows Conventional Commits.

## Notes for the implementer

**Do not weaken a test to make it pass.** Task 3's checks are expected to pass
on first run. If one fails, the script has a real defect. Fix the script.

**The `gh` stub in the tests is deliberate.** It always exits 1, which forces
the no-pull-request path. The tests must never touch the network or depend on
a logged-in account. The pull-request path is verified by hand in Task 5,
Step 3.

**`${CLAUDE_PLUGIN_ROOT}` is the correct prefix** for the script path inside
`SKILL.md`. The existing `hooks.json` in this plugin uses the same variable.
