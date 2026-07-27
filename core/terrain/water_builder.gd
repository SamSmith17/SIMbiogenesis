class_name WaterBuilder
extends RefCounted

## Builds flat OSM water bodies, each sat at a single level matched to its banks.
## Ponds and lakes get a local ReflectionProbe so the water shader can reflect
## sky and nearby trees (Godot 4 uses ReflectionProbe for this — not LightProbe3D).

const WATER_SHADER := preload("res://core/terrain/terrain_water.gdshader")
const RIVER_SHADER := preload("res://core/terrain/terrain_river.gdshader")
const MIN_AREA_M2 := 80.0
const MAX_BODIES := 200
const MIN_PROBE_AREA_M2 := 250.0
## Each probe renders a live cubemap — expensive, and the engine's reflection
## atlas only holds 64 total. Keep this well under that ceiling (transient
## overlaps during a rebuild, plus any non-water probes, must still fit) and
## reserve the slots for the biggest lakes. 28 was both a crash risk on
## water-dense sites and a major load-time FPS sink.
const MAX_REFLECTION_PROBES := 12
const PROBE_MARGIN_M := 24.0
const PROBE_HEIGHT_M := 32.0
const PROBE_MIN_EXTENT_M := 8.0
const PROBE_MAX_ASPECT := 5.5
## Layer 20 — water renders here so reflection probes can omit it (capturing
## semi-transparent water into the cubemap washes out box faces as white tiles).
const WATER_RENDER_LAYER := 1 << 19
const PROBE_CAPTURE_LAYERS := (1 << 20) - 1
## Skip narrow waterway ribbons — probes are sized for lake-like footprints.
const WATERWAY_KINDS := ["river", "stream", "canal", "ditch", "drain"]
## Flowing water: draped per-vertex onto the terrain (follows downhill contour) and
## rendered with the directional river shader. Everything else (lake/pond/reservoir/
## wetland/bay) is still water — a single flat level, which is physically correct.
const FLOWING_KINDS := ["river", "stream", "canal", "ditch", "drain", "riverbank"]
## A still water body lies on a flat plane (real water is level). The plane height is
## a low percentile of the shoreline terrain so it sits in the basin without floating
## above the lowest bank; this raises it just clear of that level to avoid z-fight.
const SURFACE_OFFSET_M := 0.06
## Flowing water hugs the terrain; lift it a hair so it reads as water, not a decal.
const FLOW_SURFACE_OFFSET_M := 0.12
## Percentile of boundary terrain heights used as the water level (0 = lowest bank).
const LEVEL_PERCENTILE := 0.18
## Blend band (m) across the detail↔base DEM seam so draped ribbons don't step where
## the two grids disagree. Matches the coarse-centre feather used by the mesh patch.
const DEM_SEAM_FEATHER_M := 40.0
## Finite-difference spacing (m) for the terrain gradient that drives flow direction.
const FLOW_GRADIENT_STEP_M := 7.0


static func _is_flowing(kind: String) -> bool:
	return kind in FLOWING_KINDS


static func build_water_node(waters: Array, elev: PackedFloat32Array, res: int,
		extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array = PackedFloat32Array(),
		detail_res: int = 0, detail_extent_m: float = 0.0,
		seam_feather_m: float = 0.0) -> Node3D:
	var feather := seam_feather_m if seam_feather_m > 0.0 else DEM_SEAM_FEATHER_M
	var still_st := SurfaceTool.new()
	still_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var flow_st := SurfaceTool.new()
	flow_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var added := 0
	var still_vtx := 0
	var flow_vtx := 0
	var probe_specs: Array = []
	for item in waters:
		if added >= MAX_BODIES:
			break
		if not (item is Dictionary):
			continue
		var poly: PackedVector2Array = item.get("points", PackedVector2Array())
		if poly.size() < 3:
			continue
		if BuildingBuilder.footprint_area_m2(poly) < MIN_AREA_M2:
			continue
		var kind := str(item.get("kind", "water"))
		if _is_flowing(kind):
			var centerline: PackedVector2Array = item.get("centerline", PackedVector2Array())
			var half_w := float(item.get("half_width", 0.0))
			var flowed := _append_flowing_polygon(flow_st, poly, flow_vtx, elev, res,
				extent_m, center_elev, detail_elev, detail_res, detail_extent_m, feather,
				centerline, half_w)
			if flowed.is_empty():
				continue
			flow_vtx = int(flowed["next_vtx"])
			added += 1
			continue
		var level_override := TerrainBuilder.variant_to_float(item.get("level_m", NAN), NAN)
		var body := _append_water_polygon(still_st, poly, still_vtx, elev, res,
			extent_m, center_elev, detail_elev, detail_res, detail_extent_m, feather,
			level_override)
		if body.is_empty():
			continue
		still_vtx = int(body["next_vtx"])
		added += 1
		var is_user := bool(item.get("user", false))
		if _wants_reflection_probe(poly, kind, is_user):
			probe_specs.append(body["probe"])
	if added == 0:
		return null
	var root := Node3D.new()
	root.name = "Water"
	if still_vtx > 0:
		var mi := MeshInstance3D.new()
		mi.name = "WaterSurface"
		mi.mesh = still_st.commit()
		mi.material_override = _make_water_material()
		mi.layers = WATER_RENDER_LAYER
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	if flow_vtx > 0:
		flow_st.generate_normals()
		var rmi := MeshInstance3D.new()
		rmi.name = "RiverSurface"
		rmi.mesh = flow_st.commit()
		rmi.material_override = _make_river_material()
		rmi.layers = WATER_RENDER_LAYER
		rmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(rmi)
	_attach_reflection_probes(root, probe_specs)
	return root


## Re-capture all water reflection probes (call after vegetation finishes loading).
static func refresh_reflection_probes(water_root: Node3D) -> void:
	if water_root == null:
		return
	var probes := water_root.get_node_or_null("WaterProbes")
	if probes == null:
		return
	for child in probes.get_children():
		if child is ReflectionProbe:
			_request_reflection_probe_update(child as ReflectionProbe)


## Godot 4.6 UPDATE_ONCE probes re-capture only when their transform changes
## (no queue_update/deferred_update API yet). A sub-centimetre nudge is invisible
## but forces a fresh cubemap after trees/terrain finish loading.
static func _request_reflection_probe_update(probe: ReflectionProbe) -> void:
	if probe == null:
		return
	if probe.has_method("queue_update"):
		probe.call("queue_update")
		return
	var step := 0.002
	var n := int(probe.get_meta("_refresh_nudge", 0)) + 1
	probe.set_meta("_refresh_nudge", n)
	probe.position += Vector3(step * float(n), 0.0, 0.0)


static func _wants_reflection_probe(poly: PackedVector2Array, kind: String,
		force_user: bool = false) -> bool:
	if kind in WATERWAY_KINDS:
		return false
	# Player-sculpted ponds always get a probe so they match OSM lake look.
	if force_user:
		return BuildingBuilder.footprint_area_m2(poly) >= MIN_AREA_M2
	if BuildingBuilder.footprint_area_m2(poly) < MIN_PROBE_AREA_M2:
		return false
	var aabb := _poly_aabb(poly)
	var short_side := maxf(minf(aabb["width"], aabb["depth"]), 1.0)
	var long_side := maxf(aabb["width"], aabb["depth"])
	if long_side / short_side > PROBE_MAX_ASPECT:
		return false
	return true


static func _attach_reflection_probes(root: Node3D, specs: Array) -> void:
	if specs.is_empty():
		return
	var probes_root := Node3D.new()
	probes_root.name = "WaterProbes"
	root.add_child(probes_root)
	# Reserve the limited probe budget for the largest bodies (biggest visual
	# payoff) rather than whichever happened to come first in OSM order.
	var ordered := specs.duplicate()
	ordered.sort_custom(func(a, b) -> bool: return _probe_footprint(a) > _probe_footprint(b))
	var count := 0
	for spec_v in ordered:
		if count >= MAX_REFLECTION_PROBES:
			break
		if not (spec_v is Dictionary):
			continue
		var spec: Dictionary = spec_v
		var probe := _make_reflection_probe(spec)
		probes_root.add_child(probe)
		count += 1


## Footprint area (m²) of a probe spec, used to rank probes when over budget.
static func _probe_footprint(spec_v) -> float:
	if not (spec_v is Dictionary):
		return 0.0
	var size: Vector3 = (spec_v as Dictionary).get("size", Vector3.ZERO)
	return size.x * size.z


static func _make_reflection_probe(spec: Dictionary) -> ReflectionProbe:
	var center: Vector3 = spec.get("center", Vector3.ZERO)
	var size: Vector3 = spec.get("size", Vector3(16.0, PROBE_HEIGHT_M, 16.0))
	var horiz := maxf(size.x, size.z)
	var probe := ReflectionProbe.new()
	probe.name = "LakeReflection"
	probe.position = center + Vector3(0.0, size.y * 0.5, 0.0)
	probe.size = size
	# Box projection parallax-maps to the probe AABB; at grazing angles the box
	# faces read as bright white rectangles around each lake from drone view.
	probe.box_projection = false
	probe.enable_shadows = false
	probe.interior = false
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.intensity = 1.0
	probe.max_distance = horiz * 0.75
	probe.origin_offset = Vector3(0.0, -size.y * 0.15, 0.0)
	probe.blend_distance = clampf(horiz * 0.42, 18.0, 96.0)
	probe.cull_mask = PROBE_CAPTURE_LAYERS & ~WATER_RENDER_LAYER
	return probe


static func _probe_spec_for_poly(poly: PackedVector2Array, level: float) -> Dictionary:
	var aabb := _poly_aabb(poly)
	var width := maxf(float(aabb["width"]) + PROBE_MARGIN_M * 2.0, PROBE_MIN_EXTENT_M)
	var depth := maxf(float(aabb["depth"]) + PROBE_MARGIN_M * 2.0, PROBE_MIN_EXTENT_M)
	return {
		"center": Vector3(float(aabb["cx"]), level, float(aabb["cz"])),
		"size": Vector3(width, PROBE_HEIGHT_M, depth),
	}


static func _poly_aabb(poly: PackedVector2Array) -> Dictionary:
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_z := poly[0].y
	var max_z := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	return {
		"cx": (min_x + max_x) * 0.5,
		"cz": (min_z + max_z) * 0.5,
		"width": max_x - min_x,
		"depth": max_z - min_z,
	}


## Appends one flat water body. Returns a result dict with `next_vtx` and optional
## `probe` spec, or {} when the polygon was rejected.
static func _append_water_polygon(st: SurfaceTool, poly: PackedVector2Array,
		vtx_base: int, elev: PackedFloat32Array, res: int, extent_m: float,
		center_elev: float, detail_elev: PackedFloat32Array, detail_res: int,
		detail_extent_m: float, seam_feather_m: float = DEM_SEAM_FEATHER_M,
		level_override: float = NAN) -> Dictionary:
	var n := poly.size()
	if n >= 3 and poly[0].distance_squared_to(poly[n - 1]) < 0.01:
		poly = poly.slice(0, n - 1)
		n = poly.size()
	if n < 3:
		return {}
	var tris := Geometry2D.triangulate_polygon(poly)
	if tris.is_empty():
		return {}
	var level := 0.0
	if not is_nan(level_override):
		# Caller-supplied surface level (sculpted ponds tie it to the depth slider).
		level = level_override + SURFACE_OFFSET_M
	else:
		var bank_heights := PackedFloat32Array()
		bank_heights.resize(n)
		for i in n:
			bank_heights[i] = _ground_y(poly[i].x, poly[i].y, elev, res, extent_m,
				center_elev, detail_elev, detail_res, detail_extent_m, seam_feather_m)
		level = _water_level(bank_heights) + SURFACE_OFFSET_M
	for i in n:
		var p := poly[i]
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(p.x, p.y))
		st.add_vertex(Vector3(p.x, level, p.y))
	for t in range(0, tris.size(), 3):
		st.add_index(vtx_base + tris[t])
		st.add_index(vtx_base + tris[t + 1])
		st.add_index(vtx_base + tris[t + 2])
	return {
		"next_vtx": vtx_base + n,
		"probe": _probe_spec_for_poly(poly, level),
	}


## Appends one flowing water body (river/stream/…). Unlike still water this drapes
## every vertex onto the terrain surface (+ a small lift) so the ribbon follows the
## downhill contour instead of floating as one flat plane. Vertex COLOR encodes the
## local downhill flow direction (rg) and slope-scaled speed (b) for the river shader.
static func _append_flowing_polygon(st: SurfaceTool, poly: PackedVector2Array,
		vtx_base: int, elev: PackedFloat32Array, res: int, extent_m: float,
		center_elev: float, detail_elev: PackedFloat32Array, detail_res: int,
		detail_extent_m: float, seam_feather_m: float = DEM_SEAM_FEATHER_M,
		centerline: PackedVector2Array = PackedVector2Array(),
		half_w: float = 0.0) -> Dictionary:
	var n := poly.size()
	if n >= 3 and poly[0].distance_squared_to(poly[n - 1]) < 0.01:
		poly = poly.slice(0, n - 1)
		n = poly.size()
	if n < 3:
		return {}
	var tris := Geometry2D.triangulate_polygon(poly)
	if tris.is_empty():
		return {}
	for i in n:
		var p := poly[i]
		var gy := _ground_y(p.x, p.y, elev, res, extent_m, center_elev,
			detail_elev, detail_res, detail_extent_m, seam_feather_m)
		var flow := _flow_vector(p.x, p.y, elev, res, extent_m, center_elev,
			detail_elev, detail_res, detail_extent_m, seam_feather_m)
		st.set_color(Color(
			flow.x * 0.5 + 0.5,   # downhill dir X  (decoded to −1..1 in shader)
			flow.y * 0.5 + 0.5,   # downhill dir Z
			flow.z,               # slope-scaled flow speed 0..1
			1.0))
		st.set_uv(Vector2(p.x, p.y))
		st.set_uv2(_ribbon_lateral_uv2(p, centerline, half_w))
		st.add_vertex(Vector3(p.x, gy + FLOW_SURFACE_OFFSET_M, p.y))
	for t in range(0, tris.size(), 3):
		st.add_index(vtx_base + tris[t])
		st.add_index(vtx_base + tris[t + 1])
		st.add_index(vtx_base + tris[t + 2])
	return {"next_vtx": vtx_base + n}


## Signed lateral position on a buffered waterway ribbon: UV2.x = −1..1 across
## the channel, UV2.y = nominal half-width (m) used when the mesh was built.
static func _ribbon_lateral_uv2(p: Vector2, centerline: PackedVector2Array,
		half_w: float) -> Vector2:
	if centerline.size() < 2 or half_w <= 0.01:
		return Vector2(0.0, maxf(half_w, 1.0))
	var best_dist_sq := INF
	var best_signed := 0.0
	for i in range(centerline.size() - 1):
		var a := centerline[i]
		var b := centerline[i + 1]
		var seg := b - a
		var len_sq := seg.length_squared()
		if len_sq < 1e-8:
			continue
		var t := clampf((p - a).dot(seg) / len_sq, 0.0, 1.0)
		var closest := a + seg * t
		var d_vec := p - closest
		var dist_sq := d_vec.length_squared()
		if dist_sq >= best_dist_sq:
			continue
		best_dist_sq = dist_sq
		var tangent := seg / sqrt(len_sq)
		var normal := Vector2(-tangent.y, tangent.x)
		var signed := d_vec.dot(normal)
		best_signed = (1.0 if signed >= 0.0 else -1.0) * sqrt(dist_sq)
	return Vector2(clampf(best_signed / half_w, -1.0, 1.0), half_w)


## Push weather-driven flow uniforms to still + river water materials.
static func apply_flow_visuals(root: Node3D, width_scale: float, level_m: float,
		speed_scale: float, churn: float, water_alpha: float) -> void:
	if root == null:
		return
	var still := root.get_node_or_null("WaterSurface") as MeshInstance3D
	if still != null and still.material_override is ShaderMaterial:
		var mat := still.material_override as ShaderMaterial
		mat.set_shader_parameter("flow_level_m", level_m)
		mat.set_shader_parameter("flow_churn", churn)
		mat.set_shader_parameter("water_alpha", water_alpha)
	var river := root.get_node_or_null("RiverSurface") as MeshInstance3D
	if river != null and river.material_override is ShaderMaterial:
		var mat := river.material_override as ShaderMaterial
		mat.set_shader_parameter("flow_width_scale", width_scale)
		mat.set_shader_parameter("flow_level_m", level_m)
		mat.set_shader_parameter("flow_speed_scale", speed_scale)
		mat.set_shader_parameter("flow_churn", churn)
		mat.set_shader_parameter("water_alpha", water_alpha)


## Downhill flow at (x, z): direction = −∇(terrain height), speed ∝ slope. Returned
## as (dir_x, dir_z, speed01). Flat ground → tiny speed and an arbitrary direction.
static func _flow_vector(x: float, z: float, elev: PackedFloat32Array, res: int,
		extent_m: float, center_elev: float, detail_elev: PackedFloat32Array,
		detail_res: int, detail_extent_m: float,
		seam_feather_m: float = DEM_SEAM_FEATHER_M) -> Vector3:
	var d := FLOW_GRADIENT_STEP_M
	var hx0 := _ground_y(x - d, z, elev, res, extent_m, center_elev, detail_elev, detail_res, detail_extent_m, seam_feather_m)
	var hx1 := _ground_y(x + d, z, elev, res, extent_m, center_elev, detail_elev, detail_res, detail_extent_m, seam_feather_m)
	var hz0 := _ground_y(x, z - d, elev, res, extent_m, center_elev, detail_elev, detail_res, detail_extent_m, seam_feather_m)
	var hz1 := _ground_y(x, z + d, elev, res, extent_m, center_elev, detail_elev, detail_res, detail_extent_m, seam_feather_m)
	var grad := Vector2((hx1 - hx0) / (2.0 * d), (hz1 - hz0) / (2.0 * d))
	var slope := grad.length()
	var dir := Vector2.ZERO if slope < 1e-4 else (-grad / slope)
	# Map slope (rise/run) to a 0..1 speed: ~0 on flats, saturating by ~12% grade.
	var speed := clampf(slope / 0.12, 0.08, 1.0)
	return Vector3(dir.x, dir.y, speed)


## Level near the basin floor (low percentile of bank heights), robust to a single
## abnormally low DEM sample on the shoreline.
static func _water_level(heights: PackedFloat32Array) -> float:
	var n := heights.size()
	if n == 0:
		return 0.0
	var sorted := heights.duplicate()
	sorted.sort()
	var idx := int(round(LEVEL_PERCENTILE * float(n - 1)))
	idx = clampi(idx, 0, n - 1)
	return sorted[idx]


## Terrain height at a world XZ. Inside the hi-res patch it uses the detail grid, but
## within DEM_SEAM_FEATHER_M of the patch edge it cross-fades to the base grid so a
## river (or shoreline) crossing the seam doesn't step where the two DEMs disagree —
## the ~10 m "hover at the boundary" artefact. Outside the patch it's the base grid.
static func _ground_y(x: float, z: float, elev: PackedFloat32Array, res: int,
		extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array, detail_res: int, detail_extent_m: float,
		seam_feather_m: float = DEM_SEAM_FEATHER_M) -> float:
	var coarse_h := TerrainBuilder.height_at_world_xz(elev, res, extent_m, center_elev, x, z)
	if detail_elev.is_empty() or detail_res <= 1 or detail_extent_m <= 0.0:
		return coarse_h
	var half_d := detail_extent_m * 0.5
	if absf(x) > half_d or absf(z) > half_d:
		return coarse_h
	var detail_h := TerrainBuilder.height_at_world_xz(
		detail_elev, detail_res, detail_extent_m, center_elev, x, z)
	var edge_dist := half_d - maxf(absf(x), absf(z))
	if edge_dist >= seam_feather_m:
		return detail_h
	var t := clampf(edge_dist / seam_feather_m, 0.0, 1.0)
	return lerpf(coarse_h, detail_h, t)


static func _make_water_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	return mat


static func _make_river_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = RIVER_SHADER
	return mat
