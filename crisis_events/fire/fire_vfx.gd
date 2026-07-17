class_name FireVfx
extends RefCounted

## Shared soft fire/smoke/ember draw materials — round alpha discs instead of
## hard-edged QuadMesh squares. Cheap: one GradientTexture2D reused per kind.

static var _soft_disc: GradientTexture2D = null
static var _ember_disc: GradientTexture2D = null


static func soft_disc_texture() -> GradientTexture2D:
	if _soft_disc != null:
		return _soft_disc
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.35, 0.7, 1.0])
	g.colors = PackedColorArray([
		Color(1, 1, 1, 1),
		Color(1, 1, 1, 0.85),
		Color(1, 1, 1, 0.25),
		Color(1, 1, 1, 0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	_soft_disc = tex
	return _soft_disc


static func ember_disc_texture() -> GradientTexture2D:
	if _ember_disc != null:
		return _ember_disc
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
	g.colors = PackedColorArray([
		Color(1, 1, 1, 1),
		Color(1, 1, 1, 0.7),
		Color(1, 1, 1, 0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 32
	tex.height = 32
	_ember_disc = tex
	return _ember_disc


static func make_billboard_quad(size: Vector2, additive: bool, emission: Color,
		emission_energy: float, soft: bool = true) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if soft:
		mat.albedo_texture = soft_disc_texture()
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	if emission_energy > 0.0:
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = emission_energy
	mesh.material = mat
	return mesh


static func make_ember_quad() -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.12, 0.12)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = ember_disc_texture()
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.25, 0.05)
	mat.emission_energy_multiplier = 4.0
	mesh.material = mat
	return mesh
