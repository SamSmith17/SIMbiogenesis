class_name PvElectrical
extends RefCounted

## PV string open-circuit voltage math for the system graph (series sum, parallel max
## per branch, cold-temperature Voc boost). Used for over-voltage controller faults.

const VOC_TEMP_COEFF := 0.003  # /°C — Voc rises ~0.3%/°C below STC (25°C)
## Vmp falls faster than Voc with heat. P = V·I, so dP/P = dV/V + dI/I: the
## Vmp coefficient is the Pmax coefficient minus the (small, positive) Imp
## one, ~+0.05 %/°C for crystalline silicon. Used when a panel gives Pmax but
## no Vmp coefficient; 0.40 %/°C is the fallback with neither.
const VMP_TEMP_COEFF := 0.0040
const IMP_TEMP_COEFF := 0.0005
## Design temperatures for the string window check (not the live weather):
## a cold clear morning sets the highest Voc, a hot noon the lowest Vmp. Cell
## temperature on the hot day uses the NOCT model at 1000 W/m²:
## T_cell = T_amb + (NOCT − 20) × 1000 / 800, NOCT 45 °C (SolarUI's model).
const DESIGN_COLD_C := -10.0
const DESIGN_HOT_AMBIENT_C := 40.0
const NOCT_C := 45.0


## `coeff_per_c` is the fractional Voc change per °C (positive number; Voc
## RISES as it gets colder). Panels that publish their own coefficient pass it
## through voc_coeff_for.
static func temp_adjusted_voc(voc_stc: float, ambient_c: float,
		coeff_per_c: float = VOC_TEMP_COEFF) -> float:
	return voc_stc * (1.0 + coeff_per_c * (25.0 - ambient_c))


## The item's own Voc temperature coefficient (`voc_temp_coeff_pct`, the data
## sheet's %/°C, e.g. -0.272), else the generic 0.3 %/°C.
static func voc_coeff_for(item: Dictionary) -> float:
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	var pct := float(sp.get("voc_temp_coeff_pct", 0.0))
	if is_finite(pct) and absf(pct) > 1e-4:
		return absf(pct) / 100.0
	return VOC_TEMP_COEFF


static func vmp_coeff_for(item: Dictionary) -> float:
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	var vpct := float(sp.get("vmp_temp_coeff_pct", 0.0))
	if is_finite(vpct) and absf(vpct) > 1e-4:
		return absf(vpct) / 100.0
	var ppct := float(sp.get("pmax_temp_coeff_pct", 0.0))
	if is_finite(ppct) and absf(ppct) > 1e-4:
		return absf(ppct) / 100.0 + IMP_TEMP_COEFF
	return VMP_TEMP_COEFF


## One unit's Vmp at STC (a panel's own; an array compound's string Vmp).
static func unit_vmp(item: Dictionary) -> float:
	var ty := str(item.get("type", ""))
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	if bool(sp.get("packed_3d", false)):
		return 0.0
	if ty == "panel":
		return float(sp.get("vmp", 0.0))
	if ty == "compound" and str(sp.get("compound_kind", "")) == "array":
		return float(sp.get("array_equiv_vmp", 0.0))
	return 0.0


## The PV string as an MPPT controller sees it, at the design extremes:
## coldest Voc (must stay under max_voc — the fault check uses the live
## temperature; this is the design margin), Voc at the cold start (must reach
## startup_v), hot-noon Vmp (must stay above mppt_min_v or the tracker falls
## out of its window and output collapses) and STC Vmp (above mppt_max_v the
## tracker clips). Empty when the controller has no PV wired.
static func string_window_report(model: GraphModel, controller_id: String,
		flat_conns: Array, cold_c: float = DESIGN_COLD_C,
		hot_ambient_c: float = DESIGN_HOT_AMBIENT_C) -> Dictionary:
	if model == null:
		return {}
	var ctrl := model.get_item(controller_id)
	if ctrl.is_empty():
		return {}
	var sources := pv_sources_for_controller_flat(model, controller_id, flat_conns)
	if sources.is_empty():
		return {}
	var hot_cell := hot_ambient_c + (NOCT_C - 20.0) * 1000.0 / 800.0
	var voc_cold := 0.0
	var voc_stc := 0.0
	var vmp_stc_min := INF
	var vmp_stc_max := 0.0
	var vmp_hot := INF
	for comp in connected_components(sources, flat_conns, true):
		var c_voc := 0.0
		var s_voc := 0.0
		var s_vmp := 0.0
		var h_vmp := 0.0
		for nid_v in comp as Array:
			var it := model.get_item(str(nid_v))
			if it.is_empty():
				continue
			var voc := unit_voc(it)
			var vmp := unit_vmp(it)
			c_voc += temp_adjusted_voc(voc, cold_c, voc_coeff_for(it))
			s_voc += voc
			s_vmp += vmp
			h_vmp += vmp * (1.0 - vmp_coeff_for(it) * (hot_cell - 25.0))
		if s_voc <= 0.0:
			continue
		voc_cold = maxf(voc_cold, c_voc)
		voc_stc = maxf(voc_stc, s_voc)
		vmp_stc_min = minf(vmp_stc_min, s_vmp)
		vmp_stc_max = maxf(vmp_stc_max, s_vmp)
		vmp_hot = minf(vmp_hot, h_vmp)
	if voc_stc <= 0.0:
		return {}
	var sp: Dictionary = ctrl.get("specs", {}) as Dictionary
	var max_voc := float(sp.get("max_voc", 150.0))
	var m_min := float(sp.get("mppt_min_v", 0.0))
	var m_max := float(sp.get("mppt_max_v", 0.0))
	var start_v := float(sp.get("startup_v", 0.0))
	var issues: Array = []
	if voc_cold > max_voc:
		issues.append("cold-morning Voc %.0f V exceeds the %.0f V limit at %.0f °C" % [voc_cold, max_voc, cold_c])
	if start_v > 0.0 and voc_stc < start_v:
		issues.append("string Voc %.0f V never reaches the %.0f V start-up voltage" % [voc_stc, start_v])
	if m_min > 0.0 and vmp_hot < m_min:
		issues.append("hot-noon Vmp %.0f V falls below the %.0f V MPPT floor" % [vmp_hot, m_min])
	if m_max > 0.0 and vmp_stc_max > m_max:
		issues.append("Vmp %.0f V is above the %.0f V MPPT ceiling (clips)" % [vmp_stc_max, m_max])
	return {
		"voc_cold": voc_cold, "voc_stc": voc_stc,
		"vmp_stc": vmp_stc_max, "vmp_stc_min": vmp_stc_min, "vmp_hot": vmp_hot,
		"hot_cell_c": hot_cell, "cold_c": cold_c,
		"max_voc": max_voc, "mppt_min_v": m_min, "mppt_max_v": m_max, "startup_v": start_v,
		"margin_v": max_voc - voc_cold,
		"ok": issues.is_empty(), "issues": issues,
	}


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
	# A packed (crated) item has no electrical presence — 0 Voc contribution
	# to any string sum (GraphDcElectrical.is_packed has the full rationale).
	if bool(sp.get("packed_3d", false)):
		return 0.0
	if ty == "panel":
		return float(sp.get("voc", 37.5))
	if ty == "compound" and str(sp.get("compound_kind", "")) == "array":
		return float(sp.get("array_equiv_voc", 0.0))
	return 0.0


## DC terminal polarity of a handle id ("pos" | "neg" | "" if not a DC terminal).
static func _terminal_polarity(handle_id: String) -> String:
	var h := handle_id.to_lower()
	if h.contains("pos"):
		return "pos"
	if h.contains("neg"):
		return "neg"
	return ""


## True when a wire joins two panels in SERIES (a + terminal to a − terminal).
## Same-terminal joins (+→+, −→−) are PARALLEL and must NOT merge two strings
## into one series sum. Non-DC / unknown handles default to connective so we
## never over-split a legitimate string.
static func _is_series_link(conn: Dictionary) -> bool:
	var s := _terminal_polarity(str(conn.get("source_handle_id", "")))
	var t := _terminal_polarity(str(conn.get("target_handle_id", "")))
	if s == "" or t == "":
		return true
	return s != t


## Connected components among `node_ids` using only edges in `connections`.
## When `series_only` is set (PV string grouping), parallel (+→+ / −→−) links are
## ignored so 3S×6P reads as six 3-panel strings, not one 18-panel series string.
static func connected_components(node_ids: Array, connections: Array,
		series_only: bool = false) -> Array:
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
			if series_only and not _is_series_link(conn as Dictionary):
				continue
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
		total += temp_adjusted_voc(unit_voc(it), ambient_c, voc_coeff_for(it))
	return total


## Wire polarities that carry a DC/PV circuit.
const PV_WALK_POLARITIES: Array[String] = ["positive", "negative", "pvPositive", "pvNegative"]


## Items wired directly to `item_id` through one of its own terminals whose
## handle starts with `handle_prefix` and reads as `pol` ("pos" | "neg").
## `handle_prefix` separates a controller's PV inputs ("pv") from its battery
## outputs ("battery"); pass "" for two-terminal devices like panels/batteries.
static func leg_neighbors(item_id: String, conns: Array, handle_prefix: String,
		pol: String) -> Array[String]:
	var out: Array[String] = []
	for conn in conns:
		if not (conn is Dictionary):
			continue
		var c: Dictionary = conn
		if str(c.get("polarity", "")) not in PV_WALK_POLARITIES:
			continue
		var local := ""
		var other := ""
		if str(c.get("source_item_id", "")) == item_id:
			local = str(c.get("source_handle_id", ""))
			other = str(c.get("target_item_id", ""))
		elif str(c.get("target_item_id", "")) == item_id:
			local = str(c.get("target_handle_id", ""))
			other = str(c.get("source_item_id", ""))
		if other.is_empty() or not local.begins_with(handle_prefix):
			continue
		if _terminal_polarity(local) != pol:
			continue
		out.append(other)
	return out


## PV sources reachable from `seeds` over PV/DC wires, with `blocked` item ids
## treated as already-visited (so a walk out one leg cannot loop back through
## the device it started from and arrive at the other leg).
static func _pv_sources_reachable(model: GraphModel, seeds: Array, conns: Array,
		blocked: Dictionary) -> Dictionary:
	var found: Dictionary = {}
	var visited: Dictionary = blocked.duplicate()
	var q: Array[String] = []
	for sid_v in seeds:
		var sid := str(sid_v)
		if visited.has(sid):
			continue
		visited[sid] = true
		q.append(sid)
	while not q.is_empty():
		var cur: String = q.pop_front()
		var cur_it := model.get_item(cur)
		if cur_it.is_empty():
			continue
		if is_pv_source_item(cur_it):
			found[cur] = true
		for conn in conns:
			if not (conn is Dictionary):
				continue
			var c: Dictionary = conn
			if str(c.get("polarity", "")) not in PV_WALK_POLARITIES:
				continue
			var other := ""
			if str(c.get("source_item_id", "")) == cur:
				other = str(c.get("target_item_id", ""))
			elif str(c.get("target_item_id", "")) == cur:
				other = str(c.get("source_item_id", ""))
			if other.is_empty() or visited.has(other):
				continue
			visited[other] = true
			q.append(other)
	return found


## PV sources feeding `controller_id` over `conns`.
##
## A PV string only presents voltage or current to a controller when BOTH of its
## input terminals are wired — one leg is an open circuit, not a source. So each
## leg is walked separately and only the sources common to both count. Without
## this, a single positive wire reads as a working array (and satisfied the
## tutorial's build goal before the return wire existed).
static func _pv_sources_over(model: GraphModel, controller_id: String,
		conns: Array) -> Array[String]:
	var out: Array[String] = []
	if model == null or controller_id.is_empty():
		return out
	var pos_seeds := leg_neighbors(controller_id, conns, "pv", "pos")
	if pos_seeds.is_empty():
		return out
	var neg_seeds := leg_neighbors(controller_id, conns, "pv", "neg")
	if neg_seeds.is_empty():
		return out
	var blocked: Dictionary = {controller_id: true}
	var via_pos := _pv_sources_reachable(model, pos_seeds, conns, blocked)
	if via_pos.is_empty():
		return out
	var via_neg := _pv_sources_reachable(model, neg_seeds, conns, blocked)
	for sid in via_pos:
		if via_neg.has(sid):
			out.append(str(sid))
	out.sort()
	return out


## All PV-source nodes feeding `controller_id` within one scope.
static func pv_sources_for_controller(model: GraphModel, controller_id: String,
		scope_id: String = "root") -> Array[String]:
	if model == null:
		return [] as Array[String]
	return _pv_sources_over(model, controller_id, model.get_connections_in_scope(scope_id))


## Per parallel branch Voc feeding a controller. Returns Array of branch Voc values.
static func branch_vocs_for_controller(model: GraphModel, controller_id: String,
		scope_id: String = "root", ambient_c: float = 25.0) -> Array:
	var sources := pv_sources_for_controller(model, controller_id, scope_id)
	if sources.is_empty():
		return []
	var conns: Array = model.get_connections_in_scope(scope_id)
	var comps := connected_components(sources, conns, true)
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


# ---------------------------------------------------------------------------
# Nesting-aware (flattened-graph) variants
# ---------------------------------------------------------------------------
## These operate on the FLATTENED connection graph (GraphNesting.flat_connections)
## so a PV string split across super-node (compound) boundaries — panels inside a
## group wired to a controller outside it, at any nesting depth — is traced and
## Voc-checked as one circuit. They also scan EVERY scope at once, so a fault
## deep in a collapsed sub-canvas is caught without drilling in.

static func pv_sources_for_controller_flat(model: GraphModel, controller_id: String,
		flat_conns: Array) -> Array[String]:
	return _pv_sources_over(model, controller_id, flat_conns)


static func branch_vocs_for_controller_flat(model: GraphModel, controller_id: String,
		flat_conns: Array, ambient_c: float = 25.0) -> Array:
	var sources := pv_sources_for_controller_flat(model, controller_id, flat_conns)
	if sources.is_empty():
		return []
	var comps := connected_components(sources, flat_conns, true)
	var branch_vocs: Array = []
	for comp in comps:
		branch_vocs.append(component_string_voc(comp as Array, model, ambient_c))
	return branch_vocs


## Highest branch Voc feeding a controller (flattened / nesting-aware). This is
## the voltage the array actually presents at the controller's PV terminals —
## used for the wire label as well as the fault check.
static func max_string_voc_for_controller_flat(model: GraphModel, controller_id: String,
		flat_conns: Array, ambient_c: float = 25.0) -> float:
	var max_v := 0.0
	for v in branch_vocs_for_controller_flat(model, controller_id, flat_conns, ambient_c):
		max_v = maxf(max_v, float(v))
	return max_v


## All over-voltage faults across the WHOLE graph (every scope, nesting-aware).
static func find_overvoltage_faults_flat(model: GraphModel, ambient_c: float = 25.0) -> Array:
	var faults: Array = []
	if model == null:
		return faults
	var flat_conns := GraphNesting.flat_connections(model)
	for item in GraphNesting.walk_items(model, "root"):
		if not (item is Dictionary):
			continue
		if str((item as Dictionary).get("type", "")) != "controller":
			continue
		var cid := str((item as Dictionary).get("id", ""))
		var max_allowed := controller_max_voc(item as Dictionary)
		for bv in branch_vocs_for_controller_flat(model, cid, flat_conns, ambient_c):
			if float(bv) > max_allowed + 0.5:
				faults.append({
					"controller_id": cid,
					"string_voc": float(bv),
					"max_voc": max_allowed,
				})
				break
	return faults


## Mark PV connections (real wires, by origin id) whose string exceeds a
## controller Voc limit — flattened so boundary/nested wires flag correctly.
static func update_connection_voltage_flags_flat(model: GraphModel, ambient_c: float = 25.0) -> void:
	if model == null:
		return
	var flat_conns := GraphNesting.flat_connections(model)
	var fault_ctrls: Dictionary = {}
	for f in find_overvoltage_faults_flat(model, ambient_c):
		fault_ctrls[str((f as Dictionary).get("controller_id", ""))] = true
	# Precompute PV-source membership per faulted controller once.
	var faulted_sources: Dictionary = {}
	for ctrl_id in fault_ctrls:
		for sid in pv_sources_for_controller_flat(model, str(ctrl_id), flat_conns):
			faulted_sources[str(sid)] = true
	for conn in flat_conns:
		var c: Dictionary = conn
		var pol := str(c.get("polarity", ""))
		if pol not in ["positive", "negative", "pvPositive", "pvNegative"]:
			continue
		var sid := str(c.get("source_item_id", ""))
		var tid := str(c.get("target_item_id", ""))
		var mismatch := fault_ctrls.has(sid) or fault_ctrls.has(tid) \
				or faulted_sources.has(sid) or faulted_sources.has(tid)
		var conn_id := str(c.get("id", ""))
		var real := model.get_connection(conn_id)
		if not real.is_empty() and bool(real.get("voltage_mismatch", false)) != mismatch:
			model.update_connection(conn_id, {"voltage_mismatch": mismatch})
