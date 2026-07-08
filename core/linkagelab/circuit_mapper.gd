class_name CircuitMapper
extends RefCounted

## Map LinkageLab circuit JSON to Godot GraphModel save payload.

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

const TYPE_MAP := {
	"solarcombiner": "combiner",
	"dcbreaker": "breaker",
	"doublevoltagehub": "combiner",
	"spiderbox": "acload",
	"producer": "resource",
	"container": "compound",
	"breakerpanel": "compound",
}

const HANDLE_ID_MAP := {
	"pv-positive": "pvPositive",
	"pv-negative": "pvNegative",
	"pv_positive": "pvPositive",
	"pv_negative": "pvNegative",
	"battery-positive": "batteryPositive",
	"battery-negative": "batteryNegative",
	"battery_positive": "batteryPositive",
	"battery_negative": "batteryNegative",
	"ac-output": "acOutput",
	"ac_output": "acOutput",
}


static func normalize_handle_id(handle_id: String) -> String:
	return str(HANDLE_ID_MAP.get(handle_id, handle_id))


const POLARITY_MAP := {
	"pv-positive": "positive",
	"pv-negative": "negative",
	"battery-positive": "positive",
	"battery-negative": "negative",
	"pv_positive": "positive",
	"pv_negative": "negative",
}

const DEFAULT_SIZES := {
	"panel": Vector2(120, 100),
	"wind": Vector2(120, 100),
	"hydro": Vector2(120, 100),
	"battery": Vector2(110, 80),
	"smartbattery": Vector2(110, 80),
	"controller": Vector2(140, 120),
	"appliance": Vector2(120, 80),
	"acload": Vector2(120, 80),
	"processor": Vector2(120, 80),
	"resource": Vector2(100, 80),
	"shelly4pm": Vector2(140, 100),
	"combiner": Vector2(100, 80),
	"breaker": Vector2(80, 60),
	"acbreaker": Vector2(80, 60),
	"acoutlet": Vector2(80, 60),
	"compound": Vector2(160, 120),
}


static func to_graph_save_state(circuit: Dictionary) -> Dictionary:
	var items_in: Array = circuit.get("items", []) as Array
	var conns_in: Array = circuit.get("connections", []) as Array
	var items_out: Array = []
	var conns_out: Array = []

	for raw_item in items_in:
		if not (raw_item is Dictionary):
			continue
		var mapped := _map_item(raw_item as Dictionary)
		if not mapped.is_empty():
			items_out.append(mapped)

	var valid_ids: Dictionary = {}
	for it: Dictionary in items_out:
		valid_ids[str(it.get("id", ""))] = true

	for raw_conn in conns_in:
		if not (raw_conn is Dictionary):
			continue
		var mapped_c := _map_connection(raw_conn as Dictionary)
		if mapped_c.is_empty():
			continue
		if not valid_ids.has(str(mapped_c.get("source_item_id", ""))):
			continue
		if not valid_ids.has(str(mapped_c.get("target_item_id", ""))):
			continue
		conns_out.append(mapped_c)

	var item_counter := int(circuit.get("itemIdCounter", items_out.size()))
	var conn_counter := int(circuit.get("connectionIdCounter", conns_out.size()))
	item_counter = maxi(item_counter, items_out.size())
	conn_counter = maxi(conn_counter, conns_out.size())

	return {
		"graph": {
			"version": 2,
			"items": items_out,
			"connections": conns_out,
			"scopes": {
				"root": {
					"id": "root",
					"parent_scope_id": "",
					"owner_compound_id": "",
					"title": "Root",
				},
			},
			"item_counter": item_counter,
			"connection_counter": conn_counter,
		},
		"sidebar_l_open": true,
		"sidebar_r_open": true,
		"mode": "build",
		"active_scope_id": "root",
		"scope_trail": ["root"],
		"canvas_pan_x": 0.0,
		"canvas_pan_y": 0.0,
		"canvas_zoom": 1.0,
		"suppressed_virtuals": {},
	}


static func _map_item(raw: Dictionary) -> Dictionary:
	var itype := str(raw.get("type", ""))
	if itype.is_empty():
		return {}
	if TYPE_MAP.has(itype):
		itype = str(TYPE_MAP[itype])
	var size: Vector2 = DEFAULT_SIZES.get(itype, Vector2(120, 80))
	var specs: Dictionary = _remap_specs(raw.get("specs", {}) as Dictionary, itype)
	var out := {
		"id": str(raw.get("id", "")),
		"type": itype,
		"x": float(raw.get("x", 0.0)),
		"y": float(raw.get("y", 0.0)),
		"width": float(raw.get("width", size.x)),
		"height": float(raw.get("height", size.y)),
		"scope_id": "root",
		"specs": specs,
		"is_virtual": false,
	}
	if out["id"].is_empty():
		out.erase("id")
	return out


static func _remap_specs(raw: Dictionary, itype: String) -> Dictionary:
	var out := raw.duplicate(true)
	_copy_key(out, "maxWatts", "max_watts")
	_copy_key(out, "avgWatts", "avg_watts")
	_copy_key(out, "maxVoc", "max_voc")
	_copy_key(out, "maxIsc", "max_charge_amps")
	_copy_key(out, "maxWmp", "max_pv_watts")
	_copy_key(out, "ratedChargeCurrent", "max_charge_amps")
	_copy_key(out, "kWh", "kwh")
	if itype == "controller":
		if not out.has("max_voc") and out.has("maxVoc"):
			out["max_voc"] = out["maxVoc"]
		if not out.has("max_charge_amps"):
			out["max_charge_amps"] = float(out.get("ratedChargeCurrent", out.get("maxIsc", 50.0)))
		if not out.has("max_pv_watts"):
			out["max_pv_watts"] = float(out.get("maxWmp", 2400.0))
	if itype in ["appliance", "acload"]:
		if not out.has("max_watts"):
			out["max_watts"] = float(out.get("watts", out.get("maxWatts", 100.0)))
		if not out.has("avg_watts"):
			out["avg_watts"] = float(out.get("avgWatts", out.get("max_watts", 0.0)))
	if itype == "battery" or itype == "smartbattery":
		if not out.has("kwh"):
			var v := float(out.get("voltage", 0.0))
			var ah := float(out.get("ah", 0.0))
			if v > 0.0 and ah > 0.0:
				out["kwh"] = v * ah / 1000.0
	# Drop web-only layout keys.
	for drop_key in ["scaleFactor", "width", "height", "behavior", "icon", "mpptCount", "supportedVoltages"]:
		if drop_key in out and itype != "panel":
			out.erase(drop_key)
	return out


static func _copy_key(specs: Dictionary, from_key: String, to_key: String) -> void:
	if specs.has(from_key) and not specs.has(to_key):
		specs[to_key] = specs[from_key]


static func _map_connection(raw: Dictionary) -> Dictionary:
	var src_id := str(raw.get("source_item_id", raw.get("sourceItemId", "")))
	var tgt_id := str(raw.get("target_item_id", raw.get("targetItemId", "")))
	if src_id.is_empty() or tgt_id.is_empty():
		return {}
	var src_handle := normalize_handle_id(str(raw.get("source_handle_id", raw.get("sourceHandleId", ""))))
	if src_handle.is_empty():
		src_handle = normalize_handle_id(str(raw.get("sourceHandleKey", raw.get("source_handle", ""))))
	var tgt_handle := normalize_handle_id(str(raw.get("target_handle_id", raw.get("targetHandleId", ""))))
	if tgt_handle.is_empty():
		tgt_handle = normalize_handle_id(str(raw.get("targetHandleKey", raw.get("target_handle", ""))))
	var polarity := str(raw.get("polarity", "positive"))
	if POLARITY_MAP.has(polarity):
		polarity = str(POLARITY_MAP[polarity])
	return {
		"id": str(raw.get("id", "")),
		"scope_id": "root",
		"polarity": polarity,
		"source_item_id": src_id,
		"source_handle_id": src_handle,
		"target_item_id": tgt_id,
		"target_handle_id": tgt_handle,
		"waypoints": raw.get("waypoints", []),
		"voltage_mismatch": bool(raw.get("voltage_mismatch", raw.get("voltageMismatch", false))),
		"wire_gauge": float(raw.get("wire_gauge", raw.get("wireGauge", 0.0))),
		"wire_amps": float(raw.get("wire_amps", raw.get("wireAmps", 0.0))),
		"estimated_length": float(raw.get("estimated_length", raw.get("estimatedLength", 0.0))),
		"total_wire_cost": float(raw.get("total_wire_cost", raw.get("totalWireCost", 0.0))),
	}
