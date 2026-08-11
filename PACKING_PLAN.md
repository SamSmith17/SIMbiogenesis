# Packing & Deployment Plan ("3D Tetris")

Vision: every physical thing in the game knows its **packed dimensions** — how
small it gets when folded, disassembled, stacked, or crated for transport — and
the game grows a packing/unpacking layer good enough that a real Burning Man
camp could use it to plan a U-Haul load. Gameplay arcs: (a) *unpack a
pre-designed system* from a shipping container and learn it by deploying it,
(b) *design for packability* — elegant space-packing as a first-class design
constraint alongside watts and litres.

Guiding order: **data first, report second, interaction third, scenario
content last.** Each phase ships something independently useful and each has an
offline selftest per project convention.

---

> **Status 2026-08-03:** Phase 0 + the Phase 0.5 simple fix LANDED —
> `core/packing/packed_spec.gd` (resolver + curated table + coverage guard +
> mass heuristics), `LinkageStructureBuilder.packed_spec_for` (envelope at
> effective min fold, cached), modal fold-slider clamp + Packed Size/Wt stat
> rows, `core/packing/packing_selftest.gd` (236 checks, in CLAUDE.md).
> Display lines LANDED too: library item-button tooltip ("Packs to: … · …"),
> inspector "Packed (shipping)" section (short ft/in form — the value column
> clips the metric-parens string; "· estimated" marker on the section title),
> prop-edit drawer 📦 line (linkage props compute from the live linkage_spec).
> Phase 0 is COMPLETE. Phase 0.5's collision-aware min fold NOT built.
>
> **Phase 1 LANDED (2026-08-03):** `core/packing/container_catalog.gd`
> (16 real volumes — U-Haul fleet dims/doors/payloads fetched from published
> specs, ISO 668 containers, GMA pallet, camp totes/drums; door-aperture
> `fits_through_door`, `packed_spec_for` = exterior+tare) +
> `core/packing/cargo_container_builder.gd` (procedural placeable ISO box,
> ModelCatalog id `cargo_container`, dims from the catalog so geometry and
> packing data can't drift; NOTE Godot front faces are CLOCKWISE — CCW
> winding renders every wall as a culled backface).
>
> **Phase 2 LANDED (2026-08-03):** `core/packing/pack_solver.gd` (greedy
> extreme-point, deterministic, door/support/this_side_up/payload aware;
> largest-first means constraint tests must force ordering or the solver
> legally rearranges around them) + `core/packing/camp_manifest.gd` (pure
> graph+prop sweeps, qty merge, fleet report smallest-first; >20 kL tanks
> skipped as site infrastructure) + the Site Report "📦 Packing & Logistics —
> will it fit?" card (live at open, outside the cached pipeline). NOT yet
> eyeballed in-game — open 📊 on a populated site.
>
> **Phase 3 LANDED (2026-08-03):** `core/packing/pack_tree.gd` (nested unit
> trees, innermost-first solve, outer envelope = exterior+tare+contents mass,
> oversize contents ESCAPE loose to the parent scope instead of failing the
> load, depth guard) + `core/packing/pack_defs.gd` (reusable kits as UNIT
> LISTS — a def is a list because real kits split across handling units: the
> 18-panel stack physically can't share a 2' crate with the frame; builtin
> starshade_kit + solar_starter_kit, def_ref splicing with cycle guard,
> user://pack_defs.json store) + `crate_8x4` sub-container. Def capture from
> live world state deferred to the modal phase. Selftest now 398 checks.
>
> **Phase 4 v1 LANDED (2026-08-03):** `scenes/ui/packing_lab_modal.gd` — the
> interactive 3D Tetris: cutaway container studio (self-hiding walls, door
> marker at the high-z end so auto-packs read nose-first), Auto-pack seed,
> manual ghost placement validated by THE SOLVER'S OWN primitives (a hand
> placement is legal iff an auto placement would be), click-to-remove, kit
> loader, live fill/payload/CoM stats + trailer tail-heavy warning. Entry:
> Site Report card button (preselects smallest fit) + `--capture=packing`
> harness (5-shot visual review, verified). Overflow lines in the report
> card now NAME the offending items. v1 deferrals → later phases: per-site
> layout persistence, sub-container drill-in, LIFO unpack-order warnings
> (needs deploy-priority data, pairs with Phase 6 scenarios).
>
> **Phase 5 v1 LANDED (2026-08-03):** PACKED ⇄ DEPLOYED world states.
> `packed: true` on a prop record makes PlacedPropRuntime build the honest
> packed form instead of the model (`core/packing/packed_form_builder.gd` —
> form-styled crate/bundle/panel-stack/pallet/tank/folded silhouettes from
> the PackedSpec, primitive meshes so no winding traps; yaw-only USER-scale
> transform — the catalog's GLB unit-compensation scale must NOT apply; no
> behavior runtimes, no connection ports). Interact on a crate = unpack in
> place; "📦 Pack up"/"Unpack" in the prop edit drawer (packing never
> hijacks a deployed prop's Interact — linkage fold etc. own it). Loader
> `set_prop_packed` persists + rebuilds + stows/unstows linkage graph
> arrays (unpack restores fold-state truth, not blind un-stow). v1
> deferrals: NPC unload/deploy labor chores (Phase 6), crates inside world
> containers. In-world pack/unpack flow needs a human playtest pass.
>
> **Packed-generation gap CLOSED (2026-08-03):** `specs.packed_3d` is the
> one flag every producer gate reads — set/cleared by
> `SystemGraphView.set_item_packed_3d` (called from `set_prop_packed` for
> any prop bound via `graph_item_id`). Gates: renewables tick (wind/hydro
> kw = 0), CSP + heliostat ticks (empty result dict zeroes all telemetry
> via the .get defaults), and `ResourceFlowEngine._processor_switched_on`
> (one guard covers every processor path — a crated machine can't run,
> whatever the switch says). **The electrical layer is CLOSED too**
> (verified 2026-08-11 — this note previously said "still ungated" and was
> stale): `PvElectrical.unit_voc` returns 0 for a packed panel,
> `GraphDcElectrical.is_packed` gates bank formation, controller liveness
> AND the current-throttle wattage (all selftest-pinned in
> `graph_electrical_selftest._test_packed_gate`), and the SolarUI capacity
> aggregate skips packed panels. The display sums followed 2026-08-11:
> battery kWh / controller max-PV watts / average bank SOC skip crated
> items, while COST keeps counting them — you own a crated battery, it
> just isn't wired.
>
> **Phase 6 v1 LANDED (2026-08-03):** `core/packing/unpack_scenario.gd` —
> delivery scenarios spawn as REAL world state (container prop + one
> `packed: true` prop per unit, staged in rows off the door end), so the
> Phase 5 loop IS the gameplay and `progress()` just counts records; no
> bespoke scenario state machine. Builtins: `starter_camp` (7 crates —
> shelter/shade/power/water/food) and `starshade_kit` (a linkage crate
> carrying a real default v30 design). Entry: Packing Lab "🚚 Deliver kit
> to site" (spawns 14 m ahead, door facing the player, crates staged
> between); loader API `deliver_packed_kit`. Goal-judging via the
> TutorialGoals pattern + strike-the-camp reverse challenge remain.

## Phase 0.5 — LinkageLab honest fold limit (prerequisite for computed dims)

The computed packed envelope is only as honest as the minimum fold angle, and
today the Lab lets a design fold through itself: the fold slider's floor is a
hardcoded 5° (`linkage_lab_modal.gd` `_fold_slider.min_value`), below the
physical limit, so brackets / outer V-beams intersect impossibly and the
apparent shipping dims come out smaller than reality.

What already exists (don't rebuild): `LinkageParams.min_fold_angle_deg` (user
override, round-trips v30 `minFoldAngle`), `LinkageKinematics.
min_fold_angle_v_overlap` (computed adjacent outer-V-beam contact),
`effective_min_fold_angle` (override-else-computed), and the deploy runtime
already stows at that angle. The modal even has the override SpinBox.

- **Simple fix (Phase 0, done with the packed-envelope work):** clamp the
  fold slider/spin floor to `effective_min_fold_angle` live (re-clamped on
  every param rebuild), and compute the packed envelope AT that angle — never
  at whatever the slider shows. The user override remains the escape hatch
  for designs whose real hardware folds tighter or looser than the model.
- **Better fix (later, own phase):** collision-aware minimum fold — OBB
  overlap sweep over the SOLVED beams + brackets (binary search for the
  tightest non-intersecting angle, same pattern as `min_fold_angle_v_overlap`
  but geometric, covering bracket-bracket and stacked-beam contacts the
  tip-gap heuristic misses). Pin reference configs in `linkage_selftest.gd`.
  Until then the V-overlap heuristic + user override is the contract.

## Phase 0 — `packed_spec`: the data model (foundation, no gameplay)

One schema, attached to anything that occupies space:

```gdscript
packed_spec = {
  "w_m": 1.22, "d_m": 2.44, "h_m": 0.45,   # packed envelope (metres internally,
                                            # display ft/in like PalletRackBuilder)
  "form": "crate",        # crate | bundle | roll | pallet | loose | container
  "mass_kg": 120.0,       # FIRST-CLASS from Phase 0 (decided 2026-08-03):
                          # curated where known, else estimated (estimator
                          # heuristics per type: W/kg for panels, Wh/kg by
                          # chemistry for batteries, wood density × beam
                          # volume for lumber builds); NAN only when no
                          # heuristic applies. Needed later for tongue
                          # weight / stack limits / labor cost.
  "stackable": true,      # may support weight on top
  "max_stack_kg": 200.0,  # optional
  "this_side_up": false,  # orientation lock (batteries, liquids)
  "count": 1,             # one deployed thing may pack into N units (panel stack + rack)
  "source": "measured" | "estimated" | "computed",
  "contains": [],         # Phase 3: nested pack units
}
```

Where it lives (three producers, one resolver):
1. **ModelCatalog entries** (shipped + user GLBs): optional `packed` key per
   catalog entry; curated values for shipped models.
2. **ComponentPresets specs** (graph nodes with physical twins — panels,
   batteries, controllers, tanks): a `packed` block in `specs`, so a 100 Ah
   battery knows it's a 0.33×0.17×0.22 m 12 kg box straight from the preset.
3. **Procedural builders compute it** (`packed_spec()` on the builder):
   - LinkageLab: solve at the closed fold angle → real folded envelope
     (the ~4'×8'×1–2' number falls out of the solver, parametrically correct
     for every design). `source: "computed"`.
   - PalletRackBuilder: uprights bundle + beams bundle + plywood stack —
     computed from part counts. GrowBed / dome / pipe-kit similar.
   - ScadStore parts: printed parts' bounding box IS the packed box.

**Resolver + estimator** (`core/packing/packed_spec.gd`, pure static):
`PackedSpec.resolve(model_id_or_specs)` returns curated → computed → estimated,
in that order. The estimator derives a plausible packed box from the deployed
AABB by form heuristics (rigid box ≈ deployed size; anything tagged foldable /
frame-like gets a ratio) and marks it `estimated` — so coverage is 100% on day
one and curation is incremental, never blocking.

UI (cheap, immediate value): library cards + inspector + prop-edit drawer show
a "Packs to: 4' × 8' × 18" (est.)" line.

Selftest `core/packing/packing_selftest.gd`: every catalog model and every
physical preset resolves a spec; dims positive; packed volume ≤ deployed
volume; LinkageLab computed envelope pinned against known reference designs.

## Phase 1 — Container catalog (the target volumes)

Pure data (`core/packing/container_catalog.gd`): real interior dims + **door
aperture** (a thing must fit through the opening, not just the volume) +
payload for the vehicles camps actually use:

- Pickup bed, cargo van, 10'/15'/20'/26' U-Haul box trucks
- 5×8 / 6×12 cargo trailers (+ tongue-weight note)
- 20' / 40' shipping containers (the classic camp storage)
- Sub-containers: 48×40 pallet, 27-gal tote, action packer, job box, 55-gal drum

Plus a placeable **container prop** (procedural box with door face, or GLB) so
a shipping container can stand in the world. Data-only selftest additions.

## Phase 2 — PackSolver + "Will it fit?" report (utility before fun)

`core/packing/pack_solver.gd`, pure static, deterministic, offline-testable.
3D bin packing is NP-hard — do NOT chase optimal. A greedy
**extreme-point / largest-first heuristic** with 90° orientations and
constraint filters (this_side_up, stackable, max_stack_kg, door aperture)
gets 70–85% utilization, which matches how humans actually pack. Returns
placements (transforms), fit/overflow list, utilization %, and center of mass
when masses are known.

**Camp manifest:** sweep the SoI — placed props + graph physical twins —
resolve every `packed_spec`, run the solver against a chosen container:
> "Your camp packs into one 15' U-Haul at 78% (est.), tongue-weight OK."

Surface it as a card in the Site Report (📊) — the report pattern already
exists. This is the killer real-world hook, shipped *before* any interactive
3D packing exists.

Selftest: known-answer packings (N unit cubes into a k-cube), constraint
refusals, determinism (two runs byte-identical), door-aperture rejection.

## Phase 3 — Nesting: boxes within boxes

`packed_spec.contains` makes any pack unit a container scope. Model it as the
graph models super-nodes:

- A **pack tree**: container → crates → totes → items. Solver runs per scope,
  innermost first (a packed tote's outer envelope is what the truck-level
  solve sees).
- **Pack definitions** mirror `GraphComponentDefs`: a curated packed kit
  ("StarShade kit: one 4'×8'×2' crate containing frame bundle + panel stack +
  hardware tote") is a reusable definition, stampable, revisable, persisted to
  `user_presets.json` alongside component defs. The graph component def and
  the pack def for the same system should reference each other — one system,
  two views (electrical topology / physical packing).

Selftest: nested resolve (inner solve feeds outer), cycle guard, def
round-trip.

## Phase 4 — Interactive packing UI (the Tetris)

Modal in the LinkageLab / building-builder pattern: SubViewport studio,
container shown cutaway, right sidebar = manifest list of remaining items.

- Grid-snapped ghost placement (reuse ghost/placement idioms), 90° rotations,
  support rule: everything rests on floor or a `stackable` surface.
- **Drill-in for nesting** exactly like graph compound zoom: enter a tote,
  pack its interior, pop back out — same mental model the player already has.
- Live feedback chips (UITheme): utilization %, center of mass vs axle/tongue,
  **unpack-order warnings** (LIFO: first-needed items buried deepest get
  flagged), overflow list.
- "Auto-pack" button = Phase 2 solver seeds the layout; the player improves it
  by hand. Auto vs hand is itself the design lesson.
- Undo per project pattern; state persists per site
  (`user://maps/packing_<lat>_<lon>.json`).

Windowed harness: `--capture=packing` (open modal, auto-pack, one manual
move, shoot PNGs + diagnostics.json).

## Phase 5 — World integration: PACKED ⇄ DEPLOYED

Placed props gain a pack state:
- **PACKED** renders as the packed form (crate/bundle mesh from `form` +
  dims) — on the ground, or inside a world container prop.
- Interact on a crate → unpack → existing ghost placement flow → DEPLOYED.
  Repack: prop collapses back to its crate. LinkageLab structures get a third
  state past "stowed": fold (existing runtime) → then crate.
- Graph consequence: packed = stowed (`set_imported_array_stowed` pattern —
  node + wiring survive, zero contribution). A packed camp is a full graph
  producing nothing: the design survives transport.
- **Labor cost:** unpack/deploy time per unit (mass- and size-scaled), fed to
  the NPC **chore board** — "unload truck" becomes a real chore NPC crews
  work through, weather-gated like everything else. Deployment speed becomes
  a measurable property of a design.

## Phase 6 — The "unpack a system" gameplay stage

`.esim` site packages extended with pack state: a scenario ships as *a
container standing on the site with everything inside*. The player opens the
door and learns the system by physically deploying it.

- Goal-driven via the `TutorialGoals`/`TutorialCatalog` pattern: "Unpack and
  wire the 1.2 kW starter kit before nightfall" — predicates over pack state +
  graph topology + clock.
- Each crate is labeled; unpacking reveals the component AND its graph node —
  learning-by-unboxing, the physical mirror of the Solar Bootcamp.
- Reverse challenge: **strike the camp** — repack everything into the same
  container before the deadline (exodus!). Score: time, labor-hours, trips,
  utilization.

## Phase 6.5 — Emergent group logistics (rules, not avatars) — VISION + first primitive

> **STATUS 2026-08-06 — the primitives are now a PLAYABLE LOOP ("Site
> Projects").** Chore completion finally has world effects: an `effect`
> payload on a chore is dispatched exactly once by
> `NpcPopulationBridge._dispatch_chore_effects` (fire-once `effect_done`
> flag persisted with the chores). Deliveries spawn crates AT the container
> door with staging slots stamped on each record; per-crate haul chores make
> NPCs walk crates over visibly (two-leg `chore_leg` carry FSM, carrying dot
> payload + carry box on both body styles + Site Plan square marker — the
> "items flowing along a line" payoff image below is now real, per-crate
> round-trip form; station-to-station brigade item flow still pending).
> The Linkage Lab's queue-build creates a `SiteProject`
> (core/population/site_project.gd + store + effects): the ghost structure
> GROWS at the build site with real labour
> (`LinkageStructureBuilder.set_build_progress`), the erect phase's
> unpack effect plays the deploy sweep as the raise, panels seed the graph,
> and a reverse breakdown project (strip → unbolt → fold/pack → load-out)
> closes the loop. Player surface: `scenes/ui/site_project_panel.gd`
> (phases, planned-vs-live Gantt strip, pause/cancel, what-if crew table).
> Verified end-to-end by `--capture=project` (CLAUDE.md validation list).
>
> **ROUND 3 (2026-08-07) closed the deferred list.** Deliveries now **stow
> inside the container**: `UnpackScenario.stow_plan` runs `PackSolver` over the
> scenario's real PackedSpecs (every item forced `this_side_up`, since a
> spawned crate is a BoxMesh with yaw and only two of the solver's six
> orientations are renderable), and `spawn()` places each crate at its solved
> position with `y_offset = pos.y` exactly. Crates come back out **LIFO**
> (highest top first, then nearest the door) — one sort that the brigade's
> stage-effect index and the round-trip rows' ascending priority both inherit.
> Two rules keep it honest: a `move_prop` always un-stows and re-grounds, and
> `set_prop_packed` refuses to deploy a crate still inside the box. The
> **teardown is now visible** (`SiteProject.breakdown_progress`): panels strip,
> then bolts and brackets leave together, then the supports and the ghost fade
> into the fold sweep — with the beams deliberately standing throughout,
> because the fold IS their visual. And the **experiment lab**
> (`core/population/npc_experiment_lab.gd`) answers the question the pure
> scheduler cannot: it re-runs the real population sim over the same task graph
> under ~15 variants (crew sizes, night shift, long shifts, crew caps, window,
> forced haul strategy) and reports actual makespans with needs, morale,
> weather and daily windows included. It never touches the bridge, re-rosters
> every variant so the comparison is fair, and states its limits in the panel
> (fresh crew, frozen weather, straight-line routes, 15-minute resolution).
> Still open: opening/hollowing the container mesh so the stack is visible
> in-world, a real rigged carry clip (asset-blocked — the loader is prepped),
> and an MP guest project panel.

Direction (user, 2026-08-03): the gameplay ideal is modeling emergent GROUP
behavior — the player doesn't drive one POV character, they author rules and
goals for the whole roster, and complexity arises from simple rules
interacting. First concrete behavior: the **bucket brigade** — people
spontaneously forming a relay chain to move many small items.

**First primitive LANDED:** `core/population/npc_haul.gd` (`NpcHaulModel`,
pure static, selftested in packing_selftest). Two strategies from first
principles — independent round trips (cycle = walk loaded + walk back +
handling) vs a brigade pipeline (stations at spacing L/(N−1); leg = hand-off
+ shuttle beyond arm reach; throughput = 1/leg) — and `best_plan` picks
whichever wins. The EMERGENT results the selftest pins: the strategy flips
with crew density and route length, and a saturated brigade's throughput
becomes 1/t_handoff — route length drops out entirely. Nobody scripts the
changeover; it falls out of two formulas. Surfaced today in the Packing
Lab's delivery readout ("4 ppl → round trip ~75 s · 12 ppl → brigade
~37 s") and bridged toward the chore board via `NpcHaulModel.chore_spec`
(a NpcChoreBoard-shaped dict sized by plan labor, so weather/morale/
productivity scaling applies like any other chore).

**Second primitive LANDED (2026-08-03) — the pit-crew scheduler.**
Direction (user): deployable infrastructure like the StarShade invites
SWARM MANUFACTURING — drilling pivot holes and assembling hardware are
chores too, and usually the FIRST chores; the tool should help large
groups dynamically organize compound tasks like a pit crew, and double as
documentation (visualizing fabrication + assembly, not just packing).

`core/population/npc_crew_plan.gd` (`NpcCrewPlan`, pure static): task
graphs with dependencies + crew limits ({work_s person-seconds,
min_workers — the barn-raising threshold, max_workers — two people per
drill, deps}), scheduled by event-driven critical-path-first list
scheduling with malleable per-event reallocation (the pit crew reshuffles
at every completion). Emergent properties PINNED in the selftest: makespan
never beats either lower bound (critical path, total/N), more hands never
hurt, makespan flatlines at the critical path once the graph's parallelism
is exhausted, and min-crew gates block small crews AT the blocking task.
`recommend_crew` answers "bring 9, not 40"; `timeline_text` renders an
ASCII Gantt for build docs. `linkage_fab_tasks` derives the fabrication
DAG from a design's REAL part counts (cut → drill → assemble ∥ brackets →
bolt → fold-test → raise (min 6) → panels). **Since the hardware/BOM port
(2026-08-04) it consumes `LinkageBom.fab_counts`**: `bom_bolt_count` gives
the analytic bolt total instead of the old ~6/module estimate (which now
only covers hand-authored counts), and `assembly_steps` splits the single
"assemble" task into one per hardware assembly, priced at `T_HW_PART_S`
per physical piece someone has to thread onto a pivot. Passing neither
emits the byte-identical pre-port graph, which a frozen literal in
linkage_selftest guards — the schedules pinned in npc_population_selftest
and packing_selftest ride on it. Surfaced LIVE in the Linkage Lab stats
("🔧 Fabrication — 56 beams · 168 holes · …; 2 ppl — (raise needs 6) ·
6 ppl 3.4 h · 12 ppl …; Best crew N → H h · %busy · bottleneck"), cached
on part counts. `chore_specs` bridges a schedule onto the chore board
(start-time order + descending priority approximates dependencies today;
`depends_on`/`min_workers` carried for the dependency-aware board).

Roadmap for the full vision (each step small and testable):
0. **Dependency-aware chore board — LANDED (2026-08-03).** NpcChoreBoard v2:
   `depends_on` (chore ids; a dep is satisfied when complete for its cycle,
   and a DELETED dep unblocks — removing a chore means "skip that step",
   never a deadlock), `min_workers` (quorum — credit() pays ZERO below it,
   so early arrivals stand at the site and wait; the gathering is emergent),
   `max_workers` (claims stack to the cap; `workers: []` replaced the single
   `worker`), roster filter in available_for (a quorum the roster can't
   meet is never offered), and `add_plan()` (a whole NpcCrewPlan
   chore_specs schedule lands as wired "once" chores — task ids remapped to
   chore ids). Agent side: `_step_chore` gained a bounded quorum-wait
   (QUORUM_WAIT_H 0.5 h, then the normal per-tier retry backoff — the
   quorum wait can never become a livelock); engine ctx carries
   roster_size. Back-compat contract: single-worker chores keep v1
   semantics exactly — credit() without a claim still works (the hybrid
   chore-confirm path never claims first), and v1 serialized boards
   deserialize through .get defaults.
   **The execution loop CLOSED same day:** add_plan takes a `target`
   stamped on every phase (the whole build happens at one site);
   `_chore_position` gained a `{"kind": "pos", x, z}` branch (build sites
   need no prop); the Linkage Lab's Fabrication block gained
   **"👷 Queue build for crew"** (finds the first crewable pop-driven
   habitat via `first_crewable_habitat`, schedules at the REAL roster size
   — an infeasible small roster still queues, ordered by a crew that
   could, and the board's roster filter holds the raise until the camp
   grows; build site = the bound placed prop else the player's feet); and
   the Site Plan draws **crew work-site markers** (`crew_site_markers` →
   `npc_crew_provider` → `_draw_npc_crew_sites`: amber disc + 🔨 under the
   agent dots; sub-quorum = orange "2/6 ppl — gathering" muster, quorate =
   green progress sweep). TO WITNESS: map with a pop-driven habitat → N →
   Queue build for crew → G → Site Plan. Testing note: the bridge cannot
   be referenced from the headless selftest (bare PerfMonitor autoload —
   the documented trap silently aborts the test function while PASS still
   prints); its pos-branch is windowed-verified only.
1. **Brigade STATION formations — LANDED (2026-08-03).** Chores carry an
   optional `haul: {from_x, from_z, to_x, to_z, strategy}`; brigade-strategy
   workers take station POSTS along the route — station = claim-order slot
   over max_workers positions (`worker_index`), so the line forms stably as
   people arrive and never reshuffles under someone mid-walk to a post.
   The Site Plan draws the relay line (amber, endpoint dots) under the crew
   marker. Deliveries are now WORK: `deliver_packed_kit` auto-queues
   "Unload the delivery" on the first crewable habitat (container →
   staging-centre route, strategy + labor from NpcHaulModel.best_plan at
   the real roster size; silent no-op with no population). Item-by-item
   hand-off animation along the line remains future polish.
   **Rule cards v1 — LANDED same day.** `NpcChoreBoard.rules` (persists
   with the chores blob): `night_shift` (windows ignored — work around the
   clock; sleep still preempts, an emergent shift pattern) and `tools_down`
   (no chores offered — rest day/ceremony/strike). UI: "Site rules" row of
   checkboxes in the Routines panel's Chores tab. More predicates slot in
   as one-line gates in available_for.
   **Packing Lab layout persistence — LANDED same day** (the Phase 4
   deferral): hand-packed layouts persist per site|container|kit to
   user://maps/packing_layouts.json on every placement change; restore
   replays rows onto the CURRENT manifest (label + orientation-set match,
   re-validated by the solver's own rules — stale rows just skip).
   `--capture=packing` snapshots + byte-restores the store (vegdock
   write-discipline), verified: file absent again after a capture run.
   **UX unification pass (2026-08-03, post-playtest feedback).** The player
   reported: manual Site Plan switching is clunky, and the plan "renders one
   time of day with no motion" — ROOT CAUSE: a PAUSED CLOCK (dots redraw on
   population ticks, which advance sim time; at time_scale 0 nothing moves
   and the hour never changes, so the plan reads as a frozen snapshot).
   Fixes, all through ONE handoff: `SystemGraphView.watch_site_at(world_xz,
   toast)` — opens the graph, switches to Site Plan, centres the canvas on
   the action (`graph_canvas.center_site_on`, bumping zoom to a
   people-readable scale only when too far out), nudges a paused clock to
   1x, and toasts. "👷 Queue build for crew" now closes the Lab and jumps
   there automatically; "🚚 Deliver kit" closes the Lab (the crates are in
   front of the player in 3D) and toasts through the same channel.
   **Linkage pack/unpack ANIMATES**: packing a deployed structure plays the
   stow sweep first (reversing a deploy mid-flight), awaits the settle, THEN
   swaps in the crate; unpacking swaps the crate for the stowed frame and
   plays the deploy sweep — one continuous motion, never a teleport
   (`set_prop_packed` is now a coroutine; `_pack_anim_in_flight` guards
   double-presses; the sweep's own settle persists pose + graph state).
1b. **(was 1) Live haul execution — remaining polish**: a chore-board entry with `haul_plan` drives
   agents visibly — round-trip mode = existing travel between two targets;
   brigade mode = agents take STATION posts along the route (Vogel-spiral
   slot logic already places arrived agents; stations are the same idea on
   a line) and the pose machine's hand-off loop plays at station cadence.
2. **Rule cards**: player-authored condition→behavior rules at the habitat
   level ("when a delivery arrives, unload it before other chores";
   "nobody works outside in unsafe weather" — the weather gate already IS
   such a rule, hardcoded). The chore board's priority/window fields are
   the substrate; rule cards are a UI + a few predicates over world state.
3. **More primitives**: assembly lines (chained processors + haul legs),
   fire-line (brigade with buckets TOWARD a crisis — crisis_events tie-in),
   harvest sweeps (area coverage), barn-raising (many-hands assembly with
   a superlinear threshold — the social physics of Amish economics).
4. **Observability**: the Site Plan already draws desire lines; group
   behaviors should read there as FORMATIONS (a brigade is a visible line
   of dots with items flowing along it — the payoff image of the whole
   direction).

## Phase 7 — Lofty: the real-world camp tool

> **First slice LANDED (2026-08-11):** `core/packing/pack_manifest_export.gd`
> (`PackManifestExport`, pure static — selftest-pinned in
> `_test_manifest_export`) builds the printable manifest from the Lab's live
> layout: LOAD ORDER sorted nose-first / floor-first (never asks a crew to
> stack onto a box not yet placed; unload = read bottom-up), per-item
> dims/mass/position/THIS-SIDE-UP/do-not-stack notes, the didn't-fit table
> with a door verdict, and totals (fill %, mass vs payload, load-centre
> fraction). Exports CSV + JSON via a FileDialog to `user://exports`
> (LinkageBom guide pattern — no PDF in GDScript). **Custom gear landed
> too**: the Lab's "➕ Item" form (name, dims cm, mass, count, stackable /
> this-side-up) mints an estimated-source PackedSpec, joins the live session
> immediately (append-only — placements reference units by index), and
> persists per site in `user://maps/packing_custom_items.json` so site cargo
> always includes it on reopen.
- Still open: per-layer load DIAGRAMS (HTML/PNG), `.esim` share of a pack
  plan, photo-reference measuring, cut-list-style tote labels,
  multi-vehicle splits ("what goes in the truck vs. the trailer").

---

## Open decisions (flagged, not blocking Phase 0)

1. **Units display** — internal metres everywhere (project convention), but
   the audience thinks in feet/inches; follow PalletRackBuilder's ft/in
   presentation.
2. **Mass coverage** — DECIDED (2026-08-03): mass is tracked from Phase 0 on
   all packable nodes, curated-else-estimated; the report still degrades
   gracefully for items where no heuristic applies.
3. **Physics for crates** — proposal: none. Crates are kinematic props like
   everything else; support rules are solver logic, not rigid bodies.
4. **Where curated packed values live** — catalog JSON vs. per-preset specs:
   both, resolver picks curated first (Phase 0 schema).

## Validation discipline

- `core/packing/packing_selftest.gd` — offline, in the CLAUDE.md list, grows
  with every phase (spec coverage → solver known answers → nesting → state
  round-trip).
- `--capture=packing` windowed harness from Phase 4 on.
- CLAUDE.md gets the standard section + validation entries per phase landed.
