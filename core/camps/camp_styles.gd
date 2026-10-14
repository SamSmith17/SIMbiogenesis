class_name CampStyles
extends RefCounted

## Data for the painted-camp layout: what a festival camp is MADE of.
##
## A camp is laid out as HOUSEHOLDS, not as individual props. People do not
## scatter one tent here and one car there — they arrive as a vehicle, pitch
## something beside it and park square to the neighbours. A household TEMPLATE
## is that unit: a handful of footprints in the household's own frame
## (`a` = metres along the camp heading, `c` = metres across it).
##
## A STYLE is a lattice cell size plus a weighted mix of templates. Every
## template of a style must FIT INSIDE that style's cell (the selftest asserts
## it), which is what guarantees two neighbouring households never collide and
## — more importantly — that enlarging a camp never disturbs what is already
## standing in it (CampLayoutGenerator's grow-stability property).
##
## Pure data, no engine state.

## Footprints: X = length (the long axis, which is what "aligned" aligns),
## Y = height, Z = width. Metres.
## Structures people SLEEP in, and how many each sleeps. The sleep need
## resolves a camp's sleep area to these (TerrainLoader.camp_shelters_in_
## polygon), so people lie down inside a tent, pod, van or RV rather than
## on the ground beside it.
const SHELTER_SLEEPS := {
	"rv": 4, "van": 2, "popup_tent": 2, "camping_tent": 2, "shift_pod": 2,
	"geodesic_dome": 4, "hexayurt": 3, "lotus_tent": 3,
}
## Structures a person cannot walk THROUGH (the nav grid blocks their
## footprint). Tents and pods are enterable — people sleep in them — and
## shade is walked under, so only the vehicles block.
const SOLID_CLASSES := {"rv": true, "van": true, "car": true}
## Structures people take SHADE (and cover from rain) under — NpcComfort's
## midday shade and a downpour's tarp.
const SHADE_CLASSES := {"shade_structure": true, "ez_up": true, "tarp": true, "shade_array": true}

const CLASS_SIZE := {
	"rv": Vector3(8.5, 3.0, 2.6),
	"van": Vector3(5.8, 2.6, 2.1),
	"car": Vector3(4.5, 1.5, 1.8),
	"shade_structure": Vector3(6.1, 3.0, 3.05),
	"ez_up": Vector3(3.05, 2.7, 3.05),
	"popup_tent": Vector3(3.05, 2.4, 3.05),
	"camping_tent": Vector3(2.6, 1.4, 2.1),
	"tarp": Vector3(4.5, 2.1, 3.5),
	"shade_array": Vector3(10.0, 0.12, 10.0),
	"geodesic_dome": Vector3(5.0, 2.6, 5.0),
	"shift_pod": Vector3(3.6, 2.2, 3.6),
	"hexayurt": Vector3(4.2, 2.8, 4.2),
	"lotus_tent": Vector3(5.0, 3.0, 5.0),
}

## How a class takes its yaw.
##   ALIGNED — parks square to the camp: heading (or heading + 180°, one choice
##             per ROW) plus a small uniform jitter. Vehicles and rigid shade.
##   LOOSE   — pitched roughly square, but by eye: ±25°.
##   FREE    — round or symmetric; any yaw.
const ALIGNED := 0
const LOOSE := 1
const FREE := 2

const CLASS_MODE := {
	"rv": ALIGNED, "van": ALIGNED, "car": ALIGNED,
	"shade_structure": ALIGNED, "shade_array": ALIGNED, "ez_up": ALIGNED,
	"tarp": ALIGNED,
	"popup_tent": LOOSE, "camping_tent": LOOSE, "shift_pod": LOOSE,
	"geodesic_dome": FREE, "hexayurt": FREE, "lotus_tent": FREE,
}

## Vehicles tilt with the ground they are parked on and refuse steep ground;
## everything else is pitched plumb and tolerates more.
const VEHICLES := {"rv": true, "van": true, "car": true}
const VEHICLE_MAX_SLOPE_DEG := 10.0
const TENT_MAX_SLOPE_DEG := 18.0
const LOOSE_JITTER_DEG := 25.0

## Household templates. Item keys: cls, a, c, optional p (chance the item is
## present, default 1) and rot (degrees off the household direction, default 0).
## The FIRST item is the anchor: if it cannot be placed, the household is not.
const TEMPLATES := {
	"rv_site": [
		{"cls": "rv", "a": 0.0, "c": 1.75},
		{"cls": "ez_up", "a": 2.1, "c": -1.75, "p": 0.75},
		{"cls": "car", "a": -2.5, "c": -1.6, "p": 0.6},
	],
	"van_site": [
		{"cls": "van", "a": 0.0, "c": 1.6},
		{"cls": "ez_up", "a": 1.4, "c": -1.6, "p": 0.6},
		{"cls": "camping_tent", "a": -2.3, "c": -1.5, "p": 0.55},
	],
	"car_tent": [
		{"cls": "car", "a": -2.1, "c": 1.5},
		{"cls": "camping_tent", "a": 2.3, "c": 1.7},
		{"cls": "ez_up", "a": 0.4, "c": -1.7, "p": 0.45},
		{"cls": "camping_tent", "a": -3.3, "c": -1.7, "p": 0.3},
	],
	"tent_cluster": [
		{"cls": "ez_up", "a": 0.0, "c": 0.0},
		{"cls": "camping_tent", "a": -3.5, "c": 1.5, "p": 0.8},
		{"cls": "camping_tent", "a": 3.5, "c": -1.5, "p": 0.8},
		{"cls": "camping_tent", "a": -3.5, "c": -1.6, "p": 0.6},
		{"cls": "camping_tent", "a": 3.5, "c": 1.6, "p": 0.6},
	],
	"popup_pair": [
		{"cls": "popup_tent", "a": -2.4, "c": 0.6},
		{"cls": "popup_tent", "a": 2.4, "c": -0.6, "p": 0.7},
	],
	"shade_site": [
		{"cls": "shade_structure", "a": 0.0, "c": 1.7},
		{"cls": "camping_tent", "a": -2.2, "c": -1.9, "p": 0.8},
		{"cls": "camping_tent", "a": 1.8, "c": -1.9, "p": 0.7},
	],
	"tarp_site": [
		{"cls": "tarp", "a": 0.0, "c": 1.6},
		{"cls": "camping_tent", "a": -2.2, "c": -2.1, "p": 0.85},
		{"cls": "camping_tent", "a": 1.8, "c": -2.1, "p": 0.7},
	],
	"theme_camp": [
		{"cls": "shade_array", "a": -3.9, "c": 0.0},
		{"cls": "geodesic_dome", "a": 6.0, "c": 2.9, "p": 0.7},
		{"cls": "hexayurt", "a": 6.0, "c": -3.3, "p": 0.6},
	],
	"theme_rv": [
		{"cls": "rv", "a": -2.0, "c": 3.6},
		{"cls": "shade_structure", "a": -2.6, "c": -0.4},
		{"cls": "rv", "a": -2.0, "c": -4.2, "p": 0.6},
		{"cls": "geodesic_dome", "a": 5.9, "c": 0.0, "p": 0.6},
	],
	"glamp_pair": [
		{"cls": "shift_pod", "a": -2.7, "c": 0.3},
		{"cls": "shift_pod", "a": 2.7, "c": -0.3, "p": 0.7},
	],
	"glamp_lotus": [
		{"cls": "lotus_tent", "a": 0.0, "c": 0.0},
	],
	"glamp_yurt": [
		{"cls": "hexayurt", "a": -2.2, "c": 0.0},
		{"cls": "ez_up", "a": 2.6, "c": 0.0, "p": 0.6},
	],
}

## How many people each household template SLEEPS — the placement tool's
## headcount source (FestivalAssigner.people_per_m2). One line each:
##   rv_site      3  an RV sleeps 2–4
##   van_site     2  a van sleeps two
##   car_tent     2  a car and a tent or two
##   tent_cluster 4  four tents at 60–80 % presence round a canopy
##   popup_pair   2  one per pop-up
##   shade_site   3  a shade structure with two tents
##   tarp_site    3  same under a tarp
##   theme_camp   8  a 10 m shade array plus a dome and a yurt
##   theme_rv     6  two RVs and a dome
##   glamp_pair   2  one per shift pod
##   glamp_lotus  2  a bell tent sleeps two
##   glamp_yurt   2  a yurt sleeps two
const PEOPLE_PER_TEMPLATE := {
	"rv_site": 3, "van_site": 2, "car_tent": 2, "tent_cluster": 4, "popup_pair": 2,
	"shade_site": 3, "tarp_site": 3, "theme_camp": 8, "theme_rv": 6,
	"glamp_pair": 2, "glamp_lotus": 2, "glamp_yurt": 2,
}
## A player-added model ("m:<class>") as a household of one.
const PEOPLE_PER_MODEL_TEMPLATE := 2

## cell_u x cell_v: one household's lattice cell (along x across the heading).
## rows_per_block rows sit back-to-back, then a lane `lane_w` wide.
## fill: chance a cell holds a household at all.
const STYLES := {
	"mixed": {
		"label": "Mixed festival",
		"cell_u": 11.0, "cell_v": 8.2, "rows_per_block": 2, "lane_w": 5.0, "fill": 0.9,
		"templates": {"rv_site": 2.0, "van_site": 1.5, "car_tent": 3.0,
			"tent_cluster": 2.0, "shade_site": 1.2, "tarp_site": 1.2,
			"popup_pair": 1.0, "glamp_pair": 0.6},
	},
	"rv_park": {
		"label": "RV park",
		"cell_u": 11.0, "cell_v": 8.2, "rows_per_block": 2, "lane_w": 7.0, "fill": 0.94,
		"templates": {"rv_site": 6.0, "van_site": 2.0, "car_tent": 0.5},
	},
	"tent_village": {
		"label": "Tent village",
		"cell_u": 11.0, "cell_v": 8.1, "rows_per_block": 3, "lane_w": 3.5, "fill": 0.9,
		"templates": {"tent_cluster": 4.0, "popup_pair": 2.0, "shade_site": 1.2,
			"tarp_site": 1.5},
	},
	"car_camping": {
		"label": "Car camping",
		"cell_u": 10.4, "cell_v": 7.2, "rows_per_block": 2, "lane_w": 5.5, "fill": 0.92,
		"templates": {"car_tent": 6.0, "van_site": 2.0, "popup_pair": 0.8},
	},
	"theme_camp": {
		"label": "Theme camp",
		"cell_u": 20.0, "cell_v": 13.6, "rows_per_block": 1, "lane_w": 6.0, "fill": 0.9,
		"templates": {"theme_camp": 3.0, "theme_rv": 2.0},
	},
	"glamping": {
		"label": "Glamping",
		"cell_u": 11.0, "cell_v": 7.7, "rows_per_block": 2, "lane_w": 4.0, "fill": 0.85,
		"templates": {"glamp_pair": 3.0, "glamp_lotus": 2.0, "glamp_yurt": 2.0},
	},
}

## Order shown in the toolbar's style picker.
const STYLE_ORDER := ["mixed", "rv_park", "tent_village", "car_camping",
	"theme_camp", "glamping"]
const DEFAULT_STYLE := "mixed"
## Pseudo-style accepted by the Subdivide tool: each plot draws its own style.
const VARIED := "varied"
const VARIED_POOL := ["mixed", "mixed", "rv_park", "tent_village", "car_camping",
	"theme_camp", "glamping"]


## What each household is, in words (the Tune-look mix list).
const TEMPLATE_LABELS := {
	"rv_site": "RV + canopy + car",
	"van_site": "Van + canopy + tent",
	"car_tent": "Car + tents",
	"tent_cluster": "Tents round a canopy",
	"popup_pair": "Pop-up tents",
	"shade_site": "Shade structure + tents",
	"tarp_site": "Tarp + tents",
	"theme_camp": "Big shade + dome + yurt",
	"theme_rv": "RVs round a shade + dome",
	"glamp_pair": "Shift pods",
	"glamp_lotus": "Bell tent",
	"glamp_yurt": "Yurt + canopy",
}
## A household that is ONE player-added model is the template "m:<class_id>".
const MODEL_TEMPLATE_PREFIX := "m:"
## Spacing multiplier range for a tuned style.
const SPACING_MIN := 0.8
const SPACING_MAX := 2.5

# ---------------------------------------------------------------------------
# The USER layer. CampStyleStore owns the file and writes these two dicts; the
# tables above stay the shipped defaults. Kept here (not in the store) so the
# generator has ONE place to ask what a style or a class is.
#   _user_styles: style_id -> {fill, lane_w, rows_per_block, spacing,
#                              templates: {template_id: weight}}
#   _user_models: class_id -> {model_id, label, mode, size: Vector3, tris}
# ---------------------------------------------------------------------------
static var _user_styles: Dictionary = {}
static var _user_models: Dictionary = {}
static var _resolved: Dictionary = {}


static func set_user_layer(styles: Dictionary, models: Dictionary) -> void:
	_user_styles = styles
	_user_models = models
	_resolved.clear()


static func clear_user_layer() -> void:
	set_user_layer({}, {})


static func user_models() -> Dictionary:
	return _user_models


static func is_user_class(cls: String) -> bool:
	return _user_models.has(cls)


static func is_valid(style_id: String) -> bool:
	return STYLES.has(style_id)


## The shipped definition of a style, ignoring every user edit.
static func base_style(style_id: String) -> Dictionary:
	return STYLES.get(style_id, STYLES[DEFAULT_STYLE])


## Scalar keys a style ENTRY may set (plus `templates`: {template_id: weight}).
## An entry is a sparse edit; entries stack, later ones winning key by key.
##   spacing          multiplier on the shipped plot size
##   pos_jitter       0..1 — how far a household wanders inside its plot
##   loose_jitter_deg how far "pitched by eye" things turn off square
##   scale_var        0..2 — how much sizes vary (1 = as shipped)
const ENTRY_KEYS := ["fill", "lane_w", "rows_per_block", "spacing",
	"pos_jitter", "loose_jitter_deg", "scale_var"]
const ENTRY_DEFAULTS := {"spacing": 1.0, "pos_jitter": 1.0,
	"loose_jitter_deg": LOOSE_JITTER_DEG, "scale_var": 1.0}
## Size spread at scale_var 1 (the long-standing ranges).
const ALIGNED_SCALE_DEV := 0.04
const LOOSE_SCALE_DEV_DOWN := 0.12
const LOOSE_SCALE_DEV_UP := 0.08


## A style laid out from the shipped table plus a STACK of entries, applied in
## order. This is the one resolver; the stack is, weakest first:
##   global style edit  ->  the camp's LAYOUT (a named variant of the style)
##   ->  this map's edit for the style  ->  this one camp's own edit.
## The result's plot is GROWN to hold the largest household in the mix — which
## keeps "every template fits its cell" true when a 14 m bus joins the tent
## village, and with it no-overlap and "a camp never reshuffles when it grows".
static func resolve(style_id: String, layers: Array) -> Dictionary:
	var sid := style_id if STYLES.has(style_id) else DEFAULT_STYLE
	var base: Dictionary = STYLES[sid]
	var out := base.duplicate(true)
	for k in ENTRY_DEFAULTS.keys():
		out[k] = ENTRY_DEFAULTS[k]
	var mix: Dictionary = (base["templates"] as Dictionary).duplicate()
	for layer in layers:
		if not (layer is Dictionary):
			continue
		var e: Dictionary = layer
		for k in ENTRY_KEYS:
			if e.has(k):
				out[k] = e[k]
		for tid in (e.get("templates", {}) as Dictionary).keys():
			if template_exists(str(tid)):
				mix[str(tid)] = float(e["templates"][tid])
	out["fill"] = clampf(float(out["fill"]), 0.1, 1.0)
	out["lane_w"] = clampf(float(out["lane_w"]), 0.0, 20.0)
	out["rows_per_block"] = clampi(int(out["rows_per_block"]), 1, 6)
	out["spacing"] = clampf(float(out["spacing"]), SPACING_MIN, SPACING_MAX)
	out["pos_jitter"] = clampf(float(out["pos_jitter"]), 0.0, 1.0)
	out["loose_jitter_deg"] = clampf(float(out["loose_jitter_deg"]), 0.0, 90.0)
	out["scale_var"] = clampf(float(out["scale_var"]), 0.0, 2.0)
	for tid in mix.keys():
		if float(mix[tid]) <= 0.0 or not template_exists(str(tid)):
			mix.erase(tid)
	if mix.is_empty():
		mix = (base["templates"] as Dictionary).duplicate()  # a style is never empty
	out["templates"] = mix
	out["max_scale"] = 1.0 + LOOSE_SCALE_DEV_UP * float(out["scale_var"])
	var need := Vector2.ZERO
	for tid in mix.keys():
		var ext := template_half_extent(str(tid), 5.0, float(out["max_scale"]))
		need.x = maxf(need.x, ext.x * 2.0)
		need.y = maxf(need.y, ext.y * 2.0)
	out["cell_u"] = maxf(float(base["cell_u"]) * float(out["spacing"]), need.x)
	out["cell_v"] = maxf(float(base["cell_v"]) * float(out["spacing"]), need.y)
	return out


## The style with only the global edit applied (no layout, map or camp layer).
static func style(style_id: String) -> Dictionary:
	var sid := style_id if STYLES.has(style_id) else DEFAULT_STYLE
	if not _resolved.has(sid):
		_resolved[sid] = resolve(sid, [_user_styles.get(sid, {})])
	return _resolved[sid]


## The style ONE camp is laid out with: the full stack for that record.
## `map_styles` = this map's per-style edits (CampAreaLayer.map_styles).
static func style_for_area(area: Dictionary, map_styles: Dictionary = {}) -> Dictionary:
	var sid := str(area.get("style", DEFAULT_STYLE))
	if not STYLES.has(sid):
		sid = DEFAULT_STYLE
	return resolve(sid, [
		_user_styles.get(sid, {}),
		variant_entry(sid, str(area.get("variant", ""))),
		map_styles.get(sid, {}),
		area.get("style_override", {}),
	])


# ---------------------------------------------------------------------------
# Layouts ("variants"): several saved looks under ONE style, so that not every
# theme camp is the same theme camp. A new camp draws one by weight.
# ---------------------------------------------------------------------------

## [{id, name, weight, ...entry keys}] for a style ("" id = the style itself).
static func variants(style_id: String) -> Array:
	var v: Variant = (_user_styles.get(style_id, {}) as Dictionary).get("variants", [])
	return v if v is Array else []


static func variant_entry(style_id: String, variant_id: String) -> Dictionary:
	if variant_id.is_empty():
		return {}
	for v in variants(style_id):
		if v is Dictionary and str((v as Dictionary).get("id", "")) == variant_id:
			return v
	return {}


static func variant_name(style_id: String, variant_id: String) -> String:
	if variant_id.is_empty():
		return "Default"
	return str(variant_entry(style_id, variant_id).get("name", "Default"))


## Which layout a NEW camp of this style gets: a weighted draw seeded by the
## camp's own seed, so the same paint stroke always draws the same one.
## "" = the style's default look.
static func pick_variant(style_id: String, seed: int) -> String:
	var list := variants(style_id)
	if list.is_empty():
		return ""
	var default_w := maxf(float((_user_styles.get(style_id, {}) as Dictionary).get(
		"default_weight", 1.0)), 0.0)
	var total := default_w
	for v in list:
		total += maxf(float((v as Dictionary).get("weight", 1.0)), 0.0)
	if total <= 0.0:
		return ""
	var roll := float(hash(Vector2i(seed & 0x7fffffff, 90721)) & 0xffffff) / float(0x1000000) * total
	roll -= default_w
	if roll < 0.0:
		return ""
	for v in list:
		roll -= maxf(float((v as Dictionary).get("weight", 1.0)), 0.0)
		if roll < 0.0:
			return str((v as Dictionary).get("id", ""))
	return ""


static func label(style_id: String) -> String:
	if style_id == VARIED:
		return "Varied"
	return str(base_style(style_id).get("label", style_id))


static func template_exists(template_id: String) -> bool:
	if template_id.begins_with(MODEL_TEMPLATE_PREFIX):
		return _user_models.has(template_id.substr(MODEL_TEMPLATE_PREFIX.length()))
	return TEMPLATES.has(template_id)


## The footprints of one household. A player-added model is a household of one.
static func template_items(template_id: String) -> Array:
	if template_id.begins_with(MODEL_TEMPLATE_PREFIX):
		var cls := template_id.substr(MODEL_TEMPLATE_PREFIX.length())
		return [{"cls": cls, "a": 0.0, "c": 0.0}] if _user_models.has(cls) else []
	return TEMPLATES.get(template_id, [])


static func template_label(template_id: String) -> String:
	if template_id.begins_with(MODEL_TEMPLATE_PREFIX):
		var m: Dictionary = _user_models.get(template_id.substr(MODEL_TEMPLATE_PREFIX.length()), {})
		return str(m.get("label", template_id))
	return str(TEMPLATE_LABELS.get(template_id, template_id))


static func class_size(cls: String) -> Vector3:
	if _user_models.has(cls):
		return (_user_models[cls] as Dictionary).get("size", Vector3(3.0, 2.5, 3.0))
	return CLASS_SIZE.get(cls, Vector3(3.0, 2.5, 3.0))


static func class_mode(cls: String) -> int:
	if _user_models.has(cls):
		return clampi(int((_user_models[cls] as Dictionary).get("mode", FREE)), ALIGNED, FREE)
	return int(CLASS_MODE.get(cls, LOOSE))


static func is_vehicle(cls: String) -> bool:
	return VEHICLES.has(cls)


## Half extents (along, across) a template can reach from its own origin, with
## every item at its LARGEST scale and worst-case yaw. `jitter_deg` is the
## aligned-class jitter the camp is using.
static func template_half_extent(template_id: String, jitter_deg: float,
		max_scale: float = 1.08) -> Vector2:
	var ext := Vector2.ZERO
	for it: Dictionary in template_items(template_id):
		var half := item_swept_half(str(it["cls"]), jitter_deg, max_scale,
			float(it.get("rot", 0.0)))
		ext.x = maxf(ext.x, absf(float(it["a"])) + half.x)
		ext.y = maxf(ext.y, absf(float(it["c"])) + half.y)
	return ext


## Axis-aligned half extents (in the household frame) swept by one item over
## its whole yaw range.
static func item_swept_half(cls: String, jitter_deg: float, max_scale: float,
		rot_deg: float = 0.0) -> Vector2:
	var size := class_size(cls) * max_scale
	var hx := size.x * 0.5
	var hz := size.z * 0.5
	match class_mode(cls):
		ALIGNED:
			var worst := Vector2.ZERO
			for off: float in [-jitter_deg, 0.0, jitter_deg]:
				var a := deg_to_rad(rot_deg + off)
				worst.x = maxf(worst.x, hx * absf(cos(a)) + hz * absf(sin(a)))
				worst.y = maxf(worst.y, hx * absf(sin(a)) + hz * absf(cos(a)))
			return worst
		_:
			var r := Vector2(hx, hz).length()
			return Vector2(r, r)
