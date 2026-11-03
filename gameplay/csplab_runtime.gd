class_name CspLabRuntime
extends Node

## A placed concentrator from the solar concentrator designer, alive in the
## world: twice a second it reads the sun from the world clock (Meeus SPA,
## the same sun the graph's tick uses) and turns the builder to face it the
## way its mount would — two-axis pedestals, one-axis troughs, every mirror
## row or heliostat of a field (CspLabBuilder.set_sun). Below the horizon it
## stows. Attached by PlacedPropRuntime to any prop whose model_id is
## CspLabBuilder.MODEL_ID; the heat itself is the graph node's
## (SystemGraphView._tick_graph_csplab).

const _POLL_S := 0.5
## A field re-meshes its mirrors per sun; skip a move smaller than this.
const _MIN_MOVE := 0.0015

var _builder: CspLabBuilder = null
var _poll := 999.0
var last_sun := Vector3.ZERO


static func attach(prop: Node3D, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != CspLabBuilder.MODEL_ID or prop.get_node_or_null("CspLabRuntime") != null:
		return
	var rt := CspLabRuntime.new()
	rt.name = "CspLabRuntime"
	prop.add_child(rt)


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	var p := get_parent()
	if p == null:
		return
	for n in p.find_children("*", "Node3D", true, false):
		if n is CspLabBuilder:
			_builder = n as CspLabBuilder
			break


func _process(delta: float) -> void:
	if _builder == null or not is_instance_valid(_builder):
		return
	_poll += delta
	if _poll < _POLL_S:
		return
	_poll = 0.0
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		return
	var clock_obj: Variant = main.get("clock")
	if clock_obj == null or not (clock_obj as Object).has_method("get_julian_day_utc"):
		return
	var la: Variant = main.get("latitude")
	var lo: Variant = main.get("longitude")
	var lat := float(la) if la != null else 35.0
	var lon := float(lo) if lo != null else -115.0
	var sp := SolarPosition.get_position(lat, lon, float((clock_obj as Object).call("get_julian_day_utc")))
	var s := CspLabSite.sun_world(float(sp.get("azimuth_deg", 180.0)), float(sp.get("elevation_deg", -10.0)))
	# The prop may be turned: the builder's frame is the prop's.
	var gb := _builder.global_transform.basis.orthonormalized()
	var s_local := gb.transposed() * s
	if s_local.distance_to(last_sun) < _MIN_MOVE:
		return
	last_sun = s_local
	_builder.lat = lat
	_builder.set_sun(s_local)
