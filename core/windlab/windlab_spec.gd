class_name WindLabSpec
extends RefCounted

## The wind turbine designer's spec: what the player chose, resolved over
## defaults so every consumer reads a complete dictionary. Pure.
##
## {
##   version, name,
##   type: WindLabParts.TYPES id,
##   rotor: {d_mm (rotor diameter: tip to tip), h_mm (VAWT rotor height),
##           blades,
##           Ugrinsky: s_ratio (the semicircle's diameter S / D), l_ratio
##             (the tail arc's radius L / R), sweep_deg (how far the tail arc
##             runs round its centre)
##           Savonius: overlap (e / bucket chord), stages (1 or 2, stacked a
##             half bucket-turn apart), twist_deg (helical twist over the
##             height)
##           Lenz2: chord_frac (wing chord / D), camber_frac (wing depth /
##             chord), set_deg (wing set angle)
##           Darrieus / helical: chord_mm, airfoil, helix_deg (helical: how
##             far each blade wraps round), arms (struts per blade)
##           HAWT: tsr (design tip speed ratio), airfoil, hub_frac (hub radius
##             / R), pitch_deg (extra blade pitch), construction ("printed"
##             | "carved" | "pvc_pipe"), pipe_d_mm (pvc_pipe), tail (vane)
##           Multi-blade: (blades) and camber_frac
##           start_assist (pushed / motored up to speed: a Darrieus)
##           hub: {style "mid_discs" | "end_plates" | "spokes", count (mid
##             discs), spacing_mm (between mid discs), overhang (end plate
##             Ø / D)}}
##   build:  {sheet: WindLabParts.SHEETS id (sheet rotors, discs), sheet_size,
##            solid: SOLIDS id (foil blades, printed hubs), score_tol_mm (the
##            most a scored facet may sit off the true curve), slot_clear_mm,
##            tabs (sheet blades end in tabs through slotted end plates),
##            print_max_mm (the longest a printed piece may be), kerf_mm
##            (between nested parts), margin_mm (round the sheet's edge)}
##   mount:  {style: MOUNTS id, mast: MASTS id, mast_h_mm (from the ground to
##            the rotor's bottom / the HAWT hub), shaft_d_mm (bearings)}
##   drive:  {type: DRIVES id, driver_teeth (on the rotor), driven_teeth (on
##            the generator), planetary_ratio}
##   generator: {id: GENERATORS id, count (generators on the one shaft
##            through one drive each — 1 or 2)}
##   load:   {type: LOADS id, battery_v, resistor_ohm, diode: DIODES id,
##            mppt_min_v, mppt_eff}
##   site:   {mean_wind_ms (annual mean at 10 m), design_wind_ms (the speed
##            the numbers are quoted at), altitude_m, roughness_m (z0),
##            cut_out_ms (0 = auto: the generator's top speed)}
##   colors: {blade, hub, frame, generator}
## }

const VERSION := 1

const ROTOR_DEFAULTS := {"d_mm": 600.0, "h_mm": 900.0, "blades": 2,
	"s_ratio": 0.35, "l_ratio": 1.0, "sweep_deg": 72.0,
	"overlap": 0.15, "stages": 1, "twist_deg": 0.0,
	"chord_frac": 0.30, "camber_frac": 0.14, "set_deg": 15.0,
	"chord_mm": 120.0, "airfoil": "naca0018", "helix_deg": 60.0, "arms": 2,
	"tsr": 6.0, "hub_frac": 0.12, "pitch_deg": 0.0, "construction": "printed", "pipe_d_mm": 160.0, "tail": true,
	"start_assist": false,
	"hub": {"style": "end_plates", "count": 2, "spacing_mm": 50.0, "overhang": 1.08}}
const BUILD_DEFAULTS := {"sheet": "correx_4", "sheet_size": "sheet_4x8", "solid": "petg", "score_tol_mm": 1.5,
	"slot_clear_mm": 0.4, "tabs": true, "print_max_mm": 220.0,
	"kerf_mm": 3.0, "margin_mm": 5.0}
const MOUNT_DEFAULTS := {"style": "bearings", "mast": "pipe_33", "mast_h_mm": 3000.0, "shaft_d_mm": 12.0, "guyed": true}
const DRIVE_DEFAULTS := {"type": "gt2", "driver_teeth": 60, "driven_teeth": 20, "planetary_ratio": 5.0}
const GEN_DEFAULTS := {"id": "nema23_76", "count": 1}
const LOAD_DEFAULTS := {"type": "battery", "battery_v": 12.0, "resistor_ohm": 4.0, "diode": "schottky",
	"mppt_min_v": 8.0, "mppt_eff": 0.95}
const SITE_DEFAULTS := {"mean_wind_ms": 4.5, "design_wind_ms": 6.0, "altitude_m": 0.0, "roughness_m": 0.03,
	"cut_out_ms": 0.0, "survival_ms": 30.0}
const COLOR_DEFAULTS := {"blade": Color(0.93, 0.93, 0.9), "hub": Color(0.86, 0.86, 0.84),
	"frame": Color(0.35, 0.37, 0.4), "generator": Color(0.12, 0.13, 0.15)}

const HUB_STYLES := ["mid_discs", "end_plates", "spokes"]
const CONSTRUCTIONS := ["printed", "carved", "pvc_pipe"]


static func default_spec() -> Dictionary:
	return resolve({})


static func resolve(spec: Dictionary) -> Dictionary:
	var s := {}
	s["version"] = VERSION
	s["name"] = str(spec.get("name", "Wind turbine"))
	var ty := str(spec.get("type", "ugrinsky"))
	s["type"] = ty if WindLabParts.TYPES.has(ty) else "ugrinsky"
	var vawt := WindLabParts.is_vawt(s["type"])
	var r := _merge(ROTOR_DEFAULTS, spec.get("rotor", {}))
	r["d_mm"] = clampf(float(r["d_mm"]), 60.0, 20000.0)
	r["h_mm"] = clampf(float(r["h_mm"]), 60.0, 20000.0)
	var b_lo := 2
	var b_hi := 3
	match str(s["type"]):
		"darrieus_h", "helical":
			b_lo = 2
			b_hi = 5
		"lenz2":
			b_lo = 2
			b_hi = 4
		"hawt":
			b_lo = 1
			b_hi = 6
		"multiblade":
			b_lo = 6
			b_hi = 24
		"ugrinsky":
			b_lo = 2
			b_hi = 3
	if str(s["type"]) == "multiblade" and int(r["blades"]) < 6:
		r["blades"] = 12
	r["blades"] = clampi(int(r["blades"]), b_lo, b_hi)
	r["s_ratio"] = clampf(float(r["s_ratio"]), 0.15, 0.6)
	r["l_ratio"] = clampf(float(r["l_ratio"]), 0.5, 1.6)
	r["sweep_deg"] = clampf(float(r["sweep_deg"]), 10.0, 150.0)
	r["overlap"] = clampf(float(r["overlap"]), 0.0, 0.5)
	r["stages"] = clampi(int(r["stages"]), 1, 2)
	r["twist_deg"] = clampf(float(r["twist_deg"]), 0.0, 180.0)
	r["chord_frac"] = clampf(float(r["chord_frac"]), 0.1, 0.5)
	r["camber_frac"] = clampf(float(r["camber_frac"]), 0.02, 0.4)
	r["set_deg"] = clampf(float(r["set_deg"]), -30.0, 45.0)
	r["chord_mm"] = clampf(float(r["chord_mm"]), 10.0, 3000.0)
	if not WindLabParts.AIRFOILS.has(str(r["airfoil"])):
		r["airfoil"] = "naca0018" if vawt else "sg6043"
	r["helix_deg"] = clampf(float(r["helix_deg"]), 0.0, 180.0)
	r["arms"] = clampi(int(r["arms"]), 1, 4)
	r["tsr"] = clampf(float(r["tsr"]), 1.0, 12.0)
	r["hub_frac"] = clampf(float(r["hub_frac"]), 0.04, 0.4)
	r["pitch_deg"] = clampf(float(r["pitch_deg"]), -20.0, 30.0)
	if not str(r["construction"]) in CONSTRUCTIONS:
		r["construction"] = "printed"
	r["pipe_d_mm"] = clampf(float(r["pipe_d_mm"]), 40.0, 1000.0)
	r["tail"] = bool(r["tail"])
	r["start_assist"] = bool(r["start_assist"])
	var hub := _merge(ROTOR_DEFAULTS["hub"], r.get("hub", {}))
	if not str(hub["style"]) in HUB_STYLES:
		hub["style"] = "end_plates"
	hub["count"] = clampi(int(hub["count"]), 1, 6)
	hub["spacing_mm"] = clampf(float(hub["spacing_mm"]), 0.0, 5000.0)
	hub["overhang"] = clampf(float(hub["overhang"]), 1.0, 1.4)
	r["hub"] = hub
	s["rotor"] = r
	var bd := _merge(BUILD_DEFAULTS, spec.get("build", {}))
	if not WindLabParts.SHEETS.has(str(bd["sheet"])):
		bd["sheet"] = "correx_4"
	if not WindLabParts.SHEET_SIZES.has(str(bd["sheet_size"])):
		bd["sheet_size"] = "sheet_4x8"
	if not WindLabParts.SOLIDS.has(str(bd["solid"])):
		bd["solid"] = "petg"
	bd["score_tol_mm"] = clampf(float(bd["score_tol_mm"]), 0.2, 20.0)
	bd["slot_clear_mm"] = clampf(float(bd["slot_clear_mm"]), 0.0, 5.0)
	bd["tabs"] = bool(bd["tabs"])
	bd["print_max_mm"] = clampf(float(bd["print_max_mm"]), 50.0, 2000.0)
	bd["kerf_mm"] = clampf(float(bd["kerf_mm"]), 0.0, 20.0)
	bd["margin_mm"] = clampf(float(bd["margin_mm"]), 0.0, 50.0)
	s["build"] = bd
	var m := _merge(MOUNT_DEFAULTS, spec.get("mount", {}))
	if not WindLabParts.MOUNTS.has(str(m["style"])):
		m["style"] = "bearings"
	if not WindLabParts.MASTS.has(str(m["mast"])):
		m["mast"] = "pipe_33"
	m["mast_h_mm"] = clampf(float(m["mast_h_mm"]), 100.0, 40000.0)
	m["shaft_d_mm"] = clampf(float(m["shaft_d_mm"]), 5.0, 60.0)
	m["guyed"] = bool(m["guyed"])
	s["mount"] = m
	var dr := _merge(DRIVE_DEFAULTS, spec.get("drive", {}))
	if not WindLabParts.DRIVES.has(str(dr["type"])):
		dr["type"] = "gt2"
	# A rotor clamped to the generator's body or on its shaft has no drive.
	if str(m["style"]) != "bearings":
		dr["type"] = "direct"
	dr["driver_teeth"] = clampi(int(dr["driver_teeth"]), 8, 400)
	dr["driven_teeth"] = clampi(int(dr["driven_teeth"]), 8, 400)
	dr["planetary_ratio"] = clampf(float(dr["planetary_ratio"]), 1.0, 100.0)
	s["drive"] = dr
	var g := _merge(GEN_DEFAULTS, spec.get("generator", {}))
	if not WindLabParts.GENERATORS.has(str(g["id"])):
		g["id"] = "nema17_48"
	g["count"] = clampi(int(g["count"]), 1, 2)
	s["generator"] = g
	var ld := _merge(LOAD_DEFAULTS, spec.get("load", {}))
	if not WindLabParts.LOADS.has(str(ld["type"])):
		ld["type"] = "battery"
	if not WindLabParts.DIODES.has(str(ld["diode"])):
		ld["diode"] = "schottky"
	ld["battery_v"] = clampf(float(ld["battery_v"]), 1.0, 400.0)
	ld["resistor_ohm"] = clampf(float(ld["resistor_ohm"]), 0.05, 10000.0)
	ld["mppt_min_v"] = clampf(float(ld["mppt_min_v"]), 0.5, 400.0)
	ld["mppt_eff"] = clampf(float(ld["mppt_eff"]), 0.5, 1.0)
	s["load"] = ld
	var st := _merge(SITE_DEFAULTS, spec.get("site", {}))
	st["mean_wind_ms"] = clampf(float(st["mean_wind_ms"]), 0.5, 20.0)
	st["design_wind_ms"] = clampf(float(st["design_wind_ms"]), 1.0, 30.0)
	st["altitude_m"] = clampf(float(st["altitude_m"]), 0.0, 6000.0)
	st["roughness_m"] = clampf(float(st["roughness_m"]), 0.0002, 2.0)
	st["cut_out_ms"] = clampf(float(st["cut_out_ms"]), 0.0, 60.0)
	st["survival_ms"] = clampf(float(st["survival_ms"]), 10.0, 80.0)
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
## Through JSON's number formatting, so a spec that has been saved and read
## back (609.6 for 609.5999999999999) keeps its key.
static func key_of(spec: Dictionary) -> String:
	return str(hash(JSON.stringify(to_json_safe(spec))))


## The geometry key: the site, load and name left out, so the studio does not
## rebuild the machine when only the wind or the battery changes.
static func geometry_key(spec: Dictionary) -> String:
	var s := to_json_safe(spec)
	for k in ["site", "load", "name"]:
		s.erase(k)
	return str(hash(JSON.stringify(s)))


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

static func fmt_mm(mm: float, decimals: int = 0) -> String:
	return ("%." + str(decimals) + "f mm") % mm


static func fmt_len(mm: float) -> String:
	if mm >= 1000.0:
		return "%.2f m" % (mm * 0.001)
	return "%.0f mm" % mm


static func fmt_in(mm: float) -> String:
	return "%.2f in" % (mm / WindLabParts.IN)


static func fmt_kg(kg: float) -> String:
	if kg < 1.0:
		return "%.0f g" % (kg * 1000.0)
	return "%.2f kg" % kg if kg < 10.0 else "%.1f kg" % kg


static func describe(spec: Dictionary) -> String:
	var s := resolve(spec)
	var r: Dictionary = s["rotor"]
	var t := str(WindLabParts.type_info(s["type"])["label"])
	if WindLabParts.is_vawt(s["type"]):
		return "%s · %d blades · Ø %s × %s" % [t, int(r["blades"]), fmt_len(float(r["d_mm"])), fmt_len(float(r["h_mm"]))]
	return "%s · %d blades · Ø %s" % [t, int(r["blades"]), fmt_len(float(r["d_mm"]))]
