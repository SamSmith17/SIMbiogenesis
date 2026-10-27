class_name GraphWorldInventory
extends RefCounted

## "In the world" — things that exist in the 3D world but are not on the
## systems graph yet: J Light Studio lights, placed props whose model has a
## graph node (turbines, machines, solar racks, StarShade, Linkage structures),
## OSM solar arrays in the SoI, ponds, scene power consumers and scene energy
## sources. The library shows them in one drawer with Add / Locate per row.
##
## Each row is {group, id, name, sub, pos: Vector3 (or Vector3.INF), add:
## Callable}. Adding goes through the SAME function the world-side path uses
## (PlacedLightService.add_to_graph, bind_pv_array_prop, add_pond_to_graph…),
## so a row added here is identical to one added from the 3D world.
##
## Static and duck-typed on purpose: it reads the view and the loader through
## has_method/call so it compiles under --script without either.

const GROUP_ORDER := ["Lights", "Placed models", "Solar arrays (OSM)", "Ponds",
	"Scene devices", "Scene energy sources"]
const GROUP_ICONS := {
	"Lights": "💡", "Placed models": "🧱", "Solar arrays (OSM)": "☀", "Ponds": "💧",
	"Scene devices": "🔌", "Scene energy sources": "🌬",
}


## Every untracked world object, grouped. `view` is the SystemGraphView.
static func collect(view: Node) -> Array:
	var rows: Array = []
	if view == null:
		return rows
	var main: Node = view.call("_get_scene_main_node") if view.has_method("_get_scene_main_node") else null
	if main == null:
		return rows
	_lights(view, main, rows)
	_props(view, main, rows)
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null:
		_osm_solar(loader, rows)
		_ponds(view, loader, rows)
	_scene_devices(view, rows)
	return rows


## Rows grouped in GROUP_ORDER: [{label, icon, rows: [...]}], empty groups left out.
static func grouped(rows: Array) -> Array:
	var by := {}
	for r in rows:
		var g := str((r as Dictionary).get("group", ""))
		if not by.has(g):
			by[g] = []
		(by[g] as Array).append(r)
	var out: Array = []
	for g in GROUP_ORDER:
		if by.has(g):
			out.append({"label": g, "icon": str(GROUP_ICONS.get(g, "•")), "rows": by[g]})
	for g in by.keys():
		if not (g in GROUP_ORDER):
			out.append({"label": g, "icon": "•", "rows": by[g]})
	return out


static func _lights(view: Node, main: Node, rows: Array) -> void:
	var layer := PlacedLightService.get_layer(main)
	if layer == null:
		return
	for rec in layer.lights:
		var r: Dictionary = rec
		var id := str(r.get("id", ""))
		var gid := str(r.get("graph_item_id", ""))
		if not gid.is_empty() and view.has_method("placed_light_item_id") \
				and not str(view.call("placed_light_item_id", id)).is_empty():
			continue
		var nm := str(r.get("name", ""))
		if nm.is_empty():
			nm = layer.style_display_name(str(r.get("style_id", "")))
		var kind := str(r.get("kind", "light"))
		rows.append({"group": "Lights", "id": "light:" + id, "name": nm if not nm.is_empty() else kind.capitalize(),
			"sub": kind.replace("_", " "), "pos": layer.position_of(r),
			"add": func() -> bool: return PlacedLightService.add_to_graph(main, id)})


## Model id -> the library preset that places it (first preset whose specs
## name that model). That preset's specs are what "Place model" would have
## put on the node, so adding an untracked prop matches placing it fresh.
static func _model_presets() -> Dictionary:
	var out := {}
	for cat in ComponentPresets.CATEGORIES:
		for p in ComponentPresets.presets_for_category(str((cat as Dictionary).get("id", ""))):
			if not (p is Dictionary):
				continue
			var mid := str(((p as Dictionary).get("specs", {}) as Dictionary).get("model_id", ""))
			if not mid.is_empty() and not out.has(mid):
				out[mid] = p
	return out


static func _props(view: Node, main: Node, rows: Array) -> void:
	var recs: Array = []
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null and loader.has_method("placed_prop_records"):
		recs = loader.call("placed_prop_records")
	if recs.is_empty():
		return
	var presets := _model_presets()
	for rec in recs:
		var r: Dictionary = rec
		var pid := str(r.get("id", ""))
		var mid := str(r.get("model_id", ""))
		if pid.is_empty() or mid.is_empty():
			continue
		if view.has_method("find_item_by_bound_prop_id") \
				and not str(view.call("find_item_by_bound_prop_id", pid)).is_empty():
			continue
		var pos := Vector3(float(r.get("x", 0.0)), float(r.get("y", 0.0)), float(r.get("z", 0.0)))
		var nm := str(ModelCatalog.find(mid).get("label", mid.capitalize()))
		var add := Callable()
		if mid == PvArrayBuilder.MODEL_ID and view.has_method("bind_pv_array_prop"):
			add = func() -> bool: return not str(view.call("bind_pv_array_prop", pid)).is_empty()
		elif mid == LinkageStructureBuilder.MODEL_ID:
			add = func() -> bool:
				PlacedPropService.seed_linkage_graph(main, pid)
				return true
		elif mid == ToroidLabBuilder.MODEL_ID:
			add = func() -> bool:
				return PlacedPropService.seed_toroid_graph(main, pid)
		elif presets.has(mid) and view.has_method("create_bound_generator_node"):
			var p: Dictionary = presets[mid]
			var specs: Dictionary = (p.get("specs", {}) as Dictionary).duplicate(true)
			var link := {"node_type": str(p.get("type", "")), "label": str(p.get("label", nm)),
				"icon": str(p.get("icon", "")), "width": float(p.get("width", 140.0)),
				"height": float(p.get("height", 104.0)), "specs": specs}
			nm = str(p.get("label", nm))
			add = func() -> bool:
				var gid := str(view.call("create_bound_generator_node", pid, link))
				if not gid.is_empty():
					PlacedPropService.update_prop_record(main, pid, {"graph_item_id": gid})
				return not gid.is_empty()
		if not add.is_valid():
			continue
		rows.append({"group": "Placed models", "id": "prop:" + pid, "name": nm, "sub": mid,
			"pos": pos, "add": add})


static func _osm_solar(loader: Node, rows: Array) -> void:
	if not loader.has_method("list_soi_solar_arrays_pending"):
		return
	for e in loader.call("list_soi_solar_arrays_pending"):
		var d: Dictionary = e
		var idx := int(d.get("idx", -1))
		var c: Vector2 = d.get("centroid", Vector2.ZERO)
		rows.append({"group": "Solar arrays (OSM)", "id": "osm_solar:%d" % idx,
			"name": "OSM solar array", "sub": UiText.count(int(d.get("panel_count", 0)), "panel"),
			"pos": Vector3(c.x, 0.0, c.y),
			"add": func() -> bool: return bool(loader.call("add_solar_array_to_graph", idx))})


static func _ponds(view: Node, loader: Node, rows: Array) -> void:
	var water: Variant = loader.get("_water_data")
	if not (water is Array):
		return
	var soi := loader.get_node_or_null("/root/SoiService")
	for i in (water as Array).size():
		var rec: Variant = (water as Array)[i]
		if not (rec is Dictionary):
			continue
		var r: Dictionary = rec
		var kind := str(r.get("kind", "water"))
		if kind in WaterBuilder.FLOWING_KINDS:
			continue
		var poly: PackedVector2Array = r.get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		var c := SolarArrayBuilder.centroid(poly)
		if soi != null and soi.has_method("contains_xz") and not bool(soi.call("contains_xz", c.x, c.y)):
			continue
		var tag := str(r.get("tag", ""))
		var pond_id := str(r.get("pond_id", ""))
		if (not tag.is_empty() or not pond_id.is_empty()) and view.has_method("has_pond_with_tag") \
				and bool(view.call("has_pond_with_tag", tag, pond_id)):
			continue
		var nm := str(r.get("label", ""))
		if nm.is_empty():
			nm = "Sculpted pond" if bool(r.get("user", false)) else kind.capitalize()
		var area := BuildingBuilder.footprint_area_m2(poly)
		var idx := i
		rows.append({"group": "Ponds", "id": "pond:%d" % i, "name": nm,
			"sub": "%s m²" % UiText.thousands(roundi(area)), "pos": Vector3(c.x, 0.0, c.y),
			"add": func() -> bool: return bool(loader.call("add_pond_to_graph", idx))})


static func _scene_devices(view: Node, rows: Array) -> void:
	if view.has_method("_world_inventory_scene_presets"):
		for e in view.call("_world_inventory_scene_presets"):
			rows.append(e)
