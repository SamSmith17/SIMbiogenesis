class_name PeltonLabSpec
extends RefCounted

## The Pelton wheel designer's spec: what the player chose, resolved over
## defaults so every consumer reads a complete dictionary. Pure.
##
## Every wheel is built from the SAME cup (PeltonLabParts.CUP, the shipped
## STL), scaled uniformly by `cup_width_mm`. The player designs round it:
## how many cups, how big the wheel is, the side discs that clamp the cup
## tabs, the hub, shaft and bolt pattern, the jets, the housing, the shaft's
## bearings and drive, and the generator.
##
## {
##   version, name,
##   orientation: "horizontal" | "vertical" (the shaft),
##   runner:  {cups, overall_d_mm (tip to tip), cup_width_mm (79.04 = the STL
##             at its own size), cup_material: PeltonLabParts.CUP_MATERIALS id,
##             cup_bolts: 1 | 2 per cup, cup_bolt: BOLTS id, cup_tilt_deg: the
##             cup turned about its own width axis (0 = radial)}
##   rotor:   {disc_d_mm (0 = to just under the bowls), disc_t_mm, material:
##             PLATE_MATERIALS id} — two discs, the cup tabs between them,
##             a spacer ring the same thickness as the tabs inside them
##   hub:     {shaft_d_mm, keyway, flange_d_mm (0 = auto), boss_d_mm (0 =
##             auto), boss_len_mm (0 = auto), bolts (the hub bolt pattern's
##             count), bolt_pcd_mm (0 = auto), bolt: BOLTS id}
##   jets:    {count, d_mm, start_deg (-1 = by orientation: the first jet
##             under the wheel on a horizontal shaft), spacing_deg (0 = by
##             orientation), standoff_mm (0 = 1.5 jet Ø)} — the nozzle mouth
##             to where the jet meets the pitch circle
##   housing: {auto, axial_mm, height_mm, depth_mm (inside, used when auto is
##             off), clear_mm (0 = auto), wall_mm, material, window (a clear
##             front panel), base (a steel base plate / legs)}
##   drive:   {bearings: "pillow" | "flange", layout: "overhung" | "straddle",
##             span_mm (bearing centres, 0 = auto), type: PeltonLabParts.DRIVES
##             id, coupler: COUPLERS id, driver_d_mm / driven_d_mm (V-belt
##             pitch Ø), driver_teeth / driven_teeth (timing belt, gears),
##             module_mm (gears), gen_side: "above" | "beside", centre_mm (0 =
##             auto)}
##   generator: {id: GENERATORS id}
##   site:    {gross_head_m, pipe_len_m, pipe_d_mm, roughness_mm, battery_v,
##             supply_lps (< 0 = unlimited)} — what the designer simulates
##             when it is not bound to a turbine on the graph
##   colors:  {cup, disc, housing, frame, generator}
## }

const VERSION := 1

const RUNNER_DEFAULTS := {"cups": 21, "overall_d_mm": 351.0, "cup_width_mm": 79.04,
	"cup_material": "nylon", "cup_bolts": 2, "cup_bolt": "m6", "cup_tilt_deg": 0.0}
const ROTOR_DEFAULTS := {"disc_d_mm": 0.0, "disc_t_mm": 5.0, "material": "steel"}
const HUB_DEFAULTS := {"shaft_d_mm": 25.0, "keyway": true, "flange_d_mm": 0.0, "boss_d_mm": 0.0,
	"boss_len_mm": 0.0, "bolts": 6, "bolt_pcd_mm": 0.0, "bolt": "m8"}
const JET_DEFAULTS := {"count": 1, "d_mm": 22.0, "start_deg": -1.0, "spacing_deg": 0.0, "standoff_mm": 0.0}
const HOUSING_DEFAULTS := {"auto": true, "axial_mm": 280.0, "height_mm": 520.0, "depth_mm": 520.0,
	"clear_mm": 0.0, "wall_mm": 3.0, "material": "steel", "window": true, "base": true}
const DRIVE_DEFAULTS := {"bearings": "pillow", "layout": "overhung", "span_mm": 0.0, "type": "vbelt",
	"coupler": "jaw", "driver_d_mm": 160.0, "driven_d_mm": 100.0, "driver_teeth": 40, "driven_teeth": 24,
	"module_mm": 2.0, "gen_side": "above", "centre_mm": 0.0}
const GEN_DEFAULTS := {"id": "pma400"}
const SITE_DEFAULTS := {"gross_head_m": 15.0, "pipe_len_m": 80.0, "pipe_d_mm": 63.0, "roughness_mm": 0.0015,
	"battery_v": 24.0, "supply_lps": -1.0}
const COLOR_DEFAULTS := {"cup": Color(0.78, 0.62, 0.32), "disc": Color(0.36, 0.38, 0.42),
	"housing": Color(0.22, 0.42, 0.58), "frame": Color(0.18, 0.19, 0.21), "generator": Color(0.12, 0.13, 0.15)}

const MIN_CUPS := 6
const MAX_CUPS := 60


static func default_spec() -> Dictionary:
	return resolve({})


static func resolve(spec: Dictionary) -> Dictionary:
	var s := {}
	s["version"] = VERSION
	s["name"] = str(spec.get("name", "Pelton wheel"))
	var ori := str(spec.get("orientation", "horizontal"))
	s["orientation"] = ori if ori in PeltonLabParts.ORIENTATIONS else "horizontal"
	var r := _merge(RUNNER_DEFAULTS, spec.get("runner", {}))
	r["cups"] = clampi(int(r["cups"]), MIN_CUPS, MAX_CUPS)
	r["cup_width_mm"] = clampf(float(r["cup_width_mm"]), 20.0, 300.0)
	var k := float(r["cup_width_mm"]) / float(PeltonLabParts.CUP["width_mm"])
	# The wheel can never be smaller than the cups' own tips need round a
	# shaft; the design reports a crowded wheel, this only keeps it solvable.
	r["overall_d_mm"] = clampf(float(r["overall_d_mm"]), 160.0 * k, 3000.0)
	if not PeltonLabParts.CUP_MATERIALS.has(str(r["cup_material"])):
		r["cup_material"] = RUNNER_DEFAULTS["cup_material"]
	r["cup_bolts"] = clampi(int(r["cup_bolts"]), 1, 2)
	if not PeltonLabParts.BOLTS.has(str(r["cup_bolt"])):
		r["cup_bolt"] = RUNNER_DEFAULTS["cup_bolt"]
	r["cup_tilt_deg"] = clampf(float(r["cup_tilt_deg"]), -20.0, 20.0)
	s["runner"] = r
	var ro := _merge(ROTOR_DEFAULTS, spec.get("rotor", {}))
	ro["disc_d_mm"] = maxf(float(ro["disc_d_mm"]), 0.0)
	ro["disc_t_mm"] = clampf(float(ro["disc_t_mm"]), 1.0, 30.0)
	if not PeltonLabParts.PLATE_MATERIALS.has(str(ro["material"])):
		ro["material"] = "steel"
	s["rotor"] = ro
	var h := _merge(HUB_DEFAULTS, spec.get("hub", {}))
	h["shaft_d_mm"] = clampf(float(h["shaft_d_mm"]), 8.0, 60.0)
	h["keyway"] = bool(h["keyway"])
	for key in ["flange_d_mm", "boss_d_mm", "boss_len_mm", "bolt_pcd_mm"]:
		h[key] = maxf(float(h[key]), 0.0)
	h["bolts"] = clampi(int(h["bolts"]), 3, 12)
	if not PeltonLabParts.BOLTS.has(str(h["bolt"])):
		h["bolt"] = "m8"
	s["hub"] = h
	var j := _merge(JET_DEFAULTS, spec.get("jets", {}))
	j["count"] = clampi(int(j["count"]), 1, int(PeltonLabParts.MAX_JETS[s["orientation"]]))
	j["d_mm"] = clampf(float(j["d_mm"]), 1.0, 150.0)
	j["start_deg"] = float(j["start_deg"])
	j["spacing_deg"] = clampf(float(j["spacing_deg"]), 0.0, 180.0)
	j["standoff_mm"] = maxf(float(j["standoff_mm"]), 0.0)
	s["jets"] = j
	var hs := _merge(HOUSING_DEFAULTS, spec.get("housing", {}))
	hs["auto"] = bool(hs["auto"])
	for key in ["axial_mm", "height_mm", "depth_mm"]:
		hs[key] = clampf(float(hs[key]), 50.0, 5000.0)
	hs["clear_mm"] = maxf(float(hs["clear_mm"]), 0.0)
	hs["wall_mm"] = clampf(float(hs["wall_mm"]), 1.0, 30.0)
	if not PeltonLabParts.PLATE_MATERIALS.has(str(hs["material"])):
		hs["material"] = "steel"
	hs["window"] = bool(hs["window"])
	hs["base"] = bool(hs["base"])
	s["housing"] = hs
	var dr := _merge(DRIVE_DEFAULTS, spec.get("drive", {}))
	if not str(dr["bearings"]) in PeltonLabParts.BEARING_TYPES:
		dr["bearings"] = "pillow"
	if not str(dr["layout"]) in PeltonLabParts.BEARING_LAYOUTS:
		dr["layout"] = "overhung"
	if not PeltonLabParts.DRIVES.has(str(dr["type"])):
		dr["type"] = "vbelt"
	if not PeltonLabParts.COUPLERS.has(str(dr["coupler"])):
		dr["coupler"] = "jaw"
	dr["span_mm"] = maxf(float(dr["span_mm"]), 0.0)
	dr["driver_d_mm"] = clampf(float(dr["driver_d_mm"]), 20.0, 1000.0)
	dr["driven_d_mm"] = clampf(float(dr["driven_d_mm"]), 20.0, 1000.0)
	dr["driver_teeth"] = clampi(int(dr["driver_teeth"]), 8, 200)
	dr["driven_teeth"] = clampi(int(dr["driven_teeth"]), 8, 200)
	dr["module_mm"] = clampf(float(dr["module_mm"]), 0.5, 10.0)
	if not str(dr["gen_side"]) in PeltonLabParts.GEN_SIDES:
		dr["gen_side"] = "above"
	dr["centre_mm"] = maxf(float(dr["centre_mm"]), 0.0)
	s["drive"] = dr
	var g := _merge(GEN_DEFAULTS, spec.get("generator", {}))
	if not PeltonLabParts.GENERATORS.has(str(g["id"])):
		g["id"] = "pma400"
	s["generator"] = g
	var st := _merge(SITE_DEFAULTS, spec.get("site", {}))
	st["gross_head_m"] = clampf(float(st["gross_head_m"]), 0.5, 1000.0)
	st["pipe_len_m"] = maxf(float(st["pipe_len_m"]), 0.0)
	st["pipe_d_mm"] = clampf(float(st["pipe_d_mm"]), 10.0, 1000.0)
	st["roughness_mm"] = maxf(float(st["roughness_mm"]), 0.0)
	st["battery_v"] = maxf(float(st["battery_v"]), 0.0)
	st["supply_lps"] = float(st["supply_lps"])
	s["site"] = st
	var cols := {}
	var cin: Dictionary = spec.get("colors", {}) if spec.get("colors", {}) is Dictionary else {}
	for key in COLOR_DEFAULTS:
		cols[key] = _to_color(cin.get(key, null), COLOR_DEFAULTS[key])
	s["colors"] = cols
	return s


static func _merge(defaults: Dictionary, over: Variant) -> Dictionary:
	var out := defaults.duplicate(true)
	if over is Dictionary:
		for k in (over as Dictionary):
			if out.has(k):
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


static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var cols := {}
	for k in s["colors"]:
		var c: Color = s["colors"][k]
		cols[k] = [c.r, c.g, c.b, c.a]
	s["colors"] = cols
	return s


## The cache key (everything that changes geometry, parts, looks or numbers).
static func key_of(spec: Dictionary) -> String:
	return str(hash(var_to_str(to_json_safe(spec))))


## The geometry-only key: the site and colours left out, so the studio does
## not rebuild the machine when only the head changes.
static func geometry_key(spec: Dictionary) -> String:
	var s := to_json_safe(spec)
	s.erase("site")
	s.erase("name")
	return str(hash(var_to_str(s)))


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

static func fmt_mm(mm: float, decimals: int = 0) -> String:
	return ("%." + str(decimals) + "f mm") % mm


static func fmt_rpm(rpm: float) -> String:
	return "%d rpm" % int(round(rpm))


static func fmt_kg(kg: float) -> String:
	return "%.2f kg" % kg if kg < 10.0 else "%.1f kg" % kg


static func describe(spec: Dictionary) -> String:
	var s := resolve(spec)
	var r: Dictionary = s["runner"]
	return "%d cups · %s overall · %s cups · %s" % [int(r["cups"]), fmt_mm(float(r["overall_d_mm"])),
		fmt_mm(float(r["cup_width_mm"])), str(PeltonLabParts.ORIENTATION_LABELS[s["orientation"]]).to_lower()]
