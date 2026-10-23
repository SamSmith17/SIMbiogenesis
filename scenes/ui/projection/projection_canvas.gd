extends Control

## The projection canvas (I): two projection SOURCES side by side, the sim
## camera (left) and a live camera feed or a recorded timelapse video locked to
## the sim clock (right), with corner-pin projection mapping (ProjectionWarp)
## over them for a projector. The timeline's VID lane and its video / live-feed
## buttons drive the right-hand source.
##
## Until 2026-10-23 it also carried a "sim vs live" dashboard in its bottom
## half (placeholder numbers when SolarUI was hidden, fabricated history
## curves, device rows nobody fed). That job is the Compare window now
## (scenes/ui/experiment/compare_view.gd, ⧉ on the timeline), which scores the
## sim against real Home Assistant history.

@export_group("Projection Canvas Visibility")
@export var start_hidden: bool = true

@export_group("Projection mapping")
## Corner-pin calibration (fractions of the screen; ProjectionWarp).
@export var warp_config_path: String = "user://projection_canvas_warp_v2.cfg"
## The pre-2026-10-23 file (absolute pixels, four quadrants) migrated on load.
@export var legacy_warp_config_path: String = "user://projection_canvas_warp.cfg"

@export_group("Simulated View Camera")
@export_node_path("Camera3D") var source_camera_path: NodePath
@export var use_source_world_3d: bool = true
@export var sync_camera_transform: bool = false
@export var sim_camera_move_speed: float = 8.0
@export var sim_camera_fast_multiplier: float = 2.5
@export var sim_camera_look_sensitivity: float = 0.12
@export var sim_camera_fov_step: float = 2.0
@export var sim_camera_min_fov: float = 25.0
@export var sim_camera_max_fov: float = 100.0

@export_group("Timelapse Sync")
## Enable automatic speed/pause sync between the loaded timelapse video and the simulation.
@export var video_sync_enabled: bool = true
## The time_scale value at which the video plays at 1× speed (450× = 0.125).
## One video frame every 15 real seconds recorded at 450× gives time_scale = 0.125.
@export var video_reference_time_scale: float = 0.125
## Simulation day_time (hours 0–24) that corresponds to video frame 0.
## Set this to align the video start with the correct time of day in the simulation.
@export var video_start_hour: float = 0.0
## Keep the video letterboxed instead of stretching when the panel changes shape.
@export var timelapse_display_aspect: float = 1.7777778
## Optional explicit path to the shared TimelineUI controller.
@export_node_path("Node") var timeline_ui_path: NodePath = NodePath("../TimelineUI")

@export_group("Webcam")
@export var webcam_feed_id: int = -1
@export var webcam_use_camera_texture: bool = true
@export var webcam_config_path: String = "user://projection_canvas_webcam.cfg"
@export var prefer_obs_virtual_camera: bool = true
@export var obs_camera_name_patterns: PackedStringArray = PackedStringArray([
	"obs virtual camera",
	"obs virtual",
	"obs-camera",
	"obs camera",
	"obs-cam",
])

const HUD_CLAIM := "projection_canvas"
const WEBCAM_FEED_RETRY_SECONDS: float = 1.0
const WEBCAM_FEED_RETRY_COUNT: int = 30
const VIDEO_SYNC_SEEK_INTERVAL_SECONDS: float = 0.15
const VIDEO_SYNC_DRIFT_TOLERANCE_SECONDS: float = 0.20

@onready var source_preview: SubViewportContainer = $SourcePreview
@onready var source_subviewport: SubViewport = $SourcePreview/SourceSubViewport
@onready var tl_subviewport: SubViewport = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLViewportPanel/TLViewportContainer/TLSubViewport
@onready var tl_camera: Camera3D = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLViewportPanel/TLViewportContainer/TLSubViewport/TLCamera3D
@onready var tl_status_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLStatusLabel
@onready var tl_viewport_container: SubViewportContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLViewportPanel/TLViewportContainer
@onready var tl_margin: MarginContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin
@onready var tl_vbox: VBoxContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox
@onready var tl_panel: PanelContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView
@onready var tl_viewport_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLViewportPanel
@onready var tl_title_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLTitle

@onready var tr_camera_texture_rect: TextureRect = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost/TRCameraTexture
@onready var tr_video_stream_player: VideoStreamPlayer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost/TRVideoStreamPlayer
@onready var tr_video_placeholder: ColorRect = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost/TRVideoPlaceholder
@onready var tr_status_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRStatusLabel
@onready var tr_panel: PanelContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam
@onready var tr_margin: MarginContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin
@onready var tr_vbox: VBoxContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox
@onready var tr_video_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel
@onready var tr_video_host: Control = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost
@onready var tr_title_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRHeaderRow/TRTitle
@onready var tr_select_feed_button: Button = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRHeaderRow/TRSelectFeedButton
@onready var tr_load_video_button: Button = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRHeaderRow/TRLoadVideoButton
@onready var video_file_dialog: FileDialog = $VideoFileDialog
@onready var tr_feed_name_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRFeedNameLabel
@onready var tr_placeholder_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost/TRVideoPlaceholder/TRPlaceholderLabel
@onready var webcam_setup_dialog: Window = $WebcamSetupDialog
@onready var dialog_intro_label: Label = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogIntroLabel
@onready var dialog_current_feed_label: Label = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogCurrentFeedLabel
@onready var feed_option_button: OptionButton = $WebcamSetupDialog/DialogMargin/DialogVBox/FeedOptionButton
@onready var dialog_refresh_button: Button = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogRefreshButton
@onready var webcam_use_camera_texture_check: CheckBox = $WebcamSetupDialog/DialogMargin/DialogVBox/WebcamUseCameraTextureCheck
@onready var dialog_help_label: Label = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogHelpLabel
@onready var dialog_cancel_button: Button = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogButtons/DialogCancelButton
@onready var dialog_apply_button: Button = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogButtons/DialogApplyButton

const _TR_SYNC_BAR := "SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRTimelapseSyncBar"
const _TR_SPEED_BAR := "SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRTimelapseSpeedBar"
@onready var tr_video_play_pause_btn: Button = get_node_or_null(_TR_SYNC_BAR + "/TRVideoPlayPauseBtn")
@onready var tr_video_scrubber: HSlider = get_node_or_null(_TR_SYNC_BAR + "/TRVideoScrubber")
@onready var tr_video_time_label: Label = get_node_or_null(_TR_SYNC_BAR + "/TRVideoTimeLabel")
@onready var tr_video_slower_btn: Button = get_node_or_null(_TR_SPEED_BAR + "/TRVideoSlowerBtn")
@onready var tr_video_speed_label: Label = get_node_or_null(_TR_SPEED_BAR + "/TRVideoSpeedLabel")
@onready var tr_video_faster_btn: Button = get_node_or_null(_TR_SPEED_BAR + "/TRVideoFasterBtn")
@onready var tr_video_sync_btn: Button = get_node_or_null(_TR_SPEED_BAR + "/TRVideoSyncBtn")

## Emitted when a video file is loaded or the start anchor changes.
signal video_clip_changed

## Absolute sim-hours at which video frame 0 aligns to sim time.
## NAN = fall back to day_time-based sync (legacy / no clip set yet).
var video_start_abs_hours: float = NAN
## Sim-hours covered by one full play-through of the loaded video (cached on load).
var _video_duration_sim_hours: float = 0.0

## The corner-pin warp over both sources (left = sim camera, right = feed).
var warp: ProjectionWarp = null

var _source_camera: Camera3D = null
var _camera_texture: CameraTexture = null
var _active_webcam_feed_name: String = ""
var _saved_webcam_feed_name: String = ""
var _active_video_file_path: String = ""
var _webcam_feed_retry_remaining: int = 0
var _webcam_feed_retry_timer: float = 0.0
var _webcam_user_disabled_auto: bool = false
var _sim_camera_control_active: bool = false
var _sim_camera_look_dragging: bool = false
var _sim_camera_yaw: float = 0.0
var _sim_camera_pitch: float = 0.0
var _video_sync_main: Node = null
var _video_scrubber_updating: bool = false
var _video_last_timescale: float = 0.125
var _video_seek_accum: float = 0.0
var _tr_video_layout_guard: bool = false


func _ready() -> void:
	visible = not start_hidden
	_style_quadrant_shells()
	_style_top_viewports()
	_setup_warp()
	_load_webcam_config()
	_initialize_camera_extension()
	_resolve_source_camera()
	_update_camera_status_label()
	_connect_webcam_ui_signals()
	_connect_sim_camera_ui_signals()
	_sync_subviewport_input()
	_begin_webcam_feed_discovery()
	_cache_sim_camera_angles()
	_connect_video_sync_signals()
	_hide_tr_video_controls()
	_apply_render_mode()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_apply_render_mode()
		# A projector output: nothing of the first-person HUD over it.
		if is_visible_in_tree():
			HudLayout.claim(HUD_CLAIM, {"hide": ["*"]})
		else:
			HudLayout.release(HUD_CLAIM)
		if visible:
			_rescan_camera_feeds(true)
	elif what == NOTIFICATION_EXIT_TREE:
		HudLayout.release(HUD_CLAIM)


## The two SubViewports draw the world a second (and third) time; while the
## canvas is hidden nobody sees them, so they stop rendering. (Both were
## UPDATE_ALWAYS for the life of the scene, canvas hidden or not.)
func _apply_render_mode() -> void:
	var mode := SubViewport.UPDATE_ALWAYS if is_visible_in_tree() else SubViewport.UPDATE_DISABLED
	if source_subviewport != null:
		source_subviewport.render_target_update_mode = mode
	if tl_subviewport != null:
		tl_subviewport.render_target_update_mode = mode


func _setup_warp() -> void:
	warp = ProjectionWarp.new()
	warp.name = "ProjectionWarp"
	warp.config_path = warp_config_path
	warp.quad_count = 2
	warp.title = "Projection mapping · sim camera | live feed"
	add_child(warp)
	warp.setup(source_subviewport.get_texture() if source_subviewport != null else null)
	if not warp.has_saved():
		warp.load_config(legacy_warp_config_path)
	warp.warp_changed.connect(_on_warp_state_changed)
	warp.calibration_changed.connect(_on_warp_state_changed)


## Warped: the flat sources are hidden (they still render into the warp's
## texture) and stop taking clicks.
func _on_warp_state_changed(_on: bool) -> void:
	if source_preview != null:
		source_preview.modulate.a = 0.0 if warp.active else 1.0
	if warp.active:
		_sim_camera_control_active = false
		_sim_camera_look_dragging = false
		_update_camera_status_label()
	_sync_subviewport_input()


func _connect_sim_camera_ui_signals() -> void:
	if tl_viewport_container != null and not tl_viewport_container.gui_input.is_connected(_on_tl_viewport_gui_input):
		tl_viewport_container.gui_input.connect(_on_tl_viewport_gui_input)


func _warp_active() -> bool:
	return warp != null and warp.active


func _process(delta: float) -> void:
	if not visible and _sim_camera_control_active:
		_sim_camera_control_active = false
		_sim_camera_look_dragging = false
		_update_camera_status_label()
	_update_video_sync(delta)
	if not visible:
		return
	_sync_simulated_camera()
	_update_sim_camera_controls(delta)
	_update_webcam_status()
	_tick_webcam_feed_discovery(delta)
	_sync_subviewport_input()
	_layout_tr_video_content()


func _input(event: InputEvent) -> void:
	if not visible or _warp_active():
		return
	_try_activate_sim_camera_from_click(event)
	_try_open_webcam_setup_from_click(event)
	if _sim_camera_control_active:
		_handle_sim_camera_input(event)
		if _should_consume_sim_camera_event(event):
			get_viewport().set_input_as_handled()


func _style_quadrant_shells() -> void:
	if tl_panel != null:
		tl_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(false, 0.94))
	if tr_panel != null:
		tr_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(true, 0.94))


func _style_top_viewports() -> void:
	for m in [tl_margin, tr_margin]:
		if m == null:
			continue
		for side in ["left", "top", "right", "bottom"]:
			(m as MarginContainer).add_theme_constant_override("margin_" + side, 8)
	for v in [tl_vbox, tr_vbox]:
		if v != null:
			(v as VBoxContainer).add_theme_constant_override("separation", 4)
	for pair in [[tl_title_label, UITheme.C_PRIMARY], [tr_title_label, UITheme.C_LAVENDER]]:
		var l := pair[0] as Label
		if l == null:
			continue
		l.add_theme_font_override("font", UITheme.font("semibold"))
		l.add_theme_font_size_override("font_size", UITheme.FONT_XL)
		l.add_theme_color_override("font_color", pair[1])
	for l in [tl_status_label, tr_status_label, tr_feed_name_label]:
		if l != null:
			(l as Label).add_theme_font_size_override("font_size", UITheme.FONT_SM)
			(l as Label).add_theme_color_override("font_color", UITheme.C_TEXT_S)
			(l as Label).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	for btn in [tr_select_feed_button, tr_load_video_button]:
		if btn != null:
			UITheme.style_button(btn as Button)
	if tr_placeholder_label != null:
		tr_placeholder_label.add_theme_font_size_override("font_size", UITheme.FONT_MD)
		tr_placeholder_label.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	if tl_viewport_panel != null:
		tl_viewport_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(false, 0.98))
	if tr_video_panel != null:
		tr_video_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(true, 0.98))
	if tr_video_host != null:
		tr_video_host.clip_contents = true
	if tr_camera_texture_rect != null:
		tr_camera_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr_camera_texture_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	if tr_video_stream_player != null:
		tr_video_stream_player.expand = true
	if tl_viewport_container != null:
		tl_viewport_container.stretch = true


func _make_hud_panel_style(is_live_panel: bool, alpha: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.10, 0.14, alpha) if not is_live_panel else Color(0.09, 0.09, 0.16, alpha)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.20, 0.40, 0.60, 0.8) if not is_live_panel else Color(0.38, 0.43, 0.70, 0.85)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_right = 8
	style.corner_radius_bottom_left = 8
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.32)
	style.shadow_size = 5
	return style


func _resolve_source_camera() -> void:
	if source_camera_path.is_empty():
		_source_camera = null
		return
	var candidate := get_node_or_null(source_camera_path)
	if candidate is Camera3D:
		_source_camera = candidate as Camera3D
		if use_source_world_3d and tl_subviewport != null:
			tl_subviewport.world_3d = _source_camera.get_world_3d()
		if tl_camera != null and not sync_camera_transform:
			_cache_sim_camera_angles()
	else:
		_source_camera = null


func _sync_simulated_camera() -> void:
	if not sync_camera_transform:
		return
	if _source_camera == null:
		return
	if tl_camera == null:
		return
	tl_camera.global_transform = _source_camera.global_transform
	tl_camera.fov = _source_camera.fov
	tl_camera.near = _source_camera.near
	tl_camera.far = _source_camera.far
	if use_source_world_3d and tl_subviewport != null and tl_subviewport.world_3d != _source_camera.get_world_3d():
		tl_subviewport.world_3d = _source_camera.get_world_3d()
	_update_camera_status_label()


func _update_camera_status_label() -> void:
	if _sim_camera_control_active:
		_set_label_text(tl_status_label, "Sim Camera: Control Active (WASD + Space/Ctrl, drag look, wheel FOV, Esc to exit)")
		return
	if sync_camera_transform:
		if _source_camera == null:
			_set_label_text(tl_status_label, "Sim Camera: Sync waiting for source camera")
			return
		_set_label_text(tl_status_label, "Sim Camera: Synced to %s (click panel to take control)" % _source_camera.name)
		return
	_set_label_text(tl_status_label, "Sim Camera: Free mode (click panel to control)")


func _try_activate_sim_camera_from_click(event: InputEvent) -> void:
	if tl_viewport_container == null:
		return
	if event is not InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var panel_rect: Rect2 = tl_viewport_container.get_global_rect()
	if panel_rect.has_point(mb.global_position):
		_sim_camera_control_active = true
		_sim_camera_look_dragging = true
		_update_camera_status_label()
	else:
		_sim_camera_control_active = false
		_sim_camera_look_dragging = false
		_update_camera_status_label()


func _handle_sim_camera_input(event: InputEvent) -> void:
	if tl_camera == null:
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_sim_camera_look_dragging = mb.pressed
			if not mb.pressed:
				_update_camera_status_label()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			tl_camera.fov = clampf(tl_camera.fov - sim_camera_fov_step, sim_camera_min_fov, sim_camera_max_fov)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			tl_camera.fov = clampf(tl_camera.fov + sim_camera_fov_step, sim_camera_min_fov, sim_camera_max_fov)
		return

	if event is InputEventMouseMotion and _sim_camera_look_dragging:
		var motion := event as InputEventMouseMotion
		_sim_camera_yaw -= motion.relative.x * sim_camera_look_sensitivity * 0.01
		_sim_camera_pitch = clampf(_sim_camera_pitch - motion.relative.y * sim_camera_look_sensitivity * 0.01, deg_to_rad(-89.0), deg_to_rad(89.0))
		_apply_sim_camera_rotation()
		return

	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and (key_event.keycode == KEY_ESCAPE or key_event.physical_keycode == KEY_ESCAPE):
			_sim_camera_control_active = false
			_sim_camera_look_dragging = false
			_update_camera_status_label()


func _update_sim_camera_controls(delta: float) -> void:
	if not _sim_camera_control_active:
		return
	if tl_camera == null:
		return

	var forward_input: float = 0.0
	if Input.is_key_pressed(KEY_W):
		forward_input += 1.0
	if Input.is_key_pressed(KEY_S):
		forward_input -= 1.0

	var strafe_input: float = 0.0
	if Input.is_key_pressed(KEY_D):
		strafe_input += 1.0
	if Input.is_key_pressed(KEY_A):
		strafe_input -= 1.0

	var vertical_input: float = 0.0
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_E):
		vertical_input += 1.0
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_Q):
		vertical_input -= 1.0

	var move_dir: Vector3 = Vector3.ZERO
	var forward: Vector3 = -tl_camera.global_basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	var right: Vector3 = tl_camera.global_basis.x
	right.y = 0.0
	if right.length_squared() > 0.0001:
		right = right.normalized()

	move_dir += forward * forward_input
	move_dir += right * strafe_input
	move_dir += Vector3.UP * vertical_input
	if move_dir.length_squared() <= 0.0001:
		return

	move_dir = move_dir.normalized()
	var speed: float = sim_camera_move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= sim_camera_fast_multiplier
	tl_camera.global_position += move_dir * speed * delta


func _should_consume_sim_camera_event(event: InputEvent) -> bool:
	if not visible:
		return false
	if event is InputEventMouseMotion:
		return _sim_camera_look_dragging
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		return mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
	if event is InputEventKey:
		var key_event := event as InputEventKey
		var code: Key = key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode
		return code in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E, KEY_SPACE, KEY_CTRL, KEY_SHIFT, KEY_ESCAPE]
	return false


func _cache_sim_camera_angles() -> void:
	if tl_camera == null:
		return
	var basis: Basis = tl_camera.global_basis
	var forward: Vector3 = -basis.z.normalized()
	_sim_camera_yaw = atan2(forward.x, forward.z)
	_sim_camera_pitch = asin(clampf(forward.y, -1.0, 1.0))


func _apply_sim_camera_rotation() -> void:
	if tl_camera == null:
		return
	tl_camera.global_basis = Basis(Vector3.UP, _sim_camera_yaw) * Basis(Vector3.RIGHT, _sim_camera_pitch)


func _on_tl_viewport_gui_input(event: InputEvent) -> void:
	if not visible or _warp_active():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_try_activate_sim_camera_from_click(event)
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and _sim_camera_control_active:
			_sim_camera_look_dragging = false
			_update_camera_status_label()
			get_viewport().set_input_as_handled()
			return
		if _sim_camera_control_active and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			_handle_sim_camera_input(event)
			get_viewport().set_input_as_handled()
			return


func _update_webcam_status() -> void:
	_refresh_active_webcam_feed_name()
	_update_webcam_feed_label()

	if tr_camera_texture_rect != null and tr_camera_texture_rect.visible and tr_camera_texture_rect.texture != null:
		_set_label_text(tr_status_label, "Feed Status: Active (%s)" % _get_webcam_feed_display_name())
		_set_placeholder_hint(false)
		return

	if tr_video_stream_player != null and tr_video_stream_player.visible and tr_video_stream_player.stream != null:
		_set_label_text(tr_status_label, "Feed Status: Active (Video stream)")
		_set_placeholder_hint(false)
		return

	if _get_available_camera_feed_count() > 0:
		_set_label_text(tr_status_label, "Feed Status: Click LIVE panel or INPUT to choose camera")
	else:
		_set_label_text(tr_status_label, "Feed Status: No camera feeds detected")

	var show_placeholder := tr_video_stream_player == null or tr_video_stream_player.stream == null
	show_placeholder = show_placeholder and (tr_camera_texture_rect == null or tr_camera_texture_rect.texture == null or not tr_camera_texture_rect.visible)
	if tr_video_placeholder != null:
		tr_video_placeholder.visible = show_placeholder
	_set_placeholder_hint(show_placeholder)


func _set_placeholder_hint(show_hint: bool) -> void:
	if tr_placeholder_label == null:
		return
	tr_placeholder_label.visible = show_hint
	if show_hint:
		tr_placeholder_label.text = "Click to select camera input"


func _sync_subviewport_input() -> void:
	if source_preview == null:
		return
	var allow_subviewport_ui := visible and not _warp_active()
	source_preview.mouse_filter = Control.MOUSE_FILTER_STOP if allow_subviewport_ui else Control.MOUSE_FILTER_IGNORE


func _begin_webcam_feed_discovery() -> void:
	_webcam_feed_retry_remaining = WEBCAM_FEED_RETRY_COUNT
	_webcam_feed_retry_timer = 0.0
	_rescan_camera_feeds(false)


func _tick_webcam_feed_discovery(delta: float) -> void:
	if _webcam_feed_retry_remaining <= 0:
		return
	if _is_webcam_feed_active():
		_webcam_feed_retry_remaining = 0
		return
	if _get_available_camera_feed_count() > 0 and webcam_feed_id >= 0 and _apply_webcam_configuration():
		_webcam_feed_retry_remaining = 0
		return

	_webcam_feed_retry_timer -= delta
	if _webcam_feed_retry_timer > 0.0:
		return

	_webcam_feed_retry_timer = WEBCAM_FEED_RETRY_SECONDS
	_webcam_feed_retry_remaining -= 1
	_rescan_camera_feeds(true)


func _rescan_camera_feeds(force_recreate_extension: bool) -> void:
	if force_recreate_extension and CameraServerBootstrap != null:
		if _camera_texture != null:
			_camera_texture.camera_feed_id = -1
		CameraServerBootstrap.rescan_feeds()
	_on_camera_feeds_ready(false)


func _get_camera_extension_status() -> String:
	if CameraServerBootstrap == null:
		return "Camera bootstrap not available"
	return CameraServerBootstrap.last_status_message


func _initialize_camera_extension() -> void:
	if CameraServerBootstrap == null:
		return
	if not CameraServerBootstrap.feeds_rescan_completed.is_connected(_on_bootstrap_feeds_rescan_completed):
		CameraServerBootstrap.feeds_rescan_completed.connect(_on_bootstrap_feeds_rescan_completed)
	_begin_webcam_feed_discovery()


func _on_bootstrap_feeds_rescan_completed(_feed_count: int, _feed_names: PackedStringArray, _status_message: String) -> void:
	_on_camera_feeds_ready(false)


func _is_webcam_feed_active() -> bool:
	return webcam_use_camera_texture and webcam_feed_id >= 0 and tr_camera_texture_rect != null and tr_camera_texture_rect.visible and tr_camera_texture_rect.texture != null


func _connect_webcam_ui_signals() -> void:
	if tr_video_placeholder != null and not tr_video_placeholder.gui_input.is_connected(_on_tr_video_placeholder_gui_input):
		tr_video_placeholder.gui_input.connect(_on_tr_video_placeholder_gui_input)
	if tr_select_feed_button != null and not tr_select_feed_button.pressed.is_connected(_on_tr_select_feed_button_pressed):
		tr_select_feed_button.pressed.connect(_on_tr_select_feed_button_pressed)
	if tr_load_video_button != null and not tr_load_video_button.pressed.is_connected(_on_tr_load_video_button_pressed):
		tr_load_video_button.pressed.connect(_on_tr_load_video_button_pressed)
	if video_file_dialog != null and not video_file_dialog.file_selected.is_connected(_on_video_file_selected):
		video_file_dialog.file_selected.connect(_on_video_file_selected)
	if dialog_refresh_button != null and not dialog_refresh_button.pressed.is_connected(_on_dialog_refresh_button_pressed):
		dialog_refresh_button.pressed.connect(_on_dialog_refresh_button_pressed)
	if dialog_cancel_button != null and not dialog_cancel_button.pressed.is_connected(_on_webcam_cancel_button_pressed):
		dialog_cancel_button.pressed.connect(_on_webcam_cancel_button_pressed)
	if dialog_apply_button != null and not dialog_apply_button.pressed.is_connected(_on_webcam_apply_button_pressed):
		dialog_apply_button.pressed.connect(_on_webcam_apply_button_pressed)
	if webcam_setup_dialog != null and not webcam_setup_dialog.close_requested.is_connected(_on_webcam_close_requested):
		webcam_setup_dialog.close_requested.connect(_on_webcam_close_requested)


func _try_open_webcam_setup_from_click(event: InputEvent) -> void:
	if event is not InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if tr_video_host == null:
		return
	if not tr_video_host.get_global_rect().has_point(mb.global_position):
		return
	_open_webcam_setup_dialog()


func _on_tr_select_feed_button_pressed() -> void:
	_open_webcam_setup_dialog()


func _on_tr_load_video_button_pressed() -> void:
	if video_file_dialog == null:
		return
	video_file_dialog.popup_centered()


func _on_video_file_selected(path: String) -> void:
	_load_video_file(path)


func _load_video_file(path: String) -> void:
	if tr_video_stream_player == null:
		return

	var stream: VideoStream = _make_video_stream(path)
	if stream == null:
		push_warning("ProjectionCanvas: Could not create video stream for: %s" % path)
		_set_label_text(tr_feed_name_label, "Error: unsupported video format")
		return

	_active_video_file_path = path

	# Lock TR panel to the selected video input.
	_webcam_user_disabled_auto = true
	webcam_use_camera_texture = false
	webcam_feed_id = -1
	if _camera_texture != null:
		_camera_texture.camera_feed_id = -1
	if tr_camera_texture_rect != null:
		tr_camera_texture_rect.visible = false

	tr_video_stream_player.stream = stream
	tr_video_stream_player.loop = true
	tr_video_stream_player.visible = true
	tr_video_stream_player.play()
	_video_seek_accum = 0.0

	# Snap start anchor to current playhead so the NLE clip is immediately visible.
	if _video_sync_main == null:
		_video_sync_main = _find_sim_main()
	if _video_sync_main != null and _video_sync_main.has_method("get_absolute_hours"):
		video_start_abs_hours = float(_video_sync_main.call("get_absolute_hours"))
	else:
		video_start_abs_hours = NAN
	# Cache duration after play() so the stream length is available.
	call_deferred("_cache_video_duration_and_notify")

	_apply_video_sync_speed()
	_seek_video_to_sim_time()
	_apply_webcam_configuration()

	if tr_video_placeholder != null:
		tr_video_placeholder.visible = false

	var filename := path.get_file()
	_set_label_text(tr_feed_name_label, filename)
	_set_label_text(tr_status_label, "Feed Status: Video file — %s (looping)" % filename)

	_save_webcam_config()


func _make_video_stream(path: String) -> VideoStream:
	var ext := path.get_extension().to_lower()
	if ext in ["ogv", "ogg"]:
		var s := VideoStreamTheora.new()
		s.file = path
		return s
	if ClassDB.class_exists("FFmpegVideoStream"):
		var s = ClassDB.instantiate("FFmpegVideoStream")
		if s != null:
			s.file = path
			return s as VideoStream
	var fallback := load(path)
	if fallback is VideoStream:
		return fallback as VideoStream
	return null


func _on_dialog_refresh_button_pressed() -> void:
	_rescan_camera_feeds(true)


func _on_tr_video_placeholder_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_open_webcam_setup_dialog()
		get_viewport().set_input_as_handled()


func _open_webcam_setup_dialog() -> void:
	if webcam_setup_dialog == null:
		return
	_rescan_camera_feeds(true)
	webcam_setup_dialog.popup_centered()


func _on_camera_feeds_ready(refresh_dialog_only: bool) -> void:
	_refresh_available_camera_feeds()
	_validate_saved_webcam_feed_id()
	if not refresh_dialog_only:
		_try_apply_saved_or_default_feed()
	_update_webcam_feed_label()
	_update_webcam_status()


func _refresh_available_camera_feeds() -> void:
	if feed_option_button == null:
		return

	CameraServer.monitoring_feeds = true

	feed_option_button.clear()
	feed_option_button.add_item("None (leave unconfigured)")
	feed_option_button.set_item_metadata(0, -1)

	var feeds: Array = CameraServer.feeds()
	for feed in feeds:
		var feed_id: int = int(feed.get_id())
		var feed_name: String = _get_feed_display_name(feed)
		feed_option_button.add_item("%s (id %d)" % [feed_name, feed_id])
		feed_option_button.set_item_metadata(feed_option_button.item_count - 1, feed_id)
		if feed_id == webcam_feed_id:
			feed_option_button.select(feed_option_button.item_count - 1)

	if webcam_use_camera_texture_check != null:
		webcam_use_camera_texture_check.button_pressed = webcam_use_camera_texture
	if webcam_feed_id < 0:
		feed_option_button.select(0)


func _try_apply_saved_or_default_feed() -> bool:
	if webcam_feed_id >= 0 and _apply_webcam_configuration():
		return true

	if _webcam_user_disabled_auto or not prefer_obs_virtual_camera:
		return false

	var preferred_feed_id := _find_preferred_obs_feed_id()
	if preferred_feed_id < 0:
		return false

	webcam_feed_id = preferred_feed_id
	webcam_use_camera_texture = true
	if not _apply_webcam_configuration():
		return false

	_save_webcam_config()
	_refresh_available_camera_feeds()
	return true


func _validate_saved_webcam_feed_id() -> void:
	if webcam_feed_id >= 0 and _find_feed_by_id(webcam_feed_id) != null:
		return

	var restored_id := _find_feed_id_by_name(_saved_webcam_feed_name)
	if restored_id >= 0:
		webcam_feed_id = restored_id
		return

	webcam_feed_id = -1


func _find_preferred_obs_feed_id() -> int:
	var feeds: Array = CameraServer.feeds()
	for feed in feeds:
		var feed_name: String = str(feed.get_name()).to_lower()
		for pattern in obs_camera_name_patterns:
			if feed_name.contains(pattern.to_lower()):
				return int(feed.get_id())
	return -1


func _find_feed_by_id(feed_id: int):
	for feed in CameraServer.feeds():
		if int(feed.get_id()) == feed_id:
			return feed
	return null


func _find_feed_id_by_name(feed_name: String) -> int:
	var target := feed_name.strip_edges().to_lower()
	if target == "":
		return -1
	for feed in CameraServer.feeds():
		if _get_feed_display_name(feed).to_lower() == target:
			return int(feed.get_id())
	return -1


func _get_feed_display_name(feed) -> String:
	var feed_name: String = str(feed.get_name()).strip_edges()
	if feed_name == "":
		feed_name = "Camera Feed %d" % int(feed.get_id())
	return feed_name


func _get_available_camera_feed_count() -> int:
	return CameraServer.feeds().size()


func _get_webcam_feed_display_name() -> String:
	if _active_webcam_feed_name.strip_edges() != "":
		return _active_webcam_feed_name
	if webcam_feed_id >= 0:
		return "Camera Feed %d" % webcam_feed_id
	return "none"


func _refresh_active_webcam_feed_name() -> void:
	_active_webcam_feed_name = ""
	if webcam_feed_id < 0:
		return
	var feed = _find_feed_by_id(webcam_feed_id)
	if feed != null:
		_active_webcam_feed_name = _get_feed_display_name(feed)


func _update_webcam_feed_label() -> void:
	var display_name := _get_webcam_feed_display_name()
	if tr_feed_name_label != null:
		if _is_webcam_feed_active():
			tr_feed_name_label.text = display_name
		elif _get_available_camera_feed_count() > 0:
			tr_feed_name_label.text = "Click LIVE panel or INPUT to choose camera"
		else:
			tr_feed_name_label.text = _get_camera_extension_status()
	if dialog_current_feed_label != null:
		dialog_current_feed_label.text = "Current input: %s" % display_name
	if dialog_help_label != null:
		if _get_available_camera_feed_count() > 0:
			dialog_help_label.text = "%s\nSelect a feed above and click Apply Feed." % _get_camera_extension_status()
		else:
			dialog_help_label.text = "%s\nStart OBS Virtual Camera, then click Refresh Feed List." % _get_camera_extension_status()


func _on_webcam_cancel_button_pressed() -> void:
	webcam_setup_dialog.hide()


func _on_webcam_close_requested() -> void:
	webcam_setup_dialog.hide()


func _on_webcam_apply_button_pressed() -> void:
	if feed_option_button == null:
		return
	var selected_index := feed_option_button.selected
	var selected_feed_id := -1
	if selected_index >= 0:
		selected_feed_id = int(feed_option_button.get_item_metadata(selected_index))
	webcam_feed_id = selected_feed_id
	if webcam_use_camera_texture_check != null:
		webcam_use_camera_texture = webcam_use_camera_texture_check.button_pressed
	_webcam_user_disabled_auto = selected_feed_id < 0
	_apply_webcam_configuration()
	_save_webcam_config()
	_update_webcam_feed_label()
	_update_webcam_status()
	if webcam_setup_dialog != null:
		webcam_setup_dialog.hide()


func _apply_webcam_configuration() -> bool:
	var stream_assigned := tr_video_stream_player != null and tr_video_stream_player.stream != null
	var camera_feed_applied := false

	if webcam_use_camera_texture and webcam_feed_id >= 0:
		camera_feed_applied = _apply_camera_feed_texture(webcam_feed_id)

	if tr_camera_texture_rect != null:
		tr_camera_texture_rect.visible = camera_feed_applied
	if tr_video_stream_player != null:
		tr_video_stream_player.visible = (not camera_feed_applied) and stream_assigned
	if tr_video_placeholder != null:
		tr_video_placeholder.visible = (not camera_feed_applied) and (not stream_assigned)

	_refresh_active_webcam_feed_name()
	return camera_feed_applied


func _apply_camera_feed_texture(feed_id: int) -> bool:
	var feeds: Array = CameraServer.feeds()
	var found := false
	for feed in feeds:
		if feed.get_id() == feed_id:
			found = true
			feed.set_active(true)
			break

	if not found:
		return false

	if _camera_texture == null:
		_camera_texture = CameraTexture.new()
	_camera_texture.camera_feed_id = feed_id
	tr_camera_texture_rect.texture = _camera_texture
	return true


func _load_webcam_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(webcam_config_path) != OK:
		return
	webcam_feed_id = int(cfg.get_value("webcam", "feed_id", webcam_feed_id))
	webcam_use_camera_texture = bool(cfg.get_value("webcam", "use_camera_texture", webcam_use_camera_texture))
	_saved_webcam_feed_name = str(cfg.get_value("webcam", "feed_name", ""))
	_webcam_user_disabled_auto = bool(cfg.get_value("webcam", "user_disabled_auto", false))
	_active_video_file_path = str(cfg.get_value("webcam", "video_file_path", ""))

	if _active_video_file_path != "" and FileAccess.file_exists(_active_video_file_path):
		call_deferred("_load_video_file", _active_video_file_path)


func _save_webcam_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("webcam", "feed_id", webcam_feed_id)
	cfg.set_value("webcam", "feed_name", _active_webcam_feed_name)
	cfg.set_value("webcam", "use_camera_texture", webcam_use_camera_texture)
	cfg.set_value("webcam", "user_disabled_auto", _webcam_user_disabled_auto)
	cfg.set_value("webcam", "video_file_path", _active_video_file_path)
	cfg.save(webcam_config_path)


func _set_label_text(label: Label, value: String) -> void:
	if label != null:
		label.text = value


# ---------------------------------------------------------------------------
# Timelapse video <-> simulation sync
# ---------------------------------------------------------------------------

## Hide the per-panel scrubber/speed bars and header buttons from the TR panel.
## Controls are moved to the main NLE timeline row instead.
func _hide_tr_video_controls() -> void:
	var sync_bar := get_node_or_null(_TR_SYNC_BAR)
	if sync_bar != null:
		(sync_bar as Control).visible = false
	var speed_bar := get_node_or_null(_TR_SPEED_BAR)
	if speed_bar != null:
		(speed_bar as Control).visible = false
	if tr_select_feed_button != null:
		tr_select_feed_button.visible = false
	if tr_load_video_button != null:
		tr_load_video_button.visible = false


## Public — returns the absolute-hours [start, end] of the loaded video clip,
## or [NAN, NAN] when no video is loaded or no anchor is set. 64-bit: a
## Vector2 holds absolute hours only to the nearest 2 h.
func get_video_clip_range_abs() -> PackedFloat64Array:
	if tr_video_stream_player == null or tr_video_stream_player.stream == null:
		return PackedFloat64Array([NAN, NAN])
	if is_nan(video_start_abs_hours) or _video_duration_sim_hours <= 0.0:
		return PackedFloat64Array([NAN, NAN])
	return PackedFloat64Array([video_start_abs_hours, video_start_abs_hours + _video_duration_sim_hours])


## Snap the video start anchor to an explicit absolute-hours value (e.g. the
## current playhead). The video track on the NLE timeline updates immediately.
func set_video_start_abs_hours(h: float) -> void:
	video_start_abs_hours = h
	video_clip_changed.emit()


## Open the file-picker to load a video into the TR panel (called from TimelineUI).
func open_load_video_dialog() -> void:
	if video_file_dialog != null:
		video_file_dialog.popup_centered()


## Open the live-feed setup dialog (called from TimelineUI).
func open_live_feed_dialog() -> void:
	_open_webcam_setup_dialog()


## Called deferred after video starts playing so the stream length is readable.
func _cache_video_duration_and_notify() -> void:
	var d := _get_video_duration_seconds()
	_video_duration_sim_hours = d * video_reference_time_scale
	video_clip_changed.emit()


func _find_sim_main() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene != null and scene.has_method("get_lunar_phase"):
		return scene
	return null


func _find_timeline_ui() -> Node:
	if not timeline_ui_path.is_empty():
		var by_path := get_node_or_null(timeline_ui_path)
		if by_path != null:
			return by_path
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.find_child("TimelineUI", true, false)


func _connect_video_sync_signals() -> void:
	if tr_video_play_pause_btn != null and not tr_video_play_pause_btn.pressed.is_connected(_on_video_play_pause_pressed):
		tr_video_play_pause_btn.pressed.connect(_on_video_play_pause_pressed)
	if tr_video_scrubber != null and not tr_video_scrubber.value_changed.is_connected(_on_video_scrubber_changed):
		tr_video_scrubber.value_changed.connect(_on_video_scrubber_changed)
	if tr_video_slower_btn != null and not tr_video_slower_btn.pressed.is_connected(_on_video_slower_pressed):
		tr_video_slower_btn.pressed.connect(_on_video_slower_pressed)
	if tr_video_faster_btn != null and not tr_video_faster_btn.pressed.is_connected(_on_video_faster_pressed):
		tr_video_faster_btn.pressed.connect(_on_video_faster_pressed)
	if tr_video_sync_btn != null and not tr_video_sync_btn.pressed.is_connected(_on_video_sync_pressed):
		tr_video_sync_btn.pressed.connect(_on_video_sync_pressed)


func _update_video_sync(delta: float) -> void:
	if not video_sync_enabled:
		return
	if _video_sync_main == null or not is_instance_valid(_video_sync_main):
		_video_sync_main = _find_sim_main()
	if _video_sync_main == null:
		return

	var ts: float = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else 0.0)
	var dt: float = float(_video_sync_main.get("day_time") if _video_sync_main.get("day_time") != null else 0.0)

	if ts > 0.0:
		_video_last_timescale = ts

	var has_video := tr_video_stream_player != null and tr_video_stream_player.stream != null
	if has_video:
		# Pause sync
		var should_pause := ts == 0.0
		var was_paused := tr_video_stream_player.paused
		if tr_video_stream_player.paused != should_pause:
			tr_video_stream_player.paused = should_pause
		# Explicitly resume playback when simulation resumes.
		# Some backends need play() after paused -> unpaused transitions.
		if was_paused and not should_pause:
			tr_video_stream_player.play()
		# Compute expected video position. When an abs_hours anchor is set use
		# multi-day absolute time so the clip stays locked across speed changes.
		var abs_h: float = NAN
		if _video_sync_main.has_method("get_absolute_hours"):
			abs_h = float(_video_sync_main.call("get_absolute_hours"))
		var expected_seconds: float
		if not is_nan(video_start_abs_hours) and not is_nan(abs_h):
			expected_seconds = (abs_h - video_start_abs_hours) / maxf(video_reference_time_scale, 0.0001)
		else:
			expected_seconds = _sim_hour_to_video_seconds(dt)
		var expected_pos := _normalized_video_position(expected_seconds)
		var current_pos := tr_video_stream_player.stream_position
		var drift := absf(expected_pos - current_pos)
		var use_periodic_seek := not is_equal_approx(absf(ts), video_reference_time_scale)
		if should_pause:
			# Keep paused frame locked to simulation clock.
			if drift > VIDEO_SYNC_DRIFT_TOLERANCE_SECONDS:
				tr_video_stream_player.stream_position = expected_pos
			_video_seek_accum = 0.0
		elif use_periodic_seek:
			# At non-reference speeds, let decode run and correct often enough.
			_video_seek_accum += maxf(delta, 0.0)
			if _video_seek_accum >= VIDEO_SYNC_SEEK_INTERVAL_SECONDS or drift > VIDEO_SYNC_DRIFT_TOLERANCE_SECONDS:
				tr_video_stream_player.stream_position = expected_pos
				_video_seek_accum = 0.0
		else:
			# At reference speed (450x), native playback should already match.
			_video_seek_accum = 0.0

	# Update scrubber without triggering feedback
	if not _video_scrubber_updating and tr_video_scrubber != null:
		_video_scrubber_updating = true
		tr_video_scrubber.value = dt
		_video_scrubber_updating = false

	_update_video_control_labels(ts, dt)


func _update_video_control_labels(ts: float, dt: float) -> void:
	if tr_video_play_pause_btn != null:
		tr_video_play_pause_btn.text = "⏸" if ts > 0.0 else "▶"

	if tr_video_time_label != null:
		var hh := int(dt) % 24
		var mm := int((dt - floor(dt)) * 60.0)
		var ap := "AM" if hh < 12 else "PM"
		var disp := hh % 12
		if disp == 0:
			disp = 12
		tr_video_time_label.text = "%d:%02d %s" % [disp, mm, ap]

	if tr_video_speed_label != null:
		if ts == 0.0:
			tr_video_speed_label.text = "PAUSED"
		else:
			# Match against TimelineUI speed steps
			var best_i := 0
			var best_d := absf(ts - float(TimelineUI.SPEED_STEPS[0][1]))
			for i in range(1, TimelineUI.SPEED_STEPS.size()):
				var d := absf(ts - float(TimelineUI.SPEED_STEPS[i][1]))
				if d < best_d:
					best_d = d
					best_i = i
			tr_video_speed_label.text = "%s SYNC" % str(TimelineUI.SPEED_STEPS[best_i][0])


func _seek_video_to_sim_time() -> void:
	if tr_video_stream_player == null or tr_video_stream_player.stream == null:
		return
	if _video_sync_main == null:
		_video_sync_main = _find_sim_main()
	if _video_sync_main == null:
		return
	var dt: float = float(_video_sync_main.get("day_time") if _video_sync_main.get("day_time") != null else 0.0)
	var pos := _normalized_video_position(_sim_hour_to_video_seconds(dt))
	tr_video_stream_player.stream_position = pos


func _apply_video_sync_speed() -> void:
	if tr_video_stream_player == null or tr_video_stream_player.stream == null:
		return
	if _video_sync_main == null:
		_video_sync_main = _find_sim_main()
	var ts: float = video_reference_time_scale
	if _video_sync_main != null:
		ts = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else video_reference_time_scale)
	tr_video_stream_player.paused = ts == 0.0


func _sim_hour_to_video_seconds(sim_hour: float) -> float:
	# Example with default values: 450x -> 0.125 time_scale -> 1 sim hour maps to 8 video seconds.
	return maxf(0.0, (sim_hour - video_start_hour) / maxf(video_reference_time_scale, 0.0001))


func _normalized_video_position(pos_seconds: float) -> float:
	var duration := _get_video_duration_seconds()
	if duration > 0.001:
		return fposmod(pos_seconds, duration)
	return pos_seconds


func _get_video_duration_seconds() -> float:
	if tr_video_stream_player == null or tr_video_stream_player.stream == null:
		return 0.0
	var stream := tr_video_stream_player.stream
	if stream.has_method("get_length"):
		var len := float(stream.call("get_length"))
		if len > 0.0:
			return len
	if tr_video_stream_player.has_method("get_stream_length"):
		var alt := float(tr_video_stream_player.call("get_stream_length"))
		if alt > 0.0:
			return alt
	return 0.0


func _on_video_play_pause_pressed() -> void:
	var timeline := _find_timeline_ui()
	if timeline != null and timeline.has_method("toggle_play"):
		timeline.call("toggle_play")
		return
	if _video_sync_main == null or not is_instance_valid(_video_sync_main):
		_video_sync_main = _find_sim_main()
	if _video_sync_main == null:
		return
	var ts: float = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else 0.0)
	if ts > 0.0:
		_video_last_timescale = ts
		_video_sync_main.set("time_scale", 0.0)
	else:
		var resume := _video_last_timescale if _video_last_timescale > 1e-6 else video_reference_time_scale
		_video_sync_main.set("time_scale", resume)


func _on_video_scrubber_changed(value: float) -> void:
	if _video_scrubber_updating:
		return
	if _video_sync_main == null or not is_instance_valid(_video_sync_main):
		_video_sync_main = _find_sim_main()
	if _video_sync_main != null:
		_video_sync_main.set("day_time", value)
	_seek_video_to_sim_time()


func _on_video_slower_pressed() -> void:
	var timeline := _find_timeline_ui()
	if timeline != null and timeline.has_method("speed_down"):
		timeline.call("speed_down")
	elif _video_sync_main != null and is_instance_valid(_video_sync_main):
		var ts: float = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else video_reference_time_scale)
		var best_i := 0
		var best_d := absf(ts - float(TimelineUI.SPEED_STEPS[0][1]))
		for i in range(1, TimelineUI.SPEED_STEPS.size()):
			var d := absf(ts - float(TimelineUI.SPEED_STEPS[i][1]))
			if d < best_d:
				best_d = d
				best_i = i
		best_i = max(best_i - 1, 0)
		_video_sync_main.set("time_scale", float(TimelineUI.SPEED_STEPS[best_i][1]))


func _on_video_faster_pressed() -> void:
	var timeline := _find_timeline_ui()
	if timeline != null and timeline.has_method("speed_up"):
		timeline.call("speed_up")
	elif _video_sync_main != null and is_instance_valid(_video_sync_main):
		var ts: float = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else video_reference_time_scale)
		var best_i := 0
		var best_d := absf(ts - float(TimelineUI.SPEED_STEPS[0][1]))
		for i in range(1, TimelineUI.SPEED_STEPS.size()):
			var d := absf(ts - float(TimelineUI.SPEED_STEPS[i][1]))
			if d < best_d:
				best_d = d
				best_i = i
		best_i = min(best_i + 1, TimelineUI.SPEED_STEPS.size() - 1)
		# Skip the ∞ analemma preset (INF) — video sync uses finite speeds only.
		while best_i > 0 and not is_finite(float(TimelineUI.SPEED_STEPS[best_i][1])):
			best_i -= 1
		_video_sync_main.set("time_scale", float(TimelineUI.SPEED_STEPS[best_i][1]))


func _on_video_sync_pressed() -> void:
	_seek_video_to_sim_time()


func _layout_tr_video_content() -> void:
	if _tr_video_layout_guard:
		return
	if tr_video_host == null or tr_video_stream_player == null:
		return
	var host_size := tr_video_host.size
	if host_size.x <= 1.0 or host_size.y <= 1.0:
		return
	var aspect := maxf(timelapse_display_aspect, 0.1)
	var host_aspect := host_size.x / host_size.y
	var target_size := host_size
	if host_aspect > aspect:
		target_size.x = host_size.y * aspect
	else:
		target_size.y = host_size.x / aspect
	var target_pos := (host_size - target_size) * 0.5

	_tr_video_layout_guard = true
	tr_video_stream_player.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	tr_video_stream_player.position = target_pos
	tr_video_stream_player.size = target_size
	_tr_video_layout_guard = false

	_layout_tl_to_match_video_aspect()


## Letterbox the TL simulated-view SubViewportContainer to the same aspect ratio
## as the TR timelapse video so both panels share the same frame geometry.
func _layout_tl_to_match_video_aspect() -> void:
	if tl_viewport_panel == null or tl_viewport_container == null:
		return
	var host_size := tl_viewport_panel.size
	if host_size.x <= 1.0 or host_size.y <= 1.0:
		return
	var aspect := maxf(timelapse_display_aspect, 0.1)
	var host_aspect := host_size.x / host_size.y
	var target_size := host_size
	if host_aspect > aspect:
		target_size.x = host_size.y * aspect
	else:
		target_size.y = host_size.x / aspect
	var target_pos := (host_size - target_size) * 0.5
	tl_viewport_container.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	tl_viewport_container.position = target_pos
	tl_viewport_container.size = target_size
