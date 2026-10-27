class_name GantryLabFrame
extends RefCounted

## The geometry of a gantry from its spec: every extrusion (a cut list), the
## real parts (GantryLabDetail kinds: wheel plates, motors on brackets, lead
## screws with couplers and nuts, GT2 pulleys and idlers, endstops, hotends,
## the Bowden tube…) grouped into the STATIC frame and the MOVING assemblies,
## the belt LOOPS as pulley lists the tangent solver turns into belts, the
## SPIN sources (which motor turns each pulley / screw / wheel and by how
## much per mm), and `pose()` — where each assembly sits for a tool position.
## The builder draws exactly this; the BOM counts exactly this.
##
## Machine frame (metres): X right, Y away from the operator (local +Z), Z up.
## The work origin (0, 0, 0) is the front-left corner of the bed at its
## surface; tool mm map straight onto it.
##
## layout(spec) → {
##   dims {w, d, h}, origin, static {beams, parts}, assemblies {name: {parent,
##   base, beams, parts, mass_kg, axis}}, loops [{name, motor, sign, belt_w,
##   n, nodes: [{asm, c, r, s, kind}]}], links [{kind, a: {asm, c}, b: {asm,
##   c}, ta, tb, r}], bed, screws, moving_kg, spans, anchors, bead_parent,
##   bead_origin }
## A part with a `spin` dict {motor, per_rev_mm, sign} turns about its own
## +Y by motor_mm / per_rev_mm turns.

const MARGIN_X := 0.06
const MARGIN_Y := 0.06
const FOOT := 0.02
const WHEEL_R := 0.012
const WHEEL_W := 0.0102
const IDLER_R := 0.0064
const SPRING_H := 0.02
const BED_STACK := {"heated_pcb": 0.0086, "alu_plate": 0.006, "spoilboard": 0.018, "honeycomb": 0.02, "none": 0.02}
const TOOL_MOUNT_H := {"hotend_04": 0.048, "hotend_08": 0.058, "pellet_extruder": 0.11, "flake_extruder_6mm": 0.17, "clay_extruder": 0.2,
	"spindle_500w": 0.07, "router_1250w": 0.07, "spindle_2200w": 0.07, "laser_10w": 0.05, "laser_40w_co2": 0.05, "pen": 0.07}
const TOOL_KINDS := {"hotend_04": "hotend", "hotend_08": "hotend", "pellet_extruder": "pellet_extruder", "flake_extruder_6mm": "pellet_extruder", "clay_extruder": "clay_extruder",
	"spindle_500w": "spindle", "router_1250w": "spindle", "spindle_2200w": "spindle", "laser_10w": "laser", "laser_40w_co2": "laser", "pen": "pen"}
## Tools drawn from a model: the GLB, where its nozzle tip is in the model's
## own frame (the tool's origin goes there), nodes to drop (SketchUp leftovers),
## and its envelope round the tip (clash box, clearances). Measured with
## core/placed_models/glb_dump_diag.gd. Without the art the procedural kind
## in TOOL_KINDS is drawn instead.
const TOOL_SCENES := {
	"flake_extruder_6mm": {"path": "res://Imported Models/Gantry/trash_printer_extruder.glb", "tip": Vector3(0.0001, -0.1597, 0.0006),
		"strip": ["Node2", "Node5", "Laser Printer", "Active View"],
		"env": AABB(Vector3(-0.0501, 0.0, -0.1216), Vector3(0.1089, 0.3893, 0.1718))},
}
## How far behind the nozzle axis the carriage face is (default 13.5 mm):
## the flake extruder's 4" flange stands 51 mm behind its axis.
const TOOL_MOUNT_BACK := {"flake_extruder_6mm": 0.054}
const MASS_KINDS := {"motor": 0.3, "plate": 0.25, "rail": 0.1, "extruder": 0.45}


static func layout(spec: Dictionary) -> Dictionary:
	var s := GantryLabSpec.resolve(spec)
	if GantryLabAssembly.uses_assembly(str(s["kinematics"])):
		return GantryLabAssembly.layout(s)
	var lay: Dictionary
	match str(s["kinematics"]):
		"bedslinger", "corexz":
			lay = _layout_bedslinger(s)
		"delta":
			lay = _layout_delta(s)
		"router":
			lay = _layout_router(s)
		_:
			lay = _layout_bedslinger(s)
	if not lay.has("loops"):
		lay["loops"] = []
	if not lay.has("links"):
		lay["links"] = []
	return lay


# ---------------------------------------------------------------------------
# Part constructors
# ---------------------------------------------------------------------------

static func _p(id: String) -> Dictionary:
	return GantryLabParts.profile(id)


static func _w(id: String) -> float:
	return float(_p(id)["w_mm"]) * 0.001


static func _h(id: String) -> float:
	return float(_p(id)["h_mm"]) * 0.001


static func _beam(a: Vector3, b: Vector3, profile: String, label: String, group: String, up: Vector3 = Vector3.UP) -> Dictionary:
	return {"a": a, "b": b, "profile": profile, "label": label, "group": group, "up": up}


## A part dict: kind, seat, frame, label, a pick extent and the kind's params.
static func _pk(kind: String, c: Vector3, label: String, s: Vector3, extra: Dictionary = {}, basis: Basis = Basis.IDENTITY) -> Dictionary:
	var d := {"kind": kind, "c": c, "s": s, "label": label, "basis": basis}
	for k in extra:
		d[k] = extra[k]
	return d


static func _part(c: Vector3, s: Vector3, kind: String, label: String) -> Dictionary:
	return _pk(kind, c, label, s)


static func _box(c: Vector3, s: Vector3, label: String, mat: String = "black") -> Dictionary:
	return _pk("box", c, label, s, {"mat": mat})


## A plate standing in the XY plane (thin along Z): w across X, h up Y.
static func _plate_xy(c: Vector3, w: float, h: float, t: float, label: String) -> Dictionary:
	return _pk("plate", c, label, Vector3(w, h, t), {"s": Vector3(w, t, h)}, Basis(Vector3.RIGHT, -PI * 0.5))


## A plate standing in the YZ plane (thin along X): d across Z, h up Y.
static func _plate_yz(c: Vector3, d: float, h: float, t: float, label: String) -> Dictionary:
	return _pk("plate", c, label, Vector3(t, h, d), {"s": Vector3(h, t, d)}, Basis(Vector3.FORWARD, PI * 0.5))


## A flat plate (thin along Y).
static func _plate_flat(c: Vector3, w: float, d: float, t: float, label: String) -> Dictionary:
	return _pk("plate", c, label, Vector3(w, t, d))


static func _motor_size(id: String) -> Vector3:
	var m := GantryLabParts.motor(id)
	var f := float(m["frame_mm"]) * 0.001
	return Vector3(f, float(m["len_mm"]) * 0.001, f)


## A motor by its mounting face and shaft direction.
static func _motor(face: Vector3, axis: Vector3, motor_id: String, label: String, shaft: float = 0.024) -> Dictionary:
	var ms := _motor_size(motor_id)
	var a := axis.normalized()
	return _pk("motor", face, label, Vector3(ms.x, ms.x, ms.x), {"frame": ms.x, "len": ms.y, "shaft": shaft, "pick_c": face - a * ms.y * 0.5}, GantryLabDetail.basis_y(a))


static func belt_off(belt_w: float, y0: float = 0.006) -> float:
	return y0 + 0.002 + belt_w * 0.5


static func _spin(motor: int, per_rev_mm: float, sign: float = 1.0) -> Dictionary:
	return {"motor": motor, "per_rev_mm": per_rev_mm, "sign": sign}


static func _belt_w(s: Dictionary, k: String) -> float:
	return float(GantryLabParts.drive(str(s["axis"][k]["drive"])).get("width_mm", 6.0)) * 0.001


## Which entry of GantryLabKinematics.motor_positions drives an axis key.
static func motor_index(kin: String, k: String) -> int:
	match kin:
		"corexy", "hbot":
			return {"x": 0, "a": 0, "b": 1, "y": 1, "z": 2}.get(k, 0)
		"corexz":
			return {"x": 0, "a": 0, "b": 1, "z": 1, "y": 2}.get(k, 0)
		"delta":
			return {"a": 0, "b": 1, "c": 2}.get(k, 0)
	return {"x": 0, "y": 1, "z": 2}.get(k, 0)


## A lead screw (spin), its coupler on the motor shaft, from `a` along `axis`.
static func _screw_set(parts: Array, a: Vector3, axis: Vector3, len: float, drive: Dictionary, motor: int, label: String) -> void:
	var ax := axis.normalized()
	parts.append(_pk("coupler", a - ax * 0.005, label + " coupler", Vector3(0.02, 0.025, 0.02), {"len": 0.025, "spin": _spin(motor, float(drive["lead_mm"]))}, GantryLabDetail.basis_y(ax)))
	parts.append(_pk("screw", a + ax * 0.015, label, Vector3(0.01, len, 0.01), {"len": len - 0.015, "d_mm": float(drive["d_mm"]), "lead_mm": float(drive["lead_mm"]),
		"starts": maxi(1, int(round(float(drive["lead_mm"]) / 2.0))) if str(drive.get("kind", "")) == "screw" and float(drive["d_mm"]) <= 8.0 else 1,
		"spin": _spin(motor, float(drive["lead_mm"]))}, GantryLabDetail.basis_y(ax)))


static func _nut(c: Vector3, axis: Vector3, label: String) -> Dictionary:
	return _pk("nut_tr8", c, label, Vector3(0.022, 0.015, 0.022), {}, GantryLabDetail.basis_y(axis))


## A V-wheel rolling along `roll` (the axis it travels), spinning about
## `axis`; the axle's spacer and bolt head on the `axis` side.
static func _wheel(parts: Array, c: Vector3, axis: Vector3, motor: int, label: String, gap: float = 0.006) -> void:
	var b := GantryLabDetail.basis_y(axis)
	parts.append(_pk("wheel", c, label, Vector3(0.024, 0.0102, 0.024), {"spin": _spin(motor, TAU * WHEEL_R * 1000.0)}, b))
	parts.append(_pk("wheel_axle", c, label + " axle", Vector3(0.009, 0.03, 0.009), {"gap": gap}, b))


static func _endstop(c: Vector3, lever: Vector3, up: Vector3, label: String) -> Dictionary:
	var x := lever.normalized()
	var y := up.normalized()
	return _pk("endstop", c, label, Vector3(0.02, 0.012, 0.015), {}, Basis(x, y, x.cross(y).normalized()))


static func _tool_part(s: Dictionary, tip: Vector3) -> Dictionary:
	var tool_id := str(s["tool"]["id"])
	var tool := GantryLabParts.tool(tool_id)
	var kind := str(TOOL_KINDS.get(tool_id, "tool"))
	var h := float(TOOL_MOUNT_H.get(tool_id, 0.06))
	var extra := {"tool": tool_id, "volcano": tool_id == "hotend_08", "pick_c": tip + Vector3(0, h * 0.6, 0)}
	var sc := tool_scene(tool_id)
	if not sc.is_empty():
		extra["scene"] = sc
	return _pk(kind, tip, str(tool["label"]), Vector3(0.05, h + 0.03, 0.05), extra)


static func tool_mount_h(tool_id: String) -> float:
	return float(TOOL_MOUNT_H.get(tool_id, 0.06))


static func tool_mount_back(tool_id: String) -> float:
	return float(TOOL_MOUNT_BACK.get(tool_id, 0.0135))


## The model a tool is drawn from ({} = procedural), only when the art is there.
static func tool_scene(tool_id: String) -> Dictionary:
	var d: Dictionary = TOOL_SCENES.get(tool_id, {})
	if d.is_empty() or not ResourceLoader.exists(str(d["path"])):
		return {}
	return d


## How far the tool reaches to either side of its nozzle axis, metres.
static func tool_side(tool_id: String) -> float:
	var d: Dictionary = TOOL_SCENES.get(tool_id, {})
	if d.is_empty():
		return 0.02
	var env: AABB = d["env"]
	return maxf(-env.position.x, env.end.x)


## How far the tool reaches ahead of its nozzle axis (toward -Z, away from the
## carriage), metres.
static func tool_front(tool_id: String) -> float:
	var d: Dictionary = TOOL_SCENES.get(tool_id, {})
	if d.is_empty():
		return 0.03
	return -(d["env"] as AABB).position.z


static func _bed(c: Vector3, size: Vector2, kind: String, label: String) -> Dictionary:
	return _pk("bed", c, label, Vector3(size.x, 0.012, size.y), {"size": size, "bed_kind": kind, "pick_c": c - Vector3(0, 0.005, 0)})


static func _bed_stack(kind: String) -> float:
	return float(BED_STACK.get(kind, 0.01))


static func _foot(c: Vector3) -> Dictionary:
	return _pk("foot", c, "Rubber foot", Vector3(0.026, 0.011, 0.026), {"pick_c": c - Vector3(0, 0.005, 0)})


## A cast corner bracket with its legs along `leg_a` and `leg_b` from the
## inside corner `c`.
static func _corner(c: Vector3, leg_a: Vector3, leg_b: Vector3) -> Dictionary:
	var x := leg_a.normalized()
	var y := leg_b.normalized()
	return _pk("corner_bracket", c, "Corner bracket", Vector3(0.02, 0.02, 0.02), {"pick_c": c + (x + y) * 0.008}, Basis(x, y, x.cross(y).normalized()))


static func _mass_of(beams: Array, parts: Array, extra_kg: float = 0.0) -> float:
	var kg := extra_kg
	for b in beams:
		var bd: Dictionary = b
		kg += (bd["a"] as Vector3).distance_to(bd["b"] as Vector3) * float(_p(str(bd["profile"]))["kg_m"])
	for p in parts:
		kg += float(MASS_KINDS.get(str((p as Dictionary)["kind"]), 0.0))
	return kg


static func _loop(name: String, motor: int, sign: float, belt_w: float, n: Vector3, nodes: Array) -> Dictionary:
	return {"name": name, "motor": motor, "sign": sign, "belt_w": belt_w, "n": n.normalized(), "nodes": nodes}


static func _node(asm: String, c: Vector3, r: float, s: float, kind: String) -> Dictionary:
	return {"asm": asm, "c": c, "r": r, "s": s, "kind": kind}


## Put the pulley / idler spin parts of a loop into the assemblies' part
## lists (`""` = static). A pulley node carries `face` (its motor's face) and
## `teeth`; an idler node its base post height `post_from` (Vector3) when it
## stands on a post.
static func _loop_parts(lay_static: Array, asms: Dictionary, loop: Dictionary) -> void:
	var n: Vector3 = loop["n"]
	var w := float(loop["belt_w"])
	var motor := int(loop["motor"])
	var sign := float(loop["sign"])
	for nd in loop["nodes"]:
		var node: Dictionary = nd
		var target: Array = lay_static if str(node["asm"]).is_empty() else (asms[node["asm"]] as Dictionary)["parts"]
		var axis: Vector3 = node.get("axis", n)
		var r := float(node["r"])
		var c: Vector3 = node["c"]
		match str(node["kind"]):
			"pulley":
				var face: Vector3 = node.get("face", c - axis * belt_off(w))
				var y0 := c.distance_to(face) - 0.002 - w * 0.5
				target.append(_pk("pulley", face, "%s pulley" % str(loop["name"]), Vector3(0.016, 0.02, 0.016), {"teeth": int(node.get("teeth", 20)), "belt_w": w, "y0": y0,
					"spin": _spin(motor, TAU * r * 1000.0, float(node["s"]) * sign)}, GantryLabDetail.basis_y(axis)))
			"idler":
				var origin := c - axis * (0.002 + w * 0.5)
				var bolt_down := float(node.get("bolt_down", 0.006))
				target.append(_pk("idler", origin, "%s idler" % str(loop["name"]), Vector3(0.016, 0.014, 0.016), {"r": r, "belt_w": w, "bolt_down": bolt_down,
					"spin": _spin(motor, TAU * r * 1000.0, float(node["s"]) * sign)}, GantryLabDetail.basis_y(axis)))
				if node.has("post_from"):
					var pf: Vector3 = node["post_from"]
					var top := origin - axis * bolt_down
					target.append(_box((pf + top) * 0.5, Vector3(0.014, 0.014, 0.014).max((top - pf).abs()), "Idler post"))
			"clamp":
				target.append(_pk("belt_clamp", c, "Belt clamp", Vector3(0.02, 0.008, 0.012), {"s": node.get("size", Vector3(0.02, 0.008, 0.012))}, node.get("basis", Basis.IDENTITY)))


# ---------------------------------------------------------------------------
# Bed-slinger / CoreXZ: the CR-10 pattern. Y bed on two standing 2040 rails,
# uprights outside the rails, an X beam between Z plates on wheels.
# ---------------------------------------------------------------------------

static func _layout_bedslinger(s: Dictionary) -> Dictionary:
	var v: Dictionary = s["volume"]
	var vx := float(v["x_mm"]) * 0.001
	var vy := float(v["y_mm"]) * 0.001
	var vz := float(v["z_mm"]) * 0.001
	var kin := str(s["kinematics"])
	var corexz := kin == "corexz"
	var pf := str(s["frame"]["profile"])
	var gf := str(s["frame"]["gantry_profile"])
	var pw := _w(pf)
	var ph := _h(pf)
	var gw := _w(gf)
	var gh := _h(gf)
	var tool_id := str(s["tool"]["id"])
	var bed_kind := str(s["tool"]["bed"])
	var base_len := 2.0 * vy + 2.0 * MARGIN_Y + 0.08
	var base_w := vx + 2.0 * MARGIN_X + 2.0 * pw
	var y0 := -base_len * 0.5
	var rail_x := base_w * 0.5 - pw * 0.5
	var gy := 0.0
	var st_beams: Array = []
	var st_parts: Array = []
	var screws: Array = []
	var loops: Array = []
	var links: Array = []
	var mi_x := motor_index(kin, "x")
	var mi_y := motor_index(kin, "y")
	var mi_z := motor_index(kin, "z")
	# --- Base ------------------------------------------------------------
	for sx in [-1.0, 1.0]:
		st_beams.append(_beam(Vector3(sx * rail_x, ph * 0.5, y0), Vector3(sx * rail_x, ph * 0.5, y0 + base_len), pf, "Y rail", "base"))
	for zz in [y0 + pw * 0.5, y0 + base_len - pw * 0.5]:
		st_beams.append(_beam(Vector3(-rail_x + pw * 0.5, ph * 0.5, zz), Vector3(rail_x - pw * 0.5, ph * 0.5, zz), pf, "Base cross", "base"))
		for sx in [-1.0, 1.0]:
			st_parts.append(_corner(Vector3(sx * (rail_x - pw * 0.5), ph, zz), Vector3(-sx, 0, 0), Vector3.DOWN))
	if bool(s["frame"]["feet"]):
		for sx in [-1.0, 1.0]:
			for zz in [y0 + 0.035, y0 + base_len - 0.035]:
				st_parts.append(_foot(Vector3(sx * rail_x, 0.0, zz)))
	# --- Bed carriage on wheels -------------------------------------------
	var axle_y := ph + WHEEL_R
	var plate_bot := ph + 2.0 * WHEEL_R + 0.004
	var plate_t := 0.006
	var plate_top := plate_bot + plate_t
	var bed_top := plate_top + SPRING_H + _bed_stack(bed_kind)
	var bed_size := Vector2(vx + 0.02, vy + 0.02)
	var bed_parts: Array = [_plate_flat(Vector3(0, plate_bot + plate_t * 0.5, 0), base_w - 2.0 * pw - 0.004, maxf(vy * 0.75, 0.12), plate_t, "Y carriage plate")]
	var wdz := clampf(vy * 0.3, 0.045, 0.25)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var c := Vector3(sx * rail_x, axle_y, sz * wdz)
			_wheel(bed_parts, c, Vector3(sx, 0, 0), mi_y, "Y wheel", 0.004)
			# A hanger from the plate down beside the wheel.
			bed_parts.append(_box(Vector3(sx * (rail_x + WHEEL_W * 0.5 + 0.009), (plate_bot + axle_y - 0.006) * 0.5, sz * wdz), Vector3(0.006, plate_bot - axle_y + 0.006, 0.03), "Wheel hanger", "plate"))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			bed_parts.append(_pk("spring_knob", Vector3(sx * (vx * 0.5 - 0.012), plate_top, sz * (vy * 0.5 - 0.012)), "Levelling spring", Vector3(0.018, 0.034, 0.018), {"h": SPRING_H}))
	bed_parts.append(_bed(Vector3(0, bed_top, 0), bed_size, bed_kind, str(GantryLabParts.bed(bed_kind)["label"])))
	var bed_kg := float(GantryLabParts.bed(bed_kind)["kg_m2"]) * bed_size.x * bed_size.y + 0.9
	# Y belt under the bed: motor at the back on a pedestal, idler at the front.
	var belt_w_y := _belt_w(s, "y")
	var belt_y := 0.03
	var yr := GantryLabDetail.gt2_pitch_radius(int(s["axis"]["y"]["pulley_teeth"]))
	var ym_z := y0 + base_len - pw - 0.03
	var y_face := Vector3(-belt_off(belt_w_y), belt_y, ym_z)
	st_parts.append(_motor(y_face, Vector3.RIGHT, str(s["axis"]["y"]["motor"]), "Y motor"))
	st_parts.append(_box(Vector3(-belt_off(belt_w_y) - 0.021, (belt_y - 0.021) * 0.5, ym_z), Vector3(0.044, belt_y - 0.021, 0.044), "Y motor pedestal", "plate"))
	var yi_z := y0 + pw + 0.025
	bed_parts.append(_box(Vector3(0, (plate_bot + belt_y + yr) * 0.5, 0), Vector3(0.02, plate_bot - belt_y - yr, 0.03), "Y belt clamp block"))
	var y_loop := _loop("Y belt", mi_y, 1.0, belt_w_y, Vector3.RIGHT, [
		_node("", Vector3(0, belt_y, ym_z), yr, 1.0, "pulley").merged({"face": y_face, "teeth": int(s["axis"]["y"]["pulley_teeth"])}),
		_node("Bed", Vector3(0, belt_y + yr, 0), 0.0, 0.0, "clamp").merged({"size": Vector3(0.012, 0.006, 0.02)}),
		_node("", Vector3(0, belt_y, yi_z), IDLER_R, 1.0, "idler").merged({"post_from": Vector3(-0.009, 0.0, yi_z), "axis": Vector3.LEFT, "bolt_down": 0.0}),
	])
	loops.append(y_loop)
	# --- Uprights, top beam -----------------------------------------------
	var hotend_h := tool_mount_h(tool_id)
	var xb_y0 := bed_top + hotend_h + 0.045 + 0.003  # X beam centre at z = 0
	var col_h := xb_y0 + vz + 0.065
	var col_x := base_w * 0.5 + 0.02 + 0.004
	for sx in [-1.0, 1.0]:
		st_beams.append(_beam(Vector3(sx * col_x, 0.0, gy), Vector3(sx * col_x, col_h, gy), gf, "Upright", "gantry", Vector3.RIGHT))
		st_parts.append(_corner(Vector3(sx * (col_x - 0.02), ph, gy), Vector3(-sx, 0, 0), Vector3.UP))
		st_parts.append(_corner(Vector3(sx * (col_x - 0.02), col_h, gy), Vector3(-sx, 0, 0), Vector3.DOWN))
	st_beams.append(_beam(Vector3(-col_x - 0.02, col_h + 0.01, gy), Vector3(col_x + 0.02, col_h + 0.01, gy), "2020", "Top beam", "gantry"))
	# --- Z plates, screws (or CoreXZ belts), the X beam -------------------
	var z_p := gy - 0.0125
	var z_beam := z_p - 0.0015 - gw * 0.5
	var beam_front := z_beam - gw * 0.5
	var xb_half := col_x - 0.055
	var xb_beams: Array = [_beam(Vector3(-xb_half, xb_y0, z_beam), Vector3(xb_half, xb_y0, z_beam), gf, "X beam", "x_axis")]
	var xb_parts: Array = []
	var z_dr := GantryLabParts.drive(str(s["axis"]["z"]["drive"]))
	var z_count := 2 if corexz else clampi(int(s["axis"]["z"]["motors"]), 1, 2)
	for i in 2:
		var sx := -1.0 if i == 0 else 1.0
		var px: float = sx * col_x
		xb_parts.append(_plate_xy(Vector3(px, xb_y0, z_p), 0.12, 0.12, 0.003, "Z carriage plate"))
		for wx in [-1.0, 1.0]:
			for wy in [-1.0, 1.0]:
				_wheel(xb_parts, Vector3(px + wx * (0.02 + WHEEL_R - 0.0025), xb_y0 + wy * 0.03, gy), Vector3.FORWARD, mi_z, "Z wheel")
		if not corexz and (z_count == 2 or i == 0):
			var x_s: float = sx * (col_x - 0.045)
			var z_s := z_p - 0.0015 - 0.01
			# Tab on the plate, the nut on it, the motor on an L bracket at the foot.
			xb_parts.append(_box(Vector3(x_s, xb_y0 - 0.045, z_s), Vector3(0.03, 0.004, 0.02), "Nut tab", "plate"))
			xb_parts.append(_nut(Vector3(x_s, xb_y0 - 0.043, z_s), Vector3.UP, "Z nut"))
			var mf := Vector3(x_s, 0.085, z_s)
			st_parts.append(_motor(mf, Vector3.UP, str(s["axis"]["z"]["motor"]), "Z motor %d" % (i + 1)))
			st_parts.append(_pk("bracket_l", Vector3(sx * (col_x - 0.02), 0.045, z_s), "Z motor bracket", Vector3(0.046, 0.052, 0.046), {"a": 0.048, "b": 0.052, "w": 0.046},
				Basis(Vector3(-sx, 0, 0), Vector3.UP, Vector3(0, 0, -sx))))
			_screw_set(st_parts, mf + Vector3(0, 0.004, 0), Vector3.UP, col_h - 0.012 - 0.089, z_dr, mi_z, "Z screw")
			screws.append({"a": Vector3(x_s, 0.1, z_s), "b": Vector3(x_s, col_h - 0.012, z_s), "d_mm": float(z_dr["d_mm"]), "label": "Z screw"})
	# Z endstop on the left upright, X endstop on the beam's left end.
	st_parts.append(_endstop(Vector3(-col_x + 0.005, xb_y0 - 0.065, gy - 0.01), Vector3.UP, Vector3.FORWARD, "Z endstop"))
	# --- X axis: motor at the beam's left end, idler at the right -----------
	var belt_w_x := _belt_w(s, "x")
	var z_belt := beam_front - 0.008
	var xr := GantryLabDetail.gt2_pitch_radius(int(s["axis"]["x"]["pulley_teeth"]))
	var xm_x := -xb_half + 0.025
	var x_face := Vector3(xm_x, xb_y0, z_belt - belt_off(belt_w_x))
	var car_z := beam_front - 0.0125
	var car_parts: Array = []
	var tool_tip := Vector3(-vx * 0.5, bed_top, gy)
	if not corexz:
		xb_parts.append(_motor(x_face, Vector3.BACK, str(s["axis"]["x"]["motor"]), "X motor"))
		xb_parts.append(_plate_xy(Vector3(xm_x, xb_y0, beam_front - 0.002), 0.05, 0.05, 0.004, "X motor plate"))
		xb_parts.append(_endstop(Vector3(-xb_half + 0.06, xb_y0 + 0.014, beam_front), Vector3.RIGHT, Vector3.FORWARD, "X endstop"))
		loops.append(_loop("X belt", mi_x, 1.0, belt_w_x, Vector3.BACK, [
			_node("XBeam", Vector3(xm_x, xb_y0, z_belt), xr, 1.0, "pulley").merged({"face": x_face, "teeth": int(s["axis"]["x"]["pulley_teeth"])}),
			_node("XCarriage", Vector3(0, xb_y0 - xr, z_belt), 0.0, 0.0, "clamp").merged({"size": Vector3(0.016, 0.006, 0.009)}),
			_node("XBeam", Vector3(xb_half - 0.02, xb_y0, z_belt), IDLER_R, 1.0, "idler").merged({"post_from": Vector3(xb_half - 0.02, xb_y0, beam_front), "bolt_down": 0.0}),
		]))
	else:
		# CoreXZ: the belts share X and Z. Motors at the top of the uprights,
		# idlers at their feet, beam-end idlers on the Z plates, both belts
		# in front of the gantry at two depths.
		var zr := GantryLabDetail.gt2_pitch_radius(int(s["axis"]["x"]["pulley_teeth"]))
		var xm := col_x - 0.03
		var top_y := col_h - 0.03
		var bot_y := ph + 0.06
		var za := beam_front - 0.012
		var zb := beam_front - 0.024
		var fa := Vector3(-xm, top_y, za - belt_off(belt_w_x))
		var fb := Vector3(xm, top_y, zb - belt_off(belt_w_x))
		st_parts.append(_motor(fa, Vector3.BACK, str(s["axis"]["x"]["motor"]), "Motor A"))
		st_parts.append(_motor(fb, Vector3.BACK, str(s["axis"]["x"]["motor"]), "Motor B"))
		for sx in [-1.0, 1.0]:
			st_parts.append(_plate_xy(Vector3(sx * xm, top_y, beam_front - 0.002), 0.05, 0.05, 0.004, "Motor plate"))
		var r := IDLER_R
		loops.append(_loop("Belt A", 0, 1.0, belt_w_x, Vector3.BACK, [
			_node("", Vector3(-xm, top_y, za), zr, 1.0, "pulley").merged({"face": fa, "teeth": int(s["axis"]["x"]["pulley_teeth"])}),
			_node("", Vector3(-xm, bot_y, za), r, 1.0, "idler").merged({"post_from": Vector3(-xm, bot_y, gy - 0.01), "bolt_down": 0.0}),
			_node("XBeam", Vector3(-xm + 2.0 * r, xb_y0 + 0.014 - r, za), r, -1.0, "idler").merged({"post_from": Vector3(-xm + 2.0 * r, xb_y0 + 0.014 - r, z_p), "bolt_down": 0.0}),
			_node("XCarriage", Vector3(0, xb_y0 + 0.014, za), 0.0, 0.0, "clamp"),
			_node("XBeam", Vector3(xm - 2.0 * r, xb_y0 + 0.014 + r, za), r, 1.0, "idler").merged({"post_from": Vector3(xm - 2.0 * r, xb_y0 + 0.014 + r, z_p), "bolt_down": 0.0}),
			_node("", Vector3(xm - 2.0 * r, top_y, za), r, 1.0, "idler").merged({"post_from": Vector3(xm - 2.0 * r, top_y, gy - 0.01), "bolt_down": 0.0}),
		]))
		loops.append(_loop("Belt B", 1, 1.0, belt_w_x, Vector3.BACK, [
			_node("", Vector3(xm, top_y, zb), zr, -1.0, "pulley").merged({"face": fb, "teeth": int(s["axis"]["x"]["pulley_teeth"])}),
			_node("", Vector3(xm, bot_y, zb), r, -1.0, "idler").merged({"post_from": Vector3(xm, bot_y, gy - 0.01), "bolt_down": 0.0}),
			_node("XBeam", Vector3(xm - 2.0 * r, xb_y0 - 0.014 - r, zb), r, 1.0, "idler").merged({"post_from": Vector3(xm - 2.0 * r, xb_y0 - 0.014 - r, z_p), "bolt_down": 0.0}),
			_node("XCarriage", Vector3(0, xb_y0 - 0.014, zb), 0.0, 0.0, "clamp"),
			_node("XBeam", Vector3(-xm + 2.0 * r, xb_y0 - 0.014 + r, zb), r, -1.0, "idler").merged({"post_from": Vector3(-xm + 2.0 * r, xb_y0 - 0.014 + r, z_p), "bolt_down": 0.0}),
			_node("", Vector3(-xm + 2.0 * r, top_y, zb), r, -1.0, "idler").merged({"post_from": Vector3(-xm + 2.0 * r, top_y, gy - 0.01), "bolt_down": 0.0}),
		]))
	# --- X carriage: plate on wheels, the hotend hanging in front ----------
	car_parts.append(_plate_xy(Vector3(0, xb_y0, car_z), 0.07, 0.09, 0.003, "X carriage plate"))
	for wx in [-1.0, 1.0]:
		for wy in [-1.0, 1.0]:
			_wheel(car_parts, Vector3(wx * 0.025, xb_y0 + wy * (gh * 0.5 + WHEEL_R - 0.0025), z_beam), Vector3.FORWARD, mi_x, "X wheel")
	var hot_z := car_z - 0.0015 - 0.013
	car_parts.append(_tool_part(s, Vector3(0, tool_tip.y, hot_z)))
	var tool := GantryLabParts.tool(tool_id)
	var guide_x := GantryLabParts.guide(str(s["axis"]["x"]["guide"]))
	var car_kg := float(tool["kg"]) + float(guide_x["kg_carriage"]) + 0.15
	# --- Bowden extruder on the left Z plate, spool on the top beam --------
	var additive := str(tool["process"]) == "additive" and tool_id != "clay_extruder" and tool_id != "pellet_extruder"
	if additive:
		var ex_c := Vector3(-col_x + 0.02, xb_y0 + 0.035, z_p - 0.0015)
		var ex_b := Basis(Vector3.LEFT, Vector3.UP, Vector3.FORWARD)
		xb_parts.append(_pk("extruder", ex_c, "Bowden extruder", Vector3(0.042, 0.06, 0.05), {"pick_c": ex_c + Vector3(0, 0, -0.02)}, ex_b))
		var outlet := ex_c + ex_b * GantryLabDetail.EXTRUDER_OUTLET
		var inlet := ex_c + ex_b * GantryLabDetail.EXTRUDER_INLET
		links.append({"kind": "bowden", "a": {"asm": "XBeam", "c": outlet}, "b": {"asm": "XCarriage", "c": Vector3(0, tool_tip.y + GantryLabDetail.HOTEND_H + 0.0135, hot_z)},
			"ta": Vector3.DOWN, "tb": Vector3.UP, "r": 0.002})
		var spool_y := col_h + 0.02 + 0.105
		st_parts.append(_pk("spool", Vector3(-0.0325, spool_y, gy), "Filament spool", Vector3(0.2, 0.2, 0.065), {"r": 0.1, "w": 0.065, "fill": 0.72, "pick_c": Vector3(0, spool_y, gy)}, GantryLabDetail.basis_y(Vector3.RIGHT)))
		st_parts.append(_box(Vector3(0.045, (col_h + 0.02 + spool_y) * 0.5, gy), Vector3(0.008, spool_y - col_h - 0.02, 0.03), "Spool holder"))
		links.append({"kind": "filament", "a": {"asm": "", "c": Vector3(-0.0, spool_y - 0.072, gy)}, "b": {"asm": "XBeam", "c": inlet}, "ta": Vector3.DOWN, "tb": Vector3.UP, "r": 0.0009})
	# --- Electronics: LCD at the front right, PSU + board beside the base --
	var lcd_b := Basis(Vector3.RIGHT, deg_to_rad(25.0)) * Basis(Vector3.UP, PI)
	st_parts.append(_pk("lcd", Vector3(base_w * 0.5 - 0.07, ph + 0.04, y0 - 0.012), "Display", Vector3(0.1, 0.062, 0.02), {}, lcd_b))
	st_parts.append(_box(Vector3(base_w * 0.5 - 0.07, ph + 0.012, y0 - 0.006), Vector3(0.03, 0.024, 0.012), "Display bracket", "plate"))
	var psu_x := base_w * 0.5 + 0.075
	st_parts.append(_pk("psu", Vector3(psu_x, 0.025, y0 + base_len * 0.3), "Power supply", Vector3(0.115, 0.05, 0.215), {"s": Vector3(0.115, 0.05, 0.215)}))
	st_parts.append(_pk("board", Vector3(psu_x, 0.001, y0 + base_len * 0.72), str(GantryLabParts.board(str(s["electronics"]["board"]))["label"]), Vector3(0.1, 0.03, 0.09),
		{"s": Vector3(0.1, 0.0016, 0.09), "drivers": int(GantryLabParts.board(str(s["electronics"]["board"]))["drivers"])}))
	st_parts.append(_endstop(Vector3(rail_x, ph, y0 + base_len - pw - 0.028), Vector3.FORWARD, Vector3.UP, "Y endstop"))
	# --- Masses, assemblies ------------------------------------------------
	var xbeam_kg := _mass_of(xb_beams, xb_parts) + float(guide_x["kg_m"]) * xb_half * 2.0 + (0.0 if corexz else float(GantryLabParts.motor(str(s["axis"]["x"]["motor"]))["kg"]))
	var assemblies := {
		"XBeam": {"parent": "", "base": Vector3(0, 0, 0), "beams": xb_beams, "parts": xb_parts, "mass_kg": xbeam_kg + car_kg, "axis": "z"},
		"XCarriage": {"parent": "XBeam", "base": Vector3(tool_tip.x, 0, 0), "beams": [], "parts": car_parts, "mass_kg": car_kg, "axis": "x"},
		"Bed": {"parent": "", "base": Vector3(0, 0, 0), "beams": [], "parts": bed_parts, "mass_kg": bed_kg, "axis": "y"},
	}
	for lp in loops:
		_loop_parts(st_parts, assemblies, lp)
	var dims := Vector3(2.0 * col_x + 0.04 + 0.15, col_h + 0.02 + (0.23 if additive else 0.0), base_len)
	return {
		"kinematics": kin, "dims": dims,
		"origin": tool_tip, "static": {"beams": st_beams, "parts": st_parts},
		"assemblies": assemblies, "bed": {"size": bed_size, "kind": bed_kind}, "screws": screws, "loops": loops, "links": links,
		"moving_kg": {"x": car_kg, "y": bed_kg, "z": xbeam_kg + car_kg},
		"spans": {"x_beam_m": xb_half * 2.0, "y_rail_m": base_len, "z_col_m": col_h},
		"anchors": {"gantry_y": gy, "col_x": col_x, "col_h": col_h, "xb_y": xb_y0, "base_y0": y0, "base_len": base_len, "ph": ph, "bed_top": bed_top, "vy": vy},
		"bead_parent": "Bed", "bead_origin": Vector3(-vx * 0.5, bed_top, -vy * 0.5),
	}


# ---------------------------------------------------------------------------
# Legacy part helpers (the cube / delta / router layouts still describe
# their motors and plates as centre + size boxes; GantryLabDetail draws a
# `motor` with `c`+`s` as a real NEMA standing on its −Y face).
# ---------------------------------------------------------------------------

static func _bed_part(s: Dictionary, c: Vector3, size: Vector2) -> Dictionary:
	return _bed(c, size, str(s["tool"]["bed"]), str(GantryLabParts.bed(str(s["tool"]["bed"]))["label"]))


static func _legacy_motor(c: Vector3, size: Vector3, motor_id: String, label: String) -> Dictionary:
	return _motor(c + Vector3(0, size.y * 0.5, 0), Vector3.UP, motor_id, label)


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
	var bed_kind := str(s["tool"]["bed"])
	var bed_top := FOOT + pw + 0.05
	var tool_id := str(s["tool"]["id"])
	var eff_h := tool_mount_h(tool_id) + 0.002
	var tower_h := bed_top + vz + eff_h + float(reach["h_centre_mm"]) * 0.001 + 0.1
	var static_beams: Array = []
	var static_parts: Array = []
	var towers: Array = []
	var loops: Array = []
	var links: Array = []
	var belt_w := _belt_w(s, "z")
	var zr := GantryLabDetail.gt2_pitch_radius(int(s["axis"]["z"]["pulley_teeth"]))
	var guide := GantryLabParts.guide(str(s["axis"]["z"]["guide"]))
	var zm := _motor_size(str(s["axis"]["z"]["motor"]))
	for i in 3:
		var a := deg_to_rad(float(GantryLabKinematics.DELTA_TOWER_DEG[i]))
		var tx := cos(a) * tower_r
		var tz := sin(a) * tower_r
		towers.append(Vector3(tx, 0, tz))
		static_beams.append(_beam(Vector3(tx, FOOT, tz), Vector3(tx, tower_h, tz), pf, "Tower", "frame"))
		if bool(s["frame"]["feet"]):
			static_parts.append(_foot(Vector3(tx, FOOT, tz)))
	for yy in [FOOT + pw * 0.5, tower_h - pw * 0.5]:
		for i in 3:
			var ta: Vector3 = towers[i]
			var tb: Vector3 = towers[(i + 1) % 3]
			var out := ((ta + tb) * 0.5).normalized() * pw
			static_beams.append(_beam(Vector3(ta.x, yy, ta.z) + out, Vector3(tb.x, yy, tb.z) + out, pf, "Base beam" if yy < 1.0 else "Top beam", "frame"))
	var bed_size := Vector2(vd + 0.02, vd + 0.02)
	static_parts.append(_pk("bed_round", Vector3(0, bed_top, 0), str(GantryLabParts.bed(bed_kind)["label"]), Vector3(vd + 0.02, 0.012, vd + 0.02), {"r": vd * 0.5 + 0.01, "bed_kind": bed_kind, "pick_c": Vector3(0, bed_top - 0.005, 0)}))
	static_parts.append(_pk("board", Vector3(0, FOOT + pw + 0.001, 0), str(GantryLabParts.board(str(s["electronics"]["board"]))["label"]), Vector3(0.11, 0.03, 0.09),
		{"s": Vector3(0.11, 0.0016, 0.09), "drivers": int(GantryLabParts.board(str(s["electronics"]["board"]))["drivers"])}))
	var tool := GantryLabParts.tool(tool_id)
	var assemblies := {}
	var car_r := float(dl["carriage_r_mm"]) * 0.001
	var side_names := ["A", "B", "C"]
	for i in 3:
		var t: Vector3 = towers[i]
		var inward := -Vector3(t.x, 0, t.z).normalized()
		var tang := inward.cross(Vector3.UP).normalized()
		# The rail on the tower's inner face, the belt beside it.
		var rail_len := tower_h - FOOT - 2.0 * pw
		if float(guide["kg_m"]) > 0.0:
			static_parts.append(_pk("rail", Vector3(t.x, FOOT + pw, t.z) + inward * (pw * 0.5), str(guide["label"]), Vector3(0.012, rail_len, 0.012), {"len": rail_len, "hole_pitch": 0.025},
				GantryLabDetail.basis_yz(Vector3.UP, inward)))
		var cpos := Vector3(t.x, bed_top, t.z)
		var car_parts: Array = []
		var plate_in := pw * 0.5 + 0.0255
		if float(guide["kg_m"]) > 0.0:
			car_parts.append(_pk("rail_block", inward * (pw * 0.5 + 0.008) + Vector3(0, eff_h, 0), "Tower carriage block", Vector3(0.027, 0.045, 0.013), {}, GantryLabDetail.basis_yz(Vector3.UP, inward)))
		else:
			plate_in = pw * 0.5 + 0.012
			for wy in [-1.0, 1.0]:
				for wt in [-1.0, 1.0]:
					_wheel(car_parts, tang * (wt * (pw * 0.5 + WHEEL_R - 0.0025)) + Vector3(0, eff_h + wy * 0.025, 0), inward, i, "Carriage wheel")
		car_parts.append(_pk("plate", inward * (plate_in + 0.003) + Vector3(0, eff_h, 0), "Tower carriage", Vector3(0.05, 0.06, 0.006), {"s": Vector3(0.05, 0.006, 0.06)}, GantryLabDetail.basis_yz(inward, Vector3.UP)))
		# The arms' pivots sit at the kinematic carriage radius, at the same
		# height above the carriage as the effector's pivots above its base.
		for sd in [-1.0, 1.0]:
			car_parts.append(_pk("rod_end", inward * car_r + tang * (sd * 0.025) + Vector3(0, eff_h + 0.003, 0), "Rod end", Vector3(0.01, 0.014, 0.01), {}, GantryLabDetail.basis_y(tang * sd)))
		assemblies["Carriage%s" % side_names[i]] = {"parent": "", "base": cpos, "beams": [], "parts": car_parts,
			"mass_kg": 0.1 + float(guide["kg_carriage"]), "axis": "z", "tower": i, "inward": inward, "car_r": car_r, "plate_in": plate_in}
		# Belt: motor at the foot (shaft along the tangent), idler at the top, clamp on the plate.
		var bx := inward * (plate_in + 0.012 + zr) + tang * 0.02
		var face := Vector3(t.x, FOOT + pw + 0.05, t.z) + bx - tang * belt_off(belt_w)
		static_parts.append(_motor(face, tang, str(s["axis"]["z"]["motor"]), "Tower %s motor" % side_names[i]))
		static_parts.append(_box(Vector3(t.x, FOOT + pw + 0.003, t.z) + inward * (plate_in + 0.012 + zr) - tang * 0.02, Vector3(0.05, 0.006, 0.05), "Motor plate", "plate"))
		loops.append(_loop("Tower %s belt" % side_names[i], i, 1.0, belt_w, tang, [
			_node("", Vector3(t.x, FOOT + pw + 0.05, t.z) + bx, zr, 1.0, "pulley").merged({"face": face, "teeth": int(s["axis"]["z"]["pulley_teeth"])}),
			_node("Carriage%s" % side_names[i], bx - inward * zr + Vector3(0, eff_h, 0), 0.0, 0.0, "clamp").merged({"size": Vector3(0.006, 0.016, 0.012), "basis": GantryLabDetail.basis_yz(inward, Vector3.UP)}),
			_node("", Vector3(t.x, tower_h - pw - 0.03, t.z) + bx, IDLER_R, 1.0, "idler").merged({"post_from": Vector3(t.x, tower_h - pw - 0.03, t.z) + inward * (pw * 0.5) + tang * 0.02, "bolt_down": 0.0}),
		]))
	var eff_r := float(dl["effector_r_mm"]) * 0.001
	var eff_parts: Array = [_pk("effector", Vector3(0, eff_h, 0), "Effector", Vector3(eff_r * 2.0 + 0.03, 0.006, eff_r * 2.0 + 0.03), {"r": eff_r}), _tool_part(s, Vector3.ZERO)]
	for i in 3:
		var inward: Vector3 = (assemblies["Carriage%s" % side_names[i]] as Dictionary)["inward"]
		var tang := inward.cross(Vector3.UP).normalized()
		for sd in [-1.0, 1.0]:
			eff_parts.append(_pk("rod_end", -inward * eff_r + tang * (sd * 0.025) + Vector3(0, eff_h + 0.003, 0), "Rod end", Vector3(0.01, 0.014, 0.01), {}, GantryLabDetail.basis_y(tang * sd)))
	assemblies["Effector"] = {"parent": "", "base": Vector3(0, bed_top, 0), "beams": [], "parts": eff_parts,
		"mass_kg": float(tool["kg"]) + 0.08 + 6.0 * 0.03, "axis": "xyz", "eff_r": eff_r, "eff_h": eff_h}
	var additive := str(tool["process"]) == "additive" and tool_id != "clay_extruder" and tool_id != "pellet_extruder"
	if additive:
		var t0: Vector3 = towers[0]
		var inward0 := -Vector3(t0.x, 0, t0.z).normalized()
		var ex_c := Vector3(t0.x, tower_h - 0.06, t0.z) - inward0 * (pw * 0.5 + 0.0)
		var ex_b := GantryLabDetail.basis_yz(Vector3.UP, -inward0)
		var ex_b2 := Basis(ex_b.y.cross(ex_b.z), ex_b.y, ex_b.z)
		static_parts.append(_pk("extruder", ex_c, "Bowden extruder", Vector3(0.042, 0.06, 0.05), {"pick_c": ex_c - inward0 * 0.02}, ex_b2))
		links.append({"kind": "bowden", "a": {"asm": "", "c": ex_c + ex_b2 * GantryLabDetail.EXTRUDER_OUTLET}, "b": {"asm": "Effector", "c": Vector3(0, GantryLabDetail.HOTEND_H + 0.0135, 0)},
			"ta": Vector3.DOWN, "tb": Vector3.UP, "r": 0.002})
		var spool_c := Vector3(t0.x, tower_h + 0.12, t0.z) - inward0 * 0.02
		static_parts.append(_pk("spool", spool_c - inward0.cross(Vector3.UP) * 0.0325, "Filament spool", Vector3(0.2, 0.2, 0.065), {"r": 0.1, "w": 0.065, "fill": 0.72, "pick_c": spool_c}, GantryLabDetail.basis_y(inward0.cross(Vector3.UP))))
		static_parts.append(_box(Vector3(t0.x, tower_h + 0.055, t0.z) + inward0.cross(Vector3.UP) * 0.045, Vector3(0.03, 0.11, 0.008), "Spool holder"))
		links.append({"kind": "filament", "a": {"asm": "", "c": spool_c + Vector3(0, -0.072, 0)}, "b": {"asm": "", "c": ex_c + ex_b2 * GantryLabDetail.EXTRUDER_INLET}, "ta": Vector3.DOWN, "tb": Vector3.UP, "r": 0.0009})
	for lp in loops:
		_loop_parts(static_parts, assemblies, lp)
	var tool_tip := Vector3(0, bed_top, 0)
	var moving := float(tool["kg"]) + 0.08 + 0.18 + 0.3 + 3.0 * float(guide["kg_carriage"])
	return {
		"kinematics": "delta", "dims": Vector3(tower_r * 2.0 + 2.0 * pw + 0.1, tower_h + pw * 0.5 + (0.2 if additive else 0.0), tower_r * 2.0 + 2.0 * pw + 0.1),
		"origin": tool_tip, "static": {"beams": static_beams, "parts": static_parts},
		"assemblies": assemblies, "bed": {"size": bed_size, "kind": bed_kind, "round": true}, "screws": [], "loops": loops, "links": links, "towers": towers, "arm_m": arm,
		"moving_kg": {"x": moving, "y": moving, "z": moving},
		"spans": {"x_beam_m": 0.0, "y_rail_m": 0.0, "z_col_m": tower_h - FOOT, "arm_m": arm},
		"anchors": {"tower_h": tower_h, "bed_top": bed_top, "pw": pw, "tower_r": tower_r},
		"bead_parent": "", "bead_origin": tool_tip,
	}


# ---------------------------------------------------------------------------
# Router: C-Beam Y rails with their screws in the channel, a gantry on wheel
# plates riding them, the X carriage on the gantry beam, the Z axis on rods.
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
	var kin := "router"
	var tool_id := str(s["tool"]["id"])
	var bed_kind := str(s["tool"]["bed"])
	var w := vx + 2.0 * MARGIN_X + 2.0 * pw + 0.10
	var d := vy + 2.0 * MARGIN_Y + 0.14
	var hx := w * 0.5
	var hz := d * 0.5
	var static_beams: Array = []
	var static_parts: Array = []
	var loops: Array = []
	var mi_x := motor_index(kin, "x")
	var mi_y := motor_index(kin, "y")
	var mi_z := motor_index(kin, "z")
	for sx in [-1.0, 1.0]:
		static_beams.append(_beam(Vector3(sx * (hx - pw * 0.5), FOOT + ph * 0.5, -hz), Vector3(sx * (hx - pw * 0.5), FOOT + ph * 0.5, hz), pf, "Y rail", "base"))
		if bool(s["frame"]["feet"]):
			for sz in [-1.0, 1.0]:
				static_parts.append(_foot(Vector3(sx * (hx - pw * 0.5), FOOT, sz * (hz - 0.04))))
	var n_cross := maxi(2, int(ceil(d / 0.4)) + 1)
	for i in n_cross:
		var zz := lerpf(-hz + pw * 0.5, hz - pw * 0.5, float(i) / float(n_cross - 1))
		static_beams.append(_beam(Vector3(-hx + pw, FOOT + pw * 0.5, zz), Vector3(hx - pw, FOOT + pw * 0.5, zz), "2040" if pf != "2020" else "2020", "Cross member", "base"))
		for sx in [-1.0, 1.0]:
			static_parts.append(_corner(Vector3(sx * (hx - pw), FOOT + pw, zz), Vector3(-sx, 0, 0), Vector3.DOWN))
	var bed_top := FOOT + ph + 0.018
	var bed_size := Vector2(vx + 0.06, vy + 0.06)
	static_parts.append(_bed(Vector3(0, bed_top, 0), bed_size, bed_kind, str(GantryLabParts.bed(bed_kind)["label"])))
	# Y drive: screws in the C-Beam channels (or belts along the rails).
	var y_dr := GantryLabParts.drive(str(s["axis"]["y"]["drive"]))
	var ym := _motor_size(str(s["axis"]["y"]["motor"]))
	var screws: Array = []
	var y_count := int(s["axis"]["y"]["motors"])
	var ch_y := FOOT + ph - 0.01 if pf == "c_beam_4080" else FOOT + ph * 0.5
	for i in y_count:
		var sx := -1.0 if i == 0 else 1.0
		if y_count == 1:
			sx = 1.0
		var mx: float = sx * (hx - pw * 0.5)
		var face := Vector3(mx, ch_y, -hz - 0.004)
		static_parts.append(_motor(face, Vector3.BACK, str(s["axis"]["y"]["motor"]), "Y motor %d" % (i + 1)))
		static_parts.append(_plate_xy(Vector3(mx, ch_y, -hz - 0.002), 0.06, 0.08, 0.004, "Y motor plate"))
		if str(y_dr["kind"]) == "screw":
			_screw_set(static_parts, face + Vector3(0, 0, 0.004), Vector3.BACK, d - 0.03, y_dr, mi_y, "Y screw")
			screws.append({"a": Vector3(mx, ch_y, -hz), "b": Vector3(mx, ch_y, hz), "d_mm": float(y_dr["d_mm"]), "label": "Y screw"})
	static_parts.append(_box(Vector3(hx + 0.09, FOOT + 0.06, 0), Vector3(0.14, 0.12, 0.22), str(GantryLabParts.board(str(s["electronics"]["board"]))["label"]), "galv"))
	static_parts.append(_endstop(Vector3(hx - pw - 0.012, FOOT + ph, -hz + 0.07), Vector3.BACK, Vector3.UP, "Y endstop"))
	# Gantry: two uprights on wheel plates, the X beam across.
	var up_h := bed_top + vz + 0.12 + gh
	var up_x := hx - pw * 0.5
	var g_beams: Array = []
	var g_parts: Array = []
	for sx in [-1.0, 1.0]:
		g_beams.append(_beam(Vector3(sx * up_x, FOOT + ph + 0.02, 0), Vector3(sx * up_x, up_h, 0), gf, "Gantry upright", "gantry"))
		g_parts.append(_plate_flat(Vector3(sx * up_x, FOOT + ph + 0.017, 0), pw + 0.06, 0.16, 0.006, "Y gantry plate"))
		for wx in [-1.0, 1.0]:
			for wz in [-1.0, 1.0]:
				_wheel(g_parts, Vector3(sx * up_x + wx * (pw * 0.5 + WHEEL_R - 0.0025), FOOT + ph - 0.01, wz * 0.05), Vector3.UP, mi_y, "Y wheel", 0.004)
		if str(y_dr["kind"]) == "screw":
			g_parts.append(_box(Vector3(sx * up_x, FOOT + ph - 0.002, 0), Vector3(0.02, 0.028, 0.03), "Nut block", "plate"))
			g_parts.append(_nut(Vector3(sx * up_x, ch_y, -0.02), Vector3.BACK, "Y nut"))
	var xb_len := 2.0 * up_x + gw
	var xb_y := up_h - gh * 0.5
	g_beams.append(_beam(Vector3(-xb_len * 0.5, xb_y, 0.0), Vector3(xb_len * 0.5, xb_y, 0.0), gf, "X beam", "gantry", Vector3.FORWARD))
	var x_dr := GantryLabParts.drive(str(s["axis"]["x"]["drive"]))
	var ch_x := -gh * 0.5 + 0.01 if gf == "c_beam_4080" else -gh * 0.5 - 0.012
	var x_face := Vector3(xb_len * 0.5 + 0.004, xb_y, ch_x)
	g_parts.append(_motor(x_face, Vector3.LEFT, str(s["axis"]["x"]["motor"]), "X motor"))
	g_parts.append(_plate_yz(Vector3(xb_len * 0.5 + 0.002, xb_y, ch_x), 0.08, 0.06, 0.004, "X motor plate"))
	if str(x_dr["kind"]) == "screw":
		_screw_set(g_parts, x_face + Vector3(-0.004, 0, 0), Vector3.LEFT, xb_len - 0.03, x_dr, mi_x, "X screw")
		screws.append({"a": Vector3(-xb_len * 0.5, xb_y, ch_x), "b": Vector3(xb_len * 0.5, xb_y, ch_x), "d_mm": float(x_dr["d_mm"]), "label": "X screw", "assembly": "YGantry"})
	g_parts.append(_endstop(Vector3(-xb_len * 0.5 + 0.06, xb_y + gw * 0.5, -gh * 0.5 + 0.004), Vector3.RIGHT, Vector3.UP, "X endstop"))
	var guide_x := GantryLabParts.guide(str(s["axis"]["x"]["guide"]))
	var guide_y := GantryLabParts.guide(str(s["axis"]["y"]["guide"]))
	var guide_z := GantryLabParts.guide(str(s["axis"]["z"]["guide"]))
	# X carriage: a plate on wheels riding the beam's front, the Z axis on it.
	var z_dr := GantryLabParts.drive(str(s["axis"]["z"]["drive"]))
	var zm := _motor_size(str(s["axis"]["z"]["motor"]))
	var zplate_h := vz + 0.16
	var car_z := -gh * 0.5 - 0.0125
	var car_parts: Array = [_plate_xy(Vector3(0, xb_y, car_z), 0.12, gw + 0.04, 0.003, "X carriage plate")]
	for wx in [-1.0, 1.0]:
		for wy in [-1.0, 1.0]:
			_wheel(car_parts, Vector3(wx * 0.04, xb_y + wy * (gw * 0.5 + WHEEL_R - 0.0025), -gh * 0.5 + 0.01), Vector3.FORWARD, mi_x, "X wheel")
	if str(x_dr["kind"]) == "screw":
		car_parts.append(_nut(Vector3(0.0, xb_y, ch_x), Vector3.RIGHT, "X nut"))
	var zm_face := Vector3(0, xb_y + gw * 0.5 + 0.024, car_z - 0.0015 - 0.012)
	car_parts.append(_motor(zm_face, Vector3.DOWN, str(s["axis"]["z"]["motor"]), "Z motor"))
	car_parts.append(_box(Vector3(0, xb_y + gw * 0.5 + 0.026, car_z - 0.0015 - 0.012), Vector3(0.09, 0.004, 0.03), "Z motor plate", "plate"))
	var zp_top := xb_y + gw * 0.5 + 0.02
	var zp_c := Vector3(0, zp_top - zplate_h * 0.5, car_z - 0.0015 - 0.005)
	car_parts.append(_plate_xy(zp_c, 0.09, zplate_h, 0.01, "Z axis plate"))
	for rx in [-1.0, 1.0]:
		car_parts.append(_pk("rod", Vector3(rx * 0.03, zp_top - zplate_h + 0.01, car_z - 0.0015 - 0.012 - 0.008), "Z rod", Vector3(0.008, zplate_h - 0.02, 0.008), {"len": zplate_h - 0.02, "d": 0.008}))
	if str(z_dr["kind"]) == "screw":
		_screw_set(car_parts, zm_face - Vector3(0, 0.004, 0), Vector3.DOWN, zplate_h - 0.02, z_dr, mi_z, "Z screw")
		screws.append({"a": Vector3(0, xb_y + gw * 0.5 + 0.02, car_z - 0.0015 - 0.012), "b": Vector3(0, xb_y - zplate_h + gw * 0.5, car_z - 0.0015 - 0.012), "d_mm": float(z_dr["d_mm"]), "label": "Z screw", "assembly": "XCarriage"})
	var tool := GantryLabParts.tool(tool_id)
	var mount_h := tool_mount_h(tool_id)
	var zc_z := car_z - 0.0015 - 0.012 - 0.008 - 0.0075 - 0.005
	var zc_parts: Array = [_plate_xy(Vector3(0, mount_h, zc_z), 0.08, 0.12, 0.008, "Z carriage plate")]
	for rx in [-1.0, 1.0]:
		for ry in [-1.0, 1.0]:
			zc_parts.append(_pk("lm8uu", Vector3(rx * 0.03, mount_h + ry * 0.035 - 0.012, car_z - 0.0015 - 0.012 - 0.008), "LM8UU bearing", Vector3(0.015, 0.024, 0.015), {}))
	if str(z_dr["kind"]) == "screw":
		zc_parts.append(_nut(Vector3(0, mount_h + 0.05, car_z - 0.0015 - 0.012), Vector3.DOWN, "Z nut"))
	zc_parts.append(_tool_part(s, Vector3(0, 0, zc_z - 0.004 - 0.035)))
	var tool_tip := Vector3(-vx * 0.5, bed_top, -vy * 0.5)
	var zc_kg := float(tool["kg"]) + float(guide_z["kg_carriage"]) + 0.2
	var car_kg := zc_kg + _mass_of([], car_parts) + float(GantryLabParts.motor(str(s["axis"]["z"]["motor"]))["kg"]) + float(guide_x["kg_carriage"]) + 0.3
	var g_kg := _mass_of(g_beams, g_parts) + car_kg + float(GantryLabParts.motor(str(s["axis"]["x"]["motor"]))["kg"]) + 2.0 * float(guide_y["kg_carriage"]) + float(guide_x["kg_m"]) * xb_len
	var assemblies := {
		"YGantry": {"parent": "", "base": Vector3(0, 0, tool_tip.z), "beams": g_beams, "parts": g_parts, "mass_kg": g_kg, "axis": "y"},
		"XCarriage": {"parent": "YGantry", "base": Vector3(tool_tip.x, 0, 0), "beams": [], "parts": car_parts, "mass_kg": car_kg, "axis": "x"},
		"ZCarriage": {"parent": "XCarriage", "base": Vector3(0, tool_tip.y, 0), "beams": [], "parts": zc_parts, "mass_kg": zc_kg, "axis": "z"},
	}
	# Belt-driven X / Y keep a simple loop each.
	if str(x_dr["kind"]) == "belt":
		var bw := _belt_w(s, "x")
		var xr := GantryLabDetail.gt2_pitch_radius(int(s["axis"]["x"]["pulley_teeth"]))
		var zb := -gh * 0.5 - 0.02
		var xf := Vector3(xb_len * 0.5 - 0.03, xb_y, zb - belt_off(bw))
		g_parts[g_parts.size() - 3] = _motor(xf, Vector3.BACK, str(s["axis"]["x"]["motor"]), "X motor")
		loops.append(_loop("X belt", mi_x, 1.0, bw, Vector3.BACK, [
			_node("YGantry", Vector3(xb_len * 0.5 - 0.03, xb_y, zb), xr, 1.0, "pulley").merged({"face": xf, "teeth": int(s["axis"]["x"]["pulley_teeth"])}),
			_node("XCarriage", Vector3(0, xb_y + xr, zb), 0.0, 0.0, "clamp").merged({"size": Vector3(0.016, 0.006, 0.009)}),
			_node("YGantry", Vector3(-xb_len * 0.5 + 0.03, xb_y, zb), IDLER_R, 1.0, "idler").merged({"post_from": Vector3(-xb_len * 0.5 + 0.03, xb_y, -gh * 0.5), "bolt_down": 0.0}),
		]))
	if str(y_dr["kind"]) == "belt":
		var bw := _belt_w(s, "y")
		var yr := GantryLabDetail.gt2_pitch_radius(int(s["axis"]["y"]["pulley_teeth"]))
		for i in y_count:
			var sx := -1.0 if i == 0 else 1.0
			if y_count == 1:
				sx = 1.0
			var bx: float = sx * (hx - pw * 0.5 + pw * 0.5 + 0.012)
			var by := FOOT + ph - 0.03
			loops.append(_loop("Y belt %d" % (i + 1), mi_y, 1.0, bw, Vector3(sx, 0, 0), [
				_node("", Vector3(bx, by, -hz + 0.03), yr, 1.0, "pulley").merged({"face": Vector3(bx, by, -hz + 0.03) - Vector3(sx, 0, 0) * belt_off(bw), "teeth": int(s["axis"]["y"]["pulley_teeth"]), "axis": Vector3(sx, 0, 0)}),
				_node("YGantry", Vector3(bx, by + yr, 0), 0.0, 0.0, "clamp").merged({"size": Vector3(0.006, 0.006, 0.016)}),
				_node("", Vector3(bx, by, hz - 0.03), IDLER_R, 1.0, "idler").merged({"post_from": Vector3(bx - sx * 0.012, by, hz - 0.03), "axis": Vector3(sx, 0, 0), "bolt_down": 0.0}),
			]))
	for lp in loops:
		_loop_parts(static_parts, assemblies, lp)
	return {
		"kinematics": "router", "dims": Vector3(w + 0.16, up_h + gh * 0.5, d + 0.16),
		"origin": tool_tip, "static": {"beams": static_beams, "parts": static_parts},
		"assemblies": assemblies, "bed": {"size": bed_size, "kind": bed_kind}, "screws": screws, "loops": loops, "links": [],
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


## The motors' displacements (mm) in motor_positions order.
static func motor_mm(spec: Dictionary, tool_mm: Vector3) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for m in GantryLabKinematics.motor_positions(spec, tool_mm):
		var v := float((m as Dictionary)["mm"])
		out.append(v if is_finite(v) else 0.0)
	return out


# ---------------------------------------------------------------------------
# Belts: each loop's pulleys resolved to machine space, joined by the common
# tangents of consecutive circles and the arcs round each pulley.
# ---------------------------------------------------------------------------

## Belt routes for drawing: [{name, points (closed polyline, machine space),
## n (pulley axis), w, inside, motor, sign, key}].
static func belt_routes(spec: Dictionary, lay: Dictionary, po: Dictionary) -> Array:
	var out: Array = []
	for lp in lay.get("loops", []):
		var loop: Dictionary = lp
		var n: Vector3 = loop["n"]
		var nodes: Array = loop["nodes"]
		if nodes.size() < 2:
			continue
		var centres: Array = []
		for nd in nodes:
			var node: Dictionary = nd
			centres.append(assembly_origin(lay, po, str(node["asm"])) + (node["c"] as Vector3))
		var pts := solve_loop(centres, nodes, n)
		if pts.size() < 2:
			continue
		var inside := 1.0
		for nd in nodes:
			if str((nd as Dictionary)["kind"]) == "pulley":
				inside = 1.0 if float((nd as Dictionary)["s"]) >= 0.0 else -1.0
				break
		out.append({"name": str(loop["name"]), "points": pts, "key": "belt", "n": n, "w": float(loop["belt_w"]), "inside": inside,
			"motor": int(loop["motor"]), "sign": float(loop["sign"])})
	return out


## The closed belt path round circles (centre, r, s) in the plane with
## normal `n`: common tangents between consecutive circles (a clamp is a
## circle of radius 0), arcs of each circle from its entry to its exit point
## in its wrap direction (s = +1 counter-clockwise seen from +n).
static func solve_loop(centres: Array, nodes: Array, n: Vector3) -> PackedVector3Array:
	var nn := n.normalized()
	var u := GantryLabDetail.basis_y(nn).x
	var v := nn.cross(u).normalized()
	var o: Vector3 = centres[0]
	var m := centres.size()
	var q: Array = []
	for i in m:
		var d: Vector3 = (centres[i] as Vector3) - o
		q.append(Vector2(d.dot(u), d.dot(v)))
	# Tangent points: for edge i → j, where the belt leaves i and arrives at j.
	var leave: Array = []
	var arrive: Array = []
	for i in m:
		var j := (i + 1) % m
		var ri := float((nodes[i] as Dictionary)["r"])
		var rj := float((nodes[j] as Dictionary)["r"])
		var si := float((nodes[i] as Dictionary)["s"])
		var sj := float((nodes[j] as Dictionary)["s"])
		var ci: Vector2 = q[i]
		var cj: Vector2 = q[j]
		var D := cj - ci
		var L := D.length()
		if L < 1e-9:
			leave.append(ci)
			arrive.append(cj)
			continue
		var dh := D / L
		var delta := sj * rj - si * ri
		var cosang := clampf(delta / L, -1.0, 1.0)
		var sinang := sqrt(maxf(0.0, 1.0 - cosang * cosang))
		var perp := Vector2(-dh.y, dh.x)
		var best_n := Vector2.ZERO
		var best_dot := -INF
		for sg_i in 2:
			var sg := 1.0 if sg_i == 0 else -1.0
			var nl := dh * cosang + perp * (sinang * sg)
			var dir := Vector2(nl.y, -nl.x)
			var dd := dir.dot(D)
			if dd > best_dot:
				best_dot = dd
				best_n = nl
		leave.append(ci - best_n * (si * ri))
		arrive.append(cj - best_n * (sj * rj))
	var pts := PackedVector3Array()
	for i in m:
		var ri := float((nodes[i] as Dictionary)["r"])
		var si := float((nodes[i] as Dictionary)["s"])
		var ci: Vector2 = q[i]
		var p_in: Vector2 = arrive[(i - 1 + m) % m]
		var p_out: Vector2 = leave[i]
		if ri <= 1e-6:
			pts.append(o + u * ci.x + v * ci.y)
			continue
		var a0 := atan2(p_in.y - ci.y, p_in.x - ci.x)
		var a1 := atan2(p_out.y - ci.y, p_out.x - ci.x)
		if si >= 0.0:
			while a1 < a0 + 1e-6:
				a1 += TAU
		else:
			while a1 > a0 - 1e-6:
				a1 -= TAU
		var steps := maxi(2, int(ceil(absf(a1 - a0) / deg_to_rad(12.0))))
		for k in steps + 1:
			var a := lerpf(a0, a1, float(k) / float(steps))
			var p2 := ci + Vector2(cos(a), sin(a)) * ri
			pts.append(o + u * p2.x + v * p2.y)
	if pts.size() > 1:
		pts.append(pts[0])
	return pts


## The Bowden tube / filament links as bezier polylines in machine space.
static func link_routes(lay: Dictionary, po: Dictionary) -> Array:
	var out: Array = []
	for lk in lay.get("links", []):
		var link: Dictionary = lk
		var a := assembly_origin(lay, po, str(link["a"]["asm"])) + (link["a"]["c"] as Vector3)
		var b := assembly_origin(lay, po, str(link["b"]["asm"])) + (link["b"]["c"] as Vector3)
		var ta: Vector3 = link.get("ta", Vector3.DOWN)
		var tb: Vector3 = link.get("tb", Vector3.UP)
		var dist := a.distance_to(b)
		var k := maxf(0.06, dist * 0.45)
		var p1 := a + ta.normalized() * (k * 0.5 if str(link["kind"]) == "bowden" else 0.02)
		var p2 := b + tb.normalized() * k
		var pts := PackedVector3Array()
		var steps := 14
		for i in steps + 1:
			var t := float(i) / float(steps)
			var mt := 1.0 - t
			pts.append(a * (mt * mt * mt) + p1 * (3.0 * mt * mt * t) + p2 * (3.0 * mt * t * t) + b * (t * t * t))
		out.append({"kind": str(link["kind"]), "points": pts, "r": float(link.get("r", 0.002))})
	return out


## Delta arms for drawing: six segments carriage ↔ effector (machine space).
static func delta_arms(lay: Dictionary, po: Dictionary) -> Array:
	if str(lay["kinematics"]) != "delta":
		return []
	var out: Array = []
	var eff := assembly_origin(lay, po, "Effector")
	var eff_asm: Dictionary = lay["assemblies"]["Effector"]
	var eff_r := float(eff_asm["eff_r"])
	var eff_h := float(eff_asm.get("eff_h", 0.03))
	for i in 3:
		var name := "Carriage%s" % ["A", "B", "C"][i]
		var asm: Dictionary = lay["assemblies"][name]
		var car := assembly_origin(lay, po, name)
		var inward: Vector3 = asm["inward"]
		var side := inward.cross(Vector3.UP).normalized() * 0.025
		var car_r := float(asm["car_r"])
		var e_pt := eff + Vector3(0, eff_h + 0.003, 0) - inward * eff_r
		var c_pt := car + Vector3(0, eff_h + 0.003, 0) + inward * car_r
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


## How many of a kind the layout draws (the BOM cross-check).
static func count_kind(lay: Dictionary, kind: String) -> int:
	var n := 0
	for p in all_parts(lay):
		if str((p as Dictionary)["kind"]) == kind:
			n += 1
	return n
