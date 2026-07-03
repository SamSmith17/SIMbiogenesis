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

var _loader: Node = null
var _active := false
var _building_idx := -1
var _record: Dictionary = {}          # centered copy of the building record
var _working_style: Dictionary = {}
var _syncing := false

var _dim: ColorRect = null
var _panel: PanelContainer = null
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
var _prov_label: Label = null
var _title_label: Label = null
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
	_sync_controls_from_style()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_fit_camera()
	_queue_rebuild(true)
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


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
	if idx < 0:
		return
	open(idx)
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
	var vp_container := SubViewportContainer.new()
	vp_container.stretch = true
	vp_container.custom_minimum_size = Vector2(590, 550)
	vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_container.mouse_filter = Control.MOUSE_FILTER_STOP
	hbox.add_child(vp_container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_2X
	vp_container.add_child(_viewport)
	_build_studio_world()

	# Right: parameter sidebar.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 550)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(scroll)
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(320, 0)
	side.add_theme_constant_override("separation", 6)
	scroll.add_child(side)

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
	var size := maxf(half * 2.0, height)
	var dist := clampf(size * 1.8, 8.0, 400.0)
	var az := deg_to_rad(35.0)
	var el := deg_to_rad(28.0)
	var target := Vector3(0, height * 0.45, 0)
	_camera.position = target + Vector3(
		sin(az) * cos(el), sin(el), cos(az) * cos(el)) * dist
	_camera.look_at(target)


func _rebuild_preview() -> void:
	if _holder == null or _record.is_empty():
		return
	for child in _holder.get_children():
		child.free()
	# Flat 2×2 zero DEM: the studio building seats at y = 0 through the same
	# geometry path the world uses.
	var flat := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var mi := BuildingBuilder.build_single_building(
		_record, _working_style, flat, 2, STUDIO_EXTENT_M, 0.0)
	if mi != null:
		_holder.add_child(mi)
	_fit_camera()


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

	var src := str(roof.get("source", "default"))
	var src_txt := "OSM tag" if src == "osm" else ("your override" if src == "user" else "default")
	_prov_label.text = "Roof: %s (%s)" % [str(roof.get("shape", "flat")), src_txt]
	var tags: Dictionary = _record.get("tags", {})
	_title_label.text = "Building Builder — %s" % str(tags.get("building", "building"))
	_syncing = false


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
	if _loader.has_method("apply_building_style"):
		_loader.call("apply_building_style", _building_idx, _working_style)
	applied.emit()
	close()


func _reset_to_osm() -> void:
	if _loader != null and _building_idx >= 0 \
			and _loader.has_method("clear_building_style"):
		_loader.call("clear_building_style", _building_idx)
	_working_style = {}
	_sync_controls_from_style()
	_queue_rebuild()
