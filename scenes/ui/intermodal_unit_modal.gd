extends CanvasLayer
## Intermodal unit generator: pick a template (ISO container, pallet, IBC,
## gaylord, drum, rack bay), edit its real dimensions and ratings, see it
## built, save it to the user library (user://intermodal_units.json) and
## place it in the world. Every number comes from IntermodalUnits.resolve,
## the same entry the Packing Lab and the solver read.

signal closed

const MODAL_NAME := "intermodal_units"

var _list: ItemList
var _ids: Array = []          # parallel to the list rows ("" = header)
var _fields_box: VBoxContainer
var _stats: Label
var _name_edit: LineEdit
var _delete_btn: Button
var _status: Label

var _vp: SubViewport
var _cam: Camera3D
var _holder: Node3D
var _yaw: float = 0.7
var _pitch: float = -0.45
var _dist: float = 8.0
var _target: Vector3 = Vector3.ZERO
var _dragging: bool = false

var _template_id: String = ""
var _unit_id: String = ""     # "" = editing a template, else a user unit
var _params: Dictionary = {}
var _building_fields: bool = false


static func open(tree: SceneTree, preselect_id: String = "") -> Node:
	var m: Node = load("res://scenes/ui/intermodal_unit_modal.gd").new()
	tree.root.add_child(m)
	m.call("open_modal", preselect_id)
	m.connect("closed", Callable(m, "queue_free"))
	return m


func _ready() -> void:
	layer = UITheme.LAYER_MODAL
	_build_ui()


func open_modal(preselect_id: String = "") -> void:
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	HudLayout.claim_modal(MODAL_NAME)
	_refresh_list()
	var pick := preselect_id
	if pick.is_empty() and _ids.size() > 1:
		pick = str(_ids[1])
	_select_id(pick)


func close() -> void:
	if not visible:
		return
	visible = false
	CursorController.release_modal(MODAL_NAME)
	HudLayout.release(MODAL_NAME)
	closed.emit()


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()


# --- UI -------------------------------------------------------------------

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(UITheme.C_BG, 0.88)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 28
	panel.offset_top = 28
	panel.offset_right = -28
	panel.offset_bottom = -28
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	root.add_child(panel)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", UITheme.SPACE_MD)
	panel.add_child(hb)

	# Left: the templates and saved units.
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(260, 0)
	hb.add_child(left)
	var lt := Label.new()
	lt.text = "Units"
	lt.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	lt.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	left.add_child(lt)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_list_selected)
	left.add_child(_list)

	# Centre: the studio.
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	svc.mouse_filter = Control.MOUSE_FILTER_STOP
	svc.gui_input.connect(_on_studio_input)
	hb.add_child(svc)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.size = Vector2i(640, 480)
	svc.add_child(_vp)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.13, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.82, 0.86)
	env.ambient_light_energy = 0.7
	we.environment = env
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 32, 0)
	sun.light_energy = 1.1
	_vp.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	ground.mesh = pm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.22, 0.24, 0.26)
	ground.material_override = gmat
	_vp.add_child(ground)
	_holder = Node3D.new()
	_vp.add_child(_holder)
	_cam = Camera3D.new()
	_vp.add_child(_cam)
	_cam.current = true

	# Right: fields, stats, buttons.
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(360, 0)
	side.add_theme_constant_override("separation", UITheme.SPACE_SM)
	hb.add_child(side)
	var head := HBoxContainer.new()
	side.add_child(head)
	var title := Label.new()
	title.text = "Intermodal unit"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	head.add_child(title)
	head.add_child(IconButton.close(Callable(self, "close")))

	var nrow := HBoxContainer.new()
	side.add_child(nrow)
	var nl := Label.new()
	nl.text = "Name"
	nl.custom_minimum_size = Vector2(90, 0)
	nrow.add_child(nl)
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nrow.add_child(_name_edit)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(scroll)
	_fields_box = VBoxContainer.new()
	_fields_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_fields_box)

	_stats = Label.new()
	_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	side.add_child(_stats)

	var row := HBoxContainer.new()
	side.add_child(row)
	row.add_child(_btn("Save", _on_save))
	row.add_child(_btn("Save as new", _on_save_as))
	_delete_btn = _btn("Delete", _on_delete)
	row.add_child(_delete_btn)
	var row2 := HBoxContainer.new()
	side.add_child(row2)
	row2.add_child(_btn("Reset to template", _on_reset))
	row2.add_child(_btn("Place in world", _on_place))
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	side.add_child(_status)
	_update_camera()


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func _refresh_list() -> void:
	_list.clear()
	_ids.clear()
	for fam in IntermodalUnits.FAMILIES:
		var ts: Array = IntermodalUnits.templates_of(str(fam))
		if ts.is_empty():
			continue
		var hi := _list.add_item(str(IntermodalUnits.FAMILY_LABELS.get(fam, fam)))
		_list.set_item_selectable(hi, false)
		_list.set_item_custom_fg_color(hi, UITheme.C_TEXT_M)
		_ids.append("")
		for t in ts:
			_list.add_item("   " + str(t.get("label", "")))
			_ids.append(str(t.get("id", "")))
	var users: Array = IntermodalUnits.load_library()
	if not users.is_empty():
		var uh := _list.add_item("My units")
		_list.set_item_selectable(uh, false)
		_list.set_item_custom_fg_color(uh, UITheme.C_TEXT_M)
		_ids.append("")
		for u in users:
			_list.add_item("   " + str(u.get("label", "")))
			_ids.append(str(u.get("id", "")))


func _select_id(uid: String) -> void:
	var idx := _ids.find(uid)
	if idx < 0:
		return
	_list.select(idx)
	_load_unit(uid)


func _on_list_selected(idx: int) -> void:
	if idx >= 0 and idx < _ids.size() and not str(_ids[idx]).is_empty():
		_load_unit(str(_ids[idx]))


func _load_unit(uid: String) -> void:
	if not IntermodalUnits.template(uid).is_empty():
		_template_id = uid
		_unit_id = ""
		_params = IntermodalUnits.defaults(uid)
		_name_edit.text = str(IntermodalUnits.template(uid).get("label", ""))
	else:
		for u in IntermodalUnits.load_library():
			if str(u.get("id", "")) == uid:
				_template_id = str(u.get("template", ""))
				_unit_id = uid
				_params = IntermodalUnits.merged_params(_template_id,
					u.get("params", {}))
				_name_edit.text = str(u.get("label", ""))
	_delete_btn.disabled = _unit_id.is_empty()
	_build_fields()
	_rebuild_preview()


func _build_fields() -> void:
	_building_fields = true
	for c in _fields_box.get_children():
		_fields_box.remove_child(c)
		c.queue_free()
	var t := IntermodalUnits.template(_template_id)
	for key in t.get("fields", []):
		var k := str(key)
		var f: Dictionary = IntermodalUnits.FIELDS.get(k, {})
		var row := HBoxContainer.new()
		_fields_box.add_child(row)
		var l := Label.new()
		l.text = str(f.get("label", k))
		l.custom_minimum_size = Vector2(170, 0)
		l.clip_text = true
		row.add_child(l)
		var kind := str(f.get("kind", "m"))
		match kind:
			"bool":
				var cb := CheckBox.new()
				cb.button_pressed = bool(_params.get(k, false))
				cb.focus_mode = Control.FOCUS_NONE
				cb.toggled.connect(func(on: bool) -> void: _set_param(k, on))
				row.add_child(cb)
			"choice":
				var ob := OptionButton.new()
				var choices: Array = f.get("choices", [])
				for i in choices.size():
					ob.add_item(str(choices[i]), i)
					if str(choices[i]) == str(_params.get(k, "")):
						ob.select(i)
				ob.item_selected.connect(func(i: int) -> void:
					_set_param(k, str(choices[i])))
				row.add_child(ob)
			_:
				var sb := SpinBox.new()
				sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				sb.allow_greater = true
				match kind:
					"m":
						sb.min_value = 0.0
						sb.max_value = 20000.0
						sb.step = 1.0
						sb.suffix = "mm"
						sb.value = float(_params.get(k, 0.0)) * 1000.0
						sb.value_changed.connect(func(v: float) -> void:
							_set_param(k, v / 1000.0))
					"kg":
						sb.min_value = 0.0
						sb.max_value = 100000.0
						sb.step = 1.0
						sb.suffix = "kg"
						sb.value = float(_params.get(k, 0.0))
						sb.value_changed.connect(func(v: float) -> void:
							_set_param(k, v))
					"l":
						sb.min_value = 0.0
						sb.max_value = 100000.0
						sb.step = 1.0
						sb.suffix = "L"
						sb.value = float(_params.get(k, 0.0))
						sb.value_changed.connect(func(v: float) -> void:
							_set_param(k, v))
					_:
						sb.min_value = float(f.get("min", 0))
						sb.max_value = float(f.get("max", 100))
						sb.step = 1.0
						sb.value = float(_params.get(k, 0))
						sb.value_changed.connect(func(v: float) -> void:
							_set_param(k, int(v)))
				row.add_child(sb)
	var notes := str(t.get("notes", ""))
	if not notes.is_empty():
		var nl := Label.new()
		nl.text = notes
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		nl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		_fields_box.add_child(nl)
	_building_fields = false


func _set_param(key: String, value: Variant) -> void:
	if _building_fields:
		return
	_params[key] = value
	_rebuild_preview()


func _current_spec() -> Dictionary:
	return {"template": _template_id, "params": _params.duplicate(true),
		"label": _name_edit.text, "unit_id": _unit_id}


func _rebuild_preview() -> void:
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	if _template_id.is_empty():
		return
	var node := IntermodalUnitBuilder.build_node(_current_spec(), "Preview")
	_holder.add_child(node)
	var e := IntermodalUnits.resolve(_template_id, _params, _unit_id,
		_name_edit.text)
	var ext: Dictionary = e.get("exterior", {})
	var span := maxf(float(ext.get("l_m", 1.0)), maxf(float(ext.get("w_m", 1.0)),
		float(ext.get("h_m", 1.0))))
	_target = Vector3(0, float(ext.get("h_m", 1.0)) * 0.5, 0)
	_dist = clampf(span * 1.8 + 1.0, 1.5, 60.0)
	_update_camera()
	_stats.text = _stats_text(e)


func _stats_text(e: Dictionary) -> String:
	var lines: PackedStringArray = []
	var ext: Dictionary = e.get("exterior", {})
	var inn: Dictionary = e.get("interior", {})
	lines.append("Outside %s" % _dims(ext))
	if not inn.is_empty():
		lines.append("Inside / load space %s (%s)" % [_dims(inn),
			UiText.num(float(inn.get("l_m", 0.0)) * float(inn.get("w_m", 0.0))
				* float(inn.get("h_m", 0.0)), "m³", 3)])
	var door: Variant = e.get("door", null)
	if door is Dictionary:
		lines.append("Door %d × %d mm" % [roundi(float(door["w_m"]) * 1000.0),
			roundi(float(door["h_m"]) * 1000.0)])
	lines.append("Empty %s · payload %s" % [UiText.num(float(e.get("tare_kg", 0.0)), "kg", 3),
		UiText.num(float(e.get("payload_kg", 0.0)), "kg", 3)])
	if e.has("floor_kg_per_m"):
		lines.append("Floor %s per running metre" % UiText.num(
			float(e["floor_kg_per_m"]), "kg", 3))
	if e.has("fork_entry"):
		lines.append("Fork entry: %s" % str(e["fork_entry"]))
	if e.has("static_kg"):
		lines.append("Static %s · racked %s" % [UiText.num(float(e["static_kg"]), "kg", 3),
			UiText.num(float(e.get("rack_kg", 0.0)), "kg", 3)])
	return "\n".join(lines)


func _dims(d: Dictionary) -> String:
	return "%d × %d × %d mm" % [roundi(float(d.get("l_m", 0.0)) * 1000.0),
		roundi(float(d.get("w_m", 0.0)) * 1000.0),
		roundi(float(d.get("h_m", 0.0)) * 1000.0)]


# --- actions --------------------------------------------------------------

func _on_save() -> void:
	if _template_id.is_empty():
		return
	if _unit_id.is_empty():
		_on_save_as()
		return
	IntermodalUnits.save_user_unit(_template_id, _label_or_default(), _params, _unit_id)
	_status.text = "Saved %s." % _label_or_default()
	_refresh_list()
	_select_id(_unit_id)


func _on_save_as() -> void:
	if _template_id.is_empty():
		return
	var uid := IntermodalUnits.save_user_unit(_template_id, _label_or_default(), _params)
	_status.text = "Saved %s to your units." % _label_or_default()
	_refresh_list()
	_select_id(uid)


func _on_delete() -> void:
	if _unit_id.is_empty():
		return
	IntermodalUnits.remove_user_unit(_unit_id)
	_status.text = "Deleted %s." % _name_edit.text
	var tid := _template_id
	_refresh_list()
	_select_id(tid)


func _on_reset() -> void:
	if _template_id.is_empty():
		return
	_params = IntermodalUnits.defaults(_template_id)
	_build_fields()
	_rebuild_preview()


func _on_place() -> void:
	if _template_id.is_empty():
		return
	var tree := get_tree()
	var main: Node = tree.get_first_node_in_group("main_scene")
	if main == null:
		main = tree.current_scene
	var res: Dictionary = PlacedPropService.begin_placement(main,
		IntermodalUnitBuilder.MODEL_ID,
		{"record_extra": {"intermodal_spec": _current_spec()}})
	if bool(res.get("ok", false)):
		close()
	else:
		_status.text = "Could not place: %s" % str(res.get("error", "no world"))


func _label_or_default() -> String:
	var l := _name_edit.text.strip_edges()
	if l.is_empty():
		l = str(IntermodalUnits.template(_template_id).get("label", "Unit"))
	return l


# --- studio camera --------------------------------------------------------

func _on_studio_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = clampf(_dist * 0.9, 1.5, 60.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = clampf(_dist * 1.1, 1.5, 60.0)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		_update_camera()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.008
		_pitch = clampf(_pitch - mm.relative.y * 0.008, -1.35, -0.05)
		_update_camera()


func _update_camera() -> void:
	if _cam == null:
		return
	var rot := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	_cam.transform = Transform3D(rot, _target + rot * Vector3(0, 0, _dist))
