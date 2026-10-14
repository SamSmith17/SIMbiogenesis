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
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vtx := 0
	for it_v in items:
		var it: Dictionary = it_v
		vtx = _append_feature(st, vtx, it, ground_fn)
	if vtx == 0:
		return null
	st.generate_normals()
	return st.commit()


static func _append_feature(st: SurfaceTool, vtx_base: int, it: Dictionary,
		ground_fn: Callable) -> int:
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
		return vtx_base
	var sec: Dictionary = f["section"]
	var bank_z := maxf(float(sec.get("bank_slope", 1.5)), 0.05)
	var vtx := vtx_base
	var run_open := false   # true while the previous station emitted a row
	for i in n:
		var surf := StreamNetwork.mode_at(f, s[i], varc) == "surface"
		# A station at a span boundary belongs to the surface run when either
		# neighbouring span is open, so the strip reaches the culvert mouth.
		if not surf and i > 0:
			surf = StreamNetwork.mode_at(f, maxf(s[i] - 0.01, 0.0), varc) == "surface"
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
			# Overbank: the channel is full — hold the water at the bank top
			# and the width at the channel's top width there.
			var bank_y := float(ground_fn.call(pts[i].x + across.x * (half + 1.0),
				pts[i].y + across.y * (half + 1.0)))
			if level > bank_y:
				level = bank_y - 0.02
				half = maxf(half, float(sec.get("bed_w", 2.0)) * 0.5 + (level - bed[i]) * bank_z)
			# Only water that has climbed the banks is widened to tuck under
			# them; water over the flat bed keeps its own smooth edge.
			if half > float(sec.get("bed_w", 2.0)) * 0.5:
				half *= 1.0 + EDGE_TUCK
		var spd := clampf(float(stt.get("velocity_ms", 0.0)) / SPEED_FULL_MS, 0.0, 1.0)
		# White water needs both supercritical flow AND depth to tumble — a
		# 2 cm sheet on a steep slope has a high Froude number but is a glassy
		# riffle, not foam.
		var white := clampf((float(stt.get("froude", 0.0)) - 1.0) / 1.2, 0.0, 1.0) \
			* clampf(depth / 0.25, 0.0, 1.0)
		var col := Color(tan.x * 0.5 + 0.5, tan.y * 0.5 + 0.5, spd, white)
		for k in ACROSS_VERTS:
			var lat := -1.0 + 2.0 * float(k) / float(ACROSS_VERTS - 1)
			var p := pts[i] + across * (lat * half)
			var y := level
			if not is_carved:
				y = float(ground_fn.call(p.x, p.y)) + DRAPE_LIFT_M
			st.set_color(col)
			st.set_uv(p)
			st.set_uv2(Vector2(lat, s[i]))
			st.add_vertex(Vector3(p.x, y, p.y))
		if run_open:
			var a0 := vtx - ACROSS_VERTS
			var b0 := vtx
			for k in ACROSS_VERTS - 1:
				st.add_index(a0 + k)
				st.add_index(b0 + k)
				st.add_index(a0 + k + 1)
				st.add_index(a0 + k + 1)
				st.add_index(b0 + k)
				st.add_index(b0 + k + 1)
		vtx += ACROSS_VERTS
		run_open = true
	return vtx


## Downstream unit tangent at station i (central difference).
static func _tangent(pts: PackedVector2Array, i: int) -> Vector2:
	var n := pts.size()
	var a := pts[maxi(i - 1, 0)]
	var b := pts[mini(i + 1, n - 1)]
	var d := b - a
	if d.length_squared() < 1e-9:
		return Vector2(1, 0)
	return d.normalized()
