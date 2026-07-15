class_name GraphModel
extends RefCounted
## Solar circuit graph data model — owns items[] and connections[].
## Mirrors the webapp's allItems + connections schema (solar_designer.html).
## All mutation goes through the CRUD methods so `changed` fires consistently.
##
## Item Dictionary shape (by convention):
##   id, type, x, y, width, height, specs{}, handles[], is_virtual, device_path
##
## Connection Dictionary shape:
##   id, source_item_id, source_handle_id, target_item_id, target_handle_id,
##   polarity, resource_type, wire_gauge, wire_amps, estimated_length,
##   total_wire_cost, waypoints[], voltage_mismatch,
##   route_3d[], conduit_type, route_length_m, line_style,
##   curve_tension, corner_radius
##
## Handle Dictionary shape (inside item.handles[]):
##   id, polarity, rx, ry, resource_kind?, angle_rad?, role?, connected_to[]
##   — rx/ry are 0–1 fractions on the node box (legacy + compounds).
##   — angle_rad ∈ [0, TAU) for circular hub ports (resource/catchment);
##     role is "in"|"out"|"hub". Missing angle_rad migrates from rx/ry
##     (left=π, right=0) via GraphHubPorts.migrate_handle.
##
## connected_to entry: {item_id, handle_id, connection_id}

signal changed(reason: String)

const ROOT_SCOPE_ID := "root"

var items: Array = []        # Array[Dictionary]
var connections: Array = []  # Array[Dictionary]
## scope_id -> {id, parent_scope_id, owner_compound_id, title}
var scopes: Dictionary = {}

var _item_counter: int = 0
var _connection_counter: int = 0

## Last connection line_style the user picked (Smooth bezier / Rounded
## rectilinear / Metro). New connections default to this so a graph keeps a
## consistent style. Round-trips through serialize/deserialize.
var last_line_style: String = "bezier"

## id -> Dictionary reference indices for O(1) get_item/get_connection. Kept
## hot by the CRUD methods; the getters self-heal (rebuild) if a direct array
## mutation (e.g. a selftest appending to `connections`) desyncs the size.
var _item_index: Dictionary = {}
var _conn_index: Dictionary = {}


func _rebuild_item_index() -> void:
	_item_index.clear()
	for item: Dictionary in items:
		_item_index[str(item.get("id", ""))] = item


func _rebuild_conn_index() -> void:
	_conn_index.clear()
	for conn: Dictionary in connections:
		_conn_index[str(conn.get("id", ""))] = conn

## Transient during deserialize: processor_id -> {old_res_in_index: new_id_or_-1}.
## Lets us fix saved wires when migrate strips auto-inserted electric inputs.
var _res_in_remap: Dictionary = {}


func _init() -> void:
	_ensure_root_scope()


# ---------------------------------------------------------------------------
# ID generation
# ---------------------------------------------------------------------------

func generate_item_id() -> String:
	_item_counter += 1
	return "item_%d" % _item_counter


func generate_connection_id() -> String:
	_connection_counter += 1
	return "conn_%d" % _connection_counter


# ---------------------------------------------------------------------------
# Item CRUD
# ---------------------------------------------------------------------------

func add_item(item: Dictionary) -> void:
	_ensure_root_scope()
	if not item.has("id") or (item["id"] as String).is_empty():
		item["id"] = generate_item_id()
	if not item.has("scope_id"):
		item["scope_id"] = ROOT_SCOPE_ID
	var sid: String = str(item.get("scope_id", ROOT_SCOPE_ID))
	if not scopes.has(sid):
		ensure_scope(sid)
	items.append(item)
	_item_index[str(item.get("id", ""))] = item
	changed.emit("add_item")


func remove_item(item_id: String) -> void:
	for i in range(items.size() - 1, -1, -1):
		if items[i].get("id", "") == item_id:
			items.remove_at(i)
			break
	_item_index.erase(item_id)
	# Cascade: remove any connections touching this item
	for i in range(connections.size() - 1, -1, -1):
		var c: Dictionary = connections[i]
		if c.get("source_item_id") == item_id or c.get("target_item_id") == item_id:
			_conn_index.erase(str(c.get("id", "")))
			connections.remove_at(i)
	changed.emit("remove_item")


func get_item(item_id: String) -> Dictionary:
	var it: Variant = _item_index.get(item_id)
	if it is Dictionary and (it as Dictionary).get("id", "") == item_id:
		return it
	# Miss or stale reference — self-heal against direct array mutation.
	if _item_index.size() != items.size():
		_rebuild_item_index()
		it = _item_index.get(item_id)
		if it is Dictionary and (it as Dictionary).get("id", "") == item_id:
			return it
	return {}


func update_item(item_id: String, updates: Dictionary) -> void:
	var item := get_item(item_id)
	if item.is_empty():
		return
	for key: String in updates:
		item[key] = updates[key]
	changed.emit("update_item")


# ---------------------------------------------------------------------------
# Connection CRUD
# ---------------------------------------------------------------------------

func add_connection(conn: Dictionary) -> void:
	_ensure_root_scope()
	if not conn.has("id") or (conn["id"] as String).is_empty():
		conn["id"] = generate_connection_id()
	if not conn.has("scope_id"):
		conn["scope_id"] = ROOT_SCOPE_ID
	connections.append(conn)
	_conn_index[str(conn.get("id", ""))] = conn
	_link_handle(
		conn.get("source_item_id", ""), conn.get("source_handle_id", ""),
		conn.get("target_item_id", ""), conn.get("target_handle_id", ""),
		conn.get("id", "")
	)
	_link_handle(
		conn.get("target_item_id", ""), conn.get("target_handle_id", ""),
		conn.get("source_item_id", ""), conn.get("source_handle_id", ""),
		conn.get("id", "")
	)
	changed.emit("add_connection")


func remove_connection(conn_id: String) -> void:
	for i in range(connections.size() - 1, -1, -1):
		var c: Dictionary = connections[i]
		if c.get("id", "") == conn_id:
			_unlink_handle(c.get("source_item_id", ""), c.get("source_handle_id", ""), conn_id)
			_unlink_handle(c.get("target_item_id", ""), c.get("target_handle_id", ""), conn_id)
			connections.remove_at(i)
			break
	_conn_index.erase(conn_id)
	changed.emit("remove_connection")


func get_connection(conn_id: String) -> Dictionary:
	var cn: Variant = _conn_index.get(conn_id)
	if cn is Dictionary and (cn as Dictionary).get("id", "") == conn_id:
		return cn
	# Miss or stale reference — self-heal against direct array mutation.
	if _conn_index.size() != connections.size():
		_rebuild_conn_index()
		cn = _conn_index.get(conn_id)
		if cn is Dictionary and (cn as Dictionary).get("id", "") == conn_id:
			return cn
	return {}


func get_items_in_scope(scope_id: String = ROOT_SCOPE_ID) -> Array:
	var out: Array = []
	var sid: String = scope_id if not scope_id.is_empty() else ROOT_SCOPE_ID
	for item: Dictionary in items:
		var isid: String = str(item.get("scope_id", ROOT_SCOPE_ID))
		if isid == sid:
			out.append(item)
	return out


func get_connections_in_scope(scope_id: String = ROOT_SCOPE_ID) -> Array:
	var out: Array = []
	var sid: String = scope_id if not scope_id.is_empty() else ROOT_SCOPE_ID
	for conn: Dictionary in connections:
		var csid: String = str(conn.get("scope_id", ROOT_SCOPE_ID))
		if csid == sid:
			out.append(conn)
	return out


func update_connection(conn_id: String, updates: Dictionary) -> void:
	for conn: Dictionary in connections:
		if conn.get("id", "") == conn_id:
			for key: String in updates:
				conn[key] = updates[key]
			changed.emit("update_connection")
			return


## Returns all connections that touch a given item (either endpoint).
func connections_for_item(item_id: String) -> Array:
	var result: Array = []
	for conn: Dictionary in connections:
		if conn.get("source_item_id") == item_id or conn.get("target_item_id") == item_id:
			result.append(conn)
	return result


# ---------------------------------------------------------------------------
# Handle bookkeeping (connected_to[] maintained as a convenience index)
# ---------------------------------------------------------------------------

func find_handle(item_id: String, handle_id: String) -> Dictionary:
	var item := get_item(item_id)
	if item.is_empty():
		return {}
	var handles: Array = item.get("handles", [])
	for h: Dictionary in handles:
		if h.get("id", "") == handle_id:
			return h
	return {}


func _link_handle(item_id: String, handle_id: String,
		other_item_id: String, other_handle_id: String,
		conn_id: String) -> void:
	var h := find_handle(item_id, handle_id)
	if h.is_empty():
		return
	if not h.has("connected_to"):
		h["connected_to"] = []
	h["connected_to"].append({
		"item_id":       other_item_id,
		"handle_id":     other_handle_id,
		"connection_id": conn_id,
	})


func _unlink_handle(item_id: String, handle_id: String, conn_id: String) -> void:
	var h := find_handle(item_id, handle_id)
	if h.is_empty() or not h.has("connected_to"):
		return
	var ct: Array = h["connected_to"]
	for i in range(ct.size() - 1, -1, -1):
		if ct[i].get("connection_id", "") == conn_id:
			ct.remove_at(i)


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

## Returns true if the item is flagged as virtual (auto-generated by the bridge).
func is_virtual(item_id: String) -> bool:
	return bool(get_item(item_id).get("is_virtual", false))


func clear() -> void:
	_ensure_root_scope()
	items.clear()
	connections.clear()
	_item_index.clear()
	_conn_index.clear()
	scopes = {}
	_ensure_root_scope()
	changed.emit("clear")


## Returns aggregated kWh from all battery items (for telemetry).
func total_battery_kwh() -> float:
	var total := 0.0
	for item: Dictionary in items:
		if item.get("type", "") == "battery":
			var specs: Dictionary = item.get("specs", {})
			total += float(specs.get("kwh", 0.0))
	return total


## Returns sum of Wmp across all connected panel items.
func total_panel_wmp() -> float:
	var total := 0.0
	for item: Dictionary in items:
		if item.get("type", "") in ["panel", "smartbattery"]:
			var specs: Dictionary = item.get("specs", {})
			total += float(specs.get("wmp", 0.0))
	return total


## Returns total cost from all item specs.cost values plus wire costs.
func total_cost() -> float:
	var total := 0.0
	for item: Dictionary in items:
		total += float(item.get("specs", {}).get("cost", 0.0))
	for conn: Dictionary in connections:
		total += float(conn.get("total_wire_cost", 0.0))
	return total


# ---------------------------------------------------------------------------
# Serialization — round-trips cleanly through JSON
# ---------------------------------------------------------------------------

func serialize() -> Dictionary:
	_ensure_root_scope()
	return {
		"version":            5,
		"items":              items.duplicate(true),
		"connections":        connections.duplicate(true),
		"scopes":             scopes.duplicate(true),
		"item_counter":       _item_counter,
		"connection_counter": _connection_counter,
		"last_line_style":    last_line_style,
	}


func deserialize(data: Dictionary) -> void:
	items       = []
	connections = []
	scopes      = {}
	_ensure_root_scope()
	if data.get("items") is Array:
		items = (data["items"] as Array).duplicate(true)
	if data.get("connections") is Array:
		connections = (data["connections"] as Array).duplicate(true)
	# v2+: explicit scope dictionary. v1: infer root-only.
	if data.get("scopes") is Dictionary:
		scopes = (data["scopes"] as Dictionary).duplicate(true)
		if scopes.is_empty():
			_ensure_root_scope()
	# Ensure every item/connection has a scope_id and known scope.
	for item: Dictionary in items:
		if not item.has("scope_id"):
			item["scope_id"] = ROOT_SCOPE_ID
		var sid: String = str(item.get("scope_id", ROOT_SCOPE_ID))
		if not scopes.has(sid):
			ensure_scope(sid)
		_migrate_item_specs(item)
	for conn: Dictionary in connections:
		if not conn.has("scope_id"):
			conn["scope_id"] = ROOT_SCOPE_ID
		var csid: String = str(conn.get("scope_id", ROOT_SCOPE_ID))
		if not scopes.has(csid):
			ensure_scope(csid)
		_apply_res_in_remap(conn)
		_migrate_connection(conn)
	_res_in_remap.clear()
	_item_counter       = int(data.get("item_counter",       0))
	_connection_counter = int(data.get("connection_counter", 0))
	last_line_style     = str(data.get("last_line_style", "bezier"))
	_rebuild_item_index()
	_rebuild_conn_index()
	changed.emit("deserialize")


func ensure_scope(scope_id: String,
		parent_scope_id: String = ROOT_SCOPE_ID,
		owner_compound_id: String = "",
		title: String = "") -> void:
	_ensure_root_scope()
	if scope_id.is_empty():
		return
	if scopes.has(scope_id):
		return
	scopes[scope_id] = {
		"id": scope_id,
		"parent_scope_id": parent_scope_id if not parent_scope_id.is_empty() else ROOT_SCOPE_ID,
		"owner_compound_id": owner_compound_id,
		"title": title if not title.is_empty() else scope_id.capitalize(),
	}


func remove_scope(scope_id: String) -> void:
	if scope_id.is_empty() or scope_id == ROOT_SCOPE_ID:
		return
	scopes.erase(scope_id)


func get_scope(scope_id: String) -> Dictionary:
	if scopes.has(scope_id):
		return scopes.get(scope_id, {}) as Dictionary
	return {}


func _ensure_root_scope() -> void:
	if scopes.has(ROOT_SCOPE_ID):
		return
	scopes[ROOT_SCOPE_ID] = {
		"id": ROOT_SCOPE_ID,
		"parent_scope_id": "",
		"owner_compound_id": "",
		"title": "Root",
	}


func _migrate_item_specs(item: Dictionary) -> void:
	var ty: String = str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if ty == "processor":
		# Capture which res_in_N ports shift when migrate strips auto-inserted
		# electric power inputs, so saved wires can be remapped (below).
		_record_res_in_remap(str(item.get("id", "")), specs.get("inputs", []) as Array)
		ResourceKinds.new().migrate_processor_specs(specs)
	elif ty == "resource":
		ResourceKinds.new().migrate_resource_specs(specs)
	# Hub ports: persist angle_rad on any stored handles (resource/catchment).
	if GraphHubPorts.is_hub_type(ty):
		var handles: Array = item.get("handles", []) as Array
		if not handles.is_empty():
			GraphHubPorts.migrate_handles_array(handles)


## Build the res_in_N port remap for a processor whose auto-inserted electric
## power inputs (unit "W") are about to be stripped. An original index K shifts
## down by the count of removed inputs before it; a removed index maps to -1.
func _record_res_in_remap(proc_id: String, raw_inputs: Array) -> void:
	if proc_id.is_empty() or raw_inputs.is_empty():
		return
	var removed: Array = []
	for i in raw_inputs.size():
		var inp := raw_inputs[i] as Dictionary
		if str(inp.get("kind", "")) == "electric" and str(inp.get("unit", "")) == "W":
			removed.append(i)
	if removed.is_empty():
		return
	var map: Dictionary = {}
	for k in raw_inputs.size():
		if removed.has(k):
			map[k] = -1
			continue
		var shift := 0
		for r in removed:
			if int(r) < k:
				shift += 1
		map[k] = k - shift
	_res_in_remap[proc_id] = map


## Rewrite a saved connection's res_in_N target handle after electric inputs were
## stripped from its target processor, so biomass/water wires stay on the right port.
func _apply_res_in_remap(conn: Dictionary) -> void:
	var tgt := str(conn.get("target_item_id", ""))
	if not _res_in_remap.has(tgt):
		return
	var handle := str(conn.get("target_handle_id", ""))
	if not handle.begins_with("res_in_"):
		return
	var old_idx := int(handle.trim_prefix("res_in_"))
	var map: Dictionary = _res_in_remap[tgt] as Dictionary
	if not map.has(old_idx):
		return
	var new_idx := int(map[old_idx])
	if new_idx >= 0:
		conn["target_handle_id"] = "res_in_%d" % new_idx


func _migrate_connection(conn: Dictionary) -> void:
	if not conn.has("resource_type"):
		conn["resource_type"] = ""
	var rt: String = str(conn.get("resource_type", ""))
	if not rt.is_empty():
		conn["resource_type"] = ResourceKinds.normalize_kind(rt)
	elif str(conn.get("polarity", "")) == "resource":
		var src_id: String = str(conn.get("source_item_id", ""))
		var src_h: String = str(conn.get("source_handle_id", ""))
		var item := get_item(src_id)
		if not item.is_empty():
			var specs: Dictionary = item.get("specs", {}) as Dictionary
			if str(item.get("type", "")) == "resource":
				ResourceKinds.new().migrate_resource_specs(specs)
				conn["resource_type"] = str(specs.get("resource_kind", ""))
			elif str(item.get("type", "")) == "processor":
				ResourceKinds.new().migrate_processor_specs(specs)
				if src_h == "output":
					var outs: Array = specs.get("outputs", []) as Array
					if outs.size() > 0:
						conn["resource_type"] = str((outs[0] as Dictionary).get("kind", ""))
				elif src_h.begins_with("res_out_"):
					var idx := int(src_h.trim_prefix("res_out_"))
					var outs: Array = specs.get("outputs", []) as Array
					if idx >= 0 and idx < outs.size():
						conn["resource_type"] = str((outs[idx] as Dictionary).get("kind", ""))
			elif str(item.get("type", "")) == "catchment":
				var cspecs: Dictionary = specs
				conn["resource_type"] = PbiBiomass.catchment_output_kind(cspecs)
	if not str(conn.get("resource_type", "")).is_empty():
		conn["resource_type"] = ResourceKinds.normalize_kind(str(conn.get("resource_type", "")))
	ConduitKinds.migrate_connection_conduit_fields(conn)
	if not conn.has("line_style"):
		conn["line_style"] = "bezier"
	if not conn.has("curve_tension"):
		conn["curve_tension"] = 1.0
	if not conn.has("corner_radius"):
		conn["corner_radius"] = 28.0


## Returns persisted scene path for a graph item (specs.scene_device_path preferred).
func item_scene_path(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var p: String = str(specs.get("scene_device_path", ""))
	if not p.is_empty():
		return p
	return str(item.get("device_path", ""))


## True when both connection endpoints have a resolvable 3D scene link
## (scene path, bound prop, or site placement with model).
func connection_is_3d_routable(conn: Dictionary) -> bool:
	var src := get_item(str(conn.get("source_item_id", "")))
	var tgt := get_item(str(conn.get("target_item_id", "")))
	if src.is_empty() or tgt.is_empty():
		return false
	return _item_has_3d_anchor(src) and _item_has_3d_anchor(tgt)


func _item_has_3d_anchor(item: Dictionary) -> bool:
	if not item_scene_path(item).is_empty():
		return true
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if not str(specs.get("bound_prop_id", "")).is_empty():
		return true
	if GraphSiteLayout.has_site_coords(item) and not str(specs.get("model_id", "")).is_empty():
		return true
	return false
