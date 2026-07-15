class_name PbiBiomass
extends RefCounted

## Planetary Basic Income — local biomass yield from SoI area.
##
## Reference: Field et al. (1998) / MODIS terrestrial NPP reviews cite ~0.5–2.0 kg C
## m⁻² yr⁻¹ for productive land; playable PBI uses ~1.2 kg dry harvestable biomass
## m⁻² yr⁻¹ (≈ mid-range herbaceous/grassland harvestable fraction, not full NPP).

## Dry harvestable biomass per m² per calendar year (kg/m²/yr).
const NPP_KG_M2_YR := 1.2
const HOURS_PER_YEAR := 365.0 * 24.0


## Northern-hemisphere seasonality (0.35 winter floor → 1.0 midsummer peak).
static func season_factor(month: int) -> float:
	var m := clampi(month, 1, 12)
	var phase := (float(m) - 1.0) / 11.0
	return 0.35 + 0.65 * (0.5 + 0.5 * sin(phase * PI))


static func biomass_kg_per_hour(area_m2: float, month: int) -> float:
	if area_m2 <= 0.0:
		return 0.0
	return area_m2 * NPP_KG_M2_YR / HOURS_PER_YEAR * season_factor(month)


static func biomass_kg_per_day(area_m2: float, month: int) -> float:
	return biomass_kg_per_hour(area_m2, month) * 24.0


## Resolve catchment collection area (manual m² or live SoI disc).
static func effective_area_m2(specs: Dictionary, soi_area_m2: float) -> float:
	if bool(specs.get("use_soi_area", false)) and soi_area_m2 > 0.0:
		return soi_area_m2
	return maxf(float(specs.get("area_m2", 10.0)), 0.0)


static func catchment_output_kind(specs: Dictionary) -> String:
	if str(specs.get("catchment_kind", "rain")) == "biomass":
		return "biomass"
	return "water"
