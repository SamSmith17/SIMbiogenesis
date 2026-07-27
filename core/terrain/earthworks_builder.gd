class_name EarthworksBuilder
extends RefCounted

## Independent earthworks meshes for the terrain sculpt tool: raised berms /
## pads with a Slope slider (0 = sheer walls, 1 = soft embankment) and flat tops.
## Preview = flat brown; commit drapes aerial imagery via world-XZ shader UVs.

const BROWN := Color(0.45, 0.42, 0.38, 1.0)
## Horizontal run of embankment per metre of height at full slope (1.0).
## ~2.4 → a 2 m berm has ~4.8 m of soft shoulder at slope=1 (gentle fill).
const SLOPE_RUN_PER_RISE := 2.4
const MIN_HEIGHT_M := 0.05
const MAX_HEIGHT_M := 40.0
## Rings from base → crest (inclusive). More rings = smoother embankment.
const SLOPE_RINGS := 9
const DRAPE_SHADER := preload("res://core/terrain/earthworks_drape.gdshader")


## Inset every vertex toward the centroid by `inset_m` (clamped so the poly
## never collapses). Kept for callers that want a pure scale-toward-centre; berms
## use miter_inset (equal run on all sides).
static func radial_inset(poly: PackedVector2Array, inset_m: float) -> PackedVector2Array:
	if poly.size() < 3 or inset_m <= 1e-4:
		return poly.duplicate()
	var c := _centroid(poly)
	var out := PackedVector2Array()
	out.resize(poly.size())
	for i in poly.size():
		var d: Vector2 = poly[i] - c
		var len := d.length()
		if len < 0.05:
			out[i] = poly[i]
			continue
		# Keep at least 20% of the spoke so the crest never pinches to a point.
		var new_len := maxf(len - inset_m, len * 0.20)
		out[i] = c + d * (new_len / len)
	return out


## Inset a polygon by a CONSTANT perpendicular distance on every edge, keeping the
## original vertex count/correspondence (a miter offset). radial_inset scaled
## toward the centroid, which gave UNEQUAL run on the long-vs-short sides of a
## rectangle (the "long sides much steeper" bug); a miter inset moves every edge
## inward by the same metres, so all four sides get an equal-width shoulder.
static func miter_inset(poly: PackedVector2Array, inset_m: float) -> PackedVector2Array:
	var n := poly.size()
	if n < 3 or inset_m <= 1e-4:
		return poly.duplicate()
	# Winding: interior is on the left of each edge for a CCW ring.
	var area2 := 0.0
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		area2 += a.x * b.y - b.x * a.y
	var ccw := area2 > 0.0
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		var p_prev: Vector2 = poly[(i - 1 + n) % n]
		var p: Vector2 = poly[i]
		var p_next: Vector2 = poly[(i + 1) % n]
		var e0: Vector2 = p - p_prev
		var e1: Vector2 = p_next - p
		if e0.length() < 1e-6:
			e0 = e1
		if e1.length() < 1e-6:
			e1 = e0
		e0 = e0.normalized()
		e1 = e1.normalized()
		# Inward edge normals (left of edge dir for CCW; flipped for CW).
		var nrm0 := Vector2(-e0.y, e0.x)
		var nrm1 := Vector2(-e1.y, e1.x)
		if not ccw:
			nrm0 = -nrm0
			nrm1 = -nrm1
		var bis := nrm0 + nrm1
		if bis.length() < 1e-5:
			out[i] = p + nrm1 * inset_m
			continue
		bis = bis.normalized()
		# Miter length = inset / cos(half-angle); clamp so sharp corners don't
		# spike outward to (near) infinity.
		var denom := maxf(bis.dot(nrm1), 0.25)
		out[i] = p + bis * (inset_m / denom)
	return out


## Inset (or expand) a polygon toward its centroid by `inset_m` metres.
## Positive inset shrinks (equal perpendicular run via miter); negative expands
## via Geometry2D offset.
static func offset_poly(poly: PackedVector2Array, inset_m: float) -> PackedVector2Array:
	if poly.size() < 3 or absf(inset_m) < 1e-4:
		return poly.duplicate()
	if inset_m > 0.0:
		return miter_inset(poly, inset_m)
	var c := _centroid(poly)
	var offs2: Array = Geometry2D.offset_polygon(poly, -inset_m, Geometry2D.JOIN_ROUND)
	if not offs2.is_empty() and offs2[0] is PackedVector2Array and (offs2[0] as PackedVector2Array).size() >= 3:
		return offs2[0] as PackedVector2Array
	var max_r := 0.0
	for p in poly:
		max_r = maxf(max_r, p.distance_to(c))
	if max_r < 0.5:
		return poly.duplicate()
	var factor := clampf(1.0 - inset_m / max_r, 0.15, 3.0)
	var out := PackedVector2Array()
	out.resize(poly.size())
	for i in poly.size():
		out[i] = c + (poly[i] - c) * factor
	return out


## Build a raise earthwork: flat top at base_y + height, multi-ring sides.
## `base_y_fn` is Callable(x, z) -> float world Y of the ground under each point.
## Returns {mesh: ArrayMesh, collision: ConcavePolygonShape3D, top_y: float} or {}.
static func build_raise(poly: PackedVector2Array, height_m: float, slope01: float,
		base_y_fn: Callable, round01: float = 1.0) -> Dictionary:
	if poly.size() < 3:
		return {}
	var h := clampf(height_m, MIN_HEIGHT_M, MAX_HEIGHT_M)
	var slope := clampf(slope01, 0.0, 1.0)
	var inset := _clamped_inset(poly, slope * h * SLOPE_RUN_PER_RISE)
	var base_ys := PackedFloat32Array()
	base_ys.resize(poly.size())
	var rim_y := INF
	for i in poly.size():
		var y: float = float(base_y_fn.call(poly[i].x, poly[i].y))
		base_ys[i] = y
		rim_y = minf(rim_y, y)
	if not is_finite(rim_y):
		rim_y = 0.0
	var top_y := rim_y + h
	return _build_embankment(poly, base_ys, top_y, inset, true, round01)


## Vertical / sloped wall ring for a cut/pool (no floor — floor comes from heightmap).
## Returns {mesh, collision, floor_y} or {}.
static func build_cut_walls(poly: PackedVector2Array, depth_m: float, slope01: float,
		base_y_fn: Callable, round01: float = 1.0) -> Dictionary:
	if poly.size() < 3:
		return {}
	var depth := clampf(depth_m, MIN_HEIGHT_M, MAX_HEIGHT_M)
	var slope := clampf(slope01, 0.0, 1.0)
	# Soft cuts need no wall mesh — the heightmap ramp is enough.
	if slope > 0.85:
		return {}
	var inset := _clamped_inset(poly, slope * depth * SLOPE_RUN_PER_RISE)
	var rim_ys := PackedFloat32Array()
	rim_ys.resize(poly.size())
	var rim_y := -INF
	for i in poly.size():
		var y: float = float(base_y_fn.call(poly[i].x, poly[i].y))
		rim_ys[i] = y
		rim_y = maxf(rim_y, y)
	if not is_finite(rim_y):
		rim_y = 0.0
	var floor_y := rim_y - depth
	return _build_embankment(poly, rim_ys, floor_y, inset, false, round01)


static func preview_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BROWN
	mat.roughness = 0.92
	mat.metallic = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## World-XZ aerial drape (samples detail/hyper ortho on sloped faces).
## Falls back to brown preview when no texture is provided.
static func drape_material(ortho: Texture2D, half_extent_m: float,
		_bbox: Vector4 = Vector4.ZERO) -> Material:
	if ortho == null:
		return preview_material()
	var mat := ShaderMaterial.new()
	mat.shader = DRAPE_SHADER
	mat.set_shader_parameter("ortho_tex", ortho)
	mat.set_shader_parameter("half_extent_m", maxf(half_extent_m, 1.0))
	mat.set_meta("earthworks_half_extent", half_extent_m)
	return mat


## Encode plan UV from world XZ over ±half_extent (0,0 = NW-ish like terrain).
static func plan_uv(x: float, z: float, half_extent_m: float) -> Vector2:
	var he := maxf(half_extent_m, 1.0)
	return Vector2(
		clampf((x + he) / (2.0 * he), 0.0, 1.0),
		clampf((z + he) / (2.0 * he), 0.0, 1.0))


static func basin_tag_from_poly(poly: PackedVector2Array) -> String:
	if poly.is_empty():
		return "sculpt_pond_0_0"
	var c := _centroid(poly)
	var aabb := _aabb(poly)
	var hx := int(round(aabb.size.x))
	var hz := int(round(aabb.size.y))
	return "sculpt_pond_%d_%d_%d_%d_%d" % [
		roundi(c.x), roundi(c.y), poly.size(), hx, hz]


static func earthwork_tag_from_poly(poly: PackedVector2Array, kind: String) -> String:
	var c := _centroid(poly)
	return "ew_%s_%d_%d" % [kind, roundi(c.x), roundi(c.y)]


static func _centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(maxi(poly.size(), 1))


static func _aabb(poly: PackedVector2Array) -> Rect2:
	var min_v := poly[0]
	var max_v := poly[0]
	for p in poly:
		min_v.x = minf(min_v.x, p.x)
		min_v.y = minf(min_v.y, p.y)
		max_v.x = maxf(max_v.x, p.x)
		max_v.y = maxf(max_v.y, p.y)
	return Rect2(min_v, max_v - min_v)


static func _min_spoke(poly: PackedVector2Array) -> float:
	var c := _centroid(poly)
	var m := INF
	for p in poly:
		m = minf(m, p.distance_to(c))
	return 0.0 if not is_finite(m) else m


static func _clamped_inset(poly: PackedVector2Array, inset: float) -> float:
	if inset <= 0.0:
		return 0.0
	# Leave a usable crest (≥40% of the shortest spoke).
	return minf(inset, _min_spoke(poly) * 0.60)


## Smoothstep ease so the embankment flares gently near the crest instead of
## a single hard crease halfway up the face.
static func _embankment_t(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	# Smoothstep — more horizontal run near the top (gentler shoulder).
	return x * x * (3.0 - 2.0 * x)


## Multi-ring frustum between base_poly (per-vert Y) and a flat crest/floor.
## `raise_mode` true → crest above base; false → flat_y is the floor (cut walls).
## `round01` blends the height profile from a straight ramp (0) to a full S-curve
## (1): horizontal ring spacing stays LINEAR while height eases, which rounds the
## toe + shoulder instead of drawing one flat sloped face.
static func _build_embankment(base_poly: PackedVector2Array, base_ys: PackedFloat32Array,
		flat_y: float, inset: float, raise_mode: bool, round01: float = 1.0) -> Dictionary:
	var n := base_poly.size()
	if n < 3 or base_ys.size() < n:
		return {}
	var ring_count := SLOPE_RINGS if inset > 0.08 else 2
	var rnd := clampf(round01, 0.0, 1.0)
	var rings: Array = []  # each: {poly: PackedVector2Array, ys: PackedFloat32Array}
	for r in ring_count:
		var t := float(r) / float(maxi(ring_count - 1, 1))
		# Horizontal spacing linear in t; height eased by round01.
		var poly_r := miter_inset(base_poly, inset * t)
		var hs := lerpf(t, _embankment_t(t), rnd)
		var ys := PackedFloat32Array()
		ys.resize(n)
		for i in n:
			ys[i] = lerpf(base_ys[i], flat_y, hs)
		rings.append({"poly": poly_r, "ys": ys})
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Cap (crest or floor) from the innermost ring.
	var cap_ring: Dictionary = rings[rings.size() - 1]
	var cap: PackedVector2Array = cap_ring["poly"]
	var tri := Geometry2D.triangulate_polygon(cap)
	if tri.is_empty():
		tri = Geometry2D.triangulate_polygon(base_poly)
		cap = base_poly
	var cap_normal := Vector3.UP if raise_mode else Vector3.DOWN
	for i in range(0, tri.size(), 3):
		var order := [0, 1, 2] if raise_mode else [0, 2, 1]
		for ok in order:
			var idx: int = tri[i + ok]
			var p: Vector2 = cap[idx] if idx < cap.size() else cap[0]
			st.set_normal(cap_normal)
			st.set_uv(plan_uv(p.x, p.y, 500.0))
			st.add_vertex(Vector3(p.x, flat_y, p.y))
	# Side bands between consecutive rings.
	for r in ring_count - 1:
		var a: Dictionary = rings[r]
		var b: Dictionary = rings[r + 1]
		var pa: PackedVector2Array = a["poly"]
		var pb: PackedVector2Array = b["poly"]
		var ya: PackedFloat32Array = a["ys"]
		var yb: PackedFloat32Array = b["ys"]
		for i in n:
			var j := (i + 1) % n
			var v00 := Vector3(pa[i].x, ya[i], pa[i].y)
			var v10 := Vector3(pa[j].x, ya[j], pa[j].y)
			var v01 := Vector3(pb[i].x, yb[i], pb[i].y)
			var v11 := Vector3(pb[j].x, yb[j], pb[j].y)
			var edge := v10 - v00
			var up := v01 - v00
			var nrm := edge.cross(up).normalized()
			if nrm.length_squared() < 1e-8:
				nrm = Vector3.RIGHT
			# Outward-facing for raises (cross may point inward on CW polys).
			var mid := (v00 + v10 + v01 + v11) * 0.25
			var c3 := Vector3(_centroid(base_poly).x, mid.y, _centroid(base_poly).y)
			if raise_mode and nrm.dot(mid - c3) < 0.0:
				nrm = -nrm
			elif not raise_mode and nrm.dot(mid - c3) > 0.0:
				nrm = -nrm
			for verts in [[v00, v10, v11], [v00, v11, v01]]:
				for v in verts:
					st.set_normal(nrm)
					st.set_uv(plan_uv(v.x, v.z, 500.0))
					st.add_vertex(v)
	var mesh := st.commit()
	var coll := ConcavePolygonShape3D.new()
	var faces := PackedVector3Array()
	if mesh.get_surface_count() > 0:
		var arrs := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrs[Mesh.ARRAY_INDEX] if arrs[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			faces = verts
		else:
			faces.resize(indices.size())
			for ii in indices.size():
				faces[ii] = verts[indices[ii]]
		faces = MeshCollisionUtil.sanitize_faces(faces)
		if faces.size() >= 3:
			coll.set_faces(faces)
	return {
		"mesh": mesh,
		"collision": coll,
		"top_y": flat_y,
		"floor_y": flat_y,
		"rim_y": base_ys[0] if base_ys.size() > 0 else 0.0,
		"inset": inset,
		"top_points": cap.duplicate(),
	}


## Point-in-polygon + height query for footing. On the embankment shoulder,
## height lerps from rim to crest by radial progress (not a flat plateau).
static func height_at_raise(rec: Dictionary, x: float, z: float) -> float:
	var pts: PackedVector2Array = rec.get("points", PackedVector2Array())
	if pts.size() < 3:
		return NAN
	var p := Vector2(x, z)
	if not Geometry2D.is_point_in_polygon(p, pts):
		return NAN
	var top_y := float(rec.get("top_y", NAN))
	var rim_y := float(rec.get("rim_y", top_y))
	var h := float(rec.get("height_m", top_y - rim_y))
	var slope := clampf(float(rec.get("slope", 0.0)), 0.0, 1.0)
	var rnd := clampf(float(rec.get("round", 1.0)), 0.0, 1.0)
	var inset := _clamped_inset(pts, slope * h * SLOPE_RUN_PER_RISE)
	if inset < 0.05:
		return top_y
	var crest := miter_inset(pts, inset)
	if Geometry2D.is_point_in_polygon(p, crest):
		return top_y
	# Shoulder: estimate t from spoke length between outer rim and crest.
	var c := _centroid(pts)
	var spoke := p - c
	var slen := spoke.length()
	if slen < 1e-4:
		return top_y
	var dir := spoke / slen
	var outer_r := _ray_poly_radius(pts, c, dir)
	var inner_r := _ray_poly_radius(crest, c, dir)
	if outer_r <= inner_r + 1e-3:
		return top_y
	# t is the horizontal fraction from rim (0) to crest (1); height uses the
	# same eased profile the mesh builder applies.
	var t := 1.0 - clampf((slen - inner_r) / (outer_r - inner_r), 0.0, 1.0)
	var hs := lerpf(t, _embankment_t(t), rnd)
	return lerpf(rim_y, top_y, hs)


static func height_at_cut(rec: Dictionary, x: float, z: float) -> float:
	var pts: PackedVector2Array = rec.get("points", PackedVector2Array())
	if pts.size() < 3:
		return NAN
	if not Geometry2D.is_point_in_polygon(Vector2(x, z), pts):
		return NAN
	return float(rec.get("floor_y", NAN))


## Distance from centroid along `dir` to the polygon boundary (2D ray cast).
static func _ray_poly_radius(poly: PackedVector2Array, origin: Vector2, dir: Vector2) -> float:
	var best := 0.0
	for i in poly.size():
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % poly.size()]
		var hit: Variant = Geometry2D.segment_intersects_segment(
			origin, origin + dir * 1.0e5, a, b)
		if hit is Vector2:
			best = maxf(best, origin.distance_to(hit as Vector2))
	if best < 1e-4:
		# Fallback: max projection onto dir among verts.
		for p in poly:
			best = maxf(best, (p - origin).dot(dir))
	return maxf(best, 0.0)
