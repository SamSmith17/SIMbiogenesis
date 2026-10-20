class_name AutoVegetationLayer
extends RefCounted

## Auto-generated, NON-PERSISTED vegetation for a map (ROADMAP Pillar 8 — auto
## land cover). Unlike the user-editable VegetationLayer, this layer is rebuilt
## from real-world data (OSM / WorldCover / canopy-height) on every map load and
## never written to disk, so it cannot collide with or bloat the player's manual
## edits. It renders under a separate "AutoVegetation" terrain child.
##
## Records mirror VegetationLayer's shape (so the same VegetationCardFactory /
## HeroTreeCatalog / VegetationPaint helpers apply) but slot keys are dynamic —
## the biome palette may introduce new mesh slots (palm / conifer / taiga) beyond
## the built-in pine / deciduous / shrub. `height_m` is carried as metadata for
## later phases (canopy-height scaling); the generator bakes the final draw scale
## into `scale`, so the runtime treats records exactly like VegetationLayer's.

## Safety caps for the wider (~3 km) coverage area. Tuned conservatively; the
## generator's spacing is the primary density control.
##
## Grass and trees draw from SEPARATE budgets. They share one bulk dictionary, but
## polygons are scattered biggest-first, and a few large grass areas (farmland,
## meadow, parks) can each emit thousands of blades. Under a single shared cap that
## grass exhausts the budget before the smaller wood polygons are reached, so trees
## silently stop appearing in tagged areas ("veg only shows up in some places").
## Splitting the budgets lets dense grass and dense woods coexist.
const MAX_TREE_BULK_TOTAL := 24000
const MAX_GRASS_BULK_TOTAL := 120000
const MAX_BULK_TOTAL := MAX_TREE_BULK_TOTAL + MAX_GRASS_BULK_TOTAL
const MAX_HERO := 4000

var _grass_bulk := 0
var _tree_bulk := 0
## Per-layer caps (set from style via apply_instance_caps). Default = constants.
var max_tree_bulk: int = MAX_TREE_BULK_TOTAL
var max_grass_bulk: int = MAX_GRASS_BULK_TOTAL


static func _is_grass_slot(slot: String) -> bool:
	if slot in VegetationLayer.GRASS_SPECIES:
		return true
	return VegSpeciesCatalog.mesh_family(slot).begins_with("grass_")


static func create_empty() -> AutoVegetationLayer:
	var layer := AutoVegetationLayer.new()
	layer.bulk = {}
	layer.hero = []
	layer.forests = []
	return layer


## bulk[slot] = [{x, z, yaw, scale, height_m}], slot is a card-factory species id.
var bulk: Dictionary = {}
var hero: Array = []
## Forest zones: sparse trunks + shared canopy mesh per large woodland polygon.
var forests: Array = []


func apply_instance_caps(style: Dictionary) -> void:
	max_tree_bulk = clampi(int(style.get("auto_max_tree_instances", MAX_TREE_BULK_TOTAL)),
		1000, MAX_TREE_BULK_TOTAL)
	max_grass_bulk = clampi(int(style.get("auto_max_grass_instances", MAX_GRASS_BULK_TOTAL)),
		2000, MAX_GRASS_BULK_TOTAL)


func add_bulk(slot: String, x: float, z: float, yaw: float, scale: float,
		height_m: float = 0.0) -> bool:
	var is_grass := _is_grass_slot(slot)
	if is_grass:
		if _grass_bulk >= max_grass_bulk:
			return false
	elif _tree_bulk >= max_tree_bulk:
		return false
	if slot not in bulk:
		bulk[slot] = []
	(bulk[slot] as Array).append({
		"x": x, "z": z, "yaw": yaw, "scale": scale, "height_m": height_m,
	})
	if is_grass:
		_grass_bulk += 1
	else:
		_tree_bulk += 1
	return true


func add_hero(preset: String, x: float, z: float, yaw: float, scale: float,
		height_m: float = 0.0, ground_y: float = NAN) -> bool:
	if hero.size() >= MAX_HERO:
		return false
	var rec := {"preset": preset, "x": x, "z": z, "yaw": yaw, "scale": scale,
		"height_m": height_m}
	if not is_nan(ground_y):
		rec["ground_y"] = ground_y
	hero.append(rec)
	return true


func slots() -> Array:
	return bulk.keys()


## Strip per-instance card_settings overrides from every bulk record (see
## VegetationLayer.clear_card_overrides). Lets "Apply to map" restyle auto (OSM)
## trees that were painted with a custom brush look too. Returns the count cleared.
func clear_card_overrides() -> int:
	var n := 0
	for slot in bulk.keys():
		for item in bulk.get(slot, []):
			if item is Dictionary and (item as Dictionary).has("card_settings"):
				(item as Dictionary).erase("card_settings")
				n += 1
	return n


func tree_bulk_count() -> int:
	return _tree_bulk


func grass_bulk_count() -> int:
	return _grass_bulk


func total_bulk() -> int:
	var n := 0
	for slot in bulk:
		n += (bulk[slot] as Array).size()
	return n


func is_empty() -> bool:
	return total_bulk() == 0 and hero.is_empty() and forests.is_empty()


func clear() -> void:
	bulk = {}
	hero = []
	forests = []
	_grass_bulk = 0
	_tree_bulk = 0


## Recompute the per-class bulk budgets from the current records. Cheap and only
## needed after bulk arrays are rebuilt outside add_bulk() (e.g. removals).
func _recount_bulk() -> void:
	_grass_bulk = 0
	_tree_bulk = 0
	for slot in bulk:
		var count: int = (bulk[slot] as Array).size()
		if _is_grass_slot(str(slot)):
			_grass_bulk += count
		else:
			_tree_bulk += count


func add_forest_zone(polygon: PackedVector2Array, profile: String, params: Dictionary) -> bool:
	if polygon.size() < 3:
		return false
	forests.append({
		"polygon": polygon.duplicate(),
		"profile": profile,
		"canopy_height_m": float(params.get("canopy_height_m", 14.0)),
		"trunk_spacing_m": float(params.get("trunk_spacing_m", 10.0)),
		"seed": int(params.get("seed", _poly_seed(polygon))),
		"source": str(params.get("source", "osm")),
	})
	return true


func remove_forests_in_polygon(poly: PackedVector2Array) -> int:
	if poly.size() < 3:
		return 0
	var kept: Array = []
	var removed := 0
	for rec in forests:
		if not (rec is Dictionary):
			continue
		var fp: PackedVector2Array = (rec as Dictionary).get("polygon", PackedVector2Array())
		if _polygons_overlap(fp, poly):
			removed += 1
		else:
			kept.append(rec)
	forests = kept
	return removed


static func _polygons_overlap(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	for p in a:
		if Geometry2D.is_point_in_polygon(p, b):
			return true
	for p in b:
		if Geometry2D.is_point_in_polygon(p, a):
			return true
	return false


## Remove bulk + hero instances whose (x,z) lies inside `poly`. Returns count removed.
func remove_in_polygon(poly: PackedVector2Array) -> int:
	if poly.size() < 3:
		return 0
	var removed := _remove_bulk_in_polygon(poly)
	removed += _remove_hero_in_polygon(poly)
	removed += remove_forests_in_polygon(poly)
	return removed


func count_bulk_in_polygon(poly: PackedVector2Array) -> int:
	if poly.size() < 3:
		return 0
	var n := 0
	for slot in bulk.keys():
		for item in bulk.get(slot, []):
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
			if Geometry2D.is_point_in_polygon(pt, poly):
				n += 1
	return n


func _remove_bulk_in_polygon(poly: PackedVector2Array) -> int:
	var removed := 0
	for slot in bulk.keys():
		var kept: Array = []
		for item in bulk.get(slot, []):
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
			if Geometry2D.is_point_in_polygon(pt, poly):
				removed += 1
			else:
				kept.append(d)
		bulk[slot] = kept
	if removed > 0:
		_recount_bulk()
	return removed


func _remove_hero_in_polygon(poly: PackedVector2Array) -> int:
	var removed := 0
	var kept: Array = []
	for item in hero:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
		if Geometry2D.is_point_in_polygon(pt, poly):
			removed += 1
		else:
			kept.append(d)
	hero = kept
	return removed


## Apply regional scale / ground-Y / card-shape overrides to instances inside `poly`.
func apply_patch_in_polygon(poly: PackedVector2Array, params: Dictionary,
		bulk_only: bool = false) -> int:
	if poly.size() < 3 or params.is_empty():
		return 0
	var n := _patch_bulk_in_polygon(poly, params)
	if not bulk_only:
		n += _patch_hero_in_polygon(poly, params)
	return n


func _patch_bulk_in_polygon(poly: PackedVector2Array, params: Dictionary) -> int:
	var all_map := bool(params.get("patch_all_map", false))
	if params.is_empty() or (not all_map and poly.size() < 3):
		return 0
	var n := 0
	var scale_mul := float(params.get("scale_mul", 1.0))
	var target := str(params.get("patch_species", ""))
	for slot in bulk.keys():
		var species := str(slot)
		if not target.is_empty() and species != target:
			continue
		var card := VegetationLayer._card_settings_for_species(params, species)
		# A single-tree look pinned by Select → Tune look (AutoVegetationEdits
		# .add_tree_patch). It REPLACES the record's previous one.
		if params.get(VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE) is Dictionary:
			card[VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE] = VegetationLayer.coerce_card_colors(
				params[VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE] as Dictionary)
		for item in bulk.get(slot, []):
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
				d["vert_off"] = VegetationLayer.vertical_offset_for(species, params)
			if not card.is_empty():
				var prev: Dictionary = d.get("card_settings", {}) as Dictionary
				var merged := prev.duplicate()
				merged.merge(card, true)
				d["card_settings"] = merged
			n += 1
	return n


func _patch_hero_in_polygon(poly: PackedVector2Array, params: Dictionary) -> int:
	var n := 0
	var scale_mul := float(params.get("scale_mul", 1.0))
	for item in hero:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
		if not Geometry2D.is_point_in_polygon(pt, poly):
			continue
		if absf(scale_mul - 1.0) > 0.001:
			d["scale"] = float(d.get("scale", 1.0)) * scale_mul
		if params.has("vertical_offset_m"):
			d["vert_off"] = float(params["vertical_offset_m"])
		n += 1
	return n


static func _card_settings_from_params(params: Dictionary) -> Dictionary:
	var out := {}
	for key in [
		# v3 tree model keys (real-world units + archetype + macros).
		"deciduous_height_m", "deciduous_crown_width_m",
		"deciduous_trunk_diameter_cm", "deciduous_crown_base_pct",
		"deciduous_archetype", "deciduous_branchiness", "deciduous_crookedness",
		"deciduous_droop", "deciduous_foliage_density",
		"pine_height_m", "pine_crown_width_m", "pine_trunk_diameter_cm",
		"pine_crown_base_pct", "pine_archetype", "pine_branchiness",
		"pine_crookedness", "pine_droop", "pine_foliage_density",
		"shrub_card_w", "shrub_card_h", "shrub_bulk_scale",
		"grass_lawn_card_w", "grass_lawn_card_h", "grass_lawn_bulk_scale",
		"grass_field_card_w", "grass_field_card_h", "grass_field_bulk_scale",
	]:
		if params.has(key):
			out[key] = params[key]
	return out


## Nearest generated plant to a world point (the Select tool's fallback when
## the ray misses every crown). Same descriptor shape as
## VegetationLayer.nearest_plant, `species` = the layer SLOT.
func nearest_plant(world_xz: Vector2, radius_m: float = 6.0) -> Dictionary:
	var best := {}
	var best_d := radius_m * radius_m
	for slot in bulk.keys():
		var arr: Array = bulk[slot]
		if _is_grass_slot(str(slot)):
			continue
		for i in arr.size():
			if not (arr[i] is Dictionary):
				continue
			var d: Dictionary = arr[i]
			var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
			var dist := pt.distance_squared_to(world_xz)
			if dist < best_d:
				best_d = dist
				best = {"kind": "bulk", "species": str(slot), "index": i,
					"x": pt.x, "z": pt.y, "scale": float(d.get("scale", 1.0)),
					"height_m": float(d.get("height_m", 0.0)), "dist_m": sqrt(dist)}
	return best


func record_for(desc: Dictionary) -> Dictionary:
	var idx := int(desc.get("index", -1))
	if str(desc.get("kind", "bulk")) == "hero":
		return hero[idx] if idx >= 0 and idx < hero.size() and hero[idx] is Dictionary else {}
	var records: Variant = bulk.get(str(desc.get("slot", desc.get("species", ""))), [])
	if not (records is Array) or idx < 0 or idx >= (records as Array).size():
		return {}
	var rec: Variant = (records as Array)[idx]
	return rec if rec is Dictionary else {}


func instance_look(desc: Dictionary) -> Dictionary:
	var card: Variant = record_for(desc).get("card_settings", {})
	if card is Dictionary and (card as Dictionary).get(VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE) is Dictionary:
		return VegetationLayer.coerce_card_colors(
			(card as Dictionary)[VegSpeciesCatalog.KEY_INSTANCE_OVERRIDE]).duplicate(true)
	return {}


func clear_species_looks(slot: String) -> int:
	var n := 0
	for item in bulk.get(slot, []):
		if item is Dictionary and (item as Dictionary).has("card_settings"):
			(item as Dictionary).erase("card_settings")
			n += 1
	return n


## All placement positions (bulk + hero) — used for cross-pass spacing/dedup.
func all_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for slot in bulk:
		for item in bulk[slot]:
			if item is Dictionary:
				out.append(Vector2(float(item.get("x", 0.0)), float(item.get("z", 0.0))))
	for item in hero:
		if item is Dictionary:
			out.append(Vector2(float(item.get("x", 0.0)), float(item.get("z", 0.0))))
	return out


func count_within_radius(cx: float, cz: float, radius_m: float) -> int:
	var r2 := radius_m * radius_m
	var n := 0
	for pt in all_points():
		var dx := pt.x - cx
		var dz := pt.y - cz
		if dx * dx + dz * dz <= r2:
			n += 1
	return n


func nearest_distance(cx: float, cz: float) -> float:
	var best := INF
	for pt in all_points():
		best = minf(best, Vector2(pt.x - cx, pt.y - cz).length())
	return best if is_finite(best) else -1.0


static func _poly_seed(poly: PackedVector2Array) -> int:
	var h := 0
	for p in poly:
		h = h ^ int(p.x * 100.0) ^ int(p.y * 100.0)
	return h
