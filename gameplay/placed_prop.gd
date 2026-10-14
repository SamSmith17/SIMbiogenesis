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
## Whole-structure cyan bounding-box shown on graph highlight (Site Plan hover/
## select). The single-mesh outline only marks one member of a multi-mesh prop
## (e.g. a pallet rack), so this box makes the entire structure read as selected.
var _graph_box: MeshInstance3D = null
var _outline_mat: StandardMaterial3D = null
var _graph_outline_mat: StandardMaterial3D = null
var _move_outline_mat: StandardMaterial3D = null
var _graph_highlight := false
## True while the prop is being repositioned by a click-drag (GrabController) —
## keeps a distinct outline on even though crosshair focus is cleared for the drag.
var _move_highlight := false
var _body: StaticBody3D = null
## Prop-local AABB of the scaled model (for software pick fallback).
var _pick_aabb_local: AABB = AABB()


func _ready() -> void:
	super._ready()
	prompt = "Edit prop (click) / Move (drag)"
	max_distance = 12.0
	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.albedo_color = Color(0.05, 0.45, 0.12, 0.85)
	_outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	_graph_outline_mat = StandardMaterial3D.new()
	_graph_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_graph_outline_mat.albedo_color = Color(0.1, 0.82, 0.95, 0.9)
	_graph_outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	_move_outline_mat = StandardMaterial3D.new()
	_move_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_move_outline_mat.albedo_color = Color(1.0, 0.7, 0.15, 0.95)
	_move_outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT


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
		# Rename before the deferred free, or the replacement added this same
		# frame is auto-renamed and get_node("PropBody") finds the dying one.
		_body.name = "PropBody_freed"
		_body.collision_layer = 0
		_body.collision_mask = 0
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
		# Animated / non-solid meshes (e.g. PP extruder plastic stick) opt out so
		# invisible geometry doesn't block the player.
		if mi.has_meta("skip_prop_collision") and bool(mi.get_meta("skip_prop_collision")):
			continue
		var xf := model.transform * _transform_relative_to(model, mi)
		var faces := mi.mesh.get_faces()
		if faces.is_empty():
			continue
		var baked := PackedVector3Array()
		baked.resize(faces.size())
		for i in faces.size():
			baked[i] = xf * faces[i]
		# Drop NaN/degenerate triangles before set_faces — procedural pipe/linkage
		# meshes and imported STL parts (hardware store) can produce them, and the
		# physics server hard-crashes on such input.
		baked = MeshCollisionUtil.sanitize_faces(baked)
		if baked.size() < 3:
			continue
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(baked)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		added = true
	_pick_aabb_local = _mesh_aabb_prop_local(model)
	# NOTE: we deliberately do NOT add a solid AABB proxy box to the physics body.
	# Doing so made the whole bounding box a physical wall (an invisible "force
	# field" around open structures like pallet racks). Physical collision now
	# follows the baked per-mesh trimesh only. Crosshair selection of thin /
	# open-frame props still works: the physics ray hits the real geometry, and
	# InteractionFocus._pick_placed_prop_aabb() provides a software ray-vs-AABB
	# fallback (via get_world_pick_aabb) when the ray slips between members.
	# Only truly meshless props fall back to a coarse box. Meshes that opted out
	# via skip_prop_collision (mud prints — walk-through inspect) keep pick AABB
	# but no physics body at all.
	var any_skip := false
	for node2 in model.find_children("*", "MeshInstance3D", true, false):
		var mi2 := node2 as MeshInstance3D
		if mi2 != null and mi2.has_meta("skip_prop_collision") \
				and bool(mi2.get_meta("skip_prop_collision")):
			any_skip = true
			break
	if not added and not any_skip and _pick_aabb_local.size.length_squared() > 0.0001:
		_setup_box_collision(body, _pick_aabb_local)
	elif not added:
		body.queue_free()
		body = null
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
	_apply_outline(on or _focus_active or _move_highlight)
	_apply_graph_box(on)


## Show/hide a translucent cyan box around the prop's whole pick AABB — the
## graph-highlight cue for Site Plan, so multi-mesh structures read as a unit.
func _apply_graph_box(on: bool) -> void:
	if not on:
		if _graph_box != null:
			_graph_box.visible = false
		return
	if _pick_aabb_local.size.length_squared() < 0.0001:
		var model := get_node_or_null("ModelRoot") as Node3D
		if model != null:
			_pick_aabb_local = _mesh_aabb_prop_local(model)
	if _pick_aabb_local.size.length_squared() < 0.0001:
		return
	if _graph_box == null:
		_graph_box = MeshInstance3D.new()
		_graph_box.name = "GraphHighlightBox"
		_graph_box.mesh = BoxMesh.new()
		_graph_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.30, 0.90, 1.0, 0.16)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_graph_box.material_override = mat
		add_child(_graph_box)
	(_graph_box.mesh as BoxMesh).size = _pick_aabb_local.size
	_graph_box.position = _pick_aabb_local.position + _pick_aabb_local.size * 0.5
	_graph_box.visible = true


## Toggle the amber "being moved" outline (used by GrabController during a
## click-drag reposition, when normal crosshair focus is intentionally cleared).
func set_move_highlight(on: bool) -> void:
	_move_highlight = on
	_apply_outline(on or _graph_highlight or _focus_active)


func is_grabbable() -> bool:
	return true


## Prop-local bounding radius (metres) of the scaled model — safe to read before
## the node is in the tree (no global_transform). Used for size-scaled perf LOD.
func get_local_pick_radius() -> float:
	if _pick_aabb_local.size.length_squared() < 0.0001:
		var model := get_node_or_null("ModelRoot") as Node3D
		if model != null:
			_pick_aabb_local = _mesh_aabb_prop_local(model)
	return _pick_aabb_local.size.length() * 0.5


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
		var mat := _outline_mat
		if _move_highlight:
			mat = _move_outline_mat
		elif _graph_highlight:
			mat = _graph_outline_mat
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
