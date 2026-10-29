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

# Map herdr's reflections now — before the question, so it can name them, and
# before the removal, after which the path is gone: the worktree's own
# workspace, and the tabs elsewhere whose panes all sit inside it.
wsid=$("$herdr" worktree list --cwd "$PWD" 2>/dev/null | herdr_ws_id_for_path "$path")
panes=$("$herdr" pane list 2>/dev/null)
tabs=$(herdr_tabs_for_path "$path" "$wsid" <<<"$panes")
if [[ -n $wsid || -n $tabs ]]; then
  # Agents running there die with their pane: say so before the question.
  agents=$(jq -r --arg ws "$wsid" --arg tabs "$tabs" '
    ($tabs | split("\n")) as $t
    | [.result.panes[]? | select(.agent and (.workspace_id == $ws or (.tab_id as $id | $t | index($id))))]
    | map(.agent) | unique | join(", ")' <<<"$panes" 2>/dev/null)
  what=${wsid:+"workspace $wsid"}
  [[ -n $tabs ]] && what="${what:+$what, }tab(s) $(paste -sd' ' - <<<"$tabs")"
  printf 'herdr will close: %s\n' "$what"
  [[ -n $agents ]] && printf '\033[33magent(s) running there will be stopped: %s\033[0m\n' "$agents"
  printf '\n'
fi

# Confirm — gwm remove is destructive and won't ask.
#   y  remove, keep the branch (the work stays reachable as a branch)
#   D  delete the branch too, even with unmerged commits: gwm journals its tip
#      first, so `gwm undo` can recreate it
printf 'Remove "%s"? [y = keep the branch · D = delete the branch too, even unmerged (gwm undo can restore it) · N] ' "$name"
read -r ans
case $ans in
  [Yy]) del='' ;;
  D)    del=--delete-branch ;;
  *)    printf 'cancelled\n'; exit 0 ;;
esac

# ${del:+…}: no empty argument, and no empty-array expansion (bash 3.2 + set -u).
gwm remove "$name" ${del:+"$del"} || die "gwm remove failed (see above)"
printf '\033[32m✓ removed %s\033[0m\n' "$name"

# Close herdr's reflections so the sidebar stays in sync. This script runs in a
# popup that herdr kills with the tab it was opened from, so whatever holds that
# tab (our own tab, or the removed worktree's workspace) is closed LAST. A tab
# herdr refuses to close (e.g. confirmation_required on a worktree group) is
# left, and reported long enough to be read.
own_tab=${HERDR_TAB_ID:-} own_ws=${HERDR_WORKSPACE_ID:-} last=() kept=0
close() { "$herdr" "$@" >/dev/null 2>&1 || kept=$((kept + 1)); }
while read -r tab; do
  [[ -z $tab ]] && continue
  if [[ $tab == "$own_tab" ]]; then last+=(tab close "$tab"); else close tab close "$tab"; fi
done <<<"$tabs"
if [[ -n $wsid ]]; then
  if [[ $wsid == "$own_ws" ]]; then last=(workspace close "$wsid"); else close workspace close "$wsid"; fi
fi
if ((kept)); then
  printf '\033[33m%s reflection(s) herdr would not close: left open on the removed path\033[0m\n' "$kept"
  sleep 3
fi
((${#last[@]})) && "$herdr" "${last[@]}"
exit 0
