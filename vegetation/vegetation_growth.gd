class_name VegetationGrowth
extends RefCounted

## Per-instance plant growth over sim-years (or crop days): seedling → full size,
## then optional senescence fade, then (for trees) death at maturity + reseeding.
##
## Growth is a SESSION-LIVE effect layered over the vegetation layers, driven by a
## monotonic "growth clock" the terrain loader advances (mainly in analemma / ∞
## mode — see terrain_loader._advance_growth). Design choices, and why:
##   * The apparent SCALE is a pure function of (growth_clock − birth) so it eases
##     smoothly as seasons pass and reverses cleanly if the clock rewinds.
##   * The generational turnover (death + reseed) is forward-only and throttled,
##     like the battery integrator — it can't be analytically reversed.
##   * birth_h lives in the growth-clock domain, which resets each load, so it is
##     re-derived on load (reset=true) rather than trusted from disk; that keeps a
##     stale value from a previous session from warping ages. Growth PROGRESS is
##     therefore not persisted across reloads (the forest re-seeds its age mix),
##     which is fine for a visual time-lapse feature.

const HOURS_PER_YEAR := 8766.0        # 365.25 × 24
const HOURS_PER_DAY := 24.0
const SEEDLING_SCALE := 0.14          # apparent size at age 0
const SENESCENT_SCALE := 0.35         # floor after full senescence
## Growth curve exponent (<1 = grows fast early, tapering toward maturity).
const GROWTH_EASE := 0.6
const SEED_RADIUS_M := 1.0            # seedlings spring up within this of the parent
const SEEDLINGS_MIN := 1
const SEEDLINGS_MAX := 2
const SEED_ATTEMPTS := 8              # retries when a zone boundary rejects a sample
## Structural clock advance below this factor is treated as winter dormancy (no aging).
const DORMANCY_THRESHOLD := 0.05
## Phenology milestone days (NH reference) when scale refresh + optional reseed run.
## ~4 pulses per growing season vs ~12 under the old fixed 720 h throttle.
const GROWTH_MILESTONE_DOYS: Array[float] = [84.0, 135.0, 172.0, 260.0]
## Only these mesh families die at maturity and reseed. Grass / shrub grow-and-hold
## (plus optional senescence scale fade without removal).
const TREE_SPECIES: Array[String] = ["pine", "deciduous"]

## Kept local (not VegetationLayer.ALL_SPECIES / AutoVegetationRuntime.SLOT_ALIAS)
## on purpose: VegetationRuntime + AutoVegetationRuntime both reference this class,
## so referencing them back would form a class_name resolution cycle ("Identifier
## VegetationGrowth not declared"). This class stays a dependency-free leaf.
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
	# Phase 5 registry species → growth-settings slot (the *_growth_years key
	# each reads when it has no own key).
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


## Senescence length after maturity (years for trees, days for crops when using days).
static func senescence_span(species: String, settings: Dictionary) -> float:
	var day_key := "%s_senescence_days" % species
	if settings.has(day_key):
		return float(settings[day_key])
	var yr_key := "%s_senescence_years" % species
	if settings.has(yr_key):
		return float(settings[yr_key])
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


static func senescence_span_hours(species: String, settings: Dictionary) -> float:
	var days := growth_days(species, settings)
	var sen := senescence_span(species, settings)
	if sen <= 0.0:
		return 0.0
	if days > 0.0:
		return sen * HOURS_PER_DAY
	return sen * HOURS_PER_YEAR


## True if the settings enable growth for at least one species.
static func any_enabled(settings: Dictionary) -> bool:
	for species in _SPECIES:
		if float(settings.get("%s_growth_years" % species, 0.0)) > 0.0:
			return true
		if float(settings.get("%s_growth_days" % species, 0.0)) > 0.0:
			return true
	for k in settings.keys():
		var ks := str(k)
		if ks.ends_with("_growth_days") and float(settings[k]) > 0.0:
			return true
		if ks.ends_with("_growth_years") and float(settings[k]) > 0.0:
			return true
	return false


## 0..1 envelope for how much the structural growth clock should advance today.
## Uses canopy + grass phenology so temperate sites pause in winter and pulse in
## spring/summer (matches shader seasonality without a separate model).
static func structural_growth_factor(day_of_year: int, latitude: float) -> float:
	var sig := SeasonModel.season_signals(day_of_year, latitude)
	var leaf := float(sig.get("leaf_coverage", 0.0))
	var grass := float(sig.get("grass_growth", 0.0))
	return clampf(maxf(leaf, grass), 0.0, 1.0)


## Death/reseed only during the active growing window (not deep winter dormancy).
static func reseed_allowed(day_of_year: int, latitude: float) -> bool:
	var nh := SeasonModel.to_nh_doy(day_of_year, latitude)
	return nh >= SeasonModel.LEAF_OUT_START and nh <= SeasonModel.GRASS_FADE_END


## True when the calendar crossed a growth milestone between two day-of-year samples.
## Handles year rollover (Dec → Jan) for analemma multi-year loops.
static func milestones_crossed(from_doy: int, to_doy: int, latitude: float) -> bool:
	if from_doy == to_doy:
		return false
	var nh_from := SeasonModel.to_nh_doy(from_doy, latitude)
	var nh_to := SeasonModel.to_nh_doy(to_doy, latitude)
	for m in GROWTH_MILESTONE_DOYS:
		if _milestone_in_crossing(nh_from, nh_to, m):
			return true
	return false


static func _milestone_in_crossing(nh_from: float, nh_to: float, milestone: float) -> bool:
	if nh_from < nh_to:
		return milestone > nh_from and milestone <= nh_to
	# Year wrap (e.g. Dec → Jan).
	return milestone > nh_from or milestone <= nh_to


## Age fraction (age / growth_years) → apparent scale multiplier (seedling → full).
static func scale_for_age(age_years: float, gy: float) -> float:
	if gy <= 0.0:
		return 1.0
	var t := clampf(age_years / gy, 0.0, 1.0)
	return SEEDLING_SCALE + (1.0 - SEEDLING_SCALE) * pow(t, GROWTH_EASE)


## Full lifecycle: seed → full over grow_h, then fade toward SENESCENT_SCALE over
## senesce_h. Ages are in hours. When senesce_h <= 0, holds at full after maturity.
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


## Per-instance render scale multiplier from its birth time + the growth clock.
## Records with no birth_h (growth off, or not yet seeded) render at full size.
static func instance_scale_mult(species: String, d: Dictionary, settings: Dictionary) -> float:
	var grow_h := growth_span_hours(species, settings)
	if grow_h <= 0.0 or not d.has("birth_h"):
		return 1.0
	var now_h := float(settings.get("growth_now_h", 0.0))
	var age_h := now_h - float(d["birth_h"])
	var sen_h := senescence_span_hours(species, settings)
	return scale_for_lifecycle(age_h, grow_h, sen_h)


## Assign birth times to bulk records. With reset=false only records missing a
## birth_h are touched (new placements keep whatever they were given); with
## reset=true every record is re-seeded (used on load). Ages are skewed toward
## mature so an established forest reads as full canopy with a scatter of younger
## trees rather than a field of seedlings.
static func ensure_birth_times(bulk_dict: Dictionary, now_h: float,
		settings: Dictionary, rng: RandomNumberGenerator, reset: bool = false) -> void:
	for slot in bulk_dict.keys():
		var species := str(slot)
		var grow_h := growth_span_hours(species, settings)
		# Growth disabled for this species → leave birth_h unset so the instance
		# renders at full size. (Stamping "now" here would make every tree an age-0
		# seedling the moment growth is later enabled — a sudden shrink.)
		if grow_h <= 0.0:
			continue
		for item in bulk_dict[slot]:
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			if not reset and d.has("birth_h"):
				continue
			# age_frac skews high (mature): 1 − rand^1.6 clusters near 1.0.
			var age_frac := 1.0 - pow(rng.randf(), 1.6)
			d["birth_h"] = now_h - age_frac * grow_h


## Per-slot record counts — the population caps captured when growth starts so
## reseeding can hold the forest near its original density instead of exploding.
static func capture_caps(bulk_dict: Dictionary) -> Dictionary:
	var caps := {}
	for slot in bulk_dict.keys():
		caps[str(slot)] = (bulk_dict[slot] as Array).size()
	return caps


## Kill matured trees (age ≥ growth span + senescence) and spring up SEEDLINGS_MIN..MAX
## seedlings within SEED_RADIUS_M of each, holding each slot near its cap so the
## population stays stable. `add_cb(slot, x, z, yaw, scale, card) -> Dictionary`
## adds one record and returns it (or null on capacity). Returns true if any
## record changed so the caller can rebuild.
static func advance_generations(bulk_dict: Dictionary, now_h: float,
		settings: Dictionary, rng: RandomNumberGenerator, caps: Dictionary,
		add_cb: Callable, zone: GrowthZoneIndex = null,
		allow_reseed: bool = true) -> bool:
	if not allow_reseed:
		return false
	var changed := false
	for slot in bulk_dict.keys():
		var species := _species_for_slot(str(slot))
		if species not in TREE_SPECIES:
			continue
		var grow_h := growth_span_hours(str(slot), settings)
		if grow_h <= 0.0:
			continue
		var sen_h := senescence_span_hours(str(slot), settings)
		var life_h := grow_h + maxf(sen_h, 0.0)
		var arr: Array = bulk_dict[slot]
		var kept: Array = []
		var dead: Array = []
		for item in arr:
			if not (item is Dictionary):
				kept.append(item)
				continue
			var d: Dictionary = item
			var age := now_h - float(d.get("birth_h", now_h))
			if age >= life_h:
				dead.append(d)
			else:
				kept.append(d)
		if dead.is_empty():
			continue
		changed = true
		bulk_dict[slot] = kept
		var cap := int(caps.get(str(slot), arr.size()))
		for parent in dead:
			var count := rng.randi_range(SEEDLINGS_MIN, SEEDLINGS_MAX)
			for _k in count:
				if (bulk_dict[slot] as Array).size() >= cap:
					break
				var pos := _sample_seed_pos(parent, rng, zone)
				if not is_finite(pos.x):
					continue
				var rec: Variant = add_cb.call(str(slot),
					pos.x, pos.y,
					rng.randf() * TAU,
					float(parent.get("scale", 1.0)),
					parent.get("card_settings", {}))
				if rec is Dictionary:
					(rec as Dictionary)["birth_h"] = now_h
	return changed


## Uniform disc sample around parent; when `zone` is non-empty, only accept
## positions inside the zone (up to SEED_ATTEMPTS). Empty zone → radius only.
static func _sample_seed_pos(parent: Dictionary, rng: RandomNumberGenerator,
		zone: GrowthZoneIndex) -> Vector2:
	var px := float(parent.get("x", 0.0))
	var pz := float(parent.get("z", 0.0))
	var use_zone := zone != null and not zone.is_empty()
	for _attempt in SEED_ATTEMPTS:
		var ang := rng.randf() * TAU
		# sqrt keeps seedlings uniformly spread over the disc, not clumped centre.
		var r := sqrt(rng.randf()) * SEED_RADIUS_M
		var x := px + cos(ang) * r
		var z := pz + sin(ang) * r
		if not use_zone or zone.contains(x, z):
			return Vector2(x, z)
	return Vector2(NAN, NAN)


## Auto-vegetation slots may be biome names (conifer/broadleaf/…); map to the
## card-factory species so growth_years / TREE_SPECIES lookups line up with render.
static func _species_for_slot(slot: String) -> String:
	if slot in _SPECIES:
		return slot
	return str(_SLOT_ALIAS.get(slot, "deciduous"))
