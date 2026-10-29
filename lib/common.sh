#!/usr/bin/env bash
# Shared helpers for the gwm herdr plugin.
#
# GOLDEN RULE (see PLAN.md §0): gwm is the source of truth. This plugin NEVER
# creates a worktree on the herdr side — it ADOPTS what gwm already created.
# The only herdr mutations allowed are reflections: `worktree open --path`,
# `workspace focus|close`, `tab create|focus|close`. Never introduce
# `herdr worktree create` or `--branch`.

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

# fzf theme mode: "user" (default, inherit the user's FZF_DEFAULT_OPTS) or
# "clean" (drop it entirely). Same one-line-sed reader as open_mode.
fzf_theme() {
  local cfg="${HERDR_PLUGIN_CONFIG_DIR:-}/config.toml" mode=""
  if [[ -f $cfg ]]; then
    mode=$(sed -n 's/^[[:space:]]*fzf_theme[[:space:]]*=[[:space:]]*"\{0,1\}\([a-z]*\).*/\1/p' "$cfg" | head -n1)
  fi
  case $mode in clean) printf clean ;; *) printf user ;; esac
}

# fzf for our pickers. By default it INHERITS the user's FZF_DEFAULT_OPTS so
# their theme (colors, borders) carries over, but neutralizes file-browser bits
# that would garble our non-file lines or rebind keys: a `bat {}` preview,
# transform-header/preview-label on focus, and ctrl-r → `git ls-files`. Our CLI
# flags are applied last so they win over the inherited opts. `fzf_theme=clean`
# drops the inherited opts entirely.
# No --margin: switch/remove run in popup panes (herdr ≥ 0.7.4) that herdr
# already frames, and a margin on top would crush the list. The pickers that
# stay in a split (create/review/exec) go full-bleed instead — fine, and one
# shared helper beats a per-caller margin flag.
wt_fzf() {
  # :- because every script runs under `set -u`: an unset FZF_DEFAULT_OPTS
  # would kill the picker subshell and the caller would read it as a cancel.
  local opts=${FZF_DEFAULT_OPTS:-}
  [[ $(fzf_theme) == clean ]] && opts=''
  FZF_DEFAULT_OPTS="$opts" fzf \
    --no-preview --bind 'focus:ignore' --bind 'ctrl-r:ignore' --header-label ' gwm ' \
    --reverse --info=inline --border=rounded "$@"
}

# Given a worktree path, print herdr's open_workspace_id for it (empty if not
# open). Reads `herdr worktree list` output (always JSON) on stdin. Pure/testable.
# Normalizes the trailing slash: gwm paths carry one (".../foo/"), herdr's don't.
herdr_ws_id_for_path() {
  local path=${1%/}
  jq -r --arg p "$path" \
    '.result.worktrees[]? | select((.path | rtrimstr("/")) == $p) | .open_workspace_id // empty' \
    2>/dev/null | head -n1
}

# Given a worktree path, print the herdr tabs that only reflect it: EVERY pane of
# the tab has its cwd inside the worktree (the path itself or below it, on a "/"
# boundary), its foreground program's cwd too when herdr reports one. A pane
# elsewhere, or with no cwd, keeps its tab out. Tabs of
# workspace $2 are skipped. Reads `herdr pane list` output on stdin.
#   herdr_tabs_for_path  → every such tab (switch: one to focus)
#   herdr_closable_tabs  → minus any workspace's last ones (remove: ones to
#     close). herdr closes a workspace with its last tab, and that workspace is
#     not ours to close (another worktree, its agents): a workspace whose every
#     tab qualifies keeps them all. Pure/testable.
_herdr_tabs() { # <path> <skip-ws> <close: true|false>
  local path=${1%/}
  [[ -n $path ]] || return 0
  jq -r --arg p "$path" --arg skip "$2" --argjson close "$3" '
    [ [.result.panes[]? | select(.workspace_id != $skip)] | group_by(.tab_id)[]
      | { ws: .[0].workspace_id, tab: .[0].tab_id,
          inside: all(.[]; .cwd != null and all(.cwd, (.foreground_cwd // empty);
            rtrimstr("/") as $c | $c == $p or ($c | startswith($p + "/")))) } ]
    | . as $tabs | .[] | select(.inside) | .ws as $w
    | select(($close | not) or any($tabs[]; .ws == $w and (.inside | not))) | .tab' 2>/dev/null
}
herdr_tabs_for_path() { _herdr_tabs "$1" "${2:-}" false; }
herdr_closable_tabs() { _herdr_tabs "$1" "${2:-}" true; }

# One field of the invocation context herdr injects (HERDR_PLUGIN_CONTEXT_JSON),
# e.g. workspace_id / tab_id. Popups get no HERDR_WORKSPACE_ID / HERDR_TAB_ID of
# their own (herdr launches them without a pane identity; whatever the server's
# env holds leaks through), so the caller's workspace and tab are read here
# FIRST, the env only as a fallback. Pure/testable.
ctx_field() {
  [[ -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]] || return 0
  jq -r --arg k "$1" '.[$k] // empty' <<<"$HERDR_PLUGIN_CONTEXT_JSON" 2>/dev/null
}

# Extract the worktree path from a herdr event payload (HERDR_PLUGIN_EVENT_JSON).
# herdr passes the serialized event envelope, same shape from 0.7.4 to 0.9.5:
#   {"event":"worktree_created","data":{"type":"worktree_created",
#    "workspace":{…},"worktree":{"path":…,"branch":…}}}
# (`event` is snake_case here; the dotted name is in $HERDR_PLUGIN_EVENT.)
# Pure/testable.   $1 = event json
event_worktree_path() {
  local json=${1:-}
  [[ -n $json ]] || return 0
  jq -r '.data.worktree.path // empty' <<<"$json" 2>/dev/null
}

# THE guardrail. Adopt an EXISTING worktree (already created by gwm) into herdr.
# Uses only `worktree open --path` (or `tab create --cwd`) — never creates a
# worktree on the herdr side.
#   $1 = worktree path (already on disk, created by gwm)
#   $2 = label (branch name)
adopt_worktree() {
  local path=$1 label=$2 herdr root_ws
  herdr=$(herdr_bin)
  [[ -d $path ]] || { printf 'adopt_worktree: path not found: %s\n' "$path" >&2; return 1; }
  if [[ $(open_mode) == tab ]]; then
    # The caller's workspace: without --workspace herdr would use the one its
    # server has focused. Popups carry it only in the context JSON.
    local ws; ws=$(ctx_field workspace_id); ws=${ws:-${HERDR_WORKSPACE_ID:-}}
    exec "$herdr" tab create ${ws:+--workspace "$ws"} --cwd "$path" --label "$label" --focus
  fi
  # Adopt under the repo ROOT workspace. Opening from inside a linked-worktree
  # workspace is rejected (linked_worktree_source); herdr resolves the root from
  # any checkout cwd. Fall back to a plain open if it can't be resolved.
  root_ws=$("$herdr" worktree list --cwd "$PWD" 2>/dev/null \
    | jq -r '.result.source.source_workspace_id // empty')
  if [[ -n $root_ws ]]; then
    exec "$herdr" worktree open --workspace "$root_ws" --path "$path" --label "$label" --focus
  fi
  exec "$herdr" worktree open --path "$path" --label "$label" --focus
}

# Saved profile NAMES for a picker, from `gwm config list --prefix <kind>.profiles`
# on stdin (gwm filters by key before printing, so no other section leaks in).
# Names only, never their command: picking X means "run profile X as .gwm.toml
# defines it" (gwm's resolved config: .gwm.toml over the global one) — exactly
# gwm's own `--profile X` — so the picker makes no claim it
# could have misread (a container runtime, a spoofed key). That output is gwm's
# human text, outside its JSON contract, so: any multi-line string in it (""" /
# ''') means no picker at all, and the caller keeps its plain prompt.
# ponytail: names are [A-Za-z0-9_][A-Za-z0-9_-]* on a known field only (exec:
# command|jobs|container.{image,runtime,extra_args,selinux_relabel}, clean: dirs), first occurrence wins; one multi-line
# value anywhere in the section disables the picker. A spoofed key can still
# surface a name that doesn't exist: gwm then refuses it. Pure/testable.
#   $1 = exec | clean
gwm_profile_names() {
  local fields text
  case ${1:-} in exec) fields='command|jobs|container\.(image|runtime|extra_args|selinux_relabel)' ;; clean) fields='dirs' ;; *) return 0 ;; esac
  text=$(cat)
  case $text in *'"""'* | *"'''"*) return 0 ;; esac
  printf '%s\n' "$text" \
    | sed -En "s/^$1\\.profiles\\.([A-Za-z0-9_][A-Za-z0-9_-]*)\\.($fields) = .*/\\1/p" | awk '!seen[$0]++'
}

# Extract the PR number from a GitHub PR URL, strictly validated. Prints nothing
# and returns 1 for any non-conforming URL — the link_handler guardrail: pass the
# NUMBER to `gwm review`, never a raw/forged URL.
pr_number_from_url() {
  local url=$1
  [[ $url =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}
