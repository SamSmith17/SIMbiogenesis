extends Control

## Controller Lab (plans/CONTROLLER_LAB_PLAN.md Phase 2): charge controllers,
## inverters and hybrids as designed 3D units. The left column is the built-in
## and saved designs; the centre is the unit in a studio; the right column is
## its shape, colours, heatsink, mounting, wiring bay, ports and electrical
## numbers.
##
## Ports are placed on the unit itself: "Add port" opens the connector kit,
## a pick arms it, a click on a face puts it there (Shift keeps the tool).
## A press on a port and a drag slides it along its face; R turns the
## selected port a quarter turn, Delete removes it, Esc puts the tool down.
##
## Opened by Main.open_ctrllab({spec, preset}). The core is core/ctrllab/.

const MODAL_NAME := "ctrllab_designer"
const WANT := Vector2(1640, 980)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.15
const DRAG_REBUILD := 0.05
const POLARITY_ITEMS := [["", "—"], ["+", "+"], ["-", "−"]]
const DOMAIN_ORDER := ["pv", "dc", "ac", "data", "io", "protection", "ground", "fitting", "ui"]
const SHEET_VIEW := preload("res://scenes/ui/ctrllab_sheet_view.gd")
const EXPORT_DIR := "user://ctrllab_designs"
const MULTI_POLE := ["terminal_block", "terminal_block_35", "power_terminal", "ac_block", "wago_lever",
	"din_breaker", "bus_bar"]

## [section, path, label, kind, a, b, step, unit, tip]. Paths go up to three
## levels into the spec ("bay.cover.window.on").
const FIELDS := [
	["Size & shape", "form", "Form", "option", "forms", "", 0.0, "", "What sort of unit this is: it decides nothing on its own, but the gallery and the checks read it"],
	["Size & shape", "body.w", "Width", "spin", 40.0, 1200.0, 1.0, "mm", "Side to side, seen from the front"],
	["Size & shape", "body.h", "Height", "spin", 30.0, 1500.0, 1.0, "mm", ""],
	["Size & shape", "body.d", "Depth", "spin", 15.0, 800.0, 1.0, "mm", "Front to back, not counting the heatsink fins"],
	["Size & shape", "body.corner_r", "Corner radius", "spin", 0.0, 120.0, 0.5, "mm", "The corners seen from the front: 0 = sharp (Victron), large = rounded (Growatt)"],
	["Size & shape", "body.edge_r", "Edge rounding", "spin", 0.0, 40.0, 0.5, "mm", "How round the front edge is"],
	["Size & shape", "body.finish", "Finish", "option", "finishes", "", 0.0, "", "Painted steel, moulded plastic or bare aluminium"],
	["Size & shape", "body.standoff", "Off the wall", "spin", 0.0, 80.0, 1.0, "mm", "A gap between the back and the wall"],
	["Colours", "body.split.y", "Two-tone at", "spin", -1.0, 1500.0, 1.0, "mm", "Below this height the body takes the second colour; −1 = one colour"],
	["Colours", "body.plate.on", "Front plate", "check", "", "", 0.0, "", "A separate front plate over a smaller shell (Growatt)"],
	["Colours", "body.plate.t", "Plate thickness", "spin", 1.0, 40.0, 0.5, "mm", ""],
	["Colours", "body.plate.inset", "Shell inset", "spin", 0.0, 60.0, 0.5, "mm", "How much smaller the shell behind the plate is"],
	["Colours", "caps.t", "End caps", "spin", 0.0, 40.0, 0.5, "mm", "Car-style inverters: the plastic ends over the extrusion; 0 = none"],
	["Heatsink & mounting", "heatsink.where", "Heatsink", "option", "heatsinks", "", 0.0, "", "Finned aluminium: on the back (charge controllers), all round (car-style inverters), at the sides or on top"],
	["Heatsink & mounting", "heatsink.fins", "Fins", "spin", 2.0, 80.0, 1.0, "", ""],
	["Heatsink & mounting", "heatsink.fin_d", "Fin depth", "spin", 2.0, 80.0, 0.5, "mm", ""],
	["Heatsink & mounting", "heatsink.fin_t", "Fin thickness", "spin", 0.5, 10.0, 0.1, "mm", ""],
	["Heatsink & mounting", "heatsink.base_t", "Base", "spin", 1.0, 20.0, 0.5, "mm", "The plate the fins stand on"],
	["Heatsink & mounting", "heatsink.extra_w", "Wider than the body", "spin", 0.0, 120.0, 1.0, "mm", "Side wings (the SmartSolar's mounting tabs are its heatsink)"],
	["Heatsink & mounting", "heatsink.slots", "Slots in the wings", "check", "", "", 0.0, "", "Open slots for the mounting screws"],
	["Heatsink & mounting", "mount.style", "Mounting", "option", "mounts", "", 0.0, "", "How it is fixed to the wall or shelf"],
	["Heatsink & mounting", "mount.where", "Where", "option", "mount_where", "", 0.0, "", ""],
	["Heatsink & mounting", "mount.n", "How many", "spin", 1.0, 8.0, 1.0, "", ""],
	["Heatsink & mounting", "mount.w", "Tab width", "spin", 4.0, 200.0, 1.0, "mm", ""],
	["Heatsink & mounting", "mount.h", "Tab height", "spin", 4.0, 200.0, 1.0, "mm", ""],
	["Wiring bay", "bay.on", "Wiring bay", "check", "", "", 0.0, "", "A recess at the bottom of the front behind a cover, where the cables land (the EG4 and Sol-Ark)"],
	["Wiring bay", "bay.y1", "Bay top", "spin", 20.0, 1500.0, 1.0, "mm", "Height of the bay's top edge"],
	["Wiring bay", "bay.wall", "Wall", "spin", 2.0, 60.0, 1.0, "mm", "Body left round the bay"],
	["Wiring bay", "bay.depth", "Depth", "spin", 10.0, 600.0, 1.0, "mm", "How far back the bay's back plate is"],
	["Wiring bay", "bay.cover.show", "Cover", "check", "", "", 0.0, "", "The cover plate over the bay"],
	["Wiring bay", "bay.cover.window.on", "Window in the cover", "check", "", "", 0.0, "", "A clear window onto the breakers"],
	["Wiring bay", "bay.cover.window.x0", "Window left", "spin", -600.0, 600.0, 1.0, "mm", "From the middle of the front"],
	["Wiring bay", "bay.cover.window.x1", "Window right", "spin", -600.0, 600.0, 1.0, "mm", ""],
	["Wiring bay", "bay.cover.window.y0", "Window bottom", "spin", 0.0, 1500.0, 1.0, "mm", ""],
	["Wiring bay", "bay.cover.window.y1", "Window top", "spin", 0.0, 1500.0, 1.0, "mm", ""],
	["Electrical", "elec.kind", "Kind", "option", "kinds", "", 0.0, "", "What it does: the terminals it must have follow from this"],
	["Electrical", "elec.system_v", "Battery voltage", "option", "system_v", "", 0.0, "", "Nominal battery bank voltage"],
	["Electrical", "elec.max_voc", "Max PV voltage", "spin", 0.0, 1500.0, 1.0, "V", "Highest open-circuit voltage the PV input survives (cold morning)"],
	["Electrical", "elec.mppt_count", "MPPT inputs", "spin", 0.0, 4.0, 1.0, "", "Independent PV inputs, each with its own tracker"],
	["Electrical", "elec.mppt_min_v", "MPPT from", "spin", 0.0, 1000.0, 1.0, "V", "The tracking window's low end"],
	["Electrical", "elec.mppt_max_v", "MPPT to", "spin", 0.0, 1000.0, 1.0, "V", "The tracking window's high end"],
	["Electrical", "elec.startup_v", "Start-up", "spin", 0.0, 1000.0, 1.0, "V", "PV voltage it needs to wake"],
	["Electrical", "elec.max_input_a", "PV current", "spin", 0.0, 200.0, 0.5, "A", "Per MPPT input"],
	["Electrical", "elec.max_isc_a", "PV short-circuit", "spin", 0.0, 200.0, 0.5, "A", "Highest Isc it accepts per input"],
	["Electrical", "elec.max_pv_w", "Max PV power", "spin", 0.0, 60000.0, 50.0, "W", "All inputs together"],
	["Electrical", "elec.max_charge_a", "Charge current", "spin", 0.0, 500.0, 1.0, "A", "Into the battery"],
	["Electrical", "elec.ac_out_w", "AC output", "spin", 0.0, 30000.0, 50.0, "W", "Continuous"],
	["Electrical", "elec.surge_w", "Surge", "spin", 0.0, 60000.0, 50.0, "W", "For a few seconds"],
	["Electrical", "elec.ac_v", "AC voltage", "spin", 0.0, 480.0, 1.0, "V", ""],
	["Electrical", "elec.split_phase", "Split phase", "check", "", "", 0.0, "", "120 / 240 V on L1 and L2"],
	["Electrical", "elec.ac_in_a", "Grid input", "spin", 0.0, 400.0, 1.0, "A", "Charger and pass-through from the grid; 0 = none"],
	["Electrical", "elec.load_a", "Load output", "spin", 0.0, 100.0, 1.0, "A", "Charge controllers: the DC load terminals"],
	["Electrical", "elec.idle_w", "Idle draw", "spin", 0.0, 500.0, 0.5, "W", ""],
	["Electrical", "elec.mass_kg", "Weight", "spin", 0.0, 200.0, 0.1, "kg", ""],
	["Electrical", "elec.cost", "Price", "spin", 0.0, 20000.0, 5.0, "$", ""],
]

## Rows shown only when another value is set.
const SHOW_IF := {
	"body.plate.t": "body.plate.on", "body.plate.inset": "body.plate.on",
	"bay.y1": "bay.on", "bay.wall": "bay.on", "bay.depth": "bay.on", "bay.cover.show": "bay.on",
	"bay.cover.window.on": "bay.on", "bay.cover.window.x0": "bay.cover.window.on",
	"bay.cover.window.x1": "bay.cover.window.on", "bay.cover.window.y0": "bay.cover.window.on",
	"bay.cover.window.y1": "bay.cover.window.on",
}
const COLOURS := [
	["body.color", "Body"], ["body.split.color", "Lower body"], ["body.plate.color", "Front plate"],
	["heatsink.color", "Heatsink"], ["caps.color", "End caps"], ["bay.color", "Wiring bay"],
]

var _active := false
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _undo: Array = []
var _redo: Array = []
var _coalesce_key := ""
var _coalesce_until := 0.0
var _rebuild_timer := -1.0
var _entries: Array = []
var _framed_key := ""
var _selected := ""          ## port id
var _tool := ""              ## connector id armed for placing
var _cover := true
var _drag := {}              ## {id, face, off: Vector2, moved}
var _eat_release := false
var _port_sig := ""

var _shell: DesignerShell
var _gallery: DesignGallery
var _studio: StudioViewport
var _builder: CtrlBuilder
var _ghost: MeshInstance3D
var _sel_box: MeshInstance3D
var _col: DesignerColumn
var _info_lbl: Label
var _checks_box: VBoxContainer
var _rows: Dictionary = {}
var _picks: Dictionary = {}
var _texts_box: VBoxContainer
var _ports_box: VBoxContainer
var _port_card: VBoxContainer
var _port_rows: Dictionary = {}
var _cover_btn: Button
var _palette: VBoxContainer
var _status_lbl: Label
var _mode := "unit"
var _tabs: TabBar
var _view_stack: Control
var _sheet_panel: VBoxContainer
var _sheet: Control
var _sheet_face := "front"
var _face_opt: OptionButton
var _wires_chk: CheckBox
var _callouts: Control
var _labels_btn: Button
var _labels := false
var _drawn_callouts: Array = []
var _bound_prop_id := ""
var _bound_graph_id := ""
var _chain: PowerChainBar = null
var _apply_btn: Button
var _place_btn: Button


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process(false)


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

## opts: {spec, preset, prop_id (a placed unit), graph_item_id (a graph
## controller)}.
func open(opts: Dictionary = {}) -> void:
	if _active:
		close()
	_bound_prop_id = str(opts.get("prop_id", ""))
	_bound_graph_id = str(opts.get("graph_item_id", ""))
	var spec: Dictionary = opts.get("spec", {}) as Dictionary
	if spec.is_empty() and not _bound_prop_id.is_empty() and _main() != null:
		var rec: Dictionary = PlacedPropService.get_prop_record(_main(), _bound_prop_id)
		if rec.get("controller_spec") is Dictionary:
			spec = rec["controller_spec"]
	if spec.is_empty() and not _bound_graph_id.is_empty():
		spec = _spec_from_graph(_bound_graph_id)
	if spec.is_empty() and str(opts.get("preset", "")) != "":
		spec = CtrlPresets.builtin(str(opts["preset"]))
	if spec.is_empty():
		spec = CtrlPresets.builtin("eg4_6000xp")
	_spec = CtrlSpec.resolve(spec)
	_undo.clear()
	_redo.clear()
	_selected = ""
	_tool = ""
	_cover = true
	_drag = {}
	_framed_key = ""
	_port_sig = ""
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_shell.open()
	_shell.scroll_top()
	_shell.set_undo_state(false, false)
	_studio.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_refresh_design_list()
	_labels = false
	var bound := not _bound_prop_id.is_empty() or not _bound_graph_id.is_empty()
	_apply_btn.disabled = not bound
	_apply_btn.tooltip_text = ("Write this design back to the placed unit and its graph controller" if not _bound_prop_id.is_empty()
		else ("Write its numbers and its terminals to the graph controller it was opened from" if bound
		else "Open the Lab from a graph controller (Design this controller…) or a placed unit to apply to it"))
	_rebuild_now()
	set_mode(str(opts.get("mode", "unit")))
	set_labels(false)
	_refresh_chain()


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_set_tool("")
	if _studio != null:
		_studio.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_shell.close()


func is_open() -> bool:
	return _active


func spec() -> Dictionary:
	return _spec


func design() -> Dictionary:
	return _design


func builder() -> CtrlBuilder:
	return _builder


func studio() -> StudioViewport:
	return _studio


func shell() -> DesignerShell:
	return _shell


func gallery() -> DesignGallery:
	return _gallery


func entry_count() -> int:
	return _entries.size()


func selected_port() -> String:
	return _selected


func tool() -> String:
	return _tool


func _process(delta: float) -> void:
	if _labels and _mode == "unit":
		_callouts.queue_redraw()
	if _rebuild_timer > 0.0:
		_rebuild_timer -= delta
		if _rebuild_timer <= 0.0:
			_rebuild_now()


func _input(e: InputEvent) -> void:
	if not _active or not (e is InputEventKey):
		return
	var ke := e as InputEventKey
	if not ke.pressed or ke.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		return
	if not _shell.flyout_shown().is_empty():
		return
	var done := true
	if ke.keycode == KEY_Z and ke.ctrl_pressed and not ke.shift_pressed:
		_undo_step()
	elif (ke.keycode == KEY_Y and ke.ctrl_pressed) or (ke.keycode == KEY_Z and ke.ctrl_pressed and ke.shift_pressed):
		_redo_step()
	elif ke.keycode == KEY_F and not ke.ctrl_pressed:
		if _mode == "terminals":
			_sheet.call("fit")
		else:
			_frame(true)
	elif ke.keycode == KEY_ESCAPE and _tool != "":
		_set_tool("")
	elif ke.keycode == KEY_ESCAPE and _selected != "":
		select_port("")
	elif ke.keycode == KEY_R and not ke.ctrl_pressed and _selected != "":
		rotate_port(_selected, -90.0 if ke.shift_pressed else 90.0)
	elif (ke.keycode == KEY_DELETE or ke.keycode == KEY_BACKSPACE) and _selected != "":
		remove_port(_selected)
	else:
		done = false
	if done:
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_shell = DesignerShell.create("Controller Lab", "cpu", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true, "undo": true,
		"left_label": "Designs", "left_w": 260.0, "right_w": 430.0})
	add_child(_shell)
	_shell.undo_requested.connect(_undo_step)
	_shell.redo_requested.connect(_redo_step)
	_shell.name_submitted.connect(_on_name_changed)
	_shell.closed.connect(close)
	_build_left()
	_build_centre()
	_build_right()
	_shell.set_hint("Drag to orbit · wheel to zoom · Shift-drag pans · Add port, then click the unit to place it (Shift keeps the tool) · drag a port to slide it · R turns it · Delete removes it · Esc puts the tool down · F frames · Ctrl+Z undoes")
	_shell.add_button("Save design", DesignerShell.SECONDARY, _on_save_design,
		"Keep this design in your library (every world)")
	_place_btn = _shell.add_button("Place in world", DesignerShell.SECONDARY, func() -> void: place_in_world(),
		"Stand the unit in the world (walls, floors, posts): a graph controller comes with it, and a placed battery bank's cables land on its studs")
	_place_btn.name = "place_in_world"
	_apply_btn = _shell.add_button("Apply", DesignerShell.PRIMARY, func() -> void: apply(),
		"Write this design back to what the Lab was opened from")
	_apply_btn.name = "apply"
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_chain = PowerChainBar.create("controller")
	_chain.follow(_shell)
	_shell.add_header_widget(_chain)
	_chain.hop_requested.connect(_on_chain_hop)
	_chain.add_requested.connect(_on_chain_add)


func _build_left() -> void:
	var box := _shell.left
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_gallery = DesignGallery.make("ctrllab")
	_gallery.set_thumbnailer(_thumb_for)
	_gallery.item_selected.connect(_on_design_activated)
	box.add_child(_gallery)
	var forget := Button.new()
	forget.name = "forget"
	forget.text = "Forget"
	forget.tooltip_text = "Remove the selected saved design (★)"
	UITheme.style_button(forget)
	forget.pressed.connect(_on_forget_design)
	box.add_child(forget)
	var about := Label.new()
	about.text = "Every built-in is a real unit: its size from the data sheet, its look from photographs, every terminal where it really is. Start from the one most like yours."
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.custom_minimum_size = Vector2(120, 0)
	about.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	about.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(about)


func _build_centre() -> void:
	var col := _shell.centre
	_tabs = TabBar.new()
	_tabs.name = "lab_tabs"
	_tabs.add_tab("Unit")
	_tabs.add_tab("Terminals")
	_tabs.set_tab_tooltip(0, "The unit in 3D: shape, colours, every port where it sits")
	_tabs.set_tab_tooltip(1, "One face straight on as a wiring diagram: every terminal labelled with what it is for")
	_tabs.tab_changed.connect(func(i: int) -> void: set_mode(["unit", "terminals"][i]))
	col.add_child(_tabs)
	_view_stack = Control.new()
	_view_stack.name = "view_stack"
	_view_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_stack.clip_contents = true
	col.add_child(_view_stack)
	_studio = StudioViewport.create({"ground": true, "person": false, "far": 40.0})
	_studio.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_studio.set_home(0.55, 0.3)
	_studio.pitch_min = -1.4
	_studio.dist_max = 12.0
	_studio.input_hook = _studio_input
	_studio.clicked.connect(_on_click)
	_studio.hovered.connect(_on_hover)
	_view_stack.add_child(_studio)
	_callouts = Control.new()
	_callouts.name = "callouts"
	_callouts.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_callouts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_callouts.visible = false
	_callouts.draw.connect(_draw_callouts)
	_view_stack.add_child(_callouts)
	_build_sheet()
	var st := _studio.strip
	for v in [["front", "Front", "Straight on"], ["back", "Back", "The heatsink and mounting"],
			["under", "Underside", "Where the cables come in on most units"], ["side", "Side", "From the right"]]:
		var b := Button.new()
		b.name = "view_" + str(v[0])
		b.text = str(v[1])
		b.tooltip_text = str(v[2])
		UITheme.style_button(b)
		b.pressed.connect(set_view.bind(str(v[0])))
		st.add_child(b)
	_cover_btn = Button.new()
	_cover_btn.name = "cover"
	_cover_btn.toggle_mode = true
	_cover_btn.text = "Cover off"
	UiIcons.apply(_cover_btn, "square-dashed", "Take the wiring bay's cover off to see the terminals")
	UITheme.style_button(_cover_btn)
	_cover_btn.toggled.connect(func(on: bool) -> void: set_cover_off(on))
	st.add_child(_cover_btn)
	_labels_btn = Button.new()
	_labels_btn.name = "labels"
	_labels_btn.toggle_mode = true
	_labels_btn.text = "Labels"
	UiIcons.apply(_labels_btn, "list", "Label every terminal on the unit with what it is for")
	UITheme.style_button(_labels_btn)
	_labels_btn.toggled.connect(func(on: bool) -> void: set_labels(on))
	st.add_child(_labels_btn)
	var close_up := Button.new()
	close_up.name = "close_up"
	close_up.text = "Close-up"
	UiIcons.apply(close_up, "eye", "The terminals straight on: the wiring bay with its cover off (or the face with the most terminals), labelled")
	UITheme.style_button(close_up)
	close_up.pressed.connect(close_up_terminals)
	st.add_child(close_up)
	# The connector kit, as a flyout.
	_palette = VBoxContainer.new()
	_palette.name = "connector_palette"
	_palette.add_theme_constant_override("separation", 2)
	for dom in DOMAIN_ORDER:
		var ids := ConnectorCatalog.ids_in(str(dom))
		if ids.is_empty():
			continue
		_palette.add_child(SectionHeader.make(str(ConnectorCatalog.DOMAIN_LABELS.get(dom, dom))))
		var grid := VBoxContainer.new()
		grid.add_theme_constant_override("separation", 1)
		for id in ids:
			var b2 := Button.new()
			b2.name = "conn_" + str(id)
			b2.text = ConnectorCatalog.label(str(id))
			var e := ConnectorCatalog.entry(str(id))
			var rt: Dictionary = e.get("rating", {}) as Dictionary
			var tip := str(e.get("family", ""))
			if float(rt.get("amps", 0.0)) > 0.0:
				tip += " · %s A" % _num(float(rt["amps"]))
			if float(rt.get("volts", 0.0)) > 0.0:
				tip += " · %s V" % _num(float(rt["volts"]))
			b2.tooltip_text = tip
			b2.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b2.flat = true
			b2.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			b2.pressed.connect(_set_tool.bind(str(id)))
			grid.add_child(b2)
		_palette.add_child(grid)
	_shell.add_flyout_button("ports", "Add port", "plus", _palette,
		{"tip": "The connector kit: pick one, then click where it goes on the unit", "width": 340.0,
		"search": true, "placeholder": "Search connectors", "close_on_pick": "conn_"})
	_info_lbl = Label.new()
	_info_lbl.name = "part_info"
	_info_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_info_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_info_lbl.clip_text = true
	_info_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_info_lbl.text = "Click a port to see what it is for."
	col.add_child(_info_lbl)


func _build_right() -> void:
	var box := _shell.right
	box.add_child(SectionHeader.make("Checks", "circle-check"))
	_checks_box = VBoxContainer.new()
	_checks_box.name = "checks"
	_checks_box.add_theme_constant_override("separation", 4)
	box.add_child(_checks_box)
	var secs := {}
	for t in ["Ports", "Size & shape", "Colours", "Heatsink & mounting", "Wiring bay", "Front panel", "Electrical"]:
		var sec := Collapsible.make(t, true)
		box.add_child(sec)
		secs[t] = sec.body
	# Ports: the list, then the selected port's card.
	var pb: VBoxContainer = secs["Ports"]
	_port_card = VBoxContainer.new()
	_port_card.name = "port_card"
	_port_card.add_theme_constant_override("separation", 2)
	pb.add_child(_port_card)
	_ports_box = VBoxContainer.new()
	_ports_box.name = "port_list"
	_ports_box.add_theme_constant_override("separation", 1)
	pb.add_child(_ports_box)
	_build_port_card()
	# Settings.
	for fv in FIELDS:
		var f: Array = fv
		var path := str(f[1])
		var body: VBoxContainer = secs[str(f[0])]
		var rid := path.replace(".", "_")
		var row: FormRow = null
		match str(f[3]):
			"spin":
				row = FormRow.spin(str(f[2]), float(f[4]), float(f[5]), float(f[6]), str(f[7]), _on_field.bind(path), str(f[8]), rid)
			"option":
				row = FormRow.option(str(f[2]), _items(str(f[4])), _on_field.bind(path), str(f[8]), rid)
			"check":
				row = FormRow.check(str(f[2]), "On", _on_field.bind(path), str(f[8]), rid)
		if row != null:
			body.add_child(row)
			_rows[path] = row
	# Colours.
	var cb: VBoxContainer = secs["Colours"]
	for c in COLOURS:
		var path2 := str(c[0])
		var pick := ColorPickerButton.new()
		pick.edit_alpha = false
		pick.custom_minimum_size = Vector2(80, 24)
		pick.color_changed.connect(func(col: Color) -> void: _set_colour(path2, col))
		var row2 := FormRow.make(str(c[1]), pick, "", "", path2.replace(".", "_"))
		cb.add_child(row2)
		_picks[path2] = row2
	# Front panel: the printed words.
	var fb: VBoxContainer = secs["Front panel"]
	for r in [["maker", "Maker"], ["model", "Model"]]:
		var tr := FormRow.text_edit(str(r[1]), "", _on_field.bind(str(r[0])), "", str(r[0]))
		fb.add_child(tr)
		_rows[str(r[0])] = tr
	_texts_box = VBoxContainer.new()
	_texts_box.name = "texts"
	_texts_box.add_theme_constant_override("separation", 2)
	fb.add_child(_texts_box)
	var copy := Button.new()
	copy.text = "Copy summary"
	copy.tooltip_text = "Every number and check, as text"
	UITheme.style_button(copy)
	copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(summary()); _status("Summary copied."))
	box.add_child(copy)
	_status_lbl = Label.new()
	_status_lbl.name = "status"
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_status_lbl)
	_col = DesignerColumn.setup(box, "ctrllab", {"open": ["Ports", "Size & shape"], "tile_cols": 3})


func _build_port_card() -> void:
	var conn_items: Array = []
	for dom in DOMAIN_ORDER:
		for id in ConnectorCatalog.ids_in(str(dom)):
			conn_items.append([str(id), ConnectorCatalog.label(str(id))])
	var face_items: Array = []
	for f in CtrlSpec.FACES:
		face_items.append([str(f), str(f).capitalize() if str(f) != "bay" else "Wiring bay"])
	var group_items: Array = []
	for g in CtrlRoles.GROUPS:
		group_items.append([str(g), str(CtrlRoles.GROUPS[g])])
	var title := Label.new()
	title.name = "port_title"
	title.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	title.add_theme_color_override("font_color", UITheme.C_TEXT)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_port_card.add_child(title)
	_port_rows["title"] = title
	var defs := [
		["connector", FormRow.option("Connector", conn_items, _on_port_field.bind("connector"), "The standard it is", "pc_connector")],
		["label", FormRow.text_edit("Label", "Printed beside it", _on_port_field.bind("label"), "", "pc_label")],
		["group", FormRow.option("Is for", group_items, _on_port_field.bind("group"), "What it connects to: its pins' roles follow (BAT + / −, PV 2 +, AC out L …)", "pc_group")],
		["polarity", FormRow.option("Polarity", POLARITY_ITEMS, _on_port_field.bind("opts.polarity"), "A single terminal: plus or minus", "pc_polarity")],
		["poles", FormRow.spin("Poles", 1.0, 24.0, 1.0, "", _on_port_field.bind("opts.poles"), "Terminal strips, breakers, bus bars", "pc_poles")],
		["face", FormRow.option("Face", face_items, _on_port_field.bind("face"), "Which side of the unit it is on", "pc_face")],
		["u", FormRow.spin("Across", -800.0, 800.0, 0.5, "mm", _on_port_field.bind("u"), "From the middle of its face", "pc_u")],
		["v", FormRow.spin("Up", -800.0, 800.0, 0.5, "mm", _on_port_field.bind("v"), "From the middle of its face", "pc_v")],
		["rot", FormRow.spin("Turned", -180.0, 180.0, 15.0, "°", _on_port_field.bind("rot"), "R turns the selected port a quarter turn", "pc_rot")],
		["dz", FormRow.spin("Out", -40.0, 40.0, 0.5, "mm", _on_port_field.bind("dz"), "Stands out of (+) or into (−) its face", "pc_dz")],
	]
	for dv in defs:
		_port_card.add_child(dv[1] as Control)
		_port_rows[str(dv[0])] = dv[1]
	var pins := Label.new()
	pins.name = "port_pins"
	pins.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pins.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	pins.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_port_card.add_child(pins)
	_port_rows["pins"] = pins
	var rm := Button.new()
	rm.name = "port_remove"
	rm.text = "Remove port"
	UiIcons.apply(rm, "trash-2", "Delete")
	UITheme.style_button(rm)
	rm.pressed.connect(func() -> void: remove_port(_selected))
	_port_card.add_child(rm)
	_port_card.visible = false


static func _items(table: String) -> Array:
	var out: Array = []
	match table:
		"forms":
			for f in CtrlSpec.FORMS:
				out.append([str(f), str(CtrlSpec.FORM_WORDS[f])])
		"kinds":
			for k in CtrlSpec.KINDS:
				out.append([str(k), str(CtrlSpec.KIND_WORDS[k])])
		"finishes":
			out = [["paint", "Painted"], ["plastic", "Plastic"], ["alu", "Bare aluminium"]]
		"heatsinks":
			out = [["none", "None"], ["back", "On the back"], ["full", "All round (car style)"], ["sides", "At the sides"], ["top", "On top"]]
		"mounts":
			out = [["none", "None"], ["tabs", "Tabs top and bottom"], ["flange", "Flange plate"], ["side_feet", "Folded side feet"],
				["bracket", "Wall bracket"], ["feet", "Feet"], ["ears", "Rack ears"], ["handles", "Handles"]]
		"mount_where":
			out = [["both", "Top and bottom"], ["top", "Top"], ["bottom", "Bottom"], ["sides", "Sides"]]
		"system_v":
			for v in [12, 24, 36, 48]:
				out.append([v, "%d V" % v])
	return out


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
	_undo.append(_spec.duplicate(true))
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()
	_shell.set_undo_state(true, false)


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(_spec.duplicate(true))
	_spec = _undo.pop_back()
	_coalesce_key = ""
	_shell.set_undo_state(not _undo.is_empty(), not _redo.is_empty())
	_after_restore()


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_spec.duplicate(true))
	_spec = _redo.pop_back()
	_coalesce_key = ""
	_shell.set_undo_state(not _undo.is_empty(), not _redo.is_empty())
	_after_restore()


func _after_restore() -> void:
	if _selected != "" and _port_index(_selected) < 0:
		_selected = ""
	_rebuild_now()


static func get_path_value(d: Dictionary, path: String) -> Variant:
	var cur: Variant = d
	for k in path.split("."):
		if not (cur is Dictionary) or not (cur as Dictionary).has(k):
			return null
		cur = (cur as Dictionary)[k]
	return cur


static func set_path_value(d: Dictionary, path: String, value: Variant) -> void:
	var parts := path.split(".")
	var cur: Dictionary = d
	for i in parts.size() - 1:
		if not (cur.get(parts[i]) is Dictionary):
			cur[parts[i]] = {}
		cur = cur[parts[i]]
	var last := parts[parts.size() - 1]
	var old: Variant = cur.get(last)
	if old is int and (value is float or value is int):
		value = int(value)
	cur[last] = value


func _on_field(value: Variant, path: String) -> void:
	_push_undo(path)
	set_path_value(_spec, path, value)
	if path in ["bay.on", "heatsink.where", "mount.style", "form", "body.plate.on"]:
		_rebuild_now()
		return
	_rebuild_timer = REBUILD_DELAY


## One field by path, rebuilt at once (the harness uses it).
func edit(path: String, value: Variant) -> void:
	_on_field(value, path)
	_rebuild_now()


func _set_colour(path: String, c: Color) -> void:
	_push_undo(path)
	set_path_value(_spec, path, [c.r, c.g, c.b])
	_rebuild_timer = REBUILD_DELAY


func set_spec(s: Dictionary) -> void:
	_push_undo()
	_spec = CtrlSpec.resolve(s)
	_selected = ""
	_set_tool("")
	_rebuild_now()


func load_builtin(id: String) -> void:
	set_spec(CtrlPresets.builtin(id))


func _on_name_changed(text: String) -> void:
	if text.strip_edges().is_empty() or text == str(_spec["name"]):
		return
	_push_undo("name")
	_spec["name"] = text.strip_edges()


# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------

func _port_index(id: String) -> int:
	var ps: Array = _spec["ports"]
	for i in ps.size():
		if str(ps[i]["id"]) == id:
			return i
	return -1


func port_spec(id: String) -> Dictionary:
	var i := _port_index(id)
	return (_spec["ports"] as Array)[i] if i >= 0 else {}


func select_port(id: String) -> void:
	_selected = id if _port_index(id) >= 0 else ""
	_sync_port_card()
	_sync_port_list()
	_update_sel_box()
	if _sheet != null:
		_sheet.set("selected", _selected)
		_sheet.queue_redraw()
	if _selected != "":
		_info_lbl.text = _port_words(_selected)
		var sec := _col.section("Ports") if _col != null else null
		if sec != null:
			sec.folded = false
		_scroll_to.call_deferred(_port_card)


## A new port of `connector` at {face, u, v}: its job guessed from the
## connector and the ports already there. Returns its id.
func add_port(connector: String, face: String, u: float, v: float) -> String:
	_push_undo()
	var ps: Array = _spec["ports"]
	var n := ps.size() + 1
	var id := "p%d" % n
	while _port_index(id) >= 0:
		n += 1
		id = "p%d" % n
	var sg := CtrlRoles.suggest(connector, ps)
	var opts := {}
	if str(sg["polarity"]) != "":
		opts["polarity"] = sg["polarity"]
	ps.append({"id": id, "connector": connector, "face": face, "u": snappedf(u, 0.5), "v": snappedf(v, 0.5),
		"group": str(sg["group"]), "label": "", "opts": opts, "roles": [], "rot": 0.0, "dz": 0.0})
	_selected = id
	_rebuild_now()
	return id


func remove_port(id: String) -> void:
	var i := _port_index(id)
	if i < 0:
		return
	_push_undo()
	(_spec["ports"] as Array).remove_at(i)
	if _selected == id:
		_selected = ""
	_rebuild_now()
	_status("Port removed.")


func rotate_port(id: String, deg: float) -> void:
	var p := port_spec(id)
	if p.is_empty():
		return
	_push_undo("rot:" + id)
	p["rot"] = wrapf(float(p.get("rot", 0.0)) + deg, -180.0, 180.0)
	_rebuild_now()


func move_port(id: String, face: String, u: float, v: float) -> void:
	var p := port_spec(id)
	if p.is_empty():
		return
	_push_undo("move:" + id)
	p["face"] = face
	p["u"] = snappedf(u, 0.5)
	p["v"] = snappedf(v, 0.5)
	_rebuild_now()


func _on_port_field(value: Variant, key: String) -> void:
	var p := port_spec(_selected)
	if p.is_empty():
		return
	_push_undo("port:%s:%s" % [_selected, key])
	if key == "connector":
		# A new connector: drop the old one's opts but keep the polarity.
		var pol: Variant = (p.get("opts", {}) as Dictionary).get("polarity", null)
		p["opts"] = {}
		if pol != null:
			p["opts"]["polarity"] = pol
		p["roles"] = []
	if key.begins_with("opts."):
		if not (p.get("opts") is Dictionary):
			p["opts"] = {}
		var k := key.substr(5)
		if (k == "polarity" and str(value) == "") or (k == "poles" and int(value) <= 0):
			(p["opts"] as Dictionary).erase(k)
		else:
			p["opts"][k] = int(value) if k == "poles" else value
	else:
		p[key] = value
	_rebuild_timer = REBUILD_DELAY if key in ["label", "u", "v", "dz", "rot"] else 0.01


func _set_tool(id: String) -> void:
	_tool = id
	if _sheet != null:
		_sheet.set("tool", id)
		_sheet.queue_redraw()
	if id != "":
		select_port("")
		_shell.set_mode("Placing %s · click the unit · Esc to stop" % ConnectorCatalog.label(id))
		_info_lbl.text = I18n.f("Click a face of the unit to put the {id} there.", {"id": ConnectorCatalog.label(id)})
		_make_ghost(id)
	else:
		_shell.set_mode("")
		if _ghost != null:
			_ghost.queue_free()
			_ghost = null


func _make_ghost(id: String) -> void:
	if _ghost != null:
		_ghost.queue_free()
	_ghost = MeshInstance3D.new()
	_ghost.name = "PortGhost"
	_ghost.set_meta("studio_no_frame", true)
	_ghost.mesh = ConnectorParts.mesh(id, CtrlRoles.suggest(id, _spec["ports"]))
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.35, 0.85, 1.0, 0.55)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	_ghost.material_override = m
	_ghost.visible = false
	_studio.holder.add_child(_ghost)


func _face_xf_m(face: String, u: float, v: float) -> Transform3D:
	var f: Dictionary = _design["faces"][face]
	var xf: Transform3D = (f["xf"] as Transform3D) * Transform3D(Basis.IDENTITY, Vector3(u, v, 0.0))
	return Transform3D(xf.basis, xf.origin * CtrlBuilder.MM)


## The face under a container position: {face, u, v} or {}.
func face_at(pos: Vector2) -> Dictionary:
	if _builder == null:
		return {}
	var r := _studio.pick_ray_local(_builder, pos)
	if r.is_empty():
		return {}
	var o: Vector3 = (r["origin"] as Vector3) / CtrlBuilder.MM
	return CtrlDesign.face_hit(_design, o, r["dir"], not _cover)


func _face_point(face: String, pos: Vector2) -> Dictionary:
	if _builder == null or not (_design["faces"] as Dictionary).has(face):
		return {}
	var r := _studio.pick_ray_local(_builder, pos)
	if r.is_empty():
		return {}
	var f: Dictionary = _design["faces"][face]
	var o: Vector3 = (r["origin"] as Vector3) / CtrlBuilder.MM
	var dir: Vector3 = r["dir"]
	var n: Vector3 = f["n"]
	var den := dir.dot(n)
	if absf(den) < 1e-6:
		return {}
	var t := ((f["c"] as Vector3) - o).dot(n) / den
	if t < 0.0:
		return {}
	var p := o + dir * t
	return {"u": (p - (f["c"] as Vector3)).dot(f["x"] as Vector3), "v": (p - (f["c"] as Vector3)).dot(f["y"] as Vector3)}


## The studio's own input first: placing and dragging ports. True = taken.
func _studio_input(e: InputEvent) -> bool:
	if not _active or _builder == null:
		return false
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _tool != "" and _ghost != null:
			var h := face_at(mm.position)
			_ghost.visible = not h.is_empty()
			if not h.is_empty():
				_ghost.transform = _face_xf_m(str(h["face"]), float(h["u"]), float(h["v"]))
			return false
		if not _drag.is_empty():
			var fp := _face_point(str(_drag["face"]), mm.position)
			if not fp.is_empty():
				var p := port_spec(str(_drag["id"]))
				if not p.is_empty():
					if not bool(_drag["moved"]):
						_push_undo()
						_drag["moved"] = true
					var off: Vector2 = _drag["off"]
					p["u"] = snappedf(float(fp["u"]) - off.x, 0.5)
					p["v"] = snappedf(float(fp["v"]) - off.y, 0.5)
					if _rebuild_timer <= 0.0:
						_rebuild_timer = DRAG_REBUILD
			return true
		return false
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if not mb.pressed:
			if not _drag.is_empty():
				var moved := bool(_drag["moved"])
				_drag = {}
				_rebuild_now()
				if moved:
					_status("Port moved.")
				return true
			if _eat_release:
				_eat_release = false
				return true
			return false
		if _tool != "":
			var h2 := face_at(mb.position)
			if h2.is_empty():
				return false
			var conn := _tool
			var id := add_port(conn, str(h2["face"]), float(h2["u"]), float(h2["v"]))
			_eat_release = true
			if not mb.shift_pressed:
				_set_tool("")
			select_port(id)
			_status("Added %s." % ConnectorCatalog.label(conn))
			return true
		var r := _studio.pick_ray_local(_builder, mb.position)
		if r.is_empty():
			return false
		var hit := _builder.pick(r["origin"], r["dir"])
		if _port_index(hit) < 0:
			return false
		select_port(hit)
		var p2 := port_spec(hit)
		var fp2 := _face_point(str(p2["face"]), mb.position)
		var off2 := Vector2.ZERO
		if not fp2.is_empty():
			off2 = Vector2(float(fp2["u"]) - float(p2["u"]), float(fp2["v"]) - float(p2["v"]))
		_drag = {"id": hit, "face": str(p2["face"]), "off": off2, "moved": false}
		return true
	return false


func _on_click(pos: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT or _builder == null or _tool != "":
		return
	var r := _studio.pick_ray_local(_builder, pos)
	if r.is_empty():
		return
	var hit := _builder.pick(r["origin"], r["dir"])
	if _port_index(hit) >= 0:
		select_port(hit)
	else:
		select_port("")
		var pt := _builder.part(hit)
		_info_lbl.text = str(pt.get("label", "Click a port to see what it is for."))


func _on_hover(pos: Vector2) -> void:
	if _builder == null or _tool != "" or _selected != "" or not _drag.is_empty():
		return
	var r := _studio.pick_ray_local(_builder, pos)
	if r.is_empty():
		return
	var hit := _builder.pick(r["origin"], r["dir"])
	if _port_index(hit) >= 0:
		_info_lbl.text = _port_words(hit)
	elif hit != "":
		_info_lbl.text = str(_builder.part(hit).get("label", ""))


## What a port is, in words: "BAT + (Bolt terminal) · Battery + · 2 pins".
func _port_words(id: String) -> String:
	for p in (_design.get("ports", []) as Array):
		if str(p["id"]) != id:
			continue
		var e: Dictionary = p["entry"]
		var name := str(p["label"]) if str(p["label"]) != "" else str(e.get("label", ""))
		var roles: Array = []
		for r in (p["roles"] as Array):
			if str(r) != "" and not roles.has(CtrlRoles.words(str(r))):
				roles.append(CtrlRoles.words(str(r)))
		var rt: Dictionary = e.get("rating", {}) as Dictionary
		var bits: Array = [name]
		if str(p["label"]) != "":
			bits.append(str(e.get("label", "")))
		if not roles.is_empty():
			bits.append(", ".join(roles))
		if float(rt.get("amps", 0.0)) > 0.0:
			bits.append("rated %s A" % _num(float(rt["amps"])))
		return " · ".join(bits)
	return ""


func _build_sheet() -> void:
	_sheet_panel = VBoxContainer.new()
	_sheet_panel.name = "sheet_panel"
	_sheet_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sheet_panel.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_sheet_panel.visible = false
	_view_stack.add_child(_sheet_panel)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_sheet_panel.add_child(bar)
	_face_opt = OptionButton.new()
	_face_opt.name = "sheet_face"
	_face_opt.fit_to_longest_item = false
	_face_opt.custom_minimum_size = Vector2(190, 0)
	_face_opt.tooltip_text = "Which face of the unit to draw (the front includes the wiring bay)"
	_face_opt.item_selected.connect(func(i: int) -> void: set_sheet_face(str(_face_opt.get_item_metadata(i))))
	bar.add_child(_face_opt)
	_wires_chk = CheckBox.new()
	_wires_chk.name = "sheet_wires"
	_wires_chk.text = "Wires"
	_wires_chk.button_pressed = true
	_wires_chk.tooltip_text = "A lead from every wired terminal in its conductor colour (L black, L2 red, N white, G green; DC + red, − black; data teal)"
	_wires_chk.toggled.connect(func(on: bool) -> void:
		_sheet.set("show_wires", on)
		_sheet.queue_redraw())
	bar.add_child(_wires_chk)
	var fit_btn := Button.new()
	fit_btn.name = "sheet_fit"
	fit_btn.text = "Fit"
	UiIcons.apply(fit_btn, "scan", "Fit the drawing to the view (F)")
	UITheme.style_button(fit_btn)
	fit_btn.pressed.connect(func() -> void: _sheet.call("fit"))
	bar.add_child(fit_btn)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(sp)
	var ex := Button.new()
	ex.name = "sheet_export"
	ex.text = "Export wiring sheet"
	UiIcons.apply(ex, "download", "Every face with terminals as one SVG to print, and this view as a PNG, under user://ctrllab_designs/")
	UITheme.style_button(ex)
	ex.pressed.connect(func() -> void: export_sheet())
	bar.add_child(ex)
	_sheet = SHEET_VIEW.new()
	_sheet.name = "sheet"
	_sheet.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sheet_panel.add_child(_sheet)
	_sheet.connect("port_selected", func(id: String) -> void: select_port(id))
	_sheet.connect("port_moved", _on_sheet_moved)
	_sheet.connect("place_requested", _on_sheet_place)


func sheet() -> Control:
	return _sheet


func mode() -> String:
	return _mode


func sheet_face() -> String:
	return _sheet_face


## "unit" (3D) or "terminals" (the flat wiring view).
func set_mode(m: String) -> void:
	_mode = m
	var want := 1 if m == "terminals" else 0
	if _tabs != null and _tabs.current_tab != want:
		_tabs.set_current_tab(want)
	_studio.visible = m == "unit"
	_callouts.visible = m == "unit" and _labels
	_sheet_panel.visible = m == "terminals"
	if m == "terminals":
		_refresh_sheet()
		_sheet.call_deferred("fit")


func set_sheet_face(f: String) -> void:
	_sheet_face = f
	_refresh_sheet()
	_sheet.call("fit")


func _refresh_sheet() -> void:
	if _sheet == null or _design.is_empty():
		return
	var faces := CtrlSheet.faces_with_ports(_design)
	for f in ["front", "back", "left", "right", "top", "bottom"]:
		if not faces.has(f):
			faces.append(f)
	if not faces.has(_sheet_face):
		_sheet_face = str(faces[0])
	_face_opt.clear()
	for f2 in faces:
		var n := 0
		for p in (_design["ports"] as Array):
			var pf := str(p["face"])
			if pf == f2 or (f2 == "front" and pf == "bay"):
				n += 1
		_face_opt.add_item("%s%s" % [CtrlSheet.FACE_WORDS[f2], " (%d)" % n if n > 0 else ""])
		_face_opt.set_item_metadata(_face_opt.item_count - 1, f2)
		if f2 == _sheet_face:
			_face_opt.select(_face_opt.item_count - 1)
	_sheet.call("set_layout", CtrlSheet.layout(_design, _sheet_face), _selected)
	_sheet.set("tool", _tool)


func _on_sheet_moved(id: String, delta: Vector2) -> void:
	var p := port_spec(id)
	if p.is_empty():
		return
	move_port(id, str(p["face"]), float(p["u"]) + delta.x, float(p["v"]) + delta.y)
	_status("Port moved.")


func _on_sheet_place(face: String, u: float, v: float) -> void:
	if _tool == "" or not (_design["faces"] as Dictionary).has(face):
		return
	var conn := _tool
	var id := add_port(conn, face, u, v)
	if not Input.is_key_pressed(KEY_SHIFT):
		_set_tool("")
	select_port(id)
	_status("Added %s." % ConnectorCatalog.label(conn))


## The terminals straight on: the wiring bay with its cover off, else the
## face with the most terminals; labels on.
func close_up_terminals() -> void:
	set_mode("unit")
	var faces: Dictionary = _design["faces"]
	var face := "front"
	if faces.has("bay"):
		face = "bay"
		set_cover_off(true)
	else:
		var best := -1
		for f in CtrlSheet.FACE_ORDER:
			if not faces.has(f):
				continue
			var n := 0
			for p in (_design["ports"] as Array):
				if str(p["face"]) == f and str(ConnectorCatalog.entry(str(p["connector"])).get("domain", "")) != "ui":
					n += 1
			if n > best:
				best = n
				face = str(f)
	var f2: Dictionary = faces[face]
	var nrm: Vector3 = f2["n"]
	var size: Vector2 = f2["size"]
	_studio.yaw = atan2(nrm.x, nrm.z) if absf(nrm.y) < 0.9 else _studio.yaw
	_studio.pitch = clampf(asin(clampf(nrm.y, -1.0, 1.0)) * 0.95 + 0.06, _studio.pitch_min, _studio.pitch_max)
	_studio.target = (f2["c"] as Vector3) * CtrlBuilder.MM
	_studio.dist = clampf(maxf(size.x, size.y) * CtrlBuilder.MM * 1.9, StudioViewport.DIST_MIN, _studio.dist_max)
	_studio.update_camera()
	set_labels(true)


func set_labels(on: bool) -> void:
	_labels = on
	if _labels_btn != null:
		_labels_btn.set_pressed_no_signal(on)
	_callouts.visible = on and _mode == "unit"
	_callouts.queue_redraw()


## The callouts drawn last frame: [{text, pos}] (for checks).
func callouts() -> Array:
	return _drawn_callouts


func _draw_callouts() -> void:
	_drawn_callouts = []
	if _builder == null or _studio.camera == null or not _labels:
		return
	var cam := _studio.camera
	var cam_pos := cam.global_transform.origin
	var cs := _studio.container.size
	var vs := Vector2(_studio.viewport.size)
	if vs.x <= 0.0 or vs.y <= 0.0:
		return
	var to_local := _callouts.get_global_transform().affine_inverse() * _studio.container.get_global_transform()
	var font := UITheme.font("semibold")
	var fs := UITheme.FONT_XS
	var placed: Array = []
	var bxf := _builder.global_transform
	for p in (_design["ports"] as Array):
		if str(p["face"]) == "bay" and _builder.cover_visible():
			continue
		for pin in (p["pins"] as Array):
			var role := str(pin["role"])
			if role == "" or CtrlRoles.group_of(role) == "ui":
				continue
			var w := bxf * ((pin["pos"] as Vector3) * CtrlBuilder.MM)
			var n := (bxf.basis * ((p["xf"] as Transform3D).basis.z)).normalized()
			if n.dot(cam_pos - w) <= 0.0 or cam.is_position_behind(w):
				continue
			var pt: Vector2 = to_local * (cam.unproject_position(w) * (cs / vs))
			var text := CtrlSheet.short(role)
			var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var box := Rect2(pt + Vector2(8, -fs - 10), Vector2(tw + 8, fs + 6))
			var ok := true
			for r in placed:
				if (r as Rect2).intersects(box):
					ok = false
					break
			var col := CtrlSheet.wire_color(role)
			_callouts.draw_circle(pt, 3.0, col.lightened(0.2), true, -1.0, true)
			if not ok:
				continue
			placed.append(box)
			_callouts.draw_line(pt, box.position + Vector2(0, box.size.y), Color(0.85, 0.87, 0.9, 0.8), 1.0, true)
			_callouts.draw_rect(box, Color(0.05, 0.06, 0.08, 0.85))
			_callouts.draw_rect(Rect2(box.position, Vector2(3, box.size.y)), col.lightened(0.15))
			_callouts.draw_string(font, box.position + Vector2(6, fs + 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.95, 0.96, 0.98))
			_drawn_callouts.append({"text": text, "pos": pt})


## The wiring sheet: every face with terminals in one SVG, and the current
## Terminals view as a PNG. Returns the folder ("" when it cannot write).
func export_sheet() -> String:
	var slug := str(_spec["name"]).to_lower().strip_edges()
	var clean := ""
	for ch in slug:
		clean += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	var dir := "%s/%s" % [EXPORT_DIR, clean.left(48)]
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir + "/wiring.svg", FileAccess.WRITE)
	if f == null:
		_status("Could not write the wiring sheet.")
		return ""
	f.store_string(CtrlSheet.svg(_design))
	f.close()
	if _mode == "terminals" and _sheet.is_visible_in_tree():
		var img := get_viewport().get_texture().get_image()
		var xf := get_viewport().get_final_transform() * _sheet.get_global_transform()
		var rr := Rect2(xf.origin, xf.basis_xform(_sheet.size)).intersection(Rect2(Vector2.ZERO, Vector2(img.get_size())))
		var r := Rect2i(rr)
		if r.size.x > 8 and r.size.y > 8:
			img.get_region(r).save_png("%s/terminals_%s.png" % [dir, _sheet_face])
	_status("Wiring sheet written to %s" % ProjectSettings.globalize_path(dir))
	return dir


func _scroll_to(c: Control) -> void:
	var p := c.get_parent()
	while p != null:
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible(c)
			return
		p = p.get_parent()


# ---------------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------------

func set_view(v: String) -> void:
	match v:
		"front":
			_studio.set_orbit(0.0, 0.05)
		"back":
			_studio.set_orbit(PI, 0.1)
		"under":
			_studio.set_orbit(0.35, -1.15)
		"side":
			_studio.set_orbit(PI * 0.5, 0.1)
	_frame(false)


func set_cover_off(off: bool) -> void:
	_cover = not off
	if _cover_btn != null:
		_cover_btn.set_pressed_no_signal(off)
	if _builder != null:
		_builder.set_cover_visible(_cover)


func _frame(reset_orbit: bool) -> void:
	if _builder == null:
		return
	if reset_orbit:
		_studio.reset_orbit()
	var ab := CtrlDesign.bounds(_design)
	var c := ab.get_center() * CtrlBuilder.MM
	var r := ab.size.length() * 0.5 * CtrlBuilder.MM
	_studio.target = c
	_studio.dist = clampf(r * 3.3, StudioViewport.DIST_MIN, _studio.dist_max)
	_studio.update_camera()


# ---------------------------------------------------------------------------
# Solve and refresh
# ---------------------------------------------------------------------------

func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = CtrlSpec.resolve(_spec)
	_design = CtrlDesign.solve(_spec)
	if _builder != null:
		_builder.queue_free()
		_builder = null
	_sel_box = null
	_builder = CtrlBuilder.build_from_design(_design)
	_builder.name = "Unit"
	_studio.holder.add_child(_builder)
	_builder.set_cover_visible(_cover)
	if _selected != "" and _port_index(_selected) < 0:
		_selected = ""
	_sync_rows()
	_sync_port_list()
	_sync_port_card()
	_update_sel_box()
	_refresh_checks()
	_refresh_tiles()
	if _mode == "terminals":
		_refresh_sheet()
	var b: Dictionary = _spec["body"]
	var shape := "%s|%.0f|%.0f|%.0f" % [_spec.get("id", _spec["name"]), float(b["w"]), float(b["h"]), float(b["d"])]
	if shape != _framed_key:
		_framed_key = shape
		_frame(false)


func _sync_rows() -> void:
	for path in _rows:
		var row: FormRow = _rows[path]
		if not (row.control is LineEdit and row.control.has_focus()):
			row.set_value(get_path_value(_spec, str(path)))
		var dep := str(SHOW_IF.get(path, ""))
		row.visible = dep == "" or bool(get_path_value(_spec, dep))
	for path2 in _picks:
		var pr: FormRow = _picks[path2]
		(pr.control as ColorPickerButton).color = CtrlSpec.color_of(get_path_value(_spec, str(path2)), Color.GRAY)
	_shell.name_edit.text = str(_spec["name"])
	_shell.set_subtitle(CtrlPresets.size_line(_spec))
	_sync_texts()


func _sync_texts() -> void:
	var texts: Array = _spec["texts"]
	var sig := str(texts.size())
	if _texts_box.get_meta("sig", "") == sig:
		for i in texts.size():
			var le := _texts_box.get_child(i).get("control") as LineEdit
			if le != null and not le.has_focus():
				le.text = str(texts[i].get("text", ""))
		return
	_texts_box.set_meta("sig", sig)
	for c in _texts_box.get_children():
		_texts_box.remove_child(c)
		c.queue_free()
	for i in texts.size():
		var t: Dictionary = texts[i]
		var row := FormRow.text_edit("Text %d" % (i + 1), "", func(v: Variant) -> void:
			_push_undo("text%d" % i)
			(_spec["texts"][i] as Dictionary)["text"] = str(v)
			_rebuild_timer = REBUILD_DELAY, "Printed on the %s" % str(t.get("face", "front")), "text_%d" % i)
		(row.control as LineEdit).text = str(t.get("text", ""))
		_texts_box.add_child(row)


func _sync_port_list() -> void:
	var ps: Array = _spec["ports"]
	var sig := ""
	for p in ps:
		sig += "%s|%s|%s|%s;" % [p["id"], p["connector"], p["label"], p["group"]]
	sig += "#" + _selected
	if sig == _port_sig:
		return
	_port_sig = sig
	for c in _ports_box.get_children():
		_ports_box.remove_child(c)
		c.queue_free()
	if ps.is_empty():
		_ports_box.add_child(EmptyState.row("plus", "No ports yet: Add port, then click the unit."))
		return
	for p in ps:
		var b := Button.new()
		b.name = "port_" + str(p["id"])
		var lab := str(p["label"]) if str(p["label"]) != "" else ConnectorCatalog.label(str(p["connector"]))
		b.text = "%s  ·  %s" % [lab, _port_job(p)]
		b.tooltip_text = I18n.f("{connector} on the {face}", {"connector": ConnectorCatalog.label(str(p["connector"])), "face": str(p["face"])})
		b.toggle_mode = true
		b.button_pressed = str(p["id"]) == _selected
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		UITheme.style_button(b)
		var col: Color = ConnectorCatalog.DOMAIN_COLORS.get(str(ConnectorCatalog.entry(str(p["connector"])).get("domain", "")), Color.GRAY)
		b.add_theme_color_override("font_color", col.lerp(UITheme.C_TEXT, 0.45))
		b.pressed.connect(select_port.bind(str(p["id"])))
		_ports_box.add_child(b)


## What a port is for, in a few words: its group, else its pins' own roles
## (a terminal strip of L1 L2 N), else what it is (a gland, a knockout).
func _port_job(p: Dictionary) -> String:
	var g := str(p.get("group", ""))
	if g != "":
		return str(CtrlRoles.GROUPS.get(g, g))
	var groups: Array = []
	for r in (p.get("roles", []) as Array):
		var rg := CtrlRoles.group_of(str(r))
		if str(r) != "" and not groups.has(rg):
			groups.append(rg)
	if not groups.is_empty():
		return ", ".join(groups.map(func(x): return str(CtrlRoles.GROUPS.get(x, x))))
	var dom := str(ConnectorCatalog.entry(str(p["connector"])).get("domain", ""))
	match dom:
		"fitting":
			return "Cable entry"
		"protection":
			return "Protection"
		"ui":
			return "Front panel"
	return "Unassigned"


func _sync_port_card() -> void:
	var p := port_spec(_selected)
	_port_card.visible = not p.is_empty()
	if p.is_empty():
		return
	var conn := str(p["connector"])
	var e := ConnectorCatalog.entry(conn)
	(_port_rows["title"] as Label).text = "%s on the %s" % [ConnectorCatalog.label(conn), str(p["face"])]
	(_port_rows["connector"] as FormRow).set_value(conn)
	var le := (_port_rows["label"] as FormRow).control as LineEdit
	if not le.has_focus():
		le.text = str(p.get("label", ""))
	(_port_rows["group"] as FormRow).set_value(str(p.get("group", "")))
	var opts: Dictionary = p.get("opts", {}) as Dictionary
	var single := (e.get("pins", []) as Array).size() == 1
	(_port_rows["polarity"] as FormRow).visible = single
	(_port_rows["polarity"] as FormRow).set_value(str(opts.get("polarity", "")))
	var multi := MULTI_POLE.has(conn)
	(_port_rows["poles"] as FormRow).visible = multi
	var res := ConnectorCatalog.resolve(conn, opts)
	(_port_rows["poles"] as FormRow).set_value(int(opts.get("poles", (res.get("pins", []) as Array).size())))
	(_port_rows["face"] as FormRow).set_value(str(p["face"]))
	for k in ["u", "v", "rot", "dz"]:
		(_port_rows[k] as FormRow).set_value(float(p.get(k, 0.0)))
	var lines: Array = []
	for dp in (_design["ports"] as Array):
		if str(dp["id"]) != _selected:
			continue
		for pin in (dp["pins"] as Array):
			lines.append("%s → %s" % [str(pin["label"]) if str(pin["label"]) != "" else str(pin["id"]),
				CtrlRoles.words(str(pin["role"]))])
	(_port_rows["pins"] as Label).text = "Pins: " + "; ".join(lines) if not lines.is_empty() else ""


func _update_sel_box() -> void:
	if _builder == null:
		return
	if _sel_box != null and is_instance_valid(_sel_box):
		_sel_box.queue_free()
	_sel_box = null
	if _selected == "":
		return
	var pt := _builder.part(_selected)
	if pt.is_empty():
		return
	var ab: AABB = pt["aabb"]
	ab = ab.grow(0.002)
	_sel_box = MeshInstance3D.new()
	_sel_box.name = "Selected"
	_sel_box.set_meta("studio_no_frame", true)
	var bm := BoxMesh.new()
	bm.size = ab.size
	_sel_box.mesh = bm
	_sel_box.position = ab.get_center()
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1.0, 0.78, 0.2, 0.28)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_sel_box.material_override = m
	_builder.add_child(_sel_box)


func _refresh_checks() -> void:
	for c in _checks_box.get_children():
		_checks_box.remove_child(c)
		c.queue_free()
	var checks: Array = _design["checks"]
	var errs := 0
	var warns := 0
	for c in checks:
		var lvl := str(c["level"])
		if lvl == "error":
			errs += 1
		elif lvl == "warn":
			warns += 1
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var lbl := Label.new()
		lbl.text = str(c["text"])
		lbl.tooltip_text = str(c.get("why", ""))
		lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		lbl.add_theme_color_override("font_color",
			UITheme.C_ERROR if lvl == "error" else (UITheme.C_WARN if lvl == "warn" else UITheme.C_TEXT_S))
		row.add_child(lbl)
		var ids: Array = c.get("ids", [])
		if not ids.is_empty() and _port_index(str(ids[0])) >= 0:
			var show := Button.new()
			show.text = "Show it"
			UITheme.style_button(show)
			show.pressed.connect(select_port.bind(str(ids[0])))
			row.add_child(show)
		_checks_box.add_child(row)
	if checks.is_empty():
		var ok := Label.new()
		ok.text = "Every check passes."
		ok.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		ok.add_theme_color_override("font_color", UITheme.C_OK)
		_checks_box.add_child(ok)
	if errs > 0:
		_shell.set_badge(UiText.count(errs, "problem") + " to fix", "error")
	elif warns > 0:
		_shell.set_badge(UiText.count(warns, "warning"), "warn")
	else:
		_shell.set_badge("Checks pass", "ok")


func _refresh_tiles() -> void:
	if _col == null:
		return
	var e: Dictionary = _spec["elec"]
	var b: Dictionary = _spec["body"]
	var tiles: Array = []
	tiles.append({"caption": "Size (mm)", "value": "%.0f × %.0f" % [float(b["w"]), float(b["h"])],
		"tip": "Width × height; %.0f mm deep" % float(b["d"])})
	if float(e["max_voc"]) > 0.0 and int(e["mppt_count"]) > 0:
		tiles.append({"caption": "PV max", "value": "%s V" % _num(float(e["max_voc"])),
			"tip": UiText.count(int(e["mppt_count"]), "MPPT input")})
	if float(e["ac_out_w"]) > 0.0:
		tiles.append({"caption": "AC out", "value": UiText.num(float(e["ac_out_w"]), "W"),
			"tip": "%s V%s" % [_num(float(e["ac_v"])), " split phase" if bool(e["split_phase"]) else ""]})
	tiles.append({"caption": "Charge", "value": "%s A" % _num(float(e["max_charge_a"])),
		"tip": "Into a %d V battery" % int(e["system_v"])})
	tiles.append({"caption": "Ports", "value": str((_spec["ports"] as Array).size()),
		"tip": UiText.count((_design["roles"] as Dictionary).size(), "wiring role")})
	_col.set_tiles(tiles)


func _status(t: String) -> void:
	if _status_lbl != null:
		_status_lbl.text = t


static func _num(v: float) -> String:
	return str(int(round(v))) if absf(v - round(v)) < 0.05 else "%.1f" % v


func summary() -> String:
	var lines: Array = ["%s · %s" % [_spec["name"], CtrlPresets.size_line(_spec)]]
	var e: Dictionary = _spec["elec"]
	lines.append("Kind: %s" % CtrlSpec.KIND_WORDS.get(str(e["kind"]), str(e["kind"])))
	for k in ["system_v", "max_voc", "mppt_count", "mppt_min_v", "mppt_max_v", "max_input_a", "max_pv_w",
			"max_charge_a", "ac_out_w", "surge_w", "ac_in_a", "idle_w"]:
		if float(e.get(k, 0.0)) != 0.0:
			lines.append("  %s: %s" % [k, str(e[k])])
	lines.append("Ports:")
	for p in (_design["ports"] as Array):
		lines.append("  " + _port_words(str(p["id"])) + " (" + str(p["face"]) + ")")
	lines.append("Graph handles: " + ", ".join(_design["handles"]))
	for c in (_design["checks"] as Array):
		lines.append("%s: %s" % [str(c["level"]).to_upper(), c["text"]])
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# Designs
# ---------------------------------------------------------------------------

func _thumb_for(i: int) -> Dictionary:
	if i < 0 or i >= _entries.size():
		return {}
	var s: Dictionary = CtrlSpec.resolve(((_entries[i] as Dictionary)["spec"] as Dictionary).duplicate(true))
	return {"key": CtrlSpec.key_of(s), "build": func() -> Node3D:
		return CtrlBuilder.build_node(s, "Thumb")}


func _refresh_design_list() -> void:
	_gallery.clear()
	_entries.clear()
	var by_form := {}
	for s in CtrlPresets.builtins():
		var f := str(s["form"])
		if not by_form.has(f):
			by_form[f] = []
		(by_form[f] as Array).append(s)
	for f2 in CtrlSpec.FORMS:
		if not by_form.has(f2):
			continue
		_gallery.add_caption(str(CtrlSpec.FORM_WORDS[f2]))
		for s2 in (by_form[f2] as Array):
			_gallery.add_item(str(s2["name"]))
			_gallery.set_item_subtitle(_gallery.item_count - 1, CtrlPresets.size_line(s2))
			_entries.append({"spec": s2, "builtin": true, "id": str(s2["id"])})
	var lib := CtrlPresets.load_library()
	for id in lib.keys():
		var s3: Dictionary = lib[id]
		_gallery.add_item("★ " + str(s3.get("name", id)))
		_gallery.set_item_subtitle(_gallery.item_count - 1, CtrlPresets.size_line(s3))
		_entries.append({"spec": s3, "builtin": false, "id": str(id)})


func _on_design_activated(idx: int) -> void:
	if idx < 0 or idx >= _entries.size():
		return
	set_spec(((_entries[idx] as Dictionary)["spec"] as Dictionary).duplicate(true))


func _on_save_design() -> void:
	var nm := str(_spec["name"])
	var id := "cl_" + nm.to_lower().replace(" ", "_").left(40)
	if CtrlPresets.save_to_library(id, _spec):
		_refresh_design_list()
		_status("Saved “%s” to your library." % nm)
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
	CtrlPresets.forget(str(e["id"]))
	_refresh_design_list()
	_status("Forgotten.")


# ---------------------------------------------------------------------------
# The graph and the world (Phase 4)
# ---------------------------------------------------------------------------

func _main() -> Node:
	var t := get_tree()
	return t.current_scene if t != null else null


func bound_prop() -> String:
	return _bound_prop_id


func bound_graph_item() -> String:
	return _bound_graph_id


static func _graph_model() -> Variant:
	var gv := ServiceLocator.graph()
	return gv.get("model") if gv != null else null


## A graph controller's design: its own, else the built-in it was placed
## from (`controller_preset`, or its name in the library), else a generic
## MPPT carrying its numbers.
func _spec_from_graph(gid: String) -> Dictionary:
	var model: Variant = _graph_model()
	if model == null:
		return {}
	var it: Dictionary = model.call("get_item", gid)
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	if sp.get("controller_spec") is Dictionary:
		return (sp["controller_spec"] as Dictionary).duplicate(true)
	if str(sp.get("controller_preset", "")) != "":
		var pre := CtrlPresets.builtin(str(sp["controller_preset"]))
		if not pre.is_empty():
			return pre
	for nm in [str(it.get("label", "")), str(sp.get("name", ""))]:
		var lib := CtrlPresets.for_library_label(nm)
		if lib.is_empty():
			lib = CtrlPresets.for_name(nm)
		if not lib.is_empty():
			return lib
	var g := CtrlPresets.builtin("generic_mppt_150_50")
	g["name"] = str(sp.get("name", "Controller"))
	var e: Dictionary = g["elec"]
	e["max_voc"] = float(sp.get("max_voc", e["max_voc"]))
	e["max_charge_a"] = float(sp.get("max_charge_amps", e["max_charge_a"]))
	e["max_pv_w"] = float(sp.get("max_pv_watts", e["max_pv_w"]))
	g.erase("id")
	return g


## Write the design back: a placed unit (its record, then its graph
## controller follows), else the graph controller (its numbers, the design
## and its terminals as handles; wires on a terminal the design no longer
## has are reported).
func apply() -> void:
	var main := _main()
	if not _bound_prop_id.is_empty() and main != null:
		PlacedPropService.update_prop_record(main, _bound_prop_id, {"controller_spec": _spec.duplicate(true)}, true)
		var gid := PlacedPropService.seed_controller(main, _bound_prop_id)
		_bound_graph_id = gid
		_status("Applied to the placed unit: its graph controller follows.")
		_refresh_chain()
		return
	if _bound_graph_id.is_empty():
		_status("Open the Lab from a graph controller or a placed unit to apply to it.")
		return
	var model: Variant = _graph_model()
	if model == null or (model.call("get_item", _bound_graph_id) as Dictionary).is_empty():
		_status("The graph controller is gone.")
		return
	var it: Dictionary = model.call("get_item", _bound_graph_id)
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	var g := CtrlDesign.graph_specs(_design)
	for k in g:
		specs[k] = g[k]
	specs["controller_spec"] = _spec.duplicate(true)
	var handles := CtrlDesign.graph_handles(_design)
	model.call("update_item", _bound_graph_id, {"specs": specs, "handles": handles})
	var ids := {}
	for h in handles:
		ids[str(h["id"])] = true
	var lost := 0
	for c: Dictionary in (model.get("connections") as Array):
		if str(c.get("source_item_id", "")) == _bound_graph_id and not ids.has(str(c.get("source_handle_id", ""))):
			lost += 1
		elif str(c.get("target_item_id", "")) == _bound_graph_id and not ids.has(str(c.get("target_handle_id", ""))):
			lost += 1
	_status("Applied to the graph controller: %s.%s" % [UiText.count(handles.size(), "terminal"),
		(" %s on terminals it no longer has." % UiText.count(lost, "wire")) if lost > 0 else ""])
	_refresh_chain()


# ---------------------------------------------------------------------------
# The power chain (Panels › Controller › Battery)
# ---------------------------------------------------------------------------

func chain_bar() -> PowerChainBar:
	return _chain


## The graph controller this Lab is on ("" = none).
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
		apply()
	close()
	PowerChainBar.go(main, kind, unit, ch)


func _on_chain_add(what: String) -> void:
	if what == "panels":
		_on_chain_hop("panels", {})
		return
	var model: Variant = _graph_model()
	if model == null:
		return
	var nid := PowerChain.add_missing(model as GraphModel, _chain.chain(), what)
	_status("Added %s to the graph, wired to this controller." % ("a battery bank" if what == "battery" else "a controller") if nid != "" else "Could not add it.")
	_refresh_chain()


## Stand this unit in the world. Opened from a graph controller, the placed
## unit takes that controller over.
func place_in_world() -> void:
	var main := _main()
	if main == null or not main.has_method("get_node"):
		_status("Placing needs a world.")
		return
	var extra := {"controller_spec": _spec.duplicate(true), "collision_enabled": true}
	if not _bound_graph_id.is_empty():
		extra["graph_item_id"] = _bound_graph_id
	var r: Dictionary = PlacedPropService.begin_placement(main, CtrlBuilder.MODEL_ID, {"record_extra": extra})
	if not bool(r.get("ok", true)):
		_status(str(r.get("error", "Could not start placing.")))
		return
	close()
