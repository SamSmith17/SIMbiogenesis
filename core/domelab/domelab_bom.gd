class_name DomeLabBom
extends RefCounted

## The bill of materials of a solved dome: every row a builder buys or cuts,
## with quantities, cut lengths, the stock it comes out of (first-fit
## decreasing into stock lengths with the saw kerf), fasteners, panels, and
## the masses. Pure static over DomeLabDesign's solved dictionary.
##
## compute(d) → {rows: [{section, item, qty, unit, detail, mass_kg}],
##   mass_kg, strut_m, stock_pieces, stock_m, waste_pct, bolts, nuts,
##   washers, screws, panels_m2, sheets, hub_mass_kg, strut_mass_kg,
##   panel_mass_kg, fastener_mass_kg}


static func compute(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var sys := str(s["system"])
	var mat := DomeLabMaterials.strut(str(s["strut"]["material"]))
	var fab: Dictionary = s["fabrication"]
	var units := str(fab["units"])
	var rows: Array = []
	var strut_m := 0.0
	var strut_mass := 0.0
	var cuts: Array = []
	var kerf := float(fab["kerf_mm"]) / 1000.0
	# Struts.
	for c in d["strut_classes"]:
		var qty := int(c["count"])
		var cut := float(c["cut"])
		strut_m += cut * qty
		for _i in qty:
			cuts.append(cut)
		var detail := "cut %s" % DomeLabSpec.fmt_len(cut * 1000.0, units)
		if sys == "bolt_stack" or (sys == "hub" and str(s["hub"]["kind"]) in ["plate", "bolt"]):
			detail += ", hole to hole %s, bend %s / %s" % [DomeLabSpec.fmt_len(float(c["hole_len"]) * 1000.0, units),
				DomeLabSpec.fmt_deg(float(c["bend_a"])), DomeLabSpec.fmt_deg(float(c["bend_b"]))]
		elif sys == "flat_bar":
			detail += " (arc), hole to hole %s, bend radius %s" % [DomeLabSpec.fmt_len(float(c["hole_len"]) * 1000.0, units),
				DomeLabSpec.fmt_m(float(c["bend_radius"])) if float(c["bend_radius"]) < INF else "straight"]
		else:
			detail += " (node to node %s)" % DomeLabSpec.fmt_len(float(c["len"]) * 1000.0, units)
		rows.append({"section": "Struts", "item": "Strut %s — %s" % [str(c["label"]), str(mat["label"])],
			"qty": qty, "unit": "pcs", "detail": detail, "mass_kg": cut * qty * float(mat["kg_m"])})
	# Ribs.
	for c in d["rib_classes"]:
		var qty := int(c["count"])
		var arc := float(c["arc_len"])
		strut_m += arc * qty
		rows.append({"section": "Ribs", "item": "%s — %s, %d segments" % [str(c["label"]), str(mat["label"]), int(c["segments"])],
			"qty": qty, "unit": "pcs", "detail": "arc %s, laps at %s" % [DomeLabSpec.fmt_len(arc * 1000.0, units),
				", ".join((c["notches"] as Array).map(func(x): return DomeLabSpec.fmt_len(float(x) * 1000.0, units, 0)))],
			"mass_kg": arc * qty * float(mat["kg_m"])})
		for _i in qty:
			cuts.append(arc)
	# Nexors.
	var nx: Dictionary = d["nexorade"]
	if not nx.is_empty():
		var slat: Dictionary = nx.get("slat", mat)
		mat = slat
		for c in nx.get("classes", []):
			var qty := int(c["count"])
			var L := float(c["len"])
			strut_m += L * qty
			for _i in qty:
				cuts.append(L)
			rows.append({"section": "Slats", "item": "Slat %s — %s" % [str(c["label"]), str(slat["label"])],
				"qty": qty, "unit": "pcs", "detail": "cut %s, holes at %s" % [DomeLabSpec.fmt_len(L * 1000.0, units),
					", ".join((c["holes"] as Array).map(func(x): return DomeLabSpec.fmt_len(float(x) * 1000.0, units, 0)))],
				"mass_kg": L * qty * float(slat["kg_m"])})
	strut_mass = strut_m * float(mat["kg_m"])
	# Stock.
	var stock := float(mat.get("stock_m", 3.0))
	var packed := pack_stock(cuts, stock, kerf)
	if not cuts.is_empty():
		rows.append({"section": "Stock", "item": "%s × %s lengths" % [str(mat["label"]), DomeLabSpec.fmt_m(stock)],
			"qty": int(packed["pieces"]), "unit": "lengths", "detail": "%s of cuts, %.0f %% waste" % [
				DomeLabSpec.fmt_m(strut_m), float(packed["waste_pct"])], "mass_kg": 0.0})
	# Hubs.
	var hub_mass := 0.0
	var hub: Dictionary = s["hub"]
	var hub_kind := str(hub["kind"])
	if sys in ["bolt_stack", "hub", "flat_bar"]:
		for t in d["hub_types"]:
			var qty := int(t["count"])
			var what := ""
			var m_each := 0.0
			var reach := float(hub["reach_mm"])
			match hub_kind if sys == "hub" else ("bolt" if sys != "flat_bar" else "bolt"):
				"socket":
					what = "Socket hub %s — %d arms at %s dip, reach %s" % [str(t["label"]), int(t["valence"]),
						DomeLabSpec.fmt_deg(float(t["mean_dip_deg"])), DomeLabSpec.fmt_len(reach, units)]
					# A printed / cast hub: a core plus arms the strut slides over.
					var w_mm := DomeLabMaterials.strut_width_mm(DomeLabMaterials.strut(str(s["strut"]["material"])))
					var arm_vol := PI * pow(w_mm * 0.45 * 0.001, 2) * (reach * 0.001 + float(s["ends"]["insert_mm"]) * 0.001)
					m_each = (arm_vol * int(t["valence"]) + 1.3 * pow(w_mm * 0.001, 3)) * DomeLabMaterials.PLA_KG_M3 * 0.6
				"plate":
					var r_m := (reach + 25.0) * 0.001
					what = "Star plate %s — %d arms, Ø %s × %s steel" % [str(t["label"]), int(t["valence"]),
						DomeLabSpec.fmt_len(r_m * 2000.0, units), DomeLabSpec.fmt_len(float(hub["plate_t_mm"]), units)]
					m_each = PI * r_m * r_m * float(hub["plate_t_mm"]) * 0.001 * DomeLabMaterials.STEEL_KG_M3 * 0.55
				"ring":
					what = "Ring hub %s — %d struts" % [str(t["label"]), int(t["valence"])]
					m_each = 0.25
				_:
					what = "Bolt hub %s — %d struts stacked%s" % [str(t["label"]), int(t["valence"]),
						" (base, feet)" if bool(t["base"]) else ""]
					m_each = 0.0
			hub_mass += m_each * qty
			rows.append({"section": "Hubs", "item": what, "qty": qty, "unit": "pcs",
				"detail": "arm gaps %s" % _gap_text(t), "mass_kg": m_each * qty})
	# Bolts.
	var bolts: Dictionary = d["bolts"]
	var fast_mass := 0.0
	var bolt_count := int(bolts.get("count", 0))
	if bolt_count > 0:
		var b: Dictionary = bolts["bolt"]
		var lens: Dictionary = bolts["lengths"]
		var keys := lens.keys()
		keys.sort()
		for L in keys:
			var q := int(lens[L])
			var m_each := float(b["kg_each"]) * (0.6 + float(L) / 100.0)
			fast_mass += m_each * q
			rows.append({"section": "Fasteners", "item": "%s × %s bolt" % [str(b["label"]), DomeLabSpec.fmt_len(float(L), units, 0)],
				"qty": q, "unit": "pcs", "detail": "", "mass_kg": m_each * q})
		rows.append({"section": "Fasteners", "item": "%s nut" % str(b["label"]), "qty": bolt_count, "unit": "pcs",
			"detail": "", "mass_kg": bolt_count * float(b["kg_each"]) * 0.4})
		rows.append({"section": "Fasteners", "item": "%s washer" % str(b["label"]), "qty": bolt_count * 2, "unit": "pcs",
			"detail": "", "mass_kg": bolt_count * 2 * float(b["kg_each"]) * 0.15})
		fast_mass += bolt_count * float(b["kg_each"]) * 0.7
	# Panels.
	var pn: Dictionary = d["panels"]
	var panel_mass := float(pn.get("mass_kg", 0.0))
	var screws := 0
	if not (pn.get("panels", []) as Array).is_empty():
		var pmat: Dictionary = pn["material"]
		for c in pn["classes"]:
			var sides: Array = c["sides_mm"]
			rows.append({"section": "Panels", "item": "Panel %s — %s" % [str(c["label"]), str(pmat["label"])],
				"qty": int(c["count"]), "unit": "pcs", "detail": "sides %s%s" % [
					", ".join(sides.map(func(x): return DomeLabSpec.fmt_len(float(x), units, 0))),
					("; folds " + ", ".join((c["bends"] as Array).map(func(x): return DomeLabSpec.fmt_deg(float(x))))) if sys == "plate" else ""],
				"mass_kg": float(c["area_mm2"]) * 1e-6 * int(c["count"]) * float(pmat["kg_m2"])})
		rows.append({"section": "Panels", "item": "%s sheets %s × %s" % [str(pmat["label"]),
			DomeLabSpec.fmt_len(float(pn["sheet"]["w"]), units, 0), DomeLabSpec.fmt_len(float(pn["sheet"]["h"]), units, 0)],
			"qty": int(pn.get("sheets", 0)), "unit": "sheets", "detail": "%s of panels" % DomeLabSpec.fmt_area(float(pn["area_m2"])),
			"mass_kg": 0.0})
		if sys != "plate":
			for p in pn["panels"]:
				screws += (p["holes"] as Array).size()
			rows.append({"section": "Fasteners", "item": "Screws Ø %s" % DomeLabSpec.fmt_len(float(s["face"]["screw_mm"]), units, 0),
				"qty": screws, "unit": "pcs", "detail": "panels to struts", "mass_kg": screws * 0.004})
			fast_mass += screws * 0.004
	var total := strut_mass + hub_mass + fast_mass + panel_mass
	return {"rows": rows, "mass_kg": total, "strut_m": strut_m, "stock_pieces": int(packed["pieces"]),
		"stock_m": stock, "waste_pct": float(packed["waste_pct"]), "bolts": bolt_count, "nuts": bolt_count,
		"washers": bolt_count * 2, "screws": screws, "panels_m2": float(pn.get("area_m2", 0.0)),
		"sheets": int(pn.get("sheets", 0)), "hub_mass_kg": hub_mass, "strut_mass_kg": strut_mass,
		"panel_mass_kg": panel_mass, "fastener_mass_kg": fast_mass}


static func _gap_text(t: Dictionary) -> String:
	var parts: PackedStringArray = []
	for g in t["gaps"]:
		parts.append("%.1f°" % float(g))
	return "/".join(parts)


## First-fit decreasing: how many stock lengths the cuts take, with a kerf.
static func pack_stock(cuts: Array, stock_m: float, kerf_m: float) -> Dictionary:
	var sorted := cuts.duplicate()
	sorted.sort()
	sorted.reverse()
	var bins: Array = []
	for c in sorted:
		var L := float(c)
		var placed := false
		for i in bins.size():
			if float(bins[i]) + L + kerf_m <= stock_m + 1e-9:
				bins[i] = float(bins[i]) + L + kerf_m
				placed = true
				break
		if not placed:
			bins.append(L + kerf_m)
	var used := 0.0
	for c in sorted:
		used += float(c)
	var bought := bins.size() * stock_m
	return {"pieces": bins.size(), "waste_pct": (1.0 - used / bought) * 100.0 if bought > 0.0 else 0.0}


# ---------------------------------------------------------------------------
# Text forms
# ---------------------------------------------------------------------------

static func cut_sheet_text(d: Dictionary) -> String:
	var s: Dictionary = d["spec"]
	var units := str(s["fabrication"]["units"])
	var st: Dictionary = d["stats"]
	var lines: PackedStringArray = []
	lines.append("%s — %s" % [str(d["name"]), DomeLabSpec.describe(s)])
	lines.append("Height %s · floor radius %s · floor %s · surface %s · %s" % [
		DomeLabSpec.fmt_m(float(st["height_m"])), DomeLabSpec.fmt_m(float(st["floor_radius_m"])),
		DomeLabSpec.fmt_area(float(st["floor_area_m2"])), DomeLabSpec.fmt_area(float(st["surface_m2"])),
		DomeLabSpec.fmt_kg(float(d["bom"]["mass_kg"]))])
	lines.append("%d vertices · %d edges · %d faces" % [int(st["vertices"]), int(st["edges"]), int(st["faces"])])
	lines.append("")
	if not (d["strut_classes"] as Array).is_empty():
		lines.append("STRUTS (%s)" % str(DomeLabMaterials.strut(str(s["strut"]["material"]))["label"]))
		var sys := str(s["system"])
		for c in d["strut_classes"]:
			var cf := ""
			if (st["chord_factors"] as Dictionary).has(str(c["label"])):
				cf = "  chord factor %.5f" % float(st["chord_factors"][str(c["label"])])
			var l := "  %-3s × %3d   cut %-12s" % [str(c["label"]), int(c["count"]),
				DomeLabSpec.fmt_len(float(c["cut"]) * 1000.0, units)]
			if sys == "flat_bar":
				l += "  arc, hole–hole %s, bend R %s" % [DomeLabSpec.fmt_len(float(c["hole_len"]) * 1000.0, units),
					DomeLabSpec.fmt_m(float(c["bend_radius"])) if float(c["bend_radius"]) < INF else "∞"]
			elif float(c["hole_len"]) > 0.0:
				l += "  hole–hole %-12s bends %s / %s" % [DomeLabSpec.fmt_len(float(c["hole_len"]) * 1000.0, units),
					DomeLabSpec.fmt_deg(float(c["bend_a"])), DomeLabSpec.fmt_deg(float(c["bend_b"]))]
			lines.append(l + cf)
		lines.append("")
	if not (d["rib_classes"] as Array).is_empty():
		lines.append("RIBS (curved, lapped at every crossing)")
		for c in d["rib_classes"]:
			lines.append("  %s × %d   arc %s   %d segments   laps at %s" % [str(c["label"]), int(c["count"]),
				DomeLabSpec.fmt_len(float(c["arc_len"]) * 1000.0, units), int(c["segments"]),
				", ".join((c["notches"] as Array).map(func(x): return DomeLabSpec.fmt_len(float(x) * 1000.0, units, 0)))])
		lines.append("")
	var nx: Dictionary = d["nexorade"]
	if not nx.is_empty():
		lines.append("SLATS (nexorade, engagement %s)" % DomeLabSpec.fmt_deg(float(nx["rho_deg"])))
		for c in nx["classes"]:
			lines.append("  %s × %d   cut %s   holes from one end: %s" % [str(c["label"]), int(c["count"]),
				DomeLabSpec.fmt_len(float(c["len"]) * 1000.0, units),
				", ".join((c["holes"] as Array).map(func(x): return DomeLabSpec.fmt_len(float(x) * 1000.0, units, 0)))])
		lines.append("")
	if not (d["hub_types"] as Array).is_empty():
		lines.append("HUBS")
		for t in d["hub_types"]:
			lines.append("  %-3s × %3d   %d-way%s   dip %s   gaps %s" % [str(t["label"]), int(t["count"]),
				int(t["valence"]), " base" if bool(t["base"]) else "", DomeLabSpec.fmt_deg(float(t["mean_dip_deg"])),
				_gap_text(t)])
		lines.append("")
	var pn: Dictionary = d["panels"]
	if not (pn.get("panels", []) as Array).is_empty():
		lines.append("PANELS (%s)" % str(pn["material"]["label"]))
		for c in pn["classes"]:
			lines.append("  %-3s × %3d   sides %s%s" % [str(c["label"]), int(c["count"]),
				", ".join((c["sides_mm"] as Array).map(func(x): return DomeLabSpec.fmt_len(float(x), units, 0))),
				("   folds " + ", ".join((c["bends"] as Array).map(func(x): return DomeLabSpec.fmt_deg(float(x))))) if str(s["system"]) == "plate" else ""])
		lines.append("")
	lines.append("BILL OF MATERIALS")
	for r in d["bom"]["rows"]:
		lines.append("  %-10s %5d %-8s %s   %s" % [str(r["section"]), int(r["qty"]), str(r["unit"]), str(r["item"]), str(r["detail"])])
	lines.append("")
	lines.append("BUILD ORDER (base first)")
	for ring in d["order"]:
		var ss: Dictionary = ring["struts"]
		var parts: PackedStringArray = []
		var keys := ss.keys()
		keys.sort()
		for k in keys:
			parts.append("%s×%d" % [str(k), int(ss[k])])
		lines.append("  ring %d at %s: %s hubs%s" % [int(ring["ring"]) + 1, DomeLabSpec.fmt_m(float(ring["y"])),
			str((ring["vertices"] as Array).size()), ("; struts " + ", ".join(parts)) if not parts.is_empty() else ""])
	lines.append("")
	lines.append("CHECKS")
	for c in d["checks"]:
		lines.append("  [%s] %s" % [str(c["level"]).to_upper(), str(c["text"])])
	return "\n".join(lines) + "\n"


static func struts_csv(d: Dictionary) -> String:
	var lines: PackedStringArray = ["label,count,node_to_node_mm,cut_mm,hole_to_hole_mm,bend_a_deg,bend_b_deg,arc_mm,bend_radius_mm,chord_factor"]
	var cf: Dictionary = d["stats"]["chord_factors"]
	for c in d["strut_classes"]:
		lines.append("%s,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%s,%s" % [str(c["label"]), int(c["count"]),
			float(c["len"]) * 1000.0, float(c["cut"]) * 1000.0, float(c["hole_len"]) * 1000.0, float(c["bend_a"]),
			float(c["bend_b"]), float(c["arc_len"]) * 1000.0,
			"%.1f" % (float(c["bend_radius"]) * 1000.0) if float(c["bend_radius"]) < INF else "",
			"%.6f" % float(cf[str(c["label"])]) if cf.has(str(c["label"])) else ""])
	var nx: Dictionary = d["nexorade"]
	for c in nx.get("classes", []):
		lines.append("%s,%d,,%.2f,,,,,,%s" % [str(c["label"]), int(c["count"]), float(c["len"]) * 1000.0,
			"holes " + " ".join((c["holes"] as Array).map(func(x): return "%.1f" % (float(x) * 1000.0)))])
	for c in d["rib_classes"]:
		lines.append("%s,%d,,%.2f,,,,%.2f,,%s" % [str(c["label"]), int(c["count"]), float(c["arc_len"]) * 1000.0,
			float(c["arc_len"]) * 1000.0, "laps " + " ".join((c["notches"] as Array).map(func(x): return "%.1f" % (float(x) * 1000.0)))])
	return "\n".join(lines) + "\n"


static func bom_csv(d: Dictionary) -> String:
	var lines: PackedStringArray = ["section,item,qty,unit,detail,mass_kg"]
	for r in d["bom"]["rows"]:
		lines.append("%s,\"%s\",%d,%s,\"%s\",%.2f" % [str(r["section"]), str(r["item"]).replace("\"", "'"),
			int(r["qty"]), str(r["unit"]), str(r["detail"]).replace("\"", "'"), float(r["mass_kg"])])
	return "\n".join(lines) + "\n"


## Everything a CAD / CAM tool or another program needs, JSON-safe.
static func fabrication_json(d: Dictionary) -> Dictionary:
	var geo: Dictionary = d["geo"]
	var verts: Array = []
	for v in (geo["verts"] as PackedVector3Array):
		verts.append([snappedf(v.x, 1e-5), snappedf(v.y, 1e-5), snappedf(v.z, 1e-5)])
	var faces: Array = []
	for f in geo["faces"]:
		faces.append(Array(f as PackedInt32Array))
	var struts: Array = []
	for st in d["struts"]:
		var e: Dictionary = d["edges"][int(st["edge"])]
		struts.append({"label": st["label"], "a": int(e["a"]), "b": int(e["b"]), "len_mm": float(st["len"]) * 1000.0,
			"cut_mm": float(st["cut"]) * 1000.0, "hole_mm": float(st["hole_len"]) * 1000.0,
			"bend_a_deg": float(st["bend_a"]), "bend_b_deg": float(st["bend_b"])})
	var hubs: Array = []
	for h in d["hubs"]:
		var arms: Array = []
		for a in h["arms"]:
			arms.append({"edge": int(a["edge"]), "to": int(a["other"]), "azimuth_deg": rad_to_deg(float(a["az"])),
				"dip_deg": rad_to_deg(float(a["dip"]))})
		hubs.append({"vertex": int(h["id"]), "type": str(h["type"]), "valence": int(h["valence"]), "base": bool(h["base"]),
			"arms": arms})
	var nexors: Array = []
	for n in (d["nexorade"] as Dictionary).get("nexors", []):
		var p0: Vector3 = n["p0"]
		var p1: Vector3 = n["p1"]
		nexors.append({"label": str(n.get("label", "")), "edge": int(n["edge"]), "p0": [p0.x, p0.y, p0.z],
			"p1": [p1.x, p1.y, p1.z], "len_mm": float(n["len"]) * 1000.0,
			"holes_mm": (n["holes"] as Array).map(func(x): return float(x) * 1000.0)})
	var panels: Array = []
	for p in (d["panels"] as Dictionary).get("panels", []):
		var pts: Array = []
		for q in (p["outer"] as PackedVector2Array):
			pts.append([snappedf(q.x, 0.01), snappedf(q.y, 0.01)])
		panels.append({"label": str(p["label"]), "face": int(p["face"]), "outline_mm": pts,
			"folds_deg": (p["bends"] as Array), "sheet": int(p.get("sheet", -1))})
	var rows: Array = []
	for r in d["bom"]["rows"]:
		rows.append({"section": r["section"], "item": r["item"], "qty": int(r["qty"]), "unit": r["unit"],
			"detail": r["detail"], "mass_kg": snappedf(float(r["mass_kg"]), 0.01)})
	return {"format": "simbiogenesis.domelab", "version": 1, "name": str(d["name"]),
		"spec": DomeLabSpec.to_json_safe(d["spec"]), "description": DomeLabSpec.describe(d["spec"]),
		"stats": d["stats"], "vertices_m": verts, "faces": faces, "base_vertices": geo.get("base_ids", []),
		"struts": struts, "strut_classes": (d["strut_classes"] as Array).map(func(c): return {
			"label": c["label"], "count": int(c["count"]), "cut_mm": float(c["cut"]) * 1000.0,
			"hole_mm": float(c["hole_len"]) * 1000.0, "bend_a_deg": float(c["bend_a"]), "bend_b_deg": float(c["bend_b"])}),
		"hubs": hubs, "hub_types": (d["hub_types"] as Array).map(func(t): return {"label": t["label"],
			"valence": int(t["valence"]), "count": int(t["count"]), "base": bool(t["base"]),
			"gaps_deg": t["gaps"], "dips_deg": (t["dips"] as Array).map(func(x): return rad_to_deg(float(x)))}),
		"nexors": nexors, "panels": panels, "bom": rows, "checks": d["checks"]}
