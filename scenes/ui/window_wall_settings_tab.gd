extends VBoxContainer

## Settings → Window Wall: the physical layout of the monitor row, which OS
## screen each takes, the clock and UI behaviour while the view is open, and the
## per-map viewpoint. Instantiated by timeline_settings_panel._build_window_wall_tab
## into one of its tabs; kept as its own script so the 2.5k-line panel does
## not grow another 300 lines, and so ui_compile_selftest sweeps it.
##
## Every control writes straight to WindowWallPrefs (+ save()); `refresh()`
## rebuilds the whole tab from the prefs, which is also how the slot rows follow
## the monitor count.

const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S
const C_PRIMARY := UITheme.C_PRIMARY
const HDR_W := 130
const CLOCK_LABELS := ["Live wall clock (default)", "1× from current sim time", "Leave the clock as is"]
const MSAA_LABELS := ["Same as main window", "Off", "2×", "4×", "8×"]
const WINDOW_MODE_LABELS := ["Fullscreen (default)", "Borderless window (fixes a grey monitor)"]

var _panel: Control = null
var _rebuilding := false
var _layout_lbl: Label = null
var _viewpoint_lbl: Label = null
var _enter_btn: Button = null


func bind(panel: Control) -> void:
	_panel = panel


func refresh() -> void:
	if _rebuilding:
		return
	_rebuilding = true
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_build()
	_rebuilding = false


## The running world's Main, or null at the launch hub (the hub scene is a
## Control with no player and no window-wall view; treating it as Main would
## save a "viewpoint" for the menu).
func _main() -> Node:
	if is_instance_valid(SimSettingsController):
		var m: Variant = SimSettingsController.get("main_node")
		if m is Node:
			return m
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("open_window_wall_view"):
		return scene
	return null


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build() -> void:
	WindowWallPrefs.ensure_loaded()
	add_theme_constant_override("separation", 8)

	_section("Window wall")
	var en := _check("Enable window wall mode (F11)", WindowWallPrefs.enabled(), func(on: bool) -> void:
		_write("enabled", on)
		# The Enter button follows the switch live; it used to stay greyed
		# out until the panel was closed and reopened.
		if _enter_btn != null and is_instance_valid(_enter_btn):
			_enter_btn.disabled = (not on) or _main() == null)
	en.tooltip_text = "Off by default. When on, F11 or the button below renders the world across your monitor row."
	_hint("Renders the world across a row of physical monitors so they read as windows out of the bus: ONE eye point, one off-axis frustum per monitor, straight lines stay straight across the bezels. The game window itself becomes one of the monitors; the others open as extra fullscreen windows.")

	add_child(HSeparator.new())
	_section("Geometry")
	_slider("Monitors", 1, WindowWallPrefs.MAX_SLOTS, 1, float(WindowWallPrefs.monitor_count()), func(v: float) -> void:
		_write("monitor_count", int(v))
		call_deferred("refresh"))
	_slider("Gap (in)", 0.0, 12.0, 0.125, float(WindowWallPrefs.get_value("gap_m")) / WindowWallLayout.INCH_M, func(v: float) -> void:
		_write("gap_m", v * WindowWallLayout.INCH_M)
		_update_layout_readout())
	_slider("Eye distance (m)", 0.3, 3.0, 0.01, float(WindowWallPrefs.get_value("eye_distance_m")), func(v: float) -> void:
		_write("eye_distance_m", v)
		_update_layout_readout())
	_slider("Eye above row centre (m)", -0.5, 0.5, 0.01, float(WindowWallPrefs.get_value("eye_height_offset_m")), func(v: float) -> void:
		_write("eye_height_offset_m", v))
	_slider("Seat eye height (m)", 0.6, 2.0, 0.01, WindowWallPrefs.seat_eye_height_m(), func(v: float) -> void:
		_write("seat_eye_height_m", v))
	_hint("Gap is bezel edge to bezel edge. Eye distance is from your eye to the monitor glass, straight ahead. 'Seat eye height' is how far your eye sits above the saved viewpoint's ground point.")
	var main_items: Array = []
	for i in WindowWallPrefs.monitor_count():
		main_items.append("Slot %d%s" % [i + 1, "  (centre)" if i == WindowWallPrefs.monitor_count() / 2 else ""])
	_option("Game window slot", main_items, WindowWallPrefs.main_slot(), func(idx: int) -> void:
		_write("main_slot", idx))
	_layout_lbl = _hint("")
	_update_layout_readout()

	add_child(HSeparator.new())
	_section("Monitors (left to right)")
	for i in WindowWallPrefs.monitor_count():
		_slot_rows(i)

	add_child(HSeparator.new())
	_section("Screens")
	var screens := WindowWallView.os_screens()
	var lines: Array[String] = []
	for s in screens:
		lines.append("Screen %d: %d×%d at (%d, %d)" % [int(s["index"]), int(s["w"]), int(s["h"]), int(s["x"]), int(s["y"])])
	_hint("Detected: " + (", ".join(lines) if not lines.is_empty() else "none"))
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var auto_btn := Button.new()
	auto_btn.text = "Auto-arrange by screen X"
	auto_btn.tooltip_text = "Assign slots to screens left to right by each screen's position in Windows display settings."
	UITheme.style_button(auto_btn)
	auto_btn.pressed.connect(func() -> void:
		WindowWallPrefs.auto_arrange_by_x(WindowWallView.os_screens())
		WindowWallPrefs.save()
		call_deferred("refresh"))
	btn_row.add_child(auto_btn)
	var id_btn := Button.new()
	id_btn.text = "Identify screens"
	id_btn.tooltip_text = "Flash each OS screen's number and the slot it will take, for 3 seconds."
	UITheme.style_button(id_btn)
	id_btn.pressed.connect(func() -> void:
		WindowWallView.identify_screens(get_tree(), 3.0))
	btn_row.add_child(id_btn)
	add_child(btn_row)

	add_child(HSeparator.new())
	_section("While the window view is open")
	_option("Clock", CLOCK_LABELS, maxi(WindowWallPrefs.CLOCK_MODES.find(WindowWallPrefs.clock_mode()), 0), func(idx: int) -> void:
		_write("clock_mode", str(WindowWallPrefs.CLOCK_MODES[clampi(idx, 0, 2)])))
	_hint("Live: the sim date and time follow your PC clock at 1× (the sun outside matches the real time of day). 1×: real-time from wherever the sim is. Both restore the previous speed on exit.")
	_check("Hide all UI on entry (U toggles)", WindowWallPrefs.hide_ui(), func(on: bool) -> void:
		_write("hide_ui", on))
	_slider("Render scale", 0.5, 1.0, 0.05, WindowWallPrefs.render_scale(), func(v: float) -> void:
		_write("render_scale", v))
	_option("MSAA", MSAA_LABELS, int(WindowWallPrefs.get_value("msaa")) + 1, func(idx: int) -> void:
		_write("msaa", idx - 1))
	_option("Extra monitors", WINDOW_MODE_LABELS, maxi(WindowWallPrefs.WINDOW_MODES.find(WindowWallPrefs.extra_window_mode()), 0), func(idx: int) -> void:
		_write("extra_window_mode", str(WindowWallPrefs.WINDOW_MODES[clampi(idx, 0, 1)])))
	_hint("If a monitor goes flat grey when you enter the view, switch this to Borderless window. That monitor is rendering fine but refusing to present a fullscreen window, which happens when it is driven by a different graphics adapter than the main game window.")
	_slider("Nudge speed (m/s)", 0.05, 2.0, 0.05, WindowWallPrefs.nudge_speed_mps(), func(v: float) -> void:
		_write("nudge_speed_mps", v))
	_hint("Three 1080p monitors are three full renders of the world (plus shadows). Drop the render scale before dropping the graphics quality — vegetation and prop detail follow the game window's camera, which shares the same eye.")

	add_child(HSeparator.new())
	_section("Viewpoint (this map)")
	_viewpoint_lbl = _hint("")
	_update_viewpoint_readout()
	var vp_row := HBoxContainer.new()
	vp_row.add_theme_constant_override("separation", 8)
	var set_btn := Button.new()
	set_btn.text = "Set viewpoint from current player position"
	set_btn.tooltip_text = "Where you stand and face right now becomes the bus's parking spot for this map."
	UITheme.style_button(set_btn)
	set_btn.pressed.connect(_on_set_viewpoint)
	if _main() == null:
		set_btn.disabled = true
		set_btn.tooltip_text = "Open a world first: the viewpoint is where the player stands in it."
	vp_row.add_child(set_btn)
	var clr_btn := Button.new()
	clr_btn.text = "Clear"
	UITheme.style_button(clr_btn)
	clr_btn.pressed.connect(func() -> void:
		WindowWallViewpoint.delete_for(_main())
		_update_viewpoint_readout())
	vp_row.add_child(clr_btn)
	add_child(vp_row)
	_hint("In the view: WASD / Q E nudge the eye, ← → turn, drag with the mouse to turn, R resets to the saved spot, Ctrl+S saves, I identifies screens, U toggles the UI, Esc or F11 leaves.")

	add_child(HSeparator.new())
	var enter := Button.new()
	enter.text = "Enter window view"
	enter.custom_minimum_size = Vector2(0, 34)
	UITheme.style_button(enter)
	enter.disabled = not WindowWallPrefs.enabled()
	enter.tooltip_text = "Tick 'Enable window wall mode' above first." if enter.disabled else "Close settings and open the view (F11 does the same)."
	if _main() == null:
		enter.disabled = true
		enter.tooltip_text = "Open a world first; F11 there opens the view."
	enter.pressed.connect(_on_enter)
	add_child(enter)
	_enter_btn = enter


func _slot_rows(i: int) -> void:
	var sc := WindowWallPrefs.slot(i)
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 6)
	var hdr := Label.new()
	hdr.text = "Slot %d" % (i + 1)
	hdr.custom_minimum_size = Vector2(60, 0)
	hdr.add_theme_color_override("font_color", C_PRIMARY)
	r1.add_child(hdr)
	_spin(r1, "Diag \"", 10.0, 100.0, 0.5, float(sc["diag_in"]), func(v: float) -> void:
		_write_slot(i, "diag_in", v))
	_spin(r1, "W m", 0.0, 5.0, 0.001, float(sc["width_m"]), func(v: float) -> void:
		_write_slot(i, "width_m", v))
	_spin(r1, "H m", 0.0, 5.0, 0.001, float(sc["height_m"]), func(v: float) -> void:
		_write_slot(i, "height_m", v))
	var por := CheckBox.new()
	por.text = "Portrait"
	por.button_pressed = bool(sc["portrait"])
	por.add_theme_color_override("font_color", C_TEXT)
	por.toggled.connect(func(on: bool) -> void: _write_slot(i, "portrait", on))
	r1.add_child(por)
	add_child(r1)
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 6)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(60, 0)
	r2.add_child(pad)
	_spin(r2, "Yaw °", -80.0, 80.0, 0.5, float(sc["yaw_deg"]), func(v: float) -> void:
		_write_slot(i, "yaw_deg", v))
	_spin(r2, "Pitch °", -45.0, 45.0, 0.5, float(sc["pitch_deg"]), func(v: float) -> void:
		_write_slot(i, "pitch_deg", v))
	var scr_lbl := Label.new()
	scr_lbl.text = "Screen"
	scr_lbl.add_theme_color_override("font_color", C_TEXT_S)
	r2.add_child(scr_lbl)
	var scr := OptionButton.new()
	scr.add_item("Auto", 0)
	var screens := WindowWallView.os_screens()
	for s in screens:
		scr.add_item("Screen %d (%d×%d at %d,%d)" % [int(s["index"]), int(s["w"]), int(s["h"]), int(s["x"]), int(s["y"])], int(s["index"]) + 1)
	var cur := int(sc["screen"])
	scr.selected = clampi(cur + 1, 0, screens.size())
	scr.item_selected.connect(func(idx: int) -> void: _write_slot(i, "screen", idx - 1))
	r2.add_child(scr)
	add_child(r2)


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

func _write(key: String, v: Variant) -> void:
	WindowWallPrefs.set_value(key, v)
	WindowWallPrefs.save()


func _write_slot(i: int, key: String, v: Variant) -> void:
	WindowWallPrefs.set_slot_value(i, key, v)
	WindowWallPrefs.save()
	_update_layout_readout()


func _update_layout_readout() -> void:
	if _layout_lbl == null or not is_instance_valid(_layout_lbl):
		return
	var slots := WindowWallLayout.build_slots(WindowWallPrefs.snapshot())
	if slots.is_empty():
		_layout_lbl.text = ""
		return
	var first: Dictionary = slots[0]
	var last: Dictionary = slots[slots.size() - 1]
	var span := (float((last["centre"] as Vector3).x) + float(last["w_m"]) * 0.5) - (float((first["centre"] as Vector3).x) - float(first["w_m"]) * 0.5)
	var d := float(WindowWallPrefs.get_value("eye_distance_m"))
	var wall_fov := rad_to_deg(2.0 * atan(span * 0.5 / d))
	var per := ""
	for s in slots:
		var f := WindowWallLayout.frustum_for(s, 0.05)
		per += ("%.0f°" % WindowWallLayout.slot_hfov_deg(f)) if not f.is_empty() else "n/a"
		if int(s["index"]) < slots.size() - 1:
			per += " / "
	_layout_lbl.text = "Row spans %.2f m; whole wall covers %.0f° horizontally; per monitor %s." % [span, wall_fov, per]


func _update_viewpoint_readout() -> void:
	if _viewpoint_lbl == null or not is_instance_valid(_viewpoint_lbl):
		return
	var vp := WindowWallViewpoint.load_for(_main())
	if vp == null:
		_viewpoint_lbl.text = "No viewpoint saved for this map — the view will open where the player stands."
	else:
		_viewpoint_lbl.text = "Saved: %s%s" % [vp.describe(), ("  (" + vp.saved_at + ")") if not vp.saved_at.is_empty() else ""]


func _on_set_viewpoint() -> void:
	var main := _main()
	if main == null:
		return
	var player := main.get_node_or_null("Player") as Node3D
	if player == null:
		return
	var vp := WindowWallViewpoint.new()
	vp.pos = player.global_position
	vp.yaw_deg = rad_to_deg(player.rotation.y)
	vp.saved_at = Time.get_datetime_string_from_system()
	vp.save_to(WindowWallViewpoint.path_for(main))
	_update_viewpoint_readout()


func _on_enter() -> void:
	var main := _main()
	if main == null or not main.has_method("open_window_wall_view"):
		return
	# The panel holds the "timeline_settings" modal; it must go first.
	if _panel != null and is_instance_valid(_panel) and _panel.has_method("close"):
		_panel.call("close")
	main.call_deferred("open_window_wall_view")


# ---------------------------------------------------------------------------
# Row helpers (same look as the panel's own)
# ---------------------------------------------------------------------------

func _section(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", C_PRIMARY)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	add_child(lbl)


func _hint(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(420, 0)
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	add_child(lbl)
	return lbl


func _check(text: String, on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.add_theme_color_override("font_color", C_TEXT)
	c.toggled.connect(cb)
	add_child(c)
	return c


func _slider(label: String, min_v: float, max_v: float, step: float, value: float, cb: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var hdr := Label.new()
	hdr.text = label
	hdr.custom_minimum_size = Vector2(HDR_W, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var sl := HSlider.new()
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step = step
	sl.value = value
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spin := SpinBox.new()
	spin.custom_minimum_size = Vector2(76, 0)
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.value = value
	spin.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sl.value_changed.connect(func(v: float) -> void:
		if spin.value != v:
			spin.value = v
		cb.call(v))
	spin.value_changed.connect(func(v: float) -> void:
		if sl.value != v:
			sl.value = v)
	row.add_child(sl)
	row.add_child(spin)
	add_child(row)
	return sl


func _spin(parent: Control, label: String, min_v: float, max_v: float, step: float, value: float, cb: Callable) -> SpinBox:
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	parent.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.value = value
	spin.custom_minimum_size = Vector2(84, 0)
	spin.value_changed.connect(cb)
	parent.add_child(spin)
	return spin


func _option(label: String, items: Array, selected: int, cb: Callable) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var hdr := Label.new()
	hdr.text = label
	hdr.custom_minimum_size = Vector2(HDR_W, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in items.size():
		opt.add_item(str(items[i]), i)
	opt.selected = clampi(selected, 0, maxi(items.size() - 1, 0))
	opt.item_selected.connect(cb)
	row.add_child(opt)
	add_child(row)
	return opt
