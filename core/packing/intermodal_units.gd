class_name IntermodalUnits
extends RefCounted
## Parametric intermodal handling units: ISO containers, pallets, IBCs,
## gaylords, drums and pallet-rack bays. Pure data + maths.
##
## A TEMPLATE is a family with real-standard defaults; a UNIT is a template
## plus the player's edited numbers. `resolve()` turns a unit into an entry
## in ContainerCatalog's own shape (interior / door / exterior / tare_kg /
## payload_kg), so PackSolver, PackTree and the Packing Lab take it with no
## new code path; ContainerCatalog.find falls back to `find()` here.
##
## Metres and kilograms throughout. Sources, per family below:
##   ISO 668:2020 series-1 container external dims + max gross; interiors and
##   tares are typical carrier datasheet values (Maersk / Hapag-Lloyd).
##   Floor strength: CTU Code (IMO/ILO/UNECE 2014) Annex 7 — a 20' floor takes
##   ~4.5 t per running metre, a 40' ~3.0 t/m, for a load spread across the
##   full width.
##   Pallets: EN 13698-1 (EUR / EPAL), GMA 48x40, ISO 6780 (1100 x 1100).
##   IBC: UN 31HA1 composite IBC datasheets (Schütz / Mauser), 1000 L and
##   275 US gal (1041 L).
##   Gaylords: Uline bulk-box listings (approximate; maker ratings vary).
##   Drums: UN 1A1/1A2 steel and 1H1/1H2 HDPE 55 US gal (208 L) datasheets.
##   Rack bays: RMI/ANSI MH16.1 typical teardrop selective rack (8' x 42"
##   frames, 8'-12' beams).

const LIBRARY_PATH := "user://intermodal_units.json"
const LIBRARY_VERSION := 1

const FAMILIES := ["container", "pallet", "ibc", "gaylord", "drum", "rack_bay"]

const FAMILY_LABELS := {
	"container": "Shipping container",
	"pallet": "Pallet",
	"ibc": "IBC tote",
	"gaylord": "Gaylord / bulk bin",
	"drum": "Drum",
	"rack_bay": "Pallet rack bay",
}

## Rated payload of a 48x40x36" corrugated gaylord by wall count
## (index = walls). Approximate Uline listing values; real ratings vary by
## board grade, so the field stays editable.
const GAYLORD_WALL_KG := [0.0, 230.0, 450.0, 680.0, 900.0, 1130.0]
## Corrugated board thickness per wall (C-flute ~4 mm, double wall ~7 mm).
const GAYLORD_WALL_MM := 5.0

## Every field a template can carry, with the unit shown in the editor.
## `kind`: "m" (shown in mm / ft-in), "kg", "int", "bool", "choice", "l".
const FIELDS := {
	"ext_l_m": {"label": "Outside length", "kind": "m"},
	"ext_w_m": {"label": "Outside width", "kind": "m"},
	"ext_h_m": {"label": "Outside height", "kind": "m"},
	"int_l_m": {"label": "Inside length", "kind": "m"},
	"int_w_m": {"label": "Inside width", "kind": "m"},
	"int_h_m": {"label": "Inside height", "kind": "m"},
	"door_w_m": {"label": "Door width", "kind": "m"},
	"door_h_m": {"label": "Door height", "kind": "m"},
	"paint": {"label": "Paint", "kind": "choice",
		"choices": ["red", "blue", "green", "rust", "orange", "tan", "grey", "white", "maroon"]},
	"open_top": {"label": "Open top", "kind": "bool"},
	"flat_rack": {"label": "Flat rack (no walls)", "kind": "bool"},
	"tare_kg": {"label": "Empty mass", "kind": "kg"},
	"max_gross_kg": {"label": "Max gross", "kind": "kg"},
	"floor_kg_per_m": {"label": "Floor load per running metre", "kind": "kg"},
	"deck_h_m": {"label": "Deck height", "kind": "m"},
	"entry": {"label": "Fork entry", "kind": "choice",
		"choices": ["2-way", "4-way"]},
	"static_kg": {"label": "Static load", "kind": "kg"},
	"dynamic_kg": {"label": "Dynamic load (on forks)", "kind": "kg"},
	"rack_kg": {"label": "Racking load", "kind": "kg"},
	"stack_h_m": {"label": "Load height limit", "kind": "m"},
	"volume_l": {"label": "Liquid volume", "kind": "l"},
	"walls": {"label": "Walls", "kind": "int", "min": 1, "max": 5},
	"lid": {"label": "Lid", "kind": "bool"},
	"diameter_m": {"label": "Diameter", "kind": "m"},
	"head": {"label": "Head", "kind": "choice", "choices": ["open", "tight"]},
	"material": {"label": "Material", "kind": "choice",
		"choices": ["steel", "hdpe"]},
	"beam_l_m": {"label": "Beam length (bay width)", "kind": "m"},
	"frame_d_m": {"label": "Frame depth", "kind": "m"},
	"frame_h_m": {"label": "Frame height", "kind": "m"},
	"levels": {"label": "Beam levels", "kind": "int", "min": 1, "max": 8},
	"level_kg": {"label": "Load per level", "kind": "kg"},
	"frame_kg": {"label": "Frame capacity", "kind": "kg"},
}

## Built-in templates. `params` are the defaults; `fields` the editable list
## in editor order.
const TEMPLATES: Array = [
	# --- ISO containers ---
	{"id": "iso_10", "family": "container", "label": "10' container",
		"icon": "📦", "fields": ["int_l_m", "int_w_m", "int_h_m", "door_w_m",
			"door_h_m", "paint", "tare_kg", "max_gross_kg", "floor_kg_per_m"],
		"params": {"ext_l_m": 2.991, "ext_w_m": 2.438, "ext_h_m": 2.591,
			"int_l_m": 2.802, "int_w_m": 2.352, "int_h_m": 2.393,
			"door_w_m": 2.343, "door_h_m": 2.280, "tare_kg": 1300.0,
			"max_gross_kg": 10160.0, "floor_kg_per_m": 4500.0,
			"open_top": false, "flat_rack": false, "paint": "red"},
		"notes": "1D. Not ISO-668 interchangeable on every chassis."},
	{"id": "iso_20", "family": "container", "label": "20' container",
		"icon": "📦", "fields": ["int_l_m", "int_w_m", "int_h_m", "door_w_m",
			"door_h_m", "paint", "tare_kg", "max_gross_kg", "floor_kg_per_m"],
		"params": {"ext_l_m": 6.058, "ext_w_m": 2.438, "ext_h_m": 2.591,
			"int_l_m": 5.898, "int_w_m": 2.352, "int_h_m": 2.393,
			"door_w_m": 2.343, "door_h_m": 2.280, "tare_kg": 2300.0,
			"max_gross_kg": 30480.0, "floor_kg_per_m": 4500.0,
			"open_top": false, "flat_rack": false, "paint": "red"},
		"notes": "1CC / 20GP."},
	{"id": "iso_40", "family": "container", "label": "40' container",
		"icon": "📦", "fields": ["int_l_m", "int_w_m", "int_h_m", "door_w_m",
			"door_h_m", "paint", "tare_kg", "max_gross_kg", "floor_kg_per_m"],
		"params": {"ext_l_m": 12.192, "ext_w_m": 2.438, "ext_h_m": 2.591,
			"int_l_m": 12.032, "int_w_m": 2.352, "int_h_m": 2.393,
			"door_w_m": 2.343, "door_h_m": 2.280, "tare_kg": 3750.0,
			"max_gross_kg": 30480.0, "floor_kg_per_m": 3000.0,
			"open_top": false, "flat_rack": false, "paint": "red"},
		"notes": "1AA / 40GP."},
	{"id": "iso_40hc", "family": "container", "label": "40' high cube",
		"icon": "📦", "fields": ["int_l_m", "int_w_m", "int_h_m", "door_w_m",
			"door_h_m", "paint", "tare_kg", "max_gross_kg", "floor_kg_per_m"],
		"params": {"ext_l_m": 12.192, "ext_w_m": 2.438, "ext_h_m": 2.896,
			"int_l_m": 12.032, "int_w_m": 2.352, "int_h_m": 2.698,
			"door_w_m": 2.343, "door_h_m": 2.585, "tare_kg": 3900.0,
			"max_gross_kg": 30480.0, "floor_kg_per_m": 3000.0,
			"open_top": false, "flat_rack": false, "paint": "red"},
		"notes": "1AAA / 40HC."},
	{"id": "iso_45hc", "family": "container", "label": "45' high cube",
		"icon": "📦", "fields": ["int_l_m", "int_w_m", "int_h_m", "door_w_m",
			"door_h_m", "paint", "tare_kg", "max_gross_kg", "floor_kg_per_m"],
		"params": {"ext_l_m": 13.716, "ext_w_m": 2.438, "ext_h_m": 2.896,
			"int_l_m": 13.556, "int_w_m": 2.352, "int_h_m": 2.698,
			"door_w_m": 2.340, "door_h_m": 2.585, "tare_kg": 4800.0,
			"max_gross_kg": 32500.0, "floor_kg_per_m": 3000.0,
			"open_top": false, "flat_rack": false, "paint": "red"},
		"notes": "1EEE. Road-length limits apply in many places."},
	{"id": "iso_20_ot", "family": "container", "label": "20' open top",
		"icon": "📦", "fields": ["int_l_m", "int_w_m", "int_h_m", "paint",
			"tare_kg", "max_gross_kg", "floor_kg_per_m"],
		"params": {"ext_l_m": 6.058, "ext_w_m": 2.438, "ext_h_m": 2.591,
			"int_l_m": 5.888, "int_w_m": 2.345, "int_h_m": 2.346,
			"door_w_m": 2.336, "door_h_m": 2.274, "tare_kg": 2350.0,
			"max_gross_kg": 30480.0, "floor_kg_per_m": 4500.0,
			"open_top": true, "flat_rack": false},
		"notes": "Loaded from above by crane or forklift; tarp roof."},
	{"id": "iso_40_fr", "family": "container", "label": "40' flat rack",
		"icon": "📦", "fields": ["int_l_m", "int_w_m", "int_h_m", "paint",
			"tare_kg", "max_gross_kg", "floor_kg_per_m"],
		"params": {"ext_l_m": 12.192, "ext_w_m": 2.438, "ext_h_m": 2.591,
			"int_l_m": 12.080, "int_w_m": 2.400, "int_h_m": 2.100,
			"door_w_m": 0.0, "door_h_m": 0.0, "tare_kg": 5000.0,
			"max_gross_kg": 45000.0, "floor_kg_per_m": 5000.0,
			"open_top": true, "flat_rack": true},
		"notes": "End walls only; oversize loads may overhang."},
	# --- Pallets ---
	{"id": "pallet_eur1", "family": "pallet", "label": "EUR / EPAL 1",
		"icon": "🟫", "fields": ["ext_l_m", "ext_w_m", "deck_h_m", "entry",
			"tare_kg", "static_kg", "dynamic_kg", "rack_kg", "stack_h_m"],
		"params": {"ext_l_m": 1.200, "ext_w_m": 0.800, "deck_h_m": 0.144,
			"entry": "4-way", "tare_kg": 25.0, "static_kg": 5500.0,
			"dynamic_kg": 1500.0, "rack_kg": 1000.0, "stack_h_m": 1.80},
		"notes": "EN 13698-1. Forks enter the short ends fully, the long sides partly."},
	{"id": "pallet_eur2", "family": "pallet", "label": "EUR 2 (1200 x 1000)",
		"icon": "🟫", "fields": ["ext_l_m", "ext_w_m", "deck_h_m", "entry",
			"tare_kg", "static_kg", "dynamic_kg", "rack_kg", "stack_h_m"],
		"params": {"ext_l_m": 1.200, "ext_w_m": 1.000, "deck_h_m": 0.162,
			"entry": "4-way", "tare_kg": 33.0, "static_kg": 6000.0,
			"dynamic_kg": 1500.0, "rack_kg": 1250.0, "stack_h_m": 1.80},
		"notes": "EN 13698-2."},
	{"id": "pallet_eur6", "family": "pallet", "label": "EUR 6 (half)",
		"icon": "🟫", "fields": ["ext_l_m", "ext_w_m", "deck_h_m", "entry",
			"tare_kg", "static_kg", "dynamic_kg", "rack_kg", "stack_h_m"],
		"params": {"ext_l_m": 0.800, "ext_w_m": 0.600, "deck_h_m": 0.144,
			"entry": "4-way", "tare_kg": 9.5, "static_kg": 1500.0,
			"dynamic_kg": 500.0, "rack_kg": 0.0, "stack_h_m": 1.20},
		"notes": "Display / half pallet; not for racking."},
	{"id": "pallet_gma", "family": "pallet", "label": "GMA 48 x 40",
		"icon": "🟫", "fields": ["ext_l_m", "ext_w_m", "deck_h_m", "entry",
			"tare_kg", "static_kg", "dynamic_kg", "rack_kg", "stack_h_m"],
		"params": {"ext_l_m": 1.219, "ext_w_m": 1.016, "deck_h_m": 0.145,
			"entry": "4-way", "tare_kg": 17.0, "static_kg": 2722.0,
			"dynamic_kg": 2087.0, "rack_kg": 1270.0, "stack_h_m": 1.83},
		"notes": "The North American standard; partial 4-way (notched stringers)."},
	{"id": "pallet_iso1100", "family": "pallet", "label": "ISO 1100 x 1100",
		"icon": "🟫", "fields": ["ext_l_m", "ext_w_m", "deck_h_m", "entry",
			"tare_kg", "static_kg", "dynamic_kg", "rack_kg", "stack_h_m"],
		"params": {"ext_l_m": 1.100, "ext_w_m": 1.100, "deck_h_m": 0.150,
			"entry": "4-way", "tare_kg": 22.0, "static_kg": 4000.0,
			"dynamic_kg": 1500.0, "rack_kg": 1000.0, "stack_h_m": 1.80},
		"notes": "ISO 6780 square pallet (Asia)."},
	# --- IBC totes ---
	{"id": "ibc_1000", "family": "ibc", "label": "IBC 1000 L",
		"icon": "🧊", "fields": ["ext_l_m", "ext_w_m", "ext_h_m", "volume_l",
			"tare_kg", "max_gross_kg", "entry"],
		"params": {"ext_l_m": 1.200, "ext_w_m": 1.000, "ext_h_m": 1.160,
			"volume_l": 1000.0, "tare_kg": 60.0, "max_gross_kg": 1960.0,
			"entry": "4-way", "deck_h_m": 0.150},
		"notes": "Cage + composite pallet base; stacks 1-over-1 full (static)."},
	{"id": "ibc_275gal", "family": "ibc", "label": "IBC 275 gal",
		"icon": "🧊", "fields": ["ext_l_m", "ext_w_m", "ext_h_m", "volume_l",
			"tare_kg", "max_gross_kg", "entry"],
		"params": {"ext_l_m": 1.219, "ext_w_m": 1.016, "ext_h_m": 1.168,
			"volume_l": 1041.0, "tare_kg": 63.0, "max_gross_kg": 2000.0,
			"entry": "4-way", "deck_h_m": 0.150},
		"notes": "48 x 40 x 46 in; the US water-tote classic."},
	# --- Gaylords ---
	{"id": "gaylord_48", "family": "gaylord", "label": "Gaylord 48 x 40 x 36",
		"icon": "📦", "fields": ["ext_l_m", "ext_w_m", "ext_h_m", "walls",
			"lid"],
		"params": {"ext_l_m": 1.219, "ext_w_m": 1.016, "ext_h_m": 0.914,
			"walls": 3, "lid": true, "tare_kg": 0.0, "max_gross_kg": 0.0},
		"notes": "Corrugated bulk box; set on a pallet to move it."},
	{"id": "gaylord_octo", "family": "gaylord", "label": "Gaylord octagon 48 x 40 x 48",
		"icon": "📦", "fields": ["ext_l_m", "ext_w_m", "ext_h_m", "walls",
			"lid"],
		"params": {"ext_l_m": 1.219, "ext_w_m": 1.016, "ext_h_m": 1.219,
			"walls": 5, "lid": false, "tare_kg": 0.0, "max_gross_kg": 0.0},
		"notes": "Octagonal bulk bin; the corners carry the stack."},
	# --- Drums ---
	{"id": "drum_55_steel", "family": "drum", "label": "55 gal drum (steel)",
		"icon": "🛢", "fields": ["diameter_m", "ext_h_m", "head", "material",
			"volume_l", "tare_kg"],
		"params": {"diameter_m": 0.572, "ext_h_m": 0.851, "head": "tight",
			"material": "steel", "volume_l": 208.0, "tare_kg": 19.0},
		"notes": "UN 1A1 (tight) / 1A2 (open head)."},
	{"id": "drum_55_hdpe", "family": "drum", "label": "55 gal drum (HDPE)",
		"icon": "🛢", "fields": ["diameter_m", "ext_h_m", "head", "material",
			"volume_l", "tare_kg"],
		"params": {"diameter_m": 0.585, "ext_h_m": 0.900, "head": "open",
			"material": "hdpe", "volume_l": 208.0, "tare_kg": 9.5},
		"notes": "UN 1H2 open head with a bolt ring; food grade."},
	# --- Rack bays ---
	{"id": "rack_bay_96", "family": "rack_bay", "label": "Rack bay 8' beams",
		"icon": "🗄", "fields": ["beam_l_m", "frame_d_m", "frame_h_m",
			"levels", "level_kg", "frame_kg"],
		"params": {"beam_l_m": 2.438, "frame_d_m": 1.067, "frame_h_m": 3.658,
			"levels": 3, "level_kg": 2041.0, "frame_kg": 9072.0},
		"notes": "Two 48x40 pallets per level, forks in from the aisle."},
	{"id": "rack_bay_108", "family": "rack_bay", "label": "Rack bay 9' beams",
		"icon": "🗄", "fields": ["beam_l_m", "frame_d_m", "frame_h_m",
			"levels", "level_kg", "frame_kg"],
		"params": {"beam_l_m": 2.743, "frame_d_m": 1.067, "frame_h_m": 4.877,
			"levels": 4, "level_kg": 2268.0, "frame_kg": 10886.0},
		"notes": "Two EUR or GMA pallets per level with clearance."},
]

## Beam face + clearance stacked per rack level (beam ~0.10 m deep, 0.15 m
## lift-off clearance over the load, RMI practice).
const RACK_LEVEL_OVERHEAD_M := 0.25


static func templates() -> Array:
	return TEMPLATES


static func templates_of(family: String) -> Array:
	var out: Array = []
	for t in TEMPLATES:
		if str(t.get("family", "")) == family:
			out.append(t)
	return out


static func template(template_id: String) -> Dictionary:
	for t in TEMPLATES:
		if str(t.get("id", "")) == template_id:
			return t
	return {}


static func defaults(template_id: String) -> Dictionary:
	return (template(template_id).get("params", {}) as Dictionary).duplicate(true)


## Template defaults with the player's edits laid over them. Only keys the
## template knows are kept; numbers stay numbers.
static func merged_params(template_id: String, params: Dictionary) -> Dictionary:
	var p := defaults(template_id)
	for k in params.keys():
		if not p.has(k):
			continue
		var d = p[k]
		var v = params[k]
		if d is bool:
			p[k] = bool(v)
		elif d is int:
			p[k] = int(v)
		elif d is float:
			p[k] = float(v)
		else:
			p[k] = str(v)
	return p


## A unit as a ContainerCatalog-shaped entry. `unit_id` / `label` default to
## the template's.
static func resolve(template_id: String, params: Dictionary = {},
		unit_id: String = "", label: String = "") -> Dictionary:
	var t := template(template_id)
	if t.is_empty():
		return {}
	var p := merged_params(template_id, params)
	var fam := str(t.get("family", ""))
	var e: Dictionary = {
		"id": unit_id if not unit_id.is_empty() else str(t.get("id", "")),
		"label": label if not label.is_empty() else str(t.get("label", "")),
		"icon": str(t.get("icon", "📦")),
		"family": fam, "template": str(t.get("id", "")),
		"params": p, "notes": str(t.get("notes", "")),
		"intermodal": true,
	}
	match fam:
		"container":
			_resolve_container(e, p)
		"pallet":
			_resolve_pallet(e, p)
		"ibc":
			_resolve_ibc(e, p)
		"gaylord":
			_resolve_gaylord(e, p)
		"drum":
			_resolve_drum(e, p)
		"rack_bay":
			_resolve_rack(e, p)
	return e


static func _resolve_container(e: Dictionary, p: Dictionary) -> void:
	e["kind"] = "container"
	var il := float(p["int_l_m"])
	var iw := float(p["int_w_m"])
	var ih := float(p["int_h_m"])
	# Outside follows inside by the standard wall allowance when edited.
	e["interior"] = {"l_m": il, "w_m": iw, "h_m": ih}
	e["exterior"] = {"l_m": maxf(float(p["ext_l_m"]), il + 0.16),
		"w_m": maxf(float(p["ext_w_m"]), iw + 0.086),
		"h_m": maxf(float(p["ext_h_m"]), ih + 0.198)}
	if bool(p.get("open_top", false)):
		e["door"] = null
	else:
		e["door"] = {"w_m": minf(float(p["door_w_m"]), iw),
			"h_m": minf(float(p["door_h_m"]), ih)}
	var tare := float(p["tare_kg"])
	e["tare_kg"] = tare
	e["max_gross_kg"] = float(p["max_gross_kg"])
	e["payload_kg"] = maxf(0.0, float(p["max_gross_kg"]) - tare)
	e["floor_kg_per_m"] = float(p["floor_kg_per_m"])
	e["floor_kg_m2"] = float(p["floor_kg_per_m"]) / maxf(iw, 0.01)
	e["forks_from"] = "door"
	e["paint"] = str(p.get("paint", CargoContainerBuilder.DEFAULT_PAINT))


static func _resolve_pallet(e: Dictionary, p: Dictionary) -> void:
	e["kind"] = "sub"
	var l := float(p["ext_l_m"])
	var w := float(p["ext_w_m"])
	var deck := float(p["deck_h_m"])
	# Open top: the load height limit is convention, not a wall.
	e["interior"] = {"l_m": l, "w_m": w, "h_m": float(p["stack_h_m"])}
	e["door"] = null
	e["exterior"] = {"l_m": l, "w_m": w, "h_m": deck}
	e["deck_h_m"] = deck
	e["tare_kg"] = float(p["tare_kg"])
	e["payload_kg"] = float(p["dynamic_kg"])
	e["static_kg"] = float(p["static_kg"])
	e["rack_kg"] = float(p["rack_kg"])
	e["fork_entry"] = str(p["entry"])
	e["pallet"] = true


static func _resolve_ibc(e: Dictionary, p: Dictionary) -> void:
	e["kind"] = "sub"
	var l := float(p["ext_l_m"])
	var w := float(p["ext_w_m"])
	var h := float(p["ext_h_m"])
	e["interior"] = {"l_m": l - 0.06, "w_m": w - 0.06,
		"h_m": h - float(p.get("deck_h_m", 0.15)) - 0.05}
	e["door"] = null
	e["exterior"] = {"l_m": l, "w_m": w, "h_m": h}
	e["tare_kg"] = float(p["tare_kg"])
	# Liquid at water density (1 kg/L), capped by the rated gross.
	var liquid := float(p["volume_l"])
	e["volume_l"] = liquid
	e["payload_kg"] = minf(liquid, float(p["max_gross_kg"]) - float(p["tare_kg"]))
	e["fork_entry"] = str(p["entry"])
	e["liquid"] = true


static func _resolve_gaylord(e: Dictionary, p: Dictionary) -> void:
	e["kind"] = "sub"
	var walls := clampi(int(p["walls"]), 1, 5)
	var wall_m := walls * GAYLORD_WALL_MM * 0.001
	var l := float(p["ext_l_m"])
	var w := float(p["ext_w_m"])
	var h := float(p["ext_h_m"])
	e["interior"] = {"l_m": l - 2.0 * wall_m, "w_m": w - 2.0 * wall_m,
		"h_m": h - wall_m}
	e["door"] = null
	e["exterior"] = {"l_m": l, "w_m": w,
		"h_m": h + (0.03 if bool(p["lid"]) else 0.0)}
	# Board mass: ~0.55 kg/m² per wall of corrugated (C-flute single wall).
	var area := 2.0 * (l + w) * h + l * w * (2.0 if bool(p["lid"]) else 1.0)
	var tare := float(p.get("tare_kg", 0.0))
	e["tare_kg"] = tare if tare > 0.0 else area * 0.55 * walls
	var rated := float(p.get("max_gross_kg", 0.0))
	e["payload_kg"] = rated if rated > 0.0 else float(GAYLORD_WALL_KG[walls])
	e["walls"] = walls
	e["needs_pallet"] = true


static func _resolve_drum(e: Dictionary, p: Dictionary) -> void:
	e["kind"] = "sub"
	var d := float(p["diameter_m"])
	var h := float(p["ext_h_m"])
	var wall := 0.0012 if str(p["material"]) == "steel" else 0.004
	e["interior"] = {"l_m": d - 2.0 * wall, "w_m": d - 2.0 * wall,
		"h_m": h - 0.02}
	e["door"] = null
	e["exterior"] = {"l_m": d, "w_m": d, "h_m": h}
	e["tare_kg"] = float(p["tare_kg"])
	e["volume_l"] = float(p["volume_l"])
	e["payload_kg"] = float(p["volume_l"])
	e["round"] = true


static func _resolve_rack(e: Dictionary, p: Dictionary) -> void:
	e["kind"] = "rack"
	var levels := maxi(1, int(p["levels"]))
	var bl := float(p["beam_l_m"])
	var fd := float(p["frame_d_m"])
	var fh := float(p["frame_h_m"])
	# One level's clear opening: the frame height shared between the levels
	# (the ground level included), minus beam + lift-off clearance.
	var clear := fh / float(levels + 1) - RACK_LEVEL_OVERHEAD_M
	e["interior"] = {"l_m": bl - 0.10, "w_m": fd + 0.15, "h_m": maxf(0.3, clear)}
	e["door"] = null
	e["exterior"] = {"l_m": bl + 0.15, "w_m": fd, "h_m": fh}
	e["levels"] = levels
	e["level_kg"] = float(p["level_kg"])
	# The frame carries every level; the smaller limit wins.
	e["payload_kg"] = minf(float(p["level_kg"]) * levels, float(p["frame_kg"]))
	# Teardrop rack ~16 kg per metre of upright + 7 kg per metre of beam.
	e["tare_kg"] = 2.0 * fh * 16.0 + 2.0 * levels * bl * 7.0


## The unit as a packed spec: exterior + tare (an empty pallet, a stacked
## drum). this_side_up: these are moved upright.
static func packed_spec_for(entry: Dictionary) -> Dictionary:
	if entry.is_empty() or not entry.has("exterior"):
		return {}
	var x: Dictionary = entry["exterior"]
	var form := "container"
	match str(entry.get("family", "")):
		"pallet":
			form = "pallet"
		"drum", "ibc":
			form = "tank"
		"gaylord":
			form = "crate"
		"rack_bay":
			form = "bundle"
	var spec := {
		"w_m": float(x["l_m"]), "d_m": float(x["w_m"]), "h_m": float(x["h_m"]),
		"mass_kg": float(entry.get("tare_kg", PackedSpec.MASS_UNKNOWN)),
		"form": form, "source": "computed", "this_side_up": true,
	}
	# A knocked-down rack bay ships as a bundle of uprights + beams.
	if str(entry.get("family", "")) == "rack_bay":
		spec = {"w_m": float(x["h_m"]), "d_m": float(x["w_m"]) + 0.1,
			"h_m": 0.35, "mass_kg": float(entry.get("tare_kg", 0.0)),
			"form": "bundle", "source": "computed"}
	return PackedSpec.normalize(spec)


static func builtin_entries() -> Array:
	var out: Array = []
	for t in TEMPLATES:
		out.append(resolve(str(t["id"])))
	return out


## ── User library ───────────────────────────────────────────────────────────
## {version, units: [{id, template, label, params}]}. `path` is a parameter so
## the selftest round-trips a TEMP file.

static func load_library(path: String = LIBRARY_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var txt := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return []
	var out: Array = []
	for u in (parsed as Dictionary).get("units", []):
		if not (u is Dictionary):
			continue
		var ud: Dictionary = u
		if template(str(ud.get("template", ""))).is_empty():
			continue
		out.append({"id": str(ud.get("id", "")),
			"template": str(ud.get("template", "")),
			"label": str(ud.get("label", "")),
			"params": merged_params(str(ud["template"]), ud.get("params", {}))})
	return out


static func save_library(units: Array, path: String = LIBRARY_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": LIBRARY_VERSION, "units": units},
		"\t"))
	f.close()
	return true


## Adds (or replaces by id) a user unit; returns its id. A new unit gets a
## stable id from its label.
static func save_user_unit(template_id: String, label: String,
		params: Dictionary, unit_id: String = "",
		path: String = LIBRARY_PATH) -> String:
	var units := load_library(path)
	var uid := unit_id
	if uid.is_empty():
		uid = "u_" + _slug(label)
		var taken := {}
		for u in units:
			taken[str(u["id"])] = true
		var base := uid
		var n := 2
		while taken.has(uid) or not template(uid).is_empty():
			uid = "%s_%d" % [base, n]
			n += 1
	var rec := {"id": uid, "template": template_id, "label": label,
		"params": merged_params(template_id, params)}
	var replaced := false
	for i in units.size():
		if str(units[i]["id"]) == uid:
			units[i] = rec
			replaced = true
	if not replaced:
		units.append(rec)
	save_library(units, path)
	return uid


static func remove_user_unit(unit_id: String, path: String = LIBRARY_PATH) -> bool:
	var units := load_library(path)
	var kept: Array = []
	for u in units:
		if str(u["id"]) != unit_id:
			kept.append(u)
	if kept.size() == units.size():
		return false
	return save_library(kept, path)


static func user_entries(path: String = LIBRARY_PATH) -> Array:
	var out: Array = []
	for u in load_library(path):
		out.append(resolve(str(u["template"]), u["params"], str(u["id"]),
			str(u["label"])))
	return out


## Built-in template or user unit by id, resolved. {} when unknown.
static func find(unit_id: String, path: String = LIBRARY_PATH) -> Dictionary:
	if not template(unit_id).is_empty():
		return resolve(unit_id)
	for u in load_library(path):
		if str(u["id"]) == unit_id:
			return resolve(str(u["template"]), u["params"], unit_id,
				str(u["label"]))
	return {}


static func _slug(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif not out.ends_with("_"):
			out += "_"
	out = out.strip_edges().trim_suffix("_").trim_prefix("_")
	return out if not out.is_empty() else "unit"
