class_name ConduitDischargeVfx
extends Node3D

## A ballistic water jet at a culvert (or pipe) outlet mouth. One GPUParticles3D
## of small billboard droplets emitted along the pipe-exit tangent, falling under
## world gravity — reads as water pouring/spraying out of the discharge. Density,
## velocity and reach scale with the live flow rate. Pattern follows
## core/precipitation_vfx.gd; the manager owns one of these per culvert connection
## and drives it every frame via set_flow().

## Flow (L/s) that reads as a "full" jet — an 8" culvert bank runs a few L/s to
## tens of L/s; normalize against this so a typical drain looks lively, not weak.
const Q_REF_LPS := 12.0
## Below this the mouth is effectively dry — stop emitting.
const Q_MIN_LPS := 0.05
const AMOUNT_MAX := 260
const LERP_SPEED := 6.0

var _particles: GPUParticles3D
var _mat: ParticleProcessMaterial
var _mesh: QuadMesh
var _mat3d: StandardMaterial3D
var _activity := 0.0


func _ready() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "DischargeParticles"
	_particles.amount = AMOUNT_MAX
	_particles.amount_ratio = 0.0
	_particles.lifetime = 1.1
	_particles.emitting = false
	# World-space so the arc keeps falling under real gravity regardless of how
	# the node is oriented at the mouth.
	_particles.local_coords = false
	_particles.visibility_aabb = AABB(Vector3(-12, -16, -12), Vector3(24, 24, 24))

	_mat = ParticleProcessMaterial.new()
	_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_mat.emission_sphere_radius = 0.08
	_mat.direction = Vector3(1, -0.15, 0)
	_mat.spread = 14.0
	_mat.initial_velocity_min = 1.2
	_mat.initial_velocity_max = 2.4
	_mat.gravity = Vector3(0, -9.8, 0)
	_mat.scale_min = 0.03
	_mat.scale_max = 0.06
	_particles.process_material = _mat

	_mesh = QuadMesh.new()
	_mesh.size = Vector2(0.05, 0.05)
	_mat3d = StandardMaterial3D.new()
	_mat3d.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat3d.albedo_color = Color(0.72, 0.88, 1.0, 0.8)
	_mat3d.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat3d.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_mat3d.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh.material = _mat3d
	_particles.draw_pass_1 = _mesh
	add_child(_particles)


static func flow_intensity_t(q_lps: float) -> float:
	if q_lps <= Q_MIN_LPS:
		return 0.0
	return clampf(q_lps / Q_REF_LPS, 0.0, 1.0)


## Drive the jet from the live flow. `mouth` = world position of the outlet;
## `dir` = world exit direction (pipe axis at the mouth, roughly outward/downhill).
func set_flow(delta: float, q_lps: float, mouth: Vector3, dir: Vector3) -> void:
	if _particles == null:
		return
	global_position = mouth
	var target := flow_intensity_t(q_lps)
	_activity = lerpf(_activity, target, 1.0 - exp(-delta * LERP_SPEED))
	if q_lps <= Q_MIN_LPS and _activity < 0.02:
		_particles.emitting = false
		_particles.amount_ratio = 0.0
		return
	_particles.emitting = true
	var t := _activity
	_particles.amount_ratio = lerpf(0.2, 1.0, t)
	# Exit vector: pipe tangent with a downward bias so it always reads as a fall.
	var jet := dir
	if jet.length_squared() < 1e-4:
		jet = Vector3(1, -0.3, 0)
	jet = (jet.normalized() + Vector3(0, -0.35, 0)).normalized()
	_mat.direction = jet
	_mat.initial_velocity_min = lerpf(0.8, 2.4, t)
	_mat.initial_velocity_max = lerpf(1.6, 4.4, t)
	_mat.scale_min = lerpf(0.025, 0.045, t)
	_mat.scale_max = lerpf(0.05, 0.08, t)
	var col := _mat3d.albedo_color
	col.a = lerpf(0.55, 0.85, t)
	_mat3d.albedo_color = col
