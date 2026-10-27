class_name ToroidLabSpec
extends RefCounted

## The toroid designer's spec: what the player chose, resolved over defaults
## so every consumer reads a complete dictionary. Pure.
##
## The frame is a TORUS: every rib is the same circle (the minor circle,
## radius r, centred major_r out from the axis and centre_h above the
## ground) swept round the axis, cut off where it meets the ground. Rings run
## round the axis at chosen angles on that circle. An angle φ on the minor
## circle is measured from its outer equator, up over the top: 0° = the
## widest point, 90° = the crown, 180° = the inner equator (the throat).
##
## {
##   version, name,
##   torus:   {major_r_m, minor_r_m, centre_h_m: the minor circle's centre
##             above the ground, base_y_m: the ground rings' centreline above
##             the ground (feet), segments: ribs round the ring,
##             inner_top_deg: where the top arc ends on the inner ring (-1 =
##             symmetric with the ground cut, so the three arcs are equal),
##             rotation_deg: rib 0's bearing}
##   tube:    {material: ToroidLabMaterials.TUBES id}
##   ribs:    {pieces: arcs between the outer ground ring and the inner top
##             ring (2 = an outer wall arc and a top arc, joined by a coupler),
##             inner_every: every Nth rib continues down the inner wall (0 =
##             none), inner_offset, inner_skip: [rib indices left open — a
##             doorway into the throat], inner_posts: a straight post beside
##             each inner arc, feet: a base foot under every ground end}
##   rings:   {ground_out, ground_in, inner_top, crown: bool, crown_deg: the
##             crown ring's angle, extra_deg: [more rings], piece_bays: how
##             many bays one bent ring tube spans}
##   bracing: [{from, to: ring indices in the ring list (outer ground = 0,
##             round over the top), pattern: "x" | "diag" | "zigzag",
##             member: "tube" | "cable", cable: CABLES id, every, start}]
##   canopy:  {enabled, fold: "diamond" (each bay a valley–peak–valley
##             pleat) | "plain", phi_out_deg / phi_in_deg: the canopy's outer
##             and inner edges, phi_peak_deg, seam_out_mm / seam_in_mm: how far
##             inside the ribs the edges' corners hang, peak_mm, valley_out_mm /
##             valley_in_mm: the pleat's depth at its ends, sheet: SHEETS id,
##             flange_mm, bolts_per_seam, bolt: DomeLabMaterials.BOLTS id,
##             every: a canopy sector every Nth bay}
##   solar:   {enabled, model: PANELS id, per_bay (0..2), every, centre_deg:
##             the panels' centre angle on the minor circle, standoff_mm:
##             panel above the rib centreline, series, parallel (0 = auto)}
##   fabrication: {units: "mm" | "in", kerf_mm, fitting_gap_mm: how far short
##             of the node a tube is cut (0 = butt to the fitting centre)}
##   colors:  {tube, connector, canopy, panel, cable}
## }

const VERSION := 1

const FOLDS := ["diamond", "plain"]
const FOLD_LABELS := {"diamond": "Diamond pleat (valley · peak · valley)", "plain": "Plain (no pleat)"}
const PATTERNS := ["x", "diag", "zigzag"]
const PATTERN_LABELS := {"x": "X (both diagonals)", "diag": "Single diagonal", "zigzag": "Zigzag"}
const MEMBERS := ["tube", "cable"]
const MEMBER_LABELS := {"tube": "Tube brace", "cable": "Tension line"}
const UNITS := ["mm", "in"]

const TORUS_DEFAULTS := {"major_r_m": 2.205, "minor_r_m": 1.825, "centre_h_m": 1.352, "base_y_m": 0.04,
	"segments": 24, "inner_top_deg": -1.0, "rotation_deg": 0.0}
const TUBE_DEFAULTS := {"material": "steel_1_065"}
const RIB_DEFAULTS := {"pieces": 2, "inner_every": 2, "inner_offset": 1, "inner_skip": [],
	"inner_posts": true, "feet": false}
const RING_DEFAULTS := {"ground_out": true, "ground_in": true, "inner_top": true, "crown": true,
	"crown_deg": 77.0, "extra_deg": [], "piece_bays": 3}
const BRACE_DEFAULTS := {"from": 0, "to": 1, "pattern": "x", "member": "cable", "cable": "cable_18",
	"every": 1, "start": 0}
const CANOPY_DEFAULTS := {"enabled": true, "fold": "diamond", "phi_out_deg": 32.4, "phi_in_deg": 119.2,
	"phi_peak_deg": 74.7, "seam_out_mm": 19.0, "seam_in_mm": 74.0, "peak_mm": 64.0, "valley_out_mm": 367.0,
	"valley_in_mm": 620.0, "sheet": "correx_10", "flange_mm": 50.8, "bolts_per_seam": 3, "bolt": "m6",
	"every": 1}
const SOLAR_DEFAULTS := {"enabled": true, "model": "flex_100", "per_bay": 1, "every": 1, "centre_deg": 84.0,
	"standoff_mm": 6.0, "series": 6, "parallel": 4}
const FAB_DEFAULTS := {"units": "in", "kerf_mm": 3.0, "fitting_gap_mm": 0.0}
const COLOR_DEFAULTS := {"tube": Color(0.45, 0.25, 0.15), "connector": Color(0.78, 0.80, 0.83),
	"canopy": Color(0.93, 0.94, 0.95), "panel": Color(0.13, 0.15, 0.22), "cable": Color(0.55, 0.57, 0.6)}

const MIN_SEGMENTS := 6
const MAX_SEGMENTS := 96


static func default_spec() -> Dictionary:
	return resolve({"name": "Toroid"})


static func resolve(spec: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	s["version"] = VERSION
	s["name"] = str(s.get("name", "Toroid")).strip_edges()
	if str(s["name"]).is_empty():
		s["name"] = "Toroid"
	var t := _merge(TORUS_DEFAULTS, s.get("torus", {}))
	t["segments"] = clampi(int(t["segments"]), MIN_SEGMENTS, MAX_SEGMENTS)
	t["minor_r_m"] = clampf(float(t["minor_r_m"]), 0.3, 20.0)
	t["major_r_m"] = clampf(float(t["major_r_m"]), 0.1, 60.0)
	t["base_y_m"] = clampf(float(t["base_y_m"]), 0.0, 2.0)
	# The ground has to cut the minor circle: its centre sits below the top
	# of the circle and above (base − r).
	var r := float(t["minor_r_m"])
	t["centre_h_m"] = clampf(float(t["centre_h_m"]), float(t["base_y_m"]) - r * 0.95, float(t["base_y_m"]) + r * 0.95)
	t["inner_top_deg"] = float(t["inner_top_deg"])
	t["rotation_deg"] = float(t["rotation_deg"])
	s["torus"] = t
	s["tube"] = _merge(TUBE_DEFAULTS, s.get("tube", {}))
	if not ToroidLabMaterials.TUBES.has(str(s["tube"]["material"])):
		s["tube"]["material"] = "steel_1_065"
	var rb := _merge(RIB_DEFAULTS, s.get("ribs", {}))
	rb["pieces"] = clampi(int(rb["pieces"]), 1, 6)
	rb["inner_every"] = clampi(int(rb["inner_every"]), 0, 12)
	rb["inner_offset"] = int(rb["inner_offset"])
	rb["inner_skip"] = _int_list(rb["inner_skip"])
	rb["inner_posts"] = bool(rb["inner_posts"])
	rb["feet"] = bool(rb["feet"])
	s["ribs"] = rb
	var rg := _merge(RING_DEFAULTS, s.get("rings", {}))
	for k in ["ground_out", "ground_in", "inner_top", "crown"]:
		rg[k] = bool(rg[k])
	rg["crown_deg"] = float(rg["crown_deg"])
	rg["extra_deg"] = _float_list(rg["extra_deg"])
	rg["piece_bays"] = clampi(int(rg["piece_bays"]), 1, 48)
	s["rings"] = rg
	var braces: Array = []
	for b in (s.get("bracing", []) as Array):
		if b is Dictionary:
			var bb := _merge(BRACE_DEFAULTS, b)
			bb["from"] = int(bb["from"])
			bb["to"] = int(bb["to"])
			if not PATTERNS.has(str(bb["pattern"])):
				bb["pattern"] = "x"
			if not MEMBERS.has(str(bb["member"])):
				bb["member"] = "cable"
			if not ToroidLabMaterials.CABLES.has(str(bb["cable"])):
				bb["cable"] = "cable_18"
			bb["every"] = clampi(int(bb["every"]), 1, 48)
			bb["start"] = int(bb["start"])
			braces.append(bb)
	s["bracing"] = braces
	var cn := _merge(CANOPY_DEFAULTS, s.get("canopy", {}))
	cn["enabled"] = bool(cn["enabled"])
	if not FOLDS.has(str(cn["fold"])):
		cn["fold"] = "diamond"
	if not ToroidLabMaterials.SHEETS.has(str(cn["sheet"])):
		cn["sheet"] = "correx_10"
	if not DomeLabMaterials.BOLTS.has(str(cn["bolt"])):
		cn["bolt"] = "m6"
	for k in ["phi_out_deg", "phi_in_deg", "phi_peak_deg", "seam_out_mm", "seam_in_mm", "peak_mm",
			"valley_out_mm", "valley_in_mm", "flange_mm"]:
		cn[k] = float(cn[k])
	cn["phi_out_deg"] = clampf(float(cn["phi_out_deg"]), -60.0, 170.0)
	cn["phi_in_deg"] = clampf(float(cn["phi_in_deg"]), float(cn["phi_out_deg"]) + 10.0, 200.0)
	cn["phi_peak_deg"] = clampf(float(cn["phi_peak_deg"]), float(cn["phi_out_deg"]) + 2.0, float(cn["phi_in_deg"]) - 2.0)
	cn["flange_mm"] = clampf(float(cn["flange_mm"]), 0.0, 150.0)
	cn["bolts_per_seam"] = clampi(int(cn["bolts_per_seam"]), 0, 12)
	cn["every"] = clampi(int(cn["every"]), 1, 12)
	s["canopy"] = cn
	var so := _merge(SOLAR_DEFAULTS, s.get("solar", {}))
	so["enabled"] = bool(so["enabled"])
	if not ToroidLabMaterials.PANELS.has(str(so["model"])):
		so["model"] = "flex_100"
	so["per_bay"] = clampi(int(so["per_bay"]), 0, 3)
	so["every"] = clampi(int(so["every"]), 1, 12)
	so["centre_deg"] = float(so["centre_deg"])
	so["standoff_mm"] = float(so["standoff_mm"])
	so["series"] = clampi(int(so["series"]), 0, 96)
	so["parallel"] = clampi(int(so["parallel"]), 0, 96)
	s["solar"] = so
	var fab := _merge(FAB_DEFAULTS, s.get("fabrication", {}))
	if not UNITS.has(str(fab["units"])):
		fab["units"] = "in"
	fab["kerf_mm"] = float(fab["kerf_mm"])
	fab["fitting_gap_mm"] = float(fab["fitting_gap_mm"])
	s["fabrication"] = fab
	var cols := _merge(COLOR_DEFAULTS, s.get("colors", {}))
	for k in cols.keys():
		cols[k] = _to_color(cols[k], COLOR_DEFAULTS.get(k, Color.WHITE))
	s["colors"] = cols
	return s


static func _merge(defaults: Dictionary, over: Variant) -> Dictionary:
	var out := defaults.duplicate(true)
	if over is Dictionary:
		for k in (over as Dictionary):
			out[k] = (over as Dictionary)[k]
	return out


static func _to_color(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	if v is String and Color.html_is_valid(str(v)):
		return Color.html(str(v))
	return fallback


static func _int_list(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for x in v:
			out.append(int(x))
	elif v is String:
		for p in str(v).replace(";", ",").split(",", false):
			if p.strip_edges().is_valid_int():
				out.append(int(p.strip_edges()))
	return out


static func _float_list(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for x in v:
			out.append(float(x))
	elif v is String:
		for p in str(v).replace(";", ",").split(",", false):
			if p.strip_edges().is_valid_float():
				out.append(float(p.strip_edges()))
	return out


## The spec with every Color as [r, g, b, a], so it survives JSON.
static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var cols := {}
	for k in s["colors"]:
		var c: Color = s["colors"][k]
		cols[k] = [c.r, c.g, c.b, c.a]
	s["colors"] = cols
	return s


## The cache key (everything that changes geometry, parts or looks).
static func key_of(spec: Dictionary) -> String:
	var s := to_json_safe(spec)
	return str(hash(var_to_str(s)))


# ---------------------------------------------------------------------------
# The torus from the numbers a builder measures
# ---------------------------------------------------------------------------

## The ground cut's half-angle below the minor circle's equator: the outer
## ground ring sits at φ = −g, the inner one at 180° + g.
static func ground_deg(t: Dictionary) -> float:
	var r := float(t["minor_r_m"])
	var dy := clampf((float(t["centre_h_m"]) - float(t["base_y_m"])) / r, -1.0, 1.0)
	return rad_to_deg(asin(dy))


## {inner_r_m (where the inner wall meets the ground), outer_r_m (the widest
## point), height_m (the top of the tube centreline), throat_r_m (the inner
## wall's tightest point)}.
static func measures(t: Dictionary) -> Dictionary:
	var R := float(t["major_r_m"])
	var r := float(t["minor_r_m"])
	var hc := float(t["centre_h_m"])
	var g := deg_to_rad(ground_deg(t))
	var below := float(t["base_y_m"]) < hc - r
	return {"inner_r_m": R - r * cos(g), "outer_r_m": R + r if not below else R + r * cos(g),
		"base_out_r_m": R + r * cos(g), "height_m": hc + r, "throat_r_m": R - r}


## The torus that has these measures: inner radius at the ground, outer
## radius, height (centreline), ground ring height. Solving
##   R + r = outer,  hc + r = height,  R − √(r² − (hc − base)²) = inner
## for r: r² − 2(H + A)r + (A² + H²) = 0 with A = outer − inner, H = height
## − base, the smaller root. Returns the torus dict (or {} when no torus fits).
static func torus_from_measures(inner_r: float, outer_r: float, height: float, base_y: float,
		segments: int = 24) -> Dictionary:
	var A := outer_r - inner_r
	var H := height - base_y
	if A <= 0.05 or H <= 0.05:
		return {}
	var disc := (H + A) * (H + A) - (A * A + H * H)
	if disc < 0.0:
		return {}
	var r := (H + A) - sqrt(disc)
	if r <= 0.0:
		return {}
	return {"major_r_m": outer_r - r, "minor_r_m": r, "centre_h_m": height - r, "base_y_m": base_y,
		"segments": segments}


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

static func fmt_len(mm: float, units: String = "in", decimals: int = 1) -> String:
	return DomeLabSpec.fmt_len(mm, units, decimals)


static func fmt_m(m: float) -> String:
	return DomeLabSpec.fmt_m(m)


static func fmt_deg(d: float) -> String:
	return DomeLabSpec.fmt_deg(d)


static func fmt_kg(kg: float) -> String:
	return DomeLabSpec.fmt_kg(kg)


static func fmt_area(m2: float) -> String:
	return DomeLabSpec.fmt_area(m2)


## A spec's one-line description.
static func describe(spec: Dictionary) -> String:
	var s := resolve(spec)
	var t: Dictionary = s["torus"]
	var m := measures(t)
	var tube := ToroidLabMaterials.tube(str(s["tube"]["material"]))
	return "%d-rib toroid Ø%s · %s" % [int(t["segments"]), fmt_m(float(m["outer_r_m"]) * 2.0),
		str(tube["label"])]
