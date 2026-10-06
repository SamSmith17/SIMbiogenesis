class_name FestivalLotPartition
extends RefCounted

## Splits a placement ZONE into LOTS of equal USABLE area along a festival
## road — the way a regional's placement team hands out ground: a block of
## lots fronting the road, each one as deep as the zone allows and as wide as
## it must be for everyone to get the same amount of pitchable ground.
##
## Pure geometry over a FestivalUsableRaster. No RNG anywhere: the same zone,
## roads and ground always produce the same lots.
##
## The algorithm, per road (in the zone's priority order) and per side:
##   1. every usable, unclaimed cell projects onto the road; cells inside the
##      band [half_w, half_w + depth] bin their area along the road's arc
##      length s (0.5 m bins) → a cumulative usable-area curve cum(s);
##   2. cuts along s at equal increments of cum, with a cross lane every K lots
##      (a second pass re-targets with the lane area removed);
##   3. each [s_a, s_b] becomes a ribbon between the offset curves at
##      half_w + 0.3 and half_w + depth, clipped to the zone minus holes, locked
##      lots and the lots of earlier roads;
##   4. slivers merge into their smaller neighbour, lots are named A1, A2 …
##      (block letter = road × side), measured, and matched to prior lots by
##      overlap so an unchanged lot keeps its id and its camp.
##
## Grow-stability: in `area` mode the cuts march from the road's own s = 0,
## so extending a zone along its road appends lots and moves none; in `count`
## mode the cuts must rebalance, and ids survive by overlap matching instead.
## A LOCKED lot is subtracted from the ground before anything is cut, so a lot
## already promised to a camp never moves in either mode.

const BIN_M := 0.5
## Lots under this share of a target lot merge into a neighbour.
const MIN_LOT_FRACTION := 0.3
## A road side holding less usable ground than this share of one target lot
## is skipped (the zone is single-loaded on the other side).
const MIN_SIDE_FRACTION := 0.3
## The lot's front edge sits this far off the road corridor.
const FRONT_SETBACK_M := 0.3
## Overlap (intersection over union) at which a new lot inherits an old id.
const INHERIT_IOU := 0.5
## Pieces smaller than this are not slivers worth merging, just remainder.
const SLIVER_MIN_M2 := 20.0
const MAX_LOTS := 200


## zone: a FestivalPlacementLayer zone record (polygon, holes, road_ids, spec).
## roads: Array of road dicts {id, points, half_width_m}.
## ctx: {ground_y_at, is_excluded, locked_lots: Array[lot records],
##       prior_lots: Array[lot records], raster?: FestivalUsableRaster}.
## Returns {lots, stats, warnings}. New lots carry lot_id "" (the layer mints
## ids); inherited ones keep theirs, their assignment and their lock.
static func partition(zone: Dictionary, roads: Array, ctx: Dictionary) -> Dictionary:
	var out := {"lots": [], "stats": {}, "warnings": []}
	var poly: PackedVector2Array = zone.get("polygon", PackedVector2Array())
	if poly.size() < 3:
		return out
	var spec: Dictionary = FestivalPlacementLayer.normalize_spec(zone.get("spec", {}))
	var holes: Array = zone.get("holes", [])
	var locked_lots: Array = ctx.get("locked_lots", [])
	var locked_polys: Array = []
	for ll in locked_lots:
		if ll is Dictionary:
			locked_polys.append((ll as Dictionary).get("polygon", PackedVector2Array()))
	var raster: FestivalUsableRaster = ctx.get("raster", null)
	if raster == null:
		raster = FestivalUsableRaster.build(poly, holes, locked_polys,
			ctx, float(spec["slope_limit_deg"]), str(spec["equalise"]) == "raw")
	var equalise_raw := str(spec["equalise"]) == "raw"

	# Resolve the zone's roads in priority order.
	var zone_roads: Array = []
	for rid in zone.get("road_ids", []):
		for r in roads:
			if r is Dictionary and str((r as Dictionary).get("id", "")) == str(rid):
				var pts: PackedVector2Array = (r as Dictionary).get("points", PackedVector2Array())
				if pts.size() >= 2:
					zone_roads.append(r)
				break

	var lots: Array = []
	var warnings: Array = []
	var total_usable := raster.usable_m2()
	var target_hint := _target_area(spec, total_usable)

	if zone_roads.is_empty():
		lots = _fallback_lattice(zone, spec, raster, target_hint)
		warnings.append("No festival road reaches this zone — rectangular lattice used")
	else:
		# Pass 1: bin every road side (cells are claimed in priority order, so
		# a cell in reach of two roads belongs to the first).
		var claimed := PackedByteArray()
		claimed.resize(raster.nx * raster.nz)
		var bands: Array = []   # [{road, road_index, side, band, cum, pts, half_w}]
		var road_index := 0
		for road in zone_roads:
			var rd: Dictionary = road
			var pts: PackedVector2Array = rd.get("points", PackedVector2Array())
			var half_w := float(rd.get("half_width_m", 4.0))
			var cum := _polyline_cum(pts)
			for side in [1, -1]:
				var band := _bin_frontage(raster, claimed, pts, cum, half_w,
					float(spec["depth_m"]), side, equalise_raw)
				if float(band["total"]) > 0.0:
					bands.append({"road": rd, "road_index": road_index, "side": side,
						"band": band, "cum": cum, "pts": pts, "half_w": half_w})
			road_index += 1
		# Pass 2: how many lots each side gets. `target_n` is the ZONE's count,
		# split across sides by usable share (largest remainder, so the total
		# lands on N); a side with too little ground, or a band too shallow to
		# be a lot (the strip between an inset road and the zone edge), is
		# skipped rather than cut into slivers.
		var counts := _side_counts(bands, spec, total_usable)
		# Pass 3: cut and build.
		for bi in bands.size():
			var n := int(counts[bi])
			if n <= 0:
				continue
			var e: Dictionary = bands[bi]
			var band: Dictionary = e["band"]
			var cuts := _cut_along(band, spec, n)
			var side_lots := _ribbon_lots(zone, raster, e["pts"], e["cum"], float(e["half_w"]),
				float(spec["depth_m"]), int(e["side"]), cuts, locked_polys, lots)
			_merge_slivers(side_lots, raster, float(band["total"]) / float(n), float(spec["front_min_m"]))
			var block := int(e["road_index"]) * 2 + (0 if int(e["side"]) == 1 else 1)
			for k in side_lots.size():
				var lot: Dictionary = side_lots[k]
				lot["index"] = k + 1
				lot["name"] = "%s%d" % [CampSubdivider.row_letters(block), k + 1]
				lot["road_id"] = str((e["road"] as Dictionary).get("id", ""))
				lot["side"] = int(e["side"])
				lots.append(lot)
				if lots.size() >= MAX_LOTS:
					break
			if lots.size() >= MAX_LOTS:
				warnings.append("Lot cap %d reached" % MAX_LOTS)
				break
		_flag_corners(lots, zone_roads)

	# Measure, warn, inherit.
	var usable_vals: Array = []
	for lot in lots:
		var m := raster.measure(lot["polygon"])
		lot["usable_m2"] = float(m["usable_m2"])
		lot["raw_m2"] = float(m["raw_m2"])
		lot["mean_slope_deg"] = float(m["mean_slope_deg"])
		lot["max_slope_deg"] = float(m["max_slope_deg"])
		lot["zone_id"] = str(zone.get("id", ""))
		lot["features"] = (zone.get("features", []) as Array).duplicate()
		lot["locked"] = false
		lot["assigned_camp"] = {}
		lot["lot_id"] = ""
		lot["camp_area_id"] = ""
		if float(lot.get("frontage_m", 0.0)) > float(spec["front_max_m"]) + 0.01:
			warnings.append("%s frontage %.0f m > %.0f — steep or blocked ground inside" % [
				str(lot["name"]), float(lot["frontage_m"]), float(spec["front_max_m"])])
		usable_vals.append(float(m["usable_m2"]))
	_inherit_ids(lots, ctx.get("prior_lots", []))
	# Locked lots come back untouched, after the new ones.
	for ll in locked_lots:
		if ll is Dictionary:
			var keep: Dictionary = (ll as Dictionary).duplicate(true)
			keep["locked"] = true
			lots.append(keep)
			usable_vals.append(float(keep.get("usable_m2", 0.0)))

	var style0 := str((spec["styles"] as Array)[0]) if not (spec["styles"] as Array).is_empty() \
		else CampStyles.DEFAULT_STYLE
	for lot in lots:
		lot["fairness"] = 0.0
	var stats := _stats(lots, usable_vals, raster, style0)
	for lot in lots:
		var mean := float(stats["usable_mean"])
		lot["fairness"] = float(lot.get("usable_m2", 0.0)) / mean if mean > 0.0 else 0.0
	stats["warnings"] = warnings
	out["lots"] = lots
	out["stats"] = stats
	out["warnings"] = warnings
	return out


## The usable area one lot should get for this spec and this much ground.
static func _target_area(spec: Dictionary, total: float) -> float:
	if str(spec["mode"]) == "count":
		return total / float(maxi(int(spec["target_n"]), 1))
	return maxf(float(spec["target_m2"]), 1.0)


## A side whose band averages shallower than this share of the intended depth
## is the strip between an inset road and the zone boundary, not a block.
const MIN_SIDE_DEPTH_FRACTION := 0.35


## Lots per band. count mode: the zone's target_n shared by usable area
## (largest remainder); area mode: each band's own total / target_m2. Either
## way a band under MIN_SIDE_FRACTION of one lot, or shallower than
## MIN_SIDE_DEPTH_FRACTION x depth, gets 0.
static func _side_counts(bands: Array, spec: Dictionary, total_usable: float) -> Array:
	var counts: Array = []
	var depth := float(spec["depth_m"])
	var grand := 0.0
	for e in bands:
		grand += float((e["band"] as Dictionary)["total"])
	var target := _target_area(spec, total_usable)
	if str(spec["mode"]) == "count":
		target = grand / float(maxi(int(spec["target_n"]), 1))
	var eligible: Array = []
	for i in bands.size():
		var band: Dictionary = bands[i]["band"]
		var total := float(band["total"])
		var span := maxf(float(band["s_last"]) - float(band["s_first"]), 1.0)
		var ok := total >= MIN_SIDE_FRACTION * maxf(target, 1.0) \
			and total / span >= MIN_SIDE_DEPTH_FRACTION * depth
		eligible.append(ok)
		counts.append(0)
	if str(spec["mode"]) != "count":
		for i in bands.size():
			if eligible[i]:
				counts[i] = maxi(int(round(float((bands[i]["band"] as Dictionary)["total"])
					/ maxf(float(spec["target_m2"]), 1.0))), 1)
		return counts
	var n_total := maxi(int(spec["target_n"]), 1)
	var elig_total := 0.0
	for i in bands.size():
		if eligible[i]:
			elig_total += float((bands[i]["band"] as Dictionary)["total"])
	if elig_total <= 0.0:
		return counts
	var rem: Array = []   # [frac, i]
	var given := 0
	for i in bands.size():
		if not eligible[i]:
			continue
		var raw := float(n_total) * float((bands[i]["band"] as Dictionary)["total"]) / elig_total
		var base := maxi(int(floor(raw)), 1)
		counts[i] = base
		given += base
		rem.append([raw - floor(raw), i])
	rem.sort_custom(func(a, b):
		if absf(float(a[0]) - float(b[0])) > 1e-9:
			return float(a[0]) > float(b[0])
		return int(a[1]) < int(b[1]))
	var k := 0
	while given < n_total and k < rem.size():
		counts[int(rem[k][1])] = int(counts[int(rem[k][1])]) + 1
		given += 1
		k += 1
	return counts


# ---------------------------------------------------------------------------
# Frontage parameterisation
# ---------------------------------------------------------------------------

static func _polyline_cum(pts: PackedVector2Array) -> PackedFloat32Array:
	var cum := PackedFloat32Array()
	cum.resize(pts.size())
	var acc := 0.0
	for i in pts.size():
		if i > 0:
			acc += pts[i].distance_to(pts[i - 1])
		cum[i] = acc
	return cum


## Nearest point of the polyline to p within `reach` of some segment.
## {ok, seg, t, s, d (signed: +left of travel), q}. Cells past the road's
## ends (t outside [0,1] on every segment) are not frontage.
static func _project(p: Vector2, pts: PackedVector2Array, cum: PackedFloat32Array,
		reach: float) -> Dictionary:
	var best := {"ok": false}
	var best_d := INF
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		if p.x < minf(a.x, b.x) - reach or p.x > maxf(a.x, b.x) + reach \
				or p.y < minf(a.y, b.y) - reach or p.y > maxf(a.y, b.y) + reach:
			continue
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 1e-6:
			continue
		var t := (p - a).dot(ab) / len2
		if t < 0.0 or t > 1.0:
			# Still a candidate when the point sits off the END of the whole
			# road? No — frontage must face the road, not its extension.
			continue
		var q := a + ab * t
		var d := p.distance_to(q)
		if d < best_d:
			best_d = d
			var tangent := ab / sqrt(len2)
			var rel := p - q
			var signed := tangent.x * rel.y - tangent.y * rel.x
			best = {"ok": true, "seg": i, "t": t, "s": cum[i] + t * sqrt(len2),
				"d": signed, "q": q}
	return best


## Bins the usable band cells of one road side along s.
## Returns {bins: PackedFloat32Array (area per bin), cum: PackedFloat32Array,
##          total, s_len, s_first, s_last}.
static func _bin_frontage(raster: FestivalUsableRaster, claimed: PackedByteArray,
		pts: PackedVector2Array, cum: PackedFloat32Array, half_w: float,
		depth_m: float, side: int, raw_mode: bool) -> Dictionary:
	var s_len := float(cum[cum.size() - 1])
	var nbins := int(ceil(s_len / BIN_M)) + 2
	var bins := PackedFloat32Array()
	bins.resize(nbins)
	var reach := half_w + depth_m + raster.cell
	var area := raster.cell_area()
	var s_first := INF
	var s_last := -INF
	var total := 0.0
	var want := FestivalUsableRaster.USABLE
	for j in raster.nz:
		for i in raster.nx:
			var k := raster.index(i, j)
			var m := raster.mask[k]
			if m == FestivalUsableRaster.OUTSIDE or claimed[k] != 0:
				continue
			if m != want and not raw_mode:
				continue
			var pr := _project(raster.cell_center(i, j), pts, cum, reach)
			if not bool(pr["ok"]):
				continue
			var d := float(pr["d"])
			if (d > 0.0) != (side > 0):
				continue
			var dist := absf(d)
			if dist < half_w or dist > half_w + depth_m:
				continue
			claimed[k] = 1
			var s := float(pr["s"])
			var bi := clampi(int(floor(s / BIN_M)), 0, nbins - 1)
			bins[bi] += area
			total += area
			s_first = minf(s_first, s)
			s_last = maxf(s_last, s)
	var cumulative := PackedFloat32Array()
	cumulative.resize(nbins + 1)
	var acc := 0.0
	for b in nbins:
		cumulative[b] = acc
		acc += bins[b]
	cumulative[nbins] = acc
	return {"bins": bins, "cum": cumulative, "total": total, "s_len": s_len,
		"s_first": s_first if total > 0.0 else 0.0,
		"s_last": s_last if total > 0.0 else 0.0}


## Cumulative usable area from the road start up to arc length s.
static func _cum_at(band: Dictionary, s: float) -> float:
	var cumulative: PackedFloat32Array = band["cum"]
	var nbins := cumulative.size() - 1
	var fb := s / BIN_M
	var b := int(floor(fb))
	if b < 0:
		return 0.0
	if b >= nbins:
		return cumulative[nbins]
	var frac := fb - float(b)
	return cumulative[b] + (cumulative[b + 1] - cumulative[b]) * frac


## The arc length at which the cumulative area reaches `target_cum` (binary
## search over the bins, linear inside one). Clamps to the road's end.
static func _inverse_cum(band: Dictionary, target_cum: float) -> float:
	var cumulative: PackedFloat32Array = band["cum"]
	var nbins := cumulative.size() - 1
	if target_cum >= cumulative[nbins] - 1e-6:
		return float(band["s_last"])
	var lo := 0
	var hi := nbins
	while lo < hi:
		var mid := (lo + hi) >> 1
		if cumulative[mid + 1] >= target_cum:
			hi = mid
		else:
			lo = mid + 1
	var b := lo
	var span := cumulative[b + 1] - cumulative[b]
	var frac := (target_cum - cumulative[b]) / span if span > 1e-9 else 0.0
	return (float(b) + clampf(frac, 0.0, 1.0)) * BIN_M


## Equal-usable-area cuts along s: Array of [s_a, s_b]. Two passes, the
## second re-targeting with the cross-lane area removed from the pool.
static func _cut_along(band: Dictionary, spec: Dictionary, n_in: int) -> Array:
	var total := float(band["total"])
	var n := clampi(n_in, 1, MAX_LOTS)
	var lane_w := float(spec["lane_w_m"])
	var k_lane := int(spec["lots_per_lane"])
	var d_lane := float(spec["lane_every_m"])
	var lanes_area := 0.0
	var cuts: Array = []
	for pass_i in 2:
		cuts = []
		var target := maxf((total - lanes_area) / float(n), 1e-3)
		var s := float(band["s_first"])
		var last_lane_s := s
		var lane_acc := 0.0
		var s_end := float(band["s_last"])
		for k in n:
			if s >= s_end - 1e-6:
				break
			var s_a := s
			var s_b := _inverse_cum(band, _cum_at(band, s_a) + target)
			if k == n - 1:
				s_b = s_end  # the last lot takes the rest
			s_b = maxf(s_b, s_a + BIN_M)
			cuts.append([s_a, minf(s_b, s_end)])
			s = s_b
			var lane_due := false
			if k_lane > 0 and (k + 1) % k_lane == 0:
				lane_due = true
			elif d_lane > 0.0 and s - last_lane_s >= d_lane:
				lane_due = true
			if lane_due and lane_w > 0.0 and k < n - 1:
				lane_acc += _cum_at(band, s + lane_w) - _cum_at(band, s)
				s += lane_w
				last_lane_s = s
		lanes_area = lane_acc
		if lane_acc <= 0.0:
			break
	return cuts


# ---------------------------------------------------------------------------
# Lot polygons
# ---------------------------------------------------------------------------

static func _point_at(pts: PackedVector2Array, cum: PackedFloat32Array, s: float) -> Vector2:
	var n := pts.size()
	if s <= 0.0:
		return pts[0]
	for i in range(n - 1):
		if s <= cum[i + 1] + 1e-6:
			var seg := cum[i + 1] - cum[i]
			var t := (s - cum[i]) / seg if seg > 1e-9 else 0.0
			return pts[i].lerp(pts[i + 1], clampf(t, 0.0, 1.0))
	return pts[n - 1]


## Left normal of the road at arc length s (averaged at a vertex).
static func _normal_at(pts: PackedVector2Array, cum: PackedFloat32Array, s: float) -> Vector2:
	var n := pts.size()
	var seg_i := n - 2
	for i in range(n - 1):
		if s < cum[i + 1] - 1e-6:
			seg_i = i
			break
	var t := (pts[seg_i + 1] - pts[seg_i]).normalized()
	# At an interior vertex, blend the two segment tangents.
	for i in range(1, n - 1):
		if absf(s - cum[i]) < 1e-4:
			var t0 := (pts[i] - pts[i - 1]).normalized()
			var t1 := (pts[i + 1] - pts[i]).normalized()
			var avg := (t0 + t1)
			if avg.length_squared() > 1e-8:
				t = avg.normalized()
			break
	return Vector2(-t.y, t.x)


## The ribbon between the offset curves at d0 and d1 over [s_a, s_b].
static func _ribbon(pts: PackedVector2Array, cum: PackedFloat32Array, s_a: float,
		s_b: float, d0: float, d1: float, side: int) -> PackedVector2Array:
	var stations: Array = [s_a]
	for i in range(1, pts.size() - 1):
		if cum[i] > s_a + 1e-4 and cum[i] < s_b - 1e-4:
			stations.append(cum[i])
	stations.append(s_b)
	var front := PackedVector2Array()
	var back := PackedVector2Array()
	for s in stations:
		var p := _point_at(pts, cum, float(s))
		var nrm := _normal_at(pts, cum, float(s)) * float(side)
		front.append(p + nrm * d0)
		back.append(p + nrm * d1)
	back.reverse()
	var ring := PackedVector2Array()
	ring.append_array(front)
	ring.append_array(back)
	return ring


static func _ring_valid(ring: PackedVector2Array) -> bool:
	if ring.size() < 3:
		return false
	return Geometry2D.triangulate_polygon(ring).size() >= 3


## Offset-band fallback for bends tighter than the depth: the band between
## the two offset curves of the sub-polyline, on the requested side.
static func _band_fallback(pts: PackedVector2Array, cum: PackedFloat32Array,
		s_a: float, s_b: float, d0: float, d1: float, side: int) -> PackedVector2Array:
	var sub := PackedVector2Array([_point_at(pts, cum, s_a)])
	for i in range(1, pts.size() - 1):
		if cum[i] > s_a + 1e-4 and cum[i] < s_b - 1e-4:
			sub.append(pts[i])
	sub.append(_point_at(pts, cum, s_b))
	var outer: Array = Geometry2D.offset_polyline(sub, d1, Geometry2D.JOIN_ROUND, Geometry2D.END_SQUARE)
	var inner: Array = Geometry2D.offset_polyline(sub, d0, Geometry2D.JOIN_ROUND, Geometry2D.END_SQUARE)
	if outer.is_empty():
		return PackedVector2Array()
	var pieces: Array = [outer[0]]
	if not inner.is_empty():
		pieces = Geometry2D.clip_polygons(outer[0], inner[0])
	var best := PackedVector2Array()
	var best_area := 0.0
	for piece: PackedVector2Array in pieces:
		if Geometry2D.is_polygon_clockwise(piece) or piece.size() < 3:
			continue
		var ip := CampAreaLayer._inner_point(piece)
		var pr := _project(ip, pts, cum, d1 + 1.0)
		if not bool(pr["ok"]) or (float(pr["d"]) > 0.0) != (side > 0):
			continue
		var a := CampAreaLayer.polygon_area(piece)
		if a > best_area:
			best_area = a
			best = piece
	return best


static func _ribbon_lots(zone: Dictionary, raster: FestivalUsableRaster,
		pts: PackedVector2Array, cum: PackedFloat32Array, half_w: float, depth_m: float,
		side: int, cuts: Array, locked_polys: Array, earlier: Array) -> Array:
	var poly: PackedVector2Array = zone.get("polygon", PackedVector2Array())
	var holes: Array = zone.get("holes", [])
	var d0 := half_w + FRONT_SETBACK_M
	var d1 := half_w + depth_m
	var out: Array = []
	for c in cuts:
		var s_a := float(c[0])
		var s_b := float(c[1])
		var ring := _ribbon(pts, cum, s_a, s_b, d0, d1, side)
		if not _ring_valid(ring):
			ring = _band_fallback(pts, cum, s_a, s_b, d0, d1, side)
		if ring.size() < 3:
			continue
		var pieces: Array = []
		for piece: PackedVector2Array in Geometry2D.intersect_polygons(ring, poly):
			if not Geometry2D.is_polygon_clockwise(piece):
				pieces.append(piece)
		var subtract: Array = []
		subtract.append_array(holes)
		subtract.append_array(locked_polys)
		for e in earlier:
			subtract.append((e as Dictionary).get("polygon", PackedVector2Array()))
		for sp in subtract:
			if not (sp is PackedVector2Array) or (sp as PackedVector2Array).size() < 3:
				continue
			var next: Array = []
			for piece: PackedVector2Array in pieces:
				if not CampAreaLayer._overlaps(piece, sp):
					next.append(piece)
					continue
				for cut: PackedVector2Array in Geometry2D.clip_polygons(piece, sp):
					if not Geometry2D.is_polygon_clockwise(cut):
						next.append(cut)
			pieces = next
		if pieces.is_empty():
			continue
		# Largest piece is the lot; the rest are slivers of this lot.
		pieces.sort_custom(func(a, b):
			return CampAreaLayer.polygon_area(a) > CampAreaLayer.polygon_area(b))
		var lot := {
			"polygon": pieces[0], "s_start": s_a, "s_end": s_b,
			"frontage_m": s_b - s_a, "depth_m": depth_m,
			"heading_deg": CampLayoutGenerator.direction_to_heading(
				_point_at(pts, cum, minf(s_b, s_a + 0.5 * (s_b - s_a) + 0.01))
				- _point_at(pts, cum, s_a)),
			"corner": false, "touches_road_ids": [],
			"slivers": pieces.slice(1),
		}
		out.append(lot)
	return out


## Lots too small or too narrow fold into their smaller neighbour on the same
## side; a lot's own slivers fold into it, or into whichever lot they border.
static func _merge_slivers(side_lots: Array, raster: FestivalUsableRaster,
		target: float, front_min_m: float) -> void:
	# Own slivers first.
	for lot in side_lots:
		var slivers: Array = lot.get("slivers", [])
		for sv: PackedVector2Array in slivers:
			if CampAreaLayer.polygon_area(sv) < SLIVER_MIN_M2:
				continue
			var merged := CampAreaLayer._union(lot["polygon"], sv)
			if (merged["outers"] as Array).size() == 1:
				lot["polygon"] = merged["outers"][0]
		lot.erase("slivers")
	# Then undersized lots.
	var i := 0
	while i < side_lots.size() and side_lots.size() > 1:
		var lot: Dictionary = side_lots[i]
		var m := raster.measure(lot["polygon"])
		var small := float(m["usable_m2"]) < MIN_LOT_FRACTION * target \
			or float(lot["frontage_m"]) < front_min_m
		if not small:
			i += 1
			continue
		var candidates: Array = []
		if i > 0:
			candidates.append(i - 1)
		if i < side_lots.size() - 1:
			candidates.append(i + 1)
		var best := -1
		var best_usable := INF
		for ci in candidates:
			var cu := float(raster.measure(side_lots[ci]["polygon"])["usable_m2"])
			if cu < best_usable:
				best_usable = cu
				best = ci
		if best < 0:
			i += 1
			continue
		var nb: Dictionary = side_lots[best]
		var merged := CampAreaLayer._union(nb["polygon"], lot["polygon"])
		if (merged["outers"] as Array).size() == 1:
			nb["polygon"] = merged["outers"][0]
			nb["s_start"] = minf(float(nb["s_start"]), float(lot["s_start"]))
			nb["s_end"] = maxf(float(nb["s_end"]), float(lot["s_end"]))
			nb["frontage_m"] = float(nb["s_end"]) - float(nb["s_start"])
		side_lots.remove_at(i)
		if best > i:
			continue  # the neighbour shifted into i; re-examine it
		# merged into the previous lot: stay at i (next lot moved here)


## A lot lying within half_w + 1 m of ANOTHER zone road is a corner lot.
static func _flag_corners(lots: Array, zone_roads: Array) -> void:
	for lot in lots:
		var touches: Array = [str(lot.get("road_id", ""))]
		for rd in zone_roads:
			var rid := str((rd as Dictionary).get("id", ""))
			if rid == str(lot.get("road_id", "")):
				continue
			var pts: PackedVector2Array = (rd as Dictionary).get("points", PackedVector2Array())
			var cum := _polyline_cum(pts)
			var reach := float((rd as Dictionary).get("half_width_m", 4.0)) + 1.0
			for v in (lot["polygon"] as PackedVector2Array):
				var pr := _project(v, pts, cum, reach)
				if bool(pr["ok"]) and absf(float(pr["d"])) <= reach:
					touches.append(rid)
					lot["corner"] = true
					break
		lot["touches_road_ids"] = touches


## Overlap-match against the previous subdivision so an unchanged lot keeps
## its id, camp and lock across a re-run.
static func _inherit_ids(lots: Array, prior: Array) -> void:
	var used: Dictionary = {}
	for lot in lots:
		var best_id := ""
		var best_iou := 0.0
		var best_rec: Dictionary = {}
		for pr in prior:
			if not (pr is Dictionary):
				continue
			var p: Dictionary = pr
			if str(p.get("road_id", "")) != str(lot.get("road_id", "")) \
					or int(p.get("side", 0)) != int(lot.get("side", 0)):
				continue
			var pid := str(p.get("lot_id", ""))
			if pid.is_empty() or used.has(pid):
				continue
			var iou := _iou(lot["polygon"], p.get("polygon", PackedVector2Array()))
			if iou > best_iou:
				best_iou = iou
				best_id = pid
				best_rec = p
		if best_iou >= INHERIT_IOU:
			used[best_id] = true
			lot["lot_id"] = best_id
			lot["assigned_camp"] = (best_rec.get("assigned_camp", {}) as Dictionary).duplicate(true)
			lot["camp_area_id"] = str(best_rec.get("camp_area_id", ""))


static func _iou(a: PackedVector2Array, b: PackedVector2Array) -> float:
	if a.size() < 3 or b.size() < 3:
		return 0.0
	var inter := 0.0
	for piece: PackedVector2Array in Geometry2D.intersect_polygons(a, b):
		if not Geometry2D.is_polygon_clockwise(piece):
			inter += CampAreaLayer.polygon_area(piece)
	var union := CampAreaLayer.polygon_area(a) + CampAreaLayer.polygon_area(b) - inter
	return inter / union if union > 1e-6 else 0.0


# ---------------------------------------------------------------------------
# Fallback + stats
# ---------------------------------------------------------------------------

## No road: the rectangular lattice of the Plots tool, measured like the rest.
static func _fallback_lattice(zone: Dictionary, spec: Dictionary,
		raster: FestivalUsableRaster, target: float) -> Array:
	var poly: PackedVector2Array = zone.get("polygon", PackedVector2Array())
	var heading := CampLayoutGenerator.resolve_heading(poly, [])
	var plot_d := float(spec["depth_m"])
	var plot_w := maxf(target * 1.3 / maxf(plot_d, 1.0), 4.0)
	var out: Array = []
	for plot in CampSubdivider.subdivide(poly, heading, plot_w, plot_d, float(spec["lane_w_m"])):
		out.append({
			"polygon": plot["polygon"], "name": str(plot["name"]), "index": int(plot["col"]),
			"road_id": "", "side": 0, "s_start": 0.0, "s_end": 0.0,
			"frontage_m": plot_w, "depth_m": plot_d, "heading_deg": heading,
			"corner": false, "touches_road_ids": [],
		})
	return out


static func _stats(lots: Array, usable_vals: Array, raster: FestivalUsableRaster,
		style0: String) -> Dictionary:
	var n := usable_vals.size()
	var mn := INF
	var mx := 0.0
	var sum := 0.0
	for v in usable_vals:
		mn = minf(mn, float(v))
		mx = maxf(mx, float(v))
		sum += float(v)
	var mean := sum / float(n) if n > 0 else 0.0
	# Gini over usable areas (0 = perfectly equal).
	var gini := 0.0
	if n > 1 and sum > 0.0:
		var sorted := usable_vals.duplicate()
		sorted.sort()
		var acc := 0.0
		for i in n:
			acc += float(i + 1) * float(sorted[i])
		gini = (2.0 * acc) / (float(n) * sum) - float(n + 1) / float(n)
	var people := 0
	for lot in lots:
		var ac: Dictionary = lot.get("assigned_camp", {})
		if not ac.is_empty():
			people += int(ac.get("headcount", 0))
		else:
			people += FestivalAssigner.default_headcount(float(lot.get("usable_m2", 0.0)), style0)
	var in_lots := sum
	return {
		"raw_m2": raster.raw_m2(), "usable_m2": raster.usable_m2(), "lots": n,
		"usable_min": mn if n > 0 else 0.0, "usable_max": mx, "usable_mean": mean,
		"ratio_max_min": (mx / mn) if n > 0 and mn > 0.0 else 0.0, "gini": gini,
		"capacity_people": people,
		"remainder_m2": maxf(raster.usable_m2() - in_lots, 0.0),
	}
