class_name VegSpeciesCatalog
extends RefCounted

## Named vegetation sub-species used by the card factory, OSM→species chooser,
## and local-mix weights. Each id maps to a mesh family (procedural builder) so
## players can select distinct species without unique artwork per variant.

const BASE_FAMILIES: Array[String] = [
	"pine", "deciduous", "shrub", "grass_lawn", "grass_field",
]

## species_id → mesh family used by VegetationCardFactory builders.
const MESH_FAMILY := {
	# Conifers (pine builder)
	"spruce": "pine",
	"cedar": "pine",
	"fir": "pine",
	"redwood": "pine",
	"pine": "pine",
	"conifer": "pine",
	"taiga": "pine",
	# Deciduous (deciduous builder)
	"chestnut": "deciduous",
	"maple": "deciduous",
	"cottonwood": "deciduous",
	"aspen": "deciduous",
	"birch": "deciduous",
	"beech": "deciduous",
	"apple": "deciduous",
	"pear": "deciduous",
	"orange": "deciduous",
	"avocado": "deciduous",
	"palm": "deciduous",
	"broadleaf": "deciduous",
	"deciduous": "deciduous",
	# Desert / shrub
	"cactus": "shrub",
	"joshua_tree": "shrub",
	"scrub": "shrub",
	"shrub": "shrub",
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

const CONIFER_IDS: Array[String] = ["spruce", "cedar", "pine", "fir", "redwood"]
const DECIDUOUS_IDS: Array[String] = [
	"chestnut", "maple", "cottonwood", "aspen", "birch", "beech",
	"apple", "pear", "orange", "avocado",
]
const DESERT_IDS: Array[String] = ["cactus", "joshua_tree"]
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
	out.append_array(DESERT_IDS)
	out.append_array(CROP_IDS)
	return out


static func label_for(id: String) -> String:
	return str(LABELS.get(id, id.capitalize()))


## Overlay variant SPECS dims into family settings keys so builders pick them up.
static func settings_with_variant(species: String, settings: Dictionary,
		specs: Dictionary) -> Dictionary:
	var family := mesh_family(species)
	var out := settings.duplicate(true)
	var spec: Dictionary = specs.get(species, specs.get(family, {}))
	if spec.is_empty():
		return out
	match family:
		"pine":
			if spec.has("width"):
				out["pine_card_w"] = float(spec["width"])
			if spec.has("height"):
				out["pine_card_h"] = float(spec["height"])
			if spec.has("trunk_w"):
				out["pine_trunk_w"] = float(spec["trunk_w"])
		"deciduous":
			if spec.has("width"):
				out["deciduous_canopy_w"] = float(spec["width"])
			if spec.has("height"):
				out["deciduous_canopy_h"] = float(spec["height"])
			if spec.has("trunk_w"):
				out["deciduous_trunk_w"] = float(spec["trunk_w"])
			if spec.has("trunk_h"):
				out["deciduous_trunk_h"] = float(spec["trunk_h"])
		"shrub":
			if spec.has("width"):
				out["shrub_card_w"] = float(spec["width"])
			if spec.has("height"):
				out["shrub_card_h"] = float(spec["height"])
		"grass_field", "grass_lawn":
			var prefix := family
			if spec.has("width"):
				out["%s_card_w" % prefix] = float(spec["width"])
			if spec.has("height"):
				out["%s_card_h" % prefix] = float(spec["height"])
	# Tint overrides from SPECS colors when player hasn't set custom tints.
	if spec.has("top") and not out.has("%s_albedo_tint" % family):
		out["%s_spec_top" % family] = spec["top"]
	if spec.has("highlight") and not out.has("%s_highlight_tint" % family):
		out["%s_spec_highlight" % family] = spec["highlight"]
	out["_variant_species"] = species
	return out
