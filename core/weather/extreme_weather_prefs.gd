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

## Wind-blown dust (HazardEvaluators.evaluate_wind_dust): the 10 m wind above
## which dry ground starts to loft dust, the dry spell it needs, and whether a
## wet climate damps it (dust_ground_factor). The player's rule is the default:
## over 10 mph, unless it rained in the last 24 h.
const SECTION_DUST := "dust"
const DUST_WIND_MPH_MIN := 3.0
const DUST_WIND_MPH_MAX := 40.0
const DUST_DRY_HOURS_MIN := 0.0
const DUST_DRY_HOURS_MAX := 168.0
static var dust_wind_mph: float = 10.0
static var dust_dry_hours: float = 24.0
static var dust_climate_scale: bool = true

## How a dust storm LOOKS (Settings -> Extreme Weather -> "Dust look"). Taste
## only: none of these reach visibility_m, AOD, PM or the energy channels.
## Defaults are tuned to a playa whiteout photo (pale grey-beige, sky gone,
## near objects just visible).
const SECTION_DUST_LOOK := "dust_look"
const DUST_COLOR_DEFAULT := Color(0.82, 0.79, 0.74)
## The measured visibility of even a full storm (~370 m) is clearer than a
## playa whiteout photo (~50-100 m), so the shipped look closes in 2x.
const DUST_THICKNESS_DEFAULT := 2.0
const DUST_THICKNESS_MIN := 0.25
const DUST_THICKNESS_MAX := 3.0
const DUST_HEIGHT_MIN := 0.25
const DUST_HEIGHT_MAX := 4.0
## Haze colour (fog, sky, the ground layer).
static var dust_color: Color = DUST_COLOR_DEFAULT
## Multiplier on the fog the dust's visibility implies.
static var dust_thickness: float = DUST_THICKNESS_DEFAULT
## 0..1: how much of the sky a full storm hides (sun, clouds and stars too).
static var dust_sky: float = 1.0
## Multiplier on the ground layer's height.
static var dust_height: float = 1.0
## 0..1: how strongly the dust streams in bands along the wind.
static var dust_streaks: float = 0.6

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
	set_dust_wind_mph(float(cfg.get_value(SECTION_DUST, "wind_mph", dust_wind_mph)))
	set_dust_dry_hours(float(cfg.get_value(SECTION_DUST, "dry_hours", dust_dry_hours)))
	dust_climate_scale = bool(cfg.get_value(SECTION_DUST, "climate_scale", dust_climate_scale))
	var col: Variant = cfg.get_value(SECTION_DUST_LOOK, "color", dust_color)
	if col is Color:
		set_dust_color(col as Color)
	set_dust_thickness(float(cfg.get_value(SECTION_DUST_LOOK, "thickness", dust_thickness)))
	set_dust_sky(float(cfg.get_value(SECTION_DUST_LOOK, "sky", dust_sky)))
	set_dust_height(float(cfg.get_value(SECTION_DUST_LOOK, "height", dust_height)))
	set_dust_streaks(float(cfg.get_value(SECTION_DUST_LOOK, "streaks", dust_streaks)))
	for id: String in HazardCatalog.ids():
		if cfg.has_section_key(SECTION, id):
			_enabled[id] = bool(cfg.get_value(SECTION, id))


static func save() -> void:
	ensure_loaded()
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)  # preserve any other sections
	cfg.set_value(SECTION_GLOBAL, "intensity", intensity)
	cfg.set_value(SECTION_GLOBAL, "notify", notify)
	cfg.set_value(SECTION_DUST, "wind_mph", dust_wind_mph)
	cfg.set_value(SECTION_DUST, "dry_hours", dust_dry_hours)
	cfg.set_value(SECTION_DUST, "climate_scale", dust_climate_scale)
	cfg.set_value(SECTION_DUST_LOOK, "color", dust_color)
	cfg.set_value(SECTION_DUST_LOOK, "thickness", dust_thickness)
	cfg.set_value(SECTION_DUST_LOOK, "sky", dust_sky)
	cfg.set_value(SECTION_DUST_LOOK, "height", dust_height)
	cfg.set_value(SECTION_DUST_LOOK, "streaks", dust_streaks)
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


static func set_dust_wind_mph(v: float) -> void:
	dust_wind_mph = clampf(v, DUST_WIND_MPH_MIN, DUST_WIND_MPH_MAX) if is_finite(v) else 10.0


static func set_dust_dry_hours(v: float) -> void:
	dust_dry_hours = clampf(v, DUST_DRY_HOURS_MIN, DUST_DRY_HOURS_MAX) if is_finite(v) else 24.0


static func set_dust_color(c: Color) -> void:
	if is_finite(c.r) and is_finite(c.g) and is_finite(c.b):
		dust_color = Color(clampf(c.r, 0.0, 1.0), clampf(c.g, 0.0, 1.0), clampf(c.b, 0.0, 1.0))
	else:
		dust_color = DUST_COLOR_DEFAULT


static func set_dust_thickness(v: float) -> void:
	dust_thickness = clampf(v, DUST_THICKNESS_MIN, DUST_THICKNESS_MAX) if is_finite(v) else DUST_THICKNESS_DEFAULT


static func set_dust_sky(v: float) -> void:
	dust_sky = clampf(v, 0.0, 1.0) if is_finite(v) else 1.0


static func set_dust_height(v: float) -> void:
	dust_height = clampf(v, DUST_HEIGHT_MIN, DUST_HEIGHT_MAX) if is_finite(v) else 1.0


static func set_dust_streaks(v: float) -> void:
	dust_streaks = clampf(v, 0.0, 1.0) if is_finite(v) else 0.6


## Back to the shipped dust look (the Settings "Reset look" button).
static func reset_dust_look() -> void:
	dust_color = DUST_COLOR_DEFAULT
	dust_thickness = DUST_THICKNESS_DEFAULT
	dust_sky = 1.0
	dust_height = 1.0
	dust_streaks = 0.6


static func dust_wind_threshold_ms() -> float:
	ensure_loaded()
	return dust_wind_mph * HazardEvaluators.MPH_TO_MS


## A hazard contributes only when it is both opted in AND actually implemented.
## Every consumer should ask this rather than `is_enabled`, so the seven
## risk-profile-only entries can stay toggleable in the UI (they still shape the
## risk display) without ever producing a state.
static func is_active(id: String) -> bool:
	return HazardCatalog.is_simulated(id) and is_enabled(id)


## Test support: in-memory defaults WITHOUT reading the player's file, so a
## selftest's results never depend on their saved taste.
static func use_defaults_for_test() -> void:
	reset_for_test()
	_loaded = true


## Test/harness support: drop in-memory state so the next read re-loads from
## disk. Does NOT touch the file.
static func reset_for_test() -> void:
	_loaded = false
	_enabled = {}
	intensity = 1.0
	notify = true
	dust_wind_mph = 10.0
	dust_dry_hours = 24.0
	dust_climate_scale = true
	reset_dust_look()
