extends VBoxContainer

## The prop editor's Earthworks section: sink any placed model into the
## ground, open the terrain over its footprint, berm its sides, dig a daylight
## cut and an entry ramp. Edits the record's `earthworks` through its simple
## form (StructureEarthworks.from_simple); the Earthworks runtime does the
## terrain within a quarter second.
##
## `patch_fn(patch: Dictionary)` writes onto the record (the editor passes
## PlacedPropService.update_prop_record with a rebuild, since the seat moves).

const SIDE_ORDER := ["-z", "+z", "-x", "+x"]
const DAYLIGHT_WORDS := ["None", "Front", "Back", "Left", "Right"]
const DAYLIGHT_SIDES := ["", "+z", "-z", "-x", "+x"]

var patch_fn: Callable = Callable()
var fit_fn: Callable = Callable()       ## () -> [x0, z0, x1, z1] of the model
var status_fn: Callable = Callable()    ## () -> String

var _on: CheckBox
var _body: VBoxContainer
var _w: SpinBox
var _d: SpinBox
var _cx: SpinBox
var _cz: SpinBox
var _sink: SpinBox
var _hole: CheckBox
var _floor: SpinBox
var _roof: SpinBox
var _slab: CheckBox
var _walls: CheckBox
var _lights: CheckBox
var _berm: Dictionary = {}      ## side -> SpinBox (m; -1 = to the roof)
var _berm_roof: Dictionary = {} ## side -> CheckBox
var _run: SpinBox
var _day: OptionButton
var _cut_w: SpinBox
var _ramp: SpinBox
var _status: Label
var _syncing := false
var _pending := false
var _timer := 0.0


func _ready() -> void:
	add_theme_constant_override("separation", UITheme.SPACE_XS)
	_on = CheckBox.new()
	_on.text = "Shape the ground round it"
	_on.tooltip_text = "Sink it, open the terrain over its footprint so you can walk in, berm its sides"
	_on.toggled.connect(func(_p: bool) -> void: _changed())
	add_child(_on)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", UITheme.SPACE_XS)
	add_child(_body)
	var g := _grid()
	_sink = _spin(g, "Sink below grade", 0.05, -5.0, 15.0, " m",
		"How far its base sits below the ground. A basement or an earth-sheltered room is sunk.")
	_floor = _spin(g, "Floor", 0.05, -15.0, 10.0, " m",
		"The floor inside the opening, measured from the model's base")
	_roof = _spin(g, "Roof", 0.05, 0.5, 30.0, " m",
		"The roof, from the model's base: rain runs off here; berms 'to the roof' rise to it")
	_hole = _check(_body, "Open the ground over its footprint",
		"The terrain is cut out exactly at the footprint, so you walk in on the model's own floor")
	var g2 := _grid()
	_w = _spin(g2, "Width", 0.1, 0.5, 200.0, " m", "Footprint width (left-right)")
	_d = _spin(g2, "Depth", 0.1, 0.5, 200.0, " m", "Footprint depth (back-front)")
	_cx = _spin(g2, "Centre right", 0.1, -100.0, 100.0, " m", "Footprint centre, along the model's right")
	_cz = _spin(g2, "Centre front", 0.1, -100.0, 100.0, " m", "Footprint centre, toward the model's front")
	var fit := Button.new()
	fit.text = "Fit to the model"
	fit.tooltip_text = "The footprint becomes the model's own outline"
	UITheme.style_button(fit)
	fit.pressed.connect(_on_fit)
	_body.add_child(fit)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_body.add_child(row)
	_slab = _check(row, "Floor slab", "A concrete floor at the floor height, for a model with none of its own")
	_walls = _check(row, "Retaining walls", "Concrete walls round the opening, up to the ground (not on the daylight side)")
	_lights = _check(row, "Lights", "Dim ceiling lights inside when the floor is below the ground")
	_body.add_child(SectionHeader.make("Berms"))
	var g3 := GridContainer.new()
	g3.columns = 3
	g3.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	_body.add_child(g3)
	for side in SIDE_ORDER:
		_label(g3, str(StructureEarthworks.SIDE_WORDS[side]))
		var sb := _bare_spin(0.1, 0.0, 20.0, " m", "Earth piled against this side, above the ground (0 = none)")
		g3.add_child(sb)
		_berm[side] = sb
		var cb := CheckBox.new()
		cb.text = "to the roof"
		cb.tooltip_text = "The berm rises to the roof line"
		cb.toggled.connect(func(_p: bool) -> void: _changed())
		g3.add_child(cb)
		_berm_roof[side] = cb
	var g4 := _grid()
	_run = _spin(g4, "Berm slope 1:", 0.1, 0.3, 12.0, "",
		"Metres out for each metre of height (1.5 = a steep berm, 3 = a gentle one)")
	_body.add_child(SectionHeader.make("Daylight side"))
	var g5 := _grid()
	_label(g5, "Open side")
	_day = OptionButton.new()
	for w in DAYLIGHT_WORDS:
		_day.add_item(w)
	_day.tooltip_text = "The side left open to the light: dug down to the floor in front of it, no wall"
	_day.item_selected.connect(func(_i: int) -> void: _changed())
	g5.add_child(_day)
	_cut_w = _spin(g5, "Dug out", 0.1, 0.5, 30.0, " m", "How far the cut in front of the open side reaches")
	_ramp = _spin(g5, "Entry ramp", 0.1, 0.0, 40.0, " m", "A ramp from the ground down into the cut (0 = none)")
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)


func _grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	g.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
	_body.add_child(g)
	return g


func _label(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	l.custom_minimum_size.x = 96.0
	parent.add_child(l)
	return l


func _bare_spin(step: float, lo: float, hi: float, suffix: String, tip: String) -> SpinBox:
	var sb := SpinBox.new()
	sb.step = step
	sb.min_value = lo
	sb.max_value = hi
	sb.suffix = suffix
	sb.tooltip_text = tip
	sb.custom_minimum_size.x = 84.0
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.value_changed.connect(func(_v: float) -> void: _changed())
	return sb


func _spin(g: GridContainer, text: String, step: float, lo: float, hi: float, suffix: String, tip: String) -> SpinBox:
	_label(g, text).tooltip_text = tip
	var sb := _bare_spin(step, lo, hi, suffix, tip)
	g.add_child(sb)
	return sb


func _check(parent: Control, text: String, tip: String) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = text
	cb.tooltip_text = tip
	cb.toggled.connect(func(_p: bool) -> void: _changed())
	parent.add_child(cb)
	return cb


## Fill from a record (no edits fire).
func load_record(rec: Dictionary) -> void:
	_syncing = true
	var has := rec.has(StructureEarthworks.KEY)
	var sm := StructureEarthworks.simple_of(rec.get(StructureEarthworks.KEY, {}))
	if not has and fit_fn.is_valid():
		var r: Variant = fit_fn.call()
		if r is Array and (r as Array).size() == 4:
			sm["rect"] = r
	_on.set_pressed_no_signal(has and StructureEarthworks.is_on(rec))
	_body.visible = _on.button_pressed
	var rc: Array = sm["rect"]
	_w.set_value_no_signal(float(rc[2]) - float(rc[0]))
	_d.set_value_no_signal(float(rc[3]) - float(rc[1]))
	_cx.set_value_no_signal((float(rc[0]) + float(rc[2])) * 0.5)
	_cz.set_value_no_signal((float(rc[1]) + float(rc[3])) * 0.5)
	_sink.set_value_no_signal(float(sm["sink_m"]))
	_floor.set_value_no_signal(float(sm["floor_y"]))
	_roof.set_value_no_signal(float(sm["roof_y"]))
	_hole.set_pressed_no_signal(bool(sm["hole"]))
	_slab.set_pressed_no_signal(bool(sm["slab"]))
	_walls.set_pressed_no_signal(bool(sm["walls"]))
	_lights.set_pressed_no_signal(bool(sm.get("lights", true)))
	var b: Dictionary = sm["berm"] if sm["berm"] is Dictionary else {}
	for side in SIDE_ORDER:
		var h := float(b.get(side, 0.0))
		(_berm_roof[side] as CheckBox).set_pressed_no_signal(h < 0.0)
		(_berm[side] as SpinBox).set_value_no_signal(maxf(h, 0.0))
		(_berm[side] as SpinBox).editable = h >= 0.0
	_run.set_value_no_signal(float(sm["berm_run"]))
	_day.selected = maxi(DAYLIGHT_SIDES.find(str(sm["daylight"])), 0)
	_cut_w.set_value_no_signal(float(sm["cut_w"]))
	_ramp.set_value_no_signal(float(sm["ramp_len"]))
	_syncing = false
	_refresh_status()


## The simple form the widgets show.
func simple() -> Dictionary:
	var x0 := _cx.value - _w.value * 0.5
	var z0 := _cz.value - _d.value * 0.5
	var berm := {}
	for side in SIDE_ORDER:
		if (_berm_roof[side] as CheckBox).button_pressed:
			berm[side] = -1.0
		elif (_berm[side] as SpinBox).value > 0.01:
			berm[side] = (_berm[side] as SpinBox).value
	return {"sink_m": _sink.value, "rect": [x0, z0, x0 + _w.value, z0 + _d.value],
		"hole": _hole.button_pressed, "floor_y": _floor.value, "roof_y": _roof.value,
		"slab": _slab.button_pressed, "walls": _walls.button_pressed, "lights": _lights.button_pressed, "berm": berm,
		"berm_run": _run.value, "daylight": DAYLIGHT_SIDES[_day.selected],
		"cut_w": _cut_w.value, "ramp_len": _ramp.value, "ramp_w": 1.6}


func _changed() -> void:
	if _syncing:
		return
	_body.visible = _on.button_pressed
	for side in SIDE_ORDER:
		(_berm[side] as SpinBox).editable = not (_berm_roof[side] as CheckBox).button_pressed
	_pending = true
	_timer = 0.3


func _process(delta: float) -> void:
	if _pending:
		_timer -= delta
		if _timer <= 0.0:
			_pending = false
			_commit()
	elif is_visible_in_tree() and Engine.get_process_frames() % 30 == 0:
		_refresh_status()


func _commit() -> void:
	if not patch_fn.is_valid():
		return
	if not _on.button_pressed:
		patch_fn.call({StructureEarthworks.KEY: null})
		return
	patch_fn.call({StructureEarthworks.KEY: StructureEarthworks.from_simple(simple())})


func _on_fit() -> void:
	if not fit_fn.is_valid():
		return
	var r: Variant = fit_fn.call()
	if not (r is Array) or (r as Array).size() != 4:
		return
	_syncing = true
	_w.set_value_no_signal(float(r[2]) - float(r[0]))
	_d.set_value_no_signal(float(r[3]) - float(r[1]))
	_cx.set_value_no_signal((float(r[0]) + float(r[2])) * 0.5)
	_cz.set_value_no_signal((float(r[1]) + float(r[3])) * 0.5)
	_syncing = false
	_changed()


func _refresh_status() -> void:
	if _status != null and status_fn.is_valid():
		_status.text = str(status_fn.call())
