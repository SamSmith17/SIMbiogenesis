class_name ResourceFlowEngine
extends RefCounted

## Simulates multi-resource flow through graph processors and catchment nodes.
## Tank levels are reversible via ResourceTimeline (scrub-safe like battery SOC).

const ResourceTimelineScript := preload("res://core/resource_timeline.gd")

var _model: GraphModel = null
var _host: Node = null
var _timelines: Dictionary = {}   # item_id -> ResourceTimeline
var _last_abs_hours: float = -1.0
var _tick_accum: float = 0.0
const TICK_INTERVAL := 0.25

## conn_id -> {rate, active} cached for wire animation
var _conn_flow: Dictionary = {}


func setup(model: GraphModel, host: Node) -> void:
	_model = model
	_host = host
	_timelines.clear()
	_conn_flow.clear()
	_last_abs_hours = -1.0


func clear_timelines() -> void:
	_timelines.clear()
	_conn_flow.clear()
	_last_abs_hours = -1.0


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
	var live_ids: Dictionary = {}
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
		tl.init_anchor(_get_abs_hours(), float(specs.get("level", 0.5)))
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
		_apply_tank_sample(item, sample)


func _apply_tank_sample(item: Dictionary, sample: Dictionary) -> void:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["level"] = float(sample.get("level", specs.get("level", 0.0)))
	specs["inflow_rate"] = float(sample.get("inflow_rate", 0.0))
	specs["outflow_rate"] = float(sample.get("outflow_rate", 0.0))
	_model.update_item(str(item.get("id", "")), {"specs": specs})


func _simulate_step(abs_hours: float, dt_hours: float) -> void:
	# Per-tank net rates (qty/hour in tank's capacity units)
	var net_rates: Dictionary = {}

	for item: Dictionary in _model.items:
		var ty: String = str(item.get("type", ""))
		if ty == "catchment":
			_process_catchment(item, net_rates, dt_hours)
		elif ty == "processor":
			_process_processor(item, net_rates, dt_hours)

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
		_apply_tank_sample(item, sample)


func _process_catchment(item: Dictionary, net_rates: Dictionary, _dt: float) -> void:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var area_m2: float = float(specs.get("area_m2", 10.0))
	var runoff: float = float(specs.get("runoff_coeff", 0.85))
	var rain_mmh := _rain_rate_mmh()
	if rain_mmh <= 0.0:
		return
	# mm/h * m² = L/h (1 mm on 1 m² = 1 L)
	var capture_lph: float = area_m2 * runoff * rain_mmh
	var out_conns := _connections_from_handle(str(item.get("id", "")), "output")
	for conn: Dictionary in out_conns:
		var tgt_id: String = str(conn.get("target_item_id", ""))
		var tgt := _model.get_item(tgt_id)
		if tgt.is_empty() or str(tgt.get("type", "")) != "resource":
			continue
		var tgt_specs: Dictionary = tgt.get("specs", {}) as Dictionary
		ResourceKinds.new().migrate_resource_specs(tgt_specs)
		if str(tgt_specs.get("resource_kind", "")) != "water":
			continue
		net_rates[tgt_id] = float(net_rates.get(tgt_id, 0.0)) + capture_lph
		_cache_conn_flow(str(conn.get("id", "")), capture_lph, "water")


func _process_processor(item: Dictionary, net_rates: Dictionary, _dt: float) -> void:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	ResourceKinds.new().migrate_processor_specs(specs)
	if not _processor_powered(item):
		return

	var efficiency: float = clampf(float(specs.get("efficiency", 1.0)), 0.0, 1.0)
	var inputs: Array = specs.get("inputs", []) as Array
	var outputs: Array = specs.get("outputs", []) as Array

	# Throughput limited by slowest input/output rate and tank availability
	var throughput: float = INF
	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		var rate: float = float(inp.get("rate", 0.0))
		if rate <= 0.0:
			continue
		var tank_id := _tank_at_port(str(item.get("id", "")), "res_in_%d" % i, true)
		if tank_id.is_empty():
			throughput = 0.0
			break
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
		if tl == null:
			throughput = 0.0
			break
		var lvl := tl.level_at(_get_abs_hours())
		if lvl <= 0.001:
			throughput = 0.0
			break
		throughput = minf(throughput, rate)

	for i: int in outputs.size():
		var outp: Dictionary = outputs[i] as Dictionary
		var rate: float = float(outp.get("rate", 0.0))
		if rate <= 0.0:
			continue
		var tank_id := _tank_at_port(str(item.get("id", "")), "res_out_%d" % i, false)
		if tank_id.is_empty():
			throughput = 0.0
			break
		var tl: ResourceTimeline = _timelines.get(tank_id) as ResourceTimeline
		if tl == null:
			throughput = 0.0
			break
		var lvl := tl.level_at(_get_abs_hours())
		if lvl >= 0.999:
			throughput = 0.0
			break
		throughput = minf(throughput, rate)

	if throughput == INF or throughput <= 0.0:
		return
	throughput *= efficiency

	# Legacy single output port
	if outputs.is_empty():
		var legacy_rate: float = float(ResourceKinds.parse_rate_text(
			str(specs.get("output_rate", ""))).get("rate", 0.0))
		if legacy_rate > 0.0:
			throughput = legacy_rate * efficiency
			var out_id := _tank_at_port(str(item.get("id", "")), "output", false)
			if not out_id.is_empty():
				net_rates[out_id] = float(net_rates.get(out_id, 0.0)) + throughput

	for i: int in inputs.size():
		var inp: Dictionary = inputs[i] as Dictionary
		var kind: String = str(inp.get("kind", ""))
		var rate: float = float(inp.get("rate", 0.0))
		if rate <= 0.0:
			continue
		var portion: float = throughput * (rate / maxf(_total_io_rate(inputs), 0.001))
		var tank_id := _tank_at_port(str(item.get("id", "")), "res_in_%d" % i, true)
		if tank_id.is_empty():
			tank_id = _tank_at_port(str(item.get("id", "")), "input", true)
		if tank_id.is_empty():
			continue
		net_rates[tank_id] = float(net_rates.get(tank_id, 0.0)) - portion
		for conn: Dictionary in _connections_to_handle(str(item.get("id", "")), "res_in_%d" % i):
			_cache_conn_flow(str(conn.get("id", "")), portion, kind)

	for i: int in outputs.size():
		var outp: Dictionary = outputs[i] as Dictionary
		var rate: float = float(outp.get("rate", 0.0))
		if rate <= 0.0:
			continue
		var portion: float = throughput * (rate / maxf(_total_io_rate(outputs), 0.001))
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


func _total_io_rate(arr: Array) -> float:
	var t := 0.0
	for e: Variant in arr:
		if e is Dictionary:
			t += float((e as Dictionary).get("rate", 0.0))
	return maxf(t, 0.001)


func _processor_powered(item: Dictionary) -> bool:
	if _host == null or _model == null:
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
		var sim_host: Node = _host.get_node_or_null("GraphSimLoadHost")
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
	var apb: Node = null
	if _host != null and is_instance_valid(_host):
		apb = _host.get_node_or_null("/root/AcPowerBus")
	if apb != null and "ac_output_enabled" in apb:
		return bool(apb.ac_output_enabled)
	var su := _get_primary_solar_ui()
	if su == null:
		return true
	if su.has_method("is_ac_output_enabled"):
		return bool(su.call("is_ac_output_enabled"))
	if su.has_method("is_power_available"):
		return bool(su.call("is_power_available"))
	return true


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
	else:
		for conn: Dictionary in _connections_from_handle(proc_id, handle_id):
			var tgt_id: String = str(conn.get("target_item_id", ""))
			var tgt := _model.get_item(tgt_id)
			if not tgt.is_empty() and str(tgt.get("type", "")) == "resource":
				return tgt_id
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


func reanchor_tank(item_id: String, level: float) -> void:
	if not _timelines.has(item_id):
		_ensure_timelines()
	if _timelines.has(item_id):
		var tl: ResourceTimeline = _timelines[item_id] as ResourceTimeline
		tl.clear()
		tl.init_anchor(_get_abs_hours(), level)
