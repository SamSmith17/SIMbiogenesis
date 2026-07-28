# Population Plan — Morale, Collapse, Enrichment, Labour, Weather

The Tier-2 design for `core/population/`. **Status: all phases 2a–2e are
implemented and verified** (offline selftest + the `--capture=population`
harness, which drives the full cascade in-game). This document remains the
design rationale and the reference for the invariants; the shipped behaviour
is summarised in the *NPC population simulation* section of `CLAUDE.md`.

**Implementation notes that differ from the original spec** (learned while
building it):
- The priority ladder must be real **tiers**, not one weighted score, and only
  CRITICAL needs may interrupt an in-progress activity. Both mistakes livelock
  the FSM — see the three traps recorded in `CLAUDE.md`.
- Retry backoff is **per-tier** (`retry_at` dict), never a single scalar.
- A fresh agent starts fully un-enriched (`enrichment` need = 1.0), otherwise
  the morale ceiling starts near 1.0 and the "earn it by gathering" mechanic
  silently no-ops.
- Enrichment at a `fire_circle` draws `biomass` through a new (rate-0, inert
  in classic mode) habitat input; with no fuel wired, agents pick a different
  enrichment space rather than looping.
- Grid A\* pathfinding and the desire-line analysis built on top of it are
  specified as **Tier 3** at the end of this document.

## The loop we are building

> Infrastructure keeps the people operating; the people keep the
> infrastructure operating. Break either side and the whole thing unwinds.

Today the sim is open-loop: unmet needs pin at 1.0 and nothing happens. The
target loop closes it:

```
        needs met ──► morale rises ──► free time ──► enrichment ──► morale ceiling lifts
            ▲                                                            │
            │                                                            ▼
    infrastructure runs ◄── chores done ◄── labour pool ◄── resilient, present people
            │                                                            ▲
            ▼                                                            │
      needs unmet ──► morale falls ──► rage-quit ──► smaller pool ──► more strain ──┘
                                                              (colony collapse)
```

The failure mode is **cascading and self-accelerating**; the success mode is
**buffered and self-reinforcing**. Everything below serves that asymmetry.

---

## 1. Morale — "Fuck Yes" → "Fuck This"

A per-agent scalar `morale ∈ [0, 1]`, surfaced on a named band scale. This is
the emotional read of the whole system and should be the most legible number
in the game.

| Band | Range | Label | Meaning |
|---|---|---|---|
| 5 | 0.85–1.00 | **Fuck Yes** | Thriving. Max resilience, volunteers for work. |
| 4 | 0.70–0.85 | **Pretty Good** | Content. Normal productivity. |
| 3 | 0.50–0.70 | **Coping** | Getting by. Chores slip first. |
| 2 | 0.30–0.50 | **Over It** | Doing the minimum. Visible discontent. |
| 1 | 0.12–0.30 | **Done With This** | Actively considering leaving. |
| 0 | 0.00–0.12 | **Fuck This** | Departure imminent. |

**New file:** `core/population/npc_morale.gd` (`NpcMorale`, static) — pure
functions: `band(morale) -> int`, `label(morale) -> String`,
`color(morale) -> Color` (green→amber→red ramp), and the delta calculation
below. Static + pure so it is trivially selftestable and reusable by the
inspector, Site Plan, crosshair, and 3D tag alike.

### What moves it

Morale integrates per sim-hour, like every other rate in this codebase:

```
d(morale)/dt = (recovery + enrichment_bonus) − Σ(critical_need_pressure) − exposure
```

**Critical needs** — `sleep`, `thirst`, `hunger`, `bladder` (NOT hygiene; it
is a comfort need and only contributes via the enrichment ceiling). Pressure
is superlinear so a genuinely unmet need dominates jitter:

```
pressure(need) = WEIGHT[need] × max(0, level − PAIN_THRESHOLD)²  / (1 − PAIN_THRESHOLD)²
PAIN_THRESHOLD := 0.75          # discomfort below this is normal life
WEIGHT := {sleep: 0.10, thirst: 0.14, hunger: 0.10, bladder: 0.06}  # per sim-hour at level 1.0
```

**Blocked ≠ merely rising.** A need that is high *because supply is starved or
no space is tagged* hurts roughly **2×** what the same level hurts while the
agent is simply walking to a working facility. The agent already tracks this
(`next_retry_h` backoff + `ctx.starved`); expose it as
`NpcAgent.is_blocked(need) -> bool` and apply `BLOCKED_MULT := 2.0`. This is
what makes *broken infrastructure* — not *busy people* — the thing that
destroys morale.

**Recovery** is slow and capped, so morale is easier to lose than regain:

```
RECOVERY_PER_H := 0.035          # when zero critical pressure
BASELINE_CEILING := 0.75         # needs alone cannot exceed "Pretty Good"
```

**The ceiling is the point.** Meeting needs perfectly gets a community to
0.75 and no further. Everything above 0.75 must be *earned through
enrichment* (§3). A purely functional camp is survivable and joyless.

### Persistence & determinism

`morale` joins the `NpcAgent.snapshot()` dict (2-dp rounded, same change-gate
as needs) and rides `specs.pop_state`. Integration is a pure function of
`dt_hours` and current state — no new reversibility problem: scrub-back
freezes with the rest of the engine, and the coarse forward-catch-up applies
the analytic settle already implemented in `_catch_up`.

---

## 2. Rage-quit and colony collapse

### Departure

When `morale < QUIT_THRESHOLD` the agent accumulates *quit pressure* rather
than leaving instantly — a bad afternoon should not empty the camp:

```
QUIT_THRESHOLD := 0.12                    # the "Fuck This" band
quit_pressure += (QUIT_THRESHOLD − morale) × dt_hours
depart when quit_pressure > QUIT_PRESSURE_H   # ≈ 8 sim-hours at morale 0
```

`quit_pressure` decays at `QUIT_DECAY_PER_H` whenever morale recovers above
the threshold, so pulling someone back from the brink is possible but costs
real sim time.

**Resilience is the buffer.** Because pressure accrues from *how far below*
the threshold morale sits and morale itself is slow-moving, a community at
"Fuck Yes" has both a longer fall and a decaying head start before anyone
reaches the quit band. That is the mechanical expression of "higher health =
rides out crises."

### Departure is a real event

`NpcPopulationEngine` emits `agent_departed(agent_id, name, reason)`:
- Agent removed from the roster → aggregate demand drops (fewer mouths)
  **and** the labour pool shrinks (fewer hands — §4).
- `SpaceRegistry.release_all_for_agent()`; 3D avatar walks to the SoI
  boundary and despawns rather than blinking out.
- A timeline/HUD toast: *"Marlo has left the community (Fuck This)"*.
- Recorded in a departure log on `specs.pop_state` for the post-mortem.

### The cascade

Departures make things worse in two directions, which is what produces
collapse rather than a soft landing:

1. **Labour:** chores that kept water pumped / waste processed / food grown
   go undone → supply fails → *everyone's* critical needs spike.
2. **Contagion:** watching people leave is demoralising.
   `MORALE_DEPARTURE_SHOCK := 0.04` applied to every remaining agent per
   departure, scaled by `departures_today / roster_size`.

**Collapse detection.** `NpcPopulationEngine` exposes
`collapse_risk() -> float` (0..1) from roster trend + mean morale + blocked
critical channels, and emits `colony_collapse_warning(level)` at 0.5 and
`colony_collapsed()` when the roster falls below
`COLLAPSE_FLOOR := 0.35 × initial_roster`. Collapse is a **narrative failure
state, not a game over** — the site persists, the graph keeps running, and
the player can rebuild and re-attract people (a future "recruitment" hook
gated on sustained high morale + surplus).

### Guarding it

The single most important thing to test here is that **collapse cannot happen
by accident on a well-supplied site**. The selftest must pin: a fully-supplied
30-day run has zero departures and mean morale ≥ 0.7; a water-starved run
collapses within a bounded window; and a *briefly* starved run (12 h) fully
recovers with no departures.

---

## 3. Enrichment — the path above 0.75

### Free time is the gate

An agent has free time when its projected day has hours left after sleep,
needs, and assigned chores:

```
free_hours = 24 − sleep_hours − Σ(need activity hours) − assigned_chore_hours
ENRICHMENT_MIN_FREE_H := 1.5     # below this, no appetite for enrichment
```

Enrichment is only ever chosen when **every critical need is below its
threshold** and free time exists. It is the lowest-priority pull in the
selector (§4) — nobody dances while thirsty.

### New space types

Extend `SpaceTypes.TYPES` (the tables are the only thing that needs to
change — registry, tagging UI, Site Plan markers and colours all follow
automatically, exactly as `shower` did):

| id | Label | Flavour | Consumes |
|---|---|---|---|
| `fire_circle` | Fire Circle | Gathering, warmth, talking | `biomass` (small, real) |
| `movement` | Dance / Movement | Dancing, yoga, exercise | — |
| `quiet` | Quiet / Reflection | Rest, reading, solitude | — |
| `workshop_social` | Making / Craft | Social making, repair-café | — |

`fire_circle` consuming biomass is deliberate: it ties joy to a real resource
the graph already models, so enrichment has a cost the player must plan for.

### The enrichment need

A fifth non-critical need, `enrichment`, rising slowly
(`1/30 h⁻¹`) and satisfied by any enrichment activity. It never contributes
critical pressure. Instead it sets the **morale ceiling**:

```
ceiling = BASELINE_CEILING + (1 − BASELINE_CEILING) × (1 − enrichment)
enrichment_bonus = ENRICH_GAIN_PER_H  while morale < ceiling
```

So: a camp that never gathers sits at 0.75 forever. A camp that gathers
regularly can reach "Fuck Yes" — and gains the collapse buffer that comes
with it.

**Social clustering.** Enrichment spaces should prefer *company*: when
choosing among candidate enrichment spaces, weight by current occupancy
(`SpaceRegistry.occupant_count`) rather than distance alone, so people
gravitate toward the fire that already has people at it. This is the cheapest
possible emergent-behaviour win — one term in the scoring function — and it
is what will make the Site Plan look alive.

---

## 4. Chores, scheduling, and the labour pool

### Priority ladder

`NpcAgent._pick()` becomes an explicit ladder, evaluated top-down. **Critical
needs always win** — that is the stated requirement:

1. **Critical need past threshold** (sleep / thirst / hunger / bladder) —
   highest urgency wins, as today.
2. **Comfort need past threshold** (hygiene).
3. **Assigned chore** whose window is open and whose weather gate passes (§5).
4. **Enrichment**, if free time and every critical need is quiet.
5. Idle / wander.

An agent that is *blocked* on tier 1 (no space, starved supply) does **not**
fall through to tier 3 — it waits and retries. Hungry people do not cheerfully
do maintenance; that is where the morale damage comes from.

### Chores as a first-class object

The project already has the substrate: `chore_hours` is a `ResourceKind`,
`core/machines/` owns process recipes with a chore ledger and "hybrid chore
confirm", and machines are placed props. NPC labour should **supply** that
ledger rather than invent a parallel system.

**New file:** `core/population/npc_chore_board.gd` (`NpcChoreBoard`) — the
per-site work queue:

```gdscript
{ id, label,
  target: {kind: "prop"|"graph_item", id: "..."},   # where the work happens
  space_type: "",                                   # optional required space
  chore_hours: 0.5,                                 # labour to complete
  window: {start_h: 8.0, end_h: 18.0},              # daily availability
  repeat: "daily"|"once"|"on_demand",
  weather_gate: {...},                              # §5
  priority: 0,                                      # player-ordered
  assigned_to: "",                                  # agent id, "" = anyone
  progress_h: 0.0 }
```

Sources of chores, in ascending order of ambition:
- **Player-authored**, from a Routines panel (below).
- **Machine-derived**: any placed machine with a pending process recipe
  publishes a chore automatically, so "keep the extruder fed" is a job.
- **Maintenance-derived** (future): a wear model on props emits repair chores.

### Doing the work

A `DOING` chore activity ticks `progress_h` by the same time-averaged
mechanism the consumption path already uses, and credits `chore_hours` into
the ledger so the existing recipe machinery advances. Productivity multiplies
in: `effective_h = dt × morale_productivity × weather_productivity`, where

```
morale_productivity = lerp(0.55, 1.15, morale)   # Fuck This is slow; Fuck Yes is fast
```

This is the second half of the loop: **low morale directly slows the work that
keeps morale up.**

### The Routines panel (the actual goal)

The stated end state is *"automate/schedule routines and chores for each NPC."*
That wants a real UI: a per-site **Routines** screen (a tab in the habitat
inspector, or a modal in the `scenes/ui/` family) with

- a **roster list**: name, morale band chip, current activity, assigned chores;
- a **chore board**: add/edit/reorder chores, set windows and repeat;
- **assignment**: per-agent, or "anyone free", or role-based once roles exist;
- a **day-plan strip** per agent — a 24 h bar showing sleep / needs / chores /
  free time, so over-scheduling is *visible* rather than discovered through
  collapse.

That day-plan strip is the key affordance: it is where the player sees that
they have booked 11 hours of chores against a person who needs 8 hours of
sleep and 3 hours of needs, and that this person is going to quit.

---

## 5. Weather-driven productivity

Weather is already a first-class, cached, location-real service
(`WeatherService.sample()` → `temperature_2m`, `wind_speed_10m`,
`precipitation`, `cloud_cover`), and the population engine ticks from the same
absolute-hours clock. So this is a scaling term, not a new system.

**New file:** `core/population/npc_weather_gate.gd` (`NpcWeatherGate`,
static, physics-cited): `productivity(weather, exposure) -> float` and
`is_unsafe(weather, exposure) -> bool`.

Chores carry an **exposure class** — `indoor`, `sheltered`, `outdoor` — and
only `outdoor`/`sheltered` work is weather-gated:

| Driver | Comfortable | Degrades | Stops |
|---|---|---|---|
| Temperature | 8–26 °C | outside band | < −5 °C or > 38 °C (WBGT-style heat ceiling) |
| Wind | < 8 m/s | 8–15 m/s | > 15 m/s (working at height / with sheet goods) |
| Rain | dry | > 0.5 mm/h | > 5 mm/h |

Productivity is the **product** of per-driver factors, floored at
`WEATHER_FLOOR := 0.15`, so a hot windy rainy day is genuinely brutal rather
than merely additive. Cite the sources in-comment per project convention
(ISO 7243 WBGT for heat, Beaufort for wind thresholds).

**Morale coupling — exposure.** Working outdoors in bad weather is its own
morale drain (`exposure` term in §1), and sleeping in the cold without a
tagged `sleep` space should hurt more when the temperature is extreme. This
is what will make the seasonal/climate dimension *felt* rather than merely
tabulated: a site that is fine in June collapses in February.

**Second-order effects worth having:** unsafe weather forces `outdoor` chores
to be skipped (their windows lapse, work backs up), which is the natural
bridge to storm/heatwave crisis events later.

---

## 6. Surfacing it

None of this matters if the player cannot see it. In rough priority:

- **Site Plan dots tinted by morale band** (the ramp already exists in
  `NpcMorale.color`) — the camp's mood readable at a glance, next to the
  space markers shipped in Tier 1.
- **Crosshair readout** extended: *"Marlo — Over It · heading to Water Point"*.
  The plumbing (`status_line`, `_update_npc_focus`) is already in place.
- **Habitat inspector Population section**: morale histogram across bands,
  collapse-risk meter, departures-today, top morale drain.
- **Timeline toasts** on departure and collapse warning.
- **Site Report population card**: mean morale and departures across the
  representative year — the planning view.

---

## 7. Build order

Each phase is independently shippable and independently guarded.

| Phase | Content | Guard |
|---|---|---|
| **2a — Morale** | `NpcMorale`, integration in `NpcAgent.step`, blocked-need detection, snapshot, Site Plan tint, crosshair band | Selftest: band boundaries, pure-function delta, supplied-run stays ≥0.7, starved-run falls, 0.75 ceiling holds without enrichment |
| **2b — Departure & collapse** | Quit pressure, `agent_departed`, roster shrink, contagion shock, `collapse_risk`, warnings, toasts | Selftest: no departures on a supplied 30-day run; bounded collapse when starved; brief starvation recovers fully. Harness: `--capture=collapse` |
| **2c — Enrichment** | 4 new space types, `enrichment` need, ceiling lift, free-time gate, occupancy-weighted social clustering | Selftest: ceiling unreachable without enrichment, reachable with; enrichment never preempts a critical need; clustering prefers occupied spaces |
| **2d — Chores & routines** | `NpcChoreBoard`, priority ladder, `chore_hours` ledger credit, morale productivity, Routines panel + day-plan strip | Selftest: critical needs always preempt chores; over-scheduling shows negative free time; ledger credit is mass-exact. Harness: chore completion drives a real recipe |
| **2e — Weather** | `NpcWeatherGate`, exposure classes, productivity scaling, exposure morale drain, unsafe-work skip | Selftest pinned to cited thresholds; a winter run measurably out-produces nothing vs. a summer run on the same site |

**Prerequisite worth doing first:** the deferred **grid A\* pathfinding**
(behind `NpcNav.advance`). Once people have day plans and chores, watching
them walk through a building to get to the fire circle will undermine every
other thing on this list.

---

## Design invariants (do not break)

1. **Critical needs always preempt everything.** No chore, no enrichment, no
   schedule overrides a person's need for water.
2. **Rates stay per sim-hour; integration stays time-averaged.** Every new
   term follows the Tier-1 pattern so mass and morale are exact at 1× and
   450× alike.
3. **Scrub-back freezes; big forward jumps settle analytically.** No new
   reversibility debt.
4. **Blocked infrastructure hurts more than busy people.** The 2× blocked
   multiplier is the thesis of the whole design.
5. **Morale is easier to lose than to regain, and the ceiling must be
   earned.** Asymmetry is what makes the loop a game rather than a readout.
6. **Collapse is recoverable.** It is a story beat, not a fail screen.

---

# Tier 3 — Wayfinding and Desire Lines

**Status: 3a–3e built and verified. 3f (3D drape) specified, not built.**

Corrections learned while building 3a/3b, kept here because they are the
non-obvious parts:
- The slope baseline is a central difference over ±2 cells — a **3 m** span,
  not 1.5 m. A single 1.2 m step therefore reads 21.8°, not 38.7°.
- String-pulling must be **cost-aware**. Pure visibility smoothing straightens
  a deliberate detour back over a hill, silently undoing the climb avoidance
  A* just paid for.
- Heights are `float32`, so a step authored at exactly `STEP_UP_M` reads back
  larger and is refused by a rounding error. `STEP_EPS` makes "at the limit"
  mean passable.
- Lane jitter must validate the whole polyline, not its vertices: a shifted
  waypoint can be walkable while the segments either side clip a doorjamb. It
  now declines entirely in pinch points and reverts on any failed segment.
- On a scene with **no TerrainLoader**, `ground_height_at` falls back to a
  raycast that returns 0.0 on a MISS, so every gap in collision coverage reads
  as a cliff and islands the grid. The nav grid uses a flat height source
  there instead; this was causing real path failures.
- Build the desire ImageTexture on the tick, never inside `_draw()`.
- Coarse catch-up must model COPING, not neglect — but must NOT feed needs
  whose supply is starved.
- Walk accounting must cover the ARRIVAL leg, not just per-step movement: a
  trip that completes inside one step never calls the walk path, and at high
  time scale that is every trip — the whole metric reads zero.
- The layer pass must budget **probes**, not cells scanned — skipping a
  non-structure cell is an array read, and charging it like a raycast made
  that phase as slow as the whole height pass for no work.

Two deliverables, in order. First **grid A\* pathfinding**, so people walk
around walls and up ramps instead of gliding through trees. Then, built on the
routes it produces, a **desire-line view**: where the population actually wears
paths into the site over days, how far each person has to walk to live here,
and what that costs them in calories — turning the spatial layout into a
measurable design variable.

> A camp is not just a set of tanks and machines. It is a *floor plan*. The
> desire-line view is what makes that floor plan legible and gradeable.

## Why this is worth the cost

Everything downstream of Tier 2 already reacts to walking distance — a person
who spends four hours a day getting to water has less free time, does fewer
chores, and reaches enrichment less often, which caps morale. Right now that
coupling is fake, because agents teleport through walls in straight lines. Once
routes are real, **layout becomes a first-class input to the survival sim**:
moving the water point 40 m closer measurably buys back free time and morale.

---

## 3a — The walkable grid

**New:** `core/population/npc_nav_grid.gd` (`NpcNavGrid`).

### Region, not the whole SoI

Baking the full SoI at person-scale resolution is wasteful — camps occupy a
fraction of it. The nav region is the **AABB of all tagged spaces plus the
habitat home, padded by `REGION_PAD_M` (30 m)**, clamped to
`MAX_REGION_HALF_M` (300 m) and re-derived whenever the space registry changes.
Typical festival/camp sites land at 100–200 m across.

`CELL_M := 0.75`. This is deliberately finer than `ConduitAStar.CELL_M`
(2.5 m): a doorway is ~1 m wide, and at 1.5 m cells a door either vanishes or
becomes a 3 m hole. At 0.75 m a 200 m region is 267² ≈ 71k cells per layer —
fine in flat `PackedFloat32Array` / `PackedByteArray` storage, hopeless in a
Dictionary. Store:

```
_height : PackedFloat32Array   # walkable surface Y per (cell, layer)
_flags  : PackedByteArray      # BLOCKED | WALL | DOOR | INTERIOR | STRUCTURE
_layers : int                  # 1 on open ground; >1 only where structures exist
```

### Baking is budgeted — never on demand

`ConduitAStar`'s header records that per-cell ground fetches caused **GPU TDR
and multi-second stalls**; it flattened its whole grid to a single Y band to
escape that. We need real heights, so instead the bake is **chunked across
frames** (`CELLS_PER_FRAME` ≈ 2000 — the `TerrainHeightField` /
`batch_renderer` pattern): ~71k cells lands in ~35 frames. The grid exposes
`is_ready()`, and until it is, agents fall back to today's straight-line
`NpcNav.advance` — the sim never blocks on the bake, and never samples terrain
inside a population tick.

Heights come from `TerrainSurfaceQuery.ground_height_at`. Slope is derived
after the height pass as a **central difference over ±2 cells (a 3 m span,
about two strides)**, not from adjacent cells — see the slope-vs-steps note
below. Nothing is sampled twice.

**Slope is terrain grade, not a step limit.** At 0.75 m cells the delta
between two *adjacent* cells is a step, not a gradient: a 1.2 m step onto a
deck reads 58° across one cell and would strand people at the bottom of it.
Over the 3 m baseline the same step reads 21.8° and stays walkable, while a
genuine cliff still reads 80°+ and blocks. Widening the baseline cannot
rescue a *sustained* steep grade — a 58° ladder reads 58° at any baseline and
is correctly refused. Per-move `STEP_UP_M` / `STEP_DOWN_M` limits belong at
connection time in 3b, never as a cell flag. Getting this backwards is exactly
the "NPCs get stuck on stairs" failure this phase exists to avoid.

### Obstacles

Reuse what exists rather than re-deriving geometry:

- `VegExclusionBuilder.build_all(buildings, roads, water, …)` already returns
  buffered obstacle polygons for buildings + roads + water, and
  `VegExclusionBuilder.build_index(exclusions, half_extent_m)` is a
  uniform-grid broadphase built for exactly this kind of hot stamping loop.
  Roads are passable (they are *good* walking), so we call it for buildings and
  water only, with our own buffers.
- Still water (`kind not in WaterBuilder.FLOWING_KINDS`) blocks; flowing water
  costs extra rather than blocking (people ford streams).
- Placed props block by footprint via `PlacedPropService.footprint_from_model`,
  skipping props whose model opts out (thin/open-frame things, and anything
  already flagged `skip_prop_collision`).
- Slope above `MAX_SLOPE_DEG` (50°) blocks — cliffs only.

`terrain_loader` needs one small public addition: `get_osm_buildings()`,
mirroring the existing `get_osm_roads()` (L4082), since `_buildings_data` is
private today.

### Invalidation

A `fingerprint()` in the `ConduitAStar.obstacle_fingerprint` idiom, folding:
space-registry revision, prop-layer revision, building-style revision, and a
terrain-edit counter. `needs_rebuild(fp)` triggers a re-bake; in-flight agent
paths survive until their next re-plan (a stale path beats a stutter).

### Selftest (offline, no scene)

`NpcNavGrid` takes a `height_fn: Callable` and an obstacle polygon array, so
the whole thing is testable on synthetic terrain: a flat plane, a 30° ramp, a
cliff, a walled box with one gap. Assert cell↔world round-trips, slope
derivation, blocked stamping, and fingerprint stability.

---

## 3b — A\* and path following

**New:** `core/population/npc_nav_query.gd` (`NpcNavQuery`).

Wrap Godot's `AStar3D` (C++-side, and what `ConduitAStar` already uses) over
the baked grid: one point per walkable (cell, layer), 8-connected in XZ plus
inter-layer links.

### Traversal rules — deliberately lenient, as specified

| Rule | Value | Rationale |
|---|---|---|
| `STEP_UP_M` | **1.2** | Slightly beyond the player's `step_height = 1.1`. Clears stair risers, curbs, pallet decks, terrain lips. |
| `STEP_DOWN_M` | **2.5** | Dropping is easier than climbing. |
| `MAX_SLOPE_DEG` | **50** | Stairs run ~32–37°, ramps ≤10°. Nothing short of a cliff stops them. |
| `CLIMB_COST_PER_M` | 2.5 | They *prefer* flat, but will always take the stairs rather than refuse the trip. |

Diagonal moves cost `√2` and require both orthogonal neighbours passable (no
corner-cutting through a wall junction).

**The rule that matters most: no reachable destination is ever refused for
being awkward.** If a path exists under these limits it is taken, however ugly.
Getting stuck is worse than walking a silly route.

### Path caching — the perf win *and* the desire-line substrate

People walk between the same ~10 tagged spaces all day. Cache
`(from_space_id, to_space_id) → PackedVector2Array`, invalidated with the grid
fingerprint. Agents starting at a space (the common case — they finish an
activity and leave from it) get a cache hit and cost nothing.

- Cache miss / not starting at a space → queued fresh query, **bounded to
  `MAX_QUERIES_PER_TICK` (4)**; the agent keeps its old heading meanwhile.
- Per-agent lateral jitter (from the day-seeded RNG) offsets the shared route
  by ±0.4 m so sixteen people do not walk a single-pixel line — which is also
  what gives a desire line its natural *width*.

### Integration

`NpcNav` keeps its role as the movement seam:

```gdscript
static func plan(nav, from_xz, to_xz, agent_seed) -> PackedVector2Array
static func advance_path(agent, dt_hours) -> Vector2   # walks agent.path
```

`NpcAgent` gains `path: PackedVector2Array`, `path_idx: int`,
`path_len_m: float`. The **teleport degradation invariant is preserved**: if
one tick's travel covers the remaining path, snap to the end. Consumption stays
rate-based in sim-hours, so mass is still exact at 450×.

Determinism: `AStar3D` is deterministic given identical construction order, so
the grid must always be built in the same cell order. Jitter comes from the
day-seeded RNG. The existing identical-run determinism check must still pass.

### Selftest

Known mazes with hand-computed answers: a wall with one gap, a spiral, an
unreachable island (must return empty, and the agent must fall back to
"blocked" rather than freeze), a 1.2 m step (passable) vs a 1.6 m step
(blocked), a 55° face (blocked) vs a 45° face (passable), cache
hit/invalidation, and identical paths across two runs.

---

## 3c — Buildings, doors, and upper levels

### Walls block, interiors do not

For each footprint: stamp cells within `WALL_BAND_M` (0.6 m) of an edge as
`WALL|BLOCKED`; leave interior cells passable and flagged `INTERIOR`. That
alone gives "avoid the walls, walk freely once inside" — the only remaining
question is how you get in.

### Doors

Player-placed door elements convert cleanly to world space. `elements` records
are `{kind:"door", edge, u_m, v_m, w_m, h_m}` where `edge` indexes the
**normalized** ring from `BuildingBuilder.resolve_building_params` (open, CCW —
so edge indices are stable), and the door centre is `poly[edge] + dir * u_m`
with span `[u−w/2, u+w/2]`. Clear the wall band over that span, plus a 2 m
approach corridor on both sides so agents aim at the opening rather than
scraping the jamb.

### The auto-door heuristic (load-bearing, not a nicety)

Only *styled* buildings carry elements. **Almost every OSM building has no door
data at all**, so without a fallback the requirement "pathfind into and through
buildings" fails on essentially every real site. Therefore:

> Any building with no door element gets one auto-punched at the midpoint of
> the edge nearest the closest OSM road (via the existing `get_osm_roads()`);
> with no road in range, the edge nearest the site centroid.

Derived deterministically from `building_tag` so it is stable across reloads,
and applied **unconditionally to any building tagged as an NPC space** — a
building the player designated as the kitchen must be enterable. Exposed as a
setting (`auto_door`, default on) and drawn on the Site Plan so the assumption
is visible rather than mysterious.

### Upper levels

The grid is layered from the start, but be clear-eyed about the content: the
project **generates no walkable upper floors, and no stairs or ramps at all**
today. Pallet racks have decks with no way up; `collision_stairs.gd` and
`collision_ramp.gd` are editor-authored scene helpers, not runtime output. The
one multi-height thing that already works is **terrain ramps**
(`terrain_sculpt_ops.ramp`), and a ground-sampled grid gets those for free.

So layers are built to this bounded scope:

- Extra layers are sampled **only in cells flagged `STRUCTURE`** (inside a prop
  AABB or building footprint) — a tiny fraction of the grid — by downward
  `intersect_ray` on collision layer 1, collecting up to `MAX_LAYERS` (3)
  surfaces. `PlacedProp.setup_collision` bakes real trimeshes with no AABB
  proxy, so a ray genuinely lands on a rack deck.
- Inter-layer links exist wherever `|Δh| ≤ STEP_UP_M` between adjacent cells,
  which means **stairs and ramps connect automatically** the moment any content
  produces them — a stair is just a chain of ≤1.2 m steps.
- No stair *generation* is in scope here. When stairs arrive (a model, or a
  building-interior generator), they work with no nav changes.

Verification: a windowed capture placing a ramp and a decked rack, asserting an
agent reaches an upper surface.

---

## 3d — Distance, climb, and calories

Per agent, per sim-day: `distance_m`, `climb_m` (positive gain only),
`walk_kcal`. Reset on the day rollover, with the previous day retained for
comparison.

**Model — ACSM walking equation** (ACSM's *Guidelines for Exercise Testing and
Prescription*), the standard for grade-adjusted walking metabolism:

```
VO2 [mL/kg/min] = 3.5 + 0.1*v + 1.8*v*g       v in m/min, g = fractional grade
kcal/min = VO2 * mass_kg / 1000 * 5           (~5 kcal per L O2)
```

Sanity check at the project's walk speed: v = 1.3 m/s = 78 m/min, 70 kg, flat →
VO2 = 11.3 → 3.96 kcal/min → **~51 kcal/km**, matching the accepted
~50–60 kcal/km for a 70 kg adult. Cite Pandolf, Givoni & Goldman (1977) in the
comments as the load-carrying upgrade for when chores involve hauling.

**Spatial efficiency** — the numbers that make layout gradeable:

- `walk_kcal / person / day`, and mean daily distance.
- **Walking overhead %** = walk kcal ÷ a ~2000 kcal/day baseline. A camp
  costing 8% of everyone's daily energy just getting to water is a bad plan,
  and now it says so.
- Mean distance *per satisfied need*, split by need — the diagnostic that
  points at *which* space is misplaced.

Surfaced in the habitat inspector, the Routines panel, and (later) a Site
Report card. Selftest pins the ACSM worked example and the grade term.

---

## 3e — Desire lines, Site Plan (the payoff)

### Accumulate a raster, not polylines

Storing every route as geometry grows without bound. Real desire-line analysis
rasterises, and so do we: a `PackedFloat32Array` heat grid at `HEAT_CELL_M`
(2.0 m) over the nav region. Each agent step DDA-rasterises the segment from
its previous position to its new one, adding metres travelled. O(1) memory,
O(cells crossed) time.

- **Channels** per activity class (water / food / restroom / sleep / work /
  gather) so the view can answer "show me only the trips to water". Six
  channels × ~10k heat cells × 4 B ≈ 240 KB.
- **Decay** applied on the sim-day rollover: `today` (full reset), `7 days`
  (exponential), `all time` (none). So the map reflects the *current* layout
  rather than a fossil of one you already fixed.

### Rendering

One `ImageTexture` built from the raster (throttled to ~2 Hz, and only while
the view is on), drawn with a **single `draw_texture_rect`** positioned by the
existing site transform — 71k `draw_rect` calls would be unusable. This mirrors
`solar_shading_analyzer`'s existing "compute a world raster, hand out an
`ImageTexture` + world `Rect2`" pipeline.

Drawn in `graph_canvas._draw()` **immediately after `_draw_pbi_bar()`**, i.e.
*under* the watershed, spaces and agent dots, following the
`npc_agents_provider` / `npc_spaces_provider` convention — the canvas gets an
`npc_desire_provider` Callable and stays sim-agnostic.

Colour: log-scaled (traffic is heavy-tailed; linear shows one hot line and
nothing else) on a perceptually ordered ramp, alpha-weighted so cold cells
vanish rather than fogging the map.

**Recent trails**, separately: a bounded ring buffer of the last N positions
per agent → fading `draw_polyline`. Cheap for 50 agents, and it is what makes
the view feel *alive* rather than statistical.

### Controls

A `Desire lines` toggle in the existing **View options ▾** menu
(`system_graph_view.gd` L1804, handler L2190, check-sync L3163), disabled
outside Site Plan exactly as the other site-only toggles are. Note the existing
id collision — `VIEW_MODE_EMBODY_TWINS` and `VIEW_MODE_SITE_PORTS` are **both
151**; take 152+. Sub-options: channel filter, time window, trails on/off.

---

## 3f — Desire lines in 3D (optional, cheap)

The same `ImageTexture`, draped on the terrain. The cheapest correct pattern
already exists: `earthworks_drape.gdshader` + `EarthworksBuilder.plan_uv(x, z,
half_extent_m)` is a straight world-XZ → 0..1 planar UV map. Build one
terrain-following mesh over the nav region (grid-tessellated so it hugs rolling
ground, unlike `build_polygon_highlight`, which only samples polygon corners),
sample the heat texture, additive-blend.

Cost: one mesh, one material, one texture upload per refresh — negligible, and
it is toggle-gated and only built when first enabled. Worth doing; it is the
view that makes an unwalkable layout obvious from inside the world.

---

## Build order & verification

| Phase | Content | Guard |
|---|---|---|
| **3a** | `NpcNavGrid`: region derivation, budgeted bake, obstacle stamping, fingerprint | Selftest on synthetic terrain (plane / ramp / cliff / walled box); assert the bake never runs inside a population tick |
| **3b** | `NpcNavQuery` + A\*, path cache, `NpcNav` path following, agent path state | Maze selftests, step/slope limits, unreachable → graceful, determinism across two runs; `--capture=population` still passes |
| **3c** | Wall bands, real + auto doors, interior passability, layered surfaces | Selftest for door punching + layer linking; windowed capture: agent enters a building and climbs a ramp |
| **3d** | Distance/climb accounting, ACSM calories, spatial-efficiency readouts | Selftest pinned to ~51 kcal/km @ 70 kg and the grade term; inspector/Routines readouts |
| **3e** | Heat raster, channels, decay, Site Plan render, View options toggle, trails | `--capture=desire` windowed: run several sim-days, shoot the heat map, assert hot cells cluster on the space-to-space corridors |
| **3f** | 3D draped overlay | Same capture, world view |

## Risks

- **The stall trap.** `ConduitAStar` abandoned per-cell terrain sampling
  because it caused GPU TDR. The bake must stay budgeted and off the tick path;
  the ambient regression guard must still pass.
- **Auto-doors are a heuristic** standing in for data OSM does not have. Make
  them visible on the Site Plan and overridable, or players will hit "why won't
  anyone go in the kitchen".
- **Layer support will be under-exercised** until something generates stairs.
  Build the mechanism; do not gold-plate it.
- **Determinism** must survive: identical grid construction order, jitter from
  the day-seeded RNG only.
- **Cache invalidation** on terrain sculpt, prop placement, and building-style
  edits — a stale path that walks through a new wall is the obvious failure.
- **Scope honesty:** if the nav region ever needs to cover a genuinely large
  site, hierarchical (portal) pathfinding is the next step, not a finer grid.

## Invariants (inherited, do not break)

1. Critical needs still preempt everything; pathfinding never delays that.
2. Rates stay per sim-hour; teleport degradation at high time scale is
   preserved, so mass stays exact at 1× and 450× alike.
3. Scrub-back still freezes; nav adds no reversibility debt (paths are
   recomputed, never replayed).
4. The sim core stays pure — the grid reaches agents through `ctx`, exactly as
   `pos_of` and the chore board already do.
