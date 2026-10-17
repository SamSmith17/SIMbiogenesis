class_name SliderSpinRow
extends RefCounted

## HSlider + SpinBox row with bidirectional sync — for precise parametric tuning.


static func default_step(min_v: float, max_v: float) -> float:
	if max_v <= 2.0:
		return 0.01
	if max_v <= 16.0:
		return 0.05
	return 1.0


static func spin_decimals(step: float) -> int:
	if step >= 1.0:
		return 0
	if step >= 0.1:
		return 1
	return 2


## Build a labeled slider + spinbox row. `style_label` receives (Label, label_text).
## Returns {row, slider, spin}.
static func add(parent: Control, label: String, min_v: float, max_v: float, start: float,
		handler: Callable, style_label: Callable = Callable(),
		label_min_w: int = 72, slider_min_w: int = 120, spin_min_w: int = 64,
		step: float = -1.0) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)
	if not label.is_empty():
		var lbl := Label.new()
		if style_label.is_valid():
			style_label.call(lbl, label)
		else:
			lbl.text = label
		lbl.custom_minimum_size = Vector2(label_min_w, 0)
		row.add_child(lbl)
	var use_step := step if step > 0.0 else default_step(min_v, max_v)
	var sl := HSlider.new()
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step = use_step
	sl.value = start
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if slider_min_w > 0:
		sl.custom_minimum_size = Vector2(slider_min_w, 0)
	row.add_child(sl)
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = use_step
	sp.custom_minimum_size = Vector2(spin_min_w, 0)
	sp.select_all_on_focus = true
	sp.add_theme_font_size_override("font_size", 10)
	sp.value = start
	row.add_child(sp)
	var guard := {"sync": false}
	sl.value_changed.connect(func(v: float) -> void:
		if guard.sync:
			return
		guard.sync = true
		sp.value = v
		guard.sync = false
		handler.call(v))
	sp.value_changed.connect(func(v: float) -> void:
		if guard.sync:
			return
		guard.sync = true
		sl.value = v
		guard.sync = false
		handler.call(v))
	return {"row": row, "slider": sl, "spin": sp}


## A compact parameter for a tool bar: label, a FIXED-width slider (an
## expanding one fills a flow row and leaves gaps between the parameters) and
## a small value box carrying the unit as its suffix. `auto_below`: a value
## under it means "automatic" (a heading of -1) and the label says so.
## Returns {row, slider, spin, label}.
static func add_param(parent: Control, label: String, min_v: float, max_v: float, start: float,
		step: float, unit: String, handler: Callable, auto_below: float = NAN,
		slider_w: int = 92, spin_w: int = 64) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(lbl)
	var name_of := func(v: float) -> String:
		if not is_nan(auto_below) and v < auto_below:
			return "%s · auto" % label
		return label
	lbl.text = name_of.call(start)
	var use_step := step if step > 0.0 else default_step(min_v, max_v)
	var sl := HSlider.new()
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step = use_step
	sl.value = start
	sl.custom_minimum_size = Vector2(slider_w, 0)
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.focus_mode = Control.FOCUS_NONE
	row.add_child(sl)
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = use_step
	sp.suffix = unit
	sp.custom_minimum_size = Vector2(spin_w, 0)
	sp.select_all_on_focus = true
	sp.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	sp.get_line_edit().add_theme_font_size_override("font_size", UITheme.FONT_XS)
	sp.value = start
	row.add_child(sp)
	var guard := {"sync": false}
	var on_change := func(v: float, from_slider: bool) -> void:
		if guard.sync:
			return
		guard.sync = true
		if from_slider:
			sp.value = v
		else:
			sl.value = v
		guard.sync = false
		lbl.text = name_of.call(v)
		handler.call(v)
	sl.value_changed.connect(on_change.bind(true))
	sp.value_changed.connect(on_change.bind(false))
	return {"row": row, "slider": sl, "spin": sp, "label": lbl}


static func set_values(pair: Dictionary, value: float) -> void:
	if pair.is_empty():
		return
	var sl: HSlider = pair.get("slider")
	var sp: SpinBox = pair.get("spin")
	if sl != null:
		sl.value = value
	if sp != null:
		sp.value = value
