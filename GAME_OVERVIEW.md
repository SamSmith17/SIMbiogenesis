# SIMbiogenesis — Project Overview

*A self-contained briefing on what this game is, what it does today, and where it is
headed. Written to be handed to someone (or something) with no access to the repo.
Snapshot: **2026-08-12**, branch `feat/settlement-work-systems`.*

Companion docs inside the repo: `ROADMAP.md` (vision + pillar status),
`SYSTEMS_GRAPH_VISION.md` (the core-gameplay design doc), `FEATURE_CHEAT_SHEET.md`
(player-facing reference), `ARCHITECTURE.md` (structure + technical debt),
`CLAUDE.md` (the living engineering memory), `POPULATION_PLAN.md`,
`PACKING_PLAN.md`, `UX_IMPROVEMENT_PLAN.md`.

---

## 1. What the game is

**SIMbiogenesis is an in-situ resource utilization (ISRU) simulator disguised as a
first-person exploration game.**

The player picks a **real location on Earth** — a street address, a pin on a world
map, a pair of coordinates — and within seconds is standing inside a 3D
reconstruction of that place, built from live public geodata: real elevation, real
satellite imagery, real building footprints, real vegetation landcover, real
historical and forecast weather for those exact coordinates.

Around that origin they define a **Sphere of Influence (SoI)**: a user-sized,
conceptual open-system volume — atmosphere above, habitable surface, subsurface
below — for which they accept stewardship. Everything inside the sphere is tracked.

Inside the sphere they design infrastructure that harvests **Planetary Basic
Income** — the free, unstoppable, solar-driven flux of **sun, wind, rain and
biomass** that every location on Earth receives forever — and routes it through
real, purchasable equipment into the things humans need: energy, water, food,
materials, fuel, waste recycling.

The thesis the game argues: **the problem is not scarcity, it is integration
efficiency.** Earth has enough sunlight, water and material. What is scarce is
skill at wiring them together. So the mechanics are *ratios*, not unlocks — kWh
per litre of recovered water, kg of plastic recycled per kWh of sunshine, what
fraction of each human need is sourced from inside your own boundary.

And because everything is modelled from cited literature against real weather, the
design can leave the game: export configs to Home Assistant, build the hardware,
link the live sensors back in, and **calibrate the simulation against reality**
until simulated and observed performance converge. Earth is the training ground;
the 100% closure required on the Moon and Mars is the endgame.

> **Elevator pitch:** *Factorio* meets *Google Earth* meets *PVsyst* meets
> *TouchDesigner* — open source, community-owned, Home Assistant-native,
> ISRU-first.

### The two surfaces

| Surface | Role |
|---|---|
| **2D systems graph** (`G`) | **The core gameplay surface.** A schematic node canvas — Grasshopper/TouchDesigner style — of every source, store, process, connection and resource flux inside the sphere. Nested sub-graphs, typed ports, live flow animation. |
| **3D world** | **The embodied digital twin.** Walk the site, sculpt terrain, plant, place real equipment, watch weather and people. Grounds the schematic in a real place. |

Neither is a HUD for the other. The graph owns logical topology; the 3D world owns
spatial truth; nodes and props bind to each other in both directions.

---

## 2. Design goals and principles

These are the commitments the codebase actually enforces, not aspirations:

1. **Real numbers, cited.** Every physics formula carries its literature source in
   a comment (Meeus, Erbs, Duffie & Beckman, Paish, Darcy–Weisbach/Swamee–Jain,
   Manwell, ACSM, ISO 7243, Runions et al., Snyder…). No invented constants, no
   faked curves. Scientists in the audience will check the maths, and the test
   suites pin published example values.
2. **Real places.** No procedural fantasy terrain. The world comes from
   Copernicus/SRTM/3DEP elevation, ESRI imagery, OpenStreetMap, Open-Meteo.
3. **Reversible, deterministic time.** The clock runs forward *and backward* at
   any speed. Anything path-dependent (battery SOC, tank levels, hazards) is
   either a pure function of absolute time or replays out of a recorded buffer.
   Synthetic fallbacks are seeded by absolute time, never `randf()`, so a replay
   reconstructs exactly.
4. **Open source, no lock-in.** Godot (MIT), OSM (ODbL), Open-Meteo, NASA POWER,
   OpenTopography, Nominatim, OpenSCAD. No proprietary API is required for any
   core feature, and no ongoing per-user cost.
5. **Depth is invisible until wanted.** A non-technical player can walk around and
   place a panel; the single-diode model, the NEC-grade wiring faults and the
   observed-vs-simulated NLE are all there when they go looking.
6. **The sphere is open, and partial closure is a valid win.** Earth never
   requires 100% ISRU on day one.
7. **Failure teaches.** Over-volting a controller destroys it *and* opens an
   education card explaining why. Blocking a critical need makes a community fall
   apart on a legible timeline.
8. **Never call the settlement view a "god's eye."** The verbs are *shape,
   schedule, watch* — the player changes conditions, never issues orders to
   people.

---

## 3. Technical shape

| | |
|---|---|
| Engine | **Godot 4.7.1** (Forward+ desktop; GL Compatibility only as mobile fallback) |
| Language | GDScript, ~**653** scripts |
| Autoload services | **37** (data sources, time, save, multiplayer, weather, terrain, cursor policy…) |
| Offline self-test suites | **~70** headless `*_selftest.gd` files |
| Windowed capture harnesses | **28** `--capture=<mode>` scripted playtests that shoot PNG sets + dump numbers |
| Platforms | Windows / Linux / macOS desktop |

**Validation culture is unusually heavy and is itself a design feature.** Two
tiers:

- **Headless self-tests** — pure, deterministic, offline. Physics, terrain maths,
  the flow engine, graph electrical, the linkage solver (pinned 1:1 against the
  original JavaScript app via a Node reference harness), packing, population,
  Discord security primitives, weather hazards, UI compile smoke.
- **Windowed capture harnesses** — launch the real game by CLI, drive real UI
  through real entry points, shoot screenshots *and print the numbers a screenshot
  cannot prove* (fog distance in metres, watts per nozzle size, anchor error in
  inches, whether labour hours moved by exactly the step's hours). These exist
  because the recurring failure mode in this project is code that **renders
  plausibly while being wrong**.

**External data sources:** Nominatim (geocoding), Open-Meteo (archive + forecast
weather, elevation), OpenTopography (SRTM 30 m / USGS 10 m / 3DEP 1 m lidar where
licensed), ESRI World Imagery (aerial drape, up to ~0.24 m/px), Overpass/OSM
(buildings, water, roads, vegetation, solar arrays), NASA POWER (GHI baseline),
CAMS/Open-Meteo air quality (aerosols), NWS/IEM (hazard alerts), Copernicus CDS
(CMIP6 climate projections), Mapillary (street-level reference photos), optional
Google Gemini (opt-in AI ground-texture enhancement).

Everything caches to `user://`, degrades gracefully offline, and secrets
(HA tokens, API keys) live only under `user://` and are never committed.

---

## 4. Play modes and views

### Modes

| Mode | Entry | What it is |
|---|---|---|
| **First person** | default | Walk, sprint, interact via a centre crosshair, ride vehicles, use tools. Survival mechanics optional. |
| **Systems graph** | `G` | The core surface. Four sub-views (below). |
| **Settlement mode** | from project panels / Watch buttons | Second play mode: a real full-screen camera driven by **one scalar** (height 1.7 m → 1200 m), pitch and pan interpolating on log(height), perspective throughout. Watch the community work; edit conditions via a work dock. Never freezes the clock, never issues orders. |
| **Window wall** | F11 / Settings → Window Wall | Optional multi-monitor viewport: the world rendered across a row of physical monitors as if they were windows out of the bus. One eye, one off-axis frustum per monitor (straight lines stay straight across bezels); the game window becomes one monitor and native windows open for the rest. Live wall-clock time, UI hidden, per-map saved viewpoint. |
| **Snowglobe / SoI preview** | graph chip, SoI pin | Live 3D miniature of the sphere. |
| **Drone / FPV** | mount drone | Aerial survey; ortho lock for vegetation editing. |
| **Modal labs** | keys | Linkage Lab (`N`), Packing Lab (`Q`), Hydro Lab, Building Builder (`B`), Site Report (`K`), Parametric part store (`H`), Projection canvas (`I`). |

### Graph sub-views

| View | What it shows |
|---|---|
| **Freeform** | Abstract wiring canvas — the schematic proper. |
| **Site Plan** | Top-down over the SoI disc, nodes at real coordinates; drag 3D props, radial/array placement tools, NPC space markers, desire-line heat maps. |
| **Elevation (CT)** | Half-cutaway vertical section with adjustable slice/heading — how hydro head, culvert inverts and penstocks are actually read. |
| **Hydro Lab / Siphon Lab** | Zoomed 2D cross-section of one water machine with live physics, plus a 3D turbine close-up. |

Each view keeps its **own camera** (zoom/pan/heading/slice), captured at the
switch rather than at every write site.

---

## 5. Feature rundown

### 5.1 Location → playable world

- Geocode an address, click a world map, or type WGS84 coordinates → a
  `MapDefinition` `.tres` is written to `user://maps/` and one reusable shell
  scene is loaded with the coordinates handed over by autoload.
- Elevation is fetched in two layers: a coarse ~30 km base grid and a high-res
  detail patch, seam-composed with adaptive feathering (80–800 m from the
  boundary delta) and vertical offset alignment. Player spawn is gated until the
  composed heightfield is ready.
- Imagery arrives in three progressive layers — base drape, ~0.3–0.5 m/px detail
  patch, then a "hyper" ~0.24 m/px patch — none of which gate the world appearing.
- OSM gives buildings, water bodies, roads, vegetation polygons and existing solar
  arrays. Everything caches per site; a return visit is instant.
- Offline or quota-exhausted → the last good cached DEM is reused; only if nothing
  exists does it fall back to flat ground with a visible warning.

### 5.2 Terrain, buildings, water, vegetation

- **Terrain sculpting** (`T`): raise / lower / smooth / flatten, level a pad, cut a
  ramp, lasso and carve a pond, hold-to-rain / hold-to-drain, measure grade. Edits
  are sparse 1.5 m per-vertex deltas in 64-cell tiles, allocated only where edited,
  rendered as their own hi-res meshes with colliders over the coarse DEM, with
  region-scoped undo and binary persistence.
- **Buildings**: OSM footprints extruded with level eaves on slopes, roofs derived
  from OSM tags (gabled/hipped/pyramid/flat) with real ridge geometry and
  watertight gable fills, procedural siding/shingle shaders, per-building tint. The
  **Building Builder** (`B`) restyles any building — roof shape/pitch/colour,
  wall material modes (lap/trailer/corrugated/plywood/stucco), drop-in facade
  textures, and doors/windows placed by clicking the wall in a live preview. Roofs
  can sample the real aerial photograph via geo-registered UV2. A **Reference** tab
  pulls nearby Mapillary street photos as an eyedropper source.
- **Water**: still bodies get a flat surface at a low percentile of bank heights
  with reflection probes; rivers and streams are draped per-vertex onto the terrain
  so the ribbon follows the contour, with per-vertex flow direction driving
  downstream ripple and foam.
- **Vegetation**: a full procedural forest system. Species catalog with climate
  envelopes, cold-hardiness gates and phenology; broadleaf trees grown by **space
  colonization** (Runions et al.) rather than card fans; real-unit authoring
  (height in metres, crown width, trunk diameter in cm, archetype
  round/spreading/columnar/vase/weeping/conical, four 0–1 character macros);
  seasonal leaf-out, autumn colour, leaf fall particles and a ground litter mask;
  camera-based LOD with in-process baked impostors; a paint dock (`V`) with
  paint/place/clear/select-one-tree tools, per-area fills, and a live "Tune look"
  studio preview that is **provably identical** to the render path.
- **Food forests**: a vegetation area added to the graph summarises the
  food-bearing trees actually standing in it and delivers a year's yield across
  its real harvest window (windows may wrap the new year), gated by tree maturity.

### 5.3 Energy physics

All static, testable, and shared between the 3D world and the graph.

- **Solar**: Meeus solar-position algorithm with Bennett refraction (~0.01°), Erbs
  diffuse decomposition of real GHI into DNI/DHI, isotropic tilted-plane POA, NOCT
  cell temperature, −0.4%/°C derating, optional single-ray 3D shadow test, and a
  year-long shading heatmap decal.
- **Wind**: P = ½ρACpv³ with Betz cap, ISA density altitude correction, log-law
  wind shear, configurable cut-in/rated/cut-out, fed by real 10 m wind.
- **Hydro**: P = ρgQh_net·η with Darcy–Weisbach losses (Swamee–Jain friction),
  monthly flow multipliers from precipitation history, Pelton/Turgo/crossflow
  selection by head band, plus a full unified hydro reach stepper (pond → siphon →
  culvert → outlet) and Pelton nozzle physics (Cv 0.97, optimal speed ratio 0.46).
- **CSP**: parabolic-trough single-axis tracking with the general 1-DOF incidence
  law, Duffie & Beckman end losses, water→steam boil-off, and a dual-axis
  heliostat. The tracker measures its own rest-pose bias from the mesh instead of
  hardcoding it, and slews on both real and sim time so it stays locked to the sun
  at 400× and still eases visibly at 1×.
- **Battery**: a forward integrator with efficiency losses and clamps, made
  reversible by recording SOC into a fixed-step timeline buffer keyed by absolute
  hours — so scrubbing back "uncharges" along exactly the curve it charged.
- **DC electrical layer**: union-find over conductive nets derives bus voltage,
  series/parallel bank topology and mismatch; detects **short circuits** (a closed
  loop with net EMF), **battery over-charge** (PV reachable with no live
  controller and string Voc above the ceiling), and **controller current throttle**
  (P ≈ V_bus × max charge amps). Faults destroy the component, sever wires, and
  raise an explanatory education card.

### 5.4 The systems graph

- **Typed resources** — 31 kinds today: electric, DC electricity, potable water,
  greywater, blackwater, biomass, food waste, manure, plastic waste/shred/flake/
  sheet, finished parts, mud, biochar, soil, hot water, steam, woodgas, food,
  meals, packaging waste, nutrients, liquid fertilizer, biogas, propane, thermal,
  sunlight, wind, money, chore-hours. Players can extend the registry.
- **Library catalog** — ~20 categories: Planetary Basic Income sources, solar
  panels (7 real models), wind turbines, hydro turbines (6, incl. a stream-fed
  PowerSpout), batteries (7 chemistries/formats), charge controllers (10 real
  products), appliances and loads, population, **22 processors**, solar
  concentrators, tools, 24 resource containers, rain catchments, grow beds,
  circuit monitors, breaker panels, super-nodes, and the player's own saved
  components.
- **ISRU pathways now buildable** — RO purifier (1.2 Wh/L), atmospheric water
  generator (300 Wh/L), water distiller (830 Wh/L against a 627 Wh/L latent
  floor), greenhouse grow bed, kitchen, compost digester, biodigesters, biochar
  reactor, woodgas generator, PP shredder → injection molder (closing the plastic
  loop), soil blender, greywater filter.
- **Nested super-nodes / SketchUp-style components** — any compound can be
  promoted to a reusable **definition**; each placement is an instance, edits to
  one propagate to all siblings while per-instance state (battery SOC, HA links,
  3D bindings) survives; "Make Unique" detaches. Definitions persist to a user
  presets file and appear in a "My Components" library category. Built-ins include
  a three-level StarShade tree.
- **Flow simulation** — `ResourceFlowEngine` moves mass across typed ports each
  tick, with scrub-safe tank levels, throughput caps, starvation propagation, and
  **it runs with the graph closed** (an ambient tick) so the world keeps
  simulating while the player is walking around.
- **Closure metrics** — per-need "how much of this came from inside the sphere"
  readouts, surfaced as needs chips on the timeline.
- **UX** — bezier/rounded/metro wire styles, flow-rate-proportional animation,
  marquee series/parallel PV wiring, Voc-ranked controller picker, auto-arrange,
  seamless zoom drill-in with portal pills for promoted ports, history/legend/
  hints, JSON export/import, tiered UI feedback sounds.

### 5.5 Water and hydro as a play loop

A full sub-game: carve a pond, designate the **watershed** that drains into it
(D8 flow accumulation over the real DEM) so real precipitation fills it; run a
siphon or a penstock; size a nozzle; stage culvert outlets that engage in invert
order as the level rises; and read live Q / head / potential-energy on the
Elevation section.

The newest loop is the **stream-fed PowerSpout**: drop a stream intake uphill,
route a poly penstock along the real terrain contour (it bridges gullies too
sharp to follow), and the invert drop *is* your gross head. Supply comes from a
base flow plus a rainfall coefficient, and when the spring runs less than the
nozzle would pass, the physics is honest — the penstock runs partly full and the
surplus head is never converted, so a big jet on a small spring genuinely makes
less power than the head suggests, and the Lab names the nozzle that would match.

The turbine close-up shows the real Pelton runner with the housing cut away, the
jet arriving in the plane of the wheel, and splash derived from the *other half*
of the Euler momentum relation — so a well-tuned wheel visibly dribbles while a
runaway flings water everywhere.

### 5.6 People, work and the settlement

The deepest recent arc. Individual simulated people (10–64), not an abstract
population number.

- **Tag spaces** the player cares about — restroom, kitchen, sleeping, water
  point, shower, plus enrichment types (fire circle, movement, quiet, workshop) —
  on placed props, on OSM buildings, or as drawn ground polygons.
- **Needs and routines**: hunger, thirst, bladder, sleep, hygiene, enrichment rise
  per sim-hour; people follow an editable **daily schedule** (blocks that tile 24 h
  and may wrap midnight), phase-offset per person so the camp doesn't move in
  lockstep, with needs interrupting and the routine being what they return to.
  Consumption is time-averaged so mass is exact at any time scale.
- **Morale** ("Fuck Yes" → "Fuck This"): pressure from unmet critical needs is
  superlinear and **doubled when a need is blocked** — broken infrastructure is
  what breaks a community, not busy people. Needs alone cap morale at 75%; the
  rest is earned at enrichment spaces. Below a threshold people accrue quit
  pressure, leave permanently, and their departure is contagious; past 35% loss
  the colony collapses. What running out actually *does* is authored per habitat:
  strike, leave, or perish.
- **Navigation**: a person-scale 0.75 m walkable grid baked in chunks across ticks,
  hand-rolled A* over packed arrays, slope measured over ±2 cells (so a 1.2 m step
  reads walkable and a cliff does not) with separate per-move step-up/step-down
  limits, cost-aware string-pulling, cached routes jittered only in open ground so
  desire lines have width. Buildings become walls with punched doors — and because
  almost no OSM building has door data, one is deterministically placed facing the
  nearest road.
- **Chores, crews and projects**: a chore board with windows, priorities, crew
  quorums, dependencies and haul routes. `NpcHaulModel` derives round-trip vs
  bucket-brigade throughput from first principles and picks the winner by crew
  density. `NpcCrewPlan` schedules compound task graphs by critical-path-first list
  scheduling with reallocation at every completion — and pins the emergent facts
  (makespan ≥ max(critical path, total/N); more hands never hurt; flatline once
  parallelism exhausts). **Site Projects** unify the whole camp lifecycle: crates
  arrive stowed inside a shipping container, get hauled to staging slots by real
  people carrying real objects, a structure's ghost fills in beam by beam as labour
  lands, it deploys — and the reverse project folds it back down.
- **Labour is real**: a machine recipe step that needs work mints an actual chore
  *at the machine*, so people walk there and the step resumes when they finish.
  The labour ledger became the meter rather than the supply; infinite labour is now
  a difficulty switch, off for new maps.
- **Bodies**: two styles behind one API — a rigged Mixamo character up close
  (handed to the nearest 12 within 45 m) and an articulated stick figure otherwise
  or when the optional art pack is absent. Both are posed by the *same* pure
  state machine, so behaviour cannot drift between them, and gait is rate-matched
  to apparent speed so time-lapse reads as time-lapse rather than skating. Work
  poses are classified from what the task *does* into seven families chosen to
  differ in silhouette at 60 m.
- **Settlement mode** is where you watch it: one continuous camera from eye height
  to 1200 m, a work dock carrying the chore queue in the order the crew actually
  works it, a shared crosshair/mouse picker with an angular minimum pick radius
  (a person at 500 m is sub-pixel), and a quiet ring-buffer log with latched
  alarms. Nothing beeps; nothing must be dismissed.

### 5.7 Packing and logistics

Every physical thing resolves to a **packed shipping spec** — dimensions, mass,
form, stackability, orientation constraints — curated, computed, or estimated from
cited constants. A greedy extreme-point solver (deliberately heuristic; ~70–85%
fill is the honest human-crew number) packs the site's cargo into a catalog of 16
real containers: the U-Haul fleet with published interior *and door-aperture*
specs, trailers, ISO 20'/40'/40HC, and nestable sub-containers (pallets, totes,
job boxes, drums). It reports fill, payload, centre of mass and trailer
tail-heaviness. The **Packing Lab** (`Q`) is an interactive 3D cutaway where the
player can hand-place boxes — validated by the solver's own constraint functions,
so the modal can never teach a packing the report would reject. Deliveries spawn as
real prop records: crates stowed inside the container at solved stack heights,
which then have to be unloaded by actual labour. Props can be packed and unpacked
in-world, and a packed machine genuinely produces nothing.

### 5.8 Fabrication and making

- **Linkage Lab** (`N`) — a native port of a parametric scissor-linkage designer:
  folding deployable structures, closed-form kinematics pinned 1:1 against the
  original web app, panels and support beams, cylinder→arch transform, world
  placement with a 3 s animated deploy/stow, and solar handoff (a deployed
  structure's panels become a real graph array; stowed, it contributes zero). Plus
  a **priced bill of materials** with cut lists, drill templates, per-joint
  assembly sequences and a crew Gantt, and a **Hardware Detail** editor showing
  the actual bolt/bushing/washer/nut stack at each joint through ghosted timber cut
  from your own design.
- **Parametric part store** (`H`) — an in-game OpenSCAD customizer: browse a
  library, edit parameters, render to STL via headless OpenSCAD, place the part in
  the world, with license triage and credit tracking on ingest.
- **Machines** — CNC router, trash printer (plastic flake FDM), mud printer
  (gantry FDM), PP shredder / beam extruder / sheet press, geodesic dome builder,
  biodigesters. Process recipes with material inputs, chore-hour steps, part
  credits and multi-step workflows.

### 5.9 Weather, hazards, climate

- Open-Meteo archive (a full hourly year, cached) merged seamlessly with the ~21
  day forecast window; synthetic generation only fills genuine gaps. Source is
  shown, never chosen by hand.
- **Extreme weather** (opt-in, off by default): eleven hazards catalogued, four
  simulated end-to-end (wildfire smoke, dust storm, damaging winds, heatwave).
  Severity is resolved as a **pure function of absolute hours** through a four-layer
  ladder — NWS/IEM alert spans → measured air quality and weather → deterministic
  climatology synthesis → nothing — so hazards scrub backwards, replay and bake
  into challenges for free. Optics take the worst, energy factors multiply, and
  "feature off ⇒ not one pixel changes" is a proven identity, not a hope.
- Climate projections (CMIP6 deltas), a stochastic weather generator, a Climate
  Record Book, and site risk profiles.

### 5.10 Time, simulation and the NLE

The clock is authoritative and reversible; the canonical timecode is absolute
hours since year 1. `TimeDirector` resolves three modes — **LIVE / PLAYBACK /
SIMULATE** — plus per-instant provenance (real / observed / projected / recorded).

The bottom bar is a multi-day non-linear-editor timeline: scrub, zoom, pan, mode
and data-source chips, provenance colour bands, and **stacked clip lanes**. The
player can import a Home Assistant CSV as an *observed* clip, batch-render a
deterministic *simulated* clip over the same dates against the archived weather
for those days, and then **compare them split-screen** driven by one playhead —
which is a working sim-vs-reality error measurement. There is also MP4 export
(steps the world one frame at a time at 30 fps, requires ffmpeg) and a climelapse
drone path.

### 5.11 Digital twin (Home Assistant)

A direct WebSocket client mirrors ~80 live entities from a real installation
(inverter, Shelly circuit monitors) into the graph via an entity linker, gated so
live data only drives the sim in LIVE mode — in SIMULATE/PLAYBACK the timeline
owns state so scrubbing still works. Outbound: automation authoring in the
inspector and YAML push to Home Assistant. Historical HA CSV exports replay as
clips. A load calibrator measures real loads.

*(The roadmap prescribes migrating this to a HACS integration; that decision is
explicitly still open.)*

### 5.12 Multiplayer and community

- **Listen-server co-presence**: host/join by join code (with candidate address
  ladder, UPnP, LAN and public), shared clock, avatars, proximity text chat,
  live graph and prop sync, design share and ghost merge, and hardening (code
  expiry, optional password, trusted-key allowlist, peer/snapshot caps, rate-limit
  kicks).
- **Host-authoritative simulation**: clients no longer run their own population
  engine; the roster streams at 6 Hz as an indexed frame protocol.
- **Possession** — a player can play *as* one of the simulated people; the engine
  then skips them for planning, separation, catch-up and departures, but keeps
  charging them to the resource economy.
- **Discord-native** discovery: sign-in via OAuth2 authorization-code + PKCE with
  no client secret, and a "who is playing right now" directory implemented as **one
  Discord webhook message edited in place forever** — no bot, no server of ours,
  and a permanent join link. Host election arbitrates races via last-write-wins
  with a fixed confirm delay. Every security-relevant decision is a pure,
  fixture-testable class.
- **Portable `.esim` site packages** and share codes: the whole site — graph, SoI,
  props, styles — as a file or a paste-able code.

### 5.13 Learning, missions, scoring

- **Solar Bootcamp** — 12 data-driven tutorial levels that teach by doing: short
  circuit (where failure *is* the win), overcharge, PWM at 120 W, array scaling,
  24 V and 48 V bus sizing, 3S2P string sizing, 24 h runs with loads, merging a
  power station. Goals are pure topology predicates. It runs in a **sandbox** that
  snapshots and restores the player's real graph, clock and battery.
- **Pre-baked challenges** — a whole day/month/year computed in seconds, then
  played back at ~20 s with the playhead sweeping baked buffers; it parks at the
  failure breakpoint, and **retry replays the same segment against the player's
  edits**.
- **Site Report** (`K`) — an interactive infographic: month-by-month GHI, PV
  potential of the current graph, windrose and wind energy, rainfall, temperature
  bands, hydro potential, and the packing/logistics verdict.
- Progress store with unlocks (no file = everything unlocked, so existing installs
  are grandfathered), high scores, record book.

### 5.14 Save, share, persist

Eight save slots plus autosave, per-map graph autosave JSON, per-site terrain
tile deltas, vegetation layers and style stores, building styles, NPC space
registries, placed props and lights — all under `user://`, keyed per site.

---

### 5.15 Window wall (multi-monitor viewport)

Optional, off by default. For a room with several monitors mounted in a row —
the shuttle bus has three 27" panels on one wall — the game renders the world
across all of them so they read as windows. The maths is the physically
correct one: a single eye point at a configured distance from the wall, and
one off-axis frustum per monitor computed from that monitor's real size and
position, so a horizon or a fence line runs straight through the bezels. The
existing game window is moved fullscreen onto one of the monitors (the centre
by default) and a native window is opened on each of the others, all rendering
the same world. Settings → Window Wall takes the monitor count, size, gap,
eye distance, per-monitor tilt and which OS screen each takes (with
auto-arrange and an identify flash), plus what the clock does while the view
is open — by default it follows the real wall clock at 1× so the sun outside
matches the time of day. The view opens at a per-map saved viewpoint (set it
from where the player stands), hides every UI layer, and leaves on Esc or F11
with everything put back. Harness: `--capture=windowwall`; shortcut launch:
`--window-wall`.

## 6. Status honestly stated

### Shipped and solid
Location→world pipeline · terrain sculpting · buildings and Building Builder ·
vegetation system · water/hydro loop · systems graph with nested components ·
solar/wind/hydro/CSP/battery physics · DC electrical fault layer · resource flow
engine with ambient ticking · NPC population with morale, nav, chores, crews and
projects · settlement mode · packing and logistics · Linkage Lab with BOM and
hardware editor · parametric SCAD store · extreme weather · reversible timeline
with observed-vs-simulated compare · multiplayer with Discord identity · Solar
Bootcamp and pre-baked challenges · Site Report · `.esim` sharing.

### Partial
- **ISRU catalog breadth** — the water/food/materials pathways are now buildable,
  but every rate is a nameplate constant; efficiency *curves* don't exist yet, and
  several resource kinds the vision names (air moisture, O₂, fuel as a family) are
  missing.
- **Digital twin** — the bridge works; the HACS-integration migration is undecided.
  Calibration is energy-only; it has not been extended to water/biomass/waste
  channels. ESPHome/Lovelace export is not built.
- **Scenario modes** — archive, forecast, CMIP6 projections and a stochastic
  generator all exist; the five curated historical disaster missions do not.
- **Graph-native automation authoring** — not started; automations are per-node.
- **NPC upper floors/stairs** — the nav grid supports layers, but nothing in the
  game generates a walkable upper floor yet.

### Not started
- **NEC compliance checker** (Pillar 7) — nothing checks conductor sizing,
  overcurrent protection, or the 120% rule.
- Monte Carlo resilience (P50/P90), battery dispatch optimiser, LCOE/NPV/IRR
  financial model as a first-class surface.

### Deliberately dead / diverged
- **Sentinel-2 NDVI vegetation** — dead. Godot has no JPEG-2000 decoder;
  vegetation comes from OSM landcover instead.
- **Nostr community layer** — diverged. The *goal* (share a site, remix someone's
  build) is met by `.esim` packages, share codes and LAN/Discord multiplayer; the
  transport is not Nostr.

---

## 7. Known limits and rough edges

- **Two big monoliths keep growing** — the graph view (~15.8k lines), terrain
  loader (~10.2k), graph canvas (~9.2k) and the playtest harness (~6.8k). The
  "extract one responsibility per push" remedy is currently being outrun.
- **Node-name coupling** — a service registry exists and a sweep was done, but new
  code (notably the settlement surface) reintroduced hardcoded node-path lookups.
  The convention is not enforcing itself.
- **A stalled v1/v2 canvas split** and a handful of compatibility shims.
- **One live key conflict**: `C` is both "charge vehicle" and "camp dock" — the
  dock consumes the event but charging is read by polling, which ignores that.
- Some player-facing docs (an older walkthrough) list keys and tools that no
  longer exist.
- A live-network boot self-test currently fails two assertions at one site,
  pre-dating the last stabilisation pass and blocked behind an imagery fetch.
- **The recurring class of bug in this project is "renders plausibly, is wrong"** —
  a mis-registered roof texture, hardware anchored on the wrong pivot, a fog value
  of 900 m vs 9 km, a severity curve that does nothing until 0.8 then collapses.
  This is why the capture harnesses print numbers alongside screenshots.

---

## 8. Where it is going

The declared next horizon, in the project's own priority order:

1. **Complete the ISRU catalog and the Planetary Basic Income vision** — real
   efficiency curves rather than nameplate constants, more categories (atmospheric
   moisture, oxygen, soil, fuel), and every module carrying capital cost, operating
   power, throughput, failure modes and an HA entity template.
2. **Close the calibration loop beyond energy** — observed vs simulated per
   resource channel, auto-tuning efficiency coefficients to minimise RMSE.
3. **Graph-native automation authoring** → Home Assistant YAML push, plus ESPHome
   and Lovelace export.
4. **Deeper closure gameplay** — closure fraction per human need as the scoring
   spine, scenarios (drought week, cloudy month, freeze event) run against it.
5. **Sphere overlap** — the long-term multiplayer vision where neighbouring
   players' spheres cooperate at regional scale.

The success criterion the whole project is aimed at, stated as a single sentence:

> *A player at any real address can define a sphere, watch Planetary Basic Income
> populate their graph from live weather, wire real catalog modules into a coherent
> water/energy/waste/food pathway, run a hard scenario against it, export the
> config to Home Assistant, build the hardware, link the sensors, and iterate until
> the simulated and observed flows converge.*

Everything else — the terrain, the trees, the people, the crates, the bolts — exists
to make that loop feel like a place worth living in rather than a spreadsheet.
