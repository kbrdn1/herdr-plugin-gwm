#!/usr/bin/env bash
# gwm: switch worktree. fzf over `gwm list`; if herdr already reflects the picked
# worktree, focus its workspace, else adopt it. gwm stays the source of truth.
# No `set -e`: fzf esc and no-match are normal exits handled by hand.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

die() { printf '\n\033[31m%s\033[0m press any key to close' "$1"; read -rn1; exit 1; }
command -v fzf >/dev/null || die "fzf not found on PATH"

herdr=$(herdr_bin)
wtjson=$(gwm list --format=json 2>/dev/null)
[[ -z $wtjson || $wtjson == "[]" ]] && { printf '\033[33mNo worktrees.\033[0m\n'; sleep 2; exit 0; }

# name is the first field (kebab, no spaces) so we recover it by cutting field 1.
# Badges: issue / PR / dirty / ahead / behind (CI status is skipped — it'd need a
# per-worktree `gwm status` network call).
sel=$(printf '%s\n' "$wtjson" | jq -r '
  .[] | select(.branch != null) |
  [ .name,
    (if .issue then "#\(.issue)" else "" end),
    (if .pr then "PR#\(.pr)" else "" end),
    (if .status.is_dirty then "±" else "" end),
    (if (.status.ahead // 0) > 0 then "↑\(.status.ahead)" else "" end),
    (if (.status.behind // 0) > 0 then "↓\(.status.behind)" else "" end)
  ] | map(select(. != "")) | join("  ")' \
  | wt_fzf --prompt='switch to ❯ ' --header='↵ to switch · esc to cancel')
[[ -z $sel ]] && exit 0
name=${sel%%[[:space:]]*}

path=$(printf '%s\n' "$wtjson" | jq -r --arg n "$name" '.[] | select(.name == $n) | .path' | head -n1)
branch=$(printf '%s\n' "$wtjson" | jq -r --arg n "$name" '.[] | select(.name == $n) | .branch' | head -n1)
[[ -z $path || $path == null ]] && die "couldn't resolve path for: $name"

# Already reflected in herdr? → focus that workspace. Else adopt it.
wsid=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null | herdr_ws_id_for_path "$path")
if [[ -n $wsid ]]; then
  exec "$herdr" workspace focus "$wsid"
fi
adopt_worktree "$path" "${branch:-$name}"
