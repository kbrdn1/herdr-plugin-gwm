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

# 1. what to run — the repo's saved profiles, if it has any, or a typed command.
custom='(type a command)' pick='(type a command)'
profiles=$(gwm config list 2>/dev/null | gwm_profiles exec)
if [[ -n $profiles ]] && command -v fzf >/dev/null; then
  pick=$({ printf '%s\n' "$custom"; printf '%s\n' "$profiles"; } \
    | wt_fzf --prompt='exec ❯ ' --header='↵ to pick · esc to cancel' --delimiter=$'\t')
  [[ -z $pick ]] && exit 0
  pick=${pick%%$'\t'*}
fi
if [[ $pick == "$custom" ]]; then
  printf 'Command to run in every non-main worktree (e.g. git fetch): '
  read -r cmd
  [[ -z $cmd ]] && exit 0
  # Run through a shell in each worktree so pipes/quotes in what the user typed work.
  run=(-- bash -c "$cmd") shown="-- bash -c $(printf %q "$cmd")"
else
  run=(--profile "$pick") shown="--profile $pick"
fi

# 2. bounded parallelism — empty leaves it to gwm (`--jobs` > the profile's `jobs`
#    > `[exec] jobs` > sequential with live output); N > 1 prints each
#    worktree's output as a block.
printf 'Parallel jobs (empty = default): '; read -r jobs
[[ -z $jobs || $jobs =~ ^[1-9][0-9]*$ ]] || die "jobs must be a positive number: $jobs"

printf '\n→ gwm exec %s%s\n\n' "${jobs:+--jobs $jobs }" "$shown"
gwm exec ${jobs:+--jobs "$jobs"} "${run[@]}"

printf '\n\033[32mdone\033[0m — press any key to close'; read -rn1
