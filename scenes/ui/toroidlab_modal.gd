extends Control

## The toroid designer: a bent-tube torus on structural pipe fittings — its
## size, rib count and tube, the rings round it, bracing and tension lines
## between the rings, a pleated origami canopy of scored corrugated plastic
## and a ring of solar panels over the crown — with a bill of materials, the
## cut list with every bend, full-size bend templates and the canopy's
## nested sheets.
##
## Left:   built-in designs and the player's library.
## Centre: the structure in a 3D studio (explode, build scrub; click a part
##         to highlight its class), the section through one rib (the
##         profile, rings, canopy and panel with their dimensions), the
##         canopy sheets as they will be cut, and the schedule.
## Right:  torus, tube and ribs, rings, bracing, canopy, solar, fabrication,
##         colours, the checks, the parts, the bill of materials, export.
## Footer: place a new toroid in the world, or apply to the placed one.
##
## The modal and the dome designer share their shape (DomeLab's studio,
## undo / redo of whole spec snapshots, the row helpers, the DXF / SVG
## writers): everything reads one solved ToroidLabDesign, so the model, the
## section, the sheets and the files always agree.

const MODAL_NAME := "toroidlab_designer"
const WANT := Vector2(1600, 960)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.15
const EXPORT_ROOT := "user://toroidlab_designs"

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

var _explode := 0.0
var _assembly := 1.0
var _playing := false
var _highlight := ""
var _library: Array = []
var _hover_frame := 0

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
var _section_canvas: Control
var _sheet_canvas: Control
var _sheet_scroll: ScrollContainer
var _schedule_scroll: ScrollContainer
var _schedule_text: RichTextLabel
var _explode_slider: HSlider
var _assembly_slider: HSlider
var _play_btn: Button
var _hover_lbl: Label
var _torus_box: VBoxContainer
var _tube_box: VBoxContainer
var _ring_box: VBoxContainer
var _brace_box: VBoxContainer
var _canopy_box: VBoxContainer
var _solar_box: VBoxContainer
var _fab_box: VBoxContainer
var _color_box: VBoxContainer
var _parts_box: VBoxContainer
var _bom_lbl: Label
var _bom_box: VBoxContainer
var _warn_box: VBoxContainer
var _export_status: Label
var _apply_btn: Button
var _place_btn: Button
var _file_dialog: FileDialog

# Studio camera
var _yaw := 0.8
var _pitch := 0.4
var _dist := 14.0
var _target := Vector3(0, 1.5, 0)
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
	_spec = ToroidLabSpec.resolve(spec if not spec.is_empty() else ToroidLabPresets.overview_spec())
	_activate()


func open_for_prop(prop_id: String) -> void:
	if _active or prop_id.is_empty():
		return
	var rec := _prop_record(prop_id)
	var spec: Dictionary = rec.get("toroid_spec", {}) as Dictionary
	_bound_prop_id = prop_id
	_spec = ToroidLabSpec.resolve(spec if not spec.is_empty() else ToroidLabPresets.overview_spec())
	_activate()


func is_open() -> bool:
	return _active


func _activate() -> void:
	_undo.clear()
	_redo.clear()
	_highlight = ""
	_explode = 0.0
	_assembly = 1.0
	_playing = false
	_library = ToroidLabPresets.load_library()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	UiFit.keep_fitted(_panel, WANT)
	_apply_btn.visible = not _bound_prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _bound_prop_id.is_empty() else "Place in world"
	_refresh_design_list()
	_built_key = ""
	_rebuild_now()
	_frame_camera()


func close() -> void:
	if not _active:
		return
	_active = false
	_playing = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


func _process(delta: float) -> void:
	if _rebuild_timer > 0.0:
		_rebuild_timer -= delta
		if _rebuild_timer <= 0.0:
			_rebuild_now()
	if _playing:
		_assembly = minf(_assembly + delta * 0.12, 1.0)
		_assembly_slider.set_value_no_signal(_assembly)
		_rebuild_studio()
		if _assembly >= 1.0:
			_playing = false
			_play_btn.text = "Play build"


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
	_file_dialog.title = "Choose a folder for the fabrication files"
	_file_dialog.dir_selected.connect(_on_export_dir_selected)
	add_child(_file_dialog)


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var icon := TextureRect.new()
	icon.texture = UiIcons.icon("target", 22)
	icon.modulate = UITheme.C_AMBER
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(icon)
	var title := Label.new()
	title.text = "Toroid designer"
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title.add_theme_color_override("font_color", UITheme.C_TEXT)
	row.add_child(title)
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(260, 0)
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
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_design_list = ItemList.new()
	_design_list.custom_minimum_size = Vector2(0, 260)
	_design_list.auto_height = true
	_design_list.item_activated.connect(_on_design_activated)
	_design_list.item_selected.connect(_on_design_activated)
	box.add_child(_design_list)
	var lib := HBoxContainer.new()
	var save := Button.new()
	save.text = "Save design"
	save.tooltip_text = "Keep this design in your library (every world)"
	UITheme.style_button(save)
	save.pressed.connect(_on_save_design)
	lib.add_child(save)
	var forget := Button.new()
	forget.text = "Forget"
	forget.tooltip_text = "Remove the selected saved design"
	UITheme.style_button(forget)
	forget.pressed.connect(_on_forget_design)
	lib.add_child(forget)
	box.add_child(lib)
	var how := Label.new()
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	how.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	how.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	how.text = ("Every rib is one circle — the torus' minor circle — cut where it meets the ground and " +
		"split into bent arcs. Angles on that circle run from its outer equator (0°) up over the crown " +
		"(90°) to the throat (180°). Rings, the canopy's edges and the panels are placed by those angles.")
	box.add_child(how)
	return col[0]


func _build_centre() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_tabs = TabBar.new()
	_tabs.add_tab("Structure")
	_tabs.add_tab("Section")
	_tabs.add_tab("Canopy sheets")
	_tabs.add_tab("Schedule")
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
	_section_canvas = SectionCanvas.new()
	_section_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_section_canvas.visible = false
	_section_canvas.set("owner_modal", self)
	_view_stack.add_child(_section_canvas)
	_sheet_scroll = ScrollContainer.new()
	_sheet_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sheet_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_sheet_scroll.visible = false
	_view_stack.add_child(_sheet_scroll)
	_sheet_canvas = SheetCanvas.new()
	_sheet_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sheet_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sheet_canvas.set("owner_modal", self)
	_sheet_scroll.add_child(_sheet_canvas)
	_schedule_scroll = ScrollContainer.new()
	_schedule_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_schedule_scroll.visible = false
	_view_stack.add_child(_schedule_scroll)
	_schedule_text = RichTextLabel.new()
	_schedule_text.bbcode_enabled = false
	_schedule_text.fit_content = true
	_schedule_text.scroll_active = false
	_schedule_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_schedule_text.add_theme_font_override("normal_font", UITheme.font("regular", true))
	_schedule_text.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	_schedule_text.add_theme_color_override("default_color", UITheme.C_TEXT)
	_schedule_scroll.add_child(_schedule_text)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var el := Label.new()
	el.text = "Explode"
	bar.add_child(el)
	_explode_slider = HSlider.new()
	_explode_slider.min_value = 0.0
	_explode_slider.max_value = 1.0
	_explode_slider.step = 0.01
	_explode_slider.custom_minimum_size = Vector2(120, 0)
	_explode_slider.value_changed.connect(func(v): _explode = v; _rebuild_studio())
	bar.add_child(_explode_slider)
	var bl := Label.new()
	bl.text = "Build"
	bar.add_child(bl)
	_assembly_slider = HSlider.new()
	_assembly_slider.min_value = 0.0
	_assembly_slider.max_value = 1.0
	_assembly_slider.step = 0.005
	_assembly_slider.value = 1.0
	_assembly_slider.custom_minimum_size = Vector2(140, 0)
	_assembly_slider.value_changed.connect(func(v): _assembly = v; _playing = false; _rebuild_studio())
	bar.add_child(_assembly_slider)
	_play_btn = Button.new()
	_play_btn.text = "Play build"
	_play_btn.tooltip_text = "Ground rings, inner column, walls, top arcs and rings, bracing, canopy, panels"
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(_on_play_build)
	bar.add_child(_play_btn)
	var clear := Button.new()
	clear.text = "Clear highlight"
	UITheme.style_button(clear)
	clear.pressed.connect(func(): _set_highlight(""))
	bar.add_child(clear)
	bar.add_child(IconButton.make("scan", "Frame the structure", func(): _yaw = 0.8; _pitch = 0.4; _frame_camera()))
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
	e.ambient_light_sky_contribution = 1.0
	e.ambient_light_energy = 0.9
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.ssao_enabled = true
	e.ssao_radius = 0.5
	e.ssao_intensity = 1.4
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.05
	env.environment = e
	_studio.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-52, 35, 0)
	key.light_energy = 1.5
	key.light_color = Color(1.0, 0.96, 0.9)
	key.shadow_enabled = true
	key.light_angular_distance = 1.0
	key.directional_shadow_max_distance = 80.0
	key.shadow_normal_bias = 1.5
	_studio.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -140, 0)
	fill.light_energy = 0.25
	fill.light_color = Color(0.8, 0.88, 1.0)
	_studio.add_child(fill)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.13, 0.125, 0.12)
	gmat.roughness = 0.95
	ground.material_override = gmat
	_studio.add_child(ground)
	var person := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.2
	cap.height = 1.75
	person.mesh = cap
	person.position = Vector3(0, 0.875, 0)
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.45, 0.48, 0.55)
	person.material_override = pm
	person.name = "ScalePerson"
	_studio.add_child(person)
	_holder = Node3D.new()
	_holder.name = "Holder"
	_studio.add_child(_holder)
	_camera = Camera3D.new()
	_camera.fov = 45.0
	_camera.far = 500.0
	_studio.add_child(_camera)
	_update_camera()


func _build_right() -> Control:
	var col := _scroll_column(400)
	var box: VBoxContainer = col[1]
	var sec := Collapsible.make("Torus", true)
	box.add_child(sec)
	_torus_box = sec.body
	sec = Collapsible.make("Tube and ribs", true)
	box.add_child(sec)
	_tube_box = sec.body
	sec = Collapsible.make("Rings", true)
	box.add_child(sec)
	_ring_box = sec.body
	sec = Collapsible.make("Bracing and tension lines", false)
	box.add_child(sec)
	_brace_box = sec.body
	sec = Collapsible.make("Origami canopy", false)
	box.add_child(sec)
	_canopy_box = sec.body
	sec = Collapsible.make("Solar", false)
	box.add_child(sec)
	_solar_box = sec.body
	sec = Collapsible.make("Fabrication", false)
	box.add_child(sec)
	_fab_box = sec.body
	sec = Collapsible.make("Colours", false)
	box.add_child(sec)
	_color_box = sec.body
	box.add_child(SectionHeader.make("Checks", "circle-check"))
	_warn_box = VBoxContainer.new()
	box.add_child(_warn_box)
	sec = Collapsible.make("Parts (click to highlight)", true)
	box.add_child(sec)
	_parts_box = sec.body
	box.add_child(SectionHeader.make("Bill of materials", "list"))
	_bom_lbl = Label.new()
	_bom_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bom_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(_bom_lbl)
	_bom_box = VBoxContainer.new()
	_bom_box.add_theme_constant_override("separation", 1)
	box.add_child(_bom_box)
	box.add_child(SectionHeader.make("Fabrication files", "download"))
	var ex := HFlowContainer.new()
	ex.add_theme_constant_override("h_separation", UITheme.SPACE_XS)
	ex.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
	for spec_btn in [["Export files", "Canopy sheet DXF + SVG, bend templates, tube CSV, BOM CSV, cut sheet, JSON", _on_export],
			["Save to…", "Choose a folder for the files", _on_export_to],
			["Open folder", "Show the exported files", _on_open_folder],
			["Copy cut sheet", "Put the whole schedule on the clipboard", _on_copy_cut_sheet]]:
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
	hint.text = "Drag to orbit · wheel to zoom · click a tube, fitting, canopy piece or panel to highlight its kind"
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(hint)
	_apply_btn = Button.new()
	_apply_btn.text = "Apply to placed structure"
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
	else:
		var g: Dictionary = _spec.get(group, {})
		g[key] = value
		_spec[group] = g
	_queue_rebuild()


func _queue_rebuild() -> void:
	_rebuild_timer = REBUILD_DELAY


## Re-solve and refresh every panel. The settings rows are rebuilt only when
## the rows themselves change (the bracing list, the ring list), so a spin
## box never loses focus mid-edit.
func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = ToroidLabSpec.resolve(_spec)
	_design = ToroidLabDesign.solve(_spec)
	var ring_names := ",".join((_design["frame"]["rings"] as Array).map(func(r): return str(r["name"])))
	var key := "%d|%s|%s|%s" % [(_spec["bracing"] as Array).size(), ring_names, str(_spec["canopy"]["enabled"]),
		str(_spec["solar"]["enabled"])]
	if key != _built_key:
		_built_key = key
		_build_settings_rows()
	_sync_settings()
	_rebuild_studio()
	_refresh_parts()
	_refresh_bom()
	_refresh_checks()
	_refresh_header()
	_schedule_text.text = ToroidLabBom.cut_sheet_text(_design)
	_section_canvas.queue_redraw()
	_sheet_canvas.queue_redraw()
	_show_view()
	_update_undo_buttons()


func _refresh_header() -> void:
	if not _name_edit.has_focus():
		_name_edit.text = str(_spec["name"])
	var st: Dictionary = _design.get("stats", {})
	var bom: Dictionary = _design.get("bom", {})
	var so: Dictionary = _design.get("solar", {})
	_subtitle.text = "%s · %s high · %s floor · %s · %s" % [ToroidLabSpec.describe(_spec),
		ToroidLabSpec.fmt_m(float(st.get("height_m", 0.0))), ToroidLabSpec.fmt_area(float(st.get("floor_area_m2", 0.0))),
		("%.1f kW solar" % (float(so.get("total_w", 0.0)) / 1000.0)) if int(so.get("count", 0)) > 0 else "no panels",
		ToroidLabSpec.fmt_kg(float(bom.get("mass_kg", 0.0)))]


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


func _note(parent: Container, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	parent.add_child(l)
	return l


## A spin box bound to spec[group][key] (shown × scale).
func _bind_spin(parent: Container, label: String, group: String, key: String, min_v: float, max_v: float,
		step: float, suffix: String, tip: String = "", scale: float = 1.0) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.suffix = suffix
	s.value_changed.connect(func(v): _edit(group, key, (int(v) if step >= 1.0 and scale == 1.0 else v / scale)))
	_row(parent, label, s, tip)
	_bindings.append({"ctl": s, "group": group, "key": key, "scale": scale})
	return s


func _bind_check(parent: Container, text: String, group: String, key: String, tip: String = "") -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.toggled.connect(func(v): _edit(group, key, v))
	parent.add_child(c)
	_bindings.append({"ctl": c, "group": group, "key": key, "scale": 1.0})
	return c


func _bind_option(parent: Container, label: String, group: String, key: String, items: Array, tip: String = "") -> OptionButton:
	var o := OptionButton.new()
	for i in items.size():
		o.add_item(str(items[i][1]), i)
		o.set_item_metadata(i, items[i][0])
	o.item_selected.connect(func(idx): _edit(group, key, o.get_item_metadata(idx)))
	_row(parent, label, o, tip)
	_bindings.append({"ctl": o, "group": group, "key": key, "scale": 1.0})
	return o


func _select_meta(o: OptionButton, value: Variant) -> void:
	for i in o.item_count:
		var m: Variant = o.get_item_metadata(i)
		if str(m) == str(value):
			o.select(i)
			return


func _table_items(order: Array, table: Dictionary) -> Array:
	var out: Array = []
	for id in order:
		out.append([id, str(table[id]["label"])])
	return out


func _build_settings_rows() -> void:
	_bindings.clear()
	for b in [_torus_box, _tube_box, _ring_box, _brace_box, _canopy_box, _solar_box, _fab_box, _color_box]:
		_clear(b)
	# --- torus ----------------------------------------------------------------
	for m in [["inner_r_m", "Inner radius at the ground", "Where the inner wall meets the ground"],
			["outer_r_m", "Outer radius", "The widest point of the ring"],
			["height_m", "Height", "The top of the tube centreline"]]:
		var s := SpinBox.new()
		s.min_value = 0.1
		s.max_value = 60.0
		s.step = 0.005
		s.suffix = " m"
		s.value_changed.connect(_on_measure_changed.bind(str(m[0])))
		_row(_torus_box, str(m[1]), s, str(m[2]))
		_bindings.append({"ctl": s, "group": "_measure", "key": str(m[0]), "scale": 1.0})
	_bind_spin(_torus_box, "Ribs (segments)", "torus", "segments", ToroidLabSpec.MIN_SEGMENTS, ToroidLabSpec.MAX_SEGMENTS,
		1.0, "", "How many ribs round the ring")
	_bind_spin(_torus_box, "Ground rings' height", "torus", "base_y_m", 0.0, 1.0, 0.005, " m",
		"The ground rings' centreline above the ground (feet, base plates)")
	_bind_spin(_torus_box, "Rotation", "torus", "rotation_deg", -180.0, 180.0, 0.5, "°", "Rib 0's bearing")
	_bind_spin(_torus_box, "Inner top ring at", "torus", "inner_top_deg", -1.0, 230.0, 0.5, "°",
		"Where the top arcs end on the inner ring (−1 = symmetric with the ground cut)")
	var tor_note := _note(_torus_box, "")
	tor_note.name = "torus_note"
	# --- tube and ribs ---------------------------------------------------------
	_bind_option(_tube_box, "Tube", "tube", "material", _table_items(ToroidLabMaterials.TUBE_ORDER, ToroidLabMaterials.TUBES),
		"The stock the ribs, rings, posts and braces are bent from")
	_bind_spin(_tube_box, "Arcs per rib", "ribs", "pieces", 1, 6, 1.0, "",
		"Bent arcs from the outer ground ring to the inner top ring (joined by couplers)")
	_bind_spin(_tube_box, "Inner wall every", "ribs", "inner_every", 0, 12, 1.0, " ribs",
		"Every Nth rib continues down the inner wall (0 = none)")
	_bind_spin(_tube_box, "Inner wall offset", "ribs", "inner_offset", 0, 12, 1.0, "", "Which rib the inner arcs start on")
	var skip := LineEdit.new()
	skip.placeholder_text = "e.g. 17, 19"
	skip.text_submitted.connect(func(t): _edit("ribs", "inner_skip", ToroidLabSpec._int_list(t)))
	skip.focus_exited.connect(func(): _edit("ribs", "inner_skip", ToroidLabSpec._int_list(skip.text)))
	_row(_tube_box, "Leave open (rib numbers)", skip, "Ribs whose inner arc is left out — a doorway into the throat")
	_bindings.append({"ctl": skip, "group": "ribs", "key": "inner_skip", "scale": 1.0})
	_bind_check(_tube_box, "Straight post beside each inner arc", "ribs", "inner_posts")
	_bind_check(_tube_box, "Base foot under every ground end", "ribs", "feet")
	# --- rings -----------------------------------------------------------------
	_bind_check(_ring_box, "Outer ground ring", "rings", "ground_out")
	_bind_check(_ring_box, "Inner ground ring", "rings", "ground_in")
	_bind_check(_ring_box, "Inner top ring", "rings", "inner_top")
	_bind_check(_ring_box, "Crown ring", "rings", "crown")
	_bind_spin(_ring_box, "Crown ring at", "rings", "crown_deg", -40.0, 220.0, 0.5, "°",
		"Its angle on the minor circle (90° = the top)")
	var extra := LineEdit.new()
	extra.placeholder_text = "angles, e.g. 20, 150"
	extra.text_submitted.connect(func(t): _edit("rings", "extra_deg", ToroidLabSpec._float_list(t)))
	extra.focus_exited.connect(func(): _edit("rings", "extra_deg", ToroidLabSpec._float_list(extra.text)))
	_row(_ring_box, "More rings at", extra, "Extra rings by their angle on the minor circle")
	_bindings.append({"ctl": extra, "group": "rings", "key": "extra_deg", "scale": 1.0})
	_bind_spin(_ring_box, "Bays per ring tube", "rings", "piece_bays", 1, 48, 1.0, " bays", "How many bays one bent ring tube spans")
	var ring_list := _note(_ring_box, "")
	ring_list.name = "ring_list"
	# --- bracing ---------------------------------------------------------------
	var rings: Array = _design.get("frame", {}).get("rings", [])
	var ring_items: Array = []
	for r in rings:
		ring_items.append([int(r["index"]), "%d · %s" % [int(r["index"]), str(r["name"])]])
	var braces: Array = _spec["bracing"]
	for i in braces.size():
		_build_brace_row(i, ring_items)
	var add := Button.new()
	add.text = "Add bracing between rings"
	UITheme.style_button(add)
	add.pressed.connect(_on_add_brace)
	_brace_box.add_child(add)
	_note(_brace_box, "Tension lines are wire rope with a turnbuckle and an eye clamp at each end; braces are straight tube on swivel clamps.")
	# --- canopy ----------------------------------------------------------------
	_bind_check(_canopy_box, "Canopy", "canopy", "enabled")
	if bool(_spec["canopy"]["enabled"]):
		_bind_option(_canopy_box, "Fold", "canopy", "fold", [["diamond", ToroidLabSpec.FOLD_LABELS["diamond"]],
			["plain", ToroidLabSpec.FOLD_LABELS["plain"]]])
		_bind_option(_canopy_box, "Sheet", "canopy", "sheet", _table_items(ToroidLabMaterials.SHEET_ORDER, ToroidLabMaterials.SHEETS))
		_bind_spin(_canopy_box, "Outer edge at", "canopy", "phi_out_deg", -60.0, 170.0, 0.1, "°", "The canopy's outer edge, on the minor circle")
		_bind_spin(_canopy_box, "Inner edge at", "canopy", "phi_in_deg", -50.0, 200.0, 0.1, "°", "The canopy's inner edge")
		_bind_spin(_canopy_box, "Peak at", "canopy", "phi_peak_deg", -50.0, 200.0, 0.1, "°", "The pleat's peak, mid-bay")
		_bind_spin(_canopy_box, "Seam drop, outer", "canopy", "seam_out_mm", 0.0, 1000.0, 1.0, " mm", "How far inside the rib the seam's outer corner hangs")
		_bind_spin(_canopy_box, "Seam drop, inner", "canopy", "seam_in_mm", 0.0, 1000.0, 1.0, " mm", "How far inside the rib the seam's inner corner hangs")
		_bind_spin(_canopy_box, "Peak drop", "canopy", "peak_mm", 0.0, 1000.0, 1.0, " mm", "How far inside the ribs the peak sits")
		_bind_spin(_canopy_box, "Pleat depth, outer", "canopy", "valley_out_mm", 0.0, 2000.0, 1.0, " mm", "The outer valley's depth inside the ribs")
		_bind_spin(_canopy_box, "Pleat depth, inner", "canopy", "valley_in_mm", 0.0, 2000.0, 1.0, " mm", "The inner valley's depth inside the ribs")
		_bind_spin(_canopy_box, "Flange", "canopy", "flange_mm", 0.0, 150.0, 0.1, " mm", "Folded up along each seam and bolted to the neighbour's (50.8 mm = 2\")")
		_bind_spin(_canopy_box, "Bolts per seam", "canopy", "bolts_per_seam", 0, 12, 1.0, "")
		_bind_option(_canopy_box, "Bolt", "canopy", "bolt", _table_items(DomeLabMaterials.BOLT_ORDER, DomeLabMaterials.BOLTS))
		_bind_spin(_canopy_box, "A sector every", "canopy", "every", 1, 12, 1.0, " bays")
		var cn_note := _note(_canopy_box, "")
		cn_note.name = "canopy_note"
	# --- solar -----------------------------------------------------------------
	_bind_check(_solar_box, "Solar panels", "solar", "enabled")
	if bool(_spec["solar"]["enabled"]):
		_bind_option(_solar_box, "Panel", "solar", "model", _table_items(ToroidLabMaterials.PANEL_ORDER, ToroidLabMaterials.PANELS))
		_bind_spin(_solar_box, "Panels per bay", "solar", "per_bay", 0, 3, 1.0, "")
		_bind_spin(_solar_box, "A bay every", "solar", "every", 1, 12, 1.0, " bays")
		_bind_spin(_solar_box, "Centred at", "solar", "centre_deg", -40.0, 200.0, 0.5, "°", "The panels' centre on the minor circle (90° = the top)")
		_bind_spin(_solar_box, "Above the ribs", "solar", "standoff_mm", -50.0, 300.0, 1.0, " mm", "Panel above the rib centreline")
		_bind_spin(_solar_box, "Series", "solar", "series", 0, 96, 1.0, " S", "Panels in a string (0 = let the graph choose)")
		_bind_spin(_solar_box, "Parallel", "solar", "parallel", 0, 96, 1.0, " P", "Strings in parallel")
		var so_note := _note(_solar_box, "")
		so_note.name = "solar_note"
	# --- fabrication -----------------------------------------------------------
	_bind_option(_fab_box, "Units", "fabrication", "units", [["in", "Inches (feet and inches)"], ["mm", "Millimetres"]])
	_bind_spin(_fab_box, "Kerf", "fabrication", "kerf_mm", 0.0, 10.0, 0.1, " mm", "Saw blade width between cuts")
	_bind_spin(_fab_box, "Short of the node", "fabrication", "fitting_gap_mm", 0.0, 100.0, 0.5, " mm",
		"How far short of each fitting's centre a tube is cut")
	# --- colours ---------------------------------------------------------------
	for k in ["tube", "connector", "canopy", "panel", "cable"]:
		var cp := ColorPickerButton.new()
		cp.edit_alpha = false
		cp.custom_minimum_size = Vector2(0, 26)
		cp.color_changed.connect(func(c): _edit("colors", k, c))
		_row(_color_box, k.capitalize(), cp)
		_bindings.append({"ctl": cp, "group": "colors", "key": k, "scale": 1.0})


func _build_brace_row(i: int, ring_items: Array) -> void:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 2)
	var head := HBoxContainer.new()
	var hl := Label.new()
	hl.text = "Bracing %d" % (i + 1)
	hl.add_theme_color_override("font_color", UITheme.C_TEXT)
	hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(hl)
	head.add_child(IconButton.make("trash-2", "Remove this bracing", func(): _on_remove_brace(i)))
	card.add_child(head)
	var mk := func(label: String, key: String, items: Array) -> void:
		var o := OptionButton.new()
		for j in items.size():
			o.add_item(str(items[j][1]), j)
			o.set_item_metadata(j, items[j][0])
		o.item_selected.connect(func(idx): _edit_brace(i, key, o.get_item_metadata(idx)))
		_row(card, label, o)
		_bindings.append({"ctl": o, "group": "_brace", "key": key, "index": i, "scale": 1.0})
	mk.call("From ring", "from", ring_items)
	mk.call("To ring", "to", ring_items)
	mk.call("Pattern", "pattern", [["x", ToroidLabSpec.PATTERN_LABELS["x"]], ["diag", ToroidLabSpec.PATTERN_LABELS["diag"]],
		["zigzag", ToroidLabSpec.PATTERN_LABELS["zigzag"]]])
	mk.call("Member", "member", [["cable", ToroidLabSpec.MEMBER_LABELS["cable"]], ["tube", ToroidLabSpec.MEMBER_LABELS["tube"]]])
	mk.call("Line", "cable", _table_items(ToroidLabMaterials.CABLE_ORDER, ToroidLabMaterials.CABLES))
	for sp in [["Every", "every", 1, 48, " bays"], ["Starting at bay", "start", 0, 95, ""]]:
		var s := SpinBox.new()
		s.min_value = float(sp[2])
		s.max_value = float(sp[3])
		s.step = 1.0
		s.suffix = str(sp[4])
		var key := str(sp[1])
		s.value_changed.connect(func(v): _edit_brace(i, key, int(v)))
		_row(card, str(sp[0]), s)
		_bindings.append({"ctl": s, "group": "_brace", "key": key, "index": i, "scale": 1.0})
	card.add_child(HSeparator.new())
	_brace_box.add_child(card)


func _edit_brace(i: int, key: String, value: Variant) -> void:
	if _suppress:
		return
	var braces: Array = _spec["bracing"]
	if i < 0 or i >= braces.size():
		return
	_push_undo("brace.%d.%s" % [i, key])
	(braces[i] as Dictionary)[key] = value
	_queue_rebuild()


func _on_add_brace() -> void:
	_push_undo()
	var rings: Array = _design["frame"]["rings"]
	var b := ToroidLabSpec.BRACE_DEFAULTS.duplicate(true)
	b["to"] = mini(1, maxi(rings.size() - 1, 0))
	(_spec["bracing"] as Array).append(b)
	_rebuild_now()


func _on_remove_brace(i: int) -> void:
	var braces: Array = _spec["bracing"]
	if i < 0 or i >= braces.size():
		return
	_push_undo()
	braces.remove_at(i)
	_rebuild_now()


func _on_measure_changed(v: float, which: String) -> void:
	if _suppress:
		return
	var t: Dictionary = _spec["torus"]
	var m := ToroidLabSpec.measures(t)
	m[which] = v
	var nt := ToroidLabSpec.torus_from_measures(float(m["inner_r_m"]), float(m["outer_r_m"]), float(m["height_m"]),
		float(t["base_y_m"]), int(t["segments"]))
	if nt.is_empty():
		_status("No torus has those measures: the outer radius must be past the inner, and the height above the ground.")
		_suppress = true
		_sync_settings()
		_suppress = false
		return
	_push_undo("torus.measure." + which)
	for k in nt:
		t[k] = nt[k]
	_queue_rebuild()


func _sync_settings() -> void:
	_suppress = true
	var meas := ToroidLabSpec.measures(_spec["torus"])
	for b in _bindings:
		var c: Node = b["ctl"]
		if not is_instance_valid(c):
			continue
		var group := str(b["group"])
		var key := str(b["key"])
		var v: Variant = null
		if group == "_measure":
			v = meas[key]
		elif group == "_brace":
			var braces: Array = _spec["bracing"]
			var i := int(b["index"])
			if i < braces.size():
				v = (braces[i] as Dictionary).get(key)
		elif group.is_empty():
			v = _spec.get(key)
		else:
			v = (_spec.get(group, {}) as Dictionary).get(key)
		if v == null:
			continue
		if c is SpinBox:
			(c as SpinBox).set_value_no_signal(float(v) * float(b["scale"]))
		elif c is CheckBox:
			(c as CheckBox).set_pressed_no_signal(bool(v))
		elif c is OptionButton:
			_select_meta(c as OptionButton, v)
		elif c is LineEdit:
			if not (c as LineEdit).has_focus():
				(c as LineEdit).text = ", ".join((v as Array).map(func(x): return str(x)))
		elif c is ColorPickerButton:
			(c as ColorPickerButton).color = v as Color
	_suppress = false
	var fr: Dictionary = _design["frame"]
	var tn := _torus_box.find_child("torus_note", true, false) as Label
	if tn != null:
		tn.text = "Major radius %s, minor radius %s, centre %s up · ground cut %s below the equator · throat Ø %s" % [
			ToroidLabSpec.fmt_m(float(fr["R"])), ToroidLabSpec.fmt_m(float(fr["r"])), ToroidLabSpec.fmt_m(float(fr["hc"])),
			ToroidLabSpec.fmt_deg(float(fr["ground_deg"])), ToroidLabSpec.fmt_m(float(_design["stats"]["throat_r_m"]) * 2.0)]
	var rl := _ring_box.find_child("ring_list", true, false) as Label
	if rl != null:
		var lines: Array = []
		for r in fr["rings"]:
			lines.append("%d · %s at %s — Ø %s%s" % [int(r["index"]), str(r["name"]), ToroidLabSpec.fmt_deg(float(r["deg"])),
				ToroidLabSpec.fmt_m(float(r["radius_m"]) * 2.0), "" if bool(r["on_node"]) else " (under the ribs)"])
		rl.text = "\n".join(lines)
	var cn := _canopy_box.find_child("canopy_note", true, false) as Label
	if cn != null:
		var c: Dictionary = _design["canopy"]
		var pcs: Array = c.get("pieces", [])
		if not pcs.is_empty():
			var p: Dictionary = pcs[0]
			cn.text = "%d sectors · pieces %s × %s · %d sheets · folds %s" % [(c["sectors"] as Array).size(),
				ToroidLabSpec.fmt_len(float(p["w_mm"]), str(_spec["fabrication"]["units"])),
				ToroidLabSpec.fmt_len(float(p["h_mm"]), str(_spec["fabrication"]["units"])), int(_design["bom"]["sheets"]),
				", ".join((p["fold"] as Array).map(func(f): return "%s %.0f°" % [str(f[3]), float(f[2])]))]
	var sn := _solar_box.find_child("solar_note", true, false) as Label
	if sn != null:
		var so: Dictionary = _design["solar"]
		var sm: Dictionary = so["summary"]
		sn.text = "%d panels · %.2f kW · %dS × %dP · string Voc %.1f V, Vmp %.1f V" % [int(so["count"]),
			float(so["total_w"]) / 1000.0, int(so["series"]), int(so["parallel"]), float(sm.get("string_voc", 0.0)),
			float(sm.get("string_vmp", 0.0))]


# ---------------------------------------------------------------------------
# Parts, BOM, checks
# ---------------------------------------------------------------------------

func _part_button(text: String, label: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.toggle_mode = true
	UITheme.style_button(b)
	UITheme.style_toggle(b, label == _highlight, UITheme.FONT_XS)
	b.set_pressed_no_signal(label == _highlight)
	b.pressed.connect(func(): _set_highlight("" if _highlight == label else label))
	return b


func _refresh_parts() -> void:
	_clear(_parts_box)
	var units := str(_spec["fabrication"]["units"])
	for c in _design["frame"]["classes"]:
		var lab := str(c["label"])
		var bend := "straight"
		if float(c["bend_r_m"]) > 0.0:
			bend = "R %s × %s" % [ToroidLabSpec.fmt_len(float(c["bend_r_m"]) * 1000.0, units), ToroidLabSpec.fmt_deg(float(c["bend_deg"]))]
		_parts_box.add_child(_part_button("%s × %d — %s, cut %s, %s" % [lab, int(c["count"]), str(c["desc"]),
			ToroidLabSpec.fmt_len(float(c["cut_m"]) * 1000.0, units), bend], lab,
			"chord %s, rise %s" % [ToroidLabSpec.fmt_len(float(c["chord_m"]) * 1000.0, units), ToroidLabSpec.fmt_len(float(c["rise_m"]) * 1000.0, units)]))
	var fits: Dictionary = _design["bom"]["fittings"]
	for ty in fits:
		var cdef := ToroidLabMaterials.connector(str(ty))
		_parts_box.add_child(_part_button("%s × %d" % [str(cdef["label"]), int(fits[ty])], str(ty), str(cdef["detail"])))
	for c in _design["canopy"].get("classes", []):
		_parts_box.add_child(_part_button("Canopy piece %s × %d — %s × %s" % [str(c["label"]), int(c["count"]),
			ToroidLabSpec.fmt_len(float(c["w_mm"]), units), ToroidLabSpec.fmt_len(float(c["h_mm"]), units)], str(c["label"]),
			"folds " + ", ".join((c["folds"] as Array).map(func(f): return "%s %.0f°" % [str(f[3]), float(f[2])]))))
	var so: Dictionary = _design["solar"]
	if int(so["count"]) > 0:
		_parts_box.add_child(_part_button("Panel × %d — %s" % [int(so["count"]), str(so["model"]["label"])], "panel",
			"%dS × %dP" % [int(so["series"]), int(so["parallel"])]))


func _set_highlight(label: String) -> void:
	_highlight = label
	_rebuild_studio()
	_refresh_parts()
	_sheet_canvas.queue_redraw()


func _refresh_bom() -> void:
	_clear(_bom_box)
	var bom: Dictionary = _design["bom"]
	_bom_lbl.text = "%s · %s of tube in %d stock lengths (%.0f %% waste) · %d fittings%s%s" % [
		ToroidLabSpec.fmt_kg(float(bom["mass_kg"])), ToroidLabSpec.fmt_m(float(bom["tube_m"])), int(bom["stock_pieces"]),
		float(bom["waste_pct"]), (_design["frame"]["fittings"] as Array).size(),
		(" · %s" % UiText.count(int(bom["sheets"]), "sheet")) if int(bom["sheets"]) > 0 else "",
		(" · %s" % UiText.count(int(bom["panels"]), "panel")) if int(bom["panels"]) > 0 else ""]
	_bom_box.add_child(_bom_row(["Qty", "Item", "Detail"], true))
	for r in bom["rows"]:
		_bom_box.add_child(_bom_row(["%d %s" % [int(r["qty"]), str(r["unit"])], str(r["item"]), str(r["detail"])], false))


func _bom_row(cells: Array, head: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var widths := [70, 190, 0]
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
# Designs
# ---------------------------------------------------------------------------

func _refresh_design_list() -> void:
	_design_list.clear()
	_design_entries.clear()
	for p in ToroidLabPresets.builtins():
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
	_spec = ToroidLabSpec.resolve((_design_entries[idx]["spec"] as Dictionary).duplicate(true))
	_highlight = ""
	_built_key = ""
	_rebuild_now()
	_frame_camera()


func _on_save_design() -> void:
	var name := str(_spec["name"])
	var id := DomeLabCam.safe_name(name) + "_%d" % (Time.get_unix_time_from_system() as int)
	var replaced := false
	for d in _library:
		if str(d["name"]) == name:
			d["spec"] = _spec.duplicate(true)
			replaced = true
	if not replaced:
		_library.append({"id": id, "name": name, "spec": _spec.duplicate(true)})
	ToroidLabPresets.save_library(_library)
	_refresh_design_list()
	_status("Saved “%s” to your library." % name)


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
	ToroidLabPresets.save_library(_library)
	_refresh_design_list()


# ---------------------------------------------------------------------------
# Studio
# ---------------------------------------------------------------------------

func _show_view() -> void:
	var t := _tabs.current_tab
	_vp_container.visible = t == 0
	_section_canvas.visible = t == 1
	_sheet_scroll.visible = t == 2
	_schedule_scroll.visible = t == 3
	_explode_slider.get_parent().visible = t == 0


func _rebuild_studio() -> void:
	if _holder == null or _design.is_empty():
		return
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	var node := ToroidLabBuilder.build_from_design(_design, "Toroid", {"explode": _explode,
		"assembly": _assembly, "highlight": _highlight, "record": true})
	_holder.add_child(node)
	var person := _studio.get_node_or_null("ScalePerson") as Node3D
	if person != null:
		person.position = Vector3(float(_design["stats"]["radius_max_m"]) + 0.6, 0.875, 0.0)


func _frame_camera() -> void:
	var st: Dictionary = _design.get("stats", {})
	var r := float(st.get("radius_max_m", 4.0))
	var h := float(st.get("height_m", 3.0))
	_target = Vector3(0, h * 0.4, 0)
	_dist = clampf(maxf(r * 2.0, h) * 1.35 + 1.0, 2.0, 200.0)
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
			_dist = maxf(1.0, _dist * 0.9)
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
				if not _moved and mb.button_index == MOUSE_BUTTON_LEFT:
					var hit := _pick_at(mb.position)
					_set_highlight(str(hit.get("id", "")))
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
				_hover_lbl.text = _describe_hit(_pick_at(mm.position))


func _describe_hit(hit: Dictionary) -> String:
	if hit.is_empty():
		return ""
	var units := str(_spec["fabrication"]["units"])
	var kind := str(hit["kind"])
	var id := str(hit["id"])
	match kind:
		"tube", "cable":
			var c := ToroidLabDesign.member_class(_design, id)
			if c.is_empty():
				return id
			var bend := "straight" if float(c["bend_r_m"]) <= 0.0 else "bent to R %s through %s" % [
				ToroidLabSpec.fmt_len(float(c["bend_r_m"]) * 1000.0, units), ToroidLabSpec.fmt_deg(float(c["bend_deg"]))]
			return "%s · %s · cut %s · %s" % [id, str(c["desc"]), ToroidLabSpec.fmt_len(float(c["cut_m"]) * 1000.0, units), bend]
		"fitting":
			return "%s · %s" % [str(ToroidLabMaterials.connector(id)["label"]), str(ToroidLabMaterials.connector(id)["detail"])]
		"canopy":
			return "Canopy piece %s" % str(hit.get("label", id))
		"panel":
			return "%s · %s" % [str(_design["solar"]["model"]["label"]), str(hit.get("label", ""))]
	return id


func _pick_at(pos: Vector2) -> Dictionary:
	if _camera == null or _holder.get_child_count() == 0:
		return {}
	var vp_size := Vector2(_viewport.size)
	var cs := _vp_container.size
	var p := pos * (vp_size / cs) if cs.x > 0.0 and cs.y > 0.0 else pos
	var o := _camera.project_ray_origin(p)
	var d := _camera.project_ray_normal(p)
	var node := _holder.get_child(0) as Node3D
	var inv := node.global_transform.affine_inverse()
	return ToroidLabBuilder.pick(node, inv * o, (inv.basis * d).normalized())


func _on_play_build() -> void:
	_playing = not _playing
	if _playing and _assembly >= 1.0:
		_assembly = 0.0
	_play_btn.text = "Pause" if _playing else "Play build"


# ---------------------------------------------------------------------------
# Export, place, apply
# ---------------------------------------------------------------------------

func export_dir() -> String:
	return ProjectSettings.globalize_path(EXPORT_ROOT.path_join(DomeLabCam.safe_name(str(_spec["name"]))))


func _on_export() -> void:
	_write_files(export_dir())


func _on_export_to() -> void:
	_file_dialog.popup_centered(Vector2i(800, 560))


func _on_export_dir_selected(dir: String) -> void:
	_write_files(dir.path_join(DomeLabCam.safe_name(str(_spec["name"]))))


func _write_files(dir: String) -> Dictionary:
	var r := ToroidLabCam.write_all(_design, dir)
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


func _on_copy_cut_sheet() -> void:
	DisplayServer.clipboard_set(ToroidLabBom.cut_sheet_text(_design))
	_status("Cut sheet copied.")


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


func _on_place() -> void:
	if _loader != null and _loader.has_method("begin_toroidlab_placement"):
		if bool(_loader.call("begin_toroidlab_placement", ToroidLabSpec.to_json_safe(_spec))):
			close()
			return
	_status("Placing needs a location map.")


func _on_apply() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	var pid := _bound_prop_id
	if main != null:
		PlacedPropService.update_prop_record(main, pid, {"toroid_spec": ToroidLabSpec.to_json_safe(_spec)}, true)
		# The panel ring may have changed: re-seed its graph array.
		Callable(PlacedPropService, "seed_toroid_graph").call_deferred(main, pid)
	close()


# ---------------------------------------------------------------------------
# Accessors for the canvases, the tour and the harness
# ---------------------------------------------------------------------------

func design() -> Dictionary:
	return _design


func spec() -> Dictionary:
	return _spec


func highlight() -> String:
	return _highlight


func set_tab(i: int) -> void:
	_tabs.current_tab = i
	_show_view()


func load_builtin(id: String) -> void:
	var p := ToroidLabPresets.builtin(id)
	if p.is_empty():
		return
	_spec = ToroidLabSpec.resolve((p["spec"] as Dictionary).duplicate(true))
	_highlight = ""
	_built_key = ""
	_rebuild_now()
	_frame_camera()


func set_explode(v: float) -> void:
	_explode = clampf(v, 0.0, 1.0)
	_explode_slider.set_value_no_signal(_explode)
	_rebuild_studio()


func set_assembly(v: float) -> void:
	_assembly = clampf(v, 0.0, 1.0)
	_assembly_slider.set_value_no_signal(_assembly)
	_rebuild_studio()


## Write the design's files to `dir` (the harness); returns the result.
func export_to(dir: String) -> Dictionary:
	return _write_files(dir)


## The bound spin / check / option for spec[group][key] (the harness drives
## the modal's own controls).
func control_for(group: String, key: String) -> Control:
	for b in _bindings:
		if str(b["group"]) == group and str(b["key"]) == key and is_instance_valid(b["ctl"]):
			return b["ctl"]
	return null


# ---------------------------------------------------------------------------
# The section through one rib
# ---------------------------------------------------------------------------

class SectionCanvas extends Control:
	var owner_modal: Control = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		resized.connect(queue_redraw)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.09))
		if owner_modal == null:
			return
		var d: Dictionary = owner_modal.call("design")
		if d.is_empty():
			return
		var font := get_theme_default_font()
		var s: Dictionary = d["spec"]
		var t: Dictionary = s["torus"]
		var fr: Dictionary = d["frame"]
		var st: Dictionary = d["stats"]
		var R := float(fr["R"])
		var r := float(fr["r"])
		var hc := float(fr["hc"])
		var units := str(s["fabrication"]["units"])
		var w_m := float(st["outer_r_m"]) + 0.6
		var h_m := float(st["height_m"]) + 0.6
		var pad := 50.0
		var k := minf((size.x - pad * 2.0) / w_m, (size.y - pad * 2.0) / h_m)
		var origin := Vector2(pad, size.y - pad)
		var P := func(rr: float, y: float) -> Vector2: return origin + Vector2(rr * k, -y * k)
		draw_string(font, Vector2(pad, 26), "Section through one rib — the axis on the left, the ground at the bottom",
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, UITheme.C_TEXT)
		draw_line(P.call(-0.2, 0.0), P.call(w_m, 0.0), Color(0.45, 0.4, 0.32), 2.0)
		draw_dashed_line(P.call(0.0, 0.0), P.call(0.0, h_m), UITheme.C_TEXT_M, 1.0, 6.0)
		# The whole minor circle, faint, and its centre.
		var circ := PackedVector2Array()
		for i in 97:
			var a := TAU * i / 96.0
			circ.append(P.call(R + r * cos(a), hc + r * sin(a)))
		draw_polyline(circ, Color(1, 1, 1, 0.12), 1.0)
		draw_circle(P.call(R, hc), 3.0, UITheme.C_TEXT_M)
		# The rib (outer ground → inner top) and the inner wall.
		var tube_col := Color(0.85, 0.5, 0.3)
		var g := float(fr["ground_deg"])
		var it := float(fr["inner_top_deg"])
		var rib := PackedVector2Array()
		for i in 121:
			var ph := deg_to_rad(lerpf(-g, it, i / 120.0))
			rib.append(P.call(R + r * cos(ph), hc + r * sin(ph)))
		draw_polyline(rib, tube_col, 3.0)
		if int(s["ribs"]["inner_every"]) > 0:
			var inner := PackedVector2Array()
			for i in 41:
				var ph := deg_to_rad(lerpf(it, 180.0 + g, i / 40.0))
				inner.append(P.call(R + r * cos(ph), hc + r * sin(ph)))
			draw_polyline(inner, tube_col.darkened(0.3), 2.0)
		for nd in ToroidLabFrame.rib_nodes(t, int(s["ribs"]["pieces"])):
			var ph := deg_to_rad(float(nd))
			draw_circle(P.call(R + r * cos(ph), hc + r * sin(ph)), 4.0, UITheme.C_TEXT)
		# Rings.
		for ring in fr["rings"]:
			var c: Vector2 = P.call(float(ring["radius_m"]), float(ring["y"]))
			draw_circle(c, 6.0, UITheme.C_PRIMARY)
			draw_string(font, c + Vector2(9, -6), "%d %s" % [int(ring["index"]), str(ring["name"])],
				HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_PRIMARY)
		# The canopy at the seam (A–B) and mid-bay (Vi–P–Vo).
		var cn: Dictionary = d["canopy"]
		if not (cn.get("sectors", []) as Array).is_empty():
			var h: Dictionary = cn["sectors"][0]["halves"][0]
			var rz := func(p: Vector3) -> Vector2: return P.call(Vector2(p.x, p.z).length(), p.y)
			draw_line(rz.call(h["A"]), rz.call(h["B"]), Color(0.9, 0.92, 0.95), 2.0)
			draw_polyline(PackedVector2Array([rz.call(h["Vi"]), rz.call(h["P"]), rz.call(h["Vo"])]),
				Color(0.9, 0.92, 0.95, 0.55), 2.0)
			draw_string(font, (rz.call(h["Vo"]) as Vector2) + Vector2(6, 14), "canopy: seam (solid), mid-bay pleat (faint)",
				HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_S)
		# A panel.
		var so: Dictionary = d["solar"]
		if not (so.get("panels", []) as Array).is_empty():
			var rows: Array = so["panels"][0]["rows"]
			var pl := PackedVector2Array()
			for row in rows:
				var a: Vector3 = row[0]
				var b: Vector3 = row[1]
				var m := (a + b) * 0.5
				pl.append(P.call(Vector2(m.x, m.z).length(), m.y))
			draw_polyline(pl, Color(0.35, 0.55, 1.0), 4.0)
		# Dimensions.
		var dims := [[float(st["inner_r_m"]), "inner R %s" % ToroidLabSpec.fmt_len(float(st["inner_r_m"]) * 1000.0, units)],
			[float(st["base_out_r_m"]), "base R %s" % ToroidLabSpec.fmt_len(float(st["base_out_r_m"]) * 1000.0, units)],
			[float(st["outer_r_m"]), "outer R %s" % ToroidLabSpec.fmt_len(float(st["outer_r_m"]) * 1000.0, units)]]
		for i in dims.size():
			var x := float(dims[i][0])
			var yy := 14.0 + 14.0 * i
			draw_line(P.call(x, 0.0), P.call(x, 0.0) + Vector2(0, yy), UITheme.C_AMBER, 1.0)
			draw_string(font, P.call(x, 0.0) + Vector2(4, yy), str(dims[i][1]), HORIZONTAL_ALIGNMENT_LEFT, -1,
				UITheme.FONT_XS, UITheme.C_AMBER)
		var top := float(st["height_m"])
		draw_line(P.call(R, top), P.call(R, top) + Vector2(-30, 0), UITheme.C_AMBER, 1.0)
		draw_string(font, P.call(R, top) + Vector2(-180, -6), "height %s" % ToroidLabSpec.fmt_len(top * 1000.0, units),
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_AMBER)


# ---------------------------------------------------------------------------
# The canopy sheets, as they will be cut
# ---------------------------------------------------------------------------

class SheetCanvas extends Control:
	var owner_modal: Control = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		resized.connect(queue_redraw)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.09))
		if owner_modal == null:
			return
		var d: Dictionary = owner_modal.call("design")
		if d.is_empty():
			return
		var font := get_theme_default_font()
		var cn: Dictionary = d["canopy"]
		var sheets: Array = (cn.get("nest", {}) as Dictionary).get("sheets", [])
		if sheets.is_empty():
			draw_string(font, Vector2(20, 40), "No canopy: turn it on under Origami canopy.", HORIZONTAL_ALIGNMENT_LEFT, -1,
				UITheme.FONT_MD, UITheme.C_TEXT_S)
			return
		# Sheets that carry the same pieces are drawn once, with their count.
		var groups: Array = []
		var by_sig := {}
		for sh in sheets:
			var sig := ",".join((sh["placements"] as Array).map(func(p): return str(p["id"]).get_slice("_", 0)))
			if not by_sig.has(sig):
				by_sig[sig] = groups.size()
				groups.append({"sheet": sh, "count": 0, "sig": sig})
			groups[int(by_sig[sig])]["count"] = int(groups[int(by_sig[sig])]["count"]) + 1
		var sw := float(cn["sheet"]["w"])
		var shh := float(cn["sheet"]["h"])
		var pad := 28.0
		var top := 52.0
		var cell_w := 300.0
		var k := cell_w / sw
		var cell_h := shh * k
		var n := groups.size()
		var cols := clampi(int(floor((size.x - pad) / (cell_w + pad))), 1, maxi(n, 1))
		var rows := int(ceil(float(n) / cols))
		var want_h := top + rows * (cell_h + pad) + pad
		if absf(custom_minimum_size.y - want_h) > 0.5:
			custom_minimum_size.y = want_h
		var hl := str(owner_modal.call("highlight"))
		draw_string(font, Vector2(pad, 24), "%s · %s sheets · score the green lines, fold to the angle shown" % [
			str(cn["sheet"]["label"]), str(sheets.size())], HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, UITheme.C_TEXT)
		for i in n:
			var g: Dictionary = groups[i]
			var cx := pad + (i % cols) * (cell_w + pad)
			var cy := top + (i / cols) * (cell_h + pad)
			var rect := Rect2(Vector2(cx, cy), Vector2(sw * k, shh * k))
			draw_rect(rect, Color(0.11, 0.13, 0.18))
			draw_rect(rect, UITheme.C_BORDER, false, 1.0)
			var content := ToroidLabCanopy.sheet_content(cn, int(g["sheet"]["index"]))
			var on := not hl.is_empty() and str(g["sig"]).contains(hl)
			for ring in content["outside"]:
				var pts: PackedVector2Array = FlatpackProfile.tessellate(ring, 20.0)
				var poly := PackedVector2Array()
				for q in pts:
					poly.append(Vector2(rect.position.x + q.x * k, rect.end.y - q.y * k))
				if poly.size() >= 3:
					draw_colored_polygon(poly, Color(0.93, 0.94, 0.95, 0.22 if not on else 0.4))
					poly.append(poly[0])
					draw_polyline(poly, UITheme.C_ERROR, 1.0)
			for ring in content["inside"]:
				var pts: PackedVector2Array = FlatpackProfile.tessellate(ring, 3.0)
				var poly := PackedVector2Array()
				for q in pts:
					poly.append(Vector2(rect.position.x + q.x * k, rect.end.y - q.y * k))
				if poly.size() >= 3:
					poly.append(poly[0])
					draw_polyline(poly, UITheme.C_PRIMARY, 1.0)
			for f in content["fold"]:
				var a: Vector2 = f["a"]
				var b: Vector2 = f["b"]
				var pa := Vector2(rect.position.x + a.x * k, rect.end.y - a.y * k)
				var pb := Vector2(rect.position.x + b.x * k, rect.end.y - b.y * k)
				draw_dashed_line(pa, pb, UITheme.C_GREEN, 1.0, 4.0)
				draw_string(font, (pa + pb) * 0.5 + Vector2(3, 0), str(f["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, UITheme.C_GREEN)
			draw_string(font, rect.position + Vector2(0, -8), "%s × %d sheets" % [str(g["sig"]), int(g["count"])],
				HORIZONTAL_ALIGNMENT_LEFT, int(rect.size.x + pad - 6.0), UITheme.FONT_XS, UITheme.C_AMBER if on else UITheme.C_TEXT_S)
