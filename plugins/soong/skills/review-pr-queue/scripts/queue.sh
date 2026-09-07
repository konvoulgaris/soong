#!/usr/bin/env bash
# Rank the pull requests awaiting the user's review. Metadata only, never a diff.
# Emits JSON: {"prs":[{url,title,body,churn,score,classification,files,...}]}
set -uo pipefail

die() { echo "$1" >&2; exit "${2:-1}"; }

command -v gh >/dev/null 2>&1 \
  || die "gh is not installed. Install the GitHub CLI, then re-run." 2
gh auth status >/dev/null 2>&1 \
  || die "gh is not authenticated. Run: gh auth login" 2

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
