# Harness matrix

Every windowed `--capture` mode, run through `tools/harness.ps1` on the user's
real worlds (Mount Vernon `w6acadacc3baf`, Walton `w6acadacc22ca`, both
`storage: legacy`), each in its own sandbox. The rules are in CLAUDE.md under
"Harness rules".

Re-run everything:
`tools\harness_matrix.ps1`, or `-Modes a,b,c` for a subset.
Each run ends with `HARNESS RESULT …` and a `REAL USER DATA UNCHANGED` hash
check of the real user dir.

## Status: 2026-10-12 (all 47 registered modes green)

| mode | world | result | secs |
|---|---|---|---|
| look | mtvernon | PASS | 56 |
| script (+look chain, dry run) | mtvernon | PASS | 59 |
| packing | mtvernon | PASS | 55 |
| hardware | mtvernon | PASS | 70 |
| autobind | mtvernon | PASS | 50 |
| ambient | mtvernon | PASS | 56 |
| foodforest | mtvernon | PASS | 62 |
| graph | mtvernon | PASS | 63 |
| siphon | mtvernon | PASS | 115 |
| stars | mtvernon | PASS | 56 |
| dawn | mtvernon | PASS | 71 |
| weather | mtvernon | PASS | 76 |
| windowwall | mtvernon | PASS (37 checks) | 60 |
| population | mtvernon | PASS (22 checks, 0 engine errors) | 384 |
| lights | walton | PASS (23 checks) | 67 |
| vehicles | walton | PASS (21 checks) | 58 |
| worlds | walton | PASS | 106 |
| poi | mtvernon | PASS (20 checks) | 52 |
| hydroload | mtvernon | PASS | 75 |
| sitebalance (new 2026-10-12) | mtvernon | PASS (13 checks) | 79 |
| pondid | mtvernon | PASS | 52 |
| culvert | mtvernon | PASS | 50 |
| npcpose | mtvernon | PASS | 84 |
| workui | mtvernon | PASS | 60 |
| npc-anim | walton | PASS | 94 |
| settlement | mtvernon | PASS | 61 |
| labour | mtvernon | PASS | 60 |
| propedit | mtvernon | PASS (20 checks) | 65 |
| tree | mtvernon | PASS | 55 |
| vegdock | mtvernon | PASS | 58 |
| camps | mtvernon | PASS (23 checks) | 69 |
| areafill | mtvernon | PASS | 57 |
| veg | mtvernon | PASS | 74 |
| growth | mtvernon | PASS | 84 |
| water | mtvernon | PASS | 144 |
| penstock | mtvernon | FAIL (the 2 Stream 2 checks green; adoption regression, see Open items) | 87 |
| project | mtvernon | PASS | 96 |
| microclimate | walton | PASS (0 engine errors) | 109 |
| popin | walton | PASS (report only, see below) | 153 |
| crowdbench | walton | PASS (bench numbers) | 79 |
| festival | walton | FAIL 4 (world-driven: the saved festival, see Open items) | 563 |
| festivalmode | walton | PASS (77 checks) | 238 |
| site-review | mtvernon | PASS (compound drill SKIPPED: no compound) | 83 |
| animeditor | mtvernon | PASS (13 checks, real input) | 57 |
| fabswarm | mtvernon | PASS (26 checks) | 59 |
| buildsteps | mtvernon | PASS (25 checks, real input; incl. the Radial Array group on Constellation and the A4 enclosure on Hex) | 78 |
| fabcrew | mtvernon | PASS (12 checks) | 74 |
| both | mtvernon | PASS | 50 |
| timeline (new 2026-10-14) | mtvernon | PASS (0.00 px drift over 236 samples, 720 + 1080) | 70 |
| graphtools (new 2026-10-14) | mtvernon | PASS (29 checks: show-only filter, world drawer, handoff, Globe Connect with real clicks, full-screen globe orbit) | 65 |
| pvsnap (new 2026-10-14) | mtvernon | PASS (8 checks) | 51 |
| conduits (new 2026-10-14) | mtvernon | PASS (13 checks: real-release plug, HUD = run length, live modal, tags, chain) | 52 |
| modals (2026-10-14, strict, 720 + 1080) | mtvernon | PASS (every settings page + conduit_style + connection_ports) | 89 / 106 |
| site-review `--review-sets=site` (2026-10-14) | mtvernon | PASS (cursor zoom drift 2.96 → 0.04 px: one held point per wheel gesture + up to 4 pan-solve passes) | 59 |
| tour (2026-10-13, via `tools\tour.ps1 -Mode stills`) | mtvernon + walton | PASS (32 of 32 stops; 200 renderer engine errors from Bootcamp-after-Hydro-Lab, see below) | 273 + 94 |

A full matrix takes about 75 minutes.

`tour` is the feature tour (see CLAUDE.md "Feature tour"). The registry runs it
on Mount Vernon only. `tools	our.ps1` runs one pass per world: 26 stops on
Mount Vernon and 6 on Walton.

Fixed 2026-10-13, found by the tour: the Solar Bootcamp opening after a Hydro
Lab session flooded about 200 Vulkan renderer errors. Root cause: a lens
applied to the CLOSED graph activated the SoI preview behind it, at a 2x2
placeholder size; on reveal `SubViewportContainer` forced the viewport to
`UPDATE_ALWAYS`. See CLAUDE.md "SoI stage". After the fix, Hydro Lab → Bootcamp
and `graph,siphon` report only the 2 pre-existing JSON warnings.

## Legacy problems found and fixed while getting here

**Harness infrastructure**
- Three drifted dispatch tables were replaced by `HarnessRegistry`.
- Captures no longer race the scene change: one readiness gate runs first.
- Added a watchdog, a real exit code, and one result line per run.
- If the harness script itself fails to compile, the launcher now kills the run
  after 4 s. It used to sit in the map chooser until a 70-minute limit.

**Your saved settings broke tests**
- Your `pop_testing.cfg` guardrails (ideal supply, no departures, …) broke
  population's starvation, collapse and personal-space checks. Test captures now
  reset them in memory.
- Your NPC display prefs (light crowd off, simple body) skewed the festival
  hero-pool check and starved npc-anim of rigged bodies. The sandbox copy is set
  aside for test captures.
- Your star look (trails, dim) was the long-standing `stars` FAIL. The capture
  now uses the shipped look for the run.

**Tests that assumed an empty SOAK world**
- `autobind` deleted every pond. It also passed vacuously on real maps: the bind
  prunes untagged ponds, so the test now uses the world's own pond.
- `penstock` deleted your stream intakes and read "the first intake" as its own.
- `festival` counted your existing camp compounds.
- `siphon` lowered a pond that already has a raised max fill.
- `water` assumed "Show buried" was off; it is on in Mount Vernon.
- `pondid` stopped scanning at the first river line, so it never found its pond.
- `vehicles` sampled the vehicle between physics and render frames.

**Real game bugs**
- **Battery jump on every reload.** A world whose graph battery bank differs
  from the panel config rescaled the saved kWh by a stale fraction (5.09 → 4.12
  on Walton). Fixed in `solar_ui.gd`: the first capacity sync after a restore
  keeps the restored kWh.
- **Lens flights shrank the frame.** Camera3D refuses FOV < 1°, so the SoI lens
  flights' 0.2° dolly shrank the frame about 5× before the ortho switch.
  `SoiStagePose` now draws those poses as an equivalent FRUSTUM.
- **PowerSpout wires never became a penstock.** A hand-drawn wire into a
  PowerSpout or any penstock turbine was stamped `direct_intake` (every hydro
  preset marks its input that way), so it never became the penstock.
  `ConduitKinds` now decides from the turbine kind, and the auto-restyle clears
  a stale stamp.

## 2026-10-12 late: whole-site hydro pass (Mt Vernon)

Re-run after the site-as-one-system fixes (CLAUDE.md "The site as one system"):
sitebalance PASS (new), hydroload PASS, siphon PASS, ambient PASS, graph PASS.
- `siphon` had started failing the micro-Pelton exit-sheet check once the
  siphon turbine was wired to the batteries: the Lab close-up read "output ÷
  nameplate" as the electrical load (3 %). The slider now decides; its 100 %
  default is the matched point a battery regulator holds.
- `hydroload` logged 200 renderer errors per graph reopen on Mt Vernon: the
  SoI preview SubViewport was born `UPDATE_WHEN_VISIBLE` and rendered its 2×2
  placeholder. Born DISABLED now. One transient reflection-probe "scenario is
  null" remains (a probe captured during a water rebuild).
- `penstock` still FAILS 2 checks on Mt Vernon, as in batches 3 and 4 (before
  this pass): "every plan bend of the creek route ≥ the pipe radius" and
  "aiming at the creek focuses the stream". The world's only stream is now
  the user's hand-drawn Stream 2 (Stream 1 is gone), whose short legs cannot
  take the 1.51 m fillet, and the crosshair at the creek finds another rung
  first. World-driven; not investigated further.

- 2026-10-13 (real power system + perspective lenses): `site-review
  --review-sets=site,elevation,globe,siphon` PASS 13/13 (orbited Site Plan
  rings now projected through the camera; POI name tags out of the lenses),
  `hydroload`, `siphon` 4/4, `sitebalance`, `graph` PASS; `penstock` the same
  2 world-driven checks as above (the harness counts the "2 CHECK(S) FAILED"
  summary line as a third). Sandbox probes: the 9S × 380 W array on the
  6000XP passes the new string check (410 V cold vs 480, 255 V hot Vmp vs
  the 120 V MPPT floor), and the prop editor's rack tilt / "Face the
  equator" drive the graph array and SolarUI.

## First-person frame baselines (2026-10-18)

`tools\harness.ps1 -World <w> -RunScript res://tools/bench/first_person_bench.gd`
(graph closed, clock parked at noon, 1x / 60x / paused, every F3 section)
and `… res://tools/bench/gpu_toggle_bench.gd` (the renderer's GPU time with
one feature or scene layer off at a time; `-UserArgs @("--veg-groups")` adds
a per-species batch breakdown; PNGs of the canopy render-mode variants under
`screenshots\gpubench\`). Both at the user's own prefs: 1920×1080 maximized,
render scale 0.5, MSAA 8x, SSAO + SSIL + volumetric fog on, graphics Low.

| world | frame median | render GPU | F3 sections | bound by |
|---|---|---|---|---|
| mtvernon, before | 32.3 ms | 31.4 ms | 3.9 ms | GPU: vegetation 24 ms, MSAA 8x 12 ms |
| walton, before | 45.3 ms | 11.5 ms | 24.7 ms | CPU: population 5.1, host 5.6, nav bake 2.9, raster 2.2, flow 2.2, timeline 1.8, DC throttle 1.5 |
| walton, after the CPU batch | 34.8 ms | 10.9 ms | 18.6 ms | DC throttle 0.4, timeline 1.4, host 4.4 |
| mtvernon, canopy shaders one opaque pass | **23.3 ms (43 fps)** | 22.0 ms | 2.9 ms | still GPU: MSAA 8x is the next 12 ms |

GPU isolation on Mount Vernon (Δ vs baseline): vegetation hidden −23.6 ms
(8 ms, 60 fps); MSAA off −12.4; canopy shaders as alpha scissor −9.0;
scissor + MSAA off −19.2 (14 ms, 60 fps); SSIL / sun shadow / volumetric fog
/ SSAO / glow each ≤ 1.4; every other scene layer < 0.6. Per species the
near-tier Douglas-firs and maples cost 2–3 ms each; the 106 shrubs by the
camera cost 9 ms (overdraw of overlapping alpha cards).

- 2026-10-18 (Push 2, NEXT_PASS_PLAN.md — bug fixes, one commit each):
  - `population` on Mount Vernon 22/22 (was 19/22). The personal-space
    stack was two things: `SpaceRegistry.slot_jitter` was a ±0.35 m SQUARE
    (0.49 m to a corner) over slots 0.855 m apart, so two neighbours could
    stand 0.03 m apart by construction; and the engine's separation pass
    was OFF outright above 120× / 0.1 h ticks, so two people left stacked
    by a coarse catch-up never spread. Jitter is a 0.2 m disc now and
    stationary pairs separate at any speed (travellers keep the gates).
    The marker check counts the capture's own seeded ids (the world's
    extra tagged space made it read "7 of 6"); `space_markers` records
    carry `id`.
  - `lights` on Walton PASS 23/23 (was 2 FAILs + the run stopping there).
    The Walton snapshot carries `festival_mode: true`; the resume reopens
    the settlement view (a CursorController modal) and `InputGuard.blocked`
    swallowed J. The capture now starts from the tour's first-person
    baseline (`_first_person_baseline`), prints the blocker when J fails,
    frames its studio over an open patch of ground (`_lc_open_ground`: the
    saved view had a spot click landing on a 4 m-high surface), clears the
    laser fan's selection before the tube pins and keeps those pins inside
    the patch.
  - `microclimate` on Walton PASS with **0 engine errors** (the 61 "Lambda
    capture at index 0 was freed" did not reproduce at cfbcf64 + Push 2;
    two runs). Left as a watch item below.
  - Possession releases a claimed chore (`NpcPopulationEngine
    .set_controller`, routed through the bridge from `MultiplayerSession`);
    pinned in `npc_population_selftest` (claim released, body left where the
    human has it, re-claimed when handed back).
  - `penstock` on Mount Vernon the two Stream 2 checks PASS (14 other checks red — pre-existing, see Open items). The fillet check reads the new
    `route_short_leg_m` the run stamps (`ContourRouter.short_leg_report`): a
    bend tighter than the pipe is pin-limited, not a routing fault, when a
    leg is shorter than the fillet needs. `pick_stream_at_world` reaches to
    the channel's bank tops (a ray from eye height into a carved trench
    lands on the bank, up to ~3.5 m off the centreline), and the capture
    dumps the whole crosshair ladder at its aim point.
  - Festival calibration: every routine serves a meal / bathroom / wash
    block ONCE (`NpcRoutine.meals_once`; the rest of the block is the
    routine's own leisure kind) in both tiers, and the light tier's dawdle
    now ends at a critical-need crossing as well as the enrichment one —
    without it the cohort pin read 7.8 % (full 127 kg vs light 117 kg of
    food over 3 days); back under 6 %. `sync_camps_from_placement` rescales
    a camp's stores with its headcount (`_sync_camp_stores`, fill fraction
    kept). `--capture=festival` on Walton: FAIL 4 count checks, world-driven (below).
  - Vegetation in the lenses at night: `VegetationEnvironmentSync
    .night_override` — the lens hands the canopy a lifted night factor
    (`LENS_VEG_NIGHT_LIFT` 0.65 × the lens night) while it is the only 3D
    on screen, cleared on close; no shader change. site-review globe set at
    22:00 on Mount Vernon: PASS 4/4, the canopy reads as dark green, not black (no before/after pair shot).
  - A player-drawn or edited stream clears the vegetation in its channel
    (`WaterNetwork._clear_vegetation_on_changed_channels`, bank top to bank
    top + 1 m, painted layer + a persisted auto-veg clear patch; only after
    a `commit()`, never a load-time carve). `--capture=water` on Mount
    Vernon PASS.
  - A catchment wired straight into a turbine is BLOCKED with
    `GraphNodeState.REASON_CATCHMENT_DIRECT` ("Needs a pond" on the chip,
    an education card); `resource_flow_selftest` 345 checks.
  - FEATURE_CHEAT_SHEET.md: the C-key poll, the climelapse bake button,
    the placed-props hotkey and the ToolManager rows corrected (doc only).

## Open items (not fixed)

- **`penstock` on Mount Vernon: the turbine no longer adopts its routed
  penstock** (2026-10-18, 14 checks: "turbine adopted the measured run",
  "the styled 2in SDR-9 bore", "produces from the routed head", "intake
  resolved a live supply", "turbine flows water" …). The run is measured
  and stamped (97.7 m, inverts 36.20 → 3.37) but the turbine's specs stay
  at the typed 100 m / 37.5 mm, outlet invert NAN, 0 W, and the stream
  intake's live supply reads 0 while the Lab's own test flow still makes
  power. A/B'd by reverting Push 2's conduit_manager / resource_flow_engine
  / terrain_loader edits: identical at HEAD, so it came in with 646f533 or
  cfbcf64 (both touched the engine's connection index and sim writes) or
  with the world. The last green record is 2026-10-13. Not investigated
  past the A/B.
- **`festival` on Walton FAILS 4 count checks** (2026-10-18): the world is
  saved mid-festival — 40 camp compounds / 1053 people already on the
  graph, so "24 lots became 11 new camp compounds" (13 of the capture's
  fresh lot ids collide with compounds already there), "the ledger counts
  the lots' people (129 over the 1053)", the water figure divides the
  whole site's draw by the capture's 316 people (144 L/person/day), and
  the vibe starts from the saved crowd. World-driven. Either clear the
  saved festival on Walton (Festival → Leave, Clear seeded, save) or give
  the capture the lights capture's `_first_person_baseline` plus its own
  lot ids.
- **`microclimate` on Walton: the 61 "Lambda capture at index 0 was
  freed" did not reproduce** on 2026-10-18 (two runs, 0 engine errors).
  The population capture logged 2 of them at exit; the one freed-capture
  pattern found — UiFit's `refit` lambda left on the viewport's
  `size_changed` after its panel was freed — is fixed (c8c2f42). Watch
  item: if they return, `HarnessReport` appends the GDScript backtrace
  when the error carries one.
- **`popin` on Walton** reports one hero JUMP (40 m, during a 131 ms frame) and
  61 of 529 frames over 100 ms at 60×.
  - The capture only reports and asserts nothing.
  - The user wants zero pop-in, so this is a performance and hand-off item.
- **Mount Vernon world data that may be leftovers from earlier non-sandboxed
  harness runs** (not touched; ask before cleaning):
  - three packed `linkage_structure` props stacked at (28.5, 32.0);
  - the pond's max fill raised to −78.0 m (basin rim −80.08).
  - CLEANED 2026-10-12 with the user's approval
    (`tools/fixes/mtvernon_hydro_cleanup.gd`, persisted, backup
    `backups/20261012-224614_mtvernon`): two empty "Potable Water Supply"
    tanks (one wired into the PowerSpout inlet), an orphan stream intake +
    prop, a pond self-loop wire; a spillway outlet was added at the
    "Pond Outlet Pipes" pin.
- **`site-review` compound drill is SKIPPED on Mount Vernon**, which has no
  generic compound. To exercise it, build one in the world or add a world that
  has one.
- **Built-in scene boot errors** (road Curve3D up-vectors, string_lights
  `tilts`): see CLAUDE.md "Known pre-existing runtime errors".
