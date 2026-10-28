class_name BuildingBuilder
extends RefCounted

## Extrudes OSM building footprints onto the generated terrain with solid wall/roof
## materials (satellite drape on the ground already shows building roofs — draping
## extruded meshes too reads as doubled / floating copies).

const DEFAULT_HEIGHT_M := 8.0
const LEVELS_TO_METRES := 2.8
const MAX_HEIGHT_M := 200.0
const MIN_FOOTPRINT_AREA_M2 := 16.0
## Upper bound on footprints merged into the single ArrayMesh. Dense residential
## grids (e.g. Portland's ~10.7 k buildings inside the 3 km detail square) blew
## far past the old 800 cap, so ~93 % of houses silently never extruded — the
## crosshair still picked those un-built footprints and drew an amber roof-level
## outline over empty ground (the "floating highlight" + "most buildings missing"
## reports). 12 000 covers a full dense neighbourhood; when a mega-city exceeds
## it, build_buildings_node keeps the NEAREST N (distance-sorted) so the ring
## around the player stays solid instead of dropping an arbitrary array slice.
const MAX_BUILDINGS := 12000
## The foundation skirt embeds this far below the LOWEST corner sample so the
## downhill edge rests slightly into the ground instead of skimming DEM noise.
const FOUNDATION_SKIRT_M := 0.35
## Cap the auto-foundation height. The house body seats on the highest corner and
## the skirt runs down to the lowest; on a steep lot (or a lone DEM spike) that
## gap could balloon, so clamp it — beyond this the skirt just embeds at the cap.
const MAX_FOUNDATION_STEP_M := 6.0

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

## Procedural wall material modes — building_wall.gdshader branches on
## floor(UV2.x) of the wall surface. LAP (0) is the original lap-board path and
## must stay visually identical: meshes with no UV2 read (0,0) and land there.
enum WallMode { LAP = 0, TRAILER = 1, CORRUGATED = 2, PLYWOOD = 3, STUCCO = 4 }
## style["wall_mode"] value meaning "derive from tags/heuristics".
const WALL_MODE_AUTO := -1
## Footprints under this area read as trailer-town stock (mobile homes, plywood
## shacks) — the Bombay Beach case, where OSM has zero material tags and 336
## `building=house` ways are mostly ~40–60 m² trailers.
const SMALL_FOOTPRINT_M2 := 80.0

## Roof geo-UVs (UV2): every roof vertex carries the footprint's plan position
## normalized against the central "hyper" ortho square (TerrainLoader's
## HYPER_HALF_EXTENT references THIS const — one canonical value) so the roof
## shader can sample the real aerial photo geo-registered: UV2 (0,0) = NW corner
## of the patch (x=−500, z=−500; image row 0 = north, matching
## TerrainBuilder.build_mesh's drape UVs), (1,1) = SE. Buildings outside the
## patch get UV2 outside 0..1 and the shader falls back to procedural. Because
## UV2 is normalized against this fixed constant, meshes never rebuild when
## imagery arrives late.
const ORTHO_HALF_EXTENT_M := 500.0

## Facade elements (doors/windows): flat quads slightly proud of the wall.
const FACADE_PROUD_M := 0.04
const FACADE_FRAME_PROUD_M := 0.08
const FACADE_FRAME_W_M := 0.06
const DOOR_COLOR := Color(0.30, 0.19, 0.11)
const WINDOW_COLOR := Color(0.52, 0.64, 0.74)
const FACADE_SELECT_TINT := Color(1.0, 0.85, 0.3)
## Clear metre gap kept between adjacent facade elements on one wall.
const FACADE_LAYOUT_GAP_M := 0.5

## Per-batch build diagnostics — enabled only while build_buildings_node runs so
## build_single_building (the modal preview) never spams. Records why footprints
## are skipped so first-load "missing residential houses" is visible in the log.
static var _diag_enabled := false
static var _diag: Dictionary = {}


static func _diag_reset() -> void:
	_diag = {"pitched": 0, "flat": 0, "flat_fallback": 0, "tri_fail": 0,
		"too_few": 0, "no_geom": 0}


static func _bump(key: String) -> void:
	if _diag_enabled:
		_diag[key] = int(_diag.get(key, 0)) + 1


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


## Perpendicular distance from p to the infinite line through a→b.
static func _perp_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l := ab.length()
	if l < 1e-6:
		return p.distance_to(a)
	return absf((p - a).cross(ab)) / l


## Rescue pass for messy OSM footprints the ear-clipper rejects: drop
## consecutive duplicate vertices and near-collinear "spike" vertices (within
## 2 cm of the line through their neighbours). Returns the cleaned ring; the
## caller re-checks the size and winding.
static func _clean_poly(poly: PackedVector2Array) -> PackedVector2Array:
	var n := poly.size()
	if n < 3:
		return poly
	var dedup := PackedVector2Array()
	for i in n:
		var p := poly[i]
		if dedup.is_empty() or p.distance_squared_to(dedup[dedup.size() - 1]) > 1e-6:
			dedup.append(p)
	if dedup.size() >= 2 \
			and dedup[0].distance_squared_to(dedup[dedup.size() - 1]) < 1e-6:
		dedup.remove_at(dedup.size() - 1)
	if dedup.size() < 3:
		return dedup
	var out := PackedVector2Array()
	var m := dedup.size()
	for i in m:
		var prev := dedup[(i - 1 + m) % m]
		var cur := dedup[i]
		var nxt := dedup[(i + 1) % m]
		if _perp_dist(cur, prev, nxt) > 0.02:
			out.append(cur)
	return out if out.size() >= 3 else dedup


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


## Typical residential siding colours, hashed off the stable tag (deterministic
## per site) so a street reads as a varied-but-believable mix of painted houses:
## warm neutrals, greiges, sage/olive, colonial blue-grey, barn red, buttery
## yellow, slate, and clean whites.
const WALL_PALETTE: Array[Color] = [
	Color(0.86, 0.84, 0.79),  # warm white
	Color(0.78, 0.73, 0.62),  # tan / khaki
	Color(0.72, 0.72, 0.70),  # light grey
	Color(0.63, 0.66, 0.58),  # sage green
	Color(0.55, 0.60, 0.62),  # colonial blue-grey
	Color(0.70, 0.56, 0.48),  # muted terracotta
	Color(0.60, 0.36, 0.32),  # barn red
	Color(0.84, 0.78, 0.60),  # buttery yellow
	Color(0.50, 0.54, 0.52),  # slate green-grey
	Color(0.90, 0.89, 0.86)]  # off-white
## Shingle roofs default to near-black asphalt grey; OSM `roof:colour` overrides
## it. A tiny palette of dark grey shades keeps a street from looking
## rubber-stamped without drifting into the old brown/red mix that read as noise.
const DEFAULT_ROOF_COLOR := Color(0.15, 0.16, 0.18)  # near-black asphalt shingle
const ROOF_PALETTE: Array[Color] = [
	Color(0.15, 0.16, 0.18), Color(0.18, 0.19, 0.21),
	Color(0.12, 0.13, 0.14), Color(0.21, 0.22, 0.24)]


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
	# Normalize the footprint HERE (strip closing point, force CCW) so facade
	# element edge indices mean the same thing in the modal's picking math and
	# the mesh build (_append_footprint's own normalization becomes a no-op).
	if poly.size() >= 4 and poly[0].distance_squared_to(poly[poly.size() - 1]) < 0.01:
		poly = poly.slice(0, poly.size() - 1)
	if poly.size() >= 3:
		poly = _ensure_ccw(poly)
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
	var stable_tag := building_tag(poly)
	var colors := resolve_building_colors(tags, stable_tag)
	if style.has("wall_color"):
		colors["wall"] = style_color(style["wall_color"], colors["wall"])
	if style.has("roof_color"):
		colors["roof"] = style_color(style["roof_color"], colors["roof"])
	var wall_mode := resolve_wall_mode(tags, poly)
	if style.has("wall_mode") and int(style["wall_mode"]) >= 0:
		wall_mode = clampi(int(style["wall_mode"]), WallMode.LAP, WallMode.STUCCO)
	return {
		"poly": poly,
		"height_m": height_m,
		"roof": roof,
		"colors": colors,
		"base_offset_m": clampf(
			TerrainBuilder.dict_float(style, "base_y_offset_m", 0.0), -5.0, 5.0),
		"elements": style.get("elements", []),
		"wall_mode": wall_mode,
		"wall_seed": float(stable_tag.hash() % 1024) / 1024.0,
	}


## Wall material mode for a building. OSM material/type tags win; with no tags
## (rural US OSM rarely has them) footprint size does the sorting: sub-80 m²
## reads as trailer-town stock, full-size houses stay lap siding with occasional
## plywood/stucco, commercial boxes go corrugated/stucco. Deterministic per
## building (hashed from the stable centroid tag).
static func resolve_wall_mode(tags: Dictionary, poly: PackedVector2Array) -> int:
	var mat := str(tags.get("building:material", "")).to_lower()
	if mat.contains("metal") or mat.contains("corrugated") or mat.contains("tin") \
			or mat.contains("steel"):
		return WallMode.CORRUGATED
	if mat.contains("wood") or mat.contains("plywood") or mat.contains("timber"):
		return WallMode.PLYWOOD
	if mat.contains("concrete") or mat.contains("brick") or mat.contains("stucco") \
			or mat.contains("cement") or mat.contains("plaster") or mat.contains("masonry"):
		return WallMode.STUCCO
	var btype := str(tags.get("building", "")).to_lower()
	if btype == "static_caravan" or btype == "caravan":
		return WallMode.TRAILER
	var h := building_tag(poly).hash()
	if btype == "shed" or btype == "hut" or btype == "cabin":
		return WallMode.PLYWOOD if h % 3 != 0 else WallMode.CORRUGATED
	if FLAT_TYPES.has(btype):
		return WallMode.CORRUGATED if h % 2 == 0 else WallMode.STUCCO
	if footprint_area_m2(poly) < SMALL_FOOTPRINT_M2:
		var pick := h % 10
		if pick < 5:
			return WallMode.TRAILER
		if pick < 8:
			return WallMode.PLYWOOD
		return WallMode.CORRUGATED
	var pick2 := h % 10
	if pick2 < 7:
		return WallMode.LAP
	if pick2 < 9:
		return WallMode.PLYWOOD
	return WallMode.STUCCO


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
	# Siding: a varied typical-house colour with a gentle value jitter (keeps the
	# hue, just lightens/darkens per building so identical picks aren't twins).
	var wall: Color = WALL_PALETTE[h % WALL_PALETTE.size()]
	var wall_jitter := 0.92 + 0.16 * float(h % 97) / 97.0
	wall = Color(wall.r * wall_jitter, wall.g * wall_jitter, wall.b * wall_jitter)
	# Roof: dark grey asphalt shingle by default, with a barely-there shade spread
	# so a row of grey roofs still has life. OSM tags win over both.
	var roof: Color = ROOF_PALETTE[(h / 7) % ROOF_PALETTE.size()]
	var roof_jitter := 0.94 + 0.12 * float((h / 13) % 89) / 89.0
	roof = Color(roof.r * roof_jitter, roof.g * roof_jitter, roof.b * roof_jitter)
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
## Optional wall_tex (styled hero buildings): a real/AI facade strip tiled in
## metric wall UVs — wall_tex_size_m = the metres one tile covers.
static func make_wall_material(wall_tex: Texture2D = null,
		wall_tex_size_m: Vector2 = Vector2(4.0, 3.0)) -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = WALL_SHADER
	if wall_tex != null:
		mat.set_shader_parameter("use_wall_tex", true)
		mat.set_shader_parameter("wall_tex", wall_tex)
		mat.set_shader_parameter("wall_tex_size_m", wall_tex_size_m)
	return mat


## Procedural shingle/membrane roof; COLOR.a picks the branch per building.
static func make_roof_material() -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = ROOF_SHADER
	return mat


## Roof UV2 is baked at build time normalized against the FIXED ORTHO_HALF_EXTENT_M
## square (see _roof_geo_uv). Whatever ortho texture is actually bound at material
## time may cover a DIFFERENT half-extent (the quality-tier hyper patch, or the
## 3 km detail drape as a fallback) — this ratio rescales UV2 so the shader
## samples the correct footprint regardless of which texture/extent won.
static func roof_ortho_uv_scale(ortho_half_extent_m: float) -> float:
	if ortho_half_extent_m <= 0.0:
		return 1.0
	return ORTHO_HALF_EXTENT_M / ortho_half_extent_m


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
	# When the set exceeds the merge budget, keep the footprints nearest the map
	# centre (where the player spawns) so the surrounding blocks stay solid rather
	# than dropping a scattered array slice. Cheap enough to skip when under budget.
	var ordered := buildings
	if buildings.size() > MAX_BUILDINGS:
		ordered = _sort_by_distance_to_centre(buildings)
	_diag_enabled = true
	_diag_reset()
	var added := 0
	for item in ordered:
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
				detail_elev, detail_cols, detail_rows, detail_foot_extent,
				0.0, int(params["wall_mode"]), float(params["wall_seed"])):
			added += 1
	if _diag_enabled:
		print("BuildingBuilder: extruded %d of %d (pitched %d, flat %d, flat-fallback %d); skipped tri_fail=%d too_few=%d no_geom=%d" % [
			added, buildings.size(), int(_diag["pitched"]), int(_diag["flat"]),
			int(_diag["flat_fallback"]), int(_diag["tri_fail"]),
			int(_diag["too_few"]), int(_diag["no_geom"])])
		_diag_enabled = false
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


## Order building records by squared distance of their centroid to the map centre
## (0,0), nearest first. Used only when the set overflows MAX_BUILDINGS so the cap
## keeps the ring around the player instead of an arbitrary OSM-id slice.
static func _sort_by_distance_to_centre(buildings: Array) -> Array:
	var out := buildings.duplicate()
	out.sort_custom(func(a: Variant, b: Variant) -> bool:
		return _record_centre_dist2(a) < _record_centre_dist2(b))
	return out


static func _record_centre_dist2(item: Variant) -> float:
	if not (item is Dictionary):
		return INF
	var pts: Variant = (item as Dictionary).get("points", PackedVector2Array())
	if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 1:
		return INF
	var poly: PackedVector2Array = pts
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= float(poly.size())
	return c.length_squared()


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
			float(params["base_offset_m"]), int(params["wall_mode"]),
			float(params["wall_seed"])):
		return null
	var mi := MeshInstance3D.new()
	mi.name = "BuildingMesh"
	var mesh: ArrayMesh = st_walls.commit()
	mesh = st_roof.commit(mesh)

	# Facade elements (doors/windows) ride on a third surface with their own
	# flat-color material — only styled buildings pay for it.
	var elements: Array = params["elements"] if params["elements"] is Array else []
	var has_facade := false
	if not elements.is_empty():
		var base_y := footprint_base_y(poly, elev, res, height_extent_m, center_elev,
			detail_elev, detail_cols, detail_rows, detail_foot_extent) \
			+ float(params["base_offset_m"])
		var selected := int(TerrainBuilder.dict_float(style, "selected_element", -1.0))
		var st_fac := SurfaceTool.new()
		st_fac.begin(Mesh.PRIMITIVE_TRIANGLES)
		for e_i in elements.size():
			if elements[e_i] is Dictionary:
				if _append_facade_element(st_fac, poly, base_y,
						float(params["height_m"]), elements[e_i], e_i == selected):
					has_facade = true
		if has_facade:
			mesh = st_fac.commit(mesh)

	# Assign every surface override AFTER mi.mesh so the internal override array
	# is sized to the surface count first — setting surface 2 before the mesh
	# exists silently drops the facade material and doors/windows render bare.
	mi.mesh = mesh
	mi.set_surface_override_material(0, make_wall_material())
	mi.set_surface_override_material(1, make_roof_material())
	if has_facade:
		mi.set_surface_override_material(2, make_facade_material())
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Lowest corner ground sample — the Y the whole building seats at (before the
## style layer's base offset). Shared by walls/roof and facade elements.
## Lowest and highest ground samples under the footprint corners, returned as
## [low, high]. The house body seats on `high` (so no corner buries into the
## hill) and the foundation skirt reaches down to `low`, filling the downhill gap.
static func footprint_ground_extents(poly: PackedVector2Array, elev: PackedFloat32Array,
		res: int, height_extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array = PackedFloat32Array(), detail_cols: int = 0,
		detail_rows: int = 0, detail_extent_m: float = 0.0) -> Array:
	var lo := INF
	var hi := -INF
	for p in poly:
		var y := _sample_ground_y(p.x, p.y, elev, res, height_extent_m,
			center_elev, detail_elev, detail_cols, detail_rows, detail_extent_m)
		lo = minf(lo, y)
		hi = maxf(hi, y)
	if lo == INF:
		return [0.0, 0.0]
	return [lo, hi]


## The Y the house body seats at — the HIGHEST corner ground sample, so eaves and
## floors clear the uphill terrain and a foundation fills the downhill gap. Shared
## by the wall/roof build and facade-element placement so they stay aligned.
static func footprint_base_y(poly: PackedVector2Array, elev: PackedFloat32Array,
		res: int, height_extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array = PackedFloat32Array(), detail_cols: int = 0,
		detail_rows: int = 0, detail_extent_m: float = 0.0) -> float:
	return footprint_ground_extents(poly, elev, res, height_extent_m, center_elev,
		detail_elev, detail_cols, detail_rows, detail_extent_m)[1]


## Ray-pick a wall face (pure math — the Building Builder studio has no
## physics). poly must be the resolve_building_params-normalized footprint.
## Returns {valid, edge, u_m (metres along edge), v_m (metres above base)}.
static func pick_wall_point(poly: PackedVector2Array, base_y: float, height_m: float,
		origin: Vector3, ray_dir: Vector3) -> Dictionary:
	var n := poly.size()
	var best := {"valid": false}
	var best_t := INF
	for i in n:
		var p_i := poly[i]
		var p_j := poly[(i + 1) % n]
		var edge_len := p_i.distance_to(p_j)
		if edge_len < 0.05:
			continue
		var dir2 := (p_j - p_i) / edge_len
		var out := Vector2(dir2.y, -dir2.x)
		var nrm := Vector3(out.x, 0.0, out.y)
		var denom := ray_dir.dot(nrm)
		if absf(denom) < 1e-6:
			continue
		var t := (Vector3(p_i.x, base_y, p_i.y) - origin).dot(nrm) / denom
		if t <= 0.0 or t >= best_t:
			continue
		var hit := origin + ray_dir * t
		var u := (Vector2(hit.x, hit.z) - p_i).dot(dir2)
		var v := hit.y - base_y
		if u < 0.0 or u > edge_len or v < 0.0 or v > height_m:
			continue
		best = {"valid": true, "edge": i, "u_m": u, "v_m": v}
		best_t = t
	return best


## Auto-arrange every facade element that shares one wall edge: the (first) door
## sits dead-centre and all other elements flank it symmetrically, so 1 door +
## 2 windows reads as window–door–window. With no door, windows are centred as an
## even symmetric group. Mutates each element's `u_m` in place (sizes/heights
## untouched); this replaces the old free-form "Along m" nudge with predictable,
## centred placement. `poly` must be the resolve_building_params-normalized ring.
static func layout_elements_on_edge(poly: PackedVector2Array, edge: int,
		elements: Array) -> void:
	var n := poly.size()
	if edge < 0 or edge >= n:
		return
	var edge_len := poly[edge].distance_to(poly[(edge + 1) % n])
	if edge_len <= 0.0:
		return
	var on_edge: Array = []
	for e in elements:
		if e is Dictionary and int((e as Dictionary).get("edge", -1)) == edge:
			on_edge.append(e)
	if on_edge.is_empty():
		return
	var center := edge_len * 0.5
	var door: Dictionary = {}
	var flankers: Array = []
	for e in on_edge:
		if door.is_empty() and str((e as Dictionary).get("kind", "window")) == "door":
			door = e
		else:
			flankers.append(e)
	if not door.is_empty():
		# Door pinned to centre; flankers grow outward, alternating right/left.
		door["u_m"] = center
		var right_b := center + _elem_half_w(door, edge_len)
		var left_b := center - _elem_half_w(door, edge_len)
		for i in flankers.size():
			var el: Dictionary = flankers[i]
			var hw := _elem_half_w(el, edge_len)
			if i % 2 == 0:
				right_b += FACADE_LAYOUT_GAP_M + hw
				el["u_m"] = right_b
				right_b += hw
			else:
				left_b -= FACADE_LAYOUT_GAP_M + hw
				el["u_m"] = left_b
				left_b -= hw
	else:
		# No door: centre the windows as one symmetric, evenly-spaced group.
		var total := 0.0
		for e in flankers:
			total += 2.0 * _elem_half_w(e, edge_len)
		total += FACADE_LAYOUT_GAP_M * float(maxi(flankers.size() - 1, 0))
		var cursor := center - total * 0.5
		for e in flankers:
			var hw := _elem_half_w(e, edge_len)
			cursor += hw
			(e as Dictionary)["u_m"] = cursor
			cursor += hw + FACADE_LAYOUT_GAP_M
	# Final clamp so nothing spills past the wall corners.
	for e in on_edge:
		var hw := _elem_half_w(e, edge_len)
		(e as Dictionary)["u_m"] = clampf(
			float((e as Dictionary).get("u_m", center)), hw, maxf(edge_len - hw, hw))


static func _elem_half_w(elem: Dictionary, edge_len: float) -> float:
	return clampf(TerrainBuilder.dict_float(elem, "w_m", 1.2), 0.2,
		maxf(edge_len - 0.1, 0.2)) * 0.5


static func _append_facade_element(st: SurfaceTool, poly: PackedVector2Array,
		base_y: float, height_m: float, elem: Dictionary, selected: bool) -> bool:
	var n := poly.size()
	var edge := int(TerrainBuilder.dict_float(elem, "edge", -1.0))
	if edge < 0 or edge >= n:
		return false
	var p_i := poly[edge]
	var p_j := poly[(edge + 1) % n]
	var edge_len := p_i.distance_to(p_j)
	if edge_len < 0.5:
		return false
	var dir := (p_j - p_i) / edge_len
	var out := Vector2(dir.y, -dir.x)  # outward for the CCW-normalized footprint
	var kind := str(elem.get("kind", "window"))
	# Clamp the element inside its wall rectangle.
	var w := clampf(TerrainBuilder.dict_float(elem, "w_m", 1.2), 0.2,
		maxf(edge_len - 0.1, 0.2))
	var h := clampf(TerrainBuilder.dict_float(elem, "h_m", 1.4), 0.2, height_m)
	var u := clampf(TerrainBuilder.dict_float(elem, "u_m", edge_len * 0.5),
		w * 0.5, edge_len - w * 0.5)
	var v := clampf(TerrainBuilder.dict_float(elem, "v_m", 0.0), 0.0, height_m - h)
	var col := DOOR_COLOR if kind == "door" else WINDOW_COLOR
	var frame_col := Color(0.85, 0.82, 0.78) if kind == "door" else Color(0.9, 0.9, 0.88)
	if selected:
		col = col.lerp(FACADE_SELECT_TINT, 0.45)
		frame_col = frame_col.lerp(FACADE_SELECT_TINT, 0.45)
	var nrm := Vector3(out.x, 0.0, out.y)

	# Panel 4 cm proud; frame strips 8 cm proud (doors skip the sill).
	_facade_quad(st, p_i, dir, out, u - w * 0.5, u + w * 0.5,
		base_y + v, base_y + v + h, FACADE_PROUD_M, col, nrm)
	var fw := FACADE_FRAME_W_M
	_facade_quad(st, p_i, dir, out, u - w * 0.5 - fw, u + w * 0.5 + fw,
		base_y + v + h, base_y + v + h + fw, FACADE_FRAME_PROUD_M, frame_col, nrm)
	if kind != "door":
		_facade_quad(st, p_i, dir, out, u - w * 0.5 - fw, u + w * 0.5 + fw,
			base_y + v - fw, base_y + v, FACADE_FRAME_PROUD_M, frame_col, nrm)
	_facade_quad(st, p_i, dir, out, u - w * 0.5 - fw, u - w * 0.5,
		base_y + v, base_y + v + h, FACADE_FRAME_PROUD_M, frame_col, nrm)
	_facade_quad(st, p_i, dir, out, u + w * 0.5, u + w * 0.5 + fw,
		base_y + v, base_y + v + h, FACADE_FRAME_PROUD_M, frame_col, nrm)
	return true


static func _facade_quad(st: SurfaceTool, p_i: Vector2, dir: Vector2, out: Vector2,
		u0: float, u1: float, y0: float, y1: float, proud: float,
		col: Color, nrm: Vector3) -> void:
	if u1 <= u0 or y1 <= y0:
		return
	var o := out * proud
	var a2 := p_i + dir * u0 + o
	var b2 := p_i + dir * u1 + o
	var a0 := Vector3(a2.x, y0, a2.y)
	var a1 := Vector3(a2.x, y1, a2.y)
	var b0 := Vector3(b2.x, y0, b2.y)
	var b1 := Vector3(b2.x, y1, b2.y)
	for v in [a0, a1, b1, a0, b1, b0]:
		st.set_normal(nrm)
		st.set_color(col)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(v)


static func make_facade_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.4
	mat.metallic = 0.1
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func _append_footprint(st_walls: SurfaceTool, st_roof: SurfaceTool,
		poly: PackedVector2Array, height_m: float, roof: Dictionary, colors: Dictionary,
		elev: PackedFloat32Array, res: int,
		height_extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array = PackedFloat32Array(),
		detail_cols: int = 0, detail_rows: int = 0, detail_extent_m: float = 0.0,
		base_offset_m: float = 0.0, wall_mode: int = WallMode.LAP,
		wall_seed: float = 0.0) -> bool:
	var n := poly.size()
	if n < 3:
		_bump("too_few")
		return false
	if poly[0].distance_squared_to(poly[n - 1]) < 0.01:
		poly = poly.slice(0, n - 1)
		n = poly.size()
	if n < 3:
		_bump("too_few")
		return false
	poly = _ensure_ccw(poly)

	# Triangulate; if the ear-clipper rejects the raw OSM way, retry on a cleaned
	# footprint (dedupe + drop collinear spikes). This rescues the many messy
	# residential ways that would otherwise vanish entirely on first load.
	var tri_indices := Geometry2D.triangulate_polygon(poly)
	if tri_indices.is_empty():
		var cleaned := _ensure_ccw(_clean_poly(poly))
		if cleaned.size() >= 3:
			var tri2 := Geometry2D.triangulate_polygon(cleaned)
			if not tri2.is_empty():
				poly = cleaned
				n = poly.size()
				tri_indices = tri2
	if tri_indices.is_empty():
		_bump("tri_fail")
		return false

	# Seat the house body on the HIGHEST corner sample so eaves/floors clear the
	# uphill terrain (no more sunk-into-the-hill look), then drop a foundation
	# skirt to the LOWEST corner so the downhill side rests on a plinth instead of
	# floating — the wall shader paints everything below the base line as concrete.
	# base_offset_m is the user's vertical-placement nudge from the style layer.
	var extents := footprint_ground_extents(poly, elev, res, height_extent_m,
		center_elev, detail_elev, detail_cols, detail_rows, detail_extent_m)
	var foot_low: float = extents[0]
	var foot_high: float = extents[1]
	var base_y := foot_high + base_offset_m
	var skirt_y := foot_low - FOUNDATION_SKIRT_M
	# Clamp the auto-foundation so a steep lot or a lone DEM spike can't launch the
	# house onto an absurd plinth (the skirt just embeds at the cap instead).
	if base_y - skirt_y > MAX_FOUNDATION_STEP_M:
		skirt_y = base_y - MAX_FOUNDATION_STEP_M

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
		var floor_v := skirt_y - base_y
		wall_faces.append([bottom_p[f0], bottom_p[f1], bottom_p[f2],
			Vector2(poly[f0].x, floor_v),
			Vector2(poly[f1].x, floor_v),
			Vector2(poly[f2].x, floor_v)])

	# Pitched roofs take the crease-split ridge path; flat roofs (explicit tag,
	# unknown shape, degenerate-footprint guardrail) get walls straight up + a
	# level cap. When the ridge path collapses to zero valid triangles (slivers,
	# self-intersections), fall back to the flat cap so the house never vanishes.
	var used_flat := frame.is_empty()
	if not used_flat:
		var pitched_roof: Array = []
		_emit_pitched_roof(pitched_roof, poly, tri_indices, frame)
		if _count_valid_tris(pitched_roof) == 0:
			used_flat = true
			_bump("flat_fallback")
		else:
			roof_faces.append_array(pitched_roof)
			_emit_pitched_walls(wall_faces, poly, frame, skirt_y, base_y)
	if used_flat:
		_emit_flat_walls_roof(wall_faces, roof_faces, poly, tri_indices,
			skirt_y, top_y, base_y)

	var wall_col: Color = colors.get("wall", Color(0.74, 0.71, 0.67))
	wall_col.a = 1.0
	var roof_col: Color = colors.get("roof", Color(0.35, 0.33, 0.32))
	# COLOR.a flags the roof shader per building: 1 = pitched (shingle courses),
	# 0 = flat (membrane/gravel).
	roof_col.a = 0.0 if used_flat else 1.0

	# UV2 on walls carries (material mode + 0.5, per-building weathering seed)
	# for building_wall.gdshader — see WallMode.
	var wall_uv2 := Vector2(float(wall_mode) + 0.5, wall_seed)
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
			st_walls.set_uv2(wall_uv2)
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
			st_roof.set_uv2(_roof_geo_uv(f[k]))
			st_roof.add_vertex(f[k])
		emitted = true
	if emitted:
		_bump("flat" if used_flat else "pitched")
	else:
		_bump("no_geom")
	return emitted


## Walls straight up to a level roof cap, plus the flat roof triangles. Shared
## by explicitly-flat buildings and the pitched-roof fallback so a house with
## broken ridge geometry still renders a solid (if flat) roof instead of a hole.
static func _emit_flat_walls_roof(wall_faces: Array, roof_faces: Array,
		poly: PackedVector2Array, tri_indices: PackedInt32Array,
		skirt_y: float, top_y: float, base_y: float) -> void:
	var n := poly.size()
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


## Pitched walls (incl. triangular gable-end fills): each boundary edge is split
## where a roof crease crosses it, then extruded up to the roof height field.
## Sharing _roof_height_at with the roof surface keeps wall tops watertight.
static func _emit_pitched_walls(wall_faces: Array, poly: PackedVector2Array,
		frame: Dictionary, skirt_y: float, base_y: float) -> void:
	var n := poly.size()
	var creases := _crease_lines(frame)
	for i in n:
		var j := (i + 1) % n
		var dir := (poly[j] - poly[i]).normalized()
		var edge_pts := _split_edge_at_creases(poly[i], poly[j], frame, creases)
		for k in edge_pts.size() - 1:
			var q0: Vector2 = edge_pts[k]
			var q1: Vector2 = edge_pts[k + 1]
			_wall_quad(wall_faces, poly[i], dir, q0, q1, skirt_y,
				_roof_height_at(q0, frame), _roof_height_at(q1, frame), base_y)


## Pitched roof faces: footprint triangulation split along every crease line so
## each resulting triangle lies inside one planar roof face, then lifted onto the
## ridge height field. Appends [a, b, c] Vector3 triples to roof_faces.
static func _emit_pitched_roof(roof_faces: Array, poly: PackedVector2Array,
		tri_indices: PackedInt32Array, frame: Dictionary) -> void:
	var creases := _crease_lines(frame)
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


## Count roof triangles that survive the degenerate-normal filter, so the
## pitched branch knows whether it produced any real geometry before committing.
static func _count_valid_tris(faces: Array) -> int:
	var c := 0
	for f in faces:
		var nrm: Vector3 = (f[1] - f[0]).cross(f[2] - f[0])
		if nrm.length_squared() >= 1e-10:
			c += 1
	return c


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


## Geo-registered UV2 for a roof vertex: plan position normalized against the
## central ortho square (see ORTHO_HALF_EXTENT_M). Pure plan projection — the
## aerial photo is orthographic, so pitched faces sample the same footprint
## pixels the satellite saw from above.
static func _roof_geo_uv(p: Vector3) -> Vector2:
	var span := ORTHO_HALF_EXTENT_M * 2.0
	return Vector2(p.x / span + 0.5, p.z / span + 0.5)


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


## The roof's surface at plan point p, for a building as resolve_building_params
## gives it (poly, roof, height_m) seated at base_y: {y, normal, flat}. The
## same frame and height field the mesh is built from (_roof_frame,
## _roof_height_at), the normal from its slope a few centimetres either side
## (each roof face is a plane between creases). A flat roof is the top.
static func roof_plane_at(poly: PackedVector2Array, roof: Dictionary, height_m: float, base_y: float,
		p: Vector2) -> Dictionary:
	var pl := poly
	if pl.size() >= 4 and pl[0].distance_squared_to(pl[pl.size() - 1]) < 0.01:
		pl = pl.slice(0, pl.size() - 1)
	if pl.size() < 3:
		return {}
	pl = _ensure_ccw(pl)
	var wall_h := _wall_height_m(height_m, roof, pl)
	var frame := _roof_frame(pl, roof, base_y, wall_h, height_m)
	if frame.is_empty():
		return {"y": base_y + height_m, "normal": Vector3.UP, "flat": true}
	var e := 0.03
	var y := _roof_height_at(p, frame)
	var dx := (_roof_height_at(p + Vector2(e, 0), frame) - _roof_height_at(p - Vector2(e, 0), frame)) / (2.0 * e)
	var dz := (_roof_height_at(p + Vector2(0, e), frame) - _roof_height_at(p - Vector2(0, e), frame)) / (2.0 * e)
	return {"y": y, "normal": Vector3(-dx, 1.0, -dz).normalized(), "flat": false}


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
