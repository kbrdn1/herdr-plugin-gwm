#!/usr/bin/env bash
# gwm: run a command in every worktree (`gwm exec -- <cmd>`), with gwm's per-
# worktree ✓/✗ rollup. This is your own command against your own worktrees — no
# adoption, herdr state is untouched.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

die() { printf '\n\033[31m%s\033[0m press any key to close' "$1"; read -rn1; exit 1; }
command -v gwm >/dev/null || die "gwm not found on PATH"

printf 'Command to run in every worktree (e.g. git fetch): '
read -r cmd
[[ -z $cmd ]] && exit 0

# Run through a shell in each worktree so pipes/quotes in what the user typed work.
printf '\n→ gwm exec -- bash -c %q\n\n' "$cmd"
gwm exec -- bash -c "$cmd"

printf '\n\033[32mdone\033[0m — press any key to close'; read -rn1
