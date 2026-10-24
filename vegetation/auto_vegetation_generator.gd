class_name AutoVegetationGenerator
extends RefCounted

## Builds an AutoVegetationLayer from real-world data sources.

const PER_POLY_CAP := 14000
const GRASS_PER_POLY_CAP := 35000
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

## Clamp for OSM natural=tree height tags — mis-entered or mis-parsed values
## (feet read as meters) otherwise produce skyscraper hero trees. ~45 m covers
## the tallest realistically mapped urban/park trees.
const TREE_POINT_MIN_HEIGHT_M := 4.0
const TREE_POINT_MAX_HEIGHT_M := 45.0

## Wetland shrub scatter may claim at most this share of the tree bulk budget.
## Sites like Canaan (92 wetland polygons vs 66 woods) otherwise let wetland
## shrubs drain MAX_TREE_BULK_TOTAL before any wood polygon scatters.
const WETLAND_TREE_BUDGET_SHARE := 0.35

## Partition of AutoVegetationLayer.MAX_GRASS_BULK_TOTAL (40000). Without these
## sub-budgets, park/cemetery lawn underlay drained ~31k first-come at the
## Canaan site, leaving 25 of 29 meadows and all 8 lawn polygons bare.
const GRASS_LAWN_BUDGET := 40000
const GRASS_UNDERLAY_BUDGET := 30000
const GRASS_FIELD_BUDGET := 50000

## Dense 3D grass is only generated within this radius of the site centre (the
## player spawn); the whole 3-km site can't be grassed at close-up density
## within budget, and grass past MID visibility (~220 m) never renders anyway.
## Concentrating the budget here is what makes grass read as real up close
## instead of a few starved tufts spread thin over distant meadows.
## Overridable via the `grass_detail_radius_m` style key.
const GRASS_DETAIL_RADIUS_M := 150.0

## Scatter order under the shared tree budget: tree-bearing kinds first so
## budget exhaustion trims understory/shrub kinds, never the woods. Within a
## priority band, largest polygons scatter first (deterministic exhaustion).
const KIND_SCATTER_PRIORITY := {
	"wood": 0, "orchard": 1, "vineyard": 1, "park": 2, "cemetery": 2,
	"scrub": 3, "wetland": 4, "grass_lawn": 5, "grass_field": 5,
}

const NOMINAL_CARD_H := {
	"deciduous": 6.0, "broadleaf": 6.0, "palm": 9.0,
	"conifer": 3.2, "pine": 3.2, "taiga": 3.2,
	"spruce": 3.6, "cedar": 3.4, "fir": 3.8, "redwood": 6.0, "hemlock": 3.6,
	"alder": 5.0, "oak": 4.5, "sword_fern": 0.9, "blackberry": 1.2, "douglas_fir": 4.0,
	"bracken": 1.1, "salal": 0.9,
	"chestnut": 6.5, "maple": 6.0, "cottonwood": 7.0, "aspen": 5.5,
	"birch": 5.0, "beech": 6.0, "apple": 4.0, "pear": 4.2,
	"orange": 3.5, "avocado": 5.0,
	# Phase 5 registry species (palm heights are TRUNK height in SPECS).
	"coconut_palm": 14.0, "date_palm": 12.0, "fan_palm": 8.0,
	"saguaro": 6.0, "prickly_pear": 1.2,
	"walnut": 5.5, "olive": 3.6, "mango": 5.5, "banana": 3.5,
	"ficus": 6.0, "acacia": 4.0,
	"shrub": 0.7, "scrub": 0.7, "cactus": 2.2, "joshua_tree": 3.2,
	"corn": 1.6, "wheat": 0.9, "lettuce": 0.25,
}

## FILLS (Phase 7) runs LAST: a player-authored per-area fill is the most
## explicit instruction on the map, so it gets whatever budget the OSM scatter
## left AND it is allowed to replace what the generator already put there.
enum ScatterPhase { POLYS, POINTS, ROWS, HEDGES, GAP_FILL, FILLS, DONE }


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
	## Explicitly-mapped features (natural=tree points, tree_rows, hedges) scatter
	## FIRST: they are individually surveyed data and must not silently vanish
	## because the polygon scatter already spent the shared tree budget (they
	## used to run last and ignore the add_bulk return).
	var phase := ScatterPhase.POINTS
	## Aggregate placed/rej_budget counters for points/rows/hedges (the poly_stats
	## table only covers polygons); consumed by the loader's post-scatter diag.
	## Pre-seeded because _stat() treats an EMPTY dict as "stats not requested".
	var feature_stats: Dictionary = {
		"points_placed": 0, "points_rej_budget": 0,
		"rows_placed": 0, "rows_rej_budget": 0,
		"hedges_placed": 0, "hedges_rej_budget": 0,
	}
	var rng: RandomNumberGenerator
	var biome: Dictionary = {}
	var forest_min_area := 12000.0
	var dense := false
	var exclusion_index: VegExclusionBuilder.ExclusionIndex = null
	var style: Dictionary = {}
	## Per-polygon scatter diagnostics: {kind, tag, area_m2, candidates, placed,
	## rej_excluded, rej_slope, rej_open, rej_edge, rej_budget}. Consumed by the
	## loader's post-scatter summary and (later) the veg-area inspector UI.
	var poly_stats: Array = []
	## Player per-area fills (AutoVegetationEdits.fills), replayed by the FILLS
	## phase. Per-fill {tag, placed} lands in fill_stats for the loader's toast.
	var fills: Array = []
	var fill_idx := 0
	var fill_stats: Array = []


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
		total += maxf(float(fills.size()), 0.0)
		done += float(mini(fill_idx, fills.size()))
		return clampf(done / total, 0.0, 1.0)


## Biome weights with shrub/scrub removed — an explicitly mapped natural=tree point
## should always become a tree (deciduous/pine), never a shrub. Falls back to
## deciduous when a biome has no tree species at all.
static func _tree_only_weights(biome: Dictionary) -> Dictionary:
	var weights: Dictionary = biome.get("weights", {"deciduous": 1.0})
	var out := {}
	for sp in weights:
		if sp == "shrub" or sp == "scrub":
			continue
		out[sp] = weights[sp]
	if out.is_empty():
		return {"deciduous": 1.0}
	return out


## Per-run resolved tree heights (species id → metres). v3 tree meshes are
## exact-size (AABB-normalized to <fam>_height_m), so a record's scale is
## simply osm_target / resolved_height — set once per generator run in
## prepare_context/apply_fill from the run's style. Non-tree species keep the
## NOMINAL_CARD_H convention (their builders are not exact-size).
static var _run_height_cache: Dictionary = {}
static var _run_style: Dictionary = {}


static func _set_run_style(style: Dictionary) -> void:
	_run_style = style
	_run_height_cache = {}


static func _resolved_tree_height(species: String) -> float:
	if _run_height_cache.has(species):
		return float(_run_height_cache[species])
	var fam := VegSpeciesCatalog.mesh_family(species)
	var resolved := VegSpeciesCatalog.settings_with_variant(species, _run_style,
		VegetationCardFactory.SPECS)
	var h := float(resolved.get("%s_height_m" % fam,
		17.0 if fam == "pine" else 14.0))
	_run_height_cache[species] = h
	return h


static func _scale_for(species: String, target_h: float, rng: RandomNumberGenerator) -> float:
	if species == "shrub" or species == "scrub":
		return rng.randf_range(0.8, 1.6)
	var fam := VegSpeciesCatalog.mesh_family(species)
	if fam == "deciduous" or fam == "pine":
		# Exact-size meshes: scale IS target/authored. No target (0) = render at
		# the species' authored height.
		if target_h <= 0.05:
			return rng.randf_range(0.9, 1.15)
		return (target_h / maxf(_resolved_tree_height(species), 0.5)) \
			* rng.randf_range(0.9, 1.15)
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
	var style: Dictionary = (ctx.get("style", {}) as Dictionary).duplicate(true)
	var half := float(ctx.get("half_extent_m", 1500.0))
	# Large world maps (Mt. Vernon 30 km) — thin + prefer FAR billboards. The
	# leafy NEAR canopy LOD is the prim bomb (×2 MultiMeshes of high-poly shells).
	# Phase 4: when the loader applied a RenderProfile veg tier
	# (veg_quality_managed), its caps/rings/cull distances are authoritative
	# and this legacy fallback must not fight them (it used to silently clamp
	# even an ULTRA budget back to 4000 trees). The fallback still protects
	# direct generate() callers (selftests, tools) on huge extents.
	if half >= 8000.0 and not bool(style.get("veg_quality_managed", false)):
		if int(style.get("auto_max_tree_instances", 24000)) >= 10000:
			style["auto_max_tree_instances"] = 4000
		if int(style.get("auto_max_grass_instances", 120000)) >= 36000:
			style["auto_max_grass_instances"] = 24000
		if absf(float(style.get("auto_density_scale", 1.0)) - 1.0) < 0.02 \
				or float(style.get("auto_density_scale", 1.0)) >= 0.44:
			style["auto_density_scale"] = 0.35
		if absf(float(style.get("auto_distant_density", 0.35)) - 0.35) < 0.02 \
				or float(style.get("auto_distant_density", 0.35)) >= 0.07:
			style["auto_distant_density"] = 0.05
		if float(style.get("auto_detail_radius_m", 800.0)) >= 440.0:
			style["auto_detail_radius_m"] = 350.0
		if float(style.get("grass_detail_radius_m", 500.0)) >= 270.0:
			style["grass_detail_radius_m"] = 220.0
		if float(style.get("grass_visibility_end_m", 520.0)) >= 310.0:
			style["grass_visibility_end_m"] = 260.0
		if float(style.get("auto_visibility_end_m", 1200.0)) >= 640.0:
			style["auto_visibility_end_m"] = 480.0
	state.style = style
	ctx["style"] = style
	_set_run_style(style)
	state.layer.apply_instance_caps(state.style)
	state.forest_min_area = float(state.style.get("forest_auto_min_area_m2", 12000.0))
	state.biome = BiomePalette.for_location(float(ctx.get("latitude", 0.0)))
	# Phase 5: climate-envelope gate. Species outside their registry latitude
	# range are dropped from the AUTO mix and the remainder renormalized (a
	# coconut palm never auto-scatters at 48°N; a spruce never in the tropics).
	# Player OVERRIDES are deliberately not gated — painting/binding a species
	# out of envelope is an explicit choice.
	# Phase 6: when the caller measured the site's winter minimum from real
	# weather it also gates cold-hardiness, so a mild-winter 45°N site can carry
	# species a continental 45°N site would kill. Absent (NAN) = latitude only.
	var bw: Variant = state.biome.get("weights", {})
	if bw is Dictionary:
		state.biome["weights"] = VegSpeciesRegistry.filter_weights_by_climate(
			bw as Dictionary, float(ctx.get("latitude", 0.0)),
			float(ctx.get("winter_min_c", NAN)))
	# Phase 7: player per-area fills, replayed as the last scatter phase.
	var raw_fills: Variant = ctx.get("fills", [])
	state.fills = (raw_fills as Array).duplicate() if raw_fills is Array else []
	state.polys = _sort_polys_for_budget(
		_trim_polygons(osm_payload.get("polygons", []), DENSE_POLY_BUDGET))
	state.dense = state.polys.size() >= DENSE_POLY_SKIP_GAP_FILL
	var exclusions: Array = ctx.get("exclusions", [])
	var extra: Variant = ctx.get("exclude_fn", Callable())
	state.exclusion_index = VegExclusionBuilder.build_index(exclusions, half,
		extra if extra is Callable else Callable())
	# Meadow/lawn footprints veto tree scatter from overlapping polygons (a
	# wood polygon drawn over a mapped meadow must not forest it). Threaded via
	# ctx so the static scatter helpers can reach it without signature churn.
	if bool(state.style.get("open_areas_exclude_trees", true)):
		# Payload is hard-capped at VegetationService.MAX_POLYGONS_RETAINED (open
		# areas preferred). Do NOT scan uncapped multi-million caches.
		ctx["open_areas"] = _build_open_area_index(osm_payload.get("polygons", []))
	# Wetland shrubs draw from the shared tree budget; cap their cumulative share.
	ctx["wetland_bulk_max"] = int(state.layer.max_tree_bulk * WETLAND_TREE_BUDGET_SHARE)
	ctx["tree_detail_radius_m"] = float(state.style.get("auto_detail_radius_m", 800.0))
	ctx["tree_distant_density"] = clampf(float(state.style.get("auto_distant_density", 0.35)),
		0.0, 1.0)
	ctx["wetland_bulk_used"] = 0
	# Grass sub-budget counters. Combined with the near-first poly ordering and
	# the detail radius, the near meadows/lawns fill densely (matching the Tune
	# Look studio) before the budget runs out; distant grass relies on the
	# terrain photo drape (and never renders past MID visibility anyway).
	ctx["grass_lawn_used"] = 0
	ctx["grass_underlay_used"] = 0
	ctx["grass_field_used"] = 0
	ctx["grass_detail_radius_m"] = float(state.style.get(
		"grass_detail_radius_m", GRASS_DETAIL_RADIUS_M))
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
					var stat: Dictionary = {}
					_scatter_polygon(state.layer, rec as Dictionary, state.biome,
						state.exclusion_index, state.rng, state.ctx,
						state.forest_min_area, state.dense, stat)
					if not stat.is_empty():
						state.poly_stats.append(stat)
			state.poly_idx += n
			if state.poly_idx >= state.polys.size():
				state.phase = ScatterPhase.GAP_FILL if not state.dense else ScatterPhase.FILLS
			return state.phase != ScatterPhase.DONE
		ScatterPhase.POINTS:
			var points: Array = state.osm_payload.get("tree_points", [])
			while state.point_idx < points.size():
				var tp: Variant = points[state.point_idx]
				state.point_idx += 1
				if tp is Dictionary:
					_place_tree_point(state.layer, tp as Dictionary, state.biome,
						state.exclusion_index, state.rng, state.ctx, state.feature_stats)
			state.phase = ScatterPhase.ROWS
			return true
		ScatterPhase.ROWS:
			var rows: Array = state.osm_payload.get("tree_rows", [])
			while state.row_idx < rows.size():
				var tree_row: Variant = rows[state.row_idx]
				state.row_idx += 1
				if tree_row is Dictionary:
					_place_tree_row(state.layer, tree_row as Dictionary, state.biome,
						state.exclusion_index, state.rng, state.ctx, state.feature_stats)
			state.phase = ScatterPhase.HEDGES
			return true
		ScatterPhase.HEDGES:
			var hedges: Array = state.osm_payload.get("hedge_rows", [])
			while state.hedge_idx < hedges.size():
				var hedge: Variant = hedges[state.hedge_idx]
				state.hedge_idx += 1
				if hedge is Dictionary:
					_place_hedge_row(state.layer, hedge as Dictionary,
						state.exclusion_index, state.rng, state.ctx, state.feature_stats)
			state.phase = ScatterPhase.POLYS
			return true
		ScatterPhase.GAP_FILL:
			var gate: Object = state.ctx.get("gate")
			if gate != null and gate.is_valid():
				_fill_imagery_gaps(state.layer, state.osm_payload, gate, state.biome,
					state.exclusion_index, state.ctx, state.rng)
			state.phase = ScatterPhase.FILLS
			return true
		ScatterPhase.FILLS:
			var n_fills := mini(maxi(batch_size / 8, 1), state.fills.size() - state.fill_idx)
			for i in n_fills:
				var fl: Variant = state.fills[state.fill_idx + i]
				if fl is Dictionary:
					state.fill_stats.append(
						apply_fill(state.layer, fl as Dictionary, state.biome,
							state.exclusion_index, state.ctx))
			state.fill_idx += n_fills
			if state.fill_idx >= state.fills.size():
				state.phase = ScatterPhase.DONE
				return false
			return true
	return false


## Scatter ONE player-authored area fill. Shared by the generator's FILLS phase
## and the loader's incremental "fill this area now" path, so a fill applied
## live and the same fill replayed on the next load produce the same forest:
## the RNG is seeded per fill, not from the run.
##
## Returns {tag, placed, removed} for the caller's toast/diagnostics.
static func apply_fill(layer: AutoVegetationLayer, fill: Dictionary,
		biome: Dictionary, exclusion_index: VegExclusionBuilder.ExclusionIndex,
		ctx: Dictionary) -> Dictionary:
	_set_run_style(ctx.get("style", {}) as Dictionary)
	var tag := str(fill.get("tag", ""))
	var poly: PackedVector2Array = fill.get("polygon", PackedVector2Array())
	var out := {"tag": tag, "placed": 0, "removed": 0}
	if layer == null or poly.size() < 3:
		return out
	if bool(fill.get("replace", true)):
		out["removed"] = layer.remove_in_polygon(poly)
	var species := str(fill.get("species", "deciduous"))
	var style_d: Dictionary = ctx.get("style", {})
	var weights := fill_weights(species, biome, style_d)
	if weights.is_empty():
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = int(fill.get("seed", 1337))
	var height := float(fill.get("height_m", 0.0))
	if height <= 0.0:
		height = float(biome.get("default_height_m", 12.0))
	# Density scales SPACING, not a count: the poisson scatter is what decides
	# how many trees an area can hold, and the player is asking for a denser or
	# thinner stand of the same forest.
	var density := clampf(float(fill.get("density", 1.0)), 0.05, 4.0)
	var spacing := maxf(float(biome.get("spacing_m", 6.0)) / sqrt(density), 1.5)
	if _is_shrub_only(weights):
		spacing = maxf(spacing * 0.85, 2.0)
		if float(fill.get("height_m", 0.0)) <= 0.0:
			height = 1.5
	var stats := {}
	# forest_min_area 999999 disables the "big woods thin out" rule: the player
	# drew this outline deliberately, whatever its size.
	out["placed"] = _scatter_polygon_poisson(layer, poly, weights, height, spacing,
		exclusion_index, rng, ctx, true, "fill", 999999.0, false, stats)
	return out


## The species-weight dict a fill choice resolves to. "auto" keeps the biome mix
## (climate-gated in prepare_context), "mixed" honours the player's tuned
## mixed-woodland composition, and anything else is that one species.
static func fill_weights(species: String, biome: Dictionary, style: Dictionary) -> Dictionary:
	match species:
		"", "auto":
			var bw: Variant = biome.get("weights", {"deciduous": 1.0})
			return (bw as Dictionary).duplicate(true) if bw is Dictionary else {"deciduous": 1.0}
		"mixed":
			var mix := BiomePalette.mix_weights_from_style(style)
			return mix if not mix.is_empty() else {"pine": 0.5, "deciduous": 0.5}
	return {species: 1.0}


static func _is_shrub_only(weights: Dictionary) -> bool:
	for k in weights:
		if VegSpeciesCatalog.mesh_family(str(k)) != "shrub":
			return false
	return not weights.is_empty()


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
## Bounds for the gap-fill scan itself. GAP_FILL_MAX only capped PLACEMENTS —
## the grid walk still visited every 11 m cell of the whole site square, with a
## linear point-in-polygon test per sample: ~7.4M samples on a 15 km half-extent,
## synchronously inside one scatter_batch call (a hard frame freeze on any large
## map sparse enough to skip the dense-site bypass). Clamp the scanned square to
## the site core and hard-cap total samples.
const GAP_FILL_SCAN_HALF_MAX_M := 1750.0
const GAP_FILL_MAX_SAMPLES := 200000


static func _fill_imagery_gaps(layer: AutoVegetationLayer, osm_payload: Dictionary,
		gate: Object, biome: Dictionary, exclusion_index: VegExclusionBuilder.ExclusionIndex,
		ctx: Dictionary, rng: RandomNumberGenerator) -> void:
	var half := float(ctx.get("half_extent_m", 1500.0))
	if half <= 0.0:
		return
	half = minf(half, GAP_FILL_SCAN_HALF_MAX_M)
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
	var samples := 0
	var z := -half
	while z <= half:
		var x := -half
		while x <= half:
			x += GAP_FILL_SPACING_M
			samples += 1
			if samples > GAP_FILL_MAX_SAMPLES:
				return
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


## Kind-priority band (KIND_SCATTER_PRIORITY) then NEAREST-to-spawn first. Under
## a bounded budget the player experiences vegetation near them, so the wood
## behind the house and the meadow down the street must scatter before distant
## polygons of the same kind claim the budget. Spawn is the site centre (origin).
static func _sort_polys_for_budget(polys: Array) -> Array:
	var ranked: Array = []
	for rec in polys:
		if not (rec is Dictionary):
			continue
		var d: Dictionary = rec
		var poly: PackedVector2Array = d.get("points", PackedVector2Array())
		ranked.append({
			"rec": d,
			"pri": int(KIND_SCATTER_PRIORITY.get(str(d.get("kind", "wood")), 3)),
			"dist": _poly_dist_to_origin(poly),
		})
	ranked.sort_custom(func(a, b):
		if int(a["pri"]) != int(b["pri"]):
			return int(a["pri"]) < int(b["pri"])
		return float(a["dist"]) < float(b["dist"]))
	var out: Array = []
	for r in ranked:
		out.append(r["rec"])
	return out


## Distance from the site centre to the polygon's nearest edge (0 if origin is
## inside it) — the proximity key that puts the vegetation around the player first.
static func _poly_dist_to_origin(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return INF
	if Geometry2D.is_point_in_polygon(Vector2.ZERO, poly):
		return 0.0
	return _dist_to_edge(Vector2.ZERO, poly)


## Open ground (mapped meadow/lawn) polygons as {poly, rect} for the tree-scatter
## veto; the Rect2 prefilter keeps the point-in-polygon cost near zero for
## non-overlapping areas.
static func _build_open_area_index(raw_polys: Array) -> Array:
	var out: Array = []
	for rec in raw_polys:
		if not (rec is Dictionary):
			continue
		var d: Dictionary = rec
		var kind := str(d.get("kind", ""))
		if kind != "grass_lawn" and kind != "grass_field":
			continue
		var poly: PackedVector2Array = d.get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		var b := _poly_bounds(poly)
		out.append({"poly": poly, "rect": Rect2(
			float(b["min_x"]), float(b["min_z"]),
			float(b["max_x"]) - float(b["min_x"]),
			float(b["max_z"]) - float(b["min_z"]))})
	return out


static func _in_open_area(p: Vector2, ctx: Dictionary) -> bool:
	var areas: Array = ctx.get("open_areas", [])
	for entry in areas:
		var e: Dictionary = entry
		if not (e["rect"] as Rect2).has_point(p):
			continue
		if Geometry2D.is_point_in_polygon(p, e["poly"]):
			return true
	return false


static func _stat(stats: Dictionary, key: String, n: int = 1) -> void:
	if stats.is_empty():
		return
	stats[key] = int(stats.get(key, 0)) + n


static func _primary_tag(tags: Dictionary, kind: String) -> String:
	for k in ["natural", "landuse", "leisure"]:
		if tags.has(k):
			return "%s=%s" % [k, str(tags[k])]
	return kind


static func _scatter_polygon(layer: AutoVegetationLayer, rec: Dictionary,
		biome: Dictionary, exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary, forest_min_area: float, dense_site: bool = false,
		stats: Dictionary = {}) -> void:
	var poly: PackedVector2Array = rec.get("points", PackedVector2Array())
	if poly.size() < 3:
		return
	var kind := str(rec.get("kind", "wood"))
	var tags: Dictionary = rec.get("tags", {})
	stats["kind"] = kind
	stats["tag"] = _primary_tag(tags, kind)
	stats["area_m2"] = VegetationPaint.polygon_area(poly)
	for key in ["candidates", "placed", "rej_excluded", "rej_slope", "rej_open",
			"rej_edge", "rej_budget", "rej_distant"]:
		stats[key] = 0
	# Player-configured OSM→species override (vegetation modal). Empty = biome/tags.
	var style_d: Dictionary = ctx.get("style", {})
	# Default: no 3D grass for OSM meadow/lawn/field (ortho shows landcover).
	# Opt in via style.scatter_lawn_field (selftests / advanced paint).
	if not BiomePalette.should_auto_scatter(kind) \
			and not bool(style_d.get("scatter_lawn_field", false)):
		return
	if kind == "grass_lawn" or kind == "grass_field":
		var bkey := "grass_lawn_used" if kind == "grass_lawn" else "grass_field_used"
		var budget := GRASS_LAWN_BUDGET if kind == "grass_lawn" else GRASS_FIELD_BUDGET
		var used := int(ctx.get(bkey, 0))
		if used >= budget:
			_stat(stats, "rej_budget")
			return
		var placed := _scatter_grass_polygon(layer, poly, kind, exclusion_index, rng, ctx,
			stats, budget - used)
		ctx[bkey] = used + placed
		return
	var osm_map: Dictionary = style_d.get("osm_species_map", {})
	var override: Dictionary = BiomePalette.species_override_for_kind(osm_map, kind,
		BiomePalette.mix_weights_from_style(style_d))
	var weights: Dictionary = BiomePalette.weights_for_osm_tags(
		biome.get("weights", {"deciduous": 1.0}), tags)
	if not override.is_empty():
		weights = override.duplicate(true)
	var height := float(biome.get("default_height_m", 12.0))
	match kind:
		"park":
			_scatter_park_polygon(layer, poly, weights, height, exclusion_index, rng, ctx, stats)
			return
		"cemetery":
			_scatter_cemetery_polygon(layer, poly, weights, height, exclusion_index, rng, ctx, stats)
			return
		"orchard":
			_scatter_row_crop_polygon(layer, poly,
				BiomePalette.override_single_species(override, "deciduous"), 6.0,
				ORCHARD_ROW_SPACING_M, ORCHARD_IN_ROW_M, exclusion_index, rng, ctx, stats)
			return
		"vineyard":
			_scatter_row_crop_polygon(layer, poly,
				BiomePalette.override_single_species(override, "deciduous"), 4.5,
				VINEYARD_ROW_SPACING_M, VINEYARD_IN_ROW_M, exclusion_index, rng, ctx, stats)
			return
		"wetland":
			var wet_weights: Dictionary = override if not override.is_empty() else {"shrub": 1.0}
			var wet_max := int(ctx.get("wetland_bulk_max", -1))
			var wet_used := int(ctx.get("wetland_bulk_used", 0))
			if wet_max >= 0 and wet_used >= wet_max:
				_stat(stats, "rej_budget")
				return
			var wet_cap := (wet_max - wet_used) if wet_max >= 0 else -1
			var wet_placed := _scatter_polygon_poisson(layer, poly, wet_weights, 1.2, 3.5,
				exclusion_index, rng, ctx, false, "wetland", 999999.0, dense_site,
				stats, wet_cap)
			ctx["wetland_bulk_used"] = wet_used + wet_placed
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
		ctx, check_slope, kind, forest_min_area, dense_site, stats)


static func _scatter_polygon_poisson(layer: AutoVegetationLayer, poly: PackedVector2Array,
		weights: Dictionary, height: float, spacing: float,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary, check_slope: bool, kind: String = "wood",
		forest_min_area: float = 12000.0, dense_site: bool = false,
		stats: Dictionary = {}, extra_cap: int = -1) -> int:
	var area := VegetationPaint.polygon_area(poly)
	if area < 16.0:
		return 0
	if layer.tree_bulk_count() >= layer.max_tree_bulk:
		_stat(stats, "rej_budget")
		return 0
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
	if extra_cap >= 0:
		cap = mini(cap, extra_cap)
	var edge_feather := float(style.get("forest_edge_feather_m", 20.0))
	var detail_r := float(ctx.get("tree_detail_radius_m", 800.0))
	var distant_den := float(ctx.get("tree_distant_density", 0.35))
	var spots := VegetationPaint.poisson_fill(poly, spacing, rng, [] as Array[Vector2], cap)
	_stat(stats, "candidates", spots.size())
	var placed := 0
	for spot in spots:
		var p := Vector2(float(spot["x"]), float(spot["z"]))
		if _excluded(p, exclusion_index):
			_stat(stats, "rej_excluded")
			continue
		if check_slope and _slope_too_steep(p.x, p.y, ctx):
			_stat(stats, "rej_slope")
			continue
		if _in_open_area(p, ctx):
			_stat(stats, "rej_open")
			continue
		# Distance LOD: thin instances past the detail radius so heavy OSM maps
		# keep near-field density while skipping far fill that rarely reads.
		var dist_xz := p.length()
		if detail_r > 0.0 and dist_xz > detail_r:
			if distant_den <= 0.0 or rng.randf() > distant_den:
				_stat(stats, "rej_distant")
				continue
		var edge_w := _edge_spawn_weight(p, poly, edge_feather)
		if rng.randf() > edge_w:
			_stat(stats, "rej_edge")
			continue
		var species := BiomePalette.pick_species(weights, rng)
		if layer.add_bulk(species, p.x, p.y, rng.randf() * TAU,
				_scale_for(species, height, rng), height):
			placed += 1
			_stat(stats, "placed")
		else:
			_stat(stats, "rej_budget")
	return placed


static func _scatter_grass_polygon(layer: AutoVegetationLayer, poly: PackedVector2Array,
		kind: String, exclusion_index: VegExclusionBuilder.ExclusionIndex,
		rng: RandomNumberGenerator, ctx: Dictionary = {}, stats: Dictionary = {},
		extra_cap: int = -1) -> int:
	if VegetationPaint.polygon_area(poly) < 4.0:
		return 0
	# Only grass the part of the polygon within the detail radius of spawn — the
	# budget can't cover a whole 3-km site at close-up density, and far grass is
	# culled at render time anyway. Regions preserve holes/concavity via clipping.
	var regions := _grass_detail_regions(poly, ctx)
	if regions.is_empty():
		return 0
	var style: Dictionary = ctx.get("style", {})
	var density_scale := clampf(float(style.get("auto_density_scale", 1.0)), 0.25, 3.0)
	var bulk_scale := float(style.get("grass_lawn_bulk_scale", 1.0)) if kind == "grass_lawn" \
		else float(style.get("grass_field_bulk_scale", 1.25))
	var cap := extra_cap if extra_cap >= 0 else GRASS_PER_POLY_CAP
	var placed := 0
	for region in regions:
		if cap <= 0:
			break
		# Spacing MATCHES the Tune Look studio (VegetationPreviewEditor._base_spacing
		# / density) so "Apply to map" reproduces the previewed density — no
		# even-spacing/fair-share dilution that used to make map grass far sparser.
		var spots: Array[Dictionary]
		if kind == "grass_lawn":
			var mat_w := float(style.get("grass_lawn_card_w",
				GrassBuilder.SPECS["grass_lawn"]["mat_w"]))
			mat_w = maxf(mat_w / sqrt(density_scale), 0.15)
			spots = VegetationPaint.square_grid_fill(region, mat_w, [] as Array[Vector2], cap)
		else:
			var spacing := maxf(1.1 / density_scale, 0.35)  # GRASS_FIELD studio base
			spots = VegetationPaint.poisson_fill(region, spacing, rng, [] as Array[Vector2], cap)
		_stat(stats, "candidates", spots.size())
		for spot in spots:
			var p := Vector2(float(spot["x"]), float(spot["z"]))
			if _excluded(p, exclusion_index):
				_stat(stats, "rej_excluded")
				continue
			var added: bool
			if kind == "grass_lawn":
				var yaw := float(spot.get("yaw", 0.0))
				added = layer.add_bulk(kind, p.x, p.y, yaw, bulk_scale, 0.0)
			else:
				added = layer.add_bulk(kind, p.x, p.y, rng.randf() * TAU,
					rng.randf_range(bulk_scale * 0.75, bulk_scale * 1.15), 0.0)
			if added:
				placed += 1
				cap -= 1
			_stat(stats, "placed" if added else "rej_budget")
	return placed


## Clip a grass polygon to the spawn-centred detail region. Returns [poly] when
## no radius is set or the footprint already fits inside the region, [] when the
## polygon lies entirely outside it, else the polygon clipped to a spawn-centred
## bounding SQUARE of half-size `radius`.
##
## The square (straight edges) avoids a visible arc cut at the disc boundary
## while bounding the footprint the grass grid must scan. Without this a large
## OSM park/meadow near spawn was scanned over its whole multi-km footprint at
## sub-metre spacing — tens of millions of point-in-polygon tests on one frame,
## which froze the load-time scatter at "OSM data".
static func _grass_detail_regions(poly: PackedVector2Array, ctx: Dictionary) -> Array:
	var radius := float(ctx.get("grass_detail_radius_m", 0.0))
	if radius <= 0.0:
		return [poly]
	if _poly_dist_to_origin(poly) > radius:
		return []
	var b := _poly_bounds(poly)
	if b.is_empty():
		return []
	# Footprint already within the spawn box → no clip needed (common small lawn).
	if float(b["min_x"]) >= -radius and float(b["max_x"]) <= radius \
			and float(b["min_z"]) >= -radius and float(b["max_z"]) <= radius:
		return [poly]
	var clip := PackedVector2Array([
		Vector2(-radius, -radius), Vector2(radius, -radius),
		Vector2(radius, radius), Vector2(-radius, radius)])
	var out: Array = []
	for region in Geometry2D.intersect_polygons(poly, clip):
		var r: PackedVector2Array = region
		if r.size() >= 3:
			out.append(r)
	return out


static func _scatter_park_polygon(layer: AutoVegetationLayer, poly: PackedVector2Array,
		weights: Dictionary, height: float,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary, stats: Dictionary = {}) -> void:
	# Underlay lawn disabled by default (SKIP_AUTO_SCATTER_KINDS).
	_scatter_polygon_poisson(layer, poly, weights, height * 0.85, 14.0,
		exclusion_index, rng, ctx, true, "wood", 999999.0, false, stats)


static func _scatter_cemetery_polygon(layer: AutoVegetationLayer, poly: PackedVector2Array,
		weights: Dictionary, height: float,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary, stats: Dictionary = {}) -> void:
	_scatter_polygon_poisson(layer, poly, weights, height * 0.7, 12.0,
		exclusion_index, rng, ctx, true, "wood", 999999.0, false, stats)


## Park/cemetery ground-cover lawn, drawn from its own grass sub-budget so big
## parks can't starve mapped lawns and meadows of the shared grass total.
static func _scatter_underlay_lawn(layer: AutoVegetationLayer, poly: PackedVector2Array,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary, stats: Dictionary) -> void:
	var used := int(ctx.get("grass_underlay_used", 0))
	if used >= GRASS_UNDERLAY_BUDGET:
		return
	var placed := _scatter_grass_polygon(layer, poly, "grass_lawn", exclusion_index,
		rng, ctx, stats, GRASS_UNDERLAY_BUDGET - used)
	ctx["grass_underlay_used"] = used + placed


static func _scatter_row_crop_polygon(layer: AutoVegetationLayer, poly: PackedVector2Array,
		species: String, target_h: float, row_spacing: float, in_row_spacing: float,
		exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary, stats: Dictionary = {}) -> void:
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
			if Geometry2D.is_point_in_polygon(p, poly):
				_stat(stats, "candidates")
				if _excluded(p, exclusion_index):
					_stat(stats, "rej_excluded")
				elif _slope_too_steep(p.x, p.y, ctx):
					_stat(stats, "rej_slope")
				elif _in_open_area(p, ctx):
					_stat(stats, "rej_open")
				elif layer.add_bulk(species, p.x, p.y, rng.randf() * TAU,
						_scale_for(species, target_h, rng), target_h):
					_stat(stats, "placed")
				else:
					_stat(stats, "rej_budget")
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
		ctx: Dictionary, stats: Dictionary = {}) -> void:
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
				if layer.add_bulk("shrub", p.x, p.y, rng.randf() * TAU,
						rng.randf_range(0.9, 1.3), 1.2):
					_stat(stats, "hedges_placed")
				else:
					_stat(stats, "hedges_rej_budget")
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
		ctx: Dictionary, stats: Dictionary = {}) -> void:
	var p: Vector2 = tp.get("pos", Vector2.ZERO)
	if _excluded(p, exclusion_index) or _slope_too_steep(p.x, p.y, ctx):
		return
	var h := float(tp.get("height_m", 0.0))
	if h > 0.0:
		# OSM height tags can be mis-entered or mis-parsed (feet vs meters); the
		# tallest realistic mapped trees are ~45 m. Clamping here also sanitizes
		# stale height_m values already sitting in cached payloads.
		h = clampf(h, TREE_POINT_MIN_HEIGHT_M, TREE_POINT_MAX_HEIGHT_M)
	if h <= 0.0:
		h = float(biome.get("default_height_m", 12.0))
	# Individually-mapped OSM trees (natural=tree, esp. with height/dbh tags) used
	# to become low-poly GLB hero models (HeroTreeCatalog "deciduous_low"), which
	# ignore the tuned Tune-Look / preset look entirely — a campus like Arcosanti is
	# mostly these points, so its trees rendered as the old low-poly GLB (no leaf
	# shells, wrong branches) while painted/forest trees used the procedural mesh.
	# Route them through the same procedural bulk species so every deciduous tree —
	# mapped point, forest scatter, or brush — shares the one tuned look. Explicit
	# trees pick a TREE species only (deciduous/pine), never shrub.
	var species := BiomePalette.pick_species(_tree_only_weights(biome), rng)
	if layer.add_bulk(species, p.x, p.y, rng.randf() * TAU, _scale_for(species, h, rng), h):
		_stat(stats, "points_placed")
	else:
		_stat(stats, "points_rej_budget")


static func _place_tree_row(layer: AutoVegetationLayer, tree_row: Dictionary,
		biome: Dictionary, exclusion_index: VegExclusionBuilder.ExclusionIndex, rng: RandomNumberGenerator,
		ctx: Dictionary, stats: Dictionary = {}) -> void:
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
				if layer.add_bulk(species, p.x, p.y, rng.randf() * TAU,
						_scale_for(species, height, rng), height):
					_stat(stats, "rows_placed")
				else:
					_stat(stats, "rows_rej_budget")
			d += TREE_ROW_SPACING_M
		carry = d - seg_len


static func _excluded(p: Vector2, exclusion_index: VegExclusionBuilder.ExclusionIndex) -> bool:
	if exclusion_index == null:
		return false
	return exclusion_index.is_excluded(p)
