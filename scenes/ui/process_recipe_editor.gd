extends Control

## Modal editor for process recipes (create / edit / save to user catalog): a
## ModalFrame form. Inputs / Outputs / Steps are sections of rows; a resource
## is picked by its name (ResourceKinds), a mode by what it means, and no id
## reaches the player.

const MODAL_NAME := "process_recipe_editor"

const MODE_LABELS := {
	"continuous": "As it runs",
	"frontloaded": "All at the start",
	"delayed": "Part way through",
	"end_batch": "At the end",
}
## An output that is a fabricated part, not a resource kind.
const KIND_PART := "part"

var _built := false
var _frame: ModalFrame = null
var _recipe: Dictionary = {}
var _role_hint := ""
var _name_edit: LineEdit = null
var _time_spin: SpinBox = null
var _chore_spin: SpinBox = null
var _confirm_start: CheckBox = null
var _roles_edit: LineEdit = null
var _note_edit: LineEdit = null
var _inputs_box: VBoxContainer = null
var _outputs_box: VBoxContainer = null
var _steps_box: VBoxContainer = null
var _status: Label = null
var _delete_btn: Button = null


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
	_frame.open()


func close() -> void:
	visible = false
	if _frame != null:
		_frame.close()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame = ModalFrame.create("Process recipe", "what a machine takes in, makes, and the hands it needs",
		Vector2(760, 720), MODAL_NAME)
	add_child(_frame)
	_frame.closed.connect(close)
	var form := _frame.body
	form.add_theme_constant_override("separation", UITheme.SPACE_XS)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Recipe name"
	form.add_child(FormRow.make("Name", _name_edit, "", "", "recipe_name"))
	var time_row := FormRow.spin("Batch time", 0.01, 10000.0, 0.05, "h", Callable(),
		"How long one batch runs", "batch_time")
	_time_spin = time_row.control as SpinBox
	form.add_child(time_row)
	var chore_row := FormRow.spin("Labour", 0.0, 100.0, 0.05, "h", Callable(),
		"Person-hours of attention a batch needs on top of its steps", "chore_hours")
	_chore_spin = chore_row.control as SpinBox
	form.add_child(chore_row)
	_confirm_start = CheckBox.new()
	form.add_child(FormRow.make("Start", _confirm_start, "Wait for someone to start each batch", "", "confirm_start"))
	_confirm_start.text = "Needs a person to start it"
	_roles_edit = LineEdit.new()
	_roles_edit.placeholder_text = "processor, pp_sheet_press, …"
	form.add_child(FormRow.make("Runs on", _roles_edit,
		"The kinds of machine that can run this recipe, by their role id, separated by commas (processor = any generic processor)", "", "roles"))
	_note_edit = LineEdit.new()
	_note_edit.placeholder_text = "A short note"
	form.add_child(FormRow.make("Note", _note_edit, "", "", "note"))

	form.add_child(SectionHeader.make("Inputs", "", "what a batch takes in"))
	_inputs_box = VBoxContainer.new()
	_inputs_box.add_theme_constant_override("separation", 2)
	form.add_child(_inputs_box)
	form.add_child(_add_button("Add an input", func() -> void:
		var arr: Array = _recipe.get("inputs", []) as Array
		arr.append({"kind": "water", "qty": 1.0, "mode": "frontloaded"})
		_recipe["inputs"] = arr
		_rebuild_io_lists()))

	form.add_child(SectionHeader.make("Outputs", "", "what it makes"))
	_outputs_box = VBoxContainer.new()
	_outputs_box.add_theme_constant_override("separation", 2)
	form.add_child(_outputs_box)
	form.add_child(_add_button("Add an output", func() -> void:
		var arr_o: Array = _recipe.get("outputs", []) as Array
		arr_o.append({"kind": "biochar", "qty": 1.0, "mode": "end_batch"})
		_recipe["outputs"] = arr_o
		_rebuild_io_lists()))

	form.add_child(SectionHeader.make("Steps", "", "the hands along the way"))
	_steps_box = VBoxContainer.new()
	_steps_box.add_theme_constant_override("separation", 2)
	form.add_child(_steps_box)
	form.add_child(_add_button("Add a step", func() -> void:
		var steps: Array = _recipe.get("steps", []) as Array
		steps.append({"id": "step_%d" % steps.size(), "label": "Step",
			"at_frac": 0.5, "chore_hours": 0.0, "require_confirm": false})
		_recipe["steps"] = steps
		_rebuild_io_lists()))

	_status = Label.new()
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form.add_child(_status)

	_frame.add_button("Save", ModalFrame.PRIMARY, _on_save, "Keep this recipe in your catalog")
	_delete_btn = _frame.add_button("Delete", ModalFrame.DESTRUCTIVE, _on_delete,
		"Remove this recipe from your catalog")
	_frame.add_button("Close", ModalFrame.SECONDARY, close)


func _add_button(text: String, cb: Callable) -> Button:
	var b := IconButton.make("plus", text, cb, text)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return b


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
	var builtin := bool(_recipe.get("builtin", false))
	var saved := not str(_recipe.get("id", "")).is_empty()
	_status.text = "A built-in recipe: saving makes your own copy" if builtin \
		else ("Saved in your catalog" if saved else "Not saved yet")
	if _delete_btn != null:
		_delete_btn.visible = saved and not builtin
	_frame.set_title("Process recipe", str(_recipe.get("label", "")) if saved else "a new recipe")


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


## One input / output: the resource by name (or a part, for outputs), how
## much, and when it moves.
func _io_row(arr: Array, idx: int, is_input: bool) -> HBoxContainer:
	var io: Dictionary = arr[idx] as Dictionary
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_XS)
	var cur_kind := str(io.get("kind", ""))
	var is_part := not is_input and (cur_kind == KIND_PART or not str(io.get("part_id", "")).is_empty())
	var kind := OptionButton.new()
	kind.fit_to_longest_item = false
	kind.clip_text = true
	kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind.tooltip_text = "The resource"
	var kinds := ResourceKinds.all_kinds()
	if not is_input:
		kinds.append(KIND_PART)
	if not cur_kind.is_empty() and not kinds.has(cur_kind) and not is_part:
		kinds.append(cur_kind)
	var sel := 0
	for ki in kinds.size():
		var kid := str(kinds[ki])
		kind.add_item("A fabricated part…" if kid == KIND_PART else ResourceKinds.display_name(kid), ki)
		kind.set_item_metadata(ki, kid)
		if (is_part and kid == KIND_PART) or (not is_part and kid == cur_kind):
			sel = ki
	kind.select(sel)
	row.add_child(kind)
	var pid := LineEdit.new()
	pid.placeholder_text = "which part"
	pid.tooltip_text = "The part's catalog id"
	pid.text = str(io.get("part_id", ""))
	pid.custom_minimum_size.x = 110
	pid.visible = is_part
	pid.text_changed.connect(func(t: String) -> void:
		io["part_id"] = t
		if not t.is_empty():
			io["kind"] = KIND_PART)
	if not is_input:
		row.add_child(pid)
	var qty := SpinBox.new()
	qty.min_value = 0.0
	qty.max_value = 999999.0
	qty.step = 0.01
	qty.value = float(io.get("qty", io.get("rate", 0.0)))
	qty.custom_minimum_size.x = 110
	qty.suffix = "" if is_part else ResourceKinds.default_unit(cur_kind)
	qty.tooltip_text = "How much per batch"
	qty.value_changed.connect(func(v: float) -> void:
		io["qty"] = v
		io["rate"] = v)
	row.add_child(qty)
	kind.item_selected.connect(func(ki: int) -> void:
		var kid := str(kind.get_item_metadata(ki))
		io["kind"] = kid
		pid.visible = kid == KIND_PART
		if kid != KIND_PART:
			io.erase("part_id")
		qty.suffix = "" if kid == KIND_PART else ResourceKinds.default_unit(kid))
	var mode := OptionButton.new()
	mode.fit_to_longest_item = false
	mode.clip_text = true
	mode.custom_minimum_size.x = 130
	mode.tooltip_text = "When it moves during the batch"
	var modes := ProcessRecipe.INPUT_MODES if is_input else ProcessRecipe.OUTPUT_MODES
	var cur := str(io.get("mode", "continuous"))
	var msel := 0
	for mi in modes.size():
		var mid := str(modes[mi])
		mode.add_item(str(MODE_LABELS.get(mid, mid.capitalize())), mi)
		if mid == cur:
			msel = mi
	mode.select(msel)
	mode.item_selected.connect(func(id: int) -> void: io["mode"] = str(modes[id]))
	row.add_child(mode)
	row.add_child(IconButton.make("trash-2", "Remove this %s" % ("input" if is_input else "output"),
		func() -> void:
			arr.remove_at(idx)
			_rebuild_io_lists()))
	return row


## One step: its name, where in the batch it falls, the hands it takes, and
## whether someone must confirm it.
func _step_row(arr: Array, idx: int) -> HBoxContainer:
	var s: Dictionary = arr[idx] as Dictionary
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_XS)
	var lbl := LineEdit.new()
	lbl.text = str(s.get("label", ""))
	lbl.placeholder_text = "Step"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.text_changed.connect(func(t: String) -> void: s["label"] = t)
	row.add_child(lbl)
	var frac := SpinBox.new()
	frac.min_value = 0.0
	frac.max_value = 100.0
	frac.step = 5.0
	frac.value = float(s.get("at_frac", 0.0)) * 100.0
	frac.suffix = "% in"
	frac.custom_minimum_size.x = 96
	frac.tooltip_text = "How far through the batch this step comes"
	frac.value_changed.connect(func(v: float) -> void: s["at_frac"] = v / 100.0)
	row.add_child(frac)
	var chore := SpinBox.new()
	chore.min_value = 0.0
	chore.max_value = 24.0
	chore.step = 0.05
	chore.value = float(s.get("chore_hours", 0.0))
	chore.suffix = "h"
	chore.custom_minimum_size.x = 90
	chore.tooltip_text = "Person-hours of work at this step"
	chore.value_changed.connect(func(v: float) -> void: s["chore_hours"] = v)
	row.add_child(chore)
	var conf := CheckBox.new()
	conf.text = "Confirm"
	conf.tooltip_text = "Someone must confirm this step before the batch goes on"
	conf.button_pressed = bool(s.get("require_confirm", false))
	conf.toggled.connect(func(on: bool) -> void: s["require_confirm"] = on)
	row.add_child(conf)
	row.add_child(IconButton.make("trash-2", "Remove this step", func() -> void:
		arr.remove_at(idx)
		_rebuild_io_lists()))
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
		_status.text = "Give the recipe a name first"
		return
	var saved := ProcessRecipeCatalog.save_user_recipe(r)
	_recipe = saved
	_populate()
	_status.text = I18n.f("Saved {label}", {"label": str(saved.get("label", ""))})


func _on_delete() -> void:
	var rid := str(_recipe.get("id", ""))
	if rid.is_empty() or bool(_recipe.get("builtin", false)):
		_status.text = "A built-in or unsaved recipe cannot be deleted"
		return
	if ProcessRecipeCatalog.delete_user_recipe(rid):
		_status.text = "Deleted"
		close()
	else:
		_status.text = "Could not delete it"
