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
## Species ids are card-factory slots; named sub-species resolve via
## VegSpeciesCatalog / AutoVegetationRuntime.SLOT_ALIAS to mesh families.

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
	["farmland", "Farmland / crops"],
]

## Meadow/lawn/field polygons are intentionally NOT auto-scattered as 3D grass
## (ortho imagery already shows the landcover). Keep for tree-scatter veto only.
const SKIP_AUTO_SCATTER_KINDS := ["grass_lawn", "grass_field"]


static func should_auto_scatter(kind: String) -> bool:
	return not SKIP_AUTO_SCATTER_KINDS.has(kind)

## Options offered per kind in the picker (id, label). "auto" defers to biome/tags.
## Built once from catalog so OSM→species and local-mix stay in sync.
static var SPECIES_OVERRIDE_OPTIONS: Array[String] = []
static var SPECIES_OVERRIDE_LABELS: Array[String] = []


static func _ensure_override_lists() -> void:
	if not SPECIES_OVERRIDE_OPTIONS.is_empty():
		return
	SPECIES_OVERRIDE_OPTIONS = ["auto", "pine", "deciduous", "shrub", "mixed"]
	for id in VegSpeciesCatalog.all_selectable_ids():
		if id not in SPECIES_OVERRIDE_OPTIONS:
			SPECIES_OVERRIDE_OPTIONS.append(id)
	SPECIES_OVERRIDE_LABELS.clear()
	for id in SPECIES_OVERRIDE_OPTIONS:
		SPECIES_OVERRIDE_LABELS.append(VegSpeciesCatalog.label_for(id))


static func override_options() -> Array[String]:
	_ensure_override_lists()
	return SPECIES_OVERRIDE_OPTIONS


static func override_labels() -> Array[String]:
	_ensure_override_lists()
	return SPECIES_OVERRIDE_LABELS


## Resolve the user's OSM→species choice for a kind into a species-weight dict.
## Returns {} when the choice is "auto" (or unset) so callers keep biome defaults.
## `mix_weights` (from the Tune Look "Mixed woodland" type) customizes the "mixed"
## choice; empty falls back to an even pine/deciduous split.
static func species_override_for_kind(osm_species_map: Dictionary, kind: String,
		mix_weights: Dictionary = {}) -> Dictionary:
	if osm_species_map.is_empty():
		return {}
	var choice := str(osm_species_map.get(kind, "auto"))
	match choice:
		"auto":
			return {}
		"pine":
			return {"pine": 1.0}
		"deciduous":
			return {"deciduous": 1.0}
		"shrub":
			return {"shrub": 1.0}
		"mixed":
			return mix_weights.duplicate(true) if not mix_weights.is_empty() \
				else {"pine": 0.5, "deciduous": 0.5}
	# Named sub-species / crops — single-weight dict keyed by selectable id.
	if choice in VegSpeciesCatalog.MESH_FAMILY or choice in VegSpeciesCatalog.BASE_FAMILIES:
		return {choice: 1.0}
	return {}


## The player-tuned mixed-woodland composition (Tune Look "Mixed woodland" type),
## read from the style's mix_* weights plus optional local_mix dict of named
## sub-species. Zero-weight species are dropped; returns {} when empty so
## callers fall back to the even pine/deciduous default.
static func mix_weights_from_style(style: Dictionary) -> Dictionary:
	var out := {}
	for species in ["pine", "deciduous", "shrub"]:
		var w := maxf(float(style.get("mix_%s" % species, 0.0)), 0.0)
		if w > 0.0:
			out[species] = w
	var local: Variant = style.get("local_mix", {})
	if local is Dictionary:
		for k in local:
			var lw := maxf(float(local[k]), 0.0)
			if lw > 0.0:
				out[str(k)] = lw
	return out


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
			"spacing_m": 6.0, "default_height_m": 1.3}
	var lat := absf(latitude)
	if lat < TROPICAL_LIMIT:
		return {"biome": "tropical", "weights": {"palm": 0.45, "deciduous": 0.45, "shrub": 0.10},
			"spacing_m": 8.0, "default_height_m": 13.0}
	if lat < SUBTROPICAL_LIMIT:
		return {"biome": "subtropical", "weights": {"deciduous": 0.55, "shrub": 0.45},
			"spacing_m": 9.0, "default_height_m": 9.0}
	if lat < TEMPERATE_LIMIT:
		return {"biome": "temperate", "weights": {"deciduous": 0.45, "conifer": 0.45, "shrub": 0.10},
			"spacing_m": 8.0, "default_height_m": 14.0}
	return {"biome": "boreal", "weights": {"conifer": 0.85, "shrub": 0.15},
		"spacing_m": 7.0, "default_height_m": 13.0}


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
