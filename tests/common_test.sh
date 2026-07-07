#!/usr/bin/env bash
# Pure-helper tests. No herdr/gwm instance required. Run: bash tests/common_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../lib/common.sh
source lib/common.sh

fail=0
check() { # <desc> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n  expected=[%s]\n  got=[%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

# ctx_cwd: workspace_cwd wins
check "ctx_cwd prefers workspace_cwd" "/a" \
  "$(HERDR_PLUGIN_CONTEXT_JSON='{"workspace_cwd":"/a","focused_pane_cwd":"/b"}' ctx_cwd)"
# ctx_cwd: falls back to focused pane
check "ctx_cwd falls back to pane" "/b" \
  "$(HERDR_PLUGIN_CONTEXT_JSON='{"focused_pane_cwd":"/b"}' ctx_cwd)"

# open_mode: default workspace when no config
check "open_mode default" "workspace" "$(HERDR_PLUGIN_CONFIG_DIR=/nonexistent open_mode)"
# open_mode: tab from config
tmp=$(mktemp -d); printf 'open_mode = "tab"\n' >"$tmp/config.toml"
check "open_mode tab from config" "tab" "$(HERDR_PLUGIN_CONFIG_DIR=$tmp open_mode)"
rm -rf "$tmp"

# pr_number_from_url: valid
check "pr url valid" "42" "$(pr_number_from_url 'https://github.com/o/r/pull/42')"
# pr_number_from_url: rejects non-PR / wrong host / trailing path
pr_number_from_url 'https://github.com/o/r/issues/42' >/dev/null; check "pr url rejects issues" "1" "$?"
pr_number_from_url 'https://evil.com/o/r/pull/42'     >/dev/null; check "pr url rejects host"   "1" "$?"
pr_number_from_url 'https://github.com/o/r/pull/42/files' >/dev/null; check "pr url rejects suffix" "1" "$?"

# Source-level guardrail: no script may create a worktree on the herdr side.
# Scan only existing dirs (bin/ arrives in phase 1) and skip comment lines — the
# rule is documented in comments that legitimately name the forbidden command.
scan_dirs=(lib); [[ -d bin ]] && scan_dirs+=(bin)
viol=$(grep -REn 'worktree[[:space:]]+create|worktree open[^"]*--branch' "${scan_dirs[@]}" 2>/dev/null \
  | grep -vE ':[[:space:]]*#')
if [[ -n $viol ]]; then
  printf 'FAIL guardrail: herdr worktree creation found in sources\n%s\n' "$viol"; fail=1
else
  printf 'ok   guardrail: no herdr worktree creation in sources\n'
fi

exit "$fail"
