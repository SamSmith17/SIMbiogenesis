class_name SiphonTurbineSpin
extends Node3D

## Spins a placed siphon hydroturbine rotor from live graph electrical output
## (same spirit as WindTurbineSpin). Attached by PlacedPropRuntime when
## record.kind == "siphon_hydro" or model_id == "hydroturbine".

const _SMOOTH_TAU := 0.6
const _MAX_OMEGA := SiphonHydraulics.OMEGA_AT_RATED * 1.25
const _POLL_S := 0.35
## Skip transform writes when parked (avoids perpetual dirty transforms).
const _PARK_EPS := 0.02

var graph_item_id: String = ""
var turbine_node_name: String = ""

var _turbine: Node3D = null
var _t0: Transform3D = Transform3D.IDENTITY
var _axis_p: Vector3 = Vector3(0.0, 0.0, 1.0)
var _center_p: Vector3 = Vector3.ZERO
var _angle: float = 0.0
var _omega: float = 0.0
var _target_omega: float = 0.0
var _poll_acc: float = 999.0
var _ready_ok := false
var _sgv: Node = null
var _parked := true


func configure(item_id: String, turbine_name: String = "") -> void:
	graph_item_id = item_id
	turbine_node_name = turbine_name


func _ready() -> void:
	call_deferred("_bind_turbine")


func _bind_turbine() -> void:
	var model_root := _find_model_root()
	if model_root == null:
		return
	_turbine = _resolve_turbine(model_root)
	if _turbine == null or _turbine.get_parent() == null:
		return
	var parent := _turbine.get_parent() as Node3D
	if parent == null:
		return
	var world_axis := model_root.global_transform.basis.z.normalized()
	if world_axis.length_squared() < 0.0001:
		world_axis = Vector3.UP
	var parent_gt := parent.global_transform
	_axis_p = (parent_gt.basis.inverse() * world_axis).normalized()
	if _axis_p.length_squared() < 0.0001:
		_axis_p = Vector3(0.0, 0.0, 1.0)
	var center_world := _group_world_center(_turbine)
	_center_p = parent_gt.affine_inverse() * center_world
	_t0 = _turbine.transform
	_ready_ok = true


func _process(delta: float) -> void:
	if not _ready_ok or not is_instance_valid(_turbine):
		return
	_poll_acc += delta
	if _poll_acc >= _POLL_S:
		_poll_acc = 0.0
		_refresh_target()
	var k := 1.0 - exp(-delta / maxf(_SMOOTH_TAU, 0.01))
	_omega = lerpf(_omega, _target_omega, clampf(k, 0.0, 1.0))
	if absf(_omega) < _PARK_EPS and absf(_target_omega) < _PARK_EPS:
		if not _parked:
			_parked = true
			_omega = 0.0
			# One last rest pose write.
			_turbine.transform = _t0
		return
	_parked = false
	_angle = wrapf(_angle + _omega * delta, -TAU, TAU)
	var rot := Basis(_axis_p, _angle)
	_turbine.transform = Transform3D(rot, _center_p - rot * _center_p) * _t0


func _refresh_target() -> void:
	_target_omega = 0.0
	if graph_item_id.is_empty():
		return
	if _sgv == null or not is_instance_valid(_sgv):
		_sgv = _system_graph_view(_main_node())
	if _sgv == null:
		return
	var model = _sgv.get("model")
	if model == null or not model.has_method("get_item"):
		return
	var item: Dictionary = model.get_item(graph_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var pe_w := float(specs.get("live_pe_w", 0.0))
	if pe_w <= 0.0:
		var power_w := float(specs.get("live_power_w", 0.0))
		if power_w <= 0.0:
			power_w = float(specs.get("current_output_kw", 0.0)) * 1000.0
		_target_omega = clampf(SiphonHydraulics.omega_from_power_w(power_w,
				float(specs.get("max_power_w", 0.0))), 0.0, _MAX_OMEGA)
	else:
		_target_omega = clampf(SiphonHydraulics.omega_from_pe_w(pe_w), 0.0, _MAX_OMEGA)


func _find_model_root() -> Node3D:
	var p := get_parent()
	if p == null:
		return null
	var mr := p.get_node_or_null("ModelRoot") as Node3D
	if mr != null:
		return mr
	return p as Node3D


func _resolve_turbine(model_root: Node3D) -> Node3D:
	var prefer := [
		turbine_node_name, "propeller", "Propeller", "rotor", "Rotor",
		"spindle", "Spindle", "blade", "Blade", "impeller", "Impeller",
	]
	for name in prefer:
		if str(name).is_empty():
			continue
		var named := model_root.find_child(str(name), true, false)
		if named is Node3D:
			return named as Node3D
	var best: Node3D = null
	var best_vol := INF
	for n in model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var aabb := mi.mesh.get_aabb()
		var vol := absf(aabb.size.x * aabb.size.y * aabb.size.z)
		if vol > 1e-8 and vol < best_vol:
			best_vol = vol
			best = mi
	return best


func _group_world_center(group: Node3D) -> Vector3:
	if group is MeshInstance3D:
		var mi := group as MeshInstance3D
		if mi.mesh != null:
			return (mi.global_transform * mi.mesh.get_aabb()).get_center()
	var aabb := AABB()
	var found := false
	for node in group.find_children("*", "MeshInstance3D", true, false):
		var mi2 := node as MeshInstance3D
		if mi2.mesh == null:
			continue
		var box: AABB = mi2.global_transform * mi2.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	if not found:
		return group.global_position
	return aabb.get_center()


func _main_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var m := tree.get_first_node_in_group("main_scene")
	if m != null:
		return m
	return tree.current_scene


func _system_graph_view(main: Node) -> Node:
	if main == null:
		return null
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	return sgv
