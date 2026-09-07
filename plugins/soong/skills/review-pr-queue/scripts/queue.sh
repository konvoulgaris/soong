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

SENSITIVE='(^|/)(auth|crypto|migrations?|migrate|payments?|billing|secrets?)(/|$)|(^|/)[^/]*auth[^/]*$|^\.github/workflows/|(^|/)Dockerfile|\.lock$|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|go\.sum|requirements[^/]*\.txt)$'
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

printf '{"prs":[]}\n'
