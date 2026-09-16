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
# Resource-flow engine self-test (offline — spec-driven hydro incl. the
# stream-source path, penstock-conn authority, habitat/processor/tank flows;
# extend it with every flow-engine change):
Godot.exe.exe --headless --path . --script power_system/sources/resource_flow_selftest.gd
# Services node-registry self-test (offline — register/get/has, auto-clear on
# tree exit, freed-node guard; see ARCHITECTURE.md debt #1):
Godot.exe.exe --headless --path . --script core/services_selftest.gd
# Render presets self-test (offline — the graphics/shadow quality tables pulled
# out of main.gd into core/env/render_profile.gd; pins every value AND that the
# presets are ordered as advertised. Worth having because project.godot carries
# only the HIGH baseline and main.gd overrides atlas size, soft-shadow quality
# and TAA at runtime, so project.godot alone does NOT tell you what the game
# renders with. Phase 4 added QUALITY_ULTRA (3, appended — indices persist) and
# veg_profile(quality): the veg tier baseline — SoI ring radii, leaf shells,
# instance caps, cull distances, large-map scatter density, veg shadows —
# applied by terrain_loader._veg_style_with_quality (player-tuned keys, i.e.
# values differing from VegetationStyleConfig.defaults(), always win; the
# generator sees the SAME dict via _auto_veg_ctx so scatter and render agree;
# veg_quality_managed supersedes prepare_context's legacy large-map rewrite).
# HIGH is pinned == pre-Phase-4 defaults, HIGH-large == the old hardcoded
# thinning. One-shot <45 fps auto-drop after load persists veg_auto_dropped
# in perf_prefs.cfg [render]):
Godot.exe.exe --headless --path . --script core/env/render_profile_selftest.gd
# Camera-claim stack self-test (offline — the CAMERA counterpart of the clock
# stack, same API and same reason. ~11 subsystems each swapped the active
# camera by hand with a private saved-camera field, which cannot nest: a
# harness capture saves the player cam, the snowglobe then saves the CAPTURE
# cam and restores THAT, and when the capture frees its camera the viewport is
# left on a freed object. The selftest reproduces exactly that, released out
# of order. The service stores camera_id ints so it stays pure; main.gd owns
# push/pop/_apply_camera_claim and every side effect (hide_player_mesh,
# shadow_max_distance, prop_cull_scale_m) plus restore-on-empty. NOT claimants,
# permanently: the six SubViewport modal previews and graph_soi_preview_service
# never touch the main viewport's camera):
Godot.exe.exe --headless --path . --script core/camera_claims_selftest.gd
# Window Wall data layer self-test (offline — core/windowwall/): the multi-
# monitor viewport's layout + off-axis frustum maths, prefs and per-map
# viewpoint. The load-bearing check INVERTS the projection Godot itself builds
# (Projection.create_frustum_aspect with flip_fov = KEEP_WIDTH) and asserts the
# four corner rays land on the physical monitor's corners, plus a NEGATIVE pin
# that the flip_fov=false form does NOT — that pair is what freezes "size is
# the near-plane WIDTH", the whole bezel-continuity property. Also the far-
# point-through-any-panel = one wall point identity, screen auto-assignment,
# prefs round-trip against a TEMP path, and the viewpoint JSON. Carries
# EXPECTED_CHECKS (a runtime error aborts a test function while PASS prints):
Godot.exe.exe --headless --path . --script core/windowwall/window_wall_selftest.gd
# Shared crosshair-ladder self-test (offline — SiteTargetPicker, the ONE
# ray→target resolver used by BOTH the first-person crosshair and the
# settlement view's mouse, so the two provably agree. Pins the ladder order,
# the `want` filter, and — the invisible one — the MINIMUM ANGULAR PICK RADIUS:
# at 500 m a person is sub-pixel and an exact sphere test is unclickable, so
# the radius grows as t·tan(0.6°) past a ~52 m crossover. Also pins its own
# check COUNT, because a Godot runtime error aborts the enclosing test function
# while the suite still prints PASS — this file lost a whole function to that):
Godot.exe.exe --headless --path . --script gameplay/site_target_picker_selftest.gd
# Clock-claim stack self-test (offline — the ordered claim stack that replaced
# nine private `_saved_time_scale` fields; covers re-claim-does-not-stack,
# order-independent release, exclusive refusal, partial-claim fall-through, and
# a direct reproduction of the snowglobe-over-CSV-playback bug where the clock
# ended up stuck paused. Extend it with every new clock owner):
Godot.exe.exe --headless --path . --script core/clock_claims_selftest.gd
# InputMap self-test (offline — parses project.godot's [input] section, NOT
# InputMap.get_actions() which also carries Godot's built-in ui_* defaults):
# fails on a key bound to two actions (whitelist intentional pairs in
# ALLOWED_OVERLAPS with the file:line that disambiguates them), on an action
# with no events at all (a dead action orphans every handler keyed to it), and
# on a key event bound via `keycode` instead of `physical_keycode` (which drifts
# on AZERTY/Dvorak). Run it after ANY project.godot [input] edit:
Godot.exe.exe --headless --path . --script core/input_map_selftest.gd
# UI compile smoke + duck-typing contract guard (offline — sweeps scenes/ui/,
# crisis_events/ and location_picker/; these scripts mostly have NO class_name,
# so Godot never parses them at import and a GDScript error surfaces only when
# a player opens that panel). Also asserts the method surface other subsystems
# call BY STRING still exists — terrain_loader.gd calls `_exit_mode` at ~10
# sites with no has_method() guard, so a rename there is a hard runtime error.
# Catches parse/identifier/preload/autoload errors, NOT node-path misses or
# layout — those still need the windowed --capture harnesses:
Godot.exe.exe --headless --path . --script scenes/ui/ui_compile_selftest.gd
# Unified edit toolbar data layer (offline — scenes/ui/toolbar/): the tool
# registry, PER-TOOL parameter isolation (the whole reason the toolbar exists —
# the legacy T dock kept ONE global radius/strength/hardness, so tuning Smooth
# silently moved Raise), per-tool shape memory, option_specs row model,
# ConfigFile + real-file persistence round-trips (against a TEMP path, so a
# player's user://toolbar_prefs.cfg is never touched) including a corrupt /
# stale-build config, and the ShapeGestureController ladder (circle/rect/lasso/
# polygon, the Esc peel, the radius cap, lasso pixel-threshold sampling).
# Pins the one cross-file coupling that would fail SILENTLY: VEG_FAMILIES
# stores VegetationPaint.Preset values as LITERAL ints (so the model still
# loads with a stale global class cache), and this asserts they still match the
# enum — reorder it and every scatter paints the wrong family. Carries its own
# EXPECTED_CHECKS count, because a Godot runtime error aborts the enclosing
# test function while the suite still prints PASS:
Godot.exe.exe --headless --path . --script scenes/ui/toolbar/toolbar_selftest.gd

# Night-sky star field self-test (offline — core/astronomy/): StarSkyMath's
# GMST pinned to Meeus's worked examples 12.a/12.b, the equatorial BASIS form
# of RA/Dec -> world direction against the independent hour-angle/alt-az
# derivation (the sky shader used to read the texture latitude off the rotated
# WORLD vector — the zenith as the texture pole, only right at latitude 90°;
# this pin is what keeps the shader and the reference-star markers on one
# sky), a line-for-line GDScript MIRROR of the shader's star block against the
# pure UV mapping (edit sky.gdshader -> edit StarSkyMath.shader_uv_for_direction
# -> or this fails), the "one sky" timezone contract (the DirectionalLight sun
# and Meeus SPA at the clock's own UTC point at the same sun — they were ~4°
# apart at Bombay Beach while the sun used the rounded meridian and everything
# UTC-based used the exact longitude), and the shipped map + sidecar
# (assets/sky/starmap_equirect_8k.{png,json}: 2:1, pole rows black, fit
# residual <= 8 px). Carries EXPECTED_CHECKS; run --import first:
Godot.exe.exe --headless --path . --script core/astronomy/star_sky_selftest.gd
# Daylight model self-test (offline — core/env/daylight_model.gd, the ONE curve
# the DirectionalLight sun/moon, the ambient, the vegetation night signal, the
# glow AND sky.gdshader's daylight_fraction() all follow). Pins what a PNG
# cannot: the sunrise is CONTINUOUS — beam energy, beam colour, skylight and
# the vegetation signal sampled at 0.05° across the horizon with the largest
# single step asserted small (the "lightbulb" regression IS a step); the beam
# is ZERO below the horizon (the old ramp put 26 % of noon, in white, on the
# ground with the sun 5.7° down); the one-atmosphere contract (beam
# transmittance == SolarIrradiance's clear-sky DNI ratio, so what the player
# sees and what the panels make cannot disagree); measured-CCT colour anchors
# (≈2100 K on the horizon, ≈3700 K at 5°, white by 30°); and the twilight
# decades (-6° = 22 %, -12° = 5 %, dark by -21°). Carries EXPECTED_CHECKS:
Godot.exe.exe --headless --path . --script core/env/daylight_model_selftest.gd
# Star-map regeneration (NOT a selftest — the asset pipeline): run
# tools/stellarium_starmap_export.ssc in Stellarium >= 1.2 (config.ini custom
# screenshot size 8192x4096; the header is the checklist), then
#   python tools/starmap_prepare.py <screenshot.png> --note "Stellarium <ver>"
# which black-floors the export, MEASURES the registration from the bright
# stars (RA at the left edge, RA direction, north-up — never assumed), and
# refuses to write the sidecar if the stars are not where the catalog says.
# Star-field capture (WINDOWED): parks the clock at a fixed night, shoots each
# reference star with the computed markers ON and OFF, and DUMPS per star the
# projected marker position vs the brightest texture blob nearby plus the 2 h
# rotation about the pole (Polaris still, Dubhe moved ~117 px, +30° CCW) — the
# numbers a PNG cannot prove; then the same at a southern site about the SCP:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=stars --shots-dir=<label> --quit-after-capture
# Dawn lighting capture (WINDOWED): parks the clock at a ladder of solar
# altitudes (-14° … +20°, equinox, found by bisection on the clock's own sun
# direction), shoots toward the sun's bearing and away from it at each, and
# DUMPS per step what the lighting actually did on the live nodes — beam
# energy + colour, ambient, night amount — because a single PNG cannot show a
# RATE. Asserts end to end: no beam with the sun below the horizon, energy and
# ambient monotonic through the ladder, a few percent on the horizon (not a
# lightbulb), deep orange there and white by 20°. NOTE the ambient column is
# the PLAYER'S ramp (ambient_energy_mult 0 reads 0 at every step); the header
# prints their prefs. Clock and clouds restored, nothing persisted:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=dawn --shots-dir=<label> --quit-after-capture

# Boot both maps, 120 frames each; compare errors against the known
# pre-existing set (see Known Issues). NOTE the default main scene is the map
# CHOOSER, so the bare form below boots almost nothing — pass a map explicitly
# to actually exercise one:
Godot.exe.exe --headless --path . --quit-after 120
Godot.exe.exe --headless --path . --quit-after 120 res://scenes/maps/soak_festival_2026.tscn
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
# Video export (in-game): Ctrl-drag a range on the timeline → 🎬 → save path. Steps
# the world one frame at a time (paused clock, `speed / 30` sim-hours per frame) and
# encodes 30 fps MP4 — requires ffmpeg in PATH. The export owns the clock: it forces
# time_scale 0 + analemma_mode off and restores both on every exit path.
# Vegetation growth seasonal gate + instance map (offline):
Godot.exe.exe --headless --path . --script vegetation/vegetation_growth_selftest.gd
# Veg style store (offline — Phase 2 layered persistence: precedence matrix
# species>family>SPECS>defaults, v1→v2 migrations incl. the defaults-dump
# purge, subspecies mesh divergence, VegetationLayer sparse-delta round-trip;
# run --import first so VegStyleStore registers):
Godot.exe.exe --headless --path . --script vegetation/veg_style_store_selftest.gd
# Veg species registry (offline — Phase 5: vegetation/species/species_catalog.json
# schema + facade parity, palm/cactus builder meshes, phenology profiles
# (tropical evergreens KEEP leaves — palms used to carry deciduousness 1.0 and
# dropped fronds every winter), climate-envelope lat gates + generator weight
# filtering, food yields/harvest windows (Phase 10 feed), photocard drop-in
# hook (assets/vegetation/photocards/<id>.png or user://veg_photocards/):
Godot.exe.exe --headless --path . --script vegetation/veg_species_registry_selftest.gd
# Veg phenology (offline — Phase 6: latitude damping of the seasonal signals
# (no autumn/leaf-drop/dormancy below ~15° abs lat, full by ~35°, hemisphere
# flip still at full strength), SeasonModel.estimate_winter_min_c incl. the
# southern-hemisphere half-year window, the species cold-hardiness gate
# (min_winter_c + tolerance; NAN = latitude only, so offline keeps its forest),
# VegLeafFall's drop window vs spring leaf-out, and the VegLitterMask
# sizing/conifer-exclusion/seasonal-strength rules):
Godot.exe.exe --headless --path . --script vegetation/veg_phenology_selftest.gd
# Food forest yield (offline — Phase 10: VegFoodYield's per-polygon summary
# over the layer records + species registry, the maturity ramp (nothing below
# half size), harvest windows INCLUDING the ones that wrap the new year, and
# the property the flow engine leans on — integrating the harvest rate over the
# window returns exactly the annual yield):
Godot.exe.exe --headless --path . --script vegetation/veg_food_selftest.gd
# Veg paint dock state (offline — Phase 8: the chip row's pure data model, the
# tool/shape/species state machine over a REAL instantiated dock, and the
# per-tree Select primitives on VegetationLayer. Two traps this file exists to
# close: the dock references CursorController at parse time, so it must be
# load()ed inside _initialize (a const preload silently fails and every
# dock.call() no-ops while the suite still says PASS); and the suite runs on the
# first PROCESS frame because the SceneTree root is not inside the tree during
# _initialize, so an added child never gets _ready() and no Controls exist):
Godot.exe.exe --headless --path . --script vegetation/veg_dock_state_selftest.gd
# Veg LOD policy (offline — Overhaul v2: budget-aware tree detail distance
# replacing the old SoI rings + large-map force_far flattening; sparse maps
# keep the requested range, dense maps shrink until the worst-case near-set
# fits the tier budget, 60 m floor, grass/shrub never counted; --import first):
Godot.exe.exe --headless --path . --script vegetation/veg_lod_policy_selftest.gd
# Extreme weather (offline — core/weather/): hazard catalog + VTEC mapping, the
# HazardState algebra (blank() is the IDENTITY element, combine() commutative,
# worst-wins optics / multiplying energy), Koschmieder + IMPROVE visibility
# maths, the per-hazard severity curves (incl. a CLIFF guard comparing each
# step's ratio against the median — a previous dust curve did nothing until 0.8
# severity then collapsed 2.4 km -> 90 m), the smoke-vs-dust fine-mode
# disambiguation (both events push PM2.5/PM10/AOD the same way; PM2.5/PM10 is
# what tells them apart), the AirQualityService parser incl. a NEW YEAR window
# crossing, the risk profile from canned VTEC history + the climatology
# fallback, and AtmosphereApplier's identity guarantee — resolve(base, blank())
# returns base FIELD FOR FIELD, which is what makes "feature off => not one
# pixel changes" true. Run --import first:
Godot.exe.exe --headless --path . --script core/weather/extreme_weather_selftest.gd
# Extreme weather capture (WINDOWED): shoots the settings tab through its real
# entry point, then a clear baseline and a severity ramp per simulated hazard
# from one fixed viewpoint with distant terrain in frame, plus a night shot
# (where a daylight-ungated sky tint shows up as a brown, starless sky). DUMPS
# every resolved number to console — visibility, fog density, sun tint, AOD,
# AQI, DNI/GHI — because a PNG cannot tell you whether the fog is 900 m or
# 9 km, and that difference is the whole feature. Snapshots and byte-restores
# user://extreme_weather.cfg. NOTE the scene renders non-deterministically
# (TAA), so two identical runs produce different PNGs — pixel-diffing cannot
# prove the no-op property; the selftest identity assertion is what does:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=weather --shots-dir=<label> --quit-after-capture
# Site Report metrics/data + UI-compile self-test (offline, deterministic):
Godot.exe.exe --headless --path . --script core/report/site_report_selftest.gd
# NPC population self-test (offline, deterministic — SpaceRegistry tagging/
# queries/occupancy/persistence; agent needs/FSM/nav: identical-run
# determinism, priority ladder, sleep schedule, starvation block, mass-exact
# time-averaged demand, teleport threshold, scrub-freeze, snapshot round-trip;
# Tier 2: morale bands/superlinear+blocked pressure/ceiling, supplied-vs-
# starved runs, brief-outage recovery, enrichment ceiling lift + social
# clustering, departure/contagion/collapse cascade + resilience buffer,
# weather multiplicative gating, chore board windows/claims/credit/serialize,
# chore-vs-need preemption and productivity scaling, and the v2 crew board
# (stacking claims to max_workers, quorum-gated credit incl. the v1
# credit-without-claim back-compat for single-worker chores, dependency
# holds + deleted-dep unblock, roster filter, add_plan wiring a whole
# NpcCrewPlan schedule with a shared build-site target, site rules
# night_shift/tools_down incl. persistence, haul-route storage +
# worker_index claim order = brigade station assignment; NOTE the suite must
# never reference NpcPopulationBridge — bare PerfMonitor autoload fails the
# --script compile and silently aborts the test function while PASS prints);
# SITE PROJECTS (the unified camp-lifecycle mechanic): completion-keeps-
# progress semantics (remaining()==0 for a done cycle — the re-work-loop
# fix; daily chores re-arm via _arm_cycle when next due), atomic add_plan
# refusal at MAX_CHORES(160), per-task target/effect/carry_to/haul fields,
# held pause flag, uncapped priority ordering, the chore_completed
# toast-only signal, the two-leg carry FSM (chore_leg pickup→carry_to,
# preemption leaves the crate unmoved — the move is the COMPLETION effect,
# dispatched once by the bridge's post-tick sweep with effect_done as the
# persisted fire-once flag), the carrying/carry_prop dot payload, and
# SiteProject/SiteProjectStore (status sync incl. deleted-chore=skipped,
# labour-weighted rollup, build_progress fractions for the ghost reveal,
# breakdown_spec_rows, store cap/round-trip); round 2: stage_effects
# (incremental world effects fired as progress crosses thresholds —
# due_stage_effects, fire-once per stage, completion brings stragglers due,
# persistence with fired flags), unload_spec_rows strategy split (round-trip
# carry rows vs ONE brigade crew chore whose stage effects move the crates
# while the relay line works; brigade station workers read as carrying in
# the dot payload), and the muster fixes (gathering crew chores jump the
# available_for queue; quorum patience scales with crew fraction present);
# round 3: SiteProject.breakdown_progress (the REVERSE lifecycle's visuals —
# emits ALL five element keys because _apply_build_progress defaults a
# MISSING key to 1.0, which is why the old panels-only push left the frame
# solid; beams deliberately stay 1.0 throughout since fold_pack's pack_prop
# awaits the stow sweep and the fold IS the beam visual; monotonic, and a
# design with no panels keeps its nonexistent panels whole), the LIFO unload
# row order (round-trip priorities ascend, gate above all; every set-down
# carries y_offset 0 + collision_enabled so a crate hauled off a container
# stack lands ON THE GROUND), NpcRig.role_needs_offset_curve (four lines
# pinning the carry-clip drop-in hazard: a lift MEASURES as descend and the
# offset curve would sink the figure ~0.7 m mid-pickup, so ROLE_CARRY is
# forced past classify() to take the constant path), and NpcExperimentLab
# (the sim-backed variant comparison — determinism, chunked==blocking,
# simulated never beats the planned lower bound, unmeetable quorum names
# every row at ZERO tick cost, hour-cap DNF, n/a haul rows on a non-delivery,
# signature stable under progress_h churn but tracking min_workers/roster,
# and force_strategy "" byte-identical to the unforced unload_spec_rows);
# Tier 3: nav-grid region/bake/slope-vs-steps/stamping/fingerprints, and A*
# mazes, step + drop asymmetry, staircase climbing, climb-cost detours,
# route cache/lane jitter/determinism, path following + teleport degradation;
# extend it with every population change):
Godot.exe.exe --headless --path . --script core/population/npc_population_selftest.gd
# Nested super-node self-test (offline — portal resolution, flattened connections,
# walk recursion, cascade delete, v6->v7 migration, exposed-port maintenance,
# nesting-aware PV faulting; run --import first so GraphNesting registers):
Godot.exe.exe --headless --path . --script system_graph/graph_nesting_selftest.gd
# Hydro node unification (offline — Phase B of the Hydro Lab overhaul): legacy
# type=="hydro" estimator items migrate on deserialize into processor role
# "siphon_hydro" (specs carried, DC wires remapped positive/negative →
# res_out_1_pos/neg, battery trace still counts the kW), idempotent over a
# serialize round-trip, existing siphon processors untouched. The spec-driven
# output path itself (no pond → estimator physics; run_of_river never drains)
# is pinned in resource_flow_selftest's _test_spec_driven_hydro:
Godot.exe.exe --headless --path . --script system_graph/hydro_migration_selftest.gd
# Graph COMPONENTS self-test (offline — SketchUp-style definitions: realize
# single + multi-level (StarShade tree), capture round-trip, edit-one-instance-
# updates-all with per-instance battery SOC preserved, external-wire survival on
# re-stamp, Make Unique detach, v6->v7 definitions round-trip; --import first):
Godot.exe.exe --headless --path . --script system_graph/graph_components_selftest.gd
# Graph electrical self-test (offline — string Voc, controller ranking, Voc across
# a super-node boundary; DC side: battery-bank bus topology (4S/2S2P/mismatch),
# short-circuit detection (direct + closed series loop, parallel banks clean),
# unregulated-PV battery overcharge, and the controller current-throttle
# wattages 120/360/720/1200 W pinned; extend with every electrical change):
Godot.exe.exe --headless --path . --script system_graph/graph_electrical_selftest.gd
# Wire routing + port presentation (offline geometry — bezier control points for
# same-edge ports (the U loop), facing ports, direction-fallback endpoints;
# ambient-port classification; DC solid-fill/glyph styling rules; the "+ is
# always on the left" terminal convention; complete-circuit flow gating):
Godot.exe.exe --headless --path . --script system_graph/graph_wire_routing_selftest.gd
# Tiered UI feedback sounds (offline — every tier well-formed/deterministic,
# the success chime rises, the womp-womp descends with a gap between notes,
# the per-wire click stays short + quiet, DANGER == the graph destroy boom):
Godot.exe.exe --headless --path . --script core/ui_sfx_selftest.gd
# Solar Bootcamp tutorial (offline — ProgressStore grandfathering/grants/levels,
# 12-level catalog integrity incl. every seed/unlock/palette entry resolving,
# TutorialGoals predicates: deliverable-watts/bus-V/string-config over synthetic
# graphs, AC-load wiring, compound-containing, run verdicts; extend with every
# tutorial change):
Godot.exe.exe --headless --path . --script gameplay/tutorial_selftest.gd
# Challenge pre-bake loop (offline — span step policy vs the 20160-sample
# timeline caps, prebake ChallengeDef round-trip + legacy default, catalog
# prebake entries, power-failure accumulator edges, two-run bake determinism):
Godot.exe.exe --headless --path . --script gameplay/challenge_bake_selftest.gd
# Challenge defs/catalog/runner rules (offline):
Godot.exe.exe --headless --path . --script gameplay/challenge_selftest.gd
# 3D conduits (offline — kinds/conceptual default, mesh/drape/lights, loss,
# bound-prop routability, connection ports, triangle pick, ortho elbows, the
# size-driven tube radius (a size-listed kind renders at its STYLED bore; the
# mesh builder reads radius_m off the kind meta, so without ConduitManager
# stamping it a 2" poly run drew exactly as thin as a 1" one and the size
# picker looked inert), and
# the poly_penstock kind + ContourRouter (Hydro Lab overhaul Phase C):
# SDR-9 ID-per-size table, PPI 25×OD bend radius, terrain-following route that
# bridges too-sharp gullies, dispatch contour branch determinism + no-ground
# chord fallback. The flow-engine side (routed conn is the authority for
# penstock length/Ø/outlet invert; contour conns exempt from the generic
# Hazen-Williams derate) is pinned in resource_flow_selftest's
# _test_penstock_conn_authority. Run --import first so class_names register:
Godot.exe.exe --headless --path . --script core/conduits/conduit_selftest.gd
# Culvert stage-discharge + Hydro Section calculator (offline — weir/orifice,
# Manning cap, stepped 3×8″ bank, PE vs HydroSource; --import first):
Godot.exe.exe --headless --path . --script core/conduits/culvert_hydraulics_selftest.gd
# Siphon micro-hydro prime/break + power cap (offline; --import first):
Godot.exe.exe --headless --path . --script core/conduits/siphon_hydraulics_selftest.gd
# Unified hydro reach: pond→siphon→culvert→outlet ONE stepper — parity vs
# SiphonHydraulics, prime/break cycle, mass conservation, effective air-break
# dead pool, overflow, penstock conveyance (design-flow vs gravity capacity),
# and the NOZZLE model (Hydro Lab overhaul Phase D): powerspout_pelton runs
# PeltonPhysics' operating point (penstock delivery meets nozzle demand,
# Cv 0.97, x_opt 0.46 — Thake; pinned to a hand-computed 20 m / 100 m /
# 1×10 mm case), jet-derived RPM (not the 5 kW siphon rotor curve), and the
# kind's 1.6 kW nameplate when the spec leaves max_power_w at 0. PeltonPhysics'
# own pins (jet velocity, nozzle head/flow round-trip, runner parabola, the
# powerspout estimator branch of power_kw_from_graph_specs incl. the pelton
# head-band floor moving 30→10 m) live in source_physics_selftest. Offline,
# deterministic; --import first. This reach is the single physics source for
# the flow engine + Hydro Lab (no fallback branch). Also pins the LEVELLESS
# STREAM mode (`penstock_source_mode: "stream"`): a spring/creek tapped by a
# penstock has no water surface to draw down, so the reach takes its head from
# the adopted invert drop and skips both the `is_nan(level)` bail and the
# submergence dead-pool — without it a stream-fed PowerSpout reported regime
# "unset" and every Lab readout sat at zero. Plus the supply cap, the
# oversized-nozzle head collapse, and `no_supply` (a DRY spring, distinct from
# `no_head` — the Lab must not tell you to move a correctly-sited turbine):
Godot.exe.exe --headless --path . --script core/conduits/hydro_reach_selftest.gd
# ABS DWV pipe kit (offline — kit JSON/meshes, planner 45/90 BOM; bake once with
# pipe_kit_extractor.gd if data/*.res missing; --import first):
Godot.exe.exe --headless --path . --script core/conduits/pipe_kit_selftest.gd
# Re-bake ABS fittings from Imported Models/PipeFittings/abs_dwv_elbows.glb:
Godot.exe.exe --headless --path . --script core/conduits/pipe_kit_extractor.gd
# LinkageLab designer self-test (offline — solver/kinematics pinned to JS
# reference values, support/panel geometry, structure builder, world-placement
# runtime, solar/graph handoff, modal compile smoke; PLUS the hardware/BOM port:
# v30 hardware-assembly round-trip, LinkageBom counts cross-checked against the
# SOLVER's own bolt/bracket arrays (the web app never did this), the packing
# mass fence, drill templates, the BOM→crew fabrication graph incl. a frozen
# back-compat literal, build-guide + hardware-modal compile smoke, hardware
# axis-stack layout/snap/mirror maths JS-PINNED via tools/linkage_hw_reference.mjs,
# part meshes (incl. an outward-normal
# WINDING assertion), the credits lockstep guard, and the hardware-spacing
# parity proof — `is_same(effective_params(p), p)` when full detail is off,
# which is what protects every pinned value here. Extend with every solver
# change; run --import first so new class_names register):
Godot.exe.exe --headless --path . --script core/linkage/linkage_selftest.gd
# Packing data model (offline — PACKING_PLAN.md Phase 0: PackedSpec
# resolution/normalization, per-type mass+dims heuristics, the shipped-model
# packing-decision coverage guard (a new structures/tools catalog model FAILS
# this until it appears in CURATED_MODELS / DYNAMIC_MODELS / NON_PACKABLE),
# and the LinkageLab packed envelope solved at the EFFECTIVE min fold angle;
# run --import first so PackedSpec registers):
Godot.exe.exe --headless --path . --script core/packing/packing_selftest.gd
# Process recipes + chore ledger + workflow runner (offline — normalize/catalog,
# legacy batch migration, scrub-safe progress, hybrid chore confirm, part credits,
# workflow step advance; run --import first so class_names register):
Godot.exe.exe --headless --path . --script core/machines/process_recipe_selftest.gd
# Portable .esim site package (offline — validate/build, ghost strip/remap,
# share-code + file round-trip, summary counts; run --import first):
Godot.exe.exe --headless --path . --script core/esim/esim_selftest.gd
# Multiplayer helpers (offline — join-code round-trip/expiry, bare ip:port,
# protocol reject, avatar color, transfer codec, chat sanitize/mute, Phase 6
# password/allowlist/rate-limit + headless host bind smoke, which now also pins
# that a hosted code carries a candidate address list AND still mirrors the LAN
# address into the top-level ip/port every pre-v3 consumer reads; --import first):
Godot.exe.exe --headless --path . --script core/multiplayer/multiplayer_selftest.gd
# Discord integration (offline — every security-relevant decision in core/discord/
# is a PURE class_name file precisely so it can be fed fixtures here instead of
# only against a live Discord app). Covers: PKCE pinned to the RFC 7636 Appendix B
# vector (catches every base64url/padding slip at once — a slip otherwise surfaces
# only as an opaque `invalid_grant` from Discord's token endpoint); the community
# file codec INCLUDING the SSRF guard that a webhook URL must be on discord.com;
# the session-directory record's parse/staleness/seq and its ELECTION arbitration
# (two simultaneous claims, exactly one winner, loser flips to joining); the gate
# verdicts over canned /oauth2/@me + guild-member bodies (notably that a token
# minted by any OTHER Discord application is rejected); deep-link injection
# rejection; reachability classification incl. the 100.64/10 CGNAT block and a
# sweep of every UPNP_RESULT_* constant; relay batching (every payload must carry
# allowed_mentions.parse == [] or an in-game "@everyone" pings the whole server);
# telemetry redaction; the admission hold-vs-kick states; join-code v3 plus a
# FROZEN v2 literal so codes already pasted into Discord keep decoding; the
# DiscordIdentity offline contract + loopback-port binding; the community STORE
# (snapshots and byte-restores the player's user://communities + active pointer,
# same write-discipline as the veg harnesses); and an END-TO-END election driven
# through a FakeDiscordHttp stand-in — empty directory wins, live host stands
# down, stale host frees the seat. That last one is awaited and deliberately
# waits out the real confirm delay, because the delay IS the mechanism:
Godot.exe.exe --headless --path . --script core/discord/discord_selftest.gd
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

# Packing Lab capture (WINDOWED — PACKING_PLAN.md Phase 4): sweeps the site
# cargo (graph + placed props, same sweep as the Site Report card) into the
# interactive Packing Lab modal, auto-packs it into the 15' and 26' trucks,
# orbits, then loads the builtin StarShade kit into a 20' container — one PNG
# per state for visual review. Read-only, nothing persisted:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=packing --shots-dir=<label> --quit-after-capture
# Hardware Detail capture (WINDOWED): opens the hardware editor through Main's
# real entry point (so it lands on its own CanvasLayer above the HUD) and shoots
# one PNG per state — each assembly seated on the frame, exploded, standalone,
# selected-with-axis-gizmo, and arch mode — then DUMPS to console how many
# joints each assembly got, how many flipped their stack axis, and the worst
# "anchor error": the distance from each seat's bracket hole to the V-stack
# pivot it clamps. That number must be 0.000000; anything else means the
# placement is back on the wrong pivot. Joint placement is unreviewable from a
# description — the port shipped anchored on the H-ring pivot, with no
# flipStackAxis and a 90°-yawed H-centre frame, and all three RENDERED:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=hardware --shots-dir=<label> --quit-after-capture
# Regenerate the hardware LAYOUT + PLACEMENT reference values from the real web
# app (writes core/linkage/testdata/hw_placement_ref.json in place; run from the
# repo root). Part 2 solves with showHardwareFullDetail=false + hwDetailMode=true
# — the only combination that emits placements while leaving the beams identical
# to linkage_reference.mjs's cyl_default, which the printed cornerSum proves:
node tools/linkage_hw_reference.mjs ../LinkageLab
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
# Hydro Lab capture (WINDOWED): builds a pond + siphon on the graph, binds them,
# opens the Lab's own 2D cross-section (VIEW_SIPHON, item-bound — the mode chip
# is gone), and shoots primed/flowing → time-accelerated drain/broken →
# test-inflow refill/reprime (drives the pond on the world clock via the unified
# HydroReach) for visual review of the flow render. The read-only variant also
# flips the turbine to powerspout_pelton for one shot (04) — nozzle knobs +
# Penstock-route section + the power-curve chart (P vs head per poly size, live
# operating-point marker) with the dock scrolled to frame them — and DUMPS the
# per-size watts line to console (the number a PNG can't prove), then restores
# the saved kind:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=siphon --shots-dir=<label> --quit-after-capture
# Site-review (WINDOWED): load a REAL user map as-is (autosaved graph + terrain
# artifacts), shoot world/ + graph/ (freeform + elevation) + siphon/ Lab, write
# diagnostics.json + perf/*.json. Alias --user-map=mtvernon resolves Mount Vernon
# under user://maps/. --perf enables F3 HUD; --no-mutate skips Demo Lab drive:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=loc_48p3252_n122p2469.tres --capture=site-review --perf --shots-dir=mt_vernon_review --quit-after-capture
# Vegetation regression capture (WINDOWED — veg overhaul Phase 1 baseline): waits
# for the auto-veg scatter, then shoots forest-anchored sets (veg_00 close canopy,
# veg_01 the NEAR→FAR LOD boundary, veg_02 distant, veg_03 aerial) + orbit + a
# 4-date seasonal series (winter/spring/summer/autumn from one fixed waypoint),
# and writes veg_diagnostics.json (per-batch instances/visibility/fade-mode/
# surfaces, VegAssetCache stats, primitives/draw-call counters, key style knobs).
# Run before/after ANY veg rendering change and diff the JSON + boundary shots:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=veg --shots-dir=<label> --quit-after-capture
# Per-area fill end-to-end (WINDOWED — veg overhaul Phase 7): on a REAL saved
# map, picks the largest OSM vegetation area, drives the loader's own
# apply_area_fill / area_fill_params / clear_area_fill, and asserts the fill
# placed instances, planted the CHOSEN species, persisted to the map's
# auto_veg_edits file, and cleared again; shoots before/after/cleared PNG pairs
# of the outline. It SNAPSHOTS and RESTORES auto_veg_edits_<lat>_<lon>.json, so
# a regression run never mutates the player's site (verify after: the file is
# back at its original version/cleared/patch counts with 0 fills):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=areafill --shots-dir=<label> --quit-after-capture
# Tree portraits (WINDOWED, console + PNGs): stands ONE tree of each species in
# empty air against sky and shoots it at NEAR and FAR, with per-shot surface/
# tri/AABB/foot numbers. Shape work is unreviewable from forest shots — a
# silhouette defect just reads as "the forest looks off". It builds meshes
# straight from VegetationCardFactory and never touches the map's veg layers,
# but it DOES read the map's live style, so run it on a real site (mtvernon),
# not the soak map, or you are reviewing library defaults nobody renders:
Godot.exe.exe --path . --windowed --resolution 900x900 -- --user-map=mtvernon --capture=tree --shots-dir=<label> --quit-after-capture
# Veg paint dock + Tune-look visual check (WINDOWED — veg overhaul Phase 8):
# opens the V dock through its real entry point and shoots the chip row in four
# tool states, then opens Tune look…, calls Apply, and asserts the modal STAYS
# OPEN (Phase 8 made applying iterative instead of close-on-apply). Read-only —
# it never paints or persists:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=vegdock --shots-dir=<label> --quit-after-capture
# Food-forest harvest guard (WINDOWED, console-only — veg overhaul Phase 10):
# seeds a food-forest bed + biomass store on the graph, keeps the graph screen
# CLOSED, and asserts the harvest is credited on the ambient tick INSIDE the
# window and nothing is credited outside it. Keep the test time_scale low (20
# h/s): at 400 h/s a 4 s run advances 66 sim-days and leaves the 61-day harvest
# window before the assertion reads it. Removes its seeded nodes afterward:
Godot.exe.exe --path . --windowed --resolution 640x480 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=foodforest --quit-after-capture
# Ambient resource-flow regression guard (WINDOWED — the harness hard no-ops
# under --headless; no screenshots, console-only): builds a primed pond+siphon+
# culvert-outlet, keeps SystemGraphView.visible=false the ENTIRE time (graph
# never opened), speeds up the world clock, and asserts the pond drained + the
# outlet accumulated volume. Guards against the water/siphon/catchment
# simulation regressing back to only running while the 2D graph screen is open
# (system_graph_view._tick_resource_flow_ambient):
Godot.exe.exe --path . --windowed --resolution 640x480 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=ambient --quit-after-capture
# NPC population end-to-end verify + Site Plan/3D capture (WINDOWED): seeds 4
# tagged area spaces + a pop-driven habitat with supply/waste tanks on the soak
# graph, runs the clock with the graph CLOSED and asserts ambient consumption
# (tanks moved) + agent movement, shoots Site Plan dot PNGs (incl. a zoomed
# close-up), shoots the 3D silhouette avatars + crosshair/space-marker
# contracts WHILE THE ROSTER IS ALIVE (phases are ordered this way on purpose
# — the cascade below empties the camp), then empties the food tank and
# asserts the starvation loop closes (STARVED flash seen, hunger climbing),
# and finally cuts the water and asserts the whole Tier-2 cascade: morale
# falls, people rage-quit, the roster shrinks, the colony collapses. Do NOT
# add a >6 h time jump to the starvation phase — that takes the coarse
# catch-up path and empties the camp before anything can be observed.
# It also seeds a plain 0.5 h scheduled chore and asserts it reached
# `done_day >= 0` during the ambient day: movement and consumption were always
# checked, but WORK REACHING COMPLETION was the gap the hygiene stall lived in
# (see the settlement plan) — the same hole the selftest had one level down.
# Note avatars are counted by TYPE, not by the host's child count: the host
# also parents the pooled CrewSiteMarker nodes, so a child count reads high
# whenever crew work is on the board.
# Cleans its cap_pop_* graph items off the map autosave:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=population --shots-dir=<label> --quit-after-capture
# Settlement view capture (WINDOWED — the mode's whole risk surface is
# invisible to every other harness): opens the view through Main's REAL entry
# point and shoots five zoom stops (eye 1.7 / street 12 / block 60 / camp 300 /
# site 1200 m), dumping height, pitch, near/far, scale label and prop-cull
# reach per stop. At each stop it drives SiteTargetPicker at a known agent's
# screen position — that is the ANGULAR pick radius (`t·tan(0.6°)`) end to end,
# the one line that makes a person clickable at every zoom and which is
# invisible to both code review and screenshots. Beyond ~52 m the radius
# exceeds a body, so picking a NEIGHBOUR is correct and only the sub-4 m stops
# demand exact identity. Ends with the anti-snowglobe assertions: the player
# camera is current again, `time_scale` NEVER moved, and the cull override is
# cleared. The harness parks the clock at --time BEFORE opening (the view must
# not touch it; the harness may, or a run after sunset ships five dark PNGs):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=settlement --shots-dir=<label> --quit-after-capture
# Window Wall capture (WINDOWED): opens the multi-monitor view through Main's
# REAL entry point with prefs forced IN MEMORY (the player's window_wall.cfg is
# never written) and proves what a PNG cannot: every slot camera shares ONE
# origin and ONE basis and differs only by its frustum (size/offset/near/corner
# hits DUMPED per slot), the extra native windows exist fullscreen with
# KEEP_WIDTH frustum cameras, U twice restores every CanvasLayer EXACTLY, a
# nudge moves all cameras together, a key pushed into an EXTRA window reaches
# the view (the relay node — `window_input` never fires for push_input), the
# "live" clock mode claims 1x + syncs the date and hands both back, and
# close() restores the ROOT WINDOW, the embed flag, the player camera, the UI
# map and the player's process mode. One PNG per window per state. On a
# single-screen machine every slot lands on screen 0 as overlapping fullscreen
# windows, which still proves creation, restoration and the maths:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --scene=res://scenes/maps/soak_festival_2026.tscn --capture=windowwall --shots-dir=<label> --quit-after-capture
# NPC pose portraits (WINDOWED): stands ONE stick figure per work-pose family
# in empty air against sky and shoots it NEAR (2.5 m) and FAR (13 m), printing
# the family asked for beside the clip the pose machine actually chose — which
# is what separates "this pose looks wrong" from "the machine picked the wrong
# clip", two different bugs in two different files. `--capture=npc-anim` cannot
# do this job: it observes only is_rigged() avatars, and the rigged Mixamo body
# aliases all seven families onto its single `work` clip, so the families only
# exist on the stick figure. Traps it handles: it FORCES NpcDisplayPrefs to
# STYLE_SIMPLE and restores it (a global persisted player preference); the
# avatar must be add_child'ed because _simple.pose runs only from _process;
# `paused` must be false even though the harness freezes time_scale; the
# transitions are ONE-SHOTS so they are pinned via the anim_map slot override
# rather than waited for; `carrying` OVERRIDES the family so it is set for
# haul_hold only; and the camera sits BELOW the waist looking up so the horizon
# never crosses the silhouette:
Godot.exe.exe --path . --windowed --resolution 900x900 -- --user-map=mtvernon --capture=npcpose --shots-dir=<label> --quit-after-capture
# Labour merge verify (WINDOWED, console-only, needs a REAL TerrainLoader map):
# parks a processor on a `chore_hours` step with the ledger at infinite_labor
# false and ZERO abstract pool, then asserts the whole merge: the step asks for
# CREW (not a confirm), a chore is minted AT the machine's bound prop (so
# people walk to it), somebody finishes it and the step resumes, and — the
# contract no screenshot can show — `chore_hours_consumed_total` moves by
# EXACTLY the step's hours. A second accounting path shows up here as a
# doubling and nowhere else. Cleans its cap_lab_* items and prop afterward:
Godot.exe.exe --path . --windowed --resolution 640x480 -- --user-map=mtvernon --capture=labour --quit-after-capture
# Site Projects end-to-end verify (WINDOWED, needs a REAL TerrainLoader map —
# the delivery path is loader-only): seeds a 12-person pop-driven habitat +
# tanks + spaces, delivers the StarShade kit, and walks the WHOLE unified
# camp-lifecycle mechanic with console asserts + a PNG per stage: crates
# spawn AT the container door carrying delivery identity + staging slots and
# an unload project lands on the board; a CARRYING dot is observed and the
# crate record moves to staging via the chore's COMPLETION effect (the world
# only changes when labour is done — a preempted carry moves nothing); a
# linkage build project grows the ghost structure's beam
# visible_instance_count with real labour; the erect phase's unpack effect
# plays the deploy sweep (packed:false, linkage_deployed, build_state
# cleared); the reverse breakdown project folds it back to packed:true.
# Round 2 added a SECOND delivery (starter_camp, 7 crates) whose strategy
# NpcHaulModel picks from crew density — brigade = one crew chore with the
# crates flowing as stage effects — asserting every crate reaches its
# staging slot either way. NOTE the carrying flag is sampled at a CRAWL
# (~7×, per-frame polls) before the clock speeds up: at 720× a carry leg is
# sub-frame and a 0.5 s poll never catches it.
# Round 3 asserts: crates spawn STOWED INSIDE the container (inside the
# interior footprint, at the solved stack height) and a hauled crate is set
# down with y_offset ~0 and no `stowed_in` — the XZ checks pass either way,
# so a crate left floating at stack height would otherwise ship invisible
# (and a stale `stowed_in` silently BLOCKS the erect phase's unpack, which
# is how that bug was caught); the teardown strips hardware while the beams
# stand (05a_stripping); and the experiment lab runs, dumping the whole
# variant table (sim / plan / drag / status per row) to console, because a
# PNG cannot tell you whether a makespan is 6 h or 60 h.
# Runs the board on night_shift and steps the clock by time_scale (never a
# >6 h jump — the catch-up path would reroll the roster). Cleans its
# cap_prj_* graph items off the map autosave:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=project --shots-dir=<label> --quit-after-capture
# Settlement view (WINDOWED): opens the mode through Main's REAL entry point,
# seeds a small crew (so the picking assertions have somebody to click), and
# shoots five zoom stops — eye 1.7 / street 12 / block 60 / camp 300 / site
# 1200 m — dumping what a PNG cannot show: height, pitch, near/far, the scale
# label and the prop-cull override. At each stop it projects a known agent to
# screen and resolves the ray BACK through SiteTargetPicker, which is the
# angular-pick-radius property end to end; past ~500 m the radius exceeds the
# spacing between people, so "picked a neighbour" is correct and only "picked
# nobody" fails. Ends on the ANTI-SNOWGLOBE assertions: the player camera is
# current again, the prop-cull override is back to 0, and `time_scale` NEVER
# MOVED — soi_snowglobe_camera freezes the clock, and this view must not:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=settlement --shots-dir=<label> --quit-after-capture
# NPC animation observation on a REAL saved map (WINDOWED, READ-ONLY): unlike
# --capture=population (which SEEDS its own spaces/tanks/habitat and would
# overwrite a curated site), this finds whatever pop-driven habitat is already
# saved, stands the camera in the middle of the roster (the rigged body is
# handed out by distance from the VIEWER — observing from spawn means nobody is
# ever rigged and no clip ever plays), anchors the clock at 08:85 because
# routines make people travel only at BLOCK BOUNDARIES, drops time_scale to
# 0.02 so the transition budget gate can open at all (a 5-min bathroom visit is
# 1.7 s at 0.05 and 4.2 s at 0.02, against a ~2.6 s requirement), and asserts
# nobody holds a lying/seated pose while the sim says they are travelling:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=<file.tres> --capture=npc-anim --shots-dir=<label> --quit-after-capture
# Penstock placement verify (WINDOWED, needs a REAL TerrainLoader map — the
# terrain scan and prop placement are loader-only). Drives the whole "drop the
# pipe uphill and THAT is the source" path: scans rings for genuinely high
# ground within 90 m, seats a PowerSpout bound to a real prop at the site
# centre, then calls the same SystemGraphView.create_penstock_intake_at both
# the Lab gizmo and the 3D plug-drag commit through. Asserts what a screenshot
# cannot: a Stream Intake prop + graph node exist at the release point (a
# conduit has NO free endpoints — a `resource` item only gets a 3D anchor via
# bound_prop_id), the run RENDERED (3D wires default OFF, and ConduitManager
# ignores model changes while they are — the original "route does nothing"
# bug), the rebuild stamped a measured run ≥ the straight chord plus endpoint
# inverts falling toward the turbine, and the turbine ADOPTED run/bore/head and
# produced power. That last group is the one that failed first: a stream intake
# has no water LEVEL, so the pond path bailed before adopting the route — and
# the fix's change-gate then hid itself, because `absf(NAN - x) > 0.01` is
# FALSE and an unset outlet_invert_m never got its first write. Cleans its
# cap_pen_* items + props afterward:
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=penstock --shots-dir=<label> --quit-after-capture
# Hydro LOAD-TIME diagnostic (WINDOWED, console-only, needs a REAL saved map with
# hydro on it): dumps every penstock/culvert conn's visible_3d, routability, 3D
# instance and BOTH resolved endpoint anchors at four moments — as loaded (graph
# never opened), graph open, back in 3D, and after a Hydro Lab round trip. It
# exists because those states differ: item elevations used to be resolved only on
# graph-view entry, so a culvert loaded anchored at world Y ~ 0 and fired into the
# sky until the player pressed G. Asserts up front that no culvert outlet sits
# above its inlet and no endpoint pair is stranded 120 m apart, and — the state
# no screenshot of this run can show — the WORLD-VISIBILITY gate at each moment:
# runs hidden in first person, shown while the Lab CT is up, and the global
# wires pref handed back on graph close (see "Conduits are x-ray by design"):
Godot.exe.exe --path . --windowed --resolution 1280x720 -- --user-map=mtvernon --capture=hydroload --quit-after-capture
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
**`ortho_uv_scale` must be `BuildingBuilder.roof_ortho_uv_scale(ortho_half_extent)`
— `ORTHO_HALF_EXTENT_M / <half-extent of whatever texture is actually bound>` —
in BOTH the hyper and detail-drape branches, not just one.** The hyper branch
used to leave it at its `1.0` default, which is only correct by coincidence at
quality tiers Low/Medium (`QUALITY_HYPER_HALF_EXTENT` = 500 m there, matching
`ORTHO_HALF_EXTENT_M`); at High/Ultra (1000/1500 m) it silently mis-registered
every roof, worse the farther a building sits from the site center — a bug that
was invisible until a session raised the quality tier specifically to get
sharper imagery. Pinned by `_test_roof_ortho_uv_scale` in
`building_builder_selftest.gd`.
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

**Near-field ground detail (Terrain options → "Near-field ground texture").**
`terrain_detail.gdshader` blends a tiling ground albedo/normal (CC0 AmbientCG
`ground049a`, `use_detail_textures`; procedural fBm fallback when the files are
absent) over the aerial photo inside `near_detail_start..end` (4–30 m from the
camera) to give the flat ortho real relief up close. The set is DIRT/SAND — it
sells playa/desert/gravel and fights grass and forest floor, so it is a player
toggle (`[terrain] near_field_detail`, default true = the long-standing
behaviour). Turning it off restores the plain ortho colour, which also exposes
how soft the underlying imagery is — the grain was partly hiding that.
The setting is applied in TWO places and needs both: `TerrainBuilder`'s
`near_detail_enabled` static is stamped into every material `make_terrain_material`
mints (the SHADER's own default is true, so a terrain rebuild/refresh would
otherwise silently switch it back on), and `TerrainLoader.set_near_field_detail`
pushes it live onto the materials already on screen so the toggle is instant.
The live push walks the whole `Terrain` subtree rather than the named
Ground/DetailGround pair the snow push uses, because the HeightField sculpt tiles
carry the same shader and a tile left on the old setting is a visible seam.
`_run_load_sequence` seeds the static from config before anything builds.
Pinned by `_test_near_detail_toggle` in terrain_selftest.

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
 `MapDefinition.half_extent_m` / `detail_half_extent_m` / `osm_half_extent_m`,
 user-adjustable via Terrain options → "Advanced terrain size" (World size / Hi-res
 DEM-imagery / Buildings-water-veg SpinBoxes, `terrain_options_ui.gd`), which calls
 `TerrainLoader.apply_terrain_extents()` — this restores a control surface that
 briefly existed as location-picker-only UI and was later dropped as collateral
 damage in an unrelated batch commit; `apply_terrain_extents` itself was never
 broken, it just had no caller. Works for an ALREADY-VISITED site, not just at
 map creation, because per-site cache metadata
 (`TerrainCacheSettings.get_meta_extents`) always wins over the global
 `terrain_config.cfg` once a site has loaded once — hand-editing that config file
 does nothing for a returning site. The `terrain_loader` used to
 gate detail behind post-terrain phases — detail now blocks terrain build. DEM caches,
 so the first visit per site pays the fetch once (inside the blocking load sequence)
 and every reload is an instant cache hit. Optional upgrade = OpenTopography SRTM 30 m
 when `user://terrain_config.cfg [opentopography] api_key=` is set (gitignored, never
 commit). **3DEP 1 m lidar detail patch (key required — and gated further, see
 below):** with a key, a US `detail` request whose square is ≤ `USGS1M_MAX_SIDE_M`
 (3200 m, so the 3 km default qualifies) fetches `datasetName=USGS1m` off the same
 `usgsdem` endpoint — the USGS-published bare-earth DTM derived from the 3DEP
 lidar projects, ~0.1 m accurate where Copernicus/SRTM carry 1–2 m of their own
 noise. **OpenTopography restricts USGS1m itself to academic-verified accounts —
 confirmed empirically, an ordinary self-registered key gets HTTP 401 "restricted
 for academics" at every site regardless of coverage** (see
 https://opentopography.org/content/how-access-restricted-data-opentopography, or
 email info@opentopography.org re: an Enterprise key). USGS10m has no such gate,
 so it is what most players actually get; `_retry_opentopo_coarser` classifies the
 401 as PERMANENT same as a genuine coverage gap (both correctly fall back), but
 records which one actually happened (`usgs1m_miss_reason`) rather than collapsing
 them into one generic message, since a player can't do anything about a coverage
 gap but might chase down academic access for the 401 case. Surfaced live in
 Terrain options → Advanced terrain size (`TerrainLoader.get_detail_dem_status`,
 filename-only lookup via `ElevationService.cached_dem_source` — no need to decode
 a 100+ MB cached grid just to answer "which one loaded"). **That grid arrives
 in UTM METRES, not degrees** — every other source here is geographic, and feeding a
 UTM header through the degrees path is a SILENT failure: `(lon − 617228)/1.0` clamps
 every sample onto one corner cell, returns a dead-flat plane, and `grid_is_usable`
 then rejects it, so it reads as "1 m did nothing" rather than as a bug.
 `resample_aaigrid_to_bbox` therefore dispatches on `aaigrid_is_projected` and
 forward-projects each target sample via `GeoMath.lonlat_to_utm` (Snyder PP 1395;
 WGS84 ellipsoid — the ~1 m CONUS NAD83 shift is sub-cell and unmodelled). A
 projected grid that fails the centre-containment gate returns EMPTY and drops a
 rung rather than being stretch-fitted (that would misregister terrain vs OSM and
 imagery while looking plausible). Coverage is patchy by nature — 1 m only exists
 where a project flew — so `_retry_opentopo_coarser` falls USGS1m→USGS10m on the
 same endpoint (the one rung allowed for the `detail` tag), and a PERMANENT failure
 writes `dem_usgs1m_miss_<token>.flag` so the next load skips straight to 10 m
 instead of re-pulling ~190 MB; transient 429/network failures deliberately do NOT
 latch it. The flag carries the `dem_` prefix + standard coord token so
 `TerrainCacheSettings.invalidate_dem` sweeps it with the rest of the generation.
 No CACHE_VERSION bump was needed: `opentopo_usgs1` is a new cache-source key, and
 the broken projected path never cached anything (it was rejected upstream).
 Note a 3 km 1 m square is ~9 M cells ≈ 190 MB of ASCII (measured: 26 s to pull,
 10 s to parse) resampled down to `DETAIL_GRID_N` 512² ≈ 5.9 m/vertex — the win is
 accuracy and noise floor, NOT resolution; raising the mesh resolution to actually
 express 1 m is a separate, unmade decision. 429/5xx → backoff retry (MAX_RETRIES=3). **Open-Meteo enforces a DAILY quota
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
 scatter phases. Cache `user://terrain_cache/osm_vegetation/` (CACHE_VERSION now v8).
 **Cache serializer must include every payload key** — `hedge_rows` was once omitted,
 so cached reloads silently dropped every hedge (fresh fetch had them, cache didn't);
 any new payload key needs matching `_serialize_payload`/`deserialize_payload`
 entries or it vanishes on reload. **Ready-payloads are key-matched to the site**
 (`matches_site`) — the service runs one job with a single-slot pending queue, so a
 listener that changed sites mid-flight must reject the previous site's payload;
 late replies that outlive the loader's 180 s phase budget still queue the scatter.

**Veg overhaul (in progress — plan + full audit:
`~/.claude/plans/i-want-to-overhaul-scalable-biscuit.md`; Phases 0–2 landed).**
**Phase 2 style architecture:** `vegetation/veg_style_store.gd` (`VegStyleStore`)
is the ONE authority for user veg-style persistence — layered v2 JSON
(`{global, family:{pine…}, species:{spruce…}}`, files
`user://vegetation_style_v2.json` + `user://maps/vegetation_style_v2_*.json`),
holding ONLY explicit user edits; v1 files (flat cfg / species-defaults JSON /
per-map JSON) migrate one-way on first read, dropping values equal to
defaults(). Resolution precedence: **species override > user family edit >
catalog SPECS variant > defaults()**, enforced in
`VegSpeciesCatalog.settings_with_variant` via two side-channel keys the store
embeds in the flat merged dict (`_user_family_keys`, `_species_overrides`) —
this is what makes subspecies REAL (spruce/fir/birch dims + colors + white
bark from `VegetationCardFactory.SPECS` finally render; they were dead for
years because family keys always existed). `VegetationStyleConfig` remains the
facade (load_merged/save_global/save_map/save_species_default all delegate).
`VegetationLayer` v2 persists SPARSE settings deltas only (`user_settings()`);
the render path merges those over the store — never merge `get_settings()`
(complete dict) over the style, that is the shadowing bug Phase 2 removed.
`--headless --import` after touching these (VegStyleStore is a class_name).
Selftest: `vegetation/veg_style_store_selftest.gd` (precedence matrix,
migrations, layer sparse round-trip).
Invariants to preserve: `AutoVegetationRuntime.neutralized_settings` — the
per-species `*_bulk_scale` keys are FORCED neutral on the auto path (the
generator bakes height into each record's scale; letting the style's 1.6 win
oversized every auto tree) and `auto_tree_scale` (style key, clamp 0.2–3.0,
rebuild-only) is the one whole-forest size knob. `VegetationRuntime.reground`
MUST receive live settings + growth map (a bare rebuild was the "V pops full
detail" bug). All veg MMIs get `visibility_range_fade_mode = FADE_SELF` + a
24 m margin via `VegetationRuntime.apply_visibility_range` at BUILD time only
(AMD Vulkan hard-crashes on live visibility_range sweeps). Built meshes/
materials memoize in `VegAssetCache` keyed `kind|species|tier|hash(settings)`
(matches batch partitioning; `clear_foot_cache()` clears it too). Generator
scatter order is POINTS→ROWS→HEDGES→POLYS→GAP_FILL — explicitly mapped
features must never lose the budget race to polygon fill.
**Tree LOD (Overhaul v2 — `vegetation/veg_lod_policy.gd` +
`veg_impostor_baker.gd`/`veg_impostor_set.gd`/`veg_impostor.gdshader`):**
every tree chunk builds exactly TWO batches: the real 3D mesh inside a
CAMERA-based detail range (`tree_detail_distance_m`, per-quality-tier default
120/160/220/400 m, user slider in Tune-look Advanced) and the baked impostor
beyond it. The old SoI ring system and the large-map `auto_force_far_canopy`
flattening are GONE — force_far was why a 30 km map never rendered a real 3D
tree at ANY distance. Its prim-guard duty moved to `VegLodPolicy`: the loader
computes a budget-shrunk `tree_detail_eff_m` per rebuild (worst-case near-set
tree count over 256 m chunk neighbourhoods vs the tier's `tree_near_budget`
400/800/1500/4000, 60 m floor) and injects it via
`_auto_veg_runtime_settings`. Visibility ranges are BUILD-time only (AMD
Vulkan hard-crashes on live sweeps); the slider triggers the debounced
rebuild. Impostors are baked IN-PROCESS (no GLBs exist — meshes are
procedural): 8 yaw + 1 top view into a 1024² 3×3 atlas + a foliage-vs-bark
mask atlas, neutral-season materials, keyed by a STABLE content hash
(`bake_key` — excludes drape/growth/LOD keys, INCLUDES String values so an
archetype switch re-bakes), cached `user://veg_impostors/<key>.res`,
BAKE_VERSION-gated (now v4). Headless/selftests never bake: `cached_set`
misses fall back to the simplified crossed-card stand-in deterministically
(the flat branch-card fan is deleted); windowed bakes debounce ONE rebuild
via `_on_impostor_bake_completed`. The impostor shader is unshaded (day/night
from the env-sync uniforms), billboards manually in vertex (spatial shaders
have no billboard render_mode), and seasonally recolors/thins ONLY
mask-flagged foliage pixels. Selftest: `vegetation/veg_lod_policy_selftest.gd`.

**Seasonal phenology (Phase 6).** `SeasonModel.season_signals` now damps every
signal by ABSOLUTE latitude (`seasonality_strength`: 0 below ~15°, 1 by ~35°,
returned in the dict as `seasonality`) — inside the tropics day length barely
varies, so a mango at 5°N must never turn red; the SH half-year flip still runs
at full strength. `SeasonModel.estimate_winter_min_c(ws, lat)` samples the
coldest ~60 days (flipped south) off WeatherService and feeds
`VegSpeciesRegistry.species_allowed_at(id, lat, winter_min_c)` — cold-hardiness
now gates the auto mix alongside the latitude range, with NAN = "unknown, use
latitude only" so an offline session keeps its forest.
`vegetation/leaf_phenology.gdshaderinc` is the ONE leaf law shared by all three
canopy tiers (leaf shells / FAR cards / impostor): whole-leaf removal on a
WORLD-stable key at `(1-leaf_coverage)*deciduousness` (the cards used a
SCREEN-space dither that crawled with the camera; the shells shrank leaves to
nothing instead of dropping them), one per-tree autumn ramp, and winter
dormancy through the FOLIAGE MASK rather than deciduousness — so evergreen
needles grey off in the impostor tier the way they already did up close.
`VegLeafFall` (`vegetation/veg_leaf_fall.gd`, High/Ultra via
`RenderProfile.veg_profile()["leaf_fall"]`) hangs ≤6 GPUParticles3D emitters
over the nearest NEAR-ring deciduous chunks during the drop window; it SCANS
the built batch nodes on a 0.75 s tick rather than living inside them, so it
survives every veg rebuild. `VegLitterMask` rasterises the deciduous instances
into a coverage mask (resolution from the map extent — a fixed 256² over 30 km
is 117 m/texel and one street tree browned a 350 m circle) consumed by
`terrain_detail.gdshader`'s `litter_*` uniforms, pushed by terrain_loader with
the snow uniforms and change-gated. Selftest:
`vegetation/veg_phenology_selftest.gd`.

**Per-area fill (Phase 7).** Aim the crosshair at an OSM vegetation area and
Interact → the Fill drawer (`scenes/ui/veg_area_fill_ui.gd`, opened by
`terrain_loader.open_veg_area_modal`; its "Tune look…" button still reaches the
all-of-type edit via `open_veg_area_tune`). Fills are ADDITIVE edits stored in
`AutoVegetationEdits.fills` (VERSION 4) keyed by the area's metre-rounded
centroid tag, so they survive an OSM re-fetch that renumbers the polygon list;
`cleared`/`patches` stay subtractive and are still replayed after all scatter,
which is why `add_fill` LIFTS any clear over the same outline (otherwise the
clear would erase the forest just planted). One implementation does the work —
`AutoVegetationGenerator.apply_fill`, seeded PER FILL — called both by the
generator's new FILLS phase (last, after GAP_FILL: a player-authored fill is
the most explicit instruction on the map and may replace what scatter put
there) and by `terrain_loader.apply_area_fill` for the live edit, so a fill
looks identical before and after a reload. Density scales SPACING, not a count.
Loader API: `apply_area_fill(idx, {species, density, height_m, replace})`,
`area_fill_params(idx)`, `clear_area_fill(idx, clear_now)`,
`get_veg_area_info(idx)`. Fill AND clear re-mesh only the 256 m chunks the
outline touches (`AutoVegetationRuntime.rebuild_chunks` +
`VegetationRuntime.chunk_keys_for_polygon`, falling back to the whole-layer
rebuild when the incremental path can't apply). That path deliberately does NOT
clear shader registrations or the growth map: surviving chunks keep theirs, new
batches register themselves, and growth slots pointing at freed MultiMeshes are
dropped lazily on the next pass (the Phase 9 dedupe keys entries on species +
position, so re-registering a rebuilt chunk re-attaches to the same plants). The
chunk set comes from the polygon's AABB — a superset, since missing a chunk
would leave stale trees on screen, while a spare one costs only time. Verify
with `--capture=areafill` (above) plus the `_test_area_fill_*` and
`_test_incremental_chunk_rebuild` checks in `auto_vegetation_selftest.gd` (the
latter pins incremental == full-regen).

**Veg UI (Phase 8).** The V dock is on `UITheme` (panel/button/chip styles,
`LAYER_PANEL`; the Tune-look modal moved to its OWN CanvasLayer at
`LAYER_MODAL` — the two shared layer 25, so which drew on top came down to
sibling order). Every toggle button now has a real hover face; before this all
15 rendered hover identically to normal. A persistent **chip row** carries the
state that used to be implied or buried in a clipping status label: tool +
species (family-coloured swatch), density, brush radius or shape, size
variance, a **custom look** badge for the invisible per-brush override, the
locked selection's area, and the picked plant. `chip_specs()` is pure data so
the dock's visible state is assertable offline. **Tune look… no longer closes
on Apply** — it re-baselines and stays open, each `_values`-keyed slider gets a
per-slider revert (↺) plus an amber "changed since last apply" label, and the
Apply button counts pending edits. **Select + Brush is the per-tree tool**:
click picks ONE plant (`VegetationLayer.nearest_plant` → loader
`pick_plant_at`/`delete_plant_at`/`scale_plant_at`), Del deletes, `[`/`]`
resize, H promotes it to a hero GLB (the SPECIES picks the model and the card's
apparent height sets its scale, so a pine becomes a pine — placed before the
card is removed, so a hero-cap refusal leaves the plant standing); heroes are
pickable too and hero placement finally pushes an undo entry. The Tune-look
modal's ~32 per-species shape sliders are grouped into collapsible sections
(Size & form / Branches & clumps / Foliage / Growth / Detail & LOD) by a rule
derived from the KEY (`slider_section`), so a new slider files itself and the
selftest can assert every real key lands in a known section. **Top-down** mounts the survey drone and locks it to an ortho view via
the `vegetation_edit_ortho` meta the drone had always read but nothing ever
set; leaving the dock releases it. Drone WASD is gated while a LineEdit/SpinBox
holds focus (typing a brush radius used to fly the drone). The crosshair area
focus and the paint selection now own SEPARATE highlight meshes. Selftest:
`vegetation/veg_dock_state_selftest.gd`.

**Procedural deciduous tree (space colonization).** The broadleaf skeleton is
grown by space colonization (Runions et al. 2007, `_build_branch_skeleton` in
vegetation_card_factory.gd): a deterministic attractor cloud fills the crown
envelope (`_sc_attractors` — profile from the ARCHETYPE table), limbs seeded
at `deciduous_primary_placements` (pure data, selftest-asserted) grow
step-by-step toward their nearest attractors and fork where the field
diverges; two Laplacian passes over pure chain links round the per-step kinks
(forks/seeds/tips pinned). SC tuning traps pinned by
`auto_vegetation_selftest`: step ≪ crown radius or the kill radius (1.05×step)
wipes crown regions before growth visits them; saturated nodes are SKIPPED in
the nearest search or their attractors starve and the loop stalls; momentum
can ratchet shoots past consumed attractors — hard-clamped to the envelope
(+6% ceiling / ×1.05 radial fence). NEAR trunk is a 7-sided tapered tube (UVs
ping-pong inside the bark texture's opaque CENTRE band — the margins are
transparent card silhouette and a full 0..1 wrap renders a cutout slab).
Foliage clumps cap the real tips (`_clusters_from_tips`) at BOTH tiers (the
stand-in runs the skeleton `emit=false`; the impostor atlas bakes FROM the
NEAR mesh); clump radius tiles the ENVELOPE volume share, clump centres
pre-fit inside the authored crown width, and the clump FLOOR is the authored
crown base (floored at 0 the canopy swallowed the trunk — bush balls).
leaf_canopy.gdshader stamps TWO interleaved size-jittered per-cell leaf
layers and keeps surviving leaves near-OPAQUE. **Bump
`VegImpostorBaker.BAKE_VERSION` on ANY change to this geometry** (now v4) or
cached impostors serve the old silhouette forever. Verify with
`--capture=tree` (pinned to July 15 so seasonal thinning can't fake or hide a
shape defect) and `--capture=veg`.

**v3 parameter model (Overhaul v2 — REAL UNITS + ARCHETYPES).** Tree families
are authored as: `<fam>_height_m` (total, EXACT — `_normalize_tree_surfaces`
rescales every surface so the built mesh hits it to the centimetre),
`<fam>_crown_width_m` (radial, pre-fit + normalized), `<fam>_trunk_diameter_cm`
(tube radius = cm/200, honest), `<fam>_crown_base_pct`, `<fam>_archetype`
(round/spreading/columnar/vase/weeping/conical), `<fam>_variant_seed` (0–9)
and four 0..1 character macros (branchiness/crookedness/droop/
foliage_density). `vegetation/veg_tree_archetypes.gd` maps archetype+macros
onto the SC builder's internal knobs at ONE choke point
(`_deciduous_adapter_settings`); the internal keys are derived, never
persisted. Advanced fine keys (leaf_*, whorl_*, fur_*) derive from the macros
unless the player explicitly sets them (`_derived_or_user` reads the store
provenance side channel, which `settings_with_variant` extends with
species-override keys). **One scale rule:** `species_bulk_scale` is hard 1.0
for trees; painted trees render at exactly the previewed size × paint jitter
(and plant MATURE — the dock "Plant young" toggle opts into seedlings); auto
records bake `scale = osm_height / resolved_height` at scatter (so
`deciduous_height_m`/`pine_height_m` changes are in `_GENERATOR_FLOAT_KEYS`
and trigger a re-scatter). `foot_local_y` is a constant 0 for trees.

**Fresh start (v3 stores).** `VegStyleStore` VERSION 3 lives in NEW files
(`vegetation_style_v3*.json`); legacy v1/v2 style files are never read
(in-place backup, deleted by the reset tooling), migrations gone.
`VegetationLayer` VERSION 3 keeps painted records/heroes/zones from ≤v2 files
but drops settings deltas and per-record card_settings; `create_empty()`
starts with EMPTY settings (it used to seed the full defaults dump as "user
deltas" — every fresh map then froze its defaults against later style edits).
Picking a subspecies in the dock no longer auto-attaches a card_settings
snapshot; `card_settings` is written ONLY by explicit "Apply to brush".
**Resets that work:** `invalidate_user_vegetation_edits` (was building
filenames from the combined "%.4f_%.4f" cache token — matched NOTHING) now
uses per-component `CoordToken.token()` and covers the v3 store + retired
sidecars; Terrain options gained "Reset map veg style" and "Reset ALL veg
styles" (loader `reset_map_veg_style`/`reset_all_veg_styles`).

**Tune-look WYSIWYG contract.** The preview builds from the SAME resolution
the render path uses: `_merged_settings` re-derives the VegStyleStore side
channels and applies the loader's `veg_quality_tier_style()` overlay under
the same only-fills-defaults rule; a headless PARITY selftest
(`_test_preview_parity` in auto_vegetation_selftest) builds the preview-path
and render-path meshes from one store state and asserts identical geometry.
Editing a NAMED subspecies routes edits (sliders AND the archetype dropdown)
to per-species overrides; sliders DISPLAY resolved per-species values.
`save_global_patch` PRUNES values equal to defaults();
`apply_vegetation_look` re-reads `flat_merged` after persisting. Modal
sections: Size (real-unit knobs + archetype dropdown + variant) / Character
(4 macros) / Foliage detail / Growth / Advanced (incl. the Detail distance
slider); colour rows Tint / Highlight / Bark; hover help via `SLIDER_TIPS`.

**Resolution ladder.** species override > user family edit > SPECS variant >
defaults, with: (1) a user FAMILY edit applies to named variants' numeric
dims as a RATIO over the family default (clamp 0.15–8; flat replacement made
every subspecies a clone on any tuned map) — the archetype string applies
directly; (2) a species-layer entry for a GENERIC family id is the WEAKEST
user layer (yields to any family edit). Selftests: veg_style_store,
vegetation_growth (`_test_settings_with_variant_non_clobber`).

**Harness write-discipline.** `--capture=vegdock` exercises the modal's Apply,
which persists global + per-map style — the harness snapshots the style files
(global/map v2 stores, layer JSON, species defaults, presets) and byte-restores
them after (`_snapshot_files`/`_restore_files`, same discipline as areafill).
Before this every vegdock run silently rewrote the player's saved looks.

**Growth (Phase 9).** `VegetationInstanceMap` holds ONE entry per PLANT with a
list of MultiMesh slots, not one entry per slot: a NEAR-ring tree lives in two
MultiMeshes, so a full growth pass used to re-run the terrain height query and
the growth curve once per SLOT (~408k `ground_y_at` calls where ~150k plants
exist). The query and the scale are now computed once and only the transform
write repeats; the budget counts plants, and OUTER-ring impostor slots are
registered scale-only (`reground=false`) so a 700 m card never re-samples
terrain. Slots holding a freed MMI are dropped individually — read the slot
UNTYPED first, because assigning a freed instance to a typed variable throws
before any `is_instance_valid()` guard runs. `forest_age` (style key:
`mature`/`mixed`/`young`, default mature = the long-standing behaviour) shapes
where in the growth span `ensure_birth_times` seeds a fresh stand; the
Tune-look modal exposes it and its "Growth yrs" sliders are now "Maturity age
(yr)". **Headless caveat pinned in the selftest:** under the dummy renderer
`MultiMesh.set_instance_transform` does NOT round-trip through
`get_instance_transform` (the buffer lives in the RenderingServer stub), so the
offline test asserts the derived scale and the ground-query COUNT rather than
reading transforms back.

**Food forest → graph (Phase 10).** Adding an OSM vegetation area to the graph
(`terrain_loader.add_veg_area_plant_to_graph` → `add_imported_plant`) now
summarises the food-bearing trees ACTUALLY standing in that outline —
`VegFoodYield.summarize` over both veg layers, per-tree registry yields ×
maturity — and the bed becomes a `food_forest` plant node instead of the
generic annual-crop one. `ResourceFlowEngine._process_food_forest` takes its
own branch: rain-fed (an unwired water port is normal, not a fault), and a
whole year's yield delivered across the harvest window rather than trickled
hourly, so a food forest reads as a season. Outside the window the node idles
with "harvest in N d". Windows may WRAP the new year (an orange is doy 335→90),
which is why `in_window`/`window_days` exist rather than a `start <= doy <= end`
test. Maturity gates yield: nothing below half apparent size, ramping to full —
a freshly planted fill must not read as a working orchard. Verify with
`--capture=foodforest` (above) + `vegetation/veg_food_selftest.gd`.

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
call `_reseat_actors_after_edit(touched_keys)` — scoped to the committed tiles
(an actor outside every touched tile is never moved) and lift only when the
FEET are genuinely below the new surface (`pos.y < gy - 0.05`, small lift, keep
horizontal velocity; the player origin is at the capsule bottom, so the old
`< gy + 0.1` test fired on every commit and launched a grounded player 2 m up —
the "player pops on brush release" bug). Lowering lets gravity work. Tile meshes share DetailGround's drape material (re-pointed via
`set_material` whenever imagery lands). Legacy coarse/detail delta grids +
earthworks migrate one-time into tiles (`_migrate_legacy_edits_to_tiles`).
Validate with the `--sculpt-test` harness (above) + terrain_selftest.

**Unified edit toolbar (`scenes/ui/toolbar/`) — T / V.** One Photoshop-style
surface for BOTH tool sets: a vertical tool strip on the left (TERRAIN: Raise /
Lower / Smooth / Level / Ramp / Pond / Rain / Drain / Measure; VEGETATION:
Paint / Place / Clear / Select) plus a slim options bar across the top carrying
the ACTIVE tool's parameters, its shape picker, the species picker, live
ground/basin readouts and Undo. It exists to fix three things the two legacy
docks could not: they locked out navigation, they shared one global
radius/strength/hardness across every tool, and getting the camera back took
Esc THEN Space. The old docks are untouched and still reachable on **Shift+T /
Shift+V** until they are retired.

**It is NOT a modal — it runs in CursorController's TOOL OVERLAY tier**
(`request_tool_overlay` / `release_tool_overlay` / `has_tool_overlay` /
`overlay_look_active` / `tool_overlay_movement_active`). `should_capture_look()`
excludes the overlay, so every downstream consumer (crosshair, interaction
focus, grab controller) correctly treats it as "not capturing", while the actual
mouse-capture decision is `should_capture_look() OR overlay_look_active()` in
BOTH `_apply_capture_deferred` and the diagnostic `_wanted_mode` — keep those
two in sync or the reconcile warns every quarter second. `player.gd` gained
exactly three additive branches: RMB edge tracking + an overlay-look motion
branch in `_input`, `tool_overlay_movement_active()` in the movement gate
(guarded by a SpinBox-aware `_keyboard_captured_by_ui()` so typing a brush
radius does not walk the player), and a `has_tool_overlay()` guard around
tool-use — **that last one is mandatory: tool use fires on raw LMB, so without
it every paint stroke sprays the fire extinguisher.** Because the overlay never
touches the pause latch, ONE Esc returns full control. And because it is not a
blocking modal, `InputGuard` stays open and terrain_loader's key dispatch stays
live while it is open, which is how T/V toggle it closed (the legacy docks
cannot — their modal claim eats their own hotkey).

**Per-tool parameters are the headline fix.** `EditToolbarState`
(`toolbar_state.gd`, pure data) holds a params dict PER TOOL seeded from a
schema, plus per-tool shape memory and the shared veg brush identity
(family / subspecies / hero preset). `option_specs()` is the row model the
options bar renders from. Persisted to `user://toolbar_prefs.cfg` via
`save_to`/`load_from` (file I/O lives on the model so the selftest can
round-trip a TEMP path), loaded in `_ready` BEFORE the strip is built, written
on a 1 s debounce and flushed immediately on close.

Traps worth keeping: `VEG_FAMILIES` stores `VegetationPaint.Preset` values as
LITERAL ints so the model still loads with a stale class cache — the selftest
asserts they still match the enum, because a reorder would silently paint the
wrong family everywhere. `set_veg_family` resets the subspecies only on a REAL
family change (membership belongs to the species catalog; a name-prefix guess
wrongly cleared spruce, which is a pine). T/V go through `toggle_section`, which
SWITCHES sections when the toolbar is already open on the other one rather than
closing. There is no fullscreen capture rect — the two panels stop mouse events
over themselves and everything else arrives via `_unhandled_input`, which is
what lets RMB reach the player. **RMB deliberately does NOT close a polygon or
cancel a shape** (it is the look button); polygons close with Enter or by
clicking the first vertex. Options rows are rebuilt per tool switch with the
dying rows DETACHED before `queue_free`, or the container measures both sets for
a frame and the bar visibly doubles in width. Selftest:
`scenes/ui/toolbar/toolbar_selftest.gd` (312 checks, in the Validation list).

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
| DiscordIdentity | core/discord/discord_identity.gd | "Sign in with Discord" via OAuth2 **authorization-code + PKCE, no client_secret** (needs the app's "Public Client" toggle — see LOCAL_CONFIG.md). Loopback `TCPServer` on one of 34199/34200/34201 catches the callback; refresh token in `user://discord_auth.cfg`; scopes deliberately limited to `identify` + `guilds.members.read`. Signals `sign_in_completed/failed`, `signed_out`, `membership_checked` |
| DiscordDirectory | core/discord/discord_directory.gd (+ `Relay` and `Population` children on MultiplayerSession) | "Who is playing right now", as ONE webhook message edited in place (no server, no bot). Read/heartbeat/vacate + the host election; `play_together()` is the whole one-button flow. Polls only while the lobby is open or we host — the webhook route budget is shared by the community. Signals `directory_changed`, `directory_error`, `election_result(won, record)` |
| MultiplayerSession | core/multiplayer/multiplayer_session.gd | **v3**: UPnP reachability + candidate-address connect ladder + Discord admission (see below). Listen-server co-presence (ENet host/join, avatars, host clock) + Phase 3–4 design share/ghost-merge + live graph/props sync (`Design` child) + Phase 5 session text chat (`Chat` child; Enter compose, proximity bubbles, mute, Discord invite deep-link) + Phase 6 hardening (join-code expiry, optional password, trusted-key allowlist, peer/snapshot caps, rate-limit kicks, local `user://mp_telemetry.log`); lobby via Timeline **Multiplayer** chip |
| AirQualityService | core/weather/air_quality_service.gd | Open-Meteo/CAMS hourly aerosols (pm2_5, pm10, dust, AOD, us_aqi); `air_quality_ready/failed` |
| ExtremeWeather | core/weather/extreme_weather_director.gd | Resolves hazards as a PURE FUNCTION of abs hours; `hazard_began/ended`, `risk_profile_ready` |
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

## Night sky (stars)

`star_system.gd` (root, node "StarSystem" under Main) + the star block of
`sky.gdshader` + `core/astronomy/star_sky_math.gd` (`StarSkyMath`, pure static,
selftest `core/astronomy/star_sky_selftest.gd`). **Orientation is COMPUTED,
never calibrated:** every sky tick StarSystem pushes the local sidereal time
and the equatorial basis for the current latitude — `pole = (0, sin φ, −cos φ)`,
`meridian = (0, cos φ, sin φ)` (due south), `east = (1, 0, 0)` — as three
vec3 uniforms, and the shader inverts them per pixel: `dec = asin(v·P)`,
`H = atan2(−v·E, v·M)` (positive WEST), `RA = LST − H`. **The bug this
replaced, so nobody puts it back:** the shader rotated the view about the pole
by LST and then read the texture latitude off the rotated WORLD vector's y —
the zenith as the texture pole — which is only right at latitude 90°; the old
RA/Dec "offset" + "flip" sliders existed to fight that and could only null it
at one instant. They are gone (`user://star_calibration.cfg`
`calibration_version 2` erases the keys); HOME toggles the computed
reference-star markers (Polaris/Sirius/…) which must sit ON the texture stars.
**The map's registration is DATA:** `assets/sky/starmap_equirect_8k.json`
(sidecar next to the PNG) says which RA sits at u = 0, which way RA runs across
the image (`ra_direction −1` = increases leftward, the inside-the-sphere
convention) and whether the NCP is the top row — MEASURED by
`tools/starmap_prepare.py` from the bright stars, never assumed. The map is a
J2000 plate-carrée export from Stellarium (`tools/stellarium_starmap_export.ssc`,
GUI/ground/atmosphere/labels off; Stellarium's all-sky projection works in the
mount frame — keep the mount equatorial). Two traps the prep tool exists to
close: Stellarium draws bright stars as SATURATED discs, so "the brightest
pixel" ties across dozens of stars (blobs are ranked by integrated brightness),
and the Milky Way core at intensity 1.6 out-sums every star disc (compact-disc
area/mean filters). The old FOV-180 "Cylindrical" screenshots were alt-az
panoramas with the GUI baked in and could not be registered at all. **Third
trap — Polaris vanishes without it:** Stellarium draws every star as a fixed
~10 px disc in IMAGE space, and a plate carrée squeezes 1 px of x into
`360/w·cos δ` degrees, so at dec 89.26° a 10 px disc is 0.006° of sky and the
shader renders the pole star as a sub-pixel sliver. The prep tool's
`pole_footprint_dilate` runs a 1-D horizontal MAX filter of radius
`R·(1/cos δ − 1)` per declination band (R measured from the anchor star's own
disc, x wrapping like RA) for |δ| ≥ 45°, so image-space discs become
sky-space discs; recorded in the sidecar under `prepare.pole_footprint`. **One
timezone for sun AND stars:** `CelestialClock.zone_offset_hours` (rounded
meridian + the US DST rule) feeds `get_solar_time`, both `*_to_clock_time`
inverses and `_julian_day_utc_for`; `get_julian_day()` is UTC. Sidereal time
is `StarSkyMath.gmst_deg` (Meeus 12.4) for the stars, moon and clock alike.
Texture import: BC7 (`compress/high_quality=true`), no mipmaps — the sampler
is `filter_linear` and mips bloomed halos. Planets stay in `planets.gd` but
share `StarSkyMath` for their alt/az.

**Daylight model (`core/env/daylight_model.gd`, `DaylightModel`) — ONE curve
for the sun, the sky and the ground.** The sunrise used to switch on like a
lightbulb because four different altitude curves ran the lighting: the
DirectionalLight faded in with `smoothstep(-0.1, 0.2, sin alt)` — 26 % of noon
power, pure WHITE, hard shadows, with the disc still 5.7° BELOW the horizon;
the sky shader went from black to full twilight between −7° and +2°; the
ambient ramp was still a third of daylight at −12°; the forest went dark over
its own 4.6° window. Now `main.gd` reads everything off DaylightModel and
`sky.gdshader` carries `daylight_fraction()`, a line-for-line MIRROR of
`DaylightModel.sky_light` (edit both or the ground and the sky darken on
different curves; the selftest pins the GDScript side). Direct beam:
Kasten-Young air mass through the SAME four-term clear-sky transmittance
`SolarIrradiance.dni_clear_sky_wm2` uses for the PV physics, normalised to the
zenith (2.5 % on the horizon, 31 % at 5°, 52 % at 10°, 85 % at 30°), zero
until the refracted upper limb clears −0.9°, times `SUN_ZENITH_GAIN` 1.3 so
the midday look the old high-sun boost gave is preserved. Beam COLOUR:
Rayleigh optical depth relative to green over 0.45 of the excess air mass
(≈2100 K on the horizon, ≈3700 K at 5°, white by 30°), `sun_warmth` scales
it; the light's colour is `_sun_clear_color × _hazard_sun_tint`, so a cleared
hazard restores the altitude colour, NOT flat white (the old code hard-reset
`Color.WHITE`). The moon gets the same extinction + reddening. Skylight:
55 % at sunrise → full by 15° above; `exp(−0.25 · depression°)` below (−6° =
22 %, −12° = 5 %, cut by −21°), scaled by `twilight_length`; it drives the
ambient (`lerp(night, day, sky_light)`), the fog/glow `night_amount`
(`1 − palette`) and the shader's night mix. Vegetation's `night_factor`
follows the BEAM (`1 − smoothstep(0, 0.35, direct)`), not a step at sunset.
⚠ `air_mass()` returns the HORIZON value below 0°: the Kasten-Young fit is
only defined to −6.08° and, evaluated there with the sine clamped, it SHRINKS
again as the sun sinks (12 at −3°), which wobbled the beam and its colour
during the disc rise. Note a player running `ambient_energy_mult 0` (the
author's own prefs at the time) sees the ground lit by the beam alone —
the ambient ramp being wrong was probably why it got zeroed. Verify with the
selftest and `--capture=dawn` (Validation list).

**Night-sky look (visual polish pass).** The shader's TWILIGHT/NIGHT blocks are
a solar-DEPRESSION model: `_sunset_amount` is 1 on the horizon and gone 15°
above / 14° below; `_night_amount = 1 − min(daylight_fraction / 0.55, 1)`, i.e.
the DaylightModel twilight envelope (civil twilight still 22 % lit, gone by
−21°). Two older forms, so nobody restores them: ONE symmetric sunset tint from
30° above to 30° below the horizon (afternoon went pale early, midnight stayed
violet) with "night" already 70 % black with the sun ON the horizon (dim
sunsets, purple night); then a `smoothstep(−0.12, 0.03)^1.6` that was black by
−7° while the ground ambient was still two-thirds of daylight (dusk read as a
switch). The star washout reads the WHOLE sky's luminance, so the twilight
glow hides the faint stars exactly as the moon does. The dark sky is a
near-black blue-grey gradient (`night_top/bottom_color`, no purple) plus three
separate user light sources: airglow band (`airglow_strength/color`), a
light-pollution dome (`light_pollution/_color`) and moonlit sky
(`moon_sky_glow`, from the moon's phase × altitude); their luminance feeds
`stars_wash`, which raises the star background cut so a full moon hides the
faint stars and the Milky Way like it does outside. `twilight_drama` scales
the horizon fire band (pushed past 1.0 so bloom carries the glare), the
aureole/glow near the horizon and the Belt of Venus opposite the sun. Star
look: every neighbour tap is in TEXELS (`stars_texel`, pushed by StarSystem
from the texture size, so 8k and 16k render alike); `stars_point_size`
erodes/dilates the discs by a texel; star COLOUR is read off each disc's
fringe (the export clips cores to white) and re-applied to the core's
luminance (`stars_saturation`); the map is split by luminance into star cores
(contrast curve) and the diffuse Milky Way, which is sampled through a 4-texel
ring (the export's dithered, block-compressed band SPECKLES at one texel) with
its own `milkyway_gain/saturation/tint`. Texture quality: Settings → Stars
offers the 16k map (`assets/sky/starmap_equirect_16k.png`, same pipeline,
BC7 = 128 MiB VRAM) when it is shipped; `StarSystem.texture_quality`.
Planet labels: `PlanetSystem.planet_labels_mode` (0 off / 1 on highlight
within 3° of the view centre / 2 always; sky-gated on the sun below +3°),
a CanvasLayer of Labels projected through the active camera, persisted with
the planet prefs. Knobs live on Main (`twilight_drama`, `airglow_*`,
`light_pollution*`, `moon_sky_glow` → `_update_celestial_sizes`) and persist
through `SimSettingsController.apply_sky_setting` / `[rendering_adv]`.

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
- `linkage_selftest.gd`: offline deterministic (1122 checks) — in CLAUDE.md validation
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
**Hardware detail + BOM + build guide (ported 2026-08-04).**

- **`LinkageBom`** (`core/linkage/linkage_bom.gd`, pure static) — the whole
  bill of materials: counts, priced line items, masses, dimensions, actuator
  stroke, panel electricals, per-joint `assembly_steps`, plus `to_csv` /
  `to_json` / `fab_counts`. Counts are derived ANALYTICALLY from the params
  (as `gatherBOMData` does), because the solver only emits bolt geometry when
  "show bolts" is on while the hardware exists regardless; the selftest
  cross-checks the two against each other, which the web app never did.
  **Masses are metric** — `PackedSpec.WOOD_KG_M3` (470) and steel 7850 —
  because `packed_spec_for` now reduces the SAME extracted helpers
  (`bracket_mass_kg` / `bolt_mass_kg`), so a design's shipping weight and its
  BOM weight can never disagree. The web app's lb constants (`woodDensity
  0.018`, 0.5 lb/bracket, 0.01 lb/bolt) are deleted, not converted, so figures
  run ~6% lighter than a web export. **Two deliberate divergences:** stack
  washers are BOM-only and must NEVER be added to `packed_spec_for` (it would
  move the pinned shipping masses in packing_selftest), and cap uprights ARE
  priced here though `gatherBOMData` omits them — flagged in `bom.warnings`.
- **`LinkageDrillPlan`** — hole patterns per beam type. The reciprocal R#/X#
  positions are derived ANALYTICALLY from support-beam geometry rather than by
  porting `rcp-ring`/`rcp-cross` bolts: the web app only uses those bolts as a
  pass-through (it projects each back onto a representative beam), and adding
  ~3n bolts would move `get_stats().bolt_count`, `packed_spec_for`'s mass and
  the crew graph at once.
- **Hardware assemblies** — `LinkageHardware` (data model + `ensure`),
  `LinkageHwLayout` (axis-stack maths: `compute_axis_layout`,
  `assembly_sandwich_gap`, snapping, mirror coupling), `LinkageHwPresets`
  (the 9-part library under `core/linkage/hardware/`), `LinkageHwParts`
  (procedural meshes) and `LinkageHwAssemblyBuilder` (per-part
  MeshInstance3D + StaticBody3D so Godot can ray-pick them — a mesh with no
  body is invisible to the physics server). `params.hardware_assemblies` is
  stored in the web app's own **camelCase** shape, the one deliberate casing
  exception in this port, so unknown keys from a newer web build survive a
  round-trip instead of being silently dropped.
- **`LinkageHardwareSpacing` is THE choke point** where hardware takes over the
  structure's stack gaps and bracket dimensions. `effective_params(p)` is
  called at exactly two sites — `LinkageSolver.solve` and
  `LinkageGeometry.support_beams` — and **returns `p` ITSELF when
  `show_hardware_full_detail` is false**, which is what makes the flag-off path
  bit-identical to the pre-hardware port. ⚠ **That flag defaults FALSE and must
  stay that way**: every pinned reference value in `linkage_selftest.gd` was
  generated by running the real JS app with the `hw*` globals mocked off
  (`tools/linkage_reference.mjs`), so flipping the default silently re-pins the
  entire suite to a different configuration. The selftest asserts the identity
  with `is_same()`, not value equality, so it is protected by construction.
- **Build Guide** (`scenes/ui/linkage_build_guide_modal.gd`, 📋 in the Lab
  topbar or the prop edit drawer) — summary, editable-price BOM tree, weight
  breakdown, cut list, `_draw`-painted drill templates + U-bracket detail
  (`LinkageGuideCharts`), the **assembly sequence** from `bom.assembly_steps`,
  the crew Gantt, actuator and electricals. **Hardware Detail**
  (`linkage_hardware_modal.gd`, 🔩) — assembly tabs, explode slider, per-axis
  part cards with preset pickers, ray-pick + drag-snap along a part's own axis.
  Both live on `UITheme.LAYER_MODAL + 1` so they stack OVER the Lab;
  `CursorController` keeps a modal stack, so Esc pops them one at a time.
- **What makes the hardware preview read correctly** (each of these looked
  "nearly right" while wrong):
  (1) `LinkageHardware.sync_beams_from_structure` re-cuts every preview beam
  from the DESIGN's own members (V-beams FULL length, H-beams the web's own
  8–24″ segment rule — both per `hwSyncBeamPartFromState`); (2)
  `LinkageHwParts.beam_mesh` drills real bolt holes and translates the member
  so its ALIGNMENT hole sits on the stack axis; (3) every part is anchored on
  its axial CENTRE and `flipAxis` is a half-turn about that centre — anchoring
  on the start looked identical for straight parts but slid every flipped part
  a full part-length out of its slot; (4) `part_transform` adds
  `bracket_hole_y` to the cross offset on HORIZONTAL axes, because that chain
  hangs off the bracket's side wall, not its centre; (5) timber uses
  `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS` — plain no-depth alpha stacked every
  internal face of the drilled mesh into a milky mess. **Layout numbers are
  pinned against the REAL web app**: `tools/linkage_hw_reference.mjs` runs
  hardware-detail.js in node (browser + THREE stubs) and
  `_test_hw_layout_reference` pins every default part's base/len/rank/centre
  per axis. The bracket GLB is THREE meshes under differently scaled nodes —
  `glb_bracket_vertices` merges them all (single-mesh loading renders one side
  plate that reads as a stray nut) and `_build_glb_bracket` follows the web's
  exact pipeline: authored glbRotX/Y/Z euler, auto-orient longest-axis-vertical,
  fit to authored height, recentre.
- **The part view IS the in-structure view** (default ON, = the web's
  `hwDetailMode`): the DISPLAY frame is solved with simple brackets/bolts
  hidden (`hideLegacyHardware`), a separate flags-ON solve feeds
  `LinkageHwPlacement` (brackets seat outer/inner joints; the `"center"`
  sub-type bolts seat hCenter at BOTH ring crossings and vCenter at the
  V-stack middle — 56 placements on the stock design), and EVERY detailed
  assembly is stamped at EVERY joint, `exclude_beams` everywhere since the
  real members are the beams. The editable stack sits on the active
  assembly's first seat; other assemblies get pick-body-stripped context
  builders. Traps: a seat must apply
  `LinkageStructureBuilder.ground_offset_for_frame` or hardware floats off
  the frame; a seat carries NO scale (parts bake the inch conversion); camera
  re-aims along the joint's radial FROM THE RING'S CENTRE (the solver builds
  module 0 AT the world origin, so the structure's middle is nowhere near it).
  ⚠ `LinkageHardwareSpacing`'s substituted-params cache is keyed on the FULL
  `to_config()` hash — it bakes every field, and a spacing-inputs-only key let
  the modal's flags-off display solve poison the flags-on placement solve
  (every placement silently vanished).
- **Three placement invariants, all of which RENDER when broken** — the port
  shipped with each of them wrong, and none produced an error, only hardware in
  the wrong place. Pinned by `_test_hw_placement_reference` against
  `core/linkage/testdata/hw_placement_ref.json`; verify visually with
  `--capture=hardware`, whose "anchor error" must read 0.000000.
  (1) **A detailed assembly anchors on `bracket["v_bolt_pivot"]`, NOT
  `bracket["pos"]`.** `pos` is the H-ring pivot where the SIMPLE bracket mesh is
  drawn; `v_bolt_pivot` is the V-stack corner the crossed uprights bolt through,
  a bracket-hole-distance away (solver.js:1987 hands `spec.vBoltPivot` to
  `hwAddAssemblyPlacement`). Reads as "right area, wrong relation to the beams".
  (2) **`compute_bracket_basis` takes a 5th `flip_stack_axis`**, mirroring the
  bolt+beam axes so an asymmetric stack sits on the correct side of the CROSSED
  V-beams. Rule in `LinkageHwPlacement.flip_stack_axis`; ~half of all joints
  flip. Simple brackets pass false, which is why `bracket["basis"]` and every
  value pinned against it are untouched by the parameter existing.
  (3) **hCentre's local +X is the RADIAL direction**, `+Y` the bolt axis
  (`computeHwHCenterBasis`). Yawing that 90° still yields a valid right-handed
  basis, so it renders fine while sending every `crossOffset` tangentially.
  In ARCH mode the port deliberately diverges: the web hardcodes world-up as the
  hCentre stack axis claiming "the H-ring bolt never tilts" (solver.js:2790),
  but the arch's 90° X-rotation makes that bolt horizontal and collapses every
  arch hCentre joint to one ±X yaw — so the port takes the axis from the bolt's
  own transformed direction. Identical in cylinder mode; those rows carry
  `skip_basis: "arch"` in the fixture.
  Also fixed alongside: the cap-upright bracket chord spans the H-ring heights
  (0..top_h), not the upright heights (y_min..y_max) — the web's bracket and
  bolt blocks genuinely differ there (solver.js:2134 vs :2103) and the port had
  copied the bolt block's into both, tilting every cap joint ~half a degree.
- **Editing UX invariants.** Typed offsets are NOT snapped (a drag still is —
  Ctrl suppresses it): the snap-plane list always contains the layout origin, so
  at a 0.18" threshold a typed 0.05 was unconditionally reverted to 0 while the
  field went on showing 0.05, which is the whole of "changing the offsets does
  nothing". Every write echoes the STORED value back via `_sync_field`.
  `axis_pos_from_part` returns the part's axial CENTRE and
  `pos_assembled_for_axis_pos` is its exact inverse (round-trip pinned over
  offset × explode × copy_index × flip) — the drag is that inverse, so a
  half-part disagreement makes every grabbed part jump. Edits are classified by
  `LinkageHardware.edit_requires_respacing`: only sandwich standoffs, centre-slot
  spans and the outer bracket's dims can move the STRUCTURE, so only those pay a
  re-solve (debounced 150 ms, forced on mouse-up); everything else is a
  transform-only `set_part_offset`. Before this, every mouse-motion event ran
  `set_params` + `set_fold_angle` + a full `LinkageSolver.solve`.
  `set_explode`/`set_part_offset` call `sync_instances()` — `set_instances`
  DUPLICATES the stack, so without it the context joints stayed frozen at the
  pose they were cloned at. ⚠ **A clone's `transform` is LOCAL and the builder
  it hangs under is ALREADY seated on placement 0**, so `set_instances` divides
  that seat out (`inv * seat_transform(...)`); assigning the absolute seat
  composes the two and puts joint i at `seat0 * seat_i`. The tell is specific
  and misleading — joint 0 IS the builder node rather than a clone, so the
  FOCUSED joint looks perfect while every other joint on the frame scatters.
  Pinned by the "every context joint lands on its own seat" check (verified to
  fail 15/15 when the inverse is removed). Clones also get
  `material_override = null`: `duplicate()` copies the selection highlight, so
  whichever part was selected when they were minted lit up at every joint.
  **The BRACKET is draggable** — it is not on a stack, so it drives its own
  `posX`/`posY` nudge (Shift for Y) through `refresh_bracket`, which is the same
  field the inspector edits. It used to refuse in silence, and since it is the
  biggest thing on screen it is the part a player grabs first, which reads as
  "dragging doesn't work" rather than "not this one". Declines now say why
  (`_flash_hint`). Verify with `--capture=hardware`, which drives REAL
  InputEvents through the viewport — including via the Lab entry point, since
  opening the editor standalone does not test whether the Lab's own full-rect
  Control swallows the pointer first — and prints DRAG OK/FAIL with the inches
  moved. The part view ghosts the surrounding timber
  (`LinkageStructureBuilder.set_ghost_alpha`, X-ray toggle) because a joint sits
  INSIDE the members it clamps; ghost materials are DUPLICATES, since the
  originals are shared with every structure in the game.
- **The crew plan reads the BOM.** `NpcCrewPlan.linkage_fab_tasks` takes
  optional `bom_bolt_count` (replacing its `modules * 6` estimate) and
  `assembly_steps` (splitting one flat "assemble" task into one per joint, at
  `T_HW_PART_S` per piece). Omit both and the emitted graph is byte-identical
  to before — a frozen literal in the selftest guards that, because
  `npc_population_selftest` and `packing_selftest` both pin schedules over it.

**Deferred:** kinematic RCP continuation solver; PDF export (GDScript has no
jsPDF equivalent — the guide exports CSV and JSON and says so in a footnote).

## Packing data model (core/packing/ — PACKING_PLAN.md, Phase 0 landed)

Every physical thing gets a **packed ("shipping") spec** — dims (m, displayed
ft/in), first-class `mass_kg` (-1.0 = unknown; NAN doesn't survive JSON), form,
stackable/this_side_up flags, `count`, `contains` (Phase 3 nesting), `source:
curated|computed|estimated`. `PackedSpec` (core/packing/packed_spec.gd, pure
static) is the ONE resolver: curated (`packed` dict on a catalog entry/preset
specs, else `CURATED_MODELS`) > computed (procedural builders) > estimated
(type heuristics with cited constants — W/kg panels, Wh/kg by chemistry,
kg/L HDPE tanks, wood/steel densities). Unless `this_side_up`, dims
canonicalize w≥d≥h. **Coverage guard:** every structures/tools catalog model
must appear in CURATED_MODELS / DYNAMIC_MODELS / NON_PACKABLE or the selftest
fails — adding a model forces a packing decision. **LinkageLab computes its
own** (`LinkageStructureBuilder.packed_spec_for`): solved at the EFFECTIVE min
fold angle (`LinkageKinematics.effective_min_fold_angle` — user override else
V-beam contact), never the live slider angle, so an impossible over-fold can't
fake smaller shipping dims; structure only (beams+brackets+bolts+supports),
panels deliberately excluded (they pack as their own stack — Phase 3 split);
cached on the instance keyed on params-minus-foldAngle because the modal's
stats refresh runs per fold tick. The modal's fold-slider FLOOR now tracks
`min_fold_angle()` (was hardcoded 5° — brackets/outer V-beams could be dragged
through each other), with the Min Fold Angle Override spin as the escape
hatch; "Packed Size"/"Packed Wt" stat rows show the result. The BETTER fix —
collision-aware min fold via OBB sweep over solved beams+brackets — is
planned, not built (PACKING_PLAN.md Phase 0.5). **Display:** library item
buttons carry a "Packs to" tooltip; the inspector adds a generic "Packed
(shipping)" section after the per-type match (`_build_packed_section` —
short ft/in form via `format_dims_short`, the narrow value column clips the
metric-parens string; compounds fall back to their `model_id`'s entry so
StarShade super-nodes resolve); the prop-edit drawer shows a 📦 line, with
linkage props computing from the record's live `linkage_spec`. **Phase 1
containers:** `ContainerCatalog` (core/packing/container_catalog.gd, pure
data) holds 16 real target volumes — U-Haul fleet (published interior/door/
payload specs), 5x8/6x12 trailers, ISO 668 20'/40'/40HC, and nestable subs
(GMA pallet, 27-gal tote, action packer, job box, 55-gal drum) — each with
interior dims + DOOR APERTURE (`fits_through_door`: 90° orientations only,
no diagonal tilt; open-top = always passes) + payload; droppable containers
also carry exterior+tare (`packed_spec_for`, `this_side_up` so normalize()
can't lay a container on its side). `CargoContainerBuilder` (procedural
ModelCatalog id `cargo_container`, `container_spec.container_id` picks the
box, default 20') emits ONE MeshInstance3D "Mesh" (PalletRack pattern —
PlacedProp collision/pick just works); dims come FROM the catalog so
geometry and packing data can't drift. Gotcha burned once already: Godot
front faces wind CLOCKWISE from outside — CCW-wound boxes render as culled
backfaces and the whole prop reads as an unlit silhouette. **Phase 2
solver + report:** `PackSolver` (core/packing/pack_solver.gd, pure static,
deterministic) is a greedy extreme-point largest-first heuristic —
deliberately NOT optimal; ~70-85% fill matches a careful human crew, which
is the honest number for a "will it fit" report. Honours container bounds,
overlap, gravity support (floor or ≥50% footprint on a STACKABLE top —
non-stackable tops support nothing), this_side_up (2 yaw orientations vs
all 6), the door aperture, and payload (reported via `payload_ok`, not
blocking — an overweight load still physically packs); also returns
mass-weighted CoM + `com_len_frac` for tongue-weight checks. Test-writing
trap: largest-first placement legally rearranges around a contrived
scenario — unit-test `_supported`/constraint internals directly instead of
trying to force an arrangement through solve(). `CampManifest`
(core/packing/camp_manifest.gd): PURE collectors (`from_graph_items` over
`GraphNesting.walk_items` output — skips virtual/compound/abstract and
resource tanks >20,000 L = site infrastructure, nobody U-Hauls a pond;
`from_prop_records` over `TerrainLoader.placed_prop_records()` — linkage
props compute their honest folded envelope, containers resolve their
variant), qty merge, solver expansion, and `fleet_report` (smallest-first
shortlist). Surfaced as the Site Report "📦 Packing & Logistics" card
(site_report_panel `_refresh_packing_card` — computed LIVE at populate
time, deliberately OUTSIDE the cached report pipeline so graph edits never
serve a stale verdict). **Phase 3 nesting:** `PackTree`
(core/packing/pack_tree.gd) solves boxes-within-boxes INNERMOST-FIRST —
a container unit's contents solve into its ContainerCatalog interior and
the parent scope sees one leaf at the exterior dims with tare+contents
mass; contents that don't fit a sub-container ESCAPE loose into the parent
scope ("(loose from <tote>)") rather than failing the load; qty>1
container units are identical instances (contents solved once, outer units
replicated); MAX_DEPTH 8. `PackDefs` (core/packing/pack_defs.gd) holds
reusable kits as UNIT LISTS — a def is a list, not one root box, because
real kits split across handling units (the StarShade 18-panel stack
physically cannot share the 2' crate with the folded frame; forcing one
root just makes panels escape on every solve). Builtins `starshade_kit`
(crate + strapped panel stack, mirrors the graph's 3-level StarShade
component tree) and `solar_starter_kit`; `{def_ref: id}` splices another
def's units with a visited-set cycle guard; user defs in
user://pack_defs.json (selftest snapshots+restores that file). **Phase 4
Packing Lab (`scenes/ui/packing_lab_modal.gd`, no class_name — ui_compile
sweeps it):** interactive 3D packing modal (own CanvasLayer at
UITheme.LAYER_MODAL, CursorController modal contract) — SubViewport studio
with a cutaway container (camera-facing walls hide themselves per orbit
frame; amber door marker at the HIGH-z end because the solver fills from
z=0, so auto-packs read as loaded nose-first — the order LIFO unpack
warnings will lean on), Auto-pack seeds from PackSolver, manual placement
ghost (ItemList pick → aim → R rotate via _unhandled_key_input so focus
doesn't matter → LMB place; click a placed box to take it back out —
placement/removal are each other's undo). Hand-placement validity calls
THE SOLVER'S OWN `_overlaps_any`/`_supported`/`_orientations`, so the
modal can never teach a packing the report would reject. Sidebar: container
picker (whole catalog incl. sub-containers), kit loader (PackDefs), live
stats (fill %, load vs payload, CoM % toward rear + trailer tail-heavy
warning), door-blocked items tinted red in the list. Opened from the Site
Report packing card ("Open Packing Lab…", preselects the smallest fitting
vehicle) or `--capture=packing`. v1 deferrals: per-site layout persistence,
tote drill-in, LIFO warnings (need deploy-priority data). **Phase 5
PACKED⇄DEPLOYED:** a prop record with `packed: true` builds
`PackedFormBuilder` (core/packing/packed_form_builder.gd — form-styled
crate/bundle/panel_stack/pallet/tank/folded silhouette from the record's
resolved PackedSpec via `PlacedPropRuntime.packed_spec_for_record`, Godot
PRIMITIVE meshes so no winding traps) instead of the model: yaw-only
USER-scale transform (the catalog's GLB unit-compensation `resolved_scale`
must NOT touch a real-metre crate), NO behavior runtimes (trackers animate
geometry that doesn't exist) and NO connection ports. Interact on a crate
unpacks in place (interaction_focus checks the prop's `packed` meta FIRST —
a deployed prop's Interact is already owned by linkage fold/StarShade edit,
so packing must never hijack it; repack lives in the edit drawer's
"📦 Pack up" button, hidden for non-packables). `TerrainLoader.
set_prop_packed(id, bool)` persists + rebuilds + keeps linkage graph
arrays honest via set_imported_array_stowed (unpack restores fold-state
truth). The packed-generation gate: `specs.packed_3d`
(`SystemGraphView.set_item_packed_3d`, called by set_prop_packed for any
prop bound via graph_item_id) zeroes the renewables tick (wind/hydro), the
CSP/heliostat ticks (empty result dict → every telemetry key defaults 0),
and refuses `ResourceFlowEngine._processor_switched_on` — ONE guard there
covers every processor path. Still ungated: individual panel items,
battery/controller electrical presence. **Phase 6 delivery scenarios**
(`core/packing/unpack_scenario.gd`): spawn = REAL prop records (container +
`packed: true` crates staged off the door end) so the Phase 5 loop IS the
gameplay and `progress()` just counts records; builtins `starter_camp` /
`starshade_kit` (linkage crate carries a real default v30 design); Packing
Lab "🚚 Deliver kit to site" button (14 m ahead, door toward player;
disabled without a TerrainLoader) / loader `deliver_packed_kit`.
**Emergent group-labor groundwork** (`core/population/npc_haul.gd`,
`NpcHaulModel`, pure static): round-trip vs bucket-brigade throughput from
first principles; `best_plan` picks the winner — the strategy FLIP with
crew density and the saturated brigade's route-length independence
(throughput → 1/t_handoff) are pinned as selftest properties, surfaced in
the Lab's delivery crew readout, and bridged to the chore board via
`chore_spec`. **Pit-crew scheduler** (`core/population/npc_crew_plan.gd`,
`NpcCrewPlan`, pure static): compound-task graphs ({work_s person-seconds,
min_workers = barn-raising threshold, max_workers, deps}) scheduled by
event-driven critical-path-first list scheduling with malleable
reallocation at every completion event. Selftest pins the classic
emergent facts: makespan ≥ max(critical path, total/N), more hands never
hurt, flatline at the critical path once parallelism exhausts, min-crew
gates block AT the blocking task (blocked_id). `linkage_fab_tasks` builds
the swarm-manufacturing DAG from a design's REAL solver part counts
(cut → drill → assemble ∥ brackets → bolt → fold-test → raise min-6 →
panels). Bolts come from `LinkageBom.fab_counts` when a bill of materials
is available; the `modules * 6` estimate survives only as the fallback for
hand-authored counts (the solver emits bolt GEOMETRY only when show_bolts
is on, but the hardware exists regardless). With `assembly_steps` present
the flat "assemble" task splits into one per hardware assembly, priced at
`T_HW_PART_S` per piece — the payoff of porting the hardware editor.
`recommend_crew` = "bring 9, not 40";
`timeline_text` = ASCII Gantt for build docs; `chore_specs` bridges a
schedule onto NpcChoreBoard (depends_on/min_workers carried as groundwork
for a dependency-aware board). Surfaced LIVE in the Linkage Lab stats
block ("🔧 Fabrication …", cached on part counts — recommend_crew sweeps
crew sizes, not per fold tick). Full vision: PACKING_PLAN.md Phase 6.5.
**Deliveries stow INSIDE the container (Round 3).**
`UnpackScenario.stow_plan(scenario_id)` resolves each unit to a PackedSpec
(`LinkageStructureBuilder.packed_spec_for` for `linkage_default`, else
`PackedSpec.for_model`), **forces `this_side_up` on every item** — the solver
otherwise returns all six axis permutations, but a spawned crate is a BoxMesh
with yaw and nothing else, so only `(w,h,d)` and `(d,h,w)` are renderable —
and runs `PackSolver.solve`. `spawn()` maps each placement into world space
(solver `x` = interior width → container-local +X = world `side`; `z` = load
length with the DOOR at high z → world `fwd`) and sets **`y_offset = pos.y`
exactly**: `PackedFormBuilder` puts a crate's origin at its own floor and the
container's floor is local Y=0, so no deck fudge. Stowed crates carry
`stowed_in` + `unload_rank` + `collision_enabled: false`; anything the solver
cannot fit falls back to the pre-v3 door stack so an oversized unit degrades
visibly. `crate_ids` is returned in **LIFO order** (highest top first, then
nearest the door), so every consumer inherits it — the brigade's stage-effect
index IS its order, and round-trip rows take an ascending priority from the
same sort. Two rules keep it honest: **`move_prop` always clears `stowed_in`
and puts `y_offset` back to 0** (moving a crate is what un-stows it, whether a
chore effect or a player drag), and **`set_prop_packed` refuses to unpack a
stowed crate** ("unload the delivery first") — you cannot erect a shiftpod
inside a shipping container. Note `PlacedPropLayer.update_prop` treats a
`null` patch value as an ERASE: readers do `str(rec.get(k, "")).is_empty()`,
and a stored null reads back as `"<null>"`, so a stale `stowed_in` silently
blocked an erect-phase deploy until this was fixed. The container mesh is a
solid box with no cavity, so the stack is invisible in-world — the Packing
Lab (`--capture=packing`) is its visual surface.
Selftest: `core/packing/packing_selftest.gd` (511 checks; --import first).

## NPC population simulation (core/population/)

Individual simulated people (10–50) driven by needs, wayfinding to
player-tagged spaces; consumption emerges from activity and flows through the
graph, and morale decides whether the community holds together. Design doc:
`POPULATION_PLAN.md`. **Tagging:** `SpaceTypes`
(restroom/kitchen/sleep/water_point/shower + enrichment types fire_circle/
movement/quiet/workshop_social, with `COLORS`/`ICONS` for markers) +
`SpaceRegistry` (per-map `user://maps/npc_spaces_*.json`; targets = prop id /
`building_tag` / area polygon [v2-reserved]; runtime occupancy never
persisted). Tag via the prop edit drawer ("Space:" OptionButton + capacity) or
Building Builder's "NPC space" row — registry only, NEVER BuildingStyleLayer
(styling de-merges the building). `TerrainLoader.npc_spaces` owns it on
generated maps; `NpcPopulationBridge` falls back to a scene-keyed registry on
built-in maps. **Agents:** `NpcAgent` (pure RefCounted FSM
IDLE→TRAVELING→DOING; needs 0..1 rise per sim-hour, activity table with
consumption rates calibrated to the habitat preset's ~50 L water + 1.5 kg
food/person/day; per-agent RNG reseeded per sim-day → deterministic).
`step()` returns **time-averaged rates** (rate × fraction of the step spent
doing) so integrating them over dt bills exact mass at any time scale.
Needs are hunger/thirst/bladder/sleep/**hygiene**/**enrichment** (shower ~12 L
→ ~60 L water/person/day total). **Priority ladder** (`_pick` = tiers 1-2,
`_step_idle` = 3-4): critical need → comfort (hygiene) → chore → enrichment.
Two livelocks to never reintroduce: comparing raw need levels ACROSS tiers
(hygiene pinned at 1.0 out-scores thirst at 0.99 → shower/interrupt loop), and
letting a non-critical need interrupt (`_most_urgent` iterates CRITICAL_NEEDS
only; `NON_INTERRUPTING` = sleep/hygiene/enrichment). Backoff after a failed
attempt is **per-tier** (`retry_at` dict) — a single scalar let a failed
enrichment attempt stop someone re-evaluating whether they were thirsty.
Agents carry a deterministic `display_name` (`NpcAgent.name_for`) +
`status_line()`.

**Morale ("Fuck Yes"→"Fuck This")** — `NpcMorale` (pure static): 6 bands;
pressure from unmet CRITICAL needs is superlinear past `PAIN_THRESHOLD` 0.75
and **2× when the need is BLOCKED** (no tagged space / starved supply) —
broken infrastructure is what breaks a community, not busy people. Needs alone
cap at `BASELINE_CEILING` 0.75; `ceiling(enrichment_need)` lifts it to 1.0 only
through gathering. Recovery (0.035/h) is far slower than loss. **Departure:**
quit pressure accrues below 0.12 and decays on rescue; at `QUIT_PRESSURE_H` the
agent leaves → `agent_departed` → roster + labour shrink, plus a
`DEPARTURE_SHOCK` contagion hit to everyone else → `collapse_warning` at risk
0.5 → `colony_collapsed` below 35% of the starting roster (a story beat, NOT a
game over). `occupants` stays the AUTHORED headcount (editing it rebuilds the
roster); live counts surface as `specs.pop_present`/`pop_morale`/
`pop_collapse_risk`.

**Chores** — `NpcChoreBoard` (per engine, rides `pop_state`): label, target,
`chore_hours`, daily window (may wrap midnight), repeat, exposure class,
priority, assignment. Progress is credited in EFFECTIVE hours = dt ×
`NpcMorale.productivity(morale)` (0.55–1.15) × `NpcWeatherGate.productivity` —
low morale slows the work that would raise it. Credit clamps to what's left
(mass-exact) and feeds the existing `chore_hours` ledger. UI:
`scenes/ui/npc_routines_panel.gd` (inspector **Routines & chores…**) — roster
with morale bands, chore board, and a 24 h **day-plan strip** per person
(sleep/needs/chores/free, red overflow) so over-scheduling is visible.

**Weather** — `NpcWeatherGate` (static, sources cited: ISO 7243 WBGT, Beaufort,
met rain classes): per-driver severity MULTIPLIES (a hot windy rainy day is
brutal, not merely additive), floored at 0.15; `is_unsafe` skips the chore
entirely (work backs up); exposure also drains morale. Indoor work is immune;
sheltered gets `SHELTER_RELIEF`. Weather is sampled per tick from
`WeatherService` and degrades to "comfortable" when uncovered/offline.
**Navigation** (`NpcNavGrid` + `NpcNavQuery`, POPULATION_PLAN.md Tier 3):
person-scale walkable grid (0.75 m cells) over the bounding box of the tagged
spaces + habitat, padded — not the whole SoI. The bake is **chunked across
ticks** (`bake_step`); `ConduitAStar`'s header records that per-cell ground
fetches caused GPU TDR, so nothing samples terrain inline. Until `is_ready()`
agents walk straight lines, and a declined plan always falls back to that.
**Slope vs steps is the load-bearing distinction**: cell slope is a central
difference over ±2 cells (3 m — a single 1.2 m step reads 22°, walkable; a
cliff reads 80°+, blocked), while per-move `STEP_UP_M` 1.2 / `STEP_DOWN_M` 2.5
are enforced at *connection* time in the A*. Measuring slope between adjacent
cells instead would read a step as 58° and strand people at the bottom of it.
A* is hand-rolled over the packed arrays (not `AStar3D`: 71k points would cost
~350k binding calls on every re-bake, and the grid re-bakes when a prop
moves). Smoothing is **cost-aware string-pulling** — a shortcut is only taken
when it is no dearer than the run it replaces, or straightening would undo the
climb avoidance the search just paid for and send everyone over the hill.
Routes between tagged spaces are cached per (from,to) pair and offset per
agent by ±0.4 m *only in open ground*, which gives desire lines their width;
in a doorway the jitter declines, and any jittered polyline that fails a
segment check reverts. `STEP_EPS` exists because heights are float32, so a
step authored at exactly 1.2 m reads back as 1.20000004768 and would be
refused by a rounding error.
**Buildings** (`NpcBuildingNav`): walls become a 0.6 m blocked band, interiors
stay walkable, and doors punch openings — so people path INTO and THROUGH
buildings. Player-placed door `elements` resolve via the NORMALIZED ring from
`BuildingBuilder.resolve_building_params` (open, CCW — the only form `edge`
indices mean anything in). The **auto-door heuristic is load-bearing, not a
nicety**: almost every OSM building has no door data, so one is punched at the
edge midpoint facing the nearest road (else the site centre), derived
deterministically from the footprint. Buildings tagged as an NPC space are
forced enterable whatever their size; sheds under 9 m² stay solid.
**Upper levels**: `surfaces_fn` probes downward rays for decks/floors, but ONLY
in `F_STRUCTURE` cells, and the layer pass budgets *probes* rather than cells
scanned. Nothing in the project generates walkable upper floors yet — the
mechanism exists so stairs/ramps connect automatically when content does (an
inter-layer link is just a move whose height delta passes the step limit).
**Walking cost** (`NpcMetabolism`, Tier 3d): per-agent daily `distance_m` /
`climb_m` / `walk_kcal` with per-need trip attribution, rolled at the sim-day
boundary (yesterday kept in `prev_day`). Model is the **ACSM walking
equation** (cited; ~51 kcal/km at 70 kg, pinned in the selftest); grade is
clamped at zero downhill because the equation has no valid negative term.
Aggregates surface as `walk_overhead` (share of a 2000 kcal day) plus an
`efficiency_label` Compact→Punishing, and mean metres per trip SPLIT BY NEED —
the diagnostic that says *which* space is misplaced. Climb reads the baked nav
grid, never a terrain query (hot path). Note the arrival branch must account
for its final leg: a trip that finishes inside one step never calls `_walk`,
and at high time scale that is every trip, which would zero the whole metric.
**Desire lines** (`NpcDesireMap`, Tier 3e): metres walked rasterised into a
2 m heat grid with per-need channels, log-scaled (foot traffic is heavy-
tailed) and drawn as ONE `draw_texture_rect` under the Site Plan overlays;
per-agent fading trails on top. Retention is Today / Past week / All time,
rolled at the sim-day boundary. **Build the ImageTexture on the TICK, never
inside `_draw()`** — allocating a GPU resource mid-draw yields undefined
contents (it rendered as a solid white block over the whole site). Toggles
live in **View options ▾** at ids ≥152 (151 is already double-booked by
`VIEW_MODE_EMBODY_TWINS` and `VIEW_MODE_SITE_PORTS`).
3D drape (`NpcDesireOverlay` + `npc_desire_drape.gdshader`): one
terrain-following mesh over the map's rect with world-XZ UVs baked into the
vertices — the mesh IS the registration, so there is no bbox uniform to keep
in sync. Additive, unshaded, no depth write; built lazily on first enable and
freed on disable. Grid-tessellated rather than reusing
`build_polygon_highlight`, which samples only a polygon's corners and floats
over rolling ground.
**Coarse catch-up models COPING, not neglect.** A >6 h jump is the player
scrubbing or a frame hitch — time the community lived through but the sim did
not simulate. Needs land at ordinary mid-cycle levels, morale drifts at most
`CATCHUP_MORALE_DRIFT`, and quit pressure only DECAYS. Integrating the whole
gap as deprivation emptied a healthy camp (morale 0.75, nothing blocked) in a
single 12.8 h tick. Crucially, a need whose supply is currently STARVED is
exempt and keeps rising — otherwise a jump silently feeds a camp whose food
tank is empty.
**On scenes with no TerrainLoader the nav grid uses a FLAT height source**:
`TerrainSurfaceQuery.ground_height_at` falls back to a raycast that returns
0.0 on a MISS, so every hole in collision coverage would read as a cliff and
island the grid (this was causing real path failures on the soak map). **Engine/coupling:** `NpcPopulationEngine`
(roster, substepped tick, scrub-back = freeze, >6 h forward jump = coarse
catch-up, snapshot/restore) is ticked by `NpcPopulationBridge` from
`system_graph_view._tick_resource_flow_ambient` BEFORE the flow tick (works
with the graph closed). It writes aggregate demand into
`ResourceFlowEngine.set_habitat_demand(item_id, rates)`; `_process_habitat`
uses that override instead of `rate × occupants` when present (waste caps
bypassed pop-driven — bursty rates would clip mass), and last tick's
`specs.starved_kinds` feeds back so blocked activities abort and the need
pins at 1.0. Enable per habitat: inspector **Population Simulation** →
`specs.pop_driven` (occupants = roster size; closure metrics unchanged).
Persistence: change-gated `specs.pop_state` snapshot (≤2×/sim-hour) rides the
normal graph save; `pop_state` is in both INSTANCE_ONLY_SPEC_KEYS strip
lists. **Daily routines (`core/population/npc_routine.gd`).** People follow a schedule
of blocks that tile 24 h and may wrap midnight; `NpcAgent._step_idle` consults
it at tier 2.5 (needs still outrank it, and the routine is what they return
to). This exists because a purely need-driven model has a visible failure: a
finished activity left the agent IDLE where it stood, and nearest-space
selection then kept picking the same place, so everyone pooled at the
restrooms. Activities are clamped to the end of the block that asked for them,
or a "5-minute" visit is only 5 minutes if the schedule can reclaim the
person. Per-agent phase offsets (`offset_for`) come from an AVALANCHED hash —
Godot's string hash over `hab_npc_0..23` is nearly sequential, and `% 1001`
put 24 people in 4 buckets, still lockstep. Bathroom = 3 scheduled visits x 5
min x one 6 L flush (18 L/person/day, replacing ~40 L of threshold-driven
phantom flushes). **The schedule only holds because the bladder was
recalibrated**: at rise 1/4 per hour + a 0.12 drink kick the need re-fired
every ~2.4 h and dragged people back (restroom share only fell 40%->23%);
1/12 with threshold 0.75 makes 3 visits sufficient and leaves the need as a
backstop for a MISSED visit. Editing lives in the Routines panel's **Daily
routine** tab, staged in a draft until Apply and persisted to
`specs.pop_routine` — deliberately NOT part of `pop_state`, so Reset
population keeps the authored day. Note a scheduled camp is materially more
resilient (morale starts ~0.81 vs 0.60), which is why the harness collapse
window had to widen 90->220 iterations.

**Area spaces (Tier 4b).** `target.kind == "area"` was always in the schema;
what it lacked was geometry and a way to create one. `SpaceEditUI`
(`scenes/ui/space_edit_ui.gd`, **Y**, wired in `terrain_loader._unhandled_input`
alongside the C camp dock — raw keycode, no new input action) draws a polygon
on the ground via `terrain_pick_ray`, closing on a click near the first corner
or RMB. Props and buildings are still tagged in place through `NpcSpaceTagRow`;
areas get a dock because there is no object to open. **Position resolution is
the subtle part**: `polygon_centroid` is a shoelace centroid, NOT a vertex
average (a vertex average drifts toward whichever edge is finely subdivided),
and for a concave outline — a courtyard wrapping a building — the centroid can
land OUTSIDE the polygon, so `area_interior_point` falls back to the bounded
grid sample furthest from any edge, which is both inside and the roomiest place
to stand. Site Plan draws the real outline plus the marker at that point
(`space_markers` carries `poly`), so a 40 m plaza no longer looks identical to a
single portaloo.

**Desertion is a dead end the sim cannot leave on its own.** Departures are
permanent, so a barren site eventually empties the roster COMPLETELY (past
`colony_collapsed`, which fires at 35% and still leaves people). At zero agents
`tick()` returns `{}` immediately: nothing moves, nothing is consumed, no
further events fire — the world just goes quiet, which reads as a bug.
`colony_deserted(cause)` is emitted separately from `colony_collapsed` for that
moment, the inspector replaces the whole Population readout with an EMPTY
banner + the dominant departure cause (`departure_cause()` tallies the
`_departures` log), and **Reset population**
(`SystemGraphView.npc_reset_population` → `NpcPopulationBridge.reset_population`)
rebuilds the roster. Reset MUST erase `specs.pop_state`, or the next
`_ensure_engine` restores the roster that just walked out. `_ensure_engine`
only rebuilds when the AUTHORED `occupants` count changes, so before this the
sole recovery was toggling `pop_driven` off and on — undiscoverable. Reset
deliberately does not fix the underlying cause; a fresh group walks out the
same way, which the selftest asserts.

**Personal space (Tier 4c) is cosmetic by contract.** Two mechanisms, because
the problems differ: **standing slots** for people who have ARRIVED (a Vogel
sunflower spiral, `r = PERSONAL_SPACE_M*sqrt(n)` at the golden angle, indexed
by position in `SpaceRegistry`'s occupancy array — claim order IS slot order,
so an arrangement is stable for a whole visit; nearest-neighbour spacing
settles at ~0.9 m for every n without looking like a lattice), and a
**separation pass** in `NpcPopulationEngine._separate` for everyone in transit.
Separation is O(n²) ON PURPOSE — the roster caps at 64, so it is ~2k pairs of
vector math, and a spatial hash would add bucket-ordering questions that the
determinism guarantee then has to answer. Pushes are biased 85% SIDEWAYS for
travelling agents (`PERP_BIAS`): shoving someone back down their own route
reads as barging and feeds back into arrival time. It is skipped above
`SEPARATION_MAX_DT_H` (agents teleport at high time scale, so nudging is noise
on noise), refuses any push onto unwalkable ground, and derives a deterministic
direction from the id pair when two agents are exactly coincident (which is
what a fresh roster is). **Displacement is deliberately NOT banked into the
walking/kcal ledger** — folding it in would make spatial-efficiency numbers
depend on crowd density. The selftest asserts consumption is unchanged to a
RELATIVE 0.1% rather than exactly: position feeds travel time feeds activity
scheduling, so a sideways nudge shifts what someone is mid-way through at the
measurement boundary (measured drift ~4 ppm over a simulated day).

**Selftest gotcha:** a Godot runtime error (assigning through a null
reference, say) PRINTS and execution continues, so `npc_population_selftest`
still reports PASS. A crash on every map load hid behind that for a whole
commit. Assert on OBSERVABLE state after construction (`NpcAvatar.has_body()`),
and when a change swaps a body/material out, grep the selftest output for
`base object of type '"Nil"'` rather than trusting the PASS line.

**Two body styles, one behaviour.** `NpcSimpleFigure`
(`core/population/npc_simple_figure.gd`) is an articulated stick figure — head,
torso, shoulder→upper-arm→ELBOW→forearm, hip→thigh→KNEE→shin, all capsules
under the silhouette shader — posed procedurally. It exists because the Mixamo
body is photoreal enough that any imperfection in how it is driven reads as
uncanny, while a stylised figure has no such contract and the same approximate
motion reads as deliberate. **It is posed from the SAME `NpcPoseMachine`** as
the rigged body, so behaviour cannot drift between styles: people walk the whole
route, lie down on arrival, sit for the bathroom, dance at the fire. Gait
cadence multiplies by the same playback rate, so it time-lapses identically.
Two details make it read as a body: the knee bends only on the RECOVERY leg
(the stance leg stays near-straight — the one asymmetry separating walking from
scissoring), and every pose is an eased TARGET rather than a jump, since this
body has no cross-fade to hide a cut. Style lives in `NpcDisplayPrefs`
(`user://npc_display.cfg`, global — a taste about the game, not a property of a
site), exposed as **Settings → NPCs → Body style**. Keep
`NpcDisplayPrefs.wants_simple()` (a CHOICE, survives installing the art)
distinct from `NpcRig.available()` (a missing-asset condition): both draw the
same figure, but only the second is worth warning about.

**Playback is time-scaled.** A gait is rate-matched to the body's APPARENT
speed — metres per REAL second measured off the rendered step, not the sim's
nominal 1.3 m/s, which is only correct at 1x. At 60x the body covers ground
60x faster and a gait pinned near 1x is exactly the skating that made speed-up
look wrong. Measuring the rendered step means smoothing, catch-up and time
scale are already in the number, with nothing to keep in sync. Other loops
(work, dance, exercise, clap) scale by `time_scale * 3600` so a chore at speed
reads as time-lapse. Capped at `MAX_PLAYBACK_RATE` 12x — past that it is a blur
either way. Rate refreshes EVERY FRAME, not on clip change, since apparent
speed varies continuously and the clock can change mid-stride. Consequence to
respect: the pose machine's one-shot timer must divide by the playback rate, or
a transition played at 6x is held five-sixths longer than the animation it
represents. Figures freeze entirely at `time_scale <= 0` (pause AND backward
scrub, where the population engine already freezes) — and because freezing is
`speed_scale = 0`, the INTENDED rate is stored separately or unpausing resumes
at zero forever.

**Animation is driven by `NpcPoseMachine`, a pure FSM** (`core/population/
npc_pose_machine.gd`; states IDLE/WALK_START/WALK/WALK_STOP/ENTER/POSE/EXIT).
It exists because clip choice used to be a function of `moving` and `activity`
only — and `NpcAgent` sets `activity` to the INTENT when travel begins, so
someone walking to bed reported `activity == "sleep"` for the whole trip and
played the lying-down clip while sliding. **The deeper bug was the `moving`
flag itself**: `_pose_avatar` compared THIS frame's sim position to LAST
frame's, but the sim advances every 0.25 s while the host poses every frame, so
it read true ~1 frame in 15 — false for exactly the window the body is gliding.
No epsilon fixes aliasing a stepped signal. `in_transit` now comes from
`dot["state"] == TRAVELING` (a LEVEL, immune to the sampling mismatch; it was
already in the payload and simply unread) OR'd with "the RENDERED body has not
arrived yet" (`gap > ARRIVE_EPS_M`, bounded by `ARRIVE_MAX_S` because the lerp
is asymptotic and never literally lands). Pure logic over an AnimationTree
**so the no-wedge guarantee can be fuzzed headless** — 200k steps with dt up to
0.5 s (far-LOD passes its accumulator as delta, so nothing may assume 60 Hz).
Getting OUT of a pose keys off `_current_pose`, NOT `_activity`: by the time an
abort runs `_activity` already holds the next intent, and looking the exit up
from it made waking skip the get-up entirely. **Clip roles are MEASURED, never
read off the filename** (`NpcRig.measure`/`classify`): "Idle To Situp" measured
as the LIE-DOWN (hips 0.940→0.123), giving sleep a real matched pair, and
Start/Stop Walking are told apart by which THIRD of the clip is faster — the
check a filename map cannot do. The loader refuses a clip whose measured role
contradicts `SOURCES`. Sitting down is `sit_exit` played BACKWARDS, so
`_apply_clip` keys on `(clip, direction)` — a clip-only guard makes
sit-down→stand-up a no-op and freezes the figure half-seated. Ground offset is
now a **phase curve** (`clip_ground_offset_at`) parameterised on the clip's own
hip descent, because one scalar is wrong at one end of a stand→lie clip;
verified continuous at the seams (sleep 9 mm, sit 29 mm). Transitions are
**budget-gated**: a 5-min bathroom visit is 0.67 REAL seconds at 450×, shorter
than one sit-down, so at speed everyone cuts straight to the pose. Harness
note: routines mean people travel at BLOCK BOUNDARIES, so the nav/pose window
anchors the clock at 08:85 and **restores it afterwards** — leaving it shifted
broke the later starvation phase.

**3D figures (`NpcRig` + `npc_silhouette.gdshader`):** `NpcAvatar` carries TWO
bodies behind one API — the rigged Mixamo character up close, the original
head/torso/legs primitive far away and whenever the FBX assets are missing
(`Imported Models/NPC/` is **gitignored**, so the fallback is the normal state
on a fresh clone; see ASSETS.md). `NpcPopulationHost` hands the rig to the
`MAX_RIGGED` (12) nearest agents within `RIG_DIST_M` (45 m), with hysteresis so
walking the boundary doesn't thrash the swap. Everything the Mixamo exporter
gets wrong for this use is corrected in `NpcRig` at load, and each correction is
**measured from the files, not hardcoded**, so a re-export keeps working:
every clip is named `mixamo_com` (renamed by role into one shared
`AnimationLibrary`); three clips carry root motion (horizontal hip translation
is flattened — vertical is kept, since for a squat that IS the animation);
nothing loops; the model faces **+Z** while the avatar's forward is −Z
(`model_yaw_offset` derives the half-turn from the direction the hips travel in
the walk clip); the walk clip covers 1.69 m/cycle at 1.64 m/s vs the sim's
1.3 m/s (`walk_speed_scale` rate-matches it or the feet skate). **Clips are
authored around their own origin, not the ground, and they disagree** —
"Laying Sleeping" puts the hips at 1.018 m, *higher* than a standing walk, so
an uncorrected figure lies down a metre in the air; `TARGET_HIPS_Y` expresses
the fix as a target height and `clip_ground_offset` derives the shift.
There is **no standing idle in the pack** (the character's bundled `Take 001`
is a static bind pose held 9 s — measured 0.0° of rotation), so the player
character's Breathing Idle is retargeted by rewriting `mixamorig_` →
`mixamorig1_`; Godot drops unbound tracks SILENTLY (a bad retarget looks like a
T-pose, not an error), so `_retarget_idle` verifies the bind ratio and rejects
the clip rather than trusting it. Shading is deliberately `unshaded` near-black
with a fresnel rim in the agent's pastel: a lit character reads as a *person*,
a flat dark mass reads as *someone*. Note a human is mostly limbs, and cylinders
show grazing angles across most of their visible surface, so a rim exponent
that edges a sphere floods a whole body — `rim_power` is 6.5 for that reason.
Skinned meshes cull against their REST AABB, so `extra_cull_margin` is set or
lying/arms-overhead figures pop out at the screen edge.

**Rendering:** Site Plan draws tagged spaces (`npc_spaces_provider` →
`_draw_npc_spaces_site`: disc + glyph + live occupancy sweep) UNDER the agent
dots (`npc_agents_provider` → `_draw_npc_agents_site`), redrawn only on
population ticks while visible; 3D = `NpcPopulationHost` (spawned by the view
while any engine runs, child of Main) posing `NpcAvatar` silhouette figures
(head/torso/legs, per-agent pastel, walk bob + leg swing, lies down asleep)
kinematically snapped to `TerrainSurfaceQuery.ground_height_at` — no
CharacterBody3D. **LOD:** cull >220 m, quarter-rate pose >90 m, ground height
cached until the agent moves 0.35 m or 0.5 s lapses (it was a terrain query
per avatar per frame). **Crosshair:** avatars join group `npc_avatars` and are
picked by a pure software ray-vs-sphere in
`interaction_focus._update_npc_focus` (deliberately NO collider — a moving
StaticBody would shove the player); Ctrl/Alt-aim shows "Name — status" and
that person's Label3D nametag. Selftest + the `--capture=population` harness
(which also asserts the crosshair contract + space-marker resolution) are in
the Validation list.

## Window wall (multi-monitor viewport — `core/windowwall/` + `scenes/windowwall/`)

The bus has three 27" 1080p monitors in a row on one wall, 4" bezel gap; the
Window Wall renders the world across them so they read as WINDOWS. Off by
default (Settings → Window Wall, `user://window_wall.cfg` via `WindowWallPrefs`,
own file on the `ExtremeWeatherPrefs` pattern); **F11** / `toggle_window_wall`
or the tab's button opens it; `--window-wall` opens it after load for a desktop
shortcut. Mode class `WindowWallView`, claim id `"window_wall"`, mirrors
`SettlementView` (modal via CursorController, camera through the claim stack,
idempotent `close()` on every exit path).

**One eye, one orientation, N off-axis frusta — physically correct, not
fanned.** `WindowWallLayout` (pure static) lays the panels out along the wall
(eye at the origin, wall at `z = -eye_distance_m`) and turns each rectangle
into `Camera3D.set_frustum(size, offset, near, far)` with
`keep_aspect = KEEP_WIDTH`: `size = w·near/d`, `offset = (cx, cy)·near/d`.
⚠ Under `KEEP_WIDTH` Godot's `size` is the near-plane WIDTH; with
`KEEP_HEIGHT` the engine multiplies it by the aspect first and it becomes the
HEIGHT — same call, silently different picture. The selftest inverts
`Projection.create_frustum_aspect(..., flip_fov=true)` (the exact call the
camera makes) to put the corner rays on the monitor corners AND pins that
`flip_fov=false` does not. Tilted panels rotate the camera basis to the
panel's normal and project in that frame (`slot_basis`); a panel the eye is
not in front of returns `{}` rather than a plausible-looking frustum.

**The game window IS one of the monitors.** Its root `Window` is moved
fullscreen onto the assigned OS screen and shows the main slot's camera via
`push_camera_claim` (no `shadow_max_distance` / `prop_cull_scale_m` — this is
eye-level tuning); every other slot is a native `Window` with
`own_world_3d = false`, `world_3d = root.world_3d`, borderless
`MODE_FULLSCREEN` (never exclusive: focus loss would minimise it), a
`Camera3D` child (which IS that window's camera), the root viewport's
`msaa_3d/use_taa/screen_space_aa/use_debanding/scaling_3d_*/shadow atlas`
copied over (main.gd applies those to the root viewport only), and an
`InputRelay` node. Spawned ONE PER FRAME (the AMD-TDR discipline from
`graph_soi_preview_service`). Facts measured by the Phase 0 spike, on this
machine: (1) `root.gui_embed_subwindows` CAN be flipped at runtime, and Godot
REFUSES (warning, value unchanged) while any embedded child window is visible
— every existing `Window.new()` popup in the project is embedded, so
`_set_embed(false)` hides visible ones first and a refusal aborts the open with
a toast rather than the project-wide setting flip (which would turn every
popup native); (2) screen/size/position may be set before or after
`add_child`, both land; (3) `w.get_texture().get_image()` works on a native
window; (4) `window_input` does NOT fire for `push_input` — only for OS
events — which is why each window carries a relay NODE whose `_input`
forwards to the view (harness-drivable AND responsive to real keys); (5) three
KEEP_WIDTH cameras put the horizon on the identical pixel row (539.5/1080).
Nudge keys are POLLED (`Input.is_physical_key_pressed`) so they work from
whichever window has focus; discrete keys go through `handle_window_event`
from both the main window's `_input` and the relays, and every key is marked
handled while the view is up (hidden panels still receive `_unhandled_input`
— the help overlay would un-hide itself on F1).

**⚠ Two measured ordering rules, both of which fail SILENTLY or CRASH.**
(1) **Closing from a relay must be DEFERRED.** Esc is delivered by the relay
INSIDE an extra window; the teardown frees that window, so a synchronous
`close()` destroys the caller and its viewport mid-stack — "Cannot call method
'get_viewport' on a previously freed instance". `request_close()` sets
`_closing`, stops consuming input and defers `close()` by one idle frame;
every input-reachable path (Esc/F11, `close_requested`, the CursorController
modal callable, Main's toggle) goes through it, while `close()` stays
synchronous for `_exit_tree` and the harness. The relay additionally captures
its viewport BEFORE calling in and re-validates after, so nothing touches
`self` past the call. Pinned by `--capture=windowwall`'s "Esc inside an extra
window closes the view".
(2) **`current_screen`/`position`/`size` go BEFORE `add_child`, and `mode`
in the SAME frame as it.** Applying `MODE_FULLSCREEN` a frame later is
silently ignored (measured on a 3-screen machine: `mode` reads back 0 and the
window sits 2 px short of the screen), and writing `size` to an
already-fullscreen window drops it back to windowed the same way. Only the
camera is re-asserted on the following frame. `_log_window_state()` prints one
line per slot on every open — screen wanted vs landed, size vs screen, mode,
camera, shared world, eye — because a grey window is indistinguishable from a
working one by eye, and the harness reads those lines back.

**A grey monitor is a PRESENTATION failure, not a rendering one.**
`w.get_texture().get_image()` can come back with a perfect frame while the
monitor shows flat grey: the render target and the swapchain are different
things, and a second fullscreen window whose monitor hangs off a different
graphics adapter may never present. Hence `extra_window_mode`
(`WindowWallPrefs.WINDOW_MODES`): "fullscreen" (default) or "borderless",
which leaves the extra windows windowed + `always_on_top` at exactly the
screen rect — visually identical, different presentation path. Exposed as
Settings → Window Wall → "Extra monitors".

**Clock: claim the scale, sync the date, never `set_live_mode`.** "live"
(default) and "1×" push a non-exclusive clock claim
`{"time_scale": 1/3600}` (composes with every other owner, base restored by
construction); "live" additionally calls
`SimSettingsController.sync_to_system_time()` on open and every 10 s while
our scale is still the effective one, and hands the date back on close unless
the player was already in live mode. `set_live_mode` is deliberately not used:
it persists a user preference and its disable path hard-writes
`time_scale = 1.0` (3600×). A refused claim (video export, a bake) toasts the
owner and carries on.

**Leave the world exactly as found.** `open()` snapshots the root window's
mode/screen/size/position, the embed flag, the root render scale, the player's
process mode and every Main CanvasLayer's `visible`; `close()` puts each back
— never blanket-true, several layers are hidden by design. Windows are
`free()`d (not queued) BEFORE the embed flag is restored, since the flip is
refused while a child window is displayed. ⚠ The extra windows take their
cameras with them: check `is_instance_valid` BEFORE `is Camera3D`, because
`is` on a freed instance is a runtime error that aborted the rest of the
restore (UI map, player mode, clock) while the harness still read
"closed PASS" — caught by `--capture=windowwall`'s restore assertions. The
hint strip lives UNDER THE VIEW NODE so the hide sweep never touches it.

**Viewpoint** (`WindowWallViewpoint`): a per-map ground point + yaw
(`user://maps/window_wall_viewpoint_<lat>_<lon>.json`, scene fallback by
basename, `CoordToken` keying like `SpaceRegistry`); pitch is always 0 (the
wall is vertical) and the eye is `seat_eye_height_m` above it, a global pref
so re-seating the chair does not touch every map. No file → the player's
current pose + a hint to Ctrl+S. Settings tab:
`scenes/ui/window_wall_settings_tab.gd` (own script, instantiated by
`timeline_settings_panel._build_window_wall_tab`; ⚠ a helper named `_set`
there collided with `Object._set` and failed the compile sweep).

## Settlement mode + the work substrate it exists to show

Plan: `~/.claude/plans/i-want-to-strengthen-groovy-pearl.md`. The second play
mode: shape the conditions, then watch the community work. **Never call it a
"god's eye" view** — in code or in game. The mode is `Settlement` /
`SettlementView`, claim id `"settlement"`, and the verbs are *shape, schedule,
watch*.

**The stall this arc exists to fix.** `NpcAgent._step_idle` used to `return`
unconditionally once `_pick()` named ANY need. `_pick` returns `"hygiene"` at
0.7 with no satisfiability check, so on a map with no shower tagged the agent
re-picked it forever and tiers 2.5/3/4 became unreachable — **every agent
locked between ~5 and ~13 sim-hours and never worked again.** Tier 1 absorbs by
design (`POPULATION_PLAN.md:248`); tier 2 inherited it by accident. Now only
`CRITICAL_NEEDS` absorb, and a blocked comfort need falls through to routine
and chores. It hid three ways: hygiene is not in `NpcMorale.CRITICAL_NEEDS` so
morale sat at 0.75 with no warning; `status_line()` reported `_worst_need()`
over ALL needs and so blamed enrichment; and **no test ran a chore to
completion** — every fixture tagged a shower, making the absorbing state
structurally unreachable. Companion fixes: `default_day()`'s evening block is
`FREE`, not `ENRICHMENT` (which is in `KIND_ACTIVITY` and can never reach a
chore) — ~10.9 chore-eligible h/day vs 6; a crew AT QUORUM yields only at
`URGENT` and solo work at `CHORE_PREEMPT_FLOOR` 0.80 (one thirsty person used
to zero six people's progress); and `_most_urgent` ranks by NORMALIZED EXCESS
among needs already past their own threshold (argmax-then-threshold let bladder
0.74 mask over-threshold hunger 0.60). Pinned by
`_test_chore_run_to_completion` (240 person-hours over 6 days on a site with
NO shower — verified to FAIL on the pre-fix code with `145.7 h left`).

**Consequences (`core/population/npc_consequence.gd`).** What running out of a
critical resource does is the PLAYER'S choice, authored per-habitat in
`specs["pop_consequence"]` via the Routines panel: `STRIKE` (default — today's
behaviour, named), `LEAVE` (routes through the ONE existing exit by setting
`quit_pressure = QUIT_PRESSURE_H`, so the cascade and its selftests are
untouched by construction) or `PERISH` (`agent_lost`, a NEW signal — challenge
code keys off collapse and must not read a death as a walk-out; no body, no
marker). Not in `NpcDisplayPrefs` (global cross-save taste) and not in
`GameplayRules` (an autoload, invisible under `--script`). ⚠ `PERISH` makes
`_process_departures` return early: morale rage-quit at ~24 h otherwise beats
the 72 h thirst window and nobody ever reaches the consequence they chose.

**The quiet alarm (`core/population/settlement_log.gd`).** A CAP-400 ring
buffer with **per-consumer cursors**, replacing the destructive `take_events()`
whose two consumers (toast drain / challenge-bake collapse detection) raced —
toasts vanished during a bake. Blocked needs are LATCHED (fire once after
`ALARM_H`, relief when the last clears): `blocked` flaps on every backoff and an
unlatched signal would strobe. Nothing beeps; nothing must be dismissed.

**`CameraClaims` (`core/camera_claims.gd`, + Main's impure half).** Mirrors
`ClockClaims`; stores `camera_id` as an int instance id to stay pure. Main owns
`push_camera_claim`/`pop_camera_claim`/`_apply_camera_claim`, resolves the top
claim, applies `hide_player_mesh` / `shadow_max_distance` / `prop_cull_scale_m`,
and **restores the player camera when the stack empties** — all restore
knowledge in one place. The six SubViewport modal previews and
`graph_soi_preview_service` are PERMANENTLY excluded (private composited
worlds, never claimants). Selftest: `core/camera_claims_selftest.gd`.

**The mode (`scenes/settlement/`).** A real full-screen `Camera3D` on Main, NOT
a SubViewport — the preview service carries AMD-TDR crop/clamp scar tissue and
a 60 m height cap, and rendering to the main viewport is what makes picking,
culling, shadows and TAA behave exactly as in first person. **One scalar `_h`**
(camera height) drives everything: pitch 0 → −80° interpolated on `log(_h)`,
**perspective throughout with no ortho toggle** (a projection switch is the
discontinuity that makes Site Plan picking fiddly), pan speed ∝ `_h`. Three
rules the file exists to hold, restated in its docstring: **the clock is NEVER
claimed** (`soi_snowglobe_camera.gd` freezes the sim — do not copy that line);
**no orders, ever** (selection is inspection + follow-cam; the levers are the
routine editor, chore board, priorities, space tagging and site rules); **it
borrows nothing from the 2D graph** (reading `agent_dots()` as DATA for the
inspector card is fine, drawing dots over people who are right there is not).
Overlays reuse the existing 3D ones; the only new one is `space_overlay.gd`
(tagged AREA spaces, triangulated with per-vertex ground sampling — 
`TerrainBuilder.build_polygon_highlight` takes a DEM grid + extent, not a height
callable, and this view must work on scenes with no TerrainLoader).
`pick_point_once(cb)` lends the view for ONE ground pick (the Routines panel's
"Where…" and the project panel's site picker) — ground only, so clicking a
person can never quietly become an order, and Esc always answers with
`Vector2.INF`.

**Picking (`gameplay/site_target_picker.gd`).** `resolve(main, origin, dir,
opts)` is the ONE crosshair ladder as a function of a ray, shared by the
first-person centre ray and the settlement mouse ray. The load-bearing line is
the **minimum angular pick radius** `r = max(PICK_RADIUS_M, t·tan(0.6°))` — at
500 m a person is sub-pixel and an exact sphere test is unclickable. Crossover
is ~52 m, so beyond that picking a NEIGHBOUR is correct behaviour, which is why
`--capture=settlement` only demands exact identity where the radius is under
4 m. Selftest carries an `EXPECTED_CHECKS` guard: a Godot runtime error aborts
the enclosing test function while PASS still prints, and instantiating a real
`NpcAvatar` in a bare SceneTree throws — the NPC rung is tested as pure
ray-vs-sphere maths for that reason.

**The labour merge.** `ChoreLedger` is now the **meter, not the supply**. A
`chore_hours` step without `require_confirm` stamps `recipe_waiting_kind =
"crew"`; `NpcPopulationBridge._service_machine_chores` mints an idempotent
chore keyed `mach|<gid>|<step_id>` whose `target` is the machine's
`bound_prop_id` (so people WALK there), and completion fires the new
`recipe_step_done` effect op through the post-tick sweep — the only place
completed work mutates the world, already fire-once. That calls the SAME
`RecipeRunner.confirm_chore` the player's button always did. ⚠ It must call
`ChoreLedger.record_worked`, not `try_debit`: finite labour means an empty
pool, an empty pool refuses the debit, and the step the crew just finished
would refuse to resume — the merge deadlocks by construction. A PACKED machine
mints an `unpack_prop` chore instead. `infinite_labor` is now the DIFFICULTY
switch, defaulting false **for new maps only** (`DEFAULT_INFINITE_FOR_NEW_MAPS`;
a loaded ledger keeps its own value, so no existing site silently stops
producing). `credit_available()` is deleted — it modelled a pool that stopped
existing. The contract is an EQUALITY, verified by `--capture=labour`.

**Facing (`core/population/npc_facing.gd`) — the "everyone works facing the
same way" fix.** `npc_population_host` used to write yaw ONLY while the body
was still moving (`if dir.length() > YAW_EPS_M`). `_step_traveling` sets
`pos = target_pos` on arrival, the rendered body converges, `dir` falls under
the threshold, and **the yaw latched on the approach heading for the whole work
session** — and since a non-brigade crew chore resolves to exactly ONE
coordinate, the whole crew walked one nav route to one point and froze on one
bearing. `_separate` then spread their POSITIONS by pushes capped at
`MAX_PUSH_M` 0.25, at or below the very threshold that would have re-triggered
the write, so the facings never followed. The fix is not a bigger epsilon:
`NpcAgent` latches a TRANSIENT `face_anchor` when it commits to a destination
(space centre before the slot offset / chore target / the relay's far end),
`agent_dots()` derives `face_yaw` from `(pos, face_anchor)` **every tick**, and
the host gates the travel branch on `in_transit` instead. Re-deriving per tick
is the whole mechanism — it is what finally lets the separation spread reach
the facings. Three subtleties: the anchor must be cleared in THREE places
(`_finish`, `release_claims` via `_finish`, and the engine's `_catch_up`); a
SOLO worker standing on their own anchor projects the arrival heading ~8 m
forward while a SHARED job keeps its anchor (`_chore_is_shared` — projecting
for a crew scatters the facings without aiming any of them, which looked
"fixed" while everyone faced out into a field); and the idle drift is bounded
in AMPLITUDE not rate, because beyond `FAR_DIST_M` the 0.25 s pose interval
turns the slew into a hard set. MP costs zero protocol churn — `_pack_frame`'s
`yaw` slot is meaningful only for possessed agents, a possessed agent never
runs the FSM planner, so the two are mutually exclusive and `flags` bit 0
already discriminates them. Pinned by `_test_crew_facing_spread` (circular
concentration R over a crew's facings, verified to FAIL on the pre-fix
behaviour with `R=1.000` and `7 of 7 within 20 deg of the walk-in bearing`),
its paired brigade opposite (`R > 0.9`, every station within 10° of the relay
line — so the rules are proven CONTEXT-AWARE rather than merely noisy), and
end to end by `--capture=population`'s facing-spread line.

**Task-aware work poses (`core/population/npc_work_pose.gd`).** A chore record
has no `kind` field and does not need one — the work is named by what it DOES:
`haul.strategy`, `carry_to`, a `chore_key` prefixed `mach|`, and above all
`effect.op` plus `effect.phase` (which carries the Linkage Lab's real
fabrication phase names). Deliberately NOT the free-text `label`, and not
`SiteProject.kind` (bridge-side, unreachable from a pure classifier).
`family_for` is TOTAL and returns one of seven families chosen to differ in
SILHOUETTE at ~60 m: `haul_hold` / `lift` / `dig` / `overhead` / `drill` /
`bench` / `inspect`. Rule 1 subsumes the pose machine's old `carrying` special
case. Plumbing: classified in `agent_dots()` (where the board is in hand),
rides the dot as `work_pose`, forwarded by the host, read by the machine as an
**INPUT** — which is what keeps the machine's purity contract. The families are
LOGICAL clips that `_clip_file_for` aliases onto `NpcRig.CLIP_WORK`, so the
rigged Mixamo body plays its single work clip unchanged while
`NpcSimpleFigure` (which already matched the logical name first, for carry)
draws the real family. That asymmetry is permanent until somebody authors more
Mixamo clips. ⚠ `merge_catalog` must be applied at `NpcAvatar.setup`, NOT
inside `NpcRig.catalog()` — that function answers "what art is installed" and
has other callers; without the merge every `_has()` guard skips the families
and their transitions on a fresh clone, silently, on exactly the body they were
written for. (The same condition means `sleep_enter`/`sit_enter` do not play on
a fresh clone either — a real gap, deliberately not widened here.) Per-agent
flavour (mirror / amplitude / stance / tempo / lean / variant) is cached in
`NpcSimpleFigure.setup()`; ⚠ **tempo scales each pose's own frequency constant,
never `_phase`'s advance**, which is what rate-matches the walk to apparent
speed. `work_enter`/`work_exit` are the one new transition pair — the exit is
the one that pays, since a worker used to snap out of a deep stoop into a
stride.

**`NpcHash` (`core/population/npc_hash.gd`).** One avalanche hash for every
per-agent scatter, lifted BIT-IDENTICALLY from `NpcRoutine.offset_for` (pinned
against a frozen literal, because routine offsets move every downstream sim
golden). Measured over 64 sequential ids in 8 bins: the naive `hash() % n` form
leaves FIVE BINS EMPTY with 30 of 64 in one; the avalanche fills every bin.
Two deliberate non-adopters: `NpcAgent.name_for` (snapshot only persists
`display_name` when it differs, so changing it would rename every unnamed
person in every save) and `color_for_agent` (already avalanched).

**Authoring depth.** The Routines panel exposes `priority` as three named bands
(never a raw int — it is uncapped and LOWER sorts first), one crew-size pair,
`repeat`, and the highest-value control, `target` via "Where…". Without a
target a hand-authored chore has no position and the worker does it where they
stand, which reads as broken. `depends_on`/`haul`/`effect`/`stage_effects`/
`carry_to` stay unexposed: that is the project compiler's vocabulary. The Site
Project panel gained a one-task "New project…" row (same reason — the
generators split into phases because they KNOW what the phases are) and a
per-project **Watch** button that opens the settlement view over that site.
`space_edit_ui.set_ray_source(Callable)` is the seam that lets the mode drive
the same polygon state machine rather than growing a second drawing UI.

**The work dock (`scenes/settlement/work_dock.gd`).** The chore board, inside
the settlement view, because editing the work and watching the work used to be
mutually exclusive — the board lived in a full-screen modal over the 2D graph,
so "retune a priority, see the crew re-form" meant closing the only surface
that shows the crew. It carries the queue in WORK order with live crew
fractions and exactly three knobs, all of which change a CONDITION: priority
band, hold, and look-at. Deep authoring stays in the modal, one button away.
It inherits the mode's no-order-verb rule verbatim. It rebuilds only when a
content SIGNATURE changes, not blindly every tick — a blind rebuild dismisses
tooltips mid-hover and makes a button impossible to click twice, which is most
of why the modal panels feel unresponsive. ⚠ That signature starts at a
sentinel, not `""`: an empty board produces an empty signature, so `""` would
compare equal on the first pass and the empty-state row would never build.

**Work-UI polish.** Both big panels now route every button through
`UITheme.style_button`, use the `FONT_*` scale, and take their palette from
UITheme (the local `C_OVER`/`C_FREE` were near-misses of `C_ERROR`/`C_GREEN`,
so two reds and two greens meant the same thing on one screen);
`UITheme.style_progress` exists because a stock Godot `ProgressBar` was the
only light-grey chrome in a dark panel, and a work UI is mostly progress bars.
The chore board is **sorted into the order the crew actually works it** —
`board.chores` is insertion order while `available_for` sorts by priority, so
the list the player read was never the queue, which made the priority control
two rows below it look inert. Rows now surface the live crew fraction, the
repeat mode, whether a chore is held or dependency-blocked, and whether it has
a PLACE at all (a chore with no target happens wherever the worker is standing,
which reads as broken). Two real bugs fixed alongside: the "Where…" round trip
called `close()`+`open()`, which re-ran the draft loaders and silently
discarded an unapplied routine or animation edit; and the project panel
reported failures by mutating a `LineEdit`'s placeholder, invisible the moment
anyone types.

## Solar Bootcamp tutorial + pre-baked challenges

**DC electrical layer (`system_graph/graph_dc_electrical.gd`, sibling of
PvElectrical, both over `GraphNesting.flat_connections`).** Battery-bank
topology via a weighted union-find over conductive nets (KVL
potential-consistency: an inconsistent constraint IS a closed loop with net
EMF = a **short circuit**; equal-voltage parallel banks are consistent and
clean). Derives bus voltage (series sums), capacity, S×P counts, chain
mismatch. `find_battery_overvoltage` = PV reachable with no live controller
in the path and string Voc > 1.217×nominal charge ceiling.
`controller_throttle` = P ≈ V_bus × max_charge_amps (Victron PWM/MPPT paper)
— the previously dead preset amp specs made live.
`system_graph_view._check_electrical_faults` (renamed from
`_check_pv_voltage_faults`) trips all three fault families; shorts sever the
loop's wires (reuses conduit burnout severing); batteries share the
controller's DESTROYED/RESET canvas contract; cards live in
`GraphEducationCards.card_for_fault` keyed by `GraphNodeState` reason and
present through `GraphFaultCardModal` (queued; replaced the hand-rolled
overlay whose `%`-precedence format bug is now selftest-guarded).
`_tick_dc_throttle` runs AMBIENT (graph closed too) and pushes the summed
delivery cap into `SolarUI.set_graph_dc_limit_w` (−1 = no cap; PV not routed
through a real controller+bank passes uncapped so freeplay is untouched).

**Tutorial (`gameplay/tutorial_*` + `scenes/ui/tutorial_hud.gd`).** 12
data-driven levels (`TutorialCatalog`): short circuit (failure IS the win) →
overcharge → PWM 120 W → array scaling 360 W → 24 V/720 W → 48 V/1200 W →
3S2P string sizing → 24 h runs with loads/utilization → Ctrl+G power-station
merge → unlock_all. Goals (`TutorialGoals`) are pure TOPOLOGY predicates
("deliverable watts" = min(array W, bus×amps)) so they read the same at
midnight and selftest offline; run-levels are judged from bake results
(`evaluate_run`). `TutorialDirector` (lazy SystemGraphView child, 🎓 toolbar
button) owns flow + the **sandbox**: `begin/end_tutorial_sandbox` snapshot
and restore the player's real graph, `collect_save_state()` RETURNS THE
PRE-STATE while sandboxed (autosave also flag-suspended), an external
apply_save_state drops the sandbox (incoming wins, `sandbox_interrupted`),
solar_bridge is `set_enabled(false)`d, and the director snapshots clock +
battery SOC so tutorial runs can't leak time into the real world. Unlocks
persist in `ProgressStore` (`user://progress.json`) — **no file = everything
unlocked** (grandfathering for existing installs); the first-load prompt
(new players, headless/harness no-op) offers bootcamp vs skip-unlock-all;
`library_panel` gates categories/presets by unlock (keyed by preset LABEL)
with a per-level `tutorial_preset_filter` override. Trainer presets (300 W /
40 Voc panel, PWM 10 A, MPPT 150/30) make the curriculum numbers exact.

**Pre-baked challenges (`gameplay/challenge_bake_engine.gd`).** `run_mode:
"prebake"` ChallengeDefs (span day/month/year → 1/4/38-min sample steps,
sized to the 20160-sample timeline caps) compute the WHOLE span in seconds:
energy via SolarUI's `_sim_series` (reused so the timeline's SIM clip lane
draws the bake for free), resources via `ResourceFlowEngine.render_step`
(AC availability injected from the co-baked SOC), population via
`NpcPopulationBridge.tick_at` at ≤0.1 h substeps (never the stochastic >6 h
catch-up). Failure = power failure (SOC PINNED at the floor while net<0,
sustained 0.25 h — the clamp means SOC never reads below the floor),
colony collapse, or stockouts; playback sweeps the playhead ~20 s reading
baked buffers (battery read-through, `seek_all_tanks`), parks at the
breakpoint, and **retry replays the SAME segment** against the player's
edits (specs/NPC/battery snapshots restore; wiring changes survive).
Ownership discipline mirrors the video exporter: time_scale 0 + the view's
`set_ambient_flow_suspended` (the ambient tick would otherwise rewind tank
specs mid-bake via its frozen-clock scrub path); every exit through
`_release_world()`. ChallengeRunner maps engine signals onto the classic
challenge_started/failed/won wiring (main.gd/timeline/picker unchanged;
realtime challenges byte-identical; runner refuses to start over an active
tutorial sandbox and vice versa). "Useful utilization" = (loads served +
charge banked)/potential — the generated-solar channel reads ~100% even
while the battery-full clamp wastes sun, so it is the wrong teaching number.

## Extreme weather (core/weather/)

Eleven hazards in `HazardCatalog`; four SIMULATED so far (wildfire smoke, dust
storm, damaging winds, heatwave), the rest are risk-profile-only rows marked
"not yet simulated". Master toggle is `GameplayRules.extreme_weather_enabled`
(**default false**, save- and scenario-scoped like every other mechanic);
per-hazard opt-ins + the "Drama" slider live in `ExtremeWeatherPrefs`
(`user://extreme_weather.cfg`). Settings → **Extreme Weather** tab shows the
site's real risk profile and a non-persistent **Preview** control.

**Severity is a PURE FUNCTION of absolute hours.** This is the load-bearing
constraint, not a stylistic choice: it is why hazards scrub backwards, replay,
and bake into prebaked challenges for free. `crisis_events/crisis_event_manager.gd`
is therefore the WRONG host — it rolls triggers on real seconds and PAUSES every
event whenever `time_scale != 1/3600`, so weather there would vanish at any speed
players actually use. Dependency direction is one-way: a crisis event may READ
the director; the director never reads crisis state. `hazard_began`/`hazard_ended`
are derived by DIFFING the evaluated set, never by a trigger, so rewinding out of
a smoke event emits `ended` exactly as fast-forwarding past it does.

**Four-layer resolution ladder** (`ExtremeWeather.resolve_at`): NWS/IEM alert
spans (authoritative timing, 1986→now, US) → measured AQ + weather (shapes the
alert into an hourly curve, and can raise a hazard on its own) → deterministic
climatology synthesis (ONLY where layers 1-2 have no DATA, not merely no event —
otherwise you invent smoke onto a verifiably clean day) → `blank()`.

**`HazardState` is the one contract.** `blank()` is the IDENTITY element and
`combine()` is commutative; optics take the worst, energy factors MULTIPLY.
`AtmosphereApplier.resolve(base, blank())` returns `base` field-for-field — that
single property is the "feature off ⇒ zero visual change" guarantee.

Traps, each of which RENDERS rather than erroring:
- **`fog_aerial_perspective` moves DOWN under haze, not up.** With
  `fog_sky_affect = 0` it blends the *rendered sky colour* into distant geometry,
  so raising it under smoke pushes terrain toward BLUE.
- **`fog_sky_affect` alone cannot take over the sky**, because the fog colour is
  simultaneously the terrain haze — which must be dark while the sky is luminous.
  Hence the `hazard_haze_color`/`hazard_haze` block in `sky.gdshader`, applied
  BEFORE the sun block so the disc survives as a dim red ball. Daylight-gate it
  or nights go brown and starless.
- **`weather_light_factor` has one owner** (`solar_ui._apply_smooth_weather_lighting`,
  rewritten every frame). Hazard dimming is a SEPARATE `_hazard_light_factor`
  multiplied alongside it in `_update_sun`.
- **`_apply_advanced_rendering_toggles` owns volumetric fog** and is reachable
  straight from the settings panel, so the emissive dust wall is forced there,
  not at the environment choke point — writing both erased the wall on any
  god-rays toggle.
- **`clampf` does NOT filter NaN**, and CAMS returns real null hours. Every 0..1
  factor in the applier goes through a NaN-safe clamp; the selftest sweep exists
  because three of them originally did not.
- **`SolarIrradiance.ghi_wm2_at_calendar` short-circuits on `has_real`** and
  returns measured GHI verbatim. Aerosol is applied on THAT branch too, or
  extreme weather is silently free of consequence on exactly the sites that have
  real weather data. Open-Meteo's shortwave field carries only climatological
  aerosol and does not resolve plumes — which is why CAMS publishes it separately.
- **Four weather samplers exist** with different key names. They are not unified
  (too risky across the prebake path); instead all four call
  `SolarIrradiance.decorate_with_hazard` and the selftest pins that they agree.
- **`NpcWeatherGate` air uses a SECOND exposure factor**
  (`air_exposure_factor`), never a change to `exposure_factor` — walls stop rain
  completely but only damp smoke, and every existing threshold depends on the
  original returning 0.0 indoors.

**Severity-curve design lessons** (both shipped broken once): anchor severity 1.0
at the observed EXTREME TAIL, not a category boundary — anchoring smoke at the
EPA "Hazardous" threshold rendered a hazardous day as light haze. And check the
curve SHAPE, not just monotonicity: the selftest's cliff guard compares each
step's ratio against the MEDIAN step, because a uniformly steep curve is
legitimate (dust fronts really do arrive fast) while one anomalous step is not.
Related: the US AQI truncates at 500 by definition, which smoke reaches by ~0.6
severity, so gameplay channels derive from SEVERITY while the displayed AQI stays
truncated like the real index.

## Discord-native multiplayer (core/discord/ + core/multiplayer/)

Goal: a private community on one Discord server drops into a shared world with
Discord handling identity, discovery and voice. **Zero always-on servers of
ours.** Full plan + remaining phases:
`~/.claude/plans/i-want-to-do-flickering-torvalds.md`. One-time Discord
developer-portal setup: `LOCAL_CONFIG.md`.

**The structural rule:** every security-relevant decision lives in a PURE
`class_name` file with no HTTP (`discord_pkce`, `gate_rules`, `community_file`,
`directory_record`, `relay_batcher`, `discord_links`, `discord_config`, plus
`MpReachability`'s classification half), so `core/discord/discord_selftest.gd`
feeds it fixtures offline. The Node halves (`discord_http`, `discord_identity`,
`discord_gate`) only fetch. Do not move a verdict into a Node.

**Sign-in** is OAuth2 authorization-code + **PKCE with no client_secret**
(needs the app's "Public Client" toggle — without it every token exchange 401s,
and Discord's own error text does not say so, which is why
`discord_identity._on_token_response` appends the hint). The code arrives in the
redirect's QUERY STRING, so a loopback `TCPServer` is enough — no JS shim, which
the implicit grant would have required. **The redirect port cannot be dynamic**
(Discord demands an exact registered match): three are reserved, 34199–34201,
and binding falls through them; all busy = a loud refusal, never an unregistered
port. The callback socket is held ~0.75 s before closing so the browser actually
renders the "you can close this tab" page. Scopes are deliberately
`identify` + `guilds.members.read` only — the broad `guilds` scope would let a
host holding a guest's token enumerate every server that guest is in.

**Reachability.** `pick_lan_ipv4()` returns an RFC1918 address by design (LAN
discovery depends on it), so internet play never worked: the join code's address
was always a LAN address. `MpReachability` adds UPnP — **on a WorkerThreadPool
task, because `UPNP.discover()` blocks ~2 s** — and the public address is folded
in ADDITIVELY as a second candidate. Join code v3 carries `addrs` while STILL
mirroring the LAN address into the top-level `ip`/`port`, so every pre-v3
consumer keeps working untouched; `decode()` accepts v2 and v3, pinned by a
frozen v2 literal in the selftest. The client tries candidates in order —
**LAN first only when its own /16 matches**, since a naive LAN-first costs every
internet player a pointless 6 s timeout. `_on_connection_failed` used to call
`leave_session` unconditionally; the ladder now intercepts before it, and there
is a wall-clock per-candidate timeout because a black-holed UDP port (the common
NAT case) may never fire `connection_failed` at all. We run no external server,
so a mapping is reported "created — not verified" until a peer actually connects
from a public address. CGNAT (`100.64/10`) is called out by name — port
forwarding cannot work there, so "check your router" would be wrong advice.

**Admission.** `rpc_hello` was only ever ADVISORY: once ENet connects, any peer
can drive `@rpc("any_peer")` handlers before saying hello, and
`rpc_lock_claim`/`rpc_lock_release` had no gate or rate limit at all. Async
Discord verification would have widened that window to seconds, so
`peer_admitted()` now gates **inside `note_peer_traffic`** (covering presence,
chat and every design transfer in one edit) with explicit checks added to the
handlers that bypass it. Two rules that must not be "simplified":
the not-admitted path **drops without kicking** (the rate-limit path kicks, and a
slow Discord round-trip must not punish a fast joiner), and `rpc_hello` passes
`require_admitted = false` since it legitimately precedes admission.
All the cheap synchronous checks still run first and unchanged, so a peer that
fails one never costs an API call; only then does `_begin_discord_admission`
hold the peer out of `peers` pending `DiscordGate`. **The gate's first call is
`GET /oauth2/@me` to prove the token was issued to OUR application** — without
it, a token the guest granted to any other Discord app would be accepted.
Discord unreachable fails **CLOSED** by default, deliberately the opposite of
`MpHardening.trusted_key_allowed`'s fail-open-on-empty (that is a
*configuration* statement; this is a *runtime failure* of a restriction the host
asked for) — do not let a refactor harmonise them. The host briefly holds a
guest's bearer token: it is never persisted, the cache keys on its SHA-256, and
`MpHardening.redact` strips it at the telemetry choke point. `DiscordBridge` is
the seam that removes the trade-off once someone runs a bot.

**The directory is ONE Discord message, edited in place forever.** Discord's
webhook message endpoints (`GET`/`PATCH` `/webhooks/{id}/{token}/messages/{msg}`)
need no authentication, so a single message is a readable AND writable
key-value store every member can reach with no bot and no server of ours. It is
created once and only ever edited, so its Discord link never changes — that pin
IS the permanent "join my map" link. `SimDirRecord` (pure) owns all the
concurrency; `discord_directory.gd` fetches and sequences.
**Host election:** read → if no live host (heartbeat older than `STALE_SEC` 150)
mint a claim, PATCH with `seq+1`, wait `CONFIRM_DELAY_SEC` **writing nothing**,
re-read. Discord serialises the two PATCHes and last-write-wins the stored
content, so if both racers re-read after the same fixed delay with no
intervening write, exactly one sees its own claim. **That no-intervening-write
discipline is what makes last-write-wins a valid arbiter** — which is why the
claim PATCH passes `no_retry` (`discord_http` would otherwise silently retry a
429 into the confirm window and mint a second host) and why a failed claim reads
as LOST, not as a retry. A `RECONFIRM_SEC` (+8 s) re-read before the winner
accepts its first peer makes the rare double-host self-healing. Reads whose
`seq` regressed are ignored (stale cache). `_host_block` reads LIVE session
state on every heartbeat, not the cached publish, so a refreshed join code or a
changed player count never goes stale in the channel. Writes DO overwrite a
hand-edited message: refusing would lock the community out of hosting until
someone tidied the channel, which is worse than losing one typed line — give the
directory its own channel. The directory is a CONVENIENCE, not a security
boundary; anyone with the community file can stomp it. `DiscordGate` is the
boundary.

**The community file** (`SimCommunity`, `SMBC1:` + base64(gzip(JSON)), also a
`.simcommunity` file) is the one blob an owner hands members: client id, guild,
role ids, voice channel, directory webhook + message id. `validate()` is a
SECURITY BOUNDARY — every id must be a snowflake (they are interpolated into
URLs) and **every webhook URL must be on discord.com**, or a pasted file
redirects the host's relayed chat to an attacker. Stored one file per community
under `user://communities/`, active one in `mp_prefs.cfg`; `active()` falls back
to "the only one on disk" so a member who imports a single file never also has
to pick it.

**Chat relay is OUTBOUND ONLY and host-only.** `rpc_chat_deliver` is
`call_local`, so `MpChatController._append` runs on the host for every message —
relaying from each client would post every line N times and would need to hand
every client the webhook credential. ⚠ A BROADCAST system line arrives with
`peer_id == 0` **and `system: false`** (rpc_chat_deliver hardcodes that field),
so the relay filters on `peer_id <= 0` too — without it the relay's own "chat is
being mirrored" notice gets copied into the channel. Every payload must carry
`allowed_mentions: {"parse": []}` or an in-game `@everyone` pings the server.
Off by default and it ANNOUNCES itself, to everyone present and to each later
joiner — mirroring people's chat into a semi-public channel silently is a trust
violation, so the notice is part of the feature. Inbound needs a bot
(`DiscordBridge`): a webhook can only read back messages it wrote itself.

**Host-authoritative simulation + NPC replication.**
`SystemGraphView._tick_resource_flow_ambient` had NO host/client guard: every
client ran its own `ResourceFlowEngine` and `NpcPopulationBridge` off its synced
graph copy, drifted, and got stomped by the host snapshot every 12 s — the
people on a joiner's screen were a local hallucination that snapped twice a
minute. `_mp_is_replica()` now short-circuits that tick **before** the
`_resource_flow == null` guard (the client path must not depend on an engine it
never steps). `MpPopulationController` streams the roster at 6 Hz: an id TABLE
on roster change (reliable), then INDEXED frames (unreliable_ordered) — by name
a 64-person camp would be ~7 kB/s of pure string, by index it is ~4 kB/s.
**The seam is one call:** `NpcPopulationHost._process` reads
`_bridge.agent_dots()` and nothing else, so handing it the controller's mirror
(which duck-types `agent_dots`/`active`) makes the whole avatar/LOD/pose path
work unchanged. Frames for an unknown table rev are dropped, not queued — the
reliable table and unreliable frames race by design.

**Possession ("play as one of the NPCs").** Call it **possess**, never
"embody" — `VIEW_MODE_EMBODY_TWINS := 157` already means "give a graph item a 3D
twin" and has a documented id-collision history. `NpcAgent.controlled_by_peer`
is TRANSIENT (absent from `snapshot()`; persisting it strands a frozen agent
with no controller after a reload). The engine skips a controlled agent in
`tick()`, `_separate()` (they push, they are never pushed), `_catch_up()` (which
would otherwise reroll their needs mid-possession) and `_process_departures()`
(they cannot rage-quit out from under a player — quit pressure still accrues, so
they leave the moment they are released). `_decay`, `_update_morale` and
`current_consumption` keep running: possession is not a way to opt out of the
resource economy. Bind by `agent_id` STRING, never by object reference —
`_ensure_engine` replaces every `NpcAgent` when authored `occupants` changes.
`_pose_possessed` bypasses the SMOOTH_RATE lerp (~125 ms of lag reads as broken
controls), `wants_anchor` (reads as input dropping out), and clock-derived
`paused`/`time_mult` (a possessed body would freeze when the host pauses); yaw
comes from the player's own look direction, not the direction of travel.
Possessed avatars are exempt from cull/far-pose/rig budget. Per the design
decision the clock is **warned about, never clamped** (`MpPossession
.time_scale_warning`, throttled by cooldown AND speed bracket since `rpc_clock`
lands at 2 Hz; note main.gd defaults `time_scale` to 0.01 ≈ 36×, so the
threshold is a tuned multiplier and not "> 1").

⚠ `PROTOCOL_VERSION` is now **3**, and `_poll_lan_packets` filters LAN beacons on
the same constant — old and new builds neither join nor SEE each other, and only
the new client can print a useful message about it.

## Stream-fed PowerSpout (the tapped-source hydro loop)

The play loop: place a PowerSpout, drop a **stream intake** uphill, draw a
penstock between them, dial a test L/s in the Hydro Lab, watch real power.

**A source is a FLOW, not a reservoir.** `create_penstock_intake_at` mints a
`resource` item with `stream_source: true`, `unlimited_capacity: true` and NO
`level_m`/`floor_m`/`rim_m` — there is no surface to draw down. Its **ground
elevation is the gross head** (the routed contour penstock's invert drop, adopted
by `_adopt_penstock_conn`), and how much water it runs comes from
`core/conduits/hydro_supply.gd` (`HydroSupply`, pure static):
`Q = base_flow_lps + rain_lps_per_tenth_in_h × (rain_mmh / 2.54)`, capped by
`max_flow_lps`, optionally lagged by `recession_tau_h` (default 0). **0.1 in =
2.54 mm exactly** — that conversion is the single likeliest thing to be silently
wrong, so it is pinned. Authored in the freeform inspector
(`_build_stream_intake_section`); `recess()` uses `1 − exp(−dt/τ)`, exact for a
step at ANY dt, because the world clock hands it multi-hour ticks at speed.

**Supply and design flow are DIFFERENT ZEROES, and merging them is the bug that
keeps coming back.** `HydroSource.available_supply_lps` discriminates on
`specs.has("supply_lps")`, never on `> 0`: an engine-written `supply_lps` of 0.0
means a spring that has stopped running, while `design_flow_lps` of 0 means a
nozzle kind is UNLIMITED. Downstream, `PeltonPhysics.operating_point_supply_limited`
carries the same contract — **NAN = unconstrained, 0.0 = dry**.

**Supply-limited physics is honest, not a clamp.** When the spring runs less than
the nozzle would pass, `Q = supply` AND the nozzle only converts the head its own
flow demands (`nozzle_head_required_m`), so the penstock runs partly full and the
surplus head is never turned into jet velocity. That is why a big jet on a small
spring makes far less power than the gross head suggests; the Lab warns and names
the matching nozzle via `nozzle_d_for_supply_m`. Verified end to end by
`--capture=penstock`: 0.25 L/s → 0.7 W, 4.0 L/s → 505 W on the same 46 m head.

**Water really moves.** `_process_spec_driven_hydro` takes `net_rates` and
`dt_hours` and classifies on the kind's `pond_drawdown`: run-of-river STREAMS THE
RIVER THROUGH (rate stays 0 — the river is not a resource the graph owns, and
crediting a sink from it would conjure water out of the landscape), while a tapped
penstock stamps real port rates, credits the outlet sink through the shared
`_credit_outlet_sink`, glows the penstock via `_cache_conn_flow`, and debits the
source ONLY when it is not `unlimited_capacity`. Before this the branch forced the
water output to 0 and took no `net_rates` at all — the reported "I can't get water
to flow through the turbine".

**Opening the Lab must not rebind a stream-fed turbine.** `prepare_siphon_lab_session`
auto-binds the nearest pond when `resolve_siphon_pond` comes back empty — and a
stream intake is not a pond, so that fired every single time and
`bind_siphon_to_nearest_pond` REPLACED the water-in wiring, deleting the penstock
the player had just routed and latching the turbine onto a pond elsewhere on the
map. Guarded by `_turbine_has_stream_source`; the explicit "Rebind to nearest
pond" button is deliberately NOT gated (that one is the player asking). Pinned by
`--capture=penstock`'s "opening the Lab did NOT delete the penstock wiring".

**The annual estimate needs the SEASONAL supply.** `available_supply_lps` returns
one instantaneous number, so `annual_energy_kwh_from_specs` reused it for all
twelve months — the annual figure read whatever the spring happened to be doing
when the panel opened, blind to the rainfall that is the whole point of the rain
coefficient. The engine now stamps `supply_monthly_lps` (12 × L/s, from
`HydroSupply.monthly_supply_lps` against `WeatherService.monthly_precip_mm`,
change-gated on the intake's authored params) and the annual closed form takes it
as an optional argument. Separate key from `supply_lps` ON PURPOSE: the live tick
must use real-time rain, never a monthly mean.

**The close-up's load slider is a what-if, and it costs watts.** The graph node
reports the MATCHED-load output (what a dump-load or MPPT controller holds).
`runner_efficiency(x, 1.0)` is the fraction of that delivered at the current speed
ratio — 1.0 at x_opt by construction — so the HUD scales the graph's power through
it. Without that the HUD read "η 0%" at runaway while the status strip a few
pixels below reported full watts.

**The Lab's test flow is the SUPPLY, not a pond fill.** For penstock kinds
`lab_sim_inflow_lps` overrides base flow + rain at the intake (flagged there as
`supply_override`, cleared by `teardown_siphon_lab_session`), and
`_apply_lab_sim_inflow_realtime` gained a stream branch BEFORE its pond lookup so
the knob moves the power instantly while the Lab holds the clock frozen.

**Per-view cameras.** `graph_canvas._view_cam` holds `{zoom, pan, along_m, elev_m}`
per view; `set_view_mode` captures the outgoing view and restores the incoming one
— capture happens at the SWITCH, not at each of the ten `_zoom` write sites, so a
new writer cannot break it. `VIEW_SIPHON` is a real mode (the canvas draws only its
background under the Lab) instead of being faked by parking in `VIEW_FREEFORM`,
which is what handed the Lab the freeform camera to overwrite;
`frame_elevation_for_siphon(id, set_camera)` lets the Lab take the heading/slice
without the framing. Pinned by `--capture=siphon`'s decoupling assertion.

**Elevation registers with 3D.** `_refresh_item_elevations` resolves a prop-bound
item's elevation from `ConduitManager.anchor_global_for_item` — the SAME resolver
the 3D conduit terminates its pipes at — before falling back to terrain ground Y,
and skips siphon modules whose elevation the flow engine and the Lab own.
`_phys_item_world_center` does the same for the whole anchor (XZ too), memoized
per draw. `_elev_exaggeration_draw()` returns 1.0 whenever a CAMERA is the
projection authority, not just under `soi_live_preview`: the overlay sits ON the
3D image, so a 5× stretch could never line up. `GraphSiteLayout.LAB_MIN_ORTHO_H_M`
(0.05 m) is clamped by BOTH the Lab's `_lab_view_metrics` and the section camera,
so deep zoom can no longer unlink them.

**Conduits are X-RAY by design, so they are HIDDEN in first person.**
`ConduitKinds.make_material` sets `no_depth_test` and `conduit_flow.gdshader`
declares `depth_test_disabled` so buried runs read through the Elevation / Site
CT soil bowl — which is exactly what made them confusing in the world: an
auto-revealed culvert tailrace or routed penstock (both stamped `visible_3d:
true` by `ensure_siphon_outlet_sink` / `create_penstock_intake_at`, which the
player never asked for) draws straight through the terrain. They cannot simply
stop being built — the REBUILD is what stamps `route_length_m` and the endpoint
inverts the flow engine adopts — so `ConduitManager._refresh_world_visibility`
gates the NODE instead: `visible = _global_visible or _preview_visible`. The
preview flag is pushed by SystemGraphView off the SoI service's
`preview_active_changed` (one signal covers mode switches AND the graph-close
teardown), and since the preview shares this World3D (`own_world_3d = false`),
that same node visibility is what keeps Site Plan / Elevation CT / the Hydro Lab
section drawing the pipes they exist to show. "Show 3D wires (world)" ON =
visible everywhere, unchanged. Two consequences to preserve: the first-person
plug/route GHOST is parented to `ConduitRouteController` itself with
`top_level = true` (its verts are world-space) so the drag feedback survives the
hide — everything left under the manager is a run visual and hides with it; and
Site Plan's `prefer_3d` wire mode, which BORROWS the global pref, must hand it
back on graph close (`_restore_site_conduit_visibility` in the visibility-changed
branch and `_exit_tree`) — it used to restore only when switching to a
non-physical view, so one visit to Site Plan left every x-ray run hanging over
the landscape for the rest of the session. All four states are pinned by
`--capture=hydroload`.

**Item elevations must be resolved AT MAP LOAD, not only on graph-view entry.**
`_refresh_item_elevations` used to run solely from `_apply_graph_view_mode` for
Site / Elevation / Siphon, so a map booted into first person ran every conduit off
whatever the save carried. An UNBOUND item — a culvert outlet sink has no prop —
saved at elevation 0 anchored at world Y ≈ 0 while its machine sat 80 m below, and
the culvert fired ~265 ft into the sky at an angle until the player pressed G.
`TerrainLoader` now calls `SystemGraphView.resolve_site_elevations_after_load`
(backfill + refresh + `ConduitManager.sync_all`) right before `map_load_complete`;
the `sync_all` also rebuilds any conduit that failed to build at boot. Pinned by
`--capture=hydroload`, which asserts BEFORE the graph is ever opened that no
culvert outlet sits above its inlet and no endpoint pair is stranded 120 m apart.

**Three Lab traps that all render plausibly while being wrong.** (a) The overlay
draws in POND-RELATIVE along — `_ensure_dem_bake` subtracts `pond_along` — so
anything built from an ABSOLUTE `project_onto_section` coordinate must too
(`_pond_along_m`). The routed penstock and the drag ghost did not, and on sloping
ground a sideways shift reads as the pipe FLOATING metres above the terrain while
3D looks right. (b) Port positions are flat `x`/`y`/`z` scalars, NOT a `pos`
Vector3 — `get("pos", Vector3.ZERO)` silently measures the model ORIGIN and
returns a plausible 0.000 m offset. (c) `design_flow_lps == 0` means UNLIMITED for
a nozzle kind, so the Lab's `maxf(design, 0.01)` floor pinned the whole power
curve to a 0.01 L/s supply and drew it at ~0 W; only design-flow kinds get the
floor.

**The power chart separates HARDWARE from SITE.** The per-size curves exclude
`supply_lps` (a live supply is a property of the site, not the pipe — leaving it
in made all four sizes return the identical number and four curves drew on top of
each other, silently answering "a fatter pipe buys you nothing"). The supply gets
its own labelled curve, and the per-size STATS stay supply-aware and say outright
when the source, not the pipe, is the limit.

**The runner's DISPLAYED speed is compressed** (`_display_omega`). 24 buckets at
533 rpm is 213 bucket-passes/s against 60 fps — far above Nyquist, so the wheel
aliased into a crawl while only the arms read ("spins so fast it looks slow"). No
frame rate fixes that. The display saturates toward `DISPLAY_RPM_MAX` 55 (~22
passes/s) on a monotonic curve, so faster still looks faster; the HUD reports the
TRUE rpm, and only the animation is slowed.

**The splash is the OTHER half of the Euler relation, not a fudge.**
`PeltonPhysics.bucket_exit_speed_ms(v_jet, x)` = `v_jet·|1 − 2x|` (ideal 180°
bucket reverses the relative velocity). At the matched load that is only
0.08·v_jet, because nearly all the jet's momentum went into the shaft — which is
why a well-tuned Pelton visibly DRIBBLES while a runaway flings water everywhere.
Driving the close-up's splash from it makes the load slider legible at a glance
and replaced an arbitrary fraction-of-jet-speed constant. `--capture=siphon`'s two
shots are the visual pin.

**Stream-intake VFX** (`gameplay/stream_intake_flow.gd`, attached by
`PlacedPropRuntime._maybe_attach_stream_intake_flow` on `model_id ==
"stream_intake"`): falling inflow plus a pool whose level rises with
`live_supply_lps`, so a dry spring and one in spate no longer look identical in
the world. ⚠ It resolves its `graph_item_id` LAZILY per poll, because
`create_penstock_intake_at` places the prop and patches `graph_item_id` onto the
record AFTERWARDS — the runtime is attached with an empty id and, without the
re-read, never showed water at all.

**Turbine close-up** (`scenes/ui/hydro_turbine_closeup.gd`, a Hydro Lab view tab):
an `own_world_3d` studio — deliberately not `graph_soi_preview_service`, which
carries the AMD-TDR crop/clamp scar tissue — showing the real
`Pelton Wheel, 24 Spoon` node with the housing ghosted (`CULL_FRONT` on the shell
is what reads as *cut open* rather than as fog; the housing set is DERIVED as
"every mesh that is not the runner", never name-matched). Two traps, both of which
RENDER rather than erroring: the spin centre must be measured in the runner's
**PARENT** frame (`_runner_centre_parent`) because `_runner.transform` is local and
the GLB has a baked inch→metre node between ModelRoot and the wheel — rotating
about a ModelRoot-space centre throws the wheel out of the housing; and the jet
must arrive **in the plane of the wheel** (`_jet_side`, perpendicular to the spin
axis), or a side-on camera looking along that axis sees it end-on and it is
invisible. Speed is `omega_rad_s_at_ratio(v_jet, PCD, speed_ratio_for_load(load))`,
so shedding the load runs the wheel toward 2·x_opt while `runner_efficiency`
collapses to zero — verified by `--capture=siphon`'s console dump (matched 458 rpm
η 65% → runaway 903 rpm η 0%). `core/conduits/pelton_jet.gdshader` scrolls at the
REAL `jet_velocity_ms`; it is written clean rather than reusing
`terrain_river`/`terrain_water`, which `#include soi_clip.gdshaderinc` and can
vanish in a studio viewport where the clip uniforms are unset.

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

List re-verified + pruned 2026-08-11: both boot-time "Node not found" errors
are FIXED (`ToolManager` under Player → `get_node_or_null` + self-heal;
HAConnectionUI button paths now include `/ButtonContainer`). Four long-listed
entries were STALE and are dropped: duplicate device id `ibc_glow_lights`
(second instance renamed `ibc_glow_lights_2`, see ARCHITECTURE.md), the 4×
fire-extinguisher `!is_inside_tree()` (main.gd adds children before setting
global_position), the missing `camp_scatter_bake.tres` (the only load site is
guarded by `ResourceLoader.exists()`), and "target vector can't be zero" from
road/camp scatter (every look_at/Basis site now guards zero-length). A clean
boot of both built-in maps currently greps ZERO node-path/parse/script errors
— treat any new one as a regression.

**`core/terrain/site_boot_selftest.gd` currently FAILS 2 of 7** — "player above
ground gap -93.75 m" and "auto-veg generated got 0" at Mount St. Helens. It is a
live-NETWORK full-scene boot test (it fetches a z16 detail imagery layer that
never lands: `'detail' layer not cached — fetching z16 tiles …`), it is **not**
in the Validation list above, and it fails identically on d38417a — i.e. this
predates the 2026-08-01 stabilisation pass and is not a regression from it.
Diagnose the imagery fetch before trusting the grounding/vegetation assertions.

**`--capture=population` flakes: FIXED 2026-08-09** (root cause found): the
food/chore/cascade sub-checks were "state-sensitive" because the soak map's
autosave carries the SIM CLOCK forward between runs and agent RNG reseeds per
sim-DAY — every run sampled a different population day. The harness now pins
2026-07-15 07:00 at the start of `_run_population_verify` and the capture
passes fully and reproducibly. If a sub-check fails now, it is a real
regression (or someone removed the date pin).

**Re-verify this list before trusting it** — it is hand-maintained and drifts.
The former "UISP button node-path misses" entry was stale: nothing outside
`uisp/` ever referenced UISP, and that subsystem is now under `parked/uisp/`
(see `parked/README.md`).
