# herdr-plugin-gwm — plan d'implémentation

Plugin herdr qui branche **gwm** (gestionnaire de worktrees, `gwm-cli`) sur
**herdr** (multiplexer terminal à agents). Repo séparé, publiable au marketplace
herdr (topic github `herdr-plugin`).

Ce document est self-contained : toute la surface API herdr + gwm nécessaire est
recopiée ici, pas besoin de re-fetcher la doc.

---

## 0. Décision d'architecture (déjà tranchée)

**gwm est la source de vérité. herdr est un reflet UI.**

Preuve que c'est faisable sans conflit — la CLI core herdr expose une commande
d'**adoption** d'un checkout existant (vérifié dans `src/cli/worktree.rs` du core) :

```
herdr worktree open [--workspace ID | --cwd PATH] (--path PATH | --branch NAME) [--label TEXT] [--focus] [--json]
```

Avec `--path`, herdr **adopte un worktree déjà créé sur le disque** — il ne crée
rien. C'est exactement le pattern des deux plugins de référence :
- `devashish2203/herdr-worktrunk` : `wt` crée le worktree → `herdr worktree open --path`
- `NathanFlurry/herdr-plugin-jj-workspace` : `jj workspace add` crée → `herdr workspace create --cwd`

gwm joue le rôle de `worktrunk`, en mieux (bootstrap, presets, guards, exec,
clean, badges PR/CI, workspace multi-repo, daemon).

### La règle unique (garde-fou anti double-source-de-vérité)

> Le plugin n'appelle **JAMAIS** `herdr worktree create` ni `herdr worktree open --branch`.
> Toute création / suppression / mutation passe par `gwm`.
> herdr ne fait que **refléter** : `worktree open --path` (adopter) et `workspace close` (fermer).

Tant que cette ligne tient, il n'y a qu'une source de vérité (gwm). Si on la
casse, herdr crée des git worktrees hors du contrôle de gwm → deux sources qui
divergent.

---

## 1. Surface API plugin herdr (les fonctionnalités dispo)

Un plugin = un dossier avec `herdr-plugin.toml` + des commandes argv (n'importe
quel langage). « The entire herdr CLI is the plugin API. » Pas de SDK. Le plugin
rappelle herdr via `$HERDR_BIN_PATH`. herdr ≥ 0.7.0.

### 1.1 Sections du manifest `herdr-plugin.toml`

| Section | Rôle | Champs |
|---|---|---|
| top-level | métadonnées | `id`, `name`, `version`, `min_herdr_version` (requis), `description`, `platforms` |
| `[[build]]` | commandes d'install (github seulement, pas `link`) | `command` (argv), `platforms` |
| `[[actions]]` | entrées invocables | `id`, `title`, `contexts`, `command`, `platforms` |
| `[[events]]` | hooks lifecycle | `on` (nom d'event), `command`, `platforms` |
| `[[panes]]` | panneaux UI | `id`, `title`, `placement`, `command`, `platforms` |
| `[[link_handlers]]` | interception d'URL cliquées | `id`, `title`, `pattern` (regex Rust), `action` |
| `[[keys.command]]` | raccourcis (dans le config herdr, pas le manifest) | `key`, `type="plugin_action"`, `command="plugin.id.action"`, `description` |

Notes :
- `command` = tableau argv, **pas de shell** (pas d'expansion). Pour du shell :
  `["bash","-c","..."]`.
- ids d'action/pane/link_handler : pas de `.` (le point est réservé à la
  qualification `plugin.id.action`).
- platforms item-level override le top-level.

### 1.2 Contexts d'action valides (enum `PluginActionContext`)

`global`, `workspace`, `tab`, `pane`, `selection`.
→ une action `contexts = ["workspace","global"]` est proposée depuis un workspace
ou globalement.

### 1.3 Placements de pane

`overlay` (défaut, zoomé temporaire, restaure le focus en fermant), `split`,
`tab`, `zoomed`. Un `plugin pane open --placement ...` peut override le manifest.

### 1.4 Events éligibles pour `[[events]] on = "..."` (extraits du core)

```
worktree.created   worktree.opened   worktree.removed
workspace.created  workspace.closed  workspace.focused  workspace.updated
tab.created        tab.closed        tab.focused
pane.created       pane.closed       pane.exited        pane.focused   pane.spawned
session.created    session.idle      session.status     session.updated
layout.updated     terminal.closed
```

### 1.5 Variables d'env injectées dans les commandes runtime

`HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_ENV=1`, `HERDR_PLUGIN_ID`,
`HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_CONFIG_DIR`, `HERDR_PLUGIN_STATE_DIR`,
`HERDR_PLUGIN_CONTEXT_JSON`, et selon dispo `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`,
`HERDR_PANE_ID`.
- actions : + `HERDR_PLUGIN_ACTION_ID`
- events : + `HERDR_PLUGIN_EVENT`, `HERDR_PLUGIN_EVENT_JSON`
- panes : + `HERDR_PLUGIN_ENTRYPOINT_ID`
- link handlers : + `HERDR_PLUGIN_CLICKED_URL`, `HERDR_PLUGIN_LINK_HANDLER_ID`,
  et `invocation_source="link_click"` dans le context JSON

### 1.6 Forme de `HERDR_PLUGIN_CONTEXT_JSON` (struct `PluginInvocationContext`)

```
workspace_id, workspace_label, workspace_cwd,
worktree { ... },
tab_id, tab_label,
focused_pane_id, focused_pane_cwd, focused_pane_agent, focused_pane_status,
selected_text, invocation_source, clicked_url, link_handler_id
```
Champs absents = non fournis pour cette invocation. En bash : `jq -r '.workspace_cwd // .focused_pane_cwd'`.

### 1.7 Rangement des fichiers (v1 : pas de storage API herdr)

- `HERDR_PLUGIN_ROOT` : le checkout du plugin — **read-only**, pas d'état durable ici.
- `HERDR_PLUGIN_CONFIG_DIR` : config user éditable (`.env`, `config.toml`).
- `HERDR_PLUGIN_STATE_DIR` : état runtime local.

### 1.8 Commandes herdr qu'on va consommer (via `$HERDR_BIN_PATH`)

```
herdr worktree open --path PATH --label TEXT --focus [--json]   # ADOPTER (jamais --branch)
herdr worktree list [--cwd PATH] [--json]                        # mapping path -> open_workspace_id
herdr workspace create --cwd PATH --label TEXT --focus           # alt. au worktree open (mode workspace top-level)
herdr workspace close <workspace_id>                             # fermer le reflet après gwm remove
herdr tab create --workspace ID --cwd PATH --label TEXT --focus  # mode léger (open_mode=tab)
herdr pane run <pane_id> <command>                               # envoyer une cmd dans un shell interactif
herdr pane list / pane close                                     # nettoyage panes orphelins
herdr plugin pane open --plugin ID --entrypoint ID --placement split --cwd PATH --focus
```

### 1.9 CLI de gestion du plugin (dev loop)

```
herdr plugin link <path>        # dev local (ne build pas)
herdr plugin unlink <id>        # relink obligatoire après édition du manifest
herdr plugin list [--json]
herdr plugin action list/invoke
herdr plugin pane open ...
herdr plugin log list --plugin <id> [--limit N]   # debug
herdr plugin config-dir <id>
herdr server reload-config       # après édition des keybindings
herdr plugin install owner/repo  # prod (build + preview trust)
```

### 1.10 Trust / sécurité (modèle herdr)

trust-by-disclosure, **pas de sandbox**. Ce qui nous concerne :
1. manifest + scripts courts et auditables (l'install montre un preview).
2. **le `link_handler` exécute sur clic d'URL** → ancrer le regex strictement
   (`^...$`), extraire le numéro, passer **le numéro** à `gwm review`, jamais
   l'URL brute. Sinon une URL forgée dans un log peut déclencher une action.

---

## 2. Surface gwm à utiliser (source de vérité — vérifié sur `gwm --help`)

```
gwm create <BRANCH_TYPE> <ISSUE> <DESC> [--repo NAME] [--workspace DIR]   # crée wt + branche + bootstrap. PAS de --format json.
gwm path <PATTERN> --format=json          # -> { name, path, branch }   ← récupérer le path après create
gwm list --format=json                    # table worktrees + badges (schema docs/schema/)
gwm status                                # issue/PR link + statut GitHub live (CI)
gwm review <PR#>                           # matérialise une PR en worktree isolé
gwm remove <PATTERN>                       # supprime un worktree
gwm bootstrap                              # re-run bootstrap (.env, hooks, preset)
gwm exec -- <cmd>                          # fan-out séquentiel sur tous les worktrees
gwm clean [--yes]                          # reclaim build artifacts
gwm statusline                             # résumé une ligne
gwm daemon                                 # JSON-RPC 2.0 sur socket unix (subscribe -> live)
gwm --workspace <DIR> ...                  # mode multi-repo (colonne REPO)
```

Flux create canonique :
```bash
gwm create "$type" "$issue" "$desc"
read -r path branch < <(gwm path "$desc" --format=json | jq -r '"\(.path) \(.branch)"')
"$HERDR_BIN_PATH" worktree open --path "$path" --label "$branch" --focus
```

---

## 3. Architecture du plugin

- **Langage : bash pur** (comme worktrunk). `jq` pour parser, `fzf` pour les
  pickers. Pas de binaire Rust : gwm a déjà son TUI, inutile de porter un modal
  comme l'a fait jj-workspace. Rung le plus bas qui tient.
- **Glue-only** : chaque script = `gwm <cmd> [--format=json]` → transforme →
  `$HERDR_BIN_PATH <cmd>`. Zéro logique métier dupliquée. On bâtit sur le
  contrat json gelé 1.0 de gwm → surface stable par design.
- **open_mode configurable** (comme worktrunk) dans
  `$HERDR_PLUGIN_CONFIG_DIR/config.toml` :
  - `workspace` (défaut) → `herdr worktree open --path` : le worktree apparaît
    comme worktree workspace nested dans la sidebar. C'est le bon match (les
    worktrees gwm sont de vrais git worktrees liés au repo).
  - `tab` → `herdr tab create --cwd` + `gwm` dans le shell : plus léger.

### Prérequis runtime
herdr ≥ 0.7.0 · `gwm` sur PATH · `jq` · `fzf` · `bash` · plateformes macos/linux.

---

## 4. Plan d'implémentation phasé (MVP d'abord)

> **Statut (v0.2.0)** : phases 1-4 **implémentées** (create/switch/remove/review/exec/clean/dashboard + link_handler PR + event `worktree.created`). Seul reliquat : le mode multi-repo `gwm --workspace` n'est pas câblé dans les actions.

### Phase 1 — MVP : create / switch / remove  ← commencer ici
- [ ] `herdr-plugin.toml` : métadonnées + 3 actions (`create`, `switch`,
      `remove`, contexts `["workspace","global"]`) + 2 panes picker/remover.
- [ ] `lib/common.sh` : helpers partagés — `herdr_bin`, `ctx_cwd` (jq sur
      `HERDR_PLUGIN_CONTEXT_JSON`), `gwm_json`, `open_mode`, et le **garde-fou**
      (fonction unique `adopt_worktree <path> <label>` qui n'appelle que
      `worktree open --path`).
- [ ] `bin/create.sh` : prompt type/issue/desc (ou fzf sur `gwm types`) →
      `gwm create` → `gwm path --format=json` → `adopt_worktree`.
- [ ] `bin/switch.sh` : `gwm list --format=json` → fzf (afficher name + badges
      issue/PR/CI) → si déjà ouvert `workspace focus`, sinon `adopt_worktree`.
- [ ] `bin/remove.sh` : fzf sur worktrees removable → `gwm remove` → mapper le
      path vers `open_workspace_id` (`herdr worktree list --cwd $PWD --json`) →
      `herdr workspace close`.
- [ ] Keybindings recommandés dans le README (override `prefix+shift+g` natif).
- [ ] Tests bash des helpers (parsing json, garde-fou, open_mode).

### Phase 2 — intégration GitHub / PR
- [ ] `bin/review.sh` : prompt PR# (ou fzf `gh pr list`) → `gwm review <PR#>` →
      `gwm path --format=json` → `adopt_worktree`.
- [ ] `[[link_handlers]]` sur `^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$` →
      action `review`. Extraire le N depuis `HERDR_PLUGIN_CLICKED_URL`, passer N
      (pas l'URL) à `gwm review`. Test du parsing + du garde-fou d'URL.

### Phase 3 — bootstrap & sens inverse
- [ ] `[[events]] on = "worktree.created"` → `gwm bootstrap` sur le path de
      l'event (enrichit un worktree créé côté herdr natif). Optionnel — à ne
      faire que si on veut supporter la création hors-gwm. Sinon documenter :
- [ ] **sens gwm → herdr sans plugin** : un hook post-create dans `.gwm.toml`
      (`herdr worktree open --path <path>`) suffit. Le documenter dans le README,
      ne pas le dupliquer dans le plugin.

### Phase 4 — vue live & ops (avancé, YAGNI tant que pas demandé)
- [ ] pane `dashboard` (placement `split`/`overlay`) : lance le TUI gwm, ou une
      vue custom alimentée par `gwm daemon` (subscribe) → badges PR/CI/diff en
      live sans polling. C'est le différenciateur vs worktrunk/jj.
- [ ] actions `exec` (`gwm exec -- <cmd>`) et `clean` (`gwm clean`).
- [ ] support `--workspace` (multi-repo) : détecter le mode et passer `--repo`.

---

## 5. Structure du repo

```
herdr-plugin-gwm/
  herdr-plugin.toml          # manifest
  lib/
    common.sh                # helpers + garde-fou adopt_worktree
  bin/
    create.sh
    switch.sh
    remove.sh
    review.sh                # phase 2
  config.sh                  # lecture open_mode
  tests/
    common_test.sh           # helpers purs (json, garde-fou, url parse)
  README.md                  # install, keybindings, open_mode, prérequis
  LICENSE                    # MIT
  .gitignore
```

Pas de `[[build]]` (bash, rien à compiler) → `plugin link` marche direct, et
`plugin install` github ne build rien non plus.

---

## 6. Tests (repo séparé, pas la CI gwm)

Suivre le modèle worktrunk (`tests/*.sh`, assertions bash) : tester les
**fonctions pures** sans instance herdr :
- parsing de `HERDR_PLUGIN_CONTEXT_JSON` (cwd fallback),
- extraction du numéro de PR depuis une URL (+ rejet d'URL forgée),
- résolution `open_mode`,
- le garde-fou : vérifier qu'aucun chemin de code n'émet `worktree create` /
  `--branch` (grep-assert dans le test).

Les scripts qui appellent herdr/gwm ne sont pas testables sans binaires → tester
l'intention (argv construits) via un `HERDR_BIN_PATH` mock qui echo ses args.

---

## 7. Dev loop

```bash
herdr plugin link "$PWD"
herdr plugin action list --plugin gwm
herdr plugin action invoke gwm.switch
herdr plugin log list --plugin gwm        # debug
# après édition du manifest : relink obligatoire (le manifest est caché)
herdr plugin unlink gwm && herdr plugin link "$PWD"
# les édits de scripts bash sont pris au prochain run (pas de relink)
```

Publication : topic github `herdr-plugin` → apparaît au marketplace ;
`herdr plugin install kbrdn1/herdr-plugin-gwm`.

---

## 8. Références

- Core herdr : `ogulcancelik/herdr` — CLI dans `src/cli/`, worktree open dans
  `src/cli/worktree.rs`, schema plugin dans `src/api/schema/plugins.rs`, doc dans
  `website/src/content/docs/{plugins,cli-reference,socket-api}.mdx`.
- Plugin de référence #1 (cas exact) : `devashish2203/herdr-worktrunk` (bash).
- Plugin de référence #2 : `NathanFlurry/herdr-plugin-jj-workspace` (rust).
- Exemples officiels : `ogulcancelik/herdr-plugin-examples`.
- gwm : `/Users/kbrdn1/Projects/Perso/gwm-cli` (source de vérité, contrat json 1.0).
```
