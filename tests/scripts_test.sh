#!/usr/bin/env bash
# Script-level tests: run bin/*.sh against stub gwm / herdr / fzf / gh and assert
# the argv each script sends. No real gwm, herdr or forge needed (CI-safe).
# Fixtures (tests/fixtures/) are real gwm 1.11 output (`gwm list --format=json`,
# `gwm types` on the gwm-demo fixture) with paths rewritten to @ROOT@; the herdr
# `worktree list` follows its v0.9.5 response schema. Run: bash tests/scripts_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
root=$PWD

fail=0
check() { # <desc> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n  expected=[%s]\n  got=[%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

# --- sandbox: fixtures materialized under $S/root, stubs first on PATH --------
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/herdr-bin" "$S/config"
sed "s|@ROOT@|$S/root|g" tests/fixtures/gwm-list.json >"$S/list.json"
sed "s|@ROOT@|$S/root|g" tests/fixtures/herdr-worktree-list.json >"$S/wt.json"
sed "s|@ROOT@|$S/root|g" tests/fixtures/herdr-pane-list.json >"$S/panes.json"
cp tests/fixtures/gwm-types.txt "$S/types.txt"
cp tests/fixtures/gh-pr-list.txt "$S/gh.txt"
: >"$S/config-exec.txt"; : >"$S/config-clean.txt"
# Every checkout is a git work tree (single-repo mode); $S/root itself is not,
# so a pane on it is in multi-repo mode, served gwm-list-workspace.json.
jq -r '.[].path' "$S/list.json" | while read -r p; do mkdir -p "$p" && git init -q "$p" 2>/dev/null; done
sed "s|@ROOT@|$S/root|g" tests/fixtures/gwm-list-workspace.json >"$S/list-ws.json"
mkdir -p "$S/root/payments-svc" && git init -q "$S/root/payments-svc" 2>/dev/null
git -C "$S/root/acme-api" remote add origin https://github.com/acme/acme-api.git
git -C "$S/root/payments-svc" remote add origin git@github.com:acme/payments-svc.git
main_api=$(cd "$S/root/acme-api" && pwd) main_pay=$(cd "$S/root/payments-svc" && pwd)
wt() { printf '%s' "$S/root/worktrees/acme-api/$1"; }
caller=$(wt chore-63-bump-axum)   # panes run with --cwd = the invoking workspace

# argv logged with %q, one call per line; expectations are built the same way.
q() { local out; out=$(printf '%q ' "$@"); printf '%s' "${out% }"; }

cat >"$S/bin/gwm" <<'EOF'
#!/usr/bin/env bash
out=$(printf '%q ' gwm "$@"); printf '%s\n' "${out% }" >>"$STUB/log"
printf '%s\n' "$PWD" >>"$STUB/cwd.log"
case $1 in
  types) cat "$STUB/types.txt" ;;
  config) # `config list --prefix <kind>.profiles`; empty files = a repo without profiles
    case " $* " in *" exec.profiles "*) cat "$STUB/config-exec.txt" ;; *" clean.profiles "*) cat "$STUB/config-clean.txt" ;; esac ;;
  bootstrap) cat >"$STUB/stdin.log" ;;   # what a trust prompt would read
  list)  # GWM_WS_EMPTY=1: a workspace root with no repo below it
    if [[ " $* " != *" --workspace "* ]]; then cat "$STUB/list.json"
    elif [[ ${GWM_WS_EMPTY:-} == 1 ]]; then echo '[]'; else cat "$STUB/list-ws.json"; fi ;;
  path)  jq -c --arg p "$2" '[.[] | select(.name | contains($p))][0] // empty | {name, path, branch}' "$STUB/list.json" ;;
  review) # gwm materializes review/pr-<N>-<author>-<slug>: mirror that in the list
    n=$2 name="review-pr-$2-alice-fix"; d=$STUB/root/worktrees/acme-api/$name; mkdir -p "$d"
    jq --arg d "$d" --arg nm "$name" --arg b "review/pr-$n-alice-fix" --argjson pr "$n" \
      '. + [.[1] | .name = $nm | .id = $nm | .path = $d | .branch = $b | .issue = null | .pr = $pr]' \
      "$STUB/list.json" >"$STUB/list.tmp" && mv "$STUB/list.tmp" "$STUB/list.json"
    # GWM_REVIEW_DECOY=<M>: a review/pr-<M> worktree listed AFTER the real one,
    # so only an anchored, number-exact match picks the right PR.
    if [[ -n ${GWM_REVIEW_DECOY:-} ]]; then
      m=$GWM_REVIEW_DECOY; dd=$STUB/root/worktrees/acme-api/review-pr-$m-bob-decoy; mkdir -p "$dd"
      jq --arg d "$dd" --arg b "review/pr-$m-bob-decoy" \
        '. + [.[1] | .name = "decoy" | .id = "decoy" | .path = $d | .branch = $b | .issue = null]' \
        "$STUB/list.json" >"$STUB/list.tmp" && mv "$STUB/list.tmp" "$STUB/list.json"
    fi ;;
  remove) # --dry-run prints gwm's own resolution, in its real format
    # GWM_REMOVE_GONE=1: the real removal deletes the directory (then GWM_FAIL
    # can model a post_remove hook failing after the fact).
    if [[ ${GWM_REMOVE_GONE:-} == 1 && " $* " != *" --dry-run "* ]]; then
      rm -rf -- "$(jq -r --arg n "$2" '.[] | select(.name == $n) | .path' "$STUB/list.json")"
    fi
    if [[ " $* " == *" --dry-run "* ]]; then
      jq -r --arg n "$2" \
        '.[] | select(.name == $n) | "would remove:\n  name:   \(.name)\n  path:   \(.path)\n  branch: \(.branch)"' "$STUB/list.json"
    fi ;;
esac
[[ "$*" == "${GWM_FAIL:-}" ]] && exit 1   # GWM_FAIL='<exact argv>' makes that one call fail
exit 0
EOF
# herdr is only reachable through $HERDR_BIN_PATH (what herdr injects; it does not
# touch PATH). The stub lives off PATH; a bare `herdr` hits the trap instead.
cat >"$S/herdr-bin/herdr" <<'EOF'
#!/usr/bin/env bash
out=$(printf '%q ' herdr "$@"); printf '%s\n' "${out% }" >>"$STUB/log"
[[ "$1 $2" == "worktree list" ]] && cat "$STUB/wt.json"
if [[ "$1 $2" == "pane list" ]]; then   # panes.next, if any, answers every later call
  n=$(cat "$STUB/pane.calls" 2>/dev/null || echo 0); echo $((n + 1)) >"$STUB/pane.calls"
  if ((n)) && [[ -f $STUB/panes.next ]]; then cat "$STUB/panes.next"; else cat "$STUB/panes.json"; fi
fi
[[ "$*" == "${HERDR_FAIL:-}" ]] && exit 1   # HERDR_FAIL='<exact argv>' makes that call fail
exit 0
EOF
cat >"$S/bin/herdr" <<'EOF'
#!/usr/bin/env bash
out=$(printf '%q ' BARE-herdr "$@"); printf '%s\n' "${out% }" >>"$STUB/log"
exit 1
EOF
cat >"$S/bin/fzf" <<'EOF'
#!/usr/bin/env bash
# FZF_PICK='a;b': the Nth picker of a run takes the Nth pattern (the last one
# repeats); fzf.in = what the last picker got, fzf.in.N = the Nth one's.
n=$(cat "$STUB/fzf.calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$STUB/fzf.calls"
IFS=';' read -ra picks <<<"${FZF_PICK:-}"; pick=${picks[n - 1]:-${picks[${#picks[@]} - 1]:-}}
in=$(cat); printf '%s\n' "$in" >"$STUB/fzf.in"; cp "$STUB/fzf.in" "$STUB/fzf.in.$n"
grep -m1 -F -- "$pick" <<<"$in" || exit 1
EOF
cat >"$S/bin/gh" <<'EOF'
#!/usr/bin/env bash
out=$(printf '%q ' gh "$@"); printf '%s\n' "${out% }" >>"$STUB/log"
printf '%s\n' "$PWD" >>"$STUB/gh-cwd.log"
[[ "$1 $2" == "pr list" ]] && cat "$STUB/gh.txt"
exit 0
EOF
chmod +x "$S"/bin/* "$S/herdr-bin/herdr"

# The caller sits in a LINKED worktree workspace (w7, cwd = its checkout), not the
# root (w1): herdr rejects an open from there (linked_worktree_source), so adopts
# must target w1.
export STUB=$S PATH="$S/bin:$PATH" HERDR_PLUGIN_ROOT=$root HERDR_BIN_PATH=$S/herdr-bin/herdr \
  HERDR_PLUGIN_CONFIG_DIR=$S/config
# Popups get no HERDR_WORKSPACE_ID / HERDR_TAB_ID (herdr omits the pane identity):
# the caller's workspace and tab reach the scripts only through the context JSON.
unset FZF_DEFAULT_OPTS GWM_REVIEW_URL HERDR_PLUGIN_EVENT_JSON GWM_FAIL HERDR_FAIL \
  HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID

# run <script> <stdin> [cwd] — fresh logs, then $rc / $S/log / $S/cwd.log
run() {
  : >"$S/log"; : >"$S/cwd.log"; : >"$S/fzf.in"; rm -f "$S/pane.calls" "$S/fzf.calls" "$S"/fzf.in.*
  local cwd=${3:-$caller}
  local ctx; ctx=$(jq -cn --arg cwd "$cwd" --arg ws "${CTX_WS:-w7}" --arg tab "${CTX_TAB:-w7:t1}" \
    '{workspace_id: $ws, tab_id: $tab, workspace_cwd: $cwd, focused_pane_cwd: $cwd}')
  (cd "$cwd" && HERDR_PLUGIN_CONTEXT_JSON=$ctx bash "$root/bin/$1" <<<"$2") >"$S/out" 2>&1
  rc=$?
}
calls() { cat "$S/log"; }
lines() { printf '%s\n' "$@"; }

# --- switch ------------------------------------------------------------------
FZF_PICK=fix-57 run switch.sh ""
check "switch: not open → adopt under the root workspace" "$(lines \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$(wt fix-57-rate-limit-headers)")" \
  "$(q herdr worktree list --cwd "$(wt fix-57-rate-limit-headers)")" \
  "$(q herdr worktree open --workspace w1 --path "$(wt fix-57-rate-limit-headers)" --label 'fix/#57-rate-limit-headers' --focus)")" "$(calls)"

# docs-71 is open in w9: neither the caller's workspace (w7) nor the root (w1).
check "switch: picker badges (issue, ±, @agent from gwm list's agents field)" "$(lines \
  'fix-57-rate-limit-headers  #57  @codex' \
  'docs-71-openapi-examples  #71  @claude' \
  'chore-63-bump-axum  #63  ±' \
  'feat-42-payment-webhooks  #42  ±  @claude')" "$(grep -v '^acme-api' "$S/fzf.in")"

jq '(.[] | select(.name == "feat-42-payment-webhooks") | .agents.top.freshness) = "active"' "$S/list.json" >"$S/list.active"
cp "$S/list.json" "$S/list.idle"; cp "$S/list.active" "$S/list.json"
FZF_PICK=feat-42 run switch.sh ""
check "switch: an active session is starred (@claude*)" \
  'feat-42-payment-webhooks  #42  ±  @claude*' "$(grep '^feat-42' "$S/fzf.in")"
# `agents` is gwm's experimental tier: a reshaped field drops the badge, never rows.
jq '(.[] | select(.name == "fix-57-rate-limit-headers") | .agents) = "reshaped"' "$S/list.idle" >"$S/list.json"
FZF_PICK=feat-42 run switch.sh ""
check "switch: a reshaped agents field keeps every worktree listed" "5" "$(grep -c . "$S/fzf.in")"
jq '(.[] | select(.name == "fix-57-rate-limit-headers") | .agents.top) = {"agent": "claude"}' "$S/list.idle" >"$S/list.json"
FZF_PICK=feat-42 run switch.sh ""
check "switch: a top session without a string kind shows no badge (no @null)" \
  'fix-57-rate-limit-headers  #57' "$(grep '^fix-57' "$S/fzf.in")"
cp "$S/list.idle" "$S/list.json"

FZF_PICK=docs-71 run switch.sh ""
check "switch: already open → focus ITS workspace" "$(lines \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$(wt docs-71-openapi-examples)")" \
  "$(q herdr workspace focus w9)")" "$(calls)"

printf 'open_mode = "tab"\n' >"$S/config/config.toml"
FZF_PICK=feat-42 run switch.sh ""
check "switch: open_mode=tab, no tab on it yet → tab create in the caller's workspace" "$(lines \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$(wt feat-42-payment-webhooks)")" \
  "$(q herdr pane list)" \
  "$(q herdr tab create --workspace w7 --cwd "$(wt feat-42-payment-webhooks)" --label 'feat/#42-payment-webhooks' --focus)")" "$(calls)"
FZF_PICK=fix-57 run switch.sh ""
check "switch: open_mode=tab, a tab already only on it (w7:t2) → tab focus, no duplicate" "$(lines \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$(wt fix-57-rate-limit-headers)")" \
  "$(q herdr pane list)" \
  "$(q herdr tab focus w7:t2)")" "$(calls)"
# The only tab of its workspace (w8, opened in fix-57/src) is still one to focus:
# the never-the-last-tab rule is for closing, not for focusing.
jq --arg c "$(wt fix-57-rate-limit-headers)/src" '.result.panes |= (map(select(.tab_id != "w7:t2"))
  + [{pane_id: "w8:p1", terminal_id: "t-12", workspace_id: "w8", tab_id: "w8:t1", focused: false, cwd: $c, agent_status: "unknown"}])' \
  "$S/panes.json" >"$S/panes.w8"; cp "$S/panes.json" "$S/panes.orig"; cp "$S/panes.w8" "$S/panes.json"
FZF_PICK=fix-57 run switch.sh ""
check "switch: open_mode=tab focuses a workspace's ONLY tab on it (w8:t1)" "$(q herdr tab focus w8:t1)" "$(tail -n1 "$S/log")"
cp "$S/panes.orig" "$S/panes.json"
rm -f "$S/config/config.toml"

# --- remove ------------------------------------------------------------------
FZF_PICK=fix-57 run remove.sh "n"
check "remove: N → preview + read-only herdr lookups, nothing removed or closed" "$(lines \
  "$(q gwm list --format=json)" \
  "$(q gwm remove fix-57-rate-limit-headers --dry-run)" \
  "$(q herdr worktree list --cwd "$(wt fix-57-rate-limit-headers)")" \
  "$(q herdr pane list)")" "$(calls)"
check "remove: the preview shows gwm's resolution before the question" \
  "branch: fix/#57-rate-limit-headers" "$(grep -o 'branch: fix/#57-rate-limit-headers' "$S/out")"

GWM_FAIL='remove fix-57-rate-limit-headers --dry-run' FZF_PICK=fix-57 run remove.sh "y"
check "remove: a refused dry-run stops before the question" \
  "$(q gwm remove fix-57-rate-limit-headers --dry-run)" "$(tail -n1 "$S/log")"
check "remove: a refused dry-run asks nothing" "" "$(grep -o 'keep the branch' "$S/out")"

FZF_PICK=acme-api run remove.sh "y"
check "remove: the main checkout is never offered" "$(q gwm list --format=json)" "$(calls)"

# docs-71: its own workspace (w9) + one tab elsewhere only on it (w1:t3). Kept:
# a mixed tab (w1:t4), a docs-71-…-old prefix decoy (w1:t5), a no-cwd pane (w1:t6).
FZF_PICK=docs-71 run remove.sh "y"
check "remove: y → map reflections first, gwm remove (branch kept), close them" "$(lines \
  "$(q gwm list --format=json)" \
  "$(q gwm remove docs-71-openapi-examples --dry-run)" \
  "$(q herdr worktree list --cwd "$(wt docs-71-openapi-examples)")" \
  "$(q herdr pane list)" \
  "$(q herdr pane list)" \
  "$(q gwm remove docs-71-openapi-examples)" \
  "$(q herdr tab close w1:t3)" \
  "$(q herdr workspace close w9)")" "$(calls)"
check "remove: the question names what herdr will close" \
  "herdr will close: workspace w9, tab(s) w1:t3" "$(grep -o 'herdr will close: .*' "$S/out")"
check "remove: … and the agents that will be stopped" \
  "agent(s) running there will be stopped: claude, codex" "$(grep -o 'agent(s) running there will be stopped: [a-z, ]*' "$S/out")"

# herdr kills this popup with the tab it was opened from: when that tab is one
# of the reflections, it goes LAST, after the removed worktree's workspace.
CTX_WS=w1 CTX_TAB=w1:t3 FZF_PICK=docs-71 run remove.sh "y"
check "remove: the caller's own tab is closed last" "$(lines \
  "$(q herdr workspace close w9)" \
  "$(q herdr tab close w1:t3)")" "$(tail -n2 "$S/log")"

# Another workspace (w8) whose ONLY tab sits in docs-71: closing that tab would
# close w8 itself, so it is never a candidate.
jq --arg c "$(wt docs-71-openapi-examples)" '.result.panes += [{pane_id: "w8:p1", terminal_id: "t-12",
  workspace_id: "w8", tab_id: "w8:t1", focused: false, cwd: $c, agent_status: "working", agent: "codex"}]' \
  "$S/panes.json" >"$S/panes.w8b"; cp "$S/panes.json" "$S/panes.orig"; cp "$S/panes.w8b" "$S/panes.json"
FZF_PICK=docs-71 run remove.sh "y"
check "remove: a workspace's last tab is never closed (w8:t1 kept, w8 lives)" "" "$(grep -F 'w8' "$S/log")"
cp "$S/panes.orig" "$S/panes.json"

# Re-read after the answer: w1:t3 was announced, but by now its workspace has no
# other tab left (the "outside" ones closed meanwhile) → closing it would close
# w1, so it is left open and reported.
jq '.result.panes |= map(select(.workspace_id != "w1" or .tab_id == "w1:t3"))' "$S/panes.json" >"$S/panes.next"
FZF_PICK=docs-71 run remove.sh "y"
check "remove: an announced tab no longer safe at answer time is not closed" "" "$(grep -F 'tab close w1:t3' "$S/log")"
check "remove: … and is reported" "1 reflection(s) left open" "$(grep -o '1 reflection(s) left open' "$S/out")"
rm -f "$S/panes.next"

# The deferred close (the caller's own tab) can be refused too: still reported.
HERDR_FAIL='tab close w1:t3' CTX_WS=w1 CTX_TAB=w1:t3 FZF_PICK=docs-71 run remove.sh "y"
check "remove: a refused close of the caller's own tab is reported" \
  "1 reflection(s) left open" "$(grep -o '1 reflection(s) left open' "$S/out")"

HERDR_FAIL='tab close w1:t3' FZF_PICK=docs-71 run remove.sh "y"
check "remove: a tab herdr refuses to close is reported, the workspace still closed" \
  "1 reflection(s) left open" "$(grep -o '1 reflection(s) left open' "$S/out")"
check "remove: … and the workspace close still ran" "$(q herdr workspace close w9)" "$(tail -n1 "$S/log")"

FZF_PICK=docs-71 run remove.sh "D"
check "remove: D → gwm remove --delete-branch" \
  "$(q gwm remove docs-71-openapi-examples --delete-branch)" "$(sed -n 6p "$S/log")"
check "remove: the prompt says D deletes even unmerged work" "even unmerged" "$(grep -o 'even unmerged' "$S/out")"
FZF_PICK=docs-71 run remove.sh "d"
check "remove: lowercase d is not D → cancelled, nothing removed or closed" "" \
  "$(grep -E '^(gwm remove docs-71-openapi-examples$|herdr (tab|workspace) close)' "$S/log")"

# --- create ------------------------------------------------------------------
adopt57=$(q herdr worktree open --workspace w1 --path "$(wt fix-57-rate-limit-headers)" --label 'fix/#57-rate-limit-headers' --focus)
FZF_PICK=fix run create.sh $'57\nrate-limit-headers'
check "create: positional triple, resolved by issue, adopted" "$(lines \
  "$(q gwm types)" \
  "$(q gwm create fix 57 rate-limit-headers)" \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$(wt fix-57-rate-limit-headers)")" \
  "$adopt57")" "$(calls)"

FZF_PICK=fix run create.sh $'57\n'
check "create: empty desc → gwm create --issue N --type T" \
  "$(q gwm create --issue 57 --type fix)" "$(sed -n 2p "$S/log")"
check "create: --issue path still adopts by issue" "$adopt57" "$(tail -n1 "$S/log")"

FZF_PICK=fix run create.sh $'057\n'
check "create: 057 resolves to issue 57 (numeric match)" "$(lines \
  "$(q gwm types)" \
  "$(q gwm create --issue 057 --type fix)" \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$(wt fix-57-rate-limit-headers)")" \
  "$adopt57")" "$(calls)"

# No row carries issue 99: a typed desc falls back to `gwm path <desc>`.
FZF_PICK=feat run create.sh $'99\npayment-webhooks'
check "create: no issue match → gwm path fallback on the typed desc" "$(lines \
  "$(q gwm types)" \
  "$(q gwm create feat 99 payment-webhooks)" \
  "$(q gwm list --format=json)" \
  "$(q gwm path payment-webhooks --format=json)" \
  "$(q herdr worktree list --cwd "$(wt feat-42-payment-webhooks)")" \
  "$(q herdr worktree open --workspace w1 --path "$(wt feat-42-payment-webhooks)" --label 'feat/#42-payment-webhooks' --focus)")" "$(calls)"

check "create: type picker = gwm types (no \"(source:\" footer), then the (auto) entry" \
  "feat fix hotfix docs test refactor chore perf ci build (auto) type from the issue labels" "$(paste -sd' ' "$S/fzf.in")"

FZF_PICK=auto run create.sh $'57'
check "create: auto → gwm create --issue N, type left to the issue's labels" "$(lines \
  "$(q gwm types)" \
  "$(q gwm create --issue 57)" \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$(wt fix-57-rate-limit-headers)")" \
  "$adopt57")" "$(calls)"
check "create: auto asks no description" "" "$(grep -o 'Description' "$S/out")"

# A repo may legally declare a branch type named `auto` (gwm: ^[a-z]+$): picking
# it must create an `auto` branch, not trigger the label-derived path.
cp "$S/types.txt" "$S/types.orig"; printf '  auto      A configured type\n' >>"$S/types.txt"
FZF_PICK=auto run create.sh $'57\nmy-desc'
check "create: a configured type named auto is a normal type" \
  "$(q gwm create auto 57 my-desc)" "$(sed -n 2p "$S/log")"
cp "$S/types.orig" "$S/types.txt"

FZF_PICK=fix run create.sh $'abc\nx'
check "create: non-digit issue → refused before gwm create" "$(q gwm types)" "$(calls)"
check "create: non-digit issue exits 1" "1" "$rc"

# --- review ------------------------------------------------------------------
GWM_REVIEW_URL='https://evil.com/o/r/pull/7' run review.sh ""
check "review: forged URL → nothing reaches gwm" "" "$(calls)"
check "review: forged URL exits 1" "1" "$rc"

GWM_REVIEW_DECOY=71 GWM_REVIEW_URL='https://github.com/o/r/pull/7' run review.sh ""
check "review: link click → gwm review <N>, adopt PR 7's worktree (not the pr-71 decoy)" "$(lines \
  "$(q gwm review 7)" \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$(wt review-pr-7-alice-fix)")" \
  "$(q herdr worktree open --workspace w1 --path "$(wt review-pr-7-alice-fix)" --label review/pr-7-alice-fix --focus)")" "$(calls)"

FZF_PICK=idempotency run review.sh ""
check "review: gh pr list picker → gwm review 9, adopt PR 9's worktree" "$(lines \
  "$(q gh pr list --limit 50)" \
  "$(q gwm review 9)" \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$(wt review-pr-9-alice-fix)")" \
  "$(q herdr worktree open --workspace w1 --path "$(wt review-pr-9-alice-fix)" --label review/pr-9-alice-fix --focus)")" "$(calls)"
check "review: picker path exits 0" "0" "$rc"

FZF_PICK=feat-42 run remove.sh "n"
check "remove: a dirty worktree is flagged before the question" "uncommitted changes" "$(grep -o 'uncommitted changes' "$S/out")"
FZF_PICK=docs-71 run remove.sh "n"
check "remove: a clean one is not" "" "$(grep -o 'uncommitted changes' "$S/out")"

# A stale HERDR_TAB_ID leaked from the server env must not win over the context.
HERDR_TAB_ID=w9:t1 CTX_WS=w1 CTX_TAB=w1:t3 FZF_PICK=docs-71 run remove.sh "y"
check "remove: the caller's tab comes from the context, not a stale env" "$(q herdr tab close w1:t3)" "$(tail -n1 "$S/log")"

# gwm exits non-zero AFTER deleting the worktree (failing post_remove hook):
# the reflections now point at nothing and are closed anyway.
GWM_REMOVE_GONE=1 GWM_FAIL='remove docs-71-openapi-examples' FZF_PICK=docs-71 run remove.sh "y"
check "remove: post_remove failure with the worktree gone → reflections still closed" "$(lines \
  "$(q herdr tab close w1:t3)" \
  "$(q herdr workspace close w9)")" "$(tail -n2 "$S/log")"
check "remove: … and the error is reported" "gwm reported an error after removing it" \
  "$(grep -o 'gwm reported an error after removing it' "$S/out")"
mkdir -p "$(wt docs-71-openapi-examples)"

# --- gwm failures stop the script before herdr is touched ---------------------
GWM_FAIL='remove docs-71-openapi-examples' FZF_PICK=docs-71 run remove.sh "y"
check "remove: gwm remove fails → no workspace or tab closed" \
  "$(q gwm remove docs-71-openapi-examples)" "$(tail -n1 "$S/log")"
GWM_FAIL='create fix 57 rate-limit-headers' FZF_PICK=fix run create.sh $'57\nrate-limit-headers'
check "create: gwm create fails → nothing adopted" "$(q gwm create fix 57 rate-limit-headers)" "$(tail -n1 "$S/log")"
GWM_FAIL='review 7' GWM_REVIEW_URL='https://github.com/o/r/pull/7' run review.sh ""
check "review: gwm review fails → nothing adopted" "$(q gwm review 7)" "$(calls)"
GWM_FAIL=clean run clean.sh "y"
check "clean: report fails → no --yes" "$(q gwm clean)" "$(tail -n1 "$S/log")"

# --- exec / clean ------------------------------------------------------------
# No profiles: the plain prompt, as before.
cfg_exec=$(q gwm config list --prefix exec.profiles) cfg_clean=$(q gwm config list --prefix clean.profiles)
run exec.sh "git fetch --prune"
check "exec: the typed line runs through bash -c, as one argument" "$(lines \
  "$cfg_exec" \
  "$(q gwm exec -- bash -c 'git fetch --prune')")" "$(calls)"
run exec.sh $'git fetch\n3'
check "exec: jobs N → --jobs N" "$(q gwm exec --jobs 3 -- bash -c 'git fetch')" "$(tail -n1 "$S/log")"
run exec.sh $'git fetch\n0'
check "exec: jobs must be a positive number (0 refused, nothing runs)" "$cfg_exec" "$(calls)"
run exec.sh $'git fetch\n2; rm -rf /'
check "exec: jobs is digits only (no injection)" "$cfg_exec" "$(calls)"
GWM_FAIL='exec -- bash -c false' run exec.sh "false"
check "exec: a failing run is not reported as done" "finished with failures" "$(grep -o 'finished with failures' "$S/out")"

# With profiles: picked by NAME (real `--prefix` captures, hostile keys included).
cp tests/fixtures/gwm-config-profiles-exec.txt "$S/config-exec.txt"
cp tests/fixtures/gwm-config-profiles-clean.txt "$S/config-clean.txt"
FZF_PICK='test' run exec.sh ""
check "exec: picker = typed command first, then profile NAMES only (no command shown)" \
  "$(printf '(type a command)\nbox\nfmt\nlint\ntest')" "$(cat "$S/fzf.in")"
check "exec: a picked profile → gwm exec --profile=<name>" "$(q gwm exec --profile=test)" "$(tail -n1 "$S/log")"
FZF_PICK=fmt run exec.sh "4"
check "exec: profile + jobs" "$(q gwm exec --jobs 4 --profile=fmt)" "$(tail -n1 "$S/log")"
FZF_PICK='(type a command)' run exec.sh "make lint"
check "exec: the typed-command entry still prompts" "$(q gwm exec -- bash -c 'make lint')" "$(tail -n1 "$S/log")"
cp tests/fixtures/gwm-config-profiles-exec-multiline.txt "$S/config-exec.txt"
run exec.sh "git fetch"
check "exec: a multi-line value in the profiles → no picker, the plain prompt" "" "$(cat "$S/fzf.in")"
check "exec: … and the typed command runs" "$(q gwm exec -- bash -c 'git fetch')" "$(tail -n1 "$S/log")"

FZF_PICK=deep run clean.sh "y"
check "clean: picker = default set, then profile names (default not listed twice)" \
  "$(printf '(default set)\ndeep')" "$(cat "$S/fzf.in")"
check "clean: a picked profile drives the report AND the deletion" "$(lines \
  "$cfg_clean" \
  "$(q gwm clean --profile=deep)" \
  "$(q gwm clean --profile=deep --yes)")" "$(calls)"
GWM_FAIL='clean --profile=deep --yes' FZF_PICK=deep run clean.sh "y"
check "clean: a failing deletion is not reported as done" "finished with failures" "$(grep -o 'finished with failures' "$S/out")"
FZF_PICK='(default set)' run clean.sh "n"
check "clean: the default set → plain gwm clean" "$(lines "$cfg_clean" "$(q gwm clean)")" "$(calls)"
: >"$S/config-exec.txt"; : >"$S/config-clean.txt"

run clean.sh "n"
check "clean: no profiles → report only on N" "$(lines "$cfg_clean" "$(q gwm clean)")" "$(calls)"
run clean.sh "y"
check "clean: y → report, then --yes" "$(lines "$cfg_clean" "$(q gwm clean)" "$(q gwm clean --yes)")" "$(calls)"

# --- multi-repo mode (gwm --workspace) ----------------------------------------
# A pane on $S/root (not a repo, repos one level below it): every listing goes
# through `gwm list --workspace`, picker keys are repo/name, and the commands gwm
# has no --workspace for run from the picked repo's main checkout.
W=$S/root
FZF_PICK=acme-api/fix-57 run switch.sh "" "$W"
check "workspace: switch lists every repo, keyed repo/name" \
  "acme-api/acme-api acme-api/fix-57-rate-limit-headers acme-api/docs-71-openapi-examples acme-api/chore-63-bump-axum acme-api/feat-42-payment-webhooks payments-svc/payments-svc" \
  "$(awk '{print $1}' "$S/fzf.in" | paste -sd' ' -)"
check "workspace: switch adopts under the TARGET repo's root workspace" "$(lines \
  "$(q gwm list --workspace "$W" --format=json)" \
  "$(q herdr worktree list --cwd "$(wt fix-57-rate-limit-headers)")" \
  "$(q herdr worktree list --cwd "$(wt fix-57-rate-limit-headers)")" \
  "$(q herdr worktree open --workspace w1 --path "$(wt fix-57-rate-limit-headers)" --label 'fix/#57-rate-limit-headers' --focus)")" "$(calls)"

# Same worktree name in two repos: the picked repo's row, nothing else.
cp "$S/list-ws.json" "$S/list-ws.orig"
jq --arg d "$S/root/worktrees/payments-svc/fix-57-rate-limit-headers" \
  '. + [.[1] | .repo = "payments-svc" | .path = $d | .branch = "fix/#57-retry"]' "$S/list-ws.orig" >"$S/list-ws.json"
mkdir -p "$S/root/worktrees/payments-svc/fix-57-rate-limit-headers"
FZF_PICK=payments-svc/fix-57 run remove.sh "y" "$W"
check "workspace: remove never passes --workspace (gwm rejects it there)" "" "$(grep -F -- 'remove' "$S/log" | grep -F -- '--workspace')"
check "workspace: remove resolves the picked repo's worktree, not the same name elsewhere" \
  "$(q herdr worktree list --cwd "$S/root/worktrees/payments-svc/fix-57-rate-limit-headers")" "$(grep -F 'worktree list' "$S/log")"
check "workspace: gwm remove runs from that repo's main checkout" "$(lines "$W" "$main_pay" "$main_pay")" "$(cat "$S/cwd.log")"
check "workspace: … dry-run first, then the removal" "$(lines \
  "$(q gwm remove fix-57-rate-limit-headers --dry-run)" "$(q gwm remove fix-57-rate-limit-headers)")" "$(grep '^gwm remove' "$S/log")"
cp "$S/list-ws.orig" "$S/list-ws.json"

FZF_PICK='payments-svc;fix' run create.sh $'57\nrate-limit-headers' "$W"
check "workspace: create asks the repo first" "acme-api payments-svc" "$(paste -sd' ' "$S/fzf.in.1")"
check "workspace: … then runs the usual flow in its main checkout" "$(lines \
  "$(q gwm list --workspace "$W" --format=json)" "$(q gwm types)" "$(q gwm create fix 57 rate-limit-headers)")" "$(sed -n 1,3p "$S/log")"
check "workspace: … every gwm call after the pick from there" "$(lines "$W" "$main_pay" "$main_pay" "$main_pay")" "$(cat "$S/cwd.log")"
FZF_PICK=no-such-repo run create.sh "" "$W"   # fzf stub: no match = esc
check "workspace: esc on the repo picker → nothing created" "$(q gwm list --workspace "$W" --format=json)" "$(calls)"
check "workspace: … and a clean exit" "0" "$rc"

: >"$S/gh-cwd.log"
GWM_REVIEW_URL='https://github.com/Acme/payments-svc/pull/7' run review.sh "" "$W"
check "workspace: a clicked PR lands in the repo whose remote is the URL's (no picker)" "$(lines \
  "$(q gwm list --workspace "$W" --format=json)" "$(q gwm review 7)")" "$(sed -n 1,2p "$S/log")"
check "workspace: … gwm review runs there" "$main_pay" "$(sed -n 2p "$S/cwd.log")"
check "workspace: … nothing was asked" "" "$(cat "$S/fzf.in")"
GWM_REVIEW_URL='https://github.com/other/payments-svc/pull/7' run review.sh "" "$W"
check "workspace: a PR of no repo here → refused, gwm review never runs" "$(q gwm list --workspace "$W" --format=json)" "$(calls)"
check "workspace: … exits 1" "1" "$rc"
FZF_PICK='acme-api;idempotency' run review.sh "" "$W"
check "workspace: gh pr list runs in the picked repo" "$main_api" "$(cat "$S/gh-cwd.log")"
check "workspace: … and gwm review too" "$(q gwm review 9)" "$(grep '^gwm review' "$S/log")"

run exec.sh $'git fetch\n' "$W"
check "workspace: exec fans out with --workspace, no per-repo profile lookup" "$(lines \
  "$(q gwm list --workspace "$W" --format=json)" "$(q gwm exec --workspace "$W" -- bash -c 'git fetch')")" "$(calls)"
check "workspace: … the prompt says how many repos" "of the 2 repo(s) under" "$(grep -o 'of the 2 repo(s) under' "$S/out")"
GWM_WS_EMPTY=1 run exec.sh $'git fetch\n' "$W"
check "workspace: no repo below → exec refused, nothing runs" "$(q gwm list --workspace "$W" --format=json)" "$(calls)"

run clean.sh "y" "$W"
check "workspace: clean reports, then deletes, across the workspace" "$(lines \
  "$(q gwm list --workspace "$W" --format=json)" "$(q gwm clean --workspace "$W")" "$(q gwm clean --workspace "$W" --yes)")" "$(calls)"
check "workspace: … the confirmation says how many repos" "in the 2 repo(s) under" "$(grep -o 'in the 2 repo(s) under' "$S/out")"

# --- worktree.created hook ---------------------------------------------------
# herdr starts hooks in the plugin dir; gwm must run from the worktree itself.
evt=$(jq -cn --arg p "$(wt docs-71-openapi-examples)" \
  '{event: "worktree_created", data: {type: "worktree_created", workspace: {workspace_id: "w3"}, worktree: {path: $p, branch: "docs/#71-openapi-examples", is_linked_worktree: true}}}')
HERDR_PLUGIN_EVENT_JSON=$evt run on_worktree_created.sh "y" "$root"
check "hook: gwm bootstrap on the event's worktree" "$(q gwm bootstrap "$(wt docs-71-openapi-examples)")" "$(calls)"
check "hook: gwm runs from inside that worktree" "$(wt docs-71-openapi-examples)" "$(cat "$S/cwd.log")"
check "hook: gwm gets no stdin (a trust prompt aborts, never reads a keystroke)" "" "$(cat "$S/stdin.log")"

HERDR_PLUGIN_EVENT_JSON='{"worktree":{"path":"/tmp"}}' run on_worktree_created.sh "" "$root"
check "hook: a payload without .data.worktree.path does nothing" "" "$(calls)"

exit "$fail"
