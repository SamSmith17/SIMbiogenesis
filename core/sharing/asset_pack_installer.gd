class_name AssetPackInstaller
extends RefCounted

## Installs an opened pack (AssetPackReader.open) on this machine, never at
## the cost of the player's own data:
##
##   worlds    always a NEW world (fresh id); a name already in use gets
##             " (from <creator>)". The record is rewritten to DIR storage.
##   map data  copied only where this machine has no file of that name.
##   library   a missing file is added; an identical one skipped; a file
##             that DIFFERS is written beside it as "<name>__from_<creator>"
##             (folder libraries) or left alone (single-file preset
##             libraries — the imported worlds still carry their own copy in
##             assets/, which WorldAssets.restore puts back as keep-both). The
##             model catalog is MERGED by id on the main thread.
##   settings  opt-in; the current file is backed up to
##             user://pack_backups/<stamp>/ first.
##   game art  written into the project folder; a file already there with
##             the same size is skipped. Needs Godot's import + a restart
##             (start_reimport / restart_game).
##
## Two halves: extract() is file work only and runs on a worker thread;
## finish() registers maps, restores world assets and merges the model
## catalog, which touch engine singletons, so it runs on the main thread.

const MODEL_CATALOG_REL := "models/catalog.json"

var info: Dictionary = {}
## {worlds: Array[old id] or "all", mapcache, library, settings, art: bool}
var choices: Dictionary = {}
var user_root := "user://"
var worlds_root := "user://worlds"
var project_root := ""
## The selftest turns this off: restore() reads and writes the real
## user:// libraries, which a TEMP-root test must not touch.
var restore_assets := true

var _creator := ""
var _creator_tag := ""
var _world_ids := {}        # old id -> new id
var _new_worlds: Array = [] # records written by extract()
var _catalog_in: Array = [] # the pack's model catalog entries
var _renamed := {}          # "user://…" pack path -> where it was written instead
var result := {"ok": false, "error": "", "worlds": [], "added": 0, "skipped": 0, "kept_both": 0,
	"kept_yours": 0, "settings": 0, "art_files": 0, "damaged": [], "backup_dir": "", "catalog_added": 0}


static func create(reader_info: Dictionary, picks: Dictionary, opts: Dictionary = {}) -> AssetPackInstaller:
	var ins := AssetPackInstaller.new()
	ins.info = reader_info
	ins.choices = picks
	ins.user_root = str(opts.get("user_root", "user://"))
	ins.worlds_root = str(opts.get("worlds_root", ins.user_root.path_join("worlds")))
	ins.project_root = str(opts.get("project_root", ""))
	ins.restore_assets = bool(opts.get("restore_assets", true))
	var man: Dictionary = reader_info.get("manifest", {})
	ins._creator = str(man.get("creator", "")).strip_edges()
	if ins._creator.is_empty():
		ins._creator = "a friend"
	ins._creator_tag = _slug(ins._creator)
	return ins


## The worker-thread half.
func extract(progress: AssetPackProgress = null) -> Dictionary:
	if progress == null:
		progress = AssetPackProgress.new()
	var man: Dictionary = info.get("manifest", {})
	var files: Dictionary = man.get("files", {})
	var hashes: Dictionary = info.get("hashes", {})
	var where: Dictionary = info.get("where", {})
	var parts: Array = info.get("parts", [])
	# What goes, in pack order, grouped by part (one ZIPReader open at a time).
	var by_part := {}
	var total := 0
	for z in files:
		if not _wanted(str(z)):
			continue
		var pi := int(where.get(z, 0))
		if not by_part.has(pi):
			by_part[pi] = []
		(by_part[pi] as Array).append(str(z))
		total += int((files[z] as Dictionary).get("size", 0))
	progress.set_total(total)
	_plan_world_ids()
	var existing_names := {}
	for w in WorldStore.list(worlds_root, true):
		existing_names[WorldStore.display_name(w).to_lower()] = true
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var backup_dir := user_root.path_join("pack_backups").path_join(stamp)
	var keys := by_part.keys()
	keys.sort()
	for pi in keys:
		var zr := ZIPReader.new()
		if zr.open(str(parts[pi])) != OK:
			result["error"] = "Could not open %s" % str(parts[pi]).get_file()
			return result
		for z in by_part[pi]:
			if progress.cancelled():
				zr.close()
				result["error"] = "Cancelled"
				return result
			var data := zr.read_file(z)
			progress.advance(maxi(data.size(), 1), z.get_file())
			var want := str(hashes.get(z, ""))
			if not want.is_empty() and _sha(data) != want:
				(result["damaged"] as Array).append(z)
				continue
			var err := _place(z, data, backup_dir)
			if not err.is_empty():
				zr.close()
				result["error"] = err
				return result
		zr.close()
	# World records last: the new id, a free name, DIR storage.
	for old_id in _world_ids:
		var new_id := str(_world_ids[old_id])
		var rec := WorldStore._read_json(WorldStore.record_path(new_id, worlds_root))
		if rec.is_empty():
			continue
		var name := WorldStore.display_name(rec)
		if existing_names.has(name.to_lower()):
			name = "%s (from %s)" % [name, _creator]
		rec["id"] = new_id
		rec["name"] = name
		rec["storage"] = WorldPaths.STORAGE_DIR
		rec["imported_from"] = {"creator": _creator, "id": str(old_id),
			"created_unix": man.get("created_unix", 0)}
		rec["last_played_unix"] = Time.get_unix_time_from_system()
		rec.erase("migrated")
		rec.erase("scratch")
		WorldStore.save_record(rec, worlds_root)
		_new_worlds.append(rec)
		existing_names[name.to_lower()] = true
	if FileAccess.file_exists(backup_dir) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(backup_dir)):
		result["backup_dir"] = backup_dir
	result["ok"] = true
	return result


## The main-thread half. Returns the final result.
func finish() -> Dictionary:
	if not bool(result.get("ok", false)):
		return result
	var worlds: Array = []
	for rec in _new_worlds:
		var r: Dictionary = rec
		var map: Dictionary = r.get("map", {}) if r.get("map", {}) is Dictionary else {}
		if WorldStore.is_generated_map(map) and user_root == "user://":
			var ref := MapRegistry.ensure_generated(map)
			map["map_def_path"] = str(ref.get("map_def_path", ""))
			r["map"] = map
			WorldStore.save_record(r, worlds_root)
		if restore_assets:
			WorldAssets.restore(r, worlds_root)
		worlds.append({"id": str(r["id"]), "name": WorldStore.display_name(r)})
	result["worlds"] = worlds
	if restore_assets:
		_merge_model_catalog()
	return result


## Did this install write game art (=> Godot must import it, then restart)?
func needs_reimport() -> bool:
	return int(result.get("art_files", 0)) > 0


# -- Routing ------------------------------------------------------------------------

func _wanted(z: String) -> bool:
	var sec := z.get_slice("/", 0)
	match sec:
		AssetPackFormat.SEC_WORLDS:
			var ws: Variant = choices.get("worlds", "all")
			if ws is String and ws == "all":
				return true
			return ws is Array and (ws as Array).has(z.get_slice("/", 1))
		AssetPackFormat.SEC_MAPCACHE:
			return bool(choices.get("mapcache", true))
		AssetPackFormat.SEC_LIBRARY:
			return bool(choices.get("library", true))
		AssetPackFormat.SEC_SETTINGS:
			return bool(choices.get("settings", false))
		AssetPackFormat.SEC_ART:
			return bool(choices.get("art", true)) and not project_root.is_empty()
	return false


func _plan_world_ids() -> void:
	var files: Dictionary = (info.get("manifest", {}) as Dictionary).get("files", {})
	for z in files:
		var s := str(z)
		if s.begins_with(AssetPackFormat.SEC_WORLDS + "/") and _wanted(s):
			var old := s.get_slice("/", 1)
			if not _world_ids.has(old):
				_world_ids[old] = WorldStore.new_id() + str(_world_ids.size())


## Write one entry where it belongs. "" = fine, else a fatal error.
func _place(z: String, data: PackedByteArray, backup_dir: String) -> String:
	var sec := z.get_slice("/", 0)
	var rest := z.substr(sec.length() + 1)
	match sec:
		AssetPackFormat.SEC_WORLDS:
			var old := rest.get_slice("/", 0)
			var inner := rest.substr(old.length() + 1)
			var dst := SafeZip.target_under(_abs(WorldStore.world_dir(str(_world_ids[old]), worlds_root)), inner)
			return _write_user(dst, inner, data)
		AssetPackFormat.SEC_MAPCACHE:
			var dst2 := SafeZip.target_under(_abs(user_root), AssetPackFormat.user_name(rest))
			if FileAccess.file_exists(dst2):
				result["skipped"] = int(result["skipped"]) + 1
				return ""
			return _write_user(dst2, rest, data)
		AssetPackFormat.SEC_LIBRARY:
			return _place_library(rest, data)
		AssetPackFormat.SEC_SETTINGS:
			var name := AssetPackFormat.user_name(rest)
			var cf := AssetPackPrefs.decode_text(data.get_string_from_utf8())
			if cf == null:
				(result["damaged"] as Array).append(z)
				return ""
			var dst3 := SafeZip.target_under(_abs(user_root), name)
			if FileAccess.file_exists(dst3):
				DirAccess.make_dir_recursive_absolute(_abs(backup_dir))
				DirAccess.copy_absolute(dst3, _abs(backup_dir).path_join(name))
			if cf.save(dst3) != OK:
				return "Could not write %s" % name
			result["settings"] = int(result["settings"]) + 1
			return ""
		AssetPackFormat.SEC_ART:
			var dst4 := SafeZip.target_under(_abs(project_root), rest)
			if dst4.is_empty():
				return "Unsafe path in pack: %s" % z
			if FileAccess.file_exists(dst4) and FileAccess.get_size(dst4) == data.size():
				result["skipped"] = int(result["skipped"]) + 1
				return ""
			if not _write_raw(dst4, data):
				return "Could not write %s into the project folder" % rest
			result["art_files"] = int(result["art_files"]) + 1
			return ""
	return "Unknown section in pack: %s" % z


func _place_library(rest: String, data: PackedByteArray) -> String:
	var rel := AssetPackFormat.user_name(rest)
	var dst := SafeZip.target_under(_abs(user_root), rel)
	if rel == MODEL_CATALOG_REL:
		var parsed: Variant = JSON.parse_string(data.get_string_from_utf8())
		if parsed is Array:
			_catalog_in = parsed
		return ""
	if not FileAccess.file_exists(dst):
		return _write_user(dst, rest, data)
	if FileAccess.get_size(dst) == data.size() and FileAccess.get_sha256(dst) == _sha(data):
		result["skipped"] = int(result["skipped"]) + 1
		return ""
	# A single preset file at the root (or maps/packing_*) is the player's
	# whole library of that kind: keep theirs.
	if not rel.contains("/") or rel.begins_with("maps/packing_"):
		result["kept_yours"] = int(result["kept_yours"]) + 1
		return ""
	var alt := "%s__from_%s.%s" % [rel.get_basename(), _creator_tag, rel.get_extension()]
	var alt_dst := SafeZip.target_under(_abs(user_root), alt)
	_renamed["user://" + rel] = "user://" + alt
	result["kept_both"] = int(result["kept_both"]) + 1
	return _write_user(alt_dst, rest, data)


## Write a user-data entry (decoding a .cfgjson back into a .cfg).
func _write_user(dst: String, transport: String, data: PackedByteArray) -> String:
	if dst.is_empty():
		return "Unsafe path in pack: %s" % transport
	if transport.ends_with(AssetPackFormat.CFG_JSON_EXT):
		var cf := AssetPackPrefs.decode_text(data.get_string_from_utf8())
		if cf == null:
			(result["damaged"] as Array).append(transport)
			return ""
		var real := AssetPackFormat.user_name(dst)
		DirAccess.make_dir_recursive_absolute(real.get_base_dir())
		if cf.save(real) != OK:
			return "Could not write %s" % real.get_file()
		result["added"] = int(result["added"]) + 1
		return ""
	if not _write_raw(dst, data):
		return "Could not write %s" % dst.get_file()
	result["added"] = int(result["added"]) + 1
	return ""


static func _write_raw(dst: String, data: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true


## The pack's custom models join this machine's catalog. An id that is new
## is registered as-is (its GLB was written by extract, possibly under a
## keep-both name); an id this machine already has keeps the local entry.
func _merge_model_catalog() -> void:
	if _catalog_in.is_empty():
		return
	var have := {}
	for m in ModelCatalog.all_models():
		have[str(m.get("id", ""))] = true
	for e in _catalog_in:
		if not e is Dictionary:
			continue
		var entry: Dictionary = (e as Dictionary).duplicate(true)
		var id := str(entry.get("id", ""))
		var path := str(entry.get("path", ""))
		if id.is_empty() or have.has(id) or not path.begins_with("user://models/"):
			continue
		if _renamed.has(path):
			entry["path"] = _renamed[path]
		if not FileAccess.file_exists(str(entry["path"])):
			continue
		ModelCatalog.register_user(entry)
		have[id] = true
		result["catalog_added"] = int(result["catalog_added"]) + 1


# -- Game art: import + restart ------------------------------------------------------------

## Run Godot's importer over the project in a separate headless process.
## Returns its pid (-1 on failure). Poll OS.is_process_running(pid).
static func start_reimport(project_dir: String = "") -> int:
	var dir := project_dir if not project_dir.is_empty() else ProjectSettings.globalize_path("res://")
	return OS.create_process(OS.get_executable_path(), ["--headless", "--path", dir, "--import"])


## Quit and start the game again with the same arguments (minus the editor's
## debugger hand-off, which would point at a session that no longer exists),
## so the freshly imported art is loaded.
static func restart_game(tree: SceneTree) -> void:
	var args: Array[String] = []
	var src := OS.get_cmdline_args()
	var skip_next := false
	var has_path := false
	for a in src:
		if skip_next:
			skip_next = false
			continue
		if a in ["--remote-debug", "--editor-pid", "--breakpoints", "--position", "--resolution"]:
			skip_next = true
			continue
		if a.begins_with("--remote-debug=") or a.begins_with("--editor-pid="):
			continue
		if a == "--path":
			has_path = true
		args.append(a)
	if not has_path:
		args.push_front(ProjectSettings.globalize_path("res://"))
		args.push_front("--path")
	OS.set_restart_on_exit(true, PackedStringArray(args))
	tree.quit()


# -- Helpers ----------------------------------------------------------------------------

static func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p).replace("\\", "/")


static func _sha(data: PackedByteArray) -> String:
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(data)
	return hc.finish().hex_encode()


static func _slug(s: String) -> String:
	var out := ""
	for c in s.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
		elif not out.ends_with("_"):
			out += "_"
	out = out.strip_edges().trim_prefix("_").trim_suffix("_")
	return out if not out.is_empty() else "friend"
