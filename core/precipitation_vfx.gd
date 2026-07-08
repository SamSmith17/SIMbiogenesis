class_name PrecipitationVfx
extends Node3D

## Rain streaks + snowflake particles (camera-centered volume). Driven by SolarUI.

const PRECIP_THRESHOLD_MMH := 0.01
const RAIN_RATE_HEAVY_MMH := 15.0
const SNOW_RATE_HEAVY_CMH := 2.0
const RAIN_AMOUNT_MAX := 5000
const SNOW_AMOUNT_MAX := 3200
const LERP_SPEED := 5.0
## Half-extents of the 3D spawn box — tall & symmetric so precip fills sky + ground view.
const EMIT_HALF := Vector3(42.0, 58.0, 42.0)
## Symmetric culling AABB (Godot defaults were biased below centre → horizon clip).
const VIS_AABB := AABB(Vector3(-65, -65, -65), Vector3(130, 130, 130))

var rain_particles: GPUParticles3D
var snow_particles: GPUParticles3D

var _rain_mat: ParticleProcessMaterial
var _snow_mat: ParticleProcessMaterial
var _rain_mesh: QuadMesh
var _rain_mat3d: StandardMaterial3D
var _snow_mesh: QuadMesh
var _snow_mat3d: StandardMaterial3D
var _rain_blend := 0.0
var _snow_blend := 0.0
var _active_kind := "none"


func _ready() -> void:
	_setup_rain()
	_setup_snow()


func _setup_rain() -> void:
	rain_particles = GPUParticles3D.new()
	rain_particles.name = "RainParticles"
	rain_particles.amount = RAIN_AMOUNT_MAX
	rain_particles.amount_ratio = 0.0
	rain_particles.lifetime = 2.2
	rain_particles.emitting = false
	rain_particles.local_coords = true
	rain_particles.visibility_aabb = VIS_AABB

	_rain_mat = ParticleProcessMaterial.new()
	_rain_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_rain_mat.emission_box_extents = EMIT_HALF
	_rain_mat.direction = Vector3(0, -1, 0)
	_rain_mat.spread = 8.0
	_rain_mat.initial_velocity_min = 15.0
	_rain_mat.initial_velocity_max = 25.0
	_rain_mat.gravity = Vector3(0, -15, 0)
	_rain_mat.scale_min = 0.02
	_rain_mat.scale_max = 0.04
	rain_particles.process_material = _rain_mat

	_rain_mesh = QuadMesh.new()
	_rain_mesh.size = Vector2(0.02, 0.3)
	_rain_mat3d = StandardMaterial3D.new()
	_rain_mat3d.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rain_mat3d.albedo_color = Color(0.88, 0.92, 1.0, 0.72)
	_rain_mat3d.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rain_mat3d.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	_rain_mat3d.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rain_mat3d.no_depth_test = true
	_rain_mesh.material = _rain_mat3d
	rain_particles.draw_pass_1 = _rain_mesh
	add_child(rain_particles)


func _setup_snow() -> void:
	snow_particles = GPUParticles3D.new()
	snow_particles.name = "SnowParticles"
	snow_particles.amount = SNOW_AMOUNT_MAX
	snow_particles.amount_ratio = 0.0
	snow_particles.lifetime = 10.0
	snow_particles.emitting = false
	snow_particles.local_coords = true
	snow_particles.visibility_aabb = VIS_AABB

	_snow_mat = ParticleProcessMaterial.new()
	_snow_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_snow_mat.emission_box_extents = EMIT_HALF
	_snow_mat.direction = Vector3(0, -1, 0)
	_snow_mat.spread = 50.0
	_snow_mat.initial_velocity_min = 0.6
	_snow_mat.initial_velocity_max = 1.8
	_snow_mat.gravity = Vector3(0, -1.2, 0)
	_snow_mat.angular_velocity_min = -2.5
	_snow_mat.angular_velocity_max = 2.5
	_snow_mat.scale_min = 0.03
	_snow_mat.scale_max = 0.07
	snow_particles.process_material = _snow_mat

	_snow_mesh = QuadMesh.new()
	_snow_mesh.size = Vector2(0.045, 0.045)
	_snow_mat3d = StandardMaterial3D.new()
	_snow_mat3d.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_snow_mat3d.albedo_color = Color(0.98, 0.99, 1.0, 0.88)
	_snow_mat3d.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_snow_mat3d.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_snow_mat3d.cull_mode = BaseMaterial3D.CULL_DISABLED
	_snow_mat3d.no_depth_test = true
	_snow_mesh.material = _snow_mat3d
	snow_particles.draw_pass_1 = _snow_mesh
	add_child(snow_particles)


static func rain_intensity_t(rate_mmh: float) -> float:
	if rate_mmh <= PRECIP_THRESHOLD_MMH:
		return 0.0
	var lo := log(maxf(PRECIP_THRESHOLD_MMH, 0.001))
	var hi := log(RAIN_RATE_HEAVY_MMH)
	return clampf((log(maxf(rate_mmh, PRECIP_THRESHOLD_MMH)) - lo) / (hi - lo), 0.0, 1.0)


static func snow_intensity_t(rate_cmh: float) -> float:
	if rate_cmh <= 0.01:
		return 0.0
	var lo := log(0.01)
	var hi := log(SNOW_RATE_HEAVY_CMH)
	return clampf((log(maxf(rate_cmh, 0.01)) - lo) / (hi - lo), 0.0, 1.0)


## kind: "none" | "rain" | "snow"
func update_frame(delta: float, kind: String, rate_mmh: float, snowfall_cmh: float,
		wind_down: Vector2, follow_pos: Vector3) -> void:
	_active_kind = kind
	global_position = follow_pos

	var wind3 := Vector3(wind_down.x, -1.0, wind_down.y).normalized()

	if kind == "rain":
		snow_particles.emitting = false
		snow_particles.amount_ratio = 0.0
		rain_particles.emitting = true
		if _rain_blend < 0.05:
			_rain_blend = rain_intensity_t(rate_mmh) * 0.65
		_update_rain(delta, rate_mmh, wind3)
	elif kind == "snow":
		rain_particles.emitting = false
		rain_particles.amount_ratio = 0.0
		snow_particles.emitting = true
		if _snow_blend < 0.05:
			_snow_blend = snow_intensity_t(snowfall_cmh) * 0.65
		_update_snow(delta, snowfall_cmh, wind3)
	else:
		rain_particles.emitting = false
		snow_particles.emitting = false
		_update_rain(delta, 0.0, wind3)
		_update_snow(delta, 0.0, wind3)
		rain_particles.amount_ratio = 0.0
		snow_particles.amount_ratio = 0.0


func _update_rain(delta: float, rate_mmh: float, wind3: Vector3) -> void:
	var target_t := rain_intensity_t(rate_mmh)
	_rain_blend = lerpf(_rain_blend, target_t, 1.0 - exp(-delta * LERP_SPEED))
	var t := _rain_blend
	var density_t := pow(t, 0.65)
	rain_particles.amount_ratio = lerpf(0.18, 1.0, density_t)
	rain_particles.lifetime = lerpf(1.8, 2.4, t)
	_rain_mat.direction = wind3
	_rain_mat.initial_velocity_min = lerpf(12.0, 30.0, t)
	_rain_mat.initial_velocity_max = lerpf(22.0, 42.0, t)
	_rain_mat.gravity = Vector3(0, lerpf(-14.0, -24.0, t), 0)
	_rain_mat.scale_min = lerpf(0.018, 0.04, t)
	_rain_mat.scale_max = lerpf(0.032, 0.065, t)
	_rain_mesh.size = Vector2(lerpf(0.018, 0.036, t), lerpf(0.32, 0.58, t))
	var col := _rain_mat3d.albedo_color
	col.a = lerpf(0.55, 0.9, t)
	_rain_mat3d.albedo_color = col


func _update_snow(delta: float, rate_cmh: float, wind3: Vector3) -> void:
	var target_t := snow_intensity_t(rate_cmh)
	_snow_blend = lerpf(_snow_blend, target_t, 1.0 - exp(-delta * LERP_SPEED))
	var t := _snow_blend
	# Density ramps faster than linear so moderate snowfall already feels substantial.
	var density_t := pow(t, 0.45)
	snow_particles.amount_ratio = lerpf(0.1, 1.0, density_t)
	# Heavier snow: shorter lifetime (flakes cross the view faster) + higher terminal speed.
	snow_particles.lifetime = lerpf(14.0, 5.5, t)
	var drift := Vector3(wind3.x * lerpf(0.15, 0.35, t), -1.0, wind3.z * lerpf(0.15, 0.35, t)).normalized()
	_snow_mat.direction = drift
	_snow_mat.spread = lerpf(58.0, 26.0, t)
	_snow_mat.initial_velocity_min = lerpf(0.3, 2.4, t)
	_snow_mat.initial_velocity_max = lerpf(0.85, 6.0, t)
	_snow_mat.gravity = Vector3(0, lerpf(-0.35, -5.0, t), 0)
	_snow_mat.angular_velocity_min = lerpf(-1.8, -4.5, t)
	_snow_mat.angular_velocity_max = lerpf(1.8, 4.5, t)
	_snow_mat.scale_min = lerpf(0.018, 0.08, t)
	_snow_mat.scale_max = lerpf(0.038, 0.18, t)
	var flake_sz := lerpf(0.028, 0.15, t)
	_snow_mesh.size = Vector2.ONE * flake_sz
	var col := _snow_mat3d.albedo_color
	col.a = lerpf(0.5, 0.98, t)
	_snow_mat3d.albedo_color = col
