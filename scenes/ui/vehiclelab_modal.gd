extends Control

## The living-vehicle designer (core/vehiclelab/): pick a type, a chassis and
## a body independently, size the body, paint it (or lay a wrap image over
## it), drag roof / side / rear items onto the preview — fans, an AC unit, a
## Starlink dish, solar panels, an awning, a ladder … — and place it in the
## world or apply it to the vehicle it was opened on. Hosted on its own
## CanvasLayer by TerrainLoader (open_vehiclelab / open_vehiclelab_for_prop),
## on DesignerShell + StudioViewport + FormRow like the dome designer.
##
## Clicks in the preview: with a tool armed (the "Roof & sides" palette) a
## cyan ghost follows the pointer over the faces the item may go on and a
## left click puts it there (Shift keeps the tool; Esc disarms). With no tool
## a left press on an item selects it and a drag slides it over the body —
## onto another face too, where it may go. Delete removes it. A drag on
## empty space orbits, as everywhere.

const MODAL_NAME := "vehiclelab_designer"
const WANT := Vector2(1600, 960)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.12
const DRAG_REBUILD_S := 0.05
const MODEL_DIR := "user://vehicle_models"
## Shipped art the player can lay over the parametric body (when present).
const SHIPPED_ART := [
	["res://Imported Models/Busses.tscn", "Tool Bus art (International 3800)"],
	["res://Imported Models/GMC camper van.glb", "GMC camper van art"],
	["res://Imported Models/Mars Aerial/Motorhome/motorhome.glb", "Motorhome art"],
]
const C_GHOST := Color(0.2, 0.75, 1.0, 0.42)
const FUEL_WORDS := {"gasoline": "Gasoline", "diesel": "Diesel", "electric": "Electric (its pack)", "none": "None (towed)"}
const C_SELECT := Color(1.0, 0.72, 0.18, 0.45)

var _loader: Node = null
var _active := false
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _bound_prop_id := ""
var _undo: Array = []
var _redo: Array = []
var _coalesce_key := ""
var _coalesce_until := 0.0
var _rebuild_timer := -1.0
var _drag_timer := 0.0
var _suppress := false
var _cutaway := false
var _library: Array = []
var _design_entries: Array = []
var _tool: Dictionary = {}
var _ghost: Dictionary = {}
var _sel := ""
## What the selection is: "ext" (roof / sides) or "int" (inside).
var _sel_kind := ""
var _dragging := false
var _drag_moved := false
var _drag_press := Vector2.ZERO
## The roof height under the dragged item when the drag began: a roof item
## slides on that level plane (a ray aimed at an item standing on a crowned
## roof can pass over the roof altogether from a low camera).
var _drag_level := 0.0
var _drag_grab := Vector2.ZERO
var _item_sig := ""
var _vehicle_node: Node3D = null
var _marks: Node3D = null

var _shell: DesignerShell
var _name_edit: LineEdit
var _type_box: VBoxContainer
var _design_list: ItemList
var _studio: StudioViewport
var _cut_btn: Button
var _hover_lbl: Label
var _rows := {}
var _tool_box: HFlowContainer
var _item_box: VBoxContainer
var _in_tool_box: VBoxContainer
var _in_box: VBoxContainer
var _in_sig := ""
var _plan_btn: Button
var _wrap_opt: OptionButton
var _glb_opt: OptionButton
var _summary: Label
var _trip_lbl: Label
var _checks_box: VBoxContainer
var _apply_btn: Button
var _place_btn: Button
var _image_dialog: FileDialog
var _replace_dialog: ConfirmationDialog
var _units_gen := -1
var _model_dialog: FileDialog


func bind_loader(loader: Node) -> void:
	_loader = loader


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process(false)


# --- open / close -------------------------------------------------------------------

func open(spec: Dictionary = {}) -> void:
	if _active:
		return
	_bound_prop_id = ""
	_spec = VehicleSpec.resolve(spec if not spec.is_empty() else VehiclePresets.builtin("van"))
	_activate()


func open_for_prop(prop_id: String) -> void:
	if _active or prop_id.is_empty():
		return
	var rec := _prop_record(prop_id)
	_bound_prop_id = prop_id
	_spec = VehicleSpec.resolve(VehicleBuilder.spec_for_record(rec))
	_activate()


func is_open() -> bool:
	return _active


func _activate() -> void:
	_undo.clear()
	_redo.clear()
	_tool = {}
	_ghost = {}
	_sel = ""
	_sel_kind = ""
	_in_sig = ""
	_cutaway = false
	if _plan_btn != null:
		_plan_btn.set_pressed_no_signal(false)
	if _cut_btn != null:
		_cut_btn.set_pressed_no_signal(false)
	_library = VehiclePresets.load_library()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_shell.open()
	_apply_btn.visible = not _bound_prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _bound_prop_id.is_empty() else "Place in world"
	var can_place := _loader != null and _loader.has_method("begin_vehiclelab_placement")
	_place_btn.disabled = not can_place
	_place_btn.tooltip_text = "Place it near you, then click where it parks" if can_place \
		else "Placing needs a location map (this scene has no terrain)"
	_refresh_design_list()
	_refresh_wraps()
	_refresh_models()
	_rebuild_now()
	_frame_camera()


func close() -> void:
	if not _active:
		return
	_active = false
	_tool = {}
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_shell.close()


func _process(delta: float) -> void:
	if _rebuild_timer > 0.0:
		_rebuild_timer -= delta
		if _rebuild_timer <= 0.0:
			_rebuild_now()
	if _drag_timer > 0.0:
		_drag_timer -= delta


func _input(e: InputEvent) -> void:
	if not _active or not (e is InputEventKey):
		return
	var ke := e as InputEventKey
	if not ke.pressed or ke.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		return
	if ke.keycode == KEY_ESCAPE and not _tool.is_empty():
		_arm_tool({})
		get_viewport().set_input_as_handled()
	elif (ke.keycode == KEY_DELETE or ke.keycode == KEY_BACKSPACE) and not _sel.is_empty():
		_remove_selected()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_R and not ke.ctrl_pressed and _sel_kind == "int" and not _sel.is_empty():
		_turn_interior()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_Z and ke.ctrl_pressed and not ke.shift_pressed:
		_undo_step()
		get_viewport().set_input_as_handled()
	elif (ke.keycode == KEY_Y and ke.ctrl_pressed) or (ke.keycode == KEY_Z and ke.ctrl_pressed and ke.shift_pressed):
		_redo_step()
		get_viewport().set_input_as_handled()


# --- layout -------------------------------------------------------------------------

func _build_ui() -> void:
	_shell = DesignerShell.create("Vehicle designer", "truck", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true, "undo": true,
		"left_label": "Vehicle & designs", "left_w": 240.0, "right_w": 400.0})
	add_child(_shell)
	_name_edit = _shell.name_edit
	_shell.undo_requested.connect(_undo_step)
	_shell.redo_requested.connect(_redo_step)
	_shell.name_submitted.connect(func(t: String) -> void: _edit(["name"], t))
	_shell.closed.connect(close)
	_build_left()
	_build_centre()
	_build_right()
	_shell.set_hint("Drag to orbit · wheel to zoom · arm an item, then click the roof, a side or (cutaway) the floor · drag an item to move it · R turns an inside item · Del removes · Esc disarms")
	_shell.add_button("Save design", DesignerShell.SECONDARY, _on_save_design,
		"Keep this vehicle in your library (every world)")
	_place_btn = _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place)
	_apply_btn = _shell.add_button("Apply to placed vehicle", DesignerShell.SECONDARY, _on_apply)
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	if _shell.undo_btn != null:
		_shell.undo_btn.tooltip_text = "Undo (Ctrl+Z)"
	if _shell.redo_btn != null:
		_shell.redo_btn.tooltip_text = "Redo (Ctrl+Y)"
	_replace_dialog = ConfirmationDialog.new()
	_replace_dialog.title = "Replace a saved design?"
	_replace_dialog.ok_button_text = "Replace"
	_replace_dialog.confirmed.connect(func() -> void: _save_design(true))
	add_child(_replace_dialog)
	_image_dialog = _file_dialog("Choose a wrap image", PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"]),
		_on_wrap_file)
	_model_dialog = _file_dialog("Choose your vehicle's model", PackedStringArray(["*.glb, *.gltf ; glTF models"]),
		_on_model_file)


func _file_dialog(title: String, filters: PackedStringArray, cb: Callable) -> FileDialog:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.title = title
	fd.filters = filters
	fd.file_selected.connect(cb)
	add_child(fd)
	return fd


func _build_left() -> void:
	var box := _shell.left
	box.add_child(SectionHeader.make("Type", "truck"))
	_type_box = VBoxContainer.new()
	_type_box.add_theme_constant_override("separation", 2)
	box.add_child(_type_box)
	for t in VehicleCatalog.TYPE_ORDER:
		var b := Button.new()
		b.text = str(VehicleCatalog.type_info(t)["label"])
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 28)
		b.name = "type_%s" % t
		b.set_meta("type", t)
		b.tooltip_text = "Start over from the built-in %s (Ctrl+Z undoes)" % str(VehicleCatalog.type_info(t)["label"]).to_lower()
		b.pressed.connect(_on_type_pressed.bind(t))
		_type_box.add_child(b)
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_design_list = ItemList.new()
	_design_list.custom_minimum_size = Vector2(0, 200)
	_design_list.auto_height = true
	_design_list.item_selected.connect(_on_design_selected)
	box.add_child(_design_list)
	var lib := HBoxContainer.new()
	for spec_btn in [["Forget", "Remove the selected saved design (built-ins stay)", _on_forget_design]]:
		var b2 := Button.new()
		b2.text = str(spec_btn[0])
		b2.tooltip_text = str(spec_btn[1])
		UITheme.style_button(b2)
		b2.pressed.connect(spec_btn[2])
		lib.add_child(b2)
	box.add_child(lib)


func _build_centre() -> void:
	_studio = StudioViewport.create({"ground": true, "person": true})
	_studio.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_studio.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio.set_home(0.9, 0.3)
	_studio.input_hook = _studio_input
	_studio.clicked.connect(_on_studio_click)
	_studio.hovered.connect(_on_studio_hover)
	_shell.centre.add_child(_studio)
	var bar := _studio.strip
	_cut_btn = Button.new()
	_cut_btn.text = "Cutaway"
	_cut_btn.toggle_mode = true
	_cut_btn.tooltip_text = "Hide the body's skin and look at the inside"
	UITheme.style_button(_cut_btn)
	_cut_btn.toggled.connect(func(on: bool) -> void:
		_cutaway = on
		_rebuild_studio())
	bar.add_child(_cut_btn)
	_plan_btn = Button.new()
	_plan_btn.text = "Plan"
	_plan_btn.toggle_mode = true
	_plan_btn.tooltip_text = "Look straight down into the vehicle, skin off"
	UITheme.style_button(_plan_btn)
	_plan_btn.toggled.connect(set_plan_view)
	bar.add_child(_plan_btn)
	bar.add_child(IconButton.make("scan", "Frame the vehicle", func() -> void:
		_studio.reset_orbit()
		_frame_camera()))
	_hover_lbl = Label.new()
	_hover_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hover_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hover_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hover_lbl.clip_text = true
	_hover_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(_hover_lbl)


func _section(title: String, open: bool) -> VBoxContainer:
	var sec := Collapsible.make(title, open)
	_shell.right.add_child(sec)
	return sec.body


func _build_right() -> void:
	# What it is and what is wrong with it, first: the checks used to sit two
	# screens down. The header's badge counts them and scrolls here.
	_shell.right.add_child(SectionHeader.make("This vehicle", "info"))
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_shell.right.add_child(_summary)
	_checks_box = VBoxContainer.new()
	_shell.right.add_child(_checks_box)
	# Chassis & body.
	var cb := _section("Chassis & body", true)
	_add_row(cb, "chassis", FormRow.option("Chassis", [], func(v): _on_chassis(str(v)),
		"What is under it: the cab, axles, tyres and fuel", "vl_chassis"))
	_add_row(cb, "body", FormRow.option("Body", [], func(v): _on_body(str(v)),
		"The box people live in, picked on its own", "vl_body"))
	_add_row(cb, "fuel", FormRow.value("Fuel", "",
		"Set by the chassis: pick another chassis for another fuel (an electric chassis carries its pack)", "vl_fuel"))
	_add_row(cb, "wheelbase_m", FormRow.option("Wheelbase", [], func(v): _edit(["chassis", "wheelbase_m"], float(v)),
		"Front axle to rear axle, in the wheelbases this chassis is sold in", "vl_wheelbase"))
	_add_row(cb, "dually", FormRow.check("Rear wheels", "Dual (dually)",
		func(on): _edit(["chassis", "dually"], on), "", "vl_dually"))
	_add_row(cb, "tank_l", FormRow.spin("Fuel tank", 0.0, 800.0, 1.0, " L",
		func(v): _edit(["chassis", "tank_l"], v), "", "vl_tank"))
	_add_row(cb, "battery_kwh", FormRow.spin("Traction battery", 0.0, 300.0, 1.0, " kWh",
		func(v): _edit(["chassis", "battery_kwh"], v), "An electric chassis' pack", "vl_battery"))
	# Body size.
	var sb := _section("Body size", true)
	_add_row(sb, "length_m", FormRow.spin("Length", 1.5, 14.0, 0.05, " m",
		func(v): _edit(["body", "length_m"], v), "The box (or the whole van shell)", "vl_length"))
	_add_row(sb, "width_m", FormRow.spin("Width", 1.4, 2.6, 0.01, " m",
		func(v): _edit(["body", "width_m"], v), "", "vl_width"))
	_add_row(sb, "height_m", FormRow.spin("Roof height", 2.0, 4.2, 0.01, " m",
		func(v): _edit(["body", "height_m"], v), "The roof above the ground", "vl_height"))
	_add_row(sb, "floor_h_m", FormRow.spin("Floor height", 0.15, 1.4, 0.01, " m",
		func(v): _edit(["body", "floor_h_m"], v), "The inside floor above the ground", "vl_floor"))
	_add_row(sb, "roof", FormRow.option("Roof", [["flat", "Flat"], ["crown", "Crowned"],
		["high_top", "High top"], ["arched", "Arched (bus)"], ["cabover", "Cab-over (Class C)"]],
		func(v): _edit(["body", "roof"], str(v)), "The roof's shape (a cab-over reaches over the cab for a bed)", "vl_roof"))
	_add_row(sb, "corner_r_m", FormRow.spin("Roof corners", 0.0, 0.4, 0.01, " m",
		func(v): _edit(["body", "corner_r_m"], v), "How round the roof's edges are", "vl_corner"))
	_add_row(sb, "windows", FormRow.option("Windows", [["none", "None"], ["few", "A few"],
		["band", "A band"], ["bus", "Bus row"]], func(v): _edit(["body", "windows"], str(v)),
		"A few = a pane over each bed, dinette and sofa; a band runs the length; a bus row is the bus's own", "vl_windows"))
	_add_row(sb, "side_door", FormRow.option("Side door", [["none", "None"], ["hinged", "Hinged"],
		["slider", "Slider"], ["bus", "Bus door"], ["sliding_step", "Step-van slider"]],
		func(v): _edit(["body", "side_door"], str(v)), "The curb-side door: how people (and cargo) get in", "vl_side_door"))
	_add_row(sb, "rear_door", FormRow.option("Rear door", [["none", "None"], ["barn", "Barn doors"],
		["roll_up", "Roll-up"], ["lift", "Lift gate"]], func(v): _edit(["body", "rear_door"], str(v)),
		"The rear door: a cargo bay loads through it when there is one", "vl_rear_door"))
	# Paint.
	var pb := _section("Paint", false)
	for key in [["body", "Body"], ["roof", "Roof"], ["trim", "Trim"], ["wheels", "Wheels"], ["stripe", "Stripe"]]:
		var k := str(key[0])
		var picker := ColorPickerButton.new()
		picker.edit_alpha = false
		picker.custom_minimum_size = Vector2(0, 24)
		picker.color_changed.connect(func(c: Color) -> void: _edit(["paint", k], [c.r, c.g, c.b], "paint." + k))
		_add_row(pb, "paint_" + k, FormRow.make(str(key[1]), picker, "The %s colour" % str(key[1]).to_lower(), "", "vl_paint_" + k))
	_add_row(pb, "stripe_on", FormRow.check("Stripe", "Down both sides",
		func(on): _edit(["paint", "stripe_on"], on), "", "vl_stripe_on"))
	_wrap_opt = OptionButton.new()
	_wrap_opt.item_selected.connect(func(i: int) -> void:
		_edit(["paint", "wrap"], str(_wrap_opt.get_item_metadata(i))))
	_add_row(pb, "wrap", FormRow.make("Wrap image", _wrap_opt,
		"An image stretched along each side over the paint (files in %s)" % VehicleBuilder.WRAP_DIR, "", "vl_wrap"))
	var wb := HBoxContainer.new()
	for spec_btn in [["Add image…", "Copy an image into your wraps and use it", func() -> void: _image_dialog.popup_centered()],
			["Open folder", "Show the wraps folder in your file browser (%s)" % VehicleBuilder.WRAP_DIR,
				func() -> void: _open_folder(VehicleBuilder.WRAP_DIR)]]:
		var b := Button.new()
		b.text = str(spec_btn[0])
		b.tooltip_text = str(spec_btn[1])
		UITheme.style_button(b)
		b.pressed.connect(spec_btn[2])
		wb.add_child(b)
	pb.add_child(wb)
	# Roof & sides.
	var xb := _section("Roof & sides", true)
	var hint := Label.new()
	hint.text = "Arm an item, then click where it goes on the preview."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	xb.add_child(hint)
	_tool_box = HFlowContainer.new()
	xb.add_child(_tool_box)
	_tool_box.visible = false
	var by_id := {}
	for preset in VehicleExterior.TOOL_PRESETS:
		by_id[str((preset as Dictionary)["id"])] = preset
	for grp in VehicleExterior.TOOL_GROUPS:
		var gl2 := Label.new()
		gl2.text = str(grp[0])
		gl2.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		gl2.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		xb.add_child(gl2)
		var flow2 := HFlowContainer.new()
		flow2.add_theme_constant_override("h_separation", UITheme.SPACE_XS)
		flow2.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
		xb.add_child(flow2)
		for pid in grp[1]:
			if not by_id.has(pid):
				continue
			var pd: Dictionary = by_id[pid]
			var t := VehicleExterior.type_info(str((pd["element"] as Dictionary)["type"]))
			var b3 := Button.new()
			b3.text = str(pd.get("label", t["label"]))
			b3.tooltip_text = "%s\nShift-click to place several · Esc stops" % str(t.get("tip", ""))
			b3.toggle_mode = true
			b3.name = "tool_%s" % str(pd["id"])
			UITheme.style_button(b3)
			b3.pressed.connect(func() -> void: _arm_tool(pd if _tool.get("id", "") != pd["id"] else {}))
			flow2.add_child(b3)
	_item_box = VBoxContainer.new()
	_item_box.add_theme_constant_override("separation", 2)
	xb.add_child(_item_box)
	# Inside.
	var ib := _section("Inside", true)
	var ihint := Label.new()
	ihint.text = "Arm a piece, then click the floor (the skin comes off). Drag to move, R turns it. Everything needs a 50 cm way in from a door."
	ihint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ihint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	ihint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	ib.add_child(ihint)
	_in_tool_box = VBoxContainer.new()
	_in_tool_box.add_theme_constant_override("separation", 2)
	ib.add_child(_in_tool_box)
	var groups := {}
	for tool in VehicleInterior.tools():
		var td: Dictionary = tool
		var g := str(td["group"])
		if not groups.has(g):
			var gl := Label.new()
			gl.text = g
			gl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
			gl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			_in_tool_box.add_child(gl)
			var flow := HFlowContainer.new()
			flow.add_theme_constant_override("h_separation", UITheme.SPACE_XS)
			flow.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
			_in_tool_box.add_child(flow)
			groups[g] = flow
		var preset := td.duplicate(true)
		preset["kind"] = "interior"
		preset["id"] = "in_" + str(td["id"])
		var b4 := Button.new()
		b4.text = str(td["label"])
		b4.tooltip_text = "%s\nShift-click to place several · R turns it · Esc stops" % str(td.get("tip", ""))
		b4.toggle_mode = true
		b4.name = "tool_%s" % str(preset["id"])
		UITheme.style_button(b4)
		b4.pressed.connect(func() -> void: _arm_tool(preset if _tool.get("id", "") != preset["id"] else {}))
		(groups[g] as HFlowContainer).add_child(b4)
	_in_box = VBoxContainer.new()
	_in_box.add_theme_constant_override("separation", 2)
	ib.add_child(_in_box)
	# The player's own model.
	var mb := _section("Your vehicle's model", false)
	var note := Label.new()
	note.text = "Lay a model of your real vehicle over this one: it is stretched onto the design's size. The inside, the roof items and the beds stay the design's."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	mb.add_child(note)
	_glb_opt = OptionButton.new()
	_glb_opt.item_selected.connect(func(i: int) -> void: _set_glb("path", str(_glb_opt.get_item_metadata(i))))
	_add_row(mb, "glb", FormRow.make("Model", _glb_opt, "", "", "vl_glb"))
	_add_row(mb, "glb_mode", FormRow.option("Replaces", [["whole", "The whole vehicle"], ["body", "Cab and body (keep the wheels)"]],
		func(v): _set_glb("mode", str(v)), "", "vl_glb_mode"))
	_add_row(mb, "glb_flip", FormRow.check("Facing", "Turn it round",
		func(on): _set_glb("flip", on), "If the model drives backwards", "vl_glb_flip"))
	var add_model := Button.new()
	add_model.text = "Add a model…"
	add_model.tooltip_text = "Copy a .glb / .gltf into %s and use it" % MODEL_DIR
	UITheme.style_button(add_model)
	add_model.pressed.connect(func() -> void: _model_dialog.popup_centered())
	mb.add_child(add_model)
	# The trip.
	var tb := _section("The trip to site", true)
	_add_row(tb, "units", FormRow.check("Units", "Kilometres and litres",
		func(on): _set_metric(on), "Shared with the ride dashboard", "vl_units"))
	_add_row(tb, "one_way_mi", FormRow.spin("One way", 0.0, 8000.0, 1.0, " mi",
		func(v): _edit(["trip", "one_way_mi"], UnitsPref.shown_to_mi(v)), "How far it drives to get to the site", "vl_trip_mi"))
	_add_row(tb, "fuel_price", FormRow.spin("Fuel price", 0.0, 20.0, 0.01, " $/gal",
		func(v): _edit(["trip", "fuel_price_per_gal"], UnitsPref.shown_to_price(v)), "", "vl_fuel_price"))
	_add_row(tb, "kwh_price", FormRow.spin("Charging", 0.0, 2.0, 0.01, " $/kWh",
		func(v): _edit(["trip", "kwh_price"], v), "", "vl_kwh_price"))
	_trip_lbl = Label.new()
	_trip_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trip_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	tb.add_child(_trip_lbl)


func _set_metric(on: bool) -> void:
	if _suppress:
		return
	UnitsPref.set_metric(on)
	_units_gen = UnitsPref.generation
	_sync_rows()
	_refresh_summary()


func _add_row(parent: Container, key: String, row: FormRow) -> void:
	parent.add_child(row)
	_rows[key] = row


# --- edits + undo -------------------------------------------------------------------

func _push_undo(key: String = "") -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not key.is_empty() and key == _coalesce_key and now < _coalesce_until:
		_coalesce_until = now + 0.8
		return
	_coalesce_key = key
	_coalesce_until = now + 0.8
	_undo.append(VehicleSpec.to_json_safe(_spec))
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()
	_update_undo_buttons()


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(VehicleSpec.to_json_safe(_spec))
	_spec = VehicleSpec.resolve(_undo.pop_back())
	_coalesce_key = ""
	_after_jump()


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(VehicleSpec.to_json_safe(_spec))
	_spec = VehicleSpec.resolve(_redo.pop_back())
	_coalesce_key = ""
	_after_jump()


func _after_jump() -> void:
	_ghost = {}
	if (_sel_kind == "int" and _in_index(_sel) < 0) or (_sel_kind != "int" and not _has_element(_sel)):
		_sel = ""
		_sel_kind = ""
	_rebuild_now()


func _update_undo_buttons() -> void:
	if _shell.undo_btn != null:
		_shell.undo_btn.disabled = _undo.is_empty()
	if _shell.redo_btn != null:
		_shell.redo_btn.disabled = _redo.is_empty()


## Write `value` at `path` in the spec ([group, key] or [key]) and rebuild.
func _edit(path: Array, value: Variant, coalesce: String = "") -> void:
	if _suppress or not _active:
		return
	_push_undo(coalesce if not coalesce.is_empty() else ".".join(PackedStringArray(path.map(func(x): return str(x)))))
	if path.size() == 1:
		_spec[str(path[0])] = value
	else:
		var g: Dictionary = _spec.get(str(path[0]), {})
		if not (g is Dictionary):
			g = {}
		g[str(path[1])] = value
		_spec[str(path[0])] = g
	_rebuild_timer = REBUILD_DELAY


func _on_type_pressed(t: String) -> void:
	if not _active:
		return
	_push_undo()
	var keep_trip: Dictionary = (_spec.get("trip", {}) as Dictionary).duplicate()
	_spec = VehicleSpec.resolve(VehiclePresets.builtin(t))
	_spec["trip"] = keep_trip
	_sel = ""
	_rebuild_now()
	_frame_camera()


func _on_chassis(id: String) -> void:
	if _suppress or id == str(_spec.get("chassis_id", "")):
		return
	_push_undo()
	_spec["chassis_id"] = id
	_spec["chassis"] = {}   # the old chassis' overrides do not carry over
	_rebuild_now()
	_frame_camera()


func _on_body(id: String) -> void:
	if _suppress or id == str(_spec.get("body_id", "")):
		return
	_push_undo()
	_spec["body_id"] = id
	_spec["body"] = {}
	_rebuild_now()
	_frame_camera()


func _set_glb(key: String, value: Variant) -> void:
	if _suppress:
		return
	var ov: Dictionary = (_spec.get("glb_override", {}) as Dictionary).duplicate()
	ov[key] = value
	if key == "path" and str(value).is_empty():
		ov = {}
	_edit(["glb_override"], ov)


# --- rebuild ------------------------------------------------------------------------

func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = VehicleSpec.resolve(_spec)
	_design = VehicleDesign.solve(_spec)
	_sync_rows()
	_rebuild_studio()
	_refresh_items()
	_refresh_summary()
	_update_undo_buttons()
	_shell.set_subtitle(VehicleSpec.describe(_spec).split(" — ")[1] if " — " in VehicleSpec.describe(_spec) else "")


func _sync_rows() -> void:
	_suppress = true
	if not _name_edit.has_focus():
		_name_edit.text = str(_spec.get("name", ""))
	var type := str(_spec["type"])
	for b in _type_box.get_children():
		(b as Button).set_pressed_no_signal(str(b.get_meta("type")) == type)
	# Chassis: the type's own first, then every other with a compatible cab.
	var ch_items: Array = []
	var ok: Array = VehicleCatalog.type_info(type).get("chassis_ok", [])
	for id in ok:
		ch_items.append([id, str(VehicleCatalog.chassis(id)["label"])])
	var trailer := str(VehicleCatalog.type_info(type)["chassis"]).begins_with("trailer")
	for id in VehicleCatalog.CHASSIS:
		if ok.has(id) or (str(id).begins_with("trailer") != trailer):
			continue
		ch_items.append([id, "%s · another type's" % str(VehicleCatalog.chassis(id)["label"])])
	_fill_option((_rows["chassis"] as FormRow).control as OptionButton, ch_items, str(_spec["chassis_id"]))
	var b_items: Array = []
	for id in VehicleCatalog.BODIES:
		b_items.append([id, str(VehicleCatalog.body(id)["label"])])
	_fill_option((_rows["body"] as FormRow).control as OptionButton, b_items, str(_spec["body_id"]))
	var ch: Dictionary = _spec["ch"]
	var bd: Dictionary = _spec["bd"]
	(_rows["fuel"] as FormRow).set_value(FUEL_WORDS.get(str(ch.get("fuel", "gasoline")), str(ch.get("fuel", ""))))
	(_rows["fuel"] as FormRow).visible = not trailer
	var wb_items: Array = []
	var wbs := VehicleCatalog.wheelbases_m(str(_spec["chassis_id"]))
	var wb_now := float(ch.get("wheelbase_m", 0.0))
	var have := false
	for w in wbs:
		have = have or absf(float(w) - wb_now) < 0.005
	if not have and wb_now > 0.0:
		wbs.append(wb_now)   # an older design's own number stays choosable
	for w in wbs:
		wb_items.append([float(w), "%.0f in (%.2f m)" % [float(w) / VehicleCatalog.IN, float(w)]])
	var wb_opt := (_rows["wheelbase_m"] as FormRow).control as OptionButton
	_fill_option(wb_opt, wb_items, str(wb_now))
	FormRow.select_meta(wb_opt, wb_now)
	wb_opt.disabled = wb_items.size() <= 1
	wb_opt.tooltip_text = "This chassis comes in one wheelbase" if wb_items.size() <= 1 else ""
	(_rows["wheelbase_m"] as FormRow).visible = not trailer
	(_rows["dually"] as FormRow).set_value(bool(ch.get("dually", false)))
	(_rows["tank_l"] as FormRow).set_value(float(ch.get("tank_l", 0.0)))
	(_rows["tank_l"] as FormRow).visible = str(ch.get("fuel", "")) in ["gasoline", "diesel"]
	(_rows["battery_kwh"] as FormRow).set_value(float(ch.get("battery_kwh", 0.0)))
	(_rows["battery_kwh"] as FormRow).visible = str(ch.get("fuel", "")) == "electric"
	for k in ["length_m", "width_m", "height_m", "floor_h_m", "corner_r_m"]:
		(_rows[k] as FormRow).set_value(float(bd.get(k, 0.0)))
	for k in ["roof", "windows", "side_door", "rear_door"]:
		(_rows[k] as FormRow).set_value(str(bd.get(k, "")))
	var paint: Dictionary = _spec["paint"]
	for k in ["body", "roof", "trim", "wheels", "stripe"]:
		var picker := (_rows["paint_" + k] as FormRow).control as ColorPickerButton
		picker.color = VehicleSpec.color(paint[k])
	(_rows["stripe_on"] as FormRow).set_value(bool(paint.get("stripe_on", false)))
	FormRow.select_meta(_wrap_opt, str(paint.get("wrap", "")))
	var ov: Dictionary = _spec.get("glb_override", {})
	FormRow.select_meta(_glb_opt, str(ov.get("path", "")))
	(_rows["glb_mode"] as FormRow).set_value(str(ov.get("mode", "whole")))
	(_rows["glb_flip"] as FormRow).set_value(bool(ov.get("flip", false)))
	var trip: Dictionary = _spec["trip"]
	_units_gen = UnitsPref.generation
	(_rows["units"] as FormRow).set_value(UnitsPref.metric())
	var mi_sb := (_rows["one_way_mi"] as FormRow).control as SpinBox
	mi_sb.suffix = " " + UnitsPref.dist_unit()
	(_rows["one_way_mi"] as FormRow).set_value(UnitsPref.mi_to_shown(float(trip.get("one_way_mi", 0.0))))
	var fp_sb := (_rows["fuel_price"] as FormRow).control as SpinBox
	fp_sb.suffix = " $/L" if UnitsPref.metric() else " $/gal"
	(_rows["fuel_price"] as FormRow).set_value(UnitsPref.price_to_shown(float(trip.get("fuel_price_per_gal", 4.5))))
	(_rows["kwh_price"] as FormRow).set_value(float(trip.get("kwh_price", 0.35)))
	_suppress = false


func _fill_option(o: OptionButton, items: Array, current: String) -> void:
	var sig := JSON.stringify(items)
	if str(o.get_meta("sig", "")) != sig:
		o.clear()
		for i in items.size():
			o.add_item(str(items[i][1]), i)
			o.set_item_metadata(i, items[i][0])
		o.set_meta("sig", sig)
	FormRow.select_meta(o, current)


func _rebuild_studio() -> void:
	if _studio == null or _design.is_empty():
		return
	_vehicle_node = VehicleBuilder.build_from_design(_design, {"cutaway": _cutaway})
	_studio.show_node(_vehicle_node)
	_studio.place_person(float(_design["width_m"]) * 0.5 + 0.4, 0.6)
	_marks = Node3D.new()
	_marks.name = "Marks"
	_vehicle_node.add_child(_marks)
	_draw_marks()


## The armed tool's ghost (cyan) and the selected item (amber) as see-through
## boxes on top of everything.
func _draw_marks() -> void:
	if _marks == null or not is_instance_valid(_marks):
		return
	for c in _marks.get_children():
		_marks.remove_child(c)
		c.queue_free()
	if not _ghost.is_empty():
		if _ghost.has("fx"):
			_mark_aabb(_ghost, C_GHOST)
		else:
			_mark_box(_ghost, C_GHOST)
	if _sel.is_empty():
		return
	if _sel_kind == "int":
		var el := _in_resolved(_sel)
		if not el.is_empty():
			_mark_aabb(el, C_SELECT)
		return
	for e in _design.get("exterior", []):
		if str((e as Dictionary)["id"]) == _sel:
			_mark_box(e as Dictionary, C_SELECT)


## A roof / side item's oriented box.
func _mark_box(el: Dictionary, c: Color) -> void:
	var fr := VehicleExterior.frame(_design, el)
	if not fr.is_empty():
		_mark_xf(Transform3D(fr["basis"], fr["centre"]), fr["size"], c)


## One see-through box at `xf`.
func _mark_xf(xf: Transform3D, size: Vector3, c: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size + Vector3(0.04, 0.04, 0.04)
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.transform = xf
	_marks.add_child(mi)


## An inside element's box (axis-aligned, vehicle-local).
func _mark_aabb(el: Dictionary, c: Color) -> void:
	var bx := VehicleInterior.box_of(el)
	_mark_xf(Transform3D(Basis(), bx["centre"]), (bx["size"] as Vector3), c)


func _frame_camera() -> void:
	if _design.is_empty():
		return
	var L := float(_design["length_m"])
	var H := float(_design["height_m"])
	# Far enough to see the whole length from the three-quarter home view.
	_studio.frame_sphere(Vector3(0, H * 0.45, 0), maxf(L * 0.55, H), 1.6)


# --- the preview: tools, picking, dragging -----------------------------------------------

func _arm_tool(preset: Dictionary) -> void:
	_tool = preset.duplicate(true) if not preset.is_empty() else {}
	_ghost = {}
	var want := "tool_%s" % str(_tool.get("id", ""))
	var buttons: Array = _tool_box.get_children()
	for flow in _in_tool_box.get_children():
		if flow is HFlowContainer:
			buttons.append_array(flow.get_children())
	for b in buttons:
		(b as Button).set_pressed_no_signal(not _tool.is_empty() and str(b.name) == want)
	if _tool.is_empty():
		_shell.set_mode("")
	else:
		var label := str(_tool.get("label", ""))
		if not _is_interior_tool():
			label = str(_tool.get("label", VehicleExterior.type_info(str((_tool["element"] as Dictionary)["type"]))["label"]))
		elif not _cutaway:
			# Inside work needs the skin off.
			_cut_btn.button_pressed = true
		_shell.set_mode("Placing: %s (Shift keeps it · Esc stops)" % label)
		_sel = ""
		_sel_kind = ""
		_refresh_items()
	_draw_marks()


func _is_interior_tool() -> bool:
	return str(_tool.get("kind", "")) == "interior"


func _local_ray(pos: Vector2) -> Dictionary:
	if _vehicle_node == null or not is_instance_valid(_vehicle_node):
		return {}
	return _studio.pick_ray_local(_vehicle_node, pos)


func _studio_input(e: InputEvent) -> bool:
	if not _active:
		return false
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if not _tool.is_empty():
			_update_ghost(mm.position)
			return false
		if _dragging:
			if mm.position.distance_to(_drag_press) > 3.0:
				_drag_moved = true
			if _drag_moved:
				if _sel_kind == "int":
					_drag_interior(mm.position)
				else:
					_drag_to(mm.position)
			return true
		return false
	if not (e is InputEventMouseButton):
		return false
	var mb := e as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return false
	if mb.pressed:
		if not _tool.is_empty():
			_update_ghost(mb.position)
			if not _ghost.is_empty():
				_place_ghost(mb.shift_pressed)
			return true
		var r := _local_ray(mb.position)
		if r.is_empty():
			return false
		if _cutaway:
			var iid := VehicleInterior.pick(_design, r["origin"], r["dir"])
			if not iid.is_empty():
				_select(iid, "int")
				_dragging = true
				_drag_moved = false
				_drag_press = mb.position
				_drag_grab = Vector2.ZERO
				var iel := _in_resolved(iid)
				var fh := VehicleInterior.floor_hit(_design, r["origin"], r["dir"])
				if not fh.is_empty():
					_drag_grab = Vector2(float(iel["x"]) - float(fh["x"]), float(iel["zc"]) - float(fh["zc"]))
				_push_undo()
				return true
		var id := VehicleExterior.pick(_design, r["origin"], r["dir"])
		if id.is_empty():
			return false
		_select(id)
		_dragging = true
		_drag_moved = false
		_drag_press = mb.position
		_drag_grab = Vector2.ZERO
		var el := _resolved(id)
		if not el.is_empty():
			var fr := VehicleExterior.frame(_design, el)
			_drag_level = float((fr["base"] as Vector3).y) if str(el["face"]) == "roof" else 0.0
			var ph := VehicleExterior.plane_hit(_design, str(el["face"]), r["origin"], r["dir"], _drag_level)
			if not ph.is_empty():
				# Where on the item it was grabbed, so it does not jump to the pointer.
				_drag_grab = Vector2(float(el["u"]) - float(ph["u"]), float(el["v"]) - float(ph["v"]))
		_push_undo()
		return true
	if _dragging:
		_dragging = false
		if _drag_moved:
			_rebuild_now()
		elif not _undo.is_empty():
			# A click with no move: nothing changed, drop the undo step.
			_undo.pop_back()
			_update_undo_buttons()
		return true
	return false


func _update_ghost(pos: Vector2) -> void:
	var r := _local_ray(pos)
	var cand := {}
	if not r.is_empty() and _is_interior_tool():
		var fh := VehicleInterior.floor_hit(_design, r["origin"], r["dir"])
		cand = VehicleInterior.candidate(_design, _tool["element"], fh)
	elif not r.is_empty():
		var hit := VehicleExterior.face_hit(_design, r["origin"], r["dir"])
		cand = VehicleExterior.candidate(_design, _tool["element"], hit)
	if JSON.stringify(cand) != JSON.stringify(_ghost):
		_ghost = cand
		_draw_marks()


func _place_ghost(keep_tool: bool) -> void:
	if _is_interior_tool():
		_place_interior(keep_tool)
		return
	_push_undo()
	var el := _ghost.duplicate(true)
	el["id"] = _new_element_id(str(el["type"]))
	for k in ["w", "l", "h", "mod_u", "mod_v"]:
		if str(el["type"]) == "solar" or not (VehicleExterior.FIELDS.get(str(el["type"]), []) as Array).any(
				func(f): return str(f[0]) == k):
			el.erase(k)
	var ext: Dictionary = _spec.get("exterior", {})
	var els: Array = (ext.get("elements", []) as Array).duplicate(true)
	els.append(el)
	ext["elements"] = els
	_spec["exterior"] = ext
	_sel = str(el["id"]) if not keep_tool else ""
	_sel_kind = "ext" if not keep_tool else ""
	if not keep_tool:
		_tool = {}
		_arm_tool({})
	_ghost = {}
	_rebuild_now()


func _new_element_id(type: String) -> String:
	var n := 1
	while _has_element("%s%d" % [type, n]):
		n += 1
	return "%s%d" % [type, n]


func _has_element(id: String) -> bool:
	if id.is_empty():
		return false
	for e in (_spec.get("exterior", {}) as Dictionary).get("elements", []):
		if str((e as Dictionary).get("id", "")) == id:
			return true
	return false


func _element_index(id: String) -> int:
	var els: Array = (_spec.get("exterior", {}) as Dictionary).get("elements", [])
	for i in els.size():
		if str((els[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


## Slide the selected item to where the pointer meets the body (onto another
## face too, where that type may go).
func _drag_to(pos: Vector2) -> void:
	var i := _element_index(_sel)
	if i < 0:
		return
	var r := _local_ray(pos)
	if r.is_empty():
		return
	var els: Array = (_spec["exterior"] as Dictionary)["elements"]
	var el: Dictionary = els[i]
	var t := VehicleExterior.type_info(str(el["type"]))
	var face := str(_resolved(_sel).get("face", el.get("face", "roof")))
	# Onto another face only when the pointer clearly lands on one it may go
	# on; otherwise slide on the item's own face plane, keeping the grab.
	var hit := VehicleExterior.face_hit(_design, r["origin"], r["dir"])
	var grab := _drag_grab
	if not hit.is_empty() and str(hit["face"]) != face and (t["faces"] as Array).has(str(hit["face"])):
		face = str(hit["face"])
		grab = Vector2.ZERO
		_drag_grab = grab
		if face == "roof":
			_drag_level = VehicleExterior.roof_y(_design, float(hit["u"]))
	else:
		hit = VehicleExterior.plane_hit(_design, face, r["origin"], r["dir"], _drag_level)
	if hit.is_empty():
		return
	el["face"] = face
	el["u"] = snappedf(float(hit["u"]) + grab.x, 0.05)
	if str(el["type"]) not in ["ladder", "awning", "hitch"]:
		el["v"] = snappedf(float(hit["v"]) + grab.y, 0.05)
	elif str(el["type"]) == "awning" or str(el["type"]) == "ladder":
		el.erase("v")
	if _drag_timer <= 0.0:
		_drag_timer = DRAG_REBUILD_S
		_spec = VehicleSpec.resolve(_spec)
		_design = VehicleDesign.solve(_spec)
		_rebuild_studio()
		_sync_item_values()


## The resolved (on-face, defaulted) element with this id, from the design.
func _resolved(id: String) -> Dictionary:
	for e in _design.get("exterior", []):
		if str((e as Dictionary)["id"]) == id:
			return e
	return {}


func _select(id: String, kind: String = "ext") -> void:
	_sel = id
	_sel_kind = kind if not id.is_empty() else ""
	_refresh_items()
	_draw_marks()


## A click that reached the studio hit nothing (the input hook takes every
## press on an item and selects it there): it clears the selection.
func _on_studio_click(_pos: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT or not _tool.is_empty():
		return
	_select("")


func _on_studio_hover(pos: Vector2) -> void:
	if not _tool.is_empty() or _dragging:
		return
	var r := _local_ray(pos)
	if r.is_empty():
		_hover_lbl.text = ""
		return
	if _cutaway:
		var iid := VehicleInterior.pick(_design, r["origin"], r["dir"])
		if not iid.is_empty():
			_hover_lbl.text = "%s · click to select, drag to move, R turns it" % VehicleInterior.label_of(_in_resolved(iid))
			return
	var id := VehicleExterior.pick(_design, r["origin"], r["dir"])
	if not id.is_empty():
		for e in _design.get("exterior", []):
			if str((e as Dictionary)["id"]) == id:
				_hover_lbl.text = "%s on the %s · click to select, drag to move" % [VehicleExterior.label_of(e),
					VehicleExterior.face_word(str(e["face"]))]
				return
	var hit := VehicleExterior.face_hit(_design, r["origin"], r["dir"])
	_hover_lbl.text = "The %s" % VehicleExterior.face_word(str(hit["face"])) if not hit.is_empty() else ""


func _remove_selected() -> void:
	if _sel_kind == "int":
		var j := _in_index(_sel)
		if j < 0:
			return
		_push_undo()
		(_in_elements()).remove_at(j)
		_sel = ""
		_sel_kind = ""
		_rebuild_now()
		return
	var i := _element_index(_sel)
	if i < 0:
		return
	_push_undo()
	var els: Array = (_spec["exterior"] as Dictionary)["elements"]
	els.remove_at(i)
	_sel = ""
	_rebuild_now()


# --- the selected item's card ------------------------------------------------------------

func _refresh_items() -> void:
	_refresh_inside()
	var el := {}
	for e in _design.get("exterior", []):
		if _sel_kind == "ext" and str((e as Dictionary)["id"]) == _sel:
			el = e
	var sig := "%s|%s|%s" % [_sel, str(el.get("type", "")), str(el.get("face", ""))]
	if sig == _item_sig:
		_sync_item_values()
		return
	_item_sig = sig
	for c in _item_box.get_children():
		_item_box.remove_child(c)
		c.queue_free()
	var count := ((_spec.get("exterior", {}) as Dictionary).get("elements", []) as Array).size()
	if el.is_empty():
		var l := Label.new()
		l.text = "%s on it. Click one in the preview to edit it." % UiText.count(count, "item") if count > 0 \
			else "Nothing on the roof or sides yet."
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_item_box.add_child(l)
		return
	_item_box.add_child(SectionHeader.make(VehicleExterior.label_of(el), "pencil"))
	var t := VehicleExterior.type_info(str(el["type"]))
	var faces: Array = []
	for f in t["faces"]:
		faces.append([f, VehicleExterior.face_word(str(f)).capitalize()])
	_item_box.add_child(FormRow.option("Face", faces, func(v): _item_edit("face", str(v)), "", "vl_item_face"))
	var fr: Dictionary = VehicleExterior.faces(_design)[str(el["face"])]
	var u_label := "Across" if str(el["face"]) in ["roof", "rear"] else "Along"
	var v_label := "Along" if str(el["face"]) == "roof" else "Height"
	_item_box.add_child(FormRow.spin(u_label, float(fr["u0"]), float(fr["u1"]), 0.01, " m",
		func(v): _item_edit("u", v), "", "vl_item_u"))
	_item_box.add_child(FormRow.spin(v_label, float(fr["v0"]) - 0.5, maxf(float(fr["v1"]), float(_design["height_m"])),
		0.01, " m", func(v): _item_edit("v", v), "", "vl_item_v"))
	for f2 in VehicleExterior.FIELDS.get(str(el["type"]), []):
		var fd: Array = f2
		var key := str(fd[0])
		match str(fd[2]):
			"module":
				var items: Array = []
				for m in VehicleExterior.MODULES:
					items.append([m, str(VehicleExterior.MODULES[m]["label"])])
				_item_box.add_child(FormRow.option(str(fd[1]), items, func(v): _item_edit(key, str(v)), "", "vl_item_" + key))
			"int", "float":
				_item_box.add_child(FormRow.spin(str(fd[1]), float(fd[3]), float(fd[4]), float(fd[5]), str(fd[6]),
					func(v): _item_edit(key, int(v) if str(fd[2]) == "int" else v), "", "vl_item_" + key))
			"bool":
				_item_box.add_child(FormRow.check(str(fd[1]), "", func(on): _item_edit(key, on), "", "vl_item_" + key))
	var info := Label.new()
	info.name = "vl_item_info"
	info.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	info.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_item_box.add_child(info)
	var rm := Button.new()
	rm.text = "Remove"
	rm.name = "vl_item_remove"
	rm.tooltip_text = "Remove it (Del or Backspace)"
	UITheme.style_button(rm)
	rm.pressed.connect(_remove_selected)
	_item_box.add_child(rm)
	_sync_item_values()


func _sync_item_values() -> void:
	var el := {}
	for e in _design.get("exterior", []):
		if _sel_kind == "ext" and str((e as Dictionary)["id"]) == _sel:
			el = e
	if el.is_empty():
		return
	_suppress = true
	for c in _item_box.get_children():
		if not (c is FormRow):
			if str(c.name) == "vl_item_info":
				(c as Label).text = _item_info(el)
			continue
		var row := c as FormRow
		var key := str(row.control.name).trim_prefix("vl_item_")
		if el.has(key):
			row.set_value(el[key])
	_suppress = false


func _item_info(el: Dictionary) -> String:
	if str(el["type"]) == "solar":
		var m: Dictionary = VehicleExterior.MODULES[str(el["module"])]
		var n := int(el["rows"]) * int(el["cols"])
		return "%s · %s · %.2f × %.2f m" % [UiText.count(n, "module"), UiText.num(float(m["watts"]) * n, "W"),
			float(el["w"]), float(el["l"])]
	var t := VehicleExterior.type_info(str(el["type"]))
	var bits: Array = ["%.0f kg" % float(t.get("kg", 0.0))]
	if float(t.get("load_w", 0.0)) > 0.0:
		bits.append("draws %s" % UiText.num(float(t["load_w"]), "W"))
	return " · ".join(bits)


func _item_edit(key: String, value: Variant) -> void:
	if _suppress:
		return
	var i := _element_index(_sel)
	if i < 0:
		return
	_push_undo("item.%s.%s" % [_sel, key])
	var els: Array = (_spec["exterior"] as Dictionary)["elements"]
	var el: Dictionary = els[i]
	el[key] = value
	if key == "face":
		el.erase("u")
		el.erase("v")
	_rebuild_timer = REBUILD_DELAY


# --- inside ---------------------------------------------------------------------------

## The spec's interior element list (made if missing), edited in place.
func _in_elements() -> Array:
	var inn: Dictionary = _spec.get("interior", {}) if _spec.get("interior", {}) is Dictionary else {}
	if not (inn.get("elements", null) is Array):
		inn["elements"] = []
	_spec["interior"] = inn
	return inn["elements"]


func _in_index(id: String) -> int:
	if id.is_empty():
		return -1
	var els: Array = (_spec.get("interior", {}) as Dictionary).get("elements", []) if _spec.get("interior", {}) is Dictionary else []
	for i in els.size():
		if str((els[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


func _in_resolved(id: String) -> Dictionary:
	return VehicleInterior.element(_design, id)


func _new_interior_id(type: String) -> String:
	if _in_index(type) < 0:
		return type
	var n := 2
	while _in_index("%s%d" % [type, n]) >= 0:
		n += 1
	return "%s%d" % [type, n]


func _place_interior(keep_tool: bool) -> void:
	_push_undo()
	var g := _ghost
	var ed := {"id": _new_interior_id(str(g["type"])), "type": str(g["type"]),
		"x": snappedf(float(g["x"]), 0.05), "z": snappedf(float(g["zc"]), 0.05)}
	_in_elements().append(ed)
	_sel = str(ed["id"]) if not keep_tool else ""
	_sel_kind = "int" if not keep_tool else ""
	if not keep_tool:
		_tool = {}
		_arm_tool({})
	_ghost = {}
	_rebuild_now()


## Slide the selected inside element to where the pointer meets the floor.
func _drag_interior(pos: Vector2) -> void:
	var i := _in_index(_sel)
	if i < 0:
		return
	var r := _local_ray(pos)
	if r.is_empty():
		return
	var fh := VehicleInterior.floor_hit(_design, r["origin"], r["dir"])
	if fh.is_empty():
		return
	var ed: Dictionary = _in_elements()[i]
	ed["x"] = snappedf(float(fh["x"]) + _drag_grab.x, 0.05)
	ed["z"] = snappedf(float(fh["zc"]) + _drag_grab.y, 0.05)
	if _drag_timer <= 0.0:
		_drag_timer = DRAG_REBUILD_S
		_spec = VehicleSpec.resolve(_spec)
		_design = VehicleDesign.solve(_spec)
		_rebuild_studio()
		_sync_inside_values()


## Turn the selected inside element a quarter turn.
func _turn_interior() -> void:
	var i := _in_index(_sel)
	if i < 0:
		return
	_push_undo()
	var ed: Dictionary = _in_elements()[i]
	ed["yaw"] = 0.0 if absf(float(ed.get("yaw", 0.0))) > 45.0 else 90.0
	_rebuild_now()


func _refresh_inside() -> void:
	if _in_box == null:
		return
	var el := _in_resolved(_sel) if _sel_kind == "int" else {}
	var sig := "%s|%s" % [_sel if not el.is_empty() else "", str(el.get("type", ""))]
	if sig == _in_sig:
		_sync_inside_values()
		return
	_in_sig = sig
	for c in _in_box.get_children():
		_in_box.remove_child(c)
		c.queue_free()
	if el.is_empty():
		var l := Label.new()
		var n := (_design.get("interior", []) as Array).size()
		l.text = "%s inside. With the skin off, click one to edit it." % UiText.count(n, "piece") if n > 0 \
			else "Nothing inside yet."
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_in_box.add_child(l)
		return
	_in_box.add_child(SectionHeader.make(VehicleInterior.label_of(el), "pencil"))
	var house: Dictionary = _design["house"]
	var hw := float(house["w"]) * 0.5
	_in_box.add_child(FormRow.spin("Across", -hw, hw, 0.05, " m", func(v): _in_edit("x", v),
		"From the middle: + is the curb (door) side", "vl_in_x"))
	_in_box.add_child(FormRow.spin("Along", 0.0, float(house["len"]), 0.05, " m", func(v): _in_edit("z", v),
		"From the front of the living space", "vl_in_zc"))
	_in_box.add_child(FormRow.spin("Width", 0.1, float(house["w"]), 0.01, " m", func(v): _in_edit("w", v), "", "vl_in_w"))
	_in_box.add_child(FormRow.spin("Length", 0.1, float(house["len"]), 0.01, " m", func(v): _in_edit("l", v), "", "vl_in_l"))
	_in_box.add_child(FormRow.spin("Height", 0.05, 2.4, 0.01, " m", func(v): _in_edit("h", v), "", "vl_in_h"))
	_in_box.add_child(FormRow.check("Turned", "A quarter turn (R)", func(on): _in_edit("yaw", 90.0 if on else 0.0),
		"", "vl_in_yaw90"))
	for f in VehicleInterior.FIELDS.get(str(el["type"]), []):
		var fd: Array = f
		var key := str(fd[0])
		_in_box.add_child(FormRow.spin(str(fd[1]), float(fd[3]), float(fd[4]), float(fd[5]), str(fd[6]),
			func(v): _in_edit(key, v), "", "vl_in_" + key))
	var info := Label.new()
	info.name = "vl_in_info"
	info.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	info.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_in_box.add_child(info)
	var rm := Button.new()
	rm.text = "Remove"
	rm.name = "vl_in_remove"
	UITheme.style_button(rm)
	rm.pressed.connect(_remove_selected)
	_in_box.add_child(rm)
	_sync_inside_values()


func _sync_inside_values() -> void:
	if _in_box == null or _sel_kind != "int":
		return
	var el := _in_resolved(_sel)
	if el.is_empty():
		return
	_suppress = true
	for c in _in_box.get_children():
		if not (c is FormRow):
			if str(c.name) == "vl_in_info":
				(c as Label).text = VehicleInterior.info_line(_design, el)
			continue
		var row := c as FormRow
		var key := str(row.control.name).trim_prefix("vl_in_")
		if el.has(key):
			row.set_value(el[key])
	_suppress = false


func _in_edit(key: String, value: Variant) -> void:
	if _suppress:
		return
	var i := _in_index(_sel)
	if i < 0:
		return
	_push_undo("in.%s.%s" % [_sel, key])
	var ed: Dictionary = _in_elements()[i]
	ed[key] = value
	_rebuild_timer = REBUILD_DELAY


# --- summary ------------------------------------------------------------------------

func _refresh_summary() -> void:
	var d := _design
	var e: Dictionary = d["energy_55"]
	var lines: Array = []
	lines.append("%.1f m long · %.2f m wide · %.2f m tall · turns in a %.1f m circle" % [float(d["length_m"]),
		float(d["width_m"]), float(d["height_m"]), float(d["turn_radius_m"]) * 2.0])
	lines.append("Sleeps %d · seats %d · %s inside" % [int(d["sleeps"]), int(d["seats"]),
		"%.1f m × %.2f m" % [float(d["house"]["len"]), float(d["house"]["w"])]])
	lines.append("Weighs %.1f t empty · %.1f t loaded (%d aboard, tanks full, gear) · payload left %.0f kg" % [
		float(d["curb_kg"]) / 1000.0, float(d["laden_kg"]) / 1000.0, int(d["seats"]), float(d["payload_kg"])])
	if bool(d.get("drivable", false)):
		var af := float(d.get("axle_f_kg", 0.0))
		var ar := float(d.get("axle_r_kg", 0.0))
		lines.append("Axles: front %.0f kg (%d %%) · rear %.0f kg of %.0f rated" % [af,
			int(round(100.0 * af / maxf(af + ar, 1.0))), ar, float(d.get("gawr_r_kg", 0.0))])
	else:
		lines.append("Tongue weight %.0f kg (%d %%) · axles %.0f kg" % [float(d.get("tongue_kg", 0.0)),
			int(round(100.0 * float(d.get("tongue_pct", 0.0)))), float(d.get("axle_r_kg", 0.0))])
	if float(d.get("overall_h_m", 0.0)) > float(d["height_m"]) + 0.01:
		lines.append("%.2f m tall with the roof items · %.0f kg on the roof" % [float(d["overall_h_m"]),
			float(d.get("roof_load_kg", 0.0))])
	var bay := VehicleCargo.bay(d)
	if not bay.is_empty():
		var bi: Dictionary = bay["interior"]
		var bdr: Dictionary = bay["door"]
		lines.append("Cargo bay %.1f × %.1f × %.1f m through a %.2f × %.2f m %s door" % [float(bi["l_m"]), float(bi["w_m"]),
			float(bi["h_m"]), float(bdr["w_m"]), float(bdr["h_m"]), VehicleExterior.face_word(str(bay["door_where"]))])
	var tot: Dictionary = d.get("exterior_totals", {})
	if float(tot.get("solar_w", 0.0)) > 0.0:
		lines.append("Solar %s on %s" % [UiText.num(float(tot["solar_w"]), "W"), UiText.count(int(tot["modules"]), "module")])
	if str(d["fuel"]) == "electric":
		lines.append(("%.2f kWh/km at 90 km/h" % float(e["kwh_per_km"])) if UnitsPref.metric()
			else ("%.2f kWh/mi at 55 mph" % (float(e["kwh_per_km"]) * VehicleEnergy.MI_M / 1000.0)))
	elif float(e["mpg"]) > 0.0:
		lines.append("%s at %s (%s)" % [UnitsPref.economy_mpg(float(e["mpg"])),
			"90 km/h" if UnitsPref.metric() else "55 mph", FUEL_WORDS.get(str(d["fuel"]), str(d["fuel"]))])
	else:
		lines.append("Towed: no engine of its own")
	_summary.text = "\n".join(PackedStringArray(lines))
	var t: Dictionary = d["trip_estimate"]
	if float(t["mi"]) <= 0.0:
		_trip_lbl.text = "Type how far it drives one way to see what getting it there costs."
	elif str(t["fuel"]) == "electric":
		_trip_lbl.text = "There and back: %s, %.0f kWh, $%.0f. Range %s." % [UnitsPref.dist_mi(float(t["mi"])),
			float(t["kwh"]), float(t["cost"]), UnitsPref.dist_m(float(t["range_km"]) * 1000.0)]
	elif float(t["gallons"]) > 0.0:
		_trip_lbl.text = "There and back: %s, %s, $%.0f. Range %s a tank." % [UnitsPref.dist_mi(float(t["mi"])),
			UnitsPref.fuel_l(float(t["litres"])), float(t["cost"]), UnitsPref.dist_m(float(t["range_km"]) * 1000.0)]
	else:
		_trip_lbl.text = "Towed: its fuel is the tow vehicle's."
	for c in _checks_box.get_children():
		_checks_box.remove_child(c)
		c.queue_free()
	var n_err := 0
	var n_warn := 0
	for chk0 in d["checks"]:
		var l0 := str((chk0 as Dictionary)["level"])
		n_err += 1 if l0 == "error" else 0
		n_warn += 1 if l0 == "warn" else 0
	if n_err > 0:
		_shell.set_badge("%s to fix" % UiText.count(n_err, "problem"), "error", "Click to see the checks")
	elif n_warn > 0:
		_shell.set_badge(UiText.count(n_warn, "warning"), "warn", "Click to see the checks")
	else:
		_shell.set_badge("Checks pass", "ok", "Nothing to fix")
	for chk in d["checks"]:
		var cd: Dictionary = chk
		var lvl := str(cd["level"])
		var banner := AlertBanner.new()
		_checks_box.add_child(banner)
		banner.show_alert(AlertBanner.ERROR if lvl == "error" else (AlertBanner.WARN if lvl == "warn"
			else AlertBanner.INFO), str(cd["text"]))
		# The reason, a sentence, on hover.
		if not str(cd.get("why", "")).is_empty():
			banner.tooltip_text = str(cd["why"])
		# "Show it" selects the first named thing: an interior element (the
		# skin comes off) or a roof / side item.
		var ids: Array = cd.get("ids", [])
		var first := str(ids[0]) if not ids.is_empty() else ""
		var kind := "int" if _in_index(first) >= 0 else ("ext" if _has_element(first) else "")
		if not kind.is_empty():
			var show := Button.new()
			show.text = "Show it"
			show.tooltip_text = "Select it in the preview" + (" (the skin comes off)" if kind == "int" else "")
			UITheme.style_button(show)
			show.pressed.connect(func() -> void:
				if kind == "int" and not _cutaway:
					_cut_btn.button_pressed = true
				elif kind == "ext" and _cutaway:
					_cut_btn.button_pressed = false
				_select(first, kind))
			_checks_box.add_child(show)


# --- library, files, actions ---------------------------------------------------------------

func _refresh_design_list() -> void:
	_design_list.clear()
	_design_entries = []
	for b in VehiclePresets.builtins():
		var bd: Dictionary = b
		_design_list.add_item(str((bd["spec"] as Dictionary)["name"]))
		_design_entries.append(bd["spec"])
	for s in _library:
		_design_list.add_item("★ %s" % str((s as Dictionary).get("name", "Design")))
		_design_entries.append(s)


func _on_design_selected(idx: int) -> void:
	if idx < 0 or idx >= _design_entries.size():
		return
	_push_undo()
	_spec = VehicleSpec.resolve(_design_entries[idx])
	_sel = ""
	_rebuild_now()
	_frame_camera()


func _on_save_design() -> void:
	var nm := str(_spec.get("name", ""))
	for s in _library:
		if str((s as Dictionary).get("name", "")) == nm:
			_replace_dialog.dialog_text = "Your vehicles already have a design called \"%s\". Replace it with this one?" % nm
			_replace_dialog.popup_centered()
			return
	_save_design(false)


func _save_design(_replacing: bool) -> void:
	var safe := VehicleSpec.to_json_safe(_spec)
	var kept: Array = []
	for s in _library:
		if str((s as Dictionary).get("name", "")) != str(safe.get("name", "")):
			kept.append(s)
	kept.append(safe)
	_library = kept
	VehiclePresets.save_library(_library)
	_refresh_design_list()
	_toast("Saved \"%s\" to your vehicles" % str(safe.get("name", "")))


func _on_forget_design() -> void:
	var sel := _design_list.get_selected_items()
	if sel.is_empty():
		return
	var idx := int(sel[0]) - VehiclePresets.builtins().size()
	if idx < 0 or idx >= _library.size():
		return
	var gone := str((_library[idx] as Dictionary).get("name", "design"))
	_library.remove_at(idx)
	VehiclePresets.save_library(_library)
	_refresh_design_list()
	_toast("Forgot \"%s\"" % gone)


func _refresh_wraps() -> void:
	_wrap_opt.clear()
	_wrap_opt.add_item("None (paint)", 0)
	_wrap_opt.set_item_metadata(0, "")
	var i := 1
	for f in VehicleBuilder.list_wraps():
		_wrap_opt.add_item(str(f), i)
		_wrap_opt.set_item_metadata(i, str(f))
		i += 1


func _refresh_models() -> void:
	_glb_opt.clear()
	_glb_opt.add_item("None (parametric)", 0)
	_glb_opt.set_item_metadata(0, "")
	var i := 1
	for a in SHIPPED_ART:
		if ResourceLoader.exists(str(a[0])):
			_glb_opt.add_item(str(a[1]), i)
			_glb_opt.set_item_metadata(i, str(a[0]))
			i += 1
	var dir := DirAccess.open(MODEL_DIR)
	if dir != null:
		for f in dir.get_files():
			var ext := f.get_extension().to_lower()
			if ext == "glb" or ext == "gltf":
				_glb_opt.add_item(f, i)
				_glb_opt.set_item_metadata(i, "%s/%s" % [MODEL_DIR, f])
				i += 1


func _copy_in(src: String, dir: String) -> String:
	DirAccess.make_dir_recursive_absolute(dir)
	var dst := "%s/%s" % [dir, src.get_file()]
	if DirAccess.copy_absolute(src, ProjectSettings.globalize_path(dst)) != OK:
		_toast("Could not copy %s" % src.get_file())
		return ""
	return dst


func _on_wrap_file(path: String) -> void:
	var dst := _copy_in(path, VehicleBuilder.WRAP_DIR)
	if dst.is_empty():
		return
	_refresh_wraps()
	_edit(["paint", "wrap"], dst.get_file())


func _on_model_file(path: String) -> void:
	var dst := _copy_in(path, MODEL_DIR)
	if dst.is_empty():
		return
	_refresh_models()
	_set_glb("path", dst)


func _open_folder(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	OS.shell_open(ProjectSettings.globalize_path(dir))


func _toast(text: String) -> void:
	var main := _main_node()
	if main != null and main.has_method("show_toast"):
		main.call("show_toast", text)


func _main_node() -> Node:
	var tree := get_tree()
	return tree.current_scene if tree != null else null


func _prop_record(prop_id: String) -> Dictionary:
	var main := _main_node()
	return PlacedPropService.get_prop_record(main, prop_id) if main != null else {}


func _on_place() -> void:
	if _loader != null and _loader.has_method("begin_vehiclelab_placement"):
		if bool(_loader.call("begin_vehiclelab_placement", VehicleSpec.to_json_safe(_spec))):
			close()
			return
	_toast("Placing needs a location map.")


func _on_apply() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	if main != null:
		PlacedPropService.update_prop_record(main, _bound_prop_id,
			{"vehicle_spec": VehicleSpec.to_json_safe(_spec)}, true)
		PlacedPropService.tag_vehicle_spaces(main, _bound_prop_id)
		_toast("Applied to %s" % str(_spec.get("name", "the vehicle")))
	close()


# --- accessors for the harness and the tour ---------------------------------------------------

func spec() -> Dictionary:
	return _spec


func design() -> Dictionary:
	return _design


func studio() -> StudioViewport:
	return _studio


func vehicle_node() -> Node3D:
	return _vehicle_node


func selected() -> String:
	return _sel


func tool_id() -> String:
	return str(_tool.get("id", ""))


func selected_kind() -> String:
	return _sel_kind


## Arm an inside tool by element type ("" disarms).
func arm_interior(type: String) -> void:
	if type.is_empty():
		_arm_tool({})
		return
	for t in VehicleInterior.tools():
		if str((t as Dictionary)["id"]) == type:
			var preset := (t as Dictionary).duplicate(true)
			preset["kind"] = "interior"
			preset["id"] = "in_" + type
			_arm_tool(preset)
			return


## Straight down into the vehicle with the skin off (on), or back to the
## three-quarter view.
func set_plan_view(on: bool) -> void:
	if _plan_btn != null and _plan_btn.button_pressed != on:
		_plan_btn.set_pressed_no_signal(on)
	if on:
		if not _cutaway:
			_cut_btn.button_pressed = true
		var L := float(_design.get("length_m", 6.0))
		_studio.target = Vector3(0, float((_design.get("house", {}) as Dictionary).get("floor_y", 0.8)), 0)
		# Long axis up the screen: the front at the top.
		_studio.set_orbit(0.0, _studio.pitch_max, maxf(L * 1.55, 6.0))
	else:
		_studio.reset_orbit()
		_frame_camera()


func load_builtin(id: String) -> void:
	_push_undo()
	_spec = VehicleSpec.resolve(VehiclePresets.builtin(id))
	_sel = ""
	_rebuild_now()
	_frame_camera()


func set_cutaway(on: bool) -> void:
	_cut_btn.button_pressed = on


## Where a vehicle-local point is in the studio container (to aim real clicks).
func studio_pos_of(local: Vector3) -> Vector2:
	if _vehicle_node == null or _studio.camera == null:
		return Vector2.ZERO
	var w := _vehicle_node.global_transform * local
	var vp := _studio.camera.unproject_position(w)
	var vs := Vector2(_studio.viewport.size)
	var cs := _studio.container.size
	return vp * (cs / vs) if vs.x > 0.0 else vp


## A rendered frame of the preview.
func studio_image() -> Image:
	return _studio.image()
