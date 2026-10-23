class_name ClimelapsePreview
extends Node

## Plays a video export in the game window before it is rendered: the clock
## walks the export range at the export's speed (sim-hours per video second)
## in REAL time, and a preview camera follows the keyframes. Nothing is
## written; it is the cheap look before the long render.
##
## Holds the clock (exclusive claim, time_scale 0 — this node places every
## instant itself, like the export) and the camera (exclusive camera claim) and
## gives both back on every exit: Stop, Esc (the CursorController modal), the
## end of the range, or the node leaving the tree. Started by
## TerrainLoader.start_climelapse_preview.

signal finished

const OWNER := "climelapse_preview"
## Seconds the last frame holds before the preview loops.
const END_HOLD_S := 1.0

var _main: Node = null
var _opts: Dictionary = {}
var _rig: ClimelapseCameraRig = null
var _cam: Camera3D = null
var _t := 0.0
var _paused := false
var _running := false
var _hold := 0.0
var _hud: CanvasLayer = null
var _label: Label = null
var _pause_btn: Button = null
var _prev_hours := NAN
## Video seconds into the shot (the clock follows it; an analemma steps one
## day per video frame).
var _vt := 0.0
var _sky: ClimelapseSkyDirector = null
var _scrub: HSlider = null
var _scrub_sync := false
var _ana_frame := -1      # last analemma frame placed (stepping only goes forward)
## Seconds a ←/→ press moves the preview.
const STEP_S := 1.0


func is_running() -> bool:
	return _running


func current_hours() -> float:
	return _t


func begin(main: Node, opts: Dictionary, rig: ClimelapseCameraRig, from_abs: float = NAN,
		paused: bool = false) -> bool:
	if main == null or rig == null or not rig.is_valid():
		return false
	_main = main
	_opts = opts
	_rig = rig
	_paused = paused
	var range_start := float(opts["start_abs"])
	var range_end := float(opts["end_abs"])
	_t = clampf(from_abs, range_start, range_end) if not is_nan(from_abs) else range_start
	_vt = (_t - range_start) / maxf(float(opts["hours_per_second"]), 1e-6)
	if main.has_method("get_absolute_hours"):
		_prev_hours = float(main.call("get_absolute_hours"))
	_sky = ClimelapseSkyDirector.new(opts)
	if _sky.analemma() > 0:
		_vt = 0.0
	# A spread camera path: start where the asked-for moment (a keyframe's)
	# sits on the path, not at its timeline hour.
	if not is_nan(from_abs) and rig.has_keys() and rig.key_timing == "spread":
		_vt = rig.keys.progress_of(from_abs) * ClimelapseExportOptions.video_seconds(opts)
	_sky.begin(main)
	if main.has_method("push_clock_claim") and not bool(main.call("push_clock_claim", OWNER,
			_sky.clock_claim_values(), true)):
		_sky.end(main)
		return false
	# From here on end() owns the clean-up, whatever fails below.
	_running = true
	_cam = Camera3D.new()
	_cam.name = "ClimelapsePreviewCam"
	_cam.top_level = true
	_cam.near = rig.near_plane
	_cam.far = rig.far_plane
	_cam.environment = rig.environment
	_cam.attributes = rig.attributes
	_cam.cull_mask = rig.cull_mask
	main.add_child(_cam)
	_apply_instant()
	if main.has_method("push_camera_claim"):
		main.call("push_camera_claim", OWNER, {"camera_id": _cam.get_instance_id(),
			"hide_player_mesh": false}, true)
	_build_hud()
	var cc := get_node_or_null("/root/CursorController")
	if cc != null:
		cc.call("request_modal", OWNER, end)
	HudLayout.claim(OWNER, {"hide": ["*"]})
	return true


func _process(delta: float) -> void:
	if not _running:
		return
	var total_s := ClimelapseExportOptions.video_seconds(_opts)
	if not _paused:
		if _vt >= total_s:
			_hold += delta
			if _hold >= END_HOLD_S:
				restart()
		else:
			_vt = minf(_vt + delta, total_s)
	_apply_instant()


func _apply_instant() -> void:
	if _main == null or not is_instance_valid(_main):
		return
	var start := float(_opts["start_abs"])
	var total_s := ClimelapseExportOptions.video_seconds(_opts)
	if _sky.analemma() > 0:
		var frames := ClimelapseExportOptions.frame_count(_opts)
		var fi := clampi(int(floor(_vt * float(int(_opts["fps"])))), 0, maxi(frames - 1, 0))
		if fi < _ana_frame:
			# The analemma only steps forward: a scrub back starts it again.
			_sky.restart(_main)
		_ana_frame = fi
		_t = _sky.place(_main, fi)
	else:
		_t = minf(start + _vt * float(_opts["hours_per_second"]), float(_opts["end_abs"]))
		_sky.place_at(_main, _t)
	var tl := get_parent()
	if tl != null and tl.has_method("_push_growth_year"):
		tl.call("_push_growth_year")
	# Progress through the VIDEO (what the export's frame index gives the rig).
	var t_norm := clampf(_vt / total_s, 0.0, 1.0) if total_s > 0.0 else 0.0
	var pose := _sky.camera_pose(_main, _rig.pose_at(_t, t_norm))
	if is_instance_valid(_cam):
		_cam.global_transform = pose.get("xform", _rig.global_xform)
		_cam.fov = float(pose.get("fov", _rig.fov))
	if _scrub != null and not _scrub_sync:
		_scrub_sync = true
		_scrub.max_value = maxf(total_s, 0.01)
		_scrub.set_value_no_signal(_vt)
		_scrub_sync = false
	if _label != null:
		var vid_s := _vt
		_label.text = "Preview  ·  %s  ·  %s / %s of video%s" % [
			ClimelapseExportOptions.timecode_at(_t),
			ClimelapseExportOptions.duration_label(vid_s),
			ClimelapseExportOptions.duration_label(total_s),
			"  ·  paused" if _paused else ""]


func toggle_pause() -> void:
	_paused = not _paused
	if _pause_btn != null:
		_pause_btn.text = "Play" if _paused else "Pause"


func restart() -> void:
	_t = float(_opts["start_abs"])
	_vt = 0.0
	_hold = 0.0
	_ana_frame = -1
	if _sky != null:
		_sky.restart(_main)


## Jump to `sec` seconds of the video (the scrub bar, ←/→).
func seek(sec: float) -> void:
	_vt = clampf(sec, 0.0, ClimelapseExportOptions.video_seconds(_opts))
	_hold = 0.0
	_apply_instant()


func video_time() -> float:
	return _vt


func camera() -> Camera3D:
	return _cam


func _input(event: InputEvent) -> void:
	if not _running or not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	var k := event as InputEventKey
	match k.physical_keycode:
		KEY_SPACE:
			toggle_pause()
		KEY_LEFT:
			seek(_vt - STEP_S)
		KEY_RIGHT:
			seek(_vt + STEP_S)
		KEY_HOME:
			restart()
		_:
			return
	get_viewport().set_input_as_handled()


## Stop and give everything back. Idempotent.
func end() -> void:
	if not _running:
		return
	_running = false
	if _main != null and is_instance_valid(_main):
		if _main.has_method("pop_camera_claim"):
			_main.call("pop_camera_claim", OWNER)
		if _main.has_method("pop_clock_claim"):
			_main.call("pop_clock_claim", OWNER)
		if _sky != null:
			_sky.end(_main)
		if not is_nan(_prev_hours) and _main.has_method("set_absolute_hours"):
			_main.call("set_absolute_hours", _prev_hours)
	if is_instance_valid(_cam):
		_cam.queue_free()
	var cc := get_node_or_null("/root/CursorController")
	if cc != null:
		cc.call("release_modal", OWNER)
	HudLayout.release(OWNER)
	if is_instance_valid(_hud):
		_hud.queue_free()
	finished.emit()
	queue_free()


func _exit_tree() -> void:
	end()


func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = UITheme.LAYER_PANEL
	add_child(_hud)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.92))
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.position = Vector2(0, 16)
	_hud.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	panel.add_child(col)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)
	_label = Label.new()
	_label.add_theme_font_override("font", UITheme.font("regular", true))
	_label.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_label.add_theme_color_override("font_color", UITheme.C_TEXT)
	_label.custom_minimum_size = Vector2(430, 0)
	row.add_child(_label)
	_pause_btn = _btn(row, "Play" if _paused else "Pause", toggle_pause)
	_pause_btn.tooltip_text = "Space"
	var restart_btn := _btn(row, "Restart", restart)
	restart_btn.tooltip_text = "Home"
	_btn(row, "Stop (Esc)", end)
	_scrub = HSlider.new()
	_scrub.min_value = 0.0
	_scrub.max_value = maxf(ClimelapseExportOptions.video_seconds(_opts), 0.01)
	_scrub.step = 0.0
	_scrub.custom_minimum_size = Vector2(560, 18)
	_scrub.focus_mode = Control.FOCUS_NONE
	_scrub.tooltip_text = "Drag to scrub the video (← / → step a second)"
	_scrub.value_changed.connect(func(v: float) -> void:
		if not _scrub_sync:
			seek(v))
	col.add_child(_scrub)
	var info := Label.new()
	info.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	info.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	info.text = _camera_line()
	col.add_child(info)
	# Keep it centred as its width settles.
	panel.resized.connect(func() -> void:
		panel.position.x = (panel.get_viewport_rect().size.x - panel.size.x) * 0.5)


## What the camera does in this shot, one line.
func _camera_line() -> String:
	var bits: Array = []
	if _rig != null and _rig.has_keys():
		var n := _rig.keys.size()
		if n == 1:
			bits.append("Camera locked on 1 keyframe")
		elif _rig.key_timing == "spread":
			bits.append("Camera path: %s spread over the video" % UiText.count(n, "keyframe"))
		else:
			bits.append("Camera path: %s at their moments" % UiText.count(n, "keyframe"))
	else:
		bits.append("Camera still (no keyframes)")
	var fol := str(_opts.get("follow", "none"))
	if fol != "none":
		bits.append("following the %s" % fol)
	if _sky != null and _sky.analemma() > 0:
		bits.append("analemma")
	return "  ·  ".join(bits)


func _btn(row: HBoxContainer, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	row.add_child(b)
	return b
