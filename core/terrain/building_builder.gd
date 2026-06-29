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


## Best-guess roof when OSM has no roof:shape — keep flat so total `height` stays accurate.
static func infer_roof_spec(tags: Dictionary, poly: PackedVector2Array) -> Dictionary:
	var spec := parse_roof_spec(tags)
	if tags.has("roof:shape") or tags.has("building:roof:shape"):
		return spec
	return spec


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

	var bottoms := PackedFloat32Array()
	bottoms.resize(n)
	for i in n:
		bottoms[i] = _sample_ground_y(poly[i].x, poly[i].y, elev, res, height_extent_m,
			center_elev, detail_elev, detail_cols, detail_rows, detail_extent_m)

	var tri_indices := Geometry2D.triangulate_polygon(poly)
	if tri_indices.is_empty():
		return vtx_base

	# OSM `height` is top-of-structure above local ground — roof must not exceed it.
	var wall_h := _wall_height_m(height_m, roof, poly)
	var eave_y := PackedFloat32Array()
	eave_y.resize(n)
	for i in n:
		eave_y[i] = bottoms[i] + wall_h

	var roof_y := _roof_corner_heights(poly, bottoms, height_m, wall_h, roof)

	# Corner positions at each ring level.
	var bottom_p: Array[Vector3] = []
	var eave_p: Array[Vector3] = []
	var roof_p: Array[Vector3] = []
	bottom_p.resize(n)
	eave_p.resize(n)
	roof_p.resize(n)
	for i in n:
		var p := poly[i]
		bottom_p[i] = Vector3(p.x, bottoms[i], p.y)
		eave_p[i] = Vector3(p.x, eave_y[i], p.y)
		roof_p[i] = Vector3(p.x, roof_y[i], p.y)

	# Flat shading: every triangle carries its own three vertices + a single face
	# normal, so wall corners and roof edges stay crisp instead of being averaged
	# into a smeared, balloon-like surface (shared vertices + generate_normals).
	var tris: Array = []

	# Floor (faces down).
	for t in range(0, tri_indices.size(), 3):
		tris.append([bottom_p[tri_indices[t + 2]], bottom_p[tri_indices[t + 1]],
			bottom_p[tri_indices[t]]])

	# Walls (outward-facing).
	for i in n:
		var j := (i + 1) % n
		tris.append([bottom_p[i], eave_p[i], eave_p[j]])
		tris.append([bottom_p[i], eave_p[j], bottom_p[j]])

	var shape := str(roof.get("shape", "flat"))
	var is_pyramid := shape in ["pyramidal", "hipped", "round", "mansard"]

	if not is_pyramid:
		# Roof cap (sloped corners already encoded in roof_p for gabled/skillion).
		for t in range(0, tri_indices.size(), 3):
			tris.append([roof_p[tri_indices[t]], roof_p[tri_indices[t + 1]],
				roof_p[tri_indices[t + 2]]])
	else:
		var center := _poly_centroid(poly)
		var ground_y := 0.0
		for i in n:
			ground_y += bottoms[i]
		ground_y /= float(maxi(n, 1))
		var apex := Vector3(center.x, ground_y + height_m, center.y)
		for i in n:
			var j := (i + 1) % n
			tris.append([eave_p[i], eave_p[j], apex])

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
		if shape in ["gabled", "saltbox"]:
			roof_rise = _obb_half_width(poly, _ridge_axis(poly, roof)) * tan(angle)
		elif shape in ["pyramidal", "hipped", "round", "mansard"]:
			var center := _poly_centroid(poly)
			var max_dist := 0.0
			for p in poly:
				max_dist = maxf(max_dist, p.distance_to(center))
			roof_rise = max_dist * tan(angle)
		elif shape in ["skillion", "lean_to"]:
			roof_rise = total_m * 0.2
	roof_rise = clampf(roof_rise, 0.0, minf(total_m * 0.3, 3.5))
	return maxf(total_m - roof_rise, total_m * 0.72)


static func _roof_corner_heights(poly: PackedVector2Array, bottoms: PackedFloat32Array,
		total_m: float, wall_h: float, roof: Dictionary) -> PackedFloat32Array:
	var n := poly.size()
	var out := PackedFloat32Array()
	out.resize(n)
	var shape := str(roof.get("shape", "flat"))
	if shape in ["flat", ""]:
		for i in n:
			out[i] = bottoms[i] + total_m
		return out
	if shape in ["pyramidal", "hipped", "round", "mansard"]:
		for i in n:
			out[i] = bottoms[i] + wall_h
		return out
	var axis := _ridge_axis(poly, roof)
	var half_w := _obb_half_width(poly, axis)
	var center := _poly_centroid(poly)
	if shape in ["gabled", "saltbox"]:
		for i in n:
			var dist := absf(_signed_ridge_dist(poly[i], axis, center))
			var t := clampf(dist / maxf(half_w, 1.0), 0.0, 1.0)
			out[i] = lerpf(bottoms[i] + total_m, bottoms[i] + wall_h, t)
	elif shape in ["skillion", "lean_to"]:
		var angle := deg_to_rad(TerrainBuilder.dict_float(roof, "angle_deg", 30.0))
		var slope := tan(angle)
		for i in n:
			var dist := _signed_ridge_dist(poly[i], axis, center)
			var rise := clampf(dist * slope, 0.0, total_m - wall_h)
			out[i] = bottoms[i] + wall_h + rise
			out[i] = minf(out[i], bottoms[i] + total_m)
	return out


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


static func _signed_ridge_dist(p: Vector2, axis: Vector2, center: Vector2) -> float:
	var perp := Vector2(-axis.y, axis.x)
	return (p - center).dot(perp)


static func _poly_centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(maxi(poly.size(), 1))
