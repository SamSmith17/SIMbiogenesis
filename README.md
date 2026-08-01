# SIMbiogenesis — renewable energy simulator (Godot 4.7)

First-person ISRU simulator with real weather, terrain from GPS, solar/wind/hydro
physics, multi-resource systems graph, and Home Assistant digital-twin bridge.
**Godot 4.7.1**, Forward+. Product vision: [`ROADMAP.md`](ROADMAP.md) · Graph design:
[`SYSTEMS_GRAPH_VISION.md`](SYSTEMS_GRAPH_VISION.md).

**GitHub lite clone:** bespoke SOAK/Mars art is not in Git — see [ASSETS.md](ASSETS.md). Generated location maps work without the asset pack.

## Map flow (launch hub)

- **Play** from the project opens the **Launch hub** (`scenes/ui/map_select/map_select.tscn`): energy-zone world map, scrollable **Your maps** list, **Create map here**, **Start**, and **Continue** (latest autosave or newest manual slot).
- **While in-game:** **L** opens the location picker overlay (Set location); bottom **Timeline** — **💾** save/load; **🗺** autosaves and returns to the launch hub.
- **Direct map testing (editor):** open `scenes/maps/generated_location.tscn` or your local SOAK/Mars scenes (if present) and run the **current** scene (F6). Old saves referencing legacy paths are rewritten when you Continue / Load.

## Save / load

- **Timeline** (bottom bar): **💾** opens **Save / Load** (eight manual slots, **Continue**, **Delete**, overwrite prompts). **Esc** still opens the legacy time UI as before.
- **Autosave** every **3 minutes** to `user://saves/autosave.save.json` while a **Main** map runs (not in the editor).
- Manual slots: `user://saves/slot_01.save.json` … `slot_08.save.json`.
- Saves include **which map** (`scene_path`) so **Continue** / load can open the correct `Main` scene when it differs from your current one.

**Quick check:** enter a map, move, save slot 1, return to map menu, **Continue** — same map and position. Switch maps, load a slot from the other map — scene should switch and apply the snapshot.

## Beta builds (Phase 6)

- **Godot 4.6** + export templates matching your editor build.
- Presets: **Windows**, **macOS**, **Linux** → `build/SIMbiogenesis.exe`, `build/SIMbiogenesis.app`, `build/SIMbiogenesis.x86_64` (see **`export_presets.cfg`**).
- Maintainer checklist and patron pointers: **[`PHASE6_BETA_READINESS.md`](PHASE6_BETA_READINESS.md)**.
- **macOS:** Set your real **bundle ID** and signing identity before distributing outside quick tests; placeholder in preset is `com.simbio.genesis.beta`.
- **Secrets / HA:** still **`user://`** only — **[`LOCAL_CONFIG.md`](LOCAL_CONFIG.md)**.

## Secrets and integrations (GitHub / collaboration)

Home Assistant, UISP, and other user-specific settings are stored under Godot’s `user://` path at runtime — **never commit** real tokens or URLs copied from your machine into this repo.

Templates with placeholders: [`config-templates/`](config-templates/README.md). Full reference: [`LOCAL_CONFIG.md`](LOCAL_CONFIG.md).

## Assets and lite GitHub clone

Maps depend on large `res://` art (see **[`PHASE3_ASSET_PACK.md`](PHASE3_ASSET_PACK.md)**): use a **Patreon/private asset zip** merged at the project root, or commit everything / Git LFS. The project does **not** yet open `scenes/maps/mars_aerial.tscn` with zero art installed.

## Where things live

- **[`ARCHITECTURE.md`](ARCHITECTURE.md)** — module conventions, where a new file
  goes, extension points, and the live architectural-debt backlog. **Read this
  before adding a feature.**
- **[`CLAUDE.md`](CLAUDE.md)** — the feature map and the full validation suite
  (every offline selftest + windowed capture harness). Authoritative when it
  disagrees with anything else here.
- **[`FEATURE_CHEAT_SHEET.md`](FEATURE_CHEAT_SHEET.md)** — player-facing hotkeys,
  docks, and an honest ✅/⚠️/❌ status table.
- Autoloads and save helpers live under **`core/`**; map scenes under
  **`scenes/maps/`**; HUD and world prefabs under **`scenes/ui/`** and
  **`scenes/gameplay/`**.

### Historical archive (April 2026 — superseded)

The `PHASE*.md` series documents a completed repo-hygiene and beta-readiness
effort. It is kept for provenance and is **no longer current guidance** — it
describes a 107-file / 7-autoload project with no `addons/`, against today's
~540 files and 33 autoloads. Where it disagrees with `ARCHITECTURE.md` or
`CLAUDE.md`, those win.

[`PHASE1_INVENTORY.md`](PHASE1_INVENTORY.md) ·
[`PHASE3_ASSET_PACK.md`](PHASE3_ASSET_PACK.md) ·
[`PHASE4_MODULE_DESIGN.md`](PHASE4_MODULE_DESIGN.md) ·
[`PHASE5_SCENE_SHELL_DESIGN.md`](PHASE5_SCENE_SHELL_DESIGN.md) ·
[`PHASE6_BETA_READINESS.md`](PHASE6_BETA_READINESS.md) ·
[`PHASE7_PERFORMANCE.md`](PHASE7_PERFORMANCE.md)
