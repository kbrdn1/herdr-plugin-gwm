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

# fzf_theme: default user (inherit), clean from config
check "fzf_theme default user" "user" "$(HERDR_PLUGIN_CONFIG_DIR=/nonexistent fzf_theme)"
tmp=$(mktemp -d); printf 'fzf_theme = "clean"\n' >"$tmp/config.toml"
check "fzf_theme clean from config" "clean" "$(HERDR_PLUGIN_CONFIG_DIR=$tmp fzf_theme)"

# wt_fzf: a stub fzf echoes the FZF_DEFAULT_OPTS it was handed, bracketed so a
# picker that died (empty output) never passes for "no opts". This suite runs
# under `set -u` like the scripts, so an unset var must not kill the picker
# (it used to: "unbound variable", read by callers as a cancelled pick).
stub=$(mktemp -d); printf '#!/usr/bin/env bash\nprintf "[%%s]" "$FZF_DEFAULT_OPTS"\n' >"$stub/fzf"
chmod +x "$stub/fzf"
check "wt_fzf survives unset FZF_DEFAULT_OPTS" "[]" \
  "$(unset FZF_DEFAULT_OPTS; PATH="$stub:$PATH" HERDR_PLUGIN_CONFIG_DIR=/nonexistent wt_fzf </dev/null)"
check "wt_fzf inherits FZF_DEFAULT_OPTS (user)" "[--color=dark]" \
  "$(FZF_DEFAULT_OPTS='--color=dark' PATH="$stub:$PATH" HERDR_PLUGIN_CONFIG_DIR=/nonexistent wt_fzf </dev/null)"
check "wt_fzf drops FZF_DEFAULT_OPTS (clean)" "[]" \
  "$(FZF_DEFAULT_OPTS='--color=dark' PATH="$stub:$PATH" HERDR_PLUGIN_CONFIG_DIR=$tmp wt_fzf </dev/null)"
rm -rf "$tmp" "$stub"

# gwm_profile_names: NAMES only, out of real `gwm config list --prefix <kind>.profiles`
# captures (gwm 1.11). The exec one holds hostile keys: -dash, a dotted "a.b", a
# container profile, and a spoofed `lint.command = [...] x` key.
check "profile names: exec → known-field names, -dash and dotted skipped (lint = spoof, gwm refuses it)" \
  "$(printf 'box\nfmt\nlint\ntest')" "$(gwm_profile_names exec <tests/fixtures/gwm-config-profiles-exec.txt)"
check "profile names: never a command or an array in the output" "" \
  "$(gwm_profile_names exec <tests/fixtures/gwm-config-profiles-exec.txt | grep -F '[')"
check 'profile names: any multi-line string (""") → no picker at all' "" \
  "$(gwm_profile_names exec <tests/fixtures/gwm-config-profiles-exec-multiline.txt)"
check "profile names: ''' counts too" "" \
  "$(printf '%s\n' "exec.profiles.a.command = ['''" "x'''] " | gwm_profile_names exec)"
check "profile names: clean → dirs profiles" "$(printf 'deep\ndefault')" \
  "$(gwm_profile_names clean <tests/fixtures/gwm-config-profiles-clean.txt)"
check "profile names: first occurrence wins" "x" \
  "$(printf 'exec.profiles.x.command = ["a"]\nexec.profiles.x.jobs = 2\n' | gwm_profile_names exec)"
check "profile names: an unknown field doesn't make a name" "" \
  "$(printf 'exec.profiles.x.weird = 1\n' | gwm_profile_names exec)"
check "profile names: unknown kind → nothing" "" "$(gwm_profile_names nope <tests/fixtures/gwm-config-profiles-clean.txt)"

# pr_number_from_url: valid
check "pr url valid" "42" "$(pr_number_from_url 'https://github.com/o/r/pull/42')"
# pr_number_from_url: rejects non-PR / wrong host / trailing path
pr_number_from_url 'https://github.com/o/r/issues/42' >/dev/null; check "pr url rejects issues" "1" "$?"
pr_number_from_url 'https://evil.com/o/r/pull/42'     >/dev/null; check "pr url rejects host"   "1" "$?"
pr_number_from_url 'https://github.com/o/r/pull/42/files' >/dev/null; check "pr url rejects suffix" "1" "$?"

# herdr_ws_id_for_path: maps a gwm path (trailing slash) to herdr's open ws id,
# normalizing the trailing-slash mismatch (gwm ".../a/" vs herdr ".../a").
wtlist='{"result":{"worktrees":[{"path":"/repo","open_workspace_id":"w1"},{"path":"/repo/wt/a","open_workspace_id":"w9"}]}}'
check "ws id: gwm trailing slash maps to herdr id" "w9" \
  "$(printf '%s' "$wtlist" | herdr_ws_id_for_path '/repo/wt/a/')"
check "ws id: no path match is empty" "" \
  "$(printf '%s' "$wtlist" | herdr_ws_id_for_path '/repo/wt/nope')"
# present but not open (no open_workspace_id field) → empty, so we adopt instead
wtlist2='{"result":{"worktrees":[{"path":"/repo/wt/b"}]}}'
check "ws id: present but not open is empty" "" \
  "$(printf '%s' "$wtlist2" | herdr_ws_id_for_path '/repo/wt/b')"

# herdr_tabs_for_path / herdr_closable_tabs: tabs whose EVERY pane sits in the
# worktree (on a "/" boundary); the closable ones never empty a workspace.
# Fixture = herdr `pane list` shape (v0.9.5 PaneInfo), paths rewritten.
panes=$(sed 's|@ROOT@|/r|g' tests/fixtures/herdr-pane-list.json)
d71=/r/worktrees/acme-api/docs-71-openapi-examples
check "tabs: only all-inside tabs; mixed, -old prefix, no-cwd kept; w9 skipped" "w1:t3" \
  "$(printf '%s' "$panes" | herdr_tabs_for_path "$d71" w9)"
check "tabs: w9's only tab still counts as a tab on it (focus)" "$(printf 'w1:t3\nw9:t1')" \
  "$(printf '%s' "$panes" | herdr_tabs_for_path "$d71/")"
check "closable: … but is never closed (it would close w9)" "w1:t3" \
  "$(printf '%s' "$panes" | herdr_closable_tabs "$d71/")"
# A workspace whose EVERY tab sits in the worktree (another worktree's workspace
# with agents, say): its tabs can be focused, never closed (that empties it).
two='{"result":{"panes":[{"workspace_id":"w5","tab_id":"w5:t1","cwd":"/r/wt"},{"workspace_id":"w5","tab_id":"w5:t2","cwd":"/r/wt/src"},{"workspace_id":"w6","tab_id":"w6:t1","cwd":"/r/wt"},{"workspace_id":"w6","tab_id":"w6:t2","cwd":"/r/other"}]}}'
check "tabs: every all-inside tab, whatever its workspace" "$(printf 'w5:t1\nw5:t2\nw6:t1')" \
  "$(printf '%s' "$two" | herdr_tabs_for_path /r/wt)"
check "closable: never the last tabs of a workspace; only w6:t1 (w6 keeps w6:t2)" "w6:t1" \
  "$(printf '%s' "$two" | herdr_closable_tabs /r/wt)"
check "tabs: a pane with no cwd keeps its tab" "" \
  "$(printf '%s' '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t9","cwd":"/r/wt"},{"workspace_id":"w1","tab_id":"w1:t9"}]}}' | herdr_tabs_for_path /r/wt)"
fg='{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t1","cwd":"/r/wt","foreground_cwd":"/r/elsewhere"},{"workspace_id":"w1","tab_id":"w1:t2","cwd":"/r/wt","foreground_cwd":"/r/wt/src"},{"workspace_id":"w1","tab_id":"w1:t3","cwd":"/r/other"}]}}'
check "tabs: a foreground program working elsewhere keeps its tab" "w1:t2" "$(printf '%s' "$fg" | herdr_tabs_for_path /r/wt)"
check "tabs: empty path matches nothing" "" "$(printf '%s' "$panes" | herdr_tabs_for_path "")"
check "tabs: \"/\" matches nothing" "" "$(printf '%s' "$panes" | herdr_closable_tabs /)"

# ctx_field: popups carry the caller's workspace/tab only in the context JSON.
check "ctx_field reads a context field" "w1:t3" \
  "$(HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1","tab_id":"w1:t3"}' ctx_field tab_id)"
check "ctx_field is empty without context" "" "$(unset HERDR_PLUGIN_CONTEXT_JSON; ctx_field tab_id)"

# event_worktree_path: hooks get the full event envelope (EventEnvelope serialized
# by herdr, shape taken from its 0.9.5 source); the path is .data.worktree.path.
# The old top-level guesses (.worktree.path/.path/.cwd) never matched it, and
# must not come back: a flat payload yields nothing.
evt='{"event":"worktree_created","data":{"type":"worktree_created","workspace":{"workspace_id":"w3","label":"x"},"worktree":{"path":"/wt/a","branch":"feat/x","is_bare":false,"is_detached":false,"is_prunable":false,"is_linked_worktree":true,"open_workspace_id":"w3","label":"x"}}}'
check "event path from .data.worktree.path" "/wt/a" "$(event_worktree_path "$evt")"
check "event path ignores the flat (non-herdr) shape" "" "$(event_worktree_path '{"worktree":{"path":"/wt/a"},"path":"/wt/b","cwd":"/wt/c"}')"
check "event path empty when absent" "" "$(event_worktree_path '{"event":"worktree_created","data":{}}')"
check "event path empty on empty payload" "" "$(event_worktree_path '')"

# adopt_worktree: the argv it sends to a stub herdr. It resolves the repo's root
# workspace from `worktree list` (no --json, output is always JSON), then adopts
# with `worktree open --path` only; open_mode=tab opens a tab instead.
hstub=$(mktemp -d); wtdir=$(mktemp -d)
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >>"$HSTUB_LOG"' \
  '[[ "$1 $2" == "worktree list" ]] && printf %s "{\"result\":{\"source\":{\"source_workspace_id\":\"w1\"},\"worktrees\":[]}}"' \
  'exit 0' >"$hstub/herdr"
chmod +x "$hstub/herdr"
(export HSTUB_LOG=$hstub/log HERDR_BIN_PATH=$hstub/herdr HERDR_PLUGIN_CONFIG_DIR=/nonexistent
 adopt_worktree "$wtdir" feat/x)
check "adopt: root ws from worktree list" "worktree list --cwd $PWD" "$(sed -n 1p "$hstub/log")"
check "adopt: worktree open --path under root ws" \
  "worktree open --workspace w1 --path $wtdir --label feat/x --focus" "$(sed -n 2p "$hstub/log")"
: >"$hstub/log"; printf 'open_mode = "tab"\n' >"$hstub/config.toml"
(export HSTUB_LOG=$hstub/log HERDR_BIN_PATH=$hstub/herdr HERDR_PLUGIN_CONFIG_DIR=$hstub HERDR_WORKSPACE_ID=w5
 adopt_worktree "$wtdir" feat/x)
check "adopt: open_mode=tab → tab create" \
  "tab create --workspace w5 --cwd $wtdir --label feat/x --focus" "$(cat "$hstub/log")"
: >"$hstub/log"
(export HSTUB_LOG=$hstub/log HERDR_BIN_PATH=$hstub/herdr HERDR_PLUGIN_CONFIG_DIR=$hstub HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w6"}'
 unset HERDR_WORKSPACE_ID; adopt_worktree "$wtdir" feat/x)
check "adopt: tab mode in a popup takes the workspace from the context" \
  "tab create --workspace w6 --cwd $wtdir --label feat/x --focus" "$(cat "$hstub/log")"
: >"$hstub/log"
(export HSTUB_LOG=$hstub/log HERDR_BIN_PATH=$hstub/herdr HERDR_PLUGIN_CONFIG_DIR=$hstub HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w6"}' HERDR_WORKSPACE_ID=w9
 adopt_worktree "$wtdir" feat/x)
check "adopt: the context wins over a stale HERDR_WORKSPACE_ID leaked from the server env" \
  "tab create --workspace w6 --cwd $wtdir --label feat/x --focus" "$(cat "$hstub/log")"
rm -rf "$hstub" "$wtdir"

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
