extends Control

## The CNC gantry designer: pick a pattern (bed-slinger, Cartesian XY,
## CoreXY, CoreXZ, H-bot, delta, router gantry) or an application, size the
## work volume, choose the extrusion, guides, drives, motors, board, tool
## and bed, read the engineering checks, jog the machine and watch what each
## motor does, play real G-code through the motion planner at true speed,
## send that job to the placed machine, read the bill of materials and
## export the firmware config and cut list.
##
## Left:   applications (a pattern + tool per job), the seven patterns with
##         their "why", built-in and saved designs.
## Centre: Machine (the 3D studio: drag orbits, wheel zooms, hover names a
##         part), Kinematics (jog X/Y/Z; the motor readouts, A = X + Y…),
##         Simulate (a sample or a file; play/pause/scrub/speed; the HUD;
##         the beads laid down), Config (printer.cfg / Configuration.h /
##         grbl $ settings, read-only).
## Right:  settings sections, checks, motors table, BOM, exports.
## Footer: place in the world, or apply to the placed one (and re-sync its
##         graph node).

const MODAL_NAME := "gantrylab_designer"
const WANT := Vector2(1600, 960)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.15
const EXPORT_ROOT := "user://gantrylab_designs"
const SPEEDS := [0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 25.0, 100.0]

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
var _library: Array = []
var _status_text := ""
var _hover_frame := 0

# Sim state
var _gcode_text := ""
var _gcode_name := ""
var _parse: Dictionary = {}
var _plan: Dictionary = {}
var _sim_t := 0.0
var _sim_playing := false
var _sim_speed := 1.0
var _jog := Vector3.ZERO

# UI
var _panel: PanelContainer
var _name_edit: LineEdit
var _subtitle: Label
var _undo_btn: Button
var _redo_btn: Button
var _app_box: VBoxContainer
var _kin_box: VBoxContainer
var _why_lbl: Label
var _design_list: ItemList
var _design_entries: Array = []
var _tabs: TabBar
var _view_stack: Control
var _vp_container: SubViewportContainer
var _viewport: SubViewport
var _studio: Node3D
var _holder: Node3D
var _camera: Camera3D
var _machine: GantryLabBuilder = null
var _hover_lbl: Label
var _kin_panel: Control
var _jog_sliders: Dictionary = {}
var _motor_box: VBoxContainer
var _kin_text: Label
var _sim_panel: Control
var _sample_opt: OptionButton
var _gcode_edit: TextEdit
var _play_btn: Button
var _speed_opt: OptionButton
var _scrub: HSlider
var _hud: Label
var _send_btn: Button
var _config_panel: Control
var _config_tabs: TabBar
var _config_text: RichTextLabel
var _size_box: VBoxContainer
var _frame_box: VBoxContainer
var _axis_box: VBoxContainer
var _elec_box: VBoxContainer
var _tool_box: VBoxContainer
var _delta_box: VBoxContainer
var _delta_sec: Collapsible
var _warn_box: VBoxContainer
var _motors_box: VBoxContainer
var _bom_lbl: Label
var _bom_box: VBoxContainer
var _export_status: Label
var _apply_btn: Button
var _place_btn: Button
var _file_dialog: FileDialog
var _gcode_dialog: FileDialog

var _yaw := 0.8
var _pitch := 0.4
var _dist := 2.0
var _target := Vector3.ZERO
var _orbiting := false
var _moved := false
var _press_pos := Vector2.ZERO


func bind_loader(loader: Node) -> void:
	_loader = loader


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process(false)


func open(spec: Dictionary = {}) -> void:
	if _active:
		return
	_bound_prop_id = ""
	_spec = GantryLabSpec.resolve(spec if not spec.is_empty() else GantryLabSpec.default_spec("bedslinger"))
	_activate()


func open_for_prop(prop_id: String) -> void:
	if _active or prop_id.is_empty():
		return
	var rec := _prop_record(prop_id)
	var spec: Dictionary = rec.get("gantry_spec", {}) as Dictionary
	_bound_prop_id = prop_id
	_spec = GantryLabSpec.resolve(spec if not spec.is_empty() else GantryLabSpec.default_spec("bedslinger"))
	_activate()


func is_open() -> bool:
	return _active


func _activate() -> void:
	_undo.clear()
	_redo.clear()
	_library = GantryLabPresets.load_library()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	UiFit.keep_fitted(_panel, WANT)
	_apply_btn.visible = not _bound_prop_id.is_empty()
	_send_btn.visible = not _bound_prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _bound_prop_id.is_empty() else "Place in world"
	_refresh_design_list()
	_built_key = ""
	_rebuild_now()
	_frame_camera()
	_load_sample_default()


func close() -> void:
	if not _active:
		return
	_active = false
	_sim_playing = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


func _process(delta: float) -> void:
	if _rebuild_timer >= 0.0:
		_rebuild_timer -= delta
		if _rebuild_timer < 0.0:
			_rebuild_now()
	if _sim_playing and not _plan.is_empty():
		_sim_t += delta * _sim_speed
		if _sim_t >= float(_plan["total_s"]):
			_sim_t = float(_plan["total_s"])
			_sim_playing = false
			_play_btn.text = "Play"
		_apply_sim_time()


func _input(e: InputEvent) -> void:
	if not _active or not (e is InputEventKey) or not e.is_pressed():
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	var k := e as InputEventKey
	if k.ctrl_pressed and k.keycode == KEY_Z and not k.shift_pressed:
		_undo_step()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and (k.keycode == KEY_Y or (k.keycode == KEY_Z and k.shift_pressed)):
		_redo_step()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_SPACE and _tabs.current_tab == 2:
		_on_play()
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
	_file_dialog.title = "Choose a folder for the design files"
	_file_dialog.dir_selected.connect(_on_export_dir_selected)
	add_child(_file_dialog)
	_gcode_dialog = FileDialog.new()
	_gcode_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_gcode_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_gcode_dialog.use_native_dialog = true
	_gcode_dialog.title = "Open a G-code file"
	_gcode_dialog.filters = PackedStringArray(["*.gcode, *.gco, *.g, *.nc, *.ngc, *.tap ; G-code"])
	_gcode_dialog.file_selected.connect(_on_gcode_file)
	add_child(_gcode_dialog)


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var icon := TextureRect.new()
	icon.texture = UiIcons.icon("cpu", 22)
	icon.modulate = UITheme.C_AMBER
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(icon)
	var title := Label.new()
	title.text = "CNC gantry designer"
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title.add_theme_color_override("font_color", UITheme.C_TEXT)
	row.add_child(title)
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(240, 0)
	_name_edit.placeholder_text = "Machine name"
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
	box.add_child(SectionHeader.make("What is it for", "target"))
	_app_box = VBoxContainer.new()
	_app_box.add_theme_constant_override("separation", 2)
	box.add_child(_app_box)
	for a in GantryLabSpec.APPLICATIONS:
		var b := Button.new()
		b.text = str(a["label"])
		b.tooltip_text = str(a["why"])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 26)
		UITheme.style_button(b)
		b.pressed.connect(_on_application.bind(str(a["id"])))
		_app_box.add_child(b)
	box.add_child(SectionHeader.make("Pattern", "box"))
	_kin_box = VBoxContainer.new()
	_kin_box.add_theme_constant_override("separation", 2)
	box.add_child(_kin_box)
	for kin in GantryLabSpec.KINEMATICS:
		var b := Button.new()
		b.text = str(GantryLabSpec.KINEMATICS_LABELS[kin])
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 28)
		b.set_meta("kin", kin)
		b.tooltip_text = str(GantryLabSpec.KINEMATICS_WHY[kin])
		b.pressed.connect(_on_kinematics.bind(kin))
		_kin_box.add_child(b)
	_why_lbl = Label.new()
	_why_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_why_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_why_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(_why_lbl)
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_design_list = ItemList.new()
	_design_list.custom_minimum_size = Vector2(0, 220)
	_design_list.auto_height = true
	_design_list.item_activated.connect(_on_design_activated)
	_design_list.item_selected.connect(_on_design_activated)
	box.add_child(_design_list)
	var lib := HBoxContainer.new()
	var save := Button.new()
	save.text = "Save design"
	save.tooltip_text = "Keep this machine in your library (every world)"
	UITheme.style_button(save)
	save.pressed.connect(_on_save_design)
	lib.add_child(save)
	var forget := Button.new()
	forget.text = "Forget"
	UITheme.style_button(forget)
	forget.pressed.connect(_on_forget_design)
	lib.add_child(forget)
	box.add_child(lib)
	return col[0]


func _build_centre() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_tabs = TabBar.new()
	_tabs.add_tab("Machine")
	_tabs.add_tab("Kinematics")
	_tabs.add_tab("Simulate")
	_tabs.add_tab("Config")
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
	# Overlay panels that share the studio: a strip under the view per tab.
	_kin_panel = _build_kin_panel()
	_kin_panel.visible = false
	_view_stack.add_child(_kin_panel)
	_sim_panel = _build_sim_panel()
	_sim_panel.visible = false
	_view_stack.add_child(_sim_panel)
	_config_panel = _build_config_panel()
	_config_panel.visible = false
	_view_stack.add_child(_config_panel)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var home := Button.new()
	home.text = "Home"
	home.tooltip_text = "Tool to the work origin"
	UITheme.style_button(home)
	home.pressed.connect(func(): _set_jog(Vector3.ZERO))
	bar.add_child(home)
	var centre := Button.new()
	centre.text = "Centre"
	UITheme.style_button(centre)
	centre.pressed.connect(func():
		var v: Dictionary = _spec["volume"]
		_set_jog(Vector3(0.0 if str(_spec["kinematics"]) == "delta" else float(v["x_mm"]) * 0.5, 0.0 if str(_spec["kinematics"]) == "delta" else float(v["y_mm"]) * 0.5, float(v["z_mm"]) * 0.5)))
	bar.add_child(centre)
	var frame := Button.new()
	frame.text = "Frame view"
	UITheme.style_button(frame)
	frame.pressed.connect(_frame_camera)
	bar.add_child(frame)
	_hover_lbl = Label.new()
	_hover_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hover_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hover_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hover_lbl.clip_text = true
	_hover_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(_hover_lbl)
	col.add_child(bar)
	return col


func _build_studio_world() -> void:
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.035, 0.043, 0.063)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.64)
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	_studio.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, 35, 0)
	key.light_energy = 1.3
	key.shadow_enabled = true
	_studio.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, -140, 0)
	fill.light_energy = 0.4
	_studio.add_child(fill)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.17, 0.17, 0.18)
	gmat.roughness = 0.95
	ground.material_override = gmat
	ground.position.y = -0.001
	_studio.add_child(ground)
	_holder = Node3D.new()
	_holder.name = "Holder"
	_studio.add_child(_holder)
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.near = 0.02
	_camera.far = 200.0
	_studio.add_child(_camera)
	_update_camera()


func _strip_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.card_style())
	p.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	p.offset_top = -170
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	return p


func _build_kin_panel() -> Control:
	var p := _strip_panel()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_MD)
	p.add_child(row)
	var jog := VBoxContainer.new()
	jog.custom_minimum_size = Vector2(300, 0)
	row.add_child(jog)
	jog.add_child(SectionHeader.make("Jog the tool", "move"))
	for k in ["x", "y", "z"]:
		var r := HBoxContainer.new()
		var l := Label.new()
		l.text = k.to_upper()
		l.custom_minimum_size = Vector2(18, 0)
		r.add_child(l)
		var s := HSlider.new()
		s.min_value = 0.0
		s.max_value = 220.0
		s.step = 0.5
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.value_changed.connect(_on_jog.bind(k))
		r.add_child(s)
		var v := Label.new()
		v.custom_minimum_size = Vector2(72, 0)
		v.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		v.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		r.add_child(v)
		_jog_sliders[k] = {"slider": s, "label": v}
		jog.add_child(r)
	var motors := VBoxContainer.new()
	motors.custom_minimum_size = Vector2(300, 0)
	row.add_child(motors)
	motors.add_child(SectionHeader.make("What the motors do", "settings"))
	_motor_box = VBoxContainer.new()
	motors.add_child(_motor_box)
	_kin_text = Label.new()
	_kin_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_kin_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_kin_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_kin_text.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_kin_text.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	row.add_child(_kin_text)
	return p


func _build_sim_panel() -> Control:
	var p := _strip_panel()
	p.offset_top = -230
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_MD)
	p.add_child(row)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(330, 0)
	row.add_child(left)
	left.add_child(SectionHeader.make("Program", "list"))
	var pick := HBoxContainer.new()
	_sample_opt = OptionButton.new()
	_sample_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sample_opt.item_selected.connect(func(i): _load_sample(str(_sample_opt.get_item_metadata(i))))
	pick.add_child(_sample_opt)
	var load := Button.new()
	load.text = "Open file…"
	load.tooltip_text = "Any .gcode / .nc from a slicer or CAM program"
	UITheme.style_button(load)
	load.pressed.connect(func(): _gcode_dialog.popup_centered(Vector2i(800, 600)))
	pick.add_child(load)
	left.add_child(pick)
	_gcode_edit = TextEdit.new()
	_gcode_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_gcode_edit.custom_minimum_size = Vector2(0, 120)
	_gcode_edit.add_theme_font_override("font", UITheme.font("regular", true))
	_gcode_edit.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_gcode_edit.editable = true
	_gcode_edit.text_changed.connect(_on_gcode_edited)
	left.add_child(_gcode_edit)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	right.add_child(SectionHeader.make("Run", "play"))
	var tr := HBoxContainer.new()
	tr.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_play_btn = Button.new()
	_play_btn.text = "Play"
	_play_btn.tooltip_text = "Space"
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(_on_play)
	tr.add_child(_play_btn)
	var restart := Button.new()
	restart.text = "Restart"
	UITheme.style_button(restart)
	restart.pressed.connect(func(): _sim_t = 0.0; _apply_sim_time())
	tr.add_child(restart)
	var sl := Label.new()
	sl.text = "Speed"
	tr.add_child(sl)
	_speed_opt = OptionButton.new()
	for sp in SPEEDS:
		_speed_opt.add_item("%s×" % str(sp))
	_speed_opt.select(2)
	_speed_opt.item_selected.connect(func(i): _sim_speed = float(SPEEDS[i]))
	tr.add_child(_speed_opt)
	_send_btn = Button.new()
	_send_btn.text = "Send to placed machine"
	_send_btn.tooltip_text = "Schedule this program as the placed machine's job: it runs on the world clock, draws feedstock and power on the graph"
	UITheme.style_button(_send_btn)
	_send_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_send_btn.pressed.connect(_on_send_job)
	tr.add_child(_send_btn)
	right.add_child(tr)
	_scrub = HSlider.new()
	_scrub.min_value = 0.0
	_scrub.max_value = 1.0
	_scrub.step = 0.0005
	_scrub.value_changed.connect(func(v):
		if not _plan.is_empty() and not _suppress:
			_sim_t = v * float(_plan["total_s"])
			_apply_sim_time())
	right.add_child(_scrub)
	_hud = Label.new()
	_hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hud.add_theme_font_override("font", UITheme.font("regular", true))
	_hud.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hud.add_theme_color_override("font_color", UITheme.C_TEXT)
	right.add_child(_hud)
	return p


func _build_config_panel() -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.card_style())
	p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	p.add_child(v)
	_config_tabs = TabBar.new()
	_config_tabs.add_tab("Klipper printer.cfg")
	_config_tabs.add_tab("Marlin Configuration.h")
	_config_tabs.add_tab("grbl $ settings")
	_config_tabs.add_tab("Cut list")
	_config_tabs.tab_changed.connect(func(_i): _refresh_config())
	v.add_child(_config_tabs)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sc)
	_config_text = RichTextLabel.new()
	_config_text.bbcode_enabled = false
	_config_text.fit_content = true
	_config_text.scroll_active = false
	_config_text.selection_enabled = true
	_config_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_config_text.add_theme_font_override("normal_font", UITheme.font("regular", true))
	_config_text.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	_config_text.add_theme_color_override("default_color", UITheme.C_TEXT)
	sc.add_child(_config_text)
	var cp := Button.new()
	cp.text = "Copy to clipboard"
	UITheme.style_button(cp)
	cp.pressed.connect(func(): DisplayServer.clipboard_set(_config_text.text); _status("Copied."))
	v.add_child(cp)
	return p


func _build_right() -> Control:
	var col := _scroll_column(400)
	var box: VBoxContainer = col[1]
	var sec := Collapsible.make("Work volume", true)
	box.add_child(sec)
	_size_box = sec.body
	_delta_sec = Collapsible.make("Delta geometry", true)
	box.add_child(_delta_sec)
	_delta_box = _delta_sec.body
	sec = Collapsible.make("Frame", true)
	box.add_child(sec)
	_frame_box = sec.body
	sec = Collapsible.make("Motion (guides, drives, motors)", true)
	box.add_child(sec)
	_axis_box = sec.body
	sec = Collapsible.make("Electronics and limits", true)
	box.add_child(sec)
	_elec_box = sec.body
	sec = Collapsible.make("Tool and bed", true)
	box.add_child(sec)
	_tool_box = sec.body
	box.add_child(SectionHeader.make("Checks", "circle-check"))
	_warn_box = VBoxContainer.new()
	box.add_child(_warn_box)
	sec = Collapsible.make("Motors", false)
	box.add_child(sec)
	_motors_box = sec.body
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
	for spec_btn in [["Export files", "printer.cfg, Configuration.h, grbl settings, BOM CSV, cut list, design JSON", _on_export],
			["Save to…", "Choose a folder", _on_export_to],
			["Open folder", "Show the exported files", _on_open_folder]]:
		var b := Button.new()
		b.text = str(spec_btn[0])
		b.tooltip_text = str(spec_btn[1])
		UITheme.style_button(b)
		b.pressed.connect(spec_btn[2])
		ex.add_child(b)
	box.add_child(ex)
	_export_status = Label.new()
	_export_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_export_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_export_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_export_status)
	return col[0]


func _build_footer() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var hint := Label.new()
	hint.text = "Drag to orbit · wheel to zoom · hover names a part · Kinematics jogs the tool · Simulate plays real G-code"
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.clip_text = true
	hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(hint)
	_apply_btn = Button.new()
	_apply_btn.text = "Apply to placed machine"
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
	_after_spec_jump()


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_spec.duplicate(true))
	_spec = _redo.pop_back()
	_coalesce_key = ""
	_after_spec_jump()


func _after_spec_jump() -> void:
	_built_key = ""
	_update_undo_buttons()
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
	elif group.begins_with("axis."):
		var k := group.substr(5)
		var g: Dictionary = (_spec["axis"] as Dictionary).get(k, {})
		g[key] = value
		(_spec["axis"] as Dictionary)[k] = g
	else:
		var g: Dictionary = _spec.get(group, {})
		g[key] = value
		_spec[group] = g
	_queue_rebuild()


func _queue_rebuild() -> void:
	_rebuild_timer = REBUILD_DELAY


func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = GantryLabSpec.resolve(_spec)
	_design = GantryLabDesign.solve(_spec)
	var skey := "%s|%s|%s" % [str(_spec["kinematics"]), str(_spec["electronics"]["board"]), str(_spec["tool"]["id"])]
	if skey != _built_key:
		_built_key = skey
		_build_settings_rows()
	_sync_settings()
	_rebuild_studio()
	_refresh_checks()
	_refresh_motors()
	_refresh_bom()
	_refresh_header()
	_refresh_config()
	_sync_kin_buttons()
	_refresh_jog_ranges()
	_replan()
	_show_view()
	_update_undo_buttons()


func _refresh_header() -> void:
	if _name_edit.text != str(_spec["name"]):
		_name_edit.text = str(_spec["name"])
	var st: Dictionary = _design["stats"]
	_subtitle.text = "%s · %.0f L · %.1f kg · $%.0f · %.0f W" % [GantryLabSpec.describe(_spec), float(st["volume_l"]), float(st["mass_kg"]), float(st["usd"]), float(st["watts"])]
	_why_lbl.text = str(GantryLabSpec.KINEMATICS_WHY[_spec["kinematics"]])


func _on_name_changed() -> void:
	var t := _name_edit.text.strip_edges()
	if t.is_empty() or t == str(_spec["name"]):
		return
	_push_undo("name")
	_spec["name"] = t
	_refresh_header()


func _on_application(id: String) -> void:
	_push_undo()
	_spec = GantryLabSpec.for_application(id)
	_built_key = ""
	_rebuild_now()
	_frame_camera()
	_load_sample_default()


func _on_kinematics(kin: String) -> void:
	if kin == str(_spec["kinematics"]):
		_sync_kin_buttons()
		return
	_push_undo("kinematics")
	_spec["kinematics"] = kin
	_spec = GantryLabSpec.resolve(_spec)
	if kin == "delta":
		var v: Dictionary = _spec["volume"]
		var r := float(v["x_mm"]) * 0.5
		_spec["delta"] = {"arm_mm": r * 2.4 + 50.0, "tower_r_mm": r + 60.0, "effector_r_mm": 32.0, "carriage_r_mm": 20.0}
	_built_key = ""
	_rebuild_now()
	_frame_camera()
	_load_sample_default()


func _sync_kin_buttons() -> void:
	for b in _kin_box.get_children():
		if b is Button and b.has_meta("kin"):
			(b as Button).set_pressed_no_signal(str(b.get_meta("kin")) == str(_spec["kinematics"]))
	_delta_sec.visible = str(_spec["kinematics"]) == "delta"


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
	l.custom_minimum_size = Vector2(150, 0)
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


func _spin(min_v: float, max_v: float, step: float, suffix: String, cb: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.suffix = suffix
	s.value_changed.connect(cb)
	return s


func _check(text: String, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.toggled.connect(cb)
	return c


func _option(items: Array, cb: Callable) -> OptionButton:
	var o := OptionButton.new()
	for i in items.size():
		var it: Array = items[i]
		o.add_item(str(it[1]), i)
		o.set_item_metadata(i, it[0])
	o.item_selected.connect(func(idx): cb.call(o.get_item_metadata(idx)))
	return o


func _select_meta(o: OptionButton, value: Variant) -> void:
	for i in o.item_count:
		var m: Variant = o.get_item_metadata(i)
		if typeof(m) == typeof(value) and m == value:
			o.select(i)
			return
		if (m is float or m is int) and (value is float or value is int) and absf(float(m) - float(value)) < 1e-6:
			o.select(i)
			return


func _build_settings_rows() -> void:
	var kin := str(_spec["kinematics"])
	_clear(_size_box)
	_clear(_delta_box)
	_clear(_frame_box)
	_clear(_axis_box)
	_clear(_elec_box)
	_clear(_tool_box)
	var delta := kin == "delta"
	_row(_size_box, "Bed diameter" if delta else "X travel", _spin(GantryLabSpec.MIN_AXIS_MM, GantryLabSpec.MAX_AXIS_MM, 10.0, " mm", func(v): _edit("volume", "x_mm", v)), "The work the tool can reach in X")
	if not delta:
		_row(_size_box, "Y travel", _spin(GantryLabSpec.MIN_AXIS_MM, GantryLabSpec.MAX_AXIS_MM, 10.0, " mm", func(v): _edit("volume", "y_mm", v)))
	_row(_size_box, "Z height", _spin(GantryLabSpec.MIN_AXIS_MM, GantryLabSpec.MAX_AXIS_MM, 10.0, " mm", func(v): _edit("volume", "z_mm", v)))
	if delta:
		_row(_delta_box, "Arm length", _spin(100.0, 1200.0, 5.0, " mm", func(v): _edit("delta", "arm_mm", v)), "Rod-end centre to centre. 1.5–2× the delta radius keeps the effector stiff")
		_row(_delta_box, "Tower radius", _spin(60.0, 1000.0, 5.0, " mm", func(v): _edit("delta", "tower_r_mm", v)), "Centre to each tower's centreline")
		_row(_delta_box, "Effector offset", _spin(10.0, 200.0, 1.0, " mm", func(v): _edit("delta", "effector_r_mm", v)), "Centre to the arms' effector pivots")
		_row(_delta_box, "Carriage offset", _spin(5.0, 150.0, 1.0, " mm", func(v): _edit("delta", "carriage_r_mm", v)), "Tower centreline to the arms' carriage pivots")
	_row(_frame_box, "Frame extrusion", _option(GantryLabParts.label_list(GantryLabParts.PROFILE_ORDER, GantryLabParts.PROFILES), func(v): _edit("frame", "profile", v)), "The base and uprights")
	_row(_frame_box, "Gantry extrusion", _option(GantryLabParts.label_list(GantryLabParts.PROFILE_ORDER, GantryLabParts.PROFILES), func(v): _edit("frame", "gantry_profile", v)), "The X beam: the part that sags")
	_row(_frame_box, "Corners", _option(_opt_list(GantryLabSpec.CORNERS, GantryLabSpec.CORNER_LABELS), func(v): _edit("frame", "corners", v)))
	_row(_frame_box, "Enclosed", _check("Panels on the sides and back", func(v): _edit("frame", "enclosed", v)), "An enclosure keeps ABS warm and fumes in")
	_row(_frame_box, "Feet", _check("Rubber feet", func(v): _edit("frame", "feet", v)))
	for m in GantryLabSpec.motor_axes(kin):
		var k := str(m["key"])
		if delta and k == "z" and _axis_box.get_child_count() > 0:
			break
		var head := Label.new()
		head.text = str(m["label"]) if not delta else "Towers (all three alike)"
		if (kin == "corexy" or kin == "hbot") and k == "x":
			head.text = "Motors A and B (one belt pair)"
		elif kin == "corexz" and k == "x":
			head.text = "Motors A and B (X + Z belts)"
		head.add_theme_color_override("font_color", UITheme.C_TEXT)
		_axis_box.add_child(head)
		_row(_axis_box, "Guide", _option(GantryLabParts.label_list(GantryLabParts.GUIDE_ORDER, GantryLabParts.GUIDES), func(v): _edit("axis." + k, "guide", v)), _guide_tip())
		_row(_axis_box, "Drive", _option(GantryLabParts.label_list(GantryLabParts.DRIVE_ORDER, GantryLabParts.DRIVES), func(v): _edit("axis." + k, "drive", v)), _drive_tip())
		_row(_axis_box, "Motor", _option(GantryLabParts.label_list(GantryLabParts.MOTOR_ORDER, GantryLabParts.MOTORS), func(v): _edit("axis." + k, "motor", v)))
		_row(_axis_box, "Pulley teeth", _spin(12, 60, 1, " T", func(v): _edit("axis." + k, "pulley_teeth", int(v))), "A GT2 pulley: 20 teeth = 40 mm per turn (belts only)")
		_row(_axis_box, "Microsteps", _option([[1, "1 (full step)"], [2, "2"], [4, "4"], [8, "8"], [16, "16"], [32, "32"], [64, "64"], [128, "128"], [256, "256"]], func(v): _edit("axis." + k, "microsteps", int(v))), "Finer steps smooth the motion and cost step rate; 16 is the Marlin default, Klipper runs 16–64")
		if not delta and not ((kin == "corexy" or kin == "hbot") and k != "z") and not (kin == "corexz" and k != "y"):
			_row(_axis_box, "Motors on this axis", _spin(1, 4, 1, "", func(v): _edit("axis." + k, "motors", int(v))), "Two Y motors on a wide router; two to four Z motors level a bed")
	_row(_elec_box, "Board", _option(GantryLabParts.label_list(GantryLabParts.BOARD_ORDER, GantryLabParts.BOARDS), func(v): _edit("electronics", "board", v)), _board_tip())
	var fw: Array = GantryLabParts.board(str(_spec["electronics"]["board"]))["firmware"]
	var fw_items: Array = []
	for f in fw:
		fw_items.append([f, str(GantryLabParts.FIRMWARE_LABELS[f])])
	_row(_elec_box, "Firmware", _option(fw_items, func(v): _edit("electronics", "firmware", v)))
	var volts: Array = GantryLabParts.board(str(_spec["electronics"]["board"]))["volts"]
	var v_items: Array = []
	for vv in volts:
		v_items.append([int(vv), "%d V" % int(vv)])
	_row(_elec_box, "Motor supply", _option(v_items, func(v): _edit("electronics", "volts", int(v))), "Higher voltage keeps torque at speed")
	_row(_elec_box, "Max feed", _spin(5.0, 1500.0, 5.0, " mm/s", func(v): _edit("electronics", "max_feed_mm_s", v)), "Travel and print moves are capped here")
	_row(_elec_box, "Acceleration", _spin(50.0, 50000.0, 50.0, " mm/s²", func(v): _edit("electronics", "accel_mm_s2", v)), "How hard every move starts and stops; the motors and belts must afford it")
	_row(_elec_box, "Corner speed (jerk)", _spin(0.5, 60.0, 0.5, " mm/s", func(v): _edit("electronics", "junction_mm_s", v)), "The instant velocity change allowed at a corner")
	_row(_tool_box, "Tool", _option(GantryLabParts.label_list(GantryLabParts.TOOL_ORDER, GantryLabParts.TOOLS), func(v): _on_tool_changed(v)), _tool_tip())
	_row(_tool_box, "Bed", _option(GantryLabParts.label_list(GantryLabParts.BED_ORDER, GantryLabParts.BEDS), func(v): _edit("tool", "bed", v)))


func _opt_list(ids: Array, labels: Dictionary) -> Array:
	var out: Array = []
	for id in ids:
		out.append([id, str(labels.get(id, id))])
	return out


func _guide_tip() -> String:
	var out: Array = []
	for id in GantryLabParts.GUIDE_ORDER:
		out.append("%s: %s" % [str(GantryLabParts.GUIDES[id]["label"]), str(GantryLabParts.GUIDES[id]["note"])])
	return "\n".join(out)


func _drive_tip() -> String:
	var out: Array = []
	for id in GantryLabParts.DRIVE_ORDER:
		out.append("%s: %s" % [str(GantryLabParts.DRIVES[id]["label"]), str(GantryLabParts.DRIVES[id]["note"])])
	return "\n".join(out)


func _board_tip() -> String:
	var out: Array = []
	for id in GantryLabParts.BOARD_ORDER:
		out.append("%s: %s" % [str(GantryLabParts.BOARDS[id]["label"]), str(GantryLabParts.BOARDS[id]["note"])])
	return "\n".join(out)


func _tool_tip() -> String:
	var out: Array = []
	for id in GantryLabParts.TOOL_ORDER:
		out.append("%s: %s" % [str(GantryLabParts.TOOLS[id]["label"]), str(GantryLabParts.TOOLS[id]["note"])])
	return "\n".join(out)


func _on_tool_changed(v: Variant) -> void:
	if _suppress:
		return
	_push_undo("tool.id")
	_spec["tool"]["id"] = str(v)
	_spec["tool"]["bed"] = str(GantryLabParts.tool(str(v))["bed"])
	_queue_rebuild()
	_gcode_name = ""


func _sync_settings() -> void:
	_suppress = true
	var kin := str(_spec["kinematics"])
	var v: Dictionary = _spec["volume"]
	_set_rows(_size_box, [float(v["x_mm"])] + ([] if kin == "delta" else [float(v["y_mm"])]) + [float(v["z_mm"])])
	if kin == "delta":
		var d: Dictionary = _spec["delta"]
		_set_rows(_delta_box, [float(d["arm_mm"]), float(d["tower_r_mm"]), float(d["effector_r_mm"]), float(d["carriage_r_mm"])])
	var f: Dictionary = _spec["frame"]
	_set_rows(_frame_box, [str(f["profile"]), str(f["gantry_profile"]), str(f["corners"]), bool(f["enclosed"]), bool(f["feet"])])
	var vals: Array = []
	for m in GantryLabSpec.motor_axes(kin):
		var k := str(m["key"])
		var a: Dictionary = _spec["axis"][k]
		vals.append_array([str(a["guide"]), str(a["drive"]), str(a["motor"]), int(a["pulley_teeth"]), int(a["microsteps"])])
		if not (kin == "delta") and not ((kin == "corexy" or kin == "hbot") and k != "z") and not (kin == "corexz" and k != "y"):
			vals.append(int(a["motors"]))
		if kin == "delta":
			break
	_set_rows(_axis_box, vals)
	var e: Dictionary = _spec["electronics"]
	_set_rows(_elec_box, [str(e["board"]), str(e["firmware"]), int(e["volts"]), float(e["max_feed_mm_s"]), float(e["accel_mm_s2"]), float(e["junction_mm_s"])])
	_set_rows(_tool_box, [str(_spec["tool"]["id"]), str(_spec["tool"]["bed"])])
	_suppress = false


func _set_rows(box: Container, values: Array) -> void:
	var i := 0
	for row in box.get_children():
		if not (row is HBoxContainer) or row.get_child_count() < 2:
			continue
		if i >= values.size():
			break
		_set_ctl(row.get_child(1), values[i])
		i += 1


func _set_ctl(c: Control, v: Variant) -> void:
	if c is SpinBox:
		(c as SpinBox).set_value_no_signal(float(v))
	elif c is CheckBox:
		(c as CheckBox).set_pressed_no_signal(bool(v))
	elif c is OptionButton:
		_select_meta(c as OptionButton, v)


# ---------------------------------------------------------------------------
# Checks, motors, BOM, config
# ---------------------------------------------------------------------------

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


func _refresh_motors() -> void:
	_clear(_motors_box)
	_motors_box.add_child(_table_row(["Motor", "steps/mm", "µm/step", "max mm/s", "accel"], true, [90, 70, 60, 70, 0]))
	for m in _design["motors"]:
		var md: Dictionary = m
		_motors_box.add_child(_table_row([str(md["label"]), "%.1f" % float(md["steps_per_mm"]), "%.1f" % float(md["resolution_um"]),
			"%.0f" % float(md["max_mm_s"]), "%.0f" % float(md["accel_capable"])], false, [90, 70, 60, 70, 0]))


func _refresh_bom() -> void:
	_clear(_bom_box)
	var bom: Dictionary = _design["bom"]
	_bom_lbl.text = "$%.0f · %.1f kg · %.1f m of extrusion in %s · %s · %s" % [float(bom["usd"]), float(bom["kg"]), float(bom["extrusion_m"]),
		UiText.count(int(bom["stock"]["pieces"]), "stock length"), UiText.count(int(bom["motors"]), "motor"),
		str(GantryLabParts.HARDWARE[str(bom["psu"])]["label"])]
	_bom_box.add_child(_table_row(["Qty", "Item", "Detail", "$"], true, [48, 160, 0, 52]))
	for r in bom["rows"]:
		_bom_box.add_child(_table_row(["%d %s" % [int(r["qty"]), str(r["unit"])], str(r["item"]), str(r["detail"]), "%.0f" % (float(r["usd"]) * float(r["qty"]))], false, [48, 160, 0, 52]))


func _table_row(cells: Array, head: bool, widths: Array) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	for i in cells.size():
		var l := Label.new()
		l.text = str(cells[i])
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		l.add_theme_color_override("font_color", UITheme.C_TEXT if head else UITheme.C_TEXT_S)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.tooltip_text = str(cells[i])
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		if int(widths[i]) > 0:
			l.custom_minimum_size = Vector2(int(widths[i]), 0)
		else:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
	return row


func _refresh_config() -> void:
	if _config_text == null or _design.is_empty():
		return
	match _config_tabs.current_tab:
		0:
			_config_text.text = GantryLabExport.klipper_cfg(_design)
		1:
			_config_text.text = GantryLabExport.marlin_h(_design)
		2:
			_config_text.text = GantryLabExport.grbl_settings(_design)
		_:
			_config_text.text = GantryLabBom.cut_list_text(_design["bom"])


# ---------------------------------------------------------------------------
# Designs
# ---------------------------------------------------------------------------

func _refresh_design_list() -> void:
	_design_list.clear()
	_design_entries.clear()
	for p in GantryLabPresets.builtins():
		_design_list.add_item(str(p["name"]))
		_design_list.set_item_tooltip(_design_list.item_count - 1, str(p.get("blurb", "")))
		_design_entries.append({"spec": p["spec"], "builtin": true, "id": str(p["id"])})
	for d in _library:
		_design_list.add_item("★ " + str(d["name"]))
		_design_entries.append({"spec": d["spec"], "builtin": false, "id": str(d["id"])})


func _on_design_activated(idx: int) -> void:
	if idx < 0 or idx >= _design_entries.size():
		return
	_push_undo()
	_spec = GantryLabSpec.resolve((_design_entries[idx]["spec"] as Dictionary).duplicate(true))
	_built_key = ""
	_rebuild_now()
	_frame_camera()
	_load_sample_default()


func _on_save_design() -> void:
	var name := str(_spec["name"])
	var id := GantryLabExport.safe_name(name)
	var replaced := false
	for d in _library:
		if str(d["id"]) == id:
			d["spec"] = _spec.duplicate(true)
			d["name"] = name
			replaced = true
	if not replaced:
		_library.append({"id": id, "name": name, "spec": _spec.duplicate(true)})
	GantryLabPresets.save_library(_library)
	_refresh_design_list()
	_status("Saved \"%s\" to your library." % name)


func _on_forget_design() -> void:
	var sel := _design_list.get_selected_items()
	if sel.is_empty():
		return
	var e: Dictionary = _design_entries[sel[0]]
	if bool(e["builtin"]):
		_status("Built-in designs stay.")
		return
	for i in _library.size():
		if str(_library[i]["id"]) == str(e["id"]):
			_library.remove_at(i)
			break
	GantryLabPresets.save_library(_library)
	_refresh_design_list()


# ---------------------------------------------------------------------------
# Studio
# ---------------------------------------------------------------------------

func _show_view() -> void:
	var t := _tabs.current_tab
	_vp_container.visible = t != 3
	_kin_panel.visible = t == 1
	_sim_panel.visible = t == 2
	_config_panel.visible = t == 3
	if t == 1:
		_set_jog(_jog)
	elif t == 2:
		_apply_sim_time()
	elif t == 0 and _machine != null:
		_machine.set_preview_progress(0.0)


func _rebuild_studio() -> void:
	if _holder == null or _design.is_empty():
		return
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	_machine = GantryLabBuilder.build_from_design(_design, "Machine", {"record": true})
	_machine.follow_drivers = false
	_holder.add_child(_machine)
	_machine.set_tool_mm(_clamp_jog(_jog))
	if not _parse.is_empty():
		_lay_preview()


func _frame_camera() -> void:
	var dims: Vector3 = _design["stats"]["dims_m"] if not _design.is_empty() else Vector3(0.5, 0.5, 0.5)
	_target = Vector3(0, dims.y * 0.45, 0)
	_dist = clampf(maxf(maxf(dims.x, dims.z), dims.y) * 1.9 + 0.3, 0.5, 40.0)
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
			_dist = maxf(0.2, _dist * 0.9)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(60.0, _dist * 1.1)
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
				_pitch = clampf(_pitch - mm.relative.y * 0.01, -0.2, 1.45)
				_update_camera()
		else:
			_hover_frame += 1
			if _hover_frame % 4 == 0:
				var hit := _pick_at(mm.position)
				_hover_lbl.text = _describe_hit(hit)


func _describe_hit(hit: Dictionary) -> String:
	if hit.is_empty():
		return ""
	var asm := str(hit.get("assembly", ""))
	return "%s%s" % [str(hit["label"]), (" · moves with the %s" % asm) if not asm.is_empty() else " · frame"]


func _pick_at(pos: Vector2) -> Dictionary:
	if _camera == null or _machine == null:
		return {}
	var vp_size := Vector2(_viewport.size)
	var cs := _vp_container.size
	var p := pos * (vp_size / cs) if cs.x > 0.0 and cs.y > 0.0 else pos
	var o := _camera.project_ray_origin(p)
	var d := _camera.project_ray_normal(p)
	var inv := _machine.global_transform.affine_inverse()
	return GantryLabBuilder.pick(_machine, inv * o, (inv.basis * d).normalized())


# ---------------------------------------------------------------------------
# Kinematics tab
# ---------------------------------------------------------------------------

func _refresh_jog_ranges() -> void:
	var v: Dictionary = _spec["volume"]
	var delta := str(_spec["kinematics"]) == "delta"
	for k in ["x", "y", "z"]:
		var s: HSlider = (_jog_sliders[k] as Dictionary)["slider"]
		var span := float(v["%s_mm" % k])
		if delta and k != "z":
			s.min_value = -span * 0.5
			s.max_value = span * 0.5
		else:
			s.min_value = 0.0
			s.max_value = span
	_jog = _clamp_jog(_jog)


func _clamp_jog(j: Vector3) -> Vector3:
	var v: Dictionary = _spec["volume"]
	if str(_spec["kinematics"]) == "delta":
		var r := float(v["x_mm"]) * 0.5
		var xy := Vector2(j.x, j.y)
		if xy.length() > r:
			xy = xy.normalized() * r
		return Vector3(xy.x, xy.y, clampf(j.z, 0.0, float(v["z_mm"])))
	return Vector3(clampf(j.x, 0.0, float(v["x_mm"])), clampf(j.y, 0.0, float(v["y_mm"])), clampf(j.z, 0.0, float(v["z_mm"])))


func _on_jog(value: float, axis: String) -> void:
	if _suppress:
		return
	match axis:
		"x":
			_jog.x = value
		"y":
			_jog.y = value
		"z":
			_jog.z = value
	_set_jog(_jog, false)


func _set_jog(j: Vector3, sync_sliders: bool = true) -> void:
	_jog = _clamp_jog(j)
	if _machine != null:
		_machine.set_tool_mm(_jog)
	_suppress = true
	for k in ["x", "y", "z"]:
		var row: Dictionary = _jog_sliders[k]
		var val := _jog.x if k == "x" else (_jog.y if k == "y" else _jog.z)
		if sync_sliders:
			(row["slider"] as HSlider).set_value_no_signal(val)
		(row["label"] as Label).text = "%.1f mm" % val
	_suppress = false
	_refresh_motor_readout()


func _refresh_motor_readout() -> void:
	if _motor_box == null:
		return
	_clear(_motor_box)
	var kin := str(_spec["kinematics"])
	var mp := GantryLabKinematics.motor_positions(_spec, _jog)
	var i := 0
	for m in mp:
		var md: Dictionary = m
		var spm := float((_design["motors"][mini(i, (_design["motors"] as Array).size() - 1)] as Dictionary)["steps_per_mm"])
		var mm := float(md["mm"])
		var txt := "%s  %s mm  (%s steps)" % [str(md["label"]), ("%.1f" % mm) if is_finite(mm) else "out of reach", ("%d" % int(round(mm * spm))) if is_finite(mm) else "—"]
		var l := Label.new()
		l.text = txt
		l.add_theme_font_override("font", UITheme.font("regular", true))
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		l.add_theme_color_override("font_color", UITheme.C_TEXT)
		_motor_box.add_child(l)
		i += 1
	match kin:
		"corexy", "hbot":
			_kin_text.text = "A = X + Y and B = X − Y: a pure X move turns both motors the same way, a pure Y move turns them against each other, and a 45° diagonal turns one motor at √2 × the feed while the other stands still. Neither motor rides the gantry, which is why CoreXY accelerates hardest." + (" On an H-bot both halves are one belt, so an X move pulls one end of the gantry and tries to rack it." if kin == "hbot" else "")
		"corexz":
			_kin_text.text = "A = X + Z and B = X − Z: the belts share X and Z, so a vertical move is as fast as a horizontal one and there is no lead screw to wobble. Y is the bed."
		"delta":
			var r := GantryLabKinematics.delta_reach(_spec)
			_kin_text.text = "Each tower carriage sits at z + √(L² − d²), d its horizontal distance to the tool: all three move for every move, and the farther the tool from a tower the lower that carriage. Arms %.0f mm, delta radius %.0f mm, reach %.0f mm from the centre at %.0f° minimum arm angle." % [float(_spec["delta"]["arm_mm"]), float(r["delta_radius_mm"]), float(r["reach_mm"]), GantryLabKinematics.DELTA_MIN_ARM_DEG]
		"bedslinger":
			_kin_text.text = "One motor per axis. The bed carries Y (it moves the opposite way to the commanded Y, so the tool ends up over the point), the X beam climbs the Z screws, the X carriage slides along it."
		"router":
			_kin_text.text = "One motor per axis, two on Y for a wide gantry: the whole gantry rides the Y rails, the X carriage rides the gantry beam, the Z axis plunges the tool. Screws, not belts, because a cutter pushes back."
		_:
			_kin_text.text = "One motor per axis. The head moves in X along the beam and in Y with the beam on the top rails; only the bed moves in Z, dropping a layer at a time."


# ---------------------------------------------------------------------------
# Simulate tab
# ---------------------------------------------------------------------------

func _load_sample_default() -> void:
	if _sample_opt == null:
		return
	_sample_opt.clear()
	var list := GantryLabSamples.list(_spec)
	for i in list.size():
		var smp: Dictionary = list[i]
		_sample_opt.add_item(str(smp["label"]), i)
		_sample_opt.set_item_metadata(i, str(smp["id"]))
		_sample_opt.set_item_tooltip(i, str(smp["blurb"]))
	if not list.is_empty():
		_sample_opt.select(0)
		_load_sample(str(list[0]["id"]))


func _load_sample(id: String) -> void:
	_gcode_name = str(id)
	_gcode_text = GantryLabSamples.text(_spec, id)
	_suppress = true
	_gcode_edit.text = _gcode_text
	_suppress = false
	_replan(true)


func _on_gcode_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_status("Could not read %s" % path)
		return
	_gcode_text = f.get_as_text()
	_gcode_name = path.get_file()
	_suppress = true
	_gcode_edit.text = _gcode_text if _gcode_text.length() < 400000 else _gcode_text.substr(0, 400000) + "\n; (truncated in the editor; the whole file runs)"
	_suppress = false
	_replan(true)
	_tabs.current_tab = 2
	_show_view()


func _on_gcode_edited() -> void:
	if _suppress:
		return
	_gcode_text = _gcode_edit.text
	_gcode_name = "edited"
	_rebuild_timer = 0.6
	_plan = {}


func _replan(reset: bool = false) -> void:
	if _gcode_text.is_empty():
		return
	_parse = GantryLabGcode.parse(_gcode_text)
	if not bool(_parse.get("ok", false)):
		_plan = {}
		_hud.text = "No motion in this program: %s" % str(_parse.get("error", ""))
		return
	_plan = GantryLabMotion.plan(_parse, _design["limits"])
	if reset:
		_sim_t = 0.0
		_sim_playing = false
		_play_btn.text = "Play"
	_sim_t = clampf(_sim_t, 0.0, float(_plan["total_s"]))
	_lay_preview()
	_apply_sim_time()


func _lay_preview() -> void:
	if _machine == null or _parse.is_empty() or not bool(_parse.get("ok", false)):
		return
	var tp := GantryLabGcode.to_toolpath(_parse)
	var tool := GantryLabParts.tool(str(_spec["tool"]["id"]))
	var col := Color(0.85, 0.55, 0.2)
	match str(tool["process"]):
		"subtractive":
			col = Color(0.35, 0.3, 0.25)
		"mark":
			col = Color(0.2, 0.15, 0.1)
	_machine.set_toolpath_preview(tp["points"], tp["extruding"], maxf(float(tool["nozzle_mm"]), 1.0 if str(tool["process"]) != "additive" else 0.4), col)


func _on_play() -> void:
	if _plan.is_empty():
		return
	if _sim_t >= float(_plan["total_s"]) - 1e-6:
		_sim_t = 0.0
	_sim_playing = not _sim_playing
	_play_btn.text = "Pause" if _sim_playing else "Play"


func _apply_sim_time() -> void:
	if _plan.is_empty() or _machine == null:
		return
	var total := float(_plan["total_s"])
	var smp := GantryLabMotion.sample(_plan, _sim_t)
	var pos: Vector3 = smp["pos"]
	if _tabs.current_tab == 2:
		_machine.set_tool_mm(pos)
		_machine.set_preview_progress(_progress_of_sample(smp))
	_suppress = true
	_scrub.set_value_no_signal(_sim_t / maxf(total, 1e-6))
	_suppress = false
	var mv := GantryLabKinematics.motor_velocity(_spec, _dir_of(smp), pos)
	var mp := GantryLabKinematics.motor_positions(_spec, pos)
	var v := float(smp["v"])
	var motor_lines: Array = []
	for i in mini(mp.size(), mv.size()):
		var spm := float((_design["motors"][mini(i, (_design["motors"] as Array).size() - 1)] as Dictionary)["steps_per_mm"])
		motor_lines.append("%-8s %8.1f mm  %6.0f mm/s  %7.0f steps/s" % [str(mp[i]["label"]), float(mp[i]["mm"]), v * float(mv[i]), v * float(mv[i]) * spm])
	var est_hr := total / 3600.0
	_hud.text = "%s · %s of %s · move %d of %d (line %d)\nX %.1f  Y %.1f  Z %.1f mm · %s %.0f mm/s (asked %.0f) · %s\n%s\n%s · peak %s steps/s on %s · %s" % [
		_gcode_name, GantryLabMotion.fmt_duration(_sim_t), GantryLabMotion.fmt_duration(total), int(smp["i"]) + 1, int(_plan["n"]), int(smp["line"]),
		pos.x, pos.y, pos.z, "rapid" if bool(smp["rapid"]) else ("extruding" if bool(smp["extruding"]) else "feed"), v, float(smp["feed"]),
		"layer %d of %d" % [_layer_of(pos.z), int(_plan["layers"])] if int(_plan["layers"]) > 0 else "",
		"\n".join(motor_lines),
		"%d %% of moves hit the feed cap, %d %% never reach it (too short for the acceleration)" % [int(100.0 * float(_plan["max_feed_hit_share"])), int(100.0 * float(_plan["accel_limited_share"]))],
		_fmt_k(float(_plan["peak_step_hz"])), str((_design["motors"][int(_plan["peak_motor"])] as Dictionary)["label"]) if int(_plan["peak_motor"]) < (_design["motors"] as Array).size() else "?",
		("job %s at 1× (%.2f kg of %s)" % [GantryLabMotion.fmt_duration(total), _material_kg(), str(GantryLabParts.tool(str(_spec["tool"]["id"]))["material"])]) if GantryLabSpec.is_additive(_spec) else "job %s at 1×" % GantryLabMotion.fmt_duration(total)]
	if est_hr > 0.0:
		pass


func _dir_of(smp: Dictionary) -> Vector3:
	var i := int(smp["i"])
	if i < 0 or _plan.is_empty():
		return Vector3.ZERO
	var mv: Dictionary = (_plan["moves"] as Array)[i]
	var d: Vector3 = (mv["p1"] as Vector3) - (mv["p0"] as Vector3)
	return d.normalized() if d.length() > 1e-9 else Vector3.ZERO


func _progress_of_sample(smp: Dictionary) -> float:
	# Beads are laid per extruding POINT in path order; approximate by the
	# share of extruded length so far.
	var i := int(smp["i"])
	if i < 0 or _plan.is_empty():
		return 0.0
	var moves: Array = _plan["moves"]
	var done := 0.0
	var total := 0.0
	for k in moves.size():
		var m: Dictionary = moves[k]
		if float(m["e_mm"]) <= 0.0:
			continue
		var l := (m["p0"] as Vector3).distance_to(m["p1"] as Vector3)
		total += l
		if k < i:
			done += l
		elif k == i:
			done += l * float(smp["s"])
	return done / total if total > 0.0 else 0.0


func _layer_of(z: float) -> int:
	var layers := int(_plan.get("layers", 0))
	if layers <= 0:
		return 0
	var bmin: Vector3 = _parse["bounds_min"]
	var bmax: Vector3 = _parse["bounds_max"]
	var span := maxf(bmax.z - bmin.z, 1e-6)
	return clampi(int(floor((z - bmin.z) / span * layers)) + 1, 1, layers)


func _material_kg() -> float:
	var tool := GantryLabParts.tool(str(_spec["tool"]["id"]))
	var d := float(tool["filament_mm"])
	var vol_mm3 := float(_parse.get("extrusion_mm", 0.0)) * PI * d * d * 0.25
	return vol_mm3 / 1000.0 * float(tool["density_g_cm3"]) / 1000.0


func _fmt_k(hz: float) -> String:
	return ("%.1f k" % (hz / 1000.0)) if hz >= 1000.0 else "%.0f" % hz


func _on_send_job() -> void:
	if _bound_prop_id.is_empty() or _plan.is_empty():
		_status("Place the machine first, then send it a program.")
		return
	var sgv := ServiceLocator.graph()
	var rec := _prop_record(_bound_prop_id)
	var iid := str(rec.get("graph_item_id", ""))
	if sgv == null or iid.is_empty():
		_status("The placed machine has no graph node yet.")
		return
	var tp := GantryLabGcode.to_toolpath(_parse, float(_plan["total_s"]) / 3600.0)
	var ok := bool(sgv.call("start_machine_job", iid, tp, "gantry_%s" % GantryLabExport.safe_name(_gcode_name), _gcode_name, 1, {}))
	if ok:
		_status("Job sent: %s runs %s on the world clock." % [_gcode_name, GantryLabMotion.fmt_duration(float(_plan["total_s"]))])
		close()
	else:
		_status("The machine refused the job (is one already running?).")


# ---------------------------------------------------------------------------
# Export, place, apply
# ---------------------------------------------------------------------------

func export_dir() -> String:
	return EXPORT_ROOT.path_join(GantryLabExport.safe_name(str(_spec["name"])))


func _on_export() -> void:
	_write_files(export_dir())


func _on_export_to() -> void:
	_file_dialog.popup_centered(Vector2i(800, 600))


func _on_export_dir_selected(dir: String) -> void:
	_write_files(dir)


func _write_files(dir: String) -> void:
	var r := GantryLabExport.write_all(_design, dir)
	if bool(r["ok"]):
		_status("Wrote %s to %s" % [UiText.count((r["files"] as Array).size(), "file"), ProjectSettings.globalize_path(dir)])
	else:
		_status("Export failed: %s" % str(r["error"]))


func _on_open_folder() -> void:
	var dir := export_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	OS.shell_open(ProjectSettings.globalize_path(dir))


func _status(text: String) -> void:
	_status_text = text
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


func _on_place() -> void:
	if _loader != null and _loader.has_method("begin_gantrylab_placement"):
		if bool(_loader.call("begin_gantrylab_placement", GantryLabSpec.to_json_safe(_spec))):
			close()
			return
	_status("Placing needs a location map.")


func _on_apply() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	var patch := {"gantry_spec": GantryLabSpec.to_json_safe(_spec)}
	if main != null:
		PlacedPropService.update_prop_record(main, _bound_prop_id, patch, true)
		PlacedPropService.sync_gantry_graph(main, _bound_prop_id)
	close()


# ---------------------------------------------------------------------------
# Accessors for the tour and the harness
# ---------------------------------------------------------------------------

func design() -> Dictionary:
	return _design


func spec() -> Dictionary:
	return _spec


func set_tab(i: int) -> void:
	_tabs.current_tab = i
	_show_view()


func load_builtin(id: String) -> void:
	var p := GantryLabPresets.builtin(id)
	if p.is_empty():
		return
	_spec = GantryLabSpec.resolve((p["spec"] as Dictionary).duplicate(true))
	_built_key = ""
	_rebuild_now()
	_frame_camera()
	_load_sample_default()


func jog(mm: Vector3) -> void:
	_set_jog(mm)


func load_sample(id: String) -> void:
	for i in _sample_opt.item_count:
		if str(_sample_opt.get_item_metadata(i)) == id:
			_sample_opt.select(i)
	_load_sample(id)


func sim_play(playing: bool) -> void:
	_sim_playing = playing
	_play_btn.text = "Pause" if playing else "Play"


func sim_seek(frac: float) -> void:
	if _plan.is_empty():
		return
	_sim_t = clampf(frac, 0.0, 1.0) * float(_plan["total_s"])
	_apply_sim_time()


func sim_state() -> Dictionary:
	if _plan.is_empty():
		return {}
	var smp := GantryLabMotion.sample(_plan, _sim_t)
	return {"t": _sim_t, "total_s": float(_plan["total_s"]), "pos": smp["pos"], "v": smp["v"], "playing": _sim_playing, "moves": int(_plan["n"])}


func machine() -> GantryLabBuilder:
	return _machine
