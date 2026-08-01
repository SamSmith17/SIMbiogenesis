class_name WindTurbineSpin
extends Node3D

## Spins a placed VAWT's rotor sub-node about the vertical (pole) axis at a speed
## derived from the live site wind, and keeps its bound 2D graph node's electrical
## output in sync. Attached by PlacedPropRuntime to a PlacedProp whose record has
## kind == "vawt".
##
## The rotor angular speed uses a tip-speed-ratio model ω = λ·v_hub / R, held at
## the rated-speed value above rated wind (pitch/furl regulation) and parked below
## cut-in / above cut-out. v_hub comes from the SAME wind model that drives the 2D
## node's power (WindTurbineSource.hub_wind_speed_ms_from_specs), so the visible
## spin and the reported watts always agree.

const _WIND_SOURCE := preload("res://power_system/sources/wind_turbine_source.gd")

## How often to re-sample the (slowly changing) site wind, seconds of real time.
const _WIND_POLL_S := 0.25
## Spin-up / spin-down smoothing time constant (s) so gusts don't snap the rotor.
const _SMOOTH_TAU := 2.5
## Safety cap on angular speed (rad/s ≈ 480 rpm) — keeps a bad spec from strobing.
const _MAX_OMEGA := 50.0

var wind_specs: Dictionary = {}
var turbine_node_name: String = ""
var graph_item_id: String = ""

var _turbine: Node3D = null
var _t0: Transform3D = Transform3D.IDENTITY
var _axis_p: Vector3 = Vector3(0.0, 0.0, 1.0)
var _center_p: Vector3 = Vector3.ZERO
var _angle: float = 0.0
var _omega: float = 0.0
var _target_omega: float = 0.0
var _poll_acc: float = 999.0
var _ready_ok := false


func configure(specs: Dictionary, turbine_name: String, item_id: String) -> void:
	wind_specs = specs.duplicate(true)
	turbine_node_name = turbine_name
	graph_item_id = item_id


func _ready() -> void:
	# Defer one frame so the parent PlacedProp's ModelRoot transform is applied
	# and global transforms are valid before we capture the pivot.
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
	# World up = the model's own up axis (prop is normally upright; honours tilt).
	var world_up := model_root.global_transform.basis.y.normalized()
	if world_up.length_squared() < 0.0001:
		world_up = Vector3.UP
	var parent_gt := parent.global_transform
	_axis_p = (parent_gt.basis.inverse() * world_up).normalized()
	if _axis_p.length_squared() < 0.0001:
		_axis_p = Vector3(0.0, 0.0, 1.0)
	# Rotate about the rotor's own centreline: its world-space centroid lies on
	# the vertical axis (symmetric rotor), projected into the parent's local space.
	var center_world := _turbine_world_center()
	_center_p = parent_gt.affine_inverse() * center_world
	_t0 = _turbine.transform
	_ready_ok = true


func _process(delta: float) -> void:
	if not _ready_ok or not is_instance_valid(_turbine):
		return
	_poll_acc += delta
	if _poll_acc >= _WIND_POLL_S:
		_poll_acc = 0.0
		_refresh_target()
	# Exponential smoothing toward the target angular speed.
	var k := 1.0 - exp(-delta / maxf(_SMOOTH_TAU, 0.01))
	_omega = lerpf(_omega, _target_omega, clampf(k, 0.0, 1.0))
	_angle = wrapf(_angle + _omega * delta, -TAU, TAU)
	var rot := Basis(_axis_p, _angle)
	_turbine.transform = Transform3D(rot, _center_p - rot * _center_p) * _t0


func _refresh_target() -> void:
	var main := _main_node()
	var hour := 12.0
	var month := 6
	var day := 15
	var real_wind_10m := NAN
	if main != null:
		var dt: Variant = main.get("day_time")
		if dt != null:
			hour = float(dt)
		var mo: Variant = main.get("month")
		if mo != null:
			month = clampi(int(mo), 1, 12)
		var dd: Variant = main.get("day")
		if dd != null:
			day = clampi(int(dd), 1, 31)
		var ws := main.get_tree().root.get_node_or_null("/root/WeatherService") if main.get_tree() != null else null
		if ws != null and ws.has_method("covers"):
			var lat: Variant = main.get("latitude")
			var lon: Variant = main.get("longitude")
			if lat != null and lon != null and bool(ws.call("covers", float(lat), float(lon))):
				real_wind_10m = float(ws.call("wind_speed_ms", month, day, hour))

	var v_hub := _WIND_SOURCE.hub_wind_speed_ms_from_specs(wind_specs, hour, real_wind_10m)
	var cut_in := float(wind_specs.get("cut_in_ms", 3.0))
	var cut_out := float(wind_specs.get("cut_out_ms", 25.0))
	var rated := maxf(float(wind_specs.get("rated_ms", 12.0)), 0.1)
	var tsr := maxf(float(wind_specs.get("tip_speed_ratio", 2.6)), 0.2)
	var radius := maxf(float(wind_specs.get("rotor_radius_m",
		float(wind_specs.get("rotor_diameter_m", 2.0)) * 0.5)), 0.05)

	if v_hub < cut_in or v_hub > cut_out:
		_target_omega = 0.0
	else:
		# Above rated wind the rotor is regulated to (roughly) constant speed.
		var v_eff := minf(v_hub, rated)
		_target_omega = clampf(tsr * v_eff / radius, 0.0, _MAX_OMEGA)

	# Keep the bound 2D node's reported output current even while the graph is
	# closed (its own _tick only runs while visible).
	if not graph_item_id.is_empty():
		var kw := _WIND_SOURCE.power_kw_from_graph_specs(wind_specs, hour, real_wind_10m)
		var sgv := _system_graph_view(main)
		if sgv != null and sgv.has_method("refresh_bound_generator_output"):
			sgv.call("refresh_bound_generator_output", graph_item_id, kw)


func _find_model_root() -> Node3D:
	var p := get_parent()
	if p == null:
		return null
	var mr := p.get_node_or_null("ModelRoot") as Node3D
	if mr != null:
		return mr
	return p as Node3D


## Locate the rotating rotor sub-node. Prefers the authored name; falls back to
## the highest non-mesh Node3D group (the rotor sits atop the mast).
func _resolve_turbine(model_root: Node3D) -> Node3D:
	if not turbine_node_name.is_empty():
		var named := model_root.find_child(turbine_node_name, true, false)
		if named is Node3D:
			return named as Node3D
	var best: Node3D = null
	var best_y := -1e20
	for n in model_root.find_children("*", "Node3D", true, false):
		if n is MeshInstance3D:
			continue
		var node3d := n as Node3D
		if node3d.find_children("*", "MeshInstance3D", true, false).is_empty():
			continue
		var c := _group_world_center(node3d)
		if c.y > best_y:
			best_y = c.y
			best = node3d
	return best


func _turbine_world_center() -> Vector3:
	return _group_world_center(_turbine)


func _group_world_center(group: Node3D) -> Vector3:
	var aabb := AABB()
	var found := false
	for node in group.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = mi.global_transform * mi.mesh.get_aabb()
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
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	return sgv
