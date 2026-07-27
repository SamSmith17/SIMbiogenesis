# SIMbiogenesis — Project Memory

Godot 4.7 (Forward+ on desktop; GL Compatibility only as the `.mobile` fallback).
First-person ISRU / renewable-energy simulator with a real
Home Assistant digital-twin bridge. **Core gameplay = 2D systems graph** (schematic
map of resource flows within a Sphere of Influence); **3D world = embodied digital twin**.
Product vision: `ROADMAP.md` + graph overhaul: `SYSTEMS_GRAPH_VISION.md`. Structure
& module conventions (where new code goes, extension points, cleanup backlog):
`ARCHITECTURE.md`. Restructure history: `PHASE1_INVENTORY.md` … `PHASE7_PERFORMANCE.md`. Secrets policy:
`LOCAL_CONFIG.md` (real HA/UISP credentials live under `user://` only — never
commit URLs or tokens).

## Validation (run before every commit)

```
# Godot 4.7.1-stable binary (the examples below use "Godot.exe.exe" as a
# shorthand for whichever current binary you have on PATH):
C:\Users\notsa\Downloads\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe
# (The old 4.6.2 binary — double extension correct — still lives at
#  C:\Users\notsa\Downloads\Godot\Godot.exe.exe for A/B comparison.)

# After adding any new class_name script, import once or headless runs fail
# with "Could not find type":
Godot.exe.exe --headless --path . --import

# Physics self-test (extend it with every physics change):
Godot.exe.exe --headless --path . --script power_system/sources/source_physics_selftest.gd

# Boot both maps, 120 frames each; compare errors against the known
# pre-existing set (see Known Issues):
Godot.exe.exe --headless --path . --quit-after 120
Godot.exe.exe --headless --path . --quit-after 120 res://scenes/maps/mars_aerial.tscn

# Terrain pipeline self-test (offline, deterministic — geo math + mesh builder):
Godot.exe.exe --headless --path . --script core/terrain/terrain_selftest.gd
# Terrain seam compose diagnostic (offline, synthetic mismatch grid):
Godot.exe.exe --headless --path . --script core/terrain/terrain_seam_diag_run.gd
# Building pipeline self-test (offline — roof geometry/UVs/styles/facade
# elements/wall picking/model catalog; extend it with every building change):
Godot.exe.exe --headless --path . --script core/terrain/building_builder_selftest.gd
# Climelapse keyframe + scale-bake round-trip (offline):
Godot.exe.exe --headless --path . --script core/climelapse/climelapse_series_selftest.gd
# Climelapse MP4 export (in-game): Render ▾ → Climelapse → export MP4… — requires ffmpeg in PATH
# Vegetation growth seasonal gate + instance map (offline):
Godot.exe.exe --headless --path . --script vegetation/vegetation_growth_selftest.gd
# Site Report metrics/data + UI-compile self-test (offline, deterministic):
Godot.exe.exe --headless --path . --script core/report/site_report_selftest.gd
# Nested super-node self-test (offline — portal resolution, flattened connections,
# walk recursion, cascade delete, v6->v7 migration, exposed-port maintenance,
# nesting-aware PV faulting; run --import first so GraphNesting registers):
Godot.exe.exe --headless --path . --script system_graph/graph_nesting_selftest.gd
# Graph COMPONENTS self-test (offline — SketchUp-style definitions: realize
# single + multi-level (StarShade tree), capture round-trip, edit-one-instance-
# updates-all with per-instance battery SOC preserved, external-wire survival on
# re-stamp, Make Unique detach, v6->v7 definitions round-trip; --import first):
Godot.exe.exe --headless --path . --script system_graph/graph_components_selftest.gd
# Graph electrical self-test (offline — string Voc, controller ranking, Voc across
# a super-node boundary):
Godot.exe.exe --headless --path . --script system_graph/graph_electrical_selftest.gd
# 3D conduits (offline — kinds/conceptual default, mesh/drape/lights, loss,
# bound-prop routability, connection ports, triangle pick, ortho elbows;
# run --import first so new class_names register):
Godot.exe.exe --headless --path . --script core/conduits/conduit_selftest.gd
# Culvert stage-discharge + Hydro Section calculator (offline — weir/orifice,
# Manning cap, stepped 3×8″ bank, PE vs HydroSource; --import first):
Godot.exe.exe --headless --path . --script core/conduits/culvert_hydraulics_selftest.gd
# Siphon micro-hydro prime/break + power cap (offline; --import first):
Godot.exe.exe --headless --path . --script core/conduits/siphon_hydraulics_selftest.gd
# Unified hydro reach: pond→siphon→culvert→outlet ONE stepper — parity vs
# SiphonHydraulics, prime/break cycle, mass conservation, effective air-break
# dead pool, overflow (offline, deterministic; --import first). This reach is the
# single physics source for the flow engine + Siphon Lab (no fallback branch):
Godot.exe.exe --headless --path . --script core/conduits/hydro_reach_selftest.gd
# ABS DWV pipe kit (offline — kit JSON/meshes, planner 45/90 BOM; bake once with
# pipe_kit_extractor.gd if data/*.res missing; --import first):
Godot.exe.exe --headless --path . --script core/conduits/pipe_kit_selftest.gd
# Re-bake ABS fittings from Imported Models/PipeFittings/abs_dwv_elbows.glb:
Godot.exe.exe --headless --path . --script core/conduits/pipe_kit_extractor.gd
# LinkageLab designer self-test (offline — solver/kinematics pinned to JS
# reference values, support/panel geometry, structure builder, world-placement
# runtime, solar/graph handoff, modal compile smoke; extend with every solver
# change; run --import first so new class_names register):
Godot.exe.exe --headless --path . --script core/linkage/linkage_selftest.gd
# Process recipes + chore ledger + workflow runner (offline — normalize/catalog,
# legacy batch migration, scrub-safe progress, hybrid chore confirm, part credits,
# workflow step advance; run --import first so class_names register):
Godot.exe.exe --headless --path . --script core/machines/process_recipe_selftest.gd
# Portable .esim site package (offline — validate/build, ghost strip/remap,
# share-code + file round-trip, summary counts; run --import first):
Godot.exe.exe --headless --path . --script core/esim/esim_selftest.gd
# Multiplayer helpers (offline — join-code v2 round-trip/expiry, bare ip:port,
# protocol reject, avatar color, transfer codec, chat sanitize/mute, Phase 6
# password/allowlist/rate-limit + headless host bind smoke; run --import first):
Godot.exe.exe --headless --path . --script core/multiplayer/multiplayer_selftest.gd
# Terrain live-fetch smoke test (NETWORK — elevation + imagery for one site):
Godot.exe.exe --headless --path . --script core/terrain/terrain_fetch_smoketest.gd
# Parametric SCAD store (offline — -D/param-set literal formatting, param-set JSON,
# StlLoader STL->mesh round-trip, ScadProvisioner manifest/plan, ScadParamParser
# Customizer schema over the seed vase, ScadCatalog deps/category/license triage;
# run --import first so the new class_names register):
Godot.exe.exe --headless --path . --script core/scad/scad_selftest.gd
# SCAD live render smoke (REQUIRES OpenSCAD binary — renders seed vase twice,
# confirms params change geometry + STL imports to a mesh):
Godot.exe.exe --headless --path . --script core/scad/scad_render_smoke.gd
# SCAD library ingest + license triage (needs OpenSCAD for validation renders):
# walks scad_library/ RECURSIVELY, parses each, validation-renders defaults
# (bounded by --render-budget=<sec>, default 240), writes scad_library/catalog.json,
# auto-stubs missing credits into credits/credits.json (--no-render = metadata only):
Godot.exe.exe --headless --path . --script core/scad/scad_ingest.gd
# SCAD library import (seed scad_library/ from an external Thingiverse-style folder:
# copies .scad by dir, classifies LICENSE.txt, extracts README, writes credits):
Godot.exe.exe --headless --path . --script core/scad/scad_import.gd -- --src="<path>"
# In-game store: press H in a loaded map (ScadStore + scenes/ui/scad_store_modal.gd;
# ScadPartBuilder MODEL_ID scad_part places rendered parts via PlacedProp).

# Visual playtest capture (WINDOWED — cannot be --headless): launch a user map
# by CLI, freeze a daytime clock, hide HUD, shoot drone-orbit + street PNG sets
# (+ manifest.json) to user://screenshots/<label>/ for agent/visual review:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=<file.tres> --capture=both --shots-dir=<label> --quit-after-capture
# Terrain-sculpt smoke test (WINDOWED): runs a real Raise stroke + Level pad +
# Pond through the TerrainLoader commands, shoots before/after PNG sets (incl.
# low grazing views where a 3 m mound/bowl actually silhouettes), dumps the
# HeightField tile-mesh state (AABBs/material — catches invisible-mesh bugs),
# then UNDOES everything (map save data untouched):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=<file.tres> --sculpt-test --shots-dir=<label> --quit-after-capture
# Systems-graph UI capture (WINDOWED): opens the G view on the soak map (the
# boot scene is the map chooser, so pass --scene) and shoots one PNG per UI
# state — freeform/arranged/selection+inspector/compound interior/zoom
# extremes/site plan/elevation — via the REAL view handlers, for visual review:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=graph --shots-dir=<label> --quit-after-capture
# Siphon Lab capture (WINDOWED): builds a pond + siphon on the graph, binds them,
# opens the Lab's own 2D cross-section (VIEW_SIPHON), and shoots primed/flowing →
# time-accelerated drain/broken → test-inflow refill/reprime (drives the pond on
# the world clock via the unified HydroReach) for visual review of the flow render:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=siphon --shots-dir=<label> --quit-after-capture
# Site-review (WINDOWED): load a REAL user map as-is (autosaved graph + terrain
# artifacts), shoot world/ + graph/ (freeform + elevation) + siphon/ Lab, write
# diagnostics.json + perf/*.json. Alias --user-map=mtvernon resolves Mount Vernon
# under user://maps/. --perf enables F3 HUD; --no-mutate skips Demo Lab drive:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=loc_48p3252_n122p2469.tres --capture=site-review --perf --shots-dir=mt_vernon_review --quit-after-capture
# Ambient resource-flow regression guard (WINDOWED — the harness hard no-ops
# under --headless; no screenshots, console-only): builds a primed pond+siphon+
# culvert-outlet, keeps SystemGraphView.visible=false the ENTIRE time (graph
# never opened), speeds up the world clock, and asserts the pond drained + the
# outlet accumulated volume. Guards against the water/siphon/catchment
# simulation regressing back to only running while the 2D graph screen is open
# (system_graph_view._tick_resource_flow_ambient):
Godot.exe.exe --path . --windowed --resolution 640x480 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=ambient --quit-after-capture
# Siphon auto-bind distance-cap guard (WINDOWED, console-only): places a NEAR
# pond and a FAR pond next to a synthetic siphon and confirms bind_siphon_to_
# nearest_pond(id, silent, max_dist_m) binds the near one, refuses the far one
# beyond the cap, and an uncapped manual Rebind ignores distance — the
# guardrail behind auto-bind-on-placement (Phase 3):
Godot.exe.exe --path . --windowed --resolution 640x480 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=autobind --quit-after-capture
# Stable pond-id guard (WINDOWED, needs a REAL TerrainLoader — generated
# location maps only, e.g. a throwaway --map-lat=/--map-lon= test coordinate,
# NOT the trusted built-in scenes which have no TerrainLoader): carves a pond,
# adds it to the graph, then re-designates the SAME basin with a reshaped
# polygon (forcing EarthworksBuilder.basin_tag_from_poly to derive a DIFFERENT
# tag — exactly what resizing/reshaping an existing pond does). Asserts no
# duplicate water-body record, pond_id preserved across the tag change, and
# the graph tank still resolves to the live re-shaped pond with no manual
# healing. Clean up the throwaway coordinate's files under user:// afterward
# (maps/, saves/graph_autosave/, terrain_cache/, weather_cache/, scores/ —
# all suffixed with the test lat/lon token):
Godot.exe.exe --path . --windowed --resolution 640x480 -- --map-lat=<f> --map-lon=<f> --half-extent=3000 --capture=pondid --quit-after-capture
# Downhill-culvert-routing guard (WINDOWED, needs a REAL TerrainLoader — a
# throwaway generated-map test coordinate, NOT the trusted built-in scenes):
# builds a siphon, calls ensure_siphon_outlet_sink, and confirms the outlet
# either (a) traced a real downhill route (Watershed.trace_downhill over the
# actual DEM — route_3d has waypoints, invert is a real terrain elevation, the
# site moved off the old fixed +12m/-9m chord) or (b) correctly fell back to
# the fixed +12m offset on flat/no-DEM terrain — either is valid; only "neither"
# is a regression. Clean up the throwaway coordinate's user:// files afterward:
Godot.exe.exe --path . --windowed --resolution 640x480 -- --map-lat=<f> --map-lon=<f> --half-extent=3000 --capture=culvert --quit-after-capture
```

Gotchas: headless runs rename `addons/**/~lib*.dll` → `*.TMP` (restore with
`git checkout`, delete TMPs). Don't `git stash` around headless runs — the
ignored `.godot` class cache goes stale. If the Godot editor is open during
file operations, it can resurrect deleted/modified scenes from memory on save.

## Maps and scene shell

Two playable maps, both rooted on `main.gd` (Node3D "Main"):
- `scenes/maps/soak_festival_2026.tscn` (default main scene in project.godot)
- `scenes/maps/mars_aerial.tscn`
Map chooser: `scenes/ui/map_select/` + `maps/map_definition.gd`
(TRUSTED_SCENE_PATHS, legacy-path normalization for old saves).
`main.tscn` at root is a legacy Mars variant kept for slim-export fallback.

**User-created location maps (ROADMAP Pillar 1 — location→world).** One reusable
shell scene `scenes/maps/generated_location.tscn` serves ALL user maps; it is the
Mars shell with world content stripped, regenerated by
`core/terrain/build_generated_scene.gd` (re-run that one-off `--script` tool if
the shell scene changes). Each user map is a `MapDefinition` .tres in
`user://maps/` pointing at `MapDefinition.GENERATED_SCENE` (now in
TRUSTED_SCENE_PATHS) and carrying `latitude`/`longitude`/`half_extent_m`.
`map_select` scans `user://maps/`; the location picker's **"Create map here"**
(`location_picker_ui.gd:_create_map`) writes the .tres and launches it.
Coordinates reach the scene via the `MapContext` autoload (set before
`change_scene_to_file`, which can't pass args; `from_resume` flag keeps the loader
from re-seating the player on save resume). `core/terrain/terrain_loader.gd`
(node "TerrainLoader" under the shell) resolves the site, calls
`apply_location`, fetches elevation + imagery, builds the terrain via
`TerrainBuilder`, and re-seats the player. Save/load already round-trips lat/lon
(main.gd save snapshot + `_apply_save_snapshot`); resume rebuilds the same terrain
(deterministic, same mean-elevation centring → saved player y still valid).

**OSM solar arrays (player-selected, not auto-added).** BuildingService pulls
`power=generator` solar ways; `terrain_loader._apply_solar_arrays()` builds each
footprint's panels in-world (`core/terrain/solar_array_builder.gd`) and records them
in `_solar_arrays` (poly + panel_count + base_y + stable centroid `tag`), but adds
NOTHING to the graph/SolarUI on load. The player aims the crosshair at an array
(`interaction_focus.gd:_update_solar_focus` → `pick_solar_array_at_world`), it
highlights **red** (`_draw_solar_highlight`, reuses `TerrainBuilder.build_polygon_highlight`),
and Interact calls `add_solar_array_to_graph(idx)` → `SystemGraphView.add_imported_solar_panels(count, watts, label, array_tag)`
(per-`array_tag` idempotent: re-adding replaces only that array's nodes, keeps
others) + `_refresh_added_solar_total()` feeds the accumulated count to SolarUI.
Added-set (`_added_solar_tags`) survives in-session terrain rebuilds; graph autosave
persists nodes across loads (tag keying prevents duplicates on re-add).

**OSM buildings + Building Builder (core/terrain/building_builder.gd).** Extruded
footprints seat at ONE base Y (lowest corner sample + 0.35 m skirt) so eaves/roofs
stay LEVEL on slopes. Roofs honor `roof:shape`/`roof:angle`/`roof:orientation`/
`roof:direction`; with no tag, residential types default gabled 28°, commercial flat,
`building=yes` by footprint heuristic (`infer_roof_spec`; cache needs NO version bump
for tag-parsing changes — `_deser_item` re-derives from cached tags). Ridge geometry
is a Chebyshev height field over the ridge frame with triangles split at crease
lines (gable/hip/pyramid faces exactly planar; gable-end wall fills share
`_roof_height_at` → watertight; star-shaped footprints fall back flat). Merged mesh
= 2 surfaces (0 walls+floor with per-facade metric UVs, 1 roof with eave-aligned
slope-metric UVs) under procedural `building_wall.gdshader` (lap siding, foundation
band at V<0) + `building_roof.gdshader` (staggered shingles; COLOR.a=0 → flat
membrane); per-building tint in vertex COLOR from `building:colour`/`roof:colour`
or a tag-hashed palette. **Per-building styles:** `BuildingStyleLayer`
(`user://maps/building_styles_<lat>_<lon>.json`, keyed by `building_tag` =
metre-rounded centroid) overrides roof shape/pitch/colors/height/base offset +
facade `elements` (doors/windows as proud quads on a 3rd surface); styled buildings
are EXCLUDED from the merged mesh and rebuilt as `BuildingsCustom/B_<tag>` children
via `build_single_building` (same `_append_footprint` path; the modal previews with
a flat 2×2 DEM). Crosshair focus draws an amber roof-level outline; Interact or B
(`building_builder` action) opens `scenes/ui/building_builder_modal.gd` (veg
"Tune look" pattern: SubViewport studio + debounced sidebar; clicking the preview
ray-picks the wall via `pick_wall_point` — pure math, no studio physics — to place
doors/windows; Library tab lists `ModelCatalog.models_in_category("structures")`
incl. StarShade and hands off to `PlacedPropService` ghost placement or
`replace_osm_building`). `apply_building_style` rebuilds one child; entering/leaving
the styled set re-runs `_attach_buildings`. Selftest:
`core/terrain/building_builder_selftest.gd` (148 checks).

**Photoreal buildings (ortho roofs + wall modes + facade textures).** Roof
surface carries geo-registered **UV2** (plan position / `ORTHO_HALF_EXTENT_M`
= 500 m square, (0,0) = NW like the terrain drape; fixed constant → mesh never
rebuilds when imagery lands). A third imagery layer "hyper" (`HYPER_HALF_EXTENT`
500 m, `HYPER_MAX_ZOOM` 19 ≈ 0.24 m/px; cfg override `[terrain]
hyper_target_px`) is requested after the detail layer, never gating load.
**ESRI z20+ exists only in select metros — elsewhere it returns HTTP-200 "Map
data not yet available" placeholder tiles** (a z20 fetch at Bombay Beach cached
an all-grey mosaic → blank grey roofs); ImageryService `_region_is_placeholder`
now rejects near-uniform mosaics as failed layers. `_make_world_roof_material()` sets `use_ortho`/`ortho_tex`/`ortho_uv_scale`
on `building_roof.gdshader` so roofs inside the patch sample the REAL aerial
photo (procedural shingle shade layered on top via `ortho_relief`; detail-drape
fallback remaps UV2 by extent ratio; outside-patch/no-texture → procedural).
Wall surface UV2 = `(WallMode + 0.5, seed01)`: `building_wall.gdshader` modes
LAP(0, byte-identical original)/TRAILER/CORRUGATED/PLYWOOD/STUCCO +
`weathering` uniform; `resolve_wall_mode` maps `building:material`/
`static_caravan` tags, else footprint <80 m² = trailer-town stock (Bombay Beach
has ZERO material tags in OSM — size heuristic does the lifting). Style keys:
`wall_mode` (int, −1 auto), `wall_texture` (+`wall_tex_w_m/h_m`) — a PNG from
`user://maps/facade_textures/` (drop-in or `tools/generate_facades.py`, Gemini
Imagen, GEMINI_API_KEY env) tiled in metric wall UVs on styled buildings only
(missing file → warn + procedural). Modal adds Material + Facade tex controls
and a **Reference** tab: `MapillaryService` autoload (token
`user://terrain_config.cfg [mapillary] access_token=`, cache
`user://terrain_cache/mapillary/`, CC-BY-SA attribution shown; Google Street
View is ToS-forbidden for texturing) shows nearby street photos; click = wall
eyedropper, right-click = roof.

**Playtest harness (`core/terrain/playtest_harness.gd`, autoload).** Hard no-op
without CLI user args (after `--`). `--user-map=<user://maps/*.tres>` (or
`--map-lat/--map-lon`, or alias `mtvernon`) seeds MapContext + switches to the
generated shell; `--capture=orbit|street|hero|both|graph|siphon|site-review`
waits for `TerrainLoader.map_load_complete` (+ the hyper drape, bounded 420 s
for world), freezes `--time=<hour>` (default 10.0), shoots PNG sets +
`manifest.json` to `user://screenshots/<--shots-dir>/`. **`site-review`** is the
agent-facing composite for a saved site: `world/` + `graph/` (freeform / site
plan / elevation) + `snowglobe/` + `siphon/` Lab + `diagnostics.json` + optional
`--perf` → F3 HUD + `perf/*.json`. `--review-sets=world,freeform,site,elevation,snowglobe,siphon,arranged`
(default omits site/snowglobe); `--no-mutate` skips Lab Demo drive.
`--quit-after-capture` exits. F12 = manual shot. Windowed only.

**Graph PV electrical + layout (system_graph/).** `PvElectrical` computes string Voc
(series sum / parallel branch max, cold-temp boost) on PV connections; exceeding
`controller.specs.max_voc` sets `destroyed` + education overlay + smoke FX on the
canvas; RESET hit-test on the node (`controller_reset_pressed`) or inspector button
clears fault and re-checks wiring. `GraphLayout.resolve_overlaps` + fit-to-view run
on first load (no saved layout) and via toolbar **Arrange**; `GraphPvWiring` wires
marquee-selected panels **Series** or **Parallel** to nearest controller `pvPositive`/
`pvNegative`. Destroyed controllers shed AC via `SolarUI.set_graph_controller_destroyed`.
Self-test: `system_graph/graph_electrical_selftest.gd`.

**Solar Concentrators (parabolic-trough CSP, Library category "csp").**
`ComponentPresets.CSP_CONCENTRATORS` (type `"processor"`, `specs.role =
"csp_concentrator"`, reuses the processor UI/save-to-library/inspector path —
see `inspector_panel.gd:_build_csp_concentrator_section`) with `model_id =
"csp_trough"` → same "Place Model" library flow as the 3D VAWT
(`system_graph_view.gd:_on_lib_place_model_requested` → `PlacedPropService` →
`PlacedPropRuntime._maybe_attach_csp_tracker`, which attaches
`gameplay/csp_trough_tracker.gd` to the placed prop). The GLB
(`Imported Models/CSP/single_axis_csp.glb`, inch-unit like the StarShade
bundles → `preserve_scale: true`) splits into `Component#452` (fixed base)
and `Component#453` (the moving concentrator — mirror + focal tube, pivot at
its own origin). **This is an E-W horizontal single-axis tracker**: the pivot
axis runs east-west (`CspTroughSource.TRACKING_AXIS` = world east, the shared
source of truth for physics + 3D), so the trough's long axis lies E-W and the
aperture faces the equator (south in N hemisphere, north in S) while tilting
up/down to follow the sun's altitude. The GLB's NATURAL pose already runs
`Component#453`'s local +X (the ~12 m module-length / pivot axis) along world
east-west — verified empirically (a throwaway diagnostic instantiated the GLB
and measured that axis + the mirror mesh's average normal in world space at
several yaws) — so `ModelCatalog.forced_yaw_deg("csp_trough")` is 0 (no yaw);
`PlacedPropService._build_ghost` applies the SAME forced-yaw constant to the
placement ghost so the preview matches the placed prop exactly (no snap on
confirm). `CspTroughTracker` force-holds `ModelRoot`'s yaw every frame (a
single-axis trough's heading is physically fixed; only its tilt tracks) and
drives `Component#453.rotation.x` from the live tracking angle. Because the
GLB's OWN rest pose (`Component#453.rotation == 0`) doesn't correspond to
"aperture normal straight up" — it measured ~64° tilted toward south, an
artifact of the asset's export pose — `_bind()` measures that bias once from
the actual mesh geometry (`CspTroughSource.tracking_offset_from_normal`:
average local normal of the mirror mesh, composed up the local-transform
chain to `ModelRoot`, projected onto the plane perpendicular to the E-W axis)
rather than hardcoding it, so `rotation.x = ideal_tracking_angle − rest_offset`
lands exactly on the ideal angle regardless of the asset's rest pose (a
re-export keeps working). **Slewing is sim-time aware** (the sun is a function
of the sim clock, which can run at big time-scales or be scrubbed): each frame
the target is refreshed and the concentrator eases toward it with a smoothing
factor driven by BOTH real time (`_TRACK_TAU_REAL`/`_RESET_TAU_REAL`, so it
visibly eases in when the clock is idle) AND elapsed sim-hours from
`clock.get_absolute_hours()` (`_TRACK_TAU_SIM`/`_RESET_TAU_SIM`, so it stays
locked to the sun at any speed); a single-frame sim jump beyond
`_SNAP_SIM_HOURS` snaps instantly (fixes lag at high speed + crawl across
timeline scrubs). Below the horizon it stops chasing the sun and eases toward
the sunrise-ready pose (flat/facing up, angle 0 — an E-W axis can't face the
due-east dawn sun) over the slower reset constants, reading as "park at
sunset, slowly reset overnight". `CspTroughTracker` also paints the curved
mirror mesh (material `Metal_06_1K`) with a near-mirror `StandardMaterial3D`
(metallic≈1, roughness≈0.02). **Absorber-tube identification is geometric, not
by material name**: the model has TWO thin cylinders — an on-axis torque tube
(material `<LightGray>`, perpendicular offset ~0 from the pivot) and the real
solar-collector tube held at the focal line ~188 cm in front of the mirrors
(authored as a glass-envelope material). `_resolve_meshes` picks the thin/long
mesh (`length/cross ≥ _TUBE_MIN_ASPECT`) whose center is FARTHEST from the
local-X pivot axis (via `_relative_to_pivot`), so it glows the focal tube, not
the axis tube (the earlier `<LightGray>`-name heuristic wrongly lit the torque
tube on the rotation axis).

**"Blinding" focal-tube glow.** A plain self-emissive tube material reads as
flat white, not brilliant: this project's WorldEnvironment deliberately caps
DAYTIME bloom to a compact core (fine mips only, capped HDR luminance — see
`main.gd`'s glow setup comments) so ordinary bright surfaces don't wash out
daylight scenes; pushing raw emission higher barely helps once past that cap.
`_update_glow` (per-frame, from `_refresh_target`) therefore drives THREE
layered elements off the same `focus = clamp(dni × cos_incidence /
_GLOW_REF_WM2, 0, 1)` (already cloud- and low-sun-angle-attenuated) with a
shared perceptual gamma curve (`_GLOW_GAMMA`) and an ember→white-hot color
ramp: (1) the tube's own emissive `StandardMaterial3D` (self-lit surface,
peak `_TUBE_EMISSION_PEAK`), (2) a child `OmniLight3D` (shadow/bake/GI-cost
disabled except a touch of `light_indirect_energy`, distance-fade for perf)
that actually lights the mirror/mount around the tube — the "this is really a
light source" cue bloom alone can't sell, and (3) a small camera-facing
additive glow card (`gameplay/csp_focal_glow.gdshader`, a soft radial-falloff
quad drawn straight into the HDR framebuffer — same trick as
`vegetation/camp_glow.gdshader`'s night-light dots) that reads as a convincing
hot point independent of how conservative the daytime bloom tuning is.
**Positioning/scale gotcha:** the GLB has an internal `Node2` ancestor between
`ModelRoot` and `Component#453` carrying a baked 0.0254 (inch→metre) scale
(confirmed empirically) — a light/card parented directly under the tube mesh
would have `omni_range`/card size silently divided by ~39, and spatial
shaders have NO built-in `billboard` render_mode (must face the camera by
hand in the vertex stage via `MODELVIEW_MATRIX`, as `camp_glow.gdshader`
already does — `render_mode billboard` does not exist and fails to compile).
So the light + card are children of `CspTroughTracker` itself (a sibling of
`ModelRoot` under `PlacedProp`, already real-world metres) with their LOCAL
position resynced every `_process` via `_local_chain_transform(_tube_mesh,
_model_root)` — pure local-transform composition, the same technique
`_measure_rest_offset_rad` already uses, robust regardless of the GLB's
internal scale/rest-pose quirks and not dependent on `global_transform` cache
timing. `SystemGraphView._tick_graph_csp` (same cadence/
pattern as `_tick_graph_renewables`) is the authority for telemetry + resource
ports: each tick it computes real sun az/el (`SolarPosition` +
`main.clock.get_julian_day_utc()`) and weather (`SolarIrradiance.sample_weather`),
calls `CspTroughSource.simulate()`, and writes the result onto `specs`
(tracking angle, DNI, end loss, thermal_output_kw) plus `specs.inputs[0].rate`
(water L/h) / `specs.outputs[0].rate` (steam kg/h) so `ResourceFlowEngine`'s
generic tank-throughput logic moves the mass (density 1 kg/L, so the two rates
are numerically equal — mass-conserving). `efficiency: 1.0` / `energy_source: ""`
on the preset bypasses the generic power-draw gating (the CSP is passive — no
AC/DC energy port). Tracking math (`tracking_angle_deg`/`cos_incidence`) is a
pure function of sun azimuth/elevation, so it needs no hemisphere-specific
branches — a southern-hemisphere site's midday sun (in the north) tilts the
aperture the opposite way from the same formula. The E-W config's signature:
zero incidence at every solar noon (perfect, any elevation), worst at
sunrise/sunset (sun on-axis due E/W). New `"steam"` `ResourceKinds` entry +
a "Steam Buffer" resource-container preset close the loop. Self-test:
`_test_csp()` in `source_physics_selftest.gd` (E-W tracking/incidence,
hemisphere symmetry, and `tracking_offset_from_normal` regression checks
pinned to the GLB's measured rest-pose bias — the identity is covered without
loading the GLB).

**Terrain data services (autoloads, copy the weather_service HTTP+cache+deferred
pattern):**
- `core/terrain/elevation_service.gd` (`ElevationService`): DEM grid. No-key
  default = Open-Meteo Elevation (Copernicus 90 m). **Open-Meteo rate-limits
  CONCURRENT connections per IP (429), not request count** — so batches are
  fetched SEQUENTIALLY (POOL_SIZE=1, DISPATCH_DELAY between requests). A concurrent
  pool tripped 429 and fell back to flat terrain; sequential is reliable.
 DEFAULT_GRID_N=64 (configurable via `[terrain] base_dem_grid_n`) = ~41 serial
 Open-Meteo batches first visit (~30 s), then cached; ~470 m spacing over 30 km,
 upsampled to mesh res). **Detail DEM is fetched before the first walkable terrain
 build** (not lazy-loaded afterward). With an OpenTopography key it's a single
 512² AAIGrid; without a key the service caps the Open-Meteo detail fetch to
 OPENMETEO_DETAIL_N (64² ≈ ~47 m spacing) at ~40 serial requests. **Seam compose**
 (`TerrainBuilder` + `TerrainSeamDiag`): vertical offset alignment in the overlap
 ring, adaptive feather (80–800 m from boundary delta), exterior coarse ring blend,
 and player spawn gated until composed heightfield is ready. Configurable extents:
 `MapDefinition.half_extent_m` / `detail_half_extent_m` / `osm_half_extent_m` +
 location picker Advanced + in-game Terrain options. The `terrain_loader` used to
 gate detail behind post-terrain phases — detail now blocks terrain build. DEM caches,
 so the first visit per site pays the fetch once (inside the blocking load sequence)
 and every reload is an instant cache hit. Optional upgrade = OpenTopography SRTM 30 m
 when `user://terrain_config.cfg [opentopography] api_key=` is set (gitignored, never
 commit). 429/5xx → backoff retry (MAX_RETRIES=3). **Open-Meteo enforces a DAILY quota
 per IP** — when a batch returns `{"error":true,"reason":"Daily API request limit exceeded"}`
 (`_is_openmeteo_daily_limit`), the service fails FAST (no wasteful retries),
 latches `is_openmeteo_daily_exhausted()`, and the loader then SKIPS the no-key
 detail-DEM storm so OSM + vegetation phases aren't blocked ~20 min. **Cache
 recovery:** `find_usable_cached_dem(lat, lon, tag)` returns the best on-disk DEM
 for a site IGNORING the cache_enabled toggle; the loader's `_apply_elevation_fallback`
 (base) and `_recover_detail_dem_from_cache` (detail) use it so a quota/offline
 failure reuses the last good DEM instead of going flat. `grid_is_usable()` rejects
 flat 2×2 / zero-relief grids (both live results and corrupt caches, which are then
 deleted). Only when NO usable cache exists does it fall back to the flat 2×2 grid
 (with a user-visible "Elevation unavailable" warning). Each load phase in
 `terrain_loader._run_load_sequence` now has a TIMEOUT (`_phase_await(secs)`: base
 120 s, detail 300 s, OSM/veg 180 s) so a lost/stale callback can't hang the load
 forever; `ElevationService.reset_session()` cancels in-flight HTTP on each new load.
 Refresh/reset-fresh are blocked while `_load_sequence_active` or when quota is
 exhausted with no OpenTopography key (would delete cache with no way to refetch).
 Cache `user://terrain_cache/dem/` (CACHE_VERSION v3 bumps on grid-N default change).
 Both ElevationService + ImageryService print `served from cache — no download` vs
 `not cached — fetching …` per layer.
- `core/terrain/imagery_service.gd` (`ImageryService`): ESRI World Imagery XYZ
  JPEG tiles (no key), stitched + cropped to the bbox so UV 0..1 aligns with the
  mesh. Cache `user://terrain_cache/imagery/`. `attribution()` must be credited.
  (Raw Sentinel-2 JP2 is intentionally NOT used — Godot has no JP2 decoder; NDVI
  vegetation stays deferred to Pillar 8.) `request_imagery(lat, lon, half_extent,
  target_px, tag, max_zoom)` — `tag` (default "base") labels the layer and is
  echoed in `imagery_ready(key, tex, tag)`/`imagery_failed(reason, tag)`; multiple
  requests serialise through the one HTTPRequest via an internal queue (older 2-arg
  handlers still connect — Godot drops the extra arg). **High-res centre patch:**
  the loader fires a second "detail" request — a 1 km square at z18 (~0.3–0.5 m/px,
  vs ~15–25 m/px for the 30 km base) — and `terrain_detail.gdshader` blends it over
  the central region of the Ground mesh (feathered, no seam). It loads in the
  background and pops in after the base drape, so the world isn't gated on the
  larger fetch (`TerrainBuilder.make_terrain_material` builds the shader material;
  `terrain_loader._apply_detail` swaps it in). ESRI serves the SAME source up to
  z19–23 globally — close-range was low-res only because the base zoom packs all
  30 km into ~2048 px. USGS NAIP (US-only, no key) and Mapbox (key) were evaluated
  as additional sources but not wired (ESRI high-zoom covers it globally, no key).
- `core/terrain/ai_imagery_service.gd` (`AiImageryService` autoload): **opt-in**
  AI "hero patch" — after the hyper drape lands, `terrain_loader._maybe_request_ai_hero()`
  crops the central ~100 m square (`AI_HERO_HALF_EXTENT_DEFAULT` 50 m) out of
  `_hyper_drape` and sends it to Gemini `gemini-2.5-flash-image` (nano-banana,
  image-in/image-out) to sharpen + add photoreal fine ground detail beyond the
  ESRI ~0.24 m/px ceiling where the player spawns. One 2K image per site, cached
  to `user://terrain_cache/ai_imagery/` (so ~$0.04 one-time), overlaid on top of
  hyper in `terrain_detail.gdshader` via the feathered `ai_*` uniforms
  (`_apply_ai_to_terrain`, re-stamped in `_stamp_drape_mercator_bboxes`). Key:
  `user://terrain_config.cfg [gemini] api_key=` (or `GEMINI_API_KEY` env);
  `ai_hero_enabled`/`ai_hero_half_extent_m`/`ai_image_size` also live there.
  Default OFF (no surprise API charge); toggle + **Generate/Regenerate** in the
  Terrain options UI, `refresh_ai_hero()` deletes the cache and re-requests (also
  folded into `refresh_all_cached_layers`). Generative — it only recolours ground
  (buildings/roads/veg are separate meshes) and the prompt pins framing/positions,
  so drift is cosmetic; output carries an invisible SynthID watermark. No key /
  offline / disabled → clean no-op, world still loads.
- `core/terrain/geo_math.gd` (`GeoMath`) + `core/terrain/terrain_builder.gd`
  (`TerrainBuilder`): pure static math (tile/Mercator/extent; ArrayMesh +
  HeightMapShape3D collision). Both covered by `terrain_selftest.gd`.
Both services emit `*_ready`/`*_failed`/`*_progress`; offline → loader falls back
to a flat grid / neutral drape so the world still loads.
- `core/terrain/vegetation_osm_service.gd` (`VegetationService`): one Overpass
 request per site → polygons (wood/forest/scrub/orchard/grass…), `tree_row` lines,
 `barrier=hedge` lines, and `natural=tree` points; feeds AutoVegetationGenerator's
 scatter phases. Cache `user://terrain_cache/osm_vegetation/`. **Cache serializer
 must include `hedge_rows`** — it previously omitted them, so cached reloads
 silently dropped every hedge (fresh fetch had them, cache didn't); fixed +
 CACHE_VERSION bumped v4→v5. Any new payload key needs matching
 `_serialize_payload`/`deserialize_payload` entries or it vanishes on reload.

**Vegetation paint + live preview (`scenes/ui/vegetation_edit_ui.gd`,
`scenes/ui/vegetation_preview_editor.gd`).** V toggles the bottom paint dock
(paint/place/clear/select, density, shape tools, Advanced per-species sliders).
**Tune look…** opens a modal with an isolated `SubViewport` studio (neutral ground +
fixed key/fill lights) showing a configurable-diameter preview patch filled via
`VegetationCardFactory`/`GrassBuilder` MultiMesh scatter; right sidebar has veg-type
dropdown, density, patch diameter, per-species shape sliders, tint, and shader knobs.
Live edits debounce ~0.1 s; **Apply to map** writes through
`terrain_loader.set_vegetation_settings` / `set_vegetation_style` (same persistence as
the dock). Per-tree layout knobs (Tune look + Advanced): pine `pine_whorl_count`,
`pine_bough_scale`, `pine_whorl_spacing` (whorls centered on trunk); deciduous
`deciduous_cluster_count/spread/size/tightness`, `deciduous_branch_count/thickness/reach/base`;
shrub `shrub_cluster_count/spread/size`. Style defaults + per-map JSON in `vegetation/vegetation_style_config.gd`.

**OSM → species binding (Tune look… modal "OSM → tree type" section).** The player
picks which shader species fills each OSM area kind: `wood`/`scrub`/`park`/`cemetery`/
`orchard`/`vineyard`/`wetland` → `auto` (biome) | `pine` | `deciduous` | `shrub` |
`mixed`. Stored as `style["osm_species_map"]` (kind→choice dict, JSON round-trips via
`VegetationStyleConfig`). `BiomePalette.MAPPABLE_KINDS` / `SPECIES_OVERRIDE_OPTIONS`
drive the UI; `BiomePalette.species_override_for_kind()` returns a weight dict (or {}
for auto) that `AutoVegetationGenerator._scatter_polygon` applies over the biome/tag
default (row crops use `override_single_species`). Changing the map requires a FULL
generator re-run — `terrain_loader._osm_species_map_changed` (inside
`_forest_params_changed`) triggers `_full_regenerate_auto_vegetation`. NOTE: a
format-string bug in `VegetationCardFactory._foot_settings_key` (12 specifiers vs 13
args) used to spam a runtime error on every scatter batch → slow, error-flooded veg
loads; fixed to 13 specifiers.
Card meshes + materials: `vegetation/vegetation_card_factory.gd` → `foliage.gdshader`
(canopy) + `bark.gdshader` (trunks); shared wind in `wind_vertex.gdshaderinc`.
Configurable realism uniforms (no extra texture fetches): `translucency_strength`,
`canopy_roundness`, `color_variation`, `foliage_roughness`, `ao_strength`,
`subsurface_strength`, `bark_roughness`, `bark_ao_strength`, `bark_color_jitter`.

**OSM water (`core/terrain/water_builder.gd` + `osm_water_parser.gd`).** Two
surfaces under the `Water` node: **still water** (lake/pond/reservoir/wetland/bay)
is one flat plane per body at a low percentile of bank heights (`terrain_water.gdshader`
+ per-lake ReflectionProbe); **flowing water** (`FLOWING_KINDS` = river/stream/canal/
ditch/drain/riverbank) is **draped per-vertex onto the terrain** so the ribbon follows
the downhill contour instead of floating as one flat plane (the old ~10 m "hover"
bug). Per-vertex COLOR encodes local downhill flow (rg = −∇height dir, b = slope-scaled
speed); `terrain_river.gdshader` scrolls ripples + foam streaks downstream, faster on
steeper reaches. `_ground_y` cross-fades the detail↔base DEM heights within
`DEM_SEAM_FEATHER_M` (40 m) of the hi-res patch edge so ribbons don't step at the seam.

**Terrain sculpting (T dock — the rebuilt terrain builder).** ONE edit substrate:
`core/terrain/terrain_edit_tiles.gd` (`TerrainEditTiles`) — sparse per-vertex
height DELTAS at 1.5 m/cell in 64-cell tiles allocated only where edited, with
region-scoped undo sessions + binary persistence (`user://maps/terrain_tiles_*`).
Ops in `core/terrain/terrain_sculpt_ops.gd` (raise/lower/smooth/flatten brushes,
`level_polygon`, `ramp`, `carve_basin`); loader commands `brush_stamp` /
`level_region_command` / `ramp_command` / `pond_command` (carve + optional seed puddle;
water folded into the SAME undo entry as the carve). **Rendering is an overlay,
NOT a bake**: the detail DEM mesh is far too coarse (~12–47 m/vertex) to show a
1.5 m edit — `core/terrain/terrain_height_field.gd` (`TerrainHeightField`, node
"HeightField" under Terrain) renders each edited tile as its own hi-res mesh +
`HeightMapShape3D` collider (base_fn returns WORLD Y — no second centring), dirty
tiles re-mesh live during a drag (budgeted; `reconcile_dirty_now()` drains fully on
commit/undo BEFORE the sink refresh so actors never lose footing). The coarse
DetailGround mesh+collider are SUNK `TILE_SINK_HEADROOM_M` (60 m) beneath the
interior of active tiles (`_detail_mesh_grid_with_sink`; boundary ring follows the
local cut) so cut bowls/ponds are neither occluded nor bridged — tile skirts
(`SKIRT_DROP_M` 65 m, must exceed the sink; selftest-pinned) seal the chasm at
cut boundaries. Footing: `_ground_height_at = composed DEM + tile delta`; commits
call `_reseat_actors_after_edit()` (lift only if buried — lowering lets gravity
work). Tile meshes share DetailGround's drape material (re-pointed via
`set_material` whenever imagery lands). Legacy coarse/detail delta grids +
earthworks migrate one-time into tiles (`_migrate_legacy_edits_to_tiles`).
Validate with the `--sculpt-test` harness (above) + terrain_selftest.

**Ponds are player-owned, never auto-added to the graph.** `pond_command` carves a
basin and optionally seeds a thin puddle; **Rain** / **Drain** (T dock) hold-modulate
`level_m` toward spill with bathymetric `stock_l`/`capacity_l` (Auto). Persisted per
site in `user://maps/user_water_*.json` (`level_m`, `capacity_mode`/`fill_mode`,
`capacity_l`, `stock_l`, …). The player Ctrl/Alt-aims a still-water body
(`interaction_focus._update_water_focus` → `pick_water_at_world`, highlights blue)
and Interact/clicks to open the **Pond settings modal**
(`scenes/ui/pond_edit_ui.gd`): level, Capacity Auto/Manual, Fill Auto/Manual,
**Add to graph / Remove**, **Delete**. Graph tank twins Auto bathymetry via
`sync_pond_level_from_mesh`. Membership via `SystemGraphView.has_pond_with_tag`.

`main.gd` (~1,900 lines) owns: environment/sky, shadow quality, collision
generation, save/load orchestration, vehicle/death-zone/crisis wiring.
World clock + astronomy live in `core/celestial_clock.gd` (`CelestialClock`,
owned by Main as `clock`); main.gd keeps delegating properties:
`year`, `month`, `day`, `day_time` (0–24 h), `latitude`, `longitude`,
`time_scale`, `sun`, `moon`.

Main scene UILayer (CanvasLayer) children by name (looked up by other code):
TimeUI (legacy hidden shim), GameOverUI, SolarUI, InteractionPromptUI, CrosshairUI,
EUCUI, HealthUI, HAConnectionUI, SaveLoadUI, SystemGraphView, TimelineUI,
CsvPlaybackUI, ProjectionCanvas, POVWarpOverlay, LocationPickerUI. HAClient
(HA WebSocket, `ha_websocket_client.gd`) is a direct child of Main, NOT an autoload.

**Timeline-centric UI (replaces ESC TimeUI panel):** `TimelineUI` owns date
Y/M/D spinboxes, play/pause (Space releases mouse), and a gear settings drawer
(clouds, sun/moon/shadows, location, live mode, survival). `SimSettingsController`
autoload holds the shared logic; `TimeUI` only forwards signals for backward compat.
`CursorController` autoload owns mouse capture (play vs pause vs modal). Center-screen
`CrosshairUI` + `InteractionFocus` on Player drive crosshair interactables (group
`interactables`, base `gameplay/interactable.gd`).

## Autoloads (project.godot)

| Name | Script | Role / key signals |
|---|---|---|
| DeviceRegistry | power_system/core/device_registry.gd | Consumer registry; `total_power_changed(w)` |
| AutomationEngine | power_system/automation/automation_engine.gd | HA-style rules @0.1s; exports HA YAML |
| SaveSystem | core/save_system.gd | 8 slots + autosave, SAVE_VERSION=2, user://saves/ |
| GhiService | location_picker/ghi_service.gd | NASA POWER GHI grid (data/ghi-grid.json) |
| InverterBridge | core/inverter_bridge.gd | Mirrors ~80 live HA entities (EcoWorthy + Shelly) |
| TimeDirector | core/time_director.gd | Authority over sim time: modes (LIVE/PLAYBACK/SIMULATE), NOW anchor, playhead, provenance; `mode_changed`/`playhead_changed`/`now_changed` |
| SimMode | core/sim_mode.gd | Compatibility shim over TimeDirector (preserves is_live/should_run_realworld_actions/etc.) |
| GameplayRules | gameplay/gameplay_rules.gd | Survival toggles, sync with main.gd |
| CameraServerBootstrap | godot/StarShadeConsole/scripts/camera_server_bootstrap.gd | OBS virtual camera |
| WeatherService | core/weather_service.gd | Open-Meteo archive weather, cached per location/year |
| ElevationService | core/terrain/elevation_service.gd | DEM grid: Open-Meteo (no key) / OpenTopography (key); `elevation_ready/failed/progress` |
| ImageryService | core/terrain/imagery_service.gd | ESRI World Imagery XYZ drape; `imagery_ready/failed/progress` |
| AiImageryService | core/terrain/ai_imagery_service.gd | Opt-in Gemini "hero patch" ground enhancement (image in/out); `ai_imagery_ready/failed`; key `[gemini] api_key` / `GEMINI_API_KEY` |
| MultiplayerSession | core/multiplayer/multiplayer_session.gd | Listen-server co-presence (ENet host/join, avatars, host clock) + Phase 3–4 design share/ghost-merge + live graph/props sync (`Design` child) + Phase 5 session text chat (`Chat` child; Enter compose, proximity bubbles, mute, Discord invite deep-link) + Phase 6 hardening (join-code expiry, optional password, trusted-key allowlist, peer/snapshot caps, rate-limit kicks, local `user://mp_telemetry.log`); lobby via Timeline **Multiplayer** chip |
| MapContext | core/terrain/map_context.gd | Transient lat/lon hand-off to generated map scene (pre-`change_scene`) |
| CursorController | scenes/ui/cursor_controller.gd | Mouse capture policy: play/pause/modal stack |
| SimSettingsController | scenes/ui/sim_settings_controller.gd | Date/location/clouds/lighting/live mode; `live_mode_changed` / `simulation_started` |

## Energy sources (power_system/sources/)

`EnergySource` (base, group `"energy_sources"`): signal
`power_updated(instant_kw, daily_kwh)`; `get_current_power_kw()`,
`get_daily_energy_kwh()`, `get_peak_capacity_kw()`; finds Main for the world
clock. `contribute_to_grid=false` opts out of the grid balance
(SolarPanelSource does this — SolarUI models solar internally).

- `SolarPanelSource` (solar_calculator.gd, repo root) — PV estimator.
- `WindTurbineSource` + `WindTurbineConfig` — P=½ρACpv³ (Manwell et al.),
  Betz cap 16/27, ISA density, log-law shear. Default: default_wind_1kw.tres.
- `HydroSource` + `HydroConfig` — P=ρgQh_netη (Paish 2002), Darcy–Weisbach via
  Swamee–Jain, monthly flow multipliers. Default: default_hydro_500w.tres.
- `CspTroughSource` (`power_system/sources/csp_trough_source.gd`, static, no
  3D EnergySource node — not an electrical source) — parabolic-trough CSP:
  single-axis N-S tracking law `cos θi = sqrt(1-(cosEl·cosAz)²)` (general
  1-DOF-tracker incidence formula; zero loss when the sun is due east/west,
  worst at solar noon high in the south — the real, documented "cosine loss"
  of N-S trough fields), Duffie & Beckman finite-length end losses, DNI via
  `SolarIrradiance` + cloud attenuation, water→steam boil-off (cp + h_fg).
  `simulate(specs, sun_az, sun_el, weather)` returns tracking angle +
  telemetry + `water_lph`/`steam_kg_h`.
- Static graph adapters: `power_kw_from_graph_specs(specs, hour|month)` drive
  the 2D graph items — extend these (not the canvas) for new physics params.

SolarUI sums contributing sources via `_poll_aux_generation()` into
`current_aux_generation_kw` → battery balance + HUD net.

## System graph (system_graph/ + system_graph_v2/) — **core gameplay surface**

**Vision:** `SYSTEMS_GRAPH_VISION.md` (SoI, Planetary Basic Income catchments, ISRU
catalog, TouchDesigner nested canvases, sim↔real calibration). ROADMAP Pillar 9 +
Phase 8.

One view: `system_graph/system_graph_view.gd` (G toggles), using the V2 canvas
`system_graph_v2/graph_canvas_v2.gd` (extends graph_canvas.gd). Type
registries in graph_canvas.gd: PORT_COLORS / NODE_BORDER_COLORS / NODE_SIZES /
HANDLES / `_type_title`. Library presets: `system_graph/data/component_presets.gd`
(types: panel, wind, hydro, battery, smartbattery, controller, appliance,
acload, processor, resource, shelly4pm, compound). Inspector forms:
`inspector_panel.gd` `_rebuild_for_item` match. Solar mirroring:
`solar_bridge.gd` (virtual_* items @0.25s). Wind/hydro live refresh:
`system_graph_view._tick_graph_renewables()`. Multi-resource flow:
`resource_flow_engine.gd` + `ResourceTimeline` (scrub-safe tanks). Typed resources:
`resource_kinds.gd` (water, biomass, plastic_waste, …). Nested scopes:
`_active_scope_id` / compound Enter-Back (partial TD-style drill-in).
Graph state round-trips via `collect_save_state()`/`apply_save_state()` + per-scene
autosave JSON. **Overhaul direction:** SoI metadata, PBI catchment nodes, full
compound promoted ports, ISRU catalog beyond electrical, 3D↔2D node binding,
observed-vs-sim calibration per resource channel.

**SketchUp-style components (`system_graph/data/graph_component_defs.gd` +
`GraphModel.definitions`).** A generic super-node can be promoted to a reusable
**component definition** (inspector **Save as Component** → names it, mints a
`def_id`, persists to `user://user_presets.json` under the "My Components"
library category with nested defs). Each placement is an **instance**: a generic
compound with `specs.definition_id`/`definition_rev`, its child scope a realized
copy whose children carry `specs.def_local_id` linking them to template slots.
`GraphComponentDefs` (static): `realize` (recursive, multi-level — nested
template items reference other defs by id), `capture` (rebuild a def from a live
instance, strip `INSTANCE_ONLY_SPEC_KEYS` = SOC/telemetry/HA/3D/site/`*_tag`, bump
rev), `restamp` (reconcile a sibling to the def, matching by `def_local_id` so
per-instance state + external wires by stable handle id survive), `make_unique`
(detach). **Live propagation:** a structural edit inside an instance debounces
(`_component_sync_timer`, 0.15 s) → `_flush_component_sync` captures that
instance's def and re-stamps every sibling; re-entrancy-guarded by
`_component_sync_active` + `_history_suppress`. Built-in defs live in
`ComponentPresets` (`builtin_definition`/`builtin_component_tree`/
`component_preset_entries`) under the **Super-nodes** category; **StarShade** is a
3-level tree (array `starshade_solar_array` 3S×6P / hybrid inverter
`starshade_hybrid_inverter` CC+inverter / battery bank `starshade_battery_bank`)
that `StarShadeGraphSeeder.seed_graph` now realizes (with `source`/`starshade_tag`
as instance-only identity so dedupe/clear/HA still work) instead of flat nodes.
Model v6→v7 adds the `definitions` registry (old saves load empty). Ctrl+G group
/ Ctrl+Shift+G explode. Zoom drill-in/pop-out is now seamless (child bbox mapped
onto the collapsed body rect then tweened to fit + a short content fade — see
`graph_canvas.gd` `begin/finish_enter_transition` + `begin/finish_pop_transition`);
collapsed compounds draw + hit-test ALL promoted handles. **All super-node ports
follow the base graph's top-to-bottom flow: inputs across the TOP edge, outputs
across the BOTTOM edge** (`_distribute_handles` / `_distribute_compound_handle_positions`
/ `_compound_handle_pos`); when inside a child scope the boundary **portal pills**
dock along the top (inputs) / bottom (outputs) edges and draw a marching connector
wire down to the child port each fronts (`_draw_portal_pill_row`). PV Voc grouping
is now **series-aware** (`PvElectrical.connected_components(..., series_only=true)`:
only +→− links merge a string, +→+ / −→− are parallel) so the StarShade array's
**3S×6P** reads as six 3-panel strings (~112 Voc) instead of one 18-panel series
string (>600 Voc) — the controller no longer over-volts. A super-node may carry
`node_banner`+`model_id` (+`icon_replaces_frame:false`) to render its 3D subject's
GLB thumbnail as a 2D banner filling the node body instead of the child-graph
miniature (`_draw_compound_banner`, same preview path as processor cards) — the
StarShade definition does this. Self-test: `system_graph/graph_components_selftest.gd`
(includes a 3S6P no-over-voltage regression check).

## HA digital twin (working today)

Direct WebSocket: HAClient (scene child) → InverterBridge (autoload) →
HAEntityLinker (`system_graph/ha_entity_linker.gd`) gated by
`SimMode.should_apply_live_data()`. Historical replay:
`core/csv_history_player.gd` (HA CSV exports). Real-load measurement:
`system_graph/load_calibrator.gd`. Automation push: AutomationEngine YAML +
`system_graph/ha_automation_pusher.gd`. NOTE: ROADMAP.md Pillar 5 prescribes a
HACS-integration architecture instead — that is a migration decision, do not
rebuild the bridge without an explicit call.

## Location (single source of truth)

`main.gd` owns `latitude`/`longitude` (full GPS precision; they delegate to
`clock`). **All location changes route through `main.apply_location(lat, lon,
label="", persist=true)`** — it sets the coords (sun/moon/stars are pure clock
functions, so they follow for free), persists to `user://location_prefs.cfg`
(actual lat/lon + label, not just a flag), and emits `location_changed(lat, lon)`.
`WeatherService` re-fetches on its own location poll (`_process` compares
`covers()`); no explicit weather call is needed.

- **Persistence across playtests:** `_load_location_prefs()` runs in `_ready`
  (after `_init_from_system_time`), restoring the last chosen site independent of
  save games. Save-load also routes through `apply_location` so a loaded location
  persists and syncs every UI.
- **Entry points (all unified):** TimelineUI gear settings + lat/lon SpinBoxes
  (step 1e-7), LocationPickerUI (M key — map click, address geocode, or typed
  WGS84 coords via "Use coords"), and save-load. Legacy TimeUI node remains hidden.
- `location_prefs.cfg` is gitignored (user pref, never committed).

## Weather (Open-Meteo)

`core/weather_service.gd` (autoload `WeatherService`): two data sources,
seamlessly merged in `sample()`:
- **Archive** (`archive-api.open-meteo.com`): one full calendar year of hourly
  data cached at `user://weather_cache/`. Sim years without complete archive
  coverage (current/future) substitute the latest complete year via
  `effective_year()`.
- **Forecast** (`api.open-meteo.com`): 5 past + 16 future days (~21-day window),
  fetched daily when `_sim_year == current calendar year`. Stored in
  `_forecast_series` with `_forecast_start_hoy` (hour-of-year of first entry).
  `sample()` silently prefers forecast data for dates in the window; archive is
  the fallback. No UTC conversion — `timezone=auto` + pure calendar arithmetic.

Variables: shortwave_radiation, diffuse_radiation, wind_speed_10m,
temperature_2m, precipitation, cloud_cover.
Signals: `weather_data_ready(lat, lon, year)`, `weather_fetch_failed(reason)`,
`forecast_data_ready(lat, lon)`, `forecast_fetch_failed(reason)`.
Public helpers: `has_data()`, `covers(lat, lon)`, `has_forecast()`,
`is_forecast_date(month, day)`, `effective_year(sim_year)`.
Connect `forecast_data_ready` BEFORE calling `request_forecast()` (same
deferred-emit pattern as the archive signal). Consumers: solar_ui
`_try_apply_open_meteo_weather` (sets `_forecast_active` flag when in window),
WindTurbineSource (real 10m wind), HydroSource monthly multipliers.
Synthetic fallback must always keep working offline.
UI indicators: 🌤 green-teal = live forecast; 🌎 blue = historical archive;
📡 = live HA; 🔄 = synthetic.
**No manual weather picker.** Open-Meteo drives automatically whenever a dataset
covers the location (synthetic only fills offline/uncovered gaps); solar_ui
`_update_weather` always calls `_try_apply_open_meteo_weather()`. The bottom-bar
weather control is a non-interactive **source indicator** (`_wx_source_lbl` in
timeline_ui), not a toggle. The legacy `set_weather()`/`cycle_weather()` manual
state machine is retained in code but no longer wired to any UI.

## Solar physics (SolarUI + SolarPanelSource)

Standard mode (always-on, default):
- DNI from Kasten-Young atmospheric transmittance formula
- NOCT cell temp: `T_cell = T_amb + (NOCT-20)*G/800`, NOCT=45°C
- Temperature derating γ = -0.004/°C: `factor = 1 + γ*(T_cell-25)`
- `_estimate_ambient_temp()`: prefers `WeatherService.temperature_c()` when
  Open-Meteo data is active; falls back to synthetic 15-38°C diurnal cycle
- Sun position from `main_node.sun` (DirectionalLight3D, driven by CelestialClock)

High-accuracy mode (`_high_accuracy_physics = true` in Panel Settings):
- `core/solar_position.gd` (`SolarPosition`): Meeus Ch.25 + Bennett refraction,
  ~0.01° accuracy; `get_position(lat, lon, jd_utc)` → `{elevation_deg, azimuth_deg}`;
  requires `main_node.clock.get_julian_day_utc()` (falls back to DirectionalLight3D)
- Erbs (1982) diffuse fraction: decomposes real GHI (from WeatherService
  `solar_radiation_wm2`) into DNI+DHI → tilted-plane POA via isotropic sky model;
  falls back to geometric DNI when no real data
- Optional 3D shadow: single `PhysicsDirectSpaceState3D.intersect_ray()` toward sun
  from `Vector3(0, _shadow_sample_height, 0)` or node in group "solar_panel_location";
  enabled separately by `_shadow_raycast_enabled`
- Both flags persisted to `user://solar_panel_config.cfg` (`high_accuracy`, `shadow_raycast`)
- Panel Settings UI: two CheckButton toggles at bottom of settings panel

Self-test: `power_system/sources/source_physics_selftest.gd` (97 checks total)
includes solar-physics checks (NOCT formula, gamma derating, SPA horizon, cos_incidence).

## Time & simulation (timecode, modes, reversibility)

**Timebase.** `core/celestial_clock.gd` (owned by Main as `clock`) is the
authoritative, reversible clock. `main.gd:_process` does
`day_time += delta * time_scale` (time_scale may be negative → time runs
backward; the `day_time` setter rolls the date both directions). The canonical
timecode is **absolute hours since year 1 Jan 1 00:00**:
`clock.get_absolute_hours()/set_absolute_hours()` (passthrough on main.gd). Sun,
moon, sky, and `WeatherService.sample()` are pure functions of the clock, so they
scrub correctly in both directions for free.

**Modes.** `TimeDirector` autoload owns mode + NOW + playhead + provenance:
- `Mode { LIVE, PLAYBACK, SIMULATE }`, resolved by: history latch (PLAYBACK) →
  explicit user pin (`set_explicit_mode`/`clear_explicit_mode`) → legacy
  heuristics. `now_abs_hours` = real wall clock; `playhead_abs_hours` = sim time.
- `provenance_at(abs_hours) → {REAL, OBSERVED, PROJECTED, RECORDED}` for UI.
- `core/sim_mode.gd` is now a thin shim delegating to TimeDirector (its public
  API and `Mode {LIVE,SIMULATE,HISTORICAL}` enum are unchanged for consumers).

**Reversible battery (the key invariant).** The battery is a path-dependent
forward integrator (efficiency losses + 0/100% + SOC-floor clamps) and cannot be
reversed analytically. `core/energy_timeline.gd` (`EnergyTimeline`, owned by
SolarUI) samples SOC + solar/aux/load into a fixed-step buffer keyed by absolute
hours. `solar_ui.gd:_update_battery` integrates **forward** (record_step) and
reads SOC **back** from the buffer when scrubbing, so the battery "uncharges"
exactly along the curve it charged. **HA SOC only drives the battery in LIVE mode**
(`SimMode.is_live()`); in SIMULATE/PLAYBACK the timeline owns SOC so scrubbing
rewinds it (otherwise a live HA reading pins the battery and it never uncharges).
While LIVE, the measured SOC is mirrored into the buffer
(`EnergyTimeline.record_measured`) so the user can scrub back through real recorded
history. Daily scoreboard counters are derived queries
over the buffer (`_recompute_scoreboard_from_timeline`); the 24h graph
(`_update_solar_history`) and load line are buffer views. The pure step math
(`EnergyTimeline.step_soc`) mirrors the old `_integrate_power_step`. Determinism:
the synthetic-weather fallback is seeded by absolute time (`_det_unit`), never
`randf()`, so replays reconstruct exactly. On load, `energy_timeline.clear()`
re-anchors at the loaded SOC.

**UI.** `timeline_ui.gd` replaces the 24h slider with a custom-drawn multi-day
absolute-time track (`_draw_track`/`_on_track_input`, ±~3.5 days, dead-zone
scrolling) with a white **NOW** marker, an amber playhead, provenance color bands
(teal=observed, lavender=projected, green=recorded), and **mode + data chips**
(`_update_mode_chips`). Dragging calls `set_absolute_hours`.

Self-test (`source_physics_selftest.gd`, now 97 checks) covers abs-hours
round-trip, reversible SOC (forward-then-rewind), provenance boundaries, the
unix↔abs bridge, ObservedSeries resampling, and batch-render determinism.

## Observed-vs-simulated comparison (NLE batch render)

Import a real HA datastream and compare it against a deterministically
re-simulated curve over the same dates — the realized "pre-render a day/week"
feature built on the EnergyTimeline + `set_evaluator` substrate.

**Data alignment.** `core/celestial_clock.gd` adds pure helpers
`unix_to_abs_hours()` and `abs_hours_to_julian_day_utc()` (+ `abs_hours_to_date()`)
so CSV wall-clock timestamps land on the same absolute-hours axis as the sim, and
a render at the CSV's dates pulls the real archived weather for those days.

**Observed track.** `core/observed_series.gd` (`ObservedSeries`) resamples the
CSV's role timelines (battery_soc%→kWh, solar/load W→kW) onto the EnergyTimeline
grid via zero-order hold; `sample_at`/`integrate_channel` mirror EnergyTimeline.
`core/csv_history_player.gd` gains a **clip mode** (`load_clip()`): parse-only, no
world-clock takeover, emits `clip_ready`; `build_observed_series()` produces the
ObservedSeries. SolarUI owns its own `ObservedClipPlayer` child for imports
(separate from CsvPlaybackUI's replay player).

**Evaluator + render.** `solar_ui.gd:evaluate_inputs_at(abs_hours)` is a *pure*
function of time (no scene sun, no HA overrides): solar via Meeus SPA + the shared
`_compute_solar_kw` POA core + WeatherService sampled at that instant; load is
either the observed CSV load (default — isolates solar/weather-model error) or a
deterministic `_modeled_load_at` (baseline + time-scheduled lights), per the
`RenderLoadMode` toggle. `core/batch_renderer.gd` (a SolarUI child Node) drives
`EnergyTimeline.fill_forward_chunk()` ~240 steps/frame into a dedicated
`_sim_series`, anchored at the observed SOC so divergence is pure model drift.

**NLE timeline UI.** `timeline_ui.gd`'s track grew to stacked lanes: the time
ruler/playhead (lane 0) plus an amber **Observed (CSV)** clip and a cyan
**Rendered (sim)** clip (with a render-progress fill). Shift-drag sets the
render in/out selection (defaults to the full clip). A controls row adds
**Import datastream…**, **Render selection**, the **Load: CSV/Modeled** toggle,
and **Compare**. `BAR_HEIGHT` is 164 (scene `TimelineUI` offset_top/min-size match).

**Split-screen compare.** Reuses the "I" `ProjectionCanvas` BL(sim)/BR(observed)
panels: `set_compare_mode()` suspends its live mirror + rolling-history sampler,
and SolarUI's `_tick_compare_feed()` pushes one synced frame each tick
(`feed_comparison(payload)`) — both panels, graphs, and Δ labels driven by the one
playhead. `TimeDirector.register_observed_range()` makes provenance read OBSERVED
inside the clip; `set_compare_active()` is a flag (compare rides on PLAYBACK/SIM,
not a 4th mode).

## Site Report (interactive infographic)

Full-screen modal giving a **deep single representative year, month-by-month**
site analysis: solar radiation resource (GHI), PV potential of the *current graph*,
windrose + wind energy potential, rainflow/precipitation, temperature bands, and
hydro potential (when the graph has hydro). Opened by the timeline toolbar **📊**
button (`timeline_ui._on_site_report_pressed`, lazy-instantiated like the Record
Book) or the `toggle_site_report` input action (**K**, routed via
`main._unhandled_input`). New files under `core/report/` + `scenes/ui/`:
- `core/report/site_report_metrics.gd` (`SiteReportMetrics`, pure static): calendar
  ↔ absolute-hours (same proleptic-Gregorian epoch as `CelestialClock`, so it feeds
  `SolarUI.evaluate_solar_at`), 8760-hour monthly aggregation (sum/mean/min/max,
  wet-day counts), windrose sector binning, capacity factor, peak-sun-hours.
- `core/report/site_report_data.gd` (`SiteReportData`): typed container (12-length
  monthly arrays + annual scalars + site header + `capacity_signature`) with
  `to_dict()`/`from_dict()` JSON round-trip.
- `core/report/site_report_builder.gd` (`SiteReportBuilder extends Node`): async,
  chunked (`DAYS_PER_CHUNK` days/frame, mirrors `batch_renderer`) engine. Samples
  `WeatherService` for radiation/wind/precip/temp, reuses `SolarUI.evaluate_solar_at`
  for PV yield (graph-synced capacity/tilt/azimuth), enumerates graph `wind`/`hydro`
  items via `model.get_items_in_scope("root")` → `WindTurbineSource`/`HydroSource`
  adapters. Uses `WeatherService.effective_year(sim_year)` for the representative
  year. Caches to `user://site_reports/report_v1_<lat>_<lon>_<year>.json`, keyed by a
  `capacity_signature` (site + PV + turbine/hydro specs + weather source) so an
  unchanged report re-opens instantly and a graph/site change invalidates it.
- `core/report/site_report_selftest.gd`: offline deterministic selftest (57 checks:
  abs-hours vs CelestialClock, windrose bins, monthly aggregation, wet days, capacity
  factor, data round-trip, and a UI-script compile smoke since the panel/charts have
  no `class_name`).
- `scenes/ui/site_report_charts.gd` (`SiteReportCharts`, static): `UITheme`-styled
  drawers — `draw_monthly_bars`, `draw_temp_band`, `draw_windrose` (+ `windrose_sector_at`).
- `scenes/ui/site_report_panel.gd`: dim-backdrop centered modal (record_book pattern),
  scrollable cards (solar/PV/windrose/wind/rain/temp/hydro) with per-month hover, a
  compute-progress overlay, `Recompute` button, and `CursorController.request_modal`.
  Ensures weather coverage (fires `request_weather`, waits on `weather_data_ready`
  with a timeout) before building; offline → PV still computes via clear-sky geometry.
First-draft limits (stated in the panel footnote): single representative year (no
multi-year/decade or `ClimateProjectionService` scenarios yet), PV uses SolarUI's
global tilt/azimuth and ignores 3D shading (live-only), no PNG export.

## Linkage Lab (scissor-linkage designer port, `core/linkage/`)

Native Godot port of the LinkageLab three.js web app (parametric folding
deployable structures via compound scissor mechanisms). **N key** or the unified
library "Linkage Lab…" entry opens the full-screen designer modal. All solver
math is **inches internally** (pinned 1:1 against JS reference values), converted
to metres (×0.0254) only in the mesh builder.
- `linkage_params.gd` (`LinkageParams`, RefCounted): full parameter model; `to_config`/
  `from_config` round-trip the web app's v30 config JSON (structure/mode/foldAngle/
  panels/supportBeams/visibility) so web designs load directly and vice-versa.
- `linkage_kinematics.gd` (static): closed-form `calculate_joint_positions`,
  `optimal_closed_angle` (ring-closure scan), `min_fold_angle_v_overlap`. Core math
  runs in 64-bit scalars before `Vector2` conversion (Godot vectors are 32-bit).
- `linkage_solver.gd` (static): `solve(params, fold)` — module chaining, zHeight from
  radial span, cylinder→arch transform, `arrayCount` tunnel dup, simplified brackets/
  bolts (visual only). Returns beams (8 corners each) + brackets + bolts + stats.
- `linkage_geometry.gd` (static): canopy area, module frames, radial support (S) beams +
  simplified static RCP beams, and panel layouts (rectangular/radial/spiral for
  cylinder, arch wall-face for arch). `solar_panels()` returns panel dicts (center +
  axes + watts); `total_watts()`.
- `linkage_structure_builder.gd` (`LinkageStructureBuilder extends Node3D`, MODEL_ID
  `"linkage_structure"`): renders the solved frame as MultiMeshInstance3D beams/
  brackets/bolts/supports/panels (cheap per-frame `set_fold_angle` transform rewrites,
  no mesh rebuild). `build_node(spec, name)` is the ModelCatalog factory;
  `refresh_collision_mesh()` builds a hidden "CollisionMesh" MeshInstance3D (box
  geometry from beam/support/panel corners) that PlacedProp consumes for collision +
  pick AABB. `deployed_panel_summary()` = count/watts/per-panel-watts/avg-normal +
  electrical specs at the closed angle (the Phase 6 handoff numbers);
  `orientation_from_normal(n_world)` → tilt + compass azimuth (CelestialClock
  convention: north −Z, east +X, clockwise).
- `linkage_selftest.gd`: offline deterministic (349 checks) — in CLAUDE.md validation
  list; run `--import` first so class_names register.

**World placement + live folding.** ModelCatalog procedural entry delegates to
`build_node`; the modal's "Place in world" → `PlacedPropService.begin_placement`
(ghost preview at the current fold). `gameplay/linkage_deploy_runtime.gd`
(`LinkageDeployRuntime`, attached by `PlacedPropRuntime._maybe_attach_linkage_deploy`,
node name "LinkageDeployRuntime") owns the in-world fold: **Interact toggles deploy/
stow** with a 3 s animated fold; fold state persists on the prop record
(`linkage_fold_deg`/`linkage_deployed`); collision mesh rebuilds only when motion
settles. Crosshair **click** opens `placed_prop_edit_ui`'s "Edit in Linkage Lab" →
`main.open_linkage_lab_for_prop(prop_id)` (bound modal; "Apply to structure" rebuilds
that prop in place).

**Solar/graph handoff (deploy-gated, idempotent per prop).** On placement and on
"Apply to structure", `PlacedPropService.seed_linkage_graph(main, prop_id)` reads the
builder's `deployed_panel_summary`, rotates the avg panel normal into world space for
real tilt/azimuth, and calls `SystemGraphView.add_imported_solar_panels(count,
watts_per_panel, "Linkage Structure", tag, opts)` where `tag = "linkage_<prop_id>"`
(re-adding replaces only that structure's array). When the structure folds, the deploy
runtime calls `SystemGraphView.set_imported_array_stowed(tag, not deployed)` — a stowed
array keeps its node/wiring but contributes NO capacity to SolarUI
(`_collect_root_array_aggregate` skips `array_stowed` compounds, summary prefixed
"STOWED •"). Deleting the prop (`terrain_loader.delete_prop_by_id`) calls
`remove_linkage_graph` → `SystemGraphView.remove_imported_solar_array(tag)`.
`.gamebundle.json` import still works unchanged (static GLB); additionally, when a
bundle carries the v30 `project` block (`DesignBundle.project_from_bundle`), TimelineUI
offers "Open in Linkage Lab" so the web design becomes live-foldable natively.
**Deferred:** full BOM/costs/actuator analysis, hardware full-detail assemblies, build
guide, kinematic RCP continuation solver.

## Conventions

- Signals are wired in code in `_ready()` (zero editor connections).
- UI styling goes through `scenes/ui/ui_theme.gd` (`UITheme`): palette,
  status colors (`C_OK/C_WARN/C_ERROR/C_INFO` — one red, not four), StyleBox
  factories (`panel_style`/`card_style`/`button_style`/`chip_style`), font +
  spacing scales, and `LAYER_*` CanvasLayer bands. Migrating files keep their
  local const names but redirect values (`const C_BG := UITheme.C_BG`).
  Semantic registries (graph PORT_COLORS etc.) stay local. Multi-phase UX/veg
  improvement plan: `UX_IMPROVEMENT_PLAN.md`.
- Physics: cite formula sources in comments; never invent constants; every
  physics change adds checks to source_physics_selftest.gd.
- Node-name lookups are load-bearing (e.g. "SystemGraphView", "SolarUI",
  "Main") — renaming scene nodes breaks SimMode/AutomationEngine/UIs.
- Commit style: imperative subject, body explains what+why, validated-by note.

## gstack

Use the `/browse` skill from gstack for all web browsing. Never use the
`mcp__claude-in-chrome__*` tools directly.

Available gstack skills: `/office-hours`, `/plan-ceo-review`, `/plan-eng-review`,
`/plan-design-review`, `/design-consultation`, `/design-shotgun`, `/design-html`,
`/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`,
`/connect-chrome`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`,
`/setup-deploy`, `/setup-gbrain`, `/retro`, `/investigate`, `/document-release`,
`/document-generate`, `/codex`, `/cso`, `/autoplan`, `/plan-devex-review`,
`/devex-review`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`,
`/learn`.

## Known pre-existing runtime errors (not regressions)

Missing `ToolManager` under Player; missing
`res://vegetation/baked/camp_scatter_bake.tres`; duplicate device id
`ibc_glow_lights` (two Starshade IBCGlow instances); HAConnectionUI/UISP
button node-path misses; 4× `!is_inside_tree()` from fire-extinguisher spawn;
"target vector can't be zero" from road/camp scatter.
