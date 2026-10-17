extends Node

## Dedicated orbit camera for Snowglobe SoI visualization.

const MODAL_NAME := "soi_snowglobe"
const CLAIM_OWNER := "soi_snowglobe"
const RIM_SUN_OWNER := "snowglobe"
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

## Fraction of the limiting field of view the globe should fill on entry —
## the same "sphere snug in the frame" composition as the graph's 2D SoI disc.
const FIT_FRACTION := 0.86

var _svc: Node = null
var _loader: Node = null
var _camera: Camera3D = null
var _orbit_yaw := 0.6
var _orbit_pitch := 0.35
var _orbit_mult := ORBIT_DIST_MULT
var _orbit_mult_target := ORBIT_DIST_MULT
var _dragging := false
var _active := false


func enter(svc: Node, loader: Node, orbit: Dictionary = {}) -> void:
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
	# Entered from the graph's Globe lens: continue ITS view instead of
	# reframing from scratch (the jump between the two read as two globes).
	if not orbit.is_empty():
		_orbit_yaw = float(orbit.get("yaw", _orbit_yaw))
		_orbit_pitch = float(orbit.get("pitch", _orbit_pitch))
		_orbit_mult = clampf(float(orbit.get("mult", _orbit_mult)), MIN_ORBIT_MULT, MAX_ORBIT_MULT)
		_orbit_mult_target = _orbit_mult
	var tree := get_tree()
	if tree == null:
		return
	var main := tree.current_scene
	if main == null:
		return
	# The clock is NOT claimed: the globe is a live view of the world, so play,
	# speed and scrub all keep working while it is up (the rim sun is the clock
	# readout). It used to push time_scale 0 here, which made "watch the day
	# go by from the globe" impossible.
	_camera = Camera3D.new()
	_camera.name = "SoiSnowglobeCamera"
	_camera.fov = CAMERA_FOV
	_camera.near = 0.5
	_camera.far = 8000.0
	main.add_child(_camera)
	# Camera + side effects through the claim stack (core/camera_claims.gd):
	# the player mesh, the long globe-distance shadows and the prop cull reach
	# all revert by construction when the claim is popped, even if this node
	# is freed mid-session. It used to set `current` by hand and save/restore
	# each side effect privately, which cannot nest with the other claimants.
	var svc_r := float(_svc.call("radius_m")) if _svc != null else 200.0
	var reach := svc_r * (MAX_ORBIT_MULT + 2.0)
	if main.has_method("push_camera_claim"):
		main.call("push_camera_claim", CLAIM_OWNER, {
			"camera_id": _camera.get_instance_id(),
			"hide_player_mesh": true,
			"shadow_max_distance": reach,
			"prop_cull_scale_m": reach,
		})
	else:
		_camera.current = true
	if _svc != null and _svc.has_method("acquire_rim_sun"):
		_svc.call("acquire_rim_sun", RIM_SUN_OWNER)
	_update_camera_transform()
	_update_glass_fade()
	set_process(true)
	set_process_unhandled_input(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "exit"))


func exit() -> void:
	if not _active:
		return
	_active = false
	set_process(false)
	set_process_unhandled_input(false)
	if _svc != null and _svc.has_method("release_rim_sun"):
		_svc.call("release_rim_sun", RIM_SUN_OWNER)
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	# Pop BEFORE freeing the camera so the stack restores the player camera
	# while this one still exists (the stack falls through a freed id anyway).
	if main != null and main.has_method("pop_camera_claim"):
		main.call("pop_camera_claim", CLAIM_OWNER)
	if is_instance_valid(_camera):
		_camera.queue_free()
		_camera = null
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


## Framing shared with the graph's Globe lens (SoiOrbitMath).
func _fit_orbit_mult() -> float:
	var vs := Vector2.ZERO
	var vp := get_viewport()
	if vp != null:
		vs = vp.get_visible_rect().size
	return SoiOrbitMath.fit_orbit_mult(CAMERA_FOV, vs, FIT_FRACTION,
			MIN_ORBIT_MULT, MAX_ORBIT_MULT, ORBIT_DIST_MULT)


func _sun_facing_yaw() -> float:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return 0.6
	return SoiOrbitMath.sun_facing_yaw(tree.current_scene.get("sun") as DirectionalLight3D)


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
	_svc.call("set_snowglobe_glass_opacity", SoiOrbitMath.glass_opacity_for_pitch(_orbit_pitch))


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


## The current orbit, for the graph's Globe lens on exit.
func orbit_state() -> Dictionary:
	return {"yaw": _orbit_yaw, "pitch": _orbit_pitch, "mult": _orbit_mult}
