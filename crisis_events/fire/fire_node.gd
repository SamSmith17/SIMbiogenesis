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

## Fire intensity (0-100, affects size and damage)
var intensity : float = 30.0

## Time elapsed since fire started (simulation time in hours)
var fire_time_hours : float = 0.0

## Time thresholds (in simulation hours)
const ENGULF_TIME_HOURS : float = 0.5  # 30 minutes
const DESTROY_TIME_HOURS : float = 1.0  # 1 hour
const SPREAD_CHECK_INTERVAL : float = 0.05

## Growth rate (intensity per sim hour) - ONLY for sim time
const GROWTH_RATE : float = 80.0

## Extinguisher damage rate (intensity per second of spray)
const EXTINGUISHER_DAMAGE : float = 50.0

## Intensity threshold to extinguish (when particles stop, fire is out)
const EXTINGUISH_THRESHOLD : float = 5.0

## LOD thresholds - when cluster manager takes over
const CLUSTER_TAKEOVER_THRESHOLD : int = 25   # Keep full particles for first 25 fires
const REALISTIC_FIRE_NODE_LIMIT : int = 5
const IGNITION_REALISM_SECONDS : float = 7.0

enum VisualQuality { HIGH, MEDIUM, LOW }

## Components - only indicator is always created, others are conditional
var flame_particles : GPUParticles3D = null
var smoke_particles : GPUParticles3D = null
var ignition_particles : GPUParticles3D = null
var fire_light : OmniLight3D = null
var fire_light_2 : OmniLight3D = null
var detection_area : Area3D = null
var indicator_mesh : MeshInstance3D = null

## Spread tracking
var spread_timer : float = 0.0
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

## Time this fire was created (for grace period before cluster management)
var _creation_time : float = 0.0

## Grace period - new fires always show particles for this many seconds
const NEW_FIRE_GRACE_PERIOD : float = 5.0
const _FIRE_COUNT_CACHE_SECONDS : float = 0.5
const _MESH_CACHE_REFRESH_SECONDS : float = 5.0
static var _cached_fire_count : int = 0
static var _last_fire_count_update_sec : float = -1000.0
static var _cached_flammable_meshes : Array[MeshInstance3D] = []
static var _last_mesh_cache_update_sec : float = -1000.0

func _ready() -> void:
	add_to_group("fire_nodes")
	_creation_time = Time.get_ticks_msec() / 1000.0
	spread_timer = randf() * SPREAD_CHECK_INTERVAL
	_cluster_check_timer = randf() * _CLUSTER_CHECK_INTERVAL
	if target_mesh != null and is_instance_valid(target_mesh):
		target_mesh.set_meta("fire_active", true)
	_create_indicator()
	_create_detection_area()
	
	# ALWAYS create fire visuals first - they're essential for visibility
	_create_fire_visuals()
	_visuals_created = true
	
	# New fires always start with their own visuals (grace period)
	# Cluster mode check happens in _process after grace period
	_cluster_managed = false
	
	_last_visual_intensity = intensity
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
	
	# Show our visuals
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

func _disable_own_visuals() -> void:
	# Hide our individual visuals - cluster manager will render shared ones
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

func _create_indicator() -> void:
	indicator_mesh = MeshInstance3D.new()
	indicator_mesh.name = "FireIndicator"
	
	var sphere := SphereMesh.new()
	sphere.radius = 0.6  # Larger initial size
	sphere.height = 1.2
	indicator_mesh.mesh = sphere
	
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.5, 0.0, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.6, 0.1)
	mat.emission_energy_multiplier = 8.0  # Much brighter!
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	indicator_mesh.material_override = mat
	
	add_child(indicator_mesh)

func _create_fire_visuals() -> void:
	# ==================== IGNITION CORE (HIGH DETAIL, SHORT-LIVED) ====================
	# Adds realism at the first point of ignition; later disabled by adaptive LOD.
	ignition_particles = GPUParticles3D.new()
	ignition_particles.name = "IgnitionCore"
	ignition_particles.amount = 18
	ignition_particles.lifetime = 0.9
	ignition_particles.preprocess = 0.2
	ignition_particles.emitting = true
	ignition_particles.fixed_fps = 32
	ignition_particles.visibility_aabb = AABB(Vector3(-6, -2, -6), Vector3(12, 20, 12))
	
	var ignition_mat := ParticleProcessMaterial.new()
	ignition_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ignition_mat.emission_sphere_radius = 0.18
	ignition_mat.direction = Vector3(0, 1, 0)
	ignition_mat.spread = 10.0
	ignition_mat.initial_velocity_min = 2.5
	ignition_mat.initial_velocity_max = 5.5
	ignition_mat.gravity = Vector3(0, 2.2, 0)
	ignition_mat.scale_min = 0.15
	ignition_mat.scale_max = 0.45
	ignition_mat.damping_min = 0.1
	ignition_mat.damping_max = 0.3
	
	var ignition_color := Gradient.new()
	ignition_color.set_color(0, Color(1.0, 0.98, 0.85, 1.0))
	ignition_color.add_point(0.2, Color(1.0, 0.85, 0.35, 0.95))
	ignition_color.add_point(0.45, Color(1.0, 0.45, 0.12, 0.75))
	ignition_color.set_color(1, Color(0.25, 0.2, 0.18, 0.0))
	var ignition_color_tex := GradientTexture1D.new()
	ignition_color_tex.gradient = ignition_color
	ignition_mat.color_ramp = ignition_color_tex
	ignition_particles.process_material = ignition_mat
	
	var ignition_mesh := QuadMesh.new()
	ignition_mesh.size = Vector2(0.35, 0.9)
	var ignition_mesh_mat := StandardMaterial3D.new()
	ignition_mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ignition_mesh_mat.vertex_color_use_as_albedo = true
	ignition_mesh_mat.emission_enabled = true
	ignition_mesh_mat.emission = Color(1.0, 0.7, 0.25)
	ignition_mesh_mat.emission_energy_multiplier = 3.0
	ignition_mesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	ignition_mesh_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ignition_mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ignition_mesh.material = ignition_mesh_mat
	ignition_particles.draw_pass_1 = ignition_mesh
	add_child(ignition_particles)
	
	# ==================== COMBINED FLAME→SMOKE PARTICLE SYSTEM ====================
	# Single system: bright flames at bottom transition to dark smoke as they rise
	# This is more efficient AND looks better than separate systems
	
	flame_particles = GPUParticles3D.new()
	flame_particles.name = "FlameSmoke"
	flame_particles.amount = 55
	flame_particles.lifetime = 3.5  # Long enough to rise and become smoke
	flame_particles.emitting = true
	flame_particles.fixed_fps = 25
	flame_particles.visibility_aabb = AABB(Vector3(-20, -5, -20), Vector3(40, 100, 40))
	
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.4
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 18.0
	mat.initial_velocity_min = 2.5
	mat.initial_velocity_max = 6.0
	mat.gravity = Vector3(0, 3.0, 0)  # Strong upward pull
	mat.scale_min = 0.3
	mat.scale_max = 0.9
	mat.damping_min = 0.2
	mat.damping_max = 0.6
	
	# Scale increases as particles rise (flame → expanding smoke)
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.4))   # Small flame
	scale_curve.add_point(Vector2(0.25, 0.7))  # Growing flame
	scale_curve.add_point(Vector2(0.5, 1.2))   # Transition to smoke
	scale_curve.add_point(Vector2(1.0, 2.2))   # Large smoke puff
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	mat.scale_curve = scale_tex
	
	# CRITICAL: Color gradient - WHITE-YELLOW → YELLOW → ORANGE → RED → GRAY SMOKE
	var color_grad := Gradient.new()
	color_grad.set_color(0, Color(1.0, 1.0, 0.85, 1.0))      # White-yellow (hottest)
	color_grad.add_point(0.1, Color(1.0, 0.95, 0.5, 1.0))    # Bright yellow
	color_grad.add_point(0.22, Color(1.0, 0.75, 0.2, 0.95))  # Golden yellow
	color_grad.add_point(0.35, Color(1.0, 0.5, 0.1, 0.9))    # Orange
	color_grad.add_point(0.5, Color(0.95, 0.25, 0.05, 0.8))  # Red
	color_grad.add_point(0.65, Color(0.5, 0.15, 0.08, 0.65)) # Dark ember
	color_grad.add_point(0.8, Color(0.3, 0.27, 0.24, 0.5))   # Gray smoke
	color_grad.set_color(1, Color(0.25, 0.23, 0.2, 0.0))     # Fade out
	var color_tex := GradientTexture1D.new()
	color_tex.gradient = color_grad
	mat.color_ramp = color_tex
	
	flame_particles.process_material = mat
	
	# Sphere mesh
	var pmesh := QuadMesh.new()
	pmesh.size = Vector2(0.7, 1.6)
	# Material on the draw-pass mesh (avoid GPUParticles3D.material_override multipass issues on export/runtime).
	var pmesh_mat := StandardMaterial3D.new()
	pmesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmesh_mat.vertex_color_use_as_albedo = true  # Use particle colors from gradient!
	pmesh_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)  # White to show gradient
	pmesh_mat.emission_enabled = true
	pmesh_mat.emission = Color(1.0, 0.6, 0.2)
	pmesh_mat.emission_energy_multiplier = 2.5
	pmesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	pmesh_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pmesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmesh.material = pmesh_mat
	flame_particles.draw_pass_1 = pmesh
	
	add_child(flame_particles)
	
	# ==================== SOFT SMOKE PLUME (ONLY IN HIGH/MEDIUM QUALITY) ====================
	smoke_particles = GPUParticles3D.new()
	smoke_particles.name = "SmokePlume"
	smoke_particles.amount = 34
	smoke_particles.lifetime = 9.5
	smoke_particles.preprocess = 0.5
	smoke_particles.emitting = true
	smoke_particles.fixed_fps = 24
	smoke_particles.visibility_aabb = AABB(Vector3(-30, -5, -30), Vector3(60, 220, 60))
	
	var smoke_mat := ParticleProcessMaterial.new()
	smoke_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	smoke_mat.emission_sphere_radius = 0.5
	smoke_mat.direction = Vector3(0, 1, 0)
	smoke_mat.spread = 10.0
	smoke_mat.initial_velocity_min = 2.0
	smoke_mat.initial_velocity_max = 4.2
	smoke_mat.gravity = Vector3(0, 1.9, 0)
	smoke_mat.scale_min = 0.95
	smoke_mat.scale_max = 3.0
	smoke_mat.damping_min = 0.15
	smoke_mat.damping_max = 0.35
	
	var smoke_color := Gradient.new()
	smoke_color.set_color(0, Color(0.03, 0.03, 0.03, 0.72))
	smoke_color.add_point(0.25, Color(0.04, 0.04, 0.04, 0.92))
	smoke_color.add_point(0.55, Color(0.06, 0.06, 0.06, 0.82))
	smoke_color.add_point(0.82, Color(0.09, 0.09, 0.09, 0.46))
	smoke_color.set_color(1, Color(0.06, 0.06, 0.06, 0.0))
	var smoke_color_tex := GradientTexture1D.new()
	smoke_color_tex.gradient = smoke_color
	smoke_mat.color_ramp = smoke_color_tex
	smoke_particles.process_material = smoke_mat
	
	var smoke_mesh := QuadMesh.new()
	smoke_mesh.size = Vector2(1.6, 3.2)
	var smoke_mesh_mat := StandardMaterial3D.new()
	smoke_mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke_mesh_mat.vertex_color_use_as_albedo = true
	smoke_mesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	smoke_mesh_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	smoke_mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_mesh.material = smoke_mesh_mat
	smoke_particles.draw_pass_1 = smoke_mesh
	smoke_particles.position = Vector3(0, 1.2, 0)
	add_child(smoke_particles)
	
	# ==================== FIRE LIGHTS ====================
	# Initial fire should be VERY visible - bright lights!
	fire_light = OmniLight3D.new()
	fire_light.name = "FireLight"
	fire_light.light_color = Color(1.0, 0.6, 0.2)
	fire_light.light_energy = 12.0  # Much brighter for visibility
	fire_light.omni_range = 25.0    # Larger range
	fire_light.omni_attenuation = 1.0
	fire_light.position = Vector3(0, 1.0, 0)
	add_child(fire_light)
	
	fire_light_2 = OmniLight3D.new()
	fire_light_2.name = "FireLight2"
	fire_light_2.light_color = Color(1.0, 0.4, 0.1)
	fire_light_2.light_energy = 8.0
	fire_light_2.omni_range = 40.0  # Wide range to be seen from distance
	fire_light_2.omni_attenuation = 1.2
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
	
	# Periodically check if cluster manager should take over (staggered per-fire)
	_cluster_check_timer += delta
	if _cluster_check_timer >= _CLUSTER_CHECK_INTERVAL:
		_cluster_check_timer -= _CLUSTER_CHECK_INTERVAL
		_check_cluster_mode()
	
	# Check if being sprayed
	var being_sprayed := spray_bodies.size() > 0
	if being_sprayed :
		_had_extinguisher_help = true
	
	# Apply extinguisher damage (REAL-TIME - not sim time)
	if being_sprayed:
		intensity -= EXTINGUISHER_DAMAGE * delta * spray_bodies.size()
		# Fire doesn't grow while being actively sprayed!
	else:
		# Natural growth only when NOT being sprayed (SIMULATION time)
		# But only if fire is above a minimum threshold
		if intensity > EXTINGUISH_THRESHOLD:
			intensity += GROWTH_RATE * sim_hours
	
	intensity = clampf(intensity, 0.0, 200.0)
	
	# Track fire time (simulation)
	fire_time_hours += sim_hours
	
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
	
	# Destruction check
	if fire_time_hours >= DESTROY_TIME_HOURS:
		_destroy_target_mesh()
	
	# Spread check (sim time)
	spread_timer += sim_hours
	if spread_timer >= SPREAD_CHECK_INTERVAL and intensity >= 50:
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
	
	# Update indicator (always visible - provides fire location even when cluster-managed)
	if indicator_mesh != null:
		# Keep a visible glowing base in all modes so players can pinpoint source.
		var indicator_base_scale := 0.1 if not ( simplified_mode or _cluster_managed ) else 0.28
		var indicator_intensity_scale := 0.2 if not ( simplified_mode or _cluster_managed ) else 0.45
		var indicator_scale := indicator_base_scale + visual_factor * indicator_intensity_scale
		var pulse := sin(_flicker_time * 4.0) * 0.12 + 1.0
		indicator_mesh.scale = Vector3.ONE * indicator_scale * pulse
		indicator_mesh.visible = intensity > EXTINGUISH_THRESHOLD
		
		# Change indicator color based on intensity
		var mat := indicator_mesh.material_override as StandardMaterial3D
		if mat != null:
			if intensity <= 0:
				mat.albedo_color = Color(0.3, 0.3, 0.3, 0.5)
				mat.emission = Color(0, 0, 0)
				mat.emission_energy_multiplier = 0.0
			else:
				mat.albedo_color = Color(1.0, 0.4 * (1.0 - visual_factor * 0.3), 0.0, 1.0)
				mat.emission = Color(1.0, 0.5, 0.0)
				# Brighter emission when cluster-managed
				var emit_mult := 3.0 if not _cluster_managed else 5.0
				mat.emission_energy_multiplier = visual_factor * emit_mult
	
	# Skip individual particle/light updates if cluster-managed
	if _cluster_managed:
		if Engine.get_process_frames() % 60 == 0:
			pass
		return
	
	# After first 5 active fire nodes, drop to lightweight "glowing ball" mode.
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
		if fire_light != null:
			var simple_energy := lerpf(3.0, 7.0, visual_factor) * (sin(_flicker_time * 5.5) * 0.12 + 1.0)
			fire_light.light_energy = lerpf(fire_light.light_energy, simple_energy, 0.2)
			fire_light.omni_range = lerpf(12.0, 22.0, visual_factor)
		if fire_light_2 != null:
			fire_light_2.visible = false
			fire_light_2.light_energy = 0.0
		return
	
	# Ignition core: only for high-quality/new fires.
	if ignition_particles != null:
		var ignition_enabled := quality == VisualQuality.HIGH and age_seconds <= IGNITION_REALISM_SECONDS and intensity > EXTINGUISH_THRESHOLD
		ignition_particles.visible = ignition_enabled
		ignition_particles.emitting = ignition_enabled
		if ignition_enabled:
			ignition_particles.amount = int(lerpf(12.0, 22.0, visual_factor))
			ignition_particles.fixed_fps = 32
			var imat := ignition_particles.process_material as ParticleProcessMaterial
			if imat != null:
				imat.emission_sphere_radius = lerpf(0.12, 0.24, visual_factor)
				imat.initial_velocity_max = lerpf(4.2, 6.5, visual_factor)
	
	# Scale combined flame→smoke particles
	if flame_particles != null:
		if intensity <= 5:
			flame_particles.emitting = false
		else:
			flame_particles.emitting = true
			match quality:
				VisualQuality.HIGH:
					flame_particles.amount = int(lerpf(38.0, 64.0, visual_factor))
					flame_particles.fixed_fps = 26
				VisualQuality.MEDIUM:
					flame_particles.amount = int(lerpf(26.0, 42.0, visual_factor))
					flame_particles.fixed_fps = 18
				VisualQuality.LOW:
					flame_particles.amount = int(lerpf(14.0, 24.0, visual_factor))
					flame_particles.fixed_fps = 12
			
			var mat := flame_particles.process_material as ParticleProcessMaterial
			if mat != null:
				match quality:
					VisualQuality.HIGH:
						mat.emission_sphere_radius = lerpf(0.22, 0.65, visual_factor)
						mat.initial_velocity_max = lerpf(4.2, 7.3, visual_factor)
						mat.scale_max = lerpf(0.7, 1.25, visual_factor)
					VisualQuality.MEDIUM:
						mat.emission_sphere_radius = lerpf(0.2, 0.55, visual_factor)
						mat.initial_velocity_max = lerpf(3.5, 6.0, visual_factor)
						mat.scale_max = lerpf(0.6, 1.0, visual_factor)
					VisualQuality.LOW:
						mat.emission_sphere_radius = lerpf(0.16, 0.45, visual_factor)
						mat.initial_velocity_max = lerpf(2.8, 4.8, visual_factor)
						mat.scale_max = lerpf(0.5, 0.85, visual_factor)
	
	# Separate smoke plume for realism near ignition, reduced under load.
	if smoke_particles != null:
		var smoke_enabled := quality != VisualQuality.LOW and intensity > EXTINGUISH_THRESHOLD
		smoke_particles.visible = smoke_enabled
		smoke_particles.emitting = smoke_enabled
		if smoke_enabled:
			if quality == VisualQuality.HIGH:
				smoke_particles.amount = int(lerpf(70.0, 130.0, visual_factor))
				smoke_particles.fixed_fps = 24
			else:
				smoke_particles.amount = int(lerpf(42.0, 82.0, visual_factor))
				smoke_particles.fixed_fps = 18
			var smat := smoke_particles.process_material as ParticleProcessMaterial
			if smat != null:
				smat.emission_sphere_radius = lerpf(0.5, 1.25, visual_factor)
				smat.initial_velocity_min = lerpf(2.0, 2.8, visual_factor)
				smat.initial_velocity_max = lerpf(3.8, 5.8, visual_factor)
				smat.scale_max = lerpf(3.2, 6.5, visual_factor)
	
	# STRONG flickering lights - critical for spotting fires!
	var flicker1 := sin(_flicker_time * 6.0) * 0.25 + sin(_flicker_time * 10.0) * 0.18 + sin(_flicker_time * 15.0) * 0.1 + 1.0
	var flicker2 := sin(_flicker_time * 5.0 + 0.7) * 0.22 + sin(_flicker_time * 9.0) * 0.12 + 1.0
	
	if fire_light != null:
		if intensity <= 5:
			fire_light.light_energy = lerpf(fire_light.light_energy, 0.0, 0.2)
		else:
			# BRIGHT flickering light
			var base_energy : float
			match quality:
				VisualQuality.HIGH:
					base_energy = lerpf(9.0, 18.0, visual_factor)
				VisualQuality.MEDIUM:
					base_energy = lerpf(6.5, 13.5, visual_factor)
				VisualQuality.LOW:
					base_energy = lerpf(4.0, 9.0, visual_factor)
			var target_energy : float = base_energy * flicker1
			fire_light.light_energy = lerpf(fire_light.light_energy, target_energy, 0.2)
			fire_light.omni_range = lerpf(14.0, 30.0, visual_factor)
			# Color shift for realism
			var color_shift := (sin(_flicker_time * 7.0) + 1.0) * 0.08
			fire_light.light_color = Color(1.0, 0.5 + color_shift, 0.15 + color_shift * 0.5)
	
	if fire_light_2 != null:
		if intensity <= 5 or quality == VisualQuality.LOW:
			fire_light_2.light_energy = lerpf(fire_light_2.light_energy, 0.0, 0.2)
			fire_light_2.visible = quality != VisualQuality.LOW
		else:
			fire_light_2.visible = true
			var target_energy : float = lerpf(5.0, 12.0, visual_factor) * flicker2
			fire_light_2.light_energy = lerpf(fire_light_2.light_energy, target_energy, 0.2)
			fire_light_2.omni_range = lerpf(30.0, 50.0, visual_factor)

func _try_spread() -> void:
	if target_mesh == null:
		return
	
	var tree := get_tree()
	if tree == null:
		return
	
	# Get current fire count to throttle spread
	var fire_count := _get_cached_fire_count()
	
	# Drastically reduce spread chance when many fires exist
	# This prevents exponential growth from overwhelming the system
	var spread_throttle := 1.0
	if fire_count > 200:
		spread_throttle = 0.05  # 95% reduction
	elif fire_count > 100:
		spread_throttle = 0.15  # 85% reduction
	elif fire_count > 50:
		spread_throttle = 0.35  # 65% reduction
	elif fire_count > 20:
		spread_throttle = 0.6   # 40% reduction
	
	# Get spread range from main settings, or use default
	var base_spread := _get_fire_spread_range()
	var spread_range := base_spread + (intensity / 100.0)
	var fire_pos := global_position
	
	var potential_targets := _find_nearby_meshes(fire_pos, spread_range)
	
	for mesh in potential_targets:
		if mesh == target_mesh:
			continue
		if mesh in nearby_meshes_engulfed:
			continue
		if _mesh_has_fire(mesh):
			continue
		
		var spread_chance := (0.08 + (intensity / 250.0)) * spread_throttle
		if randf() < spread_chance:
			fire_spread.emit(mesh)
			break

func _find_nearby_meshes(pos: Vector3, range_dist: float) -> Array[MeshInstance3D]:
	var result : Array[MeshInstance3D] = []
	var candidates := _get_cached_flammable_meshes()
	var range_sq := range_dist * range_dist
	for mesh in candidates:
		if mesh == null or not is_instance_valid(mesh):
			continue
		var to_mesh := mesh.global_position - pos
		if to_mesh.length_squared() <= range_sq:
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

func _engulf_nearby_meshes() -> void:
	if target_mesh == null:
		return
	
	var tree := get_tree()
	if tree == null:
		return
	
	# Get engulf range from main settings, or use default
	var base_engulf := _get_fire_engulf_range()
	var engulf_range := base_engulf + (intensity / 100.0)
	var fire_pos := global_position
	
	var nearby := _find_nearby_meshes(fire_pos, engulf_range)
	
	for mesh in nearby:
		if mesh == target_mesh:
			continue
		if mesh in nearby_meshes_engulfed:
			continue
		
		nearby_meshes_engulfed.append(mesh)
		_darken_mesh(mesh)

func _darken_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null:
		return
	
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.08, 0.06, 1.0)
	mat.roughness = 1.0
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.08, 0.0)
	mat.emission_energy_multiplier = 0.4
	mesh.material_override = mat

func _destroy_target_mesh() -> void:
	# Get average ground position before destroying meshes
	var ground_y := _find_ground_level()
	
	for mesh in nearby_meshes_engulfed:
		if is_instance_valid(mesh):
			mesh_destroyed.emit(mesh)
			mesh.queue_free()
	nearby_meshes_engulfed.clear()
	
	if target_mesh != null and is_instance_valid(target_mesh):
		target_mesh.set_meta("fire_active", false)
		mesh_destroyed.emit(target_mesh)
		target_mesh.queue_free()
	
	# Convert to smoldering pile on ground
	_become_smoldering_pile(ground_y)

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

## Convert this fire to a simple smoldering pile on ground (saves computation)
func _become_smoldering_pile(ground_y: float) -> void:
	# Move to ground level
	global_position.y = ground_y + 0.1
	
	# Reduce intensity and stop spreading
	intensity = 15.0
	state = FireState.SMALL
	
	# Simplify visuals - reduce particle count significantly
	if ignition_particles != null:
		ignition_particles.emitting = false
		ignition_particles.visible = false
	
	if flame_particles != null:
		flame_particles.amount = 15  # Much fewer particles
		flame_particles.lifetime = 2.0  # Shorter lifetime
		
		var mat := flame_particles.process_material as ParticleProcessMaterial
		if mat != null:
			mat.emission_sphere_radius = 1.5  # Wider, flatter emission
			mat.initial_velocity_min = 0.5
			mat.initial_velocity_max = 2.0
			mat.gravity = Vector3(0, 1.0, 0)  # Slower rise
	
	if smoke_particles != null:
		smoke_particles.emitting = false
		smoke_particles.visible = false
	
	# Dim the lights
	if fire_light != null:
		fire_light.light_energy = 4.0
		fire_light.omni_range = 10.0
	if fire_light_2 != null:
		fire_light_2.light_energy = 2.0
		fire_light_2.omni_range = 15.0
	
	# Make indicator look like embers
	if indicator_mesh != null:
		indicator_mesh.scale = Vector3(1.5, 0.3, 1.5)  # Flat pile shape
		var mat := indicator_mesh.material_override as StandardMaterial3D
		if mat != null:
			mat.emission = Color(0.8, 0.2, 0.0)
			mat.emission_energy_multiplier = 3.0
	
	# This fire no longer spreads
	target_mesh = null

func _extinguish() -> void:
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
	
	if fire_light != null:
		fire_light.light_energy = 0.0
	
	if fire_light_2 != null:
		fire_light_2.light_energy = 0.0
	
	# Hide indicator immediately
	if indicator_mesh != null:
		indicator_mesh.visible = false
	
	# Emit signal BEFORE queue_free so event can process it
	fire_extinguished.emit()
	if _had_extinguisher_help :
		var tree := get_tree()
		if tree != null :
			tree.call_group_flags( SceneTree.GROUP_CALL_DEFERRED, "mars_college_credits_ui", "on_fire_extinguished_reward" )
	
	# Quick cleanup - delay to let signals process
	var tween := create_tween()
	tween.tween_callback(queue_free).set_delay(0.5)

## Make a mesh look charred/burned (black with slight texture)
func _char_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null or not is_instance_valid(mesh):
		return
	
	var char_mat := StandardMaterial3D.new()
	char_mat.albedo_color = Color(0.05, 0.04, 0.03, 1.0)  # Very dark charcoal
	char_mat.roughness = 1.0
	char_mat.metallic = 0.0
	# Slight dark emission for "still warm" look
	char_mat.emission_enabled = true
	char_mat.emission = Color(0.2, 0.08, 0.02)
	char_mat.emission_energy_multiplier = 0.3
	
	mesh.material_override = char_mat

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
		return 3.0  # Default
	
	var root := tree.root
	for child in root.get_children():
		if "fire_spread_range" in child:
			return float(child.fire_spread_range)
	
	return 3.0  # Default

func _get_fire_engulf_range() -> float:
	var tree := get_tree()
	if tree == null:
		return 2.0  # Default
	
	var root := tree.root
	for child in root.get_children():
		if "fire_engulf_range" in child:
			return float(child.fire_engulf_range)
	
	return 2.0  # Default

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
			if mesh.mesh != null and mesh.is_visible_in_tree() and not _is_terrain(mesh):
				# Filter tiny meshes to keep spread checks cheap
				var aabb_size: Vector3 = mesh.get_aabb().size
				if aabb_size.length() > 0.5:
					_cached_flammable_meshes.append(mesh)
		for child: Node in node.get_children():
			stack.append(child)

func apply_extinguisher_damage(damage: float) -> void:
	if damage > 0.0 :
		_had_extinguisher_help = true
	intensity -= damage
	intensity = maxf(intensity, 0.0)

func get_state_text() -> String:
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
