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

pr="$(gh pr view "$target" --json headRepository,number,isDraft 2>/dev/null)" \
  || die "cannot read $target. It may not exist, or you may not have access." 2

pr_repo="$(printf '%s' "$pr" | jq -r '.headRepository.nameWithOwner // empty')"
[ -n "$pr_repo" ] || die "could not resolve the pull request's repository." 2
number="$(printf '%s' "$pr" | jq -r '.number')"

# An unresolvable workspace is a check that did not run, not one that passed.
ws_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
  || ws_repo=""
[ -n "$ws_repo" ] || die "could not resolve this workspace's repository (no origin, or a local-only checkout). The pull request belongs to $pr_repo. Nothing was reviewed." 3

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
if [ "$(lower "$pr_repo")" != "$(lower "$ws_repo")" ]; then
  die "this workspace is $ws_repo, but the pull request belongs to $pr_repo. Nothing was reviewed. Open a checkout of $pr_repo and run the skill there." 3
fi

jq -cn --arg r "$pr_repo" --argjson n "$number" '{ok:true, repo:$r, number:$n}'
