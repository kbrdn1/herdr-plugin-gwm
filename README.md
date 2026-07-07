# herdr-plugin-gwm — gwm worktrees in herdr

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![herdr](https://img.shields.io/badge/herdr-%E2%89%A5%200.7.0-8A63D2)](https://herdr.dev)
[![gwm](https://img.shields.io/badge/gwm-1.0-orange)](https://github.com/kbrdn1/gwm-cli)
[![shell](https://img.shields.io/badge/bash-glue--only-4EAA25?logo=gnubash&logoColor=white)](bin/)

A [herdr](https://herdr.dev) plugin that drives **[gwm](https://github.com/kbrdn1/gwm-cli)** for git worktree management from inside the multiplexer: create, switch, remove, review a PR, exec across worktrees, clean build artifacts, and a live dashboard. herdr reflects each worktree as a workspace.

**gwm stays the single source of truth.** The plugin never creates a worktree on the herdr side — it only *adopts* what gwm produced (`worktree open --path`) and closes the reflection when gwm removes it (`workspace close`). One source of truth, no divergence. See [the one rule](#the-one-rule).

```
╭──────────────────────────── switch to ❯ ─────────────────────────────╮
│ ▌ gwm-demo  ↑13 ↓758                                                 │
│ ▌ feat-35-embedded-lazygit  #35  ↑3                                  │
│ ▌ fix-2-beta  #2  ±                                                  │
│ ▌ docs-199-i18n  #199  PR#205  ↓5                                    │
│ ▌ feat-1-alpha  #1  ±                                                │
╰──────────────────────────────────────────────────────────────────────╯
```

## install

| Channel | Command |
|:--------|:--------|
| Marketplace | `herdr plugin install kbrdn1/herdr-plugin-gwm` |
| Dev (local checkout) | `herdr plugin link "$PWD"` |

There is no `[[build]]` step — it's plain bash, so `plugin link` and `plugin install` both wire it up with nothing to compile.

**Requirements:** herdr ≥ 0.7.0 · `gwm` on `PATH` ([gwm-cli](https://github.com/kbrdn1/gwm-cli)) · `jq` · `fzf` · `bash` · macOS / Linux.

## the 30-second tour

From any pane inside a herdr workspace that sits in a gwm-managed repo:

```bash
herdr plugin action invoke gwm.switch      # fzf over gwm worktrees → focus if open, else adopt
herdr plugin action invoke gwm.create      # branch type → issue → desc → gwm create → adopt
herdr plugin action invoke gwm.remove      # fzf → confirm → gwm remove → close the reflection
herdr plugin action invoke gwm.review      # fzf over `gh pr list` → gwm review → adopt
herdr plugin action invoke gwm.exec        # run a command across every worktree
herdr plugin action invoke gwm.clean       # report reclaimable artifacts → confirm → delete
herdr plugin action invoke gwm.dashboard   # gwm's live TUI in a pane
```

Bind them to a key in `~/.config/herdr/config.toml` (then `herdr server reload-config`):

```toml
[[keys.command]]
key = "prefix+ctrl+shift+g"
type = "plugin_action"
command = "gwm.switch"
description = "gwm: switch worktree"
```

## what it does

- **`gwm.create`** — fzf over `gwm types` (branch type) → issue number → description → runs `gwm create`, then resolves the new worktree by its **linked issue** (immune to description normalization; falls back to a fuzzy path lookup) and adopts it into herdr.
- **`gwm.switch`** — fzf over `gwm list --format=json` with live **badges** (issue `#N`, `PR#N`, dirty `±`, ahead `↑`, behind `↓`). If herdr already reflects the pick it just **focuses** the workspace; otherwise it **adopts** it — no duplicate workspaces.
- **`gwm.remove`** — fzf over removable worktrees (never the main checkout) → an explicit **confirm gate** (gwm's `remove` doesn't prompt) → `gwm remove` (branch kept, so the work stays recoverable) → `workspace close` to keep the sidebar in sync.
- **`gwm.review`** — fzf over `gh pr list` (or a plain PR-number prompt) → `gwm review <N>` materializes the PR as an isolated worktree → adopt. Also wired to a **link handler**: clicking a GitHub PR URL (`…/pull/N`) triggers it, passing the strictly-extracted PR *number* to gwm — never a raw or forged URL.
- **`gwm.exec` / `gwm.clean`** — `gwm exec -- <cmd>` fans a command across every worktree with a `✓/✗` rollup; `gwm clean` reports reclaimable build artifacts (`target/`, `node_modules/`, …) and deletes only git-ignored ones after a confirm.
- **`gwm.dashboard`** — surfaces gwm's own TUI in a zoomed pane: the live worktree table with PR/CI/dirty/ahead-behind badges, no reimplementation.
- **`worktree.created` event** — a worktree created on the herdr side (outside gwm) is enriched by `gwm bootstrap` (`.env` copy, hooks, preset). Adopts fire `worktree.opened`, not `.created`, so this never double-runs on the plugin's own work.
- **Adopt-only guardrail** — every mutation goes through `gwm`; herdr is a reflection. A source-level test asserts no script ever emits `worktree create` or `worktree open --branch` (see [tests](#testing)).
- **Root-workspace adoption** — adopts under the repo's *root* workspace, so invoking from inside a linked-worktree pane doesn't hit herdr's `linked_worktree_source` rejection.
- **Picker theming** — pickers inherit your `FZF_DEFAULT_OPTS` (colors, borders) by default, but neutralize file-browser-oriented bits (a `bat` preview, `ctrl-r` bound to `git ls-files`, `transform-header` on focus) that would garble non-file lines or rebind keys. Set `fzf_theme = "clean"` for a fully isolated picker.

## configuration

Presentation mode lives in the herdr-managed config dir — create `~/.config/herdr/plugins/config/gwm/config.toml` (or run `herdr plugin config-dir gwm` to find it):

```toml
# "workspace" (default) → adopt as a nested worktree workspace in the sidebar.
# "tab"                 → lighter: open a tab with the worktree cwd.
open_mode = "workspace"

# "user" (default) → inherit your FZF_DEFAULT_OPTS (colors/theme); the picker
#                    only neutralizes file-browser bits (bat preview, ctrl-r →
#                    git ls-files, transform-header on focus).
# "clean"          → drop FZF_DEFAULT_OPTS entirely for a bare, predictable picker.
fzf_theme = "user"
```

## the one rule

> The plugin never calls `herdr worktree create` or `worktree open --branch`.
> Creation / removal always goes through `gwm`; herdr only reflects via
> `worktree open --path` (adopt) and `workspace close` / `workspace focus`.

As long as that holds there is exactly one source of truth (gwm). Break it and herdr starts creating git worktrees outside gwm's control — two sources that drift. This is enforced, not just documented: `adopt_worktree` in [`lib/common.sh`](lib/common.sh) is the only path to herdr, and a grep-assert in the test suite fails the build if any script reaches around it.

## how it works

Glue-only bash. Each script is `gwm <cmd> --format=json` → transform with `jq` → `$HERDR_BIN_PATH <cmd>`. No business logic is duplicated; the plugin rides gwm's frozen 1.0 JSON contract, so the surface is stable by design.

```
gwm create <type> <issue> <desc>          # gwm owns creation
gwm list / path --format=json | jq        # read the source of truth
$HERDR_BIN_PATH worktree open --path …     # herdr adopts (never creates)
```

## testing

```bash
bash tests/common_test.sh    # pure-helper tests — no herdr/gwm instance needed
```

Covers the pure logic: context-cwd fallback, `open_mode` / `fzf_theme` resolution, PR-URL parsing (with forged-URL rejection), the gwm↔herdr path mapping (trailing-slash normalization), event-payload path extraction, and the adopt-only guardrail.

Dev loop:

```bash
herdr plugin link "$PWD"
herdr plugin action list --plugin gwm
herdr plugin log list --plugin gwm         # startup errors land here
# editing the manifest needs a relink (it's cached); script edits are picked up on next run:
herdr plugin unlink gwm && herdr plugin link "$PWD"
```

## design & reference

See [PLAN.md](PLAN.md) for the full design rationale and the complete herdr plugin API / gwm surface reference.

Multi-repo `gwm --workspace` mode isn't wired through the actions yet — the plugin operates on the single repo of the current workspace. Everything else (create / switch / remove / review / exec / clean / dashboard / bootstrap-on-create) is implemented.

## license

[MIT](LICENSE) © Kylian Bardini
