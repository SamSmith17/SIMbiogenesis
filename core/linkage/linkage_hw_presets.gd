class_name LinkageHwPresets
extends RefCounted
## The shipped hardware part library — real fasteners with real prices, so a
## design's BOM names parts you can actually order rather than "bolt, 0.75".
##
## `registry.json` lists each part and the file holding it; every part file is
## `{id, name, type, label, cost, link, params{}, extras{}}` with `type` one of
## LinkageHardware.PART_TYPES. Copied verbatim from the LinkageLab web app's
## `hardware/` directory so a design authored in either tool resolves the same
## presets.
##
## Loading follows `ScadCatalog`'s idiom: parse once, cache, hand out copies.
## Callers must never mutate what they get back — `apply_to_part` returns a new
## part dictionary rather than editing in place.

const REGISTRY_PATH := "res://core/linkage/hardware/registry.json"
const PART_DIR := "res://core/linkage/hardware/"

static var _entries: Array = []
static var _by_id: Dictionary = {}
static var _loaded := false


## Every registered part, in registry order.
static func all() -> Array:
	_ensure_loaded()
	return _entries


static func by_id(preset_id: String) -> Dictionary:
	_ensure_loaded()
	var e = _by_id.get(preset_id)
	return e if e is Dictionary else {}


## Parts of one type, for a "choose a bushing" dropdown.
static func for_type(type: String) -> Array:
	_ensure_loaded()
	var out: Array = []
	for e in _entries:
		if str((e as Dictionary).get("type", "")) == type:
			out.append(e)
	return out


## A copy of `part` re-specified to a preset: its label, cost, params and the
## `presetId`/`bomKey` pair that rolls identical hardware up across assemblies.
## Returns `part` unchanged when the preset is unknown or the wrong type.
static func apply_to_part(part: Dictionary, preset_id: String) -> Dictionary:
	var preset := by_id(preset_id)
	if preset.is_empty():
		return part.duplicate(true)
	var out := part.duplicate(true)
	var type := str(preset.get("type", ""))
	if type != "" and type != str(part.get("type", "")):
		# Swapping a washer for a nut changes the stack's whole shape, so the
		# type comes along with the params rather than being silently kept.
		out["type"] = type
	out["label"] = str(preset.get("label", preset.get("name", out.get("label", ""))))
	if preset.has("cost"):
		out["cost"] = float(preset["cost"])
	if preset.get("params") is Dictionary:
		out["params"] = (preset["params"] as Dictionary).duplicate(true)
	out["presetId"] = str(preset["id"])
	out["bomKey"] = str(preset["id"])
	return out


## Drop the cache. Test hook — also the way a future user-authored library
## would be picked up without a restart.
static func reload() -> void:
	_loaded = false
	_entries = []
	_by_id = {}


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var registry = _read_json(REGISTRY_PATH)
	if not (registry is Array):
		push_warning("LinkageHwPresets: %s missing or malformed" % REGISTRY_PATH)
		return
	for row in registry:
		if not (row is Dictionary):
			continue
		var meta := row as Dictionary
		var fname := str(meta.get("file", ""))
		if fname == "":
			continue
		var body = _read_json(PART_DIR + fname)
		if not (body is Dictionary):
			push_warning("LinkageHwPresets: part file %s missing or malformed" % fname)
			continue
		var entry: Dictionary = (body as Dictionary).duplicate(true)
		# Registry metadata wins on identity so a renamed part file can't
		# silently orphan every design referencing its id.
		entry["id"] = str(meta.get("id", entry.get("id", "")))
		entry["type"] = str(meta.get("type", entry.get("type", "")))
		if not entry.has("name"):
			entry["name"] = str(meta.get("name", entry["id"]))
		if not entry.has("label"):
			entry["label"] = str(entry["name"])
		if not entry.has("cost"):
			entry["cost"] = 0.0
		if not (entry.get("params") is Dictionary):
			entry["params"] = LinkageHardware.default_part_params(str(entry["type"]))
		if str(entry["id"]) == "":
			continue
		_entries.append(entry)
		_by_id[str(entry["id"])] = entry


static func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())
