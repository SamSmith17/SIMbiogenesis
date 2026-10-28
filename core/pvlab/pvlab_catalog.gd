class_name PvLabCatalog
extends RefCounted

## Real modules for the Solar designer, from their makers' data sheets:
## size, mass, cell count and cut, build, frame and backsheet, the STC
## nameplate (Pmax, Voc, Vmp, Isc, Imp) and the temperature coefficients.
## Pure data plus a search and a builder that lays each one's cells out so
## the twin looks like the real module.
##
## Values were transcribed from each maker's published data sheet for the
## named model and power class; a module sold today may be a later revision.
## Check the label on the back of your own panel — the Panel tab's data
## sheet fields are where to correct a number. The selftest holds every
## entry to Vmp × Imp ≈ Pmax (2 %), Voc > Vmp, Isc > Imp and a believable
## efficiency, which is what catches a mistyped digit.
##
## Each entry: [id, maker, model, type, tech, cut, cols, rows (pieces),
##   w, h, t (mm), kg, Pmax, Voc, Vmp, Isc, Imp, Voc %/°C, Pmax %/°C,
##   Isc %/°C, NOCT °C, frame, sheet front, busbars]

const ENTRIES := [
	["ja_jam60s20_380", "JA Solar", "JAM60S20-380/MR", "rigid", "mono_perc", "half", 6, 20,
		1052.0, 1769.0, 35.0, 20.5, 380.0, 41.62, 34.77, 11.47, 10.93, -0.272, -0.35, 0.044, 45.0, "silver", "white", 9],
	["ja_jam54s30_410", "JA Solar", "JAM54S30-410/MR", "rigid", "mono_perc", "half", 6, 18,
		1134.0, 1722.0, 30.0, 21.5, 410.0, 37.32, 31.21, 13.95, 13.14, -0.275, -0.35, 0.045, 45.0, "silver", "white", 10],
	["ja_jam72s20_450", "JA Solar", "JAM72S20-450/MR", "rigid", "mono_perc", "half", 6, 24,
		1052.0, 2120.0, 40.0, 24.7, 450.0, 49.70, 41.52, 11.36, 10.84, -0.272, -0.35, 0.044, 45.0, "silver", "white", 9],
	["longi_lr5_54hph_410", "LONGi", "Hi-MO 5m LR5-54HPH-410M", "rigid", "mono_perc", "half", 6, 18,
		1134.0, 1722.0, 30.0, 21.5, 410.0, 37.45, 31.30, 13.87, 13.10, -0.265, -0.34, 0.050, 45.0, "silver", "white", 9],
	["longi_lr5_72hph_545", "LONGi", "Hi-MO 5 LR5-72HPH-545M", "rigid", "mono_perc", "half", 6, 24,
		1134.0, 2256.0, 35.0, 27.2, 545.0, 49.65, 41.80, 13.92, 13.04, -0.265, -0.34, 0.050, 45.0, "silver", "white", 9],
	["cs_cs6r_400ms", "Canadian Solar", "HiKu6 CS6R-400MS", "rigid", "mono_perc", "half", 6, 18,
		1134.0, 1722.0, 30.0, 21.3, 400.0, 37.0, 30.8, 13.85, 12.99, -0.26, -0.34, 0.050, 42.0, "silver", "white", 10],
	["cs_cs3w_400p", "Canadian Solar", "HiKu CS3W-400P", "rigid", "poly", "half", 6, 24,
		1048.0, 2108.0, 40.0, 24.9, 400.0, 47.2, 39.0, 10.90, 10.26, -0.29, -0.37, 0.050, 42.0, "silver", "white", 5],
	["cs_cs6k_300ms", "Canadian Solar", "CS6K-300MS", "rigid", "mono_perc", "full", 6, 10,
		992.0, 1650.0, 40.0, 18.2, 300.0, 39.7, 32.5, 9.83, 9.24, -0.29, -0.39, 0.050, 44.0, "silver", "white", 5],
	["cs_cs7n_660mb_ag", "Canadian Solar", "BiHiKu7 CS7N-660MB-AG (bifacial)", "glass_glass", "mono_perc", "half", 6, 22,
		1303.0, 2384.0, 35.0, 38.1, 660.0, 45.6, 38.5, 18.42, 17.15, -0.26, -0.34, 0.050, 41.0, "silver", "clear", 12],
	["trina_de09_400", "Trina Solar", "Vertex S TSM-DE09.08 400W", "rigid", "mono_perc", "half", 6, 20,
		1096.0, 1754.0, 30.0, 21.0, 400.0, 41.2, 34.2, 12.28, 11.70, -0.25, -0.34, 0.040, 43.0, "black", "white", 12],
	["trina_deg21c_660", "Trina Solar", "Vertex TSM-DEG21C.20 660W (bifacial)", "glass_glass", "mono_perc", "half", 6, 22,
		1303.0, 2384.0, 35.0, 38.7, 660.0, 45.9, 38.1, 18.45, 17.33, -0.25, -0.34, 0.040, 43.0, "silver", "clear", 12],
	["jinko_jkm540m_72hl4", "Jinko Solar", "Tiger Pro JKM540M-72HL4-V", "rigid", "mono_perc", "half", 6, 24,
		1134.0, 2274.0, 35.0, 28.9, 540.0, 49.42, 41.29, 13.85, 13.08, -0.28, -0.35, 0.048, 45.0, "silver", "white", 9],
	["jinko_jkm420n_54hl4b", "Jinko Solar", "Tiger Neo JKM420N-54HL4-B (all black)", "rigid", "topcon", "half", 6, 18,
		1134.0, 1722.0, 30.0, 22.0, 420.0, 38.82, 32.08, 13.71, 13.09, -0.25, -0.29, 0.045, 45.0, "black", "black", 16],
	["qcells_peak_g10_400", "Qcells", "Q.PEAK DUO BLK ML-G10+ 400", "rigid", "mono_perc", "half", 6, 22,
		1045.0, 1879.0, 32.0, 22.0, 400.0, 45.30, 37.13, 11.14, 10.77, -0.27, -0.34, 0.040, 43.0, "black", "black", 12],
	["rec_alpha_pure_410", "REC", "Alpha Pure REC410AA", "rigid", "hjt", "half", 6, 22,
		1016.0, 1821.0, 30.0, 20.5, 410.0, 48.5, 41.2, 10.25, 9.96, -0.24, -0.26, 0.040, 44.0, "black", "white", 16],
	["sunpower_max3_400", "SunPower / Maxeon", "Maxeon 3 SPR-MAX3-400", "rigid", "ibc", "full", 8, 13,
		1046.0, 1690.0, 40.0, 19.0, 400.0, 75.6, 65.8, 6.58, 6.08, -0.236, -0.29, 0.058, 42.0, "black", "black", 0],
	["sunpower_x22_360", "SunPower / Maxeon", "X22-360", "rigid", "ibc", "full", 8, 12,
		1046.0, 1559.0, 46.0, 18.6, 360.0, 69.5, 60.6, 6.48, 5.94, -0.235, -0.29, 0.058, 41.5, "black", "black", 0],
	["panasonic_n330", "Panasonic", "HIT N330 VBHN330SA17", "rigid", "hjt", "full", 8, 12,
		1053.0, 1590.0, 40.0, 18.5, 330.0, 69.7, 58.0, 6.07, 5.70, -0.235, -0.258, 0.033, 44.0, "black", "white", 4],
	["lg_neon2_350", "LG", "NeON 2 LG350N1C-V5", "rigid", "topcon", "full", 6, 10,
		1016.0, 1686.0, 40.0, 17.1, 350.0, 41.1, 35.0, 10.80, 10.0, -0.27, -0.36, 0.030, 44.0, "black", "white", 12],
	["lg_neonr_370", "LG", "NeON R LG370Q1C-A5", "rigid", "ibc", "full", 6, 10,
		1016.0, 1700.0, 40.0, 18.5, 370.0, 42.8, 37.0, 10.82, 10.01, -0.24, -0.29, 0.040, 44.0, "black", "black", 0],
	["firstsolar_fs6420", "First Solar", "Series 6 FS-6420", "thin_film", "cdte", "strip", 1, 264,
		1232.0, 2009.0, 49.0, 34.5, 420.0, 219.2, 180.5, 2.54, 2.33, -0.28, -0.32, 0.04, 45.0, "black", "black", 0],
]


## Every entry as a dictionary.
static func all() -> Array:
	var out: Array = []
	for e in ENTRIES:
		out.append(entry(e))
	return out


static func entry(e: Array) -> Dictionary:
	return {"id": str(e[0]), "maker": str(e[1]), "model": str(e[2]), "type": str(e[3]), "tech": str(e[4]),
		"cut": str(e[5]), "cols": int(e[6]), "rows": int(e[7]), "w": float(e[8]), "h": float(e[9]),
		"t": float(e[10]), "kg": float(e[11]), "wmp": float(e[12]), "voc": float(e[13]), "vmp": float(e[14]),
		"isc": float(e[15]), "imp": float(e[16]), "voc_coeff": float(e[17]), "pmax_coeff": float(e[18]),
		"isc_coeff": float(e[19]), "noct_c": float(e[20]), "frame": str(e[21]), "sheet": str(e[22]),
		"busbars": int(e[23])}


static func by_id(id: String) -> Dictionary:
	for e in ENTRIES:
		if str(e[0]) == id:
			return entry(e)
	return {}


## One line for a list: "JA Solar JAM54S30-410/MR — 410 W · 1722 × 1134 mm".
static func label(e: Dictionary) -> String:
	return "%s %s — %.0f W · %.0f × %.0f mm" % [str(e["maker"]), str(e["model"]), float(e["wmp"]),
		float(e["h"]), float(e["w"])]


static func tooltip(e: Dictionary) -> String:
	return ("%s %s\n%.0f W: Voc %.2f V, Vmp %.2f V, Isc %.2f A, Imp %.2f A\n%d %s %s cells · %.0f × %.0f × %.0f mm · %.1f kg\n" +
		"Voc %.3f %%/°C, Pmax %.3f %%/°C, NOCT %.0f °C · %s frame, %s backsheet") % [str(e["maker"]),
		str(e["model"]), float(e["wmp"]), float(e["voc"]), float(e["vmp"]), float(e["isc"]), float(e["imp"]),
		int(e["cols"]) * int(e["rows"]) if str(e["cut"]) != "strip" else int(e["rows"]),
		str((PvLabCells.CUTS[str(e["cut"])] as Dictionary)["label"]).to_lower(),
		str(PvLabCells.tech(str(e["tech"]))["label"]), float(e["h"]), float(e["w"]), float(e["t"]), float(e["kg"]),
		float(e["voc_coeff"]), float(e["pmax_coeff"]), float(e["noct_c"]), str(e["frame"]), str(e["sheet"])]


## The words a search matches against.
static func haystack(e: Dictionary) -> String:
	return ("%s %s %s %s %s %.0fw %.0f w %.0f×%.0f %s %s" % [str(e["maker"]), str(e["model"]), str(e["type"]),
		str(e["tech"]), str(PvLabCells.tech(str(e["tech"]))["label"]), float(e["wmp"]), float(e["wmp"]),
		float(e["h"]), float(e["w"]), str(e["frame"]), "bifacial" if str(e["type"]) == "glass_glass" else ""]).to_lower()


## Entries matching every word of `query` (any order; "" = all).
static func search(query: String) -> Array:
	var words := query.to_lower().strip_edges().split(" ", false)
	var out: Array = []
	for e in all():
		var hs := haystack(e)
		var ok := true
		for wd in words:
			if not hs.contains(wd):
				ok = false
				break
		if ok:
			out.append(e)
	return out


## True when `text` matches every word of `query`.
static func matches(text: String, query: String) -> bool:
	var hs := text.to_lower()
	for wd in query.to_lower().strip_edges().split(" ", false):
		if not hs.contains(wd):
			return false
	return true


## The module twin of an entry: its type's build, its size, its cells laid
## out to fill the face (a standard wafer when one fits the measured pitch,
## else that pitch), its data sheet nameplate and coefficients.
static func module_spec(e: Dictionary) -> Dictionary:
	var base := PvLabModule.type_patch({"name": "%s %s" % [str(e["maker"]), str(e["model"])]}, str(e["type"]))
	base["maker"] = str(e["maker"])
	base["dims_mm"] = {"w": float(e["w"]), "h": float(e["h"]), "t": float(e["t"])}
	var fr: Dictionary = base["frame"]
	if fr["style"] in ["black", "silver"]:
		fr["style"] = str(e["frame"]) if str(e["frame"]) in ["black", "silver"] else "silver"
		fr["height_mm"] = float(e["t"])
	base["backsheet"] = {"front": str(e["sheet"]), "back": str(e["sheet"]) if str(e["sheet"]) == "clear" else
		("black" if str(e["sheet"]) == "black" else "white")}
	var c: Dictionary = base["cells"]
	c["tech"] = str(e["tech"])
	c["cut"] = str(e["cut"])
	c["cols"] = int(e["cols"])
	c["rows"] = int(e["rows"])
	c["busbars"] = int(e["busbars"])
	c["parallel"] = 0
	var cut := str(e["cut"])
	if cut == "strip":
		c["gap_mm"] = 0.2
	else:
		c["gap_mm"] = 2.0
		var pieces := int((PvLabCells.CUTS[cut] as Dictionary)["pieces"])
		var paths := int((PvLabCells.CUTS[cut] as Dictionary)["parallel"])
		var cols := int(e["cols"])
		var rows := int(e["rows"])
		var split := float(c.get("split_gap_mm", 6.0)) * float(paths - 1) if paths > 1 else 0.0
		# The largest standard wafer whose grid leaves a 7–25 mm frame lip
		# (less a 2 mm border); the frame lip is then what is left.
		var best := ""
		var best_lip := 0.0
		for fid in PvLabCells.FORMAT_ORDER:
			if fid == "custom":
				continue
			var ed := PvLabCells.format_edge_mm(str(fid))
			var gw := ed * cols + 2.0 * float(cols - 1)
			var gl := ed / float(pieces) * rows + 2.0 * float(rows - 1) + split
			var lip := minf((float(e["w"]) - gw) * 0.5, (float(e["h"]) - gl) * 0.5) - 2.0
			if lip >= 7.0 and lip <= 25.0 and (best.is_empty() or ed > PvLabCells.format_edge_mm(best)):
				best = str(fid)
				best_lip = lip
		if best.is_empty():
			c["format"] = "custom"
			var across := (float(e["w"]) - 2.0 * 14.0 - 4.0 - 2.0 * float(cols - 1)) / float(cols)
			var along_edge := (float(e["h"]) - 2.0 * 14.0 - 4.0 - split - 2.0 * float(rows - 1)) / float(rows) * float(pieces)
			c["custom_edge_mm"] = snappedf(minf(across, along_edge), 0.25)
		else:
			c["format"] = best
			if fr["style"] in ["black", "silver"]:
				fr["width_mm"] = minf(14.0, floorf(best_lip))
				fr["overlap_mm"] = minf(4.0, float(fr["width_mm"]) * 0.4)
	base["cells"] = c
	base["bypass_diodes"] = 0 if str(e["type"]) == "thin_film" else 3
	base["electrical"] = {"mode": "datasheet", "wmp": float(e["wmp"]), "voc": float(e["voc"]), "vmp": float(e["vmp"]),
		"isc": float(e["isc"]), "imp": float(e["imp"]), "voc_coeff": float(e["voc_coeff"]),
		"pmax_coeff": float(e["pmax_coeff"]), "isc_coeff": float(e["isc_coeff"]), "noct_c": float(e["noct_c"]),
		"mass_kg": float(e["kg"]), "bifaciality": 0.7 if str(e["type"]) == "glass_glass" else 0.0}
	return PvLabModule.resolve(base)
