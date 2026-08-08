class_name ExtremeWeatherPrefs
extends Object

## Per-hazard player preferences for the extreme-weather subsystem.
##
## Deliberately NOT in user://sim_settings.cfg. Two reasons:
##  * That file is driven by SimSettingsController.get_state_snapshot(), which is
##    explicitly the idiom for properties living on Main. These live on an
##    autoload and are read by the director before any Main resolves.
##  * A variable-length per-hazard dict does not belong in [rendering_adv].
## Same shape as core/perf/prop_render_tuning.gd: static state,
## `ensure_loaded()`, and a `save()` that load()s first so other sections
## survive.
##
## The MASTER on/off switch is deliberately NOT here — it lives on
## GameplayRules as `extreme_weather_enabled`, so it is save-scoped and
## scenario-scoped like every other mechanic toggle. This file only answers
## "which hazards, and how does the player like them tuned".

const CFG_PATH := "user://extreme_weather.cfg"
const SECTION := "hazards"
const SECTION_GLOBAL := "global"

## Visual severity multiplier — the "Drama" slider. Scales how a hazard LOOKS
## and nothing else: it must never reach the physics path, or a player could
## tune their PV yield with a graphics slider.
const INTENSITY_MIN := 0.25
const INTENSITY_MAX := 2.0
static var intensity: float = 1.0

## Toast on hazard onset/clear.
static var notify: bool = true

## hazard id -> bool. Absent id = HazardCatalog.default_enabled(id), so a hazard
## added in a later build opts in on its own terms rather than reading as
## disabled because the pref file predates it.
static var _enabled: Dictionary = {}

static var _loaded := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	intensity = clampf(
		float(cfg.get_value(SECTION_GLOBAL, "intensity", intensity)),
		INTENSITY_MIN, INTENSITY_MAX)
	notify = bool(cfg.get_value(SECTION_GLOBAL, "notify", notify))
	for id: String in HazardCatalog.ids():
		if cfg.has_section_key(SECTION, id):
			_enabled[id] = bool(cfg.get_value(SECTION, id))


static func save() -> void:
	ensure_loaded()
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)  # preserve any other sections
	cfg.set_value(SECTION_GLOBAL, "intensity", intensity)
	cfg.set_value(SECTION_GLOBAL, "notify", notify)
	for id: String in _enabled.keys():
		cfg.set_value(SECTION, id, bool(_enabled[id]))
	cfg.save(CFG_PATH)


static func is_enabled(id: String) -> bool:
	ensure_loaded()
	if _enabled.has(id):
		return bool(_enabled[id])
	return HazardCatalog.default_enabled(id)


static func set_enabled(id: String, on: bool) -> void:
	ensure_loaded()
	_enabled[id] = on


static func set_intensity(v: float) -> void:
	ensure_loaded()
	intensity = clampf(v, INTENSITY_MIN, INTENSITY_MAX) if is_finite(v) else 1.0


## A hazard contributes only when it is both opted in AND actually implemented.
## Every consumer should ask this rather than `is_enabled`, so the seven
## risk-profile-only entries can stay toggleable in the UI (they still shape the
## risk display) without ever producing a state.
static func is_active(id: String) -> bool:
	return HazardCatalog.is_simulated(id) and is_enabled(id)


## Test/harness support: drop in-memory state so the next read re-loads from
## disk. Does NOT touch the file.
static func reset_for_test() -> void:
	_loaded = false
	_enabled = {}
	intensity = 1.0
	notify = true
