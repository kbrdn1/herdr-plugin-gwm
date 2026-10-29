#!/usr/bin/env bash
# gwm: report reclaimable build artifacts across non-main worktrees, then delete
# on confirm — the built-in set (or `[clean.profiles.default]`), or a saved
# `[clean.profiles.<name>]` picked here. gwm clean only removes git-ignored dirs
# (target/, node_modules/, …); a non-ignored dist/ is reported as skipped.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

die() { printf '\n\033[31m%s\033[0m press any key to close' "$1"; read -rn1; exit 1; }
command -v gwm >/dev/null || die "gwm not found on PATH"

# Multi-repo mode: report and delete across every repo below the workspace (the
# confirmation says how many); per-repo profiles aren't offered there.
ws=$(ws_root "$PWD") where=''
if [[ -n $ws ]]; then
  json=$(gwm list --workspace "$ws" --format=json 2>/dev/null)
  [[ -n $(ws_repos <<<"$json") ]] || die "no git repository one level below $ws"
  n=$(ws_target_repos <<<"$json" | grep -c .)   # repos with a non-main worktree
  where=" in the $n repo(s) under $ws"
fi

# Which directory set: the default one (built-ins, or `[clean.profiles.default]`),
# or a saved profile — by NAME only, like exec. The report and the deletion use
# the same one.
default='(default set)' profile=''
profiles=''
[[ -z $ws ]] && profiles=$(gwm config list --prefix clean.profiles 2>/dev/null | gwm_profile_names clean | grep -vx default)
if [[ -n $profiles ]] && command -v fzf >/dev/null; then
  pick=$({ printf '%s\n' "$default"; printf '%s\n' "$profiles"; } \
    | wt_fzf --prompt='clean ❯ ' --header='↵ to report · esc to cancel')
  [[ -z $pick ]] && exit 0
  [[ $pick == "$default" ]] || profile=$pick
fi

printf '→ gwm clean%s%s (report)\n\n' "${ws:+ --workspace $(printf %q "$ws")}" "${profile:+ --profile=$profile}"
gwm clean ${ws:+--workspace "$ws"} ${profile:+"--profile=$profile"} || die "gwm clean failed (see above)"

printf '\nDelete the reported artifacts%s? [y/N] ' "$where"; read -r ans
[[ $ans =~ ^[Yy]$ ]] || { printf 'cancelled\n'; exit 0; }
if gwm clean ${ws:+--workspace "$ws"} ${profile:+"--profile=$profile"} --yes; then
  printf '\n\033[32mdone\033[0m — press any key to close'
else
  printf '\n\033[31mfinished with failures (see above)\033[0m — press any key to close'
fi
read -rn1
