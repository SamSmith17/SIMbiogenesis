class_name PvLabModule
extends RefCounted

## One solar MODULE (a panel) in the Solar designer: its physical build and
## its electrics, resolved over defaults so every reader gets a complete
## dictionary. Pure.
##
## Panel frame (what the builder, the shader and the shading samples share):
## the face is the local XZ plane, its normal +Y; X runs across the panel's
## WIDTH (the short side), Z along its LENGTH. u ∈ [−0.5, 0.5] across, v ∈
## [−0.5, 0.5] along. Row 0 of the cell grid is at v = −0.5, the "top" edge
## where a top junction box sits; mounted on a tilted rack that edge is the
## up-slope one (local −Z after the tilt about +X, as SolarArrayBuilder).
##
## {
##   version, name, maker,
##   type:      "rigid" | "glass_glass" | "flexible" | "thin_film" | "folding"
##   dims_mm:   {w (short side), h (long side), t}
##   cells:     {tech: PvLabCells.TECHS id, format: FORMATS id, custom_edge_mm,
##               cut: CUTS id, cols (across), rows (along) — counts of cell
##               PIECES, gap_mm (between pieces), split_gap_mm (the extra gap
##               between the halves of a split module), busbars, finger_pitch_mm,
##               chamfer_mm (−1 = from the wafer format), parallel (0 = from
##               the cut)}
##   frame:     {style: "black" | "silver" | "none" | "clips" | "fabric",
##               height_mm (profile depth), width_mm (face lip: how much of
##               the face the frame shows), overlap_mm (how far the lip
##               reaches over the glass, which sits in its channel),
##               lip_mm (how far the lip stands proud of the glass)}
##   corner_r_mm: the laminate's corner radius (−1 = by type: flexible and
##               folding modules have rounded corners, glass ones square)
##   backsheet: {front: what shows between the cells — "white" | "black" |
##               "clear" | "silver", back: the rear face}
##   glass:     "ar" | "textured" | "etfe" | "pet"
##   jbox:      {layout: "top" | "split3" | "center" | "corner", leads_mm (each
##               lead), connector: CONNECTORS id, exit: "top" | "side"}
##   bypass_diodes: 0..6
##   folding:   {leaves, hinge_mm, kickstands}
##   look:      {cell_color: Color or null (the tech's), sheen, flake,
##               grid_color (busbar / finger tint)}
##   electrical:{mode: "derived" | "datasheet", wmp, voc, vmp, isc, imp,
##               voc_coeff, isc_coeff, pmax_coeff (%/°C), noct_c,
##               max_system_v, bifaciality, mass_kg (0 = estimated)}
##   shade_samples: 1 | 2 (shading samples per current path)
## }

const VERSION := 1

const TYPES := ["rigid", "glass_glass", "flexible", "thin_film", "folding"]
const TYPE_LABELS := {"rigid": "Rigid (glass + backsheet, framed)", "glass_glass": "Glass–glass (bifacial)",
	"flexible": "Flexible laminate", "thin_film": "Thin film (glass, frameless)", "folding": "Folding / portable"}
const FRAME_STYLES := ["black", "silver", "none", "clips", "fabric"]
const FRAME_LABELS := {"black": "Black anodised aluminium", "silver": "Bare (clear anodised) aluminium",
	"none": "Frameless", "clips": "Frameless with edge clips", "fabric": "Fabric case (folding)"}
const SHEETS := ["white", "black", "clear", "silver"]
const SHEET_COLORS := {"white": Color(0.88, 0.89, 0.9), "black": Color(0.03, 0.03, 0.035),
	"clear": Color(0.55, 0.62, 0.66), "silver": Color(0.7, 0.72, 0.74)}
const GLASSES := ["ar", "textured", "etfe", "pet"]
const GLASS_LABELS := {"ar": "Tempered glass, AR coated", "textured": "Textured (prismatic) glass",
	"etfe": "ETFE film (textured)", "pet": "PET film (glossy)"}
const JBOX_LAYOUTS := ["top", "split3", "center", "corner"]
const JBOX_LABELS := {"top": "One box at the top edge", "split3": "Three split boxes across the middle",
	"center": "One box in the middle", "corner": "One box in a top corner"}
const CONNECTORS := {
	"mc4": {"label": "MC4", "color": Color(0.05, 0.05, 0.05)},
	"mc4_evo2": {"label": "MC4-Evo 2", "color": Color(0.06, 0.06, 0.07)},
	"anderson": {"label": "Anderson Powerpole", "color": Color(0.75, 0.08, 0.06)},
	"xt60": {"label": "XT60", "color": Color(0.9, 0.75, 0.1)},
	"sae": {"label": "SAE 2-pin", "color": Color(0.05, 0.05, 0.05)},
	"bare": {"label": "Bare leads", "color": Color(0.7, 0.45, 0.25)},
}
const CONNECTOR_ORDER := ["mc4", "mc4_evo2", "anderson", "xt60", "sae", "bare"]

## Areal mass (kg/m²) by build, from data sheets: JA JAM60S20 20.5 kg over
## 1.861 m² (rigid, 11.0); bifacial glass–glass 72-cell 25 kg over 1.93 m²
## (13.0); First Solar Series 6 34.5 kg over 2.47 m² (14.0); a 100 W
## semi-flexible 1.8 kg over 0.62 m² (2.9); a 200 W folding case 7.3 kg over
## 1.5 m² unfolded (4.9).
const AREAL_KG := {"rigid": 11.0, "glass_glass": 13.0, "thin_film": 14.0, "flexible": 2.9, "folding": 4.9}

const CELL_DEFAULTS := {"tech": "mono_perc", "format": "m10", "custom_edge_mm": 156.0, "cut": "half",
	"cols": 6, "rows": 20, "gap_mm": 2.0, "split_gap_mm": 6.0, "busbars": 9, "finger_pitch_mm": 1.4,
	"chamfer_mm": -1.0, "parallel": 0}
const FRAME_DEFAULTS := {"style": "black", "height_mm": 30.0, "width_mm": 14.0, "overlap_mm": 4.0, "lip_mm": 1.8}

## What switching a module's TYPE changes, so a flexible module comes out
## thin, frameless and filmed rather than a rigid one with a new label. Data
## sheet builds: a framed glass module is 30–40 mm deep with a 1.8 mm lip
## over the glass; glass–glass bifacials are framed thinner with clear sheets
## and 2 mm glass both sides; semi-flexible laminates are 2–3 mm with an
## ETFE top film and rounded corners; CdTe is a frameless glass–glass
## laminate held by clips (First Solar's older series); folding cases are
## fabric with ETFE leaves.
const TYPE_PATCH := {
	"rigid": {"dims_mm": {"t": 35.0}, "frame": {"style": "silver", "height_mm": 35.0, "width_mm": 14.0},
		"glass": "ar", "backsheet": {"front": "white", "back": "white"}, "electrical": {"bifaciality": 0.0},
		"bypass_diodes": 3},
	"glass_glass": {"dims_mm": {"t": 30.0}, "frame": {"style": "silver", "height_mm": 30.0, "width_mm": 11.0},
		"glass": "ar", "backsheet": {"front": "clear", "back": "clear"}, "electrical": {"bifaciality": 0.7},
		"bypass_diodes": 3},
	"flexible": {"dims_mm": {"t": 2.5}, "frame": {"style": "none"}, "glass": "etfe",
		"backsheet": {"front": "white", "back": "white"}, "jbox": {"layout": "top"}, "electrical": {"bifaciality": 0.0}},
	"thin_film": {"dims_mm": {"t": 6.8}, "frame": {"style": "clips"}, "glass": "ar",
		"backsheet": {"front": "black", "back": "black"}, "jbox": {"layout": "center"}, "bypass_diodes": 0,
		"electrical": {"bifaciality": 0.0}},
	"folding": {"dims_mm": {"t": 4.0}, "frame": {"style": "fabric", "height_mm": 6.0, "width_mm": 16.0},
		"glass": "etfe", "backsheet": {"front": "black", "back": "black"},
		"jbox": {"layout": "corner", "connector": "anderson"}, "electrical": {"bifaciality": 0.0}},
}
const BACK_DEFAULTS := {"front": "white", "back": "white"}
const JBOX_DEFAULTS := {"layout": "split3", "leads_mm": 1200.0, "connector": "mc4", "exit": "top"}
const FOLD_DEFAULTS := {"leaves": 4, "hinge_mm": 18.0, "kickstands": 2}
const LOOK_DEFAULTS := {"cell_color": null, "sheen": 1.0, "flake": 1.0, "grid_color": Color(0.78, 0.8, 0.83)}
const ELEC_DEFAULTS := {"mode": "derived", "wmp": 0.0, "voc": 0.0, "vmp": 0.0, "isc": 0.0, "imp": 0.0,
	"voc_coeff": NAN, "isc_coeff": NAN, "pmax_coeff": NAN, "noct_c": NAN, "max_system_v": 1000.0,
	"bifaciality": 0.0, "mass_kg": 0.0}


static func default_spec() -> Dictionary:
	return resolve({"name": "Solar module"})


static func resolve(spec: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	s["version"] = VERSION
	s["name"] = str(s.get("name", "Solar module")).strip_edges()
	if str(s["name"]).is_empty():
		s["name"] = "Solar module"
	s["maker"] = str(s.get("maker", ""))
	if not TYPES.has(str(s.get("type", "rigid"))):
		s["type"] = "rigid"
	else:
		s["type"] = str(s.get("type", "rigid"))
	var dm := _merge({"w": 1134.0, "h": 1722.0, "t": 30.0}, s.get("dims_mm", {}))
	dm["w"] = clampf(float(dm["w"]), 50.0, 4000.0)
	dm["h"] = clampf(float(dm["h"]), 50.0, 4000.0)
	dm["t"] = clampf(float(dm["t"]), 1.0, 80.0)
	s["dims_mm"] = dm
	var c := _merge(CELL_DEFAULTS, s.get("cells", {}))
	if not PvLabCells.TECHS.has(str(c["tech"])):
		c["tech"] = "mono_perc"
	if not PvLabCells.FORMATS.has(str(c["format"])):
		c["format"] = "m10"
	if not PvLabCells.CUTS.has(str(c["cut"])):
		c["cut"] = "full"
	# A thin-film technology is always strips; a wafer one never is.
	var film := bool((PvLabCells.tech(str(c["tech"]))["look"] as Dictionary)["film"])
	if film:
		c["cut"] = "strip"
		c["cols"] = 1
	elif str(c["cut"]) == "strip":
		c["cut"] = "full"
	c["cols"] = clampi(int(c["cols"]), 1, 40)
	c["rows"] = clampi(int(c["rows"]), 1, 400)
	c["gap_mm"] = clampf(float(c["gap_mm"]), 0.0, 30.0)
	c["split_gap_mm"] = clampf(float(c["split_gap_mm"]), 0.0, 120.0)
	c["custom_edge_mm"] = clampf(float(c["custom_edge_mm"]), 10.0, 400.0)
	c["busbars"] = clampi(int(c["busbars"]), 0, 24)
	c["finger_pitch_mm"] = clampf(float(c["finger_pitch_mm"]), 0.5, 6.0)
	c["chamfer_mm"] = float(c["chamfer_mm"])
	c["parallel"] = clampi(int(c["parallel"]), 0, 6)
	s["cells"] = c
	var fr := _merge(FRAME_DEFAULTS, s.get("frame", {}))
	if not FRAME_STYLES.has(str(fr["style"])):
		fr["style"] = "black"
	fr["height_mm"] = clampf(float(fr["height_mm"]), 0.0, 60.0)
	fr["width_mm"] = clampf(float(fr["width_mm"]), 0.0, 60.0)
	fr["overlap_mm"] = clampf(float(fr["overlap_mm"]), 0.0, minf(20.0, float(fr["width_mm"])))
	fr["lip_mm"] = clampf(float(fr["lip_mm"]), 0.0, 6.0)
	s["frame"] = fr
	s["corner_r_mm"] = clampf(float(s.get("corner_r_mm", -1.0)), -1.0, 80.0)
	var bk := _merge(BACK_DEFAULTS, s.get("backsheet", {}))
	for k in ["front", "back"]:
		if not SHEETS.has(str(bk[k])):
			bk[k] = "white"
	s["backsheet"] = bk
	if not GLASSES.has(str(s.get("glass", "ar"))):
		s["glass"] = "ar"
	else:
		s["glass"] = str(s.get("glass", "ar"))
	var jb := _merge(JBOX_DEFAULTS, s.get("jbox", {}))
	if not JBOX_LAYOUTS.has(str(jb["layout"])):
		jb["layout"] = "top"
	if not CONNECTORS.has(str(jb["connector"])):
		jb["connector"] = "mc4"
	if not ["top", "side"].has(str(jb["exit"])):
		jb["exit"] = "top"
	jb["leads_mm"] = clampf(float(jb["leads_mm"]), 50.0, 5000.0)
	s["jbox"] = jb
	s["bypass_diodes"] = clampi(int(s.get("bypass_diodes", 3)), 0, 6)
	var fo := _merge(FOLD_DEFAULTS, s.get("folding", {}))
	fo["leaves"] = clampi(int(fo["leaves"]), 1, 8)
	fo["hinge_mm"] = clampf(float(fo["hinge_mm"]), 0.0, 120.0)
	fo["kickstands"] = clampi(int(fo["kickstands"]), 0, 4)
	s["folding"] = fo
	var lk := _merge(LOOK_DEFAULTS, s.get("look", {}))
	lk["cell_color"] = null if lk["cell_color"] == null else _to_color(lk["cell_color"], Color.BLACK)
	lk["sheen"] = clampf(float(lk["sheen"]), 0.0, 3.0)
	lk["flake"] = clampf(float(lk["flake"]), 0.0, 3.0)
	lk["grid_color"] = _to_color(lk["grid_color"], LOOK_DEFAULTS["grid_color"])
	s["look"] = lk
	var el := _merge(ELEC_DEFAULTS, s.get("electrical", {}))
	if not ["derived", "datasheet"].has(str(el["mode"])):
		el["mode"] = "derived"
	for k in ["wmp", "voc", "vmp", "isc", "imp", "max_system_v", "bifaciality", "mass_kg"]:
		el[k] = maxf(float(el[k]), 0.0)
	for k in ["voc_coeff", "isc_coeff", "pmax_coeff", "noct_c"]:
		el[k] = float(el[k]) if el[k] != null else NAN
	s["electrical"] = el
	s["shade_samples"] = clampi(int(s.get("shade_samples", 2)), 1, 2)
	return s


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

## The frame's face lip (mm) on each side: 0 for frameless builds.
static func frame_lip_mm(s: Dictionary) -> float:
	var st := str(s["frame"]["style"])
	if st == "none" or st == "clips":
		return 0.0
	return float(s["frame"]["width_mm"])


## The module as `type` would be built: the type's frame, thickness, front
## sheet, backsheets and boxes laid over the spec. A thin-film type moves a
## wafer technology to CdTe, a wafer type moves a film one to mono PERC
## (CIGS stays on a flexible module: it is made that way).
static func type_patch(spec: Dictionary, type: String) -> Dictionary:
	var s := resolve(spec)
	if not TYPES.has(type):
		return s
	s["type"] = type
	var patch: Dictionary = TYPE_PATCH[type]
	for k in patch:
		if patch[k] is Dictionary:
			for k2 in (patch[k] as Dictionary):
				(s[k] as Dictionary)[k2] = (patch[k] as Dictionary)[k2]
		else:
			s[k] = patch[k]
	var c: Dictionary = s["cells"]
	var film := bool((PvLabCells.tech(str(c["tech"]))["look"] as Dictionary)["film"])
	if type == "thin_film" and not film:
		c["tech"] = "cdte"
		c["rows"] = maxi(int(c["rows"]), 120)
		c["gap_mm"] = 0.2
	elif type in ["rigid", "glass_glass", "folding"] and film:
		c["tech"] = "mono_perc"
		c["cut"] = "half"
		c["cols"] = 6
		c["rows"] = 20
		c["gap_mm"] = 2.0
	if type == "glass_glass" and str(c["tech"]) in ["mono_perc", "poly"]:
		c["tech"] = "topcon"
	s["corner_r_mm"] = -1.0
	return resolve(s)


## The laminate's corner radius (mm): set, or by type.
static func corner_radius_mm(s: Dictionary) -> float:
	var r := float(s.get("corner_r_mm", -1.0))
	if r >= 0.0:
		return r
	match str(s["type"]):
		"flexible":
			return 12.0
		"folding":
			return 8.0
	return 0.0


## The front sheet as the cell shader's `surface`: 0 AR glass, 1 textured
## glass, 2 ETFE, 3 PET.
static func surface_id(s: Dictionary) -> int:
	return {"ar": 0, "textured": 1, "etfe": 2, "pet": 3}.get(str(s["glass"]), 0)


## One cell piece's size (mm, across × along) and the full wafer's chamfer.
static func piece_mm(s: Dictionary) -> Dictionary:
	var c: Dictionary = s["cells"]
	var cut := str(c["cut"])
	if cut == "strip":
		var act := active_area_mm(s)
		var along := (act.y - float(c["gap_mm"]) * float(int(c["rows"]) - 1)) / float(int(c["rows"]))
		return {"across": act.x, "along": maxf(along, 0.5), "chamfer": 0.0, "edge": act.x}
	var edge := PvLabCells.format_edge_mm(str(c["format"]), float(c["custom_edge_mm"]))
	var fmt: Dictionary = PvLabCells.FORMATS.get(str(c["format"]), PvLabCells.FORMATS["m10"])
	var ch := float(c["chamfer_mm"])
	if ch < 0.0:
		ch = PvLabCells.chamfer_mm(edge, float(fmt["diameter_mm"]))
	if not bool(PvLabCells.tech(str(c["tech"]))["crystalline"]) or str(c["tech"]) == "poly":
		ch = 0.0  # multicrystalline wafers are cast square
	var pieces := int((PvLabCells.CUTS[cut] as Dictionary)["pieces"])
	return {"across": edge, "along": edge / float(pieces), "chamfer": ch, "edge": edge}


## The cell grid's extent (mm, across × along) including gaps.
static func grid_extent_mm(s: Dictionary) -> Vector2:
	var c: Dictionary = s["cells"]
	var pc := piece_mm(s)
	var cols := int(c["cols"])
	var rows := int(c["rows"])
	var gap := float(c["gap_mm"])
	var w := float(pc["across"]) * cols + gap * float(cols - 1)
	var h := float(pc["along"]) * rows + gap * float(rows - 1)
	if parallel_paths(s) > 1:
		h += float(c["split_gap_mm"]) * float(parallel_paths(s) - 1)
	return Vector2(w, h)


## The face inside the frame lip (mm), less a folding case's hinges.
static func active_area_mm(s: Dictionary) -> Vector2:
	var dm: Dictionary = s["dims_mm"]
	var lip := frame_lip_mm(s)
	var margin := 8.0 if str(s["type"]) in ["flexible", "thin_film"] else 0.0
	var w := float(dm["w"]) - 2.0 * (lip + margin)
	var h := float(dm["h"]) - 2.0 * (lip + margin)
	if str(s["type"]) == "folding":
		var fo: Dictionary = s["folding"]
		h -= float(fo["hinge_mm"]) * float(int(fo["leaves"]) - 1)
	return Vector2(maxf(w, 5.0), maxf(h, 5.0))


## Where cell piece (col, row)'s centre sits, in panel u/v (−0.5..0.5), and its
## size in u/v. Rows run from the top edge (v = −0.5); a split module adds its
## split gap between path bands, a folding one its hinges between leaves.
static func piece_rect_uv(s: Dictionary, col: int, row: int) -> Rect2:
	var c: Dictionary = s["cells"]
	var dm: Dictionary = s["dims_mm"]
	var pc := piece_mm(s)
	var ext := grid_extent_mm(s)
	var gap := float(c["gap_mm"])
	var x0 := -ext.x * 0.5 + float(col) * (float(pc["across"]) + gap)
	var y0 := -_total_along_mm(s) * 0.5 + float(row) * (float(pc["along"]) + gap)
	var rows := int(c["rows"])
	var p := parallel_paths(s)
	if p > 1:
		var per := maxi(rows / p, 1)
		y0 += float(c["split_gap_mm"]) * float(mini(row / per, p - 1))
	if str(s["type"]) == "folding":
		var fo: Dictionary = s["folding"]
		var leaves := int(fo["leaves"])
		var per_leaf := maxi(int(ceil(float(rows) / float(leaves))), 1)
		y0 += float(fo["hinge_mm"]) * float(mini(row / per_leaf, leaves - 1))
	var w := float(dm["w"])
	var h := float(dm["h"])
	return Rect2(x0 / w, y0 / h, float(pc["across"]) / w, float(pc["along"]) / h)


static func _total_along_mm(s: Dictionary) -> float:
	var ext := grid_extent_mm(s)
	if str(s["type"]) == "folding":
		var fo: Dictionary = s["folding"]
		ext.y += float(fo["hinge_mm"]) * float(int(fo["leaves"]) - 1)
	return ext.y


## How many cells fit the face as specified, and whether the grid overhangs.
static func fit_report(s: Dictionary) -> Dictionary:
	var ext := grid_extent_mm(s)
	var act := active_area_mm(s)
	if str(s["type"]) == "folding":
		var fo: Dictionary = s["folding"]
		act.y += float(fo["hinge_mm"]) * float(int(fo["leaves"]) - 1)
		ext.y += float(fo["hinge_mm"]) * float(int(fo["leaves"]) - 1)
	return {"grid_mm": ext, "face_mm": act, "fits": ext.x <= act.x + 0.5 and ext.y <= act.y + 0.5,
		"border_mm": Vector2((act.x - ext.x) * 0.5, (act.y - ext.y) * 0.5)}


## Cols × rows that fill the face for the chosen cell size and cut.
static func cells_to_fit(s: Dictionary) -> Vector2i:
	var c: Dictionary = s["cells"]
	var act := active_area_mm(s)
	if str(c["cut"]) == "strip":
		return Vector2i(1, maxi(int(c["rows"]), 1))
	var pc := piece_mm(s)
	var gap := float(c["gap_mm"])
	var cols := maxi(int(floor((act.x + gap) / (float(pc["across"]) + gap))), 1)
	var p := parallel_paths(s)
	var avail := act.y - float(c["split_gap_mm"]) * float(p - 1)
	var rows := maxi(int(floor((avail + gap) / (float(pc["along"]) + gap))), 1)
	rows = maxi(rows - rows % p, p)
	return Vector2i(cols, rows)


## Module dims (mm) that fit the cell grid exactly with a 12 mm border.
static func dims_to_fit(s: Dictionary) -> Vector2:
	var ext := grid_extent_mm(s)
	var lip := frame_lip_mm(s)
	var margin := 8.0 if str(s["type"]) in ["flexible", "thin_film"] else 0.0
	var extra := 2.0 * (lip + margin + 12.0)
	var along := ext.y
	if str(s["type"]) == "folding":
		var fo: Dictionary = s["folding"]
		along += float(fo["hinge_mm"]) * float(int(fo["leaves"]) - 1)
	return Vector2(ext.x + extra, along + extra)


static func area_m2(s: Dictionary) -> float:
	return float(s["dims_mm"]["w"]) * float(s["dims_mm"]["h"]) / 1.0e6


static func mass_kg(s: Dictionary) -> float:
	var m := float(s["electrical"]["mass_kg"])
	if m > 0.0:
		return m
	return area_m2(s) * float(AREAL_KG.get(str(s["type"]), 11.0))


# ---------------------------------------------------------------------------
# Electrics
# ---------------------------------------------------------------------------

## Current paths in parallel: a half-cut module's two halves, a third-cut's
## three, else one (or the layout's own override).
static func parallel_paths(s: Dictionary) -> int:
	var c: Dictionary = s["cells"]
	if int(c["parallel"]) > 0:
		return mini(int(c["parallel"]), int(c["rows"]))
	return mini(int((PvLabCells.CUTS[str(c["cut"])] as Dictionary)["parallel"]), int(c["rows"]))


## Cells in series in one current path.
static func series_cells(s: Dictionary) -> int:
	var c: Dictionary = s["cells"]
	return maxi(int(c["cols"]) * int(c["rows"]) / parallel_paths(s), 1)


## One cell piece's active area (cm²).
static func piece_area_cm2(s: Dictionary) -> float:
	var pc := piece_mm(s)
	if str(s["cells"]["cut"]) == "strip":
		return float(pc["across"]) * float(pc["along"]) / 100.0
	var pieces := int((PvLabCells.CUTS[str(s["cells"]["cut"])] as Dictionary)["pieces"])
	return PvLabCells.wafer_area_cm2(float(pc["edge"]), float(pc["chamfer"])) / float(pieces)


## What the cells make by themselves at STC: {voc, vmp, isc, imp, wmp}.
static func derived_stc(s: Dictionary) -> Dictionary:
	var e: Dictionary = (PvLabCells.tech(str(s["cells"]["tech"])) as Dictionary)["elec"]
	var voc := float(series_cells(s)) * float(e["voc"])
	var isc := float(parallel_paths(s)) * float(e["jsc"]) * 0.001 * piece_area_cm2(s)
	var vmp := voc * float(e["vm"])
	var imp := isc * float(e["im"])
	return {"voc": voc, "vmp": vmp, "isc": isc, "imp": imp, "wmp": vmp * imp}


## The module's STC electrics and coefficients as every consumer reads them:
## {voc, vmp, isc, imp, wmp, voc_coeff, isc_coeff, pmax_coeff, vmp_coeff,
## noct_c, series_cells, parallel_paths, bypass_diodes, mode}.
static func electrical(spec: Dictionary) -> Dictionary:
	var s := spec if spec.get("version", 0) == VERSION and spec.has("electrical") else resolve(spec)
	var el: Dictionary = s["electrical"]
	var te: Dictionary = (PvLabCells.tech(str(s["cells"]["tech"])) as Dictionary)["elec"]
	var d := derived_stc(s)
	var out := d.duplicate()
	if str(el["mode"]) == "datasheet" and float(el["voc"]) > 0.0 and float(el["isc"]) > 0.0:
		out["voc"] = float(el["voc"])
		out["isc"] = float(el["isc"])
		out["vmp"] = float(el["vmp"]) if float(el["vmp"]) > 0.0 else float(el["voc"]) * float(te["vm"])
		out["imp"] = float(el["imp"]) if float(el["imp"]) > 0.0 else float(el["isc"]) * float(te["im"])
		out["wmp"] = float(el["wmp"]) if float(el["wmp"]) > 0.0 else float(out["vmp"]) * float(out["imp"])
	out["voc_coeff"] = float(el["voc_coeff"]) if not is_nan(float(el["voc_coeff"])) else float(te["voc_coeff"])
	out["isc_coeff"] = float(el["isc_coeff"]) if not is_nan(float(el["isc_coeff"])) else float(te["isc_coeff"])
	out["pmax_coeff"] = float(el["pmax_coeff"]) if not is_nan(float(el["pmax_coeff"])) else float(te["pmax_coeff"])
	# Vmp falls with heat at about the Pmax rate less the Imp's small rise
	# (the same rule PvElectrical.vmp_coeff_for uses).
	out["vmp_coeff"] = float(out["pmax_coeff"]) - 0.05
	out["noct_c"] = float(el["noct_c"]) if not is_nan(float(el["noct_c"])) else float(te["noct_c"])
	out["series_cells"] = series_cells(s)
	out["parallel_paths"] = parallel_paths(s)
	out["bypass_diodes"] = int(s["bypass_diodes"])
	out["mode"] = str(el["mode"])
	out["derived"] = d
	return out


## The keys a graph `panel` item carries for this module (component_presets
## shape plus the temperature coefficients PvElectrical reads).
static func graph_specs(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var e := electrical(s)
	return {"name": str(s["name"]), "wmp": snappedf(float(e["wmp"]), 0.1), "voc": snappedf(float(e["voc"]), 0.01),
		"vmp": snappedf(float(e["vmp"]), 0.01), "isc": snappedf(float(e["isc"]), 0.01),
		"imp": snappedf(float(e["imp"]), 0.01), "voc_temp_coeff_pct": float(e["voc_coeff"]),
		"pmax_temp_coeff_pct": float(e["pmax_coeff"]), "noct_c": float(e["noct_c"]),
		"bypass_diodes": int(e["bypass_diodes"]), "panel_w_m": float(s["dims_mm"]["w"]) / 1000.0,
		"panel_h_m": float(s["dims_mm"]["h"]) / 1000.0, "cost": 0.4 * float(e["wmp"])}


## A module from an existing graph panel preset (component_presets PANELS
## specs): datasheet mode with its nameplate, a likely cell layout for its
## watts and a size from its watts at 20 % (rigid) efficiency.
static func from_graph_specs(gs: Dictionary) -> Dictionary:
	var wmp := float(gs.get("wmp", gs.get("watts", 300.0)))
	var voc := float(gs.get("voc", 40.0))
	var flex := str(gs.get("name", "")).to_lower().contains("flex")
	var w_mm := float(gs.get("panel_w_m", 0.0)) * 1000.0
	var h_mm := float(gs.get("panel_h_m", 0.0)) * 1000.0
	if w_mm <= 0.0 or h_mm <= 0.0:
		var a := wmp / (0.20 * 1000.0) if not flex else wmp / (0.17 * 1000.0)
		h_mm = sqrt(a * 1.62) * 1000.0
		w_mm = a * 1.0e6 / h_mm
	var series := maxi(int(round(voc / 0.69)), 1)
	var cols := 6 if series >= 36 else 4
	var spec := {"name": str(gs.get("name", "Panel")), "type": "flexible" if flex else "rigid",
		"dims_mm": {"w": w_mm, "h": h_mm, "t": 3.0 if flex else 35.0},
		"cells": {"tech": "mono_perc", "format": "m10", "cut": "full", "cols": cols,
			"rows": maxi(series / cols, 1)},
		"frame": {"style": "none" if flex else "black"},
		"electrical": {"mode": "datasheet", "wmp": wmp, "voc": voc, "vmp": float(gs.get("vmp", 0.0)),
			"isc": float(gs.get("isc", 0.0)), "imp": float(gs.get("imp", 0.0))}}
	if gs.has("voc_temp_coeff_pct"):
		spec["electrical"]["voc_coeff"] = float(gs["voc_temp_coeff_pct"])
	if gs.has("pmax_temp_coeff_pct"):
		spec["electrical"]["pmax_coeff"] = float(gs["pmax_temp_coeff_pct"])
	return resolve(spec)


# ---------------------------------------------------------------------------
# Substrings: which cells share a bypass diode, and where shade is sampled
# ---------------------------------------------------------------------------

## The module's electrical map, as the I–V model and the shading read it:
## [{diode: bool, cells (in series in each path), cols: [c0, c1), paths:
##   [{rows: [r0, r1), bands: [[Vector2 uv, ...], ...]}]}]
## A path's irradiance is the MINIMUM over its bands of each band's MEAN —
## cells in series run at the weakest cell's current; a thin-film strip
## averages along its length. A wafer path's bands are single points.
static func substrings(spec: Dictionary) -> Array:
	var s := spec if spec.get("version", 0) == VERSION and spec.has("cells") else resolve(spec)
	var c: Dictionary = s["cells"]
	var cols := int(c["cols"])
	var rows := int(c["rows"])
	var p := parallel_paths(s)
	var d := int(s["bypass_diodes"])
	var groups := maxi(d, 1)
	var film := str(c["cut"]) == "strip"
	var per_path_rows := maxi(rows / p, 1)
	var out: Array = []
	# Split by columns when they divide evenly (the usual 6 columns, 3 diodes:
	# two columns snake down and back per diode), else by rows.
	var by_cols := not film and cols >= groups and cols % groups == 0
	for g in groups:
		var c0 := 0
		var c1 := cols
		var r_lo := 0
		var r_hi := per_path_rows
		if by_cols:
			c0 = g * cols / groups
			c1 = (g + 1) * cols / groups
		else:
			r_lo = g * per_path_rows / groups
			r_hi = (g + 1) * per_path_rows / groups
		var paths: Array = []
		for pi in p:
			var base := pi * per_path_rows
			var rr := [base + r_lo, base + r_hi]
			paths.append({"rows": rr, "bands": _bands(s, c0, c1, int(rr[0]), int(rr[1]), film)})
		var cells := (c1 - c0) * (r_hi - r_lo)
		out.append({"diode": d > 0, "cells": cells, "cols": [c0, c1], "paths": paths})
	return out


static func _bands(s: Dictionary, c0: int, c1: int, r0: int, r1: int, film: bool) -> Array:
	var tl := piece_rect_uv(s, c0, r0)
	var br := piece_rect_uv(s, c1 - 1, maxi(r1 - 1, r0))
	var u0 := tl.position.x
	var u1 := br.position.x + br.size.x
	var v0 := tl.position.y
	var v1 := br.position.y + br.size.y
	var bands: Array = []
	if film:
		# Three bands across the strips (each strip averages along its length).
		for bi in 3:
			var v := lerpf(v0, v1, (float(bi) + 0.5) / 3.0)
			bands.append([Vector2(lerpf(u0, u1, 0.2), v), Vector2((u0 + u1) * 0.5, v), Vector2(lerpf(u0, u1, 0.8), v)])
		return bands
	var n := int(s["shade_samples"])
	for i in n:
		var v := lerpf(v0, v1, (float(i) + 0.5) / float(n))
		bands.append([Vector2((u0 + u1) * 0.5, v)])
	return bands


## Every shading sample point of the module in panel uv, in substring /
## path / band order (how the irradiance vector the I–V model takes is laid out).
static func sample_points(spec: Dictionary) -> Array:
	var out: Array = []
	for sub in substrings(spec):
		for path in sub["paths"]:
			for band in path["bands"]:
				for p in band:
					out.append(p)
	return out


## Junction boxes and lead exits on the BACK face, in panel uv:
## {boxes: [uv], plus: uv, minus: uv} — where the + and − leads leave.
static func jbox_points(spec: Dictionary) -> Dictionary:
	var s := spec if spec.get("version", 0) == VERSION and spec.has("jbox") else resolve(spec)
	var jb: Dictionary = s["jbox"]
	var w := float(s["dims_mm"]["w"])
	var h := float(s["dims_mm"]["h"])
	var top := -0.5 + (frame_lip_mm(s) + 60.0) / h
	var side := 0.5 - (frame_lip_mm(s) + 60.0) / w
	match str(jb["layout"]):
		"split3":
			return {"boxes": [Vector2(-0.3, 0.0), Vector2(0.0, 0.0), Vector2(0.3, 0.0)],
				"plus": Vector2(0.3, 0.0), "minus": Vector2(-0.3, 0.0)}
		"center":
			return {"boxes": [Vector2(0.0, 0.0)], "plus": Vector2(0.06, 0.0), "minus": Vector2(-0.06, 0.0)}
		"corner":
			return {"boxes": [Vector2(side, top)], "plus": Vector2(side, top), "minus": Vector2(side - 0.05, top)}
		_:
			return {"boxes": [Vector2(0.0, top)], "plus": Vector2(0.08, top), "minus": Vector2(-0.08, top)}


# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------

static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var lk: Dictionary = s["look"]
	if lk["cell_color"] is Color:
		var c: Color = lk["cell_color"]
		lk["cell_color"] = [c.r, c.g, c.b, c.a]
	var g: Color = lk["grid_color"]
	lk["grid_color"] = [g.r, g.g, g.b, g.a]
	var el: Dictionary = s["electrical"]
	for k in ["voc_coeff", "isc_coeff", "pmax_coeff", "noct_c"]:
		if is_nan(float(el[k])):
			el[k] = null
	return s


static func key_of(spec: Dictionary) -> String:
	return str(hash(var_to_str(to_json_safe(spec))))


static func describe(spec: Dictionary) -> String:
	var s := resolve(spec)
	var e := electrical(s)
	var c: Dictionary = s["cells"]
	return "%.0f W · %d×%d %s %s · %.0f × %.0f mm" % [float(e["wmp"]), int(c["cols"]), int(c["rows"]),
		str((PvLabCells.CUTS[str(c["cut"])] as Dictionary)["label"]).to_lower(),
		str(PvLabCells.tech(str(c["tech"]))["label"]), float(s["dims_mm"]["h"]), float(s["dims_mm"]["w"])]


static func _merge(defaults: Dictionary, over: Variant) -> Dictionary:
	var out := defaults.duplicate(true)
	if over is Dictionary:
		for k in (over as Dictionary):
			out[k] = (over as Dictionary)[k]
	return out


static func _to_color(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	if v is String and Color.html_is_valid(str(v)):
		return Color.html(str(v))
	return fallback
