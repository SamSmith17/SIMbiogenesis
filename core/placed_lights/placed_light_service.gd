class_name PlacedLightService
extends RefCounted

## Handles the ghost placement state machine for lights.

static var _layer_cache: PlacedLightLayer = null
static var _scene_key: String = ""

static var _placement_active := false
static var _placement_main: Node = null
static var _placement_type := "omni"

static var _ghost_node: Node3D = null

static func get_layer(main: Node) -> PlacedLightLayer:
	if main == null: return null
	var terrain = main.get_node_or_null("Terrain")
	if terrain == null:
		terrain = main.find_child("Terrain", true, false)
	if terrain == null: return null
	var key = main.scene_file_path
	if _layer_cache != null and _scene_key == key:
		return _layer_cache
	
	_layer_cache = PlacedLightLayer.create_empty()
	_scene_key = key
	if _layer_cache.load_for_scene(key):
		pass
	return _layer_cache

static func save_layer(main: Node) -> void:
	if _layer_cache != null and not _scene_key.is_empty():
		_layer_cache.save_for_scene(_scene_key)

static func is_placement_active() -> bool:
	if _placement_active and not is_instance_valid(_placement_main):
		cancel_placement()
	return _placement_active

static func begin_placement(main: Node, type: String = "omni") -> void:
	if main == null: return
	cancel_placement()
	_placement_main = main
	_placement_active = true
	_placement_type = type
	
	_ghost_node = Node3D.new()
	var mesh = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	mesh.mesh = sphere
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 1.0, 0.0, 0.6)
	mesh.material_override = mat
	_ghost_node.add_child(mesh)
	
	main.add_child(_ghost_node)

static func process_placement() -> void:
	if not _placement_active or _placement_main == null or _ghost_node == null:
		return
	var cam = _placement_main.get_viewport().get_camera_3d()
	if cam == null: return
	var space = cam.get_world_3d().direct_space_state
	var center = _placement_main.get_viewport().get_visible_rect().size / 2.0
	var from = cam.project_ray_origin(center)
	var dir = cam.project_ray_normal(center)
	var query = PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0, 1)
	var hit = space.intersect_ray(query)
	if hit:
		_ghost_node.global_position = hit.position
	else:
		_ghost_node.global_position = from + dir * 10.0

static func confirm_placement() -> void:
	if not _placement_active or _ghost_node == null: return
	var pos = _ghost_node.global_position
	var layer = get_layer(_placement_main)
	if layer != null:
		var color = Color.WHITE
		var energy = 1.0
		var r = 10.0
		var spot = 45.0
		layer.add_light(_placement_type, pos.x, pos.y, pos.z, 0, 0, 0, color, energy, r, spot)
		save_layer(_placement_main)
		var terrain = _placement_main.get_node_or_null("Terrain")
		if terrain == null:
			terrain = _placement_main.find_child("Terrain", true, false)
		if terrain != null:
			PlacedLightRuntime.rebuild(terrain, layer)
	cancel_placement()

static func cancel_placement() -> void:
	_placement_active = false
	if _ghost_node != null:
		_ghost_node.queue_free()
		_ghost_node = null
	_placement_main = null
