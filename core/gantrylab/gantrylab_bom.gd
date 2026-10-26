class_name GantryLabBom
extends RefCounted

## The bill of materials of a gantry, from its layout: an extrusion cut list
## packed into stock lengths, the corner hardware, the guides and carriages,
## belts / pulleys / idlers / screws / nuts / couplers, motors and drivers,
## the board, a PSU sized to the load, endstops and wiring, the tool and the
## bed, the enclosure. Every row carries a price and a mass from
## GantryLabParts, so the total is a budget with a source.
##
## compute(spec, layout) → {rows: [{cat, qty, unit, item, detail, usd, kg}],
##   cut_list: [{profile, len_mm, qty, label}], stock: {pieces, waste_pct},
##   usd, kg, frame_kg, extrusion_m, watts, psu}

const STOCK_LEN_MM := 1500.0
const KERF_MM := 3.0
const CUT_ROUND_MM := 5.0


static func compute(spec: Dictionary, lay: Dictionary) -> Dictionary:
	var s := GantryLabSpec.resolve(spec)
	var kin := str(s["kinematics"])
	var rows: Array = []
	var v: Dictionary = s["volume"]
	var vx := float(v["x_mm"])
	var vy := float(v["y_mm"])
	var vz := float(v["z_mm"])
	# --- Extrusion cut list -------------------------------------------------
	var cuts: Dictionary = {}  # "profile|len" → {profile, len_mm, qty, labels}
	var beams := GantryLabFrame.all_beams(lay)
	var extrusion_m := 0.0
	var frame_kg := 0.0
	for b in beams:
		var bd: Dictionary = b
		var l_mm := ceilf((bd["a"] as Vector3).distance_to(bd["b"] as Vector3) * 1000.0 / CUT_ROUND_MM) * CUT_ROUND_MM
		var pf := str(bd["profile"])
		var key := "%s|%d" % [pf, int(l_mm)]
		if not cuts.has(key):
			cuts[key] = {"profile": pf, "len_mm": l_mm, "qty": 0, "label": str(bd["label"])}
		cuts[key]["qty"] = int(cuts[key]["qty"]) + 1
		extrusion_m += l_mm * 0.001
		frame_kg += l_mm * 0.001 * float(GantryLabParts.profile(pf)["kg_m"])
	var cut_list: Array = cuts.values()
	cut_list.sort_custom(func(a, b): return str(a["profile"]) < str(b["profile"]) if a["profile"] != b["profile"] else float(a["len_mm"]) > float(b["len_mm"]))
	# Stock packing per profile (first fit decreasing).
	var stock_pieces := 0
	var stock_used_mm := 0.0
	var by_profile: Dictionary = {}
	for c in cut_list:
		var pf := str(c["profile"])
		if not by_profile.has(pf):
			by_profile[pf] = []
		for i in int(c["qty"]):
			(by_profile[pf] as Array).append(float(c["len_mm"]))
	for pf in by_profile:
		var lens: Array = by_profile[pf]
		lens.sort()
		lens.reverse()
		var bins: Array = []
		for l in lens:
			var need := float(l) + KERF_MM
			var placed := false
			for bi in bins.size():
				if float(bins[bi]) + need <= STOCK_LEN_MM:
					bins[bi] = float(bins[bi]) + need
					placed = true
					break
			if not placed:
				bins.append(minf(need, STOCK_LEN_MM))
			stock_used_mm += float(l)
		stock_pieces += bins.size()
		var p := GantryLabParts.profile(pf)
		rows.append(_row("Frame", bins.size(), "pc", "%s × %.1f m" % [str(p["label"]), STOCK_LEN_MM / 1000.0],
			"%d cuts, %.2f m used" % [lens.size(), _sum(lens) / 1000.0],
			bins.size() * STOCK_LEN_MM / 1000.0 * float(p["usd_m"]), bins.size() * STOCK_LEN_MM / 1000.0 * float(p["kg_m"])))
	var waste := 0.0
	if stock_pieces > 0:
		waste = 100.0 * (1.0 - stock_used_mm / (stock_pieces * STOCK_LEN_MM))
	# --- Corner hardware ----------------------------------------------------
	var n_beams := beams.size()
	var corners := str(s["frame"]["corners"])
	var hw := GantryLabParts.HARDWARE
	match corners:
		"bracket":
			_add(rows, "Frame", n_beams * 2, "pc", hw["corner_bracket"], "two per beam end")
			_add(rows, "Frame", n_beams * 4, "pc", hw["tnut_m5"], "two per bracket")
			_add(rows, "Frame", n_beams * 4, "pc", hw["bolt_m5"], "")
		"hidden":
			_add(rows, "Frame", n_beams * 2, "pc", hw["inside_corner"], "one per beam end")
			_add(rows, "Frame", n_beams * 2, "pc", hw["tnut_m5"], "")
			_add(rows, "Frame", n_beams * 2, "pc", hw["bolt_m5"], "")
		"plate":
			_add(rows, "Frame", int(ceil(n_beams * 0.8)), "pc", hw["gantry_plate"], "bolted corner plates")
			_add(rows, "Frame", n_beams * 6, "pc", hw["tnut_m5"], "")
			_add(rows, "Frame", n_beams * 6, "pc", hw["bolt_m5"], "")
	if bool(s["frame"]["feet"]):
		_add(rows, "Frame", 4 if kin != "delta" else 3, "pc", {"label": "Rubber foot M5", "usd": 1.5, "kg": 0.02}, "")
	# --- Guides and carriages per axis -------------------------------------
	var spans: Dictionary = lay["spans"]
	var axis_rail_m := {"x": float(spans.get("x_beam_m", 0.0)), "y": 2.0 * float(spans.get("y_rail_m", 0.0)), "z": 0.0}
	var axis_carriages := {"x": 1, "y": 2, "z": 2}
	match kin:
		"bedslinger", "corexz":
			axis_rail_m["z"] = 2.0 * float(spans.get("z_col_m", 0.0))
		"cartesian_xy", "corexy", "hbot":
			axis_rail_m["z"] = float(spans.get("z_col_m", 0.0)) * maxi(2, int(s["axis"]["z"]["motors"]))
			axis_carriages["z"] = maxi(2, int(s["axis"]["z"]["motors"]))
		"router":
			axis_rail_m["z"] = float(spans.get("z_plate_m", 0.2))
			axis_carriages["z"] = 1
		"delta":
			axis_rail_m = {"x": 0.0, "y": 0.0, "z": 3.0 * float(spans.get("z_col_m", 0.0))}
			axis_carriages = {"x": 0, "y": 0, "z": 3}
	for k in ["x", "y", "z"]:
		var g := GantryLabParts.guide(str(s["axis"][k]["guide"]))
		var n_car := int(axis_carriages[k])
		if n_car <= 0:
			continue
		var m := float(axis_rail_m[k])
		if float(g["kg_m"]) > 0.0 and m > 0.0:
			rows.append(_row("Motion", 1, "lot", "%s, %s axis" % [str(g["label"]), k.to_upper()], "%.2f m of rail" % m, m * float(g["usd_m"]), m * float(g["kg_m"])))
		if str(s["axis"][k]["guide"]) == "v_wheel":
			rows.append(_row("Motion", n_car, "pc", "V-wheel gantry plate, %s axis" % k.to_upper(), "with 3–4 Xtreme wheels + eccentric nuts", float(g["usd_carriage"]), float(g["kg_carriage"])))
		else:
			rows.append(_row("Motion", n_car, "pc", "%s carriage block, %s axis" % [str(g["label"]), k.to_upper()], "", float(g["usd_carriage"]), float(g["kg_carriage"])))
	# --- Drives -------------------------------------------------------------
	var belt_m := 0.0
	var belt_kind := ""
	var pulleys := 0
	var idlers := 0
	var shared := GantryLabKinematics.belt_length_m(kin, vx, vy, vz)
	var motor_total := 0
	var motor_rows: Dictionary = {}
	var axes_seen: Dictionary = {}
	for k in ["x", "y", "z"]:
		var a: Dictionary = s["axis"][k]
		var dr := GantryLabParts.drive(str(a["drive"]))
		var n_motor := int(a["motors"])
		if kin == "delta":
			if k != "z":
				continue
			n_motor = 3
		if (kin == "corexy" or kin == "hbot") and k == "y":
			continue
		if kin == "corexz" and k == "z":
			continue
		if k == "x" and (kin == "corexy" or kin == "hbot" or kin == "corexz"):
			n_motor = 2  # A and B
		var mkey := str(a["motor"])
		motor_rows[mkey] = int(motor_rows.get(mkey, 0)) + n_motor
		motor_total += n_motor
		var travel_mm := vx if k == "x" else (vy if k == "y" else vz)
		if kin == "bedslinger" and k == "y":
			travel_mm = vy
		match str(dr["kind"]):
			"belt":
				var m := 0.0
				if (kin == "corexy" or kin == "hbot") and k == "x":
					m = float(shared["each_m"]) * float(shared["count"])
					idlers += 8 if kin == "corexy" else 6
					pulleys += 2
				elif kin == "corexz" and k == "x":
					m = float(shared["each_m"]) * float(shared["count"])
					idlers += 8
					pulleys += 2
				elif kin == "delta":
					m = float(shared["each_m"]) * 3.0
					idlers += 3
					pulleys += 3
				else:
					m = (2.0 * travel_mm + 240.0) / 1000.0 * n_motor
					idlers += n_motor
					pulleys += n_motor
				belt_m += m
				belt_kind = str(dr["label"])
				rows.append(_row("Motion", 1, "lot", "%s, %s" % [str(dr["label"]), _axis_name(kin, k)], "%.2f m" % m, m * float(dr["usd_m"]), m * float(dr["kg_m"])))
			"screw":
				var len_m := (travel_mm + 120.0) / 1000.0
				if k == "z" and kin != "router":
					len_m = float(spans.get("z_col_m", 0.3))
				rows.append(_row("Motion", n_motor, "pc", "%s, %s axis" % [str(dr["label"]), k.to_upper()], "%.0f mm each" % (len_m * 1000.0), len_m * float(dr["usd_m"]), len_m * float(dr["kg_m"])))
				if str(a["drive"]).begins_with("ballscrew"):
					_add(rows, "Motion", n_motor, "pc", hw["ballscrew_nut"], "")
					_add(rows, "Motion", n_motor * 2, "pc", hw["bearing_block"], "BK/BF end supports")
				else:
					_add(rows, "Motion", n_motor, "pc", hw["anti_backlash_nut"], "")
				_add(rows, "Motion", n_motor, "pc", hw["coupler"], "motor to screw")
			"rack":
				var len_m := (travel_mm + 100.0) / 1000.0
				rows.append(_row("Motion", n_motor, "pc", "%s, %s axis" % [str(dr["label"]), k.to_upper()], "%.0f mm" % (len_m * 1000.0), len_m * float(dr["usd_m"]), len_m * float(dr["kg_m"])))
				rows.append(_row("Motion", n_motor, "pc", "Pinion + 3:1 reduction", "", 28.0, 0.15))
		axes_seen[k] = true
	if pulleys > 0:
		_add(rows, "Motion", pulleys, "pc", hw["pulley_gt2"], "%d-tooth on the motor shafts" % int(s["axis"]["x"]["pulley_teeth"]))
	if idlers > 0:
		_add(rows, "Motion", idlers, "pc", hw["idler_gt2"], "")
	# --- Motors and electronics --------------------------------------------
	for mkey in motor_rows:
		var m := GantryLabParts.motor(mkey)
		rows.append(_row("Electronics", int(motor_rows[mkey]), "pc", str(m["label"]), "%.1f A, %.0f steps/rev" % [float(m["amps"]), float(m["steps"])], float(m["usd"]), float(m["kg"])))
	var e: Dictionary = s["electronics"]
	var board := GantryLabParts.board(str(e["board"]))
	rows.append(_row("Electronics", 1, "pc", str(board["label"]), "%s · %s" % [str(board["mcu"]), str(GantryLabParts.FIRMWARE_LABELS.get(str(e["firmware"]), ""))], float(board["usd"]), 0.1))
	var extruder_motor := 1 if GantryLabSpec.is_additive(s) and str(s["tool"]["id"]) != "clay_extruder" else 0
	_add(rows, "Electronics", motor_total + extruder_motor, "pc", hw["driver_tmc2209"], "one per motor%s" % (" (+ extruder)" if extruder_motor > 0 else ""))
	if extruder_motor > 0:
		rows.append(_row("Electronics", 1, "pc", "NEMA 17 pancake extruder motor", "", 14.0, 0.15))
	# Power: motors at ~60 % of V·I each, the tool, the bed.
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var bed := GantryLabParts.bed(str(s["tool"]["bed"]))
	var bed_w := float(bed["watts_m2"]) * (vx * 0.001) * (vy * 0.001) * (1.0 if kin != "delta" else 0.785)
	var motor_w := 0.0
	for mkey in motor_rows:
		var m := GantryLabParts.motor(mkey)
		motor_w += int(motor_rows[mkey]) * float(e["volts"]) * float(m["amps"]) * 0.6
	var watts := motor_w + float(tool["watts"]) + bed_w + 15.0
	var psu_key := "psu_24v_350"
	var psu_w := 350.0
	if int(e["volts"]) == 48:
		psu_key = "psu_48v_600"
		psu_w = 600.0
	elif motor_w + bed_w + 15.0 > 300.0:
		psu_key = "psu_24v_600"
		psu_w = 600.0
	var dc_w := motor_w + bed_w + 15.0 + (float(tool["watts"]) if str(tool["process"]) != "subtractive" else 0.0)
	_add(rows, "Electronics", maxi(1, int(ceil(dc_w / psu_w))), "pc", hw[psu_key], "DC load %.0f W" % dc_w)
	if bed_w > 200.0 or str(tool["process"]) == "subtractive":
		_add(rows, "Electronics", 1, "pc", hw["ssr"], "bed heater" if bed_w > 200.0 else "spindle relay")
	var endstops := 3 if kin != "delta" else 3
	_add(rows, "Electronics", endstops, "pc", hw["endstop"], "")
	var wiring_m := (vx + vy + vz) * 0.001 * 2.0 + 3.0
	_add(rows, "Electronics", int(ceil(wiring_m * motor_total)), "m", hw["wiring_m"], "")
	if kin == "router" or vx > 400.0:
		_add(rows, "Electronics", int(ceil((vx + vy) * 0.001 + 0.5)), "m", hw["cable_chain_m"], "")
	# --- Tool and bed -------------------------------------------------------
	rows.append(_row("Tool", 1, "pc", str(tool["label"]), str(tool["note"]), float(tool["usd"]), float(tool["kg"])))
	var bed_area := (vx + 20.0) * 0.001 * (vy + 20.0) * 0.001
	if str(s["tool"]["bed"]) != "none":
		rows.append(_row("Tool", 1, "pc", "%s, %s" % [str(bed["label"]), GantryLabSpec.fmt_mm(vx) + " × " + GantryLabSpec.fmt_mm(vy)],
			("%.0f W" % bed_w) if bed_w > 0.0 else "", bed_area * float(bed["usd_m2"]), bed_area * float(bed["kg_m2"])))
	if kin == "delta":
		_add(rows, "Tool", 6, "pc", hw["delta_rod"], "%.0f mm centre to centre" % float(s["delta"]["arm_mm"]))
		_add(rows, "Tool", 1, "pc", hw["delta_effector"], "")
		_add(rows, "Tool", 3, "pc", hw["delta_carriage"], "")
	if bool(s["frame"]["enclosed"]):
		var dims: Vector3 = lay["dims"]
		var area := 2.0 * dims.y * dims.z + dims.x * dims.y + dims.x * dims.z
		rows.append(_row("Frame", 1, "lot", "Enclosure panels", "%.1f m² of acrylic / ACM" % area, area * float(hw["enclosure_panel_m2"]["usd"]), area * float(hw["enclosure_panel_m2"]["kg"])))
	# --- Totals -------------------------------------------------------------
	var usd := 0.0
	var kg := 0.0
	for r in rows:
		usd += float(r["usd"]) * float(r["qty"])
		kg += float(r["kg"]) * float(r["qty"])
	return {
		"rows": rows, "cut_list": cut_list, "stock": {"pieces": stock_pieces, "waste_pct": waste, "len_mm": STOCK_LEN_MM},
		"usd": usd, "kg": kg, "frame_kg": frame_kg, "extrusion_m": extrusion_m, "watts": watts,
		"motor_watts": motor_w, "bed_watts": bed_w, "tool_watts": float(tool["watts"]), "psu": psu_key, "psu_w": psu_w,
		"motors": motor_total + extruder_motor, "belt_m": belt_m, "belt_kind": belt_kind,
	}


static func _row(cat: String, qty: int, unit: String, item: String, detail: String, usd: float, kg: float) -> Dictionary:
	return {"cat": cat, "qty": qty, "unit": unit, "item": item, "detail": detail, "usd": usd, "kg": kg}


static func _add(rows: Array, cat: String, qty: int, unit: String, hw: Dictionary, detail: String) -> void:
	if qty <= 0:
		return
	rows.append(_row(cat, qty, unit, str(hw["label"]), detail, float(hw["usd"]), float(hw["kg"])))


static func _sum(a: Array) -> float:
	var t := 0.0
	for v in a:
		t += float(v)
	return t


static func _axis_name(kin: String, k: String) -> String:
	if (kin == "corexy" or kin == "hbot") and k == "x":
		return "A + B loops" if kin == "corexy" else "the H loop"
	if kin == "corexz" and k == "x":
		return "A + B loops"
	if kin == "delta":
		return "three towers"
	return "%s axis" % k.to_upper()


static func csv(bom: Dictionary) -> String:
	var lines: Array = ["category,qty,unit,item,detail,unit_usd,unit_kg,line_usd"]
	for r in bom["rows"]:
		lines.append("%s,%d,%s,\"%s\",\"%s\",%.2f,%.3f,%.2f" % [str(r["cat"]), int(r["qty"]), str(r["unit"]),
			str(r["item"]).replace("\"", "'"), str(r["detail"]).replace("\"", "'"), float(r["usd"]), float(r["kg"]), float(r["usd"]) * float(r["qty"])])
	lines.append(",,,TOTAL,,,%.3f,%.2f" % [float(bom["kg"]), float(bom["usd"])])
	return "\n".join(lines) + "\n"


static func cut_list_text(bom: Dictionary) -> String:
	var lines: Array = ["EXTRUSION CUT LIST (stock %.1f m, kerf %.0f mm)" % [float(bom["stock"]["len_mm"]) / 1000.0, KERF_MM], ""]
	for c in bom["cut_list"]:
		lines.append("%2d × %-14s %6.0f mm   %s" % [int(c["qty"]), str(GantryLabParts.profile(str(c["profile"]))["label"]), float(c["len_mm"]), str(c["label"])])
	lines.append("")
	lines.append("%d stock lengths, %.0f %% waste, %.2f m of extrusion, %.1f kg of frame" % [int(bom["stock"]["pieces"]), float(bom["stock"]["waste_pct"]), float(bom["extrusion_m"]), float(bom["frame_kg"])])
	return "\n".join(lines) + "\n"
