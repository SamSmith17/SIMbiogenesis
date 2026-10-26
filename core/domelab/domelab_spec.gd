class_name DomeLabSpec
extends RefCounted

## The dome / zome designer's spec: what the player chose, resolved over
## defaults so every consumer reads a complete dictionary. Pure.
##
## {
##   version, name,
##   family:     "geodesic" | "zome" | "helical"
##   geodesic:   {base: icosa|octa|tetra, cls: 1|2|3, frequency: 1..10,
##                b, c (Class III only), orientation: vertex|face|edge,
##                fraction: 0.25..1.0 (the share of the sphere kept, from the
##                top), flat_base: bool, stretch: vertical scale}
##   zome:       {sides: 3..16, layers: 1..sides, pitch_deg: generator tilt
##                from the axis, base: "cut" | "zigzag", triangulate: bool,
##                stretch: vertical scale, ribs: bool (helix ribs instead of
##                straight struts — the "helix zome")}
##   helical:    {sides: 3..16, pitch_deg, window: 3..sides (generators per
##                cell; = sides sweeps the whole zonohedron, 3 stacks
##                rhombohedra — the "stacked cubes"), steps: 0..48 cells after
##                the first (sides steps = one turn), hand: "right" | "left",
##                levels: rows kept from the apex down, 0 = the whole body
##                (the floor is cut level there), stretch}
##   radius_m:   the widest horizontal radius of the finished structure (a
##               helical zome: of one zonohedral cell)
##   system:     "bolt_stack" | "hub" | "flat_bar" | "nexorade" | "plate"
##   strut:      {material: DomeLabMaterials.STRUTS id}
##   ends:       {flatten_mm: how much of each end is pressed flat,
##                hole_offset_mm: hole centre from the cut end,
##                insert_mm: how far a strut slides onto / into a hub arm}
##   hub:        {kind: "bolt" | "socket" | "plate" | "ring", bolt: BOLTS id,
##                reach_mm: hub centre to the strut end, plate_t_mm}
##   nexorade:   {mode: "band" (flexible bands follow the surface; auto fits
##                the engagement length) | "rigid" (straight slats; auto fits
##                the eccentricity to the slat thickness), engagement_deg: 0 =
##                auto, engage_frac: engagement length / edge, overhang_mm,
##                slat: STRUTS id}
##   face:       {material: SHEETS id, gap_mm (seam between panels; for plates
##                the gap between two flanges bolted back to back),
##                flange_mm (plate system), hole_pitch_mm, screw_mm,
##                thickness_mm (0 = the sheet's own), fold_radius_mm (inside
##                radius of a flange's bend, 0 = the sheet's thickness),
##                oculus: bool, oculus_mm (opening's offset in from the
##                panel's edge), oculus_round (0 sharp .. 1 fully round
##                corners), oculus_zones: [rhombus types, empty = every
##                face], glazing: SHEETS id ("none" = open), bolts: draw the
##                flange bolts}
##   fabrication:{units: "mm" | "in", group_tol_mm, angle_tol_deg,
##                sheet_w_mm, sheet_h_mm (0 = the material's), kerf_mm,
##                label_struts: bool}
##   colors:     {strut, hub, face} (Color or [r,g,b,a])
## }

const VERSION := 1

const FAMILIES := ["geodesic", "zome", "helical"]
const FAMILY_LABELS := {"geodesic": "Geodesic dome", "zome": "Zome (polar zonohedron)",
	"helical": "Helical zome (twisted zonohedron)"}
const HANDS := ["right", "left"]
const HAND_LABELS := {"right": "Right-handed", "left": "Left-handed"}
const BASES := ["icosa", "octa", "tetra"]
const BASE_LABELS := {"icosa": "Icosahedron (20 faces)", "octa": "Octahedron (8 faces)",
	"tetra": "Tetrahedron (4 faces)"}
const ORIENTATIONS := ["vertex", "face", "edge"]
const ORIENTATION_LABELS := {"vertex": "Vertex at the top", "face": "Face at the top",
	"edge": "Edge at the top"}
const SYSTEMS := ["bolt_stack", "hub", "flat_bar", "nexorade", "plate"]
const SYSTEM_LABELS := {
	"bolt_stack": "Flattened ends on a bolt (conduit dome)",
	"hub": "Rigid struts into hubs",
	"flat_bar": "Flat bars bent to the curve, bolted at hubs",
	"nexorade": "Nexorade / rotegrity (hubless, slats overlap)",
	"plate": "Plates only (folded flanges, no struts)",
}
const SYSTEM_SHORT := {"bolt_stack": "Bolted conduit", "hub": "Hub & strut", "flat_bar": "Flat bar",
	"nexorade": "Nexorade", "plate": "Plates"}
const HUB_KINDS := ["bolt", "socket", "plate", "ring"]
const HUB_LABELS := {"bolt": "One bolt through the stack", "socket": "Socket hub (arms the struts slide on)",
	"plate": "Flat star plate, struts bolted on", "ring": "Pipe ring hub"}
const ZOME_BASES := ["cut", "zigzag"]
const ZOME_BASE_LABELS := {"cut": "Flat floor (bottom rhombi cut to triangles)",
	"zigzag": "Zigzag (whole rhombi)"}
const FRACTIONS := [[1.0, "Full sphere"], [0.75, "3/4"], [0.625, "5/8"], [0.5, "1/2 (hemisphere)"],
	[0.375, "3/8"], [0.25, "1/4"]]
const UNITS := ["mm", "in"]

const GEODESIC_DEFAULTS := {"base": "icosa", "cls": 1, "frequency": 3, "b": 2, "c": 1,
	"orientation": "vertex", "fraction": 0.625, "flat_base": true, "stretch": 1.0}
const ZOME_DEFAULTS := {"sides": 8, "layers": 4, "pitch_deg": 40.0, "base": "cut",
	"triangulate": false, "stretch": 1.0, "ribs": false}
const HELICAL_DEFAULTS := {"sides": 10, "pitch_deg": 57.0, "window": 10, "steps": 10, "hand": "right",
	"levels": 0, "stretch": 1.0}
const STRUT_DEFAULTS := {"material": "emt_34"}
const ENDS_DEFAULTS := {"flatten_mm": 50.0, "hole_offset_mm": 25.0, "insert_mm": 40.0}
const HUB_DEFAULTS := {"kind": "bolt", "bolt": "3_8", "reach_mm": 60.0, "plate_t_mm": 3.0}
const NEXORADE_DEFAULTS := {"mode": "band", "engagement_deg": 0.0, "engage_frac": 0.22, "overhang_mm": 40.0,
	"slat": "hdpe_bar_50x6"}
const NEXORADE_MODES := ["band", "rigid"]
const NEXORADE_MODE_LABELS := {"band": "Flexible bands on the surface (rotegrity)",
	"rigid": "Straight rigid slats (eccentricity = thickness)"}
const FACE_DEFAULTS := {"material": "none", "gap_mm": 6.0, "flange_mm": 40.0, "hole_pitch_mm": 150.0,
	"screw_mm": 5.0, "thickness_mm": 0.0, "fold_radius_mm": 0.0, "oculus": false, "oculus_mm": 80.0,
	"oculus_round": 0.3, "oculus_zones": [], "glazing": "none", "bolts": true}
const FAB_DEFAULTS := {"units": "mm", "group_tol_mm": 1.0, "angle_tol_deg": 0.5, "sheet_w_mm": 0.0,
	"sheet_h_mm": 0.0, "kerf_mm": 3.0, "label_struts": true}
const COLOR_DEFAULTS := {"strut": Color(0.70, 0.72, 0.74), "hub": Color(0.25, 0.26, 0.30),
	"face": Color(0.85, 0.87, 0.80)}

const MIN_RADIUS_M := 0.5
const MAX_RADIUS_M := 60.0


static func default_spec(family: String = "geodesic") -> Dictionary:
	var nm := {"geodesic": "3V 5/8 conduit dome", "zome": "8-sided zome", "helical": "Helical zome"}
	var s := {"family": family, "name": str(nm.get(family, "Dome"))}
	if family == "helical":
		s["system"] = "plate"
		s["face"] = {"material": "steel_06", "flange_mm": 40.0}
	return resolve(s)


static func resolve(spec: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	s["version"] = VERSION
	var fam := str(s.get("family", "geodesic"))
	if not FAMILIES.has(fam):
		fam = "geodesic"
	s["family"] = fam
	s["name"] = str(s.get("name", "Dome")).strip_edges()
	if s["name"].is_empty():
		s["name"] = "Dome"
	s["radius_m"] = clampf(float(s.get("radius_m", 4.0)), MIN_RADIUS_M, MAX_RADIUS_M)
	var sys := str(s.get("system", "bolt_stack"))
	if not SYSTEMS.has(sys):
		sys = "bolt_stack"
	s["system"] = sys
	s["geodesic"] = _merge(GEODESIC_DEFAULTS, s.get("geodesic", {}))
	s["zome"] = _merge(ZOME_DEFAULTS, s.get("zome", {}))
	s["helical"] = _merge(HELICAL_DEFAULTS, s.get("helical", {}))
	s["strut"] = _merge(STRUT_DEFAULTS, s.get("strut", {}))
	s["ends"] = _merge(ENDS_DEFAULTS, s.get("ends", {}))
	s["hub"] = _merge(HUB_DEFAULTS, s.get("hub", {}))
	s["nexorade"] = _merge(NEXORADE_DEFAULTS, s.get("nexorade", {}))
	s["face"] = _merge(FACE_DEFAULTS, s.get("face", {}))
	s["fabrication"] = _merge(FAB_DEFAULTS, s.get("fabrication", {}))
	var cols := _merge(COLOR_DEFAULTS, s.get("colors", {}))
	for k in cols:
		cols[k] = _to_color(cols[k], COLOR_DEFAULTS[k])
	s["colors"] = cols
	# Clamps.
	var g: Dictionary = s["geodesic"]
	if not BASES.has(str(g["base"])):
		g["base"] = "icosa"
	g["cls"] = clampi(int(g["cls"]), 1, 3)
	g["frequency"] = clampi(int(g["frequency"]), 1, 10)
	g["b"] = clampi(int(g["b"]), 1, 8)
	g["c"] = clampi(int(g["c"]), 1, 8)
	if g["b"] == g["c"]:
		g["c"] = maxi(1, int(g["b"]) - 1) if int(g["b"]) > 1 else 2
	if not ORIENTATIONS.has(str(g["orientation"])):
		g["orientation"] = "vertex"
	g["fraction"] = clampf(float(g["fraction"]), 0.2, 1.0)
	g["flat_base"] = bool(g["flat_base"])
	g["stretch"] = clampf(float(g["stretch"]), 0.4, 2.5)
	var z: Dictionary = s["zome"]
	z["sides"] = clampi(int(z["sides"]), 3, 16)
	z["layers"] = clampi(int(z["layers"]), 1, int(z["sides"]))
	z["pitch_deg"] = clampf(float(z["pitch_deg"]), 10.0, 80.0)
	if not ZOME_BASES.has(str(z["base"])):
		z["base"] = "cut"
	z["triangulate"] = bool(z["triangulate"])
	z["stretch"] = clampf(float(z["stretch"]), 0.4, 2.5)
	z["ribs"] = bool(z["ribs"])
	var hx: Dictionary = s["helical"]
	hx["sides"] = clampi(int(hx["sides"]), 3, 16)
	hx["pitch_deg"] = clampf(float(hx["pitch_deg"]), 10.0, 80.0)
	hx["window"] = clampi(int(hx["window"]), 3, int(hx["sides"]))
	hx["steps"] = clampi(int(hx["steps"]), 0, 48)
	if not HANDS.has(str(hx["hand"])):
		hx["hand"] = "right"
	hx["levels"] = clampi(int(hx["levels"]), 0, 80)
	hx["stretch"] = clampf(float(hx["stretch"]), 0.4, 2.5)
	var st: Dictionary = s["strut"]
	if not DomeLabMaterials.STRUTS.has(str(st["material"])):
		st["material"] = "emt_34"
	var e: Dictionary = s["ends"]
	e["flatten_mm"] = clampf(float(e["flatten_mm"]), 0.0, 200.0)
	e["hole_offset_mm"] = clampf(float(e["hole_offset_mm"]), 5.0, 150.0)
	e["insert_mm"] = clampf(float(e["insert_mm"]), 0.0, 200.0)
	var h: Dictionary = s["hub"]
	if not HUB_KINDS.has(str(h["kind"])):
		h["kind"] = "bolt"
	if not DomeLabMaterials.BOLTS.has(str(h["bolt"])):
		h["bolt"] = "3_8"
	h["reach_mm"] = clampf(float(h["reach_mm"]), 0.0, 400.0)
	h["plate_t_mm"] = clampf(float(h["plate_t_mm"]), 1.0, 12.0)
	var nx: Dictionary = s["nexorade"]
	if not NEXORADE_MODES.has(str(nx["mode"])):
		nx["mode"] = "band"
	nx["engage_frac"] = clampf(float(nx["engage_frac"]), 0.08, 0.45)
	nx["engagement_deg"] = clampf(float(nx["engagement_deg"]), 0.0, 40.0)
	nx["overhang_mm"] = clampf(float(nx["overhang_mm"]), 0.0, 300.0)
	if not DomeLabMaterials.STRUTS.has(str(nx["slat"])):
		nx["slat"] = "hdpe_bar_50x6"
	var f: Dictionary = s["face"]
	if not DomeLabMaterials.SHEETS.has(str(f["material"])):
		f["material"] = "none"
	f["gap_mm"] = clampf(float(f["gap_mm"]), 0.0, 60.0)
	f["flange_mm"] = clampf(float(f["flange_mm"]), 10.0, 150.0)
	f["hole_pitch_mm"] = clampf(float(f["hole_pitch_mm"]), 40.0, 600.0)
	f["screw_mm"] = clampf(float(f["screw_mm"]), 2.0, 12.0)
	f["thickness_mm"] = clampf(float(f["thickness_mm"]), 0.0, 25.0)
	f["fold_radius_mm"] = clampf(float(f["fold_radius_mm"]), 0.0, 100.0)
	f["oculus"] = bool(f["oculus"])
	f["oculus_mm"] = clampf(float(f["oculus_mm"]), 10.0, 1000.0)
	f["oculus_round"] = clampf(float(f["oculus_round"]), 0.0, 1.0)
	var zones: Array = []
	if f["oculus_zones"] is Array:
		for zv in (f["oculus_zones"] as Array):
			var zi := int(zv)
			if zi >= 1 and not zones.has(zi):
				zones.append(zi)
	zones.sort()
	f["oculus_zones"] = zones
	if not DomeLabMaterials.SHEETS.has(str(f["glazing"])):
		f["glazing"] = "none"
	f["bolts"] = bool(f["bolts"])
	var fb: Dictionary = s["fabrication"]
	if not UNITS.has(str(fb["units"])):
		fb["units"] = "mm"
	fb["group_tol_mm"] = clampf(float(fb["group_tol_mm"]), 0.05, 20.0)
	fb["angle_tol_deg"] = clampf(float(fb["angle_tol_deg"]), 0.05, 5.0)
	fb["sheet_w_mm"] = maxf(float(fb["sheet_w_mm"]), 0.0)
	fb["sheet_h_mm"] = maxf(float(fb["sheet_h_mm"]), 0.0)
	fb["kerf_mm"] = clampf(float(fb["kerf_mm"]), 0.0, 20.0)
	fb["label_struts"] = bool(fb["label_struts"])
	# A plate system has no struts; faces must be a sheet.
	if sys == "plate" and str(f["material"]) == "none":
		f["material"] = "ply_6"
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


## The spec with every Color as [r, g, b, a], so it survives JSON.
static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var cols := {}
	for k in s["colors"]:
		var c: Color = s["colors"][k]
		cols[k] = [c.r, c.g, c.b, c.a]
	s["colors"] = cols
	return s


## The part of the spec that changes the geometry / parts (cache key).
static func key_of(spec: Dictionary) -> String:
	var s := resolve(spec)
	var cols := {}
	for k in s["colors"]:
		var c: Color = s["colors"][k]
		cols[k] = "%.3f,%.3f,%.3f,%.3f" % [c.r, c.g, c.b, c.a]
	s["colors"] = cols
	return str(hash(var_to_str(s)))


# ---------------------------------------------------------------------------
# Formatting (the fabrication units)
# ---------------------------------------------------------------------------

static func fmt_len(mm: float, units: String = "mm", decimals: int = 1) -> String:
	if units == "in":
		var inches := mm / 25.4
		if absf(inches) >= 36.0:
			return "%.2f\" (%s)" % [inches, fmt_ft_in(inches)]
		return "%.3f\"" % inches
	if absf(mm) >= 1000.0:
		return "%.3f m" % (mm / 1000.0)
	return ("%." + str(decimals) + "f mm") % mm


static func fmt_ft_in(inches: float) -> String:
	var ft := int(floor(inches / 12.0))
	var rem := inches - ft * 12.0
	return "%d' %.1f\"" % [ft, rem]


static func fmt_m(m: float) -> String:
	return "%.2f m" % m


static func fmt_deg(d: float) -> String:
	return "%.1f°" % d


static func fmt_kg(kg: float) -> String:
	if kg >= 1000.0:
		return "%.2f t" % (kg / 1000.0)
	if kg >= 10.0:
		return "%.0f kg" % kg
	return "%.1f kg" % kg


static func fmt_area(m2: float) -> String:
	return "%.1f m²" % m2


## A spec's one-line description.
static func describe(spec: Dictionary) -> String:
	var s := resolve(spec)
	var geo := ""
	if str(s["family"]) == "geodesic":
		var g: Dictionary = s["geodesic"]
		var cls := int(g["cls"])
		var f := int(g["frequency"])
		var frac := ""
		for pair in FRACTIONS:
			if absf(float(pair[0]) - float(g["fraction"])) < 1e-6:
				frac = str(pair[1])
		if frac.is_empty():
			frac = "%d%% of the sphere" % int(round(float(g["fraction"]) * 100.0))
		var cls_txt := "Class %s" % ["I", "II", "III"][cls - 1]
		if cls == 3:
			geo = "%s (%d,%d) %s %s" % [str(BASE_LABELS[str(g["base"])]).split(" ")[0], int(g["b"]),
				int(g["c"]), cls_txt, frac]
		else:
			geo = "%dV %s %s %s" % [f, str(BASE_LABELS[str(g["base"])]).split(" ")[0], cls_txt, frac]
	elif str(s["family"]) == "helical":
		var hx: Dictionary = s["helical"]
		var turns := float(hx["steps"]) / float(hx["sides"])
		geo = "%d-sided helical zome, %s cells, %.1f turns" % [int(hx["sides"]), str(int(hx["window"])) + "-zone",
			turns]
	else:
		var z: Dictionary = s["zome"]
		geo = "%d-sided zome, %d layers%s" % [int(z["sides"]), int(z["layers"]),
			" (helix ribs)" if bool(z["ribs"]) else ""]
	return "%s · %s · R %s" % [geo, str(SYSTEM_SHORT[str(s["system"])]), fmt_m(float(s["radius_m"]))]
