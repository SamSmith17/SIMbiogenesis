class_name EditToolbarState
extends RefCounted

## Pure data model for the unified edit toolbar (terrain + vegetation tools).
##
## No scene dependencies — the toolbar UI renders FROM this and writes back
## through it, the same separation the veg dock's chip_specs() proved out, so a
## headless selftest can assert tool switching, per-tool parameter isolation and
## persistence without a renderer.
##
## The whole point of this model vs the old docks: parameters live PER TOOL.
## The terrain dock kept one global _radius_m/_strength/_hardness that every
## tool shared, so tuning Smooth stomped Raise. Here each tool owns a params
## dict seeded from its schema defaults, and switching tools switches dicts.

## Registry of every tool the toolbar offers. Fields:
##  id       - stable string key (config sections + dispatch switch on it)
##  section  - "terrain" | "veg" (strip grouping)
##  label    - button text
##  tooltip  - hover help
##  shapes   - allowed shape modes, first entry is the tool's natural default
##  params   - [{key, label, min, max, default, step}] rendered as options rows
const TOOLS: Array[Dictionary] = [
	{
		"id": "raise", "section": "terrain", "label": "Raise",
		"tooltip": "Soft brush: raise terrain (hold LMB)",
		"shapes": ["brush"],
		"params": [
			{"key": "radius_m", "label": "Size", "unit": "m", "min": 1.0, "max": 100.0, "default": 12.0, "step": 0.5},
			{"key": "strength", "label": "Strength", "min": 0.1, "max": 25.0, "default": 6.0, "step": 0.1},
			{"key": "hardness", "label": "Hardness", "min": 0.0, "max": 1.0, "default": 0.5, "step": 0.01},
		],
	},
	{
		"id": "lower", "section": "terrain", "label": "Lower",
		"tooltip": "Soft brush: lower terrain (hold LMB)",
		"shapes": ["brush"],
		"params": [
			{"key": "radius_m", "label": "Size", "unit": "m", "min": 1.0, "max": 100.0, "default": 12.0, "step": 0.5},
			{"key": "strength", "label": "Strength", "min": 0.1, "max": 25.0, "default": 6.0, "step": 0.1},
			{"key": "hardness", "label": "Hardness", "min": 0.0, "max": 1.0, "default": 0.5, "step": 0.01},
		],
	},
	{
		"id": "smooth", "section": "terrain", "label": "Smooth",
		"tooltip": "Soft brush: relax bumps and steps toward the local average",
		"shapes": ["brush"],
		"params": [
			{"key": "radius_m", "label": "Size", "unit": "m", "min": 1.0, "max": 100.0, "default": 16.0, "step": 0.5},
			{"key": "strength", "label": "Strength", "min": 0.1, "max": 25.0, "default": 8.0, "step": 0.1},
			{"key": "hardness", "label": "Hardness", "min": 0.0, "max": 1.0, "default": 0.35, "step": 0.01},
		],
	},
	{
		"id": "level", "section": "terrain", "label": "Level",
		"tooltip": "Brush: pull terrain toward the height under the first click.\nShapes: level a whole drawn region to one flat pad",
		"shapes": ["brush", "rect", "circle", "lasso", "polygon"],
		"params": [
			{"key": "radius_m", "label": "Size", "unit": "m", "min": 1.0, "max": 100.0, "default": 12.0, "step": 0.5},
			{"key": "strength", "label": "Strength", "min": 0.1, "max": 25.0, "default": 10.0, "step": 0.1},
			{"key": "hardness", "label": "Hardness", "min": 0.0, "max": 1.0, "default": 0.6, "step": 0.01},
		],
	},
	{
		"id": "ramp", "section": "terrain", "label": "Ramp",
		"tooltip": "Click the start, then the end — grades a straight ramp between them",
		"shapes": [],
		"params": [
			{"key": "width_m", "label": "Width", "unit": "m", "min": 1.0, "max": 60.0, "default": 12.0, "step": 0.5},
		],
	},
	{
		"id": "pond", "section": "terrain", "label": "Pond",
		"tooltip": "Draw an outline, carve a basin and seed a puddle",
		"shapes": ["lasso", "circle", "rect", "polygon"],
		"params": [
			{"key": "depth_m", "label": "Dig depth", "unit": "m", "min": 0.1, "max": 8.0, "default": 1.2, "step": 0.1},
		],
	},
	{
		"id": "rain", "section": "terrain", "label": "Rain",
		"tooltip": "Draw an area over a depression, then hold LMB to raise its water",
		"shapes": ["circle", "rect", "lasso", "polygon"],
		"params": [
			{"key": "rate_mps", "label": "Rate", "unit": "m/s", "min": 0.02, "max": 1.0, "default": 0.15, "step": 0.01},
		],
	},
	{
		"id": "drain", "section": "terrain", "label": "Drain",
		"tooltip": "Draw an area over water, then hold LMB to drain it",
		"shapes": ["circle", "rect", "lasso", "polygon"],
		"params": [
			{"key": "rate_mps", "label": "Rate", "unit": "m/s", "min": 0.02, "max": 1.0, "default": 0.15, "step": 0.01},
		],
	},
	{
		"id": "measure", "section": "terrain", "label": "Measure",
		"tooltip": "Click two points — distance, elevation delta and slope",
		"shapes": [],
		"params": [],
	},
	{
		"id": "veg_paint", "section": "veg", "label": "Paint",
		"tooltip": "Scatter plants of the active type (hold LMB, or drag a shape to fill it).\nA single click drops ONE plant.",
		"shapes": ["brush", "circle", "rect", "lasso", "polygon"],
		"params": [
			{"key": "radius_m", "label": "Size", "unit": "m", "min": 1.0, "max": 40.0, "default": 4.0, "step": 0.5},
			{"key": "density", "label": "Density", "unit": "×", "min": 0.25, "max": 3.0, "default": 1.0, "step": 0.05},
			{"key": "size_var", "label": "Size variation", "unit": "%", "min": 0.0, "max": 50.0, "default": 25.0, "step": 1.0},
			# Multiplies every painted plant's size (on top of the variation):
			# paint a stand of young trees, or old-growth giants.
			{"key": "scale", "label": "Plant scale", "unit": "×", "min": 0.25, "max": 3.0, "default": 1.0, "step": 0.05},
		],
	},
	{
		"id": "veg_place", "section": "veg", "label": "Place",
		"tooltip": "Place ONE hero tree (full 3D model) where you click",
		"shapes": [],
		"params": [
			{"key": "hero_scale", "label": "Scale", "unit": "×", "min": 0.3, "max": 3.0, "default": 1.0, "step": 0.05},
		],
	},
	{
		"id": "veg_clear", "section": "veg", "label": "Clear",
		"tooltip": "Erase painted plants under the brush / inside a dragged shape",
		"shapes": ["brush", "circle", "rect", "lasso", "polygon"],
		"params": [
			{"key": "radius_m", "label": "Size", "unit": "m", "min": 1.0, "max": 40.0, "default": 6.0, "step": 0.5},
		],
	},
	{
		"id": "veg_select", "section": "veg", "label": "Select",
		"tooltip": "Pick a single plant: Del deletes, [ ] resize, H promotes it to a hero model",
		"shapes": ["brush"],
		"params": [],
	},
	{
		"id": "camp_paint", "section": "camps", "label": "Camp",
		"tooltip": "Paint a camp: tents, shade and vehicles fill the area you brush or draw.\nPainting over a camp of the same style grows it; nothing already standing moves.",
		"shapes": ["brush", "circle", "rect", "lasso", "polygon"],
		"params": [
			{"key": "radius_m", "label": "Size", "unit": "m", "min": 3.0, "max": 60.0, "default": 12.0, "step": 0.5},
			{"key": "density", "label": "Density", "unit": "×", "min": 0.2, "max": 1.0, "default": 0.8, "step": 0.05},
			{"key": "heading_deg", "label": "Heading", "unit": "°", "auto_below": 0.0, "min": -1.0, "max": 179.0, "default": -1.0, "step": 1.0},
			{"key": "align_jitter_deg", "label": "Alignment ±", "unit": "°", "min": 0.0, "max": 30.0, "default": 5.0, "step": 0.5},
			{"key": "light_density", "label": "Lights", "unit": "×", "min": 0.0, "max": 2.0, "default": 1.0, "step": 0.05},
		],
	},
	{
		"id": "camp_erase", "section": "camps", "label": "Erase",
		"tooltip": "Remove camp ground under the brush / inside a drawn shape.\nCutting a camp in two leaves two camps.",
		"shapes": ["brush", "circle", "rect", "lasso", "polygon"],
		"params": [
			{"key": "radius_m", "label": "Size", "unit": "m", "min": 3.0, "max": 60.0, "default": 10.0, "step": 0.5},
		],
	},
	{
		"id": "camp_subdivide", "section": "camps", "label": "Plots",
		"tooltip": "Draw a zone: it is split into camp plots with access lanes between them.\nEach plot becomes its own camp you can restyle or delete.",
		"shapes": ["rect", "lasso", "polygon"],
		"params": [
			{"key": "plot_w_m", "label": "Plot width", "unit": "m", "min": 8.0, "max": 80.0, "default": 30.0, "step": 1.0},
			{"key": "plot_d_m", "label": "Plot depth", "unit": "m", "min": 8.0, "max": 80.0, "default": 22.0, "step": 1.0},
			{"key": "lane_w_m", "label": "Lane", "unit": "m", "min": 0.0, "max": 15.0, "default": 6.0, "step": 0.5},
			{"key": "heading_deg", "label": "Heading", "unit": "°", "auto_below": 0.0, "min": -1.0, "max": 179.0, "default": -1.0, "step": 1.0},
			{"key": "density", "label": "Density", "unit": "×", "min": 0.2, "max": 1.0, "default": 0.8, "step": 0.05},
		],
	},
	{
		"id": "camp_select", "section": "camps", "label": "Edit",
		"tooltip": "Click a camp to edit it: style, density, heading, name. Del deletes it.",
		"shapes": [],
		"params": [
			{"key": "density", "label": "Density", "unit": "×", "min": 0.2, "max": 1.0, "default": 0.8, "step": 0.05},
			{"key": "heading_deg", "label": "Heading", "unit": "°", "auto_below": 0.0, "min": -1.0, "max": 179.0, "default": -1.0, "step": 1.0},
			{"key": "align_jitter_deg", "label": "Alignment ±", "unit": "°", "min": 0.0, "max": 30.0, "default": 5.0, "step": 0.5},
			{"key": "light_density", "label": "Lights", "unit": "×", "min": 0.0, "max": 2.0, "default": 1.0, "step": 0.05},
		],
	},
	# --- PLACEMENT: festival roads, theme-camp zones, fair lots, assignment ---
	{
		"id": "fest_road", "section": "placement", "label": "Road",
		"tooltip": "Draw a festival road: click each bend, Enter to finish.\nZones front onto roads; lots are cut along them.",
		"shapes": ["path"],
		"params": [
			{"key": "width_m", "label": "Width", "unit": "m", "min": 3.0, "max": 20.0, "default": 8.0, "step": 0.5},
			{"key": "flatten", "label": "Flatten", "min": 0.0, "max": 1.0, "default": 0.0, "step": 1.0},
		],
	},
	{
		"id": "fest_zone", "section": "placement", "label": "Zone",
		"tooltip": "Draw a theme-camp allocation zone. It fronts the nearest festival road\nand is cut into lots of equal USABLE area (slope and obstacles count).",
		"shapes": ["rect", "lasso", "polygon"],
		"params": [
			{"key": "target_n", "label": "Lots", "auto_below": 0.5, "min": 0.0, "max": 200.0, "default": 0.0, "step": 1.0},
			{"key": "target_m2", "label": "Area per lot", "unit": "m²", "min": 100.0, "max": 5000.0, "default": 600.0, "step": 25.0},
			{"key": "depth_m", "label": "Depth", "unit": "m", "min": 8.0, "max": 80.0, "default": 25.0, "step": 1.0},
			{"key": "lane_w_m", "label": "Lane", "unit": "m", "min": 0.0, "max": 12.0, "default": 5.0, "step": 0.5},
			{"key": "lots_per_lane", "label": "Lots per lane", "min": 0.0, "max": 12.0, "default": 4.0, "step": 1.0},
			{"key": "front_min_m", "label": "Frontage min", "unit": "m", "min": 4.0, "max": 60.0, "default": 12.0, "step": 1.0},
			{"key": "front_max_m", "label": "Frontage max", "unit": "m", "min": 10.0, "max": 150.0, "default": 45.0, "step": 1.0},
			{"key": "slope_limit_deg", "label": "Max slope", "unit": "°", "min": 3.0, "max": 30.0, "default": 10.0, "step": 0.5},
			{"key": "density", "label": "Density", "unit": "×", "min": 0.2, "max": 1.0, "default": 0.8, "step": 0.05},
		],
	},
	{
		"id": "fest_lots", "section": "placement", "label": "Lots",
		"tooltip": "Click a zone to cut (or re-cut) it into lots with its current settings.",
		"shapes": [],
		"params": [],
	},
	{
		"id": "fest_assign", "section": "placement", "label": "Assign",
		"tooltip": "Pick a camp from the roster, then click a lot to give it that lot.\nAuto-assign places the whole roster largest-first, best-fit.",
		"shapes": [],
		"params": [],
	},
	{
		"id": "fest_edit", "section": "placement", "label": "Edit",
		"tooltip": "Click a road, zone or lot to edit it. Del deletes a road or zone.",
		"shapes": [],
		"params": [
			{"key": "width_m", "label": "Width", "unit": "m", "min": 3.0, "max": 20.0, "default": 8.0, "step": 0.5},
			{"key": "headcount", "label": "People", "min": 0.0, "max": 500.0, "default": 0.0, "step": 1.0},
		],
	},
	# --- WATER: streams, culverts, the drainage network (WaterNetwork) ---
	{
		"id": "water_trace", "section": "water", "label": "Trace",
		"tooltip": "Click anywhere: the path water takes downhill from there becomes a stream,\nending where it joins another.",
		"shapes": [],
		"params": [],
	},
	{
		"id": "water_draw", "section": "water", "label": "Draw",
		"tooltip": "Click waypoints, Enter or double-click to finish.\nDrawn uphill? It is reversed so it runs downstream.",
		"shapes": [],
		"params": [],
	},
	{
		"id": "water_edit", "section": "water", "label": "Edit",
		"tooltip": "Click a stream (mapped, yours, or a drainage line). Drag waypoints,\ndrag the line to add one, Del removes one, Ctrl-drag moves it all.",
		"shapes": [],
		"params": [],
	},
	{
		"id": "water_span", "section": "water", "label": "Culvert",
		"tooltip": "Click a span between two waypoints to make it open channel,\nculvert or pipe.",
		"shapes": [],
		"params": [],
	},
	{
		"id": "water_view", "section": "water", "label": "View",
		"tooltip": "Water display, the drainage network, carving and re-carving.",
		"shapes": [],
		"params": [],
	},
]

## Placement chip vocabularies. LITERAL copies of FestivalPlacementLayer's
## tables (stale-class-cache rule, same as VEG_FAMILIES / CAMP_STYLES);
## toolbar_selftest asserts they still match.
const PLACEMENT_SURFACES: Array[String] = ["dirt", "gravel", "playa", "paved", "grass"]
const PLACEMENT_FEATURES: Array[String] = ["power", "water", "quiet", "loud", "shade"]

## Vegetation families offered by the veg tools. `preset` mirrors
## VegetationPaint.Preset and is written as a LITERAL int so this model still
## loads with a stale global class cache; toolbar_selftest asserts the numbers
## still match the enum.
const VEG_FAMILIES: Array[Dictionary] = [
	{"id": "pine", "label": "Pine", "preset": 0},
	{"id": "deciduous", "label": "Broadleaf", "preset": 1},
	{"id": "shrub", "label": "Shrub", "preset": 2},
	{"id": "mix", "label": "Mix", "preset": 3},
	{"id": "grass_lawn", "label": "Lawn", "preset": 4},
	{"id": "grass_field", "label": "Field", "preset": 5},
]

## Camp styles offered by the camp tools. LITERAL ids for the same reason as
## VEG_FAMILIES (the model must load with a stale class cache); toolbar_selftest
## asserts they still match CampStyles. "varied" is the Plots tool's
## one-style-per-plot option; the paint tool reads it as "mixed".
const CAMP_STYLES: Array[Dictionary] = [
	{"id": "mixed", "label": "Mixed"},
	{"id": "rv_park", "label": "RVs"},
	{"id": "tent_village", "label": "Tents"},
	{"id": "car_camping", "label": "Cars"},
	{"id": "theme_camp", "label": "Theme"},
	{"id": "glamping", "label": "Glamp"},
	{"id": "varied", "label": "Varied"},
]

## Tools whose UI/dispatch has not shipped yet render disabled in the strip.
## Empty now that the shape-region tools have landed; kept as the mechanism for
## staging the vegetation section in.
const PENDING_TOOLS: Array[String] = []

var active_tool: String = "raise"
## tool_id -> {param_key: float}, seeded from schema defaults.
var _params: Dictionary = {}
## tool_id -> shape mode string (per-tool memory, like the params).
var _shapes: Dictionary = {}
## Vegetation brush identity. Shared by every veg tool rather than stored per
## tool: "what am I painting" is one decision, and Clear/Select do not carry a
## species at all, so a per-tool copy would only be a way for them to disagree.
var veg_family: String = "shrub"
var veg_species: String = "shrub"
var hero_preset: String = "pine_1"
## The Mix family's mix: "map" = this map's own mix (TerrainLoader.get_paint_mix),
## else a VegMix preset / saved-mix id.
var veg_mix_id: String = "map"
## Camp brush identity, shared by every camp tool for the same reason.
var camp_style: String = "mixed"
## Placement identity, shared by the placement tools: the styles a new zone
## allows (first = default), its features, the road surface, how to equalise
## lots, and whether a drawn zone is cut at once.
var placement_styles: Array = ["mixed"]
var placement_features: Array = []
var placement_surface: String = "gravel"
var placement_equalise: String = "usable"
var placement_subdivide_now: bool = true


func _init() -> void:
	for t in TOOLS:
		var d := {}
		for p in (t["params"] as Array):
			d[(p as Dictionary)["key"]] = float((p as Dictionary)["default"])
		_params[t["id"]] = d
		var shapes: Array = t["shapes"]
		_shapes[t["id"]] = String(shapes[0]) if not shapes.is_empty() else ""


func tool_def(tool_id: String) -> Dictionary:
	for t in TOOLS:
		if String(t["id"]) == tool_id:
			return t
	return {}


func tools_in_section(section: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t in TOOLS:
		if String(t["section"]) == section:
			out.append(t)
	return out


func set_active_tool(tool_id: String) -> bool:
	if tool_def(tool_id).is_empty():
		return false
	active_tool = tool_id
	return true


func get_param(key: String, default_v: float = 0.0) -> float:
	return float((_params.get(active_tool, {}) as Dictionary).get(key, default_v))


func set_param(key: String, value: float) -> void:
	set_tool_param(active_tool, key, value)


func set_tool_param(tool_id: String, key: String, value: float) -> void:
	var def := tool_def(tool_id)
	if def.is_empty():
		return
	for p in (def["params"] as Array):
		var pd := p as Dictionary
		if String(pd["key"]) == key:
			var d: Dictionary = _params[tool_id]
			d[key] = clampf(value, float(pd["min"]), float(pd["max"]))
			return


## Copy of a tool's current params — callers cannot mutate the store directly.
func params_for(tool_id: String) -> Dictionary:
	return (_params.get(tool_id, {}) as Dictionary).duplicate()


func shape_for(tool_id: String) -> String:
	return String(_shapes.get(tool_id, ""))


func set_shape(tool_id: String, shape: String) -> bool:
	var def := tool_def(tool_id)
	if def.is_empty() or not (def["shapes"] as Array).has(shape):
		return false
	_shapes[tool_id] = shape
	return true


# ---------------------------------------------------------------------------
# Vegetation brush identity
# ---------------------------------------------------------------------------

func veg_family_def(family_id: String) -> Dictionary:
	for f in VEG_FAMILIES:
		if String(f["id"]) == family_id:
			return f
	return {}


## VegetationPaint.Preset value for the active family — what the loader's
## scatter parameters are keyed on.
func veg_preset_index() -> int:
	var f := veg_family_def(veg_family)
	return int(f.get("preset", 2))


func is_mix_family() -> bool:
	return veg_family == "mix"


## Reset the subspecies only when the family actually CHANGES. Membership is
## the species CATALOG's business, not something this model can infer from the
## id — "spruce" is a pine and "oak" is a deciduous, so a name-prefix test
## wrongly clears a valid subspecies every time its own family is re-selected.
## On a real change we drop to the family's generic id and let the UI's
## subspecies refresh narrow it against the catalog.
func set_veg_family(family_id: String) -> bool:
	if veg_family_def(family_id).is_empty():
		return false
	var changed := veg_family != family_id
	veg_family = family_id
	# MIX has no single species — the scatter picks one per instance.
	if family_id == "mix":
		veg_species = ""
	elif changed:
		veg_species = family_id
	return true


func set_veg_species(species_id: String) -> void:
	veg_species = species_id


# ---------------------------------------------------------------------------
# Camp brush identity
# ---------------------------------------------------------------------------

func camp_style_def(style_id: String) -> Dictionary:
	for s in CAMP_STYLES:
		if String(s["id"]) == style_id:
			return s
	return {}


func set_camp_style(style_id: String) -> bool:
	if camp_style_def(style_id).is_empty():
		return false
	camp_style = style_id
	return true


## The style a tool actually applies. "varied" only means something to the
## Plots tool; anywhere else it paints the mixed camp.
func camp_style_for_tool(tool_id: String = "") -> String:
	var id := tool_id if not tool_id.is_empty() else active_tool
	if camp_style == "varied" and id != "camp_subdivide":
		return "mixed"
	return camp_style


# ---------------------------------------------------------------------------
# Placement identity
# ---------------------------------------------------------------------------

## Toggle a style in the zone's allowed mix. The mix never empties: refusing
## to clear the last one keeps "first entry = default style" well defined.
func toggle_placement_style(style_id: String) -> bool:
	if camp_style_def(style_id).is_empty() or style_id == "varied":
		return false
	if placement_styles.has(style_id):
		if placement_styles.size() <= 1:
			return false
		placement_styles.erase(style_id)
	else:
		placement_styles.append(style_id)
	return true


func toggle_placement_feature(feature: String) -> bool:
	if not PLACEMENT_FEATURES.has(feature):
		return false
	if placement_features.has(feature):
		placement_features.erase(feature)
	else:
		placement_features.append(feature)
	return true


func set_placement_surface(surface: String) -> bool:
	if not PLACEMENT_SURFACES.has(surface):
		return false
	placement_surface = surface
	return true


func set_placement_equalise(mode: String) -> bool:
	if mode != "usable" and mode != "raw":
		return false
	placement_equalise = mode
	return true


## The zone spec the Zone tool's rows + chips currently describe.
func placement_zone_spec() -> Dictionary:
	var n := int(round(get_tool_param_value("fest_zone", "target_n")))
	return {
		"mode": "count" if n > 0 else "area",
		"target_n": maxi(n, 1),
		"target_m2": get_tool_param_value("fest_zone", "target_m2"),
		"depth_m": get_tool_param_value("fest_zone", "depth_m"),
		"lane_w_m": get_tool_param_value("fest_zone", "lane_w_m"),
		"lots_per_lane": int(round(get_tool_param_value("fest_zone", "lots_per_lane"))),
		"front_min_m": get_tool_param_value("fest_zone", "front_min_m"),
		"front_max_m": get_tool_param_value("fest_zone", "front_max_m"),
		"slope_limit_deg": get_tool_param_value("fest_zone", "slope_limit_deg"),
		"density": get_tool_param_value("fest_zone", "density"),
		"equalise": placement_equalise,
		"styles": placement_styles.duplicate(),
	}


func get_tool_param_value(tool_id: String, key: String) -> float:
	var vals: Dictionary = _params.get(tool_id, {})
	if vals.has(key):
		return float(vals[key])
	for p in (tool_def(tool_id).get("params", []) as Array):
		if String((p as Dictionary)["key"]) == key:
			return float((p as Dictionary)["default"])
	return 0.0


## 0..0.5 size-variance fraction from the 0..50 percent slider.
func size_var_fraction() -> float:
	return clampf(get_param("size_var", 25.0) / 100.0, 0.0, 0.5)


## Row model the options bar renders from: one entry per parameter of the tool,
## carrying its schema AND current value. Pure data, assertable headless.
func option_specs(tool_id: String = "") -> Array[Dictionary]:
	var id := tool_id if not tool_id.is_empty() else active_tool
	var def := tool_def(id)
	var out: Array[Dictionary] = []
	if def.is_empty():
		return out
	var vals: Dictionary = _params.get(id, {})
	for p in (def["params"] as Array):
		var pd := p as Dictionary
		out.append({
			"key": String(pd["key"]),
			"label": String(pd["label"]),
			"min": float(pd["min"]),
			"max": float(pd["max"]),
			"step": float(pd["step"]),
			"value": float(vals.get(pd["key"], pd["default"])),
			"unit": String(pd.get("unit", "")),
			"auto_below": float(pd.get("auto_below", NAN)),
		})
	return out


# ---------------------------------------------------------------------------
# Persistence (Phase 4 wires the file I/O; the codec lives here so the selftest
# can round-trip it without touching user://).
# ---------------------------------------------------------------------------

## Where the player's per-tool settings live. save_to/load_from take a path so
## the selftest can round-trip a temp file instead of the real prefs.
const PREFS_PATH := "user://toolbar_prefs.cfg"


func save_to(path: String = PREFS_PATH) -> Error:
	var cfg := ConfigFile.new()
	to_config(cfg)
	return cfg.save(path)


## Missing or unreadable file leaves every schema default in place — a fresh
## install and a corrupt file behave the same, which is the point.
func load_from(path: String = PREFS_PATH) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return false
	from_config(cfg)
	return true


func to_config(cfg: ConfigFile) -> void:
	cfg.set_value("toolbar", "active_tool", active_tool)
	cfg.set_value("toolbar", "veg_family", veg_family)
	cfg.set_value("toolbar", "veg_species", veg_species)
	cfg.set_value("toolbar", "hero_preset", hero_preset)
	cfg.set_value("toolbar", "veg_mix_id", veg_mix_id)
	cfg.set_value("toolbar", "camp_style", camp_style)
	cfg.set_value("toolbar", "placement_styles", placement_styles.duplicate())
	cfg.set_value("toolbar", "placement_features", placement_features.duplicate())
	cfg.set_value("toolbar", "placement_surface", placement_surface)
	cfg.set_value("toolbar", "placement_equalise", placement_equalise)
	cfg.set_value("toolbar", "placement_subdivide_now", placement_subdivide_now)
	for t in TOOLS:
		var id := String(t["id"])
		var section := "tool_%s" % id
		var vals: Dictionary = _params[id]
		for k in vals.keys():
			cfg.set_value(section, String(k), float(vals[k]))
		if not String(_shapes.get(id, "")).is_empty():
			cfg.set_value(section, "shape", String(_shapes[id]))


## Unknown tools/keys in the file are ignored; missing keys keep their schema
## defaults — a config from an older or newer build never breaks the model.
func from_config(cfg: ConfigFile) -> void:
	var at := String(cfg.get_value("toolbar", "active_tool", active_tool))
	if not tool_def(at).is_empty():
		active_tool = at
	var fam := String(cfg.get_value("toolbar", "veg_family", veg_family))
	if not veg_family_def(fam).is_empty():
		veg_family = fam
		veg_species = String(cfg.get_value("toolbar", "veg_species", veg_species))
	hero_preset = String(cfg.get_value("toolbar", "hero_preset", hero_preset))
	veg_mix_id = String(cfg.get_value("toolbar", "veg_mix_id", veg_mix_id))
	set_camp_style(String(cfg.get_value("toolbar", "camp_style", camp_style)))
	var ps: Variant = cfg.get_value("toolbar", "placement_styles", placement_styles)
	if ps is Array:
		var clean: Array = []
		for s in ps:
			if not camp_style_def(String(s)).is_empty() and String(s) != "varied" \
					and not clean.has(String(s)):
				clean.append(String(s))
		if not clean.is_empty():
			placement_styles = clean
	var pf: Variant = cfg.get_value("toolbar", "placement_features", placement_features)
	if pf is Array:
		placement_features = []
		for f in pf:
			if PLACEMENT_FEATURES.has(String(f)) and not placement_features.has(String(f)):
				placement_features.append(String(f))
	set_placement_surface(String(cfg.get_value("toolbar", "placement_surface", placement_surface)))
	set_placement_equalise(String(cfg.get_value("toolbar", "placement_equalise", placement_equalise)))
	placement_subdivide_now = bool(cfg.get_value("toolbar", "placement_subdivide_now", placement_subdivide_now))
	for t in TOOLS:
		var id := String(t["id"])
		var section := "tool_%s" % id
		if not cfg.has_section(section):
			continue
		for p in (t["params"] as Array):
			var key := String((p as Dictionary)["key"])
			if cfg.has_section_key(section, key):
				set_tool_param(id, key, float(cfg.get_value(section, key)))
		if cfg.has_section_key(section, "shape"):
			set_shape(id, String(cfg.get_value(section, "shape")))
