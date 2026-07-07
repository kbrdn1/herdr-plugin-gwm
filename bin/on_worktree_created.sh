#!/usr/bin/env bash
# Event handler for worktree.created — a worktree created on the herdr side
# (native, outside gwm). Enrich it by running `gwm bootstrap` on its path
# (.env copy, hooks, preset). Adopts done by this plugin fire worktree.opened,
# not .created, so this never fires for our own work.
#
# Headless (no TTY): stdin comes from /dev/null, so an untrusted-repo trust
# prompt aborts cleanly instead of hanging the event handler. Errors surface in
# `herdr plugin log list --plugin gwm`.
set -uo pipefail

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
source "$plugin_root/lib/common.sh"

command -v gwm >/dev/null || exit 0
command -v jq  >/dev/null || exit 0

path=$(event_worktree_path)
[[ -n $path && -d $path ]] || exit 0

gwm bootstrap "$path" </dev/null
