extends MeshInstance3D

## Inverted sphere shell showing fake subsurface geology in Snowglobe mode.


func _ready() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://core/soi/shaders/soi_subsurface.gdshader")
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_glass_enabled(true)
	sync_transform()


func set_glass_enabled(on: bool) -> void:
	var mat := material_override as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("glass_enabled", 1.0 if on else 0.0)


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
