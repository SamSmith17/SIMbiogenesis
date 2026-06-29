class_name PlacedProp
extends Interactable

## User-placed GLB prop — grabbable, editable, crosshair focus.

var prop_id: String = ""
var model_id: String = ""
var is_osm_replacement: bool = false
var building_idx: int = -1

var _outline_mesh: MeshInstance3D = null
var _outline_mat: StandardMaterial3D = null
var _body: StaticBody3D = null


func _ready() -> void:
	super._ready()
	prompt = "Edit prop (click) / Grab (hold)"
	max_distance = 12.0
	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.albedo_color = Color(0.05, 0.45, 0.12, 0.85)
	_outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT


func set_collision_enabled(enabled: bool) -> void:
	if _body == null and enabled:
		setup_collision()
	if _body != null:
		_body.collision_layer = 1 if enabled else 0
		_body.collision_mask = 1 if enabled else 0


func setup_collision() -> void:
	if _body != null:
		_body.queue_free()
		_body = null
	var model := get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return
	var body := StaticBody3D.new()
	body.name = "PropBody"
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	# One concave (trimesh) collider per mesh, placed exactly where the visual mesh
	# sits (including ModelRoot scale). This follows the real geometry, so a player
	# can walk *under* a canopy / between legs instead of being ejected by one giant
	# box spanning the whole AABB. Transforms are composed from local Transform3Ds so
	# this works before the prop is added to the tree.
	var added := false
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var shape := mi.mesh.create_trimesh_shape()
		if shape == null:
			continue
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.transform = model.transform * _transform_relative_to(model, mi)
		body.add_child(cs)
		added = true
	if not added:
		_setup_box_collision(body, model)
	_body = body


## Coarse fallback collider (whole-AABB box) for models with no usable mesh data.
func _setup_box_collision(body: StaticBody3D, model: Node3D) -> void:
	var aabb := _mesh_aabb_local()
	if aabb.size.length_squared() < 0.0001:
		return
	var scl := model.scale
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(
		maxf(aabb.size.x * scl.x, 0.1),
		maxf(aabb.size.y * scl.y, 0.1),
		maxf(aabb.size.z * scl.z, 0.1))
	shape.shape = box
	shape.position = aabb.get_center() * scl
	body.add_child(shape)


## Transform of `descendant` relative to `ancestor`, composed from local transforms
## (no global_transform — valid before the node enters the tree).
func _transform_relative_to(ancestor: Node3D, descendant: Node3D) -> Transform3D:
	var t := descendant.transform
	var p := descendant.get_parent()
	while p != null and p != ancestor and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


func get_focus_mesh() -> MeshInstance3D:
	var model := get_node_or_null("ModelRoot")
	if model == null:
		return super.get_focus_mesh()
	for node in model.find_children("*", "MeshInstance3D", true, false):
		return node as MeshInstance3D
	return super.get_focus_mesh()


func on_focus_enter(player: Node) -> void:
	super.on_focus_enter(player)
	_apply_outline(true)


func on_focus_exit(player: Node) -> void:
	super.on_focus_exit(player)
	_apply_outline(false)


func is_grabbable() -> bool:
	return true


func get_record_patch_from_node(ground_y_at: Callable) -> Dictionary:
	var model := get_node_or_null("ModelRoot") as Node3D
	var yaw_deg := 0.0
	var pitch_deg := 0.0
	var roll_deg := 0.0
	var scale := 1.0
	if model != null:
		yaw_deg = rad_to_deg(model.rotation.y)
		pitch_deg = rad_to_deg(model.rotation.x)
		roll_deg = rad_to_deg(model.rotation.z)
		var model_id_local := model_id
		var ws := model.scale.x
		var base := ModelCatalog.resolved_scale(model_id_local, 1.0)
		if base > 0.0001:
			scale = ws / base
	var gy: float = float(ground_y_at.call(global_position.x, global_position.z))
	return {
		"x": global_position.x,
		"y": global_position.y,
		"z": global_position.z,
		"yaw": yaw_deg,
		"pitch": pitch_deg,
		"roll": roll_deg,
		"scale": scale,
		"ground_y": gy,
	}


func apply_live_transform(pos: Vector3, yaw_deg: float, pitch_deg: float,
		roll_deg: float, user_scale: float) -> void:
	global_position = pos
	var model := get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return
	var ws := ModelCatalog.resolved_scale(model_id, user_scale)
	model.scale = Vector3.ONE * ws
	model.rotation = Vector3(deg_to_rad(pitch_deg), deg_to_rad(yaw_deg), deg_to_rad(roll_deg))


func _apply_outline(on: bool) -> void:
	var mesh := get_focus_mesh()
	if mesh == null:
		return
	if on:
		if _outline_mesh == null:
			_outline_mesh = MeshInstance3D.new()
			_outline_mesh.name = "OutlinePass"
			mesh.add_child(_outline_mesh)
		_outline_mesh.mesh = mesh.mesh
		_outline_mesh.material_override = _outline_mat
		_outline_mesh.scale = Vector3(1.03, 1.03, 1.03)
		_outline_mesh.visible = true
	elif _outline_mesh != null:
		_outline_mesh.visible = false


func _mesh_aabb_local() -> AABB:
	var model := get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return AABB()
	var aabb := AABB()
	var found := false
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var local: AABB = model.transform.affine_inverse() * mi.transform * mi.mesh.get_aabb()
		if not found:
			aabb = local
			found = true
		else:
			aabb = aabb.merge(local)
	return aabb
