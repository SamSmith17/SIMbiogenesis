extends Node

## The festival SETUP CARD: "a gathering of N camps of M people", named, laid
## out round the location marker in one click (FestivalMode.setup_gathering →
## FestivalSeedLayout.setup_layout). Camps are then moved / reshaped / renamed
## with the site editor; this card only makes the first draft, and running it
## again replaces what it made before (never the player's own camps).
##
## Opened from the festival panel. A ModalFrame: Esc / the close button /
## Cancel leave without changing anything.

signal laid_out(placed: int)

const SHARED_VENUES: Array = [
	["restroom", "Portapotties"], ["water_point", "Water station"], ["shower", "Showers"],
	["stage", "Stage"], ["center_camp", "Center camp"], ["temple", "Temple"], ["art", "Art pieces"],
]
const SUPPLY_CHOICES: Array = [
	["infinite", "Infinite, metered (a calculator)"],
	["own", "Each camp's own tanks"],
	["shared", "Shared site depots"],
]

var _fm: Node = null
var _frame: ModalFrame = null
var _rows_box: VBoxContainer = null
var _count: SpinBox = null
var _each: SpinBox = null
var _provision: OptionButton = null
var _supply: OptionButton = null
var _venue_boxes: Dictionary = {}
var _rows: Array = []   # [{name: LineEdit, people: SpinBox, style: OptionButton}]
var _total_lbl: Label = null


func open(fm: Node) -> void:
	_fm = fm
	if _frame == null:
		_build()
	var d: Dictionary = fm.call("setup_defaults") if fm != null and fm.has_method("setup_defaults") else {}
	var camps: Array = d.get("camps", [])
	_count.set_value_no_signal(maxi(camps.size(), 1))
	_set_rows(camps)
	var venues: Array = d.get("venues", FestivalSeedLayout.SETUP_DEFAULT_VENUES)
	for t in _venue_boxes.keys():
		(_venue_boxes[t] as CheckBox).button_pressed = venues.has(t)
	var prov := str(d.get("provision", PopTestPrefs.provision_preset()))
	for i in _provision.item_count:
		if str(_provision.get_item_metadata(i)) == prov:
			_provision.select(i)
	_frame.open()


func is_open() -> bool:
	return _frame != null and _frame.is_open()


func _build() -> void:
	_frame = ModalFrame.create("Set up the gathering",
		"Named camps laid out round the location marker — move and reshape them afterwards",
		Vector2(760, 720), "festival_setup")
	add_child(_frame)
	var b := _frame.body
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	b.add_child(head)
	head.add_child(_lbl("Camps"))
	_count = _spin(1, FestivalSeedLayout.SETUP_MAX_CAMPS, 1, 6)
	_count.value_changed.connect(func(v: float) -> void: _resize_rows(int(v)))
	head.add_child(_count)
	head.add_child(_lbl("People in each"))
	_each = _spin(FestivalSeedLayout.MIN_HEADCOUNT, 200, 1, 10)
	head.add_child(_each)
	var apply_each := Button.new()
	UITheme.style_button(apply_each)
	apply_each.text = "Set all"
	apply_each.tooltip_text = "Give every camp this many people"
	apply_each.pressed.connect(func() -> void:
		for r in _rows:
			((r as Dictionary)["people"] as SpinBox).value = _each.value)
	head.add_child(apply_each)
	b.add_child(SectionHeader.make("Camps", "", "name · people · style"))
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	b.add_child(_rows_box)
	_total_lbl = _lbl("")
	_total_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	b.add_child(_total_lbl)
	b.add_child(_lbl("Festival length (how much each camp's own stores hold)"))
	_provision = OptionButton.new()
	for pid in CampProvisioning.PRESET_ORDER:
		_provision.add_item(str((CampProvisioning.PRESETS[pid] as Dictionary)["label"]))
		_provision.set_item_metadata(_provision.item_count - 1, pid)
	b.add_child(_provision)
	b.add_child(_lbl("Water, food and waste"))
	_supply = OptionButton.new()
	for c in SUPPLY_CHOICES:
		_supply.add_item(str(c[1]))
		_supply.set_item_metadata(_supply.item_count - 1, str(c[0]))
	_supply.tooltip_text = "Infinite: nothing runs out, every litre and kilo is metered per camp (the calculator). Own: each camp's tanks drain and fill. Shared: camps draw from site depots. Applies to the camps laid out here; camps of your own keep theirs. Change any camp later."
	b.add_child(_supply)
	b.add_child(_lbl("Shared venues to add (where the site has none yet)"))
	var grid := GridContainer.new()
	grid.columns = 3
	b.add_child(grid)
	for v in SHARED_VENUES:
		var cb := CheckBox.new()
		cb.text = str(v[1])
		cb.button_pressed = true
		grid.add_child(cb)
		_venue_boxes[str(v[0])] = cb
	_frame.add_button("Cancel", ModalFrame.SECONDARY, _frame.close)
	_frame.add_button("Lay out", ModalFrame.PRIMARY, _lay_out,
		"Replace what festival mode laid out before with these camps")


func _set_rows(camps: Array) -> void:
	for r in _rows:
		((r as Dictionary)["row"] as Node).queue_free()
	_rows.clear()
	for c in camps:
		_add_row(c as Dictionary)
	_refresh_total()


func _resize_rows(n: int) -> void:
	while _rows.size() > n:
		var r: Dictionary = _rows.pop_back()
		var row: Node = r["row"]
		_rows_box.remove_child(row)
		row.queue_free()
	while _rows.size() < n:
		_add_row({"name": "Camp %d" % (_rows.size() + 1), "people": int(_each.value),
			"style": CampStyles.DEFAULT_STYLE})
	_refresh_total()


func _add_row(c: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_rows_box.add_child(row)
	var num := _lbl("%d" % (_rows.size() + 1))
	num.custom_minimum_size.x = 22
	row.add_child(num)
	var name_e := LineEdit.new()
	name_e.text = str(c.get("name", ""))
	name_e.placeholder_text = "Camp name"
	name_e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_e)
	var ppl := _spin(FestivalSeedLayout.MIN_HEADCOUNT, FestivalSeedLayout.MAX_HEADCOUNT, 1, int(c.get("people", 10)))
	ppl.suffix = "people"
	ppl.value_changed.connect(func(_v: float) -> void: _refresh_total())
	row.add_child(ppl)
	var style := OptionButton.new()
	var want := str(c.get("style", CampStyles.DEFAULT_STYLE))
	for sid in CampStyles.STYLES.keys():
		style.add_item(CampStyles.label(str(sid)))
		style.set_item_metadata(style.item_count - 1, str(sid))
		if str(sid) == want:
			style.select(style.item_count - 1)
	row.add_child(style)
	_rows.append({"row": row, "name": name_e, "people": ppl, "style": style})


func _refresh_total() -> void:
	if _total_lbl == null:
		return
	var n := 0
	for r in _rows:
		n += int(((r as Dictionary)["people"] as SpinBox).value)
	_total_lbl.text = "%s · %s in all" % [UiText.count(_rows.size(), "camp"), UiText.count(n, "person", "people")]


func spec() -> Dictionary:
	var camps: Array = []
	for r in _rows:
		var d: Dictionary = r
		var st: OptionButton = d["style"]
		camps.append({"name": (d["name"] as LineEdit).text, "people": int((d["people"] as SpinBox).value),
			"style": str(st.get_item_metadata(st.selected)) if st.selected >= 0 else CampStyles.DEFAULT_STYLE})
	var venues: Array = []
	for t in _venue_boxes.keys():
		if (_venue_boxes[t] as CheckBox).button_pressed:
			venues.append(t)
	return {"camps": camps, "venues": venues, "replace": true,
		"provision": str(_provision.get_item_metadata(_provision.selected)) if _provision.selected >= 0 else "",
		"supply": str(_supply.get_item_metadata(_supply.selected)) if _supply.selected >= 0 else ""}


func _lay_out() -> void:
	if _fm == null:
		return
	var s := spec()
	_frame.close()
	var placed: int = await _fm.call("setup_gathering", s)
	laid_out.emit(placed)


func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	l.add_theme_color_override("font_color", UITheme.C_TEXT)
	return l


func _spin(lo: float, hi: float, step: float, val: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	return s
