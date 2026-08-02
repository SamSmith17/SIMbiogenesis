extends PanelContainer

## Per-area vegetation fill drawer (veg overhaul Phase 7). Opened by Interact /
## O on a crosshair-focused OSM vegetation area: pick a species, density and
## canopy height, and plant that outline.
##
## Phase A shipped only the highlight and a "open Tune look on the right
## species" stub — the player could point at a wood and change how ALL woods
## look, but not what grows in THAT one. This is the missing half.
##
## The fill is persisted per area (AutoVegetationEdits.fills, keyed by the
## area's centroid tag) and replayed by the generator on every later load, so a
## filled area is not a one-off edit that the next re-scatter wipes.

const C_PANEL := Color(0.082, 0.114, 0.208, 1.0)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_MUTED := Color(0.62, 0.68, 0.78, 1.0)
const C_ACCENT := Color(0.24, 0.62, 1.0, 1.0)

const DRAWER_HEIGHT := 132.0

var _loader: Node = null
var _area_idx: int = -1
var _syncing := false
## Species ids in dropdown order (BiomePalette's list, "auto" first).
var _species_ids: Array[String] = []

var _title_lbl: Label
var _meta_lbl: Label
var _status_lbl: Label
var _species_opt: OptionButton
var _density_slider: HSlider
var _density_lbl: Label
var _height_spin: SpinBox
var _replace_chk: CheckBox
var _fill_btn: Button
var _clear_btn: Button
var _tune_btn: Button


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_layout_drawer()


func bind_loader(loader: Node) -> void:
	_loader = loader


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		_layout_drawer()


func _layout_drawer() -> void:
	var clearance := UiScreenLayout.timeline_stack_height()
	var main := get_tree().current_scene
	var timeline: Node = null
	if main != null:
		timeline = main.get_node_or_null("UILayer/TimelineUI")
	if timeline != null and timeline.has_method("get_stack_height"):
		clearance = float(timeline.call("get_stack_height"))
	UiScreenLayout.pin_above_timeline(self, DRAWER_HEIGHT, clearance)


func open_for_area(idx: int) -> void:
	_area_idx = idx
	if not _load_from_loader():
		return
	_layout_drawer()
	visible = true
	CursorController.request_modal("veg_area_fill", Callable(self, "close"))


func close() -> void:
	if not visible:
		return
	visible = false
	_area_idx = -1
	CursorController.release_modal("veg_area_fill")


func _build_ui() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = C_PANEL
	panel_style.border_color = C_BORDER
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 14
	panel_style.content_margin_right = 14
	panel_style.content_margin_top = 8
	panel_style.content_margin_bottom = 8
	add_theme_stylebox_override("panel", panel_style)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	root.add_child(header)
	_title_lbl = Label.new()
	_title_lbl.text = "Fill area"
	_title_lbl.add_theme_color_override("font_color", C_TEXT)
	_title_lbl.add_theme_font_size_override("font_size", 14)
	header.add_child(_title_lbl)
	_meta_lbl = Label.new()
	_meta_lbl.add_theme_color_override("font_color", C_MUTED)
	_meta_lbl.add_theme_font_size_override("font_size", 11)
	_meta_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_meta_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_meta_lbl)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.tooltip_text = "Close (Esc)"
	close_btn.custom_minimum_size = Vector2(30, 26)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	root.add_child(row)

	# Species ---------------------------------------------------------------
	var sp_col := VBoxContainer.new()
	sp_col.add_theme_constant_override("separation", 2)
	sp_col.custom_minimum_size.x = 210.0
	row.add_child(sp_col)
	sp_col.add_child(_field_label("Plant"))
	_species_opt = OptionButton.new()
	_species_opt.custom_minimum_size.x = 210.0
	_populate_species()
	sp_col.add_child(_species_opt)

	# Density ---------------------------------------------------------------
	var d_col := VBoxContainer.new()
	d_col.add_theme_constant_override("separation", 0)
	d_col.custom_minimum_size.x = 220.0
	row.add_child(d_col)
	var d_head := HBoxContainer.new()
	d_col.add_child(d_head)
	d_head.add_child(_field_label("Density"))
	_density_lbl = Label.new()
	_density_lbl.add_theme_color_override("font_color", C_ACCENT)
	_density_lbl.add_theme_font_size_override("font_size", 11)
	_density_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_density_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	d_head.add_child(_density_lbl)
	_density_slider = HSlider.new()
	_density_slider.min_value = 0.2
	_density_slider.max_value = 3.0
	_density_slider.step = 0.05
	_density_slider.value = 1.0
	_density_slider.custom_minimum_size = Vector2(220, 20)
	_density_slider.value_changed.connect(_on_density_changed)
	d_col.add_child(_density_slider)

	# Height + replace ------------------------------------------------------
	var h_col := VBoxContainer.new()
	h_col.add_theme_constant_override("separation", 2)
	row.add_child(h_col)
	h_col.add_child(_field_label("Canopy height (0 = biome)"))
	var h_row := HBoxContainer.new()
	h_row.add_theme_constant_override("separation", 8)
	h_col.add_child(h_row)
	_height_spin = SpinBox.new()
	_height_spin.min_value = 0.0
	_height_spin.max_value = 45.0
	_height_spin.step = 0.5
	_height_spin.suffix = "m"
	_height_spin.custom_minimum_size.x = 90.0
	h_row.add_child(_height_spin)
	_replace_chk = CheckBox.new()
	_replace_chk.text = "Replace what's there"
	_replace_chk.button_pressed = true
	_replace_chk.tooltip_text = "Clear the area's existing trees before planting"
	h_row.add_child(_replace_chk)

	# Actions ---------------------------------------------------------------
	var act_col := VBoxContainer.new()
	act_col.add_theme_constant_override("separation", 2)
	act_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(act_col)
	_status_lbl = Label.new()
	_status_lbl.add_theme_color_override("font_color", C_MUTED)
	_status_lbl.add_theme_font_size_override("font_size", 10)
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	act_col.add_child(_status_lbl)
	var act := HBoxContainer.new()
	act.add_theme_constant_override("separation", 6)
	act.alignment = BoxContainer.ALIGNMENT_END
	act_col.add_child(act)
	_tune_btn = Button.new()
	_tune_btn.text = "Tune look…"
	_tune_btn.tooltip_text = "Edit how this species looks everywhere on the map"
	_tune_btn.custom_minimum_size = Vector2(96, 30)
	_tune_btn.pressed.connect(_on_tune)
	act.add_child(_tune_btn)
	_clear_btn = Button.new()
	_clear_btn.text = "Clear area"
	_clear_btn.tooltip_text = "Remove every plant inside this outline"
	_clear_btn.custom_minimum_size = Vector2(90, 30)
	_clear_btn.pressed.connect(_on_clear)
	act.add_child(_clear_btn)
	_fill_btn = Button.new()
	_fill_btn.text = "Fill area"
	_fill_btn.custom_minimum_size = Vector2(96, 30)
	_fill_btn.pressed.connect(_on_fill)
	act.add_child(_fill_btn)


func _field_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", C_MUTED)
	l.add_theme_font_size_override("font_size", 10)
	return l


## "auto" (whatever the biome would pick) first, then the shared species list —
## the same ids the OSM→species binding offers, so the two pickers can't drift.
func _populate_species() -> void:
	_species_ids.clear()
	_species_opt.clear()
	var ids := BiomePalette.override_options()
	var labels := BiomePalette.override_labels()
	for i in ids.size():
		var id := str(ids[i])
		var label := str(labels[i]) if i < labels.size() else id.capitalize()
		if id == "auto":
			label = "Auto (biome default)"
		_species_ids.append(id)
		_species_opt.add_item(label, i)


func _load_from_loader() -> bool:
	if _loader == null or not _loader.has_method("get_veg_area_info"):
		return false
	var info: Dictionary = _loader.call("get_veg_area_info", _area_idx)
	if not bool(info.get("valid", false)):
		return false
	_syncing = true
	_title_lbl.text = "Fill %s" % str(info.get("kind_label", "area"))
	var area_m2 := float(info.get("area_m2", 0.0))
	_meta_lbl.text = "%s  ·  %s" % [_area_text(area_m2), str(info.get("tag", ""))]

	# Re-opening an already-filled area shows what it was filled WITH, so the
	# drawer reads as the area's state rather than a blank form.
	var existing: Dictionary = {}
	if _loader.has_method("area_fill_params"):
		existing = _loader.call("area_fill_params", _area_idx)
	var species := str(existing.get("species", _default_species_for(info)))
	var at := _species_ids.find(species)
	_species_opt.select(at if at >= 0 else 0)
	_density_slider.value = float(existing.get("density", 1.0))
	_density_lbl.text = "×%.2f" % _density_slider.value
	_height_spin.value = float(existing.get("height_m", 0.0))
	_replace_chk.button_pressed = bool(existing.get("replace", true))
	_status_lbl.text = "Filled already — Fill again to change it" if not existing.is_empty() \
		else "Plants inside the outline; saved with the map"
	_syncing = false
	return true


static func _area_text(area_m2: float) -> String:
	if area_m2 >= 10000.0:
		return "%.1f ha" % (area_m2 / 10000.0)
	return "%.0f m²" % area_m2


## Seed the picker from whatever the area already reads as, so "Fill" with no
## other change is a no-surprise re-plant of the same kind of vegetation.
func _default_species_for(info: Dictionary) -> String:
	match str(info.get("kind", "")):
		"scrub":
			return "shrub"
		"wetland":
			return "shrub"
		"park", "cemetery":
			return "mixed"
	return "auto"


func _on_density_changed(v: float) -> void:
	_density_lbl.text = "×%.2f" % v


func _on_fill() -> void:
	if _loader == null or _syncing or not _loader.has_method("apply_area_fill"):
		return
	var idx := _species_opt.get_selected_id()
	var species := str(_species_ids[idx]) if idx >= 0 and idx < _species_ids.size() else "auto"
	var res: Dictionary = _loader.call("apply_area_fill", _area_idx, {
		"species": species,
		"density": _density_slider.value,
		"height_m": _height_spin.value,
		"replace": _replace_chk.button_pressed,
	})
	var placed := int(res.get("placed", 0))
	if placed <= 0:
		# Almost always the instance budget, a slope veto or an exclusion zone
		# rather than a broken fill — say so instead of failing silently.
		_status_lbl.text = "Nothing placed — area may be excluded, too steep, or the tree budget is spent"
		return
	_status_lbl.text = "Planted %d (cleared %d)" % [placed, int(res.get("removed", 0))]


func _on_clear() -> void:
	if _loader == null or not _loader.has_method("clear_area_fill"):
		return
	_loader.call("clear_area_fill", _area_idx, true)
	_status_lbl.text = "Cleared"


func _on_tune() -> void:
	if _loader == null or not _loader.has_method("open_veg_area_tune"):
		return
	var idx := _area_idx
	close()
	_loader.call("open_veg_area_tune", idx)
