extends Control

## Shared FDM Print Setup modal (trash / mud STL / future FDM). Full-screen
## mud-designer layout: slicer sidebar + orbitable SubViewport preview, while
## also driving the live in-world bed ghost via CncMachineRuntime. Capabilities
## (ranges, presets, persist vs inventory, Design building…) come from
## FdmPrinterCaps so new FDM machines only need specs — not modal forks.
## Does not export G-code (mud building designer still owns GRBL).

const MODAL_NAME := "print_setup"
const PRINTS_DIR := "user://machines/prints"

var _runtime: CncMachineRuntime = null
var _item_id: String = ""
var _view: Node = null
var _specs: Dictionary = {}
var _caps: FdmPrinterCaps = null
var _part_id := ""
var _part_label := ""

var _mesh: ArrayMesh = null
var _mesh_path: String = ""
var _parse: Dictionary = {}

var _built := false
var _title: Label = null
var _preset: OptionButton = null
var _preset_row: Control = null
var _offx: HSlider = null
var _offz: HSlider = null
var _scale: HSlider = null
var _mode: OptionButton = null
var _nozzle: HSlider = null
var _wall: HSlider = null
var _layer: HSlider = null
var _speed: HSlider = null
## slider -> its synced SpinBox (so numeric values are always visible/editable).
var _spin_for := {}
var _wet_btn: ColorPickerButton = null
var _dry_btn: ColorPickerButton = null
var _wet_lbl: Label = null
var _dry_lbl: Label = null
var _status: Label = null
var _start_btn: Button = null
var _file_dialog: FileDialog = null
var _presets: Array = []

## Studio preview (mud-designer style).
var _vpc: SubViewportContainer = null
var _vp: SubViewport = null
var _holder: Node3D = null
var _camera: Camera3D = null
var _solid_mi: MeshInstance3D = null
var _path_mi: MeshInstance3D = null
var _bed_mi: MeshInstance3D = null
var _yaw := 0.55
var _pitch := 0.42
var _dist := 0.6
var _cam_target := Vector3(0, 0.05, 0)
var _orbiting := false
var _panning := false
var _view_toolpath := false
var _show_travels := true
var _layer_slider: HSlider = null
var _layer_lbl: Label = null
var _max_layer := 1_000_000
var _travels_chk: CheckButton = null

## Last-used print settings per printer prop (session cache). Keyed by item_id.
var _last_settings: Dictionary = {}


func open(runtime: CncMachineRuntime, item_id: String, view: Node, specs: Dictionary) -> void:
	_runtime = runtime
	_item_id = item_id
	_view = view
	_specs = specs.duplicate(true)
	if _last_settings.has(item_id):
		_specs.merge(_last_settings[item_id] as Dictionary, true)
	_caps = FdmPrinterCaps.from_specs(_specs)
	# Mirror bed-lowering onto the runtime so seating works even before a job.
	if _runtime != null and is_instance_valid(_runtime):
		_runtime.set_meta("fdm_bed_lowering", _caps.is_bed_lowering())
	_part_id = str(_specs.get("job_part_id", ""))
	_part_label = str(_specs.get("job_part_label", ""))
	if not _built:
		_build_ui()
		_built = true
	_apply_caps_chrome()
	_reset_from_specs()
	visible = true
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func _apply_caps_chrome() -> void:
	if _caps == null:
		return
	if _title != null:
		_title.text = "%s — 3D print setup" % _caps.display_name
	if _preset_row != null:
		_preset_row.visible = _caps.show_part_presets
	if _preset != null:
		_preset.visible = _caps.show_part_presets
	var design_btn := find_child("DesignBuildingBtn", true, false) as Button
	if design_btn != null:
		design_btn.visible = _caps.show_design_building
	if _caps.show_design_building and _status != null \
			and not MudGrblExport.last_export_path.is_empty():
		_status.text = "Last GRBL export: %s" % MudGrblExport.last_export_path
	if _wet_lbl != null:
		_wet_lbl.text = _caps.wet_label
	if _dry_lbl != null:
		_dry_lbl.text = _caps.dry_label
	_set_range(_nozzle, _caps.nozzle_lo, _caps.nozzle_hi)
	_set_range(_wall, _caps.wall_lo, _caps.wall_hi)
	_set_range(_layer, _caps.layer_lo, _caps.layer_hi)
	_set_range(_speed, _caps.speed_lo, _caps.speed_hi)
	_set_range(_scale, _caps.scale_lo, _caps.scale_hi)
	var work_m := _caps.work_m()
	_set_range(_offx, -work_m * 0.5, work_m * 0.5)
	_set_range(_offz, -work_m * 0.5, work_m * 0.5)
	_rebuild_bed_plane()
	if _caps.show_part_presets:
		_rebuild_preset_menu()


func close() -> void:
	_snapshot_settings()
	visible = false
	set_process(false)
	if _runtime != null and is_instance_valid(_runtime):
		_runtime.clear_print_preview()
	CursorController.release_modal(MODAL_NAME)


func _snapshot_settings() -> void:
	if _item_id.is_empty() or not _built or _caps == null:
		return
	_last_settings[_item_id] = {
		"print_offset_x": float(_offx.value),
		"print_offset_z": float(_offz.value),
		"print_scale": float(_scale.value),
		"print_mode": "vase" if (_mode != null and _mode.selected == 1) else "solid",
		"nozzle_diameter_mm": float(_nozzle.value),
		"filament_diameter_mm": float(_nozzle.value),
		"line_width_mm": float(_wall.value),
		"layer_height_mm": float(_layer.value),
		"print_speed_mm_s": float(_speed.value) if _speed != null else _caps.print_speed_mm_s,
		"wet_color": [_wet_btn.color.r, _wet_btn.color.g, _wet_btn.color.b],
		"dry_color": [_dry_btn.color.r, _dry_btn.color.g, _dry_btn.color.b],
	}


func _process(_delta: float) -> void:
	if visible:
		_update_camera()


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
	root.add_child(_build_preview_panel())


func _build_sidebar() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	var scroll := ScrollContainer.new()
	panel.add_child(scroll)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.custom_minimum_size = Vector2(340, 0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)

	_title = Label.new()
	_title.text = "FDM Printer — 3D print setup"
	_title.add_theme_font_size_override("font_size", 18)
	v.add_child(_title)

	var sub := Label.new()
	sub.text = "Load a part → preview on the bed (studio + in-world ghost) → dial slicer → Start print."
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	sub.modulate = Color(0.7, 0.75, 0.82)
	v.add_child(sub)

	_preset_row = HBoxContainer.new()
	_preset_row.name = "PresetRow"
	var preset_cap := Label.new()
	preset_cap.text = "Part"
	preset_cap.custom_minimum_size = Vector2(110, 0)
	_preset_row.add_child(preset_cap)
	_preset = OptionButton.new()
	_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset.item_selected.connect(_on_preset_selected)
	_preset_row.add_child(_preset)
	v.add_child(_preset_row)

	var load_btn := Button.new()
	load_btn.text = "Load STL…"
	load_btn.pressed.connect(_on_load_pressed)
	v.add_child(load_btn)

	var design_btn := Button.new()
	design_btn.name = "DesignBuildingBtn"
	design_btn.text = "🏗 Design building…"
	design_btn.tooltip_text = "Sketch wall plans and print dual-perimeter mud walls (no STL needed)."
	design_btn.pressed.connect(_on_design_building_pressed)
	v.add_child(design_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = "Select a part or load an STL to preview on the bed."
	v.add_child(_status)

	v.add_child(_sep())
	_offx = _slider_row(v, "Position X (m)", -1.5, 1.5, 0.01, 0.0)
	_offz = _slider_row(v, "Position Y (m)", -1.5, 1.5, 0.01, 0.0)
	_scale = _slider_row(v, "Scale", 0.05, 8.0, 0.05, 1.0)

	v.add_child(_sep())
	var slicer_lbl := Label.new()
	slicer_lbl.text = "Slicer"
	slicer_lbl.add_theme_font_size_override("font_size", 15)
	v.add_child(slicer_lbl)
	var mode_row := HBoxContainer.new()
	var mode_cap := Label.new()
	mode_cap.text = "Infill mode"
	mode_cap.custom_minimum_size = Vector2(110, 0)
	mode_row.add_child(mode_cap)
	_mode = OptionButton.new()
	_mode.add_item("Solid", 0)
	_mode.add_item("Spiral vase (no infill)", 1)
	_mode.select(0)
	_mode.item_selected.connect(func(_i): _on_slicer_changed())
	mode_row.add_child(_mode)
	v.add_child(mode_row)
	_nozzle = _slider_row(v, "Nozzle diameter (mm)", 0.2, 150.0, 0.1, 6.0)
	_wall = _slider_row(v, "Wall / line width (mm)", 0.2, 200.0, 0.1, 6.0)
	_layer = _slider_row(v, "Layer height (mm)", 0.05, 100.0, 0.05, 0.8)
	_speed = _slider_row(v, "Print speed (mm/s)", 5.0, 600.0, 1.0, 40.0)
	_nozzle.value_changed.connect(_on_nozzle_changed)
	_wall.value_changed.connect(func(_v): _on_slicer_changed())
	_layer.value_changed.connect(func(_v): _on_slicer_changed())
	_speed.value_changed.connect(func(_v): _on_slicer_changed())
	_scale.value_changed.connect(func(_v): _on_slicer_changed())

	v.add_child(_sep())
	var wet_row := HBoxContainer.new()
	_wet_lbl = Label.new()
	_wet_lbl.text = "Filament color"
	_wet_lbl.custom_minimum_size = Vector2(110, 0)
	wet_row.add_child(_wet_lbl)
	_wet_btn = ColorPickerButton.new()
	_wet_btn.custom_minimum_size = Vector2(120, 28)
	_wet_btn.color = Color(0.85, 0.55, 0.20)
	_wet_btn.color_changed.connect(func(_c): _apply_preview())
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
	_dry_btn.color_changed.connect(func(_c): _apply_preview())
	dry_row.add_child(_dry_btn)
	v.add_child(dry_row)

	v.add_child(_sep())
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	_start_btn = Button.new()
	_start_btn.text = "Start print"
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_btn.pressed.connect(_on_start_pressed)
	btns.add_child(_start_btn)
	var cancel := Button.new()
	cancel.text = "Close"
	cancel.pressed.connect(close)
	btns.add_child(cancel)
	v.add_child(btns)
	return panel


func _build_preview_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.35
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	var v := VBoxContainer.new()
	panel.add_child(v)
	var cap := Label.new()
	cap.text = "Bed preview — RMB orbit · MMB/Shift+drag pan · wheel zoom  ·  in-world ghost updates on the machine"
	cap.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	cap.modulate = Color(0.7, 0.75, 0.82)
	cap.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(cap)

	var vpc := SubViewportContainer.new()
	vpc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc.stretch = true
	vpc.custom_minimum_size = Vector2(480, 360)
	vpc.mouse_filter = Control.MOUSE_FILTER_STOP
	vpc.gui_input.connect(_on_preview_input)
	vpc.resized.connect(_update_viewport_size)
	_vpc = vpc
	v.add_child(vpc)

	var insp := HBoxContainer.new()
	insp.add_theme_constant_override("separation", 8)
	var tp_btn := Button.new()
	tp_btn.text = "Toolpath view"
	tp_btn.toggle_mode = true
	tp_btn.focus_mode = Control.FOCUS_NONE
	tp_btn.tooltip_text = "Show the synthesized print path instead of the solid mesh."
	tp_btn.toggled.connect(func(pressed: bool):
		_view_toolpath = pressed
		_apply_view())
	insp.add_child(tp_btn)
	_travels_chk = CheckButton.new()
	_travels_chk.text = "Travels"
	_travels_chk.button_pressed = true
	_travels_chk.focus_mode = Control.FOCUS_NONE
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
	_rebuild_bed_plane()
	return panel


func _rebuild_bed_plane() -> void:
	if _holder == null or _caps == null:
		return
	if _bed_mi != null and is_instance_valid(_bed_mi):
		_bed_mi.queue_free()
	_bed_mi = null
	var work := _caps.work_m()
	var mi := MeshInstance3D.new()
	mi.name = "BedPlane"
	var plane := PlaneMesh.new()
	plane.size = Vector2(work, work)
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.24, 0.28, 0.92)
	mat.roughness = 0.85
	mat.metallic = 0.15
	mi.material_override = mat
	# Slightly below y=0 so the part (base at 0) sits on top without z-fight.
	mi.position = Vector3(0, -0.001, 0)
	_holder.add_child(mi)
	# Keep bed under other preview children.
	_holder.move_child(mi, 0)
	_bed_mi = mi


func _sep() -> HSeparator:
	return HSeparator.new()


func _slider_row(parent: VBoxContainer, label: String, lo: float, hi: float,
		step: float, val: float) -> HSlider:
	var row := VBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label
	row.add_child(lbl)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(180, 0)
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = step
	sb.value = val
	sb.custom_minimum_size = Vector2(92, 0)
	s.value_changed.connect(func(vv: float): sb.set_value_no_signal(vv))
	sb.value_changed.connect(func(vv: float): s.set_value(vv))
	s.value_changed.connect(func(_v): _apply_preview())
	h.add_child(s)
	h.add_child(sb)
	row.add_child(h)
	parent.add_child(row)
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
	var work_m := _caps.work_m()
	_wet_btn.color = _color_from(_specs.get("wet_color"), _caps.wet_color)
	_dry_btn.color = _color_from(_specs.get("dry_color"), _caps.dry_color)
	_set_range(_offx, -work_m * 0.5, work_m * 0.5)
	_set_range(_offz, -work_m * 0.5, work_m * 0.5)
	_set_slider(_offx, clampf(float(_specs.get("print_offset_x", 0.0)),
		-_work_half(), _work_half()))
	_set_slider(_offz, clampf(float(_specs.get("print_offset_z", 0.0)),
		-_work_half(), _work_half()))
	var scale_v := maxf(float(_specs.get("print_scale", 1.0)), _scale.min_value)
	_set_slider(_scale, minf(scale_v, _scale.max_value))
	if _mode != null:
		var def_mode := _caps.default_print_mode
		_mode.select(1 if str(_specs.get("print_mode", def_mode)) != "solid" else 0)
	if _nozzle != null:
		_set_slider(_nozzle, float(_specs.get("nozzle_diameter_mm",
			_specs.get("filament_diameter_mm", _caps.nozzle_mm))))
		_set_slider(_wall, float(_specs.get("line_width_mm", _caps.line_width_mm)))
		_set_slider(_layer, float(_specs.get("layer_height_mm", _caps.layer_height_mm)))
		_set_slider(_speed, float(_specs.get("print_speed_mm_s", _caps.print_speed_mm_s)))
	if _mesh != null and _runtime != null:
		_runtime.begin_print_preview(_mesh, _mesh_path)
		_apply_preview()
	elif _caps.show_part_presets and _preset != null and _preset.item_count > 1:
		# Auto-load first part preset so trash / kit printers always have a preview.
		_preset.select(1)
		_on_preset_selected(1)
	else:
		_refresh_studio_mesh()
	_recompute_estimate()


func _work_half() -> float:
	return _caps.work_m() * 0.5 if _caps != null else 1.5


func _rebuild_preset_menu() -> void:
	if _preset == null or _caps == null:
		return
	_preset.clear()
	_presets = _caps.part_presets()
	_preset.add_item("— custom / Load STL… —", 0)
	for i in _presets.size():
		var p: Dictionary = _presets[i]
		_preset.add_item(str(p.get("label", "part")), i + 1)


func _on_preset_selected(idx: int) -> void:
	if idx <= 0 or idx > _presets.size():
		_part_id = ""
		_part_label = ""
		return
	var p: Dictionary = _presets[idx - 1]
	_part_id = str(p.get("part_id", ""))
	_part_label = str(p.get("label", _part_id))
	var path := str(p.get("stl_path", ""))
	if path.is_empty():
		return
	_load_stl_path(path, false)
	if _mesh != null and _caps != null:
		var a := _mesh.get_aabb().size
		var work_m := _caps.work_m()
		var fit := minf(minf(work_m / maxf(a.x, 0.001), work_m / maxf(a.z, 0.001)),
			work_m / maxf(a.y, 0.001))
		_set_range(_scale, _caps.scale_lo, maxf(fit * 1.4, 1.0))
		_set_slider(_scale, clampf(fit * 0.85, _caps.scale_lo, _scale.max_value))
		_apply_preview()
		_recompute_estimate()
		_status.text = "Preset: %s\n%s" % [_part_label, _status.text]


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
	_parse = StlLoader.parse_file(path, _current_opts())
	if not bool(_parse.get("ok", false)):
		_status.text = "Could not read STL: %s" % str(_parse.get("error", "?"))
		return
	_mesh = StlLoader.build_mesh(path)
	_mesh_path = path
	if _mesh == null:
		_status.text = "STL had no printable geometry."
		return
	if auto_fit and _caps != null:
		var a := _mesh.get_aabb().size
		var work_m := _caps.work_m()
		var fit := minf(minf(work_m / maxf(a.x, 0.001), work_m / maxf(a.z, 0.001)),
			work_m / maxf(a.y, 0.001))
		_set_range(_scale, _caps.scale_lo, maxf(fit * 1.5, 1.0))
		_set_slider(_scale, clampf(fit * 0.8, _scale.min_value, _scale.max_value))
	if _runtime != null:
		_runtime.begin_print_preview(_mesh, _mesh_path)
	_apply_preview()
	_recompute_estimate()


func _apply_preview() -> void:
	if _runtime != null and is_instance_valid(_runtime):
		_runtime.update_print_preview(Vector2(_offx.value, _offz.value), _scale.value,
			_wet_btn.color, _dry_btn.color)
	_refresh_studio_mesh()


func _on_nozzle_changed(v: float) -> void:
	if _caps == null:
		return
	_set_slider(_wall, clampf(v, _wall.min_value, _wall.max_value))
	_set_slider(_layer, _caps.suggested_layer_for_nozzle(v))
	_on_slicer_changed()


func _on_slicer_changed() -> void:
	if not _mesh_path.is_empty():
		_parse = StlLoader.parse_file(_mesh_path, _current_opts())
	_recompute_estimate()
	_sync_layer_slider()
	_rebuild_overlay()
	_apply_preview()


func _current_opts() -> Dictionary:
	return {
		"mode": "vase" if (_mode != null and _mode.selected == 1) else "solid",
		"nozzle_mm": float(_nozzle.value),
		"line_width_mm": float(_wall.value),
		"layer_height_mm": float(_layer.value),
		"print_speed_mm_s": float(_speed.value) if _speed != null else 40.0,
		"scale": float(_scale.value),
	}


func _recompute_estimate() -> void:
	if _parse.is_empty() or not bool(_parse.get("ok", false)):
		return
	var solid: float = float(_parse.get("solid_volume_mm3", _parse.get("volume_mm3", 0.0)))
	var bmin: Vector3 = _parse.get("bounds_min", Vector3.ZERO)
	var bmax: Vector3 = _parse.get("bounds_max", Vector3.ZERO)
	var opts := _current_opts()
	var vol := StlLoader.estimate_volume_mm3(bmin, bmax, solid, opts)
	var t := StlLoader.estimate_time_hr(bmin, bmax, opts)
	_parse["volume_mm3"] = vol
	_parse["est_time_hr"] = t
	var lh := maxf(float(opts.get("layer_height_mm", 0.8)), 0.05)
	var height := maxf(bmax.z - bmin.z, lh)
	_parse["layer_count"] = clampi(int(ceil(height / lh)), 1, 5000)
	var mode_txt := "spiral vase" if (_mode != null and _mode.selected == 1) else "solid"
	var time_txt := ("~%.0f min" % (t * 60.0)) if t < 1.0 else ("~%.1f h" % t)
	var mat_txt := ("~%.0f g" % (vol * 0.001 * 0.95)) if (_caps != null \
			and not _caps.print_persist) else ("~%.1f L" % (vol / 1_000_000.0))
	_status.text = "%s • %d tris • %s • %d layers\n%s material • %s print (sim)" % [
		_mesh_path.get_file(), int(_parse.get("triangles", 0)), mode_txt,
		int(_parse.get("layer_count", 1)), mat_txt, time_txt]
	_sync_layer_slider()


func _refresh_studio_mesh() -> void:
	if _holder == null:
		return
	# Preserve the bed plane; rebuild solid + toolpath.
	if _solid_mi != null and is_instance_valid(_solid_mi):
		_solid_mi.queue_free()
	_solid_mi = null
	if _path_mi != null and is_instance_valid(_path_mi):
		_path_mi.queue_free()
	_path_mi = null
	if _mesh == null:
		return
	var sc := maxf(_scale.value, 0.01)
	var off := Vector2(_offx.value, _offz.value)
	_solid_mi = MeshInstance3D.new()
	_solid_mi.name = "PrintSolid"
	_solid_mi.mesh = _mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(_wet_btn.color.r, _wet_btn.color.g, _wet_btn.color.b, 0.92)
	mat.roughness = 0.55
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = _wet_btn.color * 0.25
	mat.emission_energy_multiplier = 0.35
	_solid_mi.material_override = mat
	# Mesh is already Y-up metres from StlLoader; seat on bed center + offset.
	_solid_mi.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * sc),
		Vector3(off.x, 0.001, off.y))
	_holder.add_child(_solid_mi)
	_path_mi = MeshInstance3D.new()
	_path_mi.name = "PrintToolpath"
	_holder.add_child(_path_mi)
	var aabb := _mesh.get_aabb()
	aabb.position *= sc
	aabb.size *= sc
	aabb.position += Vector3(off.x, 0.0, off.y)
	_cam_target = aabb.get_center()
	_dist = clampf(aabb.size.length() * 1.45, 0.15, 8.0)
	_rebuild_overlay()
	_apply_view()


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
	var lc := maxi(int(_parse.get("layer_count", 1)), 1)
	_layer_slider.max_value = lc
	_layer_slider.set_value_no_signal(lc)
	_max_layer = lc
	if _layer_lbl != null:
		_layer_lbl.text = "Layers: all"


func _on_layer_slider(val: float) -> void:
	_max_layer = int(val)
	if _layer_lbl != null:
		var lc := maxi(int(_parse.get("layer_count", 1)), 1)
		_layer_lbl.text = "Layers: all" if _max_layer >= lc else "Layers: ≤%d" % _max_layer
	_rebuild_overlay()


func _rebuild_overlay() -> void:
	if _path_mi == null or not is_instance_valid(_path_mi):
		return
	if not bool(_parse.get("ok", false)):
		_path_mi.mesh = null
		return
	var pts: PackedVector3Array = _parse.get("points", PackedVector3Array())
	var ext: PackedInt32Array = _parse.get("extruding", PackedInt32Array())
	if pts.size() < 2:
		_path_mi.mesh = null
		return
	var lh := maxf(float(_parse.get("layer_height_mm", 0.8)), 0.05)
	var bmin: Vector3 = _parse.get("bounds_min", Vector3.ZERO)
	var bmax: Vector3 = _parse.get("bounds_max", Vector3.ZERO)
	var cx := (bmin.x + bmax.x) * 0.5
	var cy := (bmin.y + bmax.y) * 0.5
	var z_base := bmin.z
	var sc := maxf(_scale.value, 0.01)
	var off := Vector2(_offx.value, _offz.value)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var col_ext := Color(0.55, 0.95, 0.70)
	var col_tra := Color(0.95, 0.32, 0.28)
	var added := false
	for i in range(1, pts.size()):
		var extruding := i < ext.size() and ext[i] != 0
		if not extruding and not _show_travels:
			continue
		var li := int(floor((pts[i].z - z_base) / lh))
		if li >= _max_layer:
			continue
		st.set_color(col_ext if extruding else col_tra)
		st.add_vertex(_path_to_studio(pts[i - 1], cx, cy, z_base, sc, off))
		st.set_color(col_ext if extruding else col_tra)
		st.add_vertex(_path_to_studio(pts[i], cx, cy, z_base, sc, off))
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
	_path_mi.transform = Transform3D.IDENTITY


## STL/toolpath mm (X,Y bed, Z up) → studio metres Y-up, centered on bed + offset.
func _path_to_studio(p: Vector3, cx: float, cy: float, z_base: float,
		sc: float, off: Vector2) -> Vector3:
	return Vector3(
		(p.x - cx) * 0.001 * sc + off.x,
		(p.z - z_base) * 0.001 * sc + 0.001,
		-(p.y - cy) * 0.001 * sc + off.y)


func _update_viewport_size() -> void:
	if _vp == null or _vpc == null:
		return
	var sz := _vpc.size
	if sz.x < 2.0 or sz.y < 2.0:
		return
	var ss := 1.25
	_vp.size = Vector2i(
		clampi(int(sz.x * ss), 320, 2560),
		clampi(int(sz.y * ss), 320, 2560))


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
			_dist = maxf(_dist * 0.88, 0.08)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(_dist * 1.12, 12.0)
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


func _on_start_pressed() -> void:
	if _mesh == null or _mesh_path.is_empty() or _parse.is_empty():
		_status.text = "Load an STL first."
		return
	if _view == null or not _view.has_method("start_machine_job") or _caps == null:
		return
	var stored_path := _copy_stl_to_user(_mesh_path)
	var wet := _wet_btn.color
	var dry := _dry_btn.color
	var opts := _current_opts()
	var job := StlLoader.parse_file(_mesh_path, opts)
	if not bool(job.get("ok", false)):
		job = _parse
	var kind := _caps.machine_kind if not _caps.machine_kind.is_empty() else "fdm"
	var job_name := _part_label if not _part_label.is_empty() else ("%s Print" % _caps.display_name)
	var part_id := _part_id
	if part_id.is_empty() and not _caps.print_persist:
		part_id = _mesh_path.get_file().get_basename().to_snake_case()
	var extra := {
		"machine_kind": kind,
		"print_persist": _caps.print_persist,
		"bed_lowering": _caps.is_bed_lowering(),
		"print_mesh_path": stored_path,
		"print_offset_x": float(_offx.value),
		"print_offset_z": float(_offz.value),
		"print_scale": float(_scale.value),
		"print_mode": String(opts.get("mode", "solid")),
		"nozzle_diameter_mm": float(_nozzle.value),
		"filament_diameter_mm": float(_nozzle.value),
		"line_width_mm": float(_wall.value),
		"layer_height_mm": float(_layer.value),
		"print_speed_mm_s": float(_speed.value) if _speed != null else _caps.print_speed_mm_s,
		"wet_color": [wet.r, wet.g, wet.b],
		"dry_color": [dry.r, dry.g, dry.b],
		"job_part_id": part_id,
		"job_part_label": job_name,
		"job_part_count": 1,
		"job_material_kind": _caps.job_material_kind,
	}
	var fallback_id := "mud_print" if _caps.print_persist else "trash_print"
	var ok: bool = _view.call("start_machine_job", _item_id, job,
		part_id if not part_id.is_empty() else fallback_id,
		job_name, 1, extra)
	if ok:
		close()
	else:
		_status.text = "Could not start the print."


func _copy_stl_to_user(src: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PRINTS_DIR))
	var id := "print_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	var dst := "%s/%s.stl" % [PRINTS_DIR, id]
	var fin := FileAccess.open(src, FileAccess.READ)
	if fin == null:
		return src
	var bytes := fin.get_buffer(fin.get_length())
	fin.close()
	var fout := FileAccess.open(dst, FileAccess.WRITE)
	if fout == null:
		return src
	fout.store_buffer(bytes)
	fout.close()
	return dst


static func _color_from(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return fallback
