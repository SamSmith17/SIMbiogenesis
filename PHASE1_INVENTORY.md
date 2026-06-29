# Phase 1 — Inventory and release target

**Date:** 2026-04-29  
**Workspace:** `godot-simulator-4-18-25` (post-backup)

This document is the Phase 1 deliverable: what is in the project, where weight and risk live, and the recommended beta/GitHub split.

---

## 1. Engine and entry

| Item | Value |
|------|--------|
| Godot | **4.6**, Forward Plus (`project.godot` → `config/features`) |
| Display name | **SIMbiogenesis** |
| Main scene | `res://scenes/ui/map_select/map_select.tscn` (chooser); maps are `scenes/maps/mars_aerial.tscn`, `scenes/maps/soak_festival_2026.tscn` (SOAK Festival 2026) |
| Icon | `res://icon.png` |

### Autoloads (`project.godot`)

- `DeviceRegistry` → `power_system/core/device_registry.gd`
- `AutomationEngine` → `power_system/automation/automation_engine.gd`
- `SaveSystem` → `core/save_system.gd`
- `GhiService` → `location_picker/ghi_service.gd`
- `InverterBridge` → `core/inverter_bridge.gd`
- `SimMode` → `core/sim_mode.gd`
- `GameplayRules` → `gameplay/gameplay_rules.gd`

### Plugins

- **No `addons/` directory** — vanilla project scripts only.

### Export presets (`export_presets.cfg`)

- Presets present: **Windows Desktop**, **macOS**, **Linux** (all `export_filter="all_resources"`); portable outputs under `build/` (`SIMbiogenesis.exe`, `SIMbiogenesis.app`, `SIMbiogenesis.x86_64`). Export templates must be installed in the editor used for builds (not stored in this repo by default).

---

## 2. Code and scenes (counts)

Measured on this copy:

| Type | Count |
|------|--------|
| `*.gd` | **107** |
| `*.tscn` | **50** |

### Scene groups (paths)

- **Root / maps:** `main- maybe unstable.tscn`, `main_old_backup.tscn`, `mars_2026.tscn`, `mars_2026_expanded.tscn`, `linkage_lab_export.tscn`; canonical Mars play map lives at **`scenes/maps/mars_aerial.tscn`** (see Restructure section).
- **Player / gameplay:** `scenes/gameplay/` (player, terrain, zones, vehicles, props — see Restructure phase 4), `player_tools/*`
- **UI:** `scenes/ui/` (HUD panels — see Restructure phase 4), **`scenes/ui/map_select/`**, `location_picker/*`, `system_graph/*`, `system_graph_v2/*`
- **Power:** `power_system/*` (devices, core, automation)
- **Integrations:** `uisp/*`, `scenes/gameplay/govee_lights.tscn`, HA client scripts at repo root
- **Crisis:** `crisis_events/*`
- **Heavy / imported scenes:** under `Imported Models/` (e.g. `Mars Aerial/mars_2026___aerial_located.tscn`, `Busses.tscn`, `appa.tscn`)

---

## 3. Data (small, commit-friendly)

`data/` (three JSON files, ~0.47 MB total on this machine):

- `ghi-grid.json` — GHI / solar UI support
- `zone-population.json`
- `countries-110m.json`

Additional logic data under `system_graph/data/` (`component_presets.gd`, `graph_model.gd`).

---

## 4. Disk footprint (top folders)

Approximate sizes on this copy (recursive file sizes):

| Location | Size (MB) | Notes |
|----------|-----------|--------|
| `.godot/` | **~5693** | **Editor import cache — do not commit**; regenerates locally |
| `Imported Models/` | **~1221** | Primary **heavy art**; GitHub lite should exclude or use LFS / separate pack |
| `StarShade FBX/` | ~499 | Large asset folder at repo root |
| `Starshade Pretty Version/` | ~243 | Large asset folder at repo root |
| `Player Character/` | ~229 | Large asset folder at repo root |
| `data/` | ~0.47 | Small |
| `readme/` | ~3.9 | Screenshots / readme assets |

**Imported Models** file count: **~3626** files.  
**.godot** file count: **~10830** files (typical for a populated import cache).

---

## 5. User-specific data and secrets (not in repo)

Runtime config uses `user://` paths (per-user, outside the project folder):

| Path (pattern) | Used by |
|------------------|---------|
| `user://ha_connection.cfg` | `ha_connection_ui.gd` |
| `user://solar_ui_ha_entities.cfg`, `user://solar_panel_config.cfg` | `solar_ui.gd` |
| `user://uisp_settings.cfg` | `uisp_connection_ui.gd` |
| `user://location_prefs.cfg` | `main.gd` |
| `user://star_calibration.cfg` | `star_system.gd`, `star_calibration_ui.gd` |
| `user://saves/index.cfg` (+ save slots) | `core/save_system.gd` |

**Code scan:** `uisp_api_client.gd` exposes `@export var api_token` with placeholder `YOUR_API_TOKEN` — ensure no real token is saved in scene `.tscn` resource overrides before GitHub.

---

## 6. Portability / hygiene flags (fix in Phase 2)

- `project.godot` → `[editor] movie_writer/movie_file` points at a **Linux path on another machine** — confusing for collaborators and diffs.
- `export_presets.cfg` — **non-portable export paths** and naming; macOS output path empty.
- `.gitignore` currently: `.godot/`, `*.import` — fine for ignoring cache; **policy decision needed** on whether to commit `.import` for reproducible clones (Phase 2).

---

## 7. Git

- **Not a git repository** on this copy (`git status` → not a git repo).  
- Phase 2: `git init`, choose ignores, optional Git LFS for art.

---

## 8. Recommended release target (Phase 1 decision)

Two deliverables match your goals:

1. **Patreon WIP binary** — Full or “curated” art: include `Imported Models` + root large folders as needed for the two maps; ship Windows/macOS/Linux exports (after preset cleanup).  
2. **GitHub “lite” source** — **Code + small data + placeholder or documented optional art**; exclude `.godot/`, exclude or submodule/LFS **`Imported Models/`**, `StarShade FBX/`, `Starshade Pretty Version/`, `Player Character/` (or document “copy your assets here”). README should state Godot version and how to open a minimal scene.

This split keeps the repo clone small while patrons still get a playable build with assets.

---

## 9. Phase 1 review checkpoint

- [x] Godot version and main scene confirmed  
- [x] Autoloads and plugin situation documented  
- [x] Script/scene counts and scene groups listed  
- [x] Heavy asset locations and sizes identified  
- [x] `user://` secret/config pattern documented  
- [x] Local path / export issues flagged for Phase 2  
- [x] Beta shape: **dual package (full binaries + lite repo)** recommended  

**Next:** Phase 2 — GitHub hygiene, `.gitignore`/LFS decision, clear `movie_writer` path, export preset cleanup, README alignment.

---

## Phase 2 (completed 2026-04-29)

- Removed foreign `[editor] movie_writer/movie_file` path from `project.godot`.
- Export presets: portable outputs under `build/` — `SIMbiogenesis.exe`, `SIMbiogenesis.x86_64`, `SIMbiogenesis.app`; Windows `application/product_name` set to **SIMbiogenesis**.
- Expanded `.gitignore`: `build/`, OS junk, accidental `*.cfg` secret drops, optional `.env` (with committed `.env.example`).
- Added [`LOCAL_CONFIG.md`](LOCAL_CONFIG.md), [`config-templates/`](config-templates/README.md), README pointer for secrets.
- Repository initialized with `git init` when Phase 2 was applied (run `git status` locally to confirm).

**Secret scan:** grep for common token patterns in `*.gd` / `*.tscn` / `*.cfg` found no embedded live credentials; `uisp_api_client.gd` remains placeholder-only.

---

## Phase 3 (completed 2026-04-29)

- Added **[`PHASE3_ASSET_PACK.md`](PHASE3_ASSET_PACK.md)**: tiers A/B/C, folder omit list, scene→dependency matrix, Patreon zip workflow, `*.import` policy.
- Added **[`.gitattributes.lfs.example`](.gitattributes.lfs.example)** for optional Git LFS.
- **[`.gitignore`](.gitignore)** — commented optional block to stop tracking heavy directories in a lite remote.
- **[`README.md`](README.md)** — pointer to asset-pack doc.

---

## Phase 4 design (completed 2026-04-29)

- Added **[`PHASE4_MODULE_DESIGN.md`](PHASE4_MODULE_DESIGN.md)** as the design handoff for separating solar/electrical simulation, survival/crisis rules, and map-specific scenario data.
- Recommended a small `GameplayRules` autoload plus `ScenarioConfig` resource as the lowest-risk first implementation.
- Preserves `main.gd.gameplay_mechanics_paused` during migration for UI, graph behavior, and old save compatibility.
- Includes a Composer 2 implementation prompt and test matrix.

**Implementation (same session):** `GameplayRules` autoload ([`gameplay/gameplay_rules.gd`](gameplay/gameplay_rules.gd)), [`ScenarioConfig`](scenarios/scenario_config.gd), wiring in `main.gd`, `player_health.gd`, `player.gd`, `death_zone.gd`, `health_ui.gd`, `time_ui.gd`, `crisis_event_manager.gd`, `system_graph_view.gd`.

---

## Phase 5 design (completed 2026-04-29)

- Added **[`PHASE5_SCENE_SHELL_DESIGN.md`](PHASE5_SCENE_SHELL_DESIGN.md)** for scene-shell/map-select design and risk review.
- Added `TimelineUI` to **[`scenes/maps/mars_aerial.tscn`](scenes/maps/mars_aerial.tscn)** so the main Mars/aerial map has the same bottom-bar save/load access as `main- maybe unstable.tscn`.
- Recommended a low-risk transitional shell: a map-select scene that `change_scene_to_file`s into self-contained map scenes, instead of a persistent shared UI shell in the first pass.
- Save routing implemented: `main.gd` stores trusted `scene_path` via `MapDefinition.snapshot_scene_path`; cross-map load uses `SaveSystem` pending resume.

---

## Phase 6 — Beta readiness (completed 2026-04-29)

- Added **[`PHASE6_BETA_READINESS.md`](PHASE6_BETA_READINESS.md)** — export checklist, patron quick reference, Phase 7 profiler preview.
- README: **Map flow** + **Beta builds** sections; roadmap link.
- **`export_presets.cfg`**: macOS `application/bundle_identifier` placeholder (`com.simbio.genesis.beta`) for local/ad-hoc builds; replace for wide distribution.
- **`player_health.gd`**: re-resolve `Main` when `_main_node` is freed after map changes (stability with scene shell).

---

## Phase 7 — Performance (completed 2026-04-29)

- **[`PHASE7_PERFORMANCE.md`](PHASE7_PERFORMANCE.md)** — how to profile in 4.6, soak/regression matrix, future candidates.
- **`scenes/ui/health_ui.gd`:** poll survival HUD visibility from `GameplayRules` every 0.2 s instead of every frame.
- **`core/sim_mode.gd`:** recompute LIVE/SIMULATE/HISTORICAL at ~20 Hz; immediate recompute when history latch changes.
- **`crisis_event_manager.gd`:** poll `GameplayRules.is_crisis_events_enabled()` every 0.25 s so the “crises off” path skips the per-frame autoload lookup.

---

## Restructure phase 0–2 (2026-04-29)

- **Branch:** `chore/restructure-phase-0-2`
- **Folders:** `core/` (autoload scripts), `scenes/maps/`, `scenes/ui/`, `scenes/gameplay/`, `assets/{sky,materials,audio,characters,props,maps,sources}/`, `legacy/` (see `legacy/README.txt`)
- **Soak map:** `main- maybe unstable.tscn` → `scenes/maps/soak_festival_2026.tscn` (display **SOAK Festival 2026**); archived copy `legacy/main_maybe_unstable_archived.tscn`. Saves with old `scene_path` normalize via `MapDefinition.LEGACY_SOAK_SCENE`.
- **Autoload paths:** `SaveSystem`, `SimMode`, `InverterBridge` → `core/*.gd`

## Restructure phase 3 (2026-04-29)

- **Mars / aerial map:** root `main.tscn` → **`scenes/maps/mars_aerial.tscn`** (same scene `uid` preserved). Frozen root copy: **`legacy/main_tscn_root_archived.tscn`**. Saves and menu paths listing `res://main.tscn` normalize via **`MapDefinition.LEGACY_MARS_SCENE`**.
- **Map select scene:** `map_select/` → **`scenes/ui/map_select/`** (`run/main_scene` and `TimelineUI` return path updated).

## Restructure phase 4 (2026-04-29)

- **Gameplay prefabs** (root → **`scenes/gameplay/`**): `player*` scripts, `Terrain.tscn`, `Tree.tscn`, `fpv_drone`, `hydration_station`, `charging_station`, `projector_screen`, `govee_lights`, `string_lights`, `death_zone`, `collision_*`.
- **HUD / panels** (root → **`scenes/ui/`**): `time_ui`, `game_over_ui`, `solar_ui`, `interaction_prompt_ui`, `euc_ui`, `health_ui`, `ha_connection_ui`, `save_load_ui`, `mars_college_credits_ui`, `timeline_ui`, `star_calibration_ui` (scripts + scenes + `.uid` where present).
- **Path rewrite:** `res://` references updated across scenes, scripts, markdown, and `.godot/*.cfg` editor caches. Notable code: `system_graph_view.gd` → `scenes/ui/solar_ui.tscn`; `star_system.gd` → `scenes/ui/star_calibration_ui.tscn`.

**Next:** optional asset migration under `assets/`; profiler-led tidy (Phase 7 doc).
