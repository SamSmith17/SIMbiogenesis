class_name StreamMeshBuilder
extends RefCounted

## Builds the water SURFACE of every flowing feature as one strip mesh — pure
## except for the ground callable it is handed (main-thread).
##
## The old OSM ribbon was a buffered polygon with vertices only on its two
## banks, draped 0.12 m above a DEM the terrain does not even draw at the same
## resolution, so long triangles chorded across the channel and the terrain
## poked through. This strip has a station every ~2 m along the arc and
## ACROSS_VERTS across it, and:
##   * where the channel is CARVED, the surface is LEVEL across each station at
##     bed + normal depth (StreamHydraulics) — water sitting in its channel,
##     legitimately hidden by the banks from low angles. It is built a touch
##     wider than the water so the edge tucks under the bank (no seam).
##   * where it is not carved (carve off, outside the hi-res patch), each vertex
##     drapes onto the surface actually drawn (`ground_fn`) plus a small lift.
##   * culvert / pipe spans emit no surface.
##
## Vertex data the shader (stream_water.gdshader) reads:
##   COLOR.rg  downstream direction (xz, encoded 0..1)
##   COLOR.b   flow speed 0..1 (velocity / SPEED_FULL_MS)
##   COLOR.a   white-water amount 0..1 (Froude number)
##   UV        world xz
##   UV2       (lateral −1..1, arc length m)

const ACROSS_VERTS := 7
## Extra width (fraction of the half width) on carved stations so the water's
## edge dives under the bank instead of meeting it exactly.
const EDGE_TUCK := 0.12
const DRAPE_LIFT_M := 0.10
## Velocity at which COLOR.b saturates.
const SPEED_FULL_MS := 2.5
## Below this depth a station is dry (no surface drawn).
const DRY_DEPTH_M := 0.002
## A wet station is drawn at least this deep: a 25 L/s brook really is a few
## centimetres deep, but a 2 cm sheet over a carved bed reads as a damp ditch.
const MIN_RENDER_DEPTH_M := 0.06
## Width used where a station is dry but neighbours are wet (a thin film so the
## strip does not tear) — and the minimum visible stream width.
const MIN_WIDTH_M := 0.4


## `items` = Array of {feature, profile, states (Array of StreamHydraulics.state
## per station), carved (PackedByteArray per station)}.
## `ground_fn(x, z) -> float` = the composed (edited) surface.
static func build(items: Array, ground_fn: Callable) -> ArrayMesh:
	var list: Array = []
	for it_v in items:
		list.append(feature_arrays(it_v as Dictionary, ground_fn))
	return mesh_from_arrays(list)


## One feature's surface as mesh arrays ([] when it draws nothing), so a
## network can re-mesh only the streams whose flow moved and keep the rest.
## Written straight into packed arrays (a SurfaceTool call per vertex
## attribute cost ~100 ms on a 4 km wash). Normals are straight up: the water
## shader writes its own NORMAL from the ripples, so generated ones were never
## seen. `bank_ref` (optional, per station): the ground just outside the
## channel's TOP width — the overbank test samples the ground only where the
## water could reach it (see _append_feature).
## `drape` (optional, from drape_refs): the ground under uncarved stations
## at fixed lateral offsets, so the strip drapes without a ground query per
## vertex on every re-mesh.
static func feature_arrays(it: Dictionary, ground_fn: Callable,
		bank_ref: PackedFloat32Array = PackedFloat32Array(), drape: Dictionary = {},
		surf_mask: PackedByteArray = PackedByteArray()) -> Array:
	var f: Dictionary = it["feature"]
	var prof: Dictionary = it["profile"]
	var states: Array = it["states"]
	var carved: PackedByteArray = it["carved"]
	var pts: PackedVector2Array = prof.get("points", PackedVector2Array())
	var s: PackedFloat32Array = prof.get("s", PackedFloat32Array())
	var bed: PackedFloat32Array = prof.get("bed", PackedFloat32Array())
	var varc: PackedFloat32Array = prof.get("varc", PackedFloat32Array())
	var n := pts.size()
	if n < 2 or states.size() != n:
		return []
	var sec: Dictionary = f["section"]
	var bank_z := maxf(float(sec.get("bank_slope", 1.5)), 0.05)
	var bed_half := float(sec.get("bed_w", 2.0)) * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	var vtx := 0
	var run_open := false
	var has_ref := bank_ref.size() == n
	var dz: PackedFloat32Array = drape.get("z", PackedFloat32Array())
	var d_m := int(drape.get("m", 0))
	var d_r := float(drape.get("r", 0.0))
	var has_drape := d_m > 1 and dz.size() == n * d_m
	var mask := surf_mask if surf_mask.size() == n else StreamNetwork.surface_mask(f, s, varc)
	for i in n:
		var surf := mask[i] == 1
		var stt: Dictionary = states[i]
		var depth := float(stt.get("depth_m", 0.0))
		if not surf or depth < DRY_DEPTH_M:
			run_open = false
			continue
		var tan := _tangent(pts, i)
		var across := Vector2(-tan.y, tan.x)
		var top_w := maxf(float(stt.get("top_w_m", 0.0)), MIN_WIDTH_M)
		var is_carved := i < carved.size() and carved[i] == 1
		var half := top_w * 0.5
		var level := 0.0
		if is_carved:
			level = bed[i] + maxf(depth, MIN_RENDER_DEPTH_M)
			# Inside the channel the ground a metre past the water's edge is
			# always above the water, so only a level over the ground at the
			# channel's own top needs the live sample.
			if not has_ref or level > bank_ref[i] - 0.05:
				# On a worker (no ground callable) the bank top stands in.
				var bank_y := float(ground_fn.call(pts[i].x + across.x * (half + 1.0),
					pts[i].y + across.y * (half + 1.0))) if ground_fn.is_valid() \
					else (bank_ref[i] if has_ref else INF)
				if level > bank_y:
					level = bank_y - 0.02
					half = maxf(half, bed_half + (level - bed[i]) * bank_z)
			if half > bed_half:
				half *= 1.0 + EDGE_TUCK
		var spd := clampf(float(stt.get("velocity_ms", 0.0)) / SPEED_FULL_MS, 0.0, 1.0)
		var white := clampf((float(stt.get("froude", 0.0)) - 1.0) / 1.2, 0.0, 1.0) \
			* clampf(depth / 0.25, 0.0, 1.0)
		var col := Color(tan.x * 0.5 + 0.5, tan.y * 0.5 + 0.5, spd, white)
		for k in ACROSS_VERTS:
			var lat := -1.0 + 2.0 * float(k) / float(ACROSS_VERTS - 1)
			var p := pts[i] + across * (lat * half)
			var y := level
			if not is_carved:
				var o := lat * half
				if has_drape and not ground_fn.is_valid():
					o = clampf(o, -d_r, d_r)
				if has_drape and absf(o) <= d_r:
					var t := (o + d_r) / (2.0 * d_r) * float(d_m - 1)
					var j := mini(int(t), d_m - 2)
					y = lerpf(dz[i * d_m + j], dz[i * d_m + j + 1], t - float(j)) + DRAPE_LIFT_M
				else:
					y = float(ground_fn.call(p.x, p.y)) + DRAPE_LIFT_M
			verts.append(Vector3(p.x, y, p.y))
			norms.append(Vector3.UP)
			cols.append(col)
			uvs.append(p)
			uv2s.append(Vector2(lat, s[i]))
		if run_open:
			var a0 := vtx - ACROSS_VERTS
			var b0 := vtx
			for k in ACROSS_VERTS - 1:
				idx.append(a0 + k)
				idx.append(b0 + k)
				idx.append(a0 + k + 1)
				idx.append(a0 + k + 1)
				idx.append(b0 + k)
				idx.append(b0 + k + 1)
		vtx += ACROSS_VERTS
		run_open = true
	if idx.is_empty():
		return []
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_TEX_UV2] = uv2s
	arr[Mesh.ARRAY_INDEX] = idx
	return arr


## The ground just outside each station's channel top (for feature_arrays).
static func bank_refs(f: Dictionary, prof: Dictionary, ground_fn: Callable) -> PackedFloat32Array:
	var pts: PackedVector2Array = prof.get("points", PackedVector2Array())
	var sec: Dictionary = f["section"]
	var top_half := float(sec.get("bed_w", 2.0)) * 0.5 \
		+ float(sec.get("bank_slope", 1.5)) * float(sec.get("depth", 0.8))
	var out := PackedFloat32Array()
	out.resize(pts.size())
	for i in pts.size():
		var across := _tangent(pts, i)
		across = Vector2(-across.y, across.x)
		var a := pts[i] + across * (top_half + 1.0)
		var b := pts[i] - across * (top_half + 1.0)
		out[i] = minf(float(ground_fn.call(a.x, a.y)), float(ground_fn.call(b.x, b.y)))
	return out


## The ground under every UNCARVED station at DRAPE_STEPS lateral offsets
## across ±(channel top + 1 m) — what feature_arrays drapes onto. Carved
## stations are level water and need none (left 0).
const DRAPE_STEPS := 7


static func drape_refs(f: Dictionary, prof: Dictionary, carved: PackedByteArray,
		ground_fn: Callable) -> Dictionary:
	var pts: PackedVector2Array = prof.get("points", PackedVector2Array())
	var sec: Dictionary = f["section"]
	var r := float(sec.get("bed_w", 2.0)) * 0.5 \
		+ float(sec.get("bank_slope", 1.5)) * float(sec.get("depth", 0.8)) + 1.0
	var m := DRAPE_STEPS
	var z := PackedFloat32Array()
	z.resize(pts.size() * m)
	for i in pts.size():
		if i < carved.size() and carved[i] == 1:
			continue
		var t := _tangent(pts, i)
		var across := Vector2(-t.y, t.x)
		for j in m:
			var p := pts[i] + across * (-r + 2.0 * r * float(j) / float(m - 1))
			z[i * m + j] = float(ground_fn.call(p.x, p.y))
	return {"z": z, "m": m, "r": r}


## A mesh of one surface per non-empty feature arrays.
static func mesh_from_arrays(list: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for a in list:
		if (a as Array).is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	return mesh if mesh.get_surface_count() > 0 else null


## Downstream unit tangent at station i (central difference).
static func _tangent(pts: PackedVector2Array, i: int) -> Vector2:
	var n := pts.size()
	var a := pts[maxi(i - 1, 0)]
	var b := pts[mini(i + 1, n - 1)]
	var d := b - a
	if d.length_squared() < 1e-9:
		return Vector2(1, 0)
	return d.normalized()
