class_name CampLedger
extends RefCounted

## Per-SCOPE resource accounting — the camp-level sibling of ClosureMetrics
## (which stays whole-model). For one compound's interior (or the root) it
## answers, per resource kind: what is stored, what is made, what is eaten,
## what is imported, and therefore whether the loop is CLOSED, IMPORTING,
## SURPLUS (a waste nobody takes away) or OPEN — needed and neither made nor
## brought in, the badge a camp compound shows at festival level.
##
## Rates are the items' nominal specs (habitat inputs × occupants, processor
## outputs); a bridge may hand in the live per-habitat demand instead
## (`demand_overrides` = {habitat_item_id: {kind: qty/h}}, what
## ResourceFlowEngine.set_habitat_demand receives). Pure: reads the model.

const STATUS_CLOSED := "closed"
const STATUS_IMPORTING := "importing"
const STATUS_SURPLUS := "surplus"
const STATUS_OPEN := "open"
const STATUS_IDLE := "idle"

## Kinds a camp produces that somebody must take away.
const WASTE_KINDS: Array = ["greywater", "blackwater", "food_waste", "plastic_waste", "packaging_waste"]


## {kinds: {kind: row}, open: [kind…], scope: scope_id} where
## row = {stock, capacity, supply, demand, imports, net, days_to_empty,
##        days_to_full, unit, status}.
static func compute(model, scope_id: String, demand_overrides: Dictionary = {}) -> Dictionary:
	var rows: Dictionary = {}
	if model == null:
		return {"kinds": rows, "open": [], "scope": scope_id}
	for item_v in GraphNesting.walk_items(model, scope_id):
		var item: Dictionary = item_v
		var ty := str(item.get("type", ""))
		var specs: Dictionary = item.get("specs", {})
		if bool(item.get("is_virtual", false)) or bool(item.get("is_ghost", false)):
			continue
		match ty:
			"resource":
				if bool(specs.get("unlimited_capacity", false)) or bool(specs.get("outlet_sink", false)):
					continue
				var kind := ResourceKinds.normalize_kind(str(specs.get("resource_kind", "")))
				if kind.is_empty():
					continue
				var row := _row(rows, kind, str(specs.get("capacity_unit", "")))
				var cap := maxf(float(specs.get("capacity_qty", 0.0)), 0.0)
				row["capacity"] = float(row["capacity"]) + cap
				row["stock"] = float(row["stock"]) + clampf(float(specs.get("level", 0.0)), 0.0, 1.0) * cap
			"processor":
				var iid := str(item.get("id", ""))
				var role := str(specs.get("role", ""))
				var is_import := bool(specs.get("counts_as_import", false)) or role == "import"
				var mult := 1.0
				if role == "habitat":
					mult = maxf(float(specs.get("occupants", 1.0)), 1.0)
				var over: Dictionary = demand_overrides.get(iid, {})
				for inp in specs.get("inputs", []):
					var kind := ResourceKinds.normalize_kind(str((inp as Dictionary).get("kind", "")))
					if kind.is_empty():
						continue
					var rate := float((inp as Dictionary).get("rate", 0.0)) * mult
					if role == "habitat" and not over.is_empty():
						rate = maxf(float(over.get(kind, 0.0)), 0.0)
					if rate <= 0.0:
						continue
					var row := _row(rows, kind, str((inp as Dictionary).get("unit", "")))
					row["demand"] = float(row["demand"]) + rate
				for outp in specs.get("outputs", []):
					var kind := ResourceKinds.normalize_kind(str((outp as Dictionary).get("kind", "")))
					if kind.is_empty():
						continue
					var rate := float((outp as Dictionary).get("rate", 0.0)) * mult
					if rate <= 0.0:
						continue
					var row := _row(rows, kind, str((outp as Dictionary).get("unit", "")))
					if is_import:
						row["imports"] = float(row["imports"]) + rate
					else:
						row["supply"] = float(row["supply"]) + rate
			"plant", "catchment":
				for outp in specs.get("outputs", []):
					var kind := ResourceKinds.normalize_kind(str((outp as Dictionary).get("kind", "")))
					var rate := float((outp as Dictionary).get("rate", 0.0))
					if kind.is_empty() or rate <= 0.0:
						continue
					var row := _row(rows, kind, str((outp as Dictionary).get("unit", "")))
					row["supply"] = float(row["supply"]) + rate
	var open: Array = []
	for kind in rows.keys():
		var row: Dictionary = rows[kind]
		var supply := float(row["supply"]) + float(row["imports"])
		var demand := float(row["demand"])
		row["net"] = supply - demand
		var deficit := demand - supply
		row["days_to_empty"] = (float(row["stock"]) / (deficit * 24.0)) if deficit > 1e-9 else INF
		var room := maxf(float(row["capacity"]) - float(row["stock"]), 0.0)
		row["days_to_full"] = (room / (-deficit * 24.0)) if deficit < -1e-9 else INF
		var status := STATUS_IDLE
		if demand > 1e-9 and deficit > 1e-9:
			status = STATUS_IMPORTING if float(row["imports"]) > 1e-9 else STATUS_OPEN
		elif demand > 1e-9:
			status = STATUS_IMPORTING if float(row["imports"]) > 1e-9 else STATUS_CLOSED
		elif supply > 1e-9:
			status = STATUS_SURPLUS if WASTE_KINDS.has(str(kind)) or float(row["capacity"]) > 0.0 else STATUS_IDLE
		row["status"] = status
		if status == STATUS_OPEN or (status == STATUS_SURPLUS and WASTE_KINDS.has(str(kind))):
			open.append(str(kind))
	open.sort()
	return {"kinds": rows, "open": open, "scope": scope_id}


static func _row(rows: Dictionary, kind: String, unit: String) -> Dictionary:
	if not rows.has(kind):
		rows[kind] = {"stock": 0.0, "capacity": 0.0, "supply": 0.0, "demand": 0.0,
			"imports": 0.0, "net": 0.0, "days_to_empty": INF, "days_to_full": INF,
			"unit": unit, "status": STATUS_IDLE}
	var row: Dictionary = rows[kind]
	if str(row["unit"]).is_empty() and not unit.is_empty():
		row["unit"] = unit
	return row


## Which of a compound's promoted ports carry a wire in its parent scope:
## {handle_id: {kind, direction, wired}}.
static func boundary_ports(model, comp_id: String) -> Dictionary:
	var out := {}
	if model == null:
		return out
	var item: Dictionary = model.get_item(comp_id)
	if item.is_empty():
		return out
	var conns: Array = model.get("connections") if model.get("connections") is Array else []
	for ep in (item.get("specs", {}) as Dictionary).get("exposed_ports", []):
		var e: Dictionary = ep
		var hid := str(e.get("handle_id", ""))
		var wired := false
		for c in conns:
			var cd: Dictionary = c
			if (str(cd.get("source_item_id", "")) == comp_id and str(cd.get("source_handle_id", "")) == hid) \
					or (str(cd.get("target_item_id", "")) == comp_id and str(cd.get("target_handle_id", "")) == hid):
				wired = true
				break
		out[hid] = {"kind": str(e.get("kind", "")), "direction": str(e.get("direction", "in")), "wired": wired}
	return out


## The loops a camp has not closed AND has not wired out — the badge text.
static func open_kinds(model, comp_id: String, demand_overrides: Dictionary = {}) -> Array:
	var item: Dictionary = model.get_item(comp_id) if model != null else {}
	if item.is_empty():
		return []
	var ledger := compute(model, str(item.get("child_scope_id", "")), demand_overrides)
	var ports := boundary_ports(model, comp_id)
	var wired_kinds: Dictionary = {}
	for hid in ports:
		if bool(ports[hid]["wired"]):
			wired_kinds[str(ports[hid]["kind"])] = true
	var out: Array = []
	for kind in ledger["open"]:
		if not wired_kinds.has(str(kind)):
			out.append(str(kind))
	return out


## Every festival camp (root-scope compounds carrying `camp_lot_id`) plus the
## site-wide sum per kind. {camps: [{id, name, lot_id, rows, open}], totals:
## {kind: row}, people}.
static func festival(model, demand_overrides: Dictionary = {}) -> Dictionary:
	var camps: Array = []
	var totals: Dictionary = {}
	var people := 0
	if model == null:
		return {"camps": camps, "totals": totals, "people": 0}
	for item_v in model.get_items_in_scope("root"):
		var item: Dictionary = item_v
		var specs: Dictionary = item.get("specs", {})
		if str(item.get("type", "")) != "compound" or not specs.has("camp_lot_id"):
			continue
		var cid := str(item.get("id", ""))
		var ledger := compute(model, str(item.get("child_scope_id", "")), demand_overrides)
		camps.append({"id": cid, "name": str(specs.get("name", "Camp")),
			"lot_id": str(specs.get("camp_lot_id", "")), "rows": ledger["kinds"],
			"open": open_kinds(model, cid, demand_overrides)})
		people += int(specs.get("camp_headcount", 0))
		for kind in (ledger["kinds"] as Dictionary):
			var r: Dictionary = ledger["kinds"][kind]
			var t := _row(totals, str(kind), str(r["unit"]))
			for k in ["stock", "capacity", "supply", "demand", "imports"]:
				t[k] = float(t[k]) + float(r[k])
	for kind in totals:
		var t: Dictionary = totals[kind]
		t["net"] = float(t["supply"]) + float(t["imports"]) - float(t["demand"])
		var deficit := float(t["demand"]) - float(t["supply"]) - float(t["imports"])
		t["days_to_empty"] = (float(t["stock"]) / (deficit * 24.0)) if deficit > 1e-9 else INF
	return {"camps": camps, "totals": totals, "people": people}
