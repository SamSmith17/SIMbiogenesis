class_name GantryLabGenSlinger
extends RefCounted

## The bed-slinger (Ender / CR-10 pattern) as a build, in kit-manual order:
##   1. the base: two side beams, front and back cross beams butted between
##      them, cast corner brackets in the four inside corners (top and bottom
##      slot), feet under the side beams;
##   2. two 2020 Y rails butted between the cross beams, flush with the top;
##   3. the Y motor on a NEMA L mount on the back cross beam's inside face,
##      a GT2 pulley on its shaft; the Y idler on a T-nut bolt on top of the
##      front cross beam, stood on spacers up to the pulley's belt plane;
##   4. the uprights stood on the side beams (corner brackets front and
##      back), a 2020 top beam between them;
##   5. a V-wheel gantry plate on each upright (the 6 mm eccentric spacer
##      puts the plate 1.1 mm off the face), a lead-screw nut block on each,
##      the Z motors on L mounts on the side beams, couplers, Tr8 screws;
##   6. the X beam bolted flat across the Z plates' hole grids; the X
##      carriage on its wheels (long spacers make room for the belt between
##      it and the beam), the hotend on the carriage; the X motor on a
##      standoff plate at the left end, the X idler on the beam's face at the
##      right, a belt clamp on the carriage's back;
##   7. two gantry plates on the Y rails, the bed carriage plate across
##      them, the bed on four springs; a belt clamp under the plate.
## Every number below is a slot line, a hole, or a stack of real parts.

const GAP_STD := 0.0011        # plate off the face with the 6 mm eccentric spacer
const GANTRY_GAP_X := 0.015    # the X carriage stands off for the belt
const XMOTOR_STANDOFF := 0.02


static func doc(spec: Dictionary) -> Dictionary:
	var s := spec
	var d := GantryLabGen.new_doc(str(s["kinematics"]))
	var v: Dictionary = s["volume"]
	var vx := float(v["x_mm"]) * 0.001
	var vy := float(v["y_mm"]) * 0.001
	var vz := float(v["z_mm"]) * 0.001
	var pf := str(s["frame"]["profile"])
	var gf := str(s["frame"]["gantry_profile"])
	# The base must be at least 40 tall to hide the Y motor; uprights and the
	# X beam are V-slot 20-series.
	var base_ref := str(GantryLabCatalog.PROFILE_REFS.get(pf, "vslot_2040"))
	if GantryLabCatalog.profile_wh(base_ref).y < 0.039:
		base_ref = "vslot_2040"
	var g_ref := str(GantryLabCatalog.PROFILE_REFS.get(gf, "vslot_2040"))
	var up_ref := g_ref if GantryLabCatalog.profile_wh(g_ref).y >= 0.039 else "vslot_2040"
	var bwh := GantryLabCatalog.profile_wh(base_ref)
	var bw := bwh.x
	var bh := bwh.y
	var uwh := GantryLabCatalog.profile_wh(up_ref)
	var gwh := GantryLabCatalog.profile_wh(g_ref)
	var kin := str(s["kinematics"])
	var mi_x := GantryLabFrame.motor_index(kin, "x")
	var mi_y := GantryLabFrame.motor_index(kin, "y")
	var mi_z := GantryLabFrame.motor_index(kin, "z")
	var tool_id := str(s["tool"]["id"])
	var bed_kind := str(s["tool"]["bed"])
	var ym := str(s["axis"]["y"]["motor"])
	var xm := str(s["axis"]["x"]["motor"])
	var zm := str(s["axis"]["z"]["motor"])
	var y_len := float(GantryLabParts.motor(ym)["len_mm"]) * 0.001
	var foot_h := maxf(0.011, y_len - 0.03)
	var T := foot_h + bh
	var gz := 0.0
	var B := Vector2(vx + 0.02, vy + 0.02)
	var mh := GantryLabFrame.tool_mount_h(tool_id)
	var bw_x := float(GantryLabParts.drive(str(s["axis"]["x"]["drive"])).get("width_mm", 6.0)) * 0.001
	var bw_y := float(GantryLabParts.drive(str(s["axis"]["y"]["drive"])).get("width_mm", 6.0)) * 0.001
	var t_x := int(s["axis"]["x"]["pulley_teeth"])
	var t_y := int(s["axis"]["y"]["pulley_teeth"])
	# The Z screw stands off the upright by the L mount's reach.
	var zmount_ref := "nema23_mount" if GantryLabCatalog.motor_frame(zm) > 0.05 else "nema17_mount"
	var zmb := float(GantryLabCatalog.params_of(zmount_ref, {})["b"])
	var zmt0 := float(GantryLabCatalog.params_of(zmount_ref, {})["t"])
	var sc := bw * 0.5 + zmt0 + zmb * 0.5   # screw axis inboard of the upright's centre
	var plate_off := sc - GantryLabCatalog.GRID
	var plate_d := 2.0 * plate_off + 0.072
	# The X beam reaches past the carriage's travel by the motor plate.
	var xm_cls := GantryLabCatalog.nema_cls(xm)
	var xm_half := GantryLabCatalog.motor_frame(xm) * 0.5 + 0.005
	var xm_reach := 0.045 if xm_cls == "nema17" else 0.06
	# A wide head (the flake extruder's hopper) clears the X motor and idler.
	var tside := GantryLabFrame.tool_side(tool_id)
	var tsx := 0.0 if tside <= 0.02 else tside - 0.02 + 0.02
	var xp := -vx * 0.5 - 0.038 - xm_half - tsx
	var x_margin := maxf(0.13, 0.038 + xm_half + xm_reach + 0.035) + tsx
	var S := vx * 0.5 + x_margin + sc + 0.014
	var xe := S - (sc + 0.014)              # X beam half length
	# The nozzle sits in front of the gantry: upright half depth, Z plate,
	# X beam, the carriage's standoff and plate, the hotend's mount.
	var z_tip := gz - (uwh.y * 0.5 + GAP_STD + 0.006 + gwh.x + GANTRY_GAP_X + 0.006 + GantryLabFrame.tool_mount_back(tool_id))
	var L_rail := vy + 0.17
	var zb := z_tip
	var Lb := L_rail + 2.0 * bw
	# Y rails clear of the Y motor between them.
	var ym_half := GantryLabCatalog.motor_frame(ym) * 0.5
	var ry := maxf(B.x * 0.5 - 0.04, ym_half + 0.004 + 0.0325)
	var bp_w := maxf(B.x, 2.0 * (ry + 0.0325))
	var cross_len := 2.0 * S - bw

	# --- 1. Base -----------------------------------------------------------
	for side: float in [-1.0, 1.0]:
		var id := "side.%s" % ("L" if side < 0 else "R")
		GantryLabGen.root(d, id, base_ref, {"len": Lb},
			GantryLabGen.beam_xf(Vector3(side * S, T - bh * 0.5, zb - Lb * 0.5), Vector3(side * S, T - bh * 0.5, zb + Lb * 0.5), Vector3.UP),
			{"group": "base", "label": "Side rail"})
	GantryLabGen.twins(d, "side.L", "side.R")
	for fb: float in [-1.0, 1.0]:
		var id := "cross.%s" % ("F" if fb < 0 else "B")
		var zc := zb + fb * (L_rail * 0.5 + bw * 0.5)
		var inner := GantryLabGen.face_toward(d, "side.L", Vector3.RIGHT)
		GantryLabGen.mate_at(d, id, base_ref, {"len": cross_len}, "side.L", inner, "e0",
			Vector3(-S + bw * 0.5, T - bh * 0.5, zc), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.UP}, {}, {"group": "base", "label": "Front cross beam" if fb < 0 else "Back cross beam"})
	# Corner brackets in the inside corners, one per slot line.
	var lines_y := _cells(bh)
	for fb: float in [-1.0, 1.0]:
		var cid := "cross.%s" % ("F" if fb < 0 else "B")
		var cin := GantryLabGen.face_toward(d, cid, Vector3(0, 0, -fb))
		var zf := zb + fb * L_rail * 0.5
		for side: float in [-1.0, 1.0]:
			var sid := "side.%s" % ("L" if side < 0 else "R")
			var sin_ := GantryLabGen.face_toward(d, sid, Vector3(-side, 0, 0))
			for li in lines_y.size():
				var yy := T - bh * 0.5 + float(lines_y[li])
				var bid := "corner.%s%s%d" % ["F" if fb < 0 else "B", "L" if side < 0 else "R", li]
				GantryLabGen.corner(d, bid, sid, sin_, cid, cin, Vector3(side * (S - bw * 0.5), yy, zf), {"group": "base"})
		for li in lines_y.size():
			GantryLabGen.twins(d, "corner.%sL%d" % ["F" if fb < 0 else "B", li], "corner.%sR%d" % ["F" if fb < 0 else "B", li])
	for side: float in [-1.0, 1.0]:
		var sid := "side.%s" % ("L" if side < 0 else "R")
		for e: float in [-1.0, 1.0]:
			var fid := "foot.%s%s" % ["L" if side < 0 else "R", "F" if e < 0 else "B"]
			GantryLabGen.mate_at(d, fid, "foot", {"h": foot_h}, sid, "-y", "mount", Vector3(side * S, foot_h, zb + e * (Lb * 0.5 - 0.03)), {}, {}, {"group": "base"})
	for e in ["F", "B"]:
		GantryLabGen.twins(d, "foot.L%s" % e, "foot.R%s" % e)

	# --- 2. Y rails ----------------------------------------------------------
	var front_in := GantryLabGen.face_toward(d, "cross.F", Vector3.BACK)
	for side: float in [-1.0, 1.0]:
		var rid := "yrail.%s" % ("L" if side < 0 else "R")
		GantryLabGen.mate_at(d, rid, "vslot_2020", {"len": L_rail}, "cross.F", front_in, "e0",
			Vector3(side * ry, T - 0.01, zb - L_rail * 0.5), {Vector3.RIGHT: Vector3.BACK, Vector3.UP: Vector3.UP}, {}, {"group": "base", "label": "Y rail"})
		var out_face := GantryLabGen.face_toward(d, rid, Vector3(side, 0, 0))
		for fb: float in [-1.0, 1.0]:
			var cid := "cross.%s" % ("F" if fb < 0 else "B")
			var cin := GantryLabGen.face_toward(d, cid, Vector3(0, 0, -fb))
			GantryLabGen.corner(d, "ycorner.%s%s" % ["L" if side < 0 else "R", "F" if fb < 0 else "B"], rid, out_face, cid, cin,
				Vector3(side * (ry + 0.01), T - 0.01, zb + fb * L_rail * 0.5), {"group": "base"})
	GantryLabGen.twins(d, "yrail.L", "yrail.R")
	GantryLabGen.twins(d, "ycorner.LF", "ycorner.RF")
	GantryLabGen.twins(d, "ycorner.LB", "ycorner.RB")

	# --- 3. Y drive ----------------------------------------------------------
	var ymount_ref := "nema23_mount" if GantryLabCatalog.motor_frame(ym) > 0.05 else "nema17_mount"
	var back_in := GantryLabGen.face_toward(d, "cross.B", Vector3.FORWARD)
	var low_line := T - bh * 0.5 + float(lines_y[0]) if lines_y.size() > 1 else T - 0.01
	GantryLabGen.mate_at(d, "ymount", ymount_ref, {}, "cross.B", back_in, "base",
		Vector3(0, low_line, zb + L_rail * 0.5), {Vector3.RIGHT: Vector3.DOWN, Vector3.UP: Vector3.FORWARD}, {}, {"label": "Y motor mount"})
	GantryLabGen.mate(d, "ymotor", ym, {"shaft": 0.024}, "ymount", "motor", "face", {"turn": 0}, {"label": "Y motor"})
	var ymt := float(GantryLabCatalog.params_of(ymount_ref, {})["t"])
	GantryLabGen.mate(d, "ypulley", "gt2_pulley", {"teeth": t_y, "belt_w": bw_y, "bore": GantryLabCatalog.shaft_d(ym)}, "ymotor", "shaft", "bore",
		{"s": ymt - 0.0005, "anchor": "start"}, {"spin": GantryLabGen.spin(mi_y, TAU * GantryLabCatalog.gt2_r(t_y) * 1000.0, 1.0), "label": "Y pulley"})
	var yband := GantryLabAssembly.band_of(GantryLabGen.part(d, "ypulley"), GantryLabGen.world(d, "ypulley"))
	var y_b: float = (yband["c"] as Vector3).y
	# The bed carriage stands high enough for the belt to run under it.
	var gap_y := maxf(GAP_STD, y_b + bw_y * 0.5 + 0.002 + 0.003 - T - 0.006)
	GantryLabGen.mate_at(d, "yidler", "gt2_idler", {"teeth": 20, "belt_w": bw_y}, "cross.F", "+y", "bore",
		Vector3(0, T, zb - L_rail * 0.5 - bw * 0.5), {}, {"h": 0.0, "auto": true}, {"label": "Y idler"})

	# --- 4. Uprights ---------------------------------------------------------
	var bed_stack := 0.0 if bed_kind == "none" else float(GantryLabFrame.BED_STACK.get(bed_kind, 0.01))
	var bed_top := T + gap_y + 0.006 + 0.006 + (0.0 if bed_kind == "none" else GantryLabCatalog.SPRING_H + bed_stack)
	var xb_y := bed_top + mh
	var U := xb_y + vz + 0.1 - T
	for side: float in [-1.0, 1.0]:
		var sid := "side.%s" % ("L" if side < 0 else "R")
		var uid := "upright.%s" % ("L" if side < 0 else "R")
		GantryLabGen.mate_at(d, uid, up_ref, {"len": U}, sid, "+y", "e0", Vector3(side * S, T, gz),
			{Vector3.RIGHT: Vector3.UP, Vector3.UP: Vector3.BACK}, {}, {"group": "gantry", "label": "Upright"})
		for fb: float in [-1.0, 1.0]:
			var uf := GantryLabGen.face_toward(d, uid, Vector3(0, 0, fb))
			GantryLabGen.corner(d, "ucorner.%s%s" % ["L" if side < 0 else "R", "F" if fb < 0 else "B"], sid, "+y", uid, uf,
				Vector3(side * S, T, gz + fb * uwh.y * 0.5), {"group": "gantry"})
	GantryLabGen.twins(d, "upright.L", "upright.R")
	GantryLabGen.twins(d, "ucorner.LF", "ucorner.RF")
	GantryLabGen.twins(d, "ucorner.LB", "ucorner.RB")
	var u_in := GantryLabGen.face_toward(d, "upright.L", Vector3.RIGHT)
	GantryLabGen.mate_at(d, "topbeam", "vslot_2020", {"len": 2.0 * S - uwh.x}, "upright.L", u_in, "e0",
		Vector3(-S + uwh.x * 0.5, T + U - 0.01, gz + uwh.y * 0.5 - 0.01), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.UP}, {}, {"group": "gantry", "label": "Top beam"})
	for side: float in [-1.0, 1.0]:
		var uid := "upright.%s" % ("L" if side < 0 else "R")
		var uin := GantryLabGen.face_toward(d, uid, Vector3(-side, 0, 0))
		GantryLabGen.corner(d, "tcorner.%s" % ("L" if side < 0 else "R"), uid, uin, "topbeam", GantryLabGen.face_toward(d, "topbeam", Vector3.DOWN),
			Vector3(side * (S - uwh.x * 0.5), T + U - 0.02, gz + uwh.y * 0.5 - 0.01), {"group": "gantry"})
	GantryLabGen.twins(d, "tcorner.L", "tcorner.R")

	# --- 5. Z plates, nut blocks, Z motors, screws -------------------------
	d["assemblies"] = {"XBeam": {"parent": "", "axis": "z"}, "XCarriage": {"parent": "XBeam", "axis": "x"}, "Bed": {"parent": "", "axis": "y"}}
	var z_dr := GantryLabParts.drive(str(s["axis"]["z"]["drive"]))
	var z_lead := float(z_dr.get("lead_mm", 8.0)) * 0.001
	var two_z := clampi(int(s["axis"]["z"]["motors"]), 1, 2) == 2
	for side: float in [-1.0, 1.0]:
		var L := "L" if side < 0 else "R"
		var uid := "upright.%s" % L
		var uf := GantryLabGen.face_toward(d, uid, Vector3.FORWARD)
		GantryLabGen.mate_at(d, "zplate.%s" % L, "gantry_plate",
			{"w": 0.09, "d": plate_d, "t": 0.006, "off": plate_off, "wheels": 4, "gap": GAP_STD, "wheelbase": 0.06},
			uid, uf, "run", Vector3(side * S, xb_y, gz - uwh.y * 0.5), {Vector3.BACK: Vector3(-side, 0, 0)},
			{"h": GAP_STD, "motor": mi_z, "sign": side}, {"asm": "XBeam", "label": "Z gantry plate"})
	GantryLabGen.twins(d, "zplate.L", "zplate.R")
	var plate_front := GantryLabGen.feat_world(d, "zplate.R", "top").origin.z
	var zs := plate_front - 0.016
	for side: float in [-1.0, 1.0]:
		var L := "L" if side < 0 else "R"
		if not two_z and side > 0:
			continue
		GantryLabGen.mate_at(d, "ztab.%s" % L, "nut_tab", {"reach": 0.016}, "zplate.%s" % L, "top", "base",
			Vector3(side * (S - sc), xb_y - 0.04, plate_front), {Vector3.UP: Vector3.UP, Vector3.BACK: Vector3.FORWARD}, {}, {"asm": "XBeam", "label": "Z nut block"})
		GantryLabGen.mate(d, "znut.%s" % L, "tr8_nut", {}, "ztab.%s" % L, "nut", "flange", {"turn": 0}, {"label": "Z nut"})
		var sid := "side.%s" % L
		var sin_ := GantryLabGen.face_toward(d, sid, Vector3(-side, 0, 0))
		var nut_c := GantryLabGen.world(d, "znut.%s" % L).origin
		var up_line := T - bh * 0.5 + float(lines_y[lines_y.size() - 1])
		GantryLabGen.mate_at(d, "zmount.%s" % L, zmount_ref, {}, sid, sin_, "base", Vector3(side * (S - bw * 0.5), up_line, nut_c.z),
			{Vector3.RIGHT: Vector3.DOWN, Vector3.UP: Vector3(-side, 0, 0)}, {}, {"label": "Z motor mount"})
		GantryLabGen.mate(d, "zmotor.%s" % L, zm, {"shaft": 0.024}, "zmount.%s" % L, "motor", "face", {"turn": 0}, {"label": "Z motor"})
		var zmt := float(GantryLabCatalog.params_of(zmount_ref, {})["t"])
		GantryLabGen.mate(d, "zcoupler.%s" % L, "coupler", {"bore": GantryLabCatalog.shaft_d(zm)}, "zmotor.%s" % L, "shaft", "bore", {"s": zmt + 0.001},
			{"spin": GantryLabGen.spin(mi_z, z_lead * 1000.0, 1.0), "label": "Z coupler"})
		var c_top := GantryLabGen.feat_world(d, "zcoupler.%s" % L, "top").origin.y
		GantryLabGen.mate(d, "zscrew.%s" % L, "tr8_screw", {"len": T + U - 0.03 - c_top, "lead": z_lead, "d": float(GantryLabParts.drive(str(s["axis"]["z"]["drive"])).get("d_mm", 8.0)) * 0.001}, "zcoupler.%s" % L, "top", "bore", {"s": 0.0},
			{"spin": GantryLabGen.spin(mi_z, z_lead * 1000.0, 1.0), "label": "Z lead screw"})
		d["coax"].append(["zscrew.%s" % L, "znut.%s" % L])
	if two_z:
		for pre in ["ztab", "znut", "zmount", "zmotor", "zcoupler", "zscrew"]:
			GantryLabGen.twins(d, "%s.L" % pre, "%s.R" % pre)

	# --- 6. X beam, carriage, tool, X drive ---------------------------------
	GantryLabGen.mate_at(d, "xbeam", g_ref, {"len": 2.0 * xe}, "zplate.L", "top", "+z", Vector3(-xe, xb_y, plate_front),
		{Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.UP}, {}, {"asm": "XBeam", "group": "x_axis", "label": "X beam",
		"also": [{"to": "zplate.R", "tf": "top", "f": "+z"}]})
	var xfront := GantryLabGen.face_toward(d, "xbeam", Vector3.FORWARD)
	var front_z := GantryLabGen.feat_world(d, "xbeam", xfront).origin.z
	GantryLabGen.mate_at(d, "xcar", "gantry_plate", {"w": 0.07, "d": 0.09, "t": 0.006, "off": 0.0, "wheels": 4, "gap": GANTRY_GAP_X, "wheelbase": 0.05, "tool": true},
		"xbeam", xfront, "run", Vector3(-vx * 0.5, xb_y, front_z), {Vector3.RIGHT: Vector3.RIGHT},
		{"h": GANTRY_GAP_X, "motor": mi_x, "sign": 1.0}, {"asm": "XCarriage", "label": "X carriage"})
	GantryLabGen.mate(d, "tool", "tool", {"id": tool_id}, "xcar", "tool", "mount", {"turn": 0}, {"label": str(GantryLabParts.tool(tool_id)["label"])})
	var xmp_params := {"cls": xm_cls, "pat": GantryLabCatalog.nema_pattern(xm_cls), "reach": xm_reach, "half": xm_half}
	GantryLabGen.mate_at(d, "xmplate", "nema17_plate", xmp_params, "xbeam", xfront, "mount",
		Vector3(xp - float(xmp_params["reach"]), xb_y, front_z), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.FORWARD},
		{"h": XMOTOR_STANDOFF}, {"label": "X motor plate"})
	GantryLabGen.mate(d, "xmotor", xm, {"shaft": 0.02}, "xmplate", "motor", "face", {"turn": 0}, {"label": "X motor"})
	# The pulley's band in the gap between the beam and the carriage.
	var shaft_o := GantryLabGen.feat_world(d, "xmotor", "shaft").origin.z
	var band_z := front_z - GANTRY_GAP_X * 0.6
	var s_x := (shaft_o - band_z) - GantryLabCatalog.pulley_band_y(bw_x)
	GantryLabGen.mate(d, "xpulley", "gt2_pulley", {"teeth": t_x, "belt_w": bw_x, "bore": GantryLabCatalog.shaft_d(xm)}, "xmotor", "shaft", "bore",
		{"s": maxf(0.0, s_x), "anchor": "start"}, {"spin": GantryLabGen.spin(mi_x, TAU * GantryLabCatalog.gt2_r(t_x) * 1000.0, 1.0), "label": "X pulley"})
	# The idler level with the pulley, on the same slot line.
	var y_c := GantryLabGen.world(d, "xmotor").origin.y
	GantryLabGen.mate_at(d, "xidler", "gt2_idler", {"teeth": 20, "belt_w": bw_x}, "xbeam", xfront, "bore",
		Vector3(vx * 0.5 + 0.075 + tsx, y_c, front_z), {}, {"h": 0.0, "auto": true}, {"label": "X idler"})
	# The clamp on the carriage's back, gripping the top run.
	var xr := GantryLabCatalog.gt2_r(t_x)
	var xband := GantryLabAssembly.band_of(GantryLabGen.part(d, "xpulley"), GantryLabGen.world(d, "xpulley"))
	var xband_c: Vector3 = xband["c"]
	var car_back := GantryLabGen.feat_world(d, "xcar", "back").origin.z
	var clamp_h := (xband_c.z - car_back) + 0.003
	var top_run := xband_c.y + xr
	var row := xb_y + roundf((top_run - xb_y) / GantryLabCatalog.GRID) * GantryLabCatalog.GRID
	GantryLabGen.mate_at(d, "xclamp", "belt_clamp", {"h": clamp_h, "w": 0.016, "d": 0.009, "grip": Vector2(0.0, -(top_run - row))}, "xcar", "back", "mount",
		Vector3(-vx * 0.5, row, car_back), {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.BACK}, {}, {"label": "X belt clamp"})
	d["loops"].append({"name": "X belt", "motor": mi_x, "sign": 1.0, "belt_w": bw_x,
		"nodes": [{"part": "xpulley", "s": -1.0, "kind": "pulley"}, {"part": "xclamp", "s": 0.0, "kind": "clamp"}, {"part": "xidler", "s": -1.0, "kind": "idler"}]})

	# --- 7. Bed --------------------------------------------------------------
	var tip := GantryLabGen.world(d, "tool").origin
	for side: float in [-1.0, 1.0]:
		var L := "L" if side < 0 else "R"
		GantryLabGen.mate_at(d, "yplate.%s" % L, "gantry_plate", {"w": 0.088, "d": 0.065, "t": 0.006, "off": 0.0, "wheels": 4, "gap": gap_y, "wheelbase": 0.06},
			"yrail.%s" % L, "+y", "run", Vector3(side * ry, T, tip.z), {Vector3.RIGHT: Vector3.BACK}, {"h": gap_y, "motor": mi_y, "sign": 1.0},
			{"asm": "Bed", "label": "Y wheel plate"})
	GantryLabGen.twins(d, "yplate.L", "yplate.R")
	var lt := GantryLabGen.feat_world(d, "yplate.L", "top").origin
	GantryLabGen.mate_at(d, "bedplate", "bed_plate", {"w": bp_w, "d": B.y, "t": 0.006, "mount_x": ry, "bed": B}, "yplate.L", "top", "mount",
		lt, {Vector3.RIGHT: Vector3.RIGHT, Vector3.UP: Vector3.UP}, {}, {"label": "Y carriage plate", "also": [{"to": "yplate.R", "tf": "top", "f": "mount_r"}]})
	if bed_kind != "none":
		GantryLabGen.mate(d, "bed", "bed", {"kind": bed_kind, "size": B}, "bedplate", "springs", "springs", {"turn": 0}, {"label": str(GantryLabParts.bed(bed_kind)["label"])})
	var yr := GantryLabCatalog.gt2_r(t_y)
	var plate_bot := GantryLabGen.feat_world(d, "bedplate", "under").origin
	var yclamp_h := plate_bot.y - y_b + 0.003
	GantryLabGen.mate_at(d, "yclamp", "belt_clamp", {"h": yclamp_h, "w": 0.012, "d": 0.012, "grip": Vector2(yr - 0.01, 0.0)}, "bedplate", "under", "mount",
		Vector3(0.01, plate_bot.y, tip.z), {Vector3.RIGHT: Vector3.RIGHT}, {}, {"label": "Y belt clamp"})
	d["loops"].append({"name": "Y belt", "motor": mi_y, "sign": 1.0, "belt_w": bw_y,
		"nodes": [{"part": "ypulley", "s": 1.0, "kind": "pulley"}, {"part": "yclamp", "s": 0.0, "kind": "clamp"}, {"part": "yidler", "s": 1.0, "kind": "idler"}]})

	# --- Extruder, spool, electronics (placed, not mated) --------------------
	var additive := str(GantryLabParts.tool(tool_id)["material"]) == "filament"
	var lf := GantryLabGen.feat_world(d, "zplate.L", "top")
	if additive:
		var ex_c := Vector3(-S + 0.01, xb_y + 0.05, lf.origin.z - 0.007)
		var ex_b := Basis(Vector3.LEFT, Vector3.UP, Vector3.FORWARD)
		GantryLabGen.free_part(d, "extruder", "Bowden extruder", Transform3D(ex_b, ex_c),
			[{"kind": "extruder", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.042, 0.06, 0.05), "pick_c": Vector3(0, 0, 0.02)}], 0.45, {"asm": "XBeam"})
		d["links"].append({"kind": "bowden", "a": {"part": "extruder", "at": GantryLabDetail.EXTRUDER_OUTLET}, "b": {"part": "tool", "at": Vector3(0, GantryLabDetail.HOTEND_H + 0.0135, 0)},
			"ta": Vector3.DOWN, "tb": Vector3.UP, "r": 0.002})
		var spool_y := T + U + 0.02 + 0.105
		GantryLabGen.free_part(d, "spool", "Filament spool", Transform3D(GantryLabDetail.basis_y(Vector3.RIGHT), Vector3(-0.0325, spool_y, gz + uwh.y * 0.5 - 0.01)),
			[{"kind": "spool", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "r": 0.1, "w": 0.065, "fill": 0.72, "s": Vector3(0.2, 0.065, 0.2), "pick_c": Vector3(0, 0.0325, 0)}], 1.0)
		GantryLabGen.free_part(d, "spool_holder", "Spool holder", Transform3D(Basis.IDENTITY, Vector3(0.045, (T + U + spool_y) * 0.5, gz + uwh.y * 0.5 - 0.01)),
			[{"kind": "box", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.008, spool_y - T - U, 0.03), "mat": "black"}], 0.05)
		d["links"].append({"kind": "filament", "a": {"part": "spool", "at": Vector3(0.072, 0.0325, 0)}, "b": {"part": "extruder", "at": GantryLabDetail.EXTRUDER_INLET},
			"ta": Vector3.DOWN, "tb": Vector3.UP, "r": 0.0009})
	var board := GantryLabParts.board(str(s["electronics"]["board"]))
	var psu_x := S + bw * 0.5 + 0.065
	GantryLabGen.free_part(d, "psu", "Power supply", Transform3D(Basis.IDENTITY, Vector3(psu_x, 0.025, zb - Lb * 0.2)),
		[{"kind": "psu", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.115, 0.05, 0.215)}], 0.9)
	GantryLabGen.free_part(d, "board", str(board["label"]), Transform3D(Basis.IDENTITY, Vector3(psu_x, 0.001, zb - Lb * 0.2 + 0.1075 + 0.05 + 0.006)),
		[{"kind": "board", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.1, 0.0016, 0.09), "drivers": int(board["drivers"])}], 0.1)
	var lcd_b := Basis(Vector3.RIGHT, deg_to_rad(25.0)) * Basis(Vector3.UP, PI)
	GantryLabGen.free_part(d, "lcd", "Display", Transform3D(lcd_b, Vector3(S - 0.07, T + 0.04, zb - Lb * 0.5 - 0.02)),
		[{"kind": "lcd", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.1, 0.062, 0.02)}], 0.15)

	# --- What this frame does not model yet: say so ---------------------------
	for k in ["x", "y", "z"]:
		if str(s["axis"][k]["guide"]) != "v_wheel":
			d["issues"].append({"level": "warn", "text": "%s guide %s is not modelled on the bed-slinger yet: drawn as V-wheels on the slot." % [k.to_upper(), str(GantryLabParts.guide(str(s["axis"][k]["guide"]))["label"])], "parts": [], "note": true})
	if str(s["frame"].get("corners", "bracket")) != "bracket":
		d["issues"].append({"level": "warn", "text": "Corners: %s are not drawn yet; the frame is built with cast corner brackets." % str(GantryLabSpec.CORNER_LABELS.get(str(s["frame"]["corners"]), "")).to_lower(), "parts": [], "note": true})

	# --- Modules (what the part editor picks first) ----------------------------
	var base: Array = []
	var gframe: Array = []
	for p in d["parts"]:
		var pd: Dictionary = p
		match str(pd.get("group", "")):
			"base":
				base.append(str(pd["id"]))
			"gantry":
				gframe.append(str(pd["id"]))
	GantryLabGen.module(d, "base", "Base frame", base, "")
	GantryLabGen.module(d, "xaxis", "X axis", ["zplate.L", "zplate.R", "xbeam", "xcar", "tool", "xmplate", "xmotor", "xpulley", "xidler", "xclamp"], "zplate.L")
	for L in ["L", "R"]:
		GantryLabGen.module(d, "zdrive.%s" % L, "Z drive (%s)" % ("left" if L == "L" else "right"),
			["ztab.%s" % L, "znut.%s" % L, "zmount.%s" % L, "zmotor.%s" % L, "zcoupler.%s" % L, "zscrew.%s" % L], "zmount.%s" % L)
	GantryLabGen.twin_modules(d, "zdrive.L", "zdrive.R")
	GantryLabGen.module(d, "gantry", "Gantry (uprights, X axis, Z drives)", gframe, "upright.L", ["xaxis", "zdrive.L", "zdrive.R"])
	GantryLabGen.module(d, "ydrive", "Y drive", ["ymount", "ymotor", "ypulley"], "ymount")
	GantryLabGen.module(d, "bed", "Bed (Y carriage)", ["yplate.L", "yplate.R", "bedplate", "bed", "yclamp"], "yplate.L")
	GantryLabGen.module(d, "electronics", "Electronics", ["psu", "board", "lcd", "extruder", "spool", "spool_holder"], "")

	# --- Meta ------------------------------------------------------------------
	d["meta"] = {"mirror_x": 0.0, "moving": {"x": "XCarriage", "y": "Bed", "z": "XBeam"},
		"spans": {"x_beam_m": 2.0 * xe, "y_rail_m": L_rail, "z_col_m": U},
		"anchors": {"gantry_y": gz, "col_x": S, "col_h": T + U, "xb_y": xb_y, "base_y0": zb - Lb * 0.5, "base_len": Lb, "ph": T, "bed_top": bed_top, "vy": vy},
		"bed": {"size": B, "kind": bed_kind}, "bead_parent": "Bed", "bead_origin": Vector3(tip.x, bed_top, tip.z - vy * 0.5)}
	return GantryLabGen.finish(d)


## Slot-cell centres across a profile side (relative to its centre).
static func _cells(n: float) -> PackedFloat32Array:
	return GantryLabCatalog._cells(n)
