class_name FormRow
extends HBoxContainer

## One settings row: `label · control · unit`. The label is a fixed 140 px
## (`LABEL_W`), ellipsizes and carries the tip on hover; the control takes
## the rest of the row; a unit is the SpinBox's suffix or a muted label after
## the control; an optional revert button (28 px, `IconButton`) sits at the
## end. Replaces the designers' `_row` / `_spin` / `_option` helpers, whose
## label widths (120, 140, 160) and tooltips differed file by file, and
## `SliderSpinRow.add` where a slider is wanted (`FormRow.slider`).
##
##   box.add_child(FormRow.spin("Radius", 1.0, 40.0, 0.1, "m", on_radius, "Sphere radius"))
##   box.add_child(FormRow.option("Base solid", [["ico", "Icosahedron"]], on_base))
##   box.add_child(FormRow.check("Base", "Flat base", on_flat))
##   var r := FormRow.slider("Explode", 0.0, 1.0, 0.0, 0.01, "", on_explode)
##   r.control (the SpinBox / OptionButton / CheckBox / HSlider), r.spin_box,
##   r.set_value(v) (no signal), r.with_revert(cb)
##
## Every row's control is also findable by name for the harness: pass `id`
## and the control is named it.

const LABEL_W := 140.0

var label: Label = null
var control: Control = null
## The SpinBox beside a slider row (null otherwise).
var spin_box: SpinBox = null
var unit_label: Label = null
var revert_btn: Button = null

var _guard := false


static func make(text: String, ctl: Control, tip: String = "", unit: String = "", id: String = "") -> FormRow:
	var r := FormRow.new()
	r._build(text, tip)
	r.control = ctl
	if not id.is_empty():
		ctl.name = id
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if not tip.is_empty() and ctl.tooltip_text.is_empty():
		ctl.tooltip_text = tip
	if ctl is OptionButton:
		(ctl as OptionButton).fit_to_longest_item = false
		(ctl as OptionButton).clip_text = true
		(ctl as OptionButton).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	r.add_child(ctl)
	r.resized.connect(r._cap_control_width)
	if not unit.is_empty():
		if ctl is SpinBox:
			(ctl as SpinBox).suffix = unit
		else:
			r.unit_label = Label.new()
			r.unit_label.text = unit
			r.unit_label.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			r.unit_label.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			r.unit_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			r.add_child(r.unit_label)
	return r


## A SpinBox row. `cb(value: float)` on change.
static func spin(text: String, min_v: float, max_v: float, step: float, unit: String,
		cb: Callable, tip: String = "", id: String = "") -> FormRow:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.select_all_on_focus = true
	if cb.is_valid():
		s.value_changed.connect(cb)
	return make(text, s, tip, unit, id)


## An OptionButton row over `[[meta, label], …]`. `cb(meta)` on select.
static func option(text: String, items: Array, cb: Callable, tip: String = "", id: String = "") -> FormRow:
	var o := OptionButton.new()
	for i in items.size():
		var it: Array = items[i]
		o.add_item(str(it[1]), i)
		o.set_item_metadata(i, it[0])
	if cb.is_valid():
		o.item_selected.connect(func(idx: int) -> void: cb.call(o.get_item_metadata(idx)))
	return make(text, o, tip, "", id)


## A CheckBox row: the row label on the left, `check_text` on the box.
static func check(text: String, check_text: String, cb: Callable, tip: String = "", id: String = "") -> FormRow:
	var c := CheckBox.new()
	c.text = check_text
	if cb.is_valid():
		c.toggled.connect(cb)
	return make(text, c, tip, "", id)


## A LineEdit row.
static func text_edit(text: String, placeholder: String, cb: Callable, tip: String = "", id: String = "") -> FormRow:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	if cb.is_valid():
		e.text_changed.connect(cb)
	return make(text, e, tip, "", id)


## A slider + value box row (the two kept in step). `r.control` is the
## HSlider, `r.spin_box` the box carrying the unit. `cb(value)` fires once per
## change from either.
static func slider(text: String, min_v: float, max_v: float, start: float, step: float,
		unit: String, cb: Callable, tip: String = "", id: String = "") -> FormRow:
	var sl := HSlider.new()
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step = step if step > 0.0 else SliderSpinRow.default_step(min_v, max_v)
	sl.value = start
	sl.focus_mode = Control.FOCUS_NONE
	var r := make(text, sl, tip, "", id)
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = sl.step
	sp.suffix = unit
	sp.value = start
	sp.select_all_on_focus = true
	sp.custom_minimum_size = Vector2(84, 0)
	sp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sp.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	sp.get_line_edit().add_theme_font_size_override("font_size", UITheme.FONT_XS)
	r.add_child(sp)
	r.spin_box = sp
	sl.value_changed.connect(func(v: float) -> void:
		if r._guard:
			return
		r._guard = true
		sp.value = v
		r._guard = false
		if cb.is_valid():
			cb.call(v))
	sp.value_changed.connect(func(v: float) -> void:
		if r._guard:
			return
		r._guard = true
		sl.value = v
		r._guard = false
		if cb.is_valid():
			cb.call(v))
	return r


## A read-only value row (a muted label on the right).
static func value(text: String, value_text: String, tip: String = "", id: String = "") -> FormRow:
	var l := Label.new()
	l.text = value_text
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.add_theme_font_override("font", UITheme.font("medium", true))
	l.add_theme_color_override("font_color", UITheme.C_TEXT)
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.mouse_entered.connect(func() -> void: l.tooltip_text = l.text)
	return make(text, l, tip, "", id)


func _build(text: String, tip: String) -> void:
	add_theme_constant_override("separation", UITheme.SPACE_SM)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size.y = 26.0
	label = Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(LABEL_W, 0)
	label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	label.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	label.tooltip_text = tip if not tip.is_empty() else text
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(label)


## Write a value without firing the change callback (a sync from the model).
func set_value(v: Variant) -> void:
	_guard = true
	if control is SpinBox:
		(control as SpinBox).set_value_no_signal(float(v))
	elif control is HSlider:
		(control as HSlider).set_value_no_signal(float(v))
		if spin_box != null:
			spin_box.set_value_no_signal(float(v))
	elif control is CheckBox:
		(control as CheckBox).set_pressed_no_signal(bool(v))
	elif control is OptionButton:
		select_meta(control as OptionButton, v)
	elif control is LineEdit:
		(control as LineEdit).text = str(v)
	elif control is Label:
		(control as Label).text = str(v)
	_guard = false


## Select an OptionButton item by its metadata (numbers compare loosely).
static func select_meta(o: OptionButton, v: Variant) -> void:
	for i in o.item_count:
		var m: Variant = o.get_item_metadata(i)
		if typeof(m) == typeof(v) and m == v:
			o.select(i)
			return
		if (m is float or m is int) and (v is float or v is int) and absf(float(m) - float(v)) < 1e-6:
			o.select(i)
			return


## A revert button at the end of the row (shown while `set_dirty(true)`).
func with_revert(cb: Callable, tip: String = "Back to the default") -> FormRow:
	revert_btn = IconButton.make("rotate-ccw", tip, cb, "", 14)
	revert_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	revert_btn.visible = false
	add_child(revert_btn)
	return self


## Mark the row as changed from its baseline (amber label, the revert shown).
func set_dirty(dirty: bool) -> void:
	label.add_theme_color_override("font_color", UITheme.C_AMBER if dirty else UITheme.C_TEXT_S)
	if revert_btn != null:
		revert_btn.visible = dirty


func set_label(text: String) -> void:
	label.text = text


func set_enabled(on: bool) -> void:
	if control is SpinBox:
		(control as SpinBox).editable = on
	elif control is HSlider:
		(control as HSlider).editable = on
		if spin_box != null:
			spin_box.editable = on
	elif control is LineEdit:
		(control as LineEdit).editable = on
	elif control is BaseButton:
		(control as BaseButton).disabled = not on


func _cap_control_width() -> void:
	if control == null or not is_instance_valid(control):
		return
	var cap := 0.0
	if control is HSlider:
		cap = 320.0
	elif control is OptionButton:
		cap = 360.0
	elif control is LineEdit:
		cap = 480.0
	if cap <= 0.0:
		return
	var avail := size.x - LABEL_W - float(UITheme.SPACE_SM)
	if avail > cap + 8.0:
		control.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		control.custom_minimum_size.x = cap
	else:
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		control.custom_minimum_size.x = 0.0
