extends Control

## The dome & zome designer: geodesic domes (Class I / II / III on an
## icosahedron, octahedron or tetrahedron), polar-zonohedron zomes and helix
## zomes, built with any of five connector systems — flattened conduit on a
## bolt, rigid struts into hubs, flat bars bent to the curve, a hubless
## nexorade / rotegrity, or folded plates — with panels of any sheet, a bill
## of materials, the strut schedule and CNC files.
##
## Left:   family, connector system, built-in designs and the player's library.
## Centre: the structure in a 3D studio (explode, build scrub; click a part
##         to pick its class), the nested panel sheets, the hub templates, and
##         the schedule (the cut sheet as text).
## Right:  geometry, size, connectors, faces, fabrication, the checks, the
##         parts (click to highlight a class), the bill of materials, export.
## Footer: place a new structure in the world, or apply to the placed one.
##
## Everything reads one solved DomeLabDesign, so the 3D model, the sheets,
## the schedule and the files always agree. Undo / redo keep whole spec
## snapshots (Ctrl+Z / Ctrl+Y).

const MODAL_NAME := "domelab_designer"
const WANT := Vector2(1600, 960)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.15
const EXPORT_ROOT := "user://domelab_designs"

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

var _explode := 0.0
var _assembly := 1.0
var _playing := false
var _highlight := ""
var _library: Array = []
var _status_text := ""
var _hover_frame := 0

# UI
var _panel: PanelContainer
var _name_edit: LineEdit
var _subtitle: Label
var _undo_btn: Button
var _redo_btn: Button
var _family_box: VBoxContainer
var _system_box: VBoxContainer
var _design_list: ItemList
var _design_entries: Array = []
var _tabs: TabBar
var _view_stack: Control
var _vp_container: SubViewportContainer
var _viewport: SubViewport
var _studio: Node3D
var _holder: Node3D
var _camera: Camera3D
var _sheet_canvas: Control
var _hub_canvas: Control
var _schedule_scroll: ScrollContainer
var _schedule_text: RichTextLabel
var _explode_slider: HSlider
var _assembly_slider: HSlider
var _play_btn: Button
var _hover_lbl: Label
var _geo_box: VBoxContainer
var _size_box: VBoxContainer
var _conn_box: VBoxContainer
var _face_box: VBoxContainer
var _fab_box: VBoxContainer
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
var _pitch := 0.35
var _dist := 12.0
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
	_spec = DomeLabSpec.resolve(spec if not spec.is_empty() else DomeLabSpec.default_spec("geodesic"))
	_activate()


func open_for_prop(prop_id: String) -> void:
	if _active or prop_id.is_empty():
		return
	var rec := _prop_record(prop_id)
	var spec: Dictionary = rec.get("domelab_spec", {}) as Dictionary
	_bound_prop_id = prop_id
	_spec = DomeLabSpec.resolve(spec if not spec.is_empty() else DomeLabSpec.default_spec("geodesic"))
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
	_library = DomeLabPresets.load_library()
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
	icon.texture = UiIcons.icon("tent", 22)
	icon.modulate = UITheme.C_AMBER
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(icon)
	var title := Label.new()
	title.text = "Dome & zome designer"
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
	box.add_child(SectionHeader.make("Structure", "tent"))
	_family_box = VBoxContainer.new()
	_family_box.add_theme_constant_override("separation", 2)
	box.add_child(_family_box)
	for f in DomeLabSpec.FAMILIES:
		var b := Button.new()
		b.text = str(DomeLabSpec.FAMILY_LABELS[f])
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 30)
		b.set_meta("family", f)
		b.pressed.connect(_on_family_pressed.bind(f))
		_family_box.add_child(b)
	box.add_child(SectionHeader.make("Connectors", "wrench"))
	_system_box = VBoxContainer.new()
	_system_box.add_theme_constant_override("separation", 2)
	box.add_child(_system_box)
	for sys in DomeLabSpec.SYSTEMS:
		var b := Button.new()
		b.text = str(DomeLabSpec.SYSTEM_SHORT[sys])
		b.tooltip_text = str(DomeLabSpec.SYSTEM_LABELS[sys])
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 28)
		b.set_meta("system", sys)
		b.pressed.connect(_on_system_pressed.bind(sys))
		_system_box.add_child(b)
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_design_list = ItemList.new()
	_design_list.custom_minimum_size = Vector2(0, 280)
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
	return col[0]


func _build_centre() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_tabs = TabBar.new()
	_tabs.add_tab("Structure")
	_tabs.add_tab("Sheets")
	_tabs.add_tab("Hubs")
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
	_sheet_canvas = SheetCanvas.new()
	_sheet_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sheet_canvas.visible = false
	_sheet_canvas.set("owner_modal", self)
	_view_stack.add_child(_sheet_canvas)
	_hub_canvas = HubCanvas.new()
	_hub_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hub_canvas.visible = false
	_hub_canvas.set("owner_modal", self)
	_view_stack.add_child(_hub_canvas)
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
	# Controls under the view.
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
	_play_btn.tooltip_text = "Watch the rings go up from the base"
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(_on_play_build)
	bar.add_child(_play_btn)
	var clear := Button.new()
	clear.text = "Clear highlight"
	UITheme.style_button(clear)
	clear.pressed.connect(func(): _set_highlight(""))
	bar.add_child(clear)
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
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	_studio.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, 35, 0)
	key.light_energy = 1.25
	key.shadow_enabled = true
	_studio.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, -140, 0)
	fill.light_energy = 0.35
	_studio.add_child(fill)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.20, 0.19, 0.18)
	gmat.roughness = 0.95
	ground.material_override = gmat
	_studio.add_child(ground)
	# A person for scale.
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
	var col := _scroll_column(390)
	var box: VBoxContainer = col[1]
	var sec := Collapsible.make("Geometry", true)
	box.add_child(sec)
	_geo_box = sec.body
	sec = Collapsible.make("Size", true)
	box.add_child(sec)
	_size_box = sec.body
	sec = Collapsible.make("Struts and hubs", true)
	box.add_child(sec)
	_conn_box = sec.body
	sec = Collapsible.make("Faces", false)
	box.add_child(sec)
	_face_box = sec.body
	sec = Collapsible.make("Fabrication", false)
	box.add_child(sec)
	_fab_box = sec.body
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
	for spec_btn in [["Export files", "DXF + SVG per sheet and hub, strut CSV, BOM CSV, cut sheet, JSON", _on_export],
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
	hint.text = "Drag to orbit · wheel to zoom · click a strut, hub or panel to highlight its class"
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
## the family, connector system, hub kind or class changes (so a spin box
## never loses focus mid-edit).
func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = DomeLabSpec.resolve(_spec)
	_design = DomeLabDesign.solve(_spec)
	var key := "%s|%s|%s|%d|%s" % [str(_spec["family"]), str(_spec["system"]), str(_spec["hub"]["kind"]),
		int(_spec["geodesic"]["cls"]), str(_spec["nexorade"]["mode"])]
	if key != _built_key:
		_built_key = key
		_build_settings_rows()
	_sync_settings()
	_rebuild_studio()
	_refresh_parts()
	_refresh_bom()
	_refresh_checks()
	_refresh_header()
	_schedule_text.text = DomeLabBom.cut_sheet_text(_design)
	_sheet_canvas.queue_redraw()
	_hub_canvas.queue_redraw()
	_sync_family_buttons()
	_show_view()
	_update_undo_buttons()


func _refresh_header() -> void:
	if not _name_edit.has_focus():
		_name_edit.text = str(_spec["name"])
	var st: Dictionary = _design.get("stats", {})
	var bom: Dictionary = _design.get("bom", {})
	_subtitle.text = "%s · %s high · %s floor · %s" % [DomeLabSpec.describe(_spec),
		DomeLabSpec.fmt_m(float(st.get("height_m", 0.0))), DomeLabSpec.fmt_area(float(st.get("floor_area_m2", 0.0))),
		DomeLabSpec.fmt_kg(float(bom.get("mass_kg", 0.0)))]


func _on_name_changed() -> void:
	var t := _name_edit.text.strip_edges()
	if t.is_empty() or t == str(_spec.get("name", "")):
		return
	_edit("", "name", t)


func _on_family_pressed(f: String) -> void:
	if f == str(_spec.get("family", "")):
		_sync_family_buttons()
		return
	_push_undo()
	_spec["family"] = f
	if f == "zome" and str(_spec["system"]) == "nexorade":
		pass
	_highlight = ""
	_rebuild_now()
	_frame_camera()


func _on_system_pressed(sys: String) -> void:
	if sys == str(_spec.get("system", "")):
		_sync_family_buttons()
		return
	_push_undo()
	_spec["system"] = sys
	# A sensible strut for the system.
	var mat := str(_spec["strut"]["material"])
	var kind := str(DomeLabMaterials.strut(mat).get("kind", ""))
	if sys == "flat_bar" and kind != "bar":
		_spec["strut"]["material"] = "hdpe_bar_50x6"
	elif sys == "bolt_stack" and not bool(DomeLabMaterials.strut(mat).get("flatten", false)):
		_spec["strut"]["material"] = "emt_34"
	elif sys == "hub" and kind == "bar":
		_spec["strut"]["material"] = "emt_34"
	if sys == "hub" and str(_spec["hub"]["kind"]) == "bolt":
		_spec["hub"]["kind"] = "socket"
	_highlight = ""
	_rebuild_now()


func _sync_family_buttons() -> void:
	for b in _family_box.get_children():
		var on: bool = str(b.get_meta("family", "")) == str(_spec.get("family", ""))
		(b as Button).set_pressed_no_signal(on)
		UITheme.style_toggle(b as Button, on)
	for b in _system_box.get_children():
		var on: bool = str(b.get_meta("system", "")) == str(_spec.get("system", ""))
		(b as Button).set_pressed_no_signal(on)
		UITheme.style_toggle(b as Button, on)


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
	l.custom_minimum_size = Vector2(160, 0)
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


func _opt_list(ids: Array, labels: Dictionary) -> Array:
	var out: Array = []
	for id in ids:
		out.append([id, str(labels.get(id, id))])
	return out


func _mat_list(order: Array, table: Dictionary, filter: Callable = Callable()) -> Array:
	var out: Array = []
	for id in order:
		if filter.is_valid() and not bool(filter.call(table[id])):
			continue
		out.append([id, str(table[id]["label"])])
	return out


func _build_settings_rows() -> void:
	var fam := str(_spec["family"])
	var sys := str(_spec["system"])
	_clear(_geo_box)
	_clear(_size_box)
	_clear(_conn_box)
	_clear(_face_box)
	_clear(_fab_box)
	# --- geometry ---------------------------------------------------------
	if fam == "geodesic":
		var g := "geodesic"
		var base := _option(_opt_list(DomeLabSpec.BASES, DomeLabSpec.BASE_LABELS), func(v): _edit(g, "base", v))
		base.name = "base"
		_row(_geo_box, "Base solid", base, "The polyhedron the sphere is subdivided from")
		var cls := _option([[1, "Class I (alternate)"], [2, "Class II (triacon)"], [3, "Class III (skew)"]],
			func(v): _edit(g, "cls", int(v)))
		cls.name = "cls"
		_row(_geo_box, "Class", cls, "Class I: strut lines run along the base edges. Class II: the great-circle grid, even frequencies. Class III: a skewed (b, c) lattice — chiral.")
		if int(_spec[g]["cls"]) == 3:
			var b := _spin(1, 8, 1, "", func(v): _edit(g, "b", int(v)))
			b.name = "b"
			_row(_geo_box, "Lattice b", b, "Goldberg–Coxeter (b, c); faces = (b² + bc + c²) × base faces")
			var c := _spin(1, 8, 1, "", func(v): _edit(g, "c", int(v)))
			c.name = "c"
			_row(_geo_box, "Lattice c", c)
		else:
			var f := _spin(1, 10, 1, "V", func(v): _edit(g, "frequency", int(v)))
			f.name = "frequency"
			_row(_geo_box, "Frequency", f, "How many times each base edge is divided (Class II: even only)")
		var orient := _option(_opt_list(DomeLabSpec.ORIENTATIONS, DomeLabSpec.ORIENTATION_LABELS),
			func(v): _edit(g, "orientation", v))
		orient.name = "orientation"
		_row(_geo_box, "Orientation", orient, "What sits at the top of the dome")
		var frac := _option(DomeLabSpec.FRACTIONS, func(v): _edit(g, "fraction", float(v)))
		frac.name = "fraction"
		_row(_geo_box, "Truncation", frac, "How much of the sphere is kept, cut at the nearest ring of hubs")
		var flat := _check("Flat base (level the base hubs)", func(v): _edit(g, "flat_base", bool(v)))
		flat.name = "flat_base"
		_row(_geo_box, "Base", flat, "A 3V 5/8 base is two heights a few centimetres apart; levelling it adds strut lengths")
		var stretch := _spin(0.4, 2.5, 0.05, "×", func(v): _edit(g, "stretch", float(v)))
		stretch.name = "stretch"
		_row(_geo_box, "Vertical stretch", stretch, "1 = a sphere; less = a low ellipsoid, more = an egg")
	else:
		var z := "zome"
		var sides := _spin(3, 16, 1, "", func(v): _edit(z, "sides", int(v)))
		sides.name = "sides"
		_row(_geo_box, "Sides (order n)", sides, "The zonohedron's generators; n(n−1) rhombi in all, n−1 shapes")
		var layers := _spin(1, 16, 1, "", func(v): _edit(z, "layers", int(v)))
		layers.name = "layers"
		_row(_geo_box, "Layers kept", layers, "Rows of rhombi from the apex down; past n/2 the zome bulges out over its floor")
		var pitch := _spin(10, 80, 1, "°", func(v): _edit(z, "pitch_deg", float(v)))
		pitch.name = "pitch_deg"
		_row(_geo_box, "Generator pitch", pitch, "The struts' angle from the vertical axis: low = tall and narrow, high = squat")
		var zb := _option(_opt_list(DomeLabSpec.ZOME_BASES, DomeLabSpec.ZOME_BASE_LABELS), func(v): _edit(z, "base", v))
		zb.name = "base"
		_row(_geo_box, "Floor", zb)
		var tri := _check("Diagonal strut in every rhombus", func(v): _edit(z, "triangulate", bool(v)))
		tri.name = "triangulate"
		_row(_geo_box, "Triangulate", tri, "A rhombus frame is a mechanism without a diagonal or a rigid panel")
		var ribs := _check("Curved helix ribs instead of struts", func(v): _edit(z, "ribs", bool(v)))
		ribs.name = "ribs"
		_row(_geo_box, "Helix zome", ribs, "Each zone becomes one continuous rib on the zonohedron's smooth limit (CNC arcs or bent bar), lapped where it crosses the other hand")
		var stretch := _spin(0.4, 2.5, 0.05, "×", func(v): _edit(z, "stretch", float(v)))
		stretch.name = "stretch"
		_row(_geo_box, "Vertical stretch", stretch)
	# --- size -------------------------------------------------------------
	var rad := _spin(DomeLabSpec.MIN_RADIUS_M, DomeLabSpec.MAX_RADIUS_M, 0.1, " m", func(v): _edit("", "radius_m", float(v)))
	rad.name = "radius_m"
	_row(_size_box, "Radius", rad, "The widest horizontal radius of the finished structure")
	var dia := Label.new()
	dia.name = "size_info"
	dia.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dia.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	dia.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_size_box.add_child(dia)
	# --- struts and hubs ----------------------------------------------------
	var ribs_mode := fam == "zome" and bool(_spec["zome"]["ribs"])
	if sys != "plate":
		var filt := Callable()
		if sys == "flat_bar":
			filt = func(m): return str(m.get("kind", "")) == "bar"
		elif sys == "bolt_stack":
			filt = func(m): return bool(m.get("flatten", false))
		var strut := _option(_mat_list(DomeLabMaterials.STRUT_ORDER, DomeLabMaterials.STRUTS, filt),
			func(v): _edit("strut", "material", v))
		strut.name = "strut_material"
		_row(_conn_box, "Rib stock" if ribs_mode else "Strut stock", strut)
	match sys:
		"bolt_stack":
			var fl := _spin(0, 200, 5, " mm", func(v): _edit("ends", "flatten_mm", float(v)))
			fl.name = "flatten_mm"
			_row(_conn_box, "Flatten each end", fl, "How much of the tube is pressed flat")
			var ho := _spin(5, 150, 1, " mm", func(v): _edit("ends", "hole_offset_mm", float(v)))
			ho.name = "hole_offset_mm"
			_row(_conn_box, "Hole from the cut end", ho, "Cut length = hole-to-hole + 2 × this")
			var bolt := _option(_mat_list(DomeLabMaterials.BOLT_ORDER, DomeLabMaterials.BOLTS), func(v): _edit("hub", "bolt", v))
			bolt.name = "bolt"
			_row(_conn_box, "Bolt", bolt, "One bolt through every stack; its length follows the hub's valence")
		"hub":
			var hk := _option(_opt_list(["socket", "plate", "ring"], DomeLabSpec.HUB_LABELS), func(v): _edit("hub", "kind", v))
			hk.name = "hub_kind"
			_row(_conn_box, "Hub", hk)
			var reach := _spin(0, 400, 5, " mm", func(v): _edit("hub", "reach_mm", float(v)))
			reach.name = "reach_mm"
			_row(_conn_box, "Hub reach", reach, "Hub centre to the strut's end; cut = node-to-node − 2 × reach")
			if str(_spec["hub"]["kind"]) == "plate":
				var pt := _spin(1, 12, 0.5, " mm", func(v): _edit("hub", "plate_t_mm", float(v)))
				pt.name = "plate_t_mm"
				_row(_conn_box, "Plate thickness", pt)
				var ho := _spin(5, 150, 1, " mm", func(v): _edit("ends", "hole_offset_mm", float(v)))
				ho.name = "hole_offset_mm"
				_row(_conn_box, "Hole from the cut end", ho)
				var bolt := _option(_mat_list(DomeLabMaterials.BOLT_ORDER, DomeLabMaterials.BOLTS), func(v): _edit("hub", "bolt", v))
				bolt.name = "bolt"
				_row(_conn_box, "Bolt", bolt)
			else:
				var ins := _spin(0, 200, 5, " mm", func(v): _edit("ends", "insert_mm", float(v)))
				ins.name = "insert_mm"
				_row(_conn_box, "Arm insertion", ins, "How far the strut slides onto the hub's arm")
		"flat_bar":
			var ho := _spin(5, 150, 1, " mm", func(v): _edit("ends", "hole_offset_mm", float(v)))
			ho.name = "hole_offset_mm"
			_row(_conn_box, "Hole from the cut end", ho, "Holes are spaced along the ARC the bar follows")
			var bolt := _option(_mat_list(DomeLabMaterials.BOLT_ORDER, DomeLabMaterials.BOLTS), func(v): _edit("hub", "bolt", v))
			bolt.name = "bolt"
			_row(_conn_box, "Bolt", bolt)
		"nexorade":
			var mode := _option(_opt_list(DomeLabSpec.NEXORADE_MODES, DomeLabSpec.NEXORADE_MODE_LABELS), func(v): _edit("nexorade", "mode", v))
			mode.name = "nx_mode"
			_row(_conn_box, "Slats", mode)
			var slat := _option(_mat_list(DomeLabMaterials.STRUT_ORDER, DomeLabMaterials.STRUTS, func(m): return str(m.get("kind", "")) == "bar"),
				func(v): _edit("nexorade", "slat", v))
			slat.name = "slat"
			_row(_conn_box, "Slat stock", slat)
			var eng := _spin(0, 40, 0.5, "°", func(v): _edit("nexorade", "engagement_deg", float(v)))
			eng.name = "engagement_deg"
			_row(_conn_box, "Engagement angle", eng, "How far each slat is turned about its midpoint; 0 = auto")
			if str(_spec["nexorade"]["mode"]) == "band":
				var ef := _spin(8, 45, 1, " %", func(v): _edit("nexorade", "engage_frac", float(v) / 100.0))
				ef.name = "engage_frac"
				_row(_conn_box, "Engagement length", ef, "End hole to the inboard hole, as a share of the edge (auto fits this)")
			var ov := _spin(0, 300, 5, " mm", func(v): _edit("nexorade", "overhang_mm", float(v)))
			ov.name = "overhang_mm"
			_row(_conn_box, "Overhang past the end hole", ov)
			var bolt := _option(_mat_list(DomeLabMaterials.BOLT_ORDER, DomeLabMaterials.BOLTS), func(v): _edit("hub", "bolt", v))
			bolt.name = "bolt"
			_row(_conn_box, "Bolt at each crossing", bolt)
		"plate":
			var bolt := _option(_mat_list(DomeLabMaterials.BOLT_ORDER, DomeLabMaterials.BOLTS), func(v): _edit("hub", "bolt", v))
			bolt.name = "bolt"
			_row(_conn_box, "Flange bolt", bolt)
	# --- faces --------------------------------------------------------------
	var fm := _option(_mat_list(DomeLabMaterials.SHEET_ORDER, DomeLabMaterials.SHEETS,
		(func(m): return bool(m.get("folds", false))) if sys == "plate" else Callable()), func(v): _edit("face", "material", v))
	fm.name = "face_material"
	_row(_face_box, "Plate sheet" if sys == "plate" else "Covering", fm, "A panel per face, cut to the face minus the seam gap, nested onto sheets")
	var gap := _spin(0, 60, 1, " mm", func(v): _edit("face", "gap_mm", float(v)))
	gap.name = "gap_mm"
	_row(_face_box, "Seam gap", gap)
	if sys == "plate":
		var fl := _spin(10, 150, 5, " mm", func(v): _edit("face", "flange_mm", float(v)))
		fl.name = "flange_mm"
		_row(_face_box, "Flange width", fl, "Folded through half the angle between the two faces")
	var hp := _spin(40, 600, 10, " mm", func(v): _edit("face", "hole_pitch_mm", float(v)))
	hp.name = "hole_pitch_mm"
	_row(_face_box, "Hole pitch", hp)
	if sys != "plate":
		var sc := _spin(2, 12, 0.5, " mm", func(v): _edit("face", "screw_mm", float(v)))
		sc.name = "screw_mm"
		_row(_face_box, "Screw hole", sc)
	# --- fabrication --------------------------------------------------------
	var units := _option([["mm", "Millimetres"], ["in", "Inches"]], func(v): _edit("fabrication", "units", v))
	units.name = "units"
	_row(_fab_box, "Units", units, "For the schedule, the labels and the files")
	var gt := _spin(0.05, 20, 0.05, " mm", func(v): _edit("fabrication", "group_tol_mm", float(v)))
	gt.name = "group_tol_mm"
	_row(_fab_box, "Length grouping", gt, "Struts within this are one type")
	var at := _spin(0.05, 5, 0.05, "°", func(v): _edit("fabrication", "angle_tol_deg", float(v)))
	at.name = "angle_tol_deg"
	_row(_fab_box, "Angle grouping", at, "Bends and hub arm angles within this are one type")
	var kerf := _spin(0, 20, 0.5, " mm", func(v): _edit("fabrication", "kerf_mm", float(v)))
	kerf.name = "kerf_mm"
	_row(_fab_box, "Saw kerf", kerf, "Lost at every cut; also the gap between nested panels")
	var sw := _spin(0, 6000, 10, " mm", func(v): _edit("fabrication", "sheet_w_mm", float(v)))
	sw.name = "sheet_w_mm"
	_row(_fab_box, "Sheet width (0 = stock)", sw)
	var sh := _spin(0, 12000, 10, " mm", func(v): _edit("fabrication", "sheet_h_mm", float(v)))
	sh.name = "sheet_h_mm"
	_row(_fab_box, "Sheet length (0 = stock)", sh)


func _sync_settings() -> void:
	_suppress = true
	var g: Dictionary = _spec["geodesic"]
	var z: Dictionary = _spec["zome"]
	for c in _all_controls(_geo_box):
		match str(c.name):
			"base": _select_meta(c, str(g["base"]))
			"cls": _select_meta(c, int(g["cls"]))
			"b": _set_ctl(c, int(g["b"]))
			"c": _set_ctl(c, int(g["c"]))
			"frequency": _set_ctl(c, int(g["frequency"]))
			"orientation": _select_meta(c, str(g["orientation"]))
			"fraction": _select_meta(c, float(g["fraction"]))
			"flat_base": _set_ctl(c, bool(g["flat_base"]))
			"stretch": _set_ctl(c, float(g["stretch"]) if str(_spec["family"]) == "geodesic" else float(z["stretch"]))
			"sides": _set_ctl(c, int(z["sides"]))
			"layers": _set_ctl(c, int(z["layers"]))
			"pitch_deg": _set_ctl(c, float(z["pitch_deg"]))
			"triangulate": _set_ctl(c, bool(z["triangulate"]))
			"ribs": _set_ctl(c, bool(z["ribs"]))
	for c in _all_controls(_size_box):
		match str(c.name):
			"radius_m": _set_ctl(c, float(_spec["radius_m"]))
			"size_info":
				var st: Dictionary = _design.get("stats", {})
				var geo: Dictionary = _design.get("geo", {})
				(c as Label).text = "Diameter %s · height %s · floor %s · surface %s · %s inside\n%d hubs · %d edges · %d faces%s" % [
					DomeLabSpec.fmt_m(float(st.get("radius_max_m", 0.0)) * 2.0), DomeLabSpec.fmt_m(float(st.get("height_m", 0.0))),
					DomeLabSpec.fmt_area(float(st.get("floor_area_m2", 0.0))), DomeLabSpec.fmt_area(float(st.get("surface_m2", 0.0))),
					"%.0f m³" % float(st.get("volume_m3", 0.0)), int(st.get("vertices", 0)), int(st.get("edges", 0)),
					int(st.get("faces", 0)),
					(" · %.0f %% of the sphere" % (float(geo.get("fraction_actual", 1.0)) * 100.0)) if str(_spec["family"]) == "geodesic" else ""]
	var hub: Dictionary = _spec["hub"]
	var ends: Dictionary = _spec["ends"]
	var nx: Dictionary = _spec["nexorade"]
	for c in _all_controls(_conn_box):
		match str(c.name):
			"strut_material": _select_meta(c, str(_spec["strut"]["material"]))
			"flatten_mm": _set_ctl(c, float(ends["flatten_mm"]))
			"hole_offset_mm": _set_ctl(c, float(ends["hole_offset_mm"]))
			"insert_mm": _set_ctl(c, float(ends["insert_mm"]))
			"bolt": _select_meta(c, str(hub["bolt"]))
			"hub_kind": _select_meta(c, str(hub["kind"]))
			"reach_mm": _set_ctl(c, float(hub["reach_mm"]))
			"plate_t_mm": _set_ctl(c, float(hub["plate_t_mm"]))
			"nx_mode": _select_meta(c, str(nx["mode"]))
			"slat": _select_meta(c, str(nx["slat"]))
			"engagement_deg": _set_ctl(c, float(nx["engagement_deg"]))
			"engage_frac": _set_ctl(c, float(nx["engage_frac"]) * 100.0)
			"overhang_mm": _set_ctl(c, float(nx["overhang_mm"]))
	var face: Dictionary = _spec["face"]
	for c in _all_controls(_face_box):
		match str(c.name):
			"face_material": _select_meta(c, str(face["material"]))
			"gap_mm": _set_ctl(c, float(face["gap_mm"]))
			"flange_mm": _set_ctl(c, float(face["flange_mm"]))
			"hole_pitch_mm": _set_ctl(c, float(face["hole_pitch_mm"]))
			"screw_mm": _set_ctl(c, float(face["screw_mm"]))
	var fab: Dictionary = _spec["fabrication"]
	for c in _all_controls(_fab_box):
		match str(c.name):
			"units": _select_meta(c, str(fab["units"]))
			"group_tol_mm": _set_ctl(c, float(fab["group_tol_mm"]))
			"angle_tol_deg": _set_ctl(c, float(fab["angle_tol_deg"]))
			"kerf_mm": _set_ctl(c, float(fab["kerf_mm"]))
			"sheet_w_mm": _set_ctl(c, float(fab["sheet_w_mm"]))
			"sheet_h_mm": _set_ctl(c, float(fab["sheet_h_mm"]))
	_suppress = false


func _all_controls(root: Node) -> Array:
	var out: Array = []
	for c in root.get_children():
		if c is Control and not (c is HBoxContainer):
			out.append(c)
		out.append_array(_all_controls(c))
	return out


func _set_ctl(c: Node, v: Variant) -> void:
	if c is SpinBox:
		(c as SpinBox).set_value_no_signal(float(v))
	elif c is CheckBox:
		(c as CheckBox).set_pressed_no_signal(bool(v))
	elif c is HSlider:
		(c as HSlider).set_value_no_signal(float(v))


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
	var cf: Dictionary = _design["stats"]["chord_factors"]
	for c in _design["strut_classes"]:
		var lab := str(c["label"])
		var extra := ""
		if float(c["hole_len"]) > 0.0 and str(_spec["system"]) != "flat_bar":
			extra = "  bends %s / %s" % [DomeLabSpec.fmt_deg(float(c["bend_a"])), DomeLabSpec.fmt_deg(float(c["bend_b"]))]
		elif str(_spec["system"]) == "flat_bar":
			extra = "  arc, R %s" % (DomeLabSpec.fmt_m(float(c["bend_radius"])) if float(c["bend_radius"]) < INF else "∞")
		_parts_box.add_child(_part_button("Strut %s × %d — cut %s%s" % [lab, int(c["count"]),
			DomeLabSpec.fmt_len(float(c["cut"]) * 1000.0, units), extra], lab,
			("chord factor %.5f · " % float(cf[lab]) if cf.has(lab) else "") + "node to node %s" % DomeLabSpec.fmt_len(float(c["len"]) * 1000.0, units)))
	for c in _design["rib_classes"]:
		var lab := str(c["label"])
		_parts_box.add_child(_part_button("%s × %d — arc %s, %d segments" % [lab, int(c["count"]),
			DomeLabSpec.fmt_len(float(c["arc_len"]) * 1000.0, units), int(c["segments"])], lab,
			"lapped at " + ", ".join((c["notches"] as Array).map(func(x): return DomeLabSpec.fmt_len(float(x) * 1000.0, units, 0)))))
	var nx: Dictionary = _design["nexorade"]
	for c in nx.get("classes", []):
		var lab := str(c["label"])
		_parts_box.add_child(_part_button("Slat %s × %d — %s" % [lab, int(c["count"]), DomeLabSpec.fmt_len(float(c["len"]) * 1000.0, units)],
			lab, "holes at " + ", ".join((c["holes"] as Array).map(func(x): return DomeLabSpec.fmt_len(float(x) * 1000.0, units, 0)))))
	for t in _design["hub_types"]:
		var lab := str(t["label"])
		_parts_box.add_child(_part_button("Hub %s × %d — %d-way%s, dip %s" % [lab, int(t["count"]), int(t["valence"]),
			" base" if bool(t["base"]) else "", DomeLabSpec.fmt_deg(float(t["mean_dip_deg"]))], lab,
			"arm gaps " + DomeLabBom._gap_text(t)))
	var pn: Dictionary = _design["panels"]
	for c in pn.get("classes", []):
		var lab := str(c["label"])
		_parts_box.add_child(_part_button("Panel %s × %d — sides %s" % [lab, int(c["count"]),
			", ".join((c["sides_mm"] as Array).map(func(x): return DomeLabSpec.fmt_len(float(x), units, 0)))], lab,
			("folds " + ", ".join((c["bends"] as Array).map(func(x): return DomeLabSpec.fmt_deg(float(x))))) if str(_spec["system"]) == "plate" else "screwed to the struts"))
	if _parts_box.get_child_count() == 0:
		var l := Label.new()
		l.text = "No parts"
		l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_parts_box.add_child(l)


func _set_highlight(label: String) -> void:
	_highlight = label
	_rebuild_studio()
	_refresh_parts()
	_hub_canvas.queue_redraw()
	_sheet_canvas.queue_redraw()


func _refresh_bom() -> void:
	_clear(_bom_box)
	var bom: Dictionary = _design["bom"]
	_bom_lbl.text = "%s · %s of %s in %s stock lengths (%.0f %% waste) · %s bolts%s" % [
		DomeLabSpec.fmt_kg(float(bom["mass_kg"])), DomeLabSpec.fmt_m(float(bom["strut_m"])),
		str(DomeLabMaterials.strut(str(_spec["strut"]["material"]))["label"]) if (_design["nexorade"] as Dictionary).is_empty() else str((_design["nexorade"] as Dictionary)["slat"]["label"]),
		str(bom["stock_pieces"]), float(bom["waste_pct"]), str(bom["bolts"]),
		(" · %s on %s" % [DomeLabSpec.fmt_area(float(bom["panels_m2"])), UiText.count(int(bom["sheets"]), "sheet")]) if float(bom["panels_m2"]) > 0.0 else ""]
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
	for p in DomeLabPresets.builtins():
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
	_spec = DomeLabSpec.resolve((_design_entries[idx]["spec"] as Dictionary).duplicate(true))
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
	DomeLabPresets.save_library(_library)
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
	DomeLabPresets.save_library(_library)
	_refresh_design_list()


# ---------------------------------------------------------------------------
# Studio
# ---------------------------------------------------------------------------

func _show_view() -> void:
	var t := _tabs.current_tab
	_vp_container.visible = t == 0
	_sheet_canvas.visible = t == 1
	_hub_canvas.visible = t == 2
	_schedule_scroll.visible = t == 3
	_explode_slider.get_parent().visible = t == 0


func _rebuild_studio() -> void:
	if _holder == null or _design.is_empty():
		return
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	var node := DomeLabBuilder.build_from_design(_design, "Dome", {"explode": _explode,
		"assembly": _assembly, "highlight": _highlight, "record": true})
	_holder.add_child(node)
	var person := _studio.get_node_or_null("ScalePerson") as Node3D
	if person != null:
		var r := float(_design["stats"]["radius_max_m"])
		person.position = Vector3(r + 0.6, 0.875, 0.0)


func _frame_camera() -> void:
	var st: Dictionary = _design.get("stats", {})
	var r := float(st.get("radius_max_m", 3.0))
	var h := float(st.get("height_m", 3.0))
	_target = Vector3(0, h * 0.45, 0)
	_dist = clampf(maxf(r * 2.0, h) * 1.6 + 1.0, 2.0, 160.0)
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
			_dist = minf(200.0, _dist * 1.1)
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
				_pitch = clampf(_pitch - mm.relative.y * 0.01, -0.3, 1.45)
				_update_camera()
		else:
			_hover_frame += 1
			if _hover_frame % 4 == 0:
				var hit := _pick_at(mm.position)
				_hover_lbl.text = _describe_hit(hit)


func _describe_hit(hit: Dictionary) -> String:
	if hit.is_empty():
		return ""
	var units := str(_spec["fabrication"]["units"])
	var kind := str(hit["kind"])
	var id := str(hit["id"])
	match kind:
		"strut":
			var c := DomeLabDesign.strut_class(_design, id)
			if c.is_empty():
				return "Strut %s" % id
			var e: Dictionary = _design["edges"][int(hit["edge"])]
			return "Strut %s · cut %s · node to node %s · dips %s / %s" % [id, DomeLabSpec.fmt_len(float(c["cut"]) * 1000.0, units),
				DomeLabSpec.fmt_len(float(e["len"]) * 1000.0, units), DomeLabSpec.fmt_deg(rad_to_deg(float(e["dip_a"]))),
				DomeLabSpec.fmt_deg(rad_to_deg(float(e["dip_b"])))]
		"hub":
			for h in _design["hubs"]:
				if int(h["id"]) == int(hit["vertex"]):
					return "Hub %s · %d-way · vertex %d%s" % [id, int(h["valence"]), int(h["id"]), " · base" if bool(h["base"]) else ""]
			return "Hub %s" % id
		"slat":
			return "Slat %s" % id
		"rib":
			return "%s" % id
		"panel":
			return "Panel %s" % str(hit.get("label", id))
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
	return DomeLabBuilder.pick(node, inv * o, (inv.basis * d).normalized())


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


func _write_files(dir: String) -> void:
	var r := DomeLabCam.write_all(_design, dir)
	if bool(r["ok"]):
		_status("Wrote %s to %s" % [UiText.count((r["files"] as Array).size(), "file"), dir])
		_export_status.set_meta("last_dir", dir)
	else:
		_status("Export failed: %s" % str(r["error"]))


func _on_open_folder() -> void:
	var dir := str(_export_status.get_meta("last_dir", export_dir()))
	if not DirAccess.dir_exists_absolute(dir):
		_write_files(dir)
	OS.shell_open(dir)


func _on_copy_cut_sheet() -> void:
	DisplayServer.clipboard_set(DomeLabBom.cut_sheet_text(_design))
	_status("Cut sheet copied.")


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
	if _loader != null and _loader.has_method("begin_domelab_placement"):
		if bool(_loader.call("begin_domelab_placement", DomeLabSpec.to_json_safe(_spec))):
			close()
			return
	_status("Placing needs a location map.")


func _on_apply() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	var patch := {"domelab_spec": DomeLabSpec.to_json_safe(_spec)}
	if main != null:
		PlacedPropService.update_prop_record(main, _bound_prop_id, patch, true)
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
	var p := DomeLabPresets.builtin(id)
	if p.is_empty():
		return
	_spec = DomeLabSpec.resolve((p["spec"] as Dictionary).duplicate(true))
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


# ---------------------------------------------------------------------------
# The sheets, as they will be cut
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
		var pn: Dictionary = d["panels"]
		var sheets: Array = (pn.get("nest", {}) as Dictionary).get("sheets", [])
		if sheets.is_empty():
			var msg := "No panels: pick a covering under Faces, or the Plates system." if str(d["system"]) != "plate" \
				else "No plates fit the sheet — a bigger sheet under Fabrication, or a smaller dome."
			draw_string(font, Vector2(20, 40), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_MD, UITheme.C_TEXT_S)
			return
		var sw := float(pn["sheet"]["w"])
		var sh := float(pn["sheet"]["h"])
		var n := sheets.size()
		var pad := 18.0
		var top := 34.0
		var cols := mini(n, maxi(1, int(floor((size.x - pad) / 190.0))))
		var rows := int(ceil(float(n) / cols))
		var cell_w := (size.x - pad * (cols + 1)) / cols
		var cell_h := (size.y - top - pad * rows) / rows
		var k := minf(cell_w / sw, cell_h / sh)
		var hl := str(owner_modal.call("highlight"))
		draw_string(font, Vector2(pad, 24), "%s · %s × %s · %s" % [str(pn["material"]["label"]),
			DomeLabSpec.fmt_len(sw, "mm", 0), DomeLabSpec.fmt_len(sh, "mm", 0), UiText.count(n, "sheet")],
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, UITheme.C_TEXT)
		for i in n:
			var cx := pad + (i % cols) * (cell_w + pad)
			var cy := top + (i / cols) * (cell_h + pad)
			var r := Rect2(Vector2(cx, cy), Vector2(sw * k, sh * k))
			draw_rect(r, Color(0.11, 0.13, 0.18))
			draw_rect(r, UITheme.C_BORDER, false, 1.0)
			var content := DomeLabPanels.sheet_content(pn, int(sheets[i]["index"]))
			for ring in content["outside"]:
				var pts: PackedVector2Array = FlatpackProfile.tessellate(ring, 20.0)
				var poly := PackedVector2Array()
				for q in pts:
					poly.append(Vector2(r.position.x + q.x * k, r.end.y - q.y * k))
				if poly.size() >= 3:
					draw_colored_polygon(poly, Color(0.80, 0.66, 0.42, 0.25))
					poly.append(poly[0])
					draw_polyline(poly, UITheme.C_ERROR, 1.0)
			for ring in content["inside"]:
				var pts: PackedVector2Array = FlatpackProfile.tessellate(ring, 5.0)
				var poly := PackedVector2Array()
				for q in pts:
					poly.append(Vector2(r.position.x + q.x * k, r.end.y - q.y * k))
				if poly.size() >= 3:
					poly.append(poly[0])
					draw_polyline(poly, UITheme.C_PRIMARY, 1.0)
			for f in content["fold"]:
				var a: Vector2 = f["a"]
				var b: Vector2 = f["b"]
				draw_dashed_line(Vector2(r.position.x + a.x * k, r.end.y - a.y * k),
					Vector2(r.position.x + b.x * k, r.end.y - b.y * k), UITheme.C_GREEN, 1.0, 4.0)
			for lb in content["labels"]:
				var p: Vector2 = lb["p"]
				var txt := str(lb["text"])
				var col := UITheme.C_AMBER if (not hl.is_empty() and txt.begins_with(hl + "-")) else UITheme.C_TEXT
				var fs := clampi(int(float(lb["size"]) * k * 1.4), 8, 14)
				draw_string(font, Vector2(r.position.x + p.x * k - 12.0, r.end.y - p.y * k + 4.0), txt,
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
			draw_string(font, r.position + Vector2(4, -4), "Sheet %d" % (i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1,
				UITheme.FONT_XS, UITheme.C_TEXT_S)


# ---------------------------------------------------------------------------
# Hub templates
# ---------------------------------------------------------------------------

class HubCanvas extends Control:
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
		var types: Array = d["hub_types"]
		if types.is_empty():
			var msg := "Plates and nexorades have no hubs." if str(d["system"]) in ["plate", "nexorade"] else "No hubs."
			draw_string(font, Vector2(20, 40), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_MD, UITheme.C_TEXT_S)
			return
		var hl := str(owner_modal.call("highlight"))
		var n := types.size()
		var pad := 16.0
		var cols := mini(n, maxi(1, int(floor(size.x / 210.0))))
		var rows := int(ceil(float(n) / cols))
		var cell := Vector2((size.x - pad * (cols + 1)) / cols, (size.y - 30.0 - pad * (rows + 1)) / rows)
		var rad := minf(cell.x, cell.y) * 0.36
		var s: Dictionary = d["spec"]
		draw_string(font, Vector2(pad, 22), "Hub patterns — arm bearings round the hub axis, with each arm's dip below the tangent plane%s" % [
			" (plate drill templates export as DXF / SVG)" if str(s["hub"]["kind"]) == "plate" and str(s["system"]) == "hub" else ""],
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, UITheme.C_TEXT)
		for i in n:
			var t: Dictionary = types[i]
			var cx := pad + (i % cols) * (cell.x + pad) + cell.x * 0.5
			var cy := 30.0 + pad + (i / cols) * (cell.y + pad) + cell.y * 0.5
			var c := Vector2(cx, cy)
			var on := str(t["label"]) == hl
			draw_circle(c, rad, Color(0.13, 0.15, 0.21) if not on else Color(0.30, 0.22, 0.08))
			draw_arc(c, rad, 0.0, TAU, 48, UITheme.C_AMBER if on else UITheme.C_BORDER, 1.5)
			var az := 0.0
			var gaps: Array = t["gaps"]
			var dips: Array = t["dips"]
			for k in gaps.size():
				var dir := Vector2(cos(az), -sin(az))
				draw_line(c, c + dir * rad * 0.9, UITheme.C_TEXT, 2.0)
				draw_circle(c + dir * rad * 0.72, 3.0, UITheme.C_PRIMARY)
				draw_string(font, c + dir * (rad + 14.0) - Vector2(12, -4), "%.1f°" % rad_to_deg(float(dips[k])),
					HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS, UITheme.C_TEXT_S)
				az += deg_to_rad(float(gaps[k]))
			draw_circle(c, 4.0, UITheme.C_TEXT)
			draw_string(font, Vector2(cx - cell.x * 0.5 + 4.0, cy + rad + 30.0), "%s × %d — %d-way%s, gaps %s" % [
				str(t["label"]), int(t["count"]), int(t["valence"]), " (base)" if bool(t["base"]) else "",
				DomeLabBom._gap_text(t)], HORIZONTAL_ALIGNMENT_LEFT, int(cell.x) - 8, UITheme.FONT_XS,
				UITheme.C_AMBER if on else UITheme.C_TEXT_S)
