class_name PlacedLightStyles
extends RefCounted

## Linked light styles — pure, no scene access.
##
## A placed light carries `style_id` + a sparse `overrides` dict. What it
## renders with is always
##
##     resolve(kind, style_fields, overrides) = defaults(kind) ⊕ style ⊕ overrides
##
## so editing a style restyles every light using it (the SketchUp-component
## model the graph already uses for super-nodes), while a per-light override
## survives the edit. Only keys in `style_keys(kind)` are style data; position,
## rotation, waypoints and graph binding are the LIGHT's own and never resolve
## through a style.

const KINDS: Array[String] = ["omni", "spot", "string", "mover"]

const FX_KEYS: Array[String] = ["effect", "fx_speed", "fx_span", "fx_gap",
	"fx_saturation", "fx_direction", "fx_pause_with_sim"]

## Moving fixtures ("mover" kind): what the head carries.
const FIXTURES: Array[String] = ["beam", "spot", "wash", "laser", "projector"]
const FIXTURE_LABELS: Array[String] = ["Beam (narrow, hard edge)", "Spot (gobo)",
	"Wash / PAR (wide, soft)", "Laser", "Gobo projector"]
## Sweep programs (MoverProgram).
const PROGRAMS: Array[String] = ["static", "pan_sweep", "tilt_sweep", "circle", "figure8", "wander"]
const PROGRAM_LABELS: Array[String] = ["Static", "Pan sweep", "Tilt sweep", "Circle",
	"Figure-8", "Wander (ballyhoo)"]
## Procedural gobos (MoverGobo).
const GOBOS: Array[String] = ["none", "dots", "star", "breakup", "rings", "bars"]

## Presets per kind: {id: {label, fields}}. `spot_angle` is Godot's HALF-angle
## (axis to edge); product sheets quote the FULL beam angle, i.e. twice it. Each one is a real look a festival
## crew would hang, with its numbers taken from typical product data (beam
## angles, pixel pitch, wattage) — a starting point, every field stays editable.
## Choosing one for NEW lights makes (or reuses) a STYLE named after it, so
## every light placed from a preset can still be restyled together.
## String presets borrow their physical defaults from the conduit light kinds
## (system_graph/data/conduit_kinds.gd led_patio / led_fairy / led_strip), so a
## J-placed string and a graph-wired one look the same out of the box.
const PRESETS := {
	"omni": {
		"lantern": {"label": "Lantern (warm flicker)", "fields": {"color": "ffae5c",
			"energy": 1.4, "range": 7.0, "effect": "flicker", "fx_speed": 6.0,
			"show_body": true, "watts": 6.0}},
		"brazier": {"label": "Fire barrel / brazier glow", "fields": {"color": "ff6a1f",
			"energy": 3.0, "range": 11.0, "effect": "flicker", "fx_speed": 9.0,
			"shadow_enabled": true, "watts": 0.0}},
		"party_bulb": {"label": "Party bulb (colour cycle)", "fields": {"color": "ffffff",
			"energy": 2.0, "range": 9.0, "effect": "rainbow_chase", "fx_speed": 0.6,
			"fx_span": 12.0, "show_body": true, "watts": 9.0}},
		"area_5000k": {"label": "Area light (5000 K)", "fields": {"color": "fff0e4",
			"energy": 4.0, "range": 28.0, "watts": 60.0}},
		"blacklight": {"label": "Blacklight (UV)", "fields": {"color": "6a2bff",
			"energy": 2.2, "range": 10.0, "watts": 18.0}},
	},
	"spot": {
		"uplight_par": {"label": "Uplight PAR (purple)", "fields": {"color": "9a3bff",
			"energy": 5.0, "range": 16.0, "spot_angle": 13.0, "spot_softness": 1.4,
			"watts": 54.0}},
		"tree_uplight": {"label": "Tree uplight (green)", "fields": {"color": "39ff7a",
			"energy": 5.0, "range": 18.0, "spot_angle": 10.0, "spot_softness": 1.2,
			"watts": 36.0}},
		"flood_4000k": {"label": "Floodlight (4000 K)", "fields": {"color": "ffe6cc",
			"energy": 7.0, "range": 40.0, "spot_angle": 50.0, "spot_softness": 2.0,
			"watts": 150.0}},
		"pin_spot": {"label": "Art pin spot (warm)", "fields": {"color": "ffd29a",
			"energy": 6.0, "range": 25.0, "spot_angle": 2.5, "spot_softness": 0.3,
			"watts": 15.0}},
	},
	"string": {
		"patio": {"label": "Patio festoon (S14)", "conduit": "led_patio", "fields": {
			"bulb_spacing_m": 0.9, "bulb_size": 0.06, "sag": 0.35, "wire_color": "141414",
			"color": "ffd18c", "energy": 2.5, "continuous": false, "watts_per_m": 3.3}},
		"fairy": {"label": "Fairy lights", "conduit": "led_fairy", "fields": {
			"bulb_spacing_m": 0.15, "bulb_size": 0.018, "sag": 0.3, "wire_color": "59503a",
			"color": "ffe0a6", "energy": 3.0, "continuous": false, "watts_per_m": 0.6}},
		"strip": {"label": "Pixel strip (60/m addressable)", "conduit": "led_strip", "fields": {
			"bulb_spacing_m": 0.0167, "bulb_size": 0.01, "sag": 0.05, "wire_color": "d9d9cc",
			"color": "ffffff", "energy": 2.0, "continuous": false, "watts_per_m": 14.0}},
		"pixel_rainbow": {"label": "Bullet pixels (rainbow chase)", "conduit": "led_strip",
			"fields": {"bulb_spacing_m": 0.1, "bulb_size": 0.014, "sag": 0.25,
			"wire_color": "1a1a1a", "color": "ffffff", "energy": 3.0, "continuous": false,
			"effect": "rainbow_chase", "fx_speed": 18.0, "fx_span": 40.0, "watts_per_m": 3.0}},
		# Continuous tubes: the TUBE glows (led_rope.gdshader), pixels every
		# 1/leds_per_m along it, diffused into one even line of light.
		"rope": {"label": "LED rope light (13 mm)", "conduit": "led_strip", "fields": {
			"continuous": true, "tube_diameter_mm": 13.0, "leds_per_m": 36.0, "sag": 0.08,
			"color": "ffb766", "energy": 2.2, "real_lights": 6, "light_range": 3.0,
			"watts_per_m": 2.3}},
		"neon_flex": {"label": "LED neon flex (addressable)", "conduit": "led_strip", "fields": {
			"continuous": true, "tube_diameter_mm": 14.0, "leds_per_m": 60.0, "sag": 0.05,
			"color": "ff2fb4", "energy": 3.5, "real_lights": 8, "light_range": 4.0,
			"watts_per_m": 9.6}},
		"glass_neon": {"label": "Glass neon tube", "conduit": "led_strip", "fields": {
			"continuous": true, "tube_diameter_mm": 12.0, "leds_per_m": 100.0, "sag": 0.0,
			"color": "ff3d1f", "energy": 4.5, "real_lights": 6, "light_range": 3.5,
			"watts_per_m": 15.0}},
		"el_wire": {"label": "EL wire", "conduit": "led_fairy", "fields": {
			"continuous": true, "tube_diameter_mm": 2.3, "leds_per_m": 100.0, "sag": 0.3,
			"color": "3dfff0", "energy": 1.4, "real_lights": 0, "light_range": 1.0,
			"watts_per_m": 0.5}},
	},
	"mover": {
		"beam_sweep": {"label": "Moving-head beam (sweep)", "fields": {"fixture": "beam",
			"color": "f4f6ff", "energy": 12.0, "range": 120.0, "spot_angle": 2.0,
			"spot_softness": 0.15, "program": "pan_sweep", "prog_speed": 8.0,
			"tilt_center": 25.0, "pan_range": 70.0, "tilt_range": 10.0, "beam_haze": 0.6,
			"watts": 330.0}},
		"beam_color_fan": {"label": "Beam fan (colour cycle)", "fields": {"fixture": "beam",
			"color": "ffffff", "energy": 12.0, "range": 120.0, "spot_angle": 2.0,
			"spot_softness": 0.15, "program": "tilt_sweep", "prog_speed": 10.0,
			"tilt_center": 35.0, "tilt_range": 30.0, "effect": "rainbow_chase",
			"fx_speed": 1.0, "fx_span": 8.0, "beam_haze": 0.6, "watts": 330.0}},
		"spot_gobo": {"label": "Moving-head spot (gobo)", "fields": {"fixture": "spot",
			"color": "7f5cff", "energy": 10.0, "range": 60.0, "spot_angle": 7.0,
			"spot_softness": 0.5, "gobo": "breakup", "gobo_spin": 6.0, "program": "circle",
			"prog_speed": 4.0, "tilt_center": 35.0, "pan_range": 40.0, "tilt_range": 15.0,
			"beam_haze": 0.35, "watts": 250.0}},
		"wash_uplight": {"label": "LED wash / PAR uplight", "fields": {"fixture": "wash",
			"color": "c02bff", "energy": 6.0, "range": 18.0, "spot_angle": 15.0,
			"spot_softness": 1.6, "program": "static", "tilt_center": 0.0, "beam_haze": 0.12,
			"watts": 150.0}},
		"skytracker": {"label": "Sky tracker (searchlight)", "fields": {"fixture": "beam",
			"color": "f2f4ff", "energy": 40.0, "range": 600.0, "spot_angle": 0.8,
			"spot_softness": 0.1, "program": "circle", "prog_speed": 2.0, "tilt_center": 20.0,
			"pan_range": 180.0, "tilt_range": 6.0, "beam_haze": 0.8, "watts": 2000.0}},
		"laser_fan_green": {"label": "Laser fan (green 532 nm)", "fields": {"fixture": "laser",
			"color": "2bff4a", "energy": 1.0, "range": 250.0, "laser_beams": 7.0,
			"laser_fan_deg": 40.0, "program": "tilt_sweep", "prog_speed": 10.0,
			"tilt_center": 70.0, "tilt_range": 12.0, "beam_haze": 0.9, "watts": 100.0}},
		"laser_rgb_scan": {"label": "RGB laser (scanning)", "fields": {"fixture": "laser",
			"color": "ff2244", "energy": 1.0, "range": 250.0, "laser_beams": 1.0,
			"laser_fan_deg": 0.0, "program": "wander", "prog_speed": 12.0,
			"tilt_center": 60.0, "pan_range": 60.0, "tilt_range": 25.0, "effect": "rainbow_chase",
			"fx_speed": 0.8, "fx_span": 6.0, "beam_haze": 0.9, "watts": 120.0}},
		"gobo_projector": {"label": "Gobo projector (dots)", "fields": {"fixture": "projector",
			"color": "ffffff", "energy": 8.0, "range": 40.0, "spot_angle": 12.0,
			"spot_softness": 0.4, "gobo": "dots", "gobo_spin": 2.0, "program": "static",
			"tilt_center": 60.0, "effect": "rainbow_chase", "fx_speed": 0.4, "fx_span": 6.0,
			"beam_haze": 0.1, "watts": 100.0}},
		"strobe": {"label": "Strobe (white, 8 Hz)", "fields": {"fixture": "wash",
			"color": "ffffff", "energy": 14.0, "range": 30.0, "spot_angle": 35.0,
			"spot_softness": 2.0, "program": "static", "tilt_center": 0.0, "effect": "strobe",
			"fx_speed": 8.0, "beam_haze": 0.05, "watts": 400.0}},
	},
}
const PRESET_ORDER := {
	"omni": ["lantern", "brazier", "party_bulb", "area_5000k", "blacklight"],
	"spot": ["uplight_par", "tree_uplight", "flood_4000k", "pin_spot"],
	"string": ["patio", "fairy", "strip", "pixel_rainbow", "rope", "neon_flex",
		"glass_neon", "el_wire"],
	"mover": ["beam_sweep", "beam_color_fan", "spot_gobo", "wash_uplight", "skytracker",
		"laser_fan_green", "laser_rgb_scan", "gobo_projector", "strobe"],
}
## Back-compat alias (the string presets were the only ones in v3.0).
const STRING_PRESETS: Dictionary = PRESETS["string"]
const STRING_PRESET_ORDER: Array = ["patio", "fairy", "strip", "pixel_rainbow", "rope",
	"neon_flex", "glass_neon", "el_wire"]


static func defaults(kind: String) -> Dictionary:
	var d := {
		"preset": "",
		"color": "ffffff",
		"energy": 1.0,
		"fade_m": 0.0,
		"schedule": "always",
		"effect": "solid",
		"fx_speed": 6.0,
		"fx_span": 24.0,
		"fx_gap": 3.0,
		"fx_saturation": 1.0,
		"fx_direction": 1.0,
		"fx_pause_with_sim": false,
		# Draw the lamp itself. Off for omni/spot — the scene shows only the
		# light, and the IK sphere only while J is open; on for strings (the
		# bulbs ARE the look) and movers (the fixture is stage gear you see).
		"show_body": kind == "string" or kind == "mover",
		# Rated draw for "Add to graph" (0 = estimate from energy).
		"watts": 0.0,
	}
	match kind:
		"spot":
			d["range"] = 12.0
			d["attenuation"] = 1.0
			d["shadow_enabled"] = true
			d["spot_angle"] = 35.0
			d["spot_softness"] = 1.0
		"string":
			var p: Dictionary = (PRESETS["string"]["patio"] as Dictionary)["fields"]
			d["preset"] = "patio"
			for k in p.keys():
				d[k] = p[k]
			d["real_lights"] = 6
			d["light_range"] = 4.0
			d["schedule"] = "dusk_dawn"
			d["tube_diameter_mm"] = 13.0
			d["leds_per_m"] = 36.0
		"mover":
			var m: Dictionary = (PRESETS["mover"]["beam_sweep"] as Dictionary)["fields"]
			d["preset"] = "beam_sweep"
			d["attenuation"] = 0.6
			d["shadow_enabled"] = false
			d["schedule"] = "dusk_dawn"
			d["pan_center"] = 0.0
			d["phase_deg"] = 0.0
			d["gobo"] = "none"
			d["gobo_spin"] = 0.0
			d["laser_beams"] = 1.0
			d["laser_fan_deg"] = 0.0
			d["pan_range"] = 0.0
			d["tilt_range"] = 0.0
			for k in m.keys():
				d[k] = m[k]
		_:
			d["range"] = 10.0
			d["attenuation"] = 1.0
			d["shadow_enabled"] = true
	return d


static func style_keys(kind: String) -> Array:
	return defaults(kind).keys()


static func is_style_key(kind: String, key: String) -> bool:
	return defaults(kind).has(key)


## defaults ⊕ style ⊕ overrides, restricted to the kind's style keys.
static func resolve(kind: String, style_fields: Dictionary, overrides: Dictionary) -> Dictionary:
	var out := defaults(kind)
	for k in style_fields.keys():
		if out.has(k):
			out[k] = style_fields[k]
	for k in overrides.keys():
		if out.has(k):
			out[k] = overrides[k]
	return out


## Override keys whose value actually differs from what the style gives.
static func override_keys(kind: String, style_fields: Dictionary, overrides: Dictionary) -> Array:
	var base := resolve(kind, style_fields, {})
	var out: Array = []
	for k in overrides.keys():
		if base.has(k) and not _same(base[k], overrides[k]):
			out.append(k)
	return out


## Drop overrides that equal the style value (an edit back to the style's
## value is not an override any more — the amber dot must go away).
static func prune_overrides(kind: String, style_fields: Dictionary, overrides: Dictionary) -> Dictionary:
	var base := resolve(kind, style_fields, {})
	var out := {}
	for k in overrides.keys():
		if base.has(k) and not _same(base[k], overrides[k]):
			out[k] = overrides[k]
	return out


static func preset_label(kind: String, preset: String) -> String:
	var p: Dictionary = (PRESETS.get(kind, {}) as Dictionary).get(preset, {})
	return str(p.get("label", "Custom"))


## The fields a preset sets (plus `preset` itself). For a kind/preset that does
## not exist: just {"preset": preset}.
static func preset_fields(preset: String, kind: String = "string") -> Dictionary:
	var p: Dictionary = (PRESETS.get(kind, {}) as Dictionary).get(preset, {})
	var out := {"preset": preset}
	var f: Dictionary = p.get("fields", {})
	for k in f.keys():
		out[k] = f[k]
	return out


static func conduit_kind_for(preset: String) -> String:
	var p: Dictionary = (PRESETS["string"] as Dictionary).get(preset, PRESETS["string"]["patio"])
	return str(p.get("conduit", "led_patio"))


## Fields that make two auto-migrated lights "the same look".
static func signature(kind: String, fields: Dictionary) -> String:
	var r := resolve(kind, fields, {})
	var keys := r.keys()
	keys.sort()
	var parts: PackedStringArray = [kind]
	for k in keys:
		parts.append("%s=%s" % [k, str(r[k])])
	return "|".join(parts)


static func _same(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) < 1e-4
	return str(a) == str(b)


## Colour temperature (K) → RGB. Tanner Helland's fit to the CIE 1964 10°
## blackbody table (tannerhelland.com/2012/09/18/convert-temperature-rgb-
## algorithm-code.html), valid 1000–40000 K.
static func kelvin_to_color(k: float) -> Color:
	var t := clampf(k, 1000.0, 40000.0) / 100.0
	var r: float
	var g: float
	var b: float
	if t <= 66.0:
		r = 255.0
		g = 99.4708025861 * log(t) - 161.1195681661
	else:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
	if t >= 66.0:
		b = 255.0
	elif t <= 19.0:
		b = 0.0
	else:
		b = 138.5177312231 * log(t - 10.0) - 305.0447927307
	return Color(clampf(r, 0.0, 255.0) / 255.0, clampf(g, 0.0, 255.0) / 255.0,
		clampf(b, 0.0, 255.0) / 255.0)
