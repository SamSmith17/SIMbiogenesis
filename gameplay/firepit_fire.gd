class_name FirepitFire
extends Node3D

## The small fire in a placed FIREPIT (FirepitBuilder). It burns while
## `FirepitBuilder.lit_for(record, env_now)` says so — by default at night,
## when the air is cold — which is the same question the crowd asks, so people
## gather round exactly the pits that are burning.
##
## Flames + sparks are GPU particles and the warmth is one OmniLight3D (no
## shadows), all on the FIRE cosmetic clock (SimFxRate): the flames dance
## faster as the sim speeds up (capped), and hang dead still while paused.
## Lighting and dying are eased over a couple of seconds rather than popped.

const _POLL_S := 1.0
const _EASE_S := 1.6
const _FLAME_AMOUNT := 48
const _SPARK_AMOUNT := 10
const _LIGHT_ENERGY := 2.2
const _LIGHT_RANGE_M := 7.5
const _LIGHT_FADE_M := 60.0

var prop_id := ""
var _main: Node = null
var _flames: GPUParticles3D
var _sparks: GPUParticles3D
var _light: OmniLight3D
var _ash_mat: StandardMaterial3D = null
var _lit := false
var _level := 0.0
var _poll := 999.0
var _flick := 0.0


func configure(id: String) -> void:
	prop_id = id


func _ready() -> void:
	_main = _find_main()
	_build()


func _find_main() -> Node:
	var n: Node = self
	while n != null:
		if n.has_method("get_absolute_hours"):
			return n
		n = n.get_parent()
	return get_tree().root.find_child("Main", true, false) if get_tree() != null else null


func _build() -> void:
	var y := FirepitBuilder.ASH_Y_M + 0.06
	_flames = _make_particles("Flames", _FLAME_AMOUNT, 0.8, 0.34,
		Color(1.0, 0.86, 0.45, 0.95), Color(1.0, 0.42, 0.08, 0.7), Color(0.5, 0.08, 0.02, 0.0))
	var fm := _flames.process_material as ParticleProcessMaterial
	fm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	fm.emission_sphere_radius = 0.2
	fm.direction = Vector3.UP
	fm.spread = 12.0
	fm.initial_velocity_min = 0.6
	fm.initial_velocity_max = 1.15
	fm.gravity = Vector3(0.0, 0.6, 0.0)
	fm.scale_min = 0.7
	fm.scale_max = 1.25
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.55))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1.0, 0.15))
	var ct := CurveTexture.new()
	ct.curve = curve
	fm.scale_curve = ct
	_flames.position = Vector3(0.0, y, 0.0)
	add_child(_flames)

	_sparks = _make_particles("Sparks", _SPARK_AMOUNT, 1.6, 0.035,
		Color(1.0, 0.8, 0.4, 1.0), Color(1.0, 0.45, 0.1, 0.9), Color(0.6, 0.1, 0.0, 0.0))
	var sm := _sparks.process_material as ParticleProcessMaterial
	sm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	sm.emission_sphere_radius = 0.12
	sm.direction = Vector3.UP
	sm.spread = 25.0
	sm.initial_velocity_min = 1.0
	sm.initial_velocity_max = 2.2
	sm.gravity = Vector3(0.0, -0.4, 0.0)
	sm.turbulence_enabled = true
	sm.turbulence_noise_strength = 0.6
	_sparks.position = Vector3(0.0, y + 0.1, 0.0)
	add_child(_sparks)

	_light = OmniLight3D.new()
	_light.name = "Warmth"
	_light.light_color = Color(1.0, 0.56, 0.22)
	_light.omni_range = _LIGHT_RANGE_M
	_light.omni_attenuation = 1.6
	_light.shadow_enabled = false
	_light.light_energy = 0.0
	_light.distance_fade_enabled = true
	_light.distance_fade_begin = _LIGHT_FADE_M
	_light.distance_fade_length = 20.0
	_light.position = Vector3(0.0, 0.7, 0.0)
	_light.visible = false
	add_child(_light)

	var ash := get_parent().find_child("Ash", true, false) as MeshInstance3D if get_parent() != null else null
	if ash != null and ash.material_override is StandardMaterial3D:
		# A per-pit duplicate: the glow is this pit's own.
		_ash_mat = (ash.material_override as StandardMaterial3D).duplicate()
		ash.material_override = _ash_mat


func _make_particles(nm: String, amount: int, life: float, size: float,
		c0: Color, c1: Color, c2: Color) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = nm
	p.amount = amount
	p.amount_ratio = 0.0
	p.lifetime = life
	p.emitting = false
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-2, -1, -2), Vector3(4, 5, 4))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	var grad := Gradient.new()
	grad.set_color(0, c0)
	grad.set_color(1, c2)
	grad.add_point(0.45, c1)
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size * 1.4)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	qm.vertex_color_use_as_albedo = true
	# HDR: above 1.0 the glow pass blooms it — a fire reads as a light source,
	# not a smudge of orange.
	qm.albedo_color = Color(3.0, 2.6, 2.2)
	qm.cull_mode = BaseMaterial3D.CULL_DISABLED
	qm.disable_fog = true
	var soft := GradientTexture2D.new()
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(1.0, 0.5)
	var sg := Gradient.new()
	sg.set_color(0, Color(1, 1, 1, 1))
	sg.set_color(1, Color(1, 1, 1, 0))
	soft.gradient = sg
	soft.width = 32
	soft.height = 32
	qm.albedo_texture = soft
	quad.material = qm
	p.draw_pass_1 = quad
	return p


func _process(delta: float) -> void:
	_poll += delta
	if _poll >= _POLL_S:
		_poll = 0.0
		_refresh()
	var rate := SimFxRate.rate(_main, SimFxRate.SYS_FIRE) if _main != null else 1.0
	var target := 1.0 if _lit else 0.0
	_level = move_toward(_level, target, delta / _EASE_S)
	var on := _level > 0.001
	_flames.emitting = on
	_sparks.emitting = on
	_flames.amount_ratio = _level
	_sparks.amount_ratio = _level
	_flames.speed_scale = rate
	_sparks.speed_scale = rate
	_light.visible = on
	if on:
		_flick += delta * rate
		var f := 0.82 + 0.1 * sin(_flick * 11.0) + 0.08 * sin(_flick * 23.7 + 1.3)
		_light.light_energy = _LIGHT_ENERGY * _level * f
	if _ash_mat != null:
		_ash_mat.emission_energy_multiplier = 1.4 * _level


func _refresh() -> void:
	if _main == null or prop_id.is_empty():
		return
	var rec := PlacedPropService.get_prop_record(_main, prop_id)
	_lit = FirepitBuilder.lit_for(rec, FirepitBuilder.env_now(_main))


## For harnesses / the prop editor: is it burning (or catching)?
func is_lit() -> bool:
	return _lit
