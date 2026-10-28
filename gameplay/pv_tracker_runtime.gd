class_name PvTrackerRuntime
extends Node

## Turns a placed designed solar array's tracker heads to follow the sun
## (PvLabTracker: true tracking, backtracking, rotation limits, stowing flat
## at night and in high wind). Visual: the graph's energy model computes the
## same angle for itself at every instant (PvLabTracker.angle_at), so a
## render or a bake never reads this node.
##
## Sim-time aware like CspTroughTracker: it eases toward the target on real
## time AND elapsed sim hours (whichever moves it more), so it is smooth at 1×
## and stays on the sun at speed; a jump over half a sim hour (a scrub) lands
## at once.

const TRACK_TAU_REAL := 0.8
const TRACK_TAU_SIM := 0.04
const SNAP_SIM_HOURS := 0.5

var _array: Node3D = null
var _spec: Dictionary = {}
var _gcr := 0.0
var _angle := 0.0
var _target := 0.0
var _last_abs := NAN
var _sim_dh := 0.0
var _acc := 0.0


static func attach(prop: Node3D, rec: Dictionary) -> void:
	var spec: Variant = rec.get("pvlab_spec")
	if not (spec is Dictionary):
		return
	var s := PvLabSpec.resolve(spec as Dictionary)
	if str(s["array"]["mount"]) != "tracker":
		return
	var rt := PvTrackerRuntime.new()
	rt.name = "PvTrackerRuntime"
	rt._spec = s
	prop.add_child(rt)


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	var stack: Array = [get_parent()]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and n.has_meta("pvlab_spec"):
			_array = n as Node3D
			break
		for c in n.get_children():
			stack.append(c)
	if _array == null:
		return
	_gcr = float(PvLabDesign.solve(_spec)["layout"]["gcr"])
	_angle = PvLabBuilder.tracker_angle(_array)


func _process(delta: float) -> void:
	if _array == null or not is_instance_valid(_array):
		return
	PerfSpan.begin("prop_ticks")
	_refresh_target(delta)
	if absf(_sim_dh) > SNAP_SIM_HOURS:
		_angle = _target
	else:
		var x := delta / TRACK_TAU_REAL + absf(_sim_dh) / TRACK_TAU_SIM
		_angle = lerpf(_angle, _target, clampf(1.0 - exp(-x), 0.0, 1.0))
	if absf(_angle - PvLabBuilder.tracker_angle(_array)) > 0.01:
		PvLabBuilder.set_tracker_angle(_array, _angle)
	PerfSpan.end("prop_ticks")


func _refresh_target(delta: float) -> void:
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		return
	var clock_obj: Variant = main.get("clock")
	_sim_dh = 0.0
	if clock_obj is Object and (clock_obj as Object).has_method("get_absolute_hours"):
		var cur := float((clock_obj as Object).call("get_absolute_hours"))
		if is_finite(_last_abs):
			_sim_dh = cur - _last_abs
		_last_abs = cur
	# The sun moves slowly: a new target 4 times a second, or at once on a jump.
	_acc += delta
	if _acc < 0.25 and absf(_sim_dh) <= SNAP_SIM_HOURS:
		return
	_acc = 0.0
	if not (clock_obj is Object and (clock_obj as Object).has_method("get_julian_day_utc")):
		return
	var lat := float(main.get("latitude")) if main.get("latitude") != null else 45.0
	var lon := float(main.get("longitude")) if main.get("longitude") != null else 0.0
	var sp := SolarPosition.get_position(lat, lon, float((clock_obj as Object).call("get_julian_day_utc")))
	var wind := 0.0
	var ws := get_tree().root.get_node_or_null("/root/WeatherService")
	if ws != null and ws.has_method("wind_speed_ms"):
		var hour := float(main.get("day_time")) if main.get("day_time") != null else 12.0
		var mo := int(main.get("month")) if main.get("month") != null else 6
		var dd := int(main.get("day")) if main.get("day") != null else 15
		wind = float(ws.call("wind_speed_ms", mo, dd, hour))
	_target = PvLabTracker.angle_at(float(sp.get("azimuth_deg", 180.0)), float(sp.get("elevation_deg", -10.0)),
		axis_azimuth(_array), _spec["tracker"], _gcr, wind)


## The compass azimuth the tracker's axis (the array's local +Z) points to.
static func axis_azimuth(array_node: Node3D) -> float:
	var z := array_node.global_transform.basis.z
	if Vector2(z.x, z.z).length() < 1e-5:
		return 180.0
	return fposmod(rad_to_deg(atan2(z.x, -z.z)), 360.0)
