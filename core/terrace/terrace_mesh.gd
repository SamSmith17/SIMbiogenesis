class_name TerraceMesh
extends RefCounted

## Geometry for terraced fields (pure static, world metres, Y up). The
## paddy surfaces come out of the solved grid (TerraceField.solve) by
## marching squares over a per-paddy field that is positive inside: the level
## floor (crops), the water at the bund's height (which runs a little way up
## the uphill riser), and the edge segments (bunds along the downhill lip,
## the canopy's skirt). Every triangle is wound for Godot's front face
## (clockwise seen from its normal: cross(b − a, c − a) · n < 0).

## Field value outside the paddy.
const OUT := -0.5


## Per paddy: the grid's sample box that holds it {p: Rect2i(ci0, cj0, w, h)}.
static func paddy_boxes(grid: Dictionary) -> Dictionary:
	var lab: PackedInt32Array = grid["label"]
	var cols := int(grid["cols"])
	var out := {}
	for k in lab.size():
		var p := lab[k]
		if p < 0:
			continue
		var ci := k % cols
		var cj := k / cols
		if not out.has(p):
			out[p] = Vector4i(ci, cj, ci, cj)
		else:
			var b: Vector4i = out[p]
			out[p] = Vector4i(mini(b.x, ci), mini(b.y, cj), maxi(b.z, ci), maxi(b.w, cj))
	var rects := {}
	for p in out.keys():
		var b: Vector4i = out[p]
		# One sample of margin so the edge crossings close.
		var x0 := maxi(b.x - 1, 0)
		var y0 := maxi(b.y - 1, 0)
		var x1 := mini(b.z + 1, cols - 1)
		var y1 := mini(b.w + 1, int(grid["rows"]) - 1)
		rects[p] = Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
	return rects


## The field over a paddy's box. mode "floor" = the level floor; "water" =
## the water at `depth_m` (up the uphill riser until it meets the ground).
static func paddy_field(grid: Dictionary, p: int, box: Rect2i, mode: String,
		depth_m: float, step_h: float) -> PackedFloat32Array:
	var cols := int(grid["cols"])
	var lab: PackedInt32Array = grid["label"]
	var dd: PackedFloat32Array = grid["d"]
	var ff: PackedFloat32Array = grid["flat"]
	var out := PackedFloat32Array()
	out.resize(box.size.x * box.size.y)
	var uw := clampf(2.0 * depth_m / maxf(step_h, 0.01), 0.0, 1.0)
	for bj in box.size.y:
		for bi in box.size.x:
			var k := (box.position.y + bj) * cols + box.position.x + bi
			var v := OUT
			if lab[k] == p:
				var d := dd[k]
				var flat := ff[k]
				if mode == "water":
					v = minf(d + flat, flat + (0.5 - flat) * uw - d)
				else:
					v = flat - absf(d)
			out[bj * box.size.x + bi] = v
	return out


## Marching squares over `field` (cols × rows samples from world `origin`,
## `cell` apart): the inside as triangles at height y, appended to `tris`;
## the boundary as segment pairs appended to `segs`.
static func march(field: PackedFloat32Array, cols: int, rows: int, origin: Vector2, cell: float,
		y: float, tris: PackedVector3Array, segs: PackedVector2Array) -> void:
	var vv := [0.0, 0.0, 0.0, 0.0]
	var pp := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	for cj in rows - 1:
		for ci in cols - 1:
			var k := cj * cols + ci
			var v0 := field[k]
			var v1 := field[k + 1]
			var v2 := field[k + cols + 1]
			var v3 := field[k + cols]
			var ins := int(v0 > 0.0) + int(v1 > 0.0) + int(v2 > 0.0) + int(v3 > 0.0)
			if ins == 0:
				continue
			var x0 := origin.x + float(ci) * cell
			var z0 := origin.y + float(cj) * cell
			var p0 := Vector2(x0, z0)
			var p1 := Vector2(x0 + cell, z0)
			var p2 := Vector2(x0 + cell, z0 + cell)
			var p3 := Vector2(x0, z0 + cell)
			if ins == 4:
				_tri2(tris, p0, p1, p2, y)
				_tri2(tris, p0, p2, p3, y)
				continue
			vv[0] = v0
			vv[1] = v1
			vv[2] = v2
			vv[3] = v3
			pp[0] = p0
			pp[1] = p1
			pp[2] = p2
			pp[3] = p3
			var poly := PackedVector2Array()
			var cross := PackedVector2Array()
			for e in 4:
				var a := float(vv[e])
				var b := float(vv[(e + 1) % 4])
				var pa: Vector2 = pp[e]
				var pb: Vector2 = pp[(e + 1) % 4]
				if a > 0.0:
					poly.append(pa)
				if (a > 0.0) != (b > 0.0):
					var q := pa.lerp(pb, a / (a - b))
					poly.append(q)
					cross.append(q)
			for t in range(1, poly.size() - 1):
				_tri2(tris, poly[0], poly[t], poly[t + 1], y)
			if cross.size() >= 2:
				segs.append(cross[0])
				segs.append(cross[1])
			if cross.size() >= 4:
				segs.append(cross[2])
				segs.append(cross[3])


static func _tri2(tris: PackedVector3Array, a: Vector2, b: Vector2, c: Vector2, y: float) -> void:
	tris.append(Vector3(a.x, y, a.y))
	tris.append(Vector3(b.x, y, b.y))
	tris.append(Vector3(c.x, y, c.y))


## Bilinear sample of a grid array at world XZ (NAN outside the grid).
static func sample(grid: Dictionary, arr: PackedFloat32Array, p: Vector2) -> float:
	var cell := float(grid["cell"])
	var cols := int(grid["cols"])
	var rows := int(grid["rows"])
	var fx := p.x / cell - float(int(grid["i0"]))
	var fz := p.y / cell - float(int(grid["j0"]))
	if fx < 0.0 or fz < 0.0 or fx > float(cols - 1) or fz > float(rows - 1):
		return NAN
	var ci := mini(int(floor(fx)), cols - 2)
	var cj := mini(int(floor(fz)), rows - 2)
	var tx := fx - float(ci)
	var tz := fz - float(cj)
	var k := cj * cols + ci
	var a := lerpf(arr[k], arr[k + 1], tx)
	var b := lerpf(arr[k + cols], arr[k + cols + 1], tx)
	return lerpf(a, b, tz)


# ---------------------------------------------------------------------------
# Mesh building
# ---------------------------------------------------------------------------

class Buf:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var c := PackedColorArray()

	## One triangle wound for Godot's front face toward `hint`.
	func tri(a: Vector3, b: Vector3, cc: Vector3, hint: Vector3, col: Color = Color.WHITE,
			ua := Vector2.ZERO, ub := Vector2.ZERO, uc := Vector2.ZERO,
			u2a := Vector2.ZERO, u2b := Vector2.ZERO, u2c := Vector2.ZERO) -> void:
		var nn := (b - a).cross(cc - a)
		if nn.dot(hint) > 0.0:
			var t := b
			b = cc
			cc = t
			var tu := ub
			ub = uc
			uc = tu
			var t2 := u2b
			u2b = u2c
			u2c = t2
		var nrm := hint.normalized()
		v.append(a)
		v.append(b)
		v.append(cc)
		for _i in 3:
			n.append(nrm)
			c.append(col)
		uv.append(ua)
		uv.append(ub)
		uv.append(uc)
		uv2.append(u2a)
		uv2.append(u2b)
		uv2.append(u2c)

	func mesh() -> ArrayMesh:
		var m := ArrayMesh.new()
		if v.is_empty():
			return m
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_TEX_UV2] = uv2
		arr[Mesh.ARRAY_COLOR] = c
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		return m


## A flat triangle list (from march) as a mesh facing up; UV = world XZ.
static func flat_mesh(tris: PackedVector3Array) -> ArrayMesh:
	var b := Buf.new()
	var i := 0
	while i + 2 < tris.size():
		var a := tris[i]
		var bb := tris[i + 1]
		var cc := tris[i + 2]
		b.tri(a, bb, cc, Vector3.UP, Color.WHITE, Vector2(a.x, a.z), Vector2(bb.x, bb.z), Vector2(cc.x, cc.z),
			Vector2(0, 1), Vector2(0, 1), Vector2(0, 1))
		i += 3
	return b.mesh()


## A low earth bund along each segment (a, b): bottom width `wb`, top `wt`,
## from y up `h`. Ends overrun a little so neighbours join.
static func bunds(b: Buf, segs: PackedVector2Array, y: float, h: float, wb: float, wt: float,
		col: Color) -> void:
	var i := 0
	while i + 1 < segs.size():
		var a := segs[i]
		var e := segs[i + 1]
		i += 2
		var dir := e - a
		var ln := dir.length()
		if ln < 0.01:
			continue
		dir /= ln
		a -= dir * 0.08
		e += dir * 0.08
		var nrm := Vector2(-dir.y, dir.x)
		var y0 := y - 0.06
		var y1 := y + h
		var al := Vector3(a.x + nrm.x * wb * 0.5, y0, a.y + nrm.y * wb * 0.5)
		var ar := Vector3(a.x - nrm.x * wb * 0.5, y0, a.y - nrm.y * wb * 0.5)
		var el := Vector3(e.x + nrm.x * wb * 0.5, y0, e.y + nrm.y * wb * 0.5)
		var er := Vector3(e.x - nrm.x * wb * 0.5, y0, e.y - nrm.y * wb * 0.5)
		var tal := Vector3(a.x + nrm.x * wt * 0.5, y1, a.y + nrm.y * wt * 0.5)
		var tar := Vector3(a.x - nrm.x * wt * 0.5, y1, a.y - nrm.y * wt * 0.5)
		var tel := Vector3(e.x + nrm.x * wt * 0.5, y1, e.y + nrm.y * wt * 0.5)
		var ter := Vector3(e.x - nrm.x * wt * 0.5, y1, e.y - nrm.y * wt * 0.5)
		var nl := Vector3(nrm.x, 0.8, nrm.y)
		var nr := Vector3(-nrm.x, 0.8, -nrm.y)
		var lite := col.lightened(0.08)
		b.tri(al, el, tel, nl, col)
		b.tri(al, tel, tal, nl, col)
		b.tri(ar, ter, er, nr, col.darkened(0.08))
		b.tri(ar, tar, ter, nr, col.darkened(0.08))
		b.tri(tal, tel, ter, Vector3.UP, lite)
		b.tri(tal, ter, tar, Vector3.UP, lite)


## A vertical strip down from each segment (the canopy's sides): UV2.y = 1 on
## top (raised to the crop's height by the shader), 0 at the floor.
static func skirts(b: Buf, segs: PackedVector2Array, y: float) -> void:
	var i := 0
	while i + 1 < segs.size():
		var a := segs[i]
		var e := segs[i + 1]
		i += 2
		if a.distance_squared_to(e) < 1e-6:
			continue
		var dir := (e - a).normalized()
		var out := Vector3(-dir.y, 0.0, dir.x)
		# Top and bottom start at the floor; the canopy shader lifts the top
		# (UV2.y = 1). The strip is flat in the mesh, so its winding is not
		# known here: the canopy material draws both sides.
		var a0 := Vector3(a.x, y, a.y)
		var e0 := Vector3(e.x, y, e.y)
		var nrm := out.normalized()
		for q in [[a0, Vector2(a.x, a.y), 0.0], [e0, Vector2(e.x, e.y), 0.0], [e0, Vector2(e.x, e.y), 1.0],
				[a0, Vector2(a.x, a.y), 0.0], [e0, Vector2(e.x, e.y), 1.0], [a0, Vector2(a.x, a.y), 1.0]]:
			b.v.append(q[0])
			b.n.append(nrm)
			b.c.append(Color(0.8, 0.8, 0.8))
			b.uv.append(q[1])
			b.uv2.append(Vector2(1.0, float(q[2])))


## The way spilled water runs from a lip point down the riser: steepest
## descent over the field's target heights, until it is within 5 cm of
## `stop_y` (the floor below) or `max_m` long. World points just above the
## ground.
static func fall_path(grid: Dictionary, start: Vector2, stop_y: float, max_m: float = 12.0) -> PackedVector3Array:
	var tg: PackedFloat32Array = grid["target"]
	var out := PackedVector3Array()
	var p := start
	var step := 0.35
	var walked := 0.0
	for _i in 80:
		var h := sample(grid, tg, p)
		if is_nan(h):
			break
		out.append(Vector3(p.x, h + 0.04, p.y))
		if h <= stop_y + 0.05 or walked >= max_m:
			break
		var e := 0.25
		var gx := sample(grid, tg, p + Vector2(e, 0)) - sample(grid, tg, p - Vector2(e, 0))
		var gz := sample(grid, tg, p + Vector2(0, e)) - sample(grid, tg, p - Vector2(0, e))
		var g := Vector2(gx, gz)
		if is_nan(g.x) or is_nan(g.y) or g.length() < 1e-4:
			break
		p -= g.normalized() * step
		walked += step
	return out


## A ribbon `width` wide along a path, facing up; UV = (across 0..1, metres
## along). Used for the cascading water and the selection outline.
static func ribbon(b: Buf, path: PackedVector3Array, width: float, col: Color = Color.WHITE,
		closed: bool = false, lift: float = 0.0) -> void:
	var nn := path.size()
	if nn < 2:
		return
	var along := 0.0
	var count := nn if closed else nn - 1
	for i in count:
		var a := path[i]
		var e := path[(i + 1) % nn]
		var d := Vector2(e.x - a.x, e.z - a.z)
		var seg_len := Vector3(e - a).length()
		if d.length_squared() < 1e-8:
			d = Vector2(1, 0)
		d = d.normalized()
		var side := Vector3(-d.y, 0.0, d.x) * width * 0.5
		var up := Vector3(0, lift, 0)
		var a0 := a - side + up
		var a1 := a + side + up
		var e0 := e - side + up
		var e1 := e + side + up
		var u0 := along
		var u1 := along + seg_len
		b.tri(a0, e0, e1, Vector3.UP, col, Vector2(0, u0), Vector2(0, u1), Vector2(1, u1))
		b.tri(a0, e1, a1, Vector3.UP, col, Vector2(0, u0), Vector2(1, u1), Vector2(1, u0))
		along = u1


## Pick up to `want` points spread along a set of segments (farthest-point
## sampling over their midpoints): where a paddy's lip spills.
static func spread_points(segs: PackedVector2Array, want: int) -> PackedVector2Array:
	var mids := PackedVector2Array()
	var i := 0
	while i + 1 < segs.size():
		mids.append((segs[i] + segs[i + 1]) * 0.5)
		i += 2
	var out := PackedVector2Array()
	if mids.is_empty() or want <= 0:
		return out
	out.append(mids[0])
	while out.size() < mini(want, mids.size()):
		var best := -1.0
		var bp := mids[0]
		for m in mids:
			var dmin := INF
			for o in out:
				dmin = minf(dmin, m.distance_squared_to(o))
			if dmin > best:
				best = dmin
				bp = m
		if best <= 4.0:
			break
		out.append(bp)
	return out
