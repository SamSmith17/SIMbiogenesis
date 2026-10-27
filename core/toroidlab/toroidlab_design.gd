class_name ToroidLabDesign
extends RefCounted

## One toroid design, solved: spec → frame (ribs, rings, bracing, fittings)
## → origami canopy → solar array → bill of materials, checks. Pure and
## cached by the spec, so the modal, the world builder, the packing spec,
## the graph handoff and the fabrication files all read the same numbers.
##
## The solved design:
##   spec, name
##   frame:   ToroidLabFrame.build
##   canopy:  ToroidLabCanopy.build
##   solar:   ToroidLabSolar.build
##   bom:     ToroidLabBom.compute
##   stats:   {outer_r_m, inner_r_m, throat_r_m, base_out_r_m, height_m,
##             floor_area_m2, shade_m2, members, fittings, radius_max_m}
##   order:   build steps, base first
##   checks:  [{level: "ok" | "warn" | "error", text}]

static var _cache := {}
const CACHE_MAX := 16

const STAGES := ["Ground rings (and feet)", "Inner column: inner arcs, posts, inner ground ring",
	"Outer wall arcs onto the outer ground ring", "Top arcs, the inner top ring and the crown ring",
	"Bracing and tension lines", "Canopy sectors, flanges bolted at the ribs", "Solar panels on the crown"]


static func solve(spec: Dictionary) -> Dictionary:
	var s := ToroidLabSpec.resolve(spec)
	var key := ToroidLabSpec.key_of(s)
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
	var frame := ToroidLabFrame.build(s)
	var canopy := ToroidLabCanopy.build(s, frame)
	var solar := ToroidLabSolar.build(s, frame)
	var d := {"spec": s, "name": str(s["name"]), "frame": frame, "canopy": canopy, "solar": solar}
	d["stats"] = _stats(d)
	d["order"] = STAGES.duplicate()
	d["bom"] = ToroidLabBom.compute(d)
	d["checks"] = _checks(d)
	return d


static func _stats(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var m := ToroidLabSpec.measures(s["torus"])
	var fr: Dictionary = d["frame"]
	var inner := float(m["inner_r_m"])
	var base_out := float(m["base_out_r_m"])
	var panel_shade := 0.0
	for p in (d["solar"] as Dictionary)["panels"]:
		var rows: Array = p["rows"]
		for i in rows.size() - 1:
			var a: Array = rows[i]
			var b: Array = rows[i + 1]
			var q := [Vector2(a[0].x, a[0].z), Vector2(a[1].x, a[1].z), Vector2(b[1].x, b[1].z), Vector2(b[0].x, b[0].z)]
			panel_shade += absf((q[1] - q[0]).cross(q[2] - q[0])) * 0.5 + absf((q[2] - q[0]).cross(q[3] - q[0])) * 0.5
	return {"outer_r_m": float(m["outer_r_m"]), "inner_r_m": inner, "throat_r_m": float(m["throat_r_m"]),
		"base_out_r_m": base_out, "height_m": float(m["height_m"]) + float(ToroidLabMaterials.tube(
			str(s["tube"]["material"]))["od_mm"]) * 0.0005,
		"floor_area_m2": PI * (base_out * base_out - inner * inner),
		"shade_m2": float((d["canopy"] as Dictionary).get("shade_m2", 0.0)) + panel_shade,
		"members": (fr["members"] as Array).size(), "fittings": (fr["fittings"] as Array).size(),
		"radius_max_m": float(m["outer_r_m"]) + float(fr["od"])}


static func _checks(d: Dictionary) -> Array:
	var s: Dictionary = d["spec"]
	var out: Array = []
	var fr: Dictionary = d["frame"]
	var cn: Dictionary = d["canopy"]
	var so: Dictionary = d["solar"]
	var bom: Dictionary = d["bom"]
	var tube := ToroidLabMaterials.tube(str(s["tube"]["material"]))
	for w in fr["warnings"]:
		out.append({"level": "warn", "text": str(w)})
	for w in cn.get("warnings", []):
		var lvl := "error" if str(w).contains("does not fit") else "warn"
		out.append({"level": lvl, "text": str(w)})
	for w in so.get("warnings", []):
		out.append({"level": "warn", "text": str(w)})
	# Pieces longer than the stock.
	var stock := float(tube["stock_m"])
	for c in fr["classes"]:
		if str(c["kind"]) != "cable" and float(c["cut_m"]) > stock:
			out.append({"level": "warn", "text": "%s is %.2f m — longer than a %.2f m stick of %s; splice it with a coupler." % [
				str(c["label"]), float(c["cut_m"]), stock, str(tube["label"])]})
	if str(tube["fits"]) != "1in":
		out.append({"level": "ok", "text": "%s takes %s." % [str(tube["label"]),
			str(ToroidLabMaterials.CONNECTOR_SERIES.get(str(tube["fits"]), "its own fittings"))]})
	# The canopy has to stay under the ribs and above the ground.
	var cs: Dictionary = s["canopy"]
	if bool(cs["enabled"]):
		var ph_lo := float(cs["phi_out_deg"])
		if ph_lo < -float(fr["ground_deg"]):
			out.append({"level": "warn", "text": "The canopy's outer edge runs below the outer ground ring."})
		var deepest := maxf(float(cs["valley_in_mm"]), float(cs["valley_out_mm"])) * 0.001
		if deepest >= float(fr["r"]) * 0.9:
			out.append({"level": "warn", "text": "The pleat is nearly as deep as the minor radius — the valleys reach the far side."})
	# Solar under the canopy?
	var ss: Dictionary = s["solar"]
	if int(so["count"]) > 0 and bool(cs["enabled"]):
		var pk := float(cs["phi_peak_deg"])
		var half := rad_to_deg(float(so["model"]["long_mm"]) * 0.0005 / float(fr["r"]))
		if float(ss["centre_deg"]) + half < float(cs["phi_out_deg"]) or float(ss["centre_deg"]) - half > float(cs["phi_in_deg"]):
			out.append({"level": "ok", "text": "The panels sit clear of the canopy."})
		elif absf(float(ss["centre_deg"]) - pk) < half:
			out.append({"level": "ok", "text": "The panels sit above the canopy, over its peak."})
	# The summary lines.
	out.append({"level": "ok", "text": "Frame: %d tubes in %d classes, %d fittings, %s of tube in %d stock lengths." % [
		(fr["members"] as Array).size(), (fr["classes"] as Array).size(), (fr["fittings"] as Array).size(),
		ToroidLabSpec.fmt_m(float(bom["tube_m"])), int(bom["stock_pieces"])]})
	if not (cn.get("pieces", []) as Array).is_empty():
		var unplaced: Array = (cn["nest"] as Dictionary).get("unplaced", [])
		if not unplaced.is_empty():
			out.append({"level": "error", "text": "%d canopy pieces do not fit the sheet." % unplaced.size()})
		out.append({"level": "ok", "text": "Canopy: %d sectors, %d pieces on %d sheets, %d bolts." % [
			(cn["sectors"] as Array).size(), (cn["sectors"] as Array).size() * 2, int(bom["sheets"]), int(bom["bolts"])]})
	if int(so["count"]) > 0:
		var sm: Dictionary = so["summary"]
		out.append({"level": "ok", "text": "Solar: %d × %.0f W = %.2f kW, %dS × %dP, string Voc %.1f V (cold ≈ %.0f V)." % [
			int(so["count"]), float(so["watts_per_panel"]), float(so["total_w"]) / 1000.0, int(so["series"]),
			int(so["parallel"]), float(sm["string_voc"]), float(sm["string_voc"]) * 1.12]})
	return out


## How it ships: the bent tube bundle (longest chord × its rise + the
## bundle's section), the canopy stack and the panel stack, as ONE envelope.
static func packed_spec(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var tube := ToroidLabMaterials.tube(str(s["tube"]["material"]))
	var od := float(tube["od_mm"]) * 0.001
	var chord := 0.3
	var rise := 0.0
	var n := 0
	for c in (d["frame"] as Dictionary)["classes"]:
		if str(c["kind"]) == "cable":
			continue
		chord = maxf(chord, float(c["chord_m"]))
		rise = maxf(rise, float(c["rise_m"]))
		n += int(c["count"])
	# Arcs nest inside each other: the bundle is the rise plus a layer of tubes.
	var side := sqrt(maxf(n, 1) * od * od * 1.4)
	var w := chord
	var dd := maxf(rise + side, 0.2)
	var h := maxf(side, 0.15)
	var cn: Dictionary = d["canopy"]
	if not (cn.get("pieces", []) as Array).is_empty():
		var pcs := 0
		var big := Vector2.ZERO
		for p in cn["pieces"]:
			big = Vector2(maxf(big.x, maxf(float(p["w_mm"]), float(p["h_mm"]))), maxf(big.y, minf(float(p["w_mm"]), float(p["h_mm"]))))
		for c in cn["classes"]:
			pcs += int(c["count"])
		w = maxf(w, big.x / 1000.0)
		dd = maxf(dd, big.y / 1000.0)
		h += pcs * float(cn["material"]["t_mm"]) / 1000.0
	var so: Dictionary = d["solar"]
	if int(so["count"]) > 0:
		h += int(so["count"]) * 0.004
	return {"w_m": w, "d_m": dd, "h_m": h, "mass_kg": float((d["bom"] as Dictionary).get("mass_kg", 0.0)),
		"form": "bundle", "source": "computed", "count": 1}


static func member_class(d: Dictionary, label: String) -> Dictionary:
	for c in (d["frame"] as Dictionary)["classes"]:
		if str(c["label"]) == label:
			return c
	return {}
