class_name AuroraSky
extends Node

## The aurora in the world's sky (a Main child). Twice a second it reads the
## sim clock, asks SpaceWeather for that time's Kp (and OVATION near the
## present) and pushes the shared aurora uniforms (core/globe/
## aurora.gdshaderinc) to the sky material: the Kp oval in the Sun's frame,
## the site and its local east / north in the globe frame. The sky shader
## draws it only after dark and under the clouds. Off by the player's pref
## (ui_prefs.cfg [aurora] sky, Settings → Stars & Planets); `brightness`
## scales it.

const PREFS := "user://ui_prefs.cfg"
const BASE_GAIN := 0.12
const TICK_S := 0.5

## Force a Kp (and no OVATION) for checks and the tour; NAN = real data.
var kp_override := NAN

var _acc := 0.0
var _state := {}


static func pref_on() -> bool:
	var cf := ConfigFile.new()
	return cf.load(PREFS) != OK or bool(cf.get_value("aurora", "sky", true))


static func pref_brightness() -> float:
	var cf := ConfigFile.new()
	return 1.0 if cf.load(PREFS) != OK else float(cf.get_value("aurora", "brightness", 1.0))


static func set_prefs(on: bool, brightness: float) -> void:
	var cf := ConfigFile.new()
	cf.load(PREFS)
	cf.set_value("aurora", "sky", on)
	cf.set_value("aurora", "brightness", brightness)
	cf.save(PREFS)


func _process(delta: float) -> void:
	_acc += delta
	if _acc < TICK_S:
		return
	_acc = 0.0
	push_now()


## What the sky was last given: {on, kp, source, ovation, seen}.
func state() -> Dictionary:
	return _state


func push_now() -> void:
	var main := get_parent()
	if main == null or not main.has_method("_sky_material"):
		return
	var mat: ShaderMaterial = main.call("_sky_material")
	if mat == null:
		return
	var on := pref_on()
	if not on:
		mat.set_shader_parameter("aurora_on", false)
		_state = {"on": false}
		return
	var clock: Object = main.get("clock")
	if clock == null:
		return
	var jd := float(clock.call("get_julian_day_utc"))
	var unix := GlobeWeather.unix_from_jd(jd)
	var kp := kp_override
	var source := "override"
	var ov := {}
	if is_nan(kp):
		var sw := get_node_or_null("/root/SpaceWeather") as SpaceWeatherService
		if sw == null:
			mat.set_shader_parameter("aurora_on", false)
			return
		var k := sw.kp_at(unix)
		kp = float(k.kp)
		source = str(k.source)
		ov = sw.ovation_for(unix)
	var lat := float(main.get("latitude"))
	var lon := float(main.get("longitude"))
	var sun := GlobeMath.sun_dir(jd)
	mat.set_shader_parameter("aurora_on", true)
	mat.set_shader_parameter("aurora_kp", kp)
	mat.set_shader_parameter("aurora_pole", AuroraModel.pole_dir())
	mat.set_shader_parameter("aurora_sun", sun)
	mat.set_shader_parameter("aurora_site", GlobeMath.to_unit(lat, lon))
	mat.set_shader_parameter("aurora_east", GlobeMath.east_at(lon))
	mat.set_shader_parameter("aurora_north", GlobeMath.north_at(lat, lon))
	mat.set_shader_parameter("aurora_sky_gain", BASE_GAIN * pref_brightness())
	mat.set_shader_parameter("aurora_use_ovation", not ov.is_empty())
	if not ov.is_empty():
		mat.set_shader_parameter("aurora_ovation", ov.texture)
	_state = {"on": true, "kp": kp, "source": source, "ovation": not ov.is_empty(),
		"seen": AuroraModel.seen_from(lat, lon, kp, sun)}
