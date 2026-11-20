class_name BankExport
extends RefCounted

## Files for building a bank: the bill of materials (CSV), a single-line
## drawing (SVG: each string's packs in series, its fuse, the bus, the
## disconnect and the run to the inverter, every cable labelled with its
## gauge and length), the cable list (CSV) and the design (JSON).

const DIR := "user://batterylab_designs"


static func slug(name: String) -> String:
	var out := ""
	for ch in name.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	return out.trim_prefix("_").trim_suffix("_").left(48)


## Write every file under `dir` (default user://batterylab_designs/<name>/);
## returns the paths written.
static func write_all(d: Dictionary, dir: String = "") -> Array:
	var b: Dictionary = d["spec"]
	if dir.is_empty():
		dir = "%s/%s" % [DIR, slug(str(b["name"]))]
	DirAccess.make_dir_recursive_absolute(dir)
	var out: Array = []
	for f in [["bom.csv", BattBom.csv(d["bom"])], ["cables.csv", cables_csv(d)],
			["single_line.svg", single_line_svg(d)], ["bank.json", JSON.stringify(_json(d), "\t")]]:
		var p := "%s/%s" % [dir, f[0]]
		var fa := FileAccess.open(p, FileAccess.WRITE)
		if fa == null:
			continue
		fa.store_string(str(f[1]))
		out.append(p)
	return out


static func cables_csv(d: Dictionary) -> String:
	var lines := PackedStringArray(["id,from_to,length_m,gauge,mm2,amps,drop_pct,colour"])
	for cb in (d["cables"] as Array):
		lines.append("%s,%s,%.2f,%s,%.1f,%.0f,%.2f,%s" % [cb["id"], BattBom._q(str(cb["label"])),
			float(cb["len_mm"]) * 0.001, cb["gauge"], float(cb["mm2"]), float(cb["amps"]), float(cb["drop_pct"]), cb["color"]])
	return "\n".join(lines)


static func _json(d: Dictionary) -> Dictionary:
	var e: Dictionary = d["electrical"]
	var cables: Array = []
	for cb in (d["cables"] as Array):
		cables.append({"id": cb["id"], "label": cb["label"], "length_m": snappedf(float(cb["len_mm"]) * 0.001, 0.01),
			"gauge": cb["gauge"], "amps": snappedf(float(cb["amps"]), 0.1)})
	return {"bank": d["spec"], "electrical": {"v_nom": e["v_nom"], "ah": e["ah"], "kwh": float(e["wh"]) * 0.001,
		"cont_discharge_a": e["cont_discharge_a"], "fault_current_a": e["i_sc"]},
		"fuse": d["fuse"], "cables": cables, "checks": d["checks"]}


## A single-line drawing: strings left to right, packs top (+) to bottom (−).
static func single_line_svg(d: Dictionary) -> String:
	var N := int(d["series"])
	var M := int(d["parallel"])
	var pe: Dictionary = (d["pack"] as Dictionary)["electrical"]
	var fuse: Dictionary = d["fuse"]
	var col_w := 150.0
	var pack_h := 54.0
	var top := 110.0
	var w := maxf(520.0, 80.0 + col_w * float(M) + 220.0)
	var h := top + float(N) * (pack_h + 30.0) + 170.0
	var s := PackedStringArray()
	s.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="sans-serif" font-size="12">' % [w, h, w, h])
	s.append('<rect width="100%%" height="100%%" fill="#ffffff"/>')
	s.append('<text x="20" y="28" font-size="16" font-weight="bold">%s</text>' % _x(str((d["spec"] as Dictionary)["name"])))
	var e: Dictionary = d["electrical"]
	s.append('<text x="20" y="48">%d × %d packs · %.1f V · %.0f Ah · %.1f kWh · %.0f A continuous</text>' % [N, M,
		float(e["v_nom"]), float(e["ah"]), float(e["wh"]) * 0.001, float(e["cont_discharge_a"])])
	var bus_p := 78.0
	var bus_n := top + float(N) * (pack_h + 30.0) + 40.0
	var x0 := 60.0
	var x1 := x0 + col_w * float(M - 1) + 60.0
	s.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#c0392b" stroke-width="5"/>' % [x0 - 20, bus_p, x1 + 120, bus_p])
	s.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#222" stroke-width="5"/>' % [x0 - 20, bus_n, x1 + 120, bus_n])
	s.append('<text x="%d" y="%d">+ bus</text><text x="%d" y="%d">− bus</text>' % [x1 + 128, bus_p + 4, x1 + 128, bus_n + 4])
	var cab := {}
	for cb in (d["cables"] as Array):
		cab[str(cb["id"])] = cb
	for j in M:
		var cx := x0 + col_w * float(j) + 30.0
		var y := top
		var cp: Dictionary = cab.get("str_pos_%d" % j, {})
		s.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#c0392b" stroke-width="2"/>' % [cx, bus_p, cx, y])
		if not fuse.is_empty():
			s.append('<rect x="%d" y="%d" width="22" height="12" fill="#f4d03f" stroke="#333"/>' % [cx - 11, bus_p + 8])
			s.append('<text x="%d" y="%d" font-size="10">%s %.0f A</text>' % [cx + 14, bus_p + 18, _x(str(fuse["label"])), float(fuse["amps"])])
		if not cp.is_empty():
			s.append('<text x="%d" y="%d" font-size="10" fill="#c0392b">%s %.1f m</text>' % [cx + 14, y - 6, _x(str(cp["gauge"])), float(cp["len_mm"]) * 0.001])
		for k in N:
			s.append('<rect x="%d" y="%d" width="60" height="%d" fill="#eef2f7" stroke="#333"/>' % [cx - 30, y, pack_h])
			s.append('<text x="%d" y="%d" text-anchor="middle">%.1f V</text>' % [cx, y + 22, float(pe["v_nom"])])
			s.append('<text x="%d" y="%d" text-anchor="middle" font-size="10">%.0f Ah</text>' % [cx, y + 38, float(pe["ah"])])
			s.append('<text x="%d" y="%d" font-size="11" fill="#c0392b">+</text>' % [cx - 40, y + 12])
			s.append('<text x="%d" y="%d" font-size="11">−</text>' % [cx - 40, y + pack_h - 2])
			y += pack_h
			if k < N - 1:
				var sc: Dictionary = cab.get("series_%d_%d" % [j, k], {})
				s.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#222" stroke-width="2"/>' % [cx, y, cx, y + 30])
				if not sc.is_empty():
					s.append('<text x="%d" y="%d" font-size="10">%s %.1f m</text>' % [cx + 6, y + 19, _x(str(sc["gauge"])), float(sc["len_mm"]) * 0.001])
				y += 30
		s.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#222" stroke-width="2"/>' % [cx, y, cx, bus_n])
		var cn: Dictionary = cab.get("str_neg_%d" % j, {})
		if not cn.is_empty():
			s.append('<text x="%d" y="%d" font-size="10">%s %.1f m</text>' % [cx + 6, bus_n - 8, _x(str(cn["gauge"])), float(cn["len_mm"]) * 0.001])
	var inv_x := x1 + 60
	var mp: Dictionary = cab.get("main_pos", {})
	s.append('<rect x="%d" y="%d" width="90" height="%d" fill="#e8f6ef" stroke="#333"/>' % [inv_x, bus_p + 40, bus_n - bus_p - 80])
	s.append('<text x="%d" y="%d" text-anchor="middle">Inverter</text>' % [inv_x + 45, (bus_p + bus_n) * 0.5])
	if bool((d["spec"] as Dictionary)["disconnect"]):
		s.append('<text x="%d" y="%d" font-size="10">disconnect</text>' % [inv_x + 4, bus_p + 34])
	if not mp.is_empty():
		s.append('<text x="%d" y="%d" font-size="10" fill="#c0392b">%s, %.1f m each way</text>' % [inv_x - 40, bus_p - 8, _x(str(mp["gauge"])), float(mp["len_mm"]) * 0.001])
	s.append('<text x="20" y="%d" font-size="10" fill="#666">Battery Lab · lengths include %d mm at each lug · prices and some ratings are estimates</text>' % [h - 14, int(BankDesign.LUG_SLACK_MM)])
	s.append("</svg>")
	return "\n".join(s)


static func _x(t: String) -> String:
	return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
