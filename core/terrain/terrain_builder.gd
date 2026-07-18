class_name TerrainBuilder
extends RefCounted

## Builds a walkable terrain Node3D from an elevation grid + draped imagery
## (ROADMAP Pillar 1). Pure geometry — no network, no scene-tree assumptions —
## so the mesh/heightfield math is headless-testable
## (core/terrain/terrain_selftest.gd).
##
## Grid convention (shared by mesh + collision so they align exactly):
##   index = row * cols + col,  row 0 = north (−Z), col 0 = west (−X).
##   world x = (col/(cols-1) - 0.5) * extent_m
##   world z = (row/(rows-1) - 0.5) * extent_m
##   world y = elevation_metres - center_elev   (mean-centred; local height varies)

## Default mesh resolution (vertices per side). 256×256 over ~30 km ≈ 120 m spacing.
const DEFAULT_MESH_RES := 256
## Vertical clearance when spawning the player on generated terrain.
const PLAYER_SPAWN_CLEARANCE_M := 2.0
## Shader that blends a high-resolution centre patch over the base drape.
const DETAIL_SHADER := preload("res://core/terrain/terrain_detail.gdshader")
## Draw order: coarse Ground first, DetailGround on top (after centre hole discard).
const GROUND_RENDER_PRIORITY := 0
const DETAIL_GROUND_RENDER_PRIORITY := 1
## Neutral ground colour when no imagery is available (offline / headless).
const NEUTRAL_GROUND := Color(0.45, 0.42, 0.38)

## Seam blending between hi-res detail patch and coarse world terrain.
const MIN_FEATHER_M := 80.0
const MAX_FEATHER_M := 800.0
const EXTERIOR_RING_M := 600.0
const FOOTING_CROSSFADE_M := 20.0
const FEATHER_DELTA_SCALE := 3.0
const DEFAULT_FEATHER_M := 80.0


## Mean of a height grid, ignoring NANs. Used as the vertical centring offset.
static func mean_elevation(grid: PackedFloat32Array) -> float:
	var total := 0.0
	var count := 0
	for v in grid:
		if not is_nan(v):
			total += v
			count += 1
	return total / float(count) if count > 0 else 0.0


## Safe float coercion from JSON/cache Variants — `float(null)` crashes in GDScript.
static func variant_to_float(v: Variant, default: float = 0.0) -> float:
	if v == null:
		return default
	match typeof(v):
		TYPE_FLOAT, TYPE_INT:
			return float(v)
		TYPE_STRING:
			var s: String = str(v).strip_edges()
			if s.is_empty():
				return default
			var f := s.to_float()
			return f if not is_nan(f) else default
		_:
			return default


static func dict_float(d: Dictionary, key: String, default: float = 0.0) -> float:
	if not d.has(key):
		return default
	return variant_to_float(d[key], default)


## Bilinearly sample a source grid (src_cols × src_rows, row-major) at normalised
## coordinates u,v ∈ [0,1] (u→col/east, v→row/south). NANs are skipped so sparse
## holes don't punch through the surface.
static func sample_bilinear(src: PackedFloat32Array, src_cols: int, src_rows: int,
		u: float, v: float) -> float:
	if src.is_empty() or src_cols < 1 or src_rows < 1:
		return 0.0
	var fx := clampf(u, 0.0, 1.0) * float(src_cols - 1)
	var fy := clampf(v, 0.0, 1.0) * float(src_rows - 1)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var x1 := mini(x0 + 1, src_cols - 1)
	var y1 := mini(y0 + 1, src_rows - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var v00 := src[y0 * src_cols + x0]
	var v10 := src[y0 * src_cols + x1]
	var v01 := src[y1 * src_cols + x0]
	var v11 := src[y1 * src_cols + x1]
	# Fall back to any finite neighbour if a corner is NAN.
	var samples := [v00, v10, v01, v11]
	var first_finite := NAN
	for s in samples:
		if not is_nan(s):
			first_finite = s
			break
	if is_nan(first_finite):
		return 0.0
	if is_nan(v00): v00 = first_finite
	if is_nan(v10): v10 = first_finite
	if is_nan(v01): v01 = first_finite
	if is_nan(v11): v11 = first_finite
	var top := lerpf(v00, v10, tx)
	var bot := lerpf(v01, v11, tx)
	return lerpf(top, bot, ty)


## World-space terrain height (metres) at (x, z). Uses the same grid convention and
## mean-centring as build_mesh / build_heightmap_shape.
static func height_at_world_xz(elev: PackedFloat32Array, res: int, extent_m: float,
		center_elev: float, x: float, z: float) -> float:
	return height_at_world_xz_rect(elev, res, res, extent_m, center_elev, x, z)


static func height_at_world_xz_rect(elev: PackedFloat32Array, cols: int, rows: int,
		extent_m: float, center_elev: float, x: float, z: float) -> float:
	if elev.is_empty() or cols < 1 or rows < 1:
		return 0.0
	var half := extent_m * 0.5
	var u := clampf((x + half) / extent_m, 0.0, 1.0)
	var v := clampf((z + half) / extent_m, 0.0, 1.0)
	return sample_bilinear(elev, cols, rows, u, v) - center_elev


## Walkable ground height: hi-res detail patch inside its square, coarse grid outside.
## Cross-fades across FOOTING_CROSSFADE_M at the boundary when both grids exist.
static func sample_footing_height(x: float, z: float, coarse: PackedFloat32Array, coarse_res: int,
		coarse_extent_m: float, center_elev: float,
		detail: PackedFloat32Array = PackedFloat32Array(), detail_cols: int = 0,
		detail_rows: int = 0, detail_extent_m: float = 0.0,
		detail_fallback_coarse: PackedFloat32Array = PackedFloat32Array(),
		crossfade_m: float = FOOTING_CROSSFADE_M) -> float:
	var detail_half := detail_extent_m * 0.5 if detail_extent_m > 0.0 else 0.0
	var has_detail := not detail.is_empty() and detail_cols > 1 and detail_rows > 1 and detail_half > 0.0
	var in_detail := detail_half > 0.0 and absf(x) <= detail_half and absf(z) <= detail_half
	var coarse_y := 0.0
	var has_coarse := not coarse.is_empty() and coarse_res > 1
	if has_coarse:
		coarse_y = height_at_world_xz(coarse, coarse_res, coarse_extent_m, center_elev, x, z)
	if in_detail and not has_detail and not detail_fallback_coarse.is_empty() and coarse_res > 1:
		return height_at_world_xz(
			detail_fallback_coarse, coarse_res, coarse_extent_m, center_elev, x, z)
	if not has_detail:
		if has_coarse:
			return coarse_y
		return 0.0
	var detail_y := height_at_world_xz_rect(
		detail, detail_cols, detail_rows, detail_extent_m, center_elev, x, z)
	var dist_in := maxf(absf(x), absf(z))
	if dist_in >= detail_half:
		return coarse_y
	if crossfade_m <= 0.0 or dist_in <= detail_half - crossfade_m:
		return detail_y
	var edge_dist := detail_half - dist_in
	var t := clampf(edge_dist / crossfade_m, 0.0, 1.0)
	return lerpf(coarse_y, detail_y, t)


## Resample a source grid to a (dst × dst) grid by bilinear interpolation.
static func resample(src: PackedFloat32Array, src_cols: int, src_rows: int,
		dst: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(dst * dst)
	var inv := 1.0 / float(maxi(dst - 1, 1))
	for r in dst:
		var v := float(r) * inv
		for c in dst:
			var u := float(c) * inv
			out[r * dst + c] = sample_bilinear(src, src_cols, src_rows, u, v)
	return out


## Build the displaced ground ArrayMesh. `elev` is a square grid (res × res,
## row-major, metres). UVs map 0..1 across the tile to match the stitched drape.
static func build_mesh(elev: PackedFloat32Array, res: int, extent_m: float,
		center_elev: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := extent_m * 0.5
	var inv := 1.0 / float(maxi(res - 1, 1))
	# Emit vertices row by row.
	for r in res:
		var v := float(r) * inv
		var z := v * extent_m - half
		for c in res:
			var u := float(c) * inv
			var x := u * extent_m - half
			var h := elev[r * res + c] - center_elev
			st.set_uv(Vector2(u, v))
			st.add_vertex(Vector3(x, h, z))
	# Two triangles per cell. Godot treats CLOCKWISE-from-front as the front face
	# (default CULL_BACK), so this winding makes the TOP the front face and
	# generate_normals() point +Y. (The reverse order leaves the surface
	# back-faced → invisible from above.)
	for r in res - 1:
		for c in res - 1:
			var i := r * res + c
			var i_right := i + 1
			var i_down := i + res
			var i_diag := i_down + 1
			st.add_index(i)
			st.add_index(i_right)
			st.add_index(i_down)
			st.add_index(i_right)
			st.add_index(i_diag)
			st.add_index(i_down)
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


## ---------------------------------------------------------------------------
## Fast surface arrays for LIVE sculpting. Unlike build_mesh (SurfaceTool +
## generate_normals, which re-walks every triangle) these compute per-vertex
## normals analytically from the heightfield central difference, so a brush stroke
## can recompute just the touched region each frame without a full re-mesh.
## ---------------------------------------------------------------------------

## Analytic surface normal at grid cell (c, r) from the heightfield gradient.
static func surface_normal_at(elev: PackedFloat32Array, res: int, extent_m: float,
		c: int, r: int) -> Vector3:
	var spacing := extent_m / float(maxi(res - 1, 1))
	var cl := maxi(c - 1, 0)
	var cr := mini(c + 1, res - 1)
	var ru := maxi(r - 1, 0)
	var rd := mini(r + 1, res - 1)
	var hl := elev[r * res + cl]
	var hr := elev[r * res + cr]
	var hu := elev[ru * res + c]
	var hd := elev[rd * res + c]
	var dx := 2.0 * spacing if cr != cl else spacing
	var dz := 2.0 * spacing if rd != ru else spacing
	var n := Vector3(-(hr - hl) / maxf(dx, 1e-4), 1.0, -(hd - hu) / maxf(dz, 1e-4))
	return n.normalized()


## Build the full surface arrays (vertex/normal/uv/index) for an ArrayMesh.
static func build_surface_arrays(elev: PackedFloat32Array, res: int, extent_m: float,
		center_elev: float) -> Array:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	verts.resize(res * res)
	uvs.resize(res * res)
	normals.resize(res * res)
	var half := extent_m * 0.5
	var inv := 1.0 / float(maxi(res - 1, 1))
	for r in res:
		var v := float(r) * inv
		var z := v * extent_m - half
		for c in res:
			var u := float(c) * inv
			var x := u * extent_m - half
			var idx := r * res + c
			verts[idx] = Vector3(x, elev[idx] - center_elev, z)
			uvs[idx] = Vector2(u, v)
			normals[idx] = surface_normal_at(elev, res, extent_m, c, r)
	var indices := PackedInt32Array()
	indices.resize((res - 1) * (res - 1) * 6)
	var ii := 0
	for r in res - 1:
		for c in res - 1:
			var i := r * res + c
			var i_right := i + 1
			var i_down := i + res
			var i_diag := i_down + 1
			indices[ii] = i
			indices[ii + 1] = i_right
			indices[ii + 2] = i_down
			indices[ii + 3] = i_right
			indices[ii + 4] = i_diag
			indices[ii + 5] = i_down
			ii += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## Re-sync vertex Y + normals for a cell rectangle after an in-place height edit.
## Normals are refreshed one ring beyond the edited rect so seams stay smooth.
static func update_surface_arrays_region(verts: PackedVector3Array, normals: PackedVector3Array,
		elev: PackedFloat32Array, res: int, extent_m: float, center_elev: float,
		min_c: int, min_r: int, max_c: int, max_r: int) -> void:
	if verts.size() != res * res or normals.size() != res * res:
		return
	for r in range(maxi(min_r, 0), mini(max_r, res - 1) + 1):
		for c in range(maxi(min_c, 0), mini(max_c, res - 1) + 1):
			var idx := r * res + c
			var p := verts[idx]
			verts[idx] = Vector3(p.x, elev[idx] - center_elev, p.z)
	var n0c := maxi(min_c - 1, 0)
	var n1c := mini(max_c + 1, res - 1)
	var n0r := maxi(min_r - 1, 0)
	var n1r := mini(max_r + 1, res - 1)
	for r in range(n0r, n1r + 1):
		for c in range(n0c, n1c + 1):
			normals[r * res + c] = surface_normal_at(elev, res, extent_m, c, r)


static func make_array_mesh(arrays: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## HeightMapShape3D for the same grid. Returned shape is unit-spaced; the caller
## scales the owning CollisionShape3D by (extent/(res-1), 1, extent/(res-1)) so it
## registers with the mesh.
static func build_heightmap_shape(elev: PackedFloat32Array, res: int,
		center_elev: float) -> HeightMapShape3D:
	var shape := HeightMapShape3D.new()
	shape.map_width = res
	shape.map_depth = res
	var data := PackedFloat32Array()
	data.resize(res * res)
	# Clamp to the smaller of the two — a non-square / mis-sized source grid would
	# otherwise write past data[] (a native heap overflow → silent process exit).
	var n := mini(elev.size(), data.size())
	for i in n:
		data[i] = elev[i] - center_elev
	shape.map_data = data
	return shape


## Drape material for the Ground mesh. Always a ShaderMaterial when a drape is
## present so Mercator→equirect sampling can keep OSM registered to the photo.
## `base_bbox` / `detail_bbox` are GeoMath.bbox_for dicts (optional — omit to
## skip Mercator correction, e.g. headless selftests).
static func make_terrain_material(base: Texture2D, detail: Texture2D,
		terrain_extent_m: float, detail_extent_m: float,
		patch_mesh: bool = false, hide_detail_region: bool = false,
		hide_centre_region: bool = false, feather_uv: float = 0.06,
		base_bbox: Dictionary = {}, detail_bbox: Dictionary = {}) -> Material:
	if base == null and detail == null and not hide_centre_region and not patch_mesh:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = NEUTRAL_GROUND
		mat.roughness = 1.0
		mat.metallic = 0.0
		mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		return mat
	var sm := ShaderMaterial.new()
	sm.shader = DETAIL_SHADER
	sm.set_shader_parameter("base_tex", base)
	sm.set_shader_parameter("use_base", base != null)
	sm.set_shader_parameter("detail_tex", detail)
	sm.set_shader_parameter("base_color", NEUTRAL_GROUND)
	sm.set_shader_parameter("extent_ratio", terrain_extent_m / maxf(detail_extent_m, 1.0))
	sm.set_shader_parameter("patch_mesh", patch_mesh)
	sm.set_shader_parameter("use_detail", detail != null)
	sm.set_shader_parameter("hide_detail_region", hide_detail_region)
	sm.set_shader_parameter("hide_centre_region", hide_centre_region)
	sm.set_shader_parameter("feather", feather_uv)
	apply_drape_bboxes(sm, base_bbox, detail_bbox)
	return sm


## bbox dict → shader vec4 (west, east, south, north).
static func bbox_to_shader_vec4(bbox: Dictionary) -> Vector4:
	if bbox.is_empty():
		return Vector4(-1.0, 1.0, -1.0, 1.0)
	return Vector4(
		float(bbox.get("west", -1.0)),
		float(bbox.get("east", 1.0)),
		float(bbox.get("south", -1.0)),
		float(bbox.get("north", 1.0)))


static func apply_drape_bboxes(sm: ShaderMaterial, base_bbox: Dictionary = {},
		detail_bbox: Dictionary = {}) -> void:
	if sm == null:
		return
	var has_base := not base_bbox.is_empty()
	var has_detail := not detail_bbox.is_empty()
	sm.set_shader_parameter("base_bbox", bbox_to_shader_vec4(base_bbox))
	sm.set_shader_parameter("detail_bbox", bbox_to_shader_vec4(detail_bbox))
	sm.set_shader_parameter("correct_base_mercator", has_base)
	sm.set_shader_parameter("correct_detail_mercator", has_detail)


static func _apply_render_priority(mat: Material, priority: int) -> void:
	if mat != null:
		mat.render_priority = priority


## True when the hi-res DetailGround mesh is present under `terrain`.
static func has_detail_ground(terrain: Node3D) -> bool:
	return terrain != null and terrain.get_node_or_null("DetailGround") != null


## Punch a visibility hole in the coarse Ground material when DetailGround exists.
static func sync_coarse_ground_hide(terrain: Node3D, base_drape: Texture2D,
		detail_drape: Texture2D, terrain_extent_m: float, detail_extent_m: float,
		feather_m: float = DEFAULT_FEATHER_M) -> void:
	if terrain == null or not has_detail_ground(terrain):
		return
	var ground := terrain.get_node_or_null("Ground") as MeshInstance3D
	if ground == null:
		return
	var feather_uv := feather_uv_from_metres(feather_m, detail_extent_m)
	# Bboxes stamped by TerrainLoader._stamp_drape_mercator_bboxes after this;
	# keep ShaderMaterial path so Mercator correction can be applied.
	ground.material_override = make_terrain_material(
		base_drape, detail_drape, terrain_extent_m, detail_extent_m,
		false, false, true, feather_uv)
	_apply_render_priority(ground.material_override, GROUND_RENDER_PRIORITY)


## Assemble the full terrain node: MeshInstance3D ("Ground") + StaticBody3D with a
## HeightMapShape3D collider. `drape` may be null (e.g. headless/offline) — the
## mesh then renders with a neutral material. `detail` (optional) is a high-res
## centre patch blended over the central `detail_extent_m` square.
static func build_terrain_node(elev: PackedFloat32Array, res: int, extent_m: float,
		center_elev: float, drape: Texture2D = null,
		detail: Texture2D = null, detail_extent_m: float = 0.0) -> Node3D:
	var root := Node3D.new()
	root.name = "GeneratedTerrain"

	var mi := MeshInstance3D.new()
	mi.name = "Ground"
	mi.mesh = build_mesh(elev, res, extent_m, center_elev)
	mi.material_override = make_terrain_material(drape, detail, extent_m, detail_extent_m)
	_apply_render_priority(mi.material_override, GROUND_RENDER_PRIORITY)
	# Large terrain spans well past the default cull margin; keep it from being
	# frustum-culled when the camera sits low on it.
	mi.extra_cull_margin = extent_m
	root.add_child(mi)

	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	var cs := CollisionShape3D.new()
	cs.shape = build_heightmap_shape(elev, res, center_elev)
	var spacing := extent_m / float(maxi(res - 1, 1))
	cs.scale = Vector3(spacing, 1.0, spacing)
	body.add_child(cs)
	root.add_child(body)

	return root


## UV-space feather width from metres on the detail patch edge.
static func feather_uv_from_metres(feather_m: float, detail_extent_m: float) -> float:
	if detail_extent_m <= 0.0:
		return 0.06
	return clampf(feather_m / detail_extent_m, 0.01, 0.35)


## Max |detail − coarse| height difference along the detail square perimeter.
static func compute_boundary_delta_m(detail: PackedFloat32Array, detail_res: int,
		detail_extent_m: float, coarse: PackedFloat32Array, coarse_res: int,
		coarse_extent_m: float, center_elev: float, sample_count: int = 32) -> float:
	if detail.is_empty() or coarse.is_empty():
		return 0.0
	var diag := TerrainSeamDiag.measure_boundary_delta(
		detail, detail_res, detail_extent_m, coarse, coarse_res,
		coarse_extent_m, center_elev, sample_count)
	return float(diag.get("max_delta_m", 0.0))


## Adaptive feather width from measured boundary mismatch.
static func compute_adaptive_feather_m(detail: PackedFloat32Array, detail_res: int,
		detail_extent_m: float, coarse: PackedFloat32Array, coarse_res: int,
		coarse_extent_m: float, center_elev: float) -> float:
	var max_delta := compute_boundary_delta_m(
		detail, detail_res, detail_extent_m, coarse, coarse_res, coarse_extent_m, center_elev)
	return clampf(FEATHER_DELTA_SCALE * max_delta, MIN_FEATHER_M, MAX_FEATHER_M)


## Median vertical offset (coarse − detail) along the detail-square perimeter; shift
## detail by this so the patch edge meets the coarse heightfield.
static func compute_detail_vertical_offset(detail: PackedFloat32Array, detail_res: int,
		detail_extent_m: float, coarse: PackedFloat32Array, coarse_res: int,
		coarse_extent_m: float, center_elev: float, sample_count: int = 32) -> float:
	if detail.is_empty() or coarse.is_empty() or detail_res < 2:
		return 0.0
	var half_d := detail_extent_m * 0.5
	var samples: Array[float] = []
	for i in sample_count:
		var t := float(i) / float(maxi(sample_count - 1, 1))
		var perim := t * 4.0
		var x := 0.0
		var z := 0.0
		if perim < 1.0:
			x = lerpf(half_d, -half_d, perim)
			z = half_d
		elif perim < 2.0:
			x = -half_d
			z = lerpf(half_d, -half_d, perim - 1.0)
		elif perim < 3.0:
			x = lerpf(-half_d, half_d, perim - 2.0)
			z = -half_d
		else:
			x = half_d
			z = lerpf(-half_d, half_d, perim - 3.0)
		var u := clampf((x + half_d) / detail_extent_m, 0.0, 1.0)
		var v := clampf((z + half_d) / detail_extent_m, 0.0, 1.0)
		var d_amsl := sample_bilinear(detail, detail_res, detail_res, u, v)
		var c_amsl := height_at_world_xz(coarse, coarse_res, coarse_extent_m,
			center_elev, x, z) + center_elev
		if is_nan(d_amsl) or is_nan(c_amsl):
			continue
		samples.append(c_amsl - d_amsl)
	if samples.is_empty():
		return 0.0
	samples.sort()
	var mid := samples.size() / 2
	if samples.size() % 2 == 1:
		return samples[mid]
	return (samples[mid - 1] + samples[mid]) * 0.5


static func apply_detail_vertical_offset(detail: PackedFloat32Array, offset_m: float) -> PackedFloat32Array:
	if absf(offset_m) < 1e-6:
		return detail
	var out := detail.duplicate()
	for i in out.size():
		if not is_nan(out[i]):
			out[i] += offset_m
	return out


## Nearest point on the detail-square boundary from world (x, z).
static func _nearest_detail_edge_xz(x: float, z: float, half_d: float) -> Vector2:
	var px := clampf(x, -half_d, half_d)
	var pz := clampf(z, -half_d, half_d)
	if absf(x) > half_d:
		px = signf(x) * half_d
	if absf(z) > half_d:
		pz = signf(z) * half_d
	return Vector2(px, pz)


## Pull coarse heights in an exterior ring toward the detail edge so cliffs don't form.
static func feather_coarse_exterior_ring(coarse: PackedFloat32Array, coarse_res: int,
		coarse_extent_m: float, center_elev: float,
		detail_surf: PackedFloat32Array, detail_res: int, detail_extent_m: float,
		ring_m: float = EXTERIOR_RING_M) -> PackedFloat32Array:
	var out := coarse.duplicate()
	if detail_surf.is_empty() or coarse.is_empty() or ring_m <= 0.0:
		return out
	var half_d := detail_extent_m * 0.5
	var half_t := coarse_extent_m * 0.5
	var inv_t := 1.0 / float(maxi(coarse_res - 1, 1))
	for r in coarse_res:
		var z := float(r) * inv_t * coarse_extent_m - half_t
		for c in coarse_res:
			var x := float(c) * inv_t * coarse_extent_m - half_t
			var dist_in := maxf(absf(x), absf(z))
			if dist_in <= half_d or dist_in > half_d + ring_m:
				continue
			var edge := _nearest_detail_edge_xz(x, z, half_d)
			var edge_amsl := sample_bilinear(detail_surf, detail_res, detail_res,
				(edge.x + half_d) / detail_extent_m, (edge.y + half_d) / detail_extent_m)
			var blend := 1.0 - clampf((dist_in - half_d) / ring_m, 0.0, 1.0)
			var idx := r * coarse_res + c
			out[idx] = lerpf(out[idx], edge_amsl, blend)
	return out


## Scale sink depth to local relief so flat sites aren't over-sunk.
static func compute_sink_depth_m(detail: PackedFloat32Array, default_depth: float = 80.0) -> float:
	if detail.is_empty():
		return default_depth
	var lo := INF
	var hi := -INF
	for v in detail:
		if not is_nan(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	var relief := hi - lo
	return maxf(default_depth, relief * 0.25)


## Merge a hi-res centre DEM patch into the full terrain grid with edge feathering.
static func patch_centre_heights(base: PackedFloat32Array, base_res: int,
		detail: PackedFloat32Array, detail_res: int, terrain_extent_m: float,
		detail_extent_m: float, feather_m: float = 40.0) -> PackedFloat32Array:
	var out := base.duplicate()
	if detail.is_empty() or detail_res < 2 or base_res < 2:
		return out
	var half_t := terrain_extent_m * 0.5
	var half_d := detail_extent_m * 0.5
	var inv_t := 1.0 / float(maxi(base_res - 1, 1))
	var inv_d := 1.0 / float(maxi(detail_res - 1, 1))
	for r in base_res:
		var z := float(r) * inv_t * terrain_extent_m - half_t
		for c in base_res:
			var x := float(c) * inv_t * terrain_extent_m - half_t
			if absf(x) > half_d or absf(z) > half_d:
				continue
			var edge_dist := minf(half_d - absf(x), half_d - absf(z))
			var blend := 1.0 if feather_m <= 0.0 else clampf(edge_dist / feather_m, 0.0, 1.0)
			var u := (x + half_d) / detail_extent_m
			var v := (z + half_d) / detail_extent_m
			var dh := sample_bilinear(detail, detail_res, detail_res, u, v)
			var idx := r * base_res + c
			out[idx] = lerpf(out[idx], dh, blend)
	return out


## Lower coarse heightmap cells inside the hi-res square so TerrainCollision cannot
## form a smoothed "bridge" above DetailCollision / DetailGround in valleys.
static func sink_coarse_centre_for_detail(out: PackedFloat32Array, base_res: int,
		terrain_extent_m: float, detail_extent_m: float, center_elev: float,
		sink_depth_m: float = 80.0, feather_m: float = 60.0) -> void:
	if out.is_empty() or base_res < 2 or detail_extent_m <= 0.0:
		return
	var half_t := terrain_extent_m * 0.5
	var half_d := detail_extent_m * 0.5
	var inv_t := 1.0 / float(maxi(base_res - 1, 1))
	var floor_y := center_elev - sink_depth_m
	for r in base_res:
		var z := float(r) * inv_t * terrain_extent_m - half_t
		for c in base_res:
			var x := float(c) * inv_t * terrain_extent_m - half_t
			if absf(x) > half_d or absf(z) > half_d:
				continue
			var edge_dist := minf(half_d - absf(x), half_d - absf(z))
			var sink_blend := 1.0 if feather_m <= 0.0 else clampf(edge_dist / feather_m, 0.0, 1.0)
			var idx := r * base_res + c
			out[idx] = lerpf(out[idx], floor_y, sink_blend)


## Replace Ground mesh on an existing terrain node. Optional `collision_elev` uses a
## separate heightfield for TerrainCollision (e.g. centre-sunk to avoid doming).
static func rebuild_terrain_surfaces(terrain: Node3D, elev: PackedFloat32Array,
		res: int, extent_m: float, center_elev: float,
		base_drape: Texture2D = null, detail_drape: Texture2D = null,
		detail_extent_m: float = 0.0, hide_coarse_centre: bool = false,
		seam_feather_m: float = DEFAULT_FEATHER_M,
		collision_elev: PackedFloat32Array = PackedFloat32Array()) -> void:
	if terrain == null:
		return
	var coll := collision_elev if not collision_elev.is_empty() else elev
	var feather_uv := feather_uv_from_metres(seam_feather_m, detail_extent_m) if detail_extent_m > 0.0 else 0.06
	var ground := terrain.get_node_or_null("Ground") as MeshInstance3D
	if ground != null:
		ground.mesh = build_mesh(elev, res, extent_m, center_elev)
		ground.material_override = make_terrain_material(
			base_drape, detail_drape, extent_m, detail_extent_m,
			false, false, hide_coarse_centre, feather_uv)
		_apply_render_priority(ground.material_override, GROUND_RENDER_PRIORITY)
	var body := terrain.get_node_or_null("TerrainCollision") as StaticBody3D
	if body != null:
		var cs := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if cs == null and body.get_child_count() > 0:
			cs = body.get_child(0) as CollisionShape3D
		if cs != null:
			cs.shape = build_heightmap_shape(coll, res, center_elev)
			var spacing := extent_m / float(maxi(res - 1, 1))
			cs.scale = Vector3(spacing, 1.0, spacing)


## Update coarse TerrainCollision only (visual Ground mesh unchanged).
static func update_terrain_collision(terrain: Node3D, elev: PackedFloat32Array,
		res: int, extent_m: float, center_elev: float) -> void:
	if terrain == null or elev.is_empty() or res < 2:
		return
	var body := terrain.get_node_or_null("TerrainCollision") as StaticBody3D
	if body == null:
		return
	var cs := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs == null and body.get_child_count() > 0:
		cs = body.get_child(0) as CollisionShape3D
	if cs == null:
		return
	cs.shape = build_heightmap_shape(elev, res, center_elev)
	var spacing := extent_m / float(maxi(res - 1, 1))
	cs.scale = Vector3(spacing, 1.0, spacing)


## Blend detail-patch edge heights into the coarse grid so the two meshes meet cleanly.
static func feather_detail_to_coarse(detail: PackedFloat32Array, detail_res: int,
		detail_extent_m: float, coarse: PackedFloat32Array, coarse_res: int,
		coarse_extent_m: float, center_elev: float, feather_m: float = 80.0) -> PackedFloat32Array:
	var out := detail.duplicate()
	if detail.is_empty() or coarse.is_empty() or detail_res < 2:
		return out
	var half_d := detail_extent_m * 0.5
	var inv := 1.0 / float(maxi(detail_res - 1, 1))
	for r in detail_res:
		var z := float(r) * inv * detail_extent_m - half_d
		for c in detail_res:
			var x := float(c) * inv * detail_extent_m - half_d
			var edge_dist := minf(half_d - absf(x), half_d - absf(z))
			if edge_dist >= feather_m:
				continue
			var blend := 1.0 - clampf(edge_dist / feather_m, 0.0, 1.0)
			var coarse_h := height_at_world_xz(coarse, coarse_res, coarse_extent_m,
				center_elev, x, z) + center_elev
			var idx := r * detail_res + c
			out[idx] = lerpf(out[idx], coarse_h, blend)
	return out


## Hi-res 1 km centre mesh (~4 m vertex spacing at 256²) over the coarse 30 km ground.
## DetailGround is visual; DetailCollision provides walkable hi-res footing in the
## same footprint (coarse TerrainCollision is sunk in the centre so it cannot dome
## over detail valleys after Phase 6 hid the coarse mesh there).
static func upsert_detail_patch(terrain: Node3D, elev: PackedFloat32Array, res: int,
		detail_extent_m: float, center_elev: float, base_drape: Texture2D = null,
		detail_drape: Texture2D = null, terrain_extent_m: float = 0.0,
		seam_feather_m: float = DEFAULT_FEATHER_M) -> void:
	if terrain == null or elev.is_empty() or res < 2:
		return
	var feather_uv := feather_uv_from_metres(seam_feather_m, detail_extent_m)
	var ground := terrain.get_node_or_null("DetailGround") as MeshInstance3D
	if ground == null:
		ground = MeshInstance3D.new()
		ground.name = "DetailGround"
		terrain.add_child(ground)
	ground.mesh = build_mesh(elev, res, detail_extent_m, center_elev)
	ground.material_override = make_terrain_material(
		base_drape, detail_drape, terrain_extent_m, detail_extent_m, true, false, false, feather_uv)
	_apply_render_priority(ground.material_override, DETAIL_GROUND_RENDER_PRIORITY)
	ground.extra_cull_margin = detail_extent_m

	var body := terrain.get_node_or_null("DetailCollision") as StaticBody3D
	if body == null:
		body = StaticBody3D.new()
		body.name = "DetailCollision"
		terrain.add_child(body)
	var cs := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs == null:
		cs = CollisionShape3D.new()
		body.add_child(cs)
	cs.shape = build_heightmap_shape(elev, res, center_elev)
	var spacing := detail_extent_m / float(maxi(res - 1, 1))
	cs.scale = Vector3(spacing, 1.0, spacing)

	sync_coarse_ground_hide(terrain, base_drape, detail_drape, terrain_extent_m, detail_extent_m, seam_feather_m)


static func remove_detail_patch(terrain: Node3D) -> void:
	if terrain == null:
		return
	for name in ["DetailGround", "DetailCollision"]:
		var n := terrain.get_node_or_null(name)
		if n != null:
			n.queue_free()


## Flat selection overlay draped on the terrain surface for sculpt feedback.
static func build_selection_highlight(world_min: Vector2, world_max: Vector2,
		elev: PackedFloat32Array, res: int, extent_m: float, center_elev: float,
		lift_m: float = 0.35) -> ArrayMesh:
	var x0 := minf(world_min.x, world_max.x)
	var x1 := maxf(world_min.x, world_max.x)
	var z0 := minf(world_min.y, world_max.y)
	var z1 := maxf(world_min.y, world_max.y)
	var corners := [
		Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1),
	]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in corners:
		var y := height_at_world_xz(elev, res, extent_m, center_elev, p.x, p.y) + lift_m
		st.set_color(Color(1.0, 0.85, 0.1, 0.45))
		st.add_vertex(Vector3(p.x, y, p.y))
	st.add_index(0)
	st.add_index(1)
	st.add_index(2)
	st.add_index(0)
	st.add_index(2)
	st.add_index(3)
	return st.commit()


## Draped selection overlay for arbitrary polygons (lasso / polygon tools).
static func build_polygon_highlight(poly: PackedVector2Array, elev: PackedFloat32Array,
		res: int, extent_m: float, center_elev: float, lift_m: float = 0.35) -> ArrayMesh:
	if poly.size() < 3:
		return ArrayMesh.new()
	var tris := Geometry2D.triangulate_polygon(poly)
	if tris.is_empty():
		return ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in poly.size():
		var p := poly[i]
		var y := height_at_world_xz(elev, res, extent_m, center_elev, p.x, p.y) + lift_m
		st.set_color(Color(0.2, 0.85, 0.35, 0.42))
		st.add_vertex(Vector3(p.x, y, p.y))
	for t in range(0, tris.size(), 3):
		st.add_index(tris[t])
		st.add_index(tris[t + 1])
		st.add_index(tris[t + 2])
	return st.commit()
