class_name WindowWallPrefs
extends Object

## Player preferences for the Window Wall (multi-monitor viewport) mode.
##
## Own file, deliberately NOT user://sim_settings.cfg (that file mirrors
## properties living on Main via SimSettingsController.get_state_snapshot())
## and NOT perf_prefs.cfg (per-slot records are structured data, and "the
## feature is off" must never be confused with a render pref). Same shape as
## core/weather/extreme_weather_prefs.gd: static state, `ensure_loaded()`, and
## a `save()` that load()s first so foreign sections survive.
##
## `cfg_path` is a static var so the selftest can round-trip a TEMP path and a
## player's real file is never touched. `override_for_session` lets the
## windowed harness force the feature on in memory without writing anything.

const CFG_PATH := "user://window_wall.cfg"
const SECTION := "wall"
const VERSION := 1
const MAX_SLOTS := WindowWallLayout.MAX_SLOTS

## How the EXTRA monitors' windows are put on screen. "fullscreen" is right
## almost always; "borderless" leaves them windowed at exactly the screen rect
## (visually identical) for a display that renders but will not PRESENT a
## second fullscreen window — the flat-grey-monitor symptom, usually a monitor
## driven by a different GPU than the main window's.
const WIN_FULLSCREEN := "fullscreen"
const WIN_BORDERLESS := "borderless"
const WINDOW_MODES := [WIN_FULLSCREEN, WIN_BORDERLESS]

const CLOCK_LIVE := "live"
const CLOCK_ONE_X := "one_x"
const CLOCK_LEAVE := "leave"
const CLOCK_MODES := [CLOCK_LIVE, CLOCK_ONE_X, CLOCK_LEAVE]

## 27" 16:9 panels, 4" gap, eye 0.9 m off the wall, seated eye ~1.2 m above the
## seat's ground point.
const DEFAULTS := {
	"enabled": false,
	"monitor_count": 3,
	"gap_m": 0.1016,
	"eye_distance_m": 0.9,
	"eye_height_offset_m": 0.0,
	"seat_eye_height_m": 1.2,
	"main_slot": 1,
	"clock_mode": CLOCK_LIVE,
	"extra_window_mode": WIN_FULLSCREEN,
	"hide_ui": true,
	"render_scale": 1.0,
	"msaa": -1,
	"nudge_speed_mps": 0.25,
}

const SLOT_DEFAULTS := {
	"diag_in": 27.0,
	"width_m": 0.0,
	"height_m": 0.0,
	"portrait": false,
	"yaw_deg": 0.0,
	"pitch_deg": 0.0,
	"screen": -1,
}

static var cfg_path: String = CFG_PATH
static var _wall: Dictionary = {}
static var _slots: Array = []
static var _loaded := false
## Bumped on every write so a panel can cheaply notice a change made elsewhere.
static var _generation := 0


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_wall = DEFAULTS.duplicate()
	_slots = []
	for i in MAX_SLOTS:
		_slots.append(SLOT_DEFAULTS.duplicate())
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return
	for key in DEFAULTS.keys():
		if cfg.has_section_key(SECTION, key):
			_wall[key] = _coerce(key, cfg.get_value(SECTION, key), DEFAULTS[key])
	for i in MAX_SLOTS:
		var sec := _slot_section(i)
		for key in SLOT_DEFAULTS.keys():
			if cfg.has_section_key(sec, key):
				_slots[i][key] = _coerce(key, cfg.get_value(sec, key), SLOT_DEFAULTS[key])
	_clamp_all()


static func save() -> void:
	ensure_loaded()
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)  # preserve any other sections
	cfg.set_value(SECTION, "version", VERSION)
	for key in DEFAULTS.keys():
		cfg.set_value(SECTION, key, _wall[key])
	for i in MAX_SLOTS:
		var sec := _slot_section(i)
		for key in SLOT_DEFAULTS.keys():
			cfg.set_value(sec, key, _slots[i][key])
	cfg.save(cfg_path)
	_generation += 1


static func generation() -> int:
	return _generation


# --- wall-level accessors ----------------------------------------------------

static func get_value(key: String) -> Variant:
	ensure_loaded()
	return _wall.get(key, DEFAULTS.get(key))


static func set_value(key: String, v: Variant) -> void:
	ensure_loaded()
	if not DEFAULTS.has(key):
		push_warning("WindowWallPrefs: unknown key %s" % key)
		return
	_wall[key] = _coerce(key, v, DEFAULTS[key])
	_clamp_all()
	_generation += 1


static func enabled() -> bool:
	return bool(get_value("enabled"))


static func monitor_count() -> int:
	return int(get_value("monitor_count"))


static func main_slot() -> int:
	return int(get_value("main_slot"))


static func clock_mode() -> String:
	return str(get_value("clock_mode"))


static func extra_window_mode() -> String:
	return str(get_value("extra_window_mode"))


static func hide_ui() -> bool:
	return bool(get_value("hide_ui"))


static func render_scale() -> float:
	return float(get_value("render_scale"))


static func seat_eye_height_m() -> float:
	return float(get_value("seat_eye_height_m"))


static func nudge_speed_mps() -> float:
	return float(get_value("nudge_speed_mps"))


# --- per-slot accessors -------------------------------------------------------

static func slot(i: int) -> Dictionary:
	ensure_loaded()
	if i < 0 or i >= MAX_SLOTS:
		return SLOT_DEFAULTS.duplicate()
	return (_slots[i] as Dictionary).duplicate()


static func set_slot_value(i: int, key: String, v: Variant) -> void:
	ensure_loaded()
	if i < 0 or i >= MAX_SLOTS or not SLOT_DEFAULTS.has(key):
		push_warning("WindowWallPrefs: bad slot write %d/%s" % [i, key])
		return
	_slots[i][key] = _coerce(key, v, SLOT_DEFAULTS[key])
	_generation += 1


## Write `screen` per slot from WindowWallLayout.assign_screens over the live
## screen list, so the settings tab can show what auto picked.
static func auto_arrange_by_x(screens: Array) -> void:
	ensure_loaded()
	for i in MAX_SLOTS:
		_slots[i]["screen"] = -1
	var assigned := WindowWallLayout.assign_screens(WindowWallLayout.build_slots(snapshot()), screens)
	for i in assigned.size():
		_slots[i]["screen"] = assigned[i]
	_generation += 1


## The dict WindowWallLayout.build_slots consumes. Only the ACTIVE slots ride
## along, so a stale slot_5 record never reaches the layout.
static func snapshot() -> Dictionary:
	ensure_loaded()
	var out := _wall.duplicate()
	var active: Array = []
	for i in monitor_count():
		active.append((_slots[i] as Dictionary).duplicate())
	out["slots"] = active
	return out


## Harness support: force values in memory for this session only. Nothing is
## written, so the player's cfg is untouched by a capture run.
static func override_for_session(values: Dictionary) -> void:
	ensure_loaded()
	for key in values.keys():
		if DEFAULTS.has(key):
			_wall[key] = _coerce(key, values[key], DEFAULTS[key])
	_clamp_all()
	_generation += 1


## Test support: drop in-memory state so the next read re-loads from disk.
## Does NOT touch the file.
static func reset_for_test() -> void:
	_loaded = false
	_wall = {}
	_slots = []


# --- internals ----------------------------------------------------------------

static func _slot_section(i: int) -> String:
	return "slot_%d" % i


static func _coerce(key: String, v: Variant, fallback: Variant) -> Variant:
	match typeof(fallback):
		TYPE_BOOL:
			return bool(v)
		TYPE_INT:
			return int(float(v)) if (v is float or v is int) else int(fallback)
		TYPE_FLOAT:
			var f := float(v) if (v is float or v is int) else float(fallback)
			return f if is_finite(f) else float(fallback)
		TYPE_STRING:
			var s := str(v)
			if key == "clock_mode" and not CLOCK_MODES.has(s):
				return str(fallback)
			if key == "extra_window_mode" and not WINDOW_MODES.has(s):
				return str(fallback)
			return s
	return v


static func _clamp_all() -> void:
	_wall["monitor_count"] = clampi(int(_wall["monitor_count"]), 1, MAX_SLOTS)
	_wall["main_slot"] = clampi(int(_wall["main_slot"]), 0, int(_wall["monitor_count"]) - 1)
	_wall["gap_m"] = clampf(float(_wall["gap_m"]), 0.0, 2.0)
	_wall["eye_distance_m"] = clampf(float(_wall["eye_distance_m"]), 0.2, 5.0)
	_wall["eye_height_offset_m"] = clampf(float(_wall["eye_height_offset_m"]), -1.0, 1.0)
	_wall["seat_eye_height_m"] = clampf(float(_wall["seat_eye_height_m"]), 0.3, 3.0)
	_wall["render_scale"] = clampf(float(_wall["render_scale"]), 0.25, 1.0)
	_wall["msaa"] = clampi(int(_wall["msaa"]), -1, 3)
	_wall["nudge_speed_mps"] = clampf(float(_wall["nudge_speed_mps"]), 0.02, 5.0)
