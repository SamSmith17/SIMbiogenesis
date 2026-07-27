class_name PipePartsPlanner
extends RefCounted

## Sharp polyline + PipeKit → BOM of procedural straights + GLB elbows.
## Straights are solid tubes (from/to); elbows use kit MultiMesh transforms.

const MIN_STRAIGHT_M := 0.002
const BEND_TOL_DEG := 10.0
## Midpoint between 45° and 90° — sharper turns morph to 90° fittings.
const MORPH_MID_DEG := 67.5


## Returns {ok, parts: Array[{kind, bend_deg, transform, length_m, from?, to?, corner_i?}],
## centerline, error}.
static func plan(sharp: PackedVector3Array, kit: PipeKit) -> Dictionary:
	var out := {
		"ok": false,
		"parts": [],
		"centerline": PackedVector3Array(),
		"error": "",
	}
	if kit == null:
		out["error"] = "null kit"
		return out
	var pts := _dedupe(sharp)
	if pts.size() < 2:
		out["error"] = "need ≥2 points"
		return out
	var corner_bends: Array = []
	corner_bends.resize(pts.size())
	for i: int in range(1, pts.size() - 1):
		var d_in := pts[i] - pts[i - 1]
		var d_out := pts[i + 1] - pts[i]
		if d_in.length_squared() < 1e-12 or d_out.length_squared() < 1e-12:
			out["error"] = "zero-length span at corner %d" % i
			return out
		var turn := rad_to_deg(d_in.normalized().angle_to(d_out.normalized()))
		if turn < 2.0:
			corner_bends[i] = 0.0
			continue
		var bend := kit.classify_bend_deg(turn, BEND_TOL_DEG)
		if bend < 0.0:
			# Soft morph for near-miss float error after expander (still near 45/90).
			var m := morph_bend_deg(turn)
			if m > 0.5 and absf(turn - m) <= BEND_TOL_DEG and kit.has_elbow(m):
				bend = m
		if bend < 0.0:
			out["error"] = "unsupported bend %.1f° at corner %d" % [turn, i]
			return out
		corner_bends[i] = bend
	var parts: Array = []
	var centerline := PackedVector3Array()
	centerline.append(pts[0])
	var cursor := pts[0]
	for i: int in range(1, pts.size()):
		var target := pts[i]
		var d := target - cursor
		var span_len := d.length()
		if span_len < 1e-9:
			continue
		var dir := d / span_len
		var take_end := 0.0
		var bend_here := 0.0
		if i < pts.size() - 1:
			bend_here = float(corner_bends[i])
			if bend_here > 0.5:
				take_end = kit.elbow_takeout_m(bend_here)
		var straight_end := target - dir * take_end
		var straight_len := cursor.distance_to(straight_end)
		if straight_len >= MIN_STRAIGHT_M:
			parts.append({
				"kind": "straight",
				"bend_deg": 0.0,
				"transform": Transform3D(Basis(), cursor),
				"from": cursor,
				"to": straight_end,
				"length_m": straight_len,
			})
			centerline.append(straight_end)
		elif straight_len < -0.01:
			out["error"] = "span too short for elbow takeout at corner %d" % i
			return out
		if i < pts.size() - 1 and bend_here > 0.5:
			var d_out := (pts[i + 1] - pts[i]).normalized()
			var d_in := dir
			var elbow_xf := _elbow_xform(pts[i], d_in, d_out, take_end, kit, bend_here)
			if elbow_xf == Transform3D():
				out["error"] = "bad elbow frame at corner %d" % i
				return out
			parts.append({
				"kind": "elbow",
				"bend_deg": bend_here,
				"transform": elbow_xf,
				"length_m": kit.elbow_centerline_radius_m(bend_here) \
						* deg_to_rad(bend_here),
				"corner_i": i,
				"corner": pts[i],
			})
			cursor = pts[i] + d_out * take_end
			centerline.append(pts[i])
			centerline.append(cursor)
		else:
			cursor = target
			if centerline[centerline.size() - 1].distance_to(target) > 1e-6:
				centerline.append(target)
	if parts.is_empty():
		parts.append({
			"kind": "straight",
			"bend_deg": 0.0,
			"transform": Transform3D(Basis(), pts[0]),
			"from": pts[0],
			"to": pts[pts.size() - 1],
			"length_m": pts[0].distance_to(pts[pts.size() - 1]),
		})
	parts = _merge_colinear_straights(parts)
	out["ok"] = true
	out["parts"] = parts
	out["centerline"] = centerline
	return out


## Collapse adjacent colinear straight spans into one tube (fewer MeshInstance3Ds).
static func _merge_colinear_straights(parts: Array) -> Array:
	if parts.size() < 2:
		return parts
	var out: Array = []
	for p: Variant in parts:
		var d: Dictionary = (p as Dictionary).duplicate(true)
		if out.is_empty() or str(d.get("kind", "")) != "straight":
			out.append(d)
			continue
		var prev: Dictionary = out[out.size() - 1] as Dictionary
		if str(prev.get("kind", "")) != "straight":
			out.append(d)
			continue
		var a0: Vector3 = prev.get("from", Vector3.ZERO) as Vector3
		var a1: Vector3 = prev.get("to", Vector3.ZERO) as Vector3
		var b0: Vector3 = d.get("from", Vector3.ZERO) as Vector3
		var b1: Vector3 = d.get("to", Vector3.ZERO) as Vector3
		if a1.distance_to(b0) > 0.002:
			out.append(d)
			continue
		var da := a1 - a0
		var db := b1 - b0
		if da.length_squared() < 1e-12 or db.length_squared() < 1e-12:
			out.append(d)
			continue
		if absf(da.normalized().dot(db.normalized())) < 0.999:
			out.append(d)
			continue
		prev["to"] = b1
		prev["length_m"] = a0.distance_to(b1)
		out[out.size() - 1] = prev
	return out


## Map a free-space turn to nearest kit elbow via 45/90 morph threshold.
static func morph_bend_deg(turn_deg: float) -> float:
	var t := absf(turn_deg)
	if t < 2.0:
		return 0.0
	if t < MORPH_MID_DEG:
		return 45.0
	return 90.0


## Place a canonical elbow mesh so local +Z (inlet) aligns with d_in and the
## baked socket_b outward aligns with d_out.
## Canonical bake: socket A at origin outward −Z; enter along +Z; bend in +X/+Z.
static func _elbow_xform(corner: Vector3, d_in: Vector3, d_out: Vector3,
		takeout: float, kit: PipeKit, bend_deg: float) -> Transform3D:
	var zin := d_in.normalized()
	var wout := d_out.normalized()
	var origin := corner - zin * takeout
	var part: Dictionary = kit.part(bend_deg)
	var sb: Dictionary = part.get("socket_b", {}) as Dictionary
	var local_out := _vec3_from_arr(sb.get("outward", [1, 0, 0]))
	if local_out.length_squared() < 1e-10:
		local_out = Vector3(1, 0, 0)
	local_out = local_out.normalized()
	# Local bend frame: +Z = inlet, +X = bend-plane direction toward outlet.
	var lz := Vector3(0, 0, 1)
	var lx := local_out - lz * local_out.dot(lz)
	if lx.length_squared() < 1e-10:
		# Degenerate bake — invent a bend plane from the world turn.
		var wx := wout - zin * wout.dot(zin)
		if wx.length_squared() < 1e-10:
			wx = zin.cross(Vector3.UP)
			if wx.length_squared() < 1e-10:
				wx = zin.cross(Vector3.RIGHT)
		wx = wx.normalized()
		var wy := zin.cross(wx).normalized()
		return Transform3D(Basis(wx, wy, zin), origin)
	lx = lx.normalized()
	var ly := lz.cross(lx).normalized()
	lx = ly.cross(lz).normalized()
	# Matching world frame from the route turn.
	var wz := zin
	var wx2 := wout - wz * wout.dot(wz)
	if wx2.length_squared() < 1e-10:
		wx2 = wz.cross(Vector3.UP)
		if wx2.length_squared() < 1e-10:
			wx2 = wz.cross(Vector3.RIGHT)
	wx2 = wx2.normalized()
	var wy2 := wz.cross(wx2).normalized()
	wx2 = wy2.cross(wz).normalized()
	# Map local → world: world_b * local_b^{-1}
	var local_b := Basis(lx, ly, lz)
	var world_b := Basis(wx2, wy2, wz)
	var basis := world_b * local_b.inverse()
	if not _basis_finite(basis) or not is_finite(origin.x):
		return Transform3D()
	return Transform3D(basis, origin)


static func _basis_finite(b: Basis) -> bool:
	for i: int in range(3):
		var ax: Vector3 = b[i]
		if not is_finite(ax.x) or not is_finite(ax.y) or not is_finite(ax.z):
			return false
		if ax.length_squared() < 1e-12:
			return false
	return true


static func _vec3_from_arr(v: Variant) -> Vector3:
	if v is Vector3:
		return v as Vector3
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.FORWARD


static func _dedupe(pts: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 1e-4:
			out.append(p)
	return out
