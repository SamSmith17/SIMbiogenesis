class_name TcParts
extends RefCounted

## The TC designer's part catalogue: every part type's palette entry, its
## parameters (FormRow-ready), and `build(type, size, params)` →
## {geo (TcGeom, mm), ports, capsules, mass_kg, volume_l, label,
## designation, bounds}. Built parts are cached by their key, so an
## assembly of fifty 1½" elbows builds one.
##
## Part frames (mm): the first port sits at the origin facing −Z for the
## straight families; elbows and tees put the centre-line corner at the
## origin. A port is {id, kind, size, pos, z (out of the part), x (roll
## reference)}; `port_xform` turns one into a Transform3D. Kinds: "tc"
## (clamp face — mates with a tc of the same clamp class), "weld" (a tube
## end), "npt_m" / "npt_f" (mate male to female, same size), "barb".
##
## Dimensions come from TcStandards (sourced or flagged estimates).

const CATEGORIES := [
	["vessels", "Vessels & tanks", "package"],
	["ferrules", "Ferrules & caps", "target"],
	["tube", "Tube & bends", "route"],
	["tees", "Tees & crosses", "workflow"],
	["reducers", "Reducers & adapters", "minimize-2"],
	["valves", "Valves", "sliders-horizontal"],
	["actuators", "Actuators", "cpu"],
	["instruments", "Sight & instruments", "gauge"],
	["columns", "Condensers & columns", "layers"],
	["filters", "Filters & strainers", "droplet"],
	["brewing", "Brewing & process", "flame"],
	["process", "Process units", "zap"],
]

## type → {label, category, short (palette text), sizes ("tc" = the TC
## sizes), designation, why}.
const TYPES := {
	"spool":        {"label": "Spool", "category": "tube", "designation": "TC × TC spool",
		"why": "A straight tube with a clamp ferrule at each end. Tick Fit length to let a closed loop set it."},
	"elbow90":      {"label": "90° elbow", "category": "tube", "designation": "2CMP 90° elbow",
		"why": "Clamp × clamp 90° elbow (centre-to-face from the 2CMP table)."},
	"elbow45":      {"label": "45° elbow", "category": "tube", "designation": "2KMP 45° elbow",
		"why": "Clamp × clamp 45° elbow, on the 90° elbow's bend radius."},
	"bend":         {"label": "Bend (any angle)", "category": "tube", "designation": "TC × TC bend",
		"why": "A tube bend at any angle and radius between two clamp ends."},
	"tee":          {"label": "Tee", "category": "tees", "designation": "7MP tee",
		"why": "Equal clamp tee (centre-to-face from the 7MP table)."},
	"reducing_tee": {"label": "Reducing tee", "category": "tees", "designation": "7RMP reducing tee",
		"why": "A tee whose branch is a smaller size than its run."},
	"cross":        {"label": "Cross", "category": "tees", "designation": "9MP cross",
		"why": "Four equal clamp ends in one plane."},
	"lateral":      {"label": "45° lateral (wye)", "category": "tees", "designation": "28MP-style lateral",
		"why": "A branch joining the run at 45°, for flow that should not turn hard."},
	"ferrule":      {"label": "Weld ferrule", "category": "ferrules", "designation": "14WMP weld ferrule",
		"why": "A clamp face on a short tube stub, for welding onto a vessel or a pipe."},
	"cap":          {"label": "End cap", "category": "ferrules", "designation": "16AMP end cap",
		"why": "A blind clamp cap that closes a port."},
	"cap_npt":      {"label": "Cap, female NPT", "category": "ferrules", "designation": "TC cap × FNPT",
		"why": "An end cap with a female pipe thread in the middle (a thermometer, a valve, a fitting)."},
	"reducing_cap": {"label": "Flat reducing cap", "category": "reducers", "designation": "TC × TC flat reducer",
		"why": "A clamp cap carrying a smaller clamp end on a short stub (like ½\" on a 1½\" cap)."},
	"reducer":      {"label": "Concentric reducer", "category": "reducers", "designation": "31MP concentric reducer",
		"why": "A cone between two clamp sizes."},
	"tc_npt_m":     {"label": "TC × male NPT", "category": "reducers", "designation": "TC × MNPT adapter",
		"why": "A clamp face on one end, a male pipe thread on the other."},
	"tc_barb":      {"label": "TC × hose barb", "category": "reducers", "designation": "TC × hose barb",
		"why": "A clamp face to a hose barb (silicone or PVC hose)."},
	"vessel":       {"label": "Vessel / tank", "category": "vessels", "designation": "Fabricated vessel",
		"why": "A kettle, boiler, fermenter or tank: shell, heads, lid, jacket, legs and nozzles you drag round it."},
	"butterfly":    {"label": "Butterfly valve", "category": "valves", "designation": "Clamp butterfly valve",
		"why": "A wafer butterfly valve between two clamp faces; quarter turn, full bore."},
	"ball_valve":   {"label": "Ball valve", "category": "valves", "designation": "Clamp ball valve",
		"why": "A 2-way ball valve with clamp ends; quarter turn."},
	"ball_valve_3way": {"label": "3-way ball valve", "category": "valves", "designation": "Clamp 3-way L-port ball valve",
		"why": "Diverts the flow to one of two outlets."},
	"check_valve":  {"label": "Check valve", "category": "valves", "designation": "Clamp check valve",
		"why": "Lets the flow through one way only (the arrow, a to b)."},
	"diaphragm_valve": {"label": "Diaphragm valve", "category": "valves", "designation": "Clamp diaphragm valve",
		"why": "A throttling valve with no crevice in the flow, for clean service."},
	"relief_valve": {"label": "Pressure relief valve", "category": "valves", "designation": "Clamp safety relief valve",
		"why": "Opens at its set pressure and vents through the side thread. Every closed pressure vessel needs one."},
	"actuator_pneumatic": {"label": "Pneumatic actuator", "category": "actuators", "designation": "Rack & pinion pneumatic actuator",
		"why": "Mounts on a valve's stem (untick the valve's handle); two quarter-inch air ports."},
	"actuator_electric": {"label": "Electric actuator", "category": "actuators", "designation": "Quarter-turn electric actuator",
		"why": "Mounts on a valve's stem (untick the valve's handle) for automation."},
	"sight_glass":  {"label": "Sight glass", "category": "instruments", "designation": "Clamp tubular sight glass",
		"why": "A glass tube between two collars and four tie rods, to see the flow."},
	"thermometer":  {"label": "Dial thermometer", "category": "instruments", "designation": "Bimetal dial thermometer",
		"why": "A 3-inch dial with its probe into the line, on a clamp cap or a male thread."},
	"gauge":        {"label": "Pressure gauge", "category": "instruments", "designation": "Bourdon pressure gauge",
		"why": "A 2.5-inch dial gauge, on a clamp cap or a male thread."},
	"thermowell":   {"label": "Thermowell", "category": "instruments", "designation": "Clamp-cap thermowell",
		"why": "A closed tube into the line for a probe (half-inch FNPT on top)."},
	"dephlegmator": {"label": "Dephlegmator / condenser", "category": "columns", "designation": "Jacketed condenser",
		"why": "The product tube runs through a water jacket with two half-inch NPT water bosses (Liebig / dephlegmator)."},
	"column":       {"label": "Column section", "category": "columns", "designation": "Packed column section",
		"why": "A column section, packed with copper mesh or rings, with an optional glass window."},
	"bubble_plate": {"label": "Bubble plate", "category": "columns", "designation": "Glass bubble-cap plate section",
		"why": "One plate of a plated column: a perforated plate with bubble caps and a downcomer."},
	"inline_strainer": {"label": "Inline strainer", "category": "filters", "designation": "Clamp inline strainer",
		"why": "A screen in a short housing between two clamp ends."},
	"y_strainer":   {"label": "Y strainer", "category": "filters", "designation": "Clamp Y strainer",
		"why": "A screen in a leg off the run, cleaned through its cap."},
	"cartridge_housing": {"label": "Cartridge filter housing", "category": "filters", "designation": "Clamp cartridge filter housing",
		"why": "Inlet and outlet in the head, the cartridge in a bowl below, a drain at the bottom."},
	"strainer_basket": {"label": "Strainer basket (wort / hops)", "category": "brewing", "designation": "Clamp-mounted strainer basket",
		"why": "A mesh basket hung through a clamp port into the vessel."},
	"funnel":       {"label": "Funnel / hopper", "category": "brewing", "designation": "Clamp funnel",
		"why": "A cone up from a clamp end, for filling."},
	"spray_ball":   {"label": "Spray ball", "category": "brewing", "designation": "Clamp CIP spray ball",
		"why": "A cleaning spray ball through a top port."},
	"heating_element": {"label": "Heating element", "category": "brewing", "designation": "Clamp immersion heating element",
		"why": "An immersion element on a clamp face; its loops reach into the vessel."},
	"gas_holder":   {"label": "Gas holder", "category": "process", "designation": "Water-sealed bell gas holder",
		"why": "Stores the gas at a low, steady pressure: the bell rises as gas comes in. Its level tells a genset when to run."},
	"dryer":        {"label": "Gas dryer", "category": "process", "designation": "Packed desiccant drying column",
		"why": "Silica gel (or activated carbon) takes the water vapour out of the gas until it is spent."},
	"genset":       {"label": "Gas genset (48 V DC)", "category": "process", "designation": "Gas engine generator, 48 V DC",
		"why": "Burns the gas and charges a battery: its power is the gas's heating value times its efficiency."},
	"flare":        {"label": "Flare", "category": "process", "designation": "Flare stack with flame arrestor",
		"why": "Burns off gas nobody can use, so it is not vented raw."},
}

const TYPE_ORDER := ["vessel", "spool", "elbow90", "elbow45", "bend", "tee", "reducing_tee", "cross", "lateral",
	"ferrule", "cap", "cap_npt", "reducing_cap", "reducer", "tc_npt_m", "tc_barb",
	"butterfly", "ball_valve", "ball_valve_3way", "check_valve", "diaphragm_valve", "relief_valve",
	"actuator_pneumatic", "actuator_electric", "sight_glass", "thermometer", "gauge", "thermowell",
	"dephlegmator", "column", "bubble_plate", "inline_strainer", "y_strainer", "cartridge_housing",
	"strainer_basket", "funnel", "spray_ball", "heating_element", "gas_holder", "dryer", "genset", "flare"]

const MOUNTS := [["tc", "Clamp cap"], ["npt", "Male NPT"]]
const PACKINGS := [["copper_mesh", "Copper mesh"], ["raschig", "Ceramic rings"], ["none", "None"]]

const STEEL := "steel"

static var _cache: Dictionary = {}


# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

## The parameter rows a type shows: [{key, label, kind (float|bool|size|
## npt|barb), unit, min, max, step, tip}].
static func _fl(key: String, lab: String, mn: float, mx: float, st: float, tip: String = "") -> Dictionary:
	return {"key": key, "label": lab, "kind": "float", "unit": "mm", "min": mn, "max": mx, "step": st, "tip": tip}


static func _bl(key: String, lab: String, tip: String = "") -> Dictionary:
	return {"key": key, "label": lab, "kind": "bool", "tip": tip}


static func param_specs(type: String) -> Array:
	match type:
		"elbow90", "tee":
			return [_bl("short", "Short pattern", "Short (cast-style) fitting: a tighter centre-to-face (an estimate: no table fetched)")]
		"butterfly", "ball_valve", "ball_valve_3way":
			return [_bl("open", "Open", "Shown open (display only)"), _bl("manual", "Handle", "Untick when an actuator drives it")]
		"diaphragm_valve":
			return [_bl("manual", "Handwheel", "Untick when an actuator drives it")]
		"thermometer":
			return [{"key": "mount", "label": "Mount", "kind": "choice", "options": MOUNTS},
				{"key": "npt", "label": "Thread", "kind": "npt"}, _fl("probe_mm", "Probe", 20.0, 600.0, 5.0)]
		"gauge":
			return [{"key": "mount", "label": "Mount", "kind": "choice", "options": MOUNTS}, {"key": "npt", "label": "Thread", "kind": "npt"}]
		"sight_glass", "thermowell":
			return [_fl("length_mm", "Length", 40.0, 1000.0, 5.0)]
		"dephlegmator":
			return [_fl("length_mm", "Length", 120.0, 2000.0, 1.0, "Face to face"),
				{"key": "shell", "label": "Jacket size", "kind": "size", "tip": "The water jacket's tube size"}]
		"column":
			return [_fl("length_mm", "Length", 60.0, 2000.0, 5.0), _bl("window", "Glass window"),
				{"key": "packing", "label": "Packing", "kind": "choice", "options": PACKINGS}]
		"cartridge_housing":
			return [_fl("element_mm", "Cartridge", 100.0, 1000.0, 1.0, "Cartridge length (10 in = 254 mm)")]
		"strainer_basket":
			return [_fl("depth_mm", "Depth", 40.0, 800.0, 5.0)]
		"funnel":
			return [_fl("rim_mm", "Rim diameter", 60.0, 1200.0, 5.0), _fl("height_mm", "Height", 30.0, 1000.0, 5.0)]
		"heating_element":
			return [_fl("length_mm", "Reach", 60.0, 1000.0, 5.0, "How far the loops reach into the vessel")]
		"gas_holder":
			return [{"key": "volume_l", "label": "Capacity", "kind": "float", "unit": "L", "min": 20.0, "max": 20000.0, "step": 10.0},
				{"key": "hold_kpa", "label": "Holds at", "kind": "float", "unit": "kPa", "min": 0.1, "max": 10.0, "step": 0.1,
					"tip": "The bell's weight: the gauge pressure it keeps the gas at"}]
		"dryer":
			return [_fl("length_mm", "Length", 150.0, 2000.0, 5.0), {"key": "packing", "label": "Packing", "kind": "choice", "options": TcUnits.PACKINGS}]
		"genset":
			return [{"key": "rated_kw", "label": "Rating", "kind": "float", "unit": "kW", "min": 0.3, "max": 30.0, "step": 0.1},
				{"key": "efficiency", "label": "Efficiency", "kind": "float", "unit": "", "min": 0.05, "max": 0.45, "step": 0.01,
					"tip": "Gas heating value to DC electricity (small gas engines 18–28 %)"}]
		"flare":
			return [_fl("height_mm", "Stack height", 300.0, 4000.0, 10.0)]
		"spool":
			return [{"key": "length_mm", "label": "Length", "kind": "float", "unit": "mm", "min": 20.0, "max": 3000.0, "step": 1.0,
					"tip": "Face to face"},
				{"key": "fit", "label": "Fit length", "kind": "bool",
					"tip": "Let a closed loop solve this spool's length"}]
		"bend":
			return [{"key": "angle_deg", "label": "Angle", "kind": "float", "unit": "°", "min": 5.0, "max": 180.0, "step": 1.0},
				{"key": "radius_mm", "label": "Bend radius", "kind": "float", "unit": "mm", "min": 0.0, "max": 1000.0, "step": 1.0,
					"tip": "Centre-line radius; 0 = the 90° elbow's radius"}]
		"ferrule":
			return [{"key": "long", "label": "Long ferrule", "kind": "bool", "tip": "Long (14AMP-style) hub"}]
		"cap_npt":
			return [{"key": "npt", "label": "Thread", "kind": "npt"}]
		"tc_npt_m":
			return [{"key": "npt", "label": "Thread", "kind": "npt"}]
		"tc_barb":
			return [{"key": "barb", "label": "Hose ID", "kind": "barb"}]
		"reducing_cap", "reducer":
			return [{"key": "small", "label": "Small end", "kind": "size"}]
		"reducing_tee":
			return [{"key": "branch", "label": "Branch size", "kind": "size"}]
	return []


static func default_params(type: String, size: String) -> Dictionary:
	match type:
		"vessel":
			var v := TcVessel.defaults()
			v["ports"] = [{"id": "n1", "kind": "tc", "size": "2", "face": "lid", "angle_deg": 0.0, "r_mm": 0.0, "stub_mm": 40.0},
				{"id": "n2", "kind": "tc", "size": "1.5", "face": "shell", "angle_deg": 180.0, "h_mm": 50.0, "stub_mm": 40.0}]
			return v
		"elbow90", "tee":
			return {"short": false}
		"butterfly", "ball_valve", "ball_valve_3way":
			return {"open": true, "manual": true}
		"diaphragm_valve":
			return {"manual": true}
		"thermometer":
			return {"mount": "tc", "npt": "0.5", "probe_mm": 100.0}
		"gauge":
			return {"mount": "tc", "npt": "0.25"}
		"sight_glass":
			return {"length_mm": 150.0}
		"thermowell":
			return {"length_mm": 150.0}
		"dephlegmator":
			return {"length_mm": 457.2, "shell": _next_bigger(size)}
		"column":
			return {"length_mm": 300.0, "window": true, "packing": "copper_mesh"}
		"cartridge_housing":
			return {"element_mm": 254.0}
		"strainer_basket":
			return {"depth_mm": 200.0}
		"funnel":
			return {"rim_mm": 300.0, "height_mm": 200.0}
		"heating_element":
			return {"length_mm": 300.0}
		"gas_holder":
			return {"volume_l": 300.0, "hold_kpa": 0.8}
		"dryer":
			return {"length_mm": 450.0, "packing": "silica"}
		"genset":
			return {"rated_kw": 2.5, "efficiency": 0.22}
		"flare":
			return {"height_mm": 1500.0}
		"spool":
			return {"length_mm": 152.4, "fit": false}
		"bend":
			return {"angle_deg": 30.0, "radius_mm": 0.0}
		"ferrule":
			return {"long": false}
		"cap_npt", "tc_npt_m":
			return {"npt": "0.5"}
		"tc_barb":
			return {"barb": "0.5"}
		"reducing_cap":
			return {"small": "0.5"}
		"reducer":
			return {"small": _next_smaller(size)}
		"reducing_tee":
			return {"branch": _next_smaller(size)}
	return {}


static func _next_bigger(size: String) -> String:
	var i := TcStandards.SIZES.find(size)
	return str(TcStandards.SIZES[mini(i + 1, TcStandards.SIZES.size() - 1)])


static func _next_smaller(size: String) -> String:
	var i := TcStandards.SIZES.find(size)
	return str(TcStandards.SIZES[maxi(i - 1, 0)])


static func resolve_params(type: String, size: String, params: Dictionary) -> Dictionary:
	if type == "vessel":
		return TcVessel.resolve(params if not params.is_empty() else default_params(type, size))
	var p := default_params(type, size)
	for k in params:
		p[k] = params[k]
	match type:
		"spool":
			p["length_mm"] = clampf(float(p["length_mm"]), 10.0, 6000.0)
			p["fit"] = bool(p.get("fit", false))
		"bend":
			p["angle_deg"] = clampf(float(p["angle_deg"]), 1.0, 180.0)
			p["radius_mm"] = maxf(float(p["radius_mm"]), 0.0)
		"reducer", "reducing_cap":
			var s := str(p.get("small", "0.5"))
			if not TcStandards.has_size(s) or TcStandards.SIZES.find(s) >= TcStandards.SIZES.find(size):
				s = _next_smaller(size)
			p["small"] = s
		"reducing_tee":
			var b := str(p.get("branch", "0.5"))
			if not TcStandards.has_size(b) or TcStandards.SIZES.find(b) > TcStandards.SIZES.find(size):
				b = _next_smaller(size)
			p["branch"] = b
		"cap_npt", "tc_npt_m":
			if not TcStandards.NPT_OD.has(str(p["npt"])):
				p["npt"] = "0.5"
		"tc_barb":
			if not str(p["barb"]) in TcStandards.BARB_SIZES:
				p["barb"] = "0.5"
		"thermometer", "gauge":
			if not str(p["mount"]) in ["tc", "npt"]:
				p["mount"] = "tc"
			if not TcStandards.NPT_OD.has(str(p["npt"])):
				p["npt"] = "0.5"
		"dephlegmator":
			p["length_mm"] = clampf(float(p["length_mm"]), 120.0, 3000.0)
			if not TcStandards.has_size(str(p["shell"])):
				p["shell"] = _next_bigger(size)
		"column":
			p["length_mm"] = clampf(float(p["length_mm"]), 60.0, 3000.0)
			if not str(p["packing"]) in ["copper_mesh", "raschig", "none"]:
				p["packing"] = "none"
		"gas_holder":
			p["volume_l"] = clampf(float(p["volume_l"]), 20.0, 20000.0)
			p["hold_kpa"] = clampf(float(p["hold_kpa"]), 0.1, 10.0)
		"dryer":
			p["length_mm"] = clampf(float(p["length_mm"]), 150.0, 2000.0)
			if not str(p["packing"]) in ["silica", "carbon"]:
				p["packing"] = "silica"
		"genset":
			p["rated_kw"] = clampf(float(p["rated_kw"]), 0.3, 30.0)
			p["efficiency"] = clampf(float(p["efficiency"]), 0.05, 0.45)
		"flare":
			p["height_mm"] = clampf(float(p["height_mm"]), 300.0, 4000.0)
	for k in p:
		if p[k] is float and str(k).ends_with("_mm"):
			p[k] = maxf(float(p[k]), 1.0)
	return p


static func label_of(type: String) -> String:
	return str((TYPES.get(type, {}) as Dictionary).get("label", type))


static func types_in(category: String) -> Array:
	var out := []
	for t in TYPE_ORDER:
		if str(TYPES[t]["category"]) == category:
			out.append(t)
	return out


## Human name for one part: "1½\" 90° elbow", "2\" × 1½\" concentric reducer".
static func part_name(type: String, size: String, params: Dictionary) -> String:
	var s := TcStandards.size_label(size)
	match type:
		"spool":
			return "%s spool %d mm" % [s, roundi(float(params.get("length_mm", 0.0)))]
		"reducer", "reducing_cap":
			return "%s × %s %s" % [s, TcStandards.size_label(str(params.get("small", ""))), label_of(type).to_lower()]
		"reducing_tee":
			return "%s × %s reducing tee" % [s, TcStandards.size_label(str(params.get("branch", "")))]
		"cap_npt":
			return "%s cap × %s FNPT" % [s, TcStandards.size_label(str(params.get("npt", "")))]
		"tc_npt_m":
			return "%s TC × %s MNPT" % [s, TcStandards.size_label(str(params.get("npt", "")))]
		"tc_barb":
			return "%s TC × %s hose barb" % [s, TcStandards.size_label(str(params.get("barb", "")))]
		"bend":
			return "%s %d° bend" % [s, roundi(float(params.get("angle_deg", 0.0)))]
		"vessel":
			return TcVessel.label(TcVessel.resolve(params))
		"elbow90", "tee":
			return "%s %s%s" % [s, "short " if bool(params.get("short", false)) else "", label_of(type).to_lower()]
		"dephlegmator":
			return "%s × %d mm condenser" % [s, roundi(float(params.get("length_mm", 0.0)))]
		"column", "sight_glass":
			return "%s %s %d mm" % [s, label_of(type).to_lower(), roundi(float(params.get("length_mm", 0.0)))]
		"actuator_pneumatic", "actuator_electric":
			return "%s (for %s valves)" % [label_of(type), s]
		"gas_holder":
			return "%d L gas holder" % roundi(float(params.get("volume_l", 0.0)))
		"dryer":
			return "%s %s dryer %d mm" % [s, "silica gel" if str(params.get("packing", "")) == "silica" else "carbon", roundi(float(params.get("length_mm", 0.0)))]
		"genset":
			return "%.1f kW gas genset (48 V DC)" % float(params.get("rated_kw", 0.0))
	return "%s %s" % [s, label_of(type).to_lower()]


# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------

static func port(id: String, kind: String, size: String, pos: Vector3, z: Vector3, x: Vector3 = Vector3.ZERO) -> Dictionary:
	var zz := z.normalized()
	var xx := x
	if xx.length() < 1e-6:
		xx = Vector3.UP if absf(zz.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	xx = (xx - zz * xx.dot(zz)).normalized()
	return {"id": id, "kind": kind, "size": size, "pos": pos, "z": zz, "x": xx}


## A port's frame: origin on the face, +Z out of the part, +X the roll
## reference, +Y = Z × X.
static func port_xform(p: Dictionary) -> Transform3D:
	var z: Vector3 = p["z"]
	var x: Vector3 = p["x"]
	return Transform3D(Basis(x, z.cross(x), z), p["pos"])


## A frame at a port whose +Z points INTO the part (what ferrule_end wants).
static func into_xform(p: Dictionary) -> Transform3D:
	var t := port_xform(p)
	return Transform3D(Basis(t.basis.x, -t.basis.y, -t.basis.z), t.origin)


## Can these two port dicts mate? {ok, why}.
static func can_mate(a: Dictionary, b: Dictionary) -> Dictionary:
	var ka := str(a["kind"])
	var kb := str(b["kind"])
	if ka == "tc" and kb == "tc":
		if TcStandards.clamps_match(str(a["size"]), str(b["size"])):
			return {"ok": true, "why": ""}
		return {"ok": false, "why": "a %s clamp face does not meet a %s one — it needs a reducer" % [
			TcStandards.size_label(str(a["size"])), TcStandards.size_label(str(b["size"]))]}
	if (ka == "npt_m" and kb == "npt_f") or (ka == "npt_f" and kb == "npt_m"):
		if str(a["size"]) == str(b["size"]):
			return {"ok": true, "why": ""}
		return {"ok": false, "why": "the threads are different sizes"}
	if ka == "weld" and kb == "weld" and str(a["size"]) == str(b["size"]):
		return {"ok": true, "why": ""}
	if ka == "stem" and kb == "stem":
		return {"ok": true, "why": ""}
	return {"ok": false, "why": "a %s end does not mate with a %s end" % [kind_word(ka), kind_word(kb)]}


static func kind_word(k: String) -> String:
	match k:
		"tc": return "clamp"
		"npt_m": return "male thread"
		"npt_f": return "female thread"
		"weld": return "weld"
		"barb": return "hose barb"
		"stem": return "valve stem"
	return k


## The gap a joint between these ports adds (mm): a gasket for clamps,
## nothing for threads (the thread engagement is drawn inside the parts).
static func joint_gap(a: Dictionary, b: Dictionary) -> float:
	if str(a["kind"]) == "tc" and str(b["kind"]) == "tc":
		return TcStandards.GASKET_GAP_MM
	return 0.0


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

static func key_of(type: String, size: String, params: Dictionary) -> String:
	return "%s|%s|%s" % [type, size, JSON.stringify(_rounded(params))]


static func _rounded(d: Dictionary) -> Dictionary:
	var out := {}
	var keys := d.keys()
	keys.sort()
	for k in keys:
		var v: Variant = d[k]
		if v is float:
			var r := snappedf(float(v), 0.01)
			out[k] = int(r) if is_equal_approx(r, roundf(r)) else r
		else:
			out[k] = v
	return out


static func clear_cache() -> void:
	_cache.clear()


## The built part. Cached; treat the returned dict as read-only.
static func build(type: String, size: String, params: Dictionary = {}) -> Dictionary:
	var p := resolve_params(type, size, params)
	var key := key_of(type, size, p)
	if TcGeom.seg_scale < 0.999:
		key += "|lod%.2f" % TcGeom.seg_scale
	if _cache.has(key):
		return _cache[key]
	var g := TcGeom.new()
	var r := {}
	match type:
		"spool": r = _spool(g, size, p)
		"elbow90": r = _bend(g, size, 90.0, TcStandards.short_radius(size) if bool(p.get("short", false)) else 0.0)
		"elbow45": r = _bend(g, size, 45.0, 0.0)
		"bend": r = _bend(g, size, float(p["angle_deg"]), float(p["radius_mm"]))
		"tee": r = _tee(g, size, size, false, bool(p.get("short", false)))
		"reducing_tee": r = _tee(g, size, str(p["branch"]), false)
		"cross": r = _tee(g, size, size, true)
		"lateral": r = _lateral(g, size)
		"ferrule": r = _ferrule(g, size, bool(p["long"]))
		"cap": r = _cap(g, size, "")
		"cap_npt": r = _cap(g, size, str(p["npt"]))
		"reducing_cap": r = _reducing_cap(g, size, str(p["small"]))
		"reducer": r = _reducer(g, size, str(p["small"]))
		"tc_npt_m": r = _tc_npt(g, size, str(p["npt"]))
		"tc_barb": r = _tc_barb(g, size, str(p["barb"]))
		"vessel": r = TcVessel.build(g, p)
		"butterfly": r = TcSpecialty.butterfly(g, size, bool(p["open"]), bool(p["manual"]))
		"ball_valve": r = TcSpecialty.ball_valve(g, size, false, bool(p["open"]), bool(p["manual"]))
		"ball_valve_3way": r = TcSpecialty.ball_valve(g, size, true, bool(p["open"]), bool(p["manual"]))
		"check_valve": r = TcSpecialty.check_valve(g, size)
		"diaphragm_valve": r = TcSpecialty.diaphragm_valve(g, size, bool(p["manual"]))
		"relief_valve": r = TcSpecialty.relief_valve(g, size)
		"actuator_pneumatic": r = TcSpecialty.actuator_pneumatic(g, size)
		"actuator_electric": r = TcSpecialty.actuator_electric(g, size)
		"sight_glass": r = TcSpecialty.sight_glass(g, size, float(p["length_mm"]))
		"thermometer": r = TcSpecialty.thermometer(g, size, str(p["mount"]), str(p["npt"]), float(p["probe_mm"]))
		"gauge": r = TcSpecialty.gauge(g, size, str(p["mount"]), str(p["npt"]))
		"thermowell": r = TcSpecialty.thermowell(g, size, float(p["length_mm"]))
		"dephlegmator": r = TcSpecialty.dephlegmator(g, size, float(p["length_mm"]), str(p["shell"]))
		"column": r = TcSpecialty.column(g, size, float(p["length_mm"]), bool(p["window"]), str(p["packing"]))
		"bubble_plate": r = TcSpecialty.bubble_plate(g, size)
		"inline_strainer": r = TcSpecialty.inline_strainer(g, size)
		"y_strainer": r = TcSpecialty.y_strainer(g, size)
		"cartridge_housing": r = TcSpecialty.cartridge_housing(g, size, float(p["element_mm"]))
		"strainer_basket": r = TcSpecialty.strainer_basket(g, size, float(p["depth_mm"]))
		"funnel": r = TcSpecialty.funnel(g, size, float(p["rim_mm"]), float(p["height_mm"]))
		"spray_ball": r = TcSpecialty.spray_ball(g, size)
		"heating_element": r = TcSpecialty.heating_element(g, size, float(p["length_mm"]))
		"gas_holder": r = TcUnits.gas_holder(g, size, float(p["volume_l"]), float(p["hold_kpa"]))
		"dryer": r = TcUnits.dryer(g, size, float(p["length_mm"]), str(p["packing"]))
		"genset": r = TcUnits.genset(g, size, float(p["rated_kw"]), float(p["efficiency"]))
		"flare": r = TcUnits.flare(g, size, float(p["height_mm"]))
		_:
			r = _cap(g, size, "")
	r["geo"] = g
	r["type"] = type
	r["size"] = size
	r["params"] = p
	r["key"] = key
	r["label"] = part_name(type, size, p)
	r["designation"] = str((TYPES.get(type, {}) as Dictionary).get("designation", type))
	r["bounds"] = g.aabb()
	if _cache.size() > 400:
		_cache.clear()
	_cache[key] = r
	return r


static func _ports_by_id(r: Dictionary) -> Dictionary:
	var out := {}
	for p in r["ports"]:
		out[str(p["id"])] = p
	return out


## Tube metal mass per mm of length (kg) and bore area (mm²).
static func _tube_kg_per_mm(size: String) -> float:
	var t := TcStandards.tube(size)
	var ro := float(t["r_out"])
	var ri := float(t["r_in"])
	return PI * (ro * ro - ri * ri) * 1e-9 * TcStandards.STEEL_KG_M3


static func _bore_l_per_mm(size: String) -> float:
	var ri := float(TcStandards.tube(size)["r_in"])
	return PI * ri * ri * 1e-6


## A clamp ferrule's flange ring mass (kg) beyond the tube.
static func _flange_kg(size: String) -> float:
	var t := TcStandards.tube(size)
	var f := TcStandards.ferrule(size)
	var rf := float(t["r_flange"])
	var ro := float(t["r_out"])
	var vol := PI * (rf * rf - ro * ro) * (float(f["rim"]) + float(f["taper"]) * 0.5)
	return vol * 1e-9 * TcStandards.STEEL_KG_M3


static func _spool(g: TcGeom, size: String, p: Dictionary) -> Dictionary:
	var L := float(p["length_mm"])
	var pa := port("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1), Vector3.UP)
	var pb := port("b", "tc", size, Vector3(0, 0, L), Vector3(0, 0, 1), Vector3.UP)
	var hub := float(TcStandards.ferrule(size)["hub"])
	var h := minf(hub, L * 0.5)
	g.ferrule_end(into_xform(pa), size, false, STEEL, h)
	g.ferrule_end(into_xform(pb), size, false, STEEL, h)
	g.tube_body(Transform3D.IDENTITY, size, h, L - h)
	var rf := float(TcStandards.tube(size)["r_flange"])
	return {"ports": [pa, pb], "capsules": [[Vector3.ZERO, Vector3(0, 0, L), rf]],
		"mass_kg": _tube_kg_per_mm(size) * L + _flange_kg(size) * 2.0,
		"volume_l": _bore_l_per_mm(size) * L}


## A bend of `angle` degrees: port a at −Z facing −Z, the corner at the
## origin, port b along (sin A, 0, cos A). radius 0 = the 2CMP radius.
static func _bend(g: TcGeom, size: String, angle: float, radius: float) -> Dictionary:
	var a := deg_to_rad(angle)
	var R := radius if radius > 0.0 else TcStandards.bend_radius(size)
	var straight := maxf(TcStandards.elbow90_ctf(size) - TcStandards.bend_radius(size), 0.0)
	var hub := float(TcStandards.ferrule(size)["hub"])
	straight = maxf(straight, hub)
	var tang := R * tan(a * 0.5) if angle < 179.0 else R
	var ctf := tang + straight
	var db := Vector3(sin(a), 0.0, cos(a))
	var pa := port("a", "tc", size, Vector3(0, 0, -ctf), Vector3(0, 0, -1), Vector3.UP)
	var pb := port("b", "tc", size, db * ctf, db, Vector3.UP)
	var ha := g.ferrule_end(into_xform(pa), size)
	var hb := g.ferrule_end(into_xform(pb), size)
	var t1 := Vector3(0, 0, -tang)
	var t2 := db * tang
	var path := PackedVector3Array()
	path.append(Vector3(0, 0, -ctf + ha))
	if ctf - ha > tang + 0.01:
		path.append(t1)
	var c := t1 + Vector3(R, 0, 0)
	var n := maxi(6, int(angle / 6.0))
	var arc := TcGeom.arc_points(c, t1, Vector3.UP, a, n)
	for i in range(1, arc.size()):
		path.append(arc[i])
	if ctf - hb > tang + 0.01:
		path.append(db * (ctf - hb))
	g.bent_body(path, size)
	var rf := float(TcStandards.tube(size)["r_flange"])
	var arc_len := R * a
	var run_len := (ctf - tang) * 2.0 + arc_len
	var caps: Array = [[pa["pos"], t1, rf], [t1, t2, float(TcStandards.tube(size)["r_out"])], [t2, pb["pos"], rf]]
	return {"ports": [pa, pb], "capsules": caps,
		"mass_kg": _tube_kg_per_mm(size) * run_len + _flange_kg(size) * 2.0,
		"volume_l": _bore_l_per_mm(size) * run_len, "ctf_mm": ctf, "radius_mm": R}


## A tee (run along Z through the origin, branch along +X); `cross` adds
## the −X branch. Branch tubes start on the run's saddle.
static func _tee(g: TcGeom, size: String, bsize: String, cross: bool, short: bool = false) -> Dictionary:
	var c := TcStandards.short_ctf(size) if short else TcStandards.tee_ctf(size)
	var cb := c
	var pa := port("a", "tc", size, Vector3(0, 0, -c), Vector3(0, 0, -1), Vector3.UP)
	var pb := port("b", "tc", size, Vector3(0, 0, c), Vector3(0, 0, 1), Vector3.UP)
	var pc := port("c", "tc", bsize, Vector3(cb, 0, 0), Vector3(1, 0, 0), Vector3.UP)
	var ports: Array = [pa, pb, pc]
	if cross:
		ports.append(port("d", "tc", bsize, Vector3(-cb, 0, 0), Vector3(-1, 0, 0), Vector3.UP))
	var ha := g.ferrule_end(into_xform(pa), size)
	g.ferrule_end(into_xform(pb), size)
	g.tube_body(into_xform(pa), size, ha, 2.0 * c - ha)
	var run := TcStandards.tube(size)
	var br := TcStandards.tube(bsize)
	for bp in ports.slice(2):
		var hb := g.ferrule_end(into_xform(bp), bsize)
		_branch(g, float(run["r_out"]), float(br["r_out"]), (bp["z"] as Vector3), cb - hb, true)
		_branch(g, float(run["r_in"]), float(br["r_in"]), (bp["z"] as Vector3), cb - hb, false)
	var rf := float(run["r_flange"])
	var caps: Array = [[pa["pos"], pb["pos"], rf]]
	for bp in ports.slice(2):
		caps.append([Vector3.ZERO, bp["pos"], float(br["r_flange"])])
	var nb := ports.size() - 2
	return {"ports": ports, "capsules": caps,
		"mass_kg": _tube_kg_per_mm(size) * 2.0 * c + _tube_kg_per_mm(bsize) * cb * nb
			+ _flange_kg(size) * 2.0 + _flange_kg(bsize) * nb,
		"volume_l": _bore_l_per_mm(size) * 2.0 * c + _bore_l_per_mm(bsize) * cb * nb}


## A branch tube surface (radius rb) leaving a run tube (radius rr, axis Z)
## along `dir` (±X), from the saddle out to `to` mm from the run's axis.
static func _branch(g: TcGeom, rr: float, rb: float, dir: Vector3, to: float, outward: bool) -> void:
	var segs := TcGeom.segs_for(rb * 1.3)
	var d := dir.normalized()
	var y := Vector3.UP
	var z := d.cross(y).normalized()
	for k in segs:
		var p0: Array = _saddle(rr, rb, d, y, z, float(k) / float(segs), to)
		var p1: Array = _saddle(rr, rb, d, y, z, float(k + 1) / float(segs), to)
		var n0: Vector3 = p0[2] if outward else -(p0[2] as Vector3)
		var n1: Vector3 = p1[2] if outward else -(p1[2] as Vector3)
		g.quad(STEEL, p0[0], p1[0], p1[1], p0[1], n0, n1, n1, n0)


static func _saddle(rr: float, rb: float, d: Vector3, y: Vector3, z: Vector3, u: float, to: float) -> Array:
	var phi := TAU * u
	var cy := rb * cos(phi)
	var cz := rb * sin(phi)
	# Distance from the run axis (Z) only counts the component across it:
	# the branch's own z offset runs ALONG the run.
	var across := cy if absf(z.z) > 0.5 else cz
	var x0 := sqrt(maxf(rr * rr - across * across, 0.0))
	var off := y * cy + z * cz
	return [d * x0 + off, d * to + off, (y * cos(phi) + z * sin(phi)).normalized()]


static func _lateral(g: TcGeom, size: String) -> Dictionary:
	var c := TcStandards.tee_ctf(size)
	var t := TcStandards.tube(size)
	var lb := c + float(t["r_flange"])   # estimate: no 28MP table fetched
	var db := Vector3(sin(PI * 0.25), 0.0, cos(PI * 0.25))
	var pa := port("a", "tc", size, Vector3(0, 0, -c), Vector3(0, 0, -1), Vector3.UP)
	var pb := port("b", "tc", size, Vector3(0, 0, c), Vector3(0, 0, 1), Vector3.UP)
	var pc := port("c", "tc", size, db * lb, db, Vector3.UP)
	var ha := g.ferrule_end(into_xform(pa), size)
	g.ferrule_end(into_xform(pb), size)
	g.tube_body(into_xform(pa), size, ha, 2.0 * c - ha)
	var hc := g.ferrule_end(into_xform(pc), size)
	# The branch starts on the run's axis: the run's own tube hides the part
	# inside it.
	g.tube_body(TcGeom.frame_along(Vector3.ZERO, db), size, float(t["r_out"]) * 0.2, lb - hc)
	var rf := float(t["r_flange"])
	return {"ports": [pa, pb, pc], "capsules": [[pa["pos"], pb["pos"], rf], [Vector3.ZERO, pc["pos"], rf]],
		"mass_kg": _tube_kg_per_mm(size) * (2.0 * c + lb) + _flange_kg(size) * 3.0,
		"volume_l": _bore_l_per_mm(size) * (2.0 * c + lb)}


static func _ferrule(g: TcGeom, size: String, long: bool) -> Dictionary:
	var f := TcStandards.ferrule(size, long)
	var hub := float(f["hub"])
	var t := TcStandards.tube(size)
	var pa := port("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1), Vector3.UP)
	var pb := port("b", "weld", size, Vector3(0, 0, hub), Vector3(0, 0, 1), Vector3.UP)
	g.ferrule_end(into_xform(pa), size, long)
	g.lathe(STEEL, [Vector2(float(t["r_out"]), hub), Vector2(float(t["r_in"]), hub)], Transform3D.IDENTITY,
		TcGeom.segs_for(float(t["r_flange"])))
	return {"ports": [pa, pb], "capsules": [[Vector3.ZERO, Vector3(0, 0, hub), float(t["r_flange"])]],
		"mass_kg": _tube_kg_per_mm(size) * hub + _flange_kg(size), "volume_l": _bore_l_per_mm(size) * hub}


## An end cap (face at the origin facing −Z); with `npt` a hex boss on the
## back carrying a female thread (port b, facing +Z).
static func _cap(g: TcGeom, size: String, npt: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var f := TcStandards.ferrule(size)
	var rf := float(t["r_flange"])
	var ro := float(t["r_out"])
	var rim := float(f["rim"])
	var thick := rim + float(f["taper"]) * 0.6 + 1.5
	var gg: Array = f["groove"]
	var gd := float(f["groove_depth"])
	var hole := 0.0
	if not npt.is_empty():
		hole = TcStandards.npt_od(npt) * 0.5 * 0.82
	var prof: Array = []
	if hole > 0.0:
		prof = [Vector2(hole, thick), Vector2(hole, 0.0)]
	else:
		prof = [Vector2(0.0, 0.0)]
	prof.append_array([Vector2(maxf(float(gg[0]), hole + 0.5), 0.0), Vector2(maxf(float(gg[0]), hole + 0.5), gd),
		Vector2(float(gg[1]), gd), Vector2(float(gg[1]), 0.0), Vector2(rf, 0.0), Vector2(rf, rim),
		Vector2(ro * 0.96, thick), Vector2(hole, thick)])
	g.lathe(STEEL, prof, Transform3D.IDENTITY, TcGeom.segs_for(rf))
	var pa := port("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1), Vector3.UP)
	var ports: Array = [pa]
	var mass := PI * rf * rf * thick * 1e-9 * TcStandards.STEEL_KG_M3
	var top := thick
	if not npt.is_empty():
		var od := TcStandards.npt_od(npt)
		var boss := od * 0.75 + 4.0
		g.hex(STEEL, Vector3(0, 0, thick), Vector3(0, 0, 1), boss, od * 1.35, hole)
		top = thick + boss
		ports.append(port("b", "npt_f", npt, Vector3(0, 0, top), Vector3(0, 0, 1), Vector3.UP))
		mass += PI * pow(od * 0.68, 2.0) * boss * 1e-9 * TcStandards.STEEL_KG_M3
	return {"ports": ports, "capsules": [[Vector3.ZERO, Vector3(0, 0, top), rf]],
		"mass_kg": mass, "volume_l": 0.0}


## A flat cap carrying a smaller clamp end on a stub (the GLB's ½" on 1½").
static func _reducing_cap(g: TcGeom, size: String, small: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var ts := TcStandards.tube(small)
	var f := TcStandards.ferrule(size)
	var rf := float(t["r_flange"])
	var rim := float(f["rim"])
	var thick := rim + 1.5
	var rs_in := float(ts["r_in"])
	var rs_out := float(ts["r_out"])
	var gg: Array = f["groove"]
	var gd := float(f["groove_depth"])
	var g0 := maxf(float(gg[0]), rs_in + 0.6)
	var g1 := maxf(float(gg[1]), g0 + 1.0)
	g.lathe(STEEL, [Vector2(rs_in, thick), Vector2(rs_in, 0.0), Vector2(g0, 0.0), Vector2(g0, gd),
		Vector2(g1, gd), Vector2(g1, 0.0), Vector2(rf, 0.0), Vector2(rf, thick), Vector2(rs_out, thick)],
		Transform3D.IDENTITY, TcGeom.segs_for(rf))
	var hub := float(TcStandards.ferrule(small)["hub"])
	var L := thick + hub + 6.0
	var pa := port("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1), Vector3.UP)
	var pb := port("b", "tc", small, Vector3(0, 0, L), Vector3(0, 0, 1), Vector3.UP)
	var h := g.ferrule_end(into_xform(pb), small)
	g.tube_body(Transform3D.IDENTITY, small, thick, L - h)
	var mass := PI * rf * rf * thick * 1e-9 * TcStandards.STEEL_KG_M3 + _flange_kg(small) + _tube_kg_per_mm(small) * (L - thick)
	return {"ports": [pa, pb], "capsules": [[Vector3.ZERO, Vector3(0, 0, thick), rf],
		[Vector3(0, 0, thick), Vector3(0, 0, L), float(ts["r_flange"])]],
		"mass_kg": mass, "volume_l": _bore_l_per_mm(small) * (L - thick)}


static func _reducer(g: TcGeom, size: String, small: String) -> Dictionary:
	var a := TcStandards.tube(size)
	var b := TcStandards.tube(small)
	var L := TcStandards.reducer_len(size, small)
	var pa := port("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1), Vector3.UP)
	var pb := port("b", "tc", small, Vector3(0, 0, L), Vector3(0, 0, 1), Vector3.UP)
	var ha := g.ferrule_end(into_xform(pa), size)
	var hb := g.ferrule_end(into_xform(pb), small)
	var n := TcGeom.segs_for(float(a["r_flange"]))
	g.lathe(STEEL, [Vector2(float(a["r_out"]), ha), Vector2(float(b["r_out"]), L - hb)], Transform3D.IDENTITY, n)
	g.lathe(STEEL, [Vector2(float(b["r_in"]), L - hb), Vector2(float(a["r_in"]), ha)], Transform3D.IDENTITY, n)
	var mid := (ha + (L - hb)) * 0.5
	return {"ports": [pa, pb], "capsules": [[Vector3.ZERO, Vector3(0, 0, mid), float(a["r_flange"])],
		[Vector3(0, 0, mid), Vector3(0, 0, L), float(b["r_flange"])]],
		"mass_kg": (_tube_kg_per_mm(size) + _tube_kg_per_mm(small)) * 0.5 * L + _flange_kg(size) + _flange_kg(small),
		"volume_l": (_bore_l_per_mm(size) + _bore_l_per_mm(small)) * 0.5 * L}


## TC × male NPT: ferrule, a short neck, a hex, then the thread (port b at
## the tip).
static func _tc_npt(g: TcGeom, size: String, npt: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var od := TcStandards.npt_od(npt)
	var pa := port("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1), Vector3.UP)
	var h := g.ferrule_end(into_xform(pa), size)
	var af := maxf(od * 1.3, float(t["od"]) * 0.8)
	var neck := h + 4.0
	g.tube_body(Transform3D.IDENTITY, size, h, neck)
	var rb := minf(float(t["r_in"]), od * 0.5 * 0.62)
	g.lathe(STEEL, [Vector2(rb, h), Vector2(float(t["r_in"]), h)], Transform3D.IDENTITY, TcGeom.segs_for(float(t["r_in"])))
	var hex_len := od * 0.45 + 4.0
	g.hex(STEEL, Vector3(0, 0, neck), Vector3(0, 0, 1), hex_len, af, rb)
	var thread_len := od * 0.85
	var z0 := neck + hex_len
	g.npt_thread(TcGeom.frame_along(Vector3(0, 0, z0), Vector3(0, 0, 1)), npt, thread_len)
	var tip := z0 + thread_len
	var pb := port("b", "npt_m", npt, Vector3(0, 0, tip), Vector3(0, 0, 1), Vector3.UP)
	var mass := _flange_kg(size) + _tube_kg_per_mm(size) * neck + PI * pow(af * 0.5, 2.0) * hex_len * 0.8e-9 * TcStandards.STEEL_KG_M3 \
		+ PI * pow(od * 0.5, 2.0) * thread_len * 0.6e-9 * TcStandards.STEEL_KG_M3
	return {"ports": [pa, pb], "capsules": [[Vector3.ZERO, Vector3(0, 0, neck), float(t["r_flange"])],
		[Vector3(0, 0, neck), Vector3(0, 0, tip), af * 0.55]], "mass_kg": mass,
		"volume_l": PI * rb * rb * (tip - h) * 1e-6 + _bore_l_per_mm(size) * h}


static func _tc_barb(g: TcGeom, size: String, barb: String) -> Dictionary:
	var t := TcStandards.tube(size)
	var d := float(barb) * TcStandards.IN
	var pa := port("a", "tc", size, Vector3.ZERO, Vector3(0, 0, -1), Vector3.UP)
	var h := g.ferrule_end(into_xform(pa), size)
	var neck := h + 3.0
	g.tube_body(Transform3D.IDENTITY, size, h, neck)
	var r0 := d * 0.5 * 0.92
	var rr := d * 0.5 * 1.12
	var bore := d * 0.5 * 0.62
	var z := neck + 3.0
	var prof: Array = [Vector2(float(t["r_out"]), neck), Vector2(r0, z)]
	var ridge := maxf(d * 0.45, 4.0)
	for i in 3:
		prof.append(Vector2(rr, z + ridge * 0.15))
		prof.append(Vector2(r0, z + ridge))
		z += ridge
	z += 2.0
	prof.append(Vector2(r0, z))
	prof.append(Vector2(bore, z))
	g.lathe(STEEL, prof, Transform3D.IDENTITY, TcGeom.segs_for(rr))
	g.lathe(STEEL, [Vector2(bore, z), Vector2(bore, h), Vector2(float(t["r_in"]), h)], Transform3D.IDENTITY, TcGeom.segs_for(float(t["r_in"])))
	var pb := port("b", "barb", barb, Vector3(0, 0, z), Vector3(0, 0, 1), Vector3.UP)
	return {"ports": [pa, pb], "capsules": [[Vector3.ZERO, Vector3(0, 0, neck), float(t["r_flange"])],
		[Vector3(0, 0, neck), Vector3(0, 0, z), rr]],
		"mass_kg": _flange_kg(size) + _tube_kg_per_mm(size) * neck + PI * (rr * rr - bore * bore) * (z - neck) * 0.7e-9 * TcStandards.STEEL_KG_M3,
		"volume_l": PI * bore * bore * (z - h) * 1e-6}
