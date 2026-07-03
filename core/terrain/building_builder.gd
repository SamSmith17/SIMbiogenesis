class_name BuildingBuilder
extends RefCounted

## Extrudes OSM building footprints onto the generated terrain with solid wall/roof
## materials (satellite drape on the ground already shows building roofs — draping
## extruded meshes too reads as doubled / floating copies).

const DEFAULT_HEIGHT_M := 8.0
const LEVELS_TO_METRES := 2.8
const MAX_HEIGHT_M := 200.0
const MIN_FOOTPRINT_AREA_M2 := 16.0
const MAX_BUILDINGS := 800
## Walls extend this far below the lowest corner sample so the downhill side
## never floats above DEM noise while eaves/roof stay level.
const FOUNDATION_SKIRT_M := 0.35

## Building types that read as houses — default gabled when OSM has no roof:shape.
const RESIDENTIAL_TYPES := ["house", "detached", "residential", "semidetached_house",
	"semi", "bungalow", "terrace", "terraced_house", "farm", "farmhouse", "cabin",
	"hut", "dormitory", "static_caravan", "villa", "cottage"]
## Types that keep the flat default (big-box / multi-storey / utility).
const FLAT_TYPES := ["commercial", "retail", "industrial", "warehouse", "office",
	"supermarket", "school", "hospital", "university", "college", "civic",
	"government", "public", "apartments", "hotel", "garage", "garages", "parking",
	"service", "roof", "hangar"]
## Typical US residential pitch (~6:12) for defaulted gables.
const DEFAULT_GABLED_ANGLE_DEG := 28.0
## `building=yes` heuristic: small, elongated footprints read as houses.
const GABLED_YES_MAX_AREA_M2 := 350.0
const GABLED_YES_MIN_ASPECT := 1.2


static func parse_height_m(tags: Dictionary) -> float:
	var from_levels := -1.0
	if tags.has("building:levels"):
		var lv := str(tags["building:levels"]).split("-")[0].split(";")[0].strip_edges().to_float()
		if not is_nan(lv) and lv > 0.0:
			from_levels = lv * LEVELS_TO_METRES
	var from_height := -1.0
	for key in ["height", "building:height"]:
		if tags.has(key):
			var parsed := _parse_length_to_metres(str(tags[key]))
			if parsed > 0.0:
				from_height = parsed
	if from_height > 0.0 and from_levels > 0.0:
		return clampf(minf(from_height, from_levels), 1.0, MAX_HEIGHT_M)
	if from_height > 0.0:
		return clampf(from_height, 1.0, MAX_HEIGHT_M)
	if from_levels > 0.0:
		return clampf(from_levels, 1.0, MAX_HEIGHT_M)
	return DEFAULT_HEIGHT_M


## OSM length tags may be metres, feet, or inches. Returns 0 when unparseable.
static func _parse_length_to_metres(raw: String) -> float:
	var s := raw.strip_edges().to_lower()
	if s.is_empty():
		return 0.0
	if s.contains("ft") or s.ends_with("'"):
		s = s.replace("feet", "").replace("foot", "").replace("ft", "").replace("'", "").strip_edges()
		var feet := s.to_float()
		return feet * 0.3048 if not is_nan(feet) and feet > 0.0 else 0.0
	if s.contains("in") or s.ends_with("\""):
		s = s.replace("inches", "").replace("inch", "").replace("in", "").replace("\"", "").strip_edges()
		var inches := s.to_float()
		return inches * 0.0254 if not is_nan(inches) and inches > 0.0 else 0.0
	s = s.trim_suffix("m").strip_edges()
	var metres := s.to_float()
	return metres if not is_nan(metres) and metres > 0.0 else 0.0


static func parse_roof_spec(tags: Dictionary) -> Dictionary:
	var shape := str(tags.get("roof:shape", tags.get("building:roof:shape", "flat"))).to_lower()
	var angle := 30.0
	if tags.has("roof:angle"):
		var av := str(tags["roof:angle"]).trim_suffix("°").strip_edges().to_float()
		if not is_nan(av):
			angle = clampf(av, 5.0, 60.0)
	var orient := str(tags.get("roof:orientation", "along")).to_lower()
	var dir_raw := str(tags.get("roof:direction", ""))
	var direction_deg := dir_raw.to_float() if dir_raw != "" else NAN
	var roof_h := 0.0
	if tags.has("roof:height"):
		roof_h = str(tags["roof:height"]).trim_suffix("m").strip_edges().to_float()
	return {
		"shape": shape,
		"angle_deg": angle,
		"orientation": orient,
		"direction_deg": direction_deg,
		"roof_height_m": roof_h,
	}


## Best-guess roof when OSM has no roof:shape: residential types default to a
## gabled roof, commercial/industrial stay flat, and bare `building=yes` falls
## back to a footprint heuristic. Explicit roof tags always win. The `source`
## key ("osm" | "default") records provenance for the Building Builder UI.
static func infer_roof_spec(tags: Dictionary, poly: PackedVector2Array) -> Dictionary:
	var spec := parse_roof_spec(tags)
	if tags.has("roof:shape") or tags.has("building:roof:shape"):
		spec["source"] = "osm"
		return spec
	spec["source"] = "default"
	var btype := str(tags.get("building", "")).to_lower()
	var gabled: bool
	if btype in RESIDENTIAL_TYPES:
		gabled = true
	elif btype in FLAT_TYPES:
		gabled = false
	else:
		gabled = footprint_area_m2(poly) < GABLED_YES_MAX_AREA_M2 \
			and _footprint_aspect(poly) >= GABLED_YES_MIN_ASPECT
	if gabled:
		spec["shape"] = "gabled"
		if not tags.has("roof:angle"):
			spec["angle_deg"] = DEFAULT_GABLED_ANGLE_DEG
	return spec


## OSM ways arrive in either winding; normalize to positive signed area in the
## XZ plane so wall quads always face outward and face orientation is
## deterministic downstream.
static func _ensure_ccw(poly: PackedVector2Array) -> PackedVector2Array:
	var area := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	if area < 0.0:
		var rev := poly.duplicate()
		rev.reverse()
		return rev
	return poly


## 2D cross (x,z plan view) of triangle p0→p1→p2. Positive = plan-CCW, which
## maps to a downward (-Y) face normal once lifted into 3D.
static func _plan_cross(p0: Vector2, p1: Vector2, p2: Vector2) -> float:
	return (p1 - p0).cross(p2 - p0)


static func _footprint_aspect(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 1.0
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_z := poly[0].y
	var max_z := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	var w := max_x - min_x
	var d := max_z - min_z
	return maxf(w, d) / maxf(minf(w, d), 1.0)


static func footprint_area_m2(points: PackedVector2Array) -> float:
	if points.size() < 3:
		return 0.0
	var area := 0.0
	for i in points.size():
		var j := (i + 1) % points.size()
		area += points[i].x * points[j].y - points[j].x * points[i].y
	return absf(area) * 0.5


static func _terrain_uv(x: float, z: float, extent_m: float) -> Vector2:
	var half := extent_m * 0.5
	return Vector2(
		clampf((x + half) / extent_m, 0.0, 1.0),
		clampf((z + half) / extent_m, 0.0, 1.0))


static func _sample_ground_y(x: float, z: float, elev: PackedFloat32Array, res: int,
		extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array = PackedFloat32Array(),
		detail_cols: int = 0, detail_rows: int = 0, detail_extent_m: float = 0.0) -> float:
	return TerrainBuilder.sample_footing_height(
		x, z, elev, res, extent_m, center_elev,
		detail_elev, detail_cols, detail_rows, detail_extent_m)


static func make_building_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.74, 0.71, 0.67)
	mat.roughness = 0.88
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# Match terrain drape (CULL_DISABLED): OSM footprints arrive in mixed winding
	# orders so back-face culling hides walls/roofs from some viewing angles.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## Flatten hi-res terrain under building footprints so extruded walls meet the mesh.
static func flatten_footprint_areas(grid: PackedFloat32Array, res: int, extent_m: float,
		buildings: Array) -> PackedFloat32Array:
	var polys: Array = []
	for item in buildings:
		if not (item is Dictionary):
			continue
		var pts: Variant = (item as Dictionary).get("points", PackedVector2Array())
		if pts is PackedVector2Array and (pts as PackedVector2Array).size() >= 3:
			polys.append({"points": pts})
	if polys.is_empty():
		return grid
	return TerrainRoadFlatten.apply_polygon_flattens(grid, res, extent_m, polys)


## Build a single combined mesh for all footprints. Returns null when empty.
## `height_extent_m` / `elev` is the natural DEM footing (no road flatten).
## Optional `detail_elev` supplies hi-res ground inside the centre patch.
static func build_buildings_node(buildings: Array, elev: PackedFloat32Array, res: int,
		height_extent_m: float, center_elev: float, base_drape: Texture2D,
		detail_drape: Texture2D = null, detail_extent_m: float = 0.0,
		terrain_extent_m: float = 0.0,
		detail_elev: PackedFloat32Array = PackedFloat32Array(), detail_cols: int = 0,
		detail_rows: int = 0, excluded_indices: Array = [],
		cast_shadows: bool = true) -> Node3D:
	var excluded: Dictionary = {}
	for i in excluded_indices:
		excluded[int(i)] = true
	var uv_extent := terrain_extent_m if terrain_extent_m > 0.0 else height_extent_m
	var detail_foot_extent := detail_extent_m if not detail_elev.is_empty() else 0.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vtx_base := 0
	var added := 0
	for item in buildings:
		if added >= MAX_BUILDINGS:
			break
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var bidx := int(d.get("idx", -1))
		if excluded.has(bidx):
			continue
		var pts: Variant = d.get("points", PackedVector2Array())
		if not (pts is PackedVector2Array):
			continue
		var poly: PackedVector2Array = pts
		if poly.size() < 3:
			continue
		if footprint_area_m2(poly) < MIN_FOOTPRINT_AREA_M2:
			continue
		var height_m := TerrainBuilder.dict_float(d, "height_m", DEFAULT_HEIGHT_M)
		var roof: Dictionary = d.get("roof", infer_roof_spec(d.get("tags", {}), poly))
		var next_base: int = _append_footprint(st, poly, height_m, roof, elev, res,
			height_extent_m, center_elev, uv_extent, vtx_base,
			detail_elev, detail_cols, detail_rows, detail_foot_extent)
		if next_base > vtx_base:
			vtx_base = next_base
			added += 1
	if added == 0:
		return null
	# Normals are set per-face in _append_footprint for crisp, faceted walls/roofs;
	# generate_normals() here would average them across corners and smear the look.
	var root := Node3D.new()
	root.name = "Buildings"
	var mi := MeshInstance3D.new()
	mi.name = "BuildingMeshes"
	mi.mesh = st.commit()
	mi.material_override = make_building_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	return root


static func _append_footprint(st: SurfaceTool, poly: PackedVector2Array, height_m: float,
		roof: Dictionary, elev: PackedFloat32Array, res: int,
		height_extent_m: float, center_elev: float, uv_extent_m: float,
		vtx_base: int,
		detail_elev: PackedFloat32Array = PackedFloat32Array(),
		detail_cols: int = 0, detail_rows: int = 0, detail_extent_m: float = 0.0) -> int:
	var n := poly.size()
	if n < 3:
		return vtx_base
	if poly[0].distance_squared_to(poly[n - 1]) < 0.01:
		poly = poly.slice(0, n - 1)
		n = poly.size()
	if n < 3:
		return vtx_base
	poly = _ensure_ccw(poly)

	# Seat the whole building at its lowest corner sample: real eaves and roofs
	# are level regardless of slope; the uphill walls simply bury into the hill.
	var base_y := INF
	for i in n:
		base_y = minf(base_y, _sample_ground_y(poly[i].x, poly[i].y, elev, res,
			height_extent_m, center_elev, detail_elev, detail_cols, detail_rows,
			detail_extent_m))
	var skirt_y := base_y - FOUNDATION_SKIRT_M

	var tri_indices := Geometry2D.triangulate_polygon(poly)
	if tri_indices.is_empty():
		return vtx_base

	# OSM `height` is top-of-structure above local ground — roof must not exceed it.
	var wall_h := _wall_height_m(height_m, roof, poly)
	var frame := _roof_frame(poly, roof, base_y, wall_h, height_m)
	var top_y := base_y + height_m

	var bottom_p: Array[Vector3] = []
	bottom_p.resize(n)
	for i in n:
		bottom_p[i] = Vector3(poly[i].x, skirt_y, poly[i].y)

	# Flat shading: every triangle carries its own three vertices + a single face
	# normal, so wall corners and roof edges stay crisp instead of being averaged
	# into a smeared, balloon-like surface (shared vertices + generate_normals).
	var tris: Array = []

	# Floor (faces down). triangulate_polygon's output winding follows the
	# input polygon, but orient every horizontal face explicitly so lighting
	# stays correct regardless of triangulation details.
	for t in range(0, tri_indices.size(), 3):
		var f0 := tri_indices[t]
		var f1 := tri_indices[t + 1]
		var f2 := tri_indices[t + 2]
		if _plan_cross(poly[f0], poly[f1], poly[f2]) < 0.0:
			var tmp := f1
			f1 = f2
			f2 = tmp
		tris.append([bottom_p[f0], bottom_p[f1], bottom_p[f2]])

	if frame.is_empty():
		# Flat roof (explicit tag, unknown shape, or degenerate-footprint
		# guardrail): walls straight up to the roof plane, level cap on top.
		for i in n:
			var j := (i + 1) % n
			var t0 := Vector3(poly[i].x, top_y, poly[i].y)
			var t1 := Vector3(poly[j].x, top_y, poly[j].y)
			tris.append([bottom_p[i], t0, t1])
			tris.append([bottom_p[i], t1, bottom_p[j]])
		for t in range(0, tri_indices.size(), 3):
			var r0 := tri_indices[t]
			var r1 := tri_indices[t + 1]
			var r2 := tri_indices[t + 2]
			if _plan_cross(poly[r0], poly[r1], poly[r2]) > 0.0:
				var tmp := r1
				r1 = r2
				r2 = tmp
			tris.append([Vector3(poly[r0].x, top_y, poly[r0].y),
				Vector3(poly[r1].x, top_y, poly[r1].y),
				Vector3(poly[r2].x, top_y, poly[r2].y)])
	else:
		var creases := _crease_lines(frame)

		# Walls, including the triangular gable-end fills: each boundary edge is
		# split where a roof crease crosses it, then extruded up to the roof
		# height field. Sharing _roof_height_at with the roof surface keeps wall
		# tops and roof edges watertight.
		for i in n:
			var j := (i + 1) % n
			var edge_pts := _split_edge_at_creases(poly[i], poly[j], frame, creases)
			for k in edge_pts.size() - 1:
				var q0: Vector2 = edge_pts[k]
				var q1: Vector2 = edge_pts[k + 1]
				var b0 := Vector3(q0.x, skirt_y, q0.y)
				var b1 := Vector3(q1.x, skirt_y, q1.y)
				var t0 := Vector3(q0.x, _roof_height_at(q0, frame), q0.y)
				var t1 := Vector3(q1.x, _roof_height_at(q1, frame), q1.y)
				tris.append([b0, t0, t1])
				tris.append([b0, t1, b1])

		# Roof: footprint triangulation split along every crease line so each
		# resulting triangle lies inside one planar roof face, then lifted.
		var tris2d: Array = []
		for t in range(0, tri_indices.size(), 3):
			tris2d.append([poly[tri_indices[t]], poly[tri_indices[t + 1]],
				poly[tri_indices[t + 2]]])
		for line in creases:
			tris2d = _split_tris_at_line(tris2d, frame, line)
		for tri2 in tris2d:
			var p0: Vector2 = tri2[0]
			var p1: Vector2 = tri2[1]
			var p2: Vector2 = tri2[2]
			if _plan_cross(p0, p1, p2) > 0.0:
				var tmp2 := p1
				p1 = p2
				p2 = tmp2
			tris.append([Vector3(p0.x, _roof_height_at(p0, frame), p0.y),
				Vector3(p1.x, _roof_height_at(p1, frame), p1.y),
				Vector3(p2.x, _roof_height_at(p2, frame), p2.y)])

	var emitted := 0
	for tri in tris:
		var a: Vector3 = tri[0]
		var b: Vector3 = tri[1]
		var c: Vector3 = tri[2]
		var nrm := (b - a).cross(c - a)
		if nrm.length_squared() < 1e-10:
			continue
		nrm = nrm.normalized()
		for v in [a, b, c]:
			st.set_normal(nrm)
			st.set_uv(_terrain_uv(v.x, v.z, uv_extent_m))
			st.add_vertex(v)
			st.add_index(vtx_base + emitted)
			emitted += 1

	return vtx_base + emitted


## Wall height below the OSM total height; remainder is reserved for roof slope.
static func _wall_height_m(total_m: float, roof: Dictionary, poly: PackedVector2Array) -> float:
	var shape := str(roof.get("shape", "flat"))
	if shape in ["flat", ""]:
		return total_m
	var roof_rise := TerrainBuilder.dict_float(roof, "roof_height_m", 0.0)
	if roof_rise <= 0.0:
		var angle := deg_to_rad(TerrainBuilder.dict_float(roof, "angle_deg", 30.0))
		if shape in ["gabled", "saltbox", "pyramidal", "hipped", "round", "mansard"]:
			# Slope run is the OBB half-width for every ridge/hip shape (the
			# height field is Chebyshev distance to the ridge segment).
			roof_rise = _obb_half_width(poly, _ridge_axis(poly, roof)) * tan(angle)
		elif shape in ["skillion", "lean_to"]:
			roof_rise = total_m * 0.2
	roof_rise = clampf(roof_rise, 0.0, minf(total_m * 0.3, 3.5))
	return maxf(total_m - roof_rise, total_m * 0.72)


## Ridge frame for a pitched roof: the local (along-ridge a, across-ridge b)
## coordinate system plus the ridge segment half-length. Returns {} for flat /
## unknown shapes and for degenerate footprints (star-shaped or self-
## intersecting ways get a flat roof rather than garbage creases).
static func _roof_frame(poly: PackedVector2Array, roof: Dictionary, base_y: float,
		wall_h: float, height_m: float) -> Dictionary:
	var shape := str(roof.get("shape", "flat"))
	if shape in ["flat", ""] or wall_h >= height_m - 0.001:
		return {}
	if not shape in ["gabled", "saltbox", "hipped", "pyramidal", "round", "mansard",
			"skillion", "lean_to"]:
		return {}
	var axis := _ridge_axis(poly, roof)
	var center := _poly_centroid(poly)
	var half_w := _obb_half_width(poly, axis)
	var half_len := _obb_half_len(poly, axis)
	if footprint_area_m2(poly) < 0.3 * (4.0 * half_w * half_len):
		return {}
	var eave_y := base_y + wall_h
	var top_y := base_y + height_m
	var frame := {
		"shape": shape,
		"axis": axis,
		"perp": Vector2(-axis.y, axis.x),
		"center": center,
		"half_w": half_w,
		"eave_y": eave_y,
		"top_y": top_y,
		"rise": maxf(top_y - eave_y, 0.0),
		"ridge_half_len": half_len,
	}
	if shape in ["hipped", "round", "mansard"]:
		frame["ridge_half_len"] = maxf(half_len - half_w, 0.0)
	elif shape == "pyramidal":
		frame["ridge_half_len"] = 0.0
	elif shape in ["skillion", "lean_to"]:
		frame["slope"] = tan(deg_to_rad(TerrainBuilder.dict_float(roof, "angle_deg", 30.0)))
	return frame


## Roof surface height at plan position p. Ridge shapes use Chebyshev distance
## to the ridge segment (u = max(|b|, |a| - ridge_half_len)) which produces the
## classic planar gable/hip/pyramid faces; skillion is a one-sided ramp.
static func _roof_height_at(p: Vector2, frame: Dictionary) -> float:
	var rel: Vector2 = p - (frame["center"] as Vector2)
	var a := rel.dot(frame["axis"] as Vector2)
	var b := rel.dot(frame["perp"] as Vector2)
	var eave_y := float(frame["eave_y"])
	if str(frame["shape"]) in ["skillion", "lean_to"]:
		return eave_y + clampf(b * float(frame["slope"]), 0.0,
			float(frame["top_y"]) - eave_y)
	var r := float(frame["ridge_half_len"])
	var u := maxf(maxf(absf(b), a - r), maxf(-a - r, 0.0))
	var t := clampf(u / maxf(float(frame["half_w"]), 0.001), 0.0, 1.0)
	return eave_y + float(frame["rise"]) * (1.0 - t)


## Crease lines of the roof height field as Vector3(ca, cb, c0) coefficients
## over ridge-frame coordinates: the crease is the zero set of ca*a + cb*b + c0.
static func _crease_lines(frame: Dictionary) -> Array:
	var shape := str(frame["shape"])
	if shape in ["skillion", "lean_to"]:
		var lines: Array = [Vector3(0, 1, 0)]
		var slope := float(frame["slope"])
		if slope > 0.001:
			var clamp_b := (float(frame["top_y"]) - float(frame["eave_y"])) / slope
			lines.append(Vector3(0, 1, -clamp_b))
		return lines
	if shape in ["gabled", "saltbox"]:
		return [Vector3(0, 1, 0)]
	var r := float(frame["ridge_half_len"])
	if r <= 0.001:
		# Pyramid: the two plan diagonals |b| == |a|.
		return [Vector3(-1, 1, 0), Vector3(1, 1, 0)]
	# Hip: ridge plus the four hip creases |b| == ±a - r.
	return [Vector3(0, 1, 0), Vector3(-1, 1, r), Vector3(1, 1, -r),
		Vector3(1, 1, r), Vector3(-1, 1, -r)]


static func _crease_eval(p: Vector2, frame: Dictionary, line: Vector3) -> float:
	var rel: Vector2 = p - (frame["center"] as Vector2)
	return line.x * rel.dot(frame["axis"] as Vector2) \
		+ line.y * rel.dot(frame["perp"] as Vector2) + line.z


## Split 2D triangles at the zero set of one crease line so each output
## triangle lies entirely on one side (each side of a crease is planar).
static func _split_tris_at_line(tris_2d: Array, frame: Dictionary, line: Vector3) -> Array:
	var out: Array = []
	for tri in tris_2d:
		var d0 := _crease_eval(tri[0], frame, line)
		var d1 := _crease_eval(tri[1], frame, line)
		var d2 := _crease_eval(tri[2], frame, line)
		var ds := [d0, d1, d2]
		var has_pos := false
		var has_neg := false
		for dv in ds:
			if dv > 0.001:
				has_pos = true
			elif dv < -0.001:
				has_neg = true
		if not (has_pos and has_neg):
			out.append(tri)
			continue
		var pos: Array = []
		var neg: Array = []
		for i in 3:
			var j := (i + 1) % 3
			var di: float = ds[i]
			var dj: float = ds[j]
			if di >= -0.001:
				pos.append(tri[i])
			if di <= 0.001:
				neg.append(tri[i])
			if (di > 0.001 and dj < -0.001) or (di < -0.001 and dj > 0.001):
				var x: Vector2 = (tri[i] as Vector2).lerp(tri[j], di / (di - dj))
				pos.append(x)
				neg.append(x)
		for side in [pos, neg]:
			for k in range(1, side.size() - 1):
				if absf(_plan_cross(side[0], side[k], side[k + 1])) > 1e-7:
					out.append([side[0], side[k], side[k + 1]])
	return out


## Points along boundary edge p0→p1, split where crease lines cross it.
static func _split_edge_at_creases(p0: Vector2, p1: Vector2, frame: Dictionary,
		creases: Array) -> Array:
	var ts: Array[float] = []
	for line in creases:
		var d0 := _crease_eval(p0, frame, line)
		var d1 := _crease_eval(p1, frame, line)
		if (d0 > 0.001 and d1 < -0.001) or (d0 < -0.001 and d1 > 0.001):
			ts.append(d0 / (d0 - d1))
	ts.sort()
	var pts: Array = [p0]
	for t in ts:
		if t <= 1e-5 or t >= 1.0 - 1e-5:
			continue
		var q := p0.lerp(p1, t)
		if q.distance_squared_to(pts[pts.size() - 1]) > 1e-10:
			pts.append(q)
	pts.append(p1)
	return pts


static func _ridge_axis(poly: PackedVector2Array, roof: Dictionary) -> Vector2:
	var dir_deg: float = TerrainBuilder.dict_float(roof, "direction_deg", NAN)
	if not is_nan(dir_deg):
		var rad := deg_to_rad(dir_deg)
		return Vector2(sin(rad), cos(rad)).normalized()
	var best_len := 0.0
	var best := Vector2(1, 0)
	for i in poly.size():
		var j := (i + 1) % poly.size()
		var edge := poly[j] - poly[i]
		var l := edge.length_squared()
		if l > best_len:
			best_len = l
			best = edge.normalized()
	if str(roof.get("orientation", "along")) == "across":
		best = Vector2(-best.y, best.x)
	return best


static func _obb_half_width(poly: PackedVector2Array, axis: Vector2) -> float:
	var perp := Vector2(-axis.y, axis.x)
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= float(poly.size())
	var max_d := 0.0
	for p in poly:
		max_d = maxf(max_d, absf((p - center).dot(perp)))
	return maxf(max_d, 1.0)


static func _obb_half_len(poly: PackedVector2Array, axis: Vector2) -> float:
	var center := _poly_centroid(poly)
	var max_d := 0.0
	for p in poly:
		max_d = maxf(max_d, absf((p - center).dot(axis)))
	return maxf(max_d, 1.0)


static func _signed_ridge_dist(p: Vector2, axis: Vector2, center: Vector2) -> float:
	var perp := Vector2(-axis.y, axis.x)
	return (p - center).dot(perp)


static func _poly_centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(maxi(poly.size(), 1))
