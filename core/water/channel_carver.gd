class_name ChannelCarver
extends RefCounted

## Carves waterway channels into the procedural channel tile layer — pure and
## worker-thread safe (it reads only a WaterGroundSampler and plain data, and
## RETURNS tile arrays for the main thread to install).
##
## One job does two things:
##   1. Profiles — every feature's bed (ChannelProfile), processed outlets-first
##      so a tributary's bed is floored at the bed of whatever it drains into.
##   2. Rasterisation — each carved segment (two consecutive profile stations on
##      a SURFACE span) is swept as a trapezoid: flat bed `bed_w` wide, banks
##      rising 1 : `bank_slope`. Each tile sample keeps the LOWEST target any
##      segment proposes (channels union), and the delta is
##      min(0, target − base): carving only ever lowers.
##
## Incremental: a feature whose profile (and section/modes) is unchanged keeps
## its footprint. Only tiles inside the old ∪ new footprints of changed features
## are re-rasterised — but ALL features overlapping those tiles are swept into
## them, so a junction tile shared by two rivers stays correct when only one
## moved. Rasterising per segment (not per tile × all segments) keeps a 3 km
## river to well under a second.

const CELL_M := TerrainEditTiles.CELL_M
const TILE_CELLS := TerrainEditTiles.TILE_CELLS
## Channels stop this far inside the hi-res patch edge — the HeightField sinks
## the DetailGround only inside the patch, and the coarse Ground beyond it is
## never carved.
const PATCH_MARGIN_M := 24.0


## Rounding radius (m) of the bank TOE — the crease where the flat bed meets
## the bank. Anything sharper than the 1.5 m edit grid aliases into a sawtooth
## along a diagonal channel; a C1 blend over ±TOE_ROUND_M does not.
const TOE_ROUND_M := 1.5
## Softness (m) of the bank LIP, where the cut meets the untouched ground.
const LIP_SOFT_M := 0.25


## Height of the channel surface above the bed at lateral distance `d` from the
## centreline: flat across the bed half-width `hb`, then rising 1 : `z` — with
## the toe rounded by a quadratic blend (value and slope continuous).
static func section_offset(d: float, hb: float, z: float) -> float:
	var x := d - hb
	var r := minf(TOE_ROUND_M, hb)
	if x <= -r:
		return 0.0
	if x >= r:
		return x / z
	return (x + r) * (x + r) / (4.0 * r) / z


## Soft minimum of 0 and `x` (target − ground): equals x for a deep cut, 0 well
## above the ground, and rounds the lip in between instead of leaving a crease.
static func soft_cut(x: float) -> float:
	var k := LIP_SOFT_M
	if x < -8.0 * k:
		return x
	if x > 8.0 * k:
		return 0.0
	return -k * log(1.0 + exp(-x / k))


## A stable signature of everything a feature's carve depends on.
static func feature_signature(f: Dictionary, profile: Dictionary, carve_on: bool) -> int:
	var bed: PackedFloat32Array = profile.get("bed", PackedFloat32Array())
	return hash([f.get("points"), f.get("modes"), f.get("section"), bool(f.get("carve", true)),
		carve_on, bed])


## Run a carve job. `job`:
##   features       resolved StreamNetwork features
##   sampler        WaterGroundSampler (base ground, no tile layers)
##   carve_enabled  map-wide switch
##   prev_sigs      {feature id -> int} from the previous run
##   prev_footprints{feature id -> Array[Vector2i]}
##   force_all      re-rasterise every footprint (first load / cache miss)
## Returns {profiles, sigs, footprints, tiles: {Vector2i -> PackedFloat32Array},
##          touched: Array[Vector2i]}. A touched key absent from `tiles` must be
##          REMOVED from the channel layer.
static func run(job: Dictionary) -> Dictionary:
	var features: Array = job.get("features", [])
	var sampler: WaterGroundSampler = job.get("sampler")
	var carve_on := bool(job.get("carve_enabled", true))
	var prev_sigs: Dictionary = job.get("prev_sigs", {})
	var prev_fp: Dictionary = job.get("prev_footprints", {})
	var force_all := bool(job.get("force_all", false))
	var ground_fn := Callable(sampler, "base_at")

	# --- 1. Profiles, outlets first --------------------------------------
	var links := StreamNetwork.drainage_links(features)
	var order := StreamNetwork.downstream_first_order(features, links)
	var profiles := {}
	var sigs := {}
	for f_v in order:
		var f: Dictionary = f_v
		var id: String = f["id"]
		var sec: Dictionary = f["section"]
		var floor_y := NAN
		var l: Dictionary = links.get(id, {})
		if not l.is_empty() and profiles.has(l["into"]):
			floor_y = ChannelProfile.bed_at(profiles[l["into"]], float(l["at_s"])).x
		# Banks are checked one metre past the bed edge on both sides.
		var prof := ChannelProfile.compute(f["points"], ground_fn,
			float(sec.get("depth", 0.8)), float(sec.get("max_cut", 6.0)), floor_y,
			ChannelProfile.STEP_M, ChannelProfile.SMOOTH_RADIUS_M,
			float(sec.get("bed_w", 2.0)) * 0.5 + 1.0)
		prof["varc"] = StreamNetwork.vertex_arc(f["points"])
		profiles[id] = prof
		sigs[id] = feature_signature(f, prof, carve_on)

	# --- 2. Which tiles need re-rasterising -------------------------------
	var footprints := {}
	var dirty := {}
	var segs_by_feature := {}
	for f_v in features:
		var f: Dictionary = f_v
		var id: String = f["id"]
		var segs := _carve_segments(f, profiles[id], carve_on, sampler)
		segs_by_feature[id] = segs
		var fp := _footprint(segs)
		footprints[id] = fp
		var changed := force_all or int(prev_sigs.get(id, 0)) != int(sigs[id])
		if changed:
			for k in fp:
				dirty[k] = true
			for k in prev_fp.get(id, []):
				dirty[k] = true
	# Features that vanished: their old footprint must be cleared.
	for id in prev_fp.keys():
		if not footprints.has(id):
			for k in prev_fp[id]:
				dirty[k] = true

	# --- 3. Rasterise every segment that touches a dirty tile -------------
	var e := TILE_CELLS + 1
	# Vector2i -> Array (REFERENCE type on purpose: a PackedFloat32Array held in
	# a Dictionary is copy-on-write, so every per-sample write would copy the
	# whole 4225-float tile) of the min target per sample (INF = none).
	var target := {}
	for id in segs_by_feature.keys():
		for seg_v in segs_by_feature[id]:
			var seg: Dictionary = seg_v
			var rect: Rect2 = seg["rect"]
			if not _rect_touches_keys(rect, dirty):
				continue
			_rasterise_segment(seg, dirty, target, e)
	var tiles := {}
	for k in target.keys():
		var arr: Array = target[k]
		var out := PackedFloat32Array()
		out.resize(e * e)
		var any := false
		var gi0: int = k.x * TILE_CELLS
		var gj0: int = k.y * TILE_CELLS
		for lj in e:
			for li in e:
				var idx := lj * e + li
				var t: float = arr[idx]
				if t == INF:
					continue
				var x := float(gi0 + li) * CELL_M
				var z := float(gj0 + lj) * CELL_M
				var d := soft_cut(t - sampler.base_at(x, z))
				if d < -1e-3:
					out[idx] = d
					any = true
		if any:
			tiles[k] = out
	return {"profiles": profiles, "sigs": sigs, "footprints": footprints,
		"tiles": tiles, "touched": dirty.keys(), "links": links}


## The carved segments of one feature: consecutive profile stations whose arc
## midpoint lies on a SURFACE span, inside the patch. Each carries the trapezoid
## parameters and its reach (how far the banks run before meeting the ground).
static func _carve_segments(f: Dictionary, prof: Dictionary, carve_on: bool,
		sampler: WaterGroundSampler) -> Array:
	var out: Array = []
	if not carve_on or not bool(f.get("carve", true)):
		return out
	var pts: PackedVector2Array = prof["points"]
	var s: PackedFloat32Array = prof["s"]
	var bed: PackedFloat32Array = prof["bed"]
	var ground: PackedFloat32Array = prof["ground"]
	var varc: PackedFloat32Array = prof["varc"]
	var sec: Dictionary = f["section"]
	var hb := maxf(float(sec.get("bed_w", 2.0)) * 0.5, 0.2)
	var z := maxf(float(sec.get("bank_slope", 1.5)), 0.05)
	var half := sampler.detail_half() - PATCH_MARGIN_M
	if half <= 0.0:
		return out
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		if maxf(maxf(absf(a.x), absf(a.y)), maxf(absf(b.x), absf(b.y))) > half:
			continue
		var mid_s := 0.5 * (s[i] + s[i + 1])
		if StreamNetwork.mode_at(f, mid_s, varc) != "surface":
			continue
		var cut := maxf(ground[i] - bed[i], ground[i + 1] - bed[i + 1])
		var reach := hb + z * (maxf(cut, 0.0) + 0.5) + CELL_M
		var rect := Rect2(a, Vector2.ZERO).expand(b).grow(reach)
		out.append({"a": a, "b": b, "ya": bed[i], "yb": bed[i + 1], "hb": hb,
			"z": z, "reach": reach, "rect": rect, "i": i})
	# Link consecutive segments so a joint is swept ONCE: a round end-cap that
	# reaches back over the neighbouring segment carries the wrong bed (on a
	# 20 % reach the next station is 0.4 m lower, and its cap dug a terrace
	# into every upstream station). Caps survive only in the outer-bend wedge.
	for k in out.size():
		var sk: Dictionary = out[k]
		if k > 0 and int((out[k - 1] as Dictionary)["i"]) == int(sk["i"]) - 1:
			sk["prev_a"] = (out[k - 1] as Dictionary)["a"]
		if k + 1 < out.size() and int((out[k + 1] as Dictionary)["i"]) == int(sk["i"]) + 1:
			sk["next_b"] = (out[k + 1] as Dictionary)["b"]
	return out


static func _footprint(segs: Array) -> Array:
	var keys := {}
	var span := CELL_M * float(TILE_CELLS)
	for seg_v in segs:
		var r: Rect2 = (seg_v as Dictionary)["rect"]
		var tx0 := floori(r.position.x / span)
		var tz0 := floori(r.position.y / span)
		var tx1 := floori(r.end.x / span)
		var tz1 := floori(r.end.y / span)
		for tz in range(tz0, tz1 + 1):
			for tx in range(tx0, tx1 + 1):
				keys[Vector2i(tx, tz)] = true
	return keys.keys()


static func _rect_touches_keys(r: Rect2, keys: Dictionary) -> bool:
	var span := CELL_M * float(TILE_CELLS)
	var tx0 := floori(r.position.x / span)
	var tz0 := floori(r.position.y / span)
	var tx1 := floori(r.end.x / span)
	var tz1 := floori(r.end.y / span)
	for tz in range(tz0, tz1 + 1):
		for tx in range(tx0, tx1 + 1):
			if keys.has(Vector2i(tx, tz)):
				return true
	return false


## Sweep one segment's trapezoid over the global sample grid inside its rect,
## writing the min target into every owning tile that is dirty.
static func _rasterise_segment(seg: Dictionary, dirty: Dictionary, target: Dictionary, e: int) -> void:
	var a: Vector2 = seg["a"]
	var b: Vector2 = seg["b"]
	var ya := float(seg["ya"])
	var yb := float(seg["yb"])
	var hb := float(seg["hb"])
	var z := float(seg["z"])
	var reach := float(seg["reach"])
	var rect: Rect2 = seg["rect"]
	var ab := b - a
	var l2 := ab.length_squared()
	var has_prev := seg.has("prev_a")
	var has_next := seg.has("next_b")
	var prev_a: Vector2 = seg.get("prev_a", a)
	var next_b: Vector2 = seg.get("next_b", b)
	var pa := a - prev_a
	var pa2 := pa.length_squared()
	var nb := next_b - b
	var nb2 := nb.length_squared()
	var gi0 := floori(rect.position.x / CELL_M)
	var gj0 := floori(rect.position.y / CELL_M)
	var gi1 := ceili(rect.end.x / CELL_M)
	var gj1 := ceili(rect.end.y / CELL_M)
	for gj in range(gj0, gj1 + 1):
		var pz := float(gj) * CELL_M
		for gi in range(gi0, gi1 + 1):
			var p := Vector2(float(gi) * CELL_M, pz)
			var traw := 0.0 if l2 < 1e-9 else (p - a).dot(ab) / l2
			# Behind the start / past the end: an interior joint's cap is kept
			# ONLY in the outer-bend wedge (past the previous segment's end, or
			# before the next one's start). Anywhere else upstream/downstream
			# segments own the point and carry the right bed.
			if traw < 0.0 and has_prev and pa2 > 1e-9:
				if (p - prev_a).dot(pa) / pa2 <= 1.0:
					continue
			elif traw > 1.0 and has_next and nb2 > 1e-9:
				if (p - b).dot(nb) / nb2 >= 0.0:
					continue
			var t := clampf(traw, 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			if d > reach:
				continue
			var y := lerpf(ya, yb, t) + section_offset(d, hb, z)
			_write_min(gi, gj, y, dirty, target, e)


## Write `y` as a candidate minimum at global sample (gi, gj) into every tile
## owning it (a sample on a tile edge belongs to two or four tiles — the
## TerrainEditTiles overlap convention), dirty tiles only.
static func _write_min(gi: int, gj: int, y: float, dirty: Dictionary, target: Dictionary, e: int) -> void:
	var tx := floori(float(gi) / float(TILE_CELLS))
	var tz := floori(float(gj) / float(TILE_CELLS))
	var li := gi - tx * TILE_CELLS
	var lj := gj - tz * TILE_CELLS
	_write_min_tile(Vector2i(tx, tz), li, lj, y, dirty, target, e)
	if li == 0:
		_write_min_tile(Vector2i(tx - 1, tz), TILE_CELLS, lj, y, dirty, target, e)
	if lj == 0:
		_write_min_tile(Vector2i(tx, tz - 1), li, TILE_CELLS, y, dirty, target, e)
	if li == 0 and lj == 0:
		_write_min_tile(Vector2i(tx - 1, tz - 1), TILE_CELLS, TILE_CELLS, y, dirty, target, e)


static func _write_min_tile(key: Vector2i, li: int, lj: int, y: float, dirty: Dictionary,
		target: Dictionary, e: int) -> void:
	if not dirty.has(key):
		return
	var arr: Array
	if target.has(key):
		arr = target[key]
	else:
		arr = []
		arr.resize(e * e)
		arr.fill(INF)
		target[key] = arr
	var idx := lj * e + li
	if y < float(arr[idx]):
		arr[idx] = y
