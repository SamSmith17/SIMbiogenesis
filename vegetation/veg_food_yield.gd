class_name VegFoodYield
extends RefCounted

## Food-forest yield from the trees actually standing in a polygon (veg overhaul
## Phase 10).
##
## The graph's `plant` node models an annual crop: photosynthesis → biomass every
## hour, gated on a water tank. A food forest is a different thing — perennials
## that are rain-fed and give a crop only inside a harvest window — so rather
## than pretending an orchard is a lettuce bed, this summarises the REAL
## instances inside an OSM area into one bed node's yield.
##
## Pure static math over layer records + the species registry, so it is
## testable offline and the same numbers can be shown in a UI, baked, or
## integrated by the flow engine.

## Fruit/nut trees carry nothing worth harvesting until they are most of the way
## grown. Below HALF apparent size a tree yields zero, ramping to full at
## maturity — the same shape as a real orchard's establishment years, and it
## keeps a freshly planted fill from reading as a working food forest.
const YIELD_MATURITY_FLOOR := 0.5


## Yield-relevant maturity 0..1 from a plant's apparent growth scale.
static func maturity_factor(growth_scale: float) -> float:
	if growth_scale >= 1.0:
		return 1.0
	return clampf((growth_scale - YIELD_MATURITY_FLOOR)
		/ maxf(1.0 - YIELD_MATURITY_FLOOR, 0.001), 0.0, 1.0)


## Summarise every food-bearing plant inside `poly`.
##
## `bulk` is a layer's species → [records] dict; `growth_settings` is what
## VegetationGrowth reads (growth_year + the *_growth_years keys), so an
## immature stand reports a smaller crop. Returns:
##   trees            food-bearing instances counted
##   species_counts   species id → count
##   kg_per_year      Σ per-tree yield × maturity
##   kcal_per_kg      yield-weighted mean energy density
##   kcal_per_year    kg_per_year × kcal_per_kg
##   harvest_start_doy / harvest_end_doy   the dominant species' window
##   dominant         species id contributing the most mass
static func summarize(bulk: Dictionary, poly: PackedVector2Array,
		growth_settings: Dictionary = {}) -> Dictionary:
	var out := {
		"trees": 0, "species_counts": {}, "kg_per_year": 0.0,
		"kcal_per_kg": 0.0, "kcal_per_year": 0.0,
		"harvest_start_doy": 1, "harvest_end_doy": 365, "dominant": "",
	}
	if bulk.is_empty() or poly.size() < 3:
		return out
	var per_species_kg := {}
	var counts := {}
	var total_kg := 0.0
	var total_kcal := 0.0
	var trees := 0
	for slot in bulk:
		var species := str(slot)
		var food := VegSpeciesRegistry.food(species)
		if food.is_empty():
			continue
		var per_tree := float(food.get("yield_kg_per_year", 0.0))
		if per_tree <= 0.0:
			continue
		var kcal_kg := float(food.get("kcal_per_kg", 0.0))
		var records: Variant = bulk[slot]
		if not (records is Array):
			continue
		for item in records as Array:
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			var pt := Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
			if not Geometry2D.is_point_in_polygon(pt, poly):
				continue
			trees += 1
			counts[species] = int(counts.get(species, 0)) + 1
			var m := maturity_factor(
				VegetationGrowth.instance_scale_mult(species, d, growth_settings))
			var kg := per_tree * m
			per_species_kg[species] = float(per_species_kg.get(species, 0.0)) + kg
			total_kg += kg
			total_kcal += kg * kcal_kg
	out["trees"] = trees
	out["species_counts"] = counts
	out["kg_per_year"] = total_kg
	out["kcal_per_year"] = total_kcal
	out["kcal_per_kg"] = (total_kcal / total_kg) if total_kg > 0.0 else 0.0
	# The harvest window comes from whichever species contributes the most MASS.
	# Blending windows across species would invent a season no tree here has;
	# a mixed orchard's dominant crop is the honest single answer for one node.
	var best := ""
	var best_kg := 0.0
	for k in per_species_kg:
		if float(per_species_kg[k]) > best_kg:
			best_kg = float(per_species_kg[k])
			best = str(k)
	if not best.is_empty():
		var fd := VegSpeciesRegistry.food(best)
		out["dominant"] = best
		out["harvest_start_doy"] = int(fd.get("harvest_start_doy", 1))
		out["harvest_end_doy"] = int(fd.get("harvest_end_doy", 365))
	return out


## True when `doy` is inside a (possibly year-wrapping) harvest window.
static func in_window(doy: int, start_doy: int, end_doy: int) -> bool:
	if start_doy <= end_doy:
		return doy >= start_doy and doy <= end_doy
	return doy >= start_doy or doy <= end_doy


## Length of a harvest window in days (wrapping windows included).
static func window_days(start_doy: int, end_doy: int) -> int:
	if start_doy <= end_doy:
		return end_doy - start_doy + 1
	return (365 - start_doy + 1) + end_doy


## The harvest rate that delivers a whole year's crop over its window. A year's
## yield lands during the harvest, not spread across the calendar — that is
## what makes a food forest a seasonal event rather than a trickle.
static func harvest_rate_kg_per_hour(kg_per_year: float, start_doy: int,
		end_doy: int) -> float:
	var days := window_days(start_doy, end_doy)
	if days <= 0 or kg_per_year <= 0.0:
		return 0.0
	return kg_per_year / (float(days) * 24.0)


## Days until the window opens (0 while it is open) — the "next harvest" readout.
static func days_until_harvest(doy: int, start_doy: int, end_doy: int) -> int:
	if in_window(doy, start_doy, end_doy):
		return 0
	var d := start_doy - doy
	if d < 0:
		d += 365
	return d
