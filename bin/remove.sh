#!/usr/bin/env bash
# gwm: remove worktree. fzf over removable worktrees (not main) → gwm's own
# `--dry-run` preview → confirm → `gwm remove` → close herdr's reflections (the
# worktree's workspace, and tabs left only on it). gwm is the source of truth.
# gwm remove does NOT prompt, so the confirmation gate lives here.
# No `set -e`: fzf esc and no-match are normal exits handled by hand.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

die() { printf '\n\033[31m%s\033[0m press any key to close' "$1"; read -rn1; exit 1; }
command -v fzf >/dev/null || die "fzf not found on PATH"

herdr=$(herdr_bin)
wtjson=$(gwm list --format=json 2>/dev/null)

# Removable = every real worktree except main (the primary checkout can't go).
cands=$(printf '%s\n' "$wtjson" | jq -r '
  .[] | select(.is_main != true and .branch != null) |
  [ .name,
    (if .issue then "#\(.issue)" else "" end),
    (if .pr then "PR#\(.pr)" else "" end),
    (if .status.is_dirty then "±dirty" else "" end)
  ] | map(select(. != "")) | join("  ")')
[[ -z $cands ]] && { printf '\033[33mNo removable worktrees (only main exists).\033[0m\n'; sleep 2; exit 0; }

sel=$(printf '%s\n' "$cands" \
  | wt_fzf --prompt='remove worktree ❯ ' --header='↵ to select · esc to cancel')
[[ -z $sel ]] && exit 0
name=${sel%%[[:space:]]*}

path=$(printf '%s\n' "$wtjson" | jq -r --arg n "$name" '.[] | select(.name == $n) | .path' | head -n1)
[[ -z $path || $path == null ]] && die "couldn't resolve path for: $name"

# Preview with gwm's own resolution (name, path, branch). An ambiguous or unknown
# pattern fails here, before anything is asked.
preview=$(gwm remove "$name" --dry-run 2>&1) || die "gwm remove --dry-run refused: $preview"
printf '%s\n\n' "$preview"

# Confirm — gwm remove is destructive and won't ask.
#   y  remove, keep the branch (the work stays reachable as a branch)
#   D  delete the branch too, even with unmerged commits: gwm journals its tip
#      first, so `gwm undo` recreates it
printf 'Remove "%s"? [y = keep the branch · D = delete the branch too (gwm undo restores it) · N] ' "$name"
read -r ans
case $ans in
  [Yy]) del='' ;;
  D)    del=--delete-branch ;;
  *)    printf 'cancelled\n'; exit 0 ;;
esac

# Map herdr's reflections BEFORE removing — the path is gone afterwards: the
# worktree's own workspace, and the tabs whose panes all sit inside it.
wsid=$("$herdr" worktree list --cwd "$PWD" 2>/dev/null | herdr_ws_id_for_path "$path")
tabs=$("$herdr" pane list 2>/dev/null | herdr_tabs_for_path "$path" "$wsid")

# ${del:+…}: no empty argument, and no empty-array expansion (bash 3.2 + set -u).
gwm remove "$name" ${del:+"$del"} || die "gwm remove failed (see above)"
printf '\033[32m✓ removed %s\033[0m\n' "$name"

# Close herdr's reflections so the sidebar stays in sync. A tab herdr refuses to
# close (e.g. confirmation_required on a worktree group) is left and reported.
[[ -n $wsid ]] && "$herdr" workspace close "$wsid"
closed=0 kept=0
while read -r tab; do
  [[ -n $tab ]] || continue
  if "$herdr" tab close "$tab" >/dev/null 2>&1; then closed=$((closed + 1)); else kept=$((kept + 1)); fi
done <<<"$tabs"
((closed)) && printf 'closed %s tab(s) left on it\n' "$closed"
((kept)) && printf '\033[33m%s tab(s) on it could not be closed\033[0m\n' "$kept"
exit 0
