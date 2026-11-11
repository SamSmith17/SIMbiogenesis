extends CanvasLayer
## Intermodal unit designer: pick a template (ISO container, pallet, IBC,
## gaylord, drum, rack bay), edit its real dimensions and ratings, see it
## built in the studio, save it to the user library
## (user://intermodal_units.json) and place it in the world. Every number
## comes from IntermodalUnits.resolve, the same entry the Packing Lab and
## the solver read. On the kit since 2026-11-07: DesignerShell (the 720
## fold), StudioViewport (the one studio), FormRow rows.

signal closed

const MODAL_NAME := "intermodal_units"
const WANT := Vector2(1500, 920)

var _shell: DesignerShell = null
var _studio: StudioViewport = null
var _list: DesignGallery = null
var _col: DesignerColumn = null
var _ids: Array = []          # parallel to the list rows ("" = header)
var _fields_box: VBoxContainer = null
var _summary_box: VBoxContainer = null
var _notes: Label = null
var _status: Label = null
var _delete_btn: Button = null
var _doors_check: CheckButton = null
var _doors_open := false

var _template_id: String = ""
var _unit_id: String = ""     # "" = editing a template, else a user unit
var _params: Dictionary = {}
var _building_fields := false
var _open := false


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
	if _open:
		return
	_open = true
	visible = true
	HudLayout.claim_modal(MODAL_NAME)
	_shell.open()
	_refresh_list()
	var pick := preselect_id
	if pick.is_empty() and _ids.size() > 1:
		pick = str(_ids[1])
	_select_id(pick)


func close() -> void:
	if not _open:
		return
	if _shell.is_open():
		_shell.close()   # emits closed -> _on_shell_closed
	else:
		_on_shell_closed()


func _on_shell_closed() -> void:
	if not _open:
		return
	_open = false
	visible = false
	HudLayout.release(MODAL_NAME)
	closed.emit()


func is_open() -> bool:
	return _open


## The spec as the world and the library take it.
func current_spec() -> Dictionary:
	return _current_spec()


# --- UI -------------------------------------------------------------------

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_shell = DesignerShell.create("Intermodal unit designer", "package", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true,
		"left_label": "Units", "left_w": 250.0, "right_w": 380.0})
	root.add_child(_shell)
	_shell.closed.connect(_on_shell_closed)
	_shell.name_submitted.connect(func(_t: String) -> void: _refresh_summary())
	_shell.name_edit.placeholder_text = "Unit name"
	_build_left()
	_build_centre()
	_build_right()
	_shell.add_button("Reset to template", DesignerShell.SECONDARY, _on_reset,
		"Every field back to the standard's numbers")
	_delete_btn = _shell.add_button("Delete", DesignerShell.DESTRUCTIVE, _on_delete,
		"Remove this unit from your library")
	_shell.add_button("Save", DesignerShell.SECONDARY, _on_save,
		"Keep the edits on this unit (a template is saved as a new unit)")
	_shell.add_button("Save as new", DesignerShell.SECONDARY, _on_save_as,
		"Keep these numbers as a new unit in your library")
	var place := _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place,
		"Put one on the site where you aim")
	place.name = "place_world"
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_shell.set_hint("Pick a unit on the left · edit its numbers on the right · drag to orbit · wheel to zoom")


func _build_left() -> void:
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.left.add_child(box)
	box.add_child(SectionHeader.make("Templates and your units", "",
		"Real ISO, GMA, UN and RMI sizes; saved units keep your edits"))
	_list = DesignGallery.make("intermodal")
	_list.name = "unit_list"
	_list.set_thumbnailer(_thumb_for)
	_list.item_selected.connect(_on_list_selected)
	box.add_child(_list)


func _build_centre() -> void:
	_studio = StudioViewport.create({"ground": true, "person": true, "ssao": true})
	_studio.set_home(0.75, 0.32)
	_shell.centre.add_child(_studio)
	_doors_check = CheckButton.new()
	_doors_check.text = "Doors open"
	_doors_check.focus_mode = Control.FOCUS_NONE
	_doors_check.tooltip_text = "Swing a container's doors back along its sides"
	_doors_check.toggled.connect(func(on: bool) -> void:
		_doors_open = on
		_rebuild_preview())
	_studio.strip.add_child(_doors_check)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio.strip.add_child(spacer)
	var frame := IconButton.make("maximize-2", "Frame the unit", _frame)
	_studio.strip.add_child(frame)


func _build_right() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.right.add_child(box)
	box.add_child(SectionHeader.make("Dimensions and ratings", ""))
	_fields_box = VBoxContainer.new()
	_fields_box.add_theme_constant_override("separation", 2)
	box.add_child(_fields_box)
	_notes = Label.new()
	_notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notes.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_notes.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_notes)
	box.add_child(SectionHeader.make("What the solver sees", ""))
	_summary_box = VBoxContainer.new()
	_summary_box.add_theme_constant_override("separation", 2)
	box.add_child(_summary_box)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_status)
	_col = DesignerColumn.setup(box, "intermodal", {"fold": ["What the solver sees"], "finder": false, "tile_cols": 2})


func _refresh_list() -> void:
	_list.clear()
	_ids.clear()
	for fam in IntermodalUnits.FAMILIES:
		var ts: Array = IntermodalUnits.templates_of(str(fam))
		if ts.is_empty():
			continue
		_list.add_caption(str(IntermodalUnits.FAMILY_LABELS.get(fam, fam)))
		for t in ts:
			_list.add_item(str(t.get("label", "")))
			_ids.append(str(t.get("id", "")))
	var users: Array = IntermodalUnits.load_library()
	if not users.is_empty():
		for u in users:
			_list.add_item(DesignGallery.MINE_PREFIX + str(u.get("label", "")))
			_ids.append(str(u.get("id", "")))


## One unit's picture for the gallery: its key and how to build it.
func _thumb_for(i: int) -> Dictionary:
	if i < 0 or i >= _ids.size():
		return {}
	var uid := str(_ids[i])
	var spec := {"template": uid, "params": IntermodalUnits.defaults(uid), "label": "", "unit_id": ""}
	if IntermodalUnits.template(uid).is_empty():
		for u in IntermodalUnits.load_library():
			if str(u.get("id", "")) == uid:
				var tid := str(u.get("template", ""))
				spec = {"template": tid, "params": IntermodalUnits.merged_params(tid, u.get("params", {})),
					"label": "", "unit_id": uid}
	return {"key": JSON.stringify(spec), "build": func() -> Node3D:
		return IntermodalUnitBuilder.build_node(spec, "Thumb")}


func _select_id(uid: String) -> void:
	var idx := _ids.find(uid)
	if idx < 0:
		return
	_list.select(idx)
	_list.ensure_current_is_visible()
	_load_unit(uid)


func _on_list_selected(idx: int) -> void:
	if idx >= 0 and idx < _ids.size() and not str(_ids[idx]).is_empty():
		_load_unit(str(_ids[idx]))


func _load_unit(uid: String) -> void:
	if not IntermodalUnits.template(uid).is_empty():
		_template_id = uid
		_unit_id = ""
		_params = IntermodalUnits.defaults(uid)
		_shell.name_edit.text = str(IntermodalUnits.template(uid).get("label", ""))
	else:
		for u in IntermodalUnits.load_library():
			if str(u.get("id", "")) == uid:
				_template_id = str(u.get("template", ""))
				_unit_id = uid
				_params = IntermodalUnits.merged_params(_template_id,
					u.get("params", {}))
				_shell.name_edit.text = str(u.get("label", ""))
	_delete_btn.disabled = _unit_id.is_empty()
	var t := IntermodalUnits.template(_template_id)
	_shell.set_subtitle(str(IntermodalUnits.FAMILY_LABELS.get(str(t.get("family", "")), "")))
	_doors_check.visible = str(t.get("family", "")) == "container"
	_build_fields()
	_rebuild_preview()
	_frame()


func _build_fields() -> void:
	_building_fields = true
	for c in _fields_box.get_children():
		_fields_box.remove_child(c)
		c.queue_free()
	var t := IntermodalUnits.template(_template_id)
	for key in t.get("fields", []):
		var k := str(key)
		var f: Dictionary = IntermodalUnits.FIELDS.get(k, {})
		var label := str(f.get("label", k))
		var kind := str(f.get("kind", "m"))
		var row: FormRow = null
		match kind:
			"bool":
				row = FormRow.check(label, "", func(on: bool) -> void: _set_param(k, on), "", k)
				(row.control as CheckBox).button_pressed = bool(_params.get(k, false))
			"choice":
				var items: Array = []
				for ch in f.get("choices", []):
					items.append([str(ch), str(ch).capitalize()])
				row = FormRow.option(label, items, func(v: Variant) -> void: _set_param(k, str(v)), "", k)
				FormRow.select_meta(row.control as OptionButton, str(_params.get(k, "")))
			"m":
				row = FormRow.spin(label, 0.0, 20000.0, 1.0, "mm",
					func(v: float) -> void: _set_param(k, v / 1000.0), "", k)
				(row.control as SpinBox).allow_greater = true
				row.set_value(float(_params.get(k, 0.0)) * 1000.0)
			"kg", "l":
				row = FormRow.spin(label, 0.0, 100000.0, 1.0, kind.to_upper() if kind == "l" else "kg",
					func(v: float) -> void: _set_param(k, v), "", k)
				(row.control as SpinBox).allow_greater = true
				row.set_value(float(_params.get(k, 0.0)))
			_:
				row = FormRow.spin(label, float(f.get("min", 0)), float(f.get("max", 100)), 1.0, "",
					func(v: float) -> void: _set_param(k, int(v)), "", k)
				row.set_value(float(_params.get(k, 0)))
		_fields_box.add_child(row)
	_notes.text = str(t.get("notes", ""))
	_building_fields = false


func _set_param(key: String, value: Variant) -> void:
	if _building_fields:
		return
	_params[key] = value
	_rebuild_preview()


func _current_spec() -> Dictionary:
	return {"template": _template_id, "params": _params.duplicate(true),
		"label": _shell.name_edit.text, "unit_id": _unit_id}


func _preview_spec() -> Dictionary:
	var s := _current_spec()
	if _doors_open:
		s["doors_open_deg"] = CargoContainerBuilder.DOORS_FOLDED_DEG
	return s


func _rebuild_preview() -> void:
	if _template_id.is_empty():
		_studio.clear()
		return
	var node := IntermodalUnitBuilder.build_node(_preview_spec(), "Preview")
	_studio.show_node(node)
	_refresh_summary()


func _frame() -> void:
	if _template_id.is_empty():
		return
	var e := IntermodalUnits.resolve(_template_id, _params, _unit_id, _shell.name_edit.text)
	var ext: Dictionary = e.get("exterior", {})
	var l := float(ext.get("l_m", 1.0))
	var w := float(ext.get("w_m", 1.0))
	var h := float(ext.get("h_m", 1.0))
	_studio.reset_orbit()
	_studio.frame_aabb(AABB(Vector3(-w * 0.5, 0.0, -l * 0.5), Vector3(w, h, l)), 0.45, 1.35)
	_studio.place_person(maxf(w, l) * 0.5 + 0.3)


func _refresh_summary() -> void:
	for c in _summary_box.get_children():
		_summary_box.remove_child(c)
		c.queue_free()
	if _template_id.is_empty():
		return
	var e := IntermodalUnits.resolve(_template_id, _params, _unit_id, _shell.name_edit.text)
	var ext: Dictionary = e.get("exterior", {})
	var inn: Dictionary = e.get("interior", {})
	if _col != null:
		var vol := float(inn.get("l_m", 0.0)) * float(inn.get("w_m", 0.0)) * float(inn.get("h_m", 0.0))
		_col.set_tiles([
			{"caption": "Outside", "value": _dims(ext), "tip": "Length × width × height"},
			{"caption": "Load space", "value": UiText.num(vol, "m³", 3) if not inn.is_empty() else "Open",
				"tip": _dims(inn) if not inn.is_empty() else "Nothing encloses the load"},
			{"caption": "Payload", "value": UiText.num(float(e.get("payload_kg", 0.0)), "kg", 3), "tip": "What it may carry"},
			{"caption": "Empty", "value": UiText.num(float(e.get("tare_kg", 0.0)), "kg", 3), "tip": "Tare weight"}])
	_add_kv("Outside", _dims(ext), "Length × width × height")
	if not inn.is_empty():
		var vol := float(inn.get("l_m", 0.0)) * float(inn.get("w_m", 0.0)) * float(inn.get("h_m", 0.0))
		_add_kv("Load space", _dims(inn), "What the solver fills")
		_add_kv("Volume", UiText.num(vol, "m³", 3), "")
	var door: Variant = e.get("door", null)
	if door is Dictionary:
		_add_kv("Door", "%d × %d mm" % [roundi(float(door["w_m"]) * 1000.0),
			roundi(float(door["h_m"]) * 1000.0)], "Fitting the volume is not fitting through the opening")
	elif str(e.get("family", "")) == "container":
		_add_kv("Door", "none (loaded from above)", "")
	_add_kv("Empty", UiText.num(float(e.get("tare_kg", 0.0)), "kg", 3), "")
	_add_kv("Payload", UiText.num(float(e.get("payload_kg", 0.0)), "kg", 3), "")
	if e.has("floor_kg_per_m"):
		_add_kv("Floor", "%s per running metre" % UiText.num(float(e["floor_kg_per_m"]), "kg", 3), "")
	if e.has("fork_entry"):
		_add_kv("Fork entry", str(e["fork_entry"]), "")
	if e.has("static_kg"):
		_add_kv("Static", UiText.num(float(e["static_kg"]), "kg", 3), "Stacked on the ground")
		_add_kv("Racked", UiText.num(float(e.get("rack_kg", 0.0)), "kg", 3), "On beams, unsupported underneath")
	if e.has("volume_l"):
		_add_kv("Liquid", UiText.num(float(e["volume_l"]), "L", 3), "")
	if e.has("levels"):
		_add_kv("Levels", UiText.count(int(e["levels"]), "beam level"), "")
	var packed := IntermodalUnits.packed_spec_for(e)
	if not packed.is_empty():
		_add_kv("Ships as", PackedSpec.format_dims_short(packed), "The empty unit itself, as cargo")


func _add_kv(k: String, v: String, tip: String) -> void:
	_summary_box.add_child(FormRow.value(k, v, tip))


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
	_status.text = "Deleted %s." % _shell.name_edit.text
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
	var l := _shell.name_edit.text.strip_edges()
	if l.is_empty():
		l = str(IntermodalUnits.template(_template_id).get("label", "Unit"))
	return l
