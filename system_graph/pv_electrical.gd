class_name PvElectrical
extends RefCounted

## PV string open-circuit voltage math for the system graph (series sum, parallel max
## per branch, cold-temperature Voc boost). Used for over-voltage controller faults.

const VOC_TEMP_COEFF := 0.003  # /°C — Voc rises ~0.3%/°C below STC (25°C)


static func temp_adjusted_voc(voc_stc: float, ambient_c: float) -> float:
	return voc_stc * (1.0 + VOC_TEMP_COEFF * (25.0 - ambient_c))


## Only DC PV strings contribute open-circuit voltage. Wind/hydro turbines are
## AC/rectified sources with their own controllers — they carry no PV `voc` and
## must NOT be treated as PV-string contributors (they'd fall back to a bogus
## 37.5 V and inflate the string Voc fault check).
static func is_pv_source_type(type_id: String) -> bool:
	return type_id == "panel"  # array compound handled via is_pv_source_item


static func is_pv_source_item(item: Dictionary) -> bool:
	var ty := str(item.get("type", ""))
	if ty == "panel":
		return true
	if ty == "compound":
		var sp: Dictionary = item.get("specs", {}) as Dictionary
		return str(sp.get("compound_kind", "")) == "array"
	return false


static func unit_voc(item: Dictionary) -> float:
	var ty := str(item.get("type", ""))
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	if ty == "panel":
		return float(sp.get("voc", 37.5))
	if ty == "compound" and str(sp.get("compound_kind", "")) == "array":
		return float(sp.get("array_equiv_voc", 0.0))
	return 0.0


## Connected components among `node_ids` using only edges in `connections`.
static func connected_components(node_ids: Array, connections: Array) -> Array:
	var allowed: Dictionary = {}
	for nid in node_ids:
		allowed[str(nid)] = true
	var adj: Dictionary = {}
	for nid in node_ids:
		adj[str(nid)] = []
	for conn in connections:
		if not (conn is Dictionary):
			continue
		var a := str((conn as Dictionary).get("source_item_id", ""))
		var b := str((conn as Dictionary).get("target_item_id", ""))
		if allowed.has(a) and allowed.has(b):
			(adj[a] as Array).append(b)
			(adj[b] as Array).append(a)
	var out: Array = []
	var seen: Dictionary = {}
	for nid in node_ids:
		var sid := str(nid)
		if seen.has(sid):
			continue
		var comp: Array = []
		var q: Array[String] = [sid]
		seen[sid] = true
		while not q.is_empty():
			var cur: String = q.pop_front()
			comp.append(cur)
			for nv in (adj.get(cur, []) as Array):
				var nxt := str(nv)
				if seen.has(nxt):
					continue
				seen[nxt] = true
				q.append(nxt)
		out.append(comp)
	return out


## Sum Voc for panels wired in series within one connected component.
static func component_string_voc(comp: Array, model: GraphModel, ambient_c: float) -> float:
	var total := 0.0
	for nid_v in comp:
		var it := model.get_item(str(nid_v))
		if it.is_empty():
			continue
		total += temp_adjusted_voc(unit_voc(it), ambient_c)
	return total


## All PV-source nodes reachable from `controller_id` via DC/PV connections.
static func pv_sources_for_controller(model: GraphModel, controller_id: String,
		scope_id: String = "root") -> Array[String]:
	var out: Array[String] = []
	if model == null or controller_id.is_empty():
		return out
	var conns: Array = model.get_connections_in_scope(scope_id)
	var visited: Dictionary = {controller_id: true}
	var q: Array[String] = [controller_id]
	while not q.is_empty():
		var cur: String = q.pop_front()
		for conn in conns:
			if not (conn is Dictionary):
				continue
			var c: Dictionary = conn
			var pol := str(c.get("polarity", ""))
			if pol not in ["positive", "negative", "pvPositive", "pvNegative"]:
				continue
			var other := ""
			if str(c.get("source_item_id", "")) == cur:
				other = str(c.get("target_item_id", ""))
			elif str(c.get("target_item_id", "")) == cur:
				other = str(c.get("source_item_id", ""))
			if other.is_empty() or visited.has(other):
				continue
			visited[other] = true
			var it := model.get_item(other)
			if it.is_empty():
				continue
			if is_pv_source_item(it):
				out.append(other)
			q.append(other)
	return out


## Per parallel branch Voc feeding a controller. Returns Array of branch Voc values.
static func branch_vocs_for_controller(model: GraphModel, controller_id: String,
		scope_id: String = "root", ambient_c: float = 25.0) -> Array:
	var sources := pv_sources_for_controller(model, controller_id, scope_id)
	if sources.is_empty():
		return []
	var conns: Array = model.get_connections_in_scope(scope_id)
	var comps := connected_components(sources, conns)
	var branch_vocs: Array = []
	for comp in comps:
		branch_vocs.append(component_string_voc(comp as Array, model, ambient_c))
	return branch_vocs


## Highest string Voc on any branch feeding the controller.
static func max_string_voc_for_controller(model: GraphModel, controller_id: String,
		scope_id: String = "root", ambient_c: float = 25.0) -> float:
	var max_v := 0.0
	for v in branch_vocs_for_controller(model, controller_id, scope_id, ambient_c):
		max_v = maxf(max_v, float(v))
	return max_v


static func controller_max_voc(item: Dictionary) -> float:
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	return float(sp.get("max_voc", 150.0))


## Returns faults: [{controller_id, string_voc, max_voc, scope_id}, ...]
static func find_overvoltage_faults(model: GraphModel, scope_id: String = "root",
		ambient_c: float = 25.0) -> Array:
	var faults: Array = []
	if model == null:
		return faults
	for item in model.get_items_in_scope(scope_id):
		if not (item is Dictionary):
			continue
		if str((item as Dictionary).get("type", "")) != "controller":
			continue
		var cid := str((item as Dictionary).get("id", ""))
		var max_allowed := controller_max_voc(item as Dictionary)
		for bv in branch_vocs_for_controller(model, cid, scope_id, ambient_c):
			if float(bv) > max_allowed + 0.5:
				faults.append({
					"controller_id": cid,
					"string_voc": float(bv),
					"max_voc": max_allowed,
					"scope_id": scope_id,
				})
				break
	return faults


## Mark PV connections that exceed controller Voc limit (early warning).
static func update_connection_voltage_flags(model: GraphModel, scope_id: String = "root",
		ambient_c: float = 25.0) -> void:
	if model == null:
		return
	var fault_ctrls: Dictionary = {}
	for f in find_overvoltage_faults(model, scope_id, ambient_c):
		fault_ctrls[str((f as Dictionary).get("controller_id", ""))] = true
	for conn in model.get_connections_in_scope(scope_id):
		if not (conn is Dictionary):
			continue
		var c: Dictionary = conn
		var pol := str(c.get("polarity", ""))
		if pol not in ["positive", "negative", "pvPositive", "pvNegative"]:
			continue
		var sid := str(c.get("source_item_id", ""))
		var tid := str(c.get("target_item_id", ""))
		var mismatch := false
		for ctrl_id in fault_ctrls:
			if sid == ctrl_id or tid == ctrl_id:
				mismatch = true
				break
		if not mismatch:
			for ctrl_id in fault_ctrls:
				var sources := pv_sources_for_controller(model, ctrl_id, scope_id)
				if _array_has_id(sources, sid) or _array_has_id(sources, tid):
					mismatch = true
					break
		var conn_id := str(c.get("id", ""))
		if bool(c.get("voltage_mismatch", false)) != mismatch:
			model.update_connection(conn_id, {"voltage_mismatch": mismatch})


static func _array_has_id(arr: Array, needle: String) -> bool:
	for v in arr:
		if str(v) == needle:
			return true
	return false
