class_name EarthshipDesign
extends RefCounted

## A solved Earthship (pure): every part in the spec's frame (x along the
## row, +z the glazing side, y = 0 at grade), the earthworks the terrain is
## asked for, the numbers and the checks. Cached by EarthshipSpec.key_of.
## EarthshipBuilder draws `parts`; the prop record's `earthworks` is
## `earthworks_simple` through StructureEarthworks.
##
## Part shapes (every part may carry "col" (collides, default true) and
## "roof" (left out of a roof-off cutaway)):
##   {"box": [Vector3 lo, Vector3 hi], "mat": m}
##   {"prism": PackedVector2Array of (z, y), "x": [xa, xb], "mat": m}
##   {"quad": [Vector3 a, b, c, d], "mat": "glass"}
##   {"cyl": [Vector3 a, Vector3 b], "r": radius, "sides": n, "mat": m}
##   {"obox": Transform3D (basis columns = half extents' axes), "size": Vector3, "mat": m}
##   {"sweep": [Vector3 (x, top y, z) along the wall's middle], "t": thickness,
##    "yb": bottom y, "mat": m}: a curved wall whose top follows the path
##   {"panel": [PackedVector2Array outline (u, v)...], "o", "u", "v", "w": Vector3,
##    "t": thickness along w, "cell": grid size, "grid_o": Vector2,
##    "holes": {Vector2i cell: Color}, "r": hole radius, "mat": m}: a wall
##    with bottles through it (a hole per listed cell, the bottle's glass in it)
## Materials: plaster, floor, roof, ceiling, wood, viga, trim, soil, glass,
## concrete, cistern, pv, pvframe, grass, door.
##
## Sources and measures:
##  - Reynolds, "Earthship Vol. 1" (1990): U-module ~4.9 m wide inside, rammed
##    tyre walls ~0.75 m, 2.4-2.7 m inside, sunk 0.6-1.2 m; vigas from the
##    back wall's bond beam to a front beam over the room's opening.
##  - The player's detail model (Imported Models/Earthship/earthship_detail.glb,
##    measured with glb_dump_diag): vigas ~0.30 m logs 6.4 m long running
##    front to back, 0.585 m apart along the row; bottle ends ~9 cm across
##    (3.5"); tyres 0.72 m; PV modules 1.99 x 1.02 m tilted ~29° on the roof.

const CACHE_MAX := 24
const KNEE_T := 0.3              ## front kneewall thickness (m)
const DOOR_W := 1.2              ## the entry bay (m)
const DOOR_CLEAR_W := 0.9        ## the opening in it (m)
const DOOR_H := 2.15             ## door top above the corridor floor (m)
const SLAB_T := 0.15
const FOOTING_M := 0.3           ## walls start this far under the floor
const RAMP_GRADE := 3.5          ## run per metre of drop for the entry ramp
const HEADER_D := 0.22           ## the front beam under the vigas (m)
const POST_W := 0.14             ## glazing posts (m)
const FRONT_T := 0.12            ## a wood or glass room front (m)
const BOTTLE_WALL_T := 0.32      ## a bottle wall: two bottle ends taped (m)
const BOTTLE_CELL := 0.19        ## a bottle and the mortar round it (m)
const BOTTLE_R := 0.045          ## bottle end radius (9 cm across)
const BOTTLE_EDGE := 0.14        ## no bottle this close to a wall's edge (m)
const VEST_W := 2.8              ## a vestibule, outside (m)
const VEST_D := 1.7
const VEST_WALL := 0.35
const VEST_H := 2.9              ## its roof above the floor (m)
const VEST_DOOR_W := 1.3
const WING_R := 2.9              ## a curved wing wall's radius (m)
const WING_TURN := 1.05          ## and how far it turns (rad)
const WING_T := 0.36
const PV_W := 1.02               ## a module across the row (m)
const PV_L := 1.99               ## up the slope (m)
const PV_GAP := 0.03
const CISTERN_H := 2.4           ## a buried cistern's height (m)
## A rammed tyre: ~0.75 m across, ~0.28 m a course, ~136 kg (300 lb) of
## earth (Reynolds, Earthship Vol. 1), ~0.085 m³ at 1600 kg/m³.
const TYRE_D_M := 0.75
const TYRE_COURSE_M := 0.28
const TYRE_EARTH_KG := 136.0
const TYRE_EARTH_M3 := 0.085

## Bottle glass (sRGB as seen): the detail model's bottles are deep sky
## blue, spring green, blue, yellow, red and gold; beer amber and clear
## are what most bottle walls are made of.
const BOTTLE_PALETTES := {
	"mixed": [Color(0.15, 0.55, 0.95), Color(0.2, 0.75, 0.4), Color(0.82, 0.48, 0.1),
		Color(0.08, 0.2, 0.8), Color(0.85, 0.92, 0.88), Color(0.95, 0.8, 0.15), Color(0.35, 0.8, 0.85)],
	"blue_green": [Color(0.12, 0.45, 0.95), Color(0.05, 0.2, 0.75), Color(0.15, 0.7, 0.4),
		Color(0.3, 0.8, 0.8), Color(0.05, 0.5, 0.3)],
	"amber": [Color(0.85, 0.5, 0.08), Color(0.55, 0.3, 0.06), Color(0.95, 0.72, 0.18),
		Color(0.7, 0.4, 0.1), Color(0.88, 0.9, 0.8)],
	"rainbow": [Color(0.85, 0.12, 0.1), Color(0.95, 0.5, 0.08), Color(0.95, 0.85, 0.12),
		Color(0.15, 0.72, 0.3), Color(0.1, 0.4, 0.95), Color(0.5, 0.2, 0.8)],
}

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


## PV tilt for the year's best output: about the latitude.
static func pv_tilt_for_lat(lat_deg: float) -> float:
	return clampf(absf(lat_deg), 10.0, 65.0)


static func _box(lo: Vector3, hi: Vector3, mat: String, col: bool = true) -> Dictionary:
	return {"box": [Vector3(minf(lo.x, hi.x), minf(lo.y, hi.y), minf(lo.z, hi.z)),
		Vector3(maxf(lo.x, hi.x), maxf(lo.y, hi.y), maxf(lo.z, hi.z))], "mat": mat, "col": col}


static func _prism(profile: PackedVector2Array, xa: float, xb: float, mat: String, col: bool = true) -> Dictionary:
	return {"prism": profile, "x": [minf(xa, xb), maxf(xa, xb)], "mat": mat, "col": col}


static func _cyl(a: Vector3, b: Vector3, r: float, mat: String, col: bool = false, sides: int = 10) -> Dictionary:
	return {"cyl": [a, b], "r": r, "sides": sides, "mat": mat, "col": col}


## A box of `size` centred at `c`, its z along `along` (x across, y the
## remaining axis).
static func _obox_along(c: Vector3, along: Vector3, up_hint: Vector3, size: Vector3, mat: String,
		col: bool = false) -> Dictionary:
	var z := along.normalized()
	var x := up_hint.cross(z).normalized()
	if x.length_squared() < 0.5:
		x = Vector3.RIGHT
	var y := z.cross(x).normalized()
	return {"obox": Transform3D(Basis(x, y, z), c), "size": size, "mat": mat, "col": col}


static func _roofed(p: Dictionary) -> Dictionary:
	p["roof"] = true
	return p


## An arched opening (u along the wall, v up) from `v0` to `v_top`, `w` wide.
static func arch_poly(cu: float, w: float, v0: float, v_top: float, segs: int = 8) -> PackedVector2Array:
	var r := w * 0.5
	var spring := maxf(v0 + 0.2, v_top - r)
	var pts := PackedVector2Array([Vector2(cu - r, v0), Vector2(cu + r, v0), Vector2(cu + r, spring)])
	for k in range(1, segs):
		var a := PI * float(k) / float(segs)
		pts.append(Vector2(cu + r * cos(a), spring + r * sin(a)))
	pts.append(Vector2(cu - r, spring))
	return pts


## A small deterministic hash in 0..1.
static func _h(i: int, j: int, seed: int) -> float:
	return fposmod(sin(float(i) * 12.9898 + float(j) * 78.233 + float(seed) * 37.719) * 43758.5453, 1.0)


static func _poly_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var u := p[i]
		var v := p[(i + 1) % p.size()]
		a += u.x * v.y - v.x * u.y
	return absf(a) * 0.5


## Which grid cells of a wall get a bottle, and its colour. A cell must lie
## wholly inside the outline (grown by BOTTLE_EDGE) and between `v_lo` and
## `v_hi`. Pure: the builder trusts the list.
static func bottle_holes(outlines: Array, grid_o: Vector2, cell: float, v_lo: float, v_hi: float,
		s: Dictionary, seed: int) -> Dictionary:
	var out := {}
	var dens := float(s["bottle_density"])
	if dens <= 0.001 or outlines.is_empty():
		return out
	var pal: Array = BOTTLE_PALETTES.get(str(s["bottle_colors"]), BOTTLE_PALETTES["mixed"])
	var pattern := str(s["bottle_pattern"])
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for o in outlines:
		for p in (o as PackedVector2Array):
			lo = lo.min(p)
			hi = hi.max(p)
	var i0 := floori((lo.x - grid_o.x) / cell)
	var i1 := ceili((hi.x - grid_o.x) / cell)
	var j0 := floori((maxf(lo.y, v_lo) - grid_o.y) / cell)
	var j1 := ceili((minf(hi.y, v_hi) - grid_o.y) / cell)
	var mid_u := (lo.x + hi.x) * 0.5
	var arch_c := Vector2(mid_u, v_lo)
	var arch_r := minf((hi.x - lo.x) * 0.42, (v_hi - v_lo) * 0.85)
	var rainbow: Array = BOTTLE_PALETTES["rainbow"]
	for j in range(j0, j1):
		for i in range(i0, i1):
			var r0 := Vector2(grid_o.x + float(i) * cell, grid_o.y + float(j) * cell)
			var c := r0 + Vector2(cell, cell) * 0.5
			if c.y < v_lo or c.y > v_hi:
				continue
			var hh := _h(i, j, seed)
			var col: Color = pal[int(_h(j, i, seed + 7) * 997.0) % pal.size()]
			var take := false
			match pattern:
				"bands":
					var band := posmod(j, 5)
					take = (band == 1 or band == 2) and (posmod(i + j, 2) == 0 or hh < dens)
					if take and str(s["bottle_colors"]) == "rainbow":
						col = rainbow[posmod(floori(float(j) / 5.0), rainbow.size())]
				"arch":
					var dist := c.distance_to(arch_c)
					var ring := -1
					for k in 6:
						if absf(dist - (arch_r - float(k) * cell)) < cell * 0.5:
							ring = k
					if ring >= 0:
						take = hh < 0.55 + dens
						col = rainbow[ring % rainbow.size()] if str(s["bottle_colors"]) in ["rainbow", "mixed"] \
								else pal[ring % pal.size()]
					else:
						take = hh < dens * 0.25
				"clusters":
					# Flowers: a centre and a ring of petals round it, on a
					# coarse grid of possible centres.
					var ci := floori(float(i) / 5.0)
					var cj := floori(float(j) / 5.0)
					var on := _h(ci, cj, seed + 3) < dens * 1.6
					var ccell := Vector2i(ci * 5 + 2, cj * 5 + 2)
					var dd := Vector2(i - ccell.x, j - ccell.y).length()
					if on and dd <= 1.5:
						take = true
						col = Color(0.95, 0.8, 0.15) if dd < 0.5 else pal[(ci * 3 + cj) % pal.size()]
				_:
					take = hh < dens
			if not take:
				continue
			var rect := PackedVector2Array([r0 - Vector2.ONE * BOTTLE_EDGE, r0 + Vector2(cell + BOTTLE_EDGE, -BOTTLE_EDGE),
				r0 + Vector2(cell, cell) + Vector2.ONE * BOTTLE_EDGE, r0 + Vector2(-BOTTLE_EDGE, cell + BOTTLE_EDGE)])
			var inside := false
			var want := _poly_area(rect)
			for o2 in outlines:
				var clip := Geometry2D.intersect_polygons(o2 as PackedVector2Array, rect)
				if clip.size() == 1 and absf(_poly_area(clip[0]) - want) < want * 1e-3:
					inside = true
					break
			if inside:
				out[Vector2i(i, j)] = col
	return out


static func _solve(s: Dictionary) -> Dictionary:
	var n := int(s["modules"])
	var w := float(s["module_w"])
	var dep := float(s["module_d"])
	var t := float(s["wall_t"])
	var h := float(s["wall_h"])
	var f := float(s["floor_depth"])
	var g := float(s["corridor_d"])
	var vertical := str(s["glazing_style"]) == "vertical"
	var a := deg_to_rad(float(s["glazing_deg"]))
	var sill := float(s["sill_h"])
	var roof_t := float(s["roof_t"])
	var vd := float(s["viga_d"])
	var length := float(n) * w + float(n + 1) * t
	var x0 := -length * 0.5
	var x1 := -x0
	var yf := -f
	var yc := yf + h
	var roof_top := yc + roof_t
	var z_back := -dep - t
	var zf_out := g + KNEE_T
	var ys := yf + sill
	var y_hb := yc - vd - HEADER_D        # underside of the front beam
	var tan_a := tan(a) if a < deg_to_rad(89.9) else 1e6
	var zg := g
	var yt := yc - 0.1
	if not vertical:
		# The glazing rises from the sill at the front to the ceiling line; a
		# shallow angle on a short corridor runs out of room and stops lower.
		zg = g - (yc - ys) / tan_a
		yt = yc
		if zg < 0.3:
			zg = 0.3
			yt = ys + (g - 0.3) * tan_a
	else:
		tan_a = 1e6
	var entry := str(s["entry"])
	var ex := 0.0
	if entry == "left":
		ex = x0 + t + w * 0.5
	elif entry == "right":
		ex = x1 - t - w * 0.5
	var vest := str(s["entry_style"]) == "vestibule"
	var bottle_ends := bool(s["bottle_ends"])
	var end_t := BOTTLE_WALL_T if bottle_ends else t
	var xg0 := x0 + end_t
	var xg1 := x1 - end_t
	var bay_w := VEST_W if vest else DOOR_W
	var parts: Array = []
	var rooms: Array = []
	var bottles := 0
	var seed := hash(str(s["name"])) % 9973
	# The glazing plane: z at a height y inside the greenhouse.
	var z_glass := func(y: float) -> float:
		if vertical:
			return g
		return clampf(g - (y - ys) / tan_a, zg, g)

	# --- the shell ------------------------------------------------------
	parts.append(_box(Vector3(x0, yf - SLAB_T, z_back), Vector3(x1, yf, zf_out), "floor"))
	parts.append(_box(Vector3(x0, yf - FOOTING_M, z_back), Vector3(x1, yc, -dep), "plaster"))
	for i in n + 1:
		var xa := x0 + float(i) * (w + t)
		var xb := xa + t
		parts.append(_box(Vector3(xa, yf - FOOTING_M, -dep), Vector3(xb, yc, 0.0), "plaster"))
	# The greenhouse end walls: tyre or bottle, maybe with a door.
	var end_door := str(s["end_door"])
	var gh_floor_front := g - float(s["planter_w"])
	var door_room := gh_floor_front - 0.15
	var end_door_z := clampf(door_room * 0.5, 0.55, maxf(door_room - 0.5, 0.55))
	for side in [0, 1]:
		var prof := PackedVector2Array([Vector2(0.0, yf - FOOTING_M), Vector2(zf_out, yf - FOOTING_M),
			Vector2(zf_out, ys), Vector2(g, ys), Vector2(zg, yt), Vector2(0.0, yc)])
		var outlines: Array = [prof]
		var has_door: bool = (end_door == "both" or (end_door == "left" and side == 0) or (end_door == "right" and side == 1)) \
				and door_room >= 1.0
		var dpoly := PackedVector2Array()
		if has_door:
			dpoly = arch_poly(end_door_z, 0.9, yf - FOOTING_M - 0.2, yf + 2.05)
			outlines = Geometry2D.clip_polygons(prof, dpoly)
		var xa2 := x0 if side == 0 else x1 - end_t
		if bottle_ends:
			var holes := bottle_holes(outlines, Vector2(0.0, yf), BOTTLE_CELL, yf + 0.45, yc - 0.2, s, seed + side * 101)
			bottles += holes.size()
			parts.append({"panel": outlines, "o": Vector3(xa2, 0.0, 0.0), "u": Vector3(0, 0, 1),
				"v": Vector3(0, 1, 0), "w": Vector3(1, 0, 0), "t": end_t, "cell": BOTTLE_CELL,
				"grid_o": Vector2(0.0, yf), "holes": holes, "r": BOTTLE_R, "mat": "plaster", "col": true})
		else:
			for o in outlines:
				if (o as PackedVector2Array).size() >= 3:
					parts.append(_prism(o, xa2, xa2 + end_t, "plaster"))
		if has_door:
			# A closed plank door in an arched frame, set in the wall's middle.
			var leaf := arch_poly(end_door_z, 0.86, yf, yf + 2.03)
			parts.append(_prism(leaf, xa2 + end_t * 0.5 - 0.03, xa2 + end_t * 0.5 + 0.03, "door"))
	for i in n:
		var rx := x0 + t + float(i) * (w + t)
		rooms.append({"x0": rx, "x1": rx + w, "z0": -dep, "z1": 0.0})

	# --- vigas, front beams, ceiling, roof ------------------------------
	var vigas := 0
	var viga_m := 0.0
	for r in rooms:
		var rx0 := float(r["x0"])
		var rx1 := float(r["x1"])
		# The front beam over the room's opening, bearing on the U's arms.
		parts.append(_box(Vector3(rx0 - t * 0.45, y_hb, -0.24), Vector3(rx1 + t * 0.45, yc - vd, 0.08), "wood"))
		# Round vigas from the back wall's bond beam over the front beam,
		# their ends showing in the greenhouse.
		var nv := maxi(2, roundi(w / float(s["viga_spacing"])))
		for k in nv:
			var vx := rx0 + (float(k) + 0.5) * w / float(nv)
			var za := -dep - t * 0.6
			var zb := 0.32
			parts.append(_cyl(Vector3(vx, yc - vd * 0.5, za), Vector3(vx, yc - vd * 0.5, zb), vd * 0.5, "viga"))
			vigas += 1
			viga_m += zb - za
	var ceil_t := 0.03
	parts.append(_roofed(_box(Vector3(x0 + t * 0.5, yc, -dep - t * 0.5), Vector3(x1 - t * 0.5, yc + ceil_t, 0.15),
		"ceiling" if str(s["ceiling"]) == "boards" else "plaster", false)))
	parts.append(_roofed(_box(Vector3(x0 - 0.3, yc + ceil_t, z_back - 0.3), Vector3(x1 + 0.3, roof_top, 0.15), "roof")))
	# A plastered cap along the roof's front edge (the line the berm meets).
	parts.append(_roofed(_box(Vector3(x0 - 0.3, roof_top - 0.05, 0.0), Vector3(x1 + 0.3, roof_top + 0.18, 0.3), "plaster")))
	if bool(s["green_roof"]):
		parts.append(_roofed(_box(Vector3(x0 - 0.2, roof_top, z_back - 0.2), Vector3(x1 + 0.2, roof_top + 0.1, -0.05),
			"grass", false)))
	# The greenhouse roof: from the room roof down to the glazing top.
	var gr_lo := PackedVector2Array([Vector2(0.15, yc), Vector2(zg, yt)])
	var gr_back_top := yc + 0.24
	if vertical:
		# Upright windows under a roof that runs out past them.
		var front_top := yt + 0.32
		parts.append(_roofed(_prism(PackedVector2Array([Vector2(0.15, yc), Vector2(zf_out + 0.35, yt - 0.02),
			Vector2(zf_out + 0.35, front_top), Vector2(0.15, roof_top)]), x0, x1, "roof")))
		parts.append(_roofed(_prism(PackedVector2Array([Vector2(0.15, yc - ceil_t), Vector2(g, yt - ceil_t),
			Vector2(g, yt), Vector2(0.15, yc)]), xg0, xg1, "ceiling" if str(s["ceiling"]) == "boards" else "plaster", false)))
		parts.append(_roofed(_box(Vector3(x0, yt - 0.02, zf_out + 0.2), Vector3(x1, front_top, zf_out + 0.38), "trim", false)))
	else:
		parts.append(_roofed(_prism(PackedVector2Array([Vector2(0.15, yc), Vector2(zg, yt),
			Vector2(zg + 0.12, yt + 0.22), Vector2(0.15, gr_back_top)]), x0, x1, "roof")))
		parts.append(_roofed(_prism(PackedVector2Array([gr_lo[0] - Vector2(0, ceil_t), gr_lo[1] - Vector2(0, ceil_t),
			gr_lo[1], gr_lo[0]]), xg0, xg1, "ceiling" if str(s["ceiling"]) == "boards" else "plaster", false)))

	# --- kneewall, planters, glazing -------------------------------------
	var dl := ex - bay_w * 0.5
	var dr := ex + bay_w * 0.5
	var pw := float(s["planter_w"])
	var ph := float(s["planter_h"])
	var planters: Array = []
	var posts: Array = []
	var glazing_m2 := 0.0
	for seg in [[xg0, dl], [dr, xg1]]:
		var sa: float = seg[0]
		var sb: float = seg[1]
		if sb - sa < 0.05:
			continue
		parts.append(_box(Vector3(sa, yf - FOOTING_M, g), Vector3(sb, ys, zf_out), "plaster"))
		parts.append(_box(Vector3(sa, ys, g - 0.05), Vector3(sb, ys + 0.12, zf_out), "trim"))
		if pw > 0.05:
			var pa := sa
			var pb := sb
			if absf(sb - dl) < 0.01:
				pb = dl - 0.3
			if absf(sa - dr) < 0.01:
				pa = dr + 0.3
			if pb - pa > 0.3:
				parts.append(_box(Vector3(pa, yf, g - pw), Vector3(pb, yf + ph, g), "plaster"))
				parts.append(_box(Vector3(pa + 0.08, yf + ph - 0.02, g - pw + 0.08),
					Vector3(pb - 0.08, yf + ph + 0.01, g - 0.08), "soil", false))
				# Headroom under the glass at the bed's back and front edges.
				var yb := yf + ph + 0.01
				var z0p := g - pw + 0.12
				var z1p := g - 0.12
				var head0 := (yt if vertical else minf(yt, ys + (g - z0p) * tan_a)) - yb - 0.15
				var head1 := (yt if vertical else minf(yt, ys + (g - z1p) * tan_a)) - yb - 0.15
				planters.append({"x0": pa + 0.12, "x1": pb - 0.12, "z0": z0p, "z1": z1p,
					"y": yb, "head0": maxf(head0, 0.3), "head1": maxf(head1, 0.3)})
		# Glazing in bays about 1.2 m wide between wood posts.
		var bays := maxi(1, ceili((sb - sa) / 1.25))
		var y_g0 := ys + 0.12
		for bi in bays:
			var ba := sa + (sb - sa) * float(bi) / float(bays)
			var bb := sa + (sb - sa) * float(bi + 1) / float(bays)
			parts.append({"quad": [Vector3(ba, y_g0, g), Vector3(bb, y_g0, g),
				Vector3(bb, yt, zg), Vector3(ba, yt, zg)], "mat": "glass", "col": true})
			glazing_m2 += (bb - ba) * Vector2(g - zg, yt - y_g0).length()
			if bool(s["vents"]):
				# An awning window low in each bay: a rail across and its frame.
				var yv := y_g0 + minf(0.62, (yt - y_g0) * 0.35)
				var zv: float = z_glass.call(yv)
				parts.append(_obox_along(Vector3((ba + bb) * 0.5, yv, zv + 0.02), Vector3.RIGHT, Vector3.UP,
					Vector3(0.07, 0.07, bb - ba), "wood"))
			posts.append(bb)
			if bi == 0:
				posts.append(ba)
	# Posts and rafters at the bay lines.
	for px in posts:
		var pxf: float = px
		var lo := Vector3(pxf, ys + 0.12, g + 0.02)
		var hi := Vector3(pxf, yt, zg + 0.02)
		parts.append(_obox_along((lo + hi) * 0.5, hi - lo, Vector3.FORWARD, Vector3(POST_W, POST_W, (hi - lo).length()),
			"wood", true))
		var ra := Vector3(pxf, yc - ceil_t - 0.1, 0.1)
		var rb := Vector3(pxf, yt - ceil_t - 0.1, zg - 0.05)
		if vertical:
			rb = Vector3(pxf, yt - ceil_t - 0.1, g - 0.1)
		parts.append(_roofed(_obox_along((ra + rb) * 0.5, rb - ra, Vector3.UP, Vector3(0.08, 0.2, (rb - ra).length()),
			"wood")))
	# A beam along the glazing's head.
	parts.append(_box(Vector3(xg0, yt - 0.16, zg - 0.08), Vector3(xg1, yt, zg + 0.08), "wood", false))

	# --- the entry -------------------------------------------------------
	var y_head := yf + DOOR_H
	var y_top_door := y_head + 0.18
	var zd := 0.0
	var ramp_at := ex
	var cut_need := 0.0
	if vest:
		var vz1 := zf_out + VEST_D
		var y_vr := yf + VEST_H
		var zr: float = z_glass.call(minf(y_vr + 0.25, yt))
		var xl := ex - VEST_W * 0.5
		var xr := ex + VEST_W * 0.5
		for cx in [xl, xr - VEST_WALL]:
			var cxf: float = cx
			parts.append(_prism(PackedVector2Array([Vector2(g, yf - FOOTING_M), Vector2(vz1, yf - FOOTING_M),
				Vector2(vz1, y_vr), Vector2(zr, y_vr), Vector2(g, ys)]), cxf, cxf + VEST_WALL, "plaster"))
		var front := PackedVector2Array([Vector2(xl, yf - FOOTING_M), Vector2(xr, yf - FOOTING_M), Vector2(xr, y_vr),
			Vector2(xl, y_vr)])
		var opening := arch_poly(ex, VEST_DOOR_W, yf - FOOTING_M - 0.2, yf + 2.45)
		for o in Geometry2D.clip_polygons(front, opening):
			parts.append({"panel": [o], "o": Vector3(0.0, 0.0, vz1 - VEST_WALL), "u": Vector3(1, 0, 0),
				"v": Vector3(0, 1, 0), "w": Vector3(0, 0, 1), "t": VEST_WALL, "cell": BOTTLE_CELL,
				"grid_o": Vector2(0.0, yf), "holes": {}, "r": BOTTLE_R, "mat": "plaster", "col": true})
		# The doors stand open against the inside of the side walls.
		for sgn in [-1.0, 1.0]:
			var hinge := Vector3(ex + sgn * (VEST_DOOR_W * 0.5 - 0.03), yf + 1.05, vz1 - VEST_WALL - 0.03)
			parts.append(_obox_along(hinge + Vector3(0, 0, -0.32), Vector3.BACK, Vector3.UP, Vector3(0.05, 2.08, 0.62),
				"door", false))
		# A wood frame and a glazed fan light in the arch.
		parts.append({"quad": [Vector3(ex - VEST_DOOR_W * 0.5, yf + 2.1, vz1 - VEST_WALL * 0.5),
			Vector3(ex + VEST_DOOR_W * 0.5, yf + 2.1, vz1 - VEST_WALL * 0.5),
			Vector3(ex + VEST_DOOR_W * 0.5, yf + 2.42, vz1 - VEST_WALL * 0.5),
			Vector3(ex - VEST_DOOR_W * 0.5, yf + 2.42, vz1 - VEST_WALL * 0.5)], "mat": "glass", "col": false})
		parts.append(_box(Vector3(ex - VEST_DOOR_W * 0.5, yf + 2.06, vz1 - VEST_WALL - 0.02),
			Vector3(ex + VEST_DOOR_W * 0.5, yf + 2.14, vz1 + 0.02), "wood", false))
		# Its roof, a rounded plaster cap along the front.
		parts.append(_roofed(_box(Vector3(xl - 0.12, y_vr, zr - 0.1), Vector3(xr + 0.12, y_vr + 0.25, vz1 + 0.15), "roof")))
		parts.append(_roofed(_cyl(Vector3(xl - 0.12, y_vr + 0.25, vz1), Vector3(xr + 0.12, y_vr + 0.25, vz1), 0.14,
			"plaster", false, 8)))
		# Glazing over the vestibule up to the head.
		if y_vr + 0.25 < yt - 0.05:
			parts.append({"quad": [Vector3(dl, y_vr + 0.25, zr), Vector3(dr, y_vr + 0.25, zr),
				Vector3(dr, yt, zg), Vector3(dl, yt, zg)], "mat": "glass", "col": true})
		# Curved wing walls sweeping out along the front and down to the cut
		# floor (the Global Model's entry).
		for sgn2 in [-1.0, 1.0]:
			var pts: Array = []
			var xs: float = ex + sgn2 * (VEST_W * 0.5 - 0.18)
			var zs := vz1 - 0.15
			# An arc out along the front, turning forward toward the steps.
			for k in 13:
				var u := float(k) / 12.0
				var th := WING_TURN * u
				var px2: float = xs + sgn2 * WING_R * sin(th)
				var pz := zs + WING_R * (1.0 - cos(th))
				var top := lerpf(yf + VEST_H * 0.82, yf + 0.55, smoothstep(0.0, 1.0, u))
				pts.append(Vector3(px2, top, pz))
			parts.append({"sweep": pts, "t": WING_T, "yb": yf - FOOTING_M, "mat": "plaster", "col": true})
			# Rounded adobe: a half-round along the top and a round nose.
			for k2 in 12:
				parts.append(_cyl(pts[k2], pts[k2 + 1], WING_T * 0.5, "plaster", false, 8))
			var nose: Vector3 = pts[12]
			parts.append(_cyl(Vector3(nose.x, yf - FOOTING_M, nose.z), nose, WING_T * 0.5, "plaster", false, 12))
		# A flagstone landing at the door.
		parts.append(_box(Vector3(ex - 1.0, yf - 0.02, vz1), Vector3(ex + 1.0, yf + 0.06, vz1 + 1.1), "floor"))
		zd = vz1
		cut_need = VEST_D + WING_R * (1.0 - cos(WING_TURN)) + 0.8
	else:
		# The alcove: a doorway set back where the glazing plane reaches the
		# door's head, side cheeks closing the alcove, glazing above.
		zd = g - (y_top_door - ys) / tan_a if not vertical else g - 0.45
		zd = clampf(zd, 0.35, g)
		var dcw := DOOR_CLEAR_W
		parts.append(_box(Vector3(dl, yf, zd - 0.12), Vector3(ex - dcw * 0.5, y_top_door, zd), "trim"))
		parts.append(_box(Vector3(ex + dcw * 0.5, yf, zd - 0.12), Vector3(dr, y_top_door, zd), "trim"))
		parts.append(_box(Vector3(dl, y_head, zd - 0.12), Vector3(dr, y_top_door, zd), "trim"))
		for cx2 in [dl, dr]:
			var cxf2: float = cx2
			parts.append(_prism(PackedVector2Array([Vector2(zd, yf - FOOTING_M), Vector2(zf_out, yf - FOOTING_M),
				Vector2(zf_out, ys), Vector2(g, ys), Vector2(zd, y_top_door)]), cxf2 - 0.08, cxf2 + 0.08, "plaster"))
		if y_top_door < yt - 0.05:
			parts.append({"quad": [Vector3(dl, y_top_door, zd), Vector3(dr, y_top_door, zd),
				Vector3(dr, yt, zg), Vector3(dl, yt, zg)], "mat": "glass", "col": true})

	# --- room fronts -----------------------------------------------------
	var front := str(s["room_front"])
	var door_top := minf(yf + DOOR_H, y_hb - 0.04)
	for r2 in rooms:
		var ra := float(r2["x0"])
		var rb := float(r2["x1"])
		var mid := (ra + rb) * 0.5
		var dh := DOOR_CLEAR_W * 0.5
		match front:
			"glass":
				for sg in [[ra, mid - dh], [mid + dh, rb]]:
					var qa: float = sg[0]
					var qb: float = sg[1]
					parts.append({"quad": [Vector3(qa, yf, -0.06), Vector3(qb, yf, -0.06), Vector3(qb, y_hb, -0.06),
						Vector3(qa, y_hb, -0.06)], "mat": "glass", "col": true})
				parts.append(_box(Vector3(mid - dh, door_top, -0.12), Vector3(mid + dh, y_hb, 0.0), "trim"))
				for px3 in [mid - dh - 0.04, mid + dh + 0.04]:
					parts.append(_box(Vector3(float(px3) - 0.04, yf, -0.1), Vector3(float(px3) + 0.04, y_hb, -0.02), "trim"))
			"wood":
				var rail := yf + 0.9
				for sg2 in [[ra, mid - dh - 0.06], [mid + dh + 0.06, rb]]:
					var qa2: float = sg2[0]
					var qb2: float = sg2[1]
					if qb2 - qa2 < 0.1:
						continue
					parts.append(_box(Vector3(qa2, yf, -0.08), Vector3(qb2, rail, -0.04), "wood"))
					parts.append(_box(Vector3(qa2, rail - 0.04, -FRONT_T), Vector3(qb2, rail + 0.05, 0.0), "wood"))
					parts.append({"quad": [Vector3(qa2, rail + 0.05, -0.06), Vector3(qb2, rail + 0.05, -0.06),
						Vector3(qb2, y_hb, -0.06), Vector3(qa2, y_hb, -0.06)], "mat": "glass", "col": true})
					# Mullions in the upper glass.
					var nm := maxi(1, ceili((qb2 - qa2) / 0.9))
					for m in range(1, nm):
						var mx := qa2 + (qb2 - qa2) * float(m) / float(nm)
						parts.append(_box(Vector3(mx - 0.03, rail, -0.09), Vector3(mx + 0.03, y_hb, -0.03), "wood", false))
				for px4 in [ra + 0.06, mid - dh - 0.06, mid + dh + 0.06, rb - 0.06]:
					var pf: float = px4
					parts.append(_box(Vector3(pf - 0.06, yf, -FRONT_T), Vector3(pf + 0.06, y_hb, 0.0), "wood"))
				parts.append(_box(Vector3(mid - dh, door_top, -FRONT_T), Vector3(mid + dh, y_hb, 0.0), "wood"))
				# A glazed door standing open into the room.
				parts.append(_obox_along(Vector3(mid + dh - 0.03, yf + (door_top - yf) * 0.5, -0.06 - 0.42), Vector3.BACK,
					Vector3.UP, Vector3(0.05, door_top - yf - 0.04, 0.84), "door", false))
			"bottle":
				var outline := PackedVector2Array([Vector2(ra, yf - FOOTING_M), Vector2(rb, yf - FOOTING_M),
					Vector2(rb, y_hb), Vector2(ra, y_hb)])
				var dpoly2 := arch_poly(mid, DOOR_CLEAR_W, yf - FOOTING_M - 0.2, door_top)
				var outs := Geometry2D.clip_polygons(outline, dpoly2)
				var holes2 := bottle_holes(outs, Vector2(ra, yf), BOTTLE_CELL, yf + 0.4, y_hb - 0.12, s,
					seed + 31 + roundi(ra * 10.0))
				bottles += holes2.size()
				parts.append({"panel": outs, "o": Vector3(0.0, 0.0, -BOTTLE_WALL_T), "u": Vector3(1, 0, 0),
					"v": Vector3(0, 1, 0), "w": Vector3(0, 0, 1), "t": BOTTLE_WALL_T, "cell": BOTTLE_CELL,
					"grid_o": Vector2(ra, yf), "holes": holes2, "r": BOTTLE_R, "mat": "plaster", "col": true})

	# --- on the roof ------------------------------------------------------
	var pv_n := int(s["pv_panels"])
	var pv_rows := 0
	var pv_placed := 0
	if pv_n > 0:
		var tilt := deg_to_rad(float(s["pv_tilt"]))
		var per_row := maxi(1, floori((length - 0.6) / (PV_W + PV_GAP)))
		pv_rows = ceili(float(pv_n) / float(per_row))
		var run := PV_L * cos(tilt)
		var rise := PV_L * sin(tilt)
		var row_pitch := run + maxf(0.8, rise * 1.6)
		var nrm := Vector3(0.0, cos(tilt), sin(tilt))
		var up := Vector3(0.0, sin(tilt), -cos(tilt))
		var base_y := roof_top + (0.1 if bool(s["green_roof"]) else 0.0) + 0.2
		var left := pv_n
		for row in pv_rows:
			var k_row := mini(per_row, left)
			left -= k_row
			var z_low := -0.1 - float(row) * row_pitch
			if z_low - run < z_back - 0.2:
				break
			var span := float(k_row) * (PV_W + PV_GAP)
			for k2 in k_row:
				var cx3 := -span * 0.5 + (float(k2) + 0.5) * (PV_W + PV_GAP)
				var c := Vector3(cx3, base_y + rise * 0.5, z_low - run * 0.5)
				parts.append(_roofed({"obox": Transform3D(Basis(Vector3.RIGHT, nrm, -up), c),
					"size": Vector3(PV_W, 0.04, PV_L), "mat": "pv", "col": false}))
				pv_placed += 1
			# Two rails under the row on short legs to the roof.
			for rail_k in 2:
				var uu := 0.25 + 0.5 * float(rail_k)
				var p := Vector3(0.0, base_y + rise * uu - 0.04, z_low - run * uu)
				parts.append(_roofed(_box(p - Vector3(span * 0.5, 0.03, 0.03), p + Vector3(span * 0.5, 0.03, 0.03),
					"pvframe", false)))
				for leg_x in [-span * 0.5 + 0.2, span * 0.5 - 0.2]:
					parts.append(_roofed(_box(Vector3(float(leg_x) - 0.03, roof_top, p.z - 0.03),
						Vector3(float(leg_x) + 0.03, p.y, p.z + 0.03), "pvframe", false)))
	var skylights := 0
	if bool(s["skylights"]):
		var sz := -dep * 0.55 if pv_rows <= 1 else -dep + 0.85
		for r3 in rooms:
			var mx3 := (float(r3["x0"]) + float(r3["x1"])) * 0.5
			# Offset off the panels' middle line when a row sits over it.
			var y0 := roof_top + (0.1 if bool(s["green_roof"]) else 0.0)
			parts.append(_roofed(_box(Vector3(mx3 - 0.5, roof_top - 0.05, sz - 0.5), Vector3(mx3 + 0.5, y0 + 0.45, sz + 0.5),
				"plaster")))
			parts.append(_roofed({"quad": [Vector3(mx3 - 0.45, y0 + 0.46, sz + 0.45), Vector3(mx3 + 0.45, y0 + 0.46, sz + 0.45),
				Vector3(mx3 + 0.45, y0 + 0.66, sz - 0.45), Vector3(mx3 - 0.45, y0 + 0.66, sz - 0.45)], "mat": "glass",
				"col": false}))
			parts.append(_roofed(_prism(PackedVector2Array([Vector2(sz - 0.5, y0 + 0.45), Vector2(sz + 0.5, y0 + 0.45),
				Vector2(sz - 0.5, y0 + 0.68)]), mx3 - 0.5, mx3 - 0.44, "trim", false)))
			parts.append(_roofed(_prism(PackedVector2Array([Vector2(sz - 0.5, y0 + 0.45), Vector2(sz + 0.5, y0 + 0.45),
				Vector2(sz - 0.5, y0 + 0.68)]), mx3 + 0.44, mx3 + 0.5, "trim", false)))
			skylights += 1
	# Cisterns buried in the berm behind, their lids at the berm's crest.
	var nc := int(s["cisterns"])
	if nc > 0:
		var vol := float(s["cistern_l"]) / 1000.0
		var cr := sqrt(vol / (PI * CISTERN_H))
		var zc := z_back - 0.5 - cr
		for k3 in nc:
			var cx4 := x0 + length * (float(k3) + 0.5) / float(nc)
			parts.append(_cyl(Vector3(cx4, yf, zc), Vector3(cx4, yf + CISTERN_H, zc), cr, "cistern", false, 16))
			parts.append(_cyl(Vector3(cx4, yf + CISTERN_H, zc), Vector3(cx4, roof_top + 0.25, zc), 0.32, "concrete", false, 12))

	# --- numbers ---------------------------------------------------------
	var floor_area := float(n) * w * dep + (xg1 - xg0) * g
	var tyre_run := length + 2.0 * dep + float(n - 1) * dep + (0.0 if bottle_ends else 2.0 * g)
	var courses := ceili((h + FOOTING_M) / TYRE_COURSE_M)
	var tyres := ceili(tyre_run / TYRE_D_M) * courses
	var roof_m2 := (length + 0.6) * (dep + t + 0.45) + length * absf(zg - 0.15)
	var planter_m2 := 0.0
	for p2 in planters:
		planter_m2 += (float(p2["x1"]) - float(p2["x0"])) * (float(p2["z1"]) - float(p2["z0"]))
	var stats := {
		"length_m": length, "depth_m": zf_out - z_back + (VEST_D if vest else 0.0), "floor_area_m2": floor_area,
		"rooms": n, "sleeps": n * 2, "tyres": tyres, "courses": courses,
		"earth_t": float(tyres) * TYRE_EARTH_KG / 1000.0,
		"earth_m3": float(tyres) * TYRE_EARTH_M3,
		"glazing_m2": glazing_m2, "roof_m2": roof_m2,
		"cistern_l": float(nc) * float(s["cistern_l"]),
		"floor_y": yf, "ceiling_y": yc, "roof_y": roof_top,
		"bottles": bottles, "vigas": vigas, "viga_m": viga_m,
		"pv_panels": pv_placed, "pv_kw": float(pv_placed) * float(s["pv_watts"]) / 1000.0,
		"planter_m2": planter_m2, "skylights": skylights,
	}
	var checks: Array = []
	if dep > 6.0:
		checks.append({"level": "warn", "text": "Vigas spanning over 6 m (the room depth) need heavier logs or a mid beam."})
	if w > 6.0:
		checks.append({"level": "warn", "text": "A front beam over 6 m (the room width) needs a post or a bigger beam."})
	if g < 1.8:
		checks.append({"level": "warn", "text": "A greenhouse under 1.8 m deep leaves little room past the planter."})
	if f > 2.0:
		checks.append({"level": "info", "text": "Sunk over 2 m: plan drainage round the floor (a french drain behind the berm)."})
	if not vertical and yt < yc - 0.05:
		checks.append({"level": "info", "text": "At this angle the glazing stops below the ceiling line; the greenhouse roof slopes down to meet it."})
	if not vertical and float(s["glazing_deg"]) < 45.0:
		checks.append({"level": "info", "text": "Glazing under 45° sheds dirt and snow poorly."})
	if y_hb - yf < 2.0:
		checks.append({"level": "warn", "text": "Under 2 m to the front beams: raise the ceiling or use thinner vigas."})
	if pv_placed < pv_n:
		checks.append({"level": "warn", "text": "Only %d of %d panels fit on the roof." % [pv_placed, pv_n]})
	if end_door != "none" and door_room < 1.0:
		checks.append({"level": "warn", "text": "No room for an end door between the rooms and the planter."})
	var open_ends := bottle_ends or end_door != "none"
	if bool(s["berm_ends"]) and open_ends:
		checks.append({"level": "info", "text": "Bottle walls and end doors stay clear of the earth: the ends are not bermed."})
	if bottles > 0 and float(s["bottle_density"]) > 0.7:
		checks.append({"level": "info", "text": "Very dense bottle walls are weak: keep a mortar web between them."})
	# What the terrain is asked for.
	var ew := {
		"sink_m": 0.0, "rect": [x0, z_back, x1, zf_out], "hole": true,
		"floor_y": yf, "roof_y": roof_top, "slab": false, "walls": false,
		"berm": {"-z": -1.0}, "berm_run": float(s["berm_run"]),
		"daylight": "+z", "cut_w": maxf(float(s["front_cut"]), cut_need),
		"ramp_len": f * RAMP_GRADE if bool(s["ramp"]) and f > 0.1 else 0.0,
		"ramp_at": ramp_at, "ramp_w": 1.8,
	}
	if bool(s["berm_ends"]):
		if not (bottle_ends or end_door in ["left", "both"]):
			ew["berm"]["-x"] = -1.0
		if not (bottle_ends or end_door in ["right", "both"]):
			ew["berm"]["+x"] = -1.0
	# Where people do things (prop frame, metres).
	var beds: Array = []
	for r4 in rooms:
		beds.append({"pos": Vector3((float(r4["x0"]) + float(r4["x1"])) * 0.5, yf + 0.5, -dep + 1.2),
			"yaw": 90.0, "kind": "lie"})
	return {"spec": s, "parts": parts, "rooms": rooms, "stats": stats, "checks": checks,
		"earthworks_simple": ew, "beds": beds, "entry_x": ex, "planters": planters,
		"frame": {"x0": x0, "x1": x1, "z_back": z_back, "z_front": zf_out, "yf": yf, "yc": yc,
			"roof": roof_top, "zg": zg, "yt": yt, "ys": ys, "door_z": zd, "beam_y": y_hb,
			"xg0": xg0, "xg1": xg1}}


## The earthworks spec for a design (the record's `earthworks`).
static func earthworks(spec_in: Variant) -> Dictionary:
	return StructureEarthworks.from_simple(solve(spec_in)["earthworks_simple"])
