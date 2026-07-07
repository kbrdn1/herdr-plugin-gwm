# herdr-plugin-gwm

A [herdr](https://herdr.dev) plugin that drives **[gwm](https://github.com/kbrdn1/gwm-cli)**
for git worktree management. gwm stays the source of truth; herdr adopts the
worktrees gwm creates and reflects them as workspaces.

Why gwm and not herdr's built-in worktrees: gwm does far more — bootstrap
(`.env` copy, hooks, guards, no-symlink), stack presets, `exec` fan-out,
`clean`, PR/CI badges, multi-repo workspace mode, and a JSON-RPC daemon. This
plugin wires all of that into herdr without herdr ever owning a worktree.

Status: **WIP** — see [PLAN.md](PLAN.md) for the full implementation plan and
the complete herdr plugin API / gwm surface reference. Phase 1 (create / switch
/ remove) is the current target.

## Requirements

- herdr ≥ 0.7.0
- `gwm` on PATH ([gwm-cli](https://github.com/kbrdn1/gwm-cli))
- `jq`, `fzf`, `bash`
- macOS / Linux

## Dev loop

```bash
herdr plugin link "$PWD"
herdr plugin action list --plugin gwm
bash tests/common_test.sh          # pure-helper tests, no herdr needed
# after editing herdr-plugin.toml, relink (the manifest is cached):
herdr plugin unlink gwm && herdr plugin link "$PWD"
```

## The one rule

The plugin never calls `herdr worktree create` or `worktree open --branch`.
Creation/removal always goes through `gwm`; herdr only reflects via
`worktree open --path` (adopt) and `workspace close`. See PLAN.md §0.

## License

[MIT](LICENSE) © Kylian Bardini
