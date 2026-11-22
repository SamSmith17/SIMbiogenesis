extends Control

## The wind turbine designer. Pick a rotor — Ugrinsky, Savonius, Lenz2,
## Darrieus, helical, a propeller or a farm windmill — size it, choose what
## it is built from (bent and scored sheet, printed or carved blades), how
## it is mounted and geared and which generator it turns into what load, and
## see what it does: the power curve, where it starts and charges, the year's
## energy at the site, the rotor and generator speeds, and the parts to cut,
## score and print.
##
## Left:   built-in turbines (incl. the one cut from a single 18 × 24 in lawn
##         sign) and the player's library.
## Centre: the turbine in a 3D studio turning at the speed it would in the
##         chosen wind; the blade (a vertical rotor's cross-section, a
##         propeller's planform and twist); the curves (power + rpm against
##         wind, Cp against tip speed ratio with the operating points, the
##         site's wind spread); the sheets to cut and score; gearing and
##         generator matching (the ratio sweep and every generator ranked).
## Right:  every setting, the numbers at the design wind, the checks, the bill
##         of materials, the files and making a part on a placed machine.
## Footer: apply to the graph's turbine (opened from it), place in the world.

const MODAL_NAME := "windlab_designer"
const WANT := Vector2(1640, 980)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.15
const EXPORT_ROOT := "user://windlab_designs"
const DISPLAY_RPM := 150.0

var _active := false
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _turbine_id := ""
var _graph_view: Node = null
var _bound_prop_id := ""
var _undo: Array = []
var _redo: Array = []
var _coalesce_key := ""
var _coalesce_until := 0.0
var _rebuild_timer := -1.0
var _built_geom := ""
var _suppress := false
var _bindings: Array = []
var _library: Array = []
var _ranking: Array = []
var _ladder: Array = []
var _studio_wind := 6.0
var _spinning := true
var _sheet_index := 0
var _keep_glb := true

# UI
var _shell: DesignerShell = null
var _panel: PanelContainer
var _name_edit: LineEdit
var _subtitle: Label
var _undo_btn: Button
var _redo_btn: Button
var _design_list: DesignGallery
var _col: DesignerColumn
var _design_entries: Array = []
var _tabs: TabBar
var _view_stack: Control
var _vp_container: SubViewportContainer
var _viewport: SubViewport
var _studio: Node3D
var _holder: Node3D
var _camera: Camera3D
var _builder: WindLabBuilder = null
var _blade_canvas: Control
var _power_canvas: Control
var _sheet_canvas: Control
var _match_canvas: Control
var _studio_bar: HBoxContainer
var _wind_spin: SpinBox
var _studio_lbl: Label
var _hover_lbl: Label
var _boxes: Dictionary = {}
var _numbers: GridContainer
var _warn_box: VBoxContainer
var _bom_box: VBoxContainer
var _bom_lbl: Label
var _status_lbl: Label
var _bound_lbl: Label
var _apply_btn: Button
var _keep_chk: CheckBox
var _place_btn: Button
var _make_opt: OptionButton

# Studio camera
var _yaw := 0.6
var _pitch := 0.25
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
		spec = rec.get("windlab_spec", {}) as Dictionary
	_spec = WindLabSpec.resolve(spec if not spec.is_empty() else WindLabPresets.lawn_sign_spec())
	_undo.clear()
	_redo.clear()
	_ranking.clear()
	_ladder.clear()
	_library = WindLabPresets.load_library()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_shell.open()
	_refresh_design_list()
	_built_geom = ""
	_studio_wind = float(_spec["site"]["design_wind_ms"])
	_wind_spin.set_value_no_signal(_studio_wind)
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
	if _shell != null and _shell.is_open():
		_shell.close()


func is_open() -> bool:
	return _active


## A wind node on the graph → a spec: its saved design, else a design shaped
## like it (the shipped VAWT / small HAWT, or a generic node's size).
func _spec_from_turbine() -> Dictionary:
	var item := _turbine_item()
	if item.is_empty():
		return {}
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	var saved: Dictionary = sp.get("windlab_spec", {}) as Dictionary
	if not saved.is_empty():
		return saved
	var vawt := str(sp.get("kind", "hawt")) == "vawt"
	var s := WindLabPresets.by_id("darrieus_h" if vawt else "air30_class")
	s["name"] = "%s (designed)" % str(sp.get("name", "Turbine"))
	var d_mm := float(sp.get("rotor_diameter_m", 1.2)) * 1000.0
	s["rotor"]["d_mm"] = d_mm
	if vawt:
		s["rotor"]["h_mm"] = maxf(float(sp.get("rotor_height_m", 0.0)) * 1000.0, d_mm * 1.25)
	s["site"]["mean_wind_ms"] = float(sp.get("site_mean_wind_ms", 4.5))
	s["mount"]["mast_h_mm"] = maxf(float(sp.get("hub_height_m", 6.0)) * 1000.0 - (d_mm * 0.6 if vawt else 0.0), 500.0)
	return s


func _turbine_item() -> Dictionary:
	if _graph_view == null or not is_instance_valid(_graph_view) or _turbine_id.is_empty():
		return {}
	var m: Variant = _graph_view.get("model")
	if m == null:
		return {}
	return (m as GraphModel).get_item(_turbine_id)


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

func shell() -> DesignerShell:
	return _shell


func _build_ui() -> void:
	_shell = DesignerShell.create("Wind turbine designer", "wind", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true, "undo": true,
		"left_label": "Turbines", "left_w": 250.0, "right_w": 410.0,
		"icon_color": UITheme.C_PRIMARY})
	add_child(_shell)
	_panel = _shell.panel
	_name_edit = _shell.name_edit
	_name_edit.placeholder_text = "Design name"
	_name_edit.text_submitted.connect(func(_t): _on_name_changed())
	_name_edit.focus_exited.connect(_on_name_changed)
	_subtitle = _shell.subtitle
	_undo_btn = _shell.undo_btn
	_redo_btn = _shell.redo_btn
	_shell.undo_requested.connect(_undo_step)
	_shell.redo_requested.connect(_redo_step)
	_shell.closed.connect(close)
	_shell.left.add_child(_build_left())
	_shell.centre.add_child(_build_centre())
	_shell.right.add_child(_build_right())
	_build_footer()


func _build_left() -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	box.add_child(SectionHeader.make("Turbines", "layout-grid"))
	_design_list = DesignGallery.make("windlab")
	_design_list.set_thumbnailer(_thumb_for)
	_design_list.item_selected.connect(_on_design_activated)
	box.add_child(_design_list)
	var lib := HBoxContainer.new()
	for b in [["Save design", "Keep this turbine in your library (every world)", _on_save_design],
			["Forget", "Remove the selected saved turbine", _on_forget_design]]:
		var btn := Button.new()
		btn.text = str(b[0])
		btn.tooltip_text = str(b[1])
		UITheme.style_button(btn)
		btn.pressed.connect(b[2])
		lib.add_child(btn)
	box.add_child(lib)
	var how_sec := Collapsible.make("How it works", false).persist("windlab", "how")
	box.add_child(how_sec)
	_note(how_sec.body, "Power in the wind is ½·ρ·A·v³: twice the wind, eight times the power, so the site's wind and the hub's " +
		"height matter more than anything else here. A rotor turns a fraction Cp of it into shaft power at its best " +
		"tip speed ratio λ = ω·R / v — drag rotors (Savonius, Ugrinsky) near λ 0.5–1 with Cp 0.15–0.3, lift rotors " +
		"(Darrieus, propellers) near λ 3–7 with Cp 0.3–0.47; no rotor beats Betz's 16/27. The generator has to be " +
		"geared so it makes its voltage at the rotor's speed, and its cogging decides the wind it starts in.")
	return box


func _build_centre() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_tabs = TabBar.new()
	for t in ["Turbine", "Blade", "Power", "Cut & print", "Gearing & motors"]:
		_tabs.add_tab(t)
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
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp_container.add_child(_viewport)
	_build_studio_world()
	_blade_canvas = BladeCanvas.new()
	_power_canvas = PowerCanvas.new()
	_sheet_canvas = SheetCanvas.new()
	_match_canvas = MatchCanvas.new()
	for c in [_blade_canvas, _power_canvas, _sheet_canvas, _match_canvas]:
		var cc := c as Control
		cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cc.visible = false
		cc.set("owner_modal", self)
		_view_stack.add_child(cc)
	_sheet_canvas.gui_input.connect(_on_sheet_input)
	_studio_bar = HBoxContainer.new()
	_studio_bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var wl := Label.new()
	wl.text = "Wind"
	_studio_bar.add_child(wl)
	_wind_spin = SpinBox.new()
	_wind_spin.min_value = 0.0
	_wind_spin.max_value = 30.0
	_wind_spin.step = 0.5
	_wind_spin.suffix = " m/s"
	_wind_spin.value = 6.0
	_wind_spin.tooltip_text = "The wind the studio turns the rotor in (at the hub)"
	_wind_spin.value_changed.connect(func(v): _studio_wind = v; _apply_studio_view())
	_studio_bar.add_child(_wind_spin)
	var spin := CheckBox.new()
	spin.text = "Spin"
	spin.button_pressed = true
	spin.tooltip_text = "Turn at the solved speed for that wind (slowed on screen past ~150 rpm)"
	spin.toggled.connect(func(v): _spinning = v; _apply_studio_view())
	_studio_bar.add_child(spin)
	_studio_bar.add_child(IconButton.make("scan", "Frame the turbine", func(): _yaw = 0.6; _pitch = 0.25; _frame_camera()))
	_studio_lbl = Label.new()
	_studio_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	_studio_lbl.add_theme_font_override("font", UITheme.font("regular", true))
	_studio_bar.add_child(_studio_lbl)
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
	e.background_mode = Environment.BG_SKY
	var skymat := ProceduralSkyMaterial.new()
	skymat.sky_top_color = Color(0.38, 0.55, 0.78)
	skymat.sky_horizon_color = Color(0.7, 0.76, 0.82)
	skymat.ground_horizon_color = Color(0.36, 0.38, 0.32)
	skymat.ground_bottom_color = Color(0.16, 0.17, 0.14)
	var sky := Sky.new()
	sky.sky_material = skymat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.9
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.ssao_enabled = true
	e.ssao_radius = 0.2
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	_studio.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-48, 35, 0)
	key.light_energy = 1.4
	key.light_color = Color(1.0, 0.96, 0.9)
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 30.0
	_studio.add_child(key)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.3, 0.36, 0.24)
	gmat.roughness = 0.95
	ground.material_override = gmat
	_studio.add_child(ground)
	_holder = Node3D.new()
	_holder.name = "Holder"
	_studio.add_child(_holder)
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.near = 0.01
	_camera.far = 200.0
	_studio.add_child(_camera)
	_update_camera()


func _build_right() -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_bound_lbl = Label.new()
	_bound_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bound_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_bound_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	box.add_child(_bound_lbl)
	for sec in [["rotor", "Rotor", true], ["build", "Made from", true], ["mount", "Mount and mast", false],
			["drive", "Drive", true], ["generator", "Generator and load", true], ["site", "Site wind", true],
			["colors", "Colours", false]]:
		var c := Collapsible.make(str(sec[1]), bool(sec[2]))
		box.add_child(c)
		_boxes[str(sec[0])] = c.body
	box.add_child(SectionHeader.make("At the design wind", "gauge"))
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
	box.add_child(SectionHeader.make("Files and making it", "download"))
	var ex := HFlowContainer.new()
	ex.add_theme_constant_override("h_separation", UITheme.SPACE_XS)
	for b in [["Export files", "Cut sheets (DXF/SVG with score lines), each part, printable STLs, the power curve, BOM, design JSON", _on_export],
			["Open folder", "Show the exported files", _on_open_folder],
			["Copy summary", "The design, its power curve and parts as text", _on_copy_summary]]:
		var btn := Button.new()
		btn.text = str(b[0])
		btn.tooltip_text = str(b[1])
		UITheme.style_button(btn)
		btn.pressed.connect(b[2])
		ex.add_child(btn)
	box.add_child(ex)
	var mk := HBoxContainer.new()
	_make_opt = OptionButton.new()
	_make_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_make_opt.tooltip_text = "A printable / routable part of this turbine"
	mk.add_child(_make_opt)
	var mkb := Button.new()
	mkb.text = "Make on a machine…"
	mkb.tooltip_text = "Open the print setup of the nearest placed printer, CNC router or designed gantry with this part loaded"
	UITheme.style_button(mkb)
	mkb.pressed.connect(func(): send_part_to_machine(str(_make_opt.get_item_metadata(_make_opt.selected)) if _make_opt.item_count > 0 else ""))
	mk.add_child(mkb)
	box.add_child(mk)
	_status_lbl = Label.new()
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_status_lbl)
	_build_settings_rows()
	_col = DesignerColumn.setup(box, "windlab", {"open": ["Rotor"], "fold": ["At the design wind", "Bill of materials", "Files and making it"]})
	return box


func _build_footer() -> void:
	_shell.set_hint("Drag to orbit · wheel to zoom · hover a part to name it")
	_keep_chk = CheckBox.new()
	_keep_chk.text = "Keep its 3D model"
	_keep_chk.tooltip_text = "A shipped turbine model (VAWT, small HAWT) keeps its look and just turns and generates as designed"
	_keep_chk.button_pressed = true
	_keep_chk.toggled.connect(func(v): _keep_glb = v)
	_shell.footer.add_child(_keep_chk)
	_apply_btn = _shell.add_button("Apply to turbine", DesignerShell.PRIMARY, func(): apply(),
		"Write this design onto the graph's turbine: its power curve, speeds and (unless kept) its 3D model")
	_place_btn = _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place,
		"Place a new turbine built to this design (its graph node comes with it)")
	_shell.add_button("Close", DesignerShell.SECONDARY, close)


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
		step: float, suffix: String, tip: String = "", is_int: bool = false, sub: String = "") -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.suffix = suffix
	s.value_changed.connect(func(v): _edit(group, key, int(v) if is_int else v, sub))
	_row(parent, label, s, tip)
	_bindings.append({"ctl": s, "group": group, "key": key, "sub": sub})
	return s


func _bind_check(parent: Container, text: String, group: String, key: String, tip: String = "", sub: String = "") -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.toggled.connect(func(v): _edit(group, key, v, sub))
	parent.add_child(c)
	_bindings.append({"ctl": c, "group": group, "key": key, "sub": sub})
	return c


func _bind_option(parent: Container, label: String, group: String, key: String, items: Array, tip: String = "",
		sub: String = "") -> OptionButton:
	var o := OptionButton.new()
	for i in items.size():
		o.add_item(str(items[i][1]), i)
		o.set_item_metadata(i, items[i][0])
	o.item_selected.connect(func(idx): _edit(group, key, o.get_item_metadata(idx), sub))
	_row(parent, label, o, tip)
	_bindings.append({"ctl": o, "group": group, "key": key, "sub": sub})
	return o


func _bind_color(parent: Container, label: String, key: String) -> void:
	var c := ColorPickerButton.new()
	c.custom_minimum_size = Vector2(60, 24)
	c.color_changed.connect(func(col): _edit("colors", key, [col.r, col.g, col.b, col.a]))
	_row(parent, label, c)
	_bindings.append({"ctl": c, "group": "colors", "key": key, "sub": ""})


func _table_items(table: Dictionary) -> Array:
	var out: Array = []
	for id in table:
		out.append([id, str(table[id]["label"])])
	return out


func _build_settings_rows() -> void:
	_bindings.clear()
	var r: VBoxContainer = _boxes["rotor"]
	var types: Array = []
	for id in WindLabParts.TYPE_ORDER:
		types.append([id, str(WindLabParts.TYPES[id]["label"])])
	_bind_option(r, "Rotor type", "", "type", types)
	_bind_spin(r, "Diameter (tip to tip)", "rotor", "d_mm", 60, 20000, 1, " mm", "The rotor's swept diameter")
	_bind_spin(r, "Height", "rotor", "h_mm", 60, 20000, 1, " mm", "A vertical rotor's height: swept area = D × H")
	_bind_spin(r, "Blades", "rotor", "blades", 1, 24, 1, "", "", true)
	_bind_spin(r, "Semicircle S / D", "rotor", "s_ratio", 0.15, 0.6, 0.01, "",
		"Ugrinsky: the semicircle's diameter as a fraction of the rotor's (0.35 is the published optimum)")
	_bind_spin(r, "Tail arc L / R", "rotor", "l_ratio", 0.5, 1.6, 0.01, "",
		"Ugrinsky: the tail arc's radius over the rotor's (1.0 = steady Cp over λ 0.5–0.7, 1.3 = the highest peak)")
	_bind_spin(r, "Tail sweep", "rotor", "sweep_deg", 10, 150, 1, "°", "How far the tail arc runs round")
	_bind_spin(r, "Overlap e / d", "rotor", "overlap", 0, 0.5, 0.01, "", "Savonius: buckets overlap through the middle (best ~0.15)")
	_bind_spin(r, "Stages", "rotor", "stages", 1, 2, 1, "", "Two stages stacked a quarter turn apart: smoother torque, starts at any angle", true)
	_bind_spin(r, "Twist", "rotor", "twist_deg", 0, 180, 1, "°", "Helical Savonius: the blades twist over the height")
	_bind_spin(r, "Wing chord / D", "rotor", "chord_frac", 0.1, 0.5, 0.01, "", "Lenz2: 0.30 is the design")
	_bind_spin(r, "Wing depth / chord", "rotor", "camber_frac", 0.02, 0.4, 0.01, "")
	_bind_spin(r, "Wing set angle", "rotor", "set_deg", -30, 45, 1, "°", "Lenz2: 15° is the design")
	_bind_spin(r, "Blade chord", "rotor", "chord_mm", 10, 3000, 1, " mm", "Darrieus: solidity N·c/D near 0.28 is best")
	_bind_option(r, "Airfoil", "rotor", "airfoil", _table_items(WindLabParts.AIRFOILS))
	_bind_spin(r, "Helix wrap", "rotor", "helix_deg", 0, 180, 1, "°", "Helical: how far each blade wraps round the shaft")
	_bind_spin(r, "Arms per blade", "rotor", "arms", 1, 4, 1, "", "", true)
	_bind_spin(r, "Design tip speed ratio", "rotor", "tsr", 1, 12, 0.1, "", "Propeller: the blades are shaped for this λ (5–7 for small turbines)")
	_bind_spin(r, "Hub radius / R", "rotor", "hub_frac", 0.04, 0.4, 0.01, "")
	_bind_spin(r, "Blade pitch", "rotor", "pitch_deg", -20, 30, 0.5, "°", "Extra pitch on the designed twist: more starts easier, runs slower")
	_bind_option(r, "Blades made by", "rotor", "construction", [["printed", "Printing (STL)"], ["carved", "Carving / CNC routing (STL)"], ["pvc_pipe", "Cutting from PVC pipe (template)"]])
	_bind_spin(r, "Pipe Ø", "rotor", "pipe_d_mm", 40, 1000, 1, " mm")
	_bind_check(r, "Tail vane", "rotor", "tail", "A propeller faces the wind on its tail")
	_bind_check(r, "Start assist (pushed / motored up)", "rotor", "start_assist", "A Darrieus barely starts by itself; assume it is pushed up to speed")
	_bind_option(r, "Hub", "rotor", "style", [["mid_discs", "Mid discs (blades slot through)"], ["end_plates", "End plates"], ["spokes", "Arms / spokes"]],
		"End plates stop air spilling off a drag rotor's blade ends (about +25 %)", "hub")
	_bind_spin(r, "Mid discs", "rotor", "count", 1, 6, 1, "", "", true, "hub")
	_bind_spin(r, "Disc spacing", "rotor", "spacing_mm", 0, 5000, 1, " mm", "", false, "hub")
	_bind_spin(r, "Plate Ø / rotor Ø", "rotor", "overhang", 1.0, 1.4, 0.01, "", "", false, "hub")
	var b: VBoxContainer = _boxes["build"]
	_bind_option(b, "Sheet", "build", "sheet", _table_items(WindLabParts.SHEETS), "Blades, discs, end plates, arms")
	_bind_option(b, "Sheet size", "build", "sheet_size", _table_items(WindLabParts.SHEET_SIZES), "What the parts are nested on")
	_bind_spin(b, "Score accuracy", "build", "score_tol_mm", 0.2, 20, 0.1, " mm", "How far a scored facet may sit off the true curve: tighter = more score lines")
	_bind_check(b, "Tabs into slotted end plates", "build", "tabs")
	_bind_spin(b, "Slot clearance", "build", "slot_clear_mm", 0, 5, 0.1, " mm")
	_bind_spin(b, "Kerf between parts", "build", "kerf_mm", 0, 20, 0.5, " mm")
	_bind_spin(b, "Sheet margin", "build", "margin_mm", 0, 50, 0.5, " mm")
	_bind_option(b, "Printed / carved in", "build", "solid", _table_items(WindLabParts.SOLIDS))
	_bind_spin(b, "Longest printed piece", "build", "print_max_mm", 50, 2000, 1, " mm", "Your printer's bed: longer parts are printed in pieces")
	var m: VBoxContainer = _boxes["mount"]
	var mounts: Array = []
	for id in WindLabParts.MOUNTS:
		mounts.append([id, str(WindLabParts.MOUNTS[id]["label"])])
	_bind_option(m, "Mount", "mount", "style", mounts, "The lawn-sign build clamps its hub discs to a stepper's face and fixes the shaft to the mast")
	_bind_option(m, "Mast", "mount", "mast", _table_items(WindLabParts.MASTS))
	_bind_spin(m, "Mast height", "mount", "mast_h_mm", 100, 40000, 10, " mm", "Higher = more wind (the log profile): the biggest lever after size")
	_bind_spin(m, "Rotor shaft Ø", "mount", "shaft_d_mm", 5, 60, 1, " mm")
	_bind_check(m, "Guy wires", "mount", "guyed")
	var dv: VBoxContainer = _boxes["drive"]
	_bind_option(dv, "Drive", "drive", "type", _table_items(WindLabParts.DRIVES), "Needs the rotor on its own shaft (Mount: own shaft and bearings)")
	_bind_spin(dv, "Rotor pulley / gear teeth", "drive", "driver_teeth", 8, 400, 1, "", "", true)
	_bind_spin(dv, "Generator pulley / gear teeth", "drive", "driven_teeth", 8, 400, 1, "", "", true)
	_bind_spin(dv, "Planetary ratio", "drive", "planetary_ratio", 1, 100, 0.5, " : 1")
	var mb := Button.new()
	mb.text = "Match the gearing (most energy a year)"
	mb.tooltip_text = "Search ratios 0.5–40 for this generator and load at the site's wind; picks the tooth counts"
	UITheme.style_button(mb)
	mb.pressed.connect(match_gearing)
	dv.add_child(mb)
	var g: VBoxContainer = _boxes["generator"]
	_bind_option(g, "Generator", "generator", "id", _table_items(WindLabParts.GENERATORS))
	_bind_spin(g, "Generators on the shaft", "generator", "count", 1, 2, 1, "", "", true)
	_bind_option(g, "Load", "load", "type", _table_items(WindLabParts.LOADS))
	_bind_spin(g, "Battery", "load", "battery_v", 1, 400, 0.1, " V")
	_bind_spin(g, "Controller's lowest input", "load", "mppt_min_v", 0.5, 400, 0.5, " V")
	_bind_spin(g, "Controller efficiency", "load", "mppt_eff", 0.5, 1.0, 0.01, "")
	_bind_spin(g, "Resistor", "load", "resistor_ohm", 0.05, 10000, 0.05, " Ω")
	_bind_option(g, "Rectifier", "load", "diode", _table_items(WindLabParts.DIODES))
	var rk := Button.new()
	rk.text = "Rank every generator"
	rk.tooltip_text = "Each generator at its best ratio, by the energy it makes a year here (see Gearing & motors)"
	UITheme.style_button(rk)
	rk.pressed.connect(func(): _status("Ranking generators…"); call_deferred("rank_generators"))
	g.add_child(rk)
	_note(g, "Ratings are typical for each class; check your own part's data sheet.")
	var st: VBoxContainer = _boxes["site"]
	_bind_spin(st, "Mean wind at 10 m", "site", "mean_wind_ms", 0.5, 20, 0.1, " m/s", "The site's annual mean (a Rayleigh spread round it)")
	_bind_spin(st, "Design wind", "site", "design_wind_ms", 1, 30, 0.5, " m/s", "The wind the numbers on the right are quoted at")
	_bind_spin(st, "Ground roughness z0", "site", "roughness_m", 0.0002, 2.0, 0.001, " m", "0.0002 water, 0.03 open grass, 0.1 farmland, 0.5–1 town or forest")
	_bind_spin(st, "Altitude", "site", "altitude_m", 0, 6000, 10, " m")
	_bind_spin(st, "Storm (parked)", "site", "survival_ms", 10, 80, 1, " m/s", "The storm the mast must stand")
	_bind_spin(st, "Cut-out (0 = auto)", "site", "cut_out_ms", 0, 60, 0.5, " m/s", "Braked above this; auto = the generator's top speed or rating")
	var wb := Button.new()
	wb.text = "Use this world's wind"
	wb.tooltip_text = "Take the mean wind from the world's weather data (a year at 10 m)"
	UITheme.style_button(wb)
	wb.pressed.connect(use_world_wind)
	st.add_child(wb)
	var c: VBoxContainer = _boxes["colors"]
	for ck in [["Blades", "blade"], ["Hub / discs", "hub"], ["Mast and frame", "frame"], ["Generator", "generator"]]:
		_bind_color(c, str(ck[0]), str(ck[1]))


func _get_value(b: Dictionary) -> Variant:
	var grp := str(b["group"])
	if grp.is_empty():
		return _spec.get(str(b["key"]))
	var g: Dictionary = _spec[grp]
	var sub := str(b.get("sub", ""))
	if not sub.is_empty():
		return (g[sub] as Dictionary).get(str(b["key"]))
	return g.get(str(b["key"]))


## Which rows matter for this design (the rest are hidden).
func _row_shown(key: String, group: String, sub: String) -> bool:
	var t := str(_spec["type"])
	var vawt := WindLabParts.is_vawt(t)
	var sheet_rotor := t in ["ugrinsky", "savonius", "lenz2"]
	var foil := t in ["darrieus_h", "helical"]
	var hub_style := str(_spec["rotor"]["hub"]["style"])
	var dt := str(_spec["drive"]["type"])
	var lt := str(_spec["load"]["type"])
	var bearings := str(_spec["mount"]["style"]) == "bearings"
	match key:
		"h_mm":
			return vawt
		"s_ratio", "l_ratio", "sweep_deg":
			return t == "ugrinsky"
		"overlap", "twist_deg":
			return t == "savonius"
		"stages":
			return t == "savonius"
		"chord_frac", "camber_frac", "set_deg":
			return t == "lenz2"
		"chord_mm", "arms":
			return foil
		"airfoil":
			return foil or (t == "hawt" and str(_spec["rotor"]["construction"]) != "pvc_pipe")
		"helix_deg":
			return t == "helical"
		"tsr", "pitch_deg", "construction":
			return t == "hawt"
		"hub_frac", "tail":
			return not vawt
		"pipe_d_mm":
			return t == "hawt" and str(_spec["rotor"]["construction"]) == "pvc_pipe"
		"start_assist":
			return foil
		"style":
			return sheet_rotor if sub == "hub" else true
		"count", "spacing_mm":
			return sheet_rotor and hub_style == "mid_discs"
		"overhang":
			return sheet_rotor and hub_style != "spokes"
		"score_tol_mm":
			return sheet_rotor
		"tabs", "slot_clear_mm":
			return sheet_rotor and hub_style != "spokes"
		"solid", "print_max_mm":
			return foil or (t == "hawt" and str(_spec["rotor"]["construction"]) != "pvc_pipe")
		"shaft_d_mm":
			return bearings
		"type":
			return bearings if group == "drive" else true
		"driver_teeth", "driven_teeth":
			return bearings and dt in ["gt2", "htd5", "spur"]
		"planetary_ratio":
			return bearings and dt == "planetary"
		"battery_v":
			return lt != "resistor"
		"mppt_min_v", "mppt_eff":
			return lt == "mppt"
		"resistor_ohm":
			return lt == "resistor"
	return true


func _sync_settings() -> void:
	_suppress = true
	for b in _bindings:
		var v: Variant = _get_value(b)
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
				if str(m) == str(v):
					o.select(i)
					break
		elif ctl is ColorPickerButton:
			(ctl as ColorPickerButton).color = v if v is Color else Color.WHITE
	_suppress = false
	for b in _bindings:
		var ctl2: Control = b["ctl"]
		var shown := _row_shown(str(b["key"]), str(b["group"]), str(b.get("sub", "")))
		var row := ctl2.get_parent() as Control
		if ctl2 is CheckBox:
			ctl2.visible = shown
		elif row is HBoxContainer:
			row.visible = shown


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


func _edit(group: String, key: String, value: Variant, sub: String = "") -> void:
	if _suppress:
		return
	_push_undo(group + "." + sub + "." + key)
	if group.is_empty():
		_spec[key] = value
	else:
		var g: Dictionary = _spec.get(group, {})
		if sub.is_empty():
			g[key] = value
		else:
			var gs: Dictionary = g.get(sub, {})
			gs[key] = value
			g[sub] = gs
		_spec[group] = g
	_ranking.clear()
	_ladder.clear()
	_rebuild_timer = REBUILD_DELAY


## Apply a whole spec (harness, presets) — one undo step.
func set_spec(spec: Dictionary) -> void:
	_push_undo()
	_spec = WindLabSpec.resolve(spec)
	_ranking.clear()
	_ladder.clear()
	_rebuild_now()


func _on_name_changed() -> void:
	var t := _name_edit.text.strip_edges()
	if t.is_empty() or t == str(_spec.get("name", "")):
		return
	_edit("", "name", t)


# ---------------------------------------------------------------------------
# Rebuild
# ---------------------------------------------------------------------------

func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = WindLabSpec.resolve(_spec)
	_design = WindLabDesign.solve(_spec)
	_sync_settings()
	var gk := WindLabSpec.geometry_key(_spec)
	if gk != _built_geom:
		_built_geom = gk
		_rebuild_studio()
	_apply_studio_view()
	_refresh_numbers()
	_refresh_checks()
	_refresh_bom()
	_refresh_make()
	_refresh_header()
	_sheet_index = clampi(_sheet_index, 0, maxi((_design["nest"]["sheets"] as Array).size() - 1, 0))
	for c in [_blade_canvas, _power_canvas, _sheet_canvas, _match_canvas]:
		(c as Control).queue_redraw()
	_show_view()
	_update_undo_buttons()


func _refresh_header() -> void:
	_refresh_tiles()
	if not _name_edit.has_focus():
		_name_edit.text = str(_spec["name"])
	var dp: Dictionary = _design["design"]
	_subtitle.text = "%s · %s at %.0f m/s · %s a year" % [WindLabSpec.describe(_spec), UiText.num(float(dp["p_elec"]), "W"),
		float(_spec["site"]["design_wind_ms"]), _fmt_kwh(float(_design["aep_kwh"]))]
	var item := _turbine_item()
	_apply_btn.visible = not item.is_empty()
	var mid := str((item.get("specs", {}) as Dictionary).get("model_id", "")) if not item.is_empty() else ""
	_keep_chk.visible = not item.is_empty() and not mid.is_empty() and mid != WindLabBuilder.MODEL_ID
	_bound_lbl.visible = not item.is_empty()
	if not item.is_empty():
		_bound_lbl.text = "Designing %s on the graph — Apply writes this design's power curve onto it." % \
			str((item.get("specs", {}) as Dictionary).get("name", "the turbine"))


static func _fmt_kwh(e: float) -> String:
	if e < 10.0:
		return "%.2f kWh" % e
	return "%d kWh" % int(round(e))


func _refresh_numbers() -> void:
	for c in _numbers.get_children():
		_numbers.remove_child(c)
		c.queue_free()
	var p: Dictionary = _design["design"]
	var cp: Dictionary = _design["cp"]
	var gen: Dictionary = _design["gen"]
	var start := float(_design["start_ms"])
	var ci := float(_design["cut_in_ms"])
	var rows := [
		["Swept area", "%.3f m² (%s)" % [float(_design["area_m2"]), "D × H" if bool(_design["vawt"]) else "π R²"]],
		["Power in the wind", UiText.num(float(p["p_wind"]), "W")],
		["Rotor", "Cp %.2f at λ %.2f (best %.2f at λ %.2f)" % [float(p["cp"]), float(p["lam"]), float(cp["cp_max"]), float(cp["lam_opt"])]],
		["Rotor speed", "%d rpm, %.2f N·m" % [int(round(float(p["rpm"]))), float(p["torque_nm"])]],
		["Drive", "%s, %.2f : 1" % [str(WindLabParts.DRIVES[str(_spec["drive"]["type"])]["label"]), float(_design["ratio"])]],
		["Generator", "%d rpm, %.1f V, %.2f A" % [int(round(float(p["gen_rpm"]))), float(p["v_dc"]), float(p["i_dc"])]],
		["Shaft power", UiText.num(float(p["p_aero"]), "W")],
		["Into the %s" % str(_spec["load"]["type"]), "%s%s" % [UiText.num(float(p["p_elec"]), "W"), " (pushed up to speed)" if bool(p["assisted"]) else ""]],
		["Starts turning", "%.1f m/s" % start if is_finite(start) else "never by itself"],
		["Charges from", "%.1f m/s" % ci if is_finite(ci) else "never"],
		["Peak", "%s at %.1f m/s (cut-out %.1f)" % [UiText.num(float(_design["peak_w"]), "W"), float(_design["peak_v"]), float(_design["cut_out_ms"])]],
		["Hub", "%.2f m up: mean wind %.2f m/s" % [float(_design["hub_h_m"]), float(_design["v_mean_hub"])]],
		["A year", "%s (%.1f W average)" % [_fmt_kwh(float(_design["aep_kwh"])), float(_design["mean_w"])]],
		["Weight", "%s (rotor %s)" % [WindLabSpec.fmt_kg(float(_design["mass"]["total"])), WindLabSpec.fmt_kg(float(_design["mass"]["rotor"]))]],
	]
	for row in rows:
		var k := Label.new()
		k.text = str(row[0])
		k.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_numbers.add_child(k)
		var v := Label.new()
		v.text = str(row[1])
		v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.custom_minimum_size = Vector2(220, 0)
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
	var t := WindLabDesign.bom_total(_design)
	_bom_lbl.text = "About $%.0f and %s." % [float(t["cost"]), WindLabSpec.fmt_kg(float(t["kg"]))]
	for r in _design["bom"]:
		var l := Label.new()
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.text = "%d × %s — %s" % [int(r["qty"]), str(r["item"]), str(r["spec"])]
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT)
		_bom_box.add_child(l)


func _refresh_make() -> void:
	_make_opt.clear()
	for p in _design["prints"]:
		_make_opt.add_item("%s (%d ×)" % [str(p["label"]), int(p["qty"])])
		_make_opt.set_item_metadata(_make_opt.item_count - 1, str(p["id"]))
	if not (_design["blades"] as Array).is_empty():
		_make_opt.add_item("Blade, printed solid (small rotors)")
		_make_opt.set_item_metadata(_make_opt.item_count - 1, "blade_print")


# ---------------------------------------------------------------------------
# Studio
# ---------------------------------------------------------------------------

func _show_view() -> void:
	var t := _tabs.current_tab
	_vp_container.visible = t == 0
	_blade_canvas.visible = t == 1
	_power_canvas.visible = t == 2
	_sheet_canvas.visible = t == 3
	_match_canvas.visible = t == 4
	_studio_bar.visible = t == 0
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if (t == 0 and _active) else SubViewport.UPDATE_DISABLED
	if t == 4 and _ladder.is_empty() and _active:
		call_deferred("_compute_ladder")


func _rebuild_studio() -> void:
	if _holder == null or _design.is_empty():
		return
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	_builder = WindLabBuilder.build_from_design(_design, "WindTurbine") as WindLabBuilder
	_holder.add_child(_builder)


func _apply_studio_view() -> void:
	if _builder == null or _design.is_empty():
		return
	var op := WindLabDesign.op_point(_design, _studio_wind)
	var rpm := float(op["rpm"])
	var shown := DISPLAY_RPM * (1.0 - exp(-rpm / DISPLAY_RPM)) if rpm > 0.0 else 0.0
	_builder.set_spin_rpm(shown if _spinning else 0.0)
	_studio_lbl.text = "%d rpm · λ %.2f · %s" % [int(round(rpm)), float(op["lam"]), UiText.num(float(op["p_elec"]), "W")] \
		if bool(op["running"]) else "standing still"


func _frame_camera() -> void:
	if _design.is_empty():
		return
	var lay: Dictionary = _design["layout"]
	var R := maxf(float(_design["R_m"]), float(_design["tip_r_mm"]) * 0.001)
	var top := float(lay["rotor_top"])
	var bottom := float(lay["rotor_bottom"])
	_target = Vector3(0.0, (top + bottom) * 0.5, 0.0)
	_dist = clampf(maxf(R * 2.0, top - bottom) * 2.2 + 0.2, 0.5, 80.0)
	_update_camera()


func _update_camera() -> void:
	if _camera == null:
		return
	var cp := Vector3(_dist * cos(_pitch) * sin(_yaw), _dist * sin(_pitch), -_dist * cos(_pitch) * cos(_yaw))
	_camera.look_at_from_position(_target + cp, _target, Vector3.UP)


func _on_studio_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(0.2, _dist * 0.9)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(150.0, _dist * 1.1)
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
				_pitch = clampf(_pitch - mm.relative.y * 0.01, -0.3, 1.5)
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
	return WindLabBuilder.pick(_builder, _camera.project_ray_origin(p), _camera.project_ray_normal(p))


func _on_sheet_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).pressed and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var n := (_design["nest"]["sheets"] as Array).size()
		if n > 1:
			_sheet_index = (_sheet_index + 1) % n
			_sheet_canvas.queue_redraw()


# ---------------------------------------------------------------------------
# Matching: ratio and generator
# ---------------------------------------------------------------------------

func _compute_ladder() -> void:
	if not _active or _design.is_empty():
		return
	if str(_spec["mount"]["style"]) != "bearings":
		_ladder = [{"ratio": 1.0, "aep_kwh": float(_design["aep_kwh"])}]
	else:
		var b := WindLabDesign.best_ratio(_spec, str(_spec["generator"]["id"]))
		_ladder = b.get("ladder", [])
		_ladder.append({"ratio": float(b["ratio"]), "aep_kwh": float(b["aep_kwh"]), "best": true})
	_match_canvas.queue_redraw()


## Pick the drive for the ratio that makes the most energy a year with this
## generator (the rotor must be on its own shaft to be geared).
func match_gearing() -> Dictionary:
	if str(_spec["mount"]["style"]) != "bearings":
		_status("A rotor clamped to the generator turns it 1 : 1 — set Mount to its own shaft and bearings to gear it.")
		return {}
	var b := WindLabDesign.best_ratio(_spec, str(_spec["generator"]["id"]))
	var dr := WindLabDesign.drive_for_ratio(_spec, float(b["ratio"]))
	_push_undo()
	for k in ["type", "driver_teeth", "driven_teeth", "planetary_ratio"]:
		if dr.has(k):
			_spec["drive"][k] = dr[k]
	_ladder = b.get("ladder", [])
	_rebuild_now()
	_status("Best ratio %.2f : 1 (%s) → %s a year; set to %s %.2f : 1." % [float(b["ratio"]), str(_spec["generator"]["id"]),
		_fmt_kwh(float(b["aep_kwh"])), str(WindLabParts.DRIVES[str(_spec["drive"]["type"])]["label"]), float(_design["ratio"])])
	return b


func rank_generators() -> Array:
	if _design.is_empty():
		return []
	_ranking = WindLabDesign.rank_generators(_spec)
	_status("Ranked %s at the site's wind." % UiText.count(_ranking.size(), "generator"))
	_tabs.current_tab = 4
	_show_view()
	_match_canvas.queue_redraw()
	return _ranking


## Use a ranked generator (and its best gearing).
func use_generator(gen_id: String, ratio: float) -> void:
	_push_undo()
	_spec["generator"]["id"] = gen_id
	if str(_spec["mount"]["style"]) == "bearings":
		var dr := WindLabDesign.drive_for_ratio(_spec, ratio)
		for k in ["type", "driver_teeth", "driven_teeth", "planetary_ratio"]:
			if dr.has(k):
				_spec["drive"][k] = dr[k]
	_rebuild_now()


## The world's mean wind: a year of the weather data at 10 m (sampled daily
## at four hours).
func use_world_wind() -> void:
	var ws := get_node_or_null("/root/WeatherService")
	var main := _main_node()
	if ws == null or main == null or not ws.has_method("wind_speed_ms"):
		_status("No weather data here.")
		return
	var lat: Variant = main.get("latitude")
	var lon: Variant = main.get("longitude")
	if lat == null or not bool(ws.call("covers", float(lat), float(lon))):
		_status("The weather data does not cover this world yet.")
		return
	var sum := 0.0
	var n := 0
	for mo in range(1, 13):
		for dday in [1, 8, 15, 22]:
			for h in [3.0, 9.0, 15.0, 21.0]:
				var v := float(ws.call("wind_speed_ms", mo, dday, h))
				if is_finite(v):
					sum += v
					n += 1
	if n == 0:
		return
	_edit("site", "mean_wind_ms", snappedf(sum / float(n), 0.1))
	_rebuild_now()
	_status("Mean wind at 10 m from this world's weather: %.1f m/s." % (sum / float(n)))


# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

## One design's picture for the gallery: its key and how to build it.
func _thumb_for(i: int) -> Dictionary:
	if i < 0 or i >= _design_entries.size():
		return {}
	var spec: Dictionary = WindLabSpec.resolve((_design_entries[i] as Dictionary).duplicate(true))
	return {"key": JSON.stringify(spec), "build": func() -> Node3D:
		return WindLabBuilder.build_node(spec, "Thumb")}


func _refresh_design_list() -> void:
	_design_list.clear()
	_design_entries.clear()
	for b in WindLabPresets.builtins():
		_design_list.add_item(str(b["label"]))
		_design_list.set_item_tooltip(_design_list.item_count - 1, str(b["blurb"]))
		_design_list.set_item_subtitle(_design_list.item_count - 1, str(b["blurb"]))
		_design_entries.append(b["spec"])
	for e in _library:
		_design_list.add_item("★ " + str((e as Dictionary).get("name", "Saved turbine")))
		_design_entries.append((e as Dictionary)["spec"])


func _on_design_activated(idx: int) -> void:
	if idx < 0 or idx >= _design_entries.size():
		return
	set_spec(_design_entries[idx])
	_studio_wind = float(_spec["site"]["design_wind_ms"])
	_wind_spin.set_value_no_signal(_studio_wind)
	_apply_studio_view()
	_frame_camera()


func _on_save_design() -> void:
	var name := str(_spec["name"])
	var kept: Array = []
	for e in _library:
		if str((e as Dictionary).get("name", "")) != name:
			kept.append(e)
	kept.append({"name": name, "spec": WindLabSpec.to_json_safe(_spec)})
	_library = kept
	if WindLabPresets.save_library(_library):
		_status("Saved “%s” to your library." % name)
	_refresh_design_list()


func _on_forget_design() -> void:
	var sel := _design_list.get_selected_items()
	if sel.is_empty():
		return
	var i := int(sel[0]) - WindLabPresets.builtins().size()
	if i < 0 or i >= _library.size():
		_status("Built-in turbines stay.")
		return
	_library.remove_at(i)
	WindLabPresets.save_library(_library)
	_refresh_design_list()


# ---------------------------------------------------------------------------
# Apply, place, export, make
# ---------------------------------------------------------------------------

func apply() -> String:
	if _turbine_id.is_empty() or _graph_view == null or not is_instance_valid(_graph_view):
		_status("Open the designer from a wind turbine on the graph to apply it.")
		return ""
	if not _graph_view.has_method("apply_wind_design"):
		return ""
	var msg := str(_graph_view.call("apply_wind_design", _turbine_id, WindLabSpec.to_json_safe(_spec),
		not (_keep_chk.visible and _keep_glb)))
	_status(msg)
	return msg


func _graph() -> Node:
	if _graph_view != null and is_instance_valid(_graph_view):
		return _graph_view
	var main := _main_node()
	return main.find_child("SystemGraphView", true, false) if main != null else null


func _on_place() -> void:
	var gv := _graph()
	if gv != null and gv.has_method("place_designed_wind"):
		if bool(gv.call("place_designed_wind", WindLabSpec.to_json_safe(_spec))):
			close()
			return
	_status("Placing needs a world with the systems graph.")


func export_dir() -> String:
	return ProjectSettings.globalize_path(EXPORT_ROOT.path_join(DomeLabCam.safe_name(str(_spec["name"]))))


func _on_export() -> Dictionary:
	var r := WindLabCam.write_all(_design, export_dir())
	if bool(r["ok"]):
		_status("Wrote %s to %s" % [UiText.count((r["files"] as Array).size(), "file"), export_dir()])
	else:
		_status("Export failed: %s" % str(r["error"]))
	return r


func _on_open_folder() -> void:
	if not DirAccess.dir_exists_absolute(export_dir()):
		_on_export()
	OS.shell_open(export_dir())


func _on_copy_summary() -> void:
	DisplayServer.clipboard_set(WindLabCam.summary_text(_design))
	_status("Summary copied.")


## Write the part's STL and open the print setup of the nearest placed
## printer / CNC router / designed gantry with it loaded. Returns the path
## written ("" when there is nothing to make it on).
func send_part_to_machine(id: String) -> String:
	if id.is_empty():
		_status("This design has no printed or routed parts — its parts are cut from sheet (Export files).")
		return ""
	var path := WindLabCam.write_stl(_design, id, export_dir())
	if path.is_empty():
		_status("Could not write the part.")
		return ""
	var gv := _graph()
	var main := _main_node()
	var prop_id := _nearest_machine(main)
	if gv == null or prop_id.is_empty():
		_status("Wrote %s — place a printer, a CNC router or a designed gantry to make it in the world." % path.get_file())
		return path
	close()
	if bool(gv.call("open_print_setup_for_prop", prop_id)):
		var ps: Variant = gv.get("_print_setup_modal")
		if ps != null and (ps as Object).has_method("load_stl"):
			(ps as Object).call("load_stl", path)
	return path


func _nearest_machine(main: Node) -> String:
	if main == null:
		return ""
	var player := ServiceLocator.player() as Node3D
	var from := player.global_position if player != null else Vector3.ZERO
	var best := ""
	var best_d := INF
	var terrain := main.get_node_or_null("Terrain")
	var root := (terrain if terrain != null else main).get_node_or_null("PlacedProps")
	if root == null:
		return ""
	for n in root.get_children():
		if not (n is PlacedProp):
			continue
		var p := n as PlacedProp
		if p.get_node_or_null("CncMachineRuntime") == null and p.get_node_or_null("GantryRuntime") == null:
			continue
		var dd := p.global_position.distance_to(from)
		if dd < best_d:
			best_d = dd
			best = str(p.prop_id)
	return best


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


func builder() -> WindLabBuilder:
	return _builder


func ranking() -> Array:
	return _ranking


func ladder() -> Array:
	return _ladder


func sheet_index() -> int:
	return _sheet_index


func studio_wind() -> float:
	return _studio_wind


func set_tab(i: int) -> void:
	_tabs.current_tab = i
	_show_view()


func control_for(group: String, key: String) -> Control:
	for b in _bindings:
		if str(b["group"]) == group and str(b["key"]) == key:
			return b["ctl"]
	return null


# ---------------------------------------------------------------------------
# Blade: a vertical rotor from above, a propeller's blade
# ---------------------------------------------------------------------------

class BladeCanvas extends Control:
	var owner_modal: Control = null

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
		if owner_modal == null:
			return
		var d: Dictionary = owner_modal.call("design")
		if d.is_empty():
			return
		var font := get_theme_default_font()
		var s: Dictionary = d["spec"]
		var t := str(s["type"])
		if t in ["ugrinsky", "savonius", "lenz2"]:
			_draw_section(d, font)
		elif t in ["darrieus_h", "helical"]:
			_draw_foil_vawt(d, font)
		else:
			_draw_hawt(d, font)

	func _draw_section(d: Dictionary, font: Font) -> void:
		var s: Dictionary = d["spec"]
		var c := Vector2(size.x * 0.36, size.y * 0.5)
		var R := float(d["tip_r_mm"])
		var k := minf(size.x * 0.6, size.y) * 0.4 / maxf(R, 1.0)
		var hub_r := R * float(s["rotor"]["hub"]["overhang"])
		draw_circle(c, hub_r * k, Color(0.35, 0.37, 0.4, 0.35))
		draw_arc(c, float(s["rotor"]["d_mm"]) * 0.5 * k, 0, TAU, 96, UITheme.C_TEXT_S, 1.0, true)
		var cols := [UITheme.C_AMBER, UITheme.C_PRIMARY, UITheme.C_GREEN, UITheme.C_ERROR]
		var i := 0
		for b in d["blades"]:
			var pts: PackedVector2Array = b["pts"]
			var sp := PackedVector2Array()
			for p in pts:
				sp.append(c + Vector2(p.x, -p.y) * k)
			draw_polyline(sp, cols[i % cols.size()], maxf(float(d["sheet_t_mm"]) * k, 2.5), true)
			i += 1
		draw_circle(c, 3.0, UITheme.C_TEXT)
		# Ugrinsky construction: the semicircle's and the tail's circles.
		var g: Dictionary = d["ugr"]
		if not g.is_empty():
			var cs: Vector2 = g["c_semi"]
			var ct: Vector2 = g["c_tail"]
			_dashed(c + Vector2(cs.x, -cs.y) * k, float(g["S"]) * 0.5 * k, Color(1, 1, 1, 0.35))
			_dashed(c + Vector2(ct.x, -ct.y) * k, float(g["L"]) * k, Color(1, 1, 1, 0.2))
			draw_circle(c + Vector2(cs.x, -cs.y) * k, 2.5, UITheme.C_AMBER)
			draw_circle(c + Vector2(ct.x, -ct.y) * k, 2.5, UITheme.C_AMBER)
		# The wind and the turn.
		draw_string(font, Vector2(12, 22), "Wind →", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UITheme.C_TEXT_S)
		var dirs := "counter-clockwise" if float(d["spin_dir"]) > 0.0 else "clockwise"
		var x0 := size.x * 0.7
		var y := 24.0
		var lines: Array = [["Seen from above", "turns %s" % dirs],
			["Rotor Ø (tips)", "%.0f mm (%.2f in)" % [R * 2.0, R * 2.0 / WindLabParts.IN]],
			["Height", "%.0f mm" % float(s["rotor"]["h_mm"])]]
		if not g.is_empty():
			lines.append_array([["Semicircle S", "%.1f mm (S/D %.2f)" % [float(g["S"]), float(s["rotor"]["s_ratio"])]],
				["Tail arc L", "%.1f mm (L/R %.2f), %.0f°" % [float(g["L"]), float(s["rotor"]["l_ratio"]), float(s["rotor"]["sweep_deg"])]],
				["Inner gap e", "%.1f mm from the shaft" % float(g["e"])]])
		var b0: Dictionary = (d["blades"] as Array)[0]
		lines.append(["Blade unrolled", "%.0f × %.0f mm" % [WindLabAero.poly_len(b0["pts"]), float(s["rotor"]["h_mm"]) / float(s["rotor"]["stages"])]])
		var blade_part := {}
		for p in d["parts"]:
			if str(p["id"]) == "blade":
				blade_part = p
		if not blade_part.is_empty():
			lines.append(["Score lines", "%d per blade" % (blade_part["fold"] as Array).size()])
		lines.append(["Hub", "%s Ø %.0f mm" % [str(s["rotor"]["hub"]["style"]).replace("_", " "), hub_r * 2.0]])
		for ln in lines:
			draw_string(font, Vector2(x0, y), str(ln[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UITheme.C_TEXT_S)
			draw_string(font, Vector2(x0, y + 15), str(ln[1]), HORIZONTAL_ALIGNMENT_LEFT, size.x - x0 - 10, 13, UITheme.C_TEXT)
			y += 36.0
		draw_string(font, Vector2(12, size.y - 12), "Dashed: the semicircle's and the tail arc's construction circles; thin ring: the rotor diameter; shaded: the hub disc.",
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 24, 11, UITheme.C_TEXT_M)

	func _draw_foil_vawt(d: Dictionary, font: Font) -> void:
		var s: Dictionary = d["spec"]
		var c := Vector2(size.x * 0.36, size.y * 0.5)
		var R := float(s["rotor"]["d_mm"]) * 0.5
		var k := minf(size.x * 0.6, size.y) * 0.4 / maxf(R, 1.0)
		draw_arc(c, R * k, 0, TAU, 96, UITheme.C_TEXT_S, 1.0, true)
		var af := WindLabAero.airfoil_points(WindLabParts.airfoil(str(s["rotor"]["airfoil"])), 16)
		var nb := int(s["rotor"]["blades"])
		var ch := float(s["rotor"]["chord_mm"])
		for b in nb:
			var psi := TAU * float(b) / float(nb)
			var er := Vector2(cos(psi), sin(psi))
			var et := Vector2(-sin(psi), cos(psi))
			var pts := PackedVector2Array()
			for p in af:
				var q := er * R + et * (0.25 - p.x) * ch + er * p.y * ch
				pts.append(c + Vector2(q.x, -q.y) * k)
			draw_colored_polygon(pts, Color(UITheme.C_PRIMARY, 0.8))
			draw_line(c, c + Vector2(er.x, -er.y) * R * k, Color(1, 1, 1, 0.25), 2.0)
		var cp: Dictionary = d["cp"]
		var y := 24.0
		var x0 := size.x * 0.7
		for ln in [["Solidity N·c/D", "%.2f" % float(cp.get("sigma", 0.0))], ["Best λ", "%.2f" % float(cp["lam_opt"])],
				["Blade Re", "%.0f k" % (float(cp.get("re", 0.0)) / 1000.0)], ["Chord", "%.0f mm" % ch]]:
			draw_string(font, Vector2(x0, y), str(ln[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UITheme.C_TEXT_S)
			draw_string(font, Vector2(x0, y + 15), str(ln[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UITheme.C_TEXT)
			y += 36.0

	func _draw_hawt(d: Dictionary, font: Font) -> void:
		var st: Array = d["stations"]
		if st.is_empty():
			return
		var s: Dictionary = d["spec"]
		var R := float(d["R_m"]) * 1000.0
		var r0 := Rect2(40, 30, size.x - 80, size.y * 0.42)
		draw_string(font, r0.position + Vector2(0, -8), "Blade planform (chord along the span), Schmitz optimum at λ %.1f, %d blades" % [float(s["rotor"]["tsr"]), int(s["rotor"]["blades"])],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UITheme.C_TEXT)
		var cmax := 1.0
		for e in st:
			cmax = maxf(cmax, float(e["c_m"]) * 1000.0)
		var kx := r0.size.x / R
		var ky := minf(r0.size.y / cmax, kx)
		var top := PackedVector2Array()
		var bot := PackedVector2Array()
		for e in st:
			var x := r0.position.x + float(e["r_m"]) * 1000.0 * kx
			var c := float(e["c_m"]) * 1000.0
			top.append(Vector2(x, r0.position.y + r0.size.y * 0.5 - c * 0.25 * ky))
			bot.append(Vector2(x, r0.position.y + r0.size.y * 0.5 + c * 0.75 * ky))
		var poly := top.duplicate()
		for i in range(bot.size() - 1, -1, -1):
			poly.append(bot[i])
		draw_colored_polygon(poly, Color(UITheme.C_PRIMARY, 0.35))
		draw_polyline(poly + PackedVector2Array([poly[0]]), UITheme.C_PRIMARY, 1.5, true)
		# Twist below.
		var r1 := Rect2(40, size.y * 0.55, size.x - 80, size.y * 0.32)
		draw_string(font, r1.position + Vector2(0, -8), "Twist (blade angle to the plane of rotation) and inflow angle", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UITheme.C_TEXT)
		draw_rect(r1, Color(1, 1, 1, 0.03))
		var amax := 1.0
		for e in st:
			amax = maxf(amax, maxf(float(e["twist_deg"]), float(e["phi_deg"])))
		var lt := PackedVector2Array()
		var lp := PackedVector2Array()
		for e in st:
			var x2 := r1.position.x + float(e["r_m"]) * 1000.0 * kx
			lt.append(Vector2(x2, r1.end.y - float(e["twist_deg"]) / amax * r1.size.y))
			lp.append(Vector2(x2, r1.end.y - float(e["phi_deg"]) / amax * r1.size.y))
		draw_polyline(lp, UITheme.C_TEXT_M, 1.5, true)
		draw_polyline(lt, UITheme.C_AMBER, 2.5, true)
		for i in st.size():
			if i % 3 == 0 or i == st.size() - 1:
				var e2: Dictionary = st[i]
				draw_string(font, Vector2(lt[i].x - 16, r1.end.y + 14), "%.0f" % (float(e2["r_m"]) * 1000.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UITheme.C_TEXT_M)
				draw_string(font, lt[i] + Vector2(-10, -6), "%.0f°" % float(e2["twist_deg"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UITheme.C_AMBER)
				draw_string(font, top[i] + Vector2(-10, -4), "%.0f" % (float(e2["c_m"]) * 1000.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UITheme.C_PRIMARY)
		draw_string(font, Vector2(40, size.y - 12), "Radius in mm along the bottom; chord (mm, blue) and twist (°, amber; grey = inflow angle φ = ⅔·atan(R/λr)). %s" % str(WindLabAero.hawt_airfoil(s)["label"]),
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 60, 11, UITheme.C_TEXT_M)

	func _dashed(c: Vector2, r: float, col: Color) -> void:
		var n := 72
		for i in n:
			if i % 2 == 0:
				draw_arc(c, r, TAU * float(i) / float(n), TAU * float(i + 1) / float(n), 4, col, 1.2, true)


# ---------------------------------------------------------------------------
# Power: the power curve, Cp(λ), the wind's spread
# ---------------------------------------------------------------------------

class PowerCanvas extends Control:
	var owner_modal: Control = null

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
		if owner_modal == null:
			return
		var d: Dictionary = owner_modal.call("design")
		if d.is_empty():
			return
		var font := get_theme_default_font()
		var h := (size.y - 40.0) * 0.5
		_curve_chart(d, Rect2(56, 28, size.x - 120, h - 36), font)
		_cp_chart(d, Rect2(56, 28 + h + 6, size.x * 0.5 - 80, h - 36), font)
		_gen_chart(d, Rect2(size.x * 0.5 + 40, 28 + h + 6, size.x * 0.5 - 104, h - 36), font)

	func _curve_chart(d: Dictionary, r: Rect2, font: Font) -> void:
		draw_string(font, r.position + Vector2(0, -8), "Power (W, amber) and rotor rpm (blue) against hub wind; bars: how often it blows that hard here",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 12, UITheme.C_TEXT)
		draw_rect(r, Color(1, 1, 1, 0.03))
		var curve: Array = d["curve"]
		var vmax := 25.0
		var pmax := 1.0
		var rmax := 1.0
		for p in curve:
			if float(p["v"]) <= vmax:
				pmax = maxf(pmax, float(p["p_elec"]))
				rmax = maxf(rmax, float(p["rpm"]))
		pmax *= 1.12
		rmax *= 1.12
		var px := func(v: float) -> float: return r.position.x + v / vmax * r.size.x
		var vm := float(d["v_mean_hub"])
		var fmax := WindLabDesign.rayleigh(vm * 0.8, vm) * 1.2
		for i in 50:
			var v := 0.25 + 0.5 * float(i)
			var f := WindLabDesign.rayleigh(v, vm)
			var bh := f / maxf(fmax, 1e-6) * r.size.y * 0.35
			draw_rect(Rect2(px.call(v - 0.22), r.end.y - bh, 0.44 / vmax * r.size.x, bh), Color(1, 1, 1, 0.07))
		for g in 5:
			var gy := r.position.y + r.size.y * float(g) / 4.0
			draw_line(Vector2(r.position.x, gy), Vector2(r.end.x, gy), Color(1, 1, 1, 0.06))
			draw_string(font, Vector2(r.position.x - 52, gy + 4), UiText.num(pmax * (1.0 - float(g) / 4.0), "W"), HORIZONTAL_ALIGNMENT_LEFT, 50, 10, UITheme.C_AMBER)
			draw_string(font, Vector2(r.end.x + 4, gy + 4), "%d" % int(rmax * (1.0 - float(g) / 4.0)), HORIZONTAL_ALIGNMENT_LEFT, 56, 10, UITheme.C_PRIMARY)
		var lp := PackedVector2Array()
		var lr := PackedVector2Array()
		for p in curve:
			var v2 := float(p["v"])
			if v2 > vmax:
				break
			var pw := float(p["p_elec"]) if v2 <= float(d["cut_out_ms"]) + 1e-6 else 0.0
			lp.append(Vector2(px.call(v2), r.end.y - pw / pmax * r.size.y))
			lr.append(Vector2(px.call(v2), r.end.y - float(p["rpm"]) / rmax * r.size.y))
		if lr.size() > 1:
			draw_polyline(lr, UITheme.C_PRIMARY, 1.5, true)
			draw_polyline(lp, UITheme.C_AMBER, 2.5, true)
		var row := 0
		for mk in [["mean", vm, Color(1, 1, 1, 0.6)], ["start", float(d["start_ms"]), UITheme.C_TEXT_S],
				["cut-in", float(d["cut_in_ms"]), UITheme.C_GREEN], ["cut-out", float(d["cut_out_ms"]), UITheme.C_ERROR]]:
			var mv := float(mk[1])
			if is_finite(mv) and mv <= vmax:
				var x := float(px.call(mv))
				draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), mk[2], 1.0)
				# Stagger the labels down so neighbours (start / cut-in) never overprint.
				draw_string(font, Vector2(x + 3, r.position.y + 14 + 13 * row), "%s %.1f" % [str(mk[0]), mv], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, mk[2])
				row += 1
		for v3 in range(0, 26, 5):
			draw_string(font, Vector2(px.call(float(v3)) - 6, r.end.y + 14), "%d" % v3, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UITheme.C_TEXT_M)
		draw_string(font, Vector2(r.end.x - 60, r.end.y + 14), "m/s", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UITheme.C_TEXT_M)

	func _cp_chart(d: Dictionary, r: Rect2, font: Font) -> void:
		var cp: Dictionary = d["cp"]
		draw_string(font, r.position + Vector2(0, -8), "Cp against λ; dots: where it runs", HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 12, UITheme.C_TEXT)
		draw_rect(r, Color(1, 1, 1, 0.03))
		var lmax := float(cp["lam_run"]) * 1.05
		var cmax := maxf(float(cp["cp_max"]) * 1.25, 0.05)
		var pts := PackedVector2Array()
		for i in 81:
			var l := lmax * float(i) / 80.0
			pts.append(Vector2(r.position.x + l / lmax * r.size.x, r.end.y - WindLabAero.cp_at(cp, l) / cmax * r.size.y))
		draw_polyline(pts, UITheme.C_PRIMARY, 2.0, true)
		var by := r.end.y - WindLabAero.BETZ / cmax * r.size.y
		if by > r.position.y:
			draw_line(Vector2(r.position.x, by), Vector2(r.end.x, by), Color(1, 1, 1, 0.3), 1.0)
		for p in d["curve"]:
			if bool(p["running"]) and float(p["lam"]) <= lmax:
				var col := UITheme.C_AMBER.lerp(UITheme.C_ERROR, clampf(float(p["v"]) / 20.0, 0.0, 1.0))
				draw_circle(Vector2(r.position.x + float(p["lam"]) / lmax * r.size.x, r.end.y - float(p["cp"]) / cmax * r.size.y), 2.5, col)
		draw_string(font, Vector2(r.position.x + 4, r.position.y + 14), "Cp max %.3f at λ %.2f" % [float(cp["cp_max"]), float(cp["lam_opt"])], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_TEXT_S)
		draw_string(font, Vector2(r.position.x, r.end.y + 14), "0", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UITheme.C_TEXT_M)
		draw_string(font, Vector2(r.end.x - 30, r.end.y + 14), "λ %.1f" % lmax, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UITheme.C_TEXT_M)

	func _gen_chart(d: Dictionary, r: Rect2, font: Font) -> void:
		draw_string(font, r.position + Vector2(0, -8), "Generator rpm (blue), volts (green), amps (amber)", HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 12, UITheme.C_TEXT)
		draw_rect(r, Color(1, 1, 1, 0.03))
		var curve: Array = d["curve"]
		var vmax := 25.0
		var rm := 1.0
		var vv := 1.0
		var am := 0.1
		for p in curve:
			if float(p["v"]) <= vmax:
				rm = maxf(rm, float(p["gen_rpm"]))
				vv = maxf(vv, float(p["v_dc"]))
				am = maxf(am, float(p["i_dc"]))
		var lines := [["gen_rpm", rm, UITheme.C_PRIMARY], ["v_dc", vv, UITheme.C_GREEN], ["i_dc", am, UITheme.C_AMBER]]
		for ln in lines:
			var pts := PackedVector2Array()
			for p in curve:
				if float(p["v"]) > vmax:
					break
				pts.append(Vector2(r.position.x + float(p["v"]) / vmax * r.size.x, r.end.y - float(p[str(ln[0])]) / float(ln[1]) * 1.1 * r.size.y * 0.9))
			if pts.size() > 1:
				draw_polyline(pts, ln[2], 1.8, true)
		var gen: Dictionary = d["gen"]
		draw_string(font, Vector2(r.position.x + 4, r.position.y + 14), "top %d rpm · %.0f V · %.1f A · limit %d rpm" % [int(rm), vv, am, int(gen["max_rpm"])],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8, 11, UITheme.C_TEXT_S)
		if str(gen["kind"]) == "stepper":
			draw_string(font, Vector2(r.position.x + 4, r.position.y + 30), "a stepper's current levels off near %.1f A (its inductance)" % WindLabGen.current_ceiling(gen),
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8, 10, UITheme.C_TEXT_M)


# ---------------------------------------------------------------------------
# Cut & print: the nested sheets with their score lines
# ---------------------------------------------------------------------------

class SheetCanvas extends Control:
	var owner_modal: Control = null

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
		if owner_modal == null:
			return
		var d: Dictionary = owner_modal.call("design")
		if d.is_empty():
			return
		var font := get_theme_default_font()
		var sheets: Array = d["nest"]["sheets"]
		var idx := int(owner_modal.call("sheet_index"))
		var title := "No sheet parts"
		if not sheets.is_empty():
			var c := WindLabCam.sheet_content(d, idx)
			var w := float(c["w"])
			var h := float(c["h"])
			var area := Rect2(24, 40, size.x - 48, size.y - 120)
			var k := minf(area.size.x / w, area.size.y / h)
			var o := area.position + Vector2(0, h * k)
			var to := func(p: Vector2) -> Vector2: return o + Vector2(p.x, -p.y) * k
			var sheet_col := Color(0.92, 0.92, 0.9, 0.12)
			draw_rect(Rect2(area.position, Vector2(w * k, h * k)), sheet_col)
			draw_rect(Rect2(area.position, Vector2(w * k, h * k)), Color(1, 1, 1, 0.4), false, 1.0)
			for ring in c["outside"]:
				_ring(ring, to, Color(0.95, 0.3, 0.25), 1.5)
			for ring in c["inside"]:
				_ring(ring, to, Color(0.35, 0.6, 1.0), 1.2)
			for f in c["fold"]:
				_dash(to.call(f["a"]), to.call(f["b"]), Color(0.3, 0.85, 0.4))
			for lb in c["labels"]:
				draw_string(font, to.call(lb["p"]) + Vector2(-30, 0), str(lb["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, 0.55))
			title = "Sheet %d of %d — %s, %s%s" % [idx + 1, sheets.size(), str(d["nest"]["sheet_label"]),
				str(WindLabParts.sheet(str(d["spec"]["build"]["sheet"]))["label"]), " (click for the next)" if sheets.size() > 1 else ""]
		draw_string(font, Vector2(24, 24), title, HORIZONTAL_ALIGNMENT_LEFT, size.x - 48, 13, UITheme.C_TEXT)
		var y := size.y - 66.0
		draw_string(font, Vector2(24, y), "Red: cut out · blue: cut inside (slots, holes) · green dashed: SCORE one skin and bend toward it",
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 48, 11, UITheme.C_TEXT_S)
		var notes := ""
		for p in d["parts"]:
			if not str(p["note"]).is_empty():
				notes += "%s: %s  " % [str(p["label"]), str(p["note"])]
		draw_string(font, Vector2(24, y + 18), notes, HORIZONTAL_ALIGNMENT_LEFT, size.x - 48, 11, UITheme.C_TEXT_M)
		var pr := ""
		for p in d["prints"]:
			pr += "%d × %s (%.0f cm³%s)  " % [int(p["qty"]), str(p["label"]), absf(float(p["volume_cm3"])),
				", %d pieces" % int(p["pieces"]) if int(p["pieces"]) > 1 else ""]
		if not pr.is_empty():
			draw_string(font, Vector2(24, y + 36), "Printed / routed: " + pr, HORIZONTAL_ALIGNMENT_LEFT, size.x - 48, 11, UITheme.C_PRIMARY)

	func _ring(ring: Dictionary, to: Callable, col: Color, w: float) -> void:
		var pts := FlatpackProfile.tessellate(ring, 2.0)
		if pts.size() < 2:
			return
		var sp := PackedVector2Array()
		for p in pts:
			sp.append(to.call(p))
		sp.append(sp[0])
		draw_polyline(sp, col, w, true)

	func _dash(a: Vector2, b: Vector2, col: Color) -> void:
		var L := a.distance_to(b)
		var n := maxi(int(L / 6.0), 1)
		for i in n:
			if i % 2 == 0:
				draw_line(a.lerp(b, float(i) / float(n)), a.lerp(b, float(i + 1) / float(n)), col, 1.2)


# ---------------------------------------------------------------------------
# Gearing & motors: the ratio sweep and the generator ranking
# ---------------------------------------------------------------------------

class MatchCanvas extends Control:
	var owner_modal: Control = null
	var _rows: Array = []

	func _ready() -> void:
		gui_input.connect(_on_input)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), UITheme.C_BG)
		if owner_modal == null:
			return
		var d: Dictionary = owner_modal.call("design")
		if d.is_empty():
			return
		var font := get_theme_default_font()
		var ladder: Array = owner_modal.call("ladder")
		var r := Rect2(56, 34, size.x - 112, size.y * 0.36)
		draw_string(font, r.position + Vector2(0, -10), "Energy a year against the drive ratio with %s (log scale)" % str(d["gen"]["label"]),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 13, UITheme.C_TEXT)
		draw_rect(r, Color(1, 1, 1, 0.03))
		if ladder.size() > 1:
			var emax := 0.001
			for e in ladder:
				emax = maxf(emax, float(e["aep_kwh"]))
			var lx := func(g: float) -> float: return r.position.x + log(g / 0.5) / log(80.0) * r.size.x
			var pts := PackedVector2Array()
			var sorted := ladder.duplicate()
			sorted.sort_custom(func(a, b): return float(a["ratio"]) < float(b["ratio"]))
			for e in sorted:
				pts.append(Vector2(lx.call(float(e["ratio"])), r.end.y - float(e["aep_kwh"]) / emax * r.size.y * 0.92))
			draw_polyline(pts, UITheme.C_AMBER, 2.0, true)
			for e in sorted:
				if bool(e.get("best", false)):
					var bx: float = lx.call(float(e["ratio"]))
					draw_line(Vector2(bx, r.position.y), Vector2(bx, r.end.y), UITheme.C_GREEN, 1.5)
					draw_string(font, Vector2(bx + 4, r.position.y + 14), "best %.2f : 1 → %.1f kWh" % [float(e["ratio"]), float(e["aep_kwh"])],
						HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_GREEN)
			var cx: float = lx.call(float(d["ratio"]))
			draw_line(Vector2(cx, r.position.y), Vector2(cx, r.end.y), Color(1, 1, 1, 0.6), 1.5)
			draw_string(font, Vector2(cx + 4, r.end.y - 6), "now %.2f" % float(d["ratio"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UITheme.C_TEXT_S)
			for g in [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 40.0]:
				draw_string(font, Vector2(lx.call(g) - 8, r.end.y + 14), "%.1f" % g if g < 1.0 else "%d" % int(g), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UITheme.C_TEXT_M)
		else:
			draw_string(font, r.position + Vector2(10, 24), "The rotor turns its generator 1 : 1 with this mount — choose own shaft and bearings to gear it.",
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20, 12, UITheme.C_TEXT_S)
		# The ranking table.
		var rank: Array = owner_modal.call("ranking")
		var y := r.end.y + 46.0
		draw_string(font, Vector2(56, y - 12), "Every generator at its best ratio, by energy a year here (click a row to use it)" if not rank.is_empty() \
			else "Press “Rank every generator” (Generator and load) to compare them here.", HORIZONTAL_ALIGNMENT_LEFT, size.x - 112, 13, UITheme.C_TEXT)
		_rows.clear()
		var cols := [56.0, 360.0, 450.0, 560.0, 660.0, 760.0]
		var hdr := ["Generator", "Ratio", "A year", "At design", "Starts", "Charges"]
		for i in hdr.size():
			draw_string(font, Vector2(cols[i], y + 6), str(hdr[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UITheme.C_TEXT_S)
		y += 14.0
		var cur := str(d["spec"]["generator"]["id"])
		for e in rank:
			var rr := Rect2(50, y, size.x - 100, 20)
			if str(e["gen"]) == cur:
				draw_rect(rr, Color(UITheme.C_PRIMARY, 0.15))
			var ci := float(e["cut_in_ms"])
			var vals := [str(e["label"]), "%.2f" % float(e["ratio"]), "%.2f kWh" % float(e["aep_kwh"]), UiText.num(float(e["design_w"]), "W"),
				"%.1f m/s" % float(e["start_ms"]) if is_finite(float(e["start_ms"])) else "never", "%.1f m/s" % ci if is_finite(ci) else "never"]
			for i in vals.size():
				draw_string(font, Vector2(cols[i], y + 15), str(vals[i]), HORIZONTAL_ALIGNMENT_LEFT, (cols[i + 1] - cols[i] - 6) if i + 1 < cols.size() else -1, 12,
					UITheme.C_TEXT if float(e["aep_kwh"]) > 0.0 else UITheme.C_TEXT_M)
			_rows.append({"rect": rr, "gen": str(e["gen"]), "ratio": float(e["ratio"])})
			y += 21.0

	func _on_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			for row in _rows:
				if (row["rect"] as Rect2).has_point((ev as InputEventMouseButton).position):
					owner_modal.call("use_generator", str(row["gen"]), float(row["ratio"]))
					return


## The headline numbers and what each folded section holds.
func _refresh_tiles() -> void:
	if _col == null or _design.is_empty():
		return
	var dp: Dictionary = _design["design"]
	var start := float(_design["start_ms"])
	var wind := float(_spec["site"]["design_wind_ms"])
	_col.set_tiles([
		{"caption": "At %.0f m/s" % wind, "value": UiText.num(float(dp["p_elec"]), "W"), "tip": "Into the load at the design wind"},
		{"caption": "A year", "value": _fmt_kwh(float(_design["aep_kwh"])), "tip": "%.1f W on average at this site" % float(_design["mean_w"])},
		{"caption": "Rotor speed", "value": "%d rpm" % int(round(float(dp["rpm"]))), "tip": "At the design wind"},
		{"caption": "Starts at", "value": ("%.1f m/s" % start) if is_finite(start) else "Never",
			"level": "" if is_finite(start) else "error", "tip": "The wind that turns it from rest"},
		{"caption": "Swept area", "value": "%.2f m²" % float(_design["area_m2"]), "tip": "What the rotor catches"},
		{"caption": "Weight", "value": WindLabSpec.fmt_kg(float(_design["mass"]["total"])),
			"tip": "Rotor %s" % WindLabSpec.fmt_kg(float(_design["mass"]["rotor"]))}])
	_col.set_summary("Rotor", "%.2f m²" % float(_design["area_m2"]))
	_col.set_summary("Site wind", "%.1f m/s design" % wind)
	_col.set_summary("At the design wind", "%d rpm, %s" % [int(round(float(dp["rpm"]))), UiText.num(float(dp["p_elec"]), "W")])
