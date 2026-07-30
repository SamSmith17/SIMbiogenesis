class_name ProgressStore
extends RefCounted

## Global (per-user, cross-map) tutorial progression + component unlocks.
## user://progress.json — deliberately separate from HighScoreStore, which is
## per-map score data; unlocks follow the player everywhere.
##
## Grandfathering rule: with NO progress file on disk, everything reads as
## unlocked — an existing install must never lose its library on update. The
## file is only created once the player answers the first-load prompt (start
## the bootcamp → gated library; skip → unlock_all persisted true).

const PROGRESS_PATH := "user://progress.json"
const VERSION := 1

## Categories every player has from the start (tutorial level 1 begins with a
## bare battery).
const BASELINE_CATEGORIES: Array[String] = ["batteries"]

## Selftest hook — redirect the store to a scratch file.
static var path_override: String = ""

static var _cache: Dictionary = {}
static var _cache_loaded: bool = false


static func _path() -> String:
	return path_override if not path_override.is_empty() else PROGRESS_PATH


static func _load() -> Dictionary:
	if _cache_loaded:
		return _cache
	_cache_loaded = true
	_cache = {}
	if FileAccess.file_exists(_path()):
		var f := FileAccess.open(_path(), FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				_cache = parsed
	return _cache


static func _save() -> void:
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f == null:
		push_warning("ProgressStore: cannot write %s" % _path())
		return
	_cache["version"] = VERSION
	f.store_string(JSON.stringify(_cache, "\t"))
	f.close()


## Drop the in-memory cache (selftests switching path_override).
static func reset_cache() -> void:
	_cache = {}
	_cache_loaded = false


static func has_file() -> bool:
	return FileAccess.file_exists(_path())


## A player who has never answered the first-load prompt.
static func is_new_player() -> bool:
	return not bool(_load().get("tutorial_prompt_seen", false))


static func mark_prompt_seen() -> void:
	_load()["tutorial_prompt_seen"] = true
	_save()


static func mark_tutorial_skipped() -> void:
	var d := _load()
	d["tutorial_prompt_seen"] = true
	d["tutorial_skipped"] = true
	_save()


## kind: "category" | "preset". Preset ids are the preset's `label` string
## (presets carry no explicit id; labels are the stable human-readable key the
## search bar already uses).
static func is_unlocked(kind: String, id: String) -> bool:
	if not has_file():
		return true  # grandfathering — see file header
	var d := _load()
	if bool(d.get("unlock_all", false)):
		return true
	var unlocked: Dictionary = d.get("unlocked", {}) as Dictionary
	match kind:
		"category":
			if id in BASELINE_CATEGORIES:
				return true
			return _has_id(unlocked.get("categories", []) as Array, id)
		"preset":
			return _has_id(unlocked.get("presets", []) as Array, id)
	return true


## Grant entries shaped "cat:<category_id>" or "preset:<label>".
static func grant(ids: Array) -> void:
	var d := _load()
	if not (d.get("unlocked") is Dictionary):
		d["unlocked"] = {"categories": [], "presets": []}
	var unlocked: Dictionary = d["unlocked"]
	for raw in ids:
		var s := str(raw)
		if s.begins_with("cat:"):
			_append_unique(unlocked, "categories", s.trim_prefix("cat:"))
		elif s.begins_with("preset:"):
			_append_unique(unlocked, "presets", s.trim_prefix("preset:"))
		elif s == "unlock_all":
			d["unlock_all"] = true
	_save()


static func unlock_all() -> void:
	var d := _load()
	d["unlock_all"] = true
	d["tutorial_prompt_seen"] = true
	_save()


static func is_unlock_all() -> bool:
	return bool(_load().get("unlock_all", false))


static func mark_level_complete(level_id: String, stats: Dictionary = {}) -> void:
	var d := _load()
	var done: Array = d.get("completed_levels", []) as Array
	if not _has_id(done, level_id):
		done.append(level_id)
	d["completed_levels"] = done
	if not stats.is_empty():
		if not (d.get("level_stats") is Dictionary):
			d["level_stats"] = {}
		(d["level_stats"] as Dictionary)[level_id] = stats
	_save()


static func is_level_complete(level_id: String) -> bool:
	return _has_id(_load().get("completed_levels", []) as Array, level_id)


static func level_stats(level_id: String) -> Dictionary:
	var stats: Dictionary = _load().get("level_stats", {}) as Dictionary
	var e: Variant = stats.get(level_id, {})
	return e if e is Dictionary else {}


## First id in `ordered_level_ids` not yet completed ("" = all done).
static func first_incomplete_level(ordered_level_ids: Array) -> String:
	for lid in ordered_level_ids:
		if not is_level_complete(str(lid)):
			return str(lid)
	return ""


## Solar Bootcamp sandbox graph (levels 10-12 build on whatever the player
## wired in the level before — "carry_graph"). Only the level INDEX persists
## via mark_level_complete; without this, resuming a carry_graph level in a new
## session lands on the blank sandbox begin_tutorial_sandbox always starts
## from, with nothing to build on. Captured on every sandbox edit (see
## SystemGraphView._flush_tutorial_sandbox_save); restored when a carry_graph
## level starts (see TutorialDirector.start()).
static func save_sandbox_snapshot(level_id: String, graph_blob: Dictionary) -> void:
	var d := _load()
	d["tutorial_sandbox"] = {"level_id": level_id, "graph": graph_blob}
	_save()


static func load_sandbox_snapshot() -> Dictionary:
	var e: Variant = _load().get("tutorial_sandbox", {})
	return e if e is Dictionary else {}


static func clear_sandbox_snapshot() -> void:
	var d := _load()
	if d.has("tutorial_sandbox"):
		d.erase("tutorial_sandbox")
		_save()


## Player/tester-requested reset: walk the curriculum again from level 1.
## Deliberately leaves unlock_all and individually granted categories/presets
## alone — a level's own allowed_presets still gates the Library while it is
## active, so this cannot be used to "re-earn" anything; it only resets which
## level you land on and drops the carried sandbox graph so level 1 starts
## from its own clean seed rather than whatever was last built.
static func reset_tutorial_progress() -> void:
	var d := _load()
	d.erase("completed_levels")
	d.erase("level_stats")
	d.erase("tutorial_sandbox")
	_save()


static func _has_id(arr: Array, needle: String) -> bool:
	for v in arr:
		if str(v) == needle:
			return true
	return false


static func _append_unique(d: Dictionary, key: String, value: String) -> void:
	var arr: Array = d.get(key, []) as Array
	if not _has_id(arr, value):
		arr.append(value)
	d[key] = arr
