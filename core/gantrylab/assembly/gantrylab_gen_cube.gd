class_name GantryLabGenCube
extends RefCounted

## The cube family — Cartesian XY head, CoreXY, H-bot — as a build:
##   1. four uprights; X and Y beams butted between them top and bottom,
##      cast corner brackets under the top joints and over the bottom ones,
##      feet under the bottom Y beams;
##   2. a V-wheel plate on the inside face of each top Y beam (stood off
##      11 mm on spacers so the X beam's end bolts fit behind it), the X
##      beam bolted into its tapped ends across the two plates, the X
##      carriage on the X beam's front face, the tool on the carriage;
##   3. the drive. CoreXY: two belts on two decks above the frame — each
##      motor behind a back corner on an L mount whose leg also carries the
##      OTHER belt's back idler, two idlers on the X beam's top slots, two
##      clamps on the carriage's tall back. The belt paths are rectangles,
##      every pulley inside its own turn, the two decks never share a
##      height, so no belt crosses another or itself. H-bot: one belt, both
##      motors. Cartesian: the X motor rides the X beam (belt between the
##      beam and the carriage), one Y belt on the right;
##   4. the bed: two Z plates on the back uprights, cantilever arms bolted
##      into the plates, the bed carriage plate on the arms, the bed on
##      springs; a Tr8 screw beside each back upright, the nut on a block on
##      the Z plate, the Z motor on an L mount on the bottom back beam.

const Y_GAP := 0.011          # Y plates stand off for the X beam's end bolts
const CAR_GAP_X := 0.015      # a Cartesian X carriage makes room for its belt
const FOOT_MIN := 0.011


static func doc(spec: Dictionary) -> Dictionary:
	var s := spec
	var kin := str(s["kinematics"])
	var shared := kin == "corexy" or kin == "hbot"
	var d := GantryLabGen.new_doc(kin)
	var v: Dictionary = s["volume"]
	var vx := float(v["x_mm"]) * 0.001
	var vy := float(v["y_mm"]) * 0.001
	var vz := float(v["z_mm"]) * 0.001
	var fr := str(GantryLabCatalog.PROFILE_REFS.get(str(s["frame"]["profile"]), "vslot_2020"))
	var xr_ref := str(GantryLabCatalog.PROFILE_REFS.get(str(s["frame"]["gantry_profile"]), "vslot_2040"))
	if GantryLabCatalog.profile_wh(xr_ref).y < 0.039:
		xr_ref = "vslot_2040"   # two top slots: one idler line per belt
	var fwh := GantryLabCatalog.profile_wh(fr)
	var wf := fwh.x
	var hf := fwh.y
	var xwh := GantryLabCatalog.profile_wh(xr_ref)
	var x_tall := xwh.x                       # the X beam lies with its w upright
	var x_deep := xwh.y
	var mi_x := GantryLabFrame.motor_index(kin, "x")
	var mi_y := GantryLabFrame.motor_index(kin, "y")
	var mi_z := GantryLabFrame.motor_index(kin, "z")
	var tool_id := str(s["tool"]["id"])
	var bed_kind := str(s["tool"]["bed"])
	var mh := GantryLabFrame.tool_mount_h(tool_id)
	var bw_x := float(GantryLabParts.drive(str(s["axis"]["x"]["drive"])).get("width_mm", 6.0)) * 0.001
	var bw_y := float(GantryLabParts.drive(str(s["axis"]["y"]["drive"])).get("width_mm", 6.0)) * 0.001
	var t_x := int(s["axis"]["x"]["pulley_teeth"])
	var t_y := int(s["axis"]["y"]["pulley_teeth"])
	var xm := str(s["axis"]["x"]["motor"])
	var ym := str(s["axis"]["y"]["motor"])
	var zm := str(s["axis"]["z"]["motor"])
	var ri := GantryLabCatalog.gt2_r(20)
	# The Z motors hang under the bottom back beam: feet tall enough that
	# the longest one stands clear of the floor.
	var zmr := "nema23_mount" if GantryLabCatalog.motor_frame(zm) > 0.05 else "nema17_mount"
	var z_len := float(GantryLabParts.motor(zm)["len_mm"]) * 0.001
	var line_off := 0.0 if hf < 0.03 else hf * 0.5 - 0.01
	var FOOT_H := maxf(FOOT_MIN, z_len - (hf * 0.5 + line_off) - float(GantryLabCatalog.params_of(zmr, {})["a"]) * 0.5 + 0.004)
	var B := Vector2(vx + 0.02, vy + 0.02)
	var stack := 0.0 if bed_kind == "none" else float(GantryLabFrame.BED_STACK.get(bed_kind, 0.01))
	var spring := 0.0 if bed_kind == "none" else GantryLabCatalog.SPRING_H

	# --- Sizes -----------------------------------------------------------
	var car_gap := CAR_GAP_X if not shared else 0.0011
	var x_pull := 0.04 + 0.01               # the outer idler + its flange
	if not shared:
		var xm_half := GantryLabCatalog.motor_frame(xm) * 0.5 + 0.005
		x_pull = 0.038 + xm_half + (0.045 if GantryLabCatalog.nema_cls(xm) == "nema17" else 0.06) + 0.03 + 0.005
	# A wide head (the flake extruder's hopper) must clear the X motor and the
	# idlers at the ends of X travel, and the Y belt over the frame's side.
	var tside := GantryLabFrame.tool_side(tool_id)
	var tsx := 0.0 if tside <= 0.02 else tside - 0.02 + 0.02   # its reach past a hotend's, plus room
	x_pull += tsx
	var cx := vx * 0.5 + x_pull + wf * 0.5 + Y_GAP + 0.006 + 0.003
	var cz := vy * 0.5 + hf * 0.5 + 0.062 + 0.0195 + car_gap + x_deep * 0.5 + 0.003
	# A big head reaching ahead of its nozzle (the flake extruder's hopper)
	# must clear the front top beam at Y = 0: grow the frame front and back.
	cz += maxf(0.0, GantryLabFrame.tool_front(tool_id) - 0.05)
	var arm0 := FOOT_H + hf + 0.09 + vz
	var bed_top0 := arm0 + 0.01 + 0.006 + spring + stack
	var yc := bed_top0 + mh                  # the X beam's (and carriage's) centre
	var H := yc + maxf(hf, x_tall) * 0.5
	var y_top := H - hf * 0.5
	var y_bot := FOOT_H + hf * 0.5
	var up_len := H - FOOT_H

	# --- 1. Frame -------------------------------------------------------------
	var corners := {"LF": Vector2(-cx, -cz), "RF": Vector2(cx, -cz), "LB": Vector2(-cx, cz), "RB": Vector2(cx, cz)}
	for k in corners:
		var c: Vector2 = corners[k]
		GantryLabGen.root(d, "up.%s" % k, fr, {"len": up_len}, GantryLabGen.beam_xf(Vector3(c.x, FOOT_H, c.y), Vector3(c.x, H, c.y), Vector3.BACK),
			{"group": "frame", "label": "Upright"})
	GantryLabGen.twins(d, "up.LF", "up.RF")
	GantryLabGen.twins(d, "up.LB", "up.RB")
	var lines_z := GantryLabCatalog._cells(hf)
	for lvl in ["T", "B"]:
		var yy := y_top if lvl == "T" else y_bot
		# Y beams (left / right), from the front upright's back face.
		for side: float in [-1.0, 1.0]:
			var L := "L" if side < 0 else "R"
			var fu := "up.%sF" % L
			var f_back := GantryLabGen.face_toward(d, fu, Vector3.BACK)
			GantryLabGen.mate_at(d, "yb%s.%s" % [lvl, L], fr, {"len": 2.0 * cz - hf}, fu, f_back, "e0", Vector3(side * cx, yy, -cz + hf * 0.5),
				{Vector3.RIGHT: Vector3.BACK, Vector3.UP: Vector3.UP}, {}, {"group": "frame", "label": "Y beam" if lvl == "T" else "Base Y beam"})
		GantryLabGen.twins(d, "yb%s.L" % lvl, "yb%s.R" % lvl)
		# X beams (front / back) on the uprights' inner slot nearest the inside.
		for fb: float in [-1.0, 1.0]:
			var F := "F" if fb < 0 else "B"
			var lu := "up.L%s" % F
			var f_in := GantryLabGen.face_toward(d, lu, Vector3.RIGHT)
			var zline := fb * cz + (-fb) * (hf * 0.5 - 0.01)
			GantryLabGen.mate_at(d, "xb%s.%s" % [lvl, F], fr, {"len": 2.0 * cx - wf}, lu, f_in, "e0", Vector3(-cx + wf * 0.5, yy, zline),
				{Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.UP}, {}, {"group": "frame", "label": ("Front" if fb < 0 else "Back") + (" top beam" if lvl == "T" else " base beam")})
		# Corner brackets: under the top joints, over the bottom ones.
		var vdir := Vector3.DOWN if lvl == "T" else Vector3.UP
		var ybr := yy + (-hf * 0.5 if lvl == "T" else hf * 0.5)
		for k in corners:
			var c: Vector2 = corners[k]
			var L := str(k).substr(0, 1)
			var F := str(k).substr(1, 1)
			var sx := -1.0 if L == "L" else 1.0
			var sz := -1.0 if F == "F" else 1.0
			var uid := "up.%s" % k
			var yb := "yb%s.%s" % [lvl, L]
			var xb := "xb%s.%s" % [lvl, F]
			GantryLabGen.corner(d, "cy%s.%s" % [lvl, k], uid, GantryLabGen.face_toward(d, uid, Vector3(0, 0, -sz)), yb, GantryLabGen.face_toward(d, yb, vdir),
				Vector3(c.x, ybr, c.y - sz * hf * 0.5), {"group": "frame"})
			var zx := (GantryLabGen.world(d, xb).origin).z
			GantryLabGen.corner(d, "cx%s.%s" % [lvl, k], uid, GantryLabGen.face_toward(d, uid, Vector3(-sx, 0, 0)), xb, GantryLabGen.face_toward(d, xb, vdir),
				Vector3(c.x - sx * wf * 0.5, ybr, zx), {"group": "frame"})
		for pre in ["cy", "cx"]:
			GantryLabGen.twins(d, "%s%s.LF" % [pre, lvl], "%s%s.RF" % [pre, lvl])
			GantryLabGen.twins(d, "%s%s.LB" % [pre, lvl], "%s%s.RB" % [pre, lvl])
	# Feet under the base X beams, inboard of the Z motors' corners.
	for side: float in [-1.0, 1.0]:
		var L := "L" if side < 0 else "R"
		for fb: float in [-1.0, 1.0]:
			var xb := "xbB.%s" % ("F" if fb < 0 else "B")
			GantryLabGen.mate_at(d, "foot.%s%s" % [L, "F" if fb < 0 else "B"], "foot", {"h": FOOT_H}, xb, GantryLabGen.face_toward(d, xb, Vector3.DOWN), "mount",
				Vector3(side * (cx - wf * 0.5 - 0.1), FOOT_H, GantryLabGen.world(d, xb).origin.z), {}, {}, {"group": "frame"})
	GantryLabGen.twins(d, "foot.LF", "foot.RF")
	GantryLabGen.twins(d, "foot.LB", "foot.RB")

	# --- 2. Y plates, X beam, carriage, tool ------------------------------
	d["assemblies"] = {"XBeam": {"parent": "", "axis": "y"}, "XCarriage": {"parent": "XBeam", "axis": "x"}, "Bed": {"parent": "", "axis": "z"}}
	# At tool y = 0 the nozzle stands over the bed's front edge.
	var tip_z := -vy * 0.5
	var xbz := tip_z + GantryLabFrame.tool_mount_back(tool_id) + 0.006 + car_gap + x_deep * 0.5
	for side: float in [-1.0, 1.0]:
		var L := "L" if side < 0 else "R"
		var yb := "ybT.%s" % L
		var fin := GantryLabGen.face_toward(d, yb, Vector3(-side, 0, 0))
		GantryLabGen.mate_at(d, "yplate.%s" % L, "gantry_plate", {"w": 0.08, "d": maxf(0.06, hf + 0.05), "t": 0.006, "off": 0.0, "wheels": 4, "gap": Y_GAP, "wheelbase": 0.05},
			yb, fin, "run", Vector3(side * (cx - wf * 0.5), y_top, xbz), {Vector3.RIGHT: Vector3.BACK},
			{"h": Y_GAP, "motor": mi_y, "sign": 1.0}, {"asm": "XBeam", "label": "Y wheel plate"})
	GantryLabGen.twins(d, "yplate.L", "yplate.R")
	var lp_top := GantryLabGen.feat_world(d, "yplate.L", "top").origin
	var rp_top := GantryLabGen.feat_world(d, "yplate.R", "top").origin
	var xb_len := rp_top.x - lp_top.x
	GantryLabGen.mate_at(d, "xbeam", xr_ref, {"len": xb_len}, "yplate.L", "top", "e0", Vector3(lp_top.x, yc, xbz),
		{Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.BACK}, {}, {"asm": "XBeam", "group": "x_axis", "label": "X beam",
		"also": [{"to": "yplate.R", "tf": "top", "f": "e1"}]})
	var xfront := GantryLabGen.face_toward(d, "xbeam", Vector3.FORWARD)
	var xtop := GantryLabGen.face_toward(d, "xbeam", Vector3.UP)
	var front_z := GantryLabGen.feat_world(d, "xbeam", xfront).origin.z
	var xyc := GantryLabGen.world(d, "xbeam").origin.y
	GantryLabGen.mate_at(d, "xcar", "gantry_plate", {"w": 0.07, "d": 0.12 if shared else 0.09, "t": 0.006, "off": 0.025 if shared else 0.0, "wheels": 4, "gap": car_gap, "wheelbase": 0.05, "tool": true},
		"xbeam", xfront, "run", Vector3(-vx * 0.5, xyc, front_z), {Vector3.RIGHT: Vector3.RIGHT},
		{"h": car_gap, "motor": mi_x, "sign": 1.0}, {"asm": "XCarriage", "label": "X carriage"})
	GantryLabGen.mate(d, "tool", "tool", {"id": tool_id}, "xcar", "tool", "mount", {"turn": 0}, {"label": str(GantryLabParts.tool(tool_id)["label"])})
	var tip := GantryLabGen.world(d, "tool").origin
	var car_back := GantryLabGen.feat_world(d, "xcar", "back").origin.z
	var g0 := GantryLabGen.feat_world(d, "xcar", "back").origin.y   # the back grid's centre row

	# --- 3. Drive ---------------------------------------------------------------
	var xbT := "xbT.B"
	var back_out := GantryLabGen.face_toward(d, xbT, Vector3.BACK)
	var back_line := GantryLabGen.world(d, xbT).origin.y + (0.0 if hf < 0.03 else hf * 0.5 - 0.01)
	var mount_ref := "nema23_mount" if GantryLabCatalog.motor_frame(xm) > 0.05 else "nema17_mount"
	var mt := float(GantryLabCatalog.params_of(mount_ref, {})["t"])
	if shared:
		var x_la := -vx * 0.5 - 0.02 - tsx    # inner idler / motor A's column
		var x_lb := x_la - 0.02               # outer idler / the B belt's column
		# Motors behind the back corners.
		for side: float in [-1.0, 1.0]:
			var M := "A" if side < 0 else "B"
			var mx_ := side * (-x_la) if side > 0 and kin == "hbot" else (x_la if side < 0 else -x_lb)
			GantryLabGen.mate_at(d, "mount.%s" % M, mount_ref, {}, xbT, back_out, "base", Vector3(mx_, back_line, GantryLabGen.feat_world(d, xbT, back_out).origin.z),
				{Vector3.RIGHT: Vector3.DOWN, Vector3.UP: Vector3.BACK}, {}, {"label": "Motor %s mount" % M})
			GantryLabGen.mate(d, "motor.%s" % M, xm, {"shaft": 0.024}, "mount.%s" % M, "motor", "face", {"turn": 0}, {"label": "Motor %s" % M})
		if kin == "hbot":
			GantryLabGen.twins(d, "mount.A", "mount.B")
			GantryLabGen.twins(d, "motor.A", "motor.B")
		var leg_top := GantryLabGen.feat_world(d, "mount.A", "leg").origin.y
		var shaft0 := GantryLabGen.feat_world(d, "motor.A", "shaft").origin.y
		var s_a := (leg_top + 0.0005) - shaft0
		var deck_a := shaft0 + s_a + GantryLabCatalog.pulley_band_y(bw_x)
		var deck_b := deck_a + bw_x + 0.005
		var mzA := GantryLabGen.world(d, "motor.A").origin.z
		var hbot := kin == "hbot"
		GantryLabGen.mate(d, "pulley.A", "gt2_pulley", {"teeth": t_x, "belt_w": bw_x, "bore": GantryLabCatalog.shaft_d(xm)}, "motor.A", "shaft", "bore", {"s": s_a},
			{"spin": GantryLabGen.spin(0, TAU * GantryLabCatalog.gt2_r(t_x) * 1000.0, 1.0), "label": "Pulley A"})
		GantryLabGen.mate(d, "pulley.B", "gt2_pulley", {"teeth": t_x, "belt_w": bw_x, "bore": GantryLabCatalog.shaft_d(xm)}, "motor.B", "shaft", "bore",
			{"s": s_a + (0.0 if hbot else bw_x + 0.005)}, {"spin": GantryLabGen.spin(1, TAU * GantryLabCatalog.gt2_r(t_x) * 1000.0, 1.0), "label": "Pulley B"})
		# The idlers on the X beam's top slots (front line A, back line B).
		var xt := GantryLabGen.feat_world(d, "xbeam", xtop)
		var lines_x: PackedFloat32Array = GantryLabCatalog.feature(xr_ref, {"len": xb_len}, xtop).get("lines", PackedFloat32Array())
		var line_f := xbz - absf(float(lines_x[0])) if lines_x.size() > 1 else xbz
		var line_b := xbz + absf(float(lines_x[0])) if lines_x.size() > 1 else xbz
		var _xt := xt
		for side: float in [-1.0, 1.0]:
			var L := "L" if side < 0 else "R"
			GantryLabGen.mate_at(d, "idlerA.%s" % L, "gt2_idler", {"teeth": 20, "belt_w": bw_x}, "xbeam", xtop, "bore", Vector3(side * -x_la, yc + x_tall * 0.5, line_f),
				{}, {"h": 0.0, "auto": true}, {"label": "Belt A idler"})
			if not hbot:
				GantryLabGen.mate_at(d, "idlerB.%s" % L, "gt2_idler", {"teeth": 20, "belt_w": bw_x}, "xbeam", xtop, "bore", Vector3(side * -x_lb, yc + x_tall * 0.5, line_b),
					{}, {"h": 0.0, "auto": true}, {"label": "Belt B idler"})
		GantryLabGen.twins(d, "idlerA.L", "idlerA.R")
		if not hbot:
			GantryLabGen.twins(d, "idlerB.L", "idlerB.R")
			# The other belt's back idler on each motor's leg.
			var legA := GantryLabGen.feat_world(d, "mount.A", "leg").origin
			var legB := GantryLabGen.feat_world(d, "mount.B", "leg").origin
			GantryLabGen.mate_at(d, "backB", "gt2_idler", {"teeth": 20, "belt_w": bw_x}, "mount.A", "leg", "bore", Vector3(x_lb, legA.y, mzA), {}, {"h": 0.0, "auto": true}, {"label": "Belt B back idler"})
			GantryLabGen.mate_at(d, "backA", "gt2_idler", {"teeth": 20, "belt_w": bw_x}, "mount.B", "leg", "bore", Vector3(-x_la, legB.y, mzA), {}, {"h": 0.0, "auto": true}, {"label": "Belt A back idler"})
		# Clamps on the carriage's back, one per deck, reaching each X run.
		var r := GantryLabCatalog.gt2_r(t_x)
		for M in (["A"] if hbot else ["A", "B"]):
			var deck := deck_a if M == "A" else deck_b
			var zrun := (line_f if M == "A" else line_b) - ri
			var row := g0 + roundf((deck - g0) / GantryLabCatalog.GRID) * GantryLabCatalog.GRID
			GantryLabGen.mate_at(d, "clamp.%s" % M, "belt_clamp", {"h": (zrun - car_back) + 0.003, "w": 0.014, "d": 0.008, "grip": Vector2(0.0, -(deck - row))},
				"xcar", "back", "mount", Vector3(-vx * 0.5, row, car_back), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.BACK}, {}, {"label": "Belt %s clamp" % M})
		var _r := r
		if hbot:
			d["loops"].append({"name": "Belt", "motor": 0, "sign": 1.0, "belt_w": bw_x, "nodes": [
				{"part": "pulley.A", "s": -1.0, "kind": "pulley"}, {"part": "idlerA.L", "s": -1.0, "kind": "idler"}, {"part": "clamp.A", "s": 0.0, "kind": "clamp"},
				{"part": "idlerA.R", "s": -1.0, "kind": "idler"}, {"part": "pulley.B", "s": -1.0, "kind": "pulley"}]})
		else:
			d["loops"].append({"name": "Belt A", "motor": 0, "sign": 1.0, "belt_w": bw_x, "nodes": [
				{"part": "pulley.A", "s": -1.0, "kind": "pulley"}, {"part": "idlerA.L", "s": -1.0, "kind": "idler"}, {"part": "clamp.A", "s": 0.0, "kind": "clamp"},
				{"part": "idlerA.R", "s": -1.0, "kind": "idler"}, {"part": "backA", "s": -1.0, "kind": "idler"}]})
			d["loops"].append({"name": "Belt B", "motor": 1, "sign": 1.0, "belt_w": bw_x, "nodes": [
				{"part": "pulley.B", "s": 1.0, "kind": "pulley"}, {"part": "idlerB.R", "s": 1.0, "kind": "idler"}, {"part": "clamp.B", "s": 0.0, "kind": "clamp"},
				{"part": "idlerB.L", "s": 1.0, "kind": "idler"}, {"part": "backB", "s": 1.0, "kind": "idler"}]})
	else:
		# Cartesian: the X motor rides the X beam's left end, the belt runs
		# between the beam and the carriage; one Y belt on the right.
		var xm_cls := GantryLabCatalog.nema_cls(xm)
		var xm_half := GantryLabCatalog.motor_frame(xm) * 0.5 + 0.005
		var xm_reach := 0.045 if xm_cls == "nema17" else 0.06
		var xp := -vx * 0.5 - 0.038 - xm_half - tsx
		GantryLabGen.mate_at(d, "xmplate", "nema17_plate", {"cls": xm_cls, "pat": GantryLabCatalog.nema_pattern(xm_cls), "reach": xm_reach, "half": xm_half}, "xbeam", xfront, "mount",
			Vector3(xp - xm_reach, xyc, front_z), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.FORWARD}, {"h": 0.02}, {"asm": "XBeam", "label": "X motor plate"})
		GantryLabGen.mate(d, "xmotor", xm, {"shaft": 0.02}, "xmplate", "motor", "face", {"turn": 0}, {"label": "X motor"})
		var shaft_o := GantryLabGen.feat_world(d, "xmotor", "shaft").origin.z
		var band_z := front_z - car_gap * 0.6
		GantryLabGen.mate(d, "xpulley", "gt2_pulley", {"teeth": t_x, "belt_w": bw_x, "bore": GantryLabCatalog.shaft_d(xm)}, "xmotor", "shaft", "bore",
			{"s": maxf(0.0, (shaft_o - band_z) - GantryLabCatalog.pulley_band_y(bw_x))}, {"spin": GantryLabGen.spin(mi_x, TAU * GantryLabCatalog.gt2_r(t_x) * 1000.0, 1.0), "label": "X pulley"})
		var y_c := GantryLabGen.world(d, "xmotor").origin.y
		GantryLabGen.mate_at(d, "xidler", "gt2_idler", {"teeth": 20, "belt_w": bw_x}, "xbeam", xfront, "bore", Vector3(vx * 0.5 + 0.075 + tsx, y_c, front_z), {}, {"h": 0.0, "auto": true}, {"label": "X idler"})
		var xband: Vector3 = GantryLabAssembly.band_of(GantryLabGen.part(d, "xpulley"), GantryLabGen.world(d, "xpulley"))["c"]
		var top_run := xband.y + GantryLabCatalog.gt2_r(t_x)
		var row := g0 + roundf((top_run - g0) / GantryLabCatalog.GRID) * GantryLabCatalog.GRID
		GantryLabGen.mate_at(d, "xclamp", "belt_clamp", {"h": (xband.z - car_back) + 0.003, "w": 0.016, "d": 0.009, "grip": Vector2(0.0, -(top_run - row))}, "xcar", "back", "mount",
			Vector3(-vx * 0.5, row, car_back), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.BACK}, {}, {"label": "X belt clamp"})
		d["loops"].append({"name": "X belt", "motor": mi_x, "sign": 1.0, "belt_w": bw_x,
			"nodes": [{"part": "xpulley", "s": -1.0, "kind": "pulley"}, {"part": "xclamp", "s": 0.0, "kind": "clamp"}, {"part": "xidler", "s": -1.0, "kind": "idler"}]})
		# Y: motor behind the back-right corner, idler on the front top beam,
		# the clamp on the X beam's top.
		var y_x := vx * 0.5 + 0.02 + tsx
		var ymount_ref := "nema23_mount" if GantryLabCatalog.motor_frame(ym) > 0.05 else "nema17_mount"
		GantryLabGen.mate_at(d, "ymount", ymount_ref, {}, xbT, back_out, "base", Vector3(y_x, back_line, GantryLabGen.feat_world(d, xbT, back_out).origin.z),
			{Vector3.RIGHT: Vector3.DOWN, Vector3.UP: Vector3.BACK}, {}, {"label": "Y motor mount"})
		GantryLabGen.mate(d, "ymotor", ym, {"shaft": 0.024}, "ymount", "motor", "face", {"turn": 0}, {"label": "Y motor"})
		var leg_top2 := GantryLabGen.feat_world(d, "ymount", "leg").origin.y
		var sh0 := GantryLabGen.feat_world(d, "ymotor", "shaft").origin.y
		# A little higher up the shaft: the belt clears the carriage's top edge.
		GantryLabGen.mate(d, "ypulley", "gt2_pulley", {"teeth": t_y, "belt_w": bw_y, "bore": GantryLabCatalog.shaft_d(ym)}, "ymotor", "shaft", "bore", {"s": (leg_top2 + 0.0005) - sh0 + 0.006},
			{"spin": GantryLabGen.spin(mi_y, TAU * GantryLabCatalog.gt2_r(t_y) * 1000.0, 1.0), "label": "Y pulley"})
		var yband: Vector3 = GantryLabAssembly.band_of(GantryLabGen.part(d, "ypulley"), GantryLabGen.world(d, "ypulley"))["c"]
		var ftop := GantryLabGen.face_toward(d, "xbT.F", Vector3.UP)
		GantryLabGen.mate_at(d, "yidler", "gt2_idler", {"teeth": 20, "belt_w": bw_y}, "xbT.F", ftop, "bore", Vector3(yband.x, H, GantryLabGen.world(d, "xbT.F").origin.z),
			{}, {"h": 0.0, "auto": true}, {"label": "Y idler"})
		var yr := GantryLabCatalog.gt2_r(t_y)
		var run_x := yband.x - yr
		var xt2 := GantryLabGen.feat_world(d, "xbeam", xtop).origin.y
		var lines2: PackedFloat32Array = GantryLabCatalog.feature(xr_ref, {"len": xb_len}, xtop).get("lines", PackedFloat32Array())
		var cl_z := xbz + absf(float(lines2[0])) if lines2.size() > 0 else xbz
		GantryLabGen.mate_at(d, "yclamp", "belt_clamp", {"h": (yband.y - xt2) + 0.003, "w": 0.012, "d": 0.012, "grip": Vector2(0.0, 0.0)}, "xbeam", xtop, "mount",
			Vector3(run_x, xt2, cl_z), {}, {}, {"asm": "XBeam", "label": "Y belt clamp"})
		d["loops"].append({"name": "Y belt", "motor": mi_y, "sign": 1.0, "belt_w": bw_y,
			"nodes": [{"part": "ypulley", "s": 1.0, "kind": "pulley"}, {"part": "yidler", "s": 1.0, "kind": "idler"}, {"part": "yclamp", "s": 0.0, "kind": "clamp"}]})

	# --- 4. Bed and Z -----------------------------------------------------------
	var z_dr := GantryLabParts.drive(str(s["axis"]["z"]["drive"]))
	var z_lead := float(z_dr.get("lead_mm", 8.0)) * 0.001
	var z_count := clampi(int(s["axis"]["z"]["motors"]), 1, 2)
	var z_guide := str(s["axis"]["z"]["guide"])
	if z_guide.begins_with("rod_"):
		_rod_bed(d, s, {"cx": cx, "cz": cz, "wf": wf, "hf": hf, "fr": fr, "y_top": y_top, "y_bot": y_bot, "H": H, "FOOT_H": FOOT_H,
			"arm0": arm0, "B": B, "bed_kind": bed_kind, "zm": zm, "mi_z": mi_z, "z_lead": z_lead, "z_count": z_count, "z_guide": z_guide,
			"yplate_d": maxf(0.06, hf + 0.05)})
	else:
		_wheel_bed(d, s, {"cx": cx, "cz": cz, "wf": wf, "hf": hf, "y_top": y_top, "y_bot": y_bot, "arm0": arm0, "B": B, "bed_kind": bed_kind,
			"zm": zm, "mi_z": mi_z, "z_lead": z_lead, "z_count": z_count})
		if z_guide != "v_wheel":
			d["issues"].append({"level": "warn", "text": "Z guide %s is not modelled on this frame yet: the bed is drawn on V-wheels. Round shafts (8 / 10 / 12 mm) are." % str(GantryLabParts.guide(z_guide)["label"]), "parts": [], "note": true})
	if int(s["axis"]["z"]["motors"]) > 2:
		d["issues"].append({"level": "warn", "text": "%d Z motors: this frame draws two (one per side); three- and four-point beds are not modelled yet." % int(s["axis"]["z"]["motors"]), "parts": [], "note": true})
	if str(s["frame"].get("corners", "bracket")) != "bracket":
		d["issues"].append({"level": "warn", "text": "Corners: %s are not drawn yet; the frame is built with cast corner brackets." % str(GantryLabSpec.CORNER_LABELS.get(str(s["frame"]["corners"]), "")).to_lower(), "parts": [], "note": true})
	for k in ["x", "y"]:
		if str(s["axis"][k]["guide"]) != "v_wheel":
			d["issues"].append({"level": "warn", "text": "%s guide %s is not modelled on the V-slot frame yet: drawn as V-wheels on the slot." % [k.to_upper(), str(GantryLabParts.guide(str(s["axis"][k]["guide"]))["label"])], "parts": [], "note": true})

	# --- Electronics, extruder, spool ------------------------------------------
	_extras(d, s, tool_id, cx, cz, wf, hf, H, FOOT_H)
	if bool(s["frame"].get("enclosed", false)):
		_enclosure(d, cx, cz, wf, hf, H, FOOT_H)
	_modules(d, kin, shared, z_guide.begins_with("rod_"), z_count)

	d["meta"] = {"mirror_x": 0.0, "moving": {"x": "XCarriage", "y": "XBeam", "z": "Bed"},
		"spans": {"x_beam_m": xb_len, "y_rail_m": 2.0 * cz - hf, "z_col_m": float(d.get("_zcol", up_len))},
		"anchors": {"hx": cx, "hz": cz, "h": H, "pw": wf, "xb_y": yc, "xb_len": xb_len, "bed_top": bed_top0, "vy": vy},
		"bed": {"size": B, "kind": bed_kind}, "bead_parent": "Bed", "bead_origin": Vector3(tip.x, bed_top0, -vy * 0.5)}
	d.erase("_zcol")
	return GantryLabGen.finish(d)


## The V-wheel lowering bed: Z plates on the back uprights, cantilever arms,
## a Tr8 beside each back upright with its motor on the bottom back beam.
static func _wheel_bed(d: Dictionary, s: Dictionary, g: Dictionary) -> void:
	var cx: float = g["cx"]
	var cz: float = g["cz"]
	var wf: float = g["wf"]
	var hf: float = g["hf"]
	var y_top: float = g["y_top"]
	var y_bot: float = g["y_bot"]
	var arm0: float = g["arm0"]
	var B: Vector2 = g["B"]
	var bed_kind: String = g["bed_kind"]
	var zm: String = g["zm"]
	var mi_z: int = g["mi_z"]
	var z_lead: float = g["z_lead"]
	var z_count: int = g["z_count"]
	# The Z plate reaches in past the upright to the screw's column: far
	# enough that the motor's L mount clears the beam's end.
	var off := ceilf((wf * 0.5 + 0.026) / GantryLabCatalog.GRID) * GantryLabCatalog.GRID
	for side: float in [-1.0, 1.0]:
		var L := "L" if side < 0 else "R"
		var uid := "up.%sB" % L
		var uf := GantryLabGen.face_toward(d, uid, Vector3.FORWARD)
		GantryLabGen.mate_at(d, "zplate.%s" % L, "gantry_plate", {"w": 0.09, "d": 2.0 * off + 0.072, "t": 0.006, "off": off, "wheels": 4, "gap": 0.0011, "wheelbase": 0.06},
			uid, uf, "run", Vector3(side * cx, arm0, cz - hf * 0.5), {Vector3.BACK: Vector3(-side, 0, 0)},
			{"h": 0.0011, "motor": mi_z, "sign": side}, {"asm": "Bed", "label": "Z gantry plate"})
	GantryLabGen.twins(d, "zplate.L", "zplate.R")
	var zp_front := GantryLabGen.feat_world(d, "zplate.R", "top").origin.z
	var arm_len := (zp_front) - (-B.y * 0.5 + 0.01)
	var ax := cx - off - 0.03
	for side: float in [-1.0, 1.0]:
		var L := "L" if side < 0 else "R"
		GantryLabGen.mate_at(d, "arm.%s" % L, "vslot_2020", {"len": arm_len}, "zplate.%s" % L, "top", "e0", Vector3(side * ax, arm0, zp_front),
			{Vector3.RIGHT: Vector3.FORWARD, Vector3.UP: Vector3.UP}, {}, {"group": "bed", "label": "Bed arm"})
	GantryLabGen.twins(d, "arm.L", "arm.R")
	var arm_top := GantryLabGen.feat_world(d, "arm.L", GantryLabGen.face_toward(d, "arm.L", Vector3.UP))
	var bp_w := maxf(B.x, 2.0 * (ax + 0.015))
	var bed_cz := -B.y * 0.5 + 0.01 + arm_len * 0.0
	bed_cz = 0.0
	GantryLabGen.mate_at(d, "bedplate", "bed_plate", {"w": bp_w, "d": B.y, "t": 0.006, "mount_x": ax, "bed": B}, "arm.L", GantryLabGen.face_toward(d, "arm.L", Vector3.UP), "mount",
		Vector3(-ax, arm_top.origin.y, bed_cz), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.UP}, {}, {"label": "Bed carriage plate",
		"also": [{"to": "arm.R", "tf": GantryLabGen.face_toward(d, "arm.R", Vector3.UP), "f": "mount_r"}]})
	if bed_kind != "none":
		GantryLabGen.mate(d, "bed", "bed", {"kind": bed_kind, "size": B}, "bedplate", "springs", "springs", {"turn": 0}, {"label": str(GantryLabParts.bed(bed_kind)["label"])})
	var zmount_ref := "nema23_mount" if GantryLabCatalog.motor_frame(zm) > 0.05 else "nema17_mount"
	var zb_in := GantryLabGen.face_toward(d, "xbB.B", Vector3.FORWARD)
	var zb_face_z := GantryLabGen.feat_world(d, "xbB.B", zb_in).origin.z
	var zmb := float(GantryLabCatalog.params_of(zmount_ref, {})["b"])
	var zmt := float(GantryLabCatalog.params_of(zmount_ref, {})["t"])
	var screw_z := zb_face_z - zmt - zmb * 0.5
	var base_line := y_bot + (0.0 if hf < 0.03 else hf * 0.5 - 0.01)
	for i in z_count:
		var side := -1.0 if i == 0 else 1.0
		var L := "L" if side < 0 else "R"
		GantryLabGen.mate_at(d, "ztab.%s" % L, "nut_tab", {"reach": zp_front - screw_z}, "zplate.%s" % L, "top", "base",
			Vector3(side * (cx - off), arm0 - 0.03, zp_front), {Vector3.UP: Vector3.UP, Vector3.BACK: Vector3.FORWARD}, {}, {"asm": "Bed", "label": "Z nut block"})
		GantryLabGen.mate(d, "znut.%s" % L, "tr8_nut", {}, "ztab.%s" % L, "nut", "flange", {"turn": 0}, {"label": "Z nut"})
		var nut_c := GantryLabGen.world(d, "znut.%s" % L).origin
		GantryLabGen.mate_at(d, "zmount.%s" % L, zmount_ref, {}, "xbB.B", zb_in, "base", Vector3(nut_c.x, base_line, zb_face_z),
			{Vector3.RIGHT: Vector3.DOWN, Vector3.UP: Vector3.FORWARD}, {}, {"label": "Z motor mount"})
		GantryLabGen.mate(d, "zmotor.%s" % L, zm, {"shaft": 0.024}, "zmount.%s" % L, "motor", "face", {"turn": 0}, {"label": "Z motor"})
		GantryLabGen.mate(d, "zcoupler.%s" % L, "coupler", {"bore": GantryLabCatalog.shaft_d(zm)}, "zmotor.%s" % L, "shaft", "bore", {"s": zmt + 0.001},
			{"spin": GantryLabGen.spin(mi_z, z_lead * 1000.0, 1.0), "label": "Z coupler"})
		var c_top := GantryLabGen.feat_world(d, "zcoupler.%s" % L, "top").origin.y
		GantryLabGen.mate(d, "zscrew.%s" % L, "tr8_screw", {"len": y_top - hf * 0.5 - 0.02 - c_top, "lead": z_lead, "d": float(GantryLabParts.drive(str(s["axis"]["z"]["drive"])).get("d_mm", 8.0)) * 0.001}, "zcoupler.%s" % L, "top", "bore", {"s": 0.0},
			{"spin": GantryLabGen.spin(mi_z, z_lead * 1000.0, 1.0), "label": "Z lead screw"})
		d["coax"].append(["zscrew.%s" % L, "znut.%s" % L])
	if z_count == 2:
		for pre in ["ztab", "znut", "zmount", "zmotor", "zcoupler", "zscrew"]:
			GantryLabGen.twins(d, "%s.L" % pre, "%s.R" % pre)



## The shaft-guided lowering bed (the Tronxy X5SA / Ender-5 Plus kind): on
## each side a Tr8 screw stands between two round shafts, one in front of it
## and one behind at the same distance. The shafts stand in SK supports on
## the base side beam and on a Z top beam that runs under the Y wheel plates;
## a Z carriage plate rides both shafts on two flange bearings hung under it
## and carries the lead nut on top; the bed arm lies on the plate. Two motors
## (or one, on the left) hang under the base side beams on L mounts.
static func _rod_bed(d: Dictionary, s: Dictionary, g: Dictionary) -> void:
	var cx: float = g["cx"]
	var cz: float = g["cz"]
	var wf: float = g["wf"]
	var hf: float = g["hf"]
	var fr: String = g["fr"]
	var y_top: float = g["y_top"]
	var y_bot: float = g["y_bot"]
	var arm0: float = g["arm0"]
	var B: Vector2 = g["B"]
	var bed_kind: String = g["bed_kind"]
	var zm: String = g["zm"]
	var mi_z: int = g["mi_z"]
	var z_lead: float = g["z_lead"]
	var z_count: int = g["z_count"]
	var rod_d := {"rod_8": 0.008, "rod_10": 0.010, "rod_12": 0.012}.get(str(g["z_guide"]), 0.008) as float
	var refs := GantryLabCatalog.rod_refs(rod_d)
	var dm := GantryLabCatalog.rod_dims(rod_d)
	var sk_h := float(dm["sk_h"])
	var sk_t := float(dm["sk_t"])
	var line_off := 0.0 if hf < 0.03 else hf * 0.5 - 0.01
	# Z top beams, clear under the Y wheel plates.
	var y_zt := y_top - float(g["yplate_d"]) * 0.5 - 0.006 - hf * 0.5
	for side: float in [-1.0, 1.0]:
		var L := "L" if side < 0 else "R"
		var fu := "up.%sF" % L
		GantryLabGen.mate_at(d, "zt.%s" % L, fr, {"len": 2.0 * cz - hf}, fu, GantryLabGen.face_toward(d, fu, Vector3.BACK), "e0", Vector3(side * cx, y_zt, -cz + hf * 0.5),
			{Vector3.RIGHT: Vector3.BACK, Vector3.UP: Vector3.UP}, {}, {"group": "frame", "label": "Z top beam"})
	GantryLabGen.twins(d, "zt.L", "zt.R")
	for k in ["LF", "RF", "LB", "RB"]:
		var L := str(k).substr(0, 1)
		var sx := -1.0 if L == "L" else 1.0
		var sz := -1.0 if str(k).substr(1, 1) == "F" else 1.0
		var uid := "up.%s" % k
		var zt := "zt.%s" % L
		GantryLabGen.corner(d, "czt.%s" % k, uid, GantryLabGen.face_toward(d, uid, Vector3(0, 0, -sz)), zt, GantryLabGen.face_toward(d, zt, Vector3.DOWN),
			Vector3(sx * cx, y_zt - hf * 0.5, sz * cz - sz * hf * 0.5), {"group": "frame"})
	GantryLabGen.twins(d, "czt.LF", "czt.RF")
	GantryLabGen.twins(d, "czt.LB", "czt.RB")
	var zmount_ref := "nema23_mount" if GantryLabCatalog.motor_frame(zm) > 0.05 else "nema17_mount"
	var zmt := float(GantryLabCatalog.params_of(zmount_ref, {})["t"])
	var zmb := float(GantryLabCatalog.params_of(zmount_ref, {})["b"])
	var zmw := float(GantryLabCatalog.params_of(zmount_ref, {})["w"])
	var screw_in := zmt + zmb * 0.5                # the screw's distance in from the beam face
	var rdx := screw_in - sk_h                     # the shafts sit this much nearer the face
	var rs := clampf(B.y * 0.5, maxf(0.12, zmw + float(dm["sk_w"]) + 0.012), 0.42)
	var base_line := y_bot + line_off
	var zt_line := y_zt + line_off
	var rod_len := (zt_line + sk_t * 0.5) - (base_line - sk_t * 0.5)
	d["_zcol"] = rod_len
	var face_x0 := absf(GantryLabGen.feat_world(d, "ybB.R", GantryLabGen.face_toward(d, "ybB.R", Vector3.LEFT)).origin.x)
	var screw_x := face_x0 - screw_in
	# The arm's slot line on the plate's 10 mm grid, clear of the nut flange.
	var bed_edge := B.x * 0.5 - 0.02
	var arm_in := maxf(0.03, ceilf((screw_x - bed_edge) / GantryLabCatalog.GRID - 0.001) * GantryLabCatalog.GRID)
	var ax := screw_x - arm_in
	var plate_t := 0.008
	var zc := 0.0
	for side: float in [-1.0, 1.0]:
		var L := "L" if side < 0 else "R"
		var yb := "ybB.%s" % L
		var fin := GantryLabGen.face_toward(d, yb, Vector3(-side, 0, 0))
		var face_x := GantryLabGen.feat_world(d, yb, fin).origin.x
		var zt := "zt.%s" % L
		var fin_t := GantryLabGen.face_toward(d, zt, Vector3(-side, 0, 0))
		# The shafts, front and back of the screw.
		for fb: float in [-1.0, 1.0]:
			var F := "F" if fb < 0 else "B"
			var rz := zc + fb * rs * 0.5
			GantryLabGen.mate_at(d, "skb%s.%s" % [F, L], str(refs["sk"]), {"d": rod_d}, yb, fin, "base", Vector3(face_x, base_line, rz),
				{Vector3.UP: Vector3.UP}, {}, {"label": "Shaft support (base)"})
			GantryLabGen.mate(d, "rod%s.%s" % [F, L], str(refs["rod"]), {"len": rod_len, "d": rod_d}, "skb%s.%s" % [F, L], "clamp", "end", {"s": 0.0},
				{"label": "Z guide shaft"})
			GantryLabGen.mate_at(d, "skt%s.%s" % [F, L], str(refs["sk"]), {"d": rod_d}, zt, fin_t, "base", Vector3(face_x, zt_line, rz),
				{Vector3.UP: Vector3.UP}, {}, {"label": "Shaft support (top)"})
			d["coax"].append(["rod%s.%s" % [F, L], "skt%s.%s" % [F, L]])
		# The carriage plate on the shaft its bore lands on (left: the back
		# one, right: the front one — the plate is turned half round).
		var bore_rod := "rodB.%s" % L if side < 0 else "rodF.%s" % L
		var rw := GantryLabGen.world(d, bore_rod).origin
		GantryLabGen.mate_at(d, "zcar.%s" % L, "z_carriage", {"rod_d": rod_d, "rs": rs, "rdx": rdx, "reach": arm_in + 0.016, "t": plate_t},
			bore_rod, "rod", "bore", Vector3(rw.x, arm0 - 0.01 - plate_t, rw.z), {Vector3.RIGHT: Vector3(side, 0, 0), Vector3.UP: Vector3.UP},
			{}, {"asm": "Bed", "label": "Z carriage plate"})
		for i in 2:
			var bid := "brg%d.%s" % [i, L]
			GantryLabGen.mate(d, bid, str(refs["lmf"]), {"d": rod_d}, "zcar.%s" % L, "brg%d" % i, "flange", {"turn": 0}, {"label": "Flange linear bearing"})
			var bw := GantryLabGen.world(d, bid).origin
			var rf := GantryLabGen.world(d, "rodF.%s" % L).origin
			var rb := GantryLabGen.world(d, "rodB.%s" % L).origin
			var on := "rodF.%s" % L if Vector2(bw.x - rf.x, bw.z - rf.z).length() < Vector2(bw.x - rb.x, bw.z - rb.z).length() else "rodB.%s" % L
			d["coax"].append([on, bid])
		var has_motor := side < 0 or z_count >= 2
		if has_motor:
			GantryLabGen.mate(d, "znut.%s" % L, "tr8_nut", {}, "zcar.%s" % L, "nut", "flange", {"turn": 0}, {"label": "Z nut"})
			GantryLabGen.mate_at(d, "zmount.%s" % L, zmount_ref, {}, yb, fin, "base", Vector3(face_x, base_line, zc),
				{Vector3.RIGHT: Vector3.DOWN, Vector3.UP: Vector3(-side, 0, 0)}, {}, {"label": "Z motor mount"})
			GantryLabGen.mate(d, "zmotor.%s" % L, zm, {"shaft": 0.024}, "zmount.%s" % L, "motor", "face", {"turn": 0}, {"label": "Z motor"})
			GantryLabGen.mate(d, "zcoupler.%s" % L, "coupler", {"bore": GantryLabCatalog.shaft_d(zm)}, "zmotor.%s" % L, "shaft", "bore", {"s": zmt + 0.001},
				{"spin": GantryLabGen.spin(mi_z, z_lead * 1000.0, 1.0), "label": "Z coupler"})
			var c_top := GantryLabGen.feat_world(d, "zcoupler.%s" % L, "top").origin.y
			GantryLabGen.mate(d, "zscrew.%s" % L, "tr8_screw", {"len": (y_zt - hf * 0.5 - 0.004) - c_top, "lead": z_lead, "d": float(GantryLabParts.drive(str(s["axis"]["z"]["drive"])).get("d_mm", 8.0)) * 0.001}, "zcoupler.%s" % L, "top", "bore", {"s": 0.0},
				{"spin": GantryLabGen.spin(mi_z, z_lead * 1000.0, 1.0), "label": "Z lead screw"})
			d["coax"].append(["zscrew.%s" % L, "znut.%s" % L])
		# The bed arm on the plate, front to back under the bed's edge.
		var zt_top := GantryLabGen.feat_world(d, "zcar.%s" % L, "top").origin.y
		GantryLabGen.mate_at(d, "arm.%s" % L, "vslot_2020", {"len": B.y}, "zcar.%s" % L, "top", "-y", Vector3(side * ax, zt_top, -B.y * 0.5),
			{Vector3.RIGHT: Vector3.BACK, Vector3.UP: Vector3.UP}, {}, {"group": "bed", "label": "Bed arm"})
	for pre in ["zt", "skbF", "skbB", "rodF", "rodB", "sktF", "sktB", "zcar", "brg0", "brg1", "arm"]:
		GantryLabGen.twins(d, "%s.L" % pre, "%s.R" % pre)
	if z_count >= 2:
		for pre in ["znut", "zmount", "zmotor", "zcoupler", "zscrew"]:
			GantryLabGen.twins(d, "%s.L" % pre, "%s.R" % pre)
	var arm_top := GantryLabGen.feat_world(d, "arm.L", GantryLabGen.face_toward(d, "arm.L", Vector3.UP))
	var bp_w := maxf(B.x, 2.0 * (ax + 0.015))
	GantryLabGen.mate_at(d, "bedplate", "bed_plate", {"w": bp_w, "d": B.y, "t": 0.006, "mount_x": ax, "bed": B}, "arm.L", GantryLabGen.face_toward(d, "arm.L", Vector3.UP), "mount",
		Vector3(-ax, arm_top.origin.y, 0.0), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.UP}, {}, {"label": "Bed carriage plate",
		"also": [{"to": "arm.R", "tf": GantryLabGen.face_toward(d, "arm.R", Vector3.UP), "f": "mount_r"}]})
	if bed_kind != "none":
		GantryLabGen.mate(d, "bed", "bed", {"kind": bed_kind, "size": B}, "bedplate", "springs", "springs", {"turn": 0}, {"label": str(GantryLabParts.bed(bed_kind)["label"])})
	if z_count < 2:
		d["issues"].append({"level": "warn", "text": "One Z motor drives only the left screw: the right side of the bed hangs on its shafts alone and will tilt. Set two Z motors.", "parts": ["zcar.R"]})


static func _extras(d: Dictionary, s: Dictionary, tool_id: String, cx: float, cz: float, wf: float, hf: float, H: float, FOOT_H: float) -> void:
	var additive := str(GantryLabParts.tool(tool_id)["material"]) == "filament"
	if additive:
		var ex_c := Vector3(-cx - wf * 0.5 - 0.05, H - 0.05, 0.0)
		var ex_b := Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK)
		GantryLabGen.free_part(d, "extruder", "Bowden extruder", Transform3D(ex_b, ex_c),
			[{"kind": "extruder", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.042, 0.06, 0.05), "pick_c": Vector3(0, 0, 0.02)}], 0.45)
		d["links"].append({"kind": "bowden", "a": {"part": "extruder", "at": GantryLabDetail.EXTRUDER_OUTLET}, "b": {"part": "tool", "at": Vector3(0, GantryLabDetail.HOTEND_H + 0.0135, 0)},
			"ta": Vector3.DOWN, "tb": Vector3.UP, "r": 0.002})
	var board := GantryLabParts.board(str(s["electronics"]["board"]))
	GantryLabGen.free_part(d, "board", str(board["label"]), Transform3D(Basis.IDENTITY, Vector3(0, FOOT_H + hf + 0.001, cz - 0.07)),
		[{"kind": "board", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.11, 0.0016, 0.09), "drivers": int(board["drivers"])}], 0.1)
	GantryLabGen.free_part(d, "psu", "Power supply", Transform3D(Basis.IDENTITY, Vector3(0, FOOT_H + 0.026, -cz - wf * 0.5 - 0.075)),
		[{"kind": "psu", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.215, 0.05, 0.115)}], 0.9)


## Acrylic panels on the two sides and the back, standing just outside
## everything that hangs off the frame (the CoreXY motors behind the back
## corners, the Bowden extruder on the left).
static func _enclosure(d: Dictionary, cx: float, cz: float, wf: float, hf: float, H: float, FOOT_H: float) -> void:
	var y0 := FOOT_H
	var h := H - FOOT_H
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p in d["parts"]:
		var pd: Dictionary = p
		var o: Vector3 = GantryLabGen.world(d, str(pd["id"])).origin
		var r := 0.0
		if bool(pd.get("free", false)):
			for dd in pd.get("draw", []):
				r = maxf(r, ((dd as Dictionary).get("s", Vector3.ZERO) as Vector3).length() * 0.5)
		lo = lo.min(o - Vector3.ONE * r)
		hi = hi.max(o + Vector3.ONE * r)
	var side_x := maxf(cx + wf * 0.5, maxf(absf(lo.x), absf(hi.x)) + 0.01) + 0.004
	var back_z := maxf(cz + wf * 0.5, hi.z + 0.06) + 0.004
	for side: float in [-1.0, 1.0]:
		GantryLabGen.free_part(d, "panel.%s" % ("L" if side < 0 else "R"), "Enclosure panel", Transform3D(Basis.IDENTITY, Vector3(side * side_x, y0 + h * 0.5, 0.0)),
			[{"kind": "panel", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.003, h, 2.0 * cz + wf)}], 0.0, {"enclosure": true})
	GantryLabGen.free_part(d, "panel.B", "Enclosure panel", Transform3D(Basis.IDENTITY, Vector3(0.0, y0 + h * 0.5, back_z)),
		[{"kind": "panel", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(2.0 * side_x, h, 0.003)}], 0.0, {"enclosure": true})


## The machine's modules (what the part editor selects first): the frame, the
## XY gantry, each motor's drive, each side's Z axis (its drive, guides and
## carriage), the bed. Twin modules move mirrored.
static func _modules(d: Dictionary, kin: String, shared: bool, rod: bool, z_count: int) -> void:
	var frame: Array = []
	for p in d["parts"]:
		var pd: Dictionary = p
		if str(pd.get("group", "")) == "frame":
			frame.append(str(pd["id"]))
	GantryLabGen.module(d, "frame", "Frame", frame, "")
	var gantry := ["yplate.L", "yplate.R", "xbeam", "xcar", "tool", "idlerA.L", "idlerA.R", "idlerB.L", "idlerB.R", "clamp.A", "clamp.B", "xmplate", "xmotor", "xpulley", "xidler", "xclamp", "yclamp"]
	GantryLabGen.module(d, "gantry", "XY gantry", gantry, "yplate.L")
	if shared:
		GantryLabGen.module(d, "drive.A", "Motor A drive", ["mount.A", "motor.A", "pulley.A", "backB"], "mount.A")
		GantryLabGen.module(d, "drive.B", "Motor B drive", ["mount.B", "motor.B", "pulley.B", "backA"], "mount.B")
		if kin == "hbot":
			GantryLabGen.twin_modules(d, "drive.A", "drive.B")
	else:
		GantryLabGen.module(d, "drive.Y", "Y drive", ["ymount", "ymotor", "ypulley"], "ymount")
	for L in ["L", "R"]:
		var lbl := "left" if L == "L" else "right"
		GantryLabGen.module(d, "zdrive.%s" % L, "Z drive (%s)" % lbl, ["zmount.%s" % L, "zmotor.%s" % L, "zcoupler.%s" % L, "zscrew.%s" % L, "znut.%s" % L, "ztab.%s" % L], "zmount.%s" % L)
		if rod:
			GantryLabGen.module(d, "zguide.%s" % L, "Z guide shafts (%s)" % lbl, ["skbF.%s" % L, "skbB.%s" % L, "rodF.%s" % L, "rodB.%s" % L, "sktF.%s" % L, "sktB.%s" % L], "skbF.%s" % L)
			GantryLabGen.module(d, "zcarr.%s" % L, "Z carriage (%s)" % lbl, ["zcar.%s" % L, "brg0.%s" % L, "brg1.%s" % L], "zcar.%s" % L)
			GantryLabGen.module(d, "zaxis.%s" % L, "Z axis (%s)" % lbl, [], "zmount.%s" % L if (L == "L" or z_count >= 2) else "skbF.%s" % L,
				["zdrive.%s" % L, "zguide.%s" % L, "zcarr.%s" % L])
	for pre in (["zdrive", "zguide", "zcarr", "zaxis"] if rod else ["zdrive"]):
		GantryLabGen.twin_modules(d, "%s.L" % pre, "%s.R" % pre)
	GantryLabGen.module(d, "bed", "Bed", ["arm.L", "arm.R", "bedplate", "bed", "zplate.L", "zplate.R"], "")
	GantryLabGen.module(d, "electronics", "Electronics", ["board", "psu", "extruder", "panel.L", "panel.R", "panel.B"], "")
