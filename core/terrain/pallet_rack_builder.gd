class_name PalletRackBuilder
extends RefCounted

## Parametric Mars-College-style structure built from standard warehouse pallet
## racking: upright frames (depth 36/42/48", height 4-20') carrying beams
## (span 4/8/9/10/12'), rack rows locked into columns by 2x4 lumber joists and
## tiled with 4'x8' 3/4" plywood decks. Supports multi-level + rooftop decks,
## plywood walls, a stepped-platform module, and a U-shaped open-bay variant.
##
## Used by the pallet-rack builder modal and as the procedural PlacedProp model
## "pallet_rack". The whole structure is emitted as ONE MeshInstance3D with a few
## merged surfaces (one per material) so large multi-column builds stay cheap and
## the trimesh collision bake (see placed_prop.gd) yields walkable decks.
##
## DESIGN ELEMENTS (spec["elements"]) are the details that turn a bare rack into
## a building, as the Mars College builds do: doors (hinged / double / sliding
## barn doors / open doorways) and windows that cut their own holes in the
## plywood walls, outside stairs, a sloped lean-to array on any face (solar
## modules, greenhouse glazing, plywood or bare rafters, chosen per bay), guard
## railings round every open deck edge, and courtyards cut out of the grid. Each
## is one record {id, type, ...}; resolve_element fills its type's defaults and
## clamps it to the rack, so a saved preset lands sanely on any other rack.

const MODEL_ID := "pallet_rack"

const FT := 0.3048
const IN := 0.0254

# Catalog option sets (imperial, snapped in resolve_spec).
const DEPTH_OPTIONS_IN := [36, 42, 48]
const HEIGHT_OPTIONS_FT := [4, 6, 8, 10, 12, 16, 20]
const BEAM_OPTIONS_FT := [4, 8, 9, 10, 12]
const LUMBER_OPTIONS_FT := [10, 12, 16]
const JOIST_SPACING_OPTIONS_IN := [16, 24]

# Member cross-sections (metres).
const POST_W := 3.0 * IN          # upright post face
const BEAM_H := 0.10              # steel beam vertical face
const BEAM_T := 0.05              # steel beam thickness (depth)
const JOIST_W := 1.5 * IN         # 2x4 on edge width
const JOIST_H := 3.5 * IN         # 2x4 on edge height
const PLY_T := 0.75 * IN          # 3/4" plywood
const BEARING := 0.04            # joist rest on each beam
const SHEET_LONG := 8.0 * FT      # 4x8 plywood long edge
const SHEET_SHORT := 4.0 * FT     # 4x8 plywood short edge
const HALF_PANEL_FT := 4.0        # 4x4 half-sheet — deck spacing snaps to this
const SEAM := 0.005              # gap between sheets so they read individually
const STAIR_STEPS := 6

# ---- Design elements ----
const ELEMENT_TYPES := ["door", "window", "stair", "lean_to", "railing", "courtyard"]
const FACES := ["front", "back", "left", "right"]
const OPPOSITE_FACE := {"front": "back", "back": "front", "left": "right", "right": "left"}
const DOOR_STYLES := ["hinged", "double", "sliding", "opening"]
const WINDOW_STYLES := ["glass", "open"]
const SLOPE_SURFACES := ["solar", "glazing", "plywood", "frame", "none"]
const SLOPE_ENDS := ["open", "glazing", "plywood"]
const PANEL_ORIENTATIONS := ["landscape", "portrait"]
const STAIR_RUNS := ["along", "out"]

const ELEMENT_LABELS := {
	"door": "Door", "window": "Window", "stair": "Stairs", "lean_to": "Sloped array",
	"railing": "Railing", "courtyard": "Courtyard",
}
const OPTION_LABELS := {
	"front": "Front", "back": "Back", "left": "Left", "right": "Right",
	"hinged": "Hinged", "double": "Double", "sliding": "Sliding barn door",
	"opening": "Open doorway", "glass": "Glazed", "open": "Open",
	"solar": "Solar panels", "glazing": "Greenhouse glazing", "plywood": "Plywood",
	"frame": "Bare rafters", "none": "Leave this bay off",
	"landscape": "Landscape", "portrait": "Portrait",
	"along": "Along the wall", "out": "Straight out",
}

# Member + product sizes for the elements (metres).
const TRIM_W := 3.5 * IN          # 1x4 casing round doors and windows
const DOOR_T := 1.75 * IN         # a solid-core door slab
const RAFTER_W := 1.5 * IN        # 2x6 rafters, on edge
const RAFTER_D := 5.5 * IN
const PURLIN_T := 1.5 * IN        # 2x4 purlins / battens, laid flat
const PURLIN_W := 3.5 * IN
const LEG_W := 3.5 * IN           # 4x4 legs and props
const PV_LONG := 65.0 * IN        # a 60-cell module is 65 x 39 in
const PV_SHORT := 39.0 * IN
const PV_T := 1.4 * IN
const PV_GAP := 0.5 * IN
const PV_WATTS := 300.0
const GLAZING_T := 0.25 * IN      # twin-wall polycarbonate
# IRC R311.7.5: a riser at most 7 3/4", a tread at least 10". 7.5" keeps margin.
const RISER_MAX := 7.5 * IN
const TREAD_RUN := 10.0 * IN
const STRINGER_D := 9.25 * IN     # 2x10 stringers
const RAIL_POST_MAX := 4.0 * FT   # guard posts at most 4' apart
const STAIR_RAIL_H := 34.0 * IN   # IRC R311.7.8.1: handrail 34-38" above the nosing

## Per-type defaults. Positions along a face are feet from the face's start
## (the -X end of front/back, the -Z end of left/right). `floor` / `to_level`
## index the deck levels (_levels: the template levels then the roof), -1 = the
## ground. `attach_level` -1 = the top of the frame.
const ELEMENT_DEFAULTS := {
	"door": {"face": "front", "at_ft": 6.0, "floor": -1, "style": "hinged",
		"width_ft": 3.0, "height_ft": 6.75, "color": "#f2efe6"},
	"window": {"face": "front", "at_ft": 6.0, "floor": -1, "style": "glass",
		"width_ft": 3.0, "height_ft": 2.5, "sill_ft": 3.0},
	"stair": {"face": "left", "at_ft": 4.0, "to_level": 1, "run": "along",
		"flip": false, "width_ft": 3.0, "handrail": true},
	"lean_to": {"face": "front", "surface": "solar", "segments": {}, "angle_deg": 50.0,
		"attach_level": -1, "bottom_ft": 1.5, "seg_from": 0, "seg_to": -1,
		"orientation": "landscape", "panel_watts": PV_WATTS, "ends": "open"},
	"railing": {"floor": 1, "height_ft": 3.5, "front": true, "back": true,
		"left": true, "right": true, "inner": true},
	"courtyard": {"bay0": 1, "bays": 1, "col0": 0, "cols": 1},
}

## The inspector's row model per element type (pure data — the modal renders
## it, the selftest checks every key is a real default). Kinds: face, floor,
## level (a deck, not the ground), attach, along, float, int, option, bool,
## color, seg (a 1-based bay of the face), bay / col (1-based grid indices).
const ELEMENT_FIELDS := {
	"door": [
		{"key": "face", "label": "Wall", "kind": "face"},
		{"key": "at_ft", "label": "Position", "kind": "along"},
		{"key": "floor", "label": "Floor", "kind": "floor"},
		{"key": "style", "label": "Style", "kind": "option", "options": DOOR_STYLES},
		{"key": "width_ft", "label": "Width", "kind": "float", "min": 2.0, "max": 12.0, "step": 0.5},
		{"key": "height_ft", "label": "Height", "kind": "float", "min": 5.0, "max": 10.0, "step": 0.25},
		{"key": "color", "label": "Colour", "kind": "color"},
	],
	"window": [
		{"key": "face", "label": "Wall", "kind": "face"},
		{"key": "at_ft", "label": "Position", "kind": "along"},
		{"key": "floor", "label": "Floor", "kind": "floor"},
		{"key": "style", "label": "Style", "kind": "option", "options": WINDOW_STYLES},
		{"key": "width_ft", "label": "Width", "kind": "float", "min": 1.0, "max": 12.0, "step": 0.5},
		{"key": "height_ft", "label": "Height", "kind": "float", "min": 1.0, "max": 8.0, "step": 0.25},
		{"key": "sill_ft", "label": "Sill height", "kind": "float", "min": 0.0, "max": 10.0, "step": 0.25},
	],
	"stair": [
		{"key": "face", "label": "Wall", "kind": "face"},
		{"key": "at_ft", "label": "Top of the stairs at", "kind": "along"},
		{"key": "to_level", "label": "Up to", "kind": "level"},
		{"key": "run", "label": "Runs", "kind": "option", "options": STAIR_RUNS},
		{"key": "flip", "label": "Run the other way", "kind": "bool"},
		{"key": "width_ft", "label": "Width", "kind": "float", "min": 2.0, "max": 8.0, "step": 0.5},
		{"key": "handrail", "label": "Handrail", "kind": "bool"},
	],
	"lean_to": [
		{"key": "face", "label": "Face", "kind": "face"},
		{"key": "surface", "label": "Covering", "kind": "option", "options": SLOPE_SURFACES},
		{"key": "angle_deg", "label": "Slope", "kind": "float", "min": 15.0, "max": 75.0, "step": 1.0, "unit": "°"},
		{"key": "attach_level", "label": "Top edge at", "kind": "attach"},
		{"key": "bottom_ft", "label": "Bottom edge height", "kind": "float", "min": 0.0, "max": 10.0, "step": 0.25},
		{"key": "seg_from", "label": "From bay", "kind": "seg"},
		{"key": "seg_to", "label": "To bay", "kind": "seg"},
		{"key": "orientation", "label": "Panels", "kind": "option", "options": PANEL_ORIENTATIONS},
		{"key": "panel_watts", "label": "Watts per panel", "kind": "float", "min": 50.0, "max": 800.0, "step": 5.0, "unit": "W"},
		{"key": "ends", "label": "Close the ends", "kind": "option", "options": SLOPE_ENDS},
	],
	"railing": [
		{"key": "floor", "label": "Deck", "kind": "level"},
		{"key": "height_ft", "label": "Height", "kind": "float", "min": 2.5, "max": 4.5, "step": 0.25},
		{"key": "front", "label": "Front edge", "kind": "bool"},
		{"key": "back", "label": "Back edge", "kind": "bool"},
		{"key": "left", "label": "Left edge", "kind": "bool"},
		{"key": "right", "label": "Right edge", "kind": "bool"},
		{"key": "inner", "label": "Inner edges (courtyards, gaps)", "kind": "bool"},
	],
	"courtyard": [
		{"key": "bay0", "label": "First bay", "kind": "bay"},
		{"key": "bays", "label": "Bays wide", "kind": "int", "min": 1, "max": 10},
		{"key": "col0", "label": "First column", "kind": "col"},
		{"key": "cols", "label": "Columns deep", "kind": "int", "min": 1, "max": 10},
	],
}

## The editor's Add palette: each tool places one element from this template.
const TOOL_PRESETS := [
	{"id": "door", "label": "Door", "tip": "Click a wall face to set a door in it",
		"element": {"type": "door"}},
	{"id": "barn_door", "label": "Sliding door", "tip": "A barn door on a track — click a wall face",
		"element": {"type": "door", "style": "sliding", "width_ft": 4.0, "height_ft": 7.0,
			"color": "#e9c22b"}},
	{"id": "window", "label": "Window", "tip": "Click a wall face where the window goes",
		"element": {"type": "window"}},
	{"id": "stairs", "label": "Stairs", "tip": "Click the face the stairs climb, near the deck they reach",
		"element": {"type": "stair"}},
	{"id": "solar_slope", "label": "Solar slope", "tip": "A sloped solar array leaning on a face — click the face",
		"element": {"type": "lean_to", "surface": "solar"}},
	{"id": "greenhouse", "label": "Greenhouse", "tip": "A glazed lean-to greenhouse — click the face",
		"element": {"type": "lean_to", "surface": "glazing", "ends": "glazing",
			"angle_deg": 45.0, "bottom_ft": 2.0}},
	{"id": "railing", "label": "Railing", "tip": "Guard rails round a deck's open edges — click the deck",
		"element": {"type": "railing"}},
	{"id": "courtyard", "label": "Courtyard", "tip": "Cut an open courtyard out of the grid — click a deck cell",
		"element": {"type": "courtyard"}},
]

## The player's saved designs + element presets (one file, every map).
const LIBRARY_PATH := "user://pallet_rack_library.json"
const LIBRARY_VERSION := 1


static func default_spec() -> Dictionary:
	# The Mars College standard: 42" x 16' uprights, 12' beams, 3 bays, 2 columns,
	# decks at 6" + 8', rooftop deck on.
	return {
		"upright_depth_in": 42,
		"upright_height_ft": 16,
		"beam_span_ft": 12,
		"bay_count": 3,
		"column_count": 2,
		"row_gap_ft": 12.0,
		"decked": true,
		"lumber_len_ft": 12,
		"joist_spacing_in": 24,
		"deck_levels": 2,
		"level_heights_ft": [0.5, 8.0],
		"roof_deck": true,
		"walls": {"front": false, "back": false, "left": false, "right": false},
		"stepped_module": 0,
		"u_shape": false,
		"u_open_bays": 1,
		"u_open_cols": 1,
		# Per-component editor overrides (empty = every cell/beam uses defaults).
		# cell_overrides: "bay,col,level" -> {height_ft, kind: deck|step|none, depth_units}
		# beam_overrides: "level,row,bay,side" -> {deleted, dy_in}
		# wall_sheet_deleted: ["face,ia,iv", ...]
		"cell_overrides": {},
		"beam_overrides": {},
		"wall_sheet_deleted": [],
		# The plywood walls' band (ft). top < 0 = the top of the frame.
		"wall_bottom_ft": 0.0,
		"wall_top_ft": -1.0,
		# Design elements (doors, windows, stairs, slopes, railings, courtyards).
		"elements": [],
	}


static func resolve_spec(overrides: Dictionary = {}) -> Dictionary:
	var s := default_spec()
	# Legacy metric spec (width_m/depth_m/levels) → map onto the catalog so old
	# saved pallet_rack props still rebuild.
	if overrides.has("width_m") and not overrides.has("beam_span_ft"):
		overrides = _map_legacy_spec(overrides)
	for k in s.keys():
		if overrides.has(k):
			s[k] = overrides[k]

	s["upright_depth_in"] = _snap(int(s["upright_depth_in"]), DEPTH_OPTIONS_IN)
	s["upright_height_ft"] = _snap(int(s["upright_height_ft"]), HEIGHT_OPTIONS_FT)
	s["beam_span_ft"] = _snap(int(s["beam_span_ft"]), BEAM_OPTIONS_FT)
	s["lumber_len_ft"] = _snap(int(s["lumber_len_ft"]), LUMBER_OPTIONS_FT)
	s["joist_spacing_in"] = _snap(int(s["joist_spacing_in"]), JOIST_SPACING_OPTIONS_IN)
	s["bay_count"] = clampi(int(s["bay_count"]), 1, 10)
	s["column_count"] = clampi(int(s["column_count"]), 1, 10)
	# Assembly spacing (deck depth between rack rows). Legacy specs (no row_gap_ft)
	# derive it from the joist/lumber length. Snap to the nearest half-panel (4 ft)
	# so plywood always tiles with full + half sheets — no slivers.
	if not overrides.has("row_gap_ft"):
		s["row_gap_ft"] = float(s["lumber_len_ft"])
	s["row_gap_ft"] = clampf(_snap_half_panel(float(s["row_gap_ft"])), 4.0, 20.0)
	s["deck_levels"] = clampi(int(s["deck_levels"]), 1, 3)
	s["decked"] = bool(s["decked"])
	s["roof_deck"] = bool(s["roof_deck"])

	# Normalise level heights to deck_levels, filling defaults / clamping below top.
	var top_ft := float(s["upright_height_ft"])
	var heights: Array = []
	var src: Array = s["level_heights_ft"] if s["level_heights_ft"] is Array else []
	for i in int(s["deck_levels"]):
		var v := _default_level_height_ft(i)
		if i < src.size():
			v = float(src[i])
		heights.append(clampf(v, 0.25, maxf(top_ft - 0.5, 0.25)))
	heights.sort()
	s["level_heights_ft"] = heights

	# Walls dict normalisation.
	var w: Dictionary = s["walls"] if s["walls"] is Dictionary else {}
	s["walls"] = {
		"front": bool(w.get("front", false)),
		"back": bool(w.get("back", false)),
		"left": bool(w.get("left", false)),
		"right": bool(w.get("right", false)),
	}

	s["stepped_module"] = clampi(int(s["stepped_module"]), 0, int(s["column_count"]))
	s["u_shape"] = bool(s["u_shape"])
	s["u_open_bays"] = clampi(int(s["u_open_bays"]), 1, int(s["bay_count"]))
	s["u_open_cols"] = clampi(int(s["u_open_cols"]), 1, int(s["column_count"]))

	# Per-component override containers (typed, string-keyed) so old saved racks
	# without them still load and every editor write round-trips through JSON.
	var cov := {}
	if s.get("cell_overrides") is Dictionary:
		for k in (s["cell_overrides"] as Dictionary).keys():
			var v: Variant = s["cell_overrides"][k]
			cov[str(k)] = (v as Dictionary).duplicate() if v is Dictionary else {}
	s["cell_overrides"] = cov
	var bov := {}
	if s.get("beam_overrides") is Dictionary:
		for k in (s["beam_overrides"] as Dictionary).keys():
			var v: Variant = s["beam_overrides"][k]
			bov[str(k)] = (v as Dictionary).duplicate() if v is Dictionary else {}
	s["beam_overrides"] = bov
	var wdel: Array = []
	if s.get("wall_sheet_deleted") is Array:
		for k in (s["wall_sheet_deleted"] as Array):
			wdel.append(str(k))
	s["wall_sheet_deleted"] = wdel

	# Migrate the legacy stepped_module flag into per-cell "step" overrides so the
	# new editor sees one uniform model. Only when there are no explicit cell edits
	# yet (an edited rack already carries the cells it wants).
	if int(s["stepped_module"]) > 0 and cov.is_empty():
		var lv_list := _levels(s)
		var top_decked := -1
		for li in lv_list.size():
			if bool(s["decked"]) or bool(lv_list[li]["roof"]):
				top_decked = li
		if top_decked > 0:
			var cc := int(s["stepped_module"]) - 1
			for b in int(s["bay_count"]):
				cov["%d,%d,%d" % [b, cc, top_decked]] = {"kind": "step"}

	# The walls' band, kept at least a foot tall.
	var wb := clampf(float(s.get("wall_bottom_ft", 0.0)), 0.0, maxf(top_ft - 1.0, 0.0))
	var wt := float(s.get("wall_top_ft", -1.0))
	if wt >= 0.0:
		wt = clampf(wt, wb + 1.0, top_ft)
		if absf(wt - top_ft) < 0.01:
			wt = -1.0
	s["wall_bottom_ft"] = wb
	s["wall_top_ft"] = -1.0 if wt < 0.0 else wt

	# Design elements: every record resolved against THIS rack, ids unique.
	var els: Array = []
	var used := {}
	var next_n := 1
	var src_els: Array = s["elements"] if s.get("elements") is Array else []
	for e in src_els:
		if e is Dictionary:
			var eid := str((e as Dictionary).get("id", ""))
			if eid.begins_with("e") and eid.substr(1).is_valid_int():
				next_n = maxi(next_n, int(eid.substr(1)) + 1)
	for e in src_els:
		if not (e is Dictionary):
			continue
		var r := resolve_element(e as Dictionary, s)
		var rid := str(r.get("id", ""))
		if rid.is_empty() or used.has(rid):
			rid = "e%d" % next_n
			next_n += 1
			r["id"] = rid
		used[rid] = true
		els.append(r)
	s["elements"] = els
	return s


static func _map_legacy_spec(o: Dictionary) -> Dictionary:
	var width_m := float(o.get("width_m", 2.4))
	var depth_m := float(o.get("depth_m", 1.1))
	var levels := int(o.get("levels", 3))
	return {
		"beam_span_ft": _snap(int(round(width_m / FT)), BEAM_OPTIONS_FT),
		"upright_depth_in": _snap(int(round(depth_m / IN)), DEPTH_OPTIONS_IN),
		"bay_count": clampi(int(o.get("bay_count", 3)), 1, 10),
		"column_count": 1,
		"decked": false,
		"deck_levels": clampi(levels, 1, 3),
		"upright_height_ft": 8,
		"roof_deck": false,
	}


static func _snap(value: int, options: Array) -> int:
	var best: int = int(options[0])
	var best_d := absi(value - best)
	for o in options:
		var d := absi(value - int(o))
		if d < best_d:
			best_d = d
			best = int(o)
	return best


## Round a spacing (ft) to the nearest 4x4 half-panel so plywood tiles cleanly.
static func _snap_half_panel(value_ft: float) -> float:
	return roundf(value_ft / HALF_PANEL_FT) * HALF_PANEL_FT


static func _default_level_height_ft(i: int) -> float:
	var defaults := [0.5, 8.0, 16.0]
	if i < defaults.size():
		return defaults[i]
	return 0.5 + float(i) * 7.5


# ---------------------------------------------------------------------------
# Geometry model
# ---------------------------------------------------------------------------

class _Geom:
	extends RefCounted
	var frame := SurfaceTool.new()
	var beam := SurfaceTool.new()
	var lumber := SurfaceTool.new()
	var ply := SurfaceTool.new()
	var pv := SurfaceTool.new()
	var glass := SurfaceTool.new()
	## Painted parts (doors), one surface per colour: "#rrggbb" -> SurfaceTool.
	var paint := {}
	var counts := {"uprights": 0, "beams": 0, "lumber": 0, "plywood": 0,
		"solar_panels": 0, "solar_watts": 0.0, "glazing": 0, "doors": 0, "windows": 0,
		"stairs": 0, "railing_ft": 0.0}

	func _init() -> void:
		frame.begin(Mesh.PRIMITIVE_TRIANGLES)
		beam.begin(Mesh.PRIMITIVE_TRIANGLES)
		lumber.begin(Mesh.PRIMITIVE_TRIANGLES)
		ply.begin(Mesh.PRIMITIVE_TRIANGLES)
		pv.begin(Mesh.PRIMITIVE_TRIANGLES)
		glass.begin(Mesh.PRIMITIVE_TRIANGLES)

	func paint_for(hex: String) -> SurfaceTool:
		var key := hex.to_lower() if Color.html_is_valid(hex) else "#f2efe6"
		if not key.begins_with("#"):
			key = "#" + key
		if not paint.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			paint[key] = st
		return paint[key]


static func footprint_xz(spec: Dictionary = {}) -> Vector2:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	return Vector2(m.total_x, m.total_z)


static func _metrics(s: Dictionary) -> Dictionary:
	var module_x := float(s["beam_span_ft"]) * FT + POST_W
	var frame_depth := float(s["upright_depth_in"]) * IN
	# Clear spacing between adjacent rack rows (assemblies); joists span it below.
	var gap_z := float(s["row_gap_ft"]) * FT
	var rows := int(s["column_count"]) + 1
	var total_x := float(s["bay_count"]) * module_x
	var total_z := float(rows) * frame_depth + float(s["column_count"]) * gap_z
	return {
		"module_x": module_x, "frame_depth": frame_depth, "gap_z": gap_z,
		"rows": rows, "total_x": total_x, "total_z": total_z,
		"height": float(s["upright_height_ft"]) * FT,
	}


## Ordered list of deck levels: {y: beam-top height, roof: bool}.
static func _levels(s: Dictionary, _m: Dictionary = {}) -> Array:
	var out: Array = []
	var top: float = float(s["upright_height_ft"]) * FT
	for h in s["level_heights_ft"]:
		var y := float(h) * FT
		if y < top - 0.15:
			out.append({"y": y, "roof": false})
	if bool(s["roof_deck"]):
		out.append({"y": top, "roof": true})
	out.sort_custom(func(a, b): return float(a["y"]) < float(b["y"]))
	return out


static func build_node(spec: Dictionary = {}, node_name: String = "PalletRack") -> Node3D:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("rack_spec", s.duplicate(true))

	var g := _Geom.new()
	_emit_structure(g, s, m)

	var mesh := ArrayMesh.new()
	var mats: Array = []
	var pairs: Array = [[g.frame, _steel_frame_material()], [g.beam, _steel_beam_material()],
			[g.lumber, _lumber_material()], [g.ply, _plywood_material()],
			[g.pv, _pv_material()], [g.glass, _glass_material()]]
	for hex in g.paint.keys():
		pairs.append([g.paint[hex], _paint_material(str(hex))])
	# Arrays of the solid shade-makers (decks, walls, panels, doors) for the
	# shadow proxy below.
	var shade_arrays: Array = []
	for pair in pairs:
		var st: SurfaceTool = pair[0]
		var arr := st.commit_to_arrays()
		# An empty SurfaceTool returns a full-size array with a null vertex slot
		# (e.g. no plywood when decking + roof are both off) — skip it rather than
		# casting null to PackedVector3Array (which throws "Invalid cast").
		if not _arrays_have_geometry(arr):
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mats.append(pair[1])
		if st == g.ply or st == g.pv or g.paint.values().has(st):
			shade_arrays.append([arr, pair[1]])
	for i in mats.size():
		mesh.surface_set_material(i, mats[i])

	var mi := MeshInstance3D.new()
	mi.name = "RackMesh"
	mi.mesh = mesh

	# Shadow proxy (perf): the decks (plywood surface) are the solar-meaningful
	# solid shadow; the many thin steel members (posts, braces, beams, joists)
	# cast negligible ground shadow but multiply the shadow-pass triangle count
	# across all splits. Emit the deck surface alone as a SHADOWS_ONLY caster and
	# drop the detailed mesh from the shadow pass. PropRenderTuning's per-prop
	# "Shadows: All parts" override (meta _shadow_full) swaps back to full detail;
	# "Off" / global disable turns both off. Falls back to full-mesh shadows when
	# there is no deck geometry. Solar panels and doors cast too: a sloped
	# array is exactly the shade the solar sim needs to see.
	var has_ply := not shade_arrays.is_empty()
	if has_ply:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("_shadow_full", true)
	else:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Add the visible mesh FIRST so it stays the focus/outline + collision source.
	root.add_child(mi)
	if has_ply:
		var pmesh := ArrayMesh.new()
		for si in shade_arrays.size():
			pmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, shade_arrays[si][0])
			pmesh.surface_set_material(si, shade_arrays[si][1])
		var pmi := MeshInstance3D.new()
		pmi.name = "RackShadowProxy"
		pmi.mesh = pmesh
		pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		pmi.set_meta("_shadow_proxy", true)
		# Invisible depth-only caster — not a physics wall (decks already collide
		# via RackMesh) and not a focus/pick target.
		pmi.set_meta("skip_prop_collision", true)
		root.add_child(pmi)

	root.set_meta("bom", g.counts.duplicate())
	# Foot origin on ground centre so PlacedProp footing works (local Y=0).
	return root


static func _arrays_have_geometry(arr: Array) -> bool:
	if arr.size() <= Mesh.ARRAY_VERTEX:
		return false
	var verts: Variant = arr[Mesh.ARRAY_VERTEX]
	return verts is PackedVector3Array and not (verts as PackedVector3Array).is_empty()


static func build_default_node() -> Node3D:
	return build_node(default_spec())


static func bom(spec: Dictionary = {}) -> Dictionary:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var g := _Geom.new()
	_emit_structure(g, s, m)
	return g.counts.duplicate()


# ---------------------------------------------------------------------------
# Structure emission (drives both geometry and the bill of materials)
# ---------------------------------------------------------------------------

## Shared spatial layout (frame X lines, row Z lines, levels, notch) so geometry
## emission and the pick registry can never drift apart.
static func _layout(s: Dictionary, m: Dictionary) -> Dictionary:
	var bays := int(s["bay_count"])
	var rows: int = m.rows
	var module_x: float = m.module_x
	var frame_depth: float = m.frame_depth
	var gap_z: float = m.gap_z
	var total_x: float = m.total_x
	var total_z: float = m.total_z
	var height: float = m.height
	var x0 := -total_x * 0.5
	var z0 := -total_z * 0.5
	var row_pitch := frame_depth + gap_z
	var fx: Array = []
	for bx in range(bays + 1):
		fx.append(x0 + float(bx) * module_x)
	var rz: Array = []
	for r in range(rows):
		rz.append(z0 + float(r) * row_pitch)
	var notch := {}
	var rects: Array = []
	if bool(s["u_shape"]):
		var ow := float(s["u_open_bays"]) * module_x
		var od := float(s["u_open_cols"]) * row_pitch
		notch = {"x0": -ow * 0.5, "x1": ow * 0.5, "z0": z0, "z1": z0 + od}
		rects.append(notch.duplicate())
	# A courtyard opens columns col0 .. col0+cols-1 across bays bay0 .. +bays:
	# the deck cells there go, and so do the rack rows strictly INSIDE it; the
	# rows and uprights on its boundary stay and carry the decks round it.
	for e in (s.get("elements", []) as Array):
		if not (e is Dictionary) or str((e as Dictionary).get("type", "")) != "courtyard":
			continue
		var b0 := clampi(int(e.get("bay0", 0)), 0, bays - 1)
		var b1 := clampi(b0 + int(e.get("bays", 1)), b0 + 1, bays)
		var c0 := clampi(int(e.get("col0", 0)), 0, int(s["column_count"]) - 1)
		var c1 := clampi(c0 + int(e.get("cols", 1)), c0 + 1, int(s["column_count"]))
		rects.append({"x0": x0 + float(b0) * module_x, "x1": x0 + float(b1) * module_x,
			"z0": z0 + float(c0) * row_pitch + frame_depth + 0.03,
			"z1": z0 + float(c1) * row_pitch - 0.03})
	if not rects.is_empty():
		notch["rects"] = rects
	return {
		"bays": bays, "rows": rows, "cols": int(s["column_count"]),
		"module_x": module_x, "frame_depth": frame_depth, "gap_z": gap_z,
		"row_pitch": row_pitch, "total_x": total_x, "total_z": total_z,
		"height": height, "x0": x0, "z0": z0, "fx": fx, "rz": rz,
		"levels": _levels(s, m), "notch": notch,
	}


static func _cell_key(b: int, c: int, li: int) -> String:
	return "%d,%d,%d" % [b, c, li]


static func _beam_key(li: int, r: int, b: int, side: int) -> String:
	return "%d,%d,%d,%d" % [li, r, b, side]


## Z bounds of a deck cell in column gap c. Cells share the frame row between
## them at its midpoint so adjacent same-height cells read as one unbroken deck
## (co-planar bridging) while differing heights show a real step.
static func _cell_z_bounds(rz: Array, frame_depth: float, c: int, cols: int) -> Vector2:
	var z_start: float = float(rz[c]) if c == 0 else float(rz[c]) + frame_depth * 0.5
	var z_end: float
	if c == cols - 1:
		z_end = float(rz[c + 1]) + frame_depth
	else:
		z_end = float(rz[c + 1]) + frame_depth * 0.5
	return Vector2(z_start, z_end)


## Resolve one deck cell against the level template + per-cell overrides.
static func _resolve_cell(s: Dictionary, b: int, c: int, li: int,
		level: Dictionary, default_decked: bool) -> Dictionary:
	var kind := "deck" if (default_decked or bool(level["roof"])) else "none"
	var height_ft := float(level["y"]) / FT
	var depth_units := -1
	var ov: Dictionary = (s.get("cell_overrides", {}) as Dictionary).get(_cell_key(b, c, li), {})
	if ov.has("kind"):
		kind = str(ov["kind"])
	if ov.has("height_ft"):
		height_ft = float(ov["height_ft"])
	if ov.has("depth_units"):
		depth_units = int(ov["depth_units"])
	return {"kind": kind, "height_ft": height_ft, "y": height_ft * FT,
		"depth_units": depth_units}


static func _emit_structure(g: _Geom, s: Dictionary, m: Dictionary) -> void:
	var L := _layout(s, m)
	var bays: int = L.bays
	var rows: int = L.rows
	var cols: int = L.cols
	var frame_depth: float = L.frame_depth
	var height: float = L.height
	var fx: Array = L.fx
	var rz: Array = L.rz
	var levels: Array = L.levels
	var notch: Dictionary = L.notch
	var x0: float = L.x0
	var z0: float = L.z0
	var total_x: float = L.total_x
	var total_z: float = L.total_z
	var decked := bool(s["decked"])
	var beam_ov: Dictionary = s.get("beam_overrides", {})

	# Uprights (frames) at every row x bay-boundary.
	for r in range(rows):
		var zf := float(rz[r])
		for bx in range(bays + 1):
			var x := float(fx[bx])
			if _in_notch(notch, x, zf + frame_depth * 0.5):
				continue
			_emit_frame(g, x, zf, zf + frame_depth, height)
			g.counts["uprights"] += 1

	# Beams at every level x row x bay (front + back side), honoring overrides
	# (deleted beams vanish; dy_in nudges them 1" at a time).
	for li in range(levels.size()):
		var y := float(levels[li]["y"])
		for r in range(rows):
			var zf := float(rz[r])
			for b in range(bays):
				var cx := (float(fx[b]) + float(fx[b + 1])) * 0.5
				var span := float(fx[b + 1]) - float(fx[b]) - POST_W
				for side in range(2):
					var zb := zf if side == 0 else zf + frame_depth
					if _in_notch(notch, cx, zb):
						continue
					var ov: Dictionary = beam_ov.get(_beam_key(li, r, b, side), {})
					if bool(ov.get("deleted", false)):
						continue
					var yy := y + float(ov.get("dy_in", 0.0)) * IN
					_emit_box(g.beam, Transform3D(Basis(), Vector3(cx, yy - BEAM_H * 0.5, zb)),
						Vector3(span, BEAM_H, BEAM_T))
					g.counts["beams"] += 1

	# Decks emitted PER CELL (bay x column) so each is individually raiseable,
	# resizeable, steppable, or removable. Within a cell the plywood keeps the
	# per-bay 4' tiling (3x 4' sheets fill each 12' clear span, ~3" post gap).
	for li in range(levels.size()):
		var lv: Dictionary = levels[li]
		for c in range(cols):
			var zb := _cell_z_bounds(rz, frame_depth, c, cols)
			for b in range(bays):
				var cell := _resolve_cell(s, b, c, li, lv, decked)
				var kind := str(cell["kind"])
				if kind == "none":
					continue
				var y := float(cell["y"])
				var bx0 := float(fx[b]) + POST_W * 0.5
				var bx1 := float(fx[b + 1]) - POST_W * 0.5
				var cz0: float = zb.x
				var cz1: float = zb.y
				var du := int(cell.get("depth_units", -1))
				if du >= 0:
					cz1 = minf(cz1, cz0 + float(du) * HALF_PANEL_FT * FT)
				var ccx := (bx0 + bx1) * 0.5
				if _in_notch(notch, ccx, (cz0 + cz1) * 0.5):
					continue
				if kind == "step":
					var y_lo := float(levels[li - 1]["y"]) if li > 0 else 0.0
					_emit_stairs(g, bx0, bx1, cz0, cz1, y_lo, y, notch)
					continue
				_emit_joists_span(g, s, bx0, bx1, cz0, cz1, y, notch)
				_emit_ply_field(g, bx0, bx1, cz0, cz1, y + JOIST_H + PLY_T * 0.5, notch)

	# Plywood walls on chosen perimeter faces (doors / windows cut through).
	_emit_walls(g, s, m, x0, z0, total_x, total_z, height, notch)

	# Design elements: doors, windows, stairs, sloped arrays, railings.
	_emit_elements(g, s, L)


static func _emit_frame(g: _Geom, x: float, z0: float, z1: float, h: float) -> void:
	# Two posts.
	for z in [z0, z1]:
		_emit_box(g.frame, Transform3D(Basis(), Vector3(x, h * 0.5, z)),
			Vector3(POST_W, h, POST_W))
	# Foot plates.
	for z in [z0, z1]:
		_emit_box(g.frame, Transform3D(Basis(), Vector3(x, 0.02, z)),
			Vector3(POST_W * 1.6, 0.04, POST_W * 1.8))
	# Horizontal + diagonal bracing in the Z-Y plane between the two posts.
	var nodes := [0.15]
	var steps := maxi(2, int(h / 1.2))
	for i in range(1, steps + 1):
		nodes.append(0.15 + (h - 0.3) * float(i) / float(steps))
	var brace := POST_W * 0.55
	for yy in nodes:
		_emit_strut(g.frame, Vector3(x, yy, z0), Vector3(x, yy, z1), brace)
	for i in range(nodes.size() - 1):
		var y_lo := float(nodes[i])
		var y_hi := float(nodes[i + 1])
		var za := z0 if (i % 2 == 0) else z1
		var zb := z1 if (i % 2 == 0) else z0
		_emit_strut(g.frame, Vector3(x, y_lo, za), Vector3(x, y_hi, zb), brace)


static func _emit_joists_span(g: _Geom, s: Dictionary, x_a: float, x_b: float,
		z_a: float, z_b: float, beam_y: float, notch: Dictionary) -> void:
	var joist_cy := beam_y + JOIST_H * 0.5
	var span_z := z_b - z_a
	var joist_len := span_z + 2.0 * BEARING
	var joist_cz := (z_a + z_b) * 0.5
	# Joists run in Z across the cell depth, spaced along X within the bay span.
	var spacing := float(s["joist_spacing_in"]) * IN
	var w := x_b - x_a
	var n := maxi(2, int(w / spacing) + 1)
	for i in range(n):
		var jx := x_a + minf(float(i) * spacing, w)
		if i == n - 1:
			jx = x_b
		if _in_notch(notch, jx, joist_cz):
			continue
		_emit_box(g.lumber, Transform3D(Basis(), Vector3(jx, joist_cy, joist_cz)),
			Vector3(JOIST_W, JOIST_H, joist_len))
		g.counts["lumber"] += 1


static func _emit_stairs(g: _Geom, x_a: float, x_b: float, z_a: float,
		z_b: float, y_lo: float, y_hi: float, notch: Dictionary) -> void:
	var span := z_b - z_a
	var step_dz := span / float(STAIR_STEPS)
	var cxm := (x_a + x_b) * 0.5
	var wx := x_b - x_a
	for s_i in range(STAIR_STEPS):
		var za := z_a + step_dz * float(s_i)
		var zb2 := za + step_dz
		var y := y_lo + (y_hi - y_lo) * float(s_i + 1) / float(STAIR_STEPS)
		var cz := (za + zb2) * 0.5
		if _in_notch(notch, cxm, cz):
			continue
		# Support lumber under the tread.
		_emit_box(g.lumber, Transform3D(Basis(), Vector3(cxm, y - JOIST_H * 0.5, cz)),
			Vector3(wx, JOIST_H, step_dz * 0.9))
		g.counts["lumber"] += 1
		_emit_ply_field(g, x_a, x_b, za, zb2, y + PLY_T * 0.5, notch)


static func _emit_ply_field(g: _Geom, x_a: float, x_b: float, z_a: float, z_b: float,
		cy: float, notch: Dictionary, skip_z: Array = []) -> void:
	# Deck sheets run their 4' short edge along X — three of them fill each 12' bay
	# span between uprights — and their 8' long edge along Z (front→back, spanning
	# across the joists), so the deck stays unbroken from the player to the wall
	# and re-tiles cleanly as the half-panel-snapped assembly spacing changes.
	var w := x_b - x_a
	var d := z_b - z_a
	var nx := maxi(1, int(ceil(w / SHEET_SHORT)))
	var nz := maxi(1, int(ceil(d / SHEET_LONG)))
	for ix in range(nx):
		var sx0 := x_a + float(ix) * SHEET_SHORT
		var sxw := minf(SHEET_SHORT, x_b - sx0) - SEAM
		if sxw <= 0.01:
			continue
		for iz in range(nz):
			var sz0 := z_a + float(iz) * SHEET_LONG
			var szw := minf(SHEET_LONG, z_b - sz0) - SEAM
			if szw <= 0.01:
				continue
			var ccx := sx0 + sxw * 0.5
			var ccz := sz0 + szw * 0.5
			if _in_notch(notch, ccx, ccz):
				continue
			if _z_in_ranges(skip_z, ccz):
				continue
			_emit_box(g.ply, Transform3D(Basis(), Vector3(ccx, cy, ccz)),
				Vector3(sxw, PLY_T, szw))
			g.counts["plywood"] += 1


static func _z_in_ranges(ranges: Array, z: float) -> bool:
	for r in ranges:
		if r is Array and (r as Array).size() >= 2:
			if z >= float(r[0]) and z <= float(r[1]):
				return true
	return false


## The wall band (metres): [bottom, top].
static func _wall_band(s: Dictionary, L: Dictionary) -> Vector2:
	var height: float = L.height
	var top := height
	if float(s.get("wall_top_ft", -1.0)) >= 0.0:
		top = minf(height, float(s["wall_top_ft"]) * FT)
	var bottom := clampf(float(s.get("wall_bottom_ft", 0.0)) * FT, 0.0, maxf(top - 0.3, 0.0))
	return Vector2(bottom, top)


static func _wall_faces(s: Dictionary, L: Dictionary) -> Array:
	# [face, a0, a1, fixed, top, along_x, notch, bottom] per enabled wall.
	var w: Dictionary = s["walls"]
	var x0: float = L.x0
	var z0: float = L.z0
	var total_x: float = L.total_x
	var total_z: float = L.total_z
	var band := _wall_band(s, L)
	var height := band.y
	var notch: Dictionary = L.notch
	var out: Array = []
	if bool(w.get("front", false)):
		out.append(["front", x0, x0 + total_x, z0, height, true, notch, band.x])
	if bool(w.get("back", false)):
		out.append(["back", x0, x0 + total_x, z0 + total_z, height, true, {}, band.x])
	# Left and right as seen standing in front of the front (-Z) face: left
	# is +X, right is -X.
	if bool(w.get("left", false)):
		out.append(["left", z0, z0 + total_z, x0 + total_x, height, false, {}, band.x])
	if bool(w.get("right", false)):
		out.append(["right", z0, z0 + total_z, x0, height, false, {}, band.x])
	return out


## Sheet tiling for one wall face: [{ia, iv, pos, size, a0, a1, y0, y1}]. Shared
## by emission + picking so a deleted sheet always matches the box the player
## clicked. Sheets tile up from `y_base` (the wall band's bottom).
static func _wall_face_sheets(a0: float, a1: float, fixed: float, height: float,
		along_x: bool, notch: Dictionary, y_base: float = 0.0) -> Array:
	var out: Array = []
	var w := a1 - a0
	var na := maxi(1, int(ceil(w / SHEET_SHORT)))
	var nv := maxi(1, int(ceil((height - y_base) / SHEET_LONG)))
	for ia in range(na):
		var pa := a0 + float(ia) * SHEET_SHORT
		var paw := minf(SHEET_SHORT, a1 - pa) - SEAM
		if paw <= 0.01:
			continue
		for iv in range(nv):
			var vy := y_base + float(iv) * SHEET_LONG
			var vh := minf(SHEET_LONG, height - vy) - SEAM
			if vh <= 0.01:
				continue
			var cc := pa + paw * 0.5
			var cy := vy + vh * 0.5
			var pos: Vector3
			var size: Vector3
			if along_x:
				if _in_notch(notch, cc, fixed):
					continue
				pos = Vector3(cc, cy, fixed)
				size = Vector3(paw, vh, PLY_T)
			else:
				pos = Vector3(fixed, cy, cc)
				size = Vector3(PLY_T, vh, paw)
			out.append({"ia": ia, "iv": iv, "pos": pos, "size": size,
				"a0": pa, "a1": pa + paw, "y0": vy, "y1": vy + vh})
	return out


## The pieces of one wall sheet left after its doors and windows are cut out.
static func _sheet_pieces(sh: Dictionary, holes: Array) -> Array:
	var r := Rect2(float(sh["a0"]), float(sh["y0"]),
		float(sh["a1"]) - float(sh["a0"]), float(sh["y1"]) - float(sh["y0"]))
	return rect_minus(r, holes)


static func _emit_walls(g: _Geom, s: Dictionary, m: Dictionary, _x0: float, _z0: float,
		_total_x: float, _total_z: float, _height: float, _notch: Dictionary) -> void:
	var L := _layout(s, m)
	var deleted: Array = s.get("wall_sheet_deleted", [])
	for f in _wall_faces(s, L):
		var holes := _face_openings(s, L, str(f[0]))
		var along_x := bool(f[5])
		var fixed := float(f[3])
		for sh in _wall_face_sheets(f[1], f[2], f[3], f[4], f[5], f[6], f[7]):
			if deleted.has("%s,%d,%d" % [f[0], int(sh["ia"]), int(sh["iv"])]):
				continue
			if holes.is_empty():
				_emit_box(g.ply, Transform3D(Basis(), sh["pos"]), sh["size"])
				g.counts["plywood"] += 1
				continue
			var pieces := _sheet_pieces(sh, holes)
			if pieces.is_empty():
				continue
			for p in pieces:
				var pr: Rect2 = p
				var cc := pr.position.x + pr.size.x * 0.5
				var cy := pr.position.y + pr.size.y * 0.5
				if along_x:
					_emit_box(g.ply, Transform3D(Basis(), Vector3(cc, cy, fixed)),
						Vector3(pr.size.x, pr.size.y, PLY_T))
				else:
					_emit_box(g.ply, Transform3D(Basis(), Vector3(fixed, cy, cc)),
						Vector3(PLY_T, pr.size.y, pr.size.x))
			g.counts["plywood"] += 1


## Rectangle minus holes, as a few rectangles (grid split on the holes' edges,
## kept cells merged along each row). Area is conserved exactly.
static func rect_minus(r: Rect2, holes: Array) -> Array:
	var hs: Array = []
	for h in holes:
		if h is Rect2 and (h as Rect2).intersects(r):
			var ix := (h as Rect2).intersection(r)
			if ix.size.x > 0.001 and ix.size.y > 0.001:
				hs.append(ix)
	if hs.is_empty():
		return [r]
	var xs: Array = [r.position.x, r.end.x]
	var ys: Array = [r.position.y, r.end.y]
	for h in hs:
		var hr: Rect2 = h
		xs.append_array([hr.position.x, hr.end.x])
		ys.append_array([hr.position.y, hr.end.y])
	xs = _sorted_unique(xs)
	ys = _sorted_unique(ys)
	var out: Array = []
	for j in range(ys.size() - 1):
		var run_start := -1
		for i in range(xs.size()):
			var keep := false
			if i < xs.size() - 1:
				var c := Vector2((float(xs[i]) + float(xs[i + 1])) * 0.5,
					(float(ys[j]) + float(ys[j + 1])) * 0.5)
				keep = true
				for h in hs:
					if (h as Rect2).has_point(c):
						keep = false
						break
			if keep and run_start < 0:
				run_start = i
			elif not keep and run_start >= 0:
				var rr := Rect2(float(xs[run_start]), float(ys[j]),
					float(xs[i]) - float(xs[run_start]), float(ys[j + 1]) - float(ys[j]))
				if rr.size.x > 0.005 and rr.size.y > 0.005:
					out.append(rr)
				run_start = -1
	return out


static func _sorted_unique(vals: Array) -> Array:
	vals.sort()
	var out: Array = []
	for v in vals:
		if out.is_empty() or absf(float(v) - float(out[-1])) > 0.0005:
			out.append(float(v))
	return out


static func _in_notch(notch: Dictionary, x: float, z: float) -> bool:
	if notch.is_empty():
		return false
	if notch.has("rects"):
		for r in notch["rects"]:
			if _in_rect_xz(r, x, z):
				return true
		return false
	return _in_rect_xz(notch, x, z)


static func _in_rect_xz(notch: Dictionary, x: float, z: float) -> bool:
	var eps := 0.02
	return x > float(notch["x0"]) + eps and x < float(notch["x1"]) - eps \
		and z > float(notch["z0"]) - eps and z < float(notch["z1"]) - eps


# ---------------------------------------------------------------------------
# Occupancy grid (bays x columns) — used by the self-test and future editors.
# ---------------------------------------------------------------------------

static func deck_grid(spec: Dictionary = {}) -> Array:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var bays := int(s["bay_count"])
	var cols := int(s["column_count"])
	var module_x: float = m.module_x
	var frame_depth: float = m.frame_depth
	var row_pitch := frame_depth + float(m.gap_z)
	var total_x: float = m.total_x
	var total_z: float = m.total_z
	var x0 := -total_x * 0.5
	var z0 := -total_z * 0.5
	var notch: Dictionary = _layout(s, m).notch
	var grid: Array = []
	for b in range(bays):
		var row: Array = []
		var cx := x0 + (float(b) + 0.5) * module_x
		for c in range(cols):
			var back_z := z0 + float(c) * row_pitch + frame_depth
			var cz := back_z + float(m.gap_z) * 0.5
			row.append(bool(s["decked"]) and not _in_notch(notch, cx, cz))
		grid.append(row)
	return grid


# ---------------------------------------------------------------------------
# Pick registry (pure math, no physics) — deck cells, beams, wall sheets,
# uprights. Consumed by the modal's ray picker for hover / select / manipulate.
# ---------------------------------------------------------------------------

## Minimum clickable half-thickness so thin members (beams, sheets) stay easy
## to hit with a ray.
const PICK_MIN_THICK := 0.08


static func pick_components(spec: Dictionary = {}) -> Array:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var L := _layout(s, m)
	var out: Array = []
	var fx: Array = L.fx
	var rz: Array = L.rz
	var levels: Array = L.levels
	var notch: Dictionary = L.notch
	var frame_depth: float = L.frame_depth
	var height: float = L.height
	var bays: int = L.bays
	var rows: int = L.rows
	var cols: int = L.cols
	var decked := bool(s["decked"])
	var beam_ov: Dictionary = s.get("beam_overrides", {})

	# Deck cells.
	for li in range(levels.size()):
		var lv: Dictionary = levels[li]
		for c in range(cols):
			var zb := _cell_z_bounds(rz, frame_depth, c, cols)
			for b in range(bays):
				var cell := _resolve_cell(s, b, c, li, lv, decked)
				if str(cell["kind"]) == "none":
					continue
				var bx0 := float(fx[b]) + POST_W * 0.5
				var bx1 := float(fx[b + 1]) - POST_W * 0.5
				var cz0: float = zb.x
				var cz1: float = zb.y
				var du := int(cell.get("depth_units", -1))
				if du >= 0:
					cz1 = minf(cz1, cz0 + float(du) * HALF_PANEL_FT * FT)
				var ccx := (bx0 + bx1) * 0.5
				if _in_notch(notch, ccx, (cz0 + cz1) * 0.5):
					continue
				var y := float(cell["y"])
				var lo := Vector3(bx0, y - JOIST_H, cz0)
				var hi := Vector3(bx1, y + JOIST_H + PLY_T + 0.02, cz1)
				out.append({
					"id": "cell:" + _cell_key(b, c, li), "kind": str(cell["kind"]),
					"aabb": AABB(lo, hi - lo), "bay": b, "col": c, "level": li,
					"height_ft": float(cell["height_ft"]), "z0": cz0, "z1": cz1,
					"depth_units": du,
				})

	# Beams (front + back of each row per bay per level).
	for li in range(levels.size()):
		var y := float(levels[li]["y"])
		for r in range(rows):
			var zf := float(rz[r])
			for b in range(bays):
				var cx := (float(fx[b]) + float(fx[b + 1])) * 0.5
				var span := float(fx[b + 1]) - float(fx[b]) - POST_W
				for side in range(2):
					var zb := zf if side == 0 else zf + frame_depth
					if _in_notch(notch, cx, zb):
						continue
					var ov: Dictionary = beam_ov.get(_beam_key(li, r, b, side), {})
					if bool(ov.get("deleted", false)):
						continue
					var yy := y + float(ov.get("dy_in", 0.0)) * IN
					var center := Vector3(cx, yy - BEAM_H * 0.5, zb)
					var size := Vector3(span, BEAM_H, maxf(BEAM_T, PICK_MIN_THICK * 2.0))
					out.append({
						"id": "beam:" + _beam_key(li, r, b, side), "kind": "beam",
						"aabb": AABB(center - size * 0.5, size),
						"level": li, "row": r, "bay": b, "side": side,
						"dy_in": float(ov.get("dy_in", 0.0)),
					})

	# Wall sheets.
	var deleted: Array = s.get("wall_sheet_deleted", [])
	for f in _wall_faces(s, L):
		var holes := _face_openings(s, L, str(f[0]))
		for sh in _wall_face_sheets(f[1], f[2], f[3], f[4], f[5], f[6], f[7]):
			var key := "%s,%d,%d" % [f[0], int(sh["ia"]), int(sh["iv"])]
			if deleted.has(key):
				continue
			if not holes.is_empty() and _sheet_pieces(sh, holes).is_empty():
				continue
			var pos: Vector3 = sh["pos"]
			var size: Vector3 = sh["size"]
			size = size.max(Vector3(PICK_MIN_THICK, PICK_MIN_THICK, PICK_MIN_THICK) * 2.0)
			out.append({"id": "wall:" + key, "kind": "wall_sheet",
				"aabb": AABB(pos - size * 0.5, size), "face": str(f[0])})

	# Uprights (selectable but not manipulated in this editor).
	for r in range(rows):
		var zf := float(rz[r])
		for bx in range(bays + 1):
			var x := float(fx[bx])
			if _in_notch(notch, x, zf + frame_depth * 0.5):
				continue
			var lo := Vector3(x - POST_W, 0.0, zf - POST_W)
			var hi := Vector3(x + POST_W, height, zf + frame_depth + POST_W)
			out.append({"id": "post:%d,%d" % [r, bx], "kind": "upright",
				"aabb": AABB(lo, hi - lo), "row": r, "bx": bx})

	# Design elements (doors, windows, stairs, slope bays, railings, courtyards).
	for e in (s.get("elements", []) as Array):
		if e is Dictionary:
			out.append_array(_element_components(s, L, e as Dictionary))
	return out


## Every (bay, col, level) cell slot INCLUDING empty ones (kind "none"), with an
## AABB at the level-template height. Used by the step-placement tool so the
## player can drop a step onto any grid slot — occupied or not.
static func cell_slots(spec: Dictionary = {}) -> Array:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var L := _layout(s, m)
	var out: Array = []
	var fx: Array = L.fx
	var rz: Array = L.rz
	var levels: Array = L.levels
	var notch: Dictionary = L.notch
	var frame_depth: float = L.frame_depth
	var bays: int = L.bays
	var cols: int = L.cols
	var decked := bool(s["decked"])
	for li in range(levels.size()):
		var lv: Dictionary = levels[li]
		for c in range(cols):
			var zb := _cell_z_bounds(rz, frame_depth, c, cols)
			for b in range(bays):
				var bx0 := float(fx[b]) + POST_W * 0.5
				var bx1 := float(fx[b + 1]) - POST_W * 0.5
				var ccx := (bx0 + bx1) * 0.5
				if _in_notch(notch, ccx, (float(zb.x) + float(zb.y)) * 0.5):
					continue
				var cell := _resolve_cell(s, b, c, li, lv, decked)
				var y := float(cell["y"])
				var lo := Vector3(bx0, y - JOIST_H, zb.x)
				var hi := Vector3(bx1, y + JOIST_H + PLY_T + 0.02, zb.y)
				out.append({
					"id": "cell:" + _cell_key(b, c, li), "kind": str(cell["kind"]),
					"aabb": AABB(lo, hi - lo), "bay": b, "col": c, "level": li,
				})
	return out


## Slab test: distance along `dir` to the first hit of `box`, or -1 if none.
static func ray_hits_aabb(origin: Vector3, dir: Vector3, box: AABB) -> float:
	var tmin := -INF
	var tmax := INF
	var bmin := box.position
	var bmax := box.position + box.size
	for i in range(3):
		var o: float = origin[i]
		var d: float = dir[i]
		if absf(d) < 1e-9:
			if o < bmin[i] or o > bmax[i]:
				return -1.0
		else:
			var t1 := (bmin[i] - o) / d
			var t2 := (bmax[i] - o) / d
			if t1 > t2:
				var tmp := t1
				t1 = t2
				t2 = tmp
			tmin = maxf(tmin, t1)
			tmax = minf(tmax, t2)
			if tmin > tmax:
				return -1.0
	if tmax < 0.0:
		return -1.0
	return tmin if tmin >= 0.0 else tmax


## Ray against one pick component: its oriented box when it carries one (a
## slope bay), else its AABB.
static func ray_hits_component(origin: Vector3, dir: Vector3, comp: Dictionary) -> float:
	if comp.has("obb_xf"):
		var xf: Transform3D = comp["obb_xf"]
		var half: Vector3 = comp["obb_half"]
		var inv := xf.affine_inverse()
		return ray_hits_aabb(inv * origin, inv.basis * dir, AABB(-half, half * 2.0))
	return ray_hits_aabb(origin, dir, comp["aabb"] as AABB)


## Nearest component whose kind is in `kinds` (empty = any) along the ray.
static func pick_nearest(comps: Array, origin: Vector3, dir: Vector3,
		kinds: Array = []) -> Dictionary:
	var best: Dictionary = {}
	var best_t := INF
	for comp in comps:
		if not kinds.is_empty() and not kinds.has(str(comp.get("kind", ""))):
			continue
		var t := ray_hits_component(origin, dir, comp)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = comp
	return best


# ---------------------------------------------------------------------------
# Design elements — resolution, faces, floors
# ---------------------------------------------------------------------------

## Fill a record's type defaults and clamp it to the resolved rack `s`. A
## record of a type this build does not know (a newer build's) is kept as it
## is and not drawn, so saving here never loses it.
static func resolve_element(e: Dictionary, s: Dictionary) -> Dictionary:
	var t := str(e.get("type", ""))
	if not ELEMENT_DEFAULTS.has(t):
		return e.duplicate(true)
	var out: Dictionary = (ELEMENT_DEFAULTS[t] as Dictionary).duplicate(true)
	for k in e.keys():
		var v: Variant = e[k]
		out[str(k)] = v.duplicate(true) if (v is Dictionary or v is Array) else v
	out["type"] = t
	out["id"] = str(e.get("id", ""))
	var nlv := _levels(s).size()
	var m := _metrics(s)
	if out.has("face") and not FACES.has(str(out["face"])):
		out["face"] = str((ELEMENT_DEFAULTS[t] as Dictionary).get("face", "front"))
	match t:
		"door", "window":
			out["style"] = _pick_option(out["style"], DOOR_STYLES if t == "door" else WINDOW_STYLES)
			out["width_ft"] = clampf(float(out["width_ft"]), 1.0 if t == "window" else 2.0, 12.0)
			out["height_ft"] = clampf(float(out["height_ft"]), 1.0, 10.0)
			out["floor"] = clampi(int(out["floor"]), -1, nlv - 1)
			var flen := _face_len_ft(m, str(out["face"]))
			var hw := minf(float(out["width_ft"]) * 0.5, flen * 0.5)
			out["at_ft"] = clampf(float(out["at_ft"]), hw, maxf(hw, flen - hw))
			if t == "window":
				out["sill_ft"] = clampf(float(out["sill_ft"]), 0.0, 12.0)
			else:
				var c := str(out["color"])
				out["color"] = c if Color.html_is_valid(c) else "#f2efe6"
		"stair":
			out["run"] = _pick_option(out["run"], STAIR_RUNS)
			out["width_ft"] = clampf(float(out["width_ft"]), 2.0, 8.0)
			out["to_level"] = clampi(int(out["to_level"]), 0, maxi(nlv - 1, 0))
			out["flip"] = bool(out["flip"])
			out["handrail"] = bool(out["handrail"])
			out["at_ft"] = clampf(float(out["at_ft"]), 0.0, _face_len_ft(m, str(out["face"])))
		"lean_to":
			out["surface"] = _pick_option(out["surface"], SLOPE_SURFACES)
			out["ends"] = _pick_option(out["ends"], SLOPE_ENDS)
			out["orientation"] = _pick_option(out["orientation"], PANEL_ORIENTATIONS)
			out["angle_deg"] = clampf(float(out["angle_deg"]), 15.0, 75.0)
			out["attach_level"] = clampi(int(out["attach_level"]), -1, nlv - 1)
			out["bottom_ft"] = clampf(float(out["bottom_ft"]), 0.0,
				maxf(float(s["upright_height_ft"]) - 2.0, 0.0))
			out["panel_watts"] = clampf(float(out["panel_watts"]), 10.0, 1000.0)
			var nseg := _face_seg_count(s, str(out["face"]))
			out["seg_from"] = clampi(int(out["seg_from"]), 0, nseg - 1)
			var st := int(out["seg_to"])
			out["seg_to"] = -1 if (st < 0 or st >= nseg - 1) else maxi(st, int(out["seg_from"]))
			var segs := {}
			if out.get("segments") is Dictionary:
				for k in (out["segments"] as Dictionary).keys():
					var sv := str(out["segments"][k])
					if SLOPE_SURFACES.has(sv) and str(k).is_valid_int():
						segs[str(int(str(k)))] = sv
			out["segments"] = segs
		"railing":
			out["floor"] = clampi(int(out["floor"]), 0, maxi(nlv - 1, 0))
			out["height_ft"] = clampf(float(out["height_ft"]), 2.0, 5.0)
			for k in ["front", "back", "left", "right", "inner"]:
				out[k] = bool(out[k])
		"courtyard":
			var bays := int(s["bay_count"])
			var cols := int(s["column_count"])
			out["bay0"] = clampi(int(out["bay0"]), 0, bays - 1)
			out["bays"] = clampi(int(out["bays"]), 1, bays - int(out["bay0"]))
			out["col0"] = clampi(int(out["col0"]), 0, cols - 1)
			out["cols"] = clampi(int(out["cols"]), 1, cols - int(out["col0"]))
	return out


## A fresh element of `type` with `overrides` over its defaults (unresolved —
## the spec it lands in resolves it).
static func make_element(type: String, overrides: Dictionary = {}) -> Dictionary:
	var out: Dictionary = (ELEMENT_DEFAULTS.get(type, {}) as Dictionary).duplicate(true)
	out["type"] = type
	for k in overrides.keys():
		var v: Variant = overrides[k]
		out[k] = v.duplicate(true) if (v is Dictionary or v is Array) else v
	return out


static func _pick_option(v: Variant, options: Array) -> String:
	var sv := str(v)
	return sv if options.has(sv) else str(options[0])


static func _face_len_ft(m: Dictionary, face: String) -> float:
	return (float(m.total_x) if face == "front" or face == "back" else float(m.total_z)) / FT


static func _face_seg_count(s: Dictionary, face: String) -> int:
	return int(s["bay_count"]) if face == "front" or face == "back" else int(s["column_count"])


## A face's length in feet on `spec`.
static func face_length_ft(spec: Dictionary, face: String) -> float:
	return _face_len_ft(_metrics(resolve_spec(spec)), face)


## How many bays a sloped array can span on `face` (bays front/back, columns
## left/right).
static func face_segment_count(spec: Dictionary, face: String) -> int:
	return _face_seg_count(resolve_spec(spec), face)


## The face's frame: origin at its start on the post centre line, `along` the
## face, `out` its outward normal. Positions on a face are (a, y, o).
static func _face_frame(face: String, L: Dictionary) -> Dictionary:
	var x0: float = L.x0
	var z0: float = L.z0
	var tx: float = L.total_x
	var tz: float = L.total_z
	match face:
		"back":
			return {"face": face, "base": Vector3(x0, 0.0, z0 + tz), "along": Vector3.RIGHT,
				"out": Vector3.BACK, "len": tx}
		"left":
			return {"face": face, "base": Vector3(x0 + tx, 0.0, z0), "along": Vector3.BACK,
				"out": Vector3.RIGHT, "len": tz}
		"right":
			return {"face": face, "base": Vector3(x0, 0.0, z0), "along": Vector3.BACK,
				"out": Vector3.LEFT, "len": tz}
	return {"face": "front", "base": Vector3(x0, 0.0, z0), "along": Vector3.RIGHT,
		"out": Vector3.FORWARD, "len": tx}


static func _fp(fr: Dictionary, a: float, y: float, o: float) -> Vector3:
	return (fr.base as Vector3) + (fr.along as Vector3) * a + Vector3.UP * y + (fr.out as Vector3) * o


## The face's start in the absolute along coordinate the wall sheets use
## (x for front/back, z for left/right).
static func _face_coord0(fr: Dictionary) -> float:
	var b: Vector3 = fr.base
	return b.x if absf((fr.along as Vector3).x) > 0.5 else b.z


## The face's bays as [Vector2(a0, a1)] relative to its start: the bays for
## front/back, the decked columns (cut at the frame-row midpoints) left/right.
static func _face_segments(face: String, L: Dictionary) -> Array:
	var out: Array = []
	if face == "front" or face == "back":
		var fx: Array = L.fx
		for b in range(int(L.bays)):
			out.append(Vector2(float(fx[b]) - float(L.x0), float(fx[b + 1]) - float(L.x0)))
	else:
		for c in range(int(L.cols)):
			var zb := _cell_z_bounds(L.rz, float(L.frame_depth), c, int(L.cols))
			out.append(Vector2(zb.x - float(L.z0), zb.y - float(L.z0)))
	return out


## Height of a floor's walking surface (m). -1 = the ground.
static func _floor_y(L: Dictionary, floor_i: int) -> float:
	var lv: Array = L.levels
	if floor_i < 0 or lv.is_empty():
		return 0.0
	return float(lv[mini(floor_i, lv.size() - 1)]["y"]) + JOIST_H + PLY_T


static func floor_y(spec: Dictionary, floor_i: int) -> float:
	var s := resolve_spec(spec)
	return _floor_y(_layout(s, _metrics(s)), floor_i)


## Every floor a door / stairs / railing can use: [{floor, label, y_ft}],
## the ground first.
static func floor_options(spec: Dictionary) -> Array:
	var s := resolve_spec(spec)
	var L := _layout(s, _metrics(s))
	var out: Array = [{"floor": -1, "label": "Ground", "y_ft": 0.0}]
	var lv: Array = L.levels
	for i in lv.size():
		var y_ft := _floor_y(L, i) / FT
		var name := "Roof" if bool(lv[i]["roof"]) else "Level %d" % (i + 1)
		out.append({"floor": i, "label": "%s · %s" % [name, fmt_ft(y_ft)], "y_ft": y_ft})
	return out


## The highest floor whose surface is at or below world height `y` (-1 = ground).
static func floor_at(spec: Dictionary, y: float) -> int:
	var s := resolve_spec(spec)
	var L := _layout(s, _metrics(s))
	var best := -1
	for i in (L.levels as Array).size():
		if _floor_y(L, i) <= y + 0.1:
			best = i
	return best


## Feet as 8' / 8' 6" / 6".
static func fmt_ft(ft: float) -> String:
	var total_in := int(round(ft * 12.0))
	var f := total_in / 12
	var i := total_in % 12
	if f == 0:
		return "%d\"" % i
	if i == 0:
		return "%d'" % f
	return "%d' %d\"" % [f, i]


## Where a camera ray first meets one of the four outer faces from outside:
## {face, along_ft, y, point, t}, or {} if it meets none.
static func face_hit(spec: Dictionary, origin: Vector3, dir: Vector3) -> Dictionary:
	var s := resolve_spec(spec)
	var L := _layout(s, _metrics(s))
	var best: Dictionary = {}
	var best_t := INF
	for face in FACES:
		var fr := _face_frame(face, L)
		var nrm: Vector3 = fr.out
		var denom := dir.dot(nrm)
		if denom > -1e-4:
			continue
		var t := ((fr.base as Vector3) - origin).dot(nrm) / denom
		if t <= 0.0 or t >= best_t:
			continue
		var p := origin + dir * t
		var a := (p - (fr.base as Vector3)).dot(fr.along as Vector3)
		var flen: float = fr.len
		if a < -0.3 or a > flen + 0.3 or p.y < -0.2 or p.y > float(L.height) + 0.6:
			continue
		best_t = t
		best = {"face": face, "along_ft": clampf(a, 0.0, flen) / FT, "y": p.y, "point": p, "t": t}
	return best


## Along-face position (ft) where a ray crosses `face`'s plane, from either
## side — the drag of a door or a window along its wall. NAN when parallel.
static func face_plane_along_ft(spec: Dictionary, face: String, origin: Vector3,
		dir: Vector3) -> float:
	var s := resolve_spec(spec)
	var L := _layout(s, _metrics(s))
	var fr := _face_frame(face, L)
	var nrm: Vector3 = fr.out
	var denom := dir.dot(nrm)
	if absf(denom) < 1e-5:
		return NAN
	var t := ((fr.base as Vector3) - origin).dot(nrm) / denom
	if t <= 0.0:
		return NAN
	var p := origin + dir * t
	return (p - (fr.base as Vector3)).dot(fr.along as Vector3) / FT


## Door and window holes on a face, as Rect2(along, y) in the wall sheets'
## absolute along coordinate.
static func _face_openings(s: Dictionary, L: Dictionary, face: String) -> Array:
	var out: Array = []
	var fr := _face_frame(face, L)
	var c0 := _face_coord0(fr)
	for e in (s.get("elements", []) as Array):
		if not (e is Dictionary):
			continue
		var t := str(e.get("type", ""))
		if (t != "door" and t != "window") or str(e.get("face", "")) != face:
			continue
		var w := float(e["width_ft"]) * FT
		var h := float(e["height_ft"]) * FT
		var y0 := _floor_y(L, int(e["floor"]))
		if t == "window":
			y0 += float(e["sill_ft"]) * FT
		out.append(Rect2(c0 + float(e["at_ft"]) * FT - w * 0.5, y0, w, h))
	return out


## One-line description of an element for lists and the HUD.
static func element_label(e: Dictionary, spec: Dictionary = {}) -> String:
	var t := str(e.get("type", ""))
	var name := str(ELEMENT_LABELS.get(t, t.capitalize()))
	var face := str(OPTION_LABELS.get(str(e.get("face", "")), "")).to_lower()
	match t:
		"door":
			return "%s · %s, %s wall" % [str(OPTION_LABELS.get(str(e.get("style", "")), name)),
				fmt_ft(float(e.get("width_ft", 3.0))), face]
		"window":
			return "Window · %s wall" % face
		"stair":
			return "Stairs · %s face, up to %s" % [face, _floor_name(spec, int(e.get("to_level", 0)))]
		"lean_to":
			return "%s · %s face" % [str(OPTION_LABELS.get(str(e.get("surface", "")), name)), face]
		"railing":
			return "Railing · %s" % _floor_name(spec, int(e.get("floor", 0)))
		"courtyard":
			var b0 := int(e.get("bay0", 0)) + 1
			var nb := int(e.get("bays", 1))
			return "Courtyard · %s" % (("bay %d" % b0) if nb == 1 else ("bays %d–%d" % [b0, b0 + nb - 1]))
	return name


static func _floor_name(spec: Dictionary, floor_i: int) -> String:
	if spec.is_empty():
		return "level %d" % (floor_i + 1)
	for o in floor_options(spec):
		if int(o["floor"]) == floor_i:
			return str(o["label"]).get_slice(" · ", 0)
	return "level %d" % (floor_i + 1)


## The element mirrored onto the opposite face (same height, mirrored position).
static func mirror_element(e: Dictionary, spec: Dictionary) -> Dictionary:
	var out := e.duplicate(true)
	out.erase("id")
	var face := str(e.get("face", ""))
	if not OPPOSITE_FACE.has(face):
		return out
	var to := str(OPPOSITE_FACE[face])
	out["face"] = to
	if out.has("at_ft"):
		out["at_ft"] = face_length_ft(spec, to) - float(e["at_ft"])
	if str(e.get("type", "")) == "stair":
		out["flip"] = not bool(e.get("flip", false))
	return out


# ---------------------------------------------------------------------------
# Design elements — emission
# ---------------------------------------------------------------------------

static func _emit_elements(g: _Geom, s: Dictionary, L: Dictionary) -> void:
	for e in (s.get("elements", []) as Array):
		if not (e is Dictionary):
			continue
		match str((e as Dictionary).get("type", "")):
			"door":
				_emit_door(g, L, e)
			"window":
				_emit_window(g, L, e)
			"stair":
				_emit_stair(g, L, e)
			"lean_to":
				_emit_lean_to(g, s, L, e)
			"railing":
				_emit_railing(g, s, L, e)
			# A courtyard is a cut in the layout (_layout's notch rects), not geometry.


## Box centred at `center` with its X along `ax` and Y along `ay` (made
## orthogonal), size in that frame.
static func _emit_obox(st: SurfaceTool, center: Vector3, ax: Vector3, ay: Vector3,
		size: Vector3) -> void:
	var xn := ax.normalized()
	var yn := (ay - xn * ay.dot(xn)).normalized()
	_emit_box(st, Transform3D(Basis(xn, yn, xn.cross(yn)), center), size)


## Box in a face's frame; size = (along, up, out).
static func _emit_face_box(st: SurfaceTool, fr: Dictionary, a: float, y: float, o: float,
		size: Vector3) -> void:
	_emit_obox(st, _fp(fr, a, y, o), fr.along as Vector3, Vector3.UP, size)


static func _face_aabb(fr: Dictionary, a: float, y: float, o: float, size: Vector3) -> AABB:
	var c := _fp(fr, a, y, o)
	var ext := ((fr.along as Vector3) * size.x).abs() + Vector3(0.0, size.y, 0.0) \
		+ ((fr.out as Vector3) * size.z).abs()
	return AABB(c - ext * 0.5, ext)


static func _emit_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length() < 1e-6:
		return
	n = n.normalized()
	for p in [[a, Vector2(0, 0)], [b, Vector2(1, 0)], [c, Vector2(1, 1)]]:
		st.set_normal(n)
		st.set_uv(p[1])
		st.add_vertex(p[0])


static func _emit_quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	_emit_tri(st, p0, p1, p2)
	_emit_tri(st, p0, p2, p3)


## 1x4 casing round an opening, proud of the wall on both sides.
static func _emit_casing(g: _Geom, fr: Dictionary, a: float, y0: float, w: float, h: float,
		sill: bool) -> void:
	var t := PLY_T + 1.5 * IN
	_emit_face_box(g.lumber, fr, a - w * 0.5 - TRIM_W * 0.5, y0 + h * 0.5, 0.0, Vector3(TRIM_W, h, t))
	_emit_face_box(g.lumber, fr, a + w * 0.5 + TRIM_W * 0.5, y0 + h * 0.5, 0.0, Vector3(TRIM_W, h, t))
	_emit_face_box(g.lumber, fr, a, y0 + h + TRIM_W * 0.5, 0.0, Vector3(w + 2.0 * TRIM_W, TRIM_W, t))
	g.counts["lumber"] += 3
	if sill:
		_emit_face_box(g.lumber, fr, a, y0 - TRIM_W * 0.4, 0.03,
			Vector3(w + 2.0 * TRIM_W + 0.05, TRIM_W * 0.8, t + 0.07))
		g.counts["lumber"] += 1


static func _emit_door(g: _Geom, L: Dictionary, e: Dictionary) -> void:
	var fr := _face_frame(str(e["face"]), L)
	var w := float(e["width_ft"]) * FT
	var h := float(e["height_ft"]) * FT
	var a := float(e["at_ft"]) * FT
	var y0 := _floor_y(L, int(e["floor"]))
	_emit_casing(g, fr, a, y0, w, h, false)
	var paint := g.paint_for(str(e.get("color", "")))
	var hw := g.paint_for("#2b2b2b")
	match str(e["style"]):
		"hinged":
			_emit_door_leaf(paint, hw, fr, a, y0, w - 0.008, h - 0.008, 1.0)
		"double":
			var lw := w * 0.5 - 0.006
			_emit_door_leaf(paint, hw, fr, a - w * 0.25, y0, lw, h - 0.008, 1.0)
			_emit_door_leaf(paint, hw, fr, a + w * 0.25, y0, lw, h - 0.008, -1.0)
		"sliding":
			# A barn door hung outside the wall on a track twice the opening wide.
			var o := (PLY_T + 1.5 * IN) * 0.5 + 0.02 + DOOR_T * 0.5
			var dw := w + 4.0 * IN
			var dh := h + 2.0 * IN
			_emit_face_box(paint, fr, a, dh * 0.5 + y0, o, Vector3(dw, dh, DOOR_T))
			var face_o := o + DOOR_T * 0.5 + 0.008
			for fy in [0.12, 0.88]:
				_emit_face_box(paint, fr, a, y0 + dh * fy, face_o, Vector3(dw - 0.02, 0.14, 0.016))
			var p_a := _fp(fr, a - dw * 0.5 + 0.08, y0 + dh * 0.16, face_o)
			var p_b := _fp(fr, a + dw * 0.5 - 0.08, y0 + dh * 0.84, face_o)
			_emit_obox(paint, (p_a + p_b) * 0.5, p_b - p_a, fr.out as Vector3,
				Vector3((p_b - p_a).length(), 0.016, 0.13))
			var ty := y0 + dh + 0.07
			_emit_face_box(g.frame, fr, a + w * 0.5, ty, o, Vector3(w * 2.0 + 0.3, 0.05, 0.035))
			for hx in [-0.35, 0.35]:
				_emit_face_box(hw, fr, a + dw * hx, y0 + dh + 0.03, o, Vector3(0.04, 0.14, 0.012))
			_emit_face_box(hw, fr, a + dw * 0.5 - 0.12, y0 + 1.0, face_o + 0.025, Vector3(0.03, 0.3, 0.03))
		_:
			pass  # an open doorway: casing only
	g.counts["doors"] += 1


## One slab with six raised panels each side and a knob on `handle_side`.
static func _emit_door_leaf(paint: SurfaceTool, hw: SurfaceTool, fr: Dictionary, a: float,
		y0: float, w: float, h: float, handle_side: float) -> void:
	_emit_face_box(paint, fr, a, y0 + h * 0.5 + 0.004, 0.0, Vector3(w, h, DOOR_T))
	var pw := w * 0.36
	var ph := h * 0.24
	for ci in [-1.0, 1.0]:
		for ri in range(3):
			var py := y0 + h * (0.2 + 0.3 * float(ri))
			for side in [-1.0, 1.0]:
				_emit_face_box(paint, fr, a + ci * w * 0.22, py, side * (DOOR_T * 0.5 + 0.003),
					Vector3(pw, ph, 0.006))
	for side in [-1.0, 1.0]:
		_emit_face_box(hw, fr, a + handle_side * (w * 0.5 - 0.07), y0 + 0.92,
			side * (DOOR_T * 0.5 + 0.03), Vector3(0.05, 0.05, 0.06))


static func _emit_window(g: _Geom, L: Dictionary, e: Dictionary) -> void:
	var fr := _face_frame(str(e["face"]), L)
	var w := float(e["width_ft"]) * FT
	var h := float(e["height_ft"]) * FT
	var a := float(e["at_ft"]) * FT
	var y0 := _floor_y(L, int(e["floor"])) + float(e["sill_ft"]) * FT
	_emit_casing(g, fr, a, y0, w, h, true)
	if str(e["style"]) == "glass":
		_emit_face_box(g.glass, fr, a, y0 + h * 0.5, 0.0, Vector3(w, h, 0.006))
		_emit_face_box(g.lumber, fr, a, y0 + h * 0.5, 0.0, Vector3(0.03, h, 0.03))
		_emit_face_box(g.lumber, fr, a, y0 + h * 0.5, 0.0, Vector3(w, 0.03, 0.03))
	g.counts["windows"] += 1


## A straight flight: risers no taller than RISER_MAX, treads TREAD_RUN deep.
## "along" runs parallel to the face, outside it, to a landing beside the deck
## edge at `at`; "out" runs straight away from the face with its top at `at`.
static func _stair_geo(L: Dictionary, e: Dictionary) -> Dictionary:
	var fr := _face_frame(str(e["face"]), L)
	var y_top := _floor_y(L, int(e["to_level"]))
	if y_top < 0.3:
		return {}
	var n := maxi(2, int(ceil(y_top / RISER_MAX)))
	return {"fr": fr, "y_top": y_top, "n": n, "riser": y_top / float(n),
		"w": float(e["width_ft"]) * FT, "a": float(e["at_ft"]) * FT,
		"o0": POST_W * 0.5 + 0.03, "along": str(e["run"]) == "along",
		"sgn": -1.0 if bool(e["flip"]) else 1.0}


## A point on the flight: `dist` back (downhill) from its top, `lat` across it.
static func _stair_point(G: Dictionary, dist: float, lat: float, y: float) -> Vector3:
	var fr: Dictionary = G.fr
	if bool(G.along):
		return _fp(fr, float(G.a) - float(G.sgn) * dist, y, float(G.o0) + float(G.w) * 0.5 + lat)
	return _fp(fr, float(G.a) + lat, y, float(G.o0) + dist)


## [downhill direction, across direction] of a flight.
static func _stair_axes(G: Dictionary) -> Array:
	var fr: Dictionary = G.fr
	if bool(G.along):
		return [-(fr.along as Vector3) * float(G.sgn), fr.out as Vector3]
	return [fr.out as Vector3, fr.along as Vector3]


static func _emit_stair(g: _Geom, L: Dictionary, e: Dictionary) -> void:
	var G := _stair_geo(L, e)
	if G.is_empty():
		return
	var axes := _stair_axes(G)
	var run_dir: Vector3 = axes[0]
	var n: int = G.n
	var w: float = G.w
	var riser: float = G.riser
	var y_top: float = G.y_top
	for k in range(1, n):
		var c := _stair_point(G, float(n - k) * TREAD_RUN - TREAD_RUN * 0.5, 0.0,
			riser * float(k) - 0.75 * IN)
		_emit_obox(g.lumber, c, run_dir, Vector3.UP, Vector3(TREAD_RUN + IN, 1.5 * IN, w))
		g.counts["lumber"] += 1
	for lat in [-w * 0.5 + 0.03, w * 0.5 - 0.03]:
		var p_bot := _stair_point(G, float(n) * TREAD_RUN, lat, 0.0)
		var p_top := _stair_point(G, 0.0, lat, y_top)
		var dv := p_top - p_bot
		_emit_obox(g.lumber, (p_bot + p_top) * 0.5 + Vector3.DOWN * (STRINGER_D * 0.45), dv,
			Vector3.UP, Vector3(dv.length(), STRINGER_D, 1.5 * IN))
		g.counts["lumber"] += 1
	if bool(G.along):
		# The landing the flight arrives on, beside the deck edge.
		var fr: Dictionary = G.fr
		var la: float = float(G.a) + float(G.sgn) * w * 0.5
		var lo: float = float(G.o0) + w * 0.5
		_emit_face_box(g.ply, fr, la, y_top - PLY_T * 0.5, lo, Vector3(w, PLY_T, w))
		_emit_face_box(g.lumber, fr, la, y_top - PLY_T - JOIST_H * 0.5, lo,
			Vector3(w - 0.02, JOIST_H, w - 0.02))
		var leg_h := y_top - PLY_T - JOIST_H
		for fa in [0.08, 0.92]:
			_emit_face_box(g.lumber, fr, float(G.a) + float(G.sgn) * w * fa, leg_h * 0.5,
				float(G.o0) + w - 0.06, Vector3(LEG_W, leg_h, LEG_W))
		g.counts["plywood"] += 1
		g.counts["lumber"] += 3
		if bool(e.get("handrail", true)):
			var c0 := _fp(fr, float(G.a), y_top, float(G.o0) + w - 0.04)
			var c1 := _fp(fr, float(G.a) + float(G.sgn) * w, y_top, float(G.o0) + w - 0.04)
			var c2 := _fp(fr, float(G.a) + float(G.sgn) * w, y_top, float(G.o0) + 0.05)
			_emit_rail_run(g, c0, c1, 3.0 * FT)
			_emit_rail_run(g, c1, c2, 3.0 * FT)
	if bool(e.get("handrail", true)):
		var sides: Array = [w * 0.5] if bool(G.along) else [-w * 0.5, w * 0.5]
		for lat in sides:
			var b := _stair_point(G, float(n - 1) * TREAD_RUN, lat, riser)
			var t := _stair_point(G, 0.0, lat, y_top)
			for p in [b, t]:
				_emit_obox(g.lumber, (p as Vector3) + Vector3.UP * (STAIR_RAIL_H * 0.5), Vector3.UP,
					run_dir, Vector3(STAIR_RAIL_H, 1.5 * IN, 3.5 * IN))
			_emit_strut(g.lumber, b + Vector3.UP * STAIR_RAIL_H, t + Vector3.UP * STAIR_RAIL_H, 0.045)
			g.counts["lumber"] += 3
	g.counts["stairs"] += 1


## The deck edge each flight lands on, per face, as along intervals (absolute)
## railings leave open.
static func _stair_gaps(s: Dictionary, L: Dictionary, li: int) -> Dictionary:
	var out := {}
	for e in (s.get("elements", []) as Array):
		if not (e is Dictionary) or str(e.get("type", "")) != "stair":
			continue
		if int(e.get("to_level", -9)) != li:
			continue
		var face := str(e["face"])
		var fr := _face_frame(face, L)
		var a := _face_coord0(fr) + float(e["at_ft"]) * FT
		var w := float(e["width_ft"]) * FT
		var gap: Vector2
		if str(e["run"]) == "along":
			gap = Vector2(a - 0.05, a + w + 0.05) if not bool(e["flip"]) \
				else Vector2(a - w - 0.05, a + 0.05)
		else:
			gap = Vector2(a - w * 0.5 - 0.05, a + w * 0.5 + 0.05)
		if not out.has(face):
			out[face] = []
		(out[face] as Array).append(gap)
	return out


# ---- Sloped (lean-to) arrays ----

## The slope's geometry: the panel plane runs from (o_bot, bot_y) up to
## (o_top, top_y) outside the face; `d` points up the slope, `n` is the plane's
## outward/upward normal (its tilt from the vertical IS the slope angle).
static func _lean_to_geo(s: Dictionary, L: Dictionary, e: Dictionary) -> Dictionary:
	var face := str(e["face"])
	var fr := _face_frame(face, L)
	var height: float = L.height
	var top_y := height
	var al := int(e.get("attach_level", -1))
	if al >= 0 and not (L.levels as Array).is_empty():
		top_y = clampf(_floor_y(L, al), 0.6, height + 0.2)
	var bot_y := clampf(float(e["bottom_ft"]) * FT, 0.0, top_y - 0.4)
	var ang := deg_to_rad(clampf(float(e["angle_deg"]), 15.0, 75.0))
	var rise := top_y - bot_y
	var run := rise / tan(ang)
	var slope_len := sqrt(run * run + rise * rise)
	var out_v: Vector3 = fr.out
	var d := (-out_v * run + Vector3.UP * rise) / slope_len
	var nv := (out_v * rise + Vector3.UP * run) / slope_len
	# Push the plane out so the rafters under it clear the uprights at the top.
	var o_top := POST_W * 0.5 + 0.03 + (PURLIN_T + RAFTER_D) * rise / slope_len
	var segs_all := _face_segments(face, L)
	var sf := clampi(int(e["seg_from"]), 0, segs_all.size() - 1)
	var stt := int(e["seg_to"])
	if stt < 0 or stt >= segs_all.size():
		stt = segs_all.size() - 1
	var segments: Dictionary = e.get("segments", {}) if e.get("segments") is Dictionary else {}
	var segs: Array = []
	for i in range(sf, stt + 1):
		segs.append({"i": i, "a0": float(segs_all[i].x), "a1": float(segs_all[i].y),
			"surface": str(segments.get(str(i), e["surface"]))})
	return {"fr": fr, "top_y": top_y, "bot_y": bot_y, "run": run, "rise": rise,
		"slope_len": slope_len, "d": d, "n": nv, "o_top": o_top, "o_bot": o_top + run,
		"segs": segs}


static func _lean_point(G: Dictionary, a: float, s_up: float, lift: float) -> Vector3:
	return _fp(G.fr, a, float(G.bot_y), float(G.o_bot)) + (G.d as Vector3) * s_up \
		+ (G.n as Vector3) * lift


## How many modules fit one bay of the slope, and where the grid starts.
static func _pv_layout(G: Dictionary, a0: float, a1: float, e: Dictionary) -> Dictionary:
	var land := str(e.get("orientation", "landscape")) != "portrait"
	var pw := PV_LONG if land else PV_SHORT
	var ph := PV_SHORT if land else PV_LONG
	var slen: float = G.slope_len
	var nc := int(floor((a1 - a0 - 0.04 + PV_GAP) / (pw + PV_GAP)))
	var nr := int(floor((slen - 0.04 + PV_GAP) / (ph + PV_GAP)))
	if nc <= 0 or nr <= 0:
		return {"count": 0}
	var used_a := float(nc) * pw + float(nc - 1) * PV_GAP
	var used_s := float(nr) * ph + float(nr - 1) * PV_GAP
	return {"count": nc * nr, "nc": nc, "nr": nr, "pw": pw, "ph": ph, "land": land,
		"a_start": a0 + (a1 - a0 - used_a) * 0.5, "s_start": (slen - used_s) * 0.5}


static func _emit_lean_to(g: _Geom, s: Dictionary, L: Dictionary, e: Dictionary) -> void:
	var G := _lean_to_geo(s, L, e)
	var fr: Dictionary = G.fr
	var along_v: Vector3 = fr.along
	var dv: Vector3 = G.d
	var nv: Vector3 = G.n
	var slen: float = G.slope_len
	var live: Array = []
	for sg in G.segs:
		if str(sg["surface"]) != "none":
			live.append(sg)
	if live.is_empty():
		return
	# Rafters at every bay edge and at most 4' apart in between.
	var raf: Array = []
	for sg in live:
		var a0: float = sg["a0"]
		var a1: float = sg["a1"]
		var nsub := maxi(1, int(ceil((a1 - a0) / (4.0 * FT))))
		for k in range(nsub + 1):
			raf.append(a0 + (a1 - a0) * float(k) / float(nsub))
	raf = _sorted_unique(raf)
	var amin: float = raf[0]
	var amax: float = raf[-1]
	var lift_r := -(PURLIN_T + RAFTER_D * 0.5)
	var under := -(PURLIN_T + RAFTER_D)
	for ra in raf:
		var a := clampf(float(ra), amin + RAFTER_W * 0.5, amax - RAFTER_W * 0.5)
		_emit_obox(g.lumber, _lean_point(G, a, slen * 0.5, lift_r), dv, nv,
			Vector3(slen, RAFTER_D, RAFTER_W))
		g.counts["lumber"] += 1
		# A leg under the low end, and a prop at mid-slope on tall arrays.
		for s_up in [0.12, slen * 0.5]:
			var foot := _lean_point(G, a, s_up, under)
			if (s_up < 0.5 and foot.y > 0.08) or (s_up > 0.5 and foot.y > 1.4):
				_emit_obox(g.lumber, Vector3(foot.x, foot.y * 0.5, foot.z), Vector3.UP, along_v,
					Vector3(foot.y, LEG_W, LEG_W))
				g.counts["lumber"] += 1
	var amid := (amin + amax) * 0.5
	var span := amax - amin
	_emit_obox(g.lumber, _lean_point(G, amid, slen - 0.07, lift_r), along_v, Vector3.UP,
		Vector3(span, RAFTER_D, RAFTER_W))
	var foot0 := _lean_point(G, amid, 0.12, under)
	if foot0.y > 0.08:
		_emit_obox(g.lumber, Vector3(foot0.x, 0.045, foot0.z), along_v, Vector3.UP,
			Vector3(span + LEG_W, 0.09, RAFTER_D))
	g.counts["lumber"] += 2
	for sg in live:
		var a0: float = sg["a0"]
		var a1: float = sg["a1"]
		var purlins: Array = []
		match str(sg["surface"]):
			"solar":
				var lay := _pv_layout(G, a0, a1, e)
				if int(lay["count"]) > 0:
					var long_ax: Vector3 = along_v if bool(lay["land"]) else dv
					var pw: float = lay["pw"]
					var ph: float = lay["ph"]
					for r in int(lay["nr"]):
						for c in int(lay["nc"]):
							var pa := float(lay["a_start"]) + float(c) * (pw + PV_GAP) + pw * 0.5
							var ps := float(lay["s_start"]) + float(r) * (ph + PV_GAP) + ph * 0.5
							_emit_obox(g.pv, _lean_point(G, pa, ps, PV_T * 0.5), long_ax, nv,
								Vector3(PV_LONG, PV_T, PV_SHORT))
					for r in range(int(lay["nr"]) + 1):
						purlins.append(float(lay["s_start"]) + float(r) * (ph + PV_GAP) - PV_GAP * 0.5)
					g.counts["solar_panels"] += int(lay["count"])
					g.counts["solar_watts"] += float(lay["count"]) * float(e["panel_watts"])
			"glazing":
				_emit_slope_sheets(g, g.glass, G, a0, a1, GLAZING_T, "glazing")
			"plywood":
				_emit_slope_sheets(g, g.ply, G, a0, a1, PLY_T, "plywood")
		if purlins.is_empty():
			var k := 0.0
			while k < slen:
				purlins.append(k)
				k += 2.0 * FT
			purlins.append(slen)
		for ps in purlins:
			var sp := clampf(float(ps), 0.04, slen - 0.04)
			_emit_obox(g.lumber, _lean_point(G, (a0 + a1) * 0.5, sp, -PURLIN_T * 0.5), along_v, nv,
				Vector3(a1 - a0, PURLIN_T, PURLIN_W))
			g.counts["lumber"] += 1
	# Close the triangular ends (a greenhouse) and the skirt under a raised slope.
	var ends := str(e.get("ends", "open"))
	if ends != "open":
		var st_e: SurfaceTool = g.glass if ends == "glazing" else g.ply
		var o_wall := POST_W * 0.5 + 0.02
		var top_y: float = G.top_y
		var bot_y: float = G.bot_y
		for a_end in [amin, amax]:
			var w_top := _fp(fr, a_end, top_y, o_wall)
			var p_top := _lean_point(G, a_end, slen, 0.0)
			var p_bot := _lean_point(G, a_end, 0.0, 0.0)
			var w_bot := _fp(fr, a_end, bot_y, o_wall)
			_emit_quad(st_e, w_top, p_top, p_bot, w_bot)
			if bot_y > 0.05:
				_emit_quad(st_e, w_bot, p_bot, Vector3(p_bot.x, 0.0, p_bot.z), Vector3(w_bot.x, 0.0, w_bot.z))
			g.counts["glazing" if ends == "glazing" else "plywood"] += 1


static func _emit_slope_sheets(g: _Geom, st: SurfaceTool, G: Dictionary, a0: float, a1: float,
		thick: float, count_key: String) -> void:
	var along_v: Vector3 = (G.fr as Dictionary).along
	var nv: Vector3 = G.n
	var slen: float = G.slope_len
	var na := maxi(1, int(ceil((a1 - a0) / SHEET_SHORT)))
	var ns := maxi(1, int(ceil(slen / SHEET_LONG)))
	for ia in range(na):
		var sa := a0 + float(ia) * SHEET_SHORT
		var sw := minf(SHEET_SHORT, a1 - sa) - SEAM
		if sw <= 0.01:
			continue
		for si in range(ns):
			var ss := float(si) * SHEET_LONG
			var sh := minf(SHEET_LONG, slen - ss) - SEAM
			if sh <= 0.01:
				continue
			_emit_obox(st, _lean_point(G, sa + sw * 0.5, ss + sh * 0.5, thick * 0.5), along_v, nv,
				Vector3(sw, thick, sh))
			g.counts[count_key] += 1


# ---- Railings ----

## Every deck / step cell of level `li` as {x0, x1, z0, z1, y (walking
## surface), kind} — the same cells _emit_structure draws.
static func _deck_rects(s: Dictionary, L: Dictionary, li: int) -> Array:
	var out: Array = []
	var levels: Array = L.levels
	if li < 0 or li >= levels.size():
		return out
	var fx: Array = L.fx
	var rz: Array = L.rz
	var notch: Dictionary = L.notch
	var cols: int = L.cols
	var decked := bool(s["decked"])
	for c in range(cols):
		var zb := _cell_z_bounds(rz, float(L.frame_depth), c, cols)
		for b in range(int(L.bays)):
			var cell := _resolve_cell(s, b, c, li, levels[li], decked)
			var kind := str(cell["kind"])
			if kind == "none":
				continue
			var bx0 := float(fx[b]) + POST_W * 0.5
			var bx1 := float(fx[b + 1]) - POST_W * 0.5
			var cz0: float = zb.x
			var cz1: float = zb.y
			var du := int(cell.get("depth_units", -1))
			if du >= 0:
				cz1 = minf(cz1, cz0 + float(du) * HALF_PANEL_FT * FT)
			if _in_notch(notch, (bx0 + bx1) * 0.5, (cz0 + cz1) * 0.5):
				continue
			out.append({"x0": bx0, "x1": bx1, "z0": cz0, "z1": cz1,
				"y": float(cell["y"]) + JOIST_H + PLY_T, "kind": kind})
	return out


static func _interval_minus(ivals: Array, cut: Vector2) -> Array:
	var out: Array = []
	for v in ivals:
		var iv: Vector2 = v
		if cut.y <= iv.x or cut.x >= iv.y:
			out.append(iv)
			continue
		if cut.x > iv.x:
			out.append(Vector2(iv.x, cut.x))
		if cut.y < iv.y:
			out.append(Vector2(cut.y, iv.y))
	return out


## The guard-rail runs a railing element makes: [{a, b, h}] at deck height.
## A rail goes on every edge of a deck cell that has no deck of the same
## height next to it (so courtyards, removed cells, shortened decks and the
## outer perimeter all get one), less the faces turned off, the stretches a
## wall already guards, and the gap each staircase lands through.
static func _railing_runs(s: Dictionary, L: Dictionary, e: Dictionary) -> Array:
	var li := int(e.get("floor", 0))
	var rects := _deck_rects(s, L, li)
	if rects.is_empty():
		return []
	var gaps := _stair_gaps(s, L, li)
	var band := _wall_band(s, L)
	var walls: Dictionary = s.get("walls", {})
	var rail_h := float(e.get("height_ft", 3.5)) * FT
	var x_lo: float = L.x0
	var x_hi: float = float(L.x0) + float(L.total_x)
	var z_lo: float = L.z0
	var z_hi: float = float(L.z0) + float(L.total_z)
	var raw: Array = []
	for ri in rects.size():
		var R: Dictionary = rects[ri]
		if str(R["kind"]) != "deck":
			continue
		var y: float = R["y"]
		for side in ["zmin", "zmax", "xmin", "xmax"]:
			var on_x: bool = side == "zmin" or side == "zmax"
			var fixed: float
			var face := "inner"
			match side:
				"zmin":
					fixed = R["z0"]
					if absf(fixed - z_lo) < 0.3:
						face = "front"
				"zmax":
					fixed = R["z1"]
					if absf(fixed - z_hi) < 0.3:
						face = "back"
				"xmin":
					fixed = R["x0"]
					if absf(fixed - x_lo) < 0.3:
						face = "right"
				_:
					fixed = R["x1"]
					if absf(fixed - x_hi) < 0.3:
						face = "left"
			if not bool(e.get(face, true)):
				continue
			if face != "inner" and bool(walls.get(face, false)) \
					and band.x <= y + 0.1 and band.y >= y + rail_h - 0.1:
				continue
			var iv: Array = [Vector2(R["x0"], R["x1"]) if on_x else Vector2(R["z0"], R["z1"])]
			for qi in rects.size():
				if qi == ri:
					continue
				var Q: Dictionary = rects[qi]
				if absf(float(Q["y"]) - y) > 0.2:
					continue
				var adj := false
				match side:
					"zmin":
						adj = absf(float(Q["z1"]) - fixed) < 0.25
					"zmax":
						adj = absf(float(Q["z0"]) - fixed) < 0.25
					"xmin":
						adj = absf(float(Q["x1"]) - fixed) < 0.25
					_:
						adj = absf(float(Q["x0"]) - fixed) < 0.25
				if adj:
					iv = _interval_minus(iv, Vector2(Q["x0"], Q["x1"]) if on_x else Vector2(Q["z0"], Q["z1"]))
			if face != "inner":
				for gp in (gaps.get(face, []) as Array):
					iv = _interval_minus(iv, gp)
			for v in iv:
				raw.append({"side": side, "fixed": fixed, "y": y, "u0": (v as Vector2).x, "u1": (v as Vector2).y})
	# Merge collinear runs across the 3" post gaps so a rail reads as one line.
	raw.sort_custom(func(p, q):
		if p["side"] != q["side"]:
			return str(p["side"]) < str(q["side"])
		if absf(float(p["fixed"]) - float(q["fixed"])) > 0.01:
			return float(p["fixed"]) < float(q["fixed"])
		if absf(float(p["y"]) - float(q["y"])) > 0.01:
			return float(p["y"]) < float(q["y"])
		return float(p["u0"]) < float(q["u0"]))
	var merged: Array = []
	for r in raw:
		if not merged.is_empty():
			var last: Dictionary = merged[-1]
			if last["side"] == r["side"] and absf(float(last["fixed"]) - float(r["fixed"])) < 0.01 \
					and absf(float(last["y"]) - float(r["y"])) < 0.01 \
					and float(r["u0"]) - float(last["u1"]) < POST_W + 0.05:
				last["u1"] = maxf(float(last["u1"]), float(r["u1"]))
				continue
		merged.append(r.duplicate())
	var out: Array = []
	for r in merged:
		var u0: float = r["u0"]
		var u1: float = r["u1"]
		if u1 - u0 < 0.15:
			continue
		var inward := 0.05
		var fx_: float = r["fixed"]
		match str(r["side"]):
			"zmin":
				fx_ += inward
			"zmax":
				fx_ -= inward
			"xmin":
				fx_ += inward
			_:
				fx_ -= inward
		var y: float = r["y"]
		var on_x: bool = str(r["side"]) == "zmin" or str(r["side"]) == "zmax"
		var pa := Vector3(u0, y, fx_) if on_x else Vector3(fx_, y, u0)
		var pb := Vector3(u1, y, fx_) if on_x else Vector3(fx_, y, u1)
		out.append({"a": pa, "b": pb, "h": rail_h})
	return out


static func _emit_railing(g: _Geom, s: Dictionary, L: Dictionary, e: Dictionary) -> void:
	for r in _railing_runs(s, L, e):
		_emit_rail_run(g, r["a"], r["b"], float(r["h"]))


## Posts at most RAIL_POST_MAX apart, a flat cap rail and a mid rail.
static func _emit_rail_run(g: _Geom, a: Vector3, b: Vector3, h: float) -> void:
	var dv := b - a
	var len := dv.length()
	if len < 0.1:
		return
	var axis := dv / len
	var np := maxi(1, int(ceil(len / RAIL_POST_MAX)))
	for k in range(np + 1):
		var p := a + axis * (len * float(k) / float(np))
		_emit_obox(g.lumber, p + Vector3.UP * (h * 0.5), Vector3.UP, axis,
			Vector3(h, 1.5 * IN, 3.5 * IN))
	_emit_obox(g.lumber, (a + b) * 0.5 + Vector3.UP * (h + 0.75 * IN), axis, Vector3.UP,
		Vector3(len + 0.09, 1.5 * IN, 3.5 * IN))
	_emit_obox(g.lumber, (a + b) * 0.5 + Vector3.UP * (h * 0.5), axis, Vector3.UP,
		Vector3(len, 3.5 * IN, 1.5 * IN))
	g.counts["lumber"] += np + 3
	g.counts["railing_ft"] += len / FT


# ---------------------------------------------------------------------------
# Design elements — picking, solar summary
# ---------------------------------------------------------------------------

## Pick boxes for one element: {id, kind "element", etype, el_id, aabb, [obb]}.
## A sloped array gets one oriented box per bay ("el:<id>:<bay>"), a railing
## one per run ("el:<id>:r<k>"); everything else one "el:<id>".
static func _element_components(s: Dictionary, L: Dictionary, e: Dictionary) -> Array:
	var id := str(e.get("id", ""))
	var t := str(e.get("type", ""))
	var base := {"kind": "element", "etype": t, "el_id": id, "face": str(e.get("face", ""))}
	var out: Array = []
	match t:
		"door", "window":
			var fr := _face_frame(str(e["face"]), L)
			var w := float(e["width_ft"]) * FT
			var h := float(e["height_ft"]) * FT
			var y0 := _floor_y(L, int(e["floor"]))
			if t == "window":
				y0 += float(e["sill_ft"]) * FT
			var c := base.duplicate()
			c["id"] = "el:" + id
			c["aabb"] = _face_aabb(fr, float(e["at_ft"]) * FT, y0 + h * 0.5 + TRIM_W * 0.25, 0.05,
				Vector3(w + 2.0 * TRIM_W, h + TRIM_W, 0.4))
			out.append(c)
		"stair":
			var G := _stair_geo(L, e)
			if G.is_empty():
				return out
			var w: float = G.w
			var n: int = G.n
			var box := AABB(_stair_point(G, 0.0, -w * 0.5, 0.0), Vector3.ZERO)
			for lat in [-w * 0.5, w * 0.5]:
				for p in [_stair_point(G, float(n) * TREAD_RUN, lat, 0.0),
						_stair_point(G, 0.0, lat, float(G.y_top) + STAIR_RAIL_H),
						_stair_point(G, -w if bool(G.along) else 0.0, lat, float(G.y_top))]:
					box = box.expand(p)
			var c := base.duplicate()
			c["id"] = "el:" + id
			c["aabb"] = box.grow(0.05)
			out.append(c)
		"lean_to":
			var G := _lean_to_geo(s, L, e)
			var along_v: Vector3 = (G.fr as Dictionary).along
			var nv: Vector3 = G.n
			var slen: float = G.slope_len
			for sg in G.segs:
				var a0: float = sg["a0"]
				var a1: float = sg["a1"]
				var half := Vector3((a1 - a0) * 0.5, 0.18, slen * 0.5)
				var xf := Transform3D(Basis(along_v, nv, along_v.cross(nv)),
					_lean_point(G, (a0 + a1) * 0.5, slen * 0.5, 0.0))
				var c := base.duplicate()
				c["id"] = "el:%s:%d" % [id, int(sg["i"])]
				c["seg"] = int(sg["i"])
				c["surface"] = str(sg["surface"])
				c["obb_xf"] = xf
				c["obb_half"] = half
				c["aabb"] = xf * AABB(-half, half * 2.0)
				out.append(c)
		"railing":
			var runs := _railing_runs(s, L, e)
			for k in runs.size():
				var r: Dictionary = runs[k]
				var pa: Vector3 = r["a"]
				var pb: Vector3 = r["b"]
				var box := AABB(pa, Vector3.ZERO).expand(pb).expand(pa + Vector3.UP * float(r["h"]))
				var c := base.duplicate()
				c["id"] = "el:%s:r%d" % [id, k]
				c["aabb"] = box.grow(0.1)
				out.append(c)
		"courtyard":
			var mx: float = L.module_x
			var pitch: float = L.row_pitch
			var x0 := float(L.x0) + float(e["bay0"]) * mx
			var x1 := x0 + float(e["bays"]) * mx
			var z0 := float(L.z0) + float(e["col0"]) * pitch + float(L.frame_depth)
			var z1 := float(L.z0) + float(int(e["col0"]) + int(e["cols"])) * pitch
			var c := base.duplicate()
			c["id"] = "el:" + id
			c["aabb"] = AABB(Vector3(x0, 0.0, z0), Vector3(x1 - x0, 0.25, maxf(z1 - z0, 0.3)))
			out.append(c)
	return out


## Pick boxes for one element on `spec` (resolved) — the placement ghost.
static func element_components(spec: Dictionary, element: Dictionary) -> Array:
	var s := resolve_spec(spec)
	var L := _layout(s, _metrics(s))
	var e := resolve_element(element, s)
	if str(e.get("id", "")).is_empty():
		e["id"] = "ghost"
	return _element_components(s, L, e)


## The solar modules on a rack's sloped arrays: {count, watts, watts_per_panel,
## avg_normal (builder-local), tilt_deg, panel_w_m, panel_h_m}. Counts match
## the geometry exactly (same _pv_layout).
static func solar_summary(spec: Dictionary) -> Dictionary:
	var s := resolve_spec(spec)
	var L := _layout(s, _metrics(s))
	var count := 0
	var watts := 0.0
	var nsum := Vector3.ZERO
	for e in (s.get("elements", []) as Array):
		if not (e is Dictionary) or str(e.get("type", "")) != "lean_to":
			continue
		var G := _lean_to_geo(s, L, e)
		for sg in G.segs:
			if str(sg["surface"]) != "solar":
				continue
			var n := int(_pv_layout(G, sg["a0"], sg["a1"], e)["count"])
			count += n
			watts += float(n) * float(e["panel_watts"])
			nsum += (G.n as Vector3) * float(n)
	var avg := nsum.normalized() if count > 0 else Vector3.UP
	return {"count": count, "watts": watts,
		"watts_per_panel": watts / float(count) if count > 0 else PV_WATTS,
		"avg_normal": avg, "tilt_deg": rad_to_deg(acos(clampf(avg.y, -1.0, 1.0))),
		"panel_w_m": PV_SHORT, "panel_h_m": PV_LONG}


# ---------------------------------------------------------------------------
# Design presets (built-in) + the player's library
# ---------------------------------------------------------------------------

## Starting points modelled on the Mars College builds. Each is a full spec.
static func design_presets() -> Array:
	return [
		{"id": "solar_workshop", "name": "Solar workshop",
			"blurb": "A roof deck with a solar lean-to down the front and a glazed greenhouse bay in the middle.",
			"spec": {"upright_height_ft": 16, "beam_span_ft": 12, "bay_count": 3, "column_count": 1,
				"row_gap_ft": 12.0, "deck_levels": 2, "level_heights_ft": [0.5, 8.0], "roof_deck": true,
				"elements": [
					{"type": "lean_to", "face": "front", "surface": "solar",
						"segments": {"1": "glazing"}, "angle_deg": 50.0, "bottom_ft": 1.5},
					{"type": "railing", "floor": 2, "front": false},
				]}},
		{"id": "two_storey", "name": "Two storey with stairs",
			"blurb": "A walled ground floor with a hinged and a sliding door, outside stairs to a railed upper deck.",
			"spec": {"upright_height_ft": 8, "beam_span_ft": 12, "bay_count": 2, "column_count": 1,
				"row_gap_ft": 12.0, "deck_levels": 1, "level_heights_ft": [0.5], "roof_deck": true,
				"walls": {"front": true, "back": false, "left": false, "right": true},
				"elements": [
					{"type": "door", "face": "front", "at_ft": 7.0, "floor": 0, "style": "hinged",
						"color": "#f2efe6"},
					{"type": "door", "face": "front", "at_ft": 17.0, "floor": 0, "style": "sliding",
						"width_ft": 4.0, "height_ft": 6.5, "color": "#e9c22b"},
					{"type": "window", "face": "right", "at_ft": 9.5, "floor": 0, "width_ft": 4.0},
					{"type": "stair", "face": "left", "at_ft": 11.5, "to_level": 1, "run": "along"},
					{"type": "railing", "floor": 1},
				]}},
		{"id": "amphitheatre", "name": "Stepped amphitheatre",
			"blurb": "Rack rows four feet apart, each a step higher, under a railed roof deck.",
			"spec": {"upright_height_ft": 12, "beam_span_ft": 12, "bay_count": 2, "column_count": 4,
				"row_gap_ft": 4.0, "deck_levels": 1, "level_heights_ft": [0.5], "roof_deck": true,
				"cell_overrides": {
					"0,1,0": {"height_ft": 2.0}, "1,1,0": {"height_ft": 2.0},
					"0,2,0": {"height_ft": 3.5}, "1,2,0": {"height_ft": 3.5},
					"0,3,0": {"height_ft": 5.0}, "1,3,0": {"height_ft": 5.0}},
				"elements": [
					{"type": "railing", "floor": 1},
					{"type": "stair", "face": "right", "at_ft": 3.0, "to_level": 1, "run": "along",
						"flip": true},
				]}},
		{"id": "courtyard_compound", "name": "Courtyard compound",
			"blurb": "Walled on all sides round an open courtyard, a double front door, windows, and stairs to the first floor.",
			"spec": {"upright_height_ft": 16, "beam_span_ft": 12, "bay_count": 4, "column_count": 3,
				"row_gap_ft": 8.0, "deck_levels": 2, "level_heights_ft": [0.5, 8.0], "roof_deck": true,
				"walls": {"front": true, "back": true, "left": true, "right": true},
				"elements": [
					{"type": "courtyard", "bay0": 1, "bays": 2, "col0": 1, "cols": 1},
					{"type": "door", "face": "front", "at_ft": 24.5, "floor": 0, "style": "double",
						"width_ft": 5.0, "color": "#c0472d"},
					{"type": "window", "face": "front", "at_ft": 8.0, "floor": 0},
					{"type": "window", "face": "front", "at_ft": 41.0, "floor": 0},
					{"type": "window", "face": "front", "at_ft": 12.0, "floor": 1, "width_ft": 6.0},
					{"type": "window", "face": "front", "at_ft": 37.0, "floor": 1, "width_ft": 6.0},
					{"type": "stair", "face": "back", "at_ft": 6.0, "to_level": 1, "run": "along",
						"flip": true},
					{"type": "door", "face": "back", "at_ft": 4.5, "floor": 1, "color": "#3d6b8f"},
					{"type": "railing", "floor": 1},
					{"type": "railing", "floor": 2},
				]}},
	]


static func design_preset(id: String) -> Dictionary:
	for d in design_presets():
		if str(d["id"]) == id:
			return d
	return {}


static func load_library(path: String = LIBRARY_PATH) -> Dictionary:
	var lib := {"version": LIBRARY_VERSION, "designs": [], "elements": []}
	if not FileAccess.file_exists(path):
		return lib
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		return lib
	for k in ["designs", "elements"]:
		var arr: Variant = (data as Dictionary).get(k, [])
		if not (arr is Array):
			continue
		for it in arr:
			if it is Dictionary and not str((it as Dictionary).get("name", "")).is_empty():
				(lib[k] as Array).append(it)
	return lib


static func save_library(lib: Dictionary, path: String = LIBRARY_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": LIBRARY_VERSION,
		"designs": lib.get("designs", []), "elements": lib.get("elements", [])}, "\t"))
	f.close()
	return true


# ---------------------------------------------------------------------------
# Box emission (merged into a SurfaceTool surface)
# ---------------------------------------------------------------------------

static func _emit_strut(st: SurfaceTool, a: Vector3, b: Vector3, thick: float) -> void:
	var dir := b - a
	var length := dir.length()
	if length < 0.001:
		return
	var xaxis := dir / length
	var up := Vector3.UP
	if absf(xaxis.dot(up)) > 0.99:
		up = Vector3.FORWARD
	var zaxis := xaxis.cross(up).normalized()
	var yaxis := zaxis.cross(xaxis).normalized()
	var basis := Basis(xaxis, yaxis, zaxis)
	var xf := Transform3D(basis, (a + b) * 0.5)
	_emit_box(st, xf, Vector3(length, thick, thick))


static func _emit_box(st: SurfaceTool, xf: Transform3D, size: Vector3) -> void:
	var h := size * 0.5
	var c := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
	var faces := [
		[Vector3(1, 0, 0), 1, 2, 6, 5],
		[Vector3(-1, 0, 0), 4, 7, 3, 0],
		[Vector3(0, 1, 0), 3, 7, 6, 2],
		[Vector3(0, -1, 0), 4, 0, 1, 5],
		[Vector3(0, 0, 1), 4, 5, 6, 7],
		[Vector3(0, 0, -1), 1, 0, 3, 2],
	]
	var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for f in faces:
		var n: Vector3 = (xf.basis * (f[0] as Vector3)).normalized()
		# Two triangles: (0,1,2) and (0,2,3) over corners f[1..4].
		var tri := [[1, 2, 3], [1, 3, 4]]
		var uvmap := [[0, 1, 2], [0, 2, 3]]
		for t in range(2):
			for k in range(3):
				var corner_i: int = f[tri[t][k]]
				var uvi: int = uvmap[t][k]
				st.set_normal(n)
				st.set_uv(uv[uvi])
				st.add_vertex(xf * (c[corner_i] as Vector3))


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

## Painted-steel upright frames. See core/structure_materials.gd for why these
## are now low-metallic (they used to read black in self-shadowed rack interiors)
## and carry procedural grain/relief.
static func _steel_frame_material() -> StandardMaterial3D:
	return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.18, 0.45, 0.50))


static func _steel_beam_material() -> StandardMaterial3D:
	return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.86, 0.36, 0.13))


static func _lumber_material() -> StandardMaterial3D:
	return StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.72, 0.55, 0.34))


static func _plywood_material() -> StandardMaterial3D:
	return StructureMaterials.make(StructureMaterials.Kind.PLYWOOD, Color(0.80, 0.66, 0.42))


## Solar modules: a dark cell grid inside a silver frame, drawn once. The box
## top face maps u along its local Z (the module's short edge) and v along X
## (the long edge), so the image is 6 cells wide and 10 tall.
static var _pv_tex: Texture2D = null


static func _pv_texture() -> Texture2D:
	if _pv_tex != null:
		return _pv_tex
	var cell := 12
	var border := 3
	var w := 6 * cell + border * 2
	var h := 10 * cell + border * 2
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(Color(0.80, 0.82, 0.85))
	img.fill_rect(Rect2i(border, border, w - border * 2, h - border * 2), Color(0.55, 0.60, 0.68))
	for cy in 10:
		for cx in 6:
			img.fill_rect(Rect2i(border + cx * cell + 1, border + cy * cell + 1, cell - 2, cell - 2),
				Color(0.05, 0.08, 0.20))
	img.generate_mipmaps()
	_pv_tex = ImageTexture.create_from_image(img)
	return _pv_tex


static func _pv_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = _pv_texture()
	m.metallic = 0.3
	m.metallic_specular = 0.65
	m.roughness = 0.25
	return m


## Glazing (polycarbonate / glass): pale, see-through, double-sided.
static func _glass_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.80, 0.90, 0.95, 0.32)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.08
	m.metallic_specular = 0.8
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Painted wood (doors) in the player's colour.
static func _paint_material(hex: String) -> StandardMaterial3D:
	var c := Color.html(hex) if Color.html_is_valid(hex) else Color(0.95, 0.94, 0.90)
	return StructureMaterials.make(StructureMaterials.Kind.WOOD, c)
