class_name GantryLabPresets
extends RefCounted

## Built-in gantry designs — the well-known open-source machines as the
## pattern language's worked examples — plus the player's library
## (user://gantrylab_library.json: {version, designs: [{id, name, spec}]}).

const LIBRARY_PATH := "user://gantrylab_library.json"


static func builtins() -> Array:
	var out: Array = []
	var d := GantryLabSpec.for_application("first_printer")
	d["name"] = "i3-class bed-slinger 220"
	out.append({"id": "i3_220", "name": "i3-class bed-slinger (220 mm)", "blurb": "The Prusa i3 / Ender 3 pattern: Y bed on 2040 rails, X beam on two Tr8 screws, one NEMA 17 per axis, a 0.4 mm hotend.", "spec": d})
	d = GantryLabSpec.for_application("learn")
	d["name"] = "H-bot pen plotter"
	out.append({"id": "hbot_plotter", "name": "H-bot pen plotter (300 × 200)", "blurb": "One belt through an H of idlers, a pen, a grbl Uno: the cheapest way to watch A = X + Y happen.", "spec": d})
	d = GantryLabSpec.default_spec("cartesian_xy")
	d["name"] = "Cube Cartesian 220"
	d["volume"] = {"x_mm": 220.0, "y_mm": 220.0, "z_mm": 300.0}
	d["frame"]["profile"] = "2020"
	d["axis"]["z"]["drive"] = "leadscrew_t8_8"
	out.append({"id": "cube_220", "name": "Cube Cartesian, Z bed (220 mm)", "blurb": "The Ender 5 / Ultimaker shape: the head moves in X and Y on a crossed gantry, the bed only drops.", "spec": GantryLabSpec.resolve(d)})
	d = GantryLabSpec.for_application("fast_printer")
	d["name"] = "CoreXY 300 (Voron-class)"
	out.append({"id": "corexy_300", "name": "CoreXY 300 enclosed (Voron-class)", "blurb": "Two fixed motors, MGN12 rails, four belted Z motors, an Octopus running Klipper: 300 mm/s at 8 000 mm/s².", "spec": d})
	d = GantryLabSpec.for_application("fast_printer")
	d["name"] = "CoreXY 500 big"
	d["volume"] = {"x_mm": 500.0, "y_mm": 500.0, "z_mm": 500.0}
	d["frame"]["profile"] = "3030"
	d["axis"]["x"]["drive"] = "belt_gt2_9"
	d["axis"]["x"]["motor"] = "nema17_hi"
	d["electronics"]["accel_mm_s2"] = 5000.0
	out.append({"id": "corexy_500", "name": "CoreXY 500 (RatRig-class)", "blurb": "The same pattern at half a metre on 3030: 9 mm belts and high-torque motors, where belt stretch starts to matter.", "spec": GantryLabSpec.resolve(d)})
	d = GantryLabSpec.default_spec("corexz")
	d["name"] = "CoreXZ Switchwire-class"
	d["volume"] = {"x_mm": 250.0, "y_mm": 210.0, "z_mm": 210.0}
	d["frame"]["profile"] = "2020"
	d["axis"]["x"]["guide"] = "mgn12"
	d["axis"]["y"]["guide"] = "mgn12"
	d["axis"]["z"]["guide"] = "mgn12"
	d["electronics"]["board"] = "skr_mini_e3"
	d["electronics"]["max_feed_mm_s"] = 250.0
	d["electronics"]["accel_mm_s2"] = 5000.0
	out.append({"id": "corexz_250", "name": "CoreXZ bed-slinger (Switchwire-class)", "blurb": "CoreXY turned on its side: the belts share X and Z, so Z is as fast as X and there is no lead screw to wobble.", "spec": GantryLabSpec.resolve(d)})
	d = GantryLabSpec.default_spec("delta")
	d["name"] = "Kossel Mini delta"
	d["volume"] = {"x_mm": 170.0, "y_mm": 170.0, "z_mm": 240.0}
	d["frame"]["profile"] = "2020"
	d["delta"] = {"arm_mm": 215.0, "tower_r_mm": 140.0, "effector_r_mm": 32.0, "carriage_r_mm": 20.0}
	d["axis"]["z"]["guide"] = "mgn12"
	d["electronics"]["max_feed_mm_s"] = 200.0
	d["electronics"]["accel_mm_s2"] = 3000.0
	out.append({"id": "kossel_mini", "name": "Kossel Mini delta (Ø170 × 240)", "blurb": "Three 2020 towers, 215 mm arms, MGN12 carriages: the RepRap delta everybody built in 2014.", "spec": GantryLabSpec.resolve(d)})
	d = GantryLabSpec.for_application("vases")
	d["name"] = "Clay delta"
	out.append({"id": "clay_delta", "name": "Clay delta (Ø300 × 500)", "blurb": "A WASP-style clay printer: long arms, a heavy effector with the clay cartridge, slow and tall.", "spec": d})
	# TRONXY X5S (330 × 330 × 400): a 2020 cube, CoreXY on V-wheels across
	# the top, the bed dropping on round shafts — here the X5SA's two Z
	# motors, each screw between two 10 mm shafts.
	d = GantryLabSpec.default_spec("corexy")
	d["name"] = "TRONXY X5S"
	d["volume"] = {"x_mm": 330.0, "y_mm": 330.0, "z_mm": 400.0}
	d["frame"]["profile"] = "2020"
	d["frame"]["gantry_profile"] = "2040"
	d["axis"]["z"]["guide"] = "rod_10"
	d["axis"]["z"]["drive"] = "leadscrew_t8_8"
	d["axis"]["z"]["motors"] = 2
	d["axis"]["z"]["microsteps"] = 8
	d["electronics"]["board"] = "ramps_14"
	d["electronics"]["firmware"] = "marlin"
	d["electronics"]["volts"] = 12
	d["electronics"]["max_feed_mm_s"] = 80.0
	d["electronics"]["accel_mm_s2"] = 1000.0
	out.append({"id": "tronxy_x5s", "name": "TRONXY X5S (330 mm CoreXY)", "blurb": "The 2020 CoreXY cube: V-wheels on the top rails, the bed dropping on four 10 mm shafts with a Tr8 screw and motor on each side.", "spec": GantryLabSpec.resolve(d)})
	# Ender-5 Plus class: a 350 mm Cartesian cube, the bed on two screws.
	d = GantryLabSpec.default_spec("cartesian_xy")
	d["name"] = "Cube Cartesian 350"
	d["volume"] = {"x_mm": 350.0, "y_mm": 350.0, "z_mm": 400.0}
	d["frame"]["profile"] = "2040"
	d["axis"]["z"]["guide"] = "rod_10"
	d["axis"]["z"]["drive"] = "leadscrew_t8_8"
	d["axis"]["z"]["motors"] = 2
	d["electronics"]["board"] = "skr_3"
	d["electronics"]["firmware"] = "marlin"
	out.append({"id": "cube_350", "name": "Cube Cartesian, dual-Z (Ender-5 Plus class, 350 mm)", "blurb": "A big head-moves-XY cube: the 350 mm bed rides four round shafts and two screws, one motor each, so it stays level as it drops.", "spec": GantryLabSpec.resolve(d)})
	# TRONXY X3 (the assembly guide): an i3 bed-slinger on 2020, the bed on
	# V-wheels, two Z motors on M8 threaded rod, the X motor on the left carriage.
	d = GantryLabSpec.default_spec("bedslinger")
	d["name"] = "TRONXY X3"
	d["volume"] = {"x_mm": 220.0, "y_mm": 220.0, "z_mm": 300.0}
	d["frame"]["profile"] = "2020"
	d["frame"]["gantry_profile"] = "2020"
	d["axis"]["z"]["drive"] = "threaded_m8"
	d["axis"]["z"]["motors"] = 2
	d["axis"]["x"]["pulley_teeth"] = 16
	d["axis"]["y"]["pulley_teeth"] = 16
	d["electronics"]["board"] = "ramps_14"
	d["electronics"]["firmware"] = "marlin"
	d["electronics"]["volts"] = 12
	d["electronics"]["max_feed_mm_s"] = 80.0
	d["electronics"]["accel_mm_s2"] = 800.0
	out.append({"id": "tronxy_x3", "name": "TRONXY X3 (220 mm i3 kit)", "blurb": "From the X3 assembly guide: 2020 frame, V-wheel bed, GT2-16 pulleys, two Z motors on M8 threaded rod.", "spec": GantryLabSpec.resolve(d)})
	# The Trash Printer's own flake extruder on the 600 mm shaft-bed cube.
	d = GantryLabSpec.for_application("big_parts")
	d["name"] = "Trash Printer 6 mm flake"
	d["tool"] = {"id": "flake_extruder_6mm", "bed": "alu_plate"}
	d["axis"]["x"]["motor"] = "nema23"
	d["axis"]["y"]["motor"] = "nema23"
	out.append({"id": "trash_flake_600", "name": "Trash Printer, 6 mm flake extruder (600 mm)", "blurb": "The large-format PP / PETE flake head: a 2\" hopper over a heated auger, 6 mm beads in 3 mm layers on a 600 mm bed riding four 12 mm shafts.", "spec": GantryLabSpec.resolve(d)})
	d = GantryLabSpec.for_application("big_parts")
	d["name"] = "Pellet Cartesian 600"
	out.append({"id": "pellet_600", "name": "Pellet-extruder Cartesian (600 mm)", "blurb": "The Trash Printer's head on a 4040 frame: the bed stays still under 1.6 kg of extruder, two Z screws.", "spec": d})
	d = GantryLabSpec.for_application("wood")
	d["name"] = "LEAD-class router 750"
	out.append({"id": "lead_750", "name": "C-Beam router, lead screws (750 mm)", "blurb": "OpenBuilds LEAD 1010 pattern: C-Beam rails, Tr8×8 screws on every axis, two Y motors, a trim router, grblHAL.", "spec": d})
	d = GantryLabSpec.for_application("wood")
	d["name"] = "WorkBee-class router 1000"
	d["volume"] = {"x_mm": 1000.0, "y_mm": 1000.0, "z_mm": 120.0}
	d["axis"]["x"]["drive"] = "ballscrew_1610"
	d["axis"]["y"]["drive"] = "ballscrew_1610"
	d["axis"]["x"]["guide"] = "hgr15"
	d["axis"]["y"]["guide"] = "hgr15"
	d["electronics"]["max_feed_mm_s"] = 80.0
	out.append({"id": "workbee_1000", "name": "Ball-screw router (1000 mm)", "blurb": "The upgrade path: SFU1610 ball screws and HGR15 rails for a metre of travel without whip.", "spec": GantryLabSpec.resolve(d)})
	d = GantryLabSpec.for_application("aluminium")
	d["name"] = "Aluminium mill 600"
	out.append({"id": "alu_mill", "name": "Aluminium mill (600 × 400)", "blurb": "2.2 kW water-cooled spindle on ball screws and HGR15: the stiffness check is the whole design.", "spec": d})
	d = GantryLabSpec.for_application("laser")
	d["name"] = "Laser 400 CoreXY"
	out.append({"id": "laser_400", "name": "Diode laser CoreXY (400 mm)", "blurb": "No cutting force: 2020, V-wheels and a 10 W diode at 400 mm/s; the Z is just focus.", "spec": d})
	d = GantryLabSpec.default_spec("router")
	d["name"] = "Mud gantry 1500"
	d["volume"] = {"x_mm": 1500.0, "y_mm": 1500.0, "z_mm": 800.0}
	d["frame"]["profile"] = "4040"
	d["frame"]["gantry_profile"] = "c_beam_4080"
	d["tool"] = {"id": "clay_extruder", "bed": "none"}
	for k in ["x", "y", "z"]:
		d["axis"][k]["guide"] = "v_wheel"
		d["axis"][k]["drive"] = "belt_gt3_15"
		d["axis"][k]["motor"] = "nema23"
	d["axis"]["y"]["motors"] = 2
	d["axis"]["z"]["drive"] = "leadscrew_t12_3"
	d["electronics"]["board"] = "blackbox_x32"
	d["electronics"]["firmware"] = "grbl"
	d["electronics"]["max_feed_mm_s"] = 60.0
	d["electronics"]["accel_mm_s2"] = 400.0
	out.append({"id": "mud_gantry", "name": "Mud gantry (1.5 m, clay extruder)", "blurb": "The Mud Printer's idea on a router frame: a moving gantry on 4040 rails printing earth onto the ground.", "spec": GantryLabSpec.resolve(d)})
	return out


static func builtin(id: String) -> Dictionary:
	for p in builtins():
		if str(p["id"]) == id:
			return p
	return {}


static func load_library(path: String = LIBRARY_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return []
	var out: Array = []
	for d in (parsed as Dictionary).get("designs", []):
		if d is Dictionary and (d as Dictionary).get("spec") is Dictionary:
			out.append({"id": str(d.get("id", "")), "name": str(d.get("name", "Design")),
				"spec": GantryLabSpec.resolve(d["spec"])})
	return out


static func save_library(designs: Array, path: String = LIBRARY_PATH) -> bool:
	var out: Array = []
	for d in designs:
		out.append({"id": str(d.get("id", "")), "name": str(d.get("name", "Design")),
			"spec": GantryLabSpec.to_json_safe(d.get("spec", {}))})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": out}, "\t"))
	f.close()
	return true
