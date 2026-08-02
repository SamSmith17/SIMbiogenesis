class_name VegImpostorBaker
extends Node

## Runtime impostor baker (veg overhaul Phase 3b). Renders each (species +
## look) parametric NEAR mesh into a 3×3 atlas — 8 yaw views + 1 top view —
## plus a foliage-vs-bark mask atlas, via an offscreen SubViewport. There are
## no static GLBs to pre-bake: tree meshes are generated from settings, so the
## bake happens in-process, is keyed by a STABLE content hash of the resolved
## look, and caches to user://veg_impostors/<key>.res across sessions.
##
## Headless/selftest safety: bakes only run windowed. The OUTER-ring builder
## asks cached_set() synchronously; a miss falls back to the FAR card mesh and
## enqueues a bake here — when it completes the loader debounces one rebuild,
## so headless runs and first frames stay deterministic.

signal bake_completed(key: String)

## Bumped whenever the NEAR mesh GEOMETRY changes. The bake key hashes settings
## only — never the generator code — so without a bump every cached
## user://veg_impostors/<key>.res keeps serving the OLD silhouette while the
## NEAR and MID rings show the new one. v2 = the deciduous skeleton rebuild
## (branches distributed over the crown, foliage on real branch tips).
## v3: space-colonization deciduous skeleton + polygonal trunk (any change to
## the NEAR deciduous geometry must bump this or cached impostors serve the old
## silhouette forever).
const BAKE_VERSION := 3
const CACHE_DIR := "user://veg_impostors"
const ATLAS_PX := 1024
const GRID := 3
const CELL_PX := int(float(ATLAS_PX) / float(GRID))
const YAW_FRAMES := 8

const IMPOSTOR_SHADER := preload("res://vegetation/veg_impostor.gdshader")
const _MASK_SHADER_CODE := "
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D albedo_tex : source_color;
uniform float use_tex_alpha = 1.0;
uniform vec3 flat_color = vec3(1.0);
void fragment() {
	if (use_tex_alpha > 0.5 && texture(albedo_tex, UV).a < 0.5) { discard; }
	ALBEDO = flat_color;
}"

static var _instance: VegImpostorBaker = null

## key -> VegImpostorSet (memory); key -> true once disk was probed.
static var _sets: Dictionary = {}
static var _disk_checked: Dictionary = {}
static var _mask_shader: Shader = null

var _queue: Array[Dictionary] = []
var _baking := false


func _enter_tree() -> void:
	_instance = self
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


## Stable content key for one species look: the variant-resolved family keys
## (dims/shape/colors) + species id + bake version. Deliberately EXCLUDES
## volatile runtime keys (drape textures, haze color, growth clock, LOD
## reaches, ring centres) so the cache hits across sessions and the key never
## embeds a Texture2D object hash.
static func bake_key(species: String, settings: Dictionary) -> String:
	var resolved := VegSpeciesCatalog.settings_with_variant(
		species, settings, VegetationCardFactory.SPECS)
	var family := VegetationCardFactory.mesh_family(species)
	var parts: Array[String] = ["v%d" % BAKE_VERSION, species]
	var keys: Array = []
	for k in resolved:
		var key := str(k)
		if not key.begins_with(family + "_"):
			continue
		if key.contains("_lod_") or key.contains("visibility") or key.contains("growth"):
			continue
		keys.append(key)
	keys.sort()
	for k in keys:
		var v: Variant = resolved[k]
		if v is Color:
			var c: Color = v
			parts.append("%s=%.3f,%.3f,%.3f" % [k, c.r, c.g, c.b])
		elif v is float or v is int:
			parts.append("%s=%.3f" % [k, float(v)])
		elif v is bool:
			parts.append("%s=%s" % [k, "1" if v else "0"])
	if resolved.has("bark_albedo_tint") and resolved["bark_albedo_tint"] is Color:
		var b: Color = resolved["bark_albedo_tint"]
		parts.append("bark=%.3f,%.3f,%.3f" % [b.r, b.g, b.b])
	return "%s_%s" % [species, "|".join(parts).md5_text().substr(0, 16)]


static func cache_path(key: String) -> String:
	return "%s/%s.res" % [CACHE_DIR, key]


## Synchronous lookup: memory, then one disk probe per key per session.
## Returns null when no bake exists yet (caller falls back to FAR cards).
static func cached_set(species: String, settings: Dictionary) -> VegImpostorSet:
	var key := bake_key(species, settings)
	var found: Variant = _sets.get(key)
	if found is VegImpostorSet:
		return found
	if _disk_checked.get(key, false):
		return null
	_disk_checked[key] = true
	var path := cache_path(key)
	if ResourceLoader.exists(path):
		var res: Variant = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
		if res is VegImpostorSet and (res as VegImpostorSet).bake_version == BAKE_VERSION \
				and (res as VegImpostorSet).is_usable():
			_sets[key] = res
			return res
	return null


## Queue a bake for a missing set. No-op when headless or no baker node exists.
static func request_async(species: String, settings: Dictionary) -> void:
	if _instance == null or DisplayServer.get_name() == "headless":
		return
	_instance._enqueue(species, settings)


## The shared unit quad mesh + configured material for one impostor set,
## memoized in VegAssetCache. Quad: X spans ±world_w/2, Y spans foot..height.
static func quad_mesh_for(iset: VegImpostorSet) -> ArrayMesh:
	var key := "impquad|%s" % iset.key
	var cached: Variant = VegAssetCache.fetch(key)
	if cached is ArrayMesh:
		return cached
	var hw := iset.world_w * 0.5
	var y0 := iset.foot_y
	var y1 := iset.foot_y + iset.world_h
	var verts := PackedVector3Array([
		Vector3(-hw, y0, 0), Vector3(hw, y0, 0), Vector3(hw, y1, 0), Vector3(-hw, y1, 0)])
	var uvs := PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	var normals := PackedVector3Array([
		Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, material_for(iset))
	return VegAssetCache.store(key, mesh)


static func material_for(iset: VegImpostorSet) -> ShaderMaterial:
	var key := "impmat|%s" % iset.key
	var cached: Variant = VegAssetCache.fetch(key)
	if cached is ShaderMaterial:
		return cached
	var mat := ShaderMaterial.new()
	mat.shader = IMPOSTOR_SHADER
	mat.set_shader_parameter("atlas_tex", iset.atlas)
	mat.set_shader_parameter("mask_tex", iset.mask)
	mat.set_shader_parameter("frames_x", float(iset.frames_x))
	mat.set_shader_parameter("frames_y", float(iset.frames_y))
	mat.set_shader_parameter("yaw_frames", float(iset.yaw_frames))
	return VegAssetCache.store(key, mat)


func _enqueue(species: String, settings: Dictionary) -> void:
	var key := bake_key(species, settings)
	if _sets.has(key):
		return
	for job in _queue:
		if str(job.get("key", "")) == key:
			return
	# Snapshot only what the bake needs; drop textures so the queued dict is light.
	var s := settings.duplicate(true)
	s.erase("drape_tex")
	_queue.append({"key": key, "species": species, "settings": s})
	if not _baking:
		_run_queue.call_deferred()


func _run_queue() -> void:
	if _baking:
		return
	_baking = true
	while not _queue.is_empty():
		var job: Dictionary = _queue.pop_front()
		var key := str(job["key"])
		if _sets.has(key):
			continue
		var iset := await _bake(str(job["species"]), job["settings"] as Dictionary, key)
		if iset != null:
			_sets[key] = iset
			var err := ResourceSaver.save(iset, cache_path(key))
			if err != OK:
				push_warning("VegImpostorBaker: failed to save %s (err %d)" % [key, err])
			print("VegImpostorBaker: baked %s" % key)
			bake_completed.emit(key)
	_baking = false


func _bake(species: String, settings: Dictionary, key: String) -> VegImpostorSet:
	var mesh := VegetationCardFactory.mesh_for_canopy_lod(species, settings,
		VegetationCardFactory.CanopyLodTier.NEAR)
	if mesh == null:
		return null
	var aabb := mesh.get_aabb()
	if aabb.size.y < 0.05:
		return null
	# Offscreen studio.
	var vp := SubViewport.new()
	vp.size = Vector2i(CELL_PX, CELL_PX)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.world_3d = World3D.new()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.85
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	vp.add_child(world_env)
	var light := DirectionalLight3D.new()
	light.light_energy = 0.55
	vp.add_child(light)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	vp.add_child(mi)
	var neutral := _neutral_overrides(mesh)
	var masks := _mask_overrides(mesh)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	var world_w := maxf(aabb.size.x, aabb.size.z)
	var world_h := aabb.size.y
	cam.size = maxf(world_w, world_h) * 1.04
	cam.near = 0.05
	var radius := maxf(world_w, world_h) * 2.0 + 4.0
	cam.far = radius * 2.5
	vp.add_child(cam)
	cam.make_current()
	var center := aabb.get_center()

	var atlas := Image.create(ATLAS_PX, ATLAS_PX, false, Image.FORMAT_RGBA8)
	var mask_img := Image.create(ATLAS_PX, ATLAS_PX, false, Image.FORMAT_RGBA8)
	for pass_i in 2:
		var overrides: Array = neutral if pass_i == 0 else masks
		for si in mesh.get_surface_count():
			mi.set_surface_override_material(si, overrides[si] if si < overrides.size() else null)
		for view in YAW_FRAMES + 1:
			var cam_pos: Vector3
			var up := Vector3.UP
			if view < YAW_FRAMES:
				var az := TAU * float(view) / float(YAW_FRAMES)
				cam_pos = center + Vector3(sin(az), 0.0, cos(az)) * radius
			else:
				cam_pos = center + Vector3(0.001, radius, 0.0)
				up = Vector3.FORWARD
			cam.look_at_from_position(cam_pos, center, up)
			light.global_transform = cam.global_transform
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			var col := view % GRID
			var row := int(float(view) / float(GRID))
			var dst := atlas if pass_i == 0 else mask_img
			dst.blit_rect(img, Rect2i(0, 0, CELL_PX, CELL_PX),
				Vector2i(col * CELL_PX, row * CELL_PX))
	vp.queue_free()

	atlas.generate_mipmaps()
	var iset := VegImpostorSet.new()
	iset.bake_version = BAKE_VERSION
	iset.key = key
	iset.species = species
	iset.atlas = ImageTexture.create_from_image(atlas)
	iset.mask = ImageTexture.create_from_image(mask_img)
	iset.frames_x = GRID
	iset.frames_y = GRID
	iset.yaw_frames = YAW_FRAMES
	iset.world_w = world_w
	iset.world_h = world_h
	iset.foot_y = aabb.position.y
	return iset


## Duplicated surface materials with the seasonal/wind/drape uniforms forced
## neutral — the atlas must bake a summer, windless, un-draped tree, or the
## live seasonal shader would double-apply on top of a baked autumn.
func _neutral_overrides(mesh: ArrayMesh) -> Array:
	var out: Array = []
	for si in mesh.get_surface_count():
		var m: Material = mesh.surface_get_material(si)
		if m is ShaderMaterial:
			var d := (m as ShaderMaterial).duplicate() as ShaderMaterial
			for pair in [["autumn", 0.0], ["winter", 0.0], ["spring_bud", 0.0],
					["leaf_coverage", 1.0], ["snow_amount", 0.0], ["snow_depth_m", 0.0],
					["wind_strength", 0.0], ["haze_strength", 0.0], ["night_factor", 0.0],
					["use_drape", false], ["drape_match_strength", 0.0]]:
				d.set_shader_parameter(str(pair[0]), pair[1])
			out.append(d)
		else:
			out.append(null)
	return out


## Flat white (foliage) / black (bark) unshaded materials that respect the
## original albedo texture's alpha, for the mask pass. Surface 0 is the bark
## surface on both canopy families (trunk cards are always appended first).
func _mask_overrides(mesh: ArrayMesh) -> Array:
	if _mask_shader == null:
		_mask_shader = Shader.new()
		_mask_shader.code = _MASK_SHADER_CODE
	var out: Array = []
	for si in mesh.get_surface_count():
		var m: Material = mesh.surface_get_material(si)
		var mm := ShaderMaterial.new()
		mm.shader = _mask_shader
		mm.set_shader_parameter("flat_color",
			Vector3(0.0, 0.0, 0.0) if si == 0 else Vector3(1.0, 1.0, 1.0))
		var tex: Variant = null
		if m is ShaderMaterial:
			tex = (m as ShaderMaterial).get_shader_parameter("albedo_tex")
		if tex is Texture2D:
			mm.set_shader_parameter("albedo_tex", tex)
			mm.set_shader_parameter("use_tex_alpha", 1.0)
		else:
			mm.set_shader_parameter("use_tex_alpha", 0.0)
		out.append(mm)
	return out
