# PR Review Queue Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/review-pr-queue` (a cheap, cross-repo ranked list of pull requests awaiting the user's review) and `/review-pr` (a repo-local in-depth review that filters findings through the adversarial council), plus the two reviewer agents and the council parameterisation they need.

**Architecture:** Follows this repo's established split — deterministic logic lives in a bash script with a real `.test.sh` suite next to it, and the SKILL.md is prose that calls the script and interprets its JSON. `review-pr-queue` gets `queue.sh` (fetch, score, classify). `review-pr` gets `guard.sh` (the adjacency stop) and `surface.sh` (the change surface). Everything genuinely testable is in the scripts; the judgment calls stay in prose. The council gains three arguments whose defaults preserve today's behaviour, so `/architect` is untouched behaviourally.

**Tech Stack:** Bash, `gh` CLI, `jq`, Markdown skills and agents. Tests are `bash *.test.sh` in the pattern of `plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh`.

**Spec:** `docs/superpowers/specs/2026-09-07-pr-review-queue-design.md`

---

## Thresholds this plan fixes

The spec deliberately left the scoring numbers open — it says the score is never shown, so no user-facing behaviour depends on the exact values. A testable script needs concrete ones. These are the plan's choices, and Task 2's tests encode them:

| Knob | Value | Reason |
| --- | --- | --- |
| Low churn | weighted churn `<= 50` | Above this a diff stops being skimmable. |
| Sensitive-path weight | 500 per matched path | Outranks the churn score at any realistic size, so a 4-line migration beats a 500-line safe diff. |
| Churn points | `log(weighted churn) * 40` | Logarithmic, so churn alone can never overtake a sensitive path. |
| Blast-radius weight | 25 per distinct top-level dir | Meaningful, never enough to outrank a sensitive path. |
| Low-signal discount | churn scaled by `1 - lowsignal_fraction` | An all-snapshot PR weighs 0; a half-test PR weighs half. |

Score is `log(weighted_churn)*40 + 500*sensitive_hits + 25*top_level_dirs`, used only for ordering.

**These weights were verified against the Task 2 test cases before this plan was written.** A linear churn term was tried first and rejected: it let a 500-line safe diff outrank a 4-line migration, inverting the ranking the spec calls for. If you change a weight, re-run the Task 2 suite — the ordering assertions are what pin these values.

**Sensitive globs (high):** `**/auth/**`, `**/*auth*`, `**/migrations/**`, `**/migrate/**`, `**/payment*/**`, `**/billing/**`, `.github/workflows/**`, `**/Dockerfile*`, `**/*.lock`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `go.sum`, `Cargo.lock`, `poetry.lock`, `requirements*.txt`, `**/secrets*`, `**/crypto/**`.

**Low-signal globs:** `**/test/**`, `**/tests/**`, `**/*_test.*`, `**/*.test.*`, `**/*.spec.*`, `**/__snapshots__/**`, `**/fixtures/**`, `**/docs/**`, `**/*.md`.

---

## File Structure

**New:**

| Path | Responsibility |
| --- | --- |
| `plugins/soong/skills/review-pr-queue/SKILL.md` | Prose: run `queue.sh`, write descriptions, render the table. |
| `plugins/soong/skills/review-pr-queue/scripts/queue.sh` | Fetch queue, score, classify. Emits JSON. |
| `plugins/soong/skills/review-pr-queue/scripts/queue.test.sh` | Suite for the above. |
| `plugins/soong/skills/review-pr/SKILL.md` | Prose: guard, gather, dispatch, council, report. |
| `plugins/soong/skills/review-pr/scripts/guard.sh` | The Step 0 adjacency stop. Emits JSON. |
| `plugins/soong/skills/review-pr/scripts/guard.test.sh` | Suite for the above. |
| `plugins/soong/skills/review-pr/scripts/surface.sh` | Derive the change surface from a diff. Emits JSON. |
| `plugins/soong/skills/review-pr/scripts/surface.test.sh` | Suite for the above. |
| `plugins/soong/agents/pr-reviewer-correctness.md` | Correctness findings from a diff. |
| `plugins/soong/agents/pr-reviewer-design.md` | Contract and structure findings from a diff. |

**Modified:**

| Path | Change |
| --- | --- |
| `plugins/soong/agents/adversarial-judge.md` | Add the integration lens; make the verifier lens mode-aware. |
| `plugins/soong/skills/adversarial-council/SKILL.md` | Three arguments; PR-mode inputs, cap, verdict degradation, report-not-walk. |
| `plugins/soong/skills/architect/SKILL.md` | Step 3.5 passes `--mode spec`. |
| `plugins/soong/.claude-plugin/plugin.json` | `0.15.0` → `0.16.0`. |
| `README.md` | Add `gh` under Requirements. |

**Task order rationale:** scripts before the prose that calls them; the shared-file edits (Tasks 9-11) before `review-pr`, which depends on PR mode existing; the version bump last so it lands once.

**Commit subjects carry no scope.** This repo's `conventional-commit-guard` hook is configured with `require_scope=false` and rejects a scoped subject, so every commit command below is written unscoped.

---

## Chunk 1: review-pr-queue

### Task 1: Scaffold `queue.sh` with its `gh` preflight

**Files:**
- Create: `plugins/soong/skills/review-pr-queue/scripts/queue.sh`
- Test: `plugins/soong/skills/review-pr-queue/scripts/queue.test.sh`

The script must be testable without hitting GitHub. It calls `gh` directly, and the tests substitute a fake `gh` by prepending a temp directory to `PATH`. No indirection in the script itself — the seam is `PATH`, which is also how `soong-setup.test.sh` isolates its environment.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Self-check for queue.sh. Run: bash queue.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/queue.sh"
tmp="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin"

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}

# fake_gh <<'JSON' installs a gh stub that replays canned output per subcommand.
fake_gh() { cat > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"; }

# gh missing entirely: PATH without gh at all
fake_gh <<'SH'
#!/usr/bin/env bash
exit 127
SH
check "gh unusable exits 2" 2 "$(bash "$script" >/dev/null 2>&1; echo $?)"

fake_gh <<'SH'
#!/usr/bin/env bash
case "$1" in
  auth) exit 1 ;;
  *) exit 0 ;;
esac
SH
check "gh unauthenticated exits 2" 2 "$(bash "$script" >/dev/null 2>&1; echo $?)"
out="$(bash "$script" 2>&1 >/dev/null)"
case "$out" in *"gh auth login"*) r=yes ;; *) r=no ;; esac
check "unauthenticated names the fix" yes "$r"

[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash plugins/soong/skills/review-pr-queue/scripts/queue.test.sh`
Expected: FAIL — `queue.sh` does not exist, so every check reports the wrong exit code.

- [ ] **Step 3: Implement the minimal code to make the test pass**

```bash
#!/usr/bin/env bash
# Rank the pull requests awaiting the user's review. Metadata only, never a diff.
# Emits JSON: {"prs":[{url,title,body,churn,score,classification,files,...}]}
set -uo pipefail

die() { echo "$1" >&2; exit "${2:-1}"; }

command -v gh >/dev/null 2>&1 \
  || die "gh is not installed. Install the GitHub CLI, then re-run." 2
gh auth status >/dev/null 2>&1 \
  || die "gh is not authenticated. Run: gh auth login" 2

printf '{"prs":[]}\n'
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bash plugins/soong/skills/review-pr-queue/scripts/queue.test.sh`
Expected: `all checks passed`

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/review-pr-queue/scripts/
git commit -m "feat: add queue.sh with a gh preflight"
```

---

### Task 2: Scoring and classification

**Files:**
- Modify: `plugins/soong/skills/review-pr-queue/scripts/queue.sh`
- Modify: `plugins/soong/skills/review-pr-queue/scripts/queue.test.sh`

Score and classify are pure functions of one PR's metadata, so they are tested directly through a hidden `--score-one` entry point that reads a PR JSON object on stdin. That keeps the tests free of `gh` entirely.

- [ ] **Step 1: Write the failing tests**

Append to `queue.test.sh`, before the tally:

```bash
# --- scoring and classification -------------------------------------------
# Task 1 left an UNAUTHENTICATED stub installed. queue.sh runs its gh preflight
# before the --score-one early exit, so without a healthy stub here every
# scoring call below dies at exit 2 and returns an empty string. Install one.
fake_gh <<'SH'
#!/usr/bin/env bash
exit 0
SH

# score_one <json> -> "<score> <classification>"
score_one() { printf '%s' "$1" | bash "$script" --score-one; }

tiny='{"url":"u","additions":3,"deletions":1,"changedFiles":1,
  "files":[{"path":"src/copy.ts"}],"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "tiny safe green PR is Review now" "Review now" "$(score_one "$tiny" | cut -d' ' -f2-)"

big='{"url":"u","additions":400,"deletions":100,"changedFiles":20,
  "files":[{"path":"src/a.ts"},{"path":"lib/b.ts"}],"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "large safe PR requires thinking" "Requires thinking" "$(score_one "$big" | cut -d' ' -f2-)"

mig='{"url":"u","additions":4,"deletions":0,"changedFiles":1,
  "files":[{"path":"db/migrations/001_add.sql"}],"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "tiny migration requires thinking" "Requires thinking" "$(score_one "$mig" | cut -d' ' -f2-)"

red='{"url":"u","additions":3,"deletions":0,"changedFiles":1,
  "files":[{"path":"src/copy.ts"}],"statusCheckRollup":[{"conclusion":"FAILURE"}]}'
check "red CI requires thinking" "Requires thinking" "$(score_one "$red" | cut -d' ' -f2-)"

# A sensitive path must outrank a much larger safe diff.
s_mig="$(score_one "$mig" | cut -d' ' -f1)"
s_big="$(score_one "$big" | cut -d' ' -f1)"
# Default to 0 so an empty score is a visible failure, not a misleading "no".
check "sensitive outranks large-and-safe" yes \
  "$([ "${s_mig:-0}" -gt "${s_big:-0}" ] && echo yes || echo no)"

# Test-only churn is discounted, so it stays Review now.
snap='{"url":"u","additions":300,"deletions":0,"changedFiles":2,
  "files":[{"path":"src/__snapshots__/a.snap"},{"path":"tests/a.test.ts"}],
  "statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "all-lowsignal churn stays Review now" "Review now" "$(score_one "$snap" | cut -d' ' -f2-)"

# Half test, half real: the real half still counts.
mixed='{"url":"u","additions":200,"deletions":0,"changedFiles":2,
  "files":[{"path":"src/big.ts"},{"path":"tests/a.test.ts"}],
  "statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "mixed churn requires thinking" "Requires thinking" "$(score_one "$mixed" | cut -d' ' -f2-)"

# No CI at all is not green.
noci='{"url":"u","additions":3,"deletions":0,"changedFiles":1,
  "files":[{"path":"src/copy.ts"}],"statusCheckRollup":[]}'
check "absent CI requires thinking" "Requires thinking" "$(score_one "$noci" | cut -d' ' -f2-)"
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `bash plugins/soong/skills/review-pr-queue/scripts/queue.test.sh`
Expected: all eight new checks FAIL — `--score-one` is not implemented, so each returns empty.

- [ ] **Step 3: Implement the minimal code to make the tests pass**

Insert before the final `printf` in `queue.sh`:

```bash
command -v jq >/dev/null 2>&1 || die "jq is not installed." 2

# Sensitive paths, in three idioms. Add to the fragment that matches your
# intent - mixing them up is how a path silently stops matching.
#   DIRS  - a whole path segment:      src/auth/x.ts, but never src/oauthly.ts
#   NAMES - a substring of a filename: src/oauth.ts, secrets.tf, payment-intent.ts
#   LOCKS - a suffix or exact filename
SENS_DIRS='(^|/)(auth|crypto|migrations?|migrate|payments?|billing|secrets?)(/|$)'
SENS_NAMES='(^|/)[^/]*(auth|secret|payment|billing)[^/]*$'
SENS_LOCKS='\.lock$|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|go\.sum|requirements[^/]*\.txt)$'
SENSITIVE="$SENS_DIRS|$SENS_NAMES|^\.github/workflows/|(^|/)Dockerfile|$SENS_LOCKS"

LOWSIGNAL='(^|/)(tests?|docs|fixtures|__snapshots__)/|[._-]test\.|[._-]spec\.|\.md$|\.snap$'

# Reads one PR JSON object on stdin, prints "<score> <classification>".
score_one() {
  jq -r --arg sens "$SENSITIVE" --arg low "$LOWSIGNAL" '
    def paths_: [.files[]?.path // empty];
    def sensitive_: [paths_[] | select(test($sens))] | length;
    def lowsig_: [paths_[] | select(test($low))] | length;
    def alldirs_: [paths_[] | split("/")[0]] | unique | length;
    (.additions // 0) + (.deletions // 0)                      as $churn
    | (paths_ | length)                                        as $n
    | (if $n > 0 then (lowsig_ / $n) else 0 end)               as $lowfrac
    | ($churn * (1 - $lowfrac) | floor)                        as $wchurn
    | sensitive_                                               as $sens_hits
    | ([.statusCheckRollup[]? | select(.conclusion != null)])  as $checks
    | (($checks | length) > 0
       and all($checks[]; .conclusion == "SUCCESS" or .conclusion == "SKIPPED"))
                                                               as $green
    | (if $wchurn > 0 then (($wchurn | log) * 40) else 0 end)  as $churn_pts
    | (($churn_pts + 500 * $sens_hits + 25 * alldirs_) | floor) as $score
    | (if $sens_hits == 0 and $green and $wchurn <= 50
       then "Review now" else "Requires thinking" end)         as $class
    | "\($score) \($class)"
  '
}

if [ "${1:-}" = "--score-one" ]; then score_one; exit 0; fi
```

Two details that matter:

- `SKIPPED` counts as green. A skipped check is not a failure, and treating it
  as one would mark most pull requests `Requires thinking`.
- Churn is logarithmic and the sensitive weight is 500. That is what makes a
  4-line migration outrank a 500-line safe refactor. A linear churn term fails
  the "sensitive outranks large-and-safe" assertion above.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bash plugins/soong/skills/review-pr-queue/scripts/queue.test.sh`
Expected: `all checks passed`

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/review-pr-queue/scripts/
git commit -m "feat: score and classify pull requests"
```

---

### Task 3: Fetch the queue and assemble the JSON

**Files:**
- Modify: `plugins/soong/skills/review-pr-queue/scripts/queue.sh`
- Modify: `plugins/soong/skills/review-pr-queue/scripts/queue.test.sh`

- [ ] **Step 1: Write the failing tests**

Append to `queue.test.sh`, before the tally:

```bash
# --- fetching -------------------------------------------------------------
# A gh stub: `search prs` lists two PRs, `pr view` returns per-PR metadata,
# and one PR is unreadable so the row-level failure path is covered.
fake_gh <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "search prs")
    cat <<'J'
[{"url":"https://github.com/o/r/pull/1"},{"url":"https://github.com/o/r/pull/2"},
 {"url":"https://github.com/o/r/pull/3"}]
J
    ;;
  "pr view")
    case "$3" in
      *"/pull/1")
        echo '{"url":"https://github.com/o/r/pull/1","title":"fix: copy","body":"",
          "additions":2,"deletions":1,"changedFiles":1,"files":[{"path":"src/c.ts"}],
          "statusCheckRollup":[{"conclusion":"SUCCESS"}],"isDraft":false,
          "reviewDecision":"","updatedAt":"2026-09-01T00:00:00Z",
          "author":{"login":"a"}}' ;;
      *"/pull/2")
        echo '{"url":"https://github.com/o/r/pull/2","title":"feat: auth","body":"",
          "additions":10,"deletions":2,"changedFiles":2,
          "files":[{"path":"src/auth/token.ts"}],
          "statusCheckRollup":[{"conclusion":"SUCCESS"}],"isDraft":false,
          "reviewDecision":"","updatedAt":"2026-09-02T00:00:00Z",
          "author":{"login":"b"}}' ;;
      *"/pull/3") exit 1 ;;
    esac ;;
esac
SH

out="$(bash "$script")"
check "emits a row per PR" 3 "$(printf '%s' "$out" | jq '.prs | length')"
check "sensitive PR sorts first" "https://github.com/o/r/pull/2" \
  "$(printf '%s' "$out" | jq -r '.prs[0].url')"
check "unreadable PR is kept" 1 \
  "$(printf '%s' "$out" | jq '[.prs[] | select(.unreadable == true)] | length')"
check "unreadable PR keeps its url" "https://github.com/o/r/pull/3" \
  "$(printf '%s' "$out" | jq -r '.prs[] | select(.unreadable == true) | .url')"
check "readable rows carry a classification" 2 \
  "$(printf '%s' "$out" | jq '[.prs[] | select(.classification != null)] | length')"

# Empty queue.
fake_gh <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "search prs") echo '[]' ;;
esac
SH
check "empty queue exits 0" 0 "$(bash "$script" >/dev/null 2>&1; echo $?)"
check "empty queue emits no rows" 0 "$(bash "$script" | jq '.prs | length')"

# Drafts are excluded unless asked for.
fake_gh <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "search prs") echo '[{"url":"https://github.com/o/r/pull/9"}]' ;;
  "pr view")
    echo '{"url":"https://github.com/o/r/pull/9","title":"wip","body":"",
      "additions":1,"deletions":0,"changedFiles":1,"files":[{"path":"a.ts"}],
      "statusCheckRollup":[{"conclusion":"SUCCESS"}],"isDraft":true,
      "reviewDecision":"","updatedAt":"2026-09-03T00:00:00Z",
      "author":{"login":"c"}}' ;;
esac
SH
check "drafts excluded by default" 0 "$(bash "$script" | jq '.prs | length')"
check "drafts included on request" 1 \
  "$(bash "$script" --include-drafts | jq '.prs | length')"

# --- regressions the checks above do not pin -------------------------------
# A sensitive FILENAME, not just a sensitive directory. The plan's glob list
# includes **/secrets* and **/payment*/**, and a whole-segment-only regex
# silently misses secrets.tf and payment-intent.ts.
for f in secrets.tf src/payment-intent.ts src/oauth.ts; do
  check "sensitive filename $f is not Review now" "Requires thinking" \
    "$(score_one "$(printf '{"additions":4,"deletions":0,
       \"files\":[{\"path\":\"%s\"}],
       \"statusCheckRollup\":[{\"conclusion\":\"SUCCESS\"}]}' "$f")" | cut -d' ' -f2-)"
done

# SKIPPED is green. Treating it as a failure would mark most PRs as needing
# thought, which is the classification this tool exists to keep meaningful.
skip='{"additions":3,"deletions":0,"changedFiles":1,
  "files":[{"path":"src/c.ts"}],
  "statusCheckRollup":[{"conclusion":"SKIPPED"},{"conclusion":"SUCCESS"}]}'
check "SKIPPED counts as green" "Review now" "$(score_one "$skip" | cut -d' ' -f2-)"

# Blast radius contributes: same churn, more top-level directories, higher score.
one='{"additions":40,"deletions":0,"files":[{"path":"a/x.ts"},{"path":"a/y.ts"}],
  "statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
two='{"additions":40,"deletions":0,"files":[{"path":"a/x.ts"},{"path":"b/y.ts"}],
  "statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
check "blast radius raises the score" yes \
  "$([ "$(score_one "$two" | cut -d' ' -f1)" -gt "$(score_one "$one" | cut -d' ' -f1)" ] \
     && echo yes || echo no)"

# A gh that exits 0 with garbage must not make a pull request disappear.
fake_gh <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "search prs") echo '[{"url":"https://github.com/o/r/pull/1"}]' ;;
  "pr view") echo 'gh: this is not json'; exit 0 ;;
esac
SH
out="$(bash "$script")"
check "non-JSON gh output keeps the row" 1 "$(printf '%s' "$out" | jq '.prs | length')"
check "non-JSON gh output marks it unreadable" true \
  "$(printf '%s' "$out" | jq -r '.prs[0].unreadable')"

# Unreadable rows sort last, which Task 4's SKILL.md relies on.
fake_gh <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "search prs") echo '[{"url":"https://github.com/o/r/pull/1"},{"url":"https://github.com/o/r/pull/2"}]' ;;
  "pr view")
    case "$3" in
      *"/pull/1") exit 1 ;;
      *"/pull/2")
        echo '{"url":"https://github.com/o/r/pull/2","title":"t","body":"",
          "additions":2,"deletions":0,"changedFiles":1,"files":[{"path":"src/c.ts"}],
          "statusCheckRollup":[{"conclusion":"SUCCESS"}],"isDraft":false,
          "reviewDecision":"","updatedAt":"2026-09-01T00:00:00Z",
          "author":{"login":"a"}}' ;;
    esac ;;
esac
SH
check "unreadable rows sort last" true \
  "$(bash "$script" | jq -r '.prs[-1].unreadable')"
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `bash plugins/soong/skills/review-pr-queue/scripts/queue.test.sh`
Expected: **6 of the 9** new checks FAIL — the script still prints `{"prs":[]}`. The 11 existing checks still pass.

Three of the nine pass vacuously against the stub, because they assert an absence the stub also satisfies: `empty queue exits 0`, `empty queue emits no rows`, and `drafts excluded by default`. That last one can only fail if drafts leak, so on its own it does not prove the filter fires — its partner `drafts included on request` is the half that does, and it is among the six. Keep all nine: together they pin the behaviour, and a check that cannot fail today still guards a regression tomorrow.

- [ ] **Step 3: Implement the minimal code to make the tests pass**

Replace the final `printf '{"prs":[]}\n'` with:

```bash
include_drafts=0
[ "${1:-}" = "--include-drafts" ] && include_drafts=1

FIELDS='url,title,body,additions,deletions,changedFiles,files,statusCheckRollup,reviewDecision,isDraft,updatedAt,author'

urls="$(gh search prs --review-requested=@me --state=open --json url \
        --limit 100 2>/dev/null | jq -r '.[].url')" \
  || die "could not search for review requests." 1

rows=""
while IFS= read -r url; do
  [ -n "$url" ] || continue
  # Exit 0 with non-JSON output must land here too, not silently drop the row:
  # --argjson score "" is a hard jq failure, and without -e nothing notices.
  if ! meta="$(gh pr view "$url" --json "$FIELDS" 2>/dev/null)" \
     || ! printf '%s' "$meta" | jq -e . >/dev/null 2>&1; then
    # One unreadable pull request must not kill the queue.
    rows="$rows$(jq -cn --arg u "$url" '{url:$u, unreadable:true}')
"
    continue
  fi
  if [ "$include_drafts" -eq 0 ] \
     && [ "$(printf '%s' "$meta" | jq -r '.isDraft')" = "true" ]; then
    continue
  fi
  sc="$(printf '%s' "$meta" | score_one)"
  # Both expansions below return the whole string when it holds no space, which
  # would put the score in the classification. Treat a degraded score as
  # unreadable rather than emitting a numeric classification.
  case "$sc" in
    [0-9]*" "*) : ;;
    *) rows="$rows$(jq -cn --arg u "$url" '{url:$u, unreadable:true}')
"
       continue ;;
  esac
  rows="$rows$(printf '%s' "$meta" | jq -c \
      --argjson score "${sc%% *}" --arg class "${sc#* }" \
      '{url, title, body, files: [.files[]?.path], churn: ((.additions//0)+(.deletions//0)),
        isDraft, reviewDecision, updatedAt, author: .author.login,
        score: $score, classification: $class, unreadable: false}')
"
done <<EOF
$urls
EOF

# Unreadable rows sort last: no score to rank them by.
printf '%s' "$rows" | jq -s '{prs: (sort_by(.unreadable, -(.score // 0)))}'
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bash plugins/soong/skills/review-pr-queue/scripts/queue.test.sh`
Expected: `all checks passed`

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/review-pr-queue/scripts/
git commit -m "feat: fetch the review queue and emit ranked JSON"
```

---

### Task 4: `review-pr-queue/SKILL.md`

**Files:**
- Create: `plugins/soong/skills/review-pr-queue/SKILL.md`

No test: this is prose the model follows. Its verification is Testing step 1 in the spec.

- [ ] **Step 1: Write the skill**

```markdown
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
```

- [ ] **Step 2: Verify the frontmatter parses and the script path resolves**

Run:

```bash
awk '/^---$/{n++; next} n==1' plugins/soong/skills/review-pr-queue/SKILL.md | cut -c1-50
ls plugins/soong/skills/review-pr-queue/scripts/queue.sh
```

Expected: the frontmatter fields, starting `name: review-pr-queue`, and the script path listed. The `awk` prints only what is between the `---` markers, so an unterminated block prints nothing.

- [ ] **Step 3: Commit**

```bash
git add plugins/soong/skills/review-pr-queue/SKILL.md
git commit -m "feat: add the skill"
```

---

## Chunk 2: review-pr scripts

### Task 5: The adjacency guard

**Files:**
- Create: `plugins/soong/skills/review-pr/scripts/guard.sh`
- Test: `plugins/soong/skills/review-pr/scripts/guard.test.sh`

The guard is the safety-critical part of this feature, so it is tested hardest. It must stop on a mismatch **and** on an unresolvable workspace — an unresolvable workspace is a check that did not run, not a check that passed.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bash
# Self-check for guard.sh. Run: bash guard.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/guard.sh"
tmp="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin"

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
# fake_gh <pr-upstream-repo> <workspace-repo-or-FAIL> [head-repo]
# `pr view` returns the canonical upstream url, plus a SEPARATE head repo so a
# fork pull request can be simulated. Feeding both arms the same value is what
# let the fork bug through: a suite that cannot distinguish head from upstream
# cannot catch a script that reads the wrong one.
# The `repo view` arm honours -q, because the script calls gh that way and a
# stub that ignores it would return raw JSON where real gh returns a value.
fake_gh() {
  cat > "$tmp/bin/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr view")     echo '{"url":"https://github.com/$1/pull/7","number":7,
                        "headRepository":{"nameWithOwner":"${3:-$1}"}}' ;;
  "repo view")
    [ "$2" = FAIL ] && exit 1
    for a in "\$@"; do [ "\$a" = "-q" ] && { echo "$2"; exit 0; }; done
    echo '{"nameWithOwner":"$2"}' ;;
esac
SH
  chmod +x "$tmp/bin/gh"
}
url=https://github.com/o/r/pull/7

fake_gh o/r o/r
check "match exits 0" 0 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
check "match reports ok" true "$(bash "$script" "$url" | jq -r '.ok')"
check "match echoes the repo" o/r "$(bash "$script" "$url" | jq -r '.repo')"
check "match echoes the number" 7 "$(bash "$script" "$url" | jq -r '.number')"

fake_gh o/r other/repo
check "mismatch exits 3" 3 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
msg="$(bash "$script" "$url" 2>&1 >/dev/null)"
case "$msg" in *o/r*) a=yes ;; *) a=no ;; esac
case "$msg" in *other/repo*) b=yes ;; *) b=no ;; esac
check "mismatch names the PR repo" yes "$a"
check "mismatch names the workspace repo" yes "$b"

# An unresolvable workspace must stop, never pass.
fake_gh o/r FAIL
check "unresolvable workspace exits 3" 3 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
msg="$(bash "$script" "$url" 2>&1 >/dev/null)"
case "$msg" in *"could not"*|*"cannot"*) c=yes ;; *) c=no ;; esac
check "unresolvable workspace says so" yes "$c"

# Case-insensitive: GitHub owners and repos are not case-sensitive.
fake_gh O/R o/r
check "case difference still matches" 0 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"

check "missing argument exits 2" 2 "$(bash "$script" >/dev/null 2>&1; echo $?)"

# A fork pull request, reviewed from the correct UPSTREAM checkout, must pass.
# headRepository is the fork here; only the url names the upstream.
fake_gh o/r o/r contributor/r-fork
check "fork PR from the upstream checkout exits 0" 0 \
  "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
check "fork PR reports the upstream repo" o/r "$(bash "$script" "$url" | jq -r '.repo')"

# And the fork checkout itself is still the wrong place to review it.
fake_gh o/r contributor/r-fork contributor/r-fork
check "fork PR from the fork checkout exits 3" 3 \
  "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"

# A pull request with no resolvable number must not report success: exit 0
# means proceed, and the caller branches on this JSON.
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view")     echo '{"url":"https://github.com/o/r/pull/7"}' ;;
  "repo view")   for a in "$@"; do [ "$a" = "-q" ] && { echo "o/r"; exit 0; }; done ;;
esac
SH
chmod +x "$tmp/bin/gh"
check "absent PR number exits 2" 2 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"

# The environment preflights must exit 2, never 0. Every other check installs a
# healthy stub, so without these a mutation turning a preflight into exit 0 is
# invisible - the one direction this guard must never fail in.
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
exit 127
SH
chmod +x "$tmp/bin/gh"
check "gh unusable exits 2" 2 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"

cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in auth) exit 1 ;; *) exit 0 ;; esac
SH
chmod +x "$tmp/bin/gh"
check "gh unauthenticated exits 2" 2 "$(bash "$script" "$url" >/dev/null 2>&1; echo $?)"
out="$(bash "$script" "$url" 2>&1 >/dev/null)"
case "$out" in *"gh auth login"*) r=yes ;; *) r=no ;; esac
check "unauthenticated names the fix" yes "$r"

[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `bash plugins/soong/skills/review-pr/scripts/guard.test.sh`
Expected: FAIL — `guard.sh` does not exist.

- [ ] **Step 3: Implement the minimal code to make the tests pass**

```bash
#!/usr/bin/env bash
# The review-pr adjacency guard. Confirms the workspace IS the pull request's
# repository. Exits 3 when it is not, or when the workspace cannot be resolved.
# Emits JSON on success: {"ok":true,"repo":"<owner/name>","number":<n>}
set -uo pipefail

die() { echo "$1" >&2; exit "${2:-1}"; }

target="${1:-}"
[ -n "$target" ] || die "usage: guard.sh <pull-request-url-or-number>" 2

command -v gh >/dev/null 2>&1 \
  || die "gh is not installed. Install the GitHub CLI, then re-run." 2
command -v jq >/dev/null 2>&1 || die "jq is not installed." 2
gh auth status >/dev/null 2>&1 \
  || die "gh is not authenticated. Run: gh auth login" 2

# Ask for the url, not headRepository: on a pull request opened from a fork,
# headRepository is the FORK. A reviewer sitting in the correct upstream
# checkout would be refused, and told to go check out the contributor's fork -
# which would put the wrong code on disk, the opposite of this guard's purpose.
# The url is the canonical upstream location for fork and same-repo alike.
# (gh pr view has no baseRepository field; asking for one is an error.)
if ! pr="$(gh pr view "$target" --json url,number 2>/dev/null)" \
   || ! printf '%s' "$pr" | jq -e . >/dev/null 2>&1; then
  die "cannot read $target. It may not exist, or you may not have access." 2
fi

pr_repo="$(printf '%s' "$pr" \
  | jq -r '(.url | capture("//[^/]+/(?<r>[^/]+/[^/]+)/pull/").r) // empty' 2>/dev/null)"
[ -n "$pr_repo" ] || die "could not resolve the pull request's repository." 2

# Guard the number too: exit 0 means "proceed", and the skill branches on this
# JSON, so a null number would surface later as a confusing gh pr diff failure.
number="$(printf '%s' "$pr" | jq -r '.number // empty')"
[ -n "$number" ] || die "could not resolve the pull request's number." 2

# An unresolvable workspace is a check that did not run, not one that passed.
ws_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
  || ws_repo=""
[ -n "$ws_repo" ] || die "could not resolve this workspace's repository (no origin, or a local-only checkout). The pull request belongs to $pr_repo. Nothing was reviewed." 3

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
if [ "$(lower "$pr_repo")" != "$(lower "$ws_repo")" ]; then
  die "this workspace is $ws_repo, but the pull request belongs to $pr_repo. Nothing was reviewed. Open a checkout of $pr_repo and run the skill there." 3
fi

jq -cn --arg r "$pr_repo" --argjson n "$number" '{ok:true, repo:$r, number:$n}'
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bash plugins/soong/skills/review-pr/scripts/guard.test.sh`
Expected: `all checks passed`

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/review-pr/scripts/
git commit -m "feat: add the adjacency guard"
```

---

### Task 6: The change surface

**Files:**
- Create: `plugins/soong/skills/review-pr/scripts/surface.sh`
- Test: `plugins/soong/skills/review-pr/scripts/surface.test.sh`

Reads a unified diff on stdin, emits the change surface as JSON. The spec's inclusion test — *can code outside the changed file depend on this name?* — is a judgment the model applies; the script does the mechanical extraction that judgment needs, and always emits changed paths.

Scope note: the script extracts **candidates** and labels each with the kind it matched. The model prunes them against the inclusion test. This split is deliberate — a regex cannot decide reachability in every language, and pretending otherwise would make the script silently wrong rather than usefully incomplete.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bash
# Self-check for surface.sh. Run: bash surface.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/surface.sh"
fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}

diff1='diff --git a/src/api.ts b/src/api.ts
--- a/src/api.ts
+++ b/src/api.ts
@@ -1,4 +1,4 @@
-export function handle(id: string) {
+export function handle(id: string, opts?: Opts) {
   const local = 1;
-  const removedLocal = 2;
+  const renamedLocal = 2;
   return id;
 }'

out="$(printf '%s' "$diff1" | bash "$script")"
check "emits the changed path" "src/api.ts" "$(printf '%s' "$out" | jq -r '.paths[0]')"
check "captures the altered signature" 1 \
  "$(printf '%s' "$out" | jq '[.entries[] | select(.name == "handle")] | length')"
check "signature marked altered" altered \
  "$(printf '%s' "$out" | jq -r '.entries[] | select(.name=="handle") | .change')"
check "keeps the before signature" yes \
  "$(printf '%s' "$out" | jq -r '.entries[] | select(.name=="handle") | .before' \
     | grep -q 'id: string)' && echo yes || echo no)"
check "keeps the after signature" yes \
  "$(printf '%s' "$out" | jq -r '.entries[] | select(.name=="handle") | .after' \
     | grep -q 'opts?: Opts' && echo yes || echo no)"
check "local variables are not entries" 0 \
  "$(printf '%s' "$out" | jq '[.entries[] | select(.name | test("Local"))] | length')"

# A route registration and a config key live inside bodies but are reachable.
diff2='diff --git a/src/server.py b/src/server.py
--- a/src/server.py
+++ b/src/server.py
@@ -1,3 +1,4 @@
+app.route("/api/v2/users")
+TIMEOUT = os.environ["REQUEST_TIMEOUT_MS"]
 def helper():
     pass'

out2="$(printf '%s' "$diff2" | bash "$script")"
check "route path captured" 1 \
  "$(printf '%s' "$out2" | jq '[.entries[] | select(.kind == "route")] | length')"
check "env var captured" 1 \
  "$(printf '%s' "$out2" | jq '[.entries[] | select(.kind == "env")] | length')"

# Added and removed declarations get the right change label.
diff3='diff --git a/lib/m.go b/lib/m.go
--- a/lib/m.go
+++ b/lib/m.go
@@ -1,3 +1,3 @@
-func OldName(a int) error {
+func NewName(a int) error {'
out3="$(printf '%s' "$diff3" | bash "$script")"
check "removed decl labelled removed" 1 \
  "$(printf '%s' "$out3" | jq '[.entries[] | select(.name=="OldName" and .change=="removed")] | length')"
check "added decl labelled added" 1 \
  "$(printf '%s' "$out3" | jq '[.entries[] | select(.name=="NewName" and .change=="added")] | length')"

# An empty diff is valid and yields nothing.
out4="$(printf '' | bash "$script")"
check "empty diff exits 0" 0 "$(printf '' | bash "$script" >/dev/null 2>&1; echo $?)"
check "empty diff has no paths" 0 "$(printf '%s' "$out4" | jq '.paths | length')"

# Multiple files.
diff5='diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1 +1 @@
-const x = 1;
+const x = 2;
diff --git a/b.ts b/b.ts
--- a/b.ts
+++ b/b.ts
@@ -1 +1 @@
-const y = 1;
+const y = 2;'
check "all changed paths listed" 2 \
  "$(printf '%s' "$diff5" | bash "$script" | jq '.paths | length')"

[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `bash plugins/soong/skills/review-pr/scripts/surface.test.sh`
Expected: FAIL — `surface.sh` does not exist.

- [ ] **Step 3: Implement the minimal code to make the tests pass**

```bash
#!/usr/bin/env bash
# Derive a change surface from a unified diff on stdin.
# Emits JSON: {"paths":[...], "entries":[{name,kind,change,before,after}]}
#
# This extracts CANDIDATES. Deciding whether a candidate is reachable from
# outside its file is the caller's judgment, per the spec's inclusion test.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "jq is not installed." >&2; exit 2; }
diff="$(cat)"
paths="$(printf '%s\n' "$diff" | sed -n 's|^diff --git a/.* b/\(.*\)$|\1|p' \
  | jq -R -s -c 'split("\n") | map(select(length > 0)) | unique')"
decl_re='^[+-][[:space:]]*(export[[:space:]]+)?(async[[:space:]]+)?(func|function|def|class|interface|type|struct|enum)[[:space:]]+[A-Za-z_]'
route_re='\.(route|get|post|put|patch|delete)\('
env_re='(os\.environ|process\.env|getenv)'
const_re='^[+-][[:space:]]*(export[[:space:]]+)?(const|var|let)?[[:space:]]*[A-Z][A-Z0-9_]{2,}[[:space:]]*='
entries="[]"
add_entry(){ entries="$(printf '%s' "$entries" | jq -c --arg n "$1" --arg k "$2" --arg c "$3" --arg b "$4" --arg a "$5" '. + [{name:$n,kind:$k,change:$c,before:$b,after:$a}]')"; }
names=(); kinds=(); befores=(); afters=()
name_index(){ local i=0 n; for n in "${names[@]+"${names[@]}"}"; do [ "$n" = "$1" ] && { echo "$i"; return; }; i=$((i+1)); done; echo -1; }
while IFS= read -r line; do
  case "$line" in ---*|+++*) continue;; esac
  case "$line" in +*) side=after;; -*) side=before;; *) continue;; esac
  body="${line#?}"
  if printf '%s' "$line" | grep -Eq "$decl_re"; then
    name="$(printf '%s' "$body" | sed -nE 's/.*(func|function|def|class|interface|type|struct|enum)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/p')"
    [ -n "$name" ] || continue
    i="$(name_index "$name")"
    if [ "$i" -lt 0 ]; then names+=("$name"); kinds+=("declaration"); befores+=(""); afters+=(""); i=$((${#names[@]}-1)); fi
    if [ "$side" = before ]; then befores[$i]="$body"; else afters[$i]="$body"; fi
    continue
  fi
  if printf '%s' "$body" | grep -Eq "$route_re"; then
    r="$(printf '%s' "$body" | sed -nE 's|.*["'"'"']([/][^"'"'"']*)["'"'"'].*|\1|p')"
    [ -n "$r" ] && add_entry "$r" route "$([ "$side" = after ] && echo added || echo removed)" "" "$body"
    continue
  fi
  if printf '%s' "$body" | grep -Eq "$env_re"; then
    k="$(printf '%s' "$body" | sed -nE 's/.*["'"'"']([A-Z_][A-Z0-9_]*)["'"'"'].*/\1/p')"
    [ -n "$k" ] && add_entry "$k" env "$([ "$side" = after ] && echo added || echo removed)" "" "$body"
    continue
  fi
  if printf '%s' "$line" | grep -Eq "$const_re"; then
    k="$(printf '%s' "$body" | sed -nE 's/.*[[:space:]]*([A-Z][A-Z0-9_]{2,})[[:space:]]*=.*/\1/p')"
    [ -n "$k" ] && add_entry "$k" config "$([ "$side" = after ] && echo added || echo removed)" "" "$body"
    continue
  fi
done <<EOF
$diff
EOF
i=0
for n in "${names[@]+"${names[@]}"}"; do
  b="${befores[$i]}"; a="${afters[$i]}"
  if [ -n "$b" ] && [ -n "$a" ]; then ch=altered; elif [ -n "$a" ]; then ch=added; else ch=removed; fi
  add_entry "$n" "${kinds[$i]}" "$ch" "$b" "$a"
  i=$((i+1))
done
jq -cn --argjson p "$paths" --argjson e "$entries" '{paths:$p, entries:$e}'
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bash plugins/soong/skills/review-pr/scripts/surface.test.sh`
Expected: `all checks passed`

If a regex misses a case, fix the regex — do not weaken the test. A missed boundary declaration means the integration judge never sees a contract change, which is the failure this script exists to prevent.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/skills/review-pr/scripts/
git commit -m "feat: derive the change surface from a diff"
```

---

## Chunk 3: The two reviewer agents

### Task 7: `pr-reviewer-correctness`

**Files:**
- Create: `plugins/soong/agents/pr-reviewer-correctness.md`

Model: `sonnet`, matching `adversarial-judge`. Tools are read-only — a reviewer that can edit is a reviewer that will.

- [ ] **Step 1: Write the agent**

```markdown
---
name: pr-reviewer-correctness
description: Reviews a pull request diff for correctness defects - bugs, unhandled errors, edge cases, concurrency, data loss, and security. Reports only findings with a concrete failure scenario. Dispatched by the review-pr skill alongside pr-reviewer-design. Read-only - never edits files.
model: sonnet
tools: Read, Grep, Glob, Bash
---

# pr-reviewer-correctness

You review one pull request diff and report correctness defects. You change
nothing.

## What counts as a finding

A finding is a defect where you can state a **concrete failure scenario**:
specific inputs or state, and the wrong outcome that follows.

Look for:

* Logic errors, off-by-one, inverted conditions.
* Unhandled errors and swallowed exceptions.
* Edge cases: empty, null, zero, negative, unicode, very large.
* Concurrency: races, deadlocks, non-atomic read-modify-write.
* Data loss: unguarded deletes, unbounded writes, missing transactions.
* Security: injection, missing authorization, secrets in code or logs,
  unvalidated input crossing a trust boundary.
* Resource leaks: unclosed handles, unbounded growth.

## What is not a finding

**These are never findings, however strongly you feel about them:**

* Formatting, whitespace, line length, quote style, import order.
* Naming preference, unless the name is actively wrong about what the code does.
* "This could be simpler", "consider extracting", "prefer X over Y".
* Missing comments or documentation.
* Test style, unless a test asserts the wrong thing.
* Anything a linter or formatter would catch.

**The test is the failure scenario.** If you cannot write specific inputs and a
specific wrong outcome, you do not have a finding. Being unable to write one is
the signal that what you have is a preference.

Report no findings rather than padding the list. An empty report on a correct
pull request is the right answer, and it is more useful than a list of
preferences that buries a real defect.

## How to work

1. Read the diff you were given.
2. Read the changed files at their current state for surrounding context. The
   diff alone hides the code a change interacts with.
3. Grep for callers when a change alters behaviour rather than only structure.
4. Verify before reporting. A finding you inferred but did not check is worth
   less than one you confirmed, and you must say which it is.

## What to return

For each finding:

* **Severity** - `blocking` or `non-blocking`. `blocking` means the pull
  request should not merge as it stands.
* **Where** - file and line, from the diff.
* **The defect** - one or two sentences.
* **Failure scenario** - the inputs or state, and the wrong outcome. Required.
* **Confidence** - `verified` when you read the code and confirmed it, or
  `inferred` when you did not. Say what you would need to verify it.

Return them ordered most severe first.

If you found nothing, say so plainly in one line. Do not manufacture a finding
to appear thorough.
```

- [ ] **Step 2: Verify the frontmatter**

Run:

```bash
awk '/^---$/{n++; next} n==1' plugins/soong/agents/pr-reviewer-correctness.md
```

Expected: the frontmatter block's contents - `name`, `description`, `model: sonnet`, and `tools: Read, Grep, Glob, Bash`. The `awk` prints only what lies between the two `---` markers, so a missing or unterminated block prints nothing rather than looking correct.

- [ ] **Step 3: Commit**

```bash
git add plugins/soong/agents/pr-reviewer-correctness.md
git commit -m "feat: add the pr-reviewer-correctness agent"
```

---

### Task 8: `pr-reviewer-design`

**Files:**
- Create: `plugins/soong/agents/pr-reviewer-design.md`

- [ ] **Step 1: Write the agent**

```markdown
---
name: pr-reviewer-design
description: Reviews a pull request diff for contract and structural defects - API and schema breakage, misleading boundaries, and missing coverage on risky paths. Reports only findings with a concrete consequence. Dispatched by the review-pr skill alongside pr-reviewer-correctness. Read-only - never edits files.
model: sonnet
tools: Read, Grep, Glob, Bash
---

# pr-reviewer-design

You review one pull request diff for contract and structural defects. You
change nothing.

Your counterpart, `pr-reviewer-correctness`, hunts bugs in what the code does.
You look at what the change commits the codebase to.

## What counts as a finding

A finding is a defect where you can state a **concrete consequence**: what
breaks, or what this will cost later, and for whom.

Look for:

* **Contract breakage.** A changed signature, type, schema, route, config key,
  or error shape that existing callers depend on. Grep for the callers; a
  breakage you asserted without finding one is inferred, not verified.
* **Compatibility.** A migration with no rollback, a required field added to an
  existing payload, a removed field still read elsewhere, a default that
  changes existing behaviour silently.
* **Misleading boundaries.** A name, signature, or module placement that tells
  a caller the wrong thing about what it does or what it costs.
* **Missing coverage on risky paths.** Not "coverage is low" - a specific
  untested path whose failure would be silent or expensive.
* **Structural problems that will cost more later.** A responsibility put in
  the wrong place, an abstraction leaking its implementation, duplicated logic
  that will drift.

## What is not a finding

**These are never findings:**

* Formatting, naming preference, import order, file length.
* "This could be simpler", "consider extracting", architectural taste.
* Missing comments or documentation.
* Coverage percentages.
* A pattern you would have chosen differently, absent a stated consequence.

**The test is the consequence.** If you cannot say what breaks or what it costs
and to whom, you do not have a finding.

An empty report on a well-shaped pull request is the right answer.

## How to work

1. Read the diff.
2. For every changed boundary - a signature, type, schema, route, config key -
   grep the repository for its dependents. This is the core of your job: a
   contract finding is only real if something depends on the contract.
3. Read the pull request's stated intent, and say so when the change does not
   match what it claims.
4. Verify before reporting, and label what you did not verify.

## What to return

For each finding:

* **Severity** - `blocking` or `non-blocking`.
* **Where** - file and line.
* **The defect** - one or two sentences.
* **Consequence** - what breaks or what it costs, and for whom. Required.
* **Dependents** - the call sites you found, or "none found" and where you
  looked.
* **Confidence** - `verified` or `inferred`.

Ordered most severe first. If you found nothing, say so in one line.
```

- [ ] **Step 2: Verify the frontmatter**

Run:

```bash
awk '/^---$/{n++; next} n==1' plugins/soong/agents/pr-reviewer-design.md
```

Expected: the same four fields as Task 7, with this agent's own name and description.

- [ ] **Step 3: Commit**

```bash
git add plugins/soong/agents/pr-reviewer-design.md
git commit -m "feat: add the pr-reviewer-design agent"
```

---

## Chunk 4: Shared-file changes

These three tasks touch files `/architect` depends on. Task 15 step 8 is the live regression check; do not skip it.

### Task 9: The integration lens in `adversarial-judge`

**Files:**
- Modify: `plugins/soong/agents/adversarial-judge.md`

Three edits: make the verifier lens mode-aware, add the integration lens, and update the opening line that says the agent judges findings about a spec.

- [ ] **Step 1: Make the verifier lens mode-aware**

Find the verifier lens paragraph (it begins `**The verifier lens.** Your evidence is the spec, the findings, and the files`). Replace it with:

```markdown
**The verifier lens.** Your evidence is the findings, the files each finding
names, and the statement of intent the dispatch supplies - a spec in spec mode,
or the pull request diff with its title and body in pull request mode. Nothing
else. Read those files. Your question is whether the finding is true of the
codebase as it stands: does the code do what the finding says it does, and is
the problem still there? Do not reason about what the other lens holds - the
pull request stack's ordering in spec mode, or the change's downstream impact in
pull request mode. That is the other lens's question.
```

The original's last sentence deferred stack re-ordering to "the other lens". In pull request mode there is no stack and the other lens is integration, so it must defer to whatever the other lens actually holds.

- [ ] **Step 2: Add the integration lens**

Immediately after the architect lens paragraph, insert:

```markdown
**The integration lens** (pull request mode only, in place of the architect
lens). Your evidence is the findings, the **change surface** - the changed paths
and the boundary declarations the change adds, removes, or alters - the pull
request's stated intent, and the code that **depends on** those declarations,
which you find by searching the repository. Your question is whether the change
breaks or misleads its callers, and whether it does what the pull request
claims.

Read the dependents. **Do not open the changed files' bodies**, including to
check whether a finding is true. That is the verifier's question, and the whole
value of two lenses is that we reach the same finding from different evidence.
You were given signatures rather than the diff for this reason; going to read
the diff anyway collapses the two lenses into one.

A finding you cannot judge from the surface and its dependents is an abstention,
not a reason to go and look at the implementation.
```

- [ ] **Step 3: Update the agent's opening line**

Find `You judge review findings about an architecture spec.` Replace with:

```markdown
You judge review findings about an architecture spec, or about a pull request.
The dispatch says which, and which lens you hold.
```

- [ ] **Step 4: Verify all three edits landed and the architect lens is untouched**

Run each line and check it against the expectation beside it:

```bash
grep -c '^\*\*The .* lens' plugins/soong/agents/adversarial-judge.md
grep -c 'Your evidence is the spec, the findings, and the files' plugins/soong/agents/adversarial-judge.md
grep -n 'read the implementation' plugins/soong/agents/adversarial-judge.md
grep -n "pull request stack's ordering in spec mode" plugins/soong/agents/adversarial-judge.md
grep -n 'about an architecture spec, or about a pull request' plugins/soong/agents/adversarial-judge.md
```

| Command | Expected |
| --- | --- |
| 1. lens headings | `3` — verifier, architect, integration |
| 2. the old verifier evidence clause | `0` — Step 1 replaced it. A `1` means Step 1 was skipped. |
| 3. the architect prohibition | one hit — the architect lens is untouched |
| 4. the mode-aware deferral | one hit — Step 1 landed |
| 5. the new opening line | one hit — Step 3 landed |

Three details, because the obvious greps here all lie:

- Anchor the lens count to `^**The`. The bare phrases "The verifier lens" and
  "The architect lens" also appear inside the `drop` verdict bullet, so an
  unanchored count reads 4 before any edit and would fail on a correct one.
- Grep `read the implementation` without the leading "Do not": the sentence
  wraps as `Do not\nread the implementation`, so the full phrase never matches.
- Command 2 is the negative assertion. Commands 4 and 5 prove the new text
  arrived; only command 2 proves the old text left.

- [ ] **Step 5: Commit**

```bash
git add plugins/soong/agents/adversarial-judge.md
git commit -m "feat: add an integration lens to adversarial-judge for PR review"
```

---

### Task 10: Council arguments and PR mode

**Files:**
- Modify: `plugins/soong/skills/adversarial-council/SKILL.md`

- [ ] **Step 1: Add the arguments section**

Insert immediately before the existing `## Inputs` heading:

```markdown
## Arguments

| Argument | Values | Default | Effect |
| --- | --- | --- | --- |
| `--mode` | `spec` or `pr` | `spec` | Sets the lens pair, the cap (8 in spec, 15 in PR), the over-cap message, and what happens on agreement. |
| `--max-findings` | integer | none | Overrides the mode's cap. |
| `--no-max-findings` | flag | off | Disables the gate. |

`--max-findings` has no default of its own: the cap comes from `--mode`, so
`--mode pr` alone means a cap of 15. Callers do not pass a value their mode
already implies.

`--no-max-findings` wins over `--max-findings`. Passing both is not an error;
say which one you honoured.

An invocation with no arguments is spec mode with a cap of eight - exactly the
behaviour this skill had before the arguments existed.
```

- [ ] **Step 2: Make Inputs mode-aware**

Replace the four-bullet `## Inputs` list with:

```markdown
You need all four. Two of them differ by mode:

| # | Spec mode | PR mode |
| --- | --- | --- |
| 1 | The findings, each with its severity | unchanged |
| 2 | The spec path | the pull request URL, its title, and its body |
| 3 | The pull request stack, as an ordered list | the change surface |
| 4 | The files or globs each finding touches | unchanged |

Each PR-mode input feeds the lens its spec-mode counterpart fed. The spec gave
both judges the statement of intent, and the pull request body now does. The
stack was the architect lens's whole evidence; the change surface is the
integration lens's.

Input 4 is what makes the verifier lens work, in either mode. A judge told to
check a finding against the code, without being told which files, rediscovers
the codebase from zero and reports what it happened to find.
```

- [ ] **Step 3: Make the cap gate mode-aware**

In the "Before dispatching: two gates" section, replace the
`**More than eight findings.**` paragraph **and** the "The cap is a signal and
not a resource limit" paragraph that follows it — the replacement below absorbs
that paragraph's reasoning into the spec-mode bullet, so leaving it in place
states the same thing twice.

Leave the `**No findings.**` gate above it alone.

Replace with:

```markdown
**Over the cap.** The cap is 8 in spec mode and 15 in PR mode, unless
`--max-findings` overrides it or `--no-max-findings` disables the gate.

Do not run the council. Hand every finding back unfiltered, and say they are
unfiltered. What you tell the user differs by mode:

* **Spec mode.** The spec needs rework rather than filtering. Nine or more
  findings means the spec is unsound, and filtering an unsound spec down to
  "only what needs your input" tells the user everything else was fine, which
  is the expensive kind of wrong.
* **PR mode.** The pull request is too large to review as one unit and should
  be split. "Rework the spec" would be nonsense here; "this is too big to
  review" is real reviewer feedback.

Do not raise the cap to get a large set through, and do not drop findings to get
under it.

When `--no-max-findings` was passed, state the finding count up front. Then:
confirm before walking a queue larger than the mode's cap **if you own the
walk**; if a caller owns it - `architect` Step 4, or `review-pr` Step 4 - report
the count, say the gate was disabled, and let the caller decide. Never prompt
about a walk you are not performing.
```

- [ ] **Step 4: Add the PR-mode report-and-verdict section**

Insert immediately before the existing `## Acting on agreement` heading:

```markdown
## PR mode reports; it does not walk

Spec mode ends in an interactive walk, and the `Asking the user` rules below
bind whoever owns it. PR mode ends in a table. The user is reviewing someone
else's pull request and has no decision to make inside the skill.

So in PR mode the `Asking the user` rules **do not apply**, and `review-pr`
Step 4 renders a report. A council that applied them would have `review-pr`
interrogate the user finding-by-finding about a stranger's pull request.

### What the verdicts mean in PR mode

Both non-`drop` verdicts degrade, because both were defined against a walk this
skill can act on:

* `auto-resolve` - you may edit nothing: the code is not the user's, and
  `review-pr` is read-only. **Report the obvious fix alongside the finding.**
* `needs-user` - nothing is queued and nothing is answered. **Report the finding
  as a concern.** Drop the judge-authored question text - a question with
  options, printed where no answer is collected, reads as a prompt waiting on
  the user. Keep the judge's reasoning.

`drop` is the one verdict unchanged in both modes.

### Every finding you did not drop is a row

That is `auto-resolve`, `needs-user`, findings the judges stayed split on after
the rebuttal, findings either judge abstained on, findings left unjudged by a
failed judge, and every finding in an unfiltered handback. Each carries what its
case needs:

| Case | The row carries |
| --- | --- |
| `auto-resolve` | the finding and the recommended fix |
| `needs-user` | the finding and the judge's reasoning |
| Still split after the rebuttal | **both** judges' positions, not a merged summary |
| Abstained, either side or both | each judge's stated reason and what it said it would need |
| Unjudged, a judge failed | that it was not judged, and why |
| Unfiltered handback | the finding, marked unfiltered |

`drop` is the only verdict that removes a finding. A dropped `blocking` finding
still leaves its notice.

This is spelled out because the omission points the wrong way: read "no shared
verdict" as "did not survive" and the report prints a clean status on a pull
request whose one finding was the one the judges could not settle.

### The blocking-drop notice in PR mode

Print it **below the concerns table**, and let it force the status to
`Concerns` even when the table is empty. `Reviewable` beside a notice saying a
blocker was swallowed is a contradiction, and the reader believes the status.

The notice is still not a question and does not wait for an answer.
```

- [ ] **Step 5: Make `Acting on agreement` mode-conditional**

The section this step edits currently states `auto-resolve` and `needs-user`
absolutely. Step 4 added the correct PR-mode meanings just above it, so without
this step a council reading its own file top-to-bottom in PR mode hits the new
section and then hits `apply the fix to the spec yourself` as an unconditional
instruction. The spec calls this out as a change to this section, not merely a
new mode setting.

Replace the three verdict bullets and the carve-out paragraph with:

```markdown
* `drop` - dropped, and the user is not told, in both modes. One exception
  below.
* `auto-resolve` - **spec mode:** apply the fix to the spec yourself, before you
  walk the queue, and list every fix you applied when you report. Applying them
  first keeps you from asking the user about a spec you are about to change
  under them. **PR mode:** report the fix alongside the finding; you edit
  nothing.
* `needs-user` - **spec mode:** queued for the user. **PR mode:** reported as a
  concern, without the question text.

One `auto-resolve` you do not apply, **in spec mode**: a fix that would add,
remove, re-order, or re-split a pull request. That change makes cobrain's
findings stale, so it needs a fresh review rather than a quiet edit. Queue it
for the user instead, and say that it changes the stack.

This carve-out has no PR-mode analogue and does not apply there. PR mode has no
stack to re-split, and applies no fixes at all.
```

- [ ] **Step 6: Make the Interactions lists mode-aware**

Append to the `## Using the Interactions lists` section:

```markdown
**In PR mode**, deduplication carries unchanged: duplicate findings are one
row, naming every finding it covers.

Dependency entries become **row grouping and ordering only**. PR mode collects
no answer and edits nothing, so no finding becomes moot and none is skipped.
Where an entry says B depends on A, the two are adjacent rows with A first, and
B's row says it follows from A. Both are reported. A dependent finding is never
dropped for being dependent.
```

- [ ] **Step 7: Verify the edits and that spec-mode text survived**

```bash
grep -c '^## Arguments\|^## PR mode reports' plugins/soong/skills/adversarial-council/SKILL.md
grep -n 'Over the cap\|the change surface' plugins/soong/skills/adversarial-council/SKILL.md
grep -c 'spec is unsound\|One finding per message' plugins/soong/skills/adversarial-council/SKILL.md
grep -c 'apply the fix to the spec yourself' plugins/soong/skills/adversarial-council/SKILL.md
grep -n 'no PR-mode analogue' plugins/soong/skills/adversarial-council/SKILL.md
grep -c '^\* .auto-resolve. - .\*spec mode:' plugins/soong/skills/adversarial-council/SKILL.md
```

| Command | Expected |
| --- | --- |
| 1. new headings | `2` |
| 2. mode-aware cap and inputs | hits for both |
| 3. spec-mode reasoning and the walk rule | `2` — neither destroyed |
| 4. the spec-mode auto-resolve instruction | `1` — kept, now scoped to spec mode |
| 5. the carve-out's PR-mode exemption | one hit — Step 5 landed |
| 6. the mode-conditional bullet | `1` — Step 5 rewrote the bullet, not just added prose |

Commands 3 and 4 are the regression assertions: they prove the spec-mode text
survived the rewrite rather than being replaced by PR-mode text. Command 6
distinguishes a real edit from prose appended somewhere harmless.

- [ ] **Step 8: Commit**

```bash
git add plugins/soong/skills/adversarial-council/SKILL.md
git commit -m "feat: add mode, cap, and finding-count arguments to the council"
```

---

### Task 11: Point `architect` at spec mode

**Files:**
- Modify: `plugins/soong/skills/architect/SKILL.md:166-167`

- [ ] **Step 1: Update Step 3.5's invocation**

Find:

```
Invoke the `adversarial-council` skill with cobrain's findings, the spec path,
the pull request stack, and the files each finding touches.
```

Replace with:

```
Invoke the `adversarial-council` skill with `--mode spec`, passing cobrain's
findings, the spec path, the pull request stack, and the files each finding
touches.

`--mode spec` is the council's default and its cap of 8 is unchanged, so this
is a no-op today. It is explicit so that anyone adding a third mode later can
see which callers assumed the default. Do not pass `--max-findings`: the cap
follows from the mode.
```

- [ ] **Step 2: Verify Step 4 still owns the walk**

Run:

```bash
grep -n "mode spec" plugins/soong/skills/architect/SKILL.md
grep -n "^## Step 4" plugins/soong/skills/architect/SKILL.md
```

Expected: the `--mode spec` invocation present; Step 4 still present and unchanged.

- [ ] **Step 3: Confirm the council's spec-mode contract by reading**

Run:

```bash
grep -n "You need all four" plugins/soong/skills/adversarial-council/SKILL.md
grep -n "spec is unsound\|Over the cap" plugins/soong/skills/adversarial-council/SKILL.md
```

Expected: Inputs still demands four; the spec-mode over-cap reasoning intact. Read enough to confirm an argument-free invocation still means spec mode with a cap of 8 — that is what keeps `/architect` behaviourally identical. The live test is Task 15 step 8.

- [ ] **Step 4: Commit**

```bash
git add plugins/soong/skills/architect/SKILL.md
git commit -m "feat: pass --mode spec from architect to the council explicitly"
```

---

## Chunk 5: The review-pr skill and release

### Task 12: `review-pr/SKILL.md`

**Files:**
- Create: `plugins/soong/skills/review-pr/SKILL.md`

- [ ] **Step 1: Write the skill**

````markdown
---
name: review-pr
description: Review one pull request in depth and report only the concerns that are real, not nitpicks. Dispatches two reviewer agents over the diff, filters their findings through the adversarial council, and reports a table of concerns with a final status of Reviewable or Concerns. Repository-local - it STOPS if the current workspace is not the pull request's own repository. Read-only; it never posts to GitHub. Use when the user runs /review-pr, asks for an in-depth or careful review of a pull request, or picks a row out of /review-pr-queue.
---

# review-pr

Review one pull request and report the concerns that are real.

This skill is read-only. It never posts a review, a comment, or an approval -
posting is `manage-pr`'s job.

## Step 0: The adjacency guard

Run this before anything else:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/review-pr/scripts/guard.sh" <url-or-number>
```

**Exit 3 means STOP.** Report the script's message verbatim and stop. Do not
clone, do not switch worktrees, do not offer to, and do not review from the diff
alone. Exit 2 is a `gh` or access problem: report it and stop.

The guard exists because the reviewer agents and the verifier lens read files
from disk. Without the right code present every finding is unverifiable, and a
review reporting unverifiable findings as concerns is worse than no review.

## Step 1: Gather

```bash
gh pr diff <url>
gh pr view <url> --json title,body,statusCheckRollup,baseRefName,headRefName
```

Resolve the merge base from the base branch the second call returns, and give it
to the agents. They read surrounding code there, so they see the code the change
was written against rather than the workspace's HEAD.

**If the diff is empty, or touches nothing but lockfiles and generated files:**
report that and stop. Do not dispatch agents and do not call the council.

## Step 2: Dispatch the reviewer agents

Send both in **one message** so they run at the same time:

* `pr-reviewer-correctness`
* `pr-reviewer-design`

Each gets the diff, the pull request's title and body, and the merge base.

Both agent files forbid style and preference findings, and require a failure
scenario or a consequence per finding. That is the primary nitpick filter. The
council's `drop` is the backstop, not the first line of defence.

Failure handling:

* **One agent fails.** Continue with the survivor's findings. Say the review is
  partial and which agent is missing. `Concerns` may still be printed;
  **`Reviewable` may not** - see Step 4.
* **Both fail.** Report the failure and stop. No status at all.

## Step 2b: Derive the change surface

```bash
gh pr diff <url> | bash "${CLAUDE_PLUGIN_ROOT}/skills/review-pr/scripts/surface.sh"
```

The script returns `paths` and `entries` - candidate boundary declarations with
their kind, whether they were added, removed, or altered, and the literal before
and after signatures.

**Prune the candidates** against one question: *can code outside the changed
file depend on this name?* Keep it if yes, wherever it appears in the file; drop
it if no, however much it changed. A route path and a config key are on the
surface even though they are statements inside a body, because a caller can
depend on them. Local variables and private helpers are not.

You own this pruning. The script extracts mechanically; a regex cannot decide
reachability across languages.

## Step 3: The council

Invoke `adversarial-council` with `--mode pr` and the four PR-mode inputs:

1. The findings, each with its severity.
2. The pull request URL, its title, and its body.
3. The change surface from Step 2b.
4. The files each finding touches - the reviewer agents name these per finding.

Do not pass `--max-findings`: `--mode pr` carries a cap of 15.

## Step 4: Report

A **report**, not a walk. Present everything at once and ask nothing - the user
is reviewing someone else's pull request and has no decision to make here. The
council's `Asking the user` rules do not apply.

Three parts:

1. **The concerns table**, one row per finding the council did not `drop`:
   location, the concern, its failure scenario or consequence, and the
   recommended fix where the council supplied one. Rows the judges linked as
   dependent are adjacent, dependency first.
2. **A blocking-drop notice**, one line per `blocking` finding both judges
   dropped, where any exist.
3. **One status.**

Every finding the council did not `drop` is a row - including `auto-resolve`,
`needs-user`, findings the judges split on, findings they abstained on,
findings left unjudged by a failed judge, and every finding in an unfiltered
handback. `drop` is the only verdict that removes one.

The status:

* **`Reviewable`** - the table is empty, no blocking-drop notice was printed,
  and both reviewer agents ran.
* **`Concerns`** - the table has at least one row, or a blocking-drop notice
  was printed.
* **`Partial: no concerns from <surviving agent>; <failed agent> did not run`**
  - where `Reviewable` would have been printed but one agent failed. Never
  phrase this so the failed agent is the subject of the no-concerns claim: it
  did not run, so it reported nothing either way.
* **No status at all** - both agents failed.

`Concerns` from a partial review is true: a concern was found, and finding more
would not change that. `Reviewable` is a claim about what is *not* there, and a
review missing a whole class of findings cannot support it.

Use the `DESIGN.md` palette where the terminal supports it: gold for the header,
`alert` for `blocking` rows, `caution` for non-blocking.

## Step 5: Stop

Report and stop. Do not post to GitHub. If the user wants to reply on the pull
request, that is `manage-pr`.
````

- [ ] **Step 2: Verify the frontmatter and both script paths resolve**

Run:

```bash
awk '/^---$/{n++; next} n==1' plugins/soong/skills/review-pr/SKILL.md | cut -c1-50
ls plugins/soong/skills/review-pr/scripts/guard.sh plugins/soong/skills/review-pr/scripts/surface.sh
```

Expected: frontmatter with `name: review-pr`; both scripts listed.

- [ ] **Step 3: Commit**

```bash
git add plugins/soong/skills/review-pr/SKILL.md
git commit -m "feat: add the review-pr skill"
```

---

### Task 13: README and version bump

**Files:**
- Modify: `README.md`
- Modify: `plugins/soong/.claude-plugin/plugin.json`

- [ ] **Step 1: Add `gh` to Requirements**

In `README.md`, add to the Requirements list, matching the existing tool-plus-reason format:

```markdown
- **`gh` CLI** — `/review-pr-queue` and `/review-pr` call it directly to read
  pull requests. Authenticate with `gh auth login`.
```

- [ ] **Step 2: Bump the version**

Change `"version": "0.15.0"` to `"version": "0.16.0"` in `plugins/soong/.claude-plugin/plugin.json`. This is a feature, and CLAUDE.md assigns features a minor bump.

- [ ] **Step 3: Verify**

Run:

```bash
jq -r .version plugins/soong/.claude-plugin/plugin.json
grep -n 'gh. CLI' README.md   # . matches the backtick
```

Expected: `0.16.0`; the new Requirements line.

- [ ] **Step 4: Commit**

```bash
git add README.md plugins/soong/.claude-plugin/plugin.json
git commit -m "feat: document the gh requirement and bump to 0.16.0"
```

---

### Task 14: Run every suite

**Files:** none — verification only.

- [ ] **Step 1: Run all three new suites plus the pre-existing ones**

```bash
for t in plugins/soong/skills/review-pr-queue/scripts/queue.test.sh \
         plugins/soong/skills/review-pr/scripts/guard.test.sh \
         plugins/soong/skills/review-pr/scripts/surface.test.sh \
         plugins/soong/skills/soong-setup/scripts/soong-setup.test.sh \
         plugins/soong/skills/walkthrough/scripts/gather-context.test.sh \
         plugins/soong/hooks/scripts/conventional-commit-guard.test.sh; do
  echo "--- $t"; bash "$t" || echo "SUITE FAILED: $t"
done
```

Expected: `all checks passed` from each. The last three are pre-existing and must be unaffected — if one now fails, this branch broke it.

- [ ] **Step 2: Confirm no debris**

```bash
git status --short
```

Expected: clean. Nothing untracked, no stray temp files.

---

### Task 15: Manual verification, from the spec's Testing section

**Files:** none — verification only. Report the result of each; do not skip one because it is awkward to stage.

- [ ] **Step 1: The queue, against the real review queue**

Run `/review-pr-queue`. Confirm it spans repositories, that no `gh pr diff` appears in the tool calls, and that a known-trivial and a known-risky pull request are classified as you would classify them.

- [ ] **Step 2: The guard, from the wrong repository**

From this worktree, run `/review-pr` on a pull request in a *different* repository. Confirm it stops, names both repositories, and dispatches no agents.

Then run it from a directory with no `origin` and confirm the same stop.

- [ ] **Step 3: A real bug survives**

Run `/review-pr` from the correct worktree on a pull request with a known real bug. Confirm the bug reaches the concerns table and the status is `Concerns`.

- [ ] **Step 4: The nitpick filter**

Run `/review-pr` on a formatting-only pull request. Confirm `Reviewable` and an empty or near-empty table. **This is the test the whole design exists to pass.**

- [ ] **Step 5: Degraded verdicts keep their row**

Run `/review-pr` on a pull request with a real bug that has one obvious fix. Confirm the finding appears with its fix and the status is `Concerns`, not `Reviewable`. Confirm the same for a `needs-user` finding: a row, an empty fix column, and no dangling question text.

- [ ] **Step 6: A dropped blocker still shows**

Run `/review-pr` on a pull request producing a single `blocking` finding both judges drop. Confirm the notice prints and the status is `Concerns` despite an empty table.

If no natural case can be staged, verify by handing the council a synthetic finding set. Do not skip the step.

- [ ] **Step 7: A partial review cannot read clean**

Run `/review-pr` with one reviewer agent forced to fail, on a pull request with no concerns. Confirm the status is neither `Reviewable` nor a sentence that reads as the failed agent having found nothing.

- [ ] **Step 8: `/architect` still behaves**

Run `/architect` on a throwaway feature. Confirm the council behaves exactly as before: two judges, the same lenses, a cap of 8, and Step 4 walking the queue one finding per message.

**This is the regression test for the three shared files.** If it fails, Tasks 9-11 broke `/architect`.

- [ ] **Step 9: Report**

Summarise which of steps 1-8 passed, and the exact output of any that did not. Steps 2, 4, 5, 6, and 7 are the ones that catch this design being wrong — every review round of the spec found another way a real finding could vanish or a clean status be printed on incomplete evidence.

---

## Done when

- [ ] All three new suites pass, and the three pre-existing suites still pass.
- [ ] Every task above is committed.
- [ ] Manual steps 1-8 have been run and reported, with step 2 (the guard), step 4 (the nitpick filter), and step 8 (the `/architect` regression) passing.
- [ ] `plugin.json` reads `0.16.0`.
