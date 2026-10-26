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
	var cx := vx * 0.5 + x_pull + wf * 0.5 + Y_GAP + 0.006 + 0.003
	var cz := vy * 0.5 + hf * 0.5 + 0.062 + 0.0195 + car_gap + x_deep * 0.5 + 0.003
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
	var xbz := tip_z + 0.0135 + 0.006 + car_gap + x_deep * 0.5
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
		var x_la := -vx * 0.5 - 0.02          # inner idler / motor A's column
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
		var xp := -vx * 0.5 - 0.038 - xm_half
		GantryLabGen.mate_at(d, "xmplate", "nema17_plate", {"cls": xm_cls, "pat": GantryLabCatalog.nema_pattern(xm_cls), "reach": xm_reach, "half": xm_half}, "xbeam", xfront, "mount",
			Vector3(xp - xm_reach, xyc, front_z), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.FORWARD}, {"h": 0.02}, {"asm": "XBeam", "label": "X motor plate"})
		GantryLabGen.mate(d, "xmotor", xm, {"shaft": 0.02}, "xmplate", "motor", "face", {"turn": 0}, {"label": "X motor"})
		var shaft_o := GantryLabGen.feat_world(d, "xmotor", "shaft").origin.z
		var band_z := front_z - car_gap * 0.6
		GantryLabGen.mate(d, "xpulley", "gt2_pulley", {"teeth": t_x, "belt_w": bw_x, "bore": GantryLabCatalog.shaft_d(xm)}, "xmotor", "shaft", "bore",
			{"s": maxf(0.0, (shaft_o - band_z) - GantryLabCatalog.pulley_band_y(bw_x))}, {"spin": GantryLabGen.spin(mi_x, TAU * GantryLabCatalog.gt2_r(t_x) * 1000.0, 1.0), "label": "X pulley"})
		var y_c := GantryLabGen.world(d, "xmotor").origin.y
		GantryLabGen.mate_at(d, "xidler", "gt2_idler", {"teeth": 20, "belt_w": bw_x}, "xbeam", xfront, "bore", Vector3(vx * 0.5 + 0.075, y_c, front_z), {}, {"h": 0.0, "auto": true}, {"label": "X idler"})
		var xband: Vector3 = GantryLabAssembly.band_of(GantryLabGen.part(d, "xpulley"), GantryLabGen.world(d, "xpulley"))["c"]
		var top_run := xband.y + GantryLabCatalog.gt2_r(t_x)
		var row := g0 + roundf((top_run - g0) / GantryLabCatalog.GRID) * GantryLabCatalog.GRID
		GantryLabGen.mate_at(d, "xclamp", "belt_clamp", {"h": (xband.z - car_back) + 0.003, "w": 0.016, "d": 0.009, "grip": Vector2(0.0, -(top_run - row))}, "xcar", "back", "mount",
			Vector3(-vx * 0.5, row, car_back), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.BACK}, {}, {"label": "X belt clamp"})
		d["loops"].append({"name": "X belt", "motor": mi_x, "sign": 1.0, "belt_w": bw_x,
			"nodes": [{"part": "xpulley", "s": -1.0, "kind": "pulley"}, {"part": "xclamp", "s": 0.0, "kind": "clamp"}, {"part": "xidler", "s": -1.0, "kind": "idler"}]})
		# Y: motor behind the back-right corner, idler on the front top beam,
		# the clamp on the X beam's top.
		var y_x := vx * 0.5 + 0.02
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
		GantryLabGen.mate(d, "zscrew.%s" % L, "tr8_screw", {"len": y_top - hf * 0.5 - 0.02 - c_top, "lead": z_lead, "d": 0.008}, "zcoupler.%s" % L, "top", "bore", {"s": 0.0},
			{"spin": GantryLabGen.spin(mi_z, z_lead * 1000.0, 1.0), "label": "Z lead screw"})
		d["coax"].append(["zscrew.%s" % L, "znut.%s" % L])
	if z_count == 2:
		for pre in ["ztab", "znut", "zmount", "zmotor", "zcoupler", "zscrew"]:
			GantryLabGen.twins(d, "%s.L" % pre, "%s.R" % pre)

	# --- Electronics, extruder, spool ------------------------------------------
	var additive := str(GantryLabParts.tool(tool_id)["process"]) == "additive" and tool_id != "clay_extruder" and tool_id != "pellet_extruder"
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

	d["meta"] = {"mirror_x": 0.0, "moving": {"x": "XCarriage", "y": "XBeam", "z": "Bed"},
		"spans": {"x_beam_m": xb_len, "y_rail_m": 2.0 * cz - hf, "z_col_m": up_len},
		"anchors": {"hx": cx, "hz": cz, "h": H, "pw": wf, "xb_y": yc, "xb_len": xb_len, "bed_top": bed_top0, "vy": vy},
		"bed": {"size": B, "kind": bed_kind}, "bead_parent": "Bed", "bead_origin": Vector3(tip.x, bed_top0, -vy * 0.5)}
	return GantryLabGen.finish(d)
