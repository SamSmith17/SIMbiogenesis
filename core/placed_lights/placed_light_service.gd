class_name PlacedLightService
extends RefCounted

## Handles the ghost placement state machine for lights + style clipboard.

static var _layer_cache: PlacedLightLayer = null
static var _scene_key: String = ""

static var _placement_active := false
static var _placement_main: Node = null
static var _placement_type := "omni"

static var _ghost_node: Node3D = null
static var _ghost_visible := true

## Last style used for new placements / copy-paste (type, color, energy, …).
static var _style_clipboard: Dictionary = {}


static func get_layer(main: Node) -> PlacedLightLayer:
	if main == null:
		return null
	var terrain = main.get_node_or_null("Terrain")
	if terrain == null:
		terrain = main.find_child("Terrain", true, false)
	if terrain == null:
		return null
	var key = main.scene_file_path
	if _layer_cache != null and _scene_key == key:
		return _layer_cache

	_layer_cache = PlacedLightLayer.create_empty()
	_scene_key = key
	_layer_cache.load_for_scene(key)
	return _layer_cache


static func save_layer(main: Node) -> void:
	if _layer_cache != null and not _scene_key.is_empty():
		_layer_cache.save_for_scene(_scene_key)


static func is_placement_active() -> bool:
	if _placement_active and not is_instance_valid(_placement_main):
		cancel_placement()
	return _placement_active


static func get_placement_type() -> String:
	return _placement_type


static func set_placement_type(type: String) -> void:
	if type == "omni" or type == "spot":
		_placement_type = type


static func begin_placement(main: Node, type: String = "omni") -> void:
	if main == null:
		return
	cancel_placement()
	_placement_main = main
	_placement_active = true
	_placement_type = type if type == "spot" else "omni"
	_ghost_visible = true
	_spawn_ghost(main)


static func _spawn_ghost(main: Node) -> void:
	if _ghost_node != null and is_instance_valid(_ghost_node):
		_ghost_node.queue_free()
		_ghost_node = null
	_ghost_node = Node3D.new()
	_ghost_node.name = "LightPlacementGhost"

	# Inner IK aim sphere (bright, obvious crosshair target).
	var core := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.28
	sphere.height = 0.56
	sphere.radial_segments = 20
	sphere.rings = 12
	core.mesh = sphere
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.92, 0.15, 0.78)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.9, 0.2)
	mat.emission_energy_multiplier = 2.0
	core.material_override = mat
	_ghost_node.add_child(core)

	# Outer halo so the aim point remains readable at longer ranges.
	var halo := MeshInstance3D.new()
	var outer := SphereMesh.new()
	outer.radius = 0.55
	outer.height = 1.1
	outer.radial_segments = 16
	outer.rings = 8
	halo.mesh = outer
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var halo_mat := StandardMaterial3D.new()
	halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	halo_mat.albedo_color = Color(1.0, 0.85, 0.15, 0.22)
	halo_mat.emission_enabled = true
	halo_mat.emission = Color(1.0, 0.85, 0.15)
	halo_mat.emission_energy_multiplier = 0.8
	halo_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	halo.material_override = halo_mat
	_ghost_node.add_child(halo)

	main.add_child(_ghost_node)
	_ghost_node.visible = _ghost_visible


static func set_ghost_visible(on: bool) -> void:
	_ghost_visible = on
	if _ghost_node != null and is_instance_valid(_ghost_node):
		_ghost_node.visible = on


static func process_placement() -> void:
	if not _placement_active or _placement_main == null \
			or _ghost_node == null or not is_instance_valid(_ghost_node):
		return
	if not _ghost_visible:
		return
	var vp := _placement_main.get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		return
	var center := vp.get_visible_rect().size * 0.5
	var from := cam.project_ray_origin(center)
	var dir := cam.project_ray_normal(center)
	# Physics ray first so lights can seat on placed structures (Man Effigy, etc.).
	# Terrain-only pick was preferred before and skipped props → 10 m fallback in front
	# of the camera when aiming at a model.
	var space := cam.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0, 1)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var exclude: Array[RID] = []
	var terrain := _placement_main.get_node_or_null("Terrain")
	if terrain != null:
		var lights_root := terrain.get_node_or_null("PlacedLights")
		if lights_root != null:
			for child in lights_root.get_children():
				if child is PlacedLight:
					var body := (child as Node).get_node_or_null("LightBody")
					if body is CollisionObject3D:
						exclude.append((body as CollisionObject3D).get_rid())
	# Don't stick the ghost to the player capsule.
	var player := _placement_main.get_node_or_null("Player")
	if player is CollisionObject3D:
		exclude.append((player as CollisionObject3D).get_rid())
	elif player != null:
		for n in player.find_children("*", "CollisionObject3D", true, false):
			if n is CollisionObject3D:
				exclude.append((n as CollisionObject3D).get_rid())
	query.exclude = exclude
	var hit := space.intersect_ray(query)
	if hit:
		_ghost_node.global_position = hit.position
		return
	# Fallback: bare terrain (no prop colliders in the way / open sky).
	var loader := _placement_main.get_node_or_null("TerrainLoader")
	if loader == null:
		loader = _placement_main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("terrain_pick_ray"):
		var p: Variant = loader.call("terrain_pick_ray", center)
		if p is Vector3:
			_ghost_node.global_position = p as Vector3
			return
	_ghost_node.global_position = from + dir * 10.0


static func confirm_placement() -> String:
	if not _placement_active or _ghost_node == null or not is_instance_valid(_ghost_node):
		return ""
	var pos := _ghost_node.global_position
	var layer := get_layer(_placement_main)
	if layer == null:
		return ""
	var style := _default_place_style()
	var color_hex := str(style.get("color", "ffffff"))
	if not color_hex.begins_with("#"):
		color_hex = "#" + color_hex
	var id := layer.add_light(
		str(style.get("type", _placement_type)),
		pos.x, pos.y, pos.z, 0.0, 0.0, 0.0,
		Color.html(color_hex),
		float(style.get("energy", 1.0)),
		float(style.get("range", 10.0)),
		float(style.get("spot_angle", 45.0)),
		bool(style.get("shadow_enabled", true)),
		float(style.get("lod_m", 0.0)))
	if id.is_empty():
		return ""
	save_layer(_placement_main)
	var terrain = _placement_main.get_node_or_null("Terrain")
	if terrain == null:
		terrain = _placement_main.find_child("Terrain", true, false)
	var rec := layer.find_light(id)
	if terrain != null:
		PlacedLightRuntime.add_one(terrain as Node3D, rec)
	copy_style_from_record(rec)
	# Stay in place mode for rapid multi-place (J or RMB to exit).
	return id


static func cancel_placement() -> void:
	_placement_active = false
	_ghost_visible = true
	if _ghost_node != null and is_instance_valid(_ghost_node):
		_ghost_node.queue_free()
	_ghost_node = null
	_placement_main = null


static func _default_place_style() -> Dictionary:
	if not _style_clipboard.is_empty():
		var s := _style_clipboard.duplicate()
		s["type"] = _placement_type
		return s
	return {
		"type": _placement_type,
		"color": "ffffff",
		"energy": 1.0,
		"range": 10.0,
		"spot_angle": 45.0,
		"shadow_enabled": true,
		"lod_m": 0.0,
	}


static func copy_style_from_record(rec: Dictionary) -> void:
	if rec.is_empty():
		return
	_style_clipboard = {
		"type": str(rec.get("type", "omni")),
		"color": str(rec.get("color", "ffffff")),
		"energy": float(rec.get("energy", 1.0)),
		"range": float(rec.get("range", 10.0)),
		"spot_angle": float(rec.get("spot_angle", 45.0)),
		"shadow_enabled": bool(rec.get("shadow_enabled", true)),
		"lod_m": float(rec.get("lod_m", 0.0)),
	}


static func copy_style_from_id(main: Node, light_id: String) -> bool:
	var layer := get_layer(main)
	if layer == null:
		return false
	var rec := layer.find_light(light_id)
	if rec.is_empty():
		return false
	copy_style_from_record(rec)
	return true


static func has_style_clipboard() -> bool:
	return not _style_clipboard.is_empty()


static func get_style_clipboard() -> Dictionary:
	return _style_clipboard.duplicate()


static func paste_style_to_id(main: Node, light_id: String) -> bool:
	if _style_clipboard.is_empty() or main == null or light_id.is_empty():
		return false
	var layer := get_layer(main)
	if layer == null:
		return false
	var props := {
		"type": str(_style_clipboard.get("type", "omni")),
		"color": str(_style_clipboard.get("color", "ffffff")),
		"energy": float(_style_clipboard.get("energy", 1.0)),
		"range": float(_style_clipboard.get("range", 10.0)),
		"spot_angle": float(_style_clipboard.get("spot_angle", 45.0)),
		"shadow_enabled": bool(_style_clipboard.get("shadow_enabled", true)),
		"lod_m": float(_style_clipboard.get("lod_m", 0.0)),
	}
	if not layer.update_light(light_id, props):
		return false
	save_layer(main)
	var node := PlacedLightRuntime.find_by_id(main, light_id)
	if node != null:
		PlacedLightRuntime.apply_record_to_light(node, layer.find_light(light_id))
	return true
