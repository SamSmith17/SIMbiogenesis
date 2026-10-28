class_name PvLabDesign
extends RefCounted

## One Solar designer spec, solved: module electrics → array layout → rack
## members → strings and their wiring → string and MPPT-input reports →
## bill of materials → checks. Pure and cached by the spec, so the modal,
## the 3D builder, the graph handoff, the packing spec and the shading all
## read the same numbers.
##
## The solved design:
##   spec, name, module (resolved), elec (PvLabModule.electrical), iv (the
##   PvLabIV model), layout (PvLabArray.layout), members (PvLabRack.members),
##   parts (PvLabHardware.parts: every clamp, bracket, footing and bolt set),
##   strings ([[panel index]]), groups ([[string index]]), wiring,
##   unwired, string_reports, group_reports, totals, span, bom, checks

static var _cache := {}
const CACHE_MAX := 24

## Estimated module price for the BOM (US$ per watt, 2026 retail).
const MODULE_USD_PER_W := 0.35


static func solve(spec: Dictionary) -> Dictionary:
	var s := PvLabSpec.resolve(spec)
	var key := PvLabSpec.key_of(s)
	if _cache.has(key):
		return _cache[key]
	var d := _solve(s)
	if _cache.size() >= CACHE_MAX:
		_cache.clear()
	_cache[key] = d
	return d


static func clear_cache() -> void:
	_cache.clear()


static func _solve(s: Dictionary) -> Dictionary:
	var m: Dictionary = s["module"]
	var e := PvLabModule.electrical(m)
	var lay := PvLabArray.layout(m, s["array"], s["rack"])
	var members := PvLabRack.members(lay, s["rack"])
	var strings := PvLabArray.strings_for(m, lay, s["strings"], s["target"])
	var groups := PvLabArray.groups_for(strings, s["strings"])
	var d := {"spec": s, "name": str(s["name"]), "module": m, "elec": e, "iv": PvLabIV.model_for(m),
		"layout": lay, "members": members, "strings": strings, "groups": groups,
		"wiring": PvLabArray.wiring(m, lay, strings), "unwired": PvLabArray.unwired(lay, strings)}
	d["parts"] = PvLabHardware.parts(d)
	d["string_reports"] = _string_reports(d)
	d["group_reports"] = _group_reports(d)
	var area := PvLabModule.area_m2(m)
	d["span"] = PvLabRack.span_check(lay, s["rack"], PvLabModule.mass_kg(m) / maxf(area, 0.01))
	d["bom"] = _bom(d)
	d["totals"] = _totals(d)
	d["checks"] = _checks(d)
	return d


static func _string_reports(d: Dictionary) -> Array:
	var e: Dictionary = d["elec"]
	var t: Dictionary = d["spec"]["target"]
	var out: Array = []
	for st in d["strings"]:
		var n := (st as Array).size()
		var w := PvLabArray.window(e, n, t)
		out.append({"n": n, "voc": float(e["voc"]) * n, "vmp": float(e["vmp"]) * n, "isc": float(e["isc"]),
			"imp": float(e["imp"]), "wmp": float(e["wmp"]) * n, "window": w})
	return out


static func _group_reports(d: Dictionary) -> Array:
	var e: Dictionary = d["elec"]
	var t: Dictionary = d["spec"]["target"]
	var out: Array = []
	var reps: Array = d["string_reports"]
	for g in d["groups"]:
		var ids: Array = g
		var isc := 0.0
		var imp := 0.0
		var wmp := 0.0
		var count := 0
		var vmin := INF
		var vmax := 0.0
		var voc_cold := 0.0
		var vmp_hot := INF
		var ok := true
		var issues: Array = []
		for si in ids:
			var r: Dictionary = reps[int(si)]
			isc += float(r["isc"])
			imp += float(r["imp"])
			wmp += float(r["wmp"])
			count += int(r["n"])
			vmin = minf(vmin, float(r["vmp"]))
			vmax = maxf(vmax, float(r["vmp"]))
			var w: Dictionary = r["window"]
			voc_cold = maxf(voc_cold, float(w["voc_cold"]))
			vmp_hot = minf(vmp_hot, float(w["vmp_hot"]))
			if not bool(w["ok"]):
				ok = false
				for i in w["issues"]:
					if not issues.has(i):
						issues.append(i)
		var series := int((reps[int(ids[0])] as Dictionary)["n"]) if not ids.is_empty() else 0
		var cold := float(t["cold_c"])
		var isc_hot := isc * (1.0 + float(e["isc_coeff"]) / 100.0 * 40.0)
		if float(t["max_isc"]) > 0.0 and isc_hot > float(t["max_isc"]):
			issues.append("short-circuit current %.1f A is over the input's %.1f A" % [isc_hot, float(t["max_isc"])])
			ok = false
		out.append({"strings": ids, "count": count, "series": series, "parallel": ids.size(),
			"voc": float(e["voc"]) * series, "vmp": vmax, "vmp_min": vmin, "isc": isc, "imp": imp,
			"wmp": wmp, "voc_cold": voc_cold, "vmp_hot": vmp_hot, "cold_c": cold, "ok": ok, "issues": issues,
			"equal": is_equal_approx(vmin, vmax)})
	return out


static func _totals(d: Dictionary) -> Dictionary:
	var m: Dictionary = d["module"]
	var n := (d["layout"]["panels"] as Array).size()
	var wired := n - (d["unwired"] as Array).size()
	var fp: Rect2 = d["layout"]["footprint"]
	return {"panels": n, "wired": wired, "wmp": float(d["elec"]["wmp"]) * n,
		"wired_wmp": float(d["elec"]["wmp"]) * wired, "module_area_m2": PvLabModule.area_m2(m) * n,
		"footprint_m2": fp.size.x * fp.size.y, "mass_kg": float(d["bom"]["mass_kg"]),
		"cost_usd": float(d["bom"]["cost_usd"]), "height_m": float(d["layout"]["height_m"]),
		"width_m": fp.size.x, "depth_m": fp.size.y}


## The bill of materials: {rows: [{group, item, qty, unit, length_m, cost,
## kg}], mass_kg, cost_usd, stock}.
static func _bom(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var m: Dictionary = d["module"]
	var lay: Dictionary = d["layout"]
	var mount := str(lay["mount"])
	var n := (lay["panels"] as Array).size()
	var rows: Array = []
	var mass := 0.0
	var cost := 0.0
	var mod_kg := PvLabModule.mass_kg(m)
	var mod_cost := float(d["elec"]["wmp"]) * MODULE_USD_PER_W
	rows.append({"group": "Modules", "item": "%s (%s)" % [str(m["name"]), PvLabModule.describe(m)], "qty": n,
		"unit": "ea", "length_m": 0.0, "cost": mod_cost * n, "kg": mod_kg * n})
	mass += mod_kg * n
	cost += mod_cost * n
	# Members by profile: total length, stock pieces (first fit, kerf 3 mm).
	var by_prof := {}
	var counts := {}
	for mb in d["members"]:
		var pid := str(mb["profile"])
		var p := PvLabRack.profile(pid)
		if float(p["stock_m"]) <= 0.0:
			counts[pid] = int(counts.get(pid, 0)) + 1
			continue
		if not by_prof.has(pid):
			by_prof[pid] = []
		(by_prof[pid] as Array).append(float(mb["len_m"]))
	var stock_total := 0
	for pid in by_prof:
		var p2 := PvLabRack.profile(pid)
		var cuts: Array = by_prof[pid]
		var total := 0.0
		for c in cuts:
			total += float(c)
		var pieces := _stock_pieces(cuts, float(p2["stock_m"]))
		stock_total += pieces
		var kg := total * float(p2["kg_m"])
		var cst := pieces * float(p2["cost"])
		rows.append({"group": "Rack", "item": "%s — %d cuts from %d × %.2f m" % [str(p2["label"]), cuts.size(),
			pieces, float(p2["stock_m"])], "qty": pieces, "unit": "stock", "length_m": total, "cost": cst, "kg": kg})
		mass += kg
		cost += cst
	for pid in counts:
		var p3 := PvLabRack.profile(pid)
		var q := int(counts[pid])
		var kg2 := 16.0 * q if pid == "ballast" else 0.4 * q
		rows.append({"group": "Rack", "item": str(p3["label"]), "qty": q, "unit": "ea", "length_m": 0.0,
			"cost": float(p3["cost"]) * q, "kg": kg2})
		mass += kg2
		cost += float(p3["cost"]) * q
	# Hardware: every part the builder draws, then the fasteners they bring.
	var pc := PvLabHardware.counts(d["parts"])
	var order: Array = pc.keys()
	order.sort_custom(func(x, y): return str(PvLabHardware.part(x)["group"]) + str(x) < str(PvLabHardware.part(y)["group"]) + str(y))
	for pt in order:
		var info := PvLabHardware.part(str(pt))
		var q := int(pc[pt])
		var kg3 := float(info["kg"]) * q
		var c3 := float(info["cost"]) * q
		rows.append({"group": "Hardware", "item": "%s (%s)" % [str(info["label"]), str(info["group"]).to_lower()],
			"qty": q, "unit": "ea", "length_m": 0.0, "cost": c3, "kg": kg3, "part": str(pt)})
		mass += kg3
		cost += c3
	var fc := PvLabHardware.fastener_counts(d["parts"])
	var forder: Array = fc.keys()
	forder.sort()
	for fid in forder:
		var fi: Dictionary = PvLabHardware.FASTENERS[fid]
		var q2 := int(fc[fid])
		rows.append({"group": "Fasteners", "item": str(fi["label"]), "qty": q2, "unit": "ea", "length_m": 0.0,
			"cost": float(fi["cost"]) * q2, "kg": float(fi["kg"]) * q2, "fastener": str(fid)})
		mass += float(fi["kg"]) * q2
		cost += float(fi["cost"]) * q2
	var hw := {}
	var wr: Dictionary = d["wiring"]
	var cable_m := ceilf(float(wr["jumper_m"]) + float(wr["home_run_m"]))
	if cable_m > 0.0:
		hw["mc4_ext"] = int(cable_m)
	for hid in hw:
		var h: Dictionary = PvLabRack.HARDWARE[hid]
		var q := int(hw[hid])
		if q <= 0:
			continue
		rows.append({"group": "Wiring", "item": str(h["label"]), "qty": q, "unit": "m" if hid == "mc4_ext" else "ea",
			"length_m": 0.0, "cost": float(h["cost"]) * q, "kg": float(h["kg"]) * q})
		mass += float(h["kg"]) * q
		cost += float(h["cost"]) * q
	return {"rows": rows, "mass_kg": mass, "cost_usd": cost, "stock": stock_total}


static func _stock_pieces(cuts: Array, stock: float) -> int:
	var sorted := cuts.duplicate()
	sorted.sort()
	sorted.reverse()
	var bins: Array = []
	for c in sorted:
		var need := minf(float(c), stock) + 0.003
		var placed := false
		for i in bins.size():
			if float(bins[i]) + need <= stock + 1e-6:
				bins[i] = float(bins[i]) + need
				placed = true
				break
		if not placed:
			# A member longer than the stock is spliced from several pieces.
			var extra := int(ceil(float(c) / stock)) - 1
			for _k in extra:
				bins.append(stock)
			bins.append(need)
	return bins.size()


static func _checks(d: Dictionary) -> Array:
	var out: Array = []
	var s: Dictionary = d["spec"]
	var m: Dictionary = d["module"]
	var e: Dictionary = d["elec"]
	var lay: Dictionary = d["layout"]
	var fit := PvLabModule.fit_report(m)
	if not bool(fit["fits"]):
		var g: Vector2 = fit["grid_mm"]
		var f: Vector2 = fit["face_mm"]
		out.append({"level": "error", "text": "The cells (%.0f × %.0f mm) do not fit the face inside the frame (%.0f × %.0f mm)." % [
			g.x, g.y, f.x, f.y]})
	if str(e["mode"]) == "datasheet":
		var dv: Dictionary = e["derived"]
		var rel := absf(float(dv["wmp"]) - float(e["wmp"])) / maxf(float(e["wmp"]), 1.0)
		if rel > 0.12:
			out.append({"level": "warn", "text": "The cells as drawn would make %.0f W; the data sheet says %.0f W. Check the cell size, count or cut." % [
				float(dv["wmp"]), float(e["wmp"])]})
	var reps: Array = d["group_reports"]
	for gi in reps.size():
		var r: Dictionary = reps[gi]
		var label := "Input %d" % (gi + 1) if reps.size() > 1 else "The array"
		for i in r["issues"]:
			var lvl := "error" if str(i).contains("exceeds") or str(i).contains("over the input") else "warn"
			out.append({"level": lvl, "text": "%s: %s." % [label, str(i)]})
		if not bool(r["equal"]):
			out.append({"level": "warn", "text": "%s: its parallel strings differ in length (%.0f–%.0f V at Vmp); the long strings are held at the short ones' voltage." % [
				label, float(r["vmp_min"]), float(r["vmp"])]})
		var t: Dictionary = s["target"]
		if float(t["max_pv_watts"]) > 0.0 and float(r["wmp"]) > float(t["max_pv_watts"]) * 1.0:
			out.append({"level": "warn", "text": "%s: %.0f W of modules on a %.0f W input — it clips at midday." % [
				label, float(r["wmp"]), float(t["max_pv_watts"])]})
	var unw: Array = d["unwired"]
	if not unw.is_empty():
		out.append({"level": "warn", "text": "%d module(s) are not in any string and make nothing." % unw.size()})
	var wr: Dictionary = d["wiring"]
	if int(wr["jumpers"]) > 0:
		out.append({"level": "warn", "text": "%d series link(s) need an extension cable (%.1f m in all): the module leads do not reach." % [
			int(wr["jumpers"]), float(wr["jumper_m"])]})
	var sp: Dictionary = d["span"]
	if sp.has("allowed_m"):
		out.append({"level": "ok" if bool(sp["ok"]) else "error", "text": str(sp["text"])})
	var a: Dictionary = s["array"]
	if str(lay["mount"]) == "tracker":
		out.append({"level": "ok", "text": "Tracker rows %.2f m apart, ground-coverage ratio %.2f%s." % [
			float(lay["pitch_m"]), float(lay["gcr"]), " (backtracking)" if bool(s["tracker"]["backtrack"]) else ""]})
	elif int(a["rows"]) > 1:
		var depth := float(lay["module_depth_m"]) * int(a["stack"])
		var tilt := deg_to_rad(float(a["tilt_deg"]))
		var need := depth * cos(tilt) + PvGridSnap.shade_gap_m(depth * sin(tilt), float(a["site_lat"]))
		if float(lay["pitch_m"]) + 0.01 < need:
			out.append({"level": "warn", "text": "Rows %.2f m apart: closer than %.2f m, so the front rows shade the back ones at winter noon." % [
				float(lay["pitch_m"]), need]})
	if str(m["type"]) == "flexible" and str(lay["mount"]) in ["ground", "pole", "tracker"]:
		out.append({"level": "warn", "text": "Flexible modules need a solid backing — on open rails they flex and crack."})
	var tot_n := (lay["panels"] as Array).size()
	out.append({"level": "ok", "text": "%d modules, %s, %d string(s) on %d input(s)." % [tot_n,
		_kw(float(e["wmp"]) * tot_n), (d["strings"] as Array).size(), reps.size()]})
	return out


static func _kw(w: float) -> String:
	return "%.0f W" % w if w < 1000.0 else "%.2f kW" % (w / 1000.0)


## How it ships: the modules on edge in a crate plus the rack bundle.
static func packed_spec(d: Dictionary) -> Dictionary:
	var m: Dictionary = d["module"]
	var n := (d["layout"]["panels"] as Array).size()
	var w := float(m["dims_mm"]["h"]) * 0.001 + 0.1
	var dd := float(m["dims_mm"]["w"]) * 0.001 + 0.1
	var h := n * (float(m["dims_mm"]["t"]) + 6.0) * 0.001 + 0.15
	var longest := 0.0
	var section := 0.0
	for mb in d["members"]:
		longest = maxf(longest, minf(float(mb["len_m"]), 6.5))
		var p := PvLabRack.profile(str(mb["profile"]))
		section += float(p["w"]) * float(p["h"]) * 1.0e-6
	if longest > 0.0:
		w = maxf(w, longest)
		h += sqrt(section * 1.3)
	return {"w_m": w, "d_m": dd, "h_m": h, "mass_kg": float(d["bom"]["mass_kg"]), "form": "crate",
		"source": "computed", "count": 1}


## What the graph needs per MPPT input: {groups: [{count, series, parallel,
## strings: [[panel index]], wmp, voc, vmp, isc, imp}], module: graph
## panel specs}.
static func graph_preset(d: Dictionary) -> Dictionary:
	var e: Dictionary = d["elec"]
	var out: Array = []
	var strings: Array = d["strings"]
	for gi in (d["groups"] as Array).size():
		var r: Dictionary = d["group_reports"][gi]
		var sts: Array = []
		for si in (d["groups"][gi] as Array):
			sts.append(strings[int(si)])
		out.append({"count": int(r["count"]), "series": int(r["series"]), "parallel": int(r["parallel"]),
			"strings": sts, "wmp": float(e["wmp"]), "voc": float(e["voc"]), "vmp": float(e["vmp"]),
			"isc": float(e["isc"]), "imp": float(e["imp"])})
	return {"groups": out, "module": PvLabModule.graph_specs(d["module"])}
