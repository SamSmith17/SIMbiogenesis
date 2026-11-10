extends RefCounted

## Whole-system design harness: put a design ON a loaded world (graph, people's
## spaces, labour rule, the date), shared by the dry-run runner and the world
## builder.

const Builder := preload("res://tools/sysdesign/sysdesign_builder.gd")


static func load_design(name_or_path: String) -> Dictionary:
	var path := name_or_path
	if not path.begins_with("res://") and not path.begins_with("user://"):
		path = "res://tools/sysdesign/designs/%s.json" % name_or_path
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## The site's weather archive for the year of `abs_h`, loaded (awaits frames).
static func ensure_weather(main: Node, abs_h: float) -> bool:
	var ws: Node = main.get_tree().root.get_node_or_null("WeatherService")
	if ws == null:
		return false
	var d: Dictionary = main.get("clock").call("abs_hours_to_date", abs_h)
	var want := int(ws.call("effective_year", int(d.get("year", 2024))))
	var lat := float(main.get("latitude"))
	var lon := float(main.get("longitude"))
	if int(ws.get("_data_year")) == want and bool(ws.call("covers", lat, lon)):
		return true
	ws.call("request_weather", lat, lon, int(d.get("year", 2024)))
	for i in 600:
		await main.get_tree().process_frame
		if int(ws.get("_data_year")) == want and bool(ws.call("covers", lat, lon)):
			return true
	return false


static func set_date(main: Node, start: Dictionary) -> float:
	main.set("year", int(start.get("year", 2024)))
	main.set("month", int(start.get("month", 1)))
	main.set("day", int(start.get("day", 1)))
	main.set("day_time", float(start.get("hour", 6.0)))
	return float(main.call("get_absolute_hours"))


## Remove everything a player or an earlier build put on the graph (the PBI
## sources stay).
static func clear_graph(model: GraphModel) -> void:
	var ids: Array = []
	for it: Dictionary in model.items:
		if str(it.get("type", "")) != "pbi" and str(it.get("scope_id", "root")) == "root":
			ids.append(str(it.get("id", "")))
	for iid in ids:
		model.remove_item(str(iid))


## The people's spaces as ground areas round the site centre:
## design.spaces = [{type, at: [dx, dz], size: [w, d], capacity, label, tank}].
## `tank` (a design node id) bills what is used there to that store.
static func tag_spaces(main: Node, bridge: Object, design: Dictionary, ids: Dictionary) -> int:
	var reg: Object = bridge.call("registry_for", main)
	if reg == null:
		return 0
	var c: Vector2 = SiteCentre.xz(main)
	var n := 0
	for s: Dictionary in (design.get("spaces", []) as Array):
		var at: Array = s.get("at", [0, 0])
		var size: Array = s.get("size", [4, 4])
		var cx := c.x + float(at[0])
		var cz := c.y + float(at[1])
		var hw := float(size[0]) * 0.5
		var hd := float(size[1]) * 0.5
		var poly := [[cx - hw, cz - hd], [cx + hw, cz - hd], [cx + hw, cz + hd], [cx - hw, cz + hd]]
		var sid := str(reg.call("set_space_type", {"kind": "area", "poly": poly},
			str(s.get("type", "")), int(s.get("capacity", 0)), str(s.get("label", ""))))
		if sid.is_empty():
			continue
		n += 1
		var tank_ids: Array = ids.get(str(s.get("tank", "")), [])
		if not tank_ids.is_empty():
			reg.call("set_space_fields", sid, {"graph_item_id": str(tank_ids[0])})
	return n


## Put the design on the world. Returns the builder's result + {start_abs}.
static func apply(main: Node, sgv: Node, design: Dictionary) -> Dictionary:
	var model: GraphModel = sgv.get("model")
	var start_abs := set_date(main, design.get("start", {}) as Dictionary)
	clear_graph(model)
	# People live where the site marker is.
	var c: Vector2 = SiteCentre.xz(main)
	for n: Dictionary in (design.get("nodes", []) as Array):
		if str(n.get("preset", "")) == "Population":
			var st: Dictionary = n.get("set", {})
			st["home_x"] = c.x
			st["home_z"] = c.y
			if not st.has("pop_routine"):
				st["pop_routine"] = NpcRoutine.default_day().to_array()
			n["set"] = st
	var res := Builder.build(model, design, sgv)
	res["start_abs"] = start_abs
	# Finite labour: machines wait for the crew (ChoreLedger is the meter).
	var loader: Node = main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("get_chore_ledger"):
		var ledger: Object = loader.call("get_chore_ledger")
		if ledger != null:
			ledger.set("infinite_labor", bool(design.get("infinite_labor", false)))
			# No abstract pool of hours either: the crew is the gate.
			if not bool(design.get("infinite_labor", false)):
				ledger.set("chore_hours_available", 0.0)
	if sgv.has_method("_sync_chore_ledger_to_flow"):
		sgv.call("_sync_chore_ledger_to_flow")
	if sgv.has_method("_sync_solar_ui_from_graph"):
		sgv.call("_sync_solar_ui_from_graph")
	return res
