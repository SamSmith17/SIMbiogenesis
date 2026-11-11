class_name FarmBotSpec
extends RefCounted

## A FarmBot-style garden robot: a gantry on two tracks along a raised bed,
## a cross-slide across it, a Z axis with a universal tool mount, a tool bay,
## and the crops it plants, waters, weeds and photographs. A spec is a
## Dictionary (JSON-safe), the record key `farmbot_spec` on a placed prop.
##
## Units: metres for the bed and the frame, mm and mm/s for the machine (its
## own coordinates: X along the tracks from the bed's -X end, Y across the bed
## from its -Z side, Z down from the top of the Z axis' travel, negative).
##
## Numbers with a source:
##  - Genesis 1.5 x 3 m, Genesis XL 3 x 6 m (18 m²): farm.bot / genesis.farm.bot.
##  - Four NEMA 17 steppers with rotary encoders (two on X, one on Y, one on
##    Z), a Farmduino and a Raspberry Pi: the v1.8 / v1.9 spec sheets.
##  - Speeds are FarmBot OS's default hardware parameters as published in its
##    web app: 400 steps/s top, 50 steps/s start, a 300-step ramp, 5 steps/mm
##    on X and Y (GT2 belts), 25 on Z (lead screw): 80 / 10 mm/s and a 60 mm
##    ramp on X and Y, 16 / 2 mm/s and a 12 mm ramp on Z. Editable.
##  - Kit prices: FarmBot's own assembly docs give about $3,500 (Genesis) and
##    $4,500 (XL) without infrastructure; v1.7 listed at $2,995 / $4,395 and
##    recent listings run higher, so the price is the player's to set.
## Everything else (watering flow, labour rates) is an estimate, said so where
## it is defined (FarmBotEconomics).

const KINDS := ["linear", "radial"]
const KIND_LABELS := {"linear": "Linear gantry (raised bed)", "radial": "Radial arm (keyhole bed)"}
const SWEEPS := ["slot", "full"]
const BED_WALLS := ["concrete", "galvanized", "timber"]
const PACKINGS := ["hex", "square"]
const LAYOUTS := ["rows", "blocks", "interleave"]
const TOOLS := ["seeder", "watering", "weeder", "soil_sensor", "rotary"]
const TOOL_LABELS := {"seeder": "Seed injector", "watering": "Watering nozzle", "weeder": "Weeder",
	"soil_sensor": "Soil sensor", "rotary": "Rotary tool"}

## The FarmBot price model fitted to the two docs prices: base electronics,
## motors and tools, plus track per metre of length (both sides) and gantry
## per metre of width. Genesis (3 x 1.5) = 3,500, XL (6 x 3) = 4,500.
const PRICE_BASE_USD := 2500.0
const PRICE_PER_M_LENGTH := 250.0
const PRICE_PER_M_WIDTH := 167.0
## The gantry's beam is an extrusion spanning the bed: past this it sags and
## the cross-slide rocks (the XL's width is the largest FarmBot sells).
const MAX_WIDTH_M := 3.0
## Belts and the cable carrier run the whole track: past this a single run is
## long for one GT2 belt and one cable chain.
const LONG_TRACK_M := 12.0
## The radial arm's price (estimates): a light aluminium truss a metre, the
## curved rail on the outer wall a metre (flat bar rolled to the radius,
## brackets), plus the pivot bearing and the outer wheel's drive.
const PRICE_ARM_PER_M := 180.0
const PRICE_RAIL_PER_M := 35.0
const PRICE_PIVOT_USD := 450.0
## Every arm past the first: its own truss, carriage, motors, controller,
## camera and set of tools (estimate).
const PRICE_EXTRA_ARM_USD := 1800.0
## Past this the arm is a long truss (FarmBot's own beam is 3 m).
const LONG_ARM_M := 6.0
const MAX_ARM_M := 12.0

const DEFAULTS := {
	"name": "FarmBot Genesis XL",
	"kind": "linear",
	## The radial robot's keyhole bed (GrowBed's keyhole keys; `sweep` "slot"
	## = the rail stops either side of the slot, "full" = it bridges it).
	"keyhole": {"outer_r": 9.5, "ring_w": 1.2, "path_w": 0.6, "rings": 5, "slot_w": 1.0, "centre_r": 1.1,
		"wall_h": 0.42, "sweep": "slot", "arms": 1},
	"bed": {"length_m": 6.0, "width_m": 3.0, "wall": "concrete", "wall_h_m": 0.42},
	"gantry": {"clearance_m": 0.9, "z_travel_mm": 500.0, "soil_z_mm": -420.0},
	"motion": {"xy_max_mm_s": 80.0, "xy_min_mm_s": 10.0, "xy_ramp_mm": 60.0,
		"z_max_mm_s": 16.0, "z_min_mm_s": 2.0, "z_ramp_mm": 12.0},
	"tools": {"seeder": true, "watering": true, "weeder": true, "soil_sensor": true, "rotary": false},
	"crops": {"mix": [{"crop": "lettuce", "share": 0.3}, {"crop": "carrot", "share": 0.2},
		{"crop": "chard", "share": 0.15}, {"crop": "onion", "share": 0.15}, {"crop": "pepper_red", "share": 0.1},
		{"crop": "basil", "share": 0.1}],
		"packing": "hex", "spacing_scale": 1.0, "layout": "rows", "section_m": 1.0},
	"care": {"water_mm_day": 4.0, "water_times": [7.0, 18.0], "flow_l_min": 3.0,
		"weed_every_days": 2, "photo_every_days": 1, "soil_every_days": 1, "seed_hour": 9.5,
		"weed_hour": 13.0, "photo_hour": 12.0},
	"cost": {"kit_usd": -1.0, "bed_usd_m2": 45.0, "labor_usd_h": 20.0, "electricity_usd_kwh": 0.15,
		"lifetime_years": 8.0, "parts_usd_year": 60.0, "upkeep_h_year": 16.0, "assembly_h": 3.0},
}


static func default_spec() -> Dictionary:
	return (DEFAULTS as Dictionary).duplicate(true)


## A full spec from any partial one: every key present and clamped.
static func resolve(s: Dictionary) -> Dictionary:
	var out := default_spec()
	for k in s.keys():
		if out.has(k) and out[k] is Dictionary and s[k] is Dictionary:
			for k2 in (s[k] as Dictionary).keys():
				(out[k] as Dictionary)[k2] = (s[k] as Dictionary)[k2]
		else:
			out[k] = s[k]
	if not (str(out.get("kind", "linear")) in KINDS):
		out["kind"] = "linear"
	var kh: Dictionary = out["keyhole"]
	kh["outer_r"] = clampf(float(kh["outer_r"]), 2.0, 15.0)
	kh["ring_w"] = clampf(float(kh["ring_w"]), 0.4, 3.0)
	kh["path_w"] = clampf(float(kh["path_w"]), 0.3, 2.0)
	kh["rings"] = clampi(int(kh["rings"]), 1, 12)
	kh["slot_w"] = clampf(float(kh["slot_w"]), 0.4, 3.0)
	kh["centre_r"] = clampf(float(kh["centre_r"]), 0.5, 4.0)
	kh["wall_h"] = clampf(float(kh["wall_h"]), 0.1, 1.0)
	kh["arms"] = clampi(int(kh.get("arms", 1)), 1, 4)
	if not (str(kh["sweep"]) in SWEEPS):
		kh["sweep"] = "slot"
	var b: Dictionary = out["bed"]
	if str(out["kind"]) == "radial":
		# The keyhole bed sets the bed's box and its height.
		b["length_m"] = 2.0 * float(kh["outer_r"])
		b["width_m"] = 2.0 * float(kh["outer_r"])
		b["wall_h_m"] = float(kh["wall_h"])
		b["wall"] = "galvanized"
	b["length_m"] = clampf(float(b["length_m"]), 1.0, 60.0)
	b["width_m"] = clampf(float(b["width_m"]), 0.6, 30.0 if str(out["kind"]) == "radial" else 6.0)
	b["wall_h_m"] = clampf(float(b["wall_h_m"]), 0.1, 1.0)
	if not (str(b["wall"]) in BED_WALLS):
		b["wall"] = "concrete"
	var g: Dictionary = out["gantry"]
	g["clearance_m"] = clampf(float(g["clearance_m"]), 0.3, 2.5)
	g["z_travel_mm"] = clampf(float(g["z_travel_mm"]), 150.0, 1500.0)
	g["soil_z_mm"] = clampf(float(g["soil_z_mm"]), -float(g["z_travel_mm"]), -50.0)
	var m: Dictionary = out["motion"]
	for k3 in m.keys():
		m[k3] = maxf(float(m[k3]), 0.1)
	m["xy_min_mm_s"] = minf(float(m["xy_min_mm_s"]), float(m["xy_max_mm_s"]))
	m["z_min_mm_s"] = minf(float(m["z_min_mm_s"]), float(m["z_max_mm_s"]))
	var tl: Dictionary = out["tools"]
	for t in TOOLS:
		tl[t] = bool(tl.get(t, false))
	var c: Dictionary = out["crops"]
	var mix: Array = []
	for e in (c.get("mix", []) as Array):
		if e is Dictionary and GardenCrops.CROPS.has(str((e as Dictionary).get("crop", ""))):
			mix.append({"crop": str(e["crop"]), "share": maxf(float(e.get("share", 0.0)), 0.0)})
	if mix.is_empty():
		mix = [{"crop": "lettuce", "share": 1.0}]
	c["mix"] = mix
	if not (str(c["packing"]) in PACKINGS):
		c["packing"] = "hex"
	if not (str(c["layout"]) in LAYOUTS):
		c["layout"] = "rows"
	c["spacing_scale"] = clampf(float(c["spacing_scale"]), 0.6, 2.5)
	c["section_m"] = clampf(float(c["section_m"]), 0.3, 6.0)
	var cr: Dictionary = out["care"]
	cr["water_mm_day"] = clampf(float(cr["water_mm_day"]), 0.0, 15.0)
	cr["flow_l_min"] = clampf(float(cr["flow_l_min"]), 0.2, 20.0)
	var times: Array = []
	for h in (cr.get("water_times", []) as Array):
		times.append(clampf(float(h), 0.0, 23.9))
	times.sort()
	cr["water_times"] = times
	for k4 in ["weed_every_days", "photo_every_days", "soil_every_days"]:
		cr[k4] = clampi(int(cr[k4]), 0, 30)
	for k5 in ["seed_hour", "weed_hour", "photo_hour"]:
		cr[k5] = clampf(float(cr[k5]), 0.0, 23.9)
	var co: Dictionary = out["cost"]
	for k6 in co.keys():
		co[k6] = float(co[k6])
	co["lifetime_years"] = maxf(float(co["lifetime_years"]), 1.0)
	out["name"] = str(out.get("name", "FarmBot"))
	return out


## The kit's price: the player's, or the fitted model (-1 = fitted).
static func kit_price_usd(s: Dictionary) -> float:
	var co: Dictionary = s["cost"]
	if float(co.get("kit_usd", -1.0)) >= 0.0:
		return float(co["kit_usd"])
	if FarmBotGeom.is_radial(s):
		var sw := FarmBotGeom.sweep(s)
		var rr := FarmBotGeom.rail_r(s)
		var na := float(FarmBotGeom.arm_count(s))
		return PRICE_BASE_USD + PRICE_PIVOT_USD + PRICE_ARM_PER_M * rr * na + PRICE_RAIL_PER_M * sw.y * rr \
			+ PRICE_EXTRA_ARM_USD * (na - 1.0)
	var b: Dictionary = s["bed"]
	return PRICE_BASE_USD + PRICE_PER_M_LENGTH * float(b["length_m"]) + PRICE_PER_M_WIDTH * float(b["width_m"])


## Bed area, m².
static func area_m2(s: Dictionary) -> float:
	return FarmBotGeom.area_m2(s)


## A stable key for caches (JSON of the resolved spec, rounded).
static func key_of(s: Dictionary) -> String:
	return str(hash(JSON.stringify(resolve(s))))


## JSON-safe copy (the record holds plain data).
static func to_json_safe(s: Dictionary) -> Dictionary:
	var parsed: Variant = JSON.parse_string(JSON.stringify(s))
	return parsed as Dictionary if parsed is Dictionary else {}
