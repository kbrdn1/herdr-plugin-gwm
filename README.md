<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/_assets/promo.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/_assets/promo-light.png">
    <img alt="herdr-plugin-gwm: gwm worktrees inside herdr, gwm stays the source of truth and herdr adopts" src="docs/_assets/promo.png" width="100%">
  </picture>
</p>

# herdr-plugin-gwm — gwm worktrees in herdr

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![herdr](https://img.shields.io/badge/herdr-%E2%89%A5%200.7.4-8A63D2)](https://herdr.dev)
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

**Requirements:** herdr ≥ 0.7.4 (popup panes) · `gwm` on `PATH` ([gwm-cli](https://github.com/kbrdn1/gwm-cli); ≥ 1.10 to derive a worktree from an existing issue) · `jq` · `fzf` · `bash` · macOS / Linux.

## the 30-second tour

From any pane inside a herdr workspace that sits in a gwm-managed repo:

```bash
herdr plugin action invoke gwm.switch      # fzf over gwm worktrees → focus if open, else adopt
herdr plugin action invoke gwm.create      # branch type → issue → desc (empty = issue title) → gwm create → adopt
herdr plugin action invoke gwm.remove      # fzf → confirm → gwm remove → close the reflection
herdr plugin action invoke gwm.review      # fzf over `gh pr list` → gwm review → adopt
herdr plugin action invoke gwm.exec        # run a command across every non-main worktree
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

- **`gwm.create`** — fzf over `gwm types` (branch type) → issue number → description → runs `gwm create`. Leave the description **empty** and gwm derives it from the issue's title instead (`gwm create --issue <N> --type <type>`, gwm ≥ 1.10, needs the repo's forge reachable): nothing to retype, and an issue that already has a worktree is just adopted again. Cancel with Esc in the type picker. The plugin then resolves the new worktree by its **linked issue** (immune to description normalization) and adopts it into herdr. A typed description adds a fuzzy path lookup as fallback; an issue-derived one has none, so it needs a `branch_pattern` that carries `{issue}` (gwm's default does).
- **`gwm.switch`** — fzf over `gwm list --format=json` with live **badges** (issue `#N`, `PR#N`, dirty `±`, ahead `↑`, behind `↓`). If herdr already reflects the pick it just **focuses** the workspace; otherwise it **adopts** it — no duplicate workspaces.
- **`gwm.remove`** — fzf over removable worktrees (never the main checkout) → an explicit **confirm gate** (gwm's `remove` doesn't prompt) → `gwm remove` (branch kept, so the work stays recoverable) → `workspace close` to keep the sidebar in sync.
- **`gwm.review`** — fzf over `gh pr list` (or a plain PR-number prompt) → `gwm review <N>` materializes the PR as an isolated worktree → adopt. Also wired to a **link handler**: Ctrl-clicking a GitHub PR URL (`…/pull/N`) triggers it, passing the strictly-extracted PR *number* to gwm — never a raw or forged URL. herdr routes link clicks to plugins only while `ui.mouse_capture` is on (Ctrl on every platform, macOS included); with capture off, your terminal's own link shortcut opens the browser instead.
- **`gwm.exec` / `gwm.clean`** — `gwm exec -- <cmd>` fans a command across every non-main worktree with a `✓/✗` rollup; `gwm clean` reports, across the same non-main worktrees, reclaimable build artifacts (`target/`, `node_modules/`, …) and deletes only git-ignored ones after a confirm.
- **`gwm.dashboard`** — surfaces gwm's own TUI in a zoomed pane: the live worktree table with PR/CI/dirty/ahead-behind badges, no reimplementation.
- **`worktree.created` event** — a worktree created on the herdr side (outside gwm) is enriched by `gwm bootstrap` (`.env` copy, hooks, preset), run from inside that worktree so gwm uses its repo's `.gwm.toml` (herdr starts hooks in the plugin dir). The path comes from the event envelope (`.data.worktree.path`). Adopts fire `worktree.opened`, not `.created`, so this never double-runs on the plugin's own work.
- **Adopt-only guardrail** — every mutation goes through `gwm`; herdr is a reflection. A source-level test asserts no script ever emits `worktree create` or `worktree open --branch` (see [tests](#testing)).
- **Root-workspace adoption** — adopts under the repo's *root* workspace, so invoking from inside a linked-worktree pane doesn't hit herdr's `linked_worktree_source` rejection.
- **Popup pickers** — `gwm.switch` and `gwm.remove` open as a session-modal floating popup (herdr ≥ 0.7.4): the tiled layout doesn't move, Escape reaches fzf, and the popup closes when the script exits. The panes whose *output* is the point (`exec`, `clean`) or that run long git/network work (`create`, `review`) stay split — a modal that blocks the session for a 30s clone reads as frozen. `dashboard` stays zoomed. Placement and size (`width`/`height`) are declared once, on the `[[panes]]` entrypoint; the popup actions pass no `--placement`, which would override it.
- **Picker theming** — pickers inherit your `FZF_DEFAULT_OPTS` (colors, borders) by default, but neutralize file-browser-oriented bits (a `bat` preview, `ctrl-r` bound to `git ls-files`, `transform-header` on focus) that would garble non-file lines or rebind keys. Set `fzf_theme = "clean"` for a fully isolated picker.

## plugin or `gwm herdr`?

gwm ≥ 1.10 ships its own [`gwm herdr <pattern>`](https://github.com/kbrdn1/gwm-cli). Both open a gwm worktree inside herdr and neither creates anything on the herdr side; they differ in what herdr ends up holding, so keep both.

| | plugin, `open_mode = "workspace"` (default) | plugin, `open_mode = "tab"` | `gwm herdr <pattern>` |
|:--|:--|:--|:--|
| herdr call | `worktree open --path` under the repo's root workspace | `tab create --workspace <current> --cwd` | `tab create --workspace <current> --cwd`, or `pane split --current` with `-p` / `--direction` |
| you get | a **workspace** of its own, grouped under the repo in the sidebar, with git checkout provenance | a tab in the current workspace | a tab, or a split pane, in the current workspace |
| picking | fzf with badges; focuses it if already open | fzf with badges; a new tab each time | a fuzzy name you type, or the `t` key in gwm's TUI |
| after `gwm.remove` | its workspace is closed | the tab stays open | the tab / pane stays open |
| needs | the plugin | the plugin | only gwm, run from a herdr pane (`$HERDR_ENV`) |

Use the **plugin** when the worktree is a unit of work you switch to and back from (an agent per worktree, its own tabs and panes): it lands in the repo's worktree group, `gwm.switch` never opens a duplicate, and `gwm.remove` takes the reflection down with it. Use **`gwm herdr`** to look at a worktree next to what you're doing, from a shell, a script or gwm's TUI: no plugin, no picker, nothing left in the sidebar.

One trap: gwm's TUI setting `[tui] mux_open_in = "workspace"` runs `herdr workspace create`, a plain top-level workspace that herdr does **not** group as a worktree of the repo. The grouped workspace is the plugin's default.

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
gwm create --issue <N> --type <type>      #   …or derives the slug from the issue title
gwm list / path --format=json | jq        # read the source of truth
$HERDR_BIN_PATH worktree open --path …     # herdr adopts (never creates)
```

## testing

```bash
bash tests/common_test.sh    # pure-helper tests — no herdr/gwm instance needed
bash tests/scripts_test.sh   # bin/*.sh against stub gwm / herdr / fzf / gh
shellcheck bin/*.sh lib/*.sh # config in .shellcheckrc (follows the lib/common.sh source)
```

`scripts_test.sh` runs every script with stub `gwm` / `fzf` / `gh` first on `PATH` and a stub herdr reachable only through `$HERDR_BIN_PATH` (a bare `herdr` hits a failing trap), fed from `tests/fixtures/` (real gwm 1.11 `list` / `types` output with paths rewritten; herdr's `worktree list` and `gh pr list` built from their documented formats), and asserts the exact argv each one sends to gwm and herdr: switch (adopt / focus / tab), remove (N / y), create (positional, `--issue`, `057`, bad issue), review (forged URL, link click, `gh` picker), exec, clean, and the `worktree.created` hook (bootstrap run from inside the worktree).

`common_test.sh` covers the pure logic: context-cwd fallback, `open_mode` / `fzf_theme` resolution, the fzf wrapper (theme inheritance, and surviving `set -u` without `FZF_DEFAULT_OPTS`), PR-URL parsing (with forged-URL rejection), the gwm↔herdr path mapping (trailing-slash normalization), event-payload path extraction (from herdr's event envelope, flat shapes rejected), the argv `adopt_worktree` sends to a stub herdr (root-workspace resolution, `worktree open --path`, `open_mode = "tab"`), and the adopt-only guardrail.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs shellcheck and both suites on every pull request and on pushes to `dev` and `main`.

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
