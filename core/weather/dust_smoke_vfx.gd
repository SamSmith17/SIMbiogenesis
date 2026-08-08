class_name DustSmokeVfx
extends Node3D

## Camera-following dust particles for extreme-weather hazards.
##
## Sibling of core/precipitation_vfx.gd and built the same way: a long-lived
## emitter that is never destroyed, modulated by `amount_ratio` and blended with
## a frame-rate-independent ease. Creating and freeing emitters as weather
## changes would hitch, and a hazard can flicker across a threshold.
##
## Why particles at all, when the volumetric fog already colours the air: the
## fog tells you the air is full of something, but only near-field motion tells
## you it is BLOWING. Dust especially reads as a painted backdrop without grains
## streaking past the camera.
##
## Wildfire smoke deliberately gets NO particle system — an earlier version
## emitted slow-drifting "ash" grains, but at night (or any time the emissive
## bloom picks them up) they read as sparks, which is the wrong image for smoke
## that is mostly just thick, hazy air. The fog/haze the atmosphere applier
## already produces is sufficient; a real ember shower belongs to fire, not to
## the smoke plume downwind of one.
##
## The intensity mapping is a pure static function so the selftest can pin it
## without a scene tree — the VegLeafFall.is_drop_window precedent.

const DUST_AMOUNT_MAX := 2600
const LERP_SPEED := 2.5

## Spawn volume around the camera. Wider than precipitation's and shallower:
## airborne dust fills the horizontal view, it does not fall from above.
const EMIT_HALF := Vector3(48.0, 26.0, 48.0)
## Symmetric so the culling box cannot clip the horizon (the bias bug
## PrecipitationVfx documents).
const VIS_AABB := AABB(Vector3(-70, -70, -70), Vector3(140, 140, 140))

## Dust below this severity is suspended haze the fog already expresses; grains
## only appear once it is genuinely being driven.
const DUST_VISIBLE_FROM := 0.25

var dust_particles: GPUParticles3D

var _dust_mat: ParticleProcessMaterial
var _dust_blend := 0.0
var _kind := ""


func _ready() -> void:
	_setup_dust()


## 0..1 emitter fill for a hazard. Pure and static so it is selftest-pinnable.
## Dust is driven, so it scales with wind as well as with severity.
static func dust_intensity_t(severity: float, wind_mult: float) -> float:
	if not is_finite(severity) or not is_finite(wind_mult):
		return 0.0
	var s := clampf((severity - DUST_VISIBLE_FROM) / (1.0 - DUST_VISIBLE_FROM), 0.0, 1.0)
	var w := clampf((wind_mult - 1.0) / 1.0, 0.0, 1.0)
	return clampf(s * lerpf(0.35, 1.0, w), 0.0, 1.0)


## Driven from main.gd once per frame. `wind_dir` is the world-space direction
## the air is moving, already scaled by speed.
func update_frame(delta: float, hz: Dictionary, wind_dir: Vector3,
		follow_pos: Vector3) -> void:
	global_position = follow_pos
	var kind := str(hz.get("particle_kind", ""))
	var sev := float(hz.get("severity", 0.0))
	if not is_finite(sev):
		sev = 0.0
	_kind = kind

	var dust_target := dust_intensity_t(sev, float(hz.get("wind_mult", 1.0))) \
		if kind == "dust" else 0.0
	# Frame-rate independent ease, matching PrecipitationVfx.
	var t := 1.0 - exp(-delta * LERP_SPEED)
	_dust_blend = lerpf(_dust_blend, dust_target, t)

	_apply(dust_particles, _dust_mat, _dust_blend, wind_dir, hz)


func _apply(p: GPUParticles3D, mat: ParticleProcessMaterial, blend: float,
		wind: Vector3, hz: Dictionary) -> void:
	if p == null or not is_instance_valid(p):
		return
	if blend <= 0.002:
		if p.emitting:
			p.emitting = false
		return
	if not p.emitting:
		p.emitting = true
	p.amount_ratio = clampf(blend, 0.0, 1.0)
	if mat != null:
		# Grains travel WITH the air, so the wind vector is the gravity term —
		# there is no meaningful downward fall for suspended dust.
		mat.gravity = wind
		var col: Color = hz.get("haze_color", Color(0.7, 0.5, 0.3))
		mat.color = Color(col.r, col.g, col.b, 0.55)


func _setup_dust() -> void:
	dust_particles = GPUParticles3D.new()
	dust_particles.name = "DustParticles"
	dust_particles.amount = DUST_AMOUNT_MAX
	dust_particles.amount_ratio = 0.0
	dust_particles.lifetime = 3.4
	dust_particles.emitting = false
	dust_particles.local_coords = false
	dust_particles.fixed_fps = 30
	dust_particles.visibility_aabb = VIS_AABB

	_dust_mat = ParticleProcessMaterial.new()
	_dust_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_dust_mat.emission_box_extents = EMIT_HALF
	_dust_mat.direction = Vector3(1, 0, 0)
	_dust_mat.spread = 25.0
	_dust_mat.initial_velocity_min = 6.0
	_dust_mat.initial_velocity_max = 16.0
	_dust_mat.gravity = Vector3(0, -0.4, 0)
	_dust_mat.scale_min = 0.05
	_dust_mat.scale_max = 0.30
	_dust_mat.turbulence_enabled = true
	_dust_mat.turbulence_noise_strength = 1.4
	dust_particles.process_material = _dust_mat
	dust_particles.draw_pass_1 = _grain_mesh(Vector2(0.22, 0.16))
	add_child(dust_particles)


## One unshaded billboarded quad shared by every particle in the pass. Vertex
## colour carries the tint so the emitter can be recoloured per hazard without
## a second material.
func _grain_mesh(size: Vector2) -> QuadMesh:
	var m := QuadMesh.new()
	m.size = size
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1, 1, 1, 0.55)
	m.material = mat
	return m


## Test/inspection accessor.
func active_kind() -> String:
	return _kind
