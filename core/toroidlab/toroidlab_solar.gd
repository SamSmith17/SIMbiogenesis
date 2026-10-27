class_name ToroidLabSolar
extends RefCounted

## The panels on top of the toroid: one (or two, three) per bay, centred
## between two ribs, the long side running over the crown along the minor
## circle. A flexible module bends to the frame's curve; a rigid one lies on
## the chord. Pure; metres, the toroid's own frame.
##
## build(spec, frame) → {
##   panels:  [{bay, slot, theta, rows: [[left, right] per station along the
##             panel], centre, normal, flexible}]
##   count, model, watts_per_panel, total_w, series, parallel,
##   summary: the numbers the graph needs (count, watts_per_panel, voc, vmp,
##            isc, imp, panel_w_m, panel_h_m, avg_normal (local), series,
##            parallel, tilt_deg), warnings
## }

const STATIONS := 10
const SLOT_GAP_M := 0.02


static func build(s: Dictionary, frame: Dictionary) -> Dictionary:
	var so: Dictionary = s["solar"]
	var out := {"panels": [], "count": 0, "model": {}, "watts_per_panel": 0.0, "total_w": 0.0,
		"series": 0, "parallel": 0, "summary": {"count": 0}, "warnings": []}
	var per_bay := int(so["per_bay"])
	if not bool(so["enabled"]) or per_bay <= 0:
		return out
	var t: Dictionary = s["torus"]
	var n := int(t["segments"])
	var r := float(frame["r"])
	var R := float(frame["R"])
	var pm := ToroidLabMaterials.panel(str(so["model"]))
	out["model"] = pm
	var L := float(pm["long_mm"]) * 0.001
	var W := float(pm["short_mm"]) * 0.001
	var flexible := bool(pm["flexible"])
	var rho := r + float(so["standoff_mm"]) * 0.001
	var phc := float(so["centre_deg"])
	var half := rad_to_deg((L * 0.5) / rho)
	var every := int(so["every"])
	var nsum := Vector3.ZERO
	var panels: Array = out["panels"]
	var warns: Array = out["warnings"]
	for bay in n:
		if posmod(bay, every) != 0:
			continue
		var thm := (ToroidLabFrame.rib_theta(t, bay) + ToroidLabFrame.rib_theta(t, bay + 1)) * 0.5
		for slot in per_bay:
			var off := (float(slot) - (per_bay - 1) * 0.5) * (W + SLOT_GAP_M)
			var rows: Array = []
			var p0 := ToroidLabFrame.point(t, thm, phc - half, rho)
			var p1 := ToroidLabFrame.point(t, thm, phc + half, rho)
			for i in STATIONS + 1:
				var f := float(i) / STATIONS
				var c := Vector3.ZERO
				if flexible:
					c = ToroidLabFrame.point(t, thm, lerpf(phc - half, phc + half, f), rho)
				else:
					c = p0.lerp(p1, f)
				var thr := deg_to_rad(thm)
				var tan := Vector3(-sin(thr), 0.0, cos(thr))
				var cc := c + tan * off
				rows.append([cc - tan * (W * 0.5), cc + tan * (W * 0.5)])
			var nrm := ToroidLabFrame.normal(thm, phc)
			if not flexible:
				var along := (p1 - p0).normalized()
				var tan2 := Vector3(-sin(deg_to_rad(thm)), 0.0, cos(deg_to_rad(thm)))
				nrm = along.cross(tan2).normalized()
				if nrm.dot(ToroidLabFrame.normal(thm, phc)) < 0.0:
					nrm = -nrm
			nsum += nrm
			panels.append({"bay": bay, "slot": slot, "theta": thm, "rows": rows,
				"centre": ToroidLabFrame.point(t, thm, phc, rho), "normal": nrm, "flexible": flexible})
	var count := panels.size()
	out["count"] = count
	out["watts_per_panel"] = float(pm["watts"])
	out["total_w"] = float(pm["watts"]) * count
	# --- fit checks -----------------------------------------------------------
	var tube := ToroidLabMaterials.tube(str(s["tube"]["material"]))
	var od := float(tube["od_mm"]) * 0.001
	var r_min := R + rho * minf(cos(deg_to_rad(phc - half)), cos(deg_to_rad(phc + half)))
	var bay_chord := 2.0 * r_min * sin(PI / n)
	var need := per_bay * W + (per_bay - 1) * SLOT_GAP_M
	if need > bay_chord + 1e-4:
		warns.append("The panels (%.0f mm across) are wider than the bay at their narrow end (%.0f mm between rib centres) — they overlap the next bay." % [
			need * 1000.0, bay_chord * 1000.0])
	elif need < bay_chord - od * 2.0 and per_bay == 1:
		warns.append("Each panel spans %.0f of the %.0f mm between ribs at its narrow end — it needs a cross bar under its edges." % [
			need * 1000.0, bay_chord * 1000.0])
	var arc := 2.0 * half
	if flexible and arc > float(pm["max_arc_deg"]):
		warns.append("%s bends through %.0f° of arc — more than the ~%.0f° a flexible module is rated for." % [
			str(pm["label"]), arc, float(pm["max_arc_deg"])])
	if not flexible:
		var sag := rho * (1.0 - cos(deg_to_rad(half)))
		if sag > 0.015:
			warns.append("A rigid panel cannot follow the crown: its middle stands %.0f mm off the ribs." % (sag * 1000.0))
	# --- electrical -------------------------------------------------------------
	var series := int(so["series"])
	var parallel := int(so["parallel"])
	if series > 0 and parallel <= 0:
		parallel = int(ceil(float(count) / series))
	if parallel > 0 and series <= 0:
		series = int(ceil(float(count) / parallel))
	if series > 0 and parallel > 0 and series * parallel != count and count > 0:
		warns.append("%dS × %dP is %d panels, but %d are placed." % [series, parallel, series * parallel, count])
	out["series"] = series
	out["parallel"] = parallel
	var avg := nsum.normalized() if nsum.length() > 1e-6 else Vector3.UP
	out["summary"] = {"count": count, "watts_per_panel": float(pm["watts"]), "voc": float(pm["voc"]),
		"vmp": float(pm["vmp"]), "isc": float(pm["isc"]), "imp": float(pm["imp"]),
		"panel_w_m": W, "panel_h_m": L, "avg_normal": avg, "series": series, "parallel": parallel,
		"tilt_deg": rad_to_deg(acos(clampf(avg.dot(Vector3.UP), -1.0, 1.0))),
		"string_voc": float(pm["voc"]) * maxi(series, 1), "string_vmp": float(pm["vmp"]) * maxi(series, 1)}
	return out
