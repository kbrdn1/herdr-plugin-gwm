#!/usr/bin/env bash
# gwm: run a command in every non-main worktree (`gwm exec -- <cmd>`, or a saved
# `[exec.profiles.<name>]` via `--profile`), optionally `--jobs N` at a time, with
# gwm's per-worktree ✓/✗ rollup. This is your own command against your own
# worktrees — no adoption, herdr state is untouched.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

die() { printf '\n\033[31m%s\033[0m press any key to close' "$1"; read -rn1; exit 1; }
command -v gwm >/dev/null || die "gwm not found on PATH"

# Multi-repo mode: the run fans out over every repo below the workspace, so the
# prompt says how many. Profiles are per-repo (`gwm config list` needs one):
# not offered there, the typed command is.
ws=$(ws_root "$PWD") where='every non-main worktree'
if [[ -n $ws ]]; then
  json=$(gwm list --workspace "$ws" --format=json 2>/dev/null)
  [[ -n $(ws_repos <<<"$json") ]] || die "no git repository one level below $ws"
  n=$(ws_target_repos <<<"$json" | grep -c .)   # repos with a non-main worktree
  where="every non-main worktree of the $n repo(s) under $ws"
fi

# 1. what to run — a saved profile, by NAME (the picker never shows a command it
#    would have to parse out of gwm's text: picking X runs profile X as
#    .gwm.toml defines it), or a typed command.
custom='(type a command)' pick='(type a command)'
profiles=''
[[ -z $ws ]] && profiles=$(gwm config list --prefix exec.profiles 2>/dev/null | gwm_profile_names exec)
if [[ -n $profiles ]] && command -v fzf >/dev/null; then
  pick=$({ printf '%s\n' "$custom"; printf '%s\n' "$profiles"; } \
    | wt_fzf --prompt='exec ❯ ' --header='↵ to pick a saved profile or type a command · esc to cancel')
  [[ -z $pick ]] && exit 0
fi
if [[ $pick == "$custom" ]]; then
  printf 'Command to run in %s (e.g. git fetch): ' "$where"
  read -r cmd
  [[ -z $cmd ]] && exit 0
  # Run through a shell in each worktree so pipes/quotes in what the user typed work.
  run=(-- bash -c "$cmd") shown="-- bash -c $(printf %q "$cmd")"
else
  # --profile=NAME: one argv word, whatever the name starts with.
  run=("--profile=$pick") shown="--profile=$pick"
fi

# 2. bounded parallelism — empty leaves it to gwm (`--jobs` > the profile's `jobs`
#    > `[exec] jobs` > sequential with live output); N > 1 prints each
#    worktree's output as a block.
printf 'Parallel jobs (empty = default): '; read -r jobs
[[ -z $jobs || $jobs =~ ^[1-9][0-9]*$ ]] || die "jobs must be a positive number: $jobs"

printf '\n→ gwm exec %s%s%s\n\n' "${ws:+--workspace $(printf %q "$ws") }" "${jobs:+--jobs $jobs }" "$shown"
if gwm exec ${ws:+--workspace "$ws"} ${jobs:+--jobs "$jobs"} "${run[@]}"; then
  printf '\n\033[32mdone\033[0m — press any key to close'
else
  printf '\n\033[31mfinished with failures (see above)\033[0m — press any key to close'
fi
read -rn1
