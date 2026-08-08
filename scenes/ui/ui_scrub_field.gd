class_name UIScrubField
extends VBoxContainer
## A number field you can drag, slide, or type into.
##
## Godot's SpinBox gives you arrows and a text box; neither is any use for the
## kind of editing this exists for, which is "make it a bit bigger and watch the
## model change". The web app solves that by making every number input a
## click-drag SCRUBBER (`hwBindNumberScrub`, hardware-detail.js:498) — press the
## label, move sideways, the value follows. This is that, plus an optional
## slider, so a value can be swept without knowing its range or nudged exactly
## when you do.
##
## Three ways in, one value out:
##   · drag the LABEL sideways — 3 px per step, matching the web
##   · drag the slider — coarse sweep across the whole range
##   · type in the box — exact, live as you type
##
## Two signals, because "the value is changing" and "the value has settled" want
## different responses: a preview should follow `value_changed`, while anything
## expensive (a re-solve, a save) should wait for `committed`.

signal value_changed(v: float)
signal committed(v: float)

## Pixels of pointer travel per step, from `hwBindNumberScrub`. Small enough to
## feel direct, large enough that a jittery hand does not ratchet the value.
const SCRUB_PX_PER_STEP := 3.0

var _label: Label = null
var _spin: SpinBox = null
var _slider: HSlider = null

var _step := 0.01
var _min := 0.0
var _max := 1.0
## Set while this control is writing to its own children, so their signals do
## not bounce back in as user edits.
var _echo := false
var _scrubbing := false
var _scrub_accum := 0.0


static func make(label: String, mn: float, mx: float, step: float, value: float,
		decimals: int = 3, show_slider: bool = true) -> UIScrubField:
	var f := UIScrubField.new()
	f._min = mn
	f._max = mx
	f._step = step
	f._build(label, value, decimals, show_slider)
	return f


func _build(label: String, value: float, decimals: int, show_slider: bool) -> void:
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", UITheme.SPACE_XS)
	add_child(head)

	_label = Label.new()
	_label.text = label
	_label.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_label.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The label IS the scrub handle, so it has to advertise itself: a horizontal
	# resize cursor is the one users already read as "drag me sideways".
	_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_label.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_label.tooltip_text = "Drag sideways to scrub · Shift = fine · Ctrl = coarse"
	_label.gui_input.connect(_on_label_input)
	head.add_child(_label)

	_spin = SpinBox.new()
	_spin.min_value = _min
	_spin.max_value = _max
	_spin.step = _step
	_spin.value = clampf(value, _min, _max)
	# Live as you type. Without this the value only lands on Enter or focus
	# loss, which reads as the field being ignored.
	_spin.update_on_text_changed = true
	_spin.custom_minimum_size.x = 76
	_spin.get_line_edit().add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_spin.value_changed.connect(_on_spin_changed)
	_spin.get_line_edit().focus_exited.connect(func() -> void:
		committed.emit(_spin.value))
	head.add_child(_spin)

	if show_slider:
		_slider = HSlider.new()
		_slider.min_value = _min
		_slider.max_value = _max
		# A display step an order finer than the range, floored at the value
		# step: a slider that can only reach the spin's own increments is no
		# faster than the spin.
		_slider.step = maxf(_step, (_max - _min) / 400.0)
		_slider.value = _spin.value
		_slider.custom_minimum_size.y = 12
		_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_slider.value_changed.connect(_on_slider_changed)
		_slider.drag_ended.connect(func(_changed: bool) -> void:
			committed.emit(_spin.value))
		add_child(_slider)
	# `decimals` is advisory — SpinBox derives its own display precision from
	# `step`, and overriding it here would fight the arrows.
	_spin.get_line_edit().tooltip_text = "%.*f" % [decimals, _spin.value]


# ---------------------------------------------------------------------------
# Scrubbing
# ---------------------------------------------------------------------------

func _on_label_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		_scrubbing = mb.pressed
		_scrub_accum = 0.0
		if _scrubbing:
			_label.accept_event()
		else:
			committed.emit(_spin.value)
		return
	var mm := event as InputEventMouseMotion
	if mm == null or not _scrubbing:
		return
	# Accumulate sub-step motion rather than rounding each event: at 3 px per
	# step a slow drag delivers a stream of 1 px events that would each round to
	# zero, and the field would simply refuse to move.
	_scrub_accum += mm.relative.x
	var steps := int(_scrub_accum / SCRUB_PX_PER_STEP)
	if steps == 0:
		return
	_scrub_accum -= float(steps) * SCRUB_PX_PER_STEP
	var step := _step
	if mm.shift_pressed:
		step *= 0.1
	elif mm.ctrl_pressed:
		step *= 10.0
	set_value(_spin.value + float(steps) * step)
	_label.accept_event()


# ---------------------------------------------------------------------------
# Value
# ---------------------------------------------------------------------------

func value() -> float:
	return _spin.value if _spin != null else 0.0


## Set the value and tell everyone — the path a scrub or an external nudge takes.
func set_value(v: float) -> void:
	var want := clampf(v, _min, _max)
	if _spin == null or is_equal_approx(want, _spin.value):
		return
	set_value_silent(want)
	value_changed.emit(want)


## Set the value WITHOUT emitting. This is how a caller echoes back what the
## model actually stored (after snapping or clamping) — emitting here would
## feed that echo straight back in as a fresh edit.
func set_value_silent(v: float) -> void:
	if _spin == null:
		return
	var was := _echo
	_echo = true
	var want := clampf(v, _min, _max)
	_spin.value = want
	if _slider != null:
		_slider.value = want
	_echo = was


## Widen the range after construction — the offset slider's useful span depends
## on the stack it belongs to, which is not known until the part is selected.
func set_range(mn: float, mx: float) -> void:
	_min = mn
	_max = mx
	if _spin != null:
		_spin.min_value = mn
		_spin.max_value = mx
	if _slider != null:
		_slider.min_value = mn
		_slider.max_value = mx
		_slider.step = maxf(_step, (mx - mn) / 400.0)


func _on_spin_changed(v: float) -> void:
	if _echo:
		return
	if _slider != null:
		var was := _echo
		_echo = true
		_slider.value = v
		_echo = was
	value_changed.emit(v)


func _on_slider_changed(v: float) -> void:
	if _echo:
		return
	var was := _echo
	_echo = true
	_spin.value = v
	_echo = was
	value_changed.emit(_spin.value)
