class_name EducationCardOverrides
extends RefCounted

## DEV AUTHORING AID (temporary — see GraphFaultCardModal.TEXT_EDITING_ENABLED).
##
## The education-card copy lives in code (GraphEducationCards, the tutorial
## catalog briefs/debriefs). Iterating on wording is much faster in the game UI
## than in source, so cards presented through the fault-card modal can be
## edited in place and saved; the saved text then presents as THE default from
## then on. Overrides persist to user://education_card_overrides.json keyed by
## each card's `override_key` ("fault:<reason>[:kind]" /
## "tutorial:<level_id>:brief|debrief").
##
## Two deliberate properties of this being a temp tool:
##  - Parameterized fault cards are formatted with live numbers BEFORE they
##    reach the modal, so a saved edit freezes that occurrence's numbers into
##    the copy. The editor warns about this; the JSON is meant to be folded
##    back into code (with placeholders restored) and this whole layer removed.
##  - Only presentation is overridden — goals, actions and card routing are
##    untouched, so an edit can never break a level.

const OVERRIDES_PATH := "user://education_card_overrides.json"

## Selftest hook — redirect the store to a scratch file.
static var path_override: String = ""

static var _cache: Dictionary = {}
static var _cache_loaded: bool = false


static func _path() -> String:
	return path_override if not path_override.is_empty() else OVERRIDES_PATH


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


static func reset_cache() -> void:
	_cache = {}
	_cache_loaded = false


static func get_override(key: String) -> Dictionary:
	if key.is_empty():
		return {}
	var e: Variant = _load().get(key, {})
	return e if e is Dictionary else {}


static func save_override(key: String, title: String, body: String) -> void:
	if key.is_empty():
		return
	var d := _load()
	d[key] = {"title": title, "body": body}
	_save(d)


static func clear_override(key: String) -> void:
	var d := _load()
	if d.has(key):
		d.erase(key)
		_save(d)


static func has_override(key: String) -> bool:
	return not get_override(key).is_empty()


## Return `card` with any saved override applied (matched by card.override_key).
## Cards without a key pass through untouched.
static func apply(card: Dictionary) -> Dictionary:
	var key := str(card.get("override_key", ""))
	if key.is_empty():
		return card
	var ov := get_override(key)
	if ov.is_empty():
		return card
	var out := card.duplicate(true)
	if not str(ov.get("title", "")).is_empty():
		out["title"] = str(ov.get("title", ""))
	if not str(ov.get("body", "")).is_empty():
		out["body"] = str(ov.get("body", ""))
	return out


static func _save(d: Dictionary) -> void:
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f == null:
		push_warning("EducationCardOverrides: cannot write %s" % _path())
		return
	f.store_string(JSON.stringify(d, "\t"))
	f.close()
