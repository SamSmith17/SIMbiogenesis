class_name GraphDcElectrical
extends RefCounted

## DC-side electrical topology for the systems graph: battery-bank bus voltage,
## short-circuit detection, unregulated-PV battery overvoltage, and controller
## current throttling. Sibling of PvElectrical (which owns the PV-string Voc
## math); both operate on GraphNesting.flat_connections so wiring across
## super-node boundaries is analyzed as one circuit.
##
## Physics sources (project convention — no invented constants):
## - Short circuit: Kirchhoff's voltage law. A closed conductive loop with
##   nonzero net EMF and only conductor resistance (milliohms) drives
##   I = ΣV/R_loop into the hundreds of amps — far beyond conductor ampacity
##   (NEC 310.16 rationale) — igniting insulation. Modeled as a
##   potential-consistency check (difference constraints / weighted union-find)
##   over conductive nets: an inconsistent constraint == a loop with net EMF.
## - Charge ceiling: absorb/full-charge voltage ≈ 1.217 × nominal for both AGM
##   lead-acid absorb (14.4–14.7 V on 12 V) and 4S LiFePO4 (14.6 V on 12.8 V)
##   per manufacturer datasheet convention. PV Voc above this, wired to the
##   bank with no charge controller, overcharges the cells.
## - Controller current limit: a charge controller delivers at the battery bus
##   voltage capped at its rated charge current, so P_delivered ≈ V_bat × I_max
##   (Victron Energy, "Which solar charge controller: PWM or MPPT?").

const CHARGE_CEILING_RATIO := 14.6 / 12.0  # ≈1.217 × nominal (datasheet convention)
const EMF_TOLERANCE_V := 1.0        # equal-voltage parallel chains are legitimate
const DC_POLARITIES: Array[String] = ["positive", "negative", "smart_battery"]

## Item types that conduct passively between all their DC terminals (junctions).
const JUNCTION_TYPES: Array[String] = ["breaker", "combiner"]


static func is_battery_item(item: Dictionary) -> bool:
	if bool(item.get("is_virtual", false)):
		return false
	var ty := str(item.get("type", ""))
	return ty == "battery" or ty == "smartbattery"


static func battery_nominal_v(item: Dictionary) -> float:
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	return float(sp.get("voltage", 12.0))


## Max safe charging voltage for a bank at `bus_v` nominal.
static func charge_ceiling_v(bus_v: float) -> float:
	return bus_v * CHARGE_CEILING_RATIO


static func _is_dc_conn(conn: Dictionary) -> bool:
	if bool(conn.get("severed", false)):
		return false  # a burned/severed wire no longer conducts
	return str(conn.get("polarity", "")) in DC_POLARITIES


## Conductive-net key for one wire endpoint, or "" when the item terminates the
## net (controller, load, inverter — anything with internal electronics).
static func _net_key(model: GraphModel, item_id: String, handle_id: String) -> String:
	var item := model.get_item(item_id)
	if item.is_empty():
		return ""
	if is_battery_item(item):
		# Skip destroyed batteries: no EMF, terminals treated open until reset.
		if bool((item.get("specs", {}) as Dictionary).get("destroyed", false)):
			return ""
		var pol := PvElectrical._terminal_polarity(handle_id)
		if pol.is_empty():
			return ""
		return "B|%s|%s" % [item_id, pol]
	if str(item.get("type", "")) in JUNCTION_TYPES and not bool(item.get("is_virtual", false)):
		return "J|%s" % item_id
	return ""


# --- Weighted union-find (potentials) -------------------------------------
# uf[key] = {"p": parent_key, "d": potential(key) − potential(parent)}

static func _uf_find(uf: Dictionary, key: String) -> Array:
	# Returns [root_key, potential(key) − potential(root)]; path-compresses.
	var path: Array[String] = []
	var cur := key
	var pot := 0.0
	while true:
		var e: Dictionary = uf[cur]
		var parent := str(e.get("p", cur))
		if parent == cur:
			break
		path.append(cur)
		pot += float(e.get("d", 0.0))
		cur = parent
	# Compress: repoint every node on the path directly at the root.
	var acc := pot
	for pk in path:
		var e2: Dictionary = uf[pk]
		var step := float(e2.get("d", 0.0))
		uf[pk] = {"p": cur, "d": acc}
		acc -= step
	return [cur, pot]


## Assert potential(a) = potential(b) + diff. Returns NAN when merged cleanly
## (or consistent), else the inconsistency magnitude (existing − asserted).
static func _uf_union(uf: Dictionary, a: String, b: String, diff: float) -> float:
	var fa := _uf_find(uf, a)
	var fb := _uf_find(uf, b)
	var root_a := str(fa[0])
	var root_b := str(fb[0])
	var pot_a := float(fa[1])
	var pot_b := float(fb[1])
	if root_a == root_b:
		return (pot_a - pot_b) - diff  # implied − asserted
	# potential(root_a) = potential(a) − pot_a; want pot(a) = pot(b) + diff
	# → pot(root_a) = pot(root_b) + (pot_b + diff − pot_a)
	uf[root_a] = {"p": root_b, "d": pot_b + diff - pot_a}
	return NAN


## Full DC-bank analysis over the flattened graph.
## Returns {
##   "banks": [{root, battery_ids, bus_voltage, capacity_kwh, mismatch,
##              shorted, series_count, parallel_count, conn_ids}],
##   "shorts": [{battery_id, root, loop_emf_v, conn_ids}],
##   "net_roots": {net_key: root},   # every conductive net key → final root
## }
static func analyze(model: GraphModel, flat_conns: Array) -> Dictionary:
	var out := {"banks": [], "shorts": [], "net_roots": {}}
	if model == null:
		return out
	var batteries: Array[Dictionary] = []
	for item in GraphNesting.walk_items(model, "root"):
		if item is Dictionary and is_battery_item(item as Dictionary) \
				and not bool(((item as Dictionary).get("specs", {}) as Dictionary).get("destroyed", false)):
			batteries.append(item as Dictionary)
	if batteries.is_empty():
		return out

	var uf: Dictionary = {}
	for b in batteries:
		var bid := str(b.get("id", ""))
		uf["B|%s|pos" % bid] = {"p": "B|%s|pos" % bid, "d": 0.0}
		uf["B|%s|neg" % bid] = {"p": "B|%s|neg" % bid, "d": 0.0}

	# Pass 1 — wires (equipotential merges). Track wire ids per endpoint key so
	# a short can name the conductors carrying fault current.
	var wire_edges: Array = []  # [{a, b, conn_id}]
	for conn in flat_conns:
		if not (conn is Dictionary) or not _is_dc_conn(conn as Dictionary):
			continue
		var c: Dictionary = conn
		var ka := _net_key(model, str(c.get("source_item_id", "")), str(c.get("source_handle_id", "")))
		var kb := _net_key(model, str(c.get("target_item_id", "")), str(c.get("target_handle_id", "")))
		if ka.is_empty() or kb.is_empty():
			continue
		if not uf.has(ka):
			uf[ka] = {"p": ka, "d": 0.0}
		if not uf.has(kb):
			uf[kb] = {"p": kb, "d": 0.0}
		wire_edges.append({"a": ka, "b": kb, "conn_id": str(c.get("id", ""))})
		_uf_union(uf, ka, kb, 0.0)  # wires processed first — never inconsistent

	# Pass 2 — batteries as EMF edges: pot(pos) = pot(neg) + V.
	# Same-root cases: implied ≈ V → clean parallel; implied ≈ 0 or opposing
	# → dead short (KVL loop with net EMF); other → chain-voltage mismatch.
	var shorts: Array = []
	var mismatched_roots: Dictionary = {}
	for b in batteries:
		var bid := str(b.get("id", ""))
		var v := battery_nominal_v(b)
		var pos_key := "B|%s|pos" % bid
		var neg_key := "B|%s|neg" % bid
		var fa := _uf_find(uf, pos_key)
		var fb := _uf_find(uf, neg_key)
		if str(fa[0]) == str(fb[0]):
			var implied := float(fa[1]) - float(fb[1])
			if absf(implied - v) <= EMF_TOLERANCE_V:
				continue  # consistent parallel placement
			if implied < EMF_TOLERANCE_V:
				# Terminals already tied together (or opposing) through pure
				# conductors → closed loop with net EMF ≈ v − implied.
				shorts.append({
					"battery_id": bid,
					"root": str(fa[0]),
					"loop_emf_v": absf(v - implied),
				})
			else:
				mismatched_roots[str(fa[0])] = true
		else:
			_uf_union(uf, pos_key, neg_key, v)

	# Group terminals by final root; collect per-root batteries + potentials.
	var root_batts: Dictionary = {}   # root -> Array[battery item]
	var root_potmin: Dictionary = {}
	var root_potmax: Dictionary = {}
	for b in batteries:
		var bid := str(b.get("id", ""))
		for term in ["pos", "neg"]:
			var f := _uf_find(uf, "B|%s|%s" % [bid, term])
			var root := str(f[0])
			var pot := float(f[1])
			if not root_batts.has(root):
				root_batts[root] = {}
				root_potmin[root] = pot
				root_potmax[root] = pot
			(root_batts[root] as Dictionary)[bid] = b
			root_potmin[root] = minf(float(root_potmin[root]), pot)
			root_potmax[root] = maxf(float(root_potmax[root]), pot)

	var shorted_roots: Dictionary = {}
	for s in shorts:
		shorted_roots[str((s as Dictionary).get("root", ""))] = true

	# Attribute conducting wires to their final root (for burn/report).
	var root_conns: Dictionary = {}
	for we in wire_edges:
		var root := str(_uf_find(uf, str((we as Dictionary).get("a", "")))[0])
		if not root_conns.has(root):
			root_conns[root] = []
		(root_conns[root] as Array).append(str((we as Dictionary).get("conn_id", "")))
	for s in shorts:
		(s as Dictionary)["conn_ids"] = (root_conns.get(str((s as Dictionary).get("root", "")), []) as Array).duplicate()

	for root in root_batts:
		var ids: Array = (root_batts[root] as Dictionary).keys()
		ids.sort()
		var cap := 0.0
		var v_sum := 0.0
		for bid in ids:
			var b: Dictionary = (root_batts[root] as Dictionary)[bid]
			cap += float((b.get("specs", {}) as Dictionary).get("kwh", 0.0))
			v_sum += battery_nominal_v(b)
		var bus := float(root_potmax[root]) - float(root_potmin[root])
		var mean_v := v_sum / maxf(1.0, float(ids.size()))
		var series := clampi(int(roundf(bus / maxf(mean_v, 0.001))), 1, ids.size())
		out["banks"].append({
			"root": str(root),
			"battery_ids": ids,
			"bus_voltage": bus,
			"capacity_kwh": cap,
			"mismatch": mismatched_roots.has(str(root)),
			"shorted": shorted_roots.has(str(root)),
			"series_count": series,
			"parallel_count": maxi(1, int(roundf(float(ids.size()) / float(series)))),
			"conn_ids": (root_conns.get(str(root), []) as Array).duplicate(),
		})
	out["shorts"] = shorts
	# Final key→root map (post all unions) so callers can resolve any endpoint
	# — battery terminal or junction — to its bank without re-traversing.
	var net_roots: Dictionary = {}
	for key in uf:
		net_roots[str(key)] = str(_uf_find(uf, str(key))[0])
	out["net_roots"] = net_roots
	return out


## The bank a controller's battery-side terminals land on, or {} when none.
## Junctions merged into a bank share its root, so one net-key hop suffices.
static func bank_for_controller(model: GraphModel, controller_id: String,
		flat_conns: Array, analysis: Dictionary) -> Dictionary:
	var banks: Array = analysis.get("banks", []) as Array
	var net_roots: Dictionary = analysis.get("net_roots", {}) as Dictionary
	if banks.is_empty():
		return {}
	for conn in flat_conns:
		if not (conn is Dictionary) or not _is_dc_conn(conn as Dictionary):
			continue
		var c: Dictionary = conn
		var other_id := ""
		var other_handle := ""
		if str(c.get("source_item_id", "")) == controller_id \
				and str(c.get("source_handle_id", "")).begins_with("battery"):
			other_id = str(c.get("target_item_id", ""))
			other_handle = str(c.get("target_handle_id", ""))
		elif str(c.get("target_item_id", "")) == controller_id \
				and str(c.get("target_handle_id", "")).begins_with("battery"):
			other_id = str(c.get("source_item_id", ""))
			other_handle = str(c.get("source_handle_id", ""))
		if other_id.is_empty():
			continue
		var key := _net_key(model, other_id, other_handle)
		if key.is_empty() or not net_roots.has(key):
			continue
		var root := str(net_roots[key])
		for bank in banks:
			if str((bank as Dictionary).get("root", "")) == root:
				return bank
	return {}


## PV strings reachable from a bank battery WITHOUT crossing a (live) charge
## controller → the string's Voc is applied raw to the bank. Fault when it
## exceeds the bank's charge ceiling.
## Returns [{bank, battery_ids, string_voc, safe_v}].
static func find_battery_overvoltage(model: GraphModel, flat_conns: Array,
		analysis: Dictionary, ambient_c: float = 25.0) -> Array:
	var faults: Array = []
	if model == null:
		return faults
	for bank_v in analysis.get("banks", []) as Array:
		var bank: Dictionary = bank_v
		if bool(bank.get("shorted", false)):
			continue  # the short fault already owns this bank
		var pv_hits: Dictionary = {}
		# BFS outward from every bank battery over DC wires, passing through
		# panels/junctions/other batteries, terminating at controllers & loads.
		var visited: Dictionary = {}
		var q: Array[String] = []
		for bid in bank.get("battery_ids", []) as Array:
			visited[str(bid)] = true
			q.append(str(bid))
		while not q.is_empty():
			var cur: String = q.pop_front()
			for conn in flat_conns:
				if not (conn is Dictionary) or not _is_dc_conn(conn as Dictionary):
					continue
				var c: Dictionary = conn
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
				var ty := str(it.get("type", ""))
				var sp: Dictionary = it.get("specs", {}) as Dictionary
				if ty == "controller" and not bool(sp.get("destroyed", false)):
					continue  # a live controller regulates — stop here
				if PvElectrical.is_pv_source_item(it):
					pv_hits[other] = true
				# Conduct onward through panels, junctions, and batteries only.
				if PvElectrical.is_pv_source_item(it) or ty in JUNCTION_TYPES \
						or is_battery_item(it):
					q.append(other)
		if pv_hits.is_empty():
			continue
		var comps := PvElectrical.connected_components(pv_hits.keys(), flat_conns, true)
		var worst := 0.0
		for comp in comps:
			worst = maxf(worst, PvElectrical.component_string_voc(comp as Array, model, ambient_c))
		var safe := charge_ceiling_v(float(bank.get("bus_voltage", 12.0)))
		if worst > safe + 0.5:
			faults.append({
				"bank": bank,
				"battery_ids": (bank.get("battery_ids", []) as Array).duplicate(),
				"string_voc": worst,
				"safe_v": safe,
			})
	return faults


## Delivered-power cap for one controller charging `bank` from `array_w` watts
## of PV: P ≈ V_bus × I_max (Victron PWM/MPPT white paper). max_charge_amps ≤ 0
## → no current limit modeled.
static func controller_throttle(ctrl_item: Dictionary, bank: Dictionary,
		array_w: float) -> Dictionary:
	var sp: Dictionary = ctrl_item.get("specs", {}) as Dictionary
	var bus_v := float(bank.get("bus_voltage", 0.0)) if not bank.is_empty() \
			else float(sp.get("system_voltage", 0.0))
	var max_a := float(sp.get("max_charge_amps", 0.0))
	var delivered := maxf(array_w, 0.0)
	var limit_w := INF
	if bus_v > 0.0 and max_a > 0.0:
		limit_w = bus_v * max_a
		delivered = minf(delivered, limit_w)
	return {
		"bus_voltage": bus_v,
		"max_charge_amps": max_a,
		"limit_w": limit_w,
		"delivered_w": delivered,
		"clipped": delivered < array_w - 1.0,
		"clip_ratio": delivered / maxf(array_w, 1.0),
	}
