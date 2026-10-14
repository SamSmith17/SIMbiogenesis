extends MeshInstance3D

## Inverted sphere shell showing fake subsurface geology in Snowglobe mode.


func _ready() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://core/soi/shaders/soi_subsurface.gdshader")
	TerrainBuilder.apply_soil_textures(mat)
	# Draw the shell LAST among transparents. Vegetation is depth_prepass_alpha:
	# its depth lands in the opaque pre-pass (so the terrain behind it is
	# rejected) and its colour in the transparent pass. The shell sorts by its
	# centre and writes depth (depth_draw_always), so whenever it sorted ahead of
	# a tree it rejected that tree's colour pass too — nothing ever painted those
	# pixels, and every such tree printed as a tree-shaped black hole in the
	# Globe lens and the snowglobe. A container is drawn over its contents.
	mat.render_priority = Material.RENDER_PRIORITY_MAX
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_glass_enabled(true)
	sync_transform()


func set_glass_enabled(on: bool) -> void:
	var mat := material_override as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("glass_enabled", 1.0 if on else 0.0)
	if on:
		set_glass_opacity(1.0)


## Soft fade for Snowglobe pitch near horizon (0 = discard glass, 1 = full).
func set_glass_opacity(opacity: float) -> void:
	var mat := material_override as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("glass_opacity", clampf(opacity, 0.0, 1.0))


## Site Plan top-down: flat ground-tan below-ground fill instead of the
## water-cycle diagram (veins/aquifer stay for Elevation/Snowglobe).
func set_plain_soil(on: bool) -> void:
	var mat := material_override as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("plain_soil", 1.0 if on else 0.0)


func sync_transform() -> void:
	var svc := get_node_or_null("/root/SoiService")
	if svc == null:
		return
	var r: float = svc.radius_m()
	global_position = svc.world_center()
	
	var sphere := SphereMesh.new()
	sphere.radius = r
	sphere.height = r * 2.0
	sphere.radial_segments = 128
	sphere.rings = 64
	
	var st := SurfaceTool.new()
	st.create_from(sphere, 0)
	var mesh_data := st.commit_to_arrays()
	
	var verts: PackedVector3Array = mesh_data[Mesh.ARRAY_VERTEX]
	var uvs2 := PackedVector2Array()
	uvs2.resize(verts.size())
	for i in range(verts.size()):
		var v := verts[i]
		var wx := global_position.x + v.x
		var wz := global_position.z + v.z
		var ty := float(svc.ground_y_at(wx, wz))
		uvs2[i] = Vector2(ty, 0.0)
	
	mesh_data[Mesh.ARRAY_TEX_UV2] = uvs2
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_data)
	mesh = am
	scale = Vector3.ONE
