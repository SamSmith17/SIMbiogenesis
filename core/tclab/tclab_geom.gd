class_name TcGeom
extends RefCounted

## Mesh maths for the TC designer, in MILLIMETRES, pure (no nodes). A part
## is built into a `TcGeom` accumulator: per material key, flat triangle
## lists of positions + normals (non-indexed). The builder scales by 0.001
## and turns each material into one surface.
##
## Winding: Godot's front face is CLOCKWISE seen from outside, i.e. for a
## front triangle cross(b − a, c − a) · n < 0. `tri` takes the normals the
## caller means and swaps b / c when needed, so every emitter here is right
## by construction (the selftest checks every triangle of every part). No
## `generate_normals()` anywhere: each emitter writes the normal it means
## (the dome lab's "bubble" trap).
##
## Lathe profiles are lists of Vector2(r, z) walked with the solid on the
## LEFT (in an r-right / z-up drawing); the outward normal of a segment is
## then (dz, −dr). Axis = local +Z.

var _mats: Dictionary = {}   # key -> {"v": PackedVector3Array, "n": PackedVector3Array}
var _cur := ""
var _cv := PackedVector3Array()
var _cn := PackedVector3Array()


## Packed arrays fetched from a Dictionary are copy-on-write values, so the
## material being written is held in members and stored back on a switch.
func _sel(mat: String) -> void:
	if mat == _cur:
		return
	_flush()
	_cur = mat
	if _mats.has(mat):
		_cv = _mats[mat]["v"]
		_cn = _mats[mat]["n"]
	else:
		_cv = PackedVector3Array()
		_cn = PackedVector3Array()


func _flush() -> void:
	if _cur.is_empty():
		return
	_mats[_cur] = {"v": _cv, "n": _cn}


## Every material's arrays: {key: {"v", "n"}}.
func get_mats() -> Dictionary:
	_flush()
	return _mats


## One triangle with vertex normals; winding fixed to Godot's front face.
func tri(mat: String, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
	_sel(mat)
	var face := (b - a).cross(c - a)
	if face.dot(na + nb + nc) > 0.0:
		_cv.append(a); _cv.append(c); _cv.append(b)
		_cn.append(na); _cn.append(nc); _cn.append(nb)
	else:
		_cv.append(a); _cv.append(b); _cv.append(c)
		_cn.append(na); _cn.append(nb); _cn.append(nc)


func quad(mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3) -> void:
	tri(mat, a, b, c, na, nb, nc)
	tri(mat, a, c, d, na, nc, nd)


## Append another accumulator through a transform (mm → mm).
func merge(other: TcGeom, xf: Transform3D = Transform3D.IDENTITY) -> void:
	var nb := xf.basis.inverse().transposed()
	var flip := xf.basis.determinant() < 0.0
	var om := other.get_mats()
	# A rigid transform (every assembly placement): whole arrays at once —
	# the per-vertex loop made a 200-part world build ~300 ms.
	var rigid := not flip and xf.basis.get_scale().is_equal_approx(Vector3.ONE)
	for k in om:
		_sel(str(k))
		var sv: PackedVector3Array = om[k]["v"]
		var sn: PackedVector3Array = om[k]["n"]
		if rigid:
			_cv.append_array(xf * sv)
			_cn.append_array(Transform3D(xf.basis, Vector3.ZERO) * sn)
			continue
		var i := 0
		while i < sv.size():
			if flip:
				_cv.append(xf * sv[i]); _cv.append(xf * sv[i + 2]); _cv.append(xf * sv[i + 1])
				_cn.append((nb * sn[i]).normalized()); _cn.append((nb * sn[i + 2]).normalized()); _cn.append((nb * sn[i + 1]).normalized())
			else:
				_cv.append(xf * sv[i]); _cv.append(xf * sv[i + 1]); _cv.append(xf * sv[i + 2])
				_cn.append((nb * sn[i]).normalized()); _cn.append((nb * sn[i + 1]).normalized()); _cn.append((nb * sn[i + 2]).normalized())
			i += 3


func vertex_count() -> int:
	var c := 0
	var m := get_mats()
	for k in m:
		c += (m[k]["v"] as PackedVector3Array).size()
	return c


## Local AABB of everything drawn (mm).
func aabb() -> AABB:
	var first := true
	var bb := AABB()
	var m := get_mats()
	for k in m:
		for p in (m[k]["v"] as PackedVector3Array):
			if first:
				bb = AABB(p, Vector3.ZERO)
				first = false
			else:
				bb = bb.expand(p)
	return bb


## Segments round a circle of radius r (mm): enough that the facets never read.
## Segments round a circle of radius r (mm). `seg_scale` < 1 draws the far
## level of detail (TcBuilder): parts built while it is set are cached apart.
static var seg_scale := 1.0


static func segs_for(r: float) -> int:
	if seg_scale < 0.999:
		return clampi(int((18.0 + r * 0.55) * seg_scale), 6, 72)
	return clampi(int(18.0 + r * 0.55), 20, 72)


# ---------------------------------------------------------------------------
# Lathe
# ---------------------------------------------------------------------------

## Revolve `profile` (Vector2 r, z; solid on the left) about local +Z
## through `xf`. `a0` / `a1` in radians (a partial revolve for a clamp band).
## `smooth` gives each profile vertex the average of its two segments'
## normals (a curved profile); otherwise every segment is flat-shaded in the
## profile direction (machined edges).
func lathe(mat: String, profile: Array, xf: Transform3D = Transform3D.IDENTITY, segs: int = 32,
		a0: float = 0.0, a1: float = TAU, smooth: bool = false) -> void:
	if profile.size() < 2:
		return
	var nb := xf.basis.inverse().transposed()
	var full := is_equal_approx(a1 - a0, TAU)
	var cs := PackedFloat64Array()
	var sn := PackedFloat64Array()
	for k in segs + 1:
		var t := a0 + (a1 - a0) * float(k) / float(segs)
		cs.append(cos(t))
		sn.append(sin(t))
	# Per-segment 2D normals.
	var seg_n: Array = []
	for i in profile.size() - 1:
		var p0: Vector2 = profile[i]
		var p1: Vector2 = profile[i + 1]
		var dr := p1.x - p0.x
		var dz := p1.y - p0.y
		var l := sqrt(dr * dr + dz * dz)
		seg_n.append(Vector2(dz / l, -dr / l) if l > 1e-9 else Vector2(1, 0))
	for i in profile.size() - 1:
		var p0: Vector2 = profile[i]
		var p1: Vector2 = profile[i + 1]
		if p0.distance_to(p1) < 1e-6:
			continue
		var n0: Vector2 = seg_n[i]
		var n1: Vector2 = seg_n[i]
		if smooth:
			if i > 0:
				n0 = ((seg_n[i - 1] as Vector2) + n0).normalized()
			if i + 1 < seg_n.size():
				n1 = ((seg_n[i + 1] as Vector2) + n1).normalized()
		for k in segs:
			var k1 := k + 1
			var a := Vector3(p0.x * cs[k], p0.x * sn[k], p0.y)
			var b := Vector3(p0.x * cs[k1], p0.x * sn[k1], p0.y)
			var c := Vector3(p1.x * cs[k1], p1.x * sn[k1], p1.y)
			var d := Vector3(p1.x * cs[k], p1.x * sn[k], p1.y)
			var na := Vector3(n0.x * cs[k], n0.x * sn[k], n0.y)
			var nb2 := Vector3(n0.x * cs[k1], n0.x * sn[k1], n0.y)
			var nc := Vector3(n1.x * cs[k1], n1.x * sn[k1], n1.y)
			var nd := Vector3(n1.x * cs[k], n1.x * sn[k], n1.y)
			na = (nb * na).normalized(); nb2 = (nb * nb2).normalized()
			nc = (nb * nc).normalized(); nd = (nb * nd).normalized()
			if p0.x < 1e-6:
				tri(mat, xf * a, xf * c, xf * d, na, nc, nd)
			elif p1.x < 1e-6:
				tri(mat, xf * a, xf * b, xf * c, na, nb2, nc)
			else:
				quad(mat, xf * a, xf * b, xf * c, xf * d, na, nb2, nc, nd)
	if not full:
		# Close the two ends of a partial revolve with the profile itself.
		_cap_profile(mat, profile, xf, a0, true)
		_cap_profile(mat, profile, xf, a1, false)


## Fill a closed profile's plane at angle `a` (the end of a partial revolve).
func _cap_profile(mat: String, profile: Array, xf: Transform3D, a: float, start: bool) -> void:
	var nb := xf.basis.inverse().transposed()
	var c := cos(a)
	var s := sin(a)
	# The plane's normal: tangent of the revolve, pointing away from the solid.
	var tn := Vector3(-s, c, 0.0) * (-1.0 if start else 1.0)
	var n := (nb * tn).normalized()
	var pts := PackedVector2Array()
	for p in profile:
		pts.append(p as Vector2)
	if pts.size() > 3 and pts[0].distance_to(pts[pts.size() - 1]) < 1e-6:
		pts.remove_at(pts.size() - 1)
	var idx := Geometry2D.triangulate_polygon(pts)
	var i := 0
	while i + 2 < idx.size():
		var q: Array = []
		for j in 3:
			var p: Vector2 = pts[idx[i + j]]
			q.append(xf * Vector3(p.x * c, p.x * s, p.y))
		tri(mat, q[0], q[1], q[2], n, n, n)
		i += 3


# ---------------------------------------------------------------------------
# Swept tubes (bends, legs)
# ---------------------------------------------------------------------------

## A tube of radius r along `path` (mm), rings framed by parallel transport.
## `outward` false draws a bore (normals toward the centre line).
func sweep(mat: String, path: PackedVector3Array, r: float, outward: bool = true, segs: int = 32) -> void:
	if path.size() < 2:
		return
	var tangents: Array = []
	for i in path.size():
		var t := Vector3.ZERO
		if i == 0:
			t = path[1] - path[0]
		elif i == path.size() - 1:
			t = path[i] - path[i - 1]
		else:
			t = (path[i + 1] - path[i]).normalized() + (path[i] - path[i - 1]).normalized()
		tangents.append(t.normalized())
	var t0: Vector3 = tangents[0]
	var u := Vector3.UP if absf(t0.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	u = (u - t0 * u.dot(t0)).normalized()
	var rings: Array = []
	var prev_t := t0
	for i in path.size():
		var t: Vector3 = tangents[i]
		var ax := prev_t.cross(t)
		if ax.length() > 1e-9:
			var ang := prev_t.angle_to(t)
			u = u.rotated(ax.normalized(), ang)
		u = (u - t * u.dot(t)).normalized()
		var w := t.cross(u)
		var ring: Array = []
		for k in segs:
			var a := TAU * float(k) / float(segs)
			var dir := u * cos(a) + w * sin(a)
			ring.append([path[i] + dir * r, dir if outward else -dir])
		rings.append(ring)
		prev_t = t
	for i in path.size() - 1:
		var r0: Array = rings[i]
		var r1: Array = rings[i + 1]
		for k in segs:
			var k1 := (k + 1) % segs
			quad(mat, r0[k][0], r0[k1][0], r1[k1][0], r1[k][0], r0[k][1], r0[k1][1], r1[k1][1], r1[k][1])


## Points along an arc centre-line: from `start` turning about `axis_c`
## (centre of the bend) through `angle` radians, `n` steps (start included).
static func arc_points(centre: Vector3, start: Vector3, axis: Vector3, angle: float, n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var rv := start - centre
	for i in n + 1:
		out.append(centre + rv.rotated(axis.normalized(), angle * float(i) / float(n)))
	return out


# ---------------------------------------------------------------------------
# Boxes and cylinders (hardware)
# ---------------------------------------------------------------------------

## An oriented box: centre, half extents along the basis columns.
func box(mat: String, xf: Transform3D, half: Vector3) -> void:
	var ax := [xf.basis.x.normalized(), xf.basis.y.normalized(), xf.basis.z.normalized()]
	var hs := [xf.basis.x.length() * half.x, xf.basis.y.length() * half.y, xf.basis.z.length() * half.z]
	var c := xf.origin
	for f in 3:
		for sgn in [-1.0, 1.0]:
			var n: Vector3 = ax[f] * sgn
			var u: Vector3 = ax[(f + 1) % 3] * hs[(f + 1) % 3]
			var v: Vector3 = ax[(f + 2) % 3] * hs[(f + 2) % 3]
			var o: Vector3 = c + n * hs[f]
			quad(mat, o - u - v, o + u - v, o + u + v, o - u + v, n, n, n, n)


## A solid cylinder from a to b, radius r.
func cylinder(mat: String, a: Vector3, b: Vector3, r: float, segs: int = 16) -> void:
	var l := a.distance_to(b)
	if l < 1e-6:
		return
	lathe(mat, [Vector2(0, 0), Vector2(r, 0), Vector2(r, l), Vector2(0, l)], frame_along(a, b - a), segs)


## A hexagonal prism (a nut, a hex boss) from a along dir, across-flats af.
func hex(mat: String, a: Vector3, dir: Vector3, length: float, af: float, hole_r: float = 0.0) -> void:
	var rc := af * 0.5 / cos(PI / 6.0)
	var prof: Array = []
	if hole_r > 0.0:
		prof = [Vector2(hole_r, length), Vector2(hole_r, 0), Vector2(rc, 0), Vector2(rc, length), Vector2(hole_r, length)]
	else:
		prof = [Vector2(0, 0), Vector2(rc, 0), Vector2(rc, length), Vector2(0, length)]
	lathe(mat, prof, frame_along(a, dir), 6, PI / 6.0, PI / 6.0 + TAU)


## A frame whose +Z runs along `dir`, origin `o`.
static func frame_along(o: Vector3, dir: Vector3) -> Transform3D:
	var z := dir.normalized()
	var ref := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(z).normalized()
	var y := z.cross(x)
	return Transform3D(Basis(x, y, z), o)


# ---------------------------------------------------------------------------
# Sanitary pieces
# ---------------------------------------------------------------------------

## The ferrule profile at a port: face at z = 0, the part's body toward +z
## (callers pass a frame whose +Z points INTO the part). Draws the face with
## its gasket groove, the flange rim, the 20° back taper, the hub and the
## bore over the hub. Returns the hub length (where the tube body starts).
func ferrule_end(xf: Transform3D, size: String, long: bool = false, mat: String = "steel",
		hub_override: float = -1.0) -> float:
	var t := TcStandards.tube(size)
	var f := TcStandards.ferrule(size, long)
	var r_in := float(t["r_in"])
	var r_out := float(t["r_out"])
	var r_fl := float(t["r_flange"])
	var rim := float(f["rim"])
	var taper := float(f["taper"])
	var hub := hub_override if hub_override > 0.0 else float(f["hub"])
	hub = maxf(hub, rim + taper + 0.5)
	var g: Array = f["groove"]
	var gd := float(f["groove_depth"])
	var prof := [Vector2(r_in, hub), Vector2(r_in, 0.0),
		Vector2(float(g[0]), 0.0), Vector2(float(g[0]), gd), Vector2(float(g[1]), gd), Vector2(float(g[1]), 0.0),
		Vector2(r_fl, 0.0), Vector2(r_fl, rim), Vector2(r_out, rim + taper), Vector2(r_out, hub)]
	lathe(mat, prof, xf, segs_for(r_fl))
	return hub


## A straight tube body (outer + bore) from z0 to z1 along a frame's +Z.
func tube_body(xf: Transform3D, size: String, z0: float, z1: float, mat: String = "steel") -> void:
	if z1 - z0 < 1e-4:
		return
	var t := TcStandards.tube(size)
	var r_in := float(t["r_in"])
	var r_out := float(t["r_out"])
	var n := segs_for(float(t["r_flange"]))
	lathe(mat, [Vector2(r_out, z0), Vector2(r_out, z1)], xf, n)
	lathe(mat, [Vector2(r_in, z1), Vector2(r_in, z0)], xf, n)


## A bent tube body (outer + bore) along a centre-line path.
func bent_body(path: PackedVector3Array, size: String, mat: String = "steel") -> void:
	var t := TcStandards.tube(size)
	var n := segs_for(float(t["r_flange"]))
	sweep(mat, path, float(t["r_out"]), true, n)
	sweep(mat, path, float(t["r_in"]), false, n)


## The gasket ring between two faces: centred on z = 0 of `xf`, `gap` thick.
func gasket(xf: Transform3D, size: String, gap: float, mat: String) -> void:
	var t := TcStandards.tube(size)
	var r_in := float(t["r_in"])
	var r_o := float(t["r_flange"]) * 0.985
	var h := gap * 0.5
	lathe(mat, [Vector2(r_in, h), Vector2(r_in, -h), Vector2(r_o, -h), Vector2(r_o, h), Vector2(r_in, h)],
		xf, segs_for(r_o))


## A hinged clamp round a joint (z = 0 of `xf` is the gasket plane): a
## V-section band over both flanges with its opening at local +X (the wing
## nut) and the hinge at −X.
func clamp(xf: Transform3D, size: String, gap: float, kind: String = "single_pin", mat: String = "hardware") -> void:
	var t := TcStandards.tube(size)
	var f := TcStandards.ferrule(size)
	var r_out := float(t["r_out"])
	var r_fl := float(t["r_flange"])
	var rim := float(f["rim"])
	var taper := float(f["taper"])
	var w := gap * 0.5 + rim + taper * 0.6
	var band_t := clampf(r_fl * 0.09, 2.2, 6.0)
	var ro := r_fl + band_t
	var r_lip := r_out + (r_fl - r_out) * 0.42
	var prof := [Vector2(r_lip, w), Vector2(r_fl + 0.3, gap * 0.5 + rim * 0.9),
		Vector2(r_fl + 0.3, -gap * 0.5 - rim * 0.9), Vector2(r_lip, -w),
		Vector2(ro, -w - 0.6), Vector2(ro, w + 0.6), Vector2(r_lip, w)]
	# Two half bands, a small gap at the hinge, a bigger one at the opening.
	var open := clampf(14.0 / ro, 0.12, 0.42)
	var segs := segs_for(ro)
	var half_segs := int(segs * 0.5)
	lathe(mat, prof, xf, half_segs, open, PI - 0.04)
	lathe(mat, prof, xf, half_segs, PI + 0.04, TAU - open)
	# Hinge pin along the axis at −X.
	var bx := xf.basis.x.normalized()
	var by := xf.basis.y.normalized()
	var bz := xf.basis.z.normalized()
	var hinge := xf.origin - bx * (ro + band_t * 0.4)
	cylinder(mat, hinge - bz * (w + 0.8), hinge + bz * (w + 0.8), band_t * 0.55, 10)
	# Lugs either side of the opening, the bolt across them, the wing nut.
	var lug_h := Vector3(band_t * 1.6, band_t * 0.55, w)
	var ya := sin(open) * ro
	for sgn in [-1.0, 1.0]:
		var c: Vector3 = xf.origin + bx * (cos(open) * (ro + lug_h.x * 0.5)) + by * (ya + lug_h.y) * sgn
		box(mat, Transform3D(Basis(bx, by, bz), c), lug_h)
	var bolt_c := xf.origin + bx * (ro + band_t * 0.9)
	var blen := ya * 2.0 + lug_h.y * 6.0
	cylinder(mat, bolt_c - by * blen * 0.5, bolt_c + by * blen * 0.6, band_t * 0.32, 8)
	if kind == "bolted":
		hex(mat, bolt_c + by * (ya + lug_h.y * 2.0), by, band_t * 0.9, band_t * 1.6)
	else:
		var wn := bolt_c + by * (ya + lug_h.y * 2.6)
		box(mat, Transform3D(Basis(bx, by, bz), wn), Vector3(band_t * 2.4, band_t * 0.5, band_t * 0.35))


## A male NPT thread from z = 0 to z = length of `xf` (a sawtooth lathe,
## 14 TPI to ½", 11½ above), closed at the tip. Female threads are drawn as
## a plain bore by their owners.
func npt_thread(xf: Transform3D, size: String, length: float, mat: String = "steel") -> void:
	var r := TcStandards.npt_od(size) * 0.5
	var pitch := 25.4 / (14.0 if r < 14.0 else 11.5)
	var depth := pitch * 0.32
	var prof: Array = [Vector2(r - depth, 0.0)]
	var z := 0.0
	while z + pitch <= length:
		prof.append(Vector2(r, z + pitch * 0.5))
		prof.append(Vector2(r - depth, z + pitch))
		z += pitch
	prof.append(Vector2(r - depth, length))
	prof.append(Vector2(0.0, length))
	lathe(mat, prof, xf, segs_for(r))
