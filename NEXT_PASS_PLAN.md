# Next pass — performance, bug fixes, easy wins (2026-10-18)

A whole-project read taken after `646f533` (sim pre-render). Sources: the
harness matrix, ARCHITECTURE.md's debt list, the memory notes of every
feature pass since July, a grep of the code's own TODO markers, and a
read-only sweep of every `_process` body for per-frame work that is not
change-gated. Nothing here was measured in a running game yet; Push 0 is the
measurement, and every item below names the bench or capture that proves it.

## Where the project stands

- Tree clean at `646f533`. All 47 harness modes were green on 2026-10-12;
  the four modes added since (timeline, graphtools, pvsnap, conduits, modals,
  tour) are green too.
- Known reds: `population` personal-space check (deterministic, Mt Vernon),
  `penstock` 2 world-driven checks, `microclimate` 61 engine errors,
  `popin` reporting one 40 m hero jump and 61 of 529 frames over 100 ms.
- Monoliths outran the "extract one responsibility per push" rule:
  `system_graph_view.gd` 19.8k lines (15.8k in August), `terrain_loader.gd`
  12.8k (10.2k), `graph_canvas.gd` 11.7k (9.2k), `playtest_harness.gd` 16.4k.
- The ServiceLocator sweep regressed again: 28 hardcoded
  `"UILayer/SystemGraphView"` lookups in 20 files, almost all in code written
  after the August sweep.
- Perf instrumentation covers the graph tick and the population tick well,
  and almost nothing else that runs per frame in first person: SolarUI,
  TimelineUI, HudLayout, the lights, InteractionFocus, StreamTracers,
  Planets/StarSystem, main's hazard/fog pass. Two F3 sections (`prop_ticks`,
  `canvas_draw`) are listed but never emitted and always read 0.
- Many memory notes still say "landed uncommitted"; that work is in the last
  four commits. Treat those notes as stale.

## Push 0 — measure (half a day)

Nothing below ships on a hunch. Before Push 1:

1. Add F3 sections around the uninstrumented per-frame work:
   `main.gd` hazard VFX + ground fog + `SimFxRate.tick` (before `world_env`),
   `terrain_loader._process` snow/moss push (after `terrain_tick` ends),
   `stream_tracers._process`, `interaction_focus._physics_process`,
   `solar_ui._process`, `timeline_ui._process`, `hud_layout`, the placed
   lights (`placed_light` / `placed_mover_light` / `placed_string_light`),
   `planets._process`. Emit `prop_ticks` from `PlacedPropRuntime` or drop it
   from `SECTION_ORDER`; same for `canvas_draw`.
2. Run the three benches as the baseline on both worlds and keep the
   numbers in `HARNESS_MATRIX.md`:
   `tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/flow_step_bench.gd`
   (the accuracy hash `fe644fbb3825ae00` must not move),
   `tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/graph_draw_bench.gd`,
   `tools\harness.ps1 -World walton -Capture crowdbench -UserArgs @("--count=1000","--ts=60")`.
3. Add a FIRST-PERSON bench (`tools/bench/first_person_bench.gd`, a
   `-RunScript`): graph closed, 10 s at 1x and 10 s at 60x on Mount Vernon,
   print every F3 section's median + 2 s peak, frame ms, draw calls. This is
   the number the whole of Push 1 is judged against. Walton at 60x is the
   `popin` regime, so run it there too.

## Push 0 — what the benches said (2026-10-18, 1920×1080 maximized, the user's prefs)

`tools/bench/first_person_bench.gd` and `tools/bench/gpu_toggle_bench.gd`
(both `-RunScript`, sandbox) exist now; the F3 sections `main_fx`, `planets`,
`terrain_season`, `stream_tracers`, `prop_ticks`, `placed_lights`,
`interact_focus`, `solar_ui`, `timeline_ui`, `hud_layout` are emitted
(`PerfSpan`, autoload-safe, for scripts the selftests load).

| world | frame (median) | render GPU | scripts (F3 sum) | verdict |
|---|---|---|---|---|
| Mount Vernon | 32 ms | **31 ms** | 3.5–4 ms | GPU-bound at **half render scale**, MSAA 8x |
| Walton | 45 ms | 11.5 ms | 24.7 ms | CPU-bound: population tick, nav bake, host, DC throttle |

GPU isolation on Mount Vernon (one thing off at a time, Δ vs 31.4 ms):
vegetation hidden **−23.6 ms (8 ms, 60 fps)**; MSAA off **−12.4 ms**;
SSIL −1.4; sun shadow −1.4; volumetric fog −1.2; SSAO −0.8; glow −0.8;
props / tiles / buildings / water / camps / lights / ground each < 0.6.
Render scale 1.0 would be 79 ms. So the first-person frame on the user's
own site is the canopy shaders (depth pre-pass + alpha pass, cull_disabled,
MSAA resolving every leaf edge twice); no CPU item in the table below can
move it. The per-batch breakdown and the alpha-scissor experiment are the
next lines of that bench.

Walton CPU, 1x (ms per frame, avg / 2 s peak): npc_host 5.6 / 17.5,
npc_population 5.1 / 30 (the 0.25 s tick, sliced), npc_nav_bake 2.9 / 6
(a legitimate 791×791 = 625k-cell bake that takes ~2 min after every load
and after every prop or camp change), crowd_raster 2.2 (345² samples, done
in ~30 s), flow_engine 2.2, timeline_ui 1.8 / 10, gv_dc_throttle 1.5 / 10,
solar_ui 0.9. The 185 ms flow_engine "peak" was the bench's own clock park
(a multi-hour catch-up step) and is gone from the bench.

After the first CPU batch (DC throttle topology cache, host readouts once
per tick, timeline ring + sweep caches, SolarUI group cache, dashboard
visibility gate, snow push gate, conduit pick memo, planets double-call):
Walton 45 → 35 ms median at 1x, gv_dc_throttle 1.5 → 0.4, timeline 1.8 →
1.4, solar_ui 0.9 → 0.6, npc_host 5.6 → 4.4.

## Push 1 — performance quick wins (first person, graph closed)

**Status 2026-10-18 (same session as Push 0):** DONE — the canopy shaders as
one opaque pass (the measured GPU owner; not in the table below, which was
written before the bench ran), #2 snow push, #3 main hazard/fog (shared
wind + cached autoloads), #4 conduit pick memo, #5 planets double-call, #7
timeline ring styleboxes, #8 sweep cache, #9 host readouts + picks once per
tick / viewer move, #10 light gizmo writes, #11 dashboard, #12 SolarUI,
#13 copy-on-write only, plus two not in the table: the DC throttle's
topology cached on (struct_rev, user_rev) — 7 ms a call on Walton — and the
nav grid reusing its baked heights across prop / camp / space changes
(`NpcNavGrid.begin_bake_reusing`, selftested). NOT done: #1 stream tracers
(0 ms in first person — flow view only), #6 conduit tick (0.25 ms), #14 the
small items, #15 the SoI stretch cap (unmeasured; the manual size is written
after the container size each layout, so the cap most likely holds).

Ranked by expected ms saved per line changed. Each is a change-gate or a
cache; none changes what the sim computes, so the flow-step hash is the pin.

| # | Where | What runs now | Fix | Proof |
|---|---|---|---|---|
| 1 | `core/water/stream_tracers.gd:94–128` | Up to 6000 beads; each frame a GDScript binary search (`_at`) + `set_instance_transform` per bead, cull 900 m so nearly all live | Advect in the vertex shader (per-instance phase + stream arc-length texture), or at least build one `PackedFloat32Array` and assign `multimesh.buffer` once; skip the frame when `SimFxRate.now` has not moved (paused) and the camera moved < 1 m | first-person bench, `--capture=water` flow-view beads still move |
| 2 | `core/terrain/terrain_loader.gd:445–478, 495–515` | Snow uniforms pushed every frame to Ground, DetailGround, Buildings and every `BuildingsCustom` child: a typed-array alloc, `ends_with` checks, a `get_shader_parameter` readback per mesh | Change-gate on (snow, depth_m) the way litter already is at :460; cache the filtered material list per mesh, invalidate on drape swap / building rebuild; extend `terrain_tick` to cover it | first-person bench; `--capture=weather` + a snow day shot |
| 3 | `main.gd:2699–2700 → 2073–2142` | Hazard VFX + ground fog every frame: ~6 `get_node_or_null("/root/…")`, 4 `WeatherService.sample()` (wind computed twice), 2–3 `HazardState.blank()` dicts | Cache autoload refs; compute wind vector + combined hazard once at 4 Hz keyed on the microclimate resolver tick; keep only easing per frame | first-person bench; `--capture=weather`, `--capture=microclimate` unchanged |
| 4 | `gameplay/interaction_focus.gd:113 → conduit_manager.gd:506–522` | `pick_conduit` at 60 Hz walks every segment of every cached polyline; a Dictionary per segment, `miss.duplicate()` per conduit, a `keys()` copy | Throttle to ~15 Hz with the camera-delta gate `_update_port_prompt` already uses (:518); bounding sphere per conduit beside `_sample_cache`; return a scalar | first-person bench; `--capture=penstock` Ctrl+click half, `--capture=conduits` |
| 5 | `main.gd:2756, 2767, 2957–2990`; `planets.gd:164–174` | `_update_planets` runs every frame AND inside the 20 Hz `_update`; 30 `"…_%d" % i` → StringName conversions per call; `Planets._process` redoes Kepler + labels while the graph hides 3D | StringName consts; drop the duplicate call; gate `Planets._process` on the graph-visible flag main already keeps | `--capture=stars` (marker vs blob dump unchanged) |
| 6 | `core/conduits/conduit_manager.gd:466–485, 860–900, 915, 1168` | Per connection per frame: two format strings, two `get_node_or_null`, child walk setting material params; `derive_type_for_connection` 2–3× per conn | Cache part-host nodes per conn id (invalidate on rebuild); type id once per conn per frame; flow pulse to shader `TIME`; outlet marker only when samples change | `--capture=hydroload` (burial, marker drag), `--capture=conduits` |
| 7 | `scenes/ui/timeline_ui.gd:925–946, 1129, 2517` (10 Hz) | Two StyleBoxFlats + four theme overrides allocated every 0.1 s whether or not play state changed → theme-changed relayout | Gate on a cached (playing, reversed) key; relayout clusters only when label text changed | `--capture=timeline` (0.5 px drift gate) |
| 8 | `scenes/ui/timeline_ui.gd:875 → 1146–1297` | Track redraw at 10 Hz: `/root/NwsAlertService` lookup, `get_alerts_in_range`, `mc.sweep()` building up to 337 dict rows per redraw | Cache the sweep keyed (floor(win_start), span, resolver invalidate counter); `queue_redraw` only on ≥ 1 px playhead move or window change | `--capture=timeline`, `--capture=microclimate` strip shot |
| 9 | `core/population/npc_population_host.gd:160–399` | 4–5 full passes over dots per frame with two sorts; ~10 setters per hero with `str`/`float`; `set_morale` / `set_tag_visible` have no early-out | If `dots` is the same Array instance as last frame and the camera moved < 0.5 m, skip the re-picks and label setters and run only `_pose_avatar`; equality early-outs on the setters | `--capture=popin` (zero VANISH/APPEAR, fewer >100 ms frames), `--capture=population` |
| 10 | `gameplay/placed_light.gd:172–199, 240–247`; `placed_mover_light.gd:264–297`; `placed_string_light.gd:277–282` | Per light per frame: `material_overlay` + `collision_layer` written unconditionally, `_sound_beat = {}` alloc, `parse_color(str)` per frame on movers, array literal per frame on strings | Write gizmo state only on change; parse colour/effect once in `_apply_fields`; const empty dict | `--capture=lights` (23 checks) |
| 11 | `system_graph/graph_dashboard_panel.gd:98–103` | `refresh(true)` at 5 Hz runs BEFORE the `is_visible_in_tree()` check: power/closure every 0.2 s with the graph closed | Move the visibility check above the refresh; force one refresh on `visibility_changed` | `--capture=graph` dashboard shot; `flow_step_bench` graph-closed sections |
| 12 | `scenes/ui/solar_ui.gd:3862, 2090–2107, 3897–3910` | `get_nodes_in_group("energy_sources")` at 10 Hz; two long-path lookups and a root-children walk when TimeUI is absent (no negative cache); theme overrides on a hidden panel | Cache the group list (invalidate on tree change), remember TimeUI is missing, gate display writes on visibility | `energy_balance_probe`, `--capture=sitebalance` |
| 13 | `system_graph_view.gd:15866, 15906, 18033`; `resource_flow_engine.gd:3742` | `duplicate(true)` BEFORE the change gate at 10 Hz with the graph open; `_processor_has_power` deep-copies specs to read one key | Compare first, duplicate only when writing; shallow copy in `_processor_has_power` after confirming `migrate_processor_specs` only touches top-level keys | `flow_step_bench` hash unchanged; `resource_flow_selftest` |
| 14 | `scenes/ui/fun_meter.gd:96, 136`; `core/population/peak_beacon.gd:157`; `vegetation/camp_light_pool.gd:104`; `graph_soi_preview_service.gd:1650` | A StyleBoxFlat allocated per draw; arrows redrawn with no beacons; settled lights rewritten; a layout-key string built per frame | Cache the stylebox and redraw only while the needle moves; redraw once on transition to empty; skip settled writes; compare raw values | festivalmode / lights captures |
| 15 | `system_graph/graph_soi_preview_service.gd:1349 vs 1771–1894` | `_container.stretch = true` while `_viewport.size` is written by hand → `SubViewportContainer` resizes the viewport to the container every frame and `MAX_VIEWPORT_PX` / `MAX_SECTION_VIEWPORT_PX` are probably dead | MEASURE first (print `_viewport.size` on a 1920×1080 Globe); if confirmed, drive the cap through `stretch_shrink` or turn `stretch` off and position the texture rect | `site-review --review-sets=site,elevation,globe` (disc 0.00 px, cap PASS) |

Also from the August perf tiers that were never built (measure with the F3
HUD on Walton before choosing): distance-culled static prop colliders
(~5k on the heavy maps), MultiMesh merging of identical placed props, a
prop-tick scheduler so solar trackers do not each run Meeus per frame with
no distance gate, and a low-quality foliage shader path for the GPU-bound
Walton frame (~28 ms GPU, scene not crowd).

## Push 2 — bug fixes

Ordered by player impact. Each names the harness that currently shows it.

1. **Hero pop-in / frame spikes at 60x on Walton** (`--capture=popin`: one
   40 m JUMP during a 131 ms frame, 61 of 529 frames > 100 ms). The user's
   stated goal is zero pop-in. Push 1 #9 and the bridge's time-budgeted
   slices should take most of the spikes; then find the jump's cause from
   the probe's record dump (a hand-off during a long frame → the eased glide
   must start from the drawn position even when the slot was rewritten in
   the same frame). Gate: `popin` reports 0 VANISH / APPEAR / JUMP.
2. **Personal-space FAIL on Mount Vernon** (`--capture=population`, `npc_2`
   and `npc_7` idle 0.09 m apart). Suspects: two idle agents dealt the same
   `SpaceRegistry` standing slot, or the idle-at-camp fallback returning one
   point. Reproduce in `npc_population_selftest` with the camp's seed, then
   fix in `SpaceRegistry.slot_jitter` / `_slot_at`. Gate: population 22/22.
3. **"Lambda capture at index 0 was freed" ×61** (`--capture=microclimate`
   on Walton, right after a placed-prop rebuild). A signal still connected to
   a lambda capturing a freed node. Find it by wrapping the prop rebuild in
   a diagnostic that lists `get_signal_connection_list` entries whose target
   is a lambda; the usual culprits are `visibility_changed` / `tree_exited`
   hooks on prop children. Replace with `Callable(self, "_fn").bind(...)` or
   disconnect in `_exit_tree`. Gate: 0 engine errors in that run.
4. **Possessed agent stalls its claimed chore** (labour-merge note). On
   possession, release the agent's chore claim (`NpcChoreBoard.release` for
   that id) so the crew re-forms; re-claim is the planner's job on release.
   Add a check to `npc_population_selftest`.
5. **Penstock harness: 2 world-driven FAILs** on Stream 2. (a) the fillet
   check should skip legs shorter than the pipe's bend radius (the router
   already fits the biggest arc that fits; the CHECK is wrong, not the pipe)
   and print the leg; (b) the stream rung loses to another rung at that
   spot: dump the ladder at the harness's aim point and decide whether the
   stream rung belongs above water bodies when the ray is within 2 m of a
   centreline. Gate: `penstock` green on mtvernon.
6. **Festival sim calibration** (from the refinement notes, all measured):
   the full tier eats ~2.5 kg/person/day against the 1.5 preset (a second
   meal inside one EAT block — `serves_once` exists for festival routines,
   extend it to `default_day`); camp stores are not resized when the
   population target changes (`sync_camps_from_placement` should rescale
   supply tanks with the headcount); restroom banks queue in lockstep at
   routine boundaries. Gate: `crowd_cohort_selftest` equivalence pins,
   `--capture=festival` L/person/day.
7. **Vegetation ignores the lens environment's ambient** so a canopy prints
   black in the Globe at night (soi-stage-lenses note). The veg shaders take
   main's ambient; have `_sync_lens_env` push the lens floor into
   `veg_sky_fill` (via `SoiService.set_preview_vegetation_look`) for the
   capture. Gate: site-review globe set at a night hour.
8. **Player-drawn stream channels do not clear vegetation** (water-network
   note). `ChannelCarver` footprint → `AutoVegetationEdits.patches` clear on
   commit, same as a Level pad does. Gate: `--capture=water`.
9. **A catchment wired straight to a siphon idles silently.** Add a fault
   reason (`GraphNodeState`) and an education card. Gate:
   `resource_flow_selftest`.
10. **Cheat-sheet "known issues" that are stale**: the C-key charge poll
    (player.gd:1619 is event-driven now), the climelapse bake button
    (handler removed on purpose), the placed-props hotkey (`placed_props_edit`
    is bound). Fix the doc, not the code; `input_map_selftest` guards the
    binding.

## Push 3 — easy-win features

Small, self-contained, each already has the data it needs.

1. **Clickable legend toggles** on the graph's show-only chip and the soil
   key (graph-tools note "not built"): one `_gui_input` per legend row
   flipping the matching `GraphDomainFilter` tick. Half a day;
   `--capture=graphtools`.
2. **Place a prop or stream intake AT a POI pin** (the user's next ask after
   the KML import): Site Plan click on a pin → the same "Place it here"
   offer the Connect tool makes; prop editor gets a "Snap to pin ▾". A day;
   `--capture=poi`.
3. **Headcount slider in the camp Edit tool** (festival-mode note): the
   record key exists (`headcount`), the sync is idempotent; one SliderSpinRow
   in the CAMPS Edit options. Half a day; `--capture=camps`.
4. **WATER toolbar hotkey** (no key today): action `water_tools`, physical
   keycode checked by `input_map_selftest`; `toggle_section` already
   switches sections. An hour.
5. **Settings reachable from the launch hub** (game assessment): the
   settings modal is a `UiFit` modal already; add a gear button on the hub
   header that opens it with the world-dependent pages hidden. Half a day;
   `--capture=modals` at 720.
6. **Key-rebind page** in Settings: parse `project.godot [input]` the way
   `input_map_selftest` does, list actions with their event labels
   (`HarnessInput.action_label`), capture a key on click, write
   `user://input_overrides.cfg` applied in `CursorController._ready` through
   `InputMap.action_erase_events` / `action_add_event`. Two days; the F1
   help overlay and tour title cards already read keys off the InputMap, so
   they follow for free.
7. **Ambient audio in first person** (game assessment: "near-silent"): a
   wind bed scaled by `WeatherService` wind speed, rain layer from
   `rain_rate_mmh`, birdsong gated by `DaylightModel` and forest proximity
   (`VegetationLayer` density under the player), stream rush from the nearest
   `StreamNetwork` feature's Manning velocity. Procedural noise + the
   shipped `.mp3` policy (user-provided files under `user://`). Two days;
   `stage_beat_selftest` style offline checks for the mix rule.
8. **`--capture=popin` asserts** instead of reporting (after Push 2 #1).
9. **Site Report PNG export** of the cards (`get_viewport().get_texture()`
   of the panel's SubViewport, or `Image` from the modal's rect). Half a
   day.
10. **Per-camp "Watch" from the camp card** on the graph → the settlement
    view over that camp (the project panel already does this per project).

## Push 4 — hygiene (one slice per push, never a big bang)

- **ServiceLocator sweep**: replace the 28 `"UILayer/SystemGraphView"`
  lookups with `ServiceLocator.graph()` (20 files, mechanical). Then add a
  guard to `ui_compile_selftest` or `services_selftest` that FAILS on any new
  `"UILayer/SystemGraphView"` literal outside `services.gd` and the harness
  probes, so the convention enforces itself (the August sweep regressed
  because nothing did).
- **Monolith extraction, one responsibility each**: from
  `system_graph_view.gd` lift the hydro helpers (`resolve_hydro_source_at`,
  `route_penstock_to_source`, `_remove_existing_penstock`, `find_uphill_source`,
  `hydro_source_summary`, `tap_stream_for_turbine` — ~1.5k lines, already a
  cohesive seam) into `system_graph/graph_hydro_routing.gd`; from
  `terrain_loader.gd` lift the snow / litter / moss / growth-year uniform
  push into `core/terrain/terrain_season_push.gd` (this is also Push 1 #2).
  Gate: the hydro captures and `--capture=veg` / `growth`.
- **Delete the TEMP dev layer** `core/education_card_overrides.gd` after
  folding its text into `GraphEducationCards`.
- **Stale comments**: `packing_lab_modal.gd:17` (persistence + LIFO landed),
  `linkage_part_keys.gd:714` (A4 landed), the "landed uncommitted" memory
  notes, the cheat-sheet rows in Push 2 #10, HARNESS_MATRIX's cleaned-data
  bullet.
- **Privacy**: the 2026-10-14 `tour.mp4` still shows the site address at
  5:43. Re-record with `tools\tour.ps1 -Mode record` (SitePrivacy is on for
  every harness run now) before anything is published.

## Explicitly not in this pass (needs a decision)

- HACS integration migration (ROADMAP Pillar 5) — architecture call.
- v1/v2 graph canvas merge — a week, no player-visible gain.
- Full ISRU catalog / PBI vision — a feature arc, not a pass.
- NEC conductor/OCPD checker — a feature arc.
- Perf Tier 2 collider culling / MultiMesh merging — only after Push 0's
  F3 reading on Walton says the CPU side is where the frame goes; the last
  measurement said GPU.

## Sequencing

| Push | Days | Ships when |
|---|---|---|
| 0 measure | 0.5 | first-person bench prints baselines on both worlds |
| 1 perf | 2–3 | bench medians down, flow-step hash unchanged, matrix green |
| 2 bugs | 2–3 | population / penstock / microclimate / popin green |
| 3 features | 3–4 | one capture per feature, tour stop for the player-facing ones |
| 4 hygiene | 1 per push, folded into 1–3 | guard selftest exists |

Commit per push (imperative subject, validated-by note), full
`tools\harness_matrix.ps1` before each.
