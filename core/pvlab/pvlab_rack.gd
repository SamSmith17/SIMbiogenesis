class_name PvLabRack
extends RefCounted

## Racks for the Solar designer: the materials, the mounts, the members a
## laid-out array needs, and a rail span check. Pure.
##
## Members are in the array's local frame (metres, y up from the mounting
## surface; see PvLabArray). Each is {kind, profile, a, b, up, head, label}:
## a straight piece from a to b whose cross-section's "height" axis points
## along `up`; `head` ≥ 0 puts it on a tracker head (rotating with it, in
## that head's frame), −1 on the fixed frame.
##
## Section properties and allowable stresses:
##   lumber   — NDS Supplement 2018, Table 4A, Spruce-Pine-Fir No. 2:
##              Fb 875 psi × size factor 1.5 (2x4) / 1.3 (2x6), E 1.4e6 psi;
##              dressed 1.5 × 3.5 in and 1.5 × 5.5 in, on edge.
##   Unistrut — General Engineering Catalog No. 17: P1000 12 ga 1-5/8"
##              Ix 0.185 in⁴, Sx 0.202 in³; P1001 back-to-back Ix 0.928 in⁴,
##              Sx 0.571 in³; allowable 25 ksi, E 29.5e6 psi.
##   aluminium PV rail — GENERIC 6005-T5 extrusions in the range the common
##              rails publish (light ≈ 1.6" deep, heavy ≈ 2.4" deep); allowable
##              ≈ 130 MPa (Fy 240 MPa / 1.65, Aluminum Design Manual), E 69
##              GPa. An estimate: use the maker's own span table to build.
## The span check is a simply supported rail under a uniform load: bending
## L = √(8·S·Fb / w), deflection L/180: L = (384·E·I / (5·w·180))^(1/3).
## Prices and stock lengths are US big-box estimates (2026), for the BOM.

const MOUNTS := ["ground", "roof_flush", "roof_tilt", "ballast", "pole", "tracker", "none"]
const MOUNT_LABELS := {"ground": "Ground rack (fixed tilt)", "roof_flush": "Roof, flush (rails on stand-offs)",
	"roof_tilt": "Roof, tilt-up legs", "ballast": "Flat roof, ballasted", "pole": "Pole mount",
	"tracker": "Single-axis tracker", "none": "No rack (laid on the surface)"}
const MATERIALS := ["lumber_2x4", "lumber_2x6", "unistrut_p1000", "unistrut_p1001", "alu_rail_light", "alu_rail_heavy"]
const MATERIAL_LABELS := {"lumber_2x4": "2x4 lumber", "lumber_2x6": "2x6 lumber",
	"unistrut_p1000": "Unistrut P1000 channel", "unistrut_p1001": "Unistrut P1001 (back-to-back)",
	"alu_rail_light": "Aluminium PV rail, light", "alu_rail_heavy": "Aluminium PV rail, heavy"}

## shape: rect | channel | rail | tube_sq | tube_round. w/h in mm (h is along
## `up`). I (cm⁴), S (cm³), F (allowable MPa), E (GPa), kg_m, stock_m, cost.
const PROFILES := {
	"2x4": {"label": "2x4 SPF #2", "shape": "rect", "w": 38.0, "h": 89.0, "I": 222.0, "S": 50.0,
		"F": 9.05, "E": 9.65, "kg_m": 1.59, "stock_m": 3.66, "cost": 9.0, "look": "lumber"},
	"2x6": {"label": "2x6 SPF #2", "shape": "rect", "w": 38.0, "h": 140.0, "I": 869.0, "S": 124.0,
		"F": 7.84, "E": 9.65, "kg_m": 2.50, "stock_m": 3.66, "cost": 14.0, "look": "lumber"},
	"4x4": {"label": "4x4 post", "shape": "rect", "w": 89.0, "h": 89.0, "I": 523.0, "S": 117.0,
		"F": 9.0, "E": 9.65, "kg_m": 3.72, "stock_m": 2.44, "cost": 14.0, "look": "lumber"},
	"p1000": {"label": "Unistrut P1000", "shape": "channel", "w": 41.3, "h": 41.3, "I": 7.70, "S": 3.31,
		"F": 172.0, "E": 203.0, "kg_m": 2.81, "stock_m": 3.05, "cost": 45.0, "look": "galv"},
	"p1001": {"label": "Unistrut P1001", "shape": "rect", "w": 41.3, "h": 82.6, "I": 38.6, "S": 9.36,
		"F": 172.0, "E": 203.0, "kg_m": 5.63, "stock_m": 3.05, "cost": 110.0, "look": "galv"},
	"rail_light": {"label": "Al rail, light", "shape": "rail", "w": 30.0, "h": 41.0, "I": 6.2, "S": 3.1,
		"F": 130.0, "E": 69.0, "kg_m": 0.75, "stock_m": 4.27, "cost": 85.0, "look": "alu"},
	"rail_heavy": {"label": "Al rail, heavy", "shape": "rail", "w": 34.0, "h": 61.0, "I": 18.0, "S": 6.7,
		"F": 130.0, "E": 69.0, "kg_m": 1.25, "stock_m": 5.18, "cost": 140.0, "look": "alu"},
	"alu_post": {"label": "Al post 60×60", "shape": "tube_sq", "w": 60.0, "h": 60.0, "I": 40.0, "S": 13.0,
		"F": 130.0, "E": 69.0, "kg_m": 1.85, "stock_m": 2.4, "cost": 30.0, "look": "alu"},
	"torque_tube": {"label": "Torque tube 100×100", "shape": "tube_sq", "w": 100.0, "h": 100.0, "I": 230.0,
		"S": 46.0, "F": 172.0, "E": 203.0, "kg_m": 12.1, "stock_m": 6.0, "cost": 260.0, "look": "galv"},
	"pipe_4in": {"label": "4\" sch 40 pipe", "shape": "tube_round", "w": 114.3, "h": 114.3, "I": 301.0,
		"S": 52.7, "F": 172.0, "E": 203.0, "kg_m": 16.1, "stock_m": 6.1, "cost": 180.0, "look": "galv"},
	"lfoot": {"label": "L-foot stand-off", "shape": "rect", "w": 40.0, "h": 40.0, "I": 0.0, "S": 0.0,
		"F": 0.0, "E": 0.0, "kg_m": 0.0, "stock_m": 0.0, "cost": 12.0, "look": "alu"},
	"ballast": {"label": "Ballast block 16 kg", "shape": "rect", "w": 200.0, "h": 100.0, "I": 0.0, "S": 0.0,
		"F": 0.0, "E": 0.0, "kg_m": 0.0, "stock_m": 0.0, "cost": 4.0, "look": "concrete"},
	"foot": {"label": "Ground screw", "shape": "tube_round", "w": 76.0, "h": 76.0, "I": 0.0, "S": 0.0,
		"F": 0.0, "E": 0.0, "kg_m": 0.0, "stock_m": 0.0, "cost": 40.0, "look": "galv"},
}

## Which profile each material uses for rails, the members up the slope and
## the legs.
const KIT := {
	"lumber_2x4": {"rail": "2x4", "purlin": "2x4", "leg": "4x4", "brace": "2x4"},
	"lumber_2x6": {"rail": "2x6", "purlin": "2x6", "leg": "4x4", "brace": "2x4"},
	"unistrut_p1000": {"rail": "p1000", "purlin": "p1000", "leg": "p1000", "brace": "p1000"},
	"unistrut_p1001": {"rail": "p1001", "purlin": "p1001", "leg": "p1001", "brace": "p1000"},
	"alu_rail_light": {"rail": "rail_light", "purlin": "rail_light", "leg": "alu_post", "brace": "rail_light"},
	"alu_rail_heavy": {"rail": "rail_heavy", "purlin": "rail_heavy", "leg": "alu_post", "brace": "rail_light"},
}

const HARDWARE := {
	"mid_clamp": {"label": "Mid clamp", "cost": 3.0, "kg": 0.08},
	"end_clamp": {"label": "End clamp", "cost": 3.0, "kg": 0.08},
	"bolt_kit": {"label": "Bolt, nut & washer set", "cost": 1.2, "kg": 0.06},
	"splice": {"label": "Rail splice", "cost": 9.0, "kg": 0.2},
	"tube_clamp": {"label": "Module-to-tube clamp", "cost": 6.0, "kg": 0.3},
	"bearing": {"label": "Tracker bearing", "cost": 45.0, "kg": 2.5},
	"actuator": {"label": "Slew drive + controller", "cost": 650.0, "kg": 28.0},
	"mc4_ext": {"label": "PV extension cable (m)", "cost": 1.5, "kg": 0.06},
}

const DEFAULTS := {"material": "alu_rail_light", "leg_spacing_m": 1.8, "rail_overhang_mm": 120.0,
	"design_load_kpa": 1.4, "brace": true, "pole_h_m": 2.4, "hub_h_m": 1.6, "standoff_mm": 110.0,
	"footing": "auto", "clamp_finish": "auto"}


static func resolve(r: Dictionary) -> Dictionary:
	var out := DEFAULTS.duplicate()
	for k in r:
		out[k] = r[k]
	if not MATERIALS.has(str(out["material"])):
		out["material"] = "alu_rail_light"
	out["leg_spacing_m"] = clampf(float(out["leg_spacing_m"]), 0.4, 6.0)
	out["rail_overhang_mm"] = clampf(float(out["rail_overhang_mm"]), 0.0, 600.0)
	out["design_load_kpa"] = clampf(float(out["design_load_kpa"]), 0.2, 6.0)
	out["brace"] = bool(out["brace"])
	out["pole_h_m"] = clampf(float(out["pole_h_m"]), 0.8, 8.0)
	out["hub_h_m"] = clampf(float(out["hub_h_m"]), 0.6, 4.0)
	out["standoff_mm"] = clampf(float(out["standoff_mm"]), 20.0, 400.0)
	if not PvLabHardware.FOOTINGS.has(str(out["footing"])):
		out["footing"] = "auto"
	if not PvLabHardware.CLAMP_FINISHES.has(str(out["clamp_finish"])):
		out["clamp_finish"] = "auto"
	return out


static func profile(id: String) -> Dictionary:
	return PROFILES.get(id, PROFILES["2x4"])


static func kit(material: String) -> Dictionary:
	return KIT.get(material, KIT["alu_rail_light"])


## The longest rail span (m) between supports for a uniform load w (N/m):
## {bending, deflection, allowed}.
static func allowed_span_m(profile_id: String, w_npm: float) -> Dictionary:
	var p := profile(profile_id)
	if float(p["S"]) <= 0.0 or w_npm <= 0.0:
		return {"bending": INF, "deflection": INF, "allowed": INF}
	var s_m3 := float(p["S"]) * 1.0e-6
	var i_m4 := float(p["I"]) * 1.0e-8
	var f_pa := float(p["F"]) * 1.0e6
	var e_pa := float(p["E"]) * 1.0e9
	var lb := sqrt(8.0 * s_m3 * f_pa / w_npm)
	var ld := pow(384.0 * e_pa * i_m4 / (5.0 * w_npm * 180.0), 1.0 / 3.0)
	return {"bending": lb, "deflection": ld, "allowed": minf(lb, ld)}


## Rail load (N/m): the design load plus the modules' weight over the strip
## each rail carries (two rails a module row: half the module's depth each).
static func rail_load_npm(design_load_kpa: float, module_kg_m2: float, tributary_m: float) -> float:
	return (design_load_kpa * 1000.0 + module_kg_m2 * 9.81) * tributary_m


## The members for a laid-out array (PvLabArray.layout).
static func members(lay: Dictionary, rack: Dictionary) -> Array:
	var r := resolve(rack)
	var out: Array = []
	var mount := str(lay["mount"])
	var k := kit(str(r["material"]))
	match mount:
		"none":
			return out
		"tracker":
			_tracker_members(lay, r, out)
		"pole":
			_table_members(lay, r, k, out, "pole")
		_:
			_table_members(lay, r, k, out, mount)
	return out


static func _m(kind: String, prof: String, a: Vector3, b: Vector3, up: Vector3, label: String,
		head: int = -1) -> Dictionary:
	return {"kind": kind, "profile": prof, "a": a, "b": b, "up": up.normalized(), "label": label, "head": head,
		"len_m": a.distance_to(b)}


## Fixed tables: rails across each table under the modules, members up the
## slope at each support line, and legs / stand-offs / ballast / pole below.
static func _table_members(lay: Dictionary, r: Dictionary, k: Dictionary, out: Array, mount: String) -> void:
	var rail := profile(str(k["rail"]))
	var rail_h := float(rail["h"]) * 0.001
	var over := float(r["rail_overhang_mm"]) * 0.001
	for ti in (lay["tables"] as Array).size():
		var tb: Dictionary = lay["tables"][ti]
		var tilt := deg_to_rad(float(tb["tilt_deg"]))
		var slope_dir := Vector3(0.0, sin(tilt), -cos(tilt))  # up the slope
		var normal := Vector3(0.0, cos(tilt), sin(tilt))
		var low: Vector3 = tb["low"]  # centre of the low edge on the rack plane
		var half_w := float(tb["width_m"]) * 0.5
		# Rails: two under each module row of the table, at its quarter points.
		for rs in tb["rail_s"]:
			var p0: Vector3 = low + slope_dir * float(rs) + normal * (rail_h * 0.5)
			out.append(_m("rail", str(k["rail"]), p0 + Vector3(-half_w - over, 0, 0),
				p0 + Vector3(half_w + over, 0, 0), normal, "Rail"))
		# Support lines across the table.
		var xs := support_xs(float(tb["width_m"]), float(r["leg_spacing_m"]))
		var length := float(tb["length_m"])
		var purl_h := float(profile(str(k["purlin"]))["h"]) * 0.001
		for x in xs:
			var base := low + Vector3(float(x), 0, 0)
			if mount == "roof_flush":
				# The rails stand on L-feet (PvLabHardware parts).
				continue
			# A member up the slope carries the rails.
			out.append(_m("purlin", str(k["purlin"]), base - normal * (purl_h * 0.5),
				base + slope_dir * length - normal * (purl_h * 0.5), normal, "Purlin"))
			var front: Vector3 = base - normal * purl_h
			var back: Vector3 = base + slope_dir * length - normal * purl_h
			var floor_y := float(tb["floor_y"])
			if mount == "pole":
				continue
			if mount == "ballast":
				out.append(_m("leg", str(k["leg"]), Vector3(front.x, floor_y, front.z), front, Vector3(0, 0, 1),
					"Front leg"))
				out.append(_m("leg", str(k["leg"]), Vector3(back.x, floor_y, back.z), back, Vector3(0, 0, 1),
					"Rear leg"))
				out.append(_m("base", str(k["purlin"]), Vector3(front.x, floor_y, front.z + 0.15),
					Vector3(back.x, floor_y, back.z - 0.15), Vector3.UP, "Ballast tray"))
				out.append(_m("ballast", "ballast", Vector3(front.x - 0.1, floor_y, front.z + 0.05),
					Vector3(front.x + 0.1, floor_y, front.z + 0.05), Vector3.UP, "Ballast block"))
				out.append(_m("ballast", "ballast", Vector3(back.x - 0.1, floor_y, back.z - 0.05),
					Vector3(back.x + 0.1, floor_y, back.z - 0.05), Vector3.UP, "Ballast block"))
				continue
			# Ground / roof tilt-up: front and rear legs, a diagonal brace.
			out.append(_m("leg", str(k["leg"]), Vector3(front.x, floor_y, front.z), front, Vector3(0, 0, 1),
				"Front leg"))
			out.append(_m("leg", str(k["leg"]), Vector3(back.x, floor_y, back.z), back, Vector3(0, 0, 1),
				"Rear leg"))
			if bool(r["brace"]) and back.y - floor_y > 0.6:
				out.append(_m("brace", str(k["brace"]), Vector3(front.x, floor_y + 0.08, front.z),
					back.lerp(Vector3(back.x, floor_y, back.z), 0.25), Vector3(1, 0, 0), "Brace"))
		if mount == "pole":
			# One pole under the table's middle and a cross arm.
			var mid: Vector3 = low + slope_dir * (length * 0.5) - normal * purl_h
			out.append(_m("pole", "pipe_4in", Vector3(mid.x, float(tb["floor_y"]), mid.z), mid, Vector3(0, 0, 1),
				"Pole"))
			out.append(_m("brace", str(k["purlin"]), mid + Vector3(-half_w * 0.7, 0, 0),
				mid + Vector3(half_w * 0.7, 0, 0), normal, "Cross arm"))


## Support lines across a table `w` wide at no more than `spacing` apart,
## inset from the ends by a fifth of the spacing.
static func support_xs(w: float, spacing: float) -> Array:
	var inset := minf(spacing * 0.2, w * 0.25)
	var span := maxf(w - 2.0 * inset, 0.0)
	var n := maxi(int(ceil(span / spacing)), 1) + 1
	var out: Array = []
	for i in n:
		out.append(-w * 0.5 + inset + span * float(i) / float(n - 1))
	return out


## Trackers: posts along each axis, a torque tube on bearings (on the head,
## so it turns), the modules clamped across it.
static func _tracker_members(lay: Dictionary, r: Dictionary, out: Array) -> void:
	for hi in (lay["heads"] as Array).size():
		var hd: Dictionary = lay["heads"][hi]
		var length := float(hd["length_m"])
		var hub: Vector3 = hd["pos"]
		# The tube runs along the head's Z (the axis), in the head's frame.
		out.append(_m("tube", "torque_tube", Vector3(0, 0, -length * 0.5 - 0.15),
			Vector3(0, 0, length * 0.5 + 0.15), Vector3.UP, "Torque tube", hi))
		var zs := support_xs(length, float(r["leg_spacing_m"]) * 2.5)
		for z in zs:
			var top := hub + Vector3(0, -0.07, float(z))
			out.append(_m("leg", "alu_post" if str(r["material"]).begins_with("alu") else "p1001",
				Vector3(top.x, float(hd["floor_y"]), top.z), top + Vector3(0, -0.1, 0), Vector3(1, 0, 0), "Post"))
		# Module rails across the tube, under each module (the head's frame;
		# the modules sit TRACKER_DECK_M above the tube's axis).
		var mrail := str(kit(str(r["material"]))["rail"])
		var mrh := float(profile(mrail)["h"]) * 0.001
		for p in lay["panels"]:
			if int(p["head"]) != hi:
				continue
			var xf: Transform3D = p["xf"]
			var half_x := float(lay["module_depth_m"]) * 0.5
			for sgn in [-1.0, 1.0]:
				var zc: float = xf.origin.z + float(sgn) * float(lay["across_m"]) * 0.3
				var y := PvLabArray.TRACKER_DECK_M - mrh * 0.5
				out.append(_m("mrail", mrail, Vector3(xf.origin.x - half_x, y, zc), Vector3(xf.origin.x + half_x, y, zc),
					Vector3.UP, "Module rail", hi))


## Rail span check for the array: {rail_profile, load_npm, span_m, allowed_m,
## ok, text}. The rail carries half a module's depth either side.
static func span_check(lay: Dictionary, rack: Dictionary, module_kg_m2: float) -> Dictionary:
	var r := resolve(rack)
	var mount := str(lay["mount"])
	if mount == "none" or mount == "tracker":
		return {"ok": true, "text": "No rail spans to check on this mount."}
	var rail_id := str(kit(str(r["material"]))["rail"])
	var trib := float(lay.get("module_depth_m", 1.7)) * 0.5
	var w := rail_load_npm(float(r["design_load_kpa"]), module_kg_m2, trib)
	var sp := allowed_span_m(rail_id, w)
	var span := float(r["leg_spacing_m"])
	if not (lay["tables"] as Array).is_empty():
		var xs := support_xs(float((lay["tables"] as Array)[0]["width_m"]), span)
		span = 0.0
		for i in range(1, xs.size()):
			span = maxf(span, float(xs[i]) - float(xs[i - 1]))
	var ok := span <= float(sp["allowed"]) + 1e-6
	var txt := "%s spans %.2f m between supports; it carries %.0f N/m (%.1f kPa + modules) and is good to %.2f m (%s governs)." % [
		str(profile(rail_id)["label"]), span, w, float(r["design_load_kpa"]), float(sp["allowed"]),
		"bending" if float(sp["bending"]) < float(sp["deflection"]) else "deflection L/180"]
	return {"rail_profile": rail_id, "load_npm": w, "span_m": span, "allowed_m": float(sp["allowed"]),
		"bending_m": float(sp["bending"]), "deflection_m": float(sp["deflection"]), "ok": ok, "text": txt}
