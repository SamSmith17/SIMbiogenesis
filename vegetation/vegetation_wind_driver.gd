extends Node

## Pushes live weather wind uniforms to registered vegetation ShaderMaterials (~4 Hz).

const UPDATE_INTERVAL := 0.25
const LERP_SPEED := 0.35
const CALM_SPEED_MS := 1.5

const FOLIAGE_SHADER := "res://vegetation/foliage.gdshader"
const LEAF_CANOPY_SHADER := "res://vegetation/leaf_canopy.gdshader"
const BARK_SHADER := "res://vegetation/bark.gdshader"
## Grass includes wind_vertex.gdshaderinc and the impostor has its own sway —
## both were missing from this accept-list, so grass swayed at the build-time
## default forever and the far forest sat frozen while a storm thrashed the
## near trees.
const GRASS_SHADER := "res://vegetation/grass.gdshader"
const IMPOSTOR_SHADER := "res://vegetation/veg_impostor.gdshader"

var _materials: Array[ShaderMaterial] = []
var _accum := 0.0
var _current_speed := CALM_SPEED_MS
var _current_gust := 0.0
var _current_dir := Vector2(0.0, 1.0)
var _target_speed := CALM_SPEED_MS
var _target_gust := 0.0
var _target_dir := Vector2(0.0, 1.0)


func clear_registered_materials() -> void:
	_materials.clear()


func register_material(mat: Material) -> void:
	if mat == null or not (mat is ShaderMaterial):
		return
	var sm := mat as ShaderMaterial
	if sm.shader == null or sm in _materials:
		return
	var path := sm.shader.resource_path
	if path != FOLIAGE_SHADER and path != LEAF_CANOPY_SHADER \
			and path != BARK_SHADER and path != GRASS_SHADER \
			and path != IMPOSTOR_SHADER:
		return
	_materials.append(sm)


func register_mesh(mesh: Mesh) -> void:
	if mesh == null:
		return
	for i in mesh.get_surface_count():
		register_material(mesh.surface_get_material(i))


func register_multimesh_instance(mi: MultiMeshInstance3D) -> void:
	if mi == null:
		return
	register_material(mi.material_override)
	if mi.multimesh != null:
		register_mesh(mi.multimesh.mesh)


func register_mesh_instance(mi: MeshInstance3D) -> void:
	if mi == null:
		return
	register_material(mi.material_override)
	if mi.mesh != null:
		register_mesh(mi.mesh)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_accum += delta
	var step := clampf(delta * LERP_SPEED / maxf(UPDATE_INTERVAL, 0.01), 0.0, 1.0)
	_current_speed = lerpf(_current_speed, _target_speed, step)
	_current_gust = lerpf(_current_gust, _target_gust, step)
	_current_dir = _current_dir.lerp(_target_dir, step)
	if _current_dir.length_squared() > 1e-6:
		_current_dir = _current_dir.normalized()
	if _accum < UPDATE_INTERVAL:
		return
	_accum = 0.0
	_poll_weather()
	_push_uniforms()


func _poll_weather() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var main: Node = tree.get_first_node_in_group("main_scene")
	if main == null:
		return
	var month := int(main.get("month")) if main.get("month") != null else 6
	var day := int(main.get("day")) if main.get("day") != null else 15
	var hour := float(main.get("day_time")) if main.get("day_time") != null else 12.0

	var speed := CALM_SPEED_MS
	if WeatherService.has_method("wind_speed_ms"):
		var ws := float(WeatherService.wind_speed_ms(month, day, hour))
		if is_finite(ws) and not is_nan(ws):
			speed = maxf(ws, 0.0)

	var gust := speed * 1.2
	if WeatherService.has_method("wind_gust_ms"):
		var gs := float(WeatherService.wind_gust_ms(month, day, hour))
		if is_finite(gs) and not is_nan(gs):
			gust = maxf(gs, speed)

	# Extreme weather multiplies in AFTER the measured base. blank() carries
	# wind_mult/gust_mult 1.0, so ordinary weather stays bit-identical (the
	# HazardState identity invariant); a severity-1 damaging-winds event is
	# 2.6×/3.0× and finally reaches the canopy. Pure rule + rationale:
	# WindMath.apply_hazard_wind (selftest-pinned). The existing LERP_SPEED
	# easing above ramps a storm in rather than snapping.
	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw != null and xw.has_method("current"):
		var hz: Variant = xw.call("current")
		if hz is Dictionary and not (hz as Dictionary).is_empty():
			var sg := WindMath.apply_hazard_wind(speed, gust, hz)
			speed = sg.x
			gust = sg.y
	# The site's microclimate VISUAL wind (a calibrated "the playa blows harder
	# than the data says" look). Physics wind corrections are already inside
	# WeatherService.wind_speed_ms above; this is the visual-only multiplier.
	var mc := get_node_or_null("/root/Microclimate")
	if mc != null and mc.has_method("current"):
		var st: Dictionary = mc.call("current")
		var m := float(st.get("wind_vis_mult", 1.0))
		if is_finite(m) and absf(m - 1.0) > 0.001:
			speed *= maxf(m, 0.0)
			gust *= maxf(m, 0.0)

	var gust_excess := maxf(gust - speed, 0.0)
	_target_gust = clampf(gust_excess / maxf(speed, 2.0), 0.0, 1.0)
	_target_speed = speed

	var from_deg := NAN
	if WeatherService.has_method("wind_direction_deg"):
		from_deg = float(WeatherService.wind_direction_deg(month, day, hour))
	_target_dir = WindMath.downwind_xz(from_deg)


static func _downwind_xz(from_deg: float) -> Vector2:
	return WindMath.downwind_xz(from_deg)


func _push_uniforms() -> void:
	var dir := _current_dir
	var i := 0
	while i < _materials.size():
		var sm := _materials[i]
		if not is_instance_valid(sm):
			_materials.remove_at(i)
			continue
		sm.set_shader_parameter("wind_speed_ms", _current_speed)
		sm.set_shader_parameter("gust_intensity", _current_gust)
		sm.set_shader_parameter("wind_direction", dir)
		i += 1
