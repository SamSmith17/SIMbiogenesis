class_name PeltonLabCam
extends RefCounted

## A designed Pelton wheel's files: the rotor side disc and the spacer ring
## as cut files (DXF R12 + SVG through DomeLabCam's writers: the outline, the
## shaft bore, the hub bolt pattern and — on the discs — every cup bolt
## hole), the bill of materials CSV, the whole design as JSON and a text
## summary. Pure static.

const MARGIN_MM := 10.0


static func _circle(c: Vector2, r: float) -> Dictionary:
	return FlatpackProfile.circle_ring(c, r)


## Content for one plate (DomeLabCam's shape): `disc` true for a side disc
## (cup bolt holes on it), false for the spacer ring.
static func plate_content(d: Dictionary, disc: bool) -> Dictionary:
	var s: Dictionary = d["spec"]
	var rn: Dictionary = d["runner"]
	var ro: Dictionary = d["rotor"]
	var r_out := float(ro["disc_r_mm"]) if disc else float(ro["spacer_r_mm"])
	var c := Vector2(r_out + MARGIN_MM, r_out + MARGIN_MM)
	var inside: Array = [_circle(c, float(ro["shaft_d_mm"]) * 0.5 + 0.1)]
	var n := int(s["hub"]["bolts"])
	var pr := float(ro["bolt_pcd_mm"]) * 0.5
	var hh := float(ro["bolt_hole_mm"]) * 0.5
	for i in n:
		var a := TAU * (float(i) + 0.5) / float(n)
		inside.append(_circle(c + Vector2(cos(a), sin(a)) * pr, hh))
	var labels: Array = []
	if disc:
		var hc := float(PeltonLabParts.bolt(str(s["runner"]["cup_bolt"]))["hole"]) * 0.5
		var z := int(rn["cups"])
		for i in z:
			var th := TAU * float(i) / float(z)
			for br in rn["bolt_radii_mm"]:
				inside.append(_circle(c + Vector2(cos(th), sin(th)) * float(br), hc))
		labels.append({"p": c + Vector2(-r_out * 0.5, -r_out * 0.15), "text": "SIDE DISC x2  %d CUPS  %.0f MM" % [z, float(ro["disc_t_mm"])],
			"size": maxf(r_out * 0.05, 3.0), "rot": 0.0})
	else:
		labels.append({"p": c + Vector2(-r_out * 0.5, -r_out * 0.15), "text": "SPACER  %.1f MM" % float(ro["gap_mm"]),
			"size": maxf(r_out * 0.06, 3.0), "rot": 0.0})
	# The keyway on the bore.
	var etch: Array = []
	if bool(s["hub"]["keyway"]):
		var kr := float(ro["shaft_d_mm"]) * 0.5
		etch.append({"a": c + Vector2(-kr * 0.25, kr), "b": c + Vector2(kr * 0.25, kr)})
	return {"w": 2.0 * (r_out + MARGIN_MM), "h": 2.0 * (r_out + MARGIN_MM), "outside": [_circle(c, r_out)],
		"inside": inside, "etch": etch, "labels": labels}


static func write_all(d: Dictionary, dir: String) -> Dictionary:
	if DirAccess.make_dir_recursive_absolute(dir) != OK and not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "error": "cannot create %s" % dir, "files": []}
	var name := DomeLabCam.safe_name(str(d["spec"]["name"]))
	var files: Array = []
	for pair in [["disc", true], ["spacer", false]]:
		var content := plate_content(d, bool(pair[1]))
		for ext in ["dxf", "svg"]:
			var path := dir.path_join("%s_%s.%s" % [name, str(pair[0]), ext])
			var text := DomeLabCam.dxf_document(content) if ext == "dxf" else DomeLabCam.svg_document(content, "mm", str(pair[0]))
			if not _write(path, text):
				return {"ok": false, "error": "cannot write %s" % path, "files": files}
			files.append(path)
	for f in [["bom.csv", PeltonLabDesign.bom_csv(d)], ["design.json", JSON.stringify(design_json(d), "  ")],
			["summary.txt", summary_text(d)]]:
		var p := dir.path_join("%s_%s" % [name, str(f[0])])
		if not _write(p, str(f[1])):
			return {"ok": false, "error": "cannot write %s" % p, "files": files}
		files.append(p)
	return {"ok": true, "error": "", "files": files}


static func design_json(d: Dictionary) -> Dictionary:
	var out := {"spec": PeltonLabSpec.to_json_safe(d["spec"]), "rules": d["rules"], "checks": d["checks"], "bom": d["bom"]}
	var perf := {}
	for k in d["perf"]:
		var v: Variant = d["perf"][k]
		perf[k] = v if not (v is float and (is_nan(float(v)) or is_inf(float(v)))) else null
	out["performance"] = perf
	var rn := {}
	for k in d["runner"]:
		if k != "cup_xfs" and k != "cup_bolts":
			rn[k] = d["runner"][k]
	out["runner"] = rn
	out["rotor"] = d["rotor"]
	return out


static func summary_text(d: Dictionary) -> String:
	var s: Dictionary = d["spec"]
	var rn: Dictionary = d["runner"]
	var ro: Dictionary = d["rotor"]
	var p: Dictionary = d["perf"]
	var o := "%s\n" % str(s["name"])
	o += "%s\n\n" % PeltonLabSpec.describe(s)
	o += "Wheel: %d cups, %.0f mm wide (%s), overall %.0f mm, pitch circle %.0f mm, root %.0f mm\n" % [int(rn["cups"]),
		float(rn["cup_w_mm"]), str(PeltonLabParts.cup_material(str(s["runner"]["cup_material"]))["label"]), float(rn["tip_r_mm"]) * 2.0,
		float(rn["pcd_mm"]), float(rn["root_r_mm"]) * 2.0]
	o += "Rotor: 2 side discs %.0f x %.1f mm, spacer %.0f x %.1f mm, cup bolts %d x %s per cup\n" % [float(ro["disc_r_mm"]) * 2.0,
		float(ro["disc_t_mm"]), float(ro["spacer_r_mm"]) * 2.0, float(ro["gap_mm"]), int(s["runner"]["cup_bolts"]), str(s["runner"]["cup_bolt"]).to_upper()]
	o += "Hub: %.0f mm bore, flange %.0f mm, %d x %s on %.1f mm\n" % [float(ro["shaft_d_mm"]), float(ro["flange_d_mm"]),
		int(s["hub"]["bolts"]), str(s["hub"]["bolt"]).to_upper(), float(ro["bolt_pcd_mm"])]
	o += "Jets: %d x %.1f mm\n" % [int(s["jets"]["count"]), float(s["jets"]["d_mm"])]
	o += "Drive: %s, %.2f : 1; generator %s\n\n" % [str(PeltonLabParts.DRIVES[str(s["drive"]["type"])]["label"]), float(d["drive"]["ratio"]),
		str(PeltonLabParts.generator(str(s["generator"]["id"]))["label"])]
	o += "At %.1f m gross (%.1f m net), %.2f L/s:\n" % [float(p["h_gross_m"]), float(p["h_net_m"]), float(p["q_lps"])]
	o += "  wheel %d rpm (runaway %d), generator %d rpm, %.1f V open circuit\n" % [int(p["rpm"]), int(p["rpm_runaway"]),
		int(p["gen_rpm"]), float(p["v_oc"])]
	o += "  water %.0f W, shaft %.0f W, electrical %.0f W (%.0f %% water to wire)\n\n" % [float(p["p_hyd_w"]), float(p["p_shaft_w"]),
		float(p["p_elec_w"]), float(p["water_to_wire"]) * 100.0]
	for c in d["checks"]:
		o += "[%s] %s\n" % [str(c["level"]), str(c["text"])]
	o += "\nBill of materials\n"
	for r in d["bom"]:
		o += "  %d x %s - %s\n" % [int(r["qty"]), str(r["item"]), str(r["spec"])]
	return o


static func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	return true
