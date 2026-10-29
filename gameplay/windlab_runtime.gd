class_name WindLabRuntime
extends Node

## A placed turbine from the wind turbine designer, alive in the world: it
## reads the site's wind at its hub (WeatherService's measured 10 m wind
## shear-corrected, else the synthetic site wind — the SAME model the graph's
## wind node uses), turns the rotor at the speed its design solved for that
## wind (WindLabDesign's rpm curve), swings a propeller to face the wind, and
## keeps the bound graph node's output current while the graph is closed.
## Attached by PlacedPropRuntime to any prop whose model_id is
## WindLabBuilder.MODEL_ID.

const _POLL_S := 0.25
const _SMOOTH_TAU := 2.0
## On screen the rotor's speed is compressed past ~150 rpm (a real small
## rotor at 1500 rpm aliases into a crawl at 60 fps); the label tells the truth.
const _DISPLAY_RPM := 150.0
const _YAW_RATE := 0.6

var graph_item_id := ""
var _specs: Dictionary = {}
var _builder: WindLabBuilder = null
var _poll := 999.0
var _rpm_target := 0.0
var _rpm := 0.0
var _yaw_target := 0.0
var _yaw := 0.0
var _have_yaw := false
var last_wind_ms := 0.0
var last_rpm := 0.0
var last_w := 0.0


static func attach(prop: Node3D, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != WindLabBuilder.MODEL_ID or prop.get_node_or_null("WindLabRuntime") != null:
		return
	var rt := WindLabRuntime.new()
	rt.name = "WindLabRuntime"
	rt.graph_item_id = str(rec.get("graph_item_id", ""))
	var spec: Dictionary = rec.get("windlab_spec", {}) as Dictionary
	rt._specs = WindLabDesign.graph_patch(WindLabDesign.solve(spec))
	prop.add_child(rt)


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	var p := get_parent()
	if p == null:
		return
	for n in p.find_children("*", "Node3D", true, false):
		if n is WindLabBuilder:
			_builder = n as WindLabBuilder
			break


func _process(delta: float) -> void:
	if _builder == null or not is_instance_valid(_builder):
		return
	_poll += delta
	if _poll >= _POLL_S:
		_poll = 0.0
		_refresh()
	var k := 1.0 - exp(-delta / _SMOOTH_TAU)
	_rpm = lerpf(_rpm, _rpm_target, k)
	_builder.set_spin_rpm(_DISPLAY_RPM * (1.0 - exp(-_rpm / _DISPLAY_RPM)) if not _paused() else 0.0)
	if _have_yaw:
		_yaw = lerp_angle(_yaw, _yaw_target, clampf(delta * _YAW_RATE, 0.0, 1.0))
		_builder.set_yaw(_yaw)


func _paused() -> bool:
	var m := _main()
	if m == null:
		return false
	var ts: Variant = m.get("time_scale")
	return ts != null and float(ts) <= 0.0


func _refresh() -> void:
	var m := _main()
	var hour := 12.0
	var month := 6
	var day := 15
	var real := NAN
	var from_deg := 270.0
	if m != null:
		var dt: Variant = m.get("day_time")
		if dt != null:
			hour = float(dt)
		var mo: Variant = m.get("month")
		if mo != null:
			month = clampi(int(mo), 1, 12)
		var dd: Variant = m.get("day")
		if dd != null:
			day = clampi(int(dd), 1, 31)
		var ws := get_node_or_null("/root/WeatherService")
		if ws != null and ws.has_method("covers"):
			var lat: Variant = m.get("latitude")
			var lon: Variant = m.get("longitude")
			if lat != null and lon != null and bool(ws.call("covers", float(lat), float(lon))):
				real = float(ws.call("wind_speed_ms", month, day, hour))
				if ws.has_method("wind_direction_deg"):
					from_deg = float(ws.call("wind_direction_deg", month, day, hour))
	var specs := _live_specs()
	var v := WindTurbineSource.hub_wind_speed_ms_from_specs(specs, hour, real)
	last_wind_ms = v
	var rc: Variant = specs.get("rpm_curve", [])
	_rpm_target = 0.0 if v > float(specs.get("cut_out_ms", 25.0)) else WindTurbineSource.curve_at(rc as Array, v)
	last_rpm = _rpm_target
	last_w = WindTurbineSource.power_kw_from_graph_specs(specs, hour, real) * 1000.0
	if _builder.yaw_node() != null:
		var down := WindMath.downwind_xz(from_deg)
		var up_world := Vector3(-down.x, 0.0, -down.y)
		var gb := (_builder as Node3D).global_transform.basis if _builder.is_inside_tree() else Basis.IDENTITY
		var ul := gb.inverse() * up_world
		_yaw_target = atan2(-ul.x, -ul.z)
		_have_yaw = true
	if not graph_item_id.is_empty():
		var sgv := ServiceLocator.graph()
		if sgv != null and sgv.has_method("refresh_bound_generator_output"):
			sgv.call("refresh_bound_generator_output", graph_item_id, last_w / 1000.0)


## The bound graph node's specs (the designer's Apply writes there), else the
## record's own design.
func _live_specs() -> Dictionary:
	if not graph_item_id.is_empty():
		var sgv := ServiceLocator.graph()
		if sgv != null:
			var mdl: Variant = sgv.get("model")
			if mdl != null:
				var it: Dictionary = (mdl as GraphModel).get_item(graph_item_id)
				var sp: Dictionary = it.get("specs", {}) as Dictionary
				if sp.get("power_curve_w", null) is Array:
					return sp
	return _specs


func _main() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var m := tree.get_first_node_in_group("main_scene")
	return m if m != null else tree.current_scene
