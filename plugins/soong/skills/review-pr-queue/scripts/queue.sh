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
