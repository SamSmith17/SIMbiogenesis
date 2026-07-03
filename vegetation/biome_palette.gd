class_name BiomePalette
extends RefCounted

## Pure: maps (latitude, optional WorldCover class) to a species mix + scatter
## spacing + default canopy height, for biome-appropriate auto-vegetation.
##
## Latitude bands (abs degrees):
##   tropical      < 23°   palms / broadleaf tropical
##   subtropical   23–40°  mixed broadleaf, dry scrub
##   temperate     40–55°  mixed broadleaf + conifer
##   boreal        55°+    dense conifer, sparse taiga
## WorldCover class 20 (Shrubland) → low scrub regardless of latitude.
##
## Species ids are card-factory slots; Phase 1 uses the built-in
## pine / deciduous / shrub. Phase 3 adds palm / conifer / taiga slots here and
## AutoVegetationRuntime.SLOT_ALIAS resolves them until real meshes exist.

const TROPICAL_LIMIT := 23.0
const SUBTROPICAL_LIMIT := 40.0
const TEMPERATE_LIMIT := 55.0

## WorldCover class codes (used from Phase 4 on).
const WC_TREE := 10
const WC_SHRUB := 20

## OSM vegetation "kind" categories the player can bind to a specific tree/shrub
## shader type via the vegetation modal's OSM→species picker. [kind, label].
const MAPPABLE_KINDS := [
	["wood", "Woodland (wood / forest)"],
	["scrub", "Scrub / heath"],
	["park", "Park"],
	["cemetery", "Cemetery"],
	["orchard", "Orchard"],
	["vineyard", "Vineyard"],
	["wetland", "Wetland"],
]

## Options offered per kind in the picker (id, label). "auto" defers to biome/tags.
const SPECIES_OVERRIDE_OPTIONS := ["auto", "pine", "deciduous", "shrub", "mixed"]
const SPECIES_OVERRIDE_LABELS := [
	"Auto (biome)", "Pine", "Deciduous", "Shrub", "Mixed pine + deciduous",
]


## Resolve the user's OSM→species choice for a kind into a species-weight dict.
## Returns {} when the choice is "auto" (or unset) so callers keep biome defaults.
static func species_override_for_kind(osm_species_map: Dictionary, kind: String) -> Dictionary:
	if osm_species_map.is_empty():
		return {}
	match str(osm_species_map.get(kind, "auto")):
		"pine":
			return {"pine": 1.0}
		"deciduous":
			return {"deciduous": 1.0}
		"shrub":
			return {"shrub": 1.0}
		"mixed":
			return {"pine": 0.5, "deciduous": 0.5}
	return {}


## Dominant species from an override weight dict (for row crops), else `fallback`.
static func override_single_species(override: Dictionary, fallback: String) -> String:
	var best := fallback
	var best_w := -1.0
	for k in override:
		var w := maxf(float(override[k]), 0.0)
		if w > best_w:
			best_w = w
			best = str(k)
	return best


static func for_location(latitude: float, worldcover_class: int = -1) -> Dictionary:
	if worldcover_class == WC_SHRUB:
		return {"biome": "shrubland", "weights": {"shrub": 1.0},
			"spacing_m": 5.0, "default_height_m": 1.3}
	var lat := absf(latitude)
	if lat < TROPICAL_LIMIT:
		return {"biome": "tropical", "weights": {"palm": 0.45, "deciduous": 0.45, "shrub": 0.10},
			"spacing_m": 6.0, "default_height_m": 13.0}
	if lat < SUBTROPICAL_LIMIT:
		return {"biome": "subtropical", "weights": {"deciduous": 0.55, "shrub": 0.45},
			"spacing_m": 7.0, "default_height_m": 9.0}
	if lat < TEMPERATE_LIMIT:
		return {"biome": "temperate", "weights": {"deciduous": 0.45, "conifer": 0.45, "shrub": 0.10},
			"spacing_m": 6.0, "default_height_m": 14.0}
	return {"biome": "boreal", "weights": {"conifer": 0.85, "shrub": 0.15},
		"spacing_m": 5.0, "default_height_m": 13.0}


static func weights_for_osm_tags(base_weights: Dictionary, tags: Dictionary) -> Dictionary:
	var lt := str(tags.get("leaf_type", "")).to_lower()
	match lt:
		"needleleaved":
			return {"conifer": 1.0}
		"broadleaved":
			return {"deciduous": 1.0}
		"mixed":
			return {"deciduous": 0.5, "conifer": 0.5}
	var lc := str(tags.get("leaf_cycle", "")).to_lower()
	if lc == "evergreen" and lt.is_empty():
		return {"conifer": 0.85, "shrub": 0.15}
	if lc == "deciduous" and lt.is_empty():
		return {"deciduous": 0.85, "shrub": 0.15}
	return base_weights.duplicate(true)


static func pick_species(weights: Dictionary, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for k in weights:
		total += maxf(float(weights[k]), 0.0)
	if total <= 0.0:
		return "deciduous"
	var r := rng.randf() * total
	for k in weights:
		r -= maxf(float(weights[k]), 0.0)
		if r <= 0.0:
			return str(k)
	return str(weights.keys()[weights.size() - 1])
