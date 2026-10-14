class_name WaterLineMesh
extends RefCounted

## Ground-draped ribbons for water polylines (the drainage overlay, editor
## previews) — one ArrayMesh for many lines. Each line is resampled every
## STEP_M so it follows the terrain between its (possibly sparse) vertices.
## UV.x = arc length (m, downstream), UV.y = lateral −1..1, COLOR per line.

const STEP_M := 2.5


## `lines` = Array of {points: PackedVector2Array, width: float, color: Color}.
## `ground_fn(x, z) -> float`. `lift` = metres above the ground.
static func build(lines: Array, ground_fn: Callable, lift: float = 0.25) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vtx := 0
	for l_v in lines:
		var l: Dictionary = l_v
		var pts := ChannelProfile.resample(l.get("points", PackedVector2Array()), STEP_M)
		var p2: PackedVector2Array = pts["points"]
		var s: PackedFloat32Array = pts["s"]
		if p2.size() < 2:
			continue
		var half := float(l.get("width", 1.0)) * 0.5
		var col: Color = l.get("color", Color(0.3, 0.6, 1.0, 0.8))
		for i in p2.size():
			var a := p2[maxi(i - 1, 0)]
			var b := p2[mini(i + 1, p2.size() - 1)]
			var t := (b - a).normalized() if a.distance_squared_to(b) > 1e-9 else Vector2(1, 0)
			var n := Vector2(-t.y, t.x)
			for side in [-1.0, 1.0]:
				var q: Vector2 = p2[i] + n * (half * side)
				st.set_color(col)
				st.set_uv(Vector2(s[i], side))
				st.add_vertex(Vector3(q.x, float(ground_fn.call(q.x, q.y)) + lift, q.y))
			if i > 0:
				var a0 := vtx - 2
				st.add_index(a0)
				st.add_index(vtx)
				st.add_index(a0 + 1)
				st.add_index(a0 + 1)
				st.add_index(vtx)
				st.add_index(vtx + 1)
			vtx += 2
	if vtx == 0:
		return null
	return st.commit()


## Strahler-order palette: pale cyan rills → deep blue rivers.
static func order_color(order: int) -> Color:
	var cols := [Color(0.45, 0.85, 1.0), Color(0.30, 0.70, 1.0), Color(0.20, 0.50, 1.0),
		Color(0.25, 0.35, 0.95), Color(0.45, 0.30, 0.95)]
	return cols[clampi(order - 1, 0, cols.size() - 1)]
