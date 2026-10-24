class_name FlatpackSpec
extends RefCounted

## The flat-pack furniture spec: one flat dictionary per design, the pattern
## PalletRackBuilder.default_spec / resolve_spec use. `resolve` keeps known
## keys only, clamps every number and fills defaults, so a spec saved by an
## older build (or typed by hand) always builds.
##
## Units: inches (the sheets, the bit and the sample design are imperial). A
## mm export is a unit switch at write time, nothing more.
##
## Types and the template that builds each:
##   sofa          — the sample: egg-crate rail frame, arms, a deck and a back
##                   that sets up upright, reclined or flat as a daybed;
##   bench, stool, table, coffee_table — the "table" family: a top on leg
##                   panels, a wedged stretcher or crossed (X) legs;
##   chair, lounger — side profiles carrying a seat and a back on tabs.

const VERSION := 1

const TYPES := ["sofa", "bench", "stool", "table", "coffee_table", "chair", "lounger"]
const TYPE_LABELS := {
	"sofa": "Sofa / daybed", "bench": "Bench", "stool": "Stool", "table": "Table",
	"coffee_table": "Coffee table", "chair": "Chair", "lounger": "Lounger",
}

## Sheet stock (inches). "5x5" is Baltic birch (1525 mm square).
const SHEETS := {
	"4x8": Vector2(48.0, 96.0), "4x4": Vector2(48.0, 48.0), "5x5": Vector2(60.0, 60.0),
	"2x4": Vector2(24.0, 48.0),
}
const SHEET_LABELS := {"4x8": "4×8 ft", "4x4": "4×4 ft (half)", "5x5": "5×5 ft (Baltic birch)",
	"2x4": "2×4 ft (handy panel)", "custom": "Custom"}

## Nominal → actual thickness. North American sheathing / cabinet plywood is
## sold by nominal size and runs a 1/32" under it (APA PS 1 / PS 2 panels:
## 15/32" sold as 1/2", 23/32" as 3/4"); Baltic birch is metric and true.
const THICKNESS := {
	"1/4": 0.21875, "3/8": 0.34375, "1/2": 0.46875, "5/8": 0.59375, "3/4": 0.71875,
	"12mm": 0.47244, "18mm": 0.70866,
}
const THICKNESS_LABELS := {
	"1/4": "1/4\" (7/32 actual)", "3/8": "3/8\" (11/32 actual)", "1/2": "1/2\" (15/32 actual)",
	"5/8": "5/8\" (19/32 actual)", "3/4": "3/4\" (23/32 actual)", "12mm": "12 mm Baltic birch",
	"18mm": "18 mm Baltic birch", "custom": "Measured (custom)",
}

## Plywood mass per square foot per inch of thickness. A 4×8 sheet of 1/2"
## softwood sheathing plywood weighs about 48 lb (1.5 lb/ft²), i.e. ~3.0
## lb/ft² per inch (≈ 577 kg/m³) — APA Engineered Wood Construction Guide,
## panel weights table. Baltic birch is denser (~680 kg/m³).
const LB_PER_FT2_PER_IN := 3.0
const LB_TO_KG := 0.45359237

const RELIEF_LABELS := {"dogbone": "Dogbones", "tbone": "T-bones", "none": "None (sharp)"}
const POSE_LABELS := {"": "Assembled", "upright": "Sofa (upright)", "recline": "Sofa (reclined)",
	"daybed": "Daybed (flat)"}

## Per-type parameters: {key, label, unit (in | deg | count | bool | choice),
## min, max, step, default, options?, tip?}. The modal draws these rows; the
## selftest checks every template reads exactly these keys.
const PARAMS := {
	"sofa": [
		{"key": "length", "label": "Length", "unit": "in", "min": 48.0, "max": 120.0, "step": 0.5, "default": 96.0},
		{"key": "depth", "label": "Frame depth", "unit": "in", "min": 30.0, "max": 60.0, "step": 0.5, "default": 48.0},
		{"key": "frame_h", "label": "Frame height", "unit": "in", "min": 8.0, "max": 18.0, "step": 0.25, "default": 11.5,
			"tip": "Height of the rails: the deck sits on top of them."},
		{"key": "deck_depth", "label": "Deck depth", "unit": "in", "min": 24.0, "max": 48.0, "step": 0.25, "default": 35.5},
		{"key": "deck_overhang", "label": "Deck overhang", "unit": "in", "min": 0.0, "max": 12.0, "step": 0.5, "default": 6.0,
			"tip": "How far the deck runs past the front of the frame."},
		{"key": "arm_h", "label": "Arm height", "unit": "in", "min": 14.0, "max": 36.0, "step": 0.25, "default": 23.75},
		{"key": "arm_inset", "label": "Arm inset", "unit": "in", "min": 2.0, "max": 12.0, "step": 0.25, "default": 6.0,
			"tip": "From the end of the rails to the arm."},
		{"key": "rails", "label": "Long rails", "unit": "count", "min": 2, "max": 5, "step": 1, "default": 3},
		{"key": "cross_rails", "label": "Cross rails", "unit": "count", "min": 1, "max": 6, "step": 1, "default": 3},
		{"key": "back_h", "label": "Back height", "unit": "in", "min": 12.0, "max": 36.0, "step": 0.5, "default": 24.0},
		{"key": "upright_deg", "label": "Upright back", "unit": "deg", "min": 5.0, "max": 30.0, "step": 1.0, "default": 15.0,
			"tip": "Back angle from vertical when sitting up."},
		{"key": "recline_deg", "label": "Reclined back", "unit": "deg", "min": 15.0, "max": 50.0, "step": 1.0, "default": 32.0},
		{"key": "daybed", "label": "Also folds flat (daybed)", "unit": "bool", "default": true},
		{"key": "deck_share", "label": "Arm slot share", "unit": "pct", "min": 0.2, "max": 0.8, "step": 0.05, "default": 0.4,
			"tip": "How much of the deck/arm overlap the arm's slot takes."},
		{"key": "brace_len", "label": "Back brace length", "unit": "in", "min": 12.0, "max": 30.0, "step": 0.25, "default": 23.75},
		{"key": "brace_w", "label": "Back brace width", "unit": "in", "min": 6.0, "max": 16.0, "step": 0.25, "default": 11.5},
	],
	"bench": [
		{"key": "length", "label": "Length", "unit": "in", "min": 24.0, "max": 96.0, "step": 0.5, "default": 48.0},
		{"key": "height", "label": "Seat height", "unit": "in", "min": 12.0, "max": 24.0, "step": 0.25, "default": 17.5},
		{"key": "width", "label": "Seat depth", "unit": "in", "min": 9.0, "max": 24.0, "step": 0.5, "default": 14.0},
		{"key": "leg_inset", "label": "Leg inset", "unit": "in", "min": 2.0, "max": 16.0, "step": 0.25, "default": 6.0},
		{"key": "legs", "label": "Legs", "unit": "count", "min": 2, "max": 4, "step": 1, "default": 2},
		{"key": "stretcher_h", "label": "Stretcher height", "unit": "in", "min": 3.0, "max": 8.0, "step": 0.25, "default": 4.5},
		{"key": "stretcher_y", "label": "Stretcher off floor", "unit": "in", "min": 2.0, "max": 10.0, "step": 0.25, "default": 4.0},
		{"key": "tab_w", "label": "Tab width", "unit": "in", "min": 1.5, "max": 5.0, "step": 0.25, "default": 2.5},
		{"key": "back", "label": "Back rest", "unit": "bool", "default": false},
		{"key": "back_h", "label": "Back rest height", "unit": "in", "min": 8.0, "max": 20.0, "step": 0.5, "default": 14.0},
	],
	"stool": [
		{"key": "height", "label": "Height", "unit": "in", "min": 12.0, "max": 32.0, "step": 0.25, "default": 18.0},
		{"key": "top", "label": "Top size", "unit": "in", "min": 10.0, "max": 24.0, "step": 0.5, "default": 14.0},
		{"key": "round", "label": "Round top", "unit": "bool", "default": true},
		{"key": "leg_inset", "label": "Leg inset", "unit": "in", "min": 0.5, "max": 4.0, "step": 0.25, "default": 1.5},
		{"key": "tab_w", "label": "Tab width", "unit": "in", "min": 1.0, "max": 4.0, "step": 0.25, "default": 2.0},
	],
	"table": [
		{"key": "length", "label": "Length", "unit": "in", "min": 24.0, "max": 96.0, "step": 0.5, "default": 60.0},
		{"key": "width", "label": "Width", "unit": "in", "min": 18.0, "max": 44.0, "step": 0.5, "default": 30.0},
		{"key": "height", "label": "Height", "unit": "in", "min": 16.0, "max": 42.0, "step": 0.25, "default": 29.5},
		{"key": "x_legs", "label": "Crossed (X) legs", "unit": "bool", "default": false},
		{"key": "leg_inset", "label": "Leg inset", "unit": "in", "min": 2.0, "max": 16.0, "step": 0.25, "default": 7.0},
		{"key": "stretcher_h", "label": "Stretcher height", "unit": "in", "min": 3.0, "max": 8.0, "step": 0.25, "default": 5.0},
		{"key": "stretcher_y", "label": "Stretcher off floor", "unit": "in", "min": 2.0, "max": 14.0, "step": 0.25, "default": 7.0},
		{"key": "tab_w", "label": "Tab width", "unit": "in", "min": 1.5, "max": 5.0, "step": 0.25, "default": 3.0},
	],
	"coffee_table": [
		{"key": "length", "label": "Length", "unit": "in", "min": 18.0, "max": 72.0, "step": 0.5, "default": 40.0},
		{"key": "width", "label": "Width", "unit": "in", "min": 14.0, "max": 36.0, "step": 0.5, "default": 22.0},
		{"key": "height", "label": "Height", "unit": "in", "min": 10.0, "max": 22.0, "step": 0.25, "default": 16.0},
		{"key": "x_legs", "label": "Crossed (X) legs", "unit": "bool", "default": true},
		{"key": "leg_inset", "label": "Leg inset", "unit": "in", "min": 1.0, "max": 12.0, "step": 0.25, "default": 4.0},
		{"key": "stretcher_h", "label": "Stretcher height", "unit": "in", "min": 2.5, "max": 6.0, "step": 0.25, "default": 3.5},
		{"key": "stretcher_y", "label": "Stretcher off floor", "unit": "in", "min": 2.0, "max": 8.0, "step": 0.25, "default": 3.0},
		{"key": "tab_w", "label": "Tab width", "unit": "in", "min": 1.5, "max": 5.0, "step": 0.25, "default": 2.5},
	],
	"chair": [
		{"key": "seat_h", "label": "Seat height", "unit": "in", "min": 8.0, "max": 24.0, "step": 0.25, "default": 17.0},
		{"key": "seat_depth", "label": "Seat depth", "unit": "in", "min": 12.0, "max": 30.0, "step": 0.5, "default": 17.0},
		{"key": "width", "label": "Seat width", "unit": "in", "min": 14.0, "max": 30.0, "step": 0.5, "default": 18.0},
		{"key": "seat_tilt", "label": "Seat tilt", "unit": "deg", "min": 0.0, "max": 15.0, "step": 0.5, "default": 5.0},
		{"key": "back_deg", "label": "Back angle", "unit": "deg", "min": 0.0, "max": 50.0, "step": 1.0, "default": 14.0,
			"tip": "From vertical."},
		{"key": "back_h", "label": "Back length", "unit": "in", "min": 8.0, "max": 30.0, "step": 0.5, "default": 16.0},
		{"key": "rise", "label": "Side above seat", "unit": "in", "min": 1.5, "max": 8.0, "step": 0.25, "default": 2.5,
			"tip": "How far the side profiles stand above the seat and back."},
		{"key": "tab_w", "label": "Tab width", "unit": "in", "min": 1.5, "max": 5.0, "step": 0.25, "default": 3.0},
	],
	"lounger": [
		{"key": "seat_h", "label": "Seat height", "unit": "in", "min": 6.0, "max": 18.0, "step": 0.25, "default": 11.0},
		{"key": "seat_depth", "label": "Seat depth", "unit": "in", "min": 14.0, "max": 34.0, "step": 0.5, "default": 22.0},
		{"key": "width", "label": "Seat width", "unit": "in", "min": 16.0, "max": 34.0, "step": 0.5, "default": 22.0},
		{"key": "seat_tilt", "label": "Seat tilt", "unit": "deg", "min": 0.0, "max": 20.0, "step": 0.5, "default": 10.0},
		{"key": "back_deg", "label": "Back angle", "unit": "deg", "min": 10.0, "max": 60.0, "step": 1.0, "default": 36.0,
			"tip": "From vertical."},
		{"key": "back_h", "label": "Back length", "unit": "in", "min": 12.0, "max": 34.0, "step": 0.5, "default": 24.0},
		{"key": "rise", "label": "Side above seat", "unit": "in", "min": 1.5, "max": 8.0, "step": 0.25, "default": 2.5},
		{"key": "tab_w", "label": "Tab width", "unit": "in", "min": 1.5, "max": 5.0, "step": 0.25, "default": 3.0},
	],
}

const MATERIAL_DEFAULTS := {"sheet": "4x8", "sheet_w": 48.0, "sheet_h": 96.0,
	"nominal": "1/2", "thickness": 0.46875, "grain_lock": false}
## spacing: kept between parts (the bit plus a little); margin: kept clear
## round the sheet's edge. 0 cuts parts right to the factory edge, which is
## what lets a 96" rail come out of a 96" sheet.
const MACHINE_DEFAULTS := {"bit_d": 0.25, "clearance": 0.01, "spacing": 0.375, "margin": 0.0,
	"relief": "dogbone", "pass_depth": 0.25, "feed_ipm": 150.0, "units": "in", "labels": true}
const STYLE_DEFAULTS := {"corner_r": 1.5, "foot_arch": true}
const JOINERY_DEFAULTS := {"wedges": true, "overrides": {}}


static func default_spec(type: String = "sofa") -> Dictionary:
	var t := type if TYPES.has(type) else "sofa"
	var params := {}
	for row in PARAMS[t]:
		params[str(row["key"])] = row["default"]
	return {
		"version": VERSION, "type": t, "name": str(TYPE_LABELS.get(t, t)),
		"params": params,
		"material": MATERIAL_DEFAULTS.duplicate(true),
		"machine": MACHINE_DEFAULTS.duplicate(true),
		"style": STYLE_DEFAULTS.duplicate(true),
		"joinery": JOINERY_DEFAULTS.duplicate(true),
		"pose": "",
		"profile_offsets": {},
		"part_overrides": {},
	}


static func param_rows(type: String) -> Array:
	return PARAMS.get(type, [])


static func param_row(type: String, key: String) -> Dictionary:
	for row in param_rows(type):
		if str(row["key"]) == key:
			return row
	return {}


## Known keys only, clamped, defaults filled.
static func resolve(spec: Dictionary) -> Dictionary:
	var t := str(spec.get("type", "sofa"))
	if not TYPES.has(t):
		t = "sofa"
	var s := default_spec(t)
	s["name"] = str(spec.get("name", s["name"])).strip_edges()
	if str(s["name"]).is_empty():
		s["name"] = str(TYPE_LABELS[t])
	var p_in: Dictionary = spec.get("params", {}) if spec.get("params") is Dictionary else {}
	for row in PARAMS[t]:
		var k := str(row["key"])
		if not p_in.has(k):
			continue
		var v: Variant = p_in[k]
		match str(row["unit"]):
			"bool":
				s["params"][k] = bool(v)
			"count":
				s["params"][k] = clampi(int(v), int(row["min"]), int(row["max"]))
			_:
				s["params"][k] = clampf(float(v), float(row["min"]), float(row["max"]))
	var m_in: Dictionary = spec.get("material", {}) if spec.get("material") is Dictionary else {}
	var m: Dictionary = s["material"]
	var sheet := str(m_in.get("sheet", m["sheet"]))
	m["sheet"] = sheet if SHEETS.has(sheet) or sheet == "custom" else "4x8"
	if SHEETS.has(m["sheet"]):
		var sz: Vector2 = SHEETS[m["sheet"]]
		m["sheet_w"] = sz.x
		m["sheet_h"] = sz.y
	else:
		m["sheet_w"] = clampf(float(m_in.get("sheet_w", 48.0)), 12.0, 120.0)
		m["sheet_h"] = clampf(float(m_in.get("sheet_h", 96.0)), 12.0, 144.0)
	var nom := str(m_in.get("nominal", m["nominal"]))
	m["nominal"] = nom if THICKNESS.has(nom) or nom == "custom" else "1/2"
	if THICKNESS.has(m["nominal"]):
		m["thickness"] = float(THICKNESS[m["nominal"]])
	else:
		m["thickness"] = clampf(float(m_in.get("thickness", 0.46875)), 0.1, 1.5)
	m["grain_lock"] = bool(m_in.get("grain_lock", false))

	var mc_in: Dictionary = spec.get("machine", {}) if spec.get("machine") is Dictionary else {}
	var mc: Dictionary = s["machine"]
	mc["bit_d"] = clampf(float(mc_in.get("bit_d", mc["bit_d"])), 0.0, 1.0)
	mc["clearance"] = clampf(float(mc_in.get("clearance", mc["clearance"])), 0.0, 0.1)
	mc["spacing"] = clampf(float(mc_in.get("spacing", mc["spacing"])), 0.0, 3.0)
	mc["margin"] = clampf(float(mc_in.get("margin", mc["margin"])), 0.0, 4.0)
	var rel := str(mc_in.get("relief", mc["relief"]))
	mc["relief"] = rel if FlatpackProfile.RELIEF_STYLES.has(rel) else "dogbone"
	mc["pass_depth"] = clampf(float(mc_in.get("pass_depth", mc["pass_depth"])), 0.02, 1.5)
	mc["feed_ipm"] = clampf(float(mc_in.get("feed_ipm", mc["feed_ipm"])), 10.0, 1500.0)
	var units := str(mc_in.get("units", mc["units"]))
	mc["units"] = units if units == "mm" or units == "in" else "in"
	mc["labels"] = bool(mc_in.get("labels", true))

	var st_in: Dictionary = spec.get("style", {}) if spec.get("style") is Dictionary else {}
	s["style"]["corner_r"] = clampf(float(st_in.get("corner_r", s["style"]["corner_r"])), 0.0, 6.0)
	s["style"]["foot_arch"] = bool(st_in.get("foot_arch", s["style"]["foot_arch"]))

	var j_in: Dictionary = spec.get("joinery", {}) if spec.get("joinery") is Dictionary else {}
	s["joinery"]["wedges"] = bool(j_in.get("wedges", true))
	var ov := {}
	var ov_in: Variant = j_in.get("overrides", {})
	if ov_in is Dictionary:
		for jid in ov_in:
			var o: Variant = ov_in[jid]
			if not (o is Dictionary):
				continue
			var e := {}
			if (o as Dictionary).has("kind"):
				var k := str(o["kind"])
				if k == "cross_lap" or k == "tenon":
					e["kind"] = k
			if (o as Dictionary).has("wedge"):
				e["wedge"] = bool(o["wedge"])
			if (o as Dictionary).has("ratio"):
				e["ratio"] = clampf(float(o["ratio"]), 0.0, 1.0)
			if not e.is_empty():
				ov[str(jid)] = e
	s["joinery"]["overrides"] = ov
	s["pose"] = str(spec.get("pose", ""))
	var po := {}
	var po_in: Variant = spec.get("profile_offsets", {})
	if po_in is Dictionary:
		for k in po_in:
			var v: Variant = po_in[k]
			if v is Vector2:
				po[str(k)] = v
			elif v is Array and (v as Array).size() >= 2:
				po[str(k)] = Vector2(float(v[0]), float(v[1]))
	s["profile_offsets"] = po
	var pov := {}
	var pov_in: Variant = spec.get("part_overrides", {})
	if pov_in is Dictionary:
		for k in pov_in:
			var v: Variant = pov_in[k]
			if v is Dictionary:
				var e := {}
				if (v as Dictionary).has("name"):
					e["name"] = str(v["name"]).strip_edges()
				if (v as Dictionary).has("hidden"):
					e["hidden"] = bool(v["hidden"])
				if (v as Dictionary).has("grain"):
					var g := str(v["grain"])
					if g in ["x", "y", "any"]:
						e["grain"] = g
				if not e.is_empty():
					pov[str(k)] = e
	s["part_overrides"] = pov
	return s


## A stable key for caching a solved design.
static func key_of(spec: Dictionary) -> String:
	return str(hash(var_to_str(resolve(spec))))


## JSON-safe copy (Vector2 → [x, y]) for the record / library.
static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var po := {}
	for k in s["profile_offsets"]:
		var v: Vector2 = s["profile_offsets"][k]
		po[k] = [v.x, v.y]
	s["profile_offsets"] = po
	return s


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

## Inches as a builder reads them: 11 3/4", 6", 15/32" (to the nearest
## 1/`denom`).
static func fmt_in(v: float, denom: int = 32) -> String:
	var neg := v < 0.0
	var a := absf(v)
	var whole := int(floor(a))
	var frac := int(round((a - whole) * denom))
	if frac >= denom:
		whole += 1
		frac = 0
	var txt := ""
	if frac == 0:
		txt = "%d\"" % whole
	else:
		var num := frac
		var den := denom
		while num % 2 == 0 and den > 1:
			num /= 2
			den /= 2
		txt = ("%d %d/%d\"" % [whole, num, den]) if whole > 0 else ("%d/%d\"" % [num, den])
	return ("-" + txt) if neg else txt


static func fmt_len(v_in: float, units: String = "in") -> String:
	if units == "mm":
		return "%d mm" % int(round(v_in * 25.4))
	return fmt_in(v_in)


static func fmt_size(w: float, h: float, units: String = "in") -> String:
	return "%s × %s" % [fmt_len(w, units), fmt_len(h, units)]
