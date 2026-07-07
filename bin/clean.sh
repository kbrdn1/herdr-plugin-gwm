#!/usr/bin/env bash
# gwm: report reclaimable build artifacts across worktrees, then delete on
# confirm. gwm clean only removes git-ignored dirs (target/, node_modules/, …);
# a non-ignored dist/ is reported as skipped, never deleted.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

die() { printf '\n\033[31m%s\033[0m press any key to close' "$1"; read -rn1; exit 1; }
command -v gwm >/dev/null || die "gwm not found on PATH"

printf '→ gwm clean (report)\n\n'
gwm clean || die "gwm clean failed (see above)"

printf '\nDelete the reported artifacts? [y/N] '; read -r ans
[[ $ans =~ ^[Yy]$ ]] || { printf 'cancelled\n'; exit 0; }
gwm clean --yes

printf '\n\033[32mdone\033[0m — press any key to close'; read -rn1
