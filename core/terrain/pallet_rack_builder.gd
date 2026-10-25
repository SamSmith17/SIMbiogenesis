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
##
## PARTS (SketchUp-style nesting). Emission registers every piece it draws as a
## part with a stable id and a path of groups above it: the rack's assemblies
## (a deck level, the uprights, a wall face, an element), their bays (a deck
## cell, a column strip when there are several, a slope bay), and the pieces
## (plywood sheets, joists, beams, treads, wall sheets, solar modules, rail
## runs). part_tree() returns that tree with pick boxes; the modal opens one
## group at a time. spec["part_overrides"] holds {hidden, color} keyed by part
## id; an override on a group applies to everything inside it, and the nearest
## one wins. Ids are grid indices, so they survive rebuilds and undo.

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
const HALF_PANEL_FT := 4.0        # 4x4 half-sheet — multiples tile plywood without cuts
## Rack-row spacing: any half foot from 2'. Real builds run 3.5–4.5' between
## frames (Chiba); multiples of 4' still tile the plywood with no cut sheets.
const ROW_GAP_STEP_FT := 0.5
const ROW_GAP_MIN_FT := 2.0
const SEAM := 0.005              # gap between sheets so they read individually
const STAIR_STEPS := 6

# ---- Design elements ----
const ELEMENT_TYPES := ["door", "window", "stair", "lean_to", "railing", "courtyard", "stepped", "ladder",
	"open_bay"]
## Which end of a slope (seen from outside, facing it) carries a door.
const END_DOORS := ["none", "left", "right", "both"]
const END_DOOR_STYLES := ["hinged", "opening"]
const FACES := ["front", "back", "left", "right"]
const OPPOSITE_FACE := {"front": "back", "back": "front", "left": "right", "right": "left"}
const DOOR_STYLES := ["hinged", "double", "sliding", "opening"]
const WINDOW_STYLES := ["glass", "open"]
const SLOPE_SURFACES := ["solar", "glazing", "plywood", "frame", "none"]
const SLOPE_ENDS := ["open", "glazing", "plywood"]
const PANEL_ORIENTATIONS := ["landscape", "portrait"]
const STAIR_RUNS := ["along", "out"]
## How a stair gets down: one flight, two in line with a landing between, an L
## (a quarter turn on a square landing), a U (a switchback on a landing as wide
## as both flights) or a wrap (three flights round two quarter-turn landings).
const STAIR_SHAPES := ["straight", "landing", "l", "u", "wrap"]
## The way the stair turns as you CLIMB it.
const STAIR_TURNS := ["left", "right"]
## What fills the gaps round the solar modules, and the strip between an
## offset slope and the structure.
const SEAL_OPTIONS := ["open", "plywood", "glazing"]
## A stepped module: inside one deck bay (steps down to the level below) or
## outside a face (big steps up to a deck — seating, a grand stair).
const STEP_MODES := ["bay", "face"]
const RISE_DIRS := ["back", "front", "left", "right"]
## Where a slope's limited rows of modules sit (pv_rows > 0).
const PV_FROM := ["centre", "top", "bottom"]

## Common solar modules (typical data-sheet numbers): long x short edge in
## inches, STC watts, Voc / Vmp volts, Isc / Imp amps. "custom" = the
## element's own numbers.
const PV_MODULES := {
	"60cell_300": {"label": "60-cell 300 W (65 x 39 in)", "long_in": 65.0, "short_in": 39.0,
		"watts": 300.0, "voc": 39.8, "vmp": 32.5, "isc": 9.8, "imp": 9.23},
	"ja_380": {"label": "JA Solar 380 W (69.6 x 41.4 in)", "long_in": 69.6, "short_in": 41.4,
		"watts": 380.0, "voc": 41.62, "vmp": 34.77, "isc": 11.52, "imp": 10.93},
	"72cell_400": {"label": "72-cell 400 W (77 x 39 in)", "long_in": 77.0, "short_in": 39.1,
		"watts": 400.0, "voc": 48.0, "vmp": 41.0, "isc": 11.0, "imp": 9.76},
	"bifacial_550": {"label": "144 half-cell 550 W (89.7 x 44.6 in)", "long_in": 89.7,
		"short_in": 44.6, "watts": 550.0, "voc": 49.9, "vmp": 41.96, "isc": 14.0, "imp": 13.11},
	"12v_100": {"label": "12 V 100 W (41.8 x 20.9 in)", "long_in": 41.8, "short_in": 20.9,
		"watts": 100.0, "voc": 22.6, "vmp": 18.9, "isc": 5.75, "imp": 5.29},
}
const PV_MODULE_ORDER := ["60cell_300", "ja_380", "72cell_400", "bifacial_550", "12v_100", "custom"]
## The element keys a module preset fills.
const PV_MODULE_KEYS := {"long_in": "panel_long_in", "short_in": "panel_short_in",
	"watts": "panel_watts", "voc": "panel_voc", "vmp": "panel_vmp", "isc": "panel_isc",
	"imp": "panel_imp"}

const ELEMENT_LABELS := {
	"door": "Door", "window": "Window", "stair": "Stairs", "lean_to": "Sloped array",
	"railing": "Railing", "courtyard": "Courtyard", "stepped": "Stepped module", "ladder": "Ladder",
	"open_bay": "Open bay",
}
const OPTION_LABELS := {
	"front": "Front", "back": "Back", "left": "Left", "right": "Right",
	"hinged": "Hinged", "double": "Double", "sliding": "Sliding barn door",
	"opening": "Open doorway", "glass": "Glazed", "open": "Open",
	"solar": "Solar panels", "glazing": "Greenhouse glazing", "plywood": "Plywood",
	"frame": "Bare rafters", "none": "Leave this bay off",
	"landscape": "Landscape", "portrait": "Portrait",
	"along": "Along the wall", "out": "Straight out",
	"straight": "Straight", "landing": "Two flights, a landing between",
	"l": "L — a quarter turn", "u": "U — a switchback", "wrap": "Wrap — two quarter turns",
	"bay": "In a deck bay", "face": "Outside a face (big steps)", "custom": "Custom",
	"centre": "Centred", "top": "From the top", "bottom": "From the bottom",
	"both": "Both ends",
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
# IRC R311.7.6: a landing at least as deep as the stair is wide, and 36" at
# the least, in the direction of travel.
const STAIR_LANDING_MIN := 3.0 * FT
const STAIR_U_GAP := 4.0 * IN      # between the two flights of a switchback

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
		"flip": false, "width_ft": 3.0, "handrail": true,
		# Tread depth (in, 10 = the IRC minimum) and, for a run straight out, a
		# landing (ft) between the deck edge and the top step.
		"tread_in": 10.0, "landing_ft": 0.0,
		# The flights (STAIR_SHAPES), the way it turns as you climb, and how high
		# the (upper) turn landing sits, in % of the height climbed.
		"shape": "straight", "turn": "left", "turn_pct": 50.0},
	"lean_to": {"face": "front", "surface": "solar", "segments": {}, "angle_deg": 50.0,
		"attach_level": -1, "bottom_ft": 1.5, "seg_from": 0, "seg_to": -1,
		"orientation": "landscape", "panel_watts": PV_WATTS, "ends": "open",
		# A gap (ft) between the structure and the slope's top edge, spanned by
		# joists; `bridge` covers that strip.
		"offset_ft": 0.0, "bridge": "open",
		# The module itself: a PV_MODULES preset or "custom" + its numbers.
		"panel_model": "60cell_300", "panel_long_in": 65.0, "panel_short_in": 39.0,
		"panel_gap_in": 0.5, "panel_voc": 39.8, "panel_vmp": 32.5, "panel_isc": 9.8,
		"panel_imp": 9.23,
		# What seals the gaps round and between the modules of a solar bay.
		"gap_fill": "open",
		# At most this many rows of modules (0 = as many as fit), set from
		# the top, the bottom or centred; the rest of the bay is gap_fill.
		"pv_rows": 0, "pv_from": "centre",
		# A door in a closed end wall (END_DOORS, seen from outside facing the
		# slope), set in as near the structure as the slope's height allows.
		"end_door": "none", "end_door_style": "hinged", "end_door_w_ft": 3.0,
		"end_door_h_ft": 6.75, "end_door_color": "#f2efe6"},
	"railing": {"floor": 1, "height_ft": 3.5, "front": true, "back": true,
		"left": true, "right": true, "inner": true},
	"courtyard": {"bay0": 1, "bays": 1, "col0": 0, "cols": 1},
	# Bays bay0.. (bays wide) open to the sky above deck `floor` (-1 = the
	# ground: open the whole height): every deck above goes, and with `beams`
	# the beams that carried them, with `walls` the wall sheets beside them.
	# cols 0 = every column, else col0.. (cols deep).
	"open_bay": {"bay0": 0, "bays": 1, "col0": 0, "cols": 0, "floor": 0, "beams": true,
		"walls": true},
	# mode "bay": the deck cell (bay, col, level) becomes steps rising from the
	# level below toward `rise_toward`. mode "face": big steps outside `face`
	# across bays seg_from..seg_to, up to deck `to_level`, each at most
	# `rise_in` tall and `tread_ft` deep.
	"stepped": {"mode": "bay", "bay": 0, "col": 0, "level": 1, "rise_toward": "back",
		"steps": STAIR_STEPS, "face": "front", "seg_from": 0, "seg_to": 0, "to_level": 0,
		"rise_in": 16.0, "tread_ft": 2.0, "closed_risers": true},
	# A ladder up a face from floor `floor` (-1 the ground) to deck `to_level`,
	# its rails running on 3' past the deck to hold on to.
	"ladder": {"face": "front", "at_ft": 4.0, "floor": -1, "to_level": 1, "width_ft": 1.5},
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
		{"key": "run", "label": "Top flight runs", "kind": "option", "options": STAIR_RUNS},
		{"key": "flip", "label": "Run the other way", "kind": "bool"},
		{"key": "shape", "label": "Flights", "kind": "option", "options": STAIR_SHAPES,
			"tip": "One flight, or several with landings: an L turns a corner, a U doubles back"},
		{"key": "turn", "label": "Turns, going up", "kind": "option", "options": STAIR_TURNS,
			"show_if": {"shape": ["l", "u", "wrap"]}},
		{"key": "turn_pct", "label": "Landing height", "kind": "float", "min": 20.0, "max": 80.0,
			"step": 5.0, "unit": "%", "show_if": {"shape": ["landing", "l", "u", "wrap"]},
			"tip": "How far up the climb the landing sits (the upper one, on a wrap)"},
		{"key": "width_ft", "label": "Width", "kind": "float", "min": 2.0, "max": 12.0, "step": 0.5},
		{"key": "tread_in", "label": "Tread depth", "kind": "float", "min": 9.0, "max": 24.0, "step": 0.5, "unit": "in"},
		{"key": "landing_ft", "label": "Landing at the top", "kind": "float", "min": 0.0, "max": 12.0, "step": 0.5,
			"show_if": {"run": ["out"]}},
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
		{"key": "offset_ft", "label": "Gap to the structure", "kind": "float", "min": 0.0, "max": 12.0, "step": 0.5,
			"tip": "Stand the slope off the face; joists span the gap"},
		{"key": "bridge", "label": "Cover the gap", "kind": "option", "options": SEAL_OPTIONS,
			"show_if": {"_min": {"offset_ft": 0.01}}},
		{"key": "ends", "label": "Close the ends", "kind": "option", "options": SLOPE_ENDS},
		{"key": "end_door", "label": "Door in an end", "kind": "option", "options": END_DOORS,
			"show_if": {"ends": ["glazing", "plywood"]},
			"tip": "A door in the closed end, set in where the slope is tallest"},
		{"key": "end_door_style", "label": "End door", "kind": "option", "options": END_DOOR_STYLES,
			"show_if": {"ends": ["glazing", "plywood"], "end_door": ["left", "right", "both"]}},
		{"key": "end_door_w_ft", "label": "End door width", "kind": "float", "min": 2.0, "max": 6.0, "step": 0.5,
			"show_if": {"ends": ["glazing", "plywood"], "end_door": ["left", "right", "both"]}},
		{"key": "end_door_h_ft", "label": "End door height", "kind": "float", "min": 5.0, "max": 8.0, "step": 0.25,
			"show_if": {"ends": ["glazing", "plywood"], "end_door": ["left", "right", "both"]},
			"tip": "Lowered to fit when the slope is not that tall where the door goes"},
		{"key": "end_door_color", "label": "End door colour", "kind": "color",
			"show_if": {"ends": ["glazing", "plywood"], "end_door": ["left", "right", "both"]}},
		{"key": "panel_model", "label": "Module", "kind": "pv_model", "section": "Solar panels",
			"show_if": {"_solar": true}},
		{"key": "orientation", "label": "Panels", "kind": "option", "options": PANEL_ORIENTATIONS,
			"show_if": {"_solar": true}},
		{"key": "pv_rows", "label": "Rows of panels", "kind": "int", "min": 0, "max": 40,
			"show_if": {"_solar": true}, "tip": "0 = as many as fit; fewer leaves the rest of the bay to the gap seal"},
		{"key": "pv_from", "label": "Rows start", "kind": "option", "options": PV_FROM,
			"show_if": {"_solar": true}},
		{"key": "panel_long_in", "label": "Long edge", "kind": "float", "min": 12.0, "max": 120.0, "step": 0.1, "unit": "in",
			"show_if": {"_solar": true}},
		{"key": "panel_short_in", "label": "Short edge", "kind": "float", "min": 8.0, "max": 60.0, "step": 0.1, "unit": "in",
			"show_if": {"_solar": true}},
		{"key": "panel_gap_in", "label": "Gap between", "kind": "float", "min": 0.0, "max": 12.0, "step": 0.25, "unit": "in",
			"show_if": {"_solar": true}},
		{"key": "panel_watts", "label": "Watts per panel", "kind": "float", "min": 10.0, "max": 1000.0, "step": 5.0, "unit": "W",
			"show_if": {"_solar": true}},
		{"key": "panel_voc", "label": "Voc", "kind": "float", "min": 1.0, "max": 120.0, "step": 0.01, "unit": "V",
			"show_if": {"_solar": true}},
		{"key": "panel_vmp", "label": "Vmp", "kind": "float", "min": 1.0, "max": 120.0, "step": 0.01, "unit": "V",
			"show_if": {"_solar": true}},
		{"key": "panel_isc", "label": "Isc", "kind": "float", "min": 0.1, "max": 30.0, "step": 0.01, "unit": "A",
			"show_if": {"_solar": true}},
		{"key": "panel_imp", "label": "Imp", "kind": "float", "min": 0.1, "max": 30.0, "step": 0.01, "unit": "A",
			"show_if": {"_solar": true}},
		{"key": "gap_fill", "label": "Seal the gaps", "kind": "option", "options": SEAL_OPTIONS,
			"show_if": {"_solar": true}, "tip": "Fill round and between the panels so the slope is a closed roof"},
	],
	"ladder": [
		{"key": "face", "label": "Wall", "kind": "face"},
		{"key": "at_ft", "label": "Position", "kind": "along"},
		{"key": "floor", "label": "From", "kind": "floor"},
		{"key": "to_level", "label": "Up to", "kind": "level"},
		{"key": "width_ft", "label": "Width", "kind": "float", "min": 1.0, "max": 3.0, "step": 0.25},
	],
	"stepped": [
		{"key": "mode", "label": "Where", "kind": "option", "options": STEP_MODES},
		{"key": "bay", "label": "Bay", "kind": "bay", "show_if": {"mode": ["bay"]}},
		{"key": "col", "label": "Column", "kind": "col", "show_if": {"mode": ["bay"]}},
		{"key": "level", "label": "Up to", "kind": "level", "show_if": {"mode": ["bay"]}},
		{"key": "rise_toward", "label": "Rises toward", "kind": "option", "options": RISE_DIRS,
			"show_if": {"mode": ["bay"]}},
		{"key": "steps", "label": "Steps", "kind": "int", "min": 2, "max": 16, "show_if": {"mode": ["bay"]}},
		{"key": "face", "label": "Face", "kind": "face", "show_if": {"mode": ["face"]}},
		{"key": "seg_from", "label": "From bay", "kind": "seg", "show_if": {"mode": ["face"]}},
		{"key": "seg_to", "label": "To bay", "kind": "seg", "show_if": {"mode": ["face"]}},
		{"key": "to_level", "label": "Up to", "kind": "level", "show_if": {"mode": ["face"]}},
		{"key": "rise_in", "label": "Step height up to", "kind": "float", "min": 6.0, "max": 30.0, "step": 0.5, "unit": "in",
			"show_if": {"mode": ["face"]}},
		{"key": "tread_ft", "label": "Step depth", "kind": "float", "min": 1.0, "max": 8.0, "step": 0.5,
			"show_if": {"mode": ["face"]}},
		{"key": "closed_risers", "label": "Close the risers", "kind": "bool", "show_if": {"mode": ["face"]}},
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
	"open_bay": [
		{"key": "bay0", "label": "First bay", "kind": "bay"},
		{"key": "bays", "label": "Bays wide", "kind": "int", "min": 1, "max": 10},
		{"key": "cols", "label": "Columns (0 = all)", "kind": "int", "min": 0, "max": 10},
		{"key": "col0", "label": "First column", "kind": "col", "show_if": {"_min": {"cols": 1}}},
		{"key": "floor", "label": "Open above", "kind": "floor",
			"tip": "The deck that stays; everything above it in these bays opens to the sky"},
		{"key": "beams", "label": "Take the beams out", "kind": "bool"},
		{"key": "walls", "label": "Take the walls off", "kind": "bool"},
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
	{"id": "ladder", "label": "Ladder", "tip": "A ladder up a face — click the face, level with the deck it reaches",
		"element": {"type": "ladder"}},
	{"id": "stepped", "label": "Stepped module",
		"tip": "Click a deck bay to turn it into steps down to the level below, or a face for big outside steps",
		"element": {"type": "stepped"}},
	{"id": "solar_slope", "label": "Solar slope", "tip": "A sloped solar array leaning on a face — click the face",
		"element": {"type": "lean_to", "surface": "solar"}},
	{"id": "greenhouse", "label": "Greenhouse", "tip": "A glazed lean-to greenhouse — click the face",
		"element": {"type": "lean_to", "surface": "glazing", "ends": "glazing",
			"angle_deg": 45.0, "bottom_ft": 2.0}},
	{"id": "railing", "label": "Railing", "tip": "Guard rails round a deck's open edges — click the deck",
		"element": {"type": "railing"}},
	{"id": "courtyard", "label": "Courtyard", "tip": "Cut an open courtyard out of the grid — click a deck cell",
		"element": {"type": "courtyard"}},
	{"id": "open_bay", "label": "Open bay",
		"tip": "Open a bay to the sky above a deck: the decks, beams and walls above it come off — click the deck cell to open",
		"element": {"type": "open_bay"}},
]

## Whether an inspector field shows for element `el`: `show_if` maps keys to
## the values they may take, "_min" keys to the least value, and "_solar" to
## "some bay of this slope carries modules".
static func field_visible(f: Dictionary, el: Dictionary) -> bool:
	var cond: Variant = f.get("show_if")
	if not (cond is Dictionary):
		return true
	for k in (cond as Dictionary).keys():
		var want: Variant = cond[k]
		match str(k):
			"_min":
				for mk in (want as Dictionary).keys():
					if float(el.get(mk, 0.0)) < float(want[mk]):
						return false
			"_solar":
				if slope_has_solar(el) != bool(want):
					return false
			_:
				if want is Array and not (want as Array).has(el.get(k)):
					return false
	return true


## Does any bay of a sloped array carry solar modules?
static func slope_has_solar(el: Dictionary) -> bool:
	if str(el.get("type", "")) != "lean_to":
		return false
	if str(el.get("surface", "")) == "solar":
		return true
	var segs: Variant = el.get("segments", {})
	return segs is Dictionary and (segs as Dictionary).values().has("solar")


## A module preset's numbers written onto a slope element (in place).
static func apply_pv_module(el: Dictionary, model: String) -> void:
	el["panel_model"] = model
	if not PV_MODULES.has(model):
		return
	var m: Dictionary = PV_MODULES[model]
	for k in PV_MODULE_KEYS.keys():
		el[PV_MODULE_KEYS[k]] = float(m[k])


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
		# Per-part overrides keyed by part id (see part_tree): {hidden, color}.
		"part_overrides": {},
		# Other racks fused onto this one where their uprights meet:
		# [{spec, x, z, yaw}] — x/z metres and yaw (0/90/180/270°) in THIS
		# rack's frame. Shared uprights are drawn once (see fuse_transform).
		"fused": [],
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
	# derive it from the joist/lumber length. Half-foot steps; a multiple of 4'
	# tiles the plywood with full + half sheets, anything else cuts a strip.
	if not overrides.has("row_gap_ft"):
		s["row_gap_ft"] = float(s["lumber_len_ft"])
	s["row_gap_ft"] = clampf(snappedf(float(s["row_gap_ft"]), ROW_GAP_STEP_FT), ROW_GAP_MIN_FT, 20.0)
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
	s["part_overrides"] = _normalize_part_overrides(s.get("part_overrides"))

	# Steps are stepped-module ELEMENTS now (placeable, draggable, editable).
	# The legacy stepped_module flag and per-cell "step" overrides migrate into
	# bay-mode elements; the cell keeps its height / depth overrides.
	var migrated: Array = []
	if int(s["stepped_module"]) > 0 and cov.is_empty():
		var lv_list := _levels(s)
		var top_decked := -1
		for li in lv_list.size():
			if bool(s["decked"]) or bool(lv_list[li]["roof"]):
				top_decked = li
		if top_decked > 0:
			var cc := int(s["stepped_module"]) - 1
			for b in int(s["bay_count"]):
				migrated.append(make_element("stepped", {"mode": "bay", "bay": b, "col": cc,
					"level": top_decked}))
	s["stepped_module"] = 0
	var step_keys: Array = cov.keys()
	step_keys.sort()
	for k in step_keys:
		var ce: Dictionary = cov[k]
		if str(ce.get("kind", "")) != "step":
			continue
		var bits := str(k).split(",")
		if bits.size() == 3:
			migrated.append(make_element("stepped", {"mode": "bay", "bay": int(bits[0]),
				"col": int(bits[1]), "level": int(bits[2])}))
		ce.erase("kind")
		if ce.is_empty():
			cov.erase(k)
	if not migrated.is_empty():
		var els0: Array = (s["elements"] as Array).duplicate() if s.get("elements") is Array else []
		els0.append_array(migrated)
		s["elements"] = els0

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
	# Deck cells a bay-mode stepped module stands in (derived each resolve,
	# never read back from a saved spec): "b,c,li" -> element id.
	var claims := {}
	for e in els:
		if str(e.get("type", "")) == "stepped" and str(e.get("mode", "")) == "bay":
			var ck := _cell_key(int(e["bay"]), int(e["col"]), int(e["level"]))
			if not claims.has(ck):
				claims[ck] = str(e["id"])
	s["_stepped_cells"] = claims
	s["_open_cells"] = _open_cells_of(s, els)
	s["fused"] = _normalize_fused(s.get("fused"))
	return s


## Deck cells an open bay takes away (derived each resolve, never read back
## from a saved spec): "b,c,li" -> {id, beams, walls}.
static func _open_cells_of(s: Dictionary, els: Array) -> Dictionary:
	var out := {}
	var nlv := _levels(s).size()
	var ncols := int(s["column_count"])
	for e in els:
		if str(e.get("type", "")) != "open_bay":
			continue
		var c0 := 0 if int(e["cols"]) <= 0 else int(e["col0"])
		var c1 := ncols - 1 if int(e["cols"]) <= 0 else int(e["col0"]) + int(e["cols"]) - 1
		for b in range(int(e["bay0"]), int(e["bay0"]) + int(e["bays"])):
			for c in range(c0, c1 + 1):
				for li in range(int(e["floor"]) + 1, nlv):
					var k := _cell_key(b, c, li)
					if not out.has(k):
						out[k] = {"id": str(e["id"]), "beams": bool(e["beams"]), "walls": bool(e["walls"])}
	return out


## Fused racks: each entry's spec resolved on its own (one level deep — a
## fused rack's own fusions were flattened when it was fused), yaw snapped to
## a quarter turn.
static func _normalize_fused(v: Variant) -> Array:
	var out: Array = []
	if not (v is Array):
		return out
	for f in (v as Array):
		if not (f is Dictionary) or not ((f as Dictionary).get("spec") is Dictionary):
			continue
		var sub: Dictionary = ((f as Dictionary)["spec"] as Dictionary).duplicate(true)
		sub.erase("fused")
		var rs := resolve_spec(sub)
		rs.erase("_stepped_cells")
		rs.erase("_open_cells")
		out.append({"spec": rs, "x": float(f.get("x", 0.0)), "z": float(f.get("z", 0.0)),
			"yaw": snap_quarter_deg(float(f.get("yaw", 0.0)))})
	return out


static func snap_quarter_deg(deg: float) -> float:
	return fposmod(roundf(deg / 90.0) * 90.0, 360.0)


## Only the keys the geometry honours survive: `hidden` (true) and `color`
## ("#rrggbb"). Empty entries are dropped so a cleared override leaves no trace.
static func _normalize_part_overrides(v: Variant) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for k in (v as Dictionary).keys():
		var o: Variant = (v as Dictionary)[k]
		if not (o is Dictionary):
			continue
		var r := {}
		if bool((o as Dictionary).get("hidden", false)):
			r["hidden"] = true
		var c := str((o as Dictionary).get("color", ""))
		if not c.is_empty() and Color.html_is_valid(c):
			r["color"] = "#" + Color.html(c).to_html(false)
		if not r.is_empty():
			out[str(k)] = r
	return out


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
		"stairs": 0, "railing_ft": 0.0, "ladders": 0}

	func _init() -> void:
		frame.begin(Mesh.PRIMITIVE_TRIANGLES)
		beam.begin(Mesh.PRIMITIVE_TRIANGLES)
		lumber.begin(Mesh.PRIMITIVE_TRIANGLES)
		ply.begin(Mesh.PRIMITIVE_TRIANGLES)
		pv.begin(Mesh.PRIMITIVE_TRIANGLES)
		glass.begin(Mesh.PRIMITIVE_TRIANGLES)

	func paint_for(hex: String) -> SurfaceTool:
		return _tool_in(paint, hex)

	## Painted steel (a beam or an upright given a colour), one surface per colour.
	var metal := {}

	func metal_for(hex: String) -> SurfaceTool:
		return _tool_in(metal, hex)

	func _tool_in(d: Dictionary, hex: String) -> SurfaceTool:
		var key := hex.to_lower() if Color.html_is_valid(hex) else "#f2efe6"
		if not key.begins_with("#"):
			key = "#" + key
		if not d.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			d[key] = st
		return d[key]

	## The surface a part draws on: its own colour when the override has one.
	func surf(ov: Dictionary, base: SurfaceTool, is_metal: bool = false) -> SurfaceTool:
		var c := str(ov.get("color", ""))
		if c.is_empty():
			return base
		return metal_for(c) if is_metal else paint_for(c)

	# ---- Parts (see the PARTS note at the top) ----
	## spec["part_overrides"].
	var po := {}
	## Record pick boxes (the editor) — off for placed props, which never pick.
	var record := false
	## While a group is open in the editor, everything outside it draws faded.
	var dim_ctx := ""
	var dim: SurfaceTool = null
	## id -> {id, label, kind, parent, children, hidden}
	var nodes := {}
	var roots: Array = []
	## One per drawn part: {path, aabb (all of it, for culling), obbs?: [[inverse
	## xf, half]] one per box drawn, aabbs?: [AABB] one per loose triangle}. A
	## part with more pieces than MAX_PART_BOXES keeps only its aabb.
	var boxes: Array = []
	const MAX_PART_BOXES := 64
	var cur_in_ctx := true
	var cur_box := {}
	## A fused rack that is not the one being edited: its parts never enter
	## the tree (their ids would collide with the edited rack's), and with
	## dim_all they draw faded.
	var no_tree := false
	var dim_all := false
	## Build units (PalletRackBuilder.build_units_node): every part's geometry
	## on its own per-material surfaces, keyed by the part's own id (a fused
	## rack's prefixed "m<i>|"), so a build site can move each piece.
	var split := false
	var unit_prefix := ""
	var cur_unit := ""
	## unit id -> {material key -> SurfaceTool}
	var units := {}

	## Register `path` (group ids down to the part) with its `labels`, make the
	## part current (its boxes are what emission draws until the next begin),
	## and return the overrides merged down the path, nearest last. A hidden
	## part is registered but gets no box; the caller draws nothing.
	func begin(path: Array, labels: Array, force_hidden: bool = false) -> Dictionary:
		end_part()
		if split:
			cur_unit = unit_prefix + (str(path[-1]) if not path.is_empty() else "misc")
		if no_tree:
			var ovn := {}
			for pid in path:
				var o: Variant = po.get(str(pid))
				if o is Dictionary:
					ovn.merge(o as Dictionary, true)
			if force_hidden:
				ovn["hidden"] = true
			cur_in_ctx = not dim_all
			return ovn
		var ov := {}
		var parent := ""
		for i in path.size():
			var id := str(path[i])
			var own: Variant = po.get(id)
			if own is Dictionary:
				ov.merge(own as Dictionary, true)
			if not nodes.has(id):
				nodes[id] = {"id": id, "label": str(labels[i]) if i < labels.size() else id,
					"kind": PalletRackBuilder.part_kind(id), "parent": parent, "children": [],
					"hidden": false}
				if parent.is_empty():
					roots.append(id)
				else:
					(nodes[parent]["children"] as Array).append(id)
			if own is Dictionary and bool((own as Dictionary).get("hidden", false)):
				nodes[id]["hidden"] = true
			parent = id
		if force_hidden:
			ov["hidden"] = true
			if not path.is_empty():
				nodes[str(path[-1])]["hidden"] = true
		cur_in_ctx = dim_ctx.is_empty() or path.has(dim_ctx)
		if record and not bool(ov.get("hidden", false)):
			cur_box = {"path": path.duplicate(), "obbs": [], "aabbs": []}
		return ov

	func end_part() -> void:
		if no_tree:
			cur_box = {}
			cur_in_ctx = not dim_all
			return
		if not cur_box.is_empty() and cur_box.has("aabb"):
			var n := (cur_box["obbs"] as Array).size() + (cur_box["aabbs"] as Array).size()
			if n > MAX_PART_BOXES:
				cur_box.erase("obbs")
				cur_box.erase("aabbs")
			elif (cur_box["aabbs"] as Array).is_empty():
				cur_box.erase("aabbs")
			boxes.append(cur_box)
		cur_box = {}
		cur_in_ctx = dim_ctx.is_empty()

	func route(st: SurfaceTool) -> SurfaceTool:
		if split:
			var u := cur_unit if not cur_unit.is_empty() else unit_prefix + "misc"
			if not units.has(u):
				units[u] = {}
			var mk := mat_key(st)
			var d: Dictionary = units[u]
			if not d.has(mk):
				var t := SurfaceTool.new()
				t.begin(Mesh.PRIMITIVE_TRIANGLES)
				d[mk] = t
			return d[mk]
		if cur_in_ctx:
			return st
		if dim == null:
			dim = SurfaceTool.new()
			dim.begin(Mesh.PRIMITIVE_TRIANGLES)
		return dim

	## Which material a base surface draws with ("frame", "paint:#rrggbb" …).
	func mat_key(st: SurfaceTool) -> String:
		if st == frame:
			return "frame"
		if st == beam:
			return "beam"
		if st == lumber:
			return "lumber"
		if st == ply:
			return "ply"
		if st == pv:
			return "pv"
		if st == glass:
			return "glass"
		for hex in paint:
			if paint[hex] == st:
				return "paint:" + str(hex)
		for hex in metal:
			if metal[hex] == st:
				return "metal:" + str(hex)
		return "lumber"

	func add_box(xf: Transform3D, size: Vector3) -> void:
		if cur_box.is_empty():
			return
		var half := (size * 0.5).max(Vector3(0.012, 0.012, 0.012))
		var bb := xf * AABB(-half, half * 2.0)
		cur_box["aabb"] = (cur_box["aabb"] as AABB).merge(bb) if cur_box.has("aabb") else bb
		if (cur_box["obbs"] as Array).size() <= MAX_PART_BOXES:
			(cur_box["obbs"] as Array).append([xf.affine_inverse(), half])

	func add_points(pts: Array) -> void:
		if cur_box.is_empty() or pts.is_empty():
			return
		var bb := AABB(pts[0] as Vector3, Vector3.ZERO)
		for p in pts:
			bb = bb.expand(p as Vector3)
		bb = bb.grow(0.02)
		cur_box["aabb"] = (cur_box["aabb"] as AABB).merge(bb) if cur_box.has("aabb") else bb
		if (cur_box["aabbs"] as Array).size() <= MAX_PART_BOXES:
			(cur_box["aabbs"] as Array).append(bb)

	func add_aabb(bb: AABB) -> void:
		add_points([bb.position, bb.end])

	func tree() -> Dictionary:
		end_part()
		var root_aabb := {}
		for b in boxes:
			var r := str((b["path"] as Array)[0])
			root_aabb[r] = (root_aabb[r] as AABB).merge(b["aabb"]) if root_aabb.has(r) else b["aabb"]
		return {"nodes": nodes, "roots": roots, "boxes": boxes, "root_aabb": root_aabb}


## The _Geom being emitted into, so the box / triangle writers can file each
## piece under the current part and fade it when a group is open. Set for the
## length of one _emit_structure; nothing else writes boxes.
static var _rec: _Geom = null
## The fused rack being emitted, in the frame of the rack being built (identity
## for a single rack). _emit_box / _emit_tri apply it, so every emitter stays
## in rack-local coordinates.
static var _mxf := Transform3D.IDENTITY
## Upright posts already drawn by an earlier rack of a fused build (in the
## build frame); a frame whose two posts are both here is shared and skipped.
static var _posts_done: Array = []
const SHARED_POST_TOL := 0.06

const FRAMES_ID := "frames"
## Kinds a colour can go on (the rest are glass, modules or whole elements).
const PAINTABLE_KINDS := ["sheet", "joist", "tread", "beam", "upright", "wall_sheet",
	"slope_sheet", "slope_frame", "rail_run"]
const METAL_KINDS := ["beam", "upright"]


## What a part id names, from its prefix (ids: see the PARTS note at the top).
static func part_kind(id: String) -> String:
	if id == FRAMES_ID:
		return "frames"
	if id.begins_with("el:"):
		var bits := id.split(":")
		if bits.size() == 2:
			return "element"
		var tail := str(bits[2])
		if bits.size() == 3:
			if tail.begins_with("r"):
				return "rail_run"
			if tail == "frame" or tail == "ends" or tail == "bridge":
				return "slope_frame"
			return "slope_bay"
		var leaf := str(bits[3])
		if leaf.begins_with("m"):
			return "module"
		if leaf.begins_with("s") or leaf == "g":
			return "slope_sheet"
		return "slope_frame"
	var pre := id.get_slice(":", 0)
	match pre:
		"deck":
			return "deck_level"
		"strip":
			return "strip"
		"cell":
			return "cell"
		"ply":
			return "sheet"
		"joist":
			return "joist"
		"tread":
			return "tread"
		"beam":
			return "beam"
		"post":
			return "upright"
		"wallface":
			return "wall"
		"wall":
			return "wall_sheet"
	return "part"


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


## `opts`: record (bool) keeps the part tree as meta "part_tree"; dim_ctx (a
## part id) draws everything outside that group faded — the editor's open group.
static func build_node(spec: Dictionary = {}, node_name: String = "PalletRack",
		opts: Dictionary = {}) -> Node3D:
	var s := resolve_spec(spec)
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("rack_spec", s.duplicate(true))

	var g := _Geom.new()
	g.record = bool(opts.get("record", false))
	g.dim_ctx = str(opts.get("dim_ctx", ""))
	_emit_all(g, s, int(opts.get("module", 0)), bool(opts.get("dim_others", false)))

	var mesh := ArrayMesh.new()
	var mats: Array = []
	var pairs: Array = [[g.frame, _steel_frame_material()], [g.beam, _steel_beam_material()],
			[g.lumber, _lumber_material()], [g.ply, _plywood_material()],
			[g.pv, _pv_material()], [g.glass, _glass_material()]]
	for hex in g.paint.keys():
		pairs.append([g.paint[hex], _paint_material(str(hex))])
	for hex in g.metal.keys():
		pairs.append([g.metal[hex], _paint_metal_material(str(hex))])
	if g.dim != null:
		pairs.append([g.dim, _dim_material()])
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
	if g.record:
		root.set_meta("part_tree", g.tree())
	# Foot origin on ground centre so PlacedProp footing works (local Y=0).
	return root


## The rack's parts as a tree: {nodes: id -> {id, label, kind, parent,
## children, hidden}, roots: [ids], boxes: [{path, aabb, obbs?}], root_aabb}.
## The same emission draws the mesh, so a box is exactly the piece drawn.
static func part_tree(spec: Dictionary = {}) -> Dictionary:
	var s := resolve_spec(spec)
	var g := _Geom.new()
	g.record = true
	_emit_all(g, s)
	return g.tree()


## Distance along the ray to a part (the nearest of the boxes it was drawn
## with; its bounding box alone when it had too many to keep).
static func ray_hits_part_box(origin: Vector3, dir: Vector3, b: Dictionary) -> float:
	var t_all := ray_hits_aabb(origin, dir, b["aabb"] as AABB)
	if t_all < 0.0 or not b.has("obbs"):
		return t_all
	var best := -1.0
	for ob in (b["obbs"] as Array):
		var inv: Transform3D = ob[0]
		var half: Vector3 = ob[1]
		var t := ray_hits_aabb(inv * origin, inv.basis * dir, AABB(-half, half * 2.0))
		if t >= 0.0 and (best < 0.0 or t < best):
			best = t
	for bb in (b.get("aabbs", []) as Array):
		var t := ray_hits_aabb(origin, dir, bb as AABB)
		if t >= 0.0 and (best < 0.0 or t < best):
			best = t
	return best


## The nearest piece the ray meets INSIDE the open group `ctx` (a path of ids,
## [] = the whole rack), resolved to the child of that group it belongs to:
## {node: child id or "", leaf, t, any: the ray met any part at all}.
static func pick_part(tree: Dictionary, origin: Vector3, dir: Vector3, ctx: Array = []) -> Dictionary:
	var d := ctx.size()
	var root_hit := {}
	var ra: Dictionary = tree.get("root_aabb", {})
	for r in ra.keys():
		root_hit[r] = ray_hits_aabb(origin, dir, (ra[r] as AABB).grow(0.05)) >= 0.0
	var best_t := INF
	var best := ""
	var leaf := ""
	var any := false
	for b in (tree.get("boxes", []) as Array):
		var path: Array = b["path"]
		if not bool(root_hit.get(path[0], false)):
			continue
		var inside := path.size() > d
		if inside:
			for i in d:
				if str(path[i]) != str(ctx[i]):
					inside = false
					break
		if not inside and any:
			continue
		var t := ray_hits_part_box(origin, dir, b)
		if t < 0.0:
			continue
		any = true
		if inside and t < best_t:
			best_t = t
			best = str(path[d])
			leaf = str(path[-1])
	return {"node": best, "leaf": leaf, "t": best_t, "any": any}


## Root-first ids from the top group down to `id`.
static func part_path(tree: Dictionary, id: String) -> Array:
	var nodes: Dictionary = tree.get("nodes", {})
	var out: Array = []
	var cur := id
	while not cur.is_empty() and nodes.has(cur):
		out.push_front(cur)
		cur = str(nodes[cur]["parent"])
	return out


## `id` and every node under it.
static func part_subtree(tree: Dictionary, id: String) -> Array:
	var nodes: Dictionary = tree.get("nodes", {})
	var out: Array = []
	var stack: Array = [id]
	while not stack.is_empty():
		var cur := str(stack.pop_back())
		if not nodes.has(cur):
			continue
		out.append(cur)
		var kids: Array = nodes[cur]["children"]
		for i in range(kids.size() - 1, -1, -1):
			stack.append(kids[i])
	return out


## The boxes drawn under `id` (its own and its descendants').
static func part_boxes(tree: Dictionary, id: String) -> Array:
	var out: Array = []
	for b in (tree.get("boxes", []) as Array):
		if (b["path"] as Array).has(id):
			out.append(b)
	return out


## The overrides a part gets, merged down its path (nearest wins).
static func merged_override(spec: Dictionary, path: Array) -> Dictionary:
	var po: Dictionary = spec.get("part_overrides", {})
	var ov := {}
	for id in path:
		var o: Variant = po.get(str(id))
		if o is Dictionary:
			ov.merge(o as Dictionary, true)
	return ov


static func _arrays_have_geometry(arr: Array) -> bool:
	if arr.size() <= Mesh.ARRAY_VERTEX:
		return false
	var verts: Variant = arr[Mesh.ARRAY_VERTEX]
	return verts is PackedVector3Array and not (verts as PackedVector3Array).is_empty()


## The rack as BUILD UNITS: one Node3D per part (named by index, the part id
## in meta "unit_id"), each holding its geometry in the build frame, so a
## build site (PalletRackBuildSite) can hide, carry, raise and set every
## piece. Meta "units" on the root: {id: {aabb (build frame), kind}}.
## Fused racks' parts carry the prefix "m<i>|".
static func build_units_node(spec: Dictionary = {}, node_name: String = "RackUnits") -> Node3D:
	var s := resolve_spec(spec)
	var g := _Geom.new()
	g.split = true
	_emit_all(g, s)
	g.end_part()
	var mats := {"frame": _steel_frame_material(), "beam": _steel_beam_material(),
		"lumber": _lumber_material(), "ply": _plywood_material(), "pv": _pv_material(),
		"glass": _glass_material()}
	var root := Node3D.new()
	root.name = node_name
	var info := {}
	var ids: Array = g.units.keys()
	ids.sort()
	var n := 0
	for id in ids:
		var node := Node3D.new()
		node.name = "U%d" % n
		node.set_meta("unit_id", str(id))
		n += 1
		var bb := AABB()
		var first := true
		var d: Dictionary = g.units[id]
		for mk in d.keys():
			var arr := (d[mk] as SurfaceTool).commit_to_arrays()
			if not _arrays_have_geometry(arr):
				continue
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			var mat: Material
			var smk := str(mk)
			if smk.begins_with("paint:"):
				mat = _paint_material(smk.substr(6))
			elif smk.begins_with("metal:"):
				mat = _paint_metal_material(smk.substr(6))
			else:
				mat = mats.get(smk, mats["lumber"])
			mesh.surface_set_material(0, mat)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			node.add_child(mi)
			var mb := mesh.get_aabb()
			bb = mb if first else bb.merge(mb)
			first = false
		if first:
			node.free()
			continue
		root.add_child(node)
		var leaf := str(id).get_slice("|", 1) if str(id).contains("|") else str(id)
		info[str(id)] = {"aabb": bb, "kind": part_kind(leaf), "node": node.name}
	root.set_meta("units", info)
	root.set_meta("rack_spec", s.duplicate(true))
	return root


static func build_default_node() -> Node3D:
	return build_node(default_spec())


static func bom(spec: Dictionary = {}) -> Dictionary:
	var s := resolve_spec(spec)
	var g := _Geom.new()
	_emit_all(g, s)
	return g.counts.duplicate()


# ---------------------------------------------------------------------------
# Fused racks — several racks built as one, sharing the uprights where they meet
# ---------------------------------------------------------------------------

## Every rack of a build: [{spec, xf}], xf in rack 0's frame (rack 0 = the
## spec itself, the rest its "fused" entries).
static func rack_modules(s: Dictionary) -> Array:
	var root := s.duplicate()
	root.erase("fused")
	var out: Array = [{"spec": root, "xf": Transform3D.IDENTITY}]
	for f in (s.get("fused", []) as Array):
		if f is Dictionary and (f as Dictionary).get("spec") is Dictionary:
			out.append({"spec": resolve_spec(f["spec"]), "xf": fused_xf(f)})
	return out


static func fused_xf(f: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(float(f.get("yaw", 0.0)))),
		Vector3(float(f.get("x", 0.0)), 0.0, float(f.get("z", 0.0))))


## Emit every rack of a build into `g`, in the frame of rack `active` (the one
## the editor works on: drawn first, the only one recorded in the part tree).
## The others follow, faded with `dim_others`, skipping frames already drawn.
static func _emit_all(g: _Geom, s: Dictionary, active: int = 0, dim_others: bool = false) -> void:
	var mods := rack_modules(s)
	active = clampi(active, 0, mods.size() - 1)
	var frame := (mods[active]["xf"] as Transform3D).affine_inverse()
	var order: Array = [active]
	for i in mods.size():
		if i != active:
			order.append(i)
	var rec0 := g.record
	_posts_done = []
	for i in order:
		var ms: Dictionary = mods[i]["spec"]
		_mxf = frame * (mods[i]["xf"] as Transform3D)
		g.unit_prefix = "" if i == 0 else "m%d|" % i
		g.no_tree = i != active
		g.dim_all = dim_others and i != active
		g.record = rec0 and i == active
		_emit_structure(g, ms, _metrics(ms))
	_mxf = Transform3D.IDENTITY
	g.no_tree = false
	g.dim_all = false
	g.record = rec0
	_posts_done = []


static func _post_shared(p: Vector3) -> bool:
	for q in _posts_done:
		var d := (q as Vector3) - p
		if Vector2(d.x, d.z).length() < SHARED_POST_TOL:
			return true
	return false


## The upright post centres of one rack (rack-local, y = 0), cut-away ones left out.
static func post_points(spec: Dictionary) -> Array:
	var s := resolve_spec(spec)
	var L := _layout(s, _metrics(s))
	var out: Array = []
	for r in range(int(L.rows)):
		var zf := float(L.rz[r])
		for bx in range(int(L.bays) + 1):
			var x := float(L.fx[bx])
			if _in_notch(L.notch, x, zf + float(L.frame_depth) * 0.5):
				continue
			out.append(Vector3(x, 0.0, zf))
			out.append(Vector3(x, 0.0, zf + float(L.frame_depth)))
	return out


## Every post of a build (all its racks) in rack 0's frame.
static func build_post_points(spec: Dictionary) -> Array:
	var out: Array = []
	for m in rack_modules(resolve_spec(spec)):
		var xf: Transform3D = m["xf"]
		for p in post_points(m["spec"]):
			out.append(xf * (p as Vector3))
	return out


## The whole build's ground footprint in rack `active`'s frame.
static func fused_bounds(spec: Dictionary, active: int = 0) -> Rect2:
	var s := resolve_spec(spec)
	var mods := rack_modules(s)
	active = clampi(active, 0, mods.size() - 1)
	var frame := (mods[active]["xf"] as Transform3D).affine_inverse()
	var r := Rect2()
	var first := true
	for m in mods:
		var mm := _metrics(m["spec"])
		var hx := float(mm.total_x) * 0.5
		var hz := float(mm.total_z) * 0.5
		for c in [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]:
			var p := frame * (m["xf"] as Transform3D) * (c as Vector3)
			if first:
				r = Rect2(Vector2(p.x, p.z), Vector2.ZERO)
				first = false
			else:
				r = r.expand(Vector2(p.x, p.z))
	return r


## Move rack `j` of a build by `a` (left-multiplied, in rack 0's frame) while
## rack 0 stays the build's frame: when rack 0 itself moves (or turns), every
## rack is re-expressed so rack 0 is the identity again, and `root` is how the
## build's own pose moved — apply it to the placed prop (world * root) and
## every rack stands where it was, the moved one where it went. {xfs, root}.
static func move_module(xfs: Array, j: int, a: Transform3D) -> Dictionary:
	var out: Array = []
	for x in xfs:
		out.append(x as Transform3D)
	if j < 0 or j >= out.size():
		return {"xfs": out, "root": Transform3D.IDENTITY}
	out[j] = _square_xf(a * (out[j] as Transform3D))
	var root: Transform3D = out[0]
	if not root.is_equal_approx(Transform3D.IDENTITY):
		var inv := root.affine_inverse()
		for i in out.size():
			out[i] = _square_xf(inv * (out[i] as Transform3D))
		out[0] = Transform3D.IDENTITY
	return {"xfs": out, "root": root}


## Turn about the y axis through `centre` by `deg` (a quarter turn, usually).
static func turn_about(centre: Vector3, deg: float) -> Transform3D:
	var r := Basis(Vector3.UP, deg_to_rad(deg))
	var c := Vector3(centre.x, 0.0, centre.z)
	return Transform3D(r, c - r * c)


## A rack pose cleaned to what the build stores: on the ground, square.
static func _square_xf(xf: Transform3D) -> Transform3D:
	var yaw := snap_quarter_deg(rad_to_deg(xf.basis.get_euler().y))
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), Vector3(xf.origin.x, 0.0, xf.origin.z))


## Where rack pose `xf` (its own post points `pb_local`) lands when the shift
## (at most `tol` m) that puts the most of its posts on posts `pa` (the other
## racks', same frame) is taken. {xf, shared}: shared < 2 = no frame meets
## (xf back unchanged); on a tie the smaller shift wins.
static func snap_posts(pa: Array, pb_local: Array, xf: Transform3D, tol: float = 0.45) -> Dictionary:
	var pb: Array = []
	for p in pb_local:
		pb.append(xf * (p as Vector3))
	var best_n := 0
	var best_d := Vector3.ZERO
	var tried := {}
	for a in pa:
		for b in pb:
			var d: Vector3 = (a as Vector3) - (b as Vector3)
			d.y = 0.0
			if d.length() > tol:
				continue
			var key := "%d,%d" % [int(round(d.x * 50.0)), int(round(d.z * 50.0))]
			if tried.has(key):
				continue
			tried[key] = true
			var n := 0
			for b2 in pb:
				var q: Vector3 = (b2 as Vector3) + d
				for a2 in pa:
					var e: Vector3 = (a2 as Vector3) - q
					if Vector2(e.x, e.z).length() < SHARED_POST_TOL:
						n += 1
						break
			if n > best_n or (n == best_n and n > 0 and d.length() < best_d.length()):
				best_n = n
				best_d = d
	if best_n < 2:
		return {"xf": xf, "shared": best_n}
	return {"xf": Transform3D(xf.basis, xf.origin + best_d), "shared": best_n}

## Where rack B (world transform xf_b) joins rack A (xf_a) if their uprights
## meet: B's yaw relative to A snapped to a quarter turn (refused past
## `yaw_tol_deg`), then the shift that lands the most of B's posts on A's,
## looking `tol` m around. {ok, x, z, yaw, shared, moved_m, reason}: x/z/yaw
## are B in A's frame, ready for fuse_specs; at least one whole frame (two
## posts) must meet.
static func fuse_transform(spec_a: Dictionary, xf_a: Transform3D, spec_b: Dictionary,
		xf_b: Transform3D, tol: float = 0.6, yaw_tol_deg: float = 20.0) -> Dictionary:
	var rel := xf_a.affine_inverse() * xf_b
	var raw_yaw := rad_to_deg(rel.basis.get_euler().y)
	var yaw := snap_quarter_deg(raw_yaw)
	var dyaw := absf(wrapf(raw_yaw - yaw, -180.0, 180.0))
	if dyaw > yaw_tol_deg:
		return {"ok": false, "reason": "the racks are not square to each other (%d degrees off)" % int(round(dyaw))}
	var base := Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), Vector3(rel.origin.x, 0.0, rel.origin.z))
	var pa := build_post_points(spec_a)
	var pb: Array = []
	for p in build_post_points(spec_b):
		pb.append(base * (p as Vector3))
	var best_n := 0
	var best_d := Vector3.ZERO
	var tried := {}
	for a in pa:
		for b in pb:
			var d: Vector3 = (a as Vector3) - (b as Vector3)
			d.y = 0.0
			if d.length() > tol:
				continue
			var key := "%d,%d" % [int(round(d.x * 50.0)), int(round(d.z * 50.0))]
			if tried.has(key):
				continue
			tried[key] = true
			var n := 0
			for b2 in pb:
				var q: Vector3 = (b2 as Vector3) + d
				for a2 in pa:
					var e: Vector3 = (a2 as Vector3) - q
					if Vector2(e.x, e.z).length() < SHARED_POST_TOL:
						n += 1
						break
			if n > best_n or (n == best_n and n > 0 and d.length() < best_d.length()):
				best_n = n
				best_d = d
	if best_n < 2:
		return {"ok": false, "reason": "no uprights line up — stand a frame of one rack on a frame of the other"}
	var o := base.origin + best_d
	return {"ok": true, "x": o.x, "z": o.z, "yaw": yaw, "shared": best_n,
		"moved_m": best_d.length()}


## Rack A with rack B fused on at `rel` ({x, z, yaw}: B in A's frame). B's own
## fused racks come along, re-expressed in A's frame.
static func fuse_specs(spec_a: Dictionary, spec_b: Dictionary, rel: Dictionary) -> Dictionary:
	var a := resolve_spec(spec_a)
	var b := resolve_spec(spec_b)
	var out := a.duplicate(true)
	var fused: Array = (out.get("fused", []) as Array).duplicate(true)
	var xf_rel := fused_xf(rel)
	for m in rack_modules(b):
		var mxf: Transform3D = xf_rel * (m["xf"] as Transform3D)
		var ms: Dictionary = (m["spec"] as Dictionary).duplicate(true)
		ms.erase("fused")
		ms.erase("_stepped_cells")
		ms.erase("_open_cells")
		fused.append({"spec": ms, "x": mxf.origin.x, "z": mxf.origin.z,
			"yaw": snap_quarter_deg(rad_to_deg(mxf.basis.get_euler().y))})
	out["fused"] = fused
	return resolve_spec(out)


## Take rack `i` out of a fused build: {rest, rest_xf, module, module_xf}.
## `rest` is the build without it, re-based on its first remaining rack, which
## sits at `rest_xf` in the old frame; `module` stands alone at `module_xf`.
## {} when the build has only one rack.
static func split_fused(spec: Dictionary, i: int) -> Dictionary:
	var mods := rack_modules(resolve_spec(spec))
	if mods.size() < 2 or i < 0 or i >= mods.size():
		return {}
	var r := 1 if i == 0 else 0
	var inv := (mods[r]["xf"] as Transform3D).affine_inverse()
	var rest: Dictionary = (mods[r]["spec"] as Dictionary).duplicate(true)
	var fused: Array = []
	for k in mods.size():
		if k == i or k == r:
			continue
		var mxf: Transform3D = inv * (mods[k]["xf"] as Transform3D)
		var ms: Dictionary = (mods[k]["spec"] as Dictionary).duplicate(true)
		ms.erase("_stepped_cells")
		ms.erase("_open_cells")
		fused.append({"spec": ms, "x": mxf.origin.x, "z": mxf.origin.z,
			"yaw": snap_quarter_deg(rad_to_deg(mxf.basis.get_euler().y))})
	rest["fused"] = fused
	var module: Dictionary = (mods[i]["spec"] as Dictionary).duplicate(true)
	module.erase("_stepped_cells")
	module.erase("_open_cells")
	return {"rest": resolve_spec(rest), "rest_xf": mods[r]["xf"],
		"module": resolve_spec(module), "module_xf": mods[i]["xf"]}


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
	var claims: Variant = s.get("_stepped_cells")
	if claims is Dictionary and (claims as Dictionary).has(_cell_key(b, c, li)):
		kind = "stepped"
	var opened: Variant = s.get("_open_cells")
	if opened is Dictionary and (opened as Dictionary).has(_cell_key(b, c, li)):
		kind = "none"
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
	var open_cells: Dictionary = s.get("_open_cells", {}) if s.get("_open_cells") is Dictionary else {}
	g.po = s.get("part_overrides", {})
	_rec = g

	# Uprights (frames) at every row x bay-boundary.
	for r in range(rows):
		var zf := float(rz[r])
		for bx in range(bays + 1):
			var x := float(fx[bx])
			if _in_notch(notch, x, zf + frame_depth * 0.5):
				continue
			# Fused racks share the frames where their uprights meet.
			var p0 := _mxf * Vector3(x, 0.0, zf)
			var p1 := _mxf * Vector3(x, 0.0, zf + frame_depth)
			if _post_shared(p0) and _post_shared(p1):
				continue
			var pov := g.begin([FRAMES_ID, "post:%d,%d" % [r, bx]],
				["Uprights", "Upright %d, rack row %d" % [bx + 1, r + 1]])
			if bool(pov.get("hidden", false)):
				continue
			_emit_frame(g, x, zf, zf + frame_depth, height, g.surf(pov, g.frame, true))
			_posts_done.append(p0)
			_posts_done.append(p1)
			g.counts["uprights"] += 1

	# Beams at every level x row x bay (front + back side), honoring overrides
	# (deleted beams vanish; dy_in nudges them 1" at a time). Each belongs to
	# the deck cell it carries.
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
					var bkey := _beam_key(li, r, b, side)
					var ov: Dictionary = beam_ov.get(bkey, {})
					var bc := _beam_cell(r, side, cols)
					var oc: Variant = open_cells.get(_cell_key(b, bc, li))
					if oc is Dictionary and bool((oc as Dictionary).get("beams", true)):
						continue
					var cp := _cell_path(s, L, b, bc, li)
					var bov := g.begin((cp[0] as Array) + ["beam:" + bkey],
						(cp[1] as Array) + [_beam_label(r, side, cols)], bool(ov.get("deleted", false)))
					if bool(bov.get("hidden", false)):
						continue
					var yy := y + float(ov.get("dy_in", 0.0)) * IN
					_emit_box(g.surf(bov, g.beam, true),
						Transform3D(Basis(), Vector3(cx, yy - BEAM_H * 0.5, zb)),
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
				if kind == "none" or kind == "stepped":
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
				var cp := _cell_path(s, L, b, c, li)
				var key := _cell_key(b, c, li)
				if kind == "step":
					var y_lo := float(levels[li - 1]["y"]) if li > 0 else 0.0
					_emit_stairs(g, bx0, bx1, cz0, cz1, y_lo, y, notch, cp, key)
					continue
				_emit_joists_span(g, s, bx0, bx1, cz0, cz1, y, notch, cp, key)
				_emit_ply_field(g, bx0, bx1, cz0, cz1, y + JOIST_H + PLY_T * 0.5, notch, [],
					[cp[0], cp[1], key])

	# Plywood walls on chosen perimeter faces (doors / windows cut through).
	_emit_walls(g, s, m, x0, z0, total_x, total_z, height, notch)

	# Design elements: doors, windows, stairs, sloped arrays, railings.
	_emit_elements(g, s, L)
	g.end_part()
	_rec = null


## Which deck cell (column) a beam carries: a frame's back beam is the front
## edge of the cell behind it, its front beam the back edge of the cell in
## front; the outermost beams carry the edge cells' overhang.
static func _beam_cell(r: int, side: int, cols: int) -> int:
	if side == 0:
		return 0 if r == 0 else r - 1
	return cols - 1 if r >= cols else r


static func _beam_label(r: int, side: int, cols: int) -> String:
	if side == 0:
		return "Front beam, outer" if r == 0 else "Back beam"
	return "Back beam, outer" if r >= cols else "Front beam"


## [ids, labels] of the groups above a deck cell's pieces: the deck level, its
## column strip (only when there are several columns), the cell itself.
static func _cell_path(s: Dictionary, L: Dictionary, b: int, c: int, li: int) -> Array:
	var levels: Array = L.levels
	var lv: Dictionary = levels[li]
	var ids: Array = ["deck:%d" % li]
	var labels: Array = ["Roof deck" if bool(lv["roof"]) else "Level %d deck · %s" % [li + 1,
		fmt_ft(float(lv["y"]) / FT)]]
	if int(L.cols) > 1:
		ids.append("strip:%d,%d" % [c, li])
		labels.append("Column %d" % (c + 1))
	var kind := str(_resolve_cell(s, b, c, li, lv, bool(s["decked"]))["kind"])
	ids.append("cell:" + _cell_key(b, c, li))
	labels.append("Bay %d%s" % [b + 1, " (steps)" if kind == "step" or kind == "stepped"
		else (" (no deck)" if kind == "none" else "")])
	return [ids, labels]


static func _emit_frame(g: _Geom, x: float, z0: float, z1: float, h: float,
		st: SurfaceTool = null) -> void:
	if st == null:
		st = g.frame
	# Two posts.
	for z in [z0, z1]:
		_emit_box(st, Transform3D(Basis(), Vector3(x, h * 0.5, z)),
			Vector3(POST_W, h, POST_W))
	# Foot plates.
	for z in [z0, z1]:
		_emit_box(st, Transform3D(Basis(), Vector3(x, 0.02, z)),
			Vector3(POST_W * 1.6, 0.04, POST_W * 1.8))
	# Horizontal + diagonal bracing in the Z-Y plane between the two posts.
	var nodes := [0.15]
	var steps := maxi(2, int(h / 1.2))
	for i in range(1, steps + 1):
		nodes.append(0.15 + (h - 0.3) * float(i) / float(steps))
	var brace := POST_W * 0.55
	for yy in nodes:
		_emit_strut(st, Vector3(x, yy, z0), Vector3(x, yy, z1), brace)
	for i in range(nodes.size() - 1):
		var y_lo := float(nodes[i])
		var y_hi := float(nodes[i + 1])
		var za := z0 if (i % 2 == 0) else z1
		var zb := z1 if (i % 2 == 0) else z0
		_emit_strut(st, Vector3(x, y_lo, za), Vector3(x, y_hi, zb), brace)


## `cp` = the cell's [ids, labels] (_cell_path); each joist is its own part.
static func _emit_joists_span(g: _Geom, s: Dictionary, x_a: float, x_b: float,
		z_a: float, z_b: float, beam_y: float, notch: Dictionary, cp: Array = [],
		key: String = "") -> void:
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
		var st := g.lumber
		if not cp.is_empty():
			var ov := g.begin((cp[0] as Array) + ["joist:%s:%d" % [key, i]],
				(cp[1] as Array) + ["Joist %d" % (i + 1)])
			if bool(ov.get("hidden", false)):
				continue
			st = g.surf(ov, g.lumber)
		_emit_box(st, Transform3D(Basis(), Vector3(jx, joist_cy, joist_cz)),
			Vector3(JOIST_W, JOIST_H, joist_len))
		g.counts["lumber"] += 1


## A flight of `n` steps across a deck cell, from y_lo up to y_hi, rising
## toward `dir` ("back" = +Z, "front" = -Z, "left" = +X, "right" = -X).
static func _emit_stairs(g: _Geom, x_a: float, x_b: float, z_a: float,
		z_b: float, y_lo: float, y_hi: float, notch: Dictionary, cp: Array = [],
		key: String = "", dir: String = "back", n: int = STAIR_STEPS) -> void:
	n = maxi(2, n)
	var along_z := dir == "back" or dir == "front"
	var lo := z_a if along_z else x_a
	var hi := z_b if along_z else x_b
	var rising_up := dir == "back" or dir == "left"
	var step_d := (hi - lo) / float(n)
	for s_i in range(n):
		# Step s_i counts up from the low end.
		var k := s_i if rising_up else n - 1 - s_i
		var u0 := lo + step_d * float(k)
		var u1 := u0 + step_d
		var y := y_lo + (y_hi - y_lo) * float(s_i + 1) / float(n)
		var sx0 := x_a if along_z else u0
		var sx1 := x_b if along_z else u1
		var sz0 := u0 if along_z else z_a
		var sz1 := u1 if along_z else z_b
		var cx := (sx0 + sx1) * 0.5
		var cz := (sz0 + sz1) * 0.5
		if _in_notch(notch, cx, cz):
			continue
		var lum := g.lumber
		var ply := g.ply
		if not cp.is_empty():
			var ov := g.begin((cp[0] as Array) + ["tread:%s:%d" % [key, s_i]],
				(cp[1] as Array) + ["Step %d" % (s_i + 1)])
			if bool(ov.get("hidden", false)):
				continue
			lum = g.surf(ov, g.lumber)
			ply = g.surf(ov, g.ply)
		# Support lumber under the tread.
		var sup := Vector3(sx1 - sx0, JOIST_H, (sz1 - sz0) * 0.9) if along_z 			else Vector3((sx1 - sx0) * 0.9, JOIST_H, sz1 - sz0)
		_emit_box(lum, Transform3D(Basis(), Vector3(cx, y - JOIST_H * 0.5, cz)), sup)
		g.counts["lumber"] += 1
		_emit_ply_field(g, sx0, sx1, sz0, sz1, y + PLY_T * 0.5, notch, [], [], ply)


## `part` = [ids, labels, cell key] makes each sheet its own part (a deck);
## without it the sheets go on `st` (default plywood) in the current part.
static func _emit_ply_field(g: _Geom, x_a: float, x_b: float, z_a: float, z_b: float,
		cy: float, notch: Dictionary, skip_z: Array = [], part: Array = [],
		st: SurfaceTool = null) -> void:
	if st == null:
		st = g.ply
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
			var sst := st
			if not part.is_empty():
				var ov := g.begin((part[0] as Array) + ["ply:%s:%d,%d" % [str(part[2]), ix, iz]],
					(part[1] as Array) + ["Sheet %d" % (iz * nx + ix + 1)])
				if bool(ov.get("hidden", false)):
					continue
				sst = g.surf(ov, g.ply)
			_emit_box(sst, Transform3D(Basis(), Vector3(ccx, cy, ccz)),
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
		var wid := "wallface:" + str(f[0])
		var wlabel := "%s wall" % str(OPTION_LABELS.get(str(f[0]), str(f[0])))
		var n_sheet := 0
		for sh in _wall_face_sheets(f[1], f[2], f[3], f[4], f[5], f[6], f[7]):
			n_sheet += 1
			var wkey := "%s,%d,%d" % [f[0], int(sh["ia"]), int(sh["iv"])]
			var wov := g.begin([wid, "wall:" + wkey], [wlabel, "Sheet %d" % n_sheet],
				deleted.has(wkey))
			if bool(wov.get("hidden", false)):
				continue
			var wst := g.surf(wov, g.ply)
			if holes.is_empty():
				_emit_box(wst, Transform3D(Basis(), sh["pos"]), sh["size"])
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
					_emit_box(wst, Transform3D(Basis(), Vector3(cc, cy, fixed)),
						Vector3(pr.size.x, pr.size.y, PLY_T))
				else:
					_emit_box(wst, Transform3D(Basis(), Vector3(fixed, cy, cc)),
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
	var any_po := not (s.get("part_overrides", {}) as Dictionary).is_empty()

	# Deck cells.
	for li in range(levels.size()):
		var lv: Dictionary = levels[li]
		for c in range(cols):
			var zb := _cell_z_bounds(rz, frame_depth, c, cols)
			for b in range(bays):
				var cell := _resolve_cell(s, b, c, li, lv, decked)
				if str(cell["kind"]) == "none" or str(cell["kind"]) == "stepped":
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
				if any_po and _part_hidden(s, _cell_path(s, L, b, c, li)[0]):
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
					if any_po and _part_hidden(s, (_cell_path(s, L, b, _beam_cell(r, side, cols), li)[0] as Array)
							+ ["beam:" + _beam_key(li, r, b, side)]):
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
			if any_po and _part_hidden(s, ["wallface:" + str(f[0]), "wall:" + key]):
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
			if any_po and _part_hidden(s, [FRAMES_ID, "post:%d,%d" % [r, bx]]):
				continue
			var lo := Vector3(x - POST_W, 0.0, zf - POST_W)
			var hi := Vector3(x + POST_W, height, zf + frame_depth + POST_W)
			out.append({"id": "post:%d,%d" % [r, bx], "kind": "upright",
				"aabb": AABB(lo, hi - lo), "row": r, "bx": bx})

	# Design elements (doors, windows, stairs, slope bays, railings, courtyards).
	for e in (s.get("elements", []) as Array):
		if e is Dictionary and not (any_po and _part_hidden(s, ["el:" + str((e as Dictionary).get("id", ""))])):
			out.append_array(_element_components(s, L, e as Dictionary))
	return out


static func _part_hidden(s: Dictionary, path: Array) -> bool:
	if (s.get("part_overrides", {}) as Dictionary).is_empty():
		return false
	return bool(merged_override(s, path).get("hidden", false))


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
			out["shape"] = _pick_option(out["shape"], STAIR_SHAPES)
			out["turn"] = _pick_option(out["turn"], STAIR_TURNS)
			out["turn_pct"] = clampf(float(out["turn_pct"]), 20.0, 80.0)
			out["width_ft"] = clampf(float(out["width_ft"]), 2.0, 12.0)
			out["tread_in"] = clampf(float(out["tread_in"]), 9.0, 24.0)
			out["landing_ft"] = clampf(float(out["landing_ft"]), 0.0, 12.0)
			out["to_level"] = clampi(int(out["to_level"]), 0, maxi(nlv - 1, 0))
			out["flip"] = bool(out["flip"])
			out["handrail"] = bool(out["handrail"])
			out["at_ft"] = clampf(float(out["at_ft"]), 0.0, _face_len_ft(m, str(out["face"])))
		"lean_to":
			out["surface"] = _pick_option(out["surface"], SLOPE_SURFACES)
			out["ends"] = _pick_option(out["ends"], SLOPE_ENDS)
			out["end_door"] = _pick_option(out["end_door"], END_DOORS)
			out["end_door_style"] = _pick_option(out["end_door_style"], END_DOOR_STYLES)
			out["end_door_w_ft"] = clampf(float(out["end_door_w_ft"]), 2.0, 6.0)
			out["end_door_h_ft"] = clampf(float(out["end_door_h_ft"]), 5.0, 8.0)
			var edc := str(out["end_door_color"])
			out["end_door_color"] = edc if Color.html_is_valid(edc) else "#f2efe6"
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
			out["offset_ft"] = clampf(float(out["offset_ft"]), 0.0, 12.0)
			out["bridge"] = _pick_option(out["bridge"], SEAL_OPTIONS)
			out["gap_fill"] = _pick_option(out["gap_fill"], SEAL_OPTIONS)
			var pm := str(out["panel_model"])
			out["panel_model"] = pm if (PV_MODULES.has(pm) or pm == "custom") else "custom"
			out["panel_long_in"] = clampf(float(out["panel_long_in"]), 12.0, 120.0)
			out["panel_short_in"] = clampf(float(out["panel_short_in"]), 8.0,
				float(out["panel_long_in"]))
			out["panel_gap_in"] = clampf(float(out["panel_gap_in"]), 0.0, 12.0)
			for k in ["panel_voc", "panel_vmp", "panel_isc", "panel_imp"]:
				out[k] = clampf(float(out[k]), 0.1, 200.0)
			out["pv_rows"] = clampi(int(out["pv_rows"]), 0, 40)
			out["pv_from"] = _pick_option(out["pv_from"], PV_FROM)
		"ladder":
			out["floor"] = clampi(int(out["floor"]), -1, maxi(nlv - 1, -1))
			out["to_level"] = clampi(int(out["to_level"]), 0, maxi(nlv - 1, 0))
			out["width_ft"] = clampf(float(out["width_ft"]), 1.0, 3.0)
			out["at_ft"] = clampf(float(out["at_ft"]), 0.0, _face_len_ft(m, str(out["face"])))
		"stepped":
			out["mode"] = _pick_option(out["mode"], STEP_MODES)
			out["rise_toward"] = _pick_option(out["rise_toward"], RISE_DIRS)
			out["bay"] = clampi(int(out["bay"]), 0, int(s["bay_count"]) - 1)
			out["col"] = clampi(int(out["col"]), 0, int(s["column_count"]) - 1)
			out["level"] = clampi(int(out["level"]), 0, maxi(nlv - 1, 0))
			out["to_level"] = clampi(int(out["to_level"]), 0, maxi(nlv - 1, 0))
			out["steps"] = clampi(int(out["steps"]), 2, 16)
			out["rise_in"] = clampf(float(out["rise_in"]), 6.0, 30.0)
			out["tread_ft"] = clampf(float(out["tread_ft"]), 1.0, 8.0)
			out["closed_risers"] = bool(out["closed_risers"])
			var nsg := _face_seg_count(s, str(out["face"]))
			out["seg_from"] = clampi(int(out["seg_from"]), 0, nsg - 1)
			var sto := int(out["seg_to"])
			out["seg_to"] = clampi(sto if sto >= 0 else nsg - 1, int(out["seg_from"]), nsg - 1)
		"railing":
			out["floor"] = clampi(int(out["floor"]), 0, maxi(nlv - 1, 0))
			out["height_ft"] = clampf(float(out["height_ft"]), 2.0, 5.0)
			for k in ["front", "back", "left", "right", "inner"]:
				out[k] = bool(out[k])
		"open_bay":
			var obays := int(s["bay_count"])
			var ocols := int(s["column_count"])
			out["bay0"] = clampi(int(out["bay0"]), 0, obays - 1)
			out["bays"] = clampi(int(out["bays"]), 1, obays - int(out["bay0"]))
			out["cols"] = clampi(int(out["cols"]), 0, ocols)
			out["col0"] = clampi(int(out["col0"]), 0, ocols - 1)
			if int(out["cols"]) > 0:
				out["cols"] = mini(int(out["cols"]), ocols - int(out["col0"]))
			out["floor"] = clampi(int(out["floor"]), -1, maxi(nlv - 2, -1))
			out["beams"] = bool(out["beams"])
			out["walls"] = bool(out["walls"])
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


## The deck cell (bay, col) over rack-local x, z; (-1, -1) outside the grid.
static func grid_cell_at(spec: Dictionary, x: float, z: float) -> Vector2i:
	var s := resolve_spec(spec)
	var L := _layout(s, _metrics(s))
	var b := int(floor((x - float(L.x0)) / float(L.module_x)))
	if b < 0 or b >= int(L.bays):
		return Vector2i(-1, -1)
	for c in range(int(L.cols)):
		var zb := _cell_z_bounds(L.rz, float(L.frame_depth), c, int(L.cols))
		if z >= zb.x - 0.02 and z <= zb.y + 0.02:
			return Vector2i(b, c)
	return Vector2i(-1, -1)


## The bay of `face` at `along_ft` from its start (clamped to the face).
static func face_segment_at(spec: Dictionary, face: String, along_ft: float) -> int:
	var s := resolve_spec(spec)
	var segs := _face_segments(face, _layout(s, _metrics(s)))
	var a := along_ft * FT
	for i in segs.size():
		if a <= float(segs[i].y):
			return i
	return maxi(segs.size() - 1, 0)


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
	out.append_array(_open_bay_wall_holes(s, L, face))
	return out


## The wall an open bay takes off a face (rects in the face's absolute along
## coordinate, like a door's): above its floor, across the bays / columns it
## opens that this face bounds.
static func _open_bay_wall_holes(s: Dictionary, L: Dictionary, face: String) -> Array:
	var out: Array = []
	var fx: Array = L.fx
	var rz: Array = L.rz
	var cols: int = L.cols
	var bays: int = L.bays
	var top := float(L.height) + 1.0
	for e in (s.get("elements", []) as Array):
		if not (e is Dictionary) or str(e.get("type", "")) != "open_bay" or not bool(e.get("walls", true)):
			continue
		var b0 := int(e["bay0"])
		var b1 := b0 + int(e["bays"]) - 1
		var c0 := 0 if int(e["cols"]) <= 0 else int(e["col0"])
		var c1 := cols - 1 if int(e["cols"]) <= 0 else int(e["col0"]) + int(e["cols"]) - 1
		var y0 := 0.0 if int(e["floor"]) < 0 else _floor_y(L, int(e["floor"]))
		match face:
			"front":
				if c0 == 0:
					out.append(Rect2(float(fx[b0]), y0, float(fx[b1 + 1]) - float(fx[b0]), top - y0))
			"back":
				if c1 == cols - 1:
					out.append(Rect2(float(fx[b0]), y0, float(fx[b1 + 1]) - float(fx[b0]), top - y0))
			"left", "right":
				if (face == "left" and b1 == bays - 1) or (face == "right" and b0 == 0):
					var za := _cell_z_bounds(rz, float(L.frame_depth), c0, cols).x
					var zb := _cell_z_bounds(rz, float(L.frame_depth), c1, cols).y
					out.append(Rect2(za, y0, zb - za, top - y0))
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
			var shape := str(e.get("shape", "straight"))
			var kind := str({"landing": "Stairs with a landing", "l": "L stairs", "u": "U stairs",
				"wrap": "Wrap-round stairs"}.get(shape, "Stairs"))
			return "%s · %s face, up to %s" % [kind, face, _floor_name(spec, int(e.get("to_level", 0)))]
		"lean_to":
			return "%s · %s face" % [str(OPTION_LABELS.get(str(e.get("surface", "")), name)), face]
		"railing":
			return "Railing · %s" % _floor_name(spec, int(e.get("floor", 0)))
		"ladder":
			return "Ladder · %s face, up to %s" % [face, _floor_name(spec, int(e.get("to_level", 0)))]
		"stepped":
			if str(e.get("mode", "bay")) == "bay":
				return "Steps · bay %d, column %d, up to %s" % [int(e.get("bay", 0)) + 1,
					int(e.get("col", 0)) + 1, _floor_name(spec, int(e.get("level", 0)))]
			return "Big steps · %s face, up to %s" % [face, _floor_name(spec, int(e.get("to_level", 0)))]
		"open_bay":
			var ob0 := int(e.get("bay0", 0)) + 1
			var onb := int(e.get("bays", 1))
			var where := ("bay %d" % ob0) if onb == 1 else ("bays %d–%d" % [ob0, ob0 + onb - 1])
			var above := "the ground up" if int(e.get("floor", 0)) < 0 \
				else "above " + _floor_name(spec, int(e.get("floor", 0)))
			return "Open bay · %s, %s" % [where, above]
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
		var t := str((e as Dictionary).get("type", ""))
		if not ELEMENT_DEFAULTS.has(t):
			continue
		var eid := "el:" + str((e as Dictionary).get("id", ""))
		if t == "lean_to":
			_emit_lean_to(g, s, L, e)
			continue
		if t == "railing":
			_emit_railing(g, s, L, e)
			continue
		if t == "stepped":
			_emit_stepped(g, s, L, e)
			continue
		var ov := g.begin([eid], [element_label(e, s) if g.record else ""])
		if bool(ov.get("hidden", false)):
			continue
		match t:
			"ladder":
				_emit_ladder(g, L, e, g.surf(ov, g.lumber))
			"door":
				_emit_door(g, L, e)
			"window":
				_emit_window(g, L, e)
			"stair":
				_emit_stair(g, L, e)
			"courtyard", "open_bay":
				# A cut in the layout (_layout's notch rects) / derived cells, not
				# geometry: its pick box is the space it opens.
				for c in _element_components(s, L, e):
					g.add_aabb(c["aabb"])


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
	var mirrored := false
	if _mxf != Transform3D.IDENTITY:
		mirrored = _mxf.basis.determinant() < 0.0
		a = _mxf * a
		b = _mxf * b
		c = _mxf * c
		n = _mxf.basis * n
	if _rec != null:
		st = _rec.route(st)
		if _rec.record:
			_rec.add_points([a, b, c])
	n = n.normalized()
	# Callers give the corners counter-clockwise seen from the side the normal
	# faces; Godot's front face is CLOCKWISE from outside, so they go in as a,
	# c, b. Emitted a, b, c, every face was a BACK face: double-sided materials
	# still drew it, but Godot turns a back face's normal round, so each face
	# was lit as if it faced away and the whole rack rendered dark.
	var order := [[a, Vector2(0, 0)], [c, Vector2(1, 1)], [b, Vector2(1, 0)]]
	if mirrored:
		order = [[a, Vector2(0, 0)], [b, Vector2(1, 0)], [c, Vector2(1, 1)]]
	for p in order:
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
	var along := str(e["run"]) == "along"
	var landing := 0.0 if along else float(e.get("landing_ft", 0.0)) * FT
	var G := {"fr": fr, "y_top": y_top, "n": n, "riser": y_top / float(n),
		"w": float(e["width_ft"]) * FT, "a": float(e["at_ft"]) * FT,
		"o0": POST_W * 0.5 + 0.03 + landing, "along": along,
		"sgn": -1.0 if bool(e["flip"]) else 1.0,
		"tread": float(e.get("tread_in", 10.0)) * IN, "landing": landing}
	var shape := str(e.get("shape", "straight"))
	var turn := str(e.get("turn", "left"))
	var frac := float(e.get("turn_pct", 50.0)) / 100.0
	_stair_flights(G, shape, turn, frac)
	# A flight that doubles back (a U, a wrap's last flight) can run into the
	# structure. A stair straight out stands off on a deeper top landing; one
	# along a wall turns the other way.
	var inside := _stair_intrusion(G)
	if inside > 0.0:
		if along:
			_stair_flights(G, shape, "right" if turn == "left" else "left", frac)
			G["turn_swapped"] = true
		else:
			var extra := ceilf((inside + 0.05) / (0.5 * FT)) * 0.5 * FT
			G["landing"] = float(G.landing) + extra
			G["o0"] = float(G.o0) + extra
			G["auto_landing"] = extra
			_stair_flights(G, shape, turn, frac)
	return G


## How far the stair's flights and landings reach in past its face (m, 0 =
## clear): every flight's two sides top and bottom, every landing corner.
static func _stair_intrusion(G: Dictionary) -> float:
	var fr: Dictionary = G.fr
	var w: float = G.w
	var limit := POST_W * 0.5 + 0.02
	var worst := 0.0
	var pts: Array = []
	for f in (G.flights as Array):
		for lat in [-w * 0.5, w * 0.5]:
			pts.append(_flight_point(f, 0.0, lat, 0.0))
			pts.append(_flight_point(f, float(int(f.m)) * float(G.tread), lat, 0.0))
	for lnd in (G.landings as Array):
		var lat_v := Vector3.UP.cross(lnd.h as Vector3)
		for ca in [-0.5, 0.5]:
			for cb in [-0.5, 0.5]:
				pts.append((lnd.c as Vector3) + (lnd.h as Vector3) * (float(lnd.along) * float(ca))
					+ lat_v * (float(lnd.across) * float(cb)))
	for q in pts:
		var o := ((q as Vector3) - (fr.base as Vector3)).dot(fr.out as Vector3)
		worst = maxf(worst, limit - o)
	return worst


## Riser counts per flight, top flight first: the landings sit at `frac` of
## the height (a wrap's lower one at half that). A stair too short for its
## flights becomes fewer flights.
static func stair_flight_counts(n: int, shape: String, frac: float) -> Array:
	match shape:
		"landing", "l", "u":
			if n < 2:
				return [n]
			var low := clampi(roundi(float(n) * frac), 1, n - 1)
			return [n - low, low]
		"wrap":
			if n < 3:
				return stair_flight_counts(n, "l", frac)
			var k1 := clampi(roundi(float(n) * frac), 2, n - 1)
			var k2 := clampi(roundi(float(k1) * 0.5), 1, k1 - 1)
			return [n - k1, k1 - k2, k2]
	return [n]


## Lays the flights and landings out from the top down into G: "flights" =
## [{top (centreline, y 0), h (downhill), m risers, yt, yb}], "landings" =
## [{c (centre, y 0), y, h, along, across, rails: [[a, b], ...]}]. A flight's
## treads sit at dist (j - 0.5) * tread for j in 1..m-1; its last riser comes
## down at dist (m - 1) * tread, where the landing below starts.
static func _stair_flights(G: Dictionary, shape: String, turn: String, frac: float) -> void:
	var fr: Dictionary = G.fr
	var w: float = G.w
	var tread: float = G.tread
	var riser: float = G.riser
	var counts := stair_flight_counts(int(G.n), shape, frac)
	var p: Vector3 = _stair_point(G, 0.0, 0.0, 0.0)
	var h: Vector3 = (_stair_axes(G)[0] as Vector3).normalized()
	var y: float = G.y_top
	var flights: Array = []
	var landings: Array = []
	for i in counts.size():
		var m: int = counts[i]
		var yb := y - riser * float(m)
		if i == counts.size() - 1:
			yb = 0.0
		flights.append({"top": p, "h": h, "m": m, "yt": y, "yb": yb})
		if i == counts.size() - 1:
			break
		var d0 := float(maxi(m - 1, 0)) * tread
		var near := p + h * d0
		# Going DOWN the stair turns the other way from climbing it: a climb to
		# the left is a descent turning right.
		var right := h.cross(Vector3.UP).normalized()
		var side := right if turn == "left" else -right
		var lnd := {"y": yb, "h": h}
		if shape == "landing":
			var ld := maxf(w, STAIR_LANDING_MIN)
			lnd["c"] = near + h * (ld * 0.5)
			lnd["along"] = ld
			lnd["across"] = w
			lnd["rails"] = [[near + right * (w * 0.5), near + h * ld + right * (w * 0.5)],
				[near - right * (w * 0.5), near + h * ld - right * (w * 0.5)]]
			p = near + h * ld
		elif shape == "u":
			var span := w + STAIR_U_GAP
			lnd["c"] = near + h * (w * 0.5) + side * (span * 0.5)
			lnd["along"] = w
			lnd["across"] = w + span
			var far := near + h * w
			var a0 := -side * (w * 0.5)
			var a1 := side * (span + w * 0.5)
			lnd["rails"] = [[far + a0, far + a1], [near + a0, far + a0], [near + a1, far + a1]]
			p = near + side * span
			h = -h
		else:
			# A quarter turn on a square landing.
			lnd["c"] = near + h * (w * 0.5)
			lnd["along"] = w
			lnd["across"] = w
			var far := near + h * w
			lnd["rails"] = [[far - side * (w * 0.5), far + side * (w * 0.5)],
				[near - side * (w * 0.5), far - side * (w * 0.5)]]
			p = near + h * (w * 0.5) + side * (w * 0.5)
			h = side
		# A rail on an edge that meets the structure would stand against it.
		var kept: Array = []
		for r in lnd["rails"]:
			var mid: Vector3 = ((r[0] as Vector3) + (r[1] as Vector3)) * 0.5
			if (mid - (fr.base as Vector3)).dot(fr.out as Vector3) > POST_W + 0.15:
				kept.append(r)
		lnd["rails"] = kept
		landings.append(lnd)
		y = yb
	G["flights"] = flights
	G["landings"] = landings


## A point on flight `f`: `dist` downhill from its top edge, `lat` to the left
## of its downhill direction, at height `y`.
static func _flight_point(f: Dictionary, dist: float, lat: float, y: float) -> Vector3:
	var h: Vector3 = f.h
	return (f.top as Vector3) + h * dist + Vector3.UP.cross(h) * lat + Vector3(0.0, y, 0.0)


## Where someone walks up the stair, bottom to top (the crew's visitor).
static func stair_walk_path(G: Dictionary) -> Array:
	var out: Array = []
	var tread: float = G.tread
	var flights: Array = G.get("flights", [])
	for i in range(flights.size() - 1, -1, -1):
		var f: Dictionary = flights[i]
		var m: int = f.m
		var r := (float(f.yt) - float(f.yb)) / float(maxi(m, 1))
		for k in range(m + 1):
			out.append(_flight_point(f, float(m - k) * tread, 0.0, float(f.yb) + r * float(k)))
	return out


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
	var w: float = G.w
	var y_top: float = G.y_top
	var tread: float = G.tread
	var landing: float = G.landing
	if landing > 0.05:
		# The landing: plywood on joists from the deck edge to the top step,
		# legs at its outer corners.
		var lfr: Dictionary = G.fr
		var o_in := POST_W * 0.5 + 0.03
		var lo := o_in + landing * 0.5
		_emit_face_box(g.ply, lfr, float(G.a), y_top - PLY_T * 0.5, lo, Vector3(w, PLY_T, landing))
		_emit_face_box(g.lumber, lfr, float(G.a), y_top - PLY_T - JOIST_H * 0.5, lo,
			Vector3(w - 0.02, JOIST_H, landing - 0.02))
		var lh := y_top - PLY_T - JOIST_H
		for fa in [-0.45, 0.45]:
			_emit_face_box(g.lumber, lfr, float(G.a) + w * float(fa), lh * 0.5, o_in + landing - 0.06,
				Vector3(LEG_W, lh, LEG_W))
		g.counts["plywood"] += 1
		g.counts["lumber"] += 3
	var fr0: Dictionary = G.fr
	var rail_on := bool(e.get("handrail", true))
	for f in (G.flights as Array):
		var m: int = f.m
		var fh: Vector3 = f.h
		var yt: float = f.yt
		var yb: float = f.yb
		var fr_r := (yt - yb) / float(maxi(m, 1))
		for j in range(1, m):
			_emit_obox(g.lumber, _flight_point(f, float(j) * tread - tread * 0.5, 0.0, yt - fr_r * float(j) - 0.75 * IN),
				fh, Vector3.UP, Vector3(tread + IN, 1.5 * IN, w))
			g.counts["lumber"] += 1
		for lat in [-w * 0.5 + 0.03, w * 0.5 - 0.03]:
			var p_bot := _flight_point(f, float(m) * tread, lat, yb)
			var p_top := _flight_point(f, 0.0, lat, yt)
			var dv := p_top - p_bot
			_emit_obox(g.lumber, (p_bot + p_top) * 0.5 + Vector3.DOWN * (STRINGER_D * 0.45), dv,
				Vector3.UP, Vector3(dv.length(), STRINGER_D, 1.5 * IN))
			g.counts["lumber"] += 1
		if rail_on and m >= 2:
			for sgn_lat in [-1.0, 1.0]:
				var lat := float(sgn_lat) * w * 0.5
				# No rail on a side that runs against the structure.
				var side_dir := Vector3.UP.cross(fh) * float(sgn_lat)
				var side_o := (_flight_point(f, 0.0, lat, 0.0) - (fr0.base as Vector3)).dot(fr0.out as Vector3)
				if side_dir.dot(fr0.out as Vector3) < -0.7 and side_o < POST_W + 0.3:
					continue
				var b := _flight_point(f, float(m - 1) * tread, lat, yb + fr_r)
				var t := _flight_point(f, 0.0, lat, yt)
				for q in [b, t]:
					_emit_obox(g.lumber, (q as Vector3) + Vector3.UP * (STAIR_RAIL_H * 0.5), Vector3.UP,
						fh, Vector3(STAIR_RAIL_H, 1.5 * IN, 3.5 * IN))
				_emit_strut(g.lumber, b + Vector3.UP * STAIR_RAIL_H, t + Vector3.UP * STAIR_RAIL_H, 0.045)
				g.counts["lumber"] += 3
	for lnd in (G.landings as Array):
		var ly: float = lnd.y
		var lh: Vector3 = lnd.h
		var lc: Vector3 = lnd.c
		var la: float = lnd.along
		var lx: float = lnd.across
		_emit_obox(g.ply, lc + Vector3.UP * (ly - PLY_T * 0.5), lh, Vector3.UP, Vector3(la, PLY_T, lx))
		_emit_obox(g.lumber, lc + Vector3.UP * (ly - PLY_T - JOIST_H * 0.5), lh, Vector3.UP,
			Vector3(la - 0.02, JOIST_H, lx - 0.02))
		var leg_h := ly - PLY_T - JOIST_H
		var lat_v := Vector3.UP.cross(lh)
		if leg_h > 0.05:
			for ca in [-1.0, 1.0]:
				for cb in [-1.0, 1.0]:
					var q := lc + lh * (float(ca) * (la * 0.5 - 0.06)) + lat_v * (float(cb) * (lx * 0.5 - 0.06))
					_emit_obox(g.lumber, q + Vector3.UP * (leg_h * 0.5), Vector3.UP, lh, Vector3(leg_h, LEG_W, LEG_W))
			g.counts["lumber"] += 4
		g.counts["plywood"] += 1
		g.counts["lumber"] += 1
		if rail_on:
			for r in (lnd.rails as Array):
				_emit_rail_run(g, (r[0] as Vector3) + Vector3.UP * ly, (r[1] as Vector3) + Vector3.UP * ly, 3.0 * FT)
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


# ---- Ladders ----

static func _ladder_geo(L: Dictionary, e: Dictionary) -> Dictionary:
	var y0 := _floor_y(L, int(e["floor"]))
	var y_deck := _floor_y(L, int(e["to_level"]))
	if y_deck < y0 + 0.5:
		return {}
	return {"fr": _face_frame(str(e["face"]), L), "a": float(e["at_ft"]) * FT, "y0": y0,
		"y_deck": y_deck, "y1": y_deck + 3.0 * FT, "w": float(e["width_ft"]) * FT,
		"o": POST_W * 0.5 + 0.06}


## Two 2x4 rails up the face (on past the deck) and a rung every foot.
static func _emit_ladder(g: _Geom, L: Dictionary, e: Dictionary, st: SurfaceTool) -> void:
	var G := _ladder_geo(L, e)
	if G.is_empty():
		return
	var fr: Dictionary = G.fr
	var a: float = G.a
	var y0: float = G.y0
	var y1: float = G.y1
	var w: float = G.w
	var o: float = G.o
	for side in [-0.5, 0.5]:
		_emit_face_box(st, fr, a + w * float(side), (y0 + y1) * 0.5, o,
			Vector3(1.5 * IN, y1 - y0, 3.5 * IN))
	var y := y0 + FT
	var n := 0
	while y < float(G.y_deck) + 0.05:
		_emit_face_box(st, fr, a, y, o, Vector3(w, 1.25 * IN, 1.25 * IN))
		y += FT
		n += 1
	g.counts["lumber"] += 2 + n
	g.counts["ladders"] += 1


# ---- Stepped modules ----

## A bay-mode module's cell: {x0, x1, z0, z1, y_lo, y_hi}, or {} when the cell
## is cut away (a courtyard, the U).
static func _stepped_cell_geo(s: Dictionary, L: Dictionary, e: Dictionary) -> Dictionary:
	var levels: Array = L.levels
	var li := int(e["level"])
	if levels.is_empty() or li < 0 or li >= levels.size():
		return {}
	var b := int(e["bay"])
	var c := int(e["col"])
	var fx: Array = L.fx
	var zb := _cell_z_bounds(L.rz, float(L.frame_depth), c, int(L.cols))
	var cell := _resolve_cell(s, b, c, li, levels[li], bool(s["decked"]))
	var x0 := float(fx[b]) + POST_W * 0.5
	var x1 := float(fx[b + 1]) - POST_W * 0.5
	var z0: float = zb.x
	var z1: float = zb.y
	var du := int(cell.get("depth_units", -1))
	if du >= 0:
		z1 = minf(z1, z0 + float(du) * HALF_PANEL_FT * FT)
	if _in_notch(L.notch, (x0 + x1) * 0.5, (z0 + z1) * 0.5):
		return {}
	var y_lo := float(levels[li - 1]["y"]) if li > 0 else 0.0
	return {"x0": x0, "x1": x1, "z0": z0, "z1": z1, "y_lo": y_lo, "y_hi": float(cell["y"])}


## A face-mode module: big steps outside `face` over its bays seg_from..seg_to,
## climbing to deck `to_level`. Step k (1 = the lowest) has its walking
## surface at k * riser and lies (n - 1 - k) treads out from the face; the deck
## itself is the n-th step.
static func _stepped_face_geo(s: Dictionary, L: Dictionary, e: Dictionary) -> Dictionary:
	var fr := _face_frame(str(e["face"]), L)
	var y_top := _floor_y(L, int(e["to_level"]))
	if y_top < 0.25:
		return {}
	var segs := _face_segments(str(e["face"]), L)
	if segs.is_empty():
		return {}
	var sf := clampi(int(e["seg_from"]), 0, segs.size() - 1)
	var st := clampi(int(e["seg_to"]), sf, segs.size() - 1)
	var n := maxi(2, int(ceil(y_top / (float(e["rise_in"]) * IN))))
	return {"fr": fr, "y_top": y_top, "n": n, "riser": y_top / float(n),
		"tread": float(e["tread_ft"]) * FT, "a0": float(segs[sf].x), "a1": float(segs[st].y),
		"o0": POST_W * 0.5 + 0.02}


static func _emit_stepped(g: _Geom, s: Dictionary, L: Dictionary, e: Dictionary) -> void:
	var eid := "el:" + str(e.get("id", ""))
	var elab := element_label(e, s) if g.record else ""
	var ov := g.begin([eid], [elab])
	if bool(ov.get("hidden", false)):
		return
	if str(e["mode"]) == "bay":
		var C := _stepped_cell_geo(s, L, e)
		if C.is_empty():
			return
		_emit_stairs(g, C.x0, C.x1, C.z0, C.z1, C.y_lo, C.y_hi, L.notch, [[eid], [elab]],
			str(e.get("id", "")), str(e["rise_toward"]), int(e["steps"]))
		g.counts["stairs"] += 1
		return
	var G := _stepped_face_geo(s, L, e)
	if G.is_empty():
		return
	var fr: Dictionary = G.fr
	var n: int = G.n
	var riser: float = G.riser
	var tread: float = G.tread
	var a0: float = G.a0
	var a1: float = G.a1
	var w := a1 - a0
	var am := (a0 + a1) * 0.5
	var key := str(e.get("id", ""))
	for k in range(1, n):
		var sov := g.begin([eid, "tread:%s:%d" % [key, k - 1]], [elab, "Step %d" % k])
		if bool(sov.get("hidden", false)):
			continue
		var lum := g.surf(sov, g.lumber)
		var ply := g.surf(sov, g.ply)
		var y := riser * float(k)
		var oi: float = float(G.o0) + float(n - 1 - k) * tread
		var oc := oi + tread * 0.5
		# The tread: a plywood top on joists running out from the face.
		_emit_face_box(ply, fr, am, y - PLY_T * 0.5, oc, Vector3(w, PLY_T, tread - SEAM))
		var nj := maxi(2, int(ceil(w / (2.0 * FT))) + 1)
		for j in range(nj):
			var a := lerpf(a0 + JOIST_W * 0.5, a1 - JOIST_W * 0.5, float(j) / float(nj - 1))
			_emit_face_box(lum, fr, a, y - PLY_T - JOIST_H * 0.5, oc,
				Vector3(JOIST_W, JOIST_H, tread))
		# Legs at the outer edge, at most 4' apart, down to the ground.
		var leg_h := y - PLY_T - JOIST_H
		if leg_h > 0.05:
			var nl := maxi(1, int(ceil(w / RAIL_POST_MAX)))
			for j in range(nl + 1):
				var a := lerpf(a0 + LEG_W * 0.5, a1 - LEG_W * 0.5, float(j) / float(nl))
				_emit_face_box(lum, fr, a, leg_h * 0.5, oi + tread - LEG_W * 0.5,
					Vector3(LEG_W, leg_h, LEG_W))
		# The riser closes the front of the step from the one below.
		if bool(e.get("closed_risers", true)):
			_emit_face_box(ply, fr, am, y - riser * 0.5 - PLY_T * 0.5, oi + tread - PLY_T * 0.5,
				Vector3(w, riser - PLY_T, PLY_T))
			g.counts["plywood"] += 1
		g.counts["plywood"] += maxi(1, int(ceil(w * tread / (SHEET_LONG * SHEET_SHORT) - 0.05)))
		g.counts["lumber"] += nj + (maxi(1, int(ceil(w / RAIL_POST_MAX))) + 1 if leg_h > 0.05 else 0)
	g.counts["stairs"] += 1


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
	# Push the plane out so the rafters under it clear the uprights at the top,
	# plus the gap the player asked for (spanned by joists, see _emit_lean_to).
	var offset := clampf(float(e.get("offset_ft", 0.0)), 0.0, 12.0) * FT
	var o_top := POST_W * 0.5 + 0.03 + (PURLIN_T + RAFTER_D) * rise / slope_len + offset
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
		"segs": segs, "offset": offset}


static func _lean_point(G: Dictionary, a: float, s_up: float, lift: float) -> Vector3:
	return _fp(G.fr, a, float(G.bot_y), float(G.o_bot)) + (G.d as Vector3) * s_up \
		+ (G.n as Vector3) * lift


## How many modules fit one bay of the slope, and where the grid starts.
## The module's own size comes from the element (panel_long_in / short / gap).
static func _pv_layout(G: Dictionary, a0: float, a1: float, e: Dictionary) -> Dictionary:
	var land := str(e.get("orientation", "landscape")) != "portrait"
	var long_m := float(e.get("panel_long_in", PV_LONG / IN)) * IN
	var short_m := float(e.get("panel_short_in", PV_SHORT / IN)) * IN
	var gap := float(e.get("panel_gap_in", PV_GAP / IN)) * IN
	var pw := long_m if land else short_m
	var ph := short_m if land else long_m
	var slen: float = G.slope_len
	var nc := int(floor((a1 - a0 - 0.04 + gap) / (pw + gap)))
	var nr := int(floor((slen - 0.04 + gap) / (ph + gap)))
	var rows_cap := int(e.get("pv_rows", 0))
	if rows_cap > 0:
		nr = mini(nr, rows_cap)
	if nc <= 0 or nr <= 0:
		return {"count": 0}
	var used_a := float(nc) * pw + float(nc - 1) * gap
	var used_s := float(nr) * ph + float(nr - 1) * gap
	var s_start := (slen - used_s) * 0.5
	if rows_cap > 0:
		match str(e.get("pv_from", "centre")):
			"top":
				s_start = slen - used_s - 0.02
			"bottom":
				s_start = 0.02
	return {"count": nc * nr, "nc": nc, "nr": nr, "pw": pw, "ph": ph, "land": land,
		"long": long_m, "short": short_m, "gap": gap,
		"a_start": a0 + (a1 - a0 - used_a) * 0.5, "s_start": s_start}


## Where module (r, c) of a bay's layout sits: Vector2(along, up-slope) centre.
static func _pv_center(lay: Dictionary, r: int, c: int) -> Vector2:
	var pw: float = lay["pw"]
	var ph: float = lay["ph"]
	var gap: float = lay["gap"]
	return Vector2(float(lay["a_start"]) + float(c) * (pw + gap) + pw * 0.5,
		float(lay["s_start"]) + float(r) * (ph + gap) + ph * 0.5)


static func _emit_lean_to(g: _Geom, s: Dictionary, L: Dictionary, e: Dictionary) -> void:
	var G := _lean_to_geo(s, L, e)
	var fr: Dictionary = G.fr
	var along_v: Vector3 = fr.along
	var dv: Vector3 = G.d
	var nv: Vector3 = G.n
	var slen: float = G.slope_len
	var eid := "el:" + str(e.get("id", ""))
	var elab := element_label(e)
	# Every bay is a part with its own pick box, drawn or not: a bay left off
	# stays clickable so it can be covered again.
	var live: Array = []
	for sg in G.segs:
		var a0: float = sg["a0"]
		var a1: float = sg["a1"]
		var bid := "%s:%d" % [eid, int(sg["i"])]
		var blab := "Bay %d · %s" % [int(sg["i"]) + 1, str(OPTION_LABELS.get(str(sg["surface"]), ""))]
		var bov := g.begin([eid, bid], [elab, blab])
		if g.record:
			var half := Vector3((a1 - a0) * 0.5, 0.18, slen * 0.5)
			g.add_box(Transform3D(Basis(along_v, nv, along_v.cross(nv)),
				_lean_point(G, (a0 + a1) * 0.5, slen * 0.5, 0.0)), half * 2.0)
		sg["id"] = bid
		sg["label"] = blab
		sg["ov"] = bov
		if str(sg["surface"]) != "none" and not bool(bov.get("hidden", false)):
			live.append(sg)
	g.end_part()
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
	var fov := g.begin([eid, eid + ":frame"], [elab, "Rafters and legs"])
	if not bool(fov.get("hidden", false)):
		var lum := g.surf(fov, g.lumber)
		for ra in raf:
			var a := clampf(float(ra), amin + RAFTER_W * 0.5, amax - RAFTER_W * 0.5)
			_emit_obox(lum, _lean_point(G, a, slen * 0.5, lift_r), dv, nv,
				Vector3(slen, RAFTER_D, RAFTER_W))
			g.counts["lumber"] += 1
			# A leg under the low end, and a prop at mid-slope on tall arrays.
			for s_up in [0.12, slen * 0.5]:
				var foot := _lean_point(G, a, s_up, under)
				if (s_up < 0.5 and foot.y > 0.08) or (s_up > 0.5 and foot.y > 1.4):
					_emit_obox(lum, Vector3(foot.x, foot.y * 0.5, foot.z), Vector3.UP, along_v,
						Vector3(foot.y, LEG_W, LEG_W))
					g.counts["lumber"] += 1
		var amid := (amin + amax) * 0.5
		var span := amax - amin
		_emit_obox(lum, _lean_point(G, amid, slen - 0.07, lift_r), along_v, Vector3.UP,
			Vector3(span, RAFTER_D, RAFTER_W))
		var foot0 := _lean_point(G, amid, 0.12, under)
		if foot0.y > 0.08:
			_emit_obox(lum, Vector3(foot0.x, 0.045, foot0.z), along_v, Vector3.UP,
				Vector3(span + LEG_W, 0.09, RAFTER_D))
		g.counts["lumber"] += 2
	if float(G.offset) > 0.02:
		_emit_lean_bridge(g, G, raf, amin, amax, e, eid, elab)
	for sg in live:
		var a0: float = sg["a0"]
		var a1: float = sg["a1"]
		var bid := str(sg["id"])
		var pre: Array = [eid, bid]
		var pre_l: Array = [elab, str(sg["label"])]
		var purlins: Array = []
		match str(sg["surface"]):
			"solar":
				var lay := _pv_layout(G, a0, a1, e)
				var holes: Array = []
				if int(lay["count"]) > 0:
					var long_ax: Vector3 = along_v if bool(lay["land"]) else dv
					var pw: float = lay["pw"]
					var ph: float = lay["ph"]
					for r in int(lay["nr"]):
						for c in int(lay["nc"]):
							var mov := g.begin(pre + ["%s:m%d,%d" % [bid, r, c]],
								pre_l + ["Panel %d" % (r * int(lay["nc"]) + c + 1)])
							if bool(mov.get("hidden", false)):
								continue
							var pc := _pv_center(lay, r, c)
							_emit_obox(g.pv, _lean_point(G, pc.x, pc.y, PV_T * 0.5), long_ax, nv,
								Vector3(float(lay["long"]), PV_T, float(lay["short"])))
							holes.append(Rect2(pc.x - pw * 0.5, pc.y - ph * 0.5, pw, ph))
							g.counts["solar_panels"] += 1
							g.counts["solar_watts"] += float(e["panel_watts"])
					for r in range(int(lay["nr"]) + 1):
						purlins.append(float(lay["s_start"]) + float(r) * (ph + float(lay["gap"]))
							- float(lay["gap"]) * 0.5)
				var fill := str(e.get("gap_fill", "open"))
				if fill != "open":
					_emit_gap_seal(g, G, a0, a1, holes, fill, pre, pre_l, bid)
			"glazing":
				_emit_slope_sheets(g, g.glass, G, a0, a1, GLAZING_T, "glazing", pre, pre_l, bid, false)
			"plywood":
				_emit_slope_sheets(g, g.ply, G, a0, a1, PLY_T, "plywood", pre, pre_l, bid, true)
		if purlins.is_empty():
			var k := 0.0
			while k < slen:
				purlins.append(k)
				k += 2.0 * FT
			purlins.append(slen)
		var pov := g.begin(pre + [bid + ":purlins"], pre_l + ["Purlins"])
		if bool(pov.get("hidden", false)):
			continue
		var pst := g.surf(pov, g.lumber)
		for ps in purlins:
			var sp := clampf(float(ps), 0.04, slen - 0.04)
			_emit_obox(pst, _lean_point(G, (a0 + a1) * 0.5, sp, -PURLIN_T * 0.5), along_v, nv,
				Vector3(a1 - a0, PURLIN_T, PURLIN_W))
			g.counts["lumber"] += 1
	# Close the triangular ends (a greenhouse) and the skirt under a raised slope.
	var ends := str(e.get("ends", "open"))
	if ends != "open":
		var eov := g.begin([eid, eid + ":ends"], [elab, "End walls"])
		if bool(eov.get("hidden", false)):
			g.end_part()
			return
		var st_e: SurfaceTool = g.glass if ends == "glazing" else g.surf(eov, g.ply)
		var o_wall := POST_W * 0.5 + 0.02
		var top_y: float = G.top_y
		var bot_y: float = G.bot_y
		var doors := end_door_spots(G, e, amin, amax)
		for a_end in [amin, amax]:
			var door: Dictionary = doors.get(a_end, {})
			if door.is_empty():
				var w_top := _fp(fr, a_end, top_y, o_wall)
				var p_top := _lean_point(G, a_end, slen, 0.0)
				var p_bot := _lean_point(G, a_end, 0.0, 0.0)
				var w_bot := _fp(fr, a_end, bot_y, o_wall)
				_emit_quad(st_e, w_top, p_top, p_bot, w_bot)
				if bot_y > 0.05:
					_emit_quad(st_e, w_bot, p_bot, Vector3(p_bot.x, 0.0, p_bot.z), Vector3(w_bot.x, 0.0, w_bot.z))
			else:
				_emit_end_wall_with_door(g, st_e, G, a_end, o_wall, door, e)
			g.counts["glazing" if ends == "glazing" else "plywood"] += 1
	g.end_part()


## Where a slope's end doors go: {a_end: {o0, o1, h, side}} for each end that
## has one. A door stands as near the structure as it can, where the slope is
## tallest, and is lowered to fit under it (no door where even 5' will not).
## "left" / "right" are as seen from outside, facing the slope.
static func end_door_spots(G: Dictionary, e: Dictionary, amin: float, amax: float) -> Dictionary:
	var out := {}
	var which := str(e.get("end_door", "none"))
	if which == "none" or str(e.get("ends", "open")) == "open":
		return out
	var fr: Dictionary = G.fr
	var right_v := (-(fr.out as Vector3)).cross(Vector3.UP)
	var amax_is_right := (fr.along as Vector3).dot(right_v) > 0.0
	var ends_w: Array = []
	if which == "both" or (which == "right") == amax_is_right:
		ends_w.append(amax)
	if which == "both" or (which == "right") != amax_is_right:
		ends_w.append(amin)
	var o_wall := POST_W * 0.5 + 0.02
	var dw := float(e.get("end_door_w_ft", 3.0)) * FT
	var o0 := o_wall + 0.12 + TRIM_W
	var o1 := minf(o0 + dw, float(G.o_bot) - TRIM_W - 0.05)
	if o1 - o0 < 0.5:
		return out
	var h := minf(float(e.get("end_door_h_ft", 6.75)) * FT, _end_wall_top(G, o1) - TRIM_W - 0.04)
	if h < 5.0 * FT - 0.01:
		return out
	for a_end in ends_w:
		out[a_end] = {"o0": o0, "o1": o1, "h": h, "sign": 1.0 if a_end == amax else -1.0}
	return out


## How high a slope's end wall reaches at distance `o` out from the face: the
## full top height up to the slope's top edge, then down the slope.
static func _end_wall_top(G: Dictionary, o: float) -> float:
	var o_top: float = G.o_top
	var o_bot: float = G.o_bot
	var top_y: float = G.top_y
	var bot_y: float = G.bot_y
	if o <= o_top:
		return top_y
	if o >= o_bot:
		return bot_y
	return top_y - (o - o_top) / maxf(o_bot - o_top, 0.001) * (top_y - bot_y)


## A slope's end wall with a door in it: strips across the end, each from the
## ground (above the door within it) up to the wall's top, then the door.
static func _emit_end_wall_with_door(g: _Geom, st: SurfaceTool, G: Dictionary, a_end: float,
		o_wall: float, door: Dictionary, e: Dictionary) -> void:
	var fr: Dictionary = G.fr
	var o0: float = door["o0"]
	var o1: float = door["o1"]
	var h: float = door["h"]
	var cuts: Array = [o_wall, o0, o1, float(G.o_top), float(G.o_bot)]
	cuts = _sorted_unique(cuts.filter(func(v): return float(v) >= o_wall - 1e-4 and float(v) <= float(G.o_bot) + 1e-4))
	for i in range(cuts.size() - 1):
		var oa := float(cuts[i])
		var ob := float(cuts[i + 1])
		if ob - oa < 0.005:
			continue
		var ya := _end_wall_top(G, oa)
		var yb := _end_wall_top(G, ob)
		var y_lo := h if (oa >= o0 - 1e-4 and ob <= o1 + 1e-4) else 0.0
		if ya <= y_lo + 0.005 and yb <= y_lo + 0.005:
			continue
		_emit_quad(st, _fp(fr, a_end, y_lo, oa), _fp(fr, a_end, y_lo, ob),
			_fp(fr, a_end, maxf(yb, y_lo), ob), _fp(fr, a_end, maxf(ya, y_lo), oa))
	# The door itself, in the end's own frame: "along" runs out from the face,
	# "out" points away from the slope's middle.
	var out_n: Vector3 = (fr.along as Vector3) * float(door.get("sign", 1.0))
	var efr := {"face": "end", "base": _fp(fr, a_end, 0.0, 0.0), "along": fr.out, "out": out_n,
		"len": float(G.o_bot)}
	var w := o1 - o0
	var a := (o0 + o1) * 0.5
	_emit_casing(g, efr, a, 0.0, w, h, false)
	if str(e.get("end_door_style", "hinged")) == "hinged":
		var paint := g.paint_for(str(e.get("end_door_color", "#f2efe6")))
		var hw := g.paint_for("#2b2b2b")
		_emit_door_leaf(paint, hw, efr, a, 0.0, w - 0.008, h - 0.008, 1.0)
	g.counts["doors"] += 1


## An offset slope's link back to the structure: a ledger on the face, a joist
## from it to the slope's top edge at every rafter, posts under the top edge
## when the gap is wide, and (bridge "plywood" / "glazing") a cover over the
## strip, flush with the slope's top. One part, "<el>:bridge".
static func _emit_lean_bridge(g: _Geom, G: Dictionary, raf: Array, amin: float, amax: float,
		e: Dictionary, eid: String, elab: String) -> void:
	var ov := g.begin([eid, eid + ":bridge"], [elab, "Joists to the structure"])
	if bool(ov.get("hidden", false)):
		return
	var fr: Dictionary = G.fr
	var top_y: float = G.top_y
	var cover := str(e.get("bridge", "open"))
	var th := 0.0 if cover == "open" else (GLAZING_T if cover == "glazing" else PLY_T)
	var lum := g.surf(ov, g.lumber)
	var o_face := POST_W * 0.5 + 0.02
	var o_end: float = G.o_top
	var jy := top_y - th - RAFTER_D * 0.5
	var span_o := o_end - o_face
	var span_a := amax - amin
	# Ledger on the face, a rim at the slope's top edge.
	for o in [o_face + RAFTER_W * 0.5, o_end - RAFTER_W * 0.5]:
		_emit_face_box(lum, fr, (amin + amax) * 0.5, jy, o, Vector3(span_a, RAFTER_D, RAFTER_W))
		g.counts["lumber"] += 1
	for ra in raf:
		var a := clampf(float(ra), amin + RAFTER_W * 0.5, amax - RAFTER_W * 0.5)
		_emit_face_box(lum, fr, a, jy, o_face + span_o * 0.5, Vector3(RAFTER_W, RAFTER_D, span_o))
		g.counts["lumber"] += 1
	# A wide gap stands on posts under its outer rim, at most 8' apart.
	if float(G.offset) > 4.0 * FT:
		var post_h := jy - RAFTER_D * 0.5
		var n := maxi(1, int(ceil(span_a / (8.0 * FT))))
		for k in range(n + 1):
			var a := lerpf(amin + LEG_W * 0.5, amax - LEG_W * 0.5, float(k) / float(n))
			_emit_face_box(lum, fr, a, post_h * 0.5, o_end - RAFTER_W - LEG_W * 0.5,
				Vector3(LEG_W, post_h, LEG_W))
			g.counts["lumber"] += 1
	if th > 0.0:
		var st: SurfaceTool = g.glass if cover == "glazing" else g.surf(ov, g.ply)
		_emit_face_box(st, fr, (amin + amax) * 0.5, top_y - th * 0.5, o_face + span_o * 0.5,
			Vector3(span_a, th, span_o))
		g.counts["glazing" if cover == "glazing" else "plywood"] += maxi(1,
			int(ceil(span_a * span_o / (SHEET_LONG * SHEET_SHORT) - 0.05)))


## Seal a solar bay: plywood or glazing over every part of the bay the modules
## do not cover (the margins and the gaps between them), flush in the module
## plane. A hidden module leaves its spot to be sealed too. One part per bay,
## "<bay>:g".
static func _emit_gap_seal(g: _Geom, G: Dictionary, a0: float, a1: float, holes: Array,
		fill: String, pre: Array, pre_l: Array, bid: String) -> void:
	var slen: float = G.slope_len
	var pieces := rect_minus(Rect2(a0, 0.0, a1 - a0, slen), holes)
	if pieces.is_empty():
		return
	var ov := g.begin(pre + [bid + ":g"], pre_l + ["Gap seal · %s" %
		str(OPTION_LABELS.get(fill, fill)).to_lower()])
	if bool(ov.get("hidden", false)):
		return
	var glass := fill == "glazing"
	var th := GLAZING_T if glass else PLY_T
	var st: SurfaceTool = g.glass if glass else g.surf(ov, g.ply)
	var along_v: Vector3 = (G.fr as Dictionary).along
	var nv: Vector3 = G.n
	var area := 0.0
	for p in pieces:
		var pr: Rect2 = p
		if pr.size.x < 0.004 or pr.size.y < 0.004:
			continue
		_emit_obox(st, _lean_point(G, pr.position.x + pr.size.x * 0.5,
			pr.position.y + pr.size.y * 0.5, th * 0.5), along_v, nv,
			Vector3(pr.size.x, th, pr.size.y))
		area += pr.get_area()
	g.counts["glazing" if glass else "plywood"] += maxi(1,
		int(ceil(area / (SHEET_LONG * SHEET_SHORT) - 0.05)))


## `pre` / `pre_l` = the bay's path + labels; each sheet is a part of the bay.
static func _emit_slope_sheets(g: _Geom, st: SurfaceTool, G: Dictionary, a0: float, a1: float,
		thick: float, count_key: String, pre: Array = [], pre_l: Array = [], bid: String = "",
		paintable: bool = false) -> void:
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
			var sst := st
			if not pre.is_empty():
				var ov := g.begin(pre + ["%s:s%d,%d" % [bid, ia, si]],
					pre_l + ["Sheet %d" % (si * na + ia + 1)])
				if bool(ov.get("hidden", false)):
					continue
				if paintable:
					sst = g.surf(ov, st)
			_emit_obox(sst, _lean_point(G, sa + sw * 0.5, ss + sh * 0.5, thick * 0.5), along_v, nv,
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
	var eid := "el:" + str(e.get("id", ""))
	var elab := element_label(e, s) if g.record else ""
	var runs := _railing_runs(s, L, e)
	for k in runs.size():
		var r: Dictionary = runs[k]
		var ov := g.begin([eid, "%s:r%d" % [eid, k]], [elab, "Rail %d" % (k + 1)])
		if bool(ov.get("hidden", false)):
			continue
		_emit_rail_run(g, r["a"], r["b"], float(r["h"]), g.surf(ov, g.lumber))


## Posts at most RAIL_POST_MAX apart, a flat cap rail and a mid rail.
static func _emit_rail_run(g: _Geom, a: Vector3, b: Vector3, h: float,
		st: SurfaceTool = null) -> void:
	if st == null:
		st = g.lumber
	var dv := b - a
	var len := dv.length()
	if len < 0.1:
		return
	var axis := dv / len
	var np := maxi(1, int(ceil(len / RAIL_POST_MAX)))
	for k in range(np + 1):
		var p := a + axis * (len * float(k) / float(np))
		_emit_obox(st, p + Vector3.UP * (h * 0.5), Vector3.UP, axis,
			Vector3(h, 1.5 * IN, 3.5 * IN))
	_emit_obox(st, (a + b) * 0.5 + Vector3.UP * (h + 0.75 * IN), axis, Vector3.UP,
		Vector3(len + 0.09, 1.5 * IN, 3.5 * IN))
	_emit_obox(st, (a + b) * 0.5 + Vector3.UP * (h * 0.5), axis, Vector3.UP,
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
			var box := AABB(_stair_point(G, 0.0, -w * 0.5, 0.0), Vector3.ZERO)
			for lat in [-w * 0.5, w * 0.5]:
				box = box.expand(_stair_point(G, -w if bool(G.along) else 0.0, lat, float(G.y_top)))
			for f in (G.flights as Array):
				for lat in [-w * 0.5, w * 0.5]:
					box = box.expand(_flight_point(f, float(int(f.m)) * float(G.tread), lat, float(f.yb)))
					box = box.expand(_flight_point(f, 0.0, lat, float(f.yt) + STAIR_RAIL_H))
			for lnd in (G.landings as Array):
				var lat_v := Vector3.UP.cross(lnd.h as Vector3)
				for ca in [-0.5, 0.5]:
					for cb in [-0.5, 0.5]:
						box = box.expand((lnd.c as Vector3) + (lnd.h as Vector3) * (float(lnd.along) * float(ca))
							+ lat_v * (float(lnd.across) * float(cb)) + Vector3.UP * (float(lnd.y) + STAIR_RAIL_H))
			box = box.expand(_fp(G.fr, float(G.a) - w * 0.5, float(G.y_top), POST_W * 0.5))
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
		"ladder":
			var G := _ladder_geo(L, e)
			if G.is_empty():
				return out
			var c := base.duplicate()
			c["id"] = "el:" + id
			c["aabb"] = _face_aabb(G.fr, G.a, (float(G.y0) + float(G.y1)) * 0.5, G.o,
				Vector3(float(G.w) + 0.1, float(G.y1) - float(G.y0), 0.25))
			out.append(c)
		"stepped":
			var box := AABB()
			if str(e["mode"]) == "bay":
				var C := _stepped_cell_geo(s, L, e)
				if C.is_empty():
					return out
				box = AABB(Vector3(C.x0, C.y_lo, C.z0),
					Vector3(C.x1 - C.x0, maxf(float(C.y_hi) - float(C.y_lo), 0.1) + JOIST_H + PLY_T,
						C.z1 - C.z0))
			else:
				var G := _stepped_face_geo(s, L, e)
				if G.is_empty():
					return out
				var o_out: float = float(G.o0) + float(int(G.n) - 1) * float(G.tread)
				box = AABB(_fp(G.fr, G.a0, 0.0, G.o0), Vector3.ZERO)
				box = box.expand(_fp(G.fr, G.a1, float(G.y_top), o_out))
			var c := base.duplicate()
			c["id"] = "el:" + id
			c["mode"] = str(e["mode"])
			c["aabb"] = box.grow(0.03)
			out.append(c)
		"open_bay":
			var ofx: Array = L.fx
			var orz: Array = L.rz
			var ocols: int = L.cols
			var ob0 := int(e["bay0"])
			var ob1 := ob0 + int(e["bays"]) - 1
			var oc0 := 0 if int(e["cols"]) <= 0 else int(e["col0"])
			var oc1 := ocols - 1 if int(e["cols"]) <= 0 else int(e["col0"]) + int(e["cols"]) - 1
			var oy0 := 0.0 if int(e["floor"]) < 0 else _floor_y(L, int(e["floor"]))
			var za := _cell_z_bounds(orz, float(L.frame_depth), oc0, ocols).x
			var zb := _cell_z_bounds(orz, float(L.frame_depth), oc1, ocols).y
			var oc := base.duplicate()
			oc["id"] = "el:" + id
			oc["aabb"] = AABB(Vector3(float(ofx[ob0]), oy0, za),
				Vector3(float(ofx[ob1 + 1]) - float(ofx[ob0]), maxf(float(L.height) - oy0, 0.3), zb - za))
			out.append(oc)
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


## The solar modules on a rack's sloped arrays (fused racks included):
## {count, watts, watts_per_panel, avg_normal (builder-local), tilt_deg,
## panel_w_m, panel_h_m, voc, vmp, isc, imp}. Counts match the geometry
## exactly (same _pv_layout). The electrical numbers and size are the module
## that makes up most of the panels.
static func solar_summary(spec: Dictionary) -> Dictionary:
	var s := resolve_spec(spec)
	var acc := {"count": 0, "watts": 0.0, "nsum": Vector3.ZERO, "by_model": {}}
	_solar_accumulate(s, Basis(), acc)
	for f in (s.get("fused", []) as Array):
		_solar_accumulate(resolve_spec(f["spec"]),
			Basis(Vector3.UP, deg_to_rad(float(f["yaw"]))), acc)
	var count: int = acc["count"]
	var watts: float = acc["watts"]
	var avg: Vector3 = (acc["nsum"] as Vector3).normalized() if count > 0 else Vector3.UP
	var best := {}
	var best_n := -1
	for k in (acc["by_model"] as Dictionary).keys():
		var r: Dictionary = acc["by_model"][k]
		if int(r["n"]) > best_n:
			best_n = int(r["n"])
			best = r
	var m0: Dictionary = PV_MODULES["60cell_300"]
	return {"count": count, "watts": watts,
		"watts_per_panel": watts / float(count) if count > 0 else PV_WATTS,
		"avg_normal": avg, "tilt_deg": rad_to_deg(acos(clampf(avg.y, -1.0, 1.0))),
		"panel_w_m": float(best.get("short", PV_SHORT)), "panel_h_m": float(best.get("long", PV_LONG)),
		"voc": float(best.get("voc", m0["voc"])), "vmp": float(best.get("vmp", m0["vmp"])),
		"isc": float(best.get("isc", m0["isc"])), "imp": float(best.get("imp", m0["imp"]))}


static func _solar_accumulate(s: Dictionary, basis: Basis, acc: Dictionary) -> void:
	var L := _layout(s, _metrics(s))
	for e in (s.get("elements", []) as Array):
		if not (e is Dictionary) or str(e.get("type", "")) != "lean_to":
			continue
		var G := _lean_to_geo(s, L, e)
		var eid := "el:" + str(e.get("id", ""))
		var mkey := "%s|%.1f|%.1f|%.2f|%.2f|%.2f|%.2f" % [str(e["panel_model"]),
			float(e["panel_long_in"]), float(e["panel_short_in"]), float(e["panel_voc"]),
			float(e["panel_vmp"]), float(e["panel_isc"]), float(e["panel_imp"])]
		for sg in G.segs:
			if str(sg["surface"]) != "solar":
				continue
			var lay := _pv_layout(G, sg["a0"], sg["a1"], e)
			var bid := "%s:%d" % [eid, int(sg["i"])]
			# Modules hidden one by one (or a hidden bay) make nothing.
			var n := 0
			if int(lay["count"]) > 0:
				for r in int(lay["nr"]):
					for c in int(lay["nc"]):
						if not bool(merged_override(s, [eid, bid, "%s:m%d,%d" % [bid, r, c]]).get("hidden", false)):
							n += 1
			if n == 0:
				continue
			acc["count"] = int(acc["count"]) + n
			acc["watts"] = float(acc["watts"]) + float(n) * float(e["panel_watts"])
			acc["nsum"] = (acc["nsum"] as Vector3) + basis * (G.n as Vector3) * float(n)
			var bm: Dictionary = acc["by_model"]
			if not bm.has(mkey):
				bm[mkey] = {"n": 0, "long": float(e["panel_long_in"]) * IN,
					"short": float(e["panel_short_in"]) * IN, "voc": float(e["panel_voc"]),
					"vmp": float(e["panel_vmp"]), "isc": float(e["panel_isc"]),
					"imp": float(e["panel_imp"])}
			bm[mkey]["n"] = int(bm[mkey]["n"]) + n


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
		{"id": "build_bay", "name": "Build a rack bay",
			"blurb": "The Mars build lab's flagship sequence: one bay of 12 ft uprights and 9 ft beams seated at 0.5 m and 1.8 m, a deck on the upper pair and a stair up to it.",
			"spec": {"upright_height_ft": 12, "beam_span_ft": 9, "bay_count": 1, "column_count": 1,
				"row_gap_ft": 4.0, "deck_levels": 2, "level_heights_ft": [1.64, 5.9], "roof_deck": false,
				"cell_overrides": {"0,0,0": {"kind": "none"}},
				"elements": [
					{"type": "stair", "face": "front", "at_ft": 4.8, "to_level": 1, "run": "out",
						"width_ft": 3.0, "handrail": true},
				]}},
		{"id": "chiba_2024", "name": "Chiba 2024",
			"blurb": "Chiba at Mars College, 2024: a two-storey rack with a red solar slope and greenhouse on the back, a grand front stair, a stepped roof at one end.",
			"spec": chiba_2024_spec()},
		{"id": "chiba_2026", "name": "Chiba 2026",
			"blurb": "Chiba at Mars College, 2026: a 20' walled block with an offset solar slope, a turned rack half open above its deck with a greenhouse, and a closed box.",
			"spec": chiba_2026_spec()},
	]


# ---------------------------------------------------------------------------
# Chiba — the Mars College builds, read off the camp's own models
# ---------------------------------------------------------------------------

## A rack's bay pitch (m) for a beam span in feet: the module design_presets
## lay fused racks out on.
static func _bay_pitch(beam_ft: int) -> float:
	return float(beam_ft) * FT + POST_W


## Wall-sheet keys ("face,ia,iv") of `face` from sheet column ia0 on, rows
## iv0 and up — the upper sheets taken off where a bay is open above a deck.
static func _sheets_from(face: String, ia0: int, ia1: int, iv0: int, iv1: int) -> Array:
	var out: Array = []
	for ia in range(ia0, ia1 + 1):
		for iv in range(iv0, iv1 + 1):
			out.append("%s,%d,%d" % [face, ia, iv])
	return out


## Chiba 2024: a 6-bay, 5-column 16' rack (36" frames 3.5' apart) with decks
## at 9" and 8' 3" and a railed roof. The front (-Z) is walled on both floors,
## a wide stair climbs straight out to a doorway on the first floor, a ladder
## goes on to the roof. The back carries a 60° solar slope over bays 1–2
## (four rows of modules from the top, the rest sealed red) and a 60°
## greenhouse over bays 5–6, with a stair along the face between them. A
## one-bay rack fused onto the -X end steps up from its first-floor deck to
## the roof in two big flights; its end wall has windows.
static func chiba_2024_spec() -> Dictionary:
	var red := "#b8352a"
	var white := "#e9e6df"
	var px := _bay_pitch(12)
	var main := {
		"upright_depth_in": 36, "upright_height_ft": 16, "beam_span_ft": 12,
		"bay_count": 6, "column_count": 5, "row_gap_ft": 3.5,
		"deck_levels": 2, "level_heights_ft": [0.75, 8.25], "roof_deck": true, "decked": true,
		"walls": {"front": true, "back": false, "left": false, "right": false},
		"part_overrides": {"wallface:front": {"color": white}},
		"elements": [
			{"id": "e1", "type": "lean_to", "face": "back", "surface": "solar", "seg_from": 0, "seg_to": 1,
				"angle_deg": 60.0, "attach_level": -1, "bottom_ft": 0.0, "ends": "plywood",
				"panel_model": "60cell_300", "orientation": "landscape", "pv_rows": 4, "pv_from": "top",
				"gap_fill": "plywood"},
			{"id": "e2", "type": "lean_to", "face": "back", "surface": "glazing", "seg_from": 4, "seg_to": 5,
				"angle_deg": 60.0, "attach_level": -1, "bottom_ft": 0.0, "ends": "plywood"},
			{"id": "e3", "type": "stair", "face": "back", "at_ft": 36.0, "to_level": 1, "run": "along",
				"width_ft": 4.0, "handrail": true},
			{"id": "e4", "type": "stair", "face": "front", "at_ft": 30.5, "to_level": 1, "run": "out",
				"width_ft": 11.0, "handrail": true, "tread_in": 13.0, "landing_ft": 6.0},
			{"id": "e5", "type": "door", "face": "front", "at_ft": 30.5, "floor": 1, "style": "opening",
				"width_ft": 6.5, "height_ft": 7.0},
			{"id": "e6", "type": "ladder", "face": "front", "at_ft": 23.0, "floor": 1, "to_level": 2},
			{"id": "e7", "type": "railing", "floor": 2, "right": false, "inner": false},
		],
	}
	# The slopes' frames and sheathing are painted red, as the build is.
	for eid in ["el:e1", "el:e2"]:
		(main["part_overrides"] as Dictionary)[eid] = {"color": red}
	var end := {
		"upright_depth_in": 36, "upright_height_ft": 16, "beam_span_ft": 12,
		"bay_count": 1, "column_count": 5, "row_gap_ft": 3.5,
		"deck_levels": 2, "level_heights_ft": [0.75, 8.25], "roof_deck": true, "decked": true,
		"walls": {"front": true, "back": true, "left": false, "right": true},
		# The side walls stop under the first-floor deck, where the steps rise.
		"wall_sheet_deleted": _sheets_from("front", 0, 3, 1, 1) + _sheets_from("back", 0, 3, 1, 1),
		"part_overrides": {"wallface:right": {"color": white}, "wallface:front": {"color": white},
			"wallface:back": {"color": white}},
		# Open to the first-floor deck except where the two flights climb.
		"cell_overrides": {"0,0,2": {"kind": "none"}, "0,2,2": {"kind": "none"}, "0,4,2": {"kind": "none"}},
		"elements": [
			{"id": "e1", "type": "stepped", "mode": "bay", "bay": 0, "col": 1, "level": 2,
				"rise_toward": "left", "steps": 4},
			{"id": "e2", "type": "stepped", "mode": "bay", "bay": 0, "col": 3, "level": 2,
				"rise_toward": "left", "steps": 4},
			{"id": "e3", "type": "window", "face": "right", "at_ft": 9.0, "floor": 1, "width_ft": 5.0,
				"height_ft": 2.5, "sill_ft": 3.0},
			{"id": "e4", "type": "window", "face": "right", "at_ft": 27.0, "floor": 1, "width_ft": 5.0,
				"height_ft": 2.5, "sill_ft": 3.0},
			{"id": "e5", "type": "railing", "floor": 1, "left": false, "inner": false},
		],
	}
	main["fused"] = [{"spec": end, "x": -(3.0 * px + px * 0.5), "z": 0.0, "yaw": 0.0}]
	return main


## Chiba 2026: three racks staggered round a fourth.
## - The main block (4 bays x 3 columns of 20' frames, decks at 3" and 9', a
##   railed roof) is walled in brown all round. Its +X side carries a 45°
##   slope stood 11' off the face on joists with a plywood cover: two rows of
##   400 W modules at the top, plywood below, closed ends. A painted stair
##   climbs straight out of the back to a yellow door on the first floor; a
##   stair runs along the -X side to the roof.
## - North-west, turned a quarter, a 4-bay x 3-column rack 4.5' between frames
##   with a roof over its first two bays only: the other two stand open above
##   their first-floor deck, frames bare, with a greenhouse leaning on their
##   east side up to that deck.
## - Beside it a closed 16' box: 2 bays of 10', walled all round, roofed.
static func chiba_2026_spec() -> Dictionary:
	var brown := "#6b5236"
	var walls_all := {"front": true, "back": true, "left": true, "right": true}
	var main := {
		"upright_depth_in": 42, "upright_height_ft": 20, "beam_span_ft": 12,
		"bay_count": 4, "column_count": 3, "row_gap_ft": 8.0,
		"deck_levels": 2, "level_heights_ft": [0.25, 9.0], "roof_deck": true, "decked": true,
		"walls": walls_all.duplicate(),
		"part_overrides": {},
		"elements": [
			{"id": "e1", "type": "lean_to", "face": "left", "surface": "solar", "seg_from": 0, "seg_to": 2,
				"angle_deg": 45.0, "attach_level": -1, "bottom_ft": 0.0, "ends": "plywood",
				"offset_ft": 11.0, "bridge": "plywood", "panel_model": "72cell_400",
				"panel_long_in": 77.0, "panel_short_in": 39.1, "panel_watts": 400.0, "panel_voc": 48.0,
				"panel_vmp": 41.0, "panel_isc": 11.0, "panel_imp": 9.76,
				"orientation": "portrait", "pv_rows": 2, "pv_from": "top", "gap_fill": "plywood"},
			{"id": "e2", "type": "stair", "face": "back", "at_ft": 6.0, "to_level": 1, "run": "out",
				"width_ft": 5.0, "handrail": true},
			{"id": "e3", "type": "door", "face": "back", "at_ft": 6.0, "floor": 1, "style": "hinged",
				"width_ft": 3.0, "height_ft": 6.75, "color": "#e5c22b"},
			{"id": "e4", "type": "stair", "face": "right", "at_ft": 8.0, "to_level": 2, "run": "along",
				"width_ft": 3.0, "handrail": true},
			{"id": "e5", "type": "railing", "floor": 2},
		],
	}
	for f in ["front", "back", "left", "right"]:
		(main["part_overrides"] as Dictionary)["wallface:" + f] = {"color": brown}
	(main["part_overrides"] as Dictionary)["el:e1"] = {"color": brown}
	# The turned rack: bays 0-1 (B) roofed and walled, bays 2-3 (C) an open bay
	# above the first floor — no roof deck, no beams across the tops (bare
	# frames, as built), the long faces' walls off above that floor.
	var turned := {
		"upright_depth_in": 42, "upright_height_ft": 20, "beam_span_ft": 12,
		"bay_count": 4, "column_count": 3, "row_gap_ft": 4.5,
		"deck_levels": 2, "level_heights_ft": [0.25, 9.0], "roof_deck": true, "decked": true,
		"walls": {"front": true, "back": true, "left": false, "right": true},
		"part_overrides": {"wallface:front": {"color": brown}, "wallface:back": {"color": brown},
			"wallface:right": {"color": brown}},
		"elements": [
			{"id": "e1", "type": "lean_to", "face": "back", "surface": "glazing", "seg_from": 2, "seg_to": 3,
				"angle_deg": 50.0, "attach_level": 1, "bottom_ft": 0.0, "ends": "plywood"},
			{"id": "e2", "type": "railing", "floor": 1, "inner": false, "right": false},
			{"id": "e3", "type": "open_bay", "bay0": 2, "bays": 2, "cols": 0, "floor": 1},
		],
	}
	var box := {
		"upright_depth_in": 42, "upright_height_ft": 16, "beam_span_ft": 10,
		"bay_count": 2, "column_count": 1, "row_gap_ft": 8.0,
		"deck_levels": 1, "level_heights_ft": [0.25], "roof_deck": true, "decked": true,
		"walls": walls_all.duplicate(),
		"part_overrides": {"wallface:front": {"color": brown}, "wallface:back": {"color": brown},
			"wallface:left": {"color": brown}, "wallface:right": {"color": brown}},
	}
	main["fused"] = [
		{"spec": turned, "x": -12.9, "z": -13.1, "yaw": 90.0},
		{"spec": box, "x": -19.7, "z": -17.2, "yaw": 90.0},
	]
	return main


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
	xf = _mxf * xf
	if _rec != null:
		st = _rec.route(st)
		if _rec.record:
			_rec.add_box(xf, size)
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
	# The corner lists run counter-clockwise seen from outside; Godot's front
	# face is clockwise, so each triangle goes in reversed (see _emit_tri). A
	# mirroring transform turns the winding over again.
	var mirrored := xf.basis.determinant() < 0.0
	for f in faces:
		var n: Vector3 = (xf.basis * (f[0] as Vector3)).normalized()
		# Two triangles over corners f[1..4]: (0,2,1) and (0,3,2).
		var tri := [[1, 3, 2], [1, 4, 3]] if not mirrored else [[1, 2, 3], [1, 3, 4]]
		var uvmap := [[0, 2, 1], [0, 3, 2]] if not mirrored else [[0, 1, 2], [0, 2, 3]]
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


## Painted steel (a beam or upright given its own colour).
static func _paint_metal_material(hex: String) -> StandardMaterial3D:
	var c := Color.html(hex) if Color.html_is_valid(hex) else Color(0.5, 0.5, 0.5)
	return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, c)


## Everything outside the group open in the editor: faded, so the group reads.
static func _dim_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.62, 0.66, 0.72, 0.16)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Painted wood (doors) in the player's colour.
static func _paint_material(hex: String) -> StandardMaterial3D:
	var c := Color.html(hex) if Color.html_is_valid(hex) else Color(0.95, 0.94, 0.90)
	return StructureMaterials.make(StructureMaterials.Kind.WOOD, c)
