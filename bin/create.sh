#!/usr/bin/env bash
# gwm: create a worktree, then adopt it into herdr. gwm is the source of truth
# (see PLAN.md §0) — this script only ADOPTS what gwm produced.
#
# Flow: (multi-repo mode: pick the repo) → pick branch type (fzf over `gwm types`, or `(auto)`) → issue → desc (empty
#       = from the issue title; not asked with `(auto)`) → `gwm create` → resolve
#       the new worktree → adopt via lib/common.sh::adopt_worktree.
# No `set -e`: fzf esc (130) and empty picks are normal exits handled by hand.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

die() { printf '\n\033[31m%s\033[0m press any key to close' "$1"; read -rn1; exit 1; }

command -v gwm >/dev/null || die "gwm not found on PATH"

# 0. multi-repo mode: the worktree goes to ONE repo, whose types and .gwm.toml
#    are its own — run the whole flow from its main checkout.
ws=$(ws_root)
if [[ -n $ws ]]; then
  ws_enter_repo "$ws"
  case $? in 0) ;; 1) exit 0 ;; *) die "no repo to create the worktree in (see above)" ;; esac
fi

# 1. branch type — fzf over `gwm types` first column (its "(source: …)" footer is
#    not a type), then the `(auto)` entry: no type at all, gwm reads it off the
#    issue's labels. gwm type names are ^[a-z]+$, so a parenthesised sentinel can
#    never shadow a configured type. Plain read as fallback.
auto='(auto) type from the issue labels'
if command -v fzf >/dev/null; then
  type=$({ gwm types 2>/dev/null | awk 'NF && $1 !~ /^\(/ {print $1}'; printf '%s\n' "$auto"; } \
    | wt_fzf --prompt='branch type ❯ ' --header='↵ to pick · esc to cancel')
else
  printf 'Branch type (feat/fix/…, or (auto)): '; read -r type
fi
[[ -z ${type:-} ]] && exit 0

# 2. issue number — digits only (gwm create requires it).
printf 'Issue number (digits): '; read -r issue
[[ $issue =~ ^[0-9]+$ ]] || die "issue must be digits only: $issue"

# 3. description — gwm normalizes it to kebab-case. Empty = let gwm derive it
#    from the issue's title (`gwm create --issue`, gwm ≥ 1.10): nothing to retype,
#    and an issue that already has a worktree is just reported (exit 0), then
#    adopted below. The picked type is passed as --type, so it always wins.
#    `(auto)` asks nothing more: the whole triple comes from the issue (labels →
#    type, title → desc), and gwm refuses, naming --type, unless the labels pick
#    exactly one type.
desc='' from_labels=0
[[ $type == '(auto)'* ]] && from_labels=1
((from_labels)) || { printf 'Description (empty = from the issue title): '; read -r desc; }
if ((from_labels)); then
  args=(--issue "$issue")
elif [[ -n $desc ]]; then
  args=("$type" "$issue" "$desc")
else
  args=(--issue "$issue" --type "$type")
fi

# Create via gwm. Interactive so any bootstrap / trust prompt shows in this pane.
printf '\n→ gwm create %s\n\n' "${args[*]}"
gwm create "${args[@]}" || die "gwm create failed (see above)"

# Resolve the new worktree. Prefer an exact match on the linked issue (gwm derives
# it from the branch) — immune to desc normalization; fall back to fuzzy path
# when a desc was typed. Compared as numbers: gwm reads "007" as issue 7.
row=$(gwm list --format=json 2>/dev/null \
  | jq -c --arg i "$issue" 'map(select(.issue != null and .issue == ($i|tonumber))) | last // empty')
if [[ -n $row ]]; then
  path=$(jq -r '.path' <<<"$row"); branch=$(jq -r '.branch' <<<"$row")
elif [[ -n $desc ]]; then
  read -r path branch < <(gwm path "$desc" --format=json 2>/dev/null \
    | jq -r '"\(.path) \(.branch)"')
fi
[[ -z ${path:-} || $path == null ]] && die "created worktree, but couldn't resolve its path"

adopt_worktree "$path" "${branch:-$desc}"
