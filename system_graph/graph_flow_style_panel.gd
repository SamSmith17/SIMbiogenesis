extends PopupPanel

## View options ▾ → Flow style… : the graph-wide flow style (GraphFlowStyle).
## A live preview ribbon at the top, two rows of presets (how wide / how it
## looks), then every knob of the look in folding sections: width, motion,
## light (glow, core, rim, swell, taper), colour, averaging and the legend,
## and the Flows lens's spacing. Every change applies live through
## `on_change(style)`; the view saves it with the graph and as the default
## for new graphs. A row whose value differs from the preset turns amber and
## shows a revert button back to the preset's value.

var on_change: Callable = Callable()
var _style: Dictionary = {}
var _rows: Dictionary = {}
var _preset_btns: Dictionary = {}
var _guard := false
var _preview: FlowPreview = null
var _accent: ColorPickerButton = null
var _status: Label = null
var _scroll: ScrollContainer = null


func setup(style: Dictionary, cb: Callable) -> void:
	on_change = cb
	_style = GraphFlowStyle.resolve(style)
	name = "FlowStyle"
	add_theme_stylebox_override("panel", UITheme.panel_style())
	var outer := VBoxContainer.new()
	outer.custom_minimum_size = Vector2(420.0, 0.0)
	outer.add_theme_constant_override("separation", 6)
	add_child(outer)
	outer.add_child(SectionHeader.make("Flow style", "route",
		"How flow shows on every wire of this graph"))

	_preview = FlowPreview.new()
	_preview.name = "flow_preview"
	_preview.custom_minimum_size = Vector2(400.0, 104.0)
	_preview.tooltip_text = "Three flows of one resource and a trickle, drawn the way the graph draws them"
	outer.add_child(_preview)

	outer.add_child(_preset_row("Width", GraphFlowStyle.WIDTH_PRESETS))
	outer.add_child(_preset_row("Looks", GraphFlowStyle.LOOK_PRESETS))
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	outer.add_child(_status)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(_scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)
	_scroll.add_child(box)

	# --- Width -------------------------------------------------------------
	var sw := _section(box, "Width", true)
	_add(sw, "scale", FormRow.option("Width follows", _items(GraphFlowStyle.SCALES, GraphFlowStyle.SCALE_LABELS),
		func(v: Variant) -> void: _set_key("scale", v),
		"Proportional: twice the flow, twice the width (a true Sankey). Square root and logarithmic squeeze a wide range.",
		"flow_scale"))
	_add(sw, "thickness", _slider("Biggest flow", "thickness", GraphFlowStyle.THICKNESS_MIN,
		GraphFlowStyle.THICKNESS_MAX, 1.0, " px", "Width of the biggest flow of each resource, at 100 % zoom"))
	_add(sw, "min_px", _slider("Thinnest live", "min_px", 0.5, GraphFlowStyle.MIN_PX_MAX, 0.5, " px",
		"A trickle is never thinner than this on screen"))
	_add(sw, "idle_px", _slider("Idle wire", "idle_px", 0.5, GraphFlowStyle.MIN_PX_MAX, 0.1, " px",
		"Width of a wire carrying nothing right now"))
	_add(sw, "ref", FormRow.option("Measured against", _items(GraphFlowStyle.REFS, GraphFlowStyle.REF_LABELS),
		func(v: Variant) -> void: _set_key("ref", v),
		"Biggest flow here: the busiest wire of each resource is the full width. Fixed: each resource's own reference rate.",
		"flow_ref"))
	_add(sw, "screen_space", FormRow.check("Zooming", "Keep widths on screen",
		func(on: bool) -> void: _set_key("screen_space", on),
		"On: wires stay bold when you zoom out (cards shrink, ribbons do not). Off: wires scale with the graph.",
		"flow_screen_space"))
	_add(sw, "zoom_floor", _slider("Zoomed out", "zoom_floor", 0.0, 1.0, 0.05, "",
		"How far wires may shrink when you zoom out (0.5 = never below half their full width)"))
	_add(sw, "taper", _slider("Taper ends", "taper", 0.0, 1.0, 0.05, "",
		"Ribbons narrow toward both ends, like a brush stroke"))

	# --- Motion ------------------------------------------------------------
	var sm := _section(box, "Motion", true)
	_add(sm, "anim", FormRow.option("Animation", _items(GraphFlowStyle.ANIMS, GraphFlowStyle.ANIM_LABELS),
		func(v: Variant) -> void: _set_key("anim", v),
		"What moves along a wire. Its speed shows how much flows, not how fast the clock runs.",
		"flow_anim"))
	_add(sm, "speed", _slider("Speed", "speed", 0.0, GraphFlowStyle.SPEED_MAX, 0.05, "×",
		"How fast the pattern moves (a bigger flow always moves faster)"))
	_add(sm, "period", _slider("Spacing", "period", 0.3, 4.0, 0.05, "×",
		"Distance between streaks, comets or beads"))
	_add(sm, "duty", _slider("Streak length", "duty", 0.05, 1.0, 0.05, "",
		"Short sparks (low) or long, soft streaks (high)"))
	_add(sm, "swell", _slider("Swell", "swell", 0.0, 1.0, 0.05, "",
		"How much a passing streak widens the ribbon: a pulse you can see from far out"))

	# --- Light -------------------------------------------------------------
	var sl := _section(box, "Light", true)
	_add(sl, "glow", _slider("Glow", "glow", 0.0, 1.0, 0.05, "", "Soft light round a live wire"))
	_add(sl, "glow_w", _slider("Glow width", "glow_w", 0.3, 5.0, 0.05, "×",
		"How far the glow reaches, in ribbon widths"))
	_add(sl, "core", _slider("Hot core", "core", 0.0, 1.0, 0.05, "",
		"A bright line down the middle of the ribbon"))
	_add(sl, "core_w", _slider("Core width", "core_w", 0.05, 0.9, 0.05, "",
		"Share of the ribbon the core takes"))
	_add(sl, "rim", _slider("Dark rim", "rim", 0.0, 1.0, 0.05, "",
		"Darker edges: ribbons read as tubes and stand apart where they cross"))
	_add(sl, "idle_alpha", _slider("Idle opacity", "idle_alpha", 0.0, 1.0, 0.05, "",
		"How visible a wire is while nothing flows on it"))

	# --- Colour ------------------------------------------------------------
	var sc := _section(box, "Colour", true)
	_add(sc, "colour", FormRow.option("Colour", _items(GraphFlowStyle.COLOURS, GraphFlowStyle.COLOUR_LABELS),
		func(v: Variant) -> void: _set_key("colour", v),
		"Resource colours keep power, water and food apart; heat colours by how much flows; one accent turns every wire the same colour.",
		"flow_colour"))
	_accent = ColorPickerButton.new()
	_accent.name = "flow_accent"
	_accent.edit_alpha = false
	_accent.custom_minimum_size = Vector2(120.0, 26.0)
	_accent.color = Color.html(str(_style["accent"]))
	_accent.color_changed.connect(func(c: Color) -> void: _set_key("accent", c.to_html(false)))
	var arow := FormRow.make("Accent", _accent, "The colour every wire takes with \"One accent colour\"")
	_add(sc, "accent", arow)
	_add(sc, "sat", _slider("Saturation", "sat", 0.0, 2.0, 0.05, "×", "0 = grey, 1 = as the resource is, 2 = vivid"))
	_add(sc, "bright", _slider("Brightness", "bright", 0.4, 2.0, 0.05, "×", "Lighter or darker than the resource colour"))

	# --- Averaging & legend --------------------------------------------------
	var sa := _section(box, "Averaging and legend", false)
	var sm_items: Array = []
	for h in GraphFlowStyle.SMOOTHING_CHOICES:
		var label := "Right now"
		if float(h) > 0.0:
			label = "Average over %s" % UiText.duration(float(h))
		sm_items.append([float(h), label])
	_add(sa, "smoothing_h", FormRow.option("Width shows", sm_items,
		func(v: Variant) -> void: _set_key("smoothing_h", float(v)),
		"Averaging over sim time steadies the picture at high speed (day and night stop flickering)",
		"flow_smoothing"))
	_add(sa, "legend", FormRow.check("Legend", "Show the width scale",
		func(on: bool) -> void: _set_key("legend", on),
		"Top-left of the graph: what a given width means for each resource", "flow_legend"))

	# --- Flows lens --------------------------------------------------------
	var sf := _section(box, "Flows lens", false)
	_add(sf, "lens_gap", _slider("Layer spacing", "lens_gap", 36.0, 220.0, 2.0, " px",
		"Room between the rows of the loop Sankey"))
	_add(sf, "lens_node_w", _slider("Node width", "lens_node_w", 80.0, 320.0, 2.0, " px",
		"How wide each machine or store is drawn"))
	_add(sf, "lens_return_gap", _slider("Return reach", "lens_return_gap", 16.0, 140.0, 2.0, " px",
		"How far the returning flows stand off the column"))
	_add(sf, "lens_return_alpha", _slider("Return opacity", "lens_return_alpha", 0.1, 1.0, 0.05, "",
		"Returns are drawn a little fainter than the main stream"))
	_add(sf, "lens_label", _slider("Label size", "lens_label", 0.6, 1.8, 0.05, "×", "Node names and values"))

	var foot := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)
	var back := Button.new()
	back.text = "Back to the preset"
	back.name = "flow_back_preset"
	back.tooltip_text = "Undo every change made on top of the preset"
	UITheme.style_button(back)
	back.pressed.connect(func() -> void: _pick_preset(str(_style["preset"])))
	foot.add_child(back)
	var reset := Button.new()
	reset.text = "Reset to Sankey"
	reset.name = "flow_reset"
	UITheme.style_button(reset)
	reset.pressed.connect(func() -> void: _pick_preset(GraphFlowStyle.PRESET_SANKEY))
	foot.add_child(reset)
	outer.add_child(foot)
	_sync()


func _notification(what: int) -> void:
	# The sections scroll: the panel never runs past the window.
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible:
		_fit_height.call_deferred()


func _fit_height() -> void:
	if _scroll == null or not is_inside_tree():
		return
	var vh := float(get_parent().get_viewport().get_visible_rect().size.y) if get_parent() != null else 900.0
	var top := float(position.y)
	_scroll.custom_minimum_size.y = clampf(vh - top - 300.0, 160.0, 640.0)


func style() -> Dictionary:
	return _style.duplicate()


## The preview ribbon (the harness reads it).
func preview() -> Control:
	return _preview


## Pick a preset (the harness and the preset buttons): every value resets to it.
func pick_preset(p: String) -> void:
	_pick_preset(p)


## Set one knob as the panel's own row would (the harness).
func set_knob(key: String, v: Variant) -> void:
	_set_key(key, v)


func _preset_row(caption: String, presets: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var lbl := Label.new()
	lbl.text = caption
	lbl.custom_minimum_size = Vector2(56.0, 0.0)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	row.add_child(lbl)
	for p in presets:
		var b := Button.new()
		b.text = str(GraphFlowStyle.PRESET_LABELS[p])
		b.tooltip_text = str(GraphFlowStyle.PRESET_TIPS.get(p, ""))
		b.toggle_mode = true
		b.name = "preset_" + str(p)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(b)
		b.pressed.connect(func() -> void: _pick_preset(str(p)))
		row.add_child(b)
		_preset_btns[p] = b
	return row


func _section(parent: VBoxContainer, title_text: String, open: bool) -> VBoxContainer:
	var c := Collapsible.make(title_text, open)
	c.name = "sec_" + title_text.to_lower().replace(" ", "_")
	parent.add_child(c)
	return c.body


func _slider(text: String, key: String, lo: float, hi: float, step: float, unit: String, tip: String) -> FormRow:
	return FormRow.slider(text, lo, hi, float(_style[key]), step, unit,
		func(v: float) -> void: _set_key(key, v), tip, "flow_" + key)


func _add(parent: VBoxContainer, key: String, r: FormRow) -> void:
	r.with_revert(func() -> void: _revert_key(key), "Back to the preset's value")
	parent.add_child(r)
	_rows[key] = r


func _pick_preset(p: String) -> void:
	_style = GraphFlowStyle.resolve({"preset": p})
	_sync()
	_emit()


func _revert_key(key: String) -> void:
	var sp := GraphFlowStyle.to_sparse(_style)
	sp.erase(key)
	_style = GraphFlowStyle.resolve(sp)
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
	var preset := str(_style["preset"])
	for p in _preset_btns:
		var b := _preset_btns[p] as Button
		b.set_pressed_no_signal(str(p) == preset)
		b.text = str(GraphFlowStyle.PRESET_LABELS[p]) + (" *" if custom and str(p) == preset else "")
	var classic := GraphFlowStyle.is_classic(_style)
	for key in _rows:
		var r: FormRow = _rows[key]
		if key != "accent":
			r.set_value(_style.get(key))
		r.set_dirty(sp.has(key))
		r.modulate.a = 0.5 if classic else 1.0
	if _accent != null:
		_accent.color = Color.html(str(_style["accent"]))
		(_rows["accent"] as FormRow).modulate.a = 1.0 if str(_style["colour"]) == GraphFlowStyle.COLOUR_MONO \
			and not classic else 0.45
	if _status != null:
		if classic:
			_status.text = "Classic draws the old thin wires; touch any knob to start from Sankey."
		elif custom:
			_status.text = I18n.f("{preset}, {sp} changed (amber rows)", {
				"preset": GraphFlowStyle.PRESET_LABELS[preset],
				"sp": UiText.count(sp.size() - 1, "setting"),
			})
		else:
			_status.text = str(GraphFlowStyle.PRESET_TIPS.get(preset, ""))
	if _preview != null:
		_preview.set_style(_style)
	_guard = false


static func _items(ids: Array, labels: Dictionary) -> Array:
	var out: Array = []
	for i in ids:
		out.append([i, str(labels.get(i, i))])
	return out


## The live sample at the top of the panel: four ribbons on S-curves (a full
## flow, half, a fifth and a trickle) in three resource colours, drawn with
## GraphFlowRibbons exactly as the canvas draws a wire, animated on its own
## clock.
class FlowPreview extends Control:
	const VALUES := [1.0, 0.5, 0.2, 0.04]
	var style: Dictionary = GraphFlowStyle.resolve({})
	var _look: Dictionary = GraphFlowStyle.look(style)
	var _t := 0.0

	func set_style(st: Dictionary) -> void:
		style = st.duplicate()
		_look = GraphFlowStyle.look(style)
		queue_redraw()

	func _ready() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_t += delta
		queue_redraw()

	## The path of ribbon i (an S across the box), shared with the harness.
	func path_of(i: int) -> PackedVector2Array:
		var w := size.x
		var h := size.y
		var y0 := h * (0.18 + 0.2 * float(i))
		var y1 := h * (0.88 - 0.2 * float(i))
		var pts := PackedVector2Array()
		for k in 33:
			var u := float(k) / 32.0
			var e := u * u * (3.0 - 2.0 * u)
			pts.append(Vector2(lerpf(18.0, w - 18.0, u), lerpf(y0, y1, e)))
		return pts

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(UITheme.C_BG, 0.96))
		var cols := [GraphTheme.channel("power"), GraphTheme.channel("water"),
			GraphTheme.channel("food"), GraphTheme.channel("water")]
		if GraphFlowStyle.is_classic(style):
			for i in VALUES.size():
				draw_polyline(path_of(i), Color(cols[i], 0.8), 2.0 + 3.0 * float(VALUES[i]), true)
			return
		var anim := str(style.get("anim", GraphFlowStyle.ANIM_STREAKS))
		for i in VALUES.size():
			var v := float(VALUES[i])
			var col: Color = cols[i]
			var width := GraphFlowStyle.width_px(style, v, 1.0, true, 1.0) * 0.6
			GraphFlowRibbons.draw(get_canvas_item(), path_of(i), {
				"width": width, "color": col, "color_end": col.lightened(0.18),
				"active": true, "anim": anim, "t": _t,
				"speed": GraphFlowStyle.anim_speed_px(style, v, 1.0),
				"look": _look, "heat": clampf(v, 0.0, 1.0),
				"intensity": clampf(sqrt(v), 0.25, 1.0),
			})
		var f := get_theme_default_font()
		draw_string(f, Vector2(8.0, size.y - 6.0), "full · half · a fifth · a trickle",
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, Color(UITheme.C_TEXT_M, 0.8))
