extends Node3D
class_name FireNode

## Fire node with visible smoke plume and flickering light
## Particle effects run at real-time speed regardless of simulation speed
## Adaptive LOD system reduces complexity when many fires are active

signal fire_extinguished()
signal fire_spread(target_mesh: MeshInstance3D)
signal mesh_destroyed(mesh: MeshInstance3D)

# Fire state
enum FireState { SMALL, MEDIUM, LARGE, ENGULFING, INFERNO }
var state : FireState = FireState.SMALL

## The mesh this fire is attached to
var target_mesh : MeshInstance3D = null
## Structure root this fire may burn (PlacedProp / camp). Spread never leaves this.
var burn_scope : Node = null
## Meshes currently burning under this single growing node (perf: no extra FireNodes).
var burning_meshes : Array[MeshInstance3D] = []
## Visual growth tier 0..4 — scales particles/lights instead of spawning more fires.
var growth_tier : int = 0
var _applied_growth_tier : int = -1

## Fire intensity (0-100, affects size and damage)
var intensity : float = 18.0

## Time elapsed since fire started (simulation time in hours)
var fire_time_hours : float = 0.0

## Time thresholds (in simulation hours)
const ENGULF_TIME_HOURS : float = 0.5  # 30 minutes
const DESTROY_TIME_HOURS : float = 1.0  # 1 hour
const SPREAD_CHECK_INTERVAL : float = 0.05
## Wall-clock spread so fires jump between meshes during normal play (sim-time
## alone is too slow when time_scale ≈ 1).
const SPREAD_WALL_INTERVAL : float = 0.7
const SPREAD_MIN_INTENSITY : float = 22.0
## Max new mesh absorptions per spread tick (same FireNode grows; no new nodes).
const SPREAD_MAX_PER_TICK : int = 2
## Hard cap on concurrent FireNodes in the whole scene (absorb within scope instead).
const MAX_SCENE_FIRE_NODES : int = 3

## Growth rate (intensity per sim hour) - ONLY for sim time
const GROWTH_RATE : float = 80.0

## Extinguisher damage rate (intensity per second of spray)
const EXTINGUISHER_DAMAGE : float = 50.0

## Intensity threshold to extinguish (when particles stop, fire is out)
const EXTINGUISH_THRESHOLD : float = 5.0

## LOD thresholds - when cluster manager takes over
const CLUSTER_TAKEOVER_THRESHOLD : int = 25   # Keep full particles for first 25 fires
const REALISTIC_FIRE_NODE_LIMIT : int = 8
const IGNITION_REALISM_SECONDS : float = 7.0

enum VisualQuality { HIGH, MEDIUM, LOW }

## Components - only indicator is always created, others are conditional
var flame_particles : GPUParticles3D = null
var smoke_particles : GPUParticles3D = null
var ignition_particles : GPUParticles3D = null
var ember_particles : GPUParticles3D = null
var fire_light : OmniLight3D = null
var fire_light_2 : OmniLight3D = null
var detection_area : Area3D = null
var indicator_mesh : MeshInstance3D = null

## Spread tracking
var spread_timer : float = 0.0
var _spread_wall_timer : float = 0.0
var nearby_meshes_engulfed : Array[MeshInstance3D] = []
var _cluster_check_timer : float = 0.0
const _CLUSTER_CHECK_INTERVAL : float = 0.75

## Extinguisher spray bodies in range
var spray_bodies : Array[Node3D] = []

## True if this fire was reduced by the player's extinguisher (cone damage and/or spray overlap).
var _had_extinguisher_help : bool = false

## Flicker timing (real-time)
var _flicker_time : float = 0.0

## Track last intensity for visual updates
var _last_visual_intensity : float = 0.0

## Whether we're rendering our own visuals or cluster manager is handling them
var _cluster_managed : bool = false
var _visuals_created : bool = false
## Avoid resetting GPUParticles amount every frame (restarts the system → static smoke).
var _applied_quality : int = -1
var _applied_amount_bucket : int = -1

## Time this fire was created (for grace period before cluster management)
var _creation_time : float = 0.0

## Grace period - new fires always show particles for this many seconds
const NEW_FIRE_GRACE_PERIOD : float = 5.0
const _FIRE_COUNT_CACHE_SECONDS : float = 0.5
const _MESH_CACHE_REFRESH_SECONDS : float = 5.0

## --- Surface burn (the burn FRONT) ---------------------------------------
## A fire used to be a point: it sat where it was lit and "spread" only by
## absorbing whole sibling meshes, so a structure that is ONE mesh never spread
## at all. Now the structure is sampled once into world-space surface points and
## a burn front climbs it from the base: flames are emitted from the surface
## points in a band under the front, and a char overlay (fire_char.gdshader)
## darkens everything the front has passed. All in WORLD space — a GLB's own
## axes and import scale (inches) are exactly what made the old ignition point
## land at the top of the model.
const CHAR_SHADER := preload("res://crisis_events/fire/fire_char.gdshader")
const ASH_SHADER := preload("res://crisis_events/fire/fire_ash.gdshader")
## Share of a fire's life (0..1 of DESTROY_TIME_HOURS) at which the blackened
## structure starts to be eaten away.
const BURN_AWAY_FROM : float = 0.82
const MAX_SURFACE_POINTS : int = 3000
const MAX_EMISSION_POINTS : int = 512
const BURN_STEPS : int = 24
## The front climbs at about this speed in real time (sim time also counts).
const CLIMB_SPEED_MPS : float = 0.22
const CLIMB_MIN_SECONDS : float = 18.0
const CLIMB_MAX_SECONDS : float = 90.0
## Fire grows in real time too — at 1x sim speed GROWTH_RATE alone adds 0.02/s
## and a fire never reached the intensity that lets it spread.
const WALL_GROWTH_PER_SEC : float = 2.5
## Fixed particle budgets in surface mode; `amount_ratio` does the scaling,
## because writing `amount` restarts the emitter (a visible gap every tier).
const SURFACE_FLAME_AMOUNT : int = 160
const SURFACE_SMOKE_AMOUNT : int = 110
const SURFACE_EMBER_AMOUNT : int = 60

## --- Collapse and the pile ------------------------------------------------
## Burning away left the last quarter of a structure hanging in the air. Now,
## once about three quarters of it is gone, what is left FAILS: it drops into
## the base (fire_ash.gdshader `collapse`), throws up a flare, and a FireAshPile
## over the footprint takes over — bonfire, embers, ash. `dissolve` 0.65 is 75 %
## of the surface consumed (measured against the shader's noise, see there).
const COLLAPSE_AT_DISSOLVE : float = 0.65
## Dissolve value by which every last scrap is gone (reached as it lands).
const COLLAPSE_END_DISSOLVE : float = 1.35
enum BurnPhase { BURNING, COLLAPSING, PILE }
var burn_phase : BurnPhase = BurnPhase.BURNING
var ash_pile : FireAshPile = null
var _collapse_t : float = 0.0
var _collapse_seconds : float = 1.5
var _collapse_from_dissolve : float = 0.0
var _whooshed : bool = false
var _extinguish_signalled : bool = false

## 0 = just lit at the base, 1 = the front has reached the top.
var burn_progress : float = 0.0
var _surface_mode : bool = false
var _surface_setup_done : bool = false
var _burn_points : PackedVector3Array = PackedVector3Array()  # sorted by y
var _burn_base_y : float = 0.0
var _burn_top_y : float = 0.0
var _burn_reach_max : float = 1.0
var _ignite_xz : Vector2 = Vector2.ZERO
var _burn_step : int = -1
var _char_mat : ShaderMaterial = null
var _ash_mat : ShaderMaterial = null
var _charred : Array[MeshInstance3D] = []

static var _cached_fire_count : int = 0
static var _last_fire_count_update_sec : float = -1000.0
static var _cached_flammable_meshes : Array[MeshInstance3D] = []
static var _last_mesh_cache_update_sec : float = -1000.0

## Burned meshes (hidden, not freed) so structures can be regenerated.
static var _burned_meshes : Array[MeshInstance3D] = []


## Call after placed-prop burnable flags change so spread sees new targets promptly.
static func invalidate_flammable_mesh_cache() -> void:
	_cached_flammable_meshes.clear()
	_last_mesh_cache_update_sec = -1000.0


static func get_burned_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for m in _burned_meshes:
		if m != null and is_instance_valid(m):
			out.append(m)
	_burned_meshes = out
	return out


## Restore visibility/materials for meshes destroyed by fire (not queue_freed).
static func regenerate_burned_meshes(limit: int = -1) -> int:
	var restored := 0
	var keep: Array[MeshInstance3D] = []
	for m in _burned_meshes:
		if m == null or not is_instance_valid(m):
			continue
		if limit >= 0 and restored >= limit:
			keep.append(m)
			continue
		_restore_burned_mesh(m)
		restored += 1
	_burned_meshes = keep
	invalidate_flammable_mesh_cache()
	return restored


## Restore burned meshes that are descendants of `root` (e.g. one PlacedProp).
static func regenerate_meshes_under(root: Node) -> int:
	if root == null:
		return 0
	var restored := 0
	var keep: Array[MeshInstance3D] = []
	for m in _burned_meshes:
		if m == null or not is_instance_valid(m):
			continue
		if _is_ancestor(root, m):
			_restore_burned_mesh(m)
			restored += 1
		else:
			keep.append(m)
	_burned_meshes = keep
	# Also clear char overlays on engulfed-but-not-destroyed siblings.
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null:
			continue
		if mi.has_meta("fire_pre_burn_override") and not (mi.has_meta("fire_burned") and bool(mi.get_meta("fire_burned"))):
			_restore_burned_mesh(mi)
			restored += 1
		elif mi.has_meta("fire_char_overlay"):
			# Charred by a burn front that was put out before it destroyed anything.
			_clear_char_overlay(mi)
			restored += 1
	FireAshPile.clear_for(root)
	if root is PlacedProp:
		(root as PlacedProp).clear_burned_flag()
	invalidate_flammable_mesh_cache()
	return restored


static func _is_ancestor(ancestor: Node, node: Node) -> bool:
	var n := node
	while n != null:
		if n == ancestor:
			return true
		n = n.get_parent()
	return false


static func _restore_burned_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null or not is_instance_valid(mesh):
		return
	mesh.visible = true
	FireAshPile.clear_for(mesh)
	_clear_char_overlay(mesh)
	if mesh.has_meta("fire_pre_burn_override"):
		var prev: Variant = mesh.get_meta("fire_pre_burn_override")
		mesh.material_override = prev as Material
		mesh.remove_meta("fire_pre_burn_override")
	else:
		mesh.material_override = null
	if mesh.has_meta("fire_burned"):
		mesh.remove_meta("fire_burned")
	if mesh.has_meta("fire_active"):
		mesh.set_meta("fire_active", false)
	# Placed props: clear burn flag on parent so the edit UI can hide Restore.
	var n: Node = mesh
	while n != null:
		if n is PlacedProp:
			(n as PlacedProp).clear_burned_flag()
			break
		n = n.get_parent()


## Take the char overlay (and any burn-away fade) off a mesh.
static func _clear_char_overlay(mesh: MeshInstance3D) -> void:
	if mesh == null or not is_instance_valid(mesh) or not mesh.has_meta("fire_char_overlay"):
		return
	var prev: Variant = mesh.get_meta("fire_pre_overlay") if mesh.has_meta("fire_pre_overlay") else null
	mesh.material_overlay = prev as Material
	mesh.remove_meta("fire_char_overlay")
	if mesh.has_meta("fire_pre_overlay"):
		mesh.remove_meta("fire_pre_overlay")


static func _register_burned_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null or not is_instance_valid(mesh):
		return
	if mesh in _burned_meshes:
		return
	_burned_meshes.append(mesh)


func _ready() -> void:
	add_to_group("fire_nodes")
	_creation_time = Time.get_ticks_msec() / 1000.0
	spread_timer = randf() * SPREAD_CHECK_INTERVAL
	_cluster_check_timer = randf() * _CLUSTER_CHECK_INTERVAL
	_spread_wall_timer = randf() * SPREAD_WALL_INTERVAL
	if target_mesh != null and is_instance_valid(target_mesh):
		target_mesh.set_meta("fire_active", true)
		if burning_meshes.is_empty():
			burning_meshes.append(target_mesh)
		if burn_scope == null:
			burn_scope = _structure_root_of(target_mesh)
	_create_indicator()
	_create_detection_area()
	_create_fire_visuals()
	_visuals_created = true
	_cluster_managed = false
	_last_visual_intensity = intensity
	_apply_growth_visuals(true)
	_update_visuals_immediate()

func _check_cluster_mode() -> void:
	var tree := get_tree()
	if tree == null:
		_ensure_own_visuals()
		return
	
	# Grace period - new fires always show their own particles for visibility
	var current_time := Time.get_ticks_msec() / 1000.0
	var age := current_time - _creation_time
	if age < NEW_FIRE_GRACE_PERIOD:
		# Still in grace period - keep individual visuals
		if _cluster_managed:
			_cluster_managed = false
			_ensure_own_visuals()
		return
	
	var fire_count := _get_cached_fire_count()
	var should_cluster := fire_count >= CLUSTER_TAKEOVER_THRESHOLD
	
	if should_cluster != _cluster_managed:
		_cluster_managed = should_cluster
		if _cluster_managed:
			# Cluster manager handles visuals - disable ours
			_disable_own_visuals()
		else:
			# We handle our own visuals
			_ensure_own_visuals()

func _ensure_own_visuals() -> void:
	if not _visuals_created:
		_create_fire_visuals()
		_visuals_created = true
	_applied_quality = -1
	_applied_amount_bucket = -1

	if ignition_particles != null:
		ignition_particles.visible = true
		ignition_particles.emitting = true
	if flame_particles != null:
		flame_particles.visible = true
		flame_particles.emitting = true
	if smoke_particles != null:
		smoke_particles.visible = true
		smoke_particles.emitting = true
	if ember_particles != null:
		ember_particles.visible = true
		ember_particles.emitting = true
	if fire_light != null:
		fire_light.visible = true
	if fire_light_2 != null:
		fire_light_2.visible = true


func _disable_own_visuals() -> void:
	if ignition_particles != null:
		ignition_particles.emitting = false
		ignition_particles.visible = false
	if flame_particles != null:
		flame_particles.emitting = false
		flame_particles.visible = false
	if smoke_particles != null:
		smoke_particles.emitting = false
		smoke_particles.visible = false
	if ember_particles != null:
		ember_particles.emitting = false
		ember_particles.visible = false
	if fire_light != null:
		fire_light.visible = false
	if fire_light_2 != null:
		fire_light_2.visible = false

func _create_indicator() -> void:
	indicator_mesh = MeshInstance3D.new()
	indicator_mesh.name = "FireIndicator"
	# Soft glow base — kept tiny while particles run; larger only in LOD/cluster.
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	indicator_mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.45, 0.05, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.08)
	mat.emission_energy_multiplier = 4.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	indicator_mesh.material_override = mat
	add_child(indicator_mesh)


func _create_fire_visuals() -> void:
	# ==================== IGNITION CORE ====================
	ignition_particles = GPUParticles3D.new()
	ignition_particles.name = "IgnitionCore"
	ignition_particles.amount = 16
	ignition_particles.lifetime = 0.85
	ignition_particles.preprocess = 0.15
	ignition_particles.emitting = true
	ignition_particles.fixed_fps = 30
	ignition_particles.visibility_aabb = AABB(Vector3(-6, -2, -6), Vector3(12, 20, 12))
	ignition_particles.local_coords = false

	var ignition_mat := ParticleProcessMaterial.new()
	ignition_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ignition_mat.emission_sphere_radius = 0.16
	ignition_mat.direction = Vector3(0, 1, 0)
	ignition_mat.spread = 12.0
	ignition_mat.initial_velocity_min = 2.2
	ignition_mat.initial_velocity_max = 5.0
	ignition_mat.gravity = Vector3(0, 4.0, 0)
	ignition_mat.scale_min = 0.2
	ignition_mat.scale_max = 0.55
	ignition_mat.damping_min = 0.05
	ignition_mat.damping_max = 0.2
	var ignition_color := Gradient.new()
	ignition_color.offsets = PackedFloat32Array([0.0, 0.25, 0.55, 1.0])
	ignition_color.colors = PackedColorArray([
		Color(1.0, 0.98, 0.85, 1.0),
		Color(1.0, 0.8, 0.3, 0.95),
		Color(1.0, 0.4, 0.08, 0.6),
		Color(0.2, 0.15, 0.1, 0.0),
	])
	var ignition_color_tex := GradientTexture1D.new()
	ignition_color_tex.gradient = ignition_color
	ignition_mat.color_ramp = ignition_color_tex
	ignition_particles.process_material = ignition_mat
	ignition_particles.draw_pass_1 = FireVfx.make_billboard_quad(
		Vector2(0.4, 0.9), true, Color(1.0, 0.7, 0.2), 3.5)
	add_child(ignition_particles)

	# ==================== FLAMES (rise + soft discs) ====================
	flame_particles = GPUParticles3D.new()
	flame_particles.name = "Flames"
	flame_particles.amount = 48
	flame_particles.lifetime = 1.6
	flame_particles.emitting = true
	flame_particles.fixed_fps = 28
	flame_particles.visibility_aabb = AABB(Vector3(-12, -2, -12), Vector3(24, 40, 24))
	flame_particles.local_coords = false
	flame_particles.explosiveness = 0.05

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.35
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 22.0
	mat.initial_velocity_min = 1.8
	mat.initial_velocity_max = 4.5
	mat.gravity = Vector3(0, 6.5, 0)
	mat.scale_min = 0.35
	mat.scale_max = 0.85
	mat.damping_min = 0.4
	mat.damping_max = 1.0
	mat.angular_velocity_min = -40.0
	mat.angular_velocity_max = 40.0
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.55))
	scale_curve.add_point(Vector2(0.35, 1.0))
	scale_curve.add_point(Vector2(0.75, 0.7))
	scale_curve.add_point(Vector2(1.0, 0.15))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	mat.scale_curve = scale_tex
	var color_grad := Gradient.new()
	color_grad.offsets = PackedFloat32Array([0.0, 0.15, 0.35, 0.55, 0.8, 1.0])
	color_grad.colors = PackedColorArray([
		Color(1.0, 1.0, 0.9, 1.0),
		Color(1.0, 0.9, 0.35, 0.95),
		Color(1.0, 0.55, 0.1, 0.9),
		Color(1.0, 0.28, 0.05, 0.7),
		Color(0.55, 0.12, 0.02, 0.35),
		Color(0.15, 0.05, 0.02, 0.0),
	])
	var color_tex := GradientTexture1D.new()
	color_tex.gradient = color_grad
	mat.color_ramp = color_tex
	flame_particles.process_material = mat
	flame_particles.draw_pass_1 = FireVfx.make_billboard_quad(
		Vector2(0.55, 1.1), true, Color(1.0, 0.55, 0.12), 2.8)
	flame_particles.position = Vector3(0, 0.35, 0)
	add_child(flame_particles)

	# ==================== SMOKE PLUME (dense, rises high + fast) ====================
	smoke_particles = GPUParticles3D.new()
	smoke_particles.name = "SmokePlume"
	smoke_particles.amount = 52
	smoke_particles.lifetime = 8.5
	smoke_particles.preprocess = 0.6
	smoke_particles.emitting = true
	smoke_particles.fixed_fps = 22
	smoke_particles.visibility_aabb = AABB(Vector3(-30, -2, -30), Vector3(60, 140, 60))
	smoke_particles.local_coords = false
	smoke_particles.position = Vector3(0, 0.9, 0)

	var smoke_mat := ParticleProcessMaterial.new()
	smoke_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	smoke_mat.emission_sphere_radius = 0.55
	smoke_mat.direction = Vector3(0, 1, 0)
	smoke_mat.spread = 16.0
	smoke_mat.initial_velocity_min = 3.5
	smoke_mat.initial_velocity_max = 7.5
	smoke_mat.gravity = Vector3(0, 9.5, 0)
	smoke_mat.scale_min = 0.9
	smoke_mat.scale_max = 2.2
	smoke_mat.damping_min = 0.04
	smoke_mat.damping_max = 0.15
	smoke_mat.turbulence_enabled = true
	smoke_mat.turbulence_noise_strength = 0.9
	smoke_mat.turbulence_noise_scale = 2.8
	smoke_mat.turbulence_influence_min = 0.08
	smoke_mat.turbulence_influence_max = 0.25
	var smoke_scale := Curve.new()
	smoke_scale.add_point(Vector2(0.0, 0.4))
	smoke_scale.add_point(Vector2(0.25, 1.0))
	smoke_scale.add_point(Vector2(0.6, 2.0))
	smoke_scale.add_point(Vector2(1.0, 3.4))
	var smoke_scale_tex := CurveTexture.new()
	smoke_scale_tex.curve = smoke_scale
	smoke_mat.scale_curve = smoke_scale_tex
	var smoke_color := Gradient.new()
	smoke_color.offsets = PackedFloat32Array([0.0, 0.12, 0.4, 0.75, 1.0])
	smoke_color.colors = PackedColorArray([
		Color(0.18, 0.14, 0.12, 0.35),
		Color(0.1, 0.09, 0.08, 0.72),
		Color(0.12, 0.11, 0.1, 0.55),
		Color(0.16, 0.15, 0.14, 0.28),
		Color(0.14, 0.13, 0.12, 0.0),
	])
	var smoke_color_tex := GradientTexture1D.new()
	smoke_color_tex.gradient = smoke_color
	smoke_mat.color_ramp = smoke_color_tex
	smoke_particles.process_material = smoke_mat
	smoke_particles.draw_pass_1 = FireVfx.make_billboard_quad(
		Vector2(1.6, 1.6), false, Color.BLACK, 0.0)
	add_child(smoke_particles)

	# ==================== RED EMBERS (rise with smoke) ====================
	ember_particles = GPUParticles3D.new()
	ember_particles.name = "Embers"
	ember_particles.amount = 28
	ember_particles.lifetime = 4.0
	ember_particles.emitting = true
	ember_particles.fixed_fps = 24
	ember_particles.visibility_aabb = AABB(Vector3(-14, -2, -14), Vector3(28, 80, 28))
	ember_particles.local_coords = false
	ember_particles.position = Vector3(0, 0.5, 0)

	var ember_mat := ParticleProcessMaterial.new()
	ember_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ember_mat.emission_sphere_radius = 0.5
	ember_mat.direction = Vector3(0, 1, 0)
	ember_mat.spread = 30.0
	ember_mat.initial_velocity_min = 2.8
	ember_mat.initial_velocity_max = 6.5
	ember_mat.gravity = Vector3(0, 5.5, 0)
	ember_mat.scale_min = 0.4
	ember_mat.scale_max = 1.15
	ember_mat.damping_min = 0.1
	ember_mat.damping_max = 0.35
	ember_mat.turbulence_enabled = true
	ember_mat.turbulence_noise_strength = 1.4
	ember_mat.turbulence_noise_scale = 3.2
	ember_mat.turbulence_influence_min = 0.12
	ember_mat.turbulence_influence_max = 0.4
	var ember_color := Gradient.new()
	ember_color.offsets = PackedFloat32Array([0.0, 0.3, 0.7, 1.0])
	ember_color.colors = PackedColorArray([
		Color(1.0, 0.85, 0.3, 1.0),
		Color(1.0, 0.35, 0.05, 1.0),
		Color(0.85, 0.12, 0.02, 0.85),
		Color(0.3, 0.02, 0.0, 0.0),
	])
	var ember_color_tex := GradientTexture1D.new()
	ember_color_tex.gradient = ember_color
	ember_mat.color_ramp = ember_color_tex
	ember_particles.process_material = ember_mat
	ember_particles.draw_pass_1 = FireVfx.make_ember_quad()
	add_child(ember_particles)

	# ==================== FIRE LIGHTS ====================
	fire_light = OmniLight3D.new()
	fire_light.name = "FireLight"
	fire_light.light_color = Color(1.0, 0.55, 0.18)
	fire_light.light_energy = 10.0
	fire_light.omni_range = 22.0
	fire_light.omni_attenuation = 1.0
	fire_light.shadow_enabled = false
	fire_light.position = Vector3(0, 1.0, 0)
	add_child(fire_light)

	fire_light_2 = OmniLight3D.new()
	fire_light_2.name = "FireLight2"
	fire_light_2.light_color = Color(1.0, 0.35, 0.08)
	fire_light_2.light_energy = 5.0
	fire_light_2.omni_range = 35.0
	fire_light_2.omni_attenuation = 1.2
	fire_light_2.shadow_enabled = false
	fire_light_2.position = Vector3(0, 2.0, 0)
	add_child(fire_light_2)

func _create_detection_area() -> void:
	detection_area = Area3D.new()
	detection_area.name = "DetectionArea"
	detection_area.collision_layer = 0
	detection_area.collision_mask = 0xFFFFFFFF
	
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 2.5
	shape.shape = sphere
	detection_area.add_child(shape)
	
	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)
	
	add_child(detection_area)

func _process(delta: float) -> void:
	# Real-time flicker (not affected by sim speed)
	_flicker_time += delta
	
	# Get time scale for simulation-dependent effects ONLY
	var time_scale := _get_time_scale()
	var sim_hours := delta * time_scale
	
	# Check if being sprayed
	var being_sprayed := spray_bodies.size() > 0
	if being_sprayed :
		_had_extinguisher_help = true

	# Collapsing, or burning down as a pile: the FireAshPile owns the visuals.
	if burn_phase != BurnPhase.BURNING:
		_process_aftermath(delta, being_sprayed)
		return

	# Periodically check if cluster manager should take over (staggered per-fire)
	_cluster_check_timer += delta
	if _cluster_check_timer >= _CLUSTER_CHECK_INTERVAL:
		_cluster_check_timer -= _CLUSTER_CHECK_INTERVAL
		_check_cluster_mode()

	# Apply extinguisher damage (REAL-TIME - not sim time)
	if being_sprayed:
		intensity -= EXTINGUISHER_DAMAGE * delta * spray_bodies.size()
		# Fire doesn't grow while being actively sprayed!
	else:
		# Natural growth only when NOT being sprayed (SIMULATION time)
		# But only if fire is above a minimum threshold
		if intensity > EXTINGUISH_THRESHOLD:
			intensity += maxf(GROWTH_RATE * sim_hours, WALL_GROWTH_PER_SEC * delta)
	
	intensity = clampf(intensity, 0.0, 200.0)
	_refresh_growth_tier()

	# Track fire time (simulation)
	fire_time_hours += sim_hours

	# The burn front. Set up on the first frame, not in _ready: the event places
	# this node AFTER add_child, and the ignition spot is where it was placed.
	if not _surface_setup_done:
		_surface_setup_done = true
		_setup_surface_burn()
	if _surface_mode:
		_advance_burn_front(delta, sim_hours, being_sprayed)
		if burn_phase != BurnPhase.BURNING:
			return  # three quarters gone: it has started to come down

	# Check if extinguished - once intensity is low enough, fire is OUT
	# No need to keep spraying once it's this low
	if intensity <= EXTINGUISH_THRESHOLD:
		_extinguish()
		return
	
	# Update state
	if intensity >= 150 or fire_time_hours >= ENGULF_TIME_HOURS:
		if state != FireState.INFERNO and state != FireState.ENGULFING:
			state = FireState.ENGULFING
			_engulf_nearby_meshes()
		if intensity >= 150:
			state = FireState.INFERNO
	elif intensity >= 100:
		state = FireState.LARGE
	elif intensity >= 60:
		state = FireState.MEDIUM
	else:
		state = FireState.SMALL
	
	# Destruction check. A surface fire collapses earlier, off the burn-away
	# itself; this catches point fires and a front that was held back by spray.
	if fire_time_hours >= DESTROY_TIME_HOURS:
		_begin_collapse()
		return

	# Spread: wall-clock so jumps happen during normal play; sim-time as backup.
	_spread_wall_timer += delta
	if _spread_wall_timer >= SPREAD_WALL_INTERVAL and intensity >= SPREAD_MIN_INTENSITY:
		_spread_wall_timer = 0.0
		_try_spread()
	spread_timer += sim_hours
	if spread_timer >= SPREAD_CHECK_INTERVAL and intensity >= SPREAD_MIN_INTENSITY:
		spread_timer -= SPREAD_CHECK_INTERVAL
		_try_spread()

	# Update visuals - always at real-time speed
	_update_visuals_immediate()

## Update visuals based on current intensity - runs every frame at real-time
func _get_visual_quality_tier(fire_count: int, age_seconds: float, visual_factor: float) -> VisualQuality:
	if fire_count > REALISTIC_FIRE_NODE_LIMIT:
		return VisualQuality.LOW
	# New ignitions stay high detail briefly for realism.
	if age_seconds <= IGNITION_REALISM_SECONDS:
		return VisualQuality.HIGH
	# Within first 5 fires, still scale down a bit at very high intensity.
	if visual_factor >= 1.6:
		return VisualQuality.LOW
	if visual_factor >= 1.1:
		return VisualQuality.MEDIUM
	return VisualQuality.HIGH

func _update_visuals_immediate() -> void:
	# Smooth visual transitions
	_last_visual_intensity = lerpf(_last_visual_intensity, intensity, 0.1)
	var visual_factor := clampf(_last_visual_intensity / 100.0, 0.0, 2.0)
	var fire_count := _get_cached_fire_count()
	var age_seconds := (Time.get_ticks_msec() / 1000.0) - _creation_time
	var simplified_mode := fire_count > REALISTIC_FIRE_NODE_LIMIT
	var quality := _get_visual_quality_tier(fire_count, age_seconds, visual_factor)

	# Indicator: tiny while particles run; larger glow only in LOD/cluster modes.
	if indicator_mesh != null:
		var use_big_indicator := simplified_mode or _cluster_managed
		var indicator_base_scale := 0.35 if use_big_indicator else 0.08
		var indicator_intensity_scale := 0.55 if use_big_indicator else 0.12
		var indicator_scale := indicator_base_scale + visual_factor * indicator_intensity_scale
		var pulse := sin(_flicker_time * 4.0) * 0.12 + 1.0
		indicator_mesh.scale = Vector3.ONE * indicator_scale * pulse
		indicator_mesh.visible = intensity > EXTINGUISH_THRESHOLD
		var mat := indicator_mesh.material_override as StandardMaterial3D
		if mat != null:
			if intensity <= 0:
				mat.albedo_color = Color(0.3, 0.3, 0.3, 0.5)
				mat.emission = Color(0, 0, 0)
				mat.emission_energy_multiplier = 0.0
			else:
				mat.albedo_color = Color(1.0, 0.4 * (1.0 - visual_factor * 0.3), 0.0, 0.9)
				mat.emission = Color(1.0, 0.5, 0.0)
				mat.emission_energy_multiplier = visual_factor * (5.0 if use_big_indicator else 2.0)

	if _cluster_managed:
		return

	if simplified_mode:
		if ignition_particles != null:
			ignition_particles.visible = false
			ignition_particles.emitting = false
		if flame_particles != null:
			flame_particles.visible = false
			flame_particles.emitting = false
		if smoke_particles != null:
			smoke_particles.visible = false
			smoke_particles.emitting = false
		if ember_particles != null:
			# Keep a few rising embers even in LOD mode — cheap and readable.
			ember_particles.visible = intensity > EXTINGUISH_THRESHOLD
			ember_particles.emitting = intensity > EXTINGUISH_THRESHOLD
			if ember_particles.emitting and ember_particles.amount != 10:
				ember_particles.amount = 10
		if fire_light != null:
			var simple_energy := lerpf(3.0, 7.0, visual_factor) * (sin(_flicker_time * 5.5) * 0.12 + 1.0)
			fire_light.light_energy = lerpf(fire_light.light_energy, simple_energy, 0.2)
			fire_light.omni_range = lerpf(12.0, 22.0, visual_factor)
		if fire_light_2 != null:
			fire_light_2.visible = false
			fire_light_2.light_energy = 0.0
		return

	# Growth tier owns particle amounts — don't thrash amount every frame.
	if ignition_particles != null:
		var ignition_enabled := growth_tier <= 1 and age_seconds <= IGNITION_REALISM_SECONDS and intensity > EXTINGUISH_THRESHOLD
		ignition_particles.visible = ignition_enabled
		ignition_particles.emitting = ignition_enabled

	if flame_particles != null:
		flame_particles.emitting = intensity > 5
		flame_particles.visible = intensity > 5

	if smoke_particles != null:
		var smoke_on := intensity > EXTINGUISH_THRESHOLD
		smoke_particles.visible = smoke_on
		smoke_particles.emitting = smoke_on

	if ember_particles != null:
		var ember_on := intensity > EXTINGUISH_THRESHOLD
		ember_particles.visible = ember_on
		ember_particles.emitting = ember_on

	var flicker1 := sin(_flicker_time * 6.0) * 0.25 + sin(_flicker_time * 10.0) * 0.18 + sin(_flicker_time * 15.0) * 0.1 + 1.0
	var flicker2 := sin(_flicker_time * 5.0 + 0.7) * 0.22 + sin(_flicker_time * 9.0) * 0.12 + 1.0

	if fire_light != null:
		if intensity <= 5:
			fire_light.light_energy = lerpf(fire_light.light_energy, 0.0, 0.2)
		else:
			var base_energy := (4.0 + float(growth_tier) * 2.5) * lerpf(0.9, 1.15, visual_factor * 0.5)
			fire_light.light_energy = lerpf(fire_light.light_energy, base_energy * flicker1, 0.2)
			var color_shift := (sin(_flicker_time * 7.0) + 1.0) * 0.08
			fire_light.light_color = Color(1.0, 0.5 + color_shift, 0.15 + color_shift * 0.5)

	if fire_light_2 != null:
		if intensity <= 5 or growth_tier < 1:
			fire_light_2.light_energy = lerpf(fire_light_2.light_energy, 0.0, 0.2)
			fire_light_2.visible = growth_tier >= 1
		else:
			fire_light_2.visible = true
			fire_light_2.light_energy = lerpf(fire_light_2.light_energy, (2.0 + float(growth_tier) * 1.8) * flicker2, 0.2)

func _try_spread() -> void:
	if target_mesh == null or not is_instance_valid(target_mesh):
		return
	if burn_scope == null:
		burn_scope = _structure_root_of(target_mesh)
	if burn_scope == null:
		return

	# Only geometry under the locked structure — never player / drone / SoI / etc.
	var potential := _collect_scope_meshes()
	if potential.is_empty():
		return

	var fire_y := global_position.y
	# Bottom-up: prefer unburned pieces whose bottoms sit at or above the flame,
	# sorted lowest-first so fire climbs the Man from the feet up.
	var candidates: Array[Dictionary] = []
	for mesh in potential:
		if mesh == null or not is_instance_valid(mesh):
			continue
		if mesh in burning_meshes or _mesh_has_fire(mesh):
			continue
		if mesh.has_meta("fire_burned") and bool(mesh.get_meta("fire_burned")):
			continue
		if _is_forbidden_burn_target(mesh):
			continue
		var aabb := _mesh_world_aabb(mesh)
		var bottom_y := aabb.position.y
		# Allow a little downward reach, but strongly prefer upward climb.
		if bottom_y < fire_y - 1.5:
			continue
		var horiz := Vector2(aabb.get_center().x - global_position.x, aabb.get_center().z - global_position.z).length()
		var climb := maxf(0.0, bottom_y - fire_y)
		candidates.append({
			"mesh": mesh,
			"bottom_y": bottom_y,
			"horiz": horiz,
			"climb": climb,
			"score": bottom_y * 0.15 + horiz + climb * 0.05,
		})

	if candidates.is_empty():
		# Fallback: any remaining scope mesh (sideways / slightly below).
		for mesh in potential:
			if mesh in burning_meshes or _mesh_has_fire(mesh):
				continue
			if _is_forbidden_burn_target(mesh):
				continue
			var aabb2 := _mesh_world_aabb(mesh)
			candidates.append({
				"mesh": mesh,
				"bottom_y": aabb2.position.y,
				"horiz": 0.0,
				"climb": 0.0,
				"score": aabb2.position.y,
			})

	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		# Climb upward: lower pieces first among those at/above the fire.
		if absf(float(a["bottom_y"]) - float(b["bottom_y"])) > 0.35:
			return float(a["bottom_y"]) < float(b["bottom_y"])
		return float(a["horiz"]) < float(b["horiz"])
	)

	var fire_count := _get_cached_fire_count()
	var throttle := 1.0 if fire_count <= MAX_SCENE_FIRE_NODES else 0.35
	var absorbed := 0
	for entry in candidates:
		if absorbed >= SPREAD_MAX_PER_TICK:
			break
		var mesh: MeshInstance3D = entry["mesh"]
		var chance := (0.22 + intensity / 180.0) * throttle
		if float(entry["climb"]) < 4.0:
			chance = maxf(chance, 0.4 * throttle)
		if randf() < chance:
			absorb_mesh(mesh)
			absorbed += 1


## Fold another mesh into this fire — grows the node instead of spawning another.
func absorb_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null or not is_instance_valid(mesh):
		return
	if _is_forbidden_burn_target(mesh):
		return
	if burn_scope != null and not _is_under(burn_scope, mesh):
		return
	if mesh in burning_meshes:
		return
	if burn_phase != BurnPhase.BURNING:
		return  # a collapsed pile cannot take on another piece
	mesh.set_meta("fire_active", true)
	burning_meshes.append(mesh)
	_darken_mesh(mesh)
	# Grow intensity; visuals scale via growth_tier.
	intensity = minf(200.0, intensity + 12.0 + float(growth_tier) * 4.0)
	# Climb: move flame toward this piece's burning surface (bottom→mid as we grow).
	var climb_t := clampf(float(burning_meshes.size()) / 6.0, 0.0, 1.0)
	var dest := ignition_point_on_mesh_progress(mesh, climb_t)
	if not _surface_mode and dest.y >= global_position.y - 0.25:
		global_position = global_position.lerp(dest, 0.45)
		global_position.y = maxf(global_position.y, lerpf(global_position.y, dest.y, 0.65))
	_refresh_growth_tier()
	fire_spread.emit(mesh)


func _refresh_growth_tier() -> void:
	var pieces := burning_meshes.size()
	var from_pieces := mini(4, maxi(0, pieces - 1))
	var from_intensity := clampi(int(intensity / 45.0), 0, 4)
	var next_tier := clampi(maxi(from_pieces, from_intensity), 0, 4)
	if next_tier != growth_tier:
		growth_tier = next_tier
		_apply_growth_visuals(false)


## Scale particle systems / lights for the current growth tier (convincing at each step).
func _apply_growth_visuals(force: bool) -> void:
	if not force and growth_tier == _applied_growth_tier:
		return
	_applied_growth_tier = growth_tier
	_applied_quality = -1
	_applied_amount_bucket = -1
	# Tier table: amount, smoke amount, ember amount, emission radius, light energy.
	var flame_amounts: Array[int] = [14, 24, 36, 48, 56]
	var smoke_amounts: Array[int] = [16, 28, 40, 52, 64]
	var ember_amounts: Array[int] = [8, 14, 20, 26, 32]
	var radii: Array[float] = [0.2, 0.35, 0.55, 0.85, 1.2]
	var smoke_vels: Array[float] = [3.5, 5.0, 6.5, 8.0, 9.5]
	var smoke_gravs: Array[float] = [7.0, 9.0, 11.0, 13.0, 15.0]
	var flame_n: int = flame_amounts[growth_tier]
	var smoke_n: int = smoke_amounts[growth_tier]
	var ember_n: int = ember_amounts[growth_tier]
	var radius: float = radii[growth_tier]
	var smoke_vel: float = smoke_vels[growth_tier]
	var smoke_grav: float = smoke_gravs[growth_tier]
	# In surface mode the emitters keep a fixed budget and unit scale (their
	# emission points are world offsets); `_refresh_surface_ratios` scales them.
	if flame_particles != null:
		if not _surface_mode:
			flame_particles.amount = flame_n
		var fmat := flame_particles.process_material as ParticleProcessMaterial
		if fmat != null:
			fmat.emission_sphere_radius = radius
			fmat.initial_velocity_max = 3.0 + float(growth_tier) * 1.1
			fmat.gravity = Vector3(0, 5.0 + float(growth_tier) * 1.5, 0)
		if not _surface_mode:
			flame_particles.scale = Vector3.ONE * (0.85 + float(growth_tier) * 0.22)
	if smoke_particles != null:
		if not _surface_mode:
			smoke_particles.amount = smoke_n
		var smat := smoke_particles.process_material as ParticleProcessMaterial
		if smat != null:
			smat.emission_sphere_radius = radius * 1.2
			smat.initial_velocity_min = smoke_vel * 0.55
			smat.initial_velocity_max = smoke_vel
			smat.gravity = Vector3(0, smoke_grav, 0)
		if not _surface_mode:
			smoke_particles.scale = Vector3.ONE * (0.9 + float(growth_tier) * 0.25)
	if ember_particles != null:
		if not _surface_mode:
			ember_particles.amount = ember_n
		var emat := ember_particles.process_material as ParticleProcessMaterial
		if emat != null:
			emat.emission_sphere_radius = radius
			emat.initial_velocity_max = 4.0 + float(growth_tier) * 1.2
			emat.gravity = Vector3(0, 4.5 + float(growth_tier) * 1.4, 0)
	if fire_light != null:
		fire_light.light_energy = 4.0 + float(growth_tier) * 2.5
		fire_light.omni_range = 10.0 + float(growth_tier) * 6.0
	if fire_light_2 != null:
		fire_light_2.light_energy = 2.0 + float(growth_tier) * 1.8
		fire_light_2.omni_range = 18.0 + float(growth_tier) * 8.0
	if _surface_mode:
		_refresh_surface_ratios()


## Meshes under burn_scope only (excludes player / drone / SoI / tools).
func _collect_scope_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if burn_scope == null or not is_instance_valid(burn_scope):
		return out
	for node in burn_scope.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible:
			continue
		if _is_forbidden_burn_target(mi):
			continue
		if _is_terrain(mi):
			continue
		var sz := mi.get_aabb().size.length()
		if sz < 0.15:
			continue
		out.append(mi)
	return out


## Never ignite the player, drones, SoI markers, cameras, tools, etc.
static func _is_forbidden_burn_target(mesh: MeshInstance3D) -> bool:
	if mesh == null:
		return true
	var n: Node = mesh
	while n != null:
		var nm := String(n.name).to_lower()
		if (
			"player" in nm or "drone" in nm or "camera" in nm or "soi" in nm
			or "extinguisher" in nm or "tool" in nm or "crosshair" in nm
			or "vehicle" in nm or "euc" in nm or "avatar" in nm
			or "charactermodel" in nm or "pinbody" in nm or "pinhead" in nm
			or nm == "characterbody3d" or "hud" in nm
		):
			return true
		if n.is_in_group("player") or n.is_in_group("drone") or n.is_in_group("soi") or n.is_in_group("vehicles"):
			return true
		if n is CharacterBody3D:
			return true
		# Scripted world props that must never burn as collateral.
		var scr: Script = n.get_script() as Script
		if scr != null:
			var sp := String(scr.resource_path).to_lower()
			if "soi_marker" in sp or "fpv_drone" in sp or "soi_preview" in sp or "soi_subsurface" in sp:
				return true
		n = n.get_parent()
	var mesh_nm := mesh.name.to_lower()
	for kw in ["player", "drone", "soi", "camera", "extinguisher", "tool", "halo", "pinbody", "pinhead"]:
		if kw in mesh_nm:
			return true
	return false


## World-space AABB of a MeshInstance3D (handles scaled ModelRoot props).
static func _mesh_world_aabb(mesh: MeshInstance3D) -> AABB:
	if mesh == null or mesh.mesh == null:
		return AABB(mesh.global_position if mesh else Vector3.ZERO, Vector3.ONE)
	return mesh.global_transform * mesh.get_aabb()


static func _node_world_aabb(root: Node) -> AABB:
	var first := true
	var merged := AABB()
	if root is MeshInstance3D and (root as MeshInstance3D).mesh != null:
		merged = _mesh_world_aabb(root as MeshInstance3D)
		first = false
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible:
			continue
		var a := _mesh_world_aabb(mi)
		if first:
			merged = a
			first = false
		else:
			merged = merged.merge(a)
	return merged


static func _aabb_distance(a: AABB, b: AABB) -> float:
	var dx := 0.0
	if a.end.x < b.position.x:
		dx = b.position.x - a.end.x
	elif b.end.x < a.position.x:
		dx = a.position.x - b.end.x
	var dy := 0.0
	if a.end.y < b.position.y:
		dy = b.position.y - a.end.y
	elif b.end.y < a.position.y:
		dy = a.position.y - b.end.y
	var dz := 0.0
	if a.end.z < b.position.z:
		dz = b.position.z - a.end.z
	elif b.end.z < a.position.z:
		dz = a.position.z - b.end.z
	return sqrt(dx * dx + dy * dy + dz * dz)


static func _aabb_distance_to_point(a: AABB, p: Vector3) -> float:
	var q := Vector3(
		clampf(p.x, a.position.x, a.end.x),
		clampf(p.y, a.position.y, a.end.y),
		clampf(p.z, a.position.z, a.end.z))
	return q.distance_to(p)


## PlacedProp / Camps / known structure root for same-model sibling spread.
static func _structure_root_of(mesh: Node) -> Node:
	var n := mesh
	while n != null:
		if n is PlacedProp:
			return n
		var nm := String(n.name).to_lower()
		if "modelroot" == nm:
			return n.get_parent() if n.get_parent() != null else n
		if "camp" in nm or "linkagelab" in nm or "located" in nm:
			return n
		n = n.get_parent()
	return mesh.get_parent() if mesh != null else null


static func _is_under(ancestor: Node, node: Node) -> bool:
	var n := node
	while n != null:
		if n == ancestor:
			return true
		n = n.get_parent()
	return false


## World point on a mesh. progress 0 = near bottom (ignition), 1 = near top.
static func ignition_point_on_mesh_progress(mesh: MeshInstance3D, progress: float) -> Vector3:
	if mesh == null:
		return Vector3.ZERO
	var t := clampf(progress, 0.0, 1.0)
	# WORLD AABB. This used to work in the mesh's LOCAL frame: local Y is not up
	# on a Z-up GLB, and the "lift" was taken from the local height and added as
	# metres — on an inch-unit import that put the flame metres above the model.
	var box := _mesh_world_aabb(mesh)
	var world := box.get_center()
	world.y = box.position.y + box.size.y * lerpf(0.12, 0.92, t) + 0.15
	return world


## Default: mid-upper surface (after the fire has climbed).
static func ignition_point_on_mesh(mesh: MeshInstance3D) -> Vector3:
	return ignition_point_on_mesh_progress(mesh, 0.85)


## Bottom ignition point — Man / tall props catch from the feet first.
static func ignition_point_on_mesh_bottom(mesh: MeshInstance3D) -> Vector3:
	return ignition_point_on_mesh_progress(mesh, 0.08)


func _find_nearby_meshes(pos: Vector3, range_dist: float,
		source_aabb: AABB = AABB()) -> Array[MeshInstance3D]:
	# Prefer scope meshes when locked; otherwise fall back to global cache.
	var candidates: Array[MeshInstance3D] = []
	if burn_scope != null and is_instance_valid(burn_scope):
		candidates = _collect_scope_meshes()
	else:
		candidates = _get_cached_flammable_meshes()
	var result: Array[MeshInstance3D] = []
	var use_source := source_aabb.size.length_squared() > 1e-4
	for mesh in candidates:
		if mesh == null or not is_instance_valid(mesh):
			continue
		if not mesh.visible or _is_forbidden_burn_target(mesh):
			continue
		var maabb := _mesh_world_aabb(mesh)
		var dist := _aabb_distance_to_point(maabb, pos)
		if use_source:
			dist = minf(dist, _aabb_distance(source_aabb, maabb))
		if dist <= range_dist:
			result.append(mesh)
	return result


func _is_terrain(mesh: MeshInstance3D) -> bool:
	var name_lower := mesh.name.to_lower()
	# Skip terrain, ground, and player equipment (fire extinguisher, etc.)
	if "terrain" in name_lower or "ground" in name_lower or "floor" in name_lower or "temporary" in name_lower:
		return true
	if "extinguisher" in name_lower or "player" in name_lower or "tool" in name_lower:
		return true
	return false

func _mesh_has_fire(mesh: MeshInstance3D) -> bool:
	return mesh != null and mesh.has_meta("fire_active") and bool(mesh.get_meta("fire_active"))


func _darken_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null:
		return
	if _surface_mode:
		_apply_char_overlay(mesh)  # the burn front darkens it progressively
		return
	if not mesh.has_meta("fire_pre_burn_override"):
		mesh.set_meta("fire_pre_burn_override", mesh.material_override)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.08, 0.06, 1.0)
	mat.roughness = 1.0
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.08, 0.0)
	mat.emission_energy_multiplier = 0.4
	mesh.material_override = mat


func _char_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null or not is_instance_valid(mesh):
		return
	if mesh.has_meta("fire_char_overlay"):
		return  # already charred by the burn front, to exactly where it reached
	if not mesh.has_meta("fire_pre_burn_override"):
		mesh.set_meta("fire_pre_burn_override", mesh.material_override)
	var char_mat := StandardMaterial3D.new()
	char_mat.albedo_color = Color(0.05, 0.04, 0.03, 1.0)
	char_mat.roughness = 1.0
	char_mat.metallic = 0.0
	char_mat.emission_enabled = true
	char_mat.emission = Color(0.2, 0.08, 0.02)
	char_mat.emission_energy_multiplier = 0.3
	mesh.material_override = char_mat


func _engulf_nearby_meshes() -> void:
	if target_mesh == null:
		return
	# Char + absorb remaining pieces of THIS structure only (no new FireNodes).
	for mesh in _collect_scope_meshes():
		if mesh == target_mesh or mesh in burning_meshes:
			continue
		if _is_forbidden_burn_target(mesh):
			continue
		absorb_mesh(mesh)


## The structure fails. What is left of it drops into the base over a second or
## two (surface fires: the ash shader's `collapse`), a FireAshPile is heaped up
## over the footprint, and the fire moves down to it.
func _begin_collapse() -> void:
	if burn_phase != BurnPhase.BURNING:
		return
	burn_phase = BurnPhase.COLLAPSING
	_collapse_t = 0.0
	_whooshed = false
	for mesh in nearby_meshes_engulfed:
		if is_instance_valid(mesh):
			_char_mesh(mesh)
	nearby_meshes_engulfed.clear()
	var foot := _pile_footprint()
	var centre: Vector3 = foot["centre"]
	var radius: Vector2 = foot["radius"]
	var fell_from: float = foot["height"]
	var pile_h := minf(clampf(fell_from * 0.12, 0.2, 1.6), minf(radius.x, radius.y) * 0.9)
	_collapse_seconds = 0.5
	if _surface_mode:
		if _ash_mat == null:
			_burn_away(0.0)  # a front held back by spray: collapse from standing
		_collapse_from_dissolve = float(_ash_mat.get_shader_parameter("dissolve"))
		_ash_mat.set_shader_parameter("pile_xz", Vector2(centre.x, centre.z))
		_ash_mat.set_shader_parameter("pile_radius", radius)
		_ash_mat.set_shader_parameter("pile_h", pile_h)
		# About the time it takes to fall that far, plus the moment it lets go.
		_collapse_seconds = clampf(sqrt(2.0 * fell_from / 9.8) * 1.15 + 0.4, 1.2, 3.2)

	ash_pile = FireAshPile.new()
	ash_pile.name = "FireAshPile"
	get_parent().add_child(ash_pile)
	ash_pile.setup(centre, radius, pile_h, fell_from, burn_scope)
	ash_pile.adopt_emitters(flame_particles, smoke_particles, ember_particles)

	# The fire is at the base now; the pile draws it. Our own emitters stop (what
	# is already in the air finishes), and the lights fade in _process_aftermath.
	_surface_mode = false
	global_position = centre + Vector3(0.0, pile_h, 0.0)
	for ps: GPUParticles3D in [flame_particles, smoke_particles, ember_particles, ignition_particles]:
		if ps != null:
			ps.emitting = false
	if indicator_mesh != null:
		indicator_mesh.visible = false
	intensity = maxf(intensity, 60.0)


## Where the pile goes: the footprint of the BASE (the bottom quarter of the
## structure), not of its widest part — an overhanging top falls inward.
func _pile_footprint() -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var base_y := global_position.y
	var h := 1.0
	if _burn_points.size() >= 8:
		h = maxf(_burn_top_y - _burn_base_y, 0.01)
		base_y = _burn_base_y
		var cut := _burn_base_y + maxf(h * 0.25, 0.3)
		for p in _burn_points:
			if p.y > cut:
				break  # sorted by height
			lo = lo.min(Vector2(p.x, p.z))
			hi = hi.max(Vector2(p.x, p.z))
	else:
		var meshes: Array[MeshInstance3D] = burning_meshes.duplicate()
		if target_mesh != null and is_instance_valid(target_mesh) and target_mesh not in meshes:
			meshes.append(target_mesh)
		var top := -INF
		base_y = INF
		for m in meshes:
			if m == null or not is_instance_valid(m) or m.mesh == null:
				continue
			var box := _mesh_world_aabb(m)
			lo = lo.min(Vector2(box.position.x, box.position.z))
			hi = hi.max(Vector2(box.end.x, box.end.z))
			base_y = minf(base_y, box.position.y)
			top = maxf(top, box.end.y)
		if base_y == INF:
			base_y = _find_ground_level()
		else:
			h = maxf(top - base_y, 0.01)
	if lo.x > hi.x:
		lo = Vector2(global_position.x, global_position.z)
		hi = lo
	var mid := (lo + hi) * 0.5
	return {
		"centre": Vector3(mid.x, base_y, mid.y),
		"radius": Vector2(maxf((hi.x - lo.x) * 0.55, 0.5), maxf((hi.y - lo.y) * 0.55, 0.5)),
		"height": h,
	}


## Collapsing, then burning down as a pile. This node is only the fire's HANDLE
## from here (the extinguisher, fire damage and the event act on it); it goes
## once there is no open flame, and the pile carries on to embers and ash alone.
func _process_aftermath(delta: float, being_sprayed: bool) -> void:
	if being_sprayed:
		intensity -= EXTINGUISHER_DAMAGE * delta * spray_bodies.size()
	# Our own lights hand over to the pile's.
	for l: OmniLight3D in [fire_light, fire_light_2]:
		if l != null:
			l.light_energy = lerpf(l.light_energy, 0.0, 0.15)
	if burn_phase == BurnPhase.COLLAPSING:
		_advance_collapse(delta)
		return
	if ash_pile == null or not is_instance_valid(ash_pile):
		_leave_quietly()  # the structure was restored or deleted under us
		return
	var flame := ash_pile.flame_level()
	if flame <= 0.0:
		_leave_quietly()  # embers now: no longer a fire to fight
		return
	intensity = clampf(intensity, 0.0, 200.0)
	if intensity <= EXTINGUISH_THRESHOLD:
		ash_pile.douse()
		_extinguish()
		return
	if not being_sprayed:
		intensity = move_toward(intensity, 8.0 + 52.0 * flame, 40.0 * delta)
	state = FireState.MEDIUM if flame > 0.5 else FireState.SMALL


func _advance_collapse(delta: float) -> void:
	_collapse_t += delta
	var u := clampf(_collapse_t / _collapse_seconds, 0.0, 1.0)
	if _ash_mat != null:
		_ash_mat.set_shader_parameter("collapse", u)
		# The last scraps burn up as they land, not on the way down.
		_ash_mat.set_shader_parameter("dissolve", lerpf(_collapse_from_dissolve,
			COLLAPSE_END_DISSOLVE, smoothstep(0.5, 1.0, u)))
	var pile_ok := ash_pile != null and is_instance_valid(ash_pile)
	if pile_ok:
		ash_pile.set_rise(u)
		if not _whooshed and u >= 0.55:
			_whooshed = true
			ash_pile.whoosh()  # it hits its own fire
	if u >= 1.0:
		_settle_into_pile()


## The fall is over: the structure's meshes are gone (hidden, restorable) and
## the pile starts burning down.
func _settle_into_pile() -> void:
	var to_burn: Array[MeshInstance3D] = burning_meshes.duplicate()
	if target_mesh != null and is_instance_valid(target_mesh) and target_mesh not in to_burn:
		to_burn.append(target_mesh)
	for mesh in _charred:
		if is_instance_valid(mesh) and mesh not in to_burn:
			to_burn.append(mesh)
	for mesh in to_burn:
		if mesh != null and is_instance_valid(mesh):
			mesh.set_meta("fire_active", false)
			_burn_out_mesh(mesh)
			mesh_destroyed.emit(mesh)
	burning_meshes.clear()
	target_mesh = null  # this fire no longer spreads
	burn_phase = BurnPhase.PILE
	state = FireState.MEDIUM
	if ash_pile != null and is_instance_valid(ash_pile):
		if not _whooshed:
			_whooshed = true
			ash_pile.whoosh()
		ash_pile.ignite()


## Gone without having been put out: burned down to embers, or its structure
## was restored. The event is told the fire is over; nobody is rewarded.
func _leave_quietly() -> void:
	set_process(false)
	for ps: GPUParticles3D in [flame_particles, smoke_particles, ember_particles, ignition_particles]:
		if ps != null:
			ps.emitting = false
	if not _extinguish_signalled:
		_extinguish_signalled = true
		fire_extinguished.emit()
	queue_free()


## Hide a fully burned mesh (keep in tree for regenerate) and mark parent prop.
func _burn_out_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null or not is_instance_valid(mesh):
		return
	if not mesh.has_meta("fire_pre_burn_override"):
		mesh.set_meta("fire_pre_burn_override", mesh.material_override)
	_char_mesh(mesh)
	mesh.set_meta("fire_burned", true)
	mesh.visible = false
	_register_burned_mesh(mesh)
	var n: Node = mesh
	while n != null:
		if n is PlacedProp:
			(n as PlacedProp).mark_burned()
			break
		n = n.get_parent()
	invalidate_flammable_mesh_cache()

## Find ground level below the fire using raycast
func _find_ground_level() -> float:
	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return 0.0
	
	var origin := global_position + Vector3(0, 2, 0)
	var end := global_position + Vector3(0, -50, 0)
	
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collision_mask = 0xFFFFFFFF
	
	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return 0.0
	
	return result.position.y

func _extinguish() -> void:
	# The char stays exactly where the front reached; only the embers go out.
	if _char_mat != null:
		_char_mat.set_shader_parameter("ember", 0.0)
	# Char the target mesh (make it black/burned looking)
	if target_mesh != null and is_instance_valid(target_mesh):
		target_mesh.set_meta("fire_active", false)
		_char_mesh(target_mesh)
	else:
		pass
	
	# Immediately stop and hide everything
	if ignition_particles != null:
		ignition_particles.emitting = false
		ignition_particles.visible = false
	
	if flame_particles != null:
		flame_particles.emitting = false
		flame_particles.visible = false
	
	if smoke_particles != null:
		smoke_particles.emitting = false
		smoke_particles.visible = false

	if ember_particles != null:
		ember_particles.emitting = false
		ember_particles.visible = false

	if fire_light != null:
		fire_light.light_energy = 0.0

	if fire_light_2 != null:
		fire_light_2.light_energy = 0.0

	# Hide indicator immediately
	if indicator_mesh != null:
		indicator_mesh.visible = false
	
	# Emit signal BEFORE queue_free so event can process it
	if not _extinguish_signalled:
		_extinguish_signalled = true
		fire_extinguished.emit()
	if _had_extinguisher_help :
		var tree := get_tree()
		if tree != null :
			tree.call_group_flags( SceneTree.GROUP_CALL_DEFERRED, "mars_college_credits_ui", "on_fire_extinguished_reward" )
	
	# Quick cleanup - delay to let signals process
	var tween := create_tween()
	tween.tween_callback(queue_free).set_delay(0.5)

func _on_body_entered(body: Node3D) -> void:
	if body.has_method("is_extinguisher_spray"):
		if body.is_extinguisher_spray():
			if body not in spray_bodies:
				spray_bodies.append(body)

func _on_body_exited(body: Node3D) -> void:
	var idx := spray_bodies.find(body)
	if idx >= 0:
		spray_bodies.remove_at(idx)

func _get_time_scale() -> float:
	var tree := get_tree()
	if tree == null:
		return 1.0
	
	var root := tree.root
	for child in root.get_children():
		if "time_scale" in child:
			return float(child.time_scale)
	
	return 1.0

func _get_fire_spread_range() -> float:
	var tree := get_tree()
	if tree == null:
		return 8.0

	var root := tree.root
	for child in root.get_children():
		if "fire_spread_range" in child:
			return float(child.fire_spread_range)

	return 8.0

func _get_fire_engulf_range() -> float:
	var tree := get_tree()
	if tree == null:
		return 5.0

	var root := tree.root
	for child in root.get_children():
		if "fire_engulf_range" in child:
			return float(child.fire_engulf_range)

	return 5.0

func _get_cached_fire_count() -> int:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_fire_count_update_sec >= _FIRE_COUNT_CACHE_SECONDS:
		var tree := get_tree()
		if tree != null:
			_cached_fire_count = tree.get_nodes_in_group("fire_nodes").size()
			_last_fire_count_update_sec = now
	return _cached_fire_count

func _get_cached_flammable_meshes() -> Array[MeshInstance3D]:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_mesh_cache_update_sec >= _MESH_CACHE_REFRESH_SECONDS or _cached_flammable_meshes.is_empty():
		_rebuild_flammable_mesh_cache()
		_last_mesh_cache_update_sec = now
	return _cached_flammable_meshes

func _rebuild_flammable_mesh_cache() -> void:
	_cached_flammable_meshes.clear()
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	var stack : Array[Node] = [tree.current_scene]
	while not stack.is_empty():
		var node: Node = stack.pop_back() as Node
		if node is MeshInstance3D:
			var mesh := node as MeshInstance3D
			if (
				mesh.mesh != null
				and mesh.is_visible_in_tree()
				and not _is_terrain(mesh)
				and _is_allowed_flammable_mesh(mesh)
			):
				var aabb_size: Vector3 = mesh.get_aabb().size
				if aabb_size.length() > 0.5:
					_cached_flammable_meshes.append(mesh)
		for child: Node in node.get_children():
			stack.append(child)


## Non-prop meshes are NOT globally flammable — only burnable PlacedProps /
## explicit structure roots. Hard-exclude player / drone / SoI.
static func _is_allowed_flammable_mesh(mesh: MeshInstance3D) -> bool:
	if mesh == null:
		return false
	if _is_forbidden_burn_target(mesh):
		return false
	if mesh.has_meta("fire_burned") and bool(mesh.get_meta("fire_burned")):
		return false
	if not mesh.visible:
		return false
	if mesh.has_meta("prop_burnable") and bool(mesh.get_meta("prop_burnable")):
		return true
	var n: Node = mesh
	while n != null:
		if n is PlacedProp:
			return (n as PlacedProp).burnable
		n = n.get_parent()
	# Legacy camp / LinkageLab meshes only when under a known structure name.
	var p: Node = mesh
	while p != null:
		var nm := String(p.name).to_lower()
		if "camp" in nm or "linkagelab" in nm or "located" in nm:
			return true
		p = p.get_parent()
	return false

func apply_extinguisher_damage(damage: float) -> void:
	if damage > 0.0 :
		_had_extinguisher_help = true
	intensity -= damage
	intensity = maxf(intensity, 0.0)

func get_state_text() -> String:
	if burn_phase == BurnPhase.COLLAPSING:
		return "COLLAPSING!"
	if burn_phase == BurnPhase.PILE:
		return "Burning down"
	match state:
		FireState.SMALL:
			return "Small fire"
		FireState.MEDIUM:
			return "Growing"
		FireState.LARGE:
			return "Large!"
		FireState.ENGULFING:
			return "ENGULFING!"
		FireState.INFERNO:
			return "INFERNO!!!"
	return "Fire"

## Pause fire effects (called when time is sped up to save GPU)
func pause_fire() -> void:
	if burn_phase != BurnPhase.BURNING:
		return  # the pile draws the fire now, and it is cheap
	# Hide visual effects but keep state
	if ignition_particles != null:
		ignition_particles.emitting = false
		ignition_particles.visible = false
	if flame_particles != null:
		flame_particles.emitting = false
		flame_particles.visible = false
	if smoke_particles != null:
		smoke_particles.emitting = false
		smoke_particles.visible = false
	if fire_light != null:
		fire_light.visible = false
	if fire_light_2 != null:
		fire_light_2.visible = false
	# Keep indicator visible as a small marker
	if indicator_mesh != null:
		indicator_mesh.visible = true

## Resume fire effects (called when back to realtime)
func resume_fire() -> void:
	if burn_phase != BurnPhase.BURNING:
		return
	# Restore visual effects
	if ignition_particles != null:
		ignition_particles.visible = true
		ignition_particles.emitting = true
	if flame_particles != null:
		flame_particles.visible = true
		flame_particles.emitting = true
	if smoke_particles != null:
		smoke_particles.visible = true
		smoke_particles.emitting = true
	if fire_light != null:
		fire_light.visible = true
	if fire_light_2 != null:
		fire_light_2.visible = true
	if indicator_mesh != null:
		indicator_mesh.visible = true
	# Force visual update
	_update_visuals_immediate()


# ---------------------------------------------------------------------------
# Surface burn — the climbing burn front
# ---------------------------------------------------------------------------

## Sample the structure's surface once (world space) and switch the emitters to
## emit from those points. Falls back to the old point fire when the structure
## has no readable geometry.
func _setup_surface_burn() -> void:
	if target_mesh == null or not is_instance_valid(target_mesh):
		return
	if burn_scope == null:
		burn_scope = _structure_root_of(target_mesh)
	var meshes := _collect_scope_meshes()
	if meshes.is_empty():
		meshes = [target_mesh]
	var pts := sample_surface_points(meshes, MAX_SURFACE_POINTS)
	if pts.size() < 8:
		return
	_burn_points = pts
	_burn_base_y = pts[0].y
	_burn_top_y = pts[pts.size() - 1].y
	_ignite_xz = Vector2(global_position.x, global_position.z)
	_burn_reach_max = 1.0
	for p in pts:
		_burn_reach_max = maxf(_burn_reach_max, Vector2(p.x, p.z).distance_to(_ignite_xz))
	_surface_mode = true
	_char_mat = ShaderMaterial.new()
	_char_mat.shader = CHAR_SHADER
	_char_mat.set_shader_parameter("soft_m", _char_soft_m())
	_char_mat.set_shader_parameter("ignite_xz", _ignite_xz)
	for m in meshes:
		_apply_char_overlay(m)
	# Emission points are world offsets from this node: no per-emitter offset or
	# scale may sit between them and the world.
	for ps: GPUParticles3D in [flame_particles, smoke_particles, ember_particles, ignition_particles]:
		if ps == null:
			continue
		ps.position = Vector3.ZERO
		ps.scale = Vector3.ONE
	if flame_particles != null:
		flame_particles.amount = SURFACE_FLAME_AMOUNT
		flame_particles.visibility_aabb = _surface_visibility_aabb(40.0)
	if smoke_particles != null:
		smoke_particles.amount = SURFACE_SMOKE_AMOUNT
		smoke_particles.visibility_aabb = _surface_visibility_aabb(140.0)
	if ember_particles != null:
		ember_particles.amount = SURFACE_EMBER_AMOUNT
		ember_particles.visibility_aabb = _surface_visibility_aabb(80.0)
	_burn_step = -1
	_advance_burn_front(0.0, 0.0, false)


## Particles are culled by this box, and the node now travels up the structure.
func _surface_visibility_aabb(rise_m: float) -> AABB:
	var h := _burn_top_y - _burn_base_y
	var r := _burn_reach_max + 12.0
	return AABB(Vector3(-r, -h - 4.0, -r), Vector3(r * 2.0, h * 2.0 + rise_m + 8.0, r * 2.0))


func _char_soft_m() -> float:
	return clampf((_burn_top_y - _burn_base_y) * 0.06, 0.12, 1.2)


func _apply_char_overlay(mesh: MeshInstance3D) -> void:
	if mesh == null or not is_instance_valid(mesh) or _char_mat == null:
		return
	if not mesh.has_meta("fire_char_overlay"):
		if mesh.material_overlay != null:
			mesh.set_meta("fire_pre_overlay", mesh.material_overlay)
		mesh.set_meta("fire_char_overlay", true)
	mesh.material_overlay = _char_mat
	if mesh not in _charred:
		_charred.append(mesh)


## The structure is fully black by now, so its materials can be swapped for the
## dissolving ash material without a visible change — and from there it is eaten
## away. (Instance `transparency` was tried first: it hides an alpha overlay
## entirely, so the charred structure flashed back to clean wood as it faded.)
func _burn_away(t: float) -> void:
	if _ash_mat == null:
		_ash_mat = ShaderMaterial.new()
		_ash_mat.shader = ASH_SHADER
		_ash_mat.set_shader_parameter("base_y", _burn_base_y)
		_ash_mat.set_shader_parameter("top_y", _burn_top_y)
		for m in _charred:
			if not is_instance_valid(m):
				continue
			if not m.has_meta("fire_pre_burn_override"):
				m.set_meta("fire_pre_burn_override", m.material_override)
			m.material_override = _ash_mat
			# The overlay redraws the whole mesh and would fill the holes back in.
			m.material_overlay = null
	t = clampf(t, 0.0, 1.0)
	_ash_mat.set_shader_parameter("dissolve", t)
	# The top goes first, so the flames come down with what is left of it —
	# otherwise they hang in the air where the top used to be.
	var step := 1000 + int(t * 6.0)
	if step != _burn_step:
		_burn_step = step
		var h := _burn_top_y - _burn_base_y
		_rebuild_emission_points(lerpf(_burn_top_y, _burn_base_y + h * 0.3, t), 1.0e9, h)


## World height of the front for a progress value. It starts a little above the
## base so there is something alight on the first frame.
func _front_y_for(progress: float) -> float:
	var h := _burn_top_y - _burn_base_y
	var start := minf(maxf(h * 0.04, 0.25), h)
	return _burn_base_y + start + (h - start) * clampf(progress, 0.0, 1.0)


func _advance_burn_front(delta: float, sim_hours: float, being_sprayed: bool) -> void:
	if burn_phase != BurnPhase.BURNING:
		return
	var h := maxf(_burn_top_y - _burn_base_y, 0.01)
	if not being_sprayed and burn_progress < 1.0:
		var climb_s := clampf(h / CLIMB_SPEED_MPS, CLIMB_MIN_SECONDS, CLIMB_MAX_SECONDS)
		burn_progress = minf(1.0, burn_progress
			+ delta / climb_s * clampf(intensity / 60.0, 0.5, 1.6)
			+ sim_hours / ENGULF_TIME_HOURS)
		if burn_progress >= 1.0:
			_engulf_nearby_meshes()
	var front_y := _front_y_for(burn_progress)
	# It catches at one spot and runs round the base well before it tops out.
	var reach := 1.5 + _burn_reach_max * clampf(burn_progress * 4.0, 0.0, 1.0) * 1.05
	if _char_mat != null:
		_char_mat.set_shader_parameter("front_y", front_y + _char_soft_m() * 0.5)
		_char_mat.set_shader_parameter("reach_m", reach)
		# Once the front is at the top the whole thing goes black, and over the
		# last stretch before it collapses it burns away.
		var life := clampf(fire_time_hours / DESTROY_TIME_HOURS, 0.0, 1.0)
		var all_black := smoothstep(0.3, 0.75, life) if burn_progress >= 1.0 else 0.0
		_char_mat.set_shader_parameter("char_all", all_black)
		if life >= BURN_AWAY_FROM and burn_progress >= 1.0:
			var eaten := (life - BURN_AWAY_FROM) / (1.0 - BURN_AWAY_FROM)
			_burn_away(minf(eaten, COLLAPSE_AT_DISSOLVE))
			if eaten >= COLLAPSE_AT_DISSOLVE:
				# Three quarters gone: what is left cannot stand.
				_begin_collapse()
				return
	var step := int(burn_progress * float(BURN_STEPS))
	if _ash_mat == null and step != _burn_step:
		_burn_step = step
		_rebuild_emission_points(front_y, reach)


## Point the emitters at the surface that is burning NOW: a band under the front,
## within reach of the ignition spot. Moves this node to the band's centre so
## the lights and the extinguisher's detection sphere travel with the fire.
func _rebuild_emission_points(front_y: float, reach: float, band_m: float = -1.0) -> void:
	var h := maxf(_burn_top_y - _burn_base_y, 0.01)
	var band := band_m if band_m > 0.0 else maxf(h * 0.4, 1.5)
	var active := PackedVector3Array()
	var reach2 := reach * reach
	for p in _burn_points:
		if p.y > front_y:
			break  # sorted by height
		if p.y < front_y - band:
			continue
		if Vector2(p.x, p.z).distance_squared_to(_ignite_xz) > reach2:
			continue
		active.append(p)
	if active.size() < 6:
		# Nothing in the band yet (first frames, or a gap in the model): use the
		# lowest points nearest the ignition spot so there is always a flame.
		active = _nearest_low_points(6)
	if active.is_empty():
		return
	var stride := maxi(1, int(ceil(float(active.size()) / float(MAX_EMISSION_POINTS))))
	var centre := Vector3.ZERO
	var picked := PackedVector3Array()
	for i in range(0, active.size(), stride):
		picked.append(active[i])
		centre += active[i]
	centre /= float(picked.size())
	global_position = centre
	var img := Image.create(picked.size(), 1, false, Image.FORMAT_RGBF)
	for i in picked.size():
		var o := picked[i] - centre
		img.set_pixel(i, 0, Color(o.x, o.y, o.z))
	var tex := ImageTexture.create_from_image(img)
	for ps: GPUParticles3D in [flame_particles, smoke_particles, ember_particles, ignition_particles]:
		if ps == null:
			continue
		var pm := ps.process_material as ParticleProcessMaterial
		if pm == null:
			continue
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
		pm.emission_point_texture = tex
		pm.emission_point_count = picked.size()
	set_meta("burn_active_points", active.size())
	_refresh_surface_ratios()


func _nearest_low_points(count: int) -> PackedVector3Array:
	var low_n := mini(_burn_points.size(), maxi(count, _burn_points.size() / 10))
	var ranked: Array = []
	for i in low_n:
		ranked.append(_burn_points[i])
	var at := _ignite_xz
	ranked.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return Vector2(a.x, a.z).distance_squared_to(at) < Vector2(b.x, b.z).distance_squared_to(at))
	var out := PackedVector3Array()
	for i in mini(count, ranked.size()):
		out.append(ranked[i])
	return out


## How much of the fixed particle budget to use: more as the fire covers more of
## the structure and as it grows hotter.
func _refresh_surface_ratios() -> void:
	if not _surface_mode or _burn_points.is_empty():
		return
	var share := float(int(get_meta("burn_active_points", 0))) / float(_burn_points.size())
	var ratio := clampf(0.14 + share * 1.7 + float(growth_tier) * 0.09, 0.14, 1.0)
	if flame_particles != null:
		flame_particles.amount_ratio = ratio
	if smoke_particles != null:
		smoke_particles.amount_ratio = clampf(ratio * 1.1, 0.2, 1.0)
	if ember_particles != null:
		ember_particles.amount_ratio = ratio


## World-space points spread over the surfaces of `meshes`, SORTED BY HEIGHT.
## Random points on sampled triangles rather than bare vertices: a box is eight
## vertices, and a wall of flame from eight points is eight candles.
static func sample_surface_points(meshes: Array, budget: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var live: Array[MeshInstance3D] = []
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi != null and is_instance_valid(mi) and mi.mesh != null:
			live.append(mi)
	if live.is_empty():
		return out
	var per_mesh := maxi(60, budget / live.size())
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	for mi in live:
		var xf := mi.global_transform
		var surfaces := mi.mesh.get_surface_count()
		var per_surface := maxi(20, per_mesh / maxi(surfaces, 1))
		for s in surfaces:
			var arr := mi.mesh.surface_get_arrays(s)
			if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = PackedInt32Array()
			if arr[Mesh.ARRAY_INDEX] != null:
				idx = arr[Mesh.ARRAY_INDEX]
			var tri_count := (idx.size() if not idx.is_empty() else verts.size()) / 3
			if tri_count <= 0:
				continue
			# AREA-weighted, several samples per triangle: a plain box is twelve
			# triangles, and one point each is far too few to carry a flame front.
			# Very dense meshes are strided so this stays a one-off few ms.
			var tri_step := maxi(1, tri_count / 20000)
			var tris := PackedInt32Array()
			var cum := PackedFloat32Array()
			var total_area := 0.0
			for ti in range(0, tri_count, tri_step):
				var t0 := ti * 3
				var pa: Vector3 = verts[t0] if idx.is_empty() else verts[idx[t0]]
				var pb: Vector3 = verts[t0 + 1] if idx.is_empty() else verts[idx[t0 + 1]]
				var pc: Vector3 = verts[t0 + 2] if idx.is_empty() else verts[idx[t0 + 2]]
				total_area += (pb - pa).cross(pc - pa).length() * 0.5
				tris.append(t0)
				cum.append(total_area)
			if total_area <= 0.0:
				continue
			for k in per_surface:
				var t := tris[mini(cum.bsearch(rng.randf() * total_area), tris.size() - 1)]
				var a: Vector3 = verts[t] if idx.is_empty() else verts[idx[t]]
				var b: Vector3 = verts[t + 1] if idx.is_empty() else verts[idx[t + 1]]
				var c: Vector3 = verts[t + 2] if idx.is_empty() else verts[idx[t + 2]]
				var u := rng.randf()
				var v := rng.randf()
				if u + v > 1.0:
					u = 1.0 - u
					v = 1.0 - v
				out.append(xf * (a + (b - a) * u + (c - a) * v))
	var list: Array = Array(out)
	list.sort_custom(func(p: Vector3, q: Vector3) -> bool: return p.y < q.y)
	return PackedVector3Array(list)
