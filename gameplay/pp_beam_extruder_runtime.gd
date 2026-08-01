class_name PpBeamExtruderRuntime
extends Node3D
## Visual extrusion for a placed Precious Plastic beam extruder.
##
## - `beam#1` = steel mold sleeve — left at authored pose (never scaled).
## - `Recycled Plastic Beam` = plastic stick — heel pinned to the mold mouth,
##   scaled along its long axis to the live extruded length, clipped so nothing
##   appears inside the machine. Graph tick owns metres / inventory cuts.

const _CLIP_SHADER := preload("res://gameplay/pp_beam_extrude_clip.gdshader")

var _graph_item_id: String = ""
var _plastic: Node3D = null
var _mold: Node3D = null
var _plastic_rest: Transform3D = Transform3D.IDENTITY
var _axis: int = 0
var _heel_local: float = 0.0
var _tip_local: float = 0.0
var _rest_length_m: float = 1.0
var _die_origin_model: Vector3 = Vector3.ZERO
var _die_outward_model: Vector3 = Vector3.LEFT
var _model_root: Node3D = null
var _clip_mats: Array[ShaderMaterial] = []
var _bound := false


func configure(graph_item_id: String, _preferred_names: PackedStringArray = PackedStringArray()) -> void:
	_graph_item_id = graph_item_id


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	if _bound:
		return
	var prop := get_parent()
	if prop == null:
		return
	_model_root = prop.get_node_or_null("ModelRoot") as Node3D
	if _model_root == null:
		return
	_plastic = _find_by_names(_model_root, ["Recycled Plastic Beam", "1x3 plastic beam"])
	_mold = _find_by_names(_model_root, ["beam#1"])
	if _plastic == null:
		push_warning("PpBeamExtruderRuntime: 'Recycled Plastic Beam' not found")
		return
	_plastic_rest = _plastic.transform
	var aabb := _local_aabb(_plastic)
	var size := aabb.size
	_axis = 0
	if size.y >= size.x and size.y >= size.z:
		_axis = 1
	elif size.z >= size.x and size.z >= size.y:
		_axis = 2
	_tip_local = aabb.position[_axis]
	_heel_local = aabb.position[_axis] + size[_axis]
	# World-metre length of the authored stick (parents carry inch→metre scale).
	var tip_l := Vector3.ZERO
	tip_l[_axis] = _tip_local
	var heel_l := Vector3.ZERO
	heel_l[_axis] = _heel_local
	_rest_length_m = maxf(_plastic.to_global(tip_l).distance_to(_plastic.to_global(heel_l)), 0.05)
	_compute_die_plane()
	_apply_clip_materials()
	for mi in _mesh_instances(_plastic):
		mi.set_meta("skip_prop_collision", true)
	if prop.has_method("setup_collision"):
		prop.call("setup_collision")
	_apply_visual(0.0, false)
	_bound = true


func _process(_delta: float) -> void:
	if not _bound or _plastic == null or not is_instance_valid(_plastic):
		return
	var state := _read_graph_state()
	var length_m := float(state.get("extruded_length_m", 0.0))
	var cut_m := maxf(float(state.get("cut_length_m", 2.0)), 0.05)
	var running := bool(state.get("running", false))
	_apply_visual(clampf(length_m, 0.0, cut_m), running or length_m > 0.002)


func _apply_visual(length_m: float, show_plastic: bool) -> void:
	# Mold is never touched.
	_plastic.visible = show_plastic and length_m > 0.002
	if not _plastic.visible:
		_plastic.transform = _plastic_rest
		_update_clip_uniforms()
		return

	var scale_frac := maxf(length_m / maxf(_rest_length_m, 0.01), 0.001)
	# Authored plastic node is translation-only (identity basis) under an inch-
	# scaled parent — scale the long axis, then slide so the heel sits on the die.
	var sc := Vector3(
		absf(_plastic_rest.basis.x.length()),
		absf(_plastic_rest.basis.y.length()),
		absf(_plastic_rest.basis.z.length()))
	if sc.x < 1e-6:
		sc = Vector3.ONE
	sc[_axis] = sc[_axis] * scale_frac

	_plastic.transform = _plastic_rest
	_plastic.scale = sc

	var parent_n := _plastic.get_parent() as Node3D
	if parent_n == null or _model_root == null:
		_update_clip_uniforms()
		return
	var die_global := _model_root.to_global(_die_origin_model)
	var die_in_parent := parent_n.to_local(die_global)
	# Heel in parent space after scale (scale is about node origin).
	var heel_offset := Vector3.ZERO
	heel_offset[_axis] = _heel_local * sc[_axis]
	var heel_in_parent := _plastic.position + heel_offset
	_plastic.position += die_in_parent - heel_in_parent
	_update_clip_uniforms()


func _compute_die_plane() -> void:
	var tip_v := Vector3.ZERO
	tip_v[_axis] = _tip_local
	var heel_v := Vector3.ZERO
	heel_v[_axis] = _heel_local
	var tip_model := _node_local_to_model(_plastic, tip_v)
	var heel_model := _node_local_to_model(_plastic, heel_v)

	if _mold != null and is_instance_valid(_mold):
		var m_aabb := _local_aabb(_mold)
		var c := m_aabb.get_center()
		var mn := m_aabb.position
		var mx := m_aabb.position + m_aabb.size
		var ax := 0
		if m_aabb.size.y >= m_aabb.size.x and m_aabb.size.y >= m_aabb.size.z:
			ax = 1
		elif m_aabb.size.z >= m_aabb.size.x and m_aabb.size.z >= m_aabb.size.y:
			ax = 2
		var min_pt := c
		min_pt[ax] = mn[ax]
		var max_pt := c
		max_pt[ax] = mx[ax]
		var min_m := _node_local_to_model(_mold, min_pt)
		var max_m := _node_local_to_model(_mold, max_pt)
		# Outward mold face = the one nearer the plastic tip.
		if min_m.distance_to(tip_model) <= max_m.distance_to(tip_model):
			_die_origin_model = min_m
			_die_outward_model = (min_m - max_m).normalized()
		else:
			_die_origin_model = max_m
			_die_outward_model = (max_m - min_m).normalized()
	else:
		_die_origin_model = heel_model
		_die_outward_model = (tip_model - heel_model).normalized()
	if _die_outward_model.length_squared() < 1e-8:
		_die_outward_model = Vector3.LEFT


func _apply_clip_materials() -> void:
	_clip_mats.clear()
	for mi in _mesh_instances(_plastic):
		var mat := ShaderMaterial.new()
		mat.shader = _CLIP_SHADER
		var src: Material = mi.get_active_material(0)
		if src is StandardMaterial3D:
			var sm := src as StandardMaterial3D
			mat.set_shader_parameter("albedo", sm.albedo_color)
			mat.set_shader_parameter("roughness", sm.roughness)
			mat.set_shader_parameter("metallic", sm.metallic)
		else:
			mat.set_shader_parameter("albedo", Color(0.22, 0.62, 0.58, 1.0))
		mi.material_override = mat
		_clip_mats.append(mat)


func _update_clip_uniforms() -> void:
	if _model_root == null:
		return
	var origin_world := _model_root.to_global(_die_origin_model)
	var outward_world := (_model_root.global_transform.basis * _die_outward_model).normalized()
	for mat: ShaderMaterial in _clip_mats:
		if mat == null:
			continue
		mat.set_shader_parameter("clip_origin", origin_world)
		mat.set_shader_parameter("clip_normal", outward_world)
		mat.set_shader_parameter("clip_enabled", true)


func _node_local_to_model(node: Node3D, local_pt: Vector3) -> Vector3:
	if _model_root == null or node == null:
		return local_pt
	return _xform_relative_to(_model_root, node) * local_pt


func _read_graph_state() -> Dictionary:
	if _graph_item_id.is_empty():
		return {}
	var main := _find_main()
	if main == null:
		return {}
	var view := ServiceLocator.graph()
	if view == null:
		view = main.find_child("SystemGraphView", true, false)
	if view != null and view.has_method("get_pp_extruder_state"):
		return view.call("get_pp_extruder_state", _graph_item_id) as Dictionary
	return {}


func _find_main() -> Node:
	var n: Node = self
	while n != null:
		if n.name == "Main" or (n.has_method("get_absolute_hours") and n.has_node("UILayer")):
			return n
		n = n.get_parent()
	return ServiceLocator.main()


func _find_by_names(root: Node, names: Array) -> Node3D:
	for want_v in names:
		var want := str(want_v)
		var hit := _find_name(root, want)
		if hit != null:
			return hit
	return null


func _find_name(node: Node, want: String) -> Node3D:
	if node is Node3D and str(node.name) == want:
		return node as Node3D
	for c in node.get_children():
		var hit := _find_name(c, want)
		if hit != null:
			return hit
	return null


func _local_aabb(n: Node3D) -> AABB:
	var acc := AABB()
	var first := true
	for mi in _mesh_instances(n):
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		var a := mesh.get_aabb()
		var xf := _xform_relative_to(n, mi)
		for p: Vector3 in [
			xf * a.position,
			xf * (a.position + Vector3(a.size.x, 0, 0)),
			xf * (a.position + Vector3(0, a.size.y, 0)),
			xf * (a.position + Vector3(0, 0, a.size.z)),
			xf * (a.position + Vector3(a.size.x, a.size.y, 0)),
			xf * (a.position + Vector3(a.size.x, 0, a.size.z)),
			xf * (a.position + Vector3(0, a.size.y, a.size.z)),
			xf * (a.position + a.size),
		]:
			if first:
				acc = AABB(p, Vector3.ZERO)
				first = false
			else:
				acc = acc.expand(p)
	if first:
		return AABB(Vector3.ZERO, Vector3(1, 0.05, 0.05))
	return acc


func _mesh_instances(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n as MeshInstance3D)
	for c in n.get_children():
		out.append_array(_mesh_instances(c))
	return out


func _xform_relative_to(ancestor: Node3D, descendant: Node3D) -> Transform3D:
	var t := descendant.transform
	var p := descendant.get_parent()
	while p != null and p != ancestor and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t
