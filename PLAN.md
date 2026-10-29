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
herdr worktree open [--workspace ID | --cwd PATH] (--path PATH | --branch NAME) [--label TEXT] [--focus] [--no-focus] [--trust-repository]
```

(sortie toujours JSON ; `--json` est un no-op de compat, masqué depuis 0.8.0.
`--trust-repository` (0.9.0) ne sert que pour un repo appartenant à un autre user.)

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
rappelle herdr via `$HERDR_BIN_PATH`. herdr ≥ 0.7.4.

### 1.1 Sections du manifest `herdr-plugin.toml`

| Section | Rôle | Champs |
|---|---|---|
| top-level | métadonnées | `id`, `name`, `version`, `min_herdr_version` (requis), `description`, `platforms` |
| `[[build]]` | commandes d'install (github seulement, pas `link`) | `command` (argv), `platforms` |
| `[[startup]]` | one-shot au démarrage du serveur (0.7.5+, non utilisé ici) | `command`, `platforms` |
| `[[actions]]` | entrées invocables | `id`, `title`, `contexts`, `command`, `platforms` |
| `[[events]]` | hooks lifecycle | `on` (nom d'event), `command`, `platforms` |
| `[[panes]]` | panneaux UI | `id`, `title`, `placement`, `width`/`height` (popup only), `command`, `platforms` |
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

`overlay` (défaut, zoomé temporaire, restaure le focus en fermant), `popup`,
`split`, `tab`, `zoomed`. Un `plugin pane open --placement ...` peut override le
manifest.

`popup` (herdr ≥ 0.7.4) = terminal flottant **session-modal** : ne touche pas au
layout tuilé, reçoit tout l'input (Escape inclus), se ferme quand la commande
sort ou sur `popup.close`. Taille via `width`/`height` dans le manifest —
cellules (entier) ou pourcentage (`"80%"`), clampé à un minimum ; omis = moitié
d'écran. Ce n'est **pas** une pane herdr : pas de `HERDR_PANE_ID`, pas d'events
de lifecycle, absent des APIs pane/layout/agent — la pane tuilée sous-jacente
reste lisible via `HERDR_PLUGIN_CONTEXT_JSON`. Ouvrir un popup pendant Settings
ou copy-mode renvoie `ui_busy`.

⚠️ `plugin pane open --help` ne liste ni `popup` ni `--width`/`--height`, mais le
parser les accepte depuis 0.7.4 (`src/cli/plugin.rs`). Côté serveur,
`--placement` override celui du manifest, et une taille omise retombe sur celle
du manifest (`params.width.or(pane.width)`). `--width`/`--height` avec un
placement non-popup → `invalid_params`. → on déclare placement + taille une
seule fois sur l'entrypoint, et les actions popup ne passent pas `--placement`.

### 1.4 Events éligibles pour `[[events]] on = "..."` (`PLUGIN_HOOK_EVENT_KINDS`, 0.9.5)

```
worktree.created   worktree.opened    worktree.removed
workspace.created  workspace.updated  workspace.closed  workspace.renamed
workspace.moved    workspace.reordered workspace.focused
tab.created        tab.closed         tab.renamed       tab.moved   tab.focused
pane.created       pane.closed        pane.focused      pane.moved  pane.exited
pane.agent_detected pane.agent_status_changed
```

Les events à fort volume (`pane.output_changed`, `pane.updated`,
`layout.updated`, `workspace.metadata_updated`) sont exclus des hooks. Un nom
inconnu donne un warning `unknown event` au link.

`HERDR_PLUGIN_EVENT_JSON` = l'**enveloppe** sérialisée, même forme de 0.7.4 à
0.9.5 — le chemin est dans `.data.worktree.path` :

```json
{"event":"worktree_created","data":{"type":"worktree_created",
 "workspace":{…},"worktree":{"path":"…","branch":"…","open_workspace_id":"…",…}}}
```

⚠️ Dans le JSON, `event` est en snake_case (`worktree_created`, `EventKind` en
`rename_all = "snake_case"`). Le nom pointé du manifest (`worktree.created`)
n'arrive que par `HERDR_PLUGIN_EVENT`.

Les hooks tournent avec le **dossier du plugin** comme cwd : tout outil qui
découvre son repo depuis le cwd (gwm) doit être lancé depuis le worktree visé.

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

### 1.8 Commandes herdr consommées (via `$HERDR_BIN_PATH`)

```
herdr worktree open [--workspace ROOT] --path PATH --label TEXT --focus  # ADOPTER (jamais --branch)
herdr worktree list --cwd PATH                                    # root ws + mapping path -> open_workspace_id (JSON)
herdr workspace focus <workspace_id>                              # switch : déjà reflété → focus
herdr workspace close <workspace_id>                              # fermer le reflet après gwm remove (worktree lié : pas de --group, réservé au primaire depuis 0.9.0)
herdr tab create [--workspace ID] --cwd PATH --label TEXT --focus # mode léger (open_mode=tab)
herdr plugin pane open --plugin ID --entrypoint ID [--placement split|zoomed --direction down] --cwd PATH [--env K=V] --focus
```

Non utilisées (écartées) : `workspace create` (un workspace top-level non
groupé, cf. README « plugin or gwm herdr? »), `pane run` / `pane list` /
`pane close` (aucun nettoyage de panes à faire).

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
   Déclenchement : Ctrl-clic (sur toutes les plateformes), seulement avec
   `ui.mouse_capture` actif ; depuis 0.9.4 les handlers passent avant
   l'ouverture navigateur. Depuis 0.9.0 ils reçoivent aussi les clics OSC 8
   `file://` qui matchent — notre regex `https://github.com/…` les exclut.

---

## 2. Surface gwm à utiliser (source de vérité — vérifié sur `gwm --help`, gwm 1.11.0)

```
gwm create <BRANCH_TYPE> <ISSUE> <DESC>   # crée wt + branche + bootstrap. PAS de --format json.
gwm create --issue <N> [--type T]         # (1.10+) triple dérivé d'une issue existante : desc = titre,
                                          #   type = labels (ou --type) ; déjà un worktree → affiché, exit 0
gwm types                                 # types de branche (1re colonne → picker)
gwm path <PATTERN> --format=json          # -> { name, path, branch }
gwm list --format=json                    # docs/schema/worktree-list.schema.json ; champs lus :
                                          #   name, path, branch, issue, pr, is_main, status.{is_dirty,ahead,behind}
gwm review <PR#>                          # PR → worktree review/pr-<N>-<author>-<slug>, sans bootstrap par défaut
gwm remove <PATTERN>...                   # ne demande PAS de confirmation (le plugin la fait), branche gardée
gwm bootstrap [TARGET]                    # re-run bootstrap ; lit .gwm.toml depuis le repo du CWD
gwm exec -- <cmd>                         # fan-out sur les worktrees NON-main (rollup ✓/✗)
gwm clean [--yes]                         # rapport (puis suppression des dossiers git-ignorés), non-main
gwm herdr <PATTERN> [-p|--direction D]    # (1.10+) ouvre en onglet / pane herdr — cf. README « plugin or gwm herdr? »
gwm status / statusline / daemon          # non utilisés (le dashboard est le TUI gwm)
gwm --workspace <DIR> ...                 # mode multi-repo (colonne REPO) — non câblé
```

Flux create réel (`bin/create.sh`) :
```bash
gwm create "$type" "$issue" "$desc"            # ou, desc vide : gwm create --issue "$issue" --type "$type"
row=$(gwm list --format=json | jq -c --arg i "$issue" 'map(select((.issue|tostring) == $i)) | last // empty')
# repli (desc saisie seulement) si aucune ligne ne porte l'issue : gwm path "$desc" --format=json
adopt_worktree "$path" "$branch"               # → herdr worktree open --path … (jamais --branch)
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
  - `tab` → `herdr tab create --cwd` (un shell dans le worktree, rien n'y est lancé) : plus léger.

### Prérequis runtime
herdr ≥ 0.7.4 (panes popup) · `gwm` sur PATH (≥ 1.10 pour `create --issue`,
qui a aussi besoin de la forge du repo) · `jq` · `fzf` · `bash` · plateformes
macos/linux.

---

## 4. Plan d'implémentation phasé (MVP d'abord)

> **Statut (`dev`, manifest 0.2.0)** : phases 1-4 **implémentées** (create/switch/remove/review/exec/clean/dashboard + link_handler PR + event `worktree.created`, opérant depuis la PR #7). Reliquats : le mode multi-repo `gwm --workspace` n'est pas câblé, et le hook post-create `.gwm.toml` (sens gwm → herdr sans plugin, phase 3) n'est pas documenté. La voie sans plugin documentée est `gwm herdr` (onglet / pane).

### Phase 1 — MVP : create / switch / remove
- [x] `herdr-plugin.toml` : métadonnées + actions `create`/`switch`/`remove`
      (contexts `["workspace","global"]`, `remove` en `["workspace"]`) + panes
      `creator` (split), `picker`/`remover` (popup 70 %×60 %).
- [x] `lib/common.sh` : `herdr_bin`, `ctx_cwd`, `open_mode`, `fzf_theme`,
      `wt_fzf`, `herdr_ws_id_for_path`, `event_worktree_path`,
      `pr_number_from_url`, et le **garde-fou** `adopt_worktree <path> <label>`
      (seul chemin vers herdr : `worktree open --path` ou `tab create --cwd`).
- [x] `bin/create.sh` : fzf sur `gwm types` → issue → desc (vide = `gwm create
      --issue`, gwm ≥ 1.10) → `gwm create` → résolution par l'issue dans
      `gwm list` (repli `gwm path`) → `adopt_worktree`.
- [x] `bin/switch.sh` : `gwm list --format=json` → fzf (badges issue/PR/±/↑/↓,
      pas de CI : il faudrait un appel réseau par worktree) → `workspace focus`
      si déjà ouvert, sinon `adopt_worktree`.
- [x] `bin/remove.sh` : fzf sur les worktrees non-main → **confirmation** (gwm
      ne demande pas) → mapper le path vers `open_workspace_id` AVANT → `gwm
      remove` (branche gardée) → `herdr workspace close`.
- [x] Keybinding d'exemple dans le README (`prefix+ctrl+shift+g` → `gwm.switch`).
- [x] Tests bash des helpers (cf. §6).

### Phase 2 — intégration GitHub / PR
- [x] `bin/review.sh` : fzf `gh pr list` (ou prompt PR#) → `gwm review <PR#>` →
      résolution par le préfixe de branche `review/pr-<N>` (repli `gwm path`) →
      `adopt_worktree`.
- [x] `[[link_handlers]]` sur `^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$` →
      action `review`. L'action lit `clicked_url` du context JSON et le passe en
      `--env GWM_REVIEW_URL` ; `review.sh` extrait N (`pr_number_from_url`) et ne
      passe que N à gwm. Testé (URL valide + rejets).

### Phase 3 — bootstrap & sens inverse
- [x] `[[events]] on = "worktree.created"` → `gwm bootstrap` sur
      `.data.worktree.path`, lancé **depuis** le worktree (le hook démarre dans
      le dossier du plugin). Inopérant jusqu'à la PR #7 (mauvais champ + mauvais cwd).
- [ ] **sens gwm → herdr sans plugin** : un hook post-create dans `.gwm.toml`
      (`herdr worktree open --path <path>`) suffirait. Pas documenté. Depuis
      gwm 1.10, `gwm herdr` couvre le besoin onglet/pane sans plugin.

### Phase 4 — vue live & ops
- [x] pane `dashboard` (placement `zoomed`) : lance le TUI gwm tel quel. Une vue
      custom sur `gwm daemon` reste YAGNI tant que le TUI suffit.
- [x] actions `exec` (`gwm exec -- bash -c <cmd>`) et `clean` (rapport →
      confirmation → `gwm clean --yes`).
- [ ] support `--workspace` (multi-repo) : détecter le mode et passer `--repo`.

---

## 5. Structure du repo

```
herdr-plugin-gwm/
  herdr-plugin.toml          # manifest (actions, panes, link handler, event)
  lib/
    common.sh                # helpers + garde-fou adopt_worktree (open_mode/fzf_theme lus ici)
  bin/
    create.sh  switch.sh  remove.sh  review.sh
    exec.sh    clean.sh
    on_worktree_created.sh   # hook de l'event worktree.created
  tests/
    common_test.sh           # helpers purs + argv d'adopt_worktree contre un herdr stub
    scripts_test.sh          # bin/*.sh contre des stubs gwm/herdr/fzf/gh (argv exact)
    fixtures/                # vraies sorties gwm 1.11 (chemins réécrits) ; worktree list herdr (schéma v0.9.5) et gh pr list construits
  .github/workflows/ci.yml   # shellcheck + tests (PR, push dev/main)
  .shellcheckrc              # source-path=SCRIPTDIR : suit le source de lib/common.sh
  README.md  PLAN.md  LICENSE  .gitignore
```

Pas de `[[build]]` (bash, rien à compiler) → `plugin link` marche direct, et
`plugin install` github ne build rien non plus.

---

## 6. Tests (repo séparé, pas la CI gwm)

`tests/common_test.sh` (assertions bash, sans instance herdr ni gwm) :
- `ctx_cwd` (fallback cwd), `open_mode` / `fzf_theme`,
- `wt_fzf` contre un `fzf` stub (héritage des opts, mode clean, survie à `set -u`),
- `pr_number_from_url` (+ rejet d'URL forgée),
- `herdr_ws_id_for_path` (slash final gwm vs herdr),
- `event_worktree_path` sur une enveloppe herdr complète (forme plate rejetée),
- `adopt_worktree` contre un `HERDR_BIN_PATH` stub qui journalise son argv,
- le garde-fou : aucun chemin de code n'émet `worktree create` / `--branch`.

CI (`.github/workflows/ci.yml`) : `shellcheck bin/*.sh lib/*.sh` + les deux suites, sur
chaque PR et sur push `dev`/`main`. Le shellcheck du runner (0.9.0 sur
ubuntu-latest) peut remonter ce qu'un 0.11 local ne voit plus (SC2119).

`tests/scripts_test.sh` (CI aussi) lance chaque `bin/*.sh` avec des stubs
`gwm` / `fzf` / `gh` en tête du `PATH` et un herdr joignable seulement via
`$HERDR_BIN_PATH` (un `herdr` nu tombe sur un piège), nourris de fixtures tirées de
vraies sorties gwm 1.11 (`tests/fixtures/`, chemins réécrits ; le `worktree list`
herdr suit le schéma v0.9.5), et vérifie l'argv exact envoyé à gwm et à herdr.

Ce que les stubs ne remplacent pas : le vrai gwm (contre `~/gwm-demo` en lecture
seule, un repo scratch pour ce qui mute, un clone relié à la forge pour
`--issue`), et ce qui ne se vérifie qu'en live : popup (cwd/env),
vrai Ctrl-clic sur une URL, déclenchement réel de l'event, rechargement du
manifest d'un plugin lié.

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

- Core herdr : `herdrdev/herdr` (ex-`ogulcancelik/herdr`, migré en 0.8.0) — CLI
  dans `src/cli/`, worktree open dans `src/cli/worktree.rs`, schema plugin dans
  `src/api/schema/plugins.rs`, events dans `src/api/schema/events.rs`, doc dans
  `docs/next/website/src/content/docs/{plugins,cli-reference,socket-api}.mdx`.
  Index LLM versionné : https://herdr.dev/llms.txt.
- Plugin de référence #1 (cas exact) : `devashish2203/herdr-worktrunk` (bash).
- Plugin de référence #2 : `NathanFlurry/herdr-plugin-jj-workspace` (rust).
- Exemples officiels : `ogulcancelik/herdr-plugin-examples`.
- gwm : `/Users/kbrdn1/Projects/Perso/gwm-cli` (source de vérité, contrat json 1.0).
```
