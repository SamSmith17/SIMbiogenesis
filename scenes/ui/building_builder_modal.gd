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
var _kind_opt: OptionButton = null
var _elem_list: ItemList = null
var _elem_spins: Dictionary = {}   # "u_m"/"v_m"/"w_m"/"h_m" -> SpinBox
var _elem_delete: Button = null
var _selected_elem := -1
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
	_activate()
	_tabs.current_tab = 0
	_fit_camera()
	_queue_rebuild(true)


## Open straight to the structure library (B with no building focused).
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
		open_library()
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
	_panel.custom_minimum_size = Vector2(980, 620)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -490
	_panel.offset_right = 490
	_panel.offset_top = -310
	_panel.offset_bottom = 310
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

	# Left: studio viewport.
	_vp_container = SubViewportContainer.new()
	_vp_container.stretch = true
	_vp_container.custom_minimum_size = Vector2(590, 550)
	_vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp_container.add_child(_viewport)
	_build_studio_world()

	# Right: tabs — parametric customization + the structure library.
	_tabs = TabContainer.new()
	_tabs.custom_minimum_size = Vector2(340, 550)
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

	# Details: click a wall in the preview to add a door/window. Elements on a
	# wall auto-arrange — the door centers, windows flank it symmetrically.
	var det_lbl := Label.new()
	det_lbl.text = "Details — click a wall to add (auto-centered)"
	det_lbl.add_theme_font_size_override("font_size", 12)
	det_lbl.modulate = Color(0.7, 0.8, 0.9)
	side.add_child(det_lbl)

	var kind_row := HBoxContainer.new()
	side.add_child(kind_row)
	var kind_lbl := Label.new()
	kind_lbl.text = "Place"
	kind_lbl.custom_minimum_size = Vector2(90, 0)
	kind_row.add_child(kind_lbl)
	_kind_opt = OptionButton.new()
	_kind_opt.add_item("Door", 0)
	_kind_opt.add_item("Window", 1)
	_kind_opt.select(1)
	_kind_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind_row.add_child(_kind_opt)

	_elem_list = ItemList.new()
	_elem_list.custom_minimum_size = Vector2(0, 92)
	_elem_list.item_selected.connect(_on_element_selected)
	side.add_child(_elem_list)

	# Only size controls remain — horizontal placement is auto-centered, so the
	# old "Along m" / "Up m" nudges are gone.
	var grid := GridContainer.new()
	grid.columns = 2
	side.add_child(grid)
	_elem_spins["w_m"] = _nudge_spin(grid, "Width m", 0.2, 10.0)
	_elem_spins["h_m"] = _nudge_spin(grid, "Height m", 0.2, 10.0)

	_elem_delete = Button.new()
	_elem_delete.text = "Delete element"
	_elem_delete.add_theme_stylebox_override("normal", _secondary_btn_style())
	_elem_delete.pressed.connect(_delete_selected_element)
	side.add_child(_elem_delete)

	side.add_child(HSeparator.new())

	var btn_row := VBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	side.add_child(btn_row)
	var apply_btn := Button.new()
	apply_btn.text = "Apply to map"
	apply_btn.pressed.connect(_apply_to_map)
	btn_row.add_child(apply_btn)
	var reset_btn := Button.new()
	reset_btn.text = "Reset to OSM"
	reset_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	reset_btn.pressed.connect(_reset_to_osm)
	btn_row.add_child(reset_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	close_btn.pressed.connect(close)
	btn_row.add_child(close_btn)


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


func _nudge_spin(grid: GridContainer, label: String, minv: float, maxv: float) -> SpinBox:
	var lbl := Label.new()
	lbl.text = label
	grid.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = minv
	spin.max_value = maxv
	spin.step = 0.05
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(spin)
	spin.value_changed.connect(func(_v: float) -> void:
		if not _syncing:
			_on_nudge_changed())
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
	var dist := clampf(size * 1.8, 8.0, 400.0)
	var az := deg_to_rad(35.0)
	var el := deg_to_rad(28.0)
	var target := Vector3(0, target_y, 0)
	_camera.position = target + Vector3(
		sin(az) * cos(el), sin(el), cos(az) * cos(el)) * dist
	_camera.look_at(target)


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
	_fit_camera()


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

	var src := str(roof.get("source", "default"))
	var src_txt := "OSM tag" if src == "osm" else ("your override" if src == "user" else "default")
	_prov_label.text = "Roof: %s (%s)" % [str(roof.get("shape", "flat")), src_txt]
	var tags: Dictionary = _record.get("tags", {})
	_title_label.text = "Building Builder — %s" % str(tags.get("building", "building"))
	_syncing = false


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
	if _loader == null or _building_idx < 0:
		return
	_working_style.erase("selected_element")
	if _loader.has_method("apply_building_style"):
		_loader.call("apply_building_style", _building_idx, _working_style)
	applied.emit()
	close()


func _reset_to_osm() -> void:
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
	_ref_status.text = "%d street photo(s) nearby — click: wall color, right-click: roof color" % mini(near.size(), 6)
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


## Click on the preview → ray-pick which wall face was hit (pure math, no studio
## physics) → add the selected element kind to that wall. Horizontal position is
## then auto-arranged (door centered, windows flanking) by layout_elements_on_edge.
func _on_preview_input(event: InputEvent) -> void:
	if not _active or _camera == null or _record.is_empty():
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var params := BuildingBuilder.resolve_building_params(_record, _working_style)
	var poly: PackedVector2Array = params["poly"]
	# Studio DEM is flat zero, so the building base sits at the Raise offset.
	var base_y := float(params["base_offset_m"])
	var vp_pos := _to_viewport_pos(mb.position)
	var origin := _camera.project_ray_origin(vp_pos)
	var dir := _camera.project_ray_normal(vp_pos)
	var pick := BuildingBuilder.pick_wall_point(
		poly, base_y, float(params["height_m"]), origin, dir)
	if not bool(pick.get("valid", false)):
		return
	var edge := int(pick["edge"])
	var is_door := _kind_opt != null and _kind_opt.selected == 0
	var height_m := float(params["height_m"])
	var elem: Dictionary
	if is_door:
		elem = {"kind": "door", "edge": edge,
			"u_m": 0.0, "v_m": 0.0, "w_m": 1.0, "h_m": 2.05}
	else:
		var h := 1.4
		# Windows sit at a standard sill height, clamped inside the wall.
		var v := clampf(0.9, 0.0, maxf(height_m - h, 0.0))
		elem = {"kind": "window", "edge": edge,
			"u_m": 0.0, "v_m": v, "w_m": 1.2, "h_m": h}
	var elems := _elements()
	elems.append(elem)
	BuildingBuilder.layout_elements_on_edge(poly, edge, elems)
	_working_style["elements"] = elems
	_select_element(elems.size() - 1)
	_sync_element_list()
	_queue_rebuild()
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
	_sync_nudge_spins()


func _on_element_selected(idx: int) -> void:
	_select_element(idx)
	_queue_rebuild()


func _sync_element_list() -> void:
	if _elem_list == null:
		return
	_elem_list.clear()
	for e in _elements():
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		_elem_list.add_item("%s — wall %d, %.2f m along, %.2f m up" % [
			str(d.get("kind", "?")).capitalize(), int(d.get("edge", 0)),
			float(d.get("u_m", 0.0)), float(d.get("v_m", 0.0))])
	if _selected_elem >= 0 and _selected_elem < _elem_list.item_count:
		_elem_list.select(_selected_elem)
	_sync_nudge_spins()


func _sync_nudge_spins() -> void:
	_syncing = true
	var elems := _elements()
	var have := _selected_elem >= 0 and _selected_elem < elems.size()
	for key in _elem_spins:
		var spin: SpinBox = _elem_spins[key]
		spin.editable = have
		if have:
			spin.value = float((elems[_selected_elem] as Dictionary).get(key, 0.0))
	if _elem_delete != null:
		_elem_delete.disabled = not have
	_syncing = false


func _on_nudge_changed() -> void:
	var elems := _elements()
	if _selected_elem < 0 or _selected_elem >= elems.size():
		return
	var d: Dictionary = elems[_selected_elem]
	for key in _elem_spins:
		d[key] = (_elem_spins[key] as SpinBox).value
	elems[_selected_elem] = d
	# A wider door/window changes the spacing, so re-run the auto-layout.
	var params := BuildingBuilder.resolve_building_params(_record, _working_style)
	BuildingBuilder.layout_elements_on_edge(
		params["poly"], int(d.get("edge", 0)), elems)
	_working_style["elements"] = elems
	_sync_element_list()
	_queue_rebuild()


func _delete_selected_element() -> void:
	var elems := _elements()
	if _selected_elem < 0 or _selected_elem >= elems.size():
		return
	var edge := int((elems[_selected_elem] as Dictionary).get("edge", -1))
	elems.remove_at(_selected_elem)
	# Re-center whatever remains on that wall.
	if edge >= 0:
		var params := BuildingBuilder.resolve_building_params(_record, _working_style)
		BuildingBuilder.layout_elements_on_edge(params["poly"], edge, elems)
	_working_style["elements"] = elems
	_select_element(-1)
	_sync_element_list()
	_queue_rebuild()
