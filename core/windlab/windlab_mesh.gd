class_name WindLabMesh
extends RefCounted

## Solid geometry for the turbine's parts as plain triangle lists — ONE
## source for the 3D model (WindLabBuilder) and the printable / routable STL
## files (WindLabCam). Pure static.
##
## Frame: millimetres, Z UP (the print / CAD convention), triangles wound
## counter-clockwise seen from outside (the STL rule). The builder maps
## (x, y, z) → Godot (x, z, −y) · 0.001, a proper rotation, and reverses each
## triangle (Godot's front faces wind clockwise).

## A closed section lofted through `sections` (each a PackedVector3Array of
## the same point count), capped at both ends. Returns triangles, wound so
## the solid's signed volume is positive.
static func loft(sections: Array, cap: bool = true) -> PackedVector3Array:
	var tris := PackedVector3Array()
	var ns := sections.size()
	if ns < 2:
		return tris
	var n: int = (sections[0] as PackedVector3Array).size()
	for s in ns - 1:
		var a: PackedVector3Array = sections[s]
		var b: PackedVector3Array = sections[s + 1]
		for i in n:
			var j := (i + 1) % n
			tris.append_array([a[i], a[j], b[j]])
			tris.append_array([a[i], b[j], b[i]])
	if cap:
		# Caps as a strip across the ring: point k paired with n − 1 − k. Every
		# ring here is built that way (a band's two sides, an airfoil's upper
		# and lower surfaces, a circle), so the strip never leaves the outline
		# the way a fan from the centroid does on a curved band.
		for end in [0, ns - 1]:
			var sec: PackedVector3Array = sections[end]
			var k := 0
			while 2 * k + 3 <= n:
				var a := k
				var b := k + 1
				var c := n - 2 - k
				var d := n - 1 - k
				if end == ns - 1:
					if b < c:
						tris.append_array([sec[a], sec[b], sec[c]])
					tris.append_array([sec[a], sec[c] if b < c else sec[b], sec[d]])
				else:
					if b < c:
						tris.append_array([sec[a], sec[c], sec[b]])
					tris.append_array([sec[a], sec[d], sec[c] if b < c else sec[b]])
				k += 1
	if signed_volume(tris) < 0.0:
		tris = flip(tris)
	return tris


static func signed_volume(tris: PackedVector3Array) -> float:
	var v := 0.0
	for i in range(0, tris.size() - 2, 3):
		v += tris[i].dot(tris[i + 1].cross(tris[i + 2]))
	return v / 6.0


static func flip(tris: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(tris.size())
	for i in range(0, tris.size() - 2, 3):
		out[i] = tris[i]
		out[i + 1] = tris[i + 2]
		out[i + 2] = tris[i + 1]
	return out


## A sheet blade: the centreline (rotor plane, mm) thickened by t either side
## of it, extruded from z0 to z1, turned about the axis by `twist` radians
## over the height (helical Savonius). Layers: 1 when straight.
static func sheet_blade(centre: PackedVector2Array, t: float, z0: float, z1: float, twist: float = 0.0) -> PackedVector3Array:
	var ring := band_outline(centre, t)
	var layers := 1 if absf(twist) < 1e-4 else maxi(int(ceil(absf(twist) / deg_to_rad(6.0))), 4)
	var sections: Array = []
	for k in layers + 1:
		var u := float(k) / float(layers)
		var z := lerpf(z0, z1, u)
		var a := twist * u
		var sec := PackedVector3Array()
		for p in ring:
			var q := p.rotated(a)
			sec.append(Vector3(q.x, q.y, z))
		sections.append(sec)
	return loft(sections)


## The closed outline of a centreline thickened by t (mm): one side forward,
## the other back.
static func band_outline(centre: PackedVector2Array, t: float) -> PackedVector2Array:
	var n := centre.size()
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for i in n:
		var dir: Vector2
		if i == 0:
			dir = centre[1] - centre[0]
		elif i == n - 1:
			dir = centre[n - 1] - centre[n - 2]
		else:
			dir = centre[i + 1] - centre[i - 1]
		var nrm := Vector2(-dir.y, dir.x).normalized()
		left.append(centre[i] + nrm * t * 0.5)
		right.append(centre[i] - nrm * t * 0.5)
	var out := left.duplicate()
	for i in range(n - 1, -1, -1):
		out.append(right[i])
	return out


## A straight airfoil blade standing on the rotor circle (Darrieus) from z0 to
## z1: the section (chord-normalised airfoil points) of chord c set tangent at
## radius R, leading edge forward in the turn, the blade at angle psi turning
## a further `helix` radians round the axis over the height.
static func vawt_foil_blade(af_pts: PackedVector2Array, c: float, R: float, psi: float, z0: float, z1: float,
		helix: float = 0.0, layers: int = 1) -> PackedVector3Array:
	var nl := maxi(layers, 1)
	var sections: Array = []
	for k in nl + 1:
		var u := float(k) / float(nl)
		var z := lerpf(z0, z1, u)
		var a := psi + helix * u
		var er := Vector2(cos(a), sin(a))
		var et := Vector2(-sin(a), cos(a))
		var sec := PackedVector3Array()
		for p in af_pts:
			var q := er * R + et * (0.25 - p.x) * c + er * p.y * c
			sec.append(Vector3(q.x, q.y, z))
		sections.append(sec)
	return loft(sections)


## One propeller blade in its own frame: span along +X from the hub, the
## direction of rotation +Y, downwind +Z. At each station the section (pitch
## axis at the quarter chord) is set at the twist angle θ to the rotor plane:
##   chord (TE → LE) = cos θ · ŷ − sin θ · ẑ,  suction side = sin θ · ŷ + cos θ · ẑ.
## `stations`: [{r_m, c_m, twist_deg}] from WindLabAero.hawt_blade; mm out.
static func hawt_blade(stations: Array, af_pts: PackedVector2Array, thick_k: float = 1.0) -> PackedVector3Array:
	var sections: Array = []
	for st in stations:
		var r := float(st["r_m"]) * 1000.0
		var c := float(st["c_m"]) * 1000.0
		var th := deg_to_rad(float(st["twist_deg"]))
		var ch := Vector3(0.0, cos(th), -sin(th))
		var nm := Vector3(0.0, sin(th), cos(th))
		var sec := PackedVector3Array()
		for p in af_pts:
			sec.append(Vector3(r, 0.0, 0.0) + ch * (0.25 - p.x) * c + nm * p.y * c * thick_k)
		sections.append(sec)
	return loft(sections)


## A cylinder / ring about +Z (mm): outer r_out, bore r_in (0 = solid), z0..z1.
static func ring(r_out: float, r_in: float, z0: float, z1: float, sides: int = 48) -> PackedVector3Array:
	var tris := PackedVector3Array()
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var o0 := Vector3(cos(a0) * r_out, sin(a0) * r_out, 0.0)
		var o1 := Vector3(cos(a1) * r_out, sin(a1) * r_out, 0.0)
		var zz0 := Vector3(0, 0, z0)
		var zz1 := Vector3(0, 0, z1)
		tris.append_array([o0 + zz0, o1 + zz0, o1 + zz1])
		tris.append_array([o0 + zz0, o1 + zz1, o0 + zz1])
		if r_in > 0.0:
			var i0 := Vector3(cos(a0) * r_in, sin(a0) * r_in, 0.0)
			var i1 := Vector3(cos(a1) * r_in, sin(a1) * r_in, 0.0)
			tris.append_array([i0 + zz0, i1 + zz1, i1 + zz0])
			tris.append_array([i0 + zz0, i0 + zz1, i1 + zz1])
			tris.append_array([o0 + zz1, o1 + zz1, i1 + zz1])
			tris.append_array([o0 + zz1, i1 + zz1, i0 + zz1])
			tris.append_array([o0 + zz0, i1 + zz0, o1 + zz0])
			tris.append_array([o0 + zz0, i0 + zz0, i1 + zz0])
		else:
			tris.append_array([zz1, o0 + zz1, o1 + zz1])
			tris.append_array([zz0, o1 + zz0, o0 + zz0])
	return tris


## A flat plate from a 2-D outline (mm, CCW), z0..z1. Holes are left out of
## the solid (the plate's cut file carries them).
static func plate(outline_in: PackedVector2Array, z0: float, z1: float) -> PackedVector3Array:
	var outline := outline_in
	if _area2(outline) < 0.0:
		outline = outline_in.duplicate()
		outline.reverse()
	var sec0 := PackedVector3Array()
	var sec1 := PackedVector3Array()
	for p in outline:
		sec0.append(Vector3(p.x, p.y, z0))
		sec1.append(Vector3(p.x, p.y, z1))
	var tris := PackedVector3Array()
	var n := outline.size()
	for i in n:
		var j := (i + 1) % n
		tris.append_array([sec0[i], sec0[j], sec1[j]])
		tris.append_array([sec0[i], sec1[j], sec1[i]])
	var idx := Geometry2D.triangulate_polygon(outline)
	for k in range(0, idx.size() - 2, 3):
		var i0 := idx[k]
		var i1 := idx[k + 1]
		var i2 := idx[k + 2]
		if (outline[i1] - outline[i0]).cross(outline[i2] - outline[i0]) < 0.0:
			var tmp := i1
			i1 = i2
			i2 = tmp
		tris.append_array([sec1[i0], sec1[i1], sec1[i2]])
		tris.append_array([sec0[i0], sec0[i2], sec0[i1]])
	if signed_volume(tris) < 0.0:
		tris = flip(tris)
	return tris


static func _area2(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		a += p[i].cross(p[(i + 1) % p.size()])
	return a


static func transformed(tris: PackedVector3Array, xf: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(tris.size())
	for i in tris.size():
		out[i] = xf * tris[i]
	return out


## Binary STL bytes (mm, the triangles as given — counter-clockwise outside).
static func stl_bytes(tris: PackedVector3Array, header: String = "SIMbiogenesis wind lab") -> PackedByteArray:
	var n := tris.size() / 3
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	var h := header.to_ascii_buffer()
	h.resize(80)
	buf.put_data(h)
	buf.put_u32(n)
	for i in n:
		var a := tris[i * 3]
		var b := tris[i * 3 + 1]
		var c := tris[i * 3 + 2]
		var nm := (b - a).cross(c - a).normalized()
		for v in [nm, a, b, c]:
			buf.put_float((v as Vector3).x)
			buf.put_float((v as Vector3).y)
			buf.put_float((v as Vector3).z)
		buf.put_u16(0)
	return buf.data_array


static func bbox(tris: PackedVector3Array) -> AABB:
	if tris.is_empty():
		return AABB()
	var a := AABB(tris[0], Vector3.ZERO)
	for p in tris:
		a = a.expand(p)
	return a
