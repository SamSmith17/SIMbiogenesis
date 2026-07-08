extends Node

## Dedicated orbit camera for Snowglobe SoI visualization.

const MODAL_NAME := "soi_snowglobe"
const ORBIT_DIST_MULT := 2.2
# Low enough to fly through the glass shell and orbit close to the SOI
# center from inside the globe (see _update_camera_transform's absolute-
# distance floor for the numeric safety clamp near zero).
const MIN_ORBIT_MULT := 0.03
const MAX_ORBIT_MULT := 4.5
const ZOOM_STEP := 0.12
## Absolute minimum camera-to-center distance (m), regardless of radius, so
## look_at(center) never degenerates when orbit_mult is tiny on a small SOI.
const MIN_ORBIT_DIST_M := 2.0

var _svc: Node = null
var _loader: Node = null
var _camera: Camera3D = null
var _player: Node3D = null
var _player_cam: Camera3D = null
var _player_mesh: Node3D = null
var _orbit_yaw := 0.6
var _orbit_pitch := 0.35
var _orbit_mult := ORBIT_DIST_MULT
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
	main.add_child(_camera)
	_camera.current = true
	_update_camera_transform()
	set_process(true)
	set_process_input(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "exit"))


func exit() -> void:
	if not _active:
		return
	_active = false
	set_process(false)
	set_process_input(false)
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


func _process(_delta: float) -> void:
	if not _active:
		return
	_update_camera_transform()


func _input(event: InputEvent) -> void:
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
		elif mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_orbit_mult = maxf(MIN_ORBIT_MULT, _orbit_mult - ZOOM_STEP)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_orbit_mult = minf(MAX_ORBIT_MULT, _orbit_mult + ZOOM_STEP)
	if event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_orbit_yaw -= mm.relative.x * 0.005
		_orbit_pitch = clampf(_orbit_pitch - mm.relative.y * 0.004, 0.05, 1.45)


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
