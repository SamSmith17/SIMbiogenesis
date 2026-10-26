class_name DomeLabDesign
extends RefCounted

## One dome / zome design, solved: spec → geometry → connector angles →
## struts, hubs, nexors, ribs, panels → bill of materials, checks. Pure and
## cached by the spec, so the modal, the world builder, the packing spec
## and the fabrication writers all read the same numbers.
##
## The solved design:
##   spec, family, name, system
##   geo:      DomeLabGeodesic / DomeLabZome output (verts in metres, y up,
##             standing on y = 0)
##   frames:   per vertex {normal, t1, t2}
##   edges:    DomeLabConnectors.edge_records
##   fans:     edges round each vertex, counter-clockwise
##   struts:   per edge {edge, label, len, cut, hole_len, bend_a, bend_b, …}
##             (empty for nexorade / plate / helix ribs)
##   strut_classes: [{label, count, len, cut, hole_len, bend_a, bend_b, …}]
##   hubs / hub_types: DomeLabConnectors.hubs (every system but plate)
##   nexorade: DomeLabNexorade.solve (nexorade system only)
##   ribs / rib_classes: the helix zome's continuous ribs
##   panels:   DomeLabPanels.build (any system with a face material)
##   bolts:    {bolt, per_hub: {type label → length mm}, count}
##   bom:      DomeLabBom.compute
##   checks:   [{level: "ok" | "warn" | "error", text}]
##   stats:    {height_m, floor_radius_m, floor_area_m2, surface_m2,
##              volume_m3, vertices, edges, faces, chord_factors}
##   order:    [{ring, y, vertices, strut_labels}] build sequence, base first

static var _cache := {}
const CACHE_MAX := 16


static func solve(spec: Dictionary) -> Dictionary:
	var s := DomeLabSpec.resolve(spec)
	var key := DomeLabSpec.key_of(s)
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
	var fam := str(s["family"])
	var radius := float(s["radius_m"])
	var geo: Dictionary = {}
	match fam:
		"geodesic": geo = DomeLabGeodesic.build(s["geodesic"], radius)
		"helical": geo = DomeLabHelical.build(s["helical"], radius)
		_: geo = DomeLabZome.build(s["zome"], radius)
	var warnings: Array = (geo.get("warnings", []) as Array).duplicate()
	var frames := DomeLabConnectors.vertex_frames(geo)
	var fidx := DomeLabConnectors.face_index(geo)
	var edges := DomeLabConnectors.edge_records(geo, frames, fidx)
	var fans := DomeLabConnectors.fans(geo, edges)
	var sys := str(s["system"])
	var ribs_mode := fam == "zome" and bool(s["zome"]["ribs"]) and sys != "nexorade" and sys != "plate"
	var d := {"spec": s, "family": fam, "name": str(s["name"]), "system": sys, "geo": geo,
		"frames": frames, "edges": edges, "fans": fans, "struts": [], "strut_classes": [],
		"hubs": [], "hub_types": [], "nexorade": {}, "ribs": [], "rib_classes": [], "panels": {},
		"bolts": {}, "ribs_mode": ribs_mode}
	var atol := float(s["fabrication"]["angle_tol_deg"])
	if sys != "plate":
		var hb := DomeLabConnectors.hubs(geo, edges, fans, atol)
		d["hubs"] = hb["hubs"]
		d["hub_types"] = hb["types"]
	if sys in ["bolt_stack", "hub", "flat_bar"] and not ribs_mode:
		var sc := DomeLabConnectors.strut_classes(edges, s)
		d["struts"] = sc["per_edge"]
		d["strut_classes"] = sc["classes"]
	if ribs_mode:
		var rb := _ribs(geo, edges, s)
		d["ribs"] = rb["ribs"]
		d["rib_classes"] = rb["classes"]
	if sys == "nexorade":
		d["nexorade"] = DomeLabNexorade.solve(geo, edges, fans, s)
		warnings.append_array(d["nexorade"].get("warnings", []))
	d["panels"] = DomeLabPanels.build(geo, edges, fidx, s)
	warnings.append_array(d["panels"].get("warnings", []))
	d["bolts"] = _bolts(d, s)
	d["stats"] = _stats(d)
	d["order"] = _build_order(d)
	d["bom"] = DomeLabBom.compute(d)
	d["checks"] = _checks(d, warnings)
	return d


# ---------------------------------------------------------------------------
# Helix ribs (zome)
# ---------------------------------------------------------------------------

static func _ribs(geo: Dictionary, edges: Array, s: Dictionary) -> Dictionary:
	var rib_index: Dictionary = geo.get("rib_index", {})
	var groups := {}
	for ei in edges.size():
		var e: Dictionary = edges[ei]
		var tag: Dictionary = e.get("tag", {})
		var fam := str(tag.get("rib", ""))
		if fam != "R" and fam != "L":
			continue
		var key := "%s%d" % [fam, int(tag["index"])]
		if not groups.has(key):
			groups[key] = {"key": key, "fam": fam, "index": int(tag["index"]), "edges": []}
		(groups[key]["edges"] as Array).append(ei)
	var ribs: Array = []
	var tol := float(s["fabrication"]["group_tol_mm"]) / 1000.0
	var classes := {}
	for key in groups:
		var g: Dictionary = groups[key]
		# Order the rib's edges from the apex down by their layer k.
		var segs: Array = []
		for ei in g["edges"]:
			var e: Dictionary = edges[int(ei)]
			var ka := int((rib_index.get(int(e["a"]), Vector2i(0, 0)) as Vector2i).y)
			var kb := int((rib_index.get(int(e["b"]), Vector2i(0, 0)) as Vector2i).y)
			var k0 := mini(ka, kb)
			var k1 := maxi(ka, kb)
			var arc := DomeLabZome.rib_arc_length(geo, str(g["fam"]), int(g["index"]), k0, k1)
			segs.append({"edge": int(ei), "k0": k0, "k1": k1, "arc": arc, "chord": float(e["len"])})
		segs.sort_custom(func(x, y): return int(x["k0"]) < int(y["k0"]))
		var total := 0.0
		var notches: Array = []
		var run := 0.0
		for i in segs.size():
			total += float(segs[i]["arc"])
			if i < segs.size() - 1:
				run += float(segs[i]["arc"])
				notches.append(run)
		var kmin := int(segs[0]["k0"]) if not segs.is_empty() else 0
		var kmax := int(segs[segs.size() - 1]["k1"]) if not segs.is_empty() else 0
		var rib := {"key": key, "fam": g["fam"], "index": int(g["index"]), "segs": segs, "arc_len": total,
			"notches": notches, "k0": kmin, "k1": kmax}
		var ckey := "%s|%d" % [str(int(round(total / tol))), segs.size()]
		rib["class_key"] = ckey
		if not classes.has(ckey):
			classes[ckey] = {"key": ckey, "arc_len": total, "segments": segs.size(), "count": 0, "ids": [],
				"notches": notches}
		(classes[ckey] as Dictionary)["count"] = int((classes[ckey] as Dictionary)["count"]) + 1
		((classes[ckey] as Dictionary)["ids"] as Array).append(key)
		ribs.append(rib)
	var clist: Array = classes.values()
	clist.sort_custom(func(x, y): return float(x["arc_len"]) > float(y["arc_len"]))
	for i in clist.size():
		(clist[i] as Dictionary)["label"] = "Rib %d" % (i + 1)
	for r in ribs:
		for c in clist:
			if str(c["key"]) == str(r["class_key"]):
				r["label"] = str(c["label"])
	ribs.sort_custom(func(x, y):
		if str(x["fam"]) != str(y["fam"]):
			return str(x["fam"]) < str(y["fam"])
		return int(x["index"]) < int(y["index"]))
	return {"ribs": ribs, "classes": clist}


# ---------------------------------------------------------------------------
# Bolts, stats, order, checks
# ---------------------------------------------------------------------------

static func _bolts(d: Dictionary, s: Dictionary) -> Dictionary:
	var sys := str(s["system"])
	var hub: Dictionary = s["hub"]
	var bolt := DomeLabMaterials.bolt(str(hub["bolt"]))
	var mat := DomeLabMaterials.strut(str(s["strut"]["material"]))
	var out := {"bolt": bolt, "id": str(hub["bolt"]), "per_type": {}, "count": 0, "lengths": {}}
	var stacked := sys == "bolt_stack" or sys == "flat_bar" or (sys == "hub" and str(hub["kind"]) in ["bolt", "plate"])
	if stacked:
		var flattened := sys == "bolt_stack" or (sys == "hub" and str(hub["kind"]) == "plate")
		for t in d["hub_types"]:
			var L := DomeLabConnectors.bolt_length_mm(int(t["valence"]), mat, bolt, flattened)
			if sys == "hub" and str(hub["kind"]) == "plate":
				# Plate hubs: one bolt per arm through plate + strut end.
				L = DomeLabMaterials.bolt_length_mm(bolt, float(hub["plate_t_mm"])
					+ DomeLabMaterials.strut_stack_mm(mat, true) + float(bolt["nut_mm"])
					+ 2.0 * float(bolt["washer_mm"]) + float(bolt["d_mm"]))
				out["lengths"][L] = int(out["lengths"].get(L, 0)) + int(t["count"]) * int(t["valence"])
				out["count"] = int(out["count"]) + int(t["count"]) * int(t["valence"])
			else:
				out["lengths"][L] = int(out["lengths"].get(L, 0)) + int(t["count"])
				out["count"] = int(out["count"]) + int(t["count"])
			out["per_type"][str(t["label"])] = L
	elif sys == "nexorade":
		var nx: Dictionary = d["nexorade"]
		var slat: Dictionary = nx.get("slat", {})
		var L := DomeLabMaterials.bolt_length_mm(bolt, 2.0 * float(slat.get("t_mm", 6.0))
			+ float(bolt["nut_mm"]) + 2.0 * float(bolt["washer_mm"]) + float(bolt["d_mm"]))
		var n := int(nx.get("crossings", 0))
		out["lengths"][L] = n
		out["count"] = n
	elif sys == "plate":
		# One bolt per shared hole through a flange pair (with the seam gap
		# between them), plus one anchor per hole in a floor flange.
		var pn: Dictionary = d["panels"]
		var mat_t := float(pn.get("t_mm", (pn.get("material", {}) as Dictionary).get("t_mm", 3.0)))
		var L := DomeLabMaterials.bolt_length_mm(bolt, 2.0 * mat_t + float(pn.get("gap_mm", 0.0))
			+ float(bolt["nut_mm"]) + 2.0 * float(bolt["washer_mm"]) + float(bolt["d_mm"]))
		var n := (pn.get("bolts3d", []) as Array).size()
		out["lengths"][L] = n
		out["count"] = n
		out["anchors"] = int(pn.get("anchors", 0))
	return out


static func _stats(d: Dictionary) -> Dictionary:
	var geo: Dictionary = d["geo"]
	var verts: PackedVector3Array = geo["verts"]
	var faces: Array = geo["faces"]
	var height := 0.0
	var rmax := 0.0
	for v in verts:
		height = maxf(height, v.y)
		rmax = maxf(rmax, Vector2(v.x, v.z).length())
	var base: Array = geo.get("base_ids", [])
	var floor_r := 0.0
	var base_pts: Array = []
	for id in base:
		var v := verts[int(id)]
		floor_r += Vector2(v.x, v.z).length()
		base_pts.append(Vector2(v.x, v.z))
	floor_r = floor_r / maxf(base.size(), 1) if not base.is_empty() else rmax
	# Floor polygon area (base ring sorted by angle).
	var floor_area := 0.0
	var loop := _floor_loop(geo)
	if loop.size() >= 3:
		# A helical zome's floor need not be star-shaped round the axis:
		# chain the boundary edges into the real outline.
		for i in loop.size():
			var p: Vector2 = loop[i]
			var q: Vector2 = loop[(i + 1) % loop.size()]
			floor_area += p.x * q.y - q.x * p.y
		floor_area = absf(floor_area) * 0.5
	elif base_pts.size() >= 3:
		base_pts.sort_custom(func(a, b): return atan2((a as Vector2).y, (a as Vector2).x) < atan2((b as Vector2).y, (b as Vector2).x))
		for i in base_pts.size():
			var p: Vector2 = base_pts[i]
			var q: Vector2 = base_pts[(i + 1) % base_pts.size()]
			floor_area += p.x * q.y - q.x * p.y
		floor_area = absf(floor_area) * 0.5
	var surface := 0.0
	var volume := 0.0
	for f in faces:
		var pf: PackedInt32Array = f
		for k in range(1, pf.size() - 1):
			var a := verts[pf[0]]
			var b := verts[pf[k]]
			var c := verts[pf[k + 1]]
			surface += (b - a).cross(c - a).length() * 0.5
			volume += a.dot(b.cross(c)) / 6.0
	# The floor closes the volume through the origin (a point on the floor
	# plane), so its triangles add nothing: the face sum IS the enclosed volume.
	var chord := {}
	if str(d["family"]) == "geodesic":
		var r := float(d["spec"]["radius_m"])
		for c in d["strut_classes"]:
			chord[str(c["label"])] = float(c["len"]) / r
	var strut_m := 0.0
	for st in d["struts"]:
		strut_m += float(st["cut"])
	for rb in d["ribs"]:
		strut_m += float(rb["arc_len"])
	for nx in (d["nexorade"] as Dictionary).get("nexors", []):
		strut_m += float(nx["len"])
	return {"height_m": height, "floor_radius_m": floor_r, "radius_max_m": rmax,
		"floor_area_m2": floor_area, "surface_m2": surface, "volume_m3": absf(volume),
		"vertices": verts.size(), "edges": (geo["edges"] as Array).size(), "faces": faces.size(),
		"chord_factors": chord, "strut_m": strut_m, "fraction": float(geo.get("fraction_actual", 1.0))}


## A helical zome's floor outline (plan, metres), chained from the edges
## that bound one face only; empty for the other families.
static func _floor_loop(geo: Dictionary) -> PackedVector2Array:
	if not geo.has("levels_kept"):
		return PackedVector2Array()
	var verts: PackedVector3Array = geo["verts"]
	var use := {}
	for f in geo["faces"]:
		var pf: PackedInt32Array = f
		for k in pf.size():
			var key := DomeLabGeodesic._ekey(pf[k], pf[(k + 1) % pf.size()])
			use[key] = int(use.get(key, 0)) + 1
	var nxt := {}
	for key in use:
		if int(use[key]) != 1:
			continue
		var parts := str(key).split("_")
		var a := int(parts[0])
		var b := int(parts[1])
		if not nxt.has(a):
			nxt[a] = []
		if not nxt.has(b):
			nxt[b] = []
		(nxt[a] as Array).append(b)
		(nxt[b] as Array).append(a)
	if nxt.is_empty():
		return PackedVector2Array()
	var start: int = nxt.keys()[0]
	var out := PackedVector2Array()
	var prev := -1
	var cur := start
	for _i in nxt.size() + 1:
		out.append(Vector2(verts[cur].x, verts[cur].z))
		var nb: Array = nxt[cur]
		var go := int(nb[0]) if int(nb[0]) != prev else (int(nb[1]) if nb.size() > 1 else -1)
		if go < 0 or go == start:
			break
		prev = cur
		cur = go
	return out


## Rings of vertices by height, base first; the strut types each ring adds.
static func _build_order(d: Dictionary) -> Array:
	var geo: Dictionary = d["geo"]
	var verts: PackedVector3Array = geo["verts"]
	var r := float(d["spec"]["radius_m"])
	var rings := DomeLabGeodesic._rings(verts, 0.04 * r)
	rings.reverse()   # lowest first
	var ring_of := PackedInt32Array()
	ring_of.resize(verts.size())
	for i in verts.size():
		var best := 0
		var bd := INF
		for k in rings.size():
			var dd := absf(verts[i].y - float(rings[k]))
			if dd < bd:
				bd = dd
				best = k
		ring_of[i] = best
	var out: Array = []
	for k in rings.size():
		out.append({"ring": k, "y": float(rings[k]), "vertices": [], "struts": {}, "hubs": {}})
	for i in verts.size():
		(out[ring_of[i]]["vertices"] as Array).append(i)
	for h in d["hubs"]:
		var rk := ring_of[int(h["id"])]
		var hs: Dictionary = out[rk]["hubs"]
		hs[str(h["type"])] = int(hs.get(str(h["type"]), 0)) + 1
	for st in d["struts"]:
		var e: Dictionary = d["edges"][int(st["edge"])]
		var rk := maxi(ring_of[int(e["a"])], ring_of[int(e["b"])])
		var ss: Dictionary = out[rk]["struts"]
		ss[str(st["label"])] = int(ss.get(str(st["label"]), 0)) + 1
	return out


static func _checks(d: Dictionary, warnings: Array) -> Array:
	var out: Array = []
	var s: Dictionary = d["spec"]
	var sys := str(s["system"])
	var mat := DomeLabMaterials.strut(str(s["strut"]["material"]))
	var geo: Dictionary = d["geo"]
	for w in warnings:
		out.append({"level": "warn", "text": str(w)})
	# Euler on the closed surface.
	var fc: Dictionary = geo.get("full_count", {})
	if not fc.is_empty():
		var chi := int(fc["v"]) - int(fc["e"]) + int(fc["f"])
		if chi != 2:
			out.append({"level": "error", "text": "The closed surface is not a sphere (V − E + F = %d)" % chi})
	# Struts vs stock.
	var stock := float(mat.get("stock_m", 3.0))
	var longest := 0.0
	for c in d["strut_classes"]:
		longest = maxf(longest, float(c["cut"]))
	if longest > stock + 1e-6:
		out.append({"level": "error", "text": "Strut %s is longer than the %s stock (%s) — raise the frequency or shrink the dome" % [
			DomeLabSpec.fmt_m(longest), str(mat["label"]), DomeLabSpec.fmt_m(stock)]})
	elif longest > 0.0:
		var per := int(floor(stock / longest))
		out.append({"level": "ok", "text": "Longest strut %s cuts %d from each %s length" % [
			DomeLabSpec.fmt_m(longest), per, DomeLabSpec.fmt_m(stock)]})
	# Slenderness (Euler buckling territory above ~200).
	if longest > 0.0 and sys in ["bolt_stack", "hub"]:
		var rg := DomeLabMaterials.strut_gyration_mm(mat)
		var slender := longest * 1000.0 / maxf(rg, 1e-6)
		if slender > 200.0:
			out.append({"level": "warn", "text": "Slenderness L/r = %d on the longest strut (over 200): a stouter section or a higher frequency" % int(slender)})
		else:
			out.append({"level": "ok", "text": "Slenderness L/r = %d" % int(slender)})
	# Flattened ends need a flattenable section.
	if (sys == "bolt_stack" or (sys == "hub" and str(s["hub"]["kind"]) == "plate")) and not bool(mat.get("flatten", false)):
		out.append({"level": "error", "text": "%s cannot be flattened and drilled — use EMT / aluminium tube, or a socket hub" % str(mat["label"])})
	if sys == "bolt_stack":
		var worst := 0.0
		for c in d["strut_classes"]:
			worst = maxf(worst, float(c["bend_b"]))
		out.append({"level": "ok" if worst < 25.0 else "warn", "text": "End bends up to %s (bend the flattened tab, hole side down)" % DomeLabSpec.fmt_deg(worst)})
	# Flat bar strain.
	if sys == "flat_bar":
		var worst_strain := 0.0
		for c in d["strut_classes"]:
			worst_strain = maxf(worst_strain, float(c["strain"]))
		var allow := float(mat.get("bend_strain", 0.0))
		if str(mat.get("kind", "")) != "bar":
			out.append({"level": "error", "text": "%s is not a flat bar — pick a bar section for the flat-bar system" % str(mat["label"])})
		elif allow <= 0.0:
			out.append({"level": "warn", "text": "%s is cut to its arc, not bent (CNC rib)" % str(mat["label"])})
		elif worst_strain > allow:
			out.append({"level": "error", "text": "Bending to R %s strains the bar %.1f %% (limit %.1f %%) — thinner bar or a bigger dome" % [
				DomeLabSpec.fmt_m(float(s["radius_m"])), worst_strain * 100.0, allow * 100.0]})
		else:
			out.append({"level": "ok", "text": "Bar strain %.2f %% of %.1f %% allowed" % [worst_strain * 100.0, allow * 100.0]})
	# Hubs.
	if not (d["hub_types"] as Array).is_empty():
		var maxv := 0
		for t in d["hub_types"]:
			maxv = maxi(maxv, int(t["valence"]))
		out.append({"level": "ok", "text": "%s, up to %d-way" % [UiText.count((d["hub_types"] as Array).size(), "hub type"), maxv]})
	# Zome rhombi without a diagonal in a strut system.
	if str(d["family"]) == "zome" and sys in ["bolt_stack", "hub", "flat_bar"] and not bool(s["zome"]["triangulate"]) \
			and not bool(d["ribs_mode"]) and str(s["face"]["material"]) == "none":
		out.append({"level": "warn", "text": "A rhombus frame is a mechanism: add diagonals (Triangulate) or rigid panels"})
	# Base level.
	var base: Array = geo.get("base_ids", [])
	if base.size() >= 3:
		var verts: PackedVector3Array = geo["verts"]
		var lo := INF
		var hi := -INF
		for id in base:
			lo = minf(lo, verts[int(id)].y)
			hi = maxf(hi, verts[int(id)].y)
		if hi - lo > 0.01:
			out.append({"level": "warn", "text": "The base is not level (%s between the lowest and highest base hub) — tick Flat base or shim the feet" % DomeLabSpec.fmt_len((hi - lo) * 1000.0)})
		else:
			out.append({"level": "ok", "text": "%s on a level base" % UiText.count(base.size(), "base hub")})
	# Nexorade fit.
	if sys == "nexorade":
		var nx: Dictionary = d["nexorade"]
		var slat: Dictionary = nx.get("slat", {})
		var t_mm := float(slat.get("t_mm", 6.0))
		var mean := float(nx.get("mean_ecc_mm", 0.0))
		var spread := float(nx.get("max_ecc_mm", 0.0)) - float(nx.get("min_ecc_mm", 0.0))
		if str(nx.get("mode", "band")) == "rigid":
			out.append({"level": "ok" if absf(mean - t_mm) < t_mm * 0.25 else "warn",
				"text": "Engagement %s: slats sit %.1f mm apart on average (slat %.0f mm thick, spread %.1f mm)" % [
					DomeLabSpec.fmt_deg(float(nx.get("rho_deg", 0.0))), mean, t_mm, spread]})
		else:
			out.append({"level": "ok", "text": "Engagement %s: each band's end hole sits %.0f %% of its edge from the inboard hole; bands lie on the curve (holes spaced along the arc)" % [
				DomeLabSpec.fmt_deg(float(nx.get("rho_deg", 0.0))), float(nx.get("engage_frac", 0.0)) * 100.0]})
		if str(slat.get("kind", "")) != "bar":
			out.append({"level": "warn", "text": "Nexorade slats are flat bars; %s will not lie over its neighbours" % str(slat["label"])})
	# Panels.
	var pn: Dictionary = d["panels"]
	if not (pn.get("panels", []) as Array).is_empty():
		var unpl: Array = pn.get("unplaced", [])
		if unpl.is_empty():
			out.append({"level": "ok", "text": "%s nest on %s" % [UiText.count((pn["panels"] as Array).size(), "panel"),
				UiText.count(int(pn.get("sheets", 0)), "sheet")]})
		else:
			out.append({"level": "error", "text": UiText.count(unpl.size(), "panel") + " do not fit the sheet"})
		if sys == "plate":
			var t_mm := float(pn.get("t_mm", 1.0))
			var fr_mm := float(pn.get("fold_r_mm", t_mm))
			var sec := DomeLabPanels.flange_section(0.0, t_mm, fr_mm, float(pn.get("gap_mm", 0.0)), float(pn.get("flange_mm", 40.0)))
			var bolt := DomeLabMaterials.bolt(str(s["hub"]["bolt"]))
			if float(sec["run"]) < float(bolt["d_mm"]) * 2.5:
				out.append({"level": "warn", "text": "The flange's straight run (%s) is short for a %s bolt — widen the flange or tighten the bend" % [
					DomeLabSpec.fmt_len(float(sec["run"])), str(bolt["label"])]})
			if fr_mm < t_mm * 0.99:
				out.append({"level": "warn", "text": "A bend radius under the sheet thickness (%s < %s) cracks most steel — use at least 1 × t" % [
					DomeLabSpec.fmt_len(fr_mm), DomeLabSpec.fmt_len(t_mm)]})
			var nb := (pn.get("bolts3d", []) as Array).size()
			if nb > 0:
				out.append({"level": "ok", "text": "%s through the flange pairs (holes drilled per edge, so both plates line up)%s" % [
					UiText.count(nb, "bolt"), (", " + UiText.count(int(pn.get("anchors", 0)), "floor anchor")) if int(pn.get("anchors", 0)) > 0 else ""]})
		if int(pn.get("panes", 0)) > 0 or float(pn.get("open_area_m2", 0.0)) > 0.0:
			var gl: Dictionary = pn.get("glazing", {})
			out.append({"level": "ok", "text": "Openings %s%s" % [DomeLabSpec.fmt_area(float(pn.get("open_area_m2", 0.0))),
				(" glazed with %s (%s, %s of pane)" % [str(gl.get("label", "")), UiText.count(int(pn["panes"]), "pane"),
					DomeLabSpec.fmt_area(float(pn.get("pane_area_m2", 0.0)))]) if int(pn.get("panes", 0)) > 0 else " (open)"]})
		if sys == "plate" and not bool((pn.get("material", {}) as Dictionary).get("folds", false)):
			out.append({"level": "warn", "text": "%s does not fold: plates need a sheet that bends (steel, aluminium, HDPE, polycarbonate)" % str(pn["material"]["label"])})
	# Mass.
	var bom: Dictionary = d["bom"]
	out.append({"level": "ok", "text": "About %s all up" % DomeLabSpec.fmt_kg(float(bom.get("mass_kg", 0.0)))})
	return out


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## Where everything packs: a strut bundle (longest strut × the bundle's
## square section), the panel stack and the hub box, as ONE envelope. Metres
## and kg (PackedSpec units).
static func packed_spec(design: Dictionary) -> Dictionary:
	var s: Dictionary = design["spec"]
	var mat := DomeLabMaterials.strut(str(s["strut"]["material"]))
	var longest := 0.0
	var n := 0
	var area := 0.0
	var w_mm := DomeLabMaterials.strut_width_mm(mat)
	for st in design["struts"]:
		longest = maxf(longest, float(st["cut"]))
		n += 1
	for nx in (design["nexorade"] as Dictionary).get("nexors", []):
		longest = maxf(longest, float(nx["len"]))
		n += 1
		w_mm = DomeLabMaterials.strut_width_mm((design["nexorade"] as Dictionary).get("slat", mat))
	for rb in design["ribs"]:
		# A rib ships as its segments.
		for sg in rb["segs"]:
			longest = maxf(longest, float(sg["arc"]))
			n += 1
	var section := w_mm * w_mm * 1.3 / 1e6   # m² per strut incl. packing slack
	var side := sqrt(maxf(n, 1) * section)
	var w := maxf(longest, 0.3)
	var dd := maxf(side, 0.15)
	var h := maxf(side, 0.15)
	var pn: Dictionary = design["panels"]
	var panels: Array = pn.get("panels", [])
	if not panels.is_empty():
		var big := Vector2.ZERO
		for p in panels:
			var bb: Rect2 = p["bbox"]
			big = Vector2(maxf(big.x, maxf(bb.size.x, bb.size.y)), maxf(big.y, minf(bb.size.x, bb.size.y)))
		var t := float((pn.get("material", {}) as Dictionary).get("t_mm", 3.0))
		w = maxf(w, big.x / 1000.0)
		dd = maxf(dd, big.y / 1000.0)
		h += panels.size() * t / 1000.0
	var form := "bundle"
	if str(s["system"]) == "plate":
		form = "panel_stack"
	return {"w_m": w, "d_m": dd, "h_m": h, "mass_kg": float((design["bom"] as Dictionary).get("mass_kg", 0.0)),
		"form": form, "source": "computed", "count": 1}


static func strut_class(design: Dictionary, label: String) -> Dictionary:
	for c in design["strut_classes"]:
		if str(c["label"]) == label:
			return c
	return {}
