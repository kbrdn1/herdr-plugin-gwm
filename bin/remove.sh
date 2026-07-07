#!/usr/bin/env bash
# gwm: remove worktree. fzf over removable worktrees (not main) → confirm →
# `gwm remove` → close herdr's reflected workspace. gwm is the source of truth.
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

# Confirm — gwm remove is destructive and won't ask. Branch is kept (no
# --delete-branch) so the work stays recoverable.
printf 'Remove worktree "%s"? branch kept. [y/N] ' "$name"; read -r ans
[[ $ans =~ ^[Yy]$ ]] || { printf 'cancelled\n'; exit 0; }

# Map herdr's workspace BEFORE removing — the path is gone afterwards.
wsid=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null | herdr_ws_id_for_path "$path")

gwm remove "$name" || die "gwm remove failed (see above)"
printf '\033[32m✓ removed %s\033[0m\n' "$name"

# Close herdr's reflection so the sidebar stays in sync.
[[ -n $wsid ]] && "$herdr" workspace close "$wsid"
