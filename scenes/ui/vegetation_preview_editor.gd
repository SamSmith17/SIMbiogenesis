extends Control

## Live-preview vegetation tuning modal — studio SubViewport + right sidebar.

signal applied

const MODAL_NAME := "vegetation_preview"
const REBUILD_DEBOUNCE_S := 0.10
const PREVIEW_SEED := 4242
const STUDIO_SUN := Vector3(0.35, 0.88, 0.32)

const SPECIES_IDS: Array[String] = [
	"pine", "deciduous", "shrub", "grass_lawn", "grass_field",
]
const SPECIES_LABELS: Array[String] = [
	"Pine", "Deciduous", "Shrub", "Lawn grass", "Field grass",
]

const SPECIES_SHAPE_SLIDERS := {
	"deciduous": [
		{"key": "deciduous_canopy_w", "label": "Can W", "min": 4.0, "max": 24.0},
		{"key": "deciduous_canopy_h", "label": "Can H", "min": 2.0, "max": 16.0},
		{"key": "deciduous_trunk_w", "label": "Tr W", "min": 0.2, "max": 2.0},
		{"key": "deciduous_trunk_h", "label": "Tr H", "min": 2.0, "max": 18.0},
		{"key": "deciduous_trunk_taper", "label": "Trunk taper", "min": 0.12, "max": 1.0},
		{"key": "deciduous_bulk_scale", "label": "Bulk×", "min": 0.5, "max": 6.0},
		{"key": "deciduous_growth_years", "label": "Growth yrs", "min": 0.0, "max": 80.0},
		{"key": "deciduous_cluster_count", "label": "Clusters", "min": 3.0, "max": 16.0},
		{"key": "deciduous_cluster_spread", "label": "Spread", "min": 0.3, "max": 1.5},
		{"key": "deciduous_cluster_size", "label": "Clump sz", "min": 0.5, "max": 1.5},
		{"key": "deciduous_cluster_tightness", "label": "Tightness", "min": 0.5, "max": 1.5},
		{"key": "deciduous_branch_count", "label": "Primaries", "min": 3.0, "max": 12.0},
		{"key": "deciduous_branch_levels", "label": "Fork levels", "min": 1.0, "max": 5.0},
		{"key": "deciduous_branch_split", "label": "Fork count", "min": 2.0, "max": 4.0},
		{"key": "deciduous_branch_angle", "label": "Fork angle", "min": 8.0, "max": 75.0},
		{"key": "deciduous_branch_length_ratio", "label": "Taper len", "min": 0.45, "max": 0.92},
		{"key": "deciduous_branch_droop", "label": "Droop/lift", "min": -0.6, "max": 0.6},
		{"key": "deciduous_branch_gnarl", "label": "Gnarl", "min": 0.0, "max": 1.0},
		{"key": "deciduous_branch_thickness", "label": "Br thick", "min": 0.3, "max": 2.0},
		{"key": "deciduous_branch_reach", "label": "Br reach", "min": 0.4, "max": 1.6},
		{"key": "deciduous_branch_base", "label": "Br base", "min": 0.5, "max": 0.95},
		{"key": "deciduous_vertical_offset_m", "label": "Raise", "min": -8.0, "max": 8.0},
		{"key": "deciduous_leaf_shell_count", "label": "Leaf shells", "min": 2.0, "max": 12.0},
		{"key": "deciduous_leaf_density", "label": "Leaf density", "min": 6.0, "max": 48.0},
		{"key": "deciduous_leaf_size", "label": "Leaf size", "min": 0.3, "max": 1.0},
		{"key": "deciduous_leaf_aspect", "label": "Leaf shape", "min": 1.0, "max": 3.5},
		{"key": "deciduous_leaf_gap", "label": "Leaf gaps", "min": 0.0, "max": 0.9},
		{"key": "deciduous_leaf_lump", "label": "Crown lump", "min": 0.0, "max": 0.6},
		{"key": "deciduous_shadow_proxy_visibility", "label": "Shadow proxy", "min": 0.0, "max": 0.25},
		{"key": "deciduous_lod_near_m", "label": "Leaf LOD m", "min": 80.0, "max": 400.0},
		{"key": "deciduous_lod_far_begin_m", "label": "Billboard m", "min": 70.0, "max": 390.0},
	],
	"pine": [
		{"key": "pine_bulk_scale", "label": "Bulk×", "min": 0.5, "max": 6.0},
		{"key": "pine_growth_years", "label": "Growth yrs", "min": 0.0, "max": 80.0},
		{"key": "pine_card_w", "label": "W", "min": 0.3, "max": 4.0},
		{"key": "pine_card_h", "label": "H", "min": 1.5, "max": 20.0},
		{"key": "pine_trunk_w", "label": "Trunk", "min": 0.08, "max": 1.5},
		{"key": "pine_whorl_count", "label": "Whorls", "min": 3.0, "max": 14.0},
		{"key": "pine_bough_scale", "label": "Bough sz", "min": 0.5, "max": 1.6},
		{"key": "pine_whorl_spacing", "label": "Whorl gap", "min": 0.5, "max": 1.5},
		{"key": "pine_whorl_jitter", "label": "Whorl jitter", "min": 0.0, "max": 0.35},
		{"key": "pine_whorl_variation", "label": "Whorl spin", "min": 0.0, "max": 1.0},
		{"key": "pine_trunk_taper", "label": "Trunk taper", "min": 0.12, "max": 1.0},
		{"key": "pine_fur_strength", "label": "Fur detail", "min": 0.0, "max": 1.0},
		{"key": "pine_fur_cells", "label": "Fur density", "min": 6.0, "max": 40.0},
		{"key": "pine_fur_tuft_size", "label": "Tuft size", "min": 0.2, "max": 1.0},
		{"key": "pine_fur_gap", "label": "Fur gaps", "min": 0.0, "max": 0.85},
		{"key": "pine_lod_near_m", "label": "Fur LOD m", "min": 80.0, "max": 400.0},
		{"key": "pine_lod_far_begin_m", "label": "Plain m", "min": 70.0, "max": 390.0},
		{"key": "pine_vertical_offset_m", "label": "Raise", "min": -8.0, "max": 8.0},
	],
	"shrub": [
		{"key": "shrub_bulk_scale", "label": "Bulk×", "min": 0.5, "max": 6.0},
		{"key": "shrub_growth_years", "label": "Growth yrs", "min": 0.0, "max": 40.0},
		{"key": "shrub_card_w", "label": "W", "min": 0.4, "max": 5.0},
		{"key": "shrub_card_h", "label": "H", "min": 0.4, "max": 5.0},
		{"key": "shrub_cluster_count", "label": "Clumps", "min": 3.0, "max": 10.0},
		{"key": "shrub_cluster_spread", "label": "Spread", "min": 0.4, "max": 1.5},
		{"key": "shrub_cluster_size", "label": "Clump sz", "min": 0.5, "max": 1.5},
		{"key": "shrub_vertical_offset_m", "label": "Raise", "min": -8.0, "max": 8.0},
	],
	"grass_lawn": [
		{"key": "grass_lawn_bulk_scale", "label": "Bulk×", "min": 0.5, "max": 3.0},
		{"key": "grass_lawn_growth_years", "label": "Growth yrs", "min": 0.0, "max": 10.0},
		{"key": "grass_lawn_card_w", "label": "Mat width", "min": 0.2, "max": 1.0},
		{"key": "grass_lawn_card_h", "label": "Height", "min": 0.05, "max": 0.30},
		{"key": "grass_lawn_vertical_offset_m", "label": "Raise", "min": -8.0, "max": 8.0},
		{"key": "grass_lawn_cells_per_side", "label": "Blade density", "min": 3.0, "max": 32.0},
		{"key": "grass_lawn_height_variation", "label": "Height var", "min": 0.0, "max": 1.0},
		{"key": "grass_lawn_blade_thickness", "label": "Blade width", "min": 0.05, "max": 1.0},
		{"key": "grass_lawn_blade_lean", "label": "Blade lean", "min": 0.0, "max": 0.5},
		{"key": "grass_lawn_hue_jitter", "label": "Color var", "min": 0.0, "max": 0.15},
	],
	"grass_field": [
		{"key": "grass_field_bulk_scale", "label": "Bulk×", "min": 0.5, "max": 3.0},
		{"key": "grass_field_growth_years", "label": "Growth yrs", "min": 0.0, "max": 10.0},
		{"key": "grass_field_card_w", "label": "Mat width", "min": 0.25, "max": 1.2},
		{"key": "grass_field_card_h", "label": "Height", "min": 0.3, "max": 1.5},
		{"key": "grass_field_vertical_offset_m", "label": "Raise", "min": -8.0, "max": 8.0},
		{"key": "grass_field_cells_per_side", "label": "Blade density", "min": 3.0, "max": 32.0},
		{"key": "grass_field_height_variation", "label": "Height var", "min": 0.0, "max": 1.0},
		{"key": "grass_field_blade_thickness", "label": "Blade width", "min": 0.05, "max": 1.0},
		{"key": "grass_field_blade_lean", "label": "Blade lean", "min": 0.0, "max": 0.5},
		{"key": "grass_field_hue_jitter", "label": "Color var", "min": 0.0, "max": 0.15},
	],
}

const SHADER_SLIDERS := [
	{"key": "translucency_strength", "label": "Translucency", "min": 0.0, "max": 1.0},
	{"key": "canopy_roundness", "label": "Roundness", "min": 0.0, "max": 1.0},
	{"key": "color_variation", "label": "Color var", "min": 0.0, "max": 0.25},
	{"key": "foliage_roughness", "label": "Foliage rough", "min": 0.5, "max": 1.0},
	{"key": "ao_strength", "label": "AO", "min": 0.0, "max": 1.0},
	{"key": "subsurface_strength", "label": "Subsurface", "min": 0.0, "max": 1.0},
	{"key": "bark_roughness", "label": "Bark rough", "min": 0.5, "max": 1.0},
	{"key": "bark_ao_strength", "label": "Bark AO", "min": 0.0, "max": 1.0},
	{"key": "bark_color_jitter", "label": "Bark jitter", "min": 0.0, "max": 0.2},
	{"key": "wind_strength", "label": "Wind", "min": 0.0, "max": 0.12},
	{"key": "wind_speed", "label": "Sway", "min": 0.2, "max": 2.0},
	{"key": "hue_jitter", "label": "Hue jitter", "min": 0.0, "max": 0.15},
]

var _loader: Node = null
var _dock: Control = null
var _active := false
var _species := "shrub"
var _density := 1.0
var _patch_diameter := 10.0
var _values: Dictionary = {}
var _baseline: Dictionary = {}
var _tints: Dictionary = {}
## Player OSM-kind → species override (e.g. {"wood": "pine"}). "auto" = biome.
var _osm_species_map: Dictionary = {}
var _osm_opts: Dictionary = {}

var _dim: ColorRect = null
var _panel: PanelContainer = null
var _viewport: SubViewport = null
var _studio: Node3D = null
var _veg_root: Node3D = null
var _camera: Camera3D = null
var _ground: MeshInstance3D = null
var _species_opt: OptionButton = null
var _preset_opt: OptionButton = null
var _preset_name_edit: LineEdit = null
var _species_section: VBoxContainer = null
var _tint_picker: ColorPickerButton = null
var _density_slider: HSlider = null
var _diameter_slider: HSlider = null
var _shader_sliders: Dictionary = {}
var _rebuild_pending := false
var _rebuild_timer := 0.0


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_build_ui()


func bind_loader(loader: Node, dock: Control = null) -> void:
	_loader = loader
	_dock = dock


func open(initial_preset: int = -1) -> void:
	if _active:
		return
	_load_from_loader()
	if initial_preset >= 0:
		_set_species_from_preset(initial_preset)
	_sync_species_dropdown()
	_rebuild_species_section()
	_refresh_preset_dropdown()
	_sync_tint_picker()
	_sync_top_sliders()
	_sync_osm_opts()
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_update_ground_and_camera()
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


func _style_section(lbl: Label, text: String) -> void:
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.5, 0.65, 0.8))
	lbl.add_theme_font_size_override("font_size", 11)


func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0, 0, 0, 0.55)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			close())
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.name = "PreviewPanel"
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(920, 580)
	_panel.offset_left = -460
	_panel.offset_top = -290
	_panel.offset_right = 460
	_panel.offset_bottom = 290
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var root_row := HBoxContainer.new()
	root_row.add_theme_constant_override("separation", 12)
	margin.add_child(root_row)

	# Left: 3D preview
	var preview_col := VBoxContainer.new()
	preview_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_col.custom_minimum_size = Vector2(500, 0)
	root_row.add_child(preview_col)

	var preview_hdr := Label.new()
	_style_section(preview_hdr, "Preview patch")
	preview_col.add_child(preview_hdr)

	var vp_container := SubViewportContainer.new()
	vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_container.custom_minimum_size = Vector2(480, 460)
	vp_container.stretch = true
	preview_col.add_child(vp_container)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(640, 480)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp_container.add_child(_viewport)
	_build_studio_world()

	# Right: controls
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 520)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_row.add_child(scroll)

	var sidebar := VBoxContainer.new()
	sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar.add_theme_constant_override("separation", 6)
	scroll.add_child(sidebar)

	var type_row := HBoxContainer.new()
	sidebar.add_child(type_row)
	var type_lbl := Label.new()
	_style_section(type_lbl, "Type")
	type_lbl.custom_minimum_size = Vector2(44, 0)
	type_row.add_child(type_lbl)
	_species_opt = OptionButton.new()
	_species_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in SPECIES_LABELS.size():
		_species_opt.add_item(SPECIES_LABELS[i], i)
	_species_opt.item_selected.connect(_on_species_selected)
	type_row.add_child(_species_opt)

	_build_preset_row(sidebar)

	_density_slider = _labeled_slider(sidebar, "Density", 0.25, 3.0, _density,
		func(v: float) -> void:
			_density = v
			_queue_rebuild())
	_diameter_slider = _labeled_slider(sidebar, "Patch Ø m", 4.0, 24.0, _patch_diameter,
		func(v: float) -> void:
			_patch_diameter = v
			_update_ground_and_camera()
			_queue_rebuild())

	_species_section = VBoxContainer.new()
	_species_section.add_theme_constant_override("separation", 4)
	sidebar.add_child(_species_section)

	var tint_row := HBoxContainer.new()
	sidebar.add_child(tint_row)
	var tint_lbl := Label.new()
	_style_section(tint_lbl, "Tint")
	tint_lbl.custom_minimum_size = Vector2(44, 0)
	tint_row.add_child(tint_lbl)
	_tint_picker = ColorPickerButton.new()
	_tint_picker.custom_minimum_size = Vector2(52, 24)
	_tint_picker.color_changed.connect(_on_tint_changed)
	tint_row.add_child(_tint_picker)

	var shader_hdr := Label.new()
	_style_section(shader_hdr, "Shader")
	sidebar.add_child(shader_hdr)
	for spec in SHADER_SLIDERS:
		var sd: Dictionary = spec
		var key := str(sd["key"])
		var sl := _labeled_slider(sidebar, str(sd["label"]), float(sd["min"]), float(sd["max"]),
			float(_values.get(key, VegetationStyleConfig.defaults().get(key, 0.0))),
			func(v: float) -> void:
				_values[key] = v
				_queue_rebuild())
		_shader_sliders[key] = sl

	_build_osm_section(sidebar)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	sidebar.add_child(btn_row)
	var apply_btn := Button.new()
	apply_btn.text = "Apply to map"
	apply_btn.custom_minimum_size = Vector2(104, 30)
	apply_btn.pressed.connect(_apply_to_map)
	btn_row.add_child(apply_btn)
	var brush_btn := Button.new()
	brush_btn.text = "Apply to brush"
	brush_btn.custom_minimum_size = Vector2(108, 30)
	brush_btn.tooltip_text = "Paint the next trees with this look only (map unchanged)"
	brush_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	brush_btn.pressed.connect(_apply_to_brush)
	btn_row.add_child(brush_btn)
	var reset_btn := Button.new()
	reset_btn.text = "Reset"
	reset_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	reset_btn.pressed.connect(_reset_values)
	btn_row.add_child(reset_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	close_btn.pressed.connect(close)
	btn_row.add_child(close_btn)


func _labeled_slider(parent: Control, label: String, min_v: float, max_v: float,
		start: float, handler: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)
	var lbl := Label.new()
	_style_section(lbl, label)
	lbl.custom_minimum_size = Vector2(72, 0)
	row.add_child(lbl)
	var sl := HSlider.new()
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step = 0.01 if max_v <= 2.0 else 0.05
	sl.value = start
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.custom_minimum_size = Vector2(120, 0)
	sl.value_changed.connect(handler)
	row.add_child(sl)
	return sl


func _rebuild_species_section() -> void:
	if _species_section == null:
		return
	for child in _species_section.get_children():
		child.queue_free()
	var specs: Array = SPECIES_SHAPE_SLIDERS.get(_species, [])
	if specs.is_empty():
		return
	var hdr := Label.new()
	_style_section(hdr, SPECIES_LABELS[SPECIES_IDS.find(_species)])
	_species_section.add_child(hdr)
	for spec in specs:
		var sd: Dictionary = spec
		var key := str(sd["key"])
		_labeled_slider(_species_section, str(sd["label"]), float(sd["min"]), float(sd["max"]),
			float(_values.get(key, 0.0)),
			func(v: float) -> void:
				_values[key] = v
				_queue_rebuild())


# ---------------------------------------------------------------------------
# Per-species look presets
# ---------------------------------------------------------------------------

func _build_preset_row(sidebar: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	sidebar.add_child(row)
	var lbl := Label.new()
	_style_section(lbl, "Preset")
	lbl.custom_minimum_size = Vector2(44, 0)
	row.add_child(lbl)
	_preset_opt = OptionButton.new()
	_preset_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_opt.item_selected.connect(_on_preset_selected)
	row.add_child(_preset_opt)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	sidebar.add_child(row2)
	_preset_name_edit = LineEdit.new()
	_preset_name_edit.placeholder_text = "Preset name…"
	_preset_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_name_edit.text_submitted.connect(func(_t: String) -> void: _on_preset_save())
	row2.add_child(_preset_name_edit)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(52, 26)
	save_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	save_btn.tooltip_text = "Save current %s look as a named preset" % _species
	save_btn.pressed.connect(_on_preset_save)
	row2.add_child(save_btn)
	var del_btn := Button.new()
	del_btn.text = "Del"
	del_btn.custom_minimum_size = Vector2(40, 26)
	del_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	del_btn.tooltip_text = "Delete the selected preset"
	del_btn.pressed.connect(_on_preset_delete)
	row2.add_child(del_btn)


## Refresh the preset dropdown for the current species. Item 0 is a placeholder.
func _refresh_preset_dropdown() -> void:
	if _preset_opt == null:
		return
	_preset_opt.clear()
	_preset_opt.add_item("— presets —", 0)
	_preset_opt.set_item_disabled(0, true)
	for preset_name in VegetationStyleConfig.list_presets(_species):
		_preset_opt.add_item(str(preset_name))
	_preset_opt.select(0)


## Shape sliders + tint for the current species — the unit a preset captures.
func _species_preset_values() -> Dictionary:
	var out := {}
	for spec in SPECIES_SHAPE_SLIDERS.get(_species, []):
		var key := str((spec as Dictionary)["key"])
		if _values.has(key):
			out[key] = _values[key]
	out["%s_albedo_tint" % _species] = _tints.get(_species, Color.WHITE)
	return out


func _apply_preset_values(values: Dictionary) -> void:
	for k in values:
		if str(k).ends_with("_albedo_tint"):
			_tints[_species] = values[k]
		else:
			_values[k] = values[k]
	_rebuild_species_section()
	_sync_tint_picker()
	_sync_top_sliders()
	_queue_rebuild(true)


func _on_preset_selected(idx: int) -> void:
	if idx <= 0 or _preset_opt == null:
		return
	var preset_name := _preset_opt.get_item_text(idx)
	var values := VegetationStyleConfig.load_preset(_species, preset_name)
	if values.is_empty():
		return
	if _preset_name_edit != null:
		_preset_name_edit.text = preset_name
	_apply_preset_values(values)


func _on_preset_save() -> void:
	if _preset_name_edit == null:
		return
	var preset_name := _preset_name_edit.text.strip_edges()
	if preset_name.is_empty():
		_preset_name_edit.placeholder_text = "Type a name first…"
		return
	VegetationStyleConfig.save_preset(_species, preset_name, _species_preset_values())
	_refresh_preset_dropdown()
	for i in _preset_opt.item_count:
		if _preset_opt.get_item_text(i) == preset_name:
			_preset_opt.select(i)
			break


func _on_preset_delete() -> void:
	if _preset_opt == null:
		return
	var idx := _preset_opt.selected
	if idx <= 0:
		return
	var preset_name := _preset_opt.get_item_text(idx)
	VegetationStyleConfig.delete_preset(_species, preset_name)
	if _preset_name_edit != null:
		_preset_name_edit.text = ""
	_refresh_preset_dropdown()


# ---------------------------------------------------------------------------
# OSM → species picker
# ---------------------------------------------------------------------------

func _build_osm_section(sidebar: VBoxContainer) -> void:
	var hdr := Label.new()
	_style_section(hdr, "OSM → tree type")
	sidebar.add_child(hdr)
	var hint := Label.new()
	hint.text = "Which shader type fills each OpenStreetMap area."
	hint.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	hint.add_theme_font_size_override("font_size", 9)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sidebar.add_child(hint)
	for entry in BiomePalette.MAPPABLE_KINDS:
		var kind := str((entry as Array)[0])
		var label := str((entry as Array)[1])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		sidebar.add_child(row)
		var lbl := Label.new()
		_style_section(lbl, label)
		lbl.custom_minimum_size = Vector2(96, 0)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(lbl)
		var opt := OptionButton.new()
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for i in BiomePalette.SPECIES_OVERRIDE_OPTIONS.size():
			opt.add_item(str(BiomePalette.SPECIES_OVERRIDE_LABELS[i]), i)
		opt.item_selected.connect(func(idx: int) -> void:
			_osm_species_map[kind] = str(BiomePalette.SPECIES_OVERRIDE_OPTIONS[idx]))
		row.add_child(opt)
		_osm_opts[kind] = opt


func _sync_osm_opts() -> void:
	for kind in _osm_opts:
		var opt := _osm_opts[kind] as OptionButton
		if opt == null:
			continue
		var choice := str(_osm_species_map.get(kind, "auto"))
		var idx := BiomePalette.SPECIES_OVERRIDE_OPTIONS.find(choice)
		opt.select(idx if idx >= 0 else 0)


# ---------------------------------------------------------------------------
# Studio world
# ---------------------------------------------------------------------------

func _build_studio_world() -> void:
	var world := World3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.42, 0.46, 0.50)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.62)
	env.ambient_light_energy = 0.35
	world.environment = env
	_viewport.world_3d = world

	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.fov = 48.0
	_studio.add_child(_camera)

	var key := DirectionalLight3D.new()
	key.name = "KeyLight"
	key.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	key.light_energy = 1.15
	key.shadow_enabled = true
	_studio.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-18.0, -135.0, 0.0)
	fill.light_energy = 0.28
	_studio.add_child(fill)

	_ground = MeshInstance3D.new()
	_ground.name = "Ground"
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.22, 0.28, 0.18)
	ground_mat.roughness = 0.95
	_ground.material_override = ground_mat
	_studio.add_child(_ground)

	_veg_root = Node3D.new()
	_veg_root.name = "Vegetation"
	_studio.add_child(_veg_root)

	_update_ground_and_camera()


func _update_ground_and_camera() -> void:
	if _ground == null or _camera == null:
		return
	var cyl := CylinderMesh.new()
	var r := _patch_diameter * 0.55
	cyl.top_radius = r
	cyl.bottom_radius = r
	cyl.height = 0.06
	_ground.mesh = cyl
	_ground.position.y = -0.03
	var dist := _patch_diameter * 1.2
	_camera.position = Vector3(dist * 0.72, _patch_diameter * 0.48, dist * 0.72)
	_camera.look_at(Vector3(0.0, _patch_diameter * 0.12, 0.0))


# ---------------------------------------------------------------------------
# Preview scatter + rebuild
# ---------------------------------------------------------------------------

func _merged_settings() -> Dictionary:
	var out := _values.duplicate(true)
	out["%s_albedo_tint" % _species] = _tints.get(_species, Color.WHITE)
	out["use_drape"] = false
	return out


func _apply_studio(mat: ShaderMaterial) -> void:
	if mat == null:
		return
	mat.set_shader_parameter("use_drape", false)
	mat.set_shader_parameter("sun_direction", STUDIO_SUN)
	mat.set_shader_parameter("night_factor", 0.0)
	mat.set_shader_parameter("haze_strength", 0.12)
	mat.set_shader_parameter("drape_match_strength", 0.0)


func _base_spacing() -> float:
	match _species:
		"grass_lawn":
			return 0.75
		"grass_field":
			return 1.1
		"shrub":
			return 3.5
		"pine":
			return 6.0
		"deciduous":
			return 8.0
		_:
			return 4.0


func _effective_spacing() -> float:
	return maxf(0.35, _base_spacing() / maxf(_density, 0.25))


func _scatter_spots() -> Array:
	var radius := _patch_diameter * 0.5
	var poly := VegetationPaint.circle_polygon(Vector2.ZERO, radius, 28)
	var rng := RandomNumberGenerator.new()
	rng.seed = PREVIEW_SEED
	var max_count := 500 if _species.begins_with("grass_") else 64
	return VegetationPaint.poisson_fill(poly, _effective_spacing(), rng, [], max_count)


func _rebuild_preview() -> void:
	if _veg_root == null:
		return
	for child in _veg_root.get_children():
		child.queue_free()
	var settings := _merged_settings()
	var spots: Array = _scatter_spots()
	if spots.is_empty():
		return
	if _species in VegetationLayer.GRASS_SPECIES:
		_build_grass_preview(spots, settings)
	else:
		_build_card_preview(spots, settings)


func _build_card_preview(spots: Array, settings: Dictionary) -> void:
	VegetationCardFactory.clear_foot_cache()
	var mesh := VegetationCardFactory.mesh_for_species(_species, settings)
	var use_surface := VegetationCardFactory.mesh_has_surface_materials(_species)
	var mat: ShaderMaterial = null
	if not use_surface:
		mat = VegetationCardFactory.material_for_species(_species, settings)
		_apply_studio(mat)
	else:
		for surf_i in mesh.get_surface_count():
			var sm := mesh.surface_get_material(surf_i) as ShaderMaterial
			_apply_studio(sm)
	var species_scale := VegetationCardFactory.species_bulk_scale(_species, settings)
	var foot_y := VegetationCardFactory.foot_local_y(_species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(_species, settings)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = spots.size()
	var i := 0
	for item in spots:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var x := float(d.get("x", 0.0))
		var z := float(d.get("z", 0.0))
		var yaw := float(d.get("yaw", 0.0))
		var sc := float(d.get("scale", 1.0)) * species_scale
		mm.set_instance_transform(i, VegetationPaint.build_transform(
			x, 0.0, z, yaw, sc, false, Vector3.UP, vert_off, foot_y))
		i += 1
	mm.instance_count = i
	if i == 0:
		return
	var mi := MultiMeshInstance3D.new()
	mi.name = "PreviewBulk"
	mi.multimesh = mm
	if not use_surface:
		mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_veg_root.add_child(mi)


func _build_grass_preview(spots: Array, settings: Dictionary) -> void:
	var mesh := GrassBuilder.mesh_for_lod(_species, settings, GrassBuilder.LodTier.NEAR)
	var mat := GrassBuilder.material_for_species(_species, settings, GrassBuilder.LodTier.NEAR)
	_apply_studio(mat)
	var species_scale := GrassBuilder.bulk_scale(_species, settings)
	var vert_off := VegetationLayer.vertical_offset_for(_species, settings)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = spots.size()
	var i := 0
	for item in spots:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var x := float(d.get("x", 0.0))
		var z := float(d.get("z", 0.0))
		var yaw := float(d.get("yaw", 0.0))
		var sc := float(d.get("scale", 1.0)) * species_scale
		mm.set_instance_transform(i, VegetationPaint.build_transform(
			x, 0.0, z, yaw, sc, false, Vector3.UP, vert_off, 0.0))
		i += 1
	mm.instance_count = i
	if i == 0:
		return
	var mi := MultiMeshInstance3D.new()
	mi.name = "PreviewGrass"
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_veg_root.add_child(mi)


# ---------------------------------------------------------------------------
# Data load / apply
# ---------------------------------------------------------------------------

func _load_from_loader() -> void:
	var shape := VegetationLayer.default_settings()
	var style := VegetationStyleConfig.defaults()
	if _loader != null:
		if _loader.has_method("get_vegetation_settings"):
			shape = _loader.call("get_vegetation_settings")
		if _loader.has_method("get_vegetation_style"):
			style = _loader.call("get_vegetation_style")
	# Precedence MUST match the render path: terrain_loader._auto_veg_runtime_settings
	# builds settings from the style, then merges layer.get_settings() ON TOP — so
	# for shape keys present in both stores, the LAYER value is what actually renders.
	# Load style scalars first, then let the layer (shape) win, otherwise the editor
	# shows style defaults that don't match the trees on the map (and "Apply to map"
	# would then overwrite the map's real values with those wrong defaults).
	_values = {}
	for k in style:
		if k.ends_with("_albedo_tint") or k.ends_with("_highlight_tint"):
			continue
		if typeof(style[k]) in [TYPE_FLOAT, TYPE_INT, TYPE_BOOL]:
			_values[k] = style[k]
	for k in shape:
		_values[k] = shape[k]
	_tints = {
		"pine": style.get("pine_albedo_tint", Color.WHITE),
		"deciduous": style.get("deciduous_albedo_tint", Color.WHITE),
		"shrub": style.get("shrub_albedo_tint", Color.WHITE),
		"grass_lawn": style.get("grass_lawn_albedo_tint", Color.WHITE),
		"grass_field": style.get("grass_field_albedo_tint", Color.WHITE),
	}
	var raw_map: Dictionary = style.get("osm_species_map", {})
	_osm_species_map = {}
	for k in raw_map:
		_osm_species_map[str(k)] = str(raw_map[k])
	_baseline = _values.duplicate(true)
	for species in SPECIES_IDS:
		_baseline["%s_albedo_tint" % species] = _tints[species]
	_baseline["osm_species_map"] = _osm_species_map.duplicate(true)
	# Density slider drives the auto-forest density (auto_density_scale) and the
	# brush; reflect the map's stored value so it matches what's on the ground.
	if style.has("auto_density_scale"):
		_density = clampf(float(style.get("auto_density_scale", 1.0)), 0.25, 3.0)
	elif _dock != null and _dock.has_method("get_paint_density"):
		_density = float(_dock.call("get_paint_density"))


func _sync_top_sliders() -> void:
	if _density_slider != null:
		_density_slider.value = _density
	if _diameter_slider != null:
		_diameter_slider.value = _patch_diameter
	for key in _shader_sliders:
		if _values.has(key):
			(_shader_sliders[key] as HSlider).value = float(_values[key])


func _shape_dict() -> Dictionary:
	var out := {}
	var shape_keys: Array[String] = []
	for species in SPECIES_IDS:
		for spec in SPECIES_SHAPE_SLIDERS.get(species, []):
			shape_keys.append(str((spec as Dictionary)["key"]))
	shape_keys.append("vertical_offset_m")
	for k in shape_keys:
		if _values.has(k):
			out[k] = _values[k]
	return out


func _style_dict() -> Dictionary:
	var out := {}
	for spec in SHADER_SLIDERS:
		var key := str((spec as Dictionary)["key"])
		if _values.has(key):
			out[key] = _values[key]
	for species in SPECIES_IDS:
		var tk := "%s_albedo_tint" % species
		out[tk] = _tints.get(species, Color.WHITE)
	out["osm_species_map"] = _osm_species_map.duplicate(true)
	# Density drives the auto (OSM) forest scatter density on Apply to map.
	out["auto_density_scale"] = _density
	return out


## Full per-instance look snapshot (shape + shader + tint) for "Apply to brush":
## stamped as card_settings onto trees the player paints next, so they keep this
## look independent of later "Apply to map" changes.
func _brush_card() -> Dictionary:
	var out := _shape_dict()
	for spec in SHADER_SLIDERS:
		var key := str((spec as Dictionary)["key"])
		if _values.has(key):
			out[key] = _values[key]
	for species in SPECIES_IDS:
		out["%s_albedo_tint" % species] = _tints.get(species, Color.WHITE)
	return out


func _apply_to_map() -> void:
	if _loader == null:
		return
	var shape := _shape_dict()
	var style := _style_dict()
	# One coalesced apply (shape + style together, single rebuild) avoids the old
	# set_vegetation_settings + set_vegetation_style double-cascade of rebuilds.
	if _loader.has_method("apply_vegetation_look"):
		_loader.call("apply_vegetation_look", shape, style)
	else:
		if _loader.has_method("set_vegetation_settings"):
			_loader.call("set_vegetation_settings", shape, true, true)
		if _loader.has_method("set_vegetation_style"):
			_loader.call("set_vegetation_style", style, true, true)
	# Persist this look as the GLOBAL default so future maps inherit it (per-map
	# saves still override). This is what makes tune-look changes "stick" between
	# maps and reloads instead of resetting to hardcoded defaults every time.
	var global_look := shape.duplicate(true)
	global_look.merge(style, true)
	VegetationStyleConfig.save_global(global_look)
	if _dock != null and _dock.has_method("set_paint_density"):
		_dock.call("set_paint_density", _density)
	# Apply to map = one global look; clear any per-brush override so future
	# painting matches the map (custom brush trees already placed keep their look).
	if _dock != null and _dock.has_method("set_brush_style"):
		_dock.call("set_brush_style", {})
	applied.emit()
	close()


## Push the current look to the paint brush only — future painted trees carry it
## as a per-instance override; the map's existing trees are untouched.
func _apply_to_brush() -> void:
	if _dock != null and _dock.has_method("set_brush_style"):
		_dock.call("set_brush_style", _brush_card())
	if _dock != null and _dock.has_method("set_paint_density"):
		_dock.call("set_paint_density", _density)
	close()


func _reset_values() -> void:
	_values = _baseline.duplicate(true)
	for species in SPECIES_IDS:
		var tk := "%s_albedo_tint" % species
		if _baseline.has(tk):
			_tints[species] = _baseline[tk]
	_osm_species_map = (_baseline.get("osm_species_map", {}) as Dictionary).duplicate(true)
	_rebuild_species_section()
	_sync_tint_picker()
	_sync_top_sliders()
	_sync_osm_opts()
	_queue_rebuild(true)


func _on_species_selected(idx: int) -> void:
	if idx >= 0 and idx < SPECIES_IDS.size():
		_species = SPECIES_IDS[idx]
	_rebuild_species_section()
	_refresh_preset_dropdown()
	if _preset_name_edit != null:
		_preset_name_edit.text = ""
	_sync_tint_picker()
	_queue_rebuild(true)


func _on_tint_changed(c: Color) -> void:
	_tints[_species] = c
	_queue_rebuild()


func _sync_species_dropdown() -> void:
	if _species_opt == null:
		return
	var idx := SPECIES_IDS.find(_species)
	if idx >= 0:
		_species_opt.select(idx)


func _sync_tint_picker() -> void:
	if _tint_picker != null:
		_tint_picker.color = _tints.get(_species, Color.WHITE)


func _set_species_from_preset(preset: int) -> void:
	match preset:
		VegetationPaint.Preset.PINE:
			_species = "pine"
		VegetationPaint.Preset.DECIDUOUS:
			_species = "deciduous"
		VegetationPaint.Preset.GRASS_LAWN:
			_species = "grass_lawn"
		VegetationPaint.Preset.GRASS_FIELD:
			_species = "grass_field"
		_:
			_species = "shrub"
