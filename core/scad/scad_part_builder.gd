class_name ScadPartBuilder
extends RefCounted

## Turns a rendered SCAD part (a binary STL produced by ScadRuntime) into a
## placeable Node3D for the PlacedProp system, reusing StlLoader.build_mesh (which
## converts Z-up millimetres -> Y-up metres, centres the footprint, and seats the
## base at local y=0 so it grounds like any other prop). Registered under
## ModelCatalog.instantiate + PlacedPropService._build_ghost as MODEL_ID
## "scad_part"; the STL path + display scale ride in the prop record's
## record_extra["scad_spec"] so a placed part survives save/reload (same mechanism
## the linkage structure uses). See PARAMETRIC_STORE_PLAN.md Phase 3.

const StlLoaderScript := preload("res://core/machines/stl_loader.gd")

const MODEL_ID := "scad_part"


## spec: {
##   stl_path: String   # user:// (or absolute) binary STL from ScadRuntime
##   display_scale: float = 1.0
##   color: Color (optional) — printed-filament tint
##   label: String (optional)
## }
static func build_node(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "ScadPart"
	var stl_path := String(spec.get("stl_path", ""))
	var mesh: ArrayMesh = null
	if not stl_path.is_empty():
		mesh = StlLoaderScript.build_mesh(stl_path)

	var mi := MeshInstance3D.new()
	mi.name = "PartMesh"
	if mesh != null:
		mi.mesh = mesh
		mi.material_override = _filament_material(spec.get("color", Color(0.80, 0.82, 0.85)))
	else:
		# Fallback placeholder so a failed/absent render still grounds visibly.
		var bm := BoxMesh.new()
		bm.size = Vector3(0.1, 0.1, 0.1)
		mi.mesh = bm
		mi.position = Vector3(0.0, 0.05, 0.0)
		mi.material_override = _filament_material(Color(0.7, 0.4, 0.4))
	root.add_child(mi)

	var scale := maxf(float(spec.get("display_scale", 1.0)), 0.001)
	if not is_equal_approx(scale, 1.0):
		root.scale = Vector3(scale, scale, scale)
	return root


static func _filament_material(color: Variant) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color if color is Color else Color(0.80, 0.82, 0.85)
	mat.roughness = 0.62
	mat.metallic = 0.0
	# Subtle so printed layer-ish shading reads without a texture.
	mat.rim_enabled = true
	mat.rim = 0.2
	return mat
