class_name MudBuildingStructureBuilder
extends RefCounted

## Places a mud building design in the world without printing — same mesh as the
## designer preview, ghosted via PlacedPropService like the geodesic dome.

const MODEL_ID := "mud_building"


static func build_node(spec: Dictionary = {}) -> Node3D:
	var mud: Dictionary = spec
	if spec.has("mud_spec") and spec["mud_spec"] is Dictionary:
		mud = spec["mud_spec"] as Dictionary
	var building := MudBuildingSpec.from_dict(mud)
	var mesh := MudWallMesher.build_mesh(building)
	var root := Node3D.new()
	root.name = "MudBuilding"
	if mesh == null:
		return root
	var mi := MeshInstance3D.new()
	mi.name = "Walls"
	mi.mesh = mesh
	# Walk-through so the player can inspect layers/infill; AABB pick still works.
	mi.set_meta("skip_prop_collision", true)
	if bool(spec.get("ghost_highlight", false)):
		var gmat := StandardMaterial3D.new()
		gmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		gmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gmat.albedo_color = Color(0.45, 0.85, 0.95, 0.5)
		gmat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = gmat
	else:
		var mat := mesh.surface_get_material(0) if mesh.get_surface_count() > 0 else null
		if mat is StandardMaterial3D:
			(mat as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
	root.add_child(mi)
	return root
