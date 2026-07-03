class_name AutoVegetationGenerator
extends RefCounted

## Builds an AutoVegetationLayer from real-world data sources.

const PER_POLY_CAP := 14000
const GRASS_PER_POLY_CAP := 6000
const LARGE_WOOD_SCATTER_CAP := 3200
const DENSE_POLY_BUDGET := 640
const DENSE_POLY_SKIP_GAP_FILL := 48
const DENSE_POLY_SCATTER_CAP := 900
const TREE_ROW_SPACING_M := 9.0
const HEDGE_ROW_SPACING_M := 1.8
const ORCHARD_ROW_SPACING_M := 7.5
const ORCHARD_IN_ROW_M := 5.5
const VINEYARD_ROW_SPACING_M := 4.0
const VINEYARD_IN_ROW_M := 2.8
const SCATTER_BATCH_DEFAULT := 5

const NOMINAL_CARD_H := {
	"deciduous": 6.0, "broadleaf": 6.0, "palm": 6.0,
	"conifer": 3.2, "pine": 3.2, "taiga": 3.2,
	"shrub": 0.7, "scrub": 0.7,
}

enum ScatterPhase { POLYS, POINTS, ROWS, HEDGES, GAP_FILL, DONE }


class GeneratorState:
	extends RefCounted

	var layer: AutoVegetationLayer
	var osm_payload: Dictionary = {}
	var ctx: Dictionary = {}
	var polys: Array = []
	var poly_idx := 0
	var point_idx := 0
	var row_idx := 0
	var hedge_idx := 0
	var phase := ScatterPhase.POLYS
	var rng: RandomNumberGenerator
	var biome: Dictionary = {}
	var forest_min_area := 12000.0
	var dense := false
	var exclusion_index: VegExclusionBuilder.ExclusionIndex = null
	var style: Dictionary = {}


	func progress_ratio() -> float:
		var total := 0.0
		var done := 0.0
		total += maxf(float(polys.size()), 1.0)
		done += float(mini(poly_idx, polys.size()))
		var points: Array = osm_payload.get("tree_points", [])
		var rows: Array = osm_payload.get("tree_rows", [])
		total += maxf(float(points.size()), 1.0)
		done += float(mini(point_idx, points.size()))
		total += maxf(float(rows.size()), 1.0)
		done += float(mini(row_idx, rows.size()))
		if not dense and phase >= ScatterPhase.GAP_FILL:
			done += 1.0
		total += 1.0
		return clampf(done / total, 0.0, 1.0)


static func _scale_for(species: String, target_h: float, rng: RandomNumberGenerator) -> float:
	if species == "shrub" or species == "scrub":
		return rng.randf_range(0.8, 1.6)
	var nominal := float(NOMINAL_CARD_H.get(species, 8.0))
	return (target_h / maxf(nominal, 0.1)) * rng.randf_range(0.9, 1.15)


static func generate(osm_payload: Dictionary, ctx: Dictionary) -> AutoVegetationLayer:
	var state := prepare_context(osm_payload, ctx)
	while scatter_batch(state, 999999):
		pass
	return state.layer


static func prepare_context(osm_payload: Dictionary, ctx: Dictionary) -> GeneratorState:
	var state := GeneratorState.new()
	state.layer = AutoVegetationLayer.create_empty()
	state.osm_payload = osm_payload
	state.ctx = ctx
	if osm_payload.is_empty():
		state.phase = ScatterPhase.DONE
		return state
	state.rng = RandomNumberGenerator.new()
	state.rng.seed = int(ctx.get("seed", 1337))
	state.style = ctx.get("style", {})
	state.forest_min_area = float(state.style.get("forest_auto_min_area_m2", 12000.0))
	state.biome = BiomePalette.for_location(float(ctx.get("latitude", 0.0)))
	state.polys = _trim_polygons(osm_payload.get("polygons", []), DENSE_POLY_BUDGET)
	state.dense = state.polys.size() >= DENSE_POLY_SKIP_GAP_FILL
	var exclusions: Array = ctx.get("exclusions", [])
	var half := float(ctx.get("half_extent_m", 1500.0))
	state.exclusion_index = VegExclusionBuilder.build_index(exclusions, half)
	return state


## Process up to `batch_size` polygon records (or one non-poly phase). Returns true while work remains.
static func scatter_batch(state: GeneratorState, batch_size: int = SCATTER_BATCH_DEFAULT) -> bool:
	if state.phase == ScatterPhase.DONE:
		return false
	match state.phase:
		ScatterPhase.POLYS:
			var n := mini(batch_size, state.polys.size() - state.poly_idx)
			for i in n:
				var rec: Variant = state.polys[state.poly_idx + i]
				if rec is Dictionary:
					_scatter_polygon(state.layer, rec as Dictionary, state.biome,
						state.exclusion_index, state.rng, state.ctx,
						state.forest_min_area, state.dense)
			state.poly_idx += n
			if state.poly_idx >= state.polys.size():
				state.phase = ScatterPhase.POINTS
			return state.phase != ScatterPhase.DONE
		ScatterPhase.POINTS:
			var points: Array = state.osm_payload.get("tree_points", [])
			while state.point_idx < points.size():
				var tp: Variant = points[state.point_idx]
				state.point_idx += 1
				if tp is Dictionary:
					_place_tree_point(state.layer, tp as Dictionary, state.biome,
						state.exclusion_index, state.rng, state.ctx)
			state.phase = ScatterPhase.ROWS
			return true
		ScatterPhase.ROWS:
			var rows: Array = state.osm_payload.get("tree_rows", [])
			while state.row_idx < rows.size():
				var tree_row: Variant = rows[state.row_idx]
				state.row_idx += 1
				if tree_row is Dictionary:
					_place_tree_row(state.layer, tree_row as Dictionary, state.biome,
						state.exclusion_index, state.rng, state.ctx)
			state.phase = ScatterPhase.HEDGES
			return true
		ScatterPhase.HEDGES:
			var hedges: Array = state.osm_payload.get("hedge_rows", [])
			while state.hedge_idx < hedges.size():
				var hedge: Variant = hedges[state.hedge_idx]
				state.hedge_idx += 1
				if hedge is Dictionary:
					_place_hedge_row(state.layer, hedge as Dictionary,
						state.exclusion_index, state.rng, state.ctx)
			state.phase = ScatterPhase.GAP_FILL if not state.dense else ScatterPhase.DONE
			return state.phase != ScatterPhase.DONE
		ScatterPhase.GAP_FILL:
			var gate: Object = state.ctx.get("gate")
			if gate != null and gate.is_valid():
				_fill_imagery_gaps(state.layer, state.osm_payload, gate, state.biome,
					state.exclusion_index, state.ctx, state.rng)
			state.phase = ScatterPhase.DONE
			return false
	return false


static func _trim_polygons(raw: Array, max_count: int) -> Array:
	if raw.size() <= max_count:
		return raw
	var ranked: Array = []
	for rec in raw:
		if not (rec is Dictionary):
			continue
		var poly: PackedVector2Array = (rec as Dictionary).get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		ranked.append({"rec": rec, "area": VegetationPaint.polygon_area(poly)})
	ranked.sort_custom(func(a, b): return float(a["area"]) > float(b["area"]))
	var out: Array = []
	for i in mini(ranked.size(), max_count):
		out.append(ranked[i]["rec"])
	return out


const GAP_FILL_SPACING_M := 11.0
const GAP_FILL_MAX := 2500


static func _fill_imagery_gaps(layer: AutoVegetationLayer, osm_payload: Dictionary,
		gate: Object, biome: Dictionary, exclusion_index: VegExclusionBuilder.ExclusionIndex,
		ctx: Dictionary, rng: RandomNumberGenerator) -> void:
	var half := float(ctx.get("half_extent_m", 1500.0))
	if half <= 0.0:
		return
	var weights: Dictionary = biome.get("weights", {"deciduous": 1.0})
	var base_height := float(biome.get("default_height_m", 12.0))
	var osm_polys: Array = []
	for rec in osm_payload.get("polygons", []):
		if rec is Dictionary:
			var pts: PackedVector2Array = (rec as Dictionary).get("points", PackedVector2Array())
			if pts.size() >= 3:
				osm_polys.append(pts)
	var jitter := GAP_FILL_SPACING_M * 0.4
	var added := 0
	var z := -half
	while z <= half:
		var x := -half
		while x <= half:
			x += GAP_FILL_SPACING_M
			var jx := x + rng.randf_range(-jitter, jitter)
			var jz := z + rng.randf_range(-jitter, jitter)
			if not gate.is_vegetated(jx, jz):
				continue
			var p := Vector2(jx, jz)
			if _excluded(p, exclusion_index) or _in_any_polygon(p, osm_polys):
				continue
			if _slope_too_steep(jx, jz, ctx):
				continue
			var f := float(gate.canopy_factor(jx, jz))
			var species := BiomePalette.pick_species(weights, rng)
			var h := lerpf(base_height * 0.7, base_height * 1.25, f)
			if layer.add_bulk(species, jx, jz, rng.randf() * TAU, _scale_for(species, h, rng), h):
				added += 1
				if added >= GAP_FILL_MAX:
					return
		z += GAP_FILL_SPACING_M


static func _in_any_polygon(p: Vector2, polys: Array) -> bool:
	for poly in polys:
		if poly is PackedVector2Array and Geometry2D.is_point_in_polygon(p, poly):
			return true
	return false


static func _scatter_polygon(layer: AutoVegetationLayer, rec: Dictionary,
		biome: Dictionary, exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary, forest_min_area: float, dense_site: bool = false) -> void:
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	if poly.size() < 3:
		return
	var kind := str(rec.get("kind", "wood"))
	var tags: Dictionary = rec.get("tags", {})
	if kind == "grass_lawn" or kind == "grass_field":
		_scatter_grass_polygon(layer, poly, kind, exclusion_index, rng)
		return
	# Player-configured OSM→species override (vegetation modal). Empty = biome/tags.
	var osm_map: Dictionary = (ctx.get("style", {}) as Dictionary).get("osm_species_map", {})
	var override: Dictionary = BiomePalette.species_override_for_kind(osm_map, kind)
	var weights: Dictionary = BiomePalette.weights_for_osm_tags(
		biome.get("weights", {"deciduous": 1.0}), tags)
	if not override.is_empty():
		weights = override.duplicate(true)
	var height := float(biome.get("default_height_m", 12.0))
	match kind:
		"park":
			_scatter_park_polygon(layer, poly, weights, height, exclusion_index, rng, ctx)
			return
		"cemetery":
			_scatter_cemetery_polygon(layer, poly, weights, height, exclusion_index, rng, ctx)
			return
		"orchard":
			_scatter_row_crop_polygon(layer, poly,
				BiomePalette.override_single_species(override, "deciduous"), 6.0,
				ORCHARD_ROW_SPACING_M, ORCHARD_IN_ROW_M, exclusion_index, rng, ctx)
			return
		"vineyard":
			_scatter_row_crop_polygon(layer, poly,
				BiomePalette.override_single_species(override, "deciduous"), 4.5,
				VINEYARD_ROW_SPACING_M, VINEYARD_IN_ROW_M, exclusion_index, rng, ctx)
			return
		"wetland":
			var wet_weights: Dictionary = override if not override.is_empty() else {"shrub": 1.0}
			_scatter_polygon_poisson(layer, poly, wet_weights, 1.2, 3.5,
				exclusion_index, rng, ctx, false)
			return
	var spacing := float(biome.get("spacing_m", 6.0))
	var check_slope := kind != "scrub"
	match kind:
		"scrub":
			spacing = maxf(spacing * 0.85, 3.0)
			if override.is_empty():
				weights = {"shrub": 1.0}
			height = 1.5
		_:
			pass
	_scatter_polygon_poisson(layer, poly, weights, height, spacing, exclusion_index, rng,
		ctx, check_slope, kind, forest_min_area, dense_site)


static func _scatter_polygon_poisson(layer: AutoVegetationLayer, poly: PackedVector2Array,
		weights: Dictionary, height: float, spacing: float,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary, check_slope: bool, kind: String = "wood",
		forest_min_area: float = 12000.0, dense_site: bool = false) -> void:
	var area := VegetationPaint.polygon_area(poly)
	if area < 16.0:
		return
	var style: Dictionary = ctx.get("style", {})
	# Global density knob from the Tune Look modal (auto_density_scale): >1 packs
	# trees tighter (smaller spacing → more instances), <1 thins them out.
	var density_scale := clampf(float(style.get("auto_density_scale", 1.0)), 0.25, 3.0)
	spacing = maxf(spacing / density_scale, 0.5)
	var even_spacing := sqrt(area / float(PER_POLY_CAP))
	spacing = maxf(spacing, even_spacing)
	var est := int(area / (spacing * spacing * 0.866)) + 4

	# Woodland is always scattered as individual card/hero trees — the old
	# canopy-mesh + trunk "forest zone" path was removed (looked wrong, removed by
	# request). Large woods are capped so the scatter stays performant.
	var cap := mini(est, PER_POLY_CAP)
	if kind == "wood" and area >= forest_min_area:
		cap = mini(cap, LARGE_WOOD_SCATTER_CAP)
	if dense_site:
		cap = mini(cap, DENSE_POLY_SCATTER_CAP)
	var edge_feather := float(style.get("forest_edge_feather_m", 20.0))
	var spots := VegetationPaint.poisson_fill(poly, spacing, rng, [] as Array[Vector2], cap)
	for spot in spots:
		var p := Vector2(float(spot["x"]), float(spot["z"]))
		if _excluded(p, exclusion_index):
			continue
		if check_slope and _slope_too_steep(p.x, p.y, ctx):
			continue
		var edge_w := _edge_spawn_weight(p, poly, edge_feather)
		if rng.randf() > edge_w:
			continue
		var species := BiomePalette.pick_species(weights, rng)
		layer.add_bulk(species, p.x, p.y, rng.randf() * TAU,
			_scale_for(species, height, rng), height)


static func _scatter_grass_polygon(layer: AutoVegetationLayer, poly: PackedVector2Array,
		kind: String, exclusion_index: VegExclusionBuilder.ExclusionIndex,
		rng: RandomNumberGenerator) -> void:
	var area := VegetationPaint.polygon_area(poly)
	if area < 4.0:
		return
	var cap := mini(VegetationPaint.GRASS_FILL_CAP, GRASS_PER_POLY_CAP)
	var spots: Array[Dictionary]
	if kind == "grass_lawn":
		var mat_w := float(GrassBuilder.SPECS["grass_lawn"]["mat_w"])
		var est := VegetationPaint.estimate_hex_fill_count(poly, mat_w, cap)
		cap = mini(est, cap)
		spots = VegetationPaint.hex_grid_fill(poly, mat_w, [] as Array[Vector2], cap)
	else:
		var preset := VegetationPaint.Preset.GRASS_FIELD
		var spacing := VegetationPaint.default_spacing_for_preset(preset)
		var even_spacing := sqrt(area / float(GRASS_PER_POLY_CAP))
		spacing = maxf(spacing, even_spacing)
		var est := int(area / (spacing * spacing * 0.866)) + 4
		cap = mini(mini(est, GRASS_PER_POLY_CAP), VegetationPaint.GRASS_FILL_CAP)
		spots = VegetationPaint.poisson_fill(poly, spacing, rng, [] as Array[Vector2], cap)
	for spot in spots:
		var p := Vector2(float(spot["x"]), float(spot["z"]))
		if _excluded(p, exclusion_index):
			continue
		if kind == "grass_lawn":
			layer.add_bulk(kind, p.x, p.y, 0.0, 1.0, 0.0)
		else:
			layer.add_bulk(kind, p.x, p.y, rng.randf() * TAU, rng.randf_range(0.75, 1.15), 0.0)


static func _scatter_park_polygon(layer: AutoVegetationLayer, poly: PackedVector2Array,
		weights: Dictionary, height: float,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary) -> void:
	_scatter_grass_polygon(layer, poly, "grass_lawn", exclusion_index, rng)
	_scatter_polygon_poisson(layer, poly, weights, height * 0.85, 14.0,
		exclusion_index, rng, ctx, true, "wood", 999999.0, false)


static func _scatter_cemetery_polygon(layer: AutoVegetationLayer, poly: PackedVector2Array,
		weights: Dictionary, height: float,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary) -> void:
	_scatter_grass_polygon(layer, poly, "grass_lawn", exclusion_index, rng)
	_scatter_polygon_poisson(layer, poly, weights, height * 0.7, 12.0,
		exclusion_index, rng, ctx, true, "wood", 999999.0, false)


static func _scatter_row_crop_polygon(layer: AutoVegetationLayer, poly: PackedVector2Array,
		species: String, target_h: float, row_spacing: float, in_row_spacing: float,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary) -> void:
	var bounds := _poly_bounds(poly)
	if bounds.is_empty():
		return
	var z := float(bounds["min_z"])
	var flip := false
	while z <= float(bounds["max_z"]):
		var x := float(bounds["min_x"]) if not flip else float(bounds["max_x"])
		var x_end := float(bounds["max_x"]) if not flip else float(bounds["min_x"])
		var step := in_row_spacing if not flip else -in_row_spacing
		while (not flip and x <= x_end + 0.001) or (flip and x >= x_end - 0.001):
			var p := Vector2(x, z)
			if Geometry2D.is_point_in_polygon(p, poly) and not _excluded(p, exclusion_index) \
					and not _slope_too_steep(p.x, p.y, ctx):
				layer.add_bulk(species, p.x, p.y, rng.randf() * TAU,
					_scale_for(species, target_h, rng), target_h)
			x += step
		z += row_spacing
		flip = not flip


static func _poly_bounds(poly: PackedVector2Array) -> Dictionary:
	if poly.is_empty():
		return {}
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_z := poly[0].y
	var max_z := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	return {"min_x": min_x, "max_x": max_x, "min_z": min_z, "max_z": max_z}


static func _place_hedge_row(layer: AutoVegetationLayer, hedge: Dictionary,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary) -> void:
	var pts: PackedVector2Array = hedge.get("points", PackedVector2Array())
	if pts.size() < 2:
		return
	var carry := 0.0
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 0.001:
			continue
		var dir := seg / seg_len
		var d := carry
		while d < seg_len:
			var p := a + dir * d
			if not _excluded(p, exclusion_index) and not _slope_too_steep(p.x, p.y, ctx):
				layer.add_bulk("shrub", p.x, p.y, rng.randf() * TAU,
					rng.randf_range(0.9, 1.3), 1.2)
			d += HEDGE_ROW_SPACING_M
		carry = d - seg_len


static func _edge_spawn_weight(p: Vector2, poly: PackedVector2Array, feather_m: float) -> float:
	if feather_m <= 0.0:
		return 1.0
	var d := _dist_to_edge(p, poly)
	return clampf(d / feather_m, 0.35, 1.0)


static func _dist_to_edge(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 1e-8:
			best = minf(best, p.distance_to(a))
			continue
		var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best if is_finite(best) else 0.0


static func _slope_too_steep(x: float, z: float, ctx: Dictionary) -> bool:
	var style: Dictionary = ctx.get("style", {})
	var max_deg := float(style.get("slope_max_deg", 25.0))
	if max_deg <= 0.0:
		return false
	var gy_v: Variant = ctx.get("ground_y_at")
	if not (gy_v is Callable):
		return false
	var gy: Callable = gy_v
	if not gy.is_valid():
		return false
	var h0 := float(gy.call(x, z))
	var h1 := float(gy.call(x + 4.0, z))
	var slope_deg := rad_to_deg(atan(absf(h1 - h0) / 4.0))
	return slope_deg > max_deg


static func _place_tree_point(layer: AutoVegetationLayer, tp: Dictionary,
		biome: Dictionary, exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary) -> void:
	var p: Vector2 = tp.get("pos", Vector2.ZERO)
	if _excluded(p, exclusion_index) or _slope_too_steep(p.x, p.y, ctx):
		return
	var h := float(tp.get("height_m", 0.0))
	if h <= 0.0:
		h = float(biome.get("default_height_m", 12.0))
	var weights: Dictionary = biome.get("weights", {"deciduous": 1.0})
	var species := BiomePalette.pick_species(weights, rng)
	layer.add_bulk(species, p.x, p.y, rng.randf() * TAU, _scale_for(species, h, rng), h)


static func _place_tree_row(layer: AutoVegetationLayer, tree_row: Dictionary,
		biome: Dictionary, exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary) -> void:
	var pts: PackedVector2Array = tree_row.get("points", PackedVector2Array())
	if pts.size() < 2:
		return
	var weights: Dictionary = biome.get("weights", {"deciduous": 1.0})
	var height := float(biome.get("default_height_m", 10.0))
	var carry := 0.0
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 0.001:
			continue
		var dir := seg / seg_len
		var d := carry
		while d < seg_len:
			var p := a + dir * d
			if not _excluded(p, exclusion_index) and not _slope_too_steep(p.x, p.y, ctx):
				var species := BiomePalette.pick_species(weights, rng)
				layer.add_bulk(species, p.x, p.y, rng.randf() * TAU,
					_scale_for(species, height, rng), height)
			d += TREE_ROW_SPACING_M
		carry = d - seg_len


static func _excluded(p: Vector2, exclusion_index: VegExclusionBuilder.ExclusionIndex) -> bool:
	if exclusion_index == null:
		return false
	return exclusion_index.is_excluded(p)
