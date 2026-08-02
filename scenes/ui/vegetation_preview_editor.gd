extends Control

## Live-preview vegetation tuning modal — studio SubViewport + right sidebar.

signal applied

const MODAL_NAME := "vegetation_preview"
const REBUILD_DEBOUNCE_S := 0.10
const PREVIEW_SEED := 4242
const STUDIO_SUN := Vector3(0.35, 0.88, 0.32)

const SliderSpinRowScript := preload("res://scenes/ui/slider_spin_row.gd")

const SPECIES_IDS: Array[String] = [
	"pine", "deciduous", "shrub", "mix", "grass_lawn", "grass_field",
]
const SPECIES_LABELS: Array[String] = [
	"Pine", "Deciduous", "Shrub", "Mixed woodland", "Lawn grass", "Field grass",
]

## Mixed-woodland composition weights (Type = "Mixed woodland"). Drive both the
## studio preview and, on Apply, any OSM kind bound to "Mixed (local blend)".
const MIX_KEYS: Array[String] = ["mix_pine", "mix_deciduous", "mix_shrub"]
const MIX_LABELS: Array[String] = ["Pine %", "Deciduous %", "Shrub %"]
## Named sub-species toggles added into style["local_mix"] for the mixed blend.
const LOCAL_MIX_CANDIDATES: Array[String] = [
	"spruce", "cedar", "fir", "redwood",
	"maple", "aspen", "birch", "apple",
	"cactus", "joshua_tree",
	"corn", "wheat", "lettuce",
]

const SPECIES_SHAPE_SLIDERS := {
	"deciduous": [
		{"key": "deciduous_canopy_w", "label": "Can W", "min": 4.0, "max": 24.0},
		{"key": "deciduous_canopy_h", "label": "Can H", "min": 2.0, "max": 16.0},
		{"key": "deciduous_trunk_w", "label": "Tr W", "min": 0.2, "max": 2.0},
		{"key": "deciduous_trunk_h", "label": "Tr H", "min": 2.0, "max": 18.0},
		{"key": "deciduous_trunk_taper", "label": "Trunk taper", "min": 0.12, "max": 1.0},
		{"key": "deciduous_bulk_scale", "label": "Bulk×", "min": 0.5, "max": 6.0},
		{"key": "deciduous_growth_years", "label": "Maturity age (yr)", "min": 0.0, "max": 80.0},
		{"key": "deciduous_crown_base", "label": "Crown base", "min": 0.05, "max": 0.9},
		{"key": "deciduous_skeleton_seed", "label": "Variant", "min": 0.0, "max": 9.0},
		{"key": "deciduous_cluster_count", "label": "Clumps", "min": 3.0, "max": 24.0},
		{"key": "deciduous_clump_spread", "label": "Clump spread", "min": 0.6, "max": 1.5},
		{"key": "deciduous_cluster_size", "label": "Clump sz", "min": 0.5, "max": 3.0},
		{"key": "deciduous_branch_count", "label": "Primaries", "min": 2.0, "max": 12.0},
		{"key": "deciduous_branch_tilt_low", "label": "Low limb splay", "min": 15.0, "max": 89.0},
		{"key": "deciduous_branch_tilt_high", "label": "Top limb splay", "min": 5.0, "max": 80.0},
		{"key": "deciduous_branch_lateral", "label": "Skirt fill", "min": 0.0, "max": 1.0},
		{"key": "deciduous_branch_levels", "label": "Twig detail", "min": 1.0, "max": 5.0},
		{"key": "deciduous_branch_split", "label": "Fork limit", "min": 2.0, "max": 4.0},
		{"key": "deciduous_branch_angle", "label": "Spread angle", "min": 8.0, "max": 75.0},
		{"key": "deciduous_branch_length_ratio", "label": "Twig taper", "min": 0.45, "max": 0.92},
		{"key": "deciduous_branch_droop", "label": "Droop/lift", "min": -0.6, "max": 0.6},
		{"key": "deciduous_branch_gnarl", "label": "Gnarl", "min": 0.0, "max": 1.0},
		{"key": "deciduous_branch_thickness", "label": "Limb thickness", "min": 0.05, "max": 2.5},
		{"key": "deciduous_branch_reach", "label": "Reach", "min": 0.4, "max": 1.6},
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
		{"key": "deciduous_billboard_y_offset", "label": "Billboard Y", "min": -2.0, "max": 2.0},
	],
	"pine": [
		{"key": "pine_bulk_scale", "label": "Bulk×", "min": 0.5, "max": 6.0},
		{"key": "pine_growth_years", "label": "Maturity age (yr)", "min": 0.0, "max": 80.0},
		{"key": "pine_card_w", "label": "W", "min": 0.3, "max": 10.0},
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
		{"key": "shrub_growth_years", "label": "Maturity age (yr)", "min": 0.0, "max": 40.0},
		{"key": "shrub_card_w", "label": "W", "min": 0.4, "max": 5.0},
		{"key": "shrub_card_h", "label": "H", "min": 0.4, "max": 5.0},
		{"key": "shrub_cluster_count", "label": "Clumps", "min": 3.0, "max": 10.0},
		{"key": "shrub_cluster_spread", "label": "Spread", "min": 0.4, "max": 1.5},
		{"key": "shrub_cluster_size", "label": "Clump sz", "min": 0.5, "max": 1.5},
		{"key": "shrub_vertical_offset_m", "label": "Raise", "min": -8.0, "max": 8.0},
	],
	"grass_lawn": [
		{"key": "grass_lawn_bulk_scale", "label": "Bulk×", "min": 0.5, "max": 3.0},
		{"key": "grass_lawn_growth_years", "label": "Maturity age (yr)", "min": 0.0, "max": 10.0},
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
		{"key": "grass_field_growth_years", "label": "Maturity age (yr)", "min": 0.0, "max": 10.0},
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

## Hover help per settings key — labels are terse to fit the row, so the
## tooltip carries the actual meaning. Keys without an entry get no tooltip.
const SLIDER_TIPS := {
	"deciduous_canopy_w": "Crown width in metres",
	"deciduous_canopy_h": "Crown height above the trunk in metres",
	"deciduous_trunk_w": "Trunk thickness in metres",
	"deciduous_trunk_h": "Trunk height to the crown top in metres",
	"deciduous_trunk_taper": "How much the trunk narrows toward the top (1 = cylinder)",
	"deciduous_bulk_scale": "Whole-tree size multiplier for PAINTED trees (auto forests use their OSM height)",
	"deciduous_growth_years": "Years a sapling takes to reach full size",
	"deciduous_crown_base": "Where the lowest limb leaves the trunk (0 = ground, 1 = trunk top)",
	"deciduous_skeleton_seed": "Pick one of 10 branch-structure variants — same shape settings, different tree",
	"deciduous_cluster_count": "Number of foliage clumps (more = finer, costlier canopy)",
	"deciduous_clump_spread": "Push foliage clumps outward (>1) or huddle them inward (<1)",
	"deciduous_cluster_size": "Foliage clump size multiplier",
	"deciduous_branch_count": "Primary limbs leaving the trunk",
	"deciduous_branch_tilt_low": "Splay of the LOWEST limbs from vertical (90 = horizontal)",
	"deciduous_branch_tilt_high": "Splay of the TOP limbs from vertical",
	"deciduous_branch_lateral": "Fills the lower crown — high = spreading skirt, low = bare lower limbs",
	"deciduous_branch_levels": "Twig fineness: higher grows more, shorter segments",
	"deciduous_branch_split": "Max forks per branch point",
	"deciduous_branch_angle": "How hard limbs chase open space — low = straight poplar, high = crooked oak",
	"deciduous_branch_length_ratio": "How much twigs shorten toward the crown edge",
	"deciduous_branch_droop": "Limb gravity: negative sags (willow), positive lifts",
	"deciduous_branch_gnarl": "Random kink per branch segment",
	"deciduous_branch_thickness": "Limb chunkiness (tip radius + taper)",
	"deciduous_branch_reach": "Crown envelope size relative to the canopy width",
	"deciduous_vertical_offset_m": "Sink (-) or raise (+) every tree relative to the ground",
	"deciduous_leaf_shell_count": "Foliage shell layers per clump (depth of the canopy volume)",
	"deciduous_leaf_density": "Leaves per clump surface (grid cells per side)",
	"deciduous_leaf_size": "Individual leaf size within its cell",
	"deciduous_leaf_aspect": "Leaf length ÷ width (1 = round, 3 = willow blade)",
	"deciduous_leaf_gap": "Fraction of missing leaves per shell (airier canopy)",
	"deciduous_leaf_lump": "Clump surface bumpiness",
	"deciduous_shadow_proxy_visibility": "Darkness of the cheap whole-crown shadow card",
	"deciduous_lod_near_m": "Distance where full leaf detail ends (painted trees)",
	"deciduous_lod_far_begin_m": "Distance where flat billboards begin (painted trees)",
	"deciduous_billboard_y_offset": "Vertical nudge of the distant billboard canopy",
	"pine_card_w": "Bough width in metres",
	"pine_card_h": "Tree height in metres",
	"pine_trunk_w": "Trunk thickness in metres",
	"pine_whorl_count": "Bough whorls stacked up the trunk",
	"pine_bough_scale": "Bough size multiplier",
	"pine_whorl_spacing": "Vertical spacing curve of the whorls",
	"pine_whorl_jitter": "Random per-whorl wobble",
	"pine_whorl_variation": "Per-whorl colour/shape variation (shader)",
	"pine_trunk_taper": "How much the trunk narrows toward the top",
	"pine_fur_strength": "Needle fuzz intensity near the camera",
	"pine_fur_cells": "Needle fuzz density",
	"pine_fur_tuft_size": "Needle tuft size",
	"pine_fur_gap": "Gaps in the needle fuzz",
	"pine_bulk_scale": "Whole-tree size multiplier for PAINTED pines",
	"pine_growth_years": "Years a sapling takes to reach full size",
	"translucency_strength": "Sunlight glowing through leaves from behind",
	"canopy_roundness": "Fake ambient occlusion rounding of the canopy",
	"color_variation": "Per-tree colour differences across a forest",
	"foliage_roughness": "Leaf surface roughness (lower = glossier)",
	"ao_strength": "Self-shadowing inside the canopy",
	"subsurface_strength": "Soft light scattering through foliage",
	"bark_roughness": "Bark surface roughness",
	"bark_ao_strength": "Shadowing in bark crevices",
	"bark_color_jitter": "Per-tree bark colour variation",
	"wind_strength": "How far foliage sways",
	"wind_speed": "How fast foliage sways",
	"hue_jitter": "Random hue shift per plant",
	"auto_foliage_lod_reach_m": "How far OSM forests keep full leaf detail (higher = prettier drone views, more GPU)",
	"auto_max_tree_instances": "Hard cap on auto-scattered trees for the whole map",
	"auto_detail_radius_m": "Radius around the site centre kept at full tree density",
	"auto_distant_density": "Tree density beyond the detail radius (0 = none)",
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
	# Distance (m) at which OSM-scattered forests drop from leaf/fur to billboards.
	# Global (not previewed in the studio, which is always close-up); affects auto
	# veg only. Higher = leaves persist farther from the drone at more vertex cost.
	{"key": "auto_foliage_lod_reach_m", "label": "Auto foliage reach (m)", "min": 120.0, "max": 500.0},
	{"key": "auto_max_tree_instances", "label": "Max tree instances", "min": 2000.0, "max": 24000.0},
	{"key": "auto_detail_radius_m", "label": "Tree detail radius m", "min": 100.0, "max": 2000.0},
	{"key": "auto_distant_density", "label": "Distant tree density", "min": 0.0, "max": 1.0},
]

var _loader: Node = null
var _dock: Control = null
var _active := false
static var _last_species := "shrub"
var _species := "shrub"
var _density := 1.0
var _patch_diameter := 10.0
var _values: Dictionary = {}
var _baseline: Dictionary = {}
var _tints: Dictionary = {}
## Per-subspecies edits made this session (sid -> {family-flat key: value}).
## Editing a NAMED subspecies (Maple, Birch…) routes here instead of _values so
## Apply writes a per-species override — the old behaviour silently retuned the
## whole family, while the preview (which resolved SPECS variants) showed no
## change at all: the single worst preview-vs-apply gap.
var _species_edits: Dictionary = {}
## Store-backed per-species overrides at open (the loader style's
## _species_overrides side channel). Merged with _species_edits at preview time
## so the studio resolves settings EXACTLY like the map render path.
var _store_species_overrides: Dictionary = {}
## Baseline RESOLVED values per subspecies (diff/revert reference while a named
## subspecies is selected). Computed lazily on first visit, reset on Apply.
var _species_baselines: Dictionary = {}
## Quality-tier veg style overlay from the loader (RenderProfile). The map
## render path merges this wherever the player left a key at defaults
## (_veg_style_with_quality); the preview applies the identical rule.
var _quality_style: Dictionary = {}
var _height_label: Label = null
## Live seasonal uniforms snapshotted per rebuild (see _live_season_uniforms).
var _season_uniforms: Dictionary = {}

var _scroll_container: ScrollContainer
## Player OSM-kind → species override (e.g. {"wood": "pine"}). "auto" = biome.
var _osm_species_map: Dictionary = {}
var _osm_opts: Dictionary = {}
## Named species included in the Mixed woodland local blend (id → weight).
var _local_mix: Dictionary = {}
var _local_mix_checks: Dictionary = {}

var _dim: ColorRect = null
var _panel: PanelContainer = null
var _viewport: SubViewport = null
var _studio: Node3D = null
var _veg_root: Node3D = null
var _camera: Camera3D = null
var _ground: MeshInstance3D = null
var _species_opt: OptionButton = null
var _subspecies_opt: OptionButton = null
var _preset_opt: OptionButton = null
var _preset_name_edit: LineEdit = null
var _species_section: VBoxContainer = null
var _tint_picker: ColorPickerButton = null
## Per-species highlight + bark tints (exact species keys only — a pick on
## Maple never silently restyles the family). Bark rides <family>_bark_tint /
## the species "bark_tint" override; highlight rides <sid>_highlight_tint.
var _hi_tints: Dictionary = {}
var _bark_tints: Dictionary = {}
var _hi_picker: ColorPickerButton = null
var _bark_picker: ColorPickerButton = null
var _bark_lbl: Label = null
var _density_slider: HSlider = null
var _density_spin: SpinBox = null
var _diameter_slider: HSlider = null
var _diameter_spin: SpinBox = null
var _size_var := 0.25
var _size_var_slider: HSlider = null
var _size_var_spin: SpinBox = null
var _shader_sliders: Dictionary = {}
## Forest age profile choices (Phase 9) — id, label.
const FOREST_AGE_OPTIONS: Array = [
	["mature", "Mature stand"],
	["mixed", "Mixed ages"],
	["young", "Young regrowth"],
]
var _forest_age_opt: OptionButton = null
## key -> {pair, label, revert, text} for every slider bound to a `_values` key
## (species shape, mix ratios, advanced shader). Rebuilt with the species
## section, so it is cleared there rather than accumulating freed rows.
var _keyed_sliders: Dictionary = {}
## True once this session has pushed a look to the map: the revert tooltip then
## reads "the last applied value", which is what the baseline actually is.
var _applied_once := false
var _apply_status: Label = null
var _apply_btn: Button = null
var _shader_advanced: VBoxContainer = null
var _rebuild_pending := false
var _rebuild_timer := 0.0
var _cam_yaw: float = PI / 4.0
var _cam_pitch: float = -0.35
var _cam_dist_mult: float = 1.0
var _cam_drag: bool = false
var _cam_last_pos: Vector2


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_build_ui()


func bind_loader(loader: Node, dock: Control = null) -> void:
	_loader = loader
	_dock = dock


func open(initial_preset: int = -1, species_id: String = "") -> void:
	if _active:
		return
	_species = _last_species
	_load_from_loader()
	if initial_preset >= 0:
		_set_species_from_preset(initial_preset)
	if _dock != null and _dock.has_method("get_paint_species"):
		var dock_sp := str(_dock.call("get_paint_species"))
		if VegSpeciesCatalog.is_paintable(dock_sp):
			_species = dock_sp
			_last_species = dock_sp
	# Explicit species id (library "Species: X" rows, veg-area modal) wins over
	# both the preset and the dock's current brush.
	if not species_id.is_empty() and VegSpeciesCatalog.is_paintable(species_id):
		_species = species_id
		_last_species = species_id
	if _dock != null and _dock.has_method("get_size_var"):
		_size_var = float(_dock.call("get_size_var"))
	_sync_species_dropdown()
	_refresh_subspecies_dropdown()
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
	
	if _scroll_container != null:
		_scroll_container.set_deferred("scroll_vertical", 0)
		
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
	vp_container.gui_input.connect(_on_vp_gui_input)
	preview_col.add_child(vp_container)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(640, 480)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp_container.add_child(_viewport)
	_build_studio_world()

	_height_label = Label.new()
	_height_label.add_theme_font_size_override("font_size", 11)
	_height_label.add_theme_color_override("font_color", Color(0.55, 0.62, 0.70))
	_height_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_col.add_child(_height_label)

	# Right: controls
	_scroll_container = ScrollContainer.new()
	_scroll_container.custom_minimum_size = Vector2(360, 520)
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_row.add_child(_scroll_container)

	var sidebar := VBoxContainer.new()
	sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar.add_theme_constant_override("separation", 6)
	_scroll_container.add_child(sidebar)

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

	var sub_row := HBoxContainer.new()
	sidebar.add_child(sub_row)
	var sub_lbl := Label.new()
	_style_section(sub_lbl, "Subsp.")
	sub_lbl.custom_minimum_size = Vector2(44, 0)
	sub_row.add_child(sub_lbl)
	_subspecies_opt = OptionButton.new()
	_subspecies_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_subspecies_opt.item_selected.connect(_on_subspecies_selected)
	sub_row.add_child(_subspecies_opt)

	_build_preset_row(sidebar)

	var dens := _labeled_slider(sidebar, "Density", 0.25, 3.0, _density,
		func(v: float) -> void:
			_density = v
			_queue_rebuild())
	_density_slider = dens.get("slider")
	_density_spin = dens.get("spin")
	var dia := _labeled_slider(sidebar, "Patch Ø m", 4.0, 24.0, _patch_diameter,
		func(v: float) -> void:
			_patch_diameter = v
			_update_ground_and_camera()
			_queue_rebuild())
	_diameter_slider = dia.get("slider")
	_diameter_spin = dia.get("spin")
	var svar := _labeled_slider(sidebar, "Size var %", 0.0, 50.0, _size_var * 100.0,
		func(v: float) -> void:
			_size_var = clampf(v / 100.0, 0.0, 0.5)
			_queue_rebuild(), 1.0)
	_size_var_slider = svar.get("slider")
	_size_var_spin = svar.get("spin")

	_species_section = VBoxContainer.new()
	_species_section.add_theme_constant_override("separation", 4)
	sidebar.add_child(_species_section)

	var tint_row := HBoxContainer.new()
	tint_row.add_theme_constant_override("separation", 6)
	sidebar.add_child(tint_row)
	var tint_lbl := Label.new()
	_style_section(tint_lbl, "Tint")
	tint_lbl.custom_minimum_size = Vector2(44, 0)
	tint_row.add_child(tint_lbl)
	_tint_picker = ColorPickerButton.new()
	_tint_picker.custom_minimum_size = Vector2(52, 24)
	_tint_picker.tooltip_text = "Overall foliage colour for this species"
	_tint_picker.color_changed.connect(_on_tint_changed)
	tint_row.add_child(_tint_picker)
	var hi_lbl := Label.new()
	_style_section(hi_lbl, "Highlight")
	tint_row.add_child(hi_lbl)
	_hi_picker = ColorPickerButton.new()
	_hi_picker.custom_minimum_size = Vector2(52, 24)
	_hi_picker.tooltip_text = "Sun-lit leaf accent colour (maple's orange, olive's silver…)"
	_hi_picker.color_changed.connect(func(c: Color) -> void:
		_hi_tints[_species] = c
		_queue_rebuild())
	tint_row.add_child(_hi_picker)
	_bark_lbl = Label.new()
	_style_section(_bark_lbl, "Bark")
	tint_row.add_child(_bark_lbl)
	_bark_picker = ColorPickerButton.new()
	_bark_picker.custom_minimum_size = Vector2(52, 24)
	_bark_picker.tooltip_text = "Trunk + limb bark colour (birch white, redwood rust…)"
	_bark_picker.color_changed.connect(func(c: Color) -> void:
		_bark_tints[_species] = c
		_queue_rebuild())
	tint_row.add_child(_bark_picker)

	var adv_toggle := CheckButton.new()
	adv_toggle.text = "Advanced shader"
	adv_toggle.button_pressed = false
	adv_toggle.toggled.connect(func(on: bool) -> void:
		if _shader_advanced != null:
			_shader_advanced.visible = on)
	sidebar.add_child(adv_toggle)
	_shader_advanced = VBoxContainer.new()
	_shader_advanced.visible = false
	_shader_advanced.add_theme_constant_override("separation", 4)
	sidebar.add_child(_shader_advanced)
	for spec in SHADER_SLIDERS:
		var sd: Dictionary = spec
		var key := str(sd["key"])
		var sl := _keyed_slider(_shader_advanced, key, str(sd["label"]), float(sd["min"]),
			float(sd["max"]),
			float(_values.get(key, VegetationStyleConfig.defaults().get(key, 0.0))))
		_shader_sliders[key] = sl

	_build_forest_age_section(sidebar)
	_build_osm_section(sidebar)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	sidebar.add_child(btn_row)
	_apply_btn = Button.new()
	_apply_btn.text = "Apply to map"
	_apply_btn.custom_minimum_size = Vector2(104, 30)
	_apply_btn.tooltip_text = "Push this look to the map — the editor stays open so you can keep iterating"
	_apply_btn.pressed.connect(_apply_to_map)
	btn_row.add_child(_apply_btn)
	var brush_btn := Button.new()
	brush_btn.text = "Apply to brush"
	brush_btn.custom_minimum_size = Vector2(108, 30)
	brush_btn.tooltip_text = "Paint the next trees with this look only (map unchanged)"
	brush_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	brush_btn.pressed.connect(_apply_to_brush)
	btn_row.add_child(brush_btn)
	var default_btn := Button.new()
	default_btn.text = "Save as species default"
	default_btn.custom_minimum_size = Vector2(150, 30)
	default_btn.tooltip_text = "Persist this look as the default for this subspecies"
	default_btn.add_theme_stylebox_override("normal", _secondary_btn_style())
	default_btn.pressed.connect(_save_species_default)
	btn_row.add_child(default_btn)
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
	_apply_status = Label.new()
	_apply_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_apply_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_apply_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sidebar.add_child(_apply_status)
	_refresh_apply_state()


func _labeled_slider(parent: Control, label: String, min_v: float, max_v: float,
		start: float, handler: Callable, step: float = -1.0) -> Dictionary:
	return SliderSpinRowScript.add(parent, label, min_v, max_v, start, handler,
		func(lbl: Label, txt: String) -> void: _style_section(lbl, txt),
		72, 120, 64, step)


## A slider bound to a `_values` KEY: same row, plus a per-slider revert button
## and a label that goes amber while the value differs from the baseline.
##
## Phase 8: the modal dumps ~32 sliders per species with no way to tell which
## ones you have actually moved, and "Reset" was all-or-nothing — so a single
## bad experiment cost the whole session's tuning.
func _keyed_slider(parent: Control, key: String, label: String, min_v: float,
		max_v: float, start: float, step: float = -1.0) -> Dictionary:
	var pair := SliderSpinRowScript.add(parent, label, min_v, max_v, start,
		func(v: float) -> void:
			_record_slider_edit(key, v)
			_refresh_slider_diff(key)
			_refresh_apply_state()
			_queue_rebuild(),
		func(lbl: Label, txt: String) -> void: _style_section(lbl, txt),
		72, 108, 60, step)
	var row: HBoxContainer = pair.get("row")
	# Hover help: the terse row label can't explain itself. Labels ignore the
	# mouse by default, so opt the whole row in.
	if SLIDER_TIPS.has(key) and row != null:
		row.tooltip_text = str(SLIDER_TIPS[key])
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		if row.get_child_count() > 0 and row.get_child(0) is Label:
			(row.get_child(0) as Label).mouse_filter = Control.MOUSE_FILTER_STOP
			(row.get_child(0) as Label).tooltip_text = str(SLIDER_TIPS[key])
	var revert := Button.new()
	revert.text = "↺"
	revert.tooltip_text = "Revert this one slider to %s" % (
		"the last applied value" if _applied_once else "the map's current value")
	revert.custom_minimum_size = Vector2(24, 20)
	revert.focus_mode = Control.FOCUS_NONE
	revert.add_theme_font_size_override("font_size", 10)
	revert.pressed.connect(_revert_key.bind(key))
	if row != null:
		row.add_child(revert)
	_keyed_sliders[key] = {
		"pair": pair,
		"label": row.get_child(0) if row != null and row.get_child_count() > 0 else null,
		"revert": revert,
		"text": label,
	}
	_refresh_slider_diff(key)
	return pair


## Family-prefixed edits on a NAMED subspecies scope to that species (Apply
## writes a per-species override); everything else edits the family/global look.
func _record_slider_edit(key: String, v: float) -> void:
	if _is_named_variant() and _family_prefixed(key):
		var d: Dictionary = _species_edits.get(_species, {})
		d[key] = v
		_species_edits[_species] = d
	else:
		_values[key] = v


func _revert_key(key: String) -> void:
	if _is_named_variant() and _family_prefixed(key):
		var edits: Dictionary = _species_edits.get(_species, {})
		edits.erase(key)
		var base: Dictionary = _species_baselines.get(_species, {})
		var entry_s: Dictionary = _keyed_sliders.get(key, {})
		if not entry_s.is_empty() and base.has(key):
			SliderSpinRowScript.set_values(entry_s.get("pair", {}), float(base[key]))
		_refresh_slider_diff(key)
		_refresh_apply_state()
		_queue_rebuild(true)
		return
	if not _baseline.has(key):
		return
	_values[key] = _baseline[key]
	var entry: Dictionary = _keyed_sliders.get(key, {})
	if not entry.is_empty():
		SliderSpinRowScript.set_values(entry.get("pair", {}), float(_baseline[key]))
	_refresh_slider_diff(key)
	_refresh_apply_state()
	_queue_rebuild(true)


## Amber label + a live revert button while this key differs from the baseline.
func _refresh_slider_diff(key: String) -> void:
	var entry: Dictionary = _keyed_sliders.get(key, {})
	if entry.is_empty():
		return
	var changed := _key_differs(key)
	var lbl: Label = entry.get("label")
	if lbl != null:
		lbl.add_theme_color_override("font_color",
			UITheme.C_AMBER if changed else UITheme.C_TEXT_S)
		lbl.text = ("• " + str(entry.get("text", ""))) if changed else str(entry.get("text", ""))
	var revert: Button = entry.get("revert")
	if revert != null:
		revert.disabled = not changed
		revert.modulate = Color(1, 1, 1, 1.0 if changed else 0.35)


func _key_differs(key: String) -> bool:
	if _is_named_variant() and _family_prefixed(key):
		var edits: Dictionary = _species_edits.get(_species, {})
		if not edits.has(key):
			return false
		var base: Dictionary = _species_baselines.get(_species, {})
		if not base.has(key):
			return true
		return absf(float(edits[key]) - float(base[key])) > 1.0e-4
	if not _baseline.has(key) or not _values.has(key):
		return false
	var a: Variant = _values[key]
	var b: Variant = _baseline[key]
	if a is float or a is int:
		return absf(float(a) - float(b)) > 1.0e-4
	return a != b


func _refresh_all_slider_diffs() -> void:
	for key in _keyed_sliders.keys():
		_refresh_slider_diff(str(key))


## How many keys the player has moved since the last apply — drives the
## Apply button's affordance so "did that take?" is answerable at a glance.
func pending_change_count() -> int:
	var n := 0
	for key in _keyed_sliders.keys():
		if _key_differs(str(key)):
			n += 1
	return n


func _shape_family() -> String:
	if _species == "mix":
		return "mix"
	return VegSpeciesCatalog.mesh_family(_species)


func _rebuild_species_section() -> void:
	if _species_section == null:
		return
	for child in _species_section.get_children():
		# The rows own the keyed-slider entries; drop them together or the diff
		# refresh walks freed Labels.
		child.queue_free()
	for key in _keyed_sliders.keys():
		if not _shader_sliders.has(key):
			_keyed_sliders.erase(key)
	if _species == "mix":
		_build_mix_section()
		return
	var fam := _shape_family()
	var specs: Array = SPECIES_SHAPE_SLIDERS.get(fam, [])
	if specs.is_empty():
		return
	var hdr := Label.new()
	_style_section(hdr, VegSpeciesCatalog.label_for(_species))
	_species_section.add_child(hdr)
	if _is_named_variant():
		_ensure_species_baseline()
		var scope_hint := Label.new()
		scope_hint.text = "Edits apply to %s only (pick the family type to restyle all)" \
			% VegSpeciesCatalog.label_for(_species)
		scope_hint.add_theme_font_size_override("font_size", 9)
		scope_hint.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
		scope_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_species_section.add_child(scope_hint)
	# Sliders display the RESOLVED value for the active species — selecting
	# Birch shows Birch's real dims (SPECS variant / species override), not the
	# family numbers it doesn't render with.
	var resolved := _resolved_active()
	var session_edits: Dictionary = _species_edits.get(_species, {})
	# Grouped, not a flat dump: a deciduous tree has ~32 shape sliders and
	# finding "leaf size" among them meant reading every label. Sections are
	# derived from the key so a new slider files itself.
	var grouped := {}
	for spec in specs:
		var sd: Dictionary = spec
		var sect := slider_section(str(sd["key"]))
		if not grouped.has(sect):
			grouped[sect] = []
		(grouped[sect] as Array).append(sd)
	for sect in SECTION_ORDER:
		if not grouped.has(sect):
			continue
		var body := _add_collapsible_section(_species_section, str(sect))
		for spec2 in grouped[sect]:
			var sd2: Dictionary = spec2
			var key := str(sd2["key"])
			var start := float(resolved.get(key, _values.get(key, 0.0)))
			if _is_named_variant() and session_edits.has(key):
				start = float(session_edits[key])
			_keyed_slider(body, key, str(sd2["label"]), float(sd2["min"]),
				float(sd2["max"]), start)


## Mixed-woodland ratio sliders. Per-species SHAPE (canopy size, etc.) is edited
## on each species' own Type page; here the player tunes only the blend.
func _build_mix_section() -> void:
	var hdr := Label.new()
	_style_section(hdr, "Mixed woodland blend")
	_species_section.add_child(hdr)
	for i in MIX_KEYS.size():
		var key := MIX_KEYS[i]
		_keyed_slider(_species_section, key, MIX_LABELS[i], 0.0, 1.0,
			float(_values.get(key, 0.0)))
	var local_hdr := Label.new()
	_style_section(local_hdr, "Local-mix species")
	_species_section.add_child(local_hdr)
	var local_hint := Label.new()
	local_hint.text = "Include named sub-types / crops in the mixed blend."
	local_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	local_hint.add_theme_font_size_override("font_size", 10)
	local_hint.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	_species_section.add_child(local_hint)
	_local_mix_checks.clear()
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 2)
	_species_section.add_child(grid)
	for sid in LOCAL_MIX_CANDIDATES:
		var cb := CheckBox.new()
		cb.text = VegSpeciesCatalog.label_for(sid)
		cb.button_pressed = float(_local_mix.get(sid, 0.0)) > 0.0
		var captured := sid
		cb.toggled.connect(func(on: bool) -> void:
			if on:
				_local_mix[captured] = 1.0
			else:
				_local_mix.erase(captured)
			_queue_rebuild())
		grid.add_child(cb)
		_local_mix_checks[sid] = cb
	var hint := Label.new()
	hint.text = "Edit each tree's shape on its own Type page."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	_species_section.add_child(hint)


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


## Shape sliders + tint for the current subspecies — the unit a preset captures.
## Uses the RESOLVED values (what the active species actually renders with),
## not the family numbers, so a Birch preset saves Birch.
func _species_preset_values() -> Dictionary:
	var out := {}
	var resolved := _resolved_active()
	var session_edits: Dictionary = _species_edits.get(_species, {})
	for spec in SPECIES_SHAPE_SLIDERS.get(_shape_family(), []):
		var key := str((spec as Dictionary)["key"])
		if session_edits.has(key):
			out[key] = session_edits[key]
		elif resolved.has(key):
			out[key] = resolved[key]
		elif _values.has(key):
			out[key] = _values[key]
	out["%s_albedo_tint" % _species] = _tints.get(_species,
		_tints.get(_shape_family(), Color.WHITE))
	return out


func _apply_preset_values(values: Dictionary) -> void:
	for k in values:
		var ks := str(k)
		if ks.ends_with("_albedo_tint"):
			var sid := ks.trim_suffix("_albedo_tint")
			_tints[sid] = values[k]
			if sid == _species or sid == _shape_family():
				_tints[_species] = values[k]
		else:
			_values[k] = values[k]
	_rebuild_species_section()
	_sync_tint_picker()
	_sync_top_sliders()
	_queue_rebuild(true)


func _save_species_default() -> void:
	if _species == "mix" or _species.is_empty():
		return
	VegetationStyleConfig.save_species_default(_species, _species_preset_values())
	if _preset_name_edit != null:
		_preset_name_edit.placeholder_text = "Saved %s default" % VegSpeciesCatalog.label_for(_species)


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

## Slider sections, in the order they are shown. "Size & form" first because it
## is what a player reaches for; "Detail & LOD" last and collapsed because it is
## tuning, not design.
const SECTION_SIZE := "Size & form"
const SECTION_BRANCHES := "Branches & clumps"
const SECTION_FOLIAGE := "Foliage"
const SECTION_GROWTH := "Growth"
const SECTION_DETAIL := "Detail & LOD"
const SECTION_ORDER: Array = [SECTION_SIZE, SECTION_BRANCHES, SECTION_FOLIAGE,
	SECTION_GROWTH, SECTION_DETAIL]
## Sections that start collapsed (per session; the toggle state is remembered in
## _section_open while the modal lives).
const SECTIONS_COLLAPSED_BY_DEFAULT: Array = [SECTION_DETAIL]

var _section_open: Dictionary = {}


## Which section a shape-slider key belongs to. Derived from the key so adding a
## slider to SPECIES_SHAPE_SLIDERS files it automatically — a per-entry
## "section" field on ~90 specs would drift the first time someone forgot one.
static func slider_section(key: String) -> String:
	if key.ends_with("_growth_years") or key.ends_with("_senescence_years"):
		return SECTION_GROWTH
	for frag in ["_lod_", "billboard", "shadow_proxy"]:
		if frag in key:
			return SECTION_DETAIL
	for frag in ["_leaf", "_fur", "_whorl", "_bough", "cells_per_side", "blade",
			"hue_jitter"]:
		if frag in key:
			return SECTION_FOLIAGE
	for frag in ["_branch", "_cluster", "_clump", "crown_base"]:
		if frag in key:
			return SECTION_BRANCHES
	return SECTION_SIZE


## Header button + body container. The header shows a caret and toggles the body.
func _add_collapsible_section(parent: Control, title: String) -> VBoxContainer:
	var open := bool(_section_open.get(title,
		not SECTIONS_COLLAPSED_BY_DEFAULT.has(title)))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 2)
	var head := Button.new()
	head.toggle_mode = true
	head.button_pressed = open
	head.focus_mode = Control.FOCUS_NONE
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	head.text = ("▾ " if open else "▸ ") + title
	head.toggled.connect(func(on: bool) -> void:
		_section_open[title] = on
		body.visible = on
		head.text = ("▾ " if on else "▸ ") + title)
	parent.add_child(head)
	parent.add_child(body)
	body.visible = open
	return body


## Forest age profile (veg overhaul Phase 9). The maturity-age sliders above say
## how LONG a plant takes to grow; this says where in that span a freshly seeded
## stand starts — the difference between dropping a mature forest and dropping a
## clear-cut that grows back while you watch.
func _build_forest_age_section(sidebar: VBoxContainer) -> void:
	var hdr := Label.new()
	_style_section(hdr, "Forest age")
	sidebar.add_child(hdr)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	sidebar.add_child(row)
	_forest_age_opt = OptionButton.new()
	_forest_age_opt.custom_minimum_size.x = 150.0
	for spec in FOREST_AGE_OPTIONS:
		_forest_age_opt.add_item(str(spec[1]))
		_forest_age_opt.set_item_metadata(_forest_age_opt.item_count - 1, str(spec[0]))
	_forest_age_opt.item_selected.connect(_on_forest_age_selected)
	row.add_child(_forest_age_opt)
	var hint := Label.new()
	hint.text = "Applies on the next reseed"
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(hint)
	_sync_forest_age_opt()


func _sync_forest_age_opt() -> void:
	if _forest_age_opt == null:
		return
	var cur := str(_values.get("forest_age", VegetationGrowth.FOREST_AGE_MATURE))
	for i in _forest_age_opt.item_count:
		if str(_forest_age_opt.get_item_metadata(i)) == cur:
			_forest_age_opt.select(i)
			return
	_forest_age_opt.select(0)


func _on_forest_age_selected(idx: int) -> void:
	if _forest_age_opt == null:
		return
	_values["forest_age"] = str(_forest_age_opt.get_item_metadata(idx))
	_refresh_apply_state()


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
		var opts := BiomePalette.override_options()
		var labels := BiomePalette.override_labels()
		for i in opts.size():
			opt.add_item(str(labels[i]), i)
		opt.item_selected.connect(func(idx: int) -> void:
			_osm_species_map[kind] = str(BiomePalette.override_options()[idx]))
		row.add_child(opt)
		_osm_opts[kind] = opt


func _sync_osm_opts() -> void:
	for kind in _osm_opts:
		var opt := _osm_opts[kind] as OptionButton
		if opt == null:
			continue
		var choice := str(_osm_species_map.get(kind, "auto"))
		var idx := BiomePalette.override_options().find(choice)
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
	var dist := _patch_diameter * 1.2 * _cam_dist_mult
	var target := Vector3(0.0, _patch_diameter * 0.12, 0.0)
	var dir := Vector3(cos(_cam_yaw) * cos(_cam_pitch), sin(_cam_pitch), sin(_cam_yaw) * cos(_cam_pitch))
	_camera.position = target - dir * dist
	_camera.look_at(target)

func _on_vp_gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var emb = ev as InputEventMouseButton
		if emb.button_index == MOUSE_BUTTON_LEFT or emb.button_index == MOUSE_BUTTON_MIDDLE or emb.button_index == MOUSE_BUTTON_RIGHT:
			if emb.pressed:
				_cam_drag = true
				_cam_last_pos = emb.position
			else:
				_cam_drag = false
		elif emb.button_index == MOUSE_BUTTON_WHEEL_UP and emb.pressed:
			_cam_dist_mult = clampf(_cam_dist_mult * 0.85, 0.1, 5.0)
			_update_ground_and_camera()
		elif emb.button_index == MOUSE_BUTTON_WHEEL_DOWN and emb.pressed:
			_cam_dist_mult = clampf(_cam_dist_mult * 1.15, 0.1, 5.0)
			_update_ground_and_camera()
	elif ev is InputEventMouseMotion and _cam_drag:
		var emm = ev as InputEventMouseMotion
		var d = emm.position - _cam_last_pos
		_cam_last_pos = emm.position
		_cam_yaw -= d.x * 0.01
		_cam_pitch += d.y * 0.01
		_cam_pitch = clampf(_cam_pitch, -PI/2.0 + 0.1, PI/2.0 - 0.1)
		_update_ground_and_camera()


# ---------------------------------------------------------------------------
# Preview scatter + rebuild
# ---------------------------------------------------------------------------

## The flat settings dict the RENDER path would see after Apply: user family
## keys diffed against defaults (exactly what the stores persist), per-species
## overrides (stored + this session's subspecies edits), and the quality-tier
## overlay under the same only-fills-defaults rule as _veg_style_with_quality.
## This single source is what makes the preview WYSIWYG — it used to drop the
## VegStyleStore side channels entirely, so subspecies resolved differently in
## the studio than on the map.
func _merged_settings() -> Dictionary:
	var out := _values.duplicate(true)
	var defaults: Dictionary = VegetationStyleConfig.defaults()
	# User family keys BEFORE the tier overlay (tier values are not user edits).
	var fam_keys: Array = []
	for k in out:
		var ks := str(k)
		if ks.begins_with("_"):
			continue
		if str(VegStyleStore.split_flat_key(ks)[0]).is_empty():
			continue
		if not defaults.has(ks) or not VegStyleStore.values_equal(out[ks], defaults[ks]):
			fam_keys.append(ks)
	fam_keys.sort()
	for k in _quality_style:
		if not out.has(k):
			out[k] = _quality_style[k]
		elif defaults.has(k) and VegStyleStore.values_equal(out[k], defaults[k]):
			out[k] = _quality_style[k]
	out[VegStyleStore.KEY_USER_FAMILY] = fam_keys
	out[VegStyleStore.KEY_SPECIES_OVERRIDES] = _overrides_with_edits()
	var fam := _shape_family()
	var tint: Color = _tints.get(_species, _tints.get(fam, Color.WHITE))
	out["%s_albedo_tint" % _species] = tint
	if fam != _species and fam != "mix":
		out["%s_albedo_tint" % fam] = tint
	var hi: Variant = _hi_tints.get(_species)
	if hi is Color:
		out["%s_highlight_tint" % _species] = hi
		if fam != _species and fam != "mix":
			out["%s_highlight_tint" % fam] = hi
	elif _hi_tints.get(fam) is Color and fam != "mix":
		out["%s_highlight_tint" % fam] = _hi_tints[fam]
	var bark: Variant = _bark_tints.get(_species)
	if not (bark is Color) and fam != "mix":
		bark = _bark_tints.get(fam)
		if bark is Color:
			out["%s_bark_tint" % fam] = bark
			bark = null
	if bark is Color:
		if _is_named_variant():
			# Species-scoped: ride the override channel as the unprefixed
			# "bark_tint" key, exactly how Apply persists it.
			var ov: Dictionary = out[VegStyleStore.KEY_SPECIES_OVERRIDES]
			var d: Dictionary = ov.get(_species, {}) if ov.get(_species) is Dictionary else {}
			d["bark_tint"] = bark
			ov[_species] = d
		else:
			out["%s_bark_tint" % fam] = bark
	out["use_drape"] = false
	return out


## Stored per-species overrides + this session's not-yet-applied subspecies
## edits, in the unprefixed form settings_with_variant consumes.
func _overrides_with_edits() -> Dictionary:
	var out := _store_species_overrides.duplicate(true)
	for sid in _species_edits:
		var fam := VegSpeciesCatalog.mesh_family(str(sid))
		var cur: Dictionary = out.get(sid, {}) if out.get(sid) is Dictionary else {}
		var edits: Dictionary = _species_edits[sid]
		for k in edits:
			var key := str(k)
			var unpref := key.substr(fam.length() + 1) if key.begins_with(fam + "_") else key
			cur[unpref] = edits[k]
		out[sid] = cur
	return out


## True while the active selection is a NAMED subspecies (Maple, Spruce…) rather
## than the generic family — the case where edits scope per-species.
func _is_named_variant() -> bool:
	return _species != "mix" and _species != _shape_family()


func _family_prefixed(key: String) -> bool:
	return key.begins_with(_shape_family() + "_")


## The fully resolved flat dict for the ACTIVE species — what its mesh builder
## sees. Sliders display these values, so selecting Birch shows Birch's real
## dims instead of the family numbers it doesn't use.
func _resolved_active() -> Dictionary:
	if _species == "mix":
		return _values
	return VegSpeciesCatalog.settings_with_variant(_species, _merged_settings(),
		VegetationCardFactory.SPECS)


## Snapshot the resolved per-species state before any session edits — the
## reference the per-slider diff/revert compares against for a named variant.
func _ensure_species_baseline() -> void:
	if _species == "mix" or _species_baselines.has(_species):
		return
	var stash: Variant = _species_edits.get(_species)
	_species_edits.erase(_species)
	_species_baselines[_species] = VegSpeciesCatalog.settings_with_variant(
		_species, _merged_settings(), VegetationCardFactory.SPECS)
	if stash is Dictionary:
		_species_edits[_species] = stash


func _apply_studio(mat: ShaderMaterial, species: String = "") -> void:
	if mat == null:
		return
	mat.set_shader_parameter("use_drape", false)
	mat.set_shader_parameter("sun_direction", STUDIO_SUN)
	mat.set_shader_parameter("night_factor", 0.0)
	mat.set_shader_parameter("haze_strength", 0.12)
	mat.set_shader_parameter("drape_match_strength", 0.0)
	# WYSIWYG seasonal state: on the map VegetationEnvironmentSync continuously
	# drives these from the live clock (autumn tint, leaf drop, snow, spring bud).
	# The studio is an isolated viewport with no env-sync, so without this it would
	# always show a peak-summer full-green tree — which is why a tree tuned here
	# looked nothing like the same tree placed under the map's current season.
	# Fixed daylight (night_factor 0, STUDIO_SUN) is kept so the tuned look stays
	# lit regardless of the in-world time of day.
	mat.set_shader_parameter("autumn", float(_season_uniforms.get("autumn", 0.0)))
	mat.set_shader_parameter("leaf_coverage", float(_season_uniforms.get("leaf_coverage", 1.0)))
	mat.set_shader_parameter("spring_bud", float(_season_uniforms.get("spring_bud", 0.0)))
	mat.set_shader_parameter("winter", float(_season_uniforms.get("winter", 0.0)))
	mat.set_shader_parameter("summer", float(_season_uniforms.get("summer", 1.0)))
	mat.set_shader_parameter("snow_amount", float(_season_uniforms.get("snow_amount", 0.0)))
	mat.set_shader_parameter("snow_depth_m", float(_season_uniforms.get("snow_depth_m", 0.0)))
	# Grass shader reads seasonal growth as "growth".
	mat.set_shader_parameter("growth", float(_season_uniforms.get("grass_growth", 1.0)))
	if not species.is_empty():
		mat.set_shader_parameter("deciduousness", _deciduousness_for(species))


## Mirrors VegetationEnvironmentSync._deciduousness_for so deciduous canopies shed
## in autumn/winter in the preview exactly as they do on the map.
func _deciduousness_for(species: String) -> float:
	var s := species.to_lower()
	if s.begins_with("pine") or s == "conifer" or s == "taiga":
		return 0.0
	if s.begins_with("deciduous") or s == "broadleaf" or s == "palm":
		return 1.0
	if s.begins_with("shrub"):
		return 0.55
	if s.begins_with("grass"):
		return 0.0
	return 0.8


## Live seasonal/snow signals from the running map (group "main_scene"), matching
## the uniforms VegetationEnvironmentSync pushes. Peak-summer defaults when no map
## is running yet (e.g. the modal opened before a location loads).
func _live_season_uniforms() -> Dictionary:
	var out := {
		"autumn": 0.0, "leaf_coverage": 1.0, "spring_bud": 0.0,
		"winter": 0.0, "summer": 1.0, "snow_amount": 0.0, "snow_depth_m": 0.0,
		"grass_growth": 1.0,
	}
	if not is_inside_tree():
		return out
	var main := get_tree().get_first_node_in_group("main_scene")
	if main == null:
		return out
	if main.has_method("get_season_signals"):
		var s: Dictionary = main.call("get_season_signals")
		out["autumn"] = float(s.get("autumn", 0.0))
		out["leaf_coverage"] = float(s.get("leaf_coverage", 1.0))
		out["spring_bud"] = float(s.get("bud", 0.0))
		out["winter"] = float(s.get("winter", 0.0))
		out["summer"] = float(s.get("summer", 1.0))
		out["grass_growth"] = float(s.get("grass_growth", 1.0))
	if main.has_method("get_snow_amount"):
		out["snow_amount"] = clampf(float(main.call("get_snow_amount")), 0.0, 1.0)
	if main.has_method("get_snow_depth_m"):
		out["snow_depth_m"] = float(main.call("get_snow_depth_m"))
	return out


func _base_spacing() -> float:
	match _shape_family():
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
		"mix":
			return 6.5
		_:
			return 4.0


func _effective_spacing() -> float:
	return maxf(0.35, _base_spacing() / maxf(_density, 0.25))


func _scatter_spots() -> Array:
	var radius := _patch_diameter * 0.5
	var poly := VegetationPaint.circle_polygon(Vector2.ZERO, radius, 28)
	var rng := RandomNumberGenerator.new()
	rng.seed = PREVIEW_SEED
	var fam := _shape_family()
	var max_count := 500 if fam.begins_with("grass_") else 64
	var spots := VegetationPaint.poisson_fill(poly, _effective_spacing(), rng, [], max_count)
	var scales := VegetationStyleConfig.scales_from_size_var(_size_var)
	for item in spots:
		if item is Dictionary:
			(item as Dictionary)["scale"] = lerpf(scales.x, scales.y, rng.randf())
	return spots


func _rebuild_preview() -> void:
	if _veg_root == null:
		return
	for child in _veg_root.get_children():
		child.queue_free()
	if _height_label != null:
		_height_label.text = ""
	_season_uniforms = _live_season_uniforms()
	var settings := _merged_settings()
	var spots: Array = _scatter_spots()
	if spots.is_empty():
		return
	var fam := _shape_family()
	if fam in VegetationLayer.GRASS_SPECIES:
		_build_grass_preview(spots, settings)
	elif _species == "mix":
		_build_mix_preview(spots, settings)
	else:
		_build_species_cards(_species, spots, settings)


## Studio preview of a mixed woodland: each spot is assigned by mix ratio +
## local-mix named species, then drawn as one MultiMesh per constituent.
func _build_mix_preview(spots: Array, settings: Dictionary) -> void:
	var weights := _mix_weight_dict()
	if weights.is_empty():
		weights = {"pine": 0.5, "deciduous": 0.5}
	var rng := RandomNumberGenerator.new()
	rng.seed = PREVIEW_SEED + 17
	var by_species: Dictionary = {}
	for item in spots:
		if not (item is Dictionary):
			continue
		var sp := BiomePalette.pick_species(weights, rng)
		if not by_species.has(sp):
			by_species[sp] = []
		(by_species[sp] as Array).append(item)
	for sp in by_species:
		if not (by_species[sp] as Array).is_empty():
			_build_species_cards(str(sp), by_species[sp], settings)


func _build_card_preview(spots: Array, settings: Dictionary) -> void:
	_build_species_cards(_species, spots, settings)


func _build_species_cards(species: String, spots: Array, settings: Dictionary) -> void:
	VegetationCardFactory.clear_foot_cache()
	var mesh: ArrayMesh
	if VegetationCardFactory.canopy_lod_enabled(species, settings):
		mesh = VegetationCardFactory.mesh_for_canopy_lod(species, settings, VegetationCardFactory.CanopyLodTier.NEAR)
	else:
		mesh = VegetationCardFactory.mesh_for_species(species, settings)
	
	var use_surface := VegetationCardFactory.mesh_has_surface_materials(species)
	var mat: ShaderMaterial = null
	if not use_surface:
		mat = VegetationCardFactory.material_for_species(species, settings)
		_apply_studio(mat, species)
	else:
		for surf_i in mesh.get_surface_count():
			var sm := mesh.surface_get_material(surf_i) as ShaderMaterial
			_apply_studio(sm, species)
	var species_scale := VegetationCardFactory.species_bulk_scale(species, settings)
	var foot_y := VegetationCardFactory.foot_local_y(species, settings)
	var family := VegetationCardFactory.mesh_family(species)
	var vert_off := VegetationLayer.vertical_offset_for(family, settings)
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
	mi.name = "PreviewBulk_%s" % species
	mi.multimesh = mm
	if not use_surface:
		mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_veg_root.add_child(mi)
	# Height gauge for the ACTIVE species: painted trees render at exactly this
	# size; auto-scattered forests scale every tree to its own OSM/species
	# target height instead — the honest explanation for why the two differ.
	if species == _species and _height_label != null and mesh != null:
		var h := mesh.get_aabb().size.y * species_scale
		_height_label.text = ("Painted %s ≈ %.1f m tall · auto forests scale each " +
			"tree to its OSM/species height") % [VegSpeciesCatalog.label_for(species), h]


## Current mix ratios as a species-weight dict (drops zero weights).
func _mix_weight_dict() -> Dictionary:
	var style := {"local_mix": _local_mix.duplicate(true)}
	for i in MIX_KEYS.size():
		style[MIX_KEYS[i]] = float(_values.get(MIX_KEYS[i], 0.0))
	return BiomePalette.mix_weights_from_style(style)


func _build_grass_preview(spots: Array, settings: Dictionary) -> void:
	var fam := _shape_family()
	var mesh := GrassBuilder.mesh_for_lod(fam, settings, GrassBuilder.LodTier.NEAR)
	var mat := GrassBuilder.material_for_species(_species, settings, GrassBuilder.LodTier.NEAR)
	_apply_studio(mat, _species)
	var species_scale := GrassBuilder.bulk_scale(fam, settings)
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
	var shape := {}
	var style := VegetationStyleConfig.defaults()
	if _loader != null:
		if _loader.has_method("get_vegetation_settings"):
			shape = _loader.call("get_vegetation_settings")
		if _loader.has_method("get_vegetation_style"):
			style = _loader.call("get_vegetation_style")
	# Precedence MUST match the render path (Phase 2): the style store is the
	# authority and the layer contributes only SPARSE user deltas
	# (user_settings()), merged on top. get_vegetation_settings() returns
	# exactly those deltas now — an empty dict on an untouched map.
	_values = {}
	for k in style:
		if k.ends_with("_albedo_tint") or k.ends_with("_highlight_tint"):
			continue
		if typeof(style[k]) in [TYPE_FLOAT, TYPE_INT, TYPE_BOOL]:
			_values[k] = style[k]
	for k in shape:
		_values[k] = shape[k]
	# WYSIWYG side channels: per-species overrides ride the style dict as
	# VegStyleStore's _species_overrides (a Dictionary, so the typed copy above
	# skipped it — and with it, every subspecies resolved differently in the
	# studio than on the map). The quality-tier overlay lives on the loader.
	_store_species_overrides = {}
	var raw_over: Variant = style.get(VegStyleStore.KEY_SPECIES_OVERRIDES, {})
	if raw_over is Dictionary:
		_store_species_overrides = (raw_over as Dictionary).duplicate(true)
	_quality_style = {}
	if _loader != null and _loader.has_method("veg_quality_tier_style"):
		_quality_style = _loader.call("veg_quality_tier_style")
	_species_edits = {}
	_species_baselines = {}
	# Seed highlight/bark from the map's stored FAMILY-level colours: they are
	# Colors, so the typed float copy above drops them, and without seeding the
	# preview would render family defaults while the map keeps the stored look
	# (species-level entries need no seeding — they resolve through the
	# override side channel). Session picks then overwrite these entries.
	_hi_tints = {}
	_bark_tints = {}
	for k in style:
		var ks := str(k)
		if ks.ends_with("_highlight_tint") and style[k] is Color:
			var sid := ks.trim_suffix("_highlight_tint")
			if sid in VegSpeciesCatalog.BASE_FAMILIES:
				_hi_tints[sid] = style[k]
		elif ks.ends_with("_bark_tint") and style[k] is Color:
			var sidb := ks.trim_suffix("_bark_tint")
			if sidb in VegSpeciesCatalog.BASE_FAMILIES:
				_bark_tints[sidb] = style[k]
	_tints = {
		"pine": style.get("pine_albedo_tint", Color.WHITE),
		"deciduous": style.get("deciduous_albedo_tint", Color.WHITE),
		"shrub": style.get("shrub_albedo_tint", Color.WHITE),
		# "mix" has no tint of its own — its trees use their own species tints;
		# present only so the SPECIES_IDS-keyed baseline/apply loops don't miss it.
		"mix": Color.WHITE,
		"grass_lawn": style.get("grass_lawn_albedo_tint", Color.WHITE),
		"grass_field": style.get("grass_field_albedo_tint", Color.WHITE),
	}
	for sid in VegSpeciesCatalog.all_selectable_ids():
		var tk := "%s_albedo_tint" % sid
		if style.has(tk):
			_tints[sid] = style[tk]
		var saved := VegetationStyleConfig.load_species_default(sid)
		if saved.has(tk):
			_tints[sid] = saved[tk]
		for k in saved:
			if not str(k).ends_with("_albedo_tint") and not str(k).ends_with("_highlight_tint"):
				if typeof(saved[k]) in [TYPE_FLOAT, TYPE_INT, TYPE_BOOL] and not _values.has(k):
					_values[k] = saved[k]
	var raw_map: Dictionary = style.get("osm_species_map", {})
	_osm_species_map = {}
	for k in raw_map:
		_osm_species_map[str(k)] = str(raw_map[k])
	_local_mix = {}
	var raw_local: Variant = style.get("local_mix", {})
	if raw_local is Dictionary:
		for k in raw_local:
			var w := maxf(float(raw_local[k]), 0.0)
			if w > 0.0:
				_local_mix[str(k)] = w
	_baseline = _values.duplicate(true)
	for species in SPECIES_IDS:
		_baseline["%s_albedo_tint" % species] = _tints[species]
	_baseline["osm_species_map"] = _osm_species_map.duplicate(true)
	_baseline["local_mix"] = _local_mix.duplicate(true)
	# Density slider drives the auto-forest density (auto_density_scale) and the
	# brush; reflect the map's stored value so it matches what's on the ground.
	if style.has("auto_density_scale"):
		_density = clampf(float(style.get("auto_density_scale", 1.0)), 0.25, 3.0)
	elif _dock != null and _dock.has_method("get_paint_density"):
		_density = float(_dock.call("get_paint_density"))


func _sync_top_sliders() -> void:
	SliderSpinRowScript.set_values({"slider": _density_slider, "spin": _density_spin}, _density)
	SliderSpinRowScript.set_values({"slider": _diameter_slider, "spin": _diameter_spin}, _patch_diameter)
	if _size_var_slider != null:
		SliderSpinRowScript.set_values({"slider": _size_var_slider, "spin": _size_var_spin}, _size_var * 100.0)
	for key in _shader_sliders:
		if _values.has(key):
			SliderSpinRowScript.set_values(_shader_sliders[key], float(_values[key]))


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
	# Persist the active subspecies tint so paint/rebuild can prefer it.
	if _species != "mix" and not _species.is_empty():
		out["%s_albedo_tint" % _species] = _tints.get(_species,
			_tints.get(_shape_family(), Color.WHITE))
	# Highlight tints: the store routes named-subspecies keys to the species
	# layer and family keys to the family layer on its own.
	for sid in _hi_tints:
		out["%s_highlight_tint" % sid] = _hi_tints[sid]
	# Bark: family-level entries only — named-subspecies bark is persisted as a
	# species override in _apply_to_map.
	for sid in _bark_tints:
		if str(sid) == VegSpeciesCatalog.mesh_family(str(sid)):
			out["%s_bark_tint" % sid] = _bark_tints[sid]
	out["osm_species_map"] = _osm_species_map.duplicate(true)
	out["local_mix"] = _local_mix.duplicate(true)
	for key in MIX_KEYS:
		if _values.has(key):
			out[key] = _values[key]
	# Density drives the auto (OSM) forest scatter density on Apply to map.
	out["auto_density_scale"] = _density
	out["forest_age"] = str(_values.get("forest_age", VegetationGrowth.FOREST_AGE_MATURE))
	return out


## Full per-instance look snapshot (shape + shader + tint) for "Apply to brush":
## stamped as card_settings onto trees the player paints next, so they keep this
## look independent of later "Apply to map" changes.
func _brush_card() -> Dictionary:
	var out := _shape_dict()
	# A named subspecies paints with ITS resolved look, not the family's.
	if _is_named_variant():
		var resolved := _resolved_active()
		for spec in SPECIES_SHAPE_SLIDERS.get(_shape_family(), []):
			var key := str((spec as Dictionary)["key"])
			if resolved.has(key):
				out[key] = resolved[key]
	for sid in _hi_tints:
		out["%s_highlight_tint" % sid] = _hi_tints[sid]
	var brush_bark: Variant = _bark_tints.get(_species, _bark_tints.get(_shape_family()))
	if brush_bark is Color:
		out["%s_bark_tint" % _shape_family()] = brush_bark
	for spec in SHADER_SLIDERS:
		var key := str((spec as Dictionary)["key"])
		if _values.has(key):
			out[key] = _values[key]
	for species in SPECIES_IDS:
		out["%s_albedo_tint" % species] = _tints.get(species, Color.WHITE)
	if _species != "mix" and not _species.is_empty():
		out["%s_albedo_tint" % _species] = _tints.get(_species,
			_tints.get(_shape_family(), Color.WHITE))
	return out


func _apply_to_map() -> void:
	if _loader == null:
		return
	# Subspecies edits land as per-species overrides FIRST, so the loader's
	# post-apply side-channel refresh (apply_vegetation_look re-reads the store)
	# picks them up in the same rebuild.
	for sid in _species_edits:
		var edits: Dictionary = _species_edits[sid]
		if not edits.is_empty():
			VegetationStyleConfig.save_species_default(str(sid), edits)
	# Named-subspecies bark picks are species overrides too (unprefixed key).
	for sid in _bark_tints:
		if str(sid) != VegSpeciesCatalog.mesh_family(str(sid)):
			VegetationStyleConfig.save_species_default(str(sid),
				{"bark_tint": _bark_tints[sid]})
	var shape := _shape_dict()
	var style := _style_dict()
	# Persist this look as the GLOBAL default so future maps inherit it (per-map
	# saves still override) — BEFORE the loader apply, whose side-channel
	# refresh re-reads the stores. The store prunes values equal to defaults()
	# so untouched sliders never become "user edits" that shadow SPECS variants.
	var global_look := shape.duplicate(true)
	global_look.merge(style, true)
	VegetationStyleConfig.save_global(global_look)
	# One coalesced apply (shape + style together, single rebuild) avoids the old
	# set_vegetation_settings + set_vegetation_style double-cascade of rebuilds.
	if _loader.has_method("apply_vegetation_look"):
		_loader.call("apply_vegetation_look", shape, style)
	else:
		if _loader.has_method("set_vegetation_settings"):
			_loader.call("set_vegetation_settings", shape, true, true)
		if _loader.has_method("set_vegetation_style"):
			_loader.call("set_vegetation_style", style, true, true)
	if _dock != null and _dock.has_method("set_paint_density"):
		_dock.call("set_paint_density", _density)
	if _dock != null and _dock.has_method("set_size_var"):
		_dock.call("set_size_var", _size_var)
	if _dock != null and _dock.has_method("set_paint_species") and _species != "mix":
		_dock.call("set_paint_species", _species)
	# Apply to map = one authoritative global look. Clear the brush override so
	# future painting matches the map; the loader also strips per-instance
	# card_settings from already-placed trees (apply_vegetation_look) so EVERY tree
	# of each type adopts this look, not just newly painted ones.
	if _dock != null and _dock.has_method("set_brush_style"):
		_dock.call("set_brush_style", {})
	applied.emit()
	# Phase 8: the editor STAYS OPEN. Closing on apply made tuning a look a
	# guess-and-reopen loop — you could never see your change on the real map
	# next to the sliders that made it. The baseline moves to what the map now
	# has, so the per-slider revert buttons mean "undo this since the last
	# apply" rather than "since the modal opened".
	_baseline = _values.duplicate(true)
	for species in SPECIES_IDS:
		_baseline["%s_albedo_tint" % species] = _tints[species]
	_baseline["osm_species_map"] = _osm_species_map.duplicate(true)
	_baseline["local_mix"] = _local_mix.duplicate(true)
	# Session subspecies edits are persisted now — fold them into the stored
	# overrides so the preview keeps resolving them, and re-baseline so the
	# per-slider diffs read "since the last apply".
	_store_species_overrides = _overrides_with_edits()
	_species_edits = {}
	_species_baselines = {}
	_applied_once = true
	_refresh_all_slider_diffs()
	_refresh_apply_state("Applied to the map — keep tuning, or Close when it looks right")


## Push the current look to the paint brush only — future painted trees carry it
## as a per-instance override; the map's existing trees are untouched.
func _apply_to_brush() -> void:
	if _dock != null and _dock.has_method("set_brush_style"):
		_dock.call("set_brush_style", _brush_card())
	if _dock != null and _dock.has_method("set_paint_density"):
		_dock.call("set_paint_density", _density)
	if _dock != null and _dock.has_method("set_size_var"):
		_dock.call("set_size_var", _size_var)
	if _dock != null and _dock.has_method("set_paint_species") and _species != "mix":
		_dock.call("set_paint_species", _species)
	close()


## Footer line + Apply emphasis. With no pending edits the Apply button is a
## normal button; with edits it says how many sliders are waiting.
func _refresh_apply_state(message: String = "") -> void:
	var pending := pending_change_count()
	if _apply_btn != null:
		_apply_btn.text = "Apply to map (%d)" % pending if pending > 0 else "Apply to map"
	if _apply_status == null:
		return
	if not message.is_empty():
		_apply_status.text = message
		_apply_status.add_theme_color_override("font_color", UITheme.C_OK)
		return
	_apply_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	if pending > 0:
		_apply_status.text = "%d slider%s changed since the last apply" % [
			pending, "" if pending == 1 else "s"]
	elif _applied_once:
		_apply_status.text = "Map matches this preview"
	else:
		_apply_status.text = "Preview only — nothing on the map has changed yet"


func _reset_values() -> void:
	_values = _baseline.duplicate(true)
	_species_edits = {}
	_hi_tints = {}
	_bark_tints = {}
	for species in SPECIES_IDS:
		var tk := "%s_albedo_tint" % species
		if _baseline.has(tk):
			_tints[species] = _baseline[tk]
	_osm_species_map = (_baseline.get("osm_species_map", {}) as Dictionary).duplicate(true)
	_local_mix = (_baseline.get("local_mix", {}) as Dictionary).duplicate(true)
	_rebuild_species_section()
	_sync_tint_picker()
	_sync_top_sliders()
	_sync_osm_opts()
	_sync_forest_age_opt()
	_refresh_all_slider_diffs()
	_refresh_apply_state()
	_queue_rebuild(true)


func _on_species_selected(idx: int) -> void:
	var fam: String = SPECIES_IDS[idx]
	if fam == "mix":
		_species = "mix"
		_last_species = "mix"
		_refresh_subspecies_dropdown()
		_sync_tint_picker()
		_rebuild_species_section()
		_refresh_preset_dropdown()
		_queue_rebuild(true)
		return
	# Keep subspecies when still in the same family; otherwise pick family default.
	if VegSpeciesCatalog.mesh_family(_species) != fam:
		_species = fam
	_last_species = _species
	_refresh_subspecies_dropdown()
	_sync_tint_picker()
	_rebuild_species_section()
	_refresh_preset_dropdown()
	if _preset_name_edit != null:
		_preset_name_edit.text = ""
	_queue_rebuild(true)


func _refresh_subspecies_dropdown() -> void:
	if _subspecies_opt == null:
		return
	_subspecies_opt.clear()
	if _species == "mix":
		_subspecies_opt.add_item("—")
		_subspecies_opt.disabled = true
		return
	_subspecies_opt.disabled = false
	var fam := _shape_family() if _species != "mix" else "pine"
	# Type dropdown may have just switched family while _species still old — use Type.
	if _species_opt != null and _species_opt.selected >= 0:
		var type_fam := SPECIES_IDS[_species_opt.selected]
		if type_fam != "mix":
			fam = type_fam
	var ids := VegSpeciesCatalog.subspecies_for_family(fam)
	var select_idx := 0
	for i in ids.size():
		var sid: String = ids[i]
		_subspecies_opt.add_item(VegSpeciesCatalog.label_for(sid))
		_subspecies_opt.set_item_metadata(i, sid)
		if sid == _species:
			select_idx = i
	_subspecies_opt.select(select_idx)
	_species = str(_subspecies_opt.get_item_metadata(select_idx))
	_last_species = _species


func _on_subspecies_selected(idx: int) -> void:
	if _subspecies_opt == null or _subspecies_opt.disabled:
		return
	var sid := str(_subspecies_opt.get_item_metadata(idx))
	if sid.is_empty() or sid == _species:
		return
	_species = sid
	_last_species = sid
	# No _maybe_apply_species_default here: saved per-species overrides now
	# arrive through the store side channel and resolve in _merged_settings —
	# copying them into the FAMILY _values was exactly how one subspecies'
	# saved look leaked onto every tree of the family.
	_sync_tint_picker()
	_rebuild_species_section()
	_refresh_preset_dropdown()
	if _preset_name_edit != null:
		_preset_name_edit.text = ""
	_queue_rebuild(true)


func _on_tint_changed(c: Color) -> void:
	_tints[_species] = c
	var fam := _shape_family()
	if fam != _species and fam != "mix":
		_tints[fam] = c
	_queue_rebuild()


func _sync_species_dropdown() -> void:
	if _species_opt == null:
		return
	var fam := "mix" if _species == "mix" else VegSpeciesCatalog.mesh_family(_species)
	var idx := SPECIES_IDS.find(fam)
	if idx >= 0:
		_species_opt.select(idx)


func _sync_tint_picker() -> void:
	if _tint_picker != null:
		_tint_picker.color = _tints.get(_species, _tints.get(_shape_family(), Color.WHITE))
	# Highlight + bark display the RESOLVED colour for the active species
	# (species override > user family edit > SPECS variant), so picking Birch
	# shows its white bark rather than the family brown.
	var fam := _shape_family()
	var is_tree := fam in ["pine", "deciduous", "palm"]
	if _bark_picker != null:
		_bark_picker.visible = is_tree
		if _bark_lbl != null:
			_bark_lbl.visible = is_tree
	if _species == "mix":
		return
	var resolved := _resolved_active()
	if _hi_picker != null:
		var hi: Variant = resolved.get("%s_highlight_tint" % fam)
		_hi_picker.color = hi if hi is Color else Color(0.42, 0.52, 0.16)
	if _bark_picker != null and is_tree:
		var bark: Variant = resolved.get("%s_bark_tint" % fam,
			resolved.get("bark_albedo_tint"))
		if not (bark is Color):
			var spec: Dictionary = VegetationCardFactory.SPECS.get(_species,
				VegetationCardFactory.SPECS.get(fam, {}))
			bark = spec.get("bark", Color(0.18, 0.12, 0.07))
		_bark_picker.color = bark


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
		VegetationPaint.Preset.MIX:
			_species = "mix"
		_:
			_species = "shrub"
