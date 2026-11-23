extends Control

## The Battery Lab: design a solar battery pack from its cells up — the
## form factor, the chemistry and cell, how many in series and in parallel,
## how they are arranged and joined, the BMS and the case — and see every
## part, exploded or cut open, with the numbers worked out in plain words.
## A press on a cell, the BMS, a sensor or a fitting selects it; dragging
## slides it (the leads are drawn again so they still reach it). On the
## Bank tab the same gesture moves a pack, and its cables follow.
## Opened from the library; Main hosts it (`open_batterylab`). The BMS
## simulation (Phase 3) and banks (Phase 4) come later
## (plans/BATTERY_LAB_PLAN.md).
##
## For people new to batteries: "Show me" numbers the parts on the picture
## with a line on what each does, and the tour walks cell → parallel →
## series → BMS → case. "Colour by" paints the cells by series group, by
## place in their group, or by how far up the string they sit.

const MODAL_NAME := "batterylab_designer"
## What the Lab was last left at (the design, the bank round it, the tab
## and the view), so opening it again carries on where it was.
const DRAFT_FILE := "user://batterylab_draft.json"
const WANT := Vector2(1640, 980)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.2
## A press that moves less than this stays a click (the studio uses the same).
const DRAG_PX := 4.0
const DRAG_REBUILD := 0.05
const TEST_PANEL := preload("res://scenes/ui/batterylab_test_panel.gd")
const BANK_PANEL := preload("res://scenes/ui/batterylab_bank_panel.gd")
## Protection rows: [key, label, unit kind "v" | "a" | "c"].
const PROT_ROWS := [
	["cell_ov", "Cell too high", "v"], ["cell_uv", "Cell too low", "v"],
	["charge_oc", "Charge current", "a"], ["discharge_oc", "Discharge current", "a"],
	["discharge_oc2", "Discharge (fast)", "a"], ["short_circuit", "Short circuit", "a"],
	["charge_ot", "Charge too hot", "c"], ["discharge_ot", "Discharge too hot", "c"],
	["charge_ut", "Charge too cold", "c"], ["discharge_ut", "Discharge too cold", "c"],
]

const COLOUR_WORDS := {
	"part": "Parts", "series": "Series group", "parallel": "Place in its group",
	"voltage": "Voltage up the string",
}
const COLOUR_TIPS := {
	"part": "The cells as they look",
	"series": "Each group of cells in parallel its own colour: the groups are joined one after another in series",
	"parallel": "Each cell's place inside its group: cells in one group share a voltage",
	"voltage": "Blue at the pack's negative to red at its positive: each series group adds its cells' voltage",
}

## The guided tour: [title, words, explode, cutaway, colour, focus part].
const TOUR := [
	["1 · The cell", "A battery is built from cells. Each cell gives a fixed voltage (3.2 V for LFP, 3.6 V for NMC, 2 V for lead-acid) and holds a number of amp-hours.", 0.0, true, "part", "cell_0_0"],
	["2 · In parallel", "Cells side by side, positive to positive, act as one bigger cell: the same voltage, their amp-hours added. A group of them is a 'P-group'.", 0.0, true, "parallel", "cell_0_0"],
	["3 · In series", "Groups joined end to end, negative to positive, add their voltages. 16 LFP groups make a 51.2 V pack. The colour climbs from the pack's negative to its positive.", 0.35, true, "voltage", "link_0"],
	["4 · The BMS", "The battery management system reads every joint through the thin balance leads, measures the current, and opens the charge or discharge switch to keep each cell inside its limits.", 0.6, true, "part", "bms"],
	["5 · The case", "The case holds the cells, the breaker and the terminals. Lithium packs carry a breaker; lead-acid blocks are their own case and have no BMS.", 0.0, false, "part", "term_pos"],
]

var _active := false
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _bound_prop_id := ""
var _undo: Array = []
var _redo: Array = []
var _coalesce_key := ""
var _coalesce_until := 0.0
var _rebuild_timer := -1.0
var _entries: Array = []
var _chem_filter := ""
var _colour := "part"
var _explode := 0.0
var _cutaway := false
var _learn := false
var _tour := -1
var _selected := ""
## Live part drag: {id, bank, press, moved, n0: Vector3, hit0: Vector3, plane: Vector3, label}.
var _drag: Dictionary = {}
var _framed_key := ""
var _mode := "pack"
var _tabs: TabBar
var _test: VBoxContainer
var _prot_box: VBoxContainer
var _prot_sig := ""
var _bank: Dictionary = {}
var _bank_panel: VBoxContainer
var _bank_builder: BankBuilder
var _bank_design: Dictionary = {}
var _bound_graph_id := ""
var _chain: PowerChainBar = null
var _bank_framed := ""

# UI
var _shell: DesignerShell
var _gallery: DesignGallery
var _sort: OptionButton
var _view_stack: Control
var _studio: StudioViewport
var _overlay: Callouts
var _builder: BattBuilder
var _col: DesignerColumn
var _explode_sl: HSlider
var _cut_btn: Button
var _colour_opt: OptionButton
var _learn_btn: Button
var _tour_btn: Button
var _info_lbl: Label
var _tour_lbl: Label
var _explain_box: VBoxContainer
var _checks_box: VBoxContainer
var _rows: Dictionary = {}
var _vals: Dictionary = {}
var _chem_opt: OptionButton
var _cell_opt: OptionButton
var _bms_opt: OptionButton
var _wrap_pick: ColorPickerButton
var _case_pick: ColorPickerButton
var _status_lbl: Label


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process(false)


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

## opts: {spec, prop_id}.
func open(opts: Dictionary = {}) -> void:
	if _active:
		close()
	_bound_prop_id = str(opts.get("prop_id", ""))
	_bound_graph_id = str(opts.get("graph_item_id", ""))
	var spec: Dictionary = opts.get("spec", {}) as Dictionary
	var bank: Dictionary = opts.get("bank", {}) as Dictionary
	var start_mode := str(opts.get("mode", "pack"))
	if not _bound_prop_id.is_empty():
		var rec: Dictionary = PlacedPropService.get_prop_record(_main(), _bound_prop_id) if _main() != null else {}
		if rec.get("battery_bank_spec") is Dictionary:
			bank = rec["battery_bank_spec"]
		start_mode = "bank"
	elif not _bound_graph_id.is_empty():
		bank = _bank_from_graph(_bound_graph_id)
		start_mode = "bank"
	if not bank.is_empty():
		var rb := BankSpec.resolve(bank)
		spec = rb["pack"]
		_bank = _bank_fields(rb)
	else:
		_bank = _bank_fields(BankSpec.empty())
	# Opened on nothing in particular: carry on from the last design.
	var draft := _load_draft()
	if spec.is_empty() and draft.get("spec") is Dictionary:
		spec = draft["spec"]
		if bank.is_empty() and draft.get("bank") is Dictionary:
			_bank = _bank_fields(BankSpec.resolve(draft["bank"]))
		if not opts.has("mode") and str(draft.get("mode", "")) in ["pack", "test", "bank"]:
			start_mode = str(draft["mode"])
	if not draft.is_empty():
		_colour = str(draft.get("colour", _colour))
		_explode = clampf(float(draft.get("explode", _explode)), 0.0, 1.0)
		_cutaway = bool(draft.get("cutaway", _cutaway))
	if spec.is_empty():
		spec = BattPresets.builtin("rack_48v_105")
	_spec = BattSpec.resolve(spec)
	_chem_filter = ""
	_undo.clear()
	_redo.clear()
	_selected = ""
	_drag = {}
	_tour = -1
	_framed_key = ""
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_shell.open()
	_shell.scroll_top()
	_studio.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_refresh_design_list()
	_bank_panel.call("set_bound", not _bound_prop_id.is_empty() or not _bound_graph_id.is_empty())
	set_explode(_explode)
	set_cutaway(_cutaway)
	set_colour(_colour)
	_rebuild_now()
	set_mode(start_mode)
	_refresh_chain()


func close() -> void:
	if not _active:
		return
	if not _drag.is_empty():
		_finish_drag()
	_save_draft()
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	if _studio != null:
		_studio.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_shell.close()


func is_open() -> bool:
	return _active


## The draft: the design and the bank fields being worked on, the tab and
## the view. Written on close (a bound bank keeps its own record, so only
## the view is written then) and read by the next open.
func _save_draft() -> void:
	var d := _load_draft()
	d["v"] = 1
	d["colour"] = _colour
	d["explode"] = _explode
	d["cutaway"] = _cutaway
	if _bound_prop_id.is_empty() and _bound_graph_id.is_empty():
		d["spec"] = _spec.duplicate(true)
		d["bank"] = _bank.duplicate(true)
		d["mode"] = _mode
	var f := FileAccess.open(DRAFT_FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d, "\t"))


static func _load_draft() -> Dictionary:
	if not FileAccess.file_exists(DRAFT_FILE):
		return {}
	var f := FileAccess.open(DRAFT_FILE, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	return v if v is Dictionary else {}


## Forget the draft (a check starts from nothing).
static func clear_draft() -> void:
	if FileAccess.file_exists(DRAFT_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DRAFT_FILE))


func spec() -> Dictionary:
	return _spec


func design() -> Dictionary:
	return _design


func builder() -> BattBuilder:
	return _builder


func studio() -> StudioViewport:
	return _studio


func _process(delta: float) -> void:
	if _rebuild_timer > 0.0:
		_rebuild_timer -= delta
		if _rebuild_timer <= 0.0:
			# A bank drag only moves packs; skip rebuilding the pack mesh.
			if not _drag.is_empty() and bool(_drag.get("bank", false)):
				_rebuild_timer = -1.0
				_rebuild_bank()
			else:
				_rebuild_now()
	if _learn and _overlay != null:
		_overlay.queue_redraw()


func _input(e: InputEvent) -> void:
	if not _active or not (e is InputEventKey):
		return
	var ke := e as InputEventKey
	if not ke.pressed or ke.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		return
	if ke.keycode == KEY_Z and ke.ctrl_pressed and not ke.shift_pressed:
		_undo_step()
		get_viewport().set_input_as_handled()
	elif (ke.keycode == KEY_Y and ke.ctrl_pressed) or (ke.keycode == KEY_Z and ke.ctrl_pressed and ke.shift_pressed):
		_redo_step()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_F:
		_frame(true)
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_SPACE and _mode == "test":
		_test.call("toggle_play")
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_shell = DesignerShell.create("Battery Lab", "battery", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true, "undo": true,
		"left_label": "Designs", "left_w": 250.0, "right_w": 430.0})
	add_child(_shell)
	_shell.undo_requested.connect(_undo_step)
	_shell.redo_requested.connect(_redo_step)
	_shell.name_submitted.connect(_on_name_changed)
	_shell.closed.connect(close)
	_build_left()
	_build_centre()
	_build_right()
	_shell.set_hint("Drag empty space to orbit · wheel to zoom · Shift-drag empty space pans · drag a cell, the BMS, a fitting or a pack to move it (Shift 1 mm · Alt free) · F frames · Ctrl+Z undoes")
	_shell.add_button("Save design", DesignerShell.SECONDARY, _on_save_design,
		"Keep this design in your library (every world)")
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_chain = PowerChainBar.create("battery")
	_chain.follow(_shell)
	_shell.add_header_widget(_chain)
	_chain.hop_requested.connect(_on_chain_hop)
	_chain.add_requested.connect(_on_chain_add)


func _build_left() -> void:
	var box := _shell.left
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_sort = OptionButton.new()
	_sort.add_item("As listed")
	_sort.add_item("$/kWh, cheapest")
	_sort.add_item("$/kWh, dearest")
	_sort.add_item("Price, cheapest")
	_sort.add_item("Price, dearest")
	_sort.fit_to_longest_item = false
	_sort.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sort.tooltip_text = "Order the list by street price, or by dollars per kilowatt-hour"
	_sort.item_selected.connect(_on_sort_picked)
	box.add_child(_sort)
	_gallery = DesignGallery.make("batterylab")
	_gallery.set_thumbnailer(_thumb_for)
	_gallery.item_selected.connect(_on_design_activated)
	box.add_child(_gallery)
	var forget := Button.new()
	forget.text = "Forget"
	forget.tooltip_text = "Remove the selected saved design (★)"
	UITheme.style_button(forget)
	forget.pressed.connect(_on_forget_design)
	box.add_child(forget)
	var about := Label.new()
	about.text = "Every design is built from real cells: its voltage, capacity, current, weight and size are worked out from them. Start from one that looks like yours and change it."
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.custom_minimum_size = Vector2(120, 0)
	about.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	about.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(about)


func _build_centre() -> void:
	var col := _shell.centre
	_tabs = TabBar.new()
	_tabs.name = "lab_tabs"
	_tabs.add_tab("Pack")
	_tabs.add_tab("BMS & test")
	_tabs.add_tab("Bank")
	_tabs.set_tab_tooltip(2, "Many packs as one bank: in a cabinet, on a wall, on the floor; every cable measured, the fuses, the bill of materials")
	_tabs.set_tab_tooltip(0, "Build the pack: cells, links, BMS, case")
	_tabs.set_tab_tooltip(1, "Run the pack through a charge, a load, a frozen morning, a short: watch every cell and what the BMS does")
	_tabs.tab_changed.connect(func(i: int) -> void: set_mode(["pack", "test", "bank"][i]))
	col.add_child(_tabs)
	_view_stack = Control.new()
	_view_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_stack.clip_contents = true
	col.add_child(_view_stack)
	_studio = StudioViewport.create({"ground": true, "person": false, "far": 60.0})
	_studio.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_studio.set_home(0.75, 0.45)
	_studio.dist_max = 20.0
	_studio.clicked.connect(_on_click)
	_studio.hovered.connect(_on_hover)
	_studio.input_hook = _studio_input
	_view_stack.add_child(_studio)
	_overlay = Callouts.new()
	_overlay.modal = self
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	_view_stack.add_child(_overlay)
	# The view strip: explode, cutaway, colour by, show me, tour.
	var st := _studio.strip
	var el := Label.new()
	el.text = "Exploded"
	el.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	el.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	st.add_child(el)
	_explode_sl = HSlider.new()
	_explode_sl.name = "explode"
	_explode_sl.min_value = 0.0
	_explode_sl.max_value = 1.0
	_explode_sl.step = 0.01
	_explode_sl.custom_minimum_size = Vector2(120, 0)
	_explode_sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_explode_sl.tooltip_text = "Pull the pack apart to see every part"
	_explode_sl.value_changed.connect(set_explode)
	st.add_child(_explode_sl)
	_cut_btn = Button.new()
	_cut_btn.name = "cutaway"
	_cut_btn.toggle_mode = true
	_cut_btn.text = "Cutaway"
	UiIcons.apply(_cut_btn, "square-dashed", "Take the lid, the front and a side off (lead-acid: see the cells inside the block)")
	UITheme.style_button(_cut_btn)
	_cut_btn.toggled.connect(set_cutaway)
	st.add_child(_cut_btn)
	_colour_opt = OptionButton.new()
	_colour_opt.name = "colour_by"
	for m in BattBuilder.COLOUR_MODES:
		_colour_opt.add_item("Colour: " + str(COLOUR_WORDS[m]))
		_colour_opt.set_item_metadata(_colour_opt.item_count - 1, m)
		_colour_opt.set_item_tooltip(_colour_opt.item_count - 1, str(COLOUR_TIPS[m]))
	_colour_opt.fit_to_longest_item = false
	_colour_opt.custom_minimum_size = Vector2(200, 0)
	_colour_opt.item_selected.connect(func(i: int) -> void: set_colour(str(_colour_opt.get_item_metadata(i))))
	st.add_child(_colour_opt)
	_learn_btn = Button.new()
	_learn_btn.name = "show_me"
	_learn_btn.toggle_mode = true
	_learn_btn.text = "Show me"
	UiIcons.apply(_learn_btn, "lightbulb", "Number the parts on the picture and say what each one does")
	UITheme.style_button(_learn_btn)
	_learn_btn.toggled.connect(set_learn)
	st.add_child(_learn_btn)
	_tour_btn = Button.new()
	_tour_btn.name = "tour"
	_tour_btn.text = "Tour"
	UiIcons.apply(_tour_btn, "graduation-cap", "Walk through a battery in five steps: cell, parallel, series, BMS, case")
	UITheme.style_button(_tour_btn)
	_tour_btn.pressed.connect(next_tour_step)
	st.add_child(_tour_btn)
	_tour_lbl = Label.new()
	_tour_lbl.name = "tour_text"
	_tour_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tour_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_tour_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	_tour_lbl.visible = false
	col.add_child(_tour_lbl)
	_info_lbl = Label.new()
	_info_lbl.name = "part_info"
	_info_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_info_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_info_lbl.clip_text = true
	_info_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_info_lbl.text = "Click a part to see what it is."
	col.add_child(_info_lbl)
	_test = TEST_PANEL.new()
	_test.name = "test_panel"
	_test.modal = self
	_test.visible = false
	_test.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_test.size_flags_stretch_ratio = 1.15
	col.add_child(_test)
	_test.frame_changed.connect(_on_test_frame)
	_bank_panel = BANK_PANEL.new()
	_bank_panel.name = "bank_panel"
	_bank_panel.modal = self
	_bank_panel.visible = false
	_bank_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bank_panel.size_flags_stretch_ratio = 1.0
	col.add_child(_bank_panel)
	_bank_panel.bank_changed.connect(_on_bank_field)
	_bank_panel.view_changed.connect(func(_v: String) -> void: _paint_bench())
	(_bank_panel.call("bench") as Control).connect("frame_changed", func(_f: Dictionary) -> void: _paint_bench())
	_bank_panel.row_selected.connect(func(id: String) -> void: select_bank_part(id))


## Settings rows: [section, path, label, kind, a, b, step, unit, tip].
## Paths are "key" or "group.key" into the spec; kind spin | option | check.
const FIELDS := [
	["Form factor", "form", "Form", "option", "forms", "", 0.0, "", "Automotive: a battery case (BCI group sizes). Rack: a 19\" server-rack pack. Wall: an upright cabinet on the wall. Rolling: a floor unit on casters. DIY: a box or frame you build."],
	["Form factor", "enclosure.group", "Case size", "option", "groups", "", 0.0, "", "BCI battery group: the standard outside size of a battery case"],
	["Form factor", "enclosure.u", "Rack height", "spin", 0.0, 12.0, 1.0, "U", "Rack units (1U = 44.45 mm); 0 = as tall as the cells need"],
	["Series × parallel", "series", "In series (S)", "spin", 1.0, 64.0, 1.0, "", "Groups joined end to end: their voltages add"],
	["Series × parallel", "parallel", "In parallel (P)", "spin", 1.0, 200.0, 1.0, "", "Cells side by side in each group: their amp-hours add"],
	["Arrangement", "arrange.orient", "Cells stand", "option", "orients", "", 0.0, "", "Upright with the terminals on top, or laid on their side with the terminals facing each other across an aisle (how 19\" packs fit 4U)"],
	["Arrangement", "arrange.cols", "Groups along a row", "spin", 0.0, 64.0, 1.0, "", "0 = chosen for the form factor"],
	["Arrangement", "arrange.rows", "Rows", "spin", 0.0, 24.0, 1.0, "", "0 = chosen for the form factor"],
	["Arrangement", "arrange.layers", "Layers", "spin", 0.0, 4.0, 1.0, "", "Layers stacked on trays; 0 = chosen"],
	["Arrangement", "arrange.group_rows", "Rows in a group", "spin", 0.0, 20.0, 1.0, "", "Cylinders: how a parallel group is laid out (0 = chosen)"],
	["Arrangement", "arrange.staggered", "Honeycomb", "check", "", "", 0.0, "", "Cylinders: every other row offset half a cell, packing tighter"],
	["Arrangement", "interconnect", "Joined with", "option", "interconnects", "", 0.0, "", "Busbars (prismatic), nickel strip (cylinders) or cables (lead-acid blocks)"],
	["Arrangement", "busbar.material", "Busbar metal", "option", "metals", "", 0.0, "", "Copper carries more current than aluminium of the same size"],
	["Arrangement", "busbar.w_mm", "Busbar width", "spin", 0.0, 80.0, 1.0, "mm", "0 = sized for the current"],
	["Arrangement", "busbar.t_mm", "Busbar thickness", "spin", 0.0, 12.0, 0.5, "mm", "0 = sized for the current"],
	["Arrangement", "compression.on", "Compression", "check", "", "", 0.0, "", "Prismatic LFP cells swell as they charge; end plates and rods hold them at the force their maker rates their life at"],
	["Arrangement", "holders", "Cell holders", "check", "", "", 0.0, "", "Plastic holders that space cylindrical cells"],
	["Enclosure", "enclosure.material", "Material", "option", "materials", "", 0.0, "", "What the case is made of (auto: ABS for automotive and DIY, steel otherwise)"],
	["Enclosure", "enclosure.w_mm", "Width", "spin", 0.0, 2000.0, 5.0, "mm", "0 = as wide as the cells need"],
	["Enclosure", "enclosure.h_mm", "Height", "spin", 0.0, 2000.0, 5.0, "mm", "0 = as tall as the cells need"],
	["Enclosure", "enclosure.d_mm", "Depth", "spin", 0.0, 2000.0, 5.0, "mm", "0 = as deep as the cells need"],
	["Enclosure", "enclosure.breaker_a", "Breaker", "spin", 0.0, 400.0, 5.0, "A", "0 = the frame size at or above the pack's current"],
	["Enclosure", "enclosure.display", "Display", "check", "", "", 0.0, "", "A charge display on the front"],
	["Enclosure", "enclosure.handles", "Handles", "check", "", "", 0.0, "", ""],
	["Enclosure", "enclosure.ears", "Rack ears", "check", "", "", 0.0, "", "Rack: the front flanges that bolt to the rails"],
]

## Rows shown for one form only.
const FORM_ONLY := {"enclosure.group": ["automotive"], "enclosure.u": ["rack"], "enclosure.ears": ["rack"]}


func _build_right() -> void:
	var box := _shell.right
	var how := Collapsible.make("How the numbers come", true, "Each headline number, worked out from the cells")
	box.add_child(how)
	_explain_box = VBoxContainer.new()
	_explain_box.add_theme_constant_override("separation", 2)
	how.body.add_child(_explain_box)
	box.add_child(SectionHeader.make("Checks", "circle-check"))
	_checks_box = VBoxContainer.new()
	_checks_box.add_theme_constant_override("separation", 4)
	box.add_child(_checks_box)
	var secs := {}
	for t in ["Form factor", "Chemistry & cell", "Series × parallel", "Arrangement", "BMS", "Enclosure",
			"Electrical detail", "Mass & cost", "Colours"]:
		var sec := Collapsible.make(t, true)
		box.add_child(sec)
		secs[t] = sec.body
	# Chemistry & cell: a filter and the cell, then the cell's sheet.
	var cbody: VBoxContainer = secs["Chemistry & cell"]
	var chem_items: Array = [["", "Any chemistry"]]
	for id in BattChem.IDS:
		chem_items.append([str(id), BattChem.long_name(str(id))])
	var cr := FormRow.option("Chemistry", chem_items, func(v: Variant) -> void:
		_chem_filter = str(v)
		_fill_cells(), "Show only cells of one chemistry", "chem")
	_chem_opt = cr.control as OptionButton
	cbody.add_child(cr)
	var cellr := FormRow.option("Cell", [], func(v: Variant) -> void: _on_field(str(v), "cell_id"),
		"The cell the pack is built from (data-sheet figures, transcribed)", "cell_id")
	_cell_opt = cellr.control as OptionButton
	_cell_opt.fit_to_longest_item = false
	cbody.add_child(cellr)
	for r in [["cell_v", "Voltage", "Nominal voltage of one cell (a lead block: of the block)"],
			["cell_ah", "Capacity", "Amp-hours, at the rated hours"], ["cell_size", "Size", "Outside size"],
			["cell_mass", "Weight", ""], ["cell_c", "Current", "Continuous charge / discharge, as multiples of its capacity (C)"],
			["cell_ir", "Resistance", "Internal resistance (AC, 1 kHz)"], ["cell_life", "Cycle life", "At the chemistry's recommended depth of discharge"],
			["cell_src", "Source", "Where the figures come from"]]:
		var row := FormRow.value(str(r[1]), "—", str(r[2]), str(r[0]))
		cbody.add_child(row)
		_vals[str(r[0])] = row
	# BMS.
	var bbody: VBoxContainer = secs["BMS"]
	var br := FormRow.option("BMS", [], func(v: Variant) -> void: _on_field(str(v), "bms.id"),
		"The battery management system (auto: the smallest that fits)", "bms_id")
	_bms_opt = br.control as OptionButton
	_bms_opt.fit_to_longest_item = false
	bbody.add_child(br)
	for r in [["bms_rating", "Rating", "Continuous / peak current"], ["bms_cells", "Cells", "Series cells it can read"],
			["bms_balance", "Balancing", "How it evens out the cells near full charge"],
			["bms_ov", "Cell too high", "Stops charging above this cell voltage; lets go below the second"],
			["bms_uv", "Cell too low", "Stops discharging below this; lets go above the second"],
			["bms_temp", "Charge between", "It will not charge outside these temperatures"],
			["bms_comms", "Talks over", "How it reports to an inverter or a phone"]]:
		var row2 := FormRow.value(str(r[1]), "—", str(r[2]), str(r[0]))
		bbody.add_child(row2)
		_vals[str(r[0])] = row2
	_prot_box = VBoxContainer.new()
	_prot_box.name = "protections"
	_prot_box.add_theme_constant_override("separation", 2)
	bbody.add_child(_prot_box)
	# Settings.
	for fv in FIELDS:
		var f: Array = fv
		var path := str(f[1])
		var body: VBoxContainer = secs[str(f[0])]
		var row3: FormRow = null
		var rid := path.replace(".", "_")
		match str(f[3]):
			"spin":
				row3 = FormRow.spin(str(f[2]), float(f[4]), float(f[5]), float(f[6]), str(f[7]), _on_field.bind(path), str(f[8]), rid)
			"option":
				row3 = FormRow.option(str(f[2]), _items(str(f[4])), _on_field.bind(path), str(f[8]), rid)
				(row3.control as OptionButton).fit_to_longest_item = false
			"check":
				row3 = FormRow.check(str(f[2]), "On", _on_field.bind(path), str(f[8]), rid)
		if row3 != null:
			body.add_child(row3)
			_rows[path] = row3
	# Read-only results.
	for r in [["Electrical detail", "e_range", "Voltage range", "Empty to full"],
			["Electrical detail", "e_charge", "Charge at", "Absorb / float voltage for the charger"],
			["Electrical detail", "e_current", "Current", "Continuous discharge / charge, and peak"],
			["Electrical detail", "e_limit", "Set by", "The part that limits the current"],
			["Electrical detail", "e_r", "Resistance", "Cells + links + cables + contacts"],
			["Electrical detail", "e_sag", "At full current", "How far the voltage drops, and the heat in the pack"],
			["Electrical detail", "e_crate", "C-rate", "Full current ÷ capacity"],
			["Electrical detail", "e_life", "Life", "Cycles at the recommended depth, and the energy over its life"],
			["Electrical detail", "e_links", "Links", "Busbar / nickel / cable joining the groups"],
			["Electrical detail", "e_leads", "Main cables", "Gauge and total length"],
			["Electrical detail", "e_harness", "Balance leads", "How many, and their total length"],
			["Electrical detail", "e_peukert", "At a 5-hour rate", "Lead-acid gives less at higher current (Peukert)"],
			["Mass & cost", "m_total", "Weight", "Cells, links, cables, frame, BMS, case"],
			["Mass & cost", "m_split", "  of which", "Cells · everything else"],
			["Mass & cost", "m_size", "Size", "Outside, width × height × depth"],
			["Mass & cost", "c_total", "Cost (estimate)", "Cells by $/Wh of their kind, plus BMS, copper, cables, case"],
			["Mass & cost", "c_kwh", "Per kWh", ""],
			["Mass & cost", "m_density", "Energy density", "Pack-level Wh/kg and Wh/L"]]:
		var row4 := FormRow.value(str(r[2]), "—", str(r[3]), str(r[1]))
		(secs[str(r[0])] as VBoxContainer).add_child(row4)
		_vals[str(r[1])] = row4
	# Colours.
	var colb: VBoxContainer = secs["Colours"]
	_wrap_pick = ColorPickerButton.new()
	_wrap_pick.edit_alpha = false
	_wrap_pick.custom_minimum_size = Vector2(80, 24)
	_wrap_pick.color_changed.connect(func(c: Color) -> void: _set_colour_field("wrap", c))
	colb.add_child(FormRow.make("Cell wrap", _wrap_pick, "The colour of the cells' sleeve", "", "wrap_colour"))
	_case_pick = ColorPickerButton.new()
	_case_pick.edit_alpha = false
	_case_pick.custom_minimum_size = Vector2(80, 24)
	_case_pick.color_changed.connect(func(c: Color) -> void: _set_colour_field("case", c))
	colb.add_child(FormRow.make("Case", _case_pick, "", "", "case_colour"))
	var copy := Button.new()
	copy.text = "Copy summary"
	copy.tooltip_text = "Every number and check, as text"
	UITheme.style_button(copy)
	copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(summary()); _status("Summary copied."))
	box.add_child(copy)
	_status_lbl = Label.new()
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_status_lbl)
	_col = DesignerColumn.setup(box, "batterylab", {
		"open": ["How the numbers come", "Form factor", "Chemistry & cell", "Series × parallel"],
		"tile_cols": 3})


static func _items(table: String) -> Array:
	match table:
		"forms":
			var out: Array = []
			for f in BattSpec.FORMS:
				out.append([str(f), str(BattSpec.FORM_WORDS[f])])
			return out
		"groups":
			var g: Array = []
			for k in BattSpec.BCI_GROUPS.keys():
				var s: Array = BattSpec.BCI_GROUPS[k]
				g.append([str(k), "Group %s (%d × %d × %d mm)" % [k, int(s[0]), int(s[2]), int(s[1])]])
			return g
		"orients":
			return [["auto", "Chosen for the form"], ["up", "Upright, terminals up"], ["side", "On their side"]]
		"interconnects":
			return [["auto", "Chosen for the cells"], ["busbar", "Busbars"], ["nickel", "Nickel strip"], ["link", "Cables"]]
		"metals":
			return [["copper", "Copper"], ["aluminium", "Aluminium"]]
		"materials":
			return [["", "Chosen for the form"], ["steel", "Steel"], ["aluminium", "Aluminium"], ["abs", "ABS plastic"]]
	return []


func _fill_cells() -> void:
	_cell_opt.clear()
	var cur := str(_spec.get("cell_id", ""))
	for c in BattCells.CELLS:
		var d: Dictionary = c
		if not _chem_filter.is_empty() and str(d["chem"]) != _chem_filter and str(d["id"]) != cur:
			continue
		_cell_opt.add_item("%s · %s" % [d["label"], BattChem.label(str(d["chem"]))])
		_cell_opt.set_item_metadata(_cell_opt.item_count - 1, str(d["id"]))
	FormRow.select_meta(_cell_opt, cur)


func _fill_bms() -> void:
	_bms_opt.clear()
	_bms_opt.add_item("Auto (smallest that fits)")
	_bms_opt.set_item_metadata(0, "")
	var chem := str(BattCells.get_cell(str(_spec["cell_id"])).get("chem", ""))
	for b in BattBms.BMS:
		var d: Dictionary = b
		if not (d["chems"] as Array).has(chem):
			continue
		_bms_opt.add_item(str(d["label"]))
		_bms_opt.set_item_metadata(_bms_opt.item_count - 1, str(d["id"]))
	FormRow.select_meta(_bms_opt, str((_spec["bms"] as Dictionary).get("id", "")))


# ---------------------------------------------------------------------------
# Edits, undo
# ---------------------------------------------------------------------------

func _push_undo(key: String = "") -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not key.is_empty() and key == _coalesce_key and now < _coalesce_until:
		_coalesce_until = now + 0.8
		return
	_coalesce_key = key
	_coalesce_until = now + 0.8
	_undo.append(_snap())
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()
	_shell.set_undo_state(true, false)


func _snap() -> Dictionary:
	return {"s": _spec.duplicate(true), "b": _bank.duplicate(true)}


func _unsnap(v: Dictionary) -> void:
	_spec = v["s"]
	_bank = v["b"]


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_drag = {}
	_redo.append(_snap())
	_unsnap(_undo.pop_back())
	_shell.set_undo_state(not _undo.is_empty(), not _redo.is_empty())
	_rebuild_now()


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_drag = {}
	_undo.append(_snap())
	_unsnap(_redo.pop_back())
	_shell.set_undo_state(not _undo.is_empty(), not _redo.is_empty())
	_rebuild_now()


func _on_field(value: Variant, path: String) -> void:
	_push_undo(path)
	var parts := path.split(".")
	if parts.size() == 1:
		var cur: Variant = _spec.get(path)
		_spec[path] = int(value) if cur is int and (value is float or value is int) else value
	else:
		var g: Dictionary = _spec[parts[0]]
		var cur2: Variant = g.get(parts[1])
		g[parts[1]] = int(value) if cur2 is int and (value is float or value is int) else value
	# A new cell, form or chemistry changes the shape: rebuild now and frame.
	if path in ["cell_id", "form", "series", "parallel", "arrange.orient"]:
		if path == "cell_id":
			# A BMS for another chemistry no longer fits: back to auto.
			(_spec["bms"] as Dictionary)["id"] = ""
		_rebuild_now()
		return
	_rebuild_timer = REBUILD_DELAY


## One field by path (the harness and the summary use it).
func edit(path: String, value: Variant) -> void:
	_on_field(value, path)
	_rebuild_now()


func _set_colour_field(which: String, c: Color) -> void:
	_push_undo("colours." + which)
	(_spec["colors"] as Dictionary)[which] = [c.r, c.g, c.b]
	_rebuild_timer = REBUILD_DELAY


## Replace the whole spec (a preset or a library design).
func set_spec(s: Dictionary) -> void:
	_push_undo()
	_spec = BattSpec.resolve(s)
	_selected = ""
	_rebuild_now()


func load_builtin(id: String) -> void:
	set_spec(BattPresets.builtin(id))


func _on_name_changed(text: String) -> void:
	if text.strip_edges().is_empty() or text == str(_spec["name"]):
		return
	_push_undo("name")
	_spec["name"] = text.strip_edges()


# ---------------------------------------------------------------------------
# Solve and refresh
# ---------------------------------------------------------------------------

func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = BattSpec.resolve(_spec)
	_design = BattDesign.solve(_spec)
	if _builder != null:
		# Hidden now: queue_free waits until the frame ends, and a drag
		# rebuilds often enough that the old pack would still be on screen.
		_builder.visible = false
		_builder.queue_free()
	_builder = BattBuilder.build_from_design(_design)
	_builder.name = "Pack"
	_studio.holder.add_child(_builder)
	_builder.set_explode(_explode)
	_builder.set_cutaway(_cutaway)
	_builder.colour_by(_colour)
	if not _selected.is_empty() and not _builder.part(_selected).is_empty():
		_builder.highlight([_selected])
	else:
		_selected = ""
	_sync_rows()
	_refresh_results()
	_refresh_checks()
	_refresh_explain()
	var shape := "%s|%s|%d|%d|%s" % [_spec["form"], _spec["cell_id"], int(_spec["series"]), int(_spec["parallel"]),
		str(_design["arrange"])]
	if shape != _framed_key:
		_framed_key = shape
		_frame(false)
	_refresh_protections()
	if _mode == "test":
		_test.call("set_design", _design)
	elif _mode == "bank":
		_builder.visible = false
		_rebuild_bank()


func _sync_rows() -> void:
	var form := str(_spec["form"])
	var cell := BattCells.get_cell(str(_spec["cell_id"]))
	var cyl := str(cell["format"]) == "cylindrical"
	for path in _rows:
		var row: FormRow = _rows[path]
		var parts := str(path).split(".")
		var v: Variant = _spec.get(path) if parts.size() == 1 else (_spec[parts[0]] as Dictionary).get(parts[1])
		row.set_value(v)
		var show := true
		if FORM_ONLY.has(path):
			show = (FORM_ONLY[path] as Array).has(form)
		if path in ["arrange.group_rows", "arrange.staggered", "holders"]:
			show = cyl
		if path == "compression.on":
			show = str(cell["format"]) == "prismatic"
		if path.begins_with("busbar."):
			show = str(_design["interconnect"]) == "busbar"
		row.visible = show
	_shell.name_edit.text = str(_spec["name"])
	_fill_cells()
	_fill_bms()
	var colors: Dictionary = _spec["colors"]
	_wrap_pick.color = _arr_color(colors.get("wrap", []), BattBuilder.WRAP.get(str(cell["chem"]), Color(0.3, 0.4, 0.8)))
	_case_pick.color = _arr_color(colors.get("case", []), BattBuilder.CASE.get(form, Color(0.2, 0.2, 0.22)))


static func _arr_color(a: Variant, def: Color) -> Color:
	if a is Array and (a as Array).size() >= 3:
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return def


func _val(key: String, text: String) -> void:
	if _vals.has(key):
		(_vals[key] as FormRow).set_value(text)


func _refresh_results() -> void:
	var d := _design
	var e: Dictionary = d["electrical"]
	var cell: Dictionary = d["cell"]
	var L: Dictionary = d["layout"]
	var sz: Vector3 = (L["bounds"] as AABB).size
	var chem := str(d["chem"])
	_shell.set_subtitle("%s · %s · %dS%dP · %s" % [BattSpec.FORM_WORDS[str(_spec["form"])], cell["label"],
		int(_spec["series"]), int(_spec["parallel"]), BattChem.long_name(chem)])
	_set_tiles()
	# The cell's sheet.
	var b := BattCells.box_mm(cell)
	_val("cell_v", "%.1f V%s" % [float(cell["nominal_v"]), (" (%d × 2 V cells)" % BattCells.cells_inside(cell)) if BattCells.cells_inside(cell) > 1 else ""])
	_val("cell_ah", "%.1f Ah at %.0f h" % [float(cell["ah"]), float(cell["rate_h"])])
	_val("cell_size", ("Ø%.1f × %.1f mm" % [float(cell["d_mm"]), float(cell["h_mm"])]) if str(cell["format"]) == "cylindrical"
		else "%.0f × %.0f × %.0f mm" % [b.x, b.y, b.z])
	_val("cell_mass", "%.2f kg · %.0f Wh/kg" % [float(cell["mass_kg"]), BattCells.wh_per_kg(cell)])
	_val("cell_c", "%sC charge / %sC discharge" % [_c(float(cell["charge_c"])), _c(float(cell["discharge_c"]))])
	_val("cell_ir", "%.2f mΩ" % float(cell["ir_mohm"]))
	_val("cell_life", "%s cycles at %d %%" % [UiText.thousands(int(BattCells.cycles_at_dod(cell, float(e["dod"])))), int(roundf(float(e["dod"]) * 100.0))])
	_val("cell_src", str(cell["source"]))
	# BMS.
	var bms: Dictionary = d["bms"]
	if bool(d["protected"]):
		var p: Dictionary = d["bms_params"]
		var bal := BattBms.balance_for(str(d["bms_id"]), chem)
		_val("bms_rating", "%.0f A / %.0f A peak" % [float(bms["cont_a"]), float(bms["peak_a"])])
		_val("bms_cells", "%d–%d in series" % [int(bms["s_min"]), int(bms["s_max"])])
		_val("bms_balance", "%s %s from %.2f V" % [str(bal["kind"]).capitalize(),
			("%.1f A" % float(bal["a"])) if float(bal["a"]) >= 1.0 else ("%.0f mA" % (float(bal["a"]) * 1000.0)), float(bal["start_v"])])
		_val("bms_ov", "%.2f V → %.2f V" % [float(p["cell_ov"]["trip"]), float(p["cell_ov"]["release"])])
		_val("bms_uv", "%.2f V → %.2f V" % [float(p["cell_uv"]["trip"]), float(p["cell_uv"]["release"])])
		_val("bms_temp", "%.0f to %.0f °C" % [float(p["charge_ut"]["trip"]), float(p["charge_ot"]["trip"])])
		_val("bms_comms", ", ".join(PackedStringArray(bms.get("comms", []))) if not (bms.get("comms", []) as Array).is_empty() else "none")
	else:
		var none := "a monitor only" if not bms.is_empty() else "none (lead-acid)"
		for k in ["bms_rating", "bms_cells", "bms_balance", "bms_ov", "bms_uv", "bms_temp", "bms_comms"]:
			_val(k, none if k == "bms_rating" else "—")
	# Electrical detail.
	_val("e_range", "%.1f – %.1f V" % [float(e["v_min"]), float(e["v_max"])])
	_val("e_charge", ("%.1f V absorb / %.1f V float" % [float(e["v_absorb"]), float(e["v_float"])]) if float(e["v_float"]) > 0.0
		else "%.1f V (CC-CV, no float)" % float(e["v_absorb"]))
	_val("e_current", "%.0f A out / %.0f A in · %.0f A peak" % [float(e["cont_discharge_a"]), float(e["cont_charge_a"]), float(e["peak_a"])])
	_val("e_limit", _limit_word(str(e["limit_by"])))
	_val("e_r", "%.2f mΩ (cells %.2f)" % [float(e["r_ohm"]) * 1000.0, float(e["r_cells"]) * 1000.0])
	_val("e_sag", "%.2f V lower · %.0f W of heat" % [float(e["sag_v"]), float(e["heat_w"])])
	_val("e_crate", "%sC" % _c(float(e["c_rate"])))
	_val("e_life", "%s cycles · %s kWh" % [UiText.thousands(int(e["cycles"])), UiText.thousands(int(e["lifetime_kwh"]))])
	var bus: Dictionary = d["bus"]
	var ic := str(d["interconnect"])
	var lk := ""
	match ic:
		"busbar":
			lk = "%s busbar %.0f × %.1f mm" % [str(bus["material"]).capitalize(), float(bus["w"]), float(bus["t"])]
		"nickel":
			lk = "Nickel strip %.0f × %.2f mm, %d per joint" % [float(BattElectrical.STRIP[0]), float(BattElectrical.STRIP[1]), int(bus["strips"])]
		_:
			lk = "Cables"
	_val("e_links", "%s · %d joints" % [lk, (L["links"] as Array).size()])
	var lead_len := 0.0
	for ld in (L["leads"] as Array):
		lead_len += float(ld["len_mm"])
	var lw: Dictionary = L.get("lead_wire", {})
	_val("e_leads", ("%s · %.2f m" % [lw.get("name", "—"), lead_len * 0.001]) if lead_len > 0.0 else "the block's own posts")
	var h_len := 0.0
	for h in (L["harness"] as Array):
		h_len += float(h["len_mm"])
	_val("e_harness", ("%d × 22 AWG · %.2f m" % [(L["harness"] as Array).size(), h_len * 0.001]) if h_len > 0.0 else "none")
	_val("e_peukert", ("%.0f Ah" % float(e["peukert_c5_ah"])) if e.has("peukert_c5_ah") else "—")
	var m: Dictionary = d["mass"]
	_val("m_total", "%.1f kg" % float(d["mass_kg"]))
	_val("m_split", "%.1f kg cells · %.1f kg the rest" % [float(m["cells"]), float(d["mass_kg"]) - float(m["cells"])])
	_val("m_size", "%.0f × %.0f × %.0f mm" % [sz.x, sz.y, sz.z])
	_val("c_total", "$%s" % UiText.thousands(int(d["cost_usd"])))
	_val("c_kwh", "$%.0f per kWh" % float(d["usd_per_kwh"]))
	var vol_l := sz.x * sz.y * sz.z * 1e-6
	_val("m_density", "%.0f Wh/kg · %.0f Wh/L" % [float(e["wh"]) / maxf(float(d["mass_kg"]), 0.001), float(e["wh"]) / maxf(vol_l, 0.001)])
	_col.set_summary("Form factor", BattSpec.FORM_WORDS[str(_spec["form"])])
	_col.set_summary("Chemistry & cell", str(cell["label"]))
	_col.set_summary("Series × parallel", "%dS%dP" % [int(_spec["series"]), int(_spec["parallel"])])
	_col.set_summary("BMS", str(bms.get("label", "none")))


## A C-rate in two significant figures ("0.5", "1", "0.25").
static func _c(v: float) -> String:
	return String.num(v, 2 if v < 1.0 else 1).trim_suffix(".0")


static func _limit_word(k: String) -> String:
	return {"cells": "the cells", "bms": "the BMS", "links": "the busbars / links", "leads": "the main cables",
		"breaker": "the breaker"}.get(k, k)


func _refresh_explain() -> void:
	for c in _explain_box.get_children():
		_explain_box.remove_child(c)
		c.queue_free()
	var ex: Dictionary = _design["explain"]
	for k in ["voltage", "capacity", "energy", "usable", "current"]:
		var l := Label.new()
		l.name = "explain_" + k
		l.text = str(ex[k])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(120, 0)
		l.add_theme_font_override("font", UITheme.font("regular", true))
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.add_theme_color_override("font_color", UITheme.C_TEXT)
		_explain_box.add_child(l)


func _refresh_checks() -> void:
	for c in _checks_box.get_children():
		_checks_box.remove_child(c)
		c.queue_free()
	var errs := 0
	var warns := 0
	for cv in (_design["checks"] as Array):
		var c: Dictionary = cv
		var lvl := str(c["level"])
		if lvl == "error":
			errs += 1
		elif lvl == "warn":
			warns += 1
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		var ico := TextureRect.new()
		ico.texture = UiIcons.icon({"error": "circle-alert", "warn": "triangle-alert"}.get(lvl, "info"), 16)
		ico.modulate = {"error": UITheme.C_ERROR, "warn": UITheme.C_AMBER}.get(lvl, UITheme.C_INFO)
		ico.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		ico.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		h.add_child(ico)
		var l := Label.new()
		l.text = str(c["text"])
		l.tooltip_text = str(c["why"])
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.custom_minimum_size = Vector2(100, 0)
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		h.add_child(l)
		var ids: Array = c.get("ids", [])
		var shown: Array = ids.filter(func(i): return _builder != null and not _builder.part(str(i)).is_empty())
		if not shown.is_empty():
			var b := Button.new()
			b.text = "Show it"
			b.tooltip_text = "Highlight the part this is about"
			UITheme.style_button(b)
			b.pressed.connect(func() -> void: select_part(str(shown[0])))
			h.add_child(b)
		_checks_box.add_child(h)
	if (_design["checks"] as Array).is_empty():
		_checks_box.add_child(EmptyState.row("circle-check", "No problems found."))
	if errs > 0:
		_shell.set_badge(UiText.count(errs, "problem") + " to fix", "error")
	elif warns > 0:
		_shell.set_badge(UiText.count(warns, "warning"), "warn")
	else:
		_shell.set_badge("Checks pass", "ok")


func _status(t: String) -> void:
	if _status_lbl != null:
		_status_lbl.text = t


## Every number and check as text.
func summary() -> String:
	var d := _design
	var e: Dictionary = d["electrical"]
	var lines := PackedStringArray()
	lines.append("%s — %s, %dS%dP of %s" % [_spec["name"], BattSpec.FORM_WORDS[str(_spec["form"])],
		int(_spec["series"]), int(_spec["parallel"]), (d["cell"] as Dictionary)["label"]])
	for k in ["voltage", "capacity", "energy", "usable", "current"]:
		lines.append("  " + str(d["explain"][k]))
	lines.append("  %.1f–%.1f V · charge %.1f V · %.2f mΩ · %.1f kg · $%.0f ($%.0f/kWh, estimate)" % [
		float(e["v_min"]), float(e["v_max"]), float(e["v_absorb"]), float(e["r_ohm"]) * 1000.0,
		float(d["mass_kg"]), float(d["cost_usd"]), float(d["usd_per_kwh"])])
	lines.append("  BMS: %s" % (d["bms"] as Dictionary).get("label", "none"))
	for c in (d["checks"] as Array):
		lines.append("  [%s] %s" % [c["level"], c["text"]])
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# Views, picking, learning
# ---------------------------------------------------------------------------

func set_explode(f: float) -> void:
	_explode = clampf(f, 0.0, 1.0)
	_explode_sl.set_value_no_signal(_explode)
	if _builder != null:
		_builder.set_explode(_explode)


func set_cutaway(on: bool) -> void:
	_cutaway = on
	_cut_btn.set_pressed_no_signal(on)
	if _builder != null:
		_builder.set_cutaway(on)


func set_colour(mode: String) -> void:
	_colour = mode if BattBuilder.COLOUR_MODES.has(mode) else "part"
	FormRow.select_meta(_colour_opt, _colour)
	if _builder != null:
		_builder.colour_by(_colour)


func colour_mode() -> String:
	return _colour


func set_learn(on: bool) -> void:
	_learn = on
	_learn_btn.set_pressed_no_signal(on)
	_overlay.visible = on
	_overlay.queue_redraw()


func learn_on() -> bool:
	return _learn


## Step the tour on (and off after the last step).
func next_tour_step() -> void:
	set_tour_step(_tour + 1 if _tour + 1 < TOUR.size() else -1)


func set_tour_step(i: int) -> void:
	_tour = i
	if i < 0:
		_tour_lbl.visible = false
		_tour_btn.text = "Tour"
		set_learn(false)
		return
	var t: Array = TOUR[i]
	_tour_lbl.text = "%s — %s" % [t[0], t[1]]
	_tour_lbl.visible = true
	_tour_btn.text = "Next" if i < TOUR.size() - 1 else "Finish"
	set_explode(float(t[2]))
	set_cutaway(bool(t[3]))
	set_colour(str(t[4]))
	var focus := str(t[5])
	if _builder != null and _builder.part(focus).is_empty() and focus == "term_pos":
		focus = "post_pos"
	select_part(focus)
	set_learn(true)


func tour_step() -> int:
	return _tour


## The callouts the overlay draws ({} parts the pack does not have are left
## out).
func callouts() -> Array:
	return [] if _builder == null else _builder.callouts()


func select_part(id: String) -> void:
	_selected = id
	if _builder == null:
		return
	var p := _builder.part(id)
	if p.is_empty():
		_builder.highlight([])
		_info_lbl.text = "Click a part to see what it is."
		return
	_builder.highlight([id])
	_info_lbl.text = _part_words(p)


func selected_part() -> String:
	return _selected


func _part_words(p: Dictionary) -> String:
	var k := str(p["kind"])
	var e: Dictionary = _design["electrical"]
	var cell: Dictionary = _design["cell"]
	var extra := ""
	match k:
		"cell":
			extra = "%s, %.1f V, %.0f Ah" % [cell["label"], float(cell["nominal_v"]), float(cell["ah"])]
		"busbar", "nickel", "link":
			for lk in (_design["layout"]["links"] as Array) + (_design["layout"]["ends"] as Array):
				if str(lk["id"]) == str(p["id"]):
					extra = "carries up to %.0f A" % float(lk.get("amps", e["cont_discharge_a"]))
		"bms":
			extra = "reads %d cells, %.0f A" % [int(e["cells_series"]), float((_design["bms"] as Dictionary).get("cont_a", 0.0))]
		"tap":
			extra = "22 AWG to the BMS"
	var words := "%s%s" % [str(p["label"]), (" · " + extra) if not extra.is_empty() else ""]
	if BattLayout.can_drag(k):
		words += " · drag to move"
	return words


func _on_click(pos: Vector2, button: int) -> void:
	if button == MOUSE_BUTTON_LEFT and _mode == "bank" and _bank_builder != null:
		var rb := _studio.pick_ray_local(_bank_builder, pos)
		if not rb.is_empty():
			select_bank_part(str(_bank_builder.pick(rb["origin"], rb["dir"]).get("id", "")))
		return
	if button != MOUSE_BUTTON_LEFT or _builder == null:
		return
	var r := _studio.pick_ray_local(_builder, pos)
	if r.is_empty():
		return
	var hit := _builder.pick(r["origin"], r["dir"])
	select_part(str(hit.get("id", "")))


func _on_hover(pos: Vector2) -> void:
	if _mode == "bank":
		if _bank_builder != null and _selected.is_empty():
			var rb := _studio.pick_ray_local(_bank_builder, pos)
			if not rb.is_empty():
				var hb := _bank_builder.pick(rb["origin"], rb["dir"])
				var hover := str(hb.get("label", "Click a pack, a cable or a fuse to see what it is."))
				if str(hb.get("kind", "")) == "pack":
					hover += " · drag to move"
				_info_lbl.text = hover
		return
	if _builder == null or not _selected.is_empty():
		return
	var r := _studio.pick_ray_local(_builder, pos)
	if r.is_empty():
		return
	var hit := _builder.pick(r["origin"], r["dir"])
	_info_lbl.text = _part_words(hit) if not hit.is_empty() else "Click a part to see what it is."


# ---------------------------------------------------------------------------
# Dragging a part (or a bank pack)
# ---------------------------------------------------------------------------

func _drag_node() -> Node3D:
	return _bank_builder if _mode == "bank" else _builder


func _can_move(part: Dictionary) -> bool:
	if part.is_empty() or _mode == "test":
		return false
	if _mode == "bank":
		return str(part.get("kind", "")) == "pack"
	return BattLayout.can_drag(str(part.get("kind", "")))


func _pick_part(pos: Vector2) -> Dictionary:
	var node := _drag_node()
	if node == null:
		return {}
	var r := _studio.pick_ray_local(node, pos)
	if r.is_empty():
		return {}
	if _mode == "bank":
		return _bank_builder.pick(r["origin"], r["dir"])
	return _builder.pick(r["origin"], r["dir"])


## 5 mm, 1 mm with Shift, free with Alt — the same steps as the gantry editor.
func _drag_step(e: InputEvent) -> float:
	if e is InputEventWithModifiers:
		var em := e as InputEventWithModifiers
		if em.alt_pressed:
			return 0.0
		if em.shift_pressed:
			return 1.0
	return 5.0


## The pointer on the camera-facing plane through `origin_m` (builder metres).
func _plane_hit(node: Node3D, pos: Vector2, origin_m: Vector3) -> Vector3:
	if node == null or _studio.camera == null:
		return Vector3.INF
	var r := _studio.pick_ray_local(node, pos)
	if r.is_empty():
		return Vector3.INF
	var cam := node.global_transform.affine_inverse() * _studio.camera.global_transform
	var n := (-cam.basis.z).normalized()
	var dir: Vector3 = r["dir"]
	var den := dir.dot(n)
	if absf(den) < 1e-6:
		return Vector3.INF
	var t := (origin_m - (r["origin"] as Vector3)).dot(n) / den
	if t < 0.0:
		return Vector3.INF
	return (r["origin"] as Vector3) + dir * t


func _moved_words(v: Vector3) -> String:
	if v.length() < 0.5:
		return "back in its place"
	return "moved %.0f mm" % v.length()


## The studio's own input first. True = the orbit does not take it.
func _studio_input(e: InputEvent) -> bool:
	if not _active or _mode == "test":
		return false
	if e is InputEventMouseMotion:
		if _drag.is_empty():
			return false
		var mm := e as InputEventMouseMotion
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_finish_drag()
			return true
		_drag_motion(mm)
		return true
	if not (e is InputEventMouseButton):
		return false
	var mb := e as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return false
	if not mb.pressed:
		if _drag.is_empty():
			return false
		_finish_drag()
		return true
	var part := _pick_part(mb.position)
	if not _can_move(part):
		return false
	var id := str(part["id"])
	if _mode == "bank":
		select_bank_part(id)
	else:
		select_part(id)
	var center: Vector3 = (part["aabb"] as AABB).get_center()
	var hit := _plane_hit(_drag_node(), mb.position, center)
	if hit == Vector3.INF:
		hit = center
	var host: Dictionary = _bank if _mode == "bank" else _spec
	_drag = {
		"id": id, "bank": _mode == "bank", "press": mb.position, "moved": false,
		"n0": BattLayout.nudge_of(host, id), "hit0": hit * 1000.0, "plane": center,
		"label": str(part.get("label", "Part")),
	}
	return true


func _drag_motion(mm: InputEventMouseMotion) -> void:
	if not bool(_drag.get("moved", false)) and mm.position.distance_to(_drag["press"]) <= DRAG_PX:
		return
	var hit := _plane_hit(_drag_node(), mm.position, _drag["plane"])
	if hit == Vector3.INF:
		return
	if not bool(_drag["moved"]):
		_drag["moved"] = true
		_push_undo("")
	var n := BattLayout.drag_nudge(_drag["n0"], _drag["hit0"], hit * 1000.0, _drag_step(mm))
	var host: Dictionary = _bank if bool(_drag["bank"]) else _spec
	BattLayout.write_nudge(host, str(_drag["id"]), n)
	_info_lbl.text = "%s · %s" % [str(_drag["label"]), _moved_words(n)]
	if _rebuild_timer <= 0.0:
		_rebuild_timer = DRAG_REBUILD


func _finish_drag() -> void:
	var moved := not _drag.is_empty() and bool(_drag.get("moved", false))
	var bank := bool(_drag.get("bank", false))
	_drag = {}
	if not moved:
		return
	# The last motion already queued a rebuild; this one is the final pose.
	_rebuild_timer = -1.0
	if bank:
		_rebuild_bank()
	else:
		_rebuild_now()


## Where a local point of the pack is on the overlay (or Vector2.INF).
func project(local: Vector3) -> Vector2:
	if _builder == null or _studio.camera == null:
		return Vector2.INF
	var w := _builder.global_transform * local
	if _studio.camera.is_position_behind(w):
		return Vector2.INF
	var vp := _studio.camera.unproject_position(w)
	var cs := _studio.container.size
	var vs := Vector2(_studio.viewport.size)
	if vs.x <= 0.0 or vs.y <= 0.0:
		return Vector2.INF
	return _studio.position + _studio.container.position + vp * (cs / vs)


func _frame(reset_orbit: bool) -> void:
	if _builder == null:
		return
	if reset_orbit:
		_studio.reset_orbit()
	var bm: AABB = _builder.get_meta("bounds_m")
	if _mode == "bank" and _bank_builder != null:
		bm = _bank_builder.get_meta("bounds_m")
	_studio.frame_sphere(bm.get_center(), bm.size.length() * 0.5, 0.9)


# ---------------------------------------------------------------------------
# Designs
# ---------------------------------------------------------------------------

func _thumb_for(i: int) -> Dictionary:
	if i < 0 or i >= _entries.size():
		return {}
	var s: Dictionary = BattSpec.resolve(((_entries[i] as Dictionary)["spec"] as Dictionary).duplicate(true))
	return {"key": BattSpec.key_of(s), "build": func() -> Node3D:
		return BattBuilder.build_node(s, "Thumb")}


func _on_sort_picked(_idx: int) -> void:
	_refresh_design_list()


func _shop_rows(raw: Array) -> Array:
	var rows: Array = []
	for i in raw.size():
		var src: Dictionary = raw[i]
		var facts := BattPresets.shop_facts(src["spec"], float(src.get("price_usd", 0.0)))
		rows.append({"src": src, "facts": facts, "ord": i})
	var mode := _sort.selected if _sort != null else 0
	if mode == 0:
		return rows
	var by_kwh := mode <= 2
	var cheap_first := mode == 1 or mode == 3
	var key := "per_kwh" if by_kwh else "usd"
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ka := float((a["facts"] as Dictionary)[key])
		var kb := float((b["facts"] as Dictionary)[key])
		if is_equal_approx(ka, kb):
			return int(a["ord"]) < int(b["ord"])
		return ka < kb if cheap_first else ka > kb)
	return rows


func _add_shop_row(label: String, facts: Dictionary, spec: Dictionary, builtin: bool, id: String, tip: String,
		bank: Dictionary = {}) -> void:
	_gallery.add_item(label)
	var i := _gallery.item_count - 1
	_gallery.set_item_shop(i, str(facts["price"]), str(facts["per"]), str(facts["detail"]))
	_gallery.set_item_tooltip(i, tip)
	_entries.append({"spec": spec, "builtin": builtin, "id": id, "bank": bank})


func _refresh_design_list() -> void:
	var keep := ""
	var sel := _gallery.get_selected_items()
	if not sel.is_empty() and int(sel[0]) < _entries.size():
		keep = str((_entries[int(sel[0])] as Dictionary)["id"])
	_gallery.clear()
	_entries.clear()
	for row in _shop_rows(BattPresets.builtins()):
		var bd: Dictionary = row["src"]
		var facts: Dictionary = row["facts"]
		_add_shop_row(str(bd["label"]), facts, bd["spec"], true, str(bd["id"]), str(bd.get("blurb", "")))
	var lib := BattPresets.load_library()
	var banks := BattPresets.load_library_banks()
	var saved: Array = []
	for id2 in lib.keys():
		var s2: Dictionary = lib[id2]
		saved.append({"spec": s2, "id": str(id2), "name": str(s2.get("name", id2)),
			"bank": banks.get(id2, {})})
	for row2 in _shop_rows(saved):
		var mine: Dictionary = row2["src"]
		var facts2: Dictionary = row2["facts"]
		var tip := str(mine["name"])
		if bool(facts2["about"]):
			tip += "\nParts estimate, not a street price"
		var bk: Dictionary = mine.get("bank", {})
		if not bk.is_empty():
			tip += "\nSaved with its bank: %d × %d, %s" % [int(bk.get("series", 1)), int(bk.get("parallel", 1)),
				str(BankSpec.MOUNT_WORDS.get(str(bk.get("mount", "auto")), "")).to_lower()]
		_add_shop_row("★ " + str(mine["name"]), facts2, mine["spec"], false, str(mine["id"]), tip, bk)
	if keep.is_empty():
		return
	for i in _entries.size():
		if str((_entries[i] as Dictionary)["id"]) == keep:
			_gallery.select(i)
			_gallery.ensure_current_is_visible()
			return


func gallery() -> DesignGallery:
	return _gallery


func entry_count() -> int:
	return _entries.size()


func _on_design_activated(idx: int) -> void:
	if idx < 0 or idx >= _entries.size():
		return
	var e: Dictionary = _entries[idx]
	var bk: Dictionary = e.get("bank", {})
	if not bk.is_empty():
		# A saved design brings its bank back with it (set before the
		# rebuild, which lays the bank out in bank mode).
		_push_undo()
		_bank = _bank_fields(BankSpec.resolve(bk))
	set_spec((e["spec"] as Dictionary).duplicate(true))


func _on_save_design() -> void:
	var nm := str(_spec["name"])
	var id := "bl_" + nm.to_lower().replace(" ", "_").left(40)
	if BattPresets.save_to_library(id, _spec, BattPresets.LIBRARY_FILE, _bank):
		_refresh_design_list()
		_status("Saved “%s” and its bank to your library." % nm)
	else:
		_status("Could not write the library file.")


func _on_forget_design() -> void:
	var sel := _gallery.get_selected_items()
	if sel.is_empty():
		_status("Pick a saved design (★) to forget.")
		return
	var e: Dictionary = _entries[sel[0]]
	if bool(e["builtin"]):
		_status("Built-in designs can't be forgotten.")
		return
	BattPresets.forget(str(e["id"]))
	_refresh_design_list()
	_status("Forgotten.")


# ---------------------------------------------------------------------------
# The "Show me" overlay
# ---------------------------------------------------------------------------

class Callouts extends Control:
	var modal: Control = null

	## Labels stand in two columns, either side of the pack, each sorted by
	## the height of the part it points at, so leader lines never cross and
	## labels never stack on each other.
	func _draw() -> void:
		if modal == null:
			return
		var font := UITheme.font("semibold")
		var small := UITheme.font("regular")
		var focus := str(modal.call("selected_part"))
		var pts: Array = []
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for cv in modal.call("callouts"):
			var c: Dictionary = cv
			var at: Vector2 = modal.call("project", c["pos"])
			if at == Vector2.INF or not Rect2(Vector2.ZERO, size).has_point(at):
				continue
			pts.append({"c": c, "at": at})
			lo = lo.min(at)
			hi = hi.max(at)
		if pts.is_empty():
			return
		var mid := (lo.x + hi.x) * 0.5
		var cols := {"l": [], "r": []}
		for p in pts:
			(cols["l"] if (p["at"] as Vector2).x < mid else cols["r"]).append(p)
		# Balance the columns.
		while (cols["l"] as Array).size() > (cols["r"] as Array).size() + 1:
			(cols["l"] as Array).sort_custom(func(a, b): return (a["at"] as Vector2).x < (b["at"] as Vector2).x)
			(cols["r"] as Array).append((cols["l"] as Array).pop_back())
		while (cols["r"] as Array).size() > (cols["l"] as Array).size() + 1:
			(cols["r"] as Array).sort_custom(func(a, b): return (a["at"] as Vector2).x < (b["at"] as Vector2).x)
			(cols["l"] as Array).append((cols["r"] as Array).pop_front())
		const STEP := 44.0
		const LW := 230.0
		for side in ["l", "r"]:
			var list: Array = cols[side]
			list.sort_custom(func(a, b): return (a["at"] as Vector2).y < (b["at"] as Vector2).y)
			var n := list.size()
			if n == 0:
				continue
			var x := (lo.x - 70.0 - LW) if side == "l" else (hi.x + 70.0)
			x = clampf(x, 8.0, size.x - LW - 8.0)
			var y0 := clampf((lo.y + hi.y) * 0.5 - STEP * float(n - 1) * 0.5, 24.0, maxf(24.0, size.y - 40.0 - STEP * float(n - 1)))
			for k in n:
				var c: Dictionary = list[k]["c"]
				var at: Vector2 = list[k]["at"]
				var lab := Vector2(x, y0 + STEP * float(k))
				var hot := str(c["id"]) == focus
				var col := UITheme.C_AMBER if hot else UITheme.C_PRIMARY
				var dot := lab + Vector2(LW + 12.0 if side == "l" else -12.0, 0.0)
				draw_line(at, dot, Color(col, 0.8), 1.5, true)
				draw_circle(at, 4.0, col)
				draw_circle(dot, 11.0, col)
				var nt := str(int(c["n"]))
				var ns := font.get_string_size(nt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
				draw_string(font, dot + Vector2(-ns.x * 0.5, 5.0), nt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.05, 0.06, 0.08))
				var title := str(c["title"])
				var tw := minf(LW, font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 10.0)
				var tx := Vector2(lab.x + (LW - tw if side == "l" else 0.0), lab.y)
				draw_rect(Rect2(tx + Vector2(0, -14), Vector2(tw, 20)), Color(0.04, 0.05, 0.08, 0.8))
				draw_string(font, tx + Vector2(5, 1), title, HORIZONTAL_ALIGNMENT_LEFT, tw - 6.0, 13, UITheme.C_TEXT)
		# The focused part's explanation under the view's top edge.
		for p in pts:
			var c2: Dictionary = p["c"]
			if str(c2["id"]) != focus:
				continue
			var lines := _wrap(small, str(c2["text"]), 420.0, 13)
			var bh := 18.0 * float(lines.size()) + 12.0
			var at2 := Vector2(12.0, 12.0)
			draw_rect(Rect2(at2, Vector2(440.0, bh + 22.0)), Color(0.04, 0.05, 0.08, 0.88))
			draw_string(font, at2 + Vector2(10, 20), str(c2["title"]), HORIZONTAL_ALIGNMENT_LEFT, 420.0, 14, UITheme.C_AMBER)
			for i in lines.size():
				draw_string(small, at2 + Vector2(10, 40.0 + 18.0 * float(i)), str(lines[i]),
					HORIZONTAL_ALIGNMENT_LEFT, 420.0, 13, UITheme.C_TEXT)

	static func _wrap(f: Font, text: String, w: float, sz: int) -> Array:
		var out: Array = []
		var line := ""
		for word in text.split(" "):
			var t := word if line.is_empty() else line + " " + word
			if f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x > w and not line.is_empty():
				out.append(line)
				line = word
			else:
				line = t
		if not line.is_empty():
			out.append(line)
		return out


# ---------------------------------------------------------------------------
# BMS & test
# ---------------------------------------------------------------------------

## "pack" or "test": the test bench under the pack.
func set_mode(m: String) -> void:
	if not _drag.is_empty():
		_finish_drag()
	_mode = m if m in ["pack", "test", "bank"] else "pack"
	_tabs.set_current_tab(["pack", "test", "bank"].find(_mode))
	_test.visible = _mode == "test"
	_bank_panel.visible = _mode == "bank"
	if _builder != null:
		_builder.visible = _mode != "bank"
	if _bank_builder != null:
		_bank_builder.visible = _mode == "bank"
	if _mode == "bank":
		set_learn(false)
		if _tour >= 0:
			set_tour_step(-1)
		_rebuild_bank()
		_frame.call_deferred(false)
		return
	_set_tiles()
	# The view changes size: frame the pack again once the layout settles.
	_frame.call_deferred(false)
	if _mode == "test":
		set_learn(false)
		if _tour >= 0:
			set_tour_step(-1)
		# The lid off, so the cells' colours (voltage, white while balancing) show.
		set_cutaway(true)
		_test.call("set_design", _design)
		_test.call("run_scenario", str(_test.call("scenario_id")))
	elif _builder != null:
		_builder.colour_by(_colour)


func mode() -> String:
	return _mode


func test_panel() -> Control:
	return _test


## Colour the 3D cells from the frame shown: voltage between the BMS's
## under- and over-voltage lines, white while balancing.
func _on_test_frame(f: Dictionary) -> void:
	if _builder == null or _mode != "test":
		return
	var res: Dictionary = _test.get("result")
	var cv: PackedFloat64Array = f["cell_v"]
	var bal: PackedFloat64Array = f["bal"]
	var inside := BattCells.cells_inside(_design["cell"])
	var ov := float(res["v_ov"])
	var uv := float(res["v_uv"])
	var cols := PackedColorArray()
	for ce in (_design["layout"]["cells"] as Array):
		var g := int(ce["group"])
		var v := 0.0
		var bl := 0.0
		for j in inside:
			var k := g * inside + j
			if k < cv.size():
				v += cv[k] / float(inside)
				bl += absf(bal[k]) if k < bal.size() else 0.0
		var c := BattBuilder.voltage_color((v - uv) / maxf(ov - uv, 1e-6))
		if bl > 1e-6:
			c = c.lerp(Color.WHITE, 0.55)
		cols.append(c)
	_builder.set_cell_colors(cols)


func _refresh_protections() -> void:
	var sig := "%s|%s" % [_design.get("bms_id", ""), JSON.stringify((_spec["bms"] as Dictionary).get("overrides", {}))]
	if sig == _prot_sig:
		return
	_prot_sig = sig
	for c in _prot_box.get_children():
		_prot_box.remove_child(c)
		c.queue_free()
	if not bool(_design.get("protected", false)):
		var l := Label.new()
		l.text = "No protection settings: nothing in this pack can disconnect it." if not BattChem.is_lithium(str(_design["chem"])) \
			else "Pick a BMS to set its protections."
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(120, 0)
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_prot_box.add_child(l)
		return
	_prot_box.add_child(SectionHeader.make("Protection settings", "sliders-horizontal", "trip · release · delay"))
	var p: Dictionary = _design["bms_params"]
	var cont_a := float((_design["bms"] as Dictionary)["cont_a"])
	var g := GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", 4)
	_prot_box.add_child(g)
	for rw in PROT_ROWS:
		var key := str(rw[0])
		if not p.has(key):
			continue
		var lim: Dictionary = p[key]
		var kind := str(rw[2])
		var lbl := Label.new()
		lbl.text = str(rw[1])
		lbl.tooltip_text = "%s — opens %s" % [BattBms.WORDS[key], str(BattBms.OPENS[key]) if str(BattBms.OPENS[key]) != "both" else "both switches"]
		lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.clip_text = true
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		g.add_child(lbl)
		var mult := cont_a if kind == "a" else 1.0
		var unit := str({"v": "V", "a": "A", "c": "°C"}[kind])
		g.add_child(_prot_spin(key, "trip", float(lim["trip"]) * mult, kind, unit, mult))
		if kind == "a":
			var rl := Label.new()
			rl.text = "retries"
			rl.tooltip_text = "Current trips close the switch again after %.0f s (a short after %.0f s)" % [BattBmsLogic.RECOVER_S, BattBmsLogic.SC_RECOVER_S]
			rl.mouse_filter = Control.MOUSE_FILTER_PASS
			rl.custom_minimum_size = Vector2(74, 0)
			rl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			rl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
			g.add_child(rl)
		else:
			g.add_child(_prot_spin(key, "release", float(lim["release"]), kind, unit, 1.0))
		g.add_child(_prot_spin(key, "delay_s", float(lim["delay_s"]), "s", "s", 1.0))
	var reset := Button.new()
	reset.name = "prot_reset"
	reset.text = "Back to the BMS's own settings"
	UITheme.style_button(reset)
	reset.disabled = ((_spec["bms"] as Dictionary).get("overrides", {}) as Dictionary).is_empty()
	reset.pressed.connect(func() -> void:
		_push_undo()
		(_spec["bms"] as Dictionary)["overrides"] = {}
		_rebuild_now())
	_prot_box.add_child(reset)


func _prot_spin(key: String, field: String, value: float, kind: String, unit: String, mult: float) -> SpinBox:
	var sb := SpinBox.new()
	sb.name = "prot_%s_%s" % [key, field]
	match kind:
		"v":
			sb.min_value = 0.5
			sb.max_value = 5.0
			sb.step = 0.01
		"a":
			sb.min_value = 0.0
			sb.max_value = 20000.0
			sb.step = 1.0
		"c":
			sb.min_value = -40.0
			sb.max_value = 90.0
			sb.step = 1.0
		_:
			sb.min_value = 0.0
			sb.max_value = 3600.0
			sb.step = 0.0001 if key == "short_circuit" else 0.5
	sb.suffix = unit
	sb.custom_minimum_size = Vector2(74, 0)
	sb.select_all_on_focus = true
	sb.set_value_no_signal(value)
	sb.value_changed.connect(func(v: float) -> void: set_protection(key, field, v / mult))
	return sb


## One protection setting (trip in volts / × the rating / °C, release, delay_s).
func set_protection(key: String, field: String, value: float) -> void:
	_push_undo("prot." + key + "." + field)
	var b: Dictionary = _spec["bms"]
	var ov: Dictionary = b.get("overrides", {})
	var one: Dictionary = ov.get(key, {})
	one[field] = value
	ov[key] = one
	b["overrides"] = ov
	_rebuild_timer = REBUILD_DELAY


# ---------------------------------------------------------------------------
# Bank
# ---------------------------------------------------------------------------

## The bank's own fields (everything but the pack).
static func _bank_fields(b: Dictionary) -> Dictionary:
	var out := b.duplicate(true)
	out.erase("pack")
	return out


## The whole bank spec: the bank's fields round the pack being designed.
func bank_spec() -> Dictionary:
	var b := _bank.duplicate(true)
	b["pack"] = _spec.duplicate(true)
	if str(b.get("name", "")).is_empty() or str(b.get("name", "")) == "Battery bank":
		var n := int(b.get("series", 1)) * int(b.get("parallel", 1))
		b["name"] = "%s × %d" % [str(_spec["name"]), n] if n > 1 else str(_spec["name"])
	return BankSpec.resolve(b)


func bank_design() -> Dictionary:
	return _bank_design


func bank_builder() -> BankBuilder:
	return _bank_builder


func bank_panel() -> Control:
	return _bank_panel



## The headline tiles: the pack's, or the bank's on the Bank tab.
func _set_tiles() -> void:
	if _mode == "bank" and not _bank_design.is_empty():
		var be: Dictionary = _bank_design["electrical"]
		_col.set_tiles([
			{"caption": "Bank voltage", "value": "%.1f V" % float(be["v_nom"]), "tip": "The packs in series"},
			{"caption": "Usable energy", "value": "%.1f kWh" % (float(be["usable_wh"]) * 0.001), "tip": "Every pack's usable energy"},
			{"caption": "Max current", "value": "%.0f A" % float(be["cont_discharge_a"]), "tip": "The strings' BMS limits added"},
			{"caption": "Fault current", "value": "%s A" % UiText.thousands(int(be["i_sc"])), "tip": "What the bank can push into a short: the fuses must break it"},
			{"caption": "Weight", "value": "%.0f kg" % float(_bank_design["mass_kg"]), "tip": "Packs, frame, cables and fuses"},
			{"caption": "Cost", "value": "$%s" % UiText.thousands(int(_bank_design["cost_usd"])), "tip": "An estimate: packs, cables, fuses, frame"},
		])
		return
	var d := _design
	var e: Dictionary = d["electrical"]
	_col.set_tiles([
		{"caption": "Voltage", "value": "%.1f V" % float(e["v_nom"]), "tip": str(d["explain"]["voltage"])},
		{"caption": "Usable energy", "value": "%.2f kWh" % (float(e["usable_wh"]) * 0.001), "tip": str(d["explain"]["usable"])},
		{"caption": "Max current", "value": "%.0f A" % float(e["cont_discharge_a"]), "tip": str(d["explain"]["current"])},
		{"caption": "Capacity", "value": "%.0f Ah" % float(e["ah"]), "tip": str(d["explain"]["capacity"])},
		{"caption": "Weight", "value": "%.1f kg" % float(d["mass_kg"]), "tip": "Cells, links, cables, frame, BMS and case"},
		{"caption": "Cost / kWh", "value": "$%.0f" % float(d["usd_per_kwh"]), "tip": "An estimate: cells by $/Wh of their kind plus the parts round them"},
	])


func _rebuild_bank() -> void:
	var b := bank_spec()
	_bank_design = BankDesign.solve(b)
	if _bank_builder != null:
		_bank_builder.visible = false
		_bank_builder.queue_free()
	_bank_builder = BankBuilder.build_from_design(_bank_design)
	_bank_builder.name = "Bank"
	_studio.holder.add_child(_bank_builder)
	_bank_builder.visible = _mode == "bank"
	_bank_panel.call("set_design", _bank_design)
	if _mode == "bank":
		_set_tiles()
	if not _selected.is_empty() and not _bank_builder.part(_selected).is_empty():
		_bank_builder.highlight([_selected])
	var key := "%s|%d|%d|%s" % [BattSpec.key_of(_spec), int(b["series"]), int(b["parallel"]), _bank_design["mount"]]
	if key != _bank_framed and _mode == "bank":
		_bank_framed = key
		_frame.call_deferred(false)


## Paint the bank bench's frame on the bank in the studio (only while the
## Bench view is up).
func _paint_bench() -> void:
	if _bank_builder == null:
		return
	var on := _mode == "bank" and str(_bank_panel.call("view")) == "bench"
	_bank_builder.show_bench_frame((_bank_panel.call("bench") as Control).call("frame") if on else {})


func _on_bank_field(path: String, value: Variant) -> void:
	_push_undo("bank." + path)
	if path in ["series", "parallel"]:
		_bank[path] = int(value)
	else:
		_bank[path] = value
	_rebuild_bank()


## One bank field by path (the harness uses it).
func edit_bank(path: String, value: Variant) -> void:
	_on_bank_field(path, value)


func select_bank_part(id: String) -> void:
	_selected = id
	if _bank_builder == null:
		return
	var p := _bank_builder.part(id)
	_bank_builder.highlight([] if p.is_empty() else [id])
	var text := str(p.get("label", "Click a pack, a cable or a fuse to see what it is."))
	if str(p.get("kind", "")) == "pack":
		text += " · drag to move"
	_info_lbl.text = text


func _main() -> Node:
	var t := get_tree()
	return t.current_scene if t != null else null


func place_bank() -> void:
	var main := _main()
	if main == null or not main.has_method("get_node"):
		_status("Placing needs a world.")
		return
	var r: Dictionary = PlacedPropService.begin_placement(main, BankBuilder.MODEL_ID, {
		"record_extra": {"battery_bank_spec": bank_spec(), "collision_enabled": true}})
	if not bool(r.get("ok", true)):
		_status(str(r.get("error", "Could not start placing.")))
		return
	close()


## Write the bank back to what it was opened from: a placed bank (its record
## and graph battery) or a graph battery (its specs).
func apply_bank() -> void:
	var main := _main()
	var b := bank_spec()
	if not _bound_prop_id.is_empty() and main != null:
		PlacedPropService.update_prop_record(main, _bound_prop_id, {"battery_bank_spec": b}, true)
		PlacedPropService.seed_battery_bank(main, _bound_prop_id)
		_status("Applied to the placed bank: its graph battery follows.")
	elif not _bound_graph_id.is_empty():
		var gv := ServiceLocator.graph()
		var model: Variant = gv.get("model") if gv != null else null
		if model == null or (model.call("get_item", _bound_graph_id) as Dictionary).is_empty():
			_status("The graph battery is gone.")
			return
		var it: Dictionary = model.call("get_item", _bound_graph_id)
		var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		var soc := float(specs.get("soc", 0.8))
		for k in BankDesign.graph_specs(BankDesign.solve(b)).keys():
			specs[k] = BankDesign.graph_specs(BankDesign.solve(b))[k]
		specs["soc"] = soc
		specs["battery_bank_spec"] = b
		model.call("update_item", _bound_graph_id, {"specs": specs})
		_status("Applied to the graph battery: %s." % BattPresets.size_line(b["pack"]))
	_refresh_chain()


# ---------------------------------------------------------------------------
# The power chain (Panels › Controller › Battery)
# ---------------------------------------------------------------------------

func chain_bar() -> PowerChainBar:
	return _chain


## The graph battery this Lab is on ("" = none).
func _chain_item() -> String:
	if not _bound_graph_id.is_empty():
		return _bound_graph_id
	if not _bound_prop_id.is_empty() and _main() != null:
		return str(PlacedPropService.get_prop_record(_main(), _bound_prop_id).get("graph_item_id", ""))
	return ""


func _refresh_chain() -> void:
	if _chain != null:
		_chain.refresh(_chain_item())


## Leave for another lab: apply what was changed here first.
func _on_chain_hop(kind: String, unit: Dictionary) -> void:
	var ch := _chain.chain()
	var main := _main()
	if not _undo.is_empty() and not _chain_item().is_empty():
		apply_bank()
	close()
	PowerChainBar.go(main, kind, unit, ch)


func _on_chain_add(what: String) -> void:
	if what == "panels":
		_on_chain_hop("panels", {})
		return
	var gv := ServiceLocator.graph()
	var model: GraphModel = gv.get("model") as GraphModel if gv != null else null
	if model == null:
		return
	var nid := PowerChain.add_missing(model, _chain.chain(), what)
	_status("Added a controller to the graph, wired to this battery." if nid != "" else "Could not add it.")
	_refresh_chain()


## A graph battery's bank: its own design, else the built-in under its
## library label, else the closest built-in pack scaled to its voltage / Ah.
func _bank_from_graph(gid: String) -> Dictionary:
	var gv := ServiceLocator.graph()
	var model: Variant = gv.get("model") if gv != null else null
	if model == null:
		return {}
	var it: Dictionary = model.call("get_item", gid)
	var specs: Dictionary = it.get("specs", {}) as Dictionary
	if specs.get("battery_bank_spec") is Dictionary:
		return specs["battery_bank_spec"]
	if not str(specs.get("battery_preset", "")).is_empty():
		var pre := BattPresets.builtin(str(specs["battery_preset"]))
		if not pre.is_empty():
			return BankSpec.of_pack(pre, 1, 1, str(specs.get("name", "")))
	var lib := BattPresets.for_library_label(str(specs.get("name", "")))
	if lib.is_empty():
		lib = BattPresets.for_library_label(str(it.get("label", "")))
	if not lib.is_empty():
		return BankSpec.of_pack(lib["spec"], 1, 1, str(specs.get("name", "")))
	return BankSpec.of_pack(BattPresets.builtin("rack_48v_105"), 1, maxi(1, roundi(float(specs.get("ah", 100.0)) / 105.0)),
		str(specs.get("name", "Battery bank")))


func export_bank() -> void:
	var files := BankExport.write_all(_bank_design)
	if files.is_empty():
		_status("Could not write the files.")
		return
	_status("Wrote %s to %s." % [UiText.count(files.size(), "file"), ProjectSettings.globalize_path((files[0] as String).get_base_dir())])
