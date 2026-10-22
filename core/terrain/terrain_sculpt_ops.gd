class_name TerrainSculptOps
extends RefCounted

## Pure shaping operations for the high-resolution terrain edit layer. Each op
## turns a player gesture (brush stamp, level polygon, ramp, basin) into per-sample
## height-DELTA writes on a TerrainEditTiles store. All ops are static and take a
## `base_fn` Callable(x, z) -> AMSL metres of the composed base surface (no edit
## layer), so the delta needed to hit an absolute target Y is (target - base).
##
## These are the "commands" of the rebuilt tool set (SimCity/Skylines style):
## explicit, previewable, and undoable (wrap in tiles.begin_session/end_session).
## Fully covered by terrain_selftest.gd.

## Smooth 0..1 radial falloff (1 at centre, 0 at edge) with an adjustable core.
static func falloff(dist: float, radius: float, hardness: float = 0.5) -> float:
	if radius <= 0.0:
		return 0.0
	var t := clampf(dist / radius, 0.0, 1.0)
	# hardness raises the flat core; 0 = gaussian-ish, 1 = nearly hard-edged.
	var h := clampf(hardness, 0.0, 0.98)
	var inner := clampf((t - h) / maxf(1.0 - h, 1e-3), 0.0, 1.0)
	return 1.0 - smoothstep(0.0, 1.0, inner)


# ---------------------------------------------------------------------------
# Brushes (relative + absolute)
# ---------------------------------------------------------------------------

## Raise (amount > 0) or lower (amount < 0) within a circular brush. `amount` is
## metres at the brush centre, scaled by the radial falloff.
static func raise_lower_brush(tiles: TerrainEditTiles, center: Vector2,
		radius: float, amount: float, hardness: float = 0.5) -> void:
	var aabb := Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
	var b := tiles.sample_bounds_for_aabb(aabb, 1)
	for gj in range(b.y, b.w + 1):
		var z := float(gj) * tiles.cell_m
		for gi in range(b.x, b.z + 1):
			var x := float(gi) * tiles.cell_m
			var d := Vector2(x, z).distance_to(center)
			if d > radius:
				continue
			var w := falloff(d, radius, hardness)
			if w > 0.0:
				tiles.add_delta_sample(gi, gj, amount * w)


## Ease the surface toward `target_y` within the brush (a soft flatten).
static func flatten_brush(tiles: TerrainEditTiles, center: Vector2, radius: float,
		target_y: float, strength: float, base_fn: Callable, hardness: float = 0.5) -> void:
	var aabb := Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
	var b := tiles.sample_bounds_for_aabb(aabb, 1)
	var s := clampf(strength, 0.0, 1.0)
	for gj in range(b.y, b.w + 1):
		var z := float(gj) * tiles.cell_m
		for gi in range(b.x, b.z + 1):
			var x := float(gi) * tiles.cell_m
			var d := Vector2(x, z).distance_to(center)
			if d > radius:
				continue
			var w := falloff(d, radius, hardness) * s
			if w <= 0.0:
				continue
			var base := float(base_fn.call(x, z))
			var cur := base + tiles.get_delta_sample(gi, gj)
			var goal := lerpf(cur, target_y, w)
			tiles.set_delta_sample(gi, gj, goal - base)


## Blur the surface toward the local neighbourhood average (removes bumps/noise).
static func smooth_brush(tiles: TerrainEditTiles, center: Vector2, radius: float,
		strength: float, base_fn: Callable, hardness: float = 0.5) -> void:
	var aabb := Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
	var b := tiles.sample_bounds_for_aabb(aabb, 1)
	var s := clampf(strength, 0.0, 1.0)
	var step := tiles.cell_m
	# Snapshot target deltas first so the blur uses pre-edit neighbours (order-free).
	var writes := {}
	for gj in range(b.y, b.w + 1):
		var z := float(gj) * step
		for gi in range(b.x, b.z + 1):
			var x := float(gi) * step
			var d := Vector2(x, z).distance_to(center)
			if d > radius:
				continue
			var w := falloff(d, radius, hardness) * s
			if w <= 0.0:
				continue
			var here := float(base_fn.call(x, z)) + tiles.get_delta_sample(gi, gj)
			var sum := 0.0
			var n := 0
			for oz in [-1, 0, 1]:
				for ox in [-1, 0, 1]:
					if ox == 0 and oz == 0:
						continue
					var nx := x + float(ox) * step
					var nz := z + float(oz) * step
					sum += float(base_fn.call(nx, nz)) + tiles.sample_delta(nx, nz)
					n += 1
			var avg := sum / float(maxi(n, 1))
			var goal := lerpf(here, avg, w)
			writes[Vector2i(gi, gj)] = goal - float(base_fn.call(x, z))
	for key in writes.keys():
		var k: Vector2i = key
		tiles.set_delta_sample(k.x, k.y, writes[key])


# ---------------------------------------------------------------------------
# Level / grade a region
# ---------------------------------------------------------------------------

## Set the whole polygon interior to `target_y` (a graded pad), feathering the
## transition out to natural ground over `feather_m` beyond the edge.
static func level_polygon(tiles: TerrainEditTiles, poly: PackedVector2Array,
		target_y: float, feather_m: float, base_fn: Callable) -> void:
	if poly.size() < 3:
		return
	var aabb := _poly_aabb(poly).grow(maxf(feather_m, 0.0) + tiles.cell_m)
	var b := tiles.sample_bounds_for_aabb(aabb, 1)
	var feather := maxf(feather_m, 0.01)
	for gj in range(b.y, b.w + 1):
		var z := float(gj) * tiles.cell_m
		for gi in range(b.x, b.z + 1):
			var x := float(gi) * tiles.cell_m
			var p := Vector2(x, z)
			var inside := Geometry2D.is_point_in_polygon(p, poly)
			var w := 1.0
			if not inside:
				var dist := _dist_to_poly_edge(poly, p)
				if dist >= feather:
					continue
				w = 1.0 - smoothstep(0.0, 1.0, dist / feather)
			var base := float(base_fn.call(x, z))
			var want := (target_y - base) * w
			# Absolute op: overwrite the delta (don't stack on prior edits).
			tiles.set_delta_sample(gi, gj, want)


## Grade a ROAD: level a corridor `half_w` wide along `points` to the
## centreline's own smoothed profile (TerrainRoadFlatten's rule, applied to
## the edit layer instead of the base grid), feathered out over `feather_m`
## beyond the shoulder. Absolute op like level_polygon.
static func level_polyline(tiles: TerrainEditTiles, points: PackedVector2Array,
		half_w: float, feather_m: float, base_fn: Callable,
		smooth_radius_m: float = 12.0) -> void:
	if points.size() < 2:
		return
	# Centreline profile: samples every ~third of a cell, smoothed over
	# smooth_radius_m so the road grades over bumps instead of copying them.
	var step := maxf(tiles.cell_m * 0.35, 0.5)
	var cum := PackedFloat32Array()
	cum.resize(points.size())
	var total_len := 0.0
	for i in points.size():
		if i > 0:
			total_len += points[i].distance_to(points[i - 1])
		cum[i] = total_len
	if total_len < 0.01:
		return
	var n_prof := int(ceil(total_len / step)) + 1
	var raw := PackedFloat32Array()
	raw.resize(n_prof)
	for k in n_prof:
		var p := _polyline_point_at(points, cum, float(k) * step)
		raw[k] = float(base_fn.call(p.x, p.y))
	var smooth_n := maxi(1, int(round(smooth_radius_m / step)))
	var profile := PackedFloat32Array()
	profile.resize(n_prof)
	for k in n_prof:
		var lo := maxi(0, k - smooth_n)
		var hi := mini(n_prof - 1, k + smooth_n)
		var total := 0.0
		for j in range(lo, hi + 1):
			total += raw[j]
		profile[k] = total / float(hi - lo + 1)
	# One write per sample: project onto the polyline (few segments), look the
	# profile up at that arc length, weight by distance from the shoulder.
	var reach := half_w + maxf(feather_m, 0.0)
	var aabb := Rect2(points[0], Vector2.ZERO)
	for p in points:
		aabb = aabb.expand(p)
	aabb = aabb.grow(reach + tiles.cell_m)
	var b := tiles.sample_bounds_for_aabb(aabb, 1)
	var feather := maxf(feather_m, 0.01)
	for gj in range(b.y, b.w + 1):
		var z := float(gj) * tiles.cell_m
		for gi in range(b.x, b.z + 1):
			var x := float(gi) * tiles.cell_m
			var p := Vector2(x, z)
			var best_d := INF
			var best_s := 0.0
			for i in range(points.size() - 1):
				var a := points[i]
				var c := points[i + 1]
				var q := Geometry2D.get_closest_point_to_segment(p, a, c)
				var d := p.distance_to(q)
				if d < best_d:
					best_d = d
					best_s = cum[i] + a.distance_to(q)
			if best_d > reach:
				continue
			var w := 1.0
			if best_d > half_w:
				w = 1.0 - smoothstep(0.0, 1.0, (best_d - half_w) / feather)
			var k := clampi(int(round(best_s / step)), 0, n_prof - 1)
			var base := float(base_fn.call(x, z))
			tiles.set_delta_sample(gi, gj, (profile[k] - base) * w)


static func _polyline_point_at(pts: PackedVector2Array, cum: PackedFloat32Array, s: float) -> Vector2:
	if s <= 0.0:
		return pts[0]
	for i in range(pts.size() - 1):
		if s <= cum[i + 1] + 1e-6:
			var seg := cum[i + 1] - cum[i]
			var t := (s - cum[i]) / seg if seg > 1e-9 else 0.0
			return pts[i].lerp(pts[i + 1], clampf(t, 0.0, 1.0))
	return pts[pts.size() - 1]


## Side slope of a ramp, horizontal : vertical. 2:1 is the usual stable fill
## embankment (USDA NRCS NEH 650 ch. 6); 0.5 is the steepest offered.
const DEFAULT_RAMP_SIDE_RUN := 2.0
const MIN_RAMP_SIDE_RUN := 0.5
## Samples along the strip used to bound how far the sides reach.
const RAMP_REACH_SAMPLES := 32
const RAMP_REACH_SLACK_M := 2.0
## A side never reaches further than this from the top's edge (a cut into a
## hill steeper than the side would otherwise run on forever).
const RAMP_MAX_SIDE_REACH_M := 120.0
## How far the toe of a side is rounded where it meets the ground (m).
const RAMP_TOE_SOFT_M := 0.6


## Straight graded strip from world point `a` to `b`: a flat-across top
## `width_m` wide whose height runs linearly from `ya` to `yb` (the ground at
## the two clicks) plus `height_m` — positive builds a berm, negative cuts a
## channel, zero grades a road across a slope. Each side then slopes at
## `side_run` (horizontal per vertical) until it meets the ground, cutting
## where the ground is higher and filling where it is lower, so on a hillside
## the uphill side is a cut and the downhill side a fill. Ends are rounded
## (distance to the clamped end point).
static func ramp(tiles: TerrainEditTiles, a: Vector2, b: Vector2, ya: float,
		yb: float, width_m: float, base_fn: Callable, height_m: float = 0.0,
		side_run: float = DEFAULT_RAMP_SIDE_RUN) -> void:
	var axis := b - a
	var len2 := axis.length_squared()
	if len2 < 1e-4:
		return
	var half_w := maxf(width_m, tiles.cell_m) * 0.5
	var run := maxf(side_run, MIN_RAMP_SIDE_RUN)
	var nrm := Vector2(-axis.y, axis.x).normalized()
	# How far the sides can reach before they meet the ground: the largest
	# top-vs-ground difference along the strip, sampled down its middle and
	# both edges, times the run (plus slack for ground that keeps falling or
	# rising past the edge).
	var max_diff := 0.0
	for k in RAMP_REACH_SAMPLES + 1:
		var t := float(k) / float(RAMP_REACH_SAMPLES)
		var top := lerpf(ya, yb, t) + height_m
		for off in [-half_w, 0.0, half_w]:
			var q: Vector2 = a + axis * t + nrm * float(off)
			max_diff = maxf(max_diff, absf(top - _surface_at(tiles, q, base_fn)))
	var side_reach := minf(run * (max_diff + RAMP_REACH_SLACK_M), RAMP_MAX_SIDE_REACH_M)
	var capped := run * (max_diff + RAMP_REACH_SLACK_M) > RAMP_MAX_SIDE_REACH_M
	var reach := half_w + side_reach
	var aabb := Rect2(a, Vector2.ZERO).expand(b).grow(reach + tiles.cell_m)
	var bnd := tiles.sample_bounds_for_aabb(aabb, 1)
	for gj in range(bnd.y, bnd.w + 1):
		var z := float(gj) * tiles.cell_m
		for gi in range(bnd.x, bnd.z + 1):
			var x := float(gi) * tiles.cell_m
			var p := Vector2(x, z)
			var t := clampf((p - a).dot(axis) / len2, 0.0, 1.0)
			var d := p.distance_to(a + axis * t)
			if d > reach:
				continue
			var top := lerpf(ya, yb, t) + height_m
			var base := float(base_fn.call(x, z))
			var cur := base + tiles.get_delta_sample(gi, gj)
			var target := top
			if d > half_w:
				var drop := (d - half_w) / run
				if cur > top:
					# Cut: the side climbs from the top edge until it meets the ground.
					target = _smooth_min(cur, top + drop, RAMP_TOE_SOFT_M)
				else:
					# Fill: the side falls away until it meets the ground.
					target = _smooth_max(cur, top - drop, RAMP_TOE_SOFT_M)
				if capped:
					# A side that never meets the ground (a cut into a slope steeper
					# than the side) eases back to the ground at the reach limit
					# instead of ending in a cliff.
					target = lerpf(target, cur, smoothstep(reach - 4.0 * tiles.cell_m, reach, d))
			tiles.set_delta_sample(gi, gj, target - base)


## Edited surface (base + this layer's delta) at a world point.
static func _surface_at(tiles: TerrainEditTiles, q: Vector2, base_fn: Callable) -> float:
	return float(base_fn.call(q.x, q.y)) + tiles.sample_delta(q.x, q.y)


## Polynomial smooth max / min (Quilez): equal to max / min once the two are
## more than `k` apart, a rounded blend within it — softens the toe of a ramp
## side so it does not alias into a staircase on the 1.5 m grid.
static func _smooth_max(p: float, q: float, k: float) -> float:
	var h := clampf(0.5 + 0.5 * (q - p) / k, 0.0, 1.0)
	return lerpf(p, q, h) + k * h * (1.0 - h)


static func _smooth_min(p: float, q: float, k: float) -> float:
	return -_smooth_max(-p, -q, k)


# ---------------------------------------------------------------------------
# Pond basin
# ---------------------------------------------------------------------------

## Carve a containing bowl inside `poly`: a flat floor `depth` metres below the
## lowest rim point, with banks sloped up to the rim over `bank_run × depth`. The
## interior is set to an absolute target (a predictable bowl the player drew), so
## a real depression fills to the lowest rim = a natural gravity level. Returns the
## rim height (min edge elevation) so the caller can set the water level, or NAN.
static func carve_basin(tiles: TerrainEditTiles, poly: PackedVector2Array,
		depth: float, bank_run: float, base_fn: Callable) -> float:
	if poly.size() < 3:
		return NAN
	var rim_min := INF
	for p in poly:
		rim_min = minf(rim_min, float(base_fn.call(p.x, p.y)))
	if not is_finite(rim_min):
		return NAN
	var floor_y := rim_min - maxf(depth, 0.1)
	var bank_w := maxf(maxf(depth, 0.1) * maxf(bank_run, 0.5), tiles.cell_m)
	var aabb := _poly_aabb(poly).grow(tiles.cell_m)
	var b := tiles.sample_bounds_for_aabb(aabb, 1)
	for gj in range(b.y, b.w + 1):
		var z := float(gj) * tiles.cell_m
		for gi in range(b.x, b.z + 1):
			var x := float(gi) * tiles.cell_m
			var p := Vector2(x, z)
			if not Geometry2D.is_point_in_polygon(p, poly):
				continue
			var d := _dist_to_poly_edge(poly, p)
			var t := clampf(d / bank_w, 0.0, 1.0)
			var target := lerpf(rim_min, floor_y, smoothstep(0.0, 1.0, t))
			var base := float(base_fn.call(x, z))
			# Only cut down — never raise interior ground above natural.
			var cur_surface := base + tiles.get_delta_sample(gi, gj)
			if target < cur_surface:
				tiles.set_delta_sample(gi, gj, target - base)
	return rim_min


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

static func _poly_aabb(poly: PackedVector2Array) -> Rect2:
	var r := Rect2(poly[0], Vector2.ZERO)
	for i in range(1, poly.size()):
		r = r.expand(poly[i])
	return r


static func _dist_to_poly_edge(poly: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var d := _point_segment_distance(p, a, b)
		best = minf(best, d)
	return best


static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 1e-9:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)
