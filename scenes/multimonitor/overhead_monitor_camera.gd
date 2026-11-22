extends Camera3D

## Interactive 3D overhead / site camera for secondary Multi-Monitor windows.
##
## Orbits around a ground target (seeded from the player's position), supports
## mouse-drag orbit (LMB/RMB), pan (MMB or Shift+drag), scroll-wheel zoom,
## touch drag/pinch, and WASD pan when its secondary window has focus.

var target := Vector3.ZERO
var distance := 75.0
var yaw := 0.35
var pitch := -0.82
var follow_player := false

var _main: Node = null
var _orbit_dragging := false
var _pan_dragging := false


func setup(main: Node, start_height_m: float = 65.0) -> void:
	_main = main
	distance = clampf(start_height_m * 1.25, 12.0, 1200.0)
	var player := main.get_node_or_null("Player") as Node3D if main != null else null
	if player != null:
		target = player.global_position
		yaw = player.rotation.y
		var src_cam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D
		if src_cam != null:
			near = src_cam.near
			far = src_cam.far
			cull_mask = src_cam.cull_mask
			attributes = src_cam.attributes
			environment = src_cam.environment
	fov = 52.0
	current = true
	_apply_pose()


func _process(delta: float) -> void:
	if follow_player and _main != null and is_instance_valid(_main):
		var p := _main.get_node_or_null("Player") as Node3D
		if p != null:
			target = target.lerp(p.global_position, clampf(delta * 4.0, 0.0, 1.0))
			_apply_pose()
	var win := get_window()
	if win == null or not win.has_focus():
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		return
	var mv := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		mv.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		mv.y += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		mv.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		mv.x += 1.0
	if mv != Vector2.ZERO:
		var spd := maxf(distance * 0.65, 8.0) * (2.5 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
		var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
		var rgt := Vector3(cos(yaw), 0.0, -sin(yaw))
		target += (rgt * mv.x + fwd * mv.y) * spd * delta
		_apply_pose()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			distance = clampf(distance * 0.88, 6.0, 2500.0)
			_apply_pose()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			distance = clampf(distance * 1.14, 6.0, 2500.0)
			_apply_pose()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_pan_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.shift_pressed:
				_pan_dragging = mb.pressed
				_orbit_dragging = false
			else:
				_orbit_dragging = mb.pressed
				_pan_dragging = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbit_dragging:
			yaw -= mm.relative.x * 0.005
			pitch = clampf(pitch - mm.relative.y * 0.005, -1.52, -0.08)
			_apply_pose()
			get_viewport().set_input_as_handled()
		elif _pan_dragging:
			var scale_m := distance * 0.0018
			var rgt := Vector3(cos(yaw), 0.0, -sin(yaw))
			var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
			target -= (rgt * mm.relative.x + fwd * mm.relative.y) * scale_m
			_apply_pose()
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		yaw -= sd.relative.x * 0.004
		pitch = clampf(pitch - sd.relative.y * 0.004, -1.52, -0.08)
		_apply_pose()
	elif event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		if mg.factor > 0.01:
			distance = clampf(distance / mg.factor, 6.0, 2500.0)
			_apply_pose()


func _apply_pose() -> void:
	var rot := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	var offset := rot * Vector3(0.0, 0.0, distance)
	global_transform = Transform3D(rot, target + offset)
