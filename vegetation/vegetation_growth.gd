class_name VegetationGrowth
extends RefCounted

## Record/settings facade over VegGrowthModel — the model is numbers only, this
## file knows what a vegetation RECORD and a style SETTINGS dict are.
##
## A plant's size is a pure function of the calendar (see VegGrowthModel):
##   * painted records carry `born_y` — the growth-year they were born — which
##     is persisted, so ages survive a reload and scrub with the timeline;
##   * generated (auto) records carry nothing: their birth is derived from a
##     position hash and the `forest_age` profile every time it is needed;
##   * a settings dict carries `growth_year` (now). Without it everything is
##     full size — which is what selftests, the Tune-look preview and the
##     impostor baker rely on.
##
## What is NOT here any more, so nobody restores it: the per-session growth
## clock, milestone ticks, advance_generations (kill + reseed, which mutated the
## record lists), population caps and growth zones. Death and regrowth are part
## of the pure function now.
##
## The lifecycle helpers at the bottom (scale_for_lifecycle / growth_stage) are
## the GROW BED's crop model and are unrelated to the forest.

const HOURS_PER_YEAR := 8766.0        # 365.25 × 24
const HOURS_PER_DAY := 24.0
const SEEDLING_SCALE := 0.14          # grow-bed crop size at age 0
const SENESCENT_SCALE := 0.35         # grow-bed floor after full senescence
## Grow-bed curve exponent (<1 = grows fast early, tapering toward maturity).
const GROWTH_EASE := 0.6
## Only these mesh families live a life cycle (decline, die, regrow). Grass and
## shrubs grow and hold.
const TREE_SPECIES: Array[String] = ["pine", "deciduous"]
## A tree with no catalog lifespan lives this many maturity ages.
const DEFAULT_LIFESPAN_MATURITIES := 6.0
## A legacy record at or past this fraction of its growth span migrates as
## ESTABLISHED (full size) rather than as a nearly-grown plant.
const ESTABLISHED_AGE_FRAC := 0.95

## Settings keys this facade reads.
const KEY_NOW := "growth_year"            # growth-year now; absent = full size
const KEY_EPOCH := "growth_epoch_y"       # site epoch for mixed/young profiles
const KEY_FROZEN := "growth_frozen"       # true = draw everything mature

const FOREST_AGE_MATURE := VegGrowthModel.PROFILE_MATURE
const FOREST_AGE_MIXED := VegGrowthModel.PROFILE_MIXED
const FOREST_AGE_YOUNG := VegGrowthModel.PROFILE_YOUNG

## Kept local (not VegetationLayer.ALL_SPECIES / AutoVegetationRuntime.SLOT_ALIAS)
## on purpose: VegetationRuntime + AutoVegetationRuntime both reference this class,
## so referencing them back would form a class_name resolution cycle.
const _SPECIES: Array[String] = ["pine", "deciduous", "shrub", "grass_lawn", "grass_field"]
const _SLOT_ALIAS := {
	"conifer": "pine",
	"taiga": "pine",
	"broadleaf": "deciduous",
	"scrub": "shrub",
	"spruce": "pine",
	"cedar": "pine",
	"fir": "pine",
	"redwood": "pine",
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
	"walnut": "deciduous",
	"olive": "deciduous",
	"mango": "deciduous",
	"banana": "deciduous",
	"ficus": "deciduous",
	"acacia": "deciduous",
	"palm": "deciduous",
	"coconut_palm": "deciduous",
	"date_palm": "deciduous",
	"fan_palm": "deciduous",
	"cactus": "shrub",
	"saguaro": "shrub",
	"prickly_pear": "shrub",
	"joshua_tree": "shrub",
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
}


# ---- settings → spans ----------------------------------------------------

static func growth_years(species: String, settings: Dictionary) -> float:
	var key := "%s_growth_years" % species
	if settings.has(key):
		return float(settings[key])
	var fam := _species_for_slot(species)
	return float(settings.get("%s_growth_years" % fam, 0.0))


## Crop / short-cycle species: growth length in days (takes precedence when > 0).
static func growth_days(species: String, settings: Dictionary) -> float:
	var key := "%s_growth_days" % species
	if settings.has(key):
		return float(settings[key])
	return 0.0


## Span of the grow phase in hours (days or years depending on species settings).
static func growth_span_hours(species: String, settings: Dictionary) -> float:
	var days := growth_days(species, settings)
	if days > 0.0:
		return days * HOURS_PER_DAY
	var gy := growth_years(species, settings)
	if gy > 0.0:
		return gy * HOURS_PER_YEAR
	return 0.0


## Age at which the plant reaches full size, in years. 0 = growth off.
static func maturity_years(species: String, settings: Dictionary) -> float:
	return growth_span_hours(species, settings) / HOURS_PER_YEAR


## Species lifespan in years (before the per-plant jitter). 0 = grow and hold.
## Resolution: explicit `<species>_lifespan_years` setting > the registry's
## `lifespan_years` (species, then its family) > DEFAULT_LIFESPAN_MATURITIES.
static func lifespan_years(species: String, settings: Dictionary) -> float:
	var fam := _species_for_slot(species)
	if fam not in TREE_SPECIES:
		return 0.0
	var maturity := maturity_years(species, settings)
	if maturity <= 0.0:
		return 0.0
	var life := 0.0
	var key := "%s_lifespan_years" % species
	if settings.has(key):
		life = float(settings[key])
	if life <= 0.0:
		life = VegSpeciesRegistry.lifespan_years(species)
	if life <= 0.0:
		life = VegSpeciesRegistry.lifespan_years(fam)
	if life <= 0.0:
		life = maturity * DEFAULT_LIFESPAN_MATURITIES
	return VegGrowthModel.effective_lifespan(maturity, life)


## True if the settings enable growth for at least one species.
static func any_enabled(settings: Dictionary) -> bool:
	for k in settings.keys():
		var ks := str(k)
		if (ks.ends_with("_growth_days") or ks.ends_with("_growth_years")) \
				and float(settings[k]) > 0.0:
			return true
	return false


static func forest_age_profile(settings: Dictionary) -> String:
	var p := str(settings.get("forest_age", FOREST_AGE_MATURE)).to_lower()
	if p == FOREST_AGE_YOUNG or p == FOREST_AGE_MIXED:
		return p
	return FOREST_AGE_MATURE


# ---- record → model parameters -------------------------------------------

## Everything about a species + settings pair that is the SAME for every record
## in a batch. Resolve once per batch (a forest build touches ~150k records; the
## registry and settings lookups must not run per tree).
static func batch_params(species: String, settings: Dictionary) -> Dictionary:
	var maturity := 0.0 if bool(settings.get(KEY_FROZEN, false)) \
		else maturity_years(species, settings)
	return {
		"species": species,
		"maturity": maturity,
		"lifespan": lifespan_years(species, settings) if maturity > 0.0 else 0.0,
		"profile": forest_age_profile(settings),
		"epoch": float(settings.get(KEY_EPOCH, VegGrowthModel.BASE_YEAR)),
	}


## The four numbers VegGrowthModel.state() needs for one record:
## {born, maturity, lifespan, seed}. `maturity` 0 = growth off for this plant.
static func params_for(bp: Dictionary, d: Dictionary) -> Dictionary:
	var maturity := float(bp["maturity"])
	if maturity <= 0.0:
		return {"born": VegGrowthModel.BASE_YEAR, "maturity": 0.0, "lifespan": 0.0, "seed": 0.0}
	var seed := VegGrowthModel.seed01(str(bp["species"]),
		float(d.get("x", 0.0)), float(d.get("z", 0.0)))
	var life_i := VegGrowthModel.jittered_lifespan(maturity, float(bp["lifespan"]), seed)
	var born := 0.0
	if d.has("born_y"):
		born = float(d["born_y"])
	else:
		born = VegGrowthModel.derived_born(str(bp["profile"]), float(bp["epoch"]),
			maturity, life_i, seed)
	return {"born": born, "maturity": maturity, "lifespan": life_i, "seed": seed}


static func record_params(species: String, d: Dictionary, settings: Dictionary) -> Dictionary:
	return params_for(batch_params(species, settings), d)


## INSTANCE_CUSTOM payload for one record — what veg_growth.gdshaderinc reads:
## (born − BASE_YEAR, maturity, lifespan, seed). All zero = identity.
static func custom_for(bp: Dictionary, d: Dictionary) -> Color:
	var p := params_for(bp, d)
	if float(p["maturity"]) <= 0.0:
		return Color(0.0, 0.0, 0.0, 0.0)
	return Color(float(p["born"]) - VegGrowthModel.BASE_YEAR, float(p["maturity"]),
		float(p["lifespan"]), float(p["seed"]))


static func instance_custom(species: String, d: Dictionary, settings: Dictionary) -> Color:
	return custom_for(batch_params(species, settings), d)


## Full model state for one record at settings[KEY_NOW]. No KEY_NOW = identity.
static func plant_state(species: String, d: Dictionary, settings: Dictionary) -> Dictionary:
	if not settings.has(KEY_NOW):
		return VegGrowthModel.state(0.0, 0.0, 0.0, 0.0, 0.0)
	var p := record_params(species, d, settings)
	return VegGrowthModel.state(float(settings[KEY_NOW]), float(p["born"]),
		float(p["maturity"]), float(p["lifespan"]), float(p["seed"]))


## Apparent size 0..1 of one record now (its height fraction; 0 while the spot
## stands empty between generations). The CPU-side answer for anything that
## needs a plant's size — food yield, readouts. Drawing does NOT use this: the
## shader evaluates the same function per instance.
static func instance_scale_mult(species: String, d: Dictionary, settings: Dictionary) -> float:
	return float(plant_state(species, d, settings)["height"])


# ---- stamping + migration --------------------------------------------------

## Mark a record as planted NOW (a seedling that grows from this date).
static func stamp_young(d: Dictionary, t_now: float) -> void:
	d.erase("birth_h")
	d["born_y"] = t_now


## Mark a record as standing FULL SIZE now, somewhere on its plateau.
static func stamp_established(d: Dictionary, species: String, settings: Dictionary,
		t_now: float) -> void:
	d.erase("birth_h")
	var maturity := maturity_years(species, settings)
	if maturity <= 0.0:
		d.erase("born_y")
		return
	var seed := VegGrowthModel.seed01(species,
		float(d.get("x", 0.0)), float(d.get("z", 0.0)))
	var life_i := VegGrowthModel.jittered_lifespan(
		maturity, lifespan_years(species, settings), seed)
	d["born_y"] = VegGrowthModel.established_born(t_now, maturity, life_i, seed)


## One-way upgrade of painted records to `born_y`. Returns how many changed.
##   * legacy `birth_h` (hours on a per-session clock that restarted at 0 each
##     load, so −birth_h is the age): ≥ 0 → planted now; near/over the growth
##     span → established; otherwise that age is kept.
##   * no birth at all → established (it was drawn full size).
## Records that already have `born_y` are left alone.
static func migrate_records(bulk_dict: Dictionary, settings: Dictionary, t_now: float) -> int:
	var changed := 0
	for slot in bulk_dict.keys():
		var species := str(slot)
		var grow_h := growth_span_hours(species, settings)
		for item in bulk_dict[slot]:
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			if d.has("born_y"):
				if d.has("birth_h"):
					d.erase("birth_h")
					changed += 1
				continue
			if grow_h <= 0.0:
				# Growth off for this species: nothing to stamp, and a stale
				# session-clock value must not linger in the file.
				if d.has("birth_h"):
					d.erase("birth_h")
					changed += 1
				continue
			var b := float(d.get("birth_h", -INF))
			if b >= 0.0:
				stamp_young(d, t_now)
			elif -b >= grow_h * ESTABLISHED_AGE_FRAC:
				stamp_established(d, species, settings, t_now)
			else:
				d.erase("birth_h")
				d["born_y"] = t_now - (-b / HOURS_PER_YEAR)
			changed += 1
	return changed


# ---- grow bed (crop) lifecycle — unrelated to the forest model -------------

## Age fraction (age / growth_years) → apparent scale multiplier (seedling → full).
static func scale_for_age(age_years: float, gy: float) -> float:
	if gy <= 0.0:
		return 1.0
	var t := clampf(age_years / gy, 0.0, 1.0)
	return SEEDLING_SCALE + (1.0 - SEEDLING_SCALE) * pow(t, GROWTH_EASE)


## Seed → full over grow_h, then fade toward SENESCENT_SCALE over senesce_h.
## Ages are in hours. When senesce_h <= 0, holds at full after maturity.
static func scale_for_lifecycle(age_h: float, grow_h: float, senesce_h: float = 0.0) -> float:
	if grow_h <= 0.0:
		return 1.0
	if age_h <= grow_h:
		var t := clampf(age_h / grow_h, 0.0, 1.0)
		return SEEDLING_SCALE + (1.0 - SEEDLING_SCALE) * pow(t, GROWTH_EASE)
	if senesce_h <= 0.0:
		return 1.0
	var u := clampf((age_h - grow_h) / senesce_h, 0.0, 1.0)
	return lerpf(1.0, SENESCENT_SCALE, u)


## Stage label for UI: "seed" | "growing" | "full" | "senescent".
static func growth_stage(age_h: float, grow_h: float, senesce_h: float = 0.0) -> String:
	if grow_h <= 0.0:
		return "full"
	if age_h <= 0.0:
		return "seed"
	if age_h < grow_h * 0.15:
		return "seed"
	if age_h < grow_h:
		return "growing"
	if senesce_h > 0.0 and age_h > grow_h + senesce_h * 0.2:
		return "senescent"
	return "full"


## Auto-vegetation slots may be biome names (conifer/broadleaf/…); map to the
## card-factory species so growth_years / TREE_SPECIES lookups line up with render.
static func _species_for_slot(slot: String) -> String:
	if slot in _SPECIES:
		return slot
	return str(_SLOT_ALIAS.get(slot, "deciduous"))
