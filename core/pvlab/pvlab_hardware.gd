class_name PvLabHardware
extends RefCounted

## Every small part a Solar designer rack is put together with: module
## clamps, rail splices and end caps, grounding lugs, the brackets where a
## rail crosses a purlin, the joints at the leg tops, footings (ground
## screws, concrete piers, base plates), L-feet with flashing, ballast
## brackets, brace bolts, a tracker's bearings, slew drive, tube clamps and
## module bolts, a pole's cap and U-bolts. Pure.
##
## parts(design) lays them out from the solved layout and members, the way
## the gantry designer places its hardware: each part is
##   {type, xf, head, size, params, where}
## xf in the array frame (or its tracker head's frame when head ≥ 0), its
## local y the surface the part sits on (a rail's top, a purlin's top, the
## ground), its local x along the rail or member it holds. `size` is the
## part's box (m) for picking. PvLabBuilder draws each type; the bill of
## materials counts what is drawn, and each part's fasteners.
##
## Which bracket a material uses (KITS) follows how each is really built:
##   aluminium rail — rail-to-purlin L-brackets with T-bolts, post brackets,
##                    base plates (the IronRidge / Unirac class);
##   Unistrut       — P1026-style 90° fittings with spring nuts, P1325-style
##                    gussets, P2072A-style post bases, yellow end caps;
##   lumber         — Simpson H2.5A-style hurricane ties at each crossing,
##                    BC4-style post caps, ABU44-style post bases, lag screws.
## Prices and masses are US retail estimates (2026) for the BOM.

const PARTS := {
	"mid_clamp": {"label": "Mid clamp", "look": "alu", "kg": 0.08, "cost": 3.0, "group": "Module clamps",
		"spec": "Holds two modules' frames on the rail, spanning the gap between them.",
		"fasteners": {"tbolt_m8": 1}},
	"end_clamp": {"label": "End clamp", "look": "alu", "kg": 0.08, "cost": 3.0, "group": "Module clamps",
		"spec": "Holds the last module's outer frame edge at the end of a rail.", "fasteners": {"tbolt_m8": 1}},
	"rail_splice": {"label": "Rail splice", "look": "alu", "kg": 0.25, "cost": 9.0, "group": "Rails",
		"spec": "Joins two lengths of rail where a run is longer than the stock.", "fasteners": {"screw_tek": 4}},
	"end_cap": {"label": "Rail end cap", "look": "plastic", "kg": 0.01, "cost": 0.6, "group": "Rails",
		"spec": "Closes the open end of a rail.", "fasteners": {}},
	"ground_lug": {"label": "Grounding lug", "look": "tin", "kg": 0.03, "cost": 4.0, "group": "Rails",
		"spec": "Bonds the rail to the equipment ground (one per rail).", "fasteners": {"tbolt_m8": 1}},
	"rail_bracket": {"label": "Rail-to-purlin L-bracket", "look": "alu", "kg": 0.12, "cost": 4.5,
		"group": "Joints", "spec": "Ties a rail down to the purlin under it.", "fasteners": {"tbolt_m8": 1, "bolt_m8": 1}},
	"strut_fitting": {"label": "90° fitting (P1026 class)", "look": "galv", "kg": 0.3, "cost": 5.5,
		"group": "Joints", "spec": "Two-hole angle bolting the rail channel to the purlin channel.",
		"fasteners": {"strut_bolt": 2}},
	"hurricane_tie": {"label": "Hurricane tie (H2.5A class)", "look": "galv", "kg": 0.07, "cost": 0.9,
		"group": "Joints", "spec": "Galvanised strap tying the rail board to the purlin board.",
		"fasteners": {"nail_8d": 10}},
	"post_bracket": {"label": "Post-top bracket", "look": "alu", "kg": 0.35, "cost": 11.0, "group": "Joints",
		"spec": "U-bracket joining the post to the purlin.", "fasteners": {"bolt_m10": 2}},
	"strut_gusset": {"label": "90° gusset (P1325 class)", "look": "galv", "kg": 0.5, "cost": 9.0, "group": "Joints",
		"spec": "Gusseted angle joining the leg channel to the purlin channel.", "fasteners": {"strut_bolt": 3}},
	"post_cap": {"label": "Post cap (BC4 class)", "look": "galv", "kg": 0.4, "cost": 6.0, "group": "Joints",
		"spec": "Galvanised cap seating the purlin board on the 4x4 post.", "fasteners": {"nail_10d": 12}},
	"ground_screw": {"label": "Ground screw", "look": "galv", "kg": 9.0, "cost": 40.0, "group": "Footings",
		"spec": "76 mm helical ground screw, 1.2 m long, with a flange head.", "fasteners": {"bolt_m12": 4}},
	"pier": {"label": "Concrete pier", "look": "concrete", "kg": 75.0, "cost": 18.0, "group": "Footings",
		"spec": "300 mm form tube, 0.9 m deep, with a cast-in anchor and post base.",
		"fasteners": {"anchor_bolt": 1}},
	"base_plate": {"label": "Post base plate", "look": "galv", "kg": 0.9, "cost": 12.0, "group": "Footings",
		"spec": "Base plate bolted to a slab or deck.", "fasteners": {"anchor_bolt": 4}},
	"post_base": {"label": "Post base (ABU44 class)", "look": "galv", "kg": 0.8, "cost": 14.0, "group": "Footings",
		"spec": "Stand-off post base holding the 4x4 off the footing.", "fasteners": {"nail_16d": 12, "anchor_bolt": 1}},
	"l_foot": {"label": "L-foot with flashing", "look": "alu", "kg": 0.3, "cost": 12.0, "group": "Roof attachment",
		"spec": "Flashed L-foot lagged into a rafter; the rail bolts to its upright.",
		"fasteners": {"lag_516": 1, "tbolt_m8": 1}},
	"ballast_bracket": {"label": "Ballast tray bracket", "look": "galv", "kg": 0.4, "cost": 6.0, "group": "Footings",
		"spec": "Ties a leg to the ballast tray.", "fasteners": {"bolt_m8": 2}},
	"brace_bolt": {"label": "Brace bolt", "look": "steel", "kg": 0.05, "cost": 0.9, "group": "Joints",
		"spec": "Through-bolt at each end of a diagonal brace.", "fasteners": {}},
	"bearing": {"label": "Tracker bearing", "look": "galv", "kg": 2.5, "cost": 45.0, "group": "Tracker",
		"spec": "Bearing housing on a post that the torque tube turns in.", "fasteners": {"bolt_m12": 4}},
	"slew_drive": {"label": "Slew drive and controller", "look": "black", "kg": 28.0, "cost": 650.0,
		"group": "Tracker", "spec": "Worm-gear slew drive on the middle post, its motor and the row's controller.",
		"fasteners": {"bolt_m12": 8}},
	"tube_clamp": {"label": "Module rail clamp", "look": "galv", "kg": 0.3, "cost": 6.0, "group": "Tracker",
		"spec": "U-bolt clamping a module rail across the torque tube.", "fasteners": {}},
	"module_bolts": {"label": "Module bolt set", "look": "steel", "kg": 0.08, "cost": 1.6, "group": "Tracker",
		"spec": "Four bolts through the module frame's mounting holes into the module rails.",
		"fasteners": {"bolt_m8": 4}},
	"pole_cap": {"label": "Pole-top mount", "look": "galv", "kg": 4.0, "cost": 60.0, "group": "Pole",
		"spec": "Sleeve and plate on top of the pole that the cross arm bolts to.", "fasteners": {"bolt_m10": 4}},
	"u_bolt": {"label": "U-bolt", "look": "galv", "kg": 0.2, "cost": 3.0, "group": "Joints",
		"spec": "Clamps a purlin to the cross arm.", "fasteners": {}},
}

## Fasteners each part brings, counted in the BOM.
const FASTENERS := {
	"tbolt_m8": {"label": "M8 × 25 T-bolt and flange nut", "kg": 0.02, "cost": 0.45},
	"bolt_m8": {"label": "M8 × 25 hex bolt, washer and nut", "kg": 0.02, "cost": 0.35},
	"bolt_m10": {"label": "M10 × 40 hex bolt, washers and nut", "kg": 0.045, "cost": 0.6},
	"bolt_m12": {"label": "M12 × 40 hex bolt, washers and nut", "kg": 0.07, "cost": 0.85},
	"strut_bolt": {"label": "3/8\" × 1\" bolt and strut spring nut", "kg": 0.05, "cost": 0.9},
	"screw_tek": {"label": "#12 self-drilling screw", "kg": 0.005, "cost": 0.1},
	"nail_8d": {"label": "8d galvanised nail", "kg": 0.004, "cost": 0.02},
	"nail_10d": {"label": "10d galvanised nail", "kg": 0.006, "cost": 0.03},
	"nail_16d": {"label": "16d galvanised nail", "kg": 0.009, "cost": 0.04},
	"lag_516": {"label": "5/16\" × 4\" lag screw and washer", "kg": 0.04, "cost": 0.6},
	"anchor_bolt": {"label": "1/2\" anchor bolt", "kg": 0.12, "cost": 1.8},
}

## The brackets a rack material is assembled with.
const KITS := {
	"alu": {"rail_joint": "rail_bracket", "leg_joint": "post_bracket", "base": "base_plate", "caps": true},
	"strut": {"rail_joint": "strut_fitting", "leg_joint": "strut_gusset", "base": "base_plate", "caps": true},
	"lumber": {"rail_joint": "hurricane_tie", "leg_joint": "post_cap", "base": "post_base", "caps": false},
}

const FOOTINGS := ["auto", "ground_screw", "pier", "base_plate"]
const FOOTING_LABELS := {"auto": "By mount (ground screws in the ground)", "ground_screw": "Ground screws",
	"pier": "Concrete piers", "base_plate": "Base plates (on a slab or deck)"}
const CLAMP_FINISHES := ["auto", "silver", "black"]
const CLAMP_FINISH_LABELS := {"auto": "Match the module frame", "silver": "Bare aluminium", "black": "Black"}


static func part(type: String) -> Dictionary:
	return PARTS.get(type, {"label": type, "look": "galv", "kg": 0.1, "cost": 1.0, "group": "Hardware",
		"spec": "", "fasteners": {}})


static func family(material: String) -> String:
	if material.begins_with("lumber"):
		return "lumber"
	if material.begins_with("unistrut"):
		return "strut"
	return "alu"


static func kit(material: String) -> Dictionary:
	return KITS[family(material)]


## The clamps' finish for a design: black on a black-framed module unless
## set.
static func clamp_finish(d: Dictionary) -> String:
	var f := str((d["spec"]["rack"] as Dictionary).get("clamp_finish", "auto"))
	if f == "auto":
		var st := str(d["module"]["frame"]["style"])
		return "black" if st == "black" or str(d["module"]["backsheet"]["front"]) == "black" else "silver"
	return f


## The footing under a ground-mounted leg.
static func footing(d: Dictionary) -> String:
	var f := str((d["spec"]["rack"] as Dictionary).get("footing", "auto"))
	if f == "auto":
		var mount := str(d["layout"]["mount"])
		return "ground_screw" if mount in ["ground", "tracker", "pole"] else "base_plate"
	return f


static func _p(type: String, origin: Vector3, x: Vector3, y: Vector3, size: Vector3, params: Dictionary,
		where: String, head: int = -1) -> Dictionary:
	var yn := y.normalized()
	var xn := (x - yn * x.dot(yn)).normalized()
	if xn.length() < 0.5:
		xn = Vector3.RIGHT if absf(yn.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
		xn = (xn - yn * xn.dot(yn)).normalized()
	var zn := xn.cross(yn).normalized()
	return {"type": type, "xf": Transform3D(Basis(xn, yn, zn), origin), "head": head, "size": size,
		"params": params, "where": where}


## Every part of the design's rack.
static func parts(d: Dictionary) -> Array:
	var out: Array = []
	var lay: Dictionary = d["layout"]
	var mount := str(lay["mount"])
	if mount == "none":
		return out
	var s: Dictionary = d["spec"]
	var r := PvLabRack.resolve(s["rack"])
	var mat := str(r["material"])
	var fam := family(mat)
	var k: Dictionary = KITS[fam]
	var rk := PvLabRack.kit(mat)
	var m: Dictionary = d["module"]
	var t_mod := float(m["dims_mm"]["t"]) * 0.001
	var finish := clamp_finish(d)
	var foot := footing(d)
	if mount == "tracker":
		_tracker_parts(d, r, out, foot)
		return out
	var rail_p := PvLabRack.profile(str(rk["rail"]))
	var rail_h := float(rail_p["h"]) * 0.001
	var rail_w := float(rail_p["w"]) * 0.001
	var purl_h := float(PvLabRack.profile(str(rk["purlin"]))["h"]) * 0.001
	var leg_w := float(PvLabRack.profile(str(rk["leg"]))["w"]) * 0.001
	var a: Dictionary = PvLabArray.resolve_array(s["array"])
	var gap := float(a["gap_mm"]) * 0.001
	var across := float(lay["across_m"])
	var cols := int(a["cols"])
	var over := float(r["rail_overhang_mm"]) * 0.001
	var stock := float(rail_p["stock_m"])
	for ti in (lay["tables"] as Array).size():
		var tb: Dictionary = lay["tables"][ti]
		var tilt := deg_to_rad(float(tb["tilt_deg"]))
		var slope := Vector3(0.0, sin(tilt), -cos(tilt))
		var nrm := Vector3(0.0, cos(tilt), sin(tilt))
		var low: Vector3 = tb["low"]
		var width := float(tb["width_m"])
		var length := float(tb["length_m"])
		var row_lbl := "row %d" % (ti + 1) if (lay["tables"] as Array).size() > 1 else ""
		var rails: Array = tb["rail_s"]
		var xs := PvLabRack.support_xs(width, float(r["leg_spacing_m"]))
		for ri in rails.size():
			var sv := float(rails[ri])
			var where := ("%s, rail %d" % [row_lbl, ri + 1]).trim_prefix(", ")
			var top := low + slope * sv + nrm * rail_h
			# Module clamps: an end clamp at each outer edge, a mid clamp in
			# every gap between neighbours.
			for side in [-1.0, 1.0]:
				var e := top + Vector3(side * width * 0.5, 0, 0)
				out.append(_p("end_clamp", e, Vector3(side, 0, 0), nrm, Vector3(0.03, t_mod + 0.006, 0.04),
					{"t": t_mod, "finish": finish}, where))
			for ci in range(1, cols):
				var gx := -width * 0.5 + float(ci) * (across + gap) - gap * 0.5
				out.append(_p("mid_clamp", top + Vector3(gx, 0, 0), Vector3.RIGHT, nrm,
					Vector3(maxf(gap, 0.004) + 0.024, t_mod + 0.006, 0.04), {"t": t_mod, "gap": gap, "finish": finish},
					where))
			var x0 := -width * 0.5 - over
			var x1 := width * 0.5 + over
			var mid := low + slope * sv + nrm * (rail_h * 0.5)
			if bool(k["caps"]):
				for side2 in [-1.0, 1.0]:
					var ex := x0 if side2 < 0.0 else x1
					out.append(_p("end_cap", mid + Vector3(ex, 0, 0), Vector3(side2, 0, 0), nrm,
						Vector3(0.004, rail_h, rail_w), {"h": rail_h, "w": rail_w, "yellow": fam == "strut"}, where))
				out.append(_p("ground_lug", top + Vector3(x0 + 0.06, 0, 0) + nrm * 0.0, Vector3.RIGHT, nrm,
					Vector3(0.02, 0.018, 0.016), {"w": rail_w}, where))
			# Splices where the run is longer than one stock length.
			var run := x1 - x0
			if stock > 0.0 and run > stock + 1e-3:
				var n_sp := int(ceil(run / stock)) - 1
				for si in n_sp:
					var sx := x0 + stock * float(si + 1)
					out.append(_p("rail_splice", mid + Vector3(sx, 0, 0), Vector3.RIGHT, nrm,
						Vector3(0.2, rail_h + 0.006, rail_w + 0.006), {"h": rail_h, "w": rail_w, "fam": fam}, where))
			# Where the rail crosses a support line.
			for x in xs:
				var at := low + Vector3(float(x), 0, 0) + slope * sv
				if mount == "roof_flush":
					var base := at - nrm * float(tb["clearance_m"])
					out.append(_p("l_foot", base, slope, nrm, Vector3(0.23, float(tb["clearance_m"]), 0.3),
						{"h": float(tb["clearance_m"]), "rail_w": rail_w, "rail_h": rail_h}, where))
				else:
					out.append(_p(str(k["rail_joint"]), at, Vector3.RIGHT, nrm, Vector3(0.06, 0.05, 0.06),
						{"rail_h": rail_h, "rail_w": rail_w, "purl_h": purl_h}, where))
		if mount == "roof_flush":
			continue
		# Leg tops, footings, brace ends.
		for x2 in xs:
			var base2 := low + Vector3(float(x2), 0, 0)
			var lbl := ("%s, support at %.2f m" % [row_lbl, float(x2) + width * 0.5]).trim_prefix(", ")
			if mount == "pole":
				continue
			var front := base2 - nrm * purl_h
			var back := base2 + slope * length - nrm * purl_h
			var floor_y := float(tb["floor_y"])
			for top2 in [front, back]:
				out.append(_p(str(k["leg_joint"]), top2, Vector3.RIGHT, Vector3.UP, Vector3(0.12, 0.12, 0.12),
					{"purl_h": purl_h, "leg_w": leg_w}, lbl))
				var at_floor := Vector3(top2.x, floor_y, top2.z)
				if mount == "ballast":
					out.append(_p("ballast_bracket", at_floor, Vector3.RIGHT, Vector3.UP, Vector3(0.1, 0.08, 0.1), {}, lbl))
				else:
					var ft := foot if mount == "ground" else (str(k["base"]) if foot == "ground_screw" else foot)
					if ft == "base_plate" and fam == "lumber":
						ft = "post_base"
					out.append(_p(ft, at_floor, Vector3.RIGHT, Vector3.UP, _footing_size(ft), {}, lbl))
			if mount in ["ground", "roof_tilt"] and bool(r["brace"]) and back.y - floor_y > 0.6:
				var bf := Vector3(front.x, floor_y + 0.08, front.z)
				var bb := back.lerp(Vector3(back.x, floor_y, back.z), 0.25)
				for p2 in [bf, bb]:
					out.append(_p("brace_bolt", p2, (bb - bf), Vector3.RIGHT, Vector3(0.06, 0.03, 0.03), {}, lbl))
		if mount == "pole":
			var mid2: Vector3 = low + slope * (length * 0.5) - nrm * purl_h
			var floor2 := float(tb["floor_y"])
			out.append(_p("pole_cap", mid2, Vector3.RIGHT, Vector3.UP, Vector3(0.2, 0.2, 0.2), {}, "pole"))
			for x3 in xs:
				out.append(_p("u_bolt", low + Vector3(float(x3), 0, 0) + slope * (length * 0.5) - nrm * purl_h,
					slope, nrm, Vector3(0.06, 0.08, 0.06), {"purl_h": purl_h}, "cross arm"))
			if foot == "pier":
				out.append(_p("pier", Vector3(mid2.x, floor2, mid2.z), Vector3.RIGHT, Vector3.UP, _footing_size("pier"),
					{}, "pole"))
	return out


static func _footing_size(t: String) -> Vector3:
	match t:
		"ground_screw":
			return Vector3(0.2, 1.4, 0.2)
		"pier":
			return Vector3(0.3, 1.0, 0.3)
		"post_base":
			return Vector3(0.1, 0.08, 0.1)
		_:
			return Vector3(0.18, 0.02, 0.18)


## Trackers: a bearing on every post, the slew drive on the middle one, a
## footing under each, module rails clamped across the tube, module bolts.
static func _tracker_parts(d: Dictionary, r: Dictionary, out: Array, foot: String) -> void:
	var lay: Dictionary = d["layout"]
	var m: Dictionary = d["module"]
	var a: Dictionary = PvLabArray.resolve_array(d["spec"]["array"])
	var land := str(a["orientation"]) == "landscape"
	for hi in (lay["heads"] as Array).size():
		var hd: Dictionary = lay["heads"][hi]
		var hub: Vector3 = hd["pos"]
		var zs := PvLabRack.support_xs(float(hd["length_m"]), float(r["leg_spacing_m"]) * 2.5)
		var mid_i := zs.size() / 2
		var where := "tracker row %d" % (hi + 1)
		for zi in zs.size():
			var z := float(zs[zi])
			var top := hub + Vector3(0, 0, z)
			out.append(_p("slew_drive" if zi == mid_i else "bearing", top, Vector3.BACK, Vector3.UP,
				Vector3(0.3, 0.3, 0.25) if zi == mid_i else Vector3(0.2, 0.22, 0.1), {}, where))
			if foot != "base_plate":
				out.append(_p(foot, Vector3(top.x, float(hd["floor_y"]), top.z), Vector3.RIGHT, Vector3.UP,
					_footing_size(foot), {}, where))
			else:
				out.append(_p("base_plate", Vector3(top.x, float(hd["floor_y"]), top.z), Vector3.RIGHT, Vector3.UP,
					_footing_size("base_plate"), {}, where))
		# Module rails cross the tube under each module; a clamp where each
		# crosses, a bolt set per module.
		for p in lay["panels"]:
			if int(p["head"]) != hi:
				continue
			var xf: Transform3D = p["xf"]
			var mw := float(m["dims_mm"]["w"]) * 0.001
			var mh := float(m["dims_mm"]["h"]) * 0.001
			var along_axis := mw if not land else mh
			for sgn in [-1.0, 1.0]:
				var zc: float = xf.origin.z + float(sgn) * along_axis * 0.3
				out.append(_p("tube_clamp", Vector3(xf.origin.x, 0.0, zc), Vector3.RIGHT, Vector3.UP,
					Vector3(0.14, 0.16, 0.05), {}, where, hi))
			out.append(_p("module_bolts", xf.origin - Vector3(0, float(m["dims_mm"]["t"]) * 0.0005, 0),
				xf.basis.x, xf.basis.y, Vector3(mw, 0.02, mh),
				{"w": mw, "h": mh}, "module %d" % (int(p["index"]) + 1), hi))


## Parts counted by type: {type: n}.
static func counts(parts_list: Array) -> Dictionary:
	var out := {}
	for p in parts_list:
		out[str(p["type"])] = int(out.get(str(p["type"]), 0)) + 1
	return out


## Fasteners counted over the parts: {fastener id: n}.
static func fastener_counts(parts_list: Array) -> Dictionary:
	var out := {}
	for p in parts_list:
		var f: Dictionary = part(str(p["type"]))["fasteners"]
		for fid in f:
			out[fid] = int(out.get(fid, 0)) + int(f[fid])
	return out
