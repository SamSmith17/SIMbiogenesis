extends RefCounted

## Sandbox: ScadaTags.graph_tags (fixed parts cached per item) and
## ElementLedger's stock pass (kind constants cached per kind) against frozen
## copies of the code they replaced, on the live world, a few times while
## the clock runs at 60x. Every tag and every stock row must be identical
## (var_to_str), key order included. Prints ms old vs new.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/scada_ledger_parity.gd -Timeout 900

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("scada-ledger-parity %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


# --- the old ScadaTags.graph_tags, word for word ----------------------------

static func _old_graph_tags(model: Object) -> Array:
	var out: Array = []
	if model == null:
		return out
	for item: Dictionary in model.get("items"):
		var ty := str(item.get("type", ""))
		var iid := str(item.get("id", ""))
		if iid.is_empty():
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var nm := str(specs.get("name", "")).strip_edges()
		if nm.is_empty():
			nm = iid
		if ty == "resource":
			var lvl := clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
			out.append(ScadaTags.make("tank.%s.level" % iid, "Level", "%", ScadaTags.KIND_SENSOR, lvl * 100.0,
					{"group": nm, "item": iid, "lo": 0.0, "hi": 100.0,
					"alias": "tank.%s.level" % ScadaTags.slug(nm)}))
			if not bool(specs.get("unlimited_capacity", false)):
				var cap := float(specs.get("capacity_qty", 0.0))
				out.append(ScadaTags.make("tank.%s.stock" % iid, "Amount", str(specs.get("capacity_unit", "")),
						ScadaTags.KIND_SENSOR, lvl * cap,
						{"group": nm, "item": iid, "lo": 0.0, "hi": cap}))
			out.append(ScadaTags.make("tank.%s" % iid, "Overflowing", "", ScadaTags.KIND_BINARY,
					1.0 if bool(specs.get("overflowing", false)) else 0.0,
					{"group": nm, "item": iid,
					"text": "overflow" if bool(specs.get("overflowing", false)) else "ok",
					"alias": "tank.%s" % ScadaTags.slug(nm)}))
		elif ty in ScadaTags.SWITCHABLE:
			var on := str(specs.get("requested_state", specs.get("current_state", "off"))).to_lower() == "on"
			var st := str(specs.get("node_state", ""))
			var word := "on" if on else "off"
			if st == "starved" or st == "blocked":
				word = st
			out.append(ScadaTags.make("node.%s" % iid, "Running", "", ScadaTags.KIND_SWITCH, 1.0 if on else 0.0,
					{"group": nm, "item": iid, "text": word, "alias": "node.%s" % ScadaTags.slug(nm)}))
			if str(specs.get("role", "")) == "flowctl" and bool(specs.get("throttle", false)):
				out.append(ScadaTags.make("valve.%s.open" % iid, "Opening", "%", ScadaTags.KIND_NUMBER,
						clampf(float(specs.get("open", 1.0)), 0.0, 1.0) * 100.0,
						{"group": nm, "item": iid, "lo": 0.0, "hi": 100.0, "alias": "valve.%s.open" % ScadaTags.slug(nm)}))
		elif ty == "compound" and bool(specs.get("greenhouse_system", false)) and specs.has("gh_t_air"):
			var g := {"group": nm, "item": iid}
			for row in [["temp", "Air temperature", "°C", "gh_t_air"], ["rh", "Humidity", "%", "gh_rh"],
					["dli", "Light today", "mol/m²", "gh_dli"], ["vent", "Vents open", "%", "gh_vent_pct"],
					["water_temp", "Water temperature", "°C", "gh_t_water"]]:
				var o := g.duplicate()
				o["alias"] = "greenhouse.%s.%s" % [ScadaTags.slug(nm), row[0]]
				out.append(ScadaTags.make("greenhouse.%s.%s" % [iid, row[0]], str(row[1]), str(row[2]),
						ScadaTags.KIND_SENSOR, float(specs.get(str(row[3]), 0.0)), o))
			var frost := bool(specs.get("gh_frost", false))
			var fo := g.duplicate()
			fo["text"] = "on" if frost else "off"
			fo["alias"] = "greenhouse.%s.frost" % ScadaTags.slug(nm)
			out.append(ScadaTags.make("greenhouse.%s.frost" % iid, "Frost", "", ScadaTags.KIND_BINARY, 1.0 if frost else 0.0, fo))
	for conn: Dictionary in model.get("connections"):
		var kind := str(conn.get("resource_type", ""))
		if kind.is_empty() or not conn.has("flow_rate"):
			continue
		var cid := str(conn.get("id", ""))
		out.append(ScadaTags.make("wire.%s.flow" % cid, "Flow", "/h", ScadaTags.KIND_SENSOR, float(conn.get("flow_rate", 0.0)),
				{"group": "%s line" % kind.capitalize(), "item": cid}))
	return out


# --- the old stock pass, with the old embodied() ----------------------------

static func _old_cat_embodied(kind: String, qty: float) -> Dictionary:
	var out := {"known": true, "kg": 0.0, "water_kg": 0.0, "elements": {}, "energy_mj": 0.0}
	if not CompositionCatalog.is_material(kind):
		return out
	if CompositionCatalog.row(kind).is_empty():
		out["known"] = false
		return out
	var kg := CompositionCatalog.kg_per_unit(kind) * qty
	var el: Dictionary = {}
	var prof: Dictionary = CompositionCatalog.elements_of(kind)
	for e in prof.keys():
		el[e] = kg * float(prof[e])
	var energy := kg * (CompositionCatalog.lhv_mj_per_kg(kind) + CompositionCatalog.sensible_mj_per_kg(kind))
	return {"known": true, "kg": kg, "water_kg": kg * CompositionCatalog.water_fraction(kind), "elements": el,
		"energy_mj": energy}


static func _old_mu_embodied(kind: String, qty: float, mu: Dictionary) -> Dictionary:
	var emb := _old_cat_embodied(kind, qty)
	if mu.is_empty() or not bool(emb.get("known", false)):
		return emb
	var kg := float(emb.get("kg", 0.0))
	emb["water_kg"] = kg * float(mu.get("water", 0.0))
	var el: Dictionary = (emb.get("elements", {}) as Dictionary).duplicate()
	for e in MakeUp.ELEMENTS:
		el[e] = kg * float(mu.get(e, 0.0))
	emb["elements"] = el
	return emb


static func _old_stocks(items: Array, out: Dictionary) -> void:
	var st: Dictionary = out["stock"]
	for it in items:
		var d: Dictionary = it
		if str(d.get("type", "")) != "resource" or bool(d.get("is_ghost", false)):
			continue
		var specs: Dictionary = d.get("specs", {})
		var kind := str(specs.get("resource_kind", ""))
		if kind.is_empty() or not CompositionCatalog.is_material(kind):
			continue
		if bool(specs.get("unlimited_capacity", false)) or bool(specs.get("outlet_sink", false)) \
				or bool(specs.get("allow_negative", false)):
			st["unlimited"] = int(st["unlimited"]) + 1
			continue
		var qty := ResourceKinds.tank_stock_qty(specs)
		var name := str(specs.get("name", d.get("id", "")))
		var tracked: Dictionary = specs.get("make_up", {}) if bool(specs.get("track_composition", false)) and specs.get("make_up") is Dictionary else {}
		var emb := _old_mu_embodied(kind, qty, tracked)
		var unit := str(ResourceKinds.kind_meta(kind).get("unit", "unit"))
		var row := {"id": str(d.get("id", "")), "name": name, "kind": kind, "qty": qty,
			"unit": unit, "known": bool(emb["known"])}
		if not bool(emb["known"]):
			(out["unknown"] as Array).append(row)
			continue
		row.merge(emb)
		(out["stores"] as Array).append(row)
		st["kg"] = float(st["kg"]) + float(emb["kg"])
		var wkg := float(emb["water_kg"])
		if CompositionCatalog.is_clean_water(kind):
			st["usable_water_kg"] = float(st["usable_water_kg"]) + wkg
		elif wkg > 0.0:
			st["bound_water_kg"] = float(st["bound_water_kg"]) + wkg
			var bk: Dictionary = st["bound_by_kind"]
			bk[kind] = float(bk.get(kind, 0.0)) + wkg
		st["energy_mj"] = float(st["energy_mj"]) + float(emb["energy_mj"])
		st["food_mj"] = float(st["food_mj"]) + float(emb["kg"]) * CompositionCatalog.food_mj_per_kg(kind)
		ElementLedger._add_elements(st["elements"], emb["elements"])


func _blank() -> Dictionary:
	return {"stock": ElementLedger._empty_stock(), "stores": [], "unknown": []}


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 300:
		await tree.process_frame
	var view: Node = main.find_child("SystemGraphView", true, false)
	if view == null:
		return {"ok": false, "why": "no SystemGraphView"}
	var model: GraphModel = view.get("model")
	main.set("time_scale", 60.0 / 3600.0)
	var n_ok := 0
	var t_old := 0
	var t_new := 0
	var l_old := 0
	var l_new := 0
	var n_tags := 0
	var n_stores := 0
	var bad_tag := ""
	var bad_stock := ""
	for k in 8:
		for _i in 30:
			await tree.process_frame
		var u := Time.get_ticks_usec()
		var a := _old_graph_tags(model)
		t_old += Time.get_ticks_usec() - u
		u = Time.get_ticks_usec()
		var b := ScadaTags.graph_tags(model)
		t_new += Time.get_ticks_usec() - u
		n_tags = b.size()
		var same := a.size() == b.size()
		if same:
			for i in a.size():
				if var_to_str(a[i]) != var_to_str(b[i]) or (a[i] as Dictionary).keys() != (b[i] as Dictionary).keys():
					same = false
					if bad_tag.is_empty():
						bad_tag = "%s vs %s" % [var_to_str(a[i]), var_to_str(b[i])]
					break
		elif bad_tag.is_empty():
			bad_tag = "%d tags vs %d" % [a.size(), b.size()]
		var items: Array = GraphNesting.walk_items(model, "root")
		var oa := _blank()
		var ob := _blank()
		u = Time.get_ticks_usec()
		_old_stocks(items, oa)
		l_old += Time.get_ticks_usec() - u
		u = Time.get_ticks_usec()
		ElementLedger._stocks(items, ob)
		l_new += Time.get_ticks_usec() - u
		n_stores = (ob["stores"] as Array).size()
		var same_l := var_to_str(oa) == var_to_str(ob)
		if not same_l and bad_stock.is_empty():
			bad_stock = "stock %s vs %s" % [var_to_str(oa["stock"]).left(300), var_to_str(ob["stock"]).left(300)]
		if same and same_l:
			n_ok += 1
	print("scada-ledger-parity: %d tags, %d stores; graph_tags old %.2f ms new %.2f ms; stocks old %.2f ms new %.2f ms" % [
		n_tags, n_stores, float(t_old) / 8000.0, float(t_new) / 8000.0, float(l_old) / 8000.0, float(l_new) / 8000.0])
	_ok(bad_tag.is_empty(), "graph tags identical over 8 refreshes" + ("" if bad_tag.is_empty() else " (%s)" % bad_tag))
	_ok(bad_stock.is_empty(), "ledger stocks identical over 8 refreshes" + ("" if bad_stock.is_empty() else " (%s)" % bad_stock))
	_ok(n_ok == 8, "all 8 rounds matched")
	return {"ok": _fails.is_empty(), "failures": _fails}
