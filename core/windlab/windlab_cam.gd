class_name WindLabCam
extends RefCounted

## A designed wind turbine's files, through DomeLabCam's DXF / SVG writers:
##   <name>_sheet<N>.dxf / .svg   every nested sheet: OUTSIDE_CUT, INSIDE_CUT
##                                (blade slots, mounting holes), FOLD (the
##                                score lines, dashed, with their bend angle),
##                                ETCH_LABELS — for a laser, a drag knife or a
##                                CNC router
##   <name>_part_<id>.dxf / .svg  each distinct part alone (small laser beds,
##                                templates to trace — the PVC pipe template
##                                prints at 100 %)
##   <name>_<print>.stl           the printed / routed solids (propeller
##                                blades, airfoil sections, the hub), mm, ready
##                                for a slicer or the in-game print setup
##   <name>_blade_print.stl       a sheet rotor's blade as a solid (print a
##                                small rotor instead of bending sheet)
##   <name>_power_curve.csv       wind → rotor rpm, generator rpm, volts, amps,
##                                watts
##   <name>_bom.csv, _design.json, _summary.txt
## Pure static.

const MARGIN_MM := 6.0


static func sheet_content(d: Dictionary, sheet_index: int) -> Dictionary:
	var nest: Dictionary = d["nest"]
	var sh: Dictionary = (nest["sheets"] as Array)[sheet_index]
	var out := {"w": float(nest["sheet_w"]), "h": float(nest["sheet_h"]), "outside": [], "inside": [], "fold": [],
		"etch": [], "labels": []}
	var turned: Dictionary = nest.get("turned", {})
	for pl in sh["placements"]:
		var pid := str(pl["id"]).get_slice("#", 0)
		var part := _part(d, pid)
		if part.is_empty():
			continue
		var turn := bool(turned.get(str(pl["id"]), false))
		_place_part(out, part, pl, turn)
	return out


static func _part(d: Dictionary, id: String) -> Dictionary:
	for p in d["parts"]:
		if str(p["id"]) == id:
			return p
	return {}


## Lay one part's geometry on a sheet at its placement (pre-turned a quarter
## turn when its corrugations must run along the sheet's flutes).
static func _place_part(out: Dictionary, part: Dictionary, pl: Dictionary, turn: bool) -> void:
	var w := float(part["w"])
	var h := float(part["h"])
	var bb := Rect2(0.0, 0.0, h if turn else w, w if turn else h)
	var pre := func(ring: Dictionary) -> Dictionary:
		return FlatpackProfile.transform_ring(ring, PI * 0.5, Vector2(h, 0.0)) if turn else ring
	var pre_pt := func(q: Vector2) -> Vector2:
		return Vector2(-q.y + h, q.x) if turn else q
	for r in part["outside"]:
		(out["outside"] as Array).append(FlatpackNesting.ring_on_sheet(pre.call(r), bb, pl))
	for r in part["inside"]:
		(out["inside"] as Array).append(FlatpackNesting.ring_on_sheet(pre.call(r), bb, pl))
	for f in part["fold"]:
		(out["fold"] as Array).append({"a": FlatpackNesting.point_on_sheet(pre_pt.call(f["a"]), bb, pl),
			"b": FlatpackNesting.point_on_sheet(pre_pt.call(f["b"]), bb, pl), "text": str(f.get("text", ""))})
	for lb in part["labels"]:
		var rot := float(lb.get("rot", 0.0)) + (90.0 if turn else 0.0) + (90.0 if bool(pl.get("rot", false)) else 0.0)
		(out["labels"] as Array).append({"p": FlatpackNesting.point_on_sheet(pre_pt.call(lb["p"]), bb, pl),
			"text": str(lb["text"]), "size": float(lb["size"]), "rot": wrapf(rot, -180.0, 180.0)})


## One part alone with a margin round it.
static func part_content(part: Dictionary) -> Dictionary:
	var off := Vector2(MARGIN_MM, MARGIN_MM)
	var out := {"w": float(part["w"]) + 2.0 * MARGIN_MM, "h": float(part["h"]) + 2.0 * MARGIN_MM,
		"outside": [], "inside": [], "fold": [], "etch": [], "labels": []}
	for r in part["outside"]:
		(out["outside"] as Array).append(FlatpackProfile.transform_ring(r, 0.0, off))
	for r in part["inside"]:
		(out["inside"] as Array).append(FlatpackProfile.transform_ring(r, 0.0, off))
	for f in part["fold"]:
		(out["fold"] as Array).append({"a": (f["a"] as Vector2) + off, "b": (f["b"] as Vector2) + off, "text": str(f.get("text", ""))})
	for lb in part["labels"]:
		(out["labels"] as Array).append({"p": (lb["p"] as Vector2) + off, "text": str(lb["text"]), "size": float(lb["size"]),
			"rot": float(lb.get("rot", 0.0))})
	return out


## A sheet rotor's blade as one printable solid (the band at least 1.6 mm
## thick), standing on the bed.
static func blade_print_tris(d: Dictionary) -> PackedVector3Array:
	var blades: Array = d["blades"]
	if blades.is_empty():
		return PackedVector3Array()
	var pts: PackedVector2Array = blades[0]["pts"]
	var t := maxf(float(d["sheet_t_mm"]), 1.6)
	var h := float(d["spec"]["rotor"]["h_mm"]) / float(d["spec"]["rotor"]["stages"])
	var tris := WindLabMesh.sheet_blade(pts, t, 0.0, h)
	var bb := WindLabMesh.bbox(tris)
	return WindLabMesh.transformed(tris, Transform3D(Basis.IDENTITY, -Vector3(bb.position.x, bb.position.y, 0.0)))


## Every file. Returns {ok, error, files: [paths], stl: {id: path}}.
static func write_all(d: Dictionary, dir: String) -> Dictionary:
	if DirAccess.make_dir_recursive_absolute(dir) != OK and not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "error": "cannot create %s" % dir, "files": [], "stl": {}}
	var name := DomeLabCam.safe_name(str(d["spec"]["name"]))
	var files: Array = []
	var stl := {}
	var sheets: Array = d["nest"]["sheets"]
	for i in sheets.size():
		var c := sheet_content(d, i)
		for ext in ["dxf", "svg"]:
			var path := dir.path_join("%s_sheet%d.%s" % [name, i + 1, ext])
			var text := DomeLabCam.dxf_document(c) if ext == "dxf" else DomeLabCam.svg_document(c, "mm", "sheet %d" % (i + 1))
			if not _write(path, text):
				return {"ok": false, "error": "cannot write %s" % path, "files": files, "stl": stl}
			files.append(path)
	for part in d["parts"]:
		var pc := part_content(part)
		for ext2 in ["dxf", "svg"]:
			var p2 := dir.path_join("%s_part_%s.%s" % [name, str(part["id"]), ext2])
			var t2 := DomeLabCam.dxf_document(pc) if ext2 == "dxf" else DomeLabCam.svg_document(pc, "mm", str(part["label"]))
			if not _write(p2, t2):
				return {"ok": false, "error": "cannot write %s" % p2, "files": files, "stl": stl}
			files.append(p2)
	for pr in d["prints"]:
		var p3 := dir.path_join("%s_%s.stl" % [name, str(pr["id"])])
		if not _write_bytes(p3, WindLabMesh.stl_bytes(pr["tris"], "%s %s" % [name, str(pr["label"])])):
			return {"ok": false, "error": "cannot write %s" % p3, "files": files, "stl": stl}
		files.append(p3)
		stl[str(pr["id"])] = p3
	if not (d["blades"] as Array).is_empty():
		var p4 := dir.path_join("%s_blade_print.stl" % name)
		if _write_bytes(p4, WindLabMesh.stl_bytes(blade_print_tris(d), "%s blade" % name)):
			files.append(p4)
			stl["blade_print"] = p4
	for f in [["power_curve.csv", power_curve_csv(d)], ["bom.csv", WindLabDesign.bom_csv(d)],
			["design.json", JSON.stringify(design_json(d), "  ")], ["summary.txt", summary_text(d)]]:
		var p5 := dir.path_join("%s_%s" % [name, str(f[0])])
		if not _write(p5, str(f[1])):
			return {"ok": false, "error": "cannot write %s" % p5, "files": files, "stl": stl}
		files.append(p5)
	return {"ok": true, "error": "", "files": files, "stl": stl}


## The printable solid for one print id (or "blade_print"), written to a
## file the print setup can load. Returns the path, or "".
static func write_stl(d: Dictionary, id: String, dir: String) -> String:
	DirAccess.make_dir_recursive_absolute(dir)
	var name := DomeLabCam.safe_name(str(d["spec"]["name"]))
	var tris := PackedVector3Array()
	if id == "blade_print":
		tris = blade_print_tris(d)
	else:
		for pr in d["prints"]:
			if str(pr["id"]) == id:
				tris = pr["tris"]
	if tris.is_empty():
		return ""
	var path := dir.path_join("%s_%s.stl" % [name, id])
	return path if _write_bytes(path, WindLabMesh.stl_bytes(tris, name)) else ""


static func power_curve_csv(d: Dictionary) -> String:
	var o := "wind_ms,rotor_rpm,tip_speed_ratio,cp,generator_rpm,dc_volts,dc_amps,aero_w,electrical_w\n"
	for p in d["curve"]:
		o += "%.1f,%.1f,%.3f,%.4f,%.1f,%.2f,%.3f,%.2f,%.2f\n" % [float(p["v"]), float(p["rpm"]), float(p["lam"]), float(p["cp"]),
			float(p["gen_rpm"]), float(p["v_dc"]), float(p["i_dc"]), float(p["p_aero"]), float(p["p_elec"])]
	return o


static func design_json(d: Dictionary) -> Dictionary:
	var out := {"spec": WindLabSpec.to_json_safe(d["spec"]), "checks": d["checks"], "bom": d["bom"]}
	var cp := {}
	for k in d["cp"]:
		if k != "factors" and k != "notes":
			cp[k] = d["cp"][k]
	cp["factors"] = d["cp"]["factors"]
	out["cp_model"] = cp
	var curve: Array = []
	for p in d["curve"]:
		curve.append({"v": p["v"], "rpm": p["rpm"], "gen_rpm": p["gen_rpm"], "p_elec": p["p_elec"], "v_dc": p["v_dc"]})
	out["power_curve"] = curve
	for k in ["area_m2", "R_m", "ratio", "drive_eff", "hub_h_m", "v_mean_hub", "aep_kwh", "peak_w", "peak_v", "cut_out_ms"]:
		out[k] = d[k]
	out["start_ms"] = float(d["start_ms"]) if is_finite(float(d["start_ms"])) else null
	out["cut_in_ms"] = float(d["cut_in_ms"]) if is_finite(float(d["cut_in_ms"])) else null
	if not (d["stations"] as Array).is_empty():
		out["blade_stations"] = d["stations"]
	if not (d["ugr"] as Dictionary).is_empty():
		var g := {}
		for k in d["ugr"]:
			var v: Variant = d["ugr"][k]
			g[k] = [v.x, v.y] if v is Vector2 else v
		out["ugrinsky"] = g
	return out


static func summary_text(d: Dictionary) -> String:
	var s: Dictionary = d["spec"]
	var cp: Dictionary = d["cp"]
	var o := "%s\n%s\n\n" % [str(s["name"]), WindLabSpec.describe(s)]
	o += "Swept area %.3f m², Cp %.3f at tip speed ratio %.2f (runaway %.2f)\n" % [float(d["area_m2"]), float(cp["cp_max"]),
		float(cp["lam_opt"]), float(cp["lam_run"])]
	for f in cp["factors"]:
		o += "  × %.3f  %s\n" % [float(f["value"]), str(f["label"])]
	var gen: Dictionary = d["gen"]
	o += "Generator: %s × %d, drive %s %.2f : 1\n" % [str(gen["label"]), int(d["gen_count"]),
		str(WindLabParts.DRIVES[str(s["drive"]["type"])]["label"]), float(d["ratio"])]
	o += "Hub %.2f m, mean wind there %.2f m/s; starts %s, charges from %s, cut-out %.1f m/s\n" % [float(d["hub_h_m"]),
		float(d["v_mean_hub"]), "%.1f m/s" % float(d["start_ms"]) if is_finite(float(d["start_ms"])) else "never",
		"%.1f m/s" % float(d["cut_in_ms"]) if is_finite(float(d["cut_in_ms"])) else "never", float(d["cut_out_ms"])]
	o += "Peak %.1f W at %.1f m/s; %.1f kWh a year\n\n" % [float(d["peak_w"]), float(d["peak_v"]), float(d["aep_kwh"])]
	o += "Wind  rotor rpm  gen rpm  volts  amps  watts\n"
	for p in d["curve"]:
		if fmod(float(p["v"]), 1.0) < 0.01:
			o += "%4.0f  %9.0f  %7.0f  %5.1f  %4.2f  %6.1f\n" % [float(p["v"]), float(p["rpm"]), float(p["gen_rpm"]),
				float(p["v_dc"]), float(p["i_dc"]), float(p["p_elec"])]
	o += "\nParts to cut\n"
	for p in d["parts"]:
		o += "  %d × %s, %.0f × %.0f mm%s\n" % [int(p["qty"]), str(p["label"]), float(p["w"]), float(p["h"]),
			", %d score lines" % (p["fold"] as Array).size() if not (p["fold"] as Array).is_empty() else ""]
		if not str(p["note"]).is_empty():
			o += "      %s\n" % str(p["note"])
	o += "  on %d × %s\n" % [(d["nest"]["sheets"] as Array).size(), str(d["nest"]["sheet_label"])]
	if not (d["prints"] as Array).is_empty():
		o += "\nParts to print\n"
		for p in d["prints"]:
			o += "  %d × %s, %.0f mm, %.0f cm³%s\n" % [int(p["qty"]), str(p["label"]), float(p["length_mm"]), absf(float(p["volume_cm3"])),
				" (in %d pieces)" % int(p["pieces"]) if int(p["pieces"]) > 1 else ""]
	o += "\n"
	for c in d["checks"]:
		o += "[%s] %s\n" % [str(c["level"]), str(c["text"])]
	o += "\nBill of materials\n"
	for r in d["bom"]:
		o += "  %d × %s — %s\n" % [int(r["qty"]), str(r["item"]), str(r["spec"])]
	return o


static func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	return true


static func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	return true
