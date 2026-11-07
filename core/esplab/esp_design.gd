class_name EspDesign
extends RefCounted

## The one solved board design: what the modal, the 3D builder, the world
## runtime and the comparison all read.
##
##   solve(spec) -> {spec (resolved), board, board_label, chip, friendly, node,
##                   wire (EspAutoWire), entities, yaml, secrets, checks,
##                   power, bom, cost_usd}
##
## Each entity: {iid, k, sub, kind (HA domain), name (as in YAML), short,
## entity_id (EspEntityNames), id (ESPHome id), unit, dc, sc, dec, set,
## filters (the part's then the player's), src (what the twin measures),
## sim: {res, acc, acc_pct, noise, lo, hi, tau, …}, update_s}.
##
## Cached by EspSpec.key_of (LRU, CACHE_MAX).

const CACHE_MAX := 24

static var _cache := {}
static var _order: Array = []


static func clear_cache() -> void:
	_cache.clear()
	_order.clear()


static func solve(spec_in: Dictionary) -> Dictionary:
	var spec := EspSpec.resolve(spec_in)
	var key := EspSpec.key_of(spec)
	if _cache.has(key):
		_order.erase(key)
		_order.append(key)
		return _cache[key]
	var d := _solve(spec)
	_cache[key] = d
	_order.append(key)
	while _order.size() > CACHE_MAX:
		_cache.erase(_order.pop_front())
	return d


static func _solve(spec: Dictionary) -> Dictionary:
	var board := EspBoards.get_board(str(spec["board"]))
	var friendly := str(spec["name"])
	var d := {
		"spec": spec, "board": board, "board_label": str(board["label"]),
		"chip": str(board["chip"]), "friendly": friendly, "node": EspEntityNames.node_name(friendly),
	}
	var wire := EspAutoWire.solve(spec)
	d["wire"] = wire
	d["entities"] = entities_of(spec, friendly)
	d["yaml"] = EspYaml.build(d)
	d["secrets"] = EspYaml.secrets_template(d)
	d["checks"] = _sorted_checks(wire["checks"])
	d["power"] = wire["power"]
	d["bom"] = _bom(spec, board)
	var cost := 0.0
	for row in d["bom"]:
		cost += float(row["price"]) * int(row["qty"])
	d["cost_usd"] = cost
	return d


## Every entity the design makes, in YAML order (parts, then diagnostics).
static func entities_of(spec: Dictionary, friendly: String) -> Array:
	var out: Array = []
	for inst in spec["parts"]:
		var part := EspParts.get_part(str(inst["part"]))
		var dom := str(part["yaml"]["dom"])
		var upd := float(inst.get("update_s", -1.0))
		if upd <= 0.0:
			upd = float(part.get("update", 0))
		var measures: Dictionary = inst.get("measures", {})
		var extra_f: Dictionary = inst.get("filters", {})
		for e in part.get("ents", []):
			var kind := str(e.get("kind", dom))
			if kind == "gps":
				kind = "sensor"
			# A part whose one entity IS the part (Relay, Button, LED Strip) takes
			# the instance's own name: a relay called "Fan" is "Fan".
			var en := str(e["name"])
			var name := str(inst["label"]) if en == EspParts.short_label(part) else EspEntityNames.entity_name(str(inst["label"]), en)
			var filters: Array = (e.get("filters", []) as Array).duplicate(true)
			for f in extra_f.get(str(e["k"]), []):
				filters.append(f)
			out.append({
				"iid": str(inst["iid"]), "part": str(inst["part"]), "k": str(e["k"]), "sub": str(e.get("sub", "")),
				"kind": kind, "name": name, "short": str(e["name"]),
				"entity_id": EspEntityNames.entity_id(kind, friendly, name),
				"id": EspEntityNames.esphome_id(str(inst["iid"]), str(e["k"])),
				"unit": str(e.get("unit", "")), "dc": str(e.get("dc", "")), "sc": str(e.get("sc", "")),
				"dec": int(e.get("dec", 0)), "set": e.get("set", []), "filters": filters,
				"part_filters": (e.get("filters", []) as Array).size(),
				"src": str(measures.get(str(e["k"]), e.get("src", ""))),
				"sim": _sim_of(e), "update_s": upd,
			})
	if bool(spec.get("diagnostics", true)):
		for row in [["sensor", "Uptime", "s", "duration"], ["sensor", "WiFi Signal", "dBm", "signal_strength"],
				["binary_sensor", "Status", "", "connectivity"]]:
			out.append({"iid": "", "part": "", "k": str(row[1]).to_lower().replace(" ", "_"), "sub": "",
				"kind": row[0], "name": row[1], "short": row[1],
				"entity_id": EspEntityNames.entity_id(str(row[0]), friendly, str(row[1])),
				"id": "", "unit": row[2], "dc": row[3], "sc": "measurement" if row[0] == "sensor" else "",
				"dec": 0, "set": [], "filters": [], "part_filters": 0, "src": "diag." + str(row[1]).to_lower().replace(" ", "_"),
				"sim": {}, "update_s": 60.0})
	return out


static func _sim_of(e: Dictionary) -> Dictionary:
	var s := {}
	for k in ["res", "acc", "acc_pct", "noise", "lo", "hi", "tau", "range_m", "cone_deg", "raw_per_kg"]:
		if e.has(k):
			s[k] = e[k]
	return s


static func _sorted_checks(checks: Array) -> Array:
	var rank := {"error": 0, "warn": 1, "info": 2}
	var out := checks.duplicate()
	out.sort_custom(func(a, b): return int(rank.get(a["level"], 3)) < int(rank.get(b["level"], 3)))
	return out


static func count_level(d: Dictionary, level: String) -> int:
	var n := 0
	for c in d["checks"]:
		if str(c["level"]) == level:
			n += 1
	return n


## Bill of materials: the board, each part, jumper wires, and the resistors
## the checks ask for. Prices are rough single-unit online prices (USD).
static func _bom(spec: Dictionary, board: Dictionary) -> Array:
	var rows: Array = [{"item": str(board["label"]), "qty": 1, "price": 6.0}]
	var by := {}
	for inst in spec["parts"]:
		var pid := str(inst["part"])
		by[pid] = int(by.get(pid, 0)) + 1
	var ids: Array = by.keys()
	ids.sort()
	var wires := 0
	for pid in ids:
		var part := EspParts.get_part(pid)
		rows.append({"item": str(part["label"]), "qty": int(by[pid]), "price": float(part.get("price", 0.0))})
		wires += (part.get("pins", []) as Array).size() * int(by[pid])
	if wires > 0:
		rows.append({"item": "Dupont jumper wire", "qty": wires, "price": 0.05})
	return rows
