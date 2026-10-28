extends Control

## The Solar designer: parametric digital twins of real solar modules, and
## the arrays, strings and racks they go into.
##
## Cell tab:  one cell up close — technology, wafer format and cut, busbars
##            and fingers, colour, sheen, crystal flake — with its electrics.
## Panel tab: the module front, back and side — exact size in mm, build type,
##            cell layout, frame, backsheet, glass, junction boxes, leads and
##            connector, bypass diodes — its I–V and P–V curves, derived from
##            its cells or typed in from the data sheet.
## Array tab: rows of modules on a rack (2x4s, Unistrut, aluminium rail; ground,
##            roof, ballast, pole or a single-axis tracker), strings painted by
##            clicking modules, a controller window, and live A / V / W per
##            string and per MPPT input — under a test shadow if you like,
##            with the I–V curve's two peaks to show what it costs.
## Left:      built-in arrays and modules, and the player's library.
## Footer:    place a new array in the world, or apply to the placed one.
##
## Everything reads one solved PvLabDesign, so the studio, the tables, the
## files and the graph agree.

const MODAL_NAME := "pvlab_designer"
const WANT := Vector2(1640, 980)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.15
const EXPORT_ROOT := "user://pvlab_designs"
const SHADE_TESTS := [["none", "No shade"], ["edge", "Shadow along the front row's bottom edge"],
	["module", "One module in shade"], ["pole", "A pole's shadow across the array"],
	["leaf", "A leaf on one cell"]]
const SHADED_SHARE := 0.2

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
var _built_key := ""
var _suppress := false
var _bindings: Array = []
var _library := {"modules": [], "designs": []}
var _entries: Array = []

var _tab := 2
var _show_back := false
var _painting := false
var _paint_string := 0
var _shade_test := "none"
var _chart_g := 1000.0
var _chart_t := 25.0
var _tracker_preview := 0.0
var _color_strings := true
var _picked := -1
var _hover_frame := 0
## The Array tab's selection: "panel" | "member" | "part" and its index;
## _sel_all lights every one like it.
var _sel_kind := ""
var _sel_index := -1
var _sel_all := false
var _show_modules := true
var _search_edit: LineEdit
var _search_count: Label
var _part_box: VBoxContainer
var _part_section: Control
var _modules_btn: Button

# UI
var _panel: PanelContainer
var _name_edit: LineEdit
var _subtitle: Label
var _undo_btn: Button
var _redo_btn: Button
var _list: ItemList
var _tabs: TabBar
var _vp_container: SubViewportContainer
var _viewport: SubViewport
var _studio: Node3D
var _holder: Node3D
var _camera: Camera3D
var _chart: Control
var _bar_cell: HBoxContainer
var _bar_panel: HBoxContainer
var _bar_array: HFlowContainer
var _paint_btn: Button
var _hover_lbl: Label
var _cell_group: VBoxContainer
var _panel_group: VBoxContainer
var _array_group: VBoxContainer
var _cell_box: VBoxContainer
var _layout_box: VBoxContainer
var _frame_box: VBoxContainer
var _jbox_box: VBoxContainer
var _fold_box: VBoxContainer
var _elec_box: VBoxContainer
var _arr_box: VBoxContainer
var _rack_box: VBoxContainer
var _tracker_box: VBoxContainer
var _tracker_section: Control
var _string_box: VBoxContainer
var _target_box: VBoxContainer
var _live_box: VBoxContainer
var _warn_box: VBoxContainer
var _bom_lbl: Label
var _bom_box: VBoxContainer
var _export_status: Label
var _apply_btn: Button
var _place_btn: Button
var _file_dialog: FileDialog

# Studio camera
var _yaw := 0.7
var _pitch := 0.45
var _dist := 10.0
var _target := Vector3(0, 1.0, 0)
var _orbiting := false
var _press_pos := Vector2.ZERO
var _moved := false


func bind_loader(loader: Node) -> void:
	_loader = loader


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process(false)


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func open(spec: Dictionary = {}) -> void:
	if _active:
		return
	_bound_prop_id = ""
	_spec = PvLabSpec.resolve(spec if not spec.is_empty() else PvLabPresets.builtin("backyard_2x4")["spec"])
	_activate()


func open_for_prop(prop_id: String) -> void:
	if _active or prop_id.is_empty():
		return
	var rec := _prop_record(prop_id)
	var spec: Dictionary = rec.get("pvlab_spec", {}) as Dictionary
	_bound_prop_id = prop_id
	_spec = PvLabSpec.resolve(spec if not spec.is_empty() else PvLabPresets.builtin("backyard_2x4")["spec"])
	# The graph may have been rewired inside the array: take its strings.
	var gs := _graph_strings()
	if not gs.is_empty():
		var flat: Array = []
		var groups: Array = []
		for g in gs:
			var gi: Array = []
			for st in g:
				gi.append(flat.size())
				flat.append(st)
			groups.append(gi)
		var cur: Array = PvLabDesign.solve(_spec)["strings"]
		if str(flat) != str(cur):
			_spec["strings"]["mode"] = "custom"
			_spec["strings"]["custom"] = flat
			_spec["strings"]["groups"] = groups
	_activate()


func is_open() -> bool:
	return _active


func _activate() -> void:
	_undo.clear()
	_redo.clear()
	_painting = false
	_picked = -1
	_sel_kind = ""
	_sel_index = -1
	_library = PvLabPresets.load_library()
	var main := _main_node()
	if main != null and _bound_prop_id.is_empty() and main.get("latitude") != null:
		_spec["array"]["site_lat"] = float(main.get("latitude"))
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	UiFit.keep_fitted(_panel, WANT)
	_apply_btn.visible = not _bound_prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _bound_prop_id.is_empty() else "Place in world"
	_refresh_list()
	_built_key = ""
	_rebuild_now()
	_frame_camera()


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


func _process(delta: float) -> void:
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
	if focus is LineEdit or focus is TextEdit:
		return
	if ke.keycode == KEY_Z and ke.ctrl_pressed and not ke.shift_pressed:
		_undo_step()
		get_viewport().set_input_as_handled()
	elif (ke.keycode == KEY_Y and ke.ctrl_pressed) or (ke.keycode == KEY_Z and ke.ctrl_pressed and ke.shift_pressed):
		_redo_step()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	add_child(_panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_panel.add_child(root)
	root.add_child(_build_header())
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UITheme.SPACE_MD)
	root.add_child(body)
	body.add_child(_build_left())
	body.add_child(_build_centre())
	body.add_child(_build_right())
	root.add_child(_build_footer())
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.title = "Choose a folder for the array's files"
	_file_dialog.dir_selected.connect(func(dir): _write_files(dir.path_join(DomeLabCam.safe_name(str(_spec["name"])))))
	add_child(_file_dialog)


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var icon := TextureRect.new()
	icon.texture = UiIcons.icon("sun", 22)
	icon.modulate = UITheme.C_AMBER
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(icon)
	var title := Label.new()
	title.text = "Solar designer"
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title.add_theme_color_override("font_color", UITheme.C_TEXT)
	row.add_child(title)
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(240, 0)
	_name_edit.placeholder_text = "Array name"
	_name_edit.text_submitted.connect(func(_t): _on_name_changed())
	_name_edit.focus_exited.connect(_on_name_changed)
	row.add_child(_name_edit)
	_subtitle = Label.new()
	_subtitle.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_subtitle.clip_text = true
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_subtitle)
	_undo_btn = IconButton.make("undo-2", "Undo (Ctrl+Z)", _undo_step)
	row.add_child(_undo_btn)
	_redo_btn = IconButton.make("redo-2", "Redo (Ctrl+Y)", _redo_step)
	row.add_child(_redo_btn)
	row.add_child(IconButton.close(close))
	return row


func _scroll_column(width: float) -> Array:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(width, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	scroll.add_child(box)
	return [scroll, box]


func _build_left() -> Control:
	var col := _scroll_column(250)
	var box: VBoxContainer = col[1]
	box.add_child(SectionHeader.make("Arrays and modules", "layout-grid"))
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search panels and arrays (maker, model, watts…)"
	_search_edit.clear_button_enabled = true
	_search_edit.right_icon = UiIcons.icon("search", 14)
	_search_edit.text_changed.connect(func(_t): _refresh_list())
	box.add_child(_search_edit)
	_search_count = Label.new()
	_search_count.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_search_count.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	box.add_child(_search_count)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 320)
	_list.auto_height = true
	_list.item_activated.connect(_on_entry_activated)
	_list.item_selected.connect(_on_entry_activated)
	box.add_child(_list)
	var lib := HFlowContainer.new()
	lib.add_theme_constant_override("h_separation", UITheme.SPACE_XS)
	lib.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
	for b in [["Save array", "Keep this whole array in your library", _on_save_design],
			["Save module", "Keep this module (your real panel) in your library, to use in any array", _on_save_module],
			["Forget", "Remove the selected saved entry", _on_forget]]:
		var btn := Button.new()
		btn.text = str(b[0])
		btn.tooltip_text = str(b[1])
		UITheme.style_button(btn)
		btn.pressed.connect(b[2])
		lib.add_child(btn)
	box.add_child(lib)
	var how := Label.new()
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	how.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	how.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	how.text = ("A module from the list replaces the module in this array and keeps the rack. " +
		"Search for your panel by maker or model: the real ones carry their data sheet. Not listed? " +
		"Measure it with a tape (mm), count its cells, read the label on the back for Voc, Vmp, Isc " +
		"and Imp, and put them in the Panel tab's data sheet: the twin then matches it exactly.")
	box.add_child(how)
	return col[0]


func _build_centre() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_tabs = TabBar.new()
	_tabs.add_tab("Cell")
	_tabs.add_tab("Panel")
	_tabs.add_tab("Array")
	_tabs.current_tab = _tab
	_tabs.tab_changed.connect(func(i): set_tab(i))
	col.add_child(_tabs)
	var split := VSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(split)
	_vp_container = SubViewportContainer.new()
	_vp_container.stretch = true
	_vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp_container.custom_minimum_size = Vector2(0, 420)
	_vp_container.gui_input.connect(_on_studio_input)
	_vp_container.mouse_filter = Control.MOUSE_FILTER_STOP
	split.add_child(_vp_container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.size = Vector2i(900, 560)
	_vp_container.add_child(_viewport)
	_build_studio_world()
	_chart = IvChart.new()
	_chart.custom_minimum_size = Vector2(0, 200)
	split.add_child(_chart)
	# Tab bars.
	_bar_cell = HBoxContainer.new()
	_bar_cell.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_bar_cell.add_child(_small_label("The cell up close: drag to orbit, wheel to zoom."))
	col.add_child(_bar_cell)
	_bar_panel = HBoxContainer.new()
	_bar_panel.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var flip := Button.new()
	flip.text = "Front / back"
	flip.tooltip_text = "Turn the module over: backsheet, junction boxes, leads, connectors"
	UITheme.style_button(flip)
	flip.pressed.connect(func(): _show_back = not _show_back; _rebuild_studio())
	_bar_panel.add_child(flip)
	_bar_panel.add_child(_chart_controls())
	col.add_child(_bar_panel)
	_bar_array = HFlowContainer.new()
	_bar_array.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	_bar_array.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
	_paint_btn = Button.new()
	_paint_btn.text = "Paint strings"
	_paint_btn.toggle_mode = true
	_paint_btn.tooltip_text = "Click modules in wiring order to make a string; click one again to take it out"
	UITheme.style_button(_paint_btn)
	_paint_btn.toggled.connect(_on_paint_toggled)
	_bar_array.add_child(_paint_btn)
	var new_s := Button.new()
	new_s.text = "New string"
	UITheme.style_button(new_s)
	new_s.pressed.connect(_on_new_string)
	_bar_array.add_child(new_s)
	var clr := Button.new()
	clr.text = "Clear strings"
	UITheme.style_button(clr)
	clr.pressed.connect(_on_clear_strings)
	_bar_array.add_child(clr)
	_modules_btn = Button.new()
	_modules_btn.text = "Modules"
	_modules_btn.toggle_mode = true
	_modules_btn.button_pressed = true
	_modules_btn.tooltip_text = "Show or hide the modules, to see the rack and every part under them"
	UITheme.style_button(_modules_btn)
	_modules_btn.toggled.connect(func(on): _show_modules = on; _rebuild_studio())
	_bar_array.add_child(_modules_btn)
	var shade := OptionButton.new()
	for i in SHADE_TESTS.size():
		shade.add_item(str(SHADE_TESTS[i][1]), i)
	shade.tooltip_text = "A test shadow: what it does to each string and the array's power"
	shade.item_selected.connect(func(i): _shade_test = str(SHADE_TESTS[i][0]); _refresh_live(); _refresh_chart())
	_bar_array.add_child(shade)
	var tl := _small_label("Tracker")
	_bar_array.add_child(tl)
	var trk := HSlider.new()
	trk.min_value = -60.0
	trk.max_value = 60.0
	trk.step = 1.0
	trk.custom_minimum_size = Vector2(90, 0)
	trk.tooltip_text = "Turn the tracker by hand (preview)"
	trk.value_changed.connect(func(v): _tracker_preview = v; _apply_tracker_preview())
	_bar_array.add_child(trk)
	_bar_array.add_child(_chart_controls())
	_bar_array.add_child(IconButton.make("scan", "Frame the array", func(): _yaw = 0.7; _pitch = 0.45; _frame_camera()))
	_hover_lbl = Label.new()
	_hover_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hover_lbl.custom_minimum_size = Vector2(160, 0)
	_hover_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hover_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hover_lbl.clip_text = true
	_hover_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_bar_array.add_child(_hover_lbl)
	col.add_child(_bar_array)
	return col


func _chart_controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_XS)
	row.add_child(_small_label("Light"))
	var g := SpinBox.new()
	g.min_value = 50.0
	g.max_value = 1200.0
	g.step = 10.0
	g.value = _chart_g
	g.suffix = " W/m²"
	g.custom_minimum_size = Vector2(118, 0)
	g.value_changed.connect(func(v): _chart_g = v; _refresh_chart())
	row.add_child(g)
	row.add_child(_small_label("Cells at"))
	var t := SpinBox.new()
	t.min_value = -20.0
	t.max_value = 85.0
	t.step = 1.0
	t.value = _chart_t
	t.suffix = " °C"
	t.custom_minimum_size = Vector2(84, 0)
	t.value_changed.connect(func(v): _chart_t = v; _refresh_chart())
	row.add_child(t)
	return row


func _small_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	return l


func _build_studio_world() -> void:
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var skymat := ProceduralSkyMaterial.new()
	skymat.sky_top_color = Color(0.32, 0.5, 0.78)
	skymat.sky_horizon_color = Color(0.72, 0.76, 0.8)
	skymat.ground_horizon_color = Color(0.4, 0.38, 0.35)
	skymat.ground_bottom_color = Color(0.15, 0.14, 0.13)
	var sky := Sky.new()
	sky.sky_material = skymat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.8
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.ssao_enabled = true
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	_studio.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, 30, 0)
	key.light_energy = 1.4
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 60.0
	_studio.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, -150, 0)
	fill.light_energy = 0.3
	_studio.add_child(fill)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.36, 0.38, 0.3)
	gmat.roughness = 0.95
	ground.material_override = gmat
	ground.name = "Ground"
	_studio.add_child(ground)
	var person := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.2
	cap.height = 1.75
	person.mesh = cap
	person.position = Vector3(-3, 0.875, 2)
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.45, 0.48, 0.55)
	person.material_override = pm
	person.name = "ScalePerson"
	_studio.add_child(person)
	_holder = Node3D.new()
	_holder.name = "Holder"
	_studio.add_child(_holder)
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.near = 0.01
	_camera.far = 500.0
	_studio.add_child(_camera)
	_update_camera()


func _build_right() -> Control:
	var col := _scroll_column(430)
	var box: VBoxContainer = col[1]
	_cell_group = VBoxContainer.new()
	box.add_child(_cell_group)
	_cell_box = _section(_cell_group, "Cells", true)
	_panel_group = VBoxContainer.new()
	box.add_child(_panel_group)
	_layout_box = _section(_panel_group, "Size, build and cell layout", true)
	_frame_box = _section(_panel_group, "Frame, backsheet and glass", true)
	_jbox_box = _section(_panel_group, "Junction box, leads and diodes", false)
	_fold_box = _section(_panel_group, "Folding", false)
	_elec_box = _section(_panel_group, "Electrical (data sheet)", true)
	_array_group = VBoxContainer.new()
	box.add_child(_array_group)
	var ps := Collapsible.make("Selected part", true)
	_array_group.add_child(ps)
	_part_section = ps
	_part_box = ps.body
	_arr_box = _section(_array_group, "Layout and mount", true)
	_rack_box = _section(_array_group, "Rack", true)
	_tracker_box = _section(_array_group, "Tracker", true)
	_string_box = _section(_array_group, "Strings and MPPT inputs", true)
	_target_box = _section(_array_group, "Controller (the strings are sized for it)", false)
	box.add_child(SectionHeader.make("Live values", "activity"))
	_live_box = VBoxContainer.new()
	_live_box.add_theme_constant_override("separation", 1)
	box.add_child(_live_box)
	box.add_child(SectionHeader.make("Checks", "circle-check"))
	_warn_box = VBoxContainer.new()
	box.add_child(_warn_box)
	box.add_child(SectionHeader.make("Bill of materials", "list"))
	_bom_lbl = Label.new()
	_bom_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bom_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(_bom_lbl)
	_bom_box = VBoxContainer.new()
	_bom_box.add_theme_constant_override("separation", 1)
	box.add_child(_bom_box)
	box.add_child(SectionHeader.make("Files", "download"))
	var ex := HFlowContainer.new()
	ex.add_theme_constant_override("h_separation", UITheme.SPACE_XS)
	ex.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
	for b in [["Export files", "BOM CSV, string diagram SVG and the design JSON", func(): _write_files(export_dir())],
			["Save to…", "Choose a folder for the files", func(): _file_dialog.popup_centered(Vector2i(800, 560))],
			["Open folder", "Show the exported files", _on_open_folder]]:
		var btn := Button.new()
		btn.text = str(b[0])
		btn.tooltip_text = str(b[1])
		UITheme.style_button(btn)
		btn.pressed.connect(b[2])
		ex.add_child(btn)
	box.add_child(ex)
	_export_status = Label.new()
	_export_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_export_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_export_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_export_status)
	return col[0]


func _section(parent: Container, title: String, open: bool) -> VBoxContainer:
	var sec := Collapsible.make(title, open)
	parent.add_child(sec)
	return sec.body


func _build_footer() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var hint := Label.new()
	hint.text = "Drag to orbit · wheel to zoom · Array tab: click a module or any rack part to see it, or paint strings"
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(hint)
	_apply_btn = Button.new()
	_apply_btn.text = "Apply to placed array"
	UITheme.style_button(_apply_btn)
	_apply_btn.pressed.connect(_on_apply)
	row.add_child(_apply_btn)
	_place_btn = Button.new()
	_place_btn.text = "Place in world"
	UITheme.style_button(_place_btn)
	_place_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_place_btn.pressed.connect(_on_place)
	row.add_child(_place_btn)
	var close_b := Button.new()
	close_b.text = "Close"
	UITheme.style_button(close_b)
	close_b.pressed.connect(close)
	row.add_child(close_b)
	return row


# ---------------------------------------------------------------------------
# Spec edits, undo
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
	_update_undo_buttons()


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(_spec.duplicate(true))
	_spec = _undo.pop_back()
	_coalesce_key = ""
	_built_key = ""
	_rebuild_now()


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_spec.duplicate(true))
	_spec = _redo.pop_back()
	_coalesce_key = ""
	_built_key = ""
	_rebuild_now()


func _update_undo_buttons() -> void:
	if _undo_btn != null:
		_undo_btn.disabled = _undo.is_empty()
	if _redo_btn != null:
		_redo_btn.disabled = _redo.is_empty()


## The dictionary at `path` ("module/cells", "array", "" = the spec).
func _group(path: String) -> Dictionary:
	var g: Dictionary = _spec
	if path.is_empty():
		return g
	for part in path.split("/"):
		if not (g.get(part) is Dictionary):
			g[part] = {}
		g = g[part]
	return g


func _edit(path: String, key: String, value: Variant) -> void:
	if _suppress:
		return
	_push_undo(path + "." + key)
	if path == "module" and key == "type":
		# A type is a build: the frame, thickness, front sheet and backsheets
		# change with it (PvLabModule.type_patch).
		_spec["module"] = PvLabModule.type_patch(_spec["module"], str(value))
		_built_key = ""
	else:
		_group(path)[key] = value
	_queue_rebuild()


func _queue_rebuild() -> void:
	_rebuild_timer = REBUILD_DELAY


## Re-solve and refresh. The settings rows are rebuilt only when their set
## changes (the module type, the mount, the electrical mode), so a spin box
## never loses focus mid-edit.
func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = PvLabSpec.resolve(_spec)
	_design = PvLabDesign.solve(_spec)
	if _sel_kind == "part" and _sel_index >= (_design["parts"] as Array).size():
		_sel_kind = ""
		_sel_index = -1
	elif _sel_kind == "member" and _sel_index >= (_design["members"] as Array).size():
		_sel_kind = ""
		_sel_index = -1
	var m: Dictionary = _spec["module"]
	var key := "%s|%s|%s|%s|%s" % [str(m["type"]), str(m["electrical"]["mode"]), str(_spec["array"]["mount"]),
		str(m["cells"]["cut"]), str(m["look"]["cell_color"] != null)]
	if key != _built_key:
		_built_key = key
		_build_settings_rows()
	_sync_settings()
	_rebuild_studio()
	_refresh_live()
	_refresh_chart()
	_refresh_bom()
	_refresh_checks()
	_refresh_header()
	_show_tab()
	_update_undo_buttons()


func _refresh_header() -> void:
	if not _name_edit.has_focus():
		_name_edit.text = str(_spec["name"])
	var t: Dictionary = _design["totals"]
	_subtitle.text = "%s · %s · %.1f × %.1f m · %s" % [PvLabSpec.describe(_spec), PvLabModule.describe(_spec["module"]),
		float(t["width_m"]), float(t["depth_m"]), DomeLabSpec.fmt_kg(float(t["mass_kg"]))]


func _on_name_changed() -> void:
	var t := _name_edit.text.strip_edges()
	if t.is_empty() or t == str(_spec.get("name", "")):
		return
	_edit("", "name", t)


# ---------------------------------------------------------------------------
# Settings rows
# ---------------------------------------------------------------------------

func _clear(box: Container) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _row(parent: Container, label: String, control: Control, tip: String = "") -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(170, 0)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.tooltip_text = tip if not tip.is_empty() else label
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not tip.is_empty():
		control.tooltip_text = tip
	row.add_child(control)
	parent.add_child(row)


func _note(parent: Container, text: String, node_name: String = "") -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	if not node_name.is_empty():
		l.name = node_name
	parent.add_child(l)
	return l


func _bind_spin(parent: Container, label: String, path: String, key: String, min_v: float, max_v: float,
		step: float, suffix: String, tip: String = "") -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.suffix = suffix
	s.value_changed.connect(func(v): _edit(path, key, int(v) if step >= 1.0 else v))
	_row(parent, label, s, tip)
	_bindings.append({"ctl": s, "path": path, "key": key})
	return s


func _bind_check(parent: Container, text: String, path: String, key: String, tip: String = "") -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.toggled.connect(func(v): _edit(path, key, v))
	parent.add_child(c)
	_bindings.append({"ctl": c, "path": path, "key": key})
	return c


func _bind_option(parent: Container, label: String, path: String, key: String, items: Array, tip: String = "") -> OptionButton:
	var o := OptionButton.new()
	for i in items.size():
		o.add_item(str(items[i][1]), i)
		o.set_item_metadata(i, items[i][0])
	o.item_selected.connect(func(idx): _edit(path, key, o.get_item_metadata(idx)))
	_row(parent, label, o, tip)
	_bindings.append({"ctl": o, "path": path, "key": key})
	return o


func _bind_color(parent: Container, label: String, path: String, key: String, tip: String = "") -> ColorPickerButton:
	var cp := ColorPickerButton.new()
	cp.custom_minimum_size = Vector2(60, 24)
	cp.edit_alpha = false
	cp.color_changed.connect(func(c): _edit(path, key, c))
	_row(parent, label, cp, tip)
	_bindings.append({"ctl": cp, "path": path, "key": key})
	return cp


func _items(order: Array, labels: Dictionary) -> Array:
	var out: Array = []
	for id in order:
		var lab: Variant = labels.get(id, id)
		if lab is Dictionary:
			lab = (lab as Dictionary).get("label", id)
		out.append([id, str(lab)])
	return out


func _button(parent: Container, text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	UITheme.style_button(b)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _build_settings_rows() -> void:
	_bindings.clear()
	for b in [_cell_box, _layout_box, _frame_box, _jbox_box, _fold_box, _elec_box, _arr_box, _rack_box,
			_tracker_box, _string_box, _target_box]:
		_clear(b)
	var m: Dictionary = _spec["module"]
	var film := str(m["cells"]["cut"]) == "strip"
	# --- cells -----------------------------------------------------------------
	_bind_option(_cell_box, "Technology", "module/cells", "tech", _items(PvLabCells.TECH_ORDER, PvLabCells.TECHS),
		"What the cells are made of: their colour, texture and electrics")
	if not film:
		_bind_option(_cell_box, "Wafer size", "module/cells", "format", _items(PvLabCells.FORMAT_ORDER, PvLabCells.FORMATS))
		_bind_spin(_cell_box, "Custom wafer edge", "module/cells", "custom_edge_mm", 10.0, 400.0, 0.25, " mm",
			"Used when the wafer size is Custom")
		_bind_option(_cell_box, "Cut", "module/cells", "cut", _items(["full", "half", "third", "shingled"], PvLabCells.CUTS),
			"Half-cut modules are two halves in parallel: less loss in a shadow along an edge")
		var bb: Array = []
		for n in PvLabCells.BUSBARS:
			bb.append([n, "None (IBC / shingled)" if n == 0 else ("%d busbars" % n if n < 9 else "%d wires (multi-busbar)" % n)])
		_bind_option(_cell_box, "Busbars", "module/cells", "busbars", bb)
		_bind_spin(_cell_box, "Finger pitch", "module/cells", "finger_pitch_mm", 0.5, 6.0, 0.05, " mm",
			"The fine lines across a cell")
		_bind_spin(_cell_box, "Corner chamfer", "module/cells", "chamfer_mm", -1.0, 40.0, 0.1, " mm",
			"The cut corners of a mono wafer (−1 = from the wafer size; 0 = square)")
	var cc := CheckBox.new()
	cc.text = "Custom cell colour"
	cc.tooltip_text = "Pick the cell colour yourself instead of the technology's"
	cc.toggled.connect(_on_custom_color)
	_cell_box.add_child(cc)
	_bindings.append({"ctl": cc, "path": "", "key": "_custom_color"})
	if m["look"]["cell_color"] != null:
		_bind_color(_cell_box, "Cell colour", "module/look", "cell_color")
	_bind_color(_cell_box, "Metal (busbars, fingers)", "module/look", "grid_color")
	_bind_spin(_cell_box, "Sheen", "module/look", "sheen", 0.0, 3.0, 0.05, "×", "The blue-violet of the anti-reflective coat at a slant")
	_bind_spin(_cell_box, "Crystal flake", "module/look", "flake", 0.0, 3.0, 0.05, "×", "Polycrystalline grain")
	_note(_cell_box, "", "cell_note")
	# --- size, build, layout ---------------------------------------------------
	_bind_option(_layout_box, "Type", "module", "type", _items(PvLabModule.TYPES, PvLabModule.TYPE_LABELS),
		"A type is a build: switching it sets the frame, thickness, front sheet and backsheets for that kind of module")
	_bind_spin(_layout_box, "Width (short side)", "module/dims_mm", "w", 50.0, 4000.0, 1.0, " mm")
	_bind_spin(_layout_box, "Length (long side)", "module/dims_mm", "h", 50.0, 4000.0, 1.0, " mm")
	_bind_spin(_layout_box, "Thickness", "module/dims_mm", "t", 1.0, 80.0, 0.5, " mm")
	if not film:
		_bind_spin(_layout_box, "Cells across", "module/cells", "cols", 1, 40, 1.0, "")
	_bind_spin(_layout_box, "Cells along" if not film else "Strips", "module/cells", "rows", 1, 400, 1.0, "")
	_bind_spin(_layout_box, "Gap between cells", "module/cells", "gap_mm", 0.0, 30.0, 0.1, " mm")
	if PvLabModule.parallel_paths(m) > 1:
		_bind_spin(_layout_box, "Gap between the halves", "module/cells", "split_gap_mm", 0.0, 120.0, 0.5, " mm")
	_bind_spin(_layout_box, "Parallel paths (0 = by cut)", "module/cells", "parallel", 0, 6, 1.0, "",
		"How many cell paths run in parallel inside the module")
	var fit := HBoxContainer.new()
	_button(fit, "Fit size to cells", "Set the module's size to the cell grid plus a 12 mm border", _on_fit_size)
	_button(fit, "Fit cells to size", "Fill the face with as many cells as fit", _on_fit_cells)
	_layout_box.add_child(fit)
	_note(_layout_box, "", "fit_note")
	# --- frame, backsheet, glass ------------------------------------------------
	_bind_option(_frame_box, "Frame", "module/frame", "style", _items(PvLabModule.FRAME_STYLES, PvLabModule.FRAME_LABELS))
	_bind_spin(_frame_box, "Frame depth", "module/frame", "height_mm", 0.0, 60.0, 0.5, " mm")
	_bind_spin(_frame_box, "Frame lip", "module/frame", "width_mm", 0.0, 60.0, 0.5, " mm", "How much of the face the frame shows")
	_bind_spin(_frame_box, "Lip over the glass", "module/frame", "overlap_mm", 0.0, 20.0, 0.5, " mm",
		"How far the frame's lip reaches over the glass edge (the glass sits in the frame's channel)")
	_bind_spin(_frame_box, "Lip height", "module/frame", "lip_mm", 0.0, 6.0, 0.1, " mm",
		"How far the lip stands proud of the glass")
	_bind_spin(_frame_box, "Corner radius (−1 = by type)", "module", "corner_r_mm", -1.0, 80.0, 0.5, " mm",
		"Rounded laminate corners: flexible and folding modules have them")
	var sheets := _items(PvLabModule.SHEETS, {"white": "White", "black": "Black", "clear": "Clear (glass)", "silver": "Silver"})
	_bind_option(_frame_box, "Backsheet, front", "module/backsheet", "front", sheets, "What shows between the cells")
	_bind_option(_frame_box, "Backsheet, back", "module/backsheet", "back", sheets)
	_bind_option(_frame_box, "Front sheet", "module", "glass", _items(PvLabModule.GLASSES, PvLabModule.GLASS_LABELS))
	# --- junction box --------------------------------------------------------------
	_bind_option(_jbox_box, "Junction box", "module/jbox", "layout", _items(PvLabModule.JBOX_LAYOUTS, PvLabModule.JBOX_LABELS))
	_bind_spin(_jbox_box, "Lead length (each)", "module/jbox", "leads_mm", 50.0, 5000.0, 10.0, " mm",
		"The + and − cables from the box: whether neighbours reach without extensions")
	_bind_option(_jbox_box, "Connector", "module/jbox", "connector", _items(PvLabModule.CONNECTOR_ORDER, PvLabModule.CONNECTORS))
	_bind_spin(_jbox_box, "Bypass diodes", "module", "bypass_diodes", 0, 6, 1.0, "",
		"Each diode lets current past a shaded group of cells")
	_bind_spin(_jbox_box, "Shading samples per path", "module", "shade_samples", 1, 2, 1.0, "",
		"How finely shade is checked along each cell path (2 catches a shadow on half of it)")
	_note(_jbox_box, "", "sub_note")
	# --- folding ------------------------------------------------------------------
	if str(m["type"]) == "folding":
		_bind_spin(_fold_box, "Leaves", "module/folding", "leaves", 1, 8, 1.0, "")
		_bind_spin(_fold_box, "Hinge", "module/folding", "hinge_mm", 0.0, 120.0, 1.0, " mm")
		_bind_spin(_fold_box, "Kickstands", "module/folding", "kickstands", 0, 4, 1.0, "")
	else:
		_note(_fold_box, "Set the type to Folding / portable for leaves, hinges and kickstands.")
	# --- electrical -----------------------------------------------------------------
	_bind_option(_elec_box, "Numbers from", "module/electrical", "mode",
		[["derived", "The cells (derived)"], ["datasheet", "The data sheet (typed in)"]])
	if str(m["electrical"]["mode"]) == "datasheet":
		_bind_spin(_elec_box, "Pmax (Wp)", "module/electrical", "wmp", 0.0, 1000.0, 0.1, " W")
		_bind_spin(_elec_box, "Voc", "module/electrical", "voc", 0.0, 400.0, 0.01, " V")
		_bind_spin(_elec_box, "Vmp", "module/electrical", "vmp", 0.0, 400.0, 0.01, " V")
		_bind_spin(_elec_box, "Isc", "module/electrical", "isc", 0.0, 30.0, 0.01, " A")
		_bind_spin(_elec_box, "Imp", "module/electrical", "imp", 0.0, 30.0, 0.01, " A")
	_bind_spin(_elec_box, "Voc temp. coefficient", "module/electrical", "voc_coeff", -1.0, 0.0, 0.001, " %/°C")
	_bind_spin(_elec_box, "Pmax temp. coefficient", "module/electrical", "pmax_coeff", -1.0, 0.0, 0.001, " %/°C")
	_bind_spin(_elec_box, "Isc temp. coefficient", "module/electrical", "isc_coeff", 0.0, 0.2, 0.001, " %/°C")
	_bind_spin(_elec_box, "NOCT", "module/electrical", "noct_c", 30.0, 60.0, 0.5, " °C")
	_bind_spin(_elec_box, "Mass (0 = estimate)", "module/electrical", "mass_kg", 0.0, 80.0, 0.1, " kg")
	_note(_elec_box, "", "elec_note")
	# --- array ------------------------------------------------------------------------
	var mount := str(_spec["array"]["mount"])
	_bind_option(_arr_box, "Mount", "array", "mount", _items(PvLabRack.MOUNTS, PvLabRack.MOUNT_LABELS))
	_bind_spin(_arr_box, "Rows" if mount != "tracker" else "Tracker rows", "array", "rows", 1, 40, 1.0, "")
	_bind_spin(_arr_box, "Modules across" if mount != "tracker" else "Modules along the axis", "array", "cols", 1, 80, 1.0, "")
	_bind_spin(_arr_box, "Modules up the slope" if mount != "tracker" else "Modules across (1P, 2P)", "array", "stack", 1, 6, 1.0, "")
	_bind_option(_arr_box, "Orientation", "array", "orientation", [["portrait", "Portrait"], ["landscape", "Landscape"]])
	_bind_spin(_arr_box, "Gap between modules", "array", "gap_mm", 0.0, 500.0, 1.0, " mm")
	if mount in ["ground", "roof_tilt", "ballast", "pole"]:
		_bind_spin(_arr_box, "Tilt", "array", "tilt_deg", 0.0, 75.0, 0.5, "°")
	if mount in ["ground", "roof_tilt", "ballast"]:
		_bind_spin(_arr_box, "Front edge height", "array", "clearance_m", 0.0, 6.0, 0.01, " m")
	if mount == "tracker":
		_bind_spin(_arr_box, "Ground coverage ratio", "array", "gcr", 0.1, 0.9, 0.01, "",
			"Module width across the axis / row spacing")
	_bind_spin(_arr_box, "Row spacing (0 = no winter shade)", "array", "pitch_m", 0.0, 40.0, 0.05, " m")
	_bind_spin(_arr_box, "Latitude (for row spacing)", "array", "site_lat", -89.0, 89.0, 0.1, "°")
	_note(_arr_box, "", "arr_note")
	# --- rack -------------------------------------------------------------------------
	if mount != "none":
		_bind_option(_rack_box, "Material", "rack", "material", _items(PvLabRack.MATERIALS, PvLabRack.MATERIAL_LABELS))
		_bind_option(_rack_box, "Footings", "rack", "footing", _items(PvLabHardware.FOOTINGS, PvLabHardware.FOOTING_LABELS),
			"What the legs or posts stand on")
		_bind_option(_rack_box, "Module clamps", "rack", "clamp_finish",
			_items(PvLabHardware.CLAMP_FINISHES, PvLabHardware.CLAMP_FINISH_LABELS))
		_bind_spin(_rack_box, "Support spacing", "rack", "leg_spacing_m", 0.4, 6.0, 0.05, " m",
			"Legs / L-feet / posts along the rails")
		_bind_spin(_rack_box, "Rail overhang", "rack", "rail_overhang_mm", 0.0, 600.0, 5.0, " mm")
		_bind_spin(_rack_box, "Design load (snow / wind)", "rack", "design_load_kpa", 0.2, 6.0, 0.1, " kPa",
			"The load the rails are checked for, on top of the modules' weight (1.4 kPa ≈ 30 psf)")
		if mount in ["ground", "roof_tilt"]:
			_bind_check(_rack_box, "Diagonal braces", "rack", "brace")
		if mount == "pole":
			_bind_spin(_rack_box, "Pole height", "rack", "pole_h_m", 0.8, 8.0, 0.05, " m")
		if mount == "roof_flush":
			_bind_spin(_rack_box, "Stand-off", "rack", "standoff_mm", 20.0, 400.0, 5.0, " mm")
		if mount == "tracker":
			_bind_spin(_rack_box, "Axis height", "rack", "hub_h_m", 0.6, 4.0, 0.05, " m")
		_note(_rack_box, "", "rack_note")
	else:
		_note(_rack_box, "No rack: the modules lie on the surface they are placed on (flexible panels glued down).")
	# --- tracker ------------------------------------------------------------------------
	if mount == "tracker":
		_bind_spin(_tracker_box, "Rotation limit", "tracker", "max_deg", 5.0, 90.0, 1.0, "°")
		_bind_check(_tracker_box, "Backtracking (no row shades the next)", "tracker", "backtrack")
		_bind_spin(_tracker_box, "Axis tilt", "tracker", "axis_tilt_deg", 0.0, 60.0, 0.5, "°")
		_bind_spin(_tracker_box, "Stow above wind", "tracker", "stow_wind_ms", 3.0, 60.0, 0.5, " m/s")
		_bind_spin(_tracker_box, "Stow angle", "tracker", "stow_deg", -60.0, 60.0, 1.0, "°")
		_bind_spin(_tracker_box, "Night angle", "tracker", "night_deg", -60.0, 60.0, 1.0, "°")
		_note(_tracker_box, "The axis runs the way the array faces when placed (north–south at the default turn). It follows the sun east to west.")
	else:
		_note(_tracker_box, "Set the mount to Single-axis tracker to track the sun.")
	# --- strings ------------------------------------------------------------------------
	_bind_option(_string_box, "Wiring", "strings", "mode", _items(PvLabArray.STRING_MODES, PvLabArray.STRING_MODE_LABELS))
	if str(_spec["strings"]["mode"]) != "custom":
		_bind_spin(_string_box, "Modules per string (0 = auto)", "strings", "size", 0, 200, 1.0, "",
			"Auto picks the longest string the controller's window allows")
	_bind_spin(_string_box, "MPPT inputs", "strings", "inputs", 1, 8, 1.0, "",
		"Each input is one array node on the graph, its strings in parallel inside")
	_note(_string_box, "", "string_note")
	# --- target controller -------------------------------------------------------------
	var presets := OptionButton.new()
	presets.add_item("Pick a controller…", 0)
	var ctrls := _controller_presets()
	for i in ctrls.size():
		presets.add_item(str(ctrls[i]["name"]), i + 1)
	presets.item_selected.connect(func(idx): _on_controller_preset(idx - 1))
	_row(_target_box, "From the library", presets)
	_bind_spin(_target_box, "Max PV voltage", "target", "max_voc", 0.0, 1500.0, 1.0, " V")
	_bind_spin(_target_box, "MPPT low", "target", "mppt_min_v", 0.0, 1500.0, 1.0, " V")
	_bind_spin(_target_box, "MPPT high", "target", "mppt_max_v", 0.0, 1500.0, 1.0, " V")
	_bind_spin(_target_box, "Start-up voltage", "target", "startup_v", 0.0, 1500.0, 1.0, " V")
	_bind_spin(_target_box, "Max Isc per input", "target", "max_isc", 0.0, 200.0, 0.5, " A")
	_bind_spin(_target_box, "Max PV power", "target", "max_pv_watts", 0.0, 100000.0, 10.0, " W")
	_bind_spin(_target_box, "Coldest morning", "target", "cold_c", -50.0, 20.0, 1.0, " °C")
	_bind_spin(_target_box, "Hottest afternoon", "target", "hot_c", 10.0, 55.0, 1.0, " °C")


func _on_custom_color(on: bool) -> void:
	if _suppress:
		return
	_push_undo()
	var tech: Dictionary = PvLabCells.tech(str(_spec["module"]["cells"]["tech"]))
	_spec["module"]["look"]["cell_color"] = (tech["look"] as Dictionary)["color"] if on else null
	_queue_rebuild()


func _controller_presets() -> Array:
	var out: Array = []
	for p in ComponentPresets.CONTROLLERS:
		var sp: Dictionary = (p as Dictionary).get("specs", {}) as Dictionary
		out.append({"name": str(sp.get("name", "Controller")), "max_voc": float(sp.get("max_voc", 150.0)),
			"mppt_min_v": float(sp.get("mppt_min_v", 0.0)), "mppt_max_v": float(sp.get("mppt_max_v", 0.0)),
			"startup_v": float(sp.get("startup_v", 0.0)), "max_pv_watts": float(sp.get("max_pv_watts", 0.0)),
			"max_isc": float(sp.get("max_isc", 0.0))})
	return out


func _on_controller_preset(i: int) -> void:
	var ctrls := _controller_presets()
	if i < 0 or i >= ctrls.size():
		return
	_push_undo()
	var t: Dictionary = _spec["target"]
	for k in ctrls[i]:
		t[k] = ctrls[i][k]
	_queue_rebuild()


func _sync_settings() -> void:
	_suppress = true
	for b in _bindings:
		var c: Node = b["ctl"]
		if not is_instance_valid(c):
			continue
		var v: Variant = null
		if str(b["key"]) == "_custom_color":
			v = _spec["module"]["look"]["cell_color"] != null
		else:
			v = _group(str(b["path"])).get(str(b["key"]))
		if v == null:
			continue
		if c is SpinBox:
			if typeof(v) == TYPE_FLOAT and is_nan(float(v)):
				continue
			(c as SpinBox).set_value_no_signal(float(v))
		elif c is CheckBox:
			(c as CheckBox).set_pressed_no_signal(bool(v))
		elif c is OptionButton:
			_select_meta(c as OptionButton, v)
		elif c is ColorPickerButton and v is Color:
			(c as ColorPickerButton).color = v
	# The coefficient spins show the technology's own when not typed in.
	var e: Dictionary = _design["elec"]
	for b2 in _bindings:
		if str(b2["path"]) == "module/electrical" and str(b2["key"]) in ["voc_coeff", "pmax_coeff", "isc_coeff", "noct_c"]:
			var raw := float(_spec["module"]["electrical"][str(b2["key"])])
			if is_nan(raw) and is_instance_valid(b2["ctl"]):
				(b2["ctl"] as SpinBox).set_value_no_signal(float(e[str(b2["key"])]))
	_suppress = false
	_sync_notes()


func _select_meta(o: OptionButton, value: Variant) -> void:
	for i in o.item_count:
		if str(o.get_item_metadata(i)) == str(value):
			o.select(i)
			return


func _sync_notes() -> void:
	var m: Dictionary = _spec["module"]
	var e: Dictionary = _design["elec"]
	var te: Dictionary = PvLabCells.tech(str(m["cells"]["tech"]))["elec"]
	_set_note(_cell_box, "cell_note", "One piece: %.1f cm² · Voc %.2f V · Jsc %.1f mA/cm² · Isc %.2f A · %.2f W at STC · %s %.2f %%/°C" % [
		PvLabModule.piece_area_cm2(m), float(te["voc"]), float(te["jsc"]),
		float(te["jsc"]) * 0.001 * PvLabModule.piece_area_cm2(m),
		float(te["voc"]) * float(te["vm"]) * float(te["jsc"]) * 0.001 * PvLabModule.piece_area_cm2(m) * float(te["im"]),
		"Pmax", float(te["pmax_coeff"])])
	var fr := PvLabModule.fit_report(m)
	var g: Vector2 = fr["grid_mm"]
	var f: Vector2 = fr["face_mm"]
	_set_note(_layout_box, "fit_note", "Cell grid %.0f × %.0f mm on a face of %.0f × %.0f mm%s · %s in series × %d path(s) · %.2f m² · %s" % [
		g.x, g.y, f.x, f.y, "" if bool(fr["fits"]) else " — DOES NOT FIT", UiText.count(PvLabModule.series_cells(m), "cell"),
		PvLabModule.parallel_paths(m), PvLabModule.area_m2(m), DomeLabSpec.fmt_kg(PvLabModule.mass_kg(m))])
	var subs := PvLabModule.substrings(m)
	_set_note(_jbox_box, "sub_note", "%s, each %s per path × %d path(s) · %d shading samples a module" % [
		UiText.count(subs.size(), "substring"), UiText.count(int(subs[0]["cells"]), "cell"),
		(subs[0]["paths"] as Array).size(), PvLabModule.sample_points(m).size()])
	var dv: Dictionary = e["derived"]
	_set_note(_elec_box, "elec_note", "Now: %.1f W · Voc %.2f V · Vmp %.2f V · Isc %.2f A · Imp %.2f A · FF %.2f · %.1f %% efficient\nFrom the cells: %.1f W · Voc %.2f V · Isc %.2f A" % [
		float(e["wmp"]), float(e["voc"]), float(e["vmp"]), float(e["isc"]), float(e["imp"]),
		float(e["wmp"]) / maxf(float(e["voc"]) * float(e["isc"]), 0.001),
		float(e["wmp"]) / (PvLabModule.area_m2(m) * 10.0), float(dv["wmp"]), float(dv["voc"]), float(dv["isc"])])
	var lay: Dictionary = _design["layout"]
	_set_note(_arr_box, "arr_note", "%s · %.1f × %.1f m footprint · %s high · rows %.2f m apart%s" % [
		UiText.count((lay["panels"] as Array).size(), "module"), float(_design["totals"]["width_m"]),
		float(_design["totals"]["depth_m"]), DomeLabSpec.fmt_m(float(lay["height_m"])), float(lay["pitch_m"]),
		(" · GCR %.2f" % float(lay["gcr"])) if float(lay["gcr"]) > 0.0 else ""])
	var sp: Dictionary = _design["span"]
	_set_note(_rack_box, "rack_note", str(sp.get("text", "")))
	_set_note(_string_box, "string_note", "%s on %s · %s" % [UiText.count((_design["strings"] as Array).size(), "string"),
		UiText.count((_design["groups"] as Array).size(), "input"),
		"painting: click modules in order" if _painting else "Paint strings to wire them by hand"])


func _set_note(box: Container, n: String, text: String) -> void:
	var l := box.find_child(n, true, false) as Label
	if l != null:
		l.text = text


func _on_fit_size() -> void:
	_push_undo()
	var v := PvLabModule.dims_to_fit(PvLabModule.resolve(_spec["module"]))
	_spec["module"]["dims_mm"]["w"] = snappedf(v.x, 1.0)
	_spec["module"]["dims_mm"]["h"] = snappedf(v.y, 1.0)
	_rebuild_now()


func _on_fit_cells() -> void:
	_push_undo()
	var v := PvLabModule.cells_to_fit(PvLabModule.resolve(_spec["module"]))
	_spec["module"]["cells"]["cols"] = v.x
	_spec["module"]["cells"]["rows"] = v.y
	_rebuild_now()


# ---------------------------------------------------------------------------
# Live values, chart, BOM, checks
# ---------------------------------------------------------------------------

## Per-sample irradiance (W/m²) of every module under the test shadow at
## light `g`: a shaded sample keeps the diffuse SHADED_SHARE.
func _test_samples(g: float) -> Array:
	var lay: Dictionary = _design["layout"]
	var m: Dictionary = _design["module"]
	var pts := PvLabModule.sample_points(m)
	var mw := float(m["dims_mm"]["w"]) * 0.001
	var mh := float(m["dims_mm"]["h"]) * 0.001
	var out: Array = []
	var first_string: Array = (_design["strings"] as Array)[0] if not (_design["strings"] as Array).is_empty() else []
	for p in lay["panels"]:
		var xf := PvLabArray.panel_xf(lay, p, 0.0)
		var s: Array = []
		for uv in pts:
			var shaded := false
			match _shade_test:
				"edge":
					shaded = int(p["table"]) == 0 and int(p["k"]) == 0 and float(uv.y) > 0.3
				"module":
					shaded = not first_string.is_empty() and int(p["index"]) == int(first_string[0])
				"pole":
					var wp := xf * Vector3(float(uv.x) * mw, 0, float(uv.y) * mh)
					shaded = absf(wp.x - 0.1) < 0.15
				"leaf":
					shaded = not first_string.is_empty() and int(p["index"]) == int(first_string[0]) \
						and float(uv.x) < -0.15 and float(uv.y) < 0.0
			s.append(g * (SHADED_SHARE if shaded else 1.0))
		out.append(PvLabIV.path_irradiance(m, s))
	return out


## Per MPPT input, the strings as per-panel path irradiance lists.
func _group_strings(paths_by_panel: Array) -> Array:
	var out: Array = []
	for g in _design["groups"]:
		var sts: Array = []
		for si in g:
			var st: Array = []
			for pi in (_design["strings"] as Array)[int(si)]:
				st.append(paths_by_panel[int(pi)])
			sts.append(st)
		out.append(sts)
	return out


func _refresh_live() -> void:
	_clear(_live_box)
	var reps: Array = _design["string_reports"]
	var e: Dictionary = _design["elec"]
	_live_box.add_child(_table_row(["String", "Mods", "Voc", "Vmp", "Isc", "Imp", "Wmp", "Cold Voc"], true))
	var colors := PvLabCam.string_colors(reps.size())
	for si in reps.size():
		var r: Dictionary = reps[si]
		var w: Dictionary = r["window"]
		var row := _table_row(["S%d" % (si + 1), str(int(r["n"])), "%.1f" % float(r["voc"]), "%.1f" % float(r["vmp"]),
			"%.2f" % float(r["isc"]), "%.2f" % float(r["imp"]), "%.0f" % float(r["wmp"]), "%.1f" % float(w["voc_cold"])], false)
		row.modulate = colors[si] if bool(w["ok"]) else UITheme.C_ERROR
		_live_box.add_child(row)
	var g := _chart_g
	var t := _chart_t
	var model: Dictionary = _design["iv"]
	var shaded := _group_strings(_test_samples(g))
	var full_by := _test_samples_uniform(g)
	var full := _group_strings(full_by)
	var gr: Array = _design["group_reports"]
	for gi in gr.size():
		var rg: Dictionary = gr[gi]
		var mpp := PvLabIV.array_mpp(model, shaded[gi], t)
		var ref := PvLabIV.array_mpp(model, full[gi], t)
		var loss := 1.0 - float(mpp["p"]) / maxf(float(ref["p"]), 0.001)
		var l := Label.new()
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT if bool(rg["ok"]) else UITheme.C_WARN)
		l.text = "Input %d: %dS × %dP · STC %.0f W, Voc %.1f V, Isc %.2f A · at %.0f W/m², %.0f °C: %.0f W at %.1f V, %.2f A%s" % [
			gi + 1, int(rg["series"]), int(rg["parallel"]), float(rg["wmp"]), float(rg["voc"]), float(rg["isc"]),
			g, t, float(mpp["p"]), float(mpp["v"]), float(mpp["i"]),
			(" — the test shadow costs %.0f %%" % (loss * 100.0)) if _shade_test != "none" else ""]
		_live_box.add_child(l)
	var now := _site_now()
	if not now.is_empty():
		var nl := Label.new()
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		nl.add_theme_color_override("font_color", UITheme.C_INFO)
		nl.text = str(now["text"])
		_live_box.add_child(nl)
	var tot: Dictionary = _design["totals"]
	_live_box.add_child(_small_label("%s of modules · %s wired · module %.0f W, Voc %.2f V" % [
		_kw(float(tot["wmp"])), _kw(float(tot["wired_wmp"])), float(e["wmp"]), float(e["voc"])]))


func _test_samples_uniform(g: float) -> Array:
	var keep := _shade_test
	_shade_test = "none"
	var out := _test_samples(g)
	_shade_test = keep
	return out


func _kw(w: float) -> String:
	return "%.0f W" % w if w < 1000.0 else "%.2f kW" % (w / 1000.0)


## What the placed array makes right now (sun, weather, its own plane), when
## the designer is bound to one in a world.
func _site_now() -> Dictionary:
	if _bound_prop_id.is_empty():
		return {}
	var main := _main_node()
	if main == null or main.get("clock") == null:
		return {}
	var clock: Object = main.get("clock")
	if not clock.has_method("get_julian_day_utc"):
		return {}
	var lat := float(main.get("latitude"))
	var lon := float(main.get("longitude"))
	var sp := SolarPosition.get_position(lat, lon, float(clock.call("get_julian_day_utc")))
	var el := float(sp.get("elevation_deg", -10.0))
	if el <= 0.0:
		return {"text": "Right now the sun is down where it stands."}
	var rec := _prop_record(_bound_prop_id)
	var plane := PlacedPropService.pvlab_plane(main, rec)
	var ws := get_tree().root.get_node_or_null("/root/WeatherService")
	var wx := SolarIrradiance.sample_weather(lat, lon, int(main.get("month")), int(main.get("day")),
		float(main.get("day_time")), ws)
	var tilt := float(plane.get("tilt_deg", 0.0))
	var az := float(plane.get("azimuth_deg", 180.0))
	if plane.has("tracker"):
		var r := PvLabTracker.angle_at(float(sp["azimuth_deg"]), el, float(plane["axis_az"]), plane["tracker"],
			float(plane["gcr"]))
		var o := PvLabTracker.orientation_of(PvLabTracker.normal_at(r, float(plane["axis_az"]),
			float((plane["tracker"] as Dictionary).get("axis_tilt_deg", 0.0))))
		tilt = float(o["tilt_deg"])
		az = float(o["azimuth_deg"])
	var poa := PvLabShading.poa(float(sp["azimuth_deg"]), el, tilt, az, float(wx.get("ghi", 0.0)),
		bool(wx.get("has_real", false)), float(wx.get("cloud", 0.0)))
	var tc := PvLabIV.cell_temp_c(float(wx.get("temp", 20.0)), float(poa["total"]), float(_design["elec"]["noct_c"]))
	var factor := float(_shade_factor_now())
	var p := 0.0
	var model: Dictionary = _design["iv"]
	for g in _group_strings(_test_samples_uniform(float(poa["total"]))):
		p += float(PvLabIV.array_mpp(model, g, tc)["p"])
	return {"text": "Here, now: sun %.0f° up · plane %.0f° toward %.0f° · %.0f W/m² on the modules, cells %.0f °C · %s before shade%s" % [
		el, tilt, az, float(poa["total"]), tc, _kw(p),
		(" · %s with the shade it is under" % _kw(p * factor)) if factor < 0.999 else ""]}


func _shade_factor_now() -> float:
	var main := _main_node()
	if main == null:
		return 1.0
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("designed_array_shade"):
		return 1.0
	return float(sgv.call("designed_array_shade", PlacedPropService.pvlab_array_tag(_bound_prop_id)))


func _table_row(cells: Array, head: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var widths := [44, 36, 50, 50, 44, 44, 50, 0]
	for i in cells.size():
		var l := Label.new()
		l.text = str(cells[i])
		l.add_theme_font_override("font", UITheme.font("regular", true))
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT if head else UITheme.C_TEXT_S)
		if int(widths[i]) > 0:
			l.custom_minimum_size = Vector2(int(widths[i]), 0)
		else:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
	return row


func _refresh_chart() -> void:
	if _chart == null or _design.is_empty():
		return
	var model: Dictionary = _design["iv"]
	var curves: Array = []
	var title := ""
	var mpp := Vector2.ZERO
	if _tab <= 1:
		var c := PvLabIV.module_curve(model, _chart_g, _chart_t)
		curves.append({"v": c["v"], "i": c["i"], "color": UITheme.C_AMBER, "label": "Module"})
		var best := PvLabIV.array_mpp(model, [[_uniform(model, _chart_g)]], _chart_t)
		mpp = Vector2(float(best["v"]), float(best["i"]))
		title = "%s · %.0f W/m², %.0f °C · MPP %.1f W at %.2f V, %.2f A" % [str(_spec["module"]["name"]), _chart_g,
			_chart_t, float(best["p"]), mpp.x, mpp.y]
		if _chart_g != 1000.0 or _chart_t != 25.0:
			var stc := PvLabIV.module_curve(model, 1000.0, 25.0)
			curves.append({"v": stc["v"], "i": stc["i"], "color": UITheme.C_TEXT_M, "label": "STC"})
	else:
		var shaded := _group_strings(_test_samples(_chart_g))
		if shaded.is_empty():
			return
		var r := PvLabIV.array_mpp(model, shaded[0], _chart_t, true)
		if r.has("curve"):
			curves.append({"v": r["curve"]["v"], "i": r["curve"]["i"], "color": UITheme.C_AMBER,
				"label": "Input 1" if _shade_test == "none" else "Input 1, shaded"})
		if _shade_test != "none":
			var full := _group_strings(_test_samples_uniform(_chart_g))
			var rf := PvLabIV.array_mpp(model, full[0], _chart_t, true)
			if rf.has("curve"):
				curves.append({"v": rf["curve"]["v"], "i": rf["curve"]["i"], "color": UITheme.C_TEXT_M, "label": "No shade"})
		mpp = Vector2(float(r["v"]), float(r["i"]))
		title = "Input 1 · %.0f W/m², %.0f °C · MPP %.0f W at %.1f V, %.2f A" % [_chart_g, _chart_t, float(r["p"]), mpp.x, mpp.y]
	_chart.set("curves", curves)
	_chart.set("mpp", mpp)
	_chart.set("title", title)
	_chart.queue_redraw()


func _uniform(model: Dictionary, g: float) -> Array:
	var out: Array = []
	for i in int(model["n_paths"]):
		out.append(g)
	return out


func _refresh_bom() -> void:
	_clear(_bom_box)
	var bom: Dictionary = _design["bom"]
	_bom_lbl.text = "%s · about $%.0f · %d stock lengths" % [DomeLabSpec.fmt_kg(float(bom["mass_kg"])),
		float(bom["cost_usd"]), int(bom["stock"])]
	for r in bom["rows"]:
		var row := HBoxContainer.new()
		for cell in [["%d %s" % [int(r["qty"]), str(r["unit"])], 70], [str(r["item"]), 0], ["$%.0f" % float(r["cost"]), 56]]:
			var l := Label.new()
			l.text = str(cell[0])
			l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
			l.clip_text = true
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			l.tooltip_text = str(cell[0])
			l.mouse_filter = Control.MOUSE_FILTER_PASS
			if int(cell[1]) > 0:
				l.custom_minimum_size = Vector2(int(cell[1]), 0)
			else:
				l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(l)
		if r.has("part"):
			# Show them: every part of this kind lit in the Array tab.
			var pt := str(r["part"])
			row.add_child(IconButton.make("eye", "Show every one in the view", func(): _show_all_parts(pt)))
		_bom_box.add_child(row)


func _refresh_checks() -> void:
	_clear(_warn_box)
	for c in _design["checks"]:
		var level := str(c["level"])
		var col := UITheme.C_OK
		var icon := "circle-check"
		if level == "warn":
			col = UITheme.C_WARN
			icon = "triangle-alert"
		elif level == "error":
			col = UITheme.C_ERROR
			icon = "circle-alert"
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UITheme.SPACE_XS)
		var ic := TextureRect.new()
		ic.texture = UiIcons.icon(icon, 14)
		ic.modulate = col
		ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		ic.custom_minimum_size = Vector2(16, 0)
		row.add_child(ic)
		var l := Label.new()
		l.text = str(c["text"])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", col if level != "ok" else UITheme.C_TEXT_S)
		row.add_child(l)
		_warn_box.add_child(row)


# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

func _refresh_list() -> void:
	_list.clear()
	_entries.clear()
	var q := _search_edit.text if _search_edit != null else ""
	# Lambdas capture locals by value: the counts live in an array.
	var cnt := [0, 0]
	var add_head := func(title: String) -> void:
		_list.add_item(title)
		_list.set_item_disabled(_list.item_count - 1, true)
		_entries.append({})
	var add := func(text: String, tip: String, entry: Dictionary, hay: String) -> void:
		cnt[1] += 1
		if not PvLabCatalog.matches(hay, q):
			return
		cnt[0] += 1
		_list.add_item(text)
		_list.set_item_tooltip(_list.item_count - 1, tip)
		_entries.append(entry)
	add_head.call("— Arrays —")
	for p in PvLabPresets.builtins():
		add.call(str(p["name"]), str(p.get("blurb", "")), {"kind": "design", "spec": p["spec"], "builtin": true,
			"id": str(p["id"])}, str(p["name"]) + " " + str(p.get("blurb", "")))
	for d in _library["designs"]:
		add.call("★ " + str(d["name"]), "", {"kind": "design", "spec": d["spec"], "builtin": false, "id": str(d["id"])},
			str(d["name"]))
	add_head.call("— Real panels (data sheets) —")
	for e in PvLabCatalog.all():
		add.call(PvLabCatalog.label(e), PvLabCatalog.tooltip(e), {"kind": "module", "catalog": str(e["id"]),
			"builtin": true, "id": str(e["id"])}, PvLabCatalog.haystack(e))
	add_head.call("— Module types —")
	for m in PvLabPresets.modules():
		add.call(str(m["name"]), PvLabModule.describe(m["spec"]), {"kind": "module", "spec": m["spec"], "builtin": true,
			"id": str(m["id"])}, str(m["name"]) + " " + PvLabModule.describe(m["spec"]))
	for m2 in _library["modules"]:
		add.call("★ " + str(m2["name"]), "", {"kind": "module", "spec": m2["spec"], "builtin": false, "id": str(m2["id"])},
			str(m2["name"]))
	if _search_count != null:
		_search_count.text = "" if q.strip_edges().is_empty() else "%d of %d match" % [int(cnt[0]), int(cnt[1])]


func _on_entry_activated(idx: int) -> void:
	if idx < 0 or idx >= _entries.size() or (_entries[idx] as Dictionary).is_empty():
		return
	var e: Dictionary = _entries[idx]
	_push_undo()
	_sel_kind = ""
	_sel_index = -1
	_picked = -1
	if str(e["kind"]) == "module":
		if e.has("catalog"):
			_spec["module"] = PvLabCatalog.module_spec(PvLabCatalog.by_id(str(e["catalog"])))
		else:
			_spec["module"] = PvLabModule.resolve((e["spec"] as Dictionary).duplicate(true))
	else:
		var keep_lat := float(_spec["array"]["site_lat"])
		_spec = PvLabSpec.resolve((e["spec"] as Dictionary).duplicate(true))
		_spec["array"]["site_lat"] = keep_lat
	_built_key = ""
	_rebuild_now()
	_frame_camera()


func _on_save_design() -> void:
	var nm := str(_spec["name"])
	_save_into("designs", nm, PvLabSpec.to_json_safe(_spec))
	_status("Saved the array “%s” to your library." % nm)


func _on_save_module() -> void:
	var nm := str(_spec["module"]["name"])
	_save_into("modules", nm, PvLabModule.to_json_safe(_spec["module"]))
	_status("Saved the module “%s” to your library." % nm)


func _save_into(kind: String, nm: String, spec: Dictionary) -> void:
	var list: Array = _library[kind]
	var replaced := false
	for d in list:
		if str(d["name"]) == nm:
			d["spec"] = spec
			replaced = true
	if not replaced:
		list.append({"id": DomeLabCam.safe_name(nm) + "_%d" % (Time.get_unix_time_from_system() as int),
			"name": nm, "spec": spec})
	PvLabPresets.save_library(_library)
	_refresh_list()


func _on_forget() -> void:
	var sel := _list.get_selected_items()
	if sel.is_empty():
		return
	var e: Dictionary = _entries[sel[0]]
	if e.is_empty() or bool(e["builtin"]):
		_status("Built-in entries stay.")
		return
	var kind := "modules" if str(e["kind"]) == "module" else "designs"
	var list: Array = _library[kind]
	for i in list.size():
		if str(list[i]["id"]) == str(e["id"]):
			list.remove_at(i)
			break
	PvLabPresets.save_library(_library)
	_refresh_list()


# ---------------------------------------------------------------------------
# Studio
# ---------------------------------------------------------------------------

func set_tab(i: int) -> void:
	_tab = clampi(i, 0, 2)
	if _tabs.current_tab != _tab:
		_tabs.current_tab = _tab
	if _tab != 2 and _painting:
		_paint_btn.button_pressed = false
	_show_tab()
	_rebuild_studio()
	_refresh_chart()
	_frame_camera()


func _show_tab() -> void:
	_cell_group.visible = _tab == 0
	_panel_group.visible = _tab == 1
	_array_group.visible = _tab == 2
	_bar_cell.visible = _tab == 0
	_bar_panel.visible = _tab == 1
	_bar_array.visible = _tab == 2
	_chart.visible = _tab >= 1


func _rebuild_studio() -> void:
	if _holder == null or _design.is_empty():
		return
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	var person := _studio.get_node_or_null("ScalePerson") as Node3D
	if _tab <= 1:
		var mi := MeshInstance3D.new()
		mi.mesh = PvLabBuilder.module_mesh(_design["module"])
		if _tab == 0:
			mi.position = Vector3(0, 0.05, 0)
		else:
			mi.position = Vector3(0, 1.0, 0)
			mi.basis = Basis(Vector3.UP, PI if _show_back else 0.0) * Basis(Vector3.RIGHT, deg_to_rad(65.0 if not _show_back else 115.0))
		_holder.add_child(mi)
		if person != null:
			person.visible = _tab == 1
			person.position = Vector3(-float(_spec["module"]["dims_mm"]["w"]) * 0.001 - 0.6, 0.875, 0)
		return
	var colors := {}
	if _color_strings:
		var cols := PvLabCam.string_colors((_design["strings"] as Array).size())
		for si in (_design["strings"] as Array).size():
			for pi in (_design["strings"] as Array)[si]:
				var c: Color = cols[si]
				colors[int(pi)] = Color(c.r, c.g, c.b, 0.16 if not (_painting and si == _paint_string) else 0.4)
	if _picked >= 0:
		colors[_picked] = Color(1.0, 0.85, 0.3, 0.6)
	var node := PvLabBuilder.build_from_design(_design, "Array", {"overlay": colors, "tracker_deg": _tracker_preview,
		"hide_modules": not _show_modules})
	_holder.add_child(node)
	_refresh_highlight()
	_refresh_part_card()
	if person != null:
		person.visible = true
		var fp: Rect2 = _design["layout"]["footprint"]
		person.position = Vector3(fp.position.x - 0.8, 0.875, fp.end.y + 0.8)


func _apply_tracker_preview() -> void:
	if _holder.get_child_count() > 0:
		PvLabBuilder.set_tracker_angle(_holder.get_child(0), _tracker_preview)
		_refresh_highlight()


## The ids a selection lights: the one picked, or every one like it.
func _selection_ids() -> Dictionary:
	var parts: Array = []
	var members: Array = []
	if _design.is_empty() or _sel_index < 0:
		return {"parts": parts, "members": members}
	if _sel_kind == "part" and _sel_index < (_design["parts"] as Array).size():
		var t := str(_design["parts"][_sel_index]["type"])
		if _sel_all:
			for i in (_design["parts"] as Array).size():
				if str(_design["parts"][i]["type"]) == t:
					parts.append(i)
		else:
			parts.append(_sel_index)
	elif _sel_kind == "member" and _sel_index < (_design["members"] as Array).size():
		var mb: Dictionary = _design["members"][_sel_index]
		if _sel_all:
			for j in (_design["members"] as Array).size():
				var o: Dictionary = _design["members"][j]
				if str(o["kind"]) == str(mb["kind"]) and str(o["profile"]) == str(mb["profile"]):
					members.append(j)
		else:
			members.append(_sel_index)
	return {"parts": parts, "members": members}


func _refresh_highlight() -> void:
	if _holder == null or _holder.get_child_count() == 0 or _tab != 2:
		return
	var node := _holder.get_child(0)
	var old := node.get_node_or_null("Highlight")
	if old != null:
		node.remove_child(old)
		old.queue_free()
	var ids := _selection_ids()
	if (ids["parts"] as Array).is_empty() and (ids["members"] as Array).is_empty():
		return
	node.add_child(PvLabBuilder.highlight_node(_design, ids["parts"], ids["members"], _tracker_preview))


## The card for what is selected in the Array tab: what it is, what it is
## for, how many there are, what they cost and weigh, what holds it down.
func _refresh_part_card() -> void:
	if _part_box == null:
		return
	_clear(_part_box)
	var lbl := func(text: String, col: Color, size: int) -> Label:
		var l := Label.new()
		l.text = text
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_color_override("font_color", col)
		l.add_theme_font_size_override("font_size", size)
		_part_box.add_child(l)
		return l
	if _sel_kind.is_empty() or _sel_index < 0:
		lbl.call("Click any part of the rack in the view — a clamp, a bracket, a rail, a footing — to see what it is. Hide the modules to see under them.",
			UITheme.C_TEXT_M, UITheme.FONT_XS)
		return
	var n := 0
	if _sel_kind == "part":
		var p: Dictionary = _design["parts"][_sel_index]
		var info := PvLabHardware.part(str(p["type"]))
		for q in _design["parts"]:
			if str(q["type"]) == str(p["type"]):
				n += 1
		lbl.call(str(info["label"]), UITheme.C_TEXT, UITheme.FONT_MD)
		lbl.call(str(info["spec"]), UITheme.C_TEXT_S, UITheme.FONT_XS)
		lbl.call("%s · %s · %d in this array · $%.2f and %s each" % [str(info["group"]), str(p["where"]), n,
			float(info["cost"]), DomeLabSpec.fmt_kg(float(info["kg"]))], UITheme.C_TEXT_S, UITheme.FONT_XS)
		var fs: Array = []
		var fd: Dictionary = info["fasteners"]
		for fid in fd:
			fs.append("%d × %s" % [int(fd[fid]), str(PvLabHardware.FASTENERS[fid]["label"])])
		if not fs.is_empty():
			lbl.call("Fastened with " + ", ".join(fs) + ".", UITheme.C_TEXT_M, UITheme.FONT_XS)
	elif _sel_kind == "member":
		var mb: Dictionary = _design["members"][_sel_index]
		var pr := PvLabRack.profile(str(mb["profile"]))
		var total := 0.0
		for o in _design["members"]:
			if str(o["kind"]) == str(mb["kind"]) and str(o["profile"]) == str(mb["profile"]):
				n += 1
				total += float(o["len_m"])
		lbl.call("%s — %s" % [str(mb["label"]), str(pr["label"])], UITheme.C_TEXT, UITheme.FONT_MD)
		lbl.call("Cut to %s from %s stock · %.0f × %.0f mm section · %s a metre" % [DomeLabSpec.fmt_m(float(mb["len_m"])),
			DomeLabSpec.fmt_m(float(pr["stock_m"])) if float(pr["stock_m"]) > 0.0 else "—", float(pr["w"]), float(pr["h"]),
			DomeLabSpec.fmt_kg(float(pr["kg_m"]))], UITheme.C_TEXT_S, UITheme.FONT_XS)
		lbl.call("%d like it in this array, %s in all" % [n, DomeLabSpec.fmt_m(total)], UITheme.C_TEXT_S, UITheme.FONT_XS)
	else:
		lbl.call(_describe_module(_sel_index), UITheme.C_TEXT, UITheme.FONT_SM)
		lbl.call(PvLabModule.describe(_design["module"]), UITheme.C_TEXT_S, UITheme.FONT_XS)
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_XS)
	var all_b := Button.new()
	all_b.text = "Light all %d" % n
	all_b.toggle_mode = true
	all_b.button_pressed = _sel_all
	all_b.tooltip_text = "Show every one like it in the view"
	UITheme.style_button(all_b)
	all_b.toggled.connect(func(on): _sel_all = on; _refresh_highlight())
	row.add_child(all_b)
	_button(row, "Clear", "Clear the selection", func(): _select("", -1))
	_part_box.add_child(row)


func _show_all_parts(type: String) -> void:
	for i in (_design["parts"] as Array).size():
		if str(_design["parts"][i]["type"]) == type:
			if _tab != 2:
				set_tab(2)
			_select("part", i)
			_sel_all = true
			_refresh_highlight()
			_refresh_part_card()
			return


func _select(kind: String, idx: int) -> void:
	if kind != _sel_kind or idx != _sel_index:
		_sel_all = false
	_sel_kind = kind
	_sel_index = idx
	_picked = idx if kind == "panel" else -1
	if kind == "panel":
		_rebuild_studio()
	else:
		_refresh_highlight()
		_refresh_part_card()


func _frame_camera() -> void:
	if _design.is_empty():
		return
	var m: Dictionary = _design["module"]
	match _tab:
		0:
			# Over the module's top-left cells.
			var r := PvLabModule.piece_rect_uv(m, 0, 0)
			var w := float(m["dims_mm"]["w"]) * 0.001
			var h := float(m["dims_mm"]["h"]) * 0.001
			_target = Vector3((r.position.x + r.size.x) * w, 0.07, (r.position.y + r.size.y) * h)
			_dist = maxf(float(PvLabModule.piece_mm(m)["across"]) * 0.004, 0.25)
			_pitch = 1.1
		1:
			_target = Vector3(0, 1.0, 0)
			_dist = maxf(float(m["dims_mm"]["h"]) * 0.0016, 1.2)
		_:
			var fp: Rect2 = _design["layout"]["footprint"]
			_target = Vector3(fp.get_center().x, float(_design["layout"]["height_m"]) * 0.45, fp.get_center().y)
			_dist = clampf(maxf(fp.size.x, fp.size.y) * 1.25 + 2.5, 3.0, 200.0)
	_update_camera()


func _update_camera() -> void:
	if _camera == null:
		return
	var cp := Vector3(_dist * cos(_pitch) * sin(_yaw), _dist * sin(_pitch), _dist * cos(_pitch) * cos(_yaw))
	_camera.look_at_from_position(_target + cp, _target, Vector3.UP)


func _on_studio_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(0.05, _dist * 0.9)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(250.0, _dist * 1.1)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_orbiting = true
				_moved = false
				_press_pos = mb.position
			else:
				_orbiting = false
				if not _moved and mb.button_index == MOUSE_BUTTON_LEFT and _tab == 2:
					if _painting:
						_on_module_clicked(_pick_at(mb.position))
					else:
						var hit := _pick_any_at(mb.position)
						if hit.is_empty():
							_select("", -1)
						elif str(hit["kind"]) == "panel" and _sel_kind == "panel" and _sel_index == int(hit["index"]):
							_select("", -1)
						else:
							_select(str(hit["kind"]), int(hit["index"]))
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _orbiting:
			if mm.position.distance_to(_press_pos) > 4.0:
				_moved = true
			if _moved:
				_yaw -= mm.relative.x * 0.01
				_pitch = clampf(_pitch - mm.relative.y * 0.01, -0.2, 1.5)
				_update_camera()
		elif _tab == 2:
			_hover_frame += 1
			if _hover_frame % 4 == 0:
				_hover_lbl.text = _describe_hit(_pick_any_at(mm.position)) if not _painting else _describe_module(_pick_at(mm.position))


func _pick_at(pos: Vector2) -> int:
	if _camera == null or _holder.get_child_count() == 0 or _tab != 2:
		return -1
	var vp_size := Vector2(_viewport.size)
	var cs := _vp_container.size
	var p := pos * (vp_size / cs) if cs.x > 0.0 and cs.y > 0.0 else pos
	var o := _camera.project_ray_origin(p)
	var d := _camera.project_ray_normal(p)
	var node := _holder.get_child(0) as Node3D
	var inv := node.global_transform.affine_inverse()
	var hit := PvLabBuilder.pick_panel(_design, inv * o, (inv.basis * d).normalized(), _tracker_preview)
	return int(hit.get("panel", -1))


func _pick_any_at(pos: Vector2) -> Dictionary:
	if _camera == null or _holder.get_child_count() == 0 or _tab != 2:
		return {}
	var vp_size := Vector2(_viewport.size)
	var cs := _vp_container.size
	var p := pos * (vp_size / cs) if cs.x > 0.0 and cs.y > 0.0 else pos
	var o := _camera.project_ray_origin(p)
	var d := _camera.project_ray_normal(p)
	var node := _holder.get_child(0) as Node3D
	var inv := node.global_transform.affine_inverse()
	return PvLabBuilder.pick_any(_design, inv * o, (inv.basis * d).normalized(), _tracker_preview, _show_modules)


func _describe_hit(hit: Dictionary) -> String:
	if hit.is_empty():
		return ""
	match str(hit["kind"]):
		"panel":
			return _describe_module(int(hit["index"]))
		"part":
			var p: Dictionary = _design["parts"][int(hit["index"])]
			return "%s · %s" % [str(PvLabHardware.part(str(p["type"]))["label"]), str(p["where"])]
		_:
			var mb: Dictionary = _design["members"][int(hit["index"])]
			return "%s · %s · %s" % [str(mb["label"]), str(PvLabRack.profile(str(mb["profile"]))["label"]),
				DomeLabSpec.fmt_m(float(mb["len_m"]))]


func _describe_module(idx: int) -> String:
	if idx < 0:
		return ""
	var where := "not in a string"
	for si in (_design["strings"] as Array).size():
		var st: Array = _design["strings"][si]
		var k := st.find(idx)
		if k >= 0:
			where = "string %d, %d of %d" % [si + 1, k + 1, st.size()]
	var p: Dictionary = (_design["layout"]["panels"] as Array)[idx]
	return "Module %d · row %d, %d across, %d up · %s" % [idx + 1, int(p["table"]) + 1, int(p["col"]) + 1, int(p["k"]) + 1, where]


func _on_module_clicked(idx: int) -> void:
	if idx < 0:
		return
	if not _painting:
		_picked = idx if _picked != idx else -1
		_rebuild_studio()
		return
	_ensure_custom()
	var custom: Array = _spec["strings"]["custom"]
	while custom.size() <= _paint_string:
		custom.append([])
	var cur: Array = custom[_paint_string]
	_push_undo("paint")
	if cur.has(idx):
		cur.erase(idx)
	else:
		for st in custom:
			(st as Array).erase(idx)
		cur.append(idx)
	_spec["strings"]["groups"] = []
	_rebuild_now()


func _ensure_custom() -> void:
	if str(_spec["strings"]["mode"]) == "custom":
		return
	_spec["strings"]["mode"] = "custom"
	_spec["strings"]["custom"] = (_design["strings"] as Array).duplicate(true)
	_built_key = ""


func _on_paint_toggled(on: bool) -> void:
	_painting = on
	if on:
		_ensure_custom()
		_paint_string = maxi((_spec["strings"]["custom"] as Array).size() - 1, 0)
		_rebuild_now()
	else:
		_rebuild_studio()
	_sync_notes()


func _on_new_string() -> void:
	_push_undo()
	_ensure_custom()
	var custom: Array = _spec["strings"]["custom"]
	custom.append([])
	_paint_string = custom.size() - 1
	if not _painting:
		_paint_btn.button_pressed = true
	_rebuild_now()


func _on_clear_strings() -> void:
	_push_undo()
	_spec["strings"]["mode"] = "custom"
	_spec["strings"]["custom"] = [[]]
	_spec["strings"]["groups"] = []
	_paint_string = 0
	_built_key = ""
	_rebuild_now()


# ---------------------------------------------------------------------------
# Export, place, apply
# ---------------------------------------------------------------------------

func export_dir() -> String:
	return ProjectSettings.globalize_path(EXPORT_ROOT.path_join(DomeLabCam.safe_name(str(_spec["name"]))))


func _write_files(dir: String) -> Dictionary:
	var r := PvLabCam.write_all(_design, dir)
	if bool(r["ok"]):
		_status("Wrote %s to %s" % [UiText.count((r["files"] as Array).size(), "file"), dir])
		_export_status.set_meta("last_dir", dir)
	else:
		_status("Export failed: %s" % str(r["error"]))
	return r


func _on_open_folder() -> void:
	var dir := str(_export_status.get_meta("last_dir", export_dir()))
	if not DirAccess.dir_exists_absolute(dir):
		_write_files(dir)
	OS.shell_open(dir)


func _status(text: String) -> void:
	if _export_status != null:
		_export_status.text = text


func _main_node() -> Node:
	var tree := get_tree()
	return tree.current_scene if tree != null else null


func _prop_record(prop_id: String) -> Dictionary:
	if _loader != null and _loader.has_method("get_prop_record"):
		var rec: Dictionary = _loader.call("get_prop_record", prop_id)
		if not rec.is_empty():
			return rec
	var main := _main_node()
	if main != null:
		return PlacedPropService.get_prop_record(main, prop_id)
	return {}


func _graph_strings() -> Array:
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("designed_array_strings") or _bound_prop_id.is_empty():
		return []
	return sgv.call("designed_array_strings", PlacedPropService.pvlab_array_tag(_bound_prop_id))


func _on_place() -> void:
	if _loader != null and _loader.has_method("begin_pvlab_placement"):
		if bool(_loader.call("begin_pvlab_placement", PvLabSpec.to_json_safe(_spec))):
			close()
			return
	_status("Placing needs a location map.")


func _on_apply() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	var pid := _bound_prop_id
	if main != null:
		PlacedPropService.update_prop_record(main, pid, {"pvlab_spec": PvLabSpec.to_json_safe(_spec)}, true)
		Callable(PlacedPropService, "seed_pvlab_graph").call_deferred(main, pid)
	close()


# ---------------------------------------------------------------------------
# Accessors for the tour and the harness
# ---------------------------------------------------------------------------

func design() -> Dictionary:
	return _design


func spec() -> Dictionary:
	return _spec


func load_builtin(id: String) -> void:
	var p := PvLabPresets.builtin(id)
	if p.is_empty():
		return
	_spec = PvLabSpec.resolve((p["spec"] as Dictionary).duplicate(true))
	_sel_kind = ""
	_sel_index = -1
	_picked = -1
	_built_key = ""
	_rebuild_now()
	_frame_camera()


func set_shade_test(id: String) -> void:
	_shade_test = id
	_refresh_live()
	_refresh_chart()


func live_text() -> String:
	var out := PackedStringArray()
	for c in _live_box.get_children():
		if c is Label:
			out.append((c as Label).text)
	return "\n".join(out)


func control_for(path: String, key: String) -> Control:
	for b in _bindings:
		if str(b["path"]) == path and str(b["key"]) == key and is_instance_valid(b["ctl"]):
			return b["ctl"]
	return null


func studio_container() -> Control:
	return _vp_container


## Screen position (in the studio container) of module `idx`'s centre.
func module_screen_pos(idx: int) -> Vector2:
	if _holder.get_child_count() == 0 or idx < 0:
		return Vector2(-1, -1)
	var node := _holder.get_child(0) as Node3D
	var p: Dictionary = (_design["layout"]["panels"] as Array)[idx]
	var wp := node.global_transform * PvLabArray.panel_xf(_design["layout"], p, _tracker_preview).origin
	var sp := _camera.unproject_position(wp)
	var cs := _vp_container.size
	return sp * (cs / Vector2(_viewport.size))


## Where part `idx` (PvLabDesign parts) is on the studio, in the container's
## coordinates: a point a little above where it sits.
func part_screen_pos(idx: int) -> Vector2:
	if _holder.get_child_count() == 0 or idx < 0 or idx >= (_design["parts"] as Array).size():
		return Vector2(-1, -1)
	var node := _holder.get_child(0) as Node3D
	var pt: Dictionary = _design["parts"][idx]
	var xf: Transform3D = pt["xf"]
	if int(pt["head"]) >= 0:
		xf = PvLabArray.head_xf(_design["layout"], int(pt["head"]), _tracker_preview) * xf
	var wp := node.global_transform * (xf * Vector3(0, float((pt["size"] as Vector3).y) * 0.5, 0))
	var sp := _camera.unproject_position(wp)
	return sp * (_vp_container.size / Vector2(_viewport.size))


func selection() -> Dictionary:
	return {"kind": _sel_kind, "index": _sel_index}


func part_card_text() -> String:
	var out: Array = []
	for c in _part_box.get_children():
		if c is Label:
			out.append((c as Label).text)
	return "\n".join(out)


## Point the studio camera (yaw, pitch rad; distance m) at a target.
func studio_view(target: Vector3, yaw: float, pitch: float, dist: float) -> void:
	_target = target
	_yaw = yaw
	_pitch = pitch
	_dist = dist
	_update_camera()


# ---------------------------------------------------------------------------
# The I–V / P–V chart
# ---------------------------------------------------------------------------

class IvChart extends Control:
	var curves: Array = []
	var mpp := Vector2.ZERO
	var title := ""

	func _draw() -> void:
		var r := Rect2(Vector2(52, 22), size - Vector2(104, 44))
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.08))
		if curves.is_empty() or r.size.x < 20.0 or r.size.y < 20.0:
			return
		var vmax := 1.0
		var imax := 0.1
		var pmax := 1.0
		for c in curves:
			var va: PackedFloat64Array = c["v"]
			var ia: PackedFloat64Array = c["i"]
			for k in va.size():
				vmax = maxf(vmax, va[k])
				imax = maxf(imax, ia[k])
				pmax = maxf(pmax, va[k] * ia[k])
		vmax *= 1.05
		imax *= 1.1
		pmax *= 1.1
		var font := ThemeDB.fallback_font
		var fs := UITheme.FONT_XS
		draw_rect(r, Color(0.25, 0.27, 0.3), false, 1.0)
		for k in 5:
			var x := r.position.x + r.size.x * float(k) / 4.0
			draw_string(font, Vector2(x - 12, r.end.y + 14), "%.0f V" % (vmax * float(k) / 4.0), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.C_TEXT_M)
			var y := r.end.y - r.size.y * float(k) / 4.0
			draw_string(font, Vector2(4, y + 4), "%.1f A" % (imax * float(k) / 4.0), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.C_TEXT_M)
			draw_string(font, Vector2(r.end.x + 4, y + 4), "%.0f W" % (pmax * float(k) / 4.0), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.C_TEXT_M)
		for c in curves:
			var va2: PackedFloat64Array = c["v"]
			var ia2: PackedFloat64Array = c["i"]
			var col: Color = c["color"]
			var iv_pts := PackedVector2Array()
			var pv_pts := PackedVector2Array()
			for k in va2.size():
				var vk := va2[k]
				var ik := ia2[k]
				if vk < 0.0:
					# Past short circuit (bypass diodes conducting): draw up
					# to the 0 V crossing between this point and its
					# neighbour, never past it.
					var nb := -1
					if k > 0 and va2[k - 1] > 0.0:
						nb = k - 1
					elif k + 1 < va2.size() and va2[k + 1] > 0.0:
						nb = k + 1
					if nb < 0:
						continue
					var f := va2[nb] / (va2[nb] - vk)
					ik = ia2[nb] + (ik - ia2[nb]) * f
					vk = 0.0
				var x2 := r.position.x + r.size.x * vk / vmax
				iv_pts.append(Vector2(x2, r.end.y - r.size.y * ik / imax))
				pv_pts.append(Vector2(x2, r.end.y - r.size.y * vk * ik / pmax))
			if iv_pts.size() > 1:
				draw_polyline(iv_pts, col, 2.0, true)
				draw_polyline(pv_pts, Color(col.r, col.g, col.b, 0.55), 1.5, true)
		if mpp != Vector2.ZERO:
			var mp := Vector2(r.position.x + r.size.x * mpp.x / vmax, r.end.y - r.size.y * mpp.y / imax)
			draw_circle(mp, 4.0, UITheme.C_OK)
			var pp := Vector2(mp.x, r.end.y - r.size.y * mpp.x * mpp.y / pmax)
			draw_circle(pp, 4.0, UITheme.C_OK)
		draw_string(font, Vector2(r.position.x, 15), title + "   (solid: current, faint: power)",
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 60.0, fs, UITheme.C_TEXT_S)
