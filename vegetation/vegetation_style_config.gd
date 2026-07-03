class_name VegetationStyleConfig
extends RefCounted

## Global + per-map vegetation style defaults. Merge order: defaults → map file → live patch.

const GLOBAL_PATH := "user://vegetation_style.cfg"


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
		"pine_trunk_taper": 0.38,
		"pine_fur_enabled": true,
		"pine_fur_lod_enabled": true,
		"pine_lod_near_m": 200.0,
		"pine_lod_far_begin_m": 190.0,
		"pine_fur_strength": 0.38,
		"pine_fur_cells": 20.0,
		"pine_fur_tuft_size": 0.58,
		"pine_fur_gap": 0.24,
		"pine_whorl_jitter": 0.08,
		"pine_whorl_variation": 0.32,
		"pine_whorl_band_h": 0.62,
		"pine_cone_sharpness": 0.42,
		"pine_canopy_roundness": 0.52,
		"deciduous_trunk_taper": 0.42,
		"deciduous_albedo_tint": Color(1.0, 1.0, 1.0),
		"deciduous_highlight_tint": Color(0.42, 0.52, 0.16),
		"deciduous_bulk_scale": 1.35,
		"deciduous_canopy_w": 11.0,
		"deciduous_canopy_h": 4.5,
		"deciduous_trunk_w": 0.45,
		"deciduous_trunk_h": 4.5,
		"deciduous_vertical_offset_m": 0.0,
		"deciduous_cluster_count": 8,
		"deciduous_cluster_spread": 1.0,
		"deciduous_cluster_size": 1.0,
		"deciduous_cluster_tightness": 1.0,
		"deciduous_branch_count": 4,
		"deciduous_branch_thickness": 1.0,
		"deciduous_branch_reach": 1.0,
		"deciduous_branch_base": 0.82,
		"deciduous_leaf_shells_enabled": true,
		"deciduous_leaf_lod_enabled": true,
		"deciduous_lod_near_m": 200.0,
		"deciduous_lod_far_begin_m": 190.0,
		"deciduous_leaf_shell_count": 4,
		"deciduous_leaf_density": 22.0,
		"deciduous_leaf_size": 0.85,
		"deciduous_leaf_aspect": 1.9,
		"deciduous_leaf_gap": 0.30,
		"deciduous_leaf_lump": 0.18,
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
		"grass_lawn_albedo_tint": Color(1.0, 1.0, 1.0),
		"grass_lawn_highlight_tint": Color(0.22, 0.62, 0.16),
		"grass_lawn_bulk_scale": 1.0,
		"grass_lawn_card_w": 0.45,
		"grass_lawn_card_h": 0.12,
		"grass_lawn_vertical_offset_m": 0.0,
		"grass_lawn_cells_per_side": 10.0,
		"grass_lawn_height_variation": 0.12,
		"grass_lawn_blade_thickness": 0.55,
		"grass_lawn_blade_lean": 0.10,
		"grass_lawn_hue_jitter": 0.02,
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
		"osm_species_map": {},
	}


static func map_path(lat: float, lon: float) -> String:
	return "user://maps/vegetation_style_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


static func load_merged(lat: float, lon: float) -> Dictionary:
	var out := defaults()
	_load_global_into(out)
	_load_map_into(out, lat, lon)
	return out


static func save_map(lat: float, lon: float, settings: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(map_path(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_color_dict_to_json(settings)))


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
