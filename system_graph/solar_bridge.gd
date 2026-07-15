class_name SolarBridge
extends RefCounted
## Solar Bridge — mirrors the live Godot solar simulation into virtual GraphModel items.
## SystemGraphView holds one instance and calls tick(delta) from _process().
##
## Virtual items:
##   virtual_solar_array, virtual_controller (inverter AC out), virtual_battery,
##   virtual_baseline, virtual_device_{PowerDevice.device_id},
##   virtual_load_{sanitized_path} for other power_consumers (e.g. Govee path lights).
##
## Virtual connections: PV↔controller, controller↔battery, AC output → every virtual load input.

var _model:    GraphModel = null
var _solar_ui: Control    = null
var _poll_acc: float      = 0.0

const POLL_INTERVAL := 0.25

const V_PANEL_ID    := "virtual_solar_array"
const V_CTRL_ID     := "virtual_controller"
const V_BATTERY_ID  := "virtual_battery"
const V_BASELINE_ID := "virtual_baseline"

const V_CONN_PC_POS := "vconn_pc_pos"
const V_CONN_PC_NEG := "vconn_pc_neg"
const V_CONN_CB_POS := "vconn_cb_pos"
const V_CONN_CB_NEG := "vconn_cb_neg"

const ARRAY_GROUPS := 3
const ARRAY_STRINGS_PER_GROUP := 2
const ARRAY_SERIES_PER_STRING := 3
const ARRAY_PANEL_COUNT := ARRAY_GROUPS * ARRAY_STRINGS_PER_GROUP * ARRAY_SERIES_PER_STRING  # 18

## PowerDevice.device_id → graph item id (same as before: virtual_device_*)
var _device_item_ids: Dictionary = {}
## NodePath string → graph item id for all consumers (including duck-typed)
var _path_to_graph_id: Dictionary = {}

## Set of virtual node / connection IDs that the user has deliberately removed
## from the graph canvas.  solar_bridge will not re-create any ID found here.
## Populated and kept in sync by SystemGraphView._suppress_virtual().
var suppressed_ids: Dictionary = {}


func setup(model: GraphModel, solar_ui: Control) -> void:
	_model    = model
	_solar_ui = solar_ui
	_poll_acc = POLL_INTERVAL
	if _model != null and not _model.changed.is_connected(_on_model_changed):
		_model.changed.connect(_on_model_changed)


func teardown() -> void:
	if _model != null and _model.changed.is_connected(_on_model_changed):
		_model.changed.disconnect(_on_model_changed)
	_model    = null
	_solar_ui = null


func tick(delta: float) -> void:
	if _model == null or not is_instance_valid(_solar_ui):
		return
	_poll_acc += delta
	if _poll_acc < POLL_INTERVAL:
		return
	_poll_acc = 0.0
	_ensure_virtual_nodes()
	_refresh_virtual_nodes()


func _on_model_changed(reason: String) -> void:
	if reason == "clear" or reason == "deserialize":
		_poll_acc = POLL_INTERVAL


func _ensure_virtual_nodes() -> void:
	_ensure_consumer_nodes()
	if _legacy_virtual_solar_active():
		if not suppressed_ids.has(V_PANEL_ID) and _model.get_item(V_PANEL_ID).is_empty():
			_model.add_item(_make_panel_item())
		if not suppressed_ids.has(V_PANEL_ID):
			_ensure_virtual_panel_cluster()
		if not suppressed_ids.has(V_CTRL_ID) and _model.get_item(V_CTRL_ID).is_empty():
			_model.add_item(_make_controller_item())
		if not suppressed_ids.has(V_BATTERY_ID) and _model.get_item(V_BATTERY_ID).is_empty():
			_model.add_item(_make_battery_item())
		if not suppressed_ids.has(V_BASELINE_ID) and _model.get_item(V_BASELINE_ID).is_empty():
			_model.add_item(_make_baseline_item())
		_ensure_virtual_connections()
	_ensure_ac_load_connections()


## Legacy saves still carry virtual_panel_* / virtual_controller; refresh those only
## when they already exist and were not user-suppressed. New maps stay blank.
func _legacy_virtual_solar_active() -> bool:
	if suppressed_ids.has(V_PANEL_ID):
		return false
	if not _model.get_item(V_PANEL_ID).is_empty():
		return true
	for i in range(ARRAY_PANEL_COUNT):
		if not _model.get_item(_panel_node_id(i)).is_empty():
			return true
	if not _model.get_item(V_CTRL_ID).is_empty():
		return true
	if not _model.get_item(V_BATTERY_ID).is_empty():
		return true
	return false


func _consumer_graph_id(consumer: Node) -> String:
	if consumer is PowerDevice:
		var pd := consumer as PowerDevice
		return "virtual_device_%s" % pd.device_id
	var pth := str(consumer.get_path())
	var safe := pth.replace(":", "_").replace("@", "_")
	safe = safe.replace("/", "_")
	while safe.begins_with("_"):
		safe = safe.substr(1)
	return "virtual_load_%s" % safe


func _ensure_consumer_nodes() -> void:
	if not is_instance_valid(_solar_ui):
		return
	var tree := _solar_ui.get_tree()
	if tree == null:
		return
	var consumers: Array[Node] = tree.get_nodes_in_group("power_consumers")
	consumers.sort_custom(func(a: Node, b: Node) -> bool:
		return str(a.get_path()) < str(b.get_path())
	)
	_path_to_graph_id.clear()
	_device_item_ids.clear()
	var slot := 0
	for consumer: Node in consumers:
		if consumer == null or not is_instance_valid(consumer):
			continue
		# Skip graph-only sim loads — they're proxies for library-spawned items
		# and already have their own graph entries.
		if consumer.has_meta("graph_sim_load") and bool(consumer.get_meta("graph_sim_load")):
			continue
		var graph_id := _consumer_graph_id(consumer)
		_path_to_graph_id[str(consumer.get_path())] = graph_id
		if consumer is PowerDevice:
			_device_item_ids[(consumer as PowerDevice).device_id] = graph_id
		if suppressed_ids.has(graph_id):
			slot += 1
			continue
		if _model.get_item(graph_id).is_empty():
			var nm: String
			var max_w: float
			var avg_w: float
			var state_s: String = ""
			var dev_path := str(consumer.get_path())
			if consumer is PowerDevice:
				var pd := consumer as PowerDevice
				nm       = pd.device_name
				max_w    = pd.rated_power_watts
				avg_w    = pd.get_current_power()
				state_s  = pd.get_state_string().to_lower()
			else:
				nm = str(consumer.name)
				if consumer.get("display_name") != null:
					nm = str(consumer.get("display_name"))
				max_w = float(consumer.get("wattage")) if consumer.get("wattage") != null else 25.0
				if consumer.has_method("get_current_power"):
					avg_w = float(consumer.call("get_current_power"))
				else:
					avg_w = 0.0
				if consumer.get("is_on") != null:
					state_s = "on" if bool(consumer.get("is_on")) else "off"
			_model.add_item({
				"id":           graph_id,
				"type":         "appliance",
				"x":            360.0,
				"y":            140.0 + slot * 90.0,
				"width":        130.0,
				"height":       70.0,
				"is_virtual":   true,
				"device_path":  dev_path,
				"specs": {
					"name":          nm,
					"max_watts":     max_w,
					"avg_watts":     avg_w,
					"current_state": state_s,
					"cost":          0.0,
				},
			})
		slot += 1


func _ensure_virtual_connections() -> void:
	# Legacy aggregate panel wiring is replaced by explicit per-panel array wiring.
	if not _model.get_connection(V_CONN_PC_POS).is_empty():
		_model.remove_connection(V_CONN_PC_POS)
	if not _model.get_connection(V_CONN_PC_NEG).is_empty():
		_model.remove_connection(V_CONN_PC_NEG)
	if not suppressed_ids.has(V_CTRL_ID):
		_ensure_virtual_panel_connections()
		_maybe_add_conn(V_CONN_CB_POS, "positive",
			V_CTRL_ID, "batteryPositive", V_BATTERY_ID, "positive")
		_maybe_add_conn(V_CONN_CB_NEG, "negative",
			V_CTRL_ID, "batteryNegative", V_BATTERY_ID, "negative")


func _ensure_ac_load_connections() -> void:
	# If the inverter controller node was user-deleted, there is no AC output to wire from.
	if suppressed_ids.has(V_CTRL_ID):
		return
	for item: Dictionary in _model.items:
		if not bool(item.get("is_virtual", false)):
			continue
		var iid: String = item.get("id", "") as String
		if iid != V_BASELINE_ID and not iid.begins_with("virtual_device_") and not iid.begins_with("virtual_load_"):
			continue
		var itype: String = item.get("type", "") as String
		if itype != "appliance" and itype != "acload":
			continue
		var conn_id := "vconn_ac_%s" % iid
		# Skip if the user has manually removed this wire or the load node itself.
		if suppressed_ids.has(conn_id) or suppressed_ids.has(iid):
			continue
		_maybe_add_conn(conn_id, "ac",
			V_CTRL_ID, "acOutput",
			iid, "input")


func _maybe_add_conn(conn_id: String, polarity: String,
		src_item: String, src_handle: String,
		tgt_item: String, tgt_handle: String) -> void:
	if suppressed_ids.has(conn_id):
		return
	if _model.get_connection(conn_id).is_empty():
		_model.add_connection({
			"id":               conn_id,
			"polarity":         polarity,
			"source_item_id":   src_item,
			"source_handle_id": src_handle,
			"target_item_id":   tgt_item,
			"target_handle_id": tgt_handle,
			"waypoints":        [],
			"voltage_mismatch": false,
		})


func _refresh_virtual_nodes() -> void:
	_refresh_consumers()
	if not _legacy_virtual_solar_active():
		return
	if not _model.get_item(V_PANEL_ID).is_empty():
		_refresh_panel()
	if not _model.get_item(V_CTRL_ID).is_empty():
		_refresh_controller()
	if not _model.get_item(V_BATTERY_ID).is_empty():
		_refresh_battery()
	if not _model.get_item(V_BASELINE_ID).is_empty():
		_refresh_baseline()


## Merge live bridge values into the item's existing specs without clobbering
## user-authored fields like ha_links/ha_live/graph_automation_id/etc. When an HA
## live value is available for a role, prefer that value over the incoming
## simulated one so the graph mirrors reality in live mode.
func _merge_specs(existing: Dictionary, incoming: Dictionary) -> Dictionary:
	var merged: Dictionary = existing.duplicate(true)
	var live: Dictionary = (existing.get("ha_live", {}) as Dictionary)
	for k: String in incoming.keys():
		if _live_wins_for_key(live, k):
			continue
		merged[k] = incoming[k]
	return merged


func _live_wins_for_key(live: Dictionary, key: String) -> bool:
	if not _should_use_live_overrides():
		return false
	if live.is_empty():
		return false
	match key:
		"soc":
			return live.has("soc")
		"current_output_kw":
			# Mirrored from panel/power or controller/ac_power
			return live.has("power") or live.has("ac_power")
		"voltage":
			return live.has("voltage")
		"avg_watts":
			# Appliance node linked to a plug/clamp sensor — don't overwrite
			# with the simulated power while a live HA reading is available.
			return live.has("power")
		"current_state":
			return live.has("switch")
	return false


## Live HA-linked values should only override simulation values in true LIVE
## mode. TimeDirector is the single authority — consult it first so the bridge,
## HAEntityLinker, and the graph view can't disagree; fall back to SolarUI's
## own flag only when TimeDirector is unavailable.
func _should_use_live_overrides() -> bool:
	if not is_instance_valid(_solar_ui):
		return false
	var td := _solar_ui.get_node_or_null("/root/TimeDirector")
	if td != null and td.has_method("should_apply_live_data"):
		return bool(td.call("should_apply_live_data"))
	if _solar_ui.has_method("is_in_live_mode"):
		return bool(_solar_ui.call("is_in_live_mode"))
	return true


func _refresh_panel() -> void:
	var panel_count:   int   = int(_read("PANEL_COUNT",       18))
	var panel_wattage: float = float(_read("PANEL_WATTAGE",  220.0))
	var solar_kw:      float = float(_read("current_solar_kw", 0.0))
	var prev := (_model.get_item(V_PANEL_ID).get("specs", {}) as Dictionary).duplicate(true)
	_model.update_item(V_PANEL_ID, {
		"specs": _merge_specs(prev, {
			"name":              "%d× %.0fW Solar Array" % [panel_count, panel_wattage],
			"wmp":               panel_count * panel_wattage,
			"voc":               37.5,
			"vmp":               30.0,
			"isc":               8.7,
			"imp":               panel_wattage / 30.0,
			"cost":              0.0,
			"current_output_kw": solar_kw,
		}),
	})
	_refresh_virtual_panel_cluster(panel_wattage, solar_kw)


func _refresh_controller() -> void:
	var peak_kw:  float = float(_read("PEAK_CAPACITY_KW", 0.0))
	var solar_kw: float = float(_read("current_solar_kw",  0.0))
	if peak_kw <= 0.0:
		var cnt: int   = int(_read("PANEL_COUNT",    18))
		var w:   float = float(_read("PANEL_WATTAGE", 220.0))
		peak_kw = cnt * w / 1000.0
	var prev := (_model.get_item(V_CTRL_ID).get("specs", {}) as Dictionary).duplicate(true)
	var merged := _merge_specs(prev, {
		"name":              "Hybrid Inverter / MPPT",
		"max_voc":           prev.get("max_voc", 150.0),
		"max_charge_amps":   prev.get("max_charge_amps", 50.0),
		"max_pv_watts":      peak_kw * 1000.0,
		"cost":              0.0,
		"current_output_kw": solar_kw,
	})
	if bool(prev.get("destroyed", false)):
		merged["destroyed"] = true
		merged["destroyed_reason"] = prev.get("destroyed_reason", "")
		merged["fault_voc"] = prev.get("fault_voc", 0.0)
	_model.update_item(V_CTRL_ID, {"specs": merged})
	# Push user-configured overload protection thresholds to solar_ui
	if is_instance_valid(_solar_ui):
		var ctrl_specs := (_model.get_item(V_CTRL_ID).get("specs", {}) as Dictionary)
		if ctrl_specs.has("overload_watts"):
			_solar_ui.inverter_overload_watts = float(ctrl_specs["overload_watts"])
		if ctrl_specs.has("overload_duration_s"):
			_solar_ui.inverter_overload_duration = float(ctrl_specs["overload_duration_s"])
		if ctrl_specs.has("overload_lockout_s"):
			_solar_ui.inverter_lockout_duration = float(ctrl_specs["overload_lockout_s"])


func _refresh_battery() -> void:
	var bat_kwh: float
	var bat_cap: float
	if is_instance_valid(_solar_ui) and _solar_ui.has_method("get_battery_kwh_stored"):
		bat_kwh = _solar_ui.get_battery_kwh_stored()
		bat_cap = _solar_ui.get_battery_capacity_kwh()
	else:
		bat_kwh = float(_read("battery_kwh_stored",   8.0))
		bat_cap = float(_read("BATTERY_CAPACITY_KWH", 16.0))
	var soc: float = bat_kwh / bat_cap if bat_cap > 0.0 else 0.0
	var prev := (_model.get_item(V_BATTERY_ID).get("specs", {}) as Dictionary).duplicate(true)
	_model.update_item(V_BATTERY_ID, {
		"specs": _merge_specs(prev, {
			"name":    "Battery Bank",
			"voltage": 48.0,
			"ah":      bat_cap * 1000.0 / 48.0,
			"kwh":     bat_cap,
			"soc":     soc,
			"cost":    0.0,
		}),
	})
	# Push user-configured SOC protection thresholds to solar_ui
	if is_instance_valid(_solar_ui):
		var bat_specs := (_model.get_item(V_BATTERY_ID).get("specs", {}) as Dictionary)
		if bat_specs.has("soc_shutdown_pct"):
			_solar_ui.battery_soc_shutdown_pct = float(bat_specs["soc_shutdown_pct"])
		if bat_specs.has("soc_resume_pct"):
			_solar_ui.battery_soc_resume_pct = float(bat_specs["soc_resume_pct"])


func _refresh_baseline() -> void:
	var kw: float = float(_read("BASELINE_LOAD_KW", 0.35))
	var prev := (_model.get_item(V_BASELINE_ID).get("specs", {}) as Dictionary).duplicate(true)
	_model.update_item(V_BASELINE_ID, {
		"specs": _merge_specs(prev, {
			"name":      "Baseline Load (%.0fW)" % (kw * 1000.0),
			"max_watts": kw * 1000.0,
			"avg_watts": kw * 1000.0,
			"cost":      0.0,
		}),
	})


func _refresh_consumers() -> void:
	if not is_instance_valid(_solar_ui):
		return
	var tree := _solar_ui.get_tree()
	if tree == null:
		return
	var consumers: Array[Node] = tree.get_nodes_in_group("power_consumers")
	for consumer: Node in consumers:
		if consumer == null or not is_instance_valid(consumer):
			continue
		if consumer.has_meta("graph_sim_load") and bool(consumer.get_meta("graph_sim_load")):
			continue
		var graph_id: String = _path_to_graph_id.get(str(consumer.get_path()), "") as String
		if graph_id.is_empty():
			graph_id = _consumer_graph_id(consumer)
		if _model.get_item(graph_id).is_empty():
			continue
		var prev_specs := (_model.get_item(graph_id).get("specs", {}) as Dictionary).duplicate(true)
		var patch: Dictionary
		if consumer is PowerDevice:
			var pd := consumer as PowerDevice
			patch = {
				"name":          pd.device_name,
				"max_watts":     pd.rated_power_watts,
				"avg_watts":     pd.get_current_power(),
				"current_state": pd.get_state_string().to_lower(),
				"cost":          0.0,
			}
		else:
			var nm: String = str(consumer.name)
			if consumer.get("display_name") != null:
				nm = str(consumer.get("display_name"))
			var max_w := float(consumer.get("wattage")) if consumer.get("wattage") != null else 25.0
			var avg_w := 0.0
			if consumer.has_method("get_current_power"):
				avg_w = float(consumer.call("get_current_power"))
			var st := ""
			if consumer.get("is_on") != null:
				st = "on" if bool(consumer.get("is_on")) else "off"
			patch = {
				"name":          nm,
				"max_watts":     max_w,
				"avg_watts":     avg_w,
				"current_state": st,
				"cost":          0.0,
			}
		_model.update_item(graph_id, {"specs": _merge_specs(prev_specs, patch)})


func _make_panel_item() -> Dictionary:
	var cnt: int   = int(_read("PANEL_COUNT",    18))
	var w:   float = float(_read("PANEL_WATTAGE", 220.0))
	return {
		"id":         V_PANEL_ID,
		"type":       "panel",
		"x":          -1650.0, # summary node kept for totals/compatibility; hidden off-canvas
		"y":          -1050.0,
		"width":      168.0,
		"height":     96.0,
		"is_virtual": true,
		"layout_exclude": true,
		"specs": {
			"name": "%d× %.0fW Solar Array" % [cnt, w],
			"wmp":  cnt * w,
			"voc":  37.5,
			"vmp":  30.0,
			"isc":  8.7,
			"imp":  w / 30.0,
			"cost": 0.0,
		},
	}


func _make_controller_item() -> Dictionary:
	var peak_kw: float = float(_read("PEAK_CAPACITY_KW", 0.0))
	if peak_kw <= 0.0:
		var cnt: int   = int(_read("PANEL_COUNT",    18))
		var w:   float = float(_read("PANEL_WATTAGE", 220.0))
		peak_kw = cnt * w / 1000.0
	return {
		"id":         V_CTRL_ID,
		"type":       "controller",
		"x":          140.0,
		"y":          -120.0,
		"width":      140.0,
		"height":     120.0,
		"is_virtual": true,
		"specs": {
			"name":               "Hybrid Inverter / MPPT",
			"max_voc":            150.0,
			"max_charge_amps":    50.0,
			"max_pv_watts":       peak_kw * 1000.0,
			"cost":               0.0,
			"overload_watts":     3500.0,
			"overload_duration_s": 10.0,
			"overload_lockout_s":  30.0,
		},
	}


func _make_battery_item() -> Dictionary:
	var bat_cap: float
	if is_instance_valid(_solar_ui) and _solar_ui.has_method("get_battery_capacity_kwh"):
		bat_cap = _solar_ui.get_battery_capacity_kwh()
	else:
		bat_cap = float(_read("BATTERY_CAPACITY_KWH", 16.0))
	return {
		"id":         V_BATTERY_ID,
		"type":       "battery",
		"x":          340.0,
		"y":          -100.0,
		"width":      100.0,
		"height":     136.0,
		"is_virtual": true,
		"specs": {
			"name":             "Battery Bank",
			"voltage":          48.0,
			"ah":               bat_cap * 1000.0 / 48.0,
			"kwh":              bat_cap,
			"soc":              0.5,
			"cost":             0.0,
			"soc_shutdown_pct": 10.0,
			"soc_resume_pct":   20.0,
		},
	}


func _make_baseline_item() -> Dictionary:
	var kw: float = float(_read("BASELINE_LOAD_KW", 0.35))
	return {
		"id":         V_BASELINE_ID,
		"type":       "appliance",
		"x":          540.0,
		"y":          80.0,
		"width":      130.0,
		"height":     70.0,
		"is_virtual": true,
		"specs": {
			"name":      "Baseline Load (%.0fW)" % (kw * 1000.0),
			"max_watts": kw * 1000.0,
			"avg_watts": kw * 1000.0,
			"cost":      0.0,
		},
	}


func _read(property: String, default_value: Variant) -> Variant:
	if not is_instance_valid(_solar_ui):
		return default_value
	var val: Variant = _solar_ui.get(property)
	return val if val != null else default_value


func _panel_node_id(idx: int) -> String:
	return "virtual_panel_%02d" % (idx + 1)


func _panel_node_position(idx: int) -> Vector2:
	return GraphVirtualIds.panel_node_position(idx)


func _ensure_virtual_panel_cluster() -> void:
	for i in range(ARRAY_PANEL_COUNT):
		var iid := _panel_node_id(i)
		if _model.get_item(iid).is_empty():
			var pos := _panel_node_position(i)
			_model.add_item({
				"id": iid,
				"type": "panel",
				"x": pos.x,
				"y": pos.y,
				"width": 66.0,
				"height": 112.0,
				"is_virtual": true,
				"specs": {
					"name": "PV-%02d" % (i + 1),
					"wmp": 220.0,
					"voc": 37.5,
					"vmp": 30.0,
					"isc": 8.7,
					"imp": 7.3,
					"cost": 0.0,
					"current_output_kw": 0.0,
					"array_group": (i / (ARRAY_STRINGS_PER_GROUP * ARRAY_SERIES_PER_STRING)) + 1,
					"array_string": ((i % (ARRAY_STRINGS_PER_GROUP * ARRAY_SERIES_PER_STRING)) / ARRAY_SERIES_PER_STRING) + 1,
					"array_series_pos": ((i % ARRAY_SERIES_PER_STRING) + 1),
				},
			})


func _ensure_virtual_panel_connections() -> void:
	for g in range(ARRAY_GROUPS):
		for s in range(ARRAY_STRINGS_PER_GROUP):
			var base := g * (ARRAY_STRINGS_PER_GROUP * ARRAY_SERIES_PER_STRING) + s * ARRAY_SERIES_PER_STRING
			var p0 := _panel_node_id(base + 0)
			var p1 := _panel_node_id(base + 1)
			var p2 := _panel_node_id(base + 2)
			var key := "g%d_s%d" % [g + 1, s + 1]
			# 3S string wiring
			_maybe_add_conn("vconn_arr_%s_s1" % key, "positive", p0, "positive", p1, "negative")
			_maybe_add_conn("vconn_arr_%s_s2" % key, "positive", p1, "positive", p2, "negative")
			# Parallel tie-in to controller PV terminals
			_maybe_add_conn("vconn_arr_%s_pos" % key, "positive", p2, "positive", V_CTRL_ID, "pvPositive")
			_maybe_add_conn("vconn_arr_%s_neg" % key, "negative", p0, "negative", V_CTRL_ID, "pvNegative")


func _refresh_virtual_panel_cluster(panel_wattage: float, solar_kw: float) -> void:
	var each_kw := solar_kw / float(maxi(ARRAY_PANEL_COUNT, 1))
	for i in range(ARRAY_PANEL_COUNT):
		var iid := _panel_node_id(i)
		var item := _model.get_item(iid)
		if item.is_empty():
			continue
		var prev := (item.get("specs", {}) as Dictionary).duplicate(true)
		_model.update_item(iid, {
			"specs": _merge_specs(prev, {
				"name": "PV-%02d" % (i + 1),
				"wmp": panel_wattage,
				"voc": 37.5,
				"vmp": 30.0,
				"isc": 8.7,
				"imp": panel_wattage / 30.0,
				"current_output_kw": each_kw,
				"array_group": (i / (ARRAY_STRINGS_PER_GROUP * ARRAY_SERIES_PER_STRING)) + 1,
				"array_string": ((i % (ARRAY_STRINGS_PER_GROUP * ARRAY_SERIES_PER_STRING)) / ARRAY_SERIES_PER_STRING) + 1,
				"array_series_pos": ((i % ARRAY_SERIES_PER_STRING) + 1),
			}),
		})
