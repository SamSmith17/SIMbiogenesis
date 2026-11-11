class_name EarthshipDesign
extends RefCounted

## A solved Earthship (pure): every part as a box, a prism or a glass quad in
## the spec's frame (x along the row, +z the glazing side, y = 0 at grade),
## the earthworks the terrain is asked for, the numbers and the checks.
## Cached by EarthshipSpec.key_of. EarthshipBuilder draws `parts`; the prop
## record's `earthworks` is `earthworks_simple` through StructureEarthworks.
##
## Part shapes:
##   {"box": [Vector3 lo, Vector3 hi], "mat": m, "col": bool}
##   {"prism": PackedVector2Array of (z, y), "x": [xa, xb], "mat": m, "col": bool}
##   {"quad": [Vector3 a, b, c, d], "mat": "glass", "col": bool}
## Materials: plaster, tyre, floor, roof, wood, trim, soil, glass, concrete.

const CACHE_MAX := 24
const KNEE_T := 0.3              ## front kneewall thickness (m)
const DOOR_W := 1.2              ## the entry bay (m)
const DOOR_CLEAR_W := 0.9        ## the opening in it (m)
const DOOR_H := 2.15             ## door top above the corridor floor (m)
const SLAB_T := 0.15
const FOOTING_M := 0.3           ## walls start this far under the floor
const VIGA_SPACING_M := 0.6
const VIGA_D_M := 0.2
const RAMP_GRADE := 3.5          ## run per metre of drop for the entry ramp
## A rammed tyre: ~0.75 m across, ~0.28 m a course, ~136 kg (300 lb) of
## earth (Reynolds, Earthship Vol. 1), ~0.085 m³ at 1600 kg/m³.
const TYRE_D_M := 0.75
const TYRE_COURSE_M := 0.28
const TYRE_EARTH_KG := 136.0
const TYRE_EARTH_M3 := 0.085

static var _cache: Dictionary = {}
static var _order: Array = []


static func solve(spec_in: Variant) -> Dictionary:
	var s := EarthshipSpec.resolve(spec_in)
	var key := EarthshipSpec.key_of(s)
	if _cache.has(key):
		return _cache[key]
	var d := _solve(s)
	_cache[key] = d
	_order.append(key)
	while _order.size() > CACHE_MAX:
		_cache.erase(_order.pop_front())
	return d


## Glazing at right angles to the winter-solstice noon sun (degrees above
## horizontal), clamped to what the designer offers.
static func glazing_for_lat(lat_deg: float) -> float:
	return clampf(absf(lat_deg) + 23.44, 35.0, 90.0)


static func _box(lo: Vector3, hi: Vector3, mat: String, col: bool = true) -> Dictionary:
	return {"box": [Vector3(minf(lo.x, hi.x), minf(lo.y, hi.y), minf(lo.z, hi.z)),
		Vector3(maxf(lo.x, hi.x), maxf(lo.y, hi.y), maxf(lo.z, hi.z))], "mat": mat, "col": col}


static func _prism(profile: PackedVector2Array, xa: float, xb: float, mat: String, col: bool = true) -> Dictionary:
	return {"prism": profile, "x": [minf(xa, xb), maxf(xa, xb)], "mat": mat, "col": col}


static func _solve(s: Dictionary) -> Dictionary:
	var n := int(s["modules"])
	var w := float(s["module_w"])
	var dep := float(s["module_d"])
	var t := float(s["wall_t"])
	var h := float(s["wall_h"])
	var f := float(s["floor_depth"])
	var g := float(s["corridor_d"])
	var a := deg_to_rad(float(s["glazing_deg"]))
	var sill := float(s["sill_h"])
	var roof_t := float(s["roof_t"])
	var length := float(n) * w + float(n + 1) * t
	var x0 := -length * 0.5
	var x1 := -x0
	var yf := -f
	var yc := yf + h
	var roof_top := yc + roof_t
	var z_back := -dep - t
	var zf_out := g + KNEE_T
	var ys := yf + sill
	# The glazing rises from the sill at the front to the ceiling line; a
	# shallow angle on a short corridor runs out of room and stops lower.
	var tan_a := tan(a) if a < deg_to_rad(89.9) else 1e6
	var run := (yc - ys) / tan_a
	var zg := g - run
	var yt := yc
	if zg < 0.3:
		zg = 0.3
		yt = ys + (g - 0.3) * tan_a
	var entry := str(s["entry"])
	var ex := 0.0
	if entry == "left":
		ex = x0 + t + w * 0.5
	elif entry == "right":
		ex = x1 - t - w * 0.5
	var parts: Array = []
	var rooms: Array = []
	# Floor slab under the whole footprint (walls stand on it).
	parts.append(_box(Vector3(x0, yf - SLAB_T, z_back), Vector3(x1, yf, zf_out), "floor"))
	# Back wall.
	parts.append(_box(Vector3(x0, yf - FOOTING_M, z_back), Vector3(x1, yc, -dep), "plaster"))
	# The U arms between rooms; the two outer ones run on as the end walls of
	# the greenhouse, cut to its glazing line.
	for i in n + 1:
		var xa := x0 + float(i) * (w + t)
		var xb := xa + t
		parts.append(_box(Vector3(xa, yf - FOOTING_M, -dep), Vector3(xb, yc, 0.0), "plaster"))
		if i == 0 or i == n:
			var prof := PackedVector2Array([Vector2(0.0, yf - FOOTING_M), Vector2(zf_out, yf - FOOTING_M),
				Vector2(zf_out, ys), Vector2(g, ys), Vector2(zg, yt), Vector2(0.0, yc)])
			parts.append(_prism(prof, xa, xb, "plaster"))
	for i in n:
		var rx := x0 + t + float(i) * (w + t)
		rooms.append({"x0": rx, "x1": rx + w, "z0": -dep, "z1": 0.0})
		# Vigas across the room under the ceiling.
		var k := 0
		var zv := -dep + VIGA_SPACING_M * 0.5
		while zv < -0.2:
			parts.append(_box(Vector3(rx - t * 0.5, yc - VIGA_D_M, zv - VIGA_D_M * 0.5),
				Vector3(rx + w + t * 0.5, yc, zv + VIGA_D_M * 0.5), "wood", false))
			zv += VIGA_SPACING_M
			k += 1
	# Roof over the rooms, eaves past the walls.
	parts.append(_box(Vector3(x0 - 0.3, yc, z_back - 0.3), Vector3(x1 + 0.3, roof_top, 0.15), "roof"))
	# Greenhouse roof: from the ceiling line at the rooms down to the glazing top.
	parts.append(_prism(PackedVector2Array([Vector2(0.15, yc), Vector2(zg, yt),
		Vector2(zg, yt + 0.22), Vector2(0.15, yc + 0.22)]), x0, x1, "trim"))
	# Front kneewall and planter, with the entry bay open.
	var dl := ex - DOOR_W * 0.5
	var dr := ex + DOOR_W * 0.5
	var xi0 := x0 + t
	var xi1 := x1 - t
	var pw := float(s["planter_w"])
	var ph := float(s["planter_h"])
	for seg in [[xi0, dl], [dr, xi1]]:
		var sa: float = seg[0]
		var sb: float = seg[1]
		if sb - sa < 0.05:
			continue
		parts.append(_box(Vector3(sa, yf - FOOTING_M, g), Vector3(sb, ys, zf_out), "plaster"))
		parts.append(_box(Vector3(sa, ys, g - 0.05), Vector3(sb, ys + 0.12, zf_out), "trim"))
		if pw > 0.05:
			var pa := sa if sa > xi0 + 0.01 else sa
			var pb := sb
			if absf(sb - dl) < 0.01:
				pb = dl - 0.3
			if absf(sa - dr) < 0.01:
				pa = dr + 0.3
			if pb - pa > 0.3:
				parts.append(_box(Vector3(pa, yf, g - pw), Vector3(pb, yf + ph, g), "plaster"))
				parts.append(_box(Vector3(pa + 0.08, yf + ph - 0.02, g - pw + 0.08),
					Vector3(pb - 0.08, yf + ph + 0.01, g - 0.08), "soil", false))
		# Glazing over this run, in bays about 1.2 m wide.
		var bays := maxi(1, ceili((sb - sa) / 1.25))
		for bi in bays:
			var ba := sa + (sb - sa) * float(bi) / float(bays)
			var bb := sa + (sb - sa) * float(bi + 1) / float(bays)
			parts.append({"quad": [Vector3(ba, ys + 0.12, g - 0.0), Vector3(bb, ys + 0.12, g - 0.0),
				Vector3(bb, yt, zg), Vector3(ba, yt, zg)], "mat": "glass", "col": true})
			parts.append(_prism(PackedVector2Array([Vector2(g, ys + 0.12), Vector2(g + 0.08, ys + 0.12),
				Vector2(zg + 0.08, yt), Vector2(zg, yt)]), bb - 0.04, bb + 0.04, "trim", false))
	# The entry bay: a doorway set back where the glazing plane reaches the
	# door's head, side cheeks closing the alcove, glazing above.
	var y_head := yf + DOOR_H
	var y_top_door := y_head + 0.18
	var zd := g - (y_top_door - ys) / tan_a
	zd = clampf(zd, 0.35, g)
	var door_parts: Array = []
	door_parts.append(_box(Vector3(dl, yf, zd - 0.12), Vector3(ex - DOOR_CLEAR_W * 0.5, y_top_door, zd), "trim"))
	door_parts.append(_box(Vector3(ex + DOOR_CLEAR_W * 0.5, yf, zd - 0.12), Vector3(dr, y_top_door, zd), "trim"))
	door_parts.append(_box(Vector3(dl, y_head, zd - 0.12), Vector3(dr, y_top_door, zd), "trim"))
	for cx in [dl, dr]:
		door_parts.append(_prism(PackedVector2Array([Vector2(zd, yf - FOOTING_M), Vector2(zf_out, yf - FOOTING_M),
			Vector2(zf_out, ys), Vector2(g, ys), Vector2(zd, y_top_door)]), float(cx) - 0.08, float(cx) + 0.08, "plaster"))
	if y_top_door < yt - 0.05:
		door_parts.append({"quad": [Vector3(dl, y_top_door, zd), Vector3(dr, y_top_door, zd),
			Vector3(dr, yt, zg), Vector3(dl, yt, zg)], "mat": "glass", "col": true})
	parts.append_array(door_parts)
	# Inner glazing (a second wall of glass between the greenhouse and the
	# rooms, Phoenix style), each room with a doorway.
	if bool(s["inner_glazing"]):
		for r in rooms:
			var ra := float(r["x0"])
			var rb := float(r["x1"])
			var mid := (ra + rb) * 0.5
			for seg2 in [[ra, mid - DOOR_CLEAR_W * 0.5], [mid + DOOR_CLEAR_W * 0.5, rb]]:
				var qa: float = seg2[0]
				var qb: float = seg2[1]
				parts.append({"quad": [Vector3(qa, yf, 0.1), Vector3(qb, yf, 0.1), Vector3(qb, yc, 0.1),
					Vector3(qa, yc, 0.1)], "mat": "glass", "col": true})
			parts.append(_box(Vector3(mid - DOOR_CLEAR_W * 0.5, y_head, 0.04), Vector3(mid + DOOR_CLEAR_W * 0.5, yc, 0.16), "trim"))
	# Numbers.
	var floor_area := float(n) * w * dep + (xi1 - xi0) * g
	var tyre_run := length + 2.0 * (dep + g) + float(n - 1) * dep
	var courses := ceili((h + FOOTING_M) / TYRE_COURSE_M)
	var tyres := ceili(tyre_run / TYRE_D_M) * courses
	var glazing_m2 := (xi1 - xi0) * sqrt(pow(g - zg, 2.0) + pow(yt - ys, 2.0))
	var roof_m2 := (length + 0.6) * (dep + t + 0.45) + length * absf(zg - 0.15)
	var stats := {
		"length_m": length, "depth_m": zf_out - z_back, "floor_area_m2": floor_area,
		"rooms": n, "sleeps": n * 2, "tyres": tyres, "courses": courses,
		"earth_t": float(tyres) * TYRE_EARTH_KG / 1000.0,
		"earth_m3": float(tyres) * TYRE_EARTH_M3,
		"glazing_m2": glazing_m2, "roof_m2": roof_m2,
		"cistern_l": float(int(s["cisterns"])) * float(s["cistern_l"]),
		"floor_y": yf, "ceiling_y": yc, "roof_y": roof_top,
	}
	var checks: Array = []
	if w > 6.0:
		checks.append({"level": "warn", "text": "Rooms over 6 m wide need heavier vigas or a centre beam."})
	if g < 1.8:
		checks.append({"level": "warn", "text": "A greenhouse under 1.8 m deep leaves little room past the planter."})
	if f > 2.0:
		checks.append({"level": "info", "text": "Sunk over 2 m: plan drainage round the floor (a french drain behind the berm)."})
	if yt < yc - 0.05:
		checks.append({"level": "info", "text": "At this angle the glazing stops below the ceiling line; the greenhouse roof slopes down to meet it."})
	if float(s["glazing_deg"]) < 45.0:
		checks.append({"level": "info", "text": "Glazing under 45° sheds dirt and snow poorly."})
	# What the terrain is asked for.
	var ew := {
		"sink_m": 0.0, "rect": [x0, z_back, x1, zf_out], "hole": true,
		"floor_y": yf, "roof_y": roof_top, "slab": false, "walls": false,
		"berm": {"-z": -1.0}, "berm_run": float(s["berm_run"]),
		"daylight": "+z", "cut_w": float(s["front_cut"]),
		"ramp_len": f * RAMP_GRADE if bool(s["ramp"]) and f > 0.1 else 0.0,
		"ramp_at": ex, "ramp_w": 1.8,
	}
	if bool(s["berm_ends"]):
		ew["berm"]["-x"] = -1.0
		ew["berm"]["+x"] = -1.0
	# Where people do things (prop frame, metres).
	var beds: Array = []
	for r2 in rooms:
		beds.append({"pos": Vector3((float(r2["x0"]) + float(r2["x1"])) * 0.5, yf + 0.5, -dep + 1.2),
			"yaw": 90.0, "kind": "lie"})
	return {"spec": s, "parts": parts, "rooms": rooms, "stats": stats, "checks": checks,
		"earthworks_simple": ew, "beds": beds, "entry_x": ex,
		"frame": {"x0": x0, "x1": x1, "z_back": z_back, "z_front": zf_out, "yf": yf, "yc": yc,
			"roof": roof_top, "zg": zg, "yt": yt, "ys": ys, "door_z": zd}}


## The earthworks spec for a design (the record's `earthworks`).
static func earthworks(spec_in: Variant) -> Dictionary:
	return StructureEarthworks.from_simple(solve(spec_in)["earthworks_simple"])
