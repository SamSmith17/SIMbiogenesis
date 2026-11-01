extends Control

## Per-area vegetation fill drawer (veg overhaul Phase 7). Opened by Interact /
## O on a crosshair-focused OSM vegetation area: pick a species, density and
## canopy height, and plant that outline. On the kit's `Drawer` (the pond
## settings' shape): a title line, three columns of FormRows across, the
## actions on the right, pinned above the timeline and sized to its rows.
##
## Phase A shipped only the highlight and a "open Tune look on the right
## species" stub — the player could point at a wood and change how ALL woods
## look, but not what grows in THAT one. This is the missing half.
##
## The fill is persisted per area (AutoVegetationEdits.fills, keyed by the
## area's centroid tag) and replayed by the generator on every later load, so a
## filled area is not a one-off edit that the next re-scatter wipes.

const DRAWER_NAME := "veg_area_fill"

var _loader: Node = null
var _area_idx: int = -1
var _syncing := false
## Species ids in dropdown order (BiomePalette's list, "auto" first).
var _species_ids: Array[String] = []

var _drawer: Drawer = null
var _status_lbl: Label
var _species_opt: OptionButton
var _density_slider: HSlider
var _height_spin: SpinBox
var _replace_chk: CheckBox
var _fill_btn: Button
var _clear_btn: Button
var _tune_btn: Button


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func bind_loader(loader: Node) -> void:
	_loader = loader


func open_for_area(idx: int) -> void:
	_area_idx = idx
	if not _load_from_loader():
		return
	visible = true
	_drawer.open()


func close() -> void:
	if not visible:
		return
	visible = false
	_area_idx = -1
	_drawer.close()


func is_open() -> bool:
	return visible


func _build_ui() -> void:
	_drawer = Drawer.create("Fill area", DRAWER_NAME)
	add_child(_drawer)
	_drawer.closed.connect(close)

	# Plant ------------------------------------------------------------------
	var plant_col := Drawer.column(360.0)
	_drawer.body.add_child(plant_col)
	_species_opt = OptionButton.new()
	_species_opt.fit_to_longest_item = false
	_species_opt.clip_text = true
	_populate_species()
	plant_col.add_child(FormRow.make("Plant", _species_opt, "What grows in this outline", "", "fill_species"))
	var dens := FormRow.slider("Density", 0.2, 3.0, 1.0, 0.05, "×", Callable(),
		"Spacing against the species' own (1 = as the map would scatter it)", "fill_density")
	_density_slider = dens.control as HSlider
	plant_col.add_child(dens)

	# Size -------------------------------------------------------------------
	var size_col := Drawer.column(340.0)
	_drawer.body.add_child(size_col)
	var h_row := FormRow.spin("Canopy height", 0.0, 45.0, 0.5, "m", Callable(),
		"The trees' height; 0 takes the biome's own", "fill_height")
	_height_spin = h_row.control as SpinBox
	size_col.add_child(h_row)
	_replace_chk = CheckBox.new()
	_replace_chk.text = "Replace what's there"
	_replace_chk.button_pressed = true
	_replace_chk.tooltip_text = "Clear the area's existing trees before planting"
	size_col.add_child(FormRow.make("Existing", _replace_chk, "", "", "fill_replace"))

	# Status + the whole-species edit -------------------------------------------
	# A fixed width: an autowrapped label in a width-less column reports a
	# minimum HEIGHT for the narrowest wrap, and the drawer (sized to its
	# rows) then stood as tall as the screen at 720.
	var note_col := Drawer.column(300.0)
	_drawer.body.add_child(note_col)
	_status_lbl = Label.new()
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.custom_minimum_size.x = 300.0
	note_col.add_child(_status_lbl)
	_tune_btn = Button.new()
	_tune_btn.text = "Tune look…"
	_tune_btn.tooltip_text = "Edit how this species looks everywhere on the map"
	_tune_btn.focus_mode = Control.FOCUS_NONE
	_tune_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UITheme.style_button(_tune_btn)
	_tune_btn.pressed.connect(_on_tune)
	note_col.add_child(_tune_btn)

	_fill_btn = _drawer.add_action("Fill area", Drawer.PRIMARY, _on_fill, "Plant the outline with this")
	_clear_btn = _drawer.add_action("Clear area", Drawer.DESTRUCTIVE, _on_clear,
		"Remove every plant inside this outline")


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
	var area_m2 := float(info.get("area_m2", 0.0))
	_drawer.set_title("Fill %s" % str(info.get("kind_label", "area")), _area_text(area_m2))

	# Re-opening an already-filled area shows what it was filled WITH, so the
	# drawer reads as the area's state rather than a blank form.
	var existing: Dictionary = {}
	if _loader.has_method("area_fill_params"):
		existing = _loader.call("area_fill_params", _area_idx)
	var species := str(existing.get("species", _default_species_for(info)))
	var at := _species_ids.find(species)
	_species_opt.select(at if at >= 0 else 0)
	_density_slider.value = float(existing.get("density", 1.0))
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
	_status_lbl.text = "Planted %s (cleared %d)" % [UiText.count(placed, "plant"), int(res.get("removed", 0))]


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
