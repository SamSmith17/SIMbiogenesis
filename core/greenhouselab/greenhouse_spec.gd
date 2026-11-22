class_name GreenhouseSpec
extends RefCounted

## The greenhouse designer's spec (record key `greenhouse_spec`): what the
## player chose, resolved over defaults so every consumer reads a complete
## dictionary. Pure.
##
## Frame: origin on the floor at the middle of the footprint; the LENGTH runs
## along local X, the WIDTH along local Z, +Z is the front (the equator side
## at the default placement yaw: a lean-to's glazing and a dome's door face
## +Z). Heights are above the floor; `ground.sink_m` lowers the floor below
## the surrounding grade.
##
## {
##   version, name,
##   form:      "gable" | "lean_to" | "hoop" | "gothic" | "dome"
##   width_m, length_m          footprint (a dome: width = its floor diameter)
##   eave_h_m                   side-wall height (where the roof starts)
##   ridge_h_m                  the peak (a lean-to: its back wall top)
##   bay_m                      rib / truss spacing along the length
##   front_h_m                  lean-to only: the glazed front wall's height
##   dome:      {frequency, fraction}   (DomeLab geodesic, radius = width / 2)
##   glazing:   {roof, walls, ends}     GreenhouseMaterials.GLAZING ids
##   back_wall: GreenhouseMaterials.WALLS id (lean-to's opaque north wall)
##   frame:     GreenhouseMaterials.FRAMES id
##   vents:     {ridge: bool, ridge_w_m, sides: "none"|"rollup"|"louvre",
##               side_h_m, ends: bool (louvres in the end walls), end_m2}
##   fans:      {kind: FANS id, count, shutters: bool}
##   heater:    HEATERS id
##   shade:     {cloth: 0..0.8 (share of light the cloth stops), months: [ints]}
##   doors:     {count: 1|2, w_m, h_m}
##   ground:    {sink_m: floor below grade, berm: "none"|"north"|"three",
##               walls: WALLS id for the retaining walls below grade}
##   mass:      {barrels: count, litres_each, colour: "black"|"blue"}
##   rain:      {gutters: bool, cistern_l, to_barrels: bool}
##   lights:    {on: bool, ppfd: µmol/m²s at the canopy, photoperiod_h,
##               dli_target: mol/m²/day, hang_m: above the bed}
##   beds:      {layout: "auto"|"custom", style: "raised"|"ground"|"keyhole",
##               bed_w_m, path_w_m, end_clear_m, wall_h_m, crops: mix,
##               gantry: bool (FarmBot on every auto bed), lights: bool,
##               items: [bed]}  (custom beds; auto ignores them)
##     bed:     {id, kind: "rect"|"keyhole", x, z, length_m (along X),
##               width_m (along Z), keyhole: {...GrowBed keys}, crops: mix,
##               gantry: bool, lights: bool}
##     mix:     "garden" | [{crop: GardenCrops id, share}]
##   control:   {vent_open_c, vent_full_c, fan_on_c, fan_off_c, heat_on_c,
##               heat_off_c, rh_flush_pct, lights_auto: bool}
##   colors:    {frame, trim}
## }

const VERSION := 1
const KEY := "greenhouse_spec"

const FORMS := ["gable", "lean_to", "hoop", "gothic", "dome"]
const FORM_LABELS := {
	"gable": "Gable (A-frame roof)",
	"lean_to": "Lean-to (passive solar, opaque back wall)",
	"hoop": "Quonset / hoop house",
	"gothic": "Gothic arch",
	"dome": "Geodesic dome",
}
const SIDE_VENTS := ["none", "rollup", "louvre"]
const SIDE_VENT_LABELS := {"none": "No side vents", "rollup": "Roll-up sides",
	"louvre": "Louvred side vents"}
const BERMS := ["none", "north", "three"]
const BERM_LABELS := {"none": "No berm", "north": "Bermed on the back (north)",
	"three": "Bermed on three sides"}
const BED_STYLES := ["raised", "ground", "keyhole"]
const BED_STYLE_LABELS := {"raised": "Raised beds", "ground": "In-ground rows",
	"keyhole": "Keyhole rings"}
const SPECTRUMS := ["blurple", "full_spectrum"]
const SPECTRUM_LABELS := {
	"blurple": "Hydroponic red/blue LED",
	"full_spectrum": "Full spectrum white",
}
const LIGHT_SCHEDULES := ["dusk_dawn", "always", "controller"]
const LIGHT_SCHEDULE_LABELS := {
	"dusk_dawn": "Sunset to sunrise",
	"always": "Always on",
	"controller": "Controller photoperiod",
}

const MIN_W := 2.0
const MAX_W := 40.0
const MIN_L := 2.0
const MAX_L := 120.0

const DEFAULTS := {
	"form": "hoop", "width_m": 6.0, "length_m": 14.0, "eave_h_m": 1.2, "ridge_h_m": 3.6,
	"bay_m": 1.2, "front_h_m": 0.9,
	"dome": {"frequency": 4, "fraction": 0.625},
	"glazing": {"roof": "poly_double", "walls": "poly_double", "ends": "pc_twin_8"},
	"back_wall": "masonry_insulated",
	"frame": "hoop_138",
	"vents": {"ridge": false, "ridge_w_m": 0.6, "sides": "rollup", "side_h_m": 1.0, "ends": true,
		"end_m2": 0.8},
	"fans": {"kind": "fan_24", "count": 0, "shutters": true},
	"heater": "none",
	"shade": {"cloth": 0.0, "months": [6, 7, 8]},
	"doors": {"count": 2, "w_m": 1.2, "h_m": 2.0},
	"ground": {"sink_m": 0.0, "berm": "none", "walls": "masonry"},
	"mass": {"barrels": 0, "litres_each": 208.0, "colour": "black"},
	"rain": {"gutters": true, "cistern_l": 2000.0, "to_barrels": true},
	"lights": {"on": false, "spectrum": "blurple", "schedule": "dusk_dawn", "ppfd": 200.0,
		"photoperiod_h": 16.0, "dli_target": 14.0, "hang_m": 0.7},
	"beds": {"layout": "auto", "style": "raised", "bed_w_m": 1.2, "path_w_m": 0.6,
		"end_clear_m": 0.9, "wall_h_m": 0.32, "crops": "garden", "gantry": false, "lights": false,
		"feed": false, "items": []},
	"control": {"vent_open_c": 24.0, "vent_full_c": 30.0, "fan_on_c": 29.0, "fan_off_c": 26.0,
		"heat_on_c": 4.0, "heat_off_c": 7.0, "rh_flush_pct": 85.0, "lights_auto": true},
	"colors": {"frame": Color(0.72, 0.74, 0.76), "trim": Color(0.25, 0.42, 0.30)},
}


static func default_spec(form: String = "hoop") -> Dictionary:
	var s := {"form": form, "name": str(FORM_LABELS.get(form, "Greenhouse")).split(" (")[0]}
	match form:
		"gable":
			s["width_m"] = 6.0
			s["length_m"] = 12.0
			s["eave_h_m"] = 2.2
			s["ridge_h_m"] = 3.6
			s["frame"] = "alu_bar"
			s["glazing"] = {"roof": "pc_twin_8", "walls": "pc_twin_8", "ends": "pc_twin_8"}
			s["vents"] = {"ridge": true, "sides": "louvre"}
		"lean_to":
			s["width_m"] = 6.0
			s["length_m"] = 18.0
			s["eave_h_m"] = 0.9
			s["front_h_m"] = 0.9
			s["ridge_h_m"] = 3.4
			s["frame"] = "timber_2x8"
			s["glazing"] = {"roof": "pc_twin_8", "walls": "pc_twin_8", "ends": "stud"}
			s["vents"] = {"ridge": true, "sides": "rollup", "side_h_m": 0.6}
			s["mass"] = {"barrels": 12}
		"gothic":
			s["width_m"] = 9.0
			s["length_m"] = 24.0
			s["eave_h_m"] = 1.5
			s["ridge_h_m"] = 4.6
			s["frame"] = "hoop_158"
		"dome":
			s["width_m"] = 10.0
			s["length_m"] = 10.0
			s["glazing"] = {"roof": "pc_twin_6", "walls": "pc_twin_6", "ends": "pc_twin_6"}
			s["frame"] = "emt_1"
			s["vents"] = {"ridge": true, "sides": "louvre"}
			s["beds"] = {"style": "keyhole"}
			s["doors"] = {"count": 1}
	return resolve(s)


static func resolve(spec: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	s["version"] = VERSION
	var form := str(s.get("form", "hoop"))
	if not FORMS.has(form):
		form = "hoop"
	s["form"] = form
	s["name"] = str(s.get("name", "Greenhouse")).strip_edges()
	if str(s["name"]).is_empty():
		s["name"] = "Greenhouse"
	for k in ["width_m", "length_m", "eave_h_m", "ridge_h_m", "bay_m", "front_h_m", "back_wall", "frame", "heater"]:
		if not s.has(k):
			s[k] = DEFAULTS[k]
	s["width_m"] = clampf(float(s["width_m"]), MIN_W, MAX_W)
	s["length_m"] = clampf(float(s["length_m"]), MIN_L, MAX_L)
	if form == "dome":
		s["length_m"] = s["width_m"]
	s["eave_h_m"] = clampf(float(s["eave_h_m"]), 0.0, 6.0)
	s["ridge_h_m"] = clampf(float(s["ridge_h_m"]), float(s["eave_h_m"]) + 0.3, 14.0)
	s["front_h_m"] = clampf(float(s["front_h_m"]), 0.0, float(s["ridge_h_m"]) - 0.3)
	s["bay_m"] = clampf(float(s["bay_m"]), 0.6, 4.0)
	if not GreenhouseMaterials.WALLS.has(str(s["back_wall"])):
		s["back_wall"] = DEFAULTS["back_wall"]
	if not GreenhouseMaterials.FRAMES.has(str(s["frame"])):
		s["frame"] = DEFAULTS["frame"]
	if not GreenhouseMaterials.HEATERS.has(str(s["heater"])):
		s["heater"] = "none"
	for sub in ["dome", "glazing", "vents", "fans", "shade", "doors", "ground", "mass", "rain",
			"lights", "beds", "control", "colors"]:
		s[sub] = _merge(DEFAULTS[sub], s.get(sub, {}))
	var gl: Dictionary = s["glazing"]
	for k in ["roof", "walls", "ends"]:
		var gid := str(gl[k])
		# "stud" on the ends: opaque end walls (a lean-to's insulated ends).
		if gid != "stud" and not GreenhouseMaterials.GLAZING.has(gid):
			gl[k] = DEFAULTS["glazing"][k]
	var d: Dictionary = s["dome"]
	d["frequency"] = clampi(int(d["frequency"]), 2, 8)
	d["fraction"] = clampf(float(d["fraction"]), 0.375, 0.75)
	var v: Dictionary = s["vents"]
	v["ridge"] = bool(v["ridge"])
	v["ridge_w_m"] = clampf(float(v["ridge_w_m"]), 0.2, 2.0)
	if not SIDE_VENTS.has(str(v["sides"])):
		v["sides"] = "rollup"
	v["side_h_m"] = clampf(float(v["side_h_m"]), 0.2, 2.5)
	v["ends"] = bool(v["ends"])
	v["end_m2"] = clampf(float(v["end_m2"]), 0.0, 8.0)
	var f: Dictionary = s["fans"]
	if not GreenhouseMaterials.FANS.has(str(f["kind"])):
		f["kind"] = "fan_24"
	f["count"] = clampi(int(f["count"]), 0, 12)
	var sh: Dictionary = s["shade"]
	sh["cloth"] = clampf(float(sh["cloth"]), 0.0, 0.8)
	if not (sh["months"] is Array):
		sh["months"] = []
	var dr: Dictionary = s["doors"]
	dr["count"] = clampi(int(dr["count"]), 1, 2)
	dr["w_m"] = clampf(float(dr["w_m"]), 0.7, 3.0)
	dr["h_m"] = clampf(float(dr["h_m"]), 1.7, 3.0)
	var gr: Dictionary = s["ground"]
	gr["sink_m"] = clampf(float(gr["sink_m"]), 0.0, 2.5)
	if not BERMS.has(str(gr["berm"])):
		gr["berm"] = "none"
	if not GreenhouseMaterials.WALLS.has(str(gr["walls"])):
		gr["walls"] = "masonry"
	var m: Dictionary = s["mass"]
	m["barrels"] = clampi(int(m["barrels"]), 0, 400)
	m["litres_each"] = clampf(float(m["litres_each"]), 20.0, 1000.0)
	var r: Dictionary = s["rain"]
	r["gutters"] = bool(r["gutters"])
	r["cistern_l"] = clampf(float(r["cistern_l"]), 0.0, 200000.0)
	r["to_barrels"] = bool(r["to_barrels"])
	var lt: Dictionary = s["lights"]
	lt["on"] = bool(lt["on"])
	if not SPECTRUMS.has(str(lt.get("spectrum", "blurple"))):
		lt["spectrum"] = "blurple"
	else:
		lt["spectrum"] = str(lt["spectrum"])
	if not LIGHT_SCHEDULES.has(str(lt.get("schedule", "dusk_dawn"))):
		lt["schedule"] = "dusk_dawn"
	else:
		lt["schedule"] = str(lt["schedule"])
	lt["ppfd"] = clampf(float(lt["ppfd"]), 20.0, 1000.0)
	lt["photoperiod_h"] = clampf(float(lt["photoperiod_h"]), 4.0, 24.0)
	lt["dli_target"] = clampf(float(lt["dli_target"]), 2.0, 40.0)
	lt["hang_m"] = clampf(float(lt["hang_m"]), 0.2, 2.5)
	var b: Dictionary = s["beds"]
	if not ["auto", "custom"].has(str(b["layout"])):
		b["layout"] = "auto"
	if not BED_STYLES.has(str(b["style"])):
		b["style"] = "raised"
	b["bed_w_m"] = clampf(float(b["bed_w_m"]), 0.5, 3.0)
	b["path_w_m"] = clampf(float(b["path_w_m"]), 0.3, 2.0)
	b["end_clear_m"] = clampf(float(b["end_clear_m"]), 0.3, 4.0)
	b["wall_h_m"] = clampf(float(b["wall_h_m"]), 0.0, 1.0)
	b["crops"] = clean_mix(b["crops"])
	b["gantry"] = bool(b["gantry"])
	b["lights"] = bool(b["lights"])
	b["feed"] = bool(b.get("feed", false))
	var items: Array = []
	if b["items"] is Array:
		for it in b["items"]:
			if it is Dictionary:
				items.append(_resolve_bed(it as Dictionary, items.size()))
	b["items"] = items
	var c: Dictionary = s["control"]
	for k in ["vent_open_c", "vent_full_c", "fan_on_c", "fan_off_c", "heat_on_c", "heat_off_c", "rh_flush_pct"]:
		c[k] = float(c[k])
	c["vent_full_c"] = maxf(float(c["vent_full_c"]), float(c["vent_open_c"]) + 0.5)
	c["fan_off_c"] = minf(float(c["fan_off_c"]), float(c["fan_on_c"]) - 0.5)
	c["heat_off_c"] = maxf(float(c["heat_off_c"]), float(c["heat_on_c"]) + 0.5)
	c["lights_auto"] = bool(c["lights_auto"])
	var cols: Dictionary = s["colors"]
	for k in DEFAULTS["colors"]:
		cols[k] = _color(cols.get(k), DEFAULTS["colors"][k])
	if spec.get("model_lights") is Array:
		s["model_lights"] = (spec["model_lights"] as Array).duplicate(true)
	return s


static func _resolve_bed(b: Dictionary, idx: int) -> Dictionary:
	var o := b.duplicate(true)
	o["id"] = str(o.get("id", "b%d" % (idx + 1)))
	o["kind"] = "keyhole" if str(o.get("kind", "rect")) == "keyhole" else "rect"
	o["x"] = float(o.get("x", 0.0))
	o["z"] = float(o.get("z", 0.0))
	o["length_m"] = clampf(float(o.get("length_m", 3.0)), 0.4, 60.0)
	o["width_m"] = clampf(float(o.get("width_m", 1.2)), 0.3, 6.0)
	o["crops"] = clean_mix(o.get("crops", "garden"))
	o["gantry"] = bool(o.get("gantry", false))
	o["lights"] = bool(o.get("lights", false))
	if o["kind"] == "keyhole":
		var k: Dictionary = GrowBed.KEYHOLE_DEFAULTS.duplicate()
		var ok: Variant = o.get("keyhole", {})
		if ok is Dictionary:
			for kk in (ok as Dictionary):
				k[kk] = (ok as Dictionary)[kk]
		o["keyhole"] = k
	return o


## A crop mix: "garden", or [{crop, share}] with known crops and shares
## summing to 1. Anything else falls back to "garden".
static func clean_mix(v: Variant) -> Variant:
	if v is String:
		var sv := str(v)
		if sv == "garden":
			return "garden"
		if GardenCrops.CROPS.has(sv):
			return [{"crop": sv, "share": 1.0}]
		return "garden"
	if not (v is Array):
		return "garden"
	var out: Array = []
	var tot := 0.0
	for e in v:
		if e is Dictionary and GardenCrops.CROPS.has(str((e as Dictionary).get("crop", ""))):
			var sh := maxf(float((e as Dictionary).get("share", 1.0)), 0.0)
			if sh > 0.0:
				out.append({"crop": str(e["crop"]), "share": sh})
				tot += sh
		elif e is String and GardenCrops.CROPS.has(str(e)):
			out.append({"crop": str(e), "share": 1.0})
			tot += 1.0
	if out.is_empty() or tot <= 0.0:
		return "garden"
	for e in out:
		e["share"] = float(e["share"]) / tot
	return out


## The crop ids of a mix in order ("garden" = GardenCrops' bed rotation).
static func mix_crops(mix: Variant) -> Array:
	if mix is Array:
		var out: Array = []
		for e in mix:
			out.append(str((e as Dictionary)["crop"]))
		return out
	return (GardenCrops.GARDEN_BEDS as Array).duplicate()


## The spec with every Color as [r, g, b, a], so it survives JSON.
static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var cols := {}
	for k in s["colors"]:
		var c: Color = s["colors"][k]
		cols[k] = [c.r, c.g, c.b, c.a]
	s["colors"] = cols
	return s


## The part of the spec that changes the geometry / physics (cache key).
static func key_of(spec: Dictionary) -> String:
	var s := to_json_safe(spec)
	s.erase("name")
	s.erase("model_lights")
	return str(hash(JSON.stringify(_rounded(s))))


static func _rounded(v: Variant) -> Variant:
	if v is float:
		var f := snappedf(float(v), 0.0001)
		return int(f) if is_equal_approx(f, roundf(f)) else f
	if v is Dictionary:
		var o := {}
		var ks: Array = (v as Dictionary).keys()
		ks.sort()
		for k in ks:
			o[k] = _rounded((v as Dictionary)[k])
		return o
	if v is Array:
		var a: Array = []
		for e in v:
			a.append(_rounded(e))
		return a
	return v


static func _merge(base: Dictionary, over: Variant) -> Dictionary:
	var out := base.duplicate(true)
	if over is Dictionary:
		for k in (over as Dictionary):
			out[k] = (over as Dictionary)[k]
	return out


static func _color(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	if v is String and Color.html_is_valid(str(v)):
		return Color.html(str(v))
	return fallback
