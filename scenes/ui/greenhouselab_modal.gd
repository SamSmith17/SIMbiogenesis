extends CanvasLayer
## Greenhouse designer: gable, lean-to, quonset / hoop, gothic arch and
## geodesic dome greenhouses (core/greenhouselab/) with their glazing,
## vents, fans, heater, water barrels, earth sheltering, gutters and cistern,
## and the beds inside — raised beds, in-ground rows or keyhole rings, any of
## them with a FarmBot gantry and / or a grow-light rack. Place in world puts
## the shell on the site and stands every bed, gantry and light rack up inside
## it as its own prop mounted on the shell (GreenhouseWorld), so the whole
## house moves, packs and deletes as one. Apply re-solves a placed one.
##
## Open: static `open(tree, {spec, prop_id})` (Library → Designers →
## Greenhouses; the prop editor's "Edit greenhouse…").

signal closed

const MODAL_NAME := "greenhouselab"
const WANT := Vector2(1560, 940)
const UNDO_LIMIT := 60
const GROW_DAYS := 70.0

var _shell: DesignerShell = null
var _studio: StudioViewport = null
var _plan: GreenhousePlanView = null
var _bill: VBoxContainer = null
var _tabs: TabBar = null
var _views: Control = null
var _list: DesignGallery = null
var _col: DesignerColumn = null
var _light_panel: ModelLightPanel = null
var _shell_3d: Node3D = null
var _ids: Array = []
var _rows: Dictionary = {}
var _checks_box: VBoxContainer = null
var _bed_box: VBoxContainer = null
var _status: Label = null
var _apply_btn: Button = null
var _place_btn: Button = null
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _prop_id := ""
var _syncing := false
var _open := false
var _rebuild_pending := false
var _roof_off := false
var _show_parts := true
var _undo: Array = []
var _redo: Array = []
var _selected_bed := ""
# The Climate tab's year (GreenhouseYear on a worker thread).
var _climate_chart: GreenhouseClimateChart = null
var _climate_box: VBoxContainer = null
var _climate_line: Label = null
var _climate_btn: Button = null
var _year_task := -1
var _year_job: Dictionary = {}
var _year_key := ""
var _year_result: Dictionary = {}
var _year_wait := 0.0
static var _wx_cache: Dictionary = {}


static func open(tree: SceneTree, opts: Dictionary = {}) -> Node:
	var m: Node = load("res://scenes/ui/greenhouselab_modal.gd").new()
	tree.root.add_child(m)
	m.call("open_modal", opts)
	m.connect("closed", Callable(m, "queue_free"))
	return m


func _ready() -> void:
	layer = UITheme.LAYER_MODAL
	_build_ui()


func open_modal(opts: Dictionary = {}) -> void:
	if _open:
		return
	_open = true
	visible = true
	HudLayout.claim_modal(MODAL_NAME)
	_shell.open()
	_prop_id = str(opts.get("prop_id", ""))
	_refresh_list()
	var s: Variant = opts.get("spec", null)
	if (not (s is Dictionary) or (s as Dictionary).is_empty()) and not _prop_id.is_empty():
		var rec := PlacedPropService.get_prop_record(_main(), _prop_id)
		s = GreenhouseWorld.spec_of(rec)
	if s is Dictionary and not (s as Dictionary).is_empty():
		_load_spec(s)
	else:
		_load_spec(GreenhousePresets.builtin("market_hoop")["spec"])
	_undo.clear()
	_redo.clear()
	_apply_btn.visible = not _prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _prop_id.is_empty() else "Place in world"


func close() -> void:
	if not _open:
		return
	if _light_panel != null:
		_light_panel.reset_studio_night()
	_stop_year()
	if _shell.is_open():
		_shell.close()
	else:
		_on_shell_closed()


func _on_shell_closed() -> void:
	if not _open:
		return
	_open = false
	visible = false
	HudLayout.release(MODAL_NAME)
	closed.emit()


func is_open() -> bool:
	return _open


func current_spec() -> Dictionary:
	var s := GreenhouseSpec.resolve(_spec)
	if _light_panel != null:
		s[PropModelLights.KEY_MODEL_LIGHTS] = _light_panel.serialized_items()
	return s


func design() -> Dictionary:
	return _design


func _unhandled_key_input(e: InputEvent) -> void:
	if not _open or not (e is InputEventKey) or not e.pressed or (e as InputEventKey).echo:
		return
	var ke := e as InputEventKey
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		return
	if ke.keycode == KEY_Z and ke.ctrl_pressed and not ke.shift_pressed:
		_undo_step()
		get_viewport().set_input_as_handled()
	elif (ke.keycode == KEY_Y and ke.ctrl_pressed) or (ke.keycode == KEY_Z and ke.ctrl_pressed and ke.shift_pressed):
		_redo_step()
		get_viewport().set_input_as_handled()
	elif (ke.keycode == KEY_DELETE or ke.keycode == KEY_BACKSPACE) and not _selected_bed.is_empty():
		remove_bed(_selected_bed)
		get_viewport().set_input_as_handled()


# --- UI -------------------------------------------------------------------

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_shell = DesignerShell.create("Greenhouse designer", "sprout", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true, "undo": true,
		"left_label": "Designs", "left_w": 260.0, "right_w": 400.0})
	root.add_child(_shell)
	_shell.closed.connect(_on_shell_closed)
	_shell.undo_requested.connect(_undo_step)
	_shell.redo_requested.connect(_redo_step)
	_shell.name_submitted.connect(func(t: String) -> void:
		_spec["name"] = t
		_refresh_summary())
	_shell.name_edit.placeholder_text = "Design name"
	_build_left()
	_build_centre()
	_build_right()
	_shell.add_button("Save", DesignerShell.SECONDARY, _on_save, "Keep this design in your library")
	_place_btn = _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place,
		"Put it on the site where you aim: the shell, then its beds, gantries and lights inside it")
	_place_btn.name = "place_world"
	_apply_btn = _shell.add_button("Apply", DesignerShell.PRIMARY, _on_apply,
		"Rebuild the placed greenhouse and the beds inside it to this design")
	_apply_btn.name = "apply_placed"
	_shell.add_button("Build with a crew", DesignerShell.SECONDARY, _on_crew,
		"A packed kit ahead of you, handed to the nearest crew to put up")
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_shell.set_hint("Pick a design · its shape, glazing, vents and earth on the right · " +
		"Plan: drag beds, draw a new one, click one to set its crops, gantry and lights · " +
		"drag to orbit, wheel to zoom · Ctrl+Z undoes")


func _build_left() -> void:
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.left.add_child(box)
	box.add_child(SectionHeader.make("Greenhouses", "", "Built-ins and your saved designs"))
	_list = DesignGallery.make("greenhouse")
	_list.name = "design_list"
	_list.set_thumbnailer(_thumb_for)
	_list.item_selected.connect(_on_list_selected)
	box.add_child(_list)


func _build_centre() -> void:
	_tabs = TabBar.new()
	_tabs.name = "views"
	_tabs.add_tab("3D")
	_tabs.add_tab("Plan")
	_tabs.add_tab("Climate")
	_tabs.add_tab("Bill")
	_tabs.tab_changed.connect(func(_i: int) -> void: _show_view())
	_shell.centre.add_child(_tabs)
	_views = Control.new()
	_views.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_views.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_views.clip_contents = true
	_shell.centre.add_child(_views)
	_studio = StudioViewport.create({"ground": true, "person": true, "ssao": true, "far": 500.0})
	_studio.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_studio.set_home(0.65, 0.4)
	_studio.dist_max = 260.0
	_studio.input_hook = func(e: InputEvent) -> bool:
		return _light_panel != null and _light_panel.handle_viewport_event(e, _studio.camera, _studio.container, _shell_3d)
	if _studio.ground != null:
		(_studio.ground.mesh as PlaneMesh).size = Vector2(300, 300)
	_views.add_child(_studio)
	var roof := CheckButton.new()
	roof.text = "Roof off"
	roof.name = "roof_off"
	roof.focus_mode = Control.FOCUS_NONE
	roof.tooltip_text = "Leave the roof glazing out to see the beds from above"
	roof.toggled.connect(func(on: bool) -> void:
		_roof_off = on
		_rebuild_preview())
	_studio.strip.add_child(roof)
	var parts := CheckButton.new()
	parts.text = "Beds inside"
	parts.name = "show_parts"
	parts.button_pressed = true
	parts.focus_mode = Control.FOCUS_NONE
	parts.tooltip_text = "Show the beds, gantries and light racks that stand inside it"
	parts.toggled.connect(func(on: bool) -> void:
		_show_parts = on
		_rebuild_preview())
	_studio.strip.add_child(parts)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio.strip.add_child(spacer)
	_studio.strip.add_child(IconButton.make("maximize-2", "Frame the greenhouse", _frame))
	_plan = GreenhousePlanView.new()
	_plan.name = "plan_view"
	_plan.modal = self
	_plan.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_plan.visible = false
	_views.add_child(_plan)
	var sc := ScrollContainer.new()
	sc.name = "bill_view"
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sc.visible = false
	_views.add_child(sc)
	_bill = VBoxContainer.new()
	_bill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_bill)
	_build_climate_view()


func _show_view() -> void:
	var i := _tabs.current_tab
	_studio.visible = i == 0
	_studio.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if i == 0 and _open \
		else SubViewport.UPDATE_DISABLED
	_plan.visible = i == 1
	(_views.get_node("climate_view") as Control).visible = i == 2
	(_views.get_node("bill_view") as Control).visible = i == 3
	_plan.queue_redraw()
	if i == 2 and _year_key != _climate_key() and _year_task < 0:
		_year_wait = 0.05


## [section, key path, label, kind, a, b, step, unit, tip]
const FIELDS := [
	["Shape", "form", "Form", "option", "forms", "", 0.0, "", "Gable: straight walls and a pitched roof. Lean-to: one glazed slope facing the sun, an opaque back wall. Hoop: a round tunnel. Gothic: a pointed tunnel (sheds snow). Dome: a geodesic sphere."],
	["Shape", "width_m", "Width", "spin", 2.0, 40.0, 0.1, " m", "Across the house (a dome: its floor diameter)"],
	["Shape", "length_m", "Length", "spin", 2.0, 120.0, 0.1, " m", "Along the ridge"],
	["Shape", "eave_h_m", "Side walls", "spin", 0.0, 6.0, 0.05, " m", "Straight wall height before the roof starts"],
	["Shape", "ridge_h_m", "Peak", "spin", 1.5, 14.0, 0.05, " m", "Floor to the top (a lean-to: its back wall)"],
	["Shape", "front_h_m", "Front wall", "spin", 0.0, 4.0, 0.05, " m", "Lean-to: the glazed wall under the low edge of the roof"],
	["Shape", "bay_m", "Rib spacing", "spin", 0.6, 4.0, 0.05, " m", "Hoops, rafters or trusses along the length"],
	["Shape", "dome.frequency", "Dome frequency", "spin", 2.0, 8.0, 1.0, "V", "More frequency = more, smaller panels"],
	["Shape", "dome.fraction", "Dome height", "option", "fractions", "", 0.0, "", "How much of the sphere stands up"],
	["Skin", "glazing.roof", "Roof", "option", "glazings", "", 0.0, "", "What covers the roof"],
	["Skin", "glazing.walls", "Walls", "option", "glazings", "", 0.0, "", "What covers the side walls"],
	["Skin", "glazing.ends", "Ends", "option", "ends", "", 0.0, "", "The end walls (or opaque insulated ends)"],
	["Skin", "back_wall", "Back wall", "option", "walls", "", 0.0, "", "Lean-to: the north wall (masonry stores heat)"],
	["Skin", "frame", "Frame", "option", "frames", "", 0.0, "", "Hoops, rafters or trusses"],
	["Skin", "shade.cloth", "Shade cloth", "spin", 0.0, 0.8, 0.05, "", "Share of the light it stops (summer months)"],
	["Air", "vents.ridge", "Ridge vent", "check", "", "", 0.0, "", "A flap along the top: hot air leaves where it collects"],
	["Air", "vents.ridge_w_m", "Ridge vent width", "spin", 0.2, 2.0, 0.05, " m", ""],
	["Air", "vents.sides", "Side vents", "option", "sides", "", 0.0, "", "Roll-up sides open the whole wall; louvres a share of it"],
	["Air", "vents.side_h_m", "Side vent height", "spin", 0.2, 2.5, 0.05, " m", "How far up the side vents open"],
	["Air", "vents.ends", "End louvres", "check", "", "", 0.0, "", "Louvres high in each end wall"],
	["Air", "vents.end_m2", "Each louvre", "spin", 0.0, 8.0, 0.1, " m²", ""],
	["Air", "fans.kind", "Fans", "option", "fans", "", 0.0, "", "Exhaust fans in the back end wall"],
	["Air", "fans.count", "How many", "spin", 0.0, 12.0, 1.0, "", "0 = none (NGMA: about 0.04 m³/s per m² of floor)"],
	["Heat", "heater", "Heater", "option", "heaters", "", 0.0, "", "Kicks in when the controller says (an unvented propane heater adds water vapour)"],
	["Heat", "mass.barrels", "Water barrels", "spin", 0.0, 400.0, 1.0, "", "Drums of water along the back: they soak up the day's heat and give it back at night"],
	["Heat", "mass.litres_each", "Each holds", "spin", 20.0, 1000.0, 10.0, " L", "A 55 gal drum is 208 L"],
	["Heat", "mass.colour", "Barrel colour", "option", "colours", "", 0.0, "", "Black absorbs the most sun"],
	["Heat", "ground.sink_m", "Sunk below grade", "spin", 0.0, 2.5, 0.05, " m", "A walipini / pit greenhouse: the floor down in the earth, which stays warm in winter"],
	["Heat", "ground.berm", "Berm", "option", "berms", "", 0.0, "", "Earth piled against the walls that face away from the sun"],
	["Heat", "ground.walls", "Walls below grade", "option", "walls", "", 0.0, "", "What holds the earth back"],
	["Beds", "beds.style", "Beds", "option", "styles", "", 0.0, "", "Raised beds along the house, in-ground rows, or keyhole rings"],
	["Beds", "beds.bed_w_m", "Bed width", "spin", 0.5, 3.0, 0.05, " m", "Reached from the paths either side"],
	["Beds", "beds.path_w_m", "Path width", "spin", 0.3, 2.0, 0.05, " m", ""],
	["Beds", "beds.end_clear_m", "Clear at the ends", "spin", 0.3, 4.0, 0.05, " m", "Room inside each door"],
	["Beds", "beds.wall_h_m", "Bed walls", "spin", 0.0, 1.0, 0.01, " m", "Raised bed height"],
	["Beds", "beds.gantry", "FarmBot gantries", "check", "", "", 0.0, "", "A FarmBot on every bed (12 m tracks at most)"],
	["Beds", "beds.lights", "Grow lights", "check", "", "", 0.0, "", "An LED rack over every bed"],
	["Beds", "beds.feed", "Fed beds", "check", "", "", 0.0, "", "A nutrient store inside the house feeds every bed; on the graph it has a Nutrients in port to fill it from (compost, urine recovery)"],
	["Lights", "lights.spectrum", "Spectrum", "option", "spectrums", "", 0.0, "", "Hydroponic red/blue LED (660 nm + 450 nm) or full-spectrum white LED"],
	["Lights", "lights.schedule", "On", "option", "light_schedules", "", 0.0, "", "Turn grow lights on at sunset and off at sunrise by default, keep them always on, or follow the DLI photoperiod controller"],
	["Lights", "lights.ppfd", "Light level", "spin", 20.0, 1000.0, 10.0, " µmol/m²s", "Photons at the canopy when on (200 tops up winter light)"],
	["Lights", "lights.photoperiod_h", "Day length", "spin", 4.0, 24.0, 0.5, " h", "The longest the controller keeps them on"],
	["Lights", "lights.dli_target", "Daily light target", "spin", 2.0, 40.0, 0.5, " mol/m²/day", "Sun + lights the controller aims for (lettuce 12-17, tomatoes 20-30)"],
	["Lights", "lights.hang_m", "Hang above the bed", "spin", 0.2, 2.5, 0.05, " m", ""],
	["Controller", "control.vent_open_c", "Vents start opening", "spin", 10.0, 40.0, 0.5, " °C", ""],
	["Controller", "control.vent_full_c", "Vents fully open", "spin", 10.0, 45.0, 0.5, " °C", ""],
	["Controller", "control.fan_on_c", "Fans on", "spin", 10.0, 45.0, 0.5, " °C", ""],
	["Controller", "control.fan_off_c", "Fans off", "spin", 5.0, 40.0, 0.5, " °C", ""],
	["Controller", "control.heat_on_c", "Heater on", "spin", -10.0, 20.0, 0.5, " °C", ""],
	["Controller", "control.heat_off_c", "Heater off", "spin", -5.0, 25.0, 0.5, " °C", ""],
	["Controller", "control.rh_flush_pct", "Humidity flush above", "spin", 50.0, 100.0, 1.0, " %", "Vents crack open when the air is this humid and warm enough"],
	["Controller", "control.lights_auto", "Lights by the controller", "check", "", "", 0.0, "", "On before dawn and after dusk until the day's light reaches the target"],
	["Rain", "rain.gutters", "Gutters", "check", "", "", 0.0, "", "Collect the rain off the roof"],
	["Rain", "rain.cistern_l", "Cistern", "spin", 0.0, 200000.0, 100.0, " L", "Where the gutters run (0 = straight to the barrels)"],
	["Rain", "rain.to_barrels", "Overflow to barrels", "check", "", "", 0.0, "", "Keep the thermal barrels topped up from the roof"],
]


func _build_right() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.right.add_child(box)
	_checks_box = VBoxContainer.new()
	box.add_child(_checks_box)
	box.add_child(SectionHeader.make("Selected bed", ""))
	_bed_box = VBoxContainer.new()
	_bed_box.name = "bed_card"
	_bed_box.add_theme_constant_override("separation", 2)
	box.add_child(_bed_box)
	var sec := ""
	for fv in FIELDS:
		var f: Array = fv
		if str(f[0]) != sec:
			sec = str(f[0])
			box.add_child(SectionHeader.make(sec, ""))
		var key := str(f[1])
		var row: FormRow = null
		match str(f[3]):
			"spin":
				row = FormRow.spin(str(f[2]), float(f[4]), float(f[5]), float(f[6]), str(f[7]),
					func(v: float) -> void: _set_field(key, v), str(f[8]), key.replace(".", "_"))
			"option":
				row = FormRow.option(str(f[2]), _items(str(f[4])), func(v: Variant) -> void: _set_field(key, v),
					str(f[8]), key.replace(".", "_"))
			"check":
				row = FormRow.check(str(f[2]), "", func(on: bool) -> void: _set_field(key, on), str(f[8]),
					key.replace(".", "_"))
		if row != null:
			box.add_child(row)
			_rows[key] = row
	box.add_child(SectionHeader.make("Lighting", ""))
	_light_panel = ModelLightPanel.new()
	_light_panel.bind_studio_night(_studio)
	_light_panel.lights_changed.connect(func() -> void:
		_spec[PropModelLights.KEY_MODEL_LIGHTS] = _light_panel.serialized_items()
		if _col != null:
			_col.set_summary("Lighting", _light_panel.summary_text()))
	box.add_child(_light_panel)
	var auto := Button.new()
	auto.text = "Lay the beds out again"
	auto.name = "beds_auto"
	auto.tooltip_text = "Forget beds moved or drawn by hand and lay them out from the settings above"
	UITheme.style_button(auto)
	auto.pressed.connect(func() -> void:
		_push_undo()
		_spec["beds"]["layout"] = "auto"
		_spec["beds"]["items"] = []
		_rebuild_preview())
	box.add_child(auto)
	var copy := Button.new()
	copy.text = "Copy summary"
	copy.tooltip_text = "Every number and check, as text"
	UITheme.style_button(copy)
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(summary())
		_status.text = "Summary copied.")
	box.add_child(copy)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_status)
	_col = DesignerColumn.setup(box, "greenhouse", {"open": ["Shape", "Selected bed"], "tile_cols": 3})


static func _items(table: String) -> Array:
	var out: Array = []
	match table:
		"forms":
			for f in GreenhouseSpec.FORMS:
				out.append([f, str(GreenhouseSpec.FORM_LABELS[f])])
		"fractions":
			for fr in [[0.375, "3/8"], [0.5, "1/2 (hemisphere)"], [0.625, "5/8"], [0.75, "3/4"]]:
				out.append(fr)
		"glazings":
			for g in GreenhouseMaterials.GLAZING_ORDER:
				out.append([g, str(GreenhouseMaterials.GLAZING[g]["label"])])
		"ends":
			for g in GreenhouseMaterials.GLAZING_ORDER:
				out.append([g, str(GreenhouseMaterials.GLAZING[g]["label"])])
			out.append(["stud", "Opaque insulated ends"])
		"walls":
			for w in GreenhouseMaterials.WALL_ORDER:
				out.append([w, str(GreenhouseMaterials.WALLS[w]["label"])])
		"frames":
			for fm in GreenhouseMaterials.FRAME_ORDER:
				out.append([fm, str(GreenhouseMaterials.FRAMES[fm]["label"])])
		"sides":
			for sv in GreenhouseSpec.SIDE_VENTS:
				out.append([sv, str(GreenhouseSpec.SIDE_VENT_LABELS[sv])])
		"fans":
			for fn in GreenhouseMaterials.FAN_ORDER:
				out.append([fn, str(GreenhouseMaterials.FANS[fn]["label"])])
		"heaters":
			for h in GreenhouseMaterials.HEATER_ORDER:
				out.append([h, str(GreenhouseMaterials.HEATERS[h]["label"])])
		"colours":
			out = [["black", "Black"], ["blue", "Blue"]]
		"berms":
			for b in GreenhouseSpec.BERMS:
				out.append([b, str(GreenhouseSpec.BERM_LABELS[b])])
		"styles":
			for st in GreenhouseSpec.BED_STYLES:
				out.append([st, str(GreenhouseSpec.BED_STYLE_LABELS[st])])
		"spectrums":
			for sp in GreenhouseSpec.SPECTRUMS:
				out.append([sp, str(GreenhouseSpec.SPECTRUM_LABELS[sp])])
		"light_schedules":
			for sc in GreenhouseSpec.LIGHT_SCHEDULES:
				out.append([sc, str(GreenhouseSpec.LIGHT_SCHEDULE_LABELS[sc])])
	return out


# --- fields, undo ---------------------------------------------------------

func _get_path(path: String) -> Variant:
	var parts := path.split(".")
	var cur: Variant = GreenhouseSpec.resolve(_spec)
	for p in parts:
		if not (cur is Dictionary) or not (cur as Dictionary).has(p):
			return null
		cur = (cur as Dictionary)[p]
	return cur


func _set_path(path: String, v: Variant) -> void:
	var parts := path.split(".")
	var cur: Dictionary = _spec
	for i in parts.size() - 1:
		if not (cur.get(parts[i]) is Dictionary):
			cur[parts[i]] = {}
		cur = cur[parts[i]]
	var old: Variant = cur.get(parts[-1])
	if old is int and v is float:
		v = int(v)
	cur[parts[-1]] = v


func _set_field(key: String, v: Variant) -> void:
	if _syncing:
		return
	_push_undo(key)
	_set_path(key, v)
	if key == "form":
		# A new form: its own defaults for size and skin, the beds laid out again.
		var keep_name := str(_spec.get("name", ""))
		_spec = GreenhouseSpec.default_spec(str(v))
		if not keep_name.is_empty():
			_spec["name"] = keep_name
		_load_spec(_spec, false)
		return
	if key == "beds.lights" or key == "beds.gantry":
		# For the whole house: every bed, hand-edited ones too.
		var items: Variant = (_spec.get("beds", {}) as Dictionary).get("items", [])
		if items is Array:
			for it in items:
				(it as Dictionary)[key.substr(5)] = v
	elif key.begins_with("beds.") and key != "beds.feed":
		# Bed settings lay the beds out again.
		_spec["beds"]["layout"] = "auto"
	if _light_panel != null and (key.begins_with("beds.") or key.begins_with("lights.") or key in ["width_m", "length_m", "eave_h_m", "ridge_h_m"]):
		_light_panel.sync_with_spec(_spec, [], key.begins_with("lights."))
		_spec[PropModelLights.KEY_MODEL_LIGHTS] = _light_panel.serialized_items()
	_queue_rebuild()


var _coalesce_key := ""
var _coalesce_until := 0.0


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
	_shell.set_undo_state(not _undo.is_empty(), true)
	_load_spec(_spec, false)


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_spec.duplicate(true))
	_spec = _redo.pop_back()
	_shell.set_undo_state(true, not _redo.is_empty())
	_load_spec(_spec, false)


func _queue_rebuild() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	_rebuild_deferred.call_deferred()


func _rebuild_deferred() -> void:
	_rebuild_pending = false
	_rebuild_preview()


func _sync_rows() -> void:
	_syncing = true
	var s := GreenhouseSpec.resolve(_spec)
	var form := str(s["form"])
	for key in _rows.keys():
		var row: FormRow = _rows[key]
		var v: Variant = _get_path(str(key))
		if row.control is OptionButton:
			FormRow.select_meta(row.control as OptionButton, v)
		elif row.control is CheckBox:
			(row.control as CheckBox).set_pressed_no_signal(bool(v))
		elif v != null:
			row.set_value(float(v))
		# Rows that only mean something for some forms.
		var vis := true
		match str(key):
			"front_h_m", "back_wall":
				vis = form == "lean_to"
			"dome.frequency", "dome.fraction":
				vis = form == "dome"
			"length_m", "eave_h_m", "ridge_h_m", "bay_m":
				vis = form != "dome"
			"vents.side_h_m":
				vis = str(s["vents"]["sides"]) != "none"
			"vents.ridge_w_m":
				vis = bool(s["vents"]["ridge"])
			"mass.litres_each", "mass.colour":
				vis = int(s["mass"]["barrels"]) > 0
		row.visible = vis
	_shell.name_edit.text = str(s["name"])
	_syncing = false


# --- gallery --------------------------------------------------------------

func _refresh_list() -> void:
	_list.clear()
	_ids.clear()
	_list.add_caption("Built-in")
	for b in GreenhousePresets.builtins():
		_list.add_item(str(b["name"]))
		_list.set_item_subtitle(_list.item_count - 1, size_line(b["spec"]))
		_list.set_item_tooltip(_list.item_count - 1, str(b["blurb"]))
		_ids.append(str(b["id"]))
	var lib := GreenhousePresets.load_library()
	if not lib.is_empty():
		_list.add_caption("Yours")
		for d in lib:
			_list.add_item(DesignGallery.MINE_PREFIX + str((d as Dictionary).get("name", "")))
			_list.set_item_subtitle(_list.item_count - 1, size_line(d["spec"]))
			_ids.append("lib:" + str((d as Dictionary).get("id", "")))


static func size_line(spec: Dictionary) -> String:
	var s := GreenhouseSpec.resolve(spec)
	if str(s["form"]) == "dome":
		return "dome Ø%s" % UiText.num(float(s["width_m"]), "m", 3)
	return "%s × %s %s" % [UiText.num(float(s["width_m"]), "m", 3), UiText.num(float(s["length_m"]), "m", 3),
		str(s["form"]).replace("_", "-")]


func _spec_for_id(id: String) -> Dictionary:
	if id.begins_with("lib:"):
		for d in GreenhousePresets.load_library():
			if "lib:" + str((d as Dictionary).get("id", "")) == id:
				return GreenhouseSpec.resolve(d["spec"])
		return {}
	var b := GreenhousePresets.builtin(id)
	return b.get("spec", {}) as Dictionary


func _thumb_for(i: int) -> Dictionary:
	if i < 0 or i >= _ids.size() or str(_ids[i]).is_empty():
		return {}
	var spec := _spec_for_id(str(_ids[i]))
	return {"key": GreenhouseSpec.key_of(spec), "build": func() -> Node3D:
		return GreenhouseBuilder.build_node(spec, "Thumb")}


func _on_list_selected(idx: int) -> void:
	if idx < 0 or idx >= _ids.size() or str(_ids[idx]).is_empty():
		return
	var spec := _spec_for_id(str(_ids[idx]))
	if not spec.is_empty():
		_push_undo()
		_load_spec(spec)


func select_design(id: String) -> bool:
	var i := _ids.find(id)
	if i < 0:
		return false
	_on_list_selected(i)
	return true


func _load_spec(spec: Dictionary, frame: bool = true) -> void:
	_spec = GreenhouseSpec.resolve(spec)
	_selected_bed = ""
	_sync_rows()
	if _light_panel != null:
		_light_panel.load_from_context(_main() if frame else null, _prop_id if frame else "", GreenhouseBuilder.MODEL_ID, _spec)
	_rebuild_preview()
	if frame:
		_frame()


# --- preview --------------------------------------------------------------

## The shell with its beds, gantries and lights standing in it (crops grown
## GROW_DAYS), and the earth it asks for when sunk or bermed.
func _preview_node(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "GreenhousePreview"
	var d := GreenhouseDesign.solve(spec)
	var shell := GreenhouseBuilder.build_from_design(d, "Greenhouse", {"cutaway": _roof_off})
	_shell_3d = shell
	root.add_child(shell)
	GreenhouseBuilder.set_vents(shell, 0.4)
	var sink := float(d["spec"]["ground"]["sink_m"])
	shell.position.y = -sink
	if _light_panel != null:
		_light_panel.attach_preview(shell)
		if _col != null:
			_col.set_summary("Lighting", _light_panel.summary_text())
	if _show_parts:
		for p in GreenhouseParts.parts(d):
			var pd: Dictionary = p
			var n := ModelCatalog.instantiate(str(pd["model_id"]), pd["extra"])
			if n == null:
				continue
			n.position = Vector3(float(pd["x"]), float(pd["y"]) - sink, float(pd["z"]))
			n.rotation.y = deg_to_rad(float(pd["yaw_deg"]))
			root.add_child(n)
			if str(pd["model_id"]) == GrowLightRack.MODEL_ID:
				GrowLightRack.set_lit(n, true, 0.6)
			n.set_process(false)
			for mi in n.find_children("*", "MultiMeshInstance3D", true, false):
				var m := (mi as MultiMeshInstance3D).material_override
				if m is ShaderMaterial:
					(m as ShaderMaterial).set_shader_parameter("now_d", GROW_DAYS)
	var ew := GreenhouseWorld.earthworks(d)
	if not ew.is_empty():
		var earth: MeshInstance3D = load("res://scenes/ui/earthshiplab_modal.gd").earth_mesh(ew)
		earth.position.y = 0.0
		root.add_child(earth)
		if _studio.ground != null:
			_studio.ground.visible = false
	elif _studio.ground != null:
		_studio.ground.visible = true
	return root


func _rebuild_preview() -> void:
	_design = GreenhouseDesign.solve(_spec)
	_studio.show_node(_preview_node(_spec))
	_refresh_summary()
	_refresh_bed_card()
	_refresh_bill()
	_plan.queue_redraw()


func _frame() -> void:
	var s := GreenhouseSpec.resolve(_spec)
	var d := GreenhouseDesign.solve(s)
	var L := float(s["length_m"])
	var W := float(s["width_m"])
	var H := float(d["stats"]["height_m"])
	_studio.reset_orbit()
	_studio.frame_aabb(AABB(Vector3(-L * 0.5, 0.0, -W * 0.5), Vector3(L, H, W)), 0.4, 1.2)
	_studio.place_person(W * 0.5 + 2.0)


func _refresh_summary() -> void:
	var d := _design
	var st: Dictionary = d["stats"]
	if _col != null:
		var yr := year_result()
		var year_tiles: Array = []
		if not yr.is_empty():
			var yt: Dictionary = yr["total"]
			year_tiles = [
				{"caption": "Coldest night", "value": "%.0f °C" % float(yt["coldest_in"]),
					"tip": "Inside, over the year at this site (outside %.0f °C)" % float(yt["coldest_out"])},
				{"caption": "Harvest / yr", "value": UiText.num(float(yt["yield_kg"]), "kg", 3),
					"tip": "From the Climate tab's year"}]
		_col.set_tiles(year_tiles + [
			{"caption": "Floor", "value": UiText.num(float(st["floor_area_m2"]), "m²", 3),
				"tip": "%s of it in beds" % UiText.pct(float(st["bed_share"]))},
			{"caption": "Beds", "value": UiText.num(float(st["bed_area_m2"]), "m²", 3),
				"tip": UiText.count(int(st["beds"]), "bed")},
			{"caption": "Vents", "value": UiText.pct(float(st["vent_share"])), "tip": "Vent area ÷ floor (15–25 % is the rule of thumb)"},
			{"caption": "Heat loss", "value": UiText.num(float(st["ua_w_k"]), "W", 3) + "/°C",
				"tip": "Through the skin for every degree inside is warmer than out (U × A)"},
			{"caption": "Water mass", "value": UiText.num(float(st["water_mass_l"]), "L", 3),
				"tip": UiText.count(int(st["barrels"]), "barrel")},
			{"caption": "Cost", "value": "$" + UiText.thousands(int(roundf(GreenhouseDesign.cost_usd(d)))),
				"tip": "Frame, skin, vents, fans, barrels, gutters, cistern, lights (estimates)"}])
	for c2 in _checks_box.get_children():
		_checks_box.remove_child(c2)
		c2.queue_free()
	var warns := 0
	for chk in d["checks"]:
		var l := Label.new()
		var lvl := str(chk["level"])
		l.text = ("⚠ " if lvl != "info" else "· ") + str(chk["text"])
		l.tooltip_text = str(chk.get("why", ""))
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_WARN if lvl != "info" else UITheme.C_TEXT_S)
		_checks_box.add_child(l)
		if lvl != "info":
			warns += 1
	_shell.set_badge(UiText.count(warns, "warning") if warns > 0 else "Checks pass", "warn" if warns > 0 else "ok")
	_shell.set_subtitle("%s · %s" % [size_line(_spec), UiText.num(float(st["height_m"]), "m", 2) + " tall"])


func _refresh_bill() -> void:
	for c in _bill.get_children():
		_bill.remove_child(c)
		c.queue_free()
	for r in _design["bom"]:
		var rd: Dictionary = r
		var txt := "%s · %s · %s" % [UiText.num(float(rd["kg"]), "kg", 3), "$" + UiText.thousands(int(roundf(float(rd["usd"])))),
			("" if bool(rd.get("total", false)) else "%s %s" % [UiText.num(float(rd["qty"]), "", 3), str(rd["unit"])])]
		var row := FormRow.value(str(rd["item"]), txt.strip_edges(), "")
		_bill.add_child(row)


# --- beds -------------------------------------------------------------------

## The beds as laid out now, kept as the design's own (custom layout) so they
## can be moved and edited one by one.
func _take_beds() -> Array:
	var items: Array = []
	for b in _design["beds"]:
		var bd: Dictionary = b
		var it := {"id": str(bd["id"]), "kind": str(bd["kind"]), "x": float(bd["x"]), "z": float(bd["z"]),
			"length_m": float(bd["length_m"]), "width_m": float(bd["width_m"]), "crops": bd["crops"],
			"gantry": bool(bd.get("gantry", false)), "lights": bool(bd.get("lights", false))}
		if bd.has("keyhole"):
			it["keyhole"] = (bd["keyhole"] as Dictionary).duplicate()
		items.append(it)
	return items


func _edit_beds(fn: Callable) -> void:
	_push_undo()
	var items := _take_beds()
	fn.call(items)
	for it in items:
		_clamp_bed(it as Dictionary)
	_spec["beds"]["layout"] = "custom"
	_spec["beds"]["items"] = items
	if _light_panel != null:
		_light_panel.sync_with_spec(_spec)
		_spec[PropModelLights.KEY_MODEL_LIGHTS] = _light_panel.serialized_items()
	_rebuild_preview()


## Keep a bed on the floor: inside the walls of a tunnel, inside a dome's ring.
func _clamp_bed(it: Dictionary) -> void:
	var s := GreenhouseSpec.resolve(_spec)
	var fr: Dictionary = _design["frame"]
	if str(fr["floor"]["kind"]) == "circle":
		var R := float(fr["floor"]["r"]) - 0.1
		var reach := float(it.get("keyhole", {}).get("outer_r", 0.0)) if str(it["kind"]) == "keyhole" 			else Vector2(float(it["length_m"]), float(it["width_m"])).length() * 0.5
		var c := Vector2(float(it["x"]), float(it["z"]))
		if c.length() + reach > R:
			c = c.normalized() * maxf(R - reach, 0.0) if c.length() > 1e-6 else c
		it["x"] = c.x
		it["z"] = c.y
		return
	var hl := float(s["length_m"]) * 0.5
	var hw := float(s["width_m"]) * 0.5
	it["length_m"] = minf(float(it["length_m"]), hl * 2.0 - 0.2)
	it["width_m"] = minf(float(it["width_m"]), hw * 2.0 - 0.2)
	var ml := hl - float(it["length_m"]) * 0.5 - 0.05
	var mw := hw - float(it["width_m"]) * 0.5 - 0.05
	it["x"] = clampf(float(it["x"]), -ml, ml)
	it["z"] = clampf(float(it["z"]), -mw, mw)


func select_bed(id: String) -> void:
	_selected_bed = id
	_refresh_bed_card()
	_plan.queue_redraw()


func selected_bed() -> String:
	return _selected_bed


func move_bed(id: String, x: float, z: float) -> void:
	_edit_beds(func(items: Array) -> void:
		for it in items:
			if str(it["id"]) == id:
				it["x"] = x
				it["z"] = z)


func add_bed(rect: Rect2) -> String:
	var nid := "b%d" % (_design["beds"].size() + 1)
	var used := {}
	for b in _design["beds"]:
		used[str(b["id"])] = true
	var k := (_design["beds"] as Array).size() + 1
	while used.has("b%d" % k):
		k += 1
	nid = "b%d" % k
	_edit_beds(func(items: Array) -> void:
		items.append({"id": nid, "kind": "rect", "x": rect.get_center().x, "z": rect.get_center().y,
			"length_m": maxf(rect.size.x, 0.4), "width_m": maxf(rect.size.y, 0.3), "crops": "garden",
			"gantry": false, "lights": false}))
	_selected_bed = nid
	_refresh_bed_card()
	return nid


func remove_bed(id: String) -> void:
	_edit_beds(func(items: Array) -> void:
		for i in range(items.size() - 1, -1, -1):
			if str(items[i]["id"]) == id:
				items.remove_at(i))
	_selected_bed = ""
	_refresh_bed_card()


func set_bed_field(id: String, key: String, v: Variant) -> void:
	_edit_beds(func(items: Array) -> void:
		for it in items:
			if str(it["id"]) == id:
				it[key] = v)


func _bed(id: String) -> Dictionary:
	for b in _design.get("beds", []):
		if str(b["id"]) == id:
			return b
	return {}


func _refresh_bed_card() -> void:
	for c in _bed_box.get_children():
		_bed_box.remove_child(c)
		c.queue_free()
	var bd := _bed(_selected_bed)
	if bd.is_empty():
		var l := Label.new()
		l.text = "Click a bed on the Plan to set its crops, gantry and lights."
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_bed_box.add_child(l)
		return
	var id := str(bd["id"])
	_bed_box.add_child(FormRow.value("Bed", "%s · %s · %s headroom" % [id, UiText.num(float(bd["area_m2"]), "m²", 3),
		UiText.num(float(bd["headroom_m"]), "m", 2)], "Its area and the clear height over its soil at the low side"))
	if str(bd["kind"]) == "rect":
		_bed_box.add_child(FormRow.spin("Length", 0.4, 60.0, 0.1, " m", func(v: float) -> void: set_bed_field(id, "length_m", v),
			"", "bed_length"))
		(_bed_box.get_child(-1) as FormRow).set_value(float(bd["length_m"]))
		_bed_box.add_child(FormRow.spin("Width", 0.3, 6.0, 0.05, " m", func(v: float) -> void: set_bed_field(id, "width_m", v),
			"", "bed_width"))
		(_bed_box.get_child(-1) as FormRow).set_value(float(bd["width_m"]))
	var g := FormRow.check("FarmBot", "A gantry works this bed", func(on: bool) -> void: set_bed_field(id, "gantry", on), "", "bed_gantry")
	(g.control as CheckBox).set_pressed_no_signal(bool(bd.get("gantry", false)))
	_bed_box.add_child(g)
	var lt := FormRow.check("Grow lights", "An LED rack over it", func(on: bool) -> void: set_bed_field(id, "lights", on), "", "bed_lights")
	(lt.control as CheckBox).set_pressed_no_signal(bool(bd.get("lights", false)))
	_bed_box.add_child(lt)
	# The crop mix: one row per crop with its share.
	var mix: Array = []
	if bd["crops"] is Array:
		mix = (bd["crops"] as Array).duplicate(true)
	var garden := FormRow.check("Mixed garden", "The garden rotation", func(on: bool) -> void:
		if on:
			set_bed_field(id, "crops", "garden")
		else:
			set_bed_field(id, "crops", [{"crop": "lettuce", "share": 1.0}]), "", "bed_garden")
	(garden.control as CheckBox).set_pressed_no_signal(not (bd["crops"] is Array))
	_bed_box.add_child(garden)
	for i in mix.size():
		var e: Dictionary = mix[i]
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 4)
		var o := OptionButton.new()
		o.name = "bed_crop_%d" % i
		var j := 0
		for cid in GardenCrops.CROPS.keys():
			o.add_item(str(GardenCrops.CROPS[cid]["label"]), j)
			o.set_item_metadata(j, str(cid))
			j += 1
		FormRow.select_meta(o, str(e["crop"]))
		o.fit_to_longest_item = false
		o.clip_text = true
		o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		o.item_selected.connect(func(k: int) -> void:
			var m2 := mix.duplicate(true)
			m2[i]["crop"] = str(o.get_item_metadata(k))
			set_bed_field(id, "crops", m2))
		h.add_child(o)
		var sp := SpinBox.new()
		sp.name = "bed_share_%d" % i
		sp.min_value = 1
		sp.max_value = 100
		sp.suffix = "%"
		sp.custom_minimum_size = Vector2(80, 0)
		sp.set_value_no_signal(roundf(float(e["share"]) * 100.0))
		sp.value_changed.connect(func(v: float) -> void:
			var m3 := mix.duplicate(true)
			m3[i]["share"] = v / 100.0
			set_bed_field(id, "crops", m3))
		h.add_child(sp)
		var rm := IconButton.make("x", "Remove this crop", func() -> void:
			var m4 := mix.duplicate(true)
			m4.remove_at(i)
			set_bed_field(id, "crops", m4 if not m4.is_empty() else "garden"))
		h.add_child(rm)
		_bed_box.add_child(h)
	if not mix.is_empty():
		var add := Button.new()
		add.text = "Add a crop"
		add.name = "bed_add_crop"
		UiIcons.apply(add, "plus", "Add a crop to this bed")
		UITheme.style_button(add)
		add.pressed.connect(func() -> void:
			var m5 := mix.duplicate(true)
			m5.append({"crop": "kale", "share": 1.0 / float(m5.size() + 1)})
			set_bed_field(id, "crops", m5))
		_bed_box.add_child(add)
	var del := Button.new()
	del.text = "Remove this bed"
	del.name = "bed_remove"
	UITheme.style_button(del)
	del.pressed.connect(func() -> void: remove_bed(id))
	_bed_box.add_child(del)


# --- actions --------------------------------------------------------------

func _main() -> Node:
	var tree := get_tree()
	var main: Node = tree.get_first_node_in_group("main_scene")
	if main == null:
		main = tree.current_scene
	return main


func _on_save() -> void:
	var name := _shell.name_edit.text.strip_edges()
	if name.is_empty():
		name = "My greenhouse"
	_spec["name"] = name
	var lib := GreenhousePresets.load_library()
	var id := name.to_lower().replace(" ", "_").left(40)
	var found := false
	for d in lib:
		if str(d["id"]) == id:
			d["spec"] = _spec.duplicate(true)
			d["name"] = name
			found = true
	if not found:
		lib.append({"id": id, "name": name, "spec": _spec.duplicate(true)})
	GreenhousePresets.save_library(lib)
	_refresh_list()
	_status.text = I18n.f("Saved {name}.", {"name": name})


func _on_place() -> void:
	var main := _main()
	var js := GreenhouseSpec.to_json_safe(current_spec())
	var res: Dictionary = PlacedPropService.begin_placement(main, GreenhouseBuilder.MODEL_ID,
		{"record_extra": {GreenhouseSpec.KEY: js,
			PropModelLights.KEY_MODEL_LIGHTS: _light_panel.serialized_items() if _light_panel != null else [],
			"collision_enabled": true, "walk_in": true}})
	if bool(res.get("ok", false)):
		close()
	else:
		_status.text = I18n.f("Could not place: {error}", {"error": str(res.get("error", "no world"))})


func _on_apply() -> void:
	if _prop_id.is_empty():
		return
	var main := _main()
	var js := GreenhouseSpec.to_json_safe(current_spec())
	PlacedPropService.update_prop_record(main, _prop_id, {GreenhouseSpec.KEY: js}, true)
	GreenhouseWorld.sync(main, _prop_id)
	if _light_panel != null:
		PropModelLights.sync_prop(main, _prop_id, _light_panel.items(), true)
	_status.text = "Applied to the placed greenhouse."


func _on_crew() -> void:
	var r := CrewBuildRequest.queue_design(_main(), GreenhouseBuilder.MODEL_ID,
		{GreenhouseSpec.KEY: GreenhouseSpec.to_json_safe(_spec), "walk_in": true})
	_status.text = str(r.get("message", "Handed to a crew." if bool(r.get("ok", false)) else "No crew could take it."))


## Every number and check, as text.
func summary() -> String:
	var s := GreenhouseSpec.resolve(_spec)
	var st: Dictionary = _design["stats"]
	var lines: Array = []
	lines.append("%s — %s, %s tall" % [str(s["name"]), size_line(s), UiText.num(float(st["height_m"]), "m", 2)])
	lines.append("Floor %s, beds %s (%d), glazing %s, earth-sheltered %s" % [UiText.num(float(st["floor_area_m2"]), "m²", 3),
		UiText.num(float(st["bed_area_m2"]), "m²", 3), int(st["beds"]), UiText.num(float(st["glazed_m2"]), "m²", 3),
		UiText.num(float(st["earth_m2"]), "m²", 3)])
	lines.append("Heat loss %s W/°C, vents %s of the floor, fans %s m³/s, water mass %s L" % [UiText.num(float(st["ua_w_k"]), "", 3),
		UiText.pct(float(st["vent_share"])), UiText.num(float(st["fan_m3s"]), "", 3), UiText.num(float(st["water_mass_l"]), "", 3)])
	lines.append("Cost $%s, %s" % [UiText.thousands(int(GreenhouseDesign.cost_usd(_design))), UiText.num(GreenhouseDesign.mass_kg(_design), "kg", 3)])
	for c in _design["checks"]:
		lines.append("[%s] %s" % [str(c["level"]), str(c["text"])])
	return "\n".join(lines)


# --- the Climate tab ------------------------------------------------------

func _build_climate_view() -> void:
	var sc := ScrollContainer.new()
	sc.name = "climate_view"
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.visible = false
	_views.add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	sc.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	_climate_line = Label.new()
	_climate_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_climate_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_climate_line.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	head.add_child(_climate_line)
	_climate_btn = Button.new()
	_climate_btn.name = "climate_run"
	_climate_btn.text = "Run the year"
	_climate_btn.tooltip_text = "Step this design through a year of weather at the site, hour by hour"
	UITheme.style_button(_climate_btn)
	_climate_btn.pressed.connect(func() -> void: _start_year(true))
	head.add_child(_climate_btn)
	_climate_chart = GreenhouseClimateChart.new()
	_climate_chart.name = "climate_chart"
	_climate_chart.custom_minimum_size = Vector2(320, 260)
	_climate_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_climate_chart)
	_climate_box = VBoxContainer.new()
	_climate_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_climate_box)


## The site the year is run at: the world's, else 45°N.
func _site() -> Dictionary:
	var main := _main()
	var lat := 45.0
	var lon := -120.0
	var yaw := 0.0
	var where := "45°N (no world open)"
	if main != null and main.get("latitude") != null:
		lat = float(main.get("latitude"))
		lon = float(main.get("longitude"))
		where = "this site (%s)" % SitePrivacy.coords(lat, lon, 1)
	if not _prop_id.is_empty():
		yaw = float(PlacedPropService.get_prop_record(main, _prop_id).get("yaw", 0.0))
	return {"lat": lat, "lon": lon, "yaw": yaw, "where": where}


func _climate_key() -> String:
	var s := _site()
	return "%s|%.3f|%.3f|%.1f" % [GreenhouseSpec.key_of(_spec), float(s["lat"]), float(s["lon"]), float(s["yaw"])]


func _weather_for(lat: float, lon: float) -> Dictionary:
	var ws := get_node_or_null("/root/WeatherService")
	var real := ws != null and bool(ws.call("has_data")) and bool(ws.call("covers", lat, lon))
	var k := "%.3f_%.3f_%s" % [lat, lon, str(real)]
	if not _wx_cache.has(k):
		_wx_cache.clear()
		_wx_cache[k] = GreenhouseYear.weather_table(lat, lon, ws if real else null)
	return _wx_cache[k]


func _start_year(force: bool = false) -> void:
	if _year_task >= 0:
		if not force:
			return
		_stop_year()
	var key := _climate_key()
	if key == _year_key and not force and not _year_result.is_empty():
		return
	var s := _site()
	var tbl := _weather_for(float(s["lat"]), float(s["lon"]))
	var job := {"stop": false, "progress": 0.0, "result": {}, "key": key}
	_year_job = job
	var d := _design.duplicate(true)
	var yaw := float(s["yaw"])
	_year_task = WorkerThreadPool.add_task(func() -> void:
		job["result"] = GreenhouseYear.run(d, tbl, {"yaw_deg": yaw,
			"cancel": func() -> bool: return bool(job["stop"]),
			"progress": func(f: float) -> void: job["progress"] = f}))
	_climate_btn.disabled = true
	_climate_line.text = I18n.f("Running a year at {where}…", {"where": str(s["where"])})


func _stop_year() -> void:
	if _year_task < 0:
		return
	_year_job["stop"] = true
	WorkerThreadPool.wait_for_task_completion(_year_task)
	_year_task = -1
	if _climate_btn != null:
		_climate_btn.disabled = false


func _exit_tree() -> void:
	_stop_year()


func _process(delta: float) -> void:
	if not _open:
		return
	if _year_wait > 0.0:
		_year_wait -= delta
		if _year_wait <= 0.0 and _tabs.current_tab == 2:
			_start_year()
	if _year_task < 0:
		return
	if not WorkerThreadPool.is_task_completed(_year_task):
		_climate_line.text = I18n.f("Running a year… {progress}", {"progress": UiText.pct(float(_year_job.get("progress", 0.0)))})
		return
	WorkerThreadPool.wait_for_task_completion(_year_task)
	_year_task = -1
	_climate_btn.disabled = false
	var r: Dictionary = _year_job.get("result", {})
	if r.is_empty() or bool(r.get("cancelled", false)):
		return
	_year_result = r
	_year_key = str(_year_job["key"])
	_show_year()
	_refresh_summary()


## The year for the design as it is now ({} until it has run; the harness
## waits on it).
func year_result() -> Dictionary:
	return _year_result if _year_key == _climate_key() else {}


func _show_year() -> void:
	var r := _year_result
	var tot: Dictionary = r["total"]
	var s := _site()
	_climate_chart.set_data(r["daily"])
	var src := "real weather" if bool(r["real_weather"]) else "a made-up year for the latitude (no weather loaded)"
	_climate_line.text = I18n.f("A year at {where}, {src}. Coldest hour inside {coldest_in} °C (outside {coldest_out} °C), hottest {hottest_in} °C.", {
		"where": str(s["where"]),
		"src": src,
		"coldest_in": "%.0f" % float(tot["coldest_in"]),
		"coldest_out": "%.0f" % float(tot["coldest_out"]),
		"hottest_in": "%.0f" % float(tot["hottest_in"]),
	})
	for c in _climate_box.get_children():
		_climate_box.remove_child(c)
		c.queue_free()
	_climate_box.add_child(SectionHeader.make("The year"))
	var rows := [
		["Days below 0 °C inside", UiText.count(int(tot["frost_d"]), "day")],
		["Hours over 35 °C inside", UiText.num(float(tot["hot_h"]), "h", 3)],
		["Vents open", UiText.num(float(tot["vent_h"]), "h", 3)],
		["Fans running", UiText.num(float(tot["fan_h"]), "h", 3)],
		["Heater running", UiText.num(float(tot["heater_h"]), "h", 3)],
		["Electricity", UiText.num(float(tot["power_kwh"]) * 1000.0, "Wh", 3)],
		["Of it, grow lights", UiText.num(float(tot["lights_kwh"]) * 1000.0, "Wh", 3)],
		["Propane", UiText.num(float(tot["propane_kg"]), "kg", 3)],
		["Rain off the roof", UiText.num(float(tot["rain_l"]), "L", 3)],
		["Water the beds use", UiText.num(float(tot["water_l"]), "L", 3)],
		["Condensation on the glazing", UiText.num(float(tot["cond_l"]), "L", 3)],
		["Harvest", "%s (%s/m² of bed)" % [UiText.num(float(tot["yield_kg"]), "kg", 3), UiText.num(float(tot["yield_kg_m2"]), "kg", 2)]],
		["Plantings lost to frost", str(int(tot["lost"]))],
	]
	for rw in rows:
		_climate_box.add_child(FormRow.value(str(rw[0]), str(rw[1]), ""))
	var harvest: Dictionary = tot["harvest"]
	if not harvest.is_empty():
		_climate_box.add_child(SectionHeader.make("Harvest by crop"))
		var ids := harvest.keys()
		ids.sort_custom(func(a, b) -> bool: return float(harvest[a]) > float(harvest[b]))
		for id in ids:
			var lbl := str(GardenCrops.CROPS.get(str(id), {}).get("label", UiText.from_id(str(id))))
			_climate_box.add_child(FormRow.value(lbl, UiText.num(float(harvest[id]), "kg", 3), ""))
	_climate_box.add_child(SectionHeader.make("By month"))
	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 14)
	_climate_box.add_child(grid)
	for h in ["Month", "Inside", "Outside", "Light", "Vents", "Heater", "Rain", "Harvest"]:
		grid.add_child(_cell(h, true))
	for mo in r["months"]:
		var md: Dictionary = mo
		grid.add_child(_cell(GreenhouseClimateChart.MONTHS[int(md["month"]) - 1]))
		grid.add_child(_cell("%.0f to %.0f °C" % [float(md["in_min"]), float(md["in_max"])]))
		grid.add_child(_cell("%.0f to %.0f °C" % [float(md["out_min"]), float(md["out_max"])]))
		grid.add_child(_cell("%.0f mol/m²·d" % float(md["dli"])))
		grid.add_child(_cell(UiText.num(float(md["vent_h"]), "h", 3)))
		grid.add_child(_cell(UiText.num(float(md["heater_h"]), "h", 3)))
		grid.add_child(_cell(UiText.num(float(md["rain_l"]), "L", 2)))
		grid.add_child(_cell(UiText.num(float(md["yield_kg"]), "kg", 2)))


func _cell(txt: String, head: bool = false) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM if head else UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT if head else UITheme.C_TEXT_S)
	return l
