extends CanvasLayer

## The in-game WORLD panel (timeline 💾) — replaces the eight anonymous save
## slots. A world is always live: what you build is written as you build it,
## and the snapshot (where you stand, what you look at, the clock, battery,
## the vehicle you ride, festival mode) is saved every 3 minutes, on Save now
## and when you exit. This panel says exactly what the world holds, so saving
## is something you can trust rather than guess at.

const REFRESH_S := 1.0

var _main: Node = null
var _root: Control = null
var _name_edit: LineEdit = null
var _sub_lbl: Label = null
var _holds: GridContainer = null
var _status: Label = null
var _copy_row: HBoxContainer = null
var _copy_name: LineEdit = null
var _adopt_btn: Button = null
var _world_btns: Array[Button] = []
var _accum := 0.0


func _ready() -> void:
	layer = UITheme.LAYER_MODAL
	var p := get_parent()
	_main = p.get_parent() if p != null else null
	_build()
	_root.visible = false


func is_panel_visible() -> bool:
	return _root != null and _root.visible


func show_panel() -> void:
	_root.visible = true
	_status.text = ""
	_copy_row.visible = false
	_refresh()
	CursorController.request_modal("world_panel", Callable(self, "hide_panel"))


func hide_panel() -> void:
	if _root == null or not _root.visible:
		return
	_commit_rename()
	_root.visible = false
	CursorController.release_modal("world_panel")


func _unhandled_input(event: InputEvent) -> void:
	if is_panel_visible() and event.is_action_pressed("ui_cancel"):
		hide_panel()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_panel_visible():
		return
	_accum += delta
	if _accum >= REFRESH_S:
		_accum = 0.0
		_refresh_holds()


# -- Build -------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	center.add_child(panel)
	var m := MarginContainer.new()
	for k in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		m.add_theme_constant_override(k, 16)
	panel.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	m.add_child(v)

	var hdr := Label.new()
	hdr.text = "WORLD"
	hdr.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hdr.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	v.add_child(hdr)
	_name_edit = LineEdit.new()
	_name_edit.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	_name_edit.tooltip_text = "Rename this world (empty = the location's name)."
	_name_edit.text_submitted.connect(func(_t: String) -> void: _commit_rename())
	_name_edit.focus_exited.connect(_commit_rename)
	v.add_child(_name_edit)
	_sub_lbl = Label.new()
	_sub_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sub_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_sub_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	v.add_child(_sub_lbl)

	var holds_hdr := Label.new()
	holds_hdr.text = "THIS WORLD HOLDS"
	holds_hdr.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	holds_hdr.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	v.add_child(holds_hdr)
	_holds = GridContainer.new()
	_holds.columns = 2
	_holds.add_theme_constant_override("h_separation", 18)
	_holds.add_theme_constant_override("v_separation", 3)
	v.add_child(_holds)
	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	note.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	note.text = ("Everything you build is written to this world as you build it. Where you stand, "
		+ "the clock, your battery and the people's state are saved every 3 minutes, on Save now, "
		+ "and when you exit — Play from the menu puts you back exactly here.")
	v.add_child(note)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 8)
	v.add_child(row1)
	_world_btns.clear()
	_world_btns.append(_btn(row1, "Save now", _on_save_now, "Write everything now."))
	_world_btns.append(_btn(row1, "Save a copy as…", _on_copy_pressed,
		"Freeze a checkpoint: an independent copy of this world. You keep playing this one."))
	_world_btns.append(_btn(row1, "New world on this map…", _on_new_world_pressed,
		"Save this world, then start a fresh, empty world on the same map."))
	_copy_row = HBoxContainer.new()
	_copy_row.add_theme_constant_override("separation", 8)
	_copy_row.visible = false
	v.add_child(_copy_row)
	_copy_name = LineEdit.new()
	_copy_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_copy_name.placeholder_text = "Name for the copy"
	_copy_name.text_submitted.connect(func(_t: String) -> void: _do_copy())
	_copy_row.add_child(_copy_name)
	_btn(_copy_row, "Make copy", _do_copy, "")
	_adopt_btn = Button.new()
	_adopt_btn.text = "Save this session as a world"
	_adopt_btn.tooltip_text = "This session was opened directly (not from a world). Make it one."
	UITheme.style_button(_adopt_btn)
	_adopt_btn.pressed.connect(_on_adopt_pressed)
	v.add_child(_adopt_btn)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	row2.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(row2)
	_world_btns.append(_btn(row2, "Exit to menu", _on_exit_pressed, "Save and return to your worlds."))
	_btn(row2, "Close", hide_panel, "")
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_status.add_theme_color_override("font_color", UITheme.C_OK)
	v.add_child(_status)


func _btn(parent: Control, text: String, cb: Callable, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	UITheme.style_button(b)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


# -- State ---------------------------------------------------------------------------

func _refresh() -> void:
	var has_world := WorldPaths.has_active_world()
	for b in _world_btns:
		b.disabled = not has_world
	_adopt_btn.visible = not has_world
	_name_edit.editable = has_world
	var rec := WorldSession.active_record()
	if not has_world or rec.is_empty():
		_name_edit.text = ""
		_name_edit.placeholder_text = "Not a saved world"
		_sub_lbl.text = "This session was opened directly, so it is not tied to a world yet."
	else:
		_name_edit.text = str(rec.get("name", ""))
		_name_edit.placeholder_text = WorldStore.display_name({"map": rec.get("map", {})})
		var bits: Array[String] = []
		var map: Dictionary = rec.get("map", {})
		bits.append(str(map.get("label", "")) if not str(map.get("label", "")).is_empty() \
			else WorldStore.display_name({"map": map}))
		var saved := float(rec.get("last_saved_unix", 0.0))
		if saved > 0.0:
			var dt := Time.get_datetime_dict_from_unix_time(int(saved + _utc_offset_s()))
			bits.append("last saved %02d:%02d" % [int(dt.hour), int(dt.minute)])
		else:
			bits.append("not saved yet")
		if str(rec.get("storage", "")) == WorldPaths.STORAGE_LEGACY:
			bits.append("original build")
		var others := WorldStore.worlds_on_map(rec).size() - 1
		if others > 0:
			bits.append("%d other world%s on this map" % [others, "" if others == 1 else "s"])
		_sub_lbl.text = "  ·  ".join(bits)
	_refresh_holds()


func _utc_offset_s() -> float:
	return float(Time.get_time_zone_from_system().get("bias", 0)) * 60.0


func _refresh_holds() -> void:
	for c in _holds.get_children():
		_holds.remove_child(c)
		c.queue_free()
	var sm := WorldSession.summary(_main)
	var rows: Array = []
	if _main != null:
		var y := int(_main.get("year")) if _main.get("year") != null else 0
		var mo := int(_main.get("month")) if _main.get("month") != null else 0
		var d := int(_main.get("day")) if _main.get("day") != null else 0
		var t := float(_main.get("day_time")) if _main.get("day_time") != null else 0.0
		rows.append(["Time", "%04d-%02d-%02d  %02d:%02d" % [y, mo, d, int(t), int(fmod(t, 1.0) * 60.0)]])
		var pl: Variant = _main.get("player")
		if pl != null and is_instance_valid(pl):
			var pos: Vector3 = (pl as Node3D).global_position
			var where := "%.0f, %.0f, %.0f" % [pos.x, pos.y, pos.z]
			if bool(pl.get("is_riding")):
				where += "  (riding)"
			rows.append(["You", where])
	rows.append(["Terrain edits", "%d tile%s" % [int(sm.get("edited_tiles", 0)), "" if int(sm.get("edited_tiles", 0)) == 1 else "s"]])
	rows.append(["Placed things", str(int(sm.get("props", 0)))])
	rows.append(["Lights", str(int(sm.get("lights", 0)))])
	rows.append(["Camps", str(int(sm.get("camps", 0)))])
	rows.append(["Systems graph", "%d nodes" % int(sm.get("graph_nodes", 0))])
	rows.append(["People", str(int(sm.get("people", 0)))])
	rows.append(["Peak experiences", str(int(sm.get("peak_total", 0)))])
	if _main != null and _main.has_method("festival_mode_active") and bool(_main.call("festival_mode_active")):
		rows.append(["Festival mode", "on"])
	for r in rows:
		var k := Label.new()
		k.text = str(r[0])
		k.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		k.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_holds.add_child(k)
		var val := Label.new()
		val.text = str(r[1])
		val.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		val.add_theme_color_override("font_color", UITheme.C_TEXT)
		_holds.add_child(val)


# -- Actions -------------------------------------------------------------------------

func _commit_rename() -> void:
	if _name_edit == null or not WorldPaths.has_active_world():
		return
	var rec := WorldSession.active_record()
	if rec.is_empty() or str(rec.get("name", "")) == _name_edit.text.strip_edges():
		return
	WorldStore.rename(WorldSession.active_id(), _name_edit.text)
	_status.text = "Renamed."


func _on_save_now() -> void:
	_commit_rename()
	var ok := WorldSession.save_now(_main, true, true)
	_status.text = "Saved — everything up to this moment is in the world." if ok \
		else "Save failed — check disk space."
	_refresh()


func _on_copy_pressed() -> void:
	_copy_row.visible = not _copy_row.visible
	if _copy_row.visible:
		var rec := WorldSession.active_record()
		_copy_name.text = "%s — %s" % [WorldStore.display_name(rec),
			Time.get_date_string_from_system()]
		_copy_name.grab_focus()
		_copy_name.select_all()


func _do_copy() -> void:
	var copy := WorldSession.save_copy(_main, _copy_name.text)
	_copy_row.visible = false
	_status.text = ("Copy saved as “%s”. You are still playing this world." % WorldStore.display_name(copy)) \
		if not copy.is_empty() else "Could not copy this world."
	_refresh()


func _on_new_world_pressed() -> void:
	var rec := WorldSession.active_record()
	if rec.is_empty():
		return
	WorldSession.save_now(_main, true, true)
	hide_panel()
	var fresh := WorldStore.create(rec.get("map", {}), "")
	WorldSession.launch(fresh, {})


func _on_exit_pressed() -> void:
	hide_panel()
	WorldSession.exit_to_menu(_main)


func _on_adopt_pressed() -> void:
	var rec := WorldSession.adopt_session(_main)
	_status.text = ("This session is now the world “%s”." % WorldStore.display_name(rec)) \
		if not rec.is_empty() else "Could not make a world from this session."
	_refresh()
