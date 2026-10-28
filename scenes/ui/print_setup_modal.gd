extends Control

## Print setup — the one print screen for every printer in the game (the
## Trash Printer, the Mud Printer, a designed gantry, anything tagged in
## Machine Setup). Load an STL and it is SLICED here (StlSlicer: walls,
## infill, top and bottom, spiral vase) at the machine's own line width and
## limits; load a G-code file and it runs as written; pick a part preset;
## or design a mud building. Either way the result is a PrintJob: the move
## list the planner (GantryLabMotion) times, played in the studio with the
## Simulate tab's own transport (play, scrub, speed, the HUD), ghosted on
## the real machine's bed in the world, exportable as G-code, and started on
## the world clock — where the machine runs exactly this plan.
##
## Layout: slicer sidebar on the left, the studio (bed, roads, nozzle) in
## the middle with the transport under it.
##
## Slicing runs on a worker thread (a large lattice is seconds of work and
## millions of moves): the old job stays on screen until the new one lands,
## a change mid-slice cancels it and starts again, and closing waits for it.
## The studio draws work space RIGHT-HANDED (work +Y away from the camera's
## default side, PrintRoads.work_basis), the same frame the model ghost is in
## — they used to be mirror images, turning opposite ways with the Turn.

const MODAL_NAME := "print_setup"
const PRINTS_DIR := "user://machines/prints"
const GCODE_DIR := "user://machines/gcode"
const SPEEDS := [0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 100.0]
const SLICE_DEBOUNCE_S := 0.3

var _runtime: Node = null
var _item_id: String = ""
var _view: Node = null
var _specs: Dictionary = {}
var _caps: FdmPrinterCaps = null
var _additive := true
var _part_id := ""
var _part_label := ""

## The source: an STL (sliced here) or a G-code text (run as written).
var _source_kind := ""             # "stl" | "gcode"
var _source_path := ""
var _source_name := ""
var _tris: Array = []
var _mesh: ArrayMesh = null
var _gcode_text := ""
var _parse: Dictionary = {}
var _job: Dictionary = {}
var _player: PrintJobPlayer = null
var _slice_timer := -1.0
## The worker slice: its task, its result, progress (0..1, written by the
## worker), a cancel flag the slicer polls, and "settings changed meanwhile".
var _task_id := -1
var _task_out: Dictionary = {}
var _slice_progress := 0.0
var _slice_cancel := false
var _slice_again := false
var _slice_t0 := 0
## The model's own size in its file (mm, X / Y / Z), for the size row.
var _native := Vector3.ZERO
var _size_spins: Array = []
var _size_lock := false

var _built := false
var _title: Label = null
var _preset: OptionButton = null
var _preset_row: Control = null
var _design_btn: Button = null
var _offx: HSlider = null
var _offy: HSlider = null
var _scale: HSlider = null
var _rot: HSlider = null
var _mode: OptionButton = null
var _nozzle: HSlider = null
var _wall: HSlider = null
var _layer: HSlider = null
var _walls: HSlider = null
var _infill: HSlider = null
var _pattern: OptionButton = null
var _top: HSlider = null
var _bottom: HSlider = null
var _speed: HSlider = null
var _travel: HSlider = null
var _hop: HSlider = null
var _slicer_box: VBoxContainer = null
var _spin_for := {}
var _wet_btn: ColorPickerButton = null
var _dry_btn: ColorPickerButton = null
var _wet_lbl: Label = null
var _dry_lbl: Label = null
var _status: Label = null
var _est_lbl: Label = null
var _machine_lbl: Label = null
var _start_btn: Button = null
var _export_btn: Button = null
var _file_dialog: FileDialog = null
var _gcode_dialog: FileDialog = null
var _save_dialog: FileDialog = null
var _presets: Array = []

## Studio.
var _vpc: SubViewportContainer = null
var _vp: SubViewport = null
var _holder: Node3D = null
var _camera: Camera3D = null
var _bed_mi: MeshInstance3D = null
var _ghost_mi: MeshInstance3D = null
var _roads: PrintRoads = null
var _nozzle_mi: MeshInstance3D = null
var _yaw := 0.55
var _pitch := 0.42
var _dist := 0.6
var _cam_target := Vector3(0, 0.05, 0)
var _orbiting := false
var _panning := false
var _show_model := true
var _model_chk: CheckButton = null

## Transport.
var _play_btn: Button = null
var _speed_opt: OptionButton = null
var _scrub: HSlider = null
var _hud: Label = null
var _sim_t := 0.0
var _sim_playing := false
var _sim_speed := 1.0
var _suppress := false

## Last-used settings per printer (session cache), keyed by item id.
var _last_settings: Dictionary = {}


func open(runtime: Node, item_id: String, view: Node, specs: Dictionary) -> void:
	_runtime = runtime
	_item_id = item_id
	_view = view
	_specs = specs.duplicate(true)
	if _last_settings.has(item_id):
		_specs.merge(_last_settings[item_id] as Dictionary, true)
	_caps = FdmPrinterCaps.from_specs(_specs)
	_additive = str(_specs.get("machine_role", "fdm_printer")) == "fdm_printer"
	if _runtime != null and is_instance_valid(_runtime) and _runtime.has_method("set_meta"):
		_runtime.set_meta("fdm_bed_lowering", _caps.is_bed_lowering())
	_part_id = str(_specs.get("job_part_id", ""))
	_part_label = str(_specs.get("job_part_label", ""))
	if not _built:
		_build_ui()
		_built = true
	_apply_caps_chrome()
	_reset_from_specs()
	_sim_t = 0.0
	_sim_playing = false
	if _play_btn != null:
		_play_btn.text = "Play"
	visible = true
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	if _job.is_empty():
		_status.text = "Load an STL to slice it, or a G-code file to run it as written."


func close() -> void:
	_stop_slice()
	_snapshot_settings()
	visible = false
	set_process(false)
	_sim_playing = false
	if _runtime != null and is_instance_valid(_runtime) and _runtime.has_method("clear_print_preview"):
		_runtime.call("clear_print_preview")
	CursorController.release_modal(MODAL_NAME)


func is_open() -> bool:
	return visible


func _exit_tree() -> void:
	_stop_slice()


## Cancel a running slice and wait for the worker (a task is always waited on).
func _stop_slice() -> void:
	_slice_again = false
	if _task_id >= 0:
		_slice_cancel = true
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	_slice_cancel = false


func _snapshot_settings() -> void:
	if _item_id.is_empty() or not _built or _caps == null:
		return
	_last_settings[_item_id] = {
		"print_offset_x": float(_offx.value), "print_offset_y": float(_offy.value),
		"print_scale": float(_scale.value), "print_rotation_deg": float(_rot.value),
		"print_mode": "vase" if _mode.selected == 1 else "solid",
		"nozzle_diameter_mm": float(_nozzle.value), "filament_diameter_mm": float(_nozzle.value),
		"line_width_mm": float(_wall.value), "layer_height_mm": float(_layer.value),
		"walls": int(_walls.value), "infill_pct": float(_infill.value),
		"infill_pattern": "grid" if _pattern.selected == 1 else "lines",
		"top_layers": int(_top.value), "bottom_layers": int(_bottom.value),
		"print_speed_mm_s": float(_speed.value), "travel_speed_mm_s": float(_travel.value),
		"z_hop_mm": float(_hop.value),
		"wet_color": [_wet_btn.color.r, _wet_btn.color.g, _wet_btn.color.b],
		"dry_color": [_dry_btn.color.r, _dry_btn.color.g, _dry_btn.color.b],
	}


func _process(delta: float) -> void:
	if not visible:
		return
	_update_camera()
	if _slice_timer >= 0.0:
		_slice_timer -= delta
		if _slice_timer < 0.0:
			_slice_timer = -1.0
			_reslice()
	_poll_slice()
	if _sim_playing and _player != null and _player.is_loaded():
		_sim_t += delta * _sim_speed
		if _sim_t >= _player.total_s:
			_sim_t = _player.total_s
			_sim_playing = false
			_play_btn.text = "Play"
		_apply_sim_time()


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16
	root.offset_top = 16
	root.offset_right = -16
	root.offset_bottom = -16
	root.add_theme_constant_override("separation", 12)
	add_child(root)
	root.add_child(_build_sidebar())
	root.add_child(_build_studio_panel())


func _apply_caps_chrome() -> void:
	if _caps == null:
		return
	_title.text = "%s — print setup" % _caps.display_name
	_preset_row.visible = _caps.show_part_presets
	_design_btn.visible = _caps.show_design_building
	_wet_lbl.text = _caps.wet_label
	_dry_lbl.text = _caps.dry_label
	_set_range(_nozzle, _caps.nozzle_lo, _caps.nozzle_hi)
	_set_range(_wall, _caps.wall_lo, _caps.wall_hi)
	_set_range(_layer, _caps.layer_lo, _caps.layer_hi)
	_set_range(_speed, _caps.speed_lo, _caps.speed_hi)
	_set_range(_travel, _caps.speed_lo, _caps.speed_hi * 3.0)
	_set_range(_scale, _caps.scale_lo, _caps.scale_hi)
	_scale.exp_edit = true
	_set_range(_offx, -_caps.work_x_mm * 0.5, _caps.work_x_mm * 0.5)
	_set_range(_offy, -_caps.work_y_mm * 0.5, _caps.work_y_mm * 0.5)
	_set_range(_hop, 0.0, maxf(_caps.layer_hi * 4.0, 2.0))
	var lim := PrintJob.limits_for_specs(_specs)
	_machine_lbl.text = "Bed %.0f × %.0f × %.0f mm · max %.0f mm/s · %.0f mm/s² · jerk %.1f mm/s" % [
		_caps.work_x_mm, _caps.work_y_mm, _caps.work_z_mm, float(lim.get("max_feed_mm_s", 0.0)),
		float(lim.get("accel_mm_s2", 0.0)), float(lim.get("junction_mm_s", 0.0))]
	_rebuild_bed_plane()
	if _caps.show_part_presets:
		_rebuild_preset_menu()


func _build_sidebar() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	var scroll := ScrollContainer.new()
	panel.add_child(scroll)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.custom_minimum_size = Vector2(356, 0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)

	_title = Label.new()
	_title.text = "Printer — print setup"
	_title.add_theme_font_size_override("font_size", 18)
	v.add_child(_title)
	_machine_lbl = Label.new()
	_machine_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_machine_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_machine_lbl.modulate = Color(0.7, 0.75, 0.82)
	v.add_child(_machine_lbl)

	v.add_child(SectionHeader.make("Part", "box"))
	_preset_row = HBoxContainer.new()
	var preset_cap := Label.new()
	preset_cap.text = "Preset"
	preset_cap.custom_minimum_size = Vector2(110, 0)
	_preset_row.add_child(preset_cap)
	_preset = OptionButton.new()
	_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset.item_selected.connect(_on_preset_selected)
	_preset_row.add_child(_preset)
	v.add_child(_preset_row)
	var load_row := HFlowContainer.new()
	load_row.add_theme_constant_override("h_separation", 6)
	var load_btn := Button.new()
	load_btn.text = "Load STL…"
	load_btn.tooltip_text = "Slice a mesh here: walls, infill, top and bottom layers at this machine's line width"
	UITheme.style_button(load_btn)
	load_btn.pressed.connect(_on_load_pressed)
	load_row.add_child(load_btn)
	var gcode_btn := Button.new()
	gcode_btn.text = "Load G-code…"
	gcode_btn.tooltip_text = "Run a program from any slicer or CAM tool as written"
	UITheme.style_button(gcode_btn)
	gcode_btn.pressed.connect(_on_load_gcode_pressed)
	load_row.add_child(gcode_btn)
	_design_btn = Button.new()
	_design_btn.text = "Design building…"
	_design_btn.tooltip_text = "Sketch wall plans and print dual-perimeter mud walls (no STL needed)"
	UITheme.style_button(_design_btn)
	_design_btn.pressed.connect(_on_design_building_pressed)
	load_row.add_child(_design_btn)
	v.add_child(load_row)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	v.add_child(_status)
	_est_lbl = Label.new()
	_est_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_est_lbl.add_theme_font_override("font", UITheme.font("regular", true))
	_est_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	v.add_child(_est_lbl)

	_slicer_box = VBoxContainer.new()
	_slicer_box.add_theme_constant_override("separation", 6)
	v.add_child(_slicer_box)
	var sb := _slicer_box
	sb.add_child(SectionHeader.make("Placement", "move"))
	_offx = _slider_row(sb, "Offset X (mm)", -300.0, 300.0, 1.0, 0.0)
	_offy = _slider_row(sb, "Offset Y (mm)", -300.0, 300.0, 1.0, 0.0)
	_scale = _slider_row(sb, "Scale", 0.001, 1000.0, 0.001, 1.0)
	_scale.exp_edit = true
	_scale.tooltip_text = "Any scale: type it, or set a size below"
	_scale.value_changed.connect(func(_v): _sync_size())
	_build_size_row(sb)
	_rot = _slider_row(sb, "Turn (°)", -180.0, 180.0, 1.0, 0.0)
	sb.add_child(SectionHeader.make("Slicer", "layers"))
	var mode_row := HBoxContainer.new()
	var mode_cap := Label.new()
	mode_cap.text = "Mode"
	mode_cap.custom_minimum_size = Vector2(110, 0)
	mode_row.add_child(mode_cap)
	_mode = OptionButton.new()
	_mode.add_item("Solid (walls + infill)", 0)
	_mode.add_item("Spiral vase (one wall, no infill)", 1)
	_mode.select(0)
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode.item_selected.connect(func(_i): _on_slicer_changed())
	mode_row.add_child(_mode)
	sb.add_child(mode_row)
	_nozzle = _slider_row(sb, "Nozzle (mm)", 0.2, 150.0, 0.1, 0.4)
	_wall = _slider_row(sb, "Line width (mm)", 0.2, 200.0, 0.05, 0.45)
	_layer = _slider_row(sb, "Layer height (mm)", 0.05, 100.0, 0.05, 0.2)
	_walls = _slider_row(sb, "Walls", 1, 8, 1, 2)
	_infill = _slider_row(sb, "Infill (%)", 0.0, 100.0, 1.0, 20.0)
	var pat_row := HBoxContainer.new()
	var pat_cap := Label.new()
	pat_cap.text = "Infill pattern"
	pat_cap.custom_minimum_size = Vector2(110, 0)
	pat_row.add_child(pat_cap)
	_pattern = OptionButton.new()
	_pattern.add_item("Lines (±45°, a quarter turn a layer)", 0)
	_pattern.add_item("Grid (both ways every layer)", 1)
	_pattern.select(0)
	_pattern.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pattern.item_selected.connect(func(_i): _on_slicer_changed())
	pat_row.add_child(_pattern)
	sb.add_child(pat_row)
	_top = _slider_row(sb, "Top layers", 0, 12, 1, 3)
	_bottom = _slider_row(sb, "Bottom layers", 0, 12, 1, 3)
	_speed = _slider_row(sb, "Print speed (mm/s)", 5.0, 600.0, 1.0, 50.0)
	_travel = _slider_row(sb, "Travel speed (mm/s)", 5.0, 1000.0, 1.0, 120.0)
	_hop = _slider_row(sb, "Z hop on travel (mm)", 0.0, 10.0, 0.1, 0.0)
	_nozzle.value_changed.connect(_on_nozzle_changed)
	for s in [_wall, _layer, _walls, _infill, _top, _bottom, _speed, _travel, _hop, _scale, _rot, _offx, _offy]:
		(s as HSlider).value_changed.connect(func(_v): _on_slicer_changed())

	v.add_child(SectionHeader.make("Look", "droplet"))
	var wet_row := HBoxContainer.new()
	_wet_lbl = Label.new()
	_wet_lbl.text = "Filament color"
	_wet_lbl.custom_minimum_size = Vector2(110, 0)
	wet_row.add_child(_wet_lbl)
	_wet_btn = ColorPickerButton.new()
	_wet_btn.custom_minimum_size = Vector2(120, 28)
	_wet_btn.color = Color(0.85, 0.55, 0.20)
	_wet_btn.color_changed.connect(func(_c): _relay_roads())
	wet_row.add_child(_wet_btn)
	v.add_child(wet_row)
	var dry_row := HBoxContainer.new()
	_dry_lbl = Label.new()
	_dry_lbl.text = "Finished color"
	_dry_lbl.custom_minimum_size = Vector2(110, 0)
	dry_row.add_child(_dry_lbl)
	_dry_btn = ColorPickerButton.new()
	_dry_btn.custom_minimum_size = Vector2(120, 28)
	_dry_btn.color = Color(0.35, 0.55, 0.65)
	_dry_btn.color_changed.connect(func(_c): _relay_roads())
	dry_row.add_child(_dry_btn)
	v.add_child(dry_row)

	v.add_child(HSeparator.new())
	var btns := HFlowContainer.new()
	btns.add_theme_constant_override("h_separation", 8)
	_start_btn = Button.new()
	_start_btn.text = "Start print"
	_start_btn.tooltip_text = "Schedule this job on the world clock: the machine runs the planned motion, draws feedstock and power on the graph"
	UITheme.style_button(_start_btn)
	_start_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	_start_btn.pressed.connect(_on_start_pressed)
	btns.add_child(_start_btn)
	_export_btn = Button.new()
	_export_btn.text = "Export G-code…"
	_export_btn.tooltip_text = "Write the sliced program for a real printer (RepRap / Marlin E words, or the mud printer's GRBL relay dialect)"
	UITheme.style_button(_export_btn)
	_export_btn.pressed.connect(_on_export_pressed)
	btns.add_child(_export_btn)
	var cancel := Button.new()
	cancel.text = "Close"
	UITheme.style_button(cancel)
	cancel.pressed.connect(close)
	btns.add_child(cancel)
	v.add_child(btns)
	return panel


func _build_studio_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.35
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	var v := VBoxContainer.new()
	panel.add_child(v)
	var cap := HBoxContainer.new()
	var cap_lbl := Label.new()
	cap_lbl.text = "Bed — RMB orbit · MMB / Shift+drag pan · wheel zoom · the ghost on the real machine follows"
	cap_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	cap_lbl.modulate = Color(0.7, 0.75, 0.82)
	cap_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cap_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cap.add_child(cap_lbl)
	_model_chk = CheckButton.new()
	_model_chk.text = "Model"
	_model_chk.button_pressed = true
	_model_chk.focus_mode = Control.FOCUS_NONE
	_model_chk.toggled.connect(func(p: bool):
		_show_model = p
		if _ghost_mi != null:
			_ghost_mi.visible = p)
	cap.add_child(_model_chk)
	v.add_child(cap)

	var vpc := SubViewportContainer.new()
	vpc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc.stretch = true
	vpc.custom_minimum_size = Vector2(480, 320)
	vpc.mouse_filter = Control.MOUSE_FILTER_STOP
	vpc.gui_input.connect(_on_preview_input)
	vpc.resized.connect(_update_viewport_size)
	_vpc = vpc
	v.add_child(vpc)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_vp.size = Vector2i(720, 600)
	_vp.msaa_3d = Viewport.MSAA_4X
	vpc.add_child(_vp)
	var world := Node3D.new()
	_vp.add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.30, 0.33, 0.38)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.52, 0.56, 0.63)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	env.ssao_radius = 0.25
	env.ssao_intensity = 1.2
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	world.add_child(world_env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-42, 38, 0)
	light.light_energy = 1.35
	light.light_color = Color(1.0, 0.93, 0.82)
	light.shadow_enabled = true
	world.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, -135, 0)
	fill.light_energy = 0.34
	world.add_child(fill)
	_holder = Node3D.new()
	world.add_child(_holder)
	_camera = Camera3D.new()
	_camera.fov = 42.0
	_camera.current = true
	world.add_child(_camera)
	_nozzle_mi = MeshInstance3D.new()
	_nozzle_mi.name = "Nozzle"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.006
	cone.bottom_radius = 0.0015
	cone.height = 0.02
	_nozzle_mi.mesh = cone
	var nmat := StandardMaterial3D.new()
	nmat.albedo_color = Color(0.85, 0.3, 0.25)
	nmat.emission_enabled = true
	nmat.emission = Color(0.85, 0.3, 0.25)
	nmat.emission_energy_multiplier = 0.6
	_nozzle_mi.material_override = nmat
	_nozzle_mi.visible = false
	_holder.add_child(_nozzle_mi)

	# Transport.
	var tr := HBoxContainer.new()
	tr.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_play_btn = Button.new()
	_play_btn.text = "Play"
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
	_scrub = HSlider.new()
	_scrub.min_value = 0.0
	_scrub.max_value = 1.0
	_scrub.step = 0.0005
	_scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrub.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scrub.value_changed.connect(func(val):
		if _player != null and _player.is_loaded() and not _suppress:
			_sim_t = val * _player.total_s
			_apply_sim_time())
	tr.add_child(_scrub)
	v.add_child(tr)
	_hud = Label.new()
	_hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud.custom_minimum_size = Vector2(0, 64)
	_hud.add_theme_font_override("font", UITheme.font("regular", true))
	_hud.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hud.add_theme_color_override("font_color", UITheme.C_TEXT)
	v.add_child(_hud)
	return panel


func _rebuild_bed_plane() -> void:
	if _holder == null or _caps == null:
		return
	if _bed_mi != null and is_instance_valid(_bed_mi):
		_bed_mi.queue_free()
	_bed_mi = null
	var mi := MeshInstance3D.new()
	mi.name = "BedPlane"
	var plane := PlaneMesh.new()
	plane.size = Vector2(_caps.work_x_mm, _caps.work_y_mm) * 0.001
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.24, 0.28, 0.92)
	mat.roughness = 0.85
	mat.metallic = 0.15
	mi.material_override = mat
	mi.position = Vector3(0, -0.001, 0)
	_holder.add_child(mi)
	_holder.move_child(mi, 0)
	_bed_mi = mi
	if _job.is_empty():
		_cam_target = Vector3.ZERO
		_dist = clampf(maxf(_caps.work_x_mm, _caps.work_y_mm) * 0.001 * 1.4, 0.15, 12.0)


## Width / depth / height of the print (mm): type any one and the scale
## follows, the other two with it (a uniform scale); "1:1" and "Fit bed".
func _build_size_row(parent: VBoxContainer) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	var lbl := Label.new()
	lbl.text = "Size (mm)"
	lbl.custom_minimum_size = Vector2(110, 0)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	lbl.tooltip_text = "The model's width (X), depth (Y) and height (Z) as printed, before the turn. Type one and the scale follows."
	h.add_child(lbl)
	_size_spins = []
	for axis in 3:
		var sp := SpinBox.new()
		sp.min_value = 0.01
		sp.max_value = 1.0e6
		sp.step = 0.1
		sp.allow_greater = true
		sp.prefix = ["W", "D", "H"][axis]
		sp.custom_minimum_size = Vector2(78, 0)
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp.tooltip_text = ["Width along the bed's X", "Depth along the bed's Y", "Height"][axis]
		sp.value_changed.connect(_on_size_typed.bind(axis))
		h.add_child(sp)
		_size_spins.append(sp)
	parent.add_child(h)
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", 6)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(110, 0)
	b.add_child(pad)
	var one := Button.new()
	one.text = "1:1"
	one.tooltip_text = "The size in the file (scale 1)"
	UITheme.style_button(one)
	one.pressed.connect(func():
		_set_slider(_scale, 1.0)
		_sync_size()
		_on_slicer_changed())
	b.add_child(one)
	var fit := Button.new()
	fit.text = "Fit bed"
	fit.tooltip_text = "The largest size that fits this machine's work volume"
	UITheme.style_button(fit)
	fit.pressed.connect(func():
		_set_slider(_scale, clampf(_fit_scale() * 0.98, _scale.min_value, _scale.max_value))
		_sync_size()
		_on_slicer_changed())
	b.add_child(fit)
	parent.add_child(b)


func _on_size_typed(v: float, axis: int) -> void:
	if _size_lock or _native[axis] <= 1e-6:
		return
	_set_slider(_scale, clampf(v / _native[axis], _scale.min_value, _scale.max_value))
	_sync_size()
	_on_slicer_changed()


## The size row from the scale (no signals).
func _sync_size() -> void:
	if _size_spins.is_empty():
		return
	_size_lock = true
	var sc := float(_scale.value)
	for axis in 3:
		var sp: SpinBox = _size_spins[axis]
		sp.set_value_no_signal(_native[axis] * sc)
		sp.editable = _native[axis] > 1e-6
	_size_lock = false


## The largest scale at which the model's own box fits the work volume.
func _fit_scale() -> float:
	if _caps == null or _native.x <= 1e-6:
		return 1.0
	return minf(minf(_caps.work_x_mm / maxf(_native.x, 1e-3), _caps.work_y_mm / maxf(_native.y, 1e-3)),
		_caps.work_z_mm / maxf(_native.z, 1e-3))


func _slider_row(parent: VBoxContainer, label: String, lo: float, hi: float, step: float, val: float) -> HSlider:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(110, 0)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	h.add_child(lbl)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(120, 0)
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = step
	sb.value = val
	sb.custom_minimum_size = Vector2(84, 0)
	s.value_changed.connect(func(vv: float): sb.set_value_no_signal(vv))
	sb.value_changed.connect(func(vv: float): s.set_value(vv))
	h.add_child(s)
	h.add_child(sb)
	parent.add_child(h)
	_spin_for[s] = sb
	return s


func _set_slider(slider: HSlider, val: float) -> void:
	if slider == null:
		return
	slider.set_value_no_signal(val)
	var sb: SpinBox = _spin_for.get(slider)
	if sb != null:
		sb.set_value_no_signal(val)


func _set_range(slider: HSlider, lo: float, hi: float) -> void:
	if slider == null:
		return
	slider.min_value = lo
	slider.max_value = hi
	var sb: SpinBox = _spin_for.get(slider)
	if sb != null:
		sb.min_value = lo
		sb.max_value = hi


func _reset_from_specs() -> void:
	if _caps == null:
		return
	_set_slider(_offx, float(_specs.get("print_offset_x", 0.0)))
	_set_slider(_offy, float(_specs.get("print_offset_y", 0.0)))
	_set_slider(_scale, clampf(float(_specs.get("print_scale", 1.0)), _scale.min_value, _scale.max_value))
	_sync_size()
	_set_slider(_rot, float(_specs.get("print_rotation_deg", 0.0)))
	_mode.select(1 if str(_specs.get("print_mode", _caps.default_print_mode)) == "vase" else 0)
	_set_slider(_nozzle, _caps.nozzle_mm)
	_set_slider(_wall, _caps.line_width_mm)
	_set_slider(_layer, _caps.layer_height_mm)
	_set_slider(_walls, float(_specs.get("walls", 2)))
	_set_slider(_infill, float(_specs.get("infill_pct", 20.0)))
	_pattern.select(1 if str(_specs.get("infill_pattern", "lines")) == "grid" else 0)
	_set_slider(_top, float(_specs.get("top_layers", 3)))
	_set_slider(_bottom, float(_specs.get("bottom_layers", 3)))
	_set_slider(_speed, _caps.print_speed_mm_s)
	_set_slider(_travel, clampf(float(_specs.get("travel_speed_mm_s", _caps.print_speed_mm_s * 2.5)), _travel.min_value, _travel.max_value))
	_set_slider(_hop, float(_specs.get("z_hop_mm", 0.0)))
	_wet_btn.color = _caps.wet_color
	_dry_btn.color = _caps.dry_color


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

func _rebuild_preset_menu() -> void:
	_presets = _caps.part_presets()
	_preset.clear()
	_preset.add_item("— custom (loaded file) —", 0)
	for i in _presets.size():
		var p: Dictionary = _presets[i]
		_preset.add_item(str(p.get("label", p.get("part_id", "part"))), i + 1)
	_preset.select(0)


func _on_preset_selected(idx: int) -> void:
	if idx <= 0 or idx - 1 >= _presets.size():
		return
	var p: Dictionary = _presets[idx - 1]
	_part_id = str(p.get("part_id", ""))
	_part_label = str(p.get("label", _part_id))
	var path := str(p.get("stl_path", ""))
	if path.is_empty() and DomeParts.STL.has(_part_id):
		path = str(DomeParts.STL[_part_id])
	if path.is_empty():
		_status.text = "Preset has no STL."
		return
	_set_slider(_scale, clampf(float(p.get("scale", 1.0)), _scale.min_value, _scale.max_value))
	_load_stl_path(path, false)


func _on_load_pressed() -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.filters = PackedStringArray(["*.stl ; STL mesh"])
		_file_dialog.use_native_dialog = true
		_file_dialog.file_selected.connect(_on_file_selected)
		add_child(_file_dialog)
	_file_dialog.popup_centered(Vector2i(900, 640))


func _on_load_gcode_pressed() -> void:
	if _gcode_dialog == null:
		_gcode_dialog = FileDialog.new()
		_gcode_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_gcode_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_gcode_dialog.filters = PackedStringArray(["*.gcode, *.gco, *.g, *.nc, *.ngc, *.tap ; G-code"])
		_gcode_dialog.use_native_dialog = true
		_gcode_dialog.file_selected.connect(_on_gcode_file_selected)
		add_child(_gcode_dialog)
	_gcode_dialog.popup_centered(Vector2i(900, 640))


func _on_design_building_pressed() -> void:
	if _caps == null or not _caps.show_design_building:
		return
	if _view != null and _view.has_method("open_mud_building_designer"):
		close()
		_view.call("open_mud_building_designer", _item_id)
	else:
		_status.text = "Mud Building Designer unavailable."


func _on_file_selected(path: String) -> void:
	if _preset != null:
		_preset.select(0)
	_part_id = ""
	_part_label = ""
	_load_stl_path(path, true)


func _load_stl_path(path: String, auto_fit: bool) -> void:
	var tris := StlLoader.load_triangles(path)
	if tris.is_empty():
		_status.text = "Could not read %s." % path.get_file()
		return
	_tris = tris
	_mesh = StlLoader.build_mesh(path)
	_source_kind = "stl"
	_source_path = path
	_source_name = path.get_file().get_basename()
	_gcode_text = ""
	_slicer_box.visible = true
	_native = Vector3.ZERO
	if _mesh != null:
		# build_mesh is Y-up in metres: X, Z, Y back to the file's X, Y, Z mm.
		var a := _mesh.get_aabb().size * 1000.0
		_native = Vector3(a.x, a.z, a.y)
	if auto_fit and _caps != null and _mesh != null:
		_set_slider(_scale, clampf(minf(_fit_scale() * 0.8, 1.0), _scale.min_value, _scale.max_value))
	_sync_size()
	_reslice()


func _on_gcode_file_selected(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_status.text = "Could not read %s." % path.get_file()
		return
	_gcode_text = f.get_as_text()
	f.close()
	if _preset != null:
		_preset.select(0)
	_part_id = ""
	_part_label = ""
	_tris = []
	_mesh = null
	_source_kind = "gcode"
	_source_path = path
	_source_name = path.get_file().get_basename()
	_slicer_box.visible = false
	_reslice()


func _on_nozzle_changed(v: float) -> void:
	if _caps == null:
		return
	_set_slider(_wall, clampf(v * 1.1, _wall.min_value, _wall.max_value))
	_set_slider(_layer, _caps.suggested_layer_for_nozzle(v))
	_on_slicer_changed()


func _on_slicer_changed() -> void:
	if _source_kind == "stl":
		_slice_timer = SLICE_DEBOUNCE_S
		_status.text = "Slicing…"


func _slicer_settings() -> Dictionary:
	return {
		"layer_height_mm": float(_layer.value), "line_width_mm": float(_wall.value),
		"walls": int(_walls.value), "infill_pct": float(_infill.value),
		"infill_pattern": "grid" if _pattern.selected == 1 else "lines",
		"top_layers": int(_top.value), "bottom_layers": int(_bottom.value),
		"mode": "vase" if _mode.selected == 1 else "solid",
		"print_speed_mm_s": float(_speed.value), "travel_speed_mm_s": float(_travel.value),
		"scale": float(_scale.value), "rotation_deg": float(_rot.value),
		"centre_xy": _caps.bed_centre_mm() + Vector2(float(_offx.value), float(_offy.value)),
		"z_hop_mm": float(_hop.value), "filament_mm": float(_nozzle.value),
		"progress": Callable(self, "_on_slice_progress"), "cancel": Callable(self, "_is_slice_cancelled"),
	}


func _on_slice_progress(f: float) -> void:
	_slice_progress = f


func _is_slice_cancelled() -> bool:
	return _slice_cancel


## Slice (or parse) the source into a job on a worker thread; the result is
## planned there too and laid in the studio when it lands (_poll_slice).
func _reslice() -> void:
	if _task_id >= 0:
		# A slice is running on old settings: stop it, slice again after.
		_slice_again = true
		_slice_cancel = true
		return
	_slice_again = false
	_slice_cancel = false
	var has_src := (_source_kind == "stl" and not _tris.is_empty()) or (_source_kind == "gcode" and not _gcode_text.is_empty())
	if not has_src:
		_job = {}
		_player = null
		_parse = {}
		_lay_studio()
		return
	var specs := _specs.duplicate()
	specs["filament_diameter_mm"] = float(_nozzle.value)
	# Limits on this thread: a designed gantry's come from GantryLabDesign's
	# cache, which the main thread also writes.
	var opts := {"name": _source_name, "limits": PrintJob.limits_for_specs(specs)}
	if _source_kind == "gcode":
		opts["line_width_mm"] = maxf(float(_wall.value), 0.05)
	var inp := {"kind": _source_kind, "tris": _tris, "text": _gcode_text, "settings": _slicer_settings(),
		"specs": specs, "opts": opts, "name": _source_name}
	_task_out = {}
	_slice_progress = 0.0
	_slice_t0 = Time.get_ticks_msec()
	_status.text = "Slicing %s…" % _source_name
	_task_id = WorkerThreadPool.add_task(_slice_task.bind(inp), false, "print setup slice")


## On the worker: slice / parse, then plan. Touches nothing but its result.
func _slice_task(inp: Dictionary) -> void:
	var parse: Dictionary
	if str(inp["kind"]) == "stl":
		parse = StlSlicer.slice_triangles(inp["tris"], inp["settings"])
	else:
		parse = GantryLabGcode.parse(str(inp["text"]))
	var out := {"parse": parse}
	if bool(parse.get("ok", false)):
		parse["name"] = str(inp["name"])
		out["job"] = PrintJob.from_parse(parse, inp["specs"], inp["opts"])
	_task_out = out


## The worker's result, when it is in (each frame; or at once, blocking).
func _poll_slice(block: bool = false) -> void:
	if _task_id < 0:
		return
	if not block and not WorkerThreadPool.is_task_completed(_task_id):
		_status.text = "Slicing %s… %d %%" % [_source_name, int(_slice_progress * 100.0)]
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	if _slice_again:
		_reslice()
		if block:
			_poll_slice(true)
		return
	_apply_slice(_task_out)


func _apply_slice(out: Dictionary) -> void:
	var parse: Dictionary = out.get("parse", {})
	if bool(parse.get("cancelled", false)):
		return
	if not bool(parse.get("ok", false)):
		_status.text = ("Could not slice: %s" if _source_kind == "stl" else "No motion in " + _source_name + ": %s") % str(parse.get("error", "?"))
		return
	var job: Dictionary = out.get("job", {})
	if not bool(job.get("ok", false)):
		_status.text = str(job.get("error", "could not plan"))
		return
	_parse = parse
	_job = job
	var ms := Time.get_ticks_msec() - _slice_t0
	if _source_kind == "stl":
		_status.text = "%s · %s · sliced and planned in %s" % [_source_name, UiText.count(int(_parse.get("triangles", 0)), "triangle"), GantryLabMotion.fmt_duration(float(ms) / 1000.0)]
	else:
		_status.text = "%s · %s · %s dialect · run as written" % [_source_name, UiText.count(int(_parse.get("lines", 0)), "line"), str(_parse.get("dialect", "reprap"))]
	_player = PrintJobPlayer.new()
	_player.set_job(_job)
	_refresh_estimate()
	_lay_studio()
	# A fresh slice shows the whole print on the plate (Play starts it over);
	# a scrubbed position is kept across re-slices.
	if _sim_t <= 0.0 and not _sim_playing:
		_sim_t = _player.total_s
	_sim_t = clampf(_sim_t, 0.0, _player.total_s)
	_apply_sim_time()
	if _runtime != null and is_instance_valid(_runtime) and _runtime.has_method("begin_print_preview"):
		_runtime.call("begin_print_preview", _job, _wet_btn.color)


func _refresh_estimate() -> void:
	if _job.is_empty() or _player == null:
		_est_lbl.text = ""
		return
	var bmin: Vector3 = _job.get("bounds_min", Vector3.ZERO)
	var bmax: Vector3 = _job.get("bounds_max", Vector3.ZERO)
	var sz := bmax - bmin
	var kg := _player.material_kg(_specs)
	var mat_txt := ("%.0f g" % (kg * 1000.0)) if kg < 1.0 else ("%.2f kg" % kg)
	if _caps != null and _caps.print_persist:
		mat_txt = "%.1f L" % (float(_job.get("volume_mm3", 0.0)) / 1_000_000.0)
	var speed_factor := maxf(float(_specs.get("speed_factor", 1.0)), 0.05)
	var warn := ""
	for w in _job.get("warnings", []):
		warn += "\n⚠ %s" % str(w)
	var bed := _caps.bed_rect_mm()
	var fits := bmin.x >= bed.position.x - 0.5 and bmin.y >= bed.position.y - 0.5 and bmax.x <= bed.end.x + 0.5 and bmax.y <= bed.end.y + 0.5 and bmax.z <= _caps.work_z_mm + 0.5
	if _roads != null and _roads.is_merged():
		warn += "\n(drawn simplified: %s roads stand for its curves)" % UiText.thousands(_roads.road_count())
	_est_lbl.text = "%s · %s · %.0f × %.0f × %.0f mm%s\n%s of material · %s at 1×%s%s" % [
		UiText.count(int(_job.get("layers", 0)), "layer"), UiText.count(PrintMoves.count(_job["moves"]), "move"),
		sz.x, sz.y, sz.z, "" if fits else "  — OFF THE BED",
		mat_txt, GantryLabMotion.fmt_duration(_player.total_s),
		(" (%s on this machine)" % GantryLabMotion.fmt_duration(_player.total_s / speed_factor)) if absf(speed_factor - 1.0) > 0.01 else "",
		warn]


# ---------------------------------------------------------------------------
# Studio
# ---------------------------------------------------------------------------

func _lay_studio() -> void:
	if _holder == null:
		return
	if _ghost_mi != null and is_instance_valid(_ghost_mi):
		_ghost_mi.queue_free()
	_ghost_mi = null
	if _roads != null and is_instance_valid(_roads):
		_roads.queue_free()
	_roads = null
	_nozzle_mi.visible = false
	if _mesh != null and _source_kind == "stl" and _parse.has("place_xy"):
		_ghost_mi = MeshInstance3D.new()
		_ghost_mi.name = "ModelGhost"
		_ghost_mi.mesh = _mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.45, 0.9, 1.0, 0.18)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.no_depth_test = false
		_ghost_mi.material_override = mat
		# The scale and turn the slice ran with (the sliders may have moved on).
		var st: Dictionary = _parse.get("settings", {})
		var sc := maxf(float(st.get("scale", _scale.value)), 0.001)
		var rot := deg_to_rad(float(st.get("rotation_deg", _rot.value)))
		# The mesh is centred on its own box and seated on y = 0, in (x, z, −y)
		# (StlLoader.build_mesh); the slicer says where that centre landed.
		var place: Vector2 = _parse["place_xy"]
		var at := _work_to_studio(Vector3(place.x, place.y, 0.0))
		_ghost_mi.transform = Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * sc), at + Vector3(0.0, 0.0005, 0.0))
		_ghost_mi.visible = _show_model
		_holder.add_child(_ghost_mi)
	if _player != null and _player.is_loaded():
		_roads = PrintRoads.new()
		var mud := _caps != null and _caps.print_persist
		var col := _dry_btn.color if mud else _wet_btn.color
		var line := _player.line_mm * (1.12 if _source_kind == "gcode" else 1.0)
		_roads.lay(_player.moves(), line, _player.layer_mm, col, 0.45 if _caps != null and _caps.machine_kind == "trash" else 0.0, Vector3.ZERO)
		_roads.transform = _studio_work_xf()
		_holder.add_child(_roads)
		if mud:
			var w := _wet_btn.color
			var d := _dry_btn.color
			_roads.set_wet(Color(w.r / maxf(d.r, 0.01), w.g / maxf(d.g, 0.01), w.b / maxf(d.b, 0.01)), _player.line_mm * 60.0)
		_roads.show_all()
		_nozzle_mi.visible = true
		var box := _roads.transform * _roads.bounds_local()
		_cam_target = box.get_center()
		_dist = clampf(box.size.length() * 1.6, 0.12, 12.0)
	if _est_lbl != null and not _job.is_empty():
		_refresh_estimate()


## Work mm → the studio: the bed plane is centred on the studio origin and
## work +Y runs toward −Z (right-handed, as the model ghost is).
func _studio_work_xf() -> Transform3D:
	var mid := _caps.bed_rect_mm().get_center() if _caps != null else Vector2.ZERO
	return Transform3D(PrintRoads.work_basis(), Vector3(-mid.x, 0.0, mid.y) * 0.001)


func _work_to_studio(p: Vector3) -> Vector3:
	return _studio_work_xf() * (Vector3(p.x, p.z, p.y) * 0.001)


## A colour change recolours the roads (no re-lay: a large print is a
## million moves).
func _relay_roads() -> void:
	if _roads == null or not is_instance_valid(_roads):
		return
	var mud := _caps != null and _caps.print_persist
	_roads.set_base_color(_dry_btn.color if mud else _wet_btn.color)
	if mud:
		var w := _wet_btn.color
		var d := _dry_btn.color
		_roads.set_wet(Color(w.r / maxf(d.r, 0.01), w.g / maxf(d.g, 0.01), w.b / maxf(d.b, 0.01)), _player.line_mm * 60.0 if _player != null else 0.0)


func _on_play() -> void:
	if _player == null or not _player.is_loaded():
		return
	if _sim_t >= _player.total_s - 1e-6:
		_sim_t = 0.0
	_sim_playing = not _sim_playing
	_play_btn.text = "Pause" if _sim_playing else "Play"


func _apply_sim_time() -> void:
	if _player == null or not _player.is_loaded():
		_hud.text = ""
		return
	var total := _player.total_s
	var smp := _player.sample(_sim_t / maxf(total, 1e-6))
	var pos: Vector3 = smp["pos"]
	if _roads != null:
		_roads.set_progress_move(int(smp["i"]), float(smp["s"]))
	if _nozzle_mi != null:
		# A cone four lines tall, its tip at the nozzle.
		var sc := clampf(_player.line_mm / 0.4, 1.0, 60.0) * 0.35
		_nozzle_mi.scale = Vector3.ONE * sc
		_nozzle_mi.position = _work_to_studio(pos) + Vector3(0.0, 0.01 * sc, 0.0)
	_suppress = true
	_scrub.set_value_no_signal(_sim_t / maxf(total, 1e-6))
	_suppress = false
	if _runtime != null and is_instance_valid(_runtime) and _runtime.has_method("preview_tool_mm"):
		_runtime.call("preview_tool_mm", pos)
	var v := float(smp["v"])
	var what := "rapid" if bool(smp["rapid"]) else ("extruding" if bool(smp["extruding"]) else "feed")
	var layer := int(smp.get("layer", 0))
	var layers := int(smp.get("layers", 0))
	var plan: Dictionary = _player.plan
	_hud.text = "%s · %s of %s · move %d of %d\nX %.1f  Y %.1f  Z %.1f mm · %s %.0f mm/s (asked %.0f)%s\n%d %% of moves hit the feed cap, %d %% never reach it (too short for the acceleration)" % [
		_source_name, GantryLabMotion.fmt_duration(_sim_t), GantryLabMotion.fmt_duration(total), int(smp["i"]) + 1, int(plan.get("n", 0)),
		pos.x, pos.y, pos.z, what, v, float(smp["feed"]),
		(" · layer %d of %d" % [layer, layers]) if layers > 0 else "",
		int(100.0 * float(plan.get("max_feed_hit_share", 0.0))), int(100.0 * float(plan.get("accel_limited_share", 0.0)))]


func _update_viewport_size() -> void:
	if _vp == null or _vpc == null:
		return
	var sz := _vpc.size
	if sz.x < 2.0 or sz.y < 2.0:
		return
	var ss := 1.25
	_vp.size = Vector2i(clampi(int(sz.x * ss), 320, 2560), clampi(int(sz.y * ss), 320, 2560))


func _update_camera() -> void:
	if _camera == null:
		return
	var offset := Vector3(cos(_pitch) * sin(_yaw), sin(_pitch), cos(_pitch) * cos(_yaw)) * _dist
	_camera.global_position = _cam_target + offset
	_camera.look_at(_cam_target, Vector3.UP)
	_camera.near = clampf(_dist * 0.01, 0.0005, 0.1)
	_camera.far = maxf(_dist * 20.0, 50.0)


func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_LEFT:
			_orbiting = mb.pressed
			_panning = false
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_orbiting = false
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(_dist * 0.88, 0.02)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(_dist * 1.12, 20.0)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var rel := mm.relative
		if _panning or (_orbiting and mm.shift_pressed):
			var right := Vector3(cos(_yaw), 0, -sin(_yaw))
			var up := Vector3.UP
			var pan_scale := _dist * 0.0015
			_cam_target += (-right * rel.x + up * rel.y) * pan_scale
		elif _orbiting:
			_yaw -= rel.x * 0.01
			_pitch = clampf(_pitch + rel.y * 0.01, 0.05, 1.45)
	elif event is InputEventKey and (event as InputEventKey).pressed and (event as InputEventKey).keycode == KEY_SPACE:
		_on_play()


# ---------------------------------------------------------------------------
# Start, export
# ---------------------------------------------------------------------------

func _on_start_pressed() -> void:
	_finish_pending_slice()
	if _job.is_empty() or not bool(_job.get("ok", false)):
		_status.text = "Load an STL or a G-code file first."
		return
	if _view == null or not _view.has_method("start_machine_job") or _caps == null:
		return
	var stored := _copy_source_to_user()
	var wet := _wet_btn.color
	var dry := _dry_btn.color
	var kind := _caps.machine_kind if not _caps.machine_kind.is_empty() else "fdm"
	var job_name := _part_label if not _part_label.is_empty() else _source_name
	var part_id := _part_id
	if part_id.is_empty() and not _caps.print_persist:
		part_id = _source_name.to_snake_case()
	var extra := {
		"machine_kind": kind,
		"print_persist": _caps.print_persist,
		"bed_lowering": _caps.is_bed_lowering(),
		"print_mesh_path": stored if _source_kind == "stl" else "",
		"print_gcode_path": stored if _source_kind == "gcode" else "",
		"print_offset_x": float(_offx.value), "print_offset_y": float(_offy.value),
		"print_scale": float(_scale.value), "print_rotation_deg": float(_rot.value),
		"print_mode": "vase" if _mode.selected == 1 else "solid",
		"nozzle_diameter_mm": float(_nozzle.value), "filament_diameter_mm": float(_nozzle.value),
		"line_width_mm": float(_wall.value), "layer_height_mm": float(_layer.value),
		"walls": int(_walls.value), "infill_pct": float(_infill.value),
		"infill_pattern": "grid" if _pattern.selected == 1 else "lines",
		"top_layers": int(_top.value), "bottom_layers": int(_bottom.value),
		"print_speed_mm_s": float(_speed.value), "travel_speed_mm_s": float(_travel.value),
		"z_hop_mm": float(_hop.value),
		"wet_color": [wet.r, wet.g, wet.b], "dry_color": [dry.r, dry.g, dry.b],
		"job_part_id": part_id, "job_part_label": job_name, "job_part_count": 1,
		"job_material_kind": _caps.job_material_kind,
	}
	var fallback_id := "mud_print" if _caps.print_persist else "trash_print"
	var ok: bool = _view.call("start_machine_job", _item_id, _job,
		part_id if not part_id.is_empty() else fallback_id, job_name, 1, extra)
	if ok:
		close()
	else:
		_status.text = "Could not start the print (is one already running?)."


func _on_export_pressed() -> void:
	_finish_pending_slice()
	if _job.is_empty() or not bool(_job.get("ok", false)):
		_status.text = "Nothing to export yet."
		return
	if _save_dialog == null:
		_save_dialog = FileDialog.new()
		_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_save_dialog.filters = PackedStringArray(["*.gcode ; G-code"])
		_save_dialog.use_native_dialog = true
		_save_dialog.file_selected.connect(_on_export_path)
		add_child(_save_dialog)
	_save_dialog.current_file = "%s_%s.gcode" % [_source_name if not _source_name.is_empty() else "print", _caps.machine_kind]
	_save_dialog.popup_centered(Vector2i(900, 640))


func _on_export_path(path: String) -> void:
	var written := export_gcode(path)
	_status.text = ("Wrote %s" % path) if not written.is_empty() else "Could not write %s" % path


## The job as G-code at `path` (the mud printer's GRBL relay dialect, else
## RepRap with E words). Returns the path written or "".
func export_gcode(path: String) -> String:
	if _job.is_empty():
		return ""
	var mud := _caps != null and _caps.machine_kind == "mud"
	var opts := {
		"name": _source_name, "filament_mm": float(_nozzle.value),
		"dialect": "grbl_relay" if mud else "reprap",
		"travel_hop_mm": 15.0 if mud else 0.0,
		"park_z_mm": minf(float((_job["bounds_max"] as Vector3).z) + (50.0 if mud else 10.0), _caps.work_z_mm),
	}
	if not mud and _caps != null and _caps.machine_kind == "gantry":
		opts["hotend_c"] = 210.0
		opts["bed_c"] = 60.0
	return PrintGcodeWriter.write_file(_job["moves"], path, opts)


## A debounced or running slice, finished now (Start, Export, the harness).
func _finish_pending_slice() -> void:
	if _slice_timer >= 0.0:
		_slice_timer = -1.0
		_reslice()
	_poll_slice(true)


func _copy_source_to_user() -> String:
	if _source_path.is_empty():
		return ""
	var dir := PRINTS_DIR if _source_kind == "stl" else GCODE_DIR
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var id := "print_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	var dst := "%s/%s.%s" % [dir, id, _source_path.get_extension()]
	var fin := FileAccess.open(_source_path, FileAccess.READ)
	if fin == null:
		return _source_path
	var bytes := fin.get_buffer(fin.get_length())
	fin.close()
	var fout := FileAccess.open(dst, FileAccess.WRITE)
	if fout == null:
		return _source_path
	fout.store_buffer(bytes)
	fout.close()
	return dst


# ---------------------------------------------------------------------------
# For the harness and tests
# ---------------------------------------------------------------------------

func job() -> Dictionary:
	_finish_pending_slice()
	return _job


func load_stl(path: String) -> void:
	_load_stl_path(path, true)
	_finish_pending_slice()


func load_gcode_text(text: String, name: String = "program") -> void:
	_gcode_text = text
	_source_kind = "gcode"
	_source_path = ""
	_source_name = name
	_tris = []
	_mesh = null
	_slicer_box.visible = false
	_reslice()
	_finish_pending_slice()


func set_slicer(settings: Dictionary) -> void:
	if settings.has("layer_height_mm"):
		_set_slider(_layer, float(settings["layer_height_mm"]))
	if settings.has("line_width_mm"):
		_set_slider(_wall, float(settings["line_width_mm"]))
	if settings.has("infill_pct"):
		_set_slider(_infill, float(settings["infill_pct"]))
	if settings.has("walls"):
		_set_slider(_walls, float(settings["walls"]))
	if settings.has("scale"):
		_set_slider(_scale, float(settings["scale"]))
		_sync_size()
	if settings.has("width_mm") and _native.x > 1e-6:
		_set_slider(_scale, float(settings["width_mm"]) / _native.x)
		_sync_size()
	if settings.has("rotation_deg"):
		_set_slider(_rot, float(settings["rotation_deg"]))
	if settings.has("mode"):
		_mode.select(1 if str(settings["mode"]) == "vase" else 0)
	_reslice()
	_finish_pending_slice()


## For probes: the studio's work frame, the ghost and the roads.
func studio_state() -> Dictionary:
	return {"work_xf": _studio_work_xf(), "ghost": _ghost_mi, "roads": _roads, "scale": float(_scale.value),
		"size": Vector3(_native.x, _native.y, _native.z) * float(_scale.value), "native": _native,
		"parse": _parse, "scale_max": _scale.max_value}


func sim_seek(frac: float) -> void:
	if _player == null:
		return
	_sim_t = clampf(frac, 0.0, 1.0) * _player.total_s
	_apply_sim_time()


func sim_state() -> Dictionary:
	if _player == null or not _player.is_loaded():
		return {}
	var smp := _player.sample(_sim_t / maxf(_player.total_s, 1e-6))
	return {"t": _sim_t, "total_s": _player.total_s, "pos": smp["pos"], "v": smp["v"], "playing": _sim_playing,
		"moves": int(_player.plan.get("n", 0)), "extruding": bool(smp["extruding"]), "roads_shown": _roads.roads_shown() if _roads != null else 0}


func start_print() -> void:
	_on_start_pressed()
