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

## Process-recipe part outputs ready for PartInventory credit.
signal recipe_parts_ready(item_id: String, parts: Array)

## Process-recipe paused for a hybrid chore confirm / labor gate.
signal recipe_chore_waiting(item_id: String, request: Dictionary)

## Potable → greywater / blackwater split (mass-conserving).
## Domestic wastewater split is typically ~70–90% grey / ~10–30% black;
## 80/20 is a standard first-order CELSS / household bookkeeping split.
const HABITAT_GREYWATER_YIELD := 0.80
const HABITAT_BLACKWATER_YIELD := 0.20
## Food scraps / inedible fraction → biomass (~20% kitchen waste fraction).
const HABITAT_FOOD_SCRAP_YIELD := 0.20
## Urine per litre of water the habitat uses: 1.42 L a person a day (Rose
## et al. 2015, Crit Rev Environ Sci Technol 45) of the ~50 L a day the
## habitat preset bills.
const HABITAT_URINE_YIELD := 0.0284
## Share of that urine a urine-diverting (NoMix) toilet catches; field trials
## report roughly 70–90 % (Larsen & Lienert 2007, Novaquatis final report).
## The rest goes down with the flush into the brownwater.
const HABITAT_URINE_DIVERSION := 0.8
## A growing machine with `establish_days` draws this share of its inputs on
## the day it is planted, rising with its yield (seedlings drink less).
const ESTABLISH_DRAW_FLOOR := 0.25

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

## Optional per-map chore-hours ledger (hybrid auto-debit / confirm gates).
## Set by SystemGraphView from TerrainLoader; null = uncapped auto-debit.
var chore_ledger: ChoreLedger = null

## Batch-render context. When active, weather (rain/month) is sampled at
## `_render_abs_hours` instead of the live clock so the resource sim becomes a
## pure function of absolute time (deterministic, reproducible pre-render + scrub).
var _render_ctx_active: bool = false
var _render_abs_hours: float = 0.0

## migrate_resource_specs/migrate_processor_specs are stateless instance
## methods — one shared instance avoids a RefCounted allocation per item per
## tick (previously ResourceKinds.new() at every call site below).
var _rk := ResourceKinds.new()

## Shared HydroReach — reused across siphons/ticks instead of HydroReach.new()
## per siphon per tick (it's reconfigured from specs+pond state each use). The
## single physics authority for pond drain, so the outlet can never be credited
## more water than the pond actually held above the air-break dead pool.
var _reach := HydroReach.new()

var _model: GraphModel = null
var _host: Node = null
var _timelines: Dictionary = {}   # item_id -> ResourceTimeline
var _last_abs_hours: float = -1.0
var _tick_accum: float = 0.0
const TICK_INTERVAL := 0.25
## At very high wall time_scale, poll less often; each step still uses full dt_hours.
const TICK_INTERVAL_HIGH_SPEED := 0.5
const HIGH_SPEED_TIME_SCALE := 0.125  # ~450× realtime (1/3600 * 450)
## When the world clock is frozen (Elev noon-lock / pause), Lab Test Inflow still
## advances pond stock on wall time at this effective scale so the CT responds.
const LAB_PAUSE_FILL_SCALE := 60.0

## Once-per-_simulate_step ambient snapshot (rain / GHI / atmosphere).
var _ambient_valid: bool = false
var _ambient_rain_mmh: float = 0.0
var _ambient_ghi_wm2: float = 0.0
var _ambient_cloud_frac: float = 0.0
var _ambient_atmo: Dictionary = {}

## Cached seasonal supply curves, PER INTAKE: intake id -> {sig, prof}. Feeds
## the annual-energy estimate only; the live tick uses the instantaneous
## supply. (One engine-wide field used to thrash between two stream-fed
## turbines and recompute 12 values + a weather lookup every tick.)
var _supply_profiles: Dictionary = {}
## The routed contour penstock per turbine, memoised for ONE step — five
## separate callers used to rescan every connection each tick.
var _penstock_conn_cache: Dictionary = {}

## conn_id -> {rate, active} cached for wire animation
var _conn_flow: Dictionary = {}
## What every wire carried since it was last asked (`take_conn_quantities`):
## conn id -> [quantity in the wire's unit, kind]. Rates are integrated over
## each LIVE step, and a batch's frontloaded charge (taken in one step, with
## no rate on its wire) is added whole. Pre-render steps are not counted.
## FlowHistory reads it, so a day's window sees what a once-a-second sample
## of the wires missed.
var _conn_qty: Dictionary = {}

## processor_id -> { "state": String, "elapsed": float, "penalty_qty": float }
var _processor_states: Dictionary = {}

## Greenhouses (a compound with specs.greenhouse_system): the climate state
## per compound (GreenhouseClimate), its model cached by signature, and the
## last step's inside climate the beds grow from.
var _gh_state: Dictionary = {}
var _gh_models: Dictionary = {}
var _gh_climate: Dictionary = {}
var _gh_last_h: Dictionary = {}

## Terraced fields (a plant with specs.terrace_id, TerraceField): per node the
## water in each paddy (L, highest first), the crop standing in the field
## (kg dry matter), the crop cycle last harvested and the last hour stepped.
var _terrace_state: Dictionary = {}

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

## What is in a tracked tank (resource composition plan Phase 10): opt-in
## per tank (`specs.track_composition`). Each step a machine fed from a
## tracked tank derives its outputs' make-up from its inputs
## (MakeUp.derive_outputs); a tracked tank mixes in what flowed into it by
## mass; the make-up is kept per 15 min (CompositionTrack) so scrubbing and
## the pre-render replay read it as it was. Nothing runs while no tank is
## tracked.
var _tracks: Dictionary = {}        # tank id -> CompositionTrack
var _out_makeup: Dictionary = {}    # processor id -> {output index: make-up}
var _mu_active := false


## Rebuilds every adjacency index above from _model.connections. O(connections)
## once per tick, replacing what used to be an O(connections) scan PER PORT
## LOOKUP (of which a single processor tick can do several).
## The index is a function of the model's TOPOLOGY plus the player's wire
## edits (GraphModel.struct_rev / user_rev): rebuilt only when either moved,
## not every step. The per-step memo of the routed penstock still clears.
var _conn_index_key: String = ""


func _rebuild_conn_index() -> void:
	_penstock_conn_cache.clear()
	if _model == null:
		_conn_index_key = ""
		_conn_by_source.clear()
		_conn_by_target.clear()
		_resource_conns_by_source_item.clear()
		_resource_conns_by_target_item.clear()
		_conn_by_id.clear()
		return
	var key := "%d|%d|%d" % [_model.struct_rev, _model.user_rev, _model.connections.size()]
	if key == _conn_index_key and not _conn_by_id.is_empty():
		return
	_conn_index_key = key
	_conn_by_source.clear()
	_conn_by_target.clear()
	_resource_conns_by_source_item.clear()
	_resource_conns_by_target_item.clear()
	_conn_by_id.clear()
	# _conn_by_id must reference the REAL connection dicts so _cache_conn_flow's
	# flow_rate/flow_active writeback animates the actual (possibly boundary)
	# wire the player sees.
	for real_conn: Dictionary in _model.connections:
		var rcid := str(real_conn.get("id", ""))
		if not rcid.is_empty():
			_conn_by_id[rcid] = real_conn
	# Adjacency is built from the FLATTENED graph: every edge's endpoints are
	# resolved through transparent super-node (compound) portals down to the leaf
	# item/handle that actually carries the resource. This makes arbitrarily deep
	# nesting transparent to the flow sim — a tank feeding a processor buried in
	# nested compounds resolves to a direct tank->processor edge. Each flat edge
	# keeps its origin conn id, so _cache_conn_flow(edge.id) still hits the real
	# wire via _conn_by_id above.
	for conn: Dictionary in GraphNesting.flat_connections_cached(_model):
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
	_ensure_key = []
	_conn_flow.clear()
	_processor_states.clear()
	_last_abs_hours = -1.0


func clear_timelines() -> void:
	_timelines.clear()
	_ensure_key = []
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


# ---------------------------------------------------------------------------
# Pre-render replay API (CLAUDE.md "Sim pre-render + playback"). Inside a
# rendered range the ambient tick READS instead of simulating: every tank off
# its timeline, the hydro readouts re-derived from the restored pond levels.
# Nothing here integrates anything.
# ---------------------------------------------------------------------------

## Replay the world at `abs_hours`: tanks from their timelines + the hydro
## telemetry (siphon prime / Q / rpm / W, culvert glow) off those levels — the
## same read the backward scrub does, now usable forward. The caller must
## never ask for a time past the rendered range's end: `ResourceTimeline.seek`
## extrapolates past its last sample at constant rates.
func replay_at(abs_hours: float) -> void:
	if _model == null:
		return
	_ensure_timelines_at(abs_hours)
	_read_all_tanks_at(abs_hours)
	_refresh_hydro_telemetry_readonly()
	_last_abs_hours = abs_hours
	# The ambient caller replaced this step's tick(): consume the accumulator
	# so the next replay waits a tick interval like a live step would.
	_tick_accum = 0.0


## Cut every tank's cache after `abs_hours` (a player edit invalidated the
## rendered future). Deficit tanks have no timeline; the render keyframes carry
## them.
func truncate_timelines_after(abs_hours: float) -> void:
	for tl in _timelines.values():
		(tl as ResourceTimeline).truncate_after(abs_hours)
	for tr in _tracks.values():
		(tr as CompositionTrack).truncate_after(abs_hours)
	for led in _item_ledgers.values():
		(led as StoreItemLedger).truncate_after(abs_hours)
	# The unpack's banked allowance is time-local state: a replay from the
	# cut must start it fresh or the re-run diverges from the first run.
	_unpack_carry.clear()


# --- what is in tracked tanks (Phase 10) ------------------------------------

## A tank's make-up now: its tracked one, else its kind's own.
func tank_make_up(iid: String) -> Dictionary:
	var it := _model.get_item(iid) if _model != null else {}
	var sp: Dictionary = it.get("specs", {})
	if bool(sp.get("track_composition", false)) and sp.get("make_up") is Dictionary \
			and not (sp["make_up"] as Dictionary).is_empty():
		return sp["make_up"]
	return MakeUp.of_kind(str(sp.get("resource_kind", "")))


func composition_track(iid: String) -> CompositionTrack:
	return _tracks.get(iid) as CompositionTrack


# --- item ledgers (food/waste realism pass, Phase 5) --------------------------
# Which discrete THINGS a store's kg are: packaged products in a supply
# store, bottles and cans in a waste bin, and the pantry's kcal density.
# Kg stays authoritative in the tank timelines; the ledgers are the fine
# structure the unpack draws FIFO, the 3D bins render and the kcal rides.
# Scrub-safe by the CompositionTrack discipline (truncate_after), carried
# by render snapshots (internal_state_snapshot) and persisted compactly on
# the store's specs ("item_ledger") so a reload keeps the counts.

## Store kinds that may carry an item ledger. `food` carries only kcal
## density (mix events); the typed waste kinds carry archetype counts;
## packaged_food carries product counts. The umbrellas take items too so a
## legacy-wired bin still renders.
const _LEDGER_KINDS := ["packaged_food", "food", "plastic_waste", "packaging_waste",
	"pet_waste", "hdpe_waste", "film_waste", "mixed_plastic_waste", "alu_waste",
	"steel_waste", "glass_waste", "cardboard_waste", "paper_waste"]

## Which umbrella port kind takes a typed waste kind when its own port is
## not on the node (old saves' three-port Unpack & Sort).
const _WASTE_UMBRELLA := {
	"pet_waste": "plastic_waste", "hdpe_waste": "plastic_waste",
	"film_waste": "plastic_waste", "mixed_plastic_waste": "plastic_waste",
	"alu_waste": "packaging_waste", "steel_waste": "packaging_waste",
	"glass_waste": "packaging_waste", "cardboard_waste": "packaging_waste",
	"paper_waste": "packaging_waste",
}

## The v1 Unpack & Sort bulk split (Eurostat 2021-based preset shares) —
## what a store with no item identity unpacks as.
const _UNPACK_BULK := {"food": 0.88, "plastic_waste": 0.04, "packaging_waste": 0.08}

var _item_ledgers: Dictionary = {}   # tank id -> StoreItemLedger
var _ledger_loaded: Dictionary = {}  # tank id -> true once specs.item_ledger was read
var _ledger_stamped: Dictionary = {} # tank id -> [rev, abs_h] of the last specs stamp
var _unpack_carry: Dictionary = {}   # unpack proc id -> kg allowance carried


func _ledger_eligible(kind: String) -> bool:
	return _LEDGER_KINDS.has(ResourceKinds.normalize_kind(kind))


## The store's ledger, created (and restored from its persisted specs state)
## on first ask. Returns null for stores whose kind carries no items.
func ensure_item_ledger(iid: String) -> StoreItemLedger:
	var hit: Variant = _item_ledgers.get(iid)
	if hit != null:
		return hit as StoreItemLedger
	var item := _model.get_item(iid) if _model != null else {}
	if item.is_empty():
		return null
	var specs: Dictionary = item.get("specs", {})
	if not _ledger_eligible(str(specs.get("resource_kind", ""))):
		return null
	var led := StoreItemLedger.new()
	if not _ledger_loaded.has(iid) and specs.get("item_ledger") is Dictionary:
		led.load_persisted(specs["item_ledger"])
	_ledger_loaded[iid] = true
	_item_ledgers[iid] = led
	return led


## Read-only: null when the store has never carried items.
func item_ledger(iid: String) -> StoreItemLedger:
	return _item_ledgers.get(iid) as StoreItemLedger


## A delivery / shopping order lands `manifest` ({product_id: count}) in a
## packaged store's ledger. Returns the kg added; the CALLER credits the
## tank's level (a user edit, outside the sim bracket).
func ledger_add_items(iid: String, manifest: Dictionary, abs_h: float) -> float:
	var led := ensure_item_ledger(iid)
	if led == null:
		return 0.0
	var kg := 0.0
	for pid in manifest:
		var n := int(manifest[pid])
		if n <= 0:
			continue
		var p := FoodProducts.product(str(pid))
		var unit_kg := FoodProducts.gross_g(p) / 1000.0 if not p.is_empty() else 1.0
		led.record(abs_h, str(pid), n, unit_kg * float(n))
		kg += unit_kg * float(n)
	_stamp_ledger_specs(iid, abs_h, true)
	return kg


## Persist a store's compact ledger state onto its specs (what the graph
## autosave carries) and, for food stores, the live kcal density. Change-
## gated on the ledger's rev and at most every 0.25 sim-h unless forced.
## Runs inside the engine's step (the view's sim-write bracket).
func _stamp_ledger_specs(iid: String, abs_h: float, force: bool = false) -> void:
	var led := _item_ledgers.get(iid) as StoreItemLedger
	if led == null or _model == null:
		return
	var last: Array = _ledger_stamped.get(iid, [-1, -INF])
	if not force and int(last[0]) == led.rev:
		return
	if not force and abs_h - float(last[1]) < 0.25:
		return
	var item := _model.get_item(iid)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate()
	specs["item_ledger"] = led.persist_state(abs_h)
	if ResourceKinds.normalize_kind(str(specs.get("resource_kind", ""))) == "food":
		var d := led.density_at(abs_h, FoodProducts.FALLBACK_KCAL_PER_KG)
		if absf(float(specs.get("kcal_per_kg", 0.0)) - d) > 0.5:
			specs["kcal_per_kg"] = d
	_model.update_item(iid, {"specs": specs})
	_ledger_stamped[iid] = [led.rev, abs_h]


## Before tanks integrate: machines fed from a tracked tank derive their
## outputs; every material wire carries the make-up its source gives it.
func _prepare_composition() -> void:
	var any := false
	for t: Dictionary in _model.items_of_type("resource"):
		if bool((t.get("specs", {}) as Dictionary).get("track_composition", false)):
			any = true
			break
	if not any:
		if _mu_active:
			for conn: Dictionary in _model.connections:
				conn.erase("make_up")
			_out_makeup.clear()
			_mu_active = false
		return
	_mu_active = true
	_out_makeup.clear()
	for proc: Dictionary in _model.items_of_type("processor"):
		var sp: Dictionary = proc.get("specs", {})
		if str(sp.get("role", "")) == "habitat" or DesignGap.is_gap(sp) or bool(sp.get("batch_mode", false)):
			continue
		var pid := str(proc.get("id", ""))
		var ins: Array = []
		var tracked_in := false
		var inputs: Array = sp.get("inputs", [])
		for i in inputs.size():
			var inp: Dictionary = inputs[i]
			var k := ResourceKinds.normalize_kind(str(inp.get("kind", "")))
			if not CompositionCatalog.is_material(k):
				continue
			var tid := _tank_at_port(pid, "res_in_%d" % i, true)
			if tid.is_empty():
				tid = _tank_at_port(pid, "input", true)
			var mu: Dictionary = {}
			if not tid.is_empty() and bool(((_model.get_item(tid).get("specs", {})) as Dictionary).get("track_composition", false)):
				mu = tank_make_up(tid)
				tracked_in = true
			ins.append({"kind": k, "kg_h": float(inp.get("rate", 0.0)) * CompositionCatalog.kg_per_unit(k), "make_up": mu})
		if not tracked_in:
			continue
		var outs: Array = []
		var outputs: Array = sp.get("outputs", [])
		for o in outputs:
			var ok := ResourceKinds.normalize_kind(str((o as Dictionary).get("kind", "")))
			var kg := float((o as Dictionary).get("rate", 0.0)) * CompositionCatalog.kg_per_unit(ok) \
				if CompositionCatalog.is_material(ok) else 0.0
			outs.append({"kind": ok, "kg_h": kg})
		var res := MakeUp.derive_outputs(ins, outs)
		var by: Dictionary = {}
		for j in res.size():
			if float((outs[j] as Dictionary)["kg_h"]) > 0.0:
				by[j] = res[j]
		_out_makeup[pid] = by
	for conn: Dictionary in _model.connections:
		if str(conn.get("polarity", "")) != "resource":
			continue
		var src := str(conn.get("source_item_id", ""))
		var mu2: Dictionary = {}
		if _out_makeup.has(src):
			var h := str(conn.get("source_handle_id", ""))
			if h.begins_with("res_out_"):
				mu2 = (_out_makeup[src] as Dictionary).get(int(h.substr(8)), {})
		else:
			var sit := _model.get_item(src)
			if str(sit.get("type", "")) == "resource" and bool((sit.get("specs", {}) as Dictionary).get("track_composition", false)):
				mu2 = tank_make_up(src)
		if mu2.is_empty():
			conn.erase("make_up")
		else:
			conn["make_up"] = MakeUp.rounded(mu2)


## Mix what flowed into a tracked tank this step into what it held.
func _mix_tank(iid: String, specs: Dictionary, net: float, dt_hours: float) -> Dictionary:
	var kind := ResourceKinds.normalize_kind(str(specs.get("resource_kind", "")))
	var kgpu := CompositionCatalog.kg_per_unit(kind)
	var cur := tank_make_up(iid)
	var stock_kg := clampf(float(specs.get("level", 0.0)), 0.0, 1.0) * _effective_capacity_qty(specs) * kgpu
	var wired_kg := 0.0
	var mu := cur
	var kg_have := stock_kg
	for conn: Dictionary in _model.connections:
		if str(conn.get("target_item_id", "")) != iid or str(conn.get("polarity", "")) != "resource":
			continue
		var rate := float((_conn_flow.get(str(conn.get("id", "")), {}) as Dictionary).get("rate", 0.0))
		if rate <= 0.0:
			continue
		var ck := ResourceKinds.normalize_kind(str(conn.get("resource_type", kind)))
		if not CompositionCatalog.is_material(ck):
			ck = kind
		var kg := rate * dt_hours * CompositionCatalog.kg_per_unit(ck)
		var cmu: Dictionary = conn.get("make_up", {}) if conn.get("make_up") is Dictionary else {}
		if cmu.is_empty():
			cmu = MakeUp.of_kind(ck)
		mu = MakeUp.mix(mu, kg_have, cmu, kg)
		kg_have += kg
		wired_kg += kg
	# Inflow no wire explains (rain on a pond, a stream, a delivery): the
	# tank's own kind.
	var other := maxf(net, 0.0) * dt_hours * kgpu - wired_kg
	if other > 1e-9:
		mu = MakeUp.mix(mu, kg_have, MakeUp.of_kind(kind), other)
	return mu


func _store_make_up(iid: String, mu: Dictionary, abs_hours: float) -> void:
	if abs_hours >= 0.0:
		if not _tracks.has(iid):
			_tracks[iid] = CompositionTrack.new()
		(_tracks[iid] as CompositionTrack).record(abs_hours, mu)
	var it := _model.get_item(iid)
	var sp: Dictionary = it.get("specs", {})
	var old: Dictionary = sp.get("make_up", {}) if sp.get("make_up") is Dictionary else {}
	if not old.is_empty() and MakeUp.same(old, mu, 1e-5):
		return
	var sp2 := sp.duplicate(false)
	sp2["make_up"] = MakeUp.rounded(mu)
	_model.update_item(iid, {"specs": sp2})


## The wire-animation flows as the render saw them at one instant …
func conn_flow_snapshot() -> Dictionary:
	return _conn_flow.duplicate(true)


## … and put back on replay, so the 2D wires and the 3D conduit glow follow
## the playhead (they read `get_connection_flow` / the conn dicts, which only
## the forward step writes).
func apply_conn_flow_snapshot(snap: Dictionary) -> void:
	if _model == null:
		return
	_rebuild_conn_index()
	_conn_flow.clear()
	for conn: Dictionary in _model.connections:
		conn["flow_active"] = false
		conn["flow_rate"] = 0.0
	for cid in snap:
		var e: Variant = snap[cid]
		if e is Dictionary:
			_cache_conn_flow(str(cid), float((e as Dictionary).get("rate", 0.0)),
				str((e as Dictionary).get("kind", "")))


## The engine state the live step carries BETWEEN steps and no timeline
## records: batch progress, the NPC bridge's demand overrides, external venue
## flows, per-scope camp AC, the seasonal supply curves, the diversions. A
## render moves all of it to the range's end; when the player drops the range
## (an edit, a scrub before its start) the live step must resume from the
## playhead's state, not the end's.
func internal_state_snapshot() -> Dictionary:
	return {
		"processor_states": _processor_states.duplicate(true),
		"habitat_demand": _habitat_demand.duplicate(true),
		"external_flows": _external_flows.duplicate(true),
		"scope_ac_available": _scope_ac_available.duplicate(true),
		"supply_profiles": _supply_profiles.duplicate(true),
		"stream_diversions": _stream_diversions.duplicate(true),
		"gh_state": _gh_state.duplicate(true),
		"gh_climate": _gh_climate.duplicate(true),
		"gh_last_h": _gh_last_h.duplicate(true),
		"terrace_state": _terrace_state.duplicate(true),
		"last_abs_hours": _last_abs_hours,
		"item_ledgers": _ledger_snapshots(),
		"unpack_carry": _unpack_carry.duplicate(true),
	}


func _ledger_snapshots() -> Dictionary:
	var out: Dictionary = {}
	for iid in _item_ledgers:
		out[iid] = (_item_ledgers[iid] as StoreItemLedger).snapshot()
	return out


func restore_internal_state(snap: Dictionary) -> void:
	if snap.is_empty():
		return
	_processor_states = (snap.get("processor_states", {}) as Dictionary).duplicate(true)
	_habitat_demand = (snap.get("habitat_demand", {}) as Dictionary).duplicate(true)
	_external_flows = (snap.get("external_flows", {}) as Dictionary).duplicate(true)
	_scope_ac_available = (snap.get("scope_ac_available", {}) as Dictionary).duplicate(true)
	_supply_profiles = (snap.get("supply_profiles", {}) as Dictionary).duplicate(true)
	_stream_diversions = (snap.get("stream_diversions", {}) as Dictionary).duplicate(true)
	_gh_state = (snap.get("gh_state", {}) as Dictionary).duplicate(true)
	_gh_climate = (snap.get("gh_climate", {}) as Dictionary).duplicate(true)
	_gh_last_h = (snap.get("gh_last_h", {}) as Dictionary).duplicate(true)
	_terrace_state = (snap.get("terrace_state", {}) as Dictionary).duplicate(true)
	_last_abs_hours = float(snap.get("last_abs_hours", _last_abs_hours))
	var led_snaps: Dictionary = snap.get("item_ledgers", {})
	for iid in led_snaps:
		var led := StoreItemLedger.new()
		led.restore(led_snaps[iid])
		_item_ledgers[iid] = led
		_ledger_loaded[iid] = true
	_unpack_carry = (snap.get("unpack_carry", {}) as Dictionary).duplicate(true)


func _wall_tick_interval() -> float:
	var ts := _host_time_scale()
	if ts >= HIGH_SPEED_TIME_SCALE:
		return TICK_INTERVAL_HIGH_SPEED
	return TICK_INTERVAL


func _host_time_scale() -> float:
	if _host == null:
		return 0.0
	var main_node: Node = null
	if _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return 0.0
	var ts: Variant = main_node.get("time_scale")
	return absf(float(ts)) if ts != null else 0.0



## Cheap, non-mutating predicate: would tick(delta) actually run a step this frame,
## or just accumulate and early-out? Lets the ambient caller skip its bulk-sync /
## history-suppress / PerfMonitor overhead on the ~59/60 frames that do nothing.
func would_tick(delta: float) -> bool:
	if _model == null or _host == null:
		return false
	return (_tick_accum + delta) >= _wall_tick_interval()


## Count a frame's time toward the next step without stepping (the view
## holds a due step over a frame so it does not land on the people tick's).
func accumulate(delta: float) -> void:
	_tick_accum += delta


func tick(delta: float) -> void:
	if _model == null or _host == null:
		return
	_tick_accum += delta
	if _tick_accum < _wall_tick_interval():
		return
	var wall_dt_s := _tick_accum
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
		# Tanks rewound, but siphon RPM/power/prime + culvert flow are written only
		# on the forward path — re-derive them from the restored pond level so the
		# hydro readouts rewind with the water instead of freezing.
		_refresh_hydro_telemetry_readonly()
	else:
		if dt_hours > 0.0:
			_simulate_step(abs_hours, dt_hours)
			_ledger_step(dt_hours)
		else:
			_read_all_tanks_at(abs_hours)
			# Clock frozen (Elev noon-lock / pause) — Test Inflow still fills
			# on wall time so Hydro Lab CT / overlays respond.
			if _lab_sim_inflow_active():
				_apply_lab_sim_inflow_realtime(wall_dt_s)

	_last_abs_hours = abs_hours


## Advance the engine to an explicit absolute-hours timestamp (offline / tools /
## selftests). Same `_simulate_step` primitive that tick() drives, with the time
## supplied directly so headless callers can integrate without a scene clock.
## NOT wired into any per-frame game path — production advances only through
## tick(delta) off the world clock (Phase 1: one clock).
func step_at(abs_hours: float, dt_hours: float) -> void:
	if _model == null:
		return
	_conn_flow.clear()
	for conn: Dictionary in _model.connections:
		conn["flow_active"] = false
		conn["flow_rate"] = 0.0
	_ensure_timelines()
	if dt_hours > 0.0:
		_simulate_step(abs_hours, dt_hours)
		_ledger_step(dt_hours)
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
## Prefer specs.allow_negative for "never block + visible stock" (deficit tanks).
const UNLIMITED_CAPACITY_QTY := ResourceKinds.UNLIMITED_CAPACITY_QTY


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


## _ensure_timelines_at walked every tank every step to find a new one;
## the walk can only change its answer when the graph's structure, a user edit,
## the item list or the timeline map has changed since the last walk.
var _ensure_key: Array = []
var _ensure_items: Array = []


func _ensure_timelines_at(abs_hours: float) -> void:
	var ekey: Array = [_model.struct_rev, _model.user_rev, _model.items.size(), _timelines.size()]
	if not _ensure_key.is_empty() and is_same(_ensure_items, _model.items) and _ensure_key == ekey:
		return
	var live_ids: Dictionary = {}
	var anchor_h: float = abs_hours if abs_hours >= 0.0 else 0.0
	for item: Dictionary in _model.items_of_type("resource"):
		var iid: String = str(item.get("id", ""))
		if iid.is_empty():
			continue
		live_ids[iid] = true
		var specs := _tank_specs_view(item)
		# Deficit-capable ("allow_negative") tanks track an unbounded net stock
		# directly on specs.level instead of a clamped ResourceTimeline — see
		# the integration branch in _simulate_step. Drop any leftover timeline
		# when the flag is toggled on mid-session.
		if bool(specs.get("allow_negative", false)):
			_timelines.erase(iid)
			continue
		if _timelines.has(iid):
			continue
		var tl := ResourceTimelineScript.new()
		tl.configure(_effective_capacity_qty(specs))
		tl.init_anchor(anchor_h, float(specs.get("level", 0.5)))
		_timelines[iid] = tl

	for iid: String in _timelines.keys():
		if not live_ids.has(iid):
			_timelines.erase(iid)
	_ensure_key = [_model.struct_rev, _model.user_rev, _model.items.size(), _timelines.size()]
	_ensure_items = _model.items


func _read_all_tanks_at(abs_hours: float) -> void:
	for item: Dictionary in _model.items_of_type("resource"):
		var iid: String = str(item.get("id", ""))
		if not _timelines.has(iid):
			continue
		var tl: ResourceTimeline = _timelines[iid] as ResourceTimeline
		var sample := tl.seek(abs_hours)
		_apply_tank_sample(item, sample, tl, abs_hours)
		if _tracks.has(iid):
			var mu := (_tracks[iid] as CompositionTrack).at(abs_hours)
			if not mu.is_empty():
				_store_make_up(iid, mu, -1.0)


## Stage–storage curve helpers — thin delegators to PondBathymetry, the one
## conversion shared with HydroReach and the 3D water.
static func stage_level_for_stock(curve: Array, stock_l: float) -> float:
	return PondBathymetry.stage_level_for_stock(curve, stock_l)


static func stage_area_at_level(curve: Array, level_m: float) -> float:
	return PondBathymetry.stage_area_at_level(curve, level_m)


func _apply_tank_sample(item: Dictionary, sample: Dictionary,
		tl: ResourceTimeline = null, abs_hours: float = -1.0) -> void:
	var orig_specs: Dictionary = item.get("specs", {}) as Dictionary
	# What this step would write is worked out into locals first; the patch
	# (and the specs copy it is merged over) is built only when something the
	# UI reads has moved: on most steps an idle tank's values are where they
	# were. The keys are written in the same order either way.
	var lvl := float(sample.get("level", orig_specs.get("level", 0.0)))
	var inr := float(sample.get("inflow_rate", 0.0))
	var outr := float(sample.get("outflow_rate", 0.0))
	var iid := str(item.get("id", ""))
	var overflow_flip := false
	var over := false
	var has_over := false
	var oq := 0.0
	var prev_state := str(orig_specs.get("node_state", ""))
	if tl != null and abs_hours >= 0.0:
		has_over = true
		# Conceptual / unlimited tanks never overflow — inflow is always kept.
		if not _tank_is_unlimited(orig_specs):
			over = tl.is_overflowing_at(abs_hours)
			overflow_flip = over != bool(orig_specs.get("overflowing", false))
			oq = 0.0 if not over else tl.total_overflow_qty
	# Tanks carry an OVERFLOW node state (drives the shared alert overlay); no
	# state otherwise (nominal — level fill speaks for itself).
	var new_state := GraphNodeState.OVERFLOW if over else ""
	# Pond water budget for this step (inflow breakdown + spill), stamped so the
	# inspector can say where the water came from and where it went.
	var b: Dictionary = _pond_budget.get(iid, {})
	var has_b := _pond_budget.has(iid)
	# Skip the model write (and the redraw/telemetry cascade it triggers) when
	# nothing the UI actually reads has moved beyond float noise — an idle
	# tank's level/rates are unchanged tick to tick. The sample/overflow
	# computation above still runs every tick either way; this only gates the
	# write, mirroring _tick_graph_renewables' change-gated update_item.
	const EPS := 0.0005
	var value_changed := new_state != prev_state \
		or absf(lvl - float(orig_specs.get("level", 0.0))) > EPS \
		or absf(inr - float(orig_specs.get("inflow_rate", 0.0))) > EPS \
		or absf(outr - float(orig_specs.get("outflow_rate", 0.0))) > EPS
	if not value_changed and has_over:
		value_changed = over != bool(orig_specs.get("overflowing", false)) \
			or absf(oq - float(orig_specs.get("overflow_qty", 0.0))) > EPS
	if not value_changed and has_b:
		value_changed = absf(float(b.get("spill", 0.0)) - float(orig_specs.get("budget_spill_lph", 0.0))) > 1.0 \
			or absf(float(b.get("rain", 0.0)) - float(orig_specs.get("budget_rain_lph", 0.0))) > 1.0 \
			or absf(float(b.get("stream", 0.0)) - float(orig_specs.get("budget_stream_lph", 0.0))) > 1.0
	var reason := ""
	if value_changed:
		var p: Dictionary = {}
		p["level"] = lvl
		p["inflow_rate"] = inr
		p["outflow_rate"] = outr
		# Pond twin: Auto fill keeps stock_l in lockstep with tank level.
		# Mesh surface uses bathymetric inverse via SystemGraphView.push_pond_levels_to_mesh
		# → terrain_loader.set_pond_stock_l_by_tag; level_m here is a linear Elev fallback.
		if bool(orig_specs.get("pond_storage", false)) \
				and str(orig_specs.get("fill_mode", "auto")) != "manual":
			var cap := maxf(float(orig_specs.get("capacity_qty", 100.0)), 0.001)
			p["stock_l"] = clampf(lvl, 0.0, 1.0) * cap
			# ONE level authority: the basin's stage–storage curve (stamped by the
			# view from the same bathymetry the 3D water uses). Linear floor→rim
			# only when no curve is known (offline / a pond with no terrain).
			var curve: Variant = orig_specs.get("stage_curve", null)
			var lvl_curve := NAN
			if curve is Array and (curve as Array).size() >= 2:
				lvl_curve = stage_level_for_stock(curve as Array, float(p["stock_l"]))
			if not is_nan(lvl_curve):
				p["level_m"] = lvl_curve
			else:
				var rim := float(orig_specs.get("rim_m", NAN))
				var floor_y := float(orig_specs.get("floor_m", NAN))
				if not is_nan(rim) and not is_nan(floor_y):
					var span := maxf(rim - floor_y, 0.05)
					p["level_m"] = floor_y + clampf(lvl, 0.0, 1.0) * span
		if has_over:
			p["overflowing"] = over
			p["overflow_qty"] = oq
		p["node_state"] = new_state
		if new_state != prev_state:
			p["node_state_reason"] = GraphNodeState.REASON_TANK_FULL if over else ""
			p["node_state_kinds"] = []
		if has_b:
			p["budget_rain_lph"] = float(b.get("rain", 0.0))
			p["budget_stream_lph"] = float(b.get("stream", 0.0))
			p["budget_spill_lph"] = float(b.get("spill", 0.0))
		reason = str(p.get("node_state_reason", orig_specs.get("node_state_reason", "")))
		var specs: Dictionary = orig_specs.duplicate(false)
		specs.merge(p, true)
		_model.update_item(iid, {"specs": specs})
	if new_state != prev_state:
		# A changed state always writes (value_changed), which set the reason.
		node_state_changed.emit(iid, new_state, reason, [])
	if overflow_flip:
		tank_overflow_changed.emit(iid, over)


## Deficit-capable ("allow_negative") tanks skip the clamped ResourceTimeline
## entirely and just integrate net rate straight onto specs.level, unbounded —
## going negative shows a deficit (drawn as a red "backordered" indicator by
## the canvas) without ever blocking whatever is drawing from it.
func _integrate_deficit_tank(iid: String, specs: Dictionary,
		net_rates: Dictionary, dt_hours: float) -> void:
	var item: Dictionary = _model.get_item(iid) if _model != null else {}
	var orig: Dictionary = item.get("specs", {}) as Dictionary if not item.is_empty() else {}
	var cap: float = maxf(float(specs.get("capacity_qty", 100.0)), 0.001)
	var net: float = float(net_rates.get(iid, 0.0))
	var level: float = float(specs.get("level", 0.0)) + (net * dt_hours) / cap
	var infl: float = maxf(net, 0.0)
	var outf: float = maxf(-net, 0.0)
	var deficit: float = maxf(-level, 0.0) * cap
	specs["level"] = level
	specs["inflow_rate"] = infl
	specs["outflow_rate"] = outf
	specs["overflowing"] = false
	specs["deficit_qty"] = deficit
	specs["node_state"] = ""
	const EPS := 0.0005
	if absf(level - float(orig.get("level", 0.0))) > EPS \
			or absf(infl - float(orig.get("inflow_rate", 0.0))) > EPS \
			or absf(outf - float(orig.get("outflow_rate", 0.0))) > EPS \
			or absf(deficit - float(orig.get("deficit_qty", 0.0))) > EPS \
			or str(orig.get("node_state", "")) != "":
		_model.update_item(iid, {"specs": specs})


func _simulate_step(abs_hours: float, dt_hours: float) -> void:
	_rebuild_conn_index()
	_refresh_ambient_cache()
	_pond_tank_index_valid = false
	_pond_budget.clear()
	_stream_catch_m2 = {}
	_stream_catch_valid = false
	# Per-tank net rates (qty/hour in tank's capacity units)
	var net_rates: Dictionary = {}

	# Greenhouses first: their beds grow from the climate they make.
	for item: Dictionary in _model.items_of_type("compound"):
		if bool((item.get("specs", {}) as Dictionary).get("greenhouse_system", false)):
			_process_greenhouse(item, dt_hours, abs_hours)
			_gh_exchange(item, net_rates, dt_hours, abs_hours)

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

	_process_culvert_stage_discharge(net_rates, dt_hours, abs_hours)
	_process_siphon_hydro(net_rates, dt_hours, abs_hours)
	_process_jit_transfers(net_rates, dt_hours, abs_hours)
	_credit_stream_inflows(net_rates, dt_hours, abs_hours)
	_apply_external_flows(net_rates, dt_hours)
	_pond_budget_pass(net_rates, dt_hours, abs_hours)
	_prepare_composition()

	# Integrate timelines
	for item: Dictionary in _model.items_of_type("resource"):
		var iid: String = str(item.get("id", ""))
		# Read-only view of the specs (_tank_specs_view); the deficit and the
		# make-up paths write into theirs, so they get a migrated copy.
		var specs := _tank_specs_view(item)
		if bool(specs.get("allow_negative", false)):
			_integrate_deficit_tank(iid, _tank_specs_copy(item), net_rates, dt_hours)
			continue
		if not _timelines.has(iid):
			continue
		var tl: ResourceTimeline = _timelines[iid] as ResourceTimeline
		tl.configure(_effective_capacity_qty(specs))
		var net: float = float(net_rates.get(iid, 0.0))
		var infl: float = maxf(net, 0.0)
		var outf: float = maxf(-net, 0.0)
		var mixed: Dictionary = {}
		if _mu_active and bool(specs.get("track_composition", false)):
			mixed = _mix_tank(iid, _tank_specs_copy(item), net, dt_hours)
		tl.record_step(abs_hours, net, infl, outf)
		var sample := tl.sample_at(abs_hours)
		_apply_tank_sample(item, sample, tl, abs_hours)
		if not mixed.is_empty():
			_store_make_up(iid, mixed, abs_hours)


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
	# Say the RATE first: the volume is rain over the whole SoI, which no tank
	# receives as such (ponds take their own surface + their streams).
	specs["live_rain_mmh"] = rain_mmh
	specs["display_value"] = (I18n.f("{rain_mmh} mm/h · {total_lph} m³/h on SoI", {"rain_mmh": "%.1f" % rain_mmh, "total_lph": "%.0f" % (total_lph / 1000.0)})) \
			if total_lph > 0.0 else "dry"
	specs["is_active"] = rain_mmh > 0.0
	var iid := str(item.get("id", ""))
	_write_if_changed(iid, item, specs,
		["live_capture_lph", "live_rain_mmh", "display_value", "is_active"])
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
	_write_if_changed(iid, item, specs,
		["irradiance_wm2", "flux_kw", "sun_availability", "cloud_frac", "display_value", "is_active"])
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
	_write_if_changed(iid, item, specs, ["wind_ms", "temp_c", "humidity_pct", "cloud_frac",
		"rain_mmh", "kinetic_kw", "weather_class", "display_value", "is_active"])
	if kinetic_kw <= 0.0:
		return
	for conn: Dictionary in (_resource_conns_by_source_item.get(iid, []) as Array):
		_cache_conn_flow(str(conn.get("id", "")), kinetic_kw, "wind")


## A terraced field (TerraceField): water from the store wired to water_in
## goes into the top paddies and cascades down, rain falls on every paddy's
## catchment, evaporation and percolation take some, and what spills off the
## lowest paddies leaves by water_out (a wired store) or runs off. The crop
## grows by light × how well watered its paddies are and is HARVESTED at the
## end of each crop cycle into the store on harvest_out (food for a food crop,
## its straw to residue_out; a reed bed or coppice is all biomass). A scrub
## back holds; nothing grows before the field is planted.
func _process_terrace(item: Dictionary, specs: Dictionary, net_rates: Dictionary,
		dt_hours: float, abs_h: float) -> void:
	var iid := str(item.get("id", ""))
	var table: Array = specs.get("terrace_table", []) as Array
	var heads: Array = specs.get("terrace_heads", []) as Array
	var n := table.size()
	var st: Dictionary = _terrace_state.get(iid, {})
	var store: PackedFloat64Array = st.get("s", PackedFloat64Array())
	if store.size() != n:
		var old := store
		store = PackedFloat64Array()
		store.resize(n)
		for i in mini(n, old.size()):
			store[i] = old[i]
		# A world loaded (or a re-cut field): the water comes back from the
		# levels the node saved with the graph.
		var saved: Array = specs.get("terrace_fill", []) as Array
		if old.is_empty() and saved.size() == n:
			for i in n:
				store[i] = clampf(float(saved[i]), 0.0, 1.0) * float(table[i][2])
		if not st.has("standing"):
			st["standing"] = float(specs.get("standing_kg", 0.0))
	# "Fill now" / "Drain" from the editor: the fills ride the specs once.
	var had_set := specs.has("terrace_fill_set")
	var fill_req: Variant = specs.get("terrace_fill_set", null)
	if fill_req is Array and (fill_req as Array).size() == n:
		for i in n:
			store[i] = clampf(float(fill_req[i]), 0.0, 1.0) * float(table[i][2])
	specs.erase("terrace_fill_set")
	var last_h := float(st.get("last_h", -1.0))
	if dt_hours <= 0.0 or (last_h >= 0.0 and abs_h < last_h - 1e-6):
		st["s"] = store
		st["last_h"] = abs_h
		_terrace_state[iid] = st
		if had_set:
			_model.update_item(iid, {"specs": specs})
		return
	var rec := specs
	var atmo := _atmosphere_sample()
	var temp_c := float(atmo.get("temp_c", 20.0))
	var rain := _rain_rate_mmh()
	# --- The farm (TerraceFarm): the paddies' stages decide which stand bare ---
	var fs: Dictionary = st.get("farm", {})
	if fs.is_empty():
		var saved_fs: Variant = specs.get("terrace_farm", null)
		if saved_fs is Dictionary and not (saved_fs as Dictionary).is_empty():
			fs = (saved_fs as Dictionary).duplicate(true)
		else:
			fs = _terrace_seed_farm(specs, table)
	fs = TerraceFarm.fit(fs, table)
	var fps: Array = fs["p"]
	var field_crop := str(specs.get("crop", "fallow"))
	var field_flood := bool(specs.get("flooded", true))
	var loss := PackedFloat64Array()
	loss.resize(n)
	# paddy_loss_mm_h is pure and resolves the whole field record per call:
	# worked out once per (crop, flooded, crop standing) this step.
	var loss_memo: Dictionary = {}
	for i in n:
		var lrow: Array = table[i]
		var stg := str((fps[i] as Dictionary).get("st", ""))
		var l_crop := str(lrow[6]) if lrow.size() > 6 else field_crop
		var l_flood := bool(lrow[7]) if lrow.size() > 7 else field_flood
		var l_grow := stg == TerraceFarm.STAGE_GROW or stg == TerraceFarm.STAGE_HARVEST
		var lk: Array = [l_crop, l_flood, l_grow]
		if not loss_memo.has(lk):
			loss_memo[lk] = TerraceField.paddy_loss_mm_h(rec, l_crop, l_flood, temp_c, l_grow)
		loss[i] = float(loss_memo[lk])
	# --- The intake: the store on water_in, as much as the gate asks ---
	var want := TerraceField.intake_lph(rec, table, store, rain, loss, dt_hours)
	var src_id := _tank_at_port(iid, "water_in", true)
	var intake := 0.0
	var no_source := src_id.is_empty()
	var src_dry := false
	if not no_source and want > 0.0:
		# Read only: the tank's specs as they are (a migrated copy if not yet).
		var src_specs: Dictionary = _tank_specs_view(_model.get_item(src_id))
		var stl: ResourceTimeline = _timelines.get(src_id) as ResourceTimeline
		var ok: bool = _tank_has_supply(src_specs, stl, abs_h) \
				or (stl == null and bool(src_specs.get("allow_negative", false)))
		if ok:
			var avail := INF
			if not _tank_is_unlimited(src_specs) and not bool(src_specs.get("allow_negative", false)) and stl != null:
				avail = maxf(stl.level_at(abs_h) - 0.001, 0.0) * _effective_capacity_qty(src_specs)
			intake = minf(want, avail / dt_hours)
			net_rates[src_id] = float(net_rates.get(src_id, 0.0)) - intake
		else:
			src_dry = true
	var res := TerraceField.cascade_step(table, store, heads, intake, rain, loss, dt_hours)
	store = res["store"]
	var out_lph := float(res["outflow_lph"])
	var runoff := out_lph
	var out_id := _tank_at_port(iid, "water_out", false)
	if not out_id.is_empty() and out_lph > 0.0:
		var os: Dictionary = _tank_specs_view(_model.get_item(out_id))
		var otl: ResourceTimeline = _timelines.get(out_id) as ResourceTimeline
		if _tank_accepts_inflow(os, otl, abs_h):
			net_rates[out_id] = float(net_rates.get(out_id, 0.0)) + out_lph
			runoff = 0.0
	# --- The crop: each paddy's season, worked by its crew ---
	var wf_arr: Array = []
	var area := 0.0
	var wf_acc := 0.0
	for i in n:
		var wrow: Array = table[i]
		var pwf := TerraceField.paddy_water_factor(wrow, store[i])
		wf_arr.append(pwf)
		area += float(wrow[0])
		wf_acc += pwf * float(wrow[0])
	var wf := wf_acc / area if area > 0.0 else 0.0
	var built: Array = []
	for brow in table:
		built.append(float((brow as Array)[2]) > 0.0)
	var labour := str(specs.get("labour", "people"))
	var credit: Variant = specs.get("terrace_credit", {})
	# The tractor runs while the diesel store on fuel_in has fuel (with no
	# store wired it is bought in and counted).
	var fuel_ok := true
	if labour == "machines":
		var fid0 := _tank_at_port(iid, "fuel_in", true)
		if not fid0.is_empty():
			var fsp: Dictionary = _tank_specs_view(_model.get_item(fid0))
			fuel_ok = _tank_has_supply(fsp, _timelines.get(fid0) as ResourceTimeline, abs_h)
	var fr := TerraceFarm.step(table, fs, abs_h, dt_hours, {
		"fuel_ok": fuel_ok,
		# No live crews inside a pre-render, an A/B run or simkit: model them.
		"crews": _render_ctx_active,
		"labour": labour, "hour": fposmod(abs_h, 24.0),
		"par_wm2": SolarIrradiance.par_wm2_from_ghi(_sun_ghi_wm2()), "month": _sim_month(),
		"wf": wf_arr, "built": built,
		"credit": credit if credit is Dictionary else {}})
	fs = fr["fs"]
	fps = fs["p"]
	var led: Dictionary = fs["ledger"]
	var grown_h := float(fr["grown_kg_h"])
	# Machines burn the fuel in the store on fuel_in (else it is bought in).
	var fuel_l := float(fr["fuel_l"])
	if fuel_l > 0.0:
		var fid := _tank_at_port(iid, "fuel_in", true)
		if not fid.is_empty():
			net_rates[fid] = float(net_rates.get(fid, 0.0)) - fuel_l / dt_hours
		else:
			led["fuel_bought_l"] = float(led.get("fuel_bought_l", 0.0)) + fuel_l
	# The harvest goes to its stores as it is cut; what does not fit waits.
	var pend: Dictionary = st.get("pend", {"food": 0.0, "bio": 0.0, "straw": 0.0})
	pend["food"] = float(pend["food"]) + float(fr["food_kg"])
	pend["bio"] = float(pend["bio"]) + float(fr["biomass_kg"])
	pend["straw"] = float(pend["straw"]) + float(fr["straw_kg"])
	var food_port := TerraceField.makes_food(specs)
	var put_now := 0.0
	var waiting := ""
	if float(pend["food"]) > 0.001:
		var pf := _terrace_deliver(iid, "harvest_out", "food", float(pend["food"]), net_rates, dt_hours, abs_h)
		pend["food"] = float(pend["food"]) - pf
		led["food_kg"] = float(led.get("food_kg", 0.0)) + pf
		put_now += pf
		if float(pend["food"]) > 0.5:
			waiting = "harvest waiting — wire a food store"
	if float(pend["bio"]) > 0.001:
		var bh := "residue_out" if food_port else "harvest_out"
		var pb := _terrace_deliver(iid, bh, "biomass", float(pend["bio"]), net_rates, dt_hours, abs_h)
		pend["bio"] = float(pend["bio"]) - pb
		led["biomass_kg"] = float(led.get("biomass_kg", 0.0)) + pb
		put_now += pb
		if float(pend["bio"]) > 0.5 and waiting.is_empty():
			waiting = "harvest waiting — wire a biomass store"
	if float(pend["straw"]) > 0.001:
		var ps2 := _terrace_deliver(iid, "residue_out", "biomass", float(pend["straw"]), net_rates, dt_hours, abs_h)
		pend["straw"] = float(pend["straw"]) - ps2
		led["straw_kg"] = float(led.get("straw_kg", 0.0)) + ps2
		# Straw nobody collects is left on the field.
		if _tank_at_port(iid, "residue_out", false).is_empty():
			pend["straw"] = 0.0
	var harvested := float(specs.get("last_harvest_kg", 0.0))
	if put_now > 0.0:
		harvested = put_now
	var standing := 0.0
	var f_acc := 0.0
	var f_n := 0
	var counts := {}
	for i in n:
		var pp: Dictionary = fps[i]
		standing += float(pp.get("kg", 0.0))
		var pst := str(pp.get("st", ""))
		counts[pst] = int(counts.get(pst, 0)) + 1
		if pst == TerraceFarm.STAGE_GROW and float(pp.get("sow", -1.0)) >= 0.0:
			var pcrop := str((table[i] as Array)[6]) if (table[i] as Array).size() > 6 else field_crop
			var cyc := float(TerraceField.crop_info(pcrop)["cycle_d"]) * 24.0
			f_acc += clampf((abs_h - float(pp["sow"])) / maxf(cyc, 1.0), 0.0, 1.0)
			f_n += 1
	st["s"] = store
	st["farm"] = fs
	st["pend"] = pend
	st["standing"] = standing
	st["last_h"] = abs_h
	_terrace_state[iid] = st
	var cinfo := TerraceField.crop_info(field_crop)
	var phase := {"planted": f_n > 0, "f": f_acc / float(maxi(f_n, 1))}
	# --- Telemetry ---
	var fills: Array = []
	var spills: Array = []
	var held := 0.0
	var spill_arr: PackedFloat32Array = res["spill"]
	for i in n:
		var cap := maxf(float(table[i][2]), 1e-6)
		fills.append(snappedf(clampf(store[i] / cap, 0.0, 1.0), 0.01))
		spills.append(snappedf(float(spill_arr[i]), 10.0))
		held += store[i]
	var ff2 := float(cinfo["food"])
	specs["terrace_fill"] = fills
	specs["terrace_spill"] = spills
	specs["water_held_l"] = snappedf(held, 10.0)
	specs["inflow_lph_live"] = snappedf(intake, 1.0)
	specs["outflow_lph"] = snappedf(out_lph, 1.0)
	specs["runoff_lph"] = snappedf(runoff, 1.0)
	specs["standing_kg"] = snappedf(standing, 0.1)
	specs["last_harvest_kg"] = snappedf(harvested, 0.1)
	specs["water_factor"] = snappedf(wf, 0.01)
	specs["crop_pct"] = roundf(float(phase["f"]) * 100.0) if bool(phase["planted"]) else -1.0
	specs["biomass_kg_h"] = snappedf(grown_h, 0.0001)
	specs["food_kg_h"] = snappedf(grown_h * ff2, 0.0001)
	var jobs: Array = TerraceFarm.open_jobs(table, fs, labour)
	specs["terrace_jobs"] = jobs
	var mjobs: Array = TerraceFarm.machine_jobs(fs) if labour == "machines" else []
	specs["terrace_machine"] = mjobs
	specs["fuel_ok"] = fuel_ok
	specs["terrace_view"] = TerraceFarm.paddy_view(fs)
	specs["farm_ledger"] = TerraceFarm.ledger_summary(led)
	specs["farm_stages"] = counts
	# The whole farm state rides the graph save when a job starts or ends,
	# and once a sim-hour.
	var fseq := int(fs.get("seq", 0))
	var fhour := int(floor(abs_h))
	var save_farm := fseq != int(st.get("saved_seq", -1)) or fhour != int(st.get("saved_hour", -1))
	if save_farm:
		specs["terrace_farm"] = fs.duplicate(true)
		st["saved_seq"] = fseq
		st["saved_hour"] = fhour
	var dv := ""
	if not bool(phase["planted"]):
		dv = I18n.f("{jobs} {jobs_2} to work", {"jobs": "%d" % jobs.size(), "jobs_2": "job" if jobs.size() == 1 else "jobs"}) \
			if not jobs.is_empty() else "not planted"
	else:
		dv = I18n.f("{label} {f}% · water {wf}%", {"label": str(cinfo["label"]), "f": "%d" % (int(roundf(float(phase["f"]) * 100.0))), "wf": "%d" % (int(roundf(wf * 100.0)))})
		if not jobs.is_empty():
			dv += I18n.f(" · {jobs} {jobs_2} for the crews", {"jobs": "%d" % jobs.size(), "jobs_2": "job" if jobs.size() == 1 else "jobs"})
	if not mjobs.is_empty() and not fuel_ok:
		dv = "the diesel store is empty — the tractor has stopped"
	elif not waiting.is_empty():
		dv = waiting
	elif src_dry:
		dv += " · its water store is empty"
	elif no_source and str(specs.get("inflow_mode", "keep")) != "off":
		dv += " · rain-fed"
	specs["display_value"] = dv
	var state := GraphNodeState.RUNNING if grown_h > 0.0 else GraphNodeState.IDLE
	if had_set:
		_model.update_item(iid, {"specs": specs})
	else:
		var wkeys := ["terrace_fill", "terrace_spill", "water_held_l",
			"inflow_lph_live", "outflow_lph", "runoff_lph", "standing_kg", "last_harvest_kg",
			"water_factor", "crop_pct", "biomass_kg_h", "food_kg_h", "display_value",
			"terrace_jobs", "terrace_view", "farm_ledger", "farm_stages", "terrace_machine", "fuel_ok"]
		if save_farm:
			wkeys.append("terrace_farm")
		_write_if_changed(iid, item, specs, wkeys)
	_write_node_state(iid, specs, state)
	for conn: Dictionary in (_resource_conns_by_target_item.get(iid, []) as Array):
		var th := str(conn.get("target_handle_id", conn.get("target_handle", "")))
		if th == "water_in":
			_cache_conn_flow(str(conn.get("id", "")), intake, "water")
	for conn: Dictionary in (_resource_conns_by_source_item.get(iid, []) as Array):
		var sh := str(conn.get("source_handle_id", conn.get("source_handle", "")))
		if sh == "water_out":
			_cache_conn_flow(str(conn.get("id", "")), out_lph - runoff, "water")
		elif sh == "harvest_out":
			_cache_conn_flow(str(conn.get("id", "")), grown_h * (ff2 if ff2 > 0.0 else 1.0),
				"food" if ff2 > 0.0 else "biomass")


## The farm state a terrace starts with: a field worked for free and already
## sown (the sandbox, and a field saved before the farm work existed) is
## growing from its planting hour; any other field starts by being prepared.
func _terrace_seed_farm(specs: Dictionary, table: Array) -> Dictionary:
	var fs := TerraceFarm.fresh(table)
	var sown := float(specs.get("plant_abs_h", -1.0))
	if str(specs.get("labour", "people")) == "free" and sown >= 0.0:
		for p in fs["p"]:
			var pd: Dictionary = p
			pd["st"] = TerraceFarm.STAGE_GROW
			pd["sow"] = sown
			pd["est"] = true
	return fs


## Put `kg` of `kind` into the store on a terrace's output port over this
## step, as much as fits. Returns what went in.
func _terrace_deliver(iid: String, handle: String, kind: String, kg: float,
		net_rates: Dictionary, dt_hours: float, abs_h: float) -> float:
	var tid := _tank_at_port(iid, handle, false)
	if tid.is_empty() or kg <= 0.0:
		return 0.0
	var ts: Dictionary = (_model.get_item(tid).get("specs", {}) as Dictionary).duplicate(true)
	_rk.migrate_resource_specs(ts)
	if ResourceKinds.normalize_kind(str(ts.get("resource_kind", ""))) != kind:
		return 0.0
	var tl: ResourceTimeline = _timelines.get(tid) as ResourceTimeline
	if not _tank_accepts_inflow(ts, tl, abs_h):
		return 0.0
	var put := kg
	if not _tank_is_unlimited(ts) and not bool(ts.get("allow_negative", false)):
		var lvl: float = tl.level_at(abs_h) if tl != null else float(ts.get("level", 0.0))
		put = minf(put, maxf(0.998 - lvl, 0.0) * _effective_capacity_qty(ts))
	if put <= 0.0:
		return 0.0
	net_rates[tid] = float(net_rates.get(tid, 0.0)) + put / maxf(dt_hours, 1e-6)
	return put


## Food forest (veg overhaul Phase 10): the trees standing inside an OSM
## vegetation area, summarised by VegFoodYield into one bed node.
##
## Deliberately NOT the annual-crop model above. These are established
## perennials: rain-fed (an unwired water port is normal, not a fault), and
## their whole year of yield is delivered across the harvest window rather than
## trickled hour by hour — which is what makes a food forest read as a season
## rather than a pipe. Outside the window the node is idle and says when the
## next harvest is.
##
## Runs on the same ambient tick as everything else here, so a food forest
## harvests with the graph screen closed.
func _process_food_forest(item: Dictionary, specs: Dictionary,
		net_rates: Dictionary, dt_hours: float, abs_h: float) -> void:
	var iid := str(item.get("id", ""))
	var kg_year := maxf(float(specs.get("food_kg_per_year", 0.0)), 0.0)
	var start_doy := int(specs.get("harvest_start_doy", 1))
	var end_doy := int(specs.get("harvest_end_doy", 365))
	var doy := _sim_doy()
	specs["food_in_season"] = VegFoodYield.in_window(doy, start_doy, end_doy)

	var bio_id := _tank_at_port(iid, "biomass_out", false)
	if bio_id.is_empty():
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "unwired out"
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_OUTPUT_UNWIRED, ["biomass"])
		_model.update_item(iid, {"specs": specs})
		return
	if not bool(specs["food_in_season"]) or kg_year <= 0.0:
		var wait := VegFoodYield.days_until_harvest(doy, start_doy, end_doy)
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = I18n.f("harvest in {wait} d", {"wait": "%d" % wait}) if kg_year > 0.0 else "no yield"
		_write_node_state(iid, specs, GraphNodeState.IDLE)
		_model.update_item(iid, {"specs": specs})
		return

	var bio_item := _model.get_item(bio_id)
	var bio_specs: Dictionary = (bio_item.get("specs", {}) as Dictionary).duplicate(true)
	_rk.migrate_resource_specs(bio_specs)
	var bio_tl: ResourceTimeline = _timelines.get(bio_id) as ResourceTimeline
	if not bool(bio_specs.get("input_valve_open", true)):
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "out closed"
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_OUTPUT_UNWIRED, ["biomass"])
		_model.update_item(iid, {"specs": specs})
		return
	if not _tank_accepts_inflow(bio_specs, bio_tl, abs_h):
		# A full store during harvest is the interesting failure — the crop is
		# ready and there is nowhere to put it.
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "store full"
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_OUTPUT_FULL, ["biomass"])
		_model.update_item(iid, {"specs": specs})
		return

	var rate := VegFoodYield.harvest_rate_kg_per_hour(kg_year, start_doy, end_doy)
	if not _tank_is_unlimited(bio_specs) and dt_hours > 0.001:
		var lvl: float = bio_tl.level_at(abs_h) if bio_tl != null else float(bio_specs.get("level", 0.0))
		var cap: float = maxf(_effective_capacity_qty(bio_specs), 0.001)
		var headroom: float = maxf(0.998 - lvl, 0.0) * cap
		rate = minf(rate, headroom / dt_hours)
	if rate <= 0.0:
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "store full"
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_OUTPUT_FULL, ["biomass"])
		_model.update_item(iid, {"specs": specs})
		return

	net_rates[bio_id] = float(net_rates.get(bio_id, 0.0)) + rate
	specs["biomass_kg_h"] = rate
	specs["display_value"] = I18n.f("{rate} kg/h harvest", {"rate": "%.1f" % rate})
	_write_node_state(iid, specs, GraphNodeState.RUNNING)
	_model.update_item(iid, {"specs": specs})


## Grow-bed / plant node: Monteith LUE biomass from ambient PAR (non-blocking
## sunlight — same SoI GHI whether or not a radiant wire is drawn), gated by
## wired water (required) and optional nutrients. Credits a biomass tank.
## Biomass is a downstream consequence of sunlight — not a separate PBI.
## The mean over a bed's crops of their temperature × humidity response
## (CropPhysiology), 0..1 — a greenhouse bed's growth multiplier.
func _gh_crop_factor(mix: Variant, t_c: float, vpd: float) -> float:
	var ids := GreenhouseSpec.mix_crops(mix)
	if ids.is_empty():
		return 1.0
	var s := 0.0
	for id in ids:
		s += CropPhysiology.temp_factor(str(id), t_c) * CropPhysiology.vpd_factor(str(id), vpd)
	return s / float(ids.size())


## One greenhouse compound: its climate stepped by `dt_hours` with the built-in
## controller (GreenhouseClimate / GreenhouseControl), the house's loads
## switched to what the controller wants (so the AC draw follows), the inside
## climate written on the compound and kept for its beds. A forward integrator
## like the camps' power: a scrub back holds it, a jump past 6 h starts it again
## from the outside air. Packed: nothing runs.
func _process_greenhouse(item: Dictionary, dt_hours: float, abs_hours: float) -> void:
	var cid := str(item.get("id", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if bool(specs.get("packed_3d", false)) or not (specs.get("gh_spec", null) is Dictionary):
		_gh_climate.erase(cid)
		return
	var m := _gh_model(cid, specs)
	if m.is_empty():
		return
	var atmo := _atmosphere_sample()
	var t_out := float(atmo.get("temp_c", 15.0))
	var rh_out := float(atmo.get("humidity_pct", 60.0))
	var last := float(_gh_last_h.get(cid, -1.0))
	var sun := _gh_sun(abs_hours)
	var doy := float(sun.get("doy", 180.0))
	if not _gh_state.has(cid) or last < 0.0 or abs_hours - last > 6.0:
		_gh_state[cid] = GreenhouseClimate.initial_state(m, t_out, rh_out, doy)
	elif abs_hours < last - 1e-4:
		return
	var dt := clampf(abs_hours - last, 0.0, 6.0) if last >= 0.0 else dt_hours
	_gh_last_h[cid] = abs_hours
	if dt <= 1e-6:
		return
	var st: Dictionary = _gh_state[cid]
	var kids := GreenhouseGraph.children_by_role(_model, cid)
	var power_ok := _ac_output_available() and _gh_has_ac(cid, kids)
	var ovr := {}
	for role in ["fans", "heater", "lights", "vents"]:
		for c in kids.get(role, []):
			var man := str(((c as Dictionary).get("specs", {}) as Dictionary).get("gh_manual", ""))
			if man == "on" or man == "off":
				ovr["vent" if role == "vents" else role] = (1.0 if role == "vents" else 1) if man == "on" else 0
	var lai := 0.0
	var nb := 0
	for c in kids.get("bed", []):
		var bs: Dictionary = (c as Dictionary).get("specs", {})
		lai += GreenhouseCrops.LAI_FULL * clampf(float(bs.get("established_pct", 100.0)) / 100.0, 0.05, 1.0)
		nb += 1
	var inp := {"t_out": t_out, "rh_out": rh_out, "wind": float(atmo.get("wind_ms", 2.0)),
		"ghi": _sun_ghi_wm2(), "cloud": _sun_cloud_frac(), "sun_az": float(sun.get("az", 180.0)),
		"sun_el": float(sun.get("el", -10.0)), "rain_mmh": _rain_rate_mmh(), "doy": doy,
		"hour": float(sun.get("hour", 12.0)), "abs_h": abs_hours, "has_real": bool(atmo.get("has_real", false)),
		"power_ok": power_ok, "lai": lai / float(nb) if nb > 0 else 0.0, "override": ovr}
	var o := GreenhouseClimate.step(m, st, inp, dt)
	# The loads follow the controller (their AC draw is what the site pays).
	var want := {"fans": bool(o["fans"]), "heater": bool(o["heater"]), "lights": bool(o["lights"]),
		"vents": float(o["vent"]) > 0.02 and float(o["vent"]) < 0.98}
	for role in want:
		for c in kids.get(role, []):
			var cd: Dictionary = c
			var cs: Dictionary = cd.get("specs", {})
			var on := "on" if bool(want[role]) else "off"
			if str(cs.get("requested_state", "")) != on:
				var ns := cs.duplicate(true)
				ns["requested_state"] = on
				_model.update_item(str(cd["id"]), {"specs": ns})
	var lit := {}
	for c in kids.get("lights", []):
		var ls: Dictionary = (c as Dictionary).get("specs", {})
		if bool(o["lights"]):
			if ls.has("gh_bed"):
				lit[str(ls["gh_bed"])] = true
			else:
				for b in kids.get("bed", []):
					lit[str(((b as Dictionary).get("specs", {}) as Dictionary).get("gh_bed", ""))] = true
	var ppfd_sun := float(o["ppfd_sun"])
	var ppfd_lamp := float(m["ppfd_lights"]) if bool(o["lights"]) else 0.0
	_gh_climate[cid] = {"t_air": float(o["t_air"]), "vpd": float(o["vpd"]), "rh": float(o["rh"]),
		"par_sun_wm2": ppfd_sun / GreenhouseClimate.UMOL_PER_J_PAR,
		"par_lit_wm2": (ppfd_sun + ppfd_lamp) / GreenhouseClimate.UMOL_PER_J_PAR, "lit_beds": lit}
	var tel := {"gh_t_air": snappedf(float(o["t_air"]), 0.1), "gh_rh": snappedf(float(o["rh"]), 1.0),
		"gh_t_out": snappedf(t_out, 0.1), "gh_vent_pct": roundf(float(o["vent"]) * 100.0),
		"gh_fans": bool(o["fans"]), "gh_heater": bool(o["heater"]), "gh_lights": bool(o["lights"]),
		"gh_dli": snappedf(float(o["dli"]), 0.1), "gh_ppfd": roundf(float(o["ppfd"])),
		"gh_t_water": snappedf(float(o["t_water"]), 0.1), "gh_cond_lph": snappedf(float(o["cond_lph"]), 0.01),
		"gh_power_w": roundf(float(o["power_w"])), "gh_frost": float(o["t_air"]) < 0.0,
		"gh_power_ok": power_ok or (kids.get("fans", []).is_empty() and kids.get("heater", []).is_empty()
			and kids.get("lights", []).is_empty() and kids.get("vents", []).is_empty())}
	var changed := false
	for k in tel:
		var a: Variant = specs.get(k, null)
		var b: Variant = tel[k]
		if a == null or (b is float and absf(float(a) - float(b)) > 0.05) or (not (b is float) and a != b):
			changed = true
			break
	if changed:
		var ns2 := specs.duplicate(true)
		for k in tel:
			ns2[k] = tel[k]
		ns2["display_value"] = "%.0f °C · %d %%" % [float(o["t_air"]), int(round(float(o["rh"])))]
		_model.update_item(cid, {"specs": ns2})


## A greenhouse trades with what is wired to its ports: its own tank and
## nutrient store are topped up (to GH_TOPUP) from the stores wired into
## water_in / nutrients_in, as a gardener fills the watering tank, and the
## harvest crate and residue bin are emptied into the stores wired to
## food_out / biomass_out. Without it a plain wire into a port moves nothing
## (tanks pass contents on only when flagged jit_outflow).
const GH_TOPUP := 0.6
const GH_PORTS := {"water_in": ["tank", true], "nutrients_in": ["nutrients", true],
	"food_out": ["harvest", false], "biomass_out": ["residue", false]}


func _gh_exchange(item: Dictionary, net_rates: Dictionary, dt_hours: float, abs_h: float) -> void:
	if dt_hours <= 1e-6 or bool((item.get("specs", {}) as Dictionary).get("packed_3d", false)):
		return
	var cid := str(item.get("id", ""))
	var kids := GreenhouseGraph.children_by_role(_model, cid)
	for c in _model.connections:
		var cd: Dictionary = c
		var port := ""
		var other := ""
		if str(cd.get("target_item_id", "")) == cid:
			port = str(cd.get("target_handle_id", ""))
			other = str(cd.get("source_item_id", ""))
		elif str(cd.get("source_item_id", "")) == cid:
			port = str(cd.get("source_handle_id", ""))
			other = str(cd.get("target_item_id", ""))
		if not GH_PORTS.has(port) or bool(cd.get("severed", false)):
			continue
		var role: String = GH_PORTS[port][0]
		var inward: bool = GH_PORTS[port][1]
		if not kids.has(role):
			continue
		var inner: Dictionary = kids[role][0]
		var ext := _model.get_item(other)
		if ext.is_empty() or str(ext.get("type", "")) != "resource":
			continue
		var in_id := str(inner["id"])
		var in_specs: Dictionary = (inner.get("specs", {}) as Dictionary).duplicate(true)
		var ex_specs: Dictionary = (ext.get("specs", {}) as Dictionary).duplicate(true)
		_rk.migrate_resource_specs(in_specs)
		_rk.migrate_resource_specs(ex_specs)
		var in_kind := ResourceKinds.normalize_kind(str(in_specs.get("resource_kind", "")))
		if in_kind != ResourceKinds.normalize_kind(str(ex_specs.get("resource_kind", ""))):
			continue
		var in_tl: ResourceTimeline = _timelines.get(in_id) as ResourceTimeline
		var ex_tl: ResourceTimeline = _timelines.get(other) as ResourceTimeline
		var in_cap := maxf(_effective_capacity_qty(in_specs), 0.001)
		var in_lvl: float = in_tl.level_at(abs_h) if in_tl != null else float(in_specs.get("level", 0.0))
		var rate := 0.0
		if inward:
			var want := maxf(GH_TOPUP - in_lvl, 0.0) * in_cap
			if want <= 1e-6 or not _tank_has_supply(ex_specs, ex_tl, abs_h):
				continue
			var ex_cap := maxf(_effective_capacity_qty(ex_specs), 0.001)
			var ex_lvl: float = ex_tl.level_at(abs_h) if ex_tl != null else float(ex_specs.get("level", 0.0))
			var have := INF if _tank_is_unlimited(ex_specs) else maxf(ex_lvl, 0.0) * ex_cap
			rate = minf(want, have) / dt_hours
			net_rates[other] = float(net_rates.get(other, 0.0)) - rate
			net_rates[in_id] = float(net_rates.get(in_id, 0.0)) + rate
		else:
			var qty := maxf(in_lvl, 0.0) * in_cap
			if qty <= 1e-6 or not _tank_accepts_inflow(ex_specs, ex_tl, abs_h):
				continue
			rate = qty / dt_hours
			net_rates[in_id] = float(net_rates.get(in_id, 0.0)) - rate
			net_rates[other] = float(net_rates.get(other, 0.0)) + rate
		_cache_conn_flow(str(cd.get("id", "")), rate, ResourceKinds.normalize_kind(str(in_specs.get("resource_kind", ""))))


func _gh_model(cid: String, specs: Dictionary) -> Dictionary:
	var key := "%s|%.1f" % [str(specs.get("gh_sig", "")), float(specs.get("gh_yaw", 0.0))]
	var c: Dictionary = _gh_models.get(cid, {})
	if str(c.get("key", "")) == key:
		return c["m"]
	var d := GreenhouseDesign.solve(specs["gh_spec"])
	var monthly: Array = []
	var tree: SceneTree = _host.get_tree() if _host != null and is_instance_valid(_host) and _host.is_inside_tree() else null
	var ws: Node = tree.root.get_node_or_null("WeatherService") if tree != null else null
	if ws != null and ws.has_method("monthly_mean_temp_c"):
		monthly = ws.call("monthly_mean_temp_c")
	var m := GreenhouseClimate.model(d, {"yaw_deg": float(specs.get("gh_yaw", 0.0)), "monthly_c": monthly})
	_gh_models[cid] = {"key": key, "m": m}
	return m


## AC reaches the house when its panel (or the house's AC port) is wired.
func _gh_has_ac(cid: String, kids: Dictionary) -> bool:
	if _has_incoming_connection(cid, "ac_in") or not _connections_from_handle(cid, "ac_in").is_empty():
		return true
	for p in kids.get("panel", []):
		var pid := str((p as Dictionary).get("id", ""))
		if _has_incoming_connection(pid, "ac_in") or not _connections_from_handle(pid, "ac_in").is_empty():
			return true
	for it in _model.get_items_in_scope(str(_model.get_item(cid).get("child_scope_id", ""))):
		if str((it as Dictionary).get("type", "")) == "breaker_panel":
			var pid2 := str((it as Dictionary)["id"])
			if _has_incoming_connection(pid2, "ac_in") or not _connections_from_handle(pid2, "ac_in").is_empty():
				return true
	return false


## The sun at `abs_h` at the site: {az, el, doy, hour}.
func _gh_sun(abs_h: float) -> Dictionary:
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return {"az": 180.0, "el": -10.0, "doy": 180.0, "hour": fposmod(abs_h, 24.0)}
	var clock: Object = main_node.get("clock")
	if clock == null or not clock.has_method("abs_hours_to_date"):
		return {"az": 180.0, "el": -10.0, "doy": 180.0, "hour": fposmod(abs_h, 24.0)}
	var dd: Dictionary = clock.call("abs_hours_to_date", abs_h)
	var y := int(dd.get("year", 2026))
	var mo := int(dd.get("month", 6))
	var d := int(dd.get("day", 15))
	var tod := float(dd.get("day_time", 12.0))
	var lat := float(main_node.get("latitude")) if main_node.get("latitude") != null else 0.0
	var lon := float(main_node.get("longitude")) if main_node.get("longitude") != null else 0.0
	var jd := float(clock.call("_julian_day_utc_for", y, mo, d, tod))
	var sp := SolarPosition.get_position(lat, lon, jd)
	var doy := 0
	for i in mo - 1:
		doy += int(GreenhouseYear.DAYS_IN_MONTH[i])
	return {"az": float(sp.get("azimuth_deg", 180.0)), "el": float(sp.get("elevation_deg", -10.0)),
		"doy": float(doy + d - 1), "hour": tod}


func _process_plant(item: Dictionary, net_rates: Dictionary, dt_hours: float,
		abs_hours: float = -1.0) -> void:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var iid := str(item.get("id", ""))
	var abs_h: float = abs_hours if abs_hours >= 0.0 else _get_abs_hours()
	if abs_h < 0.0:
		abs_h = 0.0

	# Phase 10: a food forest is not an annual crop. Its trees are rain-fed
	# perennials whose whole year of yield lands inside a harvest window, so it
	# takes its own branch instead of the LUE/water-gated growth model.
	if bool(specs.get("food_forest", false)):
		_process_food_forest(item, specs, net_rates, dt_hours, abs_h)
		return
	# A terraced field holds its own water in its paddies (TerraceField).
	if specs.has("terrace_id"):
		_process_terrace(item, specs, net_rates, dt_hours, abs_h)
		return

	# A plant with an edible share (food_fraction) makes FOOD on its output
	# port; the rest of the library's plants make biomass (firewood).
	var food_frac := clampf(float(specs.get("food_fraction", 0.0)), 0.0, 1.0)
	var out_kind := "food" if food_frac > 0.0 else "biomass"
	specs["food_kg_h"] = 0.0
	var ghi := _sun_ghi_wm2()
	var par := SolarIrradiance.par_wm2_from_ghi(ghi)
	var area := PlantGrowthScript.effective_area_m2(specs, _soi_area_m2())
	var sun_f := PlantGrowthScript.sunlight_factor_from_specs(specs)
	var lue := PlantGrowthScript.lue_from_specs(specs)
	var month := _sim_month()
	var season := PlantGrowthScript.season_for_specs(specs)
	# A bed in a greenhouse grows from the house's inside climate: the light
	# through the glazing (plus its lamps when lit), and its crops' response
	# to the inside temperature and humidity in place of the outdoor season.
	var gh: Dictionary = _gh_climate.get(str(item.get("parent_compound_id", "")), {})
	if specs.has("gh_bed") and not gh.is_empty():
		var lit := bool((gh.get("lit_beds", {}) as Dictionary).get(str(specs["gh_bed"]), false))
		par = float(gh["par_lit_wm2"]) if lit else float(gh["par_sun_wm2"])
		sun_f = 1.0
		season = _gh_crop_factor(specs.get("gh_crops", "garden"), float(gh["t_air"]), float(gh["vpd"]))
		specs["gh_t_air"] = snappedf(float(gh["t_air"]), 0.1)
	var potential := PlantGrowthScript.potential_biomass_kg_h(par, area, lue, month, season) * sun_f
	# A bed built from its kit is sown then and comes up over establish_days
	# (the processor rule, establish_factor): nothing before it is planted.
	var est := establish_factor(specs, abs_h)
	if bool(specs.get("packed_3d", false)):
		# Its bed is still a kit: nothing is planted yet.
		est = -1.0
	if est < 0.0:
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = "not planted"
		_write_node_state(iid, specs, GraphNodeState.IDLE)
		_model.update_item(iid, {"specs": specs})
		return
	if specs.has("establish_days"):
		specs["established_pct"] = roundf(est * 100.0)

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
	if ResourceKinds.normalize_kind(str(bio_specs.get("resource_kind", ""))) != out_kind:
		# Strict: the output tank must hold what the plant makes (a food
		# store for a vegetable bed, a biomass store for everything else).
		specs["biomass_kg_h"] = 0.0
		specs["display_value"] = I18n.f("need {out_kind} tank", {"out_kind": out_kind})
		_write_node_state(iid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_OUTPUT_UNWIRED, [out_kind])
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

	var grown := PlantGrowthScript.biomass_kg_per_hour(
			par, area, lue, month, water_factor, nutrient_factor, sun_f, season) * est
	var rate := grown
	if out_kind == "food":
		rate *= food_frac   # the edible share of what grew
	# The rest of a food crop (stalks, leaves, vines, roots) goes to a biomass
	# store on residue_out when one is wired (compost, the digester), else it
	# is left on the bed.
	var residue_id := ""
	var residue_rate := 0.0
	if out_kind == "food":
		residue_id = _tank_at_port(iid, "residue_out", false)
		if not residue_id.is_empty():
			var rs: Dictionary = (_model.get_item(residue_id).get("specs", {}) as Dictionary).duplicate(true)
			_rk.migrate_resource_specs(rs)
			var rtl: ResourceTimeline = _timelines.get(residue_id) as ResourceTimeline
			if ResourceKinds.normalize_kind(str(rs.get("resource_kind", ""))) == "biomass" 					and bool(rs.get("input_valve_open", true)) and _tank_accepts_inflow(rs, rtl, abs_h):
				residue_rate = grown * (1.0 - food_frac)
			else:
				residue_id = ""
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

	# A food crop drinks and feeds for the whole plant it grows, not only the
	# share that is eaten (the rate is capped by the store's headroom above,
	# so scale the whole plant by the same cap).
	var whole := rate / food_frac if out_kind == "food" and food_frac > 0.0 else rate
	var water_lph := PlantGrowthScript.water_demand_lph(
			whole, PlantGrowthScript.water_l_per_kg_from_specs(specs))
	var nut_kgph := 0.0
	if nutrients_wired:
		nut_kgph = PlantGrowthScript.nutrient_demand_kgph(
				whole, PlantGrowthScript.nutrient_kg_per_kg_from_specs(specs))
	if not residue_id.is_empty():
		residue_rate = whole * (1.0 - food_frac)
		net_rates[residue_id] = float(net_rates.get(residue_id, 0.0)) + residue_rate

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
		# Match the wire by the PORT it lands on (or the tank the plant draws
		# from), not by kind: a bed on reclaimed water ("irrigation_water")
		# or rainwater drinks through its water_in port too, and matching
		# "water" only left those wires reading zero while the tank emptied.
		var th := str(conn.get("target_handle_id", conn.get("target_handle", "")))
		var from_id := str(conn.get("source_item_id", ""))
		if th == "nutrients_in" or (nutrients_wired and from_id == nutrient_id):
			_cache_conn_flow(str(conn.get("id", "")), nut_kgph, "nutrients")
		elif th == "water_in" or (from_id == water_id and rk != "sunlight"):
			_cache_conn_flow(str(conn.get("id", "")), water_lph, rk if not rk.is_empty() else "water")
		elif rk == "sunlight":
			# Radiant wire is informational — animate at PAR×area (kW of PAR).
			_cache_conn_flow(str(conn.get("id", "")), par * area / 1000.0, "sunlight")
	for conn: Dictionary in (_resource_conns_by_source_item.get(iid, []) as Array):
		if str(conn.get("source_handle_id", conn.get("source_handle", ""))) == "residue_out":
			_cache_conn_flow(str(conn.get("id", "")), residue_rate, "biomass")
		else:
			_cache_conn_flow(str(conn.get("id", "")), rate, out_kind)

	specs["biomass_kg_h"] = rate
	specs["food_kg_h"] = rate if out_kind == "food" else 0.0
	specs["residue_kg_h"] = residue_rate
	specs["water_lph"] = water_lph
	specs["nutrient_kgph"] = nut_kgph
	if rate >= 0.01:
		specs["display_value"] = I18n.f("{rate} kg/h", {"rate": "%.2f" % rate})
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
	# Pond surface + DEM watershed catchments rain-feed directly (no Rain-PBI wire).
	# Culvert stage-discharge outflows are applied separately (Phase 3).
	var pond_direct := kind == "pond" or kind == "watershed"
	# A structure's own roof (a greenhouse, an Earthship) catches the rain that
	# falls on it with no Rain-PBI wire, like a pond's surface.
	var roof_direct := kind == "roof" or specs.has("structure_water") or str(specs.get("gh_role", "")) == "roof"
	# Rain catchments require an inbound wire from a Rain PBI node.
	if not pond_direct and not roof_direct and not _catchment_has_pbi_feed(item, "water"):
		specs["live_capture_lph"] = 0.0
		_write_if_changed(str(item.get("id", "")), item, specs, ["live_capture_lph"])
		return
	var area_m2: float = _catchment_area_m2(specs)
	# A hillside catchment and a mapped stream into the same pond drain the SAME
	# ground: the stream already carries its upstream area's runoff, so that
	# part of the watershed must not be counted again.
	if kind == "watershed":
		var covered := _stream_area_into_targets(str(item.get("id", "")))
		specs["stream_covered_m2"] = covered
		area_m2 = maxf(area_m2 - covered, 0.0)
	var runoff: float = float(specs.get("runoff_coeff", 0.85 if not pond_direct else 1.0))
	var rain_mmh := _rain_rate_mmh()
	# mm/h * m² = L/h (1 mm on 1 m² = 1 L)
	var capture_lph: float = area_m2 * runoff * maxf(rain_mmh, 0.0)
	specs["live_capture_lph"] = capture_lph
	_write_if_changed(str(item.get("id", "")), item, specs, ["live_capture_lph", "stream_covered_m2"])
	if capture_lph <= 0.0:
		return
	var abs_h: float = abs_hours if abs_hours >= 0.0 else _get_abs_hours()
	if abs_h < 0.0:
		abs_h = 0.0
	_credit_catchment_flow(item, net_rates, capture_lph, "rainwater", dt_hours, abs_h)


## Auto pond capacity: prefer TerrainLoader bathymetry over stale import estimate.
func _pond_fill_capacity_l(ts: Dictionary) -> float:
	var fallback := maxf(float(ts.get("capacity_qty", 0.0)), 0.001)
	if str(ts.get("capacity_mode", "auto")) == "manual":
		return fallback
	var tag := str(ts.get("osm_water_tag", ""))
	var pid := str(ts.get("pond_id", ""))
	if (tag.is_empty() and pid.is_empty()) or _host == null:
		return fallback
	var loader: Node = null
	if _host.has_method("_find_terrain_loader") and _host.has_method("_get_scene_main_node"):
		loader = _host.call("_find_terrain_loader", _host.call("_get_scene_main_node"))
	if loader == null or not loader.has_method("get_pond_info"):
		return fallback
	# Prefer the stable pond_id (immune to osm_water_tag drift after a re-carve —
	# the tag is a centroid/bbox hash, so resizing a pond changes it while pond_id
	# stays put). Fall back to the tag for legacy tanks with no id yet.
	var idx := -1
	if not pid.is_empty() and loader.has_method("find_pond_idx_by_id"):
		idx = int(loader.call("find_pond_idx_by_id", pid))
	if idx < 0 and not tag.is_empty() and loader.has_method("find_pond_idx_by_tag"):
		idx = int(loader.call("find_pond_idx_by_tag", tag))
	if idx < 0:
		return fallback
	var info: Dictionary = loader.call("get_pond_info", idx) as Dictionary
	if not bool(info.get("valid", false)):
		return fallback
	var terrain_cap := maxf(float(info.get("terrain_capacity_l",
			info.get("capacity_l", 0.0))), 0.0)
	return maxf(terrain_cap, fallback)


## Siphon micro-hydro processors: prime/break latch from pond level vs intake
## crown/invert; debit pond + credit downstream water; set current_output_kw
## for DcPowerWiring → 48V battery.

## True when any siphon has Lab Test Inflow armed.
func _lab_sim_inflow_active() -> bool:
	if _model == null:
		return false
	for item: Dictionary in _model.items:
		if str(item.get("type", "")) != "processor":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("role", "")) != "siphon_hydro":
			continue
		if bool(specs.get("lab_sim_inflow_enabled", false)) \
				and float(specs.get("lab_sim_inflow_lps", 0.0)) > 1e-9:
			return true
	return false


## Credit (or debit via siphon Q) pond tanks while the world clock is frozen.
## Uses wall seconds × LAB_PAUSE_FILL_SCALE so 500 L/s is visibly responsive
## under Elev noon-lock / pause without advancing celestial time.
func _apply_lab_sim_inflow_realtime(wall_dt_s: float) -> void:
	if _model == null or wall_dt_s <= 1e-6:
		return
	var dt_s := wall_dt_s * LAB_PAUSE_FILL_SCALE
	var abs_hours := _get_abs_hours()
	for item: Dictionary in _model.items:
		if str(item.get("type", "")) != "processor":
			continue
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		if str(specs.get("role", "")) != "siphon_hydro":
			continue
		if not bool(specs.get("lab_sim_inflow_enabled", false)):
			continue
		if bool(specs.get(HydroSource.SPEC_OFF, false)):
			continue  # switched off: the forward tick keeps it idle
		var sim_lps := maxf(float(specs.get("lab_sim_inflow_lps", 0.0)), 0.0)
		if sim_lps <= 1e-9:
			continue
		# STREAM tap: there is no pond to fill, so the test flow is the supply
		# itself and the answer is instantaneous. Re-evaluating here is what makes
		# dragging the Lab's test L/s move the power NOW rather than only once the
		# clock is unfrozen — with the clock frozen (paused) nothing ticks, so without this the
		# knob looks completely inert, which is exactly how it was reported.
		if not _stream_intake_for(item).is_empty():
			var dt_h_stream := (wall_dt_s * LAB_PAUSE_FILL_SCALE) / 3600.0
			_resolve_penstock_supply_lps(item, specs, dt_h_stream)
			_adopt_penstock_conn(item, specs)
			var sink_rates := {}
			_process_spec_driven_hydro(item, specs, str(item.get("id", "")),
					sink_rates, dt_h_stream)
			continue
		var tank := _resolve_siphon_inlet_tank(item)
		if tank.is_empty():
			continue
		var tid := str(tank.get("id", ""))
		var ts: Dictionary = (tank.get("specs", {}) as Dictionary).duplicate(true)
		var floor_y := float(ts.get("floor_m", NAN))
		var rim := float(ts.get("rim_m", NAN))
		# Prefer live DEM bathymetric capacity so Test Inflow can fill the
		# sculpted basin (import area×mean_depth often under-sizes capacity).
		var cap := _pond_fill_capacity_l(ts)
		var level_m := float(ts.get("level_m", NAN))
		if is_nan(level_m) and not is_nan(rim) and not is_nan(floor_y):
			level_m = floor_y + clampf(float(ts.get("level", 0.0)), 0.0, 1.0) \
					* maxf(rim - floor_y, 0.05)
		if is_nan(level_m):
			continue
		_ensure_siphon_inverts(item, specs, tank)
		# Same shared reach + dead-pool clamp as the world-clock path, so both
		# integrators conserve mass identically (no divergent semantics).
		var stock := float(ts.get("stock_l", NAN))
		if is_nan(stock):
			stock = clampf(float(ts.get("level", 0.0)), 0.0, 1.0) * cap
		_reach.configure_siphon(specs)
		_reach.set_pond(floor_y, rim, cap, stock)
		var r := _reach.evaluate(level_m)
		var dt_hours := dt_s / 3600.0
		# Clamp the drain to the stock above the air-break (never suck the pond dry).
		var q_out := maxf(_reach.drainable_lph(maxf(float(r.get("q_lph", 0.0)), 0.0),
			maxf(dt_hours, 0.0)), 0.0) / 3600.0
		var net_lps := sim_lps - q_out
		stock = clampf(stock + net_lps * dt_s, 0.0, cap)
		var frac := clampf(stock / cap, 0.0, 1.0)
		ts["stock_l"] = stock
		ts["level"] = frac
		if str(ts.get("capacity_mode", "auto")) != "manual":
			ts["capacity_qty"] = cap
			ts["capacity"] = "%.0f L" % cap
		ts["inflow_rate"] = sim_lps * 3600.0
		ts["outflow_rate"] = q_out * 3600.0
		# Linear Elev fallback; push_pond_levels_to_mesh writes bathymetric level_m.
		if not is_nan(rim) and not is_nan(floor_y):
			var span := maxf(rim - floor_y, 0.05)
			ts["level_m"] = floor_y + frac * span
			level_m = float(ts["level_m"])
		_model.update_item(tid, {"specs": ts})
		if _timelines.has(tid):
			var tl: ResourceTimeline = _timelines[tid] as ResourceTimeline
			# Re-point the present level without discarding pre-pause history so
			# scrubbing back over earlier real recording still works (was a
			# destructive clear()+init_anchor).
			tl.set_current_level(abs_hours if abs_hours >= 0.0 else 0.0, frac)
		# Keep Lab readouts live while paused (PE / RPM / prime). Reuse the shared
		# reach at the post-fill level (no per-tick HydroReach.new()).
		var proc_id := str(item.get("id", ""))
		var r2 := _reach.evaluate(level_m)
		specs["siphon_primed"] = bool(r2.get("primed", false))
		specs["live_q_lps"] = float(r2.get("q_lps", 0.0))
		specs["live_head_m"] = float(r2.get("head_m", 0.0))
		specs["live_pe_w"] = float(r2.get("pe_w", 0.0))
		specs["live_rpm"] = float(r2.get("rpm", 0.0))
		specs["live_power_w"] = float(r2.get("power_w", 0.0))
		specs["current_output_kw"] = float(r2.get("power_kw", 0.0))
		specs["live_regime"] = str(r2.get("regime", ""))
		_model.update_item(proc_id, {"specs": specs})
		# Outlet sink cumulative (wall-time drain) — credit exactly the clamped
		# drain that left the pond, so the sink can't accrue phantom litres.
		var q_lph := q_out * 3600.0
		if q_lph > 1e-6:
			var down := _resolve_siphon_outlet_tank(item)
			if not down.is_empty():
				var oid := str(down.get("id", ""))
				var ds: Dictionary = (down.get("specs", {}) as Dictionary).duplicate(true)
				if bool(ds.get("outlet_sink", false)) or bool(ds.get("unlimited_capacity", false)):
					var add_l := q_lph * (dt_s / 3600.0)
					ds["cumulative_l"] = float(ds.get("cumulative_l", 0.0)) + add_l
					ds["live_in_lps"] = q_lph / 3600.0
					ds["stock_l"] = float(ds["cumulative_l"])
					_model.update_item(oid, {"specs": ds})
			_stamp_siphon_outlet_culvert_flow(proc_id, q_lph, q_out)


func _process_siphon_hydro(net_rates: Dictionary, dt_hours: float,
		_abs_hours: float) -> void:
	if _model == null:
		return
	_stream_diversions.clear()
	for item: Dictionary in _model.items_of_type("processor"):
		# Role check on the live dict first — the deep copy used to be taken
		# for EVERY processor before the role was looked at.
		if str((item.get("specs", {}) as Dictionary).get("role", "")) != "siphon_hydro":
			continue
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		var proc_id := str(item.get("id", ""))
		if bool(specs.get(HydroSource.SPEC_OFF, false)):
			_idle_switched_off_turbine(item, specs, proc_id)
			continue
		var tank := _resolve_siphon_inlet_tank(item)
		var kind_meta := HydroSource.kind_meta(str(specs.get("turbine_kind", "siphon")))
		# A ROUTED penstock is the authority for its own geometry regardless of
		# what feeds it — adopt run length / bore / inverts BEFORE deciding how
		# this turbine is driven, so a stream-intake source (which has no water
		# LEVEL, only an elevation) still gets a real gross head.
		var specs_dirty := _adopt_penstock_conn(item, specs)
		# Available water at a tapped stream/spring, resolved AFTER the head is
		# adopted and BEFORE the pond decision — the spec-driven branch below needs
		# it, and so does HydroReach when the source has no level to draw down.
		# NAN (no stream intake) leaves the legacy design-flow behaviour alone.
		if not is_nan(_resolve_penstock_supply_lps(item, specs, dt_hours)):
			specs_dirty = true
		# A "tank" with no resolvable water level is a source, not a reservoir
		# (a stream intake) — it cannot drive the pond drawdown path.
		var pond_level := _pond_level_of(tank)
		var has_pond := not tank.is_empty() and not is_nan(pond_level)
		# Streaming kinds (pond_drawdown false — run-of-river) never drain
		# storage, and a PENSTOCK-kind turbine with no pond runs SPEC-DRIVEN:
		# the legacy type=="hydro" estimator physics, unified here in Phase B so
		# migrated estimator nodes keep producing. Neither moves any water.
		# NOTE the penstock case is unconditional (no gross-head gate): a
		# turbine whose intake sits BELOW it must still take this branch so its
		# telemetry is honestly ZEROED — the old gate sent it to the reach path,
		# which bailed on the levelless intake without touching live_q_lps, and
		# the stale flow kept the tailwater jet running forever.
		var spec_driven := not bool(kind_meta.get("pond_drawdown", true)) \
				or (not has_pond and bool(kind_meta.get("has_penstock", false)))
		if spec_driven:
			_process_spec_driven_hydro(item, specs, proc_id, net_rates, dt_hours)
			continue
		if specs_dirty and not tank.is_empty():
			_model.update_item(proc_id, {"specs": specs})
		if tank.is_empty():
			var was_q := float(specs.get("live_q_lps", 0.0))
			var was_kw := float(specs.get("current_output_kw", 0.0))
			var was_primed := bool(specs.get("siphon_primed", false))
			specs["live_q_lps"] = 0.0
			specs["current_output_kw"] = 0.0
			specs["live_power_w"] = 0.0
			specs["live_rpm"] = 0.0
			specs["siphon_primed"] = false
			# A catchment can't feed a turbine directly — it's a rain-rate source
			# with no water level for the head/prime math. The player has to store
			# the runoff in a pond first. Give that specific guidance instead of
			# the generic "wire pond storage" when a catchment is what's wired.
			if _siphon_water_in_is_catchment(proc_id):
				# A real wiring mistake, not an unprovisioned node: BLOCKED with
				# its own reason code, so the chip, the inspector and the
				# education card (GraphEducationCards.card_for_fault) can name
				# it. It used to idle with a free-text reason nobody surfaced.
				_write_node_state(proc_id, specs, GraphNodeState.BLOCKED,
						GraphNodeState.REASON_CATCHMENT_DIRECT, ["water"])
			else:
				_write_node_state(proc_id, specs, GraphNodeState.IDLE, "Wire pond storage → water in", [])
			if was_q > 1e-6 or was_kw > 1e-6 or was_primed \
					or str(specs.get("node_state", "")) != str(
						(item.get("specs", {}) as Dictionary).get("node_state", "")):
				_model.update_item(proc_id, {"specs": specs})
			continue
		var tank_specs: Dictionary = tank.get("specs", {}) as Dictionary
		var tank_id := str(tank.get("id", ""))
		# Test inflow: optional steady fill into the inlet pond, advanced on the
		# world clock like everything else (no rain / watershed required). This is
		# the ONLY manual water driver — L/s → L/h for the tank integrator.
		if bool(specs.get("lab_sim_inflow_enabled", false)) and not tank_id.is_empty():
			var sim_lps := maxf(float(specs.get("lab_sim_inflow_lps", 0.0)), 0.0)
			if sim_lps > 1e-9:
				# Heal under-sized import capacity so the tank can fill the basin.
				var heal_cap := _pond_fill_capacity_l(tank_specs)
				if heal_cap > maxf(float(tank_specs.get("capacity_qty", 0.0)), 0.0) + 1.0 \
						and str(tank_specs.get("capacity_mode", "auto")) != "manual":
					var heal_ts: Dictionary = tank_specs.duplicate(true)
					heal_ts["capacity_qty"] = heal_cap
					heal_ts["capacity"] = "%.0f L" % heal_cap
					_model.update_item(tank_id, {"specs": heal_ts})
					tank_specs = heal_ts
				net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) + sim_lps * 3600.0
		var level_m := float(tank_specs.get("level_m", NAN))
		if is_nan(level_m):
			var rim := float(tank_specs.get("rim_m", NAN))
			var floor_y := float(tank_specs.get("floor_m", NAN))
			if not is_nan(rim) and not is_nan(floor_y):
				level_m = floor_y + clampf(float(tank_specs.get("level", 0.0)), 0.0, 1.0) \
						* maxf(rim - floor_y, 0.05)
		if is_nan(level_m):
			# The "tank" carries no water level (a levelless source wired to a
			# siphon). Zero the telemetry before skipping — a bare `continue`
			# left the last forward frame's live_q_lps frozen, which kept the
			# tailwater jet (and every readout) running forever.
			if float(specs.get("live_q_lps", 0.0)) > 1e-6 \
					or float(specs.get("current_output_kw", 0.0)) > 1e-9:
				specs["live_q_lps"] = 0.0
				specs["current_output_kw"] = 0.0
				specs["live_power_w"] = 0.0
				specs["live_rpm"] = 0.0
				specs["siphon_primed"] = false
				_model.update_item(proc_id, {"specs": specs})
			continue
		var orig := (item.get("specs", {}) as Dictionary).duplicate(true)
		_ensure_siphon_inverts(item, specs, tank)
		# Unified reach physics (single source of truth) — same path the Siphon Lab
		# reads, incl. the effective air-break override. Pond storage still moves
		# through net_rates below (the generic tank integrator owns tank stock), but
		# the DRAIN is clamped through the shared reach so the pond is never pulled
		# below the air-break dead pool and the outlet is credited exactly what the
		# pond gave (mass-conserving even on a big-dt tick at high time_scale).
		_reach.configure_siphon(specs)
		var pond_cap := _pond_fill_capacity_l(tank_specs)
		var pond_stock := float(tank_specs.get("stock_l", NAN))
		if is_nan(pond_stock):
			pond_stock = clampf(float(tank_specs.get("level", 0.0)), 0.0, 1.0) * pond_cap
		_reach.set_pond(float(tank_specs.get("floor_m", NAN)),
			float(tank_specs.get("rim_m", NAN)), pond_cap, pond_stock)
		var reach_curve: Variant = tank_specs.get("stage_curve", null)
		if reach_curve is Array:
			_reach.set_stage_curve(reach_curve as Array)
		var r := _reach.evaluate(level_m)
		# Mirror resolved start/break back onto specs (keeps modal + hydraulics synced).
		var start_m := float(r.get("siphon_start_m", NAN))
		var break_m := float(r.get("siphon_break_m", NAN))
		if not is_nan(start_m):
			specs["siphon_start_m"] = start_m
			specs["intake_crown_m"] = start_m
		if not is_nan(break_m):
			specs["siphon_break_m"] = break_m
			specs["intake_invert_m"] = break_m
		specs["siphon_primed"] = bool(r.get("primed", false))
		specs["live_q_lps"] = float(r.get("q_lps", 0.0))
		specs["live_head_m"] = float(r.get("head_m", 0.0))
		specs["live_pe_w"] = float(r.get("pe_w", 0.0))
		specs["live_rpm"] = float(r.get("rpm", 0.0))
		specs["live_power_w"] = float(r.get("power_w", 0.0))
		specs["current_output_kw"] = float(r.get("power_kw", 0.0))
		specs["live_regime"] = str(r.get("regime", ""))
		# Mass-conserving drain: the hydraulically-evaluated flow clamped to the
		# stock above the dead pool this step. At steady state drained == q_lph
		# (no-op); only the crossing tick is clamped. This value — not raw q_lph —
		# drives every water transfer so the outlet balances the pond exactly.
		var q_lph := float(r.get("q_lph", 0.0))
		var drained_lph := _reach.drainable_lph(q_lph, maxf(dt_hours, 0.0))
		var q_lps := drained_lph / 3600.0
		# Watts follow the water that ACTUALLY moved. The reach reports the
		# operating point at this level; a near-empty source (or the crossing
		# tick into the dead pool) passes less, and an empty one passes none —
		# without this a turbine fed by an empty tank reported full power and
		# charged the battery with water that never existed. Paused (dt 0):
		# honest only if the source could sustain the flow for one second.
		var water_frac := 1.0
		if q_lph > 1e-6:
			if dt_hours > 1e-9:
				water_frac = clampf(drained_lph / q_lph, 0.0, 1.0)
			elif _reach.drainable_lph(q_lph, 1.0 / 3600.0) < q_lph * 0.999:
				water_frac = 0.0
				drained_lph = 0.0
				q_lps = 0.0
		if water_frac < 0.9999:
			specs["live_power_w"] = float(specs.get("live_power_w", 0.0)) * water_frac
			specs["current_output_kw"] = float(specs.get("current_output_kw", 0.0)) * water_frac
			specs["live_q_lps"] = q_lps
			if water_frac <= 1e-6:
				specs["live_rpm"] = 0.0
		# Stamp water I/O rates for port labels (L/h) — the effective moved flow.
		var inputs: Array = specs.get("inputs", []) as Array
		var outputs: Array = specs.get("outputs", []) as Array
		if not inputs.is_empty() and inputs[0] is Dictionary:
			(inputs[0] as Dictionary)["rate"] = drained_lph
		for oi in outputs.size():
			if not (outputs[oi] is Dictionary):
				continue
			var od: Dictionary = outputs[oi]
			if str(od.get("kind", "")) == "water":
				od["rate"] = drained_lph
			elif str(od.get("kind", "")) == "dc_electricity":
				od["rate"] = float(specs.get("current_output_kw", 0.0))
		specs["inputs"] = inputs
		specs["outputs"] = outputs
		var new_state := GraphNodeState.IDLE
		if drained_lph > 1e-6:
			new_state = GraphNodeState.RUNNING
			var src_id := str(tank.get("id", ""))
			net_rates[src_id] = float(net_rates.get(src_id, 0.0)) - drained_lph
			_credit_outlet_sink(_resolve_siphon_outlet_tank(item), net_rates,
					drained_lph, dt_hours, src_id)
			_stamp_siphon_outlet_culvert_flow(proc_id, drained_lph, q_lps)
		else:
			_stamp_siphon_outlet_culvert_flow(proc_id, 0.0, 0.0)
			if bool(r.get("primed", false)):
				new_state = GraphNodeState.READY
		_write_node_state(proc_id, specs, new_state)
		const EPS := 0.002
		var changed := str(specs.get("node_state", "")) != str(orig.get("node_state", "")) \
			or bool(specs.get("siphon_primed", false)) != bool(orig.get("siphon_primed", false)) \
			or absf(float(specs.get("live_q_lps", 0.0)) - float(orig.get("live_q_lps", 0.0))) > EPS \
			or absf(float(specs.get("current_output_kw", 0.0)) - float(orig.get("current_output_kw", 0.0))) > 1e-5 \
			or absf(float(specs.get("live_head_m", 0.0)) - float(orig.get("live_head_m", 0.0))) > EPS \
			or absf(float(specs.get("siphon_start_m", 0.0)) - float(orig.get("siphon_start_m", 0.0))) > EPS \
			or absf(float(specs.get("siphon_break_m", 0.0)) - float(orig.get("siphon_break_m", 0.0))) > EPS \
			or absf(float(specs.get("live_rpm", 0.0)) - float(orig.get("live_rpm", 0.0))) > 0.5
		var mod_e := float(specs.get("module_elev_m", NAN))
		var elev_target := mod_e if not is_nan(mod_e) else break_m
		var elev_patch := {}
		if not is_nan(elev_target) \
				and absf(float(item.get("elevation_m", NAN)) - elev_target) > EPS:
			elev_patch["elevation_m"] = elev_target
		if changed:
			elev_patch["specs"] = specs
			_model.update_item(proc_id, elev_patch)
		elif not elev_patch.is_empty():
			_model.update_item(proc_id, elev_patch)


## Deliver `lph` litres/hour of tailwater into a turbine's downstream sink: the
## net_rates credit plus the sink's own cumulative/live readouts. Shared by the
## pond drawdown path and the tapped-stream path so the two can never book the
## same water differently. `skip_id` guards the degenerate self-wire.
func _credit_outlet_sink(down: Dictionary, net_rates: Dictionary, lph: float,
		dt_hours: float, skip_id: String = "") -> void:
	if down.is_empty() or lph <= 1e-9:
		return
	var tid := str(down.get("id", ""))
	if tid.is_empty() or tid == skip_id:
		return
	net_rates[tid] = float(net_rates.get(tid, 0.0)) + lph
	var ds: Dictionary = (down.get("specs", {}) as Dictionary).duplicate(true)
	if not (bool(ds.get("outlet_sink", false))
			or bool(ds.get("unlimited_capacity", false))):
		return
	var prev_cum := float(ds.get("cumulative_l", 0.0))
	var next_cum := prev_cum + lph * maxf(dt_hours, 0.0)
	var next_lps := lph / 3600.0
	# Sink cumulative — write every lab/minute step (was a 0.5 L gate which hid
	# short Lab ticks).
	if next_cum - prev_cum > 1e-4 \
			or absf(next_lps - float(ds.get("live_in_lps", 0.0))) > 1e-6:
		ds["cumulative_l"] = next_cum
		ds["live_in_lps"] = next_lps
		# Mirror stock so the freeform card isn't stuck at 0.00 L.
		ds["level"] = 0.0
		ds["stock_l"] = next_cum
		_model.update_item(tid, {"specs": ds})


## Spec-driven ("estimator") hydro output: power from the authored gross_head_m
## / design_flow_lps via the SAME physics the legacy type=="hydro" estimator ran
## in _tick_graph_renewables before Phase B unified turbines onto this processor
## (HydroSource.power_kw_from_graph_specs — Darcy–Weisbach penstock losses +
## per-kind efficiency + monthly flow multipliers), so migrated saves keep their
## numbers. Computed here so it runs ambient AND inside prebaked challenge bakes
## (_sim_month respects the render context).
##
## WATER: run-of-river STREAMS THE RIVER THROUGH — it neither consumes an upstream
## stock nor delivers metered water downstream, because the river is not a resource
## the graph owns and crediting a sink from it would conjure water out of the
## landscape. A TAPPED supply through a penstock is the opposite: the intake
## diverts a measured Q, the turbine passes it, and the tailrace really does
## deliver it. The distinction is the kind's `pond_drawdown` flag. (An intake
## marked `unlimited_capacity` — every stream intake — is never debited: a spring
## is not a stock the player can empty.)
func _process_spec_driven_hydro(item: Dictionary, specs: Dictionary,
		proc_id: String, net_rates: Dictionary = {},
		dt_hours: float = 0.0) -> void:
	var orig: Dictionary = item.get("specs", {}) as Dictionary
	var month := _sim_month()
	var wx_mults := _monthly_precip_multipliers()
	var kw := 0.0
	var q_lps := 0.0
	# Packed 3D twin: a crated turbine generates nothing (same gate the old
	# estimator tick applied).
	if not bool(specs.get("packed_3d", false)):
		kw = HydroSource.power_kw_from_graph_specs(specs, month, wx_mults)
		# The OPERATING flow, not the design-flow knob: a PowerSpout's flow
		# comes from its nozzle at the current head (design_flow is 0), and a
		# turbine producing nothing flows nothing — live_q_lps drives the
		# tailwater jet, so a phantom flow here is a phantom waterfall.
		q_lps = HydroSource.operating_flow_lps_from_graph_specs(specs, month, wx_mults)
	if kw <= 1e-9:
		q_lps = 0.0
	var head_m := maxf(float(specs.get("gross_head_m", 0.0)), 0.0)
	specs["siphon_primed"] = kw > 1e-6
	specs["live_q_lps"] = q_lps
	specs["live_head_m"] = head_m
	# PE at gross head (loss-free potential); electrical is the physics number.
	specs["live_pe_w"] = 1000.0 * 9.80665 * (q_lps / 1000.0) * head_m
	specs["live_power_w"] = kw * 1000.0
	specs["current_output_kw"] = kw
	specs["live_rpm"] = SiphonHydraulics.omega_from_pe_w(
			float(specs.get("live_pe_w", 0.0))) * 60.0 / TAU if kw > 1e-6 else 0.0
	specs["live_regime"] = "spec"
	# A tapped penstock supply really moves water; a run-of-river does not.
	var kind_meta := HydroSource.kind_meta(
			str(specs.get("turbine_kind", specs.get("kind", "pelton"))))
	var moves_water := bool(kind_meta.get("pond_drawdown", true))
	var water_lph := q_lps * 3600.0 if moves_water else 0.0
	var inputs: Array = specs.get("inputs", []) as Array
	if not inputs.is_empty() and inputs[0] is Dictionary:
		(inputs[0] as Dictionary)["rate"] = water_lph
	specs["inputs"] = inputs
	var outputs: Array = specs.get("outputs", []) as Array
	for oi in outputs.size():
		if not (outputs[oi] is Dictionary):
			continue
		var od: Dictionary = outputs[oi]
		if str(od.get("kind", "")) == "water":
			od["rate"] = water_lph
		elif str(od.get("kind", "")) == "dc_electricity":
			od["rate"] = kw
	specs["outputs"] = outputs
	if water_lph > 1e-6:
		# Debit the source only when it is a finite stock. A stream intake carries
		# unlimited_capacity, so a spring is never drained — which also keeps the
		# ambient conservation assertions honest.
		var intake := _stream_intake_for(item)
		var tail_down := _resolve_siphon_outlet_tank(item)
		if not intake.is_empty():
			var isp: Dictionary = intake.get("specs", {}) as Dictionary
			if not bool(isp.get("unlimited_capacity", false)):
				var iid := str(intake.get("id", ""))
				net_rates[iid] = float(net_rates.get(iid, 0.0)) - water_lph
			# DIVERSION: when the tailwater is delivered somewhere (a wired
			# outlet), the water no longer runs on down the stream, so the
			# pond that stream ends in must not also receive it. With no
			# outlet wired the tailrace returns to the stream it came from
			# and the stream arrives whole — mass-neutral either way.
			var fid := str(isp.get("water_feature_id", ""))
			if not fid.is_empty() and not tail_down.is_empty():
				_stream_diversions[fid] = float(_stream_diversions.get(fid, 0.0)) + q_lps
		var tail_label := ""
		if not tail_down.is_empty():
			tail_label = str((tail_down.get("specs", {}) as Dictionary).get("name", "outlet"))
		elif not intake.is_empty():
			tail_label = "back to the stream"
		specs["live_tailrace"] = tail_label
		_credit_outlet_sink(tail_down, net_rates,
				water_lph, dt_hours, str(intake.get("id", "")))
		# Glow the outlet culvert AND the penstock itself. Without the second one
		# the pipe the player just routed never animates, which reads as "the water
		# isn't flowing" even when the turbine is producing.
		_stamp_siphon_outlet_culvert_flow(proc_id, water_lph, q_lps)
		var pconn := _penstock_conn_for(proc_id)
		if not pconn.is_empty():
			_cache_conn_flow(str(pconn.get("id", "")), water_lph, "water")
	elif moves_water:
		_stamp_siphon_outlet_culvert_flow(proc_id, 0.0, 0.0)
	if kw > 1e-6:
		_write_node_state(proc_id, specs, GraphNodeState.RUNNING)
	elif head_m <= 0.01 and not _penstock_conn_for(proc_id).is_empty():
		# A penstock IS routed but it doesn't climb — say the real problem.
		_write_node_state(proc_id, specs, GraphNodeState.IDLE,
				"Water source must be ABOVE the turbine — no head")
	else:
		_write_node_state(proc_id, specs, GraphNodeState.IDLE,
				"Set Gross head + Design flow (or bind a pond)")
	const EPS := 0.002
	var changed := str(specs.get("node_state", "")) != str(orig.get("node_state", "")) \
			or absf(float(specs.get("current_output_kw", 0.0)) - float(orig.get("current_output_kw", 0.0))) > 1e-5 \
			or absf(float(specs.get("live_q_lps", 0.0)) - float(orig.get("live_q_lps", 0.0))) > EPS \
			or absf(float(specs.get("live_head_m", 0.0)) - float(orig.get("live_head_m", 0.0))) > EPS
	if changed:
		_model.update_item(proc_id, {"specs": specs})


## Mean rainfall rate (mm/h) per calendar month at the sim location, or [] when
## WeatherService has nothing for this site. Derived from the year's precipitation
## TOTALS divided by the hours in each month — the input HydroSupply needs to turn
## a rain coefficient into a seasonal supply curve.
func _monthly_rain_mmh() -> Array:
	if _host == null or not _host.has_method("_get_scene_main_node"):
		return []
	var main_node: Node = _host.call("_get_scene_main_node")
	var ws: Node = _host.get_node_or_null("/root/WeatherService")
	if ws == null or main_node == null or not ws.has_method("monthly_precip_mm"):
		return []
	if ws.has_method("covers"):
		var lat: Variant = main_node.get("latitude")
		var lon: Variant = main_node.get("longitude")
		if lat == null or lon == null \
				or not bool(ws.call("covers", float(lat), float(lon))):
			return []
	var mm: Array = ws.call("monthly_precip_mm") as Array
	if mm.size() != 12:
		return []
	const DAYS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	var out: Array = []
	out.resize(12)
	for m in 12:
		out[m] = maxf(float(mm[m]), 0.0) / (float(DAYS[m]) * 24.0)
	return out


## Precipitation-derived monthly flow multipliers from WeatherService when it
## covers the sim location (same sourcing the old estimator tick used); [] keeps
## HydroSource on its built-in default profile.
func _monthly_precip_multipliers() -> Array:
	if _host == null or not _host.has_method("_get_scene_main_node"):
		return []
	var main_node: Node = _host.call("_get_scene_main_node")
	var ws: Node = _host.get_node_or_null("/root/WeatherService")
	if ws == null or main_node == null or not ws.has_method("covers"):
		return []
	var lat: Variant = main_node.get("latitude")
	var lon: Variant = main_node.get("longitude")
	if lat == null or lon == null \
			or not bool(ws.call("covers", float(lat), float(lon))):
		return []
	return ws.call("monthly_precip_multipliers") as Array


## Re-derive siphon live telemetry (prime / RPM / power / regime) + culvert flow
## glow from the CURRENT restored pond levels, WITHOUT moving any water. Called on
## a backward scrub: the tanks are rewound by _read_all_tanks_at, but the live_*
## telemetry is written only on the forward path, so without this it would freeze
## at the last forward frame and desync from the scrubbed pond. Telemetry is a pure
## function of the pond level, so evaluating the shared reach at the restored level
## reproduces exactly what the forward pass wrote at that level.
func _refresh_hydro_telemetry_readonly() -> void:
	if _model == null:
		return
	_rebuild_conn_index()  # resolve helpers read the port index; refresh it first
	for item: Dictionary in _model.items_of_type("processor"):
		if str((item.get("specs", {}) as Dictionary).get("role", "")) != "siphon_hydro":
			continue
		# Streaming kinds (pond_drawdown false) run spec-driven — no pond level
		# to rewind, telemetry is a function of the calendar month only.
		var i_specs: Dictionary = item.get("specs", {}) as Dictionary
		if bool(i_specs.get(HydroSource.SPEC_OFF, false)):
			continue  # switched off: stays at 0 W whatever the pond did
		if not bool(HydroSource.kind_meta(
				str(i_specs.get("turbine_kind", "siphon"))).get("pond_drawdown", true)):
			continue
		var proc_id := str(item.get("id", ""))
		# STREAM tap: no pond level to rewind. Supply is re-derived from the
		# intake's base flow + the rain at the scrubbed instant — deliberately
		# UN-LAGGED, since a recession is path-dependent and cannot be reproduced
		# by evaluating a single instant. Documented in the intake's inspector.
		if not _stream_intake_for(item).is_empty():
			var s_specs := (item.get("specs", {}) as Dictionary).duplicate(true)
			_adopt_penstock_conn(item, s_specs)
			_resolve_penstock_supply_lps(item, s_specs, 0.0)
			var no_rates := {}
			_process_spec_driven_hydro(item, s_specs, proc_id, no_rates, 0.0)
			continue
		var tank := _resolve_siphon_inlet_tank(item)
		if tank.is_empty():
			continue
		var tank_specs: Dictionary = tank.get("specs", {}) as Dictionary
		var level_m := float(tank_specs.get("level_m", NAN))
		if is_nan(level_m):
			var rim := float(tank_specs.get("rim_m", NAN))
			var floor_y := float(tank_specs.get("floor_m", NAN))
			if not is_nan(rim) and not is_nan(floor_y):
				level_m = floor_y + clampf(float(tank_specs.get("level", 0.0)), 0.0, 1.0) \
						* maxf(rim - floor_y, 0.05)
		if is_nan(level_m):
			continue
		var specs := (item.get("specs", {}) as Dictionary).duplicate(true)
		_ensure_siphon_inverts(item, specs, tank)
		_reach.configure_siphon(specs)
		var r := _reach.evaluate(level_m)
		specs["siphon_primed"] = bool(r.get("primed", false))
		specs["live_q_lps"] = float(r.get("q_lps", 0.0))
		specs["live_head_m"] = float(r.get("head_m", 0.0))
		specs["live_pe_w"] = float(r.get("pe_w", 0.0))
		specs["live_rpm"] = float(r.get("rpm", 0.0))
		specs["live_power_w"] = float(r.get("power_w", 0.0))
		specs["current_output_kw"] = float(r.get("power_kw", 0.0))
		specs["live_regime"] = str(r.get("regime", ""))
		_model.update_item(proc_id, {"specs": specs})
		var q_lps := float(r.get("q_lps", 0.0))
		_stamp_siphon_outlet_culvert_flow(proc_id, float(r.get("q_lph", 0.0)), q_lps)


## Stamp live Q onto siphon → culvert_pipe outlet wires for Elev/3D glow.
func _stamp_siphon_outlet_culvert_flow(siphon_id: String, q_lph: float, q_lps: float) -> void:
	if _model == null or siphon_id.is_empty():
		return
	# Outlet side only (siphon as source), through the per-topology index
	# instead of a scan of every wire per siphon per step. The stamp lands on
	# the REAL wire (the index holds flattened copies).
	for edge: Dictionary in (_resource_conns_by_source_item.get(siphon_id, []) as Array):
		var cid := str(edge.get("id", ""))
		var real: Variant = _conn_by_id.get(cid)
		var conn: Dictionary = (real as Dictionary) if real is Dictionary else edge
		var type_id := ConduitKinds.derive_type_for_connection(conn)
		if not ConduitKinds.uses_culvert_kit(type_id) \
				and str(conn.get("conduit_type", "")) != "culvert_pipe":
			continue
		conn["live_q_lps"] = q_lps
		conn["live_q_lph"] = q_lph
		_cache_conn_flow(cid, q_lph, "water")


## True when a `catchment` item is wired to this siphon's water-in (either
## through the input port or a direct inbound water connection) — used only to
## pick a clearer "insert a pond" idle message. Cheap: scans connections once.
func _siphon_water_in_is_catchment(proc_id: String) -> bool:
	if _model == null or proc_id.is_empty():
		return false
	# Use the per-tick port adjacency index (built in _rebuild_conn_index) instead
	# of a full connection scan per idle siphon.
	for handle in ["res_in_0", "input"]:
		for conn: Dictionary in _conn_by_target.get(proc_id + "|" + handle, []):
			var src := _model.get_item(str(conn.get("source_item_id", "")))
			if not src.is_empty() and str(src.get("type", "")) == "catchment":
				return true
	return false


func _resolve_siphon_inlet_tank(item: Dictionary) -> Dictionary:
	if _model == null:
		return {}
	var proc_id := str(item.get("id", ""))
	# A ROUTED penstock is the authority for what feeds a penstock turbine: a
	# stray plain wire from some other tank into the same port (an old test
	# tank, a hand-drawn "supply") must not out-vote the pipe the player laid.
	# The first-wire-wins rule below picked an empty 100 L tank carrying a
	# copied pond level over the stream intake at the head of the penstock.
	var pk_meta := HydroSource.kind_meta(str((item.get("specs", {}) as Dictionary).get("turbine_kind", "siphon")))
	if bool(pk_meta.get("has_penstock", false)):
		var pconn := _penstock_conn_for(proc_id)
		if not pconn.is_empty() and str(pconn.get("target_item_id", "")) == proc_id:
			var psrc := _model.get_item(str(pconn.get("source_item_id", "")))
			if not psrc.is_empty() and str(psrc.get("type", "")) == "resource":
				return psrc
	# Water input port → pond storage tank.
	var tank_id := _tank_at_port(proc_id, "res_in_0", true)
	if tank_id.is_empty():
		tank_id = _tank_at_port(proc_id, "input", true)
	if not tank_id.is_empty():
		var t := _model.get_item(tank_id)
		if not t.is_empty():
			var ts: Dictionary = t.get("specs", {}) as Dictionary
			if bool(ts.get("pond_storage", false)) \
					or str(ts.get("resource_kind", "")) == "water":
				return t
	# Inbound water connections (pond → siphon).
	for conn: Dictionary in _model.connections:
		if str(conn.get("target_item_id", "")) != proc_id:
			continue
		var src := _model.get_item(str(conn.get("source_item_id", "")))
		if src.is_empty():
			continue
		var ss: Dictionary = src.get("specs", {}) as Dictionary
		if bool(ss.get("pond_storage", false)):
			return src
		if str(src.get("type", "")) == "resource" \
				and str(ss.get("resource_kind", "")) == "water":
			return src
		if str(src.get("type", "")) == "catchment":
			var tag := str(ss.get("osm_water_tag", ss.get("osm_tag", "")))
			if not tag.is_empty():
				return _resolve_culvert_inlet_tank({"inlet_pond_tag": tag,
						"source_item_id": str(src.get("id", ""))}, tag)
	# Reverse-wire: siphon drawn as source → pond/catchment as target.
	for conn: Dictionary in _model.connections:
		if str(conn.get("source_item_id", "")) != proc_id:
			continue
		var tgt := _model.get_item(str(conn.get("target_item_id", "")))
		if tgt.is_empty():
			continue
		var ts2: Dictionary = tgt.get("specs", {}) as Dictionary
		if bool(ts2.get("pond_storage", false)):
			return tgt
		if str(tgt.get("type", "")) == "resource" \
				and str(ts2.get("resource_kind", "")) == "water" \
				and not bool(ts2.get("outlet_sink", false)):
			return tgt
		if str(tgt.get("type", "")) == "catchment":
			var tag2 := str(ts2.get("osm_water_tag", ts2.get("osm_tag", "")))
			if not tag2.is_empty():
				return _resolve_culvert_inlet_tank({"inlet_pond_tag": tag2,
						"source_item_id": str(tgt.get("id", ""))}, tag2)
	return {}


func _resolve_siphon_outlet_tank(item: Dictionary) -> Dictionary:
	if _model == null:
		return {}
	var proc_id := str(item.get("id", ""))
	var tank_id := _tank_at_port(proc_id, "res_out_0", false)
	if tank_id.is_empty():
		# Water may be output index 0; dc is often index 1.
		for i in 4:
			tank_id = _tank_at_port(proc_id, "res_out_%d" % i, false)
			if not tank_id.is_empty():
				var cand := _model.get_item(tank_id)
				if not cand.is_empty() \
						and str((cand.get("specs", {}) as Dictionary).get(
							"resource_kind", "")) == "water":
					return cand
	elif not tank_id.is_empty():
		return _model.get_item(tank_id)
	for conn: Dictionary in _model.connections:
		if str(conn.get("source_item_id", "")) != proc_id:
			continue
		var tgt := _model.get_item(str(conn.get("target_item_id", "")))
		if tgt.is_empty():
			continue
		if str(tgt.get("type", "")) == "resource" \
				and str((tgt.get("specs", {}) as Dictionary).get(
					"resource_kind", "")) == "water":
			return tgt
	return {}


func _ensure_siphon_inverts(item: Dictionary, specs: Dictionary, tank: Dictionary) -> void:
	var d_in := maxf(float(specs.get("intake_diameter_mm", 150.0)) / 1000.0, 0.05)
	var ts: Dictionary = tank.get("specs", {}) as Dictionary
	var rim := float(ts.get("rim_m", ts.get("level_m", NAN)))
	var floor_y := float(ts.get("floor_m", NAN))
	var mod_e := float(item.get("elevation_m", NAN))
	if is_nan(mod_e):
		mod_e = float(specs.get("module_elev_m", NAN))
	if is_nan(mod_e):
		if not is_nan(rim):
			mod_e = rim - 0.35
		else:
			mod_e = 0.0
	# Resolve start/break from module elev + offsets (migrates legacy absolutes).
	SiphonHydraulics.apply_resolved_levels(specs, mod_e)
	var start_m := float(specs.get("siphon_start_m", NAN))
	var break_m := float(specs.get("siphon_break_m", NAN))
	if not is_nan(floor_y) and not is_nan(break_m) and break_m < floor_y:
		break_m = floor_y + 0.05
		specs["siphon_break_m"] = break_m
		specs["siphon_break_offset_m"] = break_m - mod_e
		specs["intake_invert_m"] = break_m
		if not is_nan(start_m) and start_m < break_m:
			start_m = SiphonHydraulics.crown_from_invert(break_m, d_in)
			specs["siphon_start_m"] = start_m
			specs["siphon_start_offset_m"] = start_m - mod_e
			specs["intake_crown_m"] = start_m
	var inv := break_m if not is_nan(break_m) else mod_e
	_adopt_penstock_conn(item, specs)
	var out_inv := float(specs.get("outlet_invert_m", NAN))
	if is_nan(out_inv):
		# Prefer outbound culvert_pipe invert_out, else sink elevation, else drop.
		var proc_id := str(item.get("id", ""))
		for conn: Dictionary in _model.connections:
			if str(conn.get("source_item_id", "")) != proc_id:
				continue
			var type_id := ConduitKinds.derive_type_for_connection(conn)
			if ConduitKinds.uses_culvert_kit(type_id):
				_ensure_culvert_inverts(conn)
				out_inv = float(conn.get("invert_out_m", NAN))
				if not is_nan(out_inv):
					break
			var tgt := _model.get_item(str(conn.get("target_item_id", "")))
			if not tgt.is_empty() and tgt.has("elevation_m"):
				out_inv = float(tgt.get("elevation_m", 0.0))
				break
		if is_nan(out_inv):
			# Terrain at the turbine's own site is the honest tailwater level;
			# the old fixed `inv - 9.0` (~30 ft) drop invented head the site may
			# not have. Kept only as the last resort where no terrain exists
			# below the intake (flat / no-DEM built-in scenes).
			var g := _ground_elev_at_item(item)
			if not is_nan(g) and g < inv - 0.05:
				out_inv = g
			else:
				out_inv = inv - 9.0
		specs["outlet_invert_m"] = out_inv
	# Sync barrel length from site XY when both ends placed.
	if GraphSiteLayout.has_site_coords(item):
		var down := _resolve_siphon_outlet_tank(item)
		if not down.is_empty() and GraphSiteLayout.has_site_coords(down):
			var a := GraphSiteLayout.site_xz(item)
			var b := GraphSiteLayout.site_xz(down)
			var L := a.distance_to(b)
			if L > 1.0:
				specs["barrel_length_m"] = L


## A routed poly penstock (contour conduit) is the AUTHORITY for its turbine's
## geometry: the measured ground-following run replaces the typed estimate, the
## styled pipe size drives the hydraulic bore, the turbine-end elevation is the
## outlet invert, and — when the far end is a plain SOURCE rather than a pond
## with a water level (a stream intake) — the invert drop IS the gross head.
## That last part is what lets "drop the pipe on the hillside" produce power:
## there is no reservoir level to read, only two measured elevations.
## Returns true when it changed anything.
func _adopt_penstock_conn(item: Dictionary, specs: Dictionary) -> bool:
	if not bool(HydroSource.kind_meta(
			str(specs.get("turbine_kind", "siphon"))).get("has_penstock", false)):
		return false
	var proc_id := str(item.get("id", ""))
	var pen_conn := _penstock_conn_for(proc_id)
	if pen_conn.is_empty():
		return false
	var changed := false
	var run_l := float(pen_conn.get("route_length_m", 0.0))
	if run_l > 0.5 and absf(float(specs.get("penstock_length_m", 0.0)) - run_l) > 0.05:
		specs["penstock_length_m"] = run_l
		changed = true
	var pen_style: Dictionary = pen_conn.get("conduit_style", {}) as Dictionary
	var d_id := ConduitKinds.inner_diameter_for(
			ConduitKinds.derive_type_for_connection(pen_conn), pen_style)
	if d_id > 0.001 \
			and absf(float(specs.get("penstock_diameter_mm", 0.0)) - d_id * 1000.0) > 0.01:
		specs["penstock_diameter_mm"] = d_id * 1000.0
		changed = true
	var turbine_is_target := str(pen_conn.get("target_item_id", "")) == proc_id
	var t_end := float(pen_conn.get(
			"invert_out_m" if turbine_is_target else "invert_in_m", NAN))
	var s_end := float(pen_conn.get(
			"invert_in_m" if turbine_is_target else "invert_out_m", NAN))
	if not is_nan(t_end):
		# NOTE the NaN guard order: an UNSET outlet_invert_m reads back as NAN,
		# and `absf(NAN - x) > 0.01` is FALSE — a bare change-gate here silently
		# skipped the very first write and the turbine fell through to the
		# fixed-drop fallback instead of using the routed elevation.
		var prev_out := float(specs.get("outlet_invert_m", NAN))
		if is_nan(prev_out) or absf(prev_out - t_end) > 0.01:
			specs["outlet_invert_m"] = t_end
			changed = true
	# Gross head from the routed drop — only when the source end has no water
	# level of its own (a pond keeps driving head from its surface elevation).
	if not is_nan(t_end) and not is_nan(s_end):
		var src_id := str(pen_conn.get(
				"source_item_id" if turbine_is_target else "target_item_id", ""))
		var src := _model.get_item(src_id) if not src_id.is_empty() else {}
		var src_specs: Dictionary = src.get("specs", {}) as Dictionary
		if not bool(src_specs.get("pond_storage", false)):
			var drop := maxf(s_end - t_end, 0.0)
			# Write even when the key is ABSENT and the drop is zero: this gate
			# read the missing key as 0, matched drop 0, and skipped the write —
			# while power_kw_from_graph_specs reads the same missing key as its
			# 25 m default. A downhill "penstock" then generated 194 W from
			# nonexistent head (and its phantom flow ran the tailwater jet).
			var prev_h := float(specs.get("gross_head_m", NAN))
			if is_nan(prev_h) or absf(prev_h - drop) > 0.01:
				specs["gross_head_m"] = drop
				changed = true
	return changed


## Pond surface elevation for an inlet tank, or NAN when the item carries no
## water LEVEL (a stream intake is a source, not a reservoir).
func _pond_level_of(tank: Dictionary) -> float:
	if tank.is_empty():
		return NAN
	# A stream intake never has a reservoir level, even when stale pond fields
	# were copied onto it (an intake minted off a pond carried level_m/rim_m
	# and read as a full pond at that height).
	if is_stream_intake(tank):
		return NAN
	var ts: Dictionary = tank.get("specs", {}) as Dictionary
	var level_m := float(ts.get("level_m", NAN))
	if not is_nan(level_m):
		return level_m
	var rim := float(ts.get("rim_m", NAN))
	var floor_y := float(ts.get("floor_m", NAN))
	if is_nan(rim) or is_nan(floor_y):
		return NAN
	return floor_y + clampf(float(ts.get("level", 0.0)), 0.0, 1.0) \
			* maxf(rim - floor_y, 0.05)


## The routed contour-penstock connection attached to a turbine (either side),
## or {} when none is routed yet.
## True when this resource item is a tapped SOURCE (spring / creek / diverted
## stream) rather than a reservoir. `stream_source` is the marker; the model_id
## fallback keeps intakes minted before that key existed working.
static func is_stream_intake(item: Dictionary) -> bool:
	if str(item.get("type", "")) != "resource":
		return false
	var s: Dictionary = item.get("specs", {}) as Dictionary
	if bool(s.get("pond_storage", false)):
		return false
	if bool(s.get("stream_source", false)):
		return true
	return str(s.get("model_id", "")) == StreamIntakeBuilder.MODEL_ID


## The stream intake feeding this turbine, or {}.
func _stream_intake_for(item: Dictionary) -> Dictionary:
	var proc_id := str(item.get("id", ""))
	# Prefer the routed penstock's far end — that IS the physical tap.
	var conn := _penstock_conn_for(proc_id)
	if not conn.is_empty() and _model != null:
		var other_id := str(conn.get("source_item_id", ""))
		if other_id == proc_id:
			other_id = str(conn.get("target_item_id", ""))
		var other := _model.get_item(other_id)
		if is_stream_intake(other):
			return other
	var tank := _resolve_siphon_inlet_tank(item)
	return tank if is_stream_intake(tank) else {}


## Available supply (L/s) at the intake feeding this turbine, or NAN when there is
## no stream intake (→ the legacy design_flow behaviour, byte-identical).
##
## Stamps live telemetry back onto the INTAKE item so the freeform inspector can
## show what the spring is doing, and writes `supply_lps` +
## `penstock_source_mode` onto the turbine's working specs so both the estimator
## and HydroReach see the same number.
##
## Called BEFORE the pond decision in _process_siphon_hydro, i.e. after
## _adopt_penstock_conn has already stamped the measured head.
func _resolve_penstock_supply_lps(item: Dictionary, specs: Dictionary,
		dt_hours: float) -> float:
	var intake := _stream_intake_for(item)
	if intake.is_empty():
		specs.erase("supply_lps")
		specs.erase("penstock_source_mode")
		return NAN
	var isp: Dictionary = (intake.get("specs", {}) as Dictionary).duplicate(true)
	# Back-fill an intake minted before the supply model existed — otherwise it
	# resolves to HydroSupply's defaults every tick but the inspector shows blanks.
	var migrated := false
	if not isp.has("base_flow_lps"):
		isp.merge(HydroSupply.default_intake_specs())
		isp["stream_source"] = true
		migrated = true
	var rain_mmh := _rain_rate_mmh()
	# The Lab's test flow simulates what the stream is running at, BEFORE the
	# nozzle — so it overrides base flow and rain rather than adding to them.
	var override_on := bool(specs.get("lab_sim_inflow_enabled", false))
	var target := maxf(float(specs.get("lab_sim_inflow_lps", 0.0)), 0.0) if override_on \
			else HydroSupply.intake_supply_lps(isp, rain_mmh)
	# An intake standing in a mapped / drawn stream takes THAT stream's
	# discharge (base flow + rain on its real catchment) instead of the
	# authored spring numbers. A dry stream still reports 0.0 — present and
	# zero is DRY, never "unconstrained" (the supply_lps contract).
	var wf: Dictionary = {}
	if not override_on and _host != null and _host.has_method("water_feature_supply_for_intake"):
		wf = _host.call("water_feature_supply_for_intake", intake, rain_mmh)
	if not wf.is_empty():
		target = maxf(float(wf.get("q_lps", 0.0)), 0.0)
	var wf_id := str(wf.get("feature_id", ""))
	var q := target
	if not override_on:
		# Optional storm recession. State lives in the intake's own visible spec so
		# it round-trips through save like everything else; a private engine field
		# would vanish on reload and disagree with what the inspector shows.
		var tau := maxf(float(isp.get("recession_tau_h", 0.0)), 0.0)
		if tau > 0.0:
			q = HydroSupply.recess(float(isp.get("live_supply_lps", NAN)), target,
					maxf(dt_hours, 0.0), tau)
	var prev := float(isp.get("live_supply_lps", NAN))
	if migrated or is_nan(prev) or absf(prev - q) > 0.002 \
			or bool(isp.get("supply_override", false)) != override_on \
			or str(isp.get("water_feature_id", "")) != wf_id:
		isp["live_supply_lps"] = q
		isp["live_rain_mmh"] = rain_mmh
		isp["live_rain_term_lps"] = HydroSupply.rain_term_lps(isp, rain_mmh)
		isp["supply_override"] = override_on
		if wf_id.is_empty():
			isp.erase("water_feature_id")
			isp.erase("water_feature_name")
			isp.erase("water_feature_area_m2")
		else:
			isp["water_feature_id"] = wf_id
			isp["water_feature_name"] = str(wf.get("name", ""))
			isp["water_feature_area_m2"] = float(wf.get("area_m2", 0.0))
		_model.update_item(str(intake.get("id", "")), {"specs": isp})
	specs["supply_lps"] = q
	specs["penstock_source_mode"] = "stream"
	# Seasonal supply curve for the ANNUAL estimate. Recomputed only when the
	# authored intake params change — it is 12 evaluations against a cached
	# rainfall profile, not something to redo on every tick. The live path keeps
	# using the instantaneous `supply_lps` above; this is a separate key precisely
	# so the two cannot be confused (a monthly MEAN would be wrong for live rain).
	var prof_sig := "%.4f|%.4f|%.2f|%s|%.0f" % [
		float(isp.get("base_flow_lps", 0.0)),
		float(isp.get("rain_lps_per_tenth_in_h", 0.0)),
		float(isp.get("max_flow_lps", 0.0)), wf_id, float(wf.get("area_m2", 0.0))]
	var intake_id := str(intake.get("id", ""))
	var cached: Dictionary = _supply_profiles.get(intake_id, {})
	var profile: Array = cached.get("prof", [])
	if str(cached.get("sig", "")) != prof_sig:
		profile = []
		if wf_id.is_empty():
			profile = Array(HydroSupply.monthly_supply_lps(isp, _monthly_rain_mmh()))
		else:
			# The stream's own seasonal curve: base flow + rational-method runoff
			# off its catchment at each month's mean rain rate.
			for r in _monthly_rain_mmh():
				profile.append(StreamHydraulics.discharge_lps(
					float(wf.get("base_lps", 0.0)), float(wf.get("area_m2", 0.0)), float(r)))
		_supply_profiles[intake_id] = {"sig": prof_sig, "prof": profile}
	if not profile.is_empty():
		specs["supply_monthly_lps"] = profile
	else:
		specs.erase("supply_monthly_lps")
	return q


func _penstock_conn_for(proc_id: String) -> Dictionary:
	if _model == null or proc_id.is_empty():
		return {}
	if _penstock_conn_cache.has(proc_id):
		return _penstock_conn_cache[proc_id]
	var found := _find_penstock_conn(proc_id)
	_penstock_conn_cache[proc_id] = found
	return found


func _find_penstock_conn(proc_id: String) -> Dictionary:
	for conn: Dictionary in _model.connections:
		if str(conn.get("source_item_id", "")) != proc_id \
				and str(conn.get("target_item_id", "")) != proc_id:
			continue
		var tid := ConduitKinds.derive_type_for_connection(conn)
		var rm := ConduitKinds.normalize_route_mode(
				str((conn.get("conduit_style", {}) as Dictionary).get("route_mode",
					ConduitKinds.type_meta(tid).get("route_mode", ""))))
		if rm == "contour":
			return conn
	return {}


## Terrain elevation at a graph item's site position (NAN when the item has no
## site coords or no world/terrain is available — offline selftests).
func _ground_elev_at_item(item: Dictionary) -> float:
	if _host == null or not GraphSiteLayout.has_site_coords(item):
		return NAN
	if not _host.has_method("_get_scene_main_node"):
		return NAN
	var main_node: Node = _host.call("_get_scene_main_node")
	if main_node == null or not main_node.is_inside_tree():
		return NAN
	var soi := _host.get_node_or_null("/root/SoiService")
	if soi == null or not soi.has_method("world_center"):
		return NAN
	var center: Vector3 = soi.call("world_center") as Vector3
	var wxz := GraphSiteLayout.site_to_world_xz(GraphSiteLayout.site_xz(item), center)
	return TerrainSurfaceQuery.ground_height_at(main_node, wxz.x, wxz.y)


## Free-surface culvert drains from pond tanks (stage-discharge). Debits the
## inlet pond tank and credits the target tank when present. Writes live Q onto
## the connection for Elevation / inspector readouts.
func _process_culvert_stage_discharge(net_rates: Dictionary, _dt_hours: float,
		_abs_hours: float) -> void:
	if _model == null:
		return
	# uses_culvert_kit deep-copies the type's whole metadata to read one key;
	# asked once per type per step instead of once per wire (288 on Walton,
	# ~1.3 ms a step).
	var kit_of_type: Dictionary = {}
	for conn: Dictionary in _model.connections:
		var type_id := ConduitKinds.derive_type_for_connection(conn)
		var is_kit: Variant = kit_of_type.get(type_id, null)
		if is_kit == null:
			is_kit = ConduitKinds.uses_culvert_kit(type_id)
			kit_of_type[type_id] = is_kit
		if not bool(is_kit):
			continue
		var meta := ConduitKinds.type_meta(type_id)
		_ensure_culvert_inverts(conn)
		var hs := CulvertHydraulics.specs_from_connection(conn, meta)
		if is_nan(float(hs.get("invert_in_m", NAN))) \
				or is_nan(float(hs.get("invert_out_m", NAN))):
			continue
		var tank := _resolve_culvert_inlet_tank(conn, str(hs.get("inlet_pond_tag", "")))
		if tank.is_empty():
			continue
		var tank_specs: Dictionary = tank.get("specs", {}) as Dictionary
		var level_m := float(tank_specs.get("level_m", NAN))
		if is_nan(level_m):
			var rim := float(tank_specs.get("rim_m", NAN))
			var floor_y := float(tank_specs.get("floor_m", NAN))
			if not is_nan(rim) and not is_nan(floor_y):
				level_m = floor_y + clampf(float(tank_specs.get("level", 0.0)), 0.0, 1.0) \
						* maxf(rim - floor_y, 0.05)
		if is_nan(level_m):
			continue
		var r := CulvertHydraulics.stage_discharge(
			level_m,
			float(hs["invert_in_m"]),
			float(hs["invert_out_m"]),
			float(hs["diameter_m"]),
			float(hs["length_m"]),
			float(hs.get("manning_n", CulvertHydraulics.DEFAULT_MANNING_N)))
		var q_lph := float(r.get("q_m3s", 0.0)) * 1000.0 * 3600.0
		_stamp_conn_telemetry(conn, {
			"live_q_lps": float(r.get("q_lps", 0.0)),
			"live_q_lph": q_lph,
			"live_head_m": float(r.get("head_m", 0.0)),
			"live_pe_kw": float(r.get("pe_kw", 0.0)),
			"live_regime": str(r.get("regime", "")),
			"live_velocity_mps": float(r.get("velocity_mps", 0.0)),
		})
		if q_lph <= 1e-6:
			continue
		var src_id := str(tank.get("id", ""))
		net_rates[src_id] = float(net_rates.get(src_id, 0.0)) - q_lph
		var tgt := _model.get_item(str(conn.get("target_item_id", "")))
		if not tgt.is_empty() and str(tgt.get("type", "")) == "resource":
			var tid := str(tgt.get("id", ""))
			if tid != src_id:
				net_rates[tid] = float(net_rates.get(tid, 0.0)) + q_lph


## pond tag -> pond_storage tank, built once per step on first use (the
## culvert pass used to scan every item per culvert per step).
var _pond_tank_by_tag: Dictionary = {}
var _pond_tank_index_valid: bool = false


func _pond_tank_for_tag(pond_tag: String) -> Dictionary:
	if not _pond_tank_index_valid:
		_pond_tank_by_tag.clear()
		for it in _model.items_of_type("resource"):
			var specs: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
			if bool(specs.get("pond_storage", false)):
				var tag := str(specs.get("osm_water_tag", ""))
				if not tag.is_empty() and not _pond_tank_by_tag.has(tag):
					_pond_tank_by_tag[tag] = it
		_pond_tank_index_valid = true
	var hit: Variant = _pond_tank_by_tag.get(pond_tag)
	return (hit as Dictionary) if hit is Dictionary else {}


func _resolve_culvert_inlet_tank(conn: Dictionary, pond_tag: String) -> Dictionary:
	if _model == null:
		return {}
	# Prefer explicit pond tag on the connection.
	if not pond_tag.is_empty():
		var by_tag := _pond_tank_for_tag(pond_tag)
		if not by_tag.is_empty():
			return by_tag
	# Else: source item is the pond tank, or a pond catchment → linked tank.
	var src := _model.get_item(str(conn.get("source_item_id", "")))
	if src.is_empty():
		return {}
	var src_specs: Dictionary = src.get("specs", {}) as Dictionary
	if bool(src_specs.get("pond_storage", false)):
		return src
	if str(src.get("type", "")) == "catchment" \
			and str(src_specs.get("catchment_kind", "")) == "pond":
		var tag := str(src_specs.get("osm_water_tag", src_specs.get("osm_tag", "")))
		if not tag.is_empty():
			for it2 in _model.items:
				if not (it2 is Dictionary):
					continue
				var sp2: Dictionary = (it2 as Dictionary).get("specs", {}) as Dictionary
				if bool(sp2.get("pond_storage", false)) \
						and str(sp2.get("osm_water_tag", "")) == tag:
					return it2 as Dictionary
	return {}


## Fill missing invert elevations from endpoint item elevation_m (source=in).
func _ensure_culvert_inverts(conn: Dictionary) -> void:
	if _model == null:
		return
	var need_in := not conn.has("invert_in_m") or is_nan(float(conn.get("invert_in_m", NAN)))
	var need_out := not conn.has("invert_out_m") or is_nan(float(conn.get("invert_out_m", NAN)))
	var need_tag := str(conn.get("inlet_pond_tag", "")).is_empty()
	if not need_in and not need_out and not need_tag:
		return
	var src := _model.get_item(str(conn.get("source_item_id", "")))
	var tgt := _model.get_item(str(conn.get("target_item_id", "")))
	var patch := {}
	if need_in and not src.is_empty() and src.has("elevation_m"):
		patch["invert_in_m"] = float(src.get("elevation_m", 0.0))
	if need_out and not tgt.is_empty() and tgt.has("elevation_m"):
		patch["invert_out_m"] = float(tgt.get("elevation_m", 0.0))
	if need_in and not patch.has("invert_in_m"):
		var tank := _resolve_culvert_inlet_tank(conn, str(conn.get("inlet_pond_tag", "")))
		if not tank.is_empty():
			var ts: Dictionary = tank.get("specs", {}) as Dictionary
			var rim := float(ts.get("rim_m", ts.get("level_m", NAN)))
			if not is_nan(rim):
				patch["invert_in_m"] = rim - 0.15
	if need_out and not patch.has("invert_out_m") and patch.has("invert_in_m"):
		# Placeholder ~30 ft drop until the outlet endpoint has elevation_m.
		patch["invert_out_m"] = float(patch["invert_in_m"]) - 9.0
	if need_tag:
		var tank2 := _resolve_culvert_inlet_tank(conn, "")
		if not tank2.is_empty():
			var tag := str((tank2.get("specs", {}) as Dictionary).get("osm_water_tag", ""))
			if not tag.is_empty():
				patch["inlet_pond_tag"] = tag
	if not patch.is_empty():
		_model.update_connection(str(conn.get("id", "")), patch)


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


## Day of year for the harvest-window test (Phase 10 food forests). Mirrors
## _sim_month: the render context wins during a bake so a pre-baked challenge
## harvests on the same days the live sim would.
func _sim_doy() -> int:
	var month := 6
	var day := 15
	if _render_ctx_active:
		var d := _date_at_render()
		if not d.is_empty():
			month = int(d.get("month", month))
			day = int(d.get("day", day))
			return _doy_from(month, day)
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node != null:
		if main_node.get("day_of_year") != null:
			return int(main_node.get("day_of_year"))
		if main_node.get("month") != null:
			month = int(main_node.get("month"))
		if main_node.get("day") != null:
			day = int(main_node.get("day"))
	return _doy_from(month, day)


const _DAYS_BEFORE_MONTH := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]


static func _doy_from(month: int, day: int) -> int:
	return int(_DAYS_BEFORE_MONTH[clampi(month, 1, 12) - 1]) + clampi(day, 1, 31)


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
		var tk := ResourceKinds.normalize_kind(str(tgt_specs.get("resource_kind", "")))
		# Rain also fills plain water stores (worlds wired before rain was its
		# own kind; the wire now says rainwater and the inspector warns).
		if tk != want_kind and not (want_kind == "rainwater" and tk == "water"):
			continue
		var tl: ResourceTimeline = _timelines.get(tgt_id) as ResourceTimeline
		if not _is_pond_tank(tgt_specs) and not _tank_accepts_inflow(tgt_specs, tl, abs_h):
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
		if _is_pond_tank(tgt_specs2):
			# Ponds: the spill pass caps them and routes the surplus.
			if not bool(tgt_specs2.get("input_valve_open", true)):
				credit = 0.0
			elif want_kind == "water" or want_kind == "rainwater":
				_book_pond(tgt_id2, "rain", credit)
		# Cap to remaining headroom so catchments do not toast-overflow tanks.
		# Use 0.999 ceiling to stay below ResourceTimeline.is_overflowing_at.
		elif not _tank_is_unlimited(tgt_specs2) and dt_hours > 0.001:
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
	for item: Dictionary in _model.items_of_type("resource"):
		# Cheap gates on the live dict first (migration only ADDS a missing
		# jit_outflow as false, so the raw read is the migrated answer); the
		# deep copy used to be taken for every tank on the graph.
		var raw: Dictionary = item.get("specs", {}) as Dictionary
		if not bool(raw.get("jit_outflow", false)) or not bool(raw.get("output_valve_open", true)):
			continue
		var src_specs: Dictionary = raw.duplicate(true)
		_rk.migrate_resource_specs(src_specs)
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
			# Kind check before the deep copy (normalize_kind is what migration
			# would apply to the kind anyway).
			if ResourceKinds.normalize_kind(str((tgt.get("specs", {}) as Dictionary).get("resource_kind", ""))) != src_kind:
				continue
			var tgt_specs: Dictionary = (tgt.get("specs", {}) as Dictionary).duplicate(true)
			_rk.migrate_resource_specs(tgt_specs)
			# Gravity head gate: uphill transfers need a pump flag on the connection
			# or either tank (specs.pump / specs.is_pump / connection.pump).
			var gravity := _gravity_allows_transfer(item, tgt, conn)
			if not bool(gravity.get("ok", true)):
				_cache_conn_flow(str(conn.get("id", "")), 0.0, src_kind)
				_stamp_conn_telemetry(conn, {
					"needs_pump": true,
					"gravity_delta_m": float(gravity.get("delta_m", 0.0)),
				})
				continue
			_stamp_conn_telemetry(conn, {
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
	# `conn` may be a FLATTENED edge (portal-resolved duplicate); telemetry must
	# land on the REAL wire the player sees, so resolve it back by origin id.
	var real: Dictionary = _conn_by_id.get(str(conn.get("id", "")), conn) as Dictionary
	var enabled: bool = bool(conn.get("simulate_losses", _connector_losses_enabled()))
	# Physics uses the PHYSICAL pipe kind, not the visual default (unstyled
	# wires render as the conceptual-flow glow, which has no hydraulic
	# diameter and would silently skip friction loss on every unstyled pipe).
	var type_id: String = ConduitKinds.physical_type_for_connection(conn)
	# Contour-routed penstock: HydroReach owns 100% of its friction
	# (Darcy–Weisbach over the measured run — see _ensure_siphon_inverts), so
	# a second Hazen-Williams derate here would double-count the pipe loss.
	# Keep this exemption or the generic path grows back.
	var rm := ConduitKinds.normalize_route_mode(
			str((conn.get("conduit_style", {}) as Dictionary).get("route_mode",
				ConduitKinds.type_meta(type_id).get("route_mode", ""))))
	if not enabled or rm == "contour" or not ConduitKinds.is_fluid_type(type_id):
		real["pressure_drop_psi"] = 0.0
		real["flow_derate"] = 1.0
		real["overload_ratio"] = 0.0
		return rate_qph
	# The chosen size's bore and rating (ConduitSpecs). Before this a 4" PVC run
	# lost head as if it were the kind's default 1¼".
	var meta: Dictionary = ConduitSpecs.loss_meta(type_id,
		conn.get("conduit_style", {}) as Dictionary)
	var flow_lpm: float = rate_qph / 60.0
	var rep: Dictionary = ConduitLoss.hydraulic_report_for_connection(conn, meta, flow_lpm)
	var derate: float = clampf(float(rep.get("derate_frac", 1.0)), 0.0, 1.0)
	real["pressure_drop_psi"] = float(rep.get("drop_psi", 0.0))
	real["flow_derate"] = derate
	real["overload_ratio"] = float(rep.get("overload_ratio", 0.0))
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


## A valve / pump's rate for this step, written into the specs COPY the
## machine step uses: max_rate × opening, zero when the height difference
## stops it (a valve uphill; a pump past its lift). Stamps `ctl_block` and
## `ctl_rate` on the node (sim writes, change-gated).
func _prepare_flowctl(item: Dictionary, specs: Dictionary, dt_hours: float, abs_h: float) -> void:
	var iid := str(item.get("id", ""))
	var r := FlowCtl.rate(specs)
	var blk := FlowCtl.BLOCK_NONE
	if r > 0.0:
		var src_id := _tank_at_port(iid, "res_in_0", true)
		var tgt_id := _tank_at_port(iid, "res_out_0", false)
		# Never more in a step than the source holds or the target has room
		# for (the machine step alone would overdraw a small store through a
		# big valve on a coarse step).
		if dt_hours > 0.0:
			for end in [[src_id, true], [tgt_id, false]]:
				var tid := str(end[0])
				if tid.is_empty():
					continue
				var ts: Dictionary = _model.get_item(tid).get("specs", {}) as Dictionary
				if _tank_is_unlimited(ts) or bool(ts.get("allow_negative", false)):
					continue
				var tl: ResourceTimeline = _timelines.get(tid) as ResourceTimeline
				var lvl := tl.level_at(abs_h) if tl != null else float(ts.get("level", 0.0))
				var cap := maxf(_effective_capacity_qty(ts), 0.001)
				var qty := maxf(lvl, 0.0) * cap if bool(end[1]) else maxf(0.998 - lvl, 0.0) * cap
				r = minf(r, qty / dt_hours)
		var delta := NAN
		if not src_id.is_empty() and not tgt_id.is_empty():
			var src := _model.get_item(src_id)
			var tgt := _model.get_item(tgt_id)
			if src.has("elevation_m") and tgt.has("elevation_m"):
				delta = float(src.get("elevation_m", 0.0)) + float((src.get("specs", {}) as Dictionary).get("outlet_height_m", 0.0)) \
					- float(tgt.get("elevation_m", 0.0)) - float((tgt.get("specs", {}) as Dictionary).get("inlet_height_m", 0.0))
		blk = FlowCtl.block_for(specs, delta)
		if blk != FlowCtl.BLOCK_NONE:
			r = 0.0
	FlowCtl.apply_rate(specs, r)
	var live: Dictionary = item.get("specs", {}) as Dictionary
	if str(live.get("ctl_block", "")) != blk or absf(float(live.get("ctl_rate", -1.0)) - r) > 1e-6:
		live["ctl_block"] = blk
		live["ctl_rate"] = r


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


## Spec keys a processor's working copy SHARES with the live item instead of
## deep-copying them every step. They are the population's and the site
## projects' state on a habitat (every agent's snapshot, chores, labour):
## the engine never reads or changes them, and their writers (the NPC bridge,
## the project store) replace them whole. Deep-copying them was most of a
## habitat's step on a festival site.
const _SHARED_SPEC_KEYS := {
	"pop_state": true, "pop_skills": true, "site_projects": true,
	"pop_routine": true, "pop_personas": true, "pop_duties": true,
	"pop_oncall": true, "pop_anim_map": true,
}


## The working copy of a processor's specs: a deep copy of everything the
## engine may change in place (inputs / outputs, batch and recipe state),
## the _SHARED_SPEC_KEYS by reference. Identical to duplicate(true) for every
## value the engine reads.
static func _working_specs(src: Dictionary) -> Dictionary:
	var out := src.duplicate(false)
	for k in out:
		if _SHARED_SPEC_KEYS.has(k):
			continue
		var v: Variant = out[k]
		if v is Dictionary:
			out[k] = (v as Dictionary).duplicate(true)
		elif v is Array:
			out[k] = (v as Array).duplicate(true)
	return out


## Unpack & Sort v2 (food/waste realism pass, Phase 5). Item-driven: draws
## WHOLE packaged products FIFO from the source store's item ledger, puts
## their net content out as food (with its real kcal density as a mix event
## on the pantry's ledger) and their packaging out as typed waste ITEMS
## (archetype counts into the bins' ledgers — what the 3D bins draw). A
## store with no item identity (old saves, a plain stocked tank) unpacks on
## the v1 bulk split instead; mass-exact either way. A produced kind lands
## on its own port, else the legacy umbrella port (plastic_waste /
## packaging_waste), else the node blocks — v1's all-or-nothing contract.
func _process_unpack(item: Dictionary, specs: Dictionary, net_rates: Dictionary,
		dt_hours: float, abs_h: float) -> void:
	var pid := str(item.get("id", ""))
	var occupants: float = maxf(float(specs.get("occupants", 1.0)), 1.0)
	var switched_on := _processor_switched_on(specs)
	var powered := _processor_has_power(item)
	var inputs: Array = specs.get("inputs", []) as Array
	var outputs: Array = specs.get("outputs", []) as Array
	var rate := 0.0
	var in_kind := "packaged_food"
	var in_port := 0
	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		if str(inp.get("kind", "")) in ["electric", "dc_electricity"]:
			continue
		rate = float(inp.get("rate", 0.0)) * occupants
		in_kind = ResourceKinds.normalize_kind(str(inp.get("kind", "")))
		in_port = i
		break
	var src := _tank_at_port(pid, "res_in_%d" % in_port, true)
	if src.is_empty():
		src = _tank_at_port(pid, "input", true)
	var src_item := _model.get_item(src) if not src.is_empty() else {}
	var src_specs: Dictionary = src_item.get("specs", {}) if not src_item.is_empty() else {}
	var src_tl: ResourceTimeline = _timelines.get(src) as ResourceTimeline
	var has_supply := not src.is_empty() and _tank_has_supply(src_specs, src_tl, abs_h)

	# Where each output kind's port leads ("" = the port exists but nothing
	# is wired to a usable tank), and which port index carries it.
	var port_tank: Dictionary = {}
	var port_index: Dictionary = {}
	for i: int in outputs.size():
		var outp: Dictionary = outputs[i] as Dictionary
		var k := ResourceKinds.normalize_kind(str(outp.get("kind", "")))
		if k.is_empty() or k in ["electric", "dc_electricity"]:
			continue
		if not port_tank.has(k) or str(port_tank[k]) == "":
			port_tank[k] = _out_port_tank(pid, i, outp)
			port_index[k] = i

	if not switched_on:
		if powered and has_supply:
			_write_node_state(pid, specs, GraphNodeState.READY)
		else:
			_write_node_state(pid, specs, GraphNodeState.IDLE)
		return
	if not powered:
		_write_node_state(pid, specs, GraphNodeState.BLOCKED, GraphNodeState.REASON_NO_POWER, [])
		return
	if not has_supply:
		_write_node_state(pid, specs, GraphNodeState.BLOCKED,
				GraphNodeState.REASON_EMPTY_INPUT, [in_kind])
		return

	# The kg allowance this step: rate-limited, carried between steps so a
	# whole item bigger than one step's draw still processes (capped — a
	# long stall must not bank hours of work into one burst).
	var cap := maxf(2.0 * rate, 6.0)
	var carry: float = minf(float(_unpack_carry.get(pid, 0.0)) + rate * dt_hours, cap)
	var stock := INF
	if src_tl != null:
		stock = maxf(src_tl.level_at(abs_h), 0.0) * _effective_capacity_qty(src_specs)
	var budget := minf(carry, stock)

	var led := ensure_item_ledger(src)
	var item_mode := led != null and led.total_count_at(abs_h) > 0
	var taken: Array = []
	var made: Dictionary = {}         # kind -> kg this step
	var waste_items: Dictionary = {}  # kind -> {archetype_id: count}
	var food_kcal_wsum := 0.0
	var processed := 0.0
	if item_mode:
		taken = led.take_fifo(abs_h, budget, func(id: String) -> float:
			var p := FoodProducts.product(id)
			return FoodProducts.gross_g(p) / 1000.0 if not p.is_empty() else 1.0)
		for e: Dictionary in taken:
			var p := FoodProducts.product(str(e["id"]))
			var count := int(e["count"])
			var gross := float(e["kg"])
			if p.is_empty():
				# An unknown product unpacks on the bulk split.
				for k in _UNPACK_BULK:
					made[k] = float(made.get(k, 0.0)) + gross * float(_UNPACK_BULK[k])
				food_kcal_wsum += gross * float(_UNPACK_BULK["food"]) * FoodProducts.FALLBACK_KCAL_PER_KG
				processed += gross
				continue
			var net := FoodProducts.net_kg(p) * float(count)
			made["food"] = float(made.get("food", 0.0)) + net
			food_kcal_wsum += net * FoodProducts.kcal_per_kg(p)
			for w: Dictionary in FoodProducts.waste_items_for(p):
				var aid := str(w["archetype_id"])
				var wkind := PackagingArchetypes.waste_kind(aid)
				var n := int(w["count"]) * count
				var wkg := PackagingArchetypes.mass_g(aid) * float(n) / 1000.0
				made[wkind] = float(made.get(wkind, 0.0)) + wkg
				var bucket: Dictionary = waste_items.get(wkind, {})
				bucket[aid] = int(bucket.get(aid, 0)) + n
				waste_items[wkind] = bucket
			processed += gross
	else:
		processed = budget
		for k in _UNPACK_BULK:
			made[k] = processed * float(_UNPACK_BULK[k])
		food_kcal_wsum = float(made.get("food", 0.0)) * FoodProducts.FALLBACK_KCAL_PER_KG
	if processed <= 1e-9:
		# Nothing fits the allowance yet (the next item outweighs it):
		# bank the allowance and wait.
		_unpack_carry[pid] = carry
		_write_node_state(pid, specs, GraphNodeState.IDLE)
		return

	# Every made kind must land somewhere: its own port, else the umbrella.
	var route: Dictionary = {}  # kind -> [tank_id, port kind]
	for k in made:
		if float(made[k]) <= 1e-12:
			continue
		var route_kind := str(k)
		var tank := str(port_tank.get(route_kind, ""))
		if tank.is_empty():
			var u := str(_WASTE_UMBRELLA.get(route_kind, ""))
			if not u.is_empty() and str(port_tank.get(u, "")) != "":
				tank = str(port_tank[u])
				route_kind = u
		if tank.is_empty():
			_unpack_carry[pid] = carry
			_write_node_state(pid, specs, GraphNodeState.BLOCKED,
					GraphNodeState.REASON_OUTPUT_UNWIRED, [str(k)])
			return
		var tank_item := _model.get_item(tank)
		var tank_specs: Dictionary = tank_item.get("specs", {}) if not tank_item.is_empty() else {}
		var ttl: ResourceTimeline = _timelines.get(tank) as ResourceTimeline
		if not _tank_accepts_inflow(tank_specs, ttl, abs_h):
			_unpack_carry[pid] = carry
			_write_node_state(pid, specs, GraphNodeState.BLOCKED,
					GraphNodeState.REASON_OUTPUT_FULL, [route_kind])
			return
		route[k] = [tank, route_kind]

	# Commit: kg as rates (integrated over this step's dt), item events at
	# this step's time, wire glow per port.
	net_rates[src] = float(net_rates.get(src, 0.0)) - processed / dt_hours
	for conn: Dictionary in _connections_from_handle(pid, "res_in_%d" % in_port):
		_cache_conn_flow(str(conn.get("id", "")), processed / dt_hours, in_kind)
	if item_mode:
		for e: Dictionary in taken:
			led.record(abs_h, str(e["id"]), -int(e["count"]), -float(e["kg"]))
	for k in route:
		var tank := str(route[k][0])
		var route_kind := str(route[k][1])
		var kg := float(made[k])
		net_rates[tank] = float(net_rates.get(tank, 0.0)) + kg / dt_hours
		var pi := int(port_index.get(route_kind, -1))
		if pi >= 0:
			for conn: Dictionary in _connections_from_handle(pid, "res_out_%d" % pi):
				_cache_conn_flow(str(conn.get("id", "")), kg / dt_hours, route_kind)
		var dest_led := ensure_item_ledger(tank)
		if dest_led == null:
			continue
		if str(k) == "food":
			var dest_item := _model.get_item(tank)
			var dest_specs: Dictionary = dest_item.get("specs", {}) if not dest_item.is_empty() else {}
			var dtl: ResourceTimeline = _timelines.get(tank) as ResourceTimeline
			var kg0 := 0.0
			if dtl != null:
				kg0 = maxf(dtl.level_at(abs_h), 0.0) * _effective_capacity_qty(dest_specs)
			dest_led.record_mix(abs_h, kg0, kg, food_kcal_wsum / maxf(kg, 1e-9))
			_stamp_ledger_specs(tank, abs_h)
		elif waste_items.has(k):
			var bucket: Dictionary = waste_items[k]
			for aid in bucket:
				dest_led.record(abs_h, str(aid), int(bucket[aid]),
						PackagingArchetypes.mass_g(str(aid)) * float(int(bucket[aid])) / 1000.0)
			_stamp_ledger_specs(tank, abs_h)
	if item_mode:
		_stamp_ledger_specs(src, abs_h)
	_unpack_carry[pid] = carry - processed
	_write_node_state(pid, specs, GraphNodeState.RUNNING)


func _process_processor(item: Dictionary, net_rates: Dictionary, _dt: float,
		abs_hours: float = -1.0) -> void:
	var specs: Dictionary = _working_specs(item.get("specs", {}) as Dictionary)
	_rk.migrate_processor_specs(specs)
	var abs_h: float = abs_hours if abs_hours >= 0.0 else _get_abs_hours()
	if abs_h < 0.0:
		abs_h = 0.0
	if str(specs.get("role", "")) == "habitat":
		_process_habitat(item, specs, net_rates, abs_h)
		return
	if DesignGap.is_gap(specs):
		_process_design_gap(item, specs, net_rates, _dt, abs_h)
		return
	# A valve or pump in a line: its opening sets the rate, then it runs as
	# any machine does (FlowCtl).
	if FlowCtl.is_flowctl(specs):
		_prepare_flowctl(item, specs, _dt, abs_h)
	# Siphon hydro has its own tick after culverts (_process_siphon_hydro).
	if str(specs.get("role", "")) == "siphon_hydro":
		return
	# Unpack & Sort v2: item-driven sorting with the v1 bulk split as the
	# fallback (food/waste realism pass, Phase 5).
	if str(specs.get("role", "")) == "unpack":
		_process_unpack(item, specs, net_rates, _dt, abs_h)
		return
	# Role-specific machines keep dedicated ticks (CNC / sheet / extruder / …);
	# process-recipe batch cycles are for generic processors (+ legacy batch_mode).
	var proc_role := str(specs.get("role", ""))
	var specialized_job := proc_role in [
		"cartesian_machine", "pp_sheet_press", "pp_beam_extruder",
		"csp_concentrator", "heliostat", "biodigester", "habitat",
		"siphon_hydro",
	]
	if not specialized_job \
			and (RecipeRunner.is_recipe_driven(specs) or bool(specs.get("batch_mode", false))):
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
	# io_absolute (HomeBiogas etc.): rates are absolute qty/h per port — the
	# min+proportion path would incorrectly squash a small biogas m³/h against
	# larger liquid L/h rates. Absolute mode gates on wired/supplied/accepting
	# tanks then applies each port's rate directly (see consume/produce below).
	var io_absolute: bool = bool(specs.get("io_absolute", false))
	var throughput: float = INF
	var any_io_rate := false
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
		any_io_rate = true
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
		if io_absolute:
			throughput = 1.0
		else:
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
			any_io_rate = true
			var out_kind := ResourceKinds.normalize_kind(str(outp.get("kind", "")))
			var tank_id := _out_port_tank(proc_id, i, outp)
			if tank_id.is_empty():
				if not out_kind.is_empty() and not unconnected_out.has(out_kind):
					unconnected_out.append(out_kind)
				# An OPTIONAL output (a filter's backwash, a kitchen's washing-
				# up water, a reactor's cooling heat) drains on site when
				# nothing is wired to it; ElementLedger lists it as lost.
				if bool(outp.get("optional", false)):
					continue
				# Unwired output blocks the processor (all-or-nothing).
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
			if io_absolute:
				throughput = 1.0
			else:
				throughput = minf(throughput, rate)
	# Absolute mode with no positive rates yet (physics tick hasn't stamped
	# them) → idle, same as INF in proportional mode.
	if io_absolute and throughput == INF and not any_io_rate:
		pass  # falls through to the INF idle branch below
	elif io_absolute and throughput == INF and any_io_rate:
		throughput = 1.0

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

	# A growing machine (a greenhouse bed) planted at `planted_abs_h` yields
	# nothing before then and comes up to full over `establish_days`.
	var est := establish_factor(specs, abs_h)
	if bool(specs.get("packed_3d", false)):
		# Its bed is still a kit: nothing is planted yet.
		est = -1.0
	if est < 0.0:
		specs["current_output_kw"] = 0.0
		_write_node_state(proc_id, specs, GraphNodeState.IDLE)
		return
	_stamp_established(proc_id, specs, est)
	var in_scale := 1.0 if est >= 1.0 else lerpf(ESTABLISH_DRAW_FLOOR, 1.0, est)

	# RUNNING (switched on + powered + fed): move resources.
	throughput *= efficiency
	_stamp_cold_curve(proc_id, specs)
	_write_node_state(proc_id, specs, GraphNodeState.RUNNING)

	# Live DC output telemetry: Wh generated per fuel unit consumed ×
	# post-efficiency throughput, NOT the flat spec a resource-tank output
	# would use — energy_wh_per_unit is authored on the generator preset.
	# SystemGraphView's DcPowerWiring aggregator reads this each tick to fold
	# it into SolarUI/EnergyTimeline; it never moves through a tank itself.
	var dc_out_kw := 0.0
	for outp_dc: Dictionary in outputs:
		if str(outp_dc.get("kind", "")) == "dc_electricity":
			# Absolute mode: throughput is a 0/1 scale, so multiply by the
			# fuel input rate for Wh→kW; proportional mode keeps legacy math.
			if io_absolute:
				var fuel_rate := 0.0
				for inp_dc: Dictionary in inputs:
					if str(inp_dc.get("kind", "")) not in ["electric", "dc_electricity"]:
						fuel_rate = float(inp_dc.get("rate", 0.0)) * occupants
						break
				dc_out_kw = throughput * fuel_rate * _fuel_wh_per_unit(proc_id, specs) / 1000.0
			else:
				dc_out_kw = throughput * _fuel_wh_per_unit(proc_id, specs) / 1000.0
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
		var portion: float = (rate * throughput) if io_absolute \
				else throughput * (rate / maxf(in_total, 0.001))
		portion *= in_scale
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
		var portion: float = (rate * throughput) if io_absolute \
				else throughput * (rate / maxf(out_total, 0.001))
		portion *= est
		var tank_id := _out_port_tank(str(item.get("id", "")), i, outp)
		if tank_id.is_empty():
			continue
		net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) + portion
		for conn: Dictionary in _connections_from_handle(str(item.get("id", "")), "res_out_%d" % i):
			_cache_conn_flow(str(conn.get("id", "")), portion, str(outp.get("kind", "")))
		if i == 0 and outputs.size() == 1:
			for conn: Dictionary in _connections_from_handle(str(item.get("id", "")), "output"):
				_cache_conn_flow(str(conn.get("id", "")), portion, str(outp.get("kind", "")))


# --- The gap node (resource composition plan Phase 8) ------------------------

## What an upstream tank keeps back from a gap node (share of its capacity).
const GAP_RESERVE := 0.05
## Live meters by gap node id; each is saved onto its node once a sim hour.
var _gap_meters: Dictionary = {}
var _gap_saved_h: Dictionary = {}


func gap_meter(item_id: String) -> GapMeter:
	var m: GapMeter = _gap_meters.get(item_id)
	if m == null and _model != null:
		var sp: Dictionary = (_model.get_item(item_id).get("specs", {}) as Dictionary)
		m = GapMeter.from_dict(sp.get("gap_meter", {}) if sp.get("gap_meter", {}) is Dictionary else {})
		_gap_meters[item_id] = m
	return m


## A gap node: it takes what is offered on its wired inputs, DesignGap
## decides what it can deliver without making any element out of nothing,
## and the meter remembers it for the brief. Only its own wired tanks (its
## res_in_i / res_out_i), never the "any tank" fallback other machines use.
func _process_design_gap(item: Dictionary, specs: Dictionary, net_rates: Dictionary,
		dt_hours: float, abs_h: float) -> void:
	var gid := str(item.get("id", ""))
	var inputs: Array = specs.get("inputs", [])
	var outputs: Array = specs.get("outputs", [])
	var target := float(specs.get("gap_kwh_per_kg", -1.0))
	var on := _processor_switched_on(specs)
	var powered := target < 0.0 or _processor_has_power(item)
	var live := on and powered and dt_hours > 0.0
	var avail: Array = []
	var in_tanks: Array = []
	var in_kinds: Array = []
	for i in inputs.size():
		var inp: Dictionary = inputs[i]
		var k := ResourceKinds.normalize_kind(str(inp.get("kind", "")))
		in_kinds.append(ChainWiring.kind(k))
		var tid := _gap_tank(gid, "res_in_%d" % i, true)
		in_tanks.append(tid)
		var rate := float(inp.get("rate", 0.0))
		var q := 0.0
		if live and not tid.is_empty():
			var tsp: Dictionary = (_model.get_item(tid).get("specs", {}) as Dictionary)
			if _tank_is_unlimited(tsp):
				q = rate
			else:
				var tl: ResourceTimeline = _timelines.get(tid) as ResourceTimeline
				var lvl := tl.level_at(abs_h) if tl != null else float(tsp.get("level", 0.0))
				var cap := _effective_capacity_qty(tsp)
				q = maxf(lvl * cap - GAP_RESERVE * cap, 0.0) / dt_hours
		avail.append({"kind": k, "qty_h": q, "cap_h": rate})
	var outs: Array = []
	var out_tanks: Array = []
	var out_kinds: Array = []
	for j in outputs.size():
		var outp: Dictionary = outputs[j]
		var k2 := ResourceKinds.normalize_kind(str(outp.get("kind", "")))
		out_kinds.append(ChainWiring.kind(k2))
		var tid2 := _gap_tank(gid, "res_out_%d" % j, false)
		out_tanks.append(tid2)
		var room := 0.0
		if live and not tid2.is_empty():
			var tsp2: Dictionary = (_model.get_item(tid2).get("specs", {}) as Dictionary)
			if _tank_is_unlimited(tsp2):
				room = INF
			else:
				var tl2: ResourceTimeline = _timelines.get(tid2) as ResourceTimeline
				var lvl2 := tl2.level_at(abs_h) if tl2 != null else float(tsp2.get("level", 0.0))
				room = maxf(0.998 - lvl2, 0.0) * _effective_capacity_qty(tsp2) / dt_hours
				room = maxf(room - maxf(float(net_rates.get(tid2, 0.0)), 0.0), 0.0)
		outs.append({"kind": k2, "want_h": float(outp.get("rate", 0.0)), "room_h": room,
			"residue": bool(outp.get("residue", false))})
	var r := DesignGap.step(avail, outs, target)
	for i2 in in_tanks.size():
		var q2 := float((r["take"] as Array)[i2])
		if q2 > 0.0 and not str(in_tanks[i2]).is_empty():
			net_rates[in_tanks[i2]] = float(net_rates.get(in_tanks[i2], 0.0)) - q2
		for conn: Dictionary in _connections_to_handle(gid, "res_in_%d" % i2):
			_cache_conn_flow(str(conn.get("id", "")), q2, str(in_kinds[i2]))
	for j2 in out_tanks.size():
		var g := float((r["give"] as Array)[j2])
		if g > 0.0 and not str(out_tanks[j2]).is_empty():
			net_rates[out_tanks[j2]] = float(net_rates.get(out_tanks[j2], 0.0)) + g
		for conn2: Dictionary in _connections_from_handle(gid, "res_out_%d" % j2):
			_cache_conn_flow(str(conn2.get("id", "")), g, str(out_kinds[j2]))
	var m := gap_meter(gid)
	m.record(abs_h, GapMeter.rates_from_step(r, in_kinds, out_kinds))
	var res := 0.0
	for v in (r["residue"] as Dictionary).values():
		res += float(v)
	var sh := 0.0
	for v2 in (r["short"] as Dictionary).values():
		sh += float(v2)
	specs["gap_in_kg_h"] = snappedf(float(r["kg_in"]), 1e-5)
	specs["gap_out_kg_h"] = snappedf(float(r["kg_out"]), 1e-5)
	specs["gap_residue_kg_h"] = snappedf(res, 1e-5)
	specs["gap_short_kg_h"] = snappedf(sh, 1e-5)
	specs["gap_power_w"] = snappedf(float(r["power_w"]), 0.01)
	specs["watts"] = maxf(float(r["power_w"]), 0.0) if target >= 0.0 else 0.0
	var keys := ["gap_in_kg_h", "gap_out_kg_h", "gap_residue_kg_h", "gap_short_kg_h", "gap_power_w", "watts"]
	if absf(abs_h - float(_gap_saved_h.get(gid, -INF))) >= 1.0:
		_gap_saved_h[gid] = abs_h
		specs["gap_meter"] = m.to_dict()
		keys.append("gap_meter")
	_write_if_changed(gid, item, specs, keys)
	if not on:
		_write_node_state(gid, specs, GraphNodeState.IDLE)
	elif not powered:
		_write_node_state(gid, specs, GraphNodeState.BLOCKED, GraphNodeState.REASON_NO_POWER, [])
	elif bool(r["running"]):
		_write_node_state(gid, specs, GraphNodeState.RUNNING)
	else:
		_write_node_state(gid, specs, GraphNodeState.IDLE)


## The tank on one of a gap node's own ports ("" = none wired there).
func _gap_tank(gid: String, handle: String, want_input: bool) -> String:
	var conns: Array = _connections_to_handle(gid, handle) if want_input else _connections_from_handle(gid, handle)
	for conn: Dictionary in conns:
		var other := str(conn.get("source_item_id" if want_input else "target_item_id", ""))
		var it := _model.get_item(other)
		if not it.is_empty() and str(it.get("type", "")) == "resource":
			return other
	return ""


## How far a growing machine has come since it was planted: 1.0 when it has
## no `establish_days` or no `planted_abs_h` (an established bed, every other
## machine), the share of the establishment period gone by, or -1.0 before
## the planting hour. A pure function of the clock, so it scrubs.
static func establish_factor(specs: Dictionary, abs_h: float) -> float:
	var days := float(specs.get("establish_days", 0.0))
	if days <= 0.0 or not specs.has("planted_abs_h"):
		return 1.0
	var planted := float(specs.get("planted_abs_h", NAN))
	if is_nan(planted):
		return 1.0
	if abs_h < planted:
		return -1.0
	return clampf((abs_h - planted) / (days * 24.0), 0.0, 1.0)


## The share established, on the item for the card and the inspector
## (written in whole percent steps, so it costs one write a few hours).
func _stamp_established(proc_id: String, specs: Dictionary, est: float) -> void:
	if float(specs.get("establish_days", 0.0)) <= 0.0:
		return
	var pct := roundi(est * 100.0)
	# Gate on what THIS engine last wrote: the item dict the step loop hands
	# in can be an older copy, and judging by it wrote every step.
	specs["established_pct"] = pct
	if int(_established_written.get(proc_id, -1)) == pct:
		return
	_established_written[proc_id] = pct
	var live: Dictionary = (_model.get_item(proc_id).get("specs", {}) as Dictionary)
	if int(live.get("established_pct", -1)) == pct:
		return
	live["established_pct"] = pct
	_model.update_item(proc_id, {"specs": live})


var _established_written: Dictionary = {}


## Batch-mode quantity for one I/O entry: prefers the explicit "value" field
## (flat qty per batch cycle) and falls back to "rate" for older data that
## predates the name/value split — continuous mode keeps using "rate" as a
## qty/hour throughout this file, untouched by this helper.
func _io_batch_qty(io: Dictionary, occupants: float) -> float:
	# Process recipes use "qty"; legacy batch editor used "value" / "rate".
	return float(io.get("qty", io.get("value", io.get("rate", 0.0)))) * occupants


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
	## Process-recipe / legacy batch cycle. Elapsed is scrub-safe via RecipeRunner
	## (absolute hours + chore pause anchors). Tank I/O modes match the old
	## Batch Cycle Mode; part outputs credit PartInventory via signal.
	var item_id := str(item.get("id", ""))
	if not _processor_states.has(item_id):
		_processor_states[item_id] = { "state": "idle", "elapsed": 0.0, "penalty_qty": 0.0 }
	var state: Dictionary = _processor_states[item_id] as Dictionary

	# Migrate / resolve recipe onto specs (ephemeral from legacy batch_mode).
	var recipe := RecipeRunner.resolve_recipe(specs)
	if recipe.is_empty() and bool(specs.get("batch_mode", false)):
		recipe = ProcessRecipe.from_batch_specs(specs, str(specs.get("name", "")))
	if not recipe.is_empty() and str(specs.get("selected_recipe_id", "")).is_empty():
		ProcessRecipe.apply_to_specs(specs, recipe)
		_model.update_item(item_id, {"specs": specs})

	var batch_time := maxf(float(recipe.get("batch_time_hrs", specs.get("batch_time_hrs", 1.0))), 0.001)
	specs["batch_time_hrs"] = batch_time
	specs["batch_failure_mode"] = str(recipe.get("failure_mode",
		specs.get("batch_failure_mode", "pause_and_resume")))
	var occupants := maxf(float(specs.get("occupants", 1.0)), 1.0)
	var inputs := specs.get("inputs", []) as Array
	var outputs := specs.get("outputs", []) as Array
	var eff := clampf(float(specs.get("efficiency", 1.0)), 0.0, 1.0)

	# Keep engine-local state aligned with scrub-safe recipe_running flag.
	if bool(specs.get("recipe_running", false)):
		state["state"] = "running"
	elif str(state.get("state", "")) == "running" and not bool(specs.get("recipe_running", false)):
		state["state"] = "idle"
		state["elapsed"] = 0.0

	if str(state["state"]) == "idle":
		var switched_on := _processor_switched_on(specs)
		var can_start := true
		var start_block_reason := ""
		var start_block_kinds: Array = []

		var req_watts := float(specs.get("watts", specs.get("avg_watts", 0.0))) * occupants
		for inp: Variant in inputs:
			var inpd := inp as Dictionary
			if str(inpd.get("kind", "")) == "electric":
				if _is_active_in_phase(inpd, 0.0, batch_time):
					req_watts += float(inpd.get("qty", inpd.get("rate", 0.0))) * occupants

		if req_watts > 0.0 and not _processor_has_power(item):
			can_start = false
			start_block_reason = GraphNodeState.REASON_NO_POWER

		if can_start:
			for i in inputs.size():
				var inp: Dictionary = inputs[i] as Dictionary
				var mode := str(inp.get("mode", "continuous"))
				var kind := str(inp.get("kind", ""))
				if kind == "electric" or kind == "part":
					continue
				if mode == "frontloaded":
					var qty := _io_batch_qty(inp, occupants)
					if qty <= 0.0:
						continue
					var tank_id := _tank_at_port(item_id, "res_in_%d" % i, true)
					if tank_id.is_empty():
						tank_id = _tank_at_port(item_id, "input", true)
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
					if (tl == null and not deficit_ok) or (tl != null and tl.level_at(abs_h) * tl.capacity_qty < qty) or not out_valve_open:
						can_start = false
						start_block_reason = GraphNodeState.REASON_EMPTY_INPUT
						start_block_kinds = [ResourceKinds.normalize_kind(kind)]
						break

		if not switched_on:
			item.erase("batch_active_watts")
			if can_start:
				_write_node_state(item_id, specs, GraphNodeState.READY)
			else:
				_write_node_state(item_id, specs, GraphNodeState.IDLE)
			return

		item["batch_active_watts"] = req_watts

		if can_start:
			for i in inputs.size():
				var inp2: Dictionary = inputs[i] as Dictionary
				var mode2 := str(inp2.get("mode", "continuous"))
				if mode2 == "frontloaded" and str(inp2.get("kind", "")) not in ["electric", "part"]:
					var qty2 := _io_batch_qty(inp2, occupants)
					if qty2 <= 0.0:
						continue
					var tank_id2 := _tank_at_port(item_id, "res_in_%d" % i, true)
					if tank_id2.is_empty():
						tank_id2 = _tank_at_port(item_id, "input", true)
					if not tank_id2.is_empty() and dt_hours > 0.0:
						net_rates[tank_id2] = float(net_rates.get(tank_id2, 0.0)) - (qty2 / dt_hours)
						# The charge crosses its wire in this one step.
						if not _render_ctx_active:
							var charge_conns: Array = _connections_to_handle(item_id, "res_in_%d" % i)
							if charge_conns.is_empty():
								charge_conns = _connections_to_handle(item_id, "input")
							if not charge_conns.is_empty():
								_ledger_add(str((charge_conns[0] as Dictionary).get("id", "")), qty2,
									str(inp2.get("kind", "")))

			var begin := RecipeRunner.begin_run(specs, abs_h, recipe, chore_ledger)
			state["state"] = "running"
			state["elapsed"] = 0.0
			state["penalty_qty"] = 0.0
			_model.update_item(item_id, {"specs": specs})
			if bool(begin.get("waiting_chore", false)):
				_write_node_state(item_id, specs, GraphNodeState.IDLE)
				recipe_chore_waiting.emit(item_id, {
					"step_id": str(specs.get("recipe_waiting_step_id", "")),
					"label": str(specs.get("recipe_waiting_label", "Needs attention")),
					"chore_hours": float(specs.get("recipe_waiting_chore_hrs", 0.0)),
				})
				item.erase("batch_active_watts")
				return
		else:
			item.erase("batch_active_watts")
			item["batch_error"] = "blocked"
			_write_node_state(item_id, specs, GraphNodeState.BLOCKED,
					start_block_reason, start_block_kinds)
			return

	if str(state["state"]) == "running":
		if not _processor_switched_on(specs):
			item.erase("batch_active_watts")
			_write_node_state(item_id, specs, GraphNodeState.IDLE)
			return

		var tick := RecipeRunner.tick_state(specs, abs_h, dt_hours, chore_ledger)
		_model.update_item(item_id, {"specs": specs})

		if bool(tick.get("waiting_chore", false)):
			item.erase("batch_active_watts")
			_write_node_state(item_id, specs, GraphNodeState.IDLE)
			recipe_chore_waiting.emit(item_id, tick.get("chore_request", {}) as Dictionary)
			return

		var elapsed: float = float(tick.get("elapsed", 0.0))
		state["elapsed"] = elapsed

		var req_watts_r := 0.0
		var has_electric_input := false
		for inp3: Variant in inputs:
			var inpd3 := inp3 as Dictionary
			if str(inpd3.get("kind", "")) == "electric":
				has_electric_input = true
				if _is_active_in_phase(inpd3, elapsed, batch_time):
					req_watts_r += float(inpd3.get("qty", inpd3.get("rate", 0.0))) * occupants

		if not has_electric_input:
			req_watts_r = float(specs.get("watts", 0.0))
			if req_watts_r <= 0.0:
				req_watts_r = float(specs.get("avg_watts", 0.0))
			if req_watts_r <= 0.0:
				req_watts_r = float(specs.get("base_watts", 0.0))
			req_watts_r *= occupants

		item["batch_active_watts"] = req_watts_r
		item["batch_error"] = ""

		var powered := true
		if req_watts_r > 0.0:
			powered = _processor_has_power(item)

		var missing_inputs := false
		var missing_kind := ""
		var frame_pulls := {}
		for i in inputs.size():
			var inp4: Dictionary = inputs[i] as Dictionary
			var kind4 := str(inp4.get("kind", ""))
			if kind4 == "electric" or kind4 == "part":
				continue
			if _is_active_in_phase(inp4, elapsed, batch_time):
				var qty_per_hr := 0.0
				var mode4 := str(inp4.get("mode", "continuous"))
				if mode4 == "continuous":
					qty_per_hr = _io_batch_qty(inp4, occupants) / batch_time
				elif mode4 == "delayed":
					var dur := maxf(float(inp4.get("duration_hrs", 1.0)), 0.001)
					qty_per_hr = _io_batch_qty(inp4, occupants) / dur

				if qty_per_hr > 0.0:
					var tank_id4 := _tank_at_port(item_id, "res_in_%d" % i, true)
					if tank_id4.is_empty():
						tank_id4 = _tank_at_port(item_id, "input", true)
					if tank_id4.is_empty():
						missing_inputs = true
						missing_kind = kind4
						break
					var tl4 := _timelines.get(tank_id4) as ResourceTimeline
					var tank_item4 := _model.get_item(tank_id4)
					var tank_specs4: Dictionary = tank_item4.get("specs", {}) if not tank_item4.is_empty() else {}
					var out_valve_open4: bool = bool(tank_specs4.get("output_valve_open", true))
					var deficit_ok4: bool = tl4 == null and bool(tank_specs4.get("allow_negative", false))
					if (tl4 == null and not deficit_ok4) or (tl4 != null and tl4.level_at(abs_h) * tl4.capacity_qty < (qty_per_hr * dt_hours)) or not out_valve_open4:
						missing_inputs = true
						missing_kind = kind4
						break
					frame_pulls[tank_id4] = float(frame_pulls.get(tank_id4, 0.0)) + qty_per_hr
					for conn: Dictionary in _connections_to_handle(item_id, "res_in_%d" % i):
						_cache_conn_flow(str(conn.get("id", "")), qty_per_hr, kind4)
					if i == 0 and inputs.size() == 1:
						for conn2: Dictionary in _connections_to_handle(item_id, "input"):
							_cache_conn_flow(str(conn2.get("id", "")), qty_per_hr, kind4)

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
				RecipeRunner.cancel_run(specs)
				state["state"] = "idle"
				_apply_batch_penalty(item_id, specs, inputs, net_rates, dt_hours)
				_model.update_item(item_id, {"specs": specs})
			elif fail_mode == "destroy_batch":
				RecipeRunner.cancel_run(specs)
				state["state"] = "idle"
				_model.update_item(item_id, {"specs": specs})
			return

		_write_node_state(item_id, specs, GraphNodeState.RUNNING)

		for tank_id5: Variant in frame_pulls:
			net_rates[str(tank_id5)] = float(net_rates.get(str(tank_id5), 0.0)) - float(frame_pulls[tank_id5])

		var frame_pushes := {}
		for i in outputs.size():
			var outp: Dictionary = outputs[i] as Dictionary
			if str(outp.get("kind", "")) == "part":
				continue
			if _is_active_in_phase(outp, elapsed, batch_time):
				var qty_per_hr_o := 0.0
				var mode_o := str(outp.get("mode", "continuous"))
				if mode_o == "continuous":
					qty_per_hr_o = (_io_batch_qty(outp, occupants) * eff) / batch_time
				elif mode_o == "delayed":
					var dur_o := maxf(float(outp.get("duration_hrs", 1.0)), 0.001)
					qty_per_hr_o = (_io_batch_qty(outp, occupants) * eff) / dur_o

				if qty_per_hr_o > 0.0:
					var tank_ido := _tank_at_port(item_id, "res_out_%d" % i, false)
					if tank_ido.is_empty():
						tank_ido = _tank_at_port(item_id, "output", false)
					var push_ok := false
					if not tank_ido.is_empty():
						var tank_item_o := _model.get_item(tank_ido)
						var tank_specs_o: Dictionary = tank_item_o.get("specs", {}) if not tank_item_o.is_empty() else {}
						if bool(tank_specs_o.get("input_valve_open", true)):
							push_ok = true
					if push_ok:
						frame_pushes[tank_ido] = float(frame_pushes.get(tank_ido, 0.0)) + qty_per_hr_o
						if str(outp.get("kind", "")) == "meal":
							_stamp_meal_kcal(tank_ido, recipe)
						for conn_o: Dictionary in _connections_from_handle(item_id, "res_out_%d" % i):
							_cache_conn_flow(str(conn_o.get("id", "")), qty_per_hr_o, str(outp.get("kind", "")))
						if i == 0 and outputs.size() == 1:
							for conn_o2: Dictionary in _connections_from_handle(item_id, "output"):
								_cache_conn_flow(str(conn_o2.get("id", "")), qty_per_hr_o, str(outp.get("kind", "")))

		for tank_id6: Variant in frame_pushes:
			net_rates[str(tank_id6)] = float(net_rates.get(str(tank_id6), 0.0)) + float(frame_pushes[tank_id6])

		if bool(tick.get("completed", false)):
			for i in outputs.size():
				var outp2: Dictionary = outputs[i] as Dictionary
				if str(outp2.get("kind", "")) == "part":
					continue
				var mode_e := str(outp2.get("mode", "continuous"))
				if mode_e == "end_batch":
					var qty_e := _io_batch_qty(outp2, occupants) * eff
					if qty_e > 0.0 and dt_hours > 0.0:
						var tank_ide := _tank_at_port(item_id, "res_out_%d" % i, false)
						if tank_ide.is_empty():
							tank_ide = _tank_at_port(item_id, "output", false)
						var push_oke := false
						if not tank_ide.is_empty():
							var tank_item_e := _model.get_item(tank_ide)
							var tank_specs_e: Dictionary = tank_item_e.get("specs", {}) if not tank_item_e.is_empty() else {}
							if bool(tank_specs_e.get("input_valve_open", true)):
								push_oke = true
						if push_oke:
							var qty_per_hr_e := qty_e / dt_hours
							net_rates[tank_ide] = float(net_rates.get(tank_ide, 0.0)) + qty_per_hr_e
							if str(outp2.get("kind", "")) == "meal":
								_stamp_meal_kcal(tank_ide, recipe)
							for conn_e: Dictionary in _connections_from_handle(item_id, "res_out_%d" % i):
								_cache_conn_flow(str(conn_e.get("id", "")), qty_per_hr_e, str(outp2.get("kind", "")))
							if i == 0 and outputs.size() == 1:
								for conn_e2: Dictionary in _connections_from_handle(item_id, "output"):
									_cache_conn_flow(str(conn_e2.get("id", "")), qty_per_hr_e, str(outp2.get("kind", "")))

			var credits: Array = tick.get("part_credits", []) as Array
			if credits.is_empty():
				credits = RecipeRunner.take_pending_credits(specs)
			if not credits.is_empty():
				recipe_parts_ready.emit(item_id, credits)
			item.erase("batch_active_watts")
			state["state"] = "idle"
			state["elapsed"] = 0.0
			_model.update_item(item_id, {"specs": specs})
			_write_node_state(item_id, specs, GraphNodeState.READY)


## NPC population demand override (item_id -> {resource kind: qty per sim-hour}).
## When set for a habitat, its input channels draw at the population engine's
## live aggregate rates (summed over agents currently eating/drinking/etc.)
## instead of the constant preset rate × occupants. Everything downstream is
## unchanged: starvation soft-fail, stoichiometric waste yields, node states.
## Rates are refreshed every tick by the caller — nothing here needs replay,
## so scrubbing stays safe.
var _habitat_demand: Dictionary = {}


func set_habitat_demand(item_id: String, rates: Dictionary) -> void:
	_habitat_demand[item_id] = rates


## One-off quantities a crowd billed to a graph tank between steps (+ fills,
## − draws): a venue's portapotty bank fills from the whole festival, not from
## one habitat. Applied on the next step as a rate over that step, so the mass
## is exact whatever the cadence. Only `resource` items take them; anything
## else is dropped (a kitchen processor is driven by its own inputs).
## Streams of the WaterNetwork that end in a pond on the graph fill it: the
## host maps each to a tank item ({tank_id -> L/s}); credited like a catchment,
## capped to the tank's headroom.
func _credit_stream_inflows(net_rates: Dictionary, dt_hours: float, abs_h: float) -> void:
	if _host == null or not _host.has_method("stream_pond_inflows"):
		return
	var inflows: Dictionary = _host.call("stream_pond_inflows", _rain_rate_mmh(), _stream_diversions)
	for tid in inflows.keys():
		var tank := _model.get_item(str(tid))
		if tank.is_empty() or str(tank.get("type", "")) != "resource":
			continue
		var ts: Dictionary = (tank.get("specs", {}) as Dictionary).duplicate(true)
		_rk.migrate_resource_specs(ts)
		if str(ts.get("resource_kind", "")) != "water":
			continue
		var tl: ResourceTimeline = _timelines.get(str(tid)) as ResourceTimeline
		var lph := maxf(float(inflows[tid]), 0.0) * 3600.0
		# A pond takes the whole stream; what it cannot hold leaves over the
		# spillway in _pond_budget_pass (measured, never silently dropped).
		if _is_pond_tank(ts):
			if bool(ts.get("input_valve_open", true)) and lph > 0.0:
				net_rates[str(tid)] = float(net_rates.get(str(tid), 0.0)) + lph
				_book_pond(str(tid), "stream", lph)
			continue
		if not _tank_accepts_inflow(ts, tl, abs_h):
			continue
		if not _tank_is_unlimited(ts) and dt_hours > 0.001:
			var lvl := tl.level_at(abs_h) if tl != null else float(ts.get("level", 0.0))
			var cap := maxf(_effective_capacity_qty(ts), 0.001)
			lph = minf(lph, maxf(0.998 - lvl, 0.0) * cap / dt_hours)
		if lph > 0.0:
			net_rates[str(tid)] = float(net_rates.get(str(tid), 0.0)) + lph


func add_external_flow(item_id: String, kind: String, qty: float) -> void:
	if item_id.is_empty() or qty == 0.0:
		return
	var d: Dictionary = _external_flows.get(item_id, {})
	d[kind] = float(d.get(kind, 0.0)) + qty
	_external_flows[item_id] = d


var _external_flows: Dictionary = {}
## feature_id -> L/s taken out of a stream by penstock turbines whose tailwater
## is delivered elsewhere this step (rebuilt in _process_siphon_hydro, read by
## _credit_stream_inflows later in the same step).
var _stream_diversions: Dictionary = {}
## tank_id -> {rain, stream, spill} L/h for pond tanks this step.
var _pond_budget: Dictionary = {}
var _stream_catch_m2: Dictionary = {}
var _stream_catch_valid := false


static func _is_pond_tank(specs: Dictionary) -> bool:
	return bool(specs.get("pond_storage", false)) \
			and str(specs.get("fill_mode", "auto")) != "manual"


func _book_pond(tid: String, key: String, lph: float) -> void:
	var b: Dictionary = _pond_budget.get(tid, {})
	b[key] = float(b.get(key, 0.0)) + lph
	_pond_budget[tid] = b


## Upstream area (m²) of mapped streams ending in a tank this catchment feeds.
func _stream_area_into_targets(catchment_id: String) -> float:
	if not _stream_catch_valid:
		_stream_catch_valid = true
		if _host != null and _host.has_method("stream_pond_catchment_m2"):
			_stream_catch_m2 = _host.call("stream_pond_catchment_m2") as Dictionary
	var covered := 0.0
	for conn: Dictionary in (_resource_conns_by_source_item.get(catchment_id, []) as Array):
		covered = maxf(covered, float(_stream_catch_m2.get(str(conn.get("target_item_id", "")), 0.0)))
	return covered


func _tank_has_surface_catchment(tid: String) -> bool:
	for c: Dictionary in _model.items_of_type("catchment"):
		if str((c.get("specs", {}) as Dictionary).get("catchment_kind", "")) != "pond":
			continue
		for conn: Dictionary in (_resource_conns_by_source_item.get(str(c.get("id", "")), []) as Array):
			if str(conn.get("target_item_id", "")) == tid:
				return true
	return false


## Every pond's own water budget, after all sources have credited it:
##  - RAIN straight onto the open water (area = dV/dh off the stage curve, so
##    it grows as the pond rises) — intrinsic, no catchment node to lose. A
##    legacy pond-surface catchment wired to the tank still does this job.
##  - SPILL: whatever would lift the pond past its fill ceiling leaves over the
##    spillway this step, to `specs.spill_outlet_id` when one is set, and is
##    reported either way. Before this the surplus vanished unseen and a pond
##    with any base inflow simply sat pinned at its rim.
func _pond_budget_pass(net_rates: Dictionary, dt_hours: float, abs_h: float) -> void:
	if _model == null:
		return
	var rain := maxf(_rain_rate_mmh(), 0.0)
	for item: Dictionary in _model.items_of_type("resource"):
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if not _is_pond_tank(specs) or _tank_is_unlimited(specs):
			continue
		var tid := str(item.get("id", ""))
		var tl: ResourceTimeline = _timelines.get(tid) as ResourceTimeline
		if tl == null:
			continue
		if rain > 0.0 and bool(specs.get("input_valve_open", true)) \
				and not _tank_has_surface_catchment(tid):
			var area := NAN
			var curve: Variant = specs.get("stage_curve", null)
			if curve is Array:
				area = stage_area_at_level(curve as Array, float(specs.get("level_m", NAN)))
			if is_nan(area) or area <= 0.0:
				area = maxf(float(specs.get("footprint_w_m", 0.0)), 0.0) \
						* maxf(float(specs.get("footprint_d_m", 0.0)), 0.0)
			var lph := area * rain  # 1 mm on 1 m² = 1 L
			if lph > 0.0:
				net_rates[tid] = float(net_rates.get(tid, 0.0)) + lph
				_book_pond(tid, "rain", lph)
		if not _pond_budget.has(tid):
			_pond_budget[tid] = {}
		if dt_hours <= 1e-6:
			continue
		var cap := maxf(_effective_capacity_qty(specs), 0.001)
		var allowed := maxf(1.0 - tl.level_at(abs_h), 0.0) * cap / dt_hours
		var net := float(net_rates.get(tid, 0.0))
		if net > allowed + 1e-6:
			var spill := net - allowed
			net_rates[tid] = allowed
			_book_pond(tid, "spill", spill)
			var out_id := str(specs.get("spill_outlet_id", ""))
			if not out_id.is_empty() and out_id != tid:
				_credit_outlet_sink(_model.get_item(out_id), net_rates, spill, dt_hours, tid)
## scope_id -> bool: per-camp AC availability (CampPowerModel). Scopes not
## listed fall back to the global AcPowerBus.
var _scope_ac_available: Dictionary = {}


func set_scope_ac_available(scope_id: String, on: bool) -> void:
	if scope_id.is_empty():
		return
	_scope_ac_available[scope_id] = on


func clear_scope_ac_available(scope_id: String = "") -> void:
	if scope_id.is_empty():
		_scope_ac_available = {}
	else:
		_scope_ac_available.erase(scope_id)


func _apply_external_flows(net_rates: Dictionary, dt_hours: float) -> void:
	if _external_flows.is_empty() or dt_hours <= 0.0:
		return
	for iid in _external_flows:
		var item: Dictionary = _model.get_item(str(iid))
		if item.is_empty() or str(item.get("type", "")) != "resource":
			continue
		var tank_kind := ResourceKinds.normalize_kind(
			str((item.get("specs", {}) as Dictionary).get("resource_kind", "")))
		var flows: Dictionary = _external_flows[iid]
		for kind in flows:
			if ResourceKinds.normalize_kind(str(kind)) != tank_kind:
				continue
			net_rates[str(iid)] = float(net_rates.get(str(iid), 0.0)) + float(flows[kind]) / dt_hours
	_external_flows = {}


func clear_habitat_demand(item_id: String = "") -> void:
	if item_id.is_empty():
		_habitat_demand = {}
	else:
		_habitat_demand.erase(item_id)


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
	# IDEAL SUPPLY (PopTestPrefs): a channel with no tank, no timeline or a
	# dry tank is not starved — its draw is counted as an ideal import and
	# the activity goes on. The people still consume, so what accumulates
	# here is exactly the supply a perfect infrastructure would deliver.
	# Per camp (specs.supply_mode, stamped by the graph view): "infinite" =
	# never runs out — the camp's own tanks (and whatever loop-closing machine
	# fills them) are used first, and only the SHORTFALL is imported / hauled
	# away, metered (the calculator); "own" / "shared" = the tanks alone.
	var sm: Dictionary = specs.get("supply_mode", {}) if specs.get("supply_mode", {}) is Dictionary else {}
	var mode_in := str(sm.get("inputs", ""))
	var mode_out := str(sm.get("wastes", ""))
	var ideal := PopTestPrefs.habitat_ideal(mode_in)
	var ideal_out := PopTestPrefs.habitat_ideal(mode_out)
	var ideal_imports: Dictionary = {}
	var ideal_exports: Dictionary = {}
	var flows_in: Dictionary = {}
	var flows_out: Dictionary = {}

	var pop_demand: Dictionary = _habitat_demand.get(iid, {})
	var pop_driven := _habitat_demand.has(iid)
	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		var kind: String = ResourceKinds.normalize_kind(str(inp.get("kind", "")))
		var rate: float = float(inp.get("rate", 0.0)) * occupants
		if pop_driven:
			# Population-driven: this channel draws at the live agent-activity
			# rate (0 while nobody is consuming that kind this tick).
			rate = maxf(float(pop_demand.get(kind, 0.0)), 0.0)
		if rate <= 0.0:
			# A WIRED tank that is dry stays starved with nobody drawing on it.
			# Starved people stop drinking, so demand falls to 0, and judging
			# "starved" only by this tick's demand cleared the flag on the
			# next tick: they tried again, starved it, stopped — the flag
			# flipped every tick or two (measured on Walton: 40 camp tanks cut,
			# at most 8 camps starved at once, ~4 people blocked on thirst).
			# An unwired channel (an optional meal input) is left alone, as
			# before.
			if pop_driven and not ideal and not starved.has(kind):
				var tid0 := _tank_at_port(iid, "res_in_%d" % i, true)
				if tid0.is_empty():
					tid0 = _tank_at_port(iid, "input", true)
				var tl0: ResourceTimeline = _timelines.get(tid0) as ResourceTimeline if not tid0.is_empty() else null
				var tk0 := ResourceKinds.normalize_kind(str(((_model.get_item(tid0) as Dictionary).get("specs", {}) as Dictionary).get("resource_kind", ""))) \
					if not tid0.is_empty() else ""
				if tl0 != null and tk0 == kind and tl0.level_at(abs_h) <= 0.001:
					starved.append(kind)
			continue
		had_demand = true
		var tank_id := _tank_at_port(iid, "res_in_%d" % i, true)
		if tank_id.is_empty():
			tank_id = _tank_at_port(iid, "input", true)
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline if not tank_id.is_empty() else null
		var dry := tank_id.is_empty() or tl == null or tl.level_at(abs_h) <= 0.001
		if dry:
			if ideal:
				ideal_imports[kind] = float(ideal_imports.get(kind, 0.0)) + rate
				flows_in[kind] = float(flows_in.get(kind, 0.0)) + rate
				if kind == "water":
					water_consumed_lph += rate
				elif kind == "food":
					food_consumed_kgph += rate
			elif not starved.has(kind):
				starved.append(kind)
			continue
		net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) - rate
		flows_in[kind] = float(flows_in.get(kind, 0.0)) + rate
		for conn: Dictionary in _connections_to_handle(iid, "res_in_%d" % i):
			_cache_conn_flow(str(conn.get("id", "")), rate, kind)
		if kind == "water":
			water_consumed_lph += rate
		elif kind == "food":
			food_consumed_kgph += rate

	# Stoichiometric waste from actual consumption (mass-conserving yields).
	var outputs: Array = specs.get("outputs", []) as Array
	# A habitat with a urine output has urine-diverting toilets: the urine
	# leaves through its own port and only the brownwater (faeces + flush)
	# is blackwater. Same total, so the water balance does not move.
	var urine_lph := 0.0
	for o: Variant in outputs:
		if ResourceKinds.normalize_kind(str((o as Dictionary).get("kind", ""))) == "urine":
			urine_lph = water_consumed_lph * HABITAT_URINE_YIELD * HABITAT_URINE_DIVERSION
			break
	var waste_credits: Dictionary = {
		"greywater": water_consumed_lph * HABITAT_GREYWATER_YIELD,
		"blackwater": maxf(water_consumed_lph * HABITAT_BLACKWATER_YIELD - urine_lph, 0.0),
		# A urine-diverting habitat's toilet port carries brownwater (the
		# same flow as the blackwater it replaces).
		"brownwater": maxf(water_consumed_lph * HABITAT_BLACKWATER_YIELD - urine_lph, 0.0),
		"urine": urine_lph,
		"biomass": food_consumed_kgph * HABITAT_FOOD_SCRAP_YIELD,
	}
	for i: int in outputs.size():
		var outp: Dictionary = outputs[i] as Dictionary
		var kind: String = ResourceKinds.normalize_kind(str(outp.get("kind", "")))
		var credit: float = float(waste_credits.get(kind, 0.0))
		# Allow preset rate override only as a cap (never invent above yield).
		# Pop-driven demand is bursty (one agent flushing = 40 L/h for 9 min),
		# so the steady-state preset cap would silently drop mass — skip it;
		# the stoichiometric yields are already mass-conserving.
		var cap: float = float(outp.get("rate", 0.0)) * occupants
		if cap > 0.0 and not pop_driven:
			credit = minf(credit, cap)
		if credit <= 0.0:
			continue
		var tank_id := _tank_at_port(iid, "res_out_%d" % i, false)
		if tank_id.is_empty():
			tank_id = _tank_at_port(iid, "output", false)
		if tank_id.is_empty():
			if ideal_out:
				ideal_exports[kind] = float(ideal_exports.get(kind, 0.0)) + credit
				flows_out[kind] = float(flows_out.get(kind, 0.0)) + credit
			continue
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
		var tank_item := _model.get_item(tank_id)
		var tank_specs: Dictionary = tank_item.get("specs", {}) if not tank_item.is_empty() else {}
		if not _tank_accepts_inflow(tank_specs, tl, abs_h):
			if ideal_out:
				ideal_exports[kind] = float(ideal_exports.get(kind, 0.0)) + credit
				flows_out[kind] = float(flows_out.get(kind, 0.0)) + credit
				continue
			# People do not stop using the toilet because its tank is full:
			# the waste goes in and the tank overflows (its timeline books
			# the overflow). It used to vanish here unrecorded, so a site
			# whose brownwater tank sat full for weeks still read "no waste
			# overflowed".
		net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) + credit
		flows_out[kind] = float(flows_out.get(kind, 0.0)) + credit
		for conn: Dictionary in _connections_from_handle(iid, "res_out_%d" % i):
			_cache_conn_flow(str(conn.get("id", "")), credit, kind)

	_habitat_flows[iid] = {"in": flows_in, "out": flows_out, "imp": ideal_imports, "exp": ideal_exports}
	_write_habitat_starved(iid, specs, starved)
	_write_habitat_ideal(iid, specs, ideal_imports, ideal_exports)
	# Unified node state: STARVED when any channel is dry, RUNNING while fed,
	# IDLE only when the habitat has no demand at all.
	if not starved.is_empty():
		_write_node_state(iid, specs, GraphNodeState.STARVED,
				GraphNodeState.REASON_EMPTY_INPUT, starved)
	elif had_demand:
		_write_node_state(iid, specs, GraphNodeState.RUNNING)
	else:
		_write_node_state(iid, specs, GraphNodeState.IDLE)


## What each habitat actually took in and put out on its last step, by kind
## per hour — tank draw, ideal import and depot supply alike (the camp
## meter's input). Runtime only.
var _habitat_flows: Dictionary = {}


func habitat_flows(item_id: String) -> Dictionary:
	return _habitat_flows.get(item_id, {})


## Whether a habitat's input channel for `kind` is WIRED to a tank that has
## supply right now. The population sim's MEAL-FIRST eating asks this each
## tick ("is there a stocked meal counter?") and falls back to raw food when
## the answer is no — which is what keeps every kitchen-less camp, fixture
## and capture on the food path byte-identically. Pure read; no flow moves.
func habitat_kind_supplied(item_id: String, kind: String) -> bool:
	var item := _model.get_item(item_id)
	if item.is_empty():
		return false
	var specs: Dictionary = item.get("specs", {})
	var want := ResourceKinds.normalize_kind(kind)
	var inputs: Array = specs.get("inputs", []) as Array
	for i: int in inputs.size():
		if ResourceKinds.normalize_kind(
				str((inputs[i] as Dictionary).get("kind", ""))) != want:
			continue
		var tank_id := _tank_at_port(item_id, "res_in_%d" % i, true)
		if tank_id.is_empty():
			tank_id = _tank_at_port(item_id, "input", true)
		if tank_id.is_empty():
			return false
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
		return tl != null and tl.level_at(maxf(_last_abs_hours, 0.0)) > 0.001
	return false


## The wired tank behind a habitat's input channel for `kind` ("" = none).
func _habitat_supply_tank(item_id: String, kind: String) -> String:
	var item := _model.get_item(item_id)
	if item.is_empty():
		return ""
	var specs: Dictionary = item.get("specs", {})
	var want := ResourceKinds.normalize_kind(kind)
	var inputs: Array = specs.get("inputs", []) as Array
	for i: int in inputs.size():
		if ResourceKinds.normalize_kind(
				str((inputs[i] as Dictionary).get("kind", ""))) != want:
			continue
		var tank_id := _tank_at_port(item_id, "res_in_%d" % i, true)
		if tank_id.is_empty():
			tank_id = _tank_at_port(item_id, "input", true)
		return tank_id
	return ""


## The kcal density of the habitat's wired FOOD store (the item ledger's
## `kcal_per_kg` stamp — Phase 5 writes it from the real products in the
## store). 0 = unknown: the eaters then use the generic figure (food's
## 6.97 MJ/kg), which reproduces the long-standing 1.5 kg/person/day draw.
func habitat_food_kcal_kg(item_id: String) -> float:
	var tank_id := _habitat_supply_tank(item_id, "food")
	if tank_id.is_empty():
		return 0.0
	var t := _model.get_item(tank_id)
	return float((t.get("specs", {}) as Dictionary).get("kcal_per_kg", 0.0))


## kcal one meal from the habitat's wired meal counter carries (the kitchen's
## recipe stamps `kcal_per_meal` on the counter as it serves). 0 = unknown:
## a meal then satisfies hunger fully, today's behaviour exactly.
func habitat_meal_kcal(item_id: String) -> float:
	var tank_id := _habitat_supply_tank(item_id, "meal")
	if tank_id.is_empty():
		return 0.0
	var t := _model.get_item(tank_id)
	return float((t.get("specs", {}) as Dictionary).get("kcal_per_meal", 0.0))


## Change-gated `kcal_per_meal` stamp on the meal counter a kitchen's batch
## is serving into (sim write: the engine runs inside the view's bracket).
func _stamp_meal_kcal(tank_id: String, recipe: Dictionary) -> void:
	var kcal := ProcessRecipe.kcal_per_meal(recipe)
	if kcal <= 0.0:
		return
	var t := _model.get_item(tank_id)
	if t.is_empty():
		return
	var tspecs: Dictionary = t.get("specs", {})
	if absf(float(tspecs.get("kcal_per_meal", 0.0)) - kcal) < 0.5:
		return
	tspecs["kcal_per_meal"] = kcal
	_model.update_item(tank_id, {"specs": tspecs})


## The ideal-supply ledger on the habitat (what a perfect infrastructure
## would import / haul away right now), change-gated to 1 %; erased when the
## mode is off so the ledger stops reading it.
func _write_habitat_ideal(item_id: String, specs: Dictionary, imports: Dictionary, exports: Dictionary) -> void:
	var had := specs.has("ideal_import_rates") or specs.has("ideal_export_rates")
	if imports.is_empty() and exports.is_empty():
		if had:
			specs.erase("ideal_import_rates")
			specs.erase("ideal_export_rates")
			_model.update_item(item_id, {"specs": specs})
		return
	var prev_i: Dictionary = specs.get("ideal_import_rates", {})
	var prev_e: Dictionary = specs.get("ideal_export_rates", {})
	if _rates_close(prev_i, imports) and _rates_close(prev_e, exports):
		return
	specs["ideal_import_rates"] = imports.duplicate()
	specs["ideal_export_rates"] = exports.duplicate()
	_model.update_item(item_id, {"specs": specs})


static func _rates_close(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in b:
		if not a.has(k):
			return false
		var x := float(a[k])
		var y := float(b[k])
		if absf(x - y) > 0.01 * maxf(absf(y), 1e-6) + 1e-6:
			return false
	return true


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


## Cold-water specific energy: nameplate at 25 °C, dearer as the feed cools.
## Stamped onto the running processor so the AC draw and the inspector
## agree. A stopped unit keeps the last stamp; the draw only reads it
## while the node is RUNNING.
func _stamp_cold_curve(proc_id: String, specs: Dictionary) -> void:
	if str(specs.get("energy_curve", "")) != "cold_water":
		return
	var nameplate := float(specs.get("energy_wh_per_unit", 0.0))
	var temp := float(specs.get("feed_temp_c", NAN))
	if is_nan(temp):
		temp = _feed_temp_c()
	var live_wh := ComponentPresets.specific_energy_at_temp(nameplate, temp,
		float(specs.get("energy_floor_wh_per_unit", 0.0)))
	var rated := float(specs.get("watts", specs.get("avg_watts", 0.0)))
	var live_w := rated if nameplate <= 0.0 else rated * live_wh / nameplate
	if absf(float(specs.get("live_watts", -999.0)) - live_w) < 0.5 \
			and absf(float(specs.get("live_wh_per_unit", -999.0)) - live_wh) < 0.01:
		return
	specs["live_watts"] = live_w
	specs["live_wh_per_unit"] = live_wh
	_model.update_item(proc_id, {"specs": specs})


func _feed_temp_c() -> float:
	if _host == null or not _host.has_method("_get_scene_main_node"):
		return 25.0
	var main: Node = _host.call("_get_scene_main_node")
	if main == null:
		return 25.0
	var wx: Variant = main.get("_weather_service_node")
	if wx == null or not (wx as Object).has_method("temperature_c"):
		return 25.0
	var t := float((wx as Object).call("temperature_c", int(main.get("month")),
		int(main.get("day")), float(main.get("day_time"))))
	return 25.0 if is_nan(t) else t


## The first finite water tank's scrub buffer (the timeline's tank lane).
func first_water_timeline():
	_ensure_timelines()
	for item: Dictionary in _model.items_of_type("resource"):
		var specs: Dictionary = item.get("specs", {})
		if bool(specs.get("allow_negative", false)):
			continue
		var kind := ResourceKinds.normalize_kind(str(specs.get("resource_kind", "water")))
		if kind != "water":
			continue
		var tl: ResourceTimeline = _timelines.get(str(item.get("id", ""))) as ResourceTimeline
		if tl != null:
			return tl
	return null


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
	if state == GraphNodeState.RUNNING and prev_state != GraphNodeState.RUNNING:
		var since_h := _get_abs_hours()
		if since_h >= 0.0:
			specs["powered_since_h"] = since_h
	elif state != GraphNodeState.RUNNING and specs.has("powered_since_h"):
		specs.erase("powered_since_h")
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
	# Only `energy_source` is needed here, so the one-key half of
	# migrate_processor_specs is applied inline instead of deep-copying every
	# processor's specs on every flow step (three callers per step, per item).
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var es: String = str(specs.get("energy_source", ""))
	if not specs.has("energy_source") or es == "thermal" or es == "mechanical":
		es = "ac" if (not specs.has("energy_source") and float(specs.get("watts", 0.0)) > 0.0) else ""
	if es.is_empty() and float(specs.get("watts", 0.0)) > 0.0:
		es = "ac"
	if es == "ac":
		# A festival camp's processors run off THAT camp's power (the
		# simplified per-camp model), not the player's AC bus.
		var scope := str(item.get("scope_id", ""))
		if _scope_ac_available.has(scope):
			if not bool(_scope_ac_available[scope]):
				return false
			return _has_ac_power_wire(iid)
		if not _ac_output_available():
			return false
		return _has_ac_power_wire(iid)
	# Passive (no power needed) or future "dc" (powered via a tanked electric
	# resource input, which is handled by the resource-flow "fed" check, not here).
	return true


## True when any flattened AC edge touches this item's `power_in` as source OR
## target — same undirected presence check GraphAcLoad uses for reachability.
func _has_ac_power_wire(item_id: String) -> bool:
	if item_id.is_empty():
		return false
	if _has_incoming_connection(item_id, "power_in"):
		return true
	if not _connections_from_handle(item_id, "power_in").is_empty():
		return true
	return false


## The manual/automation run switch: requested_state wins, else legacy
## current_state; unset → OFF. Default-off means a processor runs only when the
## user (double-click) or an automation switches it on.
## A hydro turbine the player switched off (specs.hydro_off — double-click in
## the graph): the valve is shut, so it draws no water, diverts no stream and
## makes no power. Its telemetry is zeroed so the battery trace, the DC sum to
## SolarUI, the cards and the 3D ring all read 0 W; the prime is kept (a closed
## valve holds the column). Written only when something changed.
func _idle_switched_off_turbine(item: Dictionary, specs: Dictionary, proc_id: String) -> void:
	var before := item.get("specs", {}) as Dictionary
	for k in ["live_q_lps", "current_output_kw", "live_power_w", "live_rpm", "live_pe_w"]:
		specs[k] = 0.0
	# The port rates are what the tank integrator moves and the DC trace reads:
	# a stale rate from the last running tick would keep water flowing.
	var changed := false
	for key in ["inputs", "outputs"]:
		var ports: Array = specs.get(key, []) as Array
		for i in ports.size():
			var pd: Variant = ports[i]
			if pd is Dictionary and absf(float((pd as Dictionary).get("rate", 0.0))) > 1e-9:
				(pd as Dictionary)["rate"] = 0.0
				changed = true
	_write_node_state(proc_id, specs, GraphNodeState.IDLE,
		"Switched off — double-click to start", [])
	if str(specs.get("node_state", "")) != str(before.get("node_state", "")) \
			or str(specs.get("node_state_reason", "")) != str(before.get("node_state_reason", "")):
		changed = true
	for k in ["live_q_lps", "current_output_kw", "live_power_w", "live_rpm"]:
		if absf(float(before.get(k, 0.0))) > 1e-9:
			changed = true
	if changed:
		_model.update_item(proc_id, {"specs": specs})


func _processor_switched_on(specs: Dictionary) -> bool:
	# Packed 3D twin (PACKING_PLAN.md Phase 5): a machine in its shipping
	# crate cannot run, whatever the switch says. One gate here covers every
	# processor path in the engine.
	if bool(specs.get("packed_3d", false)):
		return false
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


## A tank's specs as _migrate_resource_specs_if_needed would leave a copy of
## them, without the copy when that migration has nothing to do but fill the
## two flags it defaults to false (every key read through .get with that same
## default gives the same value). READ ONLY: writers use _tank_specs_copy. The
## step copied all 233 of Walton's tank specs twice a step.
func _tank_specs_view(item: Dictionary) -> Dictionary:
	var raw: Dictionary = item.get("specs", {}) as Dictionary
	if raw.has("capacity_qty") and raw.has("resource_kind") and raw.has("level"):
		return raw
	return _tank_specs_copy(item)


func _tank_specs_copy(item: Dictionary) -> Dictionary:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(false)
	_migrate_resource_specs_if_needed(specs)
	return specs


func _migrate_resource_specs_if_needed(specs: Dictionary) -> void:
	# Load/create paths already migrate; skip the key-fill walk when present.
	if specs.has("capacity_qty") and specs.has("resource_kind") and specs.has("level"):
		if not specs.has("unlimited_capacity"):
			specs["unlimited_capacity"] = false
		if not specs.has("allow_negative"):
			specs["allow_negative"] = false
		return
	_rk.migrate_resource_specs(specs)


func _refresh_ambient_cache() -> void:
	_ambient_valid = false
	_wx_key = []
	_ambient_rain_mmh = _compute_rain_rate_mmh()
	_ambient_ghi_wm2 = _compute_sun_ghi_wm2()
	_ambient_cloud_frac = _compute_sun_cloud_frac()
	_ambient_atmo = _compute_atmosphere_sample()
	_ambient_valid = true


func _rain_rate_mmh() -> float:
	if _ambient_valid:
		return _ambient_rain_mmh
	return _compute_rain_rate_mmh()


func _sun_ghi_wm2() -> float:
	if _ambient_valid:
		return _ambient_ghi_wm2
	return _compute_sun_ghi_wm2()


func _sun_cloud_frac() -> float:
	if _ambient_valid:
		return _ambient_cloud_frac
	return _compute_sun_cloud_frac()


func _atmosphere_sample() -> Dictionary:
	if _ambient_valid:
		return _ambient_atmo
	return _compute_atmosphere_sample()


func _compute_rain_rate_mmh() -> float:
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
func _compute_sun_ghi_wm2() -> float:
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
	var weather := _weather_at(lat, lon, month, day, hour)
	return SolarIrradiance.ghi_wm2_at_calendar(lat, lon, month, day, hour, weather, year)


## Cloud cover fraction (0–1) at the live/render instant — folded into GHI via
## SolarIrradiance and published on the sunlight PBI as specs.cloud_frac so
## overcast reduces shared availability even without per-node 3D geometry.
func _compute_sun_cloud_frac() -> float:
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
	var weather := _weather_at(lat, lon, month, day, hour)
	return clampf(float(weather.get("cloud", 0.0)), 0.0, 1.0)


## SolarIrradiance.sample_weather at a site and instant, remembered for the
## last one asked: the sunlight PBI's GHI and its cloud cover read the same
## sample within a step. Only the very same arguments reuse it.
var _wx_key: Array = []
var _wx_val: Dictionary = {}


func _weather_at(lat: float, lon: float, month: int, day: int, hour: float) -> Dictionary:
	var key := [lat, lon, month, day, hour]
	if key == _wx_key:
		return _wx_val
	var ws: Node = null
	var tree: SceneTree = _host.get_tree() if _host != null else null
	if tree != null:
		ws = tree.root.get_node_or_null("WeatherService")
	_wx_val = SolarIrradiance.sample_weather(lat, lon, month, day, hour, ws)
	_wx_key = key
	return _wx_val


## Atmosphere sample for Wind PBI (honors selftest overrides).
func _compute_atmosphere_sample() -> Dictionary:
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


## The tank a proportional processor's output `i` delivers into. A normal
## output falls back to the legacy single "output" handle and then to any
## store wired out of the node (old saves wired one port). An OPTIONAL output
## (a filter's backwash, a kitchen's washing-up water, a reactor's cooling
## heat) takes only a tank wired to its own port: with the fallback it was
## handed the node's OTHER output store, so a Greywater Filter's 3 L/h
## backwash capped the whole filter at 3 L/h and was poured into the
## reclaimed-water tank, and a Kitchen's washing-up litres landed in the meal
## counter.
func _out_port_tank(proc_id: String, i: int, outp: Dictionary) -> String:
	if bool(outp.get("optional", false)):
		for conn: Dictionary in _connections_from_handle(proc_id, "res_out_%d" % i):
			var tgt := _model.get_item(str(conn.get("target_item_id", "")))
			if not tgt.is_empty() and str(tgt.get("type", "")) == "resource":
				return str(tgt.get("id", ""))
		return ""
	var tank_id := _tank_at_port(proc_id, "res_out_%d" % i, false)
	if tank_id.is_empty():
		tank_id = _tank_at_port(proc_id, "output", false)
	return tank_id


func _connections_from_handle(item_id: String, handle_id: String) -> Array:
	return _conn_by_source.get(item_id + "|" + handle_id, []) as Array


## The producer gas a generator preset's energy_wh_per_unit was set for
## (MJ/Nm³; air-blown gasifier gas runs 4–6, Reed & Das 1988).
const WOODGAS_REF_LHV_MJ_NM3 := 5.0


## Wh of electricity per unit of fuel: the generator's authored figure,
## scaled by the heating value of the gas wired into it when the machine that
## made it stamped one (`gas_lhv_mj_nm3`, a TC Process Lab run's summary):
## pyrolysis gas at ~10 MJ/Nm³ runs an engine twice as far as producer gas.
## Looks through one tank between them.
func _fuel_wh_per_unit(item_id: String, specs: Dictionary) -> float:
	var base := float(specs.get("energy_wh_per_unit", 0.0))
	var lhv := _wired_gas_lhv(item_id, 0)
	if lhv <= 0.0:
		return base
	return base * lhv / WOODGAS_REF_LHV_MJ_NM3


func _wired_gas_lhv(item_id: String, depth: int) -> float:
	for conn in _resource_conns_by_target_item.get(item_id, []) as Array:
		var src := _model.get_item(str((conn as Dictionary).get("source_item_id", "")))
		if src.is_empty():
			continue
		var ss: Dictionary = src.get("specs", {}) as Dictionary
		var l := float(ss.get("gas_lhv_mj_nm3", 0.0))
		if l > 0.0:
			return l
		if depth == 0 and str(src.get("type", "")) == "resource":
			var l2 := _wired_gas_lhv(str(src.get("id", "")), 1)
			if l2 > 0.0:
				return l2
	return 0.0


func _connections_to_handle(item_id: String, handle_id: String) -> Array:
	return _conn_by_target.get(item_id + "|" + handle_id, []) as Array


## Write an item's specs only when one of `keys` differs from what the model
## holds — EXACT comparison, so no value is ever left behind (the model dict
## is identical either way); only the signal cascade is saved. The PBI and
## catchment passes wrote unconditionally every step, and each write woke
## every `changed` listener (the placeholder host's O(N) sync, the pond push).
func _write_if_changed(iid: String, item: Dictionary, specs: Dictionary, keys: Array) -> void:
	var orig: Dictionary = item.get("specs", {}) as Dictionary
	for k in keys:
		if not orig.has(k) or orig[k] != specs[k]:
			_model.update_item(iid, {"specs": specs})
			return


## Sim telemetry onto a wire, CHANGE-GATED (floats within 1e-6 relative, else
## exact) and routed through `GraphModel.stamp_connection_telemetry`, whose
## "conn_telemetry" reason the view coalesces into a redraw and nothing else.
## `conn` may be a flattened edge: it is resolved by id, so the stamp lands on
## the REAL wire. Before this the culvert and JIT passes called
## update_connection unconditionally per edge per step, and each call queued a
## full electrical fault check and a conduit remesh sweep with the graph closed.
func _stamp_conn_telemetry(conn: Dictionary, updates: Dictionary) -> void:
	if _model == null:
		return
	var cid := str(conn.get("id", ""))
	if cid.is_empty():
		return
	var real: Variant = _conn_by_id.get(cid)
	var target: Dictionary = (real as Dictionary) if real is Dictionary else conn
	var dirty := false
	for k in updates:
		if not target.has(k):
			dirty = true
			break
		var nv: Variant = updates[k]
		var ov: Variant = target[k]
		if (nv is float or nv is int) and (ov is float or ov is int):
			if absf(float(nv) - float(ov)) > 1e-6 * maxf(1.0, absf(float(ov))):
				dirty = true
				break
		elif nv != ov:
			dirty = true
			break
	if dirty:
		_model.stamp_connection_telemetry(cid, updates)


## Add this step's flows to the per-wire ledger (live steps only).
func _ledger_step(dt_hours: float) -> void:
	if _render_ctx_active or dt_hours <= 0.0:
		return
	for cid in _conn_flow:
		var f: Dictionary = _conn_flow[cid]
		var rate := float(f.get("rate", 0.0))
		if rate > 0.0:
			_ledger_add(str(cid), rate * dt_hours, str(f.get("kind", "")))


func _ledger_add(conn_id: String, qty: float, kind: String) -> void:
	if conn_id.is_empty() or qty <= 0.0:
		return
	var cur: Array = _conn_qty.get(conn_id, [0.0, kind])
	cur[0] = float(cur[0]) + qty
	if str(cur[1]).is_empty():
		cur[1] = kind
	_conn_qty[conn_id] = cur


## What every wire carried since the last call: {conn id: [quantity, kind]}.
func take_conn_quantities() -> Dictionary:
	var out := _conn_qty
	_conn_qty = {}
	return out


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
