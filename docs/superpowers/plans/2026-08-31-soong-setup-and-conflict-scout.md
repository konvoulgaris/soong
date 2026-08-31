# soong-setup, the scope rule, and conflict-scout Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the architect-only setup with a generic `soong-setup` that any skill can query per capability, add a per-repo Conventional Commits scope rule to `pr-guard`, and add a `conflict-scout` agent that `architect` runs twice to catch work that already exists on Notion.

**Architecture:** One shell script owns a JSON config keyed by repo, plus a capability table mapping a capability name to the keys it needs. Skills ask `check <capability>` and branch on the exit code. `pr-guard` reads one key from that config to decide how to judge a Conventional Commits subject. A new read-only agent sweeps the configured Notion databases for overlapping work, and `architect` gates on it before and after brainstorming.

**Tech Stack:** Bash, `jq`, `git`, Claude Code plugin skills and agents, Notion MCP. No build step, no package manager. Tests are plain bash scripts run by hand.

**Spec:** `docs/superpowers/specs/2026-08-31-soong-setup-and-conflict-scout-design.md`

---

## Before you start

**Read the spec.** This plan implements it and does not restate its reasoning. Where the plan and the spec disagree, the spec wins and the plan has a bug worth reporting.

**Where you are.** A git worktree at `.claude/worktrees/notion-mcp-notifications-146dbd`, branch `claude/soong-setup-generic-versioning-646d90`. Run every command from the worktree root. Do not `cd` to the main checkout.

**Things about this repo that will bite you:**

- **This repo is a Claude Code plugin, not an application.** Nothing compiles. The "tests" are bash scripts you run by hand: `bash <path>.test.sh`. They print `ok - <label>` lines and exit non-zero if any check failed.
- **`CLAUDE.md` requires Conventional Commits and a version bump in `plugins/soong/.claude-plugin/plugin.json` for every change.** The bump happens once, in Chunk 5, not per commit.
- **A `pr-guard` hook watches your own Bash calls.** It denies PR titles that break Conventional Commits. Once you finish Chunk 3 it may also start judging your `git commit -m` messages — but only if the repo you are committing in has been configured, and this repo will not be. Write conventional commit subjects anyway; `CLAUDE.md` requires them.
- **Commits in this repo carry a `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` trailer.** Chunk 3 deliberately does not apply the footer checks to commits, precisely so this stays legal.
- **`jq` is a hard dependency** of every script here. It is installed.

**The one trap in the test suites.** `pr-guard.test.sh` currently sets no `XDG_DATA_HOME`. After Chunk 3, `pr-guard.sh` reads config from there. If you leave it unset, the tests read the developer's real config and the scope-rule cases pass or fail depending on whose machine runs them. Chunk 3 Task 1 fixes this before any scope-rule test is written. Do not skip it.

**Commit granularity.** Every task ends in a commit. Small commits are the point; do not batch tasks.

---

## File Structure

| File | Responsibility |
| ---- | -------------- |
| `plugins/soong/skills/soong-setup/scripts/soong-setup.sh` | Owns the config file, the capability table, and the four commands. The only thing that reads or writes `soong.json`. Moved from `architect-setup.sh`. |
| `plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh` | Self-check for the above. Moved from `architect-setup.test.sh`. |
| `plugins/soong/skills/soong-setup/SKILL.md` | The user-facing setup conversation: which questions to ask per capability, and the never-invent-an-id rules. Moved from `architect-setup/SKILL.md`. |
| `plugins/soong/hooks/scripts/pr-guard.sh` | Judges PR titles, commit subjects, and PR comments. Reads one config key; owns no config. |
| `plugins/soong/hooks/scripts/pr-guard.test.sh` | Self-check for the above. |
| `plugins/soong/agents/conflict-scout.md` | The sweep-and-judge prompt for the overlap agent. Read-only, no tools key. |
| `plugins/soong/skills/architect/SKILL.md` | Adds Step 1.5 and Step 2.5, and repoints Step 1 at the new script. |
| `plugins/soong/skills/develop/SKILL.md` | Repoints its config check at the new script. No gate. |
| `README.md` | Names `soong-setup` in the requirements section. |
| `plugins/soong/.claude-plugin/plugin.json` | Version bump. |

The script keeps everything config-shaped in one file because the capability table, the key names, and the project-key derivation all change together. Splitting the table into its own file would mean two files to edit to add one capability.

---

## Chunk 1: soong-setup, the script

Renames the script and its test, then adds `check` and makes `set` merge. Nothing else in the plugin changes yet, so at the end of this chunk `architect` and `develop` still call the old path — which no longer exists. That break is closed in Chunk 2. Do not stop between chunks 1 and 2 and expect a working plugin.

### Task 1: Move the three files, keeping history

**Files:**
- Move: `plugins/soong/skills/architect-setup/scripts/architect-setup.sh` → `plugins/soong/skills/soong-setup/scripts/soong-setup.sh`
- Move: `plugins/soong/skills/architect-setup/scripts/architect-setup.test.sh` → `plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh`
- Move: `plugins/soong/skills/architect-setup/SKILL.md` → `plugins/soong/skills/soong-setup/SKILL.md`

- [ ] **Step 1: Create the new directory and move all three files with `git mv`**

```bash
mkdir -p plugins/soong/skills/soong-setup/scripts
git mv plugins/soong/skills/architect-setup/scripts/architect-setup.sh \
       plugins/soong/skills/soong-setup/scripts/soong-setup.sh
git mv plugins/soong/skills/architect-setup/scripts/architect-setup.test.sh \
       plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh
git mv plugins/soong/skills/architect-setup/SKILL.md \
       plugins/soong/skills/soong-setup/SKILL.md
```

`git mv`, not `cp` then `rm`, so `git log --follow` still reaches the history.

- [ ] **Step 2: Verify the old directory is gone and nothing else references it**

```bash
ls plugins/soong/skills/architect-setup 2>&1
```

Expected: `No such file or directory`. If the directory still exists, something was left behind — list it and move it.

- [ ] **Step 3: Point the test at the renamed script**

In `soong-setup.test.sh`, two lines need editing. Line 2's comment, and the `script=` line:

```bash
# Self-check for soong-setup.sh. Run: bash soong-setup.test.sh
```

```bash
script="$(cd "$(dirname "$0")" && pwd)/soong-setup.sh"
```

Leave the `config=` line pointing at `architect.json` for now. Task 2 changes it, and changing both at once means a failing run you cannot attribute.

- [ ] **Step 4: Run the moved test suite**

```bash
bash plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh
```

Expected: every check passes, exit 0. The script's behavior has not changed, only its path. A failure here means the move broke something — fix it before continuing.

- [ ] **Step 5: Commit**

```bash
git add -A plugins/soong/skills
git commit -m "refactor(soong-setup): rename architect-setup to soong-setup

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 2: Read soong.json, falling back to architect.json

**Files:**
- Modify: `plugins/soong/skills/soong-setup/scripts/soong-setup.sh`
- Test: `plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh`

- [ ] **Step 1: Write the failing tests**

Add to `soong-setup.test.sh`, after the existing `config=` definition. First change `config` to the new file and add a second variable for the old one:

```bash
config="$XDG_DATA_HOME/soong/soong.json"
legacy="$XDG_DATA_HOME/soong/architect.json"
```

Then add a `seed_legacy` helper next to the existing `seed`:

```bash
seed_legacy() { mkdir -p "$(dirname "$legacy")"; printf '%s' "$1" > "$legacy"; }
```

And append these cases at the end of the file, before the final summary block:

```bash
# --- soong.json with an architect.json fallback -----------------------------
rm -f "$config" "$legacy"
seed_legacy '{"legacyonly":{"roadmapDb":"LR","taskDb":"LT","taskTemplate":null}}'
check "falls back to architect.json"  0    "$(run get legacyonly)"
check "fallback reads the record"     LR   "$(bash "$script" get legacyonly | jq -r .roadmapDb)"

# soong.json wins outright; the two files are never merged
seed '{"both":{"roadmapDb":"NEW","taskDb":"NT","taskTemplate":null}}'
seed_legacy '{"both":{"roadmapDb":"OLD","taskDb":"OT","taskTemplate":null},"legacyonly":{"roadmapDb":"LR","taskDb":"LT","taskTemplate":null}}'
check "soong.json wins"            NEW "$(bash "$script" get both | jq -r .roadmapDb)"
check "no merge from the legacy file" 3 "$(run get legacyonly)"

# set always writes the new file and never touches the old one
rm -f "$config"
seed_legacy '{"migrate":{"roadmapDb":"OLD","taskDb":"OT","taskTemplate":null}}'
bash "$script" set --roadmap-db NEWR --task-db NEWT migrate >/dev/null 2>&1
check "set wrote soong.json"       NEWR "$(jq -r '.migrate.roadmapDb' "$config")"
check "set left architect.json be" OLD  "$(jq -r '.migrate.roadmapDb' "$legacy")"
rm -f "$legacy"
```

The "no merge" case is the important one: a repo present only in the legacy file must read as unconfigured once `soong.json` exists, because merging needs a precedence rule the user cannot see.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh
```

Expected: the new cases FAIL. The script still writes and reads `architect.json`, so `set wrote soong.json` fails with a `jq` error on a missing file, and the fallback cases fail because nothing looks for the legacy name.

- [ ] **Step 3: Implement the fallback**

In `soong-setup.sh`, replace the single `file=` assignment:

```bash
file="$dir/architect.json"
```

with a write target, a legacy path, and a read resolver:

```bash
file="$dir/soong.json"
legacy="$dir/architect.json"

# Reads prefer soong.json and fall back to the pre-rename name, so a repo
# configured before the rename keeps working with no migration step. Writes
# always target soong.json, so the first set migrates the repo. The fallback is
# read-only and one directional: nothing writes back to architect.json, and the
# two files are never merged, because a merge needs a precedence rule the user
# cannot see.
read_file() {
  if [ -f "$file" ]; then
    echo "$file"
  elif [ -f "$legacy" ]; then
    echo "$legacy"
  else
    return 1
  fi
}
```

Then in the `get` branch, replace the `[ -f "$file" ] || die ...` line and every subsequent `"$file"` reference with the resolved path:

```bash
    src="$(read_file)" || die "no config for '$project'" 3
    jq -e . "$src" >/dev/null 2>&1 || die "$src is not valid JSON"
    jq -e 'type == "object"' "$src" >/dev/null 2>&1 || die "$src is not a JSON object"
    # --exit-status would also fire on a stored false/null, so test for the key.
    jq -e --arg p "$project" 'has($p)' "$src" >/dev/null 2>&1 \
      || die "no config for '$project'" 3
    jq --arg p "$project" '.[$p]' "$src"
```

The `set` branch keeps using `$file` throughout, unchanged. That is what makes writes always target the new name.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh
```

Expected: every check passes, including the pre-existing ones. The `set overwrites` and `stored false is found` cases must still pass — if they broke, the `$file`/`$src` split is wrong somewhere.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/soong-setup/scripts
git commit -m "feat(soong-setup): read soong.json, falling back to architect.json

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 3: Make `set` merge instead of replace

**Files:**
- Modify: `plugins/soong/skills/soong-setup/scripts/soong-setup.sh`
- Test: `plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh`

Today `set` assigns a whole object, so a later Notion reconfiguration would erase `requireScope`. Merging is what makes the capabilities independent.

- [ ] **Step 1: Write the failing tests**

Append to `soong-setup.test.sh`:

```bash
# --- set merges, so one capability does not clobber another ------------------
rm -f "$config"
bash "$script" set --roadmap-db R --task-db T mergetest >/dev/null 2>&1
bash "$script" set --require-scope true mergetest >/dev/null 2>&1
rec="$(bash "$script" get mergetest)"
check "scope stored alone"      true "$(jq -r .requireScope <<<"$rec")"
check "notion keys survived"    R    "$(jq -r .roadmapDb    <<<"$rec")"

bash "$script" set --roadmap-db R2 mergetest >/dev/null 2>&1
rec="$(bash "$script" get mergetest)"
check "notion key updated"      R2   "$(jq -r .roadmapDb    <<<"$rec")"
check "scope survived a notion set" true "$(jq -r .requireScope <<<"$rec")"
check "taskDb survived a partial set" T "$(jq -r .taskDb     <<<"$rec")"

# --require-scope takes true or false only
check "require-scope false ok"  0 "$(run set --require-scope false scopetest)"
check "require-scope stored"    false "$(bash "$script" get scopetest | jq -r .requireScope)"
check "require-scope yes fails" 2 "$(run set --require-scope yes badscope)"
check "require-scope 1 fails"   2 "$(run set --require-scope 1 badscope)"
check "bad require-scope wrote nothing" 3 "$(run get badscope)"

# set with no flags at all is a usage error, not a no-op write
check "set with no flags exits 2" 2 "$(run set noflags)"
check "set with no flags wrote nothing" 3 "$(run get noflags)"

# a partial set on a repo that does not exist yet still creates it
check "partial set creates" 0 "$(run set --task-db ONLYT newrepo)"
check "partial set stored"  ONLYT "$(bash "$script" get newrepo | jq -r .taskDb)"
check "unset key is absent" 0 "$(bash "$script" get newrepo | jq -e 'has(\"roadmapDb\") | not' >/dev/null; echo $?)"
```

That last case matters: an unset key must be **absent**, not `null`. `check` in Task 4 tests presence with `has()`, and a stored `null` would read as configured.

Also update the two existing cases that assert `set` requires both database flags — they now contradict the merge behavior. Find and delete these lines:

```bash
check "missing --roadmap-db exits 2" 2 "$(run set --task-db T only-task)"
```

and its `--task-db` counterpart if present. Replace with the "no flags" cases above, which are the real constraint now.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh
```

Expected: the merge cases FAIL (`scope survived a notion set` returns `null`), and `--require-scope` is rejected as an unknown flag with exit 2 — which accidentally passes the two `badscope` cases for the wrong reason. That is fine; Step 4 makes them pass for the right one.

- [ ] **Step 3: Implement the merge and the new flag**

In the `set` branch, add `scope=""` to the variable initialisation line, then add the flag to both `case` arms. In the long-form arm, add `--require-scope` to the flag list and this to the inner dispatch:

```bash
            --require-scope)
              case "$1" in
                true|false) scope="$1" ;;
                *) die "--require-scope takes true or false, got '$1'" 2 ;;
              esac
              ;;
```

And the `=`-form:

```bash
        --require-scope=*)
          scope="${1#--require-scope=}"
          case "$scope" in
            true|false) ;;
            *) die "--require-scope takes true or false, got '$scope'" 2 ;;
          esac
          ;;
```

Replace the two required-flag guards:

```bash
    [ -n "$roadmap" ] || die "--roadmap-db is required" 2
    [ -n "$task" ]    || die "--task-db is required" 2
```

with a single at-least-one guard, since a repo may configure `commits` alone:

```bash
    # No flag is individually required any more: a repo may configure the
    # commits capability without ever supplying a Notion database. But a set
    # with nothing to set is a usage error, not a no-op write.
    [ -n "$roadmap$task$template$scope" ] || die "set needs at least one flag" 2
```

Then replace the `jq` assignment with a merge. The old version assigned a whole object; this one sets only the keys that were given:

```bash
    jq --arg p "$project" --arg r "$roadmap" --arg k "$task" --arg tpl "$template" \
       --arg scope "$scope" \
       --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '(.[$p] //= {})
        | (if ($r     | length) > 0 then .[$p].roadmapDb    = $r          else . end)
        | (if ($k     | length) > 0 then .[$p].taskDb       = $k          else . end)
        | (if ($tpl   | length) > 0 then .[$p].taskTemplate = $tpl        else . end)
        | (if ($scope | length) > 0 then .[$p].requireScope = ($scope == "true") else . end)
        | .[$p].updatedAt = $t' "$file" > "$tmp" || die "failed to build the new config"
```

Two behaviors worth naming. `requireScope` is stored as a real JSON boolean, not the string `"true"`, which is why the comparison is there. And an omitted `--task-template` now leaves an existing template alone rather than nulling it — but an explicit `--task-template=` still needs to clear it, which the next step tests.

- [ ] **Step 4: Handle the explicit template clear**

The existing test `empty template is null` passes `--task-template=` to clear a stored template. Under the merge above, an empty string is indistinguishable from an omitted flag, so that case now fails.

Add a separate flag-seen marker. Next to `template=""`, add `template_seen=0`, set it to `1` in both `--task-template` arms, and change the template line in the `jq` filter:

```bash
       --argjson tplseen "$template_seen" \
```

```bash
        | (if $tplseen == 1
           then .[$p].taskTemplate = (if ($tpl | length) > 0 then $tpl else null end)
           else . end)
```

Also add `$template_seen` to the at-least-one guard, so `set --task-template=` alone is a real call:

```bash
    [ -n "$roadmap$task$template$scope" ] || [ "$template_seen" -eq 1 ] \
      || die "set needs at least one flag" 2
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh
```

Expected: every check passes, old and new. Pay attention to `empty template is null` and `template stored` — those two cover the branch you just added.

- [ ] **Step 6: Commit**

```bash
git add plugins/soong/skills/soong-setup/scripts
git commit -m "feat(soong-setup): merge on set and add --require-scope

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 4: Add the `check` command and the capability table

**Files:**
- Modify: `plugins/soong/skills/soong-setup/scripts/soong-setup.sh`
- Test: `plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh`

- [ ] **Step 1: Write the failing tests**

Append to `soong-setup.test.sh`:

```bash
# --- check <capability> ------------------------------------------------------
rm -f "$config"
check "check on an unconfigured repo exits 3" 3 "$(run check notion nothing)"

bash "$script" set --roadmap-db R --task-db T chk >/dev/null 2>&1
check "notion satisfied"        0 "$(run check notion chk)"
check "commits not satisfied"   3 "$(run check commits chk)"

# a stored false satisfies commits: presence is has(), not truthiness
bash "$script" set --require-scope false chk >/dev/null 2>&1
check "commits satisfied by false" 0 "$(run check commits chk)"

# a partial notion config is not satisfied, and says which key is missing
bash "$script" set --task-db T2 partial >/dev/null 2>&1
check "partial notion exits 3" 3 "$(run check notion partial)"
missing="$(bash "$script" check notion partial 2>&1 >/dev/null)"
case "$missing" in
  *roadmapDb*) check "names the missing key" 0 0 ;;
  *) check "names the missing key" "roadmapDb in stderr" "$missing" ;;
esac

# taskTemplate is optional, so its absence does not fail the capability
check "template not required" 0 "$(run check notion chk)"

# an unknown capability is a caller bug, not an unconfigured repo
check "unknown capability exits 2" 2 "$(run check notyacapability chk)"

# --- check with no capability sweeps everything ------------------------------
check "sweep exits 3 when any capability is missing" 3 "$(run check partial)"
bash "$script" set --require-scope true partial --roadmap-db R3 >/dev/null 2>&1
check "sweep exits 0 when all are satisfied" 0 "$(run check partial)"
sweep="$(bash "$script" check chk 2>&1)"
case "$sweep" in
  *notion*commits*|*commits*notion*) check "sweep lists both capabilities" 0 0 ;;
  *) check "sweep lists both capabilities" "notion and commits" "$sweep" ;;
esac

# a corrupt config is an error, never "unconfigured"
seed 'not json at all'
check "check on corrupt config exits 1" 1 "$(run check notion chk)"
check "sweep on corrupt config exits 1" 1 "$(run check chk)"
rm -f "$config"
```

The `commits satisfied by false` case is the one that catches a `jq -e` truthiness test. The `unknown capability exits 2` case is the one that stops a typo in a skill from reading as "run setup".

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh
```

Expected: every `check` case FAILS with exit 2, because `check` is not a known command yet and the script's `*)` arm rejects it.

- [ ] **Step 3: Implement the capability table and the command**

Add the table near the top of the script, after the `file`/`legacy` assignments, so it reads as configuration rather than logic:

```bash
# Capability -> required keys. Adding a capability is adding a row here; that is
# what replaces a stored setup version number. What is missing is computed from
# which required keys are absent, so a new capability shows up as unsatisfied for
# every repo that has not answered its questions, with nothing to migrate.
#
# Optional keys are deliberately absent from this table. taskTemplate is optional
# for notion, so it appears nowhere and never blocks a capability.
capabilities="notion commits"
required_keys() {
  case "$1" in
    notion)  echo "roadmapDb taskDb" ;;
    commits) echo "requireScope" ;;
    *)       return 1 ;;
  esac
}
```

Then add the `check` branch to the main `case`, before the `-h|--help|help` arm:

```bash
  check)
    [ $# -le 2 ] || die "check takes a capability and an optional project" 2
    command -v jq >/dev/null || die "jq is required"

    # check <cap> [project] and check [project] are told apart by whether the
    # first argument names a capability. So a project sharing a capability's name
    # would be unreachable in the sweep form; the projects here are repo
    # directory names, and "notion" or "commits" as a repo name is a collision
    # worth losing to keep the call sites this short.
    cap=""
    if [ -n "${1:-}" ] && required_keys "$1" >/dev/null 2>&1; then
      cap="$1"; shift
    elif [ $# -eq 2 ]; then
      die "unknown capability '$1' (want: $capabilities)" 2
    fi

    project="$(resolve_project "${1:-}")" || exit $?

    src="$(read_file)" || src=""
    if [ -n "$src" ]; then
      jq -e . "$src" >/dev/null 2>&1 || die "$src is not valid JSON"
      jq -e 'type == "object"' "$src" >/dev/null 2>&1 || die "$src is not a JSON object"
    fi

    # Presence is has(), never truthiness: requireScope false is a configured
    # commits capability, and a jq -e test would read it as missing.
    missing_for() { # missing_for <capability> -> prints missing key names
      local c="$1" k out=""
      for k in $(required_keys "$c"); do
        if [ -z "$src" ] \
          || ! jq -e --arg p "$project" --arg k "$k" \
                 '(.[$p] // {}) | has($k)' "$src" >/dev/null 2>&1; then
          out="$out $k"
        fi
      done
      printf '%s' "${out# }"
    }

    if [ -n "$cap" ]; then
      gaps="$(missing_for "$cap")"
      [ -z "$gaps" ] || die "$cap is missing: $gaps" 3
      exit 0
    fi

    rc=0
    for c in $capabilities; do
      gaps="$(missing_for "$c")"
      if [ -z "$gaps" ]; then
        echo "$c: configured"
      else
        echo "$c: missing $gaps"
        rc=3
      fi
    done
    exit "$rc"
    ;;
```

Update the `usage()` heredoc and the unknown-command `die` message to list `check`:

```bash
  soong-setup.sh check [capability] [project]
```

```bash
    die "unknown command '$cmd' (want: get, check, set)" 2
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh
```

Expected: every check passes. If `commits satisfied by false` fails, the presence test is using truthiness somewhere.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/soong-setup/scripts
git commit -m "feat(soong-setup): add check for per-capability configuration

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 5: Rewrite the setup skill

**Files:**
- Modify: `plugins/soong/skills/soong-setup/SKILL.md`

No test — this file is a prompt. Its correctness is whether a reader follows it.

- [ ] **Step 1: Rewrite the frontmatter and body**

Replace the whole file. Keep the existing rules verbatim where they carry over; they are the load-bearing part.

```markdown
---
name: soong-setup
description: Record what this repo needs for soong's skills to run - which Notion roadmap and task databases it maps to, and whether its commits carry a Conventional Commits scope. Use when the user runs /soong-setup, when another skill reports the repo is not configured, or when the user wants to change what a repo is configured for. Stops without writing anything if the user does not supply valid Notion databases.
---

# soong-setup

Configure this repo for soong's skills. Other skills ask this one's script whether
what they need is present, and send the user here when it is not.

Start by telling the user, in one line, what this does. For example:

> `soong-setup` records what this repo needs for soong's skills: the Notion
> databases `/architect` writes to, and whether commits here carry a scope.

## Arguments

```
/soong-setup [capability]
```

With no argument, sweep every capability and ask only for what is missing. With a
capability, configure that one alone.

## Config

- **File:** `${XDG_DATA_HOME:-$HOME/.local/share}/soong/soong.json`. This is user
  config, so it lives under `XDG_DATA_HOME`. The PR records that `manage-pr` writes
  are regenerable state and live under `XDG_STATE_HOME` instead.
- **Script:** `${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh`
- Keyed by the repo directory name, taken from the main checkout, so every linked
  worktree of one repo shares a single mapping.
- Reads fall back to the pre-rename `architect.json`, so a repo configured before
  the rename keeps working. The first `set` migrates it.

## Capabilities

| Capability | Keys                                  | Used by                |
| ---------- | ------------------------------------- | ---------------------- |
| `notion`   | `roadmapDb`, `taskDb`, `taskTemplate` | `architect`, `develop` |
| `commits`  | `requireScope`                        | the `pr-guard` hook    |

`taskTemplate` is optional. Every other key is required by its capability.

## Steps

1. **See what is missing.**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" check [capability]
   ```

   Exit 0 means nothing is missing: show the user the current state, ask whether
   to change anything, and stop if not. Exit 3 lists what is missing: continue,
   and ask only for those. Exit 1 means the config is corrupt, and `set` will
   refuse to overwrite it: report the message and stop, because answering the
   questions below cannot succeed. Exit 2 means this is not a git repository, or
   the capability name is wrong: report it and stop.

2. **For `notion`, ask for the roadmap item database.** Ask for a Notion database
   URL or id.

3. **Ask for the task database.** Same. One Notion task in this database is one PR
   in a stack.

4. **Verify both databases with the Notion MCP** before writing anything. Fetch
   each one and confirm it resolves to a database the user can access. Show the
   user the resolved database titles so they can catch a wrong paste.

   If either database does not resolve, or the user cannot supply one, **stop
   here.** Write nothing. Say which database was invalid and that `/architect`
   stays unavailable for this repo until setup completes.

5. **Offer the task template.** List the templates available on the task database
   and let the user pick one, or skip. The template is optional; `architect` falls
   back to the database's own default when it is null.

6. **For `commits`, ask one question:** does this repo require a scope on commit
   and PR subjects?

   > Do commits and PR titles in this repo carry a scope, as in
   > `feat(scope): summary`? Answering yes denies subjects without a scope.
   > Answering no denies subjects with one.

   There is no third answer here. Leaving the question unanswered is what the repo
   already does, and the user reaches this step by choosing to answer it. Say what
   each answer turns on, because both directions deny something that is legal
   today.

7. **Write what was gathered.** Pass only the flags for the capabilities you asked
   about; the script merges, so it does not disturb the rest.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" set \
     [--roadmap-db "<id>"] [--task-db "<id>"] [--task-template "<id>"] \
     [--require-scope true|false]
   ```

8. **Confirm** the stored record back to the user, and name which skills just
   became available.

## Rules

- Never invent, guess, or infer a database or template id. Ask, then verify via MCP.
  The script stores whatever string it is given: it cannot tell a real database id
  from a typo, so MCP verification is the only check that exists.
- Ask one question at a time.
- Never answer the `commits` question on the user's behalf by reading the repo's
  git history. A repo whose commits are inconsistent is exactly the repo where the
  user's intent is the only signal that matters.
```

- [ ] **Step 2: Verify the frontmatter parses and the script path resolves**

```bash
head -4 plugins/soong/skills/soong-setup/SKILL.md
ls plugins/soong/skills/soong-setup/scripts/soong-setup.sh
```

Expected: the `name:` is `soong-setup`, and the script exists at the path the skill names.

- [ ] **Step 3: Commit**

```bash
git add plugins/soong/skills/soong-setup/SKILL.md
git commit -m "feat(soong-setup): rewrite the skill for per-capability setup

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Chunk 2: repoint the callers

Closes the break Chunk 1 opened. Two skills reference the old script path; both must move in the same chunk.

### Task 1: Repoint architect Step 1

**Files:**
- Modify: `plugins/soong/skills/architect/SKILL.md` (frontmatter line 3, Step 1 at lines 21-35)

- [ ] **Step 1: Replace Step 1 with the two-call sequence**

Replace the whole `## Step 1: Check configuration` section through the end of its exit-code list:

```markdown
## Step 1: Check configuration

Two calls. The first asks whether this repo is configured for Notion; the second
reads the ids.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" check notion
bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" get
```

**Step A, `check notion`:**

- **Exit 0** — go to Step B.
- **Exit 3** — this repo is not configured for Notion. Say so, then invoke the
  `soong-setup` skill with the `notion` capability. When setup finishes, run
  `check notion` again: exit 0 means go to Step B, anything else means **stop
  here**. Do not brainstorm and do not touch Notion on a non-zero code.
- **Exit 1** — an error, not an unconfigured repo: no `jq`, or a corrupt config
  file. Report the message and stop. Never re-run setup to "fix" a corrupt file;
  setup refuses to overwrite one.
- **Exit 2** — not inside a git repository, or a usage error. Report it and stop.

**Step B, `get`:** read `roadmapDb`, `taskDb`, and `taskTemplate` from the JSON.

A non-zero exit here is a bug, not a user problem, because Step A just confirmed
the keys exist. Report the exit code and stop. Do not run setup again: the state
that produced this is not one setup can resolve.

`check notion` exit 3 does not mean the repo has never been set up. It means the
Notion keys are missing, which is also true of a repo configured for commits
alone. Say "not configured for Notion", not "never set up".

Confirm the Notion MCP is reachable now, in this step, rather than discovering at
Step 5 that a finished spec has nowhere to go.
```

- [ ] **Step 2: Update the frontmatter description**

In line 3, replace `Requires the repo to be configured via architect-setup first.` with:

```
Requires the repo to be configured via soong-setup first.
```

- [ ] **Step 3: Verify no stale references remain in this file**

```bash
grep -n "architect-setup" plugins/soong/skills/architect/SKILL.md
```

Expected: no output. Any hit is a reference Step 1 or Step 2 missed.

- [ ] **Step 4: Commit**

```bash
git add plugins/soong/skills/architect/SKILL.md
git commit -m "refactor(architect): call soong-setup for the config check

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 2: Repoint develop and the README

**Files:**
- Modify: `plugins/soong/skills/develop/SKILL.md` (lines 3, 21, 74, 78, 442)
- Modify: `README.md`

- [ ] **Step 1: Replace develop's config step**

At line 74, replace the script path and the prose that follows it:

```markdown
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" check notion
   bash "${CLAUDE_PLUGIN_ROOT}/skills/soong-setup/scripts/soong-setup.sh" get
   ```

   `check notion` exit 0 continues to `get`, which reads the ids. Exit 3 means
   this repo is not configured for Notion: invoke `soong-setup`, then run
   `check notion` again and stop on anything non-zero. Exit 1 is a corrupt
   config, exit 2 is not a git repository. Both stop. A non-zero `get` after a
   clean `check` is a bug: report it and stop.
```

- [ ] **Step 2: Update the three remaining references**

Line 3 (frontmatter) and line 21 (Assumes): `architect-setup` → `soong-setup`.

Line 442 (the error table row): change `Invoke \`architect-setup\`, re-check, stop on non-zero` to `Invoke \`soong-setup\`, re-check, stop on non-zero`.

- [ ] **Step 3: Add soong-setup to the README requirements**

In `README.md`, under `## Requirements`, add a bullet alongside the existing two:

```markdown
- **soong-setup** — run `/soong-setup` once per repo. `/architect` and `/develop`
  need the Notion databases it records, and the `pr-guard` hook reads the commit
  scope rule it records.
```

- [ ] **Step 4: Verify the plugin has no stale references left**

```bash
grep -rn "architect-setup" plugins/ README.md
```

Expected: no output. The historical specs and plans under `docs/superpowers/` still mention it and are deliberately left alone, which is why this grep excludes them.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/develop/SKILL.md README.md
git commit -m "refactor(develop): call soong-setup for the config check

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Chunk 3: the scope rule in pr-guard

### Task 1: Isolate the test suite from the developer's real config

**Files:**
- Modify: `plugins/soong/hooks/scripts/pr-guard.test.sh`

Do this before writing any scope-rule test. `pr-guard.sh` is about to read config from `XDG_DATA_HOME`, and the suite currently sets neither that nor a fake repo — so it would read whatever the developer running it happens to have configured, and the scope cases would pass or fail by machine.

- [ ] **Step 1: Add the isolation preamble**

After the `HOOK=` line, insert:

```bash
# pr-guard reads the commit scope rule from soong.json. Without a pinned
# XDG_DATA_HOME the suite would read the developer's own config and the scope
# cases would pass or fail depending on whose machine ran them.
XDG_DATA_HOME="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
export XDG_DATA_HOME
trap 'rm -rf "$XDG_DATA_HOME"' EXIT

# The hook resolves its project key from git, so the suite needs a repo to sit
# in that is not the checkout it was launched from.
fixture="$XDG_DATA_HOME/repo"
git init -q "$fixture" 2>/dev/null
cd "$fixture" || { echo "cannot enter the fixture repo" >&2; exit 1; }
project="repo"

setup="$(cd "$(dirname "$HOOK")/../../skills/soong-setup/scripts" && pwd)/soong-setup.sh"

# Put the repo in one of the three scope states. No argument clears it.
scope_state() {
  if [ -n "${1:-}" ]; then
    bash "$setup" set --require-scope "$1" "$project" >/dev/null 2>&1
  else
    rm -f "$XDG_DATA_HOME/soong/soong.json"
  fi
}
```

The `cd` matters: `HOOK` is resolved to an absolute path on the line above, so it survives the directory change.

- [ ] **Step 2: Run the existing suite to confirm nothing regressed**

```bash
bash plugins/soong/hooks/scripts/pr-guard.test.sh
```

Expected: the same pass count as before your change, 0 failures. The hook does not read config yet, so isolating the environment must change nothing.

- [ ] **Step 3: Assert the resolved script path exists**

Add this case near the end, before the summary block. It is the tripwire for the silent-failure mode the spec calls out: if the skills directory is ever moved, this fails instead of the scope rule quietly never firing.

```bash
# The hook finds soong-setup.sh relative to its own path. A directory move must
# fail here rather than silently disabling the scope rule.
if [ -f "$setup" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL  soong-setup.sh not found at %s\n' "$setup"
fi
```

- [ ] **Step 4: Run the suite again**

```bash
bash plugins/soong/hooks/scripts/pr-guard.test.sh
```

Expected: one more pass than Step 2, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/hooks/scripts/pr-guard.test.sh
git commit -m "test(pr-guard): isolate the suite from the developer's config

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 2: Apply the scope rule to PR titles

**Files:**
- Modify: `plugins/soong/hooks/scripts/pr-guard.sh`
- Test: `plugins/soong/hooks/scripts/pr-guard.test.sh`

- [ ] **Step 1: Write the failing tests**

Append, before the summary block:

```bash
# --- scope rule on PR titles ------------------------------------------------
scope_state true
check deny   'scoped required, none given'   'gh pr create --title "feat: thing"'
check advise 'scoped required, one given'    'gh pr create --title "feat(api): thing"'
check deny   'scoped required, placeholder'  'gh pr create --title "feat(*): thing"'

scope_state false
check deny   'scope forbidden, one given'    'gh pr create --title "feat(api): thing"'
check advise 'scope forbidden, none given'   'gh pr create --title "feat: thing"'

scope_state
check advise 'unset allows a scope'          'gh pr create --title "feat(api): thing"'
check advise 'unset allows no scope'         'gh pr create --title "feat: thing"'
check deny   'unset still denies placeholder' 'gh pr create --title "feat(misc): thing"'
check deny   'unset still denies bad shape'  'gh pr create --title "thing"'

# a corrupt config must not enforce a scope rule, and must not break the guard
mkdir -p "$XDG_DATA_HOME/soong"
printf 'not json' > "$XDG_DATA_HOME/soong/soong.json"
check advise 'corrupt config falls open'     'gh pr create --title "feat: thing"'
check deny   'corrupt config still checks shape' 'gh pr create --title "thing"'
scope_state
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash plugins/soong/hooks/scripts/pr-guard.test.sh
```

Expected: the four `scoped required` / `scope forbidden` cases FAIL. The `unset` and corrupt-config cases already pass, because today's guard behaves exactly like the unset state — that is the point of the third state, and those cases are regression cover.

- [ ] **Step 3: Implement the config read**

Near the top of `pr-guard.sh`, after the `cmd=` line:

```bash
# The repo's Conventional Commits scope rule: "true", "false", or empty for
# "not configured". Read through soong-setup.sh so the project-key derivation
# lives in exactly one place.
#
# Resolved from $0 rather than CLAUDE_PLUGIN_ROOT: no hook script here uses that
# variable, and it is set for the hook command rather than guaranteed inside this
# subprocess. Depending on it would fail silently, because the fail-open rule
# below turns a failed read into "no scope rule" — a feature that looks like it
# works while enforcing nothing.
require_scope=""
setup_sh="$(cd "$(dirname "$0")/../../skills/soong-setup/scripts" 2>/dev/null && pwd)/soong-setup.sh"
if [ -f "$setup_sh" ] && command -v jq >/dev/null 2>&1; then
  # Fail open on everything: a missing config, a corrupt one, a non-repo cwd, a
  # missing jq. A guard that dies loudly on every Bash call because a config file
  # got corrupted is worse than one that quietly stops checking scope.
  require_scope="$(bash "$setup_sh" get 2>/dev/null \
    | jq -r 'if type == "object" and has("requireScope")
             then (.requireScope | tostring) else "" end' 2>/dev/null)"
  case "$require_scope" in true|false) ;; *) require_scope="" ;; esac
fi

# Does a Conventional Commits subject carry a scope? Kept separate from the shape
# check so the shape rule stays in one place and this only answers the one
# question.
has_scope() {
  printf '%s' "$1" | grep -qE '^[a-z]+\([^)]*\)!?:'
}
```

- [ ] **Step 4: Apply it to Branch 1**

In the PR create/edit branch, after the existing placeholder and shape checks, add the state test. It goes inside the `if [ -n "$title" ]; then` block, after the existing `if/elif` chain:

```bash
      if [ "$require_scope" = "true" ] && ! has_scope "$title"; then
        reasons+=("This repo requires a scope on PR titles. Write 'feat(scope): summary'. Got: \"$title\"")
      elif [ "$require_scope" = "false" ] && has_scope "$title"; then
        reasons+=("This repo does not use scopes on PR titles. Write 'feat: summary'. Got: \"$title\"")
      fi
```

The placeholder check keeps running first in all three states. `feat(*)` satisfies "has a scope" while meaning nothing, so under `true` it still has to be caught.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash plugins/soong/hooks/scripts/pr-guard.test.sh
```

Expected: every check passes. If `unset allows a scope` broke, the `require_scope` default is not empty when the config is missing.

- [ ] **Step 6: Commit**

```bash
git add plugins/soong/hooks/scripts/pr-guard.sh plugins/soong/hooks/scripts/pr-guard.test.sh
git commit -m "feat(pr-guard): enforce the repo's scope rule on PR titles

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 3: Add the commit-message branch

**Files:**
- Modify: `plugins/soong/hooks/scripts/pr-guard.sh`
- Test: `plugins/soong/hooks/scripts/pr-guard.test.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# --- commit subjects --------------------------------------------------------
# The whole branch is gated on the commits capability. An unconfigured repo hears
# nothing at all, including on shape, because commits are far higher-frequency
# than PR titles and a new universal denial on them is the more damaging one.
scope_state
check silent 'unset ignores a bad commit'  'git commit -m "wip"'
check silent 'unset ignores a good commit' 'git commit -m "feat(api): thing"'

scope_state true
check deny   'commit needs a scope'        'git commit -m "feat: thing"'
check advise 'commit has a scope'          'git commit -m "feat(api): thing"'
check deny   'commit shape is checked'     'git commit -m "wip"'

scope_state false
check deny   'commit must not be scoped'   'git commit -m "feat(api): thing"'
check advise 'commit is unscoped'          'git commit -m "feat: thing"'

# a Co-Authored-By trailer is required by CLAUDE.md, so it must stay legal
scope_state true
check advise 'trailer is allowed' 'git commit -m "feat(api): thing" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"'

# the first -m is the subject; later ones are body paragraphs
check advise 'later -m is not the subject' 'git commit -m "feat(api): thing" -m "wip notes"'

# messages the hook cannot read: advise, never deny
check advise 'no -m at all'   'git commit'
check advise 'message in a file' 'git commit -F /tmp/msg'
check advise 'amend without -m'  'git commit --amend --no-edit'

# git generates these subjects and a later rebase absorbs them
check advise 'fixup is exempt'  'git commit --fixup=HEAD'
check advise 'squash is exempt' 'git commit --squash=HEAD'

# the PR branch is ordered first, so a compound command stops there
check deny 'compound stops at the PR title' 'git commit -m "feat(api): ok" && gh pr create --title "bad"'
scope_state
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash plugins/soong/hooks/scripts/pr-guard.test.sh
```

Expected: the `commit needs a scope`, `commit must not be scoped`, and `commit shape is checked` cases FAIL as `silent` — no commit branch exists. The `unset ignores` and advise-only cases pass already, because a nonexistent branch is silent about everything.

- [ ] **Step 3: Implement the branch**

Insert **after** the PR create/edit `case` block and **before** the `is_comment_cmd` block. That position is what makes the compound-command test pass: a hook may emit only one JSON object, so the first matching branch wins, and the always-applicable PR title check should win over the new per-repo one.

```bash
# Branch 1.5: commit subjects. Gated entirely on the commits capability, so an
# unconfigured repo is untouched -- see the require_scope read at the top.
if [ -n "$require_scope" ]; then
  case "$cmd" in
    *"git commit"*)
      # Generated and reused subjects are exempt. git writes "fixup!"/"squash!"
      # itself and a later rebase absorbs them, and --amend with no -m reuses a
      # message that is not in this command. Denying either would break the
      # stacked-PR workflow develop builds.
      exempt=0
      printf '%s' "$cmd" | grep -qE -- '--(fixup|squash)(=|[[:space:]])' && exempt=1
      if printf '%s' "$cmd" | grep -qE -- '--amend' \
         && ! printf '%s' "$cmd" | grep -qE -- '(-m|--message)[[:space:]=]'; then
        exempt=1
      fi

      if [ "$exempt" -eq 0 ]; then
        # The first -m is the subject; later ones are body paragraphs.
        subject=$(printf '%s' "$cmd" \
          | grep -oE -- '(-m|--message)[ =]+("[^"]*"|'"'"'[^'"'"']*'"'"')' \
          | head -1 | sed -E 's/^(-m|--message)[ =]+//; s/^["'"'"']//; s/["'"'"']$//')

        if [ -n "$subject" ]; then
          creasons=()

          if printf '%s' "$subject" | grep -qiE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)\((\*|misc|placeholder|tbd|na|n/a)\)'; then
            creasons+=("Do not use a placeholder or wildcard scope. Got: \"$subject\"")
          elif ! printf '%s' "$subject" | grep -qE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9./-]+(,[a-z0-9./-]+)*\))?!?: .+'; then
            creasons+=("Commit subject must follow Conventional Commits, e.g. 'feat(scope): summary'. Got: \"$subject\"")
          fi

          if [ "$require_scope" = "true" ] && ! has_scope "$subject"; then
            creasons+=("This repo requires a scope on commit subjects. Write 'feat(scope): summary'. Got: \"$subject\"")
          elif [ "$require_scope" = "false" ] && has_scope "$subject"; then
            creasons+=("This repo does not use scopes on commit subjects. Write 'feat: summary'. Got: \"$subject\"")
          fi

          # No generated-by footer check here, unlike the PR branches. CLAUDE.md
          # requires a Co-Authored-By trailer on commits, so applying the PR
          # footer rule would deny what the project requires.

          if [ ${#creasons[@]} -gt 0 ]; then
            deny "$(join_reasons "${creasons[@]}") Fix the commit subject and retry."
          fi
        fi

        # ponytail: -m only, and cwd only. A message in an editor, in -F <file>,
        # or piped via a heredoc is not in the command string, so it cannot be
        # read and must not be denied unread. And the project key comes from the
        # cwd, so `git -C /other/repo commit` is judged against this repo's rule
        # rather than the target's -- working that out means parsing -C and every
        # cd in a compound command, which is a shell interpreter. Upgrade path
        # for both: a per-repo commit-msg git hook, which brings its own install,
        # upgrade, and removal problems.
        advise "Commit subjects in this repo follow Conventional Commits, and the repo's scope rule is require_scope=$require_scope."
      fi
      ;;
  esac
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash plugins/soong/hooks/scripts/pr-guard.test.sh
```

Expected: every check passes. Two failure modes to read carefully:

- `compound stops at the PR title` failing as `advise` means the branch was inserted above the PR branch instead of below it.
- `unset ignores a bad commit` failing as `advise` means the `[ -n "$require_scope" ]` gate is missing or inverted.

- [ ] **Step 5: Verify the hook still emits exactly one JSON object**

The suite's final loop already checks that every command produces either nothing or valid JSON. Confirm it covers a commit command by adding one to that loop's list, then run the suite again.

```bash
bash plugins/soong/hooks/scripts/pr-guard.test.sh
```

Expected: 0 failures, no `invalid JSON` lines.

- [ ] **Step 6: Commit**

```bash
git add plugins/soong/hooks/scripts/pr-guard.sh plugins/soong/hooks/scripts/pr-guard.test.sh
git commit -m "feat(pr-guard): check commit subjects when the repo configures commits

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Chunk 4: conflict-scout and the two gates

### Task 1: Write the conflict-scout agent

**Files:**
- Create: `plugins/soong/agents/conflict-scout.md`

No test — this is a prompt. Read `plugins/soong/agents/architect-cobrain.md` first and match its structure, heading style, and how it states its read-only constraint.

- [ ] **Step 1: Write the agent**

```markdown
---
name: conflict-scout
description: Searches the configured Notion roadmap and task databases for existing work that overlaps a proposed feature, and returns the candidates with an overlap verdict for each. Use before brainstorming a feature and again once its spec exists. Read-only - never edits files and never writes to Notion.
model: sonnet
---

# conflict-scout

Find work that already exists. You are dispatched before a feature is
brainstormed, and again once its spec exists, to answer one question: does the
roadmap already hold an item for this, or does an in-flight task touch the same
code?

You are **read-only**. Never create, update, or comment on a Notion page. Never
edit a file. Your entire output is the list below.

## Input

The dispatcher gives you:

- The feature description. On run 1 this is the user's request, often one line.
  On run 2 it is an approved spec, its pull request stack, and the files each
  pull request touches.
- The roadmap database id and the task database id.
- Which run this is.
- On run 2, the cards the user already dismissed. Never report these again.

## The sweep

Notion search is keyword-driven, so one query on the feature name finds only what
happens to share its vocabulary. The conflict that matters is usually phrased
differently and touches the same code. So run a fan of queries, not one:

1. The feature name, and its obvious synonyms.
2. The component and module names the change touches.
3. File paths and directory names. Run 2 has these. On run 1, infer what you can
   from the repository: grep for the nouns in the request and see what files come
   back.
4. Domain nouns from the description.
5. Status, as a ranking signal rather than a query: an item already in flight
   outranks one sitting in a backlog.

Query both databases. Read the promising candidates in full rather than judging
from titles, because a title is the least reliable part of a card.

**Prefer a false positive to a miss.** A missed conflict costs a duplicate
roadmap item and a wasted brainstorm. A false positive costs one question the
user answers with "proceed anyway".

## Output

Most severe first. Roadmap items before tasks. Drop anything you judge
`unrelated` rather than reporting it.

```
- Card:     <title> + URL
- Kind:     roadmap item | task
- Status:   <the card's status>
- Overlap:  direct | adjacent | shares-files
- Why:      one or two sentences, quoting the card
- Verdict:  conflicts | builds-on | unrelated
```

If you found nothing, say exactly that, in one line. That is the common case and
it has to be cheap to read.

If you found more than six candidates, return your six strongest and say the
sweep was too broad. Do not dump the rest: a long list is indistinguishable from
noise at the gate that has to act on it.

## Rules

- Never recommend abandoning or proceeding. You report; the gate that dispatched
  you asks the user. A verdict is about the cards, not about what to do next.
- Quote the card in **Why**. An overlap claim the user cannot check against the
  card's own words is not actionable.
- Say when a database returned nothing because a query failed, rather than
  reporting a clean sweep. A silent failure here reads as "no conflicts", which
  is the one wrong answer that costs the most.
```

- [ ] **Step 2: Verify the frontmatter matches the plugin's convention**

```bash
head -5 plugins/soong/agents/conflict-scout.md
grep -c "^tools:" plugins/soong/agents/conflict-scout.md
```

Expected: `name`, `description`, and `model: sonnet` present; `0` for the `tools` grep. Neither existing agent declares `tools`, and Notion MCP tool names carry a per-installation id, so a literal list would be wrong everywhere but the machine it was written on.

- [ ] **Step 3: Commit**

```bash
git add plugins/soong/agents/conflict-scout.md
git commit -m "feat(conflict-scout): add the overlap scout agent

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 2: Add Gate 1 as architect Step 1.5

**Files:**
- Modify: `plugins/soong/skills/architect/SKILL.md`

- [ ] **Step 1: Insert Step 1.5 between Step 1 and Step 2**

```markdown
## Step 1.5: Check for work that already exists

Before brainstorming. Nothing has been spent yet, so this is the cheapest place
in this skill to abandon.

Dispatch `conflict-scout` (Agent tool, `subagent_type: conflict-scout`) with the
user's request, the `roadmapDb` and `taskDb` ids from Step 1, and the fact that
this is run 1.

**Nothing found:** say so in one line and go to Step 2.

**Candidates found:** show them and ask one question with three answers. If the
scout said its sweep was too broad, say so when you present them, and ask the
same question anyway. A too-broad sweep is weak evidence, not a fourth answer.

| Answer | What you do |
| ------ | ----------- |
| **Abandon** | Stop. Print the conflicting card URLs so the user can go look at them. Write nothing, brainstorm nothing. |
| **Build on top** | Go to Step 2 carrying the conflicting cards in as context. The spec then states what it extends and what it must not duplicate, and Step 5 names those cards in the new roadmap item's body. |
| **Proceed anyway** | Go to Step 2 as if nothing was found. Record the dismissed card ids for Step 2.5. |

Ask once, with all three options visible. Do not ask three yes-or-no questions.
```

- [ ] **Step 2: Verify the step ordering reads correctly**

```bash
grep -n "^## Step" plugins/soong/skills/architect/SKILL.md
```

Expected: `Step 1`, `Step 1.5`, `Step 2`, `Step 3`, `Step 3.5`, `Step 4`, `Step 5`, `Step 6` in that order.

- [ ] **Step 3: Commit**

```bash
git add plugins/soong/skills/architect/SKILL.md
git commit -m "feat(architect): check for existing work before brainstorming

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 3: Add Gate 2 as architect Step 2.5

**Files:**
- Modify: `plugins/soong/skills/architect/SKILL.md`

- [ ] **Step 1: Insert Step 2.5 between Step 2 and Step 3**

```markdown
## Step 2.5: Re-check for existing work, now that the spec exists

After the user approves the design, before the cobrain dispatch.

Dispatch `conflict-scout` again, with the spec, the pull request stack, the files
each pull request touches, the two database ids, the fact that this is run 2, and
the card ids the user dismissed at Step 1.5. This is far better input than Step
1.5 had, so it catches overlap a one-line request could not expose.

The same three answers, with two differences:

- **Cards dismissed with "proceed anyway" at Step 1.5 are not re-asked.** Asking
  twice about the same card trains the user to dismiss by reflex. That is why the
  dismissed ids are passed in.
- **"Build on top" here revises the spec rather than restarting the brainstorm.**
  Go back into the design with the conflicting cards as context, then run this
  step again on the revised spec.

Abandoning here still costs a brainstorm. It saves the cobrain dispatch, the
two-judge council, the Step 4 walk, and the irreversible Notion writes.

### These conflicts are not Step 4 findings

Do not fold them into the Step 4 queue. "Abandon this spec" is a decision, not a
fix to apply to a spec, and the Step 3.5 council can drop a finding. A dropped
"this duplicates an in-flight roadmap item" is exactly the swallowed blocker that
Step 4's notices exist to prevent.

### The dismissed set

The dismissed card ids live in this conversation, not in a file. `architect` has
no ledger, unlike `develop`, which needs one because it resumes across sessions.

The cost is real and worth stating: if this conversation is compacted between
Step 1.5 and Step 2.5, the set is lost and this step re-asks about a card the
user already dismissed. That is one redundant question in a rare case, against a
persistent store in every case.

Record page ids, not titles. Titles are editable and can collide.
```

- [ ] **Step 2: Name the extended cards in Step 5**

In Step 5, under **On the roadmap item**, add a bullet:

```markdown
- When the user chose "build on top" at Step 1.5 or Step 2.5, the cards this work
  extends, by title and URL, and what this item does not duplicate.
```

- [ ] **Step 3: Verify the step ordering**

```bash
grep -n "^## Step" plugins/soong/skills/architect/SKILL.md
```

Expected: `Step 1`, `Step 1.5`, `Step 2`, `Step 2.5`, `Step 3`, `Step 3.5`, `Step 4`, `Step 5`, `Step 6`.

- [ ] **Step 4: Commit**

```bash
git add plugins/soong/skills/architect/SKILL.md
git commit -m "feat(architect): re-check for existing work once the spec exists

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Chunk 5: verify and version

### Task 1: Run everything and bump the version

**Files:**
- Modify: `plugins/soong/.claude-plugin/plugin.json`

- [ ] **Step 1: Run both test suites from the worktree root**

```bash
bash plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh
bash plugins/soong/hooks/scripts/pr-guard.test.sh
```

Expected: both print `0 failed` (or all `ok -` lines) and exit 0. Do not continue on a failure; fix it and re-run.

- [ ] **Step 2: Confirm no stale references survive in the plugin**

```bash
grep -rn "architect-setup\|architect\.json" plugins/ README.md
```

Expected: exactly one hit — the `legacy=` line and its comment in `soong-setup.sh`, which is the deliberate fallback. Any other hit is a miss; fix it.

- [ ] **Step 3: Confirm the guard is inert in this repo**

This repo is not configured for `commits`, so the commit branch must stay silent here.

```bash
printf 'git commit -m "wip"' | jq -Rs '{tool_input:{command:.}}' \
  | bash plugins/soong/hooks/scripts/pr-guard.sh
```

Expected: no output. Any output means the capability gate is not working, and every unconfigured repo on the user's machine would start getting commit denials.

- [ ] **Step 4: Bump the version**

In `plugins/soong/.claude-plugin/plugin.json`, change `"version": "0.10.1"` to `"version": "0.11.0"`. Features bump the minor, per `CLAUDE.md`.

- [ ] **Step 5: Verify the JSON still parses**

```bash
jq -e '.version' plugins/soong/.claude-plugin/plugin.json
```

Expected: `"0.11.0"`.

- [ ] **Step 6: Commit**

```bash
git add plugins/soong/.claude-plugin/plugin.json
git commit -m "chore(plugin): bump version to 0.11.0

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 2: Hand off

- [ ] **Step 1: Review the full diff against the spec**

```bash
git diff main...HEAD --stat
```

Read the spec's "Files" table alongside this. Every row should appear, and nothing should appear that the table does not list.

- [ ] **Step 2: Report what the release note has to say**

The rename is user-visible: `/architect-setup` no longer exists and `/soong-setup` replaces it. There is no alias. Say so when the pull request is opened — a minor bump alone understates it.

---

## Notes for the implementer

**What this plan does not do, deliberately:**

- No `commit-msg` git hook. The `PreToolUse` hook cannot read a message in an editor, a `-F` file, or a heredoc, and those advise rather than deny. The upgrade path is named in a `ponytail:` comment in the code.
- No stored setup version number. The capability table computes what is missing.
- No backfill of `requireScope` for already-configured repos. Absent means not enforced, so existing repos behave exactly as they do today until their owner answers the question.
- No conflict gate in `develop`. It implements a roadmap item that already exists.

**If a test fights you,** read the spec section it covers before changing the test. The scope rule's three states and the commit branch's capability gate are both there to bound blast radius, and a test that looks wrong is more likely to be protecting one of those than to be a bad test.
