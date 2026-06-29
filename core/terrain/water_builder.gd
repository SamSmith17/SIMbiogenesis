class_name WaterBuilder
extends RefCounted

## Builds flat OSM water bodies, each sat at a single level matched to its banks.
## Ponds and lakes get a local ReflectionProbe so the water shader can reflect
## sky and nearby trees (Godot 4 uses ReflectionProbe for this — not LightProbe3D).

const WATER_SHADER := preload("res://core/terrain/terrain_water.gdshader")
const MIN_AREA_M2 := 80.0
const MAX_BODIES := 200
const MIN_PROBE_AREA_M2 := 250.0
const MAX_REFLECTION_PROBES := 28
const PROBE_MARGIN_M := 10.0
const PROBE_HEIGHT_M := 32.0
const PROBE_MIN_EXTENT_M := 8.0
const PROBE_MAX_ASPECT := 5.5
## Skip narrow waterway ribbons — probes are sized for lake-like footprints.
const WATERWAY_KINDS := ["river", "stream", "canal", "ditch", "drain"]
## A water body lies on a flat plane (real water is level). The plane height is a
## low percentile of the shoreline terrain so it sits in the basin without floating
## above the lowest bank; this raises it just clear of that level to avoid z-fight.
const SURFACE_OFFSET_M := 0.06
## Percentile of boundary terrain heights used as the water level (0 = lowest bank).
const LEVEL_PERCENTILE := 0.18


static func build_water_node(waters: Array, elev: PackedFloat32Array, res: int,
		extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array = PackedFloat32Array(),
		detail_res: int = 0, detail_extent_m: float = 0.0) -> Node3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var added := 0
	var vtx_base := 0
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
		var body := _append_water_polygon(st, poly, vtx_base, elev, res,
			extent_m, center_elev, detail_elev, detail_res, detail_extent_m)
		if body.is_empty():
			continue
		vtx_base = int(body["next_vtx"])
		added += 1
		var kind := str(item.get("kind", "water"))
		if _wants_reflection_probe(poly, kind):
			probe_specs.append(body["probe"])
	if added == 0:
		return null
	var root := Node3D.new()
	root.name = "Water"
	var mi := MeshInstance3D.new()
	mi.name = "WaterSurface"
	mi.mesh = st.commit()
	mi.material_override = _make_water_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
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


static func _wants_reflection_probe(poly: PackedVector2Array, kind: String) -> bool:
	if kind in WATERWAY_KINDS:
		return false
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
	var count := 0
	for spec_v in specs:
		if count >= MAX_REFLECTION_PROBES:
			break
		if not (spec_v is Dictionary):
			continue
		var spec: Dictionary = spec_v
		var probe := _make_reflection_probe(spec)
		probes_root.add_child(probe)
		count += 1


static func _make_reflection_probe(spec: Dictionary) -> ReflectionProbe:
	var center: Vector3 = spec.get("center", Vector3.ZERO)
	var size: Vector3 = spec.get("size", Vector3(16.0, PROBE_HEIGHT_M, 16.0))
	var probe := ReflectionProbe.new()
	probe.name = "LakeReflection"
	probe.position = center + Vector3(0.0, size.y * 0.5, 0.0)
	probe.size = size
	probe.box_projection = true
	probe.enable_shadows = true
	probe.interior = false
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.intensity = 1.05
	probe.max_distance = maxf(size.x, size.z) * 0.65
	probe.origin_offset = Vector3(0.0, -size.y * 0.15, 0.0)
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
		detail_extent_m: float) -> Dictionary:
	var n := poly.size()
	if n >= 3 and poly[0].distance_squared_to(poly[n - 1]) < 0.01:
		poly = poly.slice(0, n - 1)
		n = poly.size()
	if n < 3:
		return {}
	var tris := Geometry2D.triangulate_polygon(poly)
	if tris.is_empty():
		return {}
	var bank_heights := PackedFloat32Array()
	bank_heights.resize(n)
	for i in n:
		bank_heights[i] = _ground_y(poly[i].x, poly[i].y, elev, res, extent_m,
			center_elev, detail_elev, detail_res, detail_extent_m)
	var level := _water_level(bank_heights) + SURFACE_OFFSET_M
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


static func _ground_y(x: float, z: float, elev: PackedFloat32Array, res: int,
		extent_m: float, center_elev: float,
		detail_elev: PackedFloat32Array, detail_res: int, detail_extent_m: float) -> float:
	if not detail_elev.is_empty() and detail_res > 1 and detail_extent_m > 0.0:
		var half_d := detail_extent_m * 0.5
		if absf(x) <= half_d and absf(z) <= half_d:
			return TerrainBuilder.height_at_world_xz(
				detail_elev, detail_res, detail_extent_m, center_elev, x, z)
	return TerrainBuilder.height_at_world_xz(elev, res, extent_m, center_elev, x, z)


static func _make_water_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	return mat
