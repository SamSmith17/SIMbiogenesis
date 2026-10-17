extends SceneTree

## Offline probe for the broadleaf builder: per species, builds the NEAR mesh
## through the real resolution path, prints surfaces / triangles / size /
## build time, and writes each species' leaf-spray texture to
## user://broadleaf_probe/<species>.png for review.
## Godot --headless --path . --script tools/checks/broadleaf_probe.gd

const SPECIES := ["deciduous", "maple", "alder", "oak", "birch", "aspen", "cottonwood",
	"beech", "chestnut", "walnut", "apple", "pear", "olive", "orange", "acacia"]


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://broadleaf_probe"))
	var style := VegetationStyleConfig.defaults()
	for sid in SPECIES:
		var t0 := Time.get_ticks_usec()
		var mesh := VegetationCardFactory.mesh_for_canopy_lod(sid, style,
			VegetationCardFactory.CanopyLodTier.NEAR)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		var tris := 0
		for si in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(si)
			tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var aabb := mesh.get_aabb()
		print("broadleaf %-10s surf %d  tris %6d  h %.1f m  w %.1f m  %.0f ms" % [
			sid, mesh.get_surface_count(), tris, aabb.size.y,
			maxf(aabb.size.x, aabb.size.z), ms])
		if mesh.get_surface_count() > 1:
			var mat := mesh.surface_get_material(1) as ShaderMaterial
			var tex: Variant = mat.get_shader_parameter("albedo_tex") if mat else null
			if tex is ImageTexture:
				(tex as ImageTexture).get_image().save_png("user://broadleaf_probe/%s.png" % sid)
	quit()
