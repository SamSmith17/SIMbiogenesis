extends Node
class_name SaveGameService

## Autoload: slot files, autosave, JSON I/O, and slot summaries for Save/Load UI.
## Referenced at runtime as node "SaveSystem" under /root. Use class SaveGameService when @tool blocks the autoload global.
const MANUAL_SLOT_COUNT: int = 8
const AUTOSAVE_INTERVAL_SEC: float = 180.0
const SAVES_DIR: String = "user://saves/"
const INDEX_PATH: String = "user://saves/index.cfg"
const AUTOSAVE_FILENAME: String = "autosave.save.json"

var _autosave_timer: Timer = null


var _pending_resume_payload: Dictionary = {}


func set_pending_resume_payload(data: Dictionary) -> void:
	if data.is_empty():
		_pending_resume_payload = {}
	else:
		_pending_resume_payload = data.duplicate(true)


func clear_pending_resume_payload() -> void:
	_pending_resume_payload = {}


func take_pending_resume_payload() -> Dictionary:
	var d: Dictionary = _pending_resume_payload
	_pending_resume_payload = {}
	return d


func has_pending_resume_payload() -> bool:
	return not _pending_resume_payload.is_empty()


func _ready() -> void:
	_ensure_saves_dir()
	_autosave_timer = Timer.new()
	_autosave_timer.wait_time = AUTOSAVE_INTERVAL_SEC
	_autosave_timer.one_shot = false
	_autosave_timer.timeout.connect(_on_autosave_timer_timeout)
	add_child(_autosave_timer)
	# Only run autosave during playtest / exported game (not in editor)
	if not Engine.is_editor_hint():
		_autosave_timer.start()


func _ensure_saves_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVES_DIR))


func _manual_slot_path(slot_index: int) -> String:
	return SAVES_DIR.path_join("slot_%02d.save.json" % (slot_index + 1))


func get_manual_slot_path(slot_index: int) -> String:
	return _manual_slot_path(slot_index)


func autosave_path() -> String:
	return SAVES_DIR.path_join(AUTOSAVE_FILENAME)


func has_autosave() -> bool:
	return FileAccess.file_exists(autosave_path())


func has_any_manual_save() -> bool:
	for i in range(MANUAL_SLOT_COUNT):
		if FileAccess.file_exists(_manual_slot_path(i)):
			return true
	return false


func can_continue() -> bool:
	return has_autosave() or has_any_manual_save()


## Prefer autosave; else newest manual slot by created_at_unix.
func load_continue_payload() -> Dictionary:
	if has_autosave():
		var d := _read_json_file(autosave_path())
		if not d.is_empty():
			return d
	var best_idx := -1
	var best_time := -1.0
	for i in range(MANUAL_SLOT_COUNT):
		var p := _manual_slot_path(i)
		if not FileAccess.file_exists(p):
			continue
		var d := _read_json_file(p)
		if d.is_empty():
			continue
		var t := float(d.get("created_at_unix", 0.0))
		if t >= best_time:
			best_time = t
			best_idx = i
	if best_idx >= 0:
		return _read_json_file(_manual_slot_path(best_idx))
	return {}


func save_manual_slot(slot_index: int, snapshot: Dictionary) -> bool:
	if slot_index < 0 or slot_index >= MANUAL_SLOT_COUNT:
		return false
	snapshot["save_version"] = SaveSerialization.SAVE_VERSION
	snapshot["created_at_unix"] = Time.get_unix_time_from_system()
	var path := _manual_slot_path(slot_index)
	var ok := _write_json_file(path, snapshot)
	if ok:
		_index_set_slot_meta(slot_index, snapshot)
		_index_set_last_manual_slot(slot_index)
	return ok


func save_autosave(snapshot: Dictionary) -> bool:
	snapshot["save_version"] = SaveSerialization.SAVE_VERSION
	snapshot["created_at_unix"] = Time.get_unix_time_from_system()
	var ok := _write_json_file(autosave_path(), snapshot)
	if ok:
		_index_set_autosave_meta(snapshot)
	return ok


func load_manual_slot(slot_index: int) -> Dictionary:
	if slot_index < 0 or slot_index >= MANUAL_SLOT_COUNT:
		return {}
	return _read_json_file(_manual_slot_path(slot_index))


func load_autosave() -> Dictionary:
	return _read_json_file(autosave_path())


func delete_manual_slot(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= MANUAL_SLOT_COUNT:
		return
	var path := _manual_slot_path(slot_index)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_index_clear_slot(slot_index)


func delete_autosave() -> void:
	var path := autosave_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var cfg := ConfigFile.new()
	cfg.load(INDEX_PATH)
	cfg.erase_section("autosave")
	cfg.save(INDEX_PATH)


## Array of { "index": int, "exists": bool, "summary": String }
func list_slot_summaries() -> Array:
	var out: Array = []
	for i in range(MANUAL_SLOT_COUNT):
		var exists := FileAccess.file_exists(_manual_slot_path(i))
		var summary := ""
		if exists:
			var d := _read_json_file(_manual_slot_path(i))
			summary = _format_snapshot_summary(d)
		out.append({"index": i, "exists": exists, "summary": summary})
	return out


func validate_payload(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	var v := int(data.get("save_version", 0))
	if v < 1 or v > SaveSerialization.SAVE_VERSION:
		return false
	if not data.has("main"):
		return false
	var pl: Variant = data.get("player", {})
	if pl is Dictionary:
		var pd: Dictionary = pl
		if not pd.is_empty() and not pd.has("position"):
			return false
	return true


func _write_json_file(path: String, data: Dictionary) -> bool:
	_ensure_saves_dir()
	var json := JSON.stringify(data)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("SaveSystem: could not write %s" % path)
		return false
	f.store_string(json)
	return true


func _read_json_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


func _format_snapshot_summary(d: Dictionary) -> String:
	if d.is_empty():
		return ""
	var main_d: Variant = d.get("main", {})
	if main_d is Dictionary:
		var md: Dictionary = main_d
		var y := int(md.get("year", 0))
		var m := int(md.get("month", 0))
		var day := int(md.get("day", 0))
		var dt := float(md.get("day_time", 0.0))
		var h := int(dt)
		var mn := int((dt - float(h)) * 60.0)
		var unix_t := int(d.get("created_at_unix", 0))
		var wall := Time.get_datetime_dict_from_unix_time(unix_t)
		var sy := int(wall.get("year", 0))
		var sm := int(wall.get("month", 0))
		var sd := int(wall.get("day", 0))
		var sh := int(wall.get("hour", 0))
		var smin := int(wall.get("minute", 0))
		return "%04d-%02d-%02d %02d:%02d | file %04d-%02d-%02d %02d:%02d" % [y, m, day, h, mn, sy, sm, sd, sh, smin]
	return str(d.get("created_at_unix", ""))


func _index_set_slot_meta(slot_index: int, snapshot: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load(INDEX_PATH)
	var sec := "slot_%d" % slot_index
	cfg.set_value(sec, "exists", true)
	cfg.set_value(sec, "created_at_unix", snapshot.get("created_at_unix", 0.0))
	cfg.save(INDEX_PATH)


func _index_clear_slot(slot_index: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(INDEX_PATH)
	cfg.erase_section("slot_%d" % slot_index)
	cfg.save(INDEX_PATH)


func _index_set_autosave_meta(snapshot: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load(INDEX_PATH)
	cfg.set_value("autosave", "exists", true)
	cfg.set_value("autosave", "created_at_unix", snapshot.get("created_at_unix", 0.0))
	cfg.save(INDEX_PATH)


func _index_set_last_manual_slot(slot_index: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(INDEX_PATH)
	cfg.set_value("settings", "last_manual_slot", slot_index)
	cfg.save(INDEX_PATH)


func _on_autosave_timer_timeout() -> void:
	if Engine.is_editor_hint():
		return
	var tree := get_tree()
	if tree == null:
		return
	var main := tree.get_first_node_in_group("main_scene")
	if (
		main != null
		and is_instance_valid(main)
		and main.is_inside_tree()
		and main.has_method("request_autosave")
	):
		main.request_autosave()
