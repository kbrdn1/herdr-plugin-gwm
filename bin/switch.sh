#!/usr/bin/env bash
# gwm: switch worktree. fzf over `gwm list` (`--workspace` across every repo
# below a non-repo workspace); if herdr already reflects the picked worktree,
# focus its workspace, else adopt it. gwm stays the source of truth.
# No `set -e`: fzf esc and no-match are normal exits handled by hand.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

die() { printf '\n\033[31m%s\033[0m press any key to close' "$1"; read -rn1; exit 1; }
command -v fzf >/dev/null || die "fzf not found on PATH"

herdr=$(herdr_bin)
ws=$(ws_root)   # non-empty = multi-repo mode on that directory
wtjson=$(gwm list ${ws:+--workspace "$ws"} --format=json 2>/dev/null)
[[ -z $wtjson || $wtjson == "[]" ]] && { printf '\033[33mNo worktrees.\033[0m\n'; sleep 2; exit 0; }

# The key (name, or repo/name in multi-repo mode) is the first field, recovered
# by cutting field 1.
# Badges: issue / PR / dirty / ahead / behind, then the most recent agent session
# (`@claude`, `*` = active in the last 5 min; gwm ≥ 1.3, experimental and
# optional: a missing or reshaped `agents` field just shows no badge). CI status is
# skipped — it'd need a per-worktree `gwm status` network call.
sel=$(printf '%s\n' "$wtjson" | jq -r "$WT_KEY_JQ"'
  .[] | select(.branch != null) |
  [ key,
    (if .issue then "#\(.issue)" else "" end),
    (if .pr then "PR#\(.pr)" else "" end),
    (if .status.is_dirty then "±" else "" end),
    (if (.status.ahead // 0) > 0 then "↑\(.status.ahead)" else "" end),
    (if (.status.behind // 0) > 0 then "↓\(.status.behind)" else "" end),
    (try (.agents.top // empty | select((.kind | type) == "string") | "@\(.kind)" + (if .freshness == "active" then "*" else "" end)) catch empty)
  ] | map(select(. != "")) | join("  ")' \
  | wt_fzf --prompt='switch to ❯ ' --header='↵ to switch · esc to cancel')
[[ -z $sel ]] && exit 0
key=${sel%%[[:space:]]*}

row=$(wt_row "$key" <<<"$wtjson")
path=$(jq -r '.path // empty' <<<"$row" 2>/dev/null)
[[ -z $path ]] && die "couldn't resolve path for: $key"
branch=$(jq -r '.branch // empty' <<<"$row") name=$(jq -r '.name' <<<"$row")

# Already reflected in herdr? → focus that workspace. Else adopt it. herdr is
# asked about the TARGET's repo (--cwd "$path"): in multi-repo mode the caller's
# directory isn't even a repo.
wsid=$("$herdr" worktree list --cwd "$path" 2>/dev/null | herdr_ws_id_for_path "$path")
if [[ -n $wsid ]]; then
  exec "$herdr" workspace focus "$wsid"
fi
# open_mode=tab: a tab already showing only this worktree is focused, not doubled.
if [[ $(open_mode) == tab ]]; then
  tab=$("$herdr" pane list 2>/dev/null | herdr_tabs_for_path "$path" | head -n1)
  [[ -n $tab ]] && exec "$herdr" tab focus "$tab"
fi
adopt_worktree "$path" "${branch:-$name}"
