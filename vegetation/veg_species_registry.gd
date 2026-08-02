class_name VegSpeciesRegistry
extends RefCounted

## Data-driven species registry (veg overhaul Phase 5) — the authority for
## per-species DATA: builder family, phenology profile, climate envelope,
## growth/senescence spans, and food yields (Phase 10 consumes those).
## `VegSpeciesCatalog` remains the code facade every call site uses; it
## consults this registry first and falls back to its legacy constants, so
## adding a species is now a JSON edit, not a five-file code change.
##
## Phenology drives seasonal response (VegetationEnvironmentSync): a palm at
## deciduousness 1.0 used to drop its fronds every winter — the profile is
## what makes tropical evergreens actually evergreen (user goals 4 + 5).

const CATALOG_PATH := "res://vegetation/species/species_catalog.json"
## Optional textured-card upgrade: dropping <id>.png in either location swaps
## that species to photo-textured crossed cards (checked in this order).
const PHOTOCARD_RES_DIR := "res://assets/vegetation/photocards"
const PHOTOCARD_USER_DIR := "user://veg_photocards"

## phenology profile -> deciduousness pushed to the seasonal shaders.
const PHENOLOGY_DECIDUOUSNESS := {
	"conifer": 0.0,
	"evergreen": 0.05,
	"tropical_evergreen": 0.0,
	"semi_deciduous": 0.55,
	"deciduous": 1.0,
}

static var _data: Dictionary = {}
static var _loaded := false
static var _photocard_cache: Dictionary = {}


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_data = {}
	if not FileAccess.file_exists(CATALOG_PATH):
		push_warning("VegSpeciesRegistry: %s missing — registry empty" % CATALOG_PATH)
		return
	var f := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary and (parsed as Dictionary).get("species") is Dictionary:
		_data = (parsed as Dictionary)["species"]
	else:
		push_warning("VegSpeciesRegistry: %s failed to parse" % CATALOG_PATH)


## Test hook / hot-reload.
static func reset() -> void:
	_loaded = false
	_photocard_cache.clear()


static func has_species(id: String) -> bool:
	_load()
	return _data.has(id)


static func all_ids() -> Array[String]:
	_load()
	var out: Array[String] = []
	for k in _data:
		out.append(str(k))
	out.sort()
	return out


static func entry(id: String) -> Dictionary:
	_load()
	var raw: Variant = _data.get(id, {})
	return raw as Dictionary if raw is Dictionary else {}


static func label(id: String) -> String:
	return str(entry(id).get("label", id.capitalize()))


static func family(id: String) -> String:
	return str(entry(id).get("family", ""))


static func phenology(id: String) -> String:
	return str(entry(id).get("phenology", ""))


## Seasonal deciduousness for the shader uniform, or -1.0 when the registry
## has no opinion (caller falls back to its legacy heuristic).
static func deciduousness(id: String) -> float:
	var p := phenology(id)
	if p.is_empty():
		return -1.0
	return float(PHENOLOGY_DECIDUOUSNESS.get(p, -1.0))


static func growth_years(id: String, fallback: float = 0.0) -> float:
	return float(entry(id).get("growth_years", fallback))


static func senescence_years(id: String, fallback: float = 0.0) -> float:
	return float(entry(id).get("senescence_years", fallback))


static func climate(id: String) -> Dictionary:
	var raw: Variant = entry(id).get("climate", {})
	return raw as Dictionary if raw is Dictionary else {}


## Latitude gate for auto-scatter. Species without an envelope are allowed
## everywhere (painting is never gated — the player can always plant anything;
## this only shapes what the AUTO generator picks).
static func species_allowed_at(id: String, latitude: float) -> bool:
	var c := climate(id)
	if c.is_empty():
		return true
	var lat := absf(latitude)
	return lat >= float(c.get("abs_lat_min", 0.0)) - 0.001 \
		and lat <= float(c.get("abs_lat_max", 90.0)) + 0.001


## Drop climate-disallowed species from an auto weight dict and renormalize.
## Returns the original when everything is allowed or NOTHING would remain
## (never empty a forest because the data is too strict — that failure mode
## reads as "auto-veg broken").
static func filter_weights_by_climate(weights: Dictionary, latitude: float) -> Dictionary:
	var out := {}
	for k in weights:
		if species_allowed_at(str(k), latitude):
			out[k] = weights[k]
	if out.is_empty():
		return weights.duplicate(true)
	return out


static func food(id: String) -> Dictionary:
	var raw: Variant = entry(id).get("food", {})
	return raw as Dictionary if raw is Dictionary else {}


static func is_food_species(id: String) -> bool:
	return not food(id).is_empty()


static func food_ids() -> Array[String]:
	_load()
	var out: Array[String] = []
	for k in _data:
		if is_food_species(str(k)):
			out.append(str(k))
	out.sort()
	return out


## True when doy falls inside the harvest window (windows may wrap new year).
static func in_harvest_window(id: String, doy: int) -> bool:
	var fd := food(id)
	if fd.is_empty():
		return false
	var a := int(fd.get("harvest_start_doy", 1))
	var b := int(fd.get("harvest_end_doy", 365))
	if a <= b:
		return doy >= a and doy <= b
	return doy >= a or doy <= b


## Photocard texture for a species, or null. Cached per session (including
## negative results — this is called from mesh builders).
static func photocard_texture(id: String) -> Texture2D:
	if _photocard_cache.has(id):
		var c: Variant = _photocard_cache[id]
		return c as Texture2D if c is Texture2D else null
	var tex: Texture2D = null
	var res_path := "%s/%s.png" % [PHOTOCARD_RES_DIR, id]
	if ResourceLoader.exists(res_path):
		var r: Variant = ResourceLoader.load(res_path)
		if r is Texture2D:
			tex = r
	if tex == null:
		var user_path := "%s/%s.png" % [PHOTOCARD_USER_DIR, id]
		if FileAccess.file_exists(user_path):
			var img := Image.load_from_file(ProjectSettings.globalize_path(user_path))
			if img != null and not img.is_empty():
				img.generate_mipmaps()
				tex = ImageTexture.create_from_image(img)
	_photocard_cache[id] = tex if tex != null else false
	return tex
