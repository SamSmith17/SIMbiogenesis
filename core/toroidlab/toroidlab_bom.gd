class_name ToroidLabBom
extends RefCounted

## The toroid's bill of materials: every tube class with its cut length and
## bend, the stock it is cut from, the pipe fittings by kind, tension lines
## and their hardware, the canopy sheets and bolts, the panels and their
## wiring. Masses from ToroidLabMaterials. Pure.
##
## compute(design) → {rows: [{qty, unit, item, detail, kg}], mass_kg,
##   tube_m, stock_pieces, stock_m, waste_pct, fittings: {type: n},
##   cable_m, sheets, bolts, panels}


static func compute(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var units := str(s["fabrication"]["units"])
	var tube := ToroidLabMaterials.tube(str(s["tube"]["material"]))
	var od := float(tube["od_mm"])
	var frame: Dictionary = d["frame"]
	var rows: Array = []
	var mass := 0.0
	var tube_m := 0.0
	var cuts: Array = []
	# --- tubes -----------------------------------------------------------------
	for c in frame["classes"]:
		if str(c["kind"]) == "cable":
			continue
		var cnt := int(c["count"])
		var cut := float(c["cut_m"])
		var kg := cut * float(tube["kg_m"]) * cnt
		mass += kg
		tube_m += cut * cnt
		for i in cnt:
			cuts.append(cut)
		var bend := ""
		if float(c["bend_r_m"]) > 0.0:
			bend = ", bend to R %s through %s (chord %s, rise %s)" % [
				ToroidLabSpec.fmt_len(float(c["bend_r_m"]) * 1000.0, units),
				ToroidLabSpec.fmt_deg(float(c["bend_deg"])),
				ToroidLabSpec.fmt_len(float(c["chord_m"]) * 1000.0, units),
				ToroidLabSpec.fmt_len(float(c["rise_m"]) * 1000.0, units)]
		rows.append({"qty": cnt, "unit": "pcs", "item": "%s %s" % [str(c["label"]), str(c["desc"])],
			"detail": "cut %s%s" % [ToroidLabSpec.fmt_len(cut * 1000.0, units), bend], "kg": kg, "group": "tube"})
	# Stock lengths, first-fit decreasing with the kerf.
	var stock := float(tube["stock_m"])
	var kerf := float(s["fabrication"]["kerf_mm"]) * 0.001
	cuts.sort()
	cuts.reverse()
	var bins: Array = []
	var over := 0
	for cut in cuts:
		if cut > stock:
			over += 1
			bins.append(stock)   # a long piece is spliced: count a whole stick
			continue
		var placed := false
		for i in bins.size():
			if float(bins[i]) + cut + kerf <= stock + 1e-6:
				bins[i] = float(bins[i]) + cut + kerf
				placed = true
				break
		if not placed:
			bins.append(cut)
	var stock_pieces := bins.size() + over
	var waste := 0.0
	if stock_pieces > 0:
		waste = maxf(0.0, 1.0 - tube_m / (stock_pieces * stock)) * 100.0
	rows.push_front({"qty": stock_pieces, "unit": "sticks", "item": str(tube["label"]),
		"detail": "%s lengths%s" % [ToroidLabSpec.fmt_len(stock * 1000.0, units),
			(" — %d pieces are longer than a stick and need a splice" % over) if over > 0 else ""],
		"kg": 0.0, "group": "stock"})
	# --- fittings ----------------------------------------------------------------
	var fit_counts := {}
	for f in frame["fittings"]:
		var ty := str(f["type"])
		fit_counts[ty] = int(fit_counts.get(ty, 0)) + 1
	var series := str(ToroidLabMaterials.CONNECTOR_SERIES.get(str(tube["fits"]), "pipe fittings"))
	for ty in ["foot", "coupler", "elbow", "tee", "cross", "cross5", "crossover", "swivel", "eye"]:
		if not fit_counts.has(ty):
			continue
		var n := int(fit_counts[ty])
		var kg := ToroidLabMaterials.connector_kg(ty, od) * n
		mass += kg
		var cdef := ToroidLabMaterials.connector(ty)
		rows.append({"qty": n, "unit": "pcs", "item": str(cdef["label"]), "detail": "%s — %s" % [series, str(cdef["detail"])],
			"kg": kg, "group": "fitting"})
	# --- tension lines -------------------------------------------------------------
	var cable_m := 0.0
	var lines := 0
	var by_cable := {}
	for c in frame["classes"]:
		if str(c["kind"]) != "cable":
			continue
		var id := str(c["cable"])
		by_cable[id] = float(by_cable.get(id, 0.0)) + float(c["len_m"]) * int(c["count"])
		lines += int(c["count"])
	for id in by_cable:
		var cb := ToroidLabMaterials.cable(str(id))
		var L := float(by_cable[id]) * 1.1 + 0.3 * lines
		cable_m += L
		var kg := L * float(cb["kg_m"])
		mass += kg
		rows.append({"qty": int(ceil(L)), "unit": "m", "item": str(cb["label"]),
			"detail": "%.1f m of lines + 10 %% and 0.3 m a line for the eyes" % float(by_cable[id]), "kg": kg, "group": "cable"})
	if lines > 0:
		rows.append({"qty": lines, "unit": "pcs", "item": "Turnbuckle (hook / eye)", "detail": "one a line, to tension it",
			"kg": lines * 0.08, "group": "cable"})
		rows.append({"qty": lines * 2, "unit": "sets", "item": "Thimble + 2 wire rope clips", "detail": "an eye at each end",
			"kg": lines * 2 * 0.03, "group": "cable"})
		mass += lines * 0.08 + lines * 0.06
	# --- canopy --------------------------------------------------------------------
	var cn: Dictionary = d["canopy"]
	var sheets := 0
	var bolts := 0
	if not (cn.get("pieces", []) as Array).is_empty():
		var mat: Dictionary = cn["material"]
		sheets = ((cn["nest"] as Dictionary).get("sheets", []) as Array).size()
		var kg := float(cn["area_m2"]) * float(mat["kg_m2"])
		mass += kg
		var pieces := 0
		for c in cn["classes"]:
			pieces += int(c["count"])
		rows.append({"qty": sheets, "unit": "sheets", "item": str(mat["label"]),
			"detail": "%d pieces, cut, scored and folded (%s of sheet in the pieces)" % [pieces,
				ToroidLabSpec.fmt_area(float(cn["area_m2"]))], "kg": kg, "group": "canopy"})
		bolts = int(cn["bolts"])
		if bolts > 0:
			var bolt := DomeLabMaterials.bolt(str(s["canopy"]["bolt"]))
			var need := float(mat["t_mm"]) * 2.0 + float(bolt["washer_mm"]) * 2.0 + float(bolt["nut_mm"]) + 3.0
			var Lb := DomeLabMaterials.bolt_length_mm(bolt, need)
			var kgb := bolts * float(bolt["kg_each"])
			mass += kgb
			rows.append({"qty": bolts, "unit": "pcs", "item": "%s × %d mm bolt, 2 fender washers, nyloc" % [str(bolt["label"]), Lb],
				"detail": "%d through each seam's flanges" % int(s["canopy"]["bolts_per_seam"]), "kg": kgb, "group": "canopy"})
		var sectors := (cn["sectors"] as Array).size()
		rows.append({"qty": sectors * 4, "unit": "pcs", "item": "Canopy hanger (zip tie or clip to the rib)",
			"detail": "two at each seam's corners", "kg": 0.0, "group": "canopy"})
	# --- solar -----------------------------------------------------------------------
	var so: Dictionary = d["solar"]
	var npan := int(so["count"])
	if npan > 0:
		var pm: Dictionary = so["model"]
		var kg := float(pm["kg"]) * npan
		mass += kg
		rows.append({"qty": npan, "unit": "pcs", "item": str(pm["label"]),
			"detail": "%s total, %dS × %dP" % ["%.1f kW" % (float(so["total_w"]) / 1000.0), int(so["series"]),
				int(so["parallel"])], "kg": kg, "group": "solar"})
		rows.append({"qty": npan * 4, "unit": "pcs", "item": "Panel mount (grommet tie / clamp to the ribs)",
			"detail": "four a panel", "kg": npan * 4 * 0.02, "group": "solar"})
		mass += npan * 4 * 0.02
		var par := int(so["parallel"])
		if par > 1:
			rows.append({"qty": 1, "unit": "pair", "item": "MC4 %d-to-1 branch connectors" % par,
				"detail": "combine the %d strings" % par, "kg": 0.1, "group": "solar"})
	return {"rows": rows, "mass_kg": mass, "tube_m": tube_m, "stock_pieces": stock_pieces, "stock_m": stock,
		"waste_pct": waste, "fittings": fit_counts, "cable_m": cable_m, "sheets": sheets, "bolts": bolts,
		"panels": npan}


static func bom_csv(d: Dictionary) -> String:
	var o := "qty,unit,item,detail,kg\n"
	for r in (d["bom"] as Dictionary)["rows"]:
		o += "%d,%s,\"%s\",\"%s\",%.2f\n" % [int(r["qty"]), str(r["unit"]), str(r["item"]).replace("\"", "'"),
			str(r["detail"]).replace("\"", "'"), float(r["kg"])]
	return o


static func tubes_csv(d: Dictionary) -> String:
	var units := str(d["spec"]["fabrication"]["units"])
	var k := 1.0 / 25.4 if units == "in" else 1.0
	var o := "label,kind,count,cut_%s,bend_radius_%s,bend_deg,chord_%s,rise_%s,description\n" % [units, units, units, units]
	for c in (d["frame"] as Dictionary)["classes"]:
		o += "%s,%s,%d,%.2f,%.2f,%.2f,%.2f,%.2f,\"%s\"\n" % [str(c["label"]), str(c["kind"]), int(c["count"]),
			float(c["cut_m"]) * 1000.0 * k, float(c["bend_r_m"]) * 1000.0 * k, float(c["bend_deg"]),
			float(c["chord_m"]) * 1000.0 * k, float(c["rise_m"]) * 1000.0 * k, str(c["desc"])]
	return o


## The whole schedule as text: the frame, its cut list with bends, the
## fittings, the canopy pieces and folds, the array, the build order.
static func cut_sheet_text(d: Dictionary) -> String:
	var s: Dictionary = d["spec"]
	var units := str(s["fabrication"]["units"])
	var st: Dictionary = d["stats"]
	var fr: Dictionary = d["frame"]
	var bom: Dictionary = d["bom"]
	var L := func(m: float) -> String: return ToroidLabSpec.fmt_len(m * 1000.0, units)
	var o := "%s\n%s\n\n" % [str(d["name"]), ToroidLabSpec.describe(s)]
	o += "TORUS\n"
	o += "  major radius %s, minor radius %s, centre %s above the ground, %d ribs (%s apart)\n" % [
		L.call(float(fr["R"])), L.call(float(fr["r"])), L.call(float(fr["hc"])), int(fr["n"]),
		ToroidLabSpec.fmt_deg(360.0 / int(fr["n"]))]
	o += "  outer Ø %s, inner Ø at the ground %s, throat Ø %s, height %s\n" % [L.call(float(st["outer_r_m"]) * 2.0),
		L.call(float(st["inner_r_m"]) * 2.0), L.call(float(st["throat_r_m"]) * 2.0), L.call(float(st["height_m"]))]
	o += "  ground cut at %s below the minor circle's equator; inner top ring at %s\n\n" % [
		ToroidLabSpec.fmt_deg(float(fr["ground_deg"])), ToroidLabSpec.fmt_deg(float(fr["inner_top_deg"]))]
	o += "RINGS (angle on the minor circle from the outer equator)\n"
	for ring in fr["rings"]:
		o += "  %d  %-20s %7s  Ø %s at %s high%s\n" % [int(ring["index"]), str(ring["name"]),
			ToroidLabSpec.fmt_deg(float(ring["deg"])), L.call(float(ring["radius_m"]) * 2.0), L.call(float(ring["y"])),
			"" if bool(ring["on_node"]) else "  (passes under the ribs, crossover clamps)"]
	o += "\nCUT LIST — %s\n" % str(ToroidLabMaterials.tube(str(s["tube"]["material"]))["label"])
	for c in fr["classes"]:
		var bend := "straight"
		if float(c["bend_r_m"]) > 0.0:
			bend = "R %s × %s, chord %s, rise %s" % [L.call(float(c["bend_r_m"])), ToroidLabSpec.fmt_deg(float(c["bend_deg"])),
				L.call(float(c["chord_m"])), L.call(float(c["rise_m"]))]
		o += "  %-4s × %3d  %-26s cut %-18s %s\n" % [str(c["label"]), int(c["count"]), str(c["desc"]),
			L.call(float(c["cut_m"])), bend]
	o += "  %d stock lengths, %.0f %% waste, %s of tube\n\n" % [int(bom["stock_pieces"]), float(bom["waste_pct"]),
		L.call(float(bom["tube_m"]))]
	o += "FITTINGS\n"
	for ty in bom["fittings"]:
		o += "  %-24s × %d\n" % [str(ToroidLabMaterials.connector(str(ty))["label"]), int(bom["fittings"][ty])]
	var cn: Dictionary = d["canopy"]
	if not (cn.get("pieces", []) as Array).is_empty():
		o += "\nCANOPY — %s, %d sheets\n" % [str(cn["material"]["label"]), int(bom["sheets"])]
		for p in cn["pieces"]:
			o += "  %s × %d  %s × %s, seam %s\n" % [str(p["label"]), (cn["sectors"] as Array).size(),
				ToroidLabSpec.fmt_len(float(p["w_mm"]), units), ToroidLabSpec.fmt_len(float(p["h_mm"]), units),
				ToroidLabSpec.fmt_len(float(p["len_ab_mm"]), units)]
			for f in p["fold"]:
				o += "        score: %-8s %s\n" % [str(f[3]), ToroidLabSpec.fmt_deg(float(f[2]))]
		o += "  %d bolts (%d a seam)\n" % [int(bom["bolts"]), int(s["canopy"]["bolts_per_seam"])]
	var so: Dictionary = d["solar"]
	if int(so["count"]) > 0:
		var sm: Dictionary = so["summary"]
		o += "\nSOLAR — %d × %s = %.0f W, %dS × %dP, string Voc %.1f V, Vmp %.1f V\n" % [int(so["count"]),
			str(so["model"]["label"]), float(so["total_w"]), int(so["series"]), int(so["parallel"]),
			float(sm["string_voc"]), float(sm["string_vmp"])]
	o += "\nBUILD ORDER\n"
	for i in (d["order"] as Array).size():
		o += "  %d. %s\n" % [i + 1, str(d["order"][i])]
	o += "\nMASS %s\n" % ToroidLabSpec.fmt_kg(float(bom["mass_kg"]))
	return o
