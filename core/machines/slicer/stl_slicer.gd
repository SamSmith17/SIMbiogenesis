class_name StlSlicer
extends RefCounted

## A real slicer for the printers in the game: an STL (a triangle soup in
## millimetres) becomes the moves a printer firmware would run — the same
## move list `GantryLabGcode.parse` makes from a G-code file, so the motion
## planner, the road preview, the G-code writer and the in-world runtime all
## take either without a second path.
##
## What it does, in the order a slicer does it:
##   1. Transform the model (scale, a turn about Z, the base on the bed, the
##      footprint centred where the player put it).
##   2. Cut every triangle with every layer plane at the layer's MID height
##      (so a layer carries the section through its middle, not its edge).
##      Each cut is a segment oriented so the SOLID is on its left — from the
##      triangle's winding: the outward normal n is to the right of travel, so
##      travel = up × n. Chained by their quantised end points into closed
##      loops: outer loops come out counter-clockwise, holes clockwise.
##   3. Perimeters: the loops inset by (k + ½) line widths for wall k (holes
##      grown by the same — Godot's Clipper offset takes a signed distance
##      and keeps the orientation, so an outer shrinks with −d and a hole
##      grows with +d), inner walls first.
##   4. Infill: the region inside the last wall filled with parallel lines at
##      the density (rectilinear at ±45°, turning a quarter each layer, or a
##      grid), clipped by an even-odd scan over every loop — holes fall out
##      of the parity without any orientation bookkeeping. The bottom and top
##      layers are solid (100 %).
##   5. Spiral vase: after the solid bottom, one outer wall per layer whose Z
##      ramps along the loop, so the print is a single continuous bead.
##   6. Travels between features (rapid, an optional Z hop), extrusion per mm
##      of road = w·h / (π d²/4) in millimetres of the feedstock bore d, so the
##      planner and the graph bill exactly w·h·L of material.
##
## Not done (a basic slicer, honestly): skin detection over overhangs beyond
## the top/bottom layer counts, support, bridging, retraction tuning,
## coasting, seam placement beyond "nearest to where the nozzle is".
##
## Settings (mm, mm/s unless noted): layer_height_mm, line_width_mm, walls,
## infill_pct, infill_pattern ("lines" | "grid"), top_layers, bottom_layers,
## mode ("solid" | "vase"), print_speed_mm_s, travel_speed_mm_s,
## first_layer_speed_mm_s, outer_wall_speed_mm_s, scale, rotation_deg,
## centre_xy (Vector2, where the footprint centre lands), z_hop_mm,
## filament_mm (the feedstock bore the E words are in), max_moves (a ceiling:
## a print that needs more is REFUSED with advice, never cut short — the old
## 160 000 cap silently ended a gyroid cube a tenth of the way up),
## progress (a Callable taking 0..1, called from whatever thread slices),
## cancel (a Callable returning true to stop: the result is {ok: false,
## cancelled: true}).
##
## The result carries `place_xy`: where the model's OWN bounding-box centre
## (in its file's coordinates) lands on the bed after the scale, the turn and
## the centring — what a preview of the mesh needs to sit exactly on the
## sliced roads (the turned footprint's centre is a different point for any
## shape that is not symmetric).
##
## The moves come back packed (`PrintMoves`, ~37 bytes a move): a large
## lattice at a fine line is millions of moves.

const DEFAULTS := {
	"layer_height_mm": 0.2, "line_width_mm": 0.45, "walls": 2, "infill_pct": 20.0,
	"infill_pattern": "lines", "top_layers": 3, "bottom_layers": 3, "mode": "solid",
	"print_speed_mm_s": 50.0, "travel_speed_mm_s": 120.0, "first_layer_speed_mm_s": 0.0,
	"outer_wall_speed_mm_s": 0.0, "scale": 1.0, "rotation_deg": 0.0,
	"z_hop_mm": 0.0, "filament_mm": 1.75, "max_moves": 8000000,
}
## Loops are simplified to this share of the line width (never under 5 µm).
const SIMPLIFY_FRAC := 0.02
## End points closer than this (mm) are one point when chaining segments.
const WELD_MM := 1e-3
## A loop whose perimeter is under this many line widths is noise.
const MIN_LOOP_W := 1.5


static func slice_file(path: String, settings: Dictionary = {}) -> Dictionary:
	var tris := StlLoader.load_triangles(path)
	if tris.is_empty():
		return {"ok": false, "error": "no triangles in %s" % path.get_file()}
	return slice_triangles(tris, settings)


## tris = [[a, b, c] …] in mm, Z up. Returns the move list (see the header).
static func slice_triangles(tris: Array, settings_in: Dictionary = {}) -> Dictionary:
	var s := DEFAULTS.duplicate()
	for k in settings_in:
		s[k] = settings_in[k]
	var h := maxf(float(s["layer_height_mm"]), 0.02)
	var w := maxf(float(s["line_width_mm"]), 0.05)
	var walls := maxi(int(s["walls"]), 1)
	var infill_pct := clampf(float(s["infill_pct"]), 0.0, 100.0)
	var pattern := str(s["infill_pattern"])
	var top_n := maxi(int(s["top_layers"]), 0)
	var bot_n := maxi(int(s["bottom_layers"]), 0)
	var vase := str(s["mode"]) == "vase"
	var speed := maxf(float(s["print_speed_mm_s"]), 0.5)
	var travel := maxf(float(s["travel_speed_mm_s"]), speed)
	var first_speed := float(s["first_layer_speed_mm_s"])
	if first_speed <= 0.0:
		first_speed = speed * 0.5
	var outer_speed := float(s["outer_wall_speed_mm_s"])
	if outer_speed <= 0.0:
		outer_speed = speed
	var scale := maxf(float(s["scale"]), 1e-4)
	var rot := deg_to_rad(float(s["rotation_deg"]))
	var centre: Vector2 = s.get("centre_xy", Vector2.ZERO)
	var hop := maxf(float(s["z_hop_mm"]), 0.0)
	var d_fil := maxf(float(s["filament_mm"]), 0.05)
	var max_moves := maxi(int(s["max_moves"]), 1000)
	var progress: Callable = s.get("progress", Callable())
	var cancel: Callable = s.get("cancel", Callable())

	# 1. Transform: scale, turn, base on the bed, footprint centred.
	var xf := _transform(tris, scale, rot)
	var tri_pts: PackedVector3Array = xf["pts"]
	var bmin: Vector3 = xf["bmin"]
	var bmax: Vector3 = xf["bmax"]
	var height := bmax.z - bmin.z
	if height <= 1e-6:
		return {"ok": false, "error": "the model has no height"}
	var shift := Vector3(centre.x - (bmin.x + bmax.x) * 0.5, centre.y - (bmin.y + bmax.y) * 0.5, -bmin.z)
	var c0: Vector2 = xf["src_centre"]
	var c0r := Vector2(c0.x * cos(rot) - c0.y * sin(rot), c0.x * sin(rot) + c0.y * cos(rot)) * scale
	var place_xy := c0r + Vector2(shift.x, shift.y)
	for i in tri_pts.size():
		tri_pts[i] += shift
	bmin += shift
	bmax += shift
	var solid_mm3 := _signed_volume(tri_pts)

	# 2. Layers: the section through each layer's middle.
	var n_layers := maxi(int(ceil(height / h - 1e-6)), 1)
	var layers := _sections(tri_pts, n_layers, h, progress, cancel)
	if layers.is_empty():
		return {"ok": false, "cancelled": true, "error": "cancelled"}
	var tol := maxf(w * SIMPLIFY_FRAC, 0.005)
	var epm := w * h / (PI * d_fil * d_fil * 0.25)   # mm of feedstock per mm of road

	# 3–6. Emit.
	var em := _Emitter.new()
	em.travel_speed = travel
	em.hop = hop
	em.epm = epm
	var warnings: Array = []
	var layer_starts := PackedInt32Array()
	var layer_z := PackedFloat32Array()
	var min_loop_len := w * MIN_LOOP_W
	for li in n_layers:
		if li % 8 == 0:
			if progress.is_valid():
				progress.call(0.4 + 0.6 * float(li) / float(n_layers))
			if cancel.is_valid() and bool(cancel.call()):
				return {"ok": false, "cancelled": true, "error": "cancelled"}
		var z_nozzle := minf(float(li + 1) * h, height + 1e-6)
		var loops: Array = layers[li]
		var kept: Array = []
		for lp in loops:
			var ring: PackedVector2Array = _simplify(lp, tol)
			if ring.size() >= 3 and _perimeter(ring) >= min_loop_len:
				kept.append(ring)
		layer_starts.append(em.moves.size())
		layer_z.append(z_nozzle)
		if kept.is_empty():
			continue
		var layer_speed := first_speed if li == 0 else speed
		var layer_outer_speed := first_speed if li == 0 else outer_speed
		var vase_layer := vase and li >= bot_n
		if vase_layer:
			# One outer wall, Z ramping along it: the spiral.
			var outer := _largest_ccw(kept)
			if outer.is_empty():
				continue
			var wall0: Array = _offset(outer, -w * 0.5)
			if wall0.is_empty():
				continue
			var ring: PackedVector2Array = _largest(wall0)
			# From the previous layer's height (the last layer is cut short
			# to the model's top, so z1 − h would step back down).
			var z0 := minf(float(li) * h, z_nozzle)
			em.spiral(ring, z0, z_nozzle, layer_speed)
			continue
		# Walls, inner first, each island's walls together.
		var solid_layer := li < bot_n or li >= n_layers - top_n
		var inner_region: Array = []
		for ring in kept:
			var hole := Geometry2D.is_polygon_clockwise(ring)
			var ring_walls: Array = []
			for k in walls:
				var d := (float(k) + 0.5) * w
				var off: Array = _offset(ring, d if hole else -d)
				if off.is_empty():
					break
				ring_walls.append(off)
			if ring_walls.is_empty():
				continue
			for k in range(ring_walls.size() - 1, -1, -1):
				var sp := layer_outer_speed if k == 0 else layer_speed
				for r in ring_walls[k]:
					em.loop(r as PackedVector2Array, z_nozzle, sp)
			var inner_d := float(ring_walls.size()) * w
			var inner: Array = _offset(ring, inner_d if hole else -inner_d)
			for r in inner:
				inner_region.append(r)
		# Infill inside the last wall.
		var pct := 100.0 if solid_layer else infill_pct
		if pct > 0.0 and not inner_region.is_empty():
			var angle := PI * 0.25 + (PI * 0.5 if li % 2 == 1 else 0.0)
			if pattern == "grid" and not solid_layer:
				_infill(em, inner_region, PI * 0.25, w / (pct * 0.005), z_nozzle, layer_speed)
				_infill(em, inner_region, PI * 0.75, w / (pct * 0.005), z_nozzle, layer_speed)
			else:
				_infill(em, inner_region, angle, w / (pct * 0.01), z_nozzle, layer_speed)
		if em.moves.size() > max_moves:
			# Never a partial print: the whole height or nothing, with the
			# numbers that say what to change.
			var est := int(float(em.moves.size()) * float(n_layers) / float(li + 1))
			return {"ok": false, "too_many_moves": true, "error": "this print needs about %s moves (the limit is %s) — raise the layer height or the line width, lower the infill, or scale it down" % [
				UiText.thousands(est), UiText.thousands(max_moves)]}
	if progress.is_valid():
		progress.call(1.0)
	if em.moves.is_empty():
		return {"ok": false, "error": "nothing to print (no closed sections)"}
	var ext_min := Vector3(INF, INF, INF)
	var ext_max := Vector3(-INF, -INF, -INF)
	var extrusion := 0.0
	var feed_mm := 0.0
	var rapid_mm := 0.0
	var road_mm := 0.0
	var pm: PrintMoves = em.moves
	for i in pm.size():
		var a := pm.p0[i]
		var b := pm.p1[i]
		var l := a.distance_to(b)
		if pm.rapid[i] != 0:
			rapid_mm += l
		else:
			feed_mm += l
		var e := pm.e[i]
		if e > 0.0:
			extrusion += e
			road_mm += l
			ext_min = ext_min.min(a.min(b))
			ext_max = ext_max.max(a.max(b))
	return {
		"ok": true, "kind": "stl", "moves": em.moves, "bounds_min": ext_min, "bounds_max": ext_max,
		"model_min": bmin, "model_max": bmax, "place_xy": place_xy,
		"extrusion_mm": extrusion, "total_feed_mm": feed_mm, "total_rapid_mm": rapid_mm,
		"road_mm": road_mm, "layers": n_layers, "layer_count": n_layers,
		"layer_starts": layer_starts, "layer_z": layer_z,
		"dialect": "reprap", "temps": {"hotend_c": 0.0, "bed_c": 0.0}, "spindle_rpm": 0.0,
		"laser_s": 0.0, "laser_s_max": 0.0, "lines": 0, "warnings": warnings, "additive": true,
		"triangles": tris.size(), "solid_volume_mm3": solid_mm3 * scale * scale * scale,
		"volume_mm3": road_mm * w * h, "layer_height_mm": h, "line_width_mm": w,
		"print_speed_mm_s": speed, "mode": str(s["mode"]), "settings": s,
	}


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

static func _transform(tris: Array, scale: float, rot: float) -> Dictionary:
	var pts := PackedVector3Array()
	pts.resize(tris.size() * 3)
	var c := cos(rot)
	var sn := sin(rot)
	var bmin := Vector3(INF, INF, INF)
	var bmax := Vector3(-INF, -INF, -INF)
	var smin := Vector2(INF, INF)
	var smax := Vector2(-INF, -INF)
	var k := 0
	for t in tris:
		for v in t:
			var vv: Vector3 = v
			smin = smin.min(Vector2(vv.x, vv.y))
			smax = smax.max(Vector2(vv.x, vv.y))
			var p: Vector3 = vv * scale
			var q := Vector3(p.x * c - p.y * sn, p.x * sn + p.y * c, p.z)
			pts[k] = q
			k += 1
			bmin = bmin.min(q)
			bmax = bmax.max(q)
	return {"pts": pts, "bmin": bmin, "bmax": bmax, "src_centre": (smin + smax) * 0.5}


static func _signed_volume(pts: PackedVector3Array) -> float:
	var v6 := 0.0
	var n := pts.size() / 3
	for i in n:
		var a := pts[i * 3]
		var b := pts[i * 3 + 1]
		var c := pts[i * 3 + 2]
		v6 += a.dot(b.cross(c))
	return absf(v6) / 6.0


## Every layer's closed loops (PackedVector2Array each), from the triangle
## soup cut at z = (k + ½) h. Segments are oriented solid-left.
## [] when `cancel` asked to stop.
static func _sections(pts: PackedVector3Array, n_layers: int, h: float, progress: Callable = Callable(), cancel: Callable = Callable()) -> Array:
	# Per layer a plain Array of [start, end] pairs: a PackedVector2Array
	# fetched out of an Array is a copy-on-write VALUE, so appending to it in
	# place fills nothing (the FlowRouting trap).
	var segs: Array = []
	for _i in n_layers:
		segs.append([])
	var n := pts.size() / 3
	var tick := maxi(n / 40, 1)
	for i in n:
		if i % tick == 0:
			if progress.is_valid():
				progress.call(0.35 * float(i) / float(n))
			if cancel.is_valid() and bool(cancel.call()):
				return []
		var a := pts[i * 3]
		var b := pts[i * 3 + 1]
		var c := pts[i * 3 + 2]
		var zlo := minf(a.z, minf(b.z, c.z))
		var zhi := maxf(a.z, maxf(b.z, c.z))
		if zhi - zlo <= 1e-9:
			continue
		var nrm := (b - a).cross(c - a)
		if nrm.length_squared() <= 1e-18:
			continue
		var k0 := maxi(int(ceil(zlo / h - 0.5)), 0)
		var k1 := mini(int(floor(zhi / h - 0.5)), n_layers - 1)
		for k in range(k0, k1 + 1):
			var z := (float(k) + 0.5) * h
			var seg := _cut(a, b, c, z)
			if seg.is_empty():
				continue
			var p: Vector2 = seg[0]
			var q: Vector2 = seg[1]
			# Travel = up × n: the solid on the left.
			var t := Vector2(-nrm.y, nrm.x)
			if (q - p).dot(t) < 0.0:
				var tmp := p
				p = q
				q = tmp
			(segs[k] as Array).append(p)
			(segs[k] as Array).append(q)
	var out: Array = []
	for k in n_layers:
		var flat: Array = segs[k]
		var sa := PackedVector2Array()
		var sb := PackedVector2Array()
		var m := flat.size() / 2
		sa.resize(m)
		sb.resize(m)
		for j in m:
			sa[j] = flat[j * 2]
			sb[j] = flat[j * 2 + 1]
		out.append(_chain(sa, sb))
	return out


## The segment where the plane z cuts triangle abc (two points), or [].
static func _cut(a: Vector3, b: Vector3, c: Vector3, z: float) -> Array:
	var out: Array = []
	var vs := [a, b, c]
	for i in 3:
		var p: Vector3 = vs[i]
		var q: Vector3 = vs[(i + 1) % 3]
		if (p.z < z) == (q.z < z):
			continue
		if absf(q.z - p.z) <= 1e-12:
			continue
		var t := (z - p.z) / (q.z - p.z)
		out.append(Vector2(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t))
	if out.size() != 2:
		return []
	if (out[0] as Vector2).distance_squared_to(out[1] as Vector2) < 1e-14:
		return []
	return out


static func _key(p: Vector2) -> int:
	var ix := int(round(p.x / WELD_MM))
	var iy := int(round(p.y / WELD_MM))
	return hash(Vector2i(ix, iy))


## Chain oriented segments into closed loops by their welded end points.
static func _chain(sa: PackedVector2Array, sb: PackedVector2Array) -> Array:
	var n := sa.size()
	var loops: Array = []
	if n == 0:
		return loops
	var by_start: Dictionary = {}   # key -> Array of segment indices (a reference type)
	for i in n:
		var k := _key(sa[i])
		if not by_start.has(k):
			by_start[k] = []
		(by_start[k] as Array).append(i)
	var used := PackedByteArray()
	used.resize(n)
	for i in n:
		if used[i] != 0:
			continue
		var ring := PackedVector2Array()
		var cur := i
		var start_key := _key(sa[i])
		var last_end := sa[i]
		var closed := false
		var guard := 0
		while cur >= 0 and used[cur] == 0 and guard <= n:
			guard += 1
			used[cur] = 1
			ring.append(sa[cur])
			last_end = sb[cur]
			var ek := _key(last_end)
			if ek == start_key:
				closed = true
				break
			var next := -1
			if by_start.has(ek):
				for j in by_start[ek]:
					if used[j] == 0:
						next = j
						break
			cur = next
		# A chain that came back near its start closes; an open one (a
		# non-manifold mesh) is dropped unless it is nearly closed.
		if not closed:
			closed = last_end.distance_to(ring[0]) <= WELD_MM * 50.0
		if closed and ring.size() >= 3:
			loops.append(ring)
	return loops


## Ramer–Douglas–Peucker on a closed ring (the first point kept).
static func _simplify(ring: PackedVector2Array, tol: float) -> PackedVector2Array:
	var n := ring.size()
	if n <= 3 or tol <= 0.0:
		return ring
	# Split at the point farthest from point 0 so both halves are open chains.
	var far := 0
	var far_d := -1.0
	for i in n:
		var d := ring[i].distance_squared_to(ring[0])
		if d > far_d:
			far_d = d
			far = i
	if far == 0:
		return ring
	var a := ring.slice(0, far + 1)
	var b := ring.slice(far, n)
	b.append(ring[0])
	var sa := _rdp(a, tol)
	var sb := _rdp(b, tol)
	var out := PackedVector2Array()
	for i in sa.size():
		out.append(sa[i])
	for i in range(1, sb.size() - 1):
		out.append(sb[i])
	return out


static func _rdp(pts: PackedVector2Array, tol: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[n - 1] = 1
	var stack: Array = [[0, n - 1]]
	while not stack.is_empty():
		var span: Array = stack.pop_back()
		var i0: int = span[0]
		var i1: int = span[1]
		if i1 - i0 < 2:
			continue
		var a := pts[i0]
		var b := pts[i1]
		var ab := b - a
		var len2 := ab.length_squared()
		var best := -1.0
		var bi := -1
		for i in range(i0 + 1, i1):
			var d := 0.0
			if len2 <= 1e-18:
				d = pts[i].distance_to(a)
			else:
				var t := clampf((pts[i] - a).dot(ab) / len2, 0.0, 1.0)
				d = pts[i].distance_to(a + ab * t)
			if d > best:
				best = d
				bi = i
		if best > tol and bi >= 0:
			keep[bi] = 1
			stack.append([i0, bi])
			stack.append([bi, i1])
	var out := PackedVector2Array()
	for i in n:
		if keep[i] != 0:
			out.append(pts[i])
	return out


static func _perimeter(ring: PackedVector2Array) -> float:
	var l := 0.0
	var n := ring.size()
	for i in n:
		l += ring[i].distance_to(ring[(i + 1) % n])
	return l


static func _area(ring: PackedVector2Array) -> float:
	var a := 0.0
	var n := ring.size()
	for i in n:
		var p := ring[i]
		var q := ring[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


static func _offset(ring: PackedVector2Array, d: float) -> Array:
	var out: Array = []
	for r in Geometry2D.offset_polygon(ring, d, Geometry2D.JOIN_MITER):
		var rr: PackedVector2Array = r
		if rr.size() >= 3 and absf(_area(rr)) > 1e-6:
			out.append(rr)
	return out


static func _largest(rings: Array) -> PackedVector2Array:
	var best := PackedVector2Array()
	var ba := -1.0
	for r in rings:
		var a := absf(_area(r as PackedVector2Array))
		if a > ba:
			ba = a
			best = r
	return best


static func _largest_ccw(rings: Array) -> PackedVector2Array:
	var best := PackedVector2Array()
	var ba := -1.0
	for r in rings:
		var rr: PackedVector2Array = r
		if Geometry2D.is_polygon_clockwise(rr):
			continue
		var a := _area(rr)
		if a > ba:
			ba = a
			best = rr
	return best


## Parallel lines at `angle`, `spacing` apart, clipped even-odd by the loops
## of `region`, zig-zagged and emitted at z.
static func _infill(em: _Emitter, region: Array, angle: float, spacing: float, z: float, speed: float) -> void:
	spacing = maxf(spacing, 0.05)
	var u := Vector2(cos(angle), sin(angle))     # along the line
	var v := Vector2(-u.y, u.x)                   # across the lines
	# Edges in the (u, v) frame.
	var eu := PackedFloat32Array()
	var ev := PackedFloat32Array()
	var vmin := INF
	var vmax := -INF
	for r in region:
		var ring: PackedVector2Array = r
		var n := ring.size()
		for i in n:
			var p := ring[i]
			var q := ring[(i + 1) % n]
			eu.append(p.dot(u))
			ev.append(p.dot(v))
			eu.append(q.dot(u))
			ev.append(q.dot(v))
			vmin = minf(vmin, minf(p.dot(v), q.dot(v)))
			vmax = maxf(vmax, maxf(p.dot(v), q.dot(v)))
	if not is_finite(vmin) or vmax - vmin < spacing * 0.5:
		return
	# Lines anchored to a world grid so layers line up.
	var k0 := int(ceil((vmin + spacing * 0.5) / spacing))
	var k1 := int(floor((vmax - spacing * 0.5) / spacing))
	var ne := eu.size() / 2
	var flip := false
	var segs_all: Array = []
	for k in range(k0, k1 + 1):
		var line_v := float(k) * spacing
		var xs := PackedFloat32Array()
		for e in ne:
			var v0 := ev[e * 2]
			var v1 := ev[e * 2 + 1]
			if (v0 < line_v) == (v1 < line_v):
				continue
			if absf(v1 - v0) <= 1e-12:
				continue
			var t := (line_v - v0) / (v1 - v0)
			xs.append(eu[e * 2] + (eu[e * 2 + 1] - eu[e * 2]) * t)
		if xs.size() < 2:
			continue
		xs.sort()
		var segs: Array = []
		var i := 0
		while i + 1 < xs.size():
			var a := xs[i]
			var b := xs[i + 1]
			if b - a > spacing * 0.25:
				segs.append([a, b])
			i += 2
		if flip:
			segs.reverse()
		for sg in segs:
			var a_u: float = sg[1] if flip else sg[0]
			var b_u: float = sg[0] if flip else sg[1]
			segs_all.append([u * a_u + v * line_v, u * b_u + v * line_v])
		flip = not flip
	for sg in segs_all:
		em.line(sg[0], sg[1], z, speed)


# ---------------------------------------------------------------------------
# The move list, as a firmware would see it
# ---------------------------------------------------------------------------

class _Emitter:
	var moves := PrintMoves.new()
	var pos := Vector3(NAN, NAN, NAN)
	var travel_speed := 120.0
	var hop := 0.0
	var epm := 0.01
	var line_no := 0

	func _travel_to(p: Vector3) -> void:
		if is_nan(pos.x):
			pos = p
			return
		if pos.distance_squared_to(p) <= 1e-10:
			return
		if hop > 0.0 and absf(p.z - pos.z) < 1e-6:
			var up := Vector3(pos.x, pos.y, pos.z + hop)
			_add(pos, up, travel_speed, 0.0, true)
			var over := Vector3(p.x, p.y, p.z + hop)
			_add(up, over, travel_speed, 0.0, true)
			_add(over, p, travel_speed, 0.0, true)
		else:
			_add(pos, p, travel_speed, 0.0, true)
		pos = p

	func _add(a: Vector3, b: Vector3, feed: float, e: float, rapid: bool) -> void:
		line_no += 1
		moves.append(a, b, feed, e, rapid, line_no)

	func _extrude_to(p: Vector3, speed: float) -> void:
		var l := pos.distance_to(p)
		if l < 1e-3:
			# Under a micron: a G-code file rounds it to nothing, so it is
			# folded into the next move (a gap no wider than itself).
			pos = p
			return
		_add(pos, p, speed, l * epm, false)
		pos = p

	## A closed loop at z, started at the vertex nearest the nozzle.
	func loop(ring: PackedVector2Array, z: float, speed: float) -> void:
		var n := ring.size()
		if n < 3:
			return
		var start := 0
		if not is_nan(pos.x):
			var best := INF
			for i in n:
				var d := ring[i].distance_squared_to(Vector2(pos.x, pos.y))
				if d < best:
					best = d
					start = i
		var p0 := Vector3(ring[start].x, ring[start].y, z)
		_travel_to(p0)
		for k in range(1, n + 1):
			var q := ring[(start + k) % n]
			_extrude_to(Vector3(q.x, q.y, z), speed)

	## One turn of the spiral: the loop with Z ramping z0 → z1 along it.
	func spiral(ring: PackedVector2Array, z0: float, z1: float, speed: float) -> void:
		var n := ring.size()
		if n < 3:
			return
		var start := 0
		if not is_nan(pos.x):
			var best := INF
			for i in n:
				var d := ring[i].distance_squared_to(Vector2(pos.x, pos.y))
				if d < best:
					best = d
					start = i
		var total := 0.0
		for i in n:
			total += ring[i].distance_to(ring[(i + 1) % n])
		if total <= 1e-9:
			return
		var p0 := Vector3(ring[start].x, ring[start].y, z0)
		if is_nan(pos.x) or pos.distance_to(p0) > 1e-3:
			_travel_to(p0)
		var acc := 0.0
		for k in range(1, n + 1):
			var a := ring[(start + k - 1) % n]
			var b := ring[(start + k) % n]
			acc += a.distance_to(b)
			var z := z0 + (z1 - z0) * clampf(acc / total, 0.0, 1.0)
			_extrude_to(Vector3(b.x, b.y, z), speed)

	func line(a: Vector2, b: Vector2, z: float, speed: float) -> void:
		var pa := Vector3(a.x, a.y, z)
		var pb := Vector3(b.x, b.y, z)
		if not is_nan(pos.x) and pos.distance_to(pb) < pos.distance_to(pa):
			var t := pa
			pa = pb
			pb = t
		_travel_to(pa)
		_extrude_to(pb, speed)
