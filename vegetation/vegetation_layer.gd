class_name VegetationLayer
extends RefCounted

## Per-map user vegetation: bulk MultiMesh instances + hero tree placements.

const VERSION := 1
const SPECIES: Array[String] = ["pine", "deciduous", "shrub"]
const GRASS_SPECIES: Array[String] = ["grass_lawn", "grass_field"]
const ALL_SPECIES: Array[String] = ["pine", "deciduous", "shrub", "grass_lawn", "grass_field"]
const MAX_HERO := 500
const MAX_BULK_PER_SPECIES := 10000
const MAX_GRASS_PER_SPECIES := 15000


static func default_settings() -> Dictionary:
	return {
		"vertical_offset_m": 0.0,
		"deciduous_canopy_w": 11.0,
		"deciduous_canopy_h": 4.5,
		"deciduous_trunk_w": 0.45,
		"deciduous_trunk_h": 4.5,
		"deciduous_bulk_scale": 1.35,
		"deciduous_vertical_offset_m": 0.0,
		"pine_bulk_scale": 1.0,
		"pine_card_w": 0.85,
		"pine_card_h": 4.5,
		"pine_trunk_w": 0.24,
		"pine_vertical_offset_m": 0.0,
		"shrub_bulk_scale": 1.0,
		"shrub_card_w": 1.4,
		"shrub_card_h": 1.15,
		"shrub_vertical_offset_m": 0.0,
		"grass_lawn_bulk_scale": 1.35,
		"grass_lawn_card_w": 0.08,
		"grass_lawn_card_h": 0.42,
		"grass_lawn_vertical_offset_m": 0.0,
		"grass_field_bulk_scale": 1.25,
		"grass_field_card_w": 0.11,
		"grass_field_card_h": 0.88,
		"grass_field_vertical_offset_m": 0.0,
	}


static func max_bulk_for_species(species: String) -> int:
	if species in GRASS_SPECIES:
		return MAX_GRASS_PER_SPECIES
	return MAX_BULK_PER_SPECIES


static func create_empty() -> VegetationLayer:
	var layer := VegetationLayer.new()
	for species in ALL_SPECIES:
		layer.bulk[species] = []
	layer.hero = []
	layer.settings = default_settings()
	return layer


var bulk: Dictionary = {}
var hero: Array = []
var settings: Dictionary = {}


func add_bulk(species: String, x: float, z: float, yaw: float, scale: float) -> bool:
	if species not in bulk:
		return false
	var arr: Array = bulk[species]
	if arr.size() >= max_bulk_for_species(species):
		return false
	arr.append({"x": x, "z": z, "yaw": yaw, "scale": scale})
	return true


func add_hero(preset: String, x: float, z: float, yaw: float, scale: float,
		ground_y: float = NAN) -> bool:
	if hero.size() >= MAX_HERO:
		return false
	var rec := {"preset": preset, "x": x, "z": z, "yaw": yaw, "scale": scale}
	if not is_nan(ground_y):
		rec["ground_y"] = ground_y
	hero.append(rec)
	return true


func get_settings() -> Dictionary:
	var out := default_settings()
	out.merge(settings, true)
	return out


func apply_settings(patch: Dictionary) -> void:
	settings.merge(patch, true)


func remove_bulk_in_polygon(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		return
	for species in ALL_SPECIES:
		var kept: Array = []
		for item in bulk.get(species, []):
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
			if not Geometry2D.is_point_in_polygon(pt, poly):
				kept.append(d)
		bulk[species] = kept
	remove_hero_in_polygon(poly)


func remove_hero_in_polygon(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		return
	var kept: Array = []
	for item in hero:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
		if not Geometry2D.is_point_in_polygon(pt, poly):
			kept.append(d)
	hero = kept


func count_bulk_in_polygon(poly: PackedVector2Array) -> int:
	if poly.size() < 3:
		return 0
	var n := 0
	for species in ALL_SPECIES:
		for item in bulk.get(species, []):
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
			if Geometry2D.is_point_in_polygon(pt, poly):
				n += 1
	return n


func patch_bulk_in_polygon(poly: PackedVector2Array, params: Dictionary) -> int:
	if params.is_empty():
		return 0
	var all_map := bool(params.get("patch_all_map", false))
	if not all_map and poly.size() < 3:
		return 0
	var n := 0
	var scale_mul := float(params.get("scale_mul", 1.0))
	var target := str(params.get("patch_species", ""))
	for species in ALL_SPECIES:
		if not target.is_empty() and species != target:
			continue
		var card := _card_settings_for_species(params, species)
		for item in bulk.get(species, []):
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			if not all_map:
				var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
				if not Geometry2D.is_point_in_polygon(pt, poly):
					continue
			if absf(scale_mul - 1.0) > 0.001:
				d["scale"] = float(d.get("scale", 1.0)) * scale_mul
			if params.has("vertical_offset_m"):
				d["vert_off"] = float(params["vertical_offset_m"]) + float(params.get("%s_vertical_offset_m" % species, 0.0))
			elif params.has("%s_vertical_offset_m" % species):
				d["vert_off"] = vertical_offset_for(species, params)
			if not card.is_empty():
				var prev: Dictionary = d.get("card_settings", {}) as Dictionary
				var merged := prev.duplicate()
				merged.merge(card, true)
				d["card_settings"] = merged
			n += 1
	return n


static func vertical_offset_for(species: String, settings: Dictionary) -> float:
	return float(settings.get("vertical_offset_m", 0.0)) \
		+ float(settings.get("%s_vertical_offset_m" % species, 0.0))


static func _card_settings_for_species(params: Dictionary, species: String) -> Dictionary:
	var keys: Array[String] = []
	match species:
		"pine":
			keys = ["pine_card_w", "pine_card_h", "pine_trunk_w", "pine_bulk_scale", "pine_vertical_offset_m"]
		"deciduous":
			keys = ["deciduous_canopy_w", "deciduous_canopy_h", "deciduous_trunk_w",
				"deciduous_trunk_h", "deciduous_bulk_scale", "deciduous_vertical_offset_m"]
		"shrub":
			keys = ["shrub_card_w", "shrub_card_h", "shrub_bulk_scale", "shrub_vertical_offset_m"]
		"grass_lawn":
			keys = ["grass_lawn_card_w", "grass_lawn_card_h", "grass_lawn_bulk_scale",
				"grass_lawn_vertical_offset_m"]
		"grass_field":
			keys = ["grass_field_card_w", "grass_field_card_h", "grass_field_bulk_scale",
				"grass_field_vertical_offset_m"]
	var out := {}
	for key in keys:
		if params.has(key):
			out[key] = params[key]
	return out


static func _card_settings_from_params(params: Dictionary) -> Dictionary:
	var out := {}
	for key in [
		"deciduous_canopy_w", "deciduous_canopy_h", "deciduous_trunk_w", "deciduous_trunk_h",
		"deciduous_bulk_scale", "deciduous_vertical_offset_m",
		"pine_card_w", "pine_card_h", "pine_trunk_w", "pine_bulk_scale", "pine_vertical_offset_m",
		"shrub_card_w", "shrub_card_h", "shrub_bulk_scale", "shrub_vertical_offset_m",
		"grass_lawn_card_w", "grass_lawn_card_h", "grass_lawn_bulk_scale", "grass_lawn_vertical_offset_m",
		"grass_field_card_w", "grass_field_card_h", "grass_field_bulk_scale", "grass_field_vertical_offset_m",
	]:
		if params.has(key):
			out[key] = params[key]
	return out


func remove_nearest_hero(world_xz: Vector2, radius_m: float = 3.0) -> bool:
	var best_i := -1
	var best_d := radius_m * radius_m
	for i in hero.size():
		var h: Dictionary = hero[i]
		var pt := Vector2(float(h.get("x", 0.0)), float(h.get("z", 0.0)))
		var d := pt.distance_squared_to(world_xz)
		if d < best_d:
			best_d = d
			best_i = i
	if best_i < 0:
		return false
	hero.remove_at(best_i)
	return true


func all_bulk_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for species in ALL_SPECIES:
		for item in bulk.get(species, []):
			if item is Dictionary:
				var d: Dictionary = item
				out.append(Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0))))
	return out


func all_placement_points() -> Array[Vector2]:
	var out := all_bulk_points()
	for item in hero:
		if item is Dictionary:
			var d: Dictionary = item
			out.append(Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0))))
	return out


func remaining_bulk_capacity() -> int:
	var used := 0
	for species in ALL_SPECIES:
		used += bulk.get(species, []).size()
	return maxi(0, MAX_BULK_PER_SPECIES * SPECIES.size() + MAX_GRASS_PER_SPECIES * GRASS_SPECIES.size() - used)


func save_path_for_map(lat: float, lon: float) -> String:
	return "user://maps/vegetation_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


func save(lat: float, lon: float) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(save_path_for_map(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(serialize()))


func load_for_map(lat: float, lon: float) -> bool:
	var path := save_path_for_map(lat, lon)
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return false
	deserialize(parsed as Dictionary)
	return true


func serialize() -> Dictionary:
	var bulk_out := {}
	for species in ALL_SPECIES:
		bulk_out[species] = bulk.get(species, [])
	return {
		"version": VERSION,
		"bulk": bulk_out,
		"hero": hero.duplicate(true),
		"settings": get_settings(),
	}


func ensure_species_keys() -> void:
	for species in ALL_SPECIES:
		if species not in bulk:
			bulk[species] = []


func deserialize(data: Dictionary) -> void:
	bulk = {}
	var src: Dictionary = data.get("bulk", {}) as Dictionary
	for species in ALL_SPECIES:
		bulk[species] = src.get(species, [])
	hero = []
	for item in data.get("hero", []):
		if item is Dictionary:
			hero.append(item)
	settings = default_settings()
	if data.get("settings") is Dictionary:
		settings.merge(data["settings"], true)

