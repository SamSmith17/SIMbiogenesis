extends PopupPanel

## View options ▾ → Flow style… : the graph-wide flow style (GraphFlowStyle)
## with a preset row, the width rule, the motion, the averaging and the
## scale legend. Every change applies live through `on_change(style)`; the
## view saves it with the graph and as the default for new graphs.

var on_change: Callable = Callable()
var _style: Dictionary = {}
var _rows: Dictionary = {}
var _preset_btns: Dictionary = {}
var _guard := false


func setup(style: Dictionary, cb: Callable) -> void:
	on_change = cb
	_style = GraphFlowStyle.resolve(style)
	name = "FlowStyle"
	add_theme_stylebox_override("panel", UITheme.panel_style())
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(380.0, 0.0)
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	box.add_child(SectionHeader.make("Flow style", "route",
		"How flow shows on every wire of this graph"))
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 4)
	var group := ButtonGroup.new()
	for p in GraphFlowStyle.PRESETS:
		var b := Button.new()
		b.text = str(GraphFlowStyle.PRESET_LABELS[p])
		b.tooltip_text = str(GraphFlowStyle.PRESET_TIPS.get(p, ""))
		b.toggle_mode = true
		b.button_group = group
		b.name = "preset_" + str(p)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(b)
		b.pressed.connect(func() -> void: _pick_preset(str(p)))
		presets.add_child(b)
		_preset_btns[p] = b
	box.add_child(presets)

	box.add_child(SectionHeader.make("Width", "move-horizontal"))
	_rows["scale"] = FormRow.option("Width follows", _items(GraphFlowStyle.SCALES, GraphFlowStyle.SCALE_LABELS),
		func(v: Variant) -> void: _set_key("scale", v),
		"Proportional: twice the flow, twice the width (a true Sankey). Square root and logarithmic squeeze a wide range.",
		"flow_scale")
	box.add_child(_rows["scale"])
	_rows["thickness"] = FormRow.slider("Biggest flow", GraphFlowStyle.THICKNESS_MIN,
		GraphFlowStyle.THICKNESS_MAX, float(_style["thickness"]), 1.0, " px",
		func(v: float) -> void: _set_key("thickness", v),
		"Width of the biggest flow of each resource, at 100 % zoom", "flow_thickness")
	box.add_child(_rows["thickness"])
	_rows["min_px"] = FormRow.slider("Thinnest live", 0.5, GraphFlowStyle.MIN_PX_MAX,
		float(_style["min_px"]), 0.5, " px", func(v: float) -> void: _set_key("min_px", v),
		"A trickle is never thinner than this on screen", "flow_min_px")
	box.add_child(_rows["min_px"])
	_rows["ref"] = FormRow.option("Measured against", _items(GraphFlowStyle.REFS, GraphFlowStyle.REF_LABELS),
		func(v: Variant) -> void: _set_key("ref", v),
		"Biggest flow here: the busiest wire of each resource is the full width. Fixed: each resource's own reference rate.",
		"flow_ref")
	box.add_child(_rows["ref"])
	_rows["screen_space"] = FormRow.check("Zooming", "Keep widths on screen",
		func(on: bool) -> void: _set_key("screen_space", on),
		"On: wires stay bold when you zoom out (cards shrink, ribbons do not). Off: wires scale with the graph.",
		"flow_screen_space")
	box.add_child(_rows["screen_space"])
	_rows["zoom_floor"] = FormRow.slider("Zoomed out", 0.0, 1.0, float(_style["zoom_floor"]), 0.05, "",
		func(v: float) -> void: _set_key("zoom_floor", v),
		"How far wires may shrink when you zoom out (0.5 = never below half their full width)",
		"flow_zoom_floor")
	box.add_child(_rows["zoom_floor"])

	box.add_child(SectionHeader.make("Motion", "activity"))
	_rows["anim"] = FormRow.option("Animation", _items(GraphFlowStyle.ANIMS, GraphFlowStyle.ANIM_LABELS),
		func(v: Variant) -> void: _set_key("anim", v),
		"What moves along a wire. Its speed shows how much flows, not how fast the clock runs.",
		"flow_anim")
	box.add_child(_rows["anim"])
	_rows["speed"] = FormRow.slider("Speed", 0.0, GraphFlowStyle.SPEED_MAX, float(_style["speed"]),
		0.05, "×", func(v: float) -> void: _set_key("speed", v), "How fast the pattern moves", "flow_speed")
	box.add_child(_rows["speed"])
	_rows["glow"] = FormRow.slider("Glow", 0.0, 1.0, float(_style["glow"]), 0.05, "",
		func(v: float) -> void: _set_key("glow", v), "Soft light round a live wire", "flow_glow")
	box.add_child(_rows["glow"])
	_rows["gradient"] = FormRow.check("Direction", "Brighter toward the destination",
		func(on: bool) -> void: _set_key("gradient", on),
		"A live wire lightens along its length, so its direction reads even when still", "flow_gradient")
	box.add_child(_rows["gradient"])

	box.add_child(SectionHeader.make("Averaging", "clock"))
	var sm_items: Array = []
	for h in GraphFlowStyle.SMOOTHING_CHOICES:
		var label := "Right now"
		if float(h) > 0.0:
			label = "Average over %s" % UiText.duration(float(h))
		sm_items.append([float(h), label])
	_rows["smoothing_h"] = FormRow.option("Width shows", sm_items,
		func(v: Variant) -> void: _set_key("smoothing_h", float(v)),
		"Averaging over sim time steadies the picture at high speed (day and night stop flickering)",
		"flow_smoothing")
	box.add_child(_rows["smoothing_h"])
	_rows["legend"] = FormRow.check("Legend", "Show the width scale",
		func(on: bool) -> void: _set_key("legend", on),
		"Top-left of the graph: what a given width means for each resource", "flow_legend")
	box.add_child(_rows["legend"])

	var foot := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)
	var reset := Button.new()
	reset.text = "Reset to Sankey"
	reset.name = "flow_reset"
	UITheme.style_button(reset)
	reset.pressed.connect(func() -> void: _pick_preset(GraphFlowStyle.PRESET_SANKEY))
	foot.add_child(reset)
	box.add_child(foot)
	_sync()


func style() -> Dictionary:
	return _style.duplicate()


## Pick a preset (the harness and the preset buttons): every value resets to it.
func pick_preset(p: String) -> void:
	_pick_preset(p)


func _pick_preset(p: String) -> void:
	_style = GraphFlowStyle.resolve({"preset": p})
	_sync()
	_emit()


func _set_key(key: String, v: Variant) -> void:
	if _guard:
		return
	var sp := GraphFlowStyle.to_sparse(_style)
	sp[key] = v
	if str(sp.get("preset", "")) == GraphFlowStyle.PRESET_CLASSIC:
		# Touching any knob leaves the old look: start from the Sankey values.
		var base := GraphFlowStyle.to_sparse(_style)
		base["preset"] = GraphFlowStyle.PRESET_SANKEY
		base[key] = v
		sp = base
	_style = GraphFlowStyle.resolve(sp)
	_sync()
	_emit()


func _emit() -> void:
	if on_change.is_valid():
		on_change.call(_style.duplicate())


func _sync() -> void:
	_guard = true
	var sp := GraphFlowStyle.to_sparse(_style)
	var custom := sp.size() > 1
	for p in _preset_btns:
		(_preset_btns[p] as Button).set_pressed_no_signal(not custom and str(p) == str(_style["preset"]))
	for key in _rows:
		var r: FormRow = _rows[key]
		r.set_value(_style.get(key))
	var classic := GraphFlowStyle.is_classic(_style)
	for key in _rows:
		(_rows[key] as FormRow).modulate.a = 0.5 if classic else 1.0
	_guard = false


static func _items(ids: Array, labels: Dictionary) -> Array:
	var out: Array = []
	for i in ids:
		out.append([i, str(labels.get(i, i))])
	return out
