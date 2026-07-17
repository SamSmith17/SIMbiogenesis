class_name PlacedProp
extends Interactable

## User-placed GLB prop — grabbable, editable, crosshair focus.

var prop_id: String = ""
var model_id: String = ""
var is_osm_replacement: bool = false
var building_idx: int = -1
## When true, ModelRoot meshes are valid fire-crisis ignition / spread targets.
var burnable: bool = false
## True after at least one mesh was burned out (hidden); enables Restore in edit UI.
var was_burned: bool = false

var _outline_mesh: MeshInstance3D = null
var _outline_mat: StandardMaterial3D = null
var _graph_outline_mat: StandardMaterial3D = null
var _graph_highlight := false
var _body: StaticBody3D = null
## Prop-local AABB of the scaled model (for software pick fallback).
var _pick_aabb_local: AABB = AABB()


func _ready() -> void:
	super._ready()
	prompt = "Edit prop (click) / Grab (hold)"
	max_distance = 12.0
	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.albedo_color = Color(0.05, 0.45, 0.12, 0.85)
	_outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	_graph_outline_mat = StandardMaterial3D.new()
	_graph_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_graph_outline_mat.albedo_color = Color(0.1, 0.82, 0.95, 0.9)
	_graph_outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT


func set_collision_enabled(enabled: bool) -> void:
	if _body == null and enabled:
		setup_collision()
	if _body != null:
		_body.collision_layer = 1 if enabled else 0
		_body.collision_mask = 1 if enabled else 0


## Mark (or clear) mesh meta so FireEvent / FireNode can treat this as burnable.
func set_burnable(enabled: bool) -> void:
	burnable = enabled
	var model := get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null:
			continue
		if enabled:
			mi.set_meta("prop_burnable", true)
		elif mi.has_meta("prop_burnable"):
			mi.remove_meta("prop_burnable")


func mark_burned() -> void:
	was_burned = true


func clear_burned_flag() -> void:
	was_burned = false


## Restore meshes hidden/charred by fire without rebuilding the whole prop.
func restore_after_burn() -> int:
	return FireNode.regenerate_meshes_under(self)


func has_burned_geometry() -> bool:
	if was_burned:
		return true
	var model := get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return false
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi != null and mi.has_meta("fire_burned") and bool(mi.get_meta("fire_burned")):
			return true
	return false


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
	# Bake ModelRoot scale/rotation into shape vertices. ConcavePolygonShape3D
	# must not be non-uniformly scaled via CollisionShape3D.transform — that is
	# what made heavily scaled replacements (e.g. Man Effigy) miss Alt/Ctrl rays.
	var added := false
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := model.transform * _transform_relative_to(model, mi)
		var faces := mi.mesh.get_faces()
		if faces.is_empty():
			continue
		var baked := PackedVector3Array()
		baked.resize(faces.size())
		for i in faces.size():
			baked[i] = xf * faces[i]
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(baked)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		added = true
	_pick_aabb_local = _mesh_aabb_prop_local(model)
	# Inflated AABB proxy so aiming at the visual bulk (not just thin mesh faces)
	# still selects the prop after large scale changes.
	_setup_pick_proxy(body, _pick_aabb_local)
	if not added and _pick_aabb_local.size.length_squared() > 0.0001:
		_setup_box_collision(body, _pick_aabb_local)
	_body = body


## Coarse fallback collider when no trimesh could be built.
func _setup_box_collision(body: StaticBody3D, aabb: AABB) -> void:
	if aabb.size.length_squared() < 0.0001:
		return
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(
		maxf(aabb.size.x, 0.1),
		maxf(aabb.size.y, 0.1),
		maxf(aabb.size.z, 0.1))
	shape.shape = box
	shape.position = aabb.get_center()
	body.add_child(shape)


func _setup_pick_proxy(body: StaticBody3D, aabb: AABB) -> void:
	if aabb.size.length_squared() < 0.0001:
		return
	# Slight inflate so silhouette edges stay pickable.
	var pad := maxf(aabb.get_longest_axis_size() * 0.04, 0.35)
	var expanded := aabb.grow(pad)
	var shape := CollisionShape3D.new()
	shape.name = "PickProxy"
	var box := BoxShape3D.new()
	box.size = Vector3(
		maxf(expanded.size.x, 0.2),
		maxf(expanded.size.y, 0.2),
		maxf(expanded.size.z, 0.2))
	shape.shape = box
	shape.position = expanded.get_center()
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
	_apply_outline(_graph_highlight)


func set_graph_highlight(on: bool) -> void:
	_graph_highlight = on
	_apply_outline(on or _focus_active)


func is_grabbable() -> bool:
	return true


## World-space AABB of the scaled model (for software ray pick fallback).
func get_world_pick_aabb() -> AABB:
	if _pick_aabb_local.size.length_squared() < 0.0001:
		var model := get_node_or_null("ModelRoot") as Node3D
		if model != null:
			_pick_aabb_local = _mesh_aabb_prop_local(model)
	if _pick_aabb_local.size.length_squared() < 0.0001:
		return AABB()
	return global_transform * _pick_aabb_local


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
	var foot_y := ModelCatalog.foot_local_y(model_id)
	var world_scale := ModelCatalog.resolved_scale(model_id, scale)
	var grounded_y := gy - foot_y * world_scale
	var y_offset := global_position.y - grounded_y
	return {
		"x": global_position.x,
		"y_offset": y_offset,
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
	# Keep pick AABB in sync during live scale drag (full collision rebuild on Apply).
	_pick_aabb_local = _mesh_aabb_prop_local(model)


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
		var mat := _graph_outline_mat if _graph_highlight else _outline_mat
		_outline_mesh.material_override = mat
		_outline_mesh.scale = Vector3(1.03, 1.03, 1.03)
		_outline_mesh.visible = true
	elif _outline_mesh != null:
		_outline_mesh.visible = false


## Mesh AABB in ModelRoot-local space (unscaled mesh frame).
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


## Mesh AABB in prop-local space (includes ModelRoot scale/rotation).
func _mesh_aabb_prop_local(model: Node3D) -> AABB:
	var aabb := AABB()
	var found := false
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := model.transform * _transform_relative_to(model, mi)
		var local: AABB = xf * mi.mesh.get_aabb()
		if not found:
			aabb = local
			found = true
		else:
			aabb = aabb.merge(local)
	return aabb
