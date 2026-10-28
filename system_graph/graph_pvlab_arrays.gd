class_name GraphPvLabArrays
extends RefCounted

## A designed solar array (core/pvlab/) on the systems graph, at two levels.
##
## At the level it sits in, each MPPT input of the design is ONE compound
## (`compound_kind` "pv_design") with a single + / − pair: the combined
## output of its strings in parallel. Zoom into it and the strings are there
## as real `panel` items wired + to − in series, the strings joined in
## parallel at the compound's boundary — so GraphNesting.flat_connections,
## PvElectrical's string Voc checks, GraphDcElectrical and the panel cards all
## see the actual strings, unchanged. Re-seeding the same design (Apply in
## the designer) rebuilds the INTERIOR in place: the compound and every wire
## to it outside survive.
##
## Each child panel carries the design's link back to the 3D twin:
## pvlab_tag, pvlab_panel (its index in PvLabArray.layout), pvlab_string,
## bound_prop_id, plus its plane (tilt_deg, azimuth_deg) or its tracker
## (tracker_axis_az, tracker_gcr, tracker {limits}) for the energy model.
##
## Pure over a GraphModel except for `upsert` / `remove`, which take the
## SystemGraphView for its history / autosave / SolarUI sync.

const KIND := "pv_design"
const STEP_X := 232.0
const STEP_Y := 150.0


## The compounds of a design, by MPPT-input index: {group: compound id}.
static func find(model: GraphModel, tag: String) -> Dictionary:
	var out := {}
	if model == null or tag.is_empty():
		return out
	for it in model.items:
		if not (it is Dictionary):
			continue
		var sp: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if str(sp.get("compound_kind", "")) == KIND and str(sp.get("pvlab_tag", "")) == tag:
			out[int(sp.get("pvlab_group", 0))] = str((it as Dictionary).get("id", ""))
	return out


## Seed or refresh a design on the graph. opts: name, prop_id, tilt_deg,
## azimuth_deg, tracker ({} for a fixed array), axis_az, controller_id,
## auto_wire (default true). Returns the compound ids, one per MPPT input.
static func upsert(view: Node, design: Dictionary, tag: String, opts: Dictionary = {}) -> Array:
	var model: GraphModel = view.get("model")
	if model == null or tag.is_empty():
		return []
	var preset := PvLabDesign.graph_preset(design)
	var groups: Array = preset["groups"]
	var mod_specs: Dictionary = preset["module"]
	var existing := find(model, tag)
	var scope := str(view.get("_active_scope_id")) if view.get("_active_scope_id") != null else "root"
	var arr_name := str(opts.get("name", design.get("name", "Solar array")))
	var created: Array = []
	var ids: Array = []
	view.set("_history_suppress", true)
	var placed := 0
	for it in model.items:
		var sp0: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if str(sp0.get("compound_kind", "")) == KIND or bool(sp0.get("osm_import", false)):
			placed += 1
	for gi in groups.size():
		var g: Dictionary = groups[gi]
		var cid := str(existing.get(gi, ""))
		var label := arr_name if groups.size() == 1 else "%s · input %d" % [arr_name, gi + 1]
		var specs := {
			"name": label, "compound_kind": KIND, "pvlab_tag": tag, "pvlab_group": gi,
			"bound_prop_id": str(opts.get("prop_id", "")), "panel_count": int(g["count"]),
			"design_series": int(g["series"]), "design_parallel": int(g["parallel"]),
			"wmp": float(g["wmp"]), "voc": float(g["voc"]), "vmp": float(g["vmp"]), "isc": float(g["isc"]),
			"imp": float(g["imp"]),
			"summary": "%dS × %dP · %s · %.0f V Voc" % [int(g["series"]), int(g["parallel"]),
				_kw(float(g["wmp"]) * int(g["count"])), float(g["voc"]) * int(g["series"])],
		}
		_plane_keys(specs, opts)
		if cid.is_empty():
			cid = model.generate_item_id()
			var child_scope := "scope_%s" % cid
			model.add_item({"id": cid, "type": "compound", "x": -80.0, "y": float(placed + gi) * 170.0,
				"width": 220.0, "height": 132.0, "scope_id": scope, "child_scope_id": child_scope,
				"handles": [], "specs": specs, "is_virtual": false})
			model.ensure_scope(child_scope, scope, cid, label)
			created.append(cid)
		else:
			var item := model.get_item(cid)
			var merged: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
			for k in specs:
				merged[k] = specs[k]
			model.update_item(cid, {"specs": merged})
			_clear_interior(model, cid)
		_build_interior(model, cid, g, mod_specs, gi, tag, opts)
		ids.append(cid)
	# A design that now has fewer MPPT inputs drops the extra compounds.
	for gk in existing:
		if int(gk) >= groups.size():
			model.remove_item(str(existing[gk]))
	view.set("_history_suppress", false)
	if bool(opts.get("auto_wire", true)):
		for cid2 in created:
			_wire_to_controller(model, str(cid2), str(opts.get("controller_id", "")), scope)
	if view.has_method("_schedule_graph_autosave"):
		view.call("_schedule_graph_autosave")
	if view.has_method("_sync_solar_ui_from_graph"):
		view.call("_sync_solar_ui_from_graph")
	return ids


static func remove(view: Node, tag: String) -> bool:
	var model: GraphModel = view.get("model")
	var found := find(model, tag)
	for gk in found:
		model.remove_item(str(found[gk]))
	if found.is_empty():
		return false
	if view.has_method("_schedule_graph_autosave"):
		view.call("_schedule_graph_autosave")
	if view.has_method("_sync_solar_ui_from_graph"):
		view.call("_sync_solar_ui_from_graph")
	return true


static func _kw(w: float) -> String:
	return "%.0f W" % w if w < 1000.0 else "%.2f kW" % (w / 1000.0)


static func _plane_keys(specs: Dictionary, opts: Dictionary) -> void:
	if opts.get("tracker") is Dictionary and not (opts["tracker"] as Dictionary).is_empty():
		specs["tracker"] = (opts["tracker"] as Dictionary).duplicate()
		specs["tracker_axis_az"] = float(opts.get("axis_az", 180.0))
		specs["tracker_gcr"] = float(opts.get("gcr", 0.0))
		specs.erase("tilt_deg")
		specs.erase("azimuth_deg")
	else:
		specs["tilt_deg"] = float(opts.get("tilt_deg", 0.0))
		specs["azimuth_deg"] = fposmod(float(opts.get("azimuth_deg", 180.0)), 360.0)
		specs.erase("tracker")
		specs.erase("tracker_axis_az")
		specs.erase("tracker_gcr")


static func _clear_interior(model: GraphModel, cid: String) -> void:
	var child_scope := str(model.get_item(cid).get("child_scope_id", ""))
	if child_scope.is_empty():
		return
	var kill: Array = []
	for it in model.items:
		if str((it as Dictionary).get("scope_id", "")) == child_scope:
			kill.append(str((it as Dictionary).get("id", "")))
	for k in kill:
		model.remove_item(str(k))


## The strings of one MPPT input as panels inside the compound: one row per
## string, + to − along it, the strings' ends joined at the first string's
## ends, which the compound's + / − ports lead out of.
static func _build_interior(model: GraphModel, cid: String, g: Dictionary, mod_specs: Dictionary, gi: int,
		tag: String, opts: Dictionary) -> void:
	var child_scope := str(model.get_item(cid).get("child_scope_id", "scope_%s" % cid))
	var strings: Array = g["strings"]
	var dims := ComponentPresets.spawn_dimensions({"type": "panel"})
	var longest := 1
	for st in strings:
		longest = maxi(longest, (st as Array).size())
	var off_x := float(longest - 1) * 0.5 * STEP_X
	var off_y := float(strings.size() - 1) * 0.5 * STEP_Y
	var id_rows: Array = []
	for si in strings.size():
		var row: Array = []
		var st: Array = strings[si]
		for k in st.size():
			var pid := model.generate_item_id()
			var ps := mod_specs.duplicate(true)
			ps["name"] = "S%d·M%d" % [si + 1, int(st[k]) + 1]
			ps["pvlab_tag"] = tag
			ps["pvlab_group"] = gi
			ps["pvlab_panel"] = int(st[k])
			ps["pvlab_string"] = si
			ps["bound_prop_id"] = str(opts.get("prop_id", ""))
			_plane_keys(ps, opts)
			model.add_item({"id": pid, "type": "panel", "x": float(k) * STEP_X - off_x,
				"y": float(si) * STEP_Y - off_y, "width": dims.x, "height": dims.y,
				"scope_id": child_scope, "parent_compound_id": cid, "specs": ps, "is_virtual": false})
			if k > 0:
				GraphPvWiring.add_pv_connection(model, "positive", str(row[k - 1]), "positive", pid, "negative",
					child_scope)
			row.append(pid)
		id_rows.append(row)
	if id_rows.is_empty():
		return
	var first: Array = id_rows[0]
	for si in range(1, id_rows.size()):
		var r: Array = id_rows[si]
		if r.is_empty():
			continue
		GraphPvWiring.add_pv_connection(model, "positive", str(r[r.size() - 1]), "positive",
			str(first[first.size() - 1]), "positive", child_scope)
		GraphPvWiring.add_pv_connection(model, "negative", str(r[0]), "negative", str(first[0]), "negative",
			child_scope)
	var id_map := {"plus": str(first[first.size() - 1]), "minus": str(first[0])}
	GraphComponentDefs._apply_exposed_ports(model, cid, [
		{"handle_id": "positive", "child": "plus", "child_handle": "positive", "direction": "out",
			"polarity": "positive", "label": "PV +"},
		{"handle_id": "negative", "child": "minus", "child_handle": "negative", "direction": "out",
			"polarity": "negative", "label": "PV −"},
	], id_map)
	var sp: Dictionary = (model.get_item(cid).get("specs", {}) as Dictionary).duplicate(true)
	var n := 0
	for r2 in id_rows:
		n += (r2 as Array).size()
	sp["child_count"] = n
	model.update_item(cid, {"specs": sp})


static func _wire_to_controller(model: GraphModel, cid: String, prefer: String, scope: String) -> void:
	var ctrl := prefer
	if ctrl.is_empty() or model.get_item(ctrl).is_empty():
		ctrl = GraphPvWiring.nearest_controller_id(model, [cid], scope)
	if ctrl.is_empty():
		return
	GraphPvWiring.add_pv_connection(model, "positive", cid, "positive", ctrl, "pvPositive", scope)
	GraphPvWiring.add_pv_connection(model, "negative", cid, "negative", ctrl, "pvNegative", scope)


## The strings as the graph has them now (the player may have rewired the
## inside of a compound): [[panel index]] per MPPT input, in input order.
## A chain is panels linked + to − in series; a panel with no link but wired
## to anything is a string of one.
static func strings_from_model(model: GraphModel, tag: String) -> Array:
	var out: Array = []
	var comps := find(model, tag)
	var keys := comps.keys()
	keys.sort()
	for gk in keys:
		var cid := str(comps[gk])
		var child_scope := str(model.get_item(cid).get("child_scope_id", ""))
		var ids: Array = []
		var index_of := {}
		for it in model.items:
			var d: Dictionary = it
			if str(d.get("scope_id", "")) != child_scope or str(d.get("type", "")) != "panel":
				continue
			ids.append(str(d.get("id", "")))
			index_of[str(d.get("id", ""))] = int((d.get("specs", {}) as Dictionary).get("pvlab_panel", -1))
		var next_of := {}
		var wired := {}
		for c in model.connections:
			var cd: Dictionary = c
			if str(cd.get("scope_id", "")) != child_scope:
				continue
			var s := str(cd.get("source_item_id", ""))
			var t := str(cd.get("target_item_id", ""))
			wired[s] = true
			wired[t] = true
			if str(cd.get("source_handle_id", "")) == "positive" and str(cd.get("target_handle_id", "")) == "negative":
				next_of[s] = t
			elif str(cd.get("source_handle_id", "")) == "negative" and str(cd.get("target_handle_id", "")) == "positive":
				next_of[t] = s
		# The compound's exposed ports lead out of a panel: count it wired.
		for ep in (model.get_item(cid).get("specs", {}) as Dictionary).get("exposed_ports", []):
			wired[str((ep as Dictionary).get("child_item_id", ""))] = true
		var chains := PvLabArray.strings_from_links(ids, next_of, wired)
		var group: Array = []
		for ch in chains:
			var st: Array = []
			for k in ch:
				st.append(int(index_of.get(str(ids[int(k)]), -1)))
			group.append(st)
		out.append(group)
	return out
