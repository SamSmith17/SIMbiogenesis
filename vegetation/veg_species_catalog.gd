class_name VegSpeciesCatalog
extends RefCounted

## Named vegetation sub-species used by the card factory, OSM→species chooser,
## and local-mix weights. Each id maps to a mesh family (procedural builder) so
## players can select distinct species without unique artwork per variant.

## Phase 5: "palm" and "cactus" are REAL builder families now (dedicated
## procedural meshes in VegetationCardFactory), no longer aliased onto
## deciduous/shrub. BASE_FAMILIES stays the VegetationLayer slot list.
const BASE_FAMILIES: Array[String] = [
	"pine", "deciduous", "shrub", "grass_lawn", "grass_field",
]
const MESH_FAMILIES: Array[String] = [
	"pine", "deciduous", "shrub", "palm", "cactus", "grass_lawn", "grass_field",
]

## species_id → mesh family used by VegetationCardFactory builders.
## New ids belong in vegetation/species/species_catalog.json (the registry) —
## mesh_family() consults it before this legacy table.
const MESH_FAMILY := {
	# Conifers (pine builder)
	"spruce": "pine",
	"cedar": "pine",
	"fir": "pine",
	"redwood": "pine",
	"hemlock": "pine",
	"douglas_fir": "pine",
	"pine": "pine",
	"conifer": "pine",
	"taiga": "pine",
	# Deciduous (deciduous builder)
	"chestnut": "deciduous",
	"maple": "deciduous",
	"alder": "deciduous",
	"oak": "deciduous",
	"cottonwood": "deciduous",
	"aspen": "deciduous",
	"birch": "deciduous",
	"beech": "deciduous",
	"walnut": "deciduous",
	"apple": "deciduous",
	"pear": "deciduous",
	"orange": "deciduous",
	"avocado": "deciduous",
	"olive": "deciduous",
	"mango": "deciduous",
	"banana": "deciduous",
	"ficus": "deciduous",
	"acacia": "deciduous",
	"broadleaf": "deciduous",
	"deciduous": "deciduous",
	# Palms (palm builder — Phase 5)
	"palm": "palm",
	"coconut_palm": "palm",
	"date_palm": "palm",
	"fan_palm": "palm",
	"sword_fern": "palm",
	"bracken": "palm",
	# Desert (cactus builder — Phase 5)
	"cactus": "cactus",
	"saguaro": "cactus",
	"prickly_pear": "cactus",
	"joshua_tree": "cactus",
	# Shrub
	"scrub": "shrub",
	"shrub": "shrub",
	"blackberry": "shrub",
	"salal": "shrub",
	# Crops (field-grass builder — tall herbaceous stands)
	"corn": "grass_field",
	"wheat": "grass_field",
	"barley": "grass_field",
	"beans": "grass_field",
	"quinoa": "grass_field",
	"squash": "grass_field",
	"tomatoes": "grass_field",
	"potatoes": "grass_field",
	"brassicas": "grass_field",
	"lettuce": "grass_field",
	"grass_lawn": "grass_lawn",
	"grass_field": "grass_field",
}

const CONIFER_IDS: Array[String] = ["spruce", "cedar", "pine", "fir", "douglas_fir",
	"redwood", "hemlock"]
const DECIDUOUS_IDS: Array[String] = [
	"chestnut", "maple", "alder", "oak", "cottonwood", "aspen", "birch", "beech", "walnut",
	"apple", "pear", "orange", "avocado", "olive",
	"mango", "banana", "ficus", "acacia",
]
const PALM_IDS: Array[String] = ["palm", "coconut_palm", "date_palm", "fan_palm"]
const DESERT_IDS: Array[String] = ["cactus", "saguaro", "prickly_pear", "joshua_tree"]
## Forest-floor plants (under the Shrub button): the fern rides the palm
## builder, the bramble the shrub builder.
const UNDERSTORY_IDS: Array[String] = ["sword_fern", "bracken", "salal", "blackberry"]
const CROP_IDS: Array[String] = [
	"corn", "wheat", "barley", "beans", "quinoa", "squash",
	"tomatoes", "potatoes", "brassicas", "lettuce",
]

## Human labels for OSM / local-mix pickers (id → title).
const LABELS := {
	"auto": "Auto (biome)",
	"pine": "Pine",
	"deciduous": "Deciduous",
	"shrub": "Shrub",
	"mixed": "Mixed (local blend)",
	"spruce": "Spruce",
	"cedar": "Cedar",
	"fir": "Fir",
	"redwood": "Redwood",
	"hemlock": "Hemlock",
	"douglas_fir": "Douglas-fir",
	"bracken": "Bracken",
	"salal": "Salal",
	"alder": "Alder",
	"oak": "Oregon white oak",
	"sword_fern": "Sword fern",
	"blackberry": "Blackberry",
	"chestnut": "Chestnut",
	"maple": "Maple",
	"cottonwood": "Cottonwood",
	"aspen": "Aspen",
	"birch": "Birch",
	"beech": "Beech",
	"apple": "Apple",
	"pear": "Pear",
	"orange": "Orange",
	"avocado": "Avocado",
	"cactus": "Cactus",
	"joshua_tree": "Joshua tree",
	"corn": "Corn",
	"wheat": "Wheat",
	"barley": "Barley",
	"beans": "Beans",
	"quinoa": "Quinoa",
	"squash": "Squash",
	"tomatoes": "Tomatoes",
	"potatoes": "Potatoes",
	"brassicas": "Brassicas",
	"lettuce": "Lettuce",
}

## Default structural growth years (trees) or days (crops when flagged).
## Crops use growth_days via VegetationGrowth.growth_span_hours.
const DEFAULT_GROWTH_YEARS := {
	"pine": 20.0, "spruce": 25.0, "cedar": 30.0, "fir": 22.0, "redwood": 80.0,
	"hemlock": 28.0, "alder": 10.0, "oak": 40.0, "douglas_fir": 30.0,
	"deciduous": 12.0, "chestnut": 25.0, "maple": 18.0, "cottonwood": 15.0,
	"aspen": 12.0, "birch": 14.0, "beech": 40.0,
	"apple": 8.0, "pear": 8.0, "orange": 6.0, "avocado": 10.0,
	"shrub": 5.0, "cactus": 15.0, "joshua_tree": 40.0,
}

const DEFAULT_GROWTH_DAYS := {
	"corn": 100.0, "wheat": 120.0, "barley": 90.0, "beans": 75.0,
	"quinoa": 110.0, "squash": 90.0, "tomatoes": 80.0, "potatoes": 90.0,
	"brassicas": 70.0, "lettuce": 90.0,
}

## Years (or days for crops) after maturity before scale fades to senescent.
const DEFAULT_SENESCENCE := {
	"pine": 40.0, "spruce": 50.0, "cedar": 60.0, "fir": 45.0, "redwood": 200.0,
	"deciduous": 25.0, "chestnut": 40.0, "maple": 30.0, "cottonwood": 20.0,
	"aspen": 18.0, "birch": 20.0, "beech": 60.0,
	"apple": 30.0, "pear": 30.0, "orange": 25.0, "avocado": 35.0,
	"shrub": 8.0, "cactus": 30.0, "joshua_tree": 80.0,
	"corn": 20.0, "wheat": 25.0, "barley": 20.0, "beans": 15.0,
	"quinoa": 20.0, "squash": 20.0, "tomatoes": 15.0, "potatoes": 15.0,
	"brassicas": 15.0, "lettuce": 15.0,
}


static func mesh_family(species: String) -> String:
	if MESH_FAMILY.has(species):
		return str(MESH_FAMILY[species])
	if species in BASE_FAMILIES:
		return species
	# Registry-defined species (Phase 5): family comes from the JSON catalog.
	var reg_fam := VegSpeciesRegistry.family(species)
	if not reg_fam.is_empty() and reg_fam in MESH_FAMILIES:
		return reg_fam
	return "deciduous"


static func is_crop(species: String) -> bool:
	return species in CROP_IDS


static func is_tree_family(species: String) -> bool:
	var fam := mesh_family(species)
	return fam == "pine" or fam == "deciduous"


static func all_selectable_ids() -> Array[String]:
	var out: Array[String] = []
	out.append_array(CONIFER_IDS)
	out.append_array(DECIDUOUS_IDS)
	out.append_array(PALM_IDS)
	out.append_array(DESERT_IDS)
	out.append_array(CROP_IDS)
	# Any registry-only species (added via JSON without touching this file).
	for id in VegSpeciesRegistry.all_ids():
		if id not in out and id not in BASE_FAMILIES:
			out.append(id)
	return out


static func label_for(id: String) -> String:
	if LABELS.has(id):
		return str(LABELS[id])
	if VegSpeciesRegistry.has_species(id):
		return VegSpeciesRegistry.label(id)
	return id.capitalize()


## Flat dim key per family the SPECS geometry maps onto. Tree families use the
## v3 real-world dims (Vegetation Overhaul v2); the archetype id rides along as
## a non-numeric dim (ratio scaling below skips non-floats).
const _FAMILY_DIM_KEYS := {
	"pine": {"height_m": "height_m", "crown_width_m": "crown_m",
		"trunk_diameter_cm": "trunk_cm", "crown_base_pct": "crown_base_pct",
		"archetype": "archetype"},
	"deciduous": {"height_m": "height_m", "crown_width_m": "crown_m",
		"trunk_diameter_cm": "trunk_cm", "crown_base_pct": "crown_base_pct",
		"archetype": "archetype"},
	"shrub": {"card_w": "width", "card_h": "height"},
	"palm": {"card_w": "width", "card_h": "height", "trunk_w": "trunk_w"},
	"cactus": {"card_w": "width", "card_h": "height"},
	"grass_lawn": {"card_w": "width", "card_h": "height"},
	"grass_field": {"card_w": "width", "card_h": "height"},
}


## Side channel written by settings_with_variant: the pre-resolution value of
## every key it rewrote (RESOLVE_ABSENT = the key was not there), so a second
## resolution starts from the original dict.
const KEY_RESOLVE_RAW := "_resolve_raw"
const RESOLVE_ABSENT := "<absent>"

## ONE tree's own look (the V toolbar's Select → Tune look → "This tree"):
## unprefixed keys in the species-override form (height_m, albedo_tint, …),
## riding the record's card_settings. The STRONGEST layer: it beats the
## species override, user family edits and SPECS, and is never gated by the
## generic-family rule below — a tree the player tuned by hand looks exactly
## as tuned.
const KEY_INSTANCE_OVERRIDE := "_instance_over"


## Resolve the FLAT settings dict a builder sees for one species, with the
## Phase 2 precedence: per-species user override > user family edit > catalog
## SPECS variant > family default. The old version only filled ABSENT family
## keys — and the merged style always carries every family key, so a variant's
## SPECS dims/colors NEVER applied: spruce == cedar == fir, every deciduous
## variant byte-identical ("all subspecies are placeholders").
##
## User-edit provenance comes from the VegStyleStore side channels riding the
## settings dict: _user_family_keys (flat family keys the player explicitly
## set) and _species_overrides (unprefixed per-species values).
static func settings_with_variant(species: String, settings: Dictionary,
		specs: Dictionary) -> Dictionary:
	var family := mesh_family(species)
	var out := settings.duplicate(true)
	# IDEMPOTENT: a dict that was already resolved (the world resolves a batch
	# and the mesh builder resolves again; the preview resolved once) gets its
	# original values back first. Without this a family-wide size edit was
	# ratio-scaled twice in the world and once in Tune look — "what I see is
	# not what I get" (a 75 cm Pine-family trunk made a 400 cm Douglas-fir).
	var raw: Dictionary = {}
	if out.get(KEY_RESOLVE_RAW) is Dictionary:
		var prev: Dictionary = out[KEY_RESOLVE_RAW]
		for k in prev:
			if prev[k] is String and str(prev[k]) == RESOLVE_ABSENT:
				out.erase(k)
			else:
				out[k] = prev[k]
		out.erase(KEY_RESOLVE_RAW)
	# Every write below goes through put(), which remembers the value it
	# replaced (Dictionaries are shared by the lambda, so raw fills in place).
	var put := func(k: String, v: Variant) -> void:
		if not raw.has(k):
			raw[k] = out[k] if out.has(k) else RESOLVE_ABSENT
		out[k] = v
	var spec: Dictionary = specs.get(species, specs.get(family, {}))
	out["_variant_species"] = species
	var inst: Dictionary = out[KEY_INSTANCE_OVERRIDE] \
		if out.get(KEY_INSTANCE_OVERRIDE) is Dictionary else {}
	if spec.is_empty():
		_put_instance_keys(inst, family, out, put, [])
		out[KEY_RESOLVE_RAW] = raw
		return out
	var user_family: Array = out.get(VegStyleStore.KEY_USER_FAMILY, [])
	var overrides_all: Dictionary = out.get(VegStyleStore.KEY_SPECIES_OVERRIDES, {})
	var over: Dictionary = overrides_all.get(species, {}) if overrides_all.get(species) is Dictionary else {}
	var named_variant := species != family and specs.has(species)
	# A species-layer entry for the GENERIC family id ("Save as species default"
	# on plain Deciduous) is the WEAKEST user layer: it yields to any user
	# family edit — per-map tuning or a family-wide Apply. Un-gated it outranked
	# per-map family values forever ("my per-map tuning does nothing").
	# Exception: an entry THIS MAP wrote (Select → "All of these in this
	# world") is the player naming that species on this map, so it wins.
	var map_species: Array = out[VegStyleStore.KEY_MAP_SPECIES] \
		if out.get(VegStyleStore.KEY_MAP_SPECIES) is Array else []
	var generic_self := species == family and species not in map_species
	# Provenance out-channel: species-override values count as EXPLICIT user
	# edits downstream (the v3 macro system derives Advanced values unless the
	# player explicitly set them — see VegetationCardFactory._derived_or_user).
	var explicit_out: Array = (user_family as Array).duplicate()
	# Geometry dims.
	var dims: Dictionary = _FAMILY_DIM_KEYS.get(family, {})
	var fam_defaults: Dictionary = VegetationStyleConfig.defaults()
	for dim in dims:
		var flat_key := "%s_%s" % [family, dim]
		var spec_key := str(dims[dim])
		var is_string_dim: bool = spec.get(spec_key) is String \
			or over.get(dim) is String or out.get(flat_key) is String
		if over.has(dim) and not (generic_self and flat_key in user_family):
			put.call(flat_key, over[dim] if is_string_dim else float(over[dim]))
			if flat_key not in explicit_out:
				explicit_out.append(flat_key)
		elif named_variant and spec.has(spec_key):
			if is_string_dim:
				# Categorical dim (archetype): SPECS applies unless the player
				# picked one family-wide (no ratio concept for enums).
				if flat_key not in user_family:
					put.call(flat_key, spec[spec_key])
			else:
				var specs_val := float(spec[spec_key])
				if flat_key in user_family:
					# A user family edit SCALES every subspecies dim instead of
					# replacing it: "make deciduous trees taller" must not turn
					# birch, beech and chestnut into byte-identical clones —
					# which is exactly what any fully-tuned map did when family
					# edits flat-out beat SPECS ("all subspecies are
					# placeholders" back through the per-map door). Ratio over
					# the family DEFAULT, bounded so an extreme tune can't
					# explode a variant (0.15–8 also lifts the old 4× cap that
					# stopped players growing big subspecies pines).
					var base_val := float(fam_defaults.get(flat_key, 0.0))
					if absf(base_val) > 0.0001:
						var ratio := clampf(float(out.get(flat_key, base_val)) / base_val,
							0.15, 8.0)
						put.call(flat_key, specs_val * ratio)
					# else: keep the user's absolute value (no baseline).
				else:
					put.call(flat_key, specs_val)
		# else: keep the flat value (user family edit, or family default for
		# the generic family species itself).
	# Non-dim per-species overrides (fur/whorl fine keys, offsets, bark_tint …)
	# apply onto the family keys directly.
	for k in over:
		var key := str(k)
		if dims.has(key) or key == "albedo_tint" or key == "highlight_tint":
			continue
		var flat_over := "%s_%s" % [family, key]
		if generic_self and flat_over in user_family:
			continue
		put.call(flat_over, over[k])
		if flat_over not in explicit_out:
			explicit_out.append(flat_over)
	# The one tree's own look last: it beats everything above.
	_put_instance_keys(inst, family, out, put, explicit_out)
	put.call(VegStyleStore.KEY_USER_FAMILY, explicit_out)
	# Colors: same ladder. SPECS carry real per-variant palettes (birch/aspen
	# white bark, maple's orange highlight) that were previously unreachable.
	var family_albedo := "%s_albedo_tint" % family
	var family_hi := "%s_highlight_tint" % family
	var albedo_key := "%s_albedo_tint" % species
	var hi_key := "%s_highlight_tint" % species
	if inst.get("albedo_tint") is Color:
		put.call(family_albedo, inst["albedo_tint"])
	elif over.has("albedo_tint") and not (generic_self and family_albedo in user_family):
		put.call(family_albedo, over["albedo_tint"])
	elif out.has(albedo_key) and species != family:
		put.call(family_albedo, out[albedo_key])
	elif named_variant and spec.has("top") and family_albedo not in user_family:
		put.call(family_albedo, spec["top"])
	if inst.get("highlight_tint") is Color:
		put.call(family_hi, inst["highlight_tint"])
	elif over.has("highlight_tint") and not (generic_self and family_hi in user_family):
		put.call(family_hi, over["highlight_tint"])
	elif out.has(hi_key) and species != family:
		put.call(family_hi, out[hi_key])
	elif named_variant and spec.has("highlight") and family_hi not in user_family:
		put.call(family_hi, spec["highlight"])
	# Bark color (birch/aspen white trunks). bark_albedo_tint is not in
	# defaults(), so its presence means an explicit user/global choice — only
	# fill from SPECS when unset.
	if named_variant and spec.has("bark") and not out.has("bark_albedo_tint"):
		put.call("bark_albedo_tint", VegetationCardFactory.bark_paint_color(spec["bark"]))
	out[KEY_RESOLVE_RAW] = raw
	return out


## Write a per-tree override onto the family flat keys. Dims and every other
## key alike (no SPECS ratio: the values ARE this tree's numbers); albedo and
## highlight tints go through the colour ladder in the caller.
static func _put_instance_keys(inst: Dictionary, family: String, out: Dictionary,
		put: Callable, explicit_out: Array) -> void:
	if inst.is_empty():
		return
	var dims: Dictionary = _FAMILY_DIM_KEYS.get(family, {})
	for k in inst:
		var key := str(k)
		if key == "albedo_tint" or key == "highlight_tint" or key.begins_with("_"):
			continue
		var flat_key := "%s_%s" % [family, key]
		var v: Variant = inst[k]
		if dims.has(key) and (v is float or v is int):
			v = float(v)
		put.call(flat_key, v)
		if flat_key not in explicit_out:
			explicit_out.append(flat_key)


## Subspecies ids under a paint-dock family button (Pine / Decid / Shrub / grass).
## Palms ride the Decid button and cacti the Shrub button until the Phase 8
## dock redesign gives exotics their own picker.
static func subspecies_for_family(family: String) -> Array[String]:
	match family:
		"pine":
			return CONIFER_IDS.duplicate()
		"deciduous":
			var d: Array[String] = DECIDUOUS_IDS.duplicate()
			d.append("deciduous")
			d.append_array(PALM_IDS)
			return d
		"palm":
			return PALM_IDS.duplicate()
		"cactus":
			return DESERT_IDS.duplicate()
		"shrub":
			var s: Array[String] = ["shrub"]
			s.append_array(UNDERSTORY_IDS)
			s.append_array(DESERT_IDS)
			return s
		"grass_lawn":
			return ["grass_lawn"] as Array[String]
		"grass_field":
			var g: Array[String] = ["grass_field"]
			g.append_array(CROP_IDS)
			return g
		_:
			return [family] as Array[String]


## True when species can be painted / stored in the manual vegetation layer.
static func is_paintable(species: String) -> bool:
	return MESH_FAMILY.has(species) or species in BASE_FAMILIES \
		or VegSpeciesRegistry.has_species(species)
