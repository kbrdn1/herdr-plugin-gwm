#!/usr/bin/env bash
# gwm: remove worktree. fzf over removable worktrees (not main; every repo's in
# multi-repo mode) → gwm's own
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
ws=$(ws_root "$PWD")   # non-empty = multi-repo mode on that directory
wtjson=$(gwm list ${ws:+--workspace "$ws"} --format=json 2>/dev/null)

# Removable = every real worktree except main (the primary checkout can't go).
cands=$(printf '%s\n' "$wtjson" | jq -r "$WT_KEY_JQ"'
  .[] | select(.is_main != true and .branch != null) |
  [ key,
    (if .issue then "#\(.issue)" else "" end),
    (if .pr then "PR#\(.pr)" else "" end),
    (if .status.is_dirty then "±dirty" else "" end)
  ] | map(select(. != "")) | join("  ")')
[[ -z $cands ]] && { printf '\033[33mNo removable worktrees (only main exists).\033[0m\n'; sleep 2; exit 0; }

sel=$(printf '%s\n' "$cands" \
  | wt_fzf --prompt='remove worktree ❯ ' --header='↵ to select · esc to cancel')
[[ -z $sel ]] && exit 0
key=${sel%%[[:space:]]*}

row=$(wt_row "$key" <<<"$wtjson")
path=$(jq -r '.path // empty' <<<"$row" 2>/dev/null)
[[ -z $path ]] && die "couldn't resolve path for: $key"
name=$(jq -r '.name' <<<"$row") dirty=$(jq -r '.status.is_dirty // false' <<<"$row")

# Multi-repo mode: gwm remove has no --workspace (gwm rejects it), so every gwm
# call below runs from the main checkout of the picked worktree's repo, where
# the name resolves as in single-repo mode. herdr calls carry their own --cwd.
repo=$(jq -r '.repo // empty' <<<"$row")
if [[ -n $repo ]]; then
  main=$(ws_repo_main "$repo" <<<"$wtjson")
  { [[ -n $main ]] && cd -- "$main"; } || die "couldn't enter the main checkout of $repo"
fi

# Preview with gwm's own resolution (name, path, branch). An ambiguous or unknown
# pattern fails here, before anything is asked.
preview=$(gwm remove "$name" --dry-run 2>&1) || die "gwm remove --dry-run refused: $preview"
printf '%s\n\n' "$preview"

# Map herdr's reflections now — before the question, so it can name them, and
# before the removal, after which the path is gone: the worktree's own
# workspace, and the tabs elsewhere whose panes all sit inside it.
wsid=$("$herdr" worktree list --cwd "$path" 2>/dev/null | herdr_ws_id_for_path "$path")
panes=$("$herdr" pane list 2>/dev/null)
tabs=$(herdr_closable_tabs "$path" "$wsid" <<<"$panes")
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

# Uncommitted / untracked files are deleted with the directory: neither y nor D
# keeps them, and `gwm undo` only recreates the branch at its tip.
[[ $dirty == true ]] && printf '\033[31mit has uncommitted changes: they are deleted with it (gwm undo does not bring them back)\033[0m\n\n'

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

# The answer can come much later: re-read now, while the path still exists (once
# removed, a pane's reported cwd may change, e.g. "… (deleted)" on Linux), and
# close only tabs that were announced AND are still closable — a tab that kept
# another workspace alive may have gone meanwhile.
fresh=$("$herdr" pane list 2>/dev/null | herdr_closable_tabs "$path" "$wsid")

# ${del:+…}: no empty argument, and no empty-array expansion (bash 3.2 + set -u).
# A non-zero exit with the worktree already gone (a failing post_remove hook)
# still means the reflections now point at nothing: close them anyway.
if ! gwm remove "$name" ${del:+"$del"}; then
  [[ -e $path ]] && die "gwm remove failed (see above)"
  printf '\033[33mgwm reported an error after removing it (see above)\033[0m\n'
fi
printf '\033[32m✓ removed %s\033[0m\n' "$name"

# Close herdr's reflections so the sidebar stays in sync. This script runs in a
# popup that herdr kills with the tab it was opened from, so whatever holds that
# tab (our own tab, or the removed worktree's workspace) is closed LAST. A tab
# herdr refuses to close (e.g. confirmation_required on a worktree group) is
# left, and reported long enough to be read.
own_tab=$(ctx_field tab_id) own_ws=$(ctx_field workspace_id) last=() kept=0
own_tab=${own_tab:-${HERDR_TAB_ID:-}} own_ws=${own_ws:-${HERDR_WORKSPACE_ID:-}}
close() { "$herdr" "$@" >/dev/null 2>&1 || kept=$((kept + 1)); }
report() {
  printf '\033[33m%s reflection(s) left open on the removed path (herdr refused, or no longer safe to close)\033[0m\n' "$1"
  sleep 3
}
while read -r tab; do
  [[ -z $tab ]] && continue
  grep -Fxq -- "$tab" <<<"$fresh" || { kept=$((kept + 1)); continue; }
  if [[ $tab == "$own_tab" ]]; then last+=(tab close "$tab"); else close tab close "$tab"; fi
done <<<"$tabs"
if [[ -n $wsid ]]; then
  if [[ $wsid == "$own_ws" ]]; then last=(workspace close "$wsid"); else close workspace close "$wsid"; fi
fi
((kept)) && report "$kept"
# Success ends this popup; a refusal leaves us alive to say so.
if ((${#last[@]})) && ! "$herdr" "${last[@]}" >/dev/null 2>&1; then report 1; fi
exit 0
