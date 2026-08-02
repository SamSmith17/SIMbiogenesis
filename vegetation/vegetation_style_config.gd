class_name VegetationStyleConfig
extends RefCounted

## Global + per-map vegetation style defaults. Merge order: defaults → map file → live patch.

const GLOBAL_PATH := "user://vegetation_style.cfg"
## Named per-species look presets the player can quick-load from the Tune look…
## modal. One ConfigFile section per species; each key = preset name → value dict.
const PRESETS_PATH := "user://vegetation_presets.cfg"
## Player-edited default look per subspecies id (spruce, fir, …). Merged after
## global style so new maps / sessions start from the saved species looks.
const SPECIES_DEFAULTS_PATH := "user://vegetation_species_defaults.json"


static func defaults() -> Dictionary:
	return {
		"pine_albedo_tint": Color(1.0, 1.0, 1.0),
		"pine_highlight_tint": Color(0.10, 0.20, 0.07),
		"pine_bulk_scale": 1.0,
		"pine_card_w": 0.85,
		"pine_card_h": 4.5,
		"pine_trunk_w": 0.24,
		"pine_vertical_offset_m": 0.0,
		"pine_whorl_count": 7,
		"pine_bough_scale": 1.0,
		"pine_whorl_spacing": 1.0,
		"pine_growth_years": 20.0,
		"pine_trunk_taper": 0.38,
		"pine_fur_enabled": true,
		"pine_fur_lod_enabled": true,
		"pine_lod_near_m": 200.0,
		"pine_lod_far_begin_m": 190.0,
		# Auto (OSM-scattered) forests are viewed from the drone across ~3 km, so the
		# short manual near/far reach above drops them to the leafless FAR billboard
		# tier at typical altitudes. These auto-only overrides keep the leaf/fur NEAR
		# tier alive much farther out; the manual painted-tree reach is untouched.
		"pine_auto_lod_near_m": 300.0,
		"pine_auto_lod_far_begin_m": 280.0,
		"pine_fur_strength": 0.38,
		"pine_fur_cells": 20.0,
		"pine_fur_tuft_size": 0.58,
		"pine_fur_gap": 0.24,
		"pine_whorl_jitter": 0.08,
		"pine_whorl_variation": 0.32,
		"pine_whorl_band_h": 0.62,
		"pine_cone_sharpness": 0.42,
		"pine_canopy_roundness": 0.52,
		# Deciduous defaults = the player's tuned "2" preset (see also
		# VegetationLayer.default_settings, which must mirror the shape keys). This is
		# the default deciduous tree every fresh map inherits.
		"deciduous_trunk_taper": 0.7,
		"deciduous_albedo_tint": Color(0.0435791, 0.19921875, 0.075193405),
		"deciduous_highlight_tint": Color(0.42, 0.52, 0.16),
		"deciduous_bulk_scale": 1.6,
		"deciduous_canopy_w": 12.05,
		"deciduous_canopy_h": 4.35,
		"deciduous_trunk_w": 1.31,
		"deciduous_trunk_h": 4.25,
		"deciduous_vertical_offset_m": -2.0,
		"deciduous_cluster_count": 12.0,
		# Legacy pair (abstract-ring layout only — the tip-anchored crown reads
		# deciduous_clump_spread instead; see _clusters_from_tips).
		"deciduous_cluster_spread": 0.67,
		"deciduous_cluster_size": 1.0,
		"deciduous_cluster_tightness": 1.12,
		# Radial push/huddle of the foliage clumps on their branch tips.
		"deciduous_clump_spread": 1.0,
		# Deterministic skeleton variant (0-9): same dims, different tree.
		"deciduous_skeleton_seed": 0.0,
		"deciduous_branch_count": 9.55,
		"deciduous_branch_thickness": 0.64,
		"deciduous_branch_reach": 0.89,
		# Legacy alias for deciduous_crown_base (kept so saved styles migrate).
		"deciduous_branch_base": 0.71,
		# Where the LOWEST limb leaves the trunk. 0.71 packed every primary into
		# the top third of the trunk; 0.42 gives a real crown-bearing length.
		"deciduous_crown_base": 0.42,
		# Splay of the lowest vs highest limb, degrees from vertical.
		"deciduous_branch_tilt_low": 75.0,
		"deciduous_branch_tilt_high": 26.0,
		# Fraction of limb segments that carry a side shoot. Side branching is
		# what fills a broadleaf crown; without it limbs are bare sticks with a
		# tuft on the end and the crown needs far more primaries to look full.
		"deciduous_branch_lateral": 0.45,
		"deciduous_branch_levels": 2.15,
		"deciduous_branch_split": 2.65,
		"deciduous_branch_angle": 38.0,
		"deciduous_branch_length_ratio": 0.62,
		"deciduous_branch_droop": 0.12,
		"deciduous_branch_gnarl": 0.21,
		"deciduous_growth_years": 9.85,
		"deciduous_leaf_shells_enabled": true,
		"deciduous_leaf_lod_enabled": true,
		"deciduous_lod_near_m": 99.7,
		"deciduous_lod_far_begin_m": 92.15,
		# Auto-only leaf-shell reach (see pine_auto_lod_* above for the rationale):
		# keeps OSM-scattered deciduous forests in the leaf-shell NEAR tier at drone
		# distances instead of the leafless FAR billboard. Manual reach stays at 99.7.
		"deciduous_auto_lod_near_m": 300.0,
		"deciduous_auto_lod_far_begin_m": 280.0,
		"deciduous_billboard_y_offset": -1.11,
		# Foliage hangs on real branch tips and the leaf grid stamps TWO
		# interleaved layers per shell, so 4 shells read solid; the saved tri
		# budget pays for the rounder 5×10 shell spheres (hex-box silhouettes).
		"deciduous_leaf_shell_count": 4.0,
		"deciduous_leaf_density": 15.0,
		"deciduous_leaf_size": 0.95,
		"deciduous_leaf_aspect": 1.5,
		"deciduous_leaf_gap": 0.08,
		"deciduous_leaf_lump": 0.39,
		"deciduous_shadow_proxy_enabled": true,
		"deciduous_shadow_proxy_scale": 1.06,
		"deciduous_shadow_proxy_visibility": 0.04,
		"shrub_albedo_tint": Color(1.0, 1.0, 1.0),
		"shrub_highlight_tint": Color(0.26, 0.34, 0.12),
		"shrub_bulk_scale": 1.0,
		"shrub_card_w": 1.4,
		"shrub_card_h": 1.15,
		"shrub_vertical_offset_m": 0.0,
		"shrub_cluster_count": 6,
		"shrub_cluster_spread": 1.0,
		"shrub_cluster_size": 1.0,
		"shrub_growth_years": 5.0,
		"grass_lawn_albedo_tint": Color(1.0, 1.0, 1.0),
		"grass_lawn_highlight_tint": Color(0.22, 0.62, 0.16),
		"grass_lawn_bulk_scale": 1.0,
		"grass_lawn_card_w": 0.8,
		"grass_lawn_card_h": 0.12,
		"grass_lawn_vertical_offset_m": 0.0,
		"grass_lawn_cells_per_side": 18.0,
		"grass_lawn_height_variation": 0.02,
		"grass_lawn_blade_thickness": 0.55,
		"grass_lawn_blade_lean": 0.10,
		"grass_lawn_hue_jitter": 0.02,
		"grass_lawn_growth_years": 0.0,
		"grass_field_albedo_tint": Color(1.0, 1.0, 1.0),
		"grass_field_highlight_tint": Color(0.52, 0.58, 0.20),
		"grass_field_bulk_scale": 1.25,
		"grass_field_card_w": 0.55,
		"grass_field_card_h": 0.88,
		"grass_field_vertical_offset_m": 0.0,
		"grass_field_cells_per_side": 8.0,
		"grass_field_height_variation": 0.45,
		"grass_field_blade_thickness": 0.5,
		"grass_field_blade_lean": 0.22,
		"grass_field_hue_jitter": 0.06,
		"grass_field_growth_years": 0.0,
		# Single Tune-look knob for how far OSM-scattered forests keep their leaf/fur
		# NEAR tier (see *_auto_lod_* above). Higher = leaves persist farther (nicer
		# from the drone) at more vertex cost; lower = billboards sooner (cheaper).
		"auto_foliage_lod_reach_m": 300.0,
		# Whole-forest size multiplier for OSM auto-scattered trees (pine/deciduous/
		# shrub). Auto trees derive their height from OSM data via each record's
		# scale; the per-species *_bulk_scale keys are neutralised on that path
		# (AutoVegetationRuntime.NEUTRAL_BULK), so this is the one honest knob.
		# Applied at rebuild time — changing it does not re-scatter.
		"auto_tree_scale": 1.0,
		# Forest age profile (Phase 9): how a freshly seeded stand's ages spread
		# across the growth span — "mature" (the long-standing behaviour and the
		# default), "mixed" (an even spread, uneven-aged stand) or "young"
		# (regrowth: mostly saplings). Consumed by
		# VegetationGrowth.ensure_birth_times; takes effect on the next reseed.
		"forest_age": "mature",
		# Static SoI-centred detail rings (VegTierRings, Phase 3): the leaf-shell
		# NEAR tier only exists in chunks within veg_near_ring_m of the SoI
		# centre; veg_mid_ring_m bounds the FAR-card ring; beyond is the cheapest
		# representation. Centre keys are injected live from SoiService at
		# rebuild (veg_ring_center_x/z). Radii become quality-tier knobs in
		# Phase 4.
		"veg_tier_rings_enabled": true,
		"veg_near_ring_m": 250.0,
		"veg_mid_ring_m": 700.0,
		"wind_strength": 0.03,
		"wind_speed": 0.7,
		"dither_strength": 1.0,
		"alpha_dither_min": 0.20,
		"alpha_dither_max": 0.50,
		"near_crisp_m": 40.0,
		"far_dither_m": 120.0,
		"haze_strength": 0.65,
		"lean_amount": 0.30,
		"subsurface_strength": 0.15,
		"hue_jitter": 0.05,
		"drape_match_strength": 0.35,
		"translucency_strength": 0.25,
		"canopy_roundness": 0.40,
		"color_variation": 0.12,
		"foliage_roughness": 0.95,
		"ao_strength": 0.35,
		"bark_roughness": 0.98,
		"bark_ao_strength": 0.28,
		"bark_color_jitter": 0.06,
		"bud_color": Color(0.55, 0.78, 0.24),
		"autumn_warm": Color(0.96, 0.78, 0.12),
		"autumn_orange": Color(0.93, 0.45, 0.06),
		"autumn_hot": Color(0.80, 0.13, 0.04),
		"grass_summer_color": Color(0.68, 0.65, 0.22),
		"grass_fall_color": Color(0.52, 0.44, 0.18),
		"haze_sync": true,
		"building_exclusion_m": 3.0,
		"road_exclusion_m": 2.5,
		"building_exclusion_enabled": true,
		"road_exclusion_enabled": true,
		"water_exclusion_m": 0.0,
		"forest_zones_enabled": false,
		"forest_auto_min_area_m2": 12000.0,
		"forest_trunk_spacing_m": 10.0,
		"forest_canopy_height_m": 14.0,
		"forest_understory_clearance_m": 2.5,
		"forest_edge_feather_m": 20.0,
		"canopy_shadow_strength": 0.85,
		"dapple_scale_m": 2.5,
		"dapple_density": 0.55,
		"seasonal_strength": 0.0,
		"slope_max_deg": 25.0,
		"auto_density_scale": 1.0,
		# Hard caps so heavy OSM maps still load (override in Tune look / terrain cfg).
		"auto_max_tree_instances": 24000,
		"auto_max_grass_instances": 120000,
		## Beyond this radius from site centre, tree density is thinned by
		## auto_distant_density (0 = skip distant, 1 = full density).
		"auto_detail_radius_m": 800.0,
		"auto_distant_density": 0.35,
		## Tree MultiMesh visibility_range_end (AutoVegetationRuntime).
		"auto_visibility_end_m": 1200.0,
		"osm_species_map": {},
		"local_mix": {},
		# Mixed-woodland composition (Tune Look "Mixed woodland" type) used by any
		# OSM kind bound to "Mixed (local blend)".
		"mix_pine": 0.45,
		"mix_deciduous": 0.45,
		"mix_shrub": 0.10,
		# Mapped meadow/lawn polygons veto tree scatter from overlapping OSM
		# areas (a wood drawn over a meadow must not forest it).
		"open_areas_exclude_trees": true,
		# FAR grass LOD cull distance. 380 m (GrassBuilder default) was tuned
		# for camp scale; OSM meadows a few hundred metres out need more reach.
		"grass_visibility_end_m": 520.0,
		# Dense 3D grass is only generated within this radius of spawn (auto veg
		# only — the budget can't grass a whole 3-km site at close-up density).
		"grass_detail_radius_m": 500.0,
	}


static func map_path(lat: float, lon: float) -> String:
	return "user://maps/vegetation_style_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


## Phase 2: resolution + persistence live in VegStyleStore (layered v2 schema,
## precedence species > family > global > SPECS). These entry points remain the
## facade every consumer calls; v1 files are migrated one-way on first read.
static func load_merged(lat: float, lon: float) -> Dictionary:
	return VegStyleStore.flat_merged(lat, lon)


static func save_map(lat: float, lon: float, settings: Dictionary) -> void:
	VegStyleStore.save_map_style(lat, lon, settings)


## JSON-safe Color→array conversion for .esim / file exchange.
static func to_serializable(settings: Dictionary) -> Dictionary:
	return _color_dict_to_json(settings)


static func from_serializable(settings: Dictionary) -> Dictionary:
	return _json_to_color_dict(settings)


## Persist the given keys as the GLOBAL default look (defaults ← here ← per-map).
## Called from the Tune look… modal's "Apply to map" so a tuned look becomes the
## default for every future map until re-tuned (a per-map save still overrides).
## Existing keys are merged, not clobbered, so partial saves keep prior defaults.
static func save_global(settings: Dictionary) -> void:
	VegStyleStore.save_global_patch(settings)


static func clear_global() -> void:
	if FileAccess.file_exists(GLOBAL_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GLOBAL_PATH))
	var v2 := VegStyleStore.global_v2_path()
	if FileAccess.file_exists(v2):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(v2))
	VegStyleStore.invalidate_cache()


## Shape-only subset of a style dict (keys the VegetationLayer owns). Used to seed
## a fresh map's layer with the global tune-look shape so it renders as the player
## last tuned it (the render path lets layer shape win over style shape).
static func shape_subset(style: Dictionary) -> Dictionary:
	var out := {}
	for k in VegetationLayer.default_settings():
		if style.has(k):
			out[k] = style[k]
	return out


# --- Per-species look presets -------------------------------------------------

static func list_presets(species: String) -> PackedStringArray:
	if not FileAccess.file_exists(PRESETS_PATH):
		return PackedStringArray()
	var cfg := ConfigFile.new()
	if cfg.load(PRESETS_PATH) != OK or not cfg.has_section(species):
		return PackedStringArray()
	return cfg.get_section_keys(species)


static func save_preset(species: String, preset_name: String, values: Dictionary) -> void:
	if species.is_empty() or preset_name.strip_edges().is_empty():
		return
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(PRESETS_PATH):
		cfg.load(PRESETS_PATH)
	cfg.set_value(species, preset_name.strip_edges(), _color_dict_to_json(values))
	cfg.save(PRESETS_PATH)


static func load_preset(species: String, preset_name: String) -> Dictionary:
	if not FileAccess.file_exists(PRESETS_PATH):
		return {}
	var cfg := ConfigFile.new()
	if cfg.load(PRESETS_PATH) != OK or not cfg.has_section_key(species, preset_name):
		return {}
	var raw: Variant = cfg.get_value(species, preset_name, {})
	if raw is Dictionary:
		return _json_to_color_dict(raw as Dictionary)
	return {}


static func delete_preset(species: String, preset_name: String) -> void:
	if not FileAccess.file_exists(PRESETS_PATH):
		return
	var cfg := ConfigFile.new()
	if cfg.load(PRESETS_PATH) != OK:
		return
	if cfg.has_section_key(species, preset_name):
		cfg.erase_section_key(species, preset_name)
		cfg.save(PRESETS_PATH)


# --- Per-subspecies default looks --------------------------------------------

## Values arrive family-prefixed from the Tune-look sliders ("pine_card_w" while
## editing Spruce). Strip the prefix so they land as REAL per-species overrides
## in the store's species layer — the v1 file stored them family-prefixed under
## the subspecies name, which is exactly why saving Spruce retuned every conifer.
static func save_species_default(species: String, values: Dictionary) -> void:
	if species.is_empty() or values.is_empty():
		return
	var family := VegSpeciesCatalog.mesh_family(species)
	var unpref := {}
	for k in values:
		var key := str(k)
		if key.begins_with("_"):
			continue
		if key.begins_with(species + "_"):
			unpref[key.substr(species.length() + 1)] = values[k]
		elif key.begins_with(family + "_"):
			unpref[key.substr(family.length() + 1)] = values[k]
		else:
			unpref[key] = values[k]
	VegStyleStore.save_species_override(species, unpref)


## Returns the stored per-species overrides RE-PREFIXED with the family keys
## (plus "<species>_albedo_tint"/"_highlight_tint") — the flat form the
## Tune-look modal's slider table expects.
static func load_species_default(species: String) -> Dictionary:
	var over := VegStyleStore.species_override(species)
	if over.is_empty():
		return {}
	var family := VegSpeciesCatalog.mesh_family(species)
	var out := {}
	for k in over:
		var key := str(k)
		if key == "albedo_tint" or key == "highlight_tint":
			out["%s_%s" % [species, key]] = over[k]
		else:
			out["%s_%s" % [family, key]] = over[k]
	return out


static func _load_species_defaults_file() -> Dictionary:
	if not FileAccess.file_exists(SPECIES_DEFAULTS_PATH):
		return {}
	var f := FileAccess.open(SPECIES_DEFAULTS_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed as Dictionary if parsed is Dictionary else {}


static func _merge_species_defaults_into(out: Dictionary) -> void:
	var all := _load_species_defaults_file()
	for species in all:
		var raw: Variant = all[species]
		if not (raw is Dictionary):
			continue
		var patch := _json_to_color_dict(raw as Dictionary)
		out.merge(patch, true)


## Map a Size-var slider (0 = identical, 0.5 = ±50%) onto scale_min/scale_max.
static func scales_from_size_var(size_var: float) -> Vector2:
	var v := clampf(size_var, 0.0, 0.5)
	return Vector2(1.0 - v, 1.0 + v)


static func apply_patch(base: Dictionary, patch: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	out.merge(patch, true)
	return out


static func runtime_settings(style: Dictionary, drape: Texture2D = null,
		drape_extent_m: float = 0.0, seasonal_tint: Color = Color.WHITE) -> Dictionary:
	var out := style.duplicate(true)
	if drape != null and drape_extent_m > 0.0:
		out["drape_tex"] = drape
		out["drape_extent_m"] = drape_extent_m
	if style.get("seasonal_strength", 0.0) > 0.0:
		out["seasonal_tint"] = seasonal_tint
	return out


static func _load_global_into(out: Dictionary) -> void:
	if not FileAccess.file_exists(GLOBAL_PATH):
		return
	var cfg := ConfigFile.new()
	if cfg.load(GLOBAL_PATH) != OK:
		return
	if not cfg.has_section("style"):
		return
	for key in cfg.get_section_keys("style"):
		out[key] = cfg.get_value("style", key)


static func _load_map_into(out: Dictionary, lat: float, lon: float) -> void:
	var path := map_path(lat, lon)
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		out.merge(_json_to_color_dict(parsed as Dictionary), true)


static func _color_dict_to_json(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		var v: Variant = d[k]
		if v is Color:
			var c: Color = v
			out[k] = [c.r, c.g, c.b, c.a]
		else:
			out[k] = v
	return out


static func _json_to_color_dict(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		var v: Variant = d[k]
		if v is Array and (v as Array).size() >= 3:
			var a: Array = v
			out[k] = Color(float(a[0]), float(a[1]), float(a[2]),
				float(a[3]) if a.size() >= 4 else 1.0)
		else:
			out[k] = v
	return out
