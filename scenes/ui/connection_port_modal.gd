extends Control

## Connection Port modal — bind graph 2D handles to 3D mesh plug points.
## - Sidebar lists the node's 2D ports (in/out · type · name) as circular chips.
## - Select a 2D port then LMB the mesh, OR drag a chip onto the 3D preview.
## - RMB+drag orbits, scroll zooms. No free-form naming — labels come from 2D.

signal ports_saved(model_id: String, prop_id: String)

const MODAL_NAME := "connection_ports"
const ORBIT_SENS := 0.005
const ZOOM_MIN := 0.4
const ZOOM_MAX := 12.0
const DRAG_THRESH_PX := 5.0

const PORT_COLORS := {
	"positive": Color(0.847, 0.329, 0.329, 1.0),
	"negative": Color(0.333, 0.333, 0.333, 1.0),
	"ac": Color(0.941, 0.678, 0.306, 1.0),
	"ac_240": Color(1.000, 0.420, 0.420, 1.0),
	"load": Color(0.941, 0.820, 0.282, 1.0),
	"parallel": Color(0.231, 0.510, 0.965, 1.0),
	"smart_battery": Color(0.063, 0.722, 0.506, 1.0),
	"resource": Color(0.580, 0.639, 0.722, 1.0),
	"pv": Color(0.961, 0.620, 0.043, 1.0),
}

var _model_id: String = ""
var _item_id: String = ""
var _prop_id: String = ""
## Array of {id, polarity, direction, resource_kind, label}
var _handles: Array = []
var _ports: Array = []  ## 3D port defs bound to handle_ids
var _selected_handle_id: String = ""
var _selected_port_idx: int = -1

var _built := false
var _vp_container: SubViewportContainer = null
var _viewport: SubViewport = null
var _studio: Node3D = null
var _pivot: Node3D = null
var _camera: Camera3D = null
var _model_inst: Node3D = null
var _gizmo_root: Node3D = null
var _wire_root: Node3D = null
var _graph_model: GraphModel = null
var _preview_type_id: String = "conceptual_flow"

var _orbiting := false
var _yaw := 0.6
var _pitch := -0.35
var _distance := 2.5

var _handle_list: VBoxContainer = null
var _status_lbl: Label = null
var _save_catalog_chk: CheckBox = null
var _save_instance_chk: CheckBox = null
var _hint_lbl: Label = null
var _pending_banner: Label = null
var _wire_type_opt: OptionButton = null
var _pipe_size_opt: OptionButton = null
var _pipe_size_row: Control = null
var _show_wires_chk: CheckBox = null
var _approach_slider: HSlider = null
var _approach_lbl: Label = null
var _route_mode_opt: OptionButton = null
var _fitting_step_opt: OptionButton = null
var _io_settings_box: VBoxContainer = null

## Drag-from-sidebar state
var _drag_handle_id: String = ""
var _drag_active := false
var _drag_pending := false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_ghost: Control = null
var _bind_popup: PopupMenu = null
## Drag approach-arrow tip in the studio to aim outward.
var _aiming_outward := false


func open(model_id: String, item_id: String, prop_id: String,
		handles: Variant = null, graph_model: GraphModel = null) -> void:
	_model_id = model_id
	_item_id = item_id
	_prop_id = prop_id
	_graph_model = graph_model
	_handles = _normalize_handles(handles)
	if not _built:
		_build_ui()
		_built = true
	_load_ports()
	_selected_handle_id = ""
	_selected_port_idx = -1
	_preview_type_id = "conceptual_flow"
	if _wire_type_opt != null:
		_wire_type_opt.select(0)
	_rebuild_studio()
	_refresh_handle_list()
	_update_pending_banner()
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	_end_drag(false)
	visible = false
	CursorController.release_modal(MODAL_NAME)


func _normalize_handles(handles: Variant) -> Array:
	var out: Array = []
	if handles == null:
		return out
	if handles is PackedStringArray:
		for hid: String in handles as PackedStringArray:
			if hid.is_empty():
				continue
			out.append({"id": hid, "polarity": "", "direction": "", "label": hid,
				"resource_kind": ""})
		return out
	if handles is Array:
		for h: Variant in handles as Array:
			if h is String:
				var s := str(h)
				if not s.is_empty():
					out.append({"id": s, "polarity": "", "direction": "", "label": s,
						"resource_kind": ""})
			elif h is Dictionary:
				var d: Dictionary = h as Dictionary
				var hid := str(d.get("id", d.get("handle_id", "")))
				if hid.is_empty():
					continue
				out.append({
					"id": hid,
					"polarity": str(d.get("polarity", "")),
					"direction": _infer_direction(d),
					"label": _handle_display_name(d),
					"resource_kind": str(d.get("resource_kind", "")),
				})
	return out


func _infer_direction(h: Dictionary) -> String:
	var explicit := str(h.get("direction", "")).to_lower()
	if explicit == "in" or explicit == "out":
		return explicit
	if h.has("ry"):
		var ry := float(h.get("ry", 0.5))
		if ry <= 0.25:
			return "in"
		if ry >= 0.75:
			return "out"
	var pol := str(h.get("polarity", "")).to_lower()
	if pol in ["load", "ac"] and str(h.get("id", "")).contains("In"):
		return "in"
	if str(h.get("id", "")).to_lower().begins_with("in") \
			or str(h.get("id", "")).contains("_in") \
			or str(h.get("id", "")).ends_with("In"):
		return "in"
	if str(h.get("id", "")).to_lower().begins_with("out") \
			or str(h.get("id", "")).contains("_out") \
			or str(h.get("id", "")).ends_with("Out") \
			or str(h.get("id", "")).ends_with("Output"):
		return "out"
	return ""


func _handle_display_name(h: Dictionary) -> String:
	var label := str(h.get("label", "")).strip_edges()
	if not label.is_empty():
		return label
	var hid := str(h.get("id", h.get("handle_id", "")))
	# Camel/snake → spaced words
	var pretty := hid.replace("_", " ")
	var buf := ""
	for i: int in pretty.length():
		var ch := pretty[i]
		if i > 0 and ch >= "A" and ch <= "Z" and pretty[i - 1] >= "a" and pretty[i - 1] <= "z":
			buf += " "
		buf += ch
	return buf.capitalize() if not buf.is_empty() else hid


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(1040, 680)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	center.add_child(panel)

	var root_v := VBoxContainer.new()
	root_v.add_theme_constant_override("separation", 8)
	panel.add_child(root_v)

	var title := Label.new()
	title.text = "Connection Ports — bind 2D graph ports to 3D plugs"
	title.add_theme_font_size_override("font_size", 18)
	root_v.add_child(title)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_v.add_child(hbox)

	var vp_wrap := VBoxContainer.new()
	vp_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_wrap.add_theme_constant_override("separation", 4)
	hbox.add_child(vp_wrap)

	_pending_banner = Label.new()
	_pending_banner.add_theme_font_size_override("font_size", 12)
	_pending_banner.modulate = Color(1.0, 0.9, 0.45)
	vp_wrap.add_child(_pending_banner)

	_vp_container = SubViewportContainer.new()
	_vp_container.stretch = true
	_vp_container.custom_minimum_size = Vector2(600, 560)
	_vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp_container.gui_input.connect(_on_viewport_input)
	vp_wrap.add_child(_vp_container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.size = Vector2i(600, 560)
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	_vp_container.add_child(_viewport)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(380, 560)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(scroll)
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(360, 0)
	side.add_theme_constant_override("separation", 8)
	scroll.add_child(side)

	_hint_lbl = Label.new()
	_hint_lbl.text = "Select a 2D port, then click the mesh to bind. Drag the orange approach arrow tip to aim the socket outward (pipe arrives along −outward). Axis presets / Flip / length tune the approach."
	_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_lbl.add_theme_font_size_override("font_size", 12)
	_hint_lbl.modulate = Color(0.75, 0.82, 0.9)
	side.add_child(_hint_lbl)

	var wire_hdr := Label.new()
	wire_hdr.text = "Wire preview"
	wire_hdr.add_theme_font_size_override("font_size", 13)
	wire_hdr.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	side.add_child(wire_hdr)
	_show_wires_chk = CheckBox.new()
	_show_wires_chk.text = "Show preview wires from bound ports"
	_show_wires_chk.button_pressed = true
	_show_wires_chk.toggled.connect(func(_on: bool) -> void: _rebuild_wire_previews())
	side.add_child(_show_wires_chk)

	_io_settings_box = VBoxContainer.new()
	_io_settings_box.add_theme_constant_override("separation", 6)
	side.add_child(_io_settings_box)
	var io_hdr := Label.new()
	io_hdr.text = "Selected I/O settings"
	io_hdr.add_theme_font_size_override("font_size", 13)
	io_hdr.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_io_settings_box.add_child(io_hdr)

	var type_row := HBoxContainer.new()
	type_row.add_theme_constant_override("separation", 8)
	_io_settings_box.add_child(type_row)
	var type_lbl := Label.new()
	type_lbl.text = "Conduit type"
	type_lbl.custom_minimum_size.x = 90
	type_row.add_child(type_lbl)
	_wire_type_opt = OptionButton.new()
	_wire_type_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wire_type_opt.add_item("Conceptual", 0)
	_wire_type_opt.set_item_metadata(0, "conceptual_flow")
	var ti := 1
	for tid: Variant in ConduitKinds.all_types():
		var id := str(tid)
		if id == "conceptual_flow":
			continue
		_wire_type_opt.add_item(ConduitKinds.display_name(id), ti)
		_wire_type_opt.set_item_metadata(ti, id)
		ti += 1
	_wire_type_opt.item_selected.connect(_on_selected_type_changed)
	type_row.add_child(_wire_type_opt)

	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 8)
	_io_settings_box.add_child(size_row)
	_pipe_size_row = size_row
	var size_lbl := Label.new()
	size_lbl.text = "Pipe size"
	size_lbl.custom_minimum_size.x = 90
	size_row.add_child(size_lbl)
	_pipe_size_opt = OptionButton.new()
	_pipe_size_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for sz: float in PipeKit.SCH40_SIZES_IN:
		_pipe_size_opt.add_item(PipeKit.size_label(sz))
		_pipe_size_opt.set_item_metadata(_pipe_size_opt.item_count - 1, sz)
	_pipe_size_opt.item_selected.connect(func(_i: int) -> void: _write_selected_style_prefs())
	size_row.add_child(_pipe_size_opt)

	var rm_row := HBoxContainer.new()
	rm_row.add_theme_constant_override("separation", 8)
	_io_settings_box.add_child(rm_row)
	var rm_lbl := Label.new()
	rm_lbl.text = "Route mode"
	rm_lbl.custom_minimum_size.x = 90
	rm_row.add_child(rm_lbl)
	_route_mode_opt = OptionButton.new()
	_route_mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for rm: String in ["", "pipes", "ortho", "direct", "catenary"]:
		var lab := "Default" if rm.is_empty() else rm.capitalize()
		_route_mode_opt.add_item(lab)
		_route_mode_opt.set_item_metadata(_route_mode_opt.item_count - 1, rm)
	_route_mode_opt.item_selected.connect(func(_i: int) -> void: _write_selected_style_prefs())
	rm_row.add_child(_route_mode_opt)

	var fs_row := HBoxContainer.new()
	fs_row.add_theme_constant_override("separation", 8)
	_io_settings_box.add_child(fs_row)
	var fs_lbl := Label.new()
	fs_lbl.text = "Fitting °"
	fs_lbl.custom_minimum_size.x = 90
	fs_row.add_child(fs_lbl)
	_fitting_step_opt = OptionButton.new()
	_fitting_step_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for fs: float in [0.0, 30.0, 45.0, 60.0, 90.0]:
		_fitting_step_opt.add_item("Auto" if fs < 0.5 else "%d°" % int(fs))
		_fitting_step_opt.set_item_metadata(_fitting_step_opt.item_count - 1, fs)
	_fitting_step_opt.item_selected.connect(func(_i: int) -> void: _write_selected_style_prefs())
	fs_row.add_child(_fitting_step_opt)

	var apply_btn := Button.new()
	apply_btn.text = "Apply type/style to connections"
	apply_btn.focus_mode = Control.FOCUS_NONE
	apply_btn.pressed.connect(_apply_selected_to_connections)
	_io_settings_box.add_child(apply_btn)

	var ap_hdr := Label.new()
	ap_hdr.text = "Approach vector (socket outward)"
	ap_hdr.add_theme_font_size_override("font_size", 13)
	ap_hdr.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_io_settings_box.add_child(ap_hdr)
	_approach_lbl = Label.new()
	_approach_lbl.add_theme_font_size_override("font_size", 11)
	_approach_lbl.modulate = Color(0.75, 0.8, 0.85)
	_io_settings_box.add_child(_approach_lbl)
	_approach_slider = HSlider.new()
	_approach_slider.min_value = 0.15
	_approach_slider.max_value = 1.0
	_approach_slider.step = 0.05
	_approach_slider.value = ConnectionPortDefs.DEFAULT_APPROACH_M
	_approach_slider.value_changed.connect(_on_approach_m_changed)
	_io_settings_box.add_child(_approach_slider)
	var axis_row := HBoxContainer.new()
	axis_row.add_theme_constant_override("separation", 4)
	_io_settings_box.add_child(axis_row)
	for axis_name: String in ["+X", "-X", "+Y", "-Y", "+Z", "-Z"]:
		var ab := Button.new()
		ab.text = axis_name
		ab.focus_mode = Control.FOCUS_NONE
		ab.custom_minimum_size.x = 40
		var captured := axis_name
		ab.pressed.connect(func() -> void: _set_selected_outward_axis(captured))
		axis_row.add_child(ab)
	var flip_btn := Button.new()
	flip_btn.text = "Flip"
	flip_btn.focus_mode = Control.FOCUS_NONE
	flip_btn.pressed.connect(_flip_selected_outward)
	_io_settings_box.add_child(flip_btn)

	var list_hdr := Label.new()
	list_hdr.text = "2D graph ports"
	list_hdr.add_theme_font_size_override("font_size", 13)
	list_hdr.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	side.add_child(list_hdr)

	_handle_list = VBoxContainer.new()
	_handle_list.add_theme_constant_override("separation", 6)
	side.add_child(_handle_list)

	var unbind_btn := Button.new()
	unbind_btn.text = "Clear 3D bind for selected"
	unbind_btn.focus_mode = Control.FOCUS_NONE
	unbind_btn.pressed.connect(_on_clear_selected_bind)
	side.add_child(unbind_btn)

	_save_catalog_chk = CheckBox.new()
	_save_catalog_chk.text = "Save as catalog default for this model"
	_save_catalog_chk.button_pressed = true
	side.add_child(_save_catalog_chk)

	_save_instance_chk = CheckBox.new()
	_save_instance_chk.text = "Save on this placed prop only"
	_save_instance_chk.button_pressed = true
	side.add_child(_save_instance_chk)

	_status_lbl = Label.new()
	_status_lbl.add_theme_font_size_override("font_size", 12)
	_status_lbl.modulate = Color(0.7, 0.85, 0.7)
	side.add_child(_status_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	side.add_child(btn_row)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_save)
	btn_row.add_child(save_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.pressed.connect(close)
	btn_row.add_child(close_btn)

	_bind_popup = PopupMenu.new()
	_bind_popup.id_pressed.connect(_on_bind_popup_picked)
	add_child(_bind_popup)

	# Ghost chip drawn above everything while dragging.
	_drag_ghost = Control.new()
	_drag_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drag_ghost.visible = false
	_drag_ghost.z_index = 20
	_drag_ghost.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_drag_ghost.draw.connect(_draw_drag_ghost)
	add_child(_drag_ghost)


func _load_ports() -> void:
	var main := _scene_main()
	if not _prop_id.is_empty():
		_ports = ConnectionPortDefs.resolve_ports_for_prop(main, _prop_id, _model_id)
	else:
		_ports = ConnectionPortDefs.load_catalog_ports(_model_id)


func _scene_main() -> Node:
	var ul := get_parent()
	if ul != null:
		return ul.get_parent()
	return get_tree().current_scene if get_tree() != null else null


func _color_for_handle(h: Dictionary) -> Color:
	var rk := str(h.get("resource_kind", ""))
	if not rk.is_empty():
		return ResourceKinds.wire_color(rk)
	var pol := str(h.get("polarity", ""))
	return PORT_COLORS.get(pol, Color(0.55, 0.75, 0.95, 1.0)) as Color


func _port_for_handle(handle_id: String) -> Dictionary:
	return ConnectionPortDefs.find_port_for_handle(_ports, handle_id)


func _port_index_for_handle(handle_id: String) -> int:
	for i: int in _ports.size():
		if str((_ports[i] as Dictionary).get("handle_id", "")) == handle_id:
			return i
	return -1


func _refresh_handle_list() -> void:
	if _handle_list == null:
		return
	for c in _handle_list.get_children():
		c.queue_free()
	if _handles.is_empty():
		var empty := Label.new()
		empty.text = "No 2D ports on this node.\nOpen from a graph item that has handles."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.modulate = Color(0.85, 0.55, 0.45)
		_handle_list.add_child(empty)
		return

	# Group: inputs first, then outputs, then unknown.
	var groups := {"in": [], "out": [], "": []}
	for h: Variant in _handles:
		var d: Dictionary = h as Dictionary
		var dir := str(d.get("direction", ""))
		if not groups.has(dir):
			dir = ""
		(groups[dir] as Array).append(d)

	for dir_key: String in ["in", "out", ""]:
		var arr: Array = groups[dir_key] as Array
		if arr.is_empty():
			continue
		var section := Label.new()
		match dir_key:
			"in":
				section.text = "Inputs"
			"out":
				section.text = "Outputs"
			_:
				section.text = "Ports"
		section.add_theme_font_size_override("font_size", 11)
		section.modulate = Color(0.65, 0.7, 0.78)
		_handle_list.add_child(section)
		for h: Variant in arr:
			_handle_list.add_child(_make_handle_row(h as Dictionary))


func _make_handle_row(h: Dictionary) -> Control:
	var hid := str(h.get("id", ""))
	var bound := _port_for_handle(hid)
	var selected := hid == _selected_handle_id

	var row := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.14, 0.17, 0.22, 0.95) if not selected \
			else Color(0.18, 0.28, 0.34, 1.0)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(8)
	if selected:
		sb.border_color = UITheme.C_PRIMARY
		sb.set_border_width_all(2)
	row.add_theme_stylebox_override("panel", sb)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(func(ev: InputEvent) -> void:
		_on_handle_row_input(ev, hid)
	)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	row.add_child(hbox)

	# Circular port chip (draggable affordance).
	var chip := Control.new()
	chip.custom_minimum_size = Vector2(36, 36)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := _color_for_handle(h)
	chip.draw.connect(func() -> void:
		var c := chip.get_size() * 0.5
		var r := mini(c.x, c.y) - 2.0
		chip.draw_circle(c, r, col)
		chip.draw_arc(c, r, 0.0, TAU, 32, Color(1, 1, 1, 0.85 if selected else 0.45), 2.0, true)
		if not bound.is_empty():
			chip.draw_circle(c, r * 0.35, Color(1, 1, 1, 0.95))
	)
	hbox.add_child(chip)

	var text_col := VBoxContainer.new()
	text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_col.add_theme_constant_override("separation", 2)
	hbox.add_child(text_col)

	var name_lbl := Label.new()
	name_lbl.text = str(h.get("label", hid))
	name_lbl.add_theme_font_size_override("font_size", 13)
	text_col.add_child(name_lbl)

	var meta := Label.new()
	var dir := str(h.get("direction", ""))
	var dir_txt := "IN" if dir == "in" else ("OUT" if dir == "out" else "—")
	var type_txt := _type_label(h)
	var bind_txt := "bound" if not bound.is_empty() else "unbound"
	meta.text = "%s  ·  %s  ·  %s" % [dir_txt, type_txt, bind_txt]
	meta.add_theme_font_size_override("font_size", 11)
	meta.modulate = Color(0.7, 0.85, 0.7) if not bound.is_empty() \
			else Color(0.7, 0.72, 0.78)
	text_col.add_child(meta)

	return row


func _type_label(h: Dictionary) -> String:
	var rk := str(h.get("resource_kind", ""))
	if not rk.is_empty():
		return ResourceKinds.display_name(rk)
	var pol := str(h.get("polarity", ""))
	match pol:
		"positive":
			return "DC +"
		"negative":
			return "DC −"
		"ac":
			return "AC"
		"ac_240":
			return "AC 240V"
		"load":
			return "Load"
		"smart_battery":
			return "Smart battery"
		"pv":
			return "PV"
		"resource":
			return "Resource"
		"parallel":
			return "Parallel"
		_:
			return pol if not pol.is_empty() else "Port"


func _on_handle_row_input(event: InputEvent, handle_id: String) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_select_handle(handle_id)
				_drag_pending = true
				_drag_active = false
				_drag_handle_id = handle_id
				_drag_start = get_global_mouse_position()
				accept_event()
			else:
				if _drag_active:
					_finish_drag_drop()
				_drag_pending = false
				accept_event()
	elif event is InputEventMouseMotion:
		if _drag_pending and not _drag_active:
			if get_global_mouse_position().distance_to(_drag_start) >= DRAG_THRESH_PX:
				_drag_active = true
				_drag_ghost.visible = true
				_drag_ghost.queue_redraw()
		if _drag_active:
			_drag_ghost.queue_redraw()
			accept_event()


func _select_handle(handle_id: String) -> void:
	_selected_handle_id = handle_id
	_selected_port_idx = _port_index_for_handle(handle_id)
	_sync_io_controls_from_selection()
	_refresh_handle_list()
	_rebuild_gizmos()
	_update_pending_banner()


func _sync_io_controls_from_selection() -> void:
	var port := _port_for_handle(_selected_handle_id)
	var type_id := _resolve_preview_type_for_handle(_selected_handle_id)
	_preview_type_id = type_id
	if _wire_type_opt != null:
		for i: int in _wire_type_opt.item_count:
			if str(_wire_type_opt.get_item_metadata(i)) == type_id:
				_wire_type_opt.select(i)
				break
	var style: Dictionary = {}
	if port.get("preferred_conduit_style", null) is Dictionary:
		style = port.get("preferred_conduit_style", {}) as Dictionary
	else:
		var conn := _first_conn_for_handle(_selected_handle_id)
		if not conn.is_empty():
			style = conn.get("conduit_style", {}) as Dictionary
	if _route_mode_opt != null:
		var rm := str(style.get("route_mode", ""))
		for i: int in _route_mode_opt.item_count:
			if str(_route_mode_opt.get_item_metadata(i)) == rm:
				_route_mode_opt.select(i)
				break
	if _fitting_step_opt != null:
		var fs := float(style.get("fitting_step_deg", 0.0))
		var best_i := 0
		var best_d := INF
		for i: int in _fitting_step_opt.item_count:
			var v := float(_fitting_step_opt.get_item_metadata(i))
			var d := absf(v - fs)
			if d < best_d:
				best_d = d
				best_i = i
		_fitting_step_opt.select(best_i)
	var kit := ConduitKinds.uses_pipe_kit(type_id)
	if _pipe_size_row != null:
		_pipe_size_row.visible = kit
	if kit and _pipe_size_opt != null:
		var sz := ConduitKinds.pipe_size_in(type_id, style)
		for i: int in _pipe_size_opt.item_count:
			if absf(float(_pipe_size_opt.get_item_metadata(i)) - sz) < 0.01:
				_pipe_size_opt.select(i)
				break
	if _approach_slider != null:
		_approach_slider.set_value_no_signal(
			ConnectionPortDefs.approach_m_for_port(port) if not port.is_empty() \
				else ConnectionPortDefs.DEFAULT_APPROACH_M)
	_refresh_approach_label()


func _refresh_approach_label() -> void:
	if _approach_lbl == null:
		return
	var port := _port_for_handle(_selected_handle_id)
	if port.is_empty():
		_approach_lbl.text = "Bind a 3D point first to edit approach"
		return
	var n := ConnectionPortDefs.local_outward(port)
	var m := ConnectionPortDefs.approach_m_for_port(port)
	_approach_lbl.text = "Outward (%.2f, %.2f, %.2f) · length %.2f m" % [n.x, n.y, n.z, m]


func _on_selected_type_changed(idx: int) -> void:
	_preview_type_id = str(_wire_type_opt.get_item_metadata(idx))
	_write_selected_type_pref()
	if _pipe_size_row != null:
		_pipe_size_row.visible = ConduitKinds.uses_pipe_kit(_preview_type_id)
	_write_selected_style_prefs()
	_rebuild_wire_previews()


func _write_selected_type_pref() -> void:
	var idx := _port_index_for_handle(_selected_handle_id)
	if idx < 0:
		return
	var p: Dictionary = (_ports[idx] as Dictionary).duplicate(true)
	p["preferred_conduit_type"] = _preview_type_id
	_ports[idx] = p


func _write_selected_style_prefs() -> void:
	var idx := _port_index_for_handle(_selected_handle_id)
	if idx < 0:
		return
	var p: Dictionary = (_ports[idx] as Dictionary).duplicate(true)
	var style: Dictionary = {}
	if p.get("preferred_conduit_style", null) is Dictionary:
		style = (p.get("preferred_conduit_style", {}) as Dictionary).duplicate(true)
	if _route_mode_opt != null:
		var rm := str(_route_mode_opt.get_item_metadata(_route_mode_opt.selected))
		if rm.is_empty():
			style.erase("route_mode")
		else:
			style["route_mode"] = rm
	if _fitting_step_opt != null:
		var fs := float(_fitting_step_opt.get_item_metadata(_fitting_step_opt.selected))
		if fs < 0.5:
			style.erase("fitting_step_deg")
		else:
			style["fitting_step_deg"] = fs
	if ConduitKinds.uses_pipe_kit(_preview_type_id) and _pipe_size_opt != null:
		style["pipe_size_in"] = float(_pipe_size_opt.get_item_metadata(_pipe_size_opt.selected))
	else:
		style.erase("pipe_size_in")
	p["preferred_conduit_style"] = style
	_ports[idx] = p
	_rebuild_wire_previews()


func _on_approach_m_changed(v: float) -> void:
	var idx := _port_index_for_handle(_selected_handle_id)
	if idx < 0:
		return
	var p: Dictionary = (_ports[idx] as Dictionary).duplicate(true)
	p["approach_m"] = clampf(v, 0.15, 1.0)
	_ports[idx] = p
	_refresh_approach_label()
	_rebuild_gizmos()


func _set_selected_outward_axis(axis_name: String) -> void:
	var dir := Vector3.UP
	match axis_name:
		"+X":
			dir = Vector3.RIGHT
		"-X":
			dir = Vector3.LEFT
		"+Y":
			dir = Vector3.UP
		"-Y":
			dir = Vector3.DOWN
		"+Z":
			dir = Vector3.BACK
		"-Z":
			dir = Vector3.FORWARD
	_set_selected_outward(dir)


func _flip_selected_outward() -> void:
	var port := _port_for_handle(_selected_handle_id)
	if port.is_empty():
		return
	_set_selected_outward(-ConnectionPortDefs.local_outward(port))


func _set_selected_outward(dir: Vector3) -> void:
	var idx := _port_index_for_handle(_selected_handle_id)
	if idx < 0 or dir.length_squared() < 1e-8:
		_status_lbl.text = "Select a bound port first"
		return
	var n := dir.normalized()
	var p: Dictionary = (_ports[idx] as Dictionary).duplicate(true)
	p["nx"] = n.x
	p["ny"] = n.y
	p["nz"] = n.z
	_ports[idx] = p
	_refresh_approach_label()
	_rebuild_gizmos()
	_status_lbl.text = "Approach outward set"


func _apply_selected_to_connections() -> void:
	if _graph_model == null or _item_id.is_empty() or _selected_handle_id.is_empty():
		_status_lbl.text = "No graph connections to update"
		return
	var type_id := _preview_type_id
	var style: Dictionary = {}
	var port := _port_for_handle(_selected_handle_id)
	if port.get("preferred_conduit_style", null) is Dictionary:
		style = (port.get("preferred_conduit_style", {}) as Dictionary).duplicate(true)
	var n := 0
	for conn: Dictionary in _graph_model.connections_for_item(_item_id):
		var is_src := str(conn.get("source_item_id", "")) == _item_id
		var hid := str(conn.get("source_handle_id" if is_src else "target_handle_id", ""))
		if hid != _selected_handle_id:
			continue
		var patch := {"conduit_type": type_id}
		if not style.is_empty():
			var merged: Dictionary = (conn.get("conduit_style", {}) as Dictionary).duplicate(true)
			for k: Variant in style.keys():
				merged[k] = style[k]
			patch["conduit_style"] = merged
		_graph_model.update_connection(str(conn.get("id", "")), patch)
		n += 1
	_write_selected_type_pref()
	_rebuild_wire_previews()
	_status_lbl.text = "Updated %d connection(s)" % n


func _first_conn_for_handle(handle_id: String) -> Dictionary:
	if _graph_model == null or _item_id.is_empty() or handle_id.is_empty():
		return {}
	for conn: Dictionary in _graph_model.connections_for_item(_item_id):
		var is_src := str(conn.get("source_item_id", "")) == _item_id
		var hid := str(conn.get("source_handle_id" if is_src else "target_handle_id", ""))
		if hid == handle_id:
			return conn
	return {}


func _resolve_preview_type_for_handle(handle_id: String) -> String:
	var conn := _first_conn_for_handle(handle_id)
	if not conn.is_empty():
		var tid := ConduitKinds.derive_type_for_connection(conn)
		if not tid.is_empty():
			return tid
	var port := _port_for_handle(handle_id)
	var pref := str(port.get("preferred_conduit_type", ""))
	if not pref.is_empty():
		return pref
	if not _preview_type_id.is_empty():
		return _preview_type_id
	return "conceptual_flow"


func _update_pending_banner() -> void:
	if _pending_banner == null:
		return
	if _selected_handle_id.is_empty():
		_pending_banner.text = "Select a 2D port (or drag one onto the model)"
		_pending_banner.modulate = Color(0.7, 0.75, 0.82)
		return
	var h := _handle_by_id(_selected_handle_id)
	var name_ := str(h.get("label", _selected_handle_id))
	var bound := not _port_for_handle(_selected_handle_id).is_empty()
	if bound:
		_pending_banner.text = "Selected: %s — click mesh to move its 3D plug" % name_
	else:
		_pending_banner.text = "Selected: %s — click mesh to place its 3D plug" % name_
	_pending_banner.modulate = Color(1.0, 0.9, 0.45)


func _handle_by_id(handle_id: String) -> Dictionary:
	for h: Variant in _handles:
		if str((h as Dictionary).get("id", "")) == handle_id:
			return h as Dictionary
	return {}


func _draw_drag_ghost() -> void:
	if not _drag_active or _drag_handle_id.is_empty():
		return
	var h := _handle_by_id(_drag_handle_id)
	var col := _color_for_handle(h)
	var gp := get_global_mouse_position() - global_position
	_drag_ghost.draw_circle(gp, 18.0, Color(col.r, col.g, col.b, 0.9))
	_drag_ghost.draw_arc(gp, 18.0, 0.0, TAU, 36, Color(1, 1, 1, 0.9), 2.5, true)
	var label := str(h.get("label", _drag_handle_id))
	var font := ThemeDB.fallback_font
	if font != null:
		_drag_ghost.draw_string(font, gp + Vector2(22, 5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color(1, 1, 1, 0.95))


func _input(event: InputEvent) -> void:
	if not visible:
		return
	# Track drag across the whole modal (row → 3D preview).
	if (_drag_pending or _drag_active) and event is InputEventMouseMotion:
		if _drag_pending and not _drag_active:
			if get_global_mouse_position().distance_to(_drag_start) >= DRAG_THRESH_PX:
				_drag_active = true
				_drag_ghost.visible = true
		if _drag_active:
			_drag_ghost.queue_redraw()
	elif (_drag_pending or _drag_active) and event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			if _drag_active:
				_finish_drag_drop()
				get_viewport().set_input_as_handled()
			else:
				_end_drag(false)


func _finish_drag_drop() -> void:
	var hid := _drag_handle_id
	var local_in_vp := _vp_container.get_local_mouse_position() if _vp_container != null \
			else Vector2(-1, -1)
	_end_drag(false)
	if hid.is_empty() or _vp_container == null:
		return
	var rect := Rect2(Vector2.ZERO, _vp_container.size)
	if not rect.has_point(local_in_vp):
		_status_lbl.text = "Drop on the 3D preview to place"
		return
	_bind_handle_at_screen(hid, local_in_vp)


func _end_drag(_commit: bool) -> void:
	_drag_active = false
	_drag_pending = false
	_drag_handle_id = ""
	if _drag_ghost != null:
		_drag_ghost.visible = false
		_drag_ghost.queue_redraw()


func _rebuild_studio() -> void:
	if _viewport == null:
		return
	for c in _viewport.get_children():
		c.queue_free()
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 35, 0)
	light.light_energy = 1.1
	_studio.add_child(light)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-1.5, 1.2, 1.5)
	fill.light_energy = 0.4
	_studio.add_child(fill)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.12, 0.14, 0.18)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.48, 0.55)
	e.ambient_light_energy = 0.55
	env.environment = e
	_studio.add_child(env)

	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	_studio.add_child(_pivot)
	_camera = Camera3D.new()
	_camera.current = true
	_pivot.add_child(_camera)

	_model_inst = ModelCatalog.instantiate(_model_id)
	if _model_inst == null:
		_status_lbl.text = "Could not load model '%s'" % _model_id
		return
	_model_inst.name = "ModelRoot"
	_studio.add_child(_model_inst)

	_gizmo_root = Node3D.new()
	_gizmo_root.name = "PortGizmos"
	_studio.add_child(_gizmo_root)
	_wire_root = Node3D.new()
	_wire_root.name = "WirePreviews"
	_studio.add_child(_wire_root)

	_fit_camera_to_model()
	_update_camera()
	_rebuild_gizmos()
	_rebuild_wire_previews()


func _fit_camera_to_model() -> void:
	if _model_inst == null:
		return
	var aabb := AABB()
	var any := false
	for node in _model_inst.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var local := mi.get_aabb()
		var xf: Transform3D = _model_inst.global_transform.affine_inverse() * mi.global_transform
		var box := xf * local
		if not any:
			aabb = box
			any = true
		else:
			aabb = aabb.merge(box)
	if not any:
		_distance = 2.5
		return
	var radius := aabb.size.length() * 0.5
	_distance = clampf(radius * 2.4, ZOOM_MIN, ZOOM_MAX)
	_pivot.position = aabb.get_center()


func _update_camera() -> void:
	if _camera == null:
		return
	_pitch = clampf(_pitch, -1.35, 1.35)
	_distance = clampf(_distance, ZOOM_MIN, ZOOM_MAX)
	var offset := Vector3(
		_distance * cos(_pitch) * sin(_yaw),
		_distance * sin(_pitch),
		_distance * cos(_pitch) * cos(_yaw))
	_camera.position = offset
	_camera.look_at(_pivot.global_position, Vector3.UP)


func _to_viewport_pos(local_pos: Vector2) -> Vector2:
	if _vp_container == null or _viewport == null:
		return local_pos
	var sz := _vp_container.size
	if sz.x < 1.0 or sz.y < 1.0:
		return local_pos
	return local_pos * (Vector2(_viewport.size) / sz)


func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = mb.pressed
			_aiming_outward = false
			_vp_container.accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_distance *= 0.9
			_update_camera()
			_vp_container.accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_distance *= 1.1
			_update_camera()
			_vp_container.accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _hit_approach_tip(mb.position):
					_aiming_outward = true
				elif not _selected_handle_id.is_empty():
					_bind_handle_at_screen(_selected_handle_id, mb.position)
				else:
					_prompt_bind_at_screen(mb.position)
			else:
				_aiming_outward = false
			_vp_container.accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _aiming_outward:
			_aim_outward_at_screen(mm.position)
			_vp_container.accept_event()
		elif _orbiting:
			_yaw -= mm.relative.x * ORBIT_SENS
			_pitch -= mm.relative.y * ORBIT_SENS
			_update_camera()
			_vp_container.accept_event()


func _hit_approach_tip(local_pos: Vector2) -> bool:
	var port := _port_for_handle(_selected_handle_id)
	if port.is_empty() or _camera == null or _model_inst == null:
		return false
	var tip := ConnectionPortDefs.world_approach_point(port, _model_inst)
	var screen := _camera.unproject_position(tip)
	var vp_pos := _to_viewport_pos(local_pos)
	return screen.distance_to(vp_pos) <= 18.0


func _aim_outward_at_screen(local_pos: Vector2) -> void:
	var port := _port_for_handle(_selected_handle_id)
	if port.is_empty() or _camera == null or _model_inst == null:
		return
	var pos_w := ConnectionPortDefs.world_pos_for_port(port, _model_inst)
	var vp_pos := _to_viewport_pos(local_pos)
	var origin := _camera.project_ray_origin(vp_pos)
	var dir := _camera.project_ray_normal(vp_pos)
	# Intersect a plane through the port, facing the camera.
	var plane_n := -_camera.global_transform.basis.z
	var denom := plane_n.dot(dir)
	if absf(denom) < 1e-6:
		return
	var t := plane_n.dot(pos_w - origin) / denom
	if t < 0.0:
		return
	var hit_w := origin + dir * t
	var world_out := hit_w - pos_w
	if world_out.length_squared() < 1e-8:
		return
	var local_out: Vector3 = _model_inst.global_transform.basis.inverse() * world_out.normalized()
	_set_selected_outward(local_out)


func _pick_mesh(local_pos: Vector2) -> Dictionary:
	if _camera == null or _model_inst == null:
		return {}
	var vp_pos := _to_viewport_pos(local_pos)
	var origin := _camera.project_ray_origin(vp_pos)
	var dir := _camera.project_ray_normal(vp_pos)
	return MeshTrianglePick.pick(_model_inst, origin, dir)


func _bind_handle_at_screen(handle_id: String, local_pos: Vector2) -> void:
	var hit := _pick_mesh(local_pos)
	if not bool(hit.get("valid", false)):
		_status_lbl.text = "No mesh hit — try another surface"
		return
	_place_bind(handle_id, hit)


func _prompt_bind_at_screen(local_pos: Vector2) -> void:
	var hit := _pick_mesh(local_pos)
	if not bool(hit.get("valid", false)):
		_status_lbl.text = "No mesh hit — select a 2D port first, or click a surface"
		return
	if _handles.is_empty():
		_status_lbl.text = "No 2D ports to bind"
		return
	# Stash hit on the popup via meta, then show unbound-first menu.
	_bind_popup.clear()
	_bind_popup.set_meta("pending_hit", hit)
	var unbound: Array = []
	var bound: Array = []
	for h: Variant in _handles:
		var d: Dictionary = h as Dictionary
		var hid := str(d.get("id", ""))
		if _port_for_handle(hid).is_empty():
			unbound.append(d)
		else:
			bound.append(d)
	var id_i := 0
	for d: Variant in unbound:
		var h: Dictionary = d as Dictionary
		var dir := str(h.get("direction", ""))
		var prefix := "IN · " if dir == "in" else ("OUT · " if dir == "out" else "")
		_bind_popup.add_item("%s%s  (%s)" % [prefix, str(h.get("label", "")), _type_label(h)], id_i)
		_bind_popup.set_item_metadata(id_i, str(h.get("id", "")))
		id_i += 1
	if not unbound.is_empty() and not bound.is_empty():
		_bind_popup.add_separator()
	for d: Variant in bound:
		var h: Dictionary = d as Dictionary
		var dir := str(h.get("direction", ""))
		var prefix := "IN · " if dir == "in" else ("OUT · " if dir == "out" else "")
		_bind_popup.add_item("↻ %s%s  (move)" % [prefix, str(h.get("label", ""))], id_i)
		_bind_popup.set_item_metadata(id_i, str(h.get("id", "")))
		id_i += 1
	var gp := _vp_container.get_global_transform() * local_pos
	_bind_popup.position = Vector2i(gp)
	_bind_popup.popup()


func _on_bind_popup_picked(id: int) -> void:
	var hid := str(_bind_popup.get_item_metadata(id))
	var hit: Dictionary = _bind_popup.get_meta("pending_hit", {}) as Dictionary
	if hid.is_empty() or hit.is_empty():
		return
	_select_handle(hid)
	_place_bind(hid, hit)


func _place_bind(handle_id: String, hit: Dictionary) -> void:
	var h := _handle_by_id(handle_id)
	var world_pos: Vector3 = hit["position"] as Vector3
	var world_n: Vector3 = hit["normal"] as Vector3
	var local_p: Vector3 = _model_inst.to_local(world_pos)
	var local_n: Vector3 = (_model_inst.global_transform.basis.inverse() * world_n).normalized()
	var label := str(h.get("label", handle_id))
	var existing_i := _port_index_for_handle(handle_id)
	var keep_approach := ConnectionPortDefs.DEFAULT_APPROACH_M
	var keep_type := ""
	var keep_style: Dictionary = {}
	if existing_i >= 0:
		var old: Dictionary = _ports[existing_i] as Dictionary
		keep_approach = ConnectionPortDefs.approach_m_for_port(old)
		if keep_approach < ConnectionPortDefs.MIN_APPROACH_M:
			keep_approach = ConnectionPortDefs.DEFAULT_APPROACH_M
		keep_type = str(old.get("preferred_conduit_type", ""))
		if old.get("preferred_conduit_style", null) is Dictionary:
			keep_style = (old.get("preferred_conduit_style", {}) as Dictionary).duplicate(true)
	var port := ConnectionPortDefs.make_port(
		"" if existing_i < 0 else str((_ports[existing_i] as Dictionary).get("id", "")),
		label, local_p, local_n, handle_id,
		str(h.get("polarity", "")), str(h.get("resource_kind", "")),
		"", keep_approach, keep_type, keep_style)
	if existing_i >= 0:
		_ports[existing_i] = port
	else:
		_ports.append(port)
	_selected_handle_id = handle_id
	_selected_port_idx = _port_index_for_handle(handle_id)
	_sync_io_controls_from_selection()
	_refresh_handle_list()
	_rebuild_gizmos()
	_update_pending_banner()
	_status_lbl.text = "Bound “%s” to mesh" % label


func _rebuild_gizmos() -> void:
	if _gizmo_root == null:
		return
	for c in _gizmo_root.get_children():
		c.queue_free()
	for i: int in _ports.size():
		var p: Dictionary = _ports[i] as Dictionary
		var hid := str(p.get("handle_id", ""))
		var h := _handle_by_id(hid)
		var col := _color_for_handle(h) if not h.is_empty() else Color(0.2, 0.95, 0.55)
		var selected := hid == _selected_handle_id
		var holder := Node3D.new()
		holder.position = Vector3(float(p.get("x", 0.0)), float(p.get("y", 0.0)), float(p.get("z", 0.0)))
		_gizmo_root.add_child(holder)
		var sphere := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.035 if selected else 0.028
		sm.height = sm.radius * 2.0
		sphere.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = col
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 2.0 if selected else 1.4
		sphere.material_override = mat
		holder.add_child(sphere)
		var n := ConnectionPortDefs.local_outward(p)
		var approach_m := ConnectionPortDefs.approach_m_for_port(p)
		if approach_m < ConnectionPortDefs.MIN_APPROACH_M:
			approach_m = 0.08
		var arrow := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.005 if selected else 0.004
		cyl.bottom_radius = 0.005 if selected else 0.004
		cyl.height = approach_m
		arrow.mesh = cyl
		arrow.material_override = mat
		holder.add_child(arrow)
		arrow.position = n * (approach_m * 0.5)
		var up := Vector3.RIGHT if absf(n.dot(Vector3.UP)) > 0.95 else Vector3.UP
		arrow.basis = Basis.looking_at(n, up)
		arrow.rotate_object_local(Vector3.RIGHT, -PI * 0.5)
		# Tip sphere — drag handle for aiming outward.
		var tip := MeshInstance3D.new()
		var tip_m := SphereMesh.new()
		tip_m.radius = 0.022 if selected else 0.014
		tip_m.height = tip_m.radius * 2.0
		tip.mesh = tip_m
		var tip_mat := StandardMaterial3D.new()
		tip_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		tip_mat.albedo_color = Color(1.0, 0.92, 0.35) if selected else col.lightened(0.25)
		tip_mat.emission_enabled = true
		tip_mat.emission = tip_mat.albedo_color
		tip_mat.emission_energy_multiplier = 1.8
		tip.material_override = tip_mat
		tip.position = n * approach_m
		holder.add_child(tip)
	_rebuild_wire_previews()


## Preview conduits leaving each bound port (approach stub + ground fan).
func _rebuild_wire_previews() -> void:
	if _wire_root == null:
		return
	for c in _wire_root.get_children():
		c.queue_free()
	if _show_wires_chk != null and not _show_wires_chk.button_pressed:
		return
	if _model_inst == null:
		return
	var peer_ends: Dictionary = {}
	if _graph_model != null and not _item_id.is_empty():
		for conn: Dictionary in _graph_model.connections_for_item(_item_id):
			var is_src := str(conn.get("source_item_id", "")) == _item_id
			var hid := str(conn.get("source_handle_id" if is_src else "target_handle_id", ""))
			var peer_id := str(conn.get("target_item_id" if is_src else "source_item_id", ""))
			var peer_h := str(conn.get("target_handle_id" if is_src else "source_handle_id", ""))
			var peer_item := _graph_model.get_item(peer_id)
			if not peer_ends.has(hid):
				peer_ends[hid] = []
			(peer_ends[hid] as Array).append({
				"conn": conn,
				"peer_label": str(peer_item.get("type", peer_id)),
				"peer_handle": peer_h,
			})
	var lane := 0
	for p: Variant in _ports:
		if not (p is Dictionary):
			continue
		var port: Dictionary = p as Dictionary
		var hid := str(port.get("handle_id", ""))
		if hid.is_empty():
			continue
		var n := ConnectionPortDefs.local_outward(port)
		var approach_m := ConnectionPortDefs.approach_m_for_port(port)
		if approach_m < ConnectionPortDefs.MIN_APPROACH_M:
			approach_m = ConnectionPortDefs.DEFAULT_APPROACH_M
		var world_port: Vector3 = ConnectionPortDefs.world_pos_for_port(port, _model_inst)
		var world_approach: Vector3 = world_port + (_model_inst.global_transform.basis * n) \
				.normalized() * approach_m
		var ground_y := _pivot.position.y - _distance * 0.15 if _pivot != null else -0.2
		var peers: Array = peer_ends.get(hid, []) as Array
		var type_for_h := _resolve_preview_type_for_handle(hid)
		# Selected I/O uses the sidebar type picker for live audition.
		if hid == _selected_handle_id and not _preview_type_id.is_empty():
			type_for_h = _preview_type_id
		var style_for_h: Dictionary = {}
		if port.get("preferred_conduit_style", null) is Dictionary:
			style_for_h = (port.get("preferred_conduit_style", {}) as Dictionary).duplicate(true)
		# Studio stub: port → approach → leave along outward, then a short lateral
		# fan (matches world leave-shoulder semantics — not a dashed metro maze).
		var n_world: Vector3 = (_model_inst.global_transform.basis * n).normalized()
		var leave := world_approach + n_world * 0.25
		var fan := leave + Vector3(0.55 + lane * 0.12, 0, 0).rotated(Vector3.UP, float(lane) * 0.4)
		fan.y = ground_y + 0.06
		if peers.is_empty():
			_add_preview_tube(world_port, world_approach, leave, fan, type_for_h, style_for_h)
			lane += 1
			continue
		for pe: Variant in peers:
			var info: Dictionary = pe as Dictionary
			var conn: Dictionary = info.get("conn", {}) as Dictionary
			var conn_type := ConduitKinds.derive_type_for_connection(conn)
			var preview_tid := type_for_h
			if preview_tid.is_empty():
				preview_tid = conn_type if not conn_type.is_empty() else "conceptual_flow"
			var style: Dictionary = style_for_h.duplicate(true)
			if style.is_empty() and conn.get("conduit_style", null) is Dictionary:
				style = (conn.get("conduit_style", {}) as Dictionary).duplicate(true)
			var peer_fan := leave + Vector3(0.55 + lane * 0.12, 0, 0).rotated(
				Vector3.UP, float(lane) * 0.4)
			peer_fan.y = ground_y + 0.06
			_add_preview_tube(world_port, world_approach, leave, peer_fan, preview_tid, style)
			lane += 1


func _add_preview_tube(port_pt: Vector3, approach_pt: Vector3, leave_pt: Vector3,
		fan_pt: Vector3, type_id: String, style_ov: Dictionary = {}) -> void:
	var merged_style := ConduitStylePresets.type_defaults(type_id)
	for k: Variant in style_ov.keys():
		merged_style[k] = style_ov[k]
	# Studio audition: continuous tube (dashed conceptual looked like broken fragments).
	merged_style["dashed"] = false
	var route_mode := ConduitKinds.normalize_route_mode(
		str(merged_style.get("route_mode", ConduitKinds.type_meta(type_id).get("route_mode", ""))))
	var want_kit := ConduitKinds.uses_pipe_kit(type_id)
	var want_pipes := want_kit or route_mode == "pipes" \
			or (route_mode.is_empty() and ConduitKinds.is_pipes_type(type_id) \
				and not ConduitKinds.is_conceptual_type(type_id))
	var control: Array = [port_pt]
	if approach_pt.distance_to(port_pt) > 0.02:
		control.append(approach_pt)
	if leave_pt.distance_to(approach_pt) > 0.02:
		control.append(leave_pt)
	if want_pipes:
		var step := ConduitKinds.fitting_step_deg(type_id, merged_style)
		if step < 0.5:
			step = 45.0
		# Expand leave → fan (ports already seated colinear along outward).
		var sharp: Array = [leave_pt, fan_pt]
		var expanded := PipeFittingExpander.expand(sharp, step)
		for p: Vector3 in expanded:
			if control.is_empty() or (control[control.size() - 1] as Vector3).distance_to(p) > 0.01:
				control.append(p)
	else:
		# Flex / conceptual: short continuous polyline, no metro maze.
		control.append(fan_pt)
	if control.size() < 2:
		control = [port_pt, fan_pt]
	var built := ConduitMeshBuilder.build(control, type_id, 10, Callable(), merged_style)
	var mi := MeshInstance3D.new()
	mi.mesh = built.get("mesh", null)
	var tint := ConduitKinds.flow_tint_for_connection({"polarity": "ac"}) \
			if type_id == "conceptual_flow" or ConduitKinds.is_conceptual_type(type_id) \
			else Color(0, 0, 0, 0)
	if ConduitKinds.is_conceptual_type(type_id) or type_id == "conceptual_flow" \
			or bool(merged_style.get("use_flow_shader", false)):
		var flow := float(merged_style.get("flow_strength_default", 0.9))
		mi.material_override = ConduitKinds.make_flow_material(type_id, tint, flow, 1.3)
	else:
		mi.material_override = ConduitKinds.make_material(type_id)
	_wire_root.add_child(mi)


func _on_clear_selected_bind() -> void:
	if _selected_handle_id.is_empty():
		_status_lbl.text = "Select a bound 2D port first"
		return
	var idx := _port_index_for_handle(_selected_handle_id)
	if idx < 0:
		_status_lbl.text = "That port has no 3D bind"
		return
	_ports.remove_at(idx)
	_selected_port_idx = -1
	_refresh_handle_list()
	_rebuild_gizmos()
	_update_pending_banner()
	_status_lbl.text = "Cleared 3D bind for “%s”" % _selected_handle_id


func _on_save() -> void:
	var main := _scene_main()
	var ok := false
	if _save_catalog_chk.button_pressed:
		ok = ConnectionPortDefs.save_catalog_ports(_model_id, _ports) or ok
	if _save_instance_chk.button_pressed and not _prop_id.is_empty() and main != null:
		PlacedPropService.update_prop_record(main, _prop_id, {
			"connection_ports": _ports.duplicate(true),
		}, false)
		ok = true
		var prop := PlacedPropRuntime.find_by_prop_id(main, _prop_id)
		if prop != null:
			ConnectionPortDefs.sync_port_markers(prop, _ports)
	if not _item_id.is_empty() and main != null:
		var sgv := ServiceLocator.graph()
		if sgv != null:
			var mdl: GraphModel = sgv.get("model") as GraphModel
			if mdl != null:
				var item := mdl.get_item(_item_id)
				if not item.is_empty():
					var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
					var bindings: Dictionary = {}
					for p: Variant in _ports:
						if p is Dictionary:
							var hid := str((p as Dictionary).get("handle_id", ""))
							if not hid.is_empty():
								bindings[hid] = str((p as Dictionary).get("id", ""))
					specs["port_bindings"] = bindings
					mdl.update_item(_item_id, {"specs": specs})
	_status_lbl.text = "Saved %d binding(s)" % _ports.size() if ok else "Nothing to save"
	ports_saved.emit(_model_id, _prop_id)
