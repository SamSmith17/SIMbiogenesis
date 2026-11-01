extends Control

## Building Builder modal — customize one OSM building parametrically with a
## live studio preview (SubViewport + right sidebar), the building-flavored
## sibling of vegetation_preview_editor.gd. Opens via Interact on a
## crosshair-focused building or the B key. The preview rebuilds through
## BuildingBuilder.build_single_building on a flat DEM, the exact code path
## the world uses, so what you see is what gets built.

signal applied

const MODAL_NAME := "building_builder"
const REBUILD_DEBOUNCE_S := 0.10
const STUDIO_EXTENT_M := 400.0

const ROOF_SHAPE_IDS: Array[String] = [
	"", "flat", "gabled", "hipped", "pyramidal", "skillion"]
const ROOF_SHAPE_LABELS: Array[String] = [
	"Auto (OSM/default)", "Flat", "Gabled", "Hipped", "Pyramidal", "Skillion"]

## Wall material dropdown: index 0 = auto (tags/size heuristic), index i>0 =
## BuildingBuilder.WallMode i−1. Order must match the WallMode enum.
const WALL_MODE_LABELS: Array[String] = [
	"Auto (tags/size)", "Lap siding", "Trailer (ribbed metal)",
	"Corrugated steel", "Plywood / T1-11", "Stucco / block"]

var _loader: Node = null
var _active := false
var _building_idx := -1
var _record: Dictionary = {}          # centered copy of the building record
var _working_style: Dictionary = {}
var _syncing := false

var _dim: ColorRect = null
var _panel: PanelContainer = null
var _vp_container: SubViewportContainer = null
var _viewport: SubViewport = null
var _studio: Node3D = null
var _holder: Node3D = null
var _camera: Camera3D = null
var _shape_opt: OptionButton = null
var _pitch_slider: HSlider = null
var _height_slider: HSlider = null
var _offset_slider: HSlider = null
var _wall_picker: ColorPickerButton = null
var _roof_picker: ColorPickerButton = null
var _wall_mode_opt: OptionButton = null
var _facade_tex_opt: OptionButton = null
var _facade_files: PackedStringArray = PackedStringArray()
var _tex_w_spin: SpinBox = null
var _tex_h_spin: SpinBox = null
var _prov_label: Label = null
var _title_label: Label = null
var _space_opt: OptionButton = null
var _space_cap_spin: SpinBox = null
var _elem_list: ItemList = null
var _elem_delete: Button = null
var _inspector: VBoxContainer = null
var _apply_btn: Button = null
var _reset_btn: Button = null
var _foundation_opt: OptionButton = null
var _wing_opt: OptionButton = null
var _light_windows: CheckButton = null
var _corner_trim: CheckButton = null
var _overhang_slider: HSlider = null
var _stories_slider: HSlider = null
var _width_slider: HSlider = null
var _depth_slider: HSlider = null
var _selected_elem := -1
var _designer := false
var _prop_id := ""
var _armed_tool := ""
var _tool_buttons: Dictionary = {}
var _ghost: MeshInstance3D = null
var _dragging := false
var _undo: Array = []
var _redo: Array = []
var _orbit_az := deg_to_rad(35.0)
var _orbit_el := deg_to_rad(28.0)
var _cam_dist := 16.0
var _cam_target_y := 2.0
var _rmb := false
var _tabs: TabContainer = null
var _ref_list: VBoxContainer = null
var _ref_status: Label = null
var _ref_thumbs: Dictionary = {}   # photo id -> TextureRect awaiting thumb_ready
var _lib_list: ItemList = null
var _lib_models: Array = []
var _lib_replace_btn: Button = null
var _file_dialog: FileDialog = null
var _rebuild_pending := false
var _rebuild_timer := 0.0


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	set_process_input(true)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open(building_idx: int) -> void:
	if _active or _loader == null:
		return
	var rec: Dictionary = {}
	if _loader.has_method("get_building_record"):
		rec = _loader.call("get_building_record", building_idx)
	if rec.is_empty():
		return
	_building_idx = building_idx
	_designer = false
	_prop_id = ""
	_armed_tool = ""
	_undo.clear()
	_redo.clear()
	_record = _centered_record(rec)
	if _record.is_empty():
		return
	_working_style = {}
	if _loader.has_method("get_building_style"):
		_working_style = _loader.call("get_building_style", building_idx)
	_working_style.erase("selected_element")
	_selected_elem = -1
	_sync_controls_from_style()
	_sync_element_list()
	_sync_space_controls()
	_activate()
	_tabs.current_tab = 0
	_fit_camera()
	_queue_rebuild(true)


func _space_registry() -> SpaceRegistry:
	if _loader == null:
		return null
	var reg: Variant = _loader.get("npc_spaces")
	return reg as SpaceRegistry if reg is SpaceRegistry else null


func _space_target() -> Dictionary:
	var tag := ""
	if _loader != null and _building_idx >= 0 and _loader.has_method("get_building_tag"):
		tag = str(_loader.call("get_building_tag", _building_idx))
	return {"kind": "building", "building_tag": tag}


func _sync_space_controls() -> void:
	if _space_opt == null:
		return
	var reg := _space_registry()
	var target := _space_target()
	var usable := reg != null and not str(target.get("building_tag", "")).is_empty()
	_space_opt.get_parent().visible = usable
	_space_cap_spin.visible = false
	if not usable:
		return
	var rec := reg.space_for_target(target)
	var idx := SpaceTypes.TYPES.find(str(rec.get("space_type", ""))) if not rec.is_empty() else -1
	_space_opt.selected = idx + 1  # 0 = None
	if idx >= 0:
		_space_cap_spin.visible = true
		_space_cap_spin.set_value_no_signal(float(int(rec.get("capacity", SpaceRegistry.DEFAULT_CAPACITY))))


func _on_space_type_selected(idx: int) -> void:
	var reg := _space_registry()
	if reg == null:
		return
	var space_type: String = "" if idx <= 0 else str(SpaceTypes.TYPES[idx - 1])
	reg.set_space_type(_space_target(), space_type, int(_space_cap_spin.value))
	if _loader.has_method("save_npc_spaces"):
		_loader.call("save_npc_spaces")
	_sync_space_controls()


func _on_space_capacity_changed(v: float) -> void:
	var reg := _space_registry()
	if reg == null:
		return
	var target := _space_target()
	var rec := reg.space_for_target(target)
	if rec.is_empty():
		return
	reg.set_space_type(target, str(rec.get("space_type", "")), int(v))
	if _loader.has_method("save_npc_spaces"):
		_loader.call("save_npc_spaces")


## A new house, or a saved design, with no OSM footprint.
func open_designer(spec: Dictionary = {}) -> void:
	if _active or _loader == null:
		return
	_designer = true
	_prop_id = ""
	_building_idx = -1
	_armed_tool = ""
	_undo.clear()
	_redo.clear()
	_working_style = spec.duplicate(true) if not spec.is_empty() else BuildingPresets.cottage()
	_working_style.erase("selected_element")
	_record = _centered_record(BuildingFeatures.record_for(_working_style))
	_selected_elem = -1
	_sync_controls_from_style()
	_sync_element_list()
	_activate()
	_tabs.current_tab = 0
	_fit_camera()
	_queue_rebuild(true)


func open_for_prop(prop_id: String) -> void:
	if _active or _loader == null or prop_id.is_empty():
		return
	var rec := PlacedPropService.get_prop_record(_loader.get_parent(), prop_id)
	var spec: Dictionary = rec.get("building_spec", {}) if rec.get("building_spec") is Dictionary else {}
	if spec.is_empty():
		spec = BuildingPresets.cottage()
	_designer = false
	_prop_id = prop_id
	_building_idx = -1
	_armed_tool = ""
	_undo.clear()
	_redo.clear()
	_working_style = spec.duplicate(true)
	_working_style.erase("selected_element")
	_record = _centered_record(BuildingFeatures.record_for(_working_style))
	_selected_elem = -1
	_sync_controls_from_style()
	_sync_element_list()
	_activate()
	_tabs.current_tab = 0
	_fit_camera()
	_queue_rebuild(true)


## Open straight to the structure library.
func open_library() -> void:
	if _active or _loader == null:
		return
	_building_idx = -1
	_record = {}
	_working_style = {}
	_selected_elem = -1
	_activate()
	_tabs.current_tab = 1


func _activate() -> void:
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	if _lib_replace_btn != null:
		_lib_replace_btn.disabled = _building_idx < 0
	_refresh_action_labels()


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rebuild_pending = false
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


func _unhandled_input(event: InputEvent) -> void:
	if _active or _loader == null:
		return
	if not event.is_action_pressed("building_builder"):
		return
	if not CursorController.should_capture_look():
		return
	var idx := -1
	if _loader.has_method("get_building_focus_idx"):
		idx = int(_loader.call("get_building_focus_idx"))
	if idx >= 0:
		open(idx)
	else:
		open_designer()
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _active:
		return
	if _rebuild_pending:
		_rebuild_timer += delta
		if _rebuild_timer >= REBUILD_DEBOUNCE_S:
			_rebuild_pending = false
			_rebuild_preview()


func _queue_rebuild(immediate: bool = false) -> void:
	if immediate:
		_rebuild_pending = false
		_rebuild_preview()
	else:
		_rebuild_pending = true
		_rebuild_timer = 0.0


## Copy of the building record with the footprint centered on the origin so
## the studio camera can orbit it (world position is irrelevant in preview).
func _centered_record(rec: Dictionary) -> Dictionary:
	var pts: Variant = rec.get("points", PackedVector2Array())
	if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
		return {}
	var poly: PackedVector2Array = pts
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= float(poly.size())
	var centered := PackedVector2Array()
	for p in poly:
		centered.append(p - c)
	var out := rec.duplicate(true)
	out["points"] = centered
	return out


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.14, 0.98)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.2, 0.4, 0.6, 0.9)
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 8
	return sb


func _secondary_btn_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.16, 0.22, 1.0)
	sb.border_color = Color(0.25, 0.4, 0.55, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	return sb


func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.55)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(1120, 680)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -560
	_panel.offset_right = 560
	_panel.offset_top = -340
	_panel.offset_bottom = 340
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var root_v := VBoxContainer.new()
	root_v.add_theme_constant_override("separation", 6)
	margin.add_child(root_v)

	_title_label = Label.new()
	_title_label.text = "Building Builder"
	_title_label.add_theme_font_size_override("font_size", 17)
	root_v.add_child(_title_label)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_v.add_child(hbox)

	_build_palette(hbox)

	# Centre: studio viewport.
	_vp_container = SubViewportContainer.new()
	_vp_container.stretch = true
	_vp_container.custom_minimum_size = Vector2(420, 360)
	_vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_vp_container.gui_input.connect(_on_preview_input)
	hbox.add_child(_vp_container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_2X
	# Match the veg-editor pattern: a real size + always-update so the preview
	# renders and the click coordinates map cleanly into camera ray space.
	_viewport.size = Vector2i(590, 550)
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE  # idle while the modal is hidden
	_vp_container.add_child(_viewport)
	_build_studio_world()

	# Right: tabs — parametric customization + the structure library.
	_tabs = TabContainer.new()
	_tabs.custom_minimum_size = Vector2(340, 360)
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(_on_tab_changed)
	hbox.add_child(_tabs)

	var scroll := ScrollContainer.new()
	scroll.name = "Customize"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(scroll)
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(300, 0)
	side.add_theme_constant_override("separation", 6)
	scroll.add_child(side)

	_build_library_tab()

	_prov_label = Label.new()
	_prov_label.add_theme_font_size_override("font_size", 12)
	_prov_label.modulate = Color(0.7, 0.8, 0.9)
	side.add_child(_prov_label)

	# NPC space tag: writes SpaceRegistry (NOT the style layer — tagging must
	# not de-merge the building from the merged OSM mesh).
	var space_row := HBoxContainer.new()
	side.add_child(space_row)
	var space_lbl := Label.new()
	space_lbl.text = "NPC space"
	space_lbl.custom_minimum_size = Vector2(90, 0)
	space_row.add_child(space_lbl)
	_space_opt = OptionButton.new()
	_space_opt.tooltip_text = "Tag this building as a space people wayfind to (restroom, kitchen, …)"
	_space_opt.add_item("None", 0)
	for i in SpaceTypes.TYPES.size():
		_space_opt.add_item(SpaceTypes.label(SpaceTypes.TYPES[i]), i + 1)
	_space_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_space_opt.item_selected.connect(_on_space_type_selected)
	space_row.add_child(_space_opt)
	_space_cap_spin = SpinBox.new()
	_space_cap_spin.min_value = 1
	_space_cap_spin.max_value = 5000
	_space_cap_spin.step = 1
	_space_cap_spin.custom_minimum_size = Vector2(64, 0)
	_space_cap_spin.tooltip_text = "How many people can use this space at once"
	_space_cap_spin.value_changed.connect(_on_space_capacity_changed)
	_space_cap_spin.visible = false
	space_row.add_child(_space_cap_spin)

	var shape_row := HBoxContainer.new()
	side.add_child(shape_row)
	var shape_lbl := Label.new()
	shape_lbl.text = "Roof"
	shape_lbl.custom_minimum_size = Vector2(90, 0)
	shape_row.add_child(shape_lbl)
	_shape_opt = OptionButton.new()
	_shape_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in ROOF_SHAPE_LABELS.size():
		_shape_opt.add_item(ROOF_SHAPE_LABELS[i], i)
	_shape_opt.item_selected.connect(_on_shape_selected)
	shape_row.add_child(_shape_opt)

	_pitch_slider = _labeled_slider(side, "Pitch °", 10.0, 55.0, 28.0, 1.0,
		func(v: float) -> void:
			_working_style["roof_pitch_deg"] = v
			_queue_rebuild())
	_height_slider = _labeled_slider(side, "Height m", 2.0, 30.0, 8.0, 0.1,
		func(v: float) -> void:
			_working_style["height_m"] = v
			_queue_rebuild())
	_offset_slider = _labeled_slider(side, "Raise m", -3.0, 3.0, 0.0, 0.05,
		func(v: float) -> void:
			_working_style["base_y_offset_m"] = v
			_queue_rebuild())
	_width_slider = _labeled_slider(side, "Width m", 3.0, 24.0, 8.0, 0.1,
		func(v: float) -> void:
			_working_style["width_m"] = v
			_refresh_designed_footprint())
	_depth_slider = _labeled_slider(side, "Depth m", 2.4, 16.0, 6.0, 0.1,
		func(v: float) -> void:
			_working_style["depth_m"] = v
			_refresh_designed_footprint())
	_overhang_slider = _labeled_slider(side, "Eave m", 0.0, 1.2, 0.0, 0.05,
		func(v: float) -> void:
			_working_style["overhang_m"] = v
			_queue_rebuild())
	_add_massing_options(side)

	_wall_picker = _color_row(side, "Walls", func(c: Color) -> void:
		_working_style["wall_color"] = c
		_queue_rebuild())
	_roof_picker = _color_row(side, "Roof", func(c: Color) -> void:
		_working_style["roof_color"] = c
		_queue_rebuild())

	var mat_row := HBoxContainer.new()
	side.add_child(mat_row)
	var mat_lbl := Label.new()
	mat_lbl.text = "Material"
	mat_lbl.custom_minimum_size = Vector2(90, 0)
	mat_row.add_child(mat_lbl)
	_wall_mode_opt = OptionButton.new()
	_wall_mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in WALL_MODE_LABELS.size():
		_wall_mode_opt.add_item(WALL_MODE_LABELS[i], i)
	_wall_mode_opt.item_selected.connect(_on_wall_mode_selected)
	mat_row.add_child(_wall_mode_opt)

	# Facade texture (hero buildings): PNG/JPG strips from
	# user://maps/facade_textures/ tiled at real-world size on the walls.
	var ftex_row := HBoxContainer.new()
	side.add_child(ftex_row)
	var ftex_lbl := Label.new()
	ftex_lbl.text = "Facade tex"
	ftex_lbl.custom_minimum_size = Vector2(90, 0)
	ftex_row.add_child(ftex_lbl)
	_facade_tex_opt = OptionButton.new()
	_facade_tex_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_facade_tex_opt.item_selected.connect(_on_facade_tex_selected)
	ftex_row.add_child(_facade_tex_opt)

	var tsize := GridContainer.new()
	tsize.columns = 2
	side.add_child(tsize)
	_tex_w_spin = _plain_spin(tsize, "Tile W m", 0.5, 50.0, 4.0,
		func(v: float) -> void:
			_working_style["wall_tex_w_m"] = v
			_queue_rebuild())
	_tex_h_spin = _plain_spin(tsize, "Tile H m", 0.5, 50.0, 3.0,
		func(v: float) -> void:
			_working_style["wall_tex_h_m"] = v
			_queue_rebuild())

	side.add_child(HSeparator.new())

	var det_lbl := Label.new()
	det_lbl.text = "Features"
	det_lbl.add_theme_font_size_override("font_size", 12)
	side.add_child(det_lbl)

	_elem_list = ItemList.new()
	_elem_list.custom_minimum_size = Vector2(0, 72)
	_elem_list.item_selected.connect(_on_element_selected)
	side.add_child(_elem_list)

	_inspector = VBoxContainer.new()
	_inspector.add_theme_constant_override("separation", 4)
	side.add_child(_inspector)

	_elem_delete = Button.new()
	_elem_delete.text = "Delete"
	_elem_delete.add_theme_stylebox_override("normal", _secondary_btn_style())
	_elem_delete.pressed.connect(_delete_selected_element)
	side.add_child(_elem_delete)

	var line_btn := Button.new()
	line_btn.text = "Line up this wall"
	line_btn.tooltip_text = "Centre the doors and windows already on the selected wall"
	line_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	line_btn.pressed.connect(_line_up_wall)
	side.add_child(line_btn)

	side.add_child(HSeparator.new())

	var btn_row := VBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	side.add_child(btn_row)
	_apply_btn = Button.new()
	_apply_btn.text = "Apply to map"
	_apply_btn.pressed.connect(_apply_to_map)
	btn_row.add_child(_apply_btn)
	_reset_btn = Button.new()
	_reset_btn.text = "Reset to OSM"
	_reset_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	_reset_btn.pressed.connect(_reset_to_osm)
	btn_row.add_child(_reset_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	close_btn.pressed.connect(close)
	btn_row.add_child(close_btn)
	# Above the timeline and inside the screen at any size (a fixed 980 x 620
	# centred on the window sat on the timeline at 720p).
	UiFit.keep_fitted(_panel, Vector2(1120, 680))


func _labeled_slider(parent: Control, label: String, minv: float, maxv: float,
		value: float, step: float, on_change: Callable) -> HSlider:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(90, 0)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = minv
	slider.max_value = maxv
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(150, 0)
	row.add_child(slider)
	var val_lbl := Label.new()
	val_lbl.text = "%.2f" % value
	val_lbl.custom_minimum_size = Vector2(48, 0)
	row.add_child(val_lbl)
	slider.focus_entered.connect(_snapshot_style)
	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = "%.2f" % v
		if not _syncing:
			on_change.call(v))
	return slider


## Labeled SpinBox with its own change callback (no element-nudge coupling).
func _plain_spin(grid: GridContainer, label: String, minv: float, maxv: float,
		value: float, on_change: Callable) -> SpinBox:
	var lbl := Label.new()
	lbl.text = label
	grid.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = minv
	spin.max_value = maxv
	spin.step = 0.05
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(spin)
	spin.value_changed.connect(func(v: float) -> void:
		if not _syncing:
			on_change.call(v))
	return spin


func _color_row(parent: Control, label: String, on_change: Callable) -> ColorPickerButton:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(90, 0)
	row.add_child(lbl)
	var picker := ColorPickerButton.new()
	picker.custom_minimum_size = Vector2(64, 24)
	picker.edit_alpha = false
	row.add_child(picker)
	picker.color_changed.connect(func(c: Color) -> void:
		if not _syncing:
			on_change.call(c))
	return picker


# ---------------------------------------------------------------------------
# Studio world
# ---------------------------------------------------------------------------

func _build_studio_world() -> void:
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.42, 0.46, 0.50)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.62)
	env.ambient_light_energy = 0.35
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_studio.add_child(world_env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, 38, 0)
	key.light_energy = 1.15
	key.shadow_enabled = true
	_studio.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, -135, 0)
	fill.light_energy = 0.28
	_studio.add_child(fill)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.30, 0.32, 0.28)
	gmat.roughness = 0.95
	ground.material_override = gmat
	ground.position.y = 0.0
	_studio.add_child(ground)

	_holder = Node3D.new()
	_holder.name = "Building"
	_studio.add_child(_holder)

	_camera = Camera3D.new()
	_camera.fov = 48.0
	_camera.current = true
	_studio.add_child(_camera)


func _fit_camera() -> void:
	if _camera == null or _record.is_empty():
		return
	var poly: PackedVector2Array = _record.get("points", PackedVector2Array())
	var half := 1.0
	for p in poly:
		half = maxf(half, maxf(absf(p.x), absf(p.y)))
	var params := BuildingBuilder.resolve_building_params(_record, _working_style)
	var height: float = params["height_m"]
	_fit_camera_size(maxf(half * 2.0, height), height * 0.45)


func _fit_camera_size(size: float, target_y: float) -> void:
	if _camera == null:
		return
	_cam_dist = clampf(size * 1.8, 8.0, 400.0)
	_cam_target_y = target_y
	_orbit_az = deg_to_rad(35.0)
	_orbit_el = deg_to_rad(28.0)
	_apply_orbit()


func _rebuild_preview() -> void:
	if _holder == null or _record.is_empty():
		return
	if _tabs != null and _tabs.current_tab != 0:
		return  # library tab owns the preview right now
	for child in _holder.get_children():
		child.free()
	# Flat 2×2 zero DEM: the studio building seats at y = 0 through the same
	# geometry path the world uses.
	var flat := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var mi := BuildingBuilder.build_single_building(
		_record, _working_style, flat, 2, STUDIO_EXTENT_M, 0.0)
	if mi != null:
		_apply_facade_texture_preview(mi)
		_holder.add_child(mi)
	_ensure_ghost()


## Mirror the loader's styled-wall texture application in the studio so the
## Facade texture dropdown previews live (world path: terrain_loader
## _apply_styled_wall_material — same style keys).
func _apply_facade_texture_preview(mi: MeshInstance3D) -> void:
	var file := str(_working_style.get("wall_texture", ""))
	if file.is_empty() or _loader == null:
		return
	if not _loader.has_method("_facade_texture"):
		return
	var tex: Texture2D = _loader.call("_facade_texture", file)
	if tex == null:
		return
	var size := Vector2(
		clampf(float(_working_style.get("wall_tex_w_m", 4.0)), 0.5, 50.0),
		clampf(float(_working_style.get("wall_tex_h_m", 3.0)), 0.5, 50.0))
	mi.set_surface_override_material(0, BuildingBuilder.make_wall_material(tex, size))


# ---------------------------------------------------------------------------
# Style sync + actions
# ---------------------------------------------------------------------------

func _sync_controls_from_style() -> void:
	_syncing = true
	var params := BuildingBuilder.resolve_building_params(_record, _working_style)
	var roof: Dictionary = params["roof"]
	var colors: Dictionary = params["colors"]

	var override_shape := str(_working_style.get("roof_shape", ""))
	var sel := ROOF_SHAPE_IDS.find(override_shape)
	_shape_opt.select(maxi(sel, 0))
	_pitch_slider.value = float(roof.get("angle_deg", 28.0))
	_height_slider.value = float(params["height_m"])
	_offset_slider.value = float(params["base_offset_m"])
	_wall_picker.color = colors["wall"]
	_roof_picker.color = colors["roof"]
	var wm := int(_working_style.get("wall_mode", BuildingBuilder.WALL_MODE_AUTO))
	_wall_mode_opt.select(clampi(wm + 1, 0, WALL_MODE_LABELS.size() - 1))
	_refresh_facade_tex_options()
	var cur_tex := str(_working_style.get("wall_texture", ""))
	var tex_idx := _facade_files.find(cur_tex)
	_facade_tex_opt.select(tex_idx + 1 if tex_idx >= 0 else 0)
	_tex_w_spin.value = float(_working_style.get("wall_tex_w_m", 4.0))
	_tex_h_spin.value = float(_working_style.get("wall_tex_h_m", 3.0))
	if _width_slider != null:
		_width_slider.value = float(_working_style.get("width_m", 8.0))
	if _depth_slider != null:
		_depth_slider.value = float(_working_style.get("depth_m", 6.0))
	if _overhang_slider != null:
		_overhang_slider.value = float(_working_style.get("overhang_m", 0.0))
	if _stories_slider != null:
		_stories_slider.value = clampf(round(float(_working_style.get("height_m", 2.8)) / BuildingBuilder.LEVELS_TO_METRES), 1.0, 3.0)
	if _foundation_opt != null:
		_foundation_opt.select(maxi(BuildingFeatures.FOUNDATIONS.find(
			str(_working_style.get("foundation", "slab"))), 0))
	if _wing_opt != null:
		_wing_opt.select(maxi(BuildingFeatures.WINGS.find(
			str(_working_style.get("wing", "none"))), 0))
	if _light_windows != null:
		_light_windows.button_pressed = bool(_working_style.get("light_windows", false))
	if _corner_trim != null:
		_corner_trim.button_pressed = bool(_working_style.get("corner_trim", false))

	var src := str(roof.get("source", "default"))
	var src_txt := "OSM tag" if src == "osm" else ("your override" if src == "user" else "default")
	_prov_label.text = "Roof: %s (%s)" % [str(roof.get("shape", "flat")), src_txt]
	var tags: Dictionary = _record.get("tags", {})
	if _prop_id != "":
		_title_label.text = "Edit building"
	elif _designer:
		_title_label.text = "Building designer"
	else:
		_title_label.text = "Building Builder — %s" % str(tags.get("building", "building"))
	_syncing = false
	_refresh_action_labels()
	_rebuild_inspector()


func _refresh_facade_tex_options() -> void:
	if _facade_tex_opt == null:
		return
	_facade_files = PackedStringArray()
	if _loader != null and _loader.has_method("list_facade_textures"):
		_facade_files = _loader.call("list_facade_textures")
	_facade_tex_opt.clear()
	_facade_tex_opt.add_item("None (procedural)", 0)
	for i in _facade_files.size():
		_facade_tex_opt.add_item(_facade_files[i], i + 1)


func _on_facade_tex_selected(index: int) -> void:
	if _syncing:
		return
	if index <= 0 or index > _facade_files.size():
		_working_style.erase("wall_texture")
	else:
		_working_style["wall_texture"] = _facade_files[index - 1]
	_queue_rebuild()


func _on_wall_mode_selected(index: int) -> void:
	if _syncing:
		return
	if index <= 0:
		_working_style.erase("wall_mode")
	else:
		_working_style["wall_mode"] = index - 1
	_queue_rebuild()


func _on_shape_selected(index: int) -> void:
	if _syncing:
		return
	var shape := ROOF_SHAPE_IDS[clampi(index, 0, ROOF_SHAPE_IDS.size() - 1)]
	if shape.is_empty():
		_working_style.erase("roof_shape")
	else:
		_working_style["roof_shape"] = shape
	_sync_controls_from_style()
	_queue_rebuild()


func _apply_to_map() -> void:
	if _loader == null:
		return
	var style := BuildingFeatures.public_style(_working_style)
	if _prop_id != "":
		PlacedPropService.update_prop_record(_loader.get_parent(), _prop_id,
			{"building_spec": style}, true)
	elif _building_idx >= 0:
		if _loader.has_method("apply_building_style"):
			_loader.call("apply_building_style", _building_idx, style)
	elif _loader.has_method("begin_building_placement"):
		_loader.call("begin_building_placement", style)
	applied.emit()
	close()


func _reset_to_osm() -> void:
	if _designer or _prop_id != "":
		_snapshot_style()
		_working_style = BuildingPresets.cottage()
		_selected_elem = -1
		_refresh_designed_footprint()
		_sync_controls_from_style()
		_sync_element_list()
		_fit_camera()
		return
	if _loader != null and _building_idx >= 0 \
			and _loader.has_method("clear_building_style"):
		_loader.call("clear_building_style", _building_idx)
	_working_style = {}
	_selected_elem = -1
	_sync_controls_from_style()
	_sync_element_list()
	_queue_rebuild()


# ---------------------------------------------------------------------------
# Structure library
# ---------------------------------------------------------------------------

func _build_library_tab() -> void:
	var lib := VBoxContainer.new()
	lib.name = "Library"
	lib.add_theme_constant_override("separation", 6)
	_tabs.add_child(lib)

	var hint := Label.new()
	hint.text = "Preset structures + your imported models"
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(0.7, 0.8, 0.9)
	lib.add_child(hint)

	var upload_btn := Button.new()
	upload_btn.text = "Upload GLB/GLTF…"
	upload_btn.pressed.connect(_on_library_upload)
	lib.add_child(upload_btn)

	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = PackedStringArray(["*.glb ; GLB", "*.gltf ; GLTF"])
	_file_dialog.file_selected.connect(_on_library_file_selected)
	add_child(_file_dialog)

	_lib_list = ItemList.new()
	_lib_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lib_list.item_selected.connect(func(_i: int) -> void: _preview_library_model())
	lib.add_child(_lib_list)

	var place_btn := Button.new()
	place_btn.text = "Place in world"
	place_btn.pressed.connect(_on_library_place)
	lib.add_child(place_btn)

	var starshade_btn := Button.new()
	starshade_btn.text = "Add StarShade"
	starshade_btn.tooltip_text = "Place the V1 StarShade model in the world"
	starshade_btn.pressed.connect(_on_add_starshade)
	lib.add_child(starshade_btn)

	_lib_replace_btn = Button.new()
	_lib_replace_btn.text = "Replace this building"
	_lib_replace_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	_lib_replace_btn.pressed.connect(_on_library_replace)
	lib.add_child(_lib_replace_btn)

	_build_reference_tab()


## Reference tab: nearby real Mapillary street photos of the focused building
## (CC BY-SA, attributed) so styles can be matched to reality. Left-click a
## photo = eyedrop wall color, right-click = roof color.
func _build_reference_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "Reference"
	tab.add_theme_constant_override("separation", 6)
	_tabs.add_child(tab)

	_ref_status = Label.new()
	_ref_status.add_theme_font_size_override("font_size", 12)
	_ref_status.modulate = Color(0.7, 0.8, 0.9)
	_ref_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tab.add_child(_ref_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)
	_ref_list = VBoxContainer.new()
	_ref_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ref_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_ref_list)

	var attr := Label.new()
	var svc := get_node_or_null("/root/MapillaryService")
	attr.text = svc.attribution() if svc != null else "Photos © Mapillary contributors, CC BY-SA 4.0"
	attr.add_theme_font_size_override("font_size", 10)
	attr.modulate = Color(0.6, 0.65, 0.7)
	tab.add_child(attr)

	if svc != null:
		svc.thumb_ready.connect(_on_ref_thumb_ready)
		svc.photo_index_ready.connect(func(_tag: String, _photos: Array) -> void:
			if _active and _tabs.current_tab == 2:
				_refresh_reference())


func _refresh_reference() -> void:
	if _ref_list == null:
		return
	for child in _ref_list.get_children():
		child.queue_free()
	_ref_thumbs.clear()
	var svc := get_node_or_null("/root/MapillaryService")
	if svc == null:
		_ref_status.text = "MapillaryService unavailable."
		return
	if not svc.is_configured():
		_ref_status.text = "No Mapillary token. Add to user://terrain_config.cfg:\n[mapillary]\naccess_token=MLY|…\n(free token: mapillary.com/developer)"
		return
	# Centroid of the ORIGINAL (world-local) footprint — _record is re-centered
	# for the studio, so pull the raw record for position.
	var rec: Dictionary = {}
	if _loader != null and _loader.has_method("get_building_record") and _building_idx >= 0:
		rec = _loader.call("get_building_record", _building_idx)
	var pts: Variant = rec.get("points", PackedVector2Array())
	if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
		_ref_status.text = "Open a building to see nearby street photos."
		return
	var centroid := Vector2.ZERO
	for p in (pts as PackedVector2Array):
		centroid += p
	centroid /= float((pts as PackedVector2Array).size())
	if svc.photo_count() == 0:
		_ref_status.text = "Loading photo index …"
		var lat := float(_loader.get("_lat")) if _loader != null else 0.0
		var lon := float(_loader.get("_lon")) if _loader != null else 0.0
		if lat != 0.0 or lon != 0.0:
			svc.request_photo_index(lat, lon, 1500.0, "site")
		return
	var near: Array = svc.photos_near(centroid.x, centroid.y, 150.0)
	if near.is_empty():
		_ref_status.text = "No street photos within 150 m of this building."
		return
	_ref_status.text = "%s nearby — click: wall color, right-click: roof color" % UiText.count(mini(near.size(), 6), "street photo")
	for i in mini(near.size(), 6):
		var photo: Dictionary = near[i]
		var id := str(photo.get("id", ""))
		var card := VBoxContainer.new()
		_ref_list.add_child(card)
		var tex_rect := TextureRect.new()
		tex_rect.custom_minimum_size = Vector2(300, 170)
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.gui_input.connect(_on_ref_thumb_input.bind(tex_rect))
		card.add_child(tex_rect)
		_ref_thumbs[id] = tex_rect
		var cap := HBoxContainer.new()
		card.add_child(cap)
		var lbl := Label.new()
		lbl.text = "%.0f m %s" % [float(photo.get("dist_m", 0.0)),
			_bearing_label(centroid, Vector2(float(photo.get("x_m", 0.0)),
				float(photo.get("z_m", 0.0))))]
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cap.add_child(lbl)
		var open_btn := Button.new()
		open_btn.text = "Open"
		open_btn.add_theme_font_size_override("font_size", 11)
		open_btn.pressed.connect(func() -> void:
			OS.shell_open("https://www.mapillary.com/app/?pKey=%s&focus=photo" % id))
		cap.add_child(open_btn)
		svc.request_thumb(id, str(photo.get("thumb_url", "")))


func _on_ref_thumb_ready(id: String, tex: ImageTexture) -> void:
	var tr: TextureRect = _ref_thumbs.get(id)
	if tr != null and is_instance_valid(tr):
		tr.texture = tex


## Eyedropper: sample the clicked pixel of a reference photo into the wall
## (left) or roof (right) color style.
func _on_ref_thumb_input(event: InputEvent, tex_rect: TextureRect) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT and mb.button_index != MOUSE_BUTTON_RIGHT:
		return
	if tex_rect.texture == null:
		return
	var img := tex_rect.texture.get_image()
	if img == null:
		return
	var size := tex_rect.size
	var px := Vector2i(clampi(int(mb.position.x / maxf(size.x, 1.0) * img.get_width()),
		0, img.get_width() - 1),
		clampi(int(mb.position.y / maxf(size.y, 1.0) * img.get_height()),
		0, img.get_height() - 1))
	var c := img.get_pixelv(px)
	c.a = 1.0
	if mb.button_index == MOUSE_BUTTON_LEFT:
		_working_style["wall_color"] = c
		_wall_picker.color = c
	else:
		_working_style["roof_color"] = c
		_roof_picker.color = c
	_queue_rebuild()


static func _bearing_label(from: Vector2, to: Vector2) -> String:
	# +X east, −Z north (see GeoMath.lonlat_to_local_m).
	var ang := rad_to_deg(atan2(to.x - from.x, -(to.y - from.y)))
	ang = fmod(ang + 360.0, 360.0)
	var dirs := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	return dirs[int(round(ang / 45.0)) % 8]


func _on_tab_changed(tab: int) -> void:
	if not _active:
		return
	if tab == 1:
		_refresh_library()
		_preview_library_model()
	elif tab == 2:
		_refresh_reference()
	else:
		_fit_camera()
		_queue_rebuild(true)


func _refresh_library() -> void:
	if _lib_list == null:
		return
	var prev := _selected_library_id()
	_lib_models = []
	for m in ModelCatalog.models_in_category("structures"):
		_lib_models.append(m)
	# User-imported GLBs (uploaded via the P panel / LinkageLab bundles).
	for m in ModelCatalog.all_models():
		if str(m.get("path", "")).begins_with("user://"):
			_lib_models.append(m)
	_lib_list.clear()
	var reselect := 0
	for i in _lib_models.size():
		var m: Dictionary = _lib_models[i]
		_lib_list.add_item(str(m.get("label", m.get("id", "?"))))
		if str(m.get("id", "")) == prev:
			reselect = i
	if _lib_list.item_count > 0:
		_lib_list.select(reselect)


func _selected_library_id() -> String:
	if _lib_list == null or _lib_list.get_selected_items().is_empty():
		return ""
	var i: int = _lib_list.get_selected_items()[0]
	if i < 0 or i >= _lib_models.size():
		return ""
	return str((_lib_models[i] as Dictionary).get("id", ""))


func _preview_library_model() -> void:
	if _holder == null:
		return
	for child in _holder.get_children():
		child.free()
	var id := _selected_library_id()
	if id.is_empty():
		return
	var inst := ModelCatalog.instantiate(id)
	if inst == null:
		return
	var s := ModelCatalog.resolved_scale(id, 1.0)
	inst.scale = Vector3.ONE * s
	inst.position.y = -ModelCatalog.foot_local_y(id) * s
	_holder.add_child(inst)
	var m := ModelCatalog.mesh_metrics(id)
	var size: float = maxf(maxf(float(m.width), float(m.depth)), float(m.unit_height)) * s
	_fit_camera_size(maxf(size, 2.0), float(m.unit_height) * s * 0.45)


func _on_library_place() -> void:
	var id := _selected_library_id()
	if id.is_empty() or _loader == null:
		return
	if _loader.has_method("begin_structure_placement") \
			and bool(_loader.call("begin_structure_placement", id)):
		close()


func _on_add_starshade() -> void:
	if _loader == null:
		return
	if _loader.has_method("begin_structure_placement") \
			and bool(_loader.call("begin_structure_placement", "starshade")):
		close()


func _on_library_replace() -> void:
	var id := _selected_library_id()
	if id.is_empty() or _loader == null or _building_idx < 0:
		return
	if _loader.has_method("replace_osm_building") \
			and bool(_loader.call("replace_osm_building", _building_idx, id)):
		close()


func _on_library_upload() -> void:
	if _file_dialog != null:
		_file_dialog.popup_centered(Vector2i(700, 450))


func _on_library_file_selected(path: String) -> void:
	var entry := ModelImporter.import_from_path(path)
	if entry.is_empty():
		return
	_refresh_library()
	var model_id := str(entry.get("id", ""))
	for i in _lib_models.size():
		if str(_lib_models[i].get("id", "")) == model_id:
			_lib_list.select(i)
			_preview_library_model()
			break


# ---------------------------------------------------------------------------
# Facade elements (doors/windows)
# ---------------------------------------------------------------------------

func _elements() -> Array:
	var v: Variant = _working_style.get("elements", [])
	if not (v is Array):
		v = []
		_working_style["elements"] = v
	return v


func _on_preview_input(event: InputEvent) -> void:
	if not _active or _camera == null or _record.is_empty():
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _rmb:
			_orbit_az -= mm.relative.x * 0.008
			_orbit_el = clampf(_orbit_el + mm.relative.y * 0.006, -0.2, 1.2)
			_apply_orbit()
		elif _dragging:
			_drag_to(mm.position)
		else:
			_update_ghost(mm.position)
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		_rmb = mb.pressed
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
		_cam_dist = clampf(_cam_dist * 0.9, 4.0, 400.0)
		_apply_orbit()
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
		_cam_dist = clampf(_cam_dist * 1.1, 4.0, 400.0)
		_apply_orbit()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if not mb.pressed:
		_dragging = false
		_ghost_visible(false)
		return
	var pick := _pick_at(mb.position)
	if not bool(pick.get("valid", false)):
		return
	var edge := int(pick["edge"])
	var u := float(pick["u_m"])
	var hit := _opening_at(edge, u)
	if hit >= 0:
		_select_element(hit)
		_snapshot_style()
		_dragging = true
		_sync_element_list()
		_queue_rebuild()
	elif _armed_tool != "":
		place_feature(_armed_tool, edge, u)
	accept_event()


## Map a click in the SubViewportContainer's local space into the SubViewport's
## pixel space so Camera3D.project_ray_* aims where the user actually clicked.
## With stretch=true and shrink=1 this ratio is ~1, but staying explicit keeps
## picking correct if the container and viewport sizes ever diverge.
func _to_viewport_pos(local_pos: Vector2) -> Vector2:
	if _vp_container == null or _viewport == null:
		return local_pos
	var cont := _vp_container.size
	if cont.x <= 0.0 or cont.y <= 0.0:
		return local_pos
	return local_pos * (Vector2(_viewport.size) / cont)


func _select_element(idx: int) -> void:
	_selected_elem = idx
	if idx >= 0:
		_working_style["selected_element"] = idx
	else:
		_working_style.erase("selected_element")
	_rebuild_inspector()


func _on_element_selected(idx: int) -> void:
	if _syncing:
		return
	_select_element(idx)
	_queue_rebuild()


func _sync_element_list() -> void:
	if _elem_list == null:
		return
	_syncing = true
	_elem_list.clear()
	for e in _elements():
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		var typ := BuildingFeatures.element_type(d)
		_elem_list.add_item("%s — wall %d, %.2f m along" % [
			typ.capitalize(), int(d.get("edge", 0)), float(d.get("u_m", 0.0))])
	if _selected_elem >= 0 and _selected_elem < _elem_list.item_count:
		_elem_list.select(_selected_elem)
	if _elem_delete != null:
		_elem_delete.disabled = _selected_elem < 0
	_syncing = false


func _delete_selected_element() -> void:
	var elems := _elements()
	if _selected_elem < 0 or _selected_elem >= elems.size():
		return
	_snapshot_style()
	elems.remove_at(_selected_elem)
	_working_style["elements"] = elems
	_select_element(-1)
	_sync_element_list()
	_queue_rebuild()


func _input(event: InputEvent) -> void:
	if not _active or not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == KEY_ESCAPE:
		if _dragging:
			_dragging = false
			_pop_undo()
			get_viewport().set_input_as_handled()
		elif _armed_tool != "":
			_arm_tool("")
			get_viewport().set_input_as_handled()
		return
	if key.keycode == KEY_Z and key.ctrl_pressed:
		undo_style()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_Y and key.ctrl_pressed:
		_redo_style()
		get_viewport().set_input_as_handled()


func _build_palette(hbox: HBoxContainer) -> void:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(168, 0)
	col.add_theme_constant_override("separation", 4)
	hbox.add_child(col)
	var title := Label.new()
	title.text = "Add"
	title.add_theme_font_size_override("font_size", 12)
	col.add_child(title)
	for tool in BuildingFeatures.TOOL_PRESETS:
		var id := str(tool.get("id", ""))
		var btn := Button.new()
		btn.text = str(tool.get("label", id))
		btn.tooltip_text = str(tool.get("tip", ""))
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.toggle_mode = true
		btn.pressed.connect(_arm_tool.bind(id))
		col.add_child(btn)
		_tool_buttons[id] = btn
	var night := Button.new()
	night.text = "Day / Night"
	night.tooltip_text = "Preview the windows and porch lights after dusk"
	night.pressed.connect(_toggle_night_preview)
	col.add_child(night)
	col.add_child(HSeparator.new())
	var presets := Label.new()
	presets.text = "Presets"
	presets.add_theme_font_size_override("font_size", 12)
	col.add_child(presets)
	for entry in BuildingPresets.builtins():
		var pb := Button.new()
		pb.text = str(entry.get("name", ""))
		pb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		pb.pressed.connect(_apply_named_preset.bind(str(entry.get("id", ""))))
		col.add_child(pb)


func _add_massing_options(side: VBoxContainer) -> void:
	_stories_slider = _labeled_slider(side, "Stories", 1.0, 3.0, 1.0, 1.0,
		func(v: float) -> void:
			_working_style["height_m"] = v * BuildingBuilder.LEVELS_TO_METRES
			if _height_slider != null:
				_syncing = true
				_height_slider.value = float(_working_style["height_m"])
				_syncing = false
			_queue_rebuild())
	var found := HBoxContainer.new()
	side.add_child(found)
	var fl := Label.new()
	fl.text = "Foundation"
	fl.custom_minimum_size = Vector2(90, 0)
	found.add_child(fl)
	_foundation_opt = OptionButton.new()
	for f in BuildingFeatures.FOUNDATIONS:
		_foundation_opt.add_item(str(f).capitalize())
	_foundation_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_foundation_opt.item_selected.connect(func(i: int) -> void:
		if _syncing:
			return
		_snapshot_style()
		_working_style["foundation"] = BuildingFeatures.FOUNDATIONS[i]
		_queue_rebuild())
	found.add_child(_foundation_opt)
	var wing := HBoxContainer.new()
	side.add_child(wing)
	var wl := Label.new()
	wl.text = "Wing"
	wl.custom_minimum_size = Vector2(90, 0)
	wing.add_child(wl)
	_wing_opt = OptionButton.new()
	for w in BuildingFeatures.WINGS:
		_wing_opt.add_item(str(w).capitalize())
	_wing_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wing_opt.item_selected.connect(func(i: int) -> void:
		if _syncing:
			return
		_snapshot_style()
		_working_style["wing"] = BuildingFeatures.WINGS[i]
		_refresh_designed_footprint())
	wing.add_child(_wing_opt)
	_light_windows = CheckButton.new()
	_light_windows.text = "Light the windows"
	_light_windows.toggled.connect(func(on: bool) -> void:
		if _syncing:
			return
		_snapshot_style()
		_working_style["light_windows"] = on
		_queue_rebuild())
	side.add_child(_light_windows)
	_corner_trim = CheckButton.new()
	_corner_trim.text = "Corner boards"
	_corner_trim.toggled.connect(func(on: bool) -> void:
		if _syncing:
			return
		_snapshot_style()
		_working_style["corner_trim"] = on
		_queue_rebuild())
	side.add_child(_corner_trim)


func _refresh_action_labels() -> void:
	if _apply_btn != null:
		if _prop_id != "":
			_apply_btn.text = "Apply to building"
		elif _designer:
			_apply_btn.text = "Place in world"
		else:
			_apply_btn.text = "Apply to map"
	if _reset_btn != null:
		if _prop_id != "":
			_reset_btn.visible = false
		elif _designer:
			_reset_btn.visible = true
			_reset_btn.text = "New cottage"
		else:
			_reset_btn.visible = true
			_reset_btn.text = "Reset to OSM"
	var designed := _designer or _prop_id != ""
	if _width_slider != null:
		_width_slider.get_parent().visible = designed
	if _depth_slider != null:
		_depth_slider.get_parent().visible = designed
	if _wing_opt != null:
		_wing_opt.get_parent().visible = designed


func _refresh_designed_footprint() -> void:
	if _building_idx >= 0:
		_queue_rebuild()
		return
	_record = _centered_record(BuildingFeatures.record_for(_working_style))
	_queue_rebuild()


func _arm_tool(tool_id: String) -> void:
	if _armed_tool == tool_id:
		tool_id = ""
	_armed_tool = tool_id
	for id in _tool_buttons:
		var btn: Button = _tool_buttons[id]
		btn.set_pressed_no_signal(id == _armed_tool)
	if _armed_tool == "":
		_ghost_visible(false)


func _toggle_night_preview() -> void:
	_working_style["_preview_night"] = not bool(_working_style.get("_preview_night", false))
	_queue_rebuild()


func _apply_named_preset(preset_id: String) -> void:
	var spec := BuildingPresets.by_id(preset_id)
	if spec.is_empty():
		return
	_snapshot_style()
	if _building_idx >= 0:
		_working_style["roof"] = spec.get("roof", {})
		_working_style["pitch_deg"] = spec.get("pitch_deg", 30.0)
		_working_style["height_m"] = spec.get("height_m", 4.0)
		_working_style["foundation"] = spec.get("foundation", "slab")
		_working_style["overhang_m"] = spec.get("overhang_m", 0.0)
		_working_style["corner_trim"] = spec.get("corner_trim", false)
		_working_style["light_windows"] = spec.get("light_windows", false)
		if spec.has("wall_mode"):
			_working_style["wall_mode"] = spec["wall_mode"]
		for key in ["wall_color", "roof_color", "foundation_color"]:
			if spec.has(key):
				_working_style[key] = spec[key]
		var dest: PackedVector2Array = _record.get("points", PackedVector2Array())
		_working_style["elements"] = BuildingFeatures.fit_elements(spec, dest)
	else:
		_working_style = spec.duplicate(true)
		_refresh_designed_footprint()
	_selected_elem = -1
	_sync_controls_from_style()
	_sync_element_list()
	_fit_camera()


func _snapshot_style() -> void:
	if _syncing:
		return
	_undo.append(_working_style.duplicate(true))
	if _undo.size() > 40:
		_undo.pop_front()
	_redo.clear()


func undo_style() -> void:
	_pop_undo()


func _pop_undo() -> void:
	if _undo.is_empty():
		return
	_redo.append(_working_style.duplicate(true))
	_working_style = _undo.pop_back()
	_selected_elem = int(_working_style.get("selected_element", -1))
	if _building_idx < 0:
		_record = _centered_record(BuildingFeatures.record_for(_working_style))
	_sync_controls_from_style()
	_sync_element_list()
	_queue_rebuild()


func _redo_style() -> void:
	if _redo.is_empty():
		return
	_undo.append(_working_style.duplicate(true))
	_working_style = _redo.pop_back()
	_selected_elem = int(_working_style.get("selected_element", -1))
	if _building_idx < 0:
		_record = _centered_record(BuildingFeatures.record_for(_working_style))
	_sync_controls_from_style()
	_sync_element_list()
	_queue_rebuild()


func place_feature(tool_id: String, edge: int, u: float) -> void:
	var tmpl := BuildingFeatures.tool_template(tool_id)
	if tmpl.is_empty() or _record.is_empty():
		return
	var params := BuildingBuilder.resolve_building_params(_record, _working_style)
	var poly: PackedVector2Array = params["poly"]
	if edge < 0 or edge >= poly.size():
		return
	var edge_len := poly[edge].distance_to(poly[(edge + 1) % poly.size()])
	var w := float(tmpl.get("w_m", tmpl.get("width_m", 0.9)))
	var uu := BuildingFeatures.clamp_u(u, maxf(w, 0.2), edge_len)
	var elems := _elements()
	var typ := BuildingFeatures.element_type(tmpl)
	if (typ == "door" or typ == "window") and BuildingFeatures.overlaps(elems, edge, uu, w):
		return
	_snapshot_style()
	tmpl["id"] = BuildingFeatures.fresh_id(elems)
	tmpl["edge"] = edge
	tmpl["u_m"] = uu
	if typ == "door" or typ == "steps":
		tmpl["v_m"] = 0.0
	elems.append(tmpl)
	_working_style["elements"] = elems
	_select_element(elems.size() - 1)
	_sync_element_list()
	_queue_rebuild()


func set_selected_width(w: float) -> void:
	var elems := _elements()
	if _selected_elem < 0 or _selected_elem >= elems.size():
		return
	_snapshot_style()
	var d: Dictionary = elems[_selected_elem]
	if float(d.get("w_m", 0.0)) <= 0.0 and float(d.get("width_m", 0.0)) > 0.0:
		d["width_m"] = w
	else:
		d["w_m"] = w
	elems[_selected_elem] = d
	_working_style["elements"] = elems
	_rebuild_inspector()
	_queue_rebuild()


func _line_up_wall() -> void:
	var elems := _elements()
	if elems.is_empty() or _record.is_empty():
		return
	_snapshot_style()
	var params := BuildingBuilder.resolve_building_params(_record, _working_style)
	var poly: PackedVector2Array = params["poly"]
	var edge := 0
	if _selected_elem >= 0 and _selected_elem < elems.size():
		edge = int((elems[_selected_elem] as Dictionary).get("edge", 0))
		BuildingBuilder.layout_elements_on_edge(poly, edge, elems)
	else:
		for i in poly.size():
			BuildingBuilder.layout_elements_on_edge(poly, i, elems)
	_working_style["elements"] = elems
	_sync_element_list()
	_queue_rebuild()


func _rebuild_inspector() -> void:
	if _inspector == null:
		return
	_syncing = true
	var kids := _inspector.get_children()
	for c in kids:
		_inspector.remove_child(c)
		c.free()
	var elems := _elements()
	if _selected_elem < 0 or _selected_elem >= elems.size():
		return
	var el: Dictionary = elems[_selected_elem]
	var typ := BuildingFeatures.element_type(el)
	var fields: Array = BuildingFeatures.ELEMENT_FIELDS.get(typ, [])
	for field in fields:
		if not BuildingFeatures.field_visible(field, el):
			continue
		var key := str(field.get("key", ""))
		var kind := str(field.get("kind", "float"))
		var label := str(field.get("label", key))
		if kind == "float":
			var spin := SpinBox.new()
			spin.min_value = float(field.get("min", 0.0))
			spin.max_value = float(field.get("max", 10.0))
			spin.step = float(field.get("step", 0.05))
			spin.value = float(el.get(key, field.get("min", 0.0)))
			spin.prefix = label + " "
			spin.focus_entered.connect(_snapshot_style)
			spin.value_changed.connect(_on_field_float.bind(key))
			_inspector.add_child(spin)
		elif kind == "bool":
			var box := CheckButton.new()
			box.text = label
			box.button_pressed = bool(el.get(key, false))
			box.toggled.connect(_on_field_bool.bind(key))
			_inspector.add_child(box)
		elif kind == "option":
			var opt := OptionButton.new()
			var choices: Array = field.get("options", [])
			var cur := str(el.get(key, ""))
			var sel := 0
			for i in choices.size():
				opt.add_item(str(choices[i]).capitalize())
				if str(choices[i]) == cur:
					sel = i
			opt.select(sel)
			opt.item_selected.connect(_on_field_option.bind(key, choices))
			_inspector.add_child(opt)
		elif kind == "color":
			var picker := ColorPickerButton.new()
			var raw: Variant = el.get(key, Color.WHITE)
			picker.color = raw if raw is Color else Color.WHITE
			picker.color_changed.connect(_on_field_color.bind(key))
			_inspector.add_child(picker)
	_syncing = false


func _on_field_float(value: float, key: String) -> void:
	if _syncing:
		return
	_write_field(key, value)


func _on_field_bool(on: bool, key: String) -> void:
	if _syncing:
		return
	_snapshot_style()
	_write_field(key, on)


func _on_field_option(index: int, key: String, choices: Array) -> void:
	if _syncing or index < 0 or index >= choices.size():
		return
	_snapshot_style()
	_write_field(key, choices[index])
	_rebuild_inspector()


func _on_field_color(col: Color, key: String) -> void:
	if _syncing:
		return
	_write_field(key, col)


func _write_field(key: String, value: Variant) -> void:
	var elems := _elements()
	if _selected_elem < 0 or _selected_elem >= elems.size():
		return
	var d: Dictionary = elems[_selected_elem]
	d[key] = value
	elems[_selected_elem] = d
	_working_style["elements"] = elems
	_queue_rebuild()


func _apply_orbit() -> void:
	if _camera == null:
		return
	var target := Vector3(0.0, _cam_target_y, 0.0)
	_camera.position = target + Vector3(
		sin(_orbit_az) * cos(_orbit_el), sin(_orbit_el),
		cos(_orbit_az) * cos(_orbit_el)) * _cam_dist
	_camera.look_at(target)


func _pick_at(screen_pos: Vector2) -> Dictionary:
	if _camera == null or _record.is_empty():
		return {"valid": false}
	var params := BuildingBuilder.resolve_building_params(_record, _working_style)
	var origin := _camera.project_ray_origin(_to_viewport_pos(screen_pos))
	var dir := _camera.project_ray_normal(_to_viewport_pos(screen_pos))
	return BuildingBuilder.pick_wall_point(params["poly"], float(params["base_offset_m"]),
		float(params["height_m"]), origin, dir)


func _opening_at(edge: int, u: float) -> int:
	var elems := _elements()
	var best := -1
	var best_d := 0.35
	for i in elems.size():
		var d: Dictionary = elems[i]
		if BuildingFeatures.element_type(d) != "door" and BuildingFeatures.element_type(d) != "window":
			continue
		if int(d.get("edge", -1)) != edge:
			continue
		var dist := absf(float(d.get("u_m", 0.0)) - u)
		var reach := float(d.get("w_m", 0.9)) * 0.5 + 0.3
		if dist < reach and dist < best_d + reach:
			best = i
			best_d = dist
	return best


func _drag_to(screen_pos: Vector2) -> void:
	var pick := _pick_at(screen_pos)
	if not bool(pick.get("valid", false)):
		return
	var elems := _elements()
	if _selected_elem < 0 or _selected_elem >= elems.size():
		return
	var d: Dictionary = elems[_selected_elem]
	if int(pick["edge"]) != int(d.get("edge", -1)):
		return
	var params := BuildingBuilder.resolve_building_params(_record, _working_style)
	var poly: PackedVector2Array = params["poly"]
	var edge := int(d.get("edge", 0))
	var edge_len := poly[edge].distance_to(poly[(edge + 1) % poly.size()])
	var w := float(d.get("w_m", 0.9))
	d["u_m"] = BuildingFeatures.clamp_u(float(pick["u_m"]), maxf(w, 0.2), edge_len)
	elems[_selected_elem] = d
	_working_style["elements"] = elems
	_queue_rebuild()


func _ensure_ghost() -> void:
	if _studio == null:
		return
	if _ghost != null and is_instance_valid(_ghost):
		return
	_ghost = MeshInstance3D.new()
	_ghost.name = "FeatureGhost"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.9, 1.0, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost.material_override = mat
	_ghost.visible = false
	_studio.add_child(_ghost)


func _ghost_visible(on: bool) -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.visible = on


func _update_ghost(screen_pos: Vector2) -> void:
	if _armed_tool == "" or _ghost == null:
		return
	var pick := _pick_at(screen_pos)
	if not bool(pick.get("valid", false)):
		_ghost_visible(false)
		return
	var tmpl := BuildingFeatures.tool_template(_armed_tool)
	if tmpl.is_empty():
		return
	var params := BuildingBuilder.resolve_building_params(_record, _working_style)
	var poly: PackedVector2Array = params["poly"]
	var edge := int(pick["edge"])
	var p0: Vector2 = poly[edge]
	var p1: Vector2 = poly[(edge + 1) % poly.size()]
	var edge_len := p0.distance_to(p1)
	if edge_len < 0.05:
		return
	var dir2 := (p1 - p0) / edge_len
	var out := Vector2(dir2.y, -dir2.x)
	var w := float(tmpl.get("w_m", tmpl.get("width_m", 0.9)))
	var h := float(tmpl.get("h_m", 1.2))
	var depth := float(tmpl.get("depth_m", 0.08))
	var u := BuildingFeatures.clamp_u(float(pick["u_m"]), maxf(w, 0.2), edge_len)
	var v := float(tmpl.get("v_m", 0.0))
	if BuildingFeatures.element_type(tmpl) == "porch" or BuildingFeatures.element_type(tmpl) == "steps":
		h = 0.12
		depth = maxf(depth, 1.2)
		v = 0.2
	var centre := Vector3(p0.x, float(params["base_offset_m"]) + v + h * 0.5, p0.y)
	centre += Vector3(dir2.x, 0, dir2.y) * u + Vector3(out.x, 0, out.y) * (depth * 0.5)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(maxf(w, 0.3), maxf(h, 0.08), maxf(depth, 0.06))
	_ghost.mesh = mesh
	_ghost.position = centre
	_ghost.basis = Basis.looking_at(Vector3(out.x, 0, out.y), Vector3.UP)
	_ghost_visible(true)
