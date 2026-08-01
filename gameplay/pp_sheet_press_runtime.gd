class_name PpSheetPressRuntime
extends Node3D
## Visuals for a placed Precious Plastic sheet press.
##
## - Moves the GLB "Z axis" node along its local travel axis by compression
##   (melt closes, cool holds) from SystemGraphView.get_pp_sheet_press_state.
## - Keeps "Recycled Plastic Sheet" hidden until the cycle completes, then
##   reveals it (scaled to the selected thickness) until the next job starts.

const DEFAULT_Z_NODE := "Z axis"
const DEFAULT_SHEET_NODE := "Recycled Plastic Sheet"
const DEFAULT_STROKE_M := 0.12
const AUTHORED_SHEET_MM := 6.0

var _graph_item_id: String = ""
var _z_node: Node3D = null
var _sheet_node: Node3D = null
var _z_rest: Vector3 = Vector3.ZERO
var _z_axis: int = 1  # 0=x 1=y 2=z — travel direction in local space
var _stroke_m: float = DEFAULT_STROKE_M
var _sheet_rest_scale: Vector3 = Vector3.ONE
var _sheet_thick_axis: int = 1
var _bound := false
var _was_completed := false


func configure(graph_item_id: String, stroke_m: float = DEFAULT_STROKE_M) -> void:
	_graph_item_id = graph_item_id
	_stroke_m = maxf(stroke_m, 0.02)


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	if _bound:
		return
	var root := get_parent()
	if root == null:
		return
	var model := root.get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return
	_z_node = _find_named(model, DEFAULT_Z_NODE) as Node3D
	_sheet_node = _find_named(model, DEFAULT_SHEET_NODE) as Node3D
	if _z_node != null:
		_z_rest = _z_node.position
		_z_axis = _pick_travel_axis(_z_node)
	if _sheet_node != null:
		_sheet_rest_scale = _sheet_node.scale
		_sheet_thick_axis = _pick_thin_axis(_sheet_node)
		_sheet_node.visible = false
	if _z_node == null:
		push_warning("PpSheetPressRuntime: no '%s' node under %s" % [DEFAULT_Z_NODE, model.name])
	_bound = true


func _process(_delta: float) -> void:
	if not _bound:
		return
	var state := _read_graph_state()
	var compression := float(state.get("compression", 0.0))
	var phase := str(state.get("phase", "idle"))
	var completed := bool(state.get("completed", false))
	var active := bool(state.get("active", false))
	var thick_mm := float(state.get("thickness_mm", AUTHORED_SHEET_MM))
	var stroke := float(state.get("z_stroke_m", _stroke_m))
	if stroke <= 0.0:
		stroke = _stroke_m

	if _z_node != null and is_instance_valid(_z_node):
		var pos := _z_rest
		# Close toward −local travel axis (platen presses onto the sheet).
		pos[_z_axis] = _z_rest[_z_axis] - stroke * clampf(compression, 0.0, 1.0)
		_z_node.position = pos

	if _sheet_node != null and is_instance_valid(_sheet_node):
		var show_sheet := completed or (phase == "done")
		# Hide again as soon as a new cycle starts.
		if active and phase != "done":
			show_sheet = false
			_was_completed = false
		elif completed:
			_was_completed = true
			show_sheet = true
		elif _was_completed and phase == "idle":
			show_sheet = true
		_sheet_node.visible = show_sheet
		if show_sheet:
			var s := _sheet_rest_scale
			var frac := maxf(thick_mm, 1.0) / AUTHORED_SHEET_MM
			s[_sheet_thick_axis] = _sheet_rest_scale[_sheet_thick_axis] * frac
			_sheet_node.scale = s


func _read_graph_state() -> Dictionary:
	if _graph_item_id.is_empty():
		return {}
	var main := _find_main()
	if main == null:
		return {}
	var view := ServiceLocator.graph()
	if view == null:
		view = main.find_child("SystemGraphView", true, false)
	if view != null and view.has_method("get_pp_sheet_press_state"):
		return view.call("get_pp_sheet_press_state", _graph_item_id) as Dictionary
	return {}


func _find_main() -> Node:
	var n: Node = self
	while n != null:
		if n.name == "Main" or (n.has_method("get_absolute_hours") and n.has_node("UILayer")):
			return n
		n = n.get_parent()
	return ServiceLocator.main()


func _find_named(root: Node, want: String) -> Node:
	if root == null:
		return null
	if str(root.name) == want:
		return root
	for c in root.get_children():
		var hit := _find_named(c, want)
		if hit != null:
			return hit
	return null


func _pick_travel_axis(n: Node3D) -> int:
	# Prefer the axis where the platen AABB is thinnest (press travel).
	var aabb := _local_aabb(n)
	var size := aabb.size
	if size.y <= size.x and size.y <= size.z:
		return 1
	if size.z <= size.x and size.z <= size.y:
		return 2
	return 0


func _pick_thin_axis(n: Node3D) -> int:
	var aabb := _local_aabb(n)
	var size := aabb.size
	if size.y <= size.x and size.y <= size.z:
		return 1
	if size.z <= size.x and size.z <= size.y:
		return 2
	return 0


func _local_aabb(n: Node3D) -> AABB:
	var acc := AABB()
	var first := true
	for mi in _mesh_instances(n):
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		var a := mesh.get_aabb()
		var xf := _xform_relative_to(n, mi)
		var corners: Array[Vector3] = [
			xf * a.position,
			xf * (a.position + Vector3(a.size.x, 0, 0)),
			xf * (a.position + Vector3(0, a.size.y, 0)),
			xf * (a.position + Vector3(0, 0, a.size.z)),
			xf * (a.position + Vector3(a.size.x, a.size.y, 0)),
			xf * (a.position + Vector3(a.size.x, 0, a.size.z)),
			xf * (a.position + Vector3(0, a.size.y, a.size.z)),
			xf * (a.position + a.size),
		]
		for p: Vector3 in corners:
			if first:
				acc = AABB(p, Vector3.ZERO)
				first = false
			else:
				acc = acc.expand(p)
	if first:
		return AABB(Vector3.ZERO, Vector3(1, 0.05, 1))
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
