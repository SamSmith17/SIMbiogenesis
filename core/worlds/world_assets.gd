class_name WorldAssets
extends RefCounted

## A world must never break because a LIBRARY file it uses was deleted,
## overwritten, or is missing on another machine. Libraries stay global (the
## asset browsers and every loader keep working unchanged); each world keeps
## a VENDORED copy of what it actually references in <world>/assets/.
##
## What counts as a reference is found by walking the world's own JSON data
## files (props, graph, building styles, NPC spaces, printed objects, …):
##   * any string that is a "user://…" path to an existing library file
##     (SCAD part STLs, prints, …);
##   * "model_id"  -> a user catalog entry (user://models/catalog.json) + its GLB;
##   * "job_id"    -> user://machines/jobs/<id>.json (G-code toolpaths);
##   * "music"     -> user://stage_audio/<file>;
##   * "wall_texture" -> user://maps/facade_textures/<file>.
## Whole small libraries the world's ids point into (custom resource kinds,
## process/workflow recipes, component presets, camp styles, pack defs) are
## vendored too and restored only when MISSING.
##
## Restore runs BEFORE the scene builds:
##   missing library file           -> copied back from the world;
##   library file changed since     -> the world's copy is restored under a
##     the world last saved            suffixed name and the world's own data
##                                     files are REMAPPED to it, so another
##                                     world's newer edit is never overwritten;
##   missing catalog entry          -> re-registered.
##
## Collection parses the graph file, so it runs on explicit saves, exit and
## copies — not on the 3-minute autosave.

const ASSETS_DIR := "assets"
const MANIFEST := "assets.json"
const MANIFEST_VERSION := 1

const LIBRARY_FILES := [
	"user://resource_kinds.cfg",
	"user://process_recipes.json",
	"user://workflow_recipes.json",
	"user://user_presets.json",
	"user://camp_styles.json",
	"user://pack_defs.json",
]

## Path prefixes that are never vendored: the world's own data, the MAP cache,
## and other worlds.
const _SKIP_PREFIXES := ["user://worlds", "user://terrain_cache", "user://weather_cache",
	"user://saves", "user://veg_impostors", "user://site_reports", "user://shader_cache"]

const USER_CATALOG := "user://models/catalog.json"
const JOBS_DIR := "user://machines/jobs"
const MUSIC_DIR := "user://stage_audio"
const FACADE_DIR := "user://maps/facade_textures"


static func _assets_root(wdir: String) -> String:
	return "%s/%s" % [wdir, ASSETS_DIR]


static func manifest_path(wdir: String) -> String:
	return "%s/%s" % [_assets_root(wdir), MANIFEST]


## Every JSON world data file worth scanning for references.
static func _scan_files(rec: Dictionary, root: String) -> Array[String]:
	var out: Array[String] = []
	var files := WorldStore.data_files(rec, root)
	for tag in files:
		var p := str(files[tag])
		if p.ends_with(".json"):
			out.append(p)
	return out


## Walk a parsed JSON value collecting references into `refs`:
## {library_path: {"ref": the string as it appears in the data}}, plus
## catalog ids into `models`.
static func _walk(v: Variant, refs: Dictionary, models: Dictionary, catalog: Dictionary) -> void:
	if v is Dictionary:
		var d: Dictionary = v
		for k in d:
			var val: Variant = d[k]
			var ks := str(k)
			if val is String:
				var s: String = val
				if ks == "model_id" and catalog.has(s):
					models[s] = true
				elif ks == "job_id" and not s.is_empty():
					_add_ref(refs, "%s/%s.json" % [JOBS_DIR, s], s)
				elif ks == "music" and not s.is_empty() and not s.contains("/"):
					_add_ref(refs, "%s/%s" % [MUSIC_DIR, s], s)
				elif ks == "wall_texture" and not s.is_empty() and not s.contains("/"):
					_add_ref(refs, "%s/%s" % [FACADE_DIR, s], s)
				elif s.begins_with("user://"):
					_add_ref(refs, s, s)
			else:
				_walk(val, refs, models, catalog)
	elif v is Array:
		for e in v:
			if e is String:
				var s2: String = e
				if s2.begins_with("user://"):
					_add_ref(refs, s2, s2)
			else:
				_walk(e, refs, models, catalog)


static func _add_ref(refs: Dictionary, lib_path: String, ref: String) -> void:
	for pre in _SKIP_PREFIXES:
		if lib_path.begins_with(pre):
			return
	if FileAccess.file_exists(lib_path):
		refs[lib_path] = {"ref": ref}


static func _user_catalog() -> Dictionary:
	var by_id := {}
	if not FileAccess.file_exists(USER_CATALOG):
		return by_id
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(USER_CATALOG))
	if parsed is Array:
		for e in parsed:
			if e is Dictionary and not str((e as Dictionary).get("id", "")).is_empty():
				by_id[str(e["id"])] = e
	return by_id


## Vendor everything this world references. Returns {files, models, libs}
## counts. `root` is the worlds root (selftest seam).
static func collect(rec: Dictionary, root: String = WorldPaths.WORLDS_DIR) -> Dictionary:
	var id := str(rec.get("id", ""))
	if id.is_empty():
		return {}
	var wdir := WorldStore.world_dir(id, root)
	var aroot := _assets_root(wdir)
	var catalog := _user_catalog()
	var refs := {}
	var models := {}
	for p in _scan_files(rec, root):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if parsed != null:
			_walk(parsed, refs, models, catalog)
	var old := WorldStore._read_json(manifest_path(wdir))
	var old_files: Dictionary = old.get("files", {}) if old.get("files", {}) is Dictionary else {}
	var man := {"version": MANIFEST_VERSION, "files": {}, "models": {}, "libs": {}}
	for mid in models:
		var entry: Dictionary = catalog[mid]
		man["models"][mid] = entry
		var gp := str(entry.get("path", ""))
		if gp.begins_with("user://") and FileAccess.file_exists(gp):
			refs[gp] = {"ref": gp, "model": mid}
	for lib_path in refs:
		man["files"][lib_path] = _vendor(lib_path, aroot, old_files.get(lib_path, {}), refs[lib_path])
	for lp in LIBRARY_FILES:
		if FileAccess.file_exists(lp):
			man["libs"][lp] = _vendor(lp, aroot, (old.get("libs", {}) as Dictionary).get(lp, {}) \
				if old.get("libs", {}) is Dictionary else {}, {"ref": lp})
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(aroot))
	WorldStore._write_json(manifest_path(wdir), man)
	return {"files": (man["files"] as Dictionary).size(), "models": (man["models"] as Dictionary).size(),
		"libs": (man["libs"] as Dictionary).size()}


## Copy one library file into the world (skipped when unchanged since the
## last vendor — size + mtime, then the hash).
static func _vendor(lib_path: String, aroot: String, prev: Variant, info: Dictionary) -> Dictionary:
	var rel := lib_path.trim_prefix("user://")
	var dst := "%s/files/%s" % [aroot, rel]
	var mtime := FileAccess.get_modified_time(lib_path)
	var size := _file_size(lib_path)
	var out := info.duplicate()
	out["vendored"] = "files/" + rel
	if prev is Dictionary and int((prev as Dictionary).get("mtime", -1)) == mtime \
			and int((prev as Dictionary).get("size", -1)) == size and FileAccess.file_exists(dst):
		out["sha256"] = str((prev as Dictionary).get("sha256", ""))
	else:
		out["sha256"] = FileAccess.get_sha256(lib_path)
		WorldStore._copy_file(lib_path, dst)
	out["mtime"] = mtime
	out["size"] = size
	return out


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := int(f.get_length())
	f.close()
	return n


## Put back whatever this world needs before its scene builds. Returns
## {restored, remapped, registered, missing} for the log/toast.
static func restore(rec: Dictionary, root: String = WorldPaths.WORLDS_DIR) -> Dictionary:
	var stats := {"restored": 0, "remapped": 0, "registered": 0, "missing": 0}
	var id := str(rec.get("id", ""))
	if id.is_empty():
		return stats
	var wdir := WorldStore.world_dir(id, root)
	var aroot := _assets_root(wdir)
	var man := WorldStore._read_json(manifest_path(wdir))
	if man.is_empty():
		return stats
	var remap := {}      # old ref string -> new ref string (quoted in the data)
	var files: Dictionary = man.get("files", {}) if man.get("files", {}) is Dictionary else {}
	var model_remap := {}  # old model id -> new model id
	for lib_path in files:
		var info: Dictionary = files[lib_path]
		var src := "%s/%s" % [aroot, str(info.get("vendored", ""))]
		if not FileAccess.file_exists(src):
			stats["missing"] += 1
			continue
		if not FileAccess.file_exists(lib_path):
			WorldStore._copy_file(src, lib_path)
			stats["restored"] += 1
			continue
		if FileAccess.get_sha256(lib_path) == str(info.get("sha256", "")):
			continue
		# Changed in the library since this world saved: restore OUR copy
		# beside it and point this world at it.
		var alt := _suffixed(str(lib_path), id)
		if not FileAccess.file_exists(alt):
			WorldStore._copy_file(src, alt)
		var mid := str(info.get("model", ""))
		if not mid.is_empty():
			model_remap[mid] = {"path": alt}
		else:
			var old_ref := str(info.get("ref", lib_path))
			remap[old_ref] = _remap_ref(old_ref, str(lib_path), alt)
		stats["remapped"] += 1
	# Catalog entries: re-register missing ones; a changed GLB gets its own id.
	var models: Dictionary = man.get("models", {}) if man.get("models", {}) is Dictionary else {}
	var catalog := _user_catalog()
	for mid2 in models:
		var entry: Dictionary = (models[mid2] as Dictionary).duplicate(true)
		if model_remap.has(mid2):
			var new_id := "%s__%s" % [mid2, id]
			entry["id"] = new_id
			entry["path"] = str((model_remap[mid2] as Dictionary)["path"])
			if not catalog.has(new_id):
				ModelCatalog.register_user(entry)
				stats["registered"] += 1
			remap[str(mid2)] = new_id
		elif not catalog.has(mid2):
			ModelCatalog.register_user(entry)
			stats["registered"] += 1
	# Whole libraries: only when missing.
	var libs: Dictionary = man.get("libs", {}) if man.get("libs", {}) is Dictionary else {}
	for lp in libs:
		if not FileAccess.file_exists(str(lp)):
			var src2 := "%s/%s" % [aroot, str((libs[lp] as Dictionary).get("vendored", ""))]
			if WorldStore._copy_file(src2, str(lp)):
				stats["restored"] += 1
	if not remap.is_empty():
		_apply_remap(rec, root, remap)
	return stats


## "user://models/x.glb" -> "user://models/x__<world>.glb".
static func _suffixed(path: String, world_id: String) -> String:
	var ext := path.get_extension()
	var base := path.get_basename()
	return "%s__%s%s" % [base, world_id, ("." + ext) if not ext.is_empty() else ""]


## The new reference string for a remapped file: a path stays a path, a bare
## name (music, texture, job id) becomes the suffixed name.
static func _remap_ref(old_ref: String, lib_path: String, alt: String) -> String:
	if old_ref == lib_path:
		return alt
	if lib_path.begins_with(JOBS_DIR):
		return alt.get_file().get_basename()
	return alt.get_file()


## Rewrite the world's own data files: every JSON-quoted occurrence of an old
## reference becomes the new one.
static func _apply_remap(rec: Dictionary, root: String, remap: Dictionary) -> void:
	for p in _scan_files(rec, root):
		var text := FileAccess.get_file_as_string(p)
		var changed := false
		for old_ref in remap:
			var q_old := JSON.stringify(str(old_ref))
			if text.contains(q_old):
				text = text.replace(q_old, JSON.stringify(str(remap[old_ref])))
				changed = true
		if changed:
			var f := FileAccess.open(p, FileAccess.WRITE)
			if f != null:
				f.store_string(text)
				f.close()
