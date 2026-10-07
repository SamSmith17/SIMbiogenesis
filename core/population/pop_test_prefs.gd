class_name PopTestPrefs
extends RefCounted

## Testing / playability switches for the population simulation — the
## "turn the guardrails off" set the user asked for, plus the default
## provisioning preset new camps are stocked with. Global prefs in
## `user://pop_testing.cfg` (the ExtremeWeatherPrefs pattern): they are about
## how YOU want to test, not a property of a site, so they never ride a save.
##
## - ideal_supply:    every need is met as if the infrastructure were perfect.
##                    Habitats never starve (the shortfall is counted as an
##                    IDEAL IMPORT and stamped on the habitat so the ledger and
##                    the inspector can show what would have to be supplied);
##                    a need with no space tagged — or every space full — is
##                    satisfied where the person stands; waste with no sink is
##                    counted as exported. Consumption is still billed, so the
##                    numbers it produces ARE the optimal demand curve.
## - ignore_capacity: spaces never fill — no queues, no "everything is full".
## - no_departures:   nobody rage-quits, perishes or collapses the colony.
## - mute_alarms:     the settlement log records nothing (no alarms, toasts,
##                    feed lines, dashboard alerts).
## Under --script (selftests) nothing loads the file, so every flag reads
## false and the pure cores behave exactly as before.
##
## EASY-MODE OVERRIDE (festival mode): `set_easy_override(true)` makes every
## accessor read ON for the SESSION without touching the saved flags, so
## leaving festival mode hands the player's own testing prefs back exactly.
## It is deliberately not persisted — it belongs to the mode, not the file.

const CFG_PATH := "user://pop_testing.cfg"
const SECTION := "testing"

const DEFAULT_PRESET := "weekend"

static var _loaded := false
static var _ideal_supply := false
static var _ignore_capacity := false
static var _no_departures := false
static var _mute_alarms := false
static var _provision_preset := DEFAULT_PRESET
static var _generation := 0
static var _easy_override := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	load_from(CFG_PATH)


static func load_from(path: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return false
	_ideal_supply = bool(cfg.get_value(SECTION, "ideal_supply", _ideal_supply))
	_ignore_capacity = bool(cfg.get_value(SECTION, "ignore_capacity", _ignore_capacity))
	_no_departures = bool(cfg.get_value(SECTION, "no_departures", _no_departures))
	_mute_alarms = bool(cfg.get_value(SECTION, "mute_alarms", _mute_alarms))
	_provision_preset = str(cfg.get_value(SECTION, "provision_preset", _provision_preset))
	if not CampProvisioning.PRESETS.has(_provision_preset):
		_provision_preset = DEFAULT_PRESET
	_generation += 1
	return true


static func save() -> void:
	save_to(CFG_PATH)


static func save_to(path: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(path)   # preserve any other sections
	cfg.set_value(SECTION, "ideal_supply", _ideal_supply)
	cfg.set_value(SECTION, "ignore_capacity", _ignore_capacity)
	cfg.set_value(SECTION, "no_departures", _no_departures)
	cfg.set_value(SECTION, "mute_alarms", _mute_alarms)
	cfg.set_value(SECTION, "provision_preset", _provision_preset)
	cfg.save(path)


## Bumps whenever a flag changes — pollers compare it instead of re-reading.
static func generation() -> int:
	return _generation


static func ideal_supply() -> bool:
	ensure_loaded()
	return _ideal_supply or _easy_override


static func ignore_capacity() -> bool:
	ensure_loaded()
	return _ignore_capacity or _ideal_supply or _easy_override


static func no_departures() -> bool:
	ensure_loaded()
	return _no_departures or _easy_override


static func mute_alarms() -> bool:
	ensure_loaded()
	return _mute_alarms or _easy_override


## The festival mode's session switch: every guardrail off, nothing saved.
static func set_easy_override(on: bool) -> void:
	ensure_loaded()
	if _easy_override == on:
		return
	_easy_override = on
	_generation += 1


static func easy_override() -> bool:
	return _easy_override


## The SAVED flag values, regardless of the override — what the settings tab
## shows, so its checkboxes never pretend the player ticked them.
static func saved_flags() -> Dictionary:
	ensure_loaded()
	return {"ideal_supply": _ideal_supply, "ignore_capacity": _ignore_capacity,
		"no_departures": _no_departures, "mute_alarms": _mute_alarms}


static func provision_preset() -> String:
	ensure_loaded()
	return _provision_preset


static func set_ideal_supply(on: bool) -> void:
	ensure_loaded()
	_ideal_supply = on
	_generation += 1


static func set_ignore_capacity(on: bool) -> void:
	ensure_loaded()
	_ignore_capacity = on
	_generation += 1


static func set_no_departures(on: bool) -> void:
	ensure_loaded()
	_no_departures = on
	_generation += 1


static func set_mute_alarms(on: bool) -> void:
	ensure_loaded()
	_mute_alarms = on
	_generation += 1


static func set_provision_preset(id: String) -> void:
	ensure_loaded()
	_provision_preset = id if CampProvisioning.PRESETS.has(id) else DEFAULT_PRESET
	_generation += 1


## True when any guardrail is off — the HUD shows a "testing" tag then.
static func any_active() -> bool:
	ensure_loaded()
	return _ideal_supply or _ignore_capacity or _no_departures or _mute_alarms or _easy_override


## Reset to the shipped defaults (selftests use this between cases).
static func reset_defaults() -> void:
	_loaded = true
	_ideal_supply = false
	_ignore_capacity = false
	_no_departures = false
	_mute_alarms = false
	_provision_preset = DEFAULT_PRESET
	_easy_override = false
	_generation += 1
