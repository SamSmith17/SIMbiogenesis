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
const COLLAPSE_AT_DISSOLVE : float = FireTimeline.DISSOLVE_AT_COLLAPSE
## Dissolve value by which every last scrap is gone (reached as it lands).
const COLLAPSE_END_DISSOLVE : float = FireTimeline.DISSOLVE_GONE
## --- The fire is a function of SIM TIME ------------------------------------
## `burn_rec` is the FireTimeline record (see fire_timeline.gd). This node does
## not integrate anything: every frame it asks FireTimeline what the fire
## looks like at the clock's absolute hour and RECONCILES the scene to it, so
## scrubbing the clock backwards stands the structure up again and the whole
## life — ignition, climb, collapse, bonfire, embers, ash — runs at the same
## rate as the rest of the world. The record is written only when something
## HAPPENS: ignition (FireEvent), spraying (holds), going out, the player
## editing a duration. For a placed prop it is persisted on the prop record
## under "burn" (so it survives a reload and a prop rebuild); for a scene
## structure it lives here.
var burn_rec : Dictionary = {}
var prop_id : String = ""
## The phase this node last rendered (-1 = nothing yet). Transitions are what
## fire the one-shots (the whoosh) and the event signal.
var _last_phase : int = -1
var _last_out : bool = false
var ash_pile : FireAshPile = null
var _whooshed : bool = false
var _extinguish_signalled : bool = false
var _record_dirty : bool = false
var _record_flush_t : float = 0.0
var _hold_open : bool = false
var _meshes_burned : bool = false
var _eaten : bool = false
var _clock_node : Node = null
var _abs_h_fallback : float = 0.0
var _disposed : bool = false
var _damaged_this_frame : bool = false
var _flushed_once : bool = false
const RECORD_FLUSH_SECONDS : float = 1.0
## Intensity targets by phase; the extinguisher pulls against these.
const INTENSITY_RECOVER_PER_SEC : float = 12.0

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
var _surface_area_m2 : float = 0.0
var _engulfed : bool = false
## Total triangle area of the last sample_surface_points call (m2).
static var _last_sampled_area_m2 : float = 0.0

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
		_forget_prop_burn((root as PlacedProp).prop_id)
	invalidate_flammable_mesh_cache()
	return restored


## Drop a prop's burn record (Restore). Its FireNode sees the record gone on
## its next frame and disposes itself, pile and all.
static func _forget_prop_burn(pid: String) -> void:
	if pid.is_empty():
		return
	var loader := ServiceLocator.terrain_loader()
	if loader != null and loader.has_method("clear_prop_burn_record"):
		loader.call("clear_prop_burn_record", pid)


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
			_forget_prop_burn((n as PlacedProp).prop_id)
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
	if not prop_id.is_empty():
		set_meta("prop_id", prop_id)
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
	if _disposed:
		return
	# Real-time flicker (not affected by sim speed)
	_flicker_time += delta
	var t := _clock_hours(delta)

	# A placed prop's record is the authority. It can vanish (Restore, delete)
	# and its node can be rebuilt under us (any prop edit rebuilds them all).
	if not prop_id.is_empty():
		if not _refresh_prop_record():
			_dispose()
			return
		if burn_scope == null or not is_instance_valid(burn_scope):
			_rebind_scope()
			if burn_scope == null:
				return

	# The burn front. Set up on the first frame, not in _ready: the event places
	# this node AFTER add_child, and the ignition spot is where it was placed.
	if not _surface_setup_done:
		_surface_setup_done = true
		_setup_surface_burn()
	if burn_rec.is_empty():
		# A fire with no record (legacy caller): light it now, in memory.
		burn_rec = FireTimeline.make(t, _estimate_durations())

	# Check if being sprayed
	var being_sprayed := spray_bodies.size() > 0
	if being_sprayed:
		_had_extinguisher_help = true

	var st := FireTimeline.state_at(burn_rec, t)
	var phase := int(st["phase"])
	var out := bool(st["out"])

	# --- record writes: the extinguisher HOLDS the climb, then puts it out ---
	if not out and phase == FireTimeline.Phase.BURNING:
		if being_sprayed and not _hold_open:
			FireTimeline.begin_hold(burn_rec, t)
			_hold_open = true
			_record_dirty = true
		elif not being_sprayed and _hold_open:
			FireTimeline.end_hold(burn_rec, t)
			_hold_open = false
			_record_dirty = true
	elif _hold_open:
		FireTimeline.end_hold(burn_rec, t)
		_hold_open = false
		_record_dirty = true

	# Intensity is the fight: it sits at the phase's level and the spray pulls
	# it down; at the threshold the fire is OUT, written into the timeline.
	var target := _intensity_target(st)
	if (phase != _last_phase or out != _last_out) and not being_sprayed:
		intensity = target  # the clock jumped (scrub, load): no slow recovery
	if out or phase == FireTimeline.Phase.NONE:
		intensity = move_toward(intensity, 0.0, 60.0 * delta)
	elif being_sprayed or _damaged_this_frame:
		if being_sprayed:
			intensity -= EXTINGUISHER_DAMAGE * delta * spray_bodies.size()
		_damaged_this_frame = false
		if intensity <= EXTINGUISH_THRESHOLD:
			FireTimeline.put_out(burn_rec, t)
			_hold_open = false
			_record_dirty = true
			st = FireTimeline.state_at(burn_rec, t)
			phase = int(st["phase"])
			out = true
			_reward_extinguish()
	else:
		intensity = move_toward(intensity, target, INTENSITY_RECOVER_PER_SEC * delta)
	intensity = clampf(intensity, 0.0, 200.0)

	_apply_state(st, delta)

	if phase == FireTimeline.Phase.BURNING and not out:
		_refresh_growth_tier()
		_cluster_check_timer += delta
		if _cluster_check_timer >= _CLUSTER_CHECK_INTERVAL:
			_cluster_check_timer -= _CLUSTER_CHECK_INTERVAL
			_check_cluster_mode()
		# Legacy per-mesh spread inside the scope (surface mode already burns the
		# whole structure; this keeps intensity climbing on multi-mesh props).
		_spread_wall_timer += delta
		if _spread_wall_timer >= SPREAD_WALL_INTERVAL and intensity >= SPREAD_MIN_INTENSITY:
			_spread_wall_timer = 0.0
			_try_spread()
		state = FireState.INFERNO if intensity >= 150 else (
			FireState.LARGE if intensity >= 100 else (
			FireState.MEDIUM if intensity >= 60 else FireState.SMALL))
		if float(st["progress"]) >= 1.0 and state != FireState.INFERNO:
			state = FireState.ENGULFING
		_update_visuals_immediate()

	# The event hears "extinguished" ONCE, when there is no open flame left —
	# put out, or burned down to embers. The node itself stays: it is what
	# draws the fire at any time the clock is scrubbed to.
	var flame := not out and (phase == FireTimeline.Phase.BURNING
		or phase == FireTimeline.Phase.COLLAPSING
		or (phase == FireTimeline.Phase.PILE and float((st["look"] as Dictionary).get("flame", 0.0)) > 0.0))
	if not flame and phase != FireTimeline.Phase.NONE and not _extinguish_signalled:
		_extinguish_signalled = true
		fire_extinguished.emit()
	elif flame and _extinguish_signalled and phase == FireTimeline.Phase.BURNING:
		_extinguish_signalled = false  # scrubbed back into the fire

	_record_flush_t += delta
	if _record_dirty and (_record_flush_t >= RECORD_FLUSH_SECONDS or out):
		_flush_record()


## The fire's sim clock: the first root child with `get_absolute_hours` (Main),
## else hours accumulated from `time_scale` (the selftest rig).
func _clock_hours(delta: float) -> float:
	if _clock_node == null or not is_instance_valid(_clock_node):
		_clock_node = null
		var tree := get_tree()
		if tree != null:
			for child in tree.root.get_children():
				if child.has_method("get_absolute_hours") or "time_scale" in child:
					_clock_node = child
					break
	if _clock_node != null and _clock_node.has_method("get_absolute_hours"):
		return float(_clock_node.call("get_absolute_hours"))
	_abs_h_fallback += delta * _get_time_scale()
	return _abs_h_fallback


func _intensity_target(st: Dictionary) -> float:
	match int(st["phase"]):
		FireTimeline.Phase.BURNING:
			return 16.0 + 134.0 * float(st["progress"])
		FireTimeline.Phase.COLLAPSING:
			return 150.0
		FireTimeline.Phase.PILE:
			return 8.0 + 52.0 * float((st["look"] as Dictionary).get("flame", 0.0))
	return 0.0


## --- reconcile the scene to a timeline state --------------------------------
## Idempotent and ORDER-FREE: it must land the same picture whether the clock
## came forward from the previous frame or jumped back a day.
func _apply_state(st: Dictionary, delta: float) -> void:
	var phase := int(st["phase"])
	var out := bool(st["out"])
	var draw_phase := phase
	if out:
		draw_phase = FireTimeline.out_phase(burn_rec)
	# The whoosh is a one-shot on the way DOWN: it fires once as the fall passes
	# its midpoint (or on a jump straight past it), never on first draw of a
	# loaded pile, and re-arms when the clock is scrubbed back above it.
	var first_draw := _last_phase < 0
	if draw_phase < FireTimeline.Phase.COLLAPSING:
		_whooshed = false
	var landing := not first_draw and not _whooshed and (
		(draw_phase == FireTimeline.Phase.COLLAPSING and float(st["collapse"]) >= 0.55)
		or (draw_phase == FireTimeline.Phase.PILE and _last_phase <= FireTimeline.Phase.COLLAPSING))

	# 1. The structure's meshes: standing (char / ash) or gone (pile).
	var want_gone := draw_phase == FireTimeline.Phase.PILE
	if want_gone != _meshes_burned:
		_set_meshes_burned(want_gone)
	if draw_phase == FireTimeline.Phase.NONE:
		_clear_structure_visuals()
	elif _surface_mode:
		var dissolve := float(st["dissolve"])
		if dissolve > 0.0 and not _eaten:
			_set_eaten(true)
		elif dissolve <= 0.0 and _eaten:
			_set_eaten(false)
		if not _eaten:
			for m in _charred:  # back from "before the fire": the char returns
				if is_instance_valid(m) and not m.has_meta("fire_char_overlay"):
					_apply_char_overlay(m)
		if _char_mat != null:
			var front_y := _front_y_for(float(st["progress"]))
			var reach := 1.5 + _burn_reach_max * clampf(float(st["progress"]) * 4.0, 0.0, 1.0) * 1.05
			_char_mat.set_shader_parameter("front_y", front_y + _char_soft_m() * 0.5)
			_char_mat.set_shader_parameter("reach_m", reach)
			_char_mat.set_shader_parameter("char_all", float(st["char_all"]))
			_char_mat.set_shader_parameter("ember", 0.0 if out else 1.0)
		if _ash_mat != null:
			_ash_mat.set_shader_parameter("dissolve", dissolve)
			_ash_mat.set_shader_parameter("collapse", float(st["collapse"]))
	burn_progress = float(st["progress"])

	# 2. Our own emitters only burn the standing structure.
	var own_fire := draw_phase == FireTimeline.Phase.BURNING and not out
	if _surface_mode and own_fire:
		var step := int(burn_progress * float(BURN_STEPS))
		if float(st["dissolve"]) > 0.0:
			# The top goes first, so the flames come down with what is left of it.
			step = 1000 + int(float(st["dissolve"]) / COLLAPSE_AT_DISSOLVE * 6.0)
		if step != _burn_step:
			_burn_step = step
			var h := _burn_top_y - _burn_base_y
			if step >= 1000:
				_rebuild_emission_points(lerpf(_burn_top_y, _burn_base_y + h * 0.3,
					float(st["dissolve"]) / COLLAPSE_AT_DISSOLVE), 1.0e9, h)
			else:
				_rebuild_emission_points(_front_y_for(burn_progress),
					1.5 + _burn_reach_max * clampf(burn_progress * 4.0, 0.0, 1.0) * 1.05)
		if burn_progress >= 1.0 and _last_phase == FireTimeline.Phase.BURNING and not _engulfed:
			_engulfed = true
			_engulf_nearby_meshes()
	if not own_fire:
		for ps: GPUParticles3D in [flame_particles, smoke_particles, ember_particles, ignition_particles]:
			if ps != null:
				ps.emitting = false
		if indicator_mesh != null:
			indicator_mesh.visible = false
		for l: OmniLight3D in [fire_light, fire_light_2]:
			if l != null:
				l.light_energy = lerpf(l.light_energy, 0.0, 0.15)

	# 3. The pile: exists from the collapse on, drawn from the state.
	var want_pile := draw_phase >= FireTimeline.Phase.COLLAPSING
	if want_pile and (ash_pile == null or not is_instance_valid(ash_pile)):
		_spawn_pile()
	elif not want_pile and ash_pile != null and is_instance_valid(ash_pile):
		ash_pile.queue_free()
		ash_pile = null
	if ash_pile != null and is_instance_valid(ash_pile):
		if draw_phase == FireTimeline.Phase.COLLAPSING:
			ash_pile.set_rise(float(st["collapse"]))
			ash_pile.set_look(FireAshPile.look(0.0, FireTimeline.bonfire_h(burn_rec),
				FireTimeline.ember_h(burn_rec)), out)
			if landing:
				_whooshed = true
				ash_pile.whoosh()  # it hits its own fire
			global_position = ash_pile.global_position + Vector3(0.0, ash_pile.height, 0.0)
		elif draw_phase == FireTimeline.Phase.PILE:
			ash_pile.set_rise(1.0)
			ash_pile.set_look(st["look"] as Dictionary, out)
			if landing:
				_whooshed = true
				ash_pile.whoosh()  # a jump straight past the fall still lands
			global_position = ash_pile.global_position + Vector3(0.0, ash_pile.height, 0.0)

	# 4. The state line for the HUD.
	if draw_phase == FireTimeline.Phase.PILE:
		var flame := float((st["look"] as Dictionary).get("flame", 0.0))
		state = FireState.MEDIUM if flame > 0.5 else FireState.SMALL
	_last_phase = draw_phase
	_last_out = out


## Hide the structure (it has fallen into the pile) or stand it up again.
func _set_meshes_burned(gone: bool) -> void:
	_meshes_burned = gone
	var meshes: Array[MeshInstance3D] = _charred.duplicate()
	for m in burning_meshes:
		if is_instance_valid(m) and m not in meshes:
			meshes.append(m)
	if target_mesh != null and is_instance_valid(target_mesh) and target_mesh not in meshes:
		meshes.append(target_mesh)
	for mesh in meshes:
		if mesh == null or not is_instance_valid(mesh):
			continue
		if gone:
			mesh.set_meta("fire_active", false)
			_burn_out_mesh(mesh)
			mesh_destroyed.emit(mesh)
		else:
			mesh.visible = true
			if mesh.has_meta("fire_burned"):
				mesh.remove_meta("fire_burned")
			mesh.set_meta("fire_active", true)
	if not gone:
		var n: Node = burn_scope
		if n is PlacedProp:
			(n as PlacedProp).clear_burned_flag()
		invalidate_flammable_mesh_cache()


## Clock scrubbed to before the ignition: the structure as it was.
func _clear_structure_visuals() -> void:
	if _eaten:
		_set_eaten(false)
	for m in _charred:
		if is_instance_valid(m):
			_clear_char_overlay(m)
	if _char_mat != null:
		_char_mat.set_shader_parameter("char_all", 0.0)
	_burn_step = -1


## Swap the structure's own materials for the dissolving ash material (the
## char overlay is REMOVED: it redraws the whole mesh and would fill the holes
## back in), or put them back when the clock runs the other way.
func _set_eaten(on: bool) -> void:
	_eaten = on
	if on:
		if _ash_mat == null:
			_ash_mat = ShaderMaterial.new()
			_ash_mat.shader = ASH_SHADER
			_ash_mat.set_shader_parameter("base_y", _burn_base_y)
			_ash_mat.set_shader_parameter("top_y", _burn_top_y)
			var foot := _pile_footprint()
			var c: Vector3 = foot["centre"]
			_ash_mat.set_shader_parameter("pile_xz", Vector2(c.x, c.z))
			_ash_mat.set_shader_parameter("pile_radius", foot["radius"])
			_ash_mat.set_shader_parameter("pile_h", foot["pile_h"])
		for m in _charred:
			if not is_instance_valid(m):
				continue
			if not m.has_meta("fire_pre_burn_override"):
				m.set_meta("fire_pre_burn_override", m.material_override)
			m.material_override = _ash_mat
			m.material_overlay = null
	else:
		for m in _charred:
			if not is_instance_valid(m):
				continue
			if m.has_meta("fire_pre_burn_override"):
				m.material_override = m.get_meta("fire_pre_burn_override") as Material
				m.remove_meta("fire_pre_burn_override")
			else:
				m.material_override = null
			_apply_char_overlay(m)


## The pile is heaped over the footprint of the BASE (the bottom quarter of
## the structure), not of its widest part — an overhanging top falls inward.
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
	var radius := Vector2(maxf((hi.x - lo.x) * 0.55, 0.5), maxf((hi.y - lo.y) * 0.55, 0.5))
	return {
		"centre": Vector3(mid.x, base_y, mid.y),
		"radius": radius,
		"height": h,
		"pile_h": minf(clampf(h * 0.12, 0.2, 1.6), minf(radius.x, radius.y) * 0.9),
	}


func _spawn_pile() -> void:
	var foot := _pile_footprint()
	ash_pile = FireAshPile.new()
	ash_pile.name = "FireAshPile"
	get_parent().add_child(ash_pile)
	ash_pile.setup(foot["centre"], foot["radius"], foot["pile_h"], foot["height"], burn_scope)
	ash_pile.adopt_emitters(flame_particles, smoke_particles, ember_particles)
	for ps: GPUParticles3D in [flame_particles, smoke_particles, ember_particles, ignition_particles]:
		if ps != null:
			ps.emitting = false


## --- the record ---------------------------------------------------------------

## What this structure's burn should take, from its geometry (+ its packing
## mass where the catalog knows it), with the player's plan on top.
func _estimate_durations() -> Dictionary:
	var foot := _pile_footprint()
	var r: Vector2 = foot["radius"]
	var mass := -1.0
	var plan: Dictionary = {}
	if burn_scope is PlacedProp:
		var loader := ServiceLocator.terrain_loader()
		if loader != null and loader.has_method("get_prop_record"):
			var rec: Dictionary = loader.call("get_prop_record", (burn_scope as PlacedProp).prop_id)
			if not rec.is_empty():
				mass = float(PlacedPropRuntime.packed_spec_for_record(rec).get("mass_kg", -1.0))
				if rec.get("fire_plan") is Dictionary:
					plan = rec["fire_plan"]
	var est := FireTimeline.estimate(float(foot["height"]), maxf(r.x, r.y), _surface_area_m2, mass)
	return _with_plan(est, plan)


## A fire lit from the estimate keeps the estimate under "auto"; the player's
## plan overrides the durations themselves.
static func _with_plan(est: Dictionary, plan: Dictionary) -> Dictionary:
	var out := est.duplicate()
	out["auto_est"] = est.duplicate()
	for k in ["climb_h", "bonfire_h", "ember_h"]:
		if plan.has(k):
			out[k] = float(plan[k])
	return out


## The estimate for a placed prop that is NOT burning (the editor's preview):
## the same geometry sample a fire would take, from the prop's own meshes.
static func estimate_for_prop(prop: PlacedProp, rec: Dictionary) -> Dictionary:
	if prop == null:
		return {}
	var meshes: Array = []
	for node in prop.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi != null and mi.mesh != null and mi.visible and not _is_forbidden_burn_target(mi):
			meshes.append(mi)
	if meshes.is_empty():
		return {}
	var pts := sample_surface_points(meshes, 1200)
	if pts.size() < 8:
		return {}
	var h := pts[pts.size() - 1].y - pts[0].y
	var cut := pts[0].y + maxf(h * 0.25, 0.3)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in pts:
		if p.y > cut:
			break
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
	var r := maxf(maxf((hi.x - lo.x) * 0.55, (hi.y - lo.y) * 0.55), 0.5)
	var mass := float(PlacedPropRuntime.packed_spec_for_record(rec).get("mass_kg", -1.0))
	return FireTimeline.estimate(h, r, _last_sampled_area_m2, mass)


## Re-read the prop's record. False = the burn is gone (Restore / deleted).
func _refresh_prop_record() -> bool:
	var loader := ServiceLocator.terrain_loader()
	if loader == null or not loader.has_method("get_prop_record"):
		return not burn_rec.is_empty()
	var rec: Dictionary = loader.call("get_prop_record", prop_id)
	if rec.is_empty():
		return false
	var b: Variant = rec.get("burn", null)
	if not FireTimeline.is_record(b):
		# Nothing on the prop yet: fine until our first write has landed —
		# after that, a missing record means Restore forgot the fire.
		return not _flushed_once
	if not _record_dirty:
		burn_rec = b  # the UI may have edited a duration
	return true


## The prop was rebuilt (every prop edit rebuilds them all): find the new node,
## resample it and draw the current state onto it.
func _rebind_scope() -> void:
	var loader := ServiceLocator.terrain_loader()
	var prop: PlacedProp = null
	if loader != null and loader.has_method("_find_placed_prop_node"):
		prop = loader.call("_find_placed_prop_node", prop_id) as PlacedProp
	if prop == null:
		return
	burn_scope = prop
	burning_meshes.clear()
	_charred.clear()
	target_mesh = null
	for node in prop.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi != null and mi.mesh != null and not _is_forbidden_burn_target(mi):
			target_mesh = mi
			break
	if target_mesh == null:
		return
	burning_meshes.append(target_mesh)
	_surface_mode = false
	_surface_setup_done = false
	_eaten = false
	_meshes_burned = false
	_ash_mat = null
	_char_mat = null
	_burn_step = -1
	_last_phase = -1


func _flush_record() -> void:
	_record_dirty = false
	_record_flush_t = 0.0
	if prop_id.is_empty():
		return
	var loader := ServiceLocator.terrain_loader()
	if loader != null and loader.has_method("set_prop_burn_record"):
		loader.call("set_prop_burn_record", prop_id, burn_rec)
		_flushed_once = true


## Light this node's structure at `t` (FireEvent). Durations come from the
## geometry once it has been sampled, so they are filled in on the first frame.
func ignite_at(t: float) -> void:
	burn_rec = {"ignited_h": t}
	_record_dirty = true


func _reward_extinguish() -> void:
	if not _had_extinguisher_help:
		return
	var tree := get_tree()
	if tree != null:
		tree.call_group_flags(SceneTree.GROUP_CALL_DEFERRED, "mars_college_credits_ui", "on_fire_extinguished_reward")


## The burn was removed (Restore / prop deleted): leave nothing behind.
func _dispose() -> void:
	if _disposed:
		return
	_disposed = true
	if ash_pile != null and is_instance_valid(ash_pile):
		ash_pile.queue_free()
	for m in _charred:
		if is_instance_valid(m):
			_restore_burned_mesh(m)
	if not _extinguish_signalled:
		_extinguish_signalled = true
		fire_extinguished.emit()
	queue_free()


## One FireNode per placed prop that carries a burn record. Called after the
## props are rebuilt, so a saved fire comes back on reload at the right moment
## of its life, and a fire whose record was removed disposes itself.
static func sync_prop_fires(main: Node, loader: Node) -> void:
	if main == null or loader == null or not loader.has_method("placed_prop_records"):
		return
	var tree := main.get_tree()
	if tree == null:
		return
	var have := {}
	for n in tree.get_nodes_in_group("fire_nodes"):
		var pid := str(n.get_meta("prop_id", ""))
		if not pid.is_empty():
			have[pid] = true
	for rec in loader.call("placed_prop_records"):
		if not (rec is Dictionary):
			continue
		var pid := str((rec as Dictionary).get("id", ""))
		if pid.is_empty() or have.has(pid) or not FireTimeline.is_record((rec as Dictionary).get("burn", null)):
			continue
		var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
		if prop == null:
			continue
		var fire := FireNode.new()
		fire.name = "Fire_%s" % pid
		fire.prop_id = pid
		fire.burn_scope = prop
		fire.burn_rec = (rec as Dictionary).get("burn")
		for node in prop.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi != null and mi.mesh != null and not _is_forbidden_burn_target(mi):
				fire.target_mesh = mi
				break
		if fire.target_mesh == null:
			continue
		var scene := tree.current_scene if tree.current_scene != null else main
		scene.add_child(fire)
		var b: Dictionary = fire.burn_rec
		var at: Variant = b.get("ignite_pos", null)
		if at is Array and (at as Array).size() == 3:
			fire.global_position = Vector3(float(at[0]), float(at[1]), float(at[2]))
		else:
			fire.global_position = ignition_point_on_mesh_bottom(fire.target_mesh)


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
	if _last_phase > FireTimeline.Phase.BURNING:
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
		_damaged_this_frame = true
	intensity -= damage
	intensity = maxf(intensity, 0.0)

func get_state_text() -> String:
	if _last_out:
		return "Out"
	if _last_phase == FireTimeline.Phase.COLLAPSING:
		return "COLLAPSING!"
	if _last_phase == FireTimeline.Phase.PILE:
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
	if _last_phase != FireTimeline.Phase.BURNING:
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
	if _last_phase != FireTimeline.Phase.BURNING:
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
	_surface_area_m2 = _last_sampled_area_m2
	# A fire lit without durations (FireEvent lights it with just the hour):
	# estimate them from the geometry now that it is measured.
	if burn_rec.has("ignited_h") and not burn_rec.has("auto"):
		var lit := float(burn_rec["ignited_h"])
		var est := _estimate_durations()
		burn_rec = FireTimeline.make(lit, est, est.get("auto_est", est))
		burn_rec["ignite_pos"] = [global_position.x, global_position.y, global_position.z]
		_record_dirty = true
		_flush_record()


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


## World height of the front for a progress value. It starts a little above the
## base so there is something alight on the first frame.
func _front_y_for(progress: float) -> float:
	var h := _burn_top_y - _burn_base_y
	var start := minf(maxf(h * 0.04, 0.25), h)
	return _burn_base_y + start + (h - start) * clampf(progress, 0.0, 1.0)


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
	var area_sum := 0.0
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
			area_sum += total_area * float(tri_step) * _world_area_scale(xf)
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
	_last_sampled_area_m2 = area_sum
	var list: Array = Array(out)
	list.sort_custom(func(p: Vector3, q: Vector3) -> bool: return p.y < q.y)
	return PackedVector3Array(list)


## Area scale of a transform: det^(2/3) — exact for a uniform scale (an
## inch-unit import is 0.0254^2 per unit area), near enough for a mild
## anisotropic one.
static func _world_area_scale(xf: Transform3D) -> float:
	return pow(absf(xf.basis.determinant()), 2.0 / 3.0)
