extends RefCounted

## Whole-system design harness, part 1: a DESIGN (plain data, see
## tools/sysdesign/README.md) -> a systems graph made of the game's own
## library presets, wired by resource kind.
##
## A design names presets by their library LABEL (ComponentPresets), so a
## design can only use modules a player can drop from the library. `set`
## overrides are the fields the inspector lets a player edit (a tank's
## capacity, a catchment's area, a habitat's headcount).
##
## Everything goes through GraphModel.add_item / add_connection, the same
## calls the library and the starter seeder use.

const GRID_X := 190.0
const GRID_Y := 170.0


## Every library preset by label (first match wins, like the library).
static func find_preset(label: String) -> Dictionary:
	for cat: Dictionary in ComponentPresets.CATEGORIES:
		for p: Dictionary in (cat.get("presets", []) as Array):
			if str(p.get("label", "")) == label:
				return p
	return ComponentPresets.find_preset_by_label(label)


## Expanded node ids for a design node id ("gh" with count 3 -> gh_1..gh_3).
static func ids_of(design: Dictionary, nid: String) -> Array:
	for n: Dictionary in (design.get("nodes", []) as Array):
		if str(n.get("id", "")) == nid:
			var c := int(n.get("count", 1))
			if c <= 1:
				return [nid]
			var out: Array = []
			for i in c:
				out.append("%s_%d" % [nid, i + 1])
			return out
	return [nid]


## Build the design into `model`. Returns {ok, ids: {design id: [item ids]},
## errors: [..], notes: [..]}. `sgv` (the SystemGraphView) is used for the
## solar array (its own seeder) and may be null in a headless test.
static func build(model: GraphModel, design: Dictionary, sgv: Node = null) -> Dictionary:
	var errors: Array = []
	var notes: Array = []
	var ids := {}
	var col := 0
	var row := 0
	# The rain PBI every rain catchment needs.
	if model.get_item("pbi_rain").is_empty():
		model.add_item({"id": "pbi_rain", "type": "pbi", "x": -900.0, "y": -400.0,
			"width": 100.0, "height": 100.0, "scope_id": "root", "is_virtual": false,
			"locked": true,
			"specs": {"name": "Rain", "resource_kind": "water", "fundamental": true, "locked": true}})
	for n: Dictionary in (design.get("nodes", []) as Array):
		var nid := str(n.get("id", ""))
		var label := str(n.get("preset", ""))
		var preset := find_preset(label)
		if preset.is_empty():
			errors.append("node %s: no library preset '%s'" % [nid, label])
			continue
		var made: Array = []
		for iid: String in ids_of(design, nid):
			var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
			for k in (n.get("set", {}) as Dictionary).keys():
				specs[k] = (n["set"] as Dictionary)[k]
			if int(n.get("count", 1)) > 1 and not (n.get("set", {}) as Dictionary).has("name"):
				specs["name"] = "%s %s" % [str(specs.get("name", label)), iid.get_slice("_", iid.get_slice_count("_") - 1)]
			var ptype := str(preset.get("type", "appliance"))
			if ptype == "processor":
				# Processors are OFF until switched on (habitats ignore it).
				if not specs.has("requested_state"):
					specs["requested_state"] = str(n.get("state", "on"))
				if n.has("recipe"):
					specs["selected_recipe_id"] = str(n["recipe"])
				var autos: Array = specs.get("graph_automations", []) as Array
				for i in autos.size():
					var a: Dictionary = autos[i]
					if str(a.get("id", "")).is_empty():
						a["id"] = "graph_autom_%s_%d" % [iid, i]
			if n.has("automations"):
				var list: Array = (n["automations"] as Array).duplicate(true)
				for i in list.size():
					var a2: Dictionary = list[i]
					a2["id"] = "sysd_%s_%d" % [iid, i]
					if not a2.has("conditions"):
						a2["conditions"] = []
				specs["graph_automations"] = list
			specs["sysdesign_id"] = nid
			var dims := ComponentPresets.spawn_dimensions(preset)
			var pos: Variant = n.get("pos", null)
			var x := float(col) * GRID_X - 700.0
			var y := float(row) * GRID_Y - 300.0
			if pos is Array and (pos as Array).size() >= 2:
				x = float((pos as Array)[0]) + float(made.size()) * 30.0
				y = float((pos as Array)[1]) + float(made.size()) * 30.0
			else:
				col += 1
				if col >= 9:
					col = 0
					row += 1
			var item := {"id": iid, "type": ptype, "x": x, "y": y,
				"width": dims.x, "height": dims.y, "scope_id": "root",
				"is_virtual": false, "specs": specs}
			model.add_item(item)
			if ptype == "processor":
				var live: Dictionary = model.get_item(iid).get("specs", {})
				ResourceKinds.new().migrate_processor_specs(live)
				# A recipe rewrites the ports: resolve it now so wiring by
				# kind sees the recipe's inputs / outputs.
				# A fitted TC Process Lab run (tools/sysdesign/recipes/<x>.json,
				# made by fit_tc_recipes.gd), or a recipe written in the design
				# (what the recipe editor makes).
				if n.has("recipe_file"):
					var rp := "res://tools/sysdesign/recipes/%s.json" % str(n["recipe_file"])
					var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(rp)) \
						if FileAccess.file_exists(rp) else null
					if parsed is Dictionary:
						TcProcSummary.apply_to_specs(live, parsed as Dictionary)
					else:
						errors.append("node %s: no recipe file '%s'" % [nid, rp])
				elif n.has("recipe_def"):
					ProcessRecipe.apply_to_specs(live, (n["recipe_def"] as Dictionary).duplicate(true))
					var rd: Dictionary = n["recipe_def"]
					for inp in (rd.get("inputs", []) as Array):
						if str((inp as Dictionary).get("kind", "")) == "electric":
							live["watts"] = float((inp as Dictionary).get("qty", live.get("watts", 0.0)))
				elif live.has("selected_recipe_id"):
					var rec := ProcessRecipeCatalog.resolve_for_specs(live)
					if rec.is_empty():
						errors.append("node %s: no recipe '%s'" % [nid, str(live["selected_recipe_id"])])
					else:
						ProcessRecipe.apply_to_specs(live, rec)
			made.append(iid)
		ids[nid] = made

	# Solar arrays: the view's own seeder (real panels in strings inside one
	# array compound, wired PV+/PV- to the controller).
	for s: Dictionary in (design.get("solar", []) as Array):
		var pv := find_preset(str(s.get("panel", "JA Solar 380W")))
		var ps: Dictionary = pv.get("specs", {})
		var series := int(s.get("series", 8))
		var parallel := int(s.get("parallel", 1))
		var ctrl_ids: Array = ids.get(str(s.get("controller", "")), [])
		if pv.is_empty() or ctrl_ids.is_empty():
			errors.append("solar %s: panel or controller missing" % str(s.get("id", "?")))
			continue
		if sgv == null:
			notes.append("solar %s skipped (no graph view)" % str(s.get("id", "?")))
			continue
		var tag := "sysd_pv_%s" % str(s.get("id", "pv"))
		var aid := str(sgv.call("add_imported_solar_panels", series * parallel,
			float(ps.get("wmp", 380.0)), str(s.get("name", str(pv.get("label", "PV")))), tag, {
				"voc": float(ps.get("voc", 41.6)), "vmp": float(ps.get("vmp", 34.8)),
				"isc": float(ps.get("isc", 11.5)), "imp": float(ps.get("imp", 10.9)),
				"voc_temp_coeff_pct": float(ps.get("voc_temp_coeff_pct", -0.272)),
				"pmax_temp_coeff_pct": float(ps.get("pmax_temp_coeff_pct", -0.35)),
				"panel_w_m": PvArrayBuilder.DEFAULT_PANEL_W_M,
				"panel_h_m": PvArrayBuilder.DEFAULT_PANEL_H_M,
				"tilt_deg": float(s.get("tilt_deg", 30.0)),
				"azimuth_deg": float(s.get("azimuth_deg", 180.0)),
				"mount_style": SolarArrayBuilder.MOUNT_GROUND,
				"series": series, "parallel": parallel,
				"controller_id": str(ctrl_ids[0]), "show_picker": false,
			}))
		if aid.is_empty():
			errors.append("solar %s: the array was not created" % str(s.get("id", "?")))
		ids[str(s.get("id", "pv"))] = [aid]

	# Resource wires, by kind.
	for w in (design.get("wires", []) as Array):
		var wa: Array = w
		if wa.size() < 3:
			continue
		var kind := str(wa[2])
		for a: String in ids.get(str(wa[0]), [str(wa[0])]):
			for b: String in ids.get(str(wa[1]), [str(wa[1])]):
				var e := wire(model, a, b, kind)
				if not e.is_empty():
					errors.append(e)

	# DC: battery banks onto their controller's battery terminals.
	for d in (design.get("dc", []) as Array):
		var da: Array = d
		for a: String in ids.get(str(da[0]), []):
			for b: String in ids.get(str(da[1]), []):
				_dc(model, a, b)

	# AC: every AC consumer onto a controller's AC output. "ac": {"ctl": [ids]}
	# or, with no entry, everything on the first controller.
	var ac: Dictionary = design.get("ac", {})
	var all_ctrl: Array = []
	for it: Dictionary in model.items_of_type("controller"):
		all_ctrl.append(str(it.get("id", "")))
	var assigned := {}
	for ck in ac.keys():
		for nid2 in (ac[ck] as Array):
			for iid2: String in ids.get(str(nid2), []):
				for c: String in ids.get(str(ck), []):
					_ac(model, c, iid2)
					assigned[iid2] = true
					break
	if not all_ctrl.is_empty():
		for it2: Dictionary in model.items:
			var iid3 := str(it2.get("id", ""))
			if assigned.has(iid3) or not (it2.get("specs", {}) as Dictionary).has("sysdesign_id"):
				continue
			if _needs_ac(it2):
				_ac(model, str(all_ctrl[0]), iid3)
	model.changed.emit("sysdesign_build")
	return {"ok": errors.is_empty(), "ids": ids, "errors": errors, "notes": notes}


static func _needs_ac(item: Dictionary) -> bool:
	var ty := str(item.get("type", ""))
	var sp: Dictionary = item.get("specs", {})
	if ty in ["appliance", "acload"]:
		return true
	if ty != "processor":
		return false
	var es := str(sp.get("energy_source", ""))
	return es == "ac" or (es.is_empty() and float(sp.get("watts", 0.0)) > 0.0)


static func _ac(model: GraphModel, ctrl: String, load: String) -> void:
	var it := model.get_item(load)
	var handle := "power_in" if str(it.get("type", "")) == "processor" else "input"
	model.add_connection({"scope_id": "root", "polarity": "ac",
		"source_item_id": ctrl, "source_handle_id": "acOutput",
		"target_item_id": load, "target_handle_id": handle,
		"waypoints": [], "route_3d": []})


static func _dc(model: GraphModel, ctrl: String, bat: String) -> void:
	model.add_connection({"scope_id": "root", "polarity": "positive",
		"source_item_id": ctrl, "source_handle_id": "batteryPositive",
		"target_item_id": bat, "target_handle_id": "positive", "waypoints": [], "route_3d": []})
	model.add_connection({"scope_id": "root", "polarity": "negative",
		"source_item_id": ctrl, "source_handle_id": "batteryNegative",
		"target_item_id": bat, "target_handle_id": "negative", "waypoints": [], "route_3d": []})


## One resource wire a -> b carrying `kind`. Returns "" or an error.
## kind "dc" wires a generator's DC pair onto a battery.
static func wire(model: GraphModel, a: String, b: String, kind: String) -> String:
	var ia := model.get_item(a)
	var ib := model.get_item(b)
	if ia.is_empty() or ib.is_empty():
		return "wire %s -> %s: item missing" % [a, b]
	if kind == "dc":
		var h := _port_index(ia, "outputs", "dc_electricity")
		if h < 0:
			return "wire %s -> %s: no DC output" % [a, b]
		model.add_connection({"scope_id": "root", "polarity": "positive",
			"source_item_id": a, "source_handle_id": "res_out_%d_pos" % h,
			"target_item_id": b, "target_handle_id": "positive", "waypoints": [], "route_3d": []})
		model.add_connection({"scope_id": "root", "polarity": "negative",
			"source_item_id": a, "source_handle_id": "res_out_%d_neg" % h,
			"target_item_id": b, "target_handle_id": "negative", "waypoints": [], "route_3d": []})
		return ""
	var th := _target_handle(ib, kind)
	if kind.contains(">"):
		kind = kind.get_slice(">", 0)
	var sh := _source_handle(ia, kind)
	if sh.is_empty():
		return "wire %s -> %s: %s has no %s output" % [a, b, a, kind]
	if th.is_empty():
		return "wire %s -> %s: %s has no %s input" % [a, b, b, kind]
	model.add_connection({"scope_id": "root", "polarity": "resource",
		"resource_type": kind,
		"source_item_id": a, "source_handle_id": sh,
		"target_item_id": b, "target_handle_id": th,
		"waypoints": [], "route_3d": [], "conduit_type": "", "route_length_m": 0.0})
	return ""


static func _port_index(item: Dictionary, side: String, kind: String) -> int:
	var arr: Array = (item.get("specs", {}) as Dictionary).get(side, []) as Array
	var want := ResourceKinds.normalize_kind(kind)
	for i in arr.size():
		if ResourceKinds.normalize_kind(str((arr[i] as Dictionary).get("kind", ""))) == want:
			return i
	return -1


static func _source_handle(item: Dictionary, kind: String) -> String:
	match str(item.get("type", "")):
		"resource", "catchment", "pbi":
			return "output"
		"plant":
			return "biomass_out"
		"processor":
			var k := kind
			var i := _port_index(item, "outputs", k)
			return "res_out_%d" % i if i >= 0 else ""
	return ""


## A wire may carry one kind into a port of another of the same unit (the
## canvas allows it: blackwater onto a plot's water port). "blackwater>water"
## names both: the wire's kind, then the port's.
static func _target_handle(item: Dictionary, kind: String) -> String:
	var port_kind := kind
	if kind.contains(">"):
		port_kind = kind.get_slice(">", 1)
	match str(item.get("type", "")):
		"resource", "catchment":
			return "input"
		"plant":
			match ResourceKinds.normalize_kind(port_kind):
				"water": return "water_in"
				"nutrients": return "nutrients_in"
			return ""
		"processor":
			var i := _port_index(item, "inputs", port_kind)
			return "res_in_%d" % i if i >= 0 else ""
	return ""
