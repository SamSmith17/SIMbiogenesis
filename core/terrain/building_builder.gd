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


## Muted fallback palettes hashed off the stable tag (deterministic per site).
const WALL_PALETTE: Array[Color] = [
	Color(0.78, 0.73, 0.62), Color(0.72, 0.72, 0.70), Color(0.66, 0.70, 0.60),
	Color(0.70, 0.56, 0.48), Color(0.82, 0.78, 0.70), Color(0.63, 0.65, 0.56)]
const ROOF_PALETTE: Array[Color] = [
	Color(0.29, 0.29, 0.31), Color(0.42, 0.33, 0.27), Color(0.50, 0.50, 0.52),
	Color(0.47, 0.30, 0.26)]


## Stable identity for a footprint: metre-rounded centroid (mirrors the solar
## array tag scheme) — survives re-fetches as long as the way's geometry holds.
static func building_tag(poly: PackedVector2Array) -> String:
	var c := _poly_centroid(poly)
	return "bldg_%d_%d" % [roundi(c.x), roundi(c.y)]


## Effective build parameters for one building record + optional per-building
## style overrides, precedence style > OSM tags > defaults. Recognized style
## keys: roof_shape, roof_pitch_deg, wall_color / roof_color (Color, [r,g,b,a]
## array, or CSS string), height_m, base_y_offset_m, elements.
static func resolve_building_params(d: Dictionary, style: Dictionary) -> Dictionary:
	var pts: Variant = d.get("points", PackedVector2Array())
	var poly: PackedVector2Array = pts if pts is PackedVector2Array else PackedVector2Array()
	var tags: Dictionary = d.get("tags", {})
	var height_m := TerrainBuilder.dict_float(d, "height_m", DEFAULT_HEIGHT_M)
	var style_h := TerrainBuilder.dict_float(style, "height_m", 0.0)
	if style_h > 0.0:
		height_m = clampf(style_h, 1.0, MAX_HEIGHT_M)
	var roof_v: Variant = d.get("roof", infer_roof_spec(tags, poly))
	var roof: Dictionary = (roof_v as Dictionary).duplicate() if roof_v is Dictionary \
		else infer_roof_spec(tags, poly)
	if str(style.get("roof_shape", "")) != "":
		roof["shape"] = str(style["roof_shape"])
		roof["source"] = "user"
	if style.has("roof_pitch_deg"):
		roof["angle_deg"] = clampf(
			TerrainBuilder.dict_float(style, "roof_pitch_deg", 30.0), 5.0, 60.0)
		roof["roof_height_m"] = 0.0
		roof["source"] = "user"
	var colors := resolve_building_colors(tags, building_tag(poly))
	if style.has("wall_color"):
		colors["wall"] = style_color(style["wall_color"], colors["wall"])
	if style.has("roof_color"):
		colors["roof"] = style_color(style["roof_color"], colors["roof"])
	return {
		"poly": poly,
		"height_m": height_m,
		"roof": roof,
		"colors": colors,
		"base_offset_m": clampf(
			TerrainBuilder.dict_float(style, "base_y_offset_m", 0.0), -5.0, 5.0),
		"elements": style.get("elements", []),
	}


## Style colors may be Color values, [r,g,b(,a)] JSON arrays, or CSS strings.
static func style_color(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var arr: Array = v
		var a := float(arr[3]) if arr.size() > 3 else 1.0
		return Color(float(arr[0]), float(arr[1]), float(arr[2]), a)
	if v is String:
		return Color.from_string(v, fallback)
	return fallback


## Wall/roof colors: OSM building:colour / roof:colour when tagged, otherwise
## a deterministic palette pick + value jitter hashed from the stable tag.
static func resolve_building_colors(tags: Dictionary, stable_tag: String) -> Dictionary:
	var h := stable_tag.hash()
	var wall: Color = WALL_PALETTE[h % WALL_PALETTE.size()]
	var roof: Color = ROOF_PALETTE[(h / 7) % ROOF_PALETTE.size()]
	var jitter := 0.92 + 0.16 * float(h % 97) / 97.0
	wall = Color(wall.r * jitter, wall.g * jitter, wall.b * jitter)
	if tags.has("building:colour"):
		wall = Color.from_string(str(tags["building:colour"]).strip_edges(), wall)
	if tags.has("roof:colour"):
		roof = Color.from_string(str(tags["roof:colour"]).strip_edges(), roof)
	return {"wall": wall, "roof": roof}


static func _sample_ground_y(x: float, z: float, elev: PackedFloat32Array, res: int,
		extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array = PackedFloat32Array(),
		detail_cols: int = 0, detail_rows: int = 0, detail_extent_m: float = 0.0) -> float:
	return TerrainBuilder.sample_footing_height(
		x, z, elev, res, extent_m, center_elev,
		detail_elev, detail_cols, detail_rows, detail_extent_m)


const WALL_SHADER := preload("res://core/terrain/building_wall.gdshader")
const ROOF_SHADER := preload("res://core/terrain/building_roof.gdshader")


## Procedural lap-siding walls; per-building tint arrives in vertex COLOR.
## Shared instance semantics: each call returns a fresh material so callers
## (world mesh vs Building Builder studio) can tweak uniforms independently.
static func make_wall_material() -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = WALL_SHADER
	return mat


## Procedural shingle/membrane roof; COLOR.a picks the branch per building.
static func make_roof_material() -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = ROOF_SHADER
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
	var detail_foot_extent := detail_extent_m if not detail_elev.is_empty() else 0.0
	var st_walls := SurfaceTool.new()
	st_walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_roof := SurfaceTool.new()
	st_roof.begin(Mesh.PRIMITIVE_TRIANGLES)
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
		var params := resolve_building_params(d, {})
		if _append_footprint(st_walls, st_roof, poly, params["height_m"],
				params["roof"], params["colors"], elev, res,
				height_extent_m, center_elev,
				detail_elev, detail_cols, detail_rows, detail_foot_extent):
			added += 1
	if added == 0:
		return null
	# Normals are set per-face in _append_footprint for crisp, faceted walls/roofs;
	# generate_normals() here would average them across corners and smear the look.
	# Surface 0 = walls (+ gable fills + floor), surface 1 = roof planes: one
	# mesh, two draw calls, each surface with its own material.
	var root := Node3D.new()
	root.name = "Buildings"
	var mi := MeshInstance3D.new()
	mi.name = "BuildingMeshes"
	var mesh: ArrayMesh = st_walls.commit()
	mesh = st_roof.commit(mesh)
	mi.mesh = mesh
	mi.set_surface_override_material(0, make_wall_material())
	mi.set_surface_override_material(1, make_roof_material())
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	return root


## One styled building as its own MeshInstance3D. Styled buildings are
## excluded from the merged mesh and rebuilt individually; the Building
## Builder studio calls this with a flat 2×2 zero DEM so the preview and the
## world share one geometry code path.
static func build_single_building(d: Dictionary, style: Dictionary,
		elev: PackedFloat32Array, res: int, height_extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array = PackedFloat32Array(), detail_cols: int = 0,
		detail_rows: int = 0, detail_extent_m: float = 0.0,
		cast_shadows: bool = true) -> MeshInstance3D:
	var params := resolve_building_params(d, style)
	var poly: PackedVector2Array = params["poly"]
	if poly.size() < 3:
		return null
	var st_walls := SurfaceTool.new()
	st_walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_roof := SurfaceTool.new()
	st_roof.begin(Mesh.PRIMITIVE_TRIANGLES)
	var detail_foot_extent := detail_extent_m if not detail_elev.is_empty() else 0.0
	if not _append_footprint(st_walls, st_roof, poly, params["height_m"],
			params["roof"], params["colors"], elev, res, height_extent_m, center_elev,
			detail_elev, detail_cols, detail_rows, detail_foot_extent,
			float(params["base_offset_m"])):
		return null
	var mi := MeshInstance3D.new()
	mi.name = "BuildingMesh"
	var mesh: ArrayMesh = st_walls.commit()
	mesh = st_roof.commit(mesh)
	mi.mesh = mesh
	mi.set_surface_override_material(0, make_wall_material())
	mi.set_surface_override_material(1, make_roof_material())
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _append_footprint(st_walls: SurfaceTool, st_roof: SurfaceTool,
		poly: PackedVector2Array, height_m: float, roof: Dictionary, colors: Dictionary,
		elev: PackedFloat32Array, res: int,
		height_extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array = PackedFloat32Array(),
		detail_cols: int = 0, detail_rows: int = 0, detail_extent_m: float = 0.0,
		base_offset_m: float = 0.0) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	if poly[0].distance_squared_to(poly[n - 1]) < 0.01:
		poly = poly.slice(0, n - 1)
		n = poly.size()
	if n < 3:
		return false
	poly = _ensure_ccw(poly)

	# Seat the whole building at its lowest corner sample: real eaves and roofs
	# are level regardless of slope; the uphill walls simply bury into the hill.
	# base_offset_m is the user's vertical-placement nudge from the style layer.
	var base_y := INF
	for i in n:
		base_y = minf(base_y, _sample_ground_y(poly[i].x, poly[i].y, elev, res,
			height_extent_m, center_elev, detail_elev, detail_cols, detail_rows,
			detail_extent_m))
	base_y += base_offset_m
	var skirt_y := base_y - FOUNDATION_SKIRT_M

	var tri_indices := Geometry2D.triangulate_polygon(poly)
	if tri_indices.is_empty():
		return false

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
	# Wall faces carry explicit metric UVs ([a, b, c, uv_a, uv_b, uv_c]); roof
	# UVs are derived per-face at emission time.
	var wall_faces: Array = []
	var roof_faces: Array = []

	# Floor (faces down), on the walls surface — unseen underground; its
	# negative V lands in the wall shader's foundation band.
	for t in range(0, tri_indices.size(), 3):
		var f0 := tri_indices[t]
		var f1 := tri_indices[t + 1]
		var f2 := tri_indices[t + 2]
		if _plan_cross(poly[f0], poly[f1], poly[f2]) < 0.0:
			var tmp := f1
			f1 = f2
			f2 = tmp
		wall_faces.append([bottom_p[f0], bottom_p[f1], bottom_p[f2],
			Vector2(poly[f0].x, -FOUNDATION_SKIRT_M),
			Vector2(poly[f1].x, -FOUNDATION_SKIRT_M),
			Vector2(poly[f2].x, -FOUNDATION_SKIRT_M)])

	if frame.is_empty():
		# Flat roof (explicit tag, unknown shape, or degenerate-footprint
		# guardrail): walls straight up to the roof plane, level cap on top.
		for i in n:
			var j := (i + 1) % n
			var dir := (poly[j] - poly[i]).normalized()
			_wall_quad(wall_faces, poly[i], dir, poly[i], poly[j],
				skirt_y, top_y, top_y, base_y)
		for t in range(0, tri_indices.size(), 3):
			var r0 := tri_indices[t]
			var r1 := tri_indices[t + 1]
			var r2 := tri_indices[t + 2]
			if _plan_cross(poly[r0], poly[r1], poly[r2]) > 0.0:
				var tmp := r1
				r1 = r2
				r2 = tmp
			roof_faces.append([Vector3(poly[r0].x, top_y, poly[r0].y),
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
			var dir := (poly[j] - poly[i]).normalized()
			var edge_pts := _split_edge_at_creases(poly[i], poly[j], frame, creases)
			for k in edge_pts.size() - 1:
				var q0: Vector2 = edge_pts[k]
				var q1: Vector2 = edge_pts[k + 1]
				_wall_quad(wall_faces, poly[i], dir, q0, q1, skirt_y,
					_roof_height_at(q0, frame), _roof_height_at(q1, frame), base_y)

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
			roof_faces.append([Vector3(p0.x, _roof_height_at(p0, frame), p0.y),
				Vector3(p1.x, _roof_height_at(p1, frame), p1.y),
				Vector3(p2.x, _roof_height_at(p2, frame), p2.y)])

	var wall_col: Color = colors.get("wall", Color(0.74, 0.71, 0.67))
	wall_col.a = 1.0
	var roof_col: Color = colors.get("roof", Color(0.35, 0.33, 0.32))
	# COLOR.a flags the roof shader per building: 1 = pitched (shingle courses),
	# 0 = flat (membrane/gravel).
	roof_col.a = 0.0 if frame.is_empty() else 1.0

	var emitted := false
	for f in wall_faces:
		var a: Vector3 = f[0]
		var b: Vector3 = f[1]
		var c: Vector3 = f[2]
		var nrm := (b - a).cross(c - a)
		if nrm.length_squared() < 1e-10:
			continue
		nrm = nrm.normalized()
		for k in 3:
			st_walls.set_normal(nrm)
			st_walls.set_color(wall_col)
			st_walls.set_uv(f[3 + k])
			st_walls.add_vertex(f[k])
		emitted = true
	for f in roof_faces:
		var a: Vector3 = f[0]
		var b: Vector3 = f[1]
		var c: Vector3 = f[2]
		var nrm := (b - a).cross(c - a)
		if nrm.length_squared() < 1e-10:
			continue
		nrm = nrm.normalized()
		var uvs := _roof_face_uvs(a, b, c, nrm)
		for k in 3:
			st_roof.set_normal(nrm)
			st_roof.set_color(roof_col)
			st_roof.set_uv(uvs[k])
			st_roof.add_vertex(f[k])
		emitted = true
	return emitted


## Two wall triangles for the sub-edge q0→q1, with metric UVs measured from the
## façade start: U = metres along the edge (courses restart per façade, no
## corner stretch), V = metres above the building base (the skirt goes
## negative, which the wall shader renders as foundation concrete).
static func _wall_quad(faces: Array, edge_start: Vector2, edge_dir: Vector2,
		q0: Vector2, q1: Vector2, skirt_y: float, h0: float, h1: float,
		base_y: float) -> void:
	var u0 := (q0 - edge_start).dot(edge_dir)
	var u1 := (q1 - edge_start).dot(edge_dir)
	var vb := skirt_y - base_y
	var b0 := Vector3(q0.x, skirt_y, q0.y)
	var b1 := Vector3(q1.x, skirt_y, q1.y)
	var t0 := Vector3(q0.x, h0, q0.y)
	var t1 := Vector3(q1.x, h1, q1.y)
	faces.append([b0, t0, t1,
		Vector2(u0, vb), Vector2(u0, h0 - base_y), Vector2(u1, h1 - base_y)])
	faces.append([b0, t1, b1,
		Vector2(u0, vb), Vector2(u1, h1 - base_y), Vector2(u1, vb)])


## Per-face planar UVs for a roof triangle: U runs along the eave (course
## direction), V is true metric distance up the slope — shingle courses stay
## level and square on any face. Flat faces use plan-space metres.
static func _roof_face_uvs(a: Vector3, b: Vector3, c: Vector3, nrm: Vector3) -> Array:
	if nrm.y > 0.99:
		return [Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)]
	var course := Vector3(nrm.z, 0.0, -nrm.x).normalized()
	var slope_dir := nrm.cross(course).normalized()
	return [
		Vector2(a.dot(course), a.dot(slope_dir)),
		Vector2(b.dot(course), b.dot(slope_dir)),
		Vector2(c.dot(course), c.dot(slope_dir)),
	]


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
