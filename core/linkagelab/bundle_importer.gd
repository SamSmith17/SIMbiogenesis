class_name BundleImporter
extends RefCounted

## Orchestrate LinkageLab game bundle import into the Godot simulator.

const DesignBundleScript := preload("res://core/linkagelab/design_bundle.gd")
const GlbDecoderScript := preload("res://core/linkagelab/glb_decoder.gd")
const CircuitMapperScript := preload("res://core/linkagelab/circuit_mapper.gd")
const IBCGlowScript := preload("res://ibc_glow.gd")
const PLACED_PROP_SERVICE_SCRIPT := preload("res://core/placed_models/placed_prop_service.gd")

const BUNDLE_FILTER := "*.gamebundle.json ; LinkageLab Game Bundle,*.json ; JSON"


static func prepare_bundle(path: String) -> Dictionary:
	var loaded: Dictionary = DesignBundleScript.load_from_path(path)
	if not bool(loaded.get("ok", false)):
		return loaded
	var bundle: Dictionary = loaded.get("bundle", {}) as Dictionary
	var label := str(loaded.get("name", "StarShade"))
	var catalog_entry: Dictionary = GlbDecoderScript.register_from_bundle(
		loaded.get("model", {}) as Dictionary, label)
	if catalog_entry.is_empty():
		return {"ok": false, "error": "Failed to register embedded GLB"}
	var graph_state: Dictionary = CircuitMapperScript.to_graph_save_state(
		loaded.get("circuit", {}) as Dictionary)
	return {
		"ok": true,
		"bundle": bundle,
		"name": label,
		"model_id": str(catalog_entry.get("id", "")),
		"graph_save_state": graph_state,
		"solar": DesignBundleScript.solar_from_bundle(bundle),
		"ibc": DesignBundleScript.ibc_from_bundle(bundle),
		"location": DesignBundleScript.location_from_bundle(bundle),
		"path": path,
	}


static func queue_for_new_map(path: String, lat: float, lon: float, label: String) -> Dictionary:
	var prep := prepare_bundle(path)
	if not bool(prep.get("ok", false)):
		return prep
	var ctx := _design_context()
	if ctx == null:
		return {"ok": false, "error": "DesignContext autoload missing"}
	ctx.call("set_pending",
		str(prep.get("model_id", "")),
		prep.get("graph_save_state", {}),
		prep.get("solar", {}),
		prep.get("ibc", {}),
		str(prep.get("name", "")),
		path)
	var map_ctx := _map_context()
	if map_ctx != null:
		map_ctx.call("set_pending", lat, lon, label, 0.0, false)
	return prep


static func apply_to_scene(tree: SceneTree, prep: Dictionary) -> Dictionary:
	if tree == null:
		return {"ok": false, "error": "No scene tree"}
	if not bool(prep.get("ok", false)):
		return prep
	var main := _find_main(tree)
	if main == null:
		return {"ok": false, "error": "Main scene node not found"}

	var model_id := str(prep.get("model_id", ""))
	var placed_result: Dictionary = PLACED_PROP_SERVICE_SCRIPT.begin_bundle_placement(
		main, prep, true)
	var placed := bool(placed_result.get("ok", false))

	var graph_applied := _apply_graph(tree, prep.get("graph_save_state", {}) as Dictionary)
	var solar_applied := _apply_solar(tree, prep.get("solar", {}) as Dictionary)
	var ibc_attached := false

	_start_placement_ui(tree, placed_result)
	if ModelCatalog.is_starshade_model(model_id):
		PLACED_PROP_SERVICE_SCRIPT.seed_starshade_graph(main, prep)

	return {
		"ok": true,
		"placed": placed,
		"placement_active": bool(placed_result.get("placement_active", false)),
		"prop_id": str(placed_result.get("prop_id", "")),
		"graph_applied": graph_applied,
		"solar_applied": solar_applied,
		"ibc_attached": ibc_attached,
		"model_id": model_id,
	}


static func apply_bundle_file(tree: SceneTree, path: String) -> Dictionary:
	var prep := prepare_bundle(path)
	if not bool(prep.get("ok", false)):
		return prep
	return apply_to_scene(tree, prep)


static func attach_ibc_to_imported_canopy(tree: SceneTree, model_id: String,
		ibc_info: Dictionary) -> bool:
	if tree == null or model_id.is_empty():
		return false
	if not bool(ibc_info.get("present", false)):
		return false
	var mesh_names: PackedStringArray = PackedStringArray()
	for n in ibc_info.get("meshNames", []) as Array:
		mesh_names.append(str(n))
	if mesh_names.is_empty():
		mesh_names = PackedStringArray(["IBC_Tank_0", "IBC_Tank_1"])
	var wattage := float(ibc_info.get("wattage", 20.0))
	var main := _find_main(tree)
	if main == null:
		return false
	var terrain := main.get_node_or_null("Terrain/PlacedProps")
	if terrain == null:
		terrain = main.find_child("PlacedProps", true, false)
	if terrain == null:
		return false
	for child in terrain.get_children():
		if not (child is PlacedProp):
			continue
		var prop := child as PlacedProp
		if prop.model_id != model_id:
			continue
		var model_root := prop.get_node_or_null("ModelRoot")
		if model_root == null:
			continue
		if model_root.get_node_or_null("IBCGlow") != null:
			return true
		var glow: Node = IBCGlowScript.new()
		glow.name = "IBCGlow"
		if glow.get("target_mesh_names") != null:
			glow.set("target_mesh_names", mesh_names)
		if glow.get("wattage") != null:
			glow.set("wattage", wattage)
		if glow.get("display_name") != null:
			glow.set("display_name", "IBC Glow")
		model_root.add_child(glow)
		return true
	return false


static func _apply_graph(tree: SceneTree, graph_state: Dictionary) -> bool:
	if graph_state.is_empty():
		return false
	# CircuitMapper.to_graph_save_state ALWAYS returns a populated wrapper (even
	# for a StarShade bundle whose circuit.items is empty). Applying that empty
	# graph would deserialize an items=[] payload — wiping the map's existing
	# graph, including the fundamental PBI nodes — before the seeder runs. Skip
	# when the bundle carries no actual circuit items; seeding adds the panels.
	var graph_d: Dictionary = graph_state.get("graph", {}) as Dictionary
	var graph_items: Array = graph_d.get("items", []) as Array
	if graph_items.is_empty():
		return false
	var sgv := tree.root.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("apply_save_state"):
		return false
	var opts := {}
	if sgv.has_method("has_user_graph_layout") and bool(sgv.call("has_user_graph_layout")):
		opts["preserve_positions"] = true
	sgv.call("apply_save_state", graph_state, opts)
	return true


static func _apply_solar(tree: SceneTree, solar: Dictionary) -> bool:
	if solar.is_empty():
		return false
	var solar_ui := tree.root.find_child("SolarUI", true, false)
	if solar_ui == null or not solar_ui.has_method("apply_imported_solar"):
		return false
	solar_ui.call("apply_imported_solar",
		int(solar.get("panelCount", 0)),
		float(solar.get("panelWatts", 0.0)),
		float(solar.get("tiltDeg", 0.0)),
		float(solar.get("azimuthDeg", 180.0)),
		float(solar.get("batteryKwh", -1.0)))
	return true


static func _start_placement_ui(tree: SceneTree, result: Dictionary) -> void:
	if not bool(result.get("placement_active", false)):
		return
	var main := _find_main(tree)
	if main == null:
		return
	var ui_layer := main.get_node_or_null("UILayer")
	if ui_layer == null:
		return
	var props_ui := ui_layer.get_node_or_null("PlacedPropsUI")
	if props_ui == null:
		props_ui = Control.new()
		props_ui.name = "PlacedPropsUI"
		UiScreenLayout.pin_fullscreen(props_ui)
		var script := load("res://scenes/ui/placed_props_ui.gd") as Script
		if script != null:
			props_ui.set_script(script)
		ui_layer.add_child(props_ui)
	if props_ui.has_method("notify_bundle_imported"):
		props_ui.call("notify_bundle_imported", result)


static func _find_main(tree: SceneTree) -> Node:
	for child in tree.root.get_children():
		if child != null and ("day_time" in child) and ("sun" in child):
			return child
	return null


static func _design_context() -> Node:
	if Engine.has_singleton("DesignContext"):
		return Engine.get_singleton("DesignContext") as Node
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		return (tree as SceneTree).root.get_node_or_null("DesignContext")
	return null


static func _map_context() -> Node:
	if Engine.has_singleton("MapContext"):
		return Engine.get_singleton("MapContext") as Node
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		return (tree as SceneTree).root.get_node_or_null("MapContext")
	return null
