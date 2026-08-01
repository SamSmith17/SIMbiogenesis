class_name HawtTracker
extends Node3D

## Dual-axis controller for a placed small horizontal-axis wind turbine (HAWT):
## yaws the whole nacelle/vane assembly to face the live wind DIRECTION, and
## spins its blades/nosecone about the horizontal rotor axis at a rate set by
## wind SPEED. Attached by PlacedPropRuntime to a PlacedProp whose record has
## kind == "hawt" (mirrors WindTurbineSpin's VAWT pattern, extended to two
## independently-driven sub-nodes).
##
## Model structure (Small HAWT.glb, verified with a throwaway node-dump):
## the vane assembly node ("turbine vane assembly") sits at the mast top with
## its OWN ORIGIN already on the yaw-bearing centreline (author convention —
## used directly as the yaw pivot, no mesh-centroid measurement needed); its
## local Y axis is the horizontal "nose" direction the blades face. Its child
## ("Nosecone and Blades") carries the 3 blades arranged in a circle around
## that SAME local Y axis, offset from its own node origin — so the blade
## pivot is measured by averaging the 3 blade-root nodes' own positions
## (symmetric by construction), NOT a mesh-AABB centroid: unioning 3
## axis-aligned boxes of an asymmetric blade shape at 120° apart does not
## reliably land on the true rotation axis (see _measure_blade_pivot_local).
## Yawing the parent automatically carries the child's spin axis with it, so
## the two rotations compose for free through the node hierarchy.
##
## Yaw target: WeatherService.wind_direction_deg (meteorological FROM-degrees)
## converted to a world XZ vector via WindMath.downwind_xz — the SAME helper
## vegetation_wind_driver.gd uses for grass sway, so the turbine's nose always
## points opposite the direction grass leans. The turbine faces UPWIND (into
## the oncoming wind, as a real upwind-rotor HAWT self-aligns via its tail/
## nacelle), i.e. the negation of the downwind vector.
##
## Yaw slewing is sim-time aware (same technique as CspTroughTracker): a big
## timeline scrub/scale jump snaps the yaw instantly instead of visibly
## sweeping across the change.
##
## Blade spin reuses WindTurbineSpin's tip-speed-ratio model (ω = λ·v_hub/R,
## held at the rated-speed value above rated, parked outside the cut-in/
## cut-out window) and the exact same hub-wind-speed source
## (WindTurbineSource.hub_wind_speed_ms_from_specs) that drives this node's
## reported electrical output, so the visible spin rate and the wattage
## always agree.

const _WIND_SOURCE := preload("res://power_system/sources/wind_turbine_source.gd")

## How often to re-sample the (slowly changing) site wind, seconds of real time.
const _WIND_POLL_S := 0.25

## Blade spin-up / spin-down smoothing time constant (s) so gusts don't snap
## the rotor to a new RPM.
const _SPIN_SMOOTH_TAU := 2.0
## Safety cap on blade angular speed (rad/s ≈ 950 rpm) — keeps a bad spec from
## strobing; real small HAWTs of this class free-wheel around 700-900 rpm.
const _MAX_BLADE_OMEGA := 100.0

## Yaw real-time smoothing (s): how fast the nacelle eases toward the target
## heading when the sim clock is paused / near real-time. Small HAWTs of this
## size yaw over a few seconds in gusty wind.
const _YAW_TAU_REAL := 2.0
## Yaw sim-time smoothing (sim-hours): keeps the yaw glued to the wind at any
## time-scale (wind direction itself only changes on the weather sample grid).
const _YAW_TAU_SIM := 0.1
## A single-frame sim-time jump beyond this (timeline scrub / extreme speed)
## snaps the nacelle straight onto the target heading instead of easing.
const _YAW_SNAP_SIM_HOURS := 1.0

var wind_specs: Dictionary = {}
var yaw_node_name: String = "turbine vane assembly"
var blade_node_name: String = "Nosecone and Blades"
var graph_item_id: String = ""

var _yaw_node: Node3D = null
var _yaw_parent: Node3D = null
var _blade_node: Node3D = null
var _blade_parent: Node3D = null

var _t0_yaw: Transform3D = Transform3D.IDENTITY
var _t0_blade: Transform3D = Transform3D.IDENTITY
var _yaw_axis_p: Vector3 = Vector3(0.0, 0.0, 1.0)   # world-up expressed in the yaw node's parent space
var _world_up: Vector3 = Vector3.UP                  # same axis, in world space (for signed_angle_to)
var _yaw_rest_forward_world: Vector3 = Vector3(0.0, 0.0, -1.0)
var _blade_axis_c: Vector3 = Vector3(0.0, 1.0, 0.0)  # blade spin axis, expressed in the blade node's parent space
var _blade_center_c: Vector3 = Vector3.ZERO

var _yaw_angle: float = 0.0
var _yaw_target: float = 0.0
var _blade_angle: float = 0.0
var _blade_omega: float = 0.0
var _blade_target_omega: float = 0.0

var _poll_acc: float = 999.0
var _last_abs_hours: float = INF
var _sim_dh: float = 0.0
var _ready_ok := false


func configure(specs: Dictionary, yaw_name: String, blade_name: String, item_id: String) -> void:
	wind_specs = specs.duplicate(true)
	if not yaw_name.is_empty():
		yaw_node_name = yaw_name
	if not blade_name.is_empty():
		blade_node_name = blade_name
	graph_item_id = item_id


func _ready() -> void:
	# Defer one frame so the parent PlacedProp's ModelRoot transform is applied
	# and global transforms are valid before we capture the rest pose.
	call_deferred("_bind")


func _bind() -> void:
	var model_root := _find_model_root()
	if model_root == null:
		return
	_yaw_node = model_root.find_child(yaw_node_name, true, false) as Node3D
	if _yaw_node == null or _yaw_node.get_parent() == null:
		return
	_yaw_parent = _yaw_node.get_parent() as Node3D
	if _yaw_parent == null:
		return

	_world_up = model_root.global_transform.basis.y.normalized()
	if _world_up.length_squared() < 0.0001:
		_world_up = Vector3.UP
	_yaw_axis_p = (_yaw_parent.global_transform.basis.inverse() * _world_up).normalized()
	if _yaw_axis_p.length_squared() < 0.0001:
		_yaw_axis_p = Vector3(0.0, 0.0, 1.0)
	_yaw_rest_forward_world = _yaw_node.global_transform.basis.y.normalized()
	_t0_yaw = _yaw_node.transform

	_blade_node = _yaw_node.find_child(blade_node_name, true, false) as Node3D
	if _blade_node != null and _blade_node.get_parent() != null:
		_blade_parent = _blade_node.get_parent() as Node3D
		_t0_blade = _blade_node.transform
		_blade_axis_c = _t0_blade.basis.y.normalized()
		if _blade_axis_c.length_squared() < 0.0001:
			_blade_axis_c = Vector3(0.0, 1.0, 0.0)
		# Pure local-transform math (no global_transform dependency): the
		# pivot measured in the blade node's OWN local space, then carried
		# into the parent's space by _t0_blade (which already maps that
		# space into it).
		var pivot_local := _measure_blade_pivot_local()
		_blade_center_c = _t0_blade * pivot_local

	_ready_ok = true


func _process(delta: float) -> void:
	if not _ready_ok:
		return
	_poll_acc += delta
	if _poll_acc >= _WIND_POLL_S:
		_poll_acc = 0.0
		_refresh_targets()

	_step_yaw(delta)
	_step_blade_spin(delta)


func _step_yaw(delta: float) -> void:
	if not is_instance_valid(_yaw_node) or _yaw_parent == null:
		return
	var dh := absf(_sim_dh)
	if dh > _YAW_SNAP_SIM_HOURS:
		_yaw_angle = _yaw_target
	else:
		var x := delta / maxf(_YAW_TAU_REAL, 0.01) + dh / maxf(_YAW_TAU_SIM, 1e-4)
		var k := clampf(1.0 - exp(-x), 0.0, 1.0)
		_yaw_angle = lerp_angle(_yaw_angle, _yaw_target, k)
	var rot := Basis(_yaw_axis_p, _yaw_angle)
	# The yaw node's own origin (in _t0_yaw) already sits on the bearing
	# centreline, so it is the fixed point rotation happens around.
	var pivot := _t0_yaw.origin
	_yaw_node.transform = Transform3D(rot, pivot - rot * pivot) * _t0_yaw


func _step_blade_spin(delta: float) -> void:
	if not is_instance_valid(_blade_node) or _blade_parent == null:
		return
	var k := clampf(1.0 - exp(-delta / maxf(_SPIN_SMOOTH_TAU, 0.01)), 0.0, 1.0)
	_blade_omega = lerpf(_blade_omega, _blade_target_omega, k)
	_blade_angle = wrapf(_blade_angle + _blade_omega * delta, -TAU, TAU)
	var rot := Basis(_blade_axis_c, _blade_angle)
	_blade_node.transform = Transform3D(rot, _blade_center_c - rot * _blade_center_c) * _t0_blade


func _refresh_targets() -> void:
	var main := _main_node()
	var hour := 12.0
	var month := 6
	var day := 15
	var real_wind_10m := NAN
	var from_deg := NAN
	_sim_dh = 0.0

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
		var clock_obj: Variant = main.get("clock")
		if clock_obj != null and (clock_obj as Object).has_method("get_absolute_hours"):
			var cur_abs: float = float((clock_obj as Object).call("get_absolute_hours"))
			if is_finite(_last_abs_hours):
				_sim_dh = cur_abs - _last_abs_hours
			_last_abs_hours = cur_abs
		var ws := main.get_tree().root.get_node_or_null("/root/WeatherService") if main.get_tree() != null else null
		if ws != null and ws.has_method("covers"):
			var lat: Variant = main.get("latitude")
			var lon: Variant = main.get("longitude")
			if lat != null and lon != null and bool(ws.call("covers", float(lat), float(lon))):
				real_wind_10m = float(ws.call("wind_speed_ms", month, day, hour))
				if ws.has_method("wind_direction_deg"):
					from_deg = float(ws.call("wind_direction_deg", month, day, hour))

	var v_hub := _WIND_SOURCE.hub_wind_speed_ms_from_specs(wind_specs, hour, real_wind_10m)
	var cut_in := float(wind_specs.get("cut_in_ms", 3.0))
	var cut_out := float(wind_specs.get("cut_out_ms", 25.0))
	var rated := maxf(float(wind_specs.get("rated_ms", 12.0)), 0.1)
	var tsr := maxf(float(wind_specs.get("tip_speed_ratio", 4.0)), 0.2)
	var radius := maxf(float(wind_specs.get("rotor_radius_m",
		float(wind_specs.get("rotor_diameter_m", 1.17)) * 0.5)), 0.05)

	if v_hub < cut_in or v_hub > cut_out:
		_blade_target_omega = 0.0
	else:
		var v_eff := minf(v_hub, rated)
		_blade_target_omega = clampf(tsr * v_eff / radius, 0.0, _MAX_BLADE_OMEGA)

	# Wind direction → world XZ (same helper + convention as the vegetation
	# wind driver's grass sway); the nacelle faces UPWIND, opposite the
	# downwind vector grass leans along.
	var downwind := WindMath.downwind_xz(from_deg)
	var upwind_world := Vector3(-downwind.x, 0.0, -downwind.y)
	if upwind_world.length_squared() > 0.0001:
		_yaw_target = _yaw_rest_forward_world.signed_angle_to(upwind_world.normalized(), _world_up)

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


## The blade circle's true centre, in _blade_node's OWN local space. Averaging
## the direct child blade-root nodes' `position` (they are symmetric by
## construction — 3 blades 120° apart around the spin axis, verified against
## the shipped GLB: the three "t-blade*" roots average to (0, y, 0) exactly)
## is far more accurate than an AABB-union centroid: each blade's mesh is an
## axis-aligned box of an asymmetric, rotated shape, so unioning 3 of them at
## 120° apart does NOT reliably centre on the true rotation axis — this was
## the cause of the blades/nosecone reading a couple of inches off-axis.
## Falls back to the old AABB-centroid approach (converted to local space) if
## no child looks like a blade root, so a differently-authored replacement
## model still gets a reasonable pivot instead of spinning around the origin.
func _measure_blade_pivot_local() -> Vector3:
	var sum := Vector3.ZERO
	var count := 0
	for child in _blade_node.get_children():
		if child is Node3D and String(child.name).to_lower().contains("blade"):
			sum += (child as Node3D).position
			count += 1
	if count > 0:
		return sum / float(count)
	var center_world := _group_world_center(_blade_node)
	return _blade_node.global_transform.affine_inverse() * center_world


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
