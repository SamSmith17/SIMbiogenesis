class_name ModelImporter
extends RefCounted

## Copy a user GLB/GLTF into user://models/ and register in ModelCatalog.


static func import_from_path(source_path: String, label: String = "") -> Dictionary:
	if source_path.is_empty() or not FileAccess.file_exists(source_path):
		return {}
	var ext := source_path.get_extension().to_lower()
	if ext != "glb" and ext != "gltf":
		return {}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ModelCatalog.USER_DIR))
	var id := "user_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	var dest := "%s%s.%s" % [ModelCatalog.USER_DIR, id, ext]
	var abs_dest := ProjectSettings.globalize_path(dest)
	var err := DirAccess.copy_absolute(source_path, abs_dest)
	if err != OK:
		return {}
	var entry_name := label if not label.is_empty() else source_path.get_file().get_basename()
	var entry := {
		"id": id,
		"label": entry_name,
		"path": dest,
		"target_height_m": ModelCatalog.DEFAULT_TARGET_HEIGHT_M,
		"mesh_scale": 1.0,
		"preserve_scale": false,
	}
	ModelCatalog.register_user(entry)
	return entry


static func import_glb_bytes(bytes: PackedByteArray, label: String = "",
		ext: String = "glb", preserve_scale: bool = true,
		reference_height_m: float = 0.0,
		file_units_to_meters: float = 1.0) -> Dictionary:
	if bytes.is_empty():
		return {}
	ext = ext.to_lower()
	if ext != "glb" and ext != "gltf":
		ext = "glb"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ModelCatalog.USER_DIR))
	var id := "user_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	var dest := "%s%s.%s" % [ModelCatalog.USER_DIR, id, ext]
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return {}
	f.store_buffer(bytes)
	f.close()
	var entry_name := label if not label.is_empty() else "LinkageLab Import"
	var entry := {
		"id": id,
		"label": entry_name,
		"path": dest,
		"target_height_m": 0.0,
		"mesh_scale": 1.0,
		"preserve_scale": preserve_scale,
		"reference_height_m": maxf(reference_height_m, 0.0),
		"file_units_to_meters": maxf(file_units_to_meters, 0.0001),
		"source": "linkagelab",
	}
	ModelCatalog.register_user(entry)
	ModelCatalog.invalidate_metrics(id)
	return entry
