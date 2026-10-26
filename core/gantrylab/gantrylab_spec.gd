class_name GantryLabSpec
extends RefCounted

## The gantry designer's spec: everything a CNC gantry IS, as plain data.
##
##   name, version
##   kinematics   one of KINEMATICS (the pattern): bedslinger, cartesian_xy,
##                corexy, corexz, hbot, delta, router
##   volume       {x_mm, y_mm, z_mm}  (delta: x_mm = print diameter, z_mm = height)
##   frame        {profile, gantry_profile, corners, enclosed, feet}
##   axis         {x: {guide, drive, motor, pulley_teeth, motors, microsteps}, y: …, z: …}
##                (delta uses axis.z for the three towers; corexy / hbot use
##                axis.x for the shared A/B belt pair)
##   delta        {arm_mm, tower_r_mm, effector_r_mm, carriage_r_mm}
##   electronics  {board, firmware, volts, max_feed_mm_s, accel_mm_s2, junction_mm_s}
##   tool         {id, bed}
##   colors       {frame, plate, belt, bed}
##
## resolve() fills every default and clamps; key_of() hashes what changes the
## design (the cache key); to_json_safe() turns the colours into arrays.

const VERSION := 1

const KINEMATICS := ["bedslinger", "cartesian_xy", "corexy", "corexz", "hbot", "delta", "router"]
const KINEMATICS_LABELS := {
	"bedslinger": "Cartesian bed-slinger (i3)",
	"cartesian_xy": "Cartesian XY head, Z bed",
	"corexy": "CoreXY",
	"corexz": "CoreXZ",
	"hbot": "H-bot",
	"delta": "Delta (linear)",
	"router": "Moving-gantry router",
}
const KINEMATICS_SHORT := {
	"bedslinger": "Bed-slinger", "cartesian_xy": "Cartesian XY", "corexy": "CoreXY",
	"corexz": "CoreXZ", "hbot": "H-bot", "delta": "Delta", "router": "Router gantry",
}
## The pattern language: when each kinematics is the right answer.
const KINEMATICS_WHY := {
	"bedslinger": "One motor per axis, the bed carries Y. The simplest frame and the cheapest; the bed's mass caps acceleration, so tall light parts wobble past ~150 mm/s. The Prusa i3 / Ender pattern: pick it for a first printer, a pen plotter, anything under 250 mm.",
	"cartesian_xy": "The head moves in X and Y on a crossed gantry, the bed only drops in Z. Heavier parts print fine (the bed never accelerates); the Y motor rides the X beam, so the moving mass is higher than CoreXY. The Ultimaker / Ender-5 pattern.",
	"corexy": "Two fixed motors share one belt loop: A = X + Y, B = X − Y. Nothing heavy moves with the head, so it accelerates hardest of all the Cartesian layouts; the belts must be matched in tension or the axes skew. The Voron / RatRig / HyperCube pattern: fast enclosed printers from 250 to 500 mm.",
	"corexz": "CoreXY turned on its side: the belts share X and Z, the bed slides in Y. The Z axis is belt-driven and fast, with no lead-screw wobble. The Voron Switchwire pattern — a bed-slinger's frame with a CoreXY's X.",
	"hbot": "The same equations as CoreXY (A = X + Y, B = X − Y) on ONE belt through an H of idlers. Simpler to route, but every X move twists the gantry about its rails (the racking moment), so it needs stiff rails and stays small. Plotters and laser engravers.",
	"delta": "Three vertical towers, three carriages, six arms to one effector; every move is all three motors. The effector is tiny and the volume is tall; fast and light, with a round bed. Needs calibration (arm length, delta radius) and trades resolution at the edge. The Kossel / Rostock pattern: vases, tall parts, clay.",
	"router": "A whole gantry beam rides in Y over a fixed bed; X moves along the beam, Z plunges the tool. Built heavy on purpose: lead screws or ball screws hold a cutting force the belts cannot. The OpenBuilds LEAD / WorkBee / C-Beam pattern: wood, plastics, PCBs, aluminium with a big spindle.",
}
## Applications, each pointing at a pattern + tool (the "choose a design for
## an application" entry).
const APPLICATIONS := [
	{"id": "learn", "label": "Learn CNC (pen plotter)", "kinematics": "hbot", "tool": "pen",
		"why": "A pen on an H-bot: every part visible, no heat, no cutting force, the belt maths on show."},
	{"id": "first_printer", "label": "First 3D printer", "kinematics": "bedslinger", "tool": "hotend_04",
		"why": "A 220 mm bed-slinger on 2040: three motors, one belt each, the cheapest working printer."},
	{"id": "fast_printer", "label": "Fast enclosed printer", "kinematics": "corexy", "tool": "hotend_04",
		"why": "CoreXY on linear rails, 300 mm cube, four Z motors for a flat bed, 10 000 mm/s² if the belts are tight."},
	{"id": "big_parts", "label": "Big structural parts (flake)", "kinematics": "cartesian_xy", "tool": "pellet_extruder",
		"why": "A pellet head is heavy; the XY-head Cartesian keeps the bed still and the frame cheap at 600 mm."},
	{"id": "vases", "label": "Tall vases and clay", "kinematics": "delta", "tool": "clay_extruder",
		"why": "A delta is tall and round and the effector weighs nothing; the clay cartridge rides the arms."},
	{"id": "wood", "label": "Wood and plastic routing", "kinematics": "router", "tool": "router_1250w",
		"why": "C-Beam gantry on lead screws, a trim router, a spoilboard: the LEAD 1010 pattern."},
	{"id": "aluminium", "label": "Aluminium milling", "kinematics": "router", "tool": "spindle_2200w",
		"why": "Ball screws, HGR15 rails, a 2.2 kW spindle: stiff enough for 1 mm passes in 6061."},
	{"id": "laser", "label": "Laser engraving / cutting", "kinematics": "corexy", "tool": "laser_10w",
		"why": "No cutting force at all, so a light CoreXY on 2020 runs at 400 mm/s."},
]

const PROFILE_IDS := GantryLabParts.PROFILE_ORDER
const CORNERS := ["bracket", "hidden", "plate"]
const CORNER_LABELS := {"bracket": "Cast corner brackets", "hidden": "Hidden inside corners", "plate": "Bolted plates"}

const VOLUME_DEFAULTS := {"x_mm": 220.0, "y_mm": 220.0, "z_mm": 250.0}
const FRAME_DEFAULTS := {"profile": "2040", "gantry_profile": "2040", "corners": "bracket", "enclosed": false, "feet": true}
const AXIS_DEFAULTS := {"guide": "v_wheel", "drive": "belt_gt2_6", "motor": "nema17", "pulley_teeth": 20,
	"motors": 1, "microsteps": 16}
const DELTA_DEFAULTS := {"arm_mm": 215.0, "tower_r_mm": 140.0, "effector_r_mm": 32.0, "carriage_r_mm": 20.0}
const ELEC_DEFAULTS := {"board": "skr_mini_e3", "firmware": "klipper", "volts": 24,
	"max_feed_mm_s": 150.0, "accel_mm_s2": 3000.0, "junction_mm_s": 8.0}
const TOOL_DEFAULTS := {"id": "hotend_04", "bed": "heated_pcb"}
const COLOR_DEFAULTS := {
	"frame": Color(0.16, 0.17, 0.19), "plate": Color(0.72, 0.74, 0.78),
	"belt": Color(0.08, 0.08, 0.09), "bed": Color(0.22, 0.23, 0.26),
}

const MIN_AXIS_MM := 50.0
const MAX_AXIS_MM := 3000.0


static func default_spec(kinematics: String = "bedslinger") -> Dictionary:
	return resolve({"kinematics": kinematics, "name": str(KINEMATICS_SHORT.get(kinematics, "Gantry"))})


## A spec from an application entry (pattern + tool + sensible sizes).
static func for_application(app_id: String) -> Dictionary:
	for a in APPLICATIONS:
		if str(a["id"]) == app_id:
			var s := default_spec(str(a["kinematics"]))
			s["name"] = str(a["label"])
			s["tool"]["id"] = str(a["tool"])
			s["tool"]["bed"] = str(GantryLabParts.tool(str(a["tool"]))["bed"])
			match app_id:
				"fast_printer":
					s["volume"] = {"x_mm": 300.0, "y_mm": 300.0, "z_mm": 300.0}
					s["frame"]["profile"] = "2020"
					s["frame"]["enclosed"] = true
					for k in ["x", "y"]:
						s["axis"][k]["guide"] = "mgn12"
						s["axis"][k]["drive"] = "belt_gt2_6"
					s["axis"]["z"]["guide"] = "mgn9"
					s["axis"]["z"]["drive"] = "belt_gt2_6"
					s["axis"]["z"]["motors"] = 4
					s["electronics"]["board"] = "octopus"
					s["electronics"]["max_feed_mm_s"] = 300.0
					s["electronics"]["accel_mm_s2"] = 8000.0
				"big_parts":
					s["volume"] = {"x_mm": 600.0, "y_mm": 600.0, "z_mm": 600.0}
					s["frame"]["profile"] = "4040"
					s["frame"]["gantry_profile"] = "2060"
					s["axis"]["x"]["guide"] = "mgn12"
					s["axis"]["y"]["guide"] = "mgn12"
					s["axis"]["x"]["drive"] = "belt_gt2_9"
					s["axis"]["y"]["drive"] = "belt_gt2_9"
					s["axis"]["x"]["motor"] = "nema17_hi"
					s["axis"]["y"]["motor"] = "nema17_hi"
					s["axis"]["z"]["drive"] = "leadscrew_t8_8"
					s["axis"]["z"]["motors"] = 2
					s["electronics"]["board"] = "skr_3"
					s["electronics"]["volts"] = 24
					s["electronics"]["max_feed_mm_s"] = 80.0
					s["electronics"]["accel_mm_s2"] = 1500.0
				"vases":
					s["volume"] = {"x_mm": 300.0, "y_mm": 300.0, "z_mm": 500.0}
					s["delta"] = {"arm_mm": 330.0, "tower_r_mm": 210.0, "effector_r_mm": 40.0, "carriage_r_mm": 25.0}
					s["frame"]["profile"] = "2040"
					s["axis"]["z"]["guide"] = "mgn12"
					s["electronics"]["max_feed_mm_s"] = 60.0
					s["electronics"]["accel_mm_s2"] = 1200.0
				"wood":
					s["volume"] = {"x_mm": 750.0, "y_mm": 750.0, "z_mm": 120.0}
					s["frame"]["profile"] = "c_beam_4080"
					s["frame"]["gantry_profile"] = "c_beam_4080"
					for k in ["x", "y", "z"]:
						s["axis"][k]["guide"] = "v_wheel"
						s["axis"][k]["drive"] = "leadscrew_t8_8"
						s["axis"][k]["motor"] = "nema23"
					s["axis"]["y"]["motors"] = 2
					s["electronics"]["board"] = "blackbox_x32"
					s["electronics"]["firmware"] = "grbl"
					s["electronics"]["max_feed_mm_s"] = 40.0
					s["electronics"]["accel_mm_s2"] = 300.0
				"aluminium":
					s["volume"] = {"x_mm": 600.0, "y_mm": 400.0, "z_mm": 120.0}
					s["frame"]["profile"] = "c_beam_4080"
					s["frame"]["gantry_profile"] = "c_beam_4080"
					s["frame"]["corners"] = "plate"
					for k in ["x", "y", "z"]:
						s["axis"][k]["guide"] = "hgr15"
						s["axis"][k]["drive"] = "ballscrew_1605"
						s["axis"][k]["motor"] = "nema23_hi"
					s["axis"]["y"]["motors"] = 2
					s["electronics"]["board"] = "blackbox_x32"
					s["electronics"]["firmware"] = "grbl"
					s["electronics"]["volts"] = 48
					s["electronics"]["max_feed_mm_s"] = 50.0
					s["electronics"]["accel_mm_s2"] = 400.0
				"laser":
					s["volume"] = {"x_mm": 400.0, "y_mm": 400.0, "z_mm": 60.0}
					s["frame"]["profile"] = "2020"
					s["axis"]["x"]["guide"] = "v_wheel"
					s["axis"]["z"]["drive"] = "leadscrew_t8_2"
					# 400 mm/s on a diagonal is 45 k steps/s on a CoreXY motor:
					# an Uno's 30 k cannot; the ESP32 BlackBox can.
					s["electronics"]["board"] = "blackbox_x32"
					s["electronics"]["firmware"] = "grbl"
					s["electronics"]["max_feed_mm_s"] = 400.0
					s["electronics"]["accel_mm_s2"] = 4000.0
				"learn":
					s["volume"] = {"x_mm": 300.0, "y_mm": 200.0, "z_mm": 50.0}
					s["frame"]["profile"] = "2020"
					s["electronics"]["board"] = "grbl_uno"
					s["electronics"]["firmware"] = "grbl"
			return resolve(s)
	return default_spec()


static func resolve(spec: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	s["version"] = VERSION
	var kin := str(s.get("kinematics", "bedslinger"))
	if not KINEMATICS.has(kin):
		kin = "bedslinger"
	s["kinematics"] = kin
	s["name"] = str(s.get("name", "Gantry")).strip_edges()
	if s["name"].is_empty():
		s["name"] = "Gantry"
	s["volume"] = _merge(VOLUME_DEFAULTS, s.get("volume", {}))
	s["frame"] = _merge(FRAME_DEFAULTS, s.get("frame", {}))
	var ax_in: Variant = s.get("axis", {})
	var ax := {}
	for k in ["x", "y", "z"]:
		var over: Variant = (ax_in as Dictionary).get(k, {}) if ax_in is Dictionary else {}
		var d := _merge(AXIS_DEFAULTS, over)
		if k == "z" and not (over is Dictionary and (over as Dictionary).has("drive")):
			d["drive"] = "leadscrew_t8_8" if kin != "delta" and kin != "corexz" else "belt_gt2_6"
		ax[k] = d
	s["axis"] = ax
	s["delta"] = _merge(DELTA_DEFAULTS, s.get("delta", {}))
	s["electronics"] = _merge(ELEC_DEFAULTS, s.get("electronics", {}))
	s["tool"] = _merge(TOOL_DEFAULTS, s.get("tool", {}))
	var cols := _merge(COLOR_DEFAULTS, s.get("colors", {}))
	for k in cols:
		cols[k] = _to_color(cols[k], COLOR_DEFAULTS[k])
	s["colors"] = cols
	# Clamps.
	var v: Dictionary = s["volume"]
	for k in ["x_mm", "y_mm", "z_mm"]:
		v[k] = clampf(float(v[k]), MIN_AXIS_MM, MAX_AXIS_MM)
	if kin == "delta":
		v["y_mm"] = v["x_mm"]
	var f: Dictionary = s["frame"]
	if not GantryLabParts.PROFILES.has(str(f["profile"])):
		f["profile"] = "2040"
	if not GantryLabParts.PROFILES.has(str(f["gantry_profile"])):
		f["gantry_profile"] = str(f["profile"])
	if not CORNERS.has(str(f["corners"])):
		f["corners"] = "bracket"
	f["enclosed"] = bool(f["enclosed"])
	f["feet"] = bool(f["feet"])
	for k in ["x", "y", "z"]:
		var a: Dictionary = ax[k]
		if not GantryLabParts.GUIDES.has(str(a["guide"])):
			a["guide"] = "v_wheel"
		if not GantryLabParts.DRIVES.has(str(a["drive"])):
			a["drive"] = "belt_gt2_6"
		if not GantryLabParts.MOTORS.has(str(a["motor"])):
			a["motor"] = "nema17"
		a["pulley_teeth"] = clampi(int(a["pulley_teeth"]), 12, 60)
		a["motors"] = clampi(int(a["motors"]), 1, 4)
		var ms := int(a["microsteps"])
		if not [1, 2, 4, 8, 16, 32, 64, 128, 256].has(ms):
			ms = 16
		a["microsteps"] = ms
	# Shared-belt kinematics drive X and Y from the same pair; keep them equal.
	if kin == "corexy" or kin == "hbot":
		ax["y"]["drive"] = ax["x"]["drive"]
		ax["y"]["motor"] = ax["x"]["motor"]
		ax["y"]["pulley_teeth"] = ax["x"]["pulley_teeth"]
		ax["y"]["microsteps"] = ax["x"]["microsteps"]
		ax["x"]["motors"] = 1
		ax["y"]["motors"] = 1
	elif kin == "corexz":
		ax["z"]["drive"] = ax["x"]["drive"]
		ax["z"]["motor"] = ax["x"]["motor"]
		ax["z"]["pulley_teeth"] = ax["x"]["pulley_teeth"]
		ax["z"]["microsteps"] = ax["x"]["microsteps"]
		ax["x"]["motors"] = 1
		ax["z"]["motors"] = 1
	elif kin == "delta":
		ax["z"]["motors"] = 1
	var dl: Dictionary = s["delta"]
	dl["arm_mm"] = clampf(float(dl["arm_mm"]), 100.0, 1200.0)
	dl["tower_r_mm"] = clampf(float(dl["tower_r_mm"]), 60.0, 1000.0)
	dl["effector_r_mm"] = clampf(float(dl["effector_r_mm"]), 10.0, 200.0)
	dl["carriage_r_mm"] = clampf(float(dl["carriage_r_mm"]), 5.0, 150.0)
	var e: Dictionary = s["electronics"]
	if not GantryLabParts.BOARDS.has(str(e["board"])):
		e["board"] = "skr_mini_e3"
	var fw_ok: Array = GantryLabParts.board(str(e["board"]))["firmware"]
	if not fw_ok.has(str(e["firmware"])):
		e["firmware"] = str(fw_ok[0])
	var volts_ok: Array = GantryLabParts.board(str(e["board"]))["volts"]
	e["volts"] = int(e["volts"])
	if not volts_ok.has(int(e["volts"])):
		e["volts"] = int(volts_ok[volts_ok.size() - 1])
	e["max_feed_mm_s"] = clampf(float(e["max_feed_mm_s"]), 5.0, 1500.0)
	e["accel_mm_s2"] = clampf(float(e["accel_mm_s2"]), 50.0, 50000.0)
	e["junction_mm_s"] = clampf(float(e["junction_mm_s"]), 0.5, 60.0)
	var t: Dictionary = s["tool"]
	if not GantryLabParts.TOOLS.has(str(t["id"])):
		t["id"] = "hotend_04"
	if not GantryLabParts.BEDS.has(str(t["bed"])):
		t["bed"] = str(GantryLabParts.tool(str(t["id"]))["bed"])
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


static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var cols := {}
	for k in s["colors"]:
		var c: Color = s["colors"][k]
		cols[k] = [c.r, c.g, c.b, c.a]
	s["colors"] = cols
	return s


static func key_of(spec: Dictionary) -> String:
	var s := resolve(spec)
	var cols := {}
	for k in s["colors"]:
		var c: Color = s["colors"][k]
		cols[k] = "%.3f,%.3f,%.3f,%.3f" % [c.r, c.g, c.b, c.a]
	s["colors"] = cols
	return str(hash(var_to_str(s)))


## Which of x / y / z are real motor axes for a kinematics, and the names the
## motors go by (A/B for shared belts, the three towers for a delta).
static func motor_axes(kinematics: String) -> Array:
	match kinematics:
		"corexy", "hbot":
			return [{"key": "x", "label": "Motor A (X + Y)"}, {"key": "y", "label": "Motor B (X − Y)"}, {"key": "z", "label": "Z"}]
		"corexz":
			return [{"key": "x", "label": "Motor A (X + Z)"}, {"key": "z", "label": "Motor B (X − Z)"}, {"key": "y", "label": "Y"}]
		"delta":
			return [{"key": "z", "label": "Tower A"}, {"key": "z", "label": "Tower B"}, {"key": "z", "label": "Tower C"}]
	return [{"key": "x", "label": "X"}, {"key": "y", "label": "Y"}, {"key": "z", "label": "Z"}]


static func is_additive(spec: Dictionary) -> bool:
	return str(GantryLabParts.tool(str(spec["tool"]["id"]))["process"]) == "additive"


static func fmt_mm(v: float) -> String:
	if absf(v) >= 1000.0:
		return "%.2f m" % (v / 1000.0)
	return "%.0f mm" % v


static func describe(spec: Dictionary) -> String:
	var s := resolve(spec)
	var v: Dictionary = s["volume"]
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var vol := ""
	if str(s["kinematics"]) == "delta":
		vol = "Ø%s × %s" % [fmt_mm(float(v["x_mm"])), fmt_mm(float(v["z_mm"]))]
	else:
		vol = "%s × %s × %s" % [fmt_mm(float(v["x_mm"])), fmt_mm(float(v["y_mm"])), fmt_mm(float(v["z_mm"]))]
	return "%s · %s · %s · %s · %s" % [str(KINEMATICS_LABELS[s["kinematics"]]), vol,
		str(GantryLabParts.profile(str(s["frame"]["profile"]))["label"]), str(tool["label"]),
		str(GantryLabParts.FIRMWARE_LABELS.get(str(s["electronics"]["firmware"]), "firmware"))]
