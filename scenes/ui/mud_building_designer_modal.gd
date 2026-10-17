extends Control

## Phase D mud building designer: closed/open walls, bezier, gyroid fill,
## doorway lintels, camber, GRBL export, print or place-as-structure.

const MODAL_NAME := "mud_building_designer"
const REBUILD_DEBOUNCE_S := 0.12

var _view: Node = null
var _item_id: String = ""
var _runtime: CncMachineRuntime = null
var _specs: Dictionary = {}
var _spec: MudBuildingSpec = null
var _dialect: MudGrblDialect = null

var _built := false
var _canvas: MudPlanCanvas = null
var _status: Label = null
var _est_lbl: Label = null
var _height: SpinBox = null
var _thickness_base: SpinBox = null
var _thickness_top: SpinBox = null
var _shell_gap: SpinBox = null
var _layer: SpinBox = null
var _corner: SpinBox = null
var _fill_pitch: SpinBox = null
var _fill_enabled: CheckButton = null
var _fill_mode_btns: Array = []
var _fill_mode: int = MudBuildingSpec.FillMode.SINE
var _prelude_edit: TextEdit = null
var _epilogue_edit: TextEdit = null
var _export_dialog: FileDialog = null
var _camber_btns: Array = []
var _tool_btns: Array = []  # [{btn, tool_id}]

var _vp: SubViewport = null
var _vpc: SubViewportContainer = null
var _progress_row: Control = null
var _progress_bar: ProgressBar = null
var _progress_lbl: Label = null
var _progress_val := 0.0
var _build_running := false
var _build_task_id := -1
var _build_out: Dictionary = {}
var _rebuild_queued := false
var _view_toolpath := false
var _show_travels := true
var _travels_chk: CheckButton = null
var _layer_slider: HSlider = null
var _layer_lbl: Label = null
var _max_layer := 1_000_000
var _solid_mi: MeshInstance3D = null
var _path_mi: MeshInstance3D = null
var _holder: Node3D = null
var _camera: Camera3D = null
var _yaw := 0.55
var _pitch := 0.42
var _dist := 8.0
var _cam_target := Vector3(0, 1.0, 0)
var _orbiting := false
var _panning := false

var _rebuild_timer := 0.0
var _rebuild_pending := false
var _last_parse: Dictionary = {}
var _last_mesh: ArrayMesh = null
var _camber_mode: int = MudBuildingSpec.CamberMode.NONE
## Survives close/reopen so the designer remembers the last plan + wall settings.
var _session_spec: MudBuildingSpec = null
var _session_has_design := false
var _session_tool: int = MudPlanCanvas.Tool.RECT
var _session_corner_r := 200.0


func open(view: Node, item_id: String, runtime: CncMachineRuntime, specs: Dictionary) -> void:
	_view = view
	_item_id = item_id
	_runtime = runtime
	_specs = specs.duplicate(true)
	if _dialect == null:
		_dialect = MudGrblDialect.default_dialect()
	if not _built:
		_build_ui()
		_built = true
	if _session_has_design and _session_spec != null:
		_spec = _session_spec.duplicate_spec()
		# Refresh bed/nozzle from the bound printer without wiping the plan.
		var bed := MudBuildingSpec.from_printer_specs(_specs)
		_spec.nozzle_mm = bed.nozzle_mm
		_spec.line_width_mm = bed.line_width_mm
		_spec.work_x_mm = bed.work_x_mm
		_spec.work_y_mm = bed.work_y_mm
		_spec.work_z_mm = bed.work_z_mm
		_spec.print_speed_mm_s = bed.print_speed_mm_s
	else:
		_spec = MudBuildingSpec.from_printer_specs(_specs)
	_sync_sidebar_from_spec()
	_set_tool(_session_tool)
	if _canvas != null:
		_canvas.set_work(_spec.work_x_mm, _spec.work_y_mm, _spec.nozzle_mm)
		_canvas.corner_r_mm = _session_corner_r
		_canvas.loops.clear()
		_canvas.open_paths.clear()
		_canvas.selected_index = -1
		for loop: Variant in _spec.loops:
			if loop is PackedVector2Array:
				_canvas.loops.append((loop as PackedVector2Array).duplicate())
		for path: Variant in _spec.open_paths:
			if path is PackedVector2Array:
				_canvas.open_paths.append((path as PackedVector2Array).duplicate())
		if _canvas.loops.is_empty() and _canvas.open_paths.is_empty():
			# First open (or cleared session): seed a default room.
			var seed := MudBuildingSpec.make_rect(0.0, 0.0, 1800.0, 1400.0)
			var v := MudPlanOps.validate_loop(seed, _spec.nozzle_mm, _spec.work_x_mm, _spec.work_y_mm)
			if bool(v.get("ok", false)):
				_canvas.loops.append(v.get("cleaned", PackedVector2Array()))
				_canvas.selected_index = 0
		elif not _canvas.loops.is_empty():
			_canvas.selected_index = 0
			_canvas.selected_kind = "loop"
		_canvas.queue_redraw()
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	_schedule_rebuild()


func close() -> void:
	_stash_session()
	_drain_build_task()
	visible = false
	CursorController.release_modal(MODAL_NAME)


func _stash_session() -> void:
	_read_spec_from_ui()
	if _spec == null:
		return
	_session_spec = _spec.duplicate_spec()
	_session_has_design = not _session_spec.loops.is_empty() \
		or not _session_spec.open_paths.is_empty()
	if _canvas != null:
		_session_tool = int(_canvas.tool)
		_session_corner_r = _canvas.corner_r_mm
	_session_spec.camber_mode = _camber_mode
	_session_spec.fill_mode = _fill_mode
	_session_spec.sync_fill_alias()


func _exit_tree() -> void:
	_drain_build_task()


func _drain_build_task() -> void:
	if _build_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_build_task_id)
		_build_task_id = -1
	_build_running = false


func _process(delta: float) -> void:
	if not visible:
		return
	if _rebuild_pending and not _build_running:
		_rebuild_timer -= delta
		if _rebuild_timer <= 0.0:
			_rebuild_pending = false
			_begin_async_build()
	if _build_running:
		# Animate the bar toward ~92% while the slice thread runs (no true % from
		# the worker); it snaps to 100 on apply.
		_progress_val = minf(_progress_val + delta * 0.7, 0.92)
		if _progress_bar != null:
			_progress_bar.value = _progress_val * 100.0
		if _build_task_id != -1 and WorkerThreadPool.is_task_completed(_build_task_id):
			WorkerThreadPool.wait_for_task_completion(_build_task_id)
			_build_task_id = -1
			_build_running = false
			_finish_async_build()
	_update_camera()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	root.add_child(_build_center())
	root.add_child(_build_preview_panel())


func _build_sidebar() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(300, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	var scroll := ScrollContainer.new()
	panel.add_child(scroll)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.custom_minimum_size = Vector2(280, 0)
	scroll.add_child(v)

	var title := Label.new()
	title.text = "Mud Building Designer"
	title.add_theme_font_size_override("font_size", 18)
	v.add_child(title)
	var sub := Label.new()
	sub.text = "Sketch walls → solid-layer preview (nozzle beads + fill) → print, export GRBL, or place."
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	sub.modulate = Color(0.7, 0.75, 0.82)
	v.add_child(sub)

	v.add_child(_sep())
	v.add_child(SectionHeader.make("Draw"))
	_tool_btns.clear()
	for t: Array in [
		[MudPlanCanvas.Tool.RECT, "Rectangle"],
		[MudPlanCanvas.Tool.ROUNDED_RECT, "Rounded rect"],
		[MudPlanCanvas.Tool.POLYLINE, "Closed polyline"],
		[MudPlanCanvas.Tool.OPEN_POLYLINE, "Open wall"],
		[MudPlanCanvas.Tool.BEZIER, "Bezier"],
		[MudPlanCanvas.Tool.SELECT, "Select / move"],
	]:
		var btn := Button.new()
		btn.text = str(t[1])
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		var tool_id: int = t[0]
		btn.pressed.connect(func(): _set_tool(tool_id))
		v.add_child(btn)
		_tool_btns.append({"btn": btn, "tool_id": tool_id})
	_set_tool(MudPlanCanvas.Tool.RECT)

	_corner = _spin_row(v, "Corner R (mm)", 50, 800, 200, 10)
	_corner.value_changed.connect(func(val: float):
		if _canvas != null:
			_canvas.corner_r_mm = val
	)

	var row := HBoxContainer.new()
	var undo := Button.new()
	undo.text = "Undo"
	undo.focus_mode = Control.FOCUS_NONE
	undo.pressed.connect(func():
		if _canvas != null:
			_canvas.undo_last()
	)
	row.add_child(undo)
	var del := Button.new()
	del.text = "Delete"
	del.focus_mode = Control.FOCUS_NONE
	del.pressed.connect(func():
		if _canvas != null:
			_canvas.delete_selected()
	)
	row.add_child(del)
	var clear := Button.new()
	clear.text = "Clear"
	clear.focus_mode = Control.FOCUS_NONE
	clear.pressed.connect(func():
		if _canvas != null:
			_canvas.clear_loops()
		if _spec != null:
			_spec.openings.clear()
	)
	row.add_child(clear)
	v.add_child(row)
	var door := Button.new()
	door.text = "Add doorway on selection"
	door.focus_mode = Control.FOCUS_NONE
	door.tooltip_text = "Cuts a ~900 mm door (with lintel) into the selected closed room."
	door.pressed.connect(_on_add_doorway)
	v.add_child(door)
	var clear_doors := Button.new()
	clear_doors.text = "Clear doors"
	clear_doors.focus_mode = Control.FOCUS_NONE
	clear_doors.tooltip_text = "Remove every doorway / opening from the plan."
	clear_doors.pressed.connect(_on_clear_doors)
	v.add_child(clear_doors)

	v.add_child(_sep())
	v.add_child(SectionHeader.make("Walls"))
	_height = _spin_row(v, "Height (mm)", 200, 4000, 2400, 50)
	_shell_gap = _spin_row(v, "Shell gap (mm)", 20, 600, 100, 5)
	_shell_gap.tooltip_text = "Clear space between the two perimeter shells — sine/gyroid fill lives here."
	_thickness_base = _spin_row(v, "Base thick (mm)", 40, 800, 176, 5)
	_thickness_base.tooltip_text = "Centerline wall thickness at the base (camber modes only)."
	_thickness_top = _spin_row(v, "Top thick (mm)", 40, 800, 120, 5)
	_thickness_top.tooltip_text = "Centerline wall thickness at the top (camber modes only)."
	_layer = _spin_row(v, "Layer H (mm)", 10, 200, 50, 5)
	for sb: SpinBox in [_height, _shell_gap, _thickness_base, _thickness_top, _layer]:
		sb.value_changed.connect(func(_v: float): _schedule_rebuild())

	v.add_child(SectionHeader.make("Camber"))
	_camber_btns.clear()
	var cam_row := HBoxContainer.new()
	for t: Array in [
		[MudBuildingSpec.CamberMode.NONE, "Off"],
		[MudBuildingSpec.CamberMode.BOTH, "Both"],
		[MudBuildingSpec.CamberMode.OUTER, "Outer"],
		[MudBuildingSpec.CamberMode.INNER, "Inner"],
	]:
		var cbtn := Button.new()
		cbtn.text = str(t[1])
		cbtn.toggle_mode = true
		cbtn.focus_mode = Control.FOCUS_NONE
		cbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var mode_id: int = t[0]
		cbtn.pressed.connect(func(): _set_camber(mode_id))
		cam_row.add_child(cbtn)
		_camber_btns.append({"btn": cbtn, "mode": mode_id})
	v.add_child(cam_row)
	_set_camber(MudBuildingSpec.CamberMode.NONE)

	v.add_child(_sep())
	v.add_child(SectionHeader.make("Wall fill"))
	_fill_mode_btns.clear()
	var fill_row := HBoxContainer.new()
	for t: Array in [
		[MudBuildingSpec.FillMode.NONE, "None"],
		[MudBuildingSpec.FillMode.SINE, "Sine"],
		[MudBuildingSpec.FillMode.GYROID, "Gyroid"],
	]:
		var fbtn := Button.new()
		fbtn.text = str(t[1])
		fbtn.toggle_mode = true
		fbtn.focus_mode = Control.FOCUS_NONE
		fbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var fid: int = t[0]
		fbtn.pressed.connect(func(): _set_fill_mode(fid))
		fill_row.add_child(fbtn)
		_fill_mode_btns.append({"btn": fbtn, "mode": fid})
	v.add_child(fill_row)
	_set_fill_mode(MudBuildingSpec.FillMode.SINE)
	_fill_enabled = null  # replaced by fill-mode buttons
	_fill_pitch = _spin_row(v, "Fill pitch (mm)", 40, 800, 200, 10)
	_fill_pitch.value_changed.connect(func(_v: float): _schedule_rebuild())

	v.add_child(_sep())
	v.add_child(SectionHeader.make("GRBL export"))
	var exp_note := Label.new()
	exp_note.text = "E = volumetric mm³ of mud. Add pump M-codes in the prelude for your machine."
	exp_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	exp_note.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	exp_note.modulate = Color(0.65, 0.7, 0.78)
	v.add_child(exp_note)
	var pre_cap := Label.new()
	pre_cap.text = "Prelude"
	pre_cap.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	v.add_child(pre_cap)
	_prelude_edit = TextEdit.new()
	_prelude_edit.custom_minimum_size = Vector2(0, 56)
	_prelude_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_prelude_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_prelude_edit)
	var epi_cap := Label.new()
	epi_cap.text = "Epilogue ({safe_z} = park Z)"
	epi_cap.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	v.add_child(epi_cap)
	_epilogue_edit = TextEdit.new()
	_epilogue_edit.custom_minimum_size = Vector2(0, 48)
	_epilogue_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_epilogue_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_epilogue_edit)
	var export_btn := Button.new()
	export_btn.text = "⬇ Export GRBL…"
	export_btn.focus_mode = Control.FOCUS_NONE
	export_btn.tooltip_text = "Write .gcode for a real GRBL mud printer (same path as the sim)."
	export_btn.pressed.connect(_on_export_grbl_pressed)
	v.add_child(export_btn)

	v.add_child(_sep())
	_est_lbl = Label.new()
	_est_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_est_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_est_lbl.text = "—"
	v.add_child(_est_lbl)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_status.modulate = Color(0.85, 0.75, 0.55)
	v.add_child(_status)

	var print_btn := Button.new()
	print_btn.text = "▶ Print on Mud Printer"
	print_btn.focus_mode = Control.FOCUS_NONE
	print_btn.pressed.connect(_on_print_pressed)
	v.add_child(print_btn)

	var place_btn := Button.new()
	place_btn.text = "🏗 Place in world (no print)"
	place_btn.focus_mode = Control.FOCUS_NONE
	place_btn.tooltip_text = "Ghost-place the design as a structure without running the mud printer."
	place_btn.pressed.connect(_on_place_pressed)
	v.add_child(place_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	v.add_child(close_btn)
	return panel


func _build_center() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.4
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	var v := VBoxContainer.new()
	panel.add_child(v)
	var cap := Label.new()
	cap.text = "Plan — rooms / open walls / bezier (Enter commit, Shift+Enter closes bezier) · Del removes"
	cap.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	cap.modulate = Color(0.7, 0.75, 0.82)
	v.add_child(cap)
	_canvas = MudPlanCanvas.new()
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.custom_minimum_size = Vector2(400, 400)
	_canvas.plan_changed.connect(_schedule_rebuild)
	v.add_child(_canvas)
	return panel


func _build_preview_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.15
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	var v := VBoxContainer.new()
	panel.add_child(v)
	var cap := Label.new()
	cap.text = "Solid-layer preview — RMB orbit · MMB/Shift+drag pan · wheel zoom"
	cap.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	cap.modulate = Color(0.7, 0.75, 0.82)
	cap.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(cap)

	var vpc := SubViewportContainer.new()
	vpc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc.stretch = true
	vpc.custom_minimum_size = Vector2(420, 340)
	vpc.mouse_filter = Control.MOUSE_FILTER_STOP
	vpc.gui_input.connect(_on_preview_input)
	vpc.resized.connect(_update_viewport_size)
	_vpc = vpc
	v.add_child(vpc)

	# Render-progress bar (shown while the slice/mesh build runs on a worker).
	_progress_row = HBoxContainer.new()
	_progress_row.add_theme_constant_override("separation", 8)
	_progress_lbl = Label.new()
	_progress_lbl.text = "Rendering…"
	_progress_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_progress_lbl.custom_minimum_size = Vector2(96, 0)
	_progress_row.add_child(_progress_lbl)
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.value = 0.0
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(0, 14)
	_progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress_row.add_child(_progress_bar)
	_progress_row.visible = false
	v.add_child(_progress_row)

	# --- Toolpath inspector controls (Phase 3) ---
	var insp := HBoxContainer.new()
	insp.add_theme_constant_override("separation", 8)
	var tp_btn := Button.new()
	tp_btn.text = "Toolpath view"
	tp_btn.toggle_mode = true
	tp_btn.focus_mode = Control.FOCUS_NONE
	tp_btn.tooltip_text = "Show the raw print path (extrusion + travels) instead of the solid mesh."
	tp_btn.toggled.connect(func(pressed: bool):
		_view_toolpath = pressed
		_apply_view())
	insp.add_child(tp_btn)
	_travels_chk = CheckButton.new()
	_travels_chk.text = "Travels"
	_travels_chk.button_pressed = true
	_travels_chk.focus_mode = Control.FOCUS_NONE
	_travels_chk.tooltip_text = "Draw non-extruding (pump-off) moves in red."
	_travels_chk.toggled.connect(func(pressed: bool):
		_show_travels = pressed
		_rebuild_overlay())
	insp.add_child(_travels_chk)
	v.add_child(insp)

	var lrow := HBoxContainer.new()
	lrow.add_theme_constant_override("separation", 8)
	_layer_lbl = Label.new()
	_layer_lbl.text = "Layers: all"
	_layer_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_layer_lbl.custom_minimum_size = Vector2(96, 0)
	lrow.add_child(_layer_lbl)
	_layer_slider = HSlider.new()
	_layer_slider.min_value = 1
	_layer_slider.max_value = 1
	_layer_slider.step = 1
	_layer_slider.value = 1
	_layer_slider.editable = false
	_layer_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layer_slider.value_changed.connect(_on_layer_slider)
	lrow.add_child(_layer_slider)
	v.add_child(lrow)

	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
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
	# Soft AO so the grooves between stacked beads read as layer lines.
	env.ssao_enabled = true
	env.ssao_radius = 0.35
	env.ssao_intensity = 1.4
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	world.add_child(world_env)
	# Warm key light (low sun), cool sky fill, and a rim/back light for the beads.
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-42, 38, 0)
	light.light_energy = 1.35
	light.light_color = Color(1.0, 0.93, 0.82)
	light.shadow_enabled = true
	world.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, -135, 0)
	fill.light_energy = 0.34
	fill.light_color = Color(0.80, 0.86, 1.0)
	world.add_child(fill)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-8, 150, 0)
	rim.light_energy = 0.6
	rim.light_color = Color(1.0, 0.96, 0.9)
	world.add_child(rim)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.28, 0.30, 0.27)
	gmat.roughness = 0.95
	ground.material_override = gmat
	world.add_child(ground)
	_holder = Node3D.new()
	_holder.name = "PreviewHolder"
	world.add_child(_holder)
	_camera = Camera3D.new()
	_camera.fov = 42.0
	_camera.current = true
	world.add_child(_camera)
	return panel


func _set_tool(tool_id: int) -> void:
	if _canvas != null:
		_canvas.tool = tool_id as MudPlanCanvas.Tool
	for entry: Variant in _tool_btns:
		var d: Dictionary = entry
		var b: Button = d["btn"]
		b.button_pressed = int(d["tool_id"]) == tool_id


func _set_camber(mode_id: int) -> void:
	_camber_mode = mode_id
	for entry: Variant in _camber_btns:
		var d: Dictionary = entry
		var b: Button = d["btn"]
		b.button_pressed = int(d["mode"]) == mode_id
	var taper := mode_id != MudBuildingSpec.CamberMode.NONE
	if _thickness_base != null:
		_thickness_base.editable = taper
		_thickness_base.modulate = Color.WHITE if taper else Color(1, 1, 1, 0.45)
	if _thickness_top != null:
		_thickness_top.editable = taper
		_thickness_top.modulate = Color.WHITE if taper else Color(1, 1, 1, 0.45)
	_schedule_rebuild()


func _set_fill_mode(mode_id: int) -> void:
	_fill_mode = mode_id
	for entry: Variant in _fill_mode_btns:
		var d: Dictionary = entry
		var b: Button = d["btn"]
		b.button_pressed = int(d["mode"]) == mode_id
	_schedule_rebuild()


func _sync_sidebar_from_spec() -> void:
	if _spec == null:
		return
	_suppress_spin(_height, _spec.height_mm)
	_suppress_spin(_shell_gap, _spec.shell_gap_mm)
	_suppress_spin(_thickness_base, _spec.thickness_base_mm)
	_suppress_spin(_thickness_top, _spec.thickness_top_mm)
	_suppress_spin(_layer, _spec.layer_height_mm)
	_suppress_spin(_fill_pitch, _spec.fill_pitch_mm)
	_set_fill_mode(_spec.fill_mode)
	_set_camber(_spec.camber_mode)
	if _corner != null:
		_suppress_spin(_corner, _canvas.corner_r_mm if _canvas != null else 200.0)
	if _dialect == null:
		_dialect = MudGrblDialect.default_dialect()
	if _prelude_edit != null:
		_prelude_edit.text = _dialect.prelude
	if _epilogue_edit != null:
		_epilogue_edit.text = _dialect.epilogue


func _suppress_spin(sb: SpinBox, val: float) -> void:
	if sb == null:
		return
	sb.set_value_no_signal(clampf(val, sb.min_value, sb.max_value))


func _read_spec_from_ui() -> void:
	if _spec == null:
		return
	_spec.height_mm = float(_height.value)
	_spec.shell_gap_mm = float(_shell_gap.value) if _shell_gap != null else 100.0
	_spec.thickness_base_mm = float(_thickness_base.value)
	_spec.thickness_top_mm = float(_thickness_top.value)
	_spec.sync_thickness_alias()
	_spec.camber_mode = _camber_mode
	_spec.fill_mode = _fill_mode
	_spec.sync_fill_alias()
	_spec.fill_pitch_mm = float(_fill_pitch.value) if _fill_pitch != null else 200.0
	_spec.layer_height_mm = float(_layer.value)
	_spec.line_width_mm = _spec.nozzle_mm
	_spec.loops = []
	_spec.open_paths = []
	if _canvas != null:
		for loop: Variant in _canvas.loops:
			if loop is PackedVector2Array:
				_spec.loops.append((loop as PackedVector2Array).duplicate())
		for path: Variant in _canvas.open_paths:
			if path is PackedVector2Array:
				_spec.open_paths.append((path as PackedVector2Array).duplicate())
		_canvas.corner_r_mm = float(_corner.value) if _corner != null else 200.0


func _schedule_rebuild() -> void:
	_rebuild_pending = true
	_rebuild_timer = REBUILD_DEBOUNCE_S
	set_process(true)


## Kick off a threaded rebuild for live edits (slice on a worker, mesh on apply).
func _begin_async_build() -> void:
	if _build_running:
		_rebuild_queued = true
		return
	_read_spec_from_ui()
	var val := MudPlanOps.validate_spec(_spec)
	if not bool(val.get("ok", false)):
		_last_parse = {}
		_last_mesh = null
		_clear_preview()
		_est_lbl.text = "—"
		_status.text = str(val.get("error", "invalid"))
		_hide_progress()
		return
	_spec.loops = val.get("loops", [])
	_spec.open_paths = val.get("open_paths", [])
	var snapshot := _spec.duplicate_spec()
	_build_out = {}
	_build_running = true
	_progress_val = 0.05
	_show_progress("Slicing…")
	_build_task_id = WorkerThreadPool.add_task(
		Callable(self, "_threaded_build").bind(snapshot), true, "mud building slice")
	set_process(true)


## Worker-thread body — pure static slicing, no scene/resource touches.
func _threaded_build(spec: MudBuildingSpec) -> void:
	_build_out = _compute_build(spec)


func _finish_async_build() -> void:
	if _progress_lbl != null:
		_progress_lbl.text = "Meshing…"
	if _progress_bar != null:
		_progress_bar.value = 96.0
	_apply_build(_build_out)
	_build_out = {}
	_hide_progress()
	if _rebuild_queued:
		_rebuild_queued = false
		_begin_async_build()


## Synchronous build for export / print / place (must have fresh parse + mesh).
func _build_sync() -> void:
	_read_spec_from_ui()
	var val := MudPlanOps.validate_spec(_spec)
	if not bool(val.get("ok", false)):
		_last_parse = {}
		_last_mesh = null
		_clear_preview()
		_est_lbl.text = "—"
		_status.text = str(val.get("error", "invalid"))
		return
	_spec.loops = val.get("loops", [])
	_spec.open_paths = val.get("open_paths", [])
	_apply_build(_compute_build(_spec))


## Slice twice (dense for mesh/export, decimated for the job store). Static-only
## so it is safe to run on a WorkerThreadPool thread.
func _compute_build(spec: MudBuildingSpec) -> Dictionary:
	var preview := MudWallSlicer.slice(spec, {
		"decimate": true,
		"max_segments": 16000,
		"kind_hint": "mud_building",
	})
	var full := MudWallSlicer.slice(spec, {"decimate": false})
	return {"preview": preview, "full": full}


func _apply_build(build: Dictionary) -> void:
	var preview: Dictionary = build.get("preview", {})
	var full: Dictionary = build.get("full", {})
	_last_parse = preview
	_last_mesh = null
	if bool(full.get("ok", false)):
		_last_mesh = MudWallMesher.build_mesh_from_parse(full)
	_sync_layer_slider()
	_show_preview(_last_mesh)
	if bool(_last_parse.get("ok", false)):
		var fill_name := "no fill"
		match int(_last_parse.get("fill_mode", MudBuildingSpec.FillMode.NONE)):
			MudBuildingSpec.FillMode.SINE:
				fill_name = "sine fill"
			MudBuildingSpec.FillMode.GYROID:
				fill_name = "gyroid fill"
		_est_lbl.text = "%s · gap %.0f mm · %s · %s · %.0f m · ~%.1f L · %s" % [
			UiText.count(int(_last_parse.get("island_count", 0)), "room"),
			_spec.shell_gap_mm,
			UiText.count(int(_last_parse.get("layer_count", 0)), "layer"),
			fill_name,
			float(_last_parse.get("path_length_mm", 0.0)) / 1000.0,
			float(_last_parse.get("volume_mm3", 0.0)) / 1_000_000.0,
			_fmt_time(float(_last_parse.get("est_time_hr", 0.0))),
		]
		_status.text = "Solid-layer preview ready — print, export, or place"
	else:
		_est_lbl.text = "—"
		_status.text = str(_last_parse.get("error", "slice failed"))


func _show_progress(text: String) -> void:
	if _progress_row != null:
		_progress_row.visible = true
	if _progress_lbl != null:
		_progress_lbl.text = text
	if _progress_bar != null:
		_progress_bar.value = _progress_val * 100.0


func _hide_progress() -> void:
	if _progress_row != null:
		_progress_row.visible = false


func _update_viewport_size() -> void:
	if _vp == null or _vpc == null:
		return
	# Render at ~1.25× the container so the stretched image stays crisp.
	var sz := _vpc.size
	if sz.x < 2.0 or sz.y < 2.0:
		return
	var ss := 1.25
	_vp.size = Vector2i(
		clampi(int(sz.x * ss), 320, 2560),
		clampi(int(sz.y * ss), 320, 2560))


func _fmt_time(hr: float) -> String:
	if hr < 1.0:
		return "~%.0f min" % (hr * 60.0)
	return "~%.1f h" % hr


func _clear_preview() -> void:
	_solid_mi = null
	_path_mi = null
	if _holder == null:
		return
	for c in _holder.get_children():
		c.queue_free()


func _show_preview(mesh: ArrayMesh) -> void:
	_clear_preview()
	if _holder == null:
		return
	if mesh != null:
		_solid_mi = MeshInstance3D.new()
		_solid_mi.mesh = mesh
		if mesh.get_surface_count() > 0:
			var mat := mesh.surface_get_material(0)
			if mat is StandardMaterial3D:
				(mat as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
		_holder.add_child(_solid_mi)
		var aabb := mesh.get_aabb()
		_cam_target = aabb.get_center()
		_dist = clampf(aabb.size.length() * 1.35, 2.5, 60.0)
	_path_mi = MeshInstance3D.new()
	_holder.add_child(_path_mi)
	_rebuild_overlay()
	_apply_view()


## Toggle solid mesh vs. raw toolpath lines.
func _apply_view() -> void:
	if _solid_mi != null and is_instance_valid(_solid_mi):
		_solid_mi.visible = not _view_toolpath
	if _path_mi != null and is_instance_valid(_path_mi):
		_path_mi.visible = _view_toolpath
	if _layer_slider != null:
		_layer_slider.editable = _view_toolpath
	if _view_toolpath:
		_rebuild_overlay()


func _sync_layer_slider() -> void:
	if _layer_slider == null:
		return
	var lc := maxi(int(_last_parse.get("layer_count", 1)), 1)
	_layer_slider.max_value = lc
	_layer_slider.set_value_no_signal(lc)
	_max_layer = lc
	if _layer_lbl != null:
		_layer_lbl.text = "Layers: all"


func _on_layer_slider(val: float) -> void:
	_max_layer = int(val)
	if _layer_lbl != null:
		var lc := maxi(int(_last_parse.get("layer_count", 1)), 1)
		_layer_lbl.text = "Layers: all" if _max_layer >= lc else "Layers: ≤%d" % _max_layer
	_rebuild_overlay()


## Build the raw toolpath as coloured line segments (extrusion vs. travel),
## clipped to layers ≤ _max_layer. Cheap — rebuilt on scrub/toggle.
func _rebuild_overlay() -> void:
	if _path_mi == null or not is_instance_valid(_path_mi):
		return
	if not bool(_last_parse.get("ok", false)):
		_path_mi.mesh = null
		return
	var pts: PackedVector3Array = _last_parse.get("points", PackedVector3Array())
	var ext: PackedInt32Array = _last_parse.get("extruding", PackedInt32Array())
	if pts.size() < 2:
		_path_mi.mesh = null
		return
	var lh := maxf(float(_last_parse.get("layer_height_mm", 50.0)), 1.0)
	var bmin := pts[0]
	var bmax := pts[0]
	for p: Vector3 in pts:
		bmin = Vector3(minf(bmin.x, p.x), minf(bmin.y, p.y), minf(bmin.z, p.z))
		bmax = Vector3(maxf(bmax.x, p.x), maxf(bmax.y, p.y), maxf(bmax.z, p.z))
	var cx := (bmin.x + bmax.x) * 0.5
	var cy := (bmin.y + bmax.y) * 0.5
	var z_base := bmin.z - lh * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var col_ext := Color(0.55, 0.95, 0.70)
	var col_tra := Color(0.95, 0.32, 0.28)
	var added := false
	for i in range(1, pts.size()):
		var extruding := i < ext.size() and ext[i] != 0
		if not extruding and not _show_travels:
			continue
		var li := int(floor(pts[i].z / lh))
		if li >= _max_layer:
			continue
		st.set_color(col_ext if extruding else col_tra)
		st.add_vertex(_path_to_world(pts[i - 1], cx, cy, z_base))
		st.set_color(col_ext if extruding else col_tra)
		st.add_vertex(_path_to_world(pts[i], cx, cy, z_base))
		added = true
	if not added:
		_path_mi.mesh = null
		return
	var mesh := st.commit()
	var lmat := StandardMaterial3D.new()
	lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lmat.vertex_color_use_as_albedo = true
	if mesh != null and mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, lmat)
	_path_mi.mesh = mesh


## Machine mm (X,Y bed, Z up) → Godot metres Y-up, matching MudWallMesher.
func _path_to_world(p: Vector3, cx: float, cy: float, z_base: float) -> Vector3:
	return Vector3((p.x - cx) * 0.001, (p.z - z_base) * 0.001, -(p.y - cy) * 0.001)


func _update_camera() -> void:
	if _camera == null:
		return
	var offset := Vector3(
		cos(_pitch) * sin(_yaw),
		sin(_pitch),
		cos(_pitch) * cos(_yaw)) * _dist
	_camera.global_position = _cam_target + offset
	_camera.look_at(_cam_target, Vector3.UP)


func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = mb.pressed
			_panning = false
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_orbiting = false
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(_dist * 0.88, 1.5)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(_dist * 1.12, 80.0)
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


func _read_dialect_from_ui() -> void:
	if _dialect == null:
		_dialect = MudGrblDialect.default_dialect()
	if _prelude_edit != null:
		_dialect.prelude = _prelude_edit.text
	if _epilogue_edit != null:
		_dialect.epilogue = _epilogue_edit.text


func _on_export_grbl_pressed() -> void:
	_build_sync()
	if not bool(_last_parse.get("ok", false)):
		_status.text = str(_last_parse.get("error", "nothing to export"))
		return
	_read_dialect_from_ui()
	var result := MudGrblExport.from_spec(_spec, _dialect)
	if not bool(result.get("ok", false)):
		_status.text = str(result.get("error", "export failed"))
		return
	var user_path := MudGrblExport.write_user(result)
	if user_path.is_empty():
		_status.text = "Could not write user://machines/exports/"
		return
	_status.text = "Saved %s — choose a copy location…" % user_path
	_ensure_export_dialog()
	_export_dialog.set_meta("pending_gcode", str(result.get("gcode", "")))
	_export_dialog.current_file = "mud_building_%d.gcode" % Time.get_unix_time_from_system()
	_export_dialog.popup_centered(Vector2i(900, 640))


func _ensure_export_dialog() -> void:
	if _export_dialog != null and is_instance_valid(_export_dialog):
		return
	_export_dialog = FileDialog.new()
	_export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_export_dialog.use_native_dialog = true
	_export_dialog.filters = PackedStringArray([
		"*.gcode ; GRBL G-code",
		"*.nc ; GRBL NC",
	])
	_export_dialog.title = "Save GRBL…"
	_export_dialog.file_selected.connect(_on_export_file_selected)
	add_child(_export_dialog)


func _on_export_file_selected(path: String) -> void:
	var gcode := ""
	if _export_dialog != null and _export_dialog.has_meta("pending_gcode"):
		gcode = str(_export_dialog.get_meta("pending_gcode"))
	if gcode.is_empty():
		_read_dialect_from_ui()
		var result := MudGrblExport.from_spec(_spec, _dialect)
		if not bool(result.get("ok", false)):
			_status.text = str(result.get("error", "export failed"))
			return
		gcode = str(result.get("gcode", ""))
		if not MudGrblExport.write_file(result, path):
			_status.text = "Could not save %s" % path
			return
	else:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			_status.text = "Could not save %s" % path
			return
		f.store_string(gcode)
		f.close()
		MudGrblExport.last_export_path = path
	_status.text = "GRBL exported → %s" % path


func _on_add_doorway() -> void:
	if _canvas == null or _spec == null:
		return
	if _canvas.selected_kind != "loop" or _canvas.selected_index < 0 \
			or _canvas.selected_index >= _canvas.loops.size():
		_status.text = "Select a closed room first"
		return
	# ~900 mm door on the south edge of a typical room (t ≈ 0.05–0.15 of perimeter).
	var opening := {
		"loop_index": _canvas.selected_index,
		"t0": 0.05,
		"t1": 0.14,
		"lintel_mm": minf(2100.0, float(_height.value) * 0.85) if _height != null else 2100.0,
	}
	# Replace any existing opening on this loop.
	var kept: Array = []
	for o: Variant in _spec.openings:
		if o is Dictionary and int((o as Dictionary).get("loop_index", -1)) != opening["loop_index"]:
			kept.append(o)
	kept.append(opening)
	_spec.openings = kept
	_schedule_rebuild()
	_status.text = "Doorway added (lintel %.0f mm)" % float(opening["lintel_mm"])


func _on_clear_doors() -> void:
	if _spec == null:
		return
	var n := _spec.openings.size()
	_spec.openings.clear()
	_schedule_rebuild()
	_status.text = "Cleared %d doorway%s" % [n, "" if n == 1 else "s"] if n > 0 \
		else "No doorways to clear"


func _on_place_pressed() -> void:
	_build_sync()
	if not bool(_last_parse.get("ok", false)):
		_status.text = str(_last_parse.get("error", "nothing to place"))
		return
	if _view == null or not _view.has_method("place_mud_building"):
		_status.text = "No graph view — cannot place"
		return
	var mud := _spec.to_dict()
	_view.call("place_mud_building", mud)
	_status.text = "Place the building in the world"
	close()


func _on_print_pressed() -> void:
	_build_sync()
	if _view == null or not _view.has_method("start_machine_job"):
		_status.text = "No graph view — open from a mud printer."
		return
	if _item_id.is_empty():
		_status.text = "Bind a Mud Printer first (open Design from the Print modal)."
		return
	if not bool(_last_parse.get("ok", false)):
		_status.text = str(_last_parse.get("error", "nothing to print"))
		return
	var stl_path := MudWallMesher.write_stl(_spec)
	if stl_path.is_empty():
		_status.text = "Could not write print mesh."
		return
	if _runtime != null and _last_mesh != null:
		_runtime.begin_print_preview(_last_mesh, stl_path)
	var wet: Variant = _specs.get("wet_color", [0.36, 0.26, 0.17])
	var dry: Variant = _specs.get("dry_color", [0.68, 0.56, 0.42])
	var extra := {
		"machine_kind": "mud",
		"print_persist": true,
		"print_mesh_path": stl_path,
		"print_offset_x": 0.0,
		"print_offset_z": 0.0,
		"print_scale": 1.0,
		"print_mode": "solid",
		"nozzle_diameter_mm": _spec.nozzle_mm,
		"line_width_mm": _spec.line_width_mm,
		"layer_height_mm": _spec.layer_height_mm,
		"print_speed_mm_s": _spec.print_speed_mm_s,
		"wet_color": wet,
		"dry_color": dry,
		"job_material_kind": "mud",
	}
	var ok: bool = _view.call("start_machine_job", _item_id, _last_parse,
		"mud_building", "Mud Building", 1, extra)
	if ok:
		_status.text = "Print started"
		_stash_session()
		close()
	else:
		_status.text = "Could not start print job"


func _spin_row(parent: Control, label: String, lo: float, hi: float, val: float,
		step: float) -> SpinBox:
	var row := HBoxContainer.new()
	var cap := Label.new()
	cap.text = label
	cap.custom_minimum_size = Vector2(130, 0)
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cap)
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = step
	sb.value = val
	sb.custom_minimum_size = Vector2(100, 0)
	row.add_child(sb)
	parent.add_child(row)
	return sb


func _sep() -> HSeparator:
	return HSeparator.new()
