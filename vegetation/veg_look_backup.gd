class_name VegLookBackup
extends RefCounted

## Snapshots of one world's vegetation look, so a big change (a regional
## re-style, re-speciesing a painted forest) can be taken back from inside
## the game: Terrain options → "Restore an earlier vegetation look".
##
## A snapshot copies the files that ARE the look — the world's style store
## (vegetation_style_v3), its painted plants (vegetation) and its per-area
## edits/fills (auto_veg_edits) — into
##   user://veg_look_backups/<world key>/<stamp>/
## with a manifest saying which existed. Restoring writes them back and
## deletes the ones that did not exist when the snapshot was taken, so the
## result is exactly the snapshot. The world key is a hash of the RESOLVED
## style path: two worlds on one map never share backups (WorldPaths routes
## their files apart).
##
## Pure file work, no scene access; the loader reloads the layers after a
## restore.

const ROOT := "user://veg_look_backups"
const MANIFEST := "manifest.json"
const MAX_KEPT := 12


## The files a look consists of, by stable name → resolved path.
static func site_files(lat: float, lon: float) -> Dictionary:
	return {
		"style": VegStyleStore.map_v2_path(lat, lon),
		"painted": WorldPaths.site_file("vegetation", lat, lon),
		"area_edits": AutoVegetationEdits.save_path_for_map(lat, lon),
	}


static func world_dir(lat: float, lon: float) -> String:
	return "%s/%s" % [ROOT, VegStyleStore.map_v2_path(lat, lon).md5_text().substr(0, 12)]


## Copy the current look away. Returns the snapshot folder ("" on failure).
static func snapshot(lat: float, lon: float, label: String) -> String:
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var dir := "%s/%s" % [world_dir(lat, lon), stamp]
	var n := 1
	while DirAccess.dir_exists_absolute(dir):
		n += 1
		dir = "%s/%s_%d" % [world_dir(lat, lon), stamp, n]
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return ""
	var files := site_files(lat, lon)
	var existed := {}
	for name in files:
		var src := str(files[name])
		var has := FileAccess.file_exists(src)
		existed[name] = has
		if has and DirAccess.copy_absolute(src, "%s/%s" % [dir, name]) != OK:
			return ""
	var manifest := {
		"label": label,
		"stamp": stamp,
		"unix": Time.get_unix_time_from_system(),
		"existed": existed,
		"paths": files,
	}
	var f := FileAccess.open("%s/%s" % [dir, MANIFEST], FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(manifest, "\t"))
	f.close()
	_prune(lat, lon)
	return dir


## Snapshots for this world, newest first: [{dir, label, stamp, unix}].
static func list(lat: float, lon: float) -> Array:
	var out: Array = []
	var root := world_dir(lat, lon)
	var da := DirAccess.open(root)
	if da == null:
		return out
	for sub in da.get_directories():
		var dir := "%s/%s" % [root, sub]
		var m := _read_manifest(dir)
		if m.is_empty():
			continue
		out.append({"dir": dir, "label": str(m.get("label", "")),
			"stamp": str(m.get("stamp", sub)), "unix": float(m.get("unix", 0.0))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["unix"]) > float(b["unix"]))
	return out


## Put a snapshot back. Files that did not exist then are deleted, so the
## look is exactly what it was. Returns false (and changes nothing) when the
## snapshot is unreadable or incomplete.
static func restore(lat: float, lon: float, dir: String) -> bool:
	var m := _read_manifest(dir)
	if m.is_empty():
		return false
	var existed: Dictionary = m.get("existed", {})
	var files := site_files(lat, lon)
	for name in files:
		if bool(existed.get(name, false)) and not FileAccess.file_exists("%s/%s" % [dir, name]):
			return false
	for name in files:
		var dst := str(files[name])
		if bool(existed.get(name, false)):
			DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
			if DirAccess.copy_absolute("%s/%s" % [dir, name], dst) != OK:
				return false
		elif FileAccess.file_exists(dst):
			DirAccess.remove_absolute(dst)
	return true


static func _read_manifest(dir: String) -> Dictionary:
	var path := "%s/%s" % [dir, MANIFEST]
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


static func _prune(lat: float, lon: float) -> void:
	var all := list(lat, lon)
	for i in range(MAX_KEPT, all.size()):
		var dir := str((all[i] as Dictionary)["dir"])
		var da := DirAccess.open(dir)
		if da == null:
			continue
		for fn in da.get_files():
			DirAccess.remove_absolute("%s/%s" % [dir, fn])
		DirAccess.remove_absolute(dir)
