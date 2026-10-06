class_name MicroclimateProfile
extends RefCounted

## A site's microclimate calibration: "when the weather data looks like THIS,
## this site looks like THAT". Weather models are 10–30 km grid cells; a valley
## floor fogs in hours before its cell saturates (Walton OR), and an open playa
## blows harder than the Gerlach station it is sampled from. Nothing here
## replaces the weather data — it is layered on top of it.
##
## Five things, all optional, all sparse:
##
##  * looks{}         named visual sets. Keys (any subset):
##      fog_vis_m      ground-fog visibility (m); INF/absent = no fog
##      fog_depth_m    fog layer thickness above the valley floor
##      fog_color      [r, g, b]
##      haze_vis_m     whole-scene haze visibility (m)
##      haze_color     [r, g, b]
##      cloud_add      −1..1 added to the overhead cloud cover
##      dust           0..1 blowing-dust particles
##      wind_vis_mult  multiplier on vegetation sway / dust drift (visual)
##      light_mult     0..1 sun dimming
##      suppress_auto  true → this look also switches the AUTOMATIC fog off
##                     ("this is what clear looks like here")
##      physics        true → fog/haze also cut PV (as aerosol optical depth)
##  * rules[]         { id, name, look, enabled, strength, when:[cond], hold:[cond], max_hold_h }
##                    A cond is { f: feature, min, max, soft } — 1 inside
##                    [min, max], falling linearly to 0 over `soft` outside it.
##                    `hold` keeps a rule active after its `when` stops matching
##                    for as long as every hold cond still matches (fog that
##                    formed overnight lingers until it burns off).
##  * observations[]  { id, abs_h, features{}, look{}, pin, radius_h, note }
##                    A frozen moment the player calibrated by eye. PINNED ones
##                    are ground truth for that time (cross-faded ±radius_h);
##                    ALL of them feed the nearest-match generalisation.
##  * corrections[]   { id, var, mult, add, when:[cond], physics }
##                    Bias corrections on the INPUT data (playa wind ×1.5,
##                    valley nights 2 °C colder). Visual-only unless `physics`;
##                    a physics correction must be unconditional (it is applied
##                    inside WeatherService, below the feature sampler).
##  * settings{}      auto_fog (bool), auto_fog_scale, cold_pool_bias_c (NAN =
##                    from terrain), fog_depth_m default, nearest (bool),
##                    nearest_cutoff.
##
## Pure data + pure evaluation; the resolver owns sampling and caching.

const VERSION := 1

## Features a rule can test, with the scale used to normalise nearest-match
## distances (one "unit" of difference ≈ a visibly different situation).
const FEATURES := {
	"dep_c":     {"label": "Dew-point gap (°C)",      "scale": 1.5},
	"dep_eff_c": {"label": "Dew-point gap, valley (°C)", "scale": 1.5},
	"rh":        {"label": "Humidity (%)",            "scale": 8.0},
	"t_c":       {"label": "Temperature (°C)",        "scale": 6.0},
	"wind_ms":   {"label": "Wind (m/s)",              "scale": 2.0},
	"gust_ms":   {"label": "Gust (m/s)",              "scale": 3.0},
	"cloud":     {"label": "Cloud cover (0–1)",       "scale": 0.25},
	"low":       {"label": "Low cloud (0–1)",         "scale": 0.25},
	"vis_km":    {"label": "Model visibility (km)",   "scale": 5.0},
	"rain_mmh":  {"label": "Rain (mm/h)",             "scale": 0.5},
	"sun_el":    {"label": "Sun elevation (°)",       "scale": 12.0},
	"hour":      {"label": "Hour of day",             "scale": 3.0},
	"month":     {"label": "Month",                   "scale": 1.5},
	"fog_auto":  {"label": "Auto fog (0–1)",          "scale": 0.3},
}

## Which features nearest-match compares. Hour/month are deliberately out: the
## point is "same conditions", whenever they recur; sun elevation already
## carries day vs night.
const NEAREST_FEATURES := ["dep_eff_c", "rh", "wind_ms", "cloud", "low", "sun_el", "rain_mmh"]

const DEFAULT_SETTINGS := {
	"auto_fog": true,
	"auto_fog_scale": 1.0,
	"cold_pool_bias_c": NAN,
	"fog_depth_m": NAN,
	"nearest": true,
	"nearest_cutoff": 1.6,
}

const LOOK_KEYS := ["fog_vis_m", "fog_depth_m", "fog_color", "haze_vis_m", "haze_color",
	"cloud_add", "dust", "wind_vis_mult", "light_mult", "suppress_auto", "physics"]

var looks: Dictionary = {}
var rules: Array = []
var observations: Array = []
var corrections: Array = []
var settings: Dictionary = DEFAULT_SETTINGS.duplicate()


# ---------------------------------------------------------------------------
# Persistence (SoiConfig / WindowWallViewpoint pattern)
# ---------------------------------------------------------------------------

static func save_path_for_map(lat: float, lon: float) -> String:
	return "user://maps/microclimate_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


static func save_path_for_scene(scene_key: String) -> String:
	var tag := scene_key.get_file().get_basename() if scene_key.contains("/") else scene_key
	if tag.is_empty():
		tag = "unknown_scene"
	return "user://maps/microclimate_scene_%s.json" % tag


static func load_from(path: String) -> MicroclimateProfile:
	var p := MicroclimateProfile.new()
	if not FileAccess.file_exists(path):
		return p
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return p
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		p.deserialize(parsed)
	return p


func save_to(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(serialize(), "\t"))
	f.close()
	return true


func is_empty() -> bool:
	return looks.is_empty() and rules.is_empty() and observations.is_empty() and corrections.is_empty()


## JSON cannot hold INF/NAN, so non-finite floats travel as null.
static func _enc(v: Variant) -> Variant:
	if v is float and not is_finite(v):
		return null
	if v is Color:
		return [v.r, v.g, v.b]
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = _enc(v[k])
		return d
	if v is Array:
		var a := []
		for x in v:
			a.append(_enc(x))
		return a
	return v


func serialize() -> Dictionary:
	return {
		"version": VERSION,
		"settings": _enc(settings),
		"looks": _enc(looks),
		"rules": _enc(rules),
		"observations": _enc(observations),
		"corrections": _enc(corrections),
	}


func deserialize(d: Dictionary) -> void:
	settings = DEFAULT_SETTINGS.duplicate()
	var s: Variant = d.get("settings", {})
	if s is Dictionary:
		for k in s:
			settings[k] = NAN if s[k] == null else s[k]
	looks = {}
	var lk: Variant = d.get("looks", {})
	if lk is Dictionary:
		for id in lk:
			if lk[id] is Dictionary:
				looks[str(id)] = _decode_look(lk[id])
	rules = _arr(d.get("rules", []))
	observations = []
	for o in _arr(d.get("observations", [])):
		o["look"] = _decode_look(o.get("look", {}))
		o["abs_h"] = float(o.get("abs_h", 0.0))
		observations.append(o)
	corrections = _arr(d.get("corrections", []))


static func _arr(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for x in v:
			if x is Dictionary:
				out.append(x)
	return out


static func _decode_look(v: Variant) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for k in v:
		var x: Variant = v[k]
		if k in ["fog_color", "haze_color"]:
			if x is Array and x.size() >= 3:
				out[k] = Color(float(x[0]), float(x[1]), float(x[2]))
			elif x is Color:
				out[k] = x
		elif k in ["suppress_auto", "physics"]:
			out[k] = bool(x)
		elif x == null:
			out[k] = INF if k in ["fog_vis_m", "haze_vis_m"] else NAN
		else:
			out[k] = float(x)
	return out


# ---------------------------------------------------------------------------
# Editing helpers (the drawer calls these)
# ---------------------------------------------------------------------------

static func new_id(prefix: String) -> String:
	return "%s_%d_%d" % [prefix, Time.get_unix_time_from_system(), randi() % 100000]


func set_look(id: String, look: Dictionary) -> void:
	looks[id] = look.duplicate()


## A rule proposed from one moment's features: the conditions bracket what was
## measured with sensible margins, plus a hold that lets fog linger until it
## burns off. The player edits the numbers; this is a starting point, not a fit.
static func suggest_rule(features: Dictionary, look_id: String, name: String = "") -> Dictionary:
	var when: Array = []
	var hold: Array = []
	var dep := float(features.get("dep_eff_c", features.get("dep_c", NAN)))
	if is_finite(dep):
		when.append({"f": "dep_eff_c", "min": NAN, "max": maxf(dep + 0.75, 1.0), "soft": 1.0})
		hold.append({"f": "dep_eff_c", "min": NAN, "max": maxf(dep + 2.0, 3.0), "soft": 0.5})
	var w := float(features.get("wind_ms", NAN))
	if is_finite(w):
		when.append({"f": "wind_ms", "min": NAN, "max": maxf(w + 1.0, 1.5), "soft": 1.5})
	var cl := float(features.get("cloud", NAN))
	var low := float(features.get("low", NAN))
	if is_finite(cl):
		# What was measured ABOVE the low deck — a fog's own low cloud is not
		# "cloudy" for this purpose.
		var above := maxf(cl - (low if is_finite(low) else 0.0), 0.0)
		when.append({"f": "cloud", "min": NAN, "max": clampf(above + 0.25, 0.25, 1.0), "soft": 0.2})
	var el := float(features.get("sun_el", NAN))
	if is_finite(el):
		if el < 0.0:
			when.append({"f": "sun_el", "min": NAN, "max": 2.0, "soft": 4.0})
		else:
			when.append({"f": "sun_el", "min": maxf(el - 15.0, -2.0), "max": NAN, "soft": 4.0})
	return {
		"id": new_id("rule"),
		"name": name if not name.is_empty() else "Rule from %s" % str(features.get("label", "moment")),
		"look": look_id,
		"enabled": true,
		"strength": 1.0,
		"when": when,
		"hold": hold,
		"max_hold_h": 14.0,
	}


# ---------------------------------------------------------------------------
# Evaluation (pure)
# ---------------------------------------------------------------------------

## Membership of one value in one condition: 1 inside [min, max], linear to 0
## over `soft` outside. A missing feature value does not match (0) — a rule
## that tests visibility simply never fires on archive dates.
static func cond_weight(cond: Dictionary, features: Dictionary) -> float:
	var f := str(cond.get("f", ""))
	if not features.has(f):
		return 0.0
	var v := float(features[f])
	if not is_finite(v):
		return 0.0
	var lo := _num(cond.get("min", null))
	var hi := _num(cond.get("max", null))
	var soft := maxf(_num(cond.get("soft", 0.0)), 0.0) if is_finite(_num(cond.get("soft", 0.0))) else 0.0
	var below := (lo - v) if is_finite(lo) and v < lo else 0.0
	var above := (v - hi) if is_finite(hi) and v > hi else 0.0
	var out := maxf(below, above)
	if out <= 0.0:
		return 1.0
	if soft <= 0.0:
		return 0.0
	return clampf(1.0 - out / soft, 0.0, 1.0)


static func _num(v: Variant) -> float:
	if v == null:
		return NAN
	return float(v)


## All conditions, multiplied (AND). An empty list matches everything.
static func conds_weight(conds: Variant, features: Dictionary) -> float:
	if not (conds is Array):
		return 1.0
	var w := 1.0
	for c in conds:
		if c is Dictionary:
			w *= cond_weight(c, features)
			if w <= 0.0:
				return 0.0
	return w


## A rule's weight per hour over a run of hourly feature dicts, with its hold:
## once `when` has reached ≥ 0.5, the rule stays at its peak while every hold
## condition keeps matching, up to max_hold_h.
static func rule_series(rule: Dictionary, rows: Array) -> PackedFloat32Array:
	var n := rows.size()
	var out := PackedFloat32Array()
	out.resize(n)
	if not bool(rule.get("enabled", true)):
		return out
	var strength := clampf(float(rule.get("strength", 1.0)), 0.0, 1.0)
	var hold: Variant = rule.get("hold", [])
	var has_hold := hold is Array and not (hold as Array).is_empty()
	var max_hold := int(float(rule.get("max_hold_h", 14.0)))
	var held := 0.0
	var held_h := 0
	for i in n:
		var w := conds_weight(rule.get("when", []), rows[i])
		if w >= 0.5:
			held = maxf(held if held_h > 0 else 0.0, w)
			held_h = 1
		elif has_hold and held > 0.0 and held_h <= max_hold \
				and conds_weight(hold, rows[i]) >= 0.5:
			w = maxf(w, held)
			held_h += 1
		else:
			held = 0.0
			held_h = 0
		out[i] = w * strength
	return out


## Normalised distance between two feature dicts over NEAREST_FEATURES; a
## feature missing from either side is skipped (and must not make two moments
## look identical — with fewer than 3 shared features the answer is INF).
static func feature_distance(a: Dictionary, b: Dictionary) -> float:
	var sum := 0.0
	var n := 0
	for f in NEAREST_FEATURES:
		var va := float(a.get(f, NAN))
		var vb := float(b.get(f, NAN))
		if not (is_finite(va) and is_finite(vb)):
			continue
		var d := (va - vb) / float(FEATURES[f]["scale"])
		sum += d * d
		n += 1
	if n < 3:
		return INF
	return sqrt(sum / float(n))


## Nearest-match: every observation within `cutoff` contributes, weighted
## (1 − d/cutoff)². Returns [{look, w, id}] — empty means "no match", which is
## the honest answer when nothing calibrated resembles now.
func nearest_contributions(features: Dictionary) -> Array:
	var out: Array = []
	if not bool(settings.get("nearest", true)):
		return out
	var cutoff := float(settings.get("nearest_cutoff", 1.6))
	if not is_finite(cutoff) or cutoff <= 0.0:
		return out
	for o in observations:
		var d := feature_distance(features, o.get("features", {}))
		if d >= cutoff:
			continue
		var w := pow(1.0 - d / cutoff, 2.0)
		out.append({"look": o.get("look", {}), "w": w, "id": str(o.get("id", "")), "kind": "nearest"})
	return out


## Pinned observations covering an instant, cross-faded over radius_h.
func pinned_contributions(abs_h: float) -> Array:
	var out: Array = []
	for o in observations:
		if not bool(o.get("pin", false)):
			continue
		var r := maxf(float(o.get("radius_h", 1.5)), 0.05)
		var d := absf(abs_h - float(o.get("abs_h", 0.0)))
		if d >= r:
			continue
		out.append({"look": o.get("look", {}), "w": 1.0 - smoothstep(r * 0.5, r, d),
			"id": str(o.get("id", "")), "kind": "pinned"})
	return out


## Apply corrections to one feature dict, in list order; returns a new dict.
## `mode` "visual" = only the visual-only ones (the physics ones are already
## inside WeatherService's accessors — applying them again would double them),
## "physics" = only those, "all" = everything.
func apply_corrections(features: Dictionary, mode: String = "all") -> Dictionary:
	var out := features.duplicate()
	for c in corrections:
		if not bool(c.get("enabled", true)):
			continue
		var phys := bool(c.get("physics", false))
		# A conditional physics correction cannot live in WeatherService (see
		# MicroclimateCorrections), so it degrades to visual-only.
		var when: Variant = c.get("when", [])
		if phys and when is Array and not (when as Array).is_empty():
			phys = false
		if (mode == "visual" and phys) or (mode == "physics" and not phys):
			continue
		var w := conds_weight(c.get("when", []), features)
		if w <= 0.0:
			continue
		var key := str(c.get("var", ""))
		if not out.has(key) or not is_finite(float(out[key])):
			continue
		var v := float(out[key])
		var mult := float(c.get("mult", 1.0))
		var add := float(c.get("add", 0.0))
		out[key] = lerpf(v, v * mult + add, w)
	# Derived features follow their inputs.
	if out.has("t_c") and out.has("td_c"):
		var t := float(out["t_c"])
		var td := float(out["td_c"])
		if is_finite(t) and is_finite(td):
			td = minf(td, t)
			out["td_c"] = td
			out["dep_c"] = t - td
	return out


## Blend a list of {look, w} into one resolved visual state. Fog/haze combine
## in EXTINCTION space, worst wins (a second foggy rule cannot make it clearer);
## everything else is a weighted mean or sum.
static func blend(contribs: Array) -> Dictionary:
	var fog_sigma := 0.0
	var haze_sigma := 0.0
	var depth_sum := 0.0
	var depth_w := 0.0
	var fog_col := Color(0, 0, 0)
	var fog_col_w := 0.0
	var haze_col := Color(0, 0, 0)
	var haze_col_w := 0.0
	var cloud_add := 0.0
	var dust := 0.0
	var wind_mult := 1.0
	var light := 1.0
	var suppress := 0.0
	var physics := false
	for c in contribs:
		var look: Dictionary = c.get("look", {})
		var w := clampf(float(c.get("w", 0.0)), 0.0, 1.0)
		if w <= 0.0:
			continue
		if look.has("fog_vis_m"):
			fog_sigma = maxf(fog_sigma, w * FogOptics.sigma_for_visibility(float(look["fog_vis_m"])))
		if look.has("haze_vis_m"):
			haze_sigma = maxf(haze_sigma, w * FogOptics.sigma_for_visibility(float(look["haze_vis_m"])))
		if look.has("fog_depth_m") and is_finite(float(look["fog_depth_m"])):
			depth_sum += w * float(look["fog_depth_m"])
			depth_w += w
		if look.has("fog_color"):
			fog_col += (look["fog_color"] as Color) * w
			fog_col_w += w
		if look.has("haze_color"):
			haze_col += (look["haze_color"] as Color) * w
			haze_col_w += w
		cloud_add += w * float(look.get("cloud_add", 0.0))
		dust = maxf(dust, w * float(look.get("dust", 0.0)))
		wind_mult += w * (float(look.get("wind_vis_mult", 1.0)) - 1.0)
		light *= lerpf(1.0, clampf(float(look.get("light_mult", 1.0)), 0.0, 1.0), w)
		if bool(look.get("suppress_auto", false)):
			suppress = maxf(suppress, w)
		physics = physics or (bool(look.get("physics", false)) and w > 0.05)
	return {
		"fog_sigma": fog_sigma,
		"haze_sigma": haze_sigma,
		"fog_depth_m": depth_sum / depth_w if depth_w > 0.0 else NAN,
		"fog_color": fog_col / fog_col_w if fog_col_w > 0.0 else Color(0, 0, 0, 0),
		"haze_color": haze_col / haze_col_w if haze_col_w > 0.0 else Color(0, 0, 0, 0),
		"cloud_add": clampf(cloud_add, -1.0, 1.0),
		"dust": clampf(dust, 0.0, 1.0),
		"wind_vis_mult": maxf(wind_mult, 0.0),
		"light_mult": clampf(light, 0.0, 1.0),
		"suppress_auto": clampf(suppress, 0.0, 1.0),
		"physics": physics,
	}
