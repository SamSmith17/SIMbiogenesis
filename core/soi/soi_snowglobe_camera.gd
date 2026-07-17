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


func enter(svc: Node, loader: Node) -> void:
	if _active:
		return
	_svc = svc
	_loader = loader
	_active = true
	_orbit_mult = ORBIT_DIST_MULT
	_orbit_mult_target = ORBIT_DIST_MULT
	var tree := get_tree()
	if tree == null:
		return
	var main := tree.current_scene
	if main != null:
		_saved_time_scale = float(main.get("time_scale"))
		main.set("time_scale", 0.0)
		_player = main.get_node_or_null("Player") as Node3D
		if _player != null:
			_player_cam = _player.get_node_or_null("Camera3D") as Camera3D
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
