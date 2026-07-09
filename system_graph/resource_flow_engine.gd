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

## Emitted when any habitat's starved_kinds set changes (empty = all fed).
signal habitat_starvation_changed(item_id: String, starved_kinds: Array)

## Emitted when a tank transitions into/out of overflow (full while inflow > outflow).
signal tank_overflow_changed(item_id: String, overflowing: bool)

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
		ResourceKinds.new().migrate_resource_specs(specs)
		var tl := ResourceTimelineScript.new()
		tl.configure(float(specs.get("capacity_qty", 100.0)))
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
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["level"] = float(sample.get("level", specs.get("level", 0.0)))
	specs["inflow_rate"] = float(sample.get("inflow_rate", 0.0))
	specs["outflow_rate"] = float(sample.get("outflow_rate", 0.0))
	var iid := str(item.get("id", ""))
	var overflow_flip := false
	var over := false
	if tl != null and abs_hours >= 0.0:
		over = tl.is_overflowing_at(abs_hours)
		overflow_flip = over != bool(specs.get("overflowing", false))
		specs["overflowing"] = over
		specs["overflow_qty"] = tl.total_overflow_qty
	_model.update_item(iid, {"specs": specs})
	if overflow_flip:
		tank_overflow_changed.emit(iid, over)


func _simulate_step(abs_hours: float, dt_hours: float) -> void:
	# Per-tank net rates (qty/hour in tank's capacity units)
	var net_rates: Dictionary = {}

	for item: Dictionary in _model.items:
		var ty: String = str(item.get("type", ""))
		if ty == "catchment":
			_process_catchment(item, net_rates, dt_hours)
		elif ty == "processor":
			_process_processor(item, net_rates, dt_hours, abs_hours)

	# Integrate timelines
	for item: Dictionary in _model.items:
		if str(item.get("type", "")) != "resource":
			continue
		var iid: String = str(item.get("id", ""))
		if not _timelines.has(iid):
			continue
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		ResourceKinds.new().migrate_resource_specs(specs)
		var tl: ResourceTimeline = _timelines[iid] as ResourceTimeline
		tl.configure(float(specs.get("capacity_qty", 100.0)))
		var net: float = float(net_rates.get(iid, 0.0))
		var infl: float = maxf(net, 0.0)
		var outf: float = maxf(-net, 0.0)
		tl.record_step(abs_hours, net, infl, outf)
		var sample := tl.sample_at(abs_hours)
		_apply_tank_sample(item, sample, tl, abs_hours)


func _process_catchment(item: Dictionary, net_rates: Dictionary, _dt: float) -> void:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var kind := str(specs.get("catchment_kind", "rain"))
	if kind == "biomass":
		_process_biomass_catchment(item, specs, net_rates)
		return
	var area_m2: float = _catchment_area_m2(specs)
	var runoff: float = float(specs.get("runoff_coeff", 0.85))
	var rain_mmh := _rain_rate_mmh()
	if rain_mmh <= 0.0:
		return
	# mm/h * m² = L/h (1 mm on 1 m² = 1 L)
	var capture_lph: float = area_m2 * runoff * rain_mmh
	_credit_catchment_flow(item, net_rates, capture_lph, "water")


func _process_biomass_catchment(item: Dictionary, specs: Dictionary,
		net_rates: Dictionary) -> void:
	var area_m2: float = _catchment_area_m2(specs)
	if area_m2 <= 0.0:
		return
	var month := _sim_month()
	var capture_kg_h: float = PbiBiomassScript.biomass_kg_per_hour(area_m2, month)
	if capture_kg_h <= 0.0:
		return
	_credit_catchment_flow(item, net_rates, capture_kg_h, "biomass")


func _catchment_area_m2(specs: Dictionary) -> float:
	var soi_area := _soi_area_m2()
	return PbiBiomassScript.effective_area_m2(specs, soi_area)


func _soi_area_m2() -> float:
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
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return 6
	return int(main_node.get("month")) if main_node.get("month") != null else 6


func _credit_catchment_flow(item: Dictionary, net_rates: Dictionary,
		rate: float, want_kind: String) -> void:
	var iid := str(item.get("id", ""))
	# All outbound resource edges (default "output" + any hub_out_* ports).
	for conn: Dictionary in _model.connections:
		if str(conn.get("source_item_id", "")) != iid:
			continue
		if str(conn.get("polarity", "")) != "resource":
			continue
		var tgt_id: String = str(conn.get("target_item_id", ""))
		var tgt := _model.get_item(tgt_id)
		if tgt.is_empty() or str(tgt.get("type", "")) != "resource":
			continue
		var tgt_specs: Dictionary = tgt.get("specs", {}) as Dictionary
		ResourceKinds.new().migrate_resource_specs(tgt_specs)
		if str(tgt_specs.get("resource_kind", "")) != want_kind:
			continue
		net_rates[tgt_id] = float(net_rates.get(tgt_id, 0.0)) + rate
		_cache_conn_flow(str(conn.get("id", "")), rate, want_kind)


func _process_processor(item: Dictionary, net_rates: Dictionary, _dt: float,
		abs_hours: float = -1.0) -> void:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	ResourceKinds.new().migrate_processor_specs(specs)
	var abs_h: float = abs_hours if abs_hours >= 0.0 else _get_abs_hours()
	if abs_h < 0.0:
		abs_h = 0.0
	if str(specs.get("role", "")) == "habitat":
		_process_habitat(item, specs, net_rates, abs_h)
		return
	if bool(specs.get("batch_mode", false)):
		_process_processor_batch(item, specs, net_rates, _dt, abs_h)
		return
	if not _processor_powered(item):
		return

	var occupants: float = maxf(float(specs.get("occupants", 1.0)), 1.0)
	var efficiency: float = clampf(float(specs.get("efficiency", 1.0)), 0.0, 1.0)
	var inputs: Array = specs.get("inputs", []) as Array
	var outputs: Array = specs.get("outputs", []) as Array

	# Throughput limited by slowest input/output rate and tank availability.
	# Rates are scaled by occupants (default 1) so multi-unit processors share one path.
	var throughput: float = INF
	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		var rate: float = float(inp.get("rate", 0.0)) * occupants
		if rate <= 0.0:
			continue
		var tank_id := _tank_at_port(str(item.get("id", "")), "res_in_%d" % i, true)
		if tank_id.is_empty():
			# Same legacy-port fallback the consume loop below uses.
			tank_id = _tank_at_port(str(item.get("id", "")), "input", true)
		if tank_id.is_empty():
			throughput = 0.0
			break
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
		if tl == null:
			throughput = 0.0
			break
		var lvl := tl.level_at(abs_h)
		if lvl <= 0.001:
			throughput = 0.0
			break
		throughput = minf(throughput, rate)

	var unconnected_out: Array = []
	for i: int in outputs.size():
		var outp: Dictionary = outputs[i] as Dictionary
		var rate: float = float(outp.get("rate", 0.0)) * occupants
		if rate <= 0.0:
			continue
		var tank_id := _tank_at_port(str(item.get("id", "")), "res_out_%d" % i, false)
		if tank_id.is_empty():
			tank_id = _tank_at_port(str(item.get("id", "")), "output", false)
		if tank_id.is_empty():
			# Unwired output blocks the processor (all-or-nothing) — record why
			# so the UI can explain the idle instead of failing silently.
			var uk := ResourceKinds.normalize_kind(str(outp.get("kind", "")))
			if not uk.is_empty() and not unconnected_out.has(uk):
				unconnected_out.append(uk)
			throughput = 0.0
			break
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
		if tl == null:
			throughput = 0.0
			break
		var lvl := tl.level_at(abs_h)
		if lvl >= 0.999:
			throughput = 0.0
			break
		throughput = minf(throughput, rate)

	_write_output_unconnected(str(item.get("id", "")), specs, unconnected_out)
	if throughput == INF or throughput <= 0.0:
		return
	throughput *= efficiency

	# Legacy single output port
	if outputs.is_empty():
		var legacy_rate: float = float(ResourceKinds.parse_rate_text(
			str(specs.get("output_rate", ""))).get("rate", 0.0)) * occupants
		if legacy_rate > 0.0:
			throughput = legacy_rate * efficiency
			var out_id := _tank_at_port(str(item.get("id", "")), "output", false)
			if not out_id.is_empty():
				net_rates[out_id] = float(net_rates.get(out_id, 0.0)) + throughput

	var in_total: float = _total_io_rate(inputs) * occupants
	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		var kind: String = str(inp.get("kind", ""))
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

	var out_total: float = _total_io_rate(outputs) * occupants
	for i: int in outputs.size():
		var outp: Dictionary = outputs[i] as Dictionary
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
		var can_start := true
		
		# Set batch_active_watts for the START of the batch (elapsed=0) to see if power is available
		var req_watts := 0.0
		for inp: Variant in inputs:
			var inpd := inp as Dictionary
			if str(inpd.get("kind", "")) == "electric":
				if _is_active_in_phase(inpd, 0.0, batch_time):
					req_watts += float(inpd.get("rate", 0.0)) * occupants
		item["batch_active_watts"] = req_watts
		
		if req_watts > 0.0 and not _processor_powered(item):
			can_start = false
		
		if can_start:
			for i in inputs.size():
				var inp: Dictionary = inputs[i] as Dictionary
				var mode := str(inp.get("mode", "continuous"))
				var kind := str(inp.get("kind", ""))
				if kind == "electric": continue
				if mode == "frontloaded":
					var qty := float(inp.get("rate", 0.0)) * occupants
					if qty <= 0.0: continue
					var tank_id := _tank_at_port(item_id, "res_in_%d" % i, true)
					if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "input", true)
					if tank_id.is_empty():
						can_start = false; break
					var tl := _timelines.get(tank_id) as ResourceTimeline
					if tl == null or tl.level_at(abs_h) < qty:
						can_start = false; break
		
		if can_start:
			for i in inputs.size():
				var inp: Dictionary = inputs[i] as Dictionary
				var mode := str(inp.get("mode", "continuous"))
				if mode == "frontloaded" and str(inp.get("kind", "")) != "electric":
					var qty := float(inp.get("rate", 0.0)) * occupants
					if qty <= 0.0: continue
					var tank_id := _tank_at_port(item_id, "res_in_%d" % i, true)
					if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "input", true)
					net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) - (qty / dt_hours)
					
			state["state"] = "running"
			state["elapsed"] = 0.0
			state["penalty_qty"] = 0.0
		else:
			return
			
	if str(state["state"]) == "running":
		var elapsed: float = float(state["elapsed"])
		var penalty: float = float(state["penalty_qty"])
		
		var req_watts := 0.0
		for inp: Variant in inputs:
			var inpd := inp as Dictionary
			if str(inpd.get("kind", "")) == "electric" and _is_active_in_phase(inpd, elapsed, batch_time):
				req_watts += float(inpd.get("rate", 0.0)) * occupants
		item["batch_active_watts"] = req_watts
		
		var powered := true
		if req_watts > 0.0:
			powered = _processor_powered(item)
			
		var missing_inputs := false
		var frame_pulls := {}
		for i in inputs.size():
			var inp: Dictionary = inputs[i] as Dictionary
			var kind := str(inp.get("kind", ""))
			if kind == "electric": continue
			if _is_active_in_phase(inp, elapsed, batch_time):
				var qty_per_hr := 0.0
				var mode := str(inp.get("mode", "continuous"))
				if mode == "continuous":
					qty_per_hr = (float(inp.get("rate", 0.0)) * occupants) / batch_time
				elif mode == "delayed":
					var dur := maxf(float(inp.get("duration_hrs", 1.0)), 0.001)
					qty_per_hr = (float(inp.get("rate", 0.0)) * occupants) / dur
				
				if qty_per_hr > 0.0:
					var tank_id := _tank_at_port(item_id, "res_in_%d" % i, true)
					if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "input", true)
					if tank_id.is_empty():
						missing_inputs = true; break
					var tl := _timelines.get(tank_id) as ResourceTimeline
					if tl == null or tl.level_at(abs_h) < (qty_per_hr * dt_hours):
						missing_inputs = true; break
					frame_pulls[tank_id] = float(frame_pulls.get(tank_id, 0.0)) + qty_per_hr
		
		if not powered or missing_inputs:
			var fail_mode := str(specs.get("batch_failure_mode", "pause_and_resume"))
			if fail_mode == "pause_and_resume":
				return
			elif fail_mode == "restart_with_penalty":
				state["state"] = "idle"
				return
			elif fail_mode == "destroy_batch":
				state["state"] = "idle"
				return
				
		for tank_id: Variant in frame_pulls:
			net_rates[str(tank_id)] = float(net_rates.get(str(tank_id), 0.0)) - float(frame_pulls[tank_id])
			
		var frame_pushes := {}
		for i in outputs.size():
			var outp: Dictionary = outputs[i] as Dictionary
			if _is_active_in_phase(outp, elapsed, batch_time):
				var qty_per_hr := 0.0
				var mode := str(outp.get("mode", "continuous"))
				if mode == "continuous":
					qty_per_hr = (float(outp.get("rate", 0.0)) * occupants * eff) / batch_time
				elif mode == "delayed":
					var dur := maxf(float(outp.get("duration_hrs", 1.0)), 0.001)
					qty_per_hr = (float(outp.get("rate", 0.0)) * occupants * eff) / dur
				
				if qty_per_hr > 0.0:
					var tank_id := _tank_at_port(item_id, "res_out_%d" % i, false)
					if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "output", false)
					if not tank_id.is_empty():
						frame_pushes[tank_id] = float(frame_pushes.get(tank_id, 0.0)) + qty_per_hr
						
		for tank_id: Variant in frame_pushes:
			net_rates[str(tank_id)] = float(net_rates.get(str(tank_id), 0.0)) + float(frame_pushes[tank_id])
			
		state["elapsed"] = elapsed + dt_hours
		
		if float(state["elapsed"]) >= batch_time:
			for i in outputs.size():
				var outp: Dictionary = outputs[i] as Dictionary
				var mode := str(outp.get("mode", "continuous"))
				if mode == "end_batch":
					var qty := float(outp.get("rate", 0.0)) * occupants * eff
					if qty > 0.0:
						var tank_id := _tank_at_port(item_id, "res_out_%d" % i, false)
						if tank_id.is_empty(): tank_id = _tank_at_port(item_id, "output", false)
						if not tank_id.is_empty():
							net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) + (qty / dt_hours)
			
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
	var water_consumed_lph := 0.0
	var food_consumed_kgph := 0.0

	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		var kind: String = ResourceKinds.normalize_kind(str(inp.get("kind", "")))
		var rate: float = float(inp.get("rate", 0.0)) * occupants
		if rate <= 0.0:
			continue
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
		if tl != null and tl.level_at(abs_h) >= 0.999:
			continue
		net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) + credit
		for conn: Dictionary in _connections_from_handle(iid, "res_out_%d" % i):
			_cache_conn_flow(str(conn.get("id", "")), credit, kind)

	_write_habitat_starved(iid, specs, starved)


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


func _total_io_rate(arr: Array) -> float:
	var t := 0.0
	for e: Variant in arr:
		if e is Dictionary:
			t += float((e as Dictionary).get("rate", 0.0))
	return maxf(t, 0.001)


func _processor_powered(item: Dictionary) -> bool:
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
	ResourceKinds.new().migrate_processor_specs(specs)
	var es: String = str(specs.get("energy_source", ""))
	if es.is_empty() and float(specs.get("watts", 0.0)) > 0.0:
		es = "ac"
	if es == "ac":
		if not _ac_output_available():
			return false
		if not _has_incoming_connection(iid, "power_in"):
			return false
		var sim_host: Node = _host.get_node_or_null("GraphSimLoadHost") if _host != null else null
		if sim_host != null and sim_host.has_method("is_load_on"):
			return bool(sim_host.call("is_load_on", iid))
		var st: String = str(specs.get("current_state", "")).to_lower()
		if st == "off":
			return false
		return float(specs.get("watts", 0.0)) > 0.0 or st == "on"
	elif es == "thermal" or es == "mechanical":
		if not _has_incoming_connection(iid, "energy_in"):
			return false
		var st2: String = str(specs.get("current_state", "")).to_lower()
		if st2 == "off":
			return false
		return true
	if float(specs.get("watts", 0.0)) <= 0.0:
		return true
	return _ac_output_available()


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
	if su.has_method("is_ac_output_enabled"):
		return bool(su.call("is_ac_output_enabled"))
	if su.has_method("is_power_available"):
		return bool(su.call("is_power_available"))
	return false


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
	for conn: Dictionary in _model.connections:
		if str(conn.get("target_item_id", "")) == item_id \
				and str(conn.get("target_handle_id", "")) == handle_id:
			return true
	return false


func _rain_rate_mmh() -> float:
	var main_node: Node = null
	if _host != null and _host.has_method("_get_scene_main_node"):
		main_node = _host.call("_get_scene_main_node")
	if main_node == null:
		return 0.0
	var month: int = int(main_node.get("month")) if main_node.get("month") != null else 6
	var day: int = int(main_node.get("day")) if main_node.get("day") != null else 1
	var hour: float = float(main_node.get("day_time")) if main_node.get("day_time") != null else 12.0
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


func _tank_at_port(proc_id: String, handle_id: String, want_input: bool) -> String:
	if want_input:
		for conn: Dictionary in _connections_to_handle(proc_id, handle_id):
			var src_id: String = str(conn.get("source_item_id", ""))
			var src := _model.get_item(src_id)
			if not src.is_empty() and str(src.get("type", "")) == "resource":
				return src_id
		# Any resource→processor edge (hub_* tank ports still count).
		if handle_id == "input" or handle_id.begins_with("res_in_"):
			for conn: Dictionary in _model.connections:
				if str(conn.get("polarity", "")) != "resource":
					continue
				if str(conn.get("target_item_id", "")) != proc_id:
					continue
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
			for conn: Dictionary in _model.connections:
				if str(conn.get("polarity", "")) != "resource":
					continue
				if str(conn.get("source_item_id", "")) != proc_id:
					continue
				var tgt2 := _model.get_item(str(conn.get("target_item_id", "")))
				if not tgt2.is_empty() and str(tgt2.get("type", "")) == "resource":
					return str(tgt2.get("id", ""))
	return ""


func _connections_from_handle(item_id: String, handle_id: String) -> Array:
	var out: Array = []
	for conn: Dictionary in _model.connections:
		if str(conn.get("source_item_id", "")) == item_id \
				and str(conn.get("source_handle_id", "")) == handle_id:
			out.append(conn)
	return out


func _connections_to_handle(item_id: String, handle_id: String) -> Array:
	var out: Array = []
	for conn: Dictionary in _model.connections:
		if str(conn.get("target_item_id", "")) == item_id \
				and str(conn.get("target_handle_id", "")) == handle_id:
			out.append(conn)
	return out


func _cache_conn_flow(conn_id: String, rate: float, kind: String = "") -> void:
	_conn_flow[conn_id] = {"rate": rate, "active": rate > 0.001, "kind": kind}
	# Mirror live rate on the connection dict for inspector/tooling (no changed signal).
	if _model == null:
		return
	for conn: Dictionary in _model.connections:
		if str(conn.get("id", "")) == conn_id:
			conn["flow_rate"] = rate
			conn["flow_active"] = rate > 0.001
			if not kind.is_empty():
				conn["resource_type"] = ResourceKinds.normalize_kind(kind)
			break


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
