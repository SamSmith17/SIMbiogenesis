class_name ModelLightPanel
extends VBoxContainer

## Embeddable Lights & Strings editor for any 3D designer modal.
##
## Drop into a modal's right-hand column under `SectionHeader.make("Lighting", "")`:
##   - Renders live OmniLight3D, SpotLight3D and sagging string / rope lights
##     inside the modal's 3D studio (`attach_preview(model_root)`).
##   - Lets the player click surfaces on the 3D model to place Omni, Spot or
##     multi-pin String lights (`handle_viewport_event(...)`), or add model-aware
##     one-click rigs (perimeter ring, bay bulbs, ridge string, porch festoon…).
##   - Provides a `make_night_toggle(...)` button for the studio strip so the
##     player can preview the structure lit in the dark before placing/applying.
##   - Outputs local model-space items (`items()`) that `PropModelLights` writes
##     into J Light Studio's `PlacedLightLayer` hosted on the prop, so moving the
##     prop carries them and pressing J outside the modal edits them directly.

signal lights_changed
signal auto_toggle_changed(on: bool)

const DRAG_PX := 6.0
const DOUBLE_CLICK_MS := 550

var model_id: String = ""
var _spec: Dictionary = {}
var _items: Array = []
var _selected_idx: int = -1
var _tool: String = "select"   # "select" | "omni" | "spot" | "string"
var _string_pts: Array = []    # Array[Vector3] in model_root local space
var _preview_host: Node3D = null
var _syncing := false

# Viewport click tracking
var _press_pos := Vector2.ZERO
var _pressed_lmb := false
var _last_click_ms := -100000

# UI widgets
var _auto_chk: CheckBox = null
var _tool_btns: Dictionary = {}
var _string_bar: HBoxContainer = null
var _finish_btn: Button = null
var _undo_pin_btn: Button = null
var _cancel_str_btn: Button = null
var _quick_flow: HFlowContainer = null
var _hint_lbl: Label = null
var _pick_bar: HBoxContainer = null
var _item_opt: OptionButton = null
var _del_item_btn: Button = null
var _insp_card: PanelContainer = null
var _preset_opt: OptionButton = null
var _preset_ids: Array = []
var _color_btn: ColorPickerButton = null
var _sched_opt: OptionButton = null
var _energy_spin: SpinBox = null
var _range_row: FormRow = null
var _range_spin: SpinBox = null
var _pos_spins: Dictionary = {}
var _bulb_row: FormRow = null
var _bulb_chk: CheckBox = null

# Studio night-mode state
var _night_on := false
var _night_target: Node = null
var _night_chk: CheckBox = null
var _saved_studio: Dictionary = {}


func _init() -> void:
	name = "ModelLightPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", UITheme.SPACE_XS)
	_build_ui()


## Configure an optional parametric auto-lights checkbox at the top of the panel
## (e.g. "Peak omni light", "Warm ceiling bulb in every room", "Light in each stall").
func configure_auto_toggle(label_text: String, tip_text: String) -> void:
	_auto_chk.text = label_text
	_auto_chk.tooltip_text = tip_text
	_auto_chk.visible = not label_text.is_empty()


func set_auto_pressed(on: bool) -> void:
	if _auto_chk != null:
		_auto_chk.set_pressed_no_signal(on)


## Load items for `(p_model_id, spec)` — pass `prop_id` and `main` when bound to
## an already-placed prop so live J edits are read back into the modal.
func load_from_context(main: Node, prop_id: String, p_model_id: String, spec: Dictionary) -> void:
	model_id = p_model_id
	_spec = spec.duplicate(true)
	_string_pts.clear()
	_set_tool("select")
	_items = PropModelLights.read_for_modal(main, prop_id, model_id, _spec)
	_selected_idx = 0 if not _items.is_empty() else -1
	_rebuild_quick_buttons()
	_refresh_ui()
	_rebuild_preview_nodes()


## Call when parametric dimensions / room count / stall count / bed layout /
## greenhouse spectrum or schedule changed in the host modal.
func sync_with_spec(spec: Dictionary, already_seeded: Array = [], force_gh_look: bool = false) -> void:
	_spec = spec.duplicate(true)
	_items = PropModelLights.sync_parametric_slots(_items, model_id, _spec, already_seeded, force_gh_look)
	if _selected_idx >= _items.size():
		_selected_idx = _items.size() - 1
	_rebuild_quick_buttons()
	_refresh_ui()
	_rebuild_preview_nodes()


func items() -> Array:
	return _items.duplicate(true)


func serialized_items() -> Array:
	return PropModelLights.serialize_for_spec(_items)


func summary_text() -> String:
	if _items.is_empty():
		return "none"
	var n_str := 0
	var n_pt := 0
	for it in _items:
		if str((it as Dictionary).get("kind", "")) == "string":
			n_str += 1
		else:
			n_pt += 1
	var parts: PackedStringArray = PackedStringArray()
	if n_pt > 0:
		parts.append(UiText.count(n_pt, "light"))
	if n_str > 0:
		parts.append(UiText.count(n_str, "string"))
	return " · ".join(parts)


func active_tool() -> String:
	return _tool


## Add a light item programmatically (used by tests and quick presets).
func add_item(item: Dictionary) -> int:
	_items.append(PropModelLights.normalize_local_item(item))
	_selected_idx = _items.size() - 1
	_refresh_ui()
	_rebuild_preview_nodes()
	lights_changed.emit()
	return _selected_idx


func remove_item_at(index: int) -> void:
	if index < 0 or index >= _items.size():
		return
	_items.remove_at(index)
	if _selected_idx >= _items.size():
		_selected_idx = _items.size() - 1
	_refresh_ui()
	_rebuild_preview_nodes()
	lights_changed.emit()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_auto_chk = CheckBox.new()
	_auto_chk.name = "auto_lights_toggle"
	_auto_chk.visible = false
	_auto_chk.focus_mode = Control.FOCUS_NONE
	_auto_chk.toggled.connect(func(on: bool) -> void:
		if not _syncing:
			auto_toggle_changed.emit(on))
	add_child(_auto_chk)

	_night_chk = CheckBox.new()
	_night_chk.name = "night_preview_toggle"
	_night_chk.text = "Night preview in studio"
	_night_chk.tooltip_text = "Dim the 3D studio to night so you can see how the lights and strings illuminate the model"
	_night_chk.visible = false
	_night_chk.focus_mode = Control.FOCUS_NONE
	_night_chk.toggled.connect(func(on: bool) -> void:
		if _night_target != null:
			set_studio_night(_night_target, on))
	add_child(_night_chk)

	var tools := HFlowContainer.new()
	tools.add_theme_constant_override("h_separation", 4)
	tools.add_theme_constant_override("v_separation", 4)
	add_child(tools)
	for td in [
		["select", "Select", "Orbit and click an existing light or string pin to inspect it"],
		["omni", "+ Omni", "Click any surface on the 3D model to hang a point light"],
		["spot", "+ Spot", "Click a surface on the 3D model to mount an aimed spot light"],
		["string", "+ String", "Click 2 or more points on the 3D model to string bulbs or LED tube; Finish or double-click ends it"],
	]:
		var b := Button.new()
		b.name = "tool_" + str(td[0])
		b.text = str(td[1])
		b.tooltip_text = str(td[2])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		var tid := str(td[0])
		b.pressed.connect(func() -> void: _set_tool(tid))
		tools.add_child(b)
		_tool_btns[tid] = b

	_string_bar = HBoxContainer.new()
	_string_bar.add_theme_constant_override("separation", 4)
	_string_bar.visible = false
	add_child(_string_bar)
	_finish_btn = Button.new()
	_finish_btn.name = "finish_string"
	_finish_btn.text = "Finish string"
	_finish_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(_finish_btn)
	_finish_btn.pressed.connect(finish_string)
	_string_bar.add_child(_finish_btn)
	_undo_pin_btn = Button.new()
	_undo_pin_btn.text = "Undo pin"
	_undo_pin_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(_undo_pin_btn)
	_undo_pin_btn.pressed.connect(_undo_last_pin)
	_string_bar.add_child(_undo_pin_btn)
	_cancel_str_btn = Button.new()
	_cancel_str_btn.text = "Cancel"
	_cancel_str_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(_cancel_str_btn)
	_cancel_str_btn.pressed.connect(func() -> void: _set_tool("select"))
	_string_bar.add_child(_cancel_str_btn)

	_quick_flow = HFlowContainer.new()
	_quick_flow.name = "quick_lights"
	_quick_flow.add_theme_constant_override("h_separation", 4)
	_quick_flow.add_theme_constant_override("v_separation", 4)
	add_child(_quick_flow)

	_hint_lbl = Label.new()
	_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hint_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	add_child(_hint_lbl)

	_pick_bar = HBoxContainer.new()
	_pick_bar.name = "light_list"
	_pick_bar.add_theme_constant_override("separation", 4)
	add_child(_pick_bar)
	_item_opt = OptionButton.new()
	_item_opt.name = "selected_light_opt"
	_item_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_item_opt.fit_to_longest_item = false
	_item_opt.clip_text = true
	_item_opt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_item_opt.focus_mode = Control.FOCUS_NONE
	_item_opt.item_selected.connect(func(idx: int) -> void:
		if not _syncing and idx >= 0 and idx < _items.size():
			_selected_idx = idx
			_refresh_ui()
			_rebuild_preview_nodes())
	_pick_bar.add_child(_item_opt)
	_del_item_btn = IconButton.make("trash-2", "Remove the selected light or string", func() -> void:
		if _selected_idx >= 0 and _selected_idx < _items.size():
			remove_item_at(_selected_idx))
	_del_item_btn.name = "delete_selected_light"
	_pick_bar.add_child(_del_item_btn)

	_insp_card = PanelContainer.new()
	_insp_card.add_theme_stylebox_override("panel", UITheme.card_style())
	add_child(_insp_card)
	var im := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		im.add_theme_constant_override("margin_" + side, UITheme.SPACE_XS)
	_insp_card.add_child(im)
	var ib := VBoxContainer.new()
	ib.add_theme_constant_override("separation", 4)
	im.add_child(ib)

	_preset_opt = OptionButton.new()
	_preset_opt.focus_mode = Control.FOCUS_NONE
	_preset_opt.item_selected.connect(_on_preset_picked)
	ib.add_child(FormRow.make("Preset", _preset_opt, "Look preset for this fixture or string", "", "light_preset"))

	_color_btn = ColorPickerButton.new()
	_color_btn.edit_alpha = false
	_color_btn.custom_minimum_size = Vector2(44, 24)
	_color_btn.color_changed.connect(_on_color_changed)
	ib.add_child(FormRow.make("Colour", _color_btn, "Light tint", "", "light_color"))

	_sched_opt = OptionButton.new()
	_sched_opt.focus_mode = Control.FOCUS_NONE
	_sched_opt.add_item("Sunset to sunrise")
	_sched_opt.set_item_metadata(0, "dusk_dawn")
	_sched_opt.add_item("Always on")
	_sched_opt.set_item_metadata(1, "always")
	_sched_opt.item_selected.connect(_on_schedule_picked)
	ib.add_child(FormRow.make("On", _sched_opt, "When this light illuminates in the world", "", "light_schedule"))

	var r_en := FormRow.spin("Intensity", 0.0, 40.0, 0.05, "", _on_energy_changed, "", "light_energy")
	_energy_spin = r_en.control as SpinBox
	ib.add_child(r_en)

	_range_row = FormRow.spin("Range", 0.0, 120.0, 0.25, " m", _on_range_or_sag_changed, "", "light_range")
	_range_spin = _range_row.control as SpinBox
	ib.add_child(_range_row)

	for ax in [["x", "Local X"], ["y", "Local Y"], ["z", "Local Z"]]:
		var pr := FormRow.spin(str(ax[1]), -200.0, 200.0, 0.05, " m",
			func(_v: float) -> void: _on_pos_changed(), "Model-local position in metres", "pos_" + str(ax[0]))
		_pos_spins[str(ax[0])] = pr.control as SpinBox
		ib.add_child(pr)

	_bulb_row = FormRow.check("Fixture", "Show bulb", _on_bulb_toggled, "Draw a physical glowing bulb sphere", "light_bulb")
	_bulb_chk = _bulb_row.control as CheckBox
	ib.add_child(_bulb_row)

	_set_tool("select")


func _row(parent: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	parent.add_child(h)
	return h


func _lbl(text: String, parent: Control, min_w: float = 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	if min_w > 0.0:
		l.custom_minimum_size.x = min_w
	parent.add_child(l)
	return l


func _spin(step_v: float, lo: float, hi: float, suffix_s: String, parent: Control, cb: Callable) -> SpinBox:
	var sb := SpinBox.new()
	sb.step = step_v
	sb.min_value = lo
	sb.max_value = hi
	sb.allow_greater = true
	sb.allow_lesser = lo < 0.0
	sb.suffix = suffix_s
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.custom_minimum_size.x = 52.0
	sb.get_line_edit().add_theme_font_size_override("font_size", UITheme.FONT_XS)
	sb.value_changed.connect(cb)
	parent.add_child(sb)
	return sb


# ---------------------------------------------------------------------------
# Tool state & string pinning
# ---------------------------------------------------------------------------

func _set_tool(t: String) -> void:
	if t != "string":
		_string_pts.clear()
	_tool = t
	for k in _tool_btns:
		(_tool_btns[k] as Button).set_pressed_no_signal(k == _tool)
	_update_string_bar()
	_rebuild_preview_nodes()


func _update_string_bar() -> void:
	if _string_bar == null:
		return
	_string_bar.visible = _tool == "string"
	if _finish_btn != null:
		_finish_btn.disabled = _string_pts.size() < 2
		_finish_btn.text = "Finish (%d)" % _string_pts.size() if not _string_pts.is_empty() else "Finish string"
	if _undo_pin_btn != null:
		_undo_pin_btn.disabled = _string_pts.is_empty()
	if _hint_lbl != null:
		match _tool:
			"omni":
				_hint_lbl.text = "Click any surface on the 3D model to place an omni light (RMB orbits)."
			"spot":
				_hint_lbl.text = "Click a surface on the 3D model to place an aimed spot light."
			"string":
				_hint_lbl.text = "Click points on the 3D model to pin a string (%d placed) · Finish or double-click ends it." % _string_pts.size()
			_:
				_hint_lbl.text = "Attached lights move with the prop and stay editable with J in the world."


func finish_string() -> void:
	if _string_pts.size() < 2:
		return
	var pts := _string_pts.duplicate()
	_string_pts.clear()
	var n_str := 1
	for it in _items:
		if str((it as Dictionary).get("kind", "")) == "string":
			n_str += 1
	var item := PropModelLights.make_local_string("", "String %d" % n_str, pts, "patio")
	_items.append(item)
	_selected_idx = _items.size() - 1
	_set_tool("select")
	_refresh_ui()
	_rebuild_preview_nodes()
	lights_changed.emit()


func _undo_last_pin() -> void:
	if not _string_pts.is_empty():
		_string_pts.pop_back()
		_update_string_bar()
		_rebuild_preview_nodes()


# ---------------------------------------------------------------------------
# Quick-add buttons & list / inspector refresh
# ---------------------------------------------------------------------------

func _rebuild_quick_buttons() -> void:
	if _quick_flow == null:
		return
	for c in _quick_flow.get_children():
		_quick_flow.remove_child(c)
		c.queue_free()
	var bb := PropModelLights.model_bounds(_preview_host) if _preview_host != null and is_instance_valid(_preview_host) else AABB()
	var presets := PropModelLights.quick_presets_for(model_id, _spec, bb)
	_quick_flow.visible = not presets.is_empty()
	for p in presets:
		var pd: Dictionary = p
		var b := Button.new()
		b.name = "quick_" + str(pd.get("id", "add"))
		b.text = str(pd.get("label", "+ Light"))
		b.tooltip_text = str(pd.get("tip", ""))
		b.focus_mode = Control.FOCUS_NONE
		UITheme.style_button(b)
		var maker: Callable = pd["make"]
		b.pressed.connect(func() -> void:
			var made: Array = maker.call()
			if made.is_empty():
				return
			for m_it in made:
				_items.append(PropModelLights.normalize_local_item(m_it as Dictionary))
			_selected_idx = _items.size() - 1
			_refresh_ui()
			_rebuild_preview_nodes()
			lights_changed.emit())
		_quick_flow.add_child(b)


func _refresh_ui() -> void:
	if _item_opt == null:
		return
	_syncing = true
	_item_opt.clear()
	for i in _items.size():
		var it: Dictionary = _items[i]
		var kind := str(it.get("kind", "omni"))
		var nm := str(it.get("name", ""))
		if nm.is_empty():
			nm = "%s %d" % [kind.capitalize(), i + 1]
		var sched := str((it.get("fields", {}) as Dictionary).get("schedule", "always"))
		_item_opt.add_item("%s (%s · %s)" % [nm, kind, "sunset–sunrise" if sched == "dusk_dawn" else "always"])
	_pick_bar.visible = not _items.is_empty()
	if _selected_idx >= 0 and _selected_idx < _items.size():
		_item_opt.select(_selected_idx)
	_syncing = false

	_insp_card.visible = _selected_idx >= 0 and _selected_idx < _items.size()
	if not _insp_card.visible:
		return
	_syncing = true
	var cur: Dictionary = _items[_selected_idx]
	var ckind := str(cur.get("kind", "omni"))
	var fields: Dictionary = cur.get("fields", {})
	_preset_opt.clear()
	_preset_ids.clear()
	_preset_opt.add_item("Custom")
	_preset_ids.append("")
	var order: Array = PlacedLightStyles.PRESET_ORDER.get(ckind, [])
	var cur_preset := str(cur.get("preset", fields.get("preset", "")))
	var pick_idx := 0
	for pid in order:
		var ps := str(pid)
		_preset_opt.add_item(PlacedLightStyles.preset_label(ckind, ps))
		_preset_ids.append(ps)
		if ps == cur_preset:
			pick_idx = _preset_ids.size() - 1
	_preset_opt.select(pick_idx)
	_color_btn.color = PlacedLightPower.parse_color(str(fields.get("color", "ffffff")))
	var sch := str(fields.get("schedule", "always"))
	_sched_opt.select(0 if sch == "dusk_dawn" else 1)
	_energy_spin.set_value_no_signal(float(fields.get("energy", 1.0)))
	if ckind == "string":
		_range_row.label.text = "Sag"
		_range_spin.suffix = ""
		_range_spin.step = 0.02
		_range_spin.max_value = 1.5
		_range_spin.set_value_no_signal(float(fields.get("sag", 0.25)))
	else:
		_range_row.label.text = "Range"
		_range_spin.suffix = " m"
		_range_spin.step = 0.5
		_range_spin.max_value = 120.0
		_range_spin.set_value_no_signal(float(fields.get("range", 8.0)))
	for ax in ["x", "y", "z"]:
		(_pos_spins[ax] as SpinBox).set_value_no_signal(float(cur.get(ax, 0.0)))
	_bulb_row.visible = ckind != "string"
	_bulb_chk.set_pressed_no_signal(bool(fields.get("show_body", false)))
	_syncing = false


# ---------------------------------------------------------------------------
# Inspector callbacks
# ---------------------------------------------------------------------------

func _on_preset_picked(idx: int) -> void:
	if _syncing or _selected_idx < 0 or _selected_idx >= _items.size():
		return
	var pid := str(_preset_ids[idx]) if idx >= 0 and idx < _preset_ids.size() else ""
	if pid.is_empty():
		return
	var cur: Dictionary = _items[_selected_idx]
	var kind := str(cur["kind"])
	var keep_sched := str((cur["fields"] as Dictionary).get("schedule", ""))
	var pf := PlacedLightStyles.preset_fields(pid, kind)
	cur["preset"] = pid
	cur["fields"] = PlacedLightStyles.resolve(kind, pf, {})
	if not pf.has("schedule") and not keep_sched.is_empty():
		(cur["fields"] as Dictionary)["schedule"] = keep_sched
	_refresh_ui()
	_rebuild_preview_nodes()
	lights_changed.emit()


func _on_color_changed(c: Color) -> void:
	if _syncing or _selected_idx < 0 or _selected_idx >= _items.size():
		return
	var cur: Dictionary = _items[_selected_idx]
	(cur["fields"] as Dictionary)["color"] = c.to_html(false)
	_rebuild_preview_nodes()
	lights_changed.emit()


func _on_schedule_picked(idx: int) -> void:
	if _syncing or _selected_idx < 0 or _selected_idx >= _items.size():
		return
	var sch := str(_sched_opt.get_item_metadata(idx))
	var cur: Dictionary = _items[_selected_idx]
	(cur["fields"] as Dictionary)["schedule"] = sch
	_refresh_ui()
	lights_changed.emit()


func _on_energy_changed(v: float) -> void:
	if _syncing or _selected_idx < 0 or _selected_idx >= _items.size():
		return
	var cur: Dictionary = _items[_selected_idx]
	(cur["fields"] as Dictionary)["energy"] = v
	_rebuild_preview_nodes()
	lights_changed.emit()


func _on_range_or_sag_changed(v: float) -> void:
	if _syncing or _selected_idx < 0 or _selected_idx >= _items.size():
		return
	var cur: Dictionary = _items[_selected_idx]
	if str(cur["kind"]) == "string":
		(cur["fields"] as Dictionary)["sag"] = clampf(v, 0.0, 1.5)
	else:
		(cur["fields"] as Dictionary)["range"] = maxf(v, 0.5)
	_rebuild_preview_nodes()
	lights_changed.emit()


func _on_pos_changed() -> void:
	if _syncing or _selected_idx < 0 or _selected_idx >= _items.size():
		return
	var cur: Dictionary = _items[_selected_idx]
	var nx := (_pos_spins["x"] as SpinBox).value
	var ny := (_pos_spins["y"] as SpinBox).value
	var nz := (_pos_spins["z"] as SpinBox).value
	if str(cur["kind"]) == "string":
		var delta := Vector3(nx - float(cur["x"]), ny - float(cur["y"]), nz - float(cur["z"]))
		for w in cur["waypoints"]:
			var wd := w as Dictionary
			wd["x"] = snappedf(float(wd["x"]) + delta.x, 0.001)
			wd["y"] = snappedf(float(wd["y"]) + delta.y, 0.001)
			wd["z"] = snappedf(float(wd["z"]) + delta.z, 0.001)
	cur["x"] = snappedf(nx, 0.001)
	cur["y"] = snappedf(ny, 0.001)
	cur["z"] = snappedf(nz, 0.001)
	_rebuild_preview_nodes()
	lights_changed.emit()


func _on_bulb_toggled(on: bool) -> void:
	if _syncing or _selected_idx < 0 or _selected_idx >= _items.size():
		return
	var cur: Dictionary = _items[_selected_idx]
	(cur["fields"] as Dictionary)["show_body"] = on
	_rebuild_preview_nodes()
	lights_changed.emit()


# ---------------------------------------------------------------------------
# 3D Studio preview rendering & interactive surface clicking
# ---------------------------------------------------------------------------

## Attach / refresh the 3D light preview under `model_root` (the node whose
## local frame matches `ModelRoot` in the world).
func attach_preview(model_root: Node3D) -> void:
	var new_host := _preview_host != model_root
	_preview_host = model_root
	if new_host and _quick_flow != null and _quick_flow.get_child_count() == 0:
		_rebuild_quick_buttons()
	_rebuild_preview_nodes()


func _rebuild_preview_nodes() -> void:
	if _preview_host == null or not is_instance_valid(_preview_host):
		return
	var old := _preview_host.get_node_or_null("ModelLightsPreview")
	if old != null:
		_preview_host.remove_child(old)
		old.queue_free()
	var holder := Node3D.new()
	holder.name = "ModelLightsPreview"
	holder.set_meta("studio_no_frame", true)
	_preview_host.add_child(holder)

	for i in _items.size():
		var it: Dictionary = _items[i]
		if not bool(it.get("enabled", true)):
			continue
		var sel := (i == _selected_idx)
		if str(it.get("kind", "omni")) == "string":
			_build_preview_string(holder, it, sel)
		else:
			_build_preview_point(holder, it, sel)

	if _tool == "string" and not _string_pts.is_empty():
		var pin_mat := StandardMaterial3D.new()
		pin_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pin_mat.albedo_color = Color(0.2, 0.9, 1.0)
		pin_mat.no_depth_test = true
		for p in _string_pts:
			var sp := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.08
			sm.height = 0.16
			sp.mesh = sm
			sp.position = p as Vector3
			sp.material_override = pin_mat
			sp.set_meta("studio_no_frame", true)
			holder.add_child(sp)
		if _string_pts.size() >= 2:
			var samples := PackedVector3Array()
			for p2 in _string_pts:
				samples.append(p2 as Vector3)
			var wire := MeshInstance3D.new()
			wire.mesh = LightStringGeometry.build_tube(samples, 0.012, 6)
			wire.material_override = pin_mat
			wire.set_meta("studio_no_frame", true)
			holder.add_child(wire)


func _build_preview_point(holder: Node3D, it: Dictionary, selected: bool) -> void:
	var fields: Dictionary = it.get("fields", {})
	var col := PlacedLightPower.parse_color(str(fields.get("color", "ffffff")))
	var energy := float(fields.get("energy", 1.2))
	var rng := maxf(float(fields.get("range", 8.0)), 0.5)
	var kind := str(it.get("kind", "omni"))
	var n := Node3D.new()
	n.position = Vector3(float(it["x"]), float(it["y"]), float(it["z"]))
	n.rotation_degrees = Vector3(float(it.get("pitch", 0.0)), float(it.get("yaw", 0.0)), float(it.get("roll", 0.0)))
	n.set_meta("studio_no_frame", true)
	holder.add_child(n)

	var light: Light3D
	if kind == "spot" or kind == "mover":
		var sp := SpotLight3D.new()
		sp.spot_range = rng
		sp.spot_angle = clampf(float(fields.get("spot_angle", 35.0)), 2.0, 88.0)
		sp.spot_attenuation = float(fields.get("attenuation", 1.0))
		light = sp
	else:
		var om := OmniLight3D.new()
		om.omni_range = rng
		om.omni_attenuation = float(fields.get("attenuation", 1.0))
		light = om
	light.light_color = col
	light.light_energy = energy
	light.shadow_enabled = false
	n.add_child(light)

	var bulb := MeshInstance3D.new()
	var bs := SphereMesh.new()
	var r := 0.075 if bool(fields.get("show_body", true)) else 0.055
	bs.radius = r
	bs.height = r * 2.0
	bs.radial_segments = 12
	bs.rings = 6
	bulb.mesh = bs
	bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bm := StandardMaterial3D.new()
	bm.albedo_color = col
	bm.emission_enabled = true
	bm.emission = col
	bm.emission_energy_multiplier = 2.8
	bulb.material_override = bm
	bulb.set_meta("studio_no_frame", true)
	n.add_child(bulb)

	if selected:
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.13
		tm.outer_radius = 0.165
		ring.mesh = tm
		var rm := StandardMaterial3D.new()
		rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rm.albedo_color = Color(1.0, 0.72, 0.15)
		rm.no_depth_test = true
		ring.material_override = rm
		ring.set_meta("studio_no_frame", true)
		n.add_child(ring)


func _build_preview_string(holder: Node3D, it: Dictionary, selected: bool) -> void:
	var fields: Dictionary = it.get("fields", {})
	var pts: Array = []
	for w in it.get("waypoints", []):
		pts.append(PlacedLightLayer.waypoint_vec(w as Dictionary))
	if pts.size() < 2:
		return
	var geo := LightStringGeometry.build(pts, fields)
	var samples: PackedVector3Array = geo["samples"]
	if samples.size() < 2:
		return
	var col := PlacedLightPower.parse_color(str(fields.get("color", "ffd18c")))
	var energy := float(fields.get("energy", 2.5))
	var continuous := bool(fields.get("continuous", false))

	if continuous:
		var rope := MeshInstance3D.new()
		rope.mesh = LightStringGeometry.build_tube(samples,
			maxf(float(fields.get("tube_diameter_mm", 13.0)) * 0.0005, 0.004), 6)
		rope.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var rmat := StandardMaterial3D.new()
		rmat.albedo_color = col
		rmat.emission_enabled = true
		rmat.emission = col
		rmat.emission_energy_multiplier = 2.4
		rope.material_override = rmat
		rope.set_meta("studio_no_frame", true)
		holder.add_child(rope)
	else:
		var wire := MeshInstance3D.new()
		wire.mesh = LightStringGeometry.build_tube(samples, 0.004, 5)
		wire.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var wmat := StandardMaterial3D.new()
		wmat.albedo_color = PlacedLightPower.parse_color(str(fields.get("wire_color", "1a1a1a")))
		if selected:
			wmat.emission_enabled = true
			wmat.emission = Color(1.0, 0.65, 0.1)
			wmat.emission_energy_multiplier = 0.8
		wire.material_override = wmat
		wire.set_meta("studio_no_frame", true)
		holder.add_child(wire)

		var bulbs: PackedVector3Array = geo["bulbs"]
		if not bulbs.is_empty():
			var mmi := MultiMeshInstance3D.new()
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			var sm := SphereMesh.new()
			var bsz := clampf(float(fields.get("bulb_size", 0.06)), 0.012, 0.15)
			sm.radius = bsz * 0.5
			sm.height = bsz * 1.15
			sm.radial_segments = 8
			sm.rings = 4
			mm.mesh = sm
			mm.instance_count = bulbs.size()
			for bi in bulbs.size():
				mm.set_instance_transform(bi, Transform3D(Basis.IDENTITY, bulbs[bi] - Vector3(0.0, bsz * 0.4, 0.0)))
			mmi.multimesh = mm
			var bmat := StandardMaterial3D.new()
			bmat.albedo_color = col
			bmat.emission_enabled = true
			bmat.emission = col
			bmat.emission_energy_multiplier = 3.0
			mmi.material_override = bmat
			mmi.set_meta("studio_no_frame", true)
			holder.add_child(mmi)

	# Real OmniLights along the string so the studio model visibly lights up.
	var n_real := clampi(int(fields.get("real_lights", 4)), 1, 6)
	var per_e := energy * 1.4 / sqrt(float(n_real))
	var lrng := maxf(float(fields.get("light_range", 4.0)), 1.5)
	for li in n_real:
		var si := clampi(int(floor((float(li) + 0.5) * float(samples.size()) / float(n_real))), 0, samples.size() - 1)
		var om := OmniLight3D.new()
		om.position = samples[si]
		om.light_color = col
		om.light_energy = per_e
		om.omni_range = lrng
		om.shadow_enabled = false
		om.set_meta("studio_no_frame", true)
		holder.add_child(om)

	if selected:
		var pmat := StandardMaterial3D.new()
		pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pmat.albedo_color = Color(1.0, 0.72, 0.15)
		pmat.no_depth_test = true
		for p in pts:
			var pm := MeshInstance3D.new()
			var ps := SphereMesh.new()
			ps.radius = 0.065
			ps.height = 0.13
			pm.mesh = ps
			pm.position = p as Vector3
			pm.material_override = pmat
			pm.set_meta("studio_no_frame", true)
			holder.add_child(pm)


## Intercept studio SubViewport events for click-to-place & light selection.
## Returns true when consumed (leaving RMB/MMB orbit & wheel zoom untouched).
func handle_viewport_event(event: InputEvent, camera: Camera3D, vp_container: Control,
		model_root: Node3D) -> bool:
	if camera == null or vp_container == null or model_root == null or not is_instance_valid(model_root):
		return false
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var ke := event as InputEventKey
		if _tool == "string":
			if ke.keycode == KEY_ENTER or ke.keycode == KEY_KP_ENTER:
				finish_string()
				return true
			if ke.keycode == KEY_BACKSPACE:
				_undo_last_pin()
				return true
			if ke.keycode == KEY_ESCAPE:
				_set_tool("select")
				return true
		return false
	if not (event is InputEventMouseButton):
		return false
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return false
	if mb.pressed:
		_press_pos = mb.position
		_pressed_lmb = true
		return _tool != "select"
	if not _pressed_lmb:
		return false
	_pressed_lmb = false
	if mb.position.distance_to(_press_pos) > DRAG_PX:
		return false
	var ray := _viewport_ray(camera, vp_container, mb.position)
	var ro: Vector3 = ray["origin"]
	var rd: Vector3 = ray["dir"]

	if _tool == "select":
		var picked := _pick_item(model_root, ro, rd)
		if picked >= 0:
			_selected_idx = picked
			_refresh_ui()
			_rebuild_preview_nodes()
			return true
		return false

	var now_ms := Time.get_ticks_msec()
	if _tool == "string" and (mb.double_click or now_ms - _last_click_ms <= DOUBLE_CLICK_MS) and _string_pts.size() >= 2:
		_last_click_ms = -100000
		finish_string()
		return true
	_last_click_ms = now_ms

	var hit := PropModelLights.raycast_model(model_root, ro, rd)
	if not bool(hit.get("valid", false)):
		return true
	var inv := model_root.global_transform.affine_inverse()
	var lpos := inv * ((hit["position"] as Vector3) + (hit["normal"] as Vector3) * 0.12)
	var lnrm := (model_root.global_transform.basis.inverse() * (hit["normal"] as Vector3)).normalized()

	match _tool:
		"omni":
			var item := PropModelLights.make_local_point("", "omni",
				"Omni %d" % (_items.size() + 1), lpos, Vector3.ZERO, "warm_bulb",
				{"schedule": "dusk_dawn"})
			_items.append(item)
			_selected_idx = _items.size() - 1
			_refresh_ui()
			_rebuild_preview_nodes()
			lights_changed.emit()
		"spot":
			var aim_to := lpos + (lnrm if lnrm.length_squared() > 0.2 else Vector3.DOWN)
			var rot := LightGizmoMath.aim_rotation(lpos, aim_to)
			var sitem := PropModelLights.make_local_point("", "spot",
				"Spot %d" % (_items.size() + 1), lpos, rot, "flood_4000k", {
					"energy": 2.4, "range": 12.0, "spot_angle": 38.0,
					"show_body": true, "shadow_enabled": false, "fade_m": 65.0,
					"schedule": "dusk_dawn"})
			_items.append(sitem)
			_selected_idx = _items.size() - 1
			_refresh_ui()
			_rebuild_preview_nodes()
			lights_changed.emit()
		"string":
			var pin_pos := inv * ((hit["position"] as Vector3) + (hit["normal"] as Vector3) * 0.05)
			if _string_pts.is_empty() or (_string_pts[-1] as Vector3).distance_to(pin_pos) > 0.05:
				_string_pts.append(pin_pos)
				_update_string_bar()
				_rebuild_preview_nodes()
	return true


func _pick_item(model_root: Node3D, ray_o: Vector3, ray_d: Vector3) -> int:
	var gxf := model_root.global_transform
	var best_idx := -1
	var best_t := INF
	for i in _items.size():
		var it: Dictionary = _items[i]
		if str(it.get("kind", "")) == "string":
			for w in it.get("waypoints", []):
				var wp := gxf * PlacedLightLayer.waypoint_vec(w as Dictionary)
				var rp := LightGizmoMath.ray_point(ray_o, ray_d, wp)
				var t := float(rp["t"])
				if float(rp["dist"]) <= LightGizmoMath.pick_radius(0.18, t) and t < best_t:
					best_t = t
					best_idx = i
		else:
			var lp := gxf * Vector3(float(it["x"]), float(it["y"]), float(it["z"]))
			var rp2 := LightGizmoMath.ray_point(ray_o, ray_d, lp)
			var t2 := float(rp2["t"])
			if float(rp2["dist"]) <= LightGizmoMath.pick_radius(0.22, t2) and t2 < best_t:
				best_t = t2
				best_idx = i
	return best_idx


static func _viewport_ray(camera: Camera3D, container: Control, local_pos: Vector2) -> Dictionary:
	var vp := camera.get_viewport()
	var csize := container.size
	var vsize := Vector2(vp.size) if vp != null else csize
	var uv := Vector2(
		local_pos.x * vsize.x / maxf(csize.x, 1.0),
		local_pos.y * vsize.y / maxf(csize.y, 1.0))
	return {
		"origin": camera.project_ray_origin(uv),
		"dir": camera.project_ray_normal(uv),
	}


# ---------------------------------------------------------------------------
# Night preview toggle for any modal's StudioViewport or custom SubViewport
# ---------------------------------------------------------------------------

func bind_studio_night(studio_or_world: Node) -> void:
	_night_target = studio_or_world
	if _night_chk != null:
		_night_chk.visible = studio_or_world != null


func reset_studio_night() -> void:
	if _night_on and _night_target != null:
		set_studio_night(_night_target, false)
	if _night_chk != null:
		_night_chk.set_pressed_no_signal(false)


func make_night_toggle(studio_or_world: Node) -> CheckButton:
	var btn := CheckButton.new()
	btn.name = "studio_night"
	btn.text = "Night"
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = "Dim the studio to night so you can see how the lights and strings illuminate the model"
	btn.toggled.connect(func(on: bool) -> void: set_studio_night(studio_or_world, on))
	return btn


func set_studio_night(studio_or_world: Node, on: bool) -> void:
	if studio_or_world == null or on == _night_on:
		return
	_night_on = on
	var world_root: Node = studio_or_world.get("world") if "world" in studio_or_world and studio_or_world.get("world") != null else studio_or_world
	var lights: Array = []
	for c in world_root.get_children():
		if c is DirectionalLight3D:
			lights.append(c)
	var env: Environment = null
	for c2 in world_root.get_children():
		if c2 is WorldEnvironment and (c2 as WorldEnvironment).environment != null:
			env = (c2 as WorldEnvironment).environment
			break
	if on:
		var saved_e: Array = []
		for dl in lights:
			saved_e.append((dl as DirectionalLight3D).light_energy)
			(dl as DirectionalLight3D).light_energy = 0.04
		_saved_studio = {"lights": lights, "energies": saved_e, "env": env}
		if env != null:
			_saved_studio["ambient_e"] = env.ambient_light_energy
			_saved_studio["bg_mode"] = env.background_mode
			_saved_studio["bg_col"] = env.background_color
			_saved_studio["fog"] = env.fog_enabled
			env.ambient_light_energy = 0.07
			env.background_mode = Environment.BG_COLOR
			env.background_color = Color(0.02, 0.028, 0.05)
			env.fog_enabled = false
	else:
		var sl: Array = _saved_studio.get("lights", [])
		var se: Array = _saved_studio.get("energies", [])
		for i in mini(sl.size(), se.size()):
			if is_instance_valid(sl[i]):
				(sl[i] as DirectionalLight3D).light_energy = float(se[i])
		var senv: Environment = _saved_studio.get("env", null)
		if senv != null:
			senv.ambient_light_energy = float(_saved_studio.get("ambient_e", 0.9))
			senv.background_mode = int(_saved_studio.get("bg_mode", Environment.BG_SKY)) as Environment.BGMode
			senv.background_color = _saved_studio.get("bg_col", Color(0.035, 0.043, 0.063)) as Color
			senv.fog_enabled = bool(_saved_studio.get("fog", false))
		_saved_studio = {}
