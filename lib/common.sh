#!/usr/bin/env bash
# Shared helpers for the gwm herdr plugin.
#
# GOLDEN RULE (see PLAN.md §0): gwm is the source of truth. This plugin NEVER
# creates a worktree on the herdr side — it ADOPTS what gwm already created.
# The only herdr mutation commands allowed are `worktree open --path` and
# `workspace close`. Never introduce `herdr worktree create` or `--branch`.

# herdr binary to call back into (portable across unix socket / windows pipe).
herdr_bin() { printf '%s' "${HERDR_BIN_PATH:-herdr}"; }

# Current repo cwd from the invocation context herdr injects. Falls back to the
# focused pane cwd, then $PWD.
ctx_cwd() {
  local cwd=""
  if [[ -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]] && command -v jq >/dev/null; then
    cwd=$(jq -r '.workspace_cwd // .focused_pane_cwd // empty' <<<"$HERDR_PLUGIN_CONTEXT_JSON" 2>/dev/null)
  fi
  printf '%s' "${cwd:-$PWD}"
}

# Presentation mode: "workspace" (default) or "tab". Read from the herdr-managed
# config dir. ponytail: a one-line sed, not a TOML parser — the file has one key.
open_mode() {
  local cfg="${HERDR_PLUGIN_CONFIG_DIR:-}/config.toml" mode=""
  if [[ -f $cfg ]]; then
    mode=$(sed -n 's/^[[:space:]]*open_mode[[:space:]]*=[[:space:]]*"\{0,1\}\([a-z]*\).*/\1/p' "$cfg" | head -n1)
  fi
  case $mode in tab) printf tab ;; *) printf workspace ;; esac
}

# THE guardrail. Adopt an EXISTING worktree (already created by gwm) into herdr.
# Uses only `worktree open --path` (or `tab create --cwd`) — never creates a
# worktree on the herdr side.
#   $1 = worktree path (already on disk, created by gwm)
#   $2 = label (branch name)
adopt_worktree() {
  local path=$1 label=$2 herdr
  herdr=$(herdr_bin)
  [[ -d $path ]] || { printf 'adopt_worktree: path not found: %s\n' "$path" >&2; return 1; }
  if [[ $(open_mode) == tab ]]; then
    exec "$herdr" tab create --cwd "$path" --label "$label" --focus
  fi
  exec "$herdr" worktree open --path "$path" --label "$label" --focus
}

# Extract the PR number from a GitHub PR URL, strictly validated. Prints nothing
# and returns 1 for any non-conforming URL — the link_handler guardrail: pass the
# NUMBER to `gwm review`, never a raw/forged URL.
pr_number_from_url() {
  local url=$1
  [[ $url =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}
