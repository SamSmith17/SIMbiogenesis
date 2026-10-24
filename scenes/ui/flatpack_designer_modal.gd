extends Control

## The flat-pack furniture designer: parametric slotted-plywood furniture
## (the Burning Man "PlayaTech" style) with full cut measurements, sheet
## nesting and CNC files.
##
## Left:   furniture types, built-in designs and the player's library.
## Centre: the assembled piece in a 3D studio (pose, explode, build scrub;
##         click a part to select it), the nested sheets as they will be cut,
##         and for chairs and loungers the side-profile editor.
## Right:  size, material, joinery, machine and style settings, the parts,
##         the cut list and bill of materials, the checks, and the export.
## Footer: place a new piece in the world, or apply to the placed one.
##
## Everything reads one solved FlatpackDesign, so the 3D model, the sheets,
## the cut list and the DXF / SVG files always agree. Undo / redo keep whole
## spec snapshots (Ctrl+Z / Ctrl+Y).

const MODAL_NAME := "flatpack_designer"
const WANT := Vector2(1600, 960)
const UNDO_LIMIT := 60
const REBUILD_DELAY := 0.12
const EXPORT_ROOT := "user://flatpack_designs"
const BITS := [[0.0, "Laser / none"], [0.125, "1/8\""], [0.1875, "3/16\""], [0.25, "1/4\""],
	[0.375, "3/8\""], [0.5, "1/2\""]]

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
var _studio_dirty := true
var _built_type := ""
var _suppress := false

var _pose := ""
var _explode := 0.0
var _assembly := 1.0
var _playing := false
var _selected := ""
var _selected_joint := ""
var _library: Array = []
var _status_text := ""

# UI
var _panel: PanelContainer
var _name_edit: LineEdit
var _subtitle: Label
var _undo_btn: Button
var _redo_btn: Button
var _type_box: VBoxContainer
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
var _profile_canvas: Control
var _pose_opt: OptionButton
var _explode_slider: HSlider
var _assembly_slider: HSlider
var _play_btn: Button
var _hover_lbl: Label
var _param_box: VBoxContainer
var _material_box: VBoxContainer
var _joinery_box: VBoxContainer
var _machine_box: VBoxContainer
var _style_box: VBoxContainer
var _parts_box: VBoxContainer
var _cut_box: VBoxContainer
var _bom_lbl: Label
var _warn_box: VBoxContainer
var _export_status: Label
var _apply_btn: Button
var _place_btn: Button
var _file_dialog: FileDialog

# Studio camera
var _yaw := 0.7
var _pitch := 0.42
var _dist := 3.5
var _target := Vector3(0, 0.4, 0)
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
	_spec = FlatpackSpec.resolve(spec if not spec.is_empty() else FlatpackSpec.default_spec("sofa"))
	_activate()


func open_for_prop(prop_id: String) -> void:
	if _active or prop_id.is_empty():
		return
	var rec := _prop_record(prop_id)
	var spec: Dictionary = rec.get("flatpack_spec", {}) as Dictionary
	_bound_prop_id = prop_id
	_spec = FlatpackSpec.resolve(spec if not spec.is_empty() else FlatpackSpec.default_spec("sofa"))
	_activate()


func is_open() -> bool:
	return _active


func _activate() -> void:
	_undo.clear()
	_redo.clear()
	_selected = ""
	_selected_joint = ""
	_explode = 0.0
	_assembly = 1.0
	_playing = false
	_pose = str(_spec.get("pose", ""))
	_library = FlatpackPresets.load_library()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	UiFit.keep_fitted(_panel, WANT)
	_apply_btn.visible = not _bound_prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _bound_prop_id.is_empty() else "Place in world"
	_refresh_design_list()
	_built_type = ""
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
		_assembly = minf(_assembly + delta * 0.18, 1.0)
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
	_file_dialog.title = "Choose a folder for the cut files"
	_file_dialog.dir_selected.connect(_on_export_dir_selected)
	add_child(_file_dialog)


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var icon := TextureRect.new()
	icon.texture = UiIcons.icon("hammer", 22)
	icon.modulate = UITheme.C_AMBER
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(icon)
	var title := Label.new()
	title.text = "Flat-pack furniture"
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
	var col := _scroll_column(230)
	var box: VBoxContainer = col[1]
	box.add_child(SectionHeader.make("Furniture", "hammer"))
	_type_box = VBoxContainer.new()
	_type_box.add_theme_constant_override("separation", 2)
	box.add_child(_type_box)
	for t in FlatpackSpec.TYPES:
		var b := Button.new()
		b.text = str(FlatpackSpec.TYPE_LABELS[t])
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 30)
		b.set_meta("type", t)
		b.pressed.connect(_on_type_pressed.bind(t))
		_type_box.add_child(b)
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_design_list = ItemList.new()
	_design_list.custom_minimum_size = Vector2(0, 300)
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
	_tabs.add_tab("Assembled")
	_tabs.add_tab("Sheets")
	_tabs.add_tab("Side profile")
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
	_profile_canvas = ProfileCanvas.new()
	_profile_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_profile_canvas.visible = false
	_profile_canvas.set("owner_modal", self)
	_view_stack.add_child(_profile_canvas)
	# Controls under the view.
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var pl := Label.new()
	pl.text = "Pose"
	bar.add_child(pl)
	_pose_opt = OptionButton.new()
	_pose_opt.item_selected.connect(_on_pose_selected)
	bar.add_child(_pose_opt)
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
	_play_btn.tooltip_text = "Watch the parts go together in order"
	UITheme.style_button(_play_btn)
	_play_btn.pressed.connect(_on_play_build)
	bar.add_child(_play_btn)
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
	plane.size = Vector2(40, 40)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.20, 0.19, 0.18)
	gmat.roughness = 0.95
	ground.material_override = gmat
	_studio.add_child(ground)
	_holder = Node3D.new()
	_holder.name = "Holder"
	_studio.add_child(_holder)
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.far = 200.0
	_studio.add_child(_camera)
	_update_camera()


func _build_right() -> Control:
	var col := _scroll_column(380)
	var box: VBoxContainer = col[1]
	var sec := Collapsible.make("Size", true)
	box.add_child(sec)
	_param_box = sec.body
	sec = Collapsible.make("Material", true)
	box.add_child(sec)
	_material_box = sec.body
	sec = Collapsible.make("Joinery", false)
	box.add_child(sec)
	_joinery_box = sec.body
	sec = Collapsible.make("Machine", false)
	box.add_child(sec)
	_machine_box = sec.body
	sec = Collapsible.make("Style", false)
	box.add_child(sec)
	_style_box = sec.body
	box.add_child(SectionHeader.make("Checks", "circle-check"))
	_warn_box = VBoxContainer.new()
	box.add_child(_warn_box)
	sec = Collapsible.make("Parts", false)
	box.add_child(sec)
	_parts_box = sec.body
	box.add_child(SectionHeader.make("Cut list", "ruler"))
	_bom_lbl = Label.new()
	_bom_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bom_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(_bom_lbl)
	_cut_box = VBoxContainer.new()
	_cut_box.add_theme_constant_override("separation", 1)
	box.add_child(_cut_box)
	box.add_child(SectionHeader.make("CNC files", "download"))
	var ex := HFlowContainer.new()
	ex.add_theme_constant_override("h_separation", UITheme.SPACE_XS)
	ex.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
	for spec_btn in [["Export DXF + SVG", "Write one DXF and one SVG per sheet, a fit-test coupon and the cut list", _on_export],
			["Save to…", "Choose a folder for the files", _on_export_to],
			["Open folder", "Show the exported files", _on_open_folder],
			["Copy cut list", "Put the cut list on the clipboard", _on_copy_cut_list]]:
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
	hint.text = "Drag to orbit · wheel to zoom · click a part to select it"
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(hint)
	_apply_btn = Button.new()
	_apply_btn.text = "Apply to placed furniture"
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
	_built_type = ""
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


## Re-solve and refresh every panel. The parameter rows are rebuilt only when
## the furniture type changes (so a spin box never loses focus mid-edit).
func _rebuild_now() -> void:
	_rebuild_timer = -1.0
	_spec = FlatpackSpec.resolve(_spec)
	_design = FlatpackDesign.solve(_spec)
	if str(_spec["type"]) != _built_type:
		_built_type = str(_spec["type"])
		_build_settings_rows()
		_fill_poses()
		_frame_camera()
	_sync_settings()
	_studio_dirty = true
	_rebuild_studio()
	_refresh_parts()
	_refresh_cut_list()
	_refresh_warnings()
	_refresh_header()
	_sheet_canvas.queue_redraw()
	_profile_canvas.queue_redraw()
	_tabs.set_tab_disabled(2, not str(_spec["type"]) in ["chair", "lounger"])
	if _tabs.current_tab == 2 and _tabs.is_tab_disabled(2):
		_tabs.current_tab = 0
	_show_view()
	_update_undo_buttons()


func _refresh_header() -> void:
	if not _name_edit.has_focus():
		_name_edit.text = str(_spec["name"])
	var bom: Dictionary = _design.get("bom", {})
	var size: Vector3 = _design.get("size", Vector3.ZERO)
	_subtitle.text = "%s · %s · %s · %s" % [FlatpackSpec.TYPE_LABELS.get(_spec["type"], ""),
		_fmt_size3(size), UiText.count(int(bom.get("parts", 0)), "part"),
		UiText.count(int(bom.get("sheets", 0)), "sheet")]


func _fmt_size3(v: Vector3) -> String:
	return "%s W × %s D × %s H" % [FlatpackSpec.fmt_in(v.x, 8), FlatpackSpec.fmt_in(v.z, 8),
		FlatpackSpec.fmt_in(v.y, 8)]


func _on_name_changed() -> void:
	var t := _name_edit.text.strip_edges()
	if t.is_empty() or t == str(_spec.get("name", "")):
		return
	_edit("", "name", t)


func _on_type_pressed(t: String) -> void:
	if t == str(_spec.get("type", "")):
		_sync_type_buttons()
		return
	_push_undo()
	var keep_mat: Dictionary = _spec.get("material", {})
	var keep_mc: Dictionary = _spec.get("machine", {})
	var keep_style: Dictionary = _spec.get("style", {})
	_spec = FlatpackSpec.default_spec(t)
	_spec["material"] = keep_mat.duplicate(true)
	_spec["machine"] = keep_mc.duplicate(true)
	_spec["style"] = keep_style.duplicate(true)
	_selected = ""
	_rebuild_now()


func _sync_type_buttons() -> void:
	for b in _type_box.get_children():
		var on: bool = str(b.get_meta("type", "")) == str(_spec.get("type", ""))
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


## A spin box. Lengths (suffix ") step their arrows by `step` but hold and
## show thousandths: Godot takes a spin box's decimals from its step, so a
## 1/4" step would print 23.75" as "23.8" — wrong on a cutting tool.
func _spin(min_v: float, max_v: float, step: float, suffix: String, cb: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = 0.001 if suffix == "\"" else step
	s.suffix = suffix
	s.custom_arrow_step = step
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
	var type := str(_spec["type"])
	_clear(_param_box)
	for row in FlatpackSpec.param_rows(type):
		var key := str(row["key"])
		var label := str(row["label"])
		var tip := str(row.get("tip", ""))
		var ctl: Control
		match str(row["unit"]):
			"bool":
				ctl = _check("", func(on): _edit("params", key, on))
			"count":
				ctl = _spin(float(row["min"]), float(row["max"]), 1.0, "", func(v): _edit("params", key, int(v)))
			"deg":
				ctl = _spin(float(row["min"]), float(row["max"]), float(row["step"]), "°", func(v): _edit("params", key, v))
			"pct":
				ctl = _spin(float(row["min"]) * 100.0, float(row["max"]) * 100.0, float(row["step"]) * 100.0, "%",
					func(v): _edit("params", key, v / 100.0))
			_:
				ctl = _spin(float(row["min"]), float(row["max"]), float(row["step"]), "\"", func(v): _edit("params", key, v))
		ctl.set_meta("param", key)
		ctl.set_meta("unit", str(row["unit"]))
		_row(_param_box, label, ctl, tip)
	if type == "sofa":
		var fit := Button.new()
		fit.text = "Fit parts to the sheets"
		fit.tooltip_text = "Size the rails, deck and braces so they rip cleanly from your sheets with this spacing"
		UITheme.style_button(fit)
		fit.pressed.connect(_on_fit_to_sheets)
		_param_box.add_child(fit)
	_build_material_rows()
	_build_machine_rows()
	_build_style_rows()
	_build_joinery_rows()
	_sync_type_buttons()


func _build_material_rows() -> void:
	_clear(_material_box)
	var sheets: Array = []
	for k in ["4x8", "4x4", "5x5", "2x4", "custom"]:
		sheets.append([k, FlatpackSpec.SHEET_LABELS[k]])
	var so := _option(sheets, func(v): _edit("material", "sheet", str(v)))
	so.set_meta("mat", "sheet")
	_row(_material_box, "Sheet", so)
	var sw := _spin(12.0, 120.0, 0.125, "\"", func(v): _edit("material", "sheet_w", v))
	sw.set_meta("mat", "sheet_w")
	_row(_material_box, "Sheet width", sw)
	var sh := _spin(12.0, 144.0, 0.125, "\"", func(v): _edit("material", "sheet_h", v))
	sh.set_meta("mat", "sheet_h")
	_row(_material_box, "Sheet length", sh)
	var th: Array = []
	for k in ["1/4", "3/8", "1/2", "5/8", "3/4", "12mm", "18mm", "custom"]:
		th.append([k, FlatpackSpec.THICKNESS_LABELS[k]])
	var to := _option(th, func(v): _edit("material", "nominal", str(v)))
	to.set_meta("mat", "nominal")
	_row(_material_box, "Plywood", to, "Slots are cut to the ACTUAL thickness: measure your sheets and pick Measured if they differ")
	var tm := _spin(0.1, 1.5, 0.001, "\"", func(v): _edit("material", "thickness", v))
	tm.set_meta("mat", "thickness")
	_row(_material_box, "Measured thickness", tm)
	var gl := _check("Keep the grain along each part", func(on): _edit("material", "grain_lock", on))
	gl.set_meta("mat", "grain_lock")
	_material_box.add_child(gl)


func _build_machine_rows() -> void:
	_clear(_machine_box)
	var bo := _option(BITS, func(v): _edit("machine", "bit_d", float(v)))
	bo.set_meta("mc", "bit_d")
	_row(_machine_box, "Router bit", bo, "Sets the dogbone size. A laser cuts sharp corners.")
	var cl := _spin(0.0, 0.05, 0.001, "\"", func(v): _edit("machine", "clearance", v))
	cl.set_meta("mc", "clearance")
	_row(_machine_box, "Slot clearance", cl, "Added to each side of every slot. 0.005–0.015\" is typical for a snug fit.")
	var sp := _spin(0.0, 3.0, 0.0625, "\"", func(v): _edit("machine", "spacing", v))
	sp.set_meta("mc", "spacing")
	_row(_machine_box, "Space between parts", sp)
	var mg := _spin(0.0, 4.0, 0.0625, "\"", func(v): _edit("machine", "margin", v))
	mg.set_meta("mc", "margin")
	_row(_machine_box, "Sheet margin", mg, "0 cuts right to the factory edge")
	var rl: Array = []
	for k in FlatpackProfile.RELIEF_STYLES:
		rl.append([k, FlatpackSpec.RELIEF_LABELS[k]])
	var ro := _option(rl, func(v): _edit("machine", "relief", str(v)))
	ro.set_meta("mc", "relief")
	_row(_machine_box, "Inside corners", ro, "Dogbones overcut both walls; T-bones only sideways, keeping slot bottoms flat")
	var pd := _spin(0.02, 1.5, 0.0625, "\"", func(v): _edit("machine", "pass_depth", v))
	pd.set_meta("mc", "pass_depth")
	_row(_machine_box, "Depth per pass", pd)
	var fd := _spin(10.0, 1500.0, 10.0, " in/min", func(v): _edit("machine", "feed_ipm", v))
	fd.set_meta("mc", "feed_ipm")
	_row(_machine_box, "Feed rate", fd)
	var uo := _option([["in", "Inches"], ["mm", "Millimetres"]], func(v): _edit("machine", "units", str(v)))
	uo.set_meta("mc", "units")
	_row(_machine_box, "File units", uo)
	var lb := _check("Engrave part labels", func(on): _edit("machine", "labels", on))
	lb.set_meta("mc", "labels")
	_machine_box.add_child(lb)


func _build_style_rows() -> void:
	_clear(_style_box)
	var cr := _spin(0.0, 6.0, 0.125, "\"", func(v): _edit("style", "corner_r", v))
	cr.set_meta("st", "corner_r")
	_row(_style_box, "Corner radius", cr)
	var fa := _check("Foot arches", func(on): _edit("style", "foot_arch", on))
	fa.set_meta("st", "foot_arch")
	_style_box.add_child(fa)


func _build_joinery_rows() -> void:
	_clear(_joinery_box)
	var w := _check("Wedge the stretchers", func(on): _edit("joinery", "wedges", on))
	w.set_meta("jn", "wedges")
	w.tooltip_text = "A wedge through each stretcher tab pulls the joint tight; off = plain tabs"
	_joinery_box.add_child(w)
	var note := Label.new()
	note.text = "Pick a joint to change it:"
	note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_joinery_box.add_child(note)
	var jo := OptionButton.new()
	jo.set_meta("jn", "joint")
	jo.item_selected.connect(func(idx): _selected_joint = str(jo.get_item_metadata(idx)); _sync_joint_rows())
	_joinery_box.add_child(jo)
	var ko := _option([["cross_lap", "Cross-lap slots"], ["tenon", "Tab through a mortise"]],
		func(v): _edit_joint("kind", str(v)))
	ko.set_meta("jn", "kind")
	_row(_joinery_box, "Joint", ko)
	var wc := _check("Wedge this tab", func(on): _edit_joint("wedge", on))
	wc.set_meta("jn", "wedge")
	_joinery_box.add_child(wc)
	var rs := _spin(0.0, 100.0, 5.0, "%", func(v): _edit_joint("ratio", v / 100.0))
	rs.set_meta("jn", "ratio")
	_row(_joinery_box, "First part's share", rs, "How much of the overlap the first-named part's slot takes")
	var rst := Button.new()
	rst.text = "Reset this joint"
	UITheme.style_button(rst)
	rst.pressed.connect(func():
		var ov: Dictionary = (_spec["joinery"] as Dictionary).get("overrides", {})
		if ov.has(_selected_joint):
			_push_undo()
			ov.erase(_selected_joint)
			_queue_rebuild())
	_joinery_box.add_child(rst)


func _edit_joint(key: String, value: Variant) -> void:
	if _suppress or _selected_joint.is_empty():
		return
	_push_undo("joint.%s.%s" % [_selected_joint, key])
	var j: Dictionary = _spec["joinery"]
	var ov: Dictionary = j.get("overrides", {})
	var e: Dictionary = ov.get(_selected_joint, {})
	e[key] = value
	ov[_selected_joint] = e
	j["overrides"] = ov
	_queue_rebuild()


func _joint_label(j: Dictionary) -> String:
	var a := FlatpackDesign.part(_design, str(j["a"]))
	var b := FlatpackDesign.part(_design, str(j["b"]))
	var la := str(a.get("label", "")) + " " + str(a.get("name", j["a"]))
	var lb := str(b.get("label", "")) + " " + str(b.get("name", j["b"]))
	var pose := str(j.get("pose", ""))
	var suffix := (" · " + str(FlatpackSpec.POSE_LABELS.get(pose, pose))) if not pose.is_empty() else ""
	return "%s ↔ %s%s" % [la.strip_edges(), lb.strip_edges(), suffix]


## Push the spec's values into the rows (no signals).
func _sync_settings() -> void:
	_suppress = true
	for row in _param_box.get_children():
		for c in (row.get_children() if row is HBoxContainer else [row]):
			if not c.has_meta("param"):
				continue
			var v: Variant = (_spec["params"] as Dictionary).get(str(c.get_meta("param")))
			if c is CheckBox:
				(c as CheckBox).set_pressed_no_signal(bool(v))
			elif c is SpinBox:
				var f := float(v) * (100.0 if str(c.get_meta("unit")) == "pct" else 1.0)
				(c as SpinBox).set_value_no_signal(f)
	var m: Dictionary = _spec["material"]
	var mc: Dictionary = _spec["machine"]
	var st: Dictionary = _spec["style"]
	for c in _all_controls(_material_box):
		var k := str(c.get_meta("mat", ""))
		if k.is_empty():
			continue
		_set_ctl(c, m.get(k))
		if k == "sheet_w" or k == "sheet_h":
			(c.get_parent() as Control).visible = str(m["sheet"]) == "custom"
		if k == "thickness":
			(c.get_parent() as Control).visible = str(m["nominal"]) == "custom"
	for c in _all_controls(_machine_box):
		var k := str(c.get_meta("mc", ""))
		if not k.is_empty():
			_set_ctl(c, mc.get(k))
	for c in _all_controls(_style_box):
		var k := str(c.get_meta("st", ""))
		if not k.is_empty():
			_set_ctl(c, st.get(k))
	for c in _all_controls(_joinery_box):
		if str(c.get_meta("jn", "")) == "wedges":
			_set_ctl(c, (_spec["joinery"] as Dictionary).get("wedges", true))
		elif str(c.get_meta("jn", "")) == "joint":
			var jo := c as OptionButton
			jo.clear()
			var joints: Array = _design.get("joints", [])
			var idx := 0
			var sel := -1
			for j in joints:
				jo.add_item(_joint_label(j), idx)
				jo.set_item_metadata(idx, str(j["id"]))
				if str(j["id"]) == _selected_joint:
					sel = idx
				idx += 1
			if sel < 0 and idx > 0:
				sel = 0
				_selected_joint = str(jo.get_item_metadata(0))
			if sel >= 0:
				jo.select(sel)
	_suppress = false
	_sync_joint_rows()
	_sync_type_buttons()


func _sync_joint_rows() -> void:
	_suppress = true
	var j := {}
	for x in _design.get("joints", []):
		if str(x["id"]) == _selected_joint:
			j = x
	for c in _all_controls(_joinery_box):
		match str(c.get_meta("jn", "")):
			"kind":
				_set_ctl(c, str(j.get("kind", "cross_lap")))
			"wedge":
				_set_ctl(c, bool(j.get("wedge", false)))
				(c as Control).visible = str(j.get("kind", "")) == "tenon"
			"ratio":
				_set_ctl(c, float(j.get("ratio", 0.5)) * 100.0)
				(c.get_parent() as Control).visible = str(j.get("kind", "")) == "cross_lap"
	_suppress = false


func _all_controls(root: Node) -> Array:
	var out: Array = []
	for c in root.get_children():
		if c is HBoxContainer:
			for cc in c.get_children():
				out.append(cc)
		else:
			out.append(c)
	return out


func _set_ctl(c: Node, v: Variant) -> void:
	if v == null:
		return
	if c is CheckBox:
		(c as CheckBox).set_pressed_no_signal(bool(v))
	elif c is SpinBox:
		(c as SpinBox).set_value_no_signal(float(v))
	elif c is OptionButton:
		_select_meta(c as OptionButton, v)


func _on_fit_to_sheets() -> void:
	var m: Dictionary = _spec["material"]
	var mc: Dictionary = _spec["machine"]
	var sw := float(m["sheet_w"])
	var gap := float(mc["spacing"])
	var margin := float(mc["margin"])
	var rail := FlatpackNesting.fit_to_sheet(4, sw, gap, margin)
	var p: Dictionary = _spec["params"]
	_push_undo()
	p["frame_h"] = clampf(rail, 8.0, 18.0)
	p["brace_w"] = clampf(rail, 6.0, 16.0)
	p["deck_depth"] = clampf(floor((sw - 2.0 * margin - rail - gap) * 8.0) / 8.0, 24.0, 48.0)
	p["arm_h"] = clampf(floor((sw - 2.0 * margin - gap) * 0.5 * 8.0) / 8.0, 14.0, 36.0)
	p["brace_len"] = clampf(floor((sw - 2.0 * margin - gap) * 0.5 * 8.0) / 8.0, 12.0, 30.0)
	_queue_rebuild()
	_status("Sized for %s sheets with %s between parts." % [FlatpackSpec.fmt_size(sw, float(m["sheet_h"])),
		FlatpackSpec.fmt_in(gap)])


# ---------------------------------------------------------------------------
# Lists
# ---------------------------------------------------------------------------

func _refresh_parts() -> void:
	_clear(_parts_box)
	for p in _design.get("parts", []):
		var row := HBoxContainer.new()
		var b := Button.new()
		var bb: Rect2 = p["bbox"]
		b.text = "%s  %s  %s" % [str(p.get("label", "")), str(p["name"]),
			FlatpackSpec.fmt_size(bb.size.x, bb.size.y, str(_spec["machine"]["units"]))]
		b.toggle_mode = true
		b.set_pressed_no_signal(str(p["id"]) == _selected)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.clip_text = true
		b.tooltip_text = "%s: %s, %s" % [str(p["name"]), UiText.count((p["notches"] as Array).size(), "slot"),
			UiText.count((p["holes"] as Array).size(), "hole")]
		UITheme.style_toggle(b, str(p["id"]) == _selected)
		b.pressed.connect(_select_part.bind(str(p["id"])))
		row.add_child(b)
		var hide := CheckBox.new()
		hide.text = "Hide"
		hide.tooltip_text = "Hide in the 3D view (still cut)"
		hide.set_pressed_no_signal(bool(p.get("hidden", false)))
		var pid := str(p["id"])
		hide.toggled.connect(func(on): _set_part_override(pid, "hidden", on))
		row.add_child(hide)
		_parts_box.add_child(row)


func _set_part_override(pid: String, key: String, value: Variant) -> void:
	_push_undo()
	var pov: Dictionary = _spec.get("part_overrides", {})
	var e: Dictionary = pov.get(pid, {})
	e[key] = value
	pov[pid] = e
	_spec["part_overrides"] = pov
	_queue_rebuild()


func _refresh_cut_list() -> void:
	_clear(_cut_box)
	var units := str(_spec["machine"]["units"])
	var bom: Dictionary = _design.get("bom", {})
	_bom_lbl.text = "%s of %s · %d%% used\nCut length %.0f ft in %s · about %s on the router\nAbout %.0f kg (%.0f lb)" % [
		UiText.count(int(bom.get("sheets", 0)), "sheet"),
		FlatpackSpec.SHEET_LABELS.get(str(_spec["material"]["sheet"]), "custom stock"),
		int(round(float(bom.get("utilization", 0.0)) * 100.0)), float(bom.get("cut_ft", 0.0)),
		UiText.count(int(bom.get("passes", 1)), "pass", "passes"),
		UiText.duration(float(bom.get("cut_min", 0.0)) / 60.0), float(bom.get("mass_kg", 0.0)),
		float(bom.get("mass_kg", 0.0)) / FlatpackSpec.LB_TO_KG]
	var head := _cut_row(["", "Part", "Qty", "Size", "Slots", "Sheet"], true)
	_cut_box.add_child(head)
	for r in _design.get("cut_list", []):
		var sheets := ", ".join(PackedStringArray((r["sheets"] as Array).map(func(v): return str(v))))
		_cut_box.add_child(_cut_row([str(r.get("label", "")), str(r["name"]), str(int(r["qty"])),
			FlatpackSpec.fmt_size(float(r["w"]), float(r["h"]), units),
			str(int(r["notches"]) + int(r["holes"])), sheets], false))


func _cut_row(cells: Array, head: bool) -> Control:
	var row := HBoxContainer.new()
	var widths := [26, 100, 30, 130, 40, 44]
	for i in cells.size():
		var l := Label.new()
		l.text = str(cells[i])
		l.custom_minimum_size = Vector2(widths[i], 0)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.add_theme_font_size_override("font_size", UITheme.FONT_XS if head else UITheme.FONT_SM)
		l.add_theme_color_override("font_color", UITheme.C_TEXT_M if head else UITheme.C_TEXT)
		if i == 3:
			l.add_theme_font_override("font", UITheme.font("regular", true))
		row.add_child(l)
	return row


func _refresh_warnings() -> void:
	_clear(_warn_box)
	var w: Array = _design.get("warnings", [])
	var pose := _pose
	var clashes: Array = FlatpackJoints.interference(_design, pose if not pose.is_empty() else str(_design.get("pose", "")))
	if w.is_empty() and clashes.is_empty():
		var ok := Label.new()
		ok.text = "Everything slots together and fits the sheets."
		ok.add_theme_color_override("font_color", UITheme.C_OK)
		ok.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_warn_box.add_child(ok)
		return
	for c in clashes:
		var a := FlatpackDesign.part(_design, str(c["a"]))
		var b := FlatpackDesign.part(_design, str(c["b"]))
		_warn_line("%s and %s run into each other (%s)" % [str(a.get("name", c["a"])), str(b.get("name", c["b"])),
			FlatpackSpec.fmt_in(float(c["length_in"]), 8)], UITheme.C_ERROR)
	for x in w:
		_warn_line(str(x), UITheme.C_WARN)


func _warn_line(text: String, color: Color) -> void:
	var l := Label.new()
	l.text = "• " + text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_warn_box.add_child(l)


func _fill_poses() -> void:
	_pose_opt.clear()
	var poses: Array = _design.get("poses", [])
	if poses.is_empty():
		_pose_opt.add_item("Assembled", 0)
		_pose_opt.set_item_metadata(0, "")
		_pose_opt.disabled = true
		_pose = ""
		return
	_pose_opt.disabled = false
	var sel := 0
	for i in poses.size():
		_pose_opt.add_item(str(poses[i]["label"]), i)
		_pose_opt.set_item_metadata(i, str(poses[i]["id"]))
		if str(poses[i]["id"]) == _pose:
			sel = i
	_pose_opt.select(sel)
	_pose = str(poses[sel]["id"])


func _on_pose_selected(idx: int) -> void:
	_pose = str(_pose_opt.get_item_metadata(idx))
	_spec["pose"] = _pose
	_studio_dirty = true
	_rebuild_studio()
	_refresh_warnings()


func _select_part(id: String) -> void:
	_selected = "" if id == _selected else id
	_studio_dirty = true
	_rebuild_studio()
	_refresh_parts()
	_sheet_canvas.queue_redraw()
	var p := FlatpackDesign.part(_design, _selected)
	if not p.is_empty():
		var bb: Rect2 = p["bbox"]
		_hover_lbl.text = "%s %s · %s · %s, %s · sheet %d" % [str(p.get("label", "")), str(p["name"]),
			FlatpackSpec.fmt_size(bb.size.x, bb.size.y, str(_spec["machine"]["units"])),
			UiText.count((p["notches"] as Array).size(), "slot"), UiText.count((p["holes"] as Array).size(), "hole"),
			int(p.get("sheet", 0)) + 1]


# ---------------------------------------------------------------------------
# Designs
# ---------------------------------------------------------------------------

func _refresh_design_list() -> void:
	_design_list.clear()
	_design_entries.clear()
	for p in FlatpackPresets.builtins():
		var i := _design_list.add_item(str(p["name"]))
		_design_list.set_item_tooltip(i, str(p.get("blurb", "")))
		_design_entries.append({"kind": "builtin", "id": str(p["id"]), "spec": p["spec"]})
	for d in _library:
		var i2 := _design_list.add_item("★ " + str(d["name"]))
		_design_list.set_item_tooltip(i2, "Saved design")
		_design_entries.append({"kind": "saved", "id": str(d["id"]), "spec": d["spec"]})


func _on_design_activated(idx: int) -> void:
	if idx < 0 or idx >= _design_entries.size():
		return
	_push_undo()
	_spec = FlatpackSpec.resolve((_design_entries[idx]["spec"] as Dictionary).duplicate(true))
	_pose = str(_spec.get("pose", ""))
	_selected = ""
	_built_type = ""
	_rebuild_now()


func _on_save_design() -> void:
	var name := str(_spec.get("name", "Design"))
	var id := "d%d" % Time.get_unix_time_from_system()
	for d in _library:
		if str(d["name"]) == name:
			d["spec"] = _spec.duplicate(true)
			id = ""
	if not id.is_empty():
		_library.append({"id": id, "name": name, "spec": _spec.duplicate(true)})
	if FlatpackPresets.save_library(_library):
		_status("Saved “%s” to your library." % name)
	else:
		_status("Could not write the library file.")
	_refresh_design_list()


func _on_forget_design() -> void:
	var sel := _design_list.get_selected_items()
	if sel.is_empty():
		return
	var e: Dictionary = _design_entries[sel[0]]
	if str(e["kind"]) != "saved":
		_status("Built-in designs stay; pick a saved (★) one.")
		return
	for i in _library.size():
		if str(_library[i]["id"]) == str(e["id"]):
			_library.remove_at(i)
			break
	FlatpackPresets.save_library(_library)
	_refresh_design_list()


# ---------------------------------------------------------------------------
# Studio
# ---------------------------------------------------------------------------

func _show_view() -> void:
	var t := _tabs.current_tab
	_vp_container.visible = t == 0
	_sheet_canvas.visible = t == 1
	_profile_canvas.visible = t == 2
	_pose_opt.get_parent().visible = t == 0


func _rebuild_studio() -> void:
	if _holder == null or _design.is_empty():
		return
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	var node := FlatpackBuilder.build_from_design(_design, "Furniture", {"pose": _pose,
		"explode": _explode, "assembly": _assembly, "highlight": _selected, "record": true})
	_holder.add_child(node)
	_studio_dirty = false


func _frame_camera() -> void:
	var size: Vector3 = _design.get("size", Vector3(40, 30, 30)) * FlatpackBuilder.IN
	_target = Vector3(0, size.y * 0.45, 0)
	_dist = clampf(maxf(size.x, maxf(size.y, size.z)) * 1.9 + 0.4, 1.0, 12.0)
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
			_dist = maxf(0.6, _dist * 0.9)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(14.0, _dist * 1.1)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_orbiting = true
				_moved = false
				_press_pos = mb.position
			else:
				_orbiting = false
				if not _moved and mb.button_index == MOUSE_BUTTON_LEFT:
					_select_part(_pick_at(mb.position))
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _orbiting:
			if mm.position.distance_to(_press_pos) > 4.0:
				_moved = true
			if _moved:
				_yaw -= mm.relative.x * 0.01
				_pitch = clampf(_pitch - mm.relative.y * 0.01, 0.02, 1.45)
				_update_camera()
		else:
			var id := _pick_at(mm.position)
			var p := FlatpackDesign.part(_design, id)
			if not p.is_empty() and _selected.is_empty():
				var bb: Rect2 = p["bbox"]
				_hover_lbl.text = "%s %s · %s" % [str(p.get("label", "")), str(p["name"]),
					FlatpackSpec.fmt_size(bb.size.x, bb.size.y, str(_spec["machine"]["units"]))]


func _pick_at(pos: Vector2) -> String:
	if _camera == null or _holder.get_child_count() == 0:
		return ""
	var vp_size := Vector2(_viewport.size)
	var cs := _vp_container.size
	var p := pos * (vp_size / cs) if cs.x > 0.0 and cs.y > 0.0 else pos
	var o := _camera.project_ray_origin(p)
	var d := _camera.project_ray_normal(p)
	var node := _holder.get_child(0) as Node3D
	var inv := node.global_transform.affine_inverse()
	return FlatpackBuilder.pick_part(node, inv * o, (inv.basis * d).normalized())


func _on_play_build() -> void:
	_playing = not _playing
	if _playing and _assembly >= 1.0:
		_assembly = 0.0
	_play_btn.text = "Pause" if _playing else "Play build"


# ---------------------------------------------------------------------------
# Export, place, apply
# ---------------------------------------------------------------------------

func export_dir() -> String:
	return ProjectSettings.globalize_path(EXPORT_ROOT.path_join(FlatpackCam.safe_name(str(_spec["name"]))))


func _on_export() -> void:
	_write_files(export_dir())


func _on_export_to() -> void:
	_file_dialog.popup_centered(Vector2i(800, 560))


func _on_export_dir_selected(dir: String) -> void:
	_write_files(dir.path_join(FlatpackCam.safe_name(str(_spec["name"]))))


func _write_files(dir: String) -> void:
	var r := FlatpackCam.write_all(_design, dir)
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


func _on_copy_cut_list() -> void:
	DisplayServer.clipboard_set(FlatpackCam.cut_list_text(_design))
	_status("Cut list copied.")


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
	if _loader != null and _loader.has_method("begin_flatpack_placement"):
		if bool(_loader.call("begin_flatpack_placement", FlatpackSpec.to_json_safe(_spec))):
			close()
			return
	_status("Placing needs a location map.")


func _on_apply() -> void:
	if _bound_prop_id.is_empty():
		return
	var main := _main_node()
	var patch := {"flatpack_spec": FlatpackSpec.to_json_safe(_spec)}
	if main != null:
		PlacedPropService.update_prop_record(main, _bound_prop_id, patch, true)
		PlacedPropService.tag_flatpack_space(main, _bound_prop_id)
	close()


# ---------------------------------------------------------------------------
# Accessors for the canvases and the harness
# ---------------------------------------------------------------------------

func design() -> Dictionary:
	return _design


func spec() -> Dictionary:
	return _spec


func selected_part() -> String:
	return _selected


func set_tab(i: int) -> void:
	_tabs.current_tab = i
	_show_view()


func load_builtin(id: String) -> void:
	var p := FlatpackPresets.builtin(id)
	if p.is_empty():
		return
	_spec = FlatpackSpec.resolve((p["spec"] as Dictionary).duplicate(true))
	_pose = str(_spec.get("pose", ""))
	_built_type = ""
	_rebuild_now()
	_frame_camera()


func set_profile_offset(key: String, offset: Vector2, commit: bool) -> void:
	if commit:
		_push_undo("profile." + key)
	var po: Dictionary = _spec.get("profile_offsets", {})
	po[key] = offset
	_spec["profile_offsets"] = po
	if commit:
		_queue_rebuild()
	else:
		_design = FlatpackDesign.solve(_spec)
		_profile_canvas.queue_redraw()


func reset_profile() -> void:
	_push_undo()
	_spec["profile_offsets"] = {}
	_queue_rebuild()


# ---------------------------------------------------------------------------
# The sheets, as they will be cut
# ---------------------------------------------------------------------------

class SheetCanvas extends Control:
	var owner_modal: Control = null
	var _hover := ""
	var _layout: Array = []   # [{rect (canvas), sheet, scale}]

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		resized.connect(queue_redraw)

	func _sheet_rects(d: Dictionary) -> Array:
		var nest: Dictionary = d.get("nest", {})
		var sheets: Array = nest.get("sheets", [])
		var sw := float(nest.get("sheet_w", 48.0))
		var sh := float(nest.get("sheet_h", 96.0))
		var n := maxi(sheets.size(), 1)
		var pad := 18.0
		var top := 34.0
		var avail := size - Vector2(pad * 2.0, top + pad)
		# One row of sheets, scaled to fit.
		var k := minf((avail.x - (n - 1) * pad) / (n * sw), avail.y / sh)
		k = maxf(k, 0.5)
		var out: Array = []
		for i in sheets.size():
			var r := Rect2(Vector2(pad + i * (sw * k + pad), top), Vector2(sw * k, sh * k))
			out.append({"rect": r, "sheet": sheets[i], "scale": k})
		return out

	func _to_canvas(p: Vector2, L: Dictionary) -> Vector2:
		var r: Rect2 = L["rect"]
		var k := float(L["scale"])
		return Vector2(r.position.x + p.x * k, r.end.y - p.y * k)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.09))
		if owner_modal == null:
			return
		var d: Dictionary = owner_modal.call("design")
		if d.is_empty():
			return
		var font := get_theme_default_font()
		_layout = _sheet_rects(d)
		var sel := str(owner_modal.call("selected_part"))
		for L in _layout:
			var r: Rect2 = L["rect"]
			draw_rect(r, Color(0.86, 0.78, 0.62))
			draw_rect(r, Color(0.45, 0.38, 0.28), false, 1.0)
			var sh: Dictionary = L["sheet"]
			var used := 0.0
			for pl in sh["placements"]:
				var p := FlatpackDesign.part(d, str(pl["id"]))
				if p.is_empty():
					continue
				used += float(p["area"])
				var bb: Rect2 = p["bbox"]
				var ring := FlatpackNesting.ring_on_sheet(p["ring"], bb, pl)
				var pts := PackedVector2Array()
				for q in FlatpackProfile.tessellate(ring, 0.5):
					pts.append(_to_canvas(q, L))
				var id := str(p["id"])
				var fill := Color(0.97, 0.88, 0.66)
				if id == sel:
					fill = Color(1.0, 0.74, 0.32)
				elif id == _hover:
					fill = Color(1.0, 0.94, 0.78)
				var tri := Geometry2D.triangulate_polygon(pts)
				if not tri.is_empty():
					var colors := PackedColorArray()
					colors.resize(pts.size())
					colors.fill(fill)
					draw_polygon(pts, colors, PackedVector2Array(), null)
					pts.append(pts[0])
				else:
					pts.append(pts[0])
				draw_polyline(pts, Color(0.80, 0.10, 0.12), 1.2, true)
				for h in p.get("hole_rings", []):
					var hp := PackedVector2Array()
					for q in FlatpackProfile.tessellate(FlatpackNesting.ring_on_sheet(h, bb, pl), 0.5):
						hp.append(_to_canvas(q, L))
					if hp.size() > 2:
						var cols := PackedColorArray()
						cols.resize(hp.size())
						cols.fill(Color(0.86, 0.78, 0.62))
						if not Geometry2D.triangulate_polygon(hp).is_empty():
							draw_polygon(hp, cols, PackedVector2Array(), null)
						hp.append(hp[0])
						draw_polyline(hp, Color(0.10, 0.37, 0.82), 1.0, true)
				var c := _to_canvas(FlatpackNesting.point_on_sheet(bb.get_center(), bb, pl), L)
				var label := str(p.get("label", ""))
				var fs := 12
				var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
				draw_string(font, c + Vector2(-tw * 0.5, fs * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
					Color(0.25, 0.18, 0.10))
			var nest: Dictionary = d["nest"]
			var pct := used / maxf(float(nest["sheet_w"]) * float(nest["sheet_h"]), 1.0)
			draw_string(font, r.position + Vector2(0, -10), "Sheet %d · %d%% used" % [int(sh["index"]) + 1,
				int(round(pct * 100.0))], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.82, 0.86, 0.92))

	func _part_at(pos: Vector2) -> String:
		if owner_modal == null:
			return ""
		var d: Dictionary = owner_modal.call("design")
		for L in _layout:
			var r: Rect2 = L["rect"]
			if not r.has_point(pos):
				continue
			var k := float(L["scale"])
			var q := Vector2((pos.x - r.position.x) / k, (r.end.y - pos.y) / k)
			for pl in (L["sheet"] as Dictionary)["placements"]:
				var p := FlatpackDesign.part(d, str(pl["id"]))
				if p.is_empty():
					continue
				var ring := FlatpackNesting.ring_on_sheet(p["ring"], p["bbox"], pl)
				if Geometry2D.is_point_in_polygon(q, FlatpackProfile.tessellate(ring, 1.0)):
					return str(p["id"])
		return ""

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseMotion:
			var id := _part_at((e as InputEventMouseMotion).position)
			if id != _hover:
				_hover = id
				queue_redraw()
				var p := FlatpackDesign.part(owner_modal.call("design"), id)
				tooltip_text = "" if p.is_empty() else "%s %s" % [str(p.get("label", "")), str(p["name"])]
		elif e is InputEventMouseButton:
			var mb := e as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				owner_modal.call("_select_part", _part_at(mb.position))


# ---------------------------------------------------------------------------
# The side-profile editor (chairs and loungers)
# ---------------------------------------------------------------------------

class ProfileCanvas extends Control:
	var owner_modal: Control = null
	var _drag := ""
	var _drag_start := Vector2.ZERO
	var _offset_start := Vector2.ZERO
	var _scale := 10.0
	var _origin := Vector2.ZERO

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		resized.connect(queue_redraw)

	func _geometry() -> Dictionary:
		var s: Dictionary = owner_modal.call("spec")
		if not str(s.get("type", "")) in ["chair", "lounger"]:
			return {}
		var g := FlatpackTemplates.chair_geometry(s)
		var base := s.duplicate(true)
		base["profile_offsets"] = {}
		var g0 := FlatpackTemplates.chair_geometry(base)
		var shift := -float((g["pts"]["rear_foot"] as Vector2).x)
		return {"g": g, "g0": g0, "shift": shift}

	func _fit(pts: Array) -> void:
		var bb := Rect2(pts[0], Vector2.ZERO)
		for p in pts:
			bb = bb.expand(p)
		bb = bb.grow(6.0)
		_scale = minf(size.x / maxf(bb.size.x, 1.0), (size.y - 30.0) / maxf(bb.size.y, 1.0))
		_origin = Vector2((size.x - bb.size.x * _scale) * 0.5 - bb.position.x * _scale,
			size.y - 10.0 + bb.position.y * _scale)

	func _to_c(p: Vector2) -> Vector2:
		return Vector2(_origin.x + p.x * _scale, _origin.y - p.y * _scale)

	func _from_c(c: Vector2) -> Vector2:
		return Vector2((c.x - _origin.x) / _scale, (_origin.y - c.y) / _scale)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.09))
		if owner_modal == null:
			return
		var geo := _geometry()
		if geo.is_empty():
			return
		var g: Dictionary = geo["g"]
		var shift := float(geo["shift"])
		var d: Dictionary = owner_modal.call("design")
		var side := FlatpackDesign.part(d, "side_0")
		var pts: Array = []
		for k in FlatpackTemplates.PROFILE_KEYS:
			pts.append((g["pts"][k] as Vector2) + Vector2(shift, 0))
		_fit(pts)
		draw_line(_to_c(Vector2(-200, 0)), _to_c(Vector2(400, 0)), Color(0.4, 0.42, 0.48), 1.0)
		if not side.is_empty():
			var poly := PackedVector2Array()
			for q in FlatpackProfile.tessellate(side["ring"], 0.3):
				poly.append(_to_c(q))
			if not Geometry2D.triangulate_polygon(poly).is_empty():
				var cols := PackedColorArray()
				cols.resize(poly.size())
				cols.fill(Color(0.93, 0.84, 0.62))
				draw_polygon(poly, cols, PackedVector2Array(), null)
			poly.append(poly[0])
			draw_polyline(poly, Color(0.80, 0.10, 0.12), 1.5, true)
			for h in side.get("hole_rings", []):
				var hp := PackedVector2Array()
				for q in FlatpackProfile.tessellate(h, 0.3):
					hp.append(_to_c(q))
				hp.append(hp[0])
				draw_polyline(hp, Color(0.10, 0.37, 0.82), 1.2, true)
		# Seat and back lines.
		var s0: Vector2 = g["s0"]
		var s1: Vector2 = g["s1"]
		var b0: Vector2 = g["b0"]
		var b1: Vector2 = g["b1"]
		draw_line(_to_c(s0 + Vector2(shift, 0)), _to_c(s1 + Vector2(shift, 0)), Color(0.13, 0.83, 0.93, 0.9), 3.0)
		draw_line(_to_c(b0 + Vector2(shift, 0)), _to_c(b1 + Vector2(shift, 0)), Color(0.13, 0.83, 0.93, 0.9), 3.0)
		var font := get_theme_default_font()
		for i in pts.size():
			var c := _to_c(pts[i])
			var key: String = FlatpackTemplates.PROFILE_KEYS[i]
			draw_circle(c, 7.0, Color(1.0, 0.72, 0.25) if key == _drag else Color(0.96, 0.62, 0.04))
			draw_circle(c, 7.0, Color(0.1, 0.1, 0.1), false, 1.5)
			# Labels sit outside the outline: left of the points on the left half.
			var text := str(FlatpackTemplates.PROFILE_LABELS[key])
			var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			var mid_x := (_to_c(pts[0]).x + _to_c(pts[1]).x) * 0.5
			var at := c + (Vector2(-tw - 12.0, -8.0) if c.x < mid_x else Vector2(12.0, -8.0))
			draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.82, 0.86, 0.92))
		draw_string(font, Vector2(12, 20), "Drag the orange points to reshape the sides. The seat and back (cyan) follow the Size settings.",
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 24.0, 12, Color(0.58, 0.64, 0.72))

	func _handle_at(pos: Vector2) -> String:
		var geo := _geometry()
		if geo.is_empty():
			return ""
		var g: Dictionary = geo["g"]
		var shift := float(geo["shift"])
		for k in FlatpackTemplates.PROFILE_KEYS:
			if _to_c((g["pts"][k] as Vector2) + Vector2(shift, 0)).distance_to(pos) < 11.0:
				return k
		return ""

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton:
			var mb := e as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_drag = _handle_at(mb.position)
					if not _drag.is_empty():
						_drag_start = mb.position
						var po: Dictionary = (owner_modal.call("spec") as Dictionary).get("profile_offsets", {})
						_offset_start = po.get(_drag, Vector2.ZERO)
				elif not _drag.is_empty():
					var delta := (mb.position - _drag_start) / _scale
					owner_modal.call("set_profile_offset", _drag,
						_offset_start + Vector2(delta.x, -delta.y), true)
					_drag = ""
					queue_redraw()
			elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
				owner_modal.call("reset_profile")
		elif e is InputEventMouseMotion and not _drag.is_empty():
			var mm := e as InputEventMouseMotion
			var delta := (mm.position - _drag_start) / _scale
			owner_modal.call("set_profile_offset", _drag, _offset_start + Vector2(delta.x, -delta.y), false)
