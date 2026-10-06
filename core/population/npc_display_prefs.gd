class_name NpcDisplayPrefs
extends RefCounted

## Which body style NPCs are drawn with. A player choice, persisted globally
## rather than per map, because it is a taste about the game rather than a
## property of a site.
##
## The distinction that matters in the code: STYLE_SIMPLE means the player
## *chose* the stylised figure, which is different from the rigged body being
## unavailable. Both end up drawing the same figure, but only the first should
## survive installing the art, and only the second is worth reporting as a
## missing-asset condition.

const STYLE_HUMANOID := "humanoid"
const STYLE_SIMPLE := "simple"

const CFG_PATH := "user://npc_display.cfg"
const SECTION := "npc"

static var _style := ""
## Tri-state: -1 means "not loaded yet", so a real `false` from disk is never
## confused with the unloaded default (mirrors the `_style.is_empty()` check
## above, just for a bool instead of a string).
static var _colors_on := -1
## Bumped by every setter here. These are statics with no signal to connect to,
## so anything caching a value derived from them (the agent-dot cache in
## NpcPopulationBridge) compares this instead — otherwise toggling the tint
## mid-session would keep serving stale colors until the next roster change.
static var _generation := 0


## Monotonic counter of display-pref changes. Cheap to poll; see _generation.
static func generation() -> int:
	return _generation


static func style() -> String:
	if _style.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(CFG_PATH) == OK:
			_style = str(cfg.get_value(SECTION, "style", STYLE_HUMANOID))
		if _style != STYLE_SIMPLE:
			_style = STYLE_HUMANOID
	return _style


static func set_style(s: String) -> void:
	_style = STYLE_SIMPLE if s == STYLE_SIMPLE else STYLE_HUMANOID
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "style", _style)
	cfg.save(CFG_PATH)


## True when the player asked for the stylised body. Deliberately NOT the same
## question as "is the rigged body available" — see the class comment.
static func wants_simple() -> bool:
	return style() == STYLE_SIMPLE


## Overhead readout (the morale bar + task tag above each head):
##   always — ambient within AMBIENT_STATUS_DIST_M, plus on aim (the default)
##   aim    — only for the person the crosshair is on
##   off    — never (the name on aim is unaffected; that is basic interaction)
const OVERHEAD_ALWAYS := "always"
const OVERHEAD_AIM := "aim"
const OVERHEAD_OFF := "off"
const OVERHEAD_MODES: Array = [OVERHEAD_ALWAYS, OVERHEAD_AIM, OVERHEAD_OFF]
static var _overhead := ""


static func overhead_mode() -> String:
	if _overhead.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(CFG_PATH) == OK:
			_overhead = str(cfg.get_value(SECTION, "overhead", OVERHEAD_ALWAYS))
		if not OVERHEAD_MODES.has(_overhead):
			_overhead = OVERHEAD_ALWAYS
	return _overhead


static func set_overhead_mode(m: String) -> void:
	_overhead = m if OVERHEAD_MODES.has(m) else OVERHEAD_ALWAYS
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "overhead", _overhead)
	cfg.save(CFG_PATH)


## Which people are DRAWN at festival scale (the sim runs regardless):
##   home — only the focused camp's people (the full-tier avatars)
##   all  — everyone, figures near and cards far (the default)
##   lod  — everyone within crowd_lod_m of the camera
##   none — nobody (dots and ledgers keep working)
const CROWD_HOME := "home"
const CROWD_ALL := "all"
const CROWD_LOD := "lod"
const CROWD_NONE := "none"
const CROWD_MODES: Array = [CROWD_HOME, CROWD_ALL, CROWD_LOD, CROWD_NONE]
const CROWD_LOD_DEFAULT_M := 400.0
static var _crowd := ""
static var _crowd_lod := -1.0


static func crowd_draw() -> String:
	if _crowd.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(CFG_PATH) == OK:
			_crowd = str(cfg.get_value(SECTION, "crowd_draw", CROWD_ALL))
		if not CROWD_MODES.has(_crowd):
			_crowd = CROWD_ALL
	return _crowd


static func set_crowd_draw(m: String) -> void:
	_crowd = m if CROWD_MODES.has(m) else CROWD_ALL
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "crowd_draw", _crowd)
	cfg.save(CFG_PATH)


static func crowd_lod_m() -> float:
	if _crowd_lod < 0.0:
		var cfg := ConfigFile.new()
		_crowd_lod = CROWD_LOD_DEFAULT_M
		if cfg.load(CFG_PATH) == OK:
			_crowd_lod = clampf(float(cfg.get_value(SECTION, "crowd_lod_m", CROWD_LOD_DEFAULT_M)), 50.0, 5000.0)
	return _crowd_lod


static func set_crowd_lod_m(m: float) -> void:
	_crowd_lod = clampf(m, 50.0, 5000.0)
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "crowd_lod_m", _crowd_lod)
	cfg.save(CFG_PATH)


## True when each person should render with their own distinct pastel tint
## (the default). False renders everyone in plain black — no way to tell
## individuals apart by color, only by name/nametag.
static func colors_enabled() -> bool:
	if _colors_on < 0:
		var cfg := ConfigFile.new()
		var on := true
		if cfg.load(CFG_PATH) == OK:
			on = bool(cfg.get_value(SECTION, "colors_on", true))
		_colors_on = 1 if on else 0
	return _colors_on == 1


static func set_colors_enabled(on: bool) -> void:
	_colors_on = 1 if on else 0
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "colors_on", on)
	cfg.save(CFG_PATH)
