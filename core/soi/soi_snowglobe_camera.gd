extends Node

## Dedicated orbit camera for Snowglobe SoI visualization.

const MODAL_NAME := "soi_snowglobe"
const ORBIT_DIST_MULT := 2.2
# Low enough to fly through the glass shell and orbit close to the SOI
# center from inside the globe (see _update_camera_transform's absolute-
# distance floor for the numeric safety clamp near zero).
const MIN_ORBIT_MULT := 0.012
const MAX_ORBIT_MULT := 4.5
## Continuous zoom uses an exponential feel; wheel nudges the target.
const ZOOM_STEP := 0.06
const ZOOM_SMOOTH := 10.0
## Narrower than Godot's ~75° default so the dome doesn't fish-eye.
const CAMERA_FOV := 68.0
## Absolute minimum camera-to-center distance (m), regardless of radius, so
## look_at(center) never degenerates when orbit_mult is tiny on a small SOI.
const MIN_ORBIT_DIST_M := 1.0
## Below this pitch (rad), fade glass so sky isn't Fresnel-bullseyed.
const GLASS_PITCH_FADE_START := 0.55
const GLASS_PITCH_FADE_END := 0.22

## Fraction of the limiting field of view the globe should fill on entry —
## the same "sphere snug in the frame" composition as the graph's 2D SoI disc.
const FIT_FRACTION := 0.86
## Rim sun: distance and size relative to the globe radius (the water-cycle
## emblem pins the sun just off the sphere's edge).
const SUN_DIST_MULT := 1.14
const SUN_SIZE_MULT := 0.18

var _svc: Node = null
var _loader: Node = null
var _camera: Camera3D = null
var _player: Node3D = null
var _player_cam: Camera3D = null
var _player_mesh: Node3D = null
var _orbit_yaw := 0.6
var _orbit_pitch := 0.35
var _orbit_mult := ORBIT_DIST_MULT
var _orbit_mult_target := ORBIT_DIST_MULT
var _dragging := false
var _saved_time_scale := 1.0
var _active := false
var _sun_gizmo: MeshInstance3D = null
var _world_sun: DirectionalLight3D = null
var _saved_shadow_dist := -1.0


func enter(svc: Node, loader: Node) -> void:
	if _active:
		return
	_svc = svc
	_loader = loader
	_active = true
	# Open framed like the graph's 2D SoI disc: the sphere snug in the frame,
	# viewed near side-on so the earth cross-section reads (terrarium emblem).
	_orbit_mult = _fit_orbit_mult()
	_orbit_mult_target = _orbit_mult
	_orbit_pitch = 0.26
	_orbit_yaw = _sun_facing_yaw()
	var tree := get_tree()
	if tree == null:
		return
	var main := tree.current_scene
	if main != null:
		_saved_time_scale = float(main.get("time_scale"))
		main.set("time_scale", 0.0)
		# Long shadows while the globe is up: the default directional shadow
		# range is tuned for first-person distances, so buildings/props at
		# globe-viewing distance lost their shadows entirely and the scene
		# read as pasted-on. Restored on exit.
		_world_sun = main.get("sun") as DirectionalLight3D
		if _world_sun != null:
			_saved_shadow_dist = _world_sun.directional_shadow_max_distance
			var svc_r := float(_svc.call("radius_m")) if _svc != null else 200.0
			_world_sun.directional_shadow_max_distance = maxf(
				_saved_shadow_dist, svc_r * (MAX_ORBIT_MULT + 2.0))
		_player = main.get_node_or_null("Player") as Node3D
		if _player != null:
			# Real scene paths (the old bare "Camera3D"/"MeshInstance3D" lookups
			# always missed, so the player body floated inside the globe and
			# camera restore leaned on Godot's implicit fallback).
			_player_cam = _player.get_node_or_null("CameraArm/Camera3D") as Camera3D
			if _player_cam == null:
				_player_cam = _player.get_node_or_null("Camera3D") as Camera3D
			_player_mesh = _player.get_node_or_null("CharacterModel") as Node3D
			if _player_mesh == null:
				_player_mesh = _player.get_node_or_null("MeshInstance3D") as Node3D
			if _player_mesh == null:
				for c in _player.get_children():
					if c is MeshInstance3D:
						_player_mesh = c
						break
			if _player_mesh != null:
				_player_mesh.visible = false
	_camera = Camera3D.new()
	_camera.name = "SoiSnowglobeCamera"
	_camera.fov = CAMERA_FOV
	_camera.near = 0.5
	_camera.far = 8000.0
	main.add_child(_camera)
	_camera.current = true
	_ensure_sun_gizmo(main)
	_update_camera_transform()
	_update_glass_fade()
	_update_sun_gizmo()
	set_process(true)
	set_process_unhandled_input(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "exit"))


func exit() -> void:
	if not _active:
		return
	_active = false
	set_process(false)
	set_process_unhandled_input(false)
	if is_instance_valid(_sun_gizmo):
		_sun_gizmo.queue_free()
		_sun_gizmo = null
	if is_instance_valid(_world_sun) and _saved_shadow_dist > 0.0:
		_world_sun.directional_shadow_max_distance = _saved_shadow_dist
	_world_sun = null
	_saved_shadow_dist = -1.0
	if is_instance_valid(_camera):
		_camera.queue_free()
		_camera = null
	if is_instance_valid(_player_cam):
		_player_cam.current = true
	if is_instance_valid(_player_mesh):
		_player_mesh.visible = true
	var tree := get_tree()
	if tree != null:
		var main := tree.current_scene
		if main != null:
			main.set("time_scale", _saved_time_scale)
	CursorController.release_modal(MODAL_NAME)
	if _svc != null and _svc.has_method("_finalize_snowglobe_exit"):
		_svc._finalize_snowglobe_exit()


func _process(delta: float) -> void:
	if not _active:
		return
	var t := clampf(delta * ZOOM_SMOOTH, 0.0, 1.0)
	_orbit_mult = lerpf(_orbit_mult, _orbit_mult_target, t)
	_update_camera_transform()
	_update_glass_fade()
	_update_sun_gizmo()


## Orbit multiple that fits the sphere snugly in the LIMITING field of view
## (vertical in landscape; horizontal in a tall window). sin, not tan: the
## silhouette of a sphere of radius r seen from distance d subtends
## asin(r/d), so d = r / sin(half_angle).
func _fit_orbit_mult() -> float:
	var half_v := deg_to_rad(CAMERA_FOV * 0.5)
	var half_limit := half_v
	var vp := get_viewport()
	if vp != null:
		var vs := vp.get_visible_rect().size
		if vs.y > 0.0 and vs.x > 0.0 and vs.x < vs.y:
			# Portrait-ish: horizontal fov is the limit.
			half_limit = atan(tan(half_v) * vs.x / vs.y)
	var target := half_limit * FIT_FRACTION
	if target <= 0.0:
		return ORBIT_DIST_MULT
	return clampf(1.0 / sin(target), MIN_ORBIT_MULT, MAX_ORBIT_MULT)


## Entry yaw that puts the rim sun in frame, offset to the upper side like the
## emblem rather than dead behind the globe. Falls back to the old default
## when there is no scene sun yet (enter() runs before _world_sun resolves, so
## this reads the light straight from the tree).
func _sun_facing_yaw() -> float:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return 0.6
	var sun := tree.current_scene.get("sun") as DirectionalLight3D
	if sun == null:
		return 0.6
	var dir := sun.global_transform.basis.z.normalized()
	if dir.y < -0.05:
		return 0.6  # night — nothing to compose around
	# Camera sits at yaw θ on the orbit circle and looks back at the center;
	# placing the camera ~35° around from the sun's azimuth puts the disc in
	# the upper-left/right third of the frame instead of behind the sphere.
	return atan2(dir.z, dir.x) + 0.6


# ---- Rim sun (the water-cycle emblem pins the sun just off the sphere) -----

func _ensure_sun_gizmo(main: Node) -> void:
	if is_instance_valid(_sun_gizmo):
		return
	_sun_gizmo = MeshInstance3D.new()
	_sun_gizmo.name = "SnowglobeRimSun"
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE  # scaled per-frame from the globe radius
	_sun_gizmo.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# Billboard mode DISCARDS node scale unless told otherwise — without this
	# the r×0.18 disc rendered at its raw 1 m mesh size: a four-pixel dot.
	mat.billboard_keep_scale = true
	# Alpha blend, NOT additive — an additive disc disappears against a bright
	# sky, which is exactly where a daytime sun sits.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.85, 0.30, 1.0)
	mat.albedo_texture = _make_sun_disc_texture()
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.72, 0.22)
	mat.emission_energy_multiplier = 1.4
	# Emblem icon, not scenery: always draw over globe/terrain so the rim sun
	# reads from any orbit angle (the diagram never occludes its sun).
	mat.no_depth_test = true
	mat.render_priority = 10
	mat.disable_fog = true
	_sun_gizmo.material_override = mat
	_sun_gizmo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	main.add_child(_sun_gizmo)


## Soft radial disc, generated (no asset; matches the project's synthesized-
## resources convention): hot core, feathered corona.
static func _make_sun_disc_texture(px: int = 128) -> ImageTexture:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	var c := float(px - 1) * 0.5
	for y in px:
		for x in px:
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var core := clampf(1.0 - smoothstep(0.30, 0.55, d), 0.0, 1.0)
			var corona := clampf(1.0 - smoothstep(0.35, 1.0, d), 0.0, 1.0)
			var a := clampf(core + corona * 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, lerpf(0.75, 0.95, core), lerpf(0.25, 0.75, core), a))
	return ImageTexture.create_from_image(img)


## Pin the sun disc to the outside of the sphere along the REAL sun direction,
## so the emblem's rim sun doubles as a live clock readout. Hidden below the
## horizon (a rim sun under the ground would read as a bug, not a moon).
func _update_sun_gizmo() -> void:
	if not is_instance_valid(_sun_gizmo) or _svc == null:
		return
	var dir := Vector3(0.7, 0.6, 0.0).normalized()
	if is_instance_valid(_world_sun):
		# Godot lights shine along −Z, so the sun ITSELF sits along +basis.z.
		dir = _world_sun.global_transform.basis.z.normalized()
	if dir.y < -0.05:
		_sun_gizmo.visible = false
		return
	_sun_gizmo.visible = true
	var center: Vector3 = _svc.world_center()
	var r: float = _svc.radius_m()
	_sun_gizmo.global_position = center + dir * (r * SUN_DIST_MULT)
	var s := r * SUN_SIZE_MULT
	_sun_gizmo.scale = Vector3(s, s, s)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event.is_action_pressed("ui_cancel"):
		exit()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var tree := get_tree()
			if tree != null:
				var main := tree.current_scene
				var TerrainSurfaceQuery = load("res://core/placed_models/terrain_surface_query.gd")
				var hit := TerrainSurfaceQuery.raycast_ground_at_camera(main, _camera, mb.position) as Dictionary
				if hit and hit.has("position"):
					var p: Vector3 = hit["position"]
					if _svc != null and _svc.has_method("set_center_xz"):
						_svc.set_center_xz(p.x, p.z)
			get_viewport().set_input_as_handled()
		elif mb.pressed:
			# Exponential zoom: closer steps are smaller in distance space.
			var factor := 1.0 - ZOOM_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP \
					else 1.0 + ZOOM_STEP
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP \
					or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_orbit_mult_target = clampf(
						_orbit_mult_target * factor, MIN_ORBIT_MULT, MAX_ORBIT_MULT)
				get_viewport().set_input_as_handled()
	if event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_orbit_yaw -= mm.relative.x * 0.005
		_orbit_pitch = clampf(_orbit_pitch - mm.relative.y * 0.004, 0.05, 1.45)
		get_viewport().set_input_as_handled()


func _update_glass_fade() -> void:
	if _svc == null or not _svc.has_method("set_snowglobe_glass_opacity"):
		return
	# Horizon-ish pitch → kill Fresnel sky bullseye; high pitch → full glass.
	var t := inverse_lerp(GLASS_PITCH_FADE_END, GLASS_PITCH_FADE_START, _orbit_pitch)
	_svc.call("set_snowglobe_glass_opacity", clampf(t, 0.0, 1.0))


func _update_camera_transform() -> void:
	if _camera == null or _svc == null:
		return
	var center: Vector3 = _svc.world_center()
	var r: float = _svc.radius_m()
	var dist := maxf(r * _orbit_mult, MIN_ORBIT_DIST_M)
	var offset := Vector3(
		cos(_orbit_yaw) * cos(_orbit_pitch),
		sin(_orbit_pitch),
		sin(_orbit_yaw) * cos(_orbit_pitch)
	) * dist
	_camera.global_position = center + offset
	_camera.look_at(center, Vector3.UP)
	# Near clip tracks zoom so deep close-in SOI views don't clip the disc.
	_camera.near = clampf(dist * 0.02, 0.05, 0.5)
	_camera.far = maxf(8000.0, dist * 8.0 + r * 4.0)
