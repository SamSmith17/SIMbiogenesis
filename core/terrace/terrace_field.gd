class_name TerraceField
extends RefCounted

## Terraced fields cut into a hillside (rice paddies, reed beds, dry steps).
## Pure static: the record, the stepped surface, the paddies it makes, and the
## water that cascades down them. TerraceRuntime draws it and writes the
## surface into the loader's terrace tile layer; ResourceFlowEngine steps the
## water and the crop on the clock.
##
## THE SURFACE. A terrace is the hillside cut into level steps that follow its
## contours. Each ground sample's height, smoothed over a few metres so the
## steps do not break up on every bump, is put in a band of one step height H:
## t = (smoothed − datum) / H, step m = round(t), d = t − m. Inside a band the
## floor is level at datum + m·H; near the band's edges (|d| > flat) a riser
## climbs to the next floor. The riser's width in plan is H × riser_run
## (horizontal metres per metre of rise), so in t it takes a share
## r = riser_run × slope of the band — wide floors on a gentle slope, narrow on
## a steep one, and the riser face keeps one steepness. Floors sit at the
## middle of their band, so the cut into the uphill side and the fill on the
## downhill side balance. The field fades back into the natural ground over
## `feather_m` inside its outline.
##
## THE PADDIES. Every connected run of one step inside the field (past the
## feather) is a paddy: its floor area, the area that drains into it (the
## floor plus half the risers round it) and the paddies below it, weighted by
## how much edge they share. Slivers too small to farm pass their water on.
##
## THE CASCADE. A paddy holds water up to its bund (flooded) or to the soil's
## plant-available water (dry). Water put in at the top paddies (the heads),
## and rain on each paddy's catchment, fills it; what is over its capacity
## spills to the paddies below by their shares; a paddy with none below spills
## out of the field. Evaporation and percolation take water out of each paddy.
## One pass top to bottom per step, mass-exact at any dt.

const CELL_M := 1.5
## Largest outline (m²): about a 500 m square. Bigger is a landscape, not a
## field, and costs a second or more per re-cut.
const MAX_AREA_M2 := 250000.0
const MIN_AREA_M2 := 120.0
## The ground is smoothed over this radius before it is banded into steps.
const SMOOTH_M := 6.0
## Smallest step that is a paddy (m² of level floor).
const MIN_PADDY_M2 := 8.0
const MAX_DELTA_M := 30.0
## `grid.m` outside the field's core (outside the outline or in its feather).
const NO_STEP := -999999
## The riser's share of a band, clamped.
const RISER_MIN := 0.06
const RISER_MAX := 0.92
## Plant-available water held in a dry step's root zone (m): about 80 mm in
## 0.6 m of loam (FAO-56, Table 19, TAW for loam ~ 0.13 m/m).
const DRY_AWC_M := 0.08
## A paddy counts as flooded above this depth (m).
const WET_DEPTH_M := 0.02
## The share of a crop's cycle the step stands bare before it is planted
## again (the crop shader's fallow).
const FALLOW := 0.04

## Crops a terrace can carry. `mesh` is the GardenCrops mesh drawn near by;
## `wet` = it wants standing water. Harvest index (`food`) and light-use
## efficiency (`lue`, g DM per MJ PAR) are textbook values: rice HI ~0.45,
## RUE ~2.2–2.8 g/MJ PAR (Mitchell et al. 1998; Sinclair & Muchow 1999);
## taro HI ~0.5 (corm); reeds (Phragmites) are cut whole (no food) and grow
## ~1–3 kg DM/m²/yr. `kc` = FAO-56 mid-season crop coefficient.
const CROPS := {
	"rice": {"label": "Rice", "mesh": "rice", "wet": true, "food": 0.45, "lue": 2.4,
		"cycle_d": 120.0, "height": 0.95, "kc": 1.2, "young": [0.36, 0.62, 0.2],
		"ripe": [0.82, 0.68, 0.26]},
	"reed": {"label": "Reed bed", "mesh": "reed", "wet": true, "food": 0.0, "lue": 2.6,
		"cycle_d": 365.0, "height": 2.5, "kc": 1.25, "young": [0.32, 0.5, 0.2],
		"ripe": [0.7, 0.6, 0.38]},
	"taro": {"label": "Taro", "mesh": "taro", "wet": true, "food": 0.5, "lue": 2.0,
		"cycle_d": 270.0, "height": 1.1, "kc": 1.1, "young": [0.24, 0.46, 0.2],
		"ripe": [0.4, 0.5, 0.24]},
	"potato": {"label": "Potato", "mesh": "potato", "wet": false, "food": 0.75, "lue": 2.2,
		"cycle_d": 110.0, "height": 0.55, "kc": 1.15, "young": [0.28, 0.5, 0.2],
		"ripe": [0.5, 0.5, 0.26]},
	"sweet_potato": {"label": "Sweet potato", "mesh": "sweet_potato", "wet": false, "food": 0.6,
		"lue": 2.0, "cycle_d": 140.0, "height": 0.3, "kc": 1.15, "young": [0.3, 0.5, 0.22],
		"ripe": [0.42, 0.46, 0.22]},
	"sorghum": {"label": "Sorghum", "mesh": "sorghum", "wet": false, "food": 0.4, "lue": 2.8,
		"cycle_d": 110.0, "height": 2.3, "kc": 1.05, "young": [0.32, 0.52, 0.2],
		"ripe": [0.64, 0.44, 0.24]},
	"beans": {"label": "Beans", "mesh": "beans", "wet": false, "food": 0.4, "lue": 1.8,
		"cycle_d": 90.0, "height": 1.95, "kc": 1.1, "young": [0.3, 0.52, 0.22],
		"ripe": [0.46, 0.5, 0.26]},
	"willow": {"label": "Willow coppice", "mesh": "willow", "wet": false, "food": 0.0, "lue": 2.4,
		"cycle_d": 1095.0, "height": 3.4, "kc": 1.0, "young": [0.36, 0.5, 0.28],
		"ripe": [0.4, 0.5, 0.3]},
	"fallow": {"label": "Fallow", "mesh": "", "wet": false, "food": 0.0, "lue": 0.0,
		"cycle_d": 365.0, "height": 0.0, "kc": 0.5, "young": [0.4, 0.36, 0.26],
		"ripe": [0.4, 0.36, 0.26]},
}
const CROP_ORDER := ["rice", "reed", "taro", "potato", "sweet_potato", "sorghum", "beans",
	"willow", "fallow"]

const INFLOW_MODES := ["off", "keep", "pump"]
const INFLOW_LABELS := {"off": "Gate shut", "keep": "Keep it full", "pump": "Pump steadily"}


## A record with every key filled in (missing keys take the defaults).
static func defaults() -> Dictionary:
	return {
		"id": "", "name": "Terraces", "poly": [],
		"step_h": 1.2,          ## m, the rise from one floor to the next
		"riser_run": 0.6,       ## m across per m of rise (1 : 0.6, ~59°)
		"feather_m": 4.0,       ## fade to natural ground inside the outline
		"datum": NAN,           ## m; NAN = the lowest ground in the field
		"flooded": true,        ## standing water held by bunds
		"bund_h": 0.15,         ## m of water a flooded step holds
		"crop": "rice",
		"plant_abs_h": -1.0,    ## when the crop was sown (-1 = not yet)
		"inflow_mode": "keep",
		"inflow_lph": 4000.0,   ## the most the intake takes (L/h)
		"perc_mm_d": 2.0,       ## percolation through a puddled floor (mm/day)
		"seed": 1,
		## Per-step overrides: {"<step m>": {"crop": id, "flooded": bool}}.
		"steps": {},
		## Who does the farm work: "people" (the camp's crews, on the chore
		## board), "machines" (small machines with an operator, on fuel) or
		## "free" (done the moment it is due: a sandbox).
		"labour": "people",
		## How the steps are cut: "hand" (a crew with shovels and baskets),
		## "skid_steer" or "tractor" (TerraceDig.MACHINES: the machine, its
		## operator and a helper) or "instant".
		"build_mode": "instant",
		## Built share per step {"<m>": 0..1}; a step not in it is not built
		## when build_mode is not "instant".
		"built": {},
	}


static func resolve(rec: Dictionary) -> Dictionary:
	var out := defaults()
	for k in rec.keys():
		out[k] = rec[k]
	out["step_h"] = clampf(float(out["step_h"]), 0.3, 5.0)
	out["riser_run"] = clampf(float(out["riser_run"]), 0.2, 3.0)
	out["feather_m"] = clampf(float(out["feather_m"]), 0.0, 20.0)
	out["bund_h"] = clampf(float(out["bund_h"]), 0.03, 0.4)
	out["inflow_lph"] = clampf(float(out["inflow_lph"]), 0.0, 200000.0)
	out["perc_mm_d"] = clampf(float(out["perc_mm_d"]), 0.0, 30.0)
	if not CROPS.has(str(out["crop"])):
		out["crop"] = "fallow"
	if not INFLOW_MODES.has(str(out["inflow_mode"])):
		out["inflow_mode"] = "keep"
	if not LABOUR_MODES.has(str(out["labour"])):
		out["labour"] = "people"
	if str(out["build_mode"]) == "machine":
		out["build_mode"] = "skid_steer"   # the first machine build mode
	if not BUILD_MODES.has(str(out["build_mode"])):
		out["build_mode"] = "instant"
	if not (out["steps"] is Dictionary):
		out["steps"] = {}
	if not (out["built"] is Dictionary):
		out["built"] = {}
	return out


const LABOUR_MODES := ["people", "machines", "free"]
const LABOUR_LABELS := {"people": "By hand (the camp's crews)",
	"machines": "Tractor for the heavy work, people plant and weed", "free": "Done for free (sandbox)"}
const BUILD_MODES := ["hand", "skid_steer", "tractor", "instant"]
const BUILD_LABELS := {"hand": "Dug by hand", "skid_steer": "Skid steer",
	"tractor": "Tractor with front loader", "instant": "Instantly"}


## Does a field (a node's specs) burn diesel: farmed with the tractor, or its
## steps still being cut by a machine?
static func wants_fuel(specs: Dictionary) -> bool:
	return str(specs.get("labour", "")) == "machines" \
		or ["skid_steer", "tractor", "machine"].has(str(specs.get("build_mode", "")))


## One step's crop and water: the step's own override, else the field's.
static func step_setting(rec: Dictionary, m: int) -> Dictionary:
	var r := resolve(rec)
	var crop := str(r["crop"])
	var flooded := bool(r["flooded"])
	var o: Variant = (r["steps"] as Dictionary).get(str(m), null)
	if o is Dictionary:
		var od := o as Dictionary
		if CROPS.has(str(od.get("crop", ""))):
			crop = str(od["crop"])
		if od.has("flooded"):
			flooded = bool(od["flooded"])
	return {"crop": crop, "flooded": flooded}


## Does any step of a field (a node's specs, with its paddy table) make
## food? Then its harvest port takes food and the straw / reeds go to
## the residue port.
static func makes_food(specs: Dictionary) -> bool:
	var table: Array = specs.get("terrace_table", []) as Array
	for row in table:
		if (row as Array).size() > 6 and float(crop_info(str(row[6]))["food"]) > 0.0:
			return true
	if table.is_empty() or (table[0] as Array).size() <= 6:
		return float(crop_info(str(specs.get("crop", "fallow")))["food"]) > 0.0
	return false


## Is step m built (all of it), for a record?
static func step_built(rec: Dictionary, m: int) -> float:
	var r := resolve(rec)
	if str(r["build_mode"]) == "instant":
		return 1.0
	return clampf(float((r["built"] as Dictionary).get(str(m), 0.0)), 0.0, 1.0)


static func crop_info(id: String) -> Dictionary:
	return CROPS.get(id, CROPS["fallow"]) as Dictionary


static func crop_label(id: String) -> String:
	return str(crop_info(id)["label"])


## The outline as world XZ points.
static func poly_of(rec: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in rec.get("poly", []):
		if p is Array and (p as Array).size() >= 2:
			out.append(Vector2(float(p[0]), float(p[1])))
		elif p is Vector2:
			out.append(p)
	return out


static func poly_to_array(poly: PackedVector2Array) -> Array:
	var out: Array = []
	for p in poly:
		out.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01)])
	return out


static func poly_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5


static func poly_rect(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	return r


## Why an outline cannot be a terrace field ("" = it can).
static func outline_problem(poly: PackedVector2Array) -> String:
	if poly.size() < 3:
		return "Draw an outline round the slope"
	var a := poly_area(poly)
	if a < MIN_AREA_M2:
		return "Too small for terraces — draw at least %d m²" % int(MIN_AREA_M2)
	if a > MAX_AREA_M2:
		return "Too big — keep a terrace field under %d ha" % int(MAX_AREA_M2 / 10000.0)
	return ""


## A step height that makes steps about `width_m` wide on this outline's
## slope (the median over a 4 m sample grid): H = slope × width, 0.5–3.5 m.
## Steep ground gets tall steps, gentle ground low ones, as hand-built
## terraces do.
static func auto_step_h(poly: PackedVector2Array, ground_fn: Callable, width_m: float = 7.0) -> float:
	var bb := poly_rect(poly)
	var slopes: Array = []
	var e := 4.0
	var x := bb.position.x + 2.0
	while x < bb.end.x:
		var z := bb.position.y + 2.0
		while z < bb.end.y:
			if Geometry2D.is_point_in_polygon(Vector2(x, z), poly):
				var gx := float(ground_fn.call(x + e, z)) - float(ground_fn.call(x - e, z))
				var gz := float(ground_fn.call(x, z + e)) - float(ground_fn.call(x, z - e))
				slopes.append(Vector2(gx, gz).length() / (2.0 * e))
			z += 4.0
		x += 4.0
	if slopes.is_empty():
		return 1.2
	slopes.sort()
	var med := float(slopes[slopes.size() / 2])
	return clampf(snappedf(med * width_m, 0.1), 0.5, 3.5)


## The record keys that change the cut (anything else is crop, water or name).
const GEOMETRY_KEYS := ["poly", "step_h", "riser_run", "feather_m", "datum"]


static func geometry_key(rec: Dictionary) -> String:
	var r := resolve(rec)
	var parts := PackedStringArray()
	for k in GEOMETRY_KEYS:
		var v: Variant = r[k]
		if v is float and is_nan(float(v)):
			parts.append("nan")
		else:
			parts.append(JSON.stringify(v))
	return "|".join(parts)


# ---------------------------------------------------------------------------
# The stepped surface
# ---------------------------------------------------------------------------

## Solve a field over the ground `ground_fn(x, z)` (the ground WITHOUT any
## terrace on it). Returns {} for an outline that is not usable, else:
##   grid    {i0, j0, cols, rows, cell, m (step per sample, NO_STEP outside
##            the core), d, flat, w, target, label (paddy index or -1)}
##   deltas  {Vector2i(global sample): metres} for the terrace tile layer
##   paddies [{m, floor_y, area, catch, cx, cz, down: [i], dw: [w], cap_flood,
##            cap_dry}] highest first; `down` always points further down the list
##   heads   paddies nothing above spills into
##   datum, stats {floor_m2, field_m2, steps, cut_m3, fill_m3}
static func solve(rec: Dictionary, ground_fn: Callable, cell: float = CELL_M) -> Dictionary:
	var r := resolve(rec)
	var poly := poly_of(r)
	if not outline_problem(poly).is_empty():
		return {}
	var bb := poly_rect(poly)
	var pad := SMOOTH_M * 2.0 + cell * 2.0
	var i0 := floori((bb.position.x - pad) / cell)
	var j0 := floori((bb.position.y - pad) / cell)
	var i1 := ceili((bb.end.x + pad) / cell)
	var j1 := ceili((bb.end.y + pad) / cell)
	var cols := i1 - i0 + 1
	var rows := j1 - j0 + 1
	var n := cols * rows
	var g := PackedFloat32Array()
	g.resize(n)
	for cj in rows:
		var z := float(j0 + cj) * cell
		for ci in cols:
			g[cj * cols + ci] = float(ground_fn.call(float(i0 + ci) * cell, z))
	var inside := scan_inside(poly, i0, j0, cols, rows, cell)
	var dist := chamfer_distance(inside, cols, rows)
	var s := blur(g, cols, rows, maxi(1, roundi(SMOOTH_M / cell * 0.5)))
	s = blur(s, cols, rows, maxi(1, roundi(SMOOTH_M / cell * 0.5)))
	var datum := float(r["datum"])
	if is_nan(datum):
		datum = INF
		for k in n:
			if inside[k] == 1:
				datum = minf(datum, s[k])
		if datum == INF:
			return {}
		datum = snappedf(datum, 0.01)
	var hh := float(r["step_h"])
	var run := float(r["riser_run"])
	var feather := float(r["feather_m"])
	var m_arr := PackedInt32Array()
	m_arr.resize(n)
	m_arr.fill(NO_STEP)
	var d_arr := PackedFloat32Array()
	d_arr.resize(n)
	var f_arr := PackedFloat32Array()
	f_arr.resize(n)
	var w_arr := PackedFloat32Array()
	w_arr.resize(n)
	var t_arr := g.duplicate()
	# The slope sets each riser's width; taken per sample it is noisy enough
	# to saw the step edges, so it is smoothed over ~6 m first.
	var slope_a := PackedFloat32Array()
	slope_a.resize(n)
	for cj in rows:
		for ci in cols:
			var k := cj * cols + ci
			var sx0 := s[k - 1] if ci > 0 else s[k]
			var sx1 := s[k + 1] if ci < cols - 1 else s[k]
			var sz0 := s[k - cols] if cj > 0 else s[k]
			var sz1 := s[k + cols] if cj < rows - 1 else s[k]
			slope_a[k] = Vector2((sx1 - sx0) / (2.0 * cell), (sz1 - sz0) / (2.0 * cell)).length()
	slope_a = blur(slope_a, cols, rows, maxi(1, roundi(3.0 / cell)))
	slope_a = blur(slope_a, cols, rows, maxi(1, roundi(3.0 / cell)))
	var band := PackedInt32Array()
	band.resize(n)
	band.fill(NO_STEP)
	var deltas := {}
	var delta_m := {}
	var cut := 0.0
	var fill := 0.0
	var a_cell := cell * cell
	for cj in rows:
		for ci in cols:
			var k := cj * cols + ci
			if inside[k] == 0:
				continue
			var slope := slope_a[k]
			var tt := (s[k] - datum) / hh
			var m := roundi(tt)
			var d := tt - float(m)
			var rr := clampf(run * slope, RISER_MIN, RISER_MAX)
			var flat := 0.5 - rr * 0.5
			var tv := stepped_t(m, d, flat)
			var hp := datum + hh * tv
			var dm := float(dist[k]) * cell
			var w := smoothstep(0.0, maxf(feather, 0.001), dm) if feather > 0.0 else 1.0
			var tgt := lerpf(g[k], hp, w)
			t_arr[k] = tgt
			d_arr[k] = d
			f_arr[k] = flat
			w_arr[k] = w
			band[k] = m
			if w >= 0.999:
				m_arr[k] = m
			var dl := clampf(tgt - g[k], -MAX_DELTA_M, MAX_DELTA_M)
			if absf(dl) > 1e-3:
				deltas[Vector2i(i0 + ci, j0 + cj)] = dl
				delta_m[Vector2i(i0 + ci, j0 + cj)] = m
				if dl < 0.0:
					cut -= dl * a_cell
				else:
					fill += dl * a_cell
	var pz := _paddies(m_arr, d_arr, f_arr, cols, rows, i0, j0, cell, datum, hh)
	var floor_m2 := 0.0
	var steps := {}
	for p in pz["paddies"]:
		floor_m2 += float(p["area"])
		steps[int(p["m"])] = true
	return {
		"grid": {"i0": i0, "j0": j0, "cols": cols, "rows": rows, "cell": cell,
			"m": m_arr, "d": d_arr, "flat": f_arr, "w": w_arr, "target": t_arr,
			"label": pz["label"], "band": band},
		"deltas": deltas, "delta_m": delta_m, "paddies": pz["paddies"], "heads": pz["heads"],
		"datum": datum, "step_h": hh,
		"stats": {"floor_m2": floor_m2, "field_m2": poly_area(poly), "steps": steps.size(),
			"paddies": (pz["paddies"] as Array).size(), "cut_m3": cut, "fill_m3": fill},
	}


## The stepped height in band units: level floor m inside ±flat, a straight
## riser to the half-way height at the band's edge (where the next band's
## riser carries on to its floor, so the surface is continuous).
static func stepped_t(m: int, d: float, flat: float) -> float:
	var ad := absf(d)
	if ad <= flat:
		return float(m)
	var u := clampf((ad - flat) / maxf(0.5 - flat, 1e-4), 0.0, 1.0)
	return float(m) + signf(d) * 0.5 * u


## 1 for samples inside the outline (scanline crossings).
static func scan_inside(poly: PackedVector2Array, i0: int, j0: int, cols: int, rows: int,
		cell: float) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(cols * rows)
	var nv := poly.size()
	for cj in rows:
		var z := float(j0 + cj) * cell
		var xs := PackedFloat32Array()
		for e in nv:
			var a := poly[e]
			var b := poly[(e + 1) % nv]
			if (a.y <= z and b.y > z) or (b.y <= z and a.y > z):
				xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x))
		if xs.size() < 2:
			continue
		xs.sort()
		var q := 0
		while q + 1 < xs.size():
			var c0 := maxi(0, ceili(xs[q] / cell) - i0)
			var c1 := mini(cols - 1, floori(xs[q + 1] / cell) - i0)
			for ci in range(c0, c1 + 1):
				out[cj * cols + ci] = 1
			q += 2
	return out


## Distance (in cells) from each inside sample to the nearest outside one:
## the 3-4 chamfer, two passes (Borgefors 1986), divided by 3.
static func chamfer_distance(inside: PackedByteArray, cols: int, rows: int) -> PackedFloat32Array:
	var big := 1.0e6
	var dd := PackedFloat32Array()
	dd.resize(cols * rows)
	for k in dd.size():
		dd[k] = big if inside[k] == 1 else 0.0
	for cj in rows:
		for ci in cols:
			var k := cj * cols + ci
			if dd[k] == 0.0:
				continue
			var v := dd[k]
			if ci > 0:
				v = minf(v, dd[k - 1] + 3.0)
			if cj > 0:
				v = minf(v, dd[k - cols] + 3.0)
				if ci > 0:
					v = minf(v, dd[k - cols - 1] + 4.0)
				if ci < cols - 1:
					v = minf(v, dd[k - cols + 1] + 4.0)
			if ci == 0 or cj == 0 or ci == cols - 1 or cj == rows - 1:
				v = minf(v, 3.0)
			dd[k] = v
	for cj in range(rows - 1, -1, -1):
		for ci in range(cols - 1, -1, -1):
			var k := cj * cols + ci
			if dd[k] == 0.0:
				continue
			var v := dd[k]
			if ci < cols - 1:
				v = minf(v, dd[k + 1] + 3.0)
			if cj < rows - 1:
				v = minf(v, dd[k + cols] + 3.0)
				if ci < cols - 1:
					v = minf(v, dd[k + cols + 1] + 4.0)
				if ci > 0:
					v = minf(v, dd[k + cols - 1] + 4.0)
			dd[k] = v
	for k in dd.size():
		dd[k] = dd[k] / 3.0
	return dd


## Box blur of radius r cells (separable; edges clamp).
static func blur(src: PackedFloat32Array, cols: int, rows: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(src.size())
	var out := PackedFloat32Array()
	out.resize(src.size())
	var span := float(2 * r + 1)
	for cj in rows:
		var base := cj * cols
		var acc := 0.0
		for q in range(-r, r + 1):
			acc += src[base + clampi(q, 0, cols - 1)]
		for ci in cols:
			tmp[base + ci] = acc / span
			acc += src[base + clampi(ci + r + 1, 0, cols - 1)] - src[base + clampi(ci - r, 0, cols - 1)]
	for ci in cols:
		var acc2 := 0.0
		for q in range(-r, r + 1):
			acc2 += tmp[clampi(q, 0, rows - 1) * cols + ci]
		for cj in rows:
			out[cj * cols + ci] = acc2 / span
			acc2 += tmp[clampi(cj + r + 1, 0, rows - 1) * cols + ci] - tmp[clampi(cj - r, 0, rows - 1) * cols + ci]
	return out


# ---------------------------------------------------------------------------
# Paddies
# ---------------------------------------------------------------------------

static func _paddies(m_arr: PackedInt32Array, d_arr: PackedFloat32Array, f_arr: PackedFloat32Array,
		cols: int, rows: int, i0: int, j0: int, cell: float, datum: float, hh: float) -> Dictionary:
	var n := cols * rows
	var comp := PackedInt32Array()
	comp.resize(n)
	comp.fill(-1)
	var comps: Array = []          ## {m, owner, floor, sx, sz}
	var stack := PackedInt32Array()
	for k0 in n:
		if comp[k0] >= 0 or m_arr[k0] == NO_STEP:
			continue
		var cid := comps.size()
		var mm := m_arr[k0]
		var info := {"m": mm, "owner": 0, "floor": 0, "sx": 0.0, "sz": 0.0}
		comp[k0] = cid
		stack.resize(0)
		stack.append(k0)
		while not stack.is_empty():
			var k := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			info["owner"] = int(info["owner"]) + 1
			if absf(d_arr[k]) <= f_arr[k]:
				info["floor"] = int(info["floor"]) + 1
				info["sx"] = float(info["sx"]) + float(i0 + k % cols) * cell
				info["sz"] = float(info["sz"]) + float(j0 + k / cols) * cell
			var ci := k % cols
			var cj := k / cols
			for nb in [[ci - 1, cj], [ci + 1, cj], [ci, cj - 1], [ci, cj + 1]]:
				var x: int = nb[0]
				var y: int = nb[1]
				if x < 0 or y < 0 or x >= cols or y >= rows:
					continue
				var kk := y * cols + x
				if comp[kk] < 0 and m_arr[kk] == mm:
					comp[kk] = cid
					stack.append(kk)
		comps.append(info)
	# Shared edges between components on different steps.
	var edges := {}                 ## "hi|lo" -> count (hi is the higher step)
	for cj in rows:
		for ci in cols:
			var k := cj * cols + ci
			var a := comp[k]
			if a < 0:
				continue
			for nb in [[ci + 1, cj], [ci, cj + 1]]:
				var x: int = nb[0]
				var y: int = nb[1]
				if x >= cols or y >= rows:
					continue
				var b := comp[y * cols + x]
				if b < 0 or b == a:
					continue
				var ma := int(comps[a]["m"])
				var mb := int(comps[b]["m"])
				if ma == mb:
					continue
				var key := ("%d|%d" % [a, b]) if ma > mb else ("%d|%d" % [b, a])
				edges[key] = int(edges.get(key, 0)) + 1
	var downs := {}                 ## comp -> {comp: weight}
	for key in edges.keys():
		var pr := str(key).split("|")
		var hi := int(pr[0])
		var lo := int(pr[1])
		if not downs.has(hi):
			downs[hi] = {}
		(downs[hi] as Dictionary)[lo] = float(edges[key])
	var a_cell := cell * cell
	var keep := {}
	for c in comps.size():
		if float(comps[c]["floor"]) * a_cell >= MIN_PADDY_M2:
			keep[c] = true
	# Order: highest step first (ties by component index, stable).
	var kept: Array = keep.keys()
	kept.sort_custom(func(x: int, y: int) -> bool:
		var mx := int(comps[x]["m"])
		var my := int(comps[y]["m"])
		return mx > my if mx != my else x < y)
	var index := {}
	for i in kept.size():
		index[kept[i]] = i
	var paddies: Array = []
	var has_up := {}
	for i in kept.size():
		var c: int = kept[i]
		var info: Dictionary = comps[c]
		var res := _resolve_downs(c, downs, keep, comps, 0)
		var dn := PackedInt32Array()
		var dw := PackedFloat32Array()
		var tot := 0.0
		for t in res.keys():
			tot += float(res[t])
		for t in res.keys():
			if not index.has(t):
				continue
			dn.append(int(index[t]))
			dw.append(float(res[t]) / maxf(tot, 1e-9))
			has_up[int(index[t])] = true
		var fl := int(info["floor"])
		paddies.append({
			"m": int(info["m"]), "floor_y": datum + float(info["m"]) * hh,
			"area": float(fl) * a_cell, "catch": float(int(info["owner"])) * a_cell,
			"cx": float(info["sx"]) / float(maxi(fl, 1)), "cz": float(info["sz"]) / float(maxi(fl, 1)),
			"down": dn, "dw": dw, "comp": c,
		})
	var heads := PackedInt32Array()
	for i in paddies.size():
		if not has_up.has(i):
			heads.append(i)
	var label := PackedInt32Array()
	label.resize(n)
	label.fill(-1)
	for k in n:
		var c2 := comp[k]
		if c2 >= 0 and index.has(c2):
			label[k] = int(index[c2])
	return {"paddies": paddies, "heads": heads, "label": label}


## A sliver's downstream, looked through to the paddies it spills on to.
static func _resolve_downs(c: int, downs: Dictionary, keep: Dictionary, comps: Array, depth: int) -> Dictionary:
	var out := {}
	if not downs.has(c) or depth > 24:
		return out
	var dd: Dictionary = downs[c]
	var tot := 0.0
	for t in dd.keys():
		tot += float(dd[t])
	for t in dd.keys():
		var share := float(dd[t]) / maxf(tot, 1e-9)
		if keep.has(t):
			out[t] = float(out.get(t, 0.0)) + share
		else:
			var sub := _resolve_downs(int(t), downs, keep, comps, depth + 1)
			for u in sub.keys():
				out[u] = float(out.get(u, 0.0)) + share * float(sub[u])
	return out


# ---------------------------------------------------------------------------
# Picking a hill
# ---------------------------------------------------------------------------

## "Terrace this hill from here up": the ground connected to `at` that stands
## higher than it (less a little), within `max_r`, as an outline round its
## middle (one radius per 4° — hills are close to star-shaped about their
## top). Empty when there is too little of it.
static func hill_outline(ground_fn: Callable, at: Vector2, max_r: float, cell: float = 2.0) -> PackedVector2Array:
	var nr := ceili(max_r / cell)
	var cols := nr * 2 + 1
	var hg := PackedFloat32Array()
	hg.resize(cols * cols)
	for cj in cols:
		for ci in cols:
			hg[cj * cols + ci] = float(ground_fn.call(at.x + float(ci - nr) * cell, at.y + float(cj - nr) * cell))
	var base := hg[nr * cols + nr] - 0.3
	var seen := PackedByteArray()
	seen.resize(cols * cols)
	var stack := PackedInt32Array([nr * cols + nr])
	seen[nr * cols + nr] = 1
	var pts: Array = []
	while not stack.is_empty():
		var k := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		var ci := k % cols
		var cj := k / cols
		pts.append(Vector2(float(ci - nr) * cell, float(cj - nr) * cell))
		for nb in [[ci - 1, cj], [ci + 1, cj], [ci, cj - 1], [ci, cj + 1]]:
			var x: int = nb[0]
			var y: int = nb[1]
			if x < 0 or y < 0 or x >= cols or y >= cols:
				continue
			var kk := y * cols + x
			if seen[kk] == 1:
				continue
			if Vector2(float(x - nr), float(y - nr)).length() * cell > max_r:
				continue
			if hg[kk] < base:
				continue
			seen[kk] = 1
			stack.append(kk)
	if float(pts.size()) * cell * cell < MIN_AREA_M2:
		return PackedVector2Array()
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= float(pts.size())
	const BINS := 90
	var radii := PackedFloat32Array()
	radii.resize(BINS)
	for p in pts:
		var v: Vector2 = p - c
		var b := int(floor(fposmod(v.angle(), TAU) / TAU * BINS)) % BINS
		radii[b] = maxf(radii[b], v.length() + cell * 0.5)
	# Fill empty bins from their neighbours, then smooth a little.
	for _pass in 3:
		for b in BINS:
			if radii[b] <= 0.0:
				radii[b] = maxf(radii[(b + BINS - 1) % BINS], radii[(b + 1) % BINS])
	var sm := PackedFloat32Array()
	sm.resize(BINS)
	for b in BINS:
		sm[b] = (radii[(b + BINS - 1) % BINS] + radii[b] * 2.0 + radii[(b + 1) % BINS]) * 0.25
	var out := PackedVector2Array()
	for b in BINS:
		var ang := (float(b) + 0.5) / BINS * TAU
		if sm[b] <= cell:
			continue
		out.append(at + c + Vector2(cos(ang), sin(ang)) * sm[b])
	return out


# ---------------------------------------------------------------------------
# Water
# ---------------------------------------------------------------------------

## Reference evapotranspiration (mm/day) from the air temperature: Blaney &
## Criddle (1950), ET0 = p (0.46 T + 8.13) with p = 0.27 (the mean daily share
## of annual daytime hours at mid latitudes; FAO-24). Coarse, never below
## 0.5 mm/day.
static func et0_mm_day(temp_c: float) -> float:
	return maxf(0.5, 0.27 * (0.46 * temp_c + 8.13))


## Water lost from a paddy per hour (mm/h): its crop's ET (open water ×1.05
## while bare, a dry floor ×0.5) plus percolation on a flooded floor.
static func loss_mm_h(rec: Dictionary, temp_c: float, crop_present: bool) -> float:
	var r := resolve(rec)
	var flooded := bool(r["flooded"])
	var kc := float(crop_info(str(r["crop"]))["kc"]) if crop_present else (1.05 if flooded else 0.5)
	var et := et0_mm_day(temp_c) * kc
	var perc := float(r["perc_mm_d"]) if flooded else 0.0
	return (et + perc) / 24.0


## A paddy's capacity (L) for a record: water to the bund when flooded, the
## root zone's plant-available water when dry.
static func capacity_l(area_m2: float, rec: Dictionary, m: int = NO_STEP) -> float:
	var r := resolve(rec)
	var flooded := bool(r["flooded"]) if m == NO_STEP else bool(step_setting(rec, m)["flooded"])
	var depth := float(r["bund_h"]) if flooded else DRY_AWC_M
	return area_m2 * depth * 1000.0


## Water lost from one paddy per hour (mm/h) for its own crop and water.
static func paddy_loss_mm_h(rec: Dictionary, crop: String, flooded: bool, temp_c: float,
		crop_present: bool) -> float:
	var kc := float(crop_info(crop)["kc"]) if crop_present else (1.05 if flooded else 0.5)
	var perc := float(resolve(rec)["perc_mm_d"]) if flooded else 0.0
	return (et0_mm_day(temp_c) * kc + perc) / 24.0


## The compact paddy table a graph node carries: [[area, catch, cap, [down],
## [weights]], …] highest first.
static func paddy_table(solved: Dictionary, rec: Dictionary) -> Array:
	var out: Array = []
	for p in solved.get("paddies", []):
		var pd: Dictionary = p
		var dn: Array = []
		for v in (pd["down"] as PackedInt32Array):
			dn.append(int(v))
		var dw: Array = []
		for v in (pd["dw"] as PackedFloat32Array):
			dw.append(snappedf(float(v), 0.001))
		var m := int(pd.get("m", NO_STEP))
		var ss := step_setting(rec, m)
		var cap := capacity_l(float(pd["area"]), rec, m) if step_built(rec, m) >= 0.999 else 0.0
		out.append([snappedf(float(pd["area"]), 0.1), snappedf(float(pd["catch"]), 0.1),
			snappedf(cap, 1.0), dn, dw, m, str(ss["crop"]), bool(ss["flooded"])])
	return out


## The water one step does to the paddies. `table` as paddy_table, `store`
## (L per paddy). Inflow goes to the `heads` by area. Returns {store, spill
## (L/h per paddy), outflow_lph, lost_l (evaporated + percolated), rain_l,
## in_l}. Mass: Σstore' = Σstore + in + rain − lost − outflow·dt.
static func cascade_step(table: Array, store: PackedFloat64Array, heads: Array,
		inflow_lph: float, rain_mmh: float, loss_mmh: Variant, dt_h: float) -> Dictionary:
	var n := table.size()
	var add := PackedFloat64Array()
	add.resize(n)
	var spill := PackedFloat32Array()
	spill.resize(n)
	var st := store.duplicate()
	if st.size() != n:
		st.resize(n)
	var head_area := 0.0
	for h in heads:
		if int(h) < n:
			head_area += float(table[int(h)][0])
	var in_l := maxf(inflow_lph, 0.0) * dt_h
	if head_area > 0.0:
		for h in heads:
			var hi := int(h)
			if hi < n:
				add[hi] += in_l * float(table[hi][0]) / head_area
	else:
		in_l = 0.0
	var out_l := 0.0
	var lost := 0.0
	var rain_l := 0.0
	for i in n:
		var row: Array = table[i]
		var area := float(row[0])
		var rain := maxf(rain_mmh, 0.0) * float(row[1]) * dt_h
		rain_l += rain
		var s := st[i] + add[i] + rain
		var want_loss := maxf(_loss_of(loss_mmh, i), 0.0) * area * dt_h
		var take := minf(want_loss, s)
		lost += take
		s -= take
		var cap := float(row[2])
		var over := maxf(s - cap, 0.0)
		s -= over
		st[i] = s
		spill[i] = over / maxf(dt_h, 1e-9)
		var dn: Array = row[3]
		var dw: Array = row[4]
		if dn.is_empty():
			out_l += over
		else:
			for q in dn.size():
				var t := int(dn[q])
				if t > i and t < n:
					add[t] += over * float(dw[q])
				else:
					out_l += over * float(dw[q])
	return {"store": st, "spill": spill, "outflow_lph": out_l / maxf(dt_h, 1e-9),
		"lost_l": lost, "rain_l": rain_l, "in_l": in_l}


## What the intake takes this step (L/h): shut = 0, pump = the set rate, keep
## = what tops every paddy up and covers this step's losses (less the rain),
## never more than the set rate.
static func intake_lph(rec: Dictionary, table: Array, store: PackedFloat64Array,
		rain_mmh: float, loss_mmh: Variant, dt_h: float) -> float:
	var r := resolve(rec)
	var mode := str(r["inflow_mode"])
	var cap_rate := float(r["inflow_lph"])
	if mode == "off":
		return 0.0
	if mode == "pump":
		return cap_rate
	var need := 0.0
	for i in table.size():
		var row: Array = table[i]
		var s := store[i] if i < store.size() else 0.0
		need += maxf(float(row[2]) - s, 0.0)
		if float(row[2]) <= 0.0:
			continue
		need += (maxf(_loss_of(loss_mmh, i), 0.0) * float(row[0]) - maxf(rain_mmh, 0.0) * float(row[1])) * dt_h
	return clampf(need / maxf(dt_h, 1e-6), 0.0, cap_rate)


## A loss given as one rate for every paddy or as a list per paddy.
static func _loss_of(loss: Variant, i: int) -> float:
	if loss is PackedFloat64Array:
		return float((loss as PackedFloat64Array)[i]) if i < (loss as PackedFloat64Array).size() else 0.0
	if loss is PackedFloat32Array:
		return float((loss as PackedFloat32Array)[i]) if i < (loss as PackedFloat32Array).size() else 0.0
	if loss is Array:
		return float((loss as Array)[i]) if i < (loss as Array).size() else 0.0
	return float(loss)


## How well one paddy's crop is watered (0..1) for a paddy-table row and the
## water in it.
static func paddy_water_factor(row: Array, s: float) -> float:
	var area := float(row[0])
	var cap := maxf(float(row[2]), 1e-6)
	var crop := str(row[6]) if row.size() > 6 else "fallow"
	var flooded := bool(row[7]) if row.size() > 7 else true
	var wet_crop := bool(crop_info(crop)["wet"])
	if flooded:
		var depth := s / maxf(area * 1000.0, 1e-6)
		var wet := clampf(depth / WET_DEPTH_M, 0.0, 1.0)
		return (wet + (1.0 - wet) * 0.35) if wet_crop else lerpf(0.9, 0.4, wet)
	var f := clampf(s / cap / 0.5, 0.0, 1.0)
	return f * 0.6 if wet_crop else f


## How well the crop is watered (0..1), area-weighted over the paddies.
static func water_factor(rec: Dictionary, table: Array, store: PackedFloat64Array) -> float:
	var r := resolve(rec)
	var wet_crop := bool(crop_info(str(r["crop"]))["wet"])
	var flooded := bool(r["flooded"])
	var tot := 0.0
	var acc := 0.0
	for i in table.size():
		var row: Array = table[i]
		var area := float(row[0])
		var cap := maxf(float(row[2]), 1e-6)
		var s := store[i] if i < store.size() else 0.0
		var f := 0.0
		if flooded:
			var depth := s / maxf(area * 1000.0, 1e-6)
			var wet := clampf(depth / WET_DEPTH_M, 0.0, 1.0)
			# A paddy crop stands a short dry spell; a dry crop drowns.
			f = (wet + (1.0 - wet) * 0.35) if wet_crop else lerpf(0.9, 0.4, wet)
		else:
			f = clampf(s / cap / 0.5, 0.0, 1.0)
			if wet_crop:
				f *= 0.6
		acc += f * area
		tot += area
	return acc / tot if tot > 0.0 else 0.0


## The crop's cycle at abs hour h: {planted, cycle (index), f (0..1 through
## it)}. Not planted before plant_abs_h (or when there is none).
static func crop_phase(rec: Dictionary, abs_h: float) -> Dictionary:
	var r := resolve(rec)
	var p := float(r["plant_abs_h"])
	var cyc := float(crop_info(str(r["crop"]))["cycle_d"]) * 24.0
	if p < 0.0 or abs_h < p or str(r["crop"]) == "fallow":
		return {"planted": false, "cycle": -1, "f": 0.0}
	var age := abs_h - p
	return {"planted": true, "cycle": int(floor(age / cyc)), "f": fposmod(age / cyc, 1.0)}
