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


## Linear grade (ramp) between world points `a` and `b` at heights `ya`/`yb`,
## `width_m` wide, feathered at the sides.
static func ramp(tiles: TerrainEditTiles, a: Vector2, b: Vector2, ya: float,
		yb: float, width_m: float, base_fn: Callable) -> void:
	var axis := b - a
	var len2 := axis.length_squared()
	if len2 < 1e-4:
		return
	var half_w := maxf(width_m, tiles.cell_m) * 0.5
	var aabb := Rect2(a, Vector2.ZERO).expand(b).grow(half_w + tiles.cell_m)
	var bnd := tiles.sample_bounds_for_aabb(aabb, 1)
	for gj in range(bnd.y, bnd.w + 1):
		var z := float(gj) * tiles.cell_m
		for gi in range(bnd.x, bnd.z + 1):
			var x := float(gi) * tiles.cell_m
			var p := Vector2(x, z)
			var t := clampf((p - a).dot(axis) / len2, 0.0, 1.0)
			var on_axis := a + axis * t
			var perp := p.distance_to(on_axis)
			if perp > half_w:
				continue
			var w := 1.0 - smoothstep(0.6, 1.0, perp / half_w)
			var target := lerpf(ya, yb, t)
			var base := float(base_fn.call(x, z))
			tiles.set_delta_sample(gi, gj, (target - base) * w)


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
