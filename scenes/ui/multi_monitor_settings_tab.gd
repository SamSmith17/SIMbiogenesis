extends VBoxContainer

## Settings → Multi-Monitor: configure secondary monitors (e.g. 5-monitor rigs
## with landscape, portrait, and touchscreen displays) to run independent
## dashboards, Systems Graph, Process Labs (Biochar Reactor), or 3D cameras
## simultaneously, with Window Wall nested as a collapsible sub-option.
##
## Instantiated by `timeline_settings_panel._build_multi_monitor_tab`.

const C_TEXT := UITheme.C_TEXT
const C_TEXT_S := UITheme.C_TEXT_S
const C_TEXT_M := UITheme.C_TEXT_M
const C_PRIMARY := UITheme.C_PRIMARY
const HDR_W := 160.0

const MAIN_MODE_LABELS := [
	"OS Fullscreen (default)",
	"Borderless Fullscreen (recommended for multi-monitor)",
	"Windowed (draggable)",
]
const FS_METHOD_LABELS := [
	"DWM-Safe Borderless (fixes grey multi-GPU screens)",
	"OS Native Fullscreen",
]
const ORIENT_LABELS := [
	"Auto (match screen)",
	"Portrait (1080×1920)",
	"Landscape (1920×1080)",
]
const UI_SCALE_PRESETS := [
	[0.0, "Auto"],
	[0.85, "85 %"],
	[1.0, "100 %"],
	[1.15, "115 %"],
	[1.25, "125 %"],
	[1.5, "150 %"],
]

var _panel: Control = null
var _rebuilding := false
var _map_canvas: MonitorMapCanvas = null
var _wall_sub_tab: Control = null


class MonitorMapCanvas extends Control:
	var screens: Array = []
	var slot_assignments: Dictionary = {}   # screen_index -> String summary

	func _init() -> void:
		custom_minimum_size = Vector2(0, 148)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(UITheme.C_BG, 0.88), true)
		draw_rect(r, Color(UITheme.C_BORDER, 0.65), false, 1.0)
		var f_semi := UITheme.font("semibold")
		var f_reg := UITheme.font("regular")
		if screens.is_empty():
			if f_reg != null:
				draw_string(f_reg, Vector2(16, size.y * 0.5 + 5.0),
					"No active OS screens reported (headless or single-window sandbox).",
					HORIZONTAL_ALIGNMENT_LEFT, size.x - 32.0, UITheme.FONT_SM, UITheme.C_TEXT_M)
			return
		var boxes := MultiMonitorDisplay.layout_diagram_rects(screens, size, 12.0)
		for b in boxes:
			var rect: Rect2 = b["rect"]
			var idx := int(b["index"])
			var is_prim := bool(b["is_primary"])
			var is_por := bool(b["is_portrait"])
			var assigned := str(slot_assignments.get(idx, "Main 3D" if is_prim else "Unassigned"))
			var has_role := is_prim or slot_assignments.has(idx)
			var fill := Color(UITheme.C_PRIMARY, 0.16) if is_prim \
				else (Color(UITheme.C_PANEL_RAISED, 0.96) if has_role else Color(UITheme.C_PANEL, 0.65))
			var border := UITheme.C_PRIMARY if is_prim \
				else (UITheme.C_GREEN if slot_assignments.has(idx) else UITheme.C_BORDER)
			draw_rect(rect, fill, true)
			draw_rect(rect, border, false, 2.0 if is_prim else 1.0)
			if f_semi != null and rect.size.x >= 38.0 and rect.size.y >= 26.0:
				var num_txt := "Screen %d%s" % [idx + 1, " (P)" if is_por else ""]
				draw_string(f_semi, rect.position + Vector2(6, 16), num_txt,
					HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10.0, UITheme.FONT_XS, UITheme.C_TEXT)
			if f_reg != null and rect.size.y >= 44.0:
				var res_txt := "%d×%d" % [int(b["w"]), int(b["h"])]
				draw_string(f_reg, rect.position + Vector2(6, 30), res_txt,
					HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10.0, 10, UITheme.C_TEXT_S)
			if f_reg != null and rect.size.y >= 60.0:
				draw_string(f_reg, rect.position + Vector2(6, rect.size.y - 8.0), assigned,
					HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10.0, 10,
					UITheme.C_PRIMARY if is_prim else (UITheme.C_GREEN if slot_assignments.has(idx) else UITheme.C_TEXT_M))


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


func _main() -> Node:
	if is_instance_valid(SimSettingsController):
		var m: Variant = SimSettingsController.get("main_node")
		if m is Node and is_instance_valid(m):
			return m
	var tree := get_tree()
	if tree != null and tree.current_scene != null and tree.current_scene.has_method("ensure_multi_monitor_host"):
		return tree.current_scene
	return null


func _host() -> MultiMonitorHost:
	var m := _main()
	if m != null and m.has_method("ensure_multi_monitor_host"):
		return m.call("ensure_multi_monitor_host") as MultiMonitorHost
	return null


# ---------------------------------------------------------------------------
# Build UI
# ---------------------------------------------------------------------------

func _build() -> void:
	MultiMonitorPrefs.ensure_loaded()
	WindowWallPrefs.ensure_loaded()
	add_theme_constant_override("separation", 10)

	var screens := MultiMonitorDisplay.os_screens()

	# --- 1. Header & Physical Monitor Diagram ---
	_section("Multi-Monitor Workspace")
	var en := _check("Enable Multi-Monitor support", MultiMonitorPrefs.enabled(), func(on: bool) -> void:
		MultiMonitorPrefs.set_value("enabled", on)
		MultiMonitorPrefs.save()
		call_deferred("refresh"))
	en.tooltip_text = "Allows secondary monitors (landscape, portrait, and touchscreens) to run simultaneous views and dashboards."

	var auto_row := HFlowContainer.new()
	auto_row.add_theme_constant_override("h_separation", 16)
	auto_row.add_theme_constant_override("v_separation", 4)
	add_child(auto_row)

	var c_auto_open := CheckBox.new()
	c_auto_open.text = "Auto-open monitors on world load"
	c_auto_open.button_pressed = MultiMonitorPrefs.auto_open_on_world_load()
	c_auto_open.toggled.connect(func(on: bool) -> void:
		MultiMonitorPrefs.set_value("auto_open_on_world_load", on)
		MultiMonitorPrefs.save())
	auto_row.add_child(c_auto_open)

	var c_auto_fs := CheckBox.new()
	c_auto_fs.text = "Restore fullscreen on saved monitors"
	c_auto_fs.tooltip_text = "New monitors launch draggable so you can move them onto the right screen and click Fullscreen; once placed, future sessions restore fullscreen automatically."
	c_auto_fs.button_pressed = MultiMonitorPrefs.auto_fullscreen_saved()
	c_auto_fs.toggled.connect(func(on: bool) -> void:
		MultiMonitorPrefs.set_value("auto_fullscreen_saved", on)
		MultiMonitorPrefs.save())
	auto_row.add_child(c_auto_fs)

	_hint("Launch extra windows, drag each one to the monitor you want (Touchscreen, Portrait, or Landscape), and click '⛶ Fullscreen' (or press F11). Each monitor remembers its screen and starting view.")

	_map_canvas = MonitorMapCanvas.new()
	_map_canvas.name = "MonitorMapCanvas"
	_populate_map_canvas(_map_canvas, screens)
	add_child(_map_canvas)

	var map_btns := HFlowContainer.new()
	map_btns.add_theme_constant_override("h_separation", 8)
	map_btns.add_theme_constant_override("v_separation", 6)
	add_child(map_btns)

	var id_btn := Button.new()
	id_btn.text = "Identify Screens"
	id_btn.tooltip_text = "Flash big screen numbers and resolutions on every connected monitor for 3 seconds."
	UITheme.style_button(id_btn)
	id_btn.pressed.connect(func() -> void: MultiMonitorHost.identify_screens(get_tree(), 3.0))
	map_btns.add_child(id_btn)

	var pop_btn := Button.new()
	pop_btn.text = "Auto-Add Secondary Screens"
	pop_btn.tooltip_text = "Create one monitor slot per secondary display (Portrait screens default to Biochar Reactor; Landscape screens default to Systems Graph & dashboards)."
	UITheme.style_button(pop_btn)
	pop_btn.disabled = screens.size() <= 1
	pop_btn.pressed.connect(func() -> void:
		var n := MultiMonitorPrefs.populate_from_detected_screens(MultiMonitorDisplay.os_screens())
		if n > 0:
			MultiMonitorPrefs.set_value("enabled", true)
			MultiMonitorPrefs.save()
			call_deferred("refresh"))
	map_btns.add_child(pop_btn)

	var ref_btn := Button.new()
	ref_btn.text = "Refresh Displays"
	UITheme.style_button(ref_btn)
	ref_btn.pressed.connect(func() -> void: call_deferred("refresh"))
	map_btns.add_child(ref_btn)

	# --- 2. Primary Window Controls ---
	add_child(HSeparator.new())
	_section("Main Game Window (3D Player View)")

	var cur_mm := maxi(MultiMonitorPrefs.MAIN_WINDOW_MODES.find(MultiMonitorPrefs.main_window_mode()), 0)
	_option("Main window mode", MAIN_MODE_LABELS, cur_mm, func(idx: int) -> void:
		MultiMonitorPrefs.set_value("main_window_mode", MultiMonitorPrefs.MAIN_WINDOW_MODES[clampi(idx, 0, 2)])
		MultiMonitorPrefs.save())

	var scr_items: Array[String] = ["OS Primary Monitor (Auto)"]
	for s in screens:
		var sd := s as Dictionary
		var tag := "Portrait" if bool(sd["is_portrait"]) else "Landscape"
		scr_items.append("Screen %d — %d×%d (%s)" % [int(sd["index"]) + 1, int(sd["w"]), int(sd["h"]), tag])
	var cur_main_scr := MultiMonitorDisplay.resolve_screen(
		MultiMonitorPrefs.main_screen_fingerprint(), MultiMonitorPrefs.main_screen(), screens)
	var sel_scr_opt := (cur_main_scr + 1) if (MultiMonitorPrefs.main_screen() >= 0 and cur_main_scr >= 0) else 0
	_option("Main monitor", scr_items, sel_scr_opt, func(idx: int) -> void:
		if idx <= 0:
			MultiMonitorPrefs.set_value("main_screen", -1)
			MultiMonitorPrefs.set_value("main_screen_fingerprint", "")
		else:
			var pick := screens[idx - 1] as Dictionary
			MultiMonitorPrefs.set_value("main_screen", int(pick["index"]))
			MultiMonitorPrefs.set_value("main_screen_fingerprint", MultiMonitorDisplay.fingerprint_of(pick))
		MultiMonitorPrefs.save()
		call_deferred("refresh"))

	var cur_fsm := maxi(MultiMonitorPrefs.FULLSCREEN_METHODS.find(MultiMonitorPrefs.fullscreen_method()), 0)
	_option("Extra-window fullscreen", FS_METHOD_LABELS, cur_fsm, func(idx: int) -> void:
		MultiMonitorPrefs.set_value("fullscreen_method", MultiMonitorPrefs.FULLSCREEN_METHODS[clampi(idx, 0, 1)])
		MultiMonitorPrefs.save())

	var apply_main_btn := Button.new()
	apply_main_btn.text = "Apply to Main Window Now"
	apply_main_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UITheme.style_button(apply_main_btn)
	apply_main_btn.pressed.connect(func() -> void:
		if not MultiMonitorPrefs.enabled():
			MultiMonitorPrefs.set_value("enabled", true)
			MultiMonitorPrefs.save()
		MultiMonitorHost.apply_main_window_prefs(get_tree()))
	add_child(apply_main_btn)

	# --- 3. Secondary Monitor Slots ---
	add_child(HSeparator.new())
	_section("Secondary Monitor Windows (%d / %d)" % [MultiMonitorPrefs.slot_count(), MultiMonitorPrefs.MAX_MONITORS])

	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 8)
	bar.add_theme_constant_override("v_separation", 6)
	add_child(bar)

	var add_btn := Button.new()
	add_btn.name = "AddMonitorSlotButton"
	add_btn.text = "+ Add Monitor Window"
	UITheme.style_primary_button(add_btn)
	add_btn.disabled = MultiMonitorPrefs.slot_count() >= MultiMonitorPrefs.MAX_MONITORS
	add_btn.pressed.connect(func() -> void:
		MultiMonitorPrefs.add_slot()
		if not MultiMonitorPrefs.enabled():
			MultiMonitorPrefs.set_value("enabled", true)
		MultiMonitorPrefs.save()
		call_deferred("refresh"))
	bar.add_child(add_btn)

	var host := _host()
	var in_world := _main() != null

	var launch_all := Button.new()
	launch_all.text = "Launch All Enabled"
	launch_all.disabled = (not in_world) or MultiMonitorPrefs.slot_count() == 0
	launch_all.tooltip_text = "Open a world first to launch live monitor views." if not in_world \
		else "Open all enabled secondary monitor windows now."
	UITheme.style_button(launch_all)
	launch_all.pressed.connect(func() -> void:
		if not MultiMonitorPrefs.enabled():
			MultiMonitorPrefs.set_value("enabled", true)
			MultiMonitorPrefs.save()
		var h := _host()
		if h != null:
			await h.open_all_enabled()
			call_deferred("refresh"))
	bar.add_child(launch_all)

	var gather_btn := Button.new()
	gather_btn.text = "Gather All to Windowed"
	gather_btn.tooltip_text = "Exit fullscreen on every secondary window and bring them onto your primary monitor as draggable windows."
	UITheme.style_button(gather_btn)
	gather_btn.pressed.connect(func() -> void:
		var h := _host()
		if h != null:
			h.gather_all_to_windowed()
		else:
			MultiMonitorPrefs.clear_all_fullscreen()
			MultiMonitorPrefs.save()
		call_deferred("refresh"))
	bar.add_child(gather_btn)

	var close_all_btn := Button.new()
	close_all_btn.text = "Close Extra Windows"
	close_all_btn.disabled = host == null or host.active_window_count() == 0
	UITheme.style_button(close_all_btn)
	close_all_btn.pressed.connect(func() -> void:
		var h := _host()
		if h != null:
			h.close_all()
			call_deferred("refresh"))
	bar.add_child(close_all_btn)

	if MultiMonitorPrefs.slot_count() == 0:
		_hint("No secondary monitor windows configured yet. Click '+ Add Monitor Window' (or 'Auto-Add Secondary Screens' above) to add views like Systems Graph on your Touchscreen or Biochar Reactor on your Portrait monitor.")
	else:
		var slots := MultiMonitorPrefs.slots()
		for i in slots.size():
			_build_slot_card(i, slots[i], screens, host, in_world)

	# --- 4. Collapsible Sub-Option: Window Wall (Panoramic 3D) ---
	add_child(HSeparator.new())
	var wall_sec := Collapsible.make(
		"Window Wall (Bezel-Aligned Panoramic 3D)",
		WindowWallPrefs.enabled(),
		"Sub-option: turn a physical row of monitors into one continuous off-axis frustum window out of the bus (F11)."
	)
	wall_sec.set_summary("Enabled (F11)" if WindowWallPrefs.enabled() else "Off — click to configure bezel-aligned row")
	add_child(wall_sec)
	var wall_scr := load("res://scenes/ui/window_wall_settings_tab.gd") as Script
	if wall_scr != null:
		_wall_sub_tab = VBoxContainer.new()
		_wall_sub_tab.set_script(wall_scr)
		_wall_sub_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		wall_sec.body.add_child(_wall_sub_tab)
		_wall_sub_tab.call("bind", _panel)
		_wall_sub_tab.call("refresh")

	UiFit.tame_widths(self, true)


func _populate_map_canvas(canvas: MonitorMapCanvas, screens: Array) -> void:
	canvas.screens = screens
	var map := {}
	var main_scr := MultiMonitorDisplay.resolve_screen(
		MultiMonitorPrefs.main_screen_fingerprint(), MultiMonitorPrefs.main_screen(), screens)
	if main_scr >= 0:
		map[main_scr] = "Main 3D"
	for sc in MultiMonitorPrefs.slots():
		if not bool(sc.get("enabled", true)):
			continue
		var matched := MultiMonitorDisplay.resolve_screen(
			str(sc.get("screen_fingerprint", "")), int(sc.get("screen_index", -1)), screens)
		if matched >= 0:
			var short_v := MultiMonitorCatalog.short_label_of(str(sc.get("starting_view", "")))
			map[matched] = "%s: %s" % [str(sc.get("label", "Mon")), short_v]
	canvas.slot_assignments = map
	canvas.queue_redraw()


func _build_slot_card(idx: int, sc: Dictionary, screens: Array, host: MultiMonitorHost, in_world: bool) -> void:
	var sid := str(sc.get("id", ""))
	var live_win: MonitorWindowHost = host.get_slot_window(sid) if host != null else null
	var is_open := live_win != null

	var card := PanelContainer.new()
	card.name = "MonitorCard_%s" % sid
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	add_child(card)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 8)
	card.add_child(vb)

	# Row 1: Enable + Nickname + Status + Live Window Buttons
	var r1 := HFlowContainer.new()
	r1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r1.add_theme_constant_override("h_separation", 8)
	r1.add_theme_constant_override("v_separation", 4)
	vb.add_child(r1)

	var en_chk := CheckBox.new()
	en_chk.button_pressed = bool(sc.get("enabled", true))
	en_chk.tooltip_text = "Include this monitor when launching workspace windows."
	en_chk.toggled.connect(func(on: bool) -> void:
		MultiMonitorPrefs.set_slot_value(idx, "enabled", on)
		MultiMonitorPrefs.save()
		_populate_map_canvas(_map_canvas, screens))
	r1.add_child(en_chk)

	var name_ed := LineEdit.new()
	name_ed.text = str(sc.get("label", "Monitor %d" % (idx + 2)))
	name_ed.placeholder_text = "Monitor nickname"
	name_ed.custom_minimum_size = Vector2(150, 0)
	name_ed.text_submitted.connect(func(t: String) -> void:
		MultiMonitorPrefs.set_slot_value(idx, "label", t)
		MultiMonitorPrefs.save()
		if live_win != null:
			live_win.refresh_from_prefs()
		_populate_map_canvas(_map_canvas, screens))
	name_ed.focus_exited.connect(func() -> void:
		MultiMonitorPrefs.set_slot_value(idx, "label", name_ed.text)
		MultiMonitorPrefs.save()
		if live_win != null:
			live_win.refresh_from_prefs()
		_populate_map_canvas(_map_canvas, screens))
	r1.add_child(name_ed)

	var status_lbl := Label.new()
	status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	var matched_scr := MultiMonitorDisplay.resolve_screen(
		str(sc.get("screen_fingerprint", "")), int(sc.get("screen_index", -1)), screens)
	if is_open:
		status_lbl.text = "● Open (%s)" % ("Fullscreen" if live_win.is_monitor_fullscreen else "Draggable Window")
		status_lbl.add_theme_color_override("font_color", UITheme.C_OK)
	elif bool(sc.get("placed", false)) and matched_scr >= 0:
		status_lbl.text = "Saved → Screen %d%s" % [matched_scr + 1, " (Fullscreen)" if bool(sc.get("is_fullscreen", false)) else " (Windowed)"]
		status_lbl.add_theme_color_override("font_color", C_TEXT_S)
	else:
		status_lbl.text = "Unplaced — launches draggable"
		status_lbl.add_theme_color_override("font_color", C_TEXT_M)
	r1.add_child(status_lbl)

	var open_btn := Button.new()
	open_btn.text = "Focus" if is_open else "Launch Window"
	open_btn.disabled = not in_world
	open_btn.tooltip_text = "Enter a world first to launch this monitor window." if not in_world \
		else "Open this window now so you can drag it to a monitor and make it fullscreen."
	UITheme.style_primary_button(open_btn) if not is_open else UITheme.style_button(open_btn)
	open_btn.pressed.connect(func() -> void:
		var h := _host()
		if h != null:
			h.open_slot(sid)
			call_deferred("refresh"))
	r1.add_child(open_btn)

	if is_open:
		var fs_btn := Button.new()
		fs_btn.text = "❐ Windowed" if live_win.is_monitor_fullscreen else "⛶ Fullscreen"
		UITheme.style_button(fs_btn)
		fs_btn.pressed.connect(func() -> void:
			if is_instance_valid(live_win):
				live_win.toggle_monitor_fullscreen()
				call_deferred("refresh"))
		r1.add_child(fs_btn)

		var cls_btn := Button.new()
		cls_btn.text = "Close"
		UITheme.style_button(cls_btn)
		cls_btn.pressed.connect(func() -> void:
			var h := _host()
			if h != null:
				h.close_slot(sid)
				call_deferred("refresh"))
		r1.add_child(cls_btn)

	var del_btn := Button.new()
	del_btn.text = "🗑"
	del_btn.tooltip_text = "Remove this monitor slot."
	UITheme.style_button(del_btn)
	del_btn.pressed.connect(func() -> void:
		var h := _host()
		if h != null and h.is_slot_open(sid):
			h.close_slot(sid)
		MultiMonitorPrefs.remove_slot(idx)
		MultiMonitorPrefs.save()
		call_deferred("refresh"))
	r1.add_child(del_btn)

	# Row 2: Default Starting View picker + blurb
	var r2 := HBoxContainer.new()
	r2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r2.add_theme_constant_override("separation", 8)
	vb.add_child(r2)

	var v_hdr := Label.new()
	v_hdr.text = "Starting view"
	v_hdr.custom_minimum_size = Vector2(105, 0)
	v_hdr.add_theme_color_override("font_color", C_TEXT_S)
	r2.add_child(v_hdr)

	var v_opt := OptionButton.new()
	v_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v_opt.fit_to_longest_item = false
	v_opt.clip_text = true
	var view_ids := PackedStringArray()
	var cur_vid := str(sc.get("starting_view", MultiMonitorCatalog.DEFAULT_VIEW))
	var sel_v_idx := 0
	for grp in MultiMonitorCatalog.GROUPS:
		v_opt.add_separator(grp)
		view_ids.append("")
		for entry in MultiMonitorCatalog.entries_in_group(grp):
			var eid := str(entry["id"])
			if eid == cur_vid:
				sel_v_idx = view_ids.size()
			view_ids.append(eid)
			v_opt.add_item(str(entry["label"]))
	v_opt.selected = sel_v_idx
	v_opt.item_selected.connect(func(pick_i: int) -> void:
		if pick_i >= 0 and pick_i < view_ids.size() and not view_ids[pick_i].is_empty():
			var nvid := view_ids[pick_i]
			MultiMonitorPrefs.set_slot_value(idx, "starting_view", nvid)
			MultiMonitorPrefs.save()
			if live_win != null and is_instance_valid(live_win):
				live_win.switch_view(nvid)
			call_deferred("refresh"))
	r2.add_child(v_opt)

	var cat_entry := MultiMonitorCatalog.entry(cur_vid)
	var blurb := Label.new()
	blurb.text = str(cat_entry.get("blurb", ""))
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_color_override("font_color", C_TEXT_M)
	blurb.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	vb.add_child(blurb)

	# Row 3: Touchscreen, Orientation, UI Scale, and View-specific knobs
	var r3 := HFlowContainer.new()
	r3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r3.add_theme_constant_override("h_separation", 12)
	r3.add_theme_constant_override("v_separation", 6)
	vb.add_child(r3)

	var touch_chk := CheckBox.new()
	touch_chk.text = "Touchscreen"
	touch_chk.tooltip_text = "Pins the top window control bar and enlarges buttons for finger taps."
	touch_chk.button_pressed = bool(sc.get("touchscreen", false))
	touch_chk.toggled.connect(func(on: bool) -> void:
		MultiMonitorPrefs.set_slot_value(idx, "touchscreen", on)
		MultiMonitorPrefs.save()
		if live_win != null and is_instance_valid(live_win):
			live_win.refresh_from_prefs())
	r3.add_child(touch_chk)

	var or_opt := _inline_option(r3, "Orientation", ORIENT_LABELS,
		clampi(int(sc.get("portrait_override", 0)), 0, 2),
		func(oi: int) -> void:
			MultiMonitorPrefs.set_slot_value(idx, "portrait_override", oi)
			MultiMonitorPrefs.save()
			if live_win != null and is_instance_valid(live_win):
				live_win.refresh_from_prefs())
	or_opt.custom_minimum_size = Vector2(155, 0)

	var uis_labels: Array[String] = []
	var cur_uis := float(sc.get("ui_scale", 0.0))
	var sel_uis := 0
	for pi in UI_SCALE_PRESETS.size():
		uis_labels.append(str(UI_SCALE_PRESETS[pi][1]))
		if absf(float(UI_SCALE_PRESETS[pi][0]) - cur_uis) < 0.04:
			sel_uis = pi
	var sc_opt := _inline_option(r3, "UI Scale", uis_labels, sel_uis, func(si: int) -> void:
		var val := float(UI_SCALE_PRESETS[clampi(si, 0, UI_SCALE_PRESETS.size() - 1)][0])
		MultiMonitorPrefs.set_slot_value(idx, "ui_scale", val)
		MultiMonitorPrefs.save()
		if live_win != null and is_instance_valid(live_win):
			live_win.refresh_from_prefs())
	sc_opt.custom_minimum_size = Vector2(90, 0)

	if cur_vid == MultiMonitorCatalog.VIEW_WINDOW_WALL_SLOT:
		var wall_items: Array[String] = []
		for wi in WindowWallLayout.MAX_SLOTS:
			wall_items.append("Wall Slot %d" % (wi + 1))
		var ws_opt := _inline_option(r3, "Wall Panel", wall_items,
			clampi(int(sc.get("wall_slot", 0)), 0, WindowWallLayout.MAX_SLOTS - 1),
			func(wi: int) -> void:
				MultiMonitorPrefs.set_slot_value(idx, "wall_slot", wi)
				MultiMonitorPrefs.save())
		ws_opt.custom_minimum_size = Vector2(115, 0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _section(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_override("font", UITheme.font("semibold"))
	lbl.add_theme_color_override("font_color", C_PRIMARY)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	add_child(lbl)


func _hint(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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


func _option(label: String, items: Array, selected_idx: int, cb: Callable) -> OptionButton:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	var hdr := Label.new()
	hdr.text = label
	hdr.custom_minimum_size = Vector2(HDR_W, 0)
	hdr.add_theme_color_override("font_color", C_TEXT_S)
	row.add_child(hdr)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.fit_to_longest_item = false
	opt.clip_text = true
	for i in items.size():
		opt.add_item(str(items[i]), i)
	opt.selected = clampi(selected_idx, 0, maxi(items.size() - 1, 0))
	opt.item_selected.connect(cb)
	row.add_child(opt)
	add_child(row)
	return opt


func _inline_option(parent: Control, label: String, items: Array, selected_idx: int, cb: Callable) -> OptionButton:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(lbl)
	var opt := OptionButton.new()
	opt.fit_to_longest_item = false
	opt.clip_text = true
	for i in items.size():
		opt.add_item(str(items[i]), i)
	opt.selected = clampi(selected_idx, 0, maxi(items.size() - 1, 0))
	opt.item_selected.connect(cb)
	box.add_child(opt)
	parent.add_child(box)
	return opt
