class_name EsimImporter
extends RefCounted

## Apply a validated .esim package to the live scene (replace mode) or stage
## a 2D graph ghost overlay (preview mode).

const EsimPackageScript := preload("res://core/esim/esim_package.gd")


static func apply_to_scene(tree: SceneTree, package: Dictionary,
		options: Dictionary = {}) -> Dictionary:
	if tree == null:
		return {"ok": false, "error": "No scene tree"}
	var v := EsimPackageScript.validate(package)
	if not bool(v.get("ok", false)):
		return v
	var main := _find_main(tree)
	if main == null:
		return {"ok": false, "error": "Main scene node not found"}
	var mode := str(options.get("mode", "replace"))
	if mode == "ghost":
		return _apply_ghost(main, package)
	return _apply_replace(main, package, options)


static func apply_file(tree: SceneTree, path: String,
		options: Dictionary = {}) -> Dictionary:
	var loaded := EsimPackageScript.load_from_path(path)
	if not bool(loaded.get("ok", false)):
		return loaded
	return apply_to_scene(tree, loaded.get("package", {}) as Dictionary, options)


static func apply_share_code(tree: SceneTree, code: String,
		options: Dictionary = {}) -> Dictionary:
	var loaded := EsimPackageScript.decode_share_code(code)
	if not bool(loaded.get("ok", false)):
		return loaded
	return apply_to_scene(tree, loaded.get("package", {}) as Dictionary, options)


static func _apply_replace(main: Node, package: Dictionary,
		options: Dictionary) -> Dictionary:
	var warnings: Array = []
	var loc: Dictionary = package.get("location", {}) as Dictionary
	var cur_lat := float(main.get("latitude"))
	var cur_lon := float(main.get("longitude"))
	var mismatch_m := EsimPackageScript.location_mismatch_m(loc, cur_lat, cur_lon)
	if mismatch_m > 50.0:
		warnings.append(
			"Package site is ~%.0f m from this map — props/SoI may not align." % mismatch_m)

	var graph_only := bool(options.get("graph_only", false))
	var layers_applied := false
	if not graph_only:
		var loader := _find_terrain_loader(main)
		if loader != null and loader.has_method("apply_esim_site_layers"):
			var layer_result: Dictionary = loader.call("apply_esim_site_layers", {
				"soi": package.get("soi", {}),
				"placed_props": package.get("placed_props", {}),
				"building_styles": package.get("building_styles", {}),
				"vegetation": package.get("vegetation", {}),
				"vegetation_style": package.get("vegetation_style", {}),
				"auto_veg_edits": package.get("auto_veg_edits", {}),
				"user_water": package.get("user_water", {}),
			}, {"rebuild": true})
			layers_applied = bool(layer_result.get("ok", false))
			if not layers_applied and layer_result.has("error"):
				warnings.append(str(layer_result.get("error")))
		else:
			var soi := _soi_service()
			var soi_blob: Dictionary = package.get("soi", {}) as Dictionary
			if soi != null and not soi_blob.is_empty() and soi.has_method("apply_save_state"):
				soi.call("apply_save_state", soi_blob)

	var graph_applied := false
	var sgv := _find_system_graph_view(main)
	if sgv != null and sgv.has_method("apply_save_state"):
		if sgv.has_method("clear_esim_ghost"):
			sgv.call("clear_esim_ghost")
		var graph_state: Dictionary = EsimPackageScript.strip_esim_ghosts_from_graph_state(
			(package.get("system_graph", {}) as Dictionary).duplicate(true))
		sgv.call("apply_save_state", graph_state)
		graph_applied = true
		if sgv.has_method("_ensure_pbi_nodes"):
			sgv.call("_ensure_pbi_nodes")
		if sgv.has_method("_sync_solar_ui_from_graph"):
			sgv.call("_sync_solar_ui_from_graph")
		if sgv.has_method("_schedule_graph_autosave"):
			sgv.call("_schedule_graph_autosave")

	return {
		"ok": true,
		"mode": "replace",
		"graph_applied": graph_applied,
		"layers_applied": layers_applied,
		"warnings": warnings,
		"summary": EsimPackageScript.summary_of(package),
		"location_mismatch_m": mismatch_m,
	}


static func _apply_ghost(main: Node, package: Dictionary) -> Dictionary:
	var sgv := _find_system_graph_view(main)
	if sgv == null or not sgv.has_method("load_esim_as_ghost"):
		return {"ok": false, "error": "SystemGraphView ghost API missing"}
	var result: Dictionary = sgv.call("load_esim_as_ghost", package)
	if not bool(result.get("ok", false)):
		return result
	var loc: Dictionary = package.get("location", {}) as Dictionary
	var mismatch_m := EsimPackageScript.location_mismatch_m(
		loc, float(main.get("latitude")), float(main.get("longitude")))
	var warnings: Array = result.get("warnings", []) as Array
	if mismatch_m > 50.0:
		warnings.append(
			"Ghost is from a site ~%.0f m away — compare layout only." % mismatch_m)
	result["warnings"] = warnings
	result["location_mismatch_m"] = mismatch_m
	result["mode"] = "ghost"
	return result


static func _find_main(tree: SceneTree) -> Node:
	if tree == null or tree.current_scene == null:
		return null
	var scene := tree.current_scene
	if str(scene.name) == "Main":
		return scene
	var nested := scene.find_child("Main", true, false)
	return nested if nested != null else scene


static func _find_system_graph_view(main: Node) -> Node:
	var n := ServiceLocator.graph()
	if n != null:
		return n
	return main.find_child("SystemGraphView", true, false)


static func _find_terrain_loader(main: Node) -> Node:
	var n := main.get_node_or_null("TerrainLoader")
	if n != null:
		return n
	return main.find_child("TerrainLoader", true, false)


static func _soi_service() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("SoiService")
