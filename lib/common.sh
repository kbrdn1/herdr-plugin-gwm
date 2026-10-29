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

# Multi-repo (gwm --workspace) mode: a herdr workspace opened on a directory
# that is not itself inside a git work tree (e.g. ~/Projects) drives every repo
# one level below it. Prints that directory, nothing in single-repo mode.
#   $1 = directory (defaults to $PWD)
ws_root() {
  local dir=${1:-$PWD}
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || printf '%s' "$dir"
}

# Picker key of a `gwm list` row: its name, or repo/name in multi-repo mode
# (`gwm list --workspace` adds .repo; names can repeat across repos). A jq def
# for the pickers, and wt_row to get a row back from a picked key (stdin = the
# list JSON). ponytail: the key is cut at the first space, so a repo directory
# whose name has a space isn't pickable. Pure/testable.
WT_KEY_JQ='def key: if .repo then "\(.repo)/\(.name)" else .name end;'
wt_row() { jq -c --arg k "$1" "$WT_KEY_JQ"' [.[] | select(key == $k)][0] // empty' 2>/dev/null; }

# Multi-repo mode, stdin = `gwm list --workspace` JSON: every repo below the
# root (one with a main checkout), the ones gwm exec / clean act on (at least
# one non-main worktree), and the main checkout of repo $1.
ws_repos() { jq -r '.[] | select(.repo != null and .is_main == true) | .repo' 2>/dev/null; }
ws_target_repos() { jq -r '[.[] | select(.repo != null and .is_main != true) | .repo] | unique[]' 2>/dev/null; }
ws_repo_main() { jq -r --arg r "$1" '[.[] | select(.repo == $r and .is_main == true)][0].path // empty' 2>/dev/null; }

# Multi-repo mode, for the actions that work on ONE repo (create: gwm types and
# .gwm.toml are per-repo; review: gwm rejects --workspace there): cd into the
# main checkout of a repo below $1 — the only one, or the one picked. $2, if
# set (owner/name), keeps only the repos whose origin is that GitHub repo: a
# clicked PR URL must land in its own repo, never on PR #N of another one.
# Returns 1 when cancelled, 2 on error (said on stderr).
ws_enter_repo() {
  local json repos r hits='' main
  json=$(gwm list --workspace "$1" --format=json 2>/dev/null)
  repos=$(ws_repos <<<"$json")
  [[ -n $repos ]] || { printf 'no git repository one level below %s\n' "$1" >&2; return 2; }
  if [[ -n ${2:-} ]]; then
    while read -r r; do
      origin_is_github_repo "$(ws_repo_main "$r" <<<"$json")" "$2" && hits+=$r$'\n'
    done <<<"$repos"
    repos=${hits%$'\n'}
    [[ -n $repos ]] || { printf 'no repository below %s has %s as its origin\n' "$1" "$2" >&2; return 2; }
  fi
  r=$repos
  if [[ $repos == *$'\n'* ]]; then
    command -v fzf >/dev/null || { printf 'fzf not found on PATH (needed to pick the repo)\n' >&2; return 2; }
    r=$(wt_fzf --prompt='repo ❯ ' --header='↵ to pick the repo · esc to cancel' <<<"$repos")
    [[ -n $r ]] || return 1
  fi
  main=$(ws_repo_main "$r" <<<"$json")
  if [[ -z $main ]] || ! cd -- "$main" 2>/dev/null; then
    printf "couldn't enter the main checkout of %s\n" "$r" >&2
    return 2
  fi
}

# Is the origin of the checkout at $1 the GitHub repo $2 (owner/name)? origin
# only: `gwm review` resolves and fetches the PR there and nowhere else, so on a
# fork clone (origin = fork, upstream = canonical) an upstream PR is no match.
# https, ssh:// and scp forms, with or without .git, case-insensitive (GitHub
# names are). Local only: reads git config, no network.
origin_is_github_repo() {
  local want url
  want=$(tr '[:upper:]' '[:lower:]' <<<"$2")
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
  url=$(tr '[:upper:]' '[:lower:]' <<<"$url"); url=${url%/}; url=${url%.git}
  case $url in
    "https://github.com/$want" | "ssh://git@github.com/$want" | "git@github.com:$want") return 0 ;;
  esac
  return 1
}

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
  # any checkout of THE TARGET's repo (--cwd "$path", not the caller's: they
  # differ in multi-repo mode).
  local src root
  src=$("$herdr" worktree list --cwd "$path" 2>/dev/null)
  root_ws=$(jq -r '.result.source.source_workspace_id // empty' <<<"$src" 2>/dev/null)
  if [[ -n $root_ws ]]; then
    exec "$herdr" worktree open --workspace "$root_ws" --path "$path" --label "$label" --focus
  fi
  # No workspace open on that repo yet: open from its main checkout, and herdr
  # creates the repo's workspace (unfocused) and groups the worktree under it —
  # a bare `--path` open would start from the server's active workspace.
  root=$(jq -r '.result.source.source_checkout_path // empty' <<<"$src" 2>/dev/null)
  if [[ -n $root ]]; then
    exec "$herdr" worktree open --cwd "$root" --path "$path" --label "$label" --focus
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

# The GitHub repo of that same strictly-validated PR URL, as owner/name.
pr_repo_from_url() {
  [[ $1 =~ ^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}
