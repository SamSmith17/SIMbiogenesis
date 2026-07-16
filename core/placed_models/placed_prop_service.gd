class_name PlacedPropService
extends RefCounted

## Place imported / user GLB props on any map (TerrainLoader or baked terrain).

const BUNDLE_IMPORTER_SCRIPT := preload("res://core/linkagelab/bundle_importer.gd")
const PLACEMENT_RAY_LEN := 800.0

const GHOST_VALID_COLOR := Color(0.25, 1.0, 0.45, 0.45)
const GHOST_INVALID_COLOR := Color(1.0, 0.3, 0.2, 0.45)

static var _scene_layers: Dictionary = {}
static var _placement_active := false
static var _placement_prop_id := ""
static var _placement_main: Node = null
static var _placement_prep: Dictionary = {}

# Ghost preview state (transient, never persisted, never collides).
static var _ghost_node: Node3D = null
static var _ghost_model_id := ""
static var _ghost_valid := false
static var _ghost_ground_y := 0.0


static func is_placement_active() -> bool:
	# Self-heal stale cross-scene state. Placement lives in static vars that survive
	# change_scene_to_file, so importing a bundle and then loading a save / switching
	# maps without confirming would leave _placement_active = true pointing at a freed
	# scene. A freshly loaded Player must never inherit that phantom "placing" state —
	# it would otherwise suppress its normal physics grounding and drop it through the
	# world. If the owning scene is gone, the placement is not real: clear it.
	if _placement_active and not is_instance_valid(_placement_main):
		_clear_placement()
	return _placement_active


static func placement_prop_id() -> String:
	return _placement_prop_id


static func place_model(main: Node, model_id: String, near_player: bool = true,
		offset_xz: Vector2 = Vector2.ZERO) -> Dictionary:
	if main == null or model_id.is_empty():
		return {"ok": false, "error": "Missing main or model_id"}
	var xz := TerrainSurfaceQuery.placement_xz(main, near_player, offset_xz)
	var gy := TerrainSurfaceQuery.ground_height_at(main, xz.x, xz.y)
	var layer := _layer_for_main(main)
	if layer == null:
		return {"ok": false, "error": "Could not resolve placed-prop layer"}
	var prop_id := layer.add_free_prop(model_id, xz.x, NAN, xz.y, 0.0, 0.0, 0.0, 1.0, gy)
	if prop_id.is_empty():
		return {"ok": false, "error": "Failed to add prop record"}
	_save_layer(main, layer)
	_rebuild_scene_props(main, layer)
	if ModelCatalog.is_starshade_model(model_id):
		_trigger_starshade_graph_seed(main)
	return {"ok": true, "prop_id": prop_id, "x": xz.x, "z": xz.y, "ground_y": gy}


static func place_model_at_hit(main: Node, model_id: String, hit: Dictionary) -> Dictionary:
	if hit.is_empty():
		return {"ok": false, "error": "No terrain hit"}
	var pos: Vector3 = hit["position"] as Vector3
	return place_model(main, model_id, false, Vector2(pos.x, pos.z))


## Place a model at an absolute world XZ (grounds Y via TerrainSurfaceQuery).
## Optionally stamps graph_item_id / bound link extras onto the record.
static func place_model_at_xz(main: Node, model_id: String, x: float, z: float,
		extra: Dictionary = {}) -> Dictionary:
	if main == null or model_id.is_empty():
		return {"ok": false, "error": "Missing main or model_id"}
	var gy := TerrainSurfaceQuery.ground_height_at(main, x, z)
	var layer := _layer_for_main(main)
	if layer == null:
		return {"ok": false, "error": "Could not resolve placed-prop layer"}
	var prop_id := layer.add_free_prop(model_id, x, NAN, z, 0.0, 0.0, 0.0, 1.0, gy)
	if prop_id.is_empty():
		return {"ok": false, "error": "Failed to add prop record"}
	if not extra.is_empty():
		layer.update_prop(prop_id, extra.duplicate(true))
	_save_layer(main, layer)
	_rebuild_scene_props(main, layer)
	if ModelCatalog.is_starshade_model(model_id):
		_trigger_starshade_graph_seed(main)
	return {"ok": true, "prop_id": prop_id, "x": x, "z": z, "ground_y": gy}


## Move an existing prop to a new world XZ and reground.
static func move_prop_xz(main: Node, prop_id: String, x: float, z: float) -> bool:
	if main == null or prop_id.is_empty():
		return false
	var layer := _layer_for_main(main)
	if layer == null:
		return false
	var gy := TerrainSurfaceQuery.ground_height_at(main, x, z)
	if not layer.update_prop(prop_id, {"x": x, "z": z, "ground_y": gy}):
		return false
	_save_layer(main, layer)
	_rebuild_scene_props(main, layer)
	return true


static func begin_bundle_placement(main: Node, prep: Dictionary,
		near_player: bool = true) -> Dictionary:
	if main == null or not bool(prep.get("ok", false)):
		return prep if prep.has("ok") else {"ok": false, "error": "Invalid prep"}
	var model_id := str(prep.get("model_id", ""))
	var r := begin_placement(main, model_id, prep)
	r["model_id"] = model_id
	r["ibc_attached"] = false
	return r


## Start an interactive ghost-preview placement. A translucent, NON-colliding,
## NON-persisted copy of the model follows the crosshair every frame; nothing is
## written to the layer and the player is never moved. confirm_placement() commits
## the real prop at the ghost's resting spot; cancel_placement() just discards it.
static func begin_placement(main: Node, model_id: String, prep: Dictionary = {}) -> Dictionary:
	if main == null or model_id.is_empty():
		return {"ok": false, "error": "Missing main or model_id"}
	# Tear down any prior placement (e.g. re-entering before confirming).
	_clear_placement()
	# Owning scene set BEFORE the active flag (see is_placement_active guard).
	_placement_main = main
	_placement_active = true
	_placement_prep = prep.duplicate(true)
	_placement_prop_id = ""
	_ghost_model_id = model_id
	_ghost_valid = false
	var ghost := _build_ghost(main, model_id)
	if ghost == null:
		_clear_placement()
		return {"ok": false, "error": "Could not build placement ghost"}
	_ghost_node = ghost
	# Seed the ghost at the current crosshair aim so it appears immediately.
	var cam := _player_camera(main)
	if cam != null:
		update_placement_aim(main, cam)
	return {
		"ok": true,
		"placed": true,
		"placement_active": true,
		"prop_id": "",
		"model_id": model_id,
	}


static func placement_is_valid() -> bool:
	return _placement_active and _ghost_valid


static func update_placement_aim(main: Node, camera: Camera3D) -> void:
	if not _placement_active or main == null or camera == null:
		return
	if not is_instance_valid(_ghost_node):
		return
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(main, camera)
	if hit.is_empty():
		# No terrain under the crosshair — hide the ghost as clear "can't place" feedback.
		_ghost_valid = false
		_ghost_node.visible = false
		return
	var pos: Vector3 = hit["position"] as Vector3
	# Single source of truth for footing (Phase 4): rest the ghost foot on the
	# ray-hit Y directly — no second ground_height_at query that could disagree.
	var foot_y := ModelCatalog.foot_local_y(_ghost_model_id)
	var ws := ModelCatalog.resolved_scale(_ghost_model_id, 1.0)
	_ghost_node.global_position = Vector3(pos.x, pos.y - foot_y * ws, pos.z)
	_ghost_ground_y = pos.y
	_ghost_valid = true
	_ghost_node.visible = true
	_set_ghost_tint(true)


static func confirm_placement() -> bool:
	if not _placement_active or not is_instance_valid(_placement_main):
		_clear_placement()
		return false
	# Invalid aim (no terrain under crosshair): don't place — let the user keep aiming.
	if not _ghost_valid or not is_instance_valid(_ghost_node):
		return false
	var main := _placement_main
	var model_id := _ghost_model_id
	var gpos := _ghost_node.global_position
	var layer := _layer_for_main(main)
	if layer == null:
		_clear_placement()
		return false
	# Commit exactly one record at the ghost's resting spot, grounded on the ray-hit
	# Y, then spawn just that one real (colliding) prop — no full scene rebuild.
	var prop_id := layer.add_free_prop(model_id, gpos.x, NAN, gpos.z, 0.0, 0.0, 0.0, 1.0, _ghost_ground_y)
	if prop_id.is_empty():
		_clear_placement()
		return false
	_placement_prop_id = prop_id
	# Merge any placement-time record extras (e.g. VAWT spin binding: kind /
	# turbine_node / wind_specs) BEFORE the prop node is built so the runtime can
	# attach the spin controller as it spawns.
	var record_extra := _placement_prep.get("record_extra", {}) as Dictionary
	if not record_extra.is_empty():
		layer.update_prop(prop_id, record_extra.duplicate(true))
	# Create + bind the 2D graph node for a linked generator (VAWT), stamping the
	# resulting item id back onto the record so save/reload keeps the link.
	var graph_link := _placement_prep.get("graph_link", {}) as Dictionary
	if not graph_link.is_empty():
		var node_id := _create_bound_graph_node(main, prop_id, graph_link)
		if not node_id.is_empty():
			layer.update_prop(prop_id, {"graph_item_id": node_id})
	_save_layer(main, layer)
	var rec := layer.find_by_id(prop_id)
	var parent := _props_parent(main)
	var gy_fn := TerrainSurfaceQuery.ground_y_callable(main)
	var ibc := _placement_prep.get("ibc", {}) as Dictionary
	var seed_prep := _placement_prep.duplicate(true)
	# Clear the placement state BEFORE spawning the real node. _build_prop() checks
	# is_placement_active()/placement_prop_id() to keep an IN-FLIGHT ghost's real
	# record non-colliding, but by this point the placement is already committed —
	# leaving the flags set here made the just-placed prop spawn with collision
	# (and crosshair focus, which requires a physics hit) disabled until some
	# unrelated later rebuild happened to reconstruct it.
	_clear_placement()
	var prop := PlacedPropRuntime.add_one(parent, rec, gy_fn)
	if prop != null and not ibc.is_empty() and main.get_tree() != null:
		BUNDLE_IMPORTER_SCRIPT.attach_ibc_to_imported_canopy(
			main.get_tree(), model_id, ibc)
	if ModelCatalog.is_starshade_model(model_id):
		_trigger_starshade_graph_seed(main, seed_prep)
	return true


## Ask the SystemGraphView to create a 2D node bound to a just-placed 3D prop
## (e.g. the VAWT). Returns the new node's item id, or "" if the graph is absent.
static func _create_bound_graph_node(main: Node, prop_id: String,
		graph_link: Dictionary) -> String:
	if main == null or graph_link.is_empty():
		return ""
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("create_bound_generator_node"):
		return ""
	return str(sgv.call("create_bound_generator_node", prop_id, graph_link))


static func seed_starshade_graph(main: Node, prep: Dictionary = {}) -> void:
	_trigger_starshade_graph_seed(main, prep)


static func _trigger_starshade_graph_seed(main: Node, prep: Dictionary = {}) -> void:
	if main == null:
		return
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if StarShadeGraphSeeder.try_seed_from_main(main, loader):
		return
	var solar: Dictionary = prep.get("solar", {}) as Dictionary
	var panel_count := int(solar.get("panelCount", 0))
	if panel_count <= 0:
		return
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("seed_starshade_system"):
		return
	var model: GraphModel = sgv.get("model") as GraphModel
	if model == null:
		return
	if bool(sgv.call("seed_starshade_system",
			panel_count, float(solar.get("panelWatts", 220.0)), "linkagelab_import")):
		if sgv.has_method("_sync_solar_ui_from_graph"):
			sgv.call("_sync_solar_ui_from_graph")
		if sgv.has_method("_schedule_graph_autosave"):
			sgv.call("_schedule_graph_autosave")


static func cancel_placement() -> void:
	# Ghost-based: nothing was ever written to the layer, so just discard it.
	_clear_placement()


# ==================== GHOST PREVIEW ====================

static func _build_ghost(main: Node, model_id: String) -> Node3D:
	var parent := _props_parent(main)
	if parent == null:
		return null
	var existing := parent.get_node_or_null("PlacementGhost")
	if existing != null:
		existing.free()
	var model := ModelCatalog.instantiate(model_id)
	if model == null:
		return null
	var ghost := Node3D.new()
	ghost.name = "PlacementGhost"
	parent.add_child(ghost)
	ghost.add_child(model)
	model.name = "GhostModel"
	ghost.scale = Vector3.ONE * ModelCatalog.resolved_scale(model_id, 1.0)
	# Some models (e.g. the CSP trough) declare a fixed yaw that aligns their
	# mesh axes to world cardinals; apply it to the ghost too so the preview
	# already shows the same orientation PlacedPropRuntime will force on
	# confirm — otherwise the model visibly snaps/rotates the instant it's placed.
	var forced_yaw := ModelCatalog.forced_yaw_deg(model_id)
	if absf(forced_yaw) > 0.0001:
		model.rotation.y = deg_to_rad(forced_yaw)
	_disable_node_physics(model)
	_apply_ghost_tint_to(ghost, GHOST_VALID_COLOR)
	ghost.visible = false
	return ghost


static func _set_ghost_tint(valid: bool) -> void:
	if not is_instance_valid(_ghost_node):
		return
	_apply_ghost_tint_to(_ghost_node, GHOST_VALID_COLOR if valid else GHOST_INVALID_COLOR)


static func _apply_ghost_tint_to(ghost: Node3D, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for node in ghost.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_override = mat


static func _disable_node_physics(model: Node3D) -> void:
	for node in model.find_children("*", "CollisionObject3D", true, false):
		var co := node as CollisionObject3D
		co.collision_layer = 0
		co.collision_mask = 0


static func _destroy_ghost() -> void:
	if is_instance_valid(_ghost_node):
		_ghost_node.queue_free()
	_ghost_node = null
	_ghost_model_id = ""
	_ghost_valid = false
	_ghost_ground_y = 0.0


static func _player_camera(main: Node) -> Camera3D:
	if main == null:
		return null
	var player := main.get_node_or_null("Player")
	if player == null:
		return null
	return player.get_node_or_null("CameraArm/Camera3D") as Camera3D


static func _clear_placement() -> void:
	_destroy_ghost()
	_placement_active = false
	_placement_prop_id = ""
	_placement_main = null
	_placement_prep = {}


static func _layer_for_main(main: Node) -> PlacedPropLayer:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and loader.get("_placed_prop_layer") != null:
		return loader.get("_placed_prop_layer") as PlacedPropLayer
	var key := _layer_key(main)
	if _scene_layers.has(key):
		return _scene_layers[key] as PlacedPropLayer
	var layer := PlacedPropLayer.create_empty()
	layer.load_for_scene(key)
	_scene_layers[key] = layer
	return layer


static func _save_layer(main: Node, layer: PlacedPropLayer) -> void:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null and "_lat" in loader and "_lon" in loader:
		layer.save(float(loader.get("_lat")), float(loader.get("_lon")))
		return
	layer.save_for_scene(_layer_key(main))


static func _rebuild_scene_props(main: Node, layer: PlacedPropLayer) -> void:
	var parent := _props_parent(main)
	if parent == null:
		return
	var gy_fn := TerrainSurfaceQuery.ground_y_callable(main)
	PlacedPropRuntime.rebuild(parent, layer, gy_fn)


static func _props_parent(main: Node) -> Node3D:
	var terrain := main.get_node_or_null("Terrain") as Node3D
	if terrain != null:
		return terrain
	return main as Node3D


static func _layer_key(main: Node) -> String:
	if main == null:
		return "unknown"
	return main.scene_file_path if not main.scene_file_path.is_empty() else main.name
