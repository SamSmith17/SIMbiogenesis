class_name VegetationCardFactory
extends RefCounted

## Runtime procedural card meshes + foliage materials for pine / deciduous / shrub.

const FOLIAGE_SHADER := preload("res://vegetation/foliage.gdshader")
const LEAF_CANOPY_SHADER := preload("res://vegetation/leaf_canopy.gdshader")
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


## Canopy LOD tiers — deciduous: NEAR = leaf shells, FAR = billboards.
## Pine: same whorl geometry both tiers; NEAR = furry billboards, FAR = plain.
enum CanopyLodTier { NEAR, FAR }
## Back-compat alias for existing call sites.
const DeciduousLodTier = CanopyLodTier


static func mesh_for_species(species: String, settings: Dictionary = {}) -> ArrayMesh:
	if species == "deciduous":
		return mesh_for_deciduous_lod(settings, CanopyLodTier.NEAR)
	if species == "pine":
		return mesh_for_pine_lod(settings, CanopyLodTier.NEAR)
	if species == "shrub":
		return _build_shrub_mesh(_shrub_spec(settings), settings)
	if species == "grass_lawn":
		return _build_grass_mesh(_grass_lawn_spec(settings))
	if species == "grass_field":
		return _build_grass_mesh(_grass_field_spec(settings))
	var spec: Dictionary = SPECS.get(species, SPECS["shrub"])
	return _build_card_mesh(float(spec["width"]), float(spec["height"]))


## True when mesh carries per-surface materials (trunk + foliage surfaces).
static func mesh_has_surface_materials(species: String) -> bool:
	return species == "deciduous" or species == "pine"


## NEAR = procedural leaf shells; FAR = legacy crossed-billboard canopy.
static func mesh_for_deciduous_lod(settings: Dictionary, tier: CanopyLodTier) -> ArrayMesh:
	var s := settings.duplicate(true)
	s["deciduous_leaf_shells_enabled"] = tier == CanopyLodTier.NEAR
	return _build_deciduous_mesh(_deciduous_spec(s), s)


static func mesh_for_pine_lod(settings: Dictionary, tier: CanopyLodTier) -> ArrayMesh:
	var s := settings.duplicate(true)
	s["pine_fur_enabled"] = tier == CanopyLodTier.NEAR
	return _build_pine_mesh(_pine_spec(s), s)


static func canopy_visibility_range_for_tier(species: String, tier: CanopyLodTier,
		settings: Dictionary, far_end_m: float) -> Vector2:
	var prefix := "deciduous" if species == "deciduous" else "pine"
	var near_end := float(settings.get("%s_lod_near_m" % prefix,
		settings.get("deciduous_lod_near_m", 200.0)))
	var far_begin := float(settings.get("%s_lod_far_begin_m" % prefix,
		settings.get("deciduous_lod_far_begin_m", 190.0)))
	# Keep the near (leaf/fur) and far (billboard) tiers overlapping: if the two
	# independent sliders cross so far_begin > near_end, there is a dead band where
	# neither tier draws (trees pop to a bare/billboard look mid-range). Clamp the
	# billboard start to just inside the leaf end so the crossfade is continuous.
	far_begin = minf(far_begin, near_end)
	match tier:
		CanopyLodTier.NEAR:
			return Vector2(0.0, near_end)
		_:
			return Vector2(far_begin, maxf(far_end_m, near_end))


static func deciduous_visibility_range_for_tier(tier: CanopyLodTier,
		settings: Dictionary, far_end_m: float) -> Vector2:
	return canopy_visibility_range_for_tier("deciduous", tier, settings, far_end_m)


static func pine_visibility_range_for_tier(tier: CanopyLodTier,
		settings: Dictionary, far_end_m: float) -> Vector2:
	return canopy_visibility_range_for_tier("pine", tier, settings, far_end_m)


static func deciduous_lod_enabled(settings: Dictionary) -> bool:
	return bool(settings.get("deciduous_leaf_lod_enabled", true))


static func pine_lod_enabled(settings: Dictionary) -> bool:
	if settings.has("pine_fur_lod_enabled"):
		return bool(settings.get("pine_fur_lod_enabled", true))
	return bool(settings.get("pine_needle_lod_enabled", true))


static func canopy_lod_enabled(species: String, settings: Dictionary) -> bool:
	if species == "deciduous":
		return deciduous_lod_enabled(settings)
	if species == "pine":
		return pine_lod_enabled(settings)
	return false


static func mesh_for_canopy_lod(species: String, settings: Dictionary, tier: CanopyLodTier) -> ArrayMesh:
	if species == "deciduous":
		return mesh_for_deciduous_lod(settings, tier)
	if species == "pine":
		return mesh_for_pine_lod(settings, tier)
	return mesh_for_species(species, settings)


static func _configure_cutout_shadow(_mat: ShaderMaterial, _threshold: float = 0.35) -> void:
	# Alpha scissor + shadow clipping is handled in the shader render_mode
	# (ShaderMaterial has no BaseMaterial3D.transparency property in Godot 4).
	pass


static func _configure_foliage_cutout_shadow(mat: ShaderMaterial) -> void:
	_configure_cutout_shadow(mat, 0.35)


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
	_configure_foliage_cutout_shadow(mat)
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
	return "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f" % [
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
		_add_tapered_trunk_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
			trunk_w, trunk_h, 0.0, angle, Vector3(0.0, 0.85, 0.0),
			_trunk_taper_top(settings, "deciduous"))

	var collar_h := minf(0.55, crown_h * 0.12)
	var collar_base := maxf(trunk_h - collar_h * 0.65, 0.0)
	for card_i in 2:
		var angle := float(card_i) * PI * 0.5 + PI * 0.25
		_add_tapered_trunk_card(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
			trunk_w * 1.35, collar_h, collar_base, angle, Vector3(0.0, 0.75, 0.0),
			_trunk_taper_top(settings, "deciduous"), Vector3.ZERO, trunk_w * 0.72)

	var clusters := _deciduous_cluster_layout(crown_w, crown_h, trunk_h, settings)
	# Fractal bough skeleton: self-similar forks fill the crown so the tree reads
	# as a real branching structure once the leaf shells drop in winter.
	_build_fractal_branches(trunk_verts, trunk_uvs, trunk_normals, trunk_indices,
		trunk_w, trunk_h, crown_w, crown_h, settings)

	var mesh := ArrayMesh.new()
	var trunk_arr: Array = []
	trunk_arr.resize(Mesh.ARRAY_MAX)
	trunk_arr[Mesh.ARRAY_VERTEX] = trunk_verts
	trunk_arr[Mesh.ARRAY_TEX_UV] = trunk_uvs
	trunk_arr[Mesh.ARRAY_NORMAL] = trunk_normals
	trunk_arr[Mesh.ARRAY_INDEX] = trunk_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arr)
	mesh.surface_set_material(0, bark_material_for_species("deciduous", settings))

	# Canopy: optional billboard shadow proxy (casts crown silhouette) + leaf shells on top.
	if bool(settings.get("deciduous_leaf_shells_enabled", true)):
		if bool(settings.get("deciduous_shadow_proxy_enabled", true)):
			var proxy_scale := float(settings.get("deciduous_shadow_proxy_scale", 1.06))
			var proxy_verts := PackedVector3Array()
			var proxy_uvs := PackedVector2Array()
			var proxy_normals := PackedVector3Array()
			var proxy_indices := PackedInt32Array()
			for c in clusters:
				var pos: Vector3 = c["pos"]
				_add_cluster_cards(proxy_verts, proxy_uvs, proxy_normals, proxy_indices,
					pos, float(c["w"]) * proxy_scale, float(c["h"]) * proxy_scale,
					Vector3(0.0, 0.55, 0.0))
			var proxy_arr: Array = []
			proxy_arr.resize(Mesh.ARRAY_MAX)
			proxy_arr[Mesh.ARRAY_VERTEX] = proxy_verts
			proxy_arr[Mesh.ARRAY_TEX_UV] = proxy_uvs
			proxy_arr[Mesh.ARRAY_NORMAL] = proxy_normals
			proxy_arr[Mesh.ARRAY_INDEX] = proxy_indices
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, proxy_arr)
			var proxy_mat := _deciduous_shadow_proxy_material(settings)
			mesh.surface_set_material(1, proxy_mat)
		var shell_arr := _build_leaf_shell_canopy(crown_w, crown_h, trunk_h, settings)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, shell_arr)
		var leaf_mat := leaf_canopy_material_for_species("deciduous", settings)
		leaf_mat.render_priority = 1
		mesh.surface_set_material(mesh.get_surface_count() - 1, leaf_mat)
		return mesh

	var canopy_verts := PackedVector3Array()
	var canopy_uvs := PackedVector2Array()
	var canopy_normals := PackedVector3Array()
	var canopy_indices := PackedInt32Array()
	for c in clusters:
		var pos: Vector3 = c["pos"]
		_add_cluster_cards(canopy_verts, canopy_uvs, canopy_normals, canopy_indices,
			pos, float(c["w"]), float(c["h"]), Vector3(0.0, 0.55, 0.0))

	var canopy_arr: Array = []
	canopy_arr.resize(Mesh.ARRAY_MAX)
	canopy_arr[Mesh.ARRAY_VERTEX] = canopy_verts
	canopy_arr[Mesh.ARRAY_TEX_UV] = canopy_uvs
	canopy_arr[Mesh.ARRAY_NORMAL] = canopy_normals
	canopy_arr[Mesh.ARRAY_INDEX] = canopy_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, canopy_arr)
	mesh.surface_set_material(1, material_for_species("deciduous", settings))
	return mesh


## Nested lumpy ellipsoid shells wrapping the crown. Each vertex stores the
## crown-radial unit direction in NORMAL (reused for lighting + the fragment leaf
## grid), COLOR.r = shell depth (0 inner .. 1 outer), COLOR.g = normalized tree
## height (for wind). Stacked shells + per-shell leaf gaps read as a volumetric
## canopy of discrete leaves (see leaf_canopy.gdshader).
static func _build_leaf_shell_canopy(crown_w: float, crown_h: float, trunk_h: float,
		settings: Dictionary) -> Array:
	var shells := clampi(int(round(float(settings.get("deciduous_leaf_shell_count", 4)))), 2, 10)
	var lump := clampf(float(settings.get("deciduous_leaf_lump", 0.18)), 0.0, 0.6)
	var rings := 5
	var segs := 10
	var inner_frac := 0.6
	var rx := crown_w * 0.42
	var ry := crown_h * 0.62
	var rz := rx
	var center_y := trunk_h + crown_h * 0.35
	var total_h := maxf(trunk_h + crown_h, 0.001)

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var row_stride := segs + 1

	for s in shells:
		var st := float(s) / maxf(float(shells - 1), 1.0)
		var scale := lerpf(inner_frac, 1.0, st)
		var base := verts.size()
		for iy in rings + 1:
			var theta := PI * float(iy) / float(rings)
			var sin_t := sin(theta)
			var cos_t := cos(theta)
			for ix in segs + 1:
				var phi := TAU * float(ix) / float(segs)
				var dir := Vector3(sin_t * cos(phi), cos_t, sin_t * sin(phi))
				# Organic lumpy silhouette, identical per direction across shells
				# so the shells stay nested (radial displacement scales with shell).
				var bump := 1.0 + lump * (
					sin(dir.x * 5.1 + dir.y * 3.3) * 0.5
					+ sin(dir.z * 4.7 - dir.y * 2.9) * 0.5)
				var pos := Vector3(
					dir.x * rx, dir.y * ry, dir.z * rz) * scale * bump
				pos.y += center_y
				verts.append(pos)
				normals.append(dir)
				uvs.append(Vector2(phi / TAU, theta / PI))
				colors.append(Color(st, clampf(pos.y / total_h, 0.0, 1.0), 0.0, 1.0))
		for iy in rings:
			for ix in segs:
				var a := base + iy * row_stride + ix
				var b := a + 1
				var c := a + row_stride
				var d := c + 1
				indices.append_array([a, c, b, b, c, d])

	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	return arr


static func _deciduous_shadow_proxy_material(settings: Dictionary) -> ShaderMaterial:
	var s := settings.duplicate(true)
	s["deciduous_color_fade"] = float(settings.get("deciduous_shadow_proxy_visibility", 0.04))
	var mat := material_for_species("deciduous", s)
	mat.render_priority = 0
	return mat


static func leaf_canopy_material_for_species(species: String, settings: Dictionary = {}) -> ShaderMaterial:
	var spec: Dictionary
	match species:
		"deciduous":
			spec = _deciduous_spec(settings)
		_:
			spec = SPECS.get(species, SPECS["shrub"])
	var mat := ShaderMaterial.new()
	mat.shader = LEAF_CANOPY_SHADER
	_apply_leaf_canopy_uniforms(mat, species, spec, settings)
	_configure_cutout_shadow(mat, 0.35)
	return mat


static func _apply_leaf_canopy_uniforms(mat: ShaderMaterial, species: String,
		spec: Dictionary, settings: Dictionary) -> void:
	var top: Color = spec["top"]
	var tint: Color = settings.get("%s_albedo_tint" % species, Color.WHITE)
	var hi: Color = settings.get("%s_highlight_tint" % species, spec.get("highlight", Color(0.42, 0.52, 0.16)))
	mat.set_shader_parameter("canopy_profile", 0)
	mat.set_shader_parameter("leaf_color", Vector3(top.r, top.g, top.b))
	mat.set_shader_parameter("leaf_shadow", Vector3(top.r * 0.32, top.g * 0.34, top.b * 0.30))
	mat.set_shader_parameter("albedo_tint", Vector3(tint.r, tint.g, tint.b))
	mat.set_shader_parameter("highlight_tint", Vector3(hi.r, hi.g, hi.b))
	mat.set_shader_parameter("wind_strength", float(settings.get("wind_strength", 0.03)))
	mat.set_shader_parameter("sway_frequency", float(settings.get("wind_speed", 0.7)))
	mat.set_shader_parameter("wind_profile", 1.0)
	mat.set_shader_parameter("cells_per_side", float(settings.get("deciduous_leaf_density", 22.0)))
	mat.set_shader_parameter("leaf_size", float(settings.get("deciduous_leaf_size", 0.85)))
	mat.set_shader_parameter("leaf_aspect", float(settings.get("deciduous_leaf_aspect", 1.9)))
	mat.set_shader_parameter("shell_gap", float(settings.get("deciduous_leaf_gap", 0.30)))
	mat.set_shader_parameter("dither_strength", float(settings.get("dither_strength", 1.0)))
	mat.set_shader_parameter("alpha_dither_min", float(settings.get("alpha_dither_min", 0.20)))
	mat.set_shader_parameter("alpha_dither_max", float(settings.get("alpha_dither_max", 0.50)))
	mat.set_shader_parameter("near_crisp_m", float(settings.get("near_crisp_m", 40.0)))
	mat.set_shader_parameter("far_dither_m", float(settings.get("far_dither_m", 120.0)))
	mat.set_shader_parameter("haze_strength", float(settings.get("haze_strength", 0.65)))
	mat.set_shader_parameter("subsurface_strength", float(settings.get("subsurface_strength", 0.15)))
	mat.set_shader_parameter("translucency_strength", float(settings.get("translucency_strength", 0.25)))
	mat.set_shader_parameter("color_variation", float(settings.get("color_variation", 0.12)))
	mat.set_shader_parameter("roughness_value", float(settings.get("foliage_roughness", 0.95)))
	mat.set_shader_parameter("ao_strength", float(settings.get("ao_strength", 0.40)))
	mat.set_shader_parameter("hue_jitter", float(settings.get("hue_jitter", 0.0)))
	if settings.has("ao_tint"):
		var aoc: Color = settings["ao_tint"]
		mat.set_shader_parameter("ao_tint", Vector3(aoc.r, aoc.g, aoc.b))
	if settings.has("haze_color"):
		var hc: Color = settings["haze_color"]
		mat.set_shader_parameter("haze_color", Vector3(hc.r, hc.g, hc.b))


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


static func _trunk_taper_top(settings: Dictionary, species: String) -> float:
	var key := "%s_trunk_taper" % species
	var default := 0.42 if species == "deciduous" else 0.38
	return clampf(float(settings.get(key, default)), 0.12, 1.0)


static func _add_tapered_trunk_card(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		card_w_base: float, card_h: float, y_base: float, angle: float, normal_lift: Vector3,
		taper_top: float, xz_offset: Vector3 = Vector3.ZERO, card_w_top: float = -1.0) -> void:
	var w_top := card_w_top if card_w_top > 0.0 else card_w_base * taper_top
	var dx_b := cos(angle) * card_w_base * 0.5
	var dz_b := sin(angle) * card_w_base * 0.5
	var dx_t := cos(angle) * w_top * 0.5
	var dz_t := sin(angle) * w_top * 0.5
	var base := verts.size()
	verts.append_array([
		Vector3(-dx_b, y_base, -dz_b) + xz_offset,
		Vector3(dx_b, y_base, dz_b) + xz_offset,
		Vector3(dx_t, y_base + card_h, dz_t) + xz_offset,
		Vector3(-dx_t, y_base + card_h, -dz_t) + xz_offset,
	])
	uvs.append_array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),
	])
	var card_dir := Vector3(dx_b, 0.0, dz_b).normalized()
	var face_perp := Vector3(-card_dir.z, 0.0, card_dir.x)
	var face_normal := (face_perp + normal_lift).normalized()
	for _j in 4:
		normals.append(face_normal)
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


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
		center: Vector3, card_w: float, card_h: float, normal_lift: Vector3,
		base_yaw: float = 0.0, card_count: int = 3) -> void:
	var y_base := center.y - card_h * 0.20
	var n := clampi(card_count, 2, 4)
	for card_i in n:
		_add_card(verts, uvs, normals, indices, card_w, card_h, y_base,
			float(card_i) * TAU / float(n) + base_yaw, normal_lift,
			Vector3(center.x, 0.0, center.z))


## Deterministic seed for the fractal branch skeleton, so identical settings always
## build the identical tree (the mesh is shared across every MultiMesh instance).
const _BRANCH_SEED := 0x2f9a37

## Recursive fractal branch skeleton for deciduous trees. Real trees follow a
## self-similar fork pattern — a trunk splits into primaries, each of which splits
## again into smaller boughs, recursively — so the crown reads as a believable
## bare structure in winter when the leaf shells drop out (leaf_canopy.gdshader
## discards foliage as leaf_coverage falls). Returns bark geometry appended into
## the passed arrays, plus a list of tip Vector3 positions (leaf anchors for the
## caller). Curvature (gnarl) + gravitropism (droop) bend each bough so the
## silhouette avoids the "straight sticks" look.
##
## Cost is bounded by levels + children: e.g. 5 primaries × Σ children^k over
## `levels` levels. Defaults stay well under ~250 segments (a few hundred quads on
## the shared mesh), so per-instance cost is unchanged (MultiMesh reuses one mesh).
static func _build_fractal_branches(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		trunk_w: float, trunk_h: float, crown_w: float, crown_h: float,
		settings: Dictionary) -> Array:
	var levels := clampi(int(round(float(settings.get("deciduous_branch_levels", 4)))), 1, 5)
	var primaries := clampi(int(round(float(settings.get("deciduous_branch_count", 5)))), 2, 12)
	var children := clampi(int(round(float(settings.get("deciduous_branch_split", 3)))), 2, 4)
	var thick := maxf(float(settings.get("deciduous_branch_thickness", 1.0)), 0.05)
	var reach := maxf(float(settings.get("deciduous_branch_reach", 1.0)), 0.2)
	var base_frac := clampf(float(settings.get("deciduous_branch_base", 0.82)), 0.2, 1.0)
	var fork_deg := clampf(float(settings.get("deciduous_branch_angle", 38.0)), 8.0, 75.0)
	var len_ratio := clampf(float(settings.get("deciduous_branch_length_ratio", 0.72)), 0.45, 0.92)
	var droop := clampf(float(settings.get("deciduous_branch_droop", 0.12)), -0.6, 0.6)
	var gnarl := clampf(float(settings.get("deciduous_branch_gnarl", 0.22)), 0.0, 1.0)

	var rng := RandomNumberGenerator.new()
	rng.seed = _BRANCH_SEED
	var tips: Array = []
	var start_y := trunk_h * base_frac
	var primary_len := crown_h * 0.55 * reach
	var primary_w := trunk_w * 0.60 * thick
	for i in primaries:
		var t := float(i) / maxf(float(primaries), 1.0)
		# Bases march up the upper trunk; lower forks tilt outward, higher ones
		# reach up — the classic vase/oak crown spread.
		var by := lerpf(start_y, trunk_h * 1.03, t)
		var az := float(i) * TAU * 0.618034 + rng.randf() * 0.6
		var out_tilt := deg_to_rad(lerpf(58.0, 28.0, t))
		var dir := Vector3(cos(az) * sin(out_tilt), cos(out_tilt), sin(az) * sin(out_tilt)).normalized()
		var plen := primary_len * lerpf(1.0, 0.68, t)
		var pw := primary_w * lerpf(1.0, 0.72, t)
		_grow_branch(verts, uvs, normals, indices, tips,
			Vector3(0.0, by, 0.0), dir, plen, pw, 1, levels, children,
			fork_deg, len_ratio, droop, gnarl, rng)
	return tips


## Grow one bough (a gently curved, tapering limb) then recursively fork children
## off its tip. `level` counts from 1 (primary) up to `max_level`.
static func _grow_branch(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array, tips: Array,
		base: Vector3, dir: Vector3, length: float, width: float,
		level: int, max_level: int, children: int, fork_deg: float,
		len_ratio: float, droop: float, gnarl: float, rng: RandomNumberGenerator) -> void:
	# Subdivide the limb into curved sub-segments so gnarl/droop bend it smoothly.
	var sub := 3 if level <= 2 else 2
	var p := base
	var d := dir
	var seg_len := length / float(sub)
	for k in sub:
		# Random gnarl wobble + gravitropism (droop>0 lifts toward sky, <0 sags).
		var axis := Vector3(rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0,
			rng.randf() * 2.0 - 1.0)
		if axis.length_squared() > 1e-6:
			d = d.rotated(axis.normalized(), (rng.randf() * 2.0 - 1.0) * gnarl * 0.5)
		d = (d + Vector3.UP * droop * 0.18).normalized()
		var np := p + d * seg_len
		var w0 := width * (1.0 - float(k) / float(sub) * 0.35)
		var w1 := width * (1.0 - float(k + 1) / float(sub) * 0.35)
		_add_branch_segment(verts, uvs, normals, indices, p, np, maxf(w0, 0.02), maxf(w1, 0.015))
		p = np
	if level >= max_level:
		tips.append(p)
		return
	# Fork: rotate the parent dir out by fork_deg to form a cone, then spin each
	# child around the parent axis (golden-ish spacing + jitter). A child count of
	# 2 gives a Y-fork; 3–4 gives a bushier crown.
	var n := maxi(children, 2)
	var perp := d.cross(Vector3.UP)
	if perp.length_squared() < 1e-6:
		perp = d.cross(Vector3.RIGHT)
	perp = perp.normalized()
	for c in n:
		var az := float(c) / float(n) * TAU + rng.randf() * 0.8
		var spread := deg_to_rad(fork_deg * lerpf(0.7, 1.2, rng.randf()))
		var child := d.rotated(perp, spread).rotated(d, az)
		_grow_branch(verts, uvs, normals, indices, tips, p, child.normalized(),
			length * len_ratio, width * len_ratio, level + 1, max_level, children,
			fork_deg, len_ratio, droop, gnarl, rng)


## A limb segment as two perpendicular tapered quads (a cheap "tube") so a bough
## reads as solid bark from any view angle, not a flat card.
static func _add_branch_segment(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		a: Vector3, b: Vector3, w0: float, w1: float) -> void:
	var dir := b - a
	if dir.length_squared() < 1e-8:
		return
	dir = dir.normalized()
	var side1 := dir.cross(Vector3.UP)
	if side1.length_squared() < 1e-6:
		side1 = dir.cross(Vector3.RIGHT)
	side1 = side1.normalized()
	var side2 := dir.cross(side1).normalized()
	_add_branch_quad(verts, uvs, normals, indices, a, b, w0, w1, side1)
	_add_branch_quad(verts, uvs, normals, indices, a, b, w0, w1, side2)


static func _add_branch_quad(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		a: Vector3, b: Vector3, w0: float, w1: float, side: Vector3) -> void:
	var s0 := side * (w0 * 0.5)
	var s1 := side * (w1 * 0.5)
	var idx := verts.size()
	verts.append_array([a - s0, a + s0, b + s1, b - s1])
	uvs.append_array([Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0)])
	var nrm := side.cross(b - a).normalized()
	for _j in 4:
		normals.append(nrm)
	indices.append_array([idx, idx + 1, idx + 2, idx, idx + 2, idx + 3])


static func _deciduous_cluster_layout(crown_w: float, crown_h: float, trunk_h: float,
		settings: Dictionary = {}) -> Array:
	var count := clampi(int(round(float(settings.get("deciduous_cluster_count", 8)))), 3, 16)
	var spread_mul := float(settings.get("deciduous_cluster_spread", 1.0))
	var size_mul := float(settings.get("deciduous_cluster_size", 1.0))
	var tightness := maxf(float(settings.get("deciduous_cluster_tightness", 1.0)), 0.35)
	var spread := crown_w * 0.45 * spread_mul / tightness
	var cw := crown_w * 0.30 * size_mul
	var ch := crown_h * 0.40 * size_mul
	var overlap_down := minf(0.25, crown_h * 0.06)
	var out: Array = [
		{"pos": Vector3(0.0, trunk_h - overlap_down, 0.0), "w": cw * 1.08, "h": ch * 0.95},
	]
	var ring_n := count - 1
	for i in ring_n:
		var t := float(i) / maxf(float(ring_n), 1.0)
		var angle := float(i) * TAU * 0.618034 * tightness
		var elev_t := lerpf(0.08, 0.82, t)
		var r := spread * lerpf(0.50, 1.0, sqrt(t))
		var y := trunk_h + crown_h * elev_t
		var sz := lerpf(1.0, 0.76, t)
		out.append({
			"pos": Vector3(cos(angle) * r * 0.55, y, sin(angle) * r * 0.55),
			"w": cw * sz,
			"h": ch * sz,
		})
	return out


## Whorls stack on the trunk axis in a tapering cone; per-tier yaw spin breaks
## vertical repeat without offsetting whorls off-center.
static func _pine_cluster_layout(card_w: float, card_h: float,
		settings: Dictionary = {}) -> Array:
	var tiers := clampi(int(round(float(settings.get("pine_whorl_count", 7)))), 3, 14)
	var bough_scale := float(settings.get("pine_bough_scale", 1.0))
	var v_spacing := maxf(float(settings.get("pine_whorl_spacing", 1.0)), 0.45)
	var jitter := float(settings.get("pine_whorl_jitter", 0.08))
	var y_curve := 1.0 / v_spacing
	var out: Array = []
	for i in tiers:
		var t := float(i) / maxf(float(tiers - 1), 1.0)
		var fi := float(i)
		var y_norm := pow(t, y_curve)
		var y := card_h * lerpf(0.20, 0.94, y_norm)
		var w := card_w * lerpf(1.08, 0.28, t) * bough_scale
		var h := card_h * lerpf(0.32, 0.12, t) * bough_scale
		var wobble := 1.0 + sin(fi * 2.41) * 0.06 * jitter
		var yaw := fi * TAU / 6.0 + sin(fi * 2.1) * 0.45 * jitter
		out.append({
			"pos": Vector3(0.0, y, 0.0),
			"w": w * wobble,
			"h": h * (1.0 + cos(fi * 3.07) * 0.05 * jitter),
			"yaw": yaw,
			"cards": 3,
		})
	return out


static func _shrub_cluster_layout(card_w: float, card_h: float,
		settings: Dictionary = {}) -> Array:
	var count := clampi(int(round(float(settings.get("shrub_cluster_count", 6)))), 3, 10)
	var spread_mul := float(settings.get("shrub_cluster_spread", 1.0))
	var size_mul := float(settings.get("shrub_cluster_size", 1.0))
	var spread := card_w * 0.38 * spread_mul
	var out: Array = []
	for i in count:
		var t := float(i) / maxf(float(count - 1), 1.0)
		var angle := float(i) * TAU * 0.618034
		var r := spread * lerpf(0.0, 1.0, t)
		var y := card_h * lerpf(0.30, 0.62, t)
		var sz := lerpf(0.92, 0.58, t) * size_mul
		out.append({
			"pos": Vector3(cos(angle) * r * 0.42, y, sin(angle) * r * 0.42),
			"w": card_w * sz,
			"h": card_h * sz,
		})
	return out


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

	var mesh := ArrayMesh.new()
	var trunk_arr: Array = []
	trunk_arr.resize(Mesh.ARRAY_MAX)
	trunk_arr[Mesh.ARRAY_VERTEX] = trunk_verts
	trunk_arr[Mesh.ARRAY_TEX_UV] = trunk_uvs
	trunk_arr[Mesh.ARRAY_NORMAL] = trunk_normals
	trunk_arr[Mesh.ARRAY_INDEX] = trunk_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, trunk_arr)
	mesh.surface_set_material(0, bark_material_for_species("pine", settings))

	var foliage_verts := PackedVector3Array()
	var foliage_uvs := PackedVector2Array()
	var foliage_normals := PackedVector3Array()
	var foliage_indices := PackedInt32Array()
	for c in _pine_cluster_layout(card_w, card_h, settings):
		var pos: Vector3 = c["pos"]
		_add_cluster_cards(foliage_verts, foliage_uvs, foliage_normals, foliage_indices,
			pos, float(c["w"]), float(c["h"]), Vector3(0.0, 0.72, 0.0),
			float(c.get("yaw", 0.0)), int(c.get("cards", 3)))

	var foliage_arr: Array = []
	foliage_arr.resize(Mesh.ARRAY_MAX)
	foliage_arr[Mesh.ARRAY_VERTEX] = foliage_verts
	foliage_arr[Mesh.ARRAY_TEX_UV] = foliage_uvs
	foliage_arr[Mesh.ARRAY_NORMAL] = foliage_normals
	foliage_arr[Mesh.ARRAY_INDEX] = foliage_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, foliage_arr)
	var mat_settings := settings.duplicate(true)
	if bool(settings.get("pine_fur_enabled", true)):
		mat_settings["pine_fur_strength"] = float(settings.get("pine_fur_strength", 0.38))
	else:
		mat_settings["pine_fur_strength"] = 0.0
	mesh.surface_set_material(1, material_for_species("pine", mat_settings))
	return mesh


static func _build_shrub_mesh(spec: Dictionary, settings: Dictionary = {}) -> ArrayMesh:
	var card_w := float(spec["width"])
	var card_h := float(spec["height"])
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for c in _shrub_cluster_layout(card_w, card_h, settings):
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
	mat.set_shader_parameter("translucency_strength", float(settings.get("translucency_strength", 0.25)))
	mat.set_shader_parameter("canopy_roundness", float(settings.get("canopy_roundness", 0.40)))
	mat.set_shader_parameter("color_variation", float(settings.get("color_variation", 0.12)))
	mat.set_shader_parameter("roughness_value", float(settings.get("foliage_roughness", 0.95)))
	mat.set_shader_parameter("ao_strength", float(settings.get("ao_strength", 0.35)))
	if settings.has("ao_tint"):
		var aoc: Color = settings["ao_tint"]
		mat.set_shader_parameter("ao_tint", Vector3(aoc.r, aoc.g, aoc.b))
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
	if prefix == "pine":
		var fur := float(settings.get("pine_fur_strength", 0.0))
		mat.set_shader_parameter("fur_strength", fur)
		if fur > 0.001:
			mat.set_shader_parameter("fur_cells", float(settings.get("pine_fur_cells", 20.0)))
			mat.set_shader_parameter("fur_tuft_size", float(settings.get("pine_fur_tuft_size", 0.58)))
			mat.set_shader_parameter("fur_gap", float(settings.get("pine_fur_gap", 0.24)))
		mat.set_shader_parameter("whorl_variation_strength",
			float(settings.get("pine_whorl_variation", 0.32)))
		mat.set_shader_parameter("whorl_band_h", float(settings.get("pine_whorl_band_h", 0.62)))
		mat.set_shader_parameter("cone_sharpness", float(settings.get("pine_cone_sharpness", 0.42)))
		mat.set_shader_parameter("canopy_roundness", float(settings.get("pine_canopy_roundness", 0.52)))
	mat.set_shader_parameter("color_fade", float(settings.get("deciduous_color_fade", 1.0)))
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
	mat.set_shader_parameter("roughness_value", float(settings.get("bark_roughness", 0.98)))
	mat.set_shader_parameter("bark_ao_strength", float(settings.get("bark_ao_strength", 0.28)))
	mat.set_shader_parameter("bark_color_jitter", float(settings.get("bark_color_jitter", 0.06)))
	if settings.has("bark_albedo_tint"):
		var c: Color = settings["bark_albedo_tint"]
		mat.set_shader_parameter("albedo_tint", Vector3(c.r, c.g, c.b))
