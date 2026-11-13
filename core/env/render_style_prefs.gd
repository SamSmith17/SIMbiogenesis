class_name RenderStylePrefs
extends RefCounted
## The player's visual style (Settings → Lighting → Visual style), global to the
## game like the graphics preset: user://render_style.cfg [style].
##
## Readers poll generation() (the settings page and the renderer never
## reference each other). resolved() is RenderStyle.resolve over the saved
## choice, cached per generation.

const PATH := "user://render_style.cfg"

static var _loaded := false
static var _gen := 0
static var _style := RenderStyle.REALISTIC
static var _strength := 1.0
static var _outlines := 1.0
static var _painterly := 1.0
static var _cel := 1.0
static var _cache := {}
static var _cache_gen := -1
static var _path := PATH


static func generation() -> int:
	_ensure()
	return _gen


static func style() -> String:
	_ensure()
	return _style


static func strength() -> float:
	_ensure()
	return _strength


static func outlines() -> float:
	_ensure()
	return _outlines


static func painterly() -> float:
	_ensure()
	return _painterly


static func cel() -> float:
	_ensure()
	return _cel


static func resolved() -> Dictionary:
	_ensure()
	if _cache_gen != _gen:
		_cache = RenderStyle.resolve(_style, _strength, _outlines, _painterly, _cel)
		_cache_gen = _gen
	return _cache


static func set_style(id: String) -> void:
	_ensure()
	var v := id if RenderStyle.has_style(id) else RenderStyle.REALISTIC
	if v == _style:
		return
	_style = v
	_changed()


static func set_strength(v: float) -> void:
	_set_float("_strength", clampf(v, 0.0, 1.0))


static func set_outlines(v: float) -> void:
	_set_float("_outlines", clampf(v, 0.0, 2.0))


static func set_painterly(v: float) -> void:
	_set_float("_painterly", clampf(v, 0.0, 2.0))


static func set_cel(v: float) -> void:
	_set_float("_cel", clampf(v, 0.0, 2.0))


## Back to the style's own sub-control values (keeps the chosen style).
static func reset_tuning() -> void:
	_ensure()
	_strength = 1.0
	_outlines = 1.0
	_painterly = 1.0
	_cel = 1.0
	_changed()


## Selftests: a temp file and defaults, never the player's.
static func use_path_for_test(path: String) -> void:
	_path = path
	_loaded = false
	_style = RenderStyle.REALISTIC
	_strength = 1.0
	_outlines = 1.0
	_painterly = 1.0
	_cel = 1.0
	_gen += 1


static func _set_float(field: String, v: float) -> void:
	_ensure()
	var cur := float(_get_field(field))
	if absf(cur - v) < 1e-5:
		return
	match field:
		"_strength": _strength = v
		"_outlines": _outlines = v
		"_painterly": _painterly = v
		"_cel": _cel = v
	_changed()


static func _get_field(field: String) -> float:
	match field:
		"_strength": return _strength
		"_outlines": return _outlines
		"_painterly": return _painterly
		"_cel": return _cel
	return 0.0


static func _changed() -> void:
	_gen += 1
	_save()


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(_path) != OK:
		return
	var id := String(cfg.get_value("style", "id", RenderStyle.REALISTIC))
	_style = id if RenderStyle.has_style(id) else RenderStyle.REALISTIC
	_strength = clampf(float(cfg.get_value("style", "strength", 1.0)), 0.0, 1.0)
	_outlines = clampf(float(cfg.get_value("style", "outlines", 1.0)), 0.0, 2.0)
	_painterly = clampf(float(cfg.get_value("style", "painterly", 1.0)), 0.0, 2.0)
	_cel = clampf(float(cfg.get_value("style", "cel", 1.0)), 0.0, 2.0)
	_gen += 1


static func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("style", "id", _style)
	cfg.set_value("style", "strength", _strength)
	cfg.set_value("style", "outlines", _outlines)
	cfg.set_value("style", "painterly", _painterly)
	cfg.set_value("style", "cel", _cel)
	cfg.save(_path)
