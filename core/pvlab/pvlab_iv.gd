class_name PvLabIV
extends RefCounted

## Current–voltage model of a module, a string and an array under uneven
## light, with bypass diodes. Pure; curves are cached.
##
## A CELL is the single-diode model without a shunt (the five-parameter
## model with Rsh → ∞; Villalva, Gazoli & Filho, IEEE Trans. Power Electron.
## 24(5) 2009), written as voltage against current, which is explicit:
##     v(I) = a · ln((Isc − I) / I0 + 1) − I · Rs
## a (the modified thermal voltage n·kT/q), Rs and I0 are fitted per cell to
## the module's Voc, Isc and maximum-power point (Vmp, Imp), with dP/dI = 0
## at Imp — so a uniformly lit module at STC delivers exactly its Wmp. Light
## scales Isc; Voc moves by a·ln(G/1000); temperature through the data
## sheet's Isc and Voc coefficients, a with absolute temperature.
##
## A PATH is n cells in series (v·n). A SUBSTRING is one or more paths in
## parallel (a half-cut module's top and bottom halves) behind one bypass
## diode: past the current its cells can carry the diode conducts and the
## substring sits at −BYPASS_DROP_V instead of driving its cells into reverse.
## A STRING is substrings in series (voltages add at one current); an ARRAY's
## strings are in parallel (currents add at one voltage). The maximum of
## I·V over that curve is what an MPPT finds — including the higher of two
## peaks when part of a string is shaded.
##
## Input irradiances are per PATH (W/m², plane of array), laid out as
## PvLabModule.substrings orders them.

const K_CELL := 56          # points on one cell curve
const N_SUB_V := 40         # voltage points when paralleling unequal paths
const N_STRING_I := 90      # current points along a string
const N_ARRAY_V := 120      # voltage points when paralleling strings
const BLOCK_V := -1.0e4     # a substring with no diode past its current
const G_DARK := 0.5         # W/m² below which a path makes nothing

static var _fit_cache := {}
static var _cell_cache := {}
static var _sub_cache := {}
const CACHE_MAX := 4000


## The electrical model of one module design (a PvLabModule spec):
## {cells: per-cell fit, subs: [{diode, paths: [n cells, ...]}], n_paths}
static func model_for(module_spec: Dictionary) -> Dictionary:
	var e := PvLabModule.electrical(module_spec)
	var subs: Array = []
	var n_paths := 0
	for sub in PvLabModule.substrings(module_spec):
		var paths: Array = []
		for _p in sub["paths"]:
			paths.append(int(sub["cells"]))
			n_paths += 1
		subs.append({"diode": bool(sub["diode"]), "paths": paths})
	return {"cell": fit_cell(e), "subs": subs, "n_paths": n_paths, "elec": e}


## Per-cell single-diode parameters from a module's STC nameplate.
static func fit_cell(e: Dictionary) -> Dictionary:
	var ns := maxf(float(e.get("series_cells", 60)), 1.0)
	var np := maxf(float(e.get("parallel_paths", 1)), 1.0)
	var key := "%.5f|%.5f|%.5f|%.5f|%d|%d|%.4f|%.4f" % [float(e["voc"]), float(e["isc"]), float(e["vmp"]),
		float(e["imp"]), int(ns), int(np), float(e.get("voc_coeff", -0.3)), float(e.get("isc_coeff", 0.05))]
	if _fit_cache.has(key):
		return _fit_cache[key]
	var voc := float(e["voc"]) / ns
	var isc := float(e["isc"]) / np
	var vmp := clampf(float(e["vmp"]) / ns, voc * 0.5, voc * 0.98)
	var imp := clampf(float(e["imp"]) / np, isc * 0.5, isc * 0.995)
	# g(a) = a/(Isc − Imp + I0) + Rs − Vmp/Imp, increasing in a.
	var lo := 0.004
	var hi := 0.25
	var a := 0.03
	for _it in 60:
		a = (lo + hi) * 0.5
		if _fit_g(a, voc, isc, vmp, imp) > 0.0:
			hi = a
		else:
			lo = a
	var i0 := isc / (exp(voc / a) - 1.0)
	var rs := (a * log((isc - imp) / i0 + 1.0) - vmp) / imp
	if rs < 0.0:
		# A fill factor the diode alone reaches: no series resistance, and a
		# chosen so the curve passes through (Vmp, Imp). v(Imp) ≈ Voc +
		# a·ln(1 − Imp/Isc) falls as a grows.
		rs = 0.0
		lo = 0.004
		hi = 0.25
		for _it in 60:
			a = (lo + hi) * 0.5
			var i0b := isc / (exp(voc / a) - 1.0)
			if a * log((isc - imp) / i0b + 1.0) > vmp:
				lo = a
			else:
				hi = a
	var out := {"a": a, "rs": rs, "voc": voc, "isc": isc, "vmp": vmp, "imp": imp,
		"beta": float(e.get("voc_coeff", -0.3)) / 100.0, "alpha": float(e.get("isc_coeff", 0.05)) / 100.0}
	_fit_cache[key] = out
	return out


static func _fit_g(a: float, voc: float, isc: float, vmp: float, imp: float) -> float:
	var i0 := isc / (exp(voc / a) - 1.0)
	var rs := (a * log((isc - imp) / i0 + 1.0) - vmp) / imp
	return a / (isc - imp + i0) + rs - vmp / imp


## One cell's curve at irradiance g and cell temperature t: {i: currents
## ascending 0 → Isc, v: voltages descending, isc, voc}.
static func cell_curve(cell: Dictionary, g: float, t_c: float) -> Dictionary:
	var gq := snappedf(maxf(g, 0.0), 2.0)
	var tq := snappedf(t_c, 0.5)
	var key := "%s|%s|%.5f|%.5f" % [gq, tq, float(cell["a"]), float(cell["isc"])]
	if _cell_cache.has(key):
		return _cell_cache[key]
	var dt := tq - 25.0
	var i_arr := PackedFloat64Array()
	var v_arr := PackedFloat64Array()
	i_arr.resize(K_CELL)
	v_arr.resize(K_CELL)
	var isc := float(cell["isc"]) * gq / 1000.0 * (1.0 + float(cell["alpha"]) * dt)
	var out := {}
	if gq < G_DARK or isc <= 1e-9:
		out = {"i": i_arr, "v": v_arr, "isc": 0.0, "voc": 0.0}
	else:
		var a_t := float(cell["a"]) * (tq + 273.15) / 298.15
		var voc := float(cell["voc"]) * (1.0 + float(cell["beta"]) * dt) + a_t * log(gq / 1000.0)
		voc = maxf(voc, 0.01)
		var i0 := isc / (exp(voc / a_t) - 1.0)
		var rs := float(cell["rs"])
		# Sampled by the DIODE voltage, evenly from 0 to Voc (explicit both
		# ways: I = Isc − I0·(e^(Vd/a) − 1), V = Vd − I·Rs), so the flat run
		# from short circuit to the knee is as well resolved as the knee.
		# Stored with the current ascending (index 0 = open circuit).
		for k in K_CELL:
			var vd := voc * float(k) / float(K_CELL - 1)
			var ii := maxf(isc - i0 * (exp(vd / a_t) - 1.0), 0.0)
			var j := K_CELL - 1 - k
			i_arr[j] = ii
			v_arr[j] = vd - ii * rs
		out = {"i": i_arr, "v": v_arr, "isc": isc, "voc": voc}
	if _cell_cache.size() > CACHE_MAX:
		_cell_cache.clear()
	_cell_cache[key] = out
	return out


## A cell's voltage at current `i` (lerp on its curve; past Isc it would go
## into reverse — callers handle that case).
static func _cell_v_at(c: Dictionary, i: float) -> float:
	var ia: PackedFloat64Array = c["i"]
	var va: PackedFloat64Array = c["v"]
	if float(c["isc"]) <= 0.0:
		return 0.0
	if i <= 0.0:
		return va[0]
	var lo := 0
	var hi := K_CELL - 1
	if i >= ia[hi]:
		return va[hi]
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if ia[mid] <= i:
			lo = mid
		else:
			hi = mid
	var f := (i - ia[lo]) / maxf(ia[hi] - ia[lo], 1e-12)
	return lerpf(va[lo], va[hi], f)


## A cell's current at voltage `v` (the same curve read the other way).
static func _cell_i_at(c: Dictionary, v: float) -> float:
	var ia: PackedFloat64Array = c["i"]
	var va: PackedFloat64Array = c["v"]
	if float(c["isc"]) <= 0.0:
		return 0.0
	if v >= va[0]:
		return 0.0
	if v <= va[K_CELL - 1]:
		return ia[K_CELL - 1]
	var lo := 0
	var hi := K_CELL - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if va[mid] >= v:
			lo = mid
		else:
			hi = mid
	var f := (va[lo] - v) / maxf(va[lo] - va[hi], 1e-12)
	return lerpf(ia[lo], ia[hi], f)


## One substring's curve: {i: ascending currents, v: their voltages, imax
## (the most it carries before its diode takes over), diode}. Paths of n
## cells each, in parallel, at their own irradiance.
static func substring_curve(model: Dictionary, sub_idx: int, path_g: Array, t_c: float) -> Dictionary:
	var sub: Dictionary = (model["subs"] as Array)[sub_idx]
	var paths: Array = sub["paths"]
	var cell: Dictionary = model["cell"]
	var key := "%d|%s|%s|%s|%s" % [sub_idx, str(paths), str(_q_list(path_g)), snappedf(t_c, 0.5), float(cell["a"])]
	if _sub_cache.has(key):
		return _sub_cache[key]
	var curves: Array = []
	for pi in paths.size():
		curves.append(cell_curve(cell, float(path_g[pi]) if pi < path_g.size() else 0.0, t_c))
	var out := {}
	var ia := PackedFloat64Array()
	var va := PackedFloat64Array()
	if paths.size() == 1 or _all_equal(path_g, paths.size()):
		# Equal paths: the current splits evenly, the voltage is one path's.
		var c: Dictionary = curves[0]
		var n := float(paths[0])
		var np := float(paths.size())
		var ci: PackedFloat64Array = c["i"]
		var cv: PackedFloat64Array = c["v"]
		ia.resize(K_CELL)
		va.resize(K_CELL)
		for k in K_CELL:
			ia[k] = ci[k] * np
			va[k] = cv[k] * n
		out = {"i": ia, "v": va, "imax": float(c["isc"]) * np}
	else:
		# Unequal paths: sum their currents on a voltage grid.
		var vhi := 0.0
		var vlo := 0.0
		for pi in paths.size():
			var c2: Dictionary = curves[pi]
			vhi = maxf(vhi, float(c2["voc"]) * float(paths[pi]))
			if float(c2["isc"]) > 0.0:
				vlo = minf(vlo, ((c2["v"] as PackedFloat64Array)[K_CELL - 1]) * float(paths[pi]))
		ia.resize(N_SUB_V)
		va.resize(N_SUB_V)
		var imax := 0.0
		for pi in paths.size():
			imax += float((curves[pi] as Dictionary)["isc"])
		for j in N_SUB_V:
			# From the highest voltage (no current) down to the lowest.
			var t := float(j) / float(N_SUB_V - 1)
			var v := lerpf(vhi, vlo, 1.0 - (1.0 - t) * (1.0 - t))
			var isum := 0.0
			for pi in paths.size():
				isum += _cell_i_at(curves[pi], v / float(paths[pi]))
			ia[j] = isum
			va[j] = v
		out = {"i": ia, "v": va, "imax": imax}
	out["diode"] = bool(sub["diode"])
	if _sub_cache.size() > CACHE_MAX:
		_sub_cache.clear()
	_sub_cache[key] = out
	return out


static func _all_equal(g: Array, n: int) -> bool:
	if g.size() < n:
		return false
	var g0 := snappedf(float(g[0]), 2.0)
	for k in range(1, n):
		if snappedf(float(g[k]), 2.0) != g0:
			return false
	return true


static func _q_list(g: Array) -> Array:
	var out: Array = []
	for x in g:
		out.append(snappedf(float(x), 2.0))
	return out


## A substring's voltage at current i: its curve, or its diode's drop past
## the current it can carry (a substring with no diode blocks).
static func sub_v_at(sc: Dictionary, i: float) -> float:
	if i > float(sc["imax"]) + 1e-9:
		return -PvLabCells.BYPASS_DROP_V if bool(sc["diode"]) else BLOCK_V
	var ia: PackedFloat64Array = sc["i"]
	var va: PackedFloat64Array = sc["v"]
	var n := ia.size()
	if i <= ia[0]:
		return va[0]
	if i >= ia[n - 1]:
		var vend := va[n - 1]
		return maxf(vend, -PvLabCells.BYPASS_DROP_V) if bool(sc["diode"]) else vend
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if ia[mid] <= i:
			lo = mid
		else:
			hi = mid
	var f := (i - ia[lo]) / maxf(ia[hi] - ia[lo], 1e-12)
	var v := lerpf(va[lo], va[hi], f)
	return maxf(v, -PvLabCells.BYPASS_DROP_V) if bool(sc["diode"]) else v


## A string's curve: panels in series, each a list of per-path irradiances in
## the module's substring order. Returns {i: PackedFloat64Array ascending,
## v: voltages, imax, voc}. Identical substrings are summed once.
static func string_curve(model: Dictionary, panels: Array, t_c: float) -> Dictionary:
	# Group the string's substrings by curve.
	var groups := {}
	var subs: Array = model["subs"]
	for pg in panels:
		var flat: Array = pg
		var k := 0
		for si in subs.size():
			var np := (subs[si]["paths"] as Array).size()
			var g: Array = flat.slice(k, k + np)
			k += np
			var sc := substring_curve(model, si, g, t_c)
			var gk := "%d|%s" % [si, str(_q_list(g))]
			if groups.has(gk):
				groups[gk]["n"] = int(groups[gk]["n"]) + 1
			else:
				groups[gk] = {"c": sc, "n": 1}
	# Current grid: even, plus dense just under each group's limit (where a
	# string's maximum sits when part of it is shaded).
	var imax := 0.0
	for gk in groups:
		imax = maxf(imax, float((groups[gk]["c"] as Dictionary)["imax"]))
	var pts := PackedFloat64Array()
	for j in N_STRING_I:
		pts.append(imax * float(j) / float(N_STRING_I - 1))
	for gk in groups:
		var im := float((groups[gk]["c"] as Dictionary)["imax"])
		if im <= 0.0:
			continue
		for f in [0.86, 0.9, 0.93, 0.95, 0.97, 0.985, 0.995, 1.0]:
			pts.append(im * float(f))
	pts.sort()
	var ia := PackedFloat64Array()
	var va := PackedFloat64Array()
	var last := -1.0
	for x in pts:
		if x - last < 1e-9:
			continue
		last = x
		var v := 0.0
		for gk in groups:
			v += float(groups[gk]["n"]) * sub_v_at(groups[gk]["c"], x)
		ia.append(x)
		va.append(v)
	return {"i": ia, "v": va, "imax": imax, "voc": va[0] if va.size() > 0 else 0.0}


## The array's maximum power point: strings in parallel (each a list of
## panels, each panel a list of per-path irradiances). Returns {p, v, i,
## strings: [{p, v, i}], curve: {v, i}} — the curve only when `with_curve`.
static func array_mpp(model: Dictionary, strings: Array, t_c: float, with_curve: bool = false) -> Dictionary:
	if strings.is_empty():
		return {"p": 0.0, "v": 0.0, "i": 0.0, "strings": []}
	var curves: Array = []
	var dedupe := {}
	for st in strings:
		var key := str(_q_strings(st))
		if dedupe.has(key):
			curves.append(dedupe[key])
		else:
			var c := string_curve(model, st, t_c)
			dedupe[key] = c
			curves.append(c)
	if strings.size() == 1:
		var best := _string_mpp(curves[0])
		best["strings"] = [best.duplicate()]
		if with_curve:
			best["curve"] = {"v": (curves[0] as Dictionary)["v"], "i": (curves[0] as Dictionary)["i"]}
		return best
	var vmax := 0.0
	for c in curves:
		vmax = maxf(vmax, float(c["voc"]))
	var best_p := 0.0
	var best_v := 0.0
	var best_i := 0.0
	var cv := PackedFloat64Array()
	var ci := PackedFloat64Array()
	for j in N_ARRAY_V:
		var v := vmax * float(j) / float(N_ARRAY_V - 1)
		var itot := 0.0
		for c in curves:
			itot += _string_i_at(c, v)
		var p := v * itot
		if with_curve:
			cv.append(v)
			ci.append(itot)
		if p > best_p:
			best_p = p
			best_v = v
			best_i = itot
	# Refine round the best voltage.
	var step := vmax / float(N_ARRAY_V - 1)
	for r in 3:
		var lo := maxf(best_v - step, 0.0)
		var hi := minf(best_v + step, vmax)
		for j in 13:
			var v2 := lerpf(lo, hi, float(j) / 12.0)
			var it2 := 0.0
			for c in curves:
				it2 += _string_i_at(c, v2)
			if v2 * it2 > best_p:
				best_p = v2 * it2
				best_v = v2
				best_i = it2
		step /= 6.0
	var per: Array = []
	for c in curves:
		var si := _string_i_at(c, best_v)
		per.append({"p": si * best_v, "v": best_v, "i": si})
	var out := {"p": best_p, "v": best_v, "i": best_i, "strings": per}
	if with_curve:
		out["curve"] = {"v": cv, "i": ci}
	return out


static func _q_strings(st: Array) -> Array:
	var out: Array = []
	for pg in st:
		out.append(_q_list(pg))
	return out


static func _string_mpp(c: Dictionary) -> Dictionary:
	var ia: PackedFloat64Array = c["i"]
	var va: PackedFloat64Array = c["v"]
	var best := {"p": 0.0, "v": 0.0, "i": 0.0}
	for k in ia.size():
		var p := ia[k] * va[k]
		if p > float(best["p"]):
			best = {"p": p, "v": va[k], "i": ia[k]}
	return best


## A string's current at voltage v (its curve read backwards; above its Voc
## nothing flows — a blocking diode or the MPPT never goes there).
static func _string_i_at(c: Dictionary, v: float) -> float:
	var ia: PackedFloat64Array = c["i"]
	var va: PackedFloat64Array = c["v"]
	var n := ia.size()
	if n == 0 or v >= va[0]:
		return 0.0
	if v <= va[n - 1]:
		return ia[n - 1]
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if va[mid] >= v:
			lo = mid
		else:
			hi = mid
	var f := (va[lo] - v) / maxf(va[lo] - va[hi], 1e-12)
	return lerpf(ia[lo], ia[hi], f)


## A module's own curve at one irradiance (for the panel view's chart).
static func module_curve(model: Dictionary, g: float, t_c: float) -> Dictionary:
	var pg: Array = []
	for i in int(model["n_paths"]):
		pg.append(g)
	return string_curve(model, [pg], t_c)


## Per-path irradiance from per-sample irradiance (sample order =
## PvLabModule.sample_points): each path is the MIN over its bands of each
## band's MEAN.
static func path_irradiance(module_spec: Dictionary, samples: Array) -> Array:
	var out: Array = []
	var k := 0
	for sub in PvLabModule.substrings(module_spec):
		for path in sub["paths"]:
			var gmin := INF
			for band in path["bands"]:
				var tot := 0.0
				for _p in band:
					tot += float(samples[k]) if k < samples.size() else 0.0
					k += 1
				gmin = minf(gmin, tot / float(maxi((band as Array).size(), 1)))
			out.append(0.0 if gmin == INF else gmin)
	return out


## Cell temperature by the NOCT method (as SolarUI): T = Ta + G/800·(NOCT − 20).
static func cell_temp_c(t_amb: float, g: float, noct_c: float = 45.0) -> float:
	return t_amb + maxf(g, 0.0) / 800.0 * (noct_c - 20.0)


static func clear_cache() -> void:
	_fit_cache.clear()
	_cell_cache.clear()
	_sub_cache.clear()
