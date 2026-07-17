class_name ResourceFlowEngine
extends RefCounted

## Simulates multi-resource flow through graph processors and catchment nodes.
## Tank levels are reversible via ResourceTimeline (scrub-safe like battery SOC).
##
## Habitat nodes (`specs.role == "habitat"`) are always-on demand sinks: per-
## occupant input rates debit supply tanks; waste outputs are stoichiometric
## fractions of *actual* consumption (never invent mass). Empty inputs set
## `specs.starved_kinds` for HUD / challenge consumers.

const ResourceTimelineScript := preload("res://core/resource_timeline.gd")
const PbiBiomassScript := preload("res://system_graph/pbi_biomass.gd")
const PlantGrowthScript := preload("res://system_graph/plant_growth.gd")
const AtmospherePbiScript := preload("res://system_graph/atmosphere_pbi.gd")

## Emitted when any habitat's starved_kinds set changes (empty = all fed).
signal habitat_starvation_changed(item_id: String, starved_kinds: Array)

## Emitted when a tank transitions into/out of overflow (full while inflow > outflow).
signal tank_overflow_changed(item_id: String, overflowing: bool)

## Emitted when a processor blocks due to missing inputs (emitted once per transition)
signal processor_blocked(item_id: String, resource_kinds: Array)

## Unified per-node state edge signal (running/idle/blocked/starved/overflow/fault).
## Fires only on transition; see GraphNodeState for the vocabulary.
signal node_state_changed(item_id: String, state: String, reason: String, kinds: Array)

## Potable → greywater / blackwater split (mass-conserving).
## Domestic wastewater split is typically ~70–90% grey / ~10–30% black;
## 80/20 is a standard first-order CELSS / household bookkeeping split.
const HABITAT_GREYWATER_YIELD := 0.80
const HABITAT_BLACKWATER_YIELD := 0.20
## Food scraps / inedible fraction → biomass (~20% kitchen waste fraction).
const HABITAT_FOOD_SCRAP_YIELD := 0.20

## Power-availability override for selftests / diagnostics:
## -1 = auto (query AcPowerBus / SolarUI), 0 = force unpowered, 1 = force powered.
## Override 1 bypasses only bus availability — wiring checks stay active.
var power_available_override: int = -1

## Rain-rate override for selftests (mm/h). Negative = use WeatherService.
var rain_rate_override_mmh: float = -1.0

## Connector-loss override for selftests: -1 = auto (SimSettingsController),
## 0 = force off, 1 = force on. (Wave 8 hydraulic derate in JIT transfers.)
var connector_losses_override: int = -1

## Sunlight GHI override for selftests (W/m²). Negative = compute from real
## sun position (SolarIrradiance/SolarPosition) + WeatherService, falling
## back to clear-sky geometry when there is no weather coverage.
var sun_ghi_override_wm2: float = -1.0

## Cloud-fraction override for selftests (0–1). Negative = sample WeatherService.
var sun_cloud_override: float = -1.0

## SoI area override for selftests (m²). Negative = use SoiService.area_m2().
var soi_area_override_m2: float = -1.0

## Atmosphere overrides for Wind PBI selftests. Negative = sample WeatherService.
var wind_speed_override_ms: float = -1.0
var wind_temp_override_c: float = -999.0
var wind_humidity_override_pct: float = -1.0
var wind_cloud_override: float = -1.0
var wind_rain_override_mmh: float = -1.0

## Batch-render context. When active, weather (rain/month) is sampled at
## `_render_abs_hours` instead of the live clock so the resource sim becomes a
## pure function of absolute time (deterministic, reproducible pre-render + scrub).
var _render_ctx_active: bool = false
var _render_abs_hours: float = 0.0

## migrate_resource_specs/migrate_processor_specs are stateless instance
## methods — one shared instance avoids a RefCounted allocation per item per
## tick (previously ResourceKinds.new() at every call site below).
var _rk := ResourceKinds.new()

var _model: GraphModel = null
var _host: Node = null
var _timelines: Dictionary = {}   # item_id -> ResourceTimeline
var _last_abs_hours: float = -1.0
var _tick_accum: float = 0.0
const TICK_INTERVAL := 0.25

## conn_id -> {rate, active} cached for wire animation
var _conn_flow: Dictionary = {}

## processor_id -> { "state": String, "elapsed": float, "penalty_qty": float }
var _processor_states: Dictionary = {}

## Per-tick adjacency index, rebuilt once at the top of _simulate_step() by
## _rebuild_conn_index(). Resolving a processor's I/O ports used to re-scan
## every connection in the graph per port (_tank_at_port /
## _connections_to_handle / _connections_from_handle each looped
## _model.connections) — O(items × connections) per tick. These dictionaries
## turn that into O(1) lookups; the Dictionary values are references to the
## same connection Dictionaries stored in _model.connections (Godot
## Dictionaries are reference types), so callers can still mutate them in
## place (e.g. _cache_conn_flow's flow_rate/flow_active writeback).
var _conn_by_source: Dictionary = {}          # "item_id|handle_id" -> Array[Dictionary]
var _conn_by_target: Dictionary = {}          # "item_id|handle_id" -> Array[Dictionary]
## Any resource-polarity connection touching an item on that side (any
## handle) — for the "any resource edge on this item" fallback scans.
var _resource_conns_by_source_item: Dictionary = {}  # item_id -> Array[Dictionary]
var _resource_conns_by_target_item: Dictionary = {}  # item_id -> Array[Dictionary]
## conn_id -> Dictionary reference, for _cache_conn_flow's writeback (was a
## full _model.connections re-scan by id on every call).
var _conn_by_id: Dictionary = {}


## Rebuilds every adjacency index above from _model.connections. O(connections)
## once per tick, replacing what used to be an O(connections) scan PER PORT
## LOOKUP (of which a single processor tick can do several).
func _rebuild_conn_index() -> void:
	_conn_by_source.clear()
	_conn_by_target.clear()
	_resource_conns_by_source_item.clear()
	_resource_conns_by_target_item.clear()
	_conn_by_id.clear()
	if _model == null:
		return
	for conn: Dictionary in _model.connections:
		var cid := str(conn.get("id", ""))
		if not cid.is_empty():
			_conn_by_id[cid] = conn
		var sid := str(conn.get("source_item_id", ""))
		var shid := str(conn.get("source_handle_id", ""))
		var tid := str(conn.get("target_item_id", ""))
		var thid := str(conn.get("target_handle_id", ""))
		var is_resource := str(conn.get("polarity", "")) == "resource"
		if not sid.is_empty():
			var skey := sid + "|" + shid
			if not _conn_by_source.has(skey):
				_conn_by_source[skey] = []
			(_conn_by_source[skey] as Array).append(conn)
			if is_resource:
				if not _resource_conns_by_source_item.has(sid):
					_resource_conns_by_source_item[sid] = []
				(_resource_conns_by_source_item[sid] as Array).append(conn)
		if not tid.is_empty():
			var tkey := tid + "|" + thid
			if not _conn_by_target.has(tkey):
				_conn_by_target[tkey] = []
			(_conn_by_target[tkey] as Array).append(conn)
			if is_resource:
				if not _resource_conns_by_target_item.has(tid):
					_resource_conns_by_target_item[tid] = []
				(_resource_conns_by_target_item[tid] as Array).append(conn)


func setup(model: GraphModel, host: Node) -> void:
	_model = model
	_host = host
	_timelines.clear()
	_conn_flow.clear()
	_processor_states.clear()
	_last_abs_hours = -1.0


func clear_timelines() -> void:
	_timelines.clear()
	_conn_flow.clear()
	_processor_states.clear()
	_last_abs_hours = -1.0


## Test / challenge helper: advance resource sim by dt_hours at abs_hours.
func simulate_step_for_test(abs_hours: float, dt_hours: float) -> void:
	if _model == null:
		return
	_ensure_timelines_at(abs_hours)
	if dt_hours > 0.0:
		_simulate_step(abs_hours, dt_hours)
	_last_abs_hours = abs_hours


## Deterministic batch-render step: advance the resource sim one micro-step at
## `abs_hours` as a PURE function of time. Weather is sampled at `abs_hours` and
## AC availability is injected (from the co-rendered battery SOC), so a
## pre-render or forward-scrub reproduces the live curve exactly. Restores the
## live power override afterward so it never leaks into the live tick.
func render_step(abs_hours: float, dt_hours: float, ac_available: bool) -> void:
	if _model == null:
		return
	var prev_override := power_available_override
	_render_ctx_active = true
	_render_abs_hours = abs_hours
	power_available_override = 1 if ac_available else 0
	_ensure_timelines_at(abs_hours)
	if dt_hours > 0.0:
		_simulate_step(abs_hours, dt_hours)
	_last_abs_hours = abs_hours
	power_available_override = prev_override
	_render_ctx_active = false


## Re-read every tank at `abs_hours` from its reversible timeline (scrub read).
## Public wrapper for the shared scrub cursor.
func seek_all_tanks(abs_hours: float) -> void:
	if _model == null:
		return
	_ensure_timelines_at(abs_hours)
	_read_all_tanks_at(abs_hours)
	_last_abs_hours = abs_hours


func tick(delta: float) -> void:
	if _model == null or _host == null:
		return
	_tick_accum += delta
	if _tick_accum < TICK_INTERVAL:
		return
	_tick_accum = 0.0

	var abs_hours := _get_abs_hours()
	if abs_hours < 0.0:
		return

	_conn_flow.clear()
	if _model != null:
		for conn: Dictionary in _model.connections:
			conn["flow_active"] = false
			conn["flow_rate"] = 0.0
	_ensure_timelines()

	var dt_hours := abs_hours - _last_abs_hours if _last_abs_hours >= 0.0 else 0.0
	var scrubbing_back := _last_abs_hours >= 0.0 and abs_hours < _last_abs_hours - 1e-6

	if scrubbing_back:
		_read_all_tanks_at(abs_hours)
	else:
		if dt_hours > 0.0:
			_simulate_step(abs_hours, dt_hours)
		else:
			_read_all_tanks_at(abs_hours)

	_last_abs_hours = abs_hours


func _get_abs_hours() -> float:
	if _host == null or not _host.has_method("_get_scene_main_node"):
		return -1.0
	var main_node: Node = _host.call("_get_scene_main_node")
	if main_node == null:
		return -1.0
	if main_node.has_method("get_absolute_hours"):
		return float(main_node.call("get_absolute_hours"))
	if "clock" in main_node and main_node.clock != null and main_node.clock.has_method("get_absolute_hours"):
		return float(main_node.clock.get_absolute_hours())
	return -1.0


## Containers may opt out of physical capacity enforcement ("conceptual"
## containers) via specs.unlimited_capacity — modeled as a very large capacity
## for ResourceTimeline integration. Call sites that gate on "full" / overflow
## MUST use _tank_is_unlimited / _tank_accepts_inflow — the 1e12 sentinel alone
## is not enough (level can eventually hit 0.999 and block processors).
const UNLIMITED_CAPACITY_QTY := 1.0e12


func _effective_capacity_qty(specs: Dictionary) -> float:
	if _tank_is_unlimited(specs):
		return UNLIMITED_CAPACITY_QTY
	return float(specs.get("capacity_qty", 100.0))


func _tank_is_unlimited(specs: Dictionary) -> bool:
	return bool(specs.get("unlimited_capacity", false))


## True when a tank can accept more inflow at abs_h (valves + fill headroom).
## Unlimited / conceptual tanks always accept when the input valve is open.
func _tank_accepts_inflow(specs: Dictionary, tl: ResourceTimeline, abs_h: float) -> bool:
	if not bool(specs.get("input_valve_open", true)):
		return false
	if _tank_is_unlimited(specs):
		return true
	if bool(specs.get("allow_negative", false)):
		# Deficit tanks are supply-side; they can still accept credits.
		return true
	if tl == null:
		return false
	return tl.level_at(abs_h) < 0.999


## True when a tank can supply outflow at abs_h (valve + stock).
## allow_negative (deficit) tanks never starve their consumers.
func _tank_has_supply(specs: Dictionary, tl: ResourceTimeline, abs_h: float) -> bool:
	if not bool(specs.get("output_valve_open", true)):
		return false
	if bool(specs.get("allow_negative", false)):
		return true
	if tl == null:
		return false
	return tl.level_at(abs_h) > 0.001


func _ensure_timelines() -> void:
	_ensure_timelines_at(_get_abs_hours())


func _ensure_timelines_at(abs_hours: float) -> void:
	var live_ids: Dictionary = {}
	var anchor_h: float = abs_hours if abs_hours >= 0.0 else 0.0
	for item: Dictionary in _model.items:
		if str(item.get("type", "")) != "resource":
			continue
		var iid: String = str(item.get("id", ""))
		if iid.is_empty():
			continue
		live_ids[iid] = true
		if _timelines.has(iid):
			continue
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		_rk.migrate_resource_specs(specs)
		# Deficit-capable ("allow_negative") tanks track an unbounded net stock
		# directly on specs.level instead of a clamped ResourceTimeline — see
		# the integration branch in _simulate_step.
		if bool(specs.get("allow_negative", false)):
			continue
		var tl := ResourceTimelineScript.new()
		tl.configure(_effective_capacity_qty(specs))
		tl.init_anchor(anchor_h, float(specs.get("level", 0.5)))
		_timelines[iid] = tl

	for iid: String in _timelines.keys():
		if not live_ids.has(iid):
			_timelines.erase(iid)


func _read_all_tanks_at(abs_hours: float) -> void:
	for item: Dictionary in _model.items:
		if str(item.get("type", "")) != "resource":
			continue
		var iid: String = str(item.get("id", ""))
		if not _timelines.has(iid):
			continue
		var tl: ResourceTimeline = _timelines[iid] as ResourceTimeline
		var sample := tl.seek(abs_hours)
		_apply_tank_sample(item, sample, tl, abs_hours)


func _apply_tank_sample(item: Dictionary, sample: Dictionary,
		tl: ResourceTimeline = null, abs_hours: float = -1.0) -> void:
	var orig_specs: Dictionary = item.get("specs", {}) as Dictionary
	var specs: Dictionary = orig_specs.duplicate(true)
	specs["level"] = float(sample.get("level", specs.get("level", 0.0)))
	specs["inflow_rate"] = float(sample.get("inflow_rate", 0.0))
	specs["outflow_rate"] = float(sample.get("outflow_rate", 0.0))
	var iid := str(item.get("id", ""))
	var overflow_flip := false
	var over := false
	var prev_state := str(specs.get("node_state", ""))
	if tl != null and abs_hours >= 0.0:
		# Conceptual / unlimited tanks never overflow — inflow is always kept.
		if _tank_is_unlimited(specs):
			over = false
			specs["overflowing"] = false
			specs["overflow_qty"] = 0.0
		else:
			over = tl.is_overflowing_at(abs_hours)
			overflow_flip = over != bool(specs.get("overflowing", false))
			specs["overflowing"] = over
			specs["overflow_qty"] = tl.total_overflow_qty
	# Tanks carry an OVERFLOW node state (drives the shared alert overlay); no
	# state otherwise (nominal — level fill speaks for itself).
	var new_state := GraphNodeState.OVERFLOW if over else ""
	specs["node_state"] = new_state
	if new_state != prev_state:
		specs["node_state_reason"] = GraphNodeState.REASON_TANK_FULL if over else ""
		specs["node_state_kinds"] = []

	# Skip the model write (and the redraw/telemetry cascade it triggers) when
	# nothing the UI actually reads has moved beyond float noise — an idle
	# tank's level/rates are unchanged tick to tick. The sample/overflow
	# computation above still runs every tick either way; this only gates the
	# write, mirroring _tick_graph_renewables' change-gated update_item.
	const EPS := 0.0005
	var value_changed := new_state != prev_state \
		or absf(float(specs.get("level", 0.0)) - float(orig_specs.get("level", 0.0))) > EPS \
		or absf(float(specs.get("inflow_rate", 0.0)) - float(orig_specs.get("inflow_rate", 0.0))) > EPS \
		or absf(float(specs.get("outflow_rate", 0.0)) - float(orig_specs.get("outflow_rate", 0.0))) > EPS \
		or bool(specs.get("overflowing", false)) != bool(orig_specs.get("overflowing", false)) \
		or absf(float(specs.get("overflow_qty", 0.0)) - float(orig_specs.get("overflow_qty", 0.0))) > EPS
	if value_changed:
		_model.update_item(iid, {"specs": specs})
	if new_state != prev_state:
		node_state_changed.emit(iid, new_state, str(specs.get("node_state_reason", "")), [])
	if overflow_flip:
		tank_overflow_changed.emit(iid, over)


## Deficit-capable ("allow_negative") tanks skip the clamped ResourceTimeline
## entirely and just integrate net rate straight onto specs.level, unbounded —
## going negative shows a deficit (drawn as a red "backordered" indicator by
## the canvas) without ever blocking whatever is drawing from it.
func _integrate_deficit_tank(iid: String, specs: Dictionary,
		net_rates: Dictionary, dt_hours: float) -> void:
	var cap: float = maxf(float(specs.get("capacity_qty", 100.0)), 0.001)
	var net: float = float(net_rates.get(iid, 0.0))
	var level: float = float(specs.get("level", 0.0)) + (net * dt_hours) / cap
	specs["level"] = level
	specs["inflow_rate"] = maxf(net, 0.0)
	specs["outflow_rate"] = maxf(-net, 0.0)
	specs["overflowing"] = false
	specs["deficit_qty"] = maxf(-level, 0.0) * cap
	specs["node_state"] = ""
	_model.update_item(iid, {"specs": specs})


func _simulate_step(abs_hours: float, dt_hours: float) -> void:
	_rebuild_conn_index()
	# Per-tank net rates (qty/hour in tank's capacity units)
	var net_rates: Dictionary = {}

	for item: Dictionary in _model.items:
		var ty: String = str(item.get("type", ""))
		if ty == "pbi":
			_process_pbi(item, abs_hours)
		elif ty == "catchment":
			_process_catchment(item, net_rates, dt_hours, abs_hours)
		elif ty == "processor":
			_process_processor(item, net_rates, dt_hours, abs_hours)
		elif ty == "plant":
			_process_plant(item, net_rates, dt_hours, abs_hours)

	_process_jit_transfers(net_rates, dt_hours, abs_hours)

	# Integrate timelines
	for item: Dictionary in _model.items:
		if str(item.get("type", "")) != "resource":
			continue
		var iid: String = str(item.get("id", ""))
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		_rk.migrate_resource_specs(specs)
		if bool(specs.get("allow_negative", false)):
			_integrate_deficit_tank(iid, specs, net_rates, dt_hours)
			continue
		if not _timelines.has(iid):
			continue
		var tl: ResourceTimeline = _timelines[iid] as ResourceTimeline
		tl.configure(_effective_capacity_qty(specs))
		var net: float = float(net_rates.get(iid, 0.0))
		var infl: float = maxf(net, 0.0)
		var outf: float = maxf(-net, 0.0)
		tl.record_step(abs_hours, net, infl, outf)
		var sample := tl.sample_at(abs_hours)
		_apply_tank_sample(item, sample, tl, abs_hours)


## Rain / Sunlight / Wind PBI: environment-driven telemetry + optional wire viz.
## Does not credit tanks directly — catchments / turbines / plants consume ambiently.
## Never counts as an import (local Planetary Basic Income).
func _process_pbi(item: Dictionary, _abs_hours: float) -> void:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var kind := ResourceKinds.normalize_kind(str(specs.get("resource_kind", "water")))
	if kind == "sunlight" or kind == "solar":
		_process_sun_pbi(item, specs)
		return
	if kind == "wind" or kind == "atmosphere" or kind == "air" or kind == "mechanical":
		_process_wind_pbi(item, specs)
		return
	# Rain/water PBI
	if kind != "water" and kind != "rain":
		return
	var rain_mmh := _rain_rate_mmh()
	var area_m2 := _soi_area_m2()
	var total_lph: float = maxf(area_m2, 0.0) * maxf(rain_mmh, 0.0)
	specs["live_capture_lph"] = total_lph
	specs["display_value"] = "%.0f L/h" % total_lph if total_lph > 0.0 else "0 L/h"
	specs["is_active"] = rain_mmh > 0.0
	var iid := str(item.get("id", ""))
	_model.update_item(iid, {"specs": specs})
	# Animate outbound wires to catchments at the SoI total rate (informational).
	if total_lph <= 0.0:
		return
	for conn: Dictionary in (_resource_conns_by_source_item.get(iid, []) as Array):
		_cache_conn_flow(str(conn.get("id", "")), total_lph, "water")


## Solar PBI: GHI (W/m²) × SoI area (m²) = total flux (kW), plus a normalized
## `sun_availability` (0–~1.2, 1.0 ≈ STC) that receivers (panels, plants —
## Phase 3+) read to modulate their own output whether or not an optional
## radiant wire is drawn from this node. Ambient, non-blocking by design —
## sunlight is not delivered through a conduit in real life.
func _process_sun_pbi(item: Dictionary, specs: Dictionary) -> void:
	var ghi := _sun_ghi_wm2()
	var area_m2 := _soi_area_m2()
	var flux_kw: float = SolarIrradiance.flux_kw_from_ghi(ghi, area_m2)
	specs["irradiance_wm2"] = ghi
	specs["flux_kw"] = flux_kw
	specs["sun_availability"] = SolarIrradiance.sun_availability(ghi)
	specs["cloud_frac"] = _sun_cloud_frac()
	specs["display_value"] = SolarIrradiance.pbi_display_string(ghi, flux_kw)
	specs["is_active"] = ghi > 1.0
	var iid := str(item.get("id", ""))
	_model.update_item(iid, {"specs": specs})
	# Animate outbound (optional) radiant wires at the SoI total flux — informational.
	if flux_kw <= 0.0:
		return
	for conn: Dictionary in (_resource_conns_by_source_item.get(iid, []) as Array):
		_cache_conn_flow(str(conn.get("id", "")), flux_kw, "sunlight")


## Wind / atmosphere PBI: live weather (wind, temp, RH) + educational kinetic
## flux through a SoI-wide vertical slab. Turbines already read WeatherService
## ambiently — optional dashed wires are documentary only.
func _process_wind_pbi(item: Dictionary, specs: Dictionary) -> void:
	var sample := _atmosphere_sample()
	var wind_ms: float = float(sample.get("wind_ms", 0.0))
	var temp_c: float = float(sample.get("temp_c", 20.0))
	var humidity: float = float(sample.get("humidity_pct", 50.0))
	var cloud: float = float(sample.get("cloud_frac", 0.0))
	var rain: float = float(sample.get("rain_mmh", 0.0))
	var area_m2 := _soi_area_m2()
	var kinetic_kw: float = AtmospherePbiScript.kinetic_flux_kw(wind_ms, area_m2)
	specs["wind_ms"] = wind_ms
	specs["temp_c"] = temp_c
	specs["humidity_pct"] = humidity
	specs["cloud_frac"] = cloud
	specs["rain_mmh"] = rain
	specs["kinetic_kw"] = kinetic_kw
	specs["weather_class"] = AtmospherePbiScript.weather_visual_class(cloud, rain)
	specs["display_value"] = AtmospherePbiScript.pbi_display_string(wind_ms, temp_c, humidity)
	specs["is_active"] = wind_ms > 0.5 or rain > 0.05 or cloud > 0.05
	var iid := str(item.get("id", ""))
	_model.update_item(iid, {"specs": specs})
	if kinetic_kw <= 0.0:
		return
	for conn: Dictionary in (_resource_conns_by_source_item.get(iid, []) as Array):
		_cache_conn_flow(str(conn.get("id", "")), kinetic_kw, "wind")


## Grow-bed / plant node: Monteith LUE biomass from ambient PAR (non-blocking
## sunlight — same SoI GHI whether or not a radiant wire is drawn), gated by
## wired water (required) and optional nutrients. Credits a biomass tank.
## Biomass is a downstream consequence of sunlight — not a separate PBI.
func _process_plant(item: Dictionary, net_rates: Dictionary, dt_hours: float,
		abs_hours: float = -1.0) -> void:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var iid := str(item.get("id", ""))
	var abs_h: float = abs_hours if abs_hours >= 0.0 else _get_abs_hours()
	if abs_h < 0.0:
		abs_h = 0.0

	var ghi := _sun_ghi_wm2()
	var par := SolarIrradiance.par_wm2_from_ghi(ghi)
	var area := PlantGrowthScript.effective_area_m2(specs, _soi_area_m2())
	var sun_f := PlantGrowthScript.sunlight_factor_from_specs(specs)
	var lue := PlantGrowthScript.lue_from_specs(specs)
	var month := _sim_month()
	var potential := PlantGrowthScript.potential_biomass_kg_h(par, area, lue, month) * sun_f

	specs["irradiance_wm2"] = ghi
	specs["par_wm2"] = par
	specs["sunlight_factor"] = sun_f
	specs["area_m2_effective"] = area

	# --- Water (required, blocking) ---
	var water_id := _tank_at_port(iid, "water_in", true)
	var water_factor := 0.0
	var water_specs: Dictionary = {}
	var water_tl: ResourceTimeline = null
	if water_id.is_empty():
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "needs water"
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_EMPTY_INPUT, ["water"])
		_model.update_item(iid, {"specs": specs})
		return
	var water_item := _model.get_item(water_id)
	water_specs = (water_item.get("specs", {}) as Dictionary).duplicate(true)
	_rk.migrate_resource_specs(water_specs)
	water_tl = _timelines.get(water_id) as ResourceTimeline
	var water_ok: bool = _tank_has_supply(water_specs, water_tl, abs_h) \
			or (water_tl == null and bool(water_specs.get("allow_negative", false)))
	if not water_ok:
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "no water"
		_write_node_state(iid, specs, GraphNodeState.STARVED,
				GraphNodeState.REASON_EMPTY_INPUT, ["water"])
		_model.update_item(iid, {"specs": specs})
		return
	water_factor = 1.0

	# --- Nutrients (optional; if wired, depleting blocks) ---
	var nutrient_id := _tank_at_port(iid, "nutrients_in", true)
	var nutrient_factor := 1.0
	var nutrient_specs: Dictionary = {}
	var nutrient_tl: ResourceTimeline = null
	var nutrients_wired := not nutrient_id.is_empty()
	if nutrients_wired:
		var nut_item := _model.get_item(nutrient_id)
		nutrient_specs = (nut_item.get("specs", {}) as Dictionary).duplicate(true)
		_rk.migrate_resource_specs(nutrient_specs)
		nutrient_tl = _timelines.get(nutrient_id) as ResourceTimeline
		var nut_ok: bool = _tank_has_supply(nutrient_specs, nutrient_tl, abs_h) \
				or (nutrient_tl == null and bool(nutrient_specs.get("allow_negative", false)))
		if not nut_ok:
			specs["biomass_kg_h"] = 0.0
			specs["display_value"] = "no nutrients"
			_write_node_state(iid, specs, GraphNodeState.STARVED,
					GraphNodeState.REASON_EMPTY_INPUT, ["nutrients"])
			_model.update_item(iid, {"specs": specs})
			return

	# --- Biomass output tank (required) ---
	var bio_id := _tank_at_port(iid, "biomass_out", false)
	if bio_id.is_empty():
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "unwired out"
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_OUTPUT_UNWIRED, ["biomass"])
		_model.update_item(iid, {"specs": specs})
		return
	var bio_item := _model.get_item(bio_id)
	var bio_specs: Dictionary = (bio_item.get("specs", {}) as Dictionary).duplicate(true)
	_rk.migrate_resource_specs(bio_specs)
	if ResourceKinds.normalize_kind(str(bio_specs.get("resource_kind", ""))) != "biomass":
		# Allow any tank but prefer biomass; still credit if kind mismatches
		# only when the tank is biomass (strict).
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "need biomass tank"
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_OUTPUT_UNWIRED, ["biomass"])
		_model.update_item(iid, {"specs": specs})
		return
	var bio_tl: ResourceTimeline = _timelines.get(bio_id) as ResourceTimeline
	if not bool(bio_specs.get("input_valve_open", true)):
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "out closed"
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_OUTPUT_UNWIRED, ["biomass"])
		_model.update_item(iid, {"specs": specs})
		return
	if not _tank_accepts_inflow(bio_specs, bio_tl, abs_h):
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "tank full"
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_OUTPUT_FULL, ["biomass"])
		_model.update_item(iid, {"specs": specs})
		return

	var rate := PlantGrowthScript.biomass_kg_per_hour(
			par, area, lue, month, water_factor, nutrient_factor, sun_f)
	# Cap by remaining biomass headroom so we don't overflow.
	if not _tank_is_unlimited(bio_specs) and dt_hours > 0.001:
		var lvl: float = bio_tl.level_at(abs_h) if bio_tl != null else float(bio_specs.get("level", 0.0))
		var cap: float = maxf(_effective_capacity_qty(bio_specs), 0.001)
		var headroom: float = maxf(0.998 - lvl, 0.0) * cap
		rate = minf(rate, headroom / dt_hours)

	if rate <= 0.0 or potential <= 0.0:
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "0 kg/h" if ghi <= 1.0 else "idle"
		_write_node_state(iid, specs, GraphNodeState.IDLE)
		_model.update_item(iid, {"specs": specs})
		return

	var water_lph := PlantGrowthScript.water_demand_lph(
			rate, PlantGrowthScript.water_l_per_kg_from_specs(specs))
	var nut_kgph := 0.0
	if nutrients_wired:
		nut_kgph = PlantGrowthScript.nutrient_demand_kgph(
				rate, PlantGrowthScript.nutrient_kg_per_kg_from_specs(specs))

	# Apply rates
	net_rates[water_id] = float(net_rates.get(water_id, 0.0)) - water_lph
	if nutrients_wired and nut_kgph > 0.0:
		net_rates[nutrient_id] = float(net_rates.get(nutrient_id, 0.0)) - nut_kgph
	net_rates[bio_id] = float(net_rates.get(bio_id, 0.0)) + rate

	# Wire animation
	for conn: Dictionary in (_resource_conns_by_target_item.get(iid, []) as Array):
		var src := _model.get_item(str(conn.get("source_item_id", "")))
		if src.is_empty():
			continue
		var rk := ResourceKinds.normalize_kind(str(conn.get("resource_type", "")))
		if rk.is_empty():
			rk = ResourceKinds.normalize_kind(str(
					(src.get("specs", {}) as Dictionary).get("resource_kind", "")))
		if rk == "water":
			_cache_conn_flow(str(conn.get("id", "")), water_lph, "water")
		elif rk == "nutrients":
			_cache_conn_flow(str(conn.get("id", "")), nut_kgph, "nutrients")
		elif rk == "sunlight":
			# Radiant wire is informational — animate at PAR×area (kW of PAR).
			_cache_conn_flow(str(conn.get("id", "")), par * area / 1000.0, "sunlight")
	for conn: Dictionary in (_resource_conns_by_source_item.get(iid, []) as Array):
		_cache_conn_flow(str(conn.get("id", "")), rate, "biomass")

	specs["biomass_kg_h"] = rate
	specs["water_lph"] = water_lph
	specs["nutrient_kgph"] = nut_kgph
	if rate >= 0.01:
		specs["display_value"] = "%.2f kg/h" % rate
	else:
		specs["display_value"] = "%.1f g/h" % (rate * 1000.0)
	_write_node_state(iid, specs, GraphNodeState.RUNNING)
	_model.update_item(iid, {"specs": specs})


func _process_catchment(item: Dictionary, net_rates: Dictionary, dt_hours: float,
		abs_hours: float = -1.0) -> void:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var kind := str(specs.get("catchment_kind", "rain"))
	if kind == "biomass":
		_process_biomass_catchment(item, specs, net_rates, dt_hours, abs_hours)
		return
	# Rain catchments require an inbound wire from a Rain PBI node.
	if not _catchment_has_pbi_feed(item, "water"):
		specs["live_capture_lph"] = 0.0
		_model.update_item(str(item.get("id", "")), {"specs": specs})
		return
	var area_m2: float = _catchment_area_m2(specs)
	var runoff: float = float(specs.get("runoff_coeff", 0.85))
	var rain_mmh := _rain_rate_mmh()
	# mm/h * m² = L/h (1 mm on 1 m² = 1 L)
	var capture_lph: float = area_m2 * runoff * maxf(rain_mmh, 0.0)
	specs["live_capture_lph"] = capture_lph
	_model.update_item(str(item.get("id", "")), {"specs": specs})
	if capture_lph <= 0.0:
		return
	var abs_h: float = abs_hours if abs_hours >= 0.0 else _get_abs_hours()
	if abs_h < 0.0:
		abs_h = 0.0
	_credit_catchment_flow(item, net_rates, capture_lph, "water", dt_hours, abs_h)


func _process_biomass_catchment(item: Dictionary, specs: Dictionary,
		net_rates: Dictionary, dt_hours: float = 0.0,
		abs_hours: float = -1.0) -> void:
	var area_m2: float = _catchment_area_m2(specs)
	if area_m2 <= 0.0:
		specs["live_capture_lph"] = 0.0
		_model.update_item(str(item.get("id", "")), {"specs": specs})
		return
	var month := _sim_month()
	var capture_kg_h: float = PbiBiomassScript.biomass_kg_per_hour(area_m2, month)
	specs["live_capture_lph"] = capture_kg_h
	_model.update_item(str(item.get("id", "")), {"specs": specs})
	if capture_kg_h <= 0.0:
		return
	var abs_h: float = abs_hours if abs_hours >= 0.0 else _get_abs_hours()
	if abs_h < 0.0:
		abs_h = 0.0
	_credit_catchment_flow(item, net_rates, capture_kg_h, "biomass", dt_hours, abs_h)


## True when a catchment has an inbound resource edge from a matching PBI node.
func _catchment_has_pbi_feed(item: Dictionary, want_kind: String) -> bool:
	var iid := str(item.get("id", ""))
	for conn: Dictionary in (_resource_conns_by_target_item.get(iid, []) as Array):
		var src := _model.get_item(str(conn.get("source_item_id", "")))
		if src.is_empty() or str(src.get("type", "")) != "pbi":
			continue
		var src_specs: Dictionary = src.get("specs", {}) as Dictionary
		var pk := ResourceKinds.normalize_kind(str(src_specs.get("resource_kind", "water")))
		if want_kind == "water" and (pk == "water" or pk == "rain"):
			return true
		if pk == want_kind:
			return true
	return false


func _catchment_area_m2(specs: Dictionary) -> float:
	var soi_area := _soi_area_m2()
	return PbiBiomassScript.effective_area_m2(specs, soi_area)


func _soi_area_m2() -> float:
	if soi_area_override_m2 >= 0.0:
		return soi_area_override_m2
	if _host == null:
		return 0.0
	var tree: SceneTree = _host.get_tree()
	if tree == null:
		return 0.0
	var soi: Node = tree.root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("area_m2"):
		return float(soi.call("area_m2"))
	return 0.0


func _sim_month() -> int:
	if _render_ctx_active:
		var d := _date_at_render()
		if not d.is_empty():
			return int(d.get("month", 6))
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return 6
	return int(main_node.get("month")) if main_node.get("month") != null else 6


## Calendar date for the current render instant (via the world clock's pure
## abs-hours→date helper). Empty when unavailable.
func _date_at_render() -> Dictionary:
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return {}
	var clock: Object = main_node.get("clock")
	if clock != null and clock.has_method("abs_hours_to_date"):
		return clock.call("abs_hours_to_date", _render_abs_hours)
	return {}


func _credit_catchment_flow(item: Dictionary, net_rates: Dictionary,
		rate: float, want_kind: String, dt_hours: float = 0.0,
		abs_h: float = 0.0) -> void:
	var iid := str(item.get("id", ""))
	# Collect accepting same-kind tanks first so multi-tank wires split equally
	# (one catchment must not multiply volume by wiring N tanks).
	var targets: Array = []  # {conn, tgt_id, specs, tl}
	for conn: Dictionary in (_resource_conns_by_source_item.get(iid, []) as Array):
		var tgt_id: String = str(conn.get("target_item_id", ""))
		var tgt := _model.get_item(tgt_id)
		if tgt.is_empty() or str(tgt.get("type", "")) != "resource":
			continue
		var tgt_specs: Dictionary = (tgt.get("specs", {}) as Dictionary).duplicate(true)
		_rk.migrate_resource_specs(tgt_specs)
		if str(tgt_specs.get("resource_kind", "")) != want_kind:
			continue
		var tl: ResourceTimeline = _timelines.get(tgt_id) as ResourceTimeline
		if not _tank_accepts_inflow(tgt_specs, tl, abs_h):
			_cache_conn_flow(str(conn.get("id", "")), 0.0, want_kind)
			continue
		targets.append({
			"conn": conn, "tgt_id": tgt_id, "specs": tgt_specs, "tl": tl,
		})
	if targets.is_empty() or rate <= 0.0:
		return
	var share: float = rate / float(targets.size())
	for t: Dictionary in targets:
		var tgt_id2: String = str(t.get("tgt_id", ""))
		var tgt_specs2: Dictionary = t.get("specs", {}) as Dictionary
		var tl2: ResourceTimeline = t.get("tl") as ResourceTimeline
		var credit: float = share
		# Cap to remaining headroom so catchments do not toast-overflow tanks.
		# Use 0.999 ceiling to stay below ResourceTimeline.is_overflowing_at.
		if not _tank_is_unlimited(tgt_specs2) and dt_hours > 0.001:
			var lvl: float = 0.0
			if tl2 != null:
				lvl = tl2.level_at(abs_h)
			else:
				lvl = float(tgt_specs2.get("level", 0.0))
			var cap: float = maxf(_effective_capacity_qty(tgt_specs2), 0.001)
			var headroom_qty: float = maxf(0.998 - lvl, 0.0) * cap
			credit = minf(credit, headroom_qty / dt_hours)
		if credit <= 0.0:
			_cache_conn_flow(str((t.get("conn") as Dictionary).get("id", "")), 0.0, want_kind)
			continue
		net_rates[tgt_id2] = float(net_rates.get(tgt_id2, 0.0)) + credit
		_cache_conn_flow(str((t.get("conn") as Dictionary).get("id", "")), credit, want_kind)


## Just-in-time free flow: when specs.jit_outflow is on, push stock into
## same-kind downstream resource tanks without overfilling them. When the
## downstream tank is full, transfer rate is zero (upstream simply stops).
func _process_jit_transfers(net_rates: Dictionary, dt_hours: float,
		abs_hours: float) -> void:
	if dt_hours <= 0.0:
		return
	var abs_h: float = abs_hours if abs_hours >= 0.0 else 0.0
	for item: Dictionary in _model.items:
		if str(item.get("type", "")) != "resource":
			continue
		var src_specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		_rk.migrate_resource_specs(src_specs)
		if not bool(src_specs.get("jit_outflow", false)):
			continue
		if not bool(src_specs.get("output_valve_open", true)):
			continue
		var src_id := str(item.get("id", ""))
		var src_kind := ResourceKinds.normalize_kind(str(src_specs.get("resource_kind", "")))
		if src_kind.is_empty():
			continue
		var src_tl: ResourceTimeline = _timelines.get(src_id) as ResourceTimeline
		var src_lvl: float = float(src_specs.get("level", 0.0))
		if src_tl != null:
			src_lvl = src_tl.level_at(abs_h)
		elif bool(src_specs.get("allow_negative", false)):
			src_lvl = float(src_specs.get("level", 0.0))
		if src_lvl <= 0.001 and not bool(src_specs.get("allow_negative", false)):
			continue
		var src_cap: float = maxf(_effective_capacity_qty(src_specs), 0.001)
		# Available stock this step as a rate (drain at most remaining contents).
		var available_qty: float = maxf(src_lvl, 0.0) * src_cap
		if bool(src_specs.get("allow_negative", false)):
			# Deficit supply can still feed JIT; use nominal cap * max(level, 0).
			available_qty = maxf(src_lvl, 0.0) * maxf(float(src_specs.get("capacity_qty", 100.0)), 0.001)
		var available_rate: float = available_qty / dt_hours
		if available_rate <= 0.0:
			continue
		# Collect accepting downstream tanks.
		var downs: Array = []
		for conn: Dictionary in (_resource_conns_by_source_item.get(src_id, []) as Array):
			var tgt_id: String = str(conn.get("target_item_id", ""))
			if tgt_id == src_id:
				continue
			var tgt := _model.get_item(tgt_id)
			if tgt.is_empty() or str(tgt.get("type", "")) != "resource":
				continue
			var tgt_specs: Dictionary = (tgt.get("specs", {}) as Dictionary).duplicate(true)
			_rk.migrate_resource_specs(tgt_specs)
			if ResourceKinds.normalize_kind(str(tgt_specs.get("resource_kind", ""))) != src_kind:
				continue
			# Gravity head gate: uphill transfers need a pump flag on the connection
			# or either tank (specs.pump / specs.is_pump / connection.pump).
			var gravity := _gravity_allows_transfer(item, tgt, conn)
			if not bool(gravity.get("ok", true)):
				_cache_conn_flow(str(conn.get("id", "")), 0.0, src_kind)
				_model.update_connection(str(conn.get("id", "")), {
					"needs_pump": true,
					"gravity_delta_m": float(gravity.get("delta_m", 0.0)),
				})
				continue
			_model.update_connection(str(conn.get("id", "")), {
				"needs_pump": false,
				"gravity_delta_m": float(gravity.get("delta_m", 0.0)),
			})
			var tgt_tl: ResourceTimeline = _timelines.get(tgt_id) as ResourceTimeline
			if not _tank_accepts_inflow(tgt_specs, tgt_tl, abs_h):
				_cache_conn_flow(str(conn.get("id", "")), 0.0, src_kind)
				continue
			downs.append({"conn": conn, "tgt_id": tgt_id, "specs": tgt_specs, "tl": tgt_tl})
		if downs.is_empty():
			continue
		var remaining_rate: float = available_rate
		for d: Dictionary in downs:
			if remaining_rate <= 0.0:
				break
			var tgt_id2: String = str(d.get("tgt_id", ""))
			var tgt_specs2: Dictionary = d.get("specs", {}) as Dictionary
			var tgt_tl2: ResourceTimeline = d.get("tl") as ResourceTimeline
			var dconn: Dictionary = d.get("conn") as Dictionary
			if bool(dconn.get("severed", false)):
				# Burst conduit carries nothing (Wave 8 burnout).
				_cache_conn_flow(str(dconn.get("id", "")), 0.0, src_kind)
				continue
			var max_in: float = remaining_rate
			if not _tank_is_unlimited(tgt_specs2):
				var dlvl: float = float(tgt_specs2.get("level", 0.0))
				if tgt_tl2 != null:
					dlvl = tgt_tl2.level_at(abs_h)
				var dcap: float = maxf(_effective_capacity_qty(tgt_specs2), 0.001)
				# Stop short of the overflow threshold (level >= 0.999 + inflow).
				var headroom: float = maxf(0.998 - dlvl, 0.0) * dcap
				max_in = minf(max_in, headroom / dt_hours)
			max_in = _apply_conduit_derate(dconn, max_in)
			if max_in <= 0.0:
				_cache_conn_flow(str(dconn.get("id", "")), 0.0, src_kind)
				continue
			net_rates[src_id] = float(net_rates.get(src_id, 0.0)) - max_in
			net_rates[tgt_id2] = float(net_rates.get(tgt_id2, 0.0)) + max_in
			_cache_conn_flow(str(dconn.get("id", "")), max_in, src_kind)
			remaining_rate -= max_in


## Wave 8: opt-in Hazen-Williams friction derate on a JIT transfer. rate_qph is
## qty/hour (water kinds use liters); telemetry is written straight onto the
## connection dict (same in-place pattern as _cache_conn_flow).
func _apply_conduit_derate(conn: Dictionary, rate_qph: float) -> float:
	if rate_qph <= 0.0:
		return rate_qph
	var enabled: bool = bool(conn.get("simulate_losses", _connector_losses_enabled()))
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	if not enabled or not ConduitKinds.is_fluid_type(type_id):
		conn["pressure_drop_psi"] = 0.0
		conn["flow_derate"] = 1.0
		conn["overload_ratio"] = 0.0
		return rate_qph
	var meta: Dictionary = ConduitKinds.type_meta(type_id)
	var flow_lpm: float = rate_qph / 60.0
	var rep: Dictionary = ConduitLoss.hydraulic_report_for_connection(conn, meta, flow_lpm)
	var derate: float = clampf(float(rep.get("derate_frac", 1.0)), 0.0, 1.0)
	conn["pressure_drop_psi"] = float(rep.get("drop_psi", 0.0))
	conn["flow_derate"] = derate
	conn["overload_ratio"] = float(rep.get("overload_ratio", 0.0))
	return rate_qph * derate


func _connector_losses_enabled() -> bool:
	if connector_losses_override == 0:
		return false
	if connector_losses_override == 1:
		return true
	if _host == null or not is_instance_valid(_host):
		return false
	var tree := _host.get_tree()
	if tree == null or tree.root == null:
		return false
	var ctrl := tree.root.get_node_or_null("SimSettingsController")
	if ctrl == null:
		return false
	return bool(ctrl.get("connector_losses_enabled"))


## Returns {ok, delta_m}. ok=false when source elev < target elev and no pump.
## Items without elevation_m skip the gate (freeform graphs keep working).
func _gravity_allows_transfer(src_item: Dictionary, tgt_item: Dictionary,
		conn: Dictionary) -> Dictionary:
	if not src_item.has("elevation_m") or not tgt_item.has("elevation_m"):
		return {"ok": true, "delta_m": 0.0}
	var src_e := float(src_item.get("elevation_m", 0.0))
	var tgt_e := float(tgt_item.get("elevation_m", 0.0))
	# Optional outlet/inlet offsets (meters above grade).
	var src_specs: Dictionary = src_item.get("specs", {}) as Dictionary
	var tgt_specs: Dictionary = tgt_item.get("specs", {}) as Dictionary
	src_e += float(src_specs.get("outlet_height_m", 0.0))
	tgt_e += float(tgt_specs.get("inlet_height_m", 0.0))
	var delta := src_e - tgt_e
	if delta >= -0.05:
		return {"ok": true, "delta_m": delta}
	if bool(conn.get("pump", false)) or bool(src_specs.get("pump", false)) \
			or bool(tgt_specs.get("is_pump", false)) or bool(src_specs.get("is_pump", false)):
		return {"ok": true, "delta_m": delta}
	return {"ok": false, "delta_m": delta}


func _process_processor(item: Dictionary, net_rates: Dictionary, _dt: float,
		abs_hours: float = -1.0) -> void:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	_rk.migrate_processor_specs(specs)
	var abs_h: float = abs_hours if abs_hours >= 0.0 else _get_abs_hours()
	if abs_h < 0.0:
		abs_h = 0.0
	if str(specs.get("role", "")) == "habitat":
		_process_habitat(item, specs, net_rates, abs_h)
		return
	if bool(specs.get("batch_mode", false)):
		_process_processor_batch(item, specs, net_rates, _dt, abs_h)
		return

	var proc_id := str(item.get("id", ""))
	# Power availability is computed independent of the run switch so we can
	# distinguish READY (powered + fed but off) from BLOCKED (on but no power).
	var powered := _processor_has_power(item)

	var occupants: float = maxf(float(specs.get("occupants", 1.0)), 1.0)
	var efficiency: float = clampf(float(specs.get("efficiency", 1.0)), 0.0, 1.0)
	var inputs: Array = specs.get("inputs", []) as Array
	var outputs: Array = specs.get("outputs", []) as Array

	# Concrete blocking reason captured so the UI can explain an idle node
	# instead of it silently doing nothing.
	var block_reason := ""
	var block_kinds: Array = []

	# Throughput limited by slowest input/output rate and tank availability.
	# Rates are scaled by occupants (default 1) so multi-unit processors share one path.
	var throughput: float = INF
	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		# Electric is a power requirement (watts + power_in handle), not a
		# resource wire — never treat it as a tank input. dc_electricity is a
		# DC bus port pair (positive/negative), not a res_in_%d tank port —
		# its throughput is computed separately below, not tank-gated.
		if str(inp.get("kind", "")) in ["electric", "dc_electricity"]:
			continue
		var rate: float = float(inp.get("rate", 0.0)) * occupants
		if rate <= 0.0:
			continue
		var in_kind := ResourceKinds.normalize_kind(str(inp.get("kind", "")))
		var tank_id := _tank_at_port(proc_id, "res_in_%d" % i, true)
		if tank_id.is_empty():
			# Same legacy-port fallback the consume loop below uses.
			tank_id = _tank_at_port(proc_id, "input", true)
		if tank_id.is_empty():
			block_reason = GraphNodeState.REASON_EMPTY_INPUT
			block_kinds = [in_kind] if not in_kind.is_empty() else []
			throughput = 0.0
			break
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
		var tank_item := _model.get_item(tank_id)
		var tank_specs: Dictionary = tank_item.get("specs", {}) if not tank_item.is_empty() else {}
		var deficit_ok: bool = tl == null and bool(tank_specs.get("allow_negative", false))
		if (tl == null and not deficit_ok) or not _tank_has_supply(tank_specs, tl, abs_h):
			block_reason = GraphNodeState.REASON_EMPTY_INPUT
			block_kinds = [in_kind] if not in_kind.is_empty() else []
			throughput = 0.0
			break
		throughput = minf(throughput, rate)

	var unconnected_out: Array = []
	if throughput > 0.0:
		for i: int in outputs.size():
			var outp: Dictionary = outputs[i] as Dictionary
			# dc_electricity leaves via +/- DC ports, not a res_out_%d tank
			# port — never blocks the processor as unwired/full.
			if str(outp.get("kind", "")) == "dc_electricity":
				continue
			var rate: float = float(outp.get("rate", 0.0)) * occupants
			if rate <= 0.0:
				continue
			var out_kind := ResourceKinds.normalize_kind(str(outp.get("kind", "")))
			var tank_id := _tank_at_port(proc_id, "res_out_%d" % i, false)
			if tank_id.is_empty():
				tank_id = _tank_at_port(proc_id, "output", false)
			if tank_id.is_empty():
				# Unwired output blocks the processor (all-or-nothing).
				if not out_kind.is_empty() and not unconnected_out.has(out_kind):
					unconnected_out.append(out_kind)
				block_reason = GraphNodeState.REASON_OUTPUT_UNWIRED
				block_kinds = [out_kind] if not out_kind.is_empty() else []
				throughput = 0.0
				break
			var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
			var tank_item := _model.get_item(tank_id)
			var tank_specs: Dictionary = tank_item.get("specs", {}) if not tank_item.is_empty() else {}
			var in_valve_open: bool = bool(tank_specs.get("input_valve_open", true))
			# Unlimited sinks skip the timeline gate (tl may still exist at 1e12).
			var deficit_sink: bool = tl == null and bool(tank_specs.get("allow_negative", false))
			if (tl == null and not deficit_sink and not _tank_is_unlimited(tank_specs)) or not in_valve_open:
				block_reason = GraphNodeState.REASON_OUTPUT_UNWIRED
				block_kinds = [out_kind] if not out_kind.is_empty() else []
				throughput = 0.0
				break
			if not _tank_accepts_inflow(tank_specs, tl, abs_h):
				block_reason = GraphNodeState.REASON_OUTPUT_FULL
				block_kinds = [out_kind] if not out_kind.is_empty() else []
				throughput = 0.0
				break
			throughput = minf(throughput, rate)

	_write_output_unconnected(proc_id, specs, unconnected_out)

	# No active input or output rate at all — nothing to process (idle standby),
	# regardless of switch/power.
	if throughput == INF:
		specs["current_output_kw"] = 0.0
		_write_node_state(proc_id, specs, GraphNodeState.IDLE)
		return

	var fed := throughput > 0.0
	var switched_on := _processor_switched_on(specs)

	# Switched OFF: it isn't trying to run, so it is never "blocked" (no red).
	# READY = plugged in and provisioned (power + resources); otherwise IDLE.
	if not switched_on:
		specs["current_output_kw"] = 0.0
		if powered and fed:
			_write_node_state(proc_id, specs, GraphNodeState.READY)
		else:
			_write_node_state(proc_id, specs, GraphNodeState.IDLE)
		return

	# Switched ON but unable to run → BLOCKED (red) with the concrete reason.
	if not powered:
		specs["current_output_kw"] = 0.0
		_write_node_state(proc_id, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_NO_POWER, [])
		return
	if not fed:
		specs["current_output_kw"] = 0.0
		_write_node_state(proc_id, specs, GraphNodeState.BLOCKED, block_reason, block_kinds)
		return

	# RUNNING (switched on + powered + fed): move resources.
	throughput *= efficiency
	_write_node_state(proc_id, specs, GraphNodeState.RUNNING)

	# Live DC output telemetry: Wh generated per fuel unit consumed ×
	# post-efficiency throughput, NOT the flat spec a resource-tank output
	# would use — energy_wh_per_unit is authored on the generator preset.
	# SystemGraphView's DcPowerWiring aggregator reads this each tick to fold
	# it into SolarUI/EnergyTimeline; it never moves through a tank itself.
	var dc_out_kw := 0.0
	for outp_dc: Dictionary in outputs:
		if str(outp_dc.get("kind", "")) == "dc_electricity":
			dc_out_kw = throughput * float(specs.get("energy_wh_per_unit", 0.0)) / 1000.0
			break
	if absf(float(specs.get("current_output_kw", 0.0)) - dc_out_kw) > 0.0005:
		specs["current_output_kw"] = dc_out_kw
		_model.update_item(proc_id, {"specs": specs})

	var in_total: float = _resource_io_total(inputs) * occupants
	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		var kind: String = str(inp.get("kind", ""))
		if kind in ["electric", "dc_electricity"]:
			continue
		var rate: float = float(inp.get("rate", 0.0)) * occupants
		if rate <= 0.0:
			continue
		var portion: float = throughput * (rate / maxf(in_total, 0.001))
		var tank_id := _tank_at_port(str(item.get("id", "")), "res_in_%d" % i, true)
		if tank_id.is_empty():
			tank_id = _tank_at_port(str(item.get("id", "")), "input", true)
		if tank_id.is_empty():
			continue
		net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) - portion
		for conn: Dictionary in _connections_to_handle(str(item.get("id", "")), "res_in_%d" % i):
			_cache_conn_flow(str(conn.get("id", "")), portion, kind)

	var out_total: float = _total_io_rate(outputs, "dc_electricity") * occupants
	for i: int in outputs.size():
		var outp: Dictionary = outputs[i] as Dictionary
		if str(outp.get("kind", "")) == "dc_electricity":
			continue
		var rate: float = float(outp.get("rate", 0.0)) * occupants
		if rate <= 0.0:
			continue
		var portion: float = throughput * (rate / maxf(out_total, 0.001))
		var tank_id := _tank_at_port(str(item.get("id", "")), "res_out_%d" % i, false)
		if tank_id.is_empty():
			tank_id = _tank_at_port(str(item.get("id", "")), "output", false)
		if tank_id.is_empty():
			continue
		net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) + portion
		for conn: Dictionary in _connections_from_handle(str(item.get("id", "")), "res_out_%d" % i):
			_cache_conn_flow(str(conn.get("id", "")), portion, str(outp.get("kind", "")))
		if i == 0 and outputs.size() == 1:
			for conn: Dictionary in _connections_from_handle(str(item.get("id", "")), "output"):
				_cache_conn_flow(str(conn.get("id", "")), portion, str(outp.get("kind", "")))


## Batch-mode quantity for one I/O entry: prefers the explicit "value" field
## (flat qty per batch cycle) and falls back to "rate" for older data that
## predates the name/value split — continuous mode keeps using "rate" as a
## qty/hour throughout this file, untouched by this helper.
func _io_batch_qty(io: Dictionary, occupants: float) -> float:
	return float(io.get("value", io.get("rate", 0.0))) * occupants


func _is_active_in_phase(io: Dictionary, elapsed: float, _batch_time: float) -> bool:
	var mode := str(io.get("mode", "continuous"))
	if mode == "continuous":
		return true
	if mode == "delayed":
		var d := float(io.get("delay_hrs", 0.0))
		var dur := float(io.get("duration_hrs", 1.0))
		return elapsed >= d and elapsed < (d + dur)
	return false

func _process_processor_batch(item: Dictionary, specs: Dictionary, net_rates: Dictionary, dt_hours: float, abs_h: float) -> void:
	var item_id := str(item.get("id", ""))
	if not _processor_states.has(item_id):
		_processor_states[item_id] = { "state": "idle", "elapsed": 0.0, "penalty_qty": 0.0 }
	var state: Dictionary = _processor_states[item_id] as Dictionary
	
	var batch_time := maxf(float(specs.get("batch_time_hrs", 1.0)), 0.001)
	var occupants := maxf(float(specs.get("occupants", 1.0)), 1.0)
	var inputs := specs.get("inputs", []) as Array
	var outputs := specs.get("outputs", []) as Array
	var eff := clampf(float(specs.get("efficiency", 1.0)), 0.0, 1.0)
	
	if str(state["state"]) == "idle":
		var switched_on := _processor_switched_on(specs)
		var can_start := true
		var start_block_reason := ""
		var start_block_kinds: Array = []

		# Start-phase power requirement (elapsed=0), used to check power + load draw.
		var req_watts := float(specs.get("watts", specs.get("avg_watts", 0.0))) * occupants
		for inp: Variant in inputs:
			var inpd := inp as Dictionary
			if str(inpd.get("kind", "")) == "electric":
				if _is_active_in_phase(inpd, 0.0, batch_time):
					req_watts += float(inpd.get("rate", 0.0)) * occupants

		if req_watts > 0.0 and not _processor_has_power(item):
			can_start = false
			start_block_reason = GraphNodeState.REASON_NO_POWER

		if can_start:
			for i in inputs.size():
				var inp: Dictionary = inputs[i] as Dictionary
				var mode := str(inp.get("mode", "continuous"))
				var kind := str(inp.get("kind", ""))
				if kind == "electric": continue
				if mode == "frontloaded":
					var qty := _io_batch_qty(inp, occupants)
					if qty <= 0.0: continue
					var tank_id := _tank_at_port(item_id, "res_in_%d" % i, true)
					if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "input", true)
					if tank_id.is_empty():
						can_start = false
						start_block_reason = GraphNodeState.REASON_EMPTY_INPUT
						start_block_kinds = [ResourceKinds.normalize_kind(kind)]
						break
					var tl := _timelines.get(tank_id) as ResourceTimeline
					var tank_item := _model.get_item(tank_id)
					var tank_specs: Dictionary = tank_item.get("specs", {}) if not tank_item.is_empty() else {}
					var out_valve_open: bool = bool(tank_specs.get("output_valve_open", true))
					var deficit_ok: bool = tl == null and bool(tank_specs.get("allow_negative", false))
					if (tl == null and not deficit_ok) or (tl != null and tl.level_at(abs_h) < qty) or not out_valve_open:
						can_start = false
						start_block_reason = GraphNodeState.REASON_EMPTY_INPUT
						start_block_kinds = [ResourceKinds.normalize_kind(kind)]
						break

		# Switched OFF: it isn't trying to run → never blocked. READY if it could
		# start (powered + frontload available), else IDLE. Draw nothing.
		if not switched_on:
			item.erase("batch_active_watts")
			if can_start:
				_write_node_state(item_id, specs, GraphNodeState.READY)
			else:
				_write_node_state(item_id, specs, GraphNodeState.IDLE)
			return

		# Switched ON — publish the start-phase draw for load accounting.
		item["batch_active_watts"] = req_watts

		if can_start:
			for i in inputs.size():
				var inp: Dictionary = inputs[i] as Dictionary
				var mode := str(inp.get("mode", "continuous"))
				if mode == "frontloaded" and str(inp.get("kind", "")) != "electric":
					var qty := _io_batch_qty(inp, occupants)
					if qty <= 0.0: continue
					var tank_id := _tank_at_port(item_id, "res_in_%d" % i, true)
					if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "input", true)
					net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) - (qty / dt_hours)

			state["state"] = "running"
			state["elapsed"] = 0.0
			state["penalty_qty"] = 0.0
		else:
			item.erase("batch_active_watts")
			item["batch_error"] = "blocked"
			_write_node_state(item_id, specs, GraphNodeState.BLOCKED,
					start_block_reason, start_block_kinds)
			return
			
	if str(state["state"]) == "running":
		# Manually switched off mid-batch → pause (hold elapsed), draw nothing.
		if not _processor_switched_on(specs):
			item.erase("batch_active_watts")
			_write_node_state(item_id, specs, GraphNodeState.IDLE)
			return

		var elapsed: float = float(state["elapsed"])

		var req_watts := 0.0
		var has_electric_input := false
		for inp: Variant in inputs:
			var inpd := inp as Dictionary
			if str(inpd.get("kind", "")) == "electric":
				has_electric_input = true
				if _is_active_in_phase(inpd, elapsed, batch_time):
					req_watts += float(inpd.get("rate", 0.0)) * occupants
					
		if not has_electric_input:
			req_watts = float(specs.get("watts", 0.0))
			if req_watts <= 0.0:
				req_watts = float(specs.get("avg_watts", 0.0))
			if req_watts <= 0.0:
				req_watts = float(specs.get("base_watts", 0.0))
			req_watts *= occupants
			
		item["batch_active_watts"] = req_watts
		item["batch_error"] = ""

		var powered := true
		if req_watts > 0.0:
			powered = _processor_has_power(item)
			
		var missing_inputs := false
		var missing_kind := ""
		var frame_pulls := {}
		for i in inputs.size():
			var inp: Dictionary = inputs[i] as Dictionary
			var kind := str(inp.get("kind", ""))
			if kind == "electric": continue
			if _is_active_in_phase(inp, elapsed, batch_time):
				var qty_per_hr := 0.0
				var mode := str(inp.get("mode", "continuous"))
				if mode == "continuous":
					qty_per_hr = _io_batch_qty(inp, occupants) / batch_time
				elif mode == "delayed":
					var dur := maxf(float(inp.get("duration_hrs", 1.0)), 0.001)
					qty_per_hr = _io_batch_qty(inp, occupants) / dur
				
				if qty_per_hr > 0.0:
					var tank_id := _tank_at_port(item_id, "res_in_%d" % i, true)
					if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "input", true)
					if tank_id.is_empty():
						missing_inputs = true; missing_kind = kind; break
					var tl := _timelines.get(tank_id) as ResourceTimeline
					var tank_item := _model.get_item(tank_id)
					var tank_specs: Dictionary = tank_item.get("specs", {}) if not tank_item.is_empty() else {}
					var out_valve_open: bool = bool(tank_specs.get("output_valve_open", true))
					var deficit_ok: bool = tl == null and bool(tank_specs.get("allow_negative", false))
					if (tl == null and not deficit_ok) or (tl != null and tl.level_at(abs_h) < (qty_per_hr * dt_hours)) or not out_valve_open:
						missing_inputs = true; missing_kind = kind; break
					frame_pulls[tank_id] = float(frame_pulls.get(tank_id, 0.0)) + qty_per_hr
					for conn: Dictionary in _connections_to_handle(item_id, "res_in_%d" % i):
						_cache_conn_flow(str(conn.get("id", "")), qty_per_hr, kind)
					if i == 0 and inputs.size() == 1:
						for conn: Dictionary in _connections_to_handle(item_id, "input"):
							_cache_conn_flow(str(conn.get("id", "")), qty_per_hr, kind)
		
		if not powered or missing_inputs:
			item["batch_error"] = "missing_inputs" if missing_inputs else "blocked"
			item.erase("batch_active_watts")
			var blk_reason := GraphNodeState.REASON_EMPTY_INPUT if missing_inputs \
					else GraphNodeState.REASON_NO_POWER
			var blk_kinds: Array = [ResourceKinds.normalize_kind(missing_kind)] \
					if missing_inputs and not missing_kind.is_empty() else []
			_write_node_state(item_id, specs, GraphNodeState.BLOCKED, blk_reason, blk_kinds)
			var fail_mode := str(specs.get("batch_failure_mode", "pause_and_resume"))
			if fail_mode == "restart_with_penalty":
				# Scrap progress, restart from idle, and waste the configured
				# penalty quantity from the primary input tank as the retry cost.
				state["state"] = "idle"
				_apply_batch_penalty(item_id, specs, inputs, net_rates, dt_hours)
			elif fail_mode == "destroy_batch":
				# Whole batch scrapped: progress + any frontloaded inputs lost,
				# must be re-triggered from idle (no extra tank debit).
				state["state"] = "idle"
			# pause_and_resume: keep elapsed and wait for inputs to return.
			return

		_write_node_state(item_id, specs, GraphNodeState.RUNNING)

		for tank_id: Variant in frame_pulls:
			net_rates[str(tank_id)] = float(net_rates.get(str(tank_id), 0.0)) - float(frame_pulls[tank_id])
			
		var frame_pushes := {}
		for i in outputs.size():
			var outp: Dictionary = outputs[i] as Dictionary
			if _is_active_in_phase(outp, elapsed, batch_time):
				var qty_per_hr := 0.0
				var mode := str(outp.get("mode", "continuous"))
				if mode == "continuous":
					qty_per_hr = (_io_batch_qty(outp, occupants) * eff) / batch_time
				elif mode == "delayed":
					var dur := maxf(float(outp.get("duration_hrs", 1.0)), 0.001)
					qty_per_hr = (_io_batch_qty(outp, occupants) * eff) / dur
				
				if qty_per_hr > 0.0:
					var tank_id := _tank_at_port(item_id, "res_out_%d" % i, false)
					if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "output", false)
					
					var push_ok := false
					if not tank_id.is_empty():
						var tank_item := _model.get_item(tank_id)
						var tank_specs: Dictionary = tank_item.get("specs", {}) if not tank_item.is_empty() else {}
						var in_valve_open: bool = bool(tank_specs.get("input_valve_open", true))
						if in_valve_open:
							push_ok = true
					
					if push_ok:
						frame_pushes[tank_id] = float(frame_pushes.get(tank_id, 0.0)) + qty_per_hr
						for conn: Dictionary in _connections_from_handle(item_id, "res_out_%d" % i):
							_cache_conn_flow(str(conn.get("id", "")), qty_per_hr, str(outp.get("kind", "")))
						if i == 0 and outputs.size() == 1:
							for conn: Dictionary in _connections_from_handle(item_id, "output"):
								_cache_conn_flow(str(conn.get("id", "")), qty_per_hr, str(outp.get("kind", "")))
						
		for tank_id: Variant in frame_pushes:
			net_rates[str(tank_id)] = float(net_rates.get(str(tank_id), 0.0)) + float(frame_pushes[tank_id])
			
		state["elapsed"] = elapsed + dt_hours
		
		if float(state["elapsed"]) >= batch_time:
			for i in outputs.size():
				var outp: Dictionary = outputs[i] as Dictionary
				var mode := str(outp.get("mode", "continuous"))
				if mode == "end_batch":
					var qty := _io_batch_qty(outp, occupants) * eff
					if qty > 0.0:
						var tank_id := _tank_at_port(item_id, "res_out_%d" % i, false)
						if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "output", false)
						
						var push_ok := false
						if not tank_id.is_empty():
							var tank_item := _model.get_item(tank_id)
							var tank_specs: Dictionary = tank_item.get("specs", {}) if not tank_item.is_empty() else {}
							var in_valve_open: bool = bool(tank_specs.get("input_valve_open", true))
							if in_valve_open:
								push_ok = true
						
						if push_ok:
							var qty_per_hr := qty / dt_hours
							net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) + qty_per_hr
							for conn: Dictionary in _connections_from_handle(item_id, "res_out_%d" % i):
								_cache_conn_flow(str(conn.get("id", "")), qty_per_hr, str(outp.get("kind", "")))
							if i == 0 and outputs.size() == 1:
								for conn: Dictionary in _connections_from_handle(item_id, "output"):
									_cache_conn_flow(str(conn.get("id", "")), qty_per_hr, str(outp.get("kind", "")))
			
			state["state"] = "idle"
			state["elapsed"] = 0.0


## Habitat: per-channel demand × occupants; waste = yield × actual consumption.
## Does not invent mass when an input tank is empty (soft-fail + starved_kinds).
func _process_habitat(item: Dictionary, specs: Dictionary, net_rates: Dictionary,
		abs_h: float) -> void:
	var iid: String = str(item.get("id", ""))
	var occupants: float = maxf(float(specs.get("occupants", 1.0)), 1.0)
	var inputs: Array = specs.get("inputs", []) as Array

	var starved: Array = []
	var had_demand := false
	var water_consumed_lph := 0.0
	var food_consumed_kgph := 0.0

	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		var kind: String = ResourceKinds.normalize_kind(str(inp.get("kind", "")))
		var rate: float = float(inp.get("rate", 0.0)) * occupants
		if rate <= 0.0:
			continue
		had_demand = true
		var tank_id := _tank_at_port(iid, "res_in_%d" % i, true)
		if tank_id.is_empty():
			tank_id = _tank_at_port(iid, "input", true)
		if tank_id.is_empty():
			if not starved.has(kind):
				starved.append(kind)
			continue
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
		if tl == null:
			if not starved.has(kind):
				starved.append(kind)
			continue
		var lvl := tl.level_at(abs_h)
		if lvl <= 0.001:
			if not starved.has(kind):
				starved.append(kind)
			continue
		net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) - rate
		for conn: Dictionary in _connections_to_handle(iid, "res_in_%d" % i):
			_cache_conn_flow(str(conn.get("id", "")), rate, kind)
		if kind == "water":
			water_consumed_lph += rate
		elif kind == "food":
			food_consumed_kgph += rate

	# Stoichiometric waste from actual consumption (mass-conserving yields).
	var waste_credits: Dictionary = {
		"greywater": water_consumed_lph * HABITAT_GREYWATER_YIELD,
		"blackwater": water_consumed_lph * HABITAT_BLACKWATER_YIELD,
		"biomass": food_consumed_kgph * HABITAT_FOOD_SCRAP_YIELD,
	}
	var outputs: Array = specs.get("outputs", []) as Array
	for i: int in outputs.size():
		var outp: Dictionary = outputs[i] as Dictionary
		var kind: String = ResourceKinds.normalize_kind(str(outp.get("kind", "")))
		var credit: float = float(waste_credits.get(kind, 0.0))
		# Allow preset rate override only as a cap (never invent above yield).
		var cap: float = float(outp.get("rate", 0.0)) * occupants
		if cap > 0.0:
			credit = minf(credit, cap)
		if credit <= 0.0:
			continue
		var tank_id := _tank_at_port(iid, "res_out_%d" % i, false)
		if tank_id.is_empty():
			tank_id = _tank_at_port(iid, "output", false)
		if tank_id.is_empty():
			continue
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
		var tank_item := _model.get_item(tank_id)
		var tank_specs: Dictionary = tank_item.get("specs", {}) if not tank_item.is_empty() else {}
		if not _tank_accepts_inflow(tank_specs, tl, abs_h):
			continue
		net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) + credit
		for conn: Dictionary in _connections_from_handle(iid, "res_out_%d" % i):
			_cache_conn_flow(str(conn.get("id", "")), credit, kind)

	_write_habitat_starved(iid, specs, starved)
	# Unified node state: STARVED when any channel is dry, RUNNING while fed,
	# IDLE only when the habitat has no demand at all.
	if not starved.is_empty():
		_write_node_state(iid, specs, GraphNodeState.STARVED,
				GraphNodeState.REASON_EMPTY_INPUT, starved)
	elif had_demand:
		_write_node_state(iid, specs, GraphNodeState.RUNNING)
	else:
		_write_node_state(iid, specs, GraphNodeState.IDLE)


func _write_habitat_starved(item_id: String, specs: Dictionary, starved: Array) -> void:
	var prev: Array = specs.get("starved_kinds", []) as Array
	var changed := prev.size() != starved.size()
	if not changed:
		for k: Variant in starved:
			if not prev.has(k):
				changed = true
				break
	if not changed:
		return
	specs["starved_kinds"] = starved.duplicate()
	specs["is_starved"] = not starved.is_empty()
	_model.update_item(item_id, {"specs": specs})
	habitat_starvation_changed.emit(item_id, starved)


## Diagnostic: kinds whose output port has no connected tank (blocks the
## processor). Change-detected write, same pattern as _write_habitat_starved.
func _write_output_unconnected(item_id: String, specs: Dictionary, kinds: Array) -> void:
	var prev: Array = specs.get("output_unconnected_kinds", []) as Array
	var changed := prev.size() != kinds.size()
	if not changed:
		for k: Variant in kinds:
			if not prev.has(k):
				changed = true
				break
	if not changed:
		return
	specs["output_unconnected_kinds"] = kinds.duplicate()
	_model.update_item(item_id, {"specs": specs})


## Change-detected write of the unified node state (+ reason + blocking kinds).
## Mirrors _write_habitat_starved: only writes/emits on a real transition.
func _write_node_state(item_id: String, specs: Dictionary, state: String,
		reason: String = "", kinds: Array = []) -> void:
	var prev_state := str(specs.get("node_state", ""))
	var prev_reason := str(specs.get("node_state_reason", ""))
	var prev_kinds: Array = specs.get("node_state_kinds", []) as Array
	var kinds_changed := prev_kinds.size() != kinds.size()
	if not kinds_changed:
		for k: Variant in kinds:
			if not prev_kinds.has(k):
				kinds_changed = true
				break
	if prev_state == state and prev_reason == reason and not kinds_changed:
		return
	specs["node_state"] = state
	specs["node_state_reason"] = reason
	specs["node_state_kinds"] = kinds.duplicate()
	_model.update_item(item_id, {"specs": specs})
	node_state_changed.emit(item_id, state, reason, kinds)
	# Keep the legacy processor_blocked signal firing for existing consumers.
	if state == GraphNodeState.BLOCKED or state == GraphNodeState.STARVED:
		processor_blocked.emit(item_id, kinds)


## restart_with_penalty cost: waste batch_failure_penalty_qty (×occupants) from
## the first wired non-electric input tank. This is what makes that failure mode
## meaningfully distinct from destroy_batch (which just scraps the run).
func _apply_batch_penalty(item_id: String, specs: Dictionary, inputs: Array,
		net_rates: Dictionary, dt_hours: float) -> void:
	var occupants := maxf(float(specs.get("occupants", 1.0)), 1.0)
	var penalty := float(specs.get("batch_failure_penalty_qty", 0.0)) * occupants
	if penalty <= 0.0 or dt_hours <= 0.0:
		return
	for i in inputs.size():
		var inp := inputs[i] as Dictionary
		if str(inp.get("kind", "")) == "electric":
			continue
		var t := _tank_at_port(item_id, "res_in_%d" % i, true)
		if t.is_empty():
			t = _tank_at_port(item_id, "input", true)
		if not t.is_empty():
			net_rates[str(t)] = float(net_rates.get(str(t), 0.0)) - (penalty / dt_hours)
			return


func _total_io_rate(arr: Array, exclude_kind: String = "") -> float:
	var t := 0.0
	for e: Variant in arr:
		if e is Dictionary:
			if not exclude_kind.is_empty() and str((e as Dictionary).get("kind", "")) == exclude_kind:
				continue
			t += float((e as Dictionary).get("rate", 0.0))
	return maxf(t, 0.001)


## Like _total_io_rate but excludes electric/DC power entries — used to
## apportion resource throughput across actual resource inputs only.
func _resource_io_total(arr: Array) -> float:
	var t := 0.0
	for e: Variant in arr:
		if e is Dictionary and str((e as Dictionary).get("kind", "")) not in ["electric", "dc_electricity"]:
			t += float((e as Dictionary).get("rate", 0.0))
	return maxf(t, 0.001)


## Does the processor have POWER available (independent of its run switch)?
## AC processors: the AC bus is up (SolarUI/inverter) AND a `power_in` wire exists.
## Passive processors (no energy_source): always powered. This deliberately does
## NOT consult the on/off switch or GraphSimLoad — the switch is resolved
## separately (_processor_switched_on) so READY vs BLOCKED can be distinguished.
func _processor_has_power(item: Dictionary) -> bool:
	if power_available_override == 0:
		return false
	# Override 1 lets headless tests (host == null) exercise the powered path;
	# wiring checks below still apply.
	if power_available_override != 1 and (_host == null or _model == null):
		return false
	if _model == null:
		return false
	var iid: String = str(item.get("id", ""))
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	_rk.migrate_processor_specs(specs)
	var es: String = str(specs.get("energy_source", ""))
	if es.is_empty() and float(specs.get("watts", 0.0)) > 0.0:
		es = "ac"
	if es == "ac":
		if not _ac_output_available():
			return false
		return _has_incoming_connection(iid, "power_in")
	# Passive (no power needed) or future "dc" (powered via a tanked electric
	# resource input, which is handled by the resource-flow "fed" check, not here).
	return true


## The manual/automation run switch: requested_state wins, else legacy
## current_state; unset → OFF. Default-off means a processor runs only when the
## user (double-click) or an automation switches it on.
func _processor_switched_on(specs: Dictionary) -> bool:
	var req := str(specs.get("requested_state", "")).to_lower()
	if req == "on":
		return true
	if req == "off":
		return false
	return str(specs.get("current_state", "")).to_lower() == "on"


func _ac_output_available() -> bool:
	if power_available_override == 0:
		return false
	if power_available_override == 1:
		return true
	var apb: Node = null
	if _host != null and is_instance_valid(_host):
		apb = _host.get_node_or_null("/root/AcPowerBus")
	if apb != null and "ac_output_enabled" in apb:
		return bool(apb.ac_output_enabled)
	var su := _get_primary_solar_ui()
	if su == null:
		# Fail CLOSED: with no power authority present, AC loads must not run.
		# (Previously fail-open — processors consumed resources unpowered.)
		return false
	# AC is available only when the inverter output is enabled AND the battery can
	# supply it — the single authority both the engine and the sim-load use.
	var enabled := true
	if su.has_method("is_ac_output_enabled"):
		enabled = bool(su.call("is_ac_output_enabled"))
	var available := true
	if su.has_method("is_power_available"):
		available = bool(su.call("is_power_available"))
	if not su.has_method("is_ac_output_enabled") and not su.has_method("is_power_available"):
		return false
	return enabled and available


func _get_primary_solar_ui() -> Node:
	if _host == null:
		return null
	var tree: SceneTree = _host.get_tree()
	if tree == null or tree.root == null:
		return null
	return _find_primary_solar_ui(tree.root)


func _find_primary_solar_ui(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("is_ac_output_enabled"):
		if node.has_method("is_primary_power_source") and not node.call("is_primary_power_source"):
			pass
		else:
			return node
	for child in node.get_children():
		var found := _find_primary_solar_ui(child)
		if found != null:
			return found
	return null


func _has_incoming_connection(item_id: String, handle_id: String) -> bool:
	return not _connections_to_handle(item_id, handle_id).is_empty()


func _rain_rate_mmh() -> float:
	if rain_rate_override_mmh >= 0.0:
		return rain_rate_override_mmh
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return 0.0
	var month: int = int(main_node.get("month")) if main_node.get("month") != null else 6
	var day: int = int(main_node.get("day")) if main_node.get("day") != null else 1
	var hour: float = float(main_node.get("day_time")) if main_node.get("day_time") != null else 12.0
	# During a render, weather is sampled at the render instant, not the live clock.
	if _render_ctx_active:
		var d := _date_at_render()
		if not d.is_empty():
			month = int(d.get("month", month))
			day = int(d.get("day", day))
			hour = float(d.get("day_time", hour))
	var lat: float = float(main_node.get("latitude")) if main_node.get("latitude") != null else 0.0
	var lon: float = float(main_node.get("longitude")) if main_node.get("longitude") != null else 0.0
	var tree: SceneTree = _host.get_tree() if _host != null else null
	if tree == null:
		return 0.0
	var ws: Node = tree.root.get_node_or_null("WeatherService")
	if ws == null:
		return 0.0
	if ws.has_method("covers") and not bool(ws.call("covers", lat, lon)):
		return 0.0
	if ws.has_method("rain_rate_mmh"):
		return float(ws.call("rain_rate_mmh", month, day, hour))
	return 0.0


## Horizontal global irradiance (W/m²) at the live clock instant (or render
## instant during a batch render). Real sun position (Meeus SPA via
## SolarIrradiance) + measured WeatherService GHI when covered, else the
## shared clear-sky model — never zero just because weather is unavailable.
func _sun_ghi_wm2() -> float:
	if sun_ghi_override_wm2 >= 0.0:
		return sun_ghi_override_wm2
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return 0.0
	var year: int = int(main_node.get("year")) if main_node.get("year") != null else 2026
	var month: int = int(main_node.get("month")) if main_node.get("month") != null else 6
	var day: int = int(main_node.get("day")) if main_node.get("day") != null else 1
	var hour: float = float(main_node.get("day_time")) if main_node.get("day_time") != null else 12.0
	if _render_ctx_active:
		var d := _date_at_render()
		if not d.is_empty():
			year = int(d.get("year", year))
			month = int(d.get("month", month))
			day = int(d.get("day", day))
			hour = float(d.get("day_time", hour))
	var lat: float = float(main_node.get("latitude")) if main_node.get("latitude") != null else 0.0
	var lon: float = float(main_node.get("longitude")) if main_node.get("longitude") != null else 0.0
	var ws: Node = null
	var tree: SceneTree = _host.get_tree() if _host != null else null
	if tree != null:
		ws = tree.root.get_node_or_null("WeatherService")
	var weather := SolarIrradiance.sample_weather(lat, lon, month, day, hour, ws)
	return SolarIrradiance.ghi_wm2_at_calendar(lat, lon, month, day, hour, weather, year)


## Cloud cover fraction (0–1) at the live/render instant — folded into GHI via
## SolarIrradiance and published on the sunlight PBI as specs.cloud_frac so
## overcast reduces shared availability even without per-node 3D geometry.
func _sun_cloud_frac() -> float:
	if sun_cloud_override >= 0.0:
		return clampf(sun_cloud_override, 0.0, 1.0)
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return 0.0
	var year: int = int(main_node.get("year")) if main_node.get("year") != null else 2026
	var month: int = int(main_node.get("month")) if main_node.get("month") != null else 6
	var day: int = int(main_node.get("day")) if main_node.get("day") != null else 1
	var hour: float = float(main_node.get("day_time")) if main_node.get("day_time") != null else 12.0
	if _render_ctx_active:
		var d := _date_at_render()
		if not d.is_empty():
			year = int(d.get("year", year))
			month = int(d.get("month", month))
			day = int(d.get("day", day))
			hour = float(d.get("day_time", hour))
	var lat: float = float(main_node.get("latitude")) if main_node.get("latitude") != null else 0.0
	var lon: float = float(main_node.get("longitude")) if main_node.get("longitude") != null else 0.0
	var ws: Node = null
	var tree: SceneTree = _host.get_tree() if _host != null else null
	if tree != null:
		ws = tree.root.get_node_or_null("WeatherService")
	var weather := SolarIrradiance.sample_weather(lat, lon, month, day, hour, ws)
	return clampf(float(weather.get("cloud", 0.0)), 0.0, 1.0)


## Atmosphere sample for Wind PBI (honors selftest overrides).
func _atmosphere_sample() -> Dictionary:
	var out := {
		"wind_ms": 0.0, "temp_c": 20.0, "humidity_pct": 50.0,
		"cloud_frac": 0.0, "rain_mmh": 0.0, "has_real": false,
	}
	if wind_speed_override_ms >= 0.0:
		out["wind_ms"] = wind_speed_override_ms
	if wind_temp_override_c > -900.0:
		out["temp_c"] = wind_temp_override_c
	if wind_humidity_override_pct >= 0.0:
		out["humidity_pct"] = wind_humidity_override_pct
	if wind_cloud_override >= 0.0:
		out["cloud_frac"] = clampf(wind_cloud_override, 0.0, 1.0)
	if wind_rain_override_mmh >= 0.0:
		out["rain_mmh"] = wind_rain_override_mmh
	# If all overrides set, skip WeatherService (deterministic selftests).
	var all_overridden: bool = wind_speed_override_ms >= 0.0 \
			and wind_temp_override_c > -900.0 \
			and wind_humidity_override_pct >= 0.0
	if all_overridden:
		out["has_real"] = true
		return out
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return out
	var month: int = int(main_node.get("month")) if main_node.get("month") != null else 6
	var day: int = int(main_node.get("day")) if main_node.get("day") != null else 1
	var hour: float = float(main_node.get("day_time")) if main_node.get("day_time") != null else 12.0
	if _render_ctx_active:
		var d := _date_at_render()
		if not d.is_empty():
			month = int(d.get("month", month))
			day = int(d.get("day", day))
			hour = float(d.get("day_time", hour))
	var lat: float = float(main_node.get("latitude")) if main_node.get("latitude") != null else 0.0
	var lon: float = float(main_node.get("longitude")) if main_node.get("longitude") != null else 0.0
	var ws: Node = null
	var tree: SceneTree = _host.get_tree() if _host != null else null
	if tree != null:
		ws = tree.root.get_node_or_null("WeatherService")
	var sample: Dictionary = AtmospherePbiScript.sample(lat, lon, month, day, hour, ws)
	if wind_speed_override_ms < 0.0:
		out["wind_ms"] = float(sample.get("wind_ms", 0.0))
	if wind_temp_override_c <= -900.0:
		out["temp_c"] = float(sample.get("temp_c", 20.0))
	if wind_humidity_override_pct < 0.0:
		out["humidity_pct"] = float(sample.get("humidity_pct", 50.0))
	if wind_cloud_override < 0.0:
		out["cloud_frac"] = float(sample.get("cloud_frac", 0.0))
	if wind_rain_override_mmh < 0.0:
		out["rain_mmh"] = float(sample.get("rain_mmh", 0.0))
	out["has_real"] = bool(sample.get("has_real", false))
	return out


func _tank_at_port(proc_id: String, handle_id: String, want_input: bool) -> String:
	if want_input:
		for conn: Dictionary in _connections_to_handle(proc_id, handle_id):
			var src_id: String = str(conn.get("source_item_id", ""))
			var src := _model.get_item(src_id)
			if not src.is_empty() and str(src.get("type", "")) == "resource":
				return src_id
		# Any resource→processor edge (hub_* tank ports still count).
		if handle_id == "input" or handle_id.begins_with("res_in_"):
			for conn: Dictionary in (_resource_conns_by_target_item.get(proc_id, []) as Array):
				var src2 := _model.get_item(str(conn.get("source_item_id", "")))
				if not src2.is_empty() and str(src2.get("type", "")) == "resource":
					return str(src2.get("id", ""))
	else:
		for conn: Dictionary in _connections_from_handle(proc_id, handle_id):
			var tgt_id: String = str(conn.get("target_item_id", ""))
			var tgt := _model.get_item(tgt_id)
			if not tgt.is_empty() and str(tgt.get("type", "")) == "resource":
				return tgt_id
		if handle_id == "output" or handle_id.begins_with("res_out_"):
			for conn: Dictionary in (_resource_conns_by_source_item.get(proc_id, []) as Array):
				var tgt2 := _model.get_item(str(conn.get("target_item_id", "")))
				if not tgt2.is_empty() and str(tgt2.get("type", "")) == "resource":
					return str(tgt2.get("id", ""))
	return ""


func _connections_from_handle(item_id: String, handle_id: String) -> Array:
	return _conn_by_source.get(item_id + "|" + handle_id, []) as Array


func _connections_to_handle(item_id: String, handle_id: String) -> Array:
	return _conn_by_target.get(item_id + "|" + handle_id, []) as Array


func _cache_conn_flow(conn_id: String, rate: float, kind: String = "") -> void:
	_conn_flow[conn_id] = {"rate": rate, "active": rate > 0.001, "kind": kind}
	# Mirror live rate on the connection dict for inspector/tooling (no changed signal).
	var conn: Variant = _conn_by_id.get(conn_id)
	if conn is Dictionary:
		(conn as Dictionary)["flow_rate"] = rate
		(conn as Dictionary)["flow_active"] = rate > 0.001
		if not kind.is_empty():
			(conn as Dictionary)["resource_type"] = ResourceKinds.normalize_kind(kind)


func get_connection_flow(conn_id: String) -> Dictionary:
	return _conn_flow.get(conn_id, {"rate": 0.0, "active": false}) as Dictionary


## ClosureMetrics / HUD: ResourceTimeline for a tank item, or null.
func get_timeline(item_id: String) -> ResourceTimeline:
	return _timelines.get(item_id) as ResourceTimeline


func reanchor_tank(item_id: String, level: float) -> void:
	if not _timelines.has(item_id):
		_ensure_timelines()
	if _timelines.has(item_id):
		var tl: ResourceTimeline = _timelines[item_id] as ResourceTimeline
		tl.clear()
		tl.init_anchor(_get_abs_hours(), level)


## Live resource/processor state snapshot for the automation context + HUD.
## {tanks: {id: {name, kind, level_pct, overflow}}, starved: {id: [kinds]},
##  blocked: {id: {reason, kinds}}}
func state_snapshot() -> Dictionary:
	var tanks: Dictionary = {}
	var starved: Dictionary = {}
	var blocked: Dictionary = {}
	if _model != null:
		for item: Dictionary in _model.items:
			var ty := str(item.get("type", ""))
			var specs: Dictionary = item.get("specs", {}) as Dictionary
			var iid := str(item.get("id", ""))
			if ty == "resource":
				tanks[iid] = {
					"name": str(specs.get("name", "")),
					"kind": ResourceKinds.normalize_kind(str(specs.get("resource_kind", ""))),
					"level_pct": clampf(float(specs.get("level", 0.0)), 0.0, 1.0) * 100.0,
					"overflow": bool(specs.get("overflowing", false)),
				}
			else:
				var st := str(specs.get("node_state", ""))
				if st == GraphNodeState.STARVED:
					starved[iid] = (specs.get("node_state_kinds", []) as Array).duplicate()
				elif st == GraphNodeState.BLOCKED:
					blocked[iid] = {
						"reason": str(specs.get("node_state_reason", "")),
						"kinds": (specs.get("node_state_kinds", []) as Array).duplicate(),
					}
	return {"tanks": tanks, "starved": starved, "blocked": blocked}
