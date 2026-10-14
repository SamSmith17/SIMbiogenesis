class_name SoiSectionCap
extends MeshInstance3D

## Solid strata cap on the Elevation / Hydro Lab section's cut plane.
##
## The cutaway half-plane (SoiService.set_section_cutaway) used to leave the cut
## OPEN: you looked into the far half of the soil bowl, and where the ground at
## the cut was higher than the ground at the bowl's back rim the sky showed
## through. This mesh fills the plane — vertical strips from the terrain profile
## along the cut down to the sphere's chord circle — painted with the bowl's own
## strata (soi_section_cap.gdshader + soi_strata.gdshaderinc).
##
## Driven entirely by SoiService.set_section_cutaway, the one choke point every
## section user (Elevation CT, Hydro Lab) already goes through. Rebuilt only when
## its key changes (heading, slice, radius, centre, a terrain time bucket).
## World-space geometry under a top_level node, so its parent's transform is
## irrelevant. The strip builder is pure (build_strips) and selftested.

## Samples along the chord. ground_y_at is a DEM lookup, so 128 is cheap.
const SAMPLES := 128
## The cap sits this far BEHIND the plane (away from the camera): the cutaway
## discards `dot(p − o, n) > 0`, and a cap exactly on the plane would flicker in
## and out of that test.
const BACK_OFF_M := 0.03
## Terrain edits arrive with no signal; re-sample at most this often.
const TERRAIN_TTL_MS := 2000

var _key := ""
var _mat: ShaderMaterial = null


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://core/soi/shaders/soi_section_cap.gdshader")
	TerrainBuilder.apply_soil_textures(_mat)
	material_override = _mat
	visible = false


## Rebuild (when the key changed) for a cut through `center` (the SoI world
## centre, radius `r`) with plane origin `plane_origin` and normal `n` (toward
## the camera). `ground_fn(x, z) -> float` samples the terrain.
func sync_cut(center: Vector3, r: float, plane_origin: Vector3, n: Vector3,
		ground_fn: Callable) -> void:
	var nn := Vector3(n.x, 0.0, n.z)
	if nn.length_squared() < 1e-8 or r <= 0.0:
		visible = false
		return
	nn = nn.normalized()
	var d := (plane_origin - center).dot(nn)
	var bucket := Time.get_ticks_msec() / TERRAIN_TTL_MS
	var key := "%.3f|%.3f|%.3f|%.2f|%.2f|%.2f|%.2f|%d" % [
		nn.x, nn.z, d, r, center.x, center.y, center.z, bucket]
	if key != _key:
		_key = key
		# along = n rotated −90° about +Y (n = cross axis, along = its partner).
		var along := Vector3(nn.z, 0.0, -nn.x)
		var c := sqrt(maxf(r * r - d * d, 0.0))
		var alongs := PackedFloat32Array()
		var heights := PackedFloat32Array()
		alongs.resize(SAMPLES + 1)
		heights.resize(SAMPLES + 1)
		var base := center + nn * d
		for i in SAMPLES + 1:
			var a := -c + 2.0 * c * float(i) / float(SAMPLES)
			alongs[i] = a
			var p := base + along * a
			heights[i] = float(ground_fn.call(p.x, p.z))
		mesh = build_strips(center, r, along, nn, d, alongs, heights, BACK_OFF_M)
	visible = mesh != null


func set_lip(lip_m: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("lip_m", lip_m)


func set_reveal(t: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("reveal", clampf(t, 0.0, 1.0))


## Pure strip builder. `along` / `n` are unit horizontal axes (n toward the
## camera), `d` the slice depth from the centre along n. Each sample a in
## `alongs` gets a top vertex at min(ground, chord-circle top) and a bottom
## vertex on the chord circle; consecutive samples form a quad. UV2.x carries
## the ground height (so the strata depth is exact per strip), UV2.y flags the
## top edge (the lip). Returns null when nothing is left above the bottom.
static func build_strips(center: Vector3, r: float, along: Vector3, n: Vector3,
		d: float, alongs: PackedFloat32Array, heights: PackedFloat32Array,
		back_off: float) -> ArrayMesh:
	var cnt := mini(alongs.size(), heights.size())
	if cnt < 2:
		return null
	var c2 := maxf(r * r - d * d, 0.0)
	var base := center + n * (d - back_off)
	var verts := PackedVector3Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	var tops := PackedFloat32Array()
	var bots := PackedFloat32Array()
	tops.resize(cnt)
	bots.resize(cnt)
	for i in cnt:
		var a := alongs[i]
		var half := sqrt(maxf(c2 - a * a, 0.0))
		var bot := center.y - half
		var top := minf(heights[i], center.y + half)
		tops[i] = maxf(top, bot)
		bots[i] = bot
	for i in cnt - 1:
		# Skip a strip only when BOTH edges are degenerate (a single collapsed
		# edge is the chord tip, which must still close the shape).
		if tops[i] - bots[i] < 1e-4 and tops[i + 1] - bots[i + 1] < 1e-4:
			continue
		var v0 := verts.size()
		for k in [i, i + 1]:
			var p := base + along * alongs[k]
			verts.append(Vector3(p.x, bots[k], p.z))
			uv2.append(Vector2(heights[k], 0.0))
			verts.append(Vector3(p.x, tops[k], p.z))
			uv2.append(Vector2(heights[k], 1.0 if tops[k] < center.y + sqrt(maxf(c2 - alongs[k] * alongs[k], 0.0)) - 1e-4 else 0.0))
		# v0 = bottom i, v0+1 = top i, v0+2 = bottom i+1, v0+3 = top i+1
		idx.append_array([v0, v0 + 1, v0 + 3, v0, v0 + 3, v0 + 2])
	if idx.is_empty():
		return null
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(n)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
