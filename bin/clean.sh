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

# Which directory set: the default one, or a saved profile if the repo has any.
# The report and the deletion use the same one.
default='(default set)' profile=''
profiles=$(gwm config list 2>/dev/null | gwm_profiles clean)
if [[ -n $profiles ]] && command -v fzf >/dev/null; then
  pick=$({ printf '%s\n' "$default"; printf '%s\n' "$profiles"; } \
    | wt_fzf --prompt='clean ❯ ' --header='↵ to report · esc to cancel' --delimiter=$'\t')
  [[ -z $pick ]] && exit 0
  [[ $pick == "$default" ]] || profile=${pick%%$'\t'*}
fi

printf '→ gwm clean%s (report)\n\n' "${profile:+ --profile $profile}"
gwm clean ${profile:+--profile "$profile"} || die "gwm clean failed (see above)"

printf '\nDelete the reported artifacts? [y/N] '; read -r ans
[[ $ans =~ ^[Yy]$ ]] || { printf 'cancelled\n'; exit 0; }
gwm clean ${profile:+--profile "$profile"} --yes

printf '\n\033[32mdone\033[0m — press any key to close'; read -rn1
