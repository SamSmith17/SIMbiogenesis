class_name PrecipitationVfx
extends Node3D

## Rain streaks + snowflake particles (camera-centered volume). Driven by SolarUI.

const PRECIP_THRESHOLD_MMH := 0.01
const RAIN_RATE_HEAVY_MMH := 15.0
const SNOW_RATE_HEAVY_CMH := 2.0
const RAIN_AMOUNT_MAX := 14000
const SNOW_AMOUNT_MAX := 3200
const LERP_SPEED := 5.0
## Half-extents of the 3D spawn box — tall & symmetric so precip fills sky + ground view.
const EMIT_HALF := Vector3(42.0, 58.0, 42.0)
## Symmetric culling AABB (Godot defaults were biased below centre → horizon clip).
const VIS_AABB := AABB(Vector3(-65, -65, -65), Vector3(130, 130, 130))

## --- rain physics (what a given rain rate LOOKS like) ------------------------
## Drop size: Marshall & Palmer (1948) give the median-volume drop diameter
## D0 = 0.89 R^0.21 mm (R in mm/h). The drops you SEE are the big end of the
## distribution, so the drawn diameter is VISIBLE_DROP_FACTOR x D0.
## Fall speed: Atlas, Srivastava & Sekhon (1973), v = 9.65 - 10.3 exp(-0.6 D)
## m/s for D in mm (terminal velocity; drops do not accelerate in the box).
## Count: the water flux is R = N x drop volume x fall speed, so the number of
## visible drops in the air goes as R / (D^3 v) ~ R^0.37 / v, normalised to a
## violent 50 mm/h downpour.
## Rate classes: AMS Glossary — light < 2.5 mm/h, moderate < 7.6, heavy < 50,
## violent beyond (the same bands NpcWeatherGate uses).
const VISIBLE_DROP_FACTOR := 1.6
const RAIN_DENSITY_REF_MMH := 50.0
## Streak length = the distance a drop falls in this time — a camera-shutter
## exposure, so fast heavy drops draw long and slow drizzle draws short.
const STREAK_EXPOSURE_S := 0.05
## Drawn streak width per mm of drop diameter (a 3 mm drop draws ~2.4 cm wide —
## exaggerated over the real 3 mm so drops survive at screen resolution).
const STREAK_WIDTH_PER_MM := 0.011
## Wind at drop height from the 10 m wind: log law, z0 = 3 cm (open ground):
## ln(2/0.03) / ln(10/0.03) = 0.72. Drops reach the air's horizontal speed
## within a few metres, so they travel with it.
const WIND_2M_FACTOR := 0.72
## Rain spawn box round the camera (half extents). Drops live long enough to
## cross it top to bottom at their own fall speed. Kept tight round the eye:
## a drop past ~15 m is sub-pixel anyway, and a big box spread a heavy
## downpour so thin it read as a few stray streaks.
const RAIN_EMIT_HALF := Vector3(13.0, 9.0, 13.0)
const RAIN_SHADER := preload("res://core/rain_streak.gdshader")

var rain_particles: GPUParticles3D
var snow_particles: GPUParticles3D

var _rain_mat: ParticleProcessMaterial
var _snow_mat: ParticleProcessMaterial
var _rain_mesh: QuadMesh
var _rain_mat3d: ShaderMaterial
## Smoothed log rain rate (a 1 mm/h step should not snap the look).
var _rain_log_rate := log(PRECIP_THRESHOLD_MMH)
var _rain_wind_ms := 0.0
var _rain_wind_dir := Vector2.ZERO
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
	rain_particles.lifetime = 4.0
	rain_particles.emitting = false
	# World space: drops keep falling where they are while the player walks
	# through them (they used to ride along with the camera).
	rain_particles.local_coords = false
	rain_particles.visibility_aabb = VIS_AABB

	_rain_mat = ParticleProcessMaterial.new()
	_rain_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_rain_mat.emission_box_extents = RAIN_EMIT_HALF
	_rain_mat.direction = Vector3(0, -1, 0)
	_rain_mat.spread = 1.5
	_rain_mat.initial_velocity_min = 6.0
	_rain_mat.initial_velocity_max = 6.0
	_rain_mat.gravity = Vector3.ZERO
	# Each drop's Y axis follows its velocity; the streak shader draws along it.
	_rain_mat.particle_flag_align_y = true
	_rain_mat.scale_min = 1.0
	_rain_mat.scale_max = 1.0
	rain_particles.process_material = _rain_mat

	_rain_mesh = QuadMesh.new()
	_rain_mesh.size = Vector2.ONE
	_rain_mat3d = ShaderMaterial.new()
	_rain_mat3d.shader = RAIN_SHADER
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


## Drawn (visible) drop diameter in mm at a rain rate. Marshall & Palmer D0.
static func drop_diameter_mm(rate_mmh: float) -> float:
	var r := maxf(rate_mmh, PRECIP_THRESHOLD_MMH) if is_finite(rate_mmh) else PRECIP_THRESHOLD_MMH
	return VISIBLE_DROP_FACTOR * 0.89 * pow(r, 0.21)


## Terminal fall speed (m/s) of a drop of diameter d_mm. Atlas et al. 1973.
static func terminal_velocity_ms(d_mm: float) -> float:
	var d := maxf(d_mm, 0.0) if is_finite(d_mm) else 0.0
	return maxf(9.65 - 10.3 * exp(-0.6 * d), 0.5)


## Visible drops in the air relative to a violent 50 mm/h downpour (0..1).
static func rain_density_ratio(rate_mmh: float) -> float:
	if not is_finite(rate_mmh) or rate_mmh <= PRECIP_THRESHOLD_MMH:
		return 0.0
	var f := func(r: float) -> float:
		return pow(r, 0.37) / terminal_velocity_ms(drop_diameter_mm(r))
	return clampf(float(f.call(rate_mmh)) / float(f.call(RAIN_DENSITY_REF_MMH)), 0.0, 1.0)


## AMS rain-rate class name.
static func rain_class(rate_mmh: float) -> String:
	if not is_finite(rate_mmh) or rate_mmh <= PRECIP_THRESHOLD_MMH:
		return "none"
	if rate_mmh < 2.5:
		return "light"
	if rate_mmh < 7.6:
		return "moderate"
	if rate_mmh < 50.0:
		return "heavy"
	return "violent"


## Everything the rain draws at a rate and a 10 m wind (m/s) blowing toward
## `wind_dir_xz` (unit, world XZ): drop diameter, fall speed, the drop's full
## velocity (slanted by the wind), streak size, how many drops and how opaque.
## Pure, so the look is pinned offline.
static func rain_look(rate_mmh: float, wind10_ms: float, wind_dir_xz: Vector2) -> Dictionary:
	var d := drop_diameter_mm(rate_mmh)
	var vt := terminal_velocity_ms(d)
	var w := maxf(wind10_ms, 0.0) * WIND_2M_FACTOR if is_finite(wind10_ms) else 0.0
	var dir := wind_dir_xz.normalized() if wind_dir_xz.length() > 0.001 else Vector2.ZERO
	var vel := Vector3(dir.x * w, -vt, dir.y * w)
	var speed := vel.length()
	var density := rain_density_ratio(rate_mmh)
	return {
		"class": rain_class(rate_mmh),
		"diameter_mm": d,
		"fall_ms": vt,
		"velocity": vel,
		"speed_ms": speed,
		"slant_deg": rad_to_deg(atan2(w, vt)),
		"width_m": d * STREAK_WIDTH_PER_MM,
		"length_m": speed * STREAK_EXPOSURE_S,
		"density": density,
		# Bigger drops are more opaque; a curtain of them reads denser still.
		"alpha": clampf(0.22 + 0.11 * d + 0.25 * density, 0.0, 0.9),
	}


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
## `wind_ms` is the 10 m wind speed; 0 (the old callers) means still air.
func update_frame(delta: float, kind: String, rate_mmh: float, snowfall_cmh: float,
		wind_down: Vector2, follow_pos: Vector3, wind_ms: float = 0.0) -> void:
	_active_kind = kind
	global_position = follow_pos
	_rain_wind_ms = wind_ms if is_finite(wind_ms) else 0.0
	_rain_wind_dir = wind_down

	var wind3 := Vector3(wind_down.x, -1.0, wind_down.y).normalized()

	if kind == "rain":
		snow_particles.emitting = false
		snow_particles.amount_ratio = 0.0
		rain_particles.emitting = true
		if _rain_blend < 0.05:
			_rain_blend = rain_intensity_t(rate_mmh) * 0.65
			_rain_log_rate = log(maxf(rate_mmh, PRECIP_THRESHOLD_MMH))
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


func _update_rain(delta: float, rate_mmh: float, _wind3: Vector3) -> void:
	var target_t := rain_intensity_t(rate_mmh)
	var k := 1.0 - exp(-delta * LERP_SPEED)
	_rain_blend = lerpf(_rain_blend, target_t, k)
	if rate_mmh <= PRECIP_THRESHOLD_MMH:
		return
	_rain_log_rate = lerpf(_rain_log_rate, log(maxf(rate_mmh, PRECIP_THRESHOLD_MMH)), k)
	var look := rain_look(exp(_rain_log_rate), _rain_wind_ms, _rain_wind_dir)
	var vel: Vector3 = look["velocity"]
	var speed := float(look["speed_ms"])
	# Fade in with the blend so rain starting does not pop on.
	rain_particles.amount_ratio = clampf(float(look["density"]), 0.04, 1.0) * clampf(_rain_blend / 0.3, 0.0, 1.0)
	_rain_mat.direction = vel / maxf(speed, 0.001)
	_rain_mat.initial_velocity_min = speed
	_rain_mat.initial_velocity_max = speed * 1.08
	# Long enough to cross the box top to bottom at the fall speed. Changing
	# lifetime restarts the emitter, so only on a real change.
	var life := clampf(2.0 * RAIN_EMIT_HALF.y / float(look["fall_ms"]), 1.5, 12.0)
	if absf(rain_particles.lifetime - life) > life * 0.1:
		rain_particles.lifetime = life
	_rain_mat3d.set_shader_parameter("streak_width", float(look["width_m"]))
	_rain_mat3d.set_shader_parameter("streak_length", float(look["length_m"]))
	_rain_mat3d.set_shader_parameter("drop_color", Color(0.90, 0.93, 0.98, float(look["alpha"])))


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
