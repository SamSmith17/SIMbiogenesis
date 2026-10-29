extends Control

## The Pelton wheel designer. Every wheel is built from the same cup (the
## shipped STL — the common split-bucket style); the player designs round
## it: how many cups and how big the wheel, the side discs that clamp the
## cup tabs, the hub, shaft and bolt pattern, the jets, the housing, the
## shaft's bearings and drive, the generator — and sees what that does to
## the speed and the power.
##
## Left:   built-in wheels and the player's library.
## Centre: the machine in a 3D studio (the housing see-through or cut away,
##         the wheel spinning at its real speed, the jets), the wheel drawn
##         face-on with its circles and bolt pattern, and the performance
##         sweeps (power and speed against the wheel's size and its cups).
## Right:  wheel, rotor + hub, jets, housing, bearings + drive, generator,
##         site, the operating numbers, the checks, the bill of materials.
## Footer: apply to the Hydro Lab's turbine (when opened from it), place a
##         new turbine in the world, close.
##
## It runs on its own (Library → "Pelton wheel designer…") or opened from
## the Hydro Lab bound to a turbine: then the site is that turbine's head and
## pipe, and Apply writes the wheel onto it (PeltonLabDesign.turbine_patch +
## SystemGraphView.apply_pelton_design).

const MODAL_NAME := "peltonlab_designer"
const WANT := Vector2(1600, 960)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.12
const EXPORT_ROOT := "user://peltonlab_designs"

var _active := false
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _turbine_id := ""
var _graph_view: Node = null
var _bound_prop_id := ""
var _op: Dictionary = {}
var _undo: Array = []
var _redo: Array = []
var _coalesce_key := ""
var _coalesce_until := 0.0
var _rebuild_timer := -1.0
var _built_geom := ""
var _suppress := false
var _bindings: Array = []
var _library: Array = []
var _sweep_d: Array = []
var _sweep_z: Array = []
var _housing_view := "cut"
var _spinning := true
var _show_jets := true

# UI
var _panel: PanelContainer
var _name_edit: LineEdit
var _subtitle: Label
var _undo_btn: Button
var _redo_btn: Button
var _design_list: ItemList
var _design_entries: Array = []
var _tabs: TabBar
var _view_stack: Control
var _vp_container: SubViewportContainer
var _viewport: SubViewport
var _studio: Node3D
var _holder: Node3D
var _camera: Camera3D
var _builder: PeltonLabBuilder = null
var _wheel_canvas: Control
var _perf_canvas: Control
var _studio_bar: HBoxContainer
var _hover_lbl: Label
var _boxes: Dictionary = {}
var _numbers: GridContainer
var _warn_box: VBoxContainer
var _bom_box: VBoxContainer
var _bom_lbl: Label
var _status_lbl: Label
var _bound_lbl: Label
var _apply_btn: Button
var _place_btn: Button

# Studio camera
var _yaw := 0.4
var _pitch := 0.35
var _dist := 2.0
var _target := Vector3(0, 0.4, 0)
var _orbiting := false
var _press_pos := Vector2.ZERO
var _moved := false
var _hover_frame := 0


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process(false)


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

## opts: {spec, turbine_id, graph_view, prop_id}.
func open(opts: Dictionary = {}) -> void:
	if _active:
		close()
	_turbine_id = str(opts.get("turbine_id", ""))
	_graph_view = opts.get("graph_view", null) as Node
	_bound_prop_id = str(opts.get("prop_id", ""))
	var spec: Dictionary = opts.get("spec", {}) as Dictionary
	if spec.is_empty() and not _turbine_id.is_empty():
		spec = _spec_from_turbine()
	if spec.is_empty() and not _bound_prop_id.is_empty():
		var rec := _prop_record(_bound_prop_id)
		spec = rec.get("pelton_spec", {}) as Dictionary
	_spec = PeltonLabSpec.resolve(spec if not spec.is_empty() else PeltonLabPresets.classic_spec())
	_undo.clear()
	_redo.clear()
	_library = PeltonLabPresets.load_library()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	UiFit.keep_fitted(_panel, WANT)
	_refresh_design_list()
	_built_geom = ""
	_rebuild_now()
	_frame_camera()


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	CursorController.release_modal(MODAL_NAME)


func is_open() -> bool:
	return _active


## A turbine on the graph → a wheel spec: its saved design, else the classic
## wheel with the turbine's jets and site.
func _spec_from_turbine() -> Dictionary:
	var item := _turbine_item()
	if item.is_empty():
		return {}
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	var saved: Dictionary = sp.get("pelton_spec", {}) as Dictionary
	var s := PeltonLabSpec.resolve(saved if not saved.is_empty() else PeltonLabPresets.classic_spec())
	if saved.is_empty():
		s["name"] = "%s wheel" % str(sp.get("name", "Turbine"))
		s["jets"]["count"] = clampi(int(sp.get("nozzle_count", 1)), 1, 2)
		s["jets"]["d_mm"] = float(sp.get("nozzle_diameter_mm", s["jets"]["d_mm"]))
	return s


func _turbine_item() -> Dictionary:
	if _graph_view == null or not is_instance_valid(_graph_view) or _turbine_id.is_empty():
		return {}
	var m: Variant = _graph_view.get("model")
	if m == null:
		return {}
	return (m as GraphModel).get_item(_turbine_id)


## The bound turbine's site + live operating point override the design's own.
func _sync_site_from_turbine() -> void:
	_op = {}
	var item := _turbine_item()
	if item.is_empty():
		return
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	var st: Dictionary = _spec["site"]
	st["gross_head_m"] = maxf(float(sp.get("gross_head_m", st["gross_head_m"])), 0.5)
	st["pipe_len_m"] = float(sp.get("penstock_length_m", st["pipe_len_m"]))
	st["pipe_d_mm"] = float(sp.get("penstock_diameter_mm", st["pipe_d_mm"]))
	st["roughness_mm"] = float(sp.get("pipe_roughness_mm", st["roughness_mm"]))
	st["supply_lps"] = float(sp["supply_lps"]) if sp.has("supply_lps") else -1.0


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


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var icon := TextureRect.new()
	icon.texture = UiIcons.icon("settings", 22)
	icon.modulate = UITheme.C_PRIMARY
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(icon)
	var title := Label.new()
	title.text = "Pelton wheel designer"
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title.add_theme_color_override("font_color", UITheme.C_TEXT)
	row.add_child(title)
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(240, 0)
	_name_edit.placeholder_text = "Design name"
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
	var col := _scroll_column(240)
	var box: VBoxContainer = col[1]
	box.add_child(SectionHeader.make("Wheels", "layout-grid"))
	_design_list = ItemList.new()
	_design_list.custom_minimum_size = Vector2(0, 220)
	_design_list.auto_height = true
	_design_list.item_selected.connect(_on_design_activated)
	box.add_child(_design_list)
	var lib := HBoxContainer.new()
	for b in [["Save design", "Keep this wheel in your library (every world)", _on_save_design],
			["Forget", "Remove the selected saved wheel", _on_forget_design]]:
		var btn := Button.new()
		btn.text = str(b[0])
		btn.tooltip_text = str(b[1])
		UITheme.style_button(btn)
		btn.pressed.connect(b[2])
		lib.add_child(btn)
	box.add_child(lib)
	_note(box, "Every wheel uses the same cup — the common split bucket with one root tab, " +
		"clamped between two side discs. Its size scales it whole. The cups' pitch circle " +
		"(where the jet meets them) and the jet decide the speed: rpm = 60·2·0.46·v_jet / (π·PCD). " +
		"A bigger wheel turns slower with more torque; the cup count and the cup-to-jet ratio decide " +
		"how much of the jet is caught.")
	return col[0]


func _build_centre() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_tabs = TabBar.new()
	_tabs.add_tab("Machine")
	_tabs.add_tab("Wheel")
	_tabs.add_tab("Performance")
	_tabs.tab_changed.connect(func(_i): _show_view())
	col.add_child(_tabs)
	_view_stack = Control.new()
	_view_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_stack.clip_contents = true
	col.add_child(_view_stack)
	_vp_container = SubViewportContainer.new()
	_vp_container.stretch = true
	_vp_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vp_container.gui_input.connect(_on_studio_input)
	_vp_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_view_stack.add_child(_vp_container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.size = Vector2i(900, 640)
	_vp_container.add_child(_viewport)
	_build_studio_world()
	_wheel_canvas = WheelCanvas.new()
	_wheel_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wheel_canvas.visible = false
	_wheel_canvas.set("owner_modal", self)
	_view_stack.add_child(_wheel_canvas)
	_perf_canvas = PerfCanvas.new()
	_perf_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_perf_canvas.visible = false
	_perf_canvas.set("owner_modal", self)
	_view_stack.add_child(_perf_canvas)
	_studio_bar = HBoxContainer.new()
	_studio_bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var hl := Label.new()
	hl.text = "Housing"
	_studio_bar.add_child(hl)
	var hv := OptionButton.new()
	for m in [["cut", "Cut away"], ["window", "Window"], ["ghost", "See-through"], ["solid", "Solid"], ["hidden", "Hidden"]]:
		hv.add_item(str(m[1]))
		hv.set_item_metadata(hv.item_count - 1, m[0])
	hv.item_selected.connect(func(i): _housing_view = str(hv.get_item_metadata(i)); _apply_studio_view())
	_studio_bar.add_child(hv)
	var spin := CheckBox.new()
	spin.text = "Spin at its speed"
	spin.button_pressed = true
	spin.tooltip_text = "The wheel turns at its design speed (slowed to read at high rpm)"
	spin.toggled.connect(func(v): _spinning = v; _apply_studio_view())
	_studio_bar.add_child(spin)
	var jets := CheckBox.new()
	jets.text = "Jets"
	jets.button_pressed = true
	jets.toggled.connect(func(v): _show_jets = v; _apply_studio_view())
	_studio_bar.add_child(jets)
	_studio_bar.add_child(IconButton.make("scan", "Frame the machine", func(): _yaw = 0.4; _pitch = 0.35; _frame_camera()))
	_hover_lbl = Label.new()
	_hover_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hover_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hover_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hover_lbl.clip_text = true
	_hover_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_studio_bar.add_child(_hover_lbl)
	col.add_child(_studio_bar)
	return col


func _build_studio_world() -> void:
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.035, 0.043, 0.063)
	var skymat := ProceduralSkyMaterial.new()
	skymat.sky_top_color = Color(0.62, 0.68, 0.78)
	skymat.sky_horizon_color = Color(0.42, 0.42, 0.44)
	skymat.ground_horizon_color = Color(0.22, 0.21, 0.20)
	skymat.ground_bottom_color = Color(0.08, 0.08, 0.08)
	var sky := Sky.new()
	sky.sky_material = skymat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.9
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.ssao_enabled = true
	e.ssao_radius = 0.15
	e.ssao_intensity = 1.2
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.05
	env.environment = e
	_studio.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-52, 35, 0)
	key.light_energy = 1.5
	key.light_color = Color(1.0, 0.96, 0.9)
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 12.0
	key.shadow_normal_bias = 1.2
	_studio.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -140, 0)
	fill.light_energy = 0.3
	fill.light_color = Color(0.8, 0.88, 1.0)
	_studio.add_child(fill)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30, 30)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.13, 0.125, 0.12)
	gmat.roughness = 0.95
	ground.material_override = gmat
	_studio.add_child(ground)
	_holder = Node3D.new()
	_holder.name = "Holder"
	_studio.add_child(_holder)
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.near = 0.01
	_camera.far = 60.0
	_studio.add_child(_camera)
	_update_camera()


func _build_right() -> Control:
	var col := _scroll_column(410)
	var box: VBoxContainer = col[1]
	_bound_lbl = Label.new()
	_bound_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bound_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_bound_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	box.add_child(_bound_lbl)
	for sec in [["wheel", "Wheel", true], ["rotor", "Rotor discs, hub and bolt pattern", true],
			["jets", "Jets", true], ["housing", "Housing", false], ["drive", "Shaft, bearings and drive", true],
			["generator", "Generator", true], ["site", "Site", false], ["colors", "Colours", false]]:
		var c := Collapsible.make(str(sec[1]), bool(sec[2]))
		box.add_child(c)
		_boxes[str(sec[0])] = c.body
	box.add_child(SectionHeader.make("Operating point", "gauge"))
	_numbers = GridContainer.new()
	_numbers.columns = 2
	_numbers.add_theme_constant_override("h_separation", UITheme.SPACE_MD)
	box.add_child(_numbers)
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
	for b in [["Export files", "Rotor disc + spacer DXF/SVG cut files, the BOM CSV and the design JSON", _on_export],
			["Open folder", "Show the exported files", _on_open_folder],
			["Copy summary", "The design and its numbers as text", _on_copy_summary]]:
		var btn := Button.new()
		btn.text = str(b[0])
		btn.tooltip_text = str(b[1])
		UITheme.style_button(btn)
		btn.pressed.connect(b[2])
		ex.add_child(btn)
	box.add_child(ex)
	_status_lbl = Label.new()
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_status_lbl)
	_build_settings_rows()
	return col[0]


func _build_footer() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var hint := Label.new()
	hint.text = "Drag to orbit · wheel to zoom · hover a part to name it"
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(hint)
	_apply_btn = Button.new()
	_apply_btn.text = "Apply to turbine"
	_apply_btn.tooltip_text = "Write this wheel onto the Hydro Lab's turbine: its PCD, efficiencies, jets, generator rating and 3D model"
	UITheme.style_button(_apply_btn)
	_apply_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_apply_btn.pressed.connect(func(): apply())
	row.add_child(_apply_btn)
	_place_btn = Button.new()
	_place_btn.text = "Place in world"
	_place_btn.tooltip_text = "Place a new turbine built to this design (its graph node comes with it)"
	UITheme.style_button(_place_btn)
	_place_btn.pressed.connect(_on_place)
	row.add_child(_place_btn)
	var close_b := Button.new()
	close_b.text = "Close"
	UITheme.style_button(close_b)
	close_b.pressed.connect(close)
	row.add_child(close_b)
	return row


# ---------------------------------------------------------------------------
# Settings rows
# ---------------------------------------------------------------------------

func _row(parent: Container, label: String, control: Control, tip: String = "") -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(176, 0)
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


func _note(parent: Container, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	parent.add_child(l)
	return l


func _bind_spin(parent: Container, label: String, group: String, key: String, min_v: float, max_v: float,
		step: float, suffix: String, tip: String = "", is_int: bool = false) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.suffix = suffix
	s.value_changed.connect(func(v): _edit(group, key, int(v) if is_int else v))
	_row(parent, label, s, tip)
	_bindings.append({"ctl": s, "group": group, "key": key})
	return s


func _bind_check(parent: Container, text: String, group: String, key: String, tip: String = "") -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.toggled.connect(func(v): _edit(group, key, v))
	parent.add_child(c)
	_bindings.append({"ctl": c, "group": group, "key": key})
	return c


func _bind_option(parent: Container, label: String, group: String, key: String, items: Array, tip: String = "") -> OptionButton:
	var o := OptionButton.new()
	for i in items.size():
		o.add_item(str(items[i][1]), i)
		o.set_item_metadata(i, items[i][0])
	o.item_selected.connect(func(idx): _edit(group, key, o.get_item_metadata(idx)))
	_row(parent, label, o, tip)
	_bindings.append({"ctl": o, "group": group, "key": key})
	return o


func _bind_color(parent: Container, label: String, key: String) -> void:
	var c := ColorPickerButton.new()
	c.custom_minimum_size = Vector2(60, 24)
	c.color_changed.connect(func(col): _edit("colors", key, [col.r, col.g, col.b, col.a]))
	_row(parent, label, c)
	_bindings.append({"ctl": c, "group": "colors", "key": key})


func _table_items(table: Dictionary) -> Array:
	var out: Array = []
	for id in table:
		out.append([id, str(table[id]["label"])])
	return out


func _build_settings_rows() -> void:
	_bindings.clear()
	var w: VBoxContainer = _boxes["wheel"]
	_bind_spin(w, "Cups", "runner", "cups", PeltonLabSpec.MIN_CUPS, PeltonLabSpec.MAX_CUPS, 1, "",
		"How many cups round the wheel (15 + PCD/(2·jet) is the classic rule)", true)
	_bind_spin(w, "Overall Ø (tip to tip)", "runner", "overall_d_mm", 60, 3000, 1, " mm",
		"The wheel's outside diameter across the cup tips — sets the pitch circle and so the speed")
	_bind_spin(w, "Cup size (width)", "runner", "cup_width_mm", 20, 300, 0.5, " mm",
		"The cup's width across its splitter; the STL is 79 mm and is scaled whole")
	_bind_option(w, "Cup material", "runner", "cup_material", _table_items(PeltonLabParts.CUP_MATERIALS),
		"Sets the cups' weight (the pull on the bolts at runaway) and how much stress the tabs take")
	_bind_spin(w, "Cup tilt", "runner", "cup_tilt_deg", -20, 20, 0.5, "°",
		"Turn every cup about its width axis (0 = radial)")
	_bind_option(w, "Shaft", "", "orientation", [["horizontal", "Horizontal shaft"], ["vertical", "Vertical shaft"]],
		"A vertical shaft takes up to six jets round the wheel; a horizontal one two")
	var bt := Button.new()
	bt.text = "Set cups by the 15 + m/2 rule"
	UITheme.style_button(bt)
	bt.pressed.connect(_on_cups_by_rule)
	w.add_child(bt)
	var r: VBoxContainer = _boxes["rotor"]
	_bind_spin(r, "Disc Ø (0 = to the bowls)", "rotor", "disc_d_mm", 0, 3000, 1, " mm",
		"The two side discs that clamp the cup tabs; 0 runs them to just under the bowls")
	_bind_spin(r, "Disc thickness", "rotor", "disc_t_mm", 1, 30, 0.5, " mm")
	_bind_option(r, "Disc material", "rotor", "material", _table_items(PeltonLabParts.PLATE_MATERIALS))
	_bind_option(r, "Bolts per cup", "runner", "cup_bolts", [[1, "One"], [2, "Two"]])
	_bind_option(r, "Cup bolt", "runner", "cup_bolt", _bolt_items())
	_bind_option(r, "Shaft Ø", "hub", "shaft_d_mm", _shaft_items(), "Picks the bearing inserts too")
	_bind_check(r, "Keyway in shaft and hub", "hub", "keyway")
	_bind_spin(r, "Hub bolts (pattern)", "hub", "bolts", 3, 12, 1, "", "Bolts through the hub flange, discs and spacer", true)
	_bind_option(r, "Hub bolt", "hub", "bolt", _bolt_items())
	_bind_spin(r, "Bolt circle Ø (0 = auto)", "hub", "bolt_pcd_mm", 0, 1000, 0.5, " mm")
	_bind_spin(r, "Hub flange Ø (0 = auto)", "hub", "flange_d_mm", 0, 1000, 0.5, " mm")
	_bind_spin(r, "Hub boss Ø (0 = auto)", "hub", "boss_d_mm", 0, 500, 0.5, " mm")
	_bind_spin(r, "Hub boss length (0 = auto)", "hub", "boss_len_mm", 0, 500, 0.5, " mm")
	var j: VBoxContainer = _boxes["jets"]
	_bind_spin(j, "Jets", "jets", "count", 1, 6, 1, "", "Nozzles round the wheel", true)
	_bind_spin(j, "Jet Ø", "jets", "d_mm", 1, 150, 0.5, " mm", "The nozzle's bore — with the head, it sets the flow")
	_bind_spin(j, "First jet at (-1 = auto)", "jets", "start_deg", -1, 359, 1, "°",
		"Where round the wheel the first jet meets the cups (0° = top for a horizontal shaft)")
	_bind_spin(j, "Between jets (0 = auto)", "jets", "spacing_deg", 0, 180, 1, "°")
	_bind_spin(j, "Nozzle stand-off (0 = auto)", "jets", "standoff_mm", 0, 500, 1, " mm",
		"From the nozzle's mouth to where the jet meets the pitch circle")
	var bj := Button.new()
	bj.text = "Size the jet to the cups (B = 3.2 d)"
	UITheme.style_button(bj)
	bj.pressed.connect(_on_jet_to_cups)
	j.add_child(bj)
	var h: VBoxContainer = _boxes["housing"]
	_bind_check(h, "Size it round the wheel", "housing", "auto",
		"Clearance round the cup tips and 3 × the cup width across the shaft")
	_bind_spin(h, "Across the shaft (inside)", "housing", "axial_mm", 50, 5000, 1, " mm")
	_bind_spin(h, "Height (inside)", "housing", "height_mm", 50, 5000, 1, " mm")
	_bind_spin(h, "Depth (inside)", "housing", "depth_mm", 50, 5000, 1, " mm")
	_bind_spin(h, "Tip clearance (0 = auto)", "housing", "clear_mm", 0, 1000, 1, " mm")
	_bind_spin(h, "Wall", "housing", "wall_mm", 1, 30, 0.5, " mm")
	_bind_option(h, "Material", "housing", "material", _table_items(PeltonLabParts.PLATE_MATERIALS))
	_bind_check(h, "Clear front window", "housing", "window")
	_bind_check(h, "Base frame / legs", "housing", "base")
	var dv: VBoxContainer = _boxes["drive"]
	_bind_option(dv, "Bearings", "drive", "bearings", [["pillow", "Pillow blocks (UCP)"], ["flange", "Flange units (UCFL)"]])
	_bind_option(dv, "Layout", "drive", "layout", [["overhung", "Both on the drive side"], ["straddle", "One each side of the wheel"]],
		"Overhung keeps the far wall plain; straddling halves the shaft's bending")
	_bind_spin(dv, "Bearing centres (0 = auto)", "drive", "span_mm", 0, 2000, 1, " mm")
	_bind_option(dv, "Drive", "drive", "type", _table_items(PeltonLabParts.DRIVES))
	_bind_option(dv, "Coupler", "drive", "coupler", _table_items(PeltonLabParts.COUPLERS))
	_bind_spin(dv, "Wheel pulley Ø (V-belt)", "drive", "driver_d_mm", 20, 1000, 1, " mm")
	_bind_spin(dv, "Generator pulley Ø (V-belt)", "drive", "driven_d_mm", 20, 1000, 1, " mm")
	_bind_spin(dv, "Wheel teeth (timing / gear)", "drive", "driver_teeth", 8, 200, 1, "", "", true)
	_bind_spin(dv, "Generator teeth", "drive", "driven_teeth", 8, 200, 1, "", "", true)
	_bind_spin(dv, "Gear module", "drive", "module_mm", 0.5, 10, 0.5, " mm")
	_bind_option(dv, "Generator sits", "drive", "gen_side", [["above", "Above the shaft"], ["beside", "Beside the shaft"]])
	_bind_spin(dv, "Belt centres (0 = auto)", "drive", "centre_mm", 0, 3000, 1, " mm")
	var bm := Button.new()
	bm.text = "Match the ratio to the generator"
	bm.tooltip_text = "Pick the generator pulley / teeth so the generator runs at its rated speed"
	UITheme.style_button(bm)
	bm.pressed.connect(_on_match_ratio)
	dv.add_child(bm)
	var g: VBoxContainer = _boxes["generator"]
	_bind_option(g, "Generator", "generator", "id", _table_items(PeltonLabParts.GENERATORS))
	_bind_spin(g, "Battery bank", "site", "battery_v", 0, 400, 1, " V", "What it charges (0 = not checked)")
	_note(g, "Ratings are typical for each class; check your own generator's plate.")
	var st: VBoxContainer = _boxes["site"]
	_bind_spin(st, "Gross head", "site", "gross_head_m", 0.5, 1000, 0.1, " m")
	_bind_spin(st, "Penstock length", "site", "pipe_len_m", 0, 5000, 1, " m")
	_bind_spin(st, "Penstock bore", "site", "pipe_d_mm", 10, 1000, 1, " mm")
	_bind_spin(st, "Water available (-1 = any)", "site", "supply_lps", -1, 2000, 0.1, " L/s")
	_note(st, "Opened from the Hydro Lab, the site is that turbine's head, pipe and water.")
	var c: VBoxContainer = _boxes["colors"]
	for ck in [["Cups (printed)", "cup"], ["Discs", "disc"], ["Housing", "housing"], ["Base", "frame"], ["Generator", "generator"]]:
		_bind_color(c, str(ck[0]), str(ck[1]))


func _bolt_items() -> Array:
	var out: Array = []
	for id in PeltonLabParts.BOLTS:
		out.append([id, str(id).to_upper()])
	return out


func _shaft_items() -> Array:
	var out: Array = []
	for s in PeltonLabParts.SHAFTS:
		out.append([float(s), "%.0f mm" % float(s)])
	return out


func _sync_settings() -> void:
	_suppress = true
	for b in _bindings:
		var grp := str(b["group"])
		var v: Variant = _spec.get(str(b["key"])) if grp.is_empty() else (_spec[grp] as Dictionary).get(str(b["key"]))
		var ctl: Control = b["ctl"]
		if ctl is SpinBox:
			if not (ctl as SpinBox).get_line_edit().has_focus():
				(ctl as SpinBox).set_value_no_signal(float(v))
		elif ctl is CheckBox:
			(ctl as CheckBox).set_pressed_no_signal(bool(v))
		elif ctl is OptionButton:
			var o := ctl as OptionButton
			for i in o.item_count:
				var m: Variant = o.get_item_metadata(i)
				if str(m) == str(v) or (m is float and absf(float(m) - float(v)) < 0.01) or (m is int and int(m) == int(v)):
					o.select(i)
					break
		elif ctl is ColorPickerButton:
			(ctl as ColorPickerButton).color = v if v is Color else Color.WHITE
	_suppress = false
	# Rows that only matter for some choices.
	var dtype := str(_spec["drive"]["type"])
	for b in _bindings:
		var k := str(b["key"])
		var row := (b["ctl"] as Control).get_parent() as Control
		if row == null or not (row is HBoxContainer):
			continue
		var show := true
		match k:
			"driver_d_mm", "driven_d_mm":
				show = dtype == "vbelt"
			"driver_teeth", "driven_teeth":
				show = dtype == "timing" or dtype == "gear"
			"module_mm":
				show = dtype == "gear"
			"coupler":
				show = dtype == "direct"
			"gen_side", "centre_mm":
				show = dtype != "direct"
			"axial_mm", "height_mm", "depth_mm":
				show = not bool(_spec["housing"]["auto"])
		row.visible = show


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
	_update_undo_buttons()


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(_spec.duplicate(true))
	_spec = _undo.pop_back()
	_coalesce_key = ""
	_rebuild_now()


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_spec.duplicate(true))
	_spec = _redo.pop_back()
	_coalesce_key = ""
	_rebuild_now()


func _update_undo_buttons() -> void:
	if _undo_btn != null:
		_undo_btn.disabled = _undo.is_empty()
	if _redo_btn != null:
		_redo_btn.disabled = _redo.is_empty()


func _edit(group: String, key: String, value: Variant) -> void:
	if _suppress:
		return
	_push_undo(group + "." + key)
	if group.is_empty():
		_spec[key] = value
	else:
		var g: Dictionary = _spec.get(group, {})
		g[key] = value
		_spec[group] = g
	_rebuild_timer = REBUILD_DELAY


## Apply a whole spec (harness, presets) — one undo step.
func set_spec(spec: Dictionary) -> void:
	_push_undo()
	_spec = PeltonLabSpec.resolve(spec)
	_rebuild_now()


func _on_name_changed() -> void:
	var t := _name_edit.text.strip_edges()
	if t.is_empty() or t == str(_spec.get("name", "")):
		return
	_edit("", "name", t)


func _on_cups_by_rule() -> void:
	var rules: Dictionary = _design["rules"]
	var z := clampi(int(round(float(rules["z_opt"]))), PeltonLabSpec.MIN_CUPS, mini(int(rules["max_cups"]), PeltonLabSpec.MAX_CUPS))
	_push_undo()
	_spec["runner"]["cups"] = z
	_rebuild_now()


func _on_jet_to_cups() -> void:
	_push_undo()
	_spec["jets"]["d_mm"] = snappedf(float(_spec["runner"]["cup_width_mm"]) / 3.2, 0.5)
	_rebuild_now()


## Choose the generator-side pulley / teeth so the generator meets its rated
## speed at the wheel's design speed.
func _on_match_ratio() -> void:
	var perf: Dictionary = _design["perf"]
	var gen := PeltonLabParts.generator(str(_spec["generator"]["id"]))
	var rpm := float(perf["rpm"])
	if rpm <= 1.0:
		return
	var want := float(gen["rated_rpm"]) / rpm
	_push_undo()
	var dr: Dictionary = _spec["drive"]
	match str(dr["type"]):
		"direct":
			_status("A direct drive turns the generator at the wheel's speed — choose a belt or gears to change the ratio (it wants %.2f : 1)." % want)
		"vbelt":
			dr["driven_d_mm"] = clampf(snappedf(float(dr["driver_d_mm"]) / want, 1.0), 63.0, 1000.0)
		_:
			dr["driven_teeth"] = clampi(int(round(float(dr["driver_teeth"]) / want)), 14, 200)
	_rebuild_now()


# ---------------------------------------------------------------------------
# Rebuild
# ---------------------------------------------------------------------------

func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = PeltonLabSpec.resolve(_spec)
	if not _turbine_id.is_empty():
		_sync_site_from_turbine()
	_design = PeltonLabDesign.solve(_spec)
	if not _op.is_empty():
		_design["perf"] = PeltonLabDesign.performance(_design, _op)
	_sync_settings()
	var gk := PeltonLabSpec.geometry_key(_spec)
	if gk != _built_geom:
		_built_geom = gk
		_rebuild_studio()
	_apply_studio_view()
	_compute_sweeps()
	_refresh_numbers()
	_refresh_checks()
	_refresh_bom()
	_refresh_header()
	_wheel_canvas.queue_redraw()
	_perf_canvas.queue_redraw()
	_show_view()
	_update_undo_buttons()


func _refresh_header() -> void:
	if not _name_edit.has_focus():
		_name_edit.text = str(_spec["name"])
	var p: Dictionary = _design["perf"]
	_subtitle.text = "%s · %d rpm · %s" % [PeltonLabSpec.describe(_spec), int(round(float(p["rpm"]))),
		UiText.num(float(p["p_elec_w"]), "W")]
	_apply_btn.visible = not _turbine_id.is_empty()
	var item := _turbine_item()
	_bound_lbl.visible = not item.is_empty()
	if not item.is_empty():
		_bound_lbl.text = "Designing the wheel of %s — its head (%.1f m), penstock and water are the site." % [
			str((item.get("specs", {}) as Dictionary).get("name", "the turbine")), float(_spec["site"]["gross_head_m"])]


## The speed / power sweeps for the Performance tab: the wheel's overall Ø at
## its cups and cup size, and the cup count at its size.
func _compute_sweeps() -> void:
	_sweep_d.clear()
	_sweep_z.clear()
	var d0 := float(_spec["runner"]["overall_d_mm"])
	var lo := maxf(d0 * 0.45, 160.0 * float(_design["runner"]["k"]))
	var hi := d0 * 1.9
	for i in 17:
		var s := _spec.duplicate(true)
		s["runner"]["overall_d_mm"] = lerpf(lo, hi, float(i) / 16.0)
		var dd := PeltonLabDesign.solve(s)
		var pf: Dictionary = dd["perf"] if _op.is_empty() else PeltonLabDesign.performance(dd, _op)
		_sweep_d.append({"x": float(s["runner"]["overall_d_mm"]), "p": float(pf["p_elec_w"]), "rpm": float(pf["rpm"]),
			"eta": float(dd["rules"]["eta_runner"]), "ok": PeltonLabDesign.worst_level(dd) != "error"})
	var zc := int(_spec["runner"]["cups"])
	for z in range(maxi(PeltonLabSpec.MIN_CUPS, zc - 10), mini(PeltonLabSpec.MAX_CUPS, zc + 10) + 1):
		var s2 := _spec.duplicate(true)
		s2["runner"]["cups"] = z
		var d2 := PeltonLabDesign.solve(s2)
		var pf2: Dictionary = d2["perf"] if _op.is_empty() else PeltonLabDesign.performance(d2, _op)
		_sweep_z.append({"x": float(z), "p": float(pf2["p_elec_w"]), "rpm": float(pf2["rpm"]),
			"eta": float(d2["rules"]["eta_runner"]), "ok": z <= int(d2["rules"]["max_cups"])})


func _refresh_numbers() -> void:
	for c in _numbers.get_children():
		_numbers.remove_child(c)
		c.queue_free()
	var p: Dictionary = _design["perf"]
	var rn: Dictionary = _design["runner"]
	var r: Dictionary = _design["rules"]
	var rows := [
		["Water", "%.2f L/s at %.1f m net" % [float(p["q_lps"]), float(p["h_net_m"])]],
		["Jet", "%.1f m/s" % float(p["v_jet_ms"])],
		["Pitch circle", "Ø %.0f mm (m = %.1f)" % [float(rn["pcd_mm"]), float(r["m"])]],
		["Wheel speed", "%d rpm (runaway %d)" % [int(round(float(p["rpm"]))), int(round(float(p["rpm_runaway"])))]],
		["Torque", "%.1f N·m (stalled %.0f)" % [float(p["torque_nm"]), float(p["t_stall_nm"])]],
		["Runner", "%.0f %% (rules × %.2f)" % [float(p["eta_runner"]) * 100.0, float(r["factor"])]],
		["Generator", "%d rpm, %.0f %%, %.1f V open circuit" % [int(round(float(p["gen_rpm"]))), float(p["gen_eff"]) * 100.0, float(p["v_oc"])]],
		["Drive", "%.2f : 1, %.0f %%" % [float(_design["drive"]["ratio"]), float(p["drive_eff"]) * 100.0]],
		["Water power", UiText.num(float(p["p_hyd_w"]), "W")],
		["Shaft power", UiText.num(float(p["p_shaft_w"]), "W")],
		["Electrical", "%s%s" % [UiText.num(float(p["p_elec_w"]), "W"), " (generator's limit)" if bool(p["capped"]) else ""]],
		["Water to wire", "%.0f %%" % (float(p["water_to_wire"]) * 100.0)],
		["Weight", "%s (spinning %s)" % [PeltonLabSpec.fmt_kg(float(_design["mass"]["total"])), PeltonLabSpec.fmt_kg(float(_design["mass"]["rotating"]))]],
	]
	for row in rows:
		var k := Label.new()
		k.text = str(row[0])
		k.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_numbers.add_child(k)
		var v := Label.new()
		v.text = str(row[1])
		v.add_theme_color_override("font_color", UITheme.C_TEXT)
		v.add_theme_font_override("font", UITheme.font("regular", true))
		_numbers.add_child(v)


func _refresh_checks() -> void:
	for c in _warn_box.get_children():
		_warn_box.remove_child(c)
		c.queue_free()
	for ch in _design["checks"]:
		var lv := str(ch["level"])
		var l := Label.new()
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.text = ("✓ " if lv == "ok" else ("✗ " if lv == "error" else ("⚠ " if lv == "warn" else "• "))) + str(ch["text"])
		var col := UITheme.C_OK if lv == "ok" else (UITheme.C_ERROR if lv == "error" else (UITheme.C_WARN if lv == "warn" else UITheme.C_TEXT_S))
		l.add_theme_color_override("font_color", col)
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		_warn_box.add_child(l)


func _refresh_bom() -> void:
	for c in _bom_box.get_children():
		_bom_box.remove_child(c)
		c.queue_free()
	var t := PeltonLabDesign.bom_total(_design)
	_bom_lbl.text = "About $%.0f and %s, built from stock parts." % [float(t["cost"]), PeltonLabSpec.fmt_kg(float(t["kg"]))]
	for r in _design["bom"]:
		var l := Label.new()
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.text = "%d × %s — %s" % [int(r["qty"]), str(r["item"]), str(r["spec"])]
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT)
		_bom_box.add_child(l)


# ---------------------------------------------------------------------------
# Studio
# ---------------------------------------------------------------------------

func _show_view() -> void:
	var t := _tabs.current_tab
	_vp_container.visible = t == 0
	_wheel_canvas.visible = t == 1
	_perf_canvas.visible = t == 2
	_studio_bar.visible = t == 0
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if (t == 0 and _active) else SubViewport.UPDATE_DISABLED


func _rebuild_studio() -> void:
	if _holder == null or _design.is_empty():
		return
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	_builder = PeltonLabBuilder.build_from_design(_design, "Pelton", {"housing_view": _housing_view}) as PeltonLabBuilder
	_holder.add_child(_builder)


func _apply_studio_view() -> void:
	if _builder == null:
		return
	_builder.set_housing_view(_housing_view)
	_builder.set_show_jets(_show_jets)
	# The wheel at its real speed, slowed past ~60 rpm on screen so it reads
	# as turning instead of aliasing (the close-up's rule).
	var rpm := float(_design["perf"]["rpm"])
	var shown := 60.0 * (1.0 - exp(-rpm / 60.0)) if rpm > 0.0 else 0.0
	_builder.set_spin_rpm(shown if _spinning else 0.0)


func _frame_camera() -> void:
	var a: AABB = _design.get("aabb", AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE))
	_target = a.get_center()
	_dist = clampf(a.size.length() * 1.25, 0.4, 20.0)
	_update_camera()


func _update_camera() -> void:
	if _camera == null:
		return
	var cp := Vector3(_dist * cos(_pitch) * sin(_yaw), _dist * sin(_pitch), _dist * cos(_pitch) * cos(_yaw))
	# The window is the housing's −Z wall: look at the front from −Z.
	cp.z = -cp.z
	_camera.look_at_from_position(_target + cp, _target, Vector3.UP)


func _on_studio_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(0.2, _dist * 0.9)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(30.0, _dist * 1.1)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_orbiting = true
				_moved = false
				_press_pos = mb.position
			else:
				_orbiting = false
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _orbiting:
			if mm.position.distance_to(_press_pos) > 4.0:
				_moved = true
			if _moved:
				_yaw -= mm.relative.x * 0.01
				_pitch = clampf(_pitch - mm.relative.y * 0.01, -0.4, 1.5)
				_update_camera()
		else:
			_hover_frame += 1
			if _hover_frame % 4 == 0:
				var hit := pick_at(mm.position)
				_hover_lbl.text = str(hit.get("label", ""))


func pick_at(pos: Vector2) -> Dictionary:
	if _camera == null or _builder == null:
		return {}
	var vp_size := Vector2(_viewport.size)
	var cs := _vp_container.size
	var p := pos * (vp_size / cs) if cs.x > 0.0 and cs.y > 0.0 else pos
	return PeltonLabBuilder.pick(_builder, _camera.project_ray_origin(p), _camera.project_ray_normal(p))


# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

func _refresh_design_list() -> void:
	_design_list.clear()
	_design_entries.clear()
	for b in PeltonLabPresets.builtins():
		_design_list.add_item(str(b["label"]))
		_design_list.set_item_tooltip(_design_list.item_count - 1, str(b["blurb"]))
		_design_entries.append(b["spec"])
	for e in _library:
		_design_list.add_item("★ " + str((e as Dictionary).get("name", "Saved wheel")))
		_design_entries.append((e as Dictionary)["spec"])


func _on_design_activated(idx: int) -> void:
	if idx < 0 or idx >= _design_entries.size():
		return
	var keep_site: Dictionary = (_spec["site"] as Dictionary).duplicate()
	set_spec(_design_entries[idx])
	if not _turbine_id.is_empty():
		_spec["site"] = keep_site
		_rebuild_now()
	_frame_camera()


func _on_save_design() -> void:
	var name := str(_spec["name"])
	var kept: Array = []
	for e in _library:
		if str((e as Dictionary).get("name", "")) != name:
			kept.append(e)
	kept.append({"name": name, "spec": PeltonLabSpec.to_json_safe(_spec)})
	_library = kept
	if PeltonLabPresets.save_library(_library):
		_status("Saved “%s” to your library." % name)
	_refresh_design_list()


func _on_forget_design() -> void:
	var sel := _design_list.get_selected_items()
	if sel.is_empty():
		return
	var i := int(sel[0]) - PeltonLabPresets.builtins().size()
	if i < 0 or i >= _library.size():
		_status("Built-in wheels stay.")
		return
	_library.remove_at(i)
	PeltonLabPresets.save_library(_library)
	_refresh_design_list()


# ---------------------------------------------------------------------------
# Apply, place, export
# ---------------------------------------------------------------------------

## Write the wheel onto the bound turbine. Returns what happened.
func apply() -> String:
	if _turbine_id.is_empty() or _graph_view == null or not is_instance_valid(_graph_view):
		_status("Open the designer from the Hydro Lab to apply it to a turbine.")
		return ""
	if not _graph_view.has_method("apply_pelton_design"):
		return ""
	var msg := str(_graph_view.call("apply_pelton_design", _turbine_id, PeltonLabSpec.to_json_safe(_spec)))
	_status(msg)
	return msg


func _on_place() -> void:
	var gv := _graph_view
	if gv == null or not is_instance_valid(gv):
		var main := _main_node()
		gv = main.find_child("SystemGraphView", true, false) if main != null else null
	if gv != null and gv.has_method("place_designed_pelton"):
		if bool(gv.call("place_designed_pelton", PeltonLabSpec.to_json_safe(_spec))):
			close()
			return
	_status("Placing needs a world with the systems graph.")


func export_dir() -> String:
	return ProjectSettings.globalize_path(EXPORT_ROOT.path_join(DomeLabCam.safe_name(str(_spec["name"]))))


func _on_export() -> void:
	var r := PeltonLabCam.write_all(_design, export_dir())
	if bool(r["ok"]):
		_status("Wrote %s to %s" % [UiText.count((r["files"] as Array).size(), "file"), export_dir()])
	else:
		_status("Export failed: %s" % str(r["error"]))


func _on_open_folder() -> void:
	if not DirAccess.dir_exists_absolute(export_dir()):
		_on_export()
	OS.shell_open(export_dir())


func _on_copy_summary() -> void:
	DisplayServer.clipboard_set(PeltonLabCam.summary_text(_design))
	_status("Summary copied.")


func _status(text: String) -> void:
	if _status_lbl != null:
		_status_lbl.text = text


func _main_node() -> Node:
	var tree := get_tree()
	return tree.current_scene if tree != null else null


func _prop_record(prop_id: String) -> Dictionary:
	var main := _main_node()
	if main != null:
		return PlacedPropService.get_prop_record(main, prop_id)
	return {}


# ---------------------------------------------------------------------------
# Accessors (harness, tour)
# ---------------------------------------------------------------------------

func design() -> Dictionary:
	return _design


func spec() -> Dictionary:
	return _spec


func builder() -> PeltonLabBuilder:
	return _builder


func set_tab(i: int) -> void:
	_tabs.current_tab = i
	_show_view()


func sweeps() -> Dictionary:
	return {"diameter": _sweep_d, "cups": _sweep_z}


func control_for(group: String, key: String) -> Control:
	for b in _bindings:
		if str(b["group"]) == group and str(b["key"]) == key:
			return b["ctl"]
	return null


# ---------------------------------------------------------------------------
# The wheel, face on
# ---------------------------------------------------------------------------

class WheelCanvas extends Control:
	var owner_modal: Control = null

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
		if owner_modal == null:
			return
		var d: Dictionary = owner_modal.call("design")
		if d.is_empty():
			return
		var rn: Dictionary = d["runner"]
		var ro: Dictionary = d["rotor"]
		var s: Dictionary = d["spec"]
		var c := Vector2(size.x * 0.34, size.y * 0.5)
		var r_tip := float(rn["tip_r_mm"])
		var k := minf(size.x * 0.6, size.y) * 0.44 / r_tip
		var font := get_theme_default_font()
		# Discs, spacer, hub, bolt circle.
		draw_circle(c, float(ro["disc_r_mm"]) * k, Color(0.36, 0.38, 0.42))
		draw_circle(c, float(ro["spacer_r_mm"]) * k, Color(0.30, 0.32, 0.36))
		draw_circle(c, float(ro["flange_d_mm"]) * 0.5 * k, Color(0.45, 0.46, 0.5))
		draw_circle(c, float(ro["boss_d_mm"]) * 0.5 * k, Color(0.55, 0.56, 0.6))
		draw_circle(c, float(ro["shaft_d_mm"]) * 0.5 * k, Color(0.82, 0.83, 0.85))
		var n := int(s["hub"]["bolts"])
		var pr := float(ro["bolt_pcd_mm"]) * 0.5
		for i in n:
			var a := TAU * (float(i) + 0.5) / float(n)
			draw_circle(c + Vector2(cos(a), -sin(a)) * pr * k, float(ro["bolt_hole_mm"]) * 0.5 * k, Color(0.08, 0.08, 0.1))
		# Cups: each as its outline across the wheel's plane (tip, bowl, tab).
		var z := int(rn["cups"])
		var pitch := float(rn["pitch_r_mm"])
		var depth := (float(PeltonLabParts.CUP["depth_y1"]) - float(PeltonLabParts.CUP["depth_y0"])) * float(rn["k"])
		var tab1 := PeltonLabCup.tab_depth_mm(float(PeltonLabParts.CUP["root_z"])) * float(rn["k"])
		var cup_col := Color(0.78, 0.62, 0.32)
		for i in z:
			var th := TAU * float(i) / float(z)
			var rad := _screen_radial(th)
			var tan := Vector2(-rad.y, rad.x)
			var pts := PackedVector2Array([
				c + (rad * r_tip + tan * depth * 0.30) * k,
				c + (rad * float(rn["bowl_root_r_mm"]) + tan * depth * 0.5) * k,
				c + (rad * float(rn["root_r_mm"]) + tan * tab1 * 0.5) * k,
				c + (rad * float(rn["root_r_mm"]) - tan * tab1 * 0.5) * k,
				c + (rad * float(rn["bowl_root_r_mm"]) - tan * depth * 0.5) * k,
				c + (rad * r_tip - tan * depth * 0.30) * k,
			])
			draw_colored_polygon(pts, Color(cup_col, 0.85))
			draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0.2, 0.15, 0.08), 1.0, true)
			for br in rn["bolt_radii_mm"]:
				draw_circle(c + rad * float(br) * k, maxf(1.5, float(PeltonLabParts.bolt(str(s["runner"]["cup_bolt"]))["hole"]) * 0.5 * k), Color(0.1, 0.1, 0.12))
		# Circles: tip, pitch (dashed), root, disc.
		draw_arc(c, r_tip * k, 0, TAU, 128, UITheme.C_TEXT_S, 1.0, true)
		_dashed_circle(c, pitch * k, UITheme.C_PRIMARY)
		draw_arc(c, float(rn["root_r_mm"]) * k, 0, TAU, 96, UITheme.C_TEXT_M, 1.0, true)
		# Jets.
		for j in d["jets"]:
			var th := deg_to_rad(float(j["deg"]))
			var hit := _screen_radial(th) * pitch
			var tdir := Vector2(cos(th), -sin(th))
			var a := c + (hit - tdir * pitch * 0.9) * k
			var b := c + hit * k
			draw_line(a, b, Color(0.55, 0.8, 1.0), maxf(2.0, float(j["d_mm"]) * k), true)
		# Dimensions down the right.
		var x0 := size.x * 0.68
		var y := 20.0
		var lines := [
			["Overall Ø", "%.0f mm" % (r_tip * 2.0)],
			["Pitch circle (PCD)", "%.0f mm" % (pitch * 2.0)],
			["Cup root circle", "%.0f mm" % (float(rn["root_r_mm"]) * 2.0)],
			["Cups", "%d × %.0f mm %s" % [z, float(rn["cup_w_mm"]), str(PeltonLabParts.cup_material(str(s["runner"]["cup_material"]))["label"])]],
			["Cup bolts", "%d per cup, %s, at Ø %s" % [int(s["runner"]["cup_bolts"]), str(s["runner"]["cup_bolt"]).to_upper(),
				" / ".join((rn["bolt_radii_mm"] as Array).map(func(r): return "%.1f" % (float(r) * 2.0)))]],
			["Side discs", "2 × Ø %.0f × %.1f mm" % [float(ro["disc_r_mm"]) * 2.0, float(ro["disc_t_mm"])]],
			["Spacer ring", "Ø %.0f × %.1f mm (the tab)" % [float(ro["spacer_r_mm"]) * 2.0, float(ro["gap_mm"])]],
			["Hub flange", "Ø %.0f, boss Ø %.0f × %.0f" % [float(ro["flange_d_mm"]), float(ro["boss_d_mm"]), float(ro["boss_len_mm"])]],
			["Bolt pattern", "%d × %s on Ø %.1f mm" % [n, str(s["hub"]["bolt"]).to_upper(), pr * 2.0]],
			["Shaft", "Ø %.0f mm%s" % [float(ro["shaft_d_mm"]), " keyed" if bool(s["hub"]["keyway"]) else ""]],
			["Jet ratio", "PCD / d = %.1f" % float(d["rules"]["m"])],
			["Max cups", "%d before the tabs touch" % int(d["rules"]["max_cups"])],
		]
		for ln in lines:
			draw_string(font, Vector2(x0, y), str(ln[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UITheme.C_TEXT_S)
			draw_string(font, Vector2(x0, y + 15), str(ln[1]), HORIZONTAL_ALIGNMENT_LEFT, size.x - x0 - 10, 13, UITheme.C_TEXT)
			y += 36.0
		draw_string(font, Vector2(12, size.y - 12), "Dashed: the pitch circle — the jet's centreline is tangent to it. Blue: the jets.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_TEXT_M)

	## Runner angle θ → screen, looking at the wheel from its drive end: θ = 0
	## at the top, a horizontal wheel's first jet (θ = 180°) under it. The
	## runner's radial (cos θ, 0, sin θ) is canonical (0, cos θ, −sin θ).
	func _screen_radial(th: float) -> Vector2:
		return Vector2(-sin(th), -cos(th))

	func _dashed_circle(c: Vector2, r: float, col: Color) -> void:
		var n := 72
		for i in n:
			if i % 2 == 0:
				draw_arc(c, r, TAU * float(i) / float(n), TAU * float(i + 1) / float(n), 4, col, 1.5, true)


# ---------------------------------------------------------------------------
# Performance sweeps
# ---------------------------------------------------------------------------

class PerfCanvas extends Control:
	var owner_modal: Control = null

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
		if owner_modal == null:
			return
		var sw: Dictionary = owner_modal.call("sweeps")
		var d: Dictionary = owner_modal.call("design")
		if d.is_empty():
			return
		var h := (size.y - 30.0) * 0.5
		_chart(Rect2(50, 24, size.x - 110, h - 40), sw["diameter"], float(d["spec"]["runner"]["overall_d_mm"]),
			"Power and speed against the wheel's overall Ø (mm), %d cups" % int(d["runner"]["cups"]), "mm")
		_chart(Rect2(50, 24 + h, size.x - 110, h - 40), sw["cups"], float(d["runner"]["cups"]),
			"Power and speed against the number of cups, Ø %.0f mm" % float(d["spec"]["runner"]["overall_d_mm"]), "")

	func _chart(r: Rect2, pts: Array, cur: float, title: String, unit: String) -> void:
		var font := get_theme_default_font()
		draw_string(font, r.position + Vector2(0, -8), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UITheme.C_TEXT)
		draw_rect(r, Color(1, 1, 1, 0.03))
		if pts.size() < 2:
			return
		var x0 := float(pts[0]["x"])
		var x1 := float(pts[pts.size() - 1]["x"])
		var pmax := 1.0
		var rmax := 1.0
		for p in pts:
			pmax = maxf(pmax, float(p["p"]))
			rmax = maxf(rmax, float(p["rpm"]))
		pmax *= 1.1
		rmax *= 1.1
		var px := func(x: float) -> float: return r.position.x + (x - x0) / maxf(x1 - x0, 1e-6) * r.size.x
		var py := func(v: float, vmax: float) -> float: return r.end.y - v / vmax * r.size.y
		for g in 5:
			var gy := r.position.y + r.size.y * float(g) / 4.0
			draw_line(Vector2(r.position.x, gy), Vector2(r.end.x, gy), Color(1, 1, 1, 0.06))
			draw_string(font, Vector2(r.position.x - 46, gy + 4), UiText.num(pmax * (1.0 - float(g) / 4.0), "W"),
				HORIZONTAL_ALIGNMENT_LEFT, 44, 10, UITheme.C_AMBER)
			draw_string(font, Vector2(r.end.x + 4, gy + 4), "%d" % int(rmax * (1.0 - float(g) / 4.0)),
				HORIZONTAL_ALIGNMENT_LEFT, 50, 10, UITheme.C_PRIMARY)
		var lp := PackedVector2Array()
		var lr := PackedVector2Array()
		for p in pts:
			lp.append(Vector2(px.call(float(p["x"])), py.call(float(p["p"]), pmax)))
			lr.append(Vector2(px.call(float(p["x"])), py.call(float(p["rpm"]), rmax)))
		draw_polyline(lr, UITheme.C_PRIMARY, 2.0, true)
		draw_polyline(lp, UITheme.C_AMBER, 2.5, true)
		for i in pts.size():
			if not bool(pts[i]["ok"]):
				draw_circle(lp[i], 3.5, UITheme.C_ERROR)
		var cx: float = px.call(cur)
		draw_line(Vector2(cx, r.position.y), Vector2(cx, r.end.y), Color(1, 1, 1, 0.5), 1.5)
		var step := maxi(1, pts.size() / 8)
		for i in range(0, pts.size(), step):
			var x := float(pts[i]["x"])
			draw_string(font, Vector2(px.call(x) - 14, r.end.y + 14), ("%.0f" % x) + unit,
				HORIZONTAL_ALIGNMENT_LEFT, 60, 10, UITheme.C_TEXT_M)
		draw_string(font, Vector2(r.position.x + 6, r.position.y + 14), "— electrical W", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_AMBER)
		draw_string(font, Vector2(r.position.x + 110, r.position.y + 14), "— wheel rpm", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_PRIMARY)
		draw_string(font, Vector2(r.position.x + 200, r.position.y + 14), "● won't build", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_ERROR)
