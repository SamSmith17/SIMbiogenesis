@tool
extends EditorPlugin

# ── Main-menu IDs ─────────────────────────────────────────────────────────────
const MENU_ENABLE        := 0
const MENU_DEBUG_OVERLAY := 1
const MENU_LOCK_HORIZON  := 2
const MENU_OBJECT_MODE   := 3
const MENU_DRONE_MODE    := 8
const MENU_RESET_ORBIT   := 4
const MENU_PRINT_REPORT  := 5
const MENU_LOG_STATE     := 6

# Translation-axis submenu IDs  (T.x = pan L/R,  T.y = zoom,  T.z = pan U/D)
const TX_ENABLE_PAN_X := 0;  const TX_INVERT_PAN_X := 1
const TX_ENABLE_ZOOM  := 2;  const TX_INVERT_ZOOM  := 3
const TX_ENABLE_PAN_Y := 4;  const TX_INVERT_PAN_Y := 5

# Rotation-axis submenu IDs  (R.x = pitch,  R.y = roll,  R.z = yaw)
const RX_ENABLE_PITCH := 0;  const RX_INVERT_PITCH := 1
const RX_ENABLE_YAW   := 2;  const RX_INVERT_YAW   := 3
const RX_ENABLE_ROLL  := 4;  const RX_INVERT_ROLL  := 5

# ── Runtime state ─────────────────────────────────────────────────────────────
var device: Object
var enabled    := true
var show_debug := true

const BASE_TRANS_GAIN       := 0.2
const DEFAULT_ZOOM_DEADZONE  := 0.02
const DEFAULT_AXIS_DEADZONE  := 0.05

var trans_scale     := 0.5
var rot_scale       := 0.005
var damping         := 0.0
var cam_speed_scale := 1.0
var zoom_deadzone   := DEFAULT_ZOOM_DEADZONE
var axis_deadzone   := DEFAULT_AXIS_DEADZONE
var lock_horizon    := true
var object_mode     := false
var drone_mode      := true

# Per-axis enable/invert — applied to raw HID data before the velocity filter,
# so enable=false zeroes an axis completely and invert=-1 flips its sign.
var enable_pan_x := true;   var invert_pan_x := false  # T.x left / right
var enable_zoom  := true;   var invert_zoom  := false  # T.y zoom in / out
var enable_pan_y := true;   var invert_pan_y := false  # T.z up / down
var enable_pitch := true;   var invert_pitch := false  # R.x pitch
var enable_roll  := true;   var invert_roll  := false  # R.y roll
var enable_yaw   := true;   var invert_yaw   := false  # R.z yaw

var _vel_t := Vector3.ZERO
var _vel_r := Vector3.ZERO

var _orbit_target     := Vector3.ZERO
var _orbit_distance   := 10.0
var _orbit_needs_init := true

# ── UI nodes ──────────────────────────────────────────────────────────────────
var _menu     := PopupMenu.new()
var _tx_menu  := PopupMenu.new()   # Translation-axes submenu
var _rx_menu  := PopupMenu.new()   # Rotation-axes submenu
var _debug_panel  : PanelContainer
var _debug_label  : RichTextLabel
var _update_timer : Timer
var _last_update_ms := 0
var _editor_settings: EditorSettings

# ── Editor Settings key constants ─────────────────────────────────────────────
const _GDEXT_PATH := "res://addons/spacemouse_native/spacemouse_native.gdextension"
const SP := "spacemouse/"

# Category: speed
const S_TRANS     := SP + "speed/translation_scale"
const S_ROT       := SP + "speed/rotation_scale"
const S_CAM_SPEED := SP + "speed/camera_speed_multiplier"
const S_DEADZONE  := SP + "speed/zoom_deadzone"
const S_AXIS_DZ   := SP + "speed/axis_deadzone"
# Category: behavior
const S_DAMPING   := SP + "behavior/damping"
const S_LOCK_H    := SP + "behavior/lock_horizon"
const S_ORBIT     := SP + "behavior/object_mode"
const S_DRONE     := SP + "behavior/drone_mode"
# Category: translation axes
const S_EN_PAN_X  := SP + "translation/enable_pan_left_right"
const S_INV_PAN_X := SP + "translation/invert_pan_left_right"
const S_EN_ZOOM   := SP + "translation/enable_zoom"
const S_INV_ZOOM  := SP + "translation/invert_zoom"
const S_EN_PAN_Y  := SP + "translation/enable_pan_up_down"
const S_INV_PAN_Y := SP + "translation/invert_pan_up_down"
# Category: rotation axes
const S_EN_PITCH  := SP + "rotation/enable_pitch"
const S_INV_PITCH := SP + "rotation/invert_pitch"
const S_EN_YAW    := SP + "rotation/enable_yaw"
const S_INV_YAW   := SP + "rotation/invert_yaw"
const S_EN_ROLL   := SP + "rotation/enable_roll"
const S_INV_ROLL  := SP + "rotation/invert_roll"
# Category: debug
const S_DEBUG     := SP + "debug/show_debug_overlay"


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _enter_tree() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_editor_settings = get_editor_interface().get_editor_settings()
	_register_editor_settings()
	_load_settings()
	if _editor_settings and not _editor_settings.settings_changed.is_connected(_load_settings):
		_editor_settings.settings_changed.connect(_load_settings)

	_load_native_extension()
	if not ClassDB.class_exists("SpaceMouseDevice"):
		push_warning("SpaceMouse: native library not found. Check that the .gdextension and DLL are present.")
		return

	device = SpaceMouseDevice.new()
	if device.open_first() == false:
		push_warning("SpaceMouse: device not detected. Connect it and re-toggle 'SpaceMouse: Enabled'.")
	device.enable_raw_logging(show_debug)

	_setup_menu()
	_setup_overlay()
	_start_updater()


func _exit_tree() -> void:
	if DisplayServer.get_name() == "headless":
		return
	set_process(false)
	if _menu:
		remove_tool_menu_item("SpaceMouse")
		_tx_menu = null
		_rx_menu = null
		_menu    = null
	if _editor_settings and _editor_settings.settings_changed.is_connected(_load_settings):
		_editor_settings.settings_changed.disconnect(_load_settings)
	if is_instance_valid(_debug_panel):
		remove_control_from_bottom_panel(_debug_panel)
		if is_instance_valid(_update_timer):
			_update_timer.queue_free()
		_debug_panel.queue_free()
		_debug_panel = null
		_debug_label  = null
		_update_timer = null
	if device:
		device.close()
		device = null


# ── Menu setup ────────────────────────────────────────────────────────────────

func _setup_menu() -> void:
	# --- Translation-axes submenu ---
	_tx_menu.name = "SpaceMouseTX"
	_tx_menu.id_pressed.connect(_on_tx_menu_id)
	_tx_menu.add_check_item("Enable  Pan Left / Right  (T.x)", TX_ENABLE_PAN_X)
	_tx_menu.add_check_item("Invert  Pan Left / Right",         TX_INVERT_PAN_X)
	_tx_menu.add_separator()
	_tx_menu.add_check_item("Enable  Zoom  (T.y)",             TX_ENABLE_ZOOM)
	_tx_menu.add_check_item("Invert  Zoom",                     TX_INVERT_ZOOM)
	_tx_menu.add_separator()
	_tx_menu.add_check_item("Enable  Pan Up / Down  (T.z)",    TX_ENABLE_PAN_Y)
	_tx_menu.add_check_item("Invert  Pan Up / Down",            TX_INVERT_PAN_Y)
	_sync_tx_menu()

	# --- Rotation-axes submenu ---
	_rx_menu.name = "SpaceMouseRX"
	_rx_menu.id_pressed.connect(_on_rx_menu_id)
	_rx_menu.add_check_item("Enable  Pitch  (R.x)",            RX_ENABLE_PITCH)
	_rx_menu.add_check_item("Invert  Pitch",                    RX_INVERT_PITCH)
	_rx_menu.add_separator()
	_rx_menu.add_check_item("Enable  Yaw  (R.z)",              RX_ENABLE_YAW)
	_rx_menu.add_check_item("Invert  Yaw",                      RX_INVERT_YAW)
	_rx_menu.add_separator()
	_rx_menu.add_check_item("Enable  Roll  (R.y)",             RX_ENABLE_ROLL)
	_rx_menu.add_check_item("Invert  Roll",                     RX_INVERT_ROLL)
	_sync_rx_menu()

	# --- Main menu ---
	_menu.name = "SpaceMouseMenu"
	_menu.id_pressed.connect(_on_menu_id)
	_menu.add_child(_tx_menu)
	_menu.add_child(_rx_menu)

	_menu.add_check_item("SpaceMouse: Enabled",      MENU_ENABLE)
	_menu.add_check_item("Show Debug Overlay",        MENU_DEBUG_OVERLAY)
	_menu.add_separator()
	_menu.add_check_item("Lock Horizon  (no roll)",   MENU_LOCK_HORIZON)
	_menu.add_check_item("Object Mode  (orbit)",      MENU_OBJECT_MODE)
	_menu.add_check_item("Drone Mode  (fly forward)", MENU_DRONE_MODE)
	_menu.add_separator()
	_menu.add_submenu_item("Translation Axes", "SpaceMouseTX")
	_menu.add_submenu_item("Rotation Axes",    "SpaceMouseRX")
	_menu.add_item("Reset Orbit Target",              MENU_RESET_ORBIT)
	_menu.add_separator()
	_menu.add_item("Print last report (hex)",         MENU_PRINT_REPORT)
	_menu.add_item("Log current state",               MENU_LOG_STATE)

	_menu.set_item_checked(_menu.get_item_index(MENU_ENABLE),       enabled)
	_menu.set_item_checked(_menu.get_item_index(MENU_DEBUG_OVERLAY), show_debug)
	_menu.set_item_checked(_menu.get_item_index(MENU_LOCK_HORIZON),  lock_horizon)
	_menu.set_item_checked(_menu.get_item_index(MENU_OBJECT_MODE),   object_mode)
	_menu.set_item_checked(_menu.get_item_index(MENU_DRONE_MODE),    drone_mode)

	add_tool_submenu_item("SpaceMouse", _menu)


func _setup_overlay() -> void:
	if _debug_panel:
		return
	_debug_panel = PanelContainer.new()
	_debug_panel.name = "SpaceMouseDebugPanel"
	_debug_panel.custom_minimum_size = Vector2(360, 200)
	var vb := VBoxContainer.new()
	vb.anchor_right = 1.0
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	var title := Label.new()
	title.text = "SpaceMouse Debug"
	title.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))

	_debug_label = RichTextLabel.new()
	_debug_label.scroll_active         = true
	_debug_label.selection_enabled     = true
	_debug_label.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_debug_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	vb.add_child(title)
	vb.add_child(_debug_label)
	_debug_panel.add_child(vb)

	add_control_to_bottom_panel(_debug_panel, "SpaceMouse")
	_debug_panel.visible = show_debug


func _start_updater() -> void:
	_last_update_ms = Time.get_ticks_msec()
	_update_timer = Timer.new()
	_update_timer.name         = "SpaceMouseUpdateTimer"
	_update_timer.one_shot     = false
	_update_timer.wait_time    = 0.03
	_update_timer.autostart    = true
	_update_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_update_timer.timeout.connect(_on_update_timer)
	_debug_panel.add_child(_update_timer)


# ── Update loop ───────────────────────────────────────────────────────────────

func _on_update_timer() -> void:
	var now   := Time.get_ticks_msec()
	var delta := float(now - _last_update_ms) / 1000.0
	_last_update_ms = now
	_update_state(delta)


func _update_state(delta: float) -> void:
	if device == null:
		return
	if not enabled:
		if _debug_label and show_debug:
			_debug_label.text = "SpaceMouse disabled"
		return

	var state: Dictionary = device.get_state()
	if not state.get("connected", false):
		if _debug_label and show_debug:
			_debug_label.text = "SpaceMouse not connected"
		return

	var t: Vector3 = state.get("t", Vector3.ZERO)
	var r: Vector3 = state.get("r", Vector3.ZERO)

	# Per-axis deadzone: silence any axis whose raw value doesn't clear the
	# threshold. This suppresses mechanical crosstalk (e.g. a forward push that
	# also generates a tiny pitch value). Applied before enable/invert so those
	# toggles see clean zeroes rather than noise.
	var adz: float = axis_deadzone if typeof(axis_deadzone) == TYPE_FLOAT else DEFAULT_AXIS_DEADZONE
	if abs(t.x) < adz: t.x = 0.0
	if abs(t.y) < adz: t.y = 0.0
	if abs(t.z) < adz: t.z = 0.0
	if abs(r.x) < adz: r.x = 0.0
	if abs(r.y) < adz: r.y = 0.0
	if abs(r.z) < adz: r.z = 0.0

	# Apply per-axis enable (zero) and invert (negate) before the velocity
	# smoothing filter. This is the single authoritative place for axis mapping.
	if not enable_pan_x: t.x = 0.0
	elif invert_pan_x:   t.x = -t.x
	if not enable_zoom:  t.y = 0.0
	elif invert_zoom:    t.y = -t.y
	if not enable_pan_y: t.z = 0.0
	elif invert_pan_y:   t.z = -t.z
	if not enable_pitch: r.x = 0.0
	elif invert_pitch:   r.x = -r.x
	if not enable_roll:  r.y = 0.0
	elif invert_roll:    r.y = -r.y
	if not enable_yaw:   r.z = 0.0
	elif invert_yaw:     r.z = -r.z

	_vel_t = _vel_t * damping + t * (trans_scale * BASE_TRANS_GAIN) * (1.0 - damping)
	_vel_r = _vel_r * damping + r * rot_scale * (1.0 - damping)

	var cam := _get_editor_camera()
	if is_instance_valid(cam):
		_apply_to_camera(cam, delta)

	if _debug_label and show_debug:
		_update_debug_label(state, cam, t, r)
	if _debug_panel:
		_debug_panel.visible = show_debug


# ── Camera control ────────────────────────────────────────────────────────────

func _apply_to_camera(cam: Camera3D, delta: float) -> void:
	var ortho := cam.projection == Camera3D.PROJECTION_ORTHOGONAL
	var dt    := delta * cam_speed_scale
	var dz    := zoom_deadzone if typeof(zoom_deadzone) == TYPE_FLOAT else DEFAULT_ZOOM_DEADZONE

	# Deadzone applied only to zoom; pan/rotation axes respond to all deliberate input.
	var zoom := _vel_t.y
	if abs(zoom) < dz:
		zoom = 0.0

	if ortho:
		_apply_ortho(cam, dt, zoom)
		return

	if object_mode:
		if _orbit_needs_init:
			_init_orbit_target(cam)
		_apply_object_mode(cam, zoom, dt)
	elif drone_mode:
		_apply_drone(cam, dt)
	else:
		_apply_free_fly(cam, zoom, dt)


func _apply_ortho(cam: Camera3D, dt: float, zoom: float) -> void:
	# T.x/T.z: pan in screen plane. Positive zoom = size increase = zoom out.
	var move := Vector3(_vel_t.x, -_vel_t.z, 0.0) * dt
	if move.length() > 0.00001:
		cam.translate_object_local(move)
	var zoom_delta := -zoom * dt
	if abs(zoom_delta) > 0.00001:
		var factor := clamp(1.0 - zoom_delta, 0.1, 10.0)
		cam.size = max(0.01, cam.size * factor)


func _apply_free_fly(cam: Camera3D, zoom: float, dt: float) -> void:
	# Positive zoom → local +Z → camera retreats → scene shrinks (zoom out).
	var move := Vector3(_vel_t.x, -_vel_t.z, zoom) * dt
	if move.length() > 0.00001:
		cam.translate_object_local(move)

	if _vel_r.length() < 0.00001:
		return
	var yaw   := -_vel_r.z * dt
	var pitch :=  _vel_r.x * dt
	if lock_horizon:
		cam.rotate(Vector3.UP, yaw)
		cam.rotate_object_local(Vector3.RIGHT, pitch)
	else:
		var roll := -_vel_r.y * 0.25 * dt
		cam.rotate_object_local(Vector3.UP,      yaw)
		cam.rotate_object_local(Vector3.RIGHT,   pitch)
		cam.rotate_object_local(Vector3.FORWARD, roll)


func _apply_drone(cam: Camera3D, dt: float) -> void:
	# Drone mode: T.y = horizontal forward/back, T.x = strafe, T.z = world height.
	# This matches the physical SpaceMouse axis convention on this device
	# (same as the original free-fly zoom axis = T.y, vertical = T.z).
	# Forward uses only the horizontal component of the camera direction so the
	# camera never pitches into the ground when looking slightly down.
	var cam_fwd   := -cam.global_transform.basis.z
	var horiz_fwd := Vector3(cam_fwd.x, 0.0, cam_fwd.z)
	if horiz_fwd.length_squared() > 0.0001:
		horiz_fwd = horiz_fwd.normalized()
	else:
		horiz_fwd = Vector3.ZERO  # looking straight up or down

	var cam_right   := cam.global_transform.basis.x
	var horiz_right := Vector3(cam_right.x, 0.0, cam_right.z)
	if horiz_right.length_squared() > 0.0001:
		horiz_right = horiz_right.normalized()

	# Negate T.y so tilting cap forward moves the camera forward.
	var move := horiz_fwd * (-_vel_t.y) + horiz_right * _vel_t.x + Vector3.UP * _vel_t.z
	move *= dt
	if move.length() > 0.00001:
		cam.global_position += move

	if _vel_r.length() < 0.00001:
		return
	var yaw   := -_vel_r.z * dt
	var pitch :=  _vel_r.x * dt
	if lock_horizon:
		cam.rotate(Vector3.UP, yaw)
		cam.rotate_object_local(Vector3.RIGHT, pitch)
	else:
		var roll := -_vel_r.y * 0.25 * dt
		cam.rotate_object_local(Vector3.UP,      yaw)
		cam.rotate_object_local(Vector3.RIGHT,   pitch)
		cam.rotate_object_local(Vector3.FORWARD, roll)


func _init_orbit_target(cam: Camera3D) -> void:
	_orbit_target     = cam.global_position + (-cam.global_transform.basis.z) * _orbit_distance
	_orbit_needs_init = false


func _apply_object_mode(cam: Camera3D, zoom: float, dt: float) -> void:
	# Pan: slide camera and orbit target together in the camera's screen plane.
	if abs(_vel_t.x) > 0.00001 or abs(_vel_t.z) > 0.00001:
		var right := cam.global_transform.basis.x
		var up    := cam.global_transform.basis.y
		var pan   := (right * _vel_t.x - up * _vel_t.z) * dt
		cam.global_position += pan
		_orbit_target       += pan

	# Zoom: move camera along the orbit axis; speed proportional to distance.
	if abs(zoom) > 0.00001:
		var to_target := _orbit_target - cam.global_position
		var dist      := to_target.length()
		if dist > 0.001:
			var step     : float = zoom * dt * max(dist * 0.5, 0.1)
			var new_dist : float = max(0.1, dist + step)
			cam.global_position = _orbit_target - to_target.normalized() * new_dist
			_orbit_distance = new_dist

	# Orbit: rotate camera around the target point.
	if _vel_r.length() < 0.00001:
		return
	var to_cam    := cam.global_position - _orbit_target
	var dist      := to_cam.length()
	if dist < 0.001:
		return
	var yaw       := -_vel_r.z * dt
	var pitch     :=  _vel_r.x * dt
	var cam_right :=  cam.global_transform.basis.x

	if lock_horizon:
		to_cam = to_cam.rotated(Vector3.UP, yaw)
		var pitched := to_cam.rotated(cam_right, pitch)
		if abs(asin(clamp(pitched.normalized().y, -1.0, 1.0))) < deg_to_rad(89.0):
			to_cam = pitched
		cam.global_position = _orbit_target + to_cam.normalized() * dist
		if to_cam.cross(Vector3.UP).length() > 0.001:
			cam.look_at(_orbit_target, Vector3.UP)
	else:
		var cam_up := cam.global_transform.basis.y
		to_cam = to_cam.rotated(cam_up, yaw)
		to_cam = to_cam.rotated(cam_right, pitch)
		cam.global_position = _orbit_target + to_cam.normalized() * dist
		cam.look_at(_orbit_target, cam_up)


func _get_editor_camera() -> Camera3D:
	for i in range(4):
		var vp := get_editor_interface().get_editor_viewport_3d(i)
		if not is_instance_valid(vp):
			continue
		var cam := vp.get_camera_3d()
		if is_instance_valid(cam):
			return cam
	return null


# ── Native extension ──────────────────────────────────────────────────────────

func _load_native_extension() -> void:
	if ResourceLoader.exists(_GDEXT_PATH):
		ResourceLoader.load(_GDEXT_PATH)


# ── Editor Settings ───────────────────────────────────────────────────────────

# NOTE: Godot 4 does not expose a GDScript API for setting tooltip/description
# text on custom EditorSettings entries — the description strings below are used
# only in the debug overlay "Settings Reference" section (visible in the
# SpaceMouse bottom panel), not as hover tooltips in the Editor Settings dialog.

const _SETTING_DOCS := {
	"speed/translation_scale":
		"Pan and zoom speed multiplier. Higher = faster movement across all translation axes.",
	"speed/rotation_scale":
		"Pitch, yaw, and roll speed multiplier. Higher = faster rotation.",
	"speed/camera_speed_multiplier":
		"Global multiplier applied on top of translation and rotation scales.",
	"speed/zoom_deadzone":
		"Minimum T.y value before zoom is applied. Increase to suppress drift in ortho views.",
	"behavior/damping":
		"Velocity decay after releasing the puck. 0 = instant stop. 0.8 = slow, smooth coast. Was 0.8 in the original plugin (felt sticky).",
	"behavior/lock_horizon":
		"Yaw rotates around world Y; roll is suppressed. Keeps the horizon level, like SketchUp.",
	"behavior/object_mode":
		"Camera orbits a focal point rather than free-flying. Use 'Reset Orbit Target' to recenter.",
	"translation/enable_pan_left_right":  "T.x axis active. Disable to lock horizontal pan.",
	"translation/invert_pan_left_right":  "Flip T.x direction.",
	"translation/enable_zoom":            "T.y axis active. Disable to lock zoom.",
	"translation/invert_zoom":            "Flip T.y direction. On = pushing cap away zooms IN.",
	"translation/enable_pan_up_down":     "T.z axis active. Disable to lock vertical pan.",
	"translation/invert_pan_up_down":     "Flip T.z direction.",
	"rotation/enable_pitch":              "R.x axis active. Disable to lock pitch.",
	"rotation/invert_pitch":              "Flip R.x direction.",
	"rotation/enable_yaw":               "R.z axis active. Disable to lock yaw.",
	"rotation/invert_yaw":               "Flip R.z direction.",
	"rotation/enable_roll":              "R.y axis active. Only effective when Lock Horizon is OFF.",
	"rotation/invert_roll":              "Flip R.y direction.",
	"debug/show_debug_overlay":          "Show the SpaceMouse bottom panel with live axis values and settings.",
}


func _register_editor_settings() -> void:
	var es := _editor_settings
	if es == null:
		return

	# Float settings — hint_string format: "min,max,step" or "min,max,step,suffix:unit"
	var floats := [
		[S_TRANS,     trans_scale,     "0.1,50.0,0.1,suffix:×"],
		[S_ROT,       rot_scale,       "0.001,1.0,0.001,suffix:×"],
		[S_CAM_SPEED, cam_speed_scale, "0.1,10.0,0.1,suffix:×"],
		[S_DEADZONE,  zoom_deadzone,   "0.0,0.5,0.005"],
		[S_AXIS_DZ,   axis_deadzone,   "0.0,0.5,0.005"],
		[S_DAMPING,   damping,         "0.0,0.99,0.01"],
	]
	for d in floats:
		if not es.has_setting(d[0]):
			es.set_setting(d[0], d[1])
			es.add_property_info({"name": d[0], "type": TYPE_FLOAT,
				"hint": PROPERTY_HINT_RANGE, "hint_string": d[2],
				"usage": PROPERTY_USAGE_DEFAULT})

	# Bool settings
	var bools := [
		[S_LOCK_H,    lock_horizon ],
		[S_ORBIT,     object_mode  ],
		[S_DRONE,     drone_mode   ],
		[S_EN_PAN_X,  enable_pan_x ], [S_INV_PAN_X, invert_pan_x],
		[S_EN_ZOOM,   enable_zoom  ], [S_INV_ZOOM,  invert_zoom ],
		[S_EN_PAN_Y,  enable_pan_y ], [S_INV_PAN_Y, invert_pan_y],
		[S_EN_PITCH,  enable_pitch ], [S_INV_PITCH, invert_pitch],
		[S_EN_YAW,    enable_yaw   ], [S_INV_YAW,   invert_yaw  ],
		[S_EN_ROLL,   enable_roll  ], [S_INV_ROLL,  invert_roll ],
		[S_DEBUG,     show_debug   ],
	]
	for d in bools:
		if not es.has_setting(d[0]):
			es.set_setting(d[0], d[1])
			es.add_property_info({"name": d[0], "type": TYPE_BOOL,
				"usage": PROPERTY_USAGE_DEFAULT})


func _load_settings() -> void:
	var es := _editor_settings
	if es == null:
		return
	if es.has_setting(S_TRANS):     trans_scale     = es.get_setting(S_TRANS)
	if es.has_setting(S_ROT):       rot_scale       = es.get_setting(S_ROT)
	if es.has_setting(S_CAM_SPEED): cam_speed_scale = es.get_setting(S_CAM_SPEED)
	if es.has_setting(S_DAMPING):   damping         = es.get_setting(S_DAMPING)
	if es.has_setting(S_LOCK_H):    lock_horizon    = es.get_setting(S_LOCK_H)
	if es.has_setting(S_ORBIT):     object_mode     = es.get_setting(S_ORBIT)
	if es.has_setting(S_DRONE):     drone_mode      = es.get_setting(S_DRONE)
	if es.has_setting(S_DEBUG):     show_debug      = es.get_setting(S_DEBUG)
	if es.has_setting(S_DEADZONE):
		var dz = es.get_setting(S_DEADZONE)
		zoom_deadzone = float(dz) if typeof(dz) in [TYPE_INT, TYPE_FLOAT] else DEFAULT_ZOOM_DEADZONE
	if typeof(zoom_deadzone) != TYPE_FLOAT:
		zoom_deadzone = DEFAULT_ZOOM_DEADZONE
	if es.has_setting(S_AXIS_DZ):
		var adz = es.get_setting(S_AXIS_DZ)
		axis_deadzone = float(adz) if typeof(adz) in [TYPE_INT, TYPE_FLOAT] else DEFAULT_AXIS_DEADZONE
	if typeof(axis_deadzone) != TYPE_FLOAT:
		axis_deadzone = DEFAULT_AXIS_DEADZONE

	if es.has_setting(S_EN_PAN_X): enable_pan_x = es.get_setting(S_EN_PAN_X)
	if es.has_setting(S_INV_PAN_X): invert_pan_x = es.get_setting(S_INV_PAN_X)
	if es.has_setting(S_EN_ZOOM):  enable_zoom  = es.get_setting(S_EN_ZOOM)
	if es.has_setting(S_INV_ZOOM): invert_zoom  = es.get_setting(S_INV_ZOOM)
	if es.has_setting(S_EN_PAN_Y): enable_pan_y = es.get_setting(S_EN_PAN_Y)
	if es.has_setting(S_INV_PAN_Y): invert_pan_y = es.get_setting(S_INV_PAN_Y)
	if es.has_setting(S_EN_PITCH): enable_pitch = es.get_setting(S_EN_PITCH)
	if es.has_setting(S_INV_PITCH): invert_pitch = es.get_setting(S_INV_PITCH)
	if es.has_setting(S_EN_YAW):   enable_yaw   = es.get_setting(S_EN_YAW)
	if es.has_setting(S_INV_YAW):  invert_yaw   = es.get_setting(S_INV_YAW)
	if es.has_setting(S_EN_ROLL):  enable_roll  = es.get_setting(S_EN_ROLL)
	if es.has_setting(S_INV_ROLL): invert_roll  = es.get_setting(S_INV_ROLL)

	# Sync menus (guard: _load_settings fires before _setup_menu on first boot)
	if _menu:
		for pair: Array in [
			[_menu, MENU_DEBUG_OVERLAY, show_debug],
			[_menu, MENU_LOCK_HORIZON,  lock_horizon],
			[_menu, MENU_OBJECT_MODE,   object_mode],
			[_menu, MENU_DRONE_MODE,    drone_mode],
		]:
			var idx := (pair[0] as PopupMenu).get_item_index(pair[1])
			if idx != -1:
				(pair[0] as PopupMenu).set_item_checked(idx, pair[2])
	if is_instance_valid(_tx_menu) and _tx_menu.get_item_count() > 0:
		_sync_tx_menu()
	if is_instance_valid(_rx_menu) and _rx_menu.get_item_count() > 0:
		_sync_rx_menu()
	if _debug_panel:
		_debug_panel.visible = show_debug


# ── Menu sync helpers ─────────────────────────────────────────────────────────

func _chk(menu: PopupMenu, id: int, val: bool) -> void:
	var idx := menu.get_item_index(id)
	if idx != -1:
		menu.set_item_checked(idx, val)


func _sync_tx_menu() -> void:
	_chk(_tx_menu, TX_ENABLE_PAN_X, enable_pan_x)
	_chk(_tx_menu, TX_INVERT_PAN_X, invert_pan_x)
	_chk(_tx_menu, TX_ENABLE_ZOOM,  enable_zoom)
	_chk(_tx_menu, TX_INVERT_ZOOM,  invert_zoom)
	_chk(_tx_menu, TX_ENABLE_PAN_Y, enable_pan_y)
	_chk(_tx_menu, TX_INVERT_PAN_Y, invert_pan_y)


func _sync_rx_menu() -> void:
	_chk(_rx_menu, RX_ENABLE_PITCH, enable_pitch)
	_chk(_rx_menu, RX_INVERT_PITCH, invert_pitch)
	_chk(_rx_menu, RX_ENABLE_YAW,   enable_yaw)
	_chk(_rx_menu, RX_INVERT_YAW,   invert_yaw)
	_chk(_rx_menu, RX_ENABLE_ROLL,  enable_roll)
	_chk(_rx_menu, RX_INVERT_ROLL,  invert_roll)


# ── Menu callbacks ────────────────────────────────────────────────────────────

func _on_menu_id(id: int) -> void:
	match id:
		MENU_ENABLE:
			enabled = not enabled
			_chk(_menu, MENU_ENABLE, enabled)
			if enabled and device:
				if not device.is_enabled(): device.set_enabled(true)
				if not device.get_state().get("connected", false): device.open_first()
			elif device:
				device.set_enabled(false)
		MENU_DEBUG_OVERLAY:
			show_debug = not show_debug
			_chk(_menu, MENU_DEBUG_OVERLAY, show_debug)
			if device: device.enable_raw_logging(show_debug)
		MENU_LOCK_HORIZON:
			lock_horizon = not lock_horizon
			_chk(_menu, MENU_LOCK_HORIZON, lock_horizon)
			if _editor_settings: _editor_settings.set_setting(S_LOCK_H, lock_horizon)
		MENU_OBJECT_MODE:
			object_mode = not object_mode
			if object_mode: drone_mode = false
			_orbit_needs_init = true
			_chk(_menu, MENU_OBJECT_MODE, object_mode)
			_chk(_menu, MENU_DRONE_MODE,  drone_mode)
			if _editor_settings:
				_editor_settings.set_setting(S_ORBIT,  object_mode)
				_editor_settings.set_setting(S_DRONE,  drone_mode)
		MENU_DRONE_MODE:
			drone_mode = not drone_mode
			if drone_mode: object_mode = false
			_chk(_menu, MENU_DRONE_MODE,  drone_mode)
			_chk(_menu, MENU_OBJECT_MODE, object_mode)
			if _editor_settings:
				_editor_settings.set_setting(S_DRONE, drone_mode)
				_editor_settings.set_setting(S_ORBIT, object_mode)
		MENU_RESET_ORBIT:
			_orbit_needs_init = true
		MENU_PRINT_REPORT:
			if device:
				var r: String = device.get_last_report_hex()
				if r.is_empty(): push_warning("SpaceMouse: no report captured yet.")
				else: print("SpaceMouse last report: ", r)
		MENU_LOG_STATE:
			if device:
				var st: Dictionary = device.get_state()
				print("SpaceMouse => T:", st.get("t"), " R:", st.get("r"),
					" Btn:", st.get("buttons"), " Connected:", st.get("connected"))


func _on_tx_menu_id(id: int) -> void:
	match id:
		TX_ENABLE_PAN_X: enable_pan_x = not enable_pan_x; _chk(_tx_menu, id, enable_pan_x); _save(S_EN_PAN_X, enable_pan_x)
		TX_INVERT_PAN_X: invert_pan_x = not invert_pan_x; _chk(_tx_menu, id, invert_pan_x); _save(S_INV_PAN_X, invert_pan_x)
		TX_ENABLE_ZOOM:  enable_zoom  = not enable_zoom;  _chk(_tx_menu, id, enable_zoom);  _save(S_EN_ZOOM,  enable_zoom)
		TX_INVERT_ZOOM:  invert_zoom  = not invert_zoom;  _chk(_tx_menu, id, invert_zoom);  _save(S_INV_ZOOM,  invert_zoom)
		TX_ENABLE_PAN_Y: enable_pan_y = not enable_pan_y; _chk(_tx_menu, id, enable_pan_y); _save(S_EN_PAN_Y, enable_pan_y)
		TX_INVERT_PAN_Y: invert_pan_y = not invert_pan_y; _chk(_tx_menu, id, invert_pan_y); _save(S_INV_PAN_Y, invert_pan_y)


func _on_rx_menu_id(id: int) -> void:
	match id:
		RX_ENABLE_PITCH: enable_pitch = not enable_pitch; _chk(_rx_menu, id, enable_pitch); _save(S_EN_PITCH, enable_pitch)
		RX_INVERT_PITCH: invert_pitch = not invert_pitch; _chk(_rx_menu, id, invert_pitch); _save(S_INV_PITCH, invert_pitch)
		RX_ENABLE_YAW:   enable_yaw   = not enable_yaw;   _chk(_rx_menu, id, enable_yaw);   _save(S_EN_YAW,   enable_yaw)
		RX_INVERT_YAW:   invert_yaw   = not invert_yaw;   _chk(_rx_menu, id, invert_yaw);   _save(S_INV_YAW,   invert_yaw)
		RX_ENABLE_ROLL:  enable_roll  = not enable_roll;  _chk(_rx_menu, id, enable_roll);  _save(S_EN_ROLL,  enable_roll)
		RX_INVERT_ROLL:  invert_roll  = not invert_roll;  _chk(_rx_menu, id, invert_roll);  _save(S_INV_ROLL,  invert_roll)


func _save(key: String, value: Variant) -> void:
	if _editor_settings:
		_editor_settings.set_setting(key, value)


# ── Debug overlay ─────────────────────────────────────────────────────────────

func _update_debug_label(state: Dictionary, cam: Camera3D, t: Vector3, r: Vector3) -> void:
	var cam_path := str(cam.get_path())       if is_instance_valid(cam) else "(none)"
	var cam_pos  := str(cam.global_position)  if is_instance_valid(cam) else "-"
	var mode_str: String
	if object_mode:
		mode_str = "Object  orbit@(%.1f,%.1f,%.1f)  d=%.2f" % [
			_orbit_target.x, _orbit_target.y, _orbit_target.z, _orbit_distance]
	elif drone_mode:
		mode_str = "Drone  (T.z=fwd  T.x=strafe  T.y=height)"
	else:
		mode_str = "Free-fly"

	var en_str  := "T[%s %s %s]  R[%s %s %s]" % [
		"X" if enable_pan_x else "-", "Y" if enable_zoom else "-", "Z" if enable_pan_y else "-",
		"P" if enable_pitch else "-", "R" if enable_roll  else "-", "W" if enable_yaw   else "-"]
	var inv_str := "T[%s %s %s]  R[%s %s %s]" % [
		"X" if invert_pan_x else "-", "Y" if invert_zoom else "-", "Z" if invert_pan_y else "-",
		"P" if invert_pitch else "-", "R" if invert_roll  else "-", "W" if invert_yaw   else "-"]

	_debug_label.text = (
		"SpaceMouse\n"
		+ "Raw T: %s   Raw R: %s\n"
		+ "Vel T: %s   Vel R: %s\n"
		+ "Buttons: %s\n"
		+ "Enabled: %s  Connected: %s  Thread: %s\n"
		+ "Camera: %s\n  @ %s\n"
		+ "Mode: %s%s\n"
		+ "Axes enabled:  %s\n"
		+ "Axes inverted: %s\n"
		+ "Speed: trans=%.2f  rot=%.3f  cam=%.1f  damp=%.2f\n"
		+ "Loop: %s  Tick: %s ms  Reads: %s  Errs: %s\n"
		+ "Report id: %s  HID: %s\n"
		+ "Last: %s"
	) % [
		t, r, _vel_t, _vel_r,
		state.get("buttons", PackedInt32Array()),
		enabled, state.get("connected", false), state.get("thread_alive", false),
		cam_path, cam_pos,
		mode_str, ("  LockH" if lock_horizon else ""),
		en_str, inv_str,
		trans_scale, rot_scale, cam_speed_scale, damping,
		state.get("loop_count", 0), state.get("last_tick_ms", 0),
		state.get("read_count", 0), state.get("error_count", 0),
		state.get("report_id", -1), state.get("path", ""),
		device.get_last_report_hex() if device else "",
	]
