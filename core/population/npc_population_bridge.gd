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
## delegate-helper convention (ARCHITECTURE.md debt #2).

const PERSIST_INTERVAL_H := 0.5   # snapshot into specs.pop_state at most 2x/sim-hour

var _engines: Dictionary = {}          # item_id -> NpcPopulationEngine
var _configured_count: Dictionary = {} # item_id -> int (reconfigure on change)
var _last_persist_h: Dictionary = {}   # item_id -> float abs-hours
var _last_persist_blob: Dictionary = {}  # item_id -> String (change gate)
## Built-in scenes (Soak/Mars) have no TerrainLoader to own the registry —
## fall back to a bridge-owned scene-keyed one so spaces still work there.
var _fallback_registry: SpaceRegistry = null
var _weather_cache: Dictionary = {}
var _weather_hour := -999.0
var _last_abs_h := 0.0

## Navigation (Tier 3). The grid bakes in budgeted slices off the tick; until
## it is ready agents keep walking straight lines, so nothing ever stalls.
var _nav_grid: NpcNavGrid = null
var _nav_query: NpcNavQuery = null
var _nav_fp := ""
var _nav_queries_this_tick := 0
var _model_item_cache: Dictionary = {}   # item_id -> item (for nav anchors)
var _nav_rev := 0            # bumped by callers when geometry moves

## Cold A* queries allowed per tick. Cache hits are unlimited — a site has ~10
## tagged spaces, so after the first day almost every trip is a hit.
const MAX_QUERIES_PER_TICK := 2
## Terrain sampling is the expensive part of the bake, and on scenes with no
## TerrainLoader every sample is a raycast. Keep the slice conservative.
const NAV_CELLS_PER_TICK := 1200
## Region centre/extent are snapped to this before hashing, so a space moving
## a few centimetres does not throw away a finished bake.
const NAV_REGION_SNAP_M := 5.0
## Departure / collapse events for the view to toast, drained each read.
var _pending_events: Array = []


## Step every pop-driven habitat and install demand overrides. Call before
## flow_engine.tick() inside the ambient tick's suppress window.
func tick(model, flow_engine, main: Node) -> void:
	if model == null or flow_engine == null or main == null:
		return
	if not main.has_method("get_absolute_hours"):
		return
	var abs_h: float = float(main.call("get_absolute_hours"))
	_last_abs_h = abs_h
	var hour_of_day: float = fposmod(abs_h, 24.0)
	var registry := _find_registry(main)
	_nav_queries_this_tick = 0
	_service_nav(main, registry)
	var seen: Dictionary = {}

	for item in model.get_items_in_scope("root"):
		var d: Dictionary = item
		if str(d.get("type", "")) != "processor":
			continue
		var specs: Dictionary = d.get("specs", {})
		if str(specs.get("role", "")) != "habitat" or not bool(specs.get("pop_driven", false)):
			continue
		var iid := str(d.get("id", ""))
		seen[iid] = true
		_model_item_cache[iid] = d
		var engine := _ensure_engine(iid, specs, main)
		# Last flow tick's verdict drives this tick's blocked activities.
		engine.set_starved(specs.get("starved_kinds", []) as Array)
		var ctx := {
			"registry": registry,
			"pos_of": func(space: Dictionary) -> Variant:
				return registry.resolve_position(space, main) if registry != null else null,
			"chore_pos_of": func(chore: Dictionary) -> Variant:
				return _chore_position(chore, main, registry),
			"hour_of_day": hour_of_day,
			"weather": _sample_weather(main, hour_of_day),
			"plan_path": func(from_xz: Vector2, to_xz: Vector2, from_key: String,
					to_key: String, lane_seed: int) -> Variant:
				return _plan_path(from_xz, to_xz, from_key, to_key, lane_seed),
		}
		var demand: Dictionary = engine.tick(abs_h, ctx)
		flow_engine.set_habitat_demand(iid, demand)
		_maybe_persist(model, iid, engine, abs_h)

	# Habitats that stopped being pop-driven (toggle off / deleted) fall back
	# to the classic constant-rate model.
	for iid in _engines.keys():
		if not seen.has(str(iid)):
			flow_engine.clear_habitat_demand(str(iid))
			_engines.erase(iid)
			_configured_count.erase(iid)
			_last_persist_h.erase(iid)
			_last_persist_blob.erase(iid)


## Site Plan dot payload across all engines (Phase 4 renderer input).
func agent_dots() -> Array:
	var out: Array = []
	for iid in _engines:
		out.append_array((_engines[iid] as NpcPopulationEngine).agent_dots())
	return out


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
		out.append({
			"pos": p,
			"space_type": str(space.get("space_type", "")),
			"label": str(space.get("label", "")),
			"occupied": reg.occupant_count(sid),
			"capacity": maxi(int(space.get("capacity", SpaceRegistry.DEFAULT_CAPACITY)), 1),
		})
	return out


# --- navigation --------------------------------------------------------------

## Keep the nav grid in step with the world: re-derive its region when the
## tagged spaces move, then feed it ONE budgeted bake slice per tick. Never
## bakes the whole grid inline — see the NpcNavGrid stall-trap note.
func _service_nav(main: Node, registry: SpaceRegistry) -> void:
	if registry == null or main == null:
		return
	var anchors := _nav_anchor_points(main, registry)
	if anchors.size() < 1:
		return
	# The fingerprint must depend ONLY on things that sit still. Folding in
	# live agent positions makes it change every tick, which restarts the bake
	# forever and the grid never becomes ready.
	var lo := anchors[0]
	var hi := anchors[0]
	for p in anchors:
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	var center := ((lo + hi) * 0.5).snapped(Vector2(NAV_REGION_SNAP_M, NAV_REGION_SNAP_M))
	var half := snappedf(maxf(hi.x - lo.x, hi.y - lo.y) * 0.5, NAV_REGION_SNAP_M)
	var fp := NpcNavGrid.compose_fingerprint(
			registry.spaces.size(), _prop_revision(main), _nav_rev, 0, center, half)
	if _nav_grid == null or _nav_grid.needs_rebuild(fp):
		if _nav_fp != fp:
			_nav_fp = fp
			_nav_grid = NpcNavGrid.new()
			if not _nav_grid.configure_for_points(anchors):
				_nav_grid = null
				return
			_nav_grid.begin_bake(
					func(x: float, z: float) -> float:
						return TerrainSurfaceQuery.ground_height_at(main, x, z),
					_collect_nav_obstacles(main), fp)
			if _nav_query == null:
				_nav_query = NpcNavQuery.new()
		if _nav_grid != null and not _nav_grid.is_ready():
			PerfMonitor.begin("npc_nav_bake")
			if _nav_grid.bake_step(NAV_CELLS_PER_TICK):
				_nav_query.setup(_nav_grid)
			PerfMonitor.end("npc_nav_bake")


## Where the population actually operates: every resolvable tagged space plus
## each pop-driven habitat's home. STATIC POINTS ONLY — never live agent
## positions, or the region (and its fingerprint) moves every tick.
func _nav_anchor_points(main: Node, registry: SpaceRegistry) -> PackedVector2Array:
	var out := PackedVector2Array()
	for space in registry.spaces:
		var p: Variant = registry.resolve_position(space, main)
		if p is Vector2:
			out.append(p)
	for iid in _engines:
		var item: Dictionary = _model_item_cache.get(iid, {})
		out.append(_home_pos(item.get("specs", {}) as Dictionary, main))
	return out


## Buildings and still water block; roads are good walking and are left clear.
## 3c refines buildings into wall bands with doors — for now they are solid.
func _collect_nav_obstacles(main: Node) -> Array:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader == null:
		return []
	var out: Array = []
	if loader.has_method("get_osm_buildings"):
		for item in loader.call("get_osm_buildings"):
			if not (item is Dictionary):
				continue
			var pts: Variant = (item as Dictionary).get("points", PackedVector2Array())
			if pts is PackedVector2Array and (pts as PackedVector2Array).size() >= 3:
				out.append({"poly": pts,
					"flags": NpcNavGrid.F_BLOCKED | NpcNavGrid.F_STRUCTURE})
	if loader.has_method("get_still_water_polygons"):
		for poly in loader.call("get_still_water_polygons"):
			out.append({"poly": poly,
				"flags": NpcNavGrid.F_BLOCKED | NpcNavGrid.F_WATER})
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
	var path := _nav_query.path_between_spaces(from_key, to_key, from_xz, to_xz, lane_seed)
	PerfMonitor.end("npc_pathfind")
	if not cached:
		_nav_queries_this_tick += 1
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
	return d


func nav_grid() -> NpcNavGrid:
	return _nav_grid


## Live weather for the productivity/exposure model, cached per tick. Falls
## back to comfortable conditions when WeatherService has no coverage, so an
## offline site never has its work blocked.
func _sample_weather(main: Node, hour_of_day: float) -> Dictionary:
	if absf(hour_of_day - _weather_hour) < 0.25 and not _weather_cache.is_empty():
		return _weather_cache
	var ws := main.get_node_or_null("/root/WeatherService") if main != null else null
	if ws == null or not ws.has_method("sample"):
		_weather_cache = {}
		return _weather_cache
	var clock: Variant = main.get("clock")
	var month := int(main.get("month")) if main.get("month") != null else 6
	var day := int(main.get("day")) if main.get("day") != null else 15
	if clock != null:
		month = int(clock.get("month"))
		day = int(clock.get("day"))
	_weather_cache = {
		"temp_c": float(ws.call("temperature_c", month, day, hour_of_day)),
		"wind_ms": float(ws.call("sample", "wind_speed_10m", month, day, hour_of_day)),
		"rain_mmh": float(ws.call("sample", "precipitation", month, day, hour_of_day)),
	}
	_weather_hour = hour_of_day
	return _weather_cache


## Where a chore's work happens: an explicit space type, a bound prop, or
## (null) wherever the worker already stands.
func _chore_position(chore: Dictionary, main: Node, registry: SpaceRegistry) -> Variant:
	var target: Dictionary = chore.get("target", {})
	match str(target.get("kind", "")):
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
func chore_board_for(item_id: String) -> NpcChoreBoard:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.chore_board if engine != null else null


## Every pop-driven habitat id currently simulated.
func habitat_ids() -> Array:
	return _engines.keys()


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


## Inspector telemetry for one habitat ({} when not simulated yet).
func summary_for(item_id: String) -> Dictionary:
	var engine: NpcPopulationEngine = _engines.get(item_id)
	return engine.summary() if engine != null else {}


func has_engine(item_id: String) -> bool:
	return _engines.has(item_id)


func active() -> bool:
	return not _engines.is_empty()


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
	engine = NpcPopulationEngine.new()
	var snap: Dictionary = specs.get("pop_state", {}) as Dictionary
	if not snap.is_empty() and (snap.get("agents", []) as Array).size() == count:
		engine.restore(snap)
	else:
		engine.configure(count, iid, _home_pos(specs, main))
	# Departures and collapse are narrative events — surface them to the UI.
	engine.agent_departed.connect(
		func(_aid: String, who: String, reason: String) -> void:
			_pending_events.append({
				"kind": "departed", "item_id": iid, "name": who, "reason": reason,
			}))
	engine.collapse_warning.connect(
		func(risk: float) -> void:
			_pending_events.append({"kind": "collapse_warning", "item_id": iid, "risk": risk}))
	engine.colony_collapsed.connect(
		func() -> void:
			_pending_events.append({"kind": "collapsed", "item_id": iid}))
	_engines[iid] = engine
	_configured_count[iid] = count
	return engine


## Drain queued departure / collapse events (the view toasts them).
func take_events() -> Array:
	var out := _pending_events
	_pending_events = []
	return out


## Where the population anchors in world XZ: the habitat's 3D twin when one
## is placed, else the world origin (SoI center).
func _home_pos(specs: Dictionary, main: Node) -> Vector2:
	var pid := str(specs.get("bound_prop_id", ""))
	if not pid.is_empty():
		var rec: Dictionary = PlacedPropService.get_prop_record(main, pid)
		if not rec.is_empty():
			return Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	return Vector2.ZERO


## Change-gated snapshot into specs.pop_state (survives save/load via the
## graph's normal serialize path). Interval + identical-blob gates keep the
## 0.75 s autosave debounce from storming.
func _maybe_persist(model, iid: String, engine: NpcPopulationEngine, abs_h: float) -> void:
	var last := float(_last_persist_h.get(iid, -INF))
	if absf(abs_h - last) < PERSIST_INTERVAL_H:
		return
	_last_persist_h[iid] = abs_h
	var snap := engine.snapshot(abs_h)
	var blob := JSON.stringify(snap)
	if str(_last_persist_blob.get(iid, "")) == blob:
		return
	_last_persist_blob[iid] = blob
	var item: Dictionary = model.get_item(iid)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["pop_state"] = snap
	# How many are still here. `occupants` stays the AUTHORED headcount (editing
	# it deliberately rebuilds the roster), so departures surface separately.
	specs["pop_present"] = engine.agents.size()
	specs["pop_morale"] = snappedf(engine.mean_morale(), 0.01)
	specs["pop_collapse_risk"] = snappedf(engine.collapse_risk(), 0.01)
	model.update_item(iid, {"specs": specs})
