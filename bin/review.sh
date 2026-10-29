#!/usr/bin/env bash
# gwm: review a GitHub PR — materialize it as an isolated worktree, then adopt.
# Two entry paths:
#  - link click: the review action forwards the clicked URL as $GWM_REVIEW_URL;
#    we extract the PR number (strict, via pr_number_from_url) and skip the picker.
#  - direct: fzf over `gh pr list` (or a plain prompt) to choose the PR.
# Multi-repo mode: runs in the main checkout of one repo below the workspace —
# for a clicked URL, only a repo with a remote on the URL's GitHub repo.
# gwm stays the source of truth; herdr only adopts.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

die() { printf '\n\033[31m%s\033[0m press any key to close' "$1"; read -rn1; exit 1; }
command -v gwm >/dev/null || die "gwm not found on PATH"

# 1. resolve the PR number.
pr='' url_repo=''
if [[ -n ${GWM_REVIEW_URL:-} ]]; then
  # A forged URL can't get past this: only a strictly-anchored PR URL yields a
  # number, and only the number reaches gwm.
  pr=$(pr_number_from_url "$GWM_REVIEW_URL") || die "not a GitHub PR URL: $GWM_REVIEW_URL"
  url_repo=$(pr_repo_from_url "$GWM_REVIEW_URL")
fi
# Multi-repo mode: gwm review has no --workspace (gwm rejects it), and `gh pr
# list` reads the cwd's remote — enter the repo first.
ws=$(ws_root)
if [[ -n $ws ]]; then
  ws_enter_repo "$ws" "$url_repo"
  case $? in 0) ;; 1) exit 0 ;; *) die "no repo to review the PR in (see above)" ;; esac
fi
if [[ -z $pr ]] && command -v fzf >/dev/null && command -v gh >/dev/null; then
  sel=$(gh pr list --limit 50 2>/dev/null \
    | wt_fzf --prompt='review PR ❯ ' --header='↵ to review · esc to cancel')
  [[ -z $sel ]] && exit 0
  pr=${sel%%[[:space:]]*}; pr=${pr#\#}
elif [[ -z $pr ]]; then
  printf 'PR number (digits): '; read -r pr
fi
[[ $pr =~ ^[0-9]+$ ]] || die "invalid PR number: ${pr:-<empty>}"

# 2. materialize + adopt. gwm review is safe-by-default (no bootstrap on fork code).
printf '\n→ gwm review %s\n\n' "$pr"
gwm review "$pr" || die "gwm review failed (see above)"

# gwm review names the branch review/pr-<N>-<author>-<slug>; match on that prefix.
row=$(gwm list --format=json 2>/dev/null \
  | jq -c --arg n "$pr" 'map(select(.branch != null and (.branch|test("(^|/)review/pr-" + $n + "(-|$)")))) | last // empty')
if [[ -n $row ]]; then
  wtpath=$(jq -r '.path' <<<"$row"); branch=$(jq -r '.branch' <<<"$row")
else
  read -r wtpath branch < <(gwm path "pr-$pr" --format=json 2>/dev/null | jq -r '"\(.path) \(.branch)"')
fi
[[ -z ${wtpath:-} || $wtpath == null ]] && die "reviewed PR #$pr, but couldn't resolve its worktree path"

adopt_worktree "$wtpath" "${branch:-review/pr-$pr}"
