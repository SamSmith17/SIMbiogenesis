class_name VegetationGrowth
extends RefCounted

## Per-instance plant growth over sim-years: seedling → full size, then (for
## trees) death at maturity + local reseeding within a couple of metres.
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
const SEEDLING_SCALE := 0.14          # apparent size at age 0
## Growth curve exponent (<1 = grows fast early, tapering toward maturity).
const GROWTH_EASE := 0.6
const SEED_RADIUS_M := 2.0            # seedlings spring up within this of the parent
const SEEDLINGS_MIN := 1
const SEEDLINGS_MAX := 2
## Only these species die at maturity and reseed. Grass / shrub grow-and-hold.
const TREE_SPECIES: Array[String] = ["pine", "deciduous"]

## Kept local (not VegetationLayer.ALL_SPECIES / AutoVegetationRuntime.SLOT_ALIAS)
## on purpose: VegetationRuntime + AutoVegetationRuntime both reference this class,
## so referencing them back would form a class_name resolution cycle ("Identifier
## VegetationGrowth not declared"). This class stays a dependency-free leaf.
const _SPECIES: Array[String] = ["pine", "deciduous", "shrub", "grass_lawn", "grass_field"]
const _SLOT_ALIAS := {
	"conifer": "pine",
	"taiga": "pine",
	"palm": "deciduous",
	"broadleaf": "deciduous",
	"scrub": "shrub",
}


static func growth_years(species: String, settings: Dictionary) -> float:
	return float(settings.get("%s_growth_years" % species, 0.0))


## True if the settings enable growth for at least one species.
static func any_enabled(settings: Dictionary) -> bool:
	for species in _SPECIES:
		if float(settings.get("%s_growth_years" % species, 0.0)) > 0.0:
			return true
	return false


## Age fraction (age / growth_years) → apparent scale multiplier (seedling → full).
static func scale_for_age(age_years: float, gy: float) -> float:
	if gy <= 0.0:
		return 1.0
	var t := clampf(age_years / gy, 0.0, 1.0)
	return SEEDLING_SCALE + (1.0 - SEEDLING_SCALE) * pow(t, GROWTH_EASE)


## Per-instance render scale multiplier from its birth time + the growth clock.
## Records with no birth_h (growth off, or not yet seeded) render at full size.
static func instance_scale_mult(species: String, d: Dictionary, settings: Dictionary) -> float:
	var gy := growth_years(species, settings)
	if gy <= 0.0 or not d.has("birth_h"):
		return 1.0
	var now_h := float(settings.get("growth_now_h", 0.0))
	var age := (now_h - float(d["birth_h"])) / HOURS_PER_YEAR
	return scale_for_age(age, gy)


## Assign birth times to bulk records. With reset=false only records missing a
## birth_h are touched (new placements keep whatever they were given); with
## reset=true every record is re-seeded (used on load). Ages are skewed toward
## mature so an established forest reads as full canopy with a scatter of younger
## trees rather than a field of seedlings.
static func ensure_birth_times(bulk_dict: Dictionary, now_h: float,
		settings: Dictionary, rng: RandomNumberGenerator, reset: bool = false) -> void:
	for slot in bulk_dict.keys():
		var species := _species_for_slot(str(slot))
		var gy := growth_years(species, settings)
		# Growth disabled for this species → leave birth_h unset so the instance
		# renders at full size. (Stamping "now" here would make every tree an age-0
		# seedling the moment growth is later enabled — a sudden shrink.)
		if gy <= 0.0:
			continue
		for item in bulk_dict[slot]:
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			if not reset and d.has("birth_h"):
				continue
			# age_frac skews high (mature): 1 − rand^1.6 clusters near 1.0.
			var age_frac := 1.0 - pow(rng.randf(), 1.6)
			d["birth_h"] = now_h - age_frac * gy * HOURS_PER_YEAR


## Per-slot record counts — the population caps captured when growth starts so
## reseeding can hold the forest near its original density instead of exploding.
static func capture_caps(bulk_dict: Dictionary) -> Dictionary:
	var caps := {}
	for slot in bulk_dict.keys():
		caps[str(slot)] = (bulk_dict[slot] as Array).size()
	return caps


## Kill matured trees (age ≥ growth_years) and spring up SEEDLINGS_MIN..MAX
## seedlings within SEED_RADIUS_M of each, holding each slot near its cap so the
## population stays stable. `add_cb(slot, x, z, yaw, scale, card) -> Dictionary`
## adds one record and returns it (or null on capacity). Returns true if any
## record changed so the caller can rebuild.
static func advance_generations(bulk_dict: Dictionary, now_h: float,
		settings: Dictionary, rng: RandomNumberGenerator, caps: Dictionary,
		add_cb: Callable) -> bool:
	var changed := false
	for slot in bulk_dict.keys():
		var species := _species_for_slot(str(slot))
		if species not in TREE_SPECIES:
			continue
		var gy := growth_years(species, settings)
		if gy <= 0.0:
			continue
		var arr: Array = bulk_dict[slot]
		var kept: Array = []
		var dead: Array = []
		for item in arr:
			if not (item is Dictionary):
				kept.append(item)
				continue
			var d: Dictionary = item
			var age := (now_h - float(d.get("birth_h", now_h))) / HOURS_PER_YEAR
			if age >= gy:
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
				var ang := rng.randf() * TAU
				# sqrt keeps seedlings uniformly spread over the disc, not clumped centre.
				var r := sqrt(rng.randf()) * SEED_RADIUS_M
				var rec: Variant = add_cb.call(str(slot),
					float(parent.get("x", 0.0)) + cos(ang) * r,
					float(parent.get("z", 0.0)) + sin(ang) * r,
					rng.randf() * TAU,
					float(parent.get("scale", 1.0)),
					parent.get("card_settings", {}))
				if rec is Dictionary:
					(rec as Dictionary)["birth_h"] = now_h
	return changed


## Auto-vegetation slots may be biome names (conifer/broadleaf/…); map to the
## card-factory species so growth_years / TREE_SPECIES lookups line up with render.
static func _species_for_slot(slot: String) -> String:
	if slot in _SPECIES:
		return slot
	return str(_SLOT_ALIAS.get(slot, "deciduous"))
