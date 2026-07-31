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
##
## Now chemistry-aware. The old single 1.217 ratio was justified as a
## coincidence fit across AGM and LiFePO4, but it only holds for lead-acid:
## a 4S LiFePO4 pack is 12.8 V nominal and 14.6 V full (ratio 1.14), so the
## blanket ratio allowed it to be driven to ~15.6 V before faulting. Falls back
## to the old ratio when the chemistry can't be identified.
static func charge_ceiling_v(bus_v: float, chem: String = "") -> float:
	if chem.is_empty():
		return bus_v * CHARGE_CEILING_RATIO
	return BatteryChemistry.charge_ceiling_v(bus_v, chem)


## Chemistry of a bank, taken from its member batteries. A mixed bank reports
## the most conservative (lowest ceiling per nominal volt) — you must charge to
## the weakest chemistry present.
static func bank_chemistry(model: GraphModel, battery_ids: Array) -> String:
	var best := ""
	var best_ratio := INF
	for bid in battery_ids:
		var it := model.get_item(str(bid))
		if it.is_empty():
			continue
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		var chem := BatteryChemistry.infer(sp)
		if chem.is_empty():
			continue
		var nom := float(sp.get("voltage", 0.0))
		if nom <= 0.0:
			continue
		var ratio := BatteryChemistry.charge_ceiling_v(nom, chem) / nom
		if ratio < best_ratio:
			best_ratio = ratio
			best = chem
	return best


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


## Net roots reached from one polarity leg of `item_id`'s `handle_prefix`
## terminals. Junctions merged into a bank share its root, so one net-key hop
## suffices.
static func _leg_roots(model: GraphModel, item_id: String, flat_conns: Array,
		net_roots: Dictionary, handle_prefix: String, pol: String) -> Dictionary:
	var out: Dictionary = {}
	for conn in flat_conns:
		if not (conn is Dictionary) or not _is_dc_conn(conn as Dictionary):
			continue
		var c: Dictionary = conn
		var local := ""
		var other_id := ""
		var other_handle := ""
		if str(c.get("source_item_id", "")) == item_id:
			local = str(c.get("source_handle_id", ""))
			other_id = str(c.get("target_item_id", ""))
			other_handle = str(c.get("target_handle_id", ""))
		elif str(c.get("target_item_id", "")) == item_id:
			local = str(c.get("target_handle_id", ""))
			other_id = str(c.get("source_item_id", ""))
			other_handle = str(c.get("source_handle_id", ""))
		if other_id.is_empty() or not local.begins_with(handle_prefix):
			continue
		if PvElectrical._terminal_polarity(local) != pol:
			continue
		var key := _net_key(model, other_id, other_handle)
		if key.is_empty() or not net_roots.has(key):
			continue
		out[str(net_roots[key])] = true
	return out


## Item types whose +/− terminals carry a fixed, meaningful polarity role, so a
## crossed wire to a controller is unambiguously backwards. Junctions
## (breaker/combiner) are excluded: their handles are all declared "positive",
## so nothing can be inferred from them.
static func _has_polarity_role(item: Dictionary) -> bool:
	if item.is_empty() or bool(item.get("is_virtual", false)):
		return false
	var ty := str(item.get("type", ""))
	return ty in ["panel", "wind", "hydro", "battery", "smartbattery"] \
			or PvElectrical.is_pv_source_item(item)


## Wires that connect a controller terminal to a device terminal of the OPPOSITE
## polarity — panel + into the controller's PV −, or a battery + into the
## controller's battery −.
##
## Deliberately narrow: only controller↔device links are judged. Panel + to
## panel − is a legitimate series string, and battery + to battery − is a
## legitimate series bank, so a blanket "+ must meet +" rule would be wrong (and
## graph_seed_selftest asserts those stay connectable). The connect-time check
## in _polarity_compatible is likewise left alone — the wire is allowed to
## exist, it just doesn't work, which is what makes it teachable.
##
## Returns [{conn_id, controller_id, other_id, kind: "pv"|"battery",
##           ctrl_terminal, device_terminal}].
static func find_reverse_polarity(model: GraphModel, flat_conns: Array) -> Array:
	var out: Array = []
	if model == null:
		return out
	for conn in flat_conns:
		if not (conn is Dictionary) or not _is_dc_conn(conn as Dictionary):
			continue
		var c: Dictionary = conn
		var sid := str(c.get("source_item_id", ""))
		var tid := str(c.get("target_item_id", ""))
		var s_item := model.get_item(sid)
		var t_item := model.get_item(tid)
		if s_item.is_empty() or t_item.is_empty():
			continue
		# Exactly one end must be a (real) controller.
		var s_ctrl := str(s_item.get("type", "")) == "controller" \
				and not bool(s_item.get("is_virtual", false))
		var t_ctrl := str(t_item.get("type", "")) == "controller" \
				and not bool(t_item.get("is_virtual", false))
		if s_ctrl == t_ctrl:
			continue
		var ctrl_id := sid if s_ctrl else tid
		var dev_id := tid if s_ctrl else sid
		var ctrl_handle := str(c.get("source_handle_id", "")) if s_ctrl \
				else str(c.get("target_handle_id", ""))
		var dev_handle := str(c.get("target_handle_id", "")) if s_ctrl \
				else str(c.get("source_handle_id", ""))
		if not _has_polarity_role(model.get_item(dev_id)):
			continue
		var ctrl_pol := PvElectrical._terminal_polarity(ctrl_handle)
		var dev_pol := PvElectrical._terminal_polarity(dev_handle)
		if ctrl_pol.is_empty() or dev_pol.is_empty() or ctrl_pol == dev_pol:
			continue
		var kind := "battery" if ctrl_handle.begins_with("battery") else "pv"
		out.append({
			"conn_id": str(c.get("id", "")),
			"controller_id": ctrl_id,
			"other_id": dev_id,
			"kind": kind,
			"ctrl_terminal": ctrl_handle,
			"device_terminal": dev_handle,
		})
	return out


## True when any PV wire into this controller is backwards. Such an array
## presents no usable voltage, so callers must treat its delivery as zero
## rather than letting a crossed pair read as a working string.
static func controller_pv_reversed(model: GraphModel, controller_id: String,
		flat_conns: Array) -> bool:
	for r in find_reverse_polarity(model, flat_conns):
		var rd: Dictionary = r
		if str(rd.get("controller_id", "")) == controller_id and str(rd.get("kind", "")) == "pv":
			return true
	return false


## The bank a controller's battery-side terminals land on, or {} when none.
##
## BOTH terminals must land on the same bank. A single wire is an open circuit:
## no current flows through one conductor, so the controller charges nothing
## until the return leg exists. (A correctly wired pair always shares one root —
## `analyze` unions a bank's pos/neg nets across the battery EMF edge.)
static func bank_for_controller(model: GraphModel, controller_id: String,
		flat_conns: Array, analysis: Dictionary) -> Dictionary:
	var banks: Array = analysis.get("banks", []) as Array
	var net_roots: Dictionary = analysis.get("net_roots", {}) as Dictionary
	if banks.is_empty():
		return {}
	var pos_roots := _leg_roots(model, controller_id, flat_conns, net_roots, "battery", "pos")
	if pos_roots.is_empty():
		return {}
	var neg_roots := _leg_roots(model, controller_id, flat_conns, net_roots, "battery", "neg")
	if neg_roots.is_empty():
		return {}
	for bank in banks:
		var root := str((bank as Dictionary).get("root", ""))
		if pos_roots.has(root) and neg_roots.has(root):
			return bank
	return {}


## Items wired directly to `item_id`'s `pol` ("pos" | "neg") terminal over a
## live DC wire. Uses _is_dc_conn (not PvElectrical's PV polarity set) so
## smart-battery terminals and severed wires are handled by DC rules.
static func _dc_leg_neighbors(item_id: String, flat_conns: Array,
		pol: String) -> Array[String]:
	var out: Array[String] = []
	for conn in flat_conns:
		if not (conn is Dictionary) or not _is_dc_conn(conn as Dictionary):
			continue
		var c: Dictionary = conn
		var local := ""
		var other := ""
		if str(c.get("source_item_id", "")) == item_id:
			local = str(c.get("source_handle_id", ""))
			other = str(c.get("target_item_id", ""))
		elif str(c.get("target_item_id", "")) == item_id:
			local = str(c.get("target_handle_id", ""))
			other = str(c.get("source_item_id", ""))
		if other.is_empty() or PvElectrical._terminal_polarity(local) != pol:
			continue
		out.append(other)
	return out


## PV sources reachable from `seeds` over live DC wires, conducting onward only
## through PV sources, junctions and batteries, and stopping at a live
## controller (which regulates) or any load. `blocked` ids start out visited.
static func _pv_hits_from(model: GraphModel, seeds: Array, flat_conns: Array,
		blocked: Dictionary) -> Dictionary:
	var pv_hits: Dictionary = {}
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
		var it := model.get_item(cur)
		if it.is_empty():
			continue
		var ty := str(it.get("type", ""))
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		if ty == "controller" and not bool(sp.get("destroyed", false)):
			continue  # a live controller regulates — stop here
		var is_pv := PvElectrical.is_pv_source_item(it)
		if is_pv:
			pv_hits[cur] = true
		if not (is_pv or ty in JUNCTION_TYPES or is_battery_item(it)):
			continue
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
			q.append(other)
	return pv_hits


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
		# A string only pushes its Voc onto the bank when it is wired across
		# BOTH sides. Walk each polarity leg separately (with the bank's own
		# batteries blocked, so a walk cannot cross through them to the far
		# terminal) and keep only the sources common to both.
		var batt_ids: Array = bank.get("battery_ids", []) as Array
		var blocked: Dictionary = {}
		for bid in batt_ids:
			blocked[str(bid)] = true
		var pos_seeds: Array[String] = []
		var neg_seeds: Array[String] = []
		for bid in batt_ids:
			pos_seeds.append_array(_dc_leg_neighbors(str(bid), flat_conns, "pos"))
			neg_seeds.append_array(_dc_leg_neighbors(str(bid), flat_conns, "neg"))
		if pos_seeds.is_empty() or neg_seeds.is_empty():
			continue
		var via_pos := _pv_hits_from(model, pos_seeds, flat_conns, blocked)
		if via_pos.is_empty():
			continue
		var via_neg := _pv_hits_from(model, neg_seeds, flat_conns, blocked)
		var pv_hits: Dictionary = {}
		for sid in via_pos:
			if via_neg.has(sid):
				pv_hits[sid] = true
		if pv_hits.is_empty():
			continue
		var comps := PvElectrical.connected_components(pv_hits.keys(), flat_conns, true)
		var worst := 0.0
		for comp in comps:
			worst = maxf(worst, PvElectrical.component_string_voc(comp as Array, model, ambient_c))
		var chem := bank_chemistry(model, bank.get("battery_ids", []) as Array)
		var safe := charge_ceiling_v(float(bank.get("bus_voltage", 12.0)), chem)
		if worst > safe + 0.5:
			faults.append({
				"bank": bank,
				"battery_ids": (bank.get("battery_ids", []) as Array).duplicate(),
				"string_voc": worst,
				"safe_v": safe,
				"chemistry": chem,
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
