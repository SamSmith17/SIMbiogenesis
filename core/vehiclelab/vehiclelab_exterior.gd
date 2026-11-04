class_name VehicleExterior
extends RefCounted

## What bolts onto a living vehicle's outside: roof fans and vents, an AC
## unit, a Starlink dish, antennae, wire glands, racks, a cargo box, solar
## panels on the roof or the sides, an awning, a ladder, a light bar, a bike
## rack, extra windows, a hitch. Pure: the designer drags these onto faces of
## the body, the builder draws them, VehicleDesign adds their mass and watts.
##
## An element is {id, type, face, u, v, …type fields}. Faces and their (u, v)
## in the vehicle's local frame (VehicleDesign header):
##   roof   u = x (across, + = right), v = z (along, - = front); sits on the
##          roof's top surface (its crown followed)
##   left   x = -half width: u = z (along), v = y (height)
##   right  x = +half width: u = z, v = y
##   rear   z = the body's back: u = x, v = y
## (u, v) is the element's CENTRE on that face.

const FACES := ["roof", "left", "right", "rear"]
const ROOF_CORNER_SHARE := 0.6

## Solar modules a van builder buys (data sheets as published, rounded):
## a 400 W rigid 108-half-cell module (1722 x 1134 mm, ~21 kg), a 200 W rigid
## 12 V-class module (1480 x 670 mm, ~12 kg), a compact 100 W rigid 12 V
## module (~1200 x 500 mm, ~7 kg), a 100 W flexible ETFE module
## (1050 x 540 mm, ~2 kg).
const MODULES := {
	"rigid_400": {"label": "Rigid 400 W", "long": 1.722, "short": 1.134, "watts": 400.0, "kg": 21.0, "t": 0.035},
	"rigid_200": {"label": "Rigid 200 W", "long": 1.48, "short": 0.67, "watts": 200.0, "kg": 12.0, "t": 0.035},
	"rigid_100": {"label": "Rigid 100 W", "long": 1.2, "short": 0.5, "watts": 100.0, "kg": 7.0, "t": 0.035},
	"flex_100": {"label": "Flexible 100 W", "long": 1.05, "short": 0.54, "watts": 100.0, "kg": 2.0, "t": 0.004},
}
const MODULE_GAP := 0.02

## Every type: label, the faces it may go on, its size on the face (w along
## u, l along v, h out of the face), mass, and the watts it draws (a load the
## vehicle's electrical system will carry in Phase 4).
const TYPES := {
	"fan": {"label": "Roof fan", "icon": "fan", "faces": ["roof"], "w": 0.42, "l": 0.42, "h": 0.22,
		"kg": 3.5, "load_w": 40.0, "tip": "A powered roof vent fan (MaxxAir / Fan-Tastic class, 14 in opening)"},
	"vent": {"label": "Roof vent", "icon": "wind", "faces": ["roof"], "w": 0.38, "l": 0.38, "h": 0.1,
		"kg": 2.0, "load_w": 0.0, "tip": "A passive 14 in roof vent"},
	"ac": {"label": "Rooftop AC", "icon": "snowflake", "faces": ["roof"], "w": 0.76, "l": 1.02, "h": 0.32,
		"kg": 40.0, "load_w": 1400.0, "ac_load": true,
		"tip": "A 13,500 BTU rooftop air conditioner (~1.4 kW running, 120 V: an inverter or shore power)"},
	"starlink": {"label": "Starlink dish", "icon": "satellite-dish", "faces": ["roof"], "w": 0.6, "l": 0.6, "h": 0.5,
		"kg": 4.0, "load_w": 75.0, "tip": "A satellite internet dish on a short mast (~75 W)"},
	"antenna": {"label": "Antenna", "icon": "radio", "faces": ["roof"], "w": 0.08, "l": 0.08, "h": 1.0,
		"kg": 0.5, "load_w": 0.0, "tip": "A whip antenna (radio / cellular)"},
	"gland": {"label": "Wire gland", "icon": "plug", "faces": ["roof", "left", "right", "rear"], "w": 0.12,
		"l": 0.1, "h": 0.06, "kg": 0.2, "load_w": 0.0, "tip": "A cable entry gland (solar or shore power through the skin)"},
	"rack": {"label": "Roof rack", "icon": "grid-2x2", "faces": ["roof"], "w": 1.7, "l": 2.4, "h": 0.12,
		"kg": 35.0, "load_w": 0.0, "tip": "A flat roof rack: rails and cross bars"},
	"cargo_box": {"label": "Roof cargo box", "icon": "package", "faces": ["roof"], "w": 0.9, "l": 2.0, "h": 0.45,
		"kg": 20.0, "load_w": 0.0, "tip": "A hard-shell roof box (~450 L)"},
	"solar": {"label": "Solar panels", "icon": "sun", "faces": ["roof", "left", "right", "rear"], "w": 1.2, "l": 1.8,
		"h": 0.06, "kg": 0.0, "load_w": 0.0, "tip": "Solar modules in rows and columns, flush on the face"},
	"awning": {"label": "Awning", "icon": "umbrella", "faces": ["left", "right"], "w": 3.0, "l": 0.18, "h": 0.18,
		"kg": 25.0, "load_w": 0.0, "tip": "A roll-out awning; open it for shade beside the vehicle"},
	"ladder": {"label": "Ladder", "icon": "move-vertical", "faces": ["rear", "left", "right"], "w": 0.42, "l": 1.6,
		"h": 0.1, "kg": 8.0, "load_w": 0.0, "tip": "A ladder up to the roof"},
	"light_bar": {"label": "Light bar", "icon": "lightbulb", "faces": ["roof"], "w": 1.0, "l": 0.12, "h": 0.1,
		"kg": 3.0, "load_w": 120.0, "tip": "An LED light bar (~120 W)"},
	"bike_rack": {"label": "Bike rack", "icon": "bike", "faces": ["rear"], "w": 1.2, "l": 0.9, "h": 0.5,
		"kg": 15.0, "load_w": 0.0, "tip": "A rear bike rack"},
	"window": {"label": "Window", "icon": "square", "faces": ["left", "right", "rear"], "w": 0.8, "l": 0.5,
		"h": 0.02, "kg": 6.0, "load_w": 0.0, "tip": "An extra window cut into the side"},
	"hitch": {"label": "Hitch receiver", "icon": "link", "faces": ["rear"], "w": 0.12, "l": 0.12, "h": 0.3,
		"kg": 15.0, "load_w": 0.0, "tip": "A 2 in hitch receiver (tow a trailer, carry a rack)"},
}

## The designer's palette: a type plus overrides.
const TOOL_PRESETS := [
	{"id": "fan", "element": {"type": "fan"}},
	{"id": "vent", "element": {"type": "vent"}},
	{"id": "ac", "element": {"type": "ac"}},
	{"id": "starlink", "element": {"type": "starlink"}},
	{"id": "antenna", "element": {"type": "antenna"}},
	{"id": "gland", "element": {"type": "gland"}},
	{"id": "solar_roof", "label": "Solar (roof, 400 W)", "element": {"type": "solar", "module": "rigid_400", "rows": 1, "cols": 2}},
	{"id": "solar_flex", "label": "Solar (flexible, 100 W)", "element": {"type": "solar", "module": "flex_100", "rows": 1, "cols": 2}},
	{"id": "rack", "element": {"type": "rack"}},
	{"id": "cargo_box", "element": {"type": "cargo_box"}},
	{"id": "awning", "element": {"type": "awning"}},
	{"id": "ladder", "element": {"type": "ladder"}},
	{"id": "light_bar", "element": {"type": "light_bar"}},
	{"id": "bike_rack", "element": {"type": "bike_rack"}},
	{"id": "window", "element": {"type": "window"}},
	{"id": "hitch", "element": {"type": "hitch"}},
]

## The inspector's rows per type: [key, label, kind, min, max, step, unit].
const FIELDS := {
	"solar": [["module", "Module", "module"], ["rows", "Rows", "int", 1, 8, 1, ""],
		["cols", "Columns", "int", 1, 8, 1, ""], ["portrait", "Long side across", "bool"]],
	"awning": [["w", "Length", "float", 1.5, 6.0, 0.1, "m"], ["ext", "Reach", "float", 1.0, 3.0, 0.1, "m"],
		["open", "Rolled out", "bool"]],
	"rack": [["w", "Width", "float", 0.8, 2.4, 0.05, "m"], ["l", "Length", "float", 0.8, 6.0, 0.1, "m"]],
	"cargo_box": [["l", "Length", "float", 1.2, 2.4, 0.05, "m"]],
	"window": [["w", "Width", "float", 0.3, 1.8, 0.05, "m"], ["l", "Height", "float", 0.25, 1.0, 0.05, "m"]],
	"ladder": [["l", "Height", "float", 0.8, 3.2, 0.05, "m"]],
	"light_bar": [["w", "Length", "float", 0.4, 1.8, 0.05, "m"]],
}


static func type_info(t: String) -> Dictionary:
	return TYPES.get(t, {})


## The roof / side palette's groups, in order (the designer's buttons):
## [group, [tool preset ids]].
const TOOL_GROUPS := [
	["Power", ["solar_roof", "solar_flex", "gland", "light_bar"]],
	["Comfort", ["fan", "vent", "ac", "awning", "window", "starlink", "antenna"]],
	["Access", ["ladder", "hitch"]],
	["Carry", ["rack", "cargo_box", "bike_rack"]],
]

## Faces and doors in words.
const FACE_WORDS := {"roof": "roof", "left": "left side", "right": "right side", "rear": "rear",
	"side": "side", "front": "front"}


static func face_word(f: String) -> String:
	return str(FACE_WORDS.get(f, f.replace("_", " ")))


static func label_of(el: Dictionary) -> String:
	var t := type_info(str(el.get("type", "")))
	return str(t.get("label", str(el.get("type", ""))))


## The four faces' extents on a solved design (local metres). The roof
## reaches ROOF_CORNER_SHARE of the way into the corner radius: a module's
## edge may overhang the start of the curve (two 1.134 m modules across a
## 2.44 m bus roof is how skoolies are built), not the wall.
static func faces(d: Dictionary) -> Dictionary:
	var b: Dictionary = d["body"]
	var hw := float(b["w"]) * 0.5
	var z0 := float(b["z0"]) + float(b.get("rake_top", 0.0)) + 0.05
	var z1 := float(b["z1"])
	var top_hw := maxf(hw - float(b.get("corner_r", 0.1)) * (1.0 - ROOF_CORNER_SHARE), 0.2)
	return {
		"roof": {"u0": -top_hw, "u1": top_hw, "v0": z0, "v1": z1 - 0.05},
		"left": {"u0": float(b["z0"]) + 0.1, "u1": z1 - 0.05, "v0": float(b["y0"]) + 0.05, "v1": float(b["wall_top"]), "x": -hw},
		"right": {"u0": float(b["z0"]) + 0.1, "u1": z1 - 0.05, "v0": float(b["y0"]) + 0.05, "v1": float(b["wall_top"]), "x": hw},
		"rear": {"u0": -hw + 0.05, "u1": hw - 0.05, "v0": float(b["y0"]) - 0.25, "v1": float(b["wall_top"]), "z": z1},
	}


## The roof's top surface height at `x` (the crown followed).
static func roof_y(d: Dictionary, x: float) -> float:
	var b: Dictionary = d["body"]
	var hw := float(b["w"]) * 0.5
	var top_hw := maxf(hw - float(b.get("corner_r", 0.1)), 0.2)
	var t := clampf(absf(x) / top_hw, 0.0, 1.0)
	return float(b["h"]) - float(b.get("crown", 0.0)) * t * t


## An element with every default filled and clamped onto its face.
static func resolve_element(d: Dictionary, e: Dictionary) -> Dictionary:
	var el: Dictionary = e.duplicate(true)
	var type := str(el.get("type", ""))
	var t := type_info(type)
	if t.is_empty():
		return {}
	var faces_ok: Array = t["faces"]
	var face := str(el.get("face", faces_ok[0]))
	if not faces_ok.has(face):
		face = str(faces_ok[0])
	el["face"] = face
	if type == "solar":
		var m: Dictionary = MODULES.get(str(el.get("module", "rigid_400")), MODULES["rigid_400"])
		el["module"] = str(el.get("module", "rigid_400")) if MODULES.has(str(el.get("module", ""))) else "rigid_400"
		el["rows"] = clampi(int(el.get("rows", 1)), 1, 8)
		el["cols"] = clampi(int(el.get("cols", 2)), 1, 8)
		el["portrait"] = bool(el.get("portrait", false))
		var mu := float(m["long"]) if (face != "roof") != bool(el["portrait"]) else float(m["short"])
		var mv := float(m["short"]) if (face != "roof") != bool(el["portrait"]) else float(m["long"])
		el["w"] = float(el["cols"]) * mu + float(int(el["cols"]) - 1) * MODULE_GAP
		el["l"] = float(el["rows"]) * mv + float(int(el["rows"]) - 1) * MODULE_GAP
		el["mod_u"] = mu
		el["mod_v"] = mv
	else:
		el["w"] = float(el.get("w", t["w"]))
		el["l"] = float(el.get("l", t["l"]))
	el["h"] = float(el.get("h", t["h"]))
	if type == "awning":
		el["ext"] = clampf(float(el.get("ext", 2.4)), 1.0, 3.0)
		el["open"] = bool(el.get("open", false))
	var f: Dictionary = faces(d)[face]
	var span_u := float(f["u1"]) - float(f["u0"])
	var span_v := float(f["v1"]) - float(f["v0"])
	if type == "solar":
		# An array that hangs off the face loses whole modules, never part
		# of one: the columns (then the rows) come down until it fits, and
		# the item says how many it asked for (`cut_cols` / `cut_rows`).
		var mu := float(el["mod_u"])
		var mv := float(el["mod_v"])
		var cols := int(el["cols"])
		var rows := int(el["rows"])
		var want_cols := cols
		var want_rows := rows
		while cols > 1 and float(cols) * mu + float(cols - 1) * MODULE_GAP > span_u + 1e-6:
			cols -= 1
		while rows > 1 and float(rows) * mv + float(rows - 1) * MODULE_GAP > span_v + 1e-6:
			rows -= 1
		el["cols"] = cols
		el["rows"] = rows
		if cols < want_cols:
			el["cut_cols"] = want_cols
		if rows < want_rows:
			el["cut_rows"] = want_rows
		el["w"] = float(cols) * mu + float(cols - 1) * MODULE_GAP
		el["l"] = float(rows) * mv + float(rows - 1) * MODULE_GAP
	el["w"] = minf(float(el["w"]), span_u)
	el["l"] = minf(float(el["l"]), span_v) if type != "ladder" else float(el["l"])
	var mid_u := (float(f["u0"]) + float(f["u1"])) * 0.5
	var mid_v := (float(f["v0"]) + float(f["v1"])) * 0.5
	if type == "awning":
		mid_v = float(f["v1"]) - 0.12
	if type == "ladder":
		mid_v = (float(f["v0"]) + float(d["body"]["h"])) * 0.5
	if type == "hitch":
		mid_v = float(d["body"]["y0"]) - 0.15
	var u := float(el.get("u", mid_u))
	var v := float(el.get("v", mid_v))
	el["u"] = clampf(u, float(f["u0"]) + float(el["w"]) * 0.5, float(f["u1"]) - float(el["w"]) * 0.5) \
		if float(el["w"]) < span_u else mid_u
	if type == "ladder" or type == "hitch" or type == "awning":
		el["v"] = v if el.has("v") else mid_v
	else:
		el["v"] = clampf(v, float(f["v0"]) + float(el["l"]) * 0.5, float(f["v1"]) - float(el["l"]) * 0.5) \
			if float(el["l"]) < span_v else mid_v
	el["id"] = str(el.get("id", ""))
	return el


# --- checks -----------------------------------------------------------------------

## The outside's checks, {level, text, ids, why}: an array that lost
## modules to fit its face, two items on one face overlapping, a side item
## across the side door or a window. VehicleDesign adds them to its own.
static func checks(d: Dictionary) -> Array:
	var c: Array = []
	var els: Array = d.get("exterior", [])
	if els.is_empty():
		return c
	for e in els:
		var el: Dictionary = e
		if str(el["type"]) != "solar":
			continue
		var cut := el.has("cut_cols") or el.has("cut_rows")
		if cut:
			var want := int(el.get("cut_cols", el["cols"])) * int(el.get("cut_rows", el["rows"]))
			var got := int(el["cols"]) * int(el["rows"])
			c.append({"level": "warn", "ids": [str(el["id"])],
				"text": "The solar array does not fit the %s: %d of %d modules dropped." %
					[str(el["face"]), want - got, want],
				"why": "A module hanging past the edge has nothing to mount to; the array keeps whole modules only. A smaller module or the long side across fits more."})
	# Two items on one face: their (u, v) rectangles overlap.
	for i in els.size():
		for j in range(i + 1, els.size()):
			var a: Dictionary = els[i]
			var b: Dictionary = els[j]
			if str(a["face"]) != str(b["face"]):
				continue
			# Things are mounted ON a rack: a module or a box over it is the point.
			if str(a["type"]) == "rack" or str(b["type"]) == "rack":
				continue
			if _rect_overlap(float(a["u"]), float(a["v"]), float(a["w"]), float(a["l"]),
					float(b["u"]), float(b["v"]), float(b["w"]), float(b["l"])):
				c.append({"level": "warn", "ids": [str(a["id"]), str(b["id"])],
					"text": "%s and %s overlap on the %s." % [label_of(a), label_of(b), str(a["face"])],
					"why": "Two things cannot share the same patch of skin; slide one along the face."})
	# A side item across the side door or a window.
	var hw := float((d["body"] as Dictionary)["w"]) * 0.5
	for e in els:
		var el: Dictionary = e
		var face := str(el["face"])
		if face != "left" and face != "right":
			continue
		if str(el["type"]) == "awning":
			continue   # it hangs above the wall, over the door by design
		var sx := 1.0 if face == "right" else -1.0
		var eu := float(el["u"])
		var ev := float(el["v"])
		var ew := float(el["w"])
		var el_l := float(el["l"])
		if sx > 0.0:
			for sp in VehicleDesign.door_spans(d):
				var sd: Dictionary = sp
				if str(sd["where"]) != "side":
					continue
				var dz := (float(sd["z0"]) + float(sd["z1"])) * 0.5
				var dy := (float(sd["y0"]) + float(sd["y1"])) * 0.5
				if _rect_overlap(eu, ev, ew, el_l, dz, dy, float(sd["z1"]) - float(sd["z0"]), float(sd["y1"]) - float(sd["y0"])):
					c.append({"level": "warn", "ids": [str(el["id"])],
						"text": "The %s sits across the side door." % label_of(el).to_lower(),
						"why": "The door has to open and people step through it; move the item along the wall."})
		for w in VehicleDesign.window_spans(d):
			var wd: Dictionary = w
			if float(wd["sx"]) != sx:
				continue
			var wz := (float(wd["z0"]) + float(wd["z1"])) * 0.5
			var wy := (float(wd["y0"]) + float(wd["y1"])) * 0.5
			if _rect_overlap(eu, ev, ew, el_l, wz, wy, float(wd["z1"]) - float(wd["z0"]), float(wd["y1"]) - float(wd["y0"])):
				c.append({"level": "warn", "ids": [str(el["id"])],
					"text": "The %s covers a window on the %s side." % [label_of(el).to_lower(), face],
					"why": "The body's own window is there (over the bed or the dinette); mount the item beside it."})
	return c


static func _rect_overlap(au: float, av: float, aw: float, al: float,
		bu: float, bv: float, bw: float, bl: float) -> bool:
	return absf(au - bu) < (aw + bw) * 0.5 - 0.01 and absf(av - bv) < (al + bl) * 0.5 - 0.01


## Where an element sits in the vehicle's frame: {centre, basis (x = u,
## y = out of the face, z = v), size (w, h, l)} — its oriented box.
static func frame(d: Dictionary, el: Dictionary) -> Dictionary:
	var face := str(el["face"])
	var u := float(el["u"])
	var v := float(el["v"])
	var h := float(el["h"])
	var size := Vector3(float(el["w"]), h, float(el["l"]))
	var f: Dictionary = faces(d)[face]
	match face:
		"roof":
			var y := roof_y(d, u)
			return {"centre": Vector3(u, y + h * 0.5, v), "basis": Basis.IDENTITY, "size": size, "base": Vector3(u, y, v)}
		"left", "right":
			var sx := -1.0 if face == "left" else 1.0
			var x := float(f["x"])
			# x = along (u = z), y = out of the face, z = up (v = y).
			var bas := Basis(Vector3(0, 0, 1), Vector3(sx, 0, 0), Vector3(0, 1, 0))
			return {"centre": Vector3(x + sx * h * 0.5, v, u), "basis": bas, "size": size, "base": Vector3(x, v, u)}
		"rear":
			var z := float(f["z"])
			var bas2 := Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0))
			return {"centre": Vector3(u, v, z + h * 0.5), "basis": bas2, "size": size, "base": Vector3(u, v, z)}
	return {}


## The ray (vehicle-local) against the four faces: the nearest hit as {face,
## u, v, t, point}, or {}.
static func face_hit(d: Dictionary, o: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var fs := faces(d)
	# Roof: march down through the crown's slab (from its top to the wall
	# tops) to the first point under the surface, then bisect onto it. A
	# fixed-point refinement does not converge on a grazing ray over a crown.
	var r: Dictionary = fs["roof"]
	if dir.y < -1e-4:
		var t_top := maxf((float(d["body"]["h"]) + 0.01 - o.y) / dir.y, 0.0)
		var t_bot := (float(d["body"]["wall_top"]) - o.y) / dir.y
		if t_bot > t_top:
			var steps := 48
			var prev := t_top
			for i in range(1, steps + 1):
				var t := lerpf(t_top, t_bot, float(i) / float(steps))
				var p := o + dir * t
				if p.y <= roof_y(d, p.x):
					var a := prev
					var b := t
					for _k in 24:
						var m := (a + b) * 0.5
						var pm := o + dir * m
						if pm.y <= roof_y(d, pm.x):
							b = m
						else:
							a = m
					var p2 := o + dir * b
					if p2.x >= float(r["u0"]) - 0.05 and p2.x <= float(r["u1"]) + 0.05 \
							and p2.z >= float(r["v0"]) and p2.z <= float(r["v1"]):
						best = {"face": "roof", "u": p2.x, "v": p2.z, "t": b, "point": p2}
					break
				prev = t
	for side in ["left", "right"]:
		var f: Dictionary = fs[side]
		var x := float(f["x"])
		if absf(dir.x) < 1e-5 or (side == "left" and dir.x <= 0.0) or (side == "right" and dir.x >= 0.0):
			continue
		var t2 := (x - o.x) / dir.x
		var p3 := o + dir * t2
		if t2 > 0.0 and p3.z >= float(f["u0"]) and p3.z <= float(f["u1"]) and p3.y >= float(f["v0"]) - 0.3 \
				and p3.y <= float(f["v1"]) + 0.05 and (best.is_empty() or t2 < float(best["t"])):
			best = {"face": side, "u": p3.z, "v": p3.y, "t": t2, "point": p3}
	var rf: Dictionary = fs["rear"]
	if dir.z < -1e-5:
		var t3 := (float(rf["z"]) - o.z) / dir.z
		var p4 := o + dir * t3
		if t3 > 0.0 and p4.x >= float(rf["u0"]) and p4.x <= float(rf["u1"]) and p4.y >= float(rf["v0"]) \
				and p4.y <= float(rf["v1"]) + 0.05 and (best.is_empty() or t3 < float(best["t"])):
			best = {"face": "rear", "u": p4.x, "v": p4.y, "t": t3, "point": p4}
	return best


## The ray against ONE face's plane (the roof's at `level`, a side's or the
## rear's own): {face, u, v} wherever it crosses, inside the face or not —
## what a drag slides an item along. {} when the ray runs parallel or away.
static func plane_hit(d: Dictionary, face: String, o: Vector3, dir: Vector3, level: float) -> Dictionary:
	var f: Dictionary = faces(d)[face]
	match face:
		"roof":
			if dir.y > -1e-5:
				return {}
			var t := (level - o.y) / dir.y
			var p := o + dir * t
			return {"face": face, "u": p.x, "v": p.z, "t": t} if t > 0.0 else {}
		"left", "right":
			if absf(dir.x) < 1e-5:
				return {}
			var t2 := (float(f["x"]) - o.x) / dir.x
			var p2 := o + dir * t2
			return {"face": face, "u": p2.z, "v": p2.y, "t": t2} if t2 > 0.0 else {}
		"rear":
			if absf(dir.z) < 1e-5:
				return {}
			var t3 := (float(f["z"]) - o.z) / dir.z
			var p3 := o + dir * t3
			return {"face": face, "u": p3.x, "v": p3.y, "t": t3} if t3 > 0.0 else {}
	return {}


## The element under a ray (vehicle-local): its id, or "". Among items hit
## at about the same depth the smallest wins: a fan standing on a solar
## array is what the player aimed at, not the array's flat box round it.
static func pick(d: Dictionary, o: Vector3, dir: Vector3) -> String:
	var hits: Array = []
	var best_t := INF
	for e in d.get("exterior", []):
		var el: Dictionary = e
		var fr := frame(d, el)
		if fr.is_empty():
			continue
		var bas: Basis = fr["basis"]
		var inv := bas.inverse()
		var lo := inv * (o - (fr["centre"] as Vector3))
		var ld := inv * dir
		var size: Vector3 = fr["size"]
		var half: Vector3 = size * 0.5 + Vector3(0.05, 0.05, 0.05)
		var t := _ray_box(lo, ld, half)
		if t >= 0.0:
			hits.append([t, size.x * size.z, str(el["id"])])
			best_t = minf(best_t, t)
	var best := ""
	var best_area := INF
	for h in hits:
		if float(h[0]) <= best_t + 0.35 and float(h[1]) < best_area:
			best_area = float(h[1])
			best = str(h[2])
	return best


static func _ray_box(o: Vector3, d: Vector3, half: Vector3) -> float:
	var t0 := -INF
	var t1 := INF
	for i in 3:
		if absf(d[i]) < 1e-9:
			if absf(o[i]) > half[i]:
				return -1.0
			continue
		var a := (-half[i] - o[i]) / d[i]
		var b := (half[i] - o[i]) / d[i]
		t0 = maxf(t0, minf(a, b))
		t1 = minf(t1, maxf(a, b))
	if t1 < maxf(t0, 0.0):
		return -1.0
	return maxf(t0, 0.0)


## The element a click on a face would place: the armed template moved to
## the hit, on a face it may go on (or {} when it may not).
static func candidate(d: Dictionary, template: Dictionary, hit: Dictionary) -> Dictionary:
	if hit.is_empty():
		return {}
	var t := type_info(str(template.get("type", "")))
	if t.is_empty() or not (t["faces"] as Array).has(str(hit["face"])):
		return {}
	var el: Dictionary = template.duplicate(true)
	el["face"] = str(hit["face"])
	el["u"] = snappedf(float(hit["u"]), 0.05)
	el["v"] = snappedf(float(hit["v"]), 0.05)
	if str(el["type"]) == "ladder" or str(el["type"]) == "awning" or str(el["type"]) == "hitch":
		el.erase("v")
	return resolve_element(d, el)


## Totals over the resolved elements: {kg, solar_w, load_w, modules}.
static func totals(els: Array) -> Dictionary:
	var kg := 0.0
	var solar := 0.0
	var load := 0.0
	var modules := 0
	for e in els:
		var el: Dictionary = e
		var t := type_info(str(el["type"]))
		kg += mass_of(el)
		if str(el["type"]) == "solar":
			var m: Dictionary = MODULES[str(el["module"])]
			var n := int(el["rows"]) * int(el["cols"])
			modules += n
			solar += float(m["watts"]) * float(n)
		else:
			load += float(t.get("load_w", 0.0))
	return {"kg": kg, "solar_w": solar, "load_w": load, "modules": modules}


## One item's mass: its type's, or the modules (+ 2 kg of mounts per rigid
## module) for a solar item.
static func mass_of(el: Dictionary) -> float:
	if str(el.get("type", "")) == "solar":
		var m: Dictionary = MODULES.get(str(el.get("module", "rigid_400")), MODULES["rigid_400"])
		var n := int(el.get("rows", 1)) * int(el.get("cols", 1))
		return float(m["kg"]) * float(n) + (2.0 * float(n) if str(el.get("module", "")) != "flex_100" else 0.0)
	return float(type_info(str(el.get("type", ""))).get("kg", 0.0))
