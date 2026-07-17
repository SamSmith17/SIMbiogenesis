extends Control

## Parametric pallet-rack builder with SubViewport studio preview.
## Place via PlacedPropService as model_id "pallet_rack" + rack_spec extras.

const MODAL_NAME := "pallet_rack_builder"
const REBUILD_DEBOUNCE_S := 0.10

const C_BG := Color(0.039, 0.055, 0.098, 0.85)
const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_PRIMARY := Color(0.133, 0.827, 0.933, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_TEXT_S := Color(0.580, 0.639, 0.722, 1.0)

var _loader: Node = null
var _active := false
var _spec: Dictionary = {}
var _dim: ColorRect = null
var _panel: PanelContainer = null
var _vp_container: SubViewportContainer = null
var _viewport: SubViewport = null
var _studio: Node3D = null
var _holder: Node3D = null
var _camera: Camera3D = null
var _width_spin: SpinBox = null
var _bay_spin: SpinBox = null
var _level_spin: SpinBox = null
var _depth_spin: SpinBox = null
var _rebuild_pending := false
var _rebuild_timer := 0.0


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_spec = PalletRackBuilder.default_spec()
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open() -> void:
	if _active:
		return
	_spec = PalletRackBuilder.default_spec()
	_sync_controls()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	_queue_rebuild(true)


func close() -> void:
	if not _active:
		return
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


func _process(delta: float) -> void:
	if not _rebuild_pending:
		return
	_rebuild_timer -= delta
	if _rebuild_timer <= 0.0:
		_rebuild_pending = false
		_rebuild_preview()


func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.color = C_BG
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			close())
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(860, 520)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	_panel.add_child(root)

	_vp_container = SubViewportContainer.new()
	_vp_container.custom_minimum_size = Vector2(520, 480)
	_vp_container.stretch = true
	root.add_child(_vp_container)
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(520, 480)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.own_world_3d = true
	_vp_container.add_child(_viewport)
	_build_studio_world()

	var side := VBoxContainer.new()
	side.custom_minimum_size.x = 280
	side.add_theme_constant_override("separation", 8)
	root.add_child(side)

	var title := Label.new()
	title.text = "Pallet Rack Builder"
	title.add_theme_color_override("font_color", C_TEXT)
	title.add_theme_font_size_override("font_size", 16)
	side.add_child(title)

	_width_spin = _add_spin(side, "Bay width (m)", 0.8, 6.0, 0.1, float(_spec["width_m"]))
	_bay_spin = _add_spin(side, "Bay count", 1, 12, 1, float(_spec["bay_count"]))
	_level_spin = _add_spin(side, "Levels", 1, 8, 1, float(_spec["levels"]))
	_depth_spin = _add_spin(side, "Depth (m)", 0.6, 3.0, 0.05, float(_spec["depth_m"]))

	var place_btn := Button.new()
	place_btn.text = "Place in world"
	place_btn.focus_mode = Control.FOCUS_NONE
	place_btn.add_theme_color_override("font_color", C_PRIMARY)
	place_btn.pressed.connect(_on_place)
	side.add_child(place_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	side.add_child(close_btn)


func _add_spin(parent: Control, label: String, mn: float, mx: float,
		step: float, val: float) -> SpinBox:
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = mn
	spin.max_value = mx
	spin.step = step
	spin.value = val
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(func(_v: float) -> void: _queue_rebuild(false))
	parent.add_child(spin)
	return spin


func _build_studio_world() -> void:
	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.12, 0.14, 0.18)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.62)
	e.ambient_light_energy = 0.7
	env.environment = e
	_studio.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 35, 0)
	key.light_energy = 1.1
	_studio.add_child(key)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.22, 0.24, 0.28)
	ground.material_override = gmat
	_studio.add_child(ground)
	_holder = Node3D.new()
	_holder.name = "Holder"
	_studio.add_child(_holder)
	_camera = Camera3D.new()
	_camera.position = Vector3(6, 4, 8)
	_camera.look_at(Vector3(0, 1.2, 0))
	_studio.add_child(_camera)


func _sync_controls() -> void:
	if _width_spin:
		_width_spin.value = float(_spec["width_m"])
	if _bay_spin:
		_bay_spin.value = float(_spec["bay_count"])
	if _level_spin:
		_level_spin.value = float(_spec["levels"])
	if _depth_spin:
		_depth_spin.value = float(_spec["depth_m"])


func _read_spec() -> Dictionary:
	return PalletRackBuilder.resolve_spec({
		"width_m": _width_spin.value if _width_spin else 2.4,
		"bay_count": int(_bay_spin.value) if _bay_spin else 3,
		"levels": int(_level_spin.value) if _level_spin else 3,
		"depth_m": _depth_spin.value if _depth_spin else 1.1,
	})


func _queue_rebuild(immediate: bool) -> void:
	_rebuild_pending = true
	_rebuild_timer = 0.0 if immediate else REBUILD_DEBOUNCE_S


func _rebuild_preview() -> void:
	if _holder == null:
		return
	for c in _holder.get_children():
		c.queue_free()
	_spec = _read_spec()
	var node := PalletRackBuilder.build_node(_spec)
	_holder.add_child(node)
	var fp := PalletRackBuilder.footprint_xz(_spec)
	var h := float(_spec["upright_h_m"])
	var dist := maxf(fp.x, fp.y) * 1.4 + h * 0.8
	_camera.position = Vector3(dist * 0.7, h * 0.85 + 1.0, dist)
	_camera.look_at(Vector3(0, h * 0.45, 0))


func _on_place() -> void:
	_spec = _read_spec()
	if _loader == null:
		return
	if _loader.has_method("begin_pallet_rack_placement"):
		_loader.call("begin_pallet_rack_placement", _spec)
	close()
