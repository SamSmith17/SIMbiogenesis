extends MeshInstance3D

## Inverted sphere shell showing fake subsurface geology in Snowglobe mode.


func _ready() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 48
	sphere.rings = 24
	mesh = sphere
	var mat := ShaderMaterial.new()
	mat.shader = load("res://core/soi/shaders/soi_subsurface.gdshader")
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sync_transform()


func sync_transform() -> void:
	var svc := get_node_or_null("/root/SoiService")
	if svc == null:
		return
	var r: float = svc.radius_m()
	global_position = svc.world_center()
	scale = Vector3.ONE * r * 2.0
