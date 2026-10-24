class_name NpcPopulationBridge
extends RefCounted

## Glue between the graph's ambient flow tick and NpcPopulationEngine(s):
## one engine per pop-driven habitat item (specs.pop_driven). Each flow tick
## (BEFORE ResourceFlowEngine.tick) this:
##  1. feeds last tick's starved_kinds back to the agents (blocked activities
##     abort, needs keep rising),
##  2. steps the agents,
##  3. writes the aggregate consumption rates into the flow engine's habitat
##     demand override (set_habitat_demand).
## Runs inside the view's history-suppress/bulk-sync window, with the graph
## open or closed (ambient). Kept out of system_graph_view per the
## delegate-helper convention (docs/ARCHITECTURE.md debt #2).

const PERSIST_INTERVAL_H := 0.5   # snapshot into specs.pop_state at most 2x/sim-hour
## At most this many habitats persist in one tick. Every camp started on the
## same tick, so without a budget ~35 camps snapshotted, JSON-encoded and
## deep-copied their specs in ONE frame every 0.5 sim-h — every 4 s at 450x.
## Each camp's interval is also jittered (0.75..1.25x) so they drift apart.
const PERSIST_PER_TICK := 4

var _engines: Dictionary = {}          # item_id -> NpcPopulationEngine
## The LIGHT tier (festival scale): one CrowdCohort per camp that is not in
## focus, the tier each camp is currently in, and the full engines PARKED
## while their camp is light (board, labour, skills and duties stay on them,
## so promotion finds the settlement exactly as left). CrowdFocus decides.
var _cohorts: Dictionary = {}          # item_id -> CrowdCohort
var _tiers: Dictionary = {}            # item_id -> CrowdFocus.TIER_*
var _tier_pending: Dictionary = {}
var _parked: Dictionary = {}           # item_id -> NpcPopulationEngine
var _light_work_h: Dictionary = {}     # item_id -> statistical labour banked
var _watched_iid := ""
var _viewer_xz := Vector2.ZERO
var _model = null                      # last GraphModel seen by tick()
var _configured_count: Dictionary = {} # item_id -> int (reconfigure on change)
var _last_persist_h: Dictionary = {}   # item_id -> float abs-hours
var _last_persist_blob: Dictionary = {}  # item_id -> String (change gate)
## item_id -> the sim-day the duty rota last ran for. Everything in that
## service is day-granular and must not touch the substep path.
var _last_duty_day: Dictionary = {}
## Site Projects (the unified camp-lifecycle mechanic): per-habitat project
## stores, persisted into specs["site_projects"] beside pop_state.
var _project_stores: Dictionary = {}   # item_id -> SiteProjectStore
## The settlement feed — one per site, shared by every reader via cursors.
var _log: SettlementLog = null
## Built-in scenes (Soak/Mars) have no TerrainLoader to own the registry —
## fall back to a bridge-owned scene-keyed one so spaces still work there.
var _fallback_registry: SpaceRegistry = null
var _weather_cache: Dictionary = {}
var _weather_hour := -999.0
var _weather_day := -1   # month * 100 + day the cache was sampled for
var _last_abs_h := 0.0

## Navigation (Tier 3). The grid bakes in budgeted slices off the tick; until
## it is ready agents keep walking straight lines, so nothing ever stalls.
var _nav_grid: NpcNavGrid = null
var _nav_query: NpcNavQuery = null
var _nav_fp := ""
## The ground half of _nav_fp (nav_rev + region only): equal across two
## fingerprints means the finished grid's heights can be reused.
var _nav_terrain_fp := ""
var _nav_queries_this_tick := 0
var _nav_keyed_misses_this_tick := 0
var _model_item_cache: Dictionary = {}   # item_id -> item (for nav anchors)
var _nav_rev := 0            # bumped by callers when geometry moves
## Desire lines (Tier 3e): where feet actually wear paths in.
var _desire: NpcDesireMap = null
var _desire_day := -0x7fffffff
## The heat texture is built HERE, on the tick — never inside the canvas
## _draw(). Allocating a GPU resource mid-draw yields undefined contents (it
## rendered as a solid white block over the whole site).
var _desire_tex: ImageTexture = null
var _desire_tex_channel := ""
var _desire_tex_at := -1.0e9
const DESIRE_TEX_INTERVAL_S := 0.5

## Cold A* queries allowed per tick. Cache hits are unlimited — a site has ~10
## tagged spaces, so after the first day almost every trip is a hit.
const MAX_QUERIES_PER_TICK := 2
## A* searches for KEYED (space-pair) routes per tick. These used to bypass the
## budget entirely, so a crowd of hundreds warming the cache — or the burn
## crowd all moving at once — ran unbounded searches in one frame. A refused
## miss walks the straight-line fallback (round any fire) and the next tick
## tries again; hits are free.
const MAX_KEYED_MISSES_PER_TICK := 24
## Terrain sampling is the expensive part of the bake, and on scenes with no
## TerrainLoader every sample is a raycast. Keep the slice conservative.
const NAV_CELLS_PER_TICK := 1200
## The nav bake is TIME-budgeted, per tick AND per rendered frame
## (service_frame). A fixed 1200 cells per 2 Hz tick baked a festival-sized
## 640k-cell grid in ~4.4 minutes — the whole time people walked straight
## lines through tents — and still landed as one lump per tick.
const NAV_BAKE_CHUNK := 150
const NAV_TICK_BUDGET_US := 2000
const NAV_FRAME_BUDGET_US := 1500
## Region centre/extent are snapped to this before hashing, so a space moving
## a few centimetres does not throw away a finished bake.
const NAV_REGION_SNAP_M := 5.0
## Surface probing (upper levels). Rays start this far above the ground and a
## hit only counts as another level once it clears the ground by this much.
const SURFACE_PROBE_TOP_M := 12.0
const SURFACE_MIN_CLEARANCE_M := 1.6
## LIVE venue states, resolved ONCE per tick for every venue (NpcVenueState:
## a stage's programme, an effigy's FIRE RECORD off its tagged prop), plus
## each stage's front edge + facing for VenueCrowd's fan. Both tiers read
## them through ctx; `_event_active` is the enrichment-gate waiver.
var _venue_states: Dictionary = {}
var _venue_fronts: Dictionary = {}
var _event_active := false
## The burn on now (its identity for turnout — VenueCrowd.attends), "" = none.
var _burn_key := ""
## Burn roles per effigy space: {key, performers: [ids], sandmen: {id: {post,
## face, state ("post" | "redirect"), since}}, handled: {id: abs_h}}.
var _burns: Dictionary = {}
## A sandman holds a redirect this long (sim hours) before kneeling again.
const REDIRECT_HOLD_H := 0.012
## A person turned back is not chased again for this long.
const REDIRECT_COOLDOWN_H := 0.03
## sid -> "phase|active" last tick, so a phase change wakes the people there.
var _venue_phase_keys: Dictionary = {}
var _event_was := false
## sid -> radius currently stamped F_BLOCKED on the nav grid for a burning /
## burnt effigy, so people neither stand nor walk inside the fire perimeter.
var _fire_stamps: Dictionary = {}
## Beds: sleep AREA space id -> expanded list of {pos, yaw} (one entry per
## sleeper a shelter holds), refreshed when the camps change.
var _sleep_spots: Dictionary = {}
## Seats and beds ON placed furniture (flat-pack designer pieces): space id ->
## [{pos (world xz), yaw, elev (m above the ground), kind (sit | lie)}].
var _seat_spots: Dictionary = {}
var _seat_spots_at_ms := -100000
var _sleep_spots_rev := -1
## The population region from the last tick (anchors / centre / half) — the
## crowd renderer builds its height raster over it.
var _last_region: Dictionary = {}

## Cached agent_dots() payload. NpcPopulationHost calls agent_dots() every
## RENDER frame, and the Site Plan provider calls it again, but the simulation
## only steps on a 0.25–0.5 s accumulator — so the payload was identical between
## steps while being rebuilt from scratch: a fresh 15-key Dictionary per agent
## per frame, including NpcMorale.color(), NpcMorale.label() and
## status_line()'s string building. At 24 agents and 60 fps that is ~1,440
## dictionaries and ~2,900 transient strings per second, all discarded.
var _dots_cache: Array = []
## prop_id -> {node: instance id, size: {height_m, footprint_r_m}} (unlit effigies)
var _effigy_sizes: Dictionary = {}
var _persist_budget := PERSIST_PER_TICK
## Light camps waiting for their slice of a frame (see _drain_light_queue).
## Ticking ~37 camps in the one tick frame was the 15-18 ms crowd_sim spike.
var _light_queue: Array = []
var _light_queued: Dictionary = {}
var _light_ctx: Dictionary = {}
var _defer_light := false
const LIGHT_FRAME_BUDGET_US := 2500
## Set by the view each tick: is a desire-line overlay (Site Plan or 3D) on?
var desire_texture_wanted := false
## Camp beds per home point, keyed by the same prop/camp revision the sleep
## spots use: _home_beds rebuilt every camp's shelters and scanned every placed
## prop for EVERY light camp on EVERY tick (camps x shelters).
var _home_beds_cache: Dictionary = {}
var _home_beds_rev := -1
var _dots_cache_valid := false
var _dots_full: Array = []
var _dots_full_valid := false
var _dots_full_gen := -1
## Weather comfort (NpcComfort): this tick's pulls, whether hard rain is on
## (its onset wakes the site), and the shade / warmth spot lists the tiers'
## `comfort_spot` reads — rebuilt when props, camps or lit pits change.
var _comfort: Dictionary = {}
## Harness / testing: when non-empty, used INSTEAD of the weather's pulls
## ({heat, cold, rain, night}).
var comfort_override: Dictionary = {}
var _rain_on := false
var _comfort_rev := -1
var _comfort_built_h := -INF
var _shade_spots: Array = []            # {pos, yaw, size}
var _warm_spots: Array = []             # {pos, r}
var _shade_grid: Dictionary = {}
var _warm_grid: Dictionary = {}
const COMFORT_REACH_M := 220.0
const COMFORT_CHOICES := 4
const COMFORT_CELL_M := 100.0
const COMFORT_REFRESH_H := 1.0
## Rain this hard (as a pull share) counts as "it is pouring" for the wake.
const RAIN_WAKE_PULL := 0.25
## Firepits: prop id -> lit (FirepitBuilder.lit_for, the same rule the visual uses).
var _firepit_lit: Dictionary = {}
var _firepit_pos: Dictionary = {}
## A pit that is not burning draws a fraction of a fire circle's crowd. Every
## BURNING fire circle pulls by its heat (NpcComfort.fire_warmth x this; never
## an EVENT — that stays the burn's).
const UNLIT_PIT_DRAW := 0.35
const FIRE_HEAT_PULL := 0.8
## Fire circle id -> "lit|music" last tick (a change re-poses its crowd).
var _fire_keys: Dictionary = {}
## Prop geometry per prop id: {node, poly, r, centre, deck} (deck measured
## lazily, stages only). Re-measured when the prop is rebuilt (new node).
var _prop_geom: Dictionary = {}
var _prop_nodes: Dictionary = {}
var _prop_nodes_h := NAN
## DJs: stage space id -> {id, key, cast_h}. One person per set, cast DJ_LEAD_H
## before it starts; re-cast at most every DJ_RECAST_H (so a DJ who left the
## decks for the toilet is not dragged back mid-visit).
var _djs: Dictionary = {}
const DJ_LEAD_H := 0.25
const DJ_RECAST_H := 0.5
## PEAK EXPERIENCE (FUCK YES!): the field (who is peaking — the authority
## for both tiers), its score file, the last step's time, and the burst
## accumulator for the settlement log (one line per PEAK_LOG_H, not per onset).
var peaks := PeakField.new()
var _peak_path := ""
var _peak_loaded := false
var _peak_prev_h := NAN
var _peak_save_due_ms := 0
var _peak_log_n := 0
var _peak_log_venue: Dictionary = {}
var _peak_log_h := -INF
const PEAK_SAVE_DEBOUNCE_MS := 4000
const PEAK_LOG_H := 0.25
## Display prefs are statics with no signal (see NpcDisplayPrefs.generation);
## color_for_agent reads colors_enabled(), so a mid-session tint toggle has to
## invalidate the cache or it keeps serving the old colors.
var _dots_cache_gen := -1


## Step every pop-driven habitat and install demand overrides. Call before
## flow_engine.tick() inside the ambient tick's suppress window.
func tick(model, flow_engine, main: Node) -> void:
	if model == null or flow_engine == null or main == null:
		return
	if not main.has_method("get_absolute_hours"):
		return
	# The ambient path SPREADS the light camps over the following frames
	# (service_frame); tick_at called directly (the challenge bake) does not.
	_defer_light = true
	tick_at(model, flow_engine, main, float(main.call("get_absolute_hours")))
	_defer_light = false


## Same step at an EXPLICIT timestamp — the challenge bake engine advances the
## population along its own fixed-step cursor while the world clock is frozen.
func tick_at(model, flow_engine, main: Node, abs_h: float) -> void:
	if model == null or flow_engine == null or main == null:
		return
	_last_abs_h = abs_h
	_persist_budget = PERSIST_PER_TICK
	# Camps left over from the last round are ticked NOW: a light camp may lag
	# by a frame or two, never by a whole round. A direct tick_at (the
	# challenge bake, on its own cursor) drops the queue instead — those camps
	# are about to be ticked synchronously at the bake's time.
	if _defer_light:
		_drain_light_queue(-1)
	else:
		_light_queue.clear()
		_light_queued.clear()
	# Agent state is about to move, so last frame's dot payload is stale.
	_invalidate_dots()
	# Kept so the Routines panel can persist an edited schedule without being
	# handed the model separately.
	_model = model
	var hour_of_day: float = fposmod(abs_h, 24.0)
	var registry := _find_registry(main)
	# Resolve every space's world position ONCE per tick; every query this
	# tick (nearest restroom, venue choice, nav anchors) reads the cache
	# instead of resolving a prop record per candidate.
	if registry != null:
		registry.ignore_capacity = PopTestPrefs.ignore_capacity()
		registry.refresh_positions(func(space: Dictionary) -> Variant:
			return registry.resolve_position(space, main))
	PerfMonitor.begin("npc_venues")
	_service_firepits(main)
	_resolve_venues(main, registry, abs_h, hour_of_day)
	_service_djs(main, registry, abs_h, hour_of_day)
	_service_burn_roles(main, registry, abs_h)
	PerfMonitor.end("npc_venues")
	_resolve_sleep_spots(main, registry)
	_resolve_seat_spots(main, registry)
	_service_comfort(main, registry, abs_h, hour_of_day)
	_nav_queries_this_tick = 0
	_nav_keyed_misses_this_tick = 0
	var region := _population_region(main, registry)
	_last_region = region
	_service_nav(main, registry, region)
	# Deliberately NOT gated on the nav grid: tracing must start on the first
	# tick, or the desire map misses everything walked during the bake.
	_service_desire(abs_h, region)
	var seen: Dictionary = {}

	# Every pop-driven habitat, INCLUDING those inside camp compounds (a
	# festival camp is a super-node), and the tier each one runs in this tick.
	var habitats: Array = []
	var camps: Array = []
	for item in GraphNesting.walk_items(model, "root"):
		var d0: Dictionary = item
		if str(d0.get("type", "")) != "processor":
			continue
		var specs0: Dictionary = d0.get("specs", {})
		if str(specs0.get("role", "")) != "habitat" or not bool(specs0.get("pop_driven", false)):
			continue
		habitats.append(d0)
		camps.append({"id": str(d0.get("id", "")), "home": _home_pos(specs0, main),
			"count": clampi(int(float(specs0.get("occupants", 10.0))), 1, 5000)})
	var ts_mult := 0.0
	if main != null and "time_scale" in main and NpcDisplayPrefs.speed_shed():
		ts_mult = absf(float(main.get("time_scale"))) * 3600.0
	# Settings -> NPCs -> "Simulated in full" (0 = the default budget).
	var max_full := NpcDisplayPrefs.full_sim() if NpcDisplayPrefs.full_sim() > 0 else CrowdFocus.MAX_FULL_PEOPLE
	if not _tiers_frozen:
		_tiers = CrowdFocus.decide(camps, _viewer_xz, _watched_iid, _tiers, _tier_pending, abs_h,
			max_full, ts_mult)

	for item in habitats:
		var d: Dictionary = item
		var specs: Dictionary = d.get("specs", {})
		var iid := str(d.get("id", ""))
		seen[iid] = true
		_model_item_cache[iid] = d
		if str(_tiers.get(iid, CrowdFocus.TIER_FULL)) == CrowdFocus.TIER_LIGHT:
			if _defer_light:
				if not _light_queued.has(iid):
					_light_queued[iid] = true
					_light_queue.append(iid)
				_light_ctx = {"main": main, "flow": flow_engine, "model": model, "registry": registry}
			else:
				_tick_light(iid, specs, main, flow_engine, model, registry, abs_h, hour_of_day)
			continue
		var engine := _ensure_engine(iid, specs, main)
		# Last flow tick's verdict drives this tick's blocked activities.
		engine.set_starved(specs.get("starved_kinds", []) as Array)
		# One home per habitat per tick (a prop-record lookup); the ctx and the
		# home_bed_of callable used to resolve it again on every call.
		var home_xz := _home_pos(specs, main)
		var ctx := {
			# Meal-first eating: true when this habitat's meal input is wired
			# to a stocked tank. Checked ONCE per tick, not per agent — the
			# agents read the flag from ctx.
			"meal_available": flow_engine != null
				and flow_engine.has_method("habitat_kind_supplied")
				and flow_engine.habitat_kind_supplied(iid, "meal"),
			"registry": registry,
			"pos_of": func(space: Dictionary) -> Variant:
				return registry.resolve_position(space, main) if registry != null else null,
			# Bed-orientation: the yaw of a space's prop target (radians, NAN
			# unknown), so a sleeper can lie along the bed's long axis.
			"yaw_of": func(space: Dictionary) -> float:
				return registry.resolve_yaw(space, main) if registry != null else NAN,
			"chore_pos_of": func(chore: Dictionary) -> Variant:
				return _chore_position(chore, main, registry),
			"hour_of_day": hour_of_day,
			"weather": _sample_weather(main, hour_of_day),
			# LIVE venues: what each is doing now (fire phase / set), where a
			# stage's front is, and whether an EVENT is on.
			"venue_state_of": func(space: Dictionary) -> Dictionary:
				return _venue_states.get(str(space.get("id", "")), {}),
			"venue_front_of": func(sid: String) -> Dictionary:
				return _venue_fronts.get(sid, {}),
			"event_active": _event_active,
			"burn_key": _burn_key,
			# SOCIAL blocks (NpcSocial): the camp's conversation circles hang
			# off its home point and its seed — the SAME two the light tier
			# reads off the cohort, so both tiers pick the same circles.
			"camp_home": home_xz,
			"camp_seed": iid,
			"time_mult": absf(float(main.get("time_scale"))) * 3600.0 if "time_scale" in main else 0.0,
			# A bed INSIDE a shelter for slot `k` at a sleep area ({} = none).
			"bed_spot_of": func(sid: String, k: int) -> Dictionary:
				return _bed_spot(sid, k),
			# A seat or bed ON a piece of furniture for slot `k` ({} = none):
			# people sit on the bench, not inside it.
			"seat_spot_of": func(sid: String, k: int) -> Dictionary:
				return seat_spot(sid, k),
			# Weather comfort (NpcComfort): this hour's pulls, the shade /
			# warmth spot finder, and a person's own bed in this camp.
			"comfort": _comfort,
			"comfort_spot": func(kind: String, from: Vector2, aid: String) -> Dictionary:
				return _comfort_spot(kind, from, aid),
			"home_bed_of": func(aid: String) -> Variant:
				return _home_bed_of(main, home_xz, aid),
			# Fire perimeters a straight-line walk must go round.
			"no_go": _no_go_circles(),
			"plan_path": func(from_xz: Vector2, to_xz: Vector2, from_key: String,
					to_key: String, lane_seed: int) -> Variant:
				return _plan_path(from_xz, to_xz, from_key, to_key, lane_seed),
			# Climb accounting reads the BAKED GRID, never a terrain query —
			# this sits on the per-agent hot path and must stay an array
			# lookup. Returns 0 until the grid is ready, so early walking
			# simply records no ascent.
			"height_at": func(p2: Vector2) -> float:
				if _nav_grid == null or not _nav_grid.is_ready():
					return 0.0
				return _nav_grid.height_at_world(p2),
			# Used by standing slots and the separation pass to refuse a spot
			# that is not on walkable ground. Answers TRUE while the grid is
			# still baking: an unbaked grid knows nothing, and refusing
			# everything would pin the whole camp to their space centres for
			# the ~30 s it takes to map the site.
			"walkable": func(p2: Vector2) -> bool:
				if _nav_grid == null or not _nav_grid.is_ready():
					return true
				return _nav_grid.is_walkable_world(p2),
			"trace": func(a: Vector2, b: Vector2, channel: String, m: float) -> void:
				if _desire != null:
					_desire.add_segment(a, b, channel, m),
		}
		var demand: Dictionary = engine.tick(abs_h, ctx)
		flow_engine.set_habitat_demand(iid, demand)
		_dispatch_chore_effects(engine, main)
		_service_alarms(iid, engine, abs_h)
		_service_machine_chores(iid, engine, model, main, abs_h)
		_service_oncall(iid, engine, model, abs_h)
		_service_duty_roster(iid, engine, abs_h)
		var store := _ensure_project_store(iid, specs)
		store.sync(engine.chore_board, abs_h)
		_push_build_progress(store, engine.chore_board, main)
		PerfMonitor.begin("npc_persist")
		_maybe_persist(model, iid, engine, abs_h)
		PerfMonitor.end("npc_persist")

	# Habitats that stopped being pop-driven (toggle off / deleted) fall back
	# to the classic constant-rate model.
	for iid in _engines.keys():
		if not seen.has(str(iid)):
			flow_engine.clear_habitat_demand(str(iid))
			_engines.erase(iid)
			_configured_count.erase(iid)
			_last_persist_h.erase(iid)
			_last_persist_blob.erase(iid)
			_project_stores.erase(iid)
	for iid in _cohorts.keys():
		if not seen.has(str(iid)):
			flow_engine.clear_habitat_demand(str(iid))
			_cohorts.erase(iid)
			_parked.erase(iid)
			_configured_count.erase(iid)
			_tiers.erase(iid)
			_last_persist_h.erase(iid)
			_last_persist_blob.erase(iid)
	PerfMonitor.begin("npc_peaks")
	_service_peaks(main, registry, abs_h)
	PerfMonitor.end("npc_peaks")


# ---------------------------------------------------------------------------
# Peak experience (FUCK YES!)
# ---------------------------------------------------------------------------

## Run the PeakField over everyone on site (both tiers, one neighbourhood
## count), push each person's verdict back to their tier (the glow, the
## label) and lift peakers' morale; count onsets into the saved score.
func _service_peaks(main: Node, registry: SpaceRegistry, abs_h: float) -> void:
	if not _peak_loaded:
		_peak_loaded = true
		_peak_path = _peak_score_path(main)
		peaks.load_from(_peak_path)
	var chunks: Array = []
	for iid in _cohorts:
		if str(_tiers.get(iid, CrowdFocus.TIER_FULL)) != CrowdFocus.TIER_LIGHT:
			continue
		var ch := (_cohorts[iid] as CrowdCohort).peak_inputs(abs_h)
		ch["cohort"] = _cohorts[iid]
		chunks.append(ch)
	for iid in _engines:
		chunks.append((_engines[iid] as NpcPopulationEngine).peak_inputs())
	if chunks.is_empty():
		return
	var boost: Dictionary = {}
	var labels: Dictionary = {}
	if registry != null:
		for sid in _venue_states:
			var rec := registry.find_by_id(str(sid))
			var stype := str(rec.get("space_type", ""))
			boost[sid] = NpcPeak.venue_boost(stype, _venue_states[sid])
			var lbl := str(rec.get("label", ""))
			labels[sid] = lbl.trim_prefix(FestivalSeedLayout.LABEL_PREFIX) if not lbl.is_empty() \
				else SpaceTypes.label(stype)
	var before := peaks.total
	peaks.contagion = PopTestPrefs.peak_contagion()
	peaks.step(abs_h, chunks, boost, labels)
	var dt := 0.0 if is_nan(_peak_prev_h) else clampf(abs_h - _peak_prev_h, 0.0, 1.0)
	_peak_prev_h = abs_h
	for ch in chunks:
		var c: Dictionary = ch
		var ids: PackedStringArray = c["ids"]
		if c.has("cohort"):
			var co: CrowdCohort = c["cohort"]
			var idx: PackedInt32Array = c["idx"]
			for k in ids.size():
				var since := peaks.since_of(ids[k])
				co.set_peak(idx[k], since)
				co.set_buzz(idx[k], peaks.buzz_of(ids[k]), peaks.fed_by(ids[k]))
				if not is_nan(since) and dt > 0.0:
					co.lift_morale(idx[k], dt)
		else:
			var refs: Array = c["agents"]
			for k in ids.size():
				var a: NpcAgent = refs[k]
				a.peak_since = peaks.since_of(ids[k])
				a.peak_buzz = peaks.buzz_of(ids[k])
				a.peak_fed = peaks.fed_by(ids[k])
				if not is_nan(a.peak_since) and dt > 0.0:
					a.morale = NpcPeak.lift(a.morale, dt)
	var onsets := peaks.total - before
	if onsets > 0:
		_invalidate_dots()
		_peak_log_n += onsets
		for e in peaks.peek_recent(onsets):
			var v := str((e as Dictionary).get("venue", ""))
			_peak_log_venue[v] = int(_peak_log_venue.get(v, 0)) + 1
	if _peak_log_n > 0 and abs_h - _peak_log_h >= PEAK_LOG_H:
		_flush_peak_log(abs_h)
	if peaks.take_changed():
		_peak_save_due_ms = Time.get_ticks_msec() + PEAK_SAVE_DEBOUNCE_MS
	if _peak_save_due_ms > 0 and Time.get_ticks_msec() >= _peak_save_due_ms:
		_peak_save_due_ms = 0
		peaks.save(_peak_path)


func _flush_peak_log(abs_h: float) -> void:
	var top := ""
	var top_n := 0
	for v in _peak_log_venue:
		if int(_peak_log_venue[v]) > top_n and not str(v).is_empty():
			top_n = int(_peak_log_venue[v])
			top = str(v)
	var text := "%d %s hit %s%s" % [_peak_log_n, "person" if _peak_log_n == 1 else "people", NpcPeak.LABEL,
		(" at " + top) if not top.is_empty() else ""]
	settlement_log().add("peak", text, abs_h, SettlementLog.INFO, "",
		{"title": "Peak Experience", "detail": text})
	_peak_log_n = 0
	_peak_log_venue = {}
	_peak_log_h = abs_h


## user://maps/peak_experience_<lat>_<lon>.json on a generated map (the
## coordinate token every per-map file uses), else keyed by the scene.
func _peak_score_path(main: Node) -> String:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and loader.get("_lat") != null:
		return WorldPaths.site_file("peak_experience", float(loader.get("_lat")), float(loader.get("_lon")))
	if main != null and not str(main.scene_file_path).is_empty():
		return WorldPaths.scene_file("peak_experience", str(main.scene_file_path))
	return ""


## {total, today, now, best} for the score chip and the HUD.
func peak_score() -> Dictionary:
	return {"total": peaks.total, "today": peaks.today(_last_abs_h),
		"now": peaks.peaking_count(), "best": peaks.best}


func peaking_count() -> int:
	return peaks.peaking_count()


## Onsets after serial `after`, NOT consumed (the ground ripples), and the
## latest serial — {serial, events}.
func peak_events_since(after: int) -> Dictionary:
	return {"serial": peaks.serial, "events": peaks.events_since(after)}


## How many people are more than `frac` of the way to a peak right now.
func peak_building(frac: float = 0.5) -> int:
	var n := 0
	for id in peaks.charge:
		if peaks.buzz_of(str(id)) >= frac:
			n += 1
	return n


## Onsets since the last call (the toast drains these).
func take_peak_events() -> Array:
	return peaks.take_events()


func is_peaking(agent_id: String) -> bool:
	return peaks.is_peaking(agent_id)


# ---------------------------------------------------------------------------
# Light tier (festival scale)
# ---------------------------------------------------------------------------

## Tick queued light camps until `budget_us` is spent (-1 = all of them).
## Each camp is ticked to the clock AS IT IS NOW — the light tier is
## event-driven, so ticking camp A this frame and camp B the next is exact;
## demand lands on the flow engine for its next step either way. Returns how
## many camps were ticked.
func _drain_light_queue(budget_us: int) -> int:
	if _light_queue.is_empty() or _light_ctx.is_empty():
		return 0
	var main: Node = _light_ctx.get("main")
	var model = _light_ctx.get("model")
	if main == null or not is_instance_valid(main) or model == null \
			or not main.has_method("get_absolute_hours"):
		_light_queue.clear()
		_light_queued.clear()
		return 0
	var t0 := Time.get_ticks_usec()
	var n := 0
	while not _light_queue.is_empty():
		if budget_us >= 0 and n > 0 and Time.get_ticks_usec() - t0 >= budget_us:
			break
		var iid := str(_light_queue.pop_front())
		_light_queued.erase(iid)
		var item: Dictionary = model.get_item(iid)
		if item.is_empty() or str(_tiers.get(iid, CrowdFocus.TIER_FULL)) != CrowdFocus.TIER_LIGHT:
			continue
		var abs_h := float(main.call("get_absolute_hours"))
		if abs_h < _last_abs_h:
			abs_h = _last_abs_h
		_tick_light(iid, item.get("specs", {}) as Dictionary, main, _light_ctx.get("flow"),
			model, _light_ctx.get("registry"), abs_h, fposmod(abs_h, 24.0))
		n += 1
	if n > 0:
		_dots_cache_valid = false
	return n


## Where the player (camera) is, for the focus policy. Set by the view each
## ambient tick; a site that fits the full budget never reads it.
func set_viewer(xz: Vector2) -> void:
	_viewer_xz = xz


## A camp the player is watching (settlement view / graph selection) is
## always full detail.
func set_watched_habitat(item_id: String) -> void:
	_watched_iid = item_id


func tier_of(item_id: String) -> String:
	return str(_tiers.get(item_id, CrowdFocus.TIER_FULL))


func cohort_for(item_id: String) -> CrowdCohort:
	return _cohorts.get(item_id)


## Every light-tier camp: {item_id: CrowdCohort}. The crowd renderer's input.
func light_cohorts() -> Dictionary:
	return _cohorts


func last_abs_h() -> float:
	return _last_abs_h


## Statistical labour banked by a light camp since the last call (person-
## hours at their productivity). Phase 5 credits it to the camp's board.
func take_light_work_hours(item_id: String) -> float:
	var h := float(_light_work_h.get(item_id, 0.0))
	_light_work_h.erase(item_id)
	return h


func _tick_light(iid: String, specs: Dictionary, main: Node, flow_engine, model,
		registry: SpaceRegistry, abs_h: float, hour_of_day: float) -> void:
	var cohort := _ensure_cohort(iid, specs, main, registry)
	cohort.set_starved(specs.get("starved_kinds", []) as Array)
	var parked: NpcPopulationEngine = _parked.get(iid)
	cohort.has_work = parked != null and parked.chore_board != null \
			and not parked.chore_board.chores.is_empty()
	var ctx := {
		"registry": registry,
		"hour_of_day": hour_of_day,
		"abs_hours": abs_h,
		"weather": _sample_weather(main, hour_of_day),
		"meal_available": flow_engine != null and flow_engine.has_method("habitat_kind_supplied")
			and flow_engine.habitat_kind_supplied(iid, "meal"),
		"routine": cohort.routine,
		"venue_state_of": func(space: Dictionary) -> Dictionary:
			return _venue_states.get(str(space.get("id", "")), {}),
		"venue_front_of": func(sid: String) -> Dictionary:
			return _venue_fronts.get(sid, {}),
		"event_active": _event_active,
		"burn_key": _burn_key,
		# The light tier follows the same routes as the full one.
		"plan_path": func(from_xz: Vector2, to_xz: Vector2, from_key: String,
				to_key: String, lane_seed: int) -> Variant:
			return _plan_path(from_xz, to_xz, from_key, to_key, lane_seed),
		"no_go": _no_go_circles(),
		"comfort": _comfort,
		"comfort_spot": func(kind: String, from: Vector2, aid: String) -> Dictionary:
			return _comfort_spot(kind, from, aid),
	}
	# Home beds: the shelters of the camp this habitat stands in.
	var beds := _home_beds(main, cohort.home)
	if beds.size() > 0 and beds != cohort.home_slots:
		cohort.home_slots = beds
	PerfMonitor.begin("crowd_sim")
	var demand: Dictionary = cohort.tick(abs_h, ctx)
	PerfMonitor.end("crowd_sim")
	flow_engine.set_habitat_demand(iid, demand)
	# What was consumed AT bound venues (a portapotty bank, a water station)
	# lands on those tanks, not on this camp's habitat.
	var flows := cohort.take_venue_flows()
	if flow_engine.has_method("add_external_flow"):
		for item_id in flows:
			for kind in flows[item_id]:
				flow_engine.add_external_flow(str(item_id), str(kind), float(flows[item_id][kind]))
	_light_work_h[iid] = float(_light_work_h.get(iid, 0.0)) + cohort.take_work_hours()
	PerfMonitor.begin("npc_persist")
	_maybe_persist_light(model, iid, cohort, abs_h)
	PerfMonitor.end("npc_persist")


func _ensure_cohort(iid: String, specs: Dictionary, main: Node, registry: SpaceRegistry) -> CrowdCohort:
	var count := clampi(int(float(specs.get("occupants", 10.0))), 1, 5000)
	var cohort: CrowdCohort = _cohorts.get(iid)
	if cohort != null and int(_configured_count.get(iid, -1)) == count:
		return cohort
	if cohort != null and int(_configured_count.get(iid, -1)) > 0:
		# The headcount moved (the festival population slider): resize IN
		# PLACE — a rebuild respawned the whole camp at home.
		cohort.resize(count, registry)
		_configured_count[iid] = count
		_invalidate_dots()
		return cohort
	var home := _home_pos(specs, main)
	if _engines.has(iid):
		# Demotion: park the engine (its board, labour and skills are not
		# people) and hand its people to the crowd.
		var engine: NpcPopulationEngine = _engines[iid]
		cohort = NpcTierConvert.to_light(engine, registry, home)
		_parked[iid] = engine
		_engines.erase(iid)
	else:
		cohort = CrowdCohort.new()
		var snap: Dictionary = specs.get("pop_state", {}) as Dictionary
		if CrowdCohort.is_light_snapshot(snap) and int(snap.get("n", -1)) == count:
			cohort.restore(snap)
		elif not snap.is_empty() and (snap.get("agents", []) as Array).size() == count:
			# Saved while full: rebuild that roster and convert it.
			var e := NpcPopulationEngine.new()
			e.restore(snap)
			cohort = NpcTierConvert.to_light(e, registry, home)
		else:
			cohort.configure(count, iid, home)
	var routine_arr: Array = specs.get("pop_routine", []) as Array
	cohort.routine = NpcRoutine.from_array(routine_arr) if not routine_arr.is_empty() \
		else NpcRoutine.default_day()
	cohort.consequence = NpcConsequence.normalize(specs.get("pop_consequence", ""))
	cohort.agent_departed.connect(
		func(_aid: String, who: String, reason: String) -> void:
			var why := _need_text(reason)
			settlement_log().add("departed", "%s left — %s" % [who, why],
				_last_abs_h, SettlementLog.ALERT, iid,
				{"title": "%s left" % who, "detail": why}))
	cohort.collapse_warning.connect(
		func(_risk: float) -> void:
			settlement_log().add("collapse_warning",
				"People are talking about leaving",
				_last_abs_h, SettlementLog.ALERT, iid,
				{"title": "The community is unravelling",
					"detail": "people are talking about leaving"}))
	cohort.colony_collapsed.connect(
		func() -> void:
			settlement_log().add("collapsed",
				"Colony collapse — too few people remain",
				_last_abs_h, SettlementLog.ALERT, iid,
				{"title": "Colony collapse",
					"detail": "too few people remain to keep this place running"}))
	cohort.colony_deserted.connect(
		func(cause: String) -> void:
			var why2 := _need_text(cause)
			settlement_log().add("deserted", "Everyone has left — %s" % why2,
				_last_abs_h, SettlementLog.ALERT, iid,
				{"title": "Everyone has left",
					"detail": "%s · fix it, then Reset population" % why2}))
	_cohorts[iid] = cohort
	_configured_count[iid] = count
	_invalidate_dots()
	return cohort


## The light tier's compact snapshot rides the same specs.pop_state key.
func _maybe_persist_light(model, iid: String, cohort: CrowdCohort, abs_h: float) -> void:
	if not _persist_due(iid, abs_h):
		return
	var snap := cohort.snapshot(abs_h)
	var blob := JSON.stringify(snap)
	if str(_last_persist_blob.get(iid, "")) == blob:
		return
	_last_persist_blob[iid] = blob
	var item: Dictionary = model.get_item(iid)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["pop_state"] = snap
	specs["pop_present"] = cohort.alive_count()
	specs["pop_morale"] = snappedf(cohort.mean_morale(), 0.01)
	specs["pop_collapse_risk"] = snappedf(cohort.collapse_risk(), 0.01)
	model.update_item(iid, {"specs": specs})


## Site Projects: completed chores carrying an `effect` payload fire it here,
## EXACTLY ONCE — the post-tick world-effect sweep. This deliberately lives in
## the bridge (scene glue), never inside the pure engine: effects mutate
## props, and the engine's determinism must not depend on scene state.
## Fire-once is board state (`effect_done` beside the effect, persisted with
## the chores inside pop_state), so it survives save/load, scrub-back (the
## engine freezes; the flag holds), and coarse catch-up jumps. Order is the
## board's array order — deterministic, never dict-key order.
## A failed dispatch (loader not ready yet) stays un-stamped and simply
## retries next sweep; every op is idempotent-safe for that.
func _dispatch_chore_effects(engine: NpcPopulationEngine, main: Node) -> void:
	var board := engine.chore_board
	if board == null:
		return
	for c in board.chores:
		var chore: Dictionary = c
		if str(chore.get("repeat", "daily")) != "once":
			continue   # world effects ride one-shot project tasks only (v1)
		# INCREMENTAL stage effects first (a brigade moves crates one by one
		# while the chore is still in flight), then the completion effect.
		for idx in SiteProject.due_stage_effects(chore):
			var st := ((chore.get("stage_effects", []) as Array)[idx]) as Dictionary
			if SiteProjectEffects.execute(main, st.get("effect", {}) as Dictionary):
				st["fired"] = true
		if int(chore.get("done_day", -1)) < 0:
			continue
		var effect: Dictionary = chore.get("effect", {})
		if effect.is_empty() or bool(chore.get("effect_done", false)):
			continue
		if SiteProjectEffects.execute(main, effect):
			chore["effect_done"] = true


# --- Site Projects -----------------------------------------------------------

func _ensure_project_store(iid: String, specs: Dictionary) -> SiteProjectStore:
	var store: SiteProjectStore = _project_stores.get(iid)
	if store != null:
		return store
	store = SiteProjectStore.new()
	var saved: Variant = specs.get("site_projects", [])
	if saved is Array:
		store.deserialize(saved as Array)
	_project_stores[iid] = store
	return store


## A linkage build project as a LinkageBuildSite (labour mode) reads it:
## {found, state, progress 0..1 (labour-weighted, SiteProject.rollup),
## present: [{id, pos: Vector2, color}] — the people DOING one of the
## project's chores within `radius_m` of `center`}. Read-only.
func linkage_build_status(iid: String, project_id: String, center: Vector2, radius_m: float) -> Dictionary:
	var store := project_store_for(iid)
	var project: Dictionary = store.find(project_id) if store != null else {}
	if project.is_empty():
		return {"found": false}
	var board := chore_board_for(iid)
	var roll: Dictionary = SiteProject.rollup(project, board) if board != null else {}
	var chores := {}
	for t in project.get("tasks", []):
		chores[str((t as Dictionary).get("chore_id", ""))] = true
	var present: Array = []
	var engine: NpcPopulationEngine = _engines.get(iid)
	if engine != null:
		for a in engine.agents:
			var ag: NpcAgent = a
			if ag.state == NpcAgent.State.DOING and chores.has(ag.chore_id) \
					and ag.pos.distance_to(center) <= radius_m:
				present.append({"id": ag.id, "pos": ag.pos,
					"color": NpcPopulationEngine.color_for_agent(ag.id)})
	return {"found": true, "state": str(project.get("state", "")),
		"progress": float(roll.get("progress", 0.0)), "present": present}


func project_store_for(iid: String) -> SiteProjectStore:
	var item: Dictionary = _model_item_cache.get(iid, {})
	return _ensure_project_store(iid, item.get("specs", {}) as Dictionary)


## Capture everything NpcExperimentLab needs, ONCE, as plain data.
##
## This is the scene-glue half of the experiment: the lab itself must never
## touch `main`, an autoload, or the nav grid, so every scene-dependent lookup
## (space positions, prop positions, weather) is pre-resolved here into flat
## dictionaries. Pre-resolving also frames the honest question the lab
## answers — "given the layout exactly as it stands right now".
func experiment_setup(iid: String, project_id: String, main: Node) -> Dictionary:
	var engine: NpcPopulationEngine = _engines.get(iid)
	var project := project_store_for(iid).find(project_id)
	if engine == null or project.is_empty() or engine.chore_board == null:
		return {}
	var board := engine.chore_board
	var reg := _find_registry(main)
	# Chore specs, rebuilt from the LIVE board but reset to un-started: the
	# lab re-runs the plan from scratch, and inheriting half-done work (or a
	# `held` flag from a paused project) would make every row meaningless.
	var specs: Array = []
	var prop_pos: Dictionary = {}
	var gate := ""
	for t in project.get("tasks", []):
		var task: Dictionary = t
		var chore: Dictionary = board.find(str(task.get("chore_id", "")))
		if chore.is_empty():
			continue
		var tgt: Dictionary = chore.get("target", {})
		if str(tgt.get("kind", "")) == "prop":
			var p: Variant = _chore_position(chore, main, reg)
			if p is Vector2:
				prop_pos[str(tgt.get("id", ""))] = p
		specs.append({
			"task_id": str(task.get("task_id", "")),
			"label": str(chore.get("label", "")),
			"chore_hours": float(chore.get("chore_hours", 0.1)),
			"priority": int(chore.get("priority", 0)),
			"exposure": str(chore.get("exposure", "outdoor")),
			"min_workers": int(chore.get("min_workers", 1)),
			"max_workers": int(chore.get("max_workers", 1)),
			"depends_on": _task_ids_for_deps(project, board, chore),
			"target": tgt.duplicate(true),
			"haul": (chore.get("haul", {}) as Dictionary).duplicate(true),
		})
		gate = str(task.get("task_id", ""))
	var space_pos: Dictionary = {}
	if reg != null:
		for sp in reg.spaces:
			var sd: Dictionary = sp
			var p2: Variant = reg.resolve_position(sd, main)
			if p2 is Vector2:
				space_pos[str(sd.get("id", ""))] = p2
	var item: Dictionary = _model_item_cache.get(iid, {})
	var specs_live: Dictionary = item.get("specs", {})
	return {
		"project_id": project_id, "iid": iid,
		"kind": str(project.get("kind", "")),
		"chore_specs": specs, "gate_task_id": gate,
		# The pure scheduler's task graph, so the lab can report a PLANNED
		# lower bound beside each simulated makespan. A linkage build stores
		# the fab counts rather than the tasks, so rebuild them.
		"plan_tasks": _experiment_plan_tasks(project),
		"registry_blob": reg.serialize() if reg != null else {},
		"space_pos": space_pos, "prop_pos": prop_pos,
		"weather": _weather_cache.duplicate(true),
		"starved": (specs_live.get("starved_kinds", []) as Array).duplicate(),
		"roster_size": engine.agents.size(),
		"home": _home_pos(specs_live, main),
		"routine": engine.routine.to_array() if engine.routine != null else [],
		"rules": board.rules.duplicate(true),
		# The project's REAL window, not a literal. Hardcoding {7,19} meant the
		# lab's "Longer window" row compared against a window the site was not
		# using.
		"window": _experiment_window(project, board),
		"target": {"kind": "pos",
			"x": float((project.get("site", {}) as Dictionary).get("x", 0.0)),
			"z": float((project.get("site", {}) as Dictionary).get("z", 0.0))},
		"start_h": _last_abs_h,
		"day_index": NpcChoreBoard.day_index(_last_abs_h),
		"haul": _experiment_haul(project, board, main, reg),
	}


## The widest window any of this project's chores actually runs in.
func _experiment_window(project: Dictionary, board) -> Dictionary:
	var lo := INF
	var hi := -INF
	for t in project.get("tasks", []):
		var chore: Dictionary = board.find(str((t as Dictionary).get("chore_id", "")))
		var w: Dictionary = chore.get("window", {})
		if w.is_empty():
			continue
		lo = minf(lo, float(w.get("start_h", 7.0)))
		hi = maxf(hi, float(w.get("end_h", 19.0)))
	if lo == INF or hi <= lo:
		return {"start_h": 7.0, "end_h": 19.0}
	return {"start_h": lo, "end_h": hi}


## The NpcCrewPlan task graph behind a project, or [] when there isn't one.
## Without this every `plan_h` is 0 and the drag column would report the whole
## makespan as drag — worse than reporting nothing.
func _experiment_plan_tasks(project: Dictionary) -> Array:
	var plan: Dictionary = project.get("plan", {})
	var stored: Array = plan.get("tasks", []) as Array
	if not stored.is_empty():
		return stored
	var counts: Dictionary = plan.get("fab_counts", {})
	if not counts.is_empty():
		return NpcCrewPlan.linkage_fab_tasks(counts)
	return []


## Live chore-id deps mapped back onto plan task ids (the lab rebuilds a board
## from scratch, so board ids mean nothing to it).
func _task_ids_for_deps(project: Dictionary, _board, chore: Dictionary) -> Array:
	var by_cid: Dictionary = {}
	for t in project.get("tasks", []):
		by_cid[str((t as Dictionary).get("chore_id", ""))] = \
			str((t as Dictionary).get("task_id", ""))
	var out: Array = []
	for d in chore.get("depends_on", []):
		if by_cid.has(str(d)):
			out.append(str(by_cid[str(d)]))
	return out


## Crate list for the haul-strategy variants, or {} when this is not a
## delivery (those rows then report "n/a" rather than silently vanishing).
func _experiment_haul(project: Dictionary, board, main: Node, reg) -> Dictionary:
	if str(project.get("kind", "")) != SiteProject.KIND_DELIVERY:
		return {}
	var crates: Array = []
	var from := Vector2.ZERO
	var rec: Dictionary = PlacedPropService.get_prop_record(main,
		str(project.get("prop_id", "")))
	if not rec.is_empty():
		from = Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	for t in project.get("tasks", []):
		var chore: Dictionary = board.find(str((t as Dictionary).get("chore_id", "")))
		var ct: Dictionary = chore.get("target", {})
		if str(ct.get("kind", "")) != "prop":
			continue
		var carry: Dictionary = chore.get("carry_to", {})
		if carry.is_empty():
			continue
		crates.append({"pid": str(ct.get("id", "")),
			"stage": Vector2(float(carry.get("x", 0.0)), float(carry.get("z", 0.0))),
			"label": str(chore.get("label", "crate"))})
	# A brigade project has ONE chore carrying every crate as a stage effect.
	if crates.is_empty():
		for t2 in project.get("tasks", []):
			var ch2: Dictionary = board.find(str((t2 as Dictionary).get("chore_id", "")))
			for st in (ch2.get("stage_effects", []) as Array):
				var eff: Dictionary = (st as Dictionary).get("effect", {})
				if str(eff.get("op", "")) != "move_prop":
					continue
				crates.append({"pid": str(eff.get("prop_id", "")),
					"stage": Vector2(float(eff.get("x", 0.0)), float(eff.get("z", 0.0))),
					"label": "crate"})
	return {"crates": crates, "from": from} if not crates.is_empty() else {}


## Every habitat's projects, flattened for the panel: [{iid, project}].
func all_site_projects() -> Array:
	var out: Array = []
	for iid in _project_stores:
		for p in (_project_stores[iid] as SiteProjectStore).projects:
			out.append({"iid": str(iid), "project": p})
	return out


## Create a project: drop the plan onto the habitat's board (ATOMIC — a board
## that can't take the whole plan refuses and this returns ""), bind task ids
## to the created chores, store the record, and force the next tick to
## persist. `spec_rows` are chore_specs-shaped rows (may carry per-task
## target/effect/carry_to/haul).
func create_site_project(iid: String, kind: String, label: String,
		prop_id: String, site: Vector2, spec_rows: Array,
		window: Dictionary = {"start_h": 7.0, "end_h": 19.0},
		target: Dictionary = {}, plan_meta: Dictionary = {}) -> String:
	var board = chore_board_for(iid)
	if board == null:
		return ""
	var made: Array = board.add_plan(spec_rows, window, target)
	if made.is_empty():
		return ""
	var project := SiteProject.make(kind, label, prop_id, site, _last_abs_h, plan_meta)
	SiteProject.bind_tasks(project, spec_rows, made)
	project_store_for(iid).add(project)
	_last_persist_h.erase(iid)   # persist on the next tick, not in half an hour
	return str(project.get("id", ""))


## Pause/resume: holds every still-pending task's chore out of available_for
## without losing progress. Workers already on a held chore finish their
## current step and release naturally (credit still pays — pausing mid-swing
## must not void labour already under way).
func set_project_paused(iid: String, project_id: String, paused: bool) -> void:
	var board = chore_board_for(iid)
	var project := project_store_for(iid).find(project_id)
	if board == null or project.is_empty():
		return
	for t in project.get("tasks", []):
		var task: Dictionary = t
		if str(task.get("status", "pending")) == "pending":
			board.update_chore(str(task.get("chore_id", "")), {"held": paused})
	project["paused"] = paused
	_last_persist_h.erase(iid)


## Cancel: remove every still-pending chore from the board (their effects
## never fire) and mark the project cancelled. Completed tasks keep their
## fired effects — cancellation is "stop here", not an undo.
##
## EXCEPT crew-assembly projects, where cancel IS an undo: an unfinished
## structure is just parts laid out on the ground, so the debited parts go
## back to the inventory (`plan.refund_parts`, erased fire-once) and the
## ghost prop is cleared. Needs `main` for the loader; without it the
## project still cancels but nothing is refunded.
func cancel_project(iid: String, project_id: String, main: Node = null) -> void:
	var board = chore_board_for(iid)
	var project := project_store_for(iid).find(project_id)
	if project.is_empty():
		return
	for t in project.get("tasks", []):
		var task: Dictionary = t
		if str(task.get("status", "pending")) == "pending" and board != null:
			board.remove_chore(str(task.get("chore_id", "")))
			task["status"] = "skipped"
	project["state"] = "cancelled"
	project["ended_h"] = current_abs_hours()
	if main != null and str(project.get("kind", "")) == "assembly":
		var plan: Dictionary = project.get("plan", {})
		var refund: Dictionary = plan.get("refund_parts", {})
		var loader := TerrainSurfaceQuery.find_terrain_loader(main)
		if not refund.is_empty() and loader != null \
				and loader.has_method("get_part_inventory"):
			var inv: Variant = loader.call("get_part_inventory")
			if inv != null:
				for pid in refund:
					inv.add_part(str(pid), int(refund[pid]))
				loader.call("save_part_inventory")
				plan.erase("refund_parts")
		var prop_id := str(project.get("prop_id", ""))
		if not prop_id.is_empty() and loader != null \
				and loader.has_method("delete_prop_by_id"):
			loader.call_deferred("delete_prop_by_id", prop_id)
	_last_persist_h.erase(iid)


## Live progressive-build visuals: push each active linkage project's real
## labour fractions onto the structure builder standing at its prop. Node
## lookup + visible_instance_count writes only — nothing here persists (the
## coarse phase lands in the record via the set_build_phase chore effects,
## which is what a fresh load renders until this refines it).
func _push_build_progress(store: SiteProjectStore, board, main: Node) -> void:
	if main == null:
		return
	# Iterate EVERY project, not just active(): a cancelled teardown has to get
	# its visuals restored, and only this function can reach the builder.
	for p in store.projects:
		var project: Dictionary = p
		var kind := str(project.get("kind", ""))
		if kind != SiteProject.KIND_LINKAGE_BUILD \
				and kind != SiteProject.KIND_LINKAGE_BREAKDOWN:
			continue
		var builder := _linkage_builder_for(main, str(project.get("prop_id", "")))
		if builder == null:
			continue
		# A labour-mode build site (per-worker timeline) stages the parts itself.
		var site: Node = builder.get_parent().get_node_or_null("LinkageBuildSite") \
			if builder.get_parent() != null else null
		if site != null and site.has_method("owns_visuals") and bool(site.call("owns_visuals")):
			continue
		if str(project.get("state", "")) != "active":
			# Cancelled or finished mid-teardown. set_ghost_alpha swaps in
			# DUPLICATED materials and only alpha >= 0.999 restores the shared
			# originals, so without this a cancelled breakdown leaves the
			# structure permanently translucent with its bolts missing.
			# Fire-once via a stamp — this runs every tick.
			if not bool(project.get("vis_reset", false)):
				builder.call("set_build_progress", {})
				builder.call("set_ghost_alpha", 1.0)
				project["vis_reset"] = true
			continue
		if kind == SiteProject.KIND_LINKAGE_BREAKDOWN:
			var bd := SiteProject.breakdown_progress(project, board)
			# `folded` used to `continue` (stop painting) — which froze the
			# frame at whatever the LAST push showed while pack_prop's ~3 s
			# stow-fold sweep played, and with the old deep ghost that was a
			# near-invisible skeleton: the "structure disappears, then a crate
			# appears" gap. Keep painting the final pre-pack state instead —
			# beams+supports solid, ghost held high — right up to the crate
			# swap (after which _linkage_builder_for returns null and this
			# loop naturally stops reaching it).
			builder.call("set_build_progress", {
				"beams": bd["beams"], "brackets": bd["brackets"],
				"bolts": bd["bolts"], "supports": bd["supports"],
				"panels": bd["panels"]})
			builder.call("set_ghost_alpha", float(bd.get("ghost", 1.0)))
			continue
		var bp := SiteProject.build_progress(project, board)
		if bool(bp.get("erected", false)):
			# Deployed structure: only the panel mount still animates.
			builder.call("set_build_progress", {"panels": float(bp.get("panels", 1.0))})
			builder.call("set_ghost_alpha", 1.0)
		else:
			builder.call("set_build_progress", {
				"beams": bp["beams"], "brackets": bp["brackets"],
				"bolts": bp["bolts"], "supports": bp["supports"],
				"panels": 0.0})
			builder.call("set_ghost_alpha", float(bp.get("ghost", 1.0)))


func _linkage_builder_for(main: Node, prop_id: String) -> Node:
	if prop_id.is_empty():
		return null
	var root := main.find_child("PlacedProps", true, false)
	if root == null:
		return null
	for child in root.get_children():
		if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
			var mr := child.get_node_or_null("ModelRoot")
			return mr if mr != null and mr.has_method("set_build_progress") else null
	return null


## {full, light}: how many people each tier is simulating right now — the
## cheap count for HUDs. (agent_dots() builds a ~25-key dict per person; the
## festival panel used to build all of them twice a second just to count.)
func population_counts() -> Dictionary:
	var full := 0
	var light := 0
	for iid in _engines:
		full += (_engines[iid] as NpcPopulationEngine).agents.size()
	for iid in _cohorts:
		light += (_cohorts[iid] as CrowdCohort).alive_count()
	return {"full": full, "light": light}


## The FULL-tier dots only — what the 3D host draws avatars for. The host
## used to read agent_dots() and skip every light entry, so ~700 light-tier
## dicts (name, status, morale colour, facing…) were built every tick and
## thrown away; they are now built only when the Site Plan / a card asks.
func agent_dots_full() -> Array:
	var gen := NpcDisplayPrefs.generation()
	if _dots_full_valid and gen == _dots_full_gen:
		return _dots_full
	var out: Array = []
	PerfMonitor.begin("npc_dots")
	for iid in _engines:
		out.append_array((_engines[iid] as NpcPopulationEngine).agent_dots())
	PerfMonitor.end("npc_dots")
	_dots_full = out
	_dots_full_valid = true
	_dots_full_gen = gen
	return out


## Site Plan dot payload across all engines (Phase 4 renderer input).
func agent_dots() -> Array:
	var gen := NpcDisplayPrefs.generation()
	if _dots_cache_valid and gen == _dots_cache_gen:
		return _dots_cache
	var out: Array = []
	# Timed separately from the sim tick: the dot payload is a per-agent dict
	# build (status strings, chore lookups) and scales with the roster on its
	# own — the festival-scale bench needs to see it apart from the agent steps.
	PerfMonitor.begin("npc_dots")
	for iid in _engines:
		out.append_array((_engines[iid] as NpcPopulationEngine).agent_dots())
	for iid in _cohorts:
		out.append_array((_cohorts[iid] as CrowdCohort).agent_dots())
	PerfMonitor.end("npc_dots")
	_dots_cache = out
	_dots_cache_valid = true
	_dots_cache_gen = gen
	return out


## Drop the cached dot payload. Called from every path that can change what a
## dot would say: a sim step, a roster rebuild, a snapshot restore.
func _invalidate_dots() -> void:
	_dots_cache_valid = false
	_dots_full_valid = false


## Where this person's current chore happens, as world XZ — or null when they
## hold no chore / it has no resolvable place. The settlement card's "their
## task" look-at reads this; resolution is the same _chore_position every
## other surface uses, so the camera lands where the workers actually walk.
func chore_site_of(agent_id: String, main: Node) -> Variant:
	for iid in _engines:
		var engine: NpcPopulationEngine = _engines[iid]
		var ag := engine.find_agent(agent_id)
		if ag == null:
			continue
		var cid := str(ag.chore_id)
		if cid.is_empty() or engine.chore_board == null:
			return null
		var chore := engine.chore_board.find(cid)
		if chore.is_empty():
			return null
		return _chore_position(chore, main, _find_registry(main))
	return null


## Tagged spaces with resolved world positions + live occupancy, for the Site
## Plan markers: [{pos, space_type, label, occupied, capacity}]. Dangling
## targets (deleted prop / missing building) resolve null and are skipped.
func space_markers(main: Node) -> Array:
	var reg := _find_registry(main)
	if reg == null:
		return []
	var out: Array = []
	for item in reg.spaces:
		var space: Dictionary = item
		var p: Variant = reg.resolve_position(space, main)
		if not (p is Vector2):
			continue
		var sid := str(space.get("id", ""))
		var target: Dictionary = space.get("target", {})
		out.append({
			"id": sid,
			"pos": p,
			"space_type": str(space.get("space_type", "")),
			"label": str(space.get("label", "")),
			"occupied": reg.occupant_count(sid),
			"capacity": maxi(int(space.get("capacity", SpaceRegistry.DEFAULT_CAPACITY)), 1),
			# Area spaces carry their outline so Site Plan can show the REGION
			# rather than a marker floating at its interior point.
			"poly": SpaceRegistry.poly_points(target.get("poly", []) as Array) \
					if str(target.get("kind", "")) == "area" else PackedVector2Array(),
		})
	return out


# --- navigation --------------------------------------------------------------

## Keep the nav grid in step with the world: re-derive its region when the
## tagged spaces move, then feed it ONE budgeted bake slice per tick. Never
## bakes the whole grid inline — see the NpcNavGrid stall-trap note.
## The area the population operates in, snapped so tiny movements do not
## invalidate a finished bake. STATIC anchors only — see _nav_anchor_points.
func _population_region(main: Node, registry: SpaceRegistry) -> Dictionary:
	if registry == null or main == null:
		return {}
	var anchors := _nav_anchor_points(main, registry)
	if anchors.size() < 1:
		return {}
	var lo := anchors[0]
	var hi := anchors[0]
	for p in anchors:
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	return {
		"anchors": anchors,
		"center": ((lo + hi) * 0.5).snapped(Vector2(NAV_REGION_SNAP_M, NAV_REGION_SNAP_M)),
		"half": snappedf(maxf(hi.x - lo.x, hi.y - lo.y) * 0.5, NAV_REGION_SNAP_M),
	}


func _service_nav(main: Node, registry: SpaceRegistry, region: Dictionary) -> void:
	if registry == null or main == null or region.is_empty():
		return
	var anchors: PackedVector2Array = region["anchors"]
	# The fingerprint must depend ONLY on things that sit still. Folding in
	# live agent positions makes it change every tick, which restarts the bake
	# forever and the grid never becomes ready.
	var center: Vector2 = region["center"]
	var half: float = region["half"]
	var fp := NpcNavGrid.compose_fingerprint(
			registry.spaces.size(), _prop_revision(main) + 1000 * _camp_revision(main),
			_nav_rev, 0, center, half)
	if _nav_grid == null or _nav_grid.needs_rebuild(fp):
		if _nav_fp != fp:
			_nav_fp = fp
			# The GROUND part of the fingerprint: when only props, camps or
			# spaces changed, the finished grid's heights and slopes are
			# reused and the bake resumes at the obstacle stamps.
			var terrain_fp := NpcNavGrid.compose_fingerprint(0, 0, _nav_rev, 0, center, half)
			var prev_grid := _nav_grid
			_nav_grid = NpcNavGrid.new()
			if not _nav_grid.configure_for_points(anchors):
				_nav_grid = null
				return
			var reuse := prev_grid != null and prev_grid.is_ready() \
					and terrain_fp == _nav_terrain_fp and _nav_grid.same_lattice(prev_grid)
			_nav_terrain_fp = terrain_fp
			# Height source. With a TerrainLoader we get a real heightfield
			# lookup (cheap, and correct everywhere). WITHOUT one — the
			# hand-built scenes — ground_height_at falls back to a raycast
			# that returns 0.0 on a MISS, so every hole in collision coverage
			# would read as a cliff, island the grid, and strand people. A
			# flat grid is the honest answer there (and skips 78k raycasts).
			var has_terrain := TerrainSurfaceQuery.find_terrain_loader(main) != null
			var height_fn := func(x: float, z: float) -> float:
				return TerrainSurfaceQuery.ground_height_at(main, x, z)
			if not has_terrain:
				height_fn = func(_x: float, _z: float) -> float: return 0.0
			var surfaces_fn := func(x: float, z: float) -> PackedFloat32Array:
				return _probe_surfaces(main, x, z,
						TerrainSurfaceQuery.ground_height_at(main, x, z))
			if reuse:
				_nav_grid.begin_bake_reusing(prev_grid, height_fn,
						_collect_nav_obstacles(main, registry), fp, surfaces_fn)
			else:
				_nav_grid.begin_bake(height_fn,
						_collect_nav_obstacles(main, registry), fp, surfaces_fn)
			if _nav_query == null:
				_nav_query = NpcNavQuery.new()
		_bake_nav_for(NAV_TICK_BUDGET_US)


## Per rendered frame (SystemGraphView._process): keep a nav bake moving in
## small time-boxed slices between ticks.
func service_frame() -> int:
	_bake_nav_for(NAV_FRAME_BUDGET_US)
	PerfMonitor.begin("crowd_sim")
	var n := _drain_light_queue(LIGHT_FRAME_BUDGET_US)
	PerfMonitor.end("crowd_sim")
	return n


func _bake_nav_for(budget_us: int) -> void:
	if _nav_grid == null or _nav_grid.is_ready() or _nav_query == null:
		return
	PerfMonitor.begin("npc_nav_bake")
	var t0 := Time.get_ticks_usec()
	while true:
		if _nav_grid.bake_step(NAV_BAKE_CHUNK):
			_nav_query.setup(_nav_grid)
			# A fresh grid forgets the fire perimeters: stamp them again.
			for sid in _fire_stamps.keys():
				var fs: Dictionary = _fire_stamps[sid]
				_stamp_fire(fs.get("centre", Vector2.ZERO), float(fs.get("r", 0.0)))
			break
		if Time.get_ticks_usec() - t0 >= budget_us:
			break
	PerfMonitor.end("npc_nav_bake")


# --- desire lines --------------------------------------------------------------

## Keep the desire map sized to the nav region and apply its retention policy
## once per sim-day.
func _service_desire(abs_h: float, region: Dictionary) -> void:
	if region.is_empty():
		return
	if _desire == null or not _desire.is_configured():
		_desire = NpcDesireMap.new()
		# Pad beyond the anchors so trips that stray past a space still land
		# on the map rather than being clipped away.
		_desire.configure(region["center"] as Vector2,
				float(region["half"]) + NpcNavGrid.REGION_PAD_M)
		_desire_day = int(floor(abs_h / 24.0))
		return
	var day := int(floor(abs_h / 24.0))
	if day != _desire_day:
		# Only forward: scrubbing back must not decay history.
		if day > _desire_day:
			for _i in mini(day - _desire_day, 14):
				_desire.roll_day()
		_desire_day = day
	# The heat raster is a GDScript loop over up to 256^2 cells (a set_pixel
	# and a log each): build it only while a desire overlay is on. The map
	# itself keeps accumulating — the walking metrics read it.
	if desire_texture_wanted:
		_refresh_desire_texture()


## Rebuild the heat texture at most twice a second, and only when the map has
## actually changed or the channel filter moved.
##
## ORDER MATTERS: the throttle must be checked BEFORE consuming take_dirty().
## The old single-expression form consumed the dirty flag even while
## throttled, so a change landing inside the throttle window was forgotten and
## the on-screen raster stayed stale until the NEXT mutation. The pure rule is
## NpcDesireMap.tex_should_rebuild(), pinned by the population selftest (it
## lives on the map class because the selftest may not load THIS script — see
## the note there about the bare PerfMonitor identifier).
func _refresh_desire_texture(force: bool = false) -> void:
	if _desire == null or not _desire.is_configured():
		return
	var now := float(Time.get_ticks_msec()) * 0.001
	if not NpcDesireMap.tex_should_rebuild(force, now - _desire_tex_at,
			DESIRE_TEX_INTERVAL_S, true):
		return  # throttled — leave the dirty flag latched for the next window
	if not force and not _desire.take_dirty():
		return
	_desire_tex_at = now
	_desire_tex = _desire.texture(_desire_tex_channel)


## Which channel the heat texture is built for ("" = all traffic).
func set_desire_channel(channel: String) -> void:
	if channel == _desire_tex_channel:
		return
	_desire_tex_channel = channel
	_refresh_desire_texture(true)


## Heat payload for the Site Plan renderer, or {} when there is nothing to
## show. `channel` "" means all traffic.
## Read-only: returns the CACHED texture built on the tick. Never builds one
## here — this is called from inside the canvas _draw().
func desire_payload(_channel: String = "") -> Dictionary:
	if _desire == null or not _desire.is_configured() or _desire_tex == null:
		return {}
	return {
		"texture": _desire_tex,
		"rect": _desire.world_rect(),
		"peak": _desire.peak(),
		"window": NpcDesireMap.retention_label(_desire.retention),
	}


func desire_map() -> NpcDesireMap:
	return _desire


func set_desire_window(w: int) -> void:
	if _desire != null:
		_desire.set_retention(w)
		# TODAY clears the buffer immediately — rebuild now so the raster
		# reflects the choice without waiting for the next dirty tick.
		_refresh_desire_texture(true)


## "Reset desire lines": drop the accumulated heat map AND every agent's live
## trail, then rebuild the (now empty) texture.
func reset_desire_map() -> void:
	if _desire != null:
		_desire.clear()
	for iid in _engines:
		var eng: NpcPopulationEngine = _engines[iid]
		if eng == null:
			continue
		for a in eng.agents:
			(a as NpcAgent).clear_trail()
	_refresh_desire_texture(true)


## Where the population actually operates: every resolvable tagged space plus
## each pop-driven habitat's home. STATIC POINTS ONLY — never live agent
## positions, or the region (and its fingerprint) moves every tick.
func _nav_anchor_points(main: Node, registry: SpaceRegistry) -> PackedVector2Array:
	var out := PackedVector2Array()
	for space in registry.spaces:
		var p: Variant = registry.cached_position(str((space as Dictionary).get("id", ""))) \
			if registry.positions_ready() else registry.resolve_position(space, main)
		if p is Vector2:
			out.append(p)
	for iid in _engines:
		var item: Dictionary = _model_item_cache.get(iid, {})
		out.append(_home_pos(item.get("specs", {}) as Dictionary, main))
	return out


## Buildings become wall bands with doors (interiors stay walkable); still
## water blocks; roads are good walking and are left clear.
func _collect_nav_obstacles(main: Node, registry: SpaceRegistry) -> Array:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader == null:
		return []
	var out: Array = []
	var roads: Array = loader.call("get_osm_roads") if loader.has_method("get_osm_roads") else []
	# Buildings the player tagged as an NPC space MUST be enterable, whatever
	# their size and whether or not anyone placed a door.
	var tagged: Dictionary = {}
	if registry != null:
		for space in registry.spaces:
			var t: Dictionary = (space as Dictionary).get("target", {})
			if str(t.get("kind", "")) == "building":
				tagged[str(t.get("building_tag", ""))] = true
	if loader.has_method("get_osm_buildings"):
		for item in loader.call("get_osm_buildings"):
			if not (item is Dictionary):
				continue
			var rec: Dictionary = item
			var idx := int(rec.get("idx", -1))
			var style: Dictionary = {}
			if idx >= 0 and loader.has_method("get_building_style"):
				style = loader.call("get_building_style", idx)
			# resolve_building_params normalises the ring (open, CCW), which is
			# the only form facade element `edge` indices are meaningful in.
			var params: Dictionary = BuildingBuilder.resolve_building_params(rec, style)
			var poly: PackedVector2Array = params.get("poly", PackedVector2Array())
			if poly.size() < 3:
				continue
			var mid := NpcBuildingNav.centroid(poly)
			var attract: Variant = NpcBuildingNav.nearest_road_point(roads, mid)
			var entry := NpcBuildingNav.nav_entry(
					poly, params.get("elements", []) as Array,
					attract if attract is Vector2 else Vector2.ZERO,
					true, tagged.has(BuildingBuilder.building_tag(poly)))
			if not entry.is_empty():
				out.append(entry)
	if loader.has_method("get_still_water_polygons"):
		for poly2 in loader.call("get_still_water_polygons"):
			out.append({"poly": poly2,
				"flags": NpcNavGrid.F_BLOCKED | NpcNavGrid.F_WATER})
	# Camp vehicles and placed props: people walk ROUND them. Props tagged as
	# a space people enter are left passable.
	if loader.has_method("nav_solid_footprints"):
		var enterable: Dictionary = {}
		if registry != null:
			for space in registry.spaces:
				var t2: Dictionary = (space as Dictionary).get("target", {})
				if str(t2.get("kind", "")) == "prop":
					enterable[str(t2.get("prop_id", ""))] = true
		for poly3 in loader.call("nav_solid_footprints", enterable):
			out.append({"poly": poly3, "flags": NpcNavGrid.F_BLOCKED | NpcNavGrid.F_STRUCTURE})
	return out


func _camp_revision(main: Node) -> int:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader == null or not loader.has_method("camp_structure_count"):
		return 0
	return int(loader.call("camp_structure_count"))


# --- beds ---------------------------------------------------------------------

## Sleep AREA spaces -> the shelters inside them, expanded one entry per
## sleeper and ordered so slot k wraps round the shelters. Refreshed when
## the camps or props change.
func _resolve_sleep_spots(main: Node, registry: SpaceRegistry) -> void:
	if registry == null:
		return
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader == null or not loader.has_method("camp_shelters_in_polygon"):
		return
	var rev := _prop_revision(main) * 7919 + _camp_revision(main) * 31 + registry.spaces.size()
	if rev == _sleep_spots_rev:
		return
	_sleep_spots_rev = rev
	_sleep_spots = {}
	for item in registry.spaces_of_type("sleep"):
		var space: Dictionary = item
		var tgt: Dictionary = space.get("target", {})
		if str(tgt.get("kind", "")) != "area":
			continue
		var poly := SpaceRegistry.poly_points(tgt.get("poly", []) as Array)
		var shelters: Array = loader.call("camp_shelters_in_polygon", poly)
		if shelters.is_empty():
			continue
		_sleep_spots[str(space.get("id", ""))] = _expand_beds(shelters)


## Spaces tagged on flat-pack furniture -> the piece's own seat / bed spots
## (FlatpackBuilder "seat_spots" meta, local metres) in world space. Furniture
## is few and cheap to read, so this re-reads once a second: a moved bench
## carries its seats with it.
func _resolve_seat_spots(main: Node, registry: SpaceRegistry) -> void:
	if registry == null:
		return
	var now := Time.get_ticks_msec()
	if now - _seat_spots_at_ms < 1000:
		return
	_seat_spots_at_ms = now
	_seat_spots = {}
	for item in registry.spaces:
		var space: Dictionary = item
		var tgt: Dictionary = space.get("target", {})
		if str(tgt.get("kind", "")) != "prop":
			continue
		var prop := PlacedPropRuntime.find_by_prop_id(main, str(tgt.get("prop_id", "")))
		if prop == null or prop.model_id != FlatpackBuilder.MODEL_ID:
			continue
		var spots := furniture_spots(prop)
		if not spots.is_empty():
			_seat_spots[str(space.get("id", ""))] = spots


## A placed furniture piece's seats in world space.
static func furniture_spots(prop: Node3D) -> Array:
	var out: Array = []
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return out
	var furn: Node3D = null
	if model.has_meta("seat_spots"):
		furn = model
	else:
		for c in model.get_children():
			if c is Node3D and (c as Node3D).has_meta("seat_spots"):
				furn = c
				break
	if furn == null:
		return out
	var xf := furn.global_transform
	var yaw0 := xf.basis.get_euler().y
	for st in furn.get_meta("seat_spots", []):
		var w: Vector3 = xf * (st["pos"] as Vector3)
		out.append({"pos": Vector2(w.x, w.z), "yaw": float(st["yaw"]) + yaw0,
			"elev": maxf(w.y - xf.origin.y, 0.0), "kind": str(st.get("kind", "sit"))})
	return out


func seat_spot(sid: String, k: int) -> Dictionary:
	var spots: Array = _seat_spots.get(sid, [])
	if spots.is_empty():
		return {}
	return spots[maxi(k, 0) % spots.size()]


## One entry per sleeper per shelter, scattered inside its footprint, so a
## tent of two shows two people lying in it rather than one point.
static func _expand_beds(shelters: Array) -> Array:
	var out: Array = []
	for s in shelters:
		var sd: Dictionary = s
		var n := maxi(int(sd.get("sleeps", 2)), 1)
		var yaw := float(sd.get("yaw", 0.0))
		var p: Vector2 = sd["pos"]
		# Along the shelter's long axis (local +X -> world (cos, -sin)).
		var axis := Vector2(cos(yaw), -sin(yaw))
		for k in n:
			var off := (float(k) - float(n - 1) * 0.5) * 0.8
			out.append({"pos": p + axis * off, "yaw": yaw})
	return out


func _bed_spot(sid: String, k: int) -> Dictionary:
	var beds: Array = _sleep_spots.get(sid, [])
	if beds.is_empty():
		return {}
	var kk := maxi(k, 0)
	var bed: Dictionary = beds[kk % beds.size()]
	var round_n := kk / beds.size()
	if round_n == 0:
		return bed
	# More sleepers than beds: they PILE IN beside the bed's owner, inside the
	# same shelter (a short step across its long axis), not on the ground.
	var yaw := float(bed.get("yaw", 0.0))
	return {"pos": (bed["pos"] as Vector2) + SpaceRegistry.pile_offset(round_n, yaw), "yaw": yaw}


## The expanded beds of the camp standing at `home` (the light tier's home
## slots), or an empty array when there is no camp there.
func _home_beds(main: Node, home: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader == null or not loader.has_method("camp_area_at") or not loader.has_method("camp_shelters_in_polygon"):
		return out
	var rev := _prop_revision(main) * 7919 + _camp_revision(main) * 31
	if rev != _home_beds_rev:
		_home_beds_rev = rev
		_home_beds_cache = {}
	var hkey := "%.2f,%.2f" % [home.x, home.y]
	if _home_beds_cache.has(hkey):
		return _home_beds_cache[hkey]
	out = _home_beds_uncached(loader, home)
	_home_beds_cache[hkey] = out
	return out


func _home_beds_uncached(loader: Node, home: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var cid := str(loader.call("camp_area_at", home))
	if cid.is_empty():
		return out
	var layer: Variant = loader.get("camp_areas")
	if layer == null:
		return out
	var rec: Dictionary = layer.get_area(cid)
	var poly: PackedVector2Array = rec.get("polygon", PackedVector2Array())
	for b in _expand_beds(loader.call("camp_shelters_in_polygon", poly)):
		out.append((b as Dictionary)["pos"])
	return out


# --- the fire perimeter on the nav grid ----------------------------------------

## Stamp (or clear) the effigy's perimeter as the fire moves through its
## phases, so nobody walks INTO the fall radius or the pile.
func _apply_fire_perimeter(sid: String, centre: Vector2, st: Dictionary) -> void:
	var phase := int(st.get("phase", -1))
	var r := 0.0
	# The perimeter holds from the SANDMEN stage (the fire-flow performers
	# dance inside it before that), through the flame and the circle dance;
	# the embers keep the pile's own.
	if bool(st.get("perimeter", false)) or phase == VenueCrowd.EffigyPhase.AFTER:
		r = float(st.get("safe_r", 0.0))
	var prev: Dictionary = _fire_stamps.get(sid, {})
	if absf(float(prev.get("r", 0.0)) - r) < 0.01 and prev.get("centre", Vector2.INF) == centre:
		return
	if _nav_grid != null and _nav_grid.is_ready():
		if not prev.is_empty() and float(prev.get("r", 0.0)) > 0.0:
			_nav_grid.clear_flags_in_circle(prev.get("centre", centre), float(prev["r"]), NpcNavGrid.F_FIRE)
		_stamp_fire(centre, r)
		if _nav_query != null:
			# Only routes through the old or new circle are stale. The cache
			# fingerprint does not see flag stamps, so drop them by geometry.
			var reach := maxf(r, float(prev.get("r", 0.0)))
			_nav_query.invalidate_near(centre, reach + 1.0)
	if r > 0.0:
		_fire_stamps[sid] = {"centre": centre, "r": r}
	else:
		_fire_stamps.erase(sid)


## The fire perimeters as [{centre, r}] for straight-line detours.
func _no_go_circles() -> Array:
	var out: Array = []
	for sid in _fire_stamps:
		out.append(_fire_stamps[sid])
	return out


func _stamp_fire(centre: Vector2, r: float) -> void:
	if r <= 0.0 or _nav_grid == null or not _nav_grid.is_ready():
		return
	_nav_grid.clear_flags_in_circle(centre, r, 0, NpcNavGrid.F_FIRE)


## Walkable surfaces ABOVE the ground at a point — deck levels, upper floors.
## Called only in STRUCTURE cells, so the raycast cost is bounded to building
## and prop volumes rather than the whole grid.
func _probe_surfaces(main: Node, x: float, z: float, ground_y: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if main == null or not main.is_inside_tree():
		return out
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	if space == null:
		return out
	var top := ground_y + SURFACE_PROBE_TOP_M
	var from := Vector3(x, top, z)
	for i in NpcNavGrid.MAX_LAYERS - 1:
		var params := PhysicsRayQueryParameters3D.create(from, Vector3(x, ground_y + 0.2, z))
		params.collision_mask = 1
		var hit: Dictionary = space.intersect_ray(params)
		if hit.is_empty():
			break
		var y := float((hit["position"] as Vector3).y)
		# Only surfaces clearly above the ground count as another level.
		if y - ground_y >= SURFACE_MIN_CLEARANCE_M:
			out.append(y)
		from = Vector3(x, y - 0.05, z)
		if from.y <= ground_y + 0.2:
			break
	return out


func _prop_revision(main: Node) -> int:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader == null:
		return 0
	var layer: Variant = loader.get("_placed_prop_layer")
	if layer != null and layer.get("props") != null:
		return (layer.get("props") as Array).size()
	return 0


## Bump when world geometry moves so the grid re-bakes (terrain sculpt, prop
## placement, building style edits).
func notify_world_changed() -> void:
	_nav_rev += 1


## The agent-facing planner. Returns null when the grid is not ready or the
## per-tick cold-query budget is spent — agents then walk straight, which is
## exactly the pre-3b behaviour.
func _plan_path(from_xz: Vector2, to_xz: Vector2, from_key: String,
		to_key: String, lane_seed: int) -> Variant:
	if _nav_query == null or not _nav_query.is_ready():
		return null
	var cached := not from_key.is_empty() and not to_key.is_empty()
	if not cached and _nav_queries_this_tick >= MAX_QUERIES_PER_TICK:
		return null
	PerfMonitor.begin("npc_pathfind")
	_nav_query.allow_miss = _nav_keyed_misses_this_tick < MAX_KEYED_MISSES_PER_TICK
	var misses0 := int(_nav_query.stats().get("misses", 0))
	var path := _nav_query.path_between_spaces(from_key, to_key, from_xz, to_xz, lane_seed)
	_nav_query.allow_miss = true
	PerfMonitor.end("npc_pathfind")
	if not cached:
		_nav_queries_this_tick += 1
	elif int(_nav_query.stats().get("misses", 0)) > misses0:
		_nav_keyed_misses_this_tick += 1
	return path if path.size() > 0 else null


## Navigation state for the inspector / harness.
func nav_status() -> Dictionary:
	if _nav_grid == null:
		return {"state": "off"}
	var d := {
		"state": "ready" if _nav_grid.is_ready() else "baking",
		"progress": _nav_grid.bake_progress(),
		"cells": _nav_grid.cell_count(),
		"cell_m": _nav_grid.cell_m,
	}
	if _nav_query != null:
		d.merge(_nav_query.stats())
	d["layers"] = _nav_grid.layers
	d["doors"] = _nav_grid.count_flag(NpcNavGrid.F_DOOR)
	d["interior"] = _nav_grid.count_flag(NpcNavGrid.F_INTERIOR)
	d["upper"] = _nav_grid.upper_surface_cells()
	return d


func nav_grid() -> NpcNavGrid:
	return _nav_grid


## Live weather for the productivity/exposure model, cached per tick. Falls
## back to comfortable conditions when WeatherService has no coverage, so an
## offline site never has its work blocked.
func _sample_weather(main: Node, hour_of_day: float) -> Dictionary:
	var clock: Variant = main.get("clock") if main != null else null
	var month := int(main.get("month")) if main != null and main.get("month") != null else 6
	var day := int(main.get("day")) if main != null and main.get("day") != null else 15
	if clock != null:
		month = int(clock.get("month"))
		day = int(clock.get("day"))
	# Keyed on the DATE as well as the hour: a jump of whole days that lands
	# on the same hour used to keep the previous day's weather.
	if absf(hour_of_day - _weather_hour) < 0.25 and month * 100 + day == _weather_day \
			and not _weather_cache.is_empty():
		return _weather_cache
	var ws := main.get_node_or_null("/root/WeatherService") if main != null else null
	if ws == null or not ws.has_method("sample"):
		_weather_cache = {}
		return _weather_cache
	_weather_cache = {
		"temp_c": float(ws.call("temperature_c", month, day, hour_of_day)),
		"wind_ms": float(ws.call("sample", "wind_speed_10m", month, day, hour_of_day)),
		"rain_mmh": float(ws.call("sample", "precipitation", month, day, hour_of_day)),
		# Global horizontal irradiance — how SUNNY it is (NpcComfort's heat
		# pull wants shade on a hot sunny day, not a hot overcast one).
		"ghi_wm2": float(ws.call("sample", "shortwave_radiation", month, day, hour_of_day)),
	}
	# Extreme-weather air quality. NpcWeatherGate reads `aqi` and it is the one
	# driver that follows people indoors, so smoke can stop work in a way rain
	# never does. Absent (no hazard, or the subsystem disabled) it reads 0 and
	# every existing threshold behaves exactly as before.
	var xw := main.get_node_or_null("/root/ExtremeWeather") if main != null else null
	if xw != null:
		var hz: Dictionary = xw.call("current")
		_weather_cache["aqi"] = float(hz.get("aqi", 0.0))
		_weather_cache["pm25_ugm3"] = float(hz.get("pm25_ugm3", 0.0))
	_weather_hour = hour_of_day
	_weather_day = month * 100 + day
	return _weather_cache


## Where a chore's work happens: an explicit world position (crew-plan build
## sites), an explicit space type, a bound prop, or (null) wherever the
## worker already stands.
func _chore_position(chore: Dictionary, main: Node, registry: SpaceRegistry) -> Variant:
	var target: Dictionary = chore.get("target", {})
	match str(target.get("kind", "")):
		"pos":
			return Vector2(float(target.get("x", 0.0)), float(target.get("z", 0.0)))
		"prop":
			var rec: Dictionary = PlacedPropService.get_prop_record(main, str(target.get("id", "")))
			if not rec.is_empty():
				return Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
		"space":
			if registry != null:
				var sp := registry.find_by_id(str(target.get("id", "")))
				if not sp.is_empty():
					return registry.resolve_position(sp, main)
	var stype := str(chore.get("space_type", ""))
	if not stype.is_empty() and registry != null:
		for sp2 in registry.spaces_of_type(stype):
			var p: Variant = registry.resolve_position(sp2, main)
			if p is Vector2:
				return p
	return null


## The chore board for a habitat (creating its engine lazily is the caller's
## job — this returns null before the first tick).
## Every habitat currently running a population. The Site Project panel needs
## it to answer "whose board does a hand-authored job land on" before any
## project exists to read an id off.
func pop_driven_item_ids() -> Array:
	var out: Array = []
	for iid in _engines:
		out.append(str(iid))
	out.sort()   # deterministic: the panel must not pick a different board per open
	return out


## --- duty rota + skills (config, persisted beside pop_routine) -------------

func duty_roster_for(item_id: String) -> NpcDutyRoster:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.duty if engine != null else null


func skills_for(item_id: String) -> NpcSkills:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.skills if engine != null else null


func labour_for(item_id: String) -> NpcLabourLog:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.labour if engine != null else null


## Persist the duty TEMPLATES after an edit. Slots are simulation state and
## ride pop_state; only the templates are config.
## ⚠ Through `update_item`, never by mutating the returned specs in place —
## a direct mutation skips the model's dirty marking, so the edit would render
## live and silently miss the next autosave.
func save_duties(model, item_id: String) -> void:
	_save_config_key(model, item_id, "pop_duties",
		func(engine: NpcPopulationEngine) -> Dictionary:
			return engine.duty.serialize_duties())
	# Re-plan from today, so an edit shows up now rather than when the horizon
	# happens to roll past it.
	_last_duty_day.erase(item_id)


func save_skills(model, item_id: String) -> void:
	_save_config_key(model, item_id, "pop_skills",
		func(engine: NpcPopulationEngine) -> Dictionary:
			return engine.skills.serialize())


func oncall_for(item_id: String) -> NpcOnCall:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.oncall if engine != null else null


func save_oncall(model, item_id: String) -> void:
	_save_config_key(model, item_id, "pop_oncall",
		func(engine: NpcPopulationEngine) -> Dictionary:
			return engine.oncall.serialize())


func _save_config_key(model, item_id: String, key: String, value_of: Callable) -> void:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	if engine == null or model == null:
		return
	var item: Dictionary = model.get_item(item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs[key] = value_of.call(engine)
	model.update_item(item_id, {"specs": specs})


## One call for the Work Planner: persist every piece of work CONFIG this
## habitat carries (duty templates, skill tags, on-call roles) using the model
## the bridge already holds. Slots/labour are simulation state and ride
## pop_state on their own.
func persist_work_config(item_id: String) -> void:
	save_duties(_model, item_id)
	save_skills(_model, item_id)
	save_oncall(_model, item_id)


func chore_board_for(item_id: String) -> NpcChoreBoard:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.chore_board if engine != null else null


func roster_size_for(item_id: String) -> int:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.agents.size() if engine != null else 0


## First habitat with a live engine, people, and a board — where a queued
## crew plan lands (Linkage Lab "Queue build for crew").
func first_crewable_habitat() -> String:
	for iid in _engines:
		var engine: NpcPopulationEngine = _engines[iid]
		if engine != null and engine.chore_board != null and not engine.agents.is_empty():
			return str(iid)
	return ""


## Active work sites for the Site Plan: any claimed chore with a resolvable
## position — [{pos, label, workers, min_workers, quorum, progress}]. A
## sub-quorum site is a crew GATHERING (people standing at it, work not yet
## paying); a quorate one shows real progress. Under the agent dots, so the
## crowd visibly stands ON its work.
func crew_site_markers(main: Node) -> Array:
	var reg := _find_registry(main)
	var out: Array = []
	for iid in _engines:
		var engine: NpcPopulationEngine = _engines[iid]
		if engine == null or engine.chore_board == null:
			continue
		for c in engine.chore_board.chores:
			var chore: Dictionary = c
			var workers := (chore.get("workers", []) as Array).size()
			if workers <= 0:
				continue
			var p: Variant = _chore_position(chore, main, reg)
			if not (p is Vector2):
				continue
			var hours := maxf(float(chore.get("chore_hours", 0.0)), 0.01)
			var min_w := maxi(int(chore.get("min_workers", 1)), 1)
			var mark := {
				"pos": p,
				"label": str(chore.get("label", "")),
				"workers": workers,
				"min_workers": min_w,
				"quorum": workers >= min_w,
				"progress": clampf(float(chore.get("progress_h", 0.0)) / hours, 0.0, 1.0),
			}
			# Haul routes render as a LINE — the brigade formation is the
			# payoff image of the whole rules-driven direction.
			var haul: Dictionary = chore.get("haul", {})
			if not haul.is_empty():
				mark["from"] = Vector2(float(haul.get("from_x", 0.0)),
					float(haul.get("from_z", 0.0)))
				mark["to"] = Vector2(float(haul.get("to_x", 0.0)),
					float(haul.get("to_z", 0.0)))
				mark["strategy"] = str(haul.get("strategy", ""))
				# Sim-time phase for the flowing-item pips: a pure function of
				# the clock (scrub-safe), frozen exactly when the sim is.
				mark["flow_t"] = _last_abs_h
			out.append(mark)
	return out


## Start a habitat's community over with a fresh roster.
##
## Needed because an emptied roster cannot restart itself: departures are
## permanent, `_ensure_engine` only rebuilds when the AUTHORED occupant count
## changes, and a zero-agent engine ticks to nothing forever. Without this the
## only recovery was to toggle `pop_driven` off and on, which is not something
## anyone would guess.
##
## Clears the persisted snapshot too, or the next `_ensure_engine` would
## restore the very roster that just walked out.
func reset_population(item_id: String, model, main: Node) -> bool:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	if engine == null and _cohorts.has(item_id) and model != null:
		var item0: Dictionary = model.get_item(item_id)
		if item0.is_empty():
			return false
		var specs0: Dictionary = (item0.get("specs", {}) as Dictionary).duplicate(true)
		var count0 := clampi(int(float(specs0.get("occupants", 10.0))), 1, 5000)
		var fresh := CrowdCohort.new()
		fresh.configure(count0, item_id, _home_pos(specs0, main))
		fresh.routine = (_cohorts[item_id] as CrowdCohort).routine
		fresh.consequence = (_cohorts[item_id] as CrowdCohort).consequence
		_cohorts[item_id] = fresh
		_parked.erase(item_id)
		_invalidate_dots()
		specs0.erase("pop_state")
		specs0["pop_present"] = count0
		specs0["pop_morale"] = snappedf(fresh.mean_morale(), 0.01)
		specs0["pop_collapse_risk"] = 0.0
		_last_persist_h.erase(item_id)
		_last_persist_blob.erase(item_id)
		model.update_item(item_id, {"specs": specs0})
		return true
	if engine == null or model == null:
		return false
	var item: Dictionary = model.get_item(item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var count := clampi(int(float(specs.get("occupants", 10.0))), 1, 200)
	engine.reset_roster(count, item_id, _home_pos(specs, main))
	_invalidate_dots()
	specs.erase("pop_state")
	specs["pop_present"] = count
	specs["pop_morale"] = snappedf(engine.mean_morale(), 0.01)
	specs["pop_collapse_risk"] = 0.0
	model.update_item(item_id, {"specs": specs})
	_configured_count[item_id] = count
	_last_persist_h.erase(item_id)
	_last_persist_blob.erase(item_id)
	return true


## The daily schedule a habitat's people follow.
func routine_for(item_id: String) -> NpcRoutine:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.routine if engine != null else null


## Replace a habitat's schedule and persist it. Applies live — everyone picks
## the new day up at their next idle moment, without restarting the roster.
func set_routine(item_id: String, blocks: Array) -> bool:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	if engine == null:
		return false
	engine.routine = NpcRoutine.from_array(blocks)
	if _model == null:
		return true   # applied live; persistence waits for the next tick
	var item: Dictionary = _model.get_item(item_id)
	if item.is_empty():
		return true
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["pop_routine"] = engine.routine.to_array()
	_model.update_item(item_id, {"specs": specs})
	return true


## What running out of a critical resource does here. Same shape as
## set_routine: applied live, persisted into the habitat's specs so it rides
## the graph autosave and is scoped to THIS settlement rather than following
## the player between saves.
func set_consequence(item_id: String, policy: String) -> bool:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	if engine == null:
		return false
	engine.consequence = NpcConsequence.normalize(policy)
	if _model == null:
		return true
	var item: Dictionary = _model.get_item(item_id)
	if item.is_empty():
		return true
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["pop_consequence"] = engine.consequence
	_model.update_item(item_id, {"specs": specs})
	return true


func consequence_for(item_id: String) -> String:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.consequence if engine != null else NpcConsequence.DEFAULT


## Which clip plays in each slot for this habitat (Routines panel).
func anim_overrides_for(item_id: String) -> Dictionary:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.anim_overrides if engine != null else {}


## Bind clips to slots and persist. Applies live: the map rides on every dot,
## so the next frame already uses it.
func set_anim_overrides(item_id: String, overrides: Dictionary) -> bool:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	if engine == null:
		return false
	engine.anim_overrides = overrides.duplicate()
	if _model == null:
		return true
	var item: Dictionary = _model.get_item(item_id)
	if item.is_empty():
		return true
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["pop_anim_map"] = engine.anim_overrides
	_model.update_item(item_id, {"specs": specs})
	return true


## Every pop-driven habitat id currently simulated.
func habitat_ids() -> Array:
	return _engines.keys()


## Every simulated habitat's summary, both tiers (the Fun Meter's fallback
## when the map has no festival camps for SystemGraphView.festival_vibe()).
func vibe_summaries() -> Array:
	var out: Array = []
	var seen := {}
	for iid in _engines.keys() + _cohorts.keys():
		if seen.has(iid):
			continue
		seen[iid] = true
		# A light camp's engine is PARKED (its roster is stale): read the
		# tier that is actually simulating it.
		var light := str(_tiers.get(iid, CrowdFocus.TIER_FULL)) == CrowdFocus.TIER_LIGHT
		var s: Dictionary = {}
		if light and _cohorts.has(iid):
			s = (_cohorts[iid] as CrowdCohort).summary()
		elif _engines.has(iid):
			s = (_engines[iid] as NpcPopulationEngine).summary()
		elif _cohorts.has(iid):
			s = (_cohorts[iid] as CrowdCohort).summary()
		if not s.is_empty():
			out.append(s)
	return out


## Last sampled weather (Routines panel readout).
func current_weather() -> Dictionary:
	return _weather_cache


## Sim time of the last tick — the chore board's windows/day rollover key off it.
func current_abs_hours() -> float:
	return _last_abs_h


## Agent roster for one habitat (Routines panel).
func roster_for(item_id: String) -> Array:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.agents if engine != null else []


## The agent behind an id, across all engines (3D interaction lookups).
func find_agent(agent_id: String) -> NpcAgent:
	for iid in _engines:
		var a := (_engines[iid] as NpcPopulationEngine).find_agent(agent_id)
		if a != null:
			return a
	return null


## Possession hand-over (MultiplayerSession): the engine that owns the person
## releases their chore claim, see NpcPopulationEngine.set_controller.
func set_agent_controller(agent_id: String, peer_id: int) -> bool:
	for iid in _engines:
		if (_engines[iid] as NpcPopulationEngine).set_controller(agent_id, peer_id):
			return true
	return false


## The habitat whose roster carries this agent, "" when unknown. The
## settlement card's person jump needs it — passing "" let the planner bind
## to whichever habitat happened to be first, silently showing a different
## settlement's board on a two-habitat map.
func habitat_of_agent(agent_id: String) -> String:
	for iid in _engines:
		if (_engines[iid] as NpcPopulationEngine).find_agent(agent_id) != null:
			return str(iid)
	for iid in _cohorts:
		if (_cohorts[iid] as CrowdCohort).agent_index(agent_id) >= 0:
			return str(iid)
	return ""


## Inspector telemetry for one habitat ({} when not simulated yet).
func summary_for(item_id: String) -> Dictionary:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	if engine != null:
		return engine.summary()
	var cohort: CrowdCohort = _cohorts.get(item_id)
	return cohort.summary() if cohort != null else {}


func has_engine(item_id: String) -> bool:
	return _engines.has(item_id)


func active() -> bool:
	return not _engines.is_empty() or not _cohorts.is_empty()


## The venue states this tick resolved: {space_id: NpcVenueState dict}.
func venue_states() -> Dictionary:
	return _venue_states


func venue_state(space_id: String) -> Dictionary:
	return _venue_states.get(space_id, {})


## A stage's {front: Vector2, fwd: Vector2} this tick ({} for anything else).
func venue_front(space_id: String) -> Dictionary:
	return _venue_fronts.get(space_id, {})


func event_active() -> bool:
	return _event_active


## Last tick's population region ({anchors, center, half}); {} before the
## first tick. The crowd renderer sizes its height raster from it.
func population_region() -> Dictionary:
	return _last_region


## Resolve every venue's live state once per tick. An effigy reads the burn
## record off its tagged prop (FireTimeline, pure); stages get a front edge
## and facing — `facing_deg` when set, else toward the mean of the sleep
## spaces (the camps), else south.
func _resolve_venues(main: Node, registry: SpaceRegistry, abs_h: float, hour: float) -> void:
	_venue_states = {}
	_venue_fronts = {}
	_event_active = false
	_burn_key = ""
	if registry == null:
		return
	var changed: Array = []
	var evac: Array = []
	var camps := Vector2.ZERO
	var n_camps := 0
	for rec in registry.spaces_of_type("sleep"):
		var p: Variant = registry.cached_position(str((rec as Dictionary).get("id", "")))
		if p is Vector2:
			camps += p
			n_camps += 1
	if n_camps > 0:
		camps /= float(n_camps)
	for stype in SpaceTypes.VENUE_TYPES:
		for item in registry.spaces_of_type(str(stype)):
			var space: Dictionary = item
			var sid := str(space.get("id", ""))
			var fire_rec: Dictionary = {}
			if str(stype) == "effigy":
				var tgt: Dictionary = space.get("target", {})
				if str(tgt.get("kind", "")) == "prop":
					var prop := PlacedPropService.get_prop_record(main, str(tgt.get("prop_id", "")))
					var burn: Variant = prop.get("burn", {})
					if burn is Dictionary and FireTimeline.is_record(burn):
						fire_rec = burn
					else:
						# Never lit: hand over its SIZE so the idle crowd
						# already stands outside the radius a burn would need.
						fire_rec = _effigy_size(main, str(tgt.get("prop_id", "")))
			var st := NpcVenueState.resolve(space, hour, abs_h, fire_rec)
			_venue_states[sid] = st
			if bool(st.get("event", false)):
				_event_active = true
				if str(stype) == "effigy" and _burn_key.is_empty():
					_burn_key = str(st.get("burn_key", ""))
			# Shared moments (the effigy's last minutes, a set's closer) are
			# folded into the key so the crowd's poses update when they begin.
			var key := "%d|%s|%s|%s" % [int(st.get("phase", -1)),
				str(bool(st.get("active", true)) and bool(st.get("programmed", false))),
				str(bool(st.get("cheer", false))), str(bool(st.get("peak", false)))]
			if _venue_phase_keys.has(sid) and str(_venue_phase_keys[sid]) != key:
				changed.append(sid)
				# The effigy was just LIT (its pre-roll began): clear the fall
				# zone of everyone who is not part of its crowd, right now.
				if str(stype) == "effigy" and int(st.get("phase", -1)) == VenueCrowd.EffigyPhase.BURNING \
						and int(str(_venue_phase_keys[sid]).get_slice("|", 0)) != VenueCrowd.EffigyPhase.BURNING:
					var ec0: Variant = registry.cached_position(sid)
					if ec0 is Vector2:
						evac.append({"centre": ec0, "r": float(st.get("safe_r", 0.0)), "sid": sid})
			_venue_phase_keys[sid] = key
			if str(stype) == "effigy":
				var ec: Variant = registry.cached_position(sid)
				if ec is Vector2:
					_apply_fire_perimeter(sid, ec, st)
			# A fire circle's HEAT draws people while it burns — the colder
			# (and the darker) the more. A firepit tagged as one draws a crowd
			# only while it burns; any other fire circle counts as lit.
			if str(stype) == "fire_circle":
				var tgt3: Dictionary = space.get("target", {})
				var pid3 := str(tgt3.get("prop_id", "")) if str(tgt3.get("kind", "")) == "prop" else ""
				var lit3 := true
				if _firepit_lit.has(pid3):
					lit3 = bool(_firepit_lit[pid3])
					st["lit"] = lit3
					if not lit3:
						st["draw"] = float(st.get("draw", 0.5)) * UNLIT_PIT_DRAW
						st["label"] = "Cold firepit"
					else:
						st["label"] = "Firepit"
				if lit3:
					st["pull"] = float(st.get("pull", 0.0)) \
						+ float(_comfort.get("warmth", 0.0)) * FIRE_HEAT_PULL
			# Crowd geometry for EVERY venue: its layout (round or facing one
			# way), footprint radius, and — directional — the front edge and
			# the way it faces. Stages default to directional.
			var centre: Variant = registry.cached_position(sid)
			if centre is Vector2 and str(stype) != "effigy":
				var lay := VenueCrowd.layout_of(str(stype), str(space.get("layout", "")))
				var geo := _space_geom(main, space, centre)
				var entry := {"layout": lay, "r": float(geo.get("r", 0.0)),
					"gap": float(space.get("crowd_gap_m", -1.0))}
				if lay == SpaceRegistry.LAYOUT_DIRECTIONAL:
					entry["fwd"] = _venue_fwd(space, centre, camps, n_camps)
					entry["front"] = VenueCrowd.stage_front(geo.get("centre", centre),
						geo.get("poly", PackedVector2Array()), entry["fwd"])
				_venue_fronts[sid] = entry
	_stamp_fire_music(registry, changed)
	for e in evac:
		var ed: Dictionary = e
		for iid in _engines:
			(_engines[iid] as NpcPopulationEngine).evacuate_from(ed["centre"], float(ed["r"]), registry)
		for iid in _cohorts:
			(_cohorts[iid] as CrowdCohort).evacuate_from(ed["centre"], float(ed["r"]),
				str(ed["sid"]), abs_h, registry)
	if not evac.is_empty():
		_invalidate_dots()
	# A phase change re-seats the LIGHT tier now (the full tier re-seats
	# every step on its own).
	for sid in changed:
		for iid in _cohorts:
			(_cohorts[iid] as CrowdCohort).wake_at_venue(str(sid), abs_h)
	# The first tick of an EVENT: everyone idle or at another venue looks
	# round (the full tier does the same check itself in _step_doing).
	if _event_active and not _event_was:
		for iid in _cohorts:
			(_cohorts[iid] as CrowdCohort).wake_for_event(abs_h)
	_event_was = _event_active


## Fire circles within earshot of a PLAYING stage (its speakers: the front
## edge of a directional stage, else its centre) get `music_near` — most of
## the ring sways to it (VenueCrowd.venue_pose). Any other venue playing its
## own track (StageMusic) counts too. A change in a fire's lit / music state
## re-poses its light-tier crowd now (`changed`).
func _stamp_fire_music(registry: SpaceRegistry, changed: Array) -> void:
	var sources: Array = []
	for sid in _venue_states:
		var rec := registry.find_by_id(str(sid))
		var stype := str(rec.get("space_type", ""))
		if stype == "fire_circle" or stype == "effigy" or rec.is_empty():
			continue
		var st: Dictionary = _venue_states[sid]
		var playing := false
		if stype == "stage":
			playing = StageMusic.should_play("stage", st)
		elif not str(rec.get("music", "")).is_empty():
			playing = StageMusic.should_play(stype, st)
		if not playing:
			continue
		var fr: Dictionary = _venue_fronts.get(sid, {})
		var at: Variant = fr.get("front", registry.cached_position(str(sid)))
		if at is Vector2:
			sources.append(at)
	for item in registry.spaces_of_type("fire_circle"):
		var sid2 := str((item as Dictionary).get("id", ""))
		if not _venue_states.has(sid2):
			continue
		var st2: Dictionary = _venue_states[sid2]
		var pos: Variant = registry.cached_position(sid2)
		var music := VenueCrowd.fire_lit(st2) and pos is Vector2 and VenueCrowd.music_reaches(pos, sources)
		st2["music_near"] = music
		var key := "%s|%s" % [str(VenueCrowd.fire_lit(st2)), str(music)]
		if _fire_keys.has(sid2) and str(_fire_keys[sid2]) != key and not changed.has(sid2):
			changed.append(sid2)
		_fire_keys[sid2] = key


## The way a venue FACES (the direction its speakers point), as an XZ unit
## vector: `facing_deg` when set, else toward the mean of the camps, else
## south.
func _venue_fwd(space: Dictionary, centre: Vector2, camps: Vector2, n_camps: int) -> Vector2:
	var facing := float(space.get("facing_deg", -1.0))
	if facing >= 0.0:
		return VenueCrowd.fwd_from_deg(facing)
	if n_camps > 0:
		return VenueCrowd.stage_facing(centre, camps)
	return Vector2(0.0, 1.0)


## A space's footprint: {poly (XZ), r (its half-size), centre (the
## footprint's middle — a prop's origin need not be)} from a prop's live
## pick AABB or an area's outline; {} for anything else.
func _space_geom(main: Node, space: Dictionary, centre: Vector2) -> Dictionary:
	var tgt: Dictionary = space.get("target", {})
	match str(tgt.get("kind", "")):
		"prop":
			return _prop_geometry(main, str(tgt.get("prop_id", "")))
		"area":
			var poly := SpaceRegistry.poly_points(tgt.get("poly", []) as Array)
			var r := 0.0
			for v in poly:
				r = maxf(r, (v - centre).length())
			return {"poly": poly, "r": r, "centre": centre}
	return {}


func _prop_node(main: Node, prop_id: String) -> PlacedProp:
	if prop_id.is_empty() or main == null:
		return null
	# One sweep of the props per tick, not one per question.
	if _prop_nodes_h != _last_abs_h:
		_prop_nodes_h = _last_abs_h
		_prop_nodes = {}
		var terrain := main.get_node_or_null("Terrain")
		var root := terrain.get_node_or_null("PlacedProps") if terrain != null else null
		if root == null:
			root = main.find_child("PlacedProps", true, false)
		if root != null:
			for child in root.get_children():
				if child is PlacedProp:
					_prop_nodes[str((child as PlacedProp).prop_id)] = child
	var n: Variant = _prop_nodes.get(prop_id)
	return n as PlacedProp if n != null and is_instance_valid(n) else null


## {poly, r, centre, node} for a placed prop, from its live pick AABB —
## cached per prop NODE (a rebuild mints a new node and re-measures).
func _prop_geometry(main: Node, prop_id: String) -> Dictionary:
	var node := _prop_node(main, prop_id)
	if node == null:
		return {}
	var cached: Dictionary = _prop_geom.get(prop_id, {})
	if int(cached.get("node", 0)) == node.get_instance_id():
		return cached
	var bb: AABB = node.get_world_pick_aabb()
	if bb.size.length_squared() < 0.01:
		return {}
	var poly := PackedVector2Array([Vector2(bb.position.x, bb.position.z),
		Vector2(bb.end.x, bb.position.z), Vector2(bb.end.x, bb.end.z), Vector2(bb.position.x, bb.end.z)])
	var c := bb.get_center()
	var geo := {"node": node.get_instance_id(), "poly": poly,
		"r": maxf(bb.size.x, bb.size.z) * 0.5, "centre": Vector2(c.x, c.z), "deck": NAN}
	_prop_geom[prop_id] = geo
	return geo


## How high a performer stands on a prop (a stage's deck), in metres above
## the prop's base: the LOWEST upward-facing surface over the footprint's
## middle that is clear of the ground, taking the top of that deck (a slab's
## underside and top are both horizontal). -1 when nothing qualifies (a flat
## prop, or a roof-only structure). Measured once per prop node; meshes whose
## bounds miss the middle are skipped before their faces are read.
func _deck_height(main: Node, prop_id: String) -> float:
	var geo := _prop_geometry(main, prop_id)
	if geo.is_empty():
		return -1.0
	if not is_nan(float(geo.get("deck", NAN))):
		return float(geo["deck"])
	var node := _prop_node(main, prop_id)
	var deck := -1.0
	if node != null:
		var c: Vector2 = geo["centre"]
		for probe in [c, c + Vector2(0.6, 0.0), c - Vector2(0.6, 0.0), c + Vector2(0.0, 0.6), c - Vector2(0.0, 0.6)]:
			deck = _deck_at(node, probe)
			if deck >= 0.0:
				break
	geo["deck"] = deck
	return deck


static func _deck_at(node: PlacedProp, p: Vector2) -> float:
	var model := node.get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return -1.0
	var base_y := node.global_position.y
	var hits: Array = []
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var xf := mi.global_transform
		var wb: AABB = xf * mi.mesh.get_aabb()
		if p.x < wb.position.x or p.x > wb.end.x or p.y < wb.position.z or p.y > wb.end.z:
			continue
		var faces := mi.mesh.get_faces()
		for t in range(0, faces.size() - 2, 3):
			var a: Vector3 = xf * faces[t]
			var b: Vector3 = xf * faces[t + 1]
			var cc: Vector3 = xf * faces[t + 2]
			var nrm := (b - a).cross(cc - a)
			var ln := nrm.length()
			if ln < 1e-9 or absf(nrm.y) / ln < 0.85:
				continue
			if not Geometry2D.point_is_inside_triangle(p, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(cc.x, cc.z)):
				continue
			var y := a.y - (nrm.x * (p.x - a.x) + nrm.z * (p.y - a.z)) / nrm.y
			var h := y - base_y
			if h > 0.25 and h < 2.6:
				hits.append(h)
	if hits.is_empty():
		return -1.0
	hits.sort()
	var low := float(hits[0])
	var top := low
	for h in hits:
		if float(h) <= low + 0.35:
			top = maxf(top, float(h))
	return top


# --- firepits, weather comfort, DJs ------------------------------------------

## Which placed firepits are burning right now (FirepitBuilder.lit_for — the
## rule FirepitFire draws by), so a cold pit draws no crowd and a lit one
## warms people on a cold night.
func _service_firepits(main: Node) -> void:
	_firepit_lit = {}
	_firepit_pos = {}
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader == null or not loader.has_method("placed_prop_records"):
		return
	var env := {}
	for r in loader.call("placed_prop_records"):
		var rec: Dictionary = r
		if str(rec.get("model_id", "")) != FirepitBuilder.MODEL_ID or bool(rec.get("packed", false)):
			continue
		if env.is_empty():
			env = FirepitBuilder.env_now(main)
		var pid := str(rec.get("id", ""))
		_firepit_lit[pid] = FirepitBuilder.lit_for(rec, env)
		_firepit_pos[pid] = Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))


## This hour's comfort pulls, the spot lists (when anything pulls), and the
## onset of hard rain, which sends everyone on ordinary leisure looking for
## cover NOW rather than at the end of their stint.
func _service_comfort(main: Node, registry: SpaceRegistry, abs_h: float, hour: float) -> void:
	_comfort = comfort_override.duplicate() if not comfort_override.is_empty() \
		else NpcComfort.pulls(_sample_weather(main, hour), hour)
	var rain_on := float(_comfort.get("rain", 0.0)) >= RAIN_WAKE_PULL
	if rain_on and not _rain_on:
		for iid in _engines:
			(_engines[iid] as NpcPopulationEngine).wake_for_weather()
		for iid in _cohorts:
			(_cohorts[iid] as CrowdCohort).wake_for_weather(abs_h, _event_active)
	_rain_on = rain_on
	if NpcComfort.is_calm(_comfort):
		return
	var lit_n := 0
	for pid in _firepit_lit:
		if bool(_firepit_lit[pid]):
			lit_n += 1
	var rev := _prop_revision(main) * 7919 + _camp_revision(main) * 31 \
		+ (registry.spaces.size() if registry != null else 0) * 131 + lit_n * 1000003
	if rev == _comfort_rev and absf(abs_h - _comfort_built_h) < COMFORT_REFRESH_H:
		return
	_comfort_rev = rev
	_comfort_built_h = abs_h
	_build_comfort_spots(main, registry)


func _build_comfort_spots(main: Node, registry: SpaceRegistry) -> void:
	_shade_spots = []
	_warm_spots = []
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and loader.has_method("shade_footprints"):
		_shade_spots = loader.call("shade_footprints")
	if registry != null:
		for item in registry.spaces_of_type("shade"):
			var space: Dictionary = item
			var c: Variant = registry.cached_position(str(space.get("id", "")))
			if not (c is Vector2):
				continue
			var geo := _space_geom(main, space, c)
			var r := maxf(float(geo.get("r", 1.5)), 1.5)
			_shade_spots.append({"pos": geo.get("centre", c), "yaw": 0.0, "size": Vector3(r * 2.0, 2.5, r * 2.0)})
		# Fire circles that are not firepits are fires too.
		for item in registry.spaces_of_type("fire_circle"):
			var space2: Dictionary = item
			var tgt: Dictionary = space2.get("target", {})
			if str(tgt.get("kind", "")) == "prop" and _firepit_lit.has(str(tgt.get("prop_id", ""))):
				continue
			var c2: Variant = registry.cached_position(str(space2.get("id", "")))
			if c2 is Vector2:
				var geo2 := _space_geom(main, space2, c2)
				_warm_spots.append({"pos": c2, "r": maxf(float(geo2.get("r", 0.0)) + 1.5, 3.0)})
	for pid in _firepit_lit:
		if bool(_firepit_lit[pid]):
			_warm_spots.append({"pos": _firepit_pos[pid], "r": FirepitBuilder.RING_R_M})
	_shade_grid = _grid_of(_shade_spots)
	_warm_grid = _grid_of(_warm_spots)


static func _grid_of(spots: Array) -> Dictionary:
	var g := {}
	for k in spots.size():
		var p: Vector2 = (spots[k] as Dictionary)["pos"]
		var key := Vector2i(int(floor(p.x / COMFORT_CELL_M)), int(floor(p.y / COMFORT_CELL_M)))
		var arr: Array = g.get(key, [])
		arr.append(k)
		g[key] = arr
	return g


## A comfort spot for this person ({pos, face} or {} when there is none in
## reach): one of the COMFORT_CHOICES nearest spots of that kind to their
## camp, picked by their FRIEND GROUP's hash so friends go to the same one,
## then a seat in it (under the shade, or round the fire).
func _comfort_spot(kind: String, from: Vector2, agent_id: String) -> Dictionary:
	var warm := kind == NpcComfort.KIND_WARM
	var spots: Array = _warm_spots if warm else _shade_spots
	var grid: Dictionary = _warm_grid if warm else _shade_grid
	if spots.is_empty():
		return {}
	var cx := int(floor(from.x / COMFORT_CELL_M))
	var cz := int(floor(from.y / COMFORT_CELL_M))
	var span := int(ceil(COMFORT_REACH_M / COMFORT_CELL_M))
	var near: Array = []
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			for k in grid.get(Vector2i(cx + dx, cz + dz), []):
				var p: Vector2 = (spots[int(k)] as Dictionary)["pos"]
				var d := p.distance_to(from)
				if d <= COMFORT_REACH_M:
					near.append([d, int(k)])
	if near.is_empty():
		return {}
	near.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var n := mini(near.size(), COMFORT_CHOICES)
	var pick := int(NpcHash.unit01(NpcFriends.key_of(agent_id), "cmfspot") * float(n)) % n
	var spot: Dictionary = spots[int(near[pick][1])]
	if warm:
		return NpcComfort.seat_around(spot["pos"], float(spot.get("r", 2.0)), agent_id)
	return NpcComfort.seat_under(spot, agent_id)


## This person's own bed in the camp at `home` (sheltering / warming up in
## the tent), or null.
func _home_bed_of(main: Node, home: Vector2, agent_id: String) -> Variant:
	var beds := _home_beds(main, home)
	if beds.is_empty():
		return null
	var cut := agent_id.rfind("_npc_")
	var idx := int(agent_id.substr(cut + 5)) if cut > 0 and agent_id.substr(cut + 5).is_valid_int() else absi(hash(agent_id))
	return beds[idx % beds.size()]


## Cast a DJ for every stage with a set on (or starting within DJ_LEAD_H):
## one person per set, deterministic (the lowest hash of the set's key over
## everyone on site), walked to the middle of the stage and stood on its
## deck facing the way the speakers point. Re-cast at most every DJ_RECAST_H
## if they wandered off (a toilet run) — never dragged back mid-visit.
func _service_djs(main: Node, registry: SpaceRegistry, abs_h: float, hour: float) -> void:
	if registry == null:
		_djs = {}
		return
	var live: Dictionary = {}
	for item in registry.spaces_of_type("stage"):
		var space: Dictionary = item
		var sid := str(space.get("id", ""))
		var set_now := _set_window(space, hour, abs_h)
		if set_now.is_empty():
			continue
		var centre: Variant = registry.cached_position(sid)
		if not (centre is Vector2):
			continue
		live[sid] = true
		var geo := _space_geom(main, space, centre)
		var mid: Vector2 = geo.get("centre", centre)
		var fr: Dictionary = _venue_fronts.get(sid, {})
		var fwd: Vector2 = fr.get("fwd", _venue_fwd(space, centre, Vector2.ZERO, 0))
		var deck := float(space.get("perform_h_m", -1.0))
		if deck < 0.0:
			var tgt: Dictionary = space.get("target", {})
			deck = _deck_height(main, str(tgt.get("prop_id", ""))) if str(tgt.get("kind", "")) == "prop" else 0.0
		var spot := VenueCrowd.perform_spot(mid, fwd, maxf(deck, 0.0))
		spot["sid"] = sid
		spot["label"] = str(space.get("label", "")) if not str(space.get("label", "")).is_empty() \
			else SpaceTypes.label("stage")
		var key := "%s|%.2f" % [sid, float(set_now["start_abs"])]
		var d: Dictionary = _djs.get(sid, {})
		if str(d.get("key", "")) != key or not _agent_alive(str(d.get("id", ""))):
			var who := _pick_dj(key)
			if who.is_empty():
				continue
			# A new set (or the clock jumped): the last set's DJ steps down.
			var prev := str(d.get("id", ""))
			if not prev.is_empty() and prev != who:
				_end_dj(prev, abs_h)
			d = {"id": who, "key": key, "cast_h": -INF}
			_djs[sid] = d
		var aid := str(d["id"])
		if _is_performing(aid):
			continue
		# The cooldown is ONLY for a DJ who stepped off for a need (a drink,
		# the toilet) — they finish it first. Anything else that took them
		# off the decks (a >6 h catch-up re-planning the camp, the camp
		# switching tier, a nap) puts them straight back on.
		if _dj_on_a_need(aid) and abs_h - float(d["cast_h"]) < DJ_RECAST_H:
			continue
		if _cast_dj(aid, spot, float(set_now["until_abs"]), abs_h, registry):
			d["cast_h"] = abs_h
	for sid in _djs.keys():
		if not live.has(sid):
			_end_dj(str((_djs[sid] as Dictionary).get("id", "")), abs_h)
			_djs.erase(sid)


# ---------------------------------------------------------------------------
# The burn's ROLES: the fire-flow performers and the sandmen
# ---------------------------------------------------------------------------

## Every tick of a burn (VenueCrowd's stages): cast the FIRE FLOW performers
## for the flow stage and stand them down after it; from the sandmen stage
## kneel the SANDMEN round the line and, when anyone crosses it, send the
## nearest one over to turn them back (REDIRECT_HOLD_H), then back to post.
## Everything ends when the burn leaves BURNING (the circle dance: everyone,
## sandmen included, goes round the fire).
func _service_burn_roles(main: Node, registry: SpaceRegistry, abs_h: float) -> void:
	if registry == null:
		return
	var live := {}
	for item in registry.spaces_of_type("effigy"):
		var space: Dictionary = item
		var sid := str(space.get("id", ""))
		var st: Dictionary = _venue_states.get(sid, {})
		var centre: Variant = registry.cached_position(sid)
		if int(st.get("phase", -1)) != VenueCrowd.EffigyPhase.BURNING or not (centre is Vector2):
			continue
		live[sid] = true
		var key := str(st.get("burn_key", ""))
		var b: Dictionary = _burns.get(sid, {})
		if str(b.get("key", "")) != key:
			_end_burn_roles(b, abs_h)
			b = {"key": key, "performers": [], "sandmen": {}, "handled": {}}
			_burns[sid] = b
		var stage := str(st.get("stage", ""))
		var safe_r := float(st.get("safe_r", VenueCrowd.EFFIGY_SAFE_R_M))
		var c: Vector2 = centre
		# --- fire flow ---------------------------------------------------
		var perf: Array = b["performers"]
		if stage == VenueCrowd.STAGE_FLOW:
			if perf.is_empty():
				var near := _people_near(c, safe_r + 40.0, {})
				var n := mini(VenueCrowd.flow_count(near.size()), near.size())
				near.sort_custom(func(x, y): return NpcHash.unit01(str(x), key + "flow") < NpcHash.unit01(str(y), key + "flow"))
				var t0 := float(st.get("flow_t0", abs_h))
				var until := abs_h + maxf(float(st.get("stage_ends_in_h", 0.1)), 0.01)
				for k in n:
					var aid := str(near[k])
					var orbit := VenueCrowd.flow_orbit(c, safe_r, k, n, t0)
					var p := VenueCrowd.orbit_point(orbit, abs_h)
					if _cast_dj(aid, {"pos": p, "face": p + VenueCrowd.ccw_tangent(c, p) * 10.0,
							"role": "flow", "orbit": orbit, "sid": sid}, until, abs_h, registry):
						perf.append(aid)
		elif not perf.is_empty():
			for aid in perf:
				_end_dj(str(aid), abs_h)
			b["performers"] = []
		# --- sandmen -------------------------------------------------------
		if stage != VenueCrowd.STAGE_SANDMEN and stage != VenueCrowd.STAGE_BURN:
			continue
		var sand: Dictionary = b["sandmen"]
		if sand.is_empty():
			var n2 := VenueCrowd.sandman_count(safe_r)
			var near2 := _people_near(c, safe_r + 40.0, {})
			# The nearest of the gathered take the posts (stable by hash).
			near2.sort_custom(func(x, y): return NpcHash.unit01(str(x), key + "sand") < NpcHash.unit01(str(y), key + "sand"))
			for k in mini(n2, near2.size()):
				var aid2 := str(near2[k])
				var post := VenueCrowd.sandman_post(c, safe_r, k, n2)
				if _cast_dj(aid2, {"pos": post["pos"], "face": post["face"], "role": "sandman", "sid": sid},
						abs_h + 24.0, abs_h, registry):
					sand[aid2] = {"post": post["pos"], "face": post["face"], "state": "post", "since": abs_h}
		# Back to post after a redirect.
		for aid3 in sand:
			var sd: Dictionary = sand[aid3]
			if str(sd["state"]) == "redirect" and abs_h - float(sd["since"]) >= REDIRECT_HOLD_H:
				if _cast_dj(str(aid3), {"pos": sd["post"], "face": sd["face"], "role": "sandman", "sid": sid},
						abs_h + 24.0, abs_h, registry):
					sd["state"] = "post"
					sd["since"] = abs_h
		if not bool(st.get("perimeter", false)):
			continue
		# Anyone across the line: the nearest kneeling sandman goes to them.
		var handled: Dictionary = b["handled"]
		for who in _people_inside(c, safe_r - VenueCrowd.BREACH_INSET_M):
			var wid := str(who[0])
			if sand.has(wid) or abs_h - float(handled.get(wid, -INF)) < REDIRECT_COOLDOWN_H:
				continue
			var wp: Vector2 = who[1]
			var best := ""
			var best_d := INF
			for aid4 in sand:
				var sd2: Dictionary = sand[aid4]
				if str(sd2["state"]) != "post":
					continue
				var dd := (sd2["post"] as Vector2).distance_to(wp)
				if dd < best_d:
					best_d = dd
					best = str(aid4)
			handled[wid] = abs_h
			var o := _tier_owner(wid)
			if o is CrowdCohort:
				(o as CrowdCohort).redirect_out(wid, c, safe_r, abs_h, registry)
			elif o is NpcPopulationEngine:
				(o as NpcPopulationEngine).redirect_out(wid, c, safe_r, registry)
			_burn_redirects += 1
			if best.is_empty():
				continue
			# The sandman steps up beside them, between them and the fire,
			# and turns them round (arm out toward the crowd).
			var out_dir := (wp - c).normalized() if (wp - c).length() > 0.01 else Vector2(1, 0)
			var stand := c + out_dir * maxf(wp.distance_to(c) - 0.6, 1.0)
			if _cast_dj(best, {"pos": stand, "face": c + out_dir * (safe_r + 20.0), "role": "redirect", "sid": sid},
					abs_h + 24.0, abs_h, registry):
				var sd3: Dictionary = sand[best]
				sd3["state"] = "redirect"
				sd3["since"] = abs_h
		_invalidate_dots()
	for sid in _burns.keys():
		if not live.has(sid):
			_end_burn_roles(_burns[sid], abs_h)
			_burns.erase(sid)


## How many people sandmen have turned back (harness / diagnostics).
var _burn_redirects := 0

func burn_redirects() -> int:
	return _burn_redirects


func _end_burn_roles(b: Dictionary, abs_h: float) -> void:
	for aid in b.get("performers", []):
		_end_dj(str(aid), abs_h)
	for aid in (b.get("sandmen", {}) as Dictionary):
		_end_dj(str(aid), abs_h)


## {sid: {stage, performers: [ids], sandmen: [ids]}} — the burn roles now
## (the fire-prop effect, the harness).
func burn_roles() -> Dictionary:
	var out := {}
	for sid in _burns:
		var b: Dictionary = _burns[sid]
		out[sid] = {"performers": (b.get("performers", []) as Array).duplicate(),
			"sandmen": (b.get("sandmen", {}) as Dictionary).keys(),
			"stage": str((_venue_states.get(sid, {}) as Dictionary).get("stage", ""))}
	return out


## Everyone on site within `r` of `c` who is free to take a role (not
## performing already, not asleep): ids.
func _people_near(c: Vector2, r: float, exclude: Dictionary) -> Array:
	var out: Array = []
	var t := _last_abs_h
	for iid in _cohorts:
		if str(_tiers.get(iid, CrowdFocus.TIER_FULL)) != CrowdFocus.TIER_LIGHT:
			continue
		var co: CrowdCohort = _cohorts[iid]
		for i in co.count():
			if co.alive[i] != 1 or co.act[i] == CrowdCohort.A_PERFORM or co.act[i] == CrowdCohort.A_SLEEP \
					or exclude.has(co.ids[i]):
				continue
			if co.pos_at(i, t).distance_to(c) <= r:
				out.append(co.ids[i])
	for iid in _engines:
		for a in (_engines[iid] as NpcPopulationEngine).agents:
			var ag: NpcAgent = a
			if ag.controlled_by_peer != 0 or ag.activity == NpcAgent.PERFORM_ACTIVITY \
					or ag.activity == "sleep" or exclude.has(ag.id):
				continue
			if ag.pos.distance_to(c) <= r:
				out.append(ag.id)
	return out


## Everyone (not performing) closer than `r` to `c`: [[id, pos]].
func _people_inside(c: Vector2, r: float) -> Array:
	var out: Array = []
	var t := _last_abs_h
	for iid in _cohorts:
		if str(_tiers.get(iid, CrowdFocus.TIER_FULL)) != CrowdFocus.TIER_LIGHT:
			continue
		var co: CrowdCohort = _cohorts[iid]
		for i in co.count():
			if co.alive[i] != 1 or co.act[i] == CrowdCohort.A_PERFORM or co.act[i] == CrowdCohort.A_SLEEP:
				continue
			var p := co.pos_at(i, t)
			if p.distance_to(c) < r:
				out.append([co.ids[i], p])
	for iid in _engines:
		for a in (_engines[iid] as NpcPopulationEngine).agents:
			var ag: NpcAgent = a
			if ag.activity == NpcAgent.PERFORM_ACTIVITY or ag.activity == "sleep":
				continue
			if ag.pos.distance_to(c) < r:
				out.append([ag.id, ag.pos])
	return out


func _end_dj(agent_id: String, abs_h: float) -> void:
	var o := _tier_owner(agent_id)
	if o is CrowdCohort:
		(o as CrowdCohort).end_perform(agent_id, abs_h)
	elif o is NpcPopulationEngine:
		(o as NpcPopulationEngine).end_perform(agent_id)


## The set a stage is playing now or starting within DJ_LEAD_H:
## {start_abs, until_abs} in absolute hours, {} when nothing is on.
static func _set_window(space: Dictionary, hour: float, abs_h: float) -> Dictionary:
	for s in space.get("program", []):
		if not (s is Dictionary):
			continue
		var slot: Dictionary = s
		var a := float(slot.get("start_h", 0.0))
		var b := float(slot.get("end_h", 0.0))
		var dur := fposmod(b - a, 24.0)
		if dur <= 0.0:
			dur = 24.0
		if FestivalProgram.slot_covers(slot, hour):
			var since := fposmod(hour - a, 24.0)
			return {"start_abs": abs_h - since, "until_abs": abs_h - since + dur}
		var wait := fposmod(a - fposmod(hour, 24.0), 24.0)
		if wait <= DJ_LEAD_H:
			return {"start_abs": abs_h + wait, "until_abs": abs_h + wait + dur}
	return {}


## Everyone on site, by the set's key: the lowest hash wins, skipping anyone
## already DJing another stage.
func _pick_dj(key: String) -> String:
	var busy := {}
	for sid in _djs:
		busy[str((_djs[sid] as Dictionary).get("id", ""))] = true
	var best := ""
	var best_u := INF
	for iid in _cohorts:
		if str(_tiers.get(iid, CrowdFocus.TIER_FULL)) != CrowdFocus.TIER_LIGHT:
			continue
		var c: CrowdCohort = _cohorts[iid]
		for i in c.count():
			if c.alive[i] != 1 or busy.has(c.ids[i]):
				continue
			var u := NpcHash.unit01(c.ids[i], key)
			if u < best_u:
				best_u = u
				best = c.ids[i]
	for iid in _engines:
		for a in (_engines[iid] as NpcPopulationEngine).agents:
			var ag: NpcAgent = a
			if ag.controlled_by_peer != 0 or busy.has(ag.id):
				continue
			var u2 := NpcHash.unit01(ag.id, key)
			if u2 < best_u:
				best_u = u2
				best = ag.id
	return best


func _tier_owner(agent_id: String) -> Object:
	for iid in _engines:
		if (_engines[iid] as NpcPopulationEngine).find_agent(agent_id) != null:
			return _engines[iid]
	for iid in _cohorts:
		if str(_tiers.get(iid, CrowdFocus.TIER_FULL)) == CrowdFocus.TIER_LIGHT \
				and (_cohorts[iid] as CrowdCohort).agent_index(agent_id) >= 0:
			return _cohorts[iid]
	return null


## Is this person walking to, queueing for or doing a NEED (eat, drink, the
## toilet, a wash)?
func _dj_on_a_need(agent_id: String) -> bool:
	var o := _tier_owner(agent_id)
	if o is CrowdCohort:
		return (o as CrowdCohort).on_a_need(agent_id)
	if o is NpcPopulationEngine:
		var a := (o as NpcPopulationEngine).find_agent(agent_id)
		return a != null and a.activity in ["hunger", "thirst", "bladder", "hygiene"] \
			and a.state != NpcAgent.State.IDLE
	return false


func _agent_alive(agent_id: String) -> bool:
	if agent_id.is_empty():
		return false
	var o := _tier_owner(agent_id)
	if o is CrowdCohort:
		var i := (o as CrowdCohort).agent_index(agent_id)
		return i >= 0 and (o as CrowdCohort).alive[i] == 1
	return o != null


func _is_performing(agent_id: String) -> bool:
	var o := _tier_owner(agent_id)
	if o is CrowdCohort:
		return (o as CrowdCohort).is_performing(agent_id)
	if o is NpcPopulationEngine:
		return (o as NpcPopulationEngine).is_performing(agent_id)
	return false


func _cast_dj(agent_id: String, spot: Dictionary, until_abs: float, abs_h: float,
		registry: SpaceRegistry) -> bool:
	var o := _tier_owner(agent_id)
	if o is CrowdCohort:
		var ctx := {"registry": registry, "no_go": _no_go_circles(),
			"plan_path": func(from_xz: Vector2, to_xz: Vector2, from_key: String,
					to_key: String, lane_seed: int) -> Variant:
				return _plan_path(from_xz, to_xz, from_key, to_key, lane_seed)}
		var ok := (o as CrowdCohort).perform(agent_id, spot, until_abs, abs_h, ctx)
		if ok:
			_invalidate_dots()
		return ok
	if o is NpcPopulationEngine:
		return (o as NpcPopulationEngine).perform(agent_id, spot, until_abs)
	return false


## The deck height a DJ stands on for this prop (measured from its model;
## -1 when nothing qualifies) — the space tag row shows it as the auto value.
func stage_deck_m(main: Node, prop_id: String) -> float:
	return _deck_height(main, prop_id)


## Who is DJing which stage right now: {stage space id: agent id}.
func djs() -> Dictionary:
	var out := {}
	for sid in _djs:
		out[sid] = str((_djs[sid] as Dictionary).get("id", ""))
	return out


## This tick's weather comfort pulls (NpcComfort.pulls).
func comfort_pulls() -> Dictionary:
	return _comfort


## {height_m, footprint_r_m} of an unlit effigy prop, from its live pick
## AABB — cached per prop node (a rebuild mints a new node and re-measures).
func _effigy_size(main: Node, prop_id: String) -> Dictionary:
	if prop_id.is_empty():
		return {}
	var root := main.find_child("PlacedProps", true, false) if main != null else null
	if root == null:
		return {}
	var cached: Dictionary = _effigy_sizes.get(prop_id, {})
	for child in root.get_children():
		if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
			if int(cached.get("node", 0)) == child.get_instance_id():
				return cached["size"]
			var bb: AABB = (child as PlacedProp).get_world_pick_aabb()
			var size := {}
			if bb.size.length_squared() > 0.01:
				size = {"height_m": bb.size.y,
					"footprint_r_m": maxf(bb.size.x, bb.size.z) * 0.5}
			_effigy_sizes[prop_id] = {"node": child.get_instance_id(), "size": size}
			return size
	return {}


## The registry agents will read this map (loader-owned or scene fallback) —
## for tooling/harness seeding.
func registry_for(main: Node) -> SpaceRegistry:
	return _find_registry(main)


# --- internals --------------------------------------------------------------

func _find_registry(main: Node) -> SpaceRegistry:
	# TerrainSurfaceQuery (static) rather than the Services autoload: autoloads
	# don't exist under `--script`, and a compile-time `Services` identifier
	# made this whole file fail to parse in the headless selftest.
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null:
		var reg: Variant = loader.get("npc_spaces")
		if reg is SpaceRegistry:
			return reg
	if _fallback_registry == null:
		_fallback_registry = SpaceRegistry.create_empty()
		var scene_key := str(main.scene_file_path) if main != null else ""
		if not scene_key.is_empty():
			_fallback_registry.load_for_scene(scene_key)
	return _fallback_registry


func _ensure_engine(iid: String, specs: Dictionary, main: Node) -> NpcPopulationEngine:
	var count := clampi(int(float(specs.get("occupants", 10.0))), 1, 200)
	var engine: NpcPopulationEngine = _engines.get(iid)
	if engine != null and int(_configured_count.get(iid, -1)) == count:
		return engine
	if engine != null and int(_configured_count.get(iid, -1)) > 0:
		# The headcount moved: resize IN PLACE (see _ensure_cohort).
		engine.resize(count, iid, _home_pos(specs, main), _find_registry(main))
		_configured_count[iid] = count
		_invalidate_dots()
		return engine
	if _parked.has(iid):
		# Promotion from the light tier: the parked engine (board, labour,
		# skills, signals already wired) takes the crowd's people back.
		engine = _parked[iid]
		_parked.erase(iid)
		if _cohorts.has(iid):
			NpcTierConvert.to_full(_cohorts[iid], engine, _find_registry(main))
			_cohorts.erase(iid)
		_invalidate_dots()
		_engines[iid] = engine
		_configured_count[iid] = count
		return engine
	engine = NpcPopulationEngine.new()
	var snap: Dictionary = specs.get("pop_state", {}) as Dictionary
	if CrowdCohort.is_light_snapshot(snap) and int(snap.get("n", -1)) == count:
		# Saved while light: rebuild the crowd, promote it below.
		var c := CrowdCohort.new()
		c.restore(snap)
		_cohorts[iid] = c
		engine.configure(count, iid, _home_pos(specs, main))
	elif not snap.is_empty() and (snap.get("agents", []) as Array).size() == count:
		engine.restore(snap)
		_invalidate_dots()
	else:
		engine.configure(count, iid, _home_pos(specs, main))
	# An authored routine is CONFIG, not simulation state: it lives in
	# specs.pop_routine and survives independently of the roster snapshot, so
	# resetting the population keeps the schedule the player wrote.
	var routine_arr: Array = specs.get("pop_routine", []) as Array
	engine.routine = NpcRoutine.from_array(routine_arr) if not routine_arr.is_empty() \
			else NpcRoutine.default_day()
	engine.anim_overrides = (specs.get("pop_anim_map", {}) as Dictionary).duplicate()
	# Also config rather than simulation state: an absent key normalizes to
	# STRIKE, which is exactly the behaviour that shipped, so every existing
	# save keeps running the way it always has.
	engine.consequence = NpcConsequence.normalize(specs.get("pop_consequence", ""))
	# Skills and the duty rota are CONFIG too, for the same reason: the
	# settlement's expertise and the schedule the player wrote should
	# outlive a "Reset population". Agent ids are regenerated identically
	# by configure(), so both reattach to the same slots.
	engine.skills = NpcSkills.deserialize(specs.get("pop_skills", {}) as Dictionary)
	engine.duty.load_duties(specs.get("pop_duties", {}) as Dictionary)
	engine.oncall.load_from(specs.get("pop_oncall", {}) as Dictionary)
	# Departures and collapse are narrative events. They go into the settlement
	# LOG (per-consumer cursors: the graph toast and the challenge bake's
	# collapse watcher can no longer race), which also finally puts these story
	# beats in the settlement feed — before this the feed missed every one.
	# Texts are deliberately TIGHT — name first, one em-dash, the reason in the
	# player's words. The meta {title, detail} split feeds the toast chips'
	# two-line layout; the text alone stays a complete feed line.
	engine.agent_departed.connect(
		func(_aid: String, who: String, reason: String) -> void:
			var why := _need_text(reason)
			settlement_log().add("departed", "%s left — %s" % [who, why],
				_last_abs_h, SettlementLog.ALERT, iid,
				{"title": "%s left" % who, "detail": why}))
	engine.collapse_warning.connect(
		func(_risk: float) -> void:
			settlement_log().add("collapse_warning",
				"People are talking about leaving",
				_last_abs_h, SettlementLog.ALERT, iid,
				{"title": "The community is unravelling",
					"detail": "people are talking about leaving"}))
	engine.colony_collapsed.connect(
		func() -> void:
			settlement_log().add("collapsed",
				"Colony collapse — too few people remain",
				_last_abs_h, SettlementLog.ALERT, iid,
				{"title": "Colony collapse",
					"detail": "too few people remain to keep this place running"}))
	engine.colony_deserted.connect(
		func(cause: String) -> void:
			var why2 := _need_text(cause)
			settlement_log().add("deserted",
				"Everyone has left — %s" % why2,
				_last_abs_h, SettlementLog.ALERT, iid,
				{"title": "Everyone has left",
					"detail": "%s · fix it, then Reset population" % why2}))
	engine.agent_lost.connect(
		func(_aid: String, who: String, reason: String) -> void:
			# The PERISH consequence, and only ever that — stated plainly.
			settlement_log().add("lost", "%s did not make it — %s" % [who, reason],
				_last_abs_h, SettlementLog.ALERT, iid,
				{"title": "%s did not make it" % who, "detail": reason}))
	engine.skill_earned.connect(
		func(aid: String, who: String, tag: String) -> void:
			# Apprenticeship made visible: train() reports the crossing exactly
			# once, so this cannot spam. NOTE severity — good news, not an alarm.
			# agent_id rides the meta so the chip can open THIS person's ledger.
			settlement_log().add("skill_earned", "%s qualified: %s" % [
				who, NpcSkills.label(tag)], _last_abs_h, SettlementLog.NOTE, iid,
				{"title": "%s qualified" % who, "detail": NpcSkills.label(tag),
					"agent_id": aid}))
	if _cohorts.has(iid):
		NpcTierConvert.to_full(_cohorts[iid], engine, _find_registry(main))
		_cohorts.erase(iid)
		_invalidate_dots()
	_engines[iid] = engine
	_configured_count[iid] = count
	return engine


## The needs, in the words a player uses. Shared by the departure/desertion
## log lines; the fallback covers the morale rage-quit, which has no need.
static func _need_text(need: String) -> String:
	match need:
		"thirst": return "no water"
		"hunger": return "no food"
		"sleep": return "nowhere to sleep"
		"bladder": return "no sanitation"
	return NpcMorale.label(0.0)


## THE LABOUR MERGE: a machine waiting on hands gets a real chore, at the
## machine, that a real person walks to and does.
##
## Before this, `ChoreLedger` and `NpcChoreBoard` shared a unit name and
## nothing else — `credit_available()` had zero callers, and a recipe step
## needing `chore_hours` could never be satisfied by the crew standing next to
## it. It waited for a player button instead.
##
## Idempotent: the chore id is remembered on the machine's own specs, so a
## re-tick finds the existing chore rather than minting a second one. The
## chore's completion `effect` calls the SAME `RecipeRunner.confirm_chore` the
## Confirm button always did — so the ledger stays the meter (Site Report
## totals keep working) while the crew becomes the gate.
## The duty rota, once per sim-day.
##
## Settle yesterday, top the plan back up to the horizon, mint today's slots
## onto the board, and retire finished one-offs so a month of dead chores is
## not competing with the rota for MAX_CHORES.
func _service_duty_roster(iid: String, engine: NpcPopulationEngine,
		abs_h: float) -> void:
	var board := engine.chore_board
	if board == null:
		return
	var day := NpcChoreBoard.day_index(abs_h)
	if int(_last_duty_day.get(iid, -999999)) == day:
		return
	_last_duty_day[iid] = day
	var ids: Array = []
	for a in engine.agents:
		ids.append((a as NpcAgent).id)
	if ids.is_empty():
		return
	engine.skills.forget_missing(ids)
	engine.duty.settle_day(board, day)
	engine.duty.generate(day, ids, engine.skills, engine.labour)
	engine.duty.mint_day(board, day, abs_h, ids, engine.skills,
		engine.labour, settlement_log())
	board.prune_completed(abs_h)
	engine.labour.prune(day - NpcLabourLog.KEEP_DAYS)
	# A new day of assignments is exactly when a stale one should be caught.
	board.validate_assignments(ids)
	_last_persist_h.erase(iid)


func _service_machine_chores(iid: String, engine: NpcPopulationEngine, model,
		main: Node, _abs_h: float) -> void:
	var board := engine.chore_board
	if board == null or model == null:
		return
	for item in model.get_items_in_scope("root"):
		var d: Dictionary = item
		var specs: Dictionary = d.get("specs", {})
		if not bool(specs.get("recipe_waiting_chore", false)):
			continue
		if str(specs.get("recipe_waiting_kind", "")) != "crew":
			continue   # a require_confirm step wants a DECISION, not hands
		var gid := str(d.get("id", ""))
		var step_id := str(specs.get("recipe_waiting_step_id", ""))
		if gid.is_empty() or step_id.is_empty():
			continue
		var want_id := "mach|%s|%s" % [gid, step_id]
		# Already minted and still live? Nothing to do. Checked by KEY as well
		# as by id, because a reloaded board renumbers its chores and the
		# remembered id would miss — minting a duplicate every tick.
		var existing := str(specs.get("recipe_chore_id", ""))
		if not existing.is_empty() and not board.find(existing).is_empty():
			continue
		if not board.find_by_key(want_id).is_empty():
			continue
		# A packed machine cannot be operated — send the crew to UNPACK it
		# instead. "They unpack the mill, then run it" is both correct and the
		# most on-theme moment the feature has.
		var prop_id := str(specs.get("bound_prop_id", ""))
		var label := str(specs.get("recipe_waiting_label", "Tend the machine"))
		var hours := maxf(float(specs.get("recipe_waiting_chore_hrs", 0.25)), 0.05)
		var effect: Dictionary = {"op": "recipe_step_done",
			"item_id": gid, "step_id": step_id}
		if bool(specs.get("packed_3d", false)) and not prop_id.is_empty():
			label = "Unpack %s" % str(specs.get("name", "the machine"))
			effect = {"op": "unpack_prop", "prop_id": prop_id}
		var opts := {
			"repeat": "once",
			"priority": 3,
			"exposure": NpcWeatherGate.EXPOSURE_SHELTERED,
			"min_workers": 1, "max_workers": 1,
			"window": {"start_h": 0.0, "end_h": 24.0},
			"effect": effect,
			"chore_key": want_id,
		}
		# Target the machine's 3D twin so people actually walk to it. With no
		# bound prop the work happens where they stand, which is the honest
		# fallback for a graph-only site.
		if not prop_id.is_empty():
			opts["target"] = {"kind": "prop", "id": prop_id}
		var cid := board.add_chore(label, hours, opts)
		if cid.is_empty():
			continue
		var patch: Dictionary = (d.get("specs", {}) as Dictionary).duplicate(true)
		patch["recipe_chore_id"] = cid
		model.update_item(gid, {"specs": patch})


## On-call roles (NpcOnCall): who answers when something breaks.
##
## FIXABLE conditions already have a real chore — _service_machine_chores mints
## it — so on-call only NAMES the responder on it, as a short first refusal
## (they get ONCALL_HOLD_H to show up; then anyone covers, which is the same
## path a duty substitute takes). ESCALATE conditions have no finishable unit
## of work behind them, so the response is a short inspect chore (the responder
## walks over to look — visible, honest) plus a latched alarm that NAMES them.
## The fix stays the player's, because the graph has no repair model.
##
## Also runs the un-mint sweep EVERY tick, roles or no roles — that is the fix
## for the `mach|` leak, where a machine the player fixed by hand left a
## phantom job on the board forever, and it retires yesterday's duty-slot
## instances too.
const ONCALL_HOLD_H := 0.5

func _service_oncall(iid: String, engine: NpcPopulationEngine, model,
		abs_h: float) -> void:
	var board := engine.chore_board
	if board == null or model == null:
		return
	var oc := engine.oncall
	var lg := settlement_log()
	var ids: Array = []
	for a in engine.agents:
		ids.append((a as NpcAgent).id)
	var wanted: Dictionary = {}
	if oc != null and not oc.roles.is_empty() and not ids.is_empty():
		# --- fixable: put the responder's name on the machine chores ---------
		for item in model.get_items_in_scope("root"):
			var d: Dictionary = item
			var specs: Dictionary = d.get("specs", {})
			if not bool(specs.get("recipe_waiting_chore", false)):
				continue
			if str(specs.get("recipe_waiting_kind", "")) != "crew":
				continue
			var gid := str(d.get("id", ""))
			var step_id := str(specs.get("recipe_waiting_step_id", ""))
			var rec := board.find_by_key("mach|%s|%s" % [gid, step_id])
			if rec.is_empty() or rec.has("oncall_named"):
				continue
			var cond := NpcOnCall.FIX_MACHINE_PACKED \
				if bool(specs.get("packed_3d", false)) else NpcOnCall.FIX_MACHINE_STALLED
			var role := oc.role_for(cond)
			if role.is_empty():
				continue
			var who := oc.next_responder(role, ids, engine.labour, engine.skills)
			if who.is_empty():
				continue   # everybody in the role has left; the chore stays open
			rec["assigned_to"] = who
			rec["assign_at_h"] = abs_h
			rec["assign_hold_h"] = ONCALL_HOLD_H
			rec["oncall_named"] = who
			lg.add("oncall_page", "%s is on call for %s — %s" % [
				_agent_name(engine, who), str(role.get("label", "the role")),
				str(rec.get("label", "a machine"))], abs_h, SettlementLog.NOTE, cond)
		# --- escalations: mint the look, latch the alarm, name the name ------
		var item_specs: Dictionary = \
			((_model_item_cache.get(iid, {}) as Dictionary).get("specs", {}) as Dictionary)
		var active: Dictionary = {}
		var starved: Array = item_specs.get("starved_kinds", []) as Array
		if not starved.is_empty():
			active[NpcOnCall.ESC_STARVED] = "The %s supply has run out" % str(starved[0])
		if engine.collapse_risk() >= NpcPopulationEngine.COLLAPSE_WARN_RISK:
			active[NpcOnCall.ESC_COLLAPSE_RISK] = "People are starting to leave"
		for cond2 in [NpcOnCall.ESC_STARVED, NpcOnCall.ESC_COLLAPSE_RISK]:
			var role2 := oc.role_for(str(cond2))
			if role2.is_empty():
				continue
			var alarm_key := "oncall|%s|%s" % [iid, str(cond2)]
			if not active.has(cond2):
				lg.clear_latch(alarm_key, "", abs_h, str(cond2))
				continue
			var key := NpcOnCall.chore_key_for(str(cond2), iid,
				str(role2.get("role_id", "")))
			wanted[key] = true
			var who2 := oc.next_responder(role2, ids, engine.labour, engine.skills)
			if who2.is_empty():
				lg.latch(alarm_key, "%s — nobody in %s is left to answer" % [
					str(active[cond2]), str(role2.get("label", "the role"))],
					abs_h, SettlementLog.ALERT, str(cond2))
				continue
			lg.latch(alarm_key, "%s — %s is on call" % [
				str(active[cond2]), _agent_name(engine, who2)],
				abs_h, SettlementLog.ALERT, str(cond2))
			if not board.find_by_key(key).is_empty():
				continue
			var opts := {
				"repeat": "once", "priority": 5,
				"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
				"min_workers": 1, "max_workers": 1,
				"window": {"start_h": 0.0, "end_h": 24.0},
				"assigned_to": who2, "chore_key": key,
			}
			var prop_id := str(item_specs.get("bound_prop_id", ""))
			if not prop_id.is_empty():
				opts["target"] = {"kind": "prop", "id": prop_id}
			# LOOK_HOURS sits under NpcWorkPose.GATE_HOURS, so this classifies
			# as INSPECT — the responder stands and assesses, which is what is
			# actually happening.
			var cid := board.add_chore("Check: %s" % str(active[cond2]).to_lower(),
				NpcOnCall.LOOK_HOURS, opts)
			if not cid.is_empty():
				var rec2 := board.find(cid)
				rec2["assign_at_h"] = abs_h
				rec2["assign_hold_h"] = ONCALL_HOLD_H
	# --- the un-mint sweep, unconditionally ---------------------------------
	NpcOnCall.sweep_stale(board, wanted,
		func(key: String) -> bool: return _machine_key_live(model, key), abs_h)
	# Covered duty slots: log the substitution once. NOTE, not ALERT — a
	# covered shift is the system working.
	for c in board.chores:
		var ch: Dictionary = c
		if not str(ch.get("chore_key", "")).begins_with("duty|"):
			continue
		var cover := str(ch.get("covered_by", ""))
		if cover.is_empty() or bool(ch.get("covered_logged", false)):
			continue
		ch["covered_logged"] = true
		lg.add("duty_cover", "%s stepped in on %s (%s did not show)" % [
			_agent_name(engine, cover), str(ch.get("label", "a duty")),
			_agent_name(engine, str(ch.get("assigned_to", "")))],
			abs_h, SettlementLog.NOTE, str(ch.get("chore_key", "")))


## Is the machine this `mach|<gid>|<step>` chore was minted for still waiting
## on that step with crew hands? Feeds the un-mint sweep.
func _machine_key_live(model, key: String) -> bool:
	if model == null:
		return false
	var gid := key.get_slice("|", 1)
	var step := key.get_slice("|", 2)
	var item: Dictionary = model.get_item(gid)
	if item.is_empty():
		return false
	var specs: Dictionary = item.get("specs", {})
	return bool(specs.get("recipe_waiting_chore", false)) \
		and str(specs.get("recipe_waiting_kind", "")) == "crew" \
		and str(specs.get("recipe_waiting_step_id", "")) == step


func _agent_name(engine: NpcPopulationEngine, agent_id: String) -> String:
	for a in engine.agents:
		var ag: NpcAgent = a
		if ag.id == agent_id:
			return ag.display_name
	return agent_id if not agent_id.is_empty() else "somebody"


## The settlement's persistent feed. Survives fast-forward, unlike a toast.
func settlement_log() -> SettlementLog:
	if _log == null:
		_log = SettlementLog.create_empty()
	return _log


## Everything `consumer` has not read yet — non-destructive for every other
## consumer.
func log_since(consumer: String) -> Array:
	return settlement_log().since(consumer)


## Latch/clear the "nobody can get X" alarms once per habitat per need.
##
## Keyed on duration rather than the flapping `blocked` flag: an agent retries
## every RETRY_BACKOFF_H, so an alarm on the raw flag would post the same line
## several times an hour. ALARM_H of standing failure is the signal.
const ALARM_H := 0.5
## need -> {habitat id: true} for every habitat whose need alarm is standing.
var _alarm_habs: Dictionary = {}

func _service_alarms(iid: String, engine: NpcPopulationEngine, abs_h: float) -> void:
	if PopTestPrefs.mute_alarms():
		return
	var lg := settlement_log()
	for need in NpcAgent.NEEDS:
		var worst := 0.0
		var who := ""
		for a in engine.agents:
			var ag: NpcAgent = a
			var h := ag.blocked_hours(str(need), abs_h)
			if h > worst:
				worst = h
				who = ag.display_name
		# ONE alarm per need for the whole site: a festival of 35 camps used to
		# post "Nobody can reach a Restroom" 35 times. Each habitat's standing
		# failure is tracked in _alarm_habs; the line goes up with the first and
		# clears with the last.
		var key := "need_unmet|site|%s" % str(need)
		var habs: Dictionary = _alarm_habs.get(str(need), {})
		_alarm_habs[str(need)] = habs
		# A habitat that went away (camp deleted, festival cleared, population
		# reset) never ticks again to erase itself: drop it here, or the site
		# alarm could never clear.
		for gone in habs.keys():
			if not _engines.has(gone):
				habs.erase(gone)
		if worst >= ALARM_H:
			habs[iid] = true
		elif worst <= 0.0:
			habs.erase(iid)
		if worst >= ALARM_H and not lg.is_latched(key):
			var space := SpaceTypes.label(str(NpcAgent.space_of(str(need))))
			var line := "Nobody can reach a %s — work is backing up" % space
			# `who` (worst affected) used to be computed and thrown away; naming
			# the RESPONDER is where it finally goes. The alarm stays up either
			# way — the fix (tag a space, fix the supply) is the player's.
			var role: Dictionary = engine.oncall.role_for(NpcOnCall.ESC_NEED_UNMET) \
				if engine.oncall != null else {}
			if not role.is_empty():
				var ids: Array = []
				for a2 in engine.agents:
					ids.append((a2 as NpcAgent).id)
				var resp := engine.oncall.next_responder(role, ids,
					engine.labour, engine.skills)
				if not resp.is_empty():
					line += " — %s is on call" % _agent_name(engine, resp)
			if not who.is_empty():
				line += " (%s has waited longest)" % who
			lg.latch(key, line, abs_h, SettlementLog.ALERT, str(need))
		elif habs.is_empty():
			lg.clear_latch(key, "", abs_h, str(need))


## Challenge replay: snapshot / restore every live engine so a retry replays
## the SAME segment from identical population state.
## While a sim pre-render steps every camp to the range's end, the tier
## decision must hold still: `restore_all` only restores a roster whose camp
## is still in the tier the snapshot was taken in (a FULL snapshot cannot land
## on a LIGHT cohort), and CrowdFocus re-tiers on the viewer's distance.
var _tiers_frozen: bool = false


func freeze_tiers(on: bool) -> void:
	_tiers_frozen = on


func snapshot_all(abs_h: float) -> Dictionary:
	var out: Dictionary = {}
	for iid in _engines:
		out[str(iid)] = (_engines[iid] as NpcPopulationEngine).snapshot(abs_h)
	for iid in _cohorts:
		out[str(iid)] = (_cohorts[iid] as CrowdCohort).snapshot(abs_h)
	return out


func restore_all(snaps: Dictionary) -> void:
	for iid in snaps:
		if not (snaps[iid] is Dictionary):
			continue
		if _engines.has(str(iid)):
			(_engines[str(iid)] as NpcPopulationEngine).restore(snaps[iid] as Dictionary)
		elif _cohorts.has(str(iid)) and CrowdCohort.is_light_snapshot(snaps[iid]):
			(_cohorts[str(iid)] as CrowdCohort).restore(snaps[iid] as Dictionary)
	_invalidate_dots()


func has_pop_driven() -> bool:
	return not _engines.is_empty() or not _cohorts.is_empty()


## Where the population anchors in world XZ: the habitat's 3D twin when one
## is placed, else the world origin (SoI center).
func _home_pos(specs: Dictionary, main: Node) -> Vector2:
	# A festival camp's habitat carries its lot centre (CampTemplates stamp
	# it); there is no prop to anchor on.
	if specs.has("home_x") and specs.has("home_z"):
		return Vector2(float(specs.get("home_x", 0.0)), float(specs.get("home_z", 0.0)))
	var pid := str(specs.get("bound_prop_id", ""))
	if not pid.is_empty():
		var rec: Dictionary = PlacedPropService.get_prop_record(main, pid)
		if not rec.is_empty():
			return Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	# Nothing to anchor on: the site's centre (the location marker), never the
	# world origin.
	return SiteCentre.xz(main)


## Change-gated snapshot into specs.pop_state (survives save/load via the
## graph's normal serialize path). Interval + identical-blob gates keep the
## 0.75 s autosave debounce from storming.
## Is this habitat's snapshot due — its jittered interval elapsed AND a slot
## left in this tick's persist budget? A habitat with no entry (never saved,
## or cleared by a project edit to force a save) is due at once.
func _persist_due(iid: String, abs_h: float) -> bool:
	var last := float(_last_persist_h.get(iid, -INF))
	var gap := PERSIST_INTERVAL_H * (0.75 + 0.5 * NpcHash.unit01(iid, "persist"))
	if absf(abs_h - last) < gap:
		return false
	if _persist_budget <= 0:
		return false
	_persist_budget -= 1
	_last_persist_h[iid] = abs_h
	return true


## World save / exit: write EVERY habitat's snapshot into the graph now, past
## the ≤2×/sim-hour interval and the per-tick budget, and the peak score past
## its debounce. Without it a save could lose up to half a sim-hour of every
## person's needs and morale, and the last few seconds of FUCK YES onsets.
## Whichever tier a camp is in is the one that persists (a light camp's full
## engine is PARKED and stale).
func persist_all_now(model) -> void:
	if model == null:
		return
	var saved_budget := _persist_budget
	_persist_budget = 1 << 20
	for iid in _engines.keys():
		if str(_tiers.get(iid, CrowdFocus.TIER_FULL)) == CrowdFocus.TIER_LIGHT and _cohorts.has(iid):
			continue
		_last_persist_h.erase(iid)
		_maybe_persist(model, str(iid), _engines[iid], _last_abs_h)
	for iid2 in _cohorts.keys():
		if str(_tiers.get(iid2, CrowdFocus.TIER_FULL)) != CrowdFocus.TIER_LIGHT:
			continue
		_last_persist_h.erase(iid2)
		_maybe_persist_light(model, str(iid2), _cohorts[iid2], _last_abs_h)
	_persist_budget = saved_budget
	flush_peak_score()


## Write the peak score (and who is mid-peak) now. Unconditional: the live
## charge moves every tick without flagging a change.
func flush_peak_score() -> void:
	if not _peak_loaded or _peak_path.is_empty():
		return
	_peak_save_due_ms = 0
	peaks.take_changed()
	peaks.save(_peak_path)


func _maybe_persist(model, iid: String, engine: NpcPopulationEngine, abs_h: float) -> void:
	if not _persist_due(iid, abs_h):
		return
	var snap := engine.snapshot(abs_h)
	var store: SiteProjectStore = _project_stores.get(iid)
	var proj_blob: Array = store.serialize() if store != null else []
	# Project records ride the same change gate: their status derives from
	# board state (inside the engine snapshot), and create/pause/cancel all
	# clear _last_persist_h explicitly, so folding them into the blob only
	# has to catch the sync-derived edits.
	var blob := JSON.stringify(snap) + JSON.stringify(proj_blob) \
		+ JSON.stringify(engine.skills.serialize())
	if str(_last_persist_blob.get(iid, "")) == blob:
		return
	_last_persist_blob[iid] = blob
	var item: Dictionary = model.get_item(iid)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["pop_state"] = snap
	# Training progress accrues on the job, and skills are CONFIG — without
	# this ride-along a reload would silently lose every part-trained
	# apprenticeship. Serialize snaps levels to 0.001, so the blob-compare
	# gate above still holds when nothing actually moved.
	if not engine.skills.by_agent.is_empty():
		specs["pop_skills"] = engine.skills.serialize()
	if not proj_blob.is_empty():
		specs["site_projects"] = proj_blob
	else:
		specs.erase("site_projects")
	# How many are still here. `occupants` stays the AUTHORED headcount (editing
	# it deliberately rebuilds the roster), so departures surface separately.
	specs["pop_present"] = engine.agents.size()
	specs["pop_morale"] = snappedf(engine.mean_morale(), 0.01)
	specs["pop_collapse_risk"] = snappedf(engine.collapse_risk(), 0.01)
	model.update_item(iid, {"specs": specs})
