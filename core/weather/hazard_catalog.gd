class_name HazardCatalog
extends RefCounted

## Extreme-weather hazard definitions, as PURE data.
##
## The whole framework rests on this table: a hazard "exists" when it has a row
## here, and it becomes *simulated* when it also has a resolver in
## HazardEvaluators. Everything else — the settings tab, the risk profile, the
## timeline bands, the capture harness — enumerates this file rather than
## hardcoding a hazard list, so adding the twelfth hazard is a data edit plus one
## resolver, not a new subsystem.
##
## Same precedent as RenderProfile / ComponentPresets: the mapping
## `hazard id -> properties` is a pure function with no engine state, so it is
## pinned by core/weather/extreme_weather_selftest.gd while the *application*
## lives where the nodes are (main.gd for atmosphere, solar_ui for energy,
## npc_weather_gate for people).
##
## NOTE ON VTEC CODES. The codes below are the authority for mapping a National
## Weather Service alert onto a hazard, NOT the English event names.
## `NwsAlertService._vtec_to_event_name()` renders a name for display and does
## not cover every code we care about — HU/TY/TR/SS/HW/EH/WC/ZR/AF all fall
## through it to the bare phenomena string. Matching on the code is both more
## complete and immune to NWS re-wording an event name.

## Stable display/enumeration order. Persisted prefs key off the ID string, not
## this index, so entries may be reordered freely — unlike RenderProfile's
## quality indices.
const HAZARD_IDS: Array[String] = [
	"wildfire_smoke",
	"dust_storm",
	"damaging_winds",
	"heatwave",
	"flooding",
	"blizzard",
	"ice_storm",
	"hailstorm",
	"cold_snap",
	"storm_surge",
	"blackout",
]

## Severity floor implied by a VTEC significance code, before the measured
## drivers shape it. A Dust Storm WARNING must outrank a Dust Storm ADVISORY —
## collapsing them would make a genuine haboob read the same as blowing dust on
## a windy afternoon.
##   W = Warning   (occurring / imminent)
##   A = Watch     (conditions favourable)
##   Y = Advisory  (less serious, still hazardous)
##   S = Statement (informational follow-up)
const SIGNIFICANCE_SEVERITY: Dictionary = {
	"W": 0.75,
	"A": 0.35,
	"Y": 0.45,
	"S": 0.20,
}

## Risk-rank bands, in events per decade, derived from the site's own VTEC
## history. Thresholds are pinned by the selftest so the settings tab's badges
## cannot drift from the numbers beside them.
const RISK_NONE := "none"
const RISK_LOW := "low"
const RISK_MODERATE := "moderate"
const RISK_HIGH := "high"
const RISK_SEVERE := "severe"
const RISK_UNKNOWN := "unknown"

const RISK_BANDS: Array = [
	{"level": RISK_SEVERE, "per_decade": 20.0},
	{"level": RISK_HIGH, "per_decade": 8.0},
	{"level": RISK_MODERATE, "per_decade": 2.0},
	{"level": RISK_LOW, "per_decade": 0.5},
]

## The table. Keys:
##   name              player-facing label
##   icon              one glyph for the settings row and timeline band
##   blurb             one sentence, shown in the settings tab
##   category          "air" | "wind" | "thermal" | "water" | "system"
##   simulated         true = has a resolver and renders; false = risk-profile only
##   vtec              NWS VTEC phenomena codes that indicate this hazard
##   drivers           data channels the resolver needs (documentation + the
##                     "why is this greyed out" message when a channel is absent)
##   default_enabled   opt-in state on a fresh install
##   notify_threshold  severity at which a toast fires
const HAZARDS: Dictionary = {
	"wildfire_smoke": {
		"name": "Wildfire Smoke",
		"icon": "🔥",
		"blurb": "Smoke plumes cut visibility, turn the sun red and collapse direct solar output.",
		"category": "air",
		"simulated": true,
		# SM = Dense Smoke. FW = Red Flag (fire-weather conditions) — a leading
		# indicator rather than smoke itself, so the resolver weights it lower.
		"vtec": ["SM", "FW"],
		"drivers": ["pm2_5", "aerosol_optical_depth", "us_aqi"],
		"default_enabled": true,
		"notify_threshold": 0.30,
	},
	"dust_storm": {
		"name": "Dust Storm",
		"icon": "🌪",
		"blurb": "Wind-lifted dust forms a glowing wall that blots out the sun and scours everything.",
		"category": "air",
		"simulated": true,
		"vtec": ["DS", "DU"],
		"drivers": ["dust", "pm10", "wind_speed_10m", "precipitation"],
		"default_enabled": true,
		"notify_threshold": 0.30,
	},
	"damaging_winds": {
		"name": "Damaging Winds",
		"icon": "🌀",
		"blurb": "Gales, hurricanes and typhoons — turbines shut down and outdoor work stops.",
		"category": "wind",
		"simulated": true,
		# HW = High Wind, WI = Wind, EW = Extreme Wind, HU = Hurricane,
		# TY = Typhoon, TR = Tropical Storm. NwsAlertService names only WI/EW.
		"vtec": ["HW", "WI", "EW", "HU", "TY", "TR"],
		"drivers": ["wind_speed_10m", "windgusts_10m"],
		"default_enabled": true,
		"notify_threshold": 0.35,
	},
	"heatwave": {
		"name": "Heatwave",
		"icon": "🌡",
		"blurb": "Sustained extreme heat derates panels, drains water and halts labour.",
		"category": "thermal",
		"simulated": true,
		# EH = Excessive Heat, HT = Heat. NwsAlertService names only HT.
		"vtec": ["EH", "HT"],
		"drivers": ["temperature_2m", "relative_humidity_2m"],
		"default_enabled": true,
		"notify_threshold": 0.35,
	},
	"flooding": {
		"name": "Flooding",
		"icon": "🌊",
		"blurb": "Extreme rainfall overwhelms catchments and inundates low ground.",
		"category": "water",
		"simulated": false,
		# FF = Flash Flood, FA = Areal Flood, FL = Forecast-point Flood.
		"vtec": ["FF", "FA", "FL"],
		"drivers": ["precipitation", "rain_24h"],
		"default_enabled": true,
		"notify_threshold": 0.35,
	},
	"blizzard": {
		"name": "Blizzard",
		"icon": "❄",
		"blurb": "Heavy snow driven by high wind — whiteout visibility and buried arrays.",
		"category": "thermal",
		"simulated": false,
		"vtec": ["BZ", "WS", "HS", "WW"],
		"drivers": ["snowfall", "wind_speed_10m", "temperature_2m"],
		"default_enabled": true,
		"notify_threshold": 0.35,
	},
	"ice_storm": {
		"name": "Ice Storm",
		"icon": "🧊",
		"blurb": "Freezing rain glazes every surface, loading conductors and stopping turbines.",
		"category": "thermal",
		"simulated": false,
		# ZR = Freezing Rain, IS = Ice Storm, IP = Sleet.
		"vtec": ["IS", "ZR", "IP"],
		"drivers": ["precipitation", "temperature_2m"],
		"default_enabled": true,
		"notify_threshold": 0.35,
	},
	"hailstorm": {
		"name": "Hailstorm",
		"icon": "🌨",
		"blurb": "Severe convective hail — the classic way a solar array dies in ten minutes.",
		"category": "water",
		"simulated": false,
		"vtec": ["SV"],
		"drivers": ["precipitation", "temperature_2m"],
		"default_enabled": true,
		"notify_threshold": 0.40,
	},
	"cold_snap": {
		"name": "Cold Snap",
		"icon": "🥶",
		"blurb": "Extreme cold cuts battery capacity and makes every outdoor task dangerous.",
		"category": "thermal",
		"simulated": false,
		# EC = Extreme Cold, WC = Wind Chill, FZ = Freeze, HZ = Hard Freeze, FR = Frost.
		"vtec": ["EC", "WC", "FZ", "HZ", "FR"],
		"drivers": ["temperature_2m", "wind_speed_10m"],
		"default_enabled": true,
		"notify_threshold": 0.35,
	},
	"storm_surge": {
		"name": "Storm Surge",
		"icon": "🌊",
		"blurb": "Wind-driven sea rise floods coastal sites well beyond the normal tide line.",
		"category": "water",
		"simulated": false,
		"vtec": ["SS"],
		"drivers": ["wind_speed_10m", "coastline"],
		"default_enabled": true,
		"notify_threshold": 0.40,
	},
	"blackout": {
		"name": "Grid Blackout",
		"icon": "⚡",
		"blurb": "The utility connection fails — the moment an off-grid system justifies itself.",
		"category": "system",
		"simulated": false,
		# No VTEC phenomenon: a blackout is a consequence, not a forecast product.
		# Its risk is derived from the other hazards, never observed directly.
		"vtec": [],
		"drivers": [],
		"default_enabled": true,
		"notify_threshold": 0.10,
	},
}


static func ids() -> Array[String]:
	return HAZARD_IDS.duplicate()


static func has_id(id: String) -> bool:
	return HAZARDS.has(id)


## Unknown ids return an empty dict rather than pushing an error: the settings
## tab and the risk profile both read persisted ids, and a pref file written by
## a newer build must degrade quietly instead of spamming the log.
static func get_def(id: String) -> Dictionary:
	var d: Variant = HAZARDS.get(id, null)
	return (d as Dictionary) if d is Dictionary else {}


static func display_name(id: String) -> String:
	var d := get_def(id)
	return str(d.get("name", id))


static func icon(id: String) -> String:
	return str(get_def(id).get("icon", "•"))


static func is_simulated(id: String) -> bool:
	return bool(get_def(id).get("simulated", false))


## The subset that actually renders and affects the sim.
static func simulated_ids() -> Array[String]:
	var out: Array[String] = []
	for id: String in HAZARD_IDS:
		if is_simulated(id):
			out.append(id)
	return out


static func default_enabled(id: String) -> bool:
	return bool(get_def(id).get("default_enabled", true))


static func notify_threshold(id: String) -> float:
	return float(get_def(id).get("notify_threshold", 0.35))


## VTEC phenomena code -> hazard id. Built once on first use rather than stored
## as a second const, so the codes cannot drift out of step with HAZARDS.
static var _vtec_map: Dictionary = {}


static func vtec_map() -> Dictionary:
	if _vtec_map.is_empty():
		for id: String in HAZARD_IDS:
			for code: String in (get_def(id).get("vtec", []) as Array):
				_vtec_map[code] = id
	return _vtec_map


## Resolve an alert to a hazard id, preferring the VTEC code and falling back to
## the rendered event name. "" when the alert is not one of ours (most of them
## are not — Marine, Dense Fog, Tornado and Special Statements all land here).
static func id_for_alert(phenomena: String, event_name: String = "") -> String:
	var code := phenomena.strip_edges().to_upper()
	if not code.is_empty():
		var hit: String = str(vtec_map().get(code, ""))
		if not hit.is_empty():
			return hit
	return id_for_event_name(event_name)


## Name-based fallback, for cached IEM rows that predate the service carrying
## VTEC codes through. Deliberately conservative: it matches the distinctive
## noun only, so "Dense Smoke Advisory" hits and "Special Weather Statement"
## does not.
static func id_for_event_name(event_name: String) -> String:
	var s := event_name.strip_edges().to_lower()
	if s.is_empty():
		return ""
	if s.contains("smoke"):
		return "wildfire_smoke"
	if s.contains("red flag") or s.contains("fire weather"):
		return "wildfire_smoke"
	if s.contains("dust"):
		return "dust_storm"
	if s.contains("hurricane") or s.contains("typhoon") or s.contains("tropical storm"):
		return "damaging_winds"
	if s.contains("wind") and not s.contains("chill"):
		return "damaging_winds"
	if s.contains("heat"):
		return "heatwave"
	if s.contains("surge"):
		return "storm_surge"
	if s.contains("flood"):
		return "flooding"
	if s.contains("blizzard") or s.contains("snow") or s.contains("winter"):
		return "blizzard"
	if s.contains("ice") or s.contains("freezing rain") or s.contains("sleet"):
		return "ice_storm"
	if s.contains("thunderstorm") or s.contains("hail"):
		return "hailstorm"
	if s.contains("cold") or s.contains("freeze") or s.contains("frost") or s.contains("chill"):
		return "cold_snap"
	return ""


## Base severity for an alert of this significance, before measured drivers
## shape it into an hourly curve.
static func severity_for_significance(significance: String) -> float:
	return float(SIGNIFICANCE_SEVERITY.get(significance.strip_edges().to_upper(), 0.45))


## Events-per-decade -> risk band. Monotonic by construction (RISK_BANDS is
## ordered descending), which the selftest pins.
static func risk_level_for_rate(events_per_decade: float) -> String:
	if not is_finite(events_per_decade) or events_per_decade <= 0.0:
		return RISK_NONE
	for band: Dictionary in RISK_BANDS:
		if events_per_decade >= float(band["per_decade"]):
			return str(band["level"])
	return RISK_NONE


static func risk_label(level: String) -> String:
	match level:
		RISK_SEVERE: return "SEVERE"
		RISK_HIGH: return "HIGH"
		RISK_MODERATE: return "MODERATE"
		RISK_LOW: return "LOW"
		RISK_UNKNOWN: return "UNKNOWN"
	return "NOT OBSERVED"


## 0..1 fill for the settings tab's risk bar. RISK_UNKNOWN returns 0 — the row
## renders the bar empty and says so in text rather than implying "safe".
static func risk_fill(level: String) -> float:
	match level:
		RISK_SEVERE: return 1.0
		RISK_HIGH: return 0.75
		RISK_MODERATE: return 0.5
		RISK_LOW: return 0.25
	return 0.0
