class_name BattParts
extends RefCounted

## Detailed battery hardware as triangle meshes: swept cable (a tube along a
## bent path), ring lugs, heat-shrink, hex nuts, washers, threaded studs,
## tapered SAE posts, rounded busbars, discs. Positions in MILLIMETRES go
## into a `Geo` accumulator, which keeps one surface per finish ("jacket",
## "metal", "plastic", ...) with vertex colours and writes metres.
##
## Every triangle is wound to its normal (Godot's front face is clockwise
## seen from the normal's side: cross(b - a, c - a) · n < 0).

const MM := 0.001

## Finish → [metallic, roughness].
const FINISH := {
	"jacket": [0.0, 0.55], "shrink": [0.0, 0.42], "metal": [0.85, 0.3], "tin": [0.7, 0.38],
	"plastic": [0.0, 0.5], "rubber": [0.0, 0.8], "board": [0.1, 0.5],
}


class Surf:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()

	func add(a: Vector3, b: Vector3, cc: Vector3, na: Vector3, nb: Vector3, nc: Vector3, col: Color) -> void:
		v.append(a * MM)
		v.append(b * MM)
		v.append(cc * MM)
		n.append(na)
		n.append(nb)
		n.append(nc)
		c.append(col)
		c.append(col)
		c.append(col)


class Geo:
	# finish -> Surf. (A packed array fetched from a Dictionary is a copy,
	# so each surface appends to its own members.)
	var surf: Dictionary = {}

	func _s(finish: String) -> Surf:
		if not surf.has(finish):
			surf[finish] = Surf.new()
		return surf[finish]

	## One triangle (mm), wound so its front faces `fn` (the face's own
	## normal); vertex normals na / nb / nc.
	func tri(finish: String, col: Color, a: Vector3, b: Vector3, c: Vector3,
			na: Vector3, nb: Vector3, nc: Vector3, fn: Vector3) -> void:
		var lc := col.srgb_to_linear()
		if (b - a).cross(c - a).dot(fn) > 0.0:
			_s(finish).add(a, c, b, na, nc, nb, lc)
		else:
			_s(finish).add(a, b, c, na, nb, nc, lc)

	func quad(finish: String, col: Color, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
			na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3) -> void:
		var fn := (na + nb + nc + nd)
		if fn.length_squared() < 1e-9:
			fn = (b - a).cross(d - a)
		tri(finish, col, a, b, c, na, nb, nc, fn)
		tri(finish, col, a, c, d, na, nc, nd, fn)

	func flat_quad(finish: String, col: Color, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
		quad(finish, col, a, b, c, d, n, n, n, n)

	func tri_count() -> int:
		var t := 0
		for k in surf:
			t += (surf[k] as Surf).v.size() / 3
		return t

	func is_empty() -> bool:
		return tri_count() == 0

	## An ArrayMesh with a surface per finish (vertex colours as albedo).
	func commit() -> ArrayMesh:
		var am := ArrayMesh.new()
		for k in surf:
			var sf: Surf = surf[k]
			if sf.v.is_empty():
				continue
			var arr := []
			arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = sf.v
			arr[Mesh.ARRAY_NORMAL] = sf.n
			arr[Mesh.ARRAY_COLOR] = sf.c
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			am.surface_set_material(am.get_surface_count() - 1, BattParts.material(str(k)))
		return am


static var _mats: Dictionary = {}


static func material(finish: String) -> StandardMaterial3D:
	if _mats.has(finish):
		return _mats[finish]
	var mat_id := "plastic"
	match finish:
		"metal": mat_id = "aluminium"
		"tin": mat_id = "galvanised"
		"copper": mat_id = "copper"
		"brass": mat_id = "brass_bronze"
		"rubber": mat_id = "rubber"
		"board": mat_id = "powder_coat"
		"jacket", "shrink", "plastic": mat_id = "plastic"
	var m := ParametricMaterialLibrary.make(mat_id, Color.WHITE, {
		"vertex_color": true,
		"cull_mode": BaseMaterial3D.CULL_BACK,
	})
	_mats[finish] = m
	return m


## Two unit vectors ⊥ n.
static func frame(n: Vector3) -> Array:
	var nn := n.normalized()
	var u := nn.cross(Vector3.UP if absf(nn.y) < 0.9 else Vector3.RIGHT).normalized()
	return [u, nn.cross(u).normalized()]


# ---------------------------------------------------------------------------
# Cable
# ---------------------------------------------------------------------------

## A round tube of diameter `d` along `path` (mm), frames carried along the
## path by parallel transport (no twist), both ends capped.
static func tube(g: Geo, path: PackedVector3Array, d: float, col: Color, finish: String = "jacket",
		sides: int = 10, caps: bool = true) -> void:
	var n := path.size()
	if n < 2:
		return
	var r := d * 0.5
	var tans: Array = []
	for i in n:
		var t := Vector3.ZERO
		if i > 0:
			t += (path[i] - path[i - 1]).normalized()
		if i < n - 1:
			t += (path[i + 1] - path[i]).normalized()
		if t.length_squared() < 1e-9:
			t = (path[mini(i + 1, n - 1)] - path[maxi(i - 1, 0)])
		tans.append(t.normalized())
	var f: Array = frame(tans[0])
	var u: Vector3 = f[0]
	var rings: Array = []
	var norms: Array = []
	for i in n:
		var t: Vector3 = tans[i]
		if i > 0:
			var tp: Vector3 = tans[i - 1]
			var ax := tp.cross(t)
			if ax.length_squared() > 1e-12:
				u = u.rotated(ax.normalized(), tp.angle_to(t))
			u = (u - t * u.dot(t)).normalized()
		var w := t.cross(u)
		# A bent tube's section stays round on the plane ⊥ the bisector.
		var ring := PackedVector3Array()
		var nr := PackedVector3Array()
		for k in sides:
			var a := TAU * float(k) / float(sides)
			var rv := u * cos(a) + w * sin(a)
			ring.append(path[i] + rv * r)
			nr.append(rv)
		rings.append(ring)
		norms.append(nr)
	for i in range(1, n):
		var r0: PackedVector3Array = rings[i - 1]
		var r1: PackedVector3Array = rings[i]
		var n0: PackedVector3Array = norms[i - 1]
		var n1: PackedVector3Array = norms[i]
		for k in sides:
			var k1 := (k + 1) % sides
			g.quad(finish, col, r0[k], r0[k1], r1[k1], r1[k], n0[k], n0[k1], n1[k1], n1[k])
	if caps:
		_cap(g, path[0], -(tans[0] as Vector3), rings[0], col, finish)
		_cap(g, path[n - 1], tans[n - 1], rings[n - 1], col, finish)


## A flat strap along `path`: width across, thickness the easy way to bend.
## The section is carried by parallel transport, starting with its thin axis
## toward world up so a horizontal run lies flat.
static func ribbon(g: Geo, path: PackedVector3Array, width: float, thick: float, col: Color,
		finish: String = "jacket") -> void:
	var n := path.size()
	if n < 2 or width < 0.2 or thick < 0.2:
		return
	var tans: Array = []
	for i in n:
		var t := Vector3.ZERO
		if i > 0:
			t += (path[i] - path[i - 1]).normalized()
		if i < n - 1:
			t += (path[i + 1] - path[i]).normalized()
		if t.length_squared() < 1e-9:
			t = path[mini(i + 1, n - 1)] - path[maxi(i - 1, 0)]
		tans.append(t.normalized())
	var t0: Vector3 = tans[0]
	var ref := Vector3.UP if absf(t0.dot(Vector3.UP)) < 0.9 else Vector3.FORWARD
	var u := ref.cross(t0).normalized()
	var hw := width * 0.5
	var ht := thick * 0.5
	var rings: Array = []
	var norms: Array = []
	for i in n:
		var tv: Vector3 = tans[i]
		if i > 0:
			var tp: Vector3 = tans[i - 1]
			var ax := tp.cross(tv)
			if ax.length_squared() > 1e-12:
				u = u.rotated(ax.normalized(), tp.angle_to(tv))
			u = (u - tv * u.dot(tv)).normalized()
		var w := tv.cross(u).normalized()
		var ring := PackedVector3Array()
		var nr := PackedVector3Array()
		for off in [u * hw + w * ht, -u * hw + w * ht, -u * hw - w * ht, u * hw - w * ht]:
			ring.append(path[i] + off)
			nr.append((off as Vector3).normalized())
		rings.append(ring)
		norms.append(nr)
	for i in range(1, n):
		var r0: PackedVector3Array = rings[i - 1]
		var r1: PackedVector3Array = rings[i]
		var n0: PackedVector3Array = norms[i - 1]
		var n1: PackedVector3Array = norms[i]
		for k in 4:
			var k1 := (k + 1) % 4
			g.quad(finish, col, r0[k], r0[k1], r1[k1], r1[k], n0[k], n0[k1], n1[k1], n1[k])
	_cap(g, path[0], -(tans[0] as Vector3), rings[0], col, finish)
	_cap(g, path[n - 1], tans[n - 1], rings[n - 1], col, finish)


static func _cap(g: Geo, c: Vector3, n: Vector3, ring: PackedVector3Array, col: Color, finish: String) -> void:
	for k in ring.size():
		g.tri(finish, col, c, ring[k], ring[(k + 1) % ring.size()], n, n, n, n)


## A ring lug crimped on a cable, its tongue flat on a stud at `p` with
## normal `n` (the lug sits on the `n` side), its barrel running along `t`.
## `lg` from BattWire.lug. Then heat-shrink over the barrel's back half and
## onto the cable (`shrink` colour; none when alpha is 0).
static func ring_lug(g: Geo, p: Vector3, n: Vector3, t: Vector3, lg: Dictionary, shrink: Color,
		metal: Color = Color(0.8, 0.8, 0.78)) -> void:
	var nn := n.normalized()
	var tt := (t - nn * t.dot(nn)).normalized()
	var tw := float(lg["tongue_w"])
	var tth := float(lg["tongue_t"])
	var bod := float(lg["barrel_od"])
	var blen := float(lg["barrel_len"])
	var reach := float(lg["reach"])
	var hole := float(lg["hole_d"]) * 0.5
	var c := p + nn * tth * 0.5
	# Round end: an annulus round the stud.
	annulus(g, c, nn, tw * 0.5, hole, tth, metal, "tin", 18)
	# Neck: from the round end to the barrel, a flat tapering plate.
	var b0 := reach - blen
	var neck_a := c + tt * tw * 0.3
	var neck_b := c + tt * b0
	plate(g, neck_a, neck_b, nn, tw * 0.62, bod * 0.85, tth, metal, "tin")
	# Barrel: a short tube lying on the tongue, its mouth flared a little.
	var lift := tth * 0.5 + bod * 0.5
	var ba := p + nn * lift + tt * b0
	var bb := p + nn * lift + tt * reach
	tube(g, PackedVector3Array([ba, bb]), bod, metal, "tin", 14)
	# Crimp marks: two dimples on top.
	for f in [0.35, 0.7]:
		var cp := ba.lerp(bb, f) + nn * bod * 0.48
		disc(g, cp, nn, bod * 0.22, 0.4, metal.darkened(0.25), "tin", 8)
	if shrink.a > 0.0:
		var s0 := ba.lerp(bb, 0.45)
		var s1 := bb + tt * maxf(float(lg["sleeve_len"]) - blen * 0.55, 4.0)
		tube(g, PackedVector3Array([s0, s1]), bod * 1.1, shrink, "shrink", 14)


## A flat plate from a to b (its centre line) of width wa at a, wb at b,
## thickness th centred on its plane (normal n).
static func plate(g: Geo, a: Vector3, b: Vector3, n: Vector3, wa: float, wb: float, th: float,
		col: Color, finish: String) -> void:
	var t := (b - a)
	if t.length() < 1e-3:
		return
	t = t.normalized()
	var s := n.cross(t).normalized()
	var h := n * th * 0.5
	var pts := [a + s * wa * 0.5, b + s * wb * 0.5, b - s * wb * 0.5, a - s * wa * 0.5]
	var top: Array = pts.map(func(q): return (q as Vector3) + h)
	var bot: Array = pts.map(func(q): return (q as Vector3) - h)
	g.flat_quad(finish, col, top[0], top[1], top[2], top[3], n)
	g.flat_quad(finish, col, bot[0], bot[3], bot[2], bot[1], -n)
	for i in 4:
		var j := (i + 1) % 4
		var en: Vector3 = ((top[i] + top[j]) * 0.5 - (a + b) * 0.5)
		en = (en - n * en.dot(n)).normalized()
		g.flat_quad(finish, col, top[i], bot[i], bot[j], top[j], en)


# ---------------------------------------------------------------------------
# Turned and machined parts (surfaces of revolution)
# ---------------------------------------------------------------------------

## Revolve a profile [(r, h)…] round the axis through `c` along `n`. The
## profile runs from the bottom near the axis, round the OUTSIDE, to the top
## (so the solid is on its left); each segment gets its own normal
## (dh, −dr), so edges stay crisp. `sides` 6 with `flat` true is a hex.
static func lathe(g: Geo, c: Vector3, n: Vector3, profile: Array, col: Color, finish: String,
		sides: int = 16, flat: bool = false, phase: float = 0.0) -> void:
	var f := frame(n)
	var u: Vector3 = f[0]
	var w: Vector3 = f[1]
	var nn := n.normalized()
	var dirs: Array = []
	for k in sides + 1:
		var a := phase + TAU * float(k) / float(sides)
		dirs.append(u * cos(a) + w * sin(a))
	for i in range(1, profile.size()):
		var p0: Vector2 = profile[i - 1]
		var p1: Vector2 = profile[i]
		var dr := p1.x - p0.x
		var dh := p1.y - p0.y
		var l2 := Vector2(dh, -dr).normalized()
		if Vector2(dr, dh).length() < 1e-6:
			continue
		for k in sides:
			var d0: Vector3 = dirs[k]
			var d1: Vector3 = dirs[k + 1]
			var a0 := c + d0 * p0.x + nn * p0.y
			var a1 := c + d1 * p0.x + nn * p0.y
			var b0 := c + d0 * p1.x + nn * p1.y
			var b1 := c + d1 * p1.x + nn * p1.y
			var m0 := d0
			var m1 := d1
			if flat:
				var mid := (d0 + d1).normalized()
				m0 = mid
				m1 = mid
			var na := (m0 * l2.x + nn * l2.y).normalized()
			var nb := (m1 * l2.x + nn * l2.y).normalized()
			g.quad(finish, col, a0, a1, b1, b0, na, nb, nb, na)


## A flat disc (solid) of radius r and thickness th on the `n` side of c.
static func disc(g: Geo, c: Vector3, n: Vector3, r: float, th: float, col: Color, finish: String,
		sides: int = 16) -> void:
	lathe(g, c, n, [Vector2(0, 0), Vector2(r, 0), Vector2(r, th), Vector2(0, th)], col, finish, sides)


## An annulus (a washer) centred on c (half its thickness either side).
static func annulus(g: Geo, c: Vector3, n: Vector3, r_out: float, r_in: float, th: float, col: Color,
		finish: String, sides: int = 16) -> void:
	var h := th * 0.5
	lathe(g, c, n, [Vector2(r_in, -h), Vector2(r_out, -h), Vector2(r_out, h), Vector2(r_in, h), Vector2(r_in, -h)],
		col, finish, sides)


## A washer seated on the `n` side of c.
static func washer(g: Geo, c: Vector3, n: Vector3, stud: float, col: Color = Color(0.74, 0.75, 0.77)) -> float:
	var th := maxf(1.0, stud * 0.18)
	annulus(g, c + n.normalized() * th * 0.5, n, stud * 1.05, stud * 0.55, th, col, "metal", 18)
	return th


## A hex nut (ISO 4032 proportions: across flats 1.6 d, height 0.8 d) seated
## on the `n` side of c, chamfered top. Returns its height.
static func hex_nut(g: Geo, c: Vector3, n: Vector3, stud: float, col: Color = Color(0.72, 0.73, 0.75),
		phase: float = 0.0) -> float:
	var af := stud * 1.6
	var rc := af * 0.5 / cos(PI / 6.0)   # corner radius
	var h := stud * 0.8
	var hole := stud * 0.5
	lathe(g, c, n, [Vector2(hole, 0), Vector2(rc * 0.92, 0), Vector2(rc, h * 0.12), Vector2(rc, h * 0.85),
		Vector2(rc * 0.88, h), Vector2(hole, h), Vector2(hole, 0)], col, "metal", 6, true, phase)
	return h


## A threaded stud of diameter d from c along n for `len`: a shank with
## thread ridges every pitch, a chamfered tip.
static func threaded_stud(g: Geo, c: Vector3, n: Vector3, d: float, length: float,
		col: Color = Color(0.82, 0.62, 0.38)) -> void:
	var r := d * 0.5
	var pitch := clampf(d * 0.16, 0.8, 2.0)
	var prof: Array = [Vector2(0, 0), Vector2(r * 0.86, 0)]
	var h := 0.0
	while h + pitch < length - pitch:
		prof.append(Vector2(r * 0.86, h + pitch * 0.1))
		prof.append(Vector2(r, h + pitch * 0.5))
		h += pitch
	prof.append(Vector2(r * 0.86, h + pitch * 0.1))
	prof.append(Vector2(r * 0.86, length - pitch * 0.4))
	prof.append(Vector2(r * 0.6, length))
	prof.append(Vector2(0, length))
	lathe(g, c, n, prof, col, "metal", 12)


## An SAE J537 tapered battery post (top Ø 17.5 mm positive, 15.9 mm
## negative, 1:9 taper) standing on c along n, `h` tall, with a lead skirt.
static func sae_post(g: Geo, c: Vector3, n: Vector3, positive: bool, h: float = 19.0,
		col: Color = Color(0.5, 0.5, 0.52)) -> void:
	var top := (17.5 if positive else 15.9) * 0.5
	var bot := top + h / 18.0
	lathe(g, c, n, [Vector2(0, 0), Vector2(bot + 3.0, 0), Vector2(bot + 3.0, 2.0), Vector2(bot, 2.5),
		Vector2(top, h - 0.8), Vector2(top - 0.8, h), Vector2(0, h)], col, "tin", 24)


## A clamp terminal round an SAE post at c (post axis n), its bolt across:
## a split ring, two ears, a carriage bolt and nut. Ears point along `t`.
static func post_clamp(g: Geo, c: Vector3, n: Vector3, t: Vector3, r_post: float, col: Color) -> void:
	var nn := n.normalized()
	var tt := (t - nn * t.dot(nn)).normalized()
	annulus(g, c, nn, r_post + 3.2, r_post, 11.0, col, "tin", 22)
	var s := nn.cross(tt).normalized()
	for side in [-1.0, 1.0]:
		var e0: Vector3 = c + tt * (r_post + 1.0) + s * side * 3.2
		var e1: Vector3 = c + tt * (r_post + 13.0) + s * side * 3.2
		plate(g, e0, e1, s, 11.0, 9.0, 2.6, col, "tin")
	var bc := c + tt * (r_post + 8.0)
	var bolt_a := bc - s * 9.0
	var bolt_b := bc + s * 9.0
	tube(g, PackedVector3Array([bolt_a, bolt_b]), 7.0, Color(0.62, 0.63, 0.65), "metal", 10)
	hex_nut(g, bc + s * 4.6, s, 7.0, Color(0.62, 0.63, 0.65))


# ---------------------------------------------------------------------------
# Bars and boxes
# ---------------------------------------------------------------------------

## A busbar: a flat bar from a to b (its centre line), width w across (⊥
## a→b in the plane ⊥ n), thickness th along n, with round ends of radius
## w/2 (punched busbars) and a slight edge break. Holes are drawn by what
## sits in them (nuts).
static func busbar(g: Geo, a: Vector3, b: Vector3, n: Vector3, w: float, th: float, col: Color,
		finish: String = "metal", round_ends: bool = true) -> void:
	var nn := n.normalized()
	var t := b - a
	t = t - nn * t.dot(nn)
	var l := t.length()
	if l < 1e-3:
		t = frame(nn)[0]
		l = 0.0
	else:
		t = t / l
	var s := nn.cross(t).normalized()
	var r := w * 0.5
	var outline: Array = []   # in (t, s) around the bar's middle, CCW seen from +n
	var half := l * 0.5
	var mid := (a + b) * 0.5
	var ends := 8 if round_ends else 1
	if round_ends:
		for k in ends + 1:
			var ang := -PI * 0.5 + PI * float(k) / float(ends)
			outline.append(Vector2(half + r * cos(ang), r * sin(ang)))
		for k in ends + 1:
			var ang := PI * 0.5 + PI * float(k) / float(ends)
			outline.append(Vector2(-half + r * cos(ang), r * sin(ang)))
	else:
		outline = [Vector2(-half - r, -r), Vector2(half + r, -r), Vector2(half + r, r), Vector2(-half - r, r)]
	prism(g, mid - nn * th * 0.5, t, s, nn, outline, th, col, finish)


## A convex outline (CCW seen from +n, in the (u, w) plane at origin o)
## extruded along n by h.
static func prism(g: Geo, o: Vector3, u: Vector3, w: Vector3, n: Vector3, outline: Array, h: float,
		col: Color, finish: String) -> void:
	var nn := n.normalized()
	var m := outline.size()
	var bot: Array = []
	var top: Array = []
	var cen := Vector2.ZERO
	for q in outline:
		cen += q as Vector2
		var p := o + u * (q as Vector2).x + w * (q as Vector2).y
		bot.append(p)
		top.append(p + nn * h)
	cen /= float(m)
	var cb := o + u * cen.x + w * cen.y
	var ct := cb + nn * h
	for i in m:
		var j := (i + 1) % m
		g.tri(finish, col, ct, top[i], top[j], nn, nn, nn, nn)
		g.tri(finish, col, cb, bot[j], bot[i], -nn, -nn, -nn, -nn)
		var e := (outline[j] as Vector2) - (outline[i] as Vector2)
		var en2 := Vector2(e.y, -e.x).normalized()
		var en := (u * en2.x + w * en2.y).normalized()
		g.flat_quad(finish, col, bot[i], bot[j], top[j], top[i], en)


## A box from its centre and size along axes (u, v, w).
static func obox(g: Geo, c: Vector3, u: Vector3, v: Vector3, w: Vector3, size: Vector3, col: Color,
		finish: String) -> void:
	var hu := u.normalized() * size.x * 0.5
	var hv := v.normalized() * size.y * 0.5
	var hw := w.normalized() * size.z * 0.5
	for ax in [[hu, hv, hw], [hv, hw, hu], [hw, hu, hv]]:
		var a: Vector3 = ax[0]
		var b: Vector3 = ax[1]
		var cc: Vector3 = ax[2]
		for sg in [-1.0, 1.0]:
			var fc: Vector3 = c + a * sg
			var fn: Vector3 = (a * sg).normalized()
			g.flat_quad(finish, col, fc - b - cc, fc + b - cc, fc + b + cc, fc - b + cc, fn)


static func abox(g: Geo, c: Vector3, size: Vector3, col: Color, finish: String) -> void:
	obox(g, c, Vector3.RIGHT, Vector3.UP, Vector3.BACK, size, col, finish)
