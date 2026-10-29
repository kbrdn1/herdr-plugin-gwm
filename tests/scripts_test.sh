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
cp tests/fixtures/gwm-types.txt "$S/types.txt"
cp tests/fixtures/gh-pr-list.txt "$S/gh.txt"
jq -r '.[].path' "$S/list.json" | while read -r p; do mkdir -p "$p"; done
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
  bootstrap) cat >"$STUB/stdin.log" ;;   # what a trust prompt would read
  list)  cat "$STUB/list.json" ;;
  path)  jq -c --arg p "$2" '[.[] | select(.name | contains($p))][0] // empty | {name, path, branch}' "$STUB/list.json" ;;
  review) # gwm materializes review/pr-<N>-<author>-<slug>: mirror that in the list
    n=$2 name="review-pr-$2-alice-fix"; d=$STUB/root/worktrees/acme-api/$name; mkdir -p "$d"
    jq --arg d "$d" --arg nm "$name" --arg b "review/pr-$n-alice-fix" --argjson pr "$n" \
      '. + [.[1] | .name = $nm | .id = $nm | .path = $d | .branch = $b | .issue = null | .pr = $pr]' \
      "$STUB/list.json" >"$STUB/list.tmp" && mv "$STUB/list.tmp" "$STUB/list.json" ;;
esac
[[ $1 == "${GWM_FAIL:-}" ]] && exit 1   # GWM_FAIL=<subcommand> makes that call fail
exit 0
EOF
# herdr is only reachable through $HERDR_BIN_PATH (what herdr injects; it does not
# touch PATH). The stub lives off PATH; a bare `herdr` hits the trap instead.
cat >"$S/herdr-bin/herdr" <<'EOF'
#!/usr/bin/env bash
out=$(printf '%q ' herdr "$@"); printf '%s\n' "${out% }" >>"$STUB/log"
[[ "$1 $2" == "worktree list" ]] && cat "$STUB/wt.json"
exit 0
EOF
cat >"$S/bin/herdr" <<'EOF'
#!/usr/bin/env bash
out=$(printf '%q ' BARE-herdr "$@"); printf '%s\n' "${out% }" >>"$STUB/log"
exit 1
EOF
cat >"$S/bin/fzf" <<'EOF'
#!/usr/bin/env bash
grep -m1 -F -- "${FZF_PICK:-}" || exit 1
EOF
cat >"$S/bin/gh" <<'EOF'
#!/usr/bin/env bash
out=$(printf '%q ' gh "$@"); printf '%s\n' "${out% }" >>"$STUB/log"
[[ "$1 $2" == "pr list" ]] && cat "$STUB/gh.txt"
exit 0
EOF
chmod +x "$S"/bin/* "$S/herdr-bin/herdr"

# The caller sits in a LINKED worktree workspace (w7, cwd = its checkout), not the
# root (w1): herdr rejects an open from there (linked_worktree_source), so adopts
# must target w1.
export STUB=$S PATH="$S/bin:$PATH" HERDR_PLUGIN_ROOT=$root HERDR_BIN_PATH=$S/herdr-bin/herdr \
  HERDR_PLUGIN_CONFIG_DIR=$S/config HERDR_WORKSPACE_ID=w7
unset FZF_DEFAULT_OPTS GWM_REVIEW_URL HERDR_PLUGIN_EVENT_JSON GWM_FAIL

# run <script> <stdin> [cwd] — fresh logs, then $rc / $S/log / $S/cwd.log
run() {
  : >"$S/log"; : >"$S/cwd.log"
  local cwd=${3:-$caller}
  (cd "$cwd" && HERDR_PLUGIN_CONTEXT_JSON="{\"workspace_cwd\":\"$cwd\"}" bash "$root/bin/$1" <<<"$2") >"$S/out" 2>&1
  rc=$?
}
calls() { cat "$S/log"; }
lines() { printf '%s\n' "$@"; }

# --- switch ------------------------------------------------------------------
FZF_PICK=fix-57 run switch.sh ""
check "switch: not open → adopt under the root workspace" "$(lines \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$caller")" \
  "$(q herdr worktree list --cwd "$caller")" \
  "$(q herdr worktree open --workspace w1 --path "$(wt fix-57-rate-limit-headers)" --label 'fix/#57-rate-limit-headers' --focus)")" "$(calls)"

FZF_PICK=chore-63 run switch.sh ""
check "switch: already open → workspace focus" "$(lines \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$caller")" \
  "$(q herdr workspace focus w7)")" "$(calls)"

printf 'open_mode = "tab"\n' >"$S/config/config.toml"
FZF_PICK=fix-57 run switch.sh ""
check "switch: open_mode=tab → tab create" \
  "$(q herdr tab create --workspace w7 --cwd "$(wt fix-57-rate-limit-headers)" --label 'fix/#57-rate-limit-headers' --focus)" \
  "$(tail -n1 "$S/log")"
rm -f "$S/config/config.toml"

# --- remove ------------------------------------------------------------------
FZF_PICK=fix-57 run remove.sh "n"
check "remove: N → nothing removed, nothing closed" "$(q gwm list --format=json)" "$(calls)"

FZF_PICK=chore-63 run remove.sh "y"
check "remove: y → map the workspace first, gwm remove, then workspace close" "$(lines \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$caller")" \
  "$(q gwm remove chore-63-bump-axum)" \
  "$(q herdr workspace close w7)")" "$(calls)"

# --- create ------------------------------------------------------------------
adopt57=$(q herdr worktree open --workspace w1 --path "$(wt fix-57-rate-limit-headers)" --label 'fix/#57-rate-limit-headers' --focus)
FZF_PICK=fix run create.sh $'57\nrate-limit-headers'
check "create: positional triple, resolved by issue, adopted" "$(lines \
  "$(q gwm types)" \
  "$(q gwm create fix 57 rate-limit-headers)" \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$caller")" \
  "$adopt57")" "$(calls)"

FZF_PICK=fix run create.sh $'57\n'
check "create: empty desc → gwm create --issue N --type T" \
  "$(q gwm create --issue 57 --type fix)" "$(sed -n 2p "$S/log")"
check "create: --issue path still adopts by issue" "$adopt57" "$(tail -n1 "$S/log")"

FZF_PICK=fix run create.sh $'057\n'
check "create: 057 resolves to issue 57 (numeric match)" "$adopt57" "$(tail -n1 "$S/log")"

FZF_PICK=fix run create.sh $'abc\nx'
check "create: non-digit issue → refused before gwm create" "$(q gwm types)" "$(calls)"
check "create: non-digit issue exits 1" "1" "$rc"

# --- review ------------------------------------------------------------------
GWM_REVIEW_URL='https://evil.com/o/r/pull/7' run review.sh ""
check "review: forged URL → nothing reaches gwm" "" "$(calls)"
check "review: forged URL exits 1" "1" "$rc"

GWM_REVIEW_URL='https://github.com/o/r/pull/7' run review.sh ""
check "review: link click → gwm review <N>, adopt the review worktree" "$(lines \
  "$(q gwm review 7)" \
  "$(q gwm list --format=json)" \
  "$(q herdr worktree list --cwd "$caller")" \
  "$(q herdr worktree open --workspace w1 --path "$(wt review-pr-7-alice-fix)" --label review/pr-7-alice-fix --focus)")" "$(calls)"

FZF_PICK=idempotency run review.sh ""
check "review: gh pr list picker → gwm review 9" \
  "$(lines "$(q gh pr list --limit 50)" "$(q gwm review 9)")" "$(sed -n 1,2p "$S/log")"

# --- gwm failures stop the script before herdr is touched ---------------------
GWM_FAIL=remove FZF_PICK=chore-63 run remove.sh "y"
check "remove: gwm remove fails → the workspace is NOT closed" \
  "$(q gwm remove chore-63-bump-axum)" "$(tail -n1 "$S/log")"
GWM_FAIL=create FZF_PICK=fix run create.sh $'57\nrate-limit-headers'
check "create: gwm create fails → nothing adopted" "$(q gwm create fix 57 rate-limit-headers)" "$(tail -n1 "$S/log")"
GWM_FAIL=review GWM_REVIEW_URL='https://github.com/o/r/pull/7' run review.sh ""
check "review: gwm review fails → nothing adopted" "$(q gwm review 7)" "$(calls)"
GWM_FAIL=clean run clean.sh "y"
check "clean: report fails → no --yes" "$(q gwm clean)" "$(calls)"

# --- exec / clean ------------------------------------------------------------
run exec.sh "git fetch --prune"
check "exec: the typed line runs through bash -c, as one argument" \
  "$(q gwm exec -- bash -c 'git fetch --prune')" "$(calls)"

run clean.sh "n"
check "clean: report only on N" "$(q gwm clean)" "$(calls)"
run clean.sh "y"
check "clean: y → report, then --yes" "$(lines "$(q gwm clean)" "$(q gwm clean --yes)")" "$(calls)"

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
