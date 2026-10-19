# SIMbiogenesis — Architecture & Module Conventions

This is the **structural** companion to `CLAUDE.md` (which is the feature map /
agent guide). Read this when adding a feature, a view, a tool, or a data source,
or when deciding *where a new file goes*. The goal is a codebase where new
functionality can be **added or imported without editing the core simulation**,
so the game stays moddable and hackable for others.

## North star

A feature (view / tool / device / data source / world object) should:

1. **Live in its own directory** with a `class_name` and, where it has behaviour
   worth guarding, its own `*_selftest.gd`.
2. **Self-register** through the service/registry layer or a group — never be
   hard-wired into a core file by a chain of `get_node()` calls.
3. **Communicate through signals and autoload services**, not by reaching into
   another subsystem's internal nodes.
4. **Never require edits to core sim files** (`main.gd`, the graph/canvas, the
   flow engine) to exist. If it does, that coupling is the thing to refactor.

We are **not** there yet (see *Known debt* below). Every push should leave the
architecture a little closer to it. New code is expected to follow these rules
even while old code is migrated incrementally.

## Layers

| Layer | What it is | Examples |
|---|---|---|
| **Services (autoloads)** | Global, always-on singletons that own state or talk to the outside world. The de-facto public API other code depends on. | `TimeDirector`/`SimMode`, `SaveSystem`, `WeatherService`, `ElevationService`/`ImageryService`/`AiImageryService`, `DeviceRegistry`, `MapContext`, `MultiplayerSession` (37 total — see `project.godot [autoload]`) |
| **Core sim** | The simulation surfaces. Heavy, central, currently monolithic. | `system_graph/` (the 2D systems graph = core gameplay), `power_system/`, `core/` subsystems, `main.gd` (world/env/save orchestration) |
| **World & gameplay** | Embodied 3D twin, player, props, vehicles. | `gameplay/`, `scenes/gameplay/`, `core/terrain/`, `vegetation/`, `core/placed_models/` |
| **UI / views** | Screens and panels under the Main `UILayer` (CanvasLayer). | `scenes/ui/`, `system_graph/*_view.gd`, `location_picker/` |
| **Settlement mode** | The second play mode: full-screen camera on Main, work dock, HUD, space overlay (see CLAUDE.md "Settlement mode"). | `scenes/settlement/` (`settlement_view.gd`, `settlement_camera.gd`, `settlement_hud.gd`, `work_dock.gd`, `space_overlay.gd`) |
| **Feature subsystems** | Self-contained capabilities, each in its own `core/` dir with a selftest. This is the pattern to copy. | `core/conduits/`, `core/machines/`, `core/scad/`, `core/linkage/`, `core/esim/`, `core/multiplayer/`, `core/report/`, `core/perf/` |

The **feature subsystems** column is the model for new work: each is a directory
of `class_name` scripts, offline-testable via `<name>_selftest.gd`, wired into the
game at a small number of seams rather than smeared across core files.

## Where a new file goes

- **A new self-contained capability** → its own `core/<feature>/` directory, with
  a `class_name`, and a `core/<feature>/<feature>_selftest.gd` (add it to the
  Validation list in `CLAUDE.md`).
- **A global service / data source** → an autoload in `project.godot [autoload]`.
  Copy the `WeatherService` HTTP+cache+deferred-signal pattern for anything that
  fetches. Only add an autoload if the thing is genuinely global and long-lived.
- **A UI screen/panel** → `scenes/ui/`, styled through `scenes/ui/ui_theme.gd`
  (`UITheme`), signals wired in `_ready()`.
- **A 3D world object / runtime** → `gameplay/` (behaviour) or `core/placed_models/`
  (catalog/placement). Add to `ModelCatalog` if it's placeable.
- **Nothing new belongs at the repo root.** Root is for project files
  (`project.godot`, `export_presets.cfg`), docs (`*.md`), `LICENSE`, and the
  entry scripts already there. The loose root `.gd` files (vehicles, HA client,
  etc.) are legacy and slated to move (see debt).

## Conventions (structural)

- **Signals wired in code** in `_ready()` — zero editor connections.
- **`class_name` + committed `.uid`** for every script (the repo tracks `.uid`).
- **UI through `UITheme`** — palette, status colors (`C_OK/C_WARN/C_ERROR/C_INFO`),
  StyleBox factories, `LAYER_*` bands. Don't hardcode colors/styles.
- **Lookups by group or registry, not by node path.** Groups already in use:
  `energy_sources`, `interactables`, `solar_panel_location`
  (`get_first_node_in_group(...)`). Prefer these over
  `get_node("…/UILayer/SolarUI")`. A general `Services` registry (see debt #1) is
  the intended replacement for the remaining node-name lookups.
- **Offline determinism** — subsystems ship a headless `*_selftest.gd`; sims seed
  from absolute time, never `randf()`, so replays reconstruct exactly.
- **Physics cite sources** in comments; never invent constants; extend
  `source_physics_selftest.gd` with every physics change.
- **Secrets stay under `user://`** — never commit URLs/tokens (`LOCAL_CONFIG.md`).

## Extension points (adding a feature without touching core)

Today's seams a new feature attaches to, in rough order of decoupling:

- **Autoload service** — register in `[autoload]`; other code finds you by
  singleton name. Best for data sources and global state.
- **Groups** — join a group in `_ready()`; core iterates the group
  (e.g. `EnergySource` joins `energy_sources` and is summed generically). Best
  for "N of a kind the sim aggregates."
- **`ModelCatalog`** — register a procedural or scene model; placement, ghosts,
  collision, and the library UI pick it up generically. Best for world objects.
- **System-graph presets** — add to `system_graph/data/component_presets.gd`; the
  canvas/inspector/flow engine handle it by `type`/`role`. Best for new
  simulated components.
- **Component definitions** — SketchUp-style reusable super-nodes persisted to
  `user://user_presets.json`; pure data, no code. Best for user/mod content.
- **Tutorial levels & challenge missions** — pure data additions: Solar
  Bootcamp levels in `gameplay/tutorial_catalog.gd` (seed items/wires, goal
  spec, palette, unlock grants; predicates live in `tutorial_goals.gd`),
  challenge missions in `gameplay/challenge_catalog.gd` (a def with
  `run_mode: "prebake"` gets the whole bake→playback→breakpoint→replay loop
  for free). Best for curriculum and mission content.

When you find yourself needing to edit a core monolith to add a feature, prefer
adding a **registration hook** there once, then having the feature register into
it — so the *next* feature doesn't need the edit.

## Known architectural debt (the incremental backlog)

Measured 2026-07-26. Tackle one slice per push; keep public surfaces stable and
selftests green.

1. **Node-name coupling.** Renaming a scene node silently breaks
   SimMode/AutomationEngine/UIs. *In progress:* the registry autoload
   (`core/services.gd`, selftest `core/services_selftest.gd`) has landed. Core
   nodes self-register — `Main` in `_enter_tree` (so it resolves before any
   child's `_ready`), plus
   `SystemGraphView`/`SolarUI`/`TimelineUI`/`TerrainLoader`/`Player`/`HAClient`
   in `_ready`.

   **Use the STATIC accessors: `ServiceLocator.graph()`, `.main()`, `.player()`,
   … and `ServiceLocator.provide(key, self)` to register.** The script is
   `class_name ServiceLocator` (it cannot be named `Services` — Godot refuses a
   `class_name` that shadows an autoload). The bare autoload identifier
   `Services` still works at runtime but **must not be used**: it does not exist
   under `--headless --script`, so any file referencing it fails to *compile*,
   which silently broke the whole `npc_population_selftest` dependency chain.
   The statics resolve the registry by path and return null when absent —
   the same contract as the `get_node_or_null()` calls they replace.

   *Done (2026-08-01):* all 12 bare `Services.get_*()` calls, all 7
   self-registrations, and 35 hardcoded `"UILayer/SystemGraphView"` lookups
   across 23 files. There are now **zero bare `Services` identifiers** outside
   `services.gd`. *Remaining:* the `SolarUI` / `TerrainLoader` / `Player` /
   `HAClient` path lookups, and ~340 other `"UILayer/…"` / `"/root/…"` strings.
   Do **not** register autoloads (WeatherService, TimeDirector, …) — reference
   those directly.
   ⚠ *Regressed (re-measured 2026-08-11):* 12 `"UILayer/SystemGraphView"`
   lookups were back, **concentrated in code written AFTER the sweep**, and by
   2026-10-18 there were 28 in 20 files (the settlement surface, the peak /
   festival chips, the site-project effects, the ambient bed, the fire props).
   *Swept again 2026-10-18 (Push 4), and this time it enforces itself:*
   `core/services_selftest.gd` walks every `.gd` in the repo and FAILS on the
   literal anywhere outside an allow-list — `core/services.gd` (its doc
   comment names the path it replaces), the selftest itself, and the harness
   probes (`core/terrain/harness/`, `core/terrain/playtest_harness.gd`,
   `tools/`), which walk the REAL scene tree by path on purpose. A new
   `get_node_or_null("UILayer/SystemGraphView")` anywhere else fails the
   selftest with the file named. Use `ServiceLocator.graph()`.
2. **Monoliths — the big files keep growing** (re-measured 2026-08-11):
   `system_graph_view.gd` (~15.8k lines), `terrain_loader.gd` (~10.2k),
   `graph_canvas.gd` (~9.2k), `playtest_harness.gd` (~6.8k — now bigger than
   inspector_panel and previously missing from this list), `inspector_panel.gd`
   (~6.0k), `solar_ui.gd` (~4.7k), `main.gd` (~4.3k),
   `siphon_hydro_modal.gd` (~3.8k), `resource_flow_engine.gd` (~3.6k),
   `timeline_ui.gd` (~3.1k). Every file grew since the 2026-07-26 measurement —
   the "extract one responsibility per push" remedy is being outrun. *Fix:* extract one
   cohesive responsibility per push into a delegate helper (e.g. the graph's
   `_tick_graph_csp` / `_tick_graph_renewables` / `_tick_resource_flow_ambient`;
   main's env/sky, save/load, collision generation).
3. **Loose root `.gd` (11 files)** — vehicles (`euc_/golf_cart_/skid_steer_`),
   `ha_switch`, `ha_websocket_client`, `ibc_glow`, `auto_light`,
   `solar_calculator`, `planets`, `star_system`, `main.gd`
   (`auto_collision_generator` and the root `inverter_bridge` shim are gone —
   the live `inverter_bridge.gd` autoload is under `core/`).
   *Fix (medium-risk):* relocate into homes (`gameplay/vehicles/`,
   `core/ha/`, `core/astronomy/`, …) **via the Godot editor** so `res://` /
   `.tscn` / `.tres` references are rewritten — do not `git mv` code blindly.
   *Partial (2026-09-14):* `core/astronomy/` now exists and holds the star-field
   math (`StarSkyMath` + selftest) that `star_system.gd`, `planets.gd`,
   `CelestialClock` and `LunarPosition` all delegate to; the root scripts
   themselves stay put by decision (4 scenes reference them).
4. **Stalled v1/v2 split** — `system_graph_v2/graph_canvas_v2.gd extends
   system_graph/graph_canvas.gd`. Decide: finish the migration or fold v2 back.
5. **Compat shims / dead ends** — `SimMode`→`TimeDirector`, the hidden `TimeUI`
   shim, `legacy/`. Mark with deprecation headers; remove once the registry
   migration (debt #1) is far enough along.
   *Resolved:* the duplicate `ibc_glow_lights` device id is **already fixed** —
   `soak_festival_2026.tscn` carries `ibc_glow_lights` and `ibc_glow_lights_2`,
   and neither map logs a registry collision on boot. Five dead scripts, two
   pass-only stubs and the no-op root `inverter_bridge.gd` shim were deleted
   2026-08-01, and the unreachable `uisp/` subsystem moved to `parked/uisp/`
   behind a `.gdignore` (see `parked/README.md`).
6. **Autoload count (37, re-counted 2026-08-11).** High, but it's the current service API — do not churn
   it until debt #1 gives a cleaner indirection. Then the shims become removable.

*Rule of thumb:* asset/junk hygiene is zero-risk (do freely). Moving or splitting
**code** touches `res://` paths and node lookups — do it deliberately, one bounded
slice at a time, with the subsystem's selftest as the guard.
