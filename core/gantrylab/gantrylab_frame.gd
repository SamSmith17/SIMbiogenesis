class_name GantryLabFrame
extends RefCounted

## The geometry of a gantry from its spec: every extrusion (a cut list), the
## plates, motors, rails, screws and bed, grouped into the STATIC frame and
## the MOVING assemblies, and `pose()` — where each assembly sits for a tool
## position, which is the kinematics made visible. The builder draws exactly
## this; the BOM counts exactly this.
##
## Machine frame (metres): X right, Y away from the operator (local +Z), Z up.
## The work origin (0, 0, 0) is the front-left corner of the bed at its
## surface; tool mm map straight onto it.
##
## layout(spec) → {
##   dims {w, d, h} (overall, m), origin (the work origin in frame space),
##   static {beams: [{a, b, profile, label, group}], parts: [{c, s, kind, label}]},
##   assemblies {name: {parent, base, beams, parts, mass_kg, axis}},
##   belts: [{name, route: Callable-free description (anchor refs)}],
##   bed {size, thick, kind}, screws: [{a, b, d_mm, assembly}],
##   moving_kg {x, y, z}, spans {x_beam_m, y_rail_m, z_col_m}
## }
## pose(spec, layout, tool_mm) → {assembly: Vector3 offset (m) from its base}
## belt_routes(spec, layout, pose) → [{name, points: PackedVector3Array, color_key}]

const MARGIN_X := 0.06   # carriage half-width + end clearance each side
const MARGIN_Y := 0.06
const TOP_CLEAR := 0.12  # room above the work for the toolhead
const BED_CLEAR := 0.05  # bed above the base frame
const FOOT := 0.02


static func layout(spec: Dictionary) -> Dictionary:
	var s := GantryLabSpec.resolve(spec)
	match str(s["kinematics"]):
		"bedslinger", "corexz":
			return _layout_bedslinger(s)
		"cartesian_xy", "corexy", "hbot":
			return _layout_cube(s)
		"delta":
			return _layout_delta(s)
		"router":
			return _layout_router(s)
	return _layout_bedslinger(s)


static func _p(id: String) -> Dictionary:
	return GantryLabParts.profile(id)


static func _w(id: String) -> float:
	return float(_p(id)["w_mm"]) * 0.001


static func _h(id: String) -> float:
	return float(_p(id)["h_mm"]) * 0.001


static func _beam(a: Vector3, b: Vector3, profile: String, label: String, group: String, up: Vector3 = Vector3.UP) -> Dictionary:
	return {"a": a, "b": b, "profile": profile, "label": label, "group": group, "up": up}


static func _part(c: Vector3, s: Vector3, kind: String, label: String) -> Dictionary:
	return {"c": c, "s": s, "kind": kind, "label": label}


static func _motor_size(id: String) -> Vector3:
	var m := GantryLabParts.motor(id)
	var f := float(m["frame_mm"]) * 0.001
	return Vector3(f, float(m["len_mm"]) * 0.001, f)


static func _bed_part(s: Dictionary, c: Vector3, size: Vector2) -> Dictionary:
	var b := GantryLabParts.bed(str(s["tool"]["bed"]))
	var t := maxf(float(b["thick_mm"]) * 0.001, 0.004)
	return _part(c - Vector3(0, t * 0.5, 0), Vector3(size.x, t, size.y), "bed", str(b["label"]))


static func _tool_part(s: Dictionary, c: Vector3) -> Dictionary:
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var kg := float(tool["kg"])
	# Draw the head as a block whose volume reads as its mass (~1 kg ≈ 0.06 m cube).
	var side := clampf(0.035 + 0.04 * pow(kg, 0.4), 0.03, 0.16)
	return _part(c + Vector3(0, side * 0.5, 0), Vector3(side, side * 1.4, side), "tool", str(tool["label"]))


static func _mass_of(beams: Array, parts: Array, extra_kg: float = 0.0) -> float:
	var kg := extra_kg
	for b in beams:
		var bd: Dictionary = b
		kg += (bd["a"] as Vector3).distance_to(bd["b"] as Vector3) * float(_p(str(bd["profile"]))["kg_m"])
	for p in parts:
		var pd: Dictionary = p
		match str(pd["kind"]):
			"motor":
				kg += 0.3
			"plate":
				kg += 0.25
			"bed":
				kg += 0.0  # counted by area below
			"tool":
				kg += 0.0  # the tool's own mass is added by the caller
			"rail":
				kg += 0.1
			_:
				kg += 0.05
	return kg


# ---------------------------------------------------------------------------
# Bed-slinger / CoreXZ: a Y bed, an X beam that climbs the uprights.
# ---------------------------------------------------------------------------

static func _layout_bedslinger(s: Dictionary) -> Dictionary:
	var v: Dictionary = s["volume"]
	var vx := float(v["x_mm"]) * 0.001
	var vy := float(v["y_mm"]) * 0.001
	var vz := float(v["z_mm"]) * 0.001
	var pf := str(s["frame"]["profile"])
	var gf := str(s["frame"]["gantry_profile"])
	var pw := _w(pf)
	var ph := _h(pf)
	var corexz := str(s["kinematics"]) == "corexz"
	# Base: two Y rails plus two cross beams. The bed travels its own length.
	var base_len := 2.0 * vy + 2.0 * MARGIN_Y
	var base_w := vx + 2.0 * MARGIN_X + 2.0 * pw
	var y0 := -base_len * 0.5
	var static_beams: Array = []
	var static_parts: Array = []
	var rail_x := base_w * 0.5 - pw * 0.5
	for sx in [-1.0, 1.0]:
		static_beams.append(_beam(Vector3(sx * rail_x, ph * 0.5, y0), Vector3(sx * rail_x, ph * 0.5, y0 + base_len), pf, "Y rail", "base"))
	for zz in [y0, y0 + base_len - pw]:
		static_beams.append(_beam(Vector3(-base_w * 0.5 + pw, ph * 0.5, zz + pw * 0.5), Vector3(base_w * 0.5 - pw, ph * 0.5, zz + pw * 0.5), pf, "Base cross", "base"))
	# Uprights at the middle of the Y travel, top beam across.
	var gy := 0.0
	var col_h := ph + BED_CLEAR + vz + TOP_CLEAR + 0.06
	var col_x := base_w * 0.5 + _w(gf) * 0.5 + 0.01
	for sx in [-1.0, 1.0]:
		static_beams.append(_beam(Vector3(sx * col_x, ph, gy), Vector3(sx * col_x, col_h, gy), gf, "Upright", "gantry"))
	static_beams.append(_beam(Vector3(-col_x, col_h + _h(gf) * 0.5, gy), Vector3(col_x, col_h + _h(gf) * 0.5, gy), gf, "Top beam", "gantry"))
	# Motors: Y at the back end of the base; Z motors at the uprights' feet
	# (lead screws) or on top (CoreXZ belts); X motor rides the X beam.
	var ms := _motor_size(str(s["axis"]["y"]["motor"]))
	static_parts.append(_part(Vector3(0, ph + ms.y * 0.5, y0 + base_len - 0.03), Vector3(ms.x, ms.y, ms.z), "motor", "Y motor"))
	var screws: Array = []
	var zm := _motor_size(str(s["axis"]["z"]["motor"]))
	var z_dr := GantryLabParts.drive(str(s["axis"]["z"]["drive"]))
	var z_count := int(s["axis"]["z"]["motors"]) if not corexz else 2
	for i in z_count:
		var sx := -1.0 if i % 2 == 0 else 1.0
		if z_count == 1:
			sx = -1.0
		var mx: float = sx * (col_x - _w(gf) * 0.5 - zm.x * 0.5 - 0.005)
		if corexz:
			static_parts.append(_part(Vector3(mx, col_h + 0.02 + zm.y * 0.5, gy), Vector3(zm.x, zm.y, zm.z), "motor", "Motor A" if i == 0 else "Motor B"))
		else:
			static_parts.append(_part(Vector3(mx, ph + zm.y * 0.5, gy), Vector3(zm.x, zm.y, zm.z), "motor", "Z motor %d" % (i + 1)))
			if str(z_dr["kind"]) == "screw":
				screws.append({"a": Vector3(mx, ph + zm.y, gy), "b": Vector3(mx, col_h, gy), "d_mm": float(z_dr["d_mm"]), "label": "Z screw"})
	# Electronics under the base.
	static_parts.append(_part(Vector3(0, ph * 0.5 - 0.001, y0 + base_len * 0.5), Vector3(0.12, 0.004, 0.1), "board", str(GantryLabParts.board(str(s["electronics"]["board"]))["label"])))
	# Bed assembly: a plate on a Y carriage; its work surface at bed_top.
	var bed_top := ph + BED_CLEAR
	var bed := {"size": Vector2(vx + 0.02, vy + 0.02), "kind": str(s["tool"]["bed"])}
	var bed_parts: Array = [_bed_part(s, Vector3(0, bed_top, 0), bed["size"]),
		_part(Vector3(0, ph + 0.012, 0), Vector3(vx * 0.6, 0.006, vy * 0.6), "plate", "Y carriage")]
	var bed_kg := float(GantryLabParts.bed(str(s["tool"]["bed"]))["kg_m2"]) * (vx + 0.02) * (vy + 0.02) + 0.4
	# X beam assembly: a beam between the uprights with the X carriage on it.
	var xb_len := 2.0 * col_x - _w(gf) - 0.01
	var xb_y := bed_top + TOP_CLEAR * 0.5
	var xbeam_beams: Array = [_beam(Vector3(-xb_len * 0.5, xb_y, gy), Vector3(xb_len * 0.5, xb_y, gy), gf, "X beam", "x_axis")]
	var xm := _motor_size(str(s["axis"]["x"]["motor"]))
	var xbeam_parts: Array = []
	if not corexz:
		xbeam_parts.append(_part(Vector3(-xb_len * 0.5 + xm.x * 0.5 + 0.005, xb_y + _h(gf) * 0.5 + xm.y * 0.5, gy), Vector3(xm.x, xm.y, xm.z), "motor", "X motor"))
	for sx in [-1.0, 1.0]:
		xbeam_parts.append(_part(Vector3(sx * (xb_len * 0.5 + _w(gf) * 0.5 - 0.004), xb_y, gy), Vector3(0.008, 0.08, 0.06), "plate", "Z carriage"))
	var guide_x := GantryLabParts.guide(str(s["axis"]["x"]["guide"]))
	if float(guide_x["kg_m"]) > 0.0:
		xbeam_parts.append(_part(Vector3(0, xb_y + _h(gf) * 0.5 + 0.004, gy + _w(gf) * 0.5 - 0.008), Vector3(xb_len - 0.02, 0.008, 0.012), "rail", str(guide_x["label"])))
	# X carriage: the toolhead; tool tip at the work origin when tool = (0,0,0).
	var tool_tip := Vector3(-vx * 0.5, bed_top, gy)
	var car_parts: Array = [_part(Vector3(0, xb_y, gy + _w(gf) * 0.5 + 0.01), Vector3(0.07, 0.09, 0.012), "plate", "X carriage"),
		_tool_part(s, Vector3(0, xb_y - 0.045, gy + _w(gf) * 0.5 + 0.03))]
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var car_kg := float(tool["kg"]) + float(guide_x["kg_carriage"]) + 0.15
	var xbeam_kg := _mass_of(xbeam_beams, xbeam_parts) + float(guide_x["kg_m"]) * xb_len + (0.0 if corexz else float(GantryLabParts.motor(str(s["axis"]["x"]["motor"]))["kg"]))
	var assemblies := {
		"XBeam": {"parent": "", "base": Vector3(0, 0, 0), "beams": xbeam_beams, "parts": xbeam_parts, "mass_kg": xbeam_kg + car_kg, "axis": "z"},
		"XCarriage": {"parent": "XBeam", "base": Vector3(tool_tip.x, 0, 0), "beams": [], "parts": car_parts, "mass_kg": car_kg, "axis": "x"},
		"Bed": {"parent": "", "base": Vector3(0, 0, 0), "beams": [], "parts": bed_parts, "mass_kg": bed_kg, "axis": "y"},
	}
	var dims := Vector3(2.0 * col_x + _w(gf), col_h + _h(gf), base_len)
	return {
		"kinematics": str(s["kinematics"]), "dims": dims,
		"origin": tool_tip, "static": {"beams": static_beams, "parts": static_parts},
		"assemblies": assemblies, "bed": bed, "screws": screws,
		"moving_kg": {"x": car_kg, "y": bed_kg, "z": xbeam_kg + car_kg},
		"spans": {"x_beam_m": xb_len, "y_rail_m": base_len, "z_col_m": col_h - ph},
		"anchors": {"gantry_y": gy, "col_x": col_x, "col_h": col_h, "xb_y": xb_y, "base_y0": y0, "base_len": base_len, "ph": ph, "bed_top": bed_top, "vy": vy},
		"bead_parent": "Bed", "bead_origin": Vector3(-vx * 0.5, bed_top, -vy * 0.5),
	}


# ---------------------------------------------------------------------------
# Cube: a box frame, an X beam riding Y rails at the top, the bed drops.
# CoreXY and H-bot share it with their fixed A/B motors at the back corners.
# ---------------------------------------------------------------------------

static func _layout_cube(s: Dictionary) -> Dictionary:
	var v: Dictionary = s["volume"]
	var vx := float(v["x_mm"]) * 0.001
	var vy := float(v["y_mm"]) * 0.001
	var vz := float(v["z_mm"]) * 0.001
	var pf := str(s["frame"]["profile"])
	var gf := str(s["frame"]["gantry_profile"])
	var pw := _w(pf)
	var kin := str(s["kinematics"])
	var shared := kin == "corexy" or kin == "hbot"
	var w := vx + 2.0 * MARGIN_X + 2.0 * pw + (0.0 if shared else 0.06)
	var d := vy + 2.0 * MARGIN_Y + 2.0 * pw + 0.08
	var h := FOOT + pw + BED_CLEAR + vz + TOP_CLEAR + pw + 0.06
	var hx := w * 0.5
	var hz := d * 0.5
	var static_beams: Array = []
	var static_parts: Array = []
	# Twelve edges.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			static_beams.append(_beam(Vector3(sx * (hx - pw * 0.5), FOOT, sz * (hz - pw * 0.5)), Vector3(sx * (hx - pw * 0.5), h, sz * (hz - pw * 0.5)), pf, "Upright", "frame"))
	for yy in [FOOT + pw * 0.5, h - pw * 0.5]:
		for sz in [-1.0, 1.0]:
			static_beams.append(_beam(Vector3(-hx + pw, yy, sz * (hz - pw * 0.5)), Vector3(hx - pw, yy, sz * (hz - pw * 0.5)), pf, "X rail" if yy > 1.0 * FOOT + pw else "Base beam", "frame"))
		for sx in [-1.0, 1.0]:
			static_beams.append(_beam(Vector3(sx * (hx - pw * 0.5), yy, -hz + pw), Vector3(sx * (hx - pw * 0.5), yy, hz - pw), pf, "Y rail" if yy > FOOT + pw else "Base beam", "frame"))
	# Y rails carry the X beam: linear rails / wheels on the top side beams.
	var guide_y := GantryLabParts.guide(str(s["axis"]["y"]["guide"]))
	var guide_x := GantryLabParts.guide(str(s["axis"]["x"]["guide"]))
	var y_rail_len := d - 2.0 * pw
	if float(guide_y["kg_m"]) > 0.0:
		for sx in [-1.0, 1.0]:
			static_parts.append(_part(Vector3(sx * (hx - pw - 0.006), h - pw * 0.5, 0), Vector3(0.012, 0.008, y_rail_len - 0.02), "rail", str(guide_y["label"])))
	# Motors.
	if shared:
		for i in 2:
			var sx := -1.0 if i == 0 else 1.0
			var ms := _motor_size(str(s["axis"]["x"]["motor"]))
			static_parts.append(_part(Vector3(sx * (hx - pw - ms.x * 0.5 - 0.004), h - pw - ms.y * 0.5, hz - pw - ms.z * 0.5 - 0.004), Vector3(ms.x, ms.y, ms.z), "motor", "Motor A" if i == 0 else "Motor B"))
	else:
		var ms := _motor_size(str(s["axis"]["y"]["motor"]))
		static_parts.append(_part(Vector3(hx - pw - ms.x * 0.5 - 0.004, h - pw - ms.y * 0.5, hz - pw - ms.z * 0.5 - 0.004), Vector3(ms.x, ms.y, ms.z), "motor", "Y motor"))
	# Z: lead screws or belts in the corners.
	var z_dr := GantryLabParts.drive(str(s["axis"]["z"]["drive"]))
	var zm := _motor_size(str(s["axis"]["z"]["motor"]))
	var z_count := int(s["axis"]["z"]["motors"])
	var screws: Array = []
	var corner_list := [Vector3(-1, 0, 1), Vector3(1, 0, 1), Vector3(-1, 0, -1), Vector3(1, 0, -1)]
	for i in z_count:
		var cn: Vector3 = corner_list[i % 4]
		var cx := cn.x * (hx - pw - zm.x * 0.5 - 0.004)
		var cz := cn.z * (hz - pw - zm.z * 0.5 - 0.004)
		if z_count == 1:
			cx = 0.0
			cz = hz - pw - zm.z * 0.5 - 0.004
		static_parts.append(_part(Vector3(cx, FOOT + pw + zm.y * 0.5, cz), Vector3(zm.x, zm.y, zm.z), "motor", "Z motor %d" % (i + 1)))
		if str(z_dr["kind"]) == "screw":
			screws.append({"a": Vector3(cx, FOOT + pw + zm.y, cz), "b": Vector3(cx, h - pw, cz), "d_mm": float(z_dr["d_mm"]), "label": "Z screw"})
	static_parts.append(_part(Vector3(0, FOOT + pw * 0.5, hz - pw * 0.5 - 0.002), Vector3(0.12, 0.004, 0.01), "board", str(GantryLabParts.board(str(s["electronics"]["board"]))["label"])))
	if bool(s["frame"]["enclosed"]):
		for sx in [-1.0, 1.0]:
			static_parts.append(_part(Vector3(sx * (hx - 0.002), (FOOT + h) * 0.5, 0), Vector3(0.004, h - FOOT - 2.0 * pw, d - 2.0 * pw), "panel", "Side panel"))
		static_parts.append(_part(Vector3(0, (FOOT + h) * 0.5, hz - 0.002), Vector3(w - 2.0 * pw, h - FOOT - 2.0 * pw, 0.004), "panel", "Back panel"))
	# X beam on the Y rails, carrying the X carriage.
	var xb_len := w - 2.0 * pw - 0.004
	var xb_y := h - pw * 0.5
	var xb_z := -vy * 0.5
	var xbeam_beams: Array = [_beam(Vector3(-xb_len * 0.5, xb_y, 0), Vector3(xb_len * 0.5, xb_y, 0), gf, "X beam", "x_axis")]
	var xbeam_parts: Array = []
	for sx in [-1.0, 1.0]:
		xbeam_parts.append(_part(Vector3(sx * (xb_len * 0.5 - 0.02), xb_y, 0), Vector3(0.04, 0.012, 0.07), "plate", "Y carriage"))
	if not shared:
		var xm := _motor_size(str(s["axis"]["x"]["motor"]))
		xbeam_parts.append(_part(Vector3(-xb_len * 0.5 + 0.03, xb_y + _h(gf) * 0.5 + xm.y * 0.5, 0), Vector3(xm.x, xm.y, xm.z), "motor", "X motor"))
	if float(guide_x["kg_m"]) > 0.0:
		xbeam_parts.append(_part(Vector3(0, xb_y - _h(gf) * 0.5 - 0.004, 0), Vector3(xb_len - 0.06, 0.008, 0.012), "rail", str(guide_x["label"])))
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var car_parts: Array = [_part(Vector3(0, xb_y - _h(gf) * 0.5 - 0.016, 0), Vector3(0.07, 0.012, 0.07), "plate", "X carriage"),
		_tool_part(s, Vector3(0, xb_y - _h(gf) * 0.5 - 0.022 - 0.09, 0))]
	var car_kg := float(tool["kg"]) + float(guide_x["kg_carriage"]) + 0.15
	var xbeam_kg := _mass_of(xbeam_beams, xbeam_parts) + float(guide_x["kg_m"]) * xb_len + (0.0 if shared else float(GantryLabParts.motor(str(s["axis"]["x"]["motor"]))["kg"]))
	# Bed on the Z stage: its top at the work origin's height when z = 0.
	var bed_top := h - pw - TOP_CLEAR - 0.012 - 0.09
	var bed := {"size": Vector2(vx + 0.02, vy + 0.02), "kind": str(s["tool"]["bed"])}
	var bed_parts: Array = [_bed_part(s, Vector3(0, bed_top, 0), bed["size"])]
	var bed_t := maxf(float(GantryLabParts.bed(str(s["tool"]["bed"]))["thick_mm"]) * 0.001, 0.004)
	bed_parts.append(_part(Vector3(0, bed_top - bed_t - 0.01, 0), Vector3(vx * 0.8, 0.02, vy * 0.8), "plate", "Bed frame"))
	var bed_kg := float(GantryLabParts.bed(str(s["tool"]["bed"]))["kg_m2"]) * (vx + 0.02) * (vy + 0.02) + 1.2
	var tool_tip := Vector3(-vx * 0.5, bed_top, -vy * 0.5)
	var assemblies := {
		"XBeam": {"parent": "", "base": Vector3(0, 0, xb_z), "beams": xbeam_beams, "parts": xbeam_parts, "mass_kg": xbeam_kg + car_kg, "axis": "y"},
		"XCarriage": {"parent": "XBeam", "base": Vector3(tool_tip.x, 0, 0), "beams": [], "parts": car_parts, "mass_kg": car_kg, "axis": "x"},
		"Bed": {"parent": "", "base": Vector3(0, 0, 0), "beams": [], "parts": bed_parts, "mass_kg": bed_kg, "axis": "z"},
	}
	return {
		"kinematics": kin, "dims": Vector3(w, h + pw * 0.5, d),
		"origin": tool_tip, "static": {"beams": static_beams, "parts": static_parts},
		"assemblies": assemblies, "bed": bed, "screws": screws,
		"moving_kg": {"x": car_kg, "y": xbeam_kg + car_kg, "z": bed_kg},
		"spans": {"x_beam_m": xb_len, "y_rail_m": y_rail_len, "z_col_m": h - FOOT - pw},
		"anchors": {"hx": hx, "hz": hz, "h": h, "pw": pw, "xb_y": xb_y, "xb_len": xb_len, "bed_top": bed_top, "vy": vy},
		"bead_parent": "Bed", "bead_origin": tool_tip,
	}


# ---------------------------------------------------------------------------
# Delta: three towers on a triangular base, carriages, arms, a round bed.
# ---------------------------------------------------------------------------

static func _layout_delta(s: Dictionary) -> Dictionary:
	var v: Dictionary = s["volume"]
	var vd := float(v["x_mm"]) * 0.001
	var vz := float(v["z_mm"]) * 0.001
	var pf := str(s["frame"]["profile"])
	var pw := _w(pf)
	var dl: Dictionary = s["delta"]
	var tower_r := float(dl["tower_r_mm"]) * 0.001
	var arm := float(dl["arm_mm"]) * 0.001
	var reach := GantryLabKinematics.delta_reach(s)
	var bed_top := FOOT + pw + BED_CLEAR
	var tower_h := bed_top + vz + float(reach["h_centre_mm"]) * 0.001 + 0.08
	var static_beams: Array = []
	var static_parts: Array = []
	var towers: Array = []
	for i in 3:
		var a := deg_to_rad(float(GantryLabKinematics.DELTA_TOWER_DEG[i]))
		var tx := cos(a) * tower_r
		var tz := sin(a) * tower_r
		towers.append(Vector3(tx, 0, tz))
		static_beams.append(_beam(Vector3(tx, FOOT, tz), Vector3(tx, tower_h, tz), pf, "Tower", "frame"))
	# Triangular base and top frames between the towers (outside the towers).
	for yy in [FOOT + pw * 0.5, tower_h - pw * 0.5]:
		for i in 3:
			var ta: Vector3 = towers[i]
			var tb: Vector3 = towers[(i + 1) % 3]
			var out := ((ta + tb) * 0.5).normalized() * pw
			static_beams.append(_beam(Vector3(ta.x, yy, ta.z) + out, Vector3(tb.x, yy, tb.z) + out, pf, "Base beam" if yy < 1.0 else "Top beam", "frame"))
	var zm := _motor_size(str(s["axis"]["z"]["motor"]))
	for i in 3:
		var t: Vector3 = towers[i]
		var inward := -Vector3(t.x, 0, t.z).normalized()
		static_parts.append(_part(Vector3(t.x, FOOT + pw + zm.y * 0.5, t.z) + inward * (pw * 0.5 + zm.z * 0.5), Vector3(zm.x, zm.y, zm.z), "motor", "Tower %s motor" % ["A", "B", "C"][i]))
	static_parts.append(_part(Vector3(0, FOOT + pw * 0.5, 0), Vector3(0.12, 0.004, 0.1), "board", str(GantryLabParts.board(str(s["electronics"]["board"]))["label"])))
	var bed := {"size": Vector2(vd + 0.02, vd + 0.02), "kind": str(s["tool"]["bed"]), "round": true}
	static_parts.append(_part(Vector3(0, bed_top - 0.003, 0), Vector3(vd + 0.02, 0.006, vd + 0.02), "bed_round", str(GantryLabParts.bed(str(s["tool"]["bed"]))["label"])))
	var guide := GantryLabParts.guide(str(s["axis"]["z"]["guide"]))
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var assemblies := {}
	var car_r := float(dl["carriage_r_mm"]) * 0.001
	for i in 3:
		var t: Vector3 = towers[i]
		var inward := -Vector3(t.x, 0, t.z).normalized()
		# The carriage's base is the tower's centreline; its pivot sits car_r
		# inward of it (the delta-radius convention), the plate on the face.
		var cpos := Vector3(t.x, bed_top, t.z)
		assemblies["Carriage%s" % ["A", "B", "C"][i]] = {"parent": "", "base": cpos,
			"beams": [], "parts": [_part(inward * (pw * 0.5 + 0.006), Vector3(0.05, 0.06, 0.012), "plate", "Tower carriage")],
			"mass_kg": 0.1 + float(guide["kg_carriage"]), "axis": "z", "tower": i, "inward": inward, "car_r": car_r}
	var eff_r := float(dl["effector_r_mm"]) * 0.001
	assemblies["Effector"] = {"parent": "", "base": Vector3(0, bed_top, 0), "beams": [],
		"parts": [_part(Vector3(0, 0.03, 0), Vector3(eff_r * 2.0, 0.01, eff_r * 2.0), "plate", "Effector"),
			_tool_part(s, Vector3(0, 0.0, 0))],
		"mass_kg": float(tool["kg"]) + 0.08 + 6.0 * 0.03, "axis": "xyz", "eff_r": eff_r}
	var tool_tip := Vector3(0, bed_top, 0)
	var moving := float(tool["kg"]) + 0.08 + 0.18 + 0.3 + 3.0 * float(guide["kg_carriage"])
	return {
		"kinematics": "delta", "dims": Vector3(tower_r * 2.0 + 2.0 * pw + 0.04, tower_h + pw * 0.5, tower_r * 2.0 + 2.0 * pw + 0.04),
		"origin": tool_tip, "static": {"beams": static_beams, "parts": static_parts},
		"assemblies": assemblies, "bed": bed, "screws": [], "towers": towers, "arm_m": arm,
		"moving_kg": {"x": moving, "y": moving, "z": moving},
		"spans": {"x_beam_m": 0.0, "y_rail_m": 0.0, "z_col_m": tower_h - FOOT, "arm_m": arm},
		"anchors": {"tower_h": tower_h, "bed_top": bed_top, "pw": pw, "tower_r": tower_r},
		"bead_parent": "", "bead_origin": tool_tip,
	}


# ---------------------------------------------------------------------------
# Router: a bed-sized base, two Y side rails, a gantry that rides them in Y,
# the X carriage on the gantry beam, the Z axis plunging the tool.
# ---------------------------------------------------------------------------

static func _layout_router(s: Dictionary) -> Dictionary:
	var v: Dictionary = s["volume"]
	var vx := float(v["x_mm"]) * 0.001
	var vy := float(v["y_mm"]) * 0.001
	var vz := float(v["z_mm"]) * 0.001
	var pf := str(s["frame"]["profile"])
	var gf := str(s["frame"]["gantry_profile"])
	var pw := _w(pf)
	var ph := _h(pf)
	var gw := _w(gf)
	var gh := _h(gf)
	var w := vx + 2.0 * MARGIN_X + 2.0 * pw + 0.10
	var d := vy + 2.0 * MARGIN_Y + 0.14
	var hx := w * 0.5
	var hz := d * 0.5
	var static_beams: Array = []
	var static_parts: Array = []
	# Side rails (the Y axis): the profile on its strong axis (height up).
	for sx in [-1.0, 1.0]:
		static_beams.append(_beam(Vector3(sx * (hx - pw * 0.5), FOOT + ph * 0.5, -hz), Vector3(sx * (hx - pw * 0.5), FOOT + ph * 0.5, hz), pf, "Y rail", "base"))
	# Cross members under the bed.
	var n_cross := maxi(2, int(ceil(d / 0.4)) + 1)
	for i in n_cross:
		var zz := lerpf(-hz + pw * 0.5, hz - pw * 0.5, float(i) / float(n_cross - 1))
		static_beams.append(_beam(Vector3(-hx + pw, FOOT + pw * 0.5, zz), Vector3(hx - pw, FOOT + pw * 0.5, zz), "2040" if pf != "2020" else "2020", "Cross member", "base"))
	var bed_top := FOOT + ph
	var bed := {"size": Vector2(vx + 0.06, vy + 0.06), "kind": str(s["tool"]["bed"])}
	static_parts.append(_bed_part(s, Vector3(0, bed_top + 0.018, 0), bed["size"]))
	bed_top += 0.018
	# Y motors (one per rail when two).
	var y_dr := GantryLabParts.drive(str(s["axis"]["y"]["drive"]))
	var ym := _motor_size(str(s["axis"]["y"]["motor"]))
	var screws: Array = []
	var y_count := int(s["axis"]["y"]["motors"])
	for i in y_count:
		var sx := -1.0 if i == 0 else 1.0
		if y_count == 1:
			sx = 1.0
		var mx: float = sx * (hx - pw * 0.5)
		static_parts.append(_part(Vector3(mx, FOOT + ph * 0.5, -hz - ym.y * 0.5), Vector3(ym.x, ym.y, ym.z), "motor", "Y motor %d" % (i + 1)))
		if str(y_dr["kind"]) == "screw":
			screws.append({"a": Vector3(mx, FOOT + ph * 0.5, -hz), "b": Vector3(mx, FOOT + ph * 0.5, hz), "d_mm": float(y_dr["d_mm"]), "label": "Y screw"})
	static_parts.append(_part(Vector3(hx + 0.08, FOOT + 0.06, 0), Vector3(0.14, 0.12, 0.22), "board", str(GantryLabParts.board(str(s["electronics"]["board"]))["label"])))
	# Gantry: two uprights on Y carriages, the X beam across, the X motor at its end.
	var up_h := bed_top + vz + 0.12 + gh
	var up_x := hx - pw * 0.5
	var g_beams: Array = []
	var g_parts: Array = []
	for sx in [-1.0, 1.0]:
		g_beams.append(_beam(Vector3(sx * up_x, FOOT + ph, 0), Vector3(sx * up_x, up_h, 0), gf, "Gantry upright", "gantry"))
		g_parts.append(_part(Vector3(sx * up_x, FOOT + ph * 0.5, 0), Vector3(0.012, ph + 0.02, 0.16), "plate", "Y gantry plate"))
	var xb_len := 2.0 * up_x + gw
	var xb_y := up_h - gh * 0.5
	g_beams.append(_beam(Vector3(-xb_len * 0.5, xb_y, 0.0), Vector3(xb_len * 0.5, xb_y, 0.0), gf, "X beam", "gantry", Vector3.FORWARD))
	var xm := _motor_size(str(s["axis"]["x"]["motor"]))
	g_parts.append(_part(Vector3(xb_len * 0.5 + xm.y * 0.5, xb_y, 0), Vector3(xm.y, xm.x, xm.z), "motor", "X motor"))
	var x_dr := GantryLabParts.drive(str(s["axis"]["x"]["drive"]))
	if str(x_dr["kind"]) == "screw":
		screws.append({"a": Vector3(-xb_len * 0.5, xb_y, -gw * 0.5 - 0.012), "b": Vector3(xb_len * 0.5, xb_y, -gw * 0.5 - 0.012), "d_mm": float(x_dr["d_mm"]), "label": "X screw", "assembly": "YGantry"})
	var guide_x := GantryLabParts.guide(str(s["axis"]["x"]["guide"]))
	var guide_y := GantryLabParts.guide(str(s["axis"]["y"]["guide"]))
	var guide_z := GantryLabParts.guide(str(s["axis"]["z"]["guide"]))
	if float(guide_x["kg_m"]) > 0.0:
		g_parts.append(_part(Vector3(0, xb_y + gh * 0.5 - 0.02, -gw * 0.5 - 0.004), Vector3(xb_len - 0.04, 0.012, 0.008), "rail", str(guide_x["label"])))
	# X carriage: the Z axis plate; the Z carriage holds the tool.
	var z_dr := GantryLabParts.drive(str(s["axis"]["z"]["drive"]))
	var zm := _motor_size(str(s["axis"]["z"]["motor"]))
	var zplate_h := vz + 0.16
	var car_parts: Array = [_part(Vector3(0, xb_y, -gw * 0.5 - 0.012), Vector3(0.12, gh + 0.04, 0.012), "plate", "X carriage"),
		_part(Vector3(0, xb_y + gh * 0.5 + 0.02 + zm.y * 0.5, -gw * 0.5 - 0.03), Vector3(zm.x, zm.y, zm.z), "motor", "Z motor")]
	car_parts.append(_part(Vector3(0, xb_y - zplate_h * 0.5 + gh * 0.5, -gw * 0.5 - 0.03), Vector3(0.09, zplate_h, 0.01), "plate", "Z axis plate"))
	if str(z_dr["kind"]) == "screw":
		screws.append({"a": Vector3(0, xb_y + gh * 0.5 + 0.02, -gw * 0.5 - 0.045), "b": Vector3(0, xb_y - zplate_h + gh * 0.5, -gw * 0.5 - 0.045), "d_mm": float(z_dr["d_mm"]), "label": "Z screw", "assembly": "XCarriage"})
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var tool_part := _tool_part(s, Vector3(0, 0, 0))
	var tool_h := (tool_part["s"] as Vector3).y
	# The Z carriage's base puts the tool tip at the bed when z = 0.
	var zc_parts: Array = [_part(Vector3(0, tool_h * 0.5, -gw * 0.5 - 0.06), Vector3(0.08, 0.1, 0.012), "plate", "Z carriage"),
		_part(Vector3(0, tool_h * 0.5, -gw * 0.5 - 0.06 - 0.01 - (tool_part["s"] as Vector3).z * 0.5), tool_part["s"], "tool", str(tool["label"]))]
	var tool_tip := Vector3(-vx * 0.5, bed_top, -vy * 0.5)
	var zc_kg := float(tool["kg"]) + float(guide_z["kg_carriage"]) + 0.2
	var car_kg := zc_kg + _mass_of([], car_parts) + float(GantryLabParts.motor(str(s["axis"]["z"]["motor"]))["kg"]) + float(guide_x["kg_carriage"]) + 0.3
	var g_kg := _mass_of(g_beams, g_parts) + car_kg + float(GantryLabParts.motor(str(s["axis"]["x"]["motor"]))["kg"]) + 2.0 * float(guide_y["kg_carriage"]) + float(guide_x["kg_m"]) * xb_len
	var assemblies := {
		"YGantry": {"parent": "", "base": Vector3(0, 0, tool_tip.z), "beams": g_beams, "parts": g_parts, "mass_kg": g_kg, "axis": "y"},
		"XCarriage": {"parent": "YGantry", "base": Vector3(tool_tip.x, 0, 0), "beams": [], "parts": car_parts, "mass_kg": car_kg, "axis": "x"},
		"ZCarriage": {"parent": "XCarriage", "base": Vector3(0, tool_tip.y, 0), "beams": [], "parts": zc_parts, "mass_kg": zc_kg, "axis": "z"},
	}
	return {
		"kinematics": "router", "dims": Vector3(w + 0.16, up_h + gh * 0.5, d + 0.16),
		"origin": tool_tip, "static": {"beams": static_beams, "parts": static_parts},
		"assemblies": assemblies, "bed": bed, "screws": screws,
		"moving_kg": {"x": car_kg, "y": g_kg, "z": zc_kg},
		"spans": {"x_beam_m": xb_len, "y_rail_m": d, "z_col_m": up_h - FOOT - ph, "z_plate_m": zplate_h},
		"anchors": {"hx": hx, "hz": hz, "xb_y": xb_y, "xb_len": xb_len, "bed_top": bed_top, "up_h": up_h, "gw": gw},
		"bead_parent": "", "bead_origin": tool_tip,
	}


# ---------------------------------------------------------------------------
# Pose: where every assembly sits for a tool position (mm, work coordinates).
# ---------------------------------------------------------------------------

static func pose(spec: Dictionary, lay: Dictionary, tool_mm: Vector3) -> Dictionary:
	var x := tool_mm.x * 0.001
	var y := tool_mm.y * 0.001
	var z := tool_mm.z * 0.001
	match str(lay["kinematics"]):
		"bedslinger", "corexz":
			# The bed slides so the tool stands over (x, y): at y = 0 the bed's
			# front edge is under the gantry, at y = vy its back edge.
			var vy := float((lay["anchors"] as Dictionary).get("vy", 0.0))
			return {"XBeam": Vector3(0, z, 0), "XCarriage": Vector3(x, 0, 0), "Bed": Vector3(0, 0, vy * 0.5 - y)}
		"cartesian_xy", "corexy", "hbot":
			return {"XBeam": Vector3(0, 0, y), "XCarriage": Vector3(x, 0, 0), "Bed": Vector3(0, -z, 0)}
		"router":
			return {"YGantry": Vector3(0, 0, y), "XCarriage": Vector3(x, 0, 0), "ZCarriage": Vector3(0, z, 0)}
		"delta":
			var c := GantryLabKinematics.delta_carriages(spec, tool_mm)
			var out := {"Effector": Vector3(x, z, y)}
			for i in 3:
				var h := float(c[i])
				out["Carriage%s" % ["A", "B", "C"][i]] = Vector3(0, (h if is_finite(h) else tool_mm.z) * 0.001, 0)
			return out
	return {}


## World-frame (machine-local) position of an assembly's base + pose offset,
## following its parent chain.
static func assembly_origin(lay: Dictionary, po: Dictionary, name: String) -> Vector3:
	var asm: Dictionary = lay["assemblies"].get(name, {})
	if asm.is_empty():
		return Vector3.ZERO
	var p := (asm["base"] as Vector3) + (po.get(name, Vector3.ZERO) as Vector3)
	var parent := str(asm.get("parent", ""))
	if not parent.is_empty():
		p += assembly_origin(lay, po, parent)
	return p


## Belt routes for drawing: closed loops as point lists in machine space.
static func belt_routes(spec: Dictionary, lay: Dictionary, po: Dictionary) -> Array:
	var kin := str(lay["kinematics"])
	var an: Dictionary = lay["anchors"]
	var out: Array = []
	match kin:
		"corexy", "hbot", "cartesian_xy":
			var hx := float(an["hx"])
			var hz := float(an["hz"])
			var pw := float(an["pw"])
			var y := float(an["xb_y"]) + 0.012
			var xb := assembly_origin(lay, po, "XBeam")
			var car := assembly_origin(lay, po, "XCarriage")
			var xl := -float(an["xb_len"]) * 0.5 + 0.03
			var xr := float(an["xb_len"]) * 0.5 - 0.03
			var bk := hz - pw - 0.03
			var fr := -hz + pw + 0.03
			var cz := xb.z
			var f := 0.012
			if kin == "corexy":
				out.append({"name": "Belt A", "points": PackedVector3Array([Vector3(xl, y, bk), Vector3(xl, y, cz + f), Vector3(car.x - 0.03, y, cz + f),
					Vector3(car.x + 0.03, y, cz + f), Vector3(xr, y, cz + f), Vector3(xr, y, fr), Vector3(xr + 0.01, y, fr), Vector3(xr + 0.01, y, bk)]), "key": "belt"})
				out.append({"name": "Belt B", "points": PackedVector3Array([Vector3(xr, y, bk), Vector3(xr, y, cz - f), Vector3(car.x + 0.03, y, cz - f),
					Vector3(car.x - 0.03, y, cz - f), Vector3(xl, y, cz - f), Vector3(xl, y, fr), Vector3(xl - 0.01, y, fr), Vector3(xl - 0.01, y, bk)]), "key": "belt"})
			elif kin == "hbot":
				out.append({"name": "Belt (H)", "points": PackedVector3Array([Vector3(xl, y, bk), Vector3(xl, y, cz + f), Vector3(car.x - 0.03, y, cz + f),
					Vector3(car.x + 0.03, y, cz + f), Vector3(xr, y, cz + f), Vector3(xr, y, bk), Vector3(xr, y, cz - f), Vector3(car.x + 0.03, y, cz - f),
					Vector3(car.x - 0.03, y, cz - f), Vector3(xl, y, cz - f), Vector3(xl, y, fr), Vector3(xl, y, bk)]), "key": "belt"})
			else:
				out.append({"name": "X belt", "points": PackedVector3Array([Vector3(xl, y, cz - f), Vector3(car.x - 0.03, y, cz - f), Vector3(car.x + 0.03, y, cz - f),
					Vector3(xr, y, cz - f), Vector3(xr, y, cz + f), Vector3(xl, y, cz + f)]), "key": "belt"})
				var yx := hx - pw - 0.02
				out.append({"name": "Y belt", "points": PackedVector3Array([Vector3(yx, y, bk), Vector3(yx, y, cz + 0.02), Vector3(yx, y, cz - 0.02),
					Vector3(yx, y, fr), Vector3(yx - 0.012, y, fr), Vector3(yx - 0.012, y, bk)]), "key": "belt"})
		"bedslinger", "corexz":
			var gy := float(an["gantry_y"])
			var col_x := float(an["col_x"])
			var col_h := float(an["col_h"])
			var ph := float(an["ph"])
			var xb := assembly_origin(lay, po, "XBeam")
			var car := assembly_origin(lay, po, "XCarriage")
			var y := xb.y + float(an["xb_y"])
			var xl := -col_x + 0.04
			var xr := col_x - 0.04
			var zf := gy + 0.03
			if kin == "corexz":
				# Belts run from the top motors down the uprights to the X beam / carriage.
				out.append({"name": "Belt A", "points": PackedVector3Array([Vector3(xl, col_h, zf), Vector3(xl, y, zf), Vector3(car.x - 0.03, y, zf),
					Vector3(car.x + 0.03, y, zf), Vector3(xr, y, zf), Vector3(xr, ph + 0.02, zf), Vector3(xr + 0.012, ph + 0.02, zf), Vector3(xr + 0.012, col_h, zf)]), "key": "belt"})
				out.append({"name": "Belt B", "points": PackedVector3Array([Vector3(xr, col_h, zf + 0.012), Vector3(xr, y + 0.012, zf + 0.012), Vector3(car.x + 0.03, y + 0.012, zf + 0.012),
					Vector3(car.x - 0.03, y + 0.012, zf + 0.012), Vector3(xl, y + 0.012, zf + 0.012), Vector3(xl, ph + 0.02, zf + 0.012), Vector3(xl - 0.012, ph + 0.02, zf + 0.012), Vector3(xl - 0.012, col_h, zf + 0.012)]), "key": "belt"})
			else:
				out.append({"name": "X belt", "points": PackedVector3Array([Vector3(xl, y, zf), Vector3(car.x - 0.03, y, zf), Vector3(car.x + 0.03, y, zf),
					Vector3(xr, y, zf), Vector3(xr, y + 0.012, zf), Vector3(xl, y + 0.012, zf)]), "key": "belt"})
			var y0 := float(an["base_y0"])
			var bl := float(an["base_len"])
			var bed := assembly_origin(lay, po, "Bed")
			var by := ph + 0.03
			out.append({"name": "Y belt", "points": PackedVector3Array([Vector3(0.006, by, y0 + bl - 0.05), Vector3(0.006, by, bed.z + 0.05), Vector3(0.006, by, bed.z - 0.05),
				Vector3(0.006, by, y0 + 0.03), Vector3(-0.006, by, y0 + 0.03), Vector3(-0.006, by, y0 + bl - 0.05)]), "key": "belt"})
		"delta":
			var tw: Array = lay["towers"]
			var th := float(an["tower_h"])
			var pw := float(an["pw"])
			for i in 3:
				var t: Vector3 = tw[i]
				var inward := -Vector3(t.x, 0, t.z).normalized()
				var p := Vector3(t.x, 0, t.z) + inward * (pw * 0.5 + 0.003)
				var car := assembly_origin(lay, po, "Carriage%s" % ["A", "B", "C"][i])
				var side := inward.cross(Vector3.UP) * 0.006
				out.append({"name": "Tower %s belt" % ["A", "B", "C"][i], "points": PackedVector3Array([
					p + side + Vector3(0, FOOT + pw + 0.03, 0), p + side + Vector3(0, car.y - 0.03, 0), p + side + Vector3(0, car.y + 0.03, 0),
					p + side + Vector3(0, th - 0.04, 0), p - side + Vector3(0, th - 0.04, 0), p - side + Vector3(0, FOOT + pw + 0.03, 0)]), "key": "belt"})
		"router":
			var x_dr := GantryLabParts.drive(str(spec["axis"]["x"]["drive"]))
			var y_dr := GantryLabParts.drive(str(spec["axis"]["y"]["drive"]))
			var g := assembly_origin(lay, po, "YGantry")
			var car := assembly_origin(lay, po, "XCarriage")
			var y := float(an["xb_y"]) + float(an["gw"]) * 0.5 + 0.01
			var xl := -float(an["xb_len"]) * 0.5 + 0.03
			var xr := float(an["xb_len"]) * 0.5 - 0.03
			if str(x_dr["kind"]) == "belt":
				out.append({"name": "X belt", "points": PackedVector3Array([Vector3(xl, y, g.z - 0.03), Vector3(car.x - 0.04, y, g.z - 0.03), Vector3(car.x + 0.04, y, g.z - 0.03),
					Vector3(xr, y, g.z - 0.03), Vector3(xr, y + 0.012, g.z - 0.03), Vector3(xl, y + 0.012, g.z - 0.03)]), "key": "belt"})
			if str(y_dr["kind"]) == "belt":
				var hz := float(an["hz"])
				var hx := float(an["hx"])
				var by := FOOT + 0.03
				for sx in [-1.0, 1.0]:
					var bx: float = sx * (hx - 0.03)
					out.append({"name": "Y belt", "points": PackedVector3Array([Vector3(bx, by, -hz + 0.03), Vector3(bx, by, g.z - 0.06), Vector3(bx, by, g.z + 0.06),
						Vector3(bx, by, hz - 0.03), Vector3(bx, by + 0.012, hz - 0.03), Vector3(bx, by + 0.012, -hz + 0.03)]), "key": "belt"})
	return out


## Delta arms for drawing: six segments carriage ↔ effector (machine space).
static func delta_arms(lay: Dictionary, po: Dictionary) -> Array:
	if str(lay["kinematics"]) != "delta":
		return []
	var out: Array = []
	var eff := assembly_origin(lay, po, "Effector")
	var eff_r := float(lay["assemblies"]["Effector"]["eff_r"])
	for i in 3:
		var name := "Carriage%s" % ["A", "B", "C"][i]
		var asm: Dictionary = lay["assemblies"][name]
		var car := assembly_origin(lay, po, name)
		var inward: Vector3 = asm["inward"]
		var side := inward.cross(Vector3.UP).normalized() * 0.025
		var car_r := float(asm["car_r"])
		var e_pt := eff + Vector3(0, 0.03, 0) - inward * eff_r
		var c_pt := car + Vector3(0, 0.03, 0) + inward * car_r
		out.append([c_pt + side, e_pt + side])
		out.append([c_pt - side, e_pt - side])
	return out


## Every beam of the machine (static + assemblies), for the cut list.
static func all_beams(lay: Dictionary) -> Array:
	var out: Array = []
	out.append_array(lay["static"]["beams"])
	for name in lay["assemblies"]:
		out.append_array((lay["assemblies"][name] as Dictionary)["beams"])
	return out


static func all_parts(lay: Dictionary) -> Array:
	var out: Array = []
	out.append_array(lay["static"]["parts"])
	for name in lay["assemblies"]:
		out.append_array((lay["assemblies"][name] as Dictionary)["parts"])
	return out
