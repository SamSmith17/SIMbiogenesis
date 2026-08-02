class_name VegetationLayer
extends RefCounted

## Per-map user vegetation: bulk MultiMesh instances + hero tree placements.

## v2: `settings` persists SPARSE user deltas only. v1 files stored the
## COMPLETE settings dict (defaults included), and because the render path
## merges layer settings over the style, every stale copy of a default
## permanently shadowed the style store ("Tune-look doesn't apply" cause #3).
const VERSION := 2
const SPECIES: Array[String] = ["pine", "deciduous", "shrub"]
const GRASS_SPECIES: Array[String] = ["grass_lawn", "grass_field"]
## Base family slots (always present). Subspecies (spruce, fir, …) are created
## lazily in `bulk` when painted — see ensure_species_key / add_bulk.
const ALL_SPECIES: Array[String] = ["pine", "deciduous", "shrub", "grass_lawn", "grass_field"]
const MAX_HERO := 500
const MAX_BULK_PER_SPECIES := 10000
const MAX_GRASS_PER_SPECIES := 15000


static func default_settings() -> Dictionary:
	return {
		"vertical_offset_m": 0.0,
		# Deciduous defaults = the player's tuned "2" preset (the desired default
		# tree). Shape keys the layer owns MUST match VegetationStyleConfig.defaults()
		# because the render path merges layer settings ON TOP of the style, so a
		# stale layer default here would override the style and auto (OSM) trees
		# would render with the old shape instead of the tuned one.
		"deciduous_canopy_w": 12.05,
		"deciduous_canopy_h": 4.35,
		"deciduous_trunk_w": 1.31,
		"deciduous_trunk_h": 4.25,
		"deciduous_bulk_scale": 1.6,
		"deciduous_vertical_offset_m": -2.0,
		"deciduous_cluster_count": 10.05,
		"deciduous_cluster_spread": 0.67,
		"deciduous_cluster_size": 1.0,
		"deciduous_cluster_tightness": 1.12,
		"deciduous_branch_count": 9.55,
		"deciduous_branch_thickness": 0.64,
		"deciduous_branch_reach": 0.89,
		"deciduous_branch_base": 0.71,
		"deciduous_branch_levels": 2.15,
		"deciduous_branch_split": 2.65,
		"deciduous_branch_angle": 38.0,
		"deciduous_branch_length_ratio": 0.62,
		"deciduous_branch_droop": 0.12,
		"deciduous_branch_gnarl": 0.21,
		"deciduous_growth_years": 9.85,
		"pine_bulk_scale": 1.0,
		"pine_card_w": 0.85,
		"pine_card_h": 4.5,
		"pine_trunk_w": 0.24,
		"pine_vertical_offset_m": 0.0,
		"pine_whorl_count": 7,
		"pine_bough_scale": 1.0,
		"pine_whorl_spacing": 1.0,
		"pine_growth_years": 20.0,
		"shrub_bulk_scale": 1.0,
		"shrub_card_w": 1.4,
		"shrub_card_h": 1.15,
		"shrub_vertical_offset_m": 0.0,
		"shrub_cluster_count": 6,
		"shrub_cluster_spread": 1.0,
		"shrub_cluster_size": 1.0,
		"shrub_growth_years": 5.0,
		"grass_lawn_bulk_scale": 1.0,
		# Must mirror VegetationStyleConfig.defaults() (was 0.45, a drift that
		# permanently pinned lawn mat width because the layer used to win).
		"grass_lawn_card_w": 0.8,
		"grass_lawn_card_h": 0.12,
		"grass_lawn_vertical_offset_m": 0.0,
		"grass_lawn_growth_years": 0.0,
		"grass_field_bulk_scale": 1.25,
		"grass_field_card_w": 0.55,
		"grass_field_card_h": 0.88,
		"grass_field_vertical_offset_m": 0.0,
		"grass_field_growth_years": 0.0,
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
	layer.growth_zones = []
	return layer


var bulk: Dictionary = {}
var hero: Array = []
var settings: Dictionary = {}
## Paint polygons that define where generational reseeding may place seedlings.
var growth_zones: Array = []


## All species keys currently stored (base families + painted subspecies).
func species_keys() -> Array[String]:
	var out: Array[String] = []
	for k in bulk.keys():
		out.append(str(k))
	for sp in ALL_SPECIES:
		if sp not in out:
			out.append(sp)
	return out


func ensure_species_key(species: String) -> bool:
	if species.is_empty() or not VegSpeciesCatalog.is_paintable(species):
		return false
	if not bulk.has(species):
		bulk[species] = []
	return true


func add_bulk(species: String, x: float, z: float, yaw: float, scale: float,
		card: Dictionary = {}) -> bool:
	if not ensure_species_key(species):
		return false
	var arr: Array = bulk[species]
	var fam := VegSpeciesCatalog.mesh_family(species)
	if arr.size() >= max_bulk_for_species(fam):
		return false
	var rec := {"x": x, "z": z, "yaw": yaw, "scale": scale}
	# Optional per-instance look override ("Apply to brush" snapshot) so these
	# painted trees keep their custom shape/shader independent of the global map
	# style set later by "Apply to map".
	if not card.is_empty():
		rec["card_settings"] = card.duplicate(true)
	arr.append(rec)
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


## SPARSE user deltas only — what the render path merges over the style store.
## get_settings() (defaults + deltas) remains for internal per-key fallbacks,
## but merging IT over the style is exactly the shadowing bug v2 removes.
func user_settings() -> Dictionary:
	return settings.duplicate(true)


func apply_settings(patch: Dictionary) -> void:
	settings.merge(patch, true)


## Drop specific delta keys — called when the same keys are (re)expressed at
## style-store level, which is now the canonical home for shape (Phase 2).
func erase_settings_keys(keys: Array) -> void:
	for k in keys:
		settings.erase(str(k))


## Strip per-instance card_settings ("Apply to brush" snapshots) from every bulk
## record so all trees conform to the global map look. Returns the count cleared.
## "Apply to map" is authoritative over the whole map (see
## terrain_loader.apply_vegetation_look): without this, any tree painted with a
## custom brush look keeps a per-instance override that wins over the global
## settings in _partition_bulk_batches — and since card_settings persists to the
## map JSON, those trees stay pinned to a stale appearance even across reloads.
func clear_card_overrides() -> int:
	var n := 0
	for species in species_keys():
		for item in bulk.get(species, []):
			if item is Dictionary and (item as Dictionary).has("card_settings"):
				(item as Dictionary).erase("card_settings")
				n += 1
	return n


func remove_bulk_in_polygon(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		return
	for species in species_keys():
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
	for species in species_keys():
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
	for species in species_keys():
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
	var fam := VegSpeciesCatalog.mesh_family(species)
	return float(settings.get("vertical_offset_m", 0.0)) \
		+ float(settings.get("%s_vertical_offset_m" % species,
			settings.get("%s_vertical_offset_m" % fam, 0.0)))


static func _card_settings_for_species(params: Dictionary, species: String) -> Dictionary:
	var keys: Array[String] = []
	match species:
		"pine":
			keys = ["pine_card_w", "pine_card_h", "pine_trunk_w", "pine_bulk_scale",
				"pine_vertical_offset_m", "pine_whorl_count", "pine_bough_scale", "pine_whorl_spacing"]
		"deciduous":
			keys = ["deciduous_canopy_w", "deciduous_canopy_h", "deciduous_trunk_w",
				"deciduous_trunk_h", "deciduous_bulk_scale", "deciduous_vertical_offset_m",
				"deciduous_cluster_count", "deciduous_cluster_spread", "deciduous_cluster_size",
				"deciduous_cluster_tightness", "deciduous_branch_count", "deciduous_branch_thickness",
				"deciduous_branch_reach", "deciduous_branch_base"]
		"shrub":
			keys = ["shrub_card_w", "shrub_card_h", "shrub_bulk_scale", "shrub_vertical_offset_m",
				"shrub_cluster_count", "shrub_cluster_spread", "shrub_cluster_size"]
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
		"deciduous_cluster_count", "deciduous_cluster_spread", "deciduous_cluster_size",
		"deciduous_cluster_tightness", "deciduous_branch_count", "deciduous_branch_thickness",
		"deciduous_branch_reach", "deciduous_branch_base",
		"pine_card_w", "pine_card_h", "pine_trunk_w", "pine_bulk_scale", "pine_vertical_offset_m",
		"pine_whorl_count", "pine_bough_scale", "pine_whorl_spacing",
		"shrub_card_w", "shrub_card_h", "shrub_bulk_scale", "shrub_vertical_offset_m",
		"shrub_cluster_count", "shrub_cluster_spread", "shrub_cluster_size",
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
	for species in species_keys():
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
	for species in species_keys():
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


func add_growth_zone(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		return
	growth_zones.append(poly)


func serialize() -> Dictionary:
	var bulk_out := {}
	for species in species_keys():
		bulk_out[species] = _records_to_json(bulk.get(species, []))
	return {
		"version": VERSION,
		"bulk": bulk_out,
		"hero": hero.duplicate(true),
		# v2: sparse deltas only — never persist the defaults back to disk.
		"settings": settings.duplicate(true),
		"growth_zones": _zones_to_json(growth_zones),
	}


const TINT_SUFFIX := "_albedo_tint"


## Per-instance "Apply to brush" card_settings can hold Color tints. Plain
## JSON.stringify turns a Color into the string "(r, g, b, a)", so we convert
## tints to [r,g,b,a] arrays on save and back to Color on load — otherwise the
## card factory's typed `Color` assignment throws on reload and the map fails.
static func _zones_to_json(zones: Array) -> Array:
	var out: Array = []
	for poly in zones:
		if poly is PackedVector2Array:
			var pts: Array = []
			for p in poly:
				pts.append([p.x, p.y])
			out.append(pts)
	return out


static func _zones_from_json(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for item in raw:
		if not (item is Array):
			continue
		var poly := PackedVector2Array()
		for pt in item:
			if pt is Array and (pt as Array).size() >= 2:
				poly.append(Vector2(float(pt[0]), float(pt[1])))
		if poly.size() >= 3:
			out.append(poly)
	return out


static func _records_to_json(records: Array) -> Array:
	var out: Array = []
	for item in records:
		if item is Dictionary and (item as Dictionary).has("card_settings"):
			var rec: Dictionary = (item as Dictionary).duplicate()
			rec["card_settings"] = _card_to_json(item["card_settings"])
			out.append(rec)
		else:
			out.append(item)
	return out


static func _records_from_json(records: Array) -> Array:
	var out: Array = []
	for item in records:
		if item is Dictionary and (item as Dictionary).has("card_settings"):
			var rec: Dictionary = (item as Dictionary).duplicate()
			rec["card_settings"] = coerce_card_colors(item["card_settings"] as Dictionary)
			out.append(rec)
		else:
			out.append(item)
	return out


static func _card_to_json(card: Dictionary) -> Dictionary:
	var out := {}
	for k in card:
		var v: Variant = card[k]
		if v is Color:
			var c: Color = v
			out[k] = [c.r, c.g, c.b, c.a]
		else:
			out[k] = v
	return out


## Coerce any *_albedo_tint value (Color, [r,g,b,a] array, or a legacy
## JSON-stringified "(r, g, b, a)" string) back to a real Color so consumers
## that assign to a typed Color never trip. Recovers maps saved before the
## array round-trip fix as well.
static func coerce_card_colors(card: Dictionary) -> Dictionary:
	# Fast path: skip the per-record copy on rebuilds when tints are already
	# Colors (the normal post-load state) so this stays cheap in the hot loop.
	var needs_fix := false
	for k in card:
		if str(k).ends_with(TINT_SUFFIX) and not (card[k] is Color):
			needs_fix = true
			break
	if not needs_fix:
		return card
	var out := card.duplicate()
	for k in out:
		if str(k).ends_with(TINT_SUFFIX):
			out[k] = _as_color(out[k])
	return out


static func _as_color(v: Variant) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]),
			float(a[3]) if a.size() >= 4 else 1.0)
	if v is String:
		var parts := (v as String).strip_edges().trim_prefix("(").trim_suffix(")").split(",")
		if parts.size() >= 3:
			return Color(float(parts[0]), float(parts[1]), float(parts[2]),
				float(parts[3]) if parts.size() >= 4 else 1.0)
	return Color.WHITE


func ensure_species_keys() -> void:
	for species in ALL_SPECIES:
		if species not in bulk:
			bulk[species] = []


func deserialize(data: Dictionary) -> void:
	bulk = {}
	var src: Dictionary = data.get("bulk", {}) as Dictionary
	for species in ALL_SPECIES:
		bulk[species] = _records_from_json(src.get(species, []))
	# Subspecies painted after the earthworks polish (spruce, fir, …).
	for key in src.keys():
		var sid := str(key)
		if sid in ALL_SPECIES:
			continue
		if VegSpeciesCatalog.is_paintable(sid):
			bulk[sid] = _records_from_json(src.get(key, []))
	hero = []
	for item in data.get("hero", []):
		if item is Dictionary:
			hero.append(item)
	growth_zones = _zones_from_json(data.get("growth_zones", []))
	var loaded: Dictionary = {}
	if data.get("settings") is Dictionary:
		loaded = data["settings"]
	if int(data.get("version", 1)) >= 2:
		settings = loaded.duplicate(true)
	else:
		# v1 persisted the complete dict. Keep only true user deltas so the
		# style store stops being shadowed by stale copies of old defaults.
		settings = {}
		var defs := default_settings()
		for k in loaded:
			if defs.has(k) and VegStyleStore.values_equal(defs[k], loaded[k]):
				continue
			settings[k] = loaded[k]

