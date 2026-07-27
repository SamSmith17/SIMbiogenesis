extends Control

## Modal editor for process recipes (create / edit / save to user catalog).

const MODAL_NAME := "process_recipe_editor"

var _built := false
var _recipe: Dictionary = {}
var _role_hint := ""
var _name_edit: LineEdit = null
var _time_spin: SpinBox = null
var _chore_spin: SpinBox = null
var _confirm_start: CheckButton = null
var _roles_edit: LineEdit = null
var _note_edit: LineEdit = null
var _inputs_box: VBoxContainer = null
var _outputs_box: VBoxContainer = null
var _steps_box: VBoxContainer = null
var _status: Label = null


func open(recipe_id: String = "", role_hint: String = "") -> void:
	_role_hint = role_hint
	if not recipe_id.is_empty():
		_recipe = ProcessRecipeCatalog.find(recipe_id)
	if _recipe.is_empty():
		_recipe = ProcessRecipe.normalize({
			"id": "",
			"label": "New Recipe",
			"compatible_roles": [role_hint] if not role_hint.is_empty() else ["processor"],
			"batch_time_hrs": 1.0,
			"chore_hours": 0.1,
			"require_confirm_start": false,
			"inputs": [{"kind": "plastic_flake", "qty": 1.0, "mode": "frontloaded"}],
			"outputs": [{"kind": "biochar", "qty": 1.0, "mode": "end_batch"}],
			"steps": [
				{"id": "load", "label": "Load", "at_frac": 0.0, "chore_hours": 0.05, "require_confirm": false},
				{"id": "run", "label": "Process", "at_frac": 0.0, "chore_hours": 0.0, "require_confirm": false},
				{"id": "unload", "label": "Unload", "at_frac": 1.0, "chore_hours": 0.05, "require_confirm": false},
			],
		})
	if not _built:
		_build_ui()
		_built = true
	_populate()
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	visible = false
	CursorController.release_modal(MODAL_NAME)


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640, 620)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	center.add_child(panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	panel.add_child(root)

	var title := Label.new()
	title.text = "Process Recipe Editor"
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(600, 0)
	form.add_theme_constant_override("separation", 6)
	scroll.add_child(form)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Recipe name"
	form.add_child(_labeled("Name", _name_edit))

	_time_spin = SpinBox.new()
	_time_spin.min_value = 0.01
	_time_spin.max_value = 10000.0
	_time_spin.step = 0.05
	form.add_child(_labeled("Batch time (h)", _time_spin))

	_chore_spin = SpinBox.new()
	_chore_spin.min_value = 0.0
	_chore_spin.max_value = 100.0
	_chore_spin.step = 0.05
	form.add_child(_labeled("Chore hours", _chore_spin))

	_confirm_start = CheckButton.new()
	_confirm_start.text = "Require confirm to start"
	form.add_child(_confirm_start)

	_roles_edit = LineEdit.new()
	_roles_edit.placeholder_text = "processor, pp_sheet_press, …"
	form.add_child(_labeled("Compatible roles", _roles_edit))

	_note_edit = LineEdit.new()
	_note_edit.placeholder_text = "Short note"
	form.add_child(_labeled("Note", _note_edit))

	var in_hdr := Label.new()
	in_hdr.text = "Inputs (kind, qty, mode)"
	form.add_child(in_hdr)
	_inputs_box = VBoxContainer.new()
	form.add_child(_inputs_box)
	var add_in := Button.new()
	add_in.text = "+ Input"
	add_in.pressed.connect(func():
		var arr: Array = _recipe.get("inputs", []) as Array
		arr.append({"kind": "water", "qty": 1.0, "mode": "frontloaded"})
		_recipe["inputs"] = arr
		_rebuild_io_lists()
	)
	form.add_child(add_in)

	var out_hdr := Label.new()
	out_hdr.text = "Outputs (kind|part, qty, mode)"
	form.add_child(out_hdr)
	_outputs_box = VBoxContainer.new()
	form.add_child(_outputs_box)
	var add_out := Button.new()
	add_out.text = "+ Output"
	add_out.pressed.connect(func():
		var arr_o: Array = _recipe.get("outputs", []) as Array
		arr_o.append({"kind": "biochar", "qty": 1.0, "mode": "end_batch"})
		_recipe["outputs"] = arr_o
		_rebuild_io_lists()
	)
	form.add_child(add_out)

	var step_hdr := Label.new()
	step_hdr.text = "Steps (label, at_frac, chore_h, confirm)"
	form.add_child(step_hdr)
	_steps_box = VBoxContainer.new()
	form.add_child(_steps_box)
	var add_step := Button.new()
	add_step.text = "+ Step"
	add_step.pressed.connect(func():
		var steps: Array = _recipe.get("steps", []) as Array
		steps.append({"id": "step_%d" % steps.size(), "label": "Step",
			"at_frac": 0.5, "chore_hours": 0.0, "require_confirm": false})
		_recipe["steps"] = steps
		_rebuild_io_lists()
	)
	form.add_child(add_step)

	_status = Label.new()
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	root.add_child(_status)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	root.add_child(btns)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(_on_save)
	btns.add_child(save_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.pressed.connect(_on_delete)
	btns.add_child(del_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(close)
	btns.add_child(close_btn)


func _labeled(text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size.x = 140
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	row.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _populate() -> void:
	_name_edit.text = str(_recipe.get("label", ""))
	_time_spin.value = float(_recipe.get("batch_time_hrs", 1.0))
	_chore_spin.value = float(_recipe.get("chore_hours", 0.0))
	_confirm_start.button_pressed = bool(_recipe.get("require_confirm_start", false))
	var roles: Array = _recipe.get("compatible_roles", []) as Array
	var role_bits := PackedStringArray()
	for r: Variant in roles:
		role_bits.append(str(r))
	_roles_edit.text = ", ".join(role_bits)
	_note_edit.text = str(_recipe.get("note", ""))
	_rebuild_io_lists()
	_status.text = "id: %s" % str(_recipe.get("id", "(new)"))


func _rebuild_io_lists() -> void:
	for c in _inputs_box.get_children():
		c.queue_free()
	for c2 in _outputs_box.get_children():
		c2.queue_free()
	for c3 in _steps_box.get_children():
		c3.queue_free()
	var inputs: Array = _recipe.get("inputs", []) as Array
	for i in inputs.size():
		_inputs_box.add_child(_io_row(inputs, i, true))
	var outputs: Array = _recipe.get("outputs", []) as Array
	for j in outputs.size():
		_outputs_box.add_child(_io_row(outputs, j, false))
	var steps: Array = _recipe.get("steps", []) as Array
	for k in steps.size():
		_steps_box.add_child(_step_row(steps, k))


func _io_row(arr: Array, idx: int, is_input: bool) -> HBoxContainer:
	var io: Dictionary = arr[idx] as Dictionary
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var kind := LineEdit.new()
	kind.text = str(io.get("kind", ""))
	kind.custom_minimum_size.x = 120
	kind.text_changed.connect(func(t: String): io["kind"] = t)
	row.add_child(kind)
	if not is_input:
		var pid := LineEdit.new()
		pid.placeholder_text = "part_id"
		pid.text = str(io.get("part_id", ""))
		pid.custom_minimum_size.x = 100
		pid.text_changed.connect(func(t: String):
			io["part_id"] = t
			if not t.is_empty():
				io["kind"] = "part"
		)
		row.add_child(pid)
	var qty := SpinBox.new()
	qty.min_value = 0.0
	qty.max_value = 999999.0
	qty.step = 0.01
	qty.value = float(io.get("qty", io.get("rate", 0.0)))
	qty.value_changed.connect(func(v: float): io["qty"] = v; io["rate"] = v)
	row.add_child(qty)
	var mode := OptionButton.new()
	var modes := ProcessRecipe.INPUT_MODES if is_input else ProcessRecipe.OUTPUT_MODES
	var cur := str(io.get("mode", "continuous"))
	var msel := 0
	for mi in modes.size():
		mode.add_item(str(modes[mi]), mi)
		if str(modes[mi]) == cur:
			msel = mi
	mode.select(msel)
	mode.item_selected.connect(func(id: int): io["mode"] = str(modes[id]))
	row.add_child(mode)
	var del := Button.new()
	del.text = "X"
	del.pressed.connect(func():
		arr.remove_at(idx)
		_rebuild_io_lists()
	)
	row.add_child(del)
	return row


func _step_row(arr: Array, idx: int) -> HBoxContainer:
	var s: Dictionary = arr[idx] as Dictionary
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var lbl := LineEdit.new()
	lbl.text = str(s.get("label", ""))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.text_changed.connect(func(t: String): s["label"] = t)
	row.add_child(lbl)
	var frac := SpinBox.new()
	frac.min_value = 0.0
	frac.max_value = 1.0
	frac.step = 0.05
	frac.value = float(s.get("at_frac", 0.0))
	frac.value_changed.connect(func(v: float): s["at_frac"] = v)
	row.add_child(frac)
	var chore := SpinBox.new()
	chore.min_value = 0.0
	chore.max_value = 24.0
	chore.step = 0.05
	chore.value = float(s.get("chore_hours", 0.0))
	chore.value_changed.connect(func(v: float): s["chore_hours"] = v)
	row.add_child(chore)
	var conf := CheckButton.new()
	conf.text = "Confirm"
	conf.button_pressed = bool(s.get("require_confirm", false))
	conf.toggled.connect(func(on: bool): s["require_confirm"] = on)
	row.add_child(conf)
	var del := Button.new()
	del.text = "X"
	del.pressed.connect(func():
		arr.remove_at(idx)
		_rebuild_io_lists()
	)
	row.add_child(del)
	return row


func _collect() -> Dictionary:
	var roles: Array = []
	for part: String in _roles_edit.text.split(","):
		var s := part.strip_edges()
		if not s.is_empty():
			roles.append(s)
	var r := _recipe.duplicate(true)
	r["label"] = _name_edit.text.strip_edges()
	r["batch_time_hrs"] = _time_spin.value
	r["chore_hours"] = _chore_spin.value
	r["require_confirm_start"] = _confirm_start.button_pressed
	r["compatible_roles"] = roles
	r["note"] = _note_edit.text.strip_edges()
	r["builtin"] = false
	return ProcessRecipe.normalize(r)


func _on_save() -> void:
	var r := _collect()
	if str(r.get("label", "")).is_empty():
		_status.text = "Name required"
		return
	var saved := ProcessRecipeCatalog.save_user_recipe(r)
	_recipe = saved
	_status.text = "Saved: %s" % str(saved.get("id", ""))
	_populate()


func _on_delete() -> void:
	var rid := str(_recipe.get("id", ""))
	if rid.is_empty() or bool(_recipe.get("builtin", false)):
		_status.text = "Cannot delete builtins / unsaved"
		return
	if ProcessRecipeCatalog.delete_user_recipe(rid):
		_status.text = "Deleted"
		close()
	else:
		_status.text = "Delete failed (builtin?)"
