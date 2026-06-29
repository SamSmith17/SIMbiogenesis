class_name VegetationCardFactory
extends RefCounted

## Runtime procedural card meshes + foliage materials for pine / deciduous / shrub.

const FOLIAGE_SHADER := preload("res://vegetation/foliage.gdshader")
const BARK_SHADER := preload("res://vegetation/bark.gdshader")
const BAKED_SHRUB_MESH := "res://vegetation/baked/shrub_mesh.tres"
const BAKED_SHRUB_MAT := "res://vegetation/baked/shrub_material.tres"

const SPECS := {
	"pine": {"width": 0.85, "height": 4.5, "trunk_w": 0.24,
		"top": Color(0.05, 0.14, 0.06), "bottom": Color(0.07, 0.10, 0.04),
		"highlight": Color(0.12, 0.24, 0.08),
		"bark": Color(0.16, 0.11, 0.06)},
	"deciduous": {"width": 11.0, "height": 4.5, "trunk_w": 0.45, "trunk_h": 4.5,
		"top": Color(0.18, 0.38, 0.10), "bottom": Color(0.24, 0.16, 0.06),
		"highlight": Color(0.42, 0.52, 0.16),
		"bark": Color(0.18, 0.12, 0.07)},
	"shrub": {"width": 1.4, "height": 1.15,
		"top": Color(0.12, 0.24, 0.08), "bottom": Color(0.16, 0.14, 0.06),
		"highlight": Color(0.28, 0.38, 0.14)},
	"grass_lawn": {"width": 0.55, "height": 0.48,
		"top": Color(0.14, 0.42, 0.12), "bottom": Color(0.10, 0.32, 0.08),
		"highlight": Color(0.28, 0.58, 0.18)},
	"grass_field": {"width": 0.70, "height": 0.95,
		"top": Color(0.38, 0.48, 0.12), "bottom": Color(0.28, 0.36, 0.08),
		"highlight": Color(0.52, 0.58, 0.20)},
}


static func mesh_for_species(species: String, settings: Dictionary = {}) -> ArrayMesh:
	if species == "deciduous":
		return _build_deciduous_mesh(_deciduous_spec(settings), settings)
	if species == "pine":
		return _build_pine_mesh(_pine_spec(settings), settings)
	if species == "shrub":
		return _build_shrub_mesh(_shrub_spec(settings))
	if species == "grass_lawn":
		return _build_grass_mesh(_grass_lawn_spec(settings))
	if species == "grass_field":
		return _build_grass_mesh(_grass_field_spec(settings))
	var spec: Dictionary = SPECS.get(species, SPECS["shrub"])
	return _build_card_mesh(float(spec["width"]), float(spec["height"]))


## True when mesh carries per-surface materials (trunk + foliage surfaces).
static func mesh_has_surface_materials(species: String) -> bool:
	return species == "deciduous" or species == "pine"


static func material_for_species(species: String, settings: Dictionary = {}) -> ShaderMaterial:
	var spec: Dictionary = SPECS.get(species, SPECS["shrub"])
	match species:
		"deciduous":
			spec = _deciduous_spec(settings)
		"pine":
			spec = _pine_spec(settings)
		"shrub":
			spec = _shrub_spec(settings)
		"grass_lawn":
			spec = _grass_lawn_spec(settings)
		"grass_field":
			spec = _grass_field_spec(settings)
	var mat := ShaderMaterial.new()
	mat.shader = FOLIAGE_SHADER
	if species == "deciduous":
		mat.set_shader_parameter("albedo_tex", _build_cluster_foliage_texture(spec, "deciduous"))
	elif species.begins_with("grass_"):
		mat.set_shader_parameter("albedo_tex", _build_grass_blade_texture(spec))
	else:
		mat.set_shader_parameter("albedo_tex", _build_cluster_foliage_texture(spec, species))
	_apply_foliage_uniforms(mat, species, settings)
	return mat


static func bark_material_for_species(species: String, settings: Dictionary = {}) -> ShaderMaterial:
	var spec: Dictionary
	match species:
		"deciduous":
			spec = _deciduous_spec(settings)
		"pine":
			spec = _pine_spec(settings)
		_:
			spec = SPECS.get(species, SPECS["shrub"])
	var mat := ShaderMaterial.new()
	mat.shader = BARK_SHADER
	mat.set_shader_parameter("albedo_tex", _build_bark_texture(spec))
	_apply_bark_uniforms(mat, settings)
	return mat


static func species_bulk_scale(species: String, settings: Dictionary) -> float:
	match species:
		"pine":
			return float(settings.get("pine_bulk_scale", 1.0))
		"deciduous":
			return float(settings.get("deciduous_bulk_scale", 1.35))
		"shrub":
			return float(settings.get("shrub_bulk_scale", 1.0))
		"grass_lawn":
			return float(settings.get("grass_lawn_bulk_scale", 1.0))
		"grass_field":
			return float(settings.get("grass_field_bulk_scale", 1.0))
	return 1.0


static var _foot_cache: Dictionary = {}


static func clear_foot_cache() -> void:
	_foot_cache.clear()


static func foot_local_y(species: String, settings: Dictionary = {}) -> float:
	if species == "deciduous":
		return 0.0
	var key := "%s:%s" % [species, _foot_settings_key(settings)]
	if _foot_cache.has(key):
		return float(_foot_cache[key])
	var mesh := mesh_for_species(species, settings)
	var foot := mesh.get_aabb().position.y if mesh != null else 0.0
	_foot_cache[key] = foot
	return foot


static func _foot_settings_key(settings: Dictionary) -> String:
	if settings.is_empty():
		return "default"
	return "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f" % [
		float(settings.get("deciduous_canopy_w", 11.0)),
		float(settings.get("deciduous_canopy_h", 4.5)),
		float(settings.get("deciduous_trunk_w", 0.45)),
		float(settings.get("deciduous_trunk_h", 4.5)),
		float(settings.get("pine_card_w", 0.85)),
		float(settings.get("pine_card_h", 4.5)),
		float(settings.get("pine_trunk_w", 0.24)),
		float(settings.get("shrub_card_w", 1.4)),
		float(settings.get("shrub_card_h", 1.15)),
		float(settings.get("grass_lawn_card_w", 0.55)),
		float(settings.get("grass_lawn_card_h", 0.48)),
		float(settings.get("grass_field_card_w", 0.70)),
		float(settings.get("grass_field_card_h", 0.95)),
	]


static func _deciduous_spec(settings: Dictionary) -> Dictionary:
	var base: Dictionary = SPECS["deciduous"].duplicate(true)
	base["width"] = float(settings.get("deciduous_canopy_w", base["width"]))
	base["height"] = float(settings.get("deciduous_canopy_h", base["height"]))
	base["trunk_w"] = float(settings.get("deciduous_trunk_w", base["trunk_w"]))
	base["trunk_h"] = float(settings.get("deciduous_trunk_h", base["trunk_h"]))
	return base


static func _pine_spec(settings: Dictionary) -> Dictionary:
	var base: Dictionary = SPECS["pine"].duplicate(true)
	base["width"] = float(settings.get("pine_card_w", base["width"]))
	base["height"] = float(settings.get("pine_card_h", base["height"]))
	base["trunk_w"] = float(settings.get("pine_trunk_w", base["trunk_w"]))
	return base


static func _shrub_spec(settings: Dictionary) -> Dictionary:
	var base: Dictionary = SPECS["shrub"].duplicate(true)
	base["width"] = float(settings.get("shrub_card_w", base["width"]))
	base["height"] = float(settings.get("shrub_card_h", base["height"]))
	return base


static func _grass_lawn_spec(settings: Dictionary) -> Dictionary:
	var base: Dictionary = SPECS["grass_lawn"].duplicate(true)
	base["width"] = float(settings.get("grass_lawn_card_w", base["width"]))
	base["height"] = float(settings.get("grass_lawn_card_h", base["height"]))
	return base


static func _grass_field_spec(settings: Dictionary) -> Dictionary:
	var base: Dictionary = SPECS["grass_field"].duplicate(true)
	base["width"] = float(settings.get("grass_field_card_w", base["width"]))
	base["height"] = float(settings.get("grass_field_card_h", base["height"]))
	return base


static func _build_deciduous_mesh(spec: Dictionary, settings: Dictionary) -> ArrayMesh:
	var trunk_w := float(spec["trunk_w"])
	var trunk_h := float(spec["trunk_h"])
	var crown_w := float(spec["width"])
	var crown_h := float(spec["height"])

	var trunk_verts := PackedVector3Array()
	var trunk_uvs := PackedVector2Array()
	var trunk_normals := PackedVector3Array()
	var trunk_indices := PackedInt32Array()
	for card_i in 2:
		var angle := float(card_i) * PI * 0.5
		_add_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
			trunk_w, trunk_h, 0.0, angle, Vector3(0.0, 0.85, 0.0))

	var collar_h := minf(0.55, crown_h * 0.12)
	var collar_base := maxf(trunk_h - collar_h * 0.65, 0.0)
	for card_i in 2:
		var angle := float(card_i) * PI * 0.5 + PI * 0.25
		_add_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
			trunk_w * 1.35, collar_h, collar_base, angle, Vector3(0.0, 0.75, 0.0))

	var clusters := _deciduous_cluster_layout(crown_w, crown_h, trunk_h)
	for i in clusters.size():
		var c: Dictionary = clusters[i]
		var pos: Vector3 = c["pos"]
		if i > 0 and i < 5:
			_add_branch_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
				Vector3(0.0, trunk_h * 0.82, 0.0),
				pos + Vector3(0.0, -float(c["h"]) * 0.25, 0.0),
				trunk_w * 0.32)

	var canopy_verts := PackedVector3Array()
	var canopy_uvs := PackedVector2Array()
	var canopy_normals := PackedVector3Array()
	var canopy_indices := PackedInt32Array()
	for c in clusters:
		var pos: Vector3 = c["pos"]
		_add_cluster_cards(canopy_verts, canopy_uvs, canopy_normals, canopy_indices,
			pos, float(c["w"]), float(c["h"]), Vector3(0.0, 0.55, 0.0))

	var mesh := ArrayMesh.new()
	var trunk_arr: Array = []
	trunk_arr.resize(Mesh.ARRAY_MAX)
	trunk_arr[Mesh.ARRAY_VERTEX] = trunk_verts
	trunk_arr[Mesh.ARRAY_TEX_UV] = trunk_uvs
	trunk_arr[Mesh.ARRAY_NORMAL] = trunk_normals
	trunk_arr[Mesh.ARRAY_INDEX] = trunk_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arr)
	mesh.surface_set_material(0, bark_material_for_species("deciduous", settings))

	var canopy_arr: Array = []
	canopy_arr.resize(Mesh.ARRAY_MAX)
	canopy_arr[Mesh.ARRAY_VERTEX] = canopy_verts
	canopy_arr[Mesh.ARRAY_TEX_UV] = canopy_uvs
	canopy_arr[Mesh.ARRAY_NORMAL] = canopy_normals
	canopy_arr[Mesh.ARRAY_INDEX] = canopy_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, canopy_arr)
	mesh.surface_set_material(1, material_for_species("deciduous", settings))
	return mesh


static func trunk_mesh_for_forest(settings: Dictionary = {}) -> ArrayMesh:
	var spec := _deciduous_spec(settings)
	var trunk_w := float(spec["trunk_w"])
	var trunk_h := float(spec["trunk_h"]) * 0.85
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for card_i in 2:
		var angle := float(card_i) * PI * 0.5
		_add_card(verts, uvs, normals, indices,
			trunk_w, trunk_h, 0.0, angle, Vector3(0.0, 0.85, 0.0))
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, bark_material_for_species("deciduous", settings))
	return mesh


static func _add_card(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		card_w: float, card_h: float, y_base: float, angle: float, normal_lift: Vector3,
		xz_offset: Vector3 = Vector3.ZERO) -> void:
	var dx := cos(angle) * card_w * 0.5
	var dz := sin(angle) * card_w * 0.5
	var base := verts.size()
	verts.append_array([
		Vector3(-dx, y_base, -dz) + xz_offset, Vector3(dx, y_base, dz) + xz_offset,
		Vector3(dx, y_base + card_h, dz) + xz_offset, Vector3(-dx, y_base + card_h, -dz) + xz_offset,
	])
	uvs.append_array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),
	])
	var card_dir := Vector3(dx, 0.0, dz).normalized()
	var face_perp := Vector3(-card_dir.z, 0.0, card_dir.x)
	var face_normal := (face_perp + normal_lift).normalized()
	for _j in 4:
		normals.append(face_normal)
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


## Three crossed quads at a cluster anchor — circular alpha reads as a foliage puff.
static func _add_cluster_cards(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		center: Vector3, card_w: float, card_h: float, normal_lift: Vector3) -> void:
	var y_base := center.y - card_h * 0.20
	for card_i in 3:
		_add_card(verts, uvs, normals, indices, card_w, card_h, y_base,
			float(card_i) * PI / 3.0, normal_lift, Vector3(center.x, 0.0, center.z))


## Tapered bark card between trunk and a canopy cluster.
static func _add_branch_card(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		base: Vector3, tip: Vector3, width: float) -> void:
	var dir := tip - base
	if dir.length_squared() < 1e-6:
		return
	dir = dir.normalized()
	var side := dir.cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = dir.cross(Vector3.FORWARD)
	side = side.normalized() * width * 0.5
	var idx := verts.size()
	verts.append_array([
		base - side, base + side, tip + side * 0.55, tip - side * 0.55,
	])
	uvs.append_array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),
	])
	var face_normal := side.cross(dir).normalized()
	for _j in 4:
		normals.append(face_normal)
	indices.append_array([idx, idx + 1, idx + 2, idx, idx + 2, idx + 3])


static func _deciduous_cluster_layout(crown_w: float, crown_h: float, trunk_h: float) -> Array:
	var spread := crown_w * 0.45
	var cw := crown_w * 0.30
	var ch := crown_h * 0.40
	var overlap_down := minf(0.25, crown_h * 0.06)
	return [
		{"pos": Vector3(0.0, trunk_h - overlap_down, 0.0), "w": cw * 1.08, "h": ch * 0.95},
		{"pos": Vector3(spread * 0.55, trunk_h + crown_h * 0.10, spread * 0.18), "w": cw, "h": ch},
		{"pos": Vector3(-spread * 0.48, trunk_h + crown_h * 0.08, spread * 0.32), "w": cw, "h": ch},
		{"pos": Vector3(spread * 0.22, trunk_h + crown_h * 0.06, -spread * 0.42), "w": cw, "h": ch},
		{"pos": Vector3(-spread * 0.46, trunk_h + crown_h * 0.14, -spread * 0.20), "w": cw, "h": ch},
		{"pos": Vector3(spread * 0.10, trunk_h + crown_h * 0.48, spread * 0.10), "w": cw * 0.92, "h": ch * 0.95},
		{"pos": Vector3(-spread * 0.16, trunk_h + crown_h * 0.62, -spread * 0.08), "w": cw * 0.86, "h": ch * 0.90},
		{"pos": Vector3(0.0, trunk_h + crown_h * 0.78, 0.0), "w": cw * 0.78, "h": ch * 0.85},
	]


## Whorls taper toward the tip — classic conifer silhouette.
static func _pine_cluster_layout(card_w: float, card_h: float) -> Array:
	var tiers := 7
	var out: Array = []
	for i in tiers:
		var t := float(i) / maxf(float(tiers - 1), 1.0)
		var y := card_h * lerpf(0.20, 0.94, t)
		var w := card_w * lerpf(1.08, 0.30, t)
		var h := card_h * lerpf(0.30, 0.14, t)
		var spread := card_w * lerpf(0.28, 0.04, t)
		var angle := float(i) * 0.72
		var pos := Vector3(cos(angle) * spread, y, sin(angle) * spread * 0.85)
		out.append({"pos": pos, "w": w, "h": h})
	return out


static func _shrub_cluster_layout(card_w: float, card_h: float) -> Array:
	var spread := card_w * 0.38
	return [
		{"pos": Vector3(0.0, card_h * 0.38, 0.0), "w": card_w * 0.92, "h": card_h * 0.88},
		{"pos": Vector3(spread * 0.42, card_h * 0.32, spread * 0.10), "w": card_w * 0.78, "h": card_h * 0.82},
		{"pos": Vector3(-spread * 0.38, card_h * 0.30, spread * 0.14), "w": card_w * 0.76, "h": card_h * 0.80},
		{"pos": Vector3(spread * 0.12, card_h * 0.52, -spread * 0.36), "w": card_w * 0.70, "h": card_h * 0.74},
		{"pos": Vector3(-spread * 0.28, card_h * 0.48, -spread * 0.22), "w": card_w * 0.68, "h": card_h * 0.72},
		{"pos": Vector3(0.0, card_h * 0.62, spread * 0.08), "w": card_w * 0.58, "h": card_h * 0.62},
	]


static func _build_pine_mesh(spec: Dictionary, settings: Dictionary) -> ArrayMesh:
	var card_w := float(spec["width"])
	var card_h := float(spec["height"])
	var trunk_w := float(spec.get("trunk_w", 0.24))
	var trunk_h := card_h * 0.94

	var trunk_verts := PackedVector3Array()
	var trunk_uvs := PackedVector2Array()
	var trunk_normals := PackedVector3Array()
	var trunk_indices := PackedInt32Array()
	for card_i in 2:
		var angle := float(card_i) * PI * 0.5
		_add_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
			trunk_w, trunk_h, 0.0, angle, Vector3(0.0, 0.85, 0.0))

	var foliage_verts := PackedVector3Array()
	var foliage_uvs := PackedVector2Array()
	var foliage_normals := PackedVector3Array()
	var foliage_indices := PackedInt32Array()
	for c in _pine_cluster_layout(card_w, card_h):
		var pos: Vector3 = c["pos"]
		_add_cluster_cards(foliage_verts, foliage_uvs, foliage_normals, foliage_indices,
			pos, float(c["w"]), float(c["h"]), Vector3(0.0, 0.72, 0.0))

	var mesh := ArrayMesh.new()
	var trunk_arr: Array = []
	trunk_arr.resize(Mesh.ARRAY_MAX)
	trunk_arr[Mesh.ARRAY_VERTEX] = trunk_verts
	trunk_arr[Mesh.ARRAY_TEX_UV] = trunk_uvs
	trunk_arr[Mesh.ARRAY_NORMAL] = trunk_normals
	trunk_arr[Mesh.ARRAY_INDEX] = trunk_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arr)
	mesh.surface_set_material(0, bark_material_for_species("pine", settings))

	var foliage_arr: Array = []
	foliage_arr.resize(Mesh.ARRAY_MAX)
	foliage_arr[Mesh.ARRAY_VERTEX] = foliage_verts
	foliage_arr[Mesh.ARRAY_TEX_UV] = foliage_uvs
	foliage_arr[Mesh.ARRAY_NORMAL] = foliage_normals
	foliage_arr[Mesh.ARRAY_INDEX] = foliage_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, foliage_arr)
	mesh.surface_set_material(1, material_for_species("pine", settings))
	return mesh


static func _build_shrub_mesh(spec: Dictionary) -> ArrayMesh:
	var card_w := float(spec["width"])
	var card_h := float(spec["height"])
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for c in _shrub_cluster_layout(card_w, card_h):
		var pos: Vector3 = c["pos"]
		_add_cluster_cards(verts, uvs, normals, indices,
			pos, float(c["w"]), float(c["h"]), Vector3(0.0, 0.65, 0.0))
	return _arrays_to_mesh(verts, uvs, normals, indices)


static func _build_grass_mesh(spec: Dictionary) -> ArrayMesh:
	var card_w := float(spec["width"])
	var card_h := float(spec["height"])
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for card_i in 5:
		_add_card(verts, uvs, normals, indices,
			card_w, card_h, 0.0, float(card_i) * TAU / 5.0, Vector3(0.0, 0.15, 0.0))
	return _arrays_to_mesh(verts, uvs, normals, indices)


static func _build_grass_blade_texture(spec: Dictionary) -> Texture2D:
	var w := 32
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var bottom: Color = spec["bottom"]
	var top: Color = spec["top"]
	var highlight: Color = spec["highlight"]
	for y in h:
		for x in w:
			var nx := (float(x) + 0.5) / float(w) - 0.5
			var ny := float(y) / float(h)
			var half_w := (0.44 - ny * 0.30) * 0.5
			if absf(nx) > half_w:
				continue
			var edge := 1.0 - smoothstep(half_w * 0.65, half_w, absf(nx))
			var base := bottom.lerp(top, ny)
			var lit := base.lerp(highlight, smoothstep(0.5, 1.0, ny) * 0.42)
			lit.a = edge * (0.88 + ny * 0.12)
			img.set_pixel(x, y, lit)
	img.flip_y()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _arrays_to_mesh(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array) -> ArrayMesh:
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func _build_card_mesh(card_w: float, card_h: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for card_i in 3:
		_add_card(verts, uvs, normals, indices, card_w, card_h, 0.0,
			float(card_i) * PI / 3.0, Vector3(0.0, 0.7, 0.0))
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func _build_bark_texture(spec: Dictionary) -> Texture2D:
	var size := 128
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var bark: Color = spec.get("bark", Color(0.18, 0.12, 0.07))
	var shadow := Color(0.02, 0.02, 0.015)
	var n := FastNoiseLite.new()
	n.seed = "bark".hash()
	n.frequency = 0.12
	var half := float(size) * 0.5
	for y in size:
		for x in size:
			var nx := absf((float(x) - half) / half)
			var v := float(y) / float(size)
			if nx > 0.22:
				continue
			var ncol := (n.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			var c := bark.lerp(shadow, v * 0.4 + ncol * 0.15)
			c.a = 1.0 if nx < 0.18 else smoothstep(0.22, 0.18, nx)
			if c.a > 0.05:
				img.set_pixel(x, y, c)
	img.flip_y()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _build_cluster_foliage_texture(spec: Dictionary, species: String) -> Texture2D:
	var size := 128 if species != "deciduous" else 160
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var n_shape := FastNoiseLite.new()
	n_shape.seed = species.hash()
	n_shape.frequency = 0.055
	var n_color := FastNoiseLite.new()
	n_color.seed = species.hash() + 17
	n_color.frequency = 0.11
	var top_color: Color = spec["top"]
	var bottom_color: Color = spec["bottom"]
	var highlight: Color = spec["highlight"]
	var shadow := Color(0.02, 0.04, 0.015)
	var circles: Array = _foliage_texture_circles(species)
	var half := float(size)
	for y in size:
		for x in size:
			var px := (float(x) + 0.5) / half
			var py := (float(y) + 0.5) / half
			var alpha := 0.0
			for c in circles:
				var cd: Dictionary = c
				var dx := px - float(cd["cx"])
				var dy := py - float(cd["cy"])
				var r := float(cd["r"])
				var dist := sqrt(dx * dx + dy * dy) / maxf(r, 0.01)
				var blob := clampf(1.0 - dist, 0.0, 1.0)
				var n := (n_shape.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
				var edge := smoothstep(0.42, 0.78, blob * (0.62 + n * 0.55))
				alpha = maxf(alpha, edge)
			if alpha < 0.03:
				continue
			var v := py
			var brown_t := clampf((v - 0.35) / 0.65, 0.0, 1.0)
			var base := top_color.lerp(bottom_color, brown_t * 0.22)
			var ncol := (n_color.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			var lit := base.lerp(highlight, smoothstep(0.45, 0.95, ncol) * 0.58)
			var final := lit.lerp(shadow, brown_t * 0.16)
			final.a = alpha
			img.set_pixel(x, y, final)
	img.flip_y()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _foliage_texture_circles(species: String) -> Array:
	match species:
		"deciduous":
			return [
				{"cx": 0.50, "cy": 0.48, "r": 0.36},
				{"cx": 0.30, "cy": 0.56, "r": 0.24},
				{"cx": 0.70, "cy": 0.52, "r": 0.22},
				{"cx": 0.46, "cy": 0.34, "r": 0.18},
			]
		"pine":
			return [
				{"cx": 0.50, "cy": 0.46, "r": 0.40},
				{"cx": 0.34, "cy": 0.54, "r": 0.22},
				{"cx": 0.66, "cy": 0.50, "r": 0.18},
				{"cx": 0.48, "cy": 0.30, "r": 0.14},
			]
		"grass_lawn", "grass_field":
			return [
				{"cx": 0.50, "cy": 0.62, "r": 0.22},
				{"cx": 0.42, "cy": 0.48, "r": 0.14},
				{"cx": 0.58, "cy": 0.50, "r": 0.12},
			]
		"shrub":
			return [
				{"cx": 0.50, "cy": 0.50, "r": 0.36},
				{"cx": 0.32, "cy": 0.44, "r": 0.20},
				{"cx": 0.68, "cy": 0.46, "r": 0.18},
				{"cx": 0.44, "cy": 0.62, "r": 0.14},
			]
		_:
			return [
				{"cx": 0.50, "cy": 0.50, "r": 0.32},
				{"cx": 0.34, "cy": 0.44, "r": 0.18},
				{"cx": 0.66, "cy": 0.46, "r": 0.16},
			]


static func _build_deciduous_canopy_texture(spec: Dictionary) -> Texture2D:
	return _build_cluster_foliage_texture(spec, "deciduous")


static func _build_deciduous_texture(spec: Dictionary) -> Texture2D:
	return _build_cluster_foliage_texture(spec, "deciduous")


static func _build_texture(spec: Dictionary, species: String) -> Texture2D:
	return _build_cluster_foliage_texture(spec, species)


static func _apply_foliage_uniforms(mat: ShaderMaterial, species: String, settings: Dictionary) -> void:
	var known := ["pine", "deciduous", "shrub", "grass_lawn", "grass_field"]
	var prefix := species if species in known else "deciduous"
	var spec: Dictionary = SPECS.get(prefix, SPECS["shrub"])
	var tint: Color = settings.get("%s_albedo_tint" % prefix, Color.WHITE)
	if tint == Color.WHITE:
		tint = spec["top"].lerp(Color.WHITE, 0.0)
	mat.set_shader_parameter("albedo_tint", Vector3(tint.r, tint.g, tint.b))
	var hi: Color = settings.get("%s_highlight_tint" % prefix, spec["highlight"])
	mat.set_shader_parameter("highlight_tint", Vector3(hi.r, hi.g, hi.b))
	mat.set_shader_parameter("wind_strength", float(settings.get("wind_strength", 0.03)))
	mat.set_shader_parameter("sway_frequency", float(settings.get("wind_speed", 0.7)))
	mat.set_shader_parameter("wind_profile", _wind_profile_for_species(prefix))
	mat.set_shader_parameter("dither_strength", float(settings.get("dither_strength", 1.0)))
	mat.set_shader_parameter("alpha_dither_min", float(settings.get("alpha_dither_min", 0.20)))
	mat.set_shader_parameter("alpha_dither_max", float(settings.get("alpha_dither_max", 0.50)))
	mat.set_shader_parameter("trunk_uv_cutoff", float(settings.get("trunk_uv_cutoff", 0.0)))
	mat.set_shader_parameter("near_crisp_m", float(settings.get("near_crisp_m", 40.0)))
	mat.set_shader_parameter("far_dither_m", float(settings.get("far_dither_m", 120.0)))
	mat.set_shader_parameter("haze_strength", float(settings.get("haze_strength", 0.65)))
	mat.set_shader_parameter("lean_amount", float(settings.get("lean_amount", 0.30)))
	mat.set_shader_parameter("subsurface_strength", float(settings.get("subsurface_strength", 0.15)))
	mat.set_shader_parameter("hue_jitter", float(settings.get("hue_jitter", 0.0)))
	mat.set_shader_parameter("seasonal_strength", float(settings.get("seasonal_strength", 0.0)))
	if settings.has("haze_color"):
		var hc: Color = settings["haze_color"]
		mat.set_shader_parameter("haze_color", Vector3(hc.r, hc.g, hc.b))
	if settings.has("seasonal_tint"):
		var st: Color = settings["seasonal_tint"]
		mat.set_shader_parameter("seasonal_tint", Vector3(st.r, st.g, st.b))
	if settings.has("drape_tex") and settings["drape_tex"] is Texture2D:
		mat.set_shader_parameter("drape_tex", settings["drape_tex"])
		mat.set_shader_parameter("use_drape", true)
		mat.set_shader_parameter("drape_extent_m", float(settings.get("drape_extent_m", 30000.0)))
		mat.set_shader_parameter("drape_match_strength", float(settings.get("drape_match_strength", 0.0)))
	if prefix.begins_with("grass_"):
		mat.set_shader_parameter("near_crisp_m", 100.0)
		mat.set_shader_parameter("far_dither_m", 250.0)
		mat.set_shader_parameter("dither_strength", 0.22)
		mat.set_shader_parameter("alpha_dither_min", 0.08)
		mat.set_shader_parameter("alpha_dither_max", 0.24)
		mat.set_shader_parameter("subsurface_strength", maxf(
			float(settings.get("subsurface_strength", 0.15)), 0.42))
		mat.set_shader_parameter("lean_amount", 0.06)
		mat.set_shader_parameter("haze_strength", 0.35)


static func _wind_profile_for_species(species: String) -> float:
	match species:
		"pine":
			return 0.0
		"deciduous":
			return 1.0
		"shrub":
			return 2.0
		"grass_lawn", "grass_field":
			return 3.0
	return 1.0


static func _apply_bark_uniforms(mat: ShaderMaterial, settings: Dictionary) -> void:
	mat.set_shader_parameter("wind_strength", float(settings.get("wind_strength", 0.03)) * 0.3)
	mat.set_shader_parameter("sway_frequency", float(settings.get("wind_speed", 0.7)))
	mat.set_shader_parameter("wind_profile", 0.15)
	if settings.has("bark_albedo_tint"):
		var c: Color = settings["bark_albedo_tint"]
		mat.set_shader_parameter("albedo_tint", Vector3(c.r, c.g, c.b))
