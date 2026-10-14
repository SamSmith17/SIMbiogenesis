class_name LinkageCoveringPlan
extends RefCounted
## The coverings cut plan (port of `js/linkage/coverings-plan.js`, A4): every
## plywood wall, table and the floor deck nested on stock sheets, every fabric
## band turned into a flat pattern, the shop totals, and the ENCLOSURE BOM
## rows. One structure's worth: a radial array multiplies it in LinkageBom.
##
## Pure. Inputs are the per-structure covering records (LinkageCoverings,
## LinkageFloor.deck) and the normalised coverings config.


## A price from the design's `costs` block (the enclosure prices ride
## `LinkageParams.extra`, web camelCase: plywoodSheet, fabricYard, grommet,
## shadeCloth), else the web default.
static func price(p: LinkageParams, key: String, def: float) -> float:
	var costs = p.extra.get("costs")
	if costs is Dictionary and ((costs as Dictionary).get(key) is float or (costs as Dictionary).get(key) is int):
		return float(costs[key])
	return def


static func set_price(p: LinkageParams, key: String, value: float) -> void:
	var costs = p.extra.get("costs")
	if not (costs is Dictionary):
		costs = {}
	(costs as Dictionary)[key] = value
	p.extra["costs"] = costs


static func _empty_totals() -> Dictionary:
	return {"walls": 0, "tables": 0, "floor_sheets": 0, "fabric_bands": 0, "sheets": 0,
		"full_sheets": 0, "cut_pieces": 0, "plywood_area_in2": 0.0, "stock_area_in2": 0.0,
		"seams": 0.0, "batten_linear_in": 0.0, "fabric_yards": 0.0, "fabric_area_in2": 0.0,
		"fabric_panels": 0, "grommets": 0, "warnings": 0, "utilization": 0.0}


## `computeCoveringCutPlan`. `cov_shapes` = one structure's covering shapes
## (walls, fabric, tables), `cov_cfg` = the normalised coverings config,
## `floor_deck` = the deck record or {}.
static func compute(cov_shapes: Array, cov_cfg: Dictionary, floor_deck: Dictionary = {}) -> Dictionary:
	if cov_shapes.is_empty() and floor_deck.is_empty():
		return {"walls": [], "tables": [], "fabric": [], "floor": {}, "totals": _empty_totals(), "stock": {}}
	var stock: Dictionary = (cov_cfg.get("sheet", LinkageCoverings.DEFAULTS["sheet"]) as Dictionary).duplicate()
	var walls: Array = []
	var tables: Array = []
	var fabric: Array = []
	var floor := {}
	if not floor_deck.is_empty():
		var fs := stock.duplicate()
		fs["thicknessIn"] = float(floor_deck["thickness_in"])
		floor = {"shape": floor_deck, "nest": LinkageSheetNesting.nest(floor_deck["corners_2d"], fs)}
	for shape in cov_shapes:
		match str(shape.get("kind", "")):
			"wall":
				walls.append({"shape": shape, "nest": LinkageSheetNesting.nest(shape["corners_2d"], stock)})
			"table":
				var ts := stock.duplicate()
				ts["thicknessIn"] = float((cov_cfg.get("table", {}) as Dictionary).get("thicknessIn", 0.75))
				tables.append({"shape": shape, "nest": LinkageSheetNesting.nest(shape["corners_2d"], ts)})
			"fabric":
				fabric.append({"shape": shape, "pattern": LinkageFabricPattern.build(shape["corners_2d"], cov_cfg.get("fabric", {}))})
	var order := func(a, b) -> bool:
		var sa := int(a["shape"]["span_index"])
		var sb := int(b["shape"]["span_index"])
		if sa != sb:
			return sa < sb
		return str(a["shape"]["band"]) < str(b["shape"]["band"])
	walls = LinkageCoverings._stable_sort(walls, order)
	tables = LinkageCoverings._stable_sort(tables, order)
	fabric = LinkageCoverings._stable_sort(fabric, order)
	var sheet_items: Array = walls + tables + ([floor] if not floor.is_empty() else [])
	var t := _empty_totals()
	t["walls"] = walls.size()
	t["tables"] = tables.size()
	t["floor_sheets"] = int(floor["nest"]["sheet_count"]) if not floor.is_empty() else 0
	t["fabric_bands"] = fabric.size()
	var ply_area := 0.0
	var stock_area := 0.0
	var batten := 0.0
	for w in sheet_items:
		var nest: Dictionary = w["nest"]
		t["sheets"] = int(t["sheets"]) + int(nest["sheet_count"])
		for pc in nest["pieces"]:
			if bool(pc["is_full_sheet"]):
				t["full_sheets"] = int(t["full_sheets"]) + 1
			else:
				t["cut_pieces"] = int(t["cut_pieces"]) + 1
		ply_area += float(nest["polygon_area_in2"])
		stock_area += float(nest["stock_area_in2"])
		t["seams"] = float(t["seams"]) + float(nest["seam_count"])
		batten += float(nest["seam_linear_in"])
		for wr in nest["warnings"]:
			if str(wr["code"]) != "batten":
				t["warnings"] = int(t["warnings"]) + 1
	t["plywood_area_in2"] = LinkageSheetNesting.rnd(ply_area, 1)
	t["stock_area_in2"] = LinkageSheetNesting.rnd(stock_area, 1)
	t["batten_linear_in"] = LinkageSheetNesting.rnd(batten, 1)
	var yards := 0.0
	var f_area := 0.0
	for f in fabric:
		var pat: Dictionary = f["pattern"]
		yards += float(pat["fabric_yards"])
		f_area += float(pat["area_in2"])
		t["fabric_panels"] = int(t["fabric_panels"]) + int(pat["panel_count"])
		t["grommets"] = int(t["grommets"]) + int(pat["grommet_count"])
	t["fabric_yards"] = LinkageSheetNesting.rnd(yards, 2)
	t["fabric_area_in2"] = LinkageSheetNesting.rnd(f_area, 1)
	t["utilization"] = LinkageSheetNesting.rnd(float(t["plywood_area_in2"]) / float(t["stock_area_in2"]), 3) if float(t["stock_area_in2"]) > 0.0 else 0.0
	return {"walls": walls, "tables": tables, "fabric": fabric, "floor": floor, "totals": t, "stock": stock,
		"fabric_cfg": (cov_cfg.get("fabric", {}) as Dictionary).duplicate(), "table_cfg": (cov_cfg.get("table", {}) as Dictionary).duplicate()}


## A web-style inch fraction, e.g. 22 3/16" (`formatInchesFraction`).
static func fmt_in(inches: float, denom: int = 16, unit: String = "\"") -> String:
	if is_nan(inches):
		return "—"
	var d := denom if denom in [2, 4, 8, 16, 32, 64] else 16
	var sign := "-" if inches < 0.0 else ""
	var a := absf(inches)
	var whole := int(floor(a))
	var num := int(roundf((a - whole) * d))
	if num == d:
		whole += 1
		num = 0
	var den := d
	while num > 0 and num % 2 == 0 and den % 2 == 0:
		num /= 2
		den /= 2
	if num == 0:
		return "%s%d%s" % [sign, whole, unit]
	if whole == 0:
		return "%s%d/%d%s" % [sign, num, den, unit]
	return "%s%d %d/%d%s" % [sign, whole, num, den, unit]


## ENCLOSURE BOM rows (`coveringBomItems`): plywood sheets, fabric yards,
## grommets.
static func bom_items(plan: Dictionary, p: LinkageParams) -> Array:
	var items: Array = []
	if plan.is_empty():
		return items
	var t: Dictionary = plan["totals"]
	if int(t["sheets"]) > 0:
		var s: Dictionary = plan["stock"]
		var what: PackedStringArray = []
		if int(t["walls"]) > 0:
			what.append("%d wall%s" % [int(t["walls"]), "" if int(t["walls"]) == 1 else "s"])
		if int(t["tables"]) > 0:
			what.append("%d table%s" % [int(t["tables"]), "" if int(t["tables"]) == 1 else "s"])
		if int(t["floor_sheets"]) > 0:
			what.append("floor deck")
		items.append(LinkageBom._line(int(t["sheets"]),
			"Plywood sheets %s × %s (%s)" % [fmt_in(float(s["widthIn"])), fmt_in(float(s["lengthIn"])), ", ".join(what)],
			price(p, "plywoodSheet", 45.0), 0.0, "enclosure", "plywood_sheet"))
	if float(t["fabric_yards"]) > 0.0:
		var yards := int(ceil(float(t["fabric_yards"])))
		items.append(LinkageBom._line(yards,
			"Fabric, %s roll (%d band%s, %d panel%s)" % [fmt_in(float(plan["fabric_cfg"].get("rollWidthIn", 60.0))),
				int(t["fabric_bands"]), "" if int(t["fabric_bands"]) == 1 else "s",
				int(t["fabric_panels"]), "" if int(t["fabric_panels"]) == 1 else "s"],
			price(p, "fabricYard", 8.0), 0.0, "enclosure", "fabric_yard"))
	if int(t["grommets"]) > 0:
		items.append(LinkageBom._line(int(t["grommets"]), "Grommets", price(p, "grommet", 0.25), 0.0, "enclosure", "grommet"))
	return items


## Title lines stamped on every cut file (`coveringFileLines`).
static func file_lines(shape: Dictionary, p: LinkageParams, extra: Array = []) -> Array:
	var out: Array = [
		"%s · %s" % [str(shape.get("label", "Covering")), "fabric" if str(shape.get("kind", "")) == "fabric" else "plywood"],
		"Cuts assume fold angle %.1f° · %d modules · %s" % [rad_to_deg(p.fold_angle), p.modules,
			Time.get_date_string_from_system()],
	]
	out.append_array(extra)
	return out


## The SVG for one plan entry (`coveringEntrySvg`): walls / tables / the deck
## → a full-scale sheet cut file, fabric → its pattern.
static func entry_svg(entry: Dictionary, p: LinkageParams) -> String:
	var shape: Dictionary = entry["shape"]
	if entry.has("pattern"):
		return LinkageSvgCutFile.fabric_pattern_svg(entry["pattern"], {
			"title": "%s fabric pattern" % str(shape.get("label", "")),
			"lines": file_lines(shape, p, ["Finished %s → %s × %s before shrink" % [
				fmt_in(float(shape["width_bottom_in"])), fmt_in(float(shape["width_top_in"])), fmt_in(float(shape["slant_height_in"]))]])})
	var nest: Dictionary = entry["nest"]
	var kind_word := "deep" if str(shape.get("kind", "")) == "table" else "slant"
	return LinkageSvgCutFile.sheet_cut_svg(nest, {
		"title": "%s sheet cuts" % str(shape.get("label", "")),
		"lines": file_lines(shape, p, [
			"Trapezoid %s bottom · %s top · %s %s · tilt %.1f°" % [fmt_in(float(shape.get("width_bottom_in", 0.0))),
				fmt_in(float(shape.get("width_top_in", 0.0))), fmt_in(float(shape.get("slant_height_in", 0.0))), kind_word,
				float(shape.get("tilt_from_vertical_deg", 0.0))],
			"%d sheet%s (%s), %d%% used" % [int(nest["sheet_count"]), "" if int(nest["sheet_count"]) == 1 else "s",
				str(nest["orientation"]), int(roundf(float(nest["utilization"]) * 100.0))]])})


## File name for an entry's cut file (`coveringEntryFilename`).
static func entry_filename(entry: Dictionary, prefix: String = "linkagelab") -> String:
	var s: Dictionary = entry["shape"]
	if str(s.get("band", "")) == "floor":
		return "%s-floor-deck.svg" % prefix
	var kind := "fabric" if str(s.get("kind", "")) == "fabric" else ("table" if str(s.get("kind", "")) == "table" else "wall")
	return "%s-span%d-%s-%s.svg" % [prefix, int(s.get("span_index", 0)) + 1, str(s.get("band", "")), kind]


## Every plan entry in shop order: walls, tables, the deck, fabric.
static func entries(plan: Dictionary) -> Array:
	var out: Array = []
	out.append_array(plan.get("walls", []))
	out.append_array(plan.get("tables", []))
	if not (plan.get("floor", {}) as Dictionary).is_empty():
		out.append(plan["floor"])
	out.append_array(plan.get("fabric", []))
	return out
