extends PanelContainer

## The video's CAMERA PATH editor: the keyframes drawn in the world as a path
## (ClimelapsePathView: the line the camera flies, view ticks along it, each
## key's frustum, number and time), with a gizmo on the selected key and its
## numbers in a right-edge dock.
##
##   the green ring (about up)        pans (compass heading)
##   the red ring (the camera's side) tilts
##   arrows / squares                 move the camera (in its own frame)
##   click a marker                   picks that keyframe
##   Look through                     sees the key's own view; drag to pan and
##                                    tilt, the wheel zooms (field of view)
##
## A right-edge dock in CursorController's tool-overlay tier, like the prop
## editor: the cursor is free, RMB looks, WASD walks, Esc steps out (a drag,
## then Look through, then the editor). Opened from the timeline (click a key
## on the CLIM lane, or its right-click menu) and from the export dialog.
## Every edit saves the world's keyframe file at once; Revert puts back the
## keys as they were when the editor opened.

const OVERLAY_NAME := "climelapse_path_editor"
const LOOK_OWNER := "climelapse_look_through"
const DOCK_W := 380.0
const SNAP_M := 0.25
const SNAP_DEG := 5.0
const LOOK_SENS := 0.0035   # radians per pixel dragged while looking through

var _loader: Node = null
var _main: Node = null
var _open := false
var _suspended := false     # a Preview is playing; the editor comes back after
var _opts: Dictionary = {}
var _sel := -1
var _keys0: ClimelapseKeyframes = null
var _list_sig := ""
var _syncing := false

var _view: ClimelapsePathView = null
var _gizmo: LightGizmo = null
var _dragging := false
var _drag := {}
var _look := false
var _look_cam: Camera3D = null
var _look_drag := false
var _look_last := Vector2.ZERO

var _sub_lbl: Label
var _list: ItemList
var _time_lbl: Label
var _pan_spin: SpinBox
var _tilt_spin: SpinBox
var _fov_spin: SpinBox
var _pos_spins: Array = []
var _look_btn: Button
var _myview_btn: Button
var _smooth_chk: CheckBox
var _path_lbl: Label
var _hint_lbl: Label
var _key_box: Control


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UITheme.panel_style(0.94))
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_left = -DOCK_W - 10.0
	offset_right = -10.0
	offset_top = 10.0
	offset_bottom = -(HudLayout.timeline_height() + 10.0)
	_build_ui()
	set_process(false)


func bind_loader(loader: Node) -> void:
	_loader = loader


func _resolve_main() -> void:
	if _main == null or not is_instance_valid(_main):
		_main = ServiceLocator.main()
		if _main == null and get_tree() != null:
			_main = get_tree().current_scene


func _keys() -> ClimelapseKeyframes:
	return _loader.call("climelapse_keys") if _loader != null else null


# --- open / close -------------------------------------------------------------

## `key_index` -1 = the key nearest the playhead. `opts`: the export's options
## (its Preview plays them); empty = the remembered ones over the keys' span.
func open(key_index: int = -1, opts: Dictionary = {}) -> bool:
	_resolve_main()
	if _loader == null or _main == null:
		return false
	var keys := _keys()
	if keys == null:
		return false
	if not opts.is_empty():
		_opts = opts.duplicate()
	if not _open:
		_keys0 = keys.duplicate_keys()
	_sel = key_index if key_index >= 0 and key_index < keys.size() else _nearest_to_playhead(keys)
	if not _open:
		_open = true
		_suspended = false
		visible = true
		move_to_front()
		set_process(true)
		CursorController.request_tool_overlay(OVERLAY_NAME, Callable(self, "_escape_step"))
		HudLayout.claim_right_dock("climelapse_path_editor", self, DOCK_W)
		_ensure_world_nodes()
	_list_sig = ""
	_refresh_list()
	_sync_fields()
	_hint("Drag the green ring to pan, the red ring to tilt, the arrows to move. Click a marker to pick a keyframe. Esc closes.")
	return true


func close() -> void:
	if not _open:
		return
	if _dragging:
		_end_drag(true)
	_set_look(false)
	_open = false
	_suspended = false
	visible = false
	set_process(false)
	HudLayout.release("climelapse_path_editor")
	CursorController.release_tool_overlay(OVERLAY_NAME)
	if is_instance_valid(_view):
		_view.visible = false
	if is_instance_valid(_gizmo):
		_gizmo.hide_gizmo()


func is_open() -> bool:
	return _open


func selected() -> int:
	return _sel


func _exit_mode() -> void:
	close()


func _exit_tree() -> void:
	if _open:
		close()
	for n in [_view, _gizmo, _look_cam]:
		if n != null and is_instance_valid(n):
			(n as Node).queue_free()


func _escape_step() -> void:
	if _dragging:
		_end_drag(false)
	elif _look:
		_set_look(false)
	else:
		close()


func _nearest_to_playhead(keys: ClimelapseKeyframes) -> int:
	if keys.is_empty():
		return -1
	var now := _now()
	var best := 0
	var best_d := INF
	var ts := keys.times()
	for i in ts.size():
		var d := absf(ts[i] - now)
		if d < best_d:
			best_d = d
			best = i
	return best


func _now() -> float:
	return float(_main.call("get_absolute_hours")) if _main != null and _main.has_method("get_absolute_hours") else 0.0


func _ensure_world_nodes() -> void:
	if not is_instance_valid(_view):
		_view = ClimelapsePathView.new()
		_view.name = "ClimelapsePathView"
		_main.add_child(_view)
	_view.visible = true
	if not is_instance_valid(_gizmo):
		_gizmo = LightGizmo.new()
		_gizmo.name = "ClimelapseKeyGizmo"
		_gizmo.world_space = false
		_gizmo.hidden = ["rz"]    # a video camera does not roll
		_main.add_child(_gizmo)


# --- UI -----------------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, UITheme.SPACE_SM)
	add_child(margin)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", UITheme.SPACE_SM)
	margin.add_child(outer)
	var head := DockShell.header("Camera path", "", close)
	outer.add_child(head["row"])
	_sub_lbl = head["subtitle"]
	_sub_lbl.visible = true

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UITheme.SPACE_SM)
	scroll.add_child(body)

	var keys_box := _section(body, "Keyframes", "route")
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 132)
	_list.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_list.item_selected.connect(func(i: int) -> void: _select(i))
	keys_box.add_child(_list)
	var nav := _row(keys_box)
	_button(nav, "◀ Previous", "The keyframe before", func() -> void: _select(_sel - 1))
	_button(nav, "Next ▶", "The keyframe after", func() -> void: _select(_sel + 1))

	var kb := _section(body, "This keyframe", "camera")
	_key_box = kb
	_time_lbl = _label(kb, "")
	var tr := _row(kb)
	_button(tr, "Move the playhead here", "Put the clock at this keyframe's moment", _on_jump)
	_look_btn = _button(tr, "Look through", "See this keyframe's own view. Drag to pan and tilt, the wheel zooms.", func() -> void: _set_look(not _look))
	_look_btn.toggle_mode = true
	var g := GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	g.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
	kb.add_child(g)
	_label(g, "Pan")
	_pan_spin = _spin(g, -720.0, 720.0, 0.5, "°", "Compass heading the camera faces: 0° north, 90° east")
	_label(g, "Tilt")
	_tilt_spin = _spin(g, -89.0, 89.0, 0.5, "°", "Up (+) or down (−) from level")
	_label(g, "Field of view")
	_fov_spin = _spin(g, ClimelapseKeyframes.MIN_FOV, ClimelapseKeyframes.MAX_FOV, 1.0, "°", "Vertical field of view: smaller zooms in")
	_label(g, "")
	_label(g, "")
	for ax in ["East", "Up", "South"]:
		_label(g, ax)
		_pos_spins.append(_spin(g, -1.0e6, 1.0e6, 0.1, " m", "Camera position in the world (metres)"))
	var ar := _row(kb)
	_myview_btn = _button(ar, "Set to my view", "Give this keyframe the view you are looking at now (keeps its time)", _on_set_my_view)
	_button(ar, "Delete", "Remove this keyframe", _on_delete)

	var pb := _section(body, "Path", "route")
	_smooth_chk = CheckBox.new()
	_smooth_chk.text = "Smooth path between keyframes"
	_smooth_chk.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_smooth_chk.toggled.connect(func(on: bool) -> void:
		if not _syncing and _loader != null:
			_loader.call("set_climelapse_keys_smooth", on))
	pb.add_child(_smooth_chk)
	_path_lbl = _label(pb, "")
	_path_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_hint_lbl = Label.new()
	_hint_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hint_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(_hint_lbl)
	var foot := _row(outer)
	_button(foot, "Preview", "Play the shot from this keyframe in the game window", _on_preview)
	_button(foot, "Revert", "Put the keyframes back as they were when the editor opened", _on_revert)
	_button(foot, "Done", "Close the editor (the changes are saved)", close)


func _section(parent: Control, title: String, icon: String) -> VBoxContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	parent.add_child(card)
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, UITheme.SPACE_SM)
	card.add_child(m)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	m.add_child(box)
	box.add_child(SectionHeader.make(title, icon))
	return box


func _row(parent: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", UITheme.SPACE_SM)
	parent.add_child(h)
	return h


func _label(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	parent.add_child(l)
	return l


func _button(parent: Control, text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(b)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _spin(parent: Control, lo: float, hi: float, step: float, suffix: String, tip: String) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = step
	sb.suffix = suffix
	sb.tooltip_text = tip
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.custom_minimum_size.x = 72.0
	sb.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	sb.get_line_edit().add_theme_font_size_override("font_size", UITheme.FONT_SM)
	sb.value_changed.connect(func(_v: float) -> void: _on_fields_changed())
	parent.add_child(sb)
	return sb


func _hint(text: String) -> void:
	if _hint_lbl != null:
		_hint_lbl.text = text


# --- list + fields --------------------------------------------------------------

func _clock() -> Object:
	return _main.get("clock") if _main != null else null


func _refresh_list() -> void:
	var keys := _keys()
	if keys == null:
		return
	var sig := "%d|%s" % [keys.size(), str(keys.times())]
	for i in keys.size():
		var k := keys.key(i)
		sig += "|%.2f,%.2f,%.1f" % [float(k.get("yaw", 0.0)), float(k.get("pitch", 0.0)), float(k.get("fov", 75.0))]
	if sig == _list_sig:
		return
	_list_sig = sig
	_list.clear()
	for i in keys.size():
		var k := keys.key(i)
		_list.add_item("%d   %s   pan %d°  tilt %d°" % [i + 1,
			ClimelapsePathView.time_label(_clock(), float(k.get("t", 0.0))),
			int(round(ClimelapseKeyframes.heading_deg(float(k.get("yaw", 0.0))))),
			int(round(rad_to_deg(float(k.get("pitch", 0.0)))))])
	_sel = clampi(_sel, -1, keys.size() - 1)
	if _sel >= 0:
		_list.select(_sel)
		_list.ensure_current_is_visible()
	_sub_lbl.text = UiText.count(keys.size(), "keyframe") if keys.size() > 0 \
		else "No keyframes: add them with 📍 on the timeline"
	var ts := keys.times()
	var length := 0.0
	var path := keys.sample_path(clampi(keys.size() * 32, 2, 600))
	for j in range(1, path.size()):
		length += ((path[j] as Dictionary)["pos"] as Vector3).distance_to((path[j - 1] as Dictionary)["pos"])
	_path_lbl.text = "" if ts.size() < 2 else "%s of camera travel over %s of sim time." % [
		UiText.num(length, "m"), UiText.duration(ts[ts.size() - 1] - ts[0])]
	_syncing = true
	_smooth_chk.button_pressed = keys.smooth
	_smooth_chk.disabled = keys.size() < 3
	_syncing = false


func _select(i: int) -> void:
	var keys := _keys()
	if keys == null or keys.is_empty():
		return
	if _dragging:
		_end_drag(true)
	_sel = clampi(i, 0, keys.size() - 1)
	_list.select(_sel)
	_list.ensure_current_is_visible()
	_sync_fields()


func _sync_fields() -> void:
	var keys := _keys()
	var has := keys != null and _sel >= 0 and _sel < keys.size()
	_key_box.get_parent().get_parent().visible = has
	if not has:
		return
	var k := keys.key(_sel)
	var p: Vector3 = ClimelapseKeyframes.key_transform(k).origin
	_syncing = true
	_time_lbl.text = "Keyframe %d of %d · %s" % [_sel + 1, keys.size(),
		ClimelapsePathView.time_label(_clock(), float(k.get("t", 0.0)))]
	_pan_spin.value = ClimelapseKeyframes.heading_deg(float(k.get("yaw", 0.0)))
	_tilt_spin.value = rad_to_deg(float(k.get("pitch", 0.0)))
	_fov_spin.value = float(k.get("fov", 75.0))
	(_pos_spins[0] as SpinBox).value = p.x
	(_pos_spins[1] as SpinBox).value = p.y
	(_pos_spins[2] as SpinBox).value = p.z
	_syncing = false


func _on_fields_changed() -> void:
	if _syncing or _sel < 0:
		return
	var pos := Vector3((_pos_spins[0] as SpinBox).value, (_pos_spins[1] as SpinBox).value, (_pos_spins[2] as SpinBox).value)
	_write(pos, ClimelapseKeyframes.yaw_for_heading(_pan_spin.value), deg_to_rad(_tilt_spin.value), _fov_spin.value, true)
	if _pan_spin.value < 0.0 or _pan_spin.value >= 360.0:
		_sync_fields()


func _write(pos: Vector3, yaw: float, pitch: float, fov: float, save: bool) -> void:
	if _loader == null or _sel < 0:
		return
	_loader.call("set_climelapse_key_pose", _sel, pos, yaw, pitch, fov, save)


func _key_pose() -> Dictionary:
	var keys := _keys()
	if keys == null or _sel < 0 or _sel >= keys.size():
		return {}
	var k := keys.key(_sel)
	return {"pos": ClimelapseKeyframes.key_transform(k).origin, "yaw": float(k.get("yaw", 0.0)),
		"pitch": float(k.get("pitch", 0.0)), "fov": float(k.get("fov", 75.0)), "t": float(k.get("t", 0.0))}


# --- buttons ------------------------------------------------------------------

func _on_jump() -> void:
	var kp := _key_pose()
	if kp.is_empty() or _main == null or not _main.has_method("set_absolute_hours"):
		return
	_main.call("set_absolute_hours", float(kp["t"]))


func _on_set_my_view() -> void:
	if _sel < 0 or _look or _loader == null:
		return
	_loader.call("repose_climelapse_key", _sel)
	_sync_fields()


func _on_delete() -> void:
	if _sel < 0 or _loader == null:
		return
	_set_look(false)
	_loader.call("remove_climelapse_key", _sel)
	var keys := _keys()
	_sel = mini(_sel, keys.size() - 1) if keys != null else -1
	_refresh_list()
	_sync_fields()


func _on_revert() -> void:
	if _keys0 == null or _loader == null:
		return
	if _dragging:
		_end_drag(false)
	_loader.call("restore_climelapse_keys", _keys0)
	_sel = clampi(_sel, -1, _keys0.size() - 1)
	_list_sig = ""
	_refresh_list()
	_sync_fields()
	_hint("Keyframes put back as they were when the editor opened.")


func _preview_opts() -> Dictionary:
	var o: Dictionary = _opts.duplicate() if not _opts.is_empty() else ClimelapseExportOptions.load_prefs()
	if _opts.is_empty():
		var ts := _keys().times()
		if ts.size() >= 2 and ts[ts.size() - 1] > ts[0]:
			o["start_abs"] = ts[0]
			o["end_abs"] = ts[ts.size() - 1]
		else:
			o["start_abs"] = _now()
			o["end_abs"] = _now() + 24.0
	return ClimelapseExportOptions.normalize(o)


func _on_preview() -> void:
	if _loader == null:
		return
	if _dragging:
		_end_drag(true)
	_set_look(false)
	var o := _preview_opts()
	var kp := _key_pose()
	var from := NAN
	if not kp.is_empty() and int(o.get("analemma", 0)) == 0:
		from = clampf(float(kp["t"]), float(o["start_abs"]), float(o["end_abs"]))
	if bool(_loader.call("start_climelapse_preview", o, from, false)):
		_suspended = true
		visible = false
		if is_instance_valid(_view):
			_view.visible = false
		if is_instance_valid(_gizmo):
			_gizmo.hide_gizmo()


# --- look through ---------------------------------------------------------------

func _set_look(on: bool) -> void:
	if on == _look:
		if _look_btn != null:
			_look_btn.set_pressed_no_signal(_look)
		return
	if on:
		if _sel < 0 or _main == null:
			_look_btn.set_pressed_no_signal(false)
			return
		if not is_instance_valid(_look_cam):
			_look_cam = Camera3D.new()
			_look_cam.name = "ClimelapseLookThroughCamera"
			_main.add_child(_look_cam)
		_place_look_cam()
		var ok := bool(_main.call("push_camera_claim", LOOK_OWNER,
			{"camera_id": _look_cam.get_instance_id(), "hide_player_mesh": false}, false)) \
			if _main.has_method("push_camera_claim") else false
		if not ok:
			_look_btn.set_pressed_no_signal(false)
			_hint("Something else is using the camera; try again when it is done.")
			return
		_look = true
		_hint("Looking through keyframe %d: drag to pan and tilt, the wheel zooms. Esc or Look through again to step back." % (_sel + 1))
	else:
		_look = false
		_look_drag = false
		if _main != null and is_instance_valid(_main) and _main.has_method("pop_camera_claim"):
			_main.call("pop_camera_claim", LOOK_OWNER)
		_hint("")
	_look_btn.set_pressed_no_signal(_look)
	_myview_btn.disabled = _look


func _place_look_cam() -> void:
	var kp := _key_pose()
	if kp.is_empty() or not is_instance_valid(_look_cam):
		return
	_look_cam.global_transform = Transform3D(Basis.from_euler(Vector3(float(kp["pitch"]), float(kp["yaw"]), 0.0)), kp["pos"])
	_look_cam.fov = float(kp["fov"])


# --- per frame ------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _open:
		return
	if _suspended:
		if _loader != null and not bool(_loader.call("is_climelapse_previewing")):
			_suspended = false
			visible = true
			if is_instance_valid(_view):
				_view.visible = true
		return
	var keys := _keys()
	if keys == null:
		return
	_refresh_list()
	if _sel >= keys.size():
		_sel = keys.size() - 1
		_sync_fields()
	var cam := get_viewport().get_camera_3d()
	if is_instance_valid(_view):
		_view.visible = not _look
		_view.selected = _sel
		var o := _opts if not _opts.is_empty() else {}
		var w := float(o.get("width", 16.0))
		var h := float(o.get("height", 9.0))
		_view.aspect = w / maxf(h, 1.0)
		var smp := keys.sample(_now())
		_view.now_pose = smp
		if not _look:
			_view.refresh(keys, cam, _clock())
	if _look:
		_place_look_cam()
		if is_instance_valid(_gizmo):
			_gizmo.hide_gizmo()
		return
	var kp := _key_pose()
	if kp.is_empty() or cam == null or not is_instance_valid(_gizmo):
		if is_instance_valid(_gizmo):
			_gizmo.hide_gizmo()
		return
	_gizmo.set_target(kp["pos"], Basis(Vector3.UP, float(kp["yaw"])), cam, {})


func _pointer_over_ui() -> bool:
	return visible and get_global_rect().has_point(get_viewport().get_mouse_position())


func _ray(mouse: Vector2) -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return {}
	return {"o": cam.project_ray_origin(mouse), "d": cam.project_ray_normal(mouse), "cam": cam}


func _unhandled_input(event: InputEvent) -> void:
	if not _open or _suspended:
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var k := event as InputEventKey
		if k.physical_keycode == KEY_DELETE and _sel >= 0:
			_on_delete()
			get_viewport().set_input_as_handled()
		return
	if _look:
		_look_input(event)
		return
	if event is InputEventMouseMotion:
		var pos := (event as InputEventMouseMotion).position
		if _dragging:
			var r := _ray(pos)
			if not r.is_empty():
				_update_drag(r)
			get_viewport().set_input_as_handled()
		elif is_instance_valid(_gizmo) and not _pointer_over_ui() and not CursorController.overlay_look_active():
			var r2 := _ray(pos)
			if not r2.is_empty():
				_gizmo.set_hot(_gizmo.pick(r2["o"], r2["d"]))
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if _pointer_over_ui() or CursorController.overlay_look_active():
				return
			var r := _ray(mb.position)
			if r.is_empty():
				return
			var handle := _gizmo.pick(r["o"], r["d"]) if is_instance_valid(_gizmo) else ""
			if not handle.is_empty():
				_begin_drag(handle, r)
				get_viewport().set_input_as_handled()
				return
			var hit := ClimelapsePathView.pick_key(_keys(), r["cam"] as Camera3D, mb.position)
			if hit >= 0:
				_select(hit)
				get_viewport().set_input_as_handled()
		elif _dragging:
			_end_drag(true)
			get_viewport().set_input_as_handled()


func _look_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and not _pointer_over_ui():
				_look_drag = true
				_look_last = mb.position
				get_viewport().set_input_as_handled()
			elif not mb.pressed and _look_drag:
				_look_drag = false
				var kp := _key_pose()
				if not kp.is_empty():
					_write(kp["pos"], kp["yaw"], kp["pitch"], kp["fov"], true)
				get_viewport().set_input_as_handled()
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN) \
				and not _pointer_over_ui():
			var kp2 := _key_pose()
			if not kp2.is_empty():
				var f := float(kp2["fov"]) + (-2.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 2.0)
				_write(kp2["pos"], kp2["yaw"], kp2["pitch"], f, true)
				_sync_fields()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _look_drag:
		# From positions, not `relative`: a warped or pushed motion carries a
		# relative that does not match where the pointer went.
		var mpos := (event as InputEventMouseMotion).position
		var rel := mpos - _look_last
		_look_last = mpos
		var kp := _key_pose()
		if kp.is_empty():
			return
		# Dragging moves the view the way the hand moves the camera: right
		# turns right, up tilts up.
		_write(kp["pos"], float(kp["yaw"]) - rel.x * LOOK_SENS, float(kp["pitch"]) - rel.y * LOOK_SENS, kp["fov"], false)
		_sync_fields()
		get_viewport().set_input_as_handled()


# --- gizmo drags ----------------------------------------------------------------

func _begin_drag(handle: String, r: Dictionary) -> void:
	var kp := _key_pose()
	if kp.is_empty():
		return
	_dragging = true
	var o := _gizmo.global_position
	_drag = {"handle": handle, "origin": o, "kp0": kp}
	if handle.begins_with("r"):
		var n := _gizmo.axis(handle)
		var hit: Variant = LightGizmoMath.ray_plane(r["o"], r["d"], o, n)
		_drag["axis"] = n
		_drag["ref"] = ((hit as Vector3) - o) if hit != null else n.cross(Vector3.UP + Vector3(0.01, 0, 0))
	elif handle.length() == 1:
		var ax := _gizmo.axis(handle)
		_drag["axis"] = ax
		_drag["s0"] = LightGizmoMath.axis_param(r["o"], r["d"], o, ax)
	else:
		var n2 := _gizmo.plane_normal(handle)
		_drag["normal"] = n2
		_drag["hit0"] = LightGizmoMath.ray_plane(r["o"], r["d"], o, n2)
	_gizmo.set_hot(handle)


func _update_drag(r: Dictionary) -> void:
	var handle := str(_drag["handle"])
	var o: Vector3 = _drag["origin"]
	var kp0: Dictionary = _drag["kp0"]
	var snap := Input.is_key_pressed(KEY_SHIFT)
	var pos: Vector3 = kp0["pos"]
	var yaw := float(kp0["yaw"])
	var pitch := float(kp0["pitch"])
	if handle.begins_with("r"):
		var n: Vector3 = _drag["axis"]
		var hit: Variant = LightGizmoMath.ray_plane(r["o"], r["d"], o, n)
		if hit == null:
			return
		var ang := LightGizmoMath.ring_angle(hit, o, n, _drag["ref"])
		if snap:
			ang = deg_to_rad(LightGizmoMath.snap(rad_to_deg(ang), SNAP_DEG))
		if handle == "ry":
			yaw += ang
			_hint("Pan %+.1f° → heading %.1f°  (Shift snaps to %d°)" % [-rad_to_deg(ang),
				ClimelapseKeyframes.heading_deg(yaw), int(SNAP_DEG)])
		else:
			pitch = clampf(pitch + ang, -ClimelapseKeyframes.MAX_PITCH, ClimelapseKeyframes.MAX_PITCH)
			_hint("Tilt %.1f°  (Shift snaps to %d°)" % [rad_to_deg(pitch), int(SNAP_DEG)])
	elif handle.length() == 1:
		var s := LightGizmoMath.axis_param(r["o"], r["d"], o, _drag["axis"])
		if is_nan(s) or is_nan(float(_drag["s0"])):
			return
		var d := s - float(_drag["s0"])
		if snap:
			d = LightGizmoMath.snap(d, SNAP_M)
		pos += (_drag["axis"] as Vector3) * d
		_hint("Move %.2f m  (Shift snaps to %.2f m)" % [absf(d), SNAP_M])
	else:
		var hit2: Variant = LightGizmoMath.ray_plane(r["o"], r["d"], o, _drag["normal"])
		if hit2 == null or _drag["hit0"] == null:
			return
		var delta := (hit2 as Vector3) - (_drag["hit0"] as Vector3)
		if snap:
			delta = LightGizmoMath.snap_vec(delta, SNAP_M)
		pos += delta
		_hint("Move %.2f m  (Shift snaps to %.2f m)" % [delta.length(), SNAP_M])
	_write(pos, yaw, pitch, float(kp0["fov"]), false)
	_sync_fields()


func _end_drag(commit: bool) -> void:
	if not _dragging:
		return
	_dragging = false
	if is_instance_valid(_gizmo):
		_gizmo.set_hot("")
	var kp0: Dictionary = _drag.get("kp0", {})
	if commit:
		var kp := _key_pose()
		if not kp.is_empty():
			_write(kp["pos"], kp["yaw"], kp["pitch"], kp["fov"], true)
	elif not kp0.is_empty():
		_write(kp0["pos"], kp0["yaw"], kp0["pitch"], kp0["fov"], true)
	_drag = {}
	_sync_fields()


## Harness hooks.
func gizmo() -> LightGizmo:
	return _gizmo


func path_view() -> ClimelapsePathView:
	return _view


func is_looking_through() -> bool:
	return _look


func set_look_through(on: bool) -> void:
	_set_look(on)
