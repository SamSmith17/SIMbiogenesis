class_name PlantGrowth
extends RefCounted

## Light-use-efficiency (LUE) biomass production for grow-bed / plant graph nodes.
##
## Monteith (1972, 1977): NPP ≈ ε × APAR, where ε is dry-matter produced per
## unit absorbed PAR. Crop ε is typically ~1–3 g DM MJ⁻¹ PAR (Sinclair & Muchow
## 1999 review). This module uses incident PAR × area as a first-order APAR
## proxy (canopy interception ≈ 1 for a dense bed), then multiplies by water /
## nutrient / shade / season stress factors in [0, 1].
##
## Water demand (L per kg dry biomass) is a playable grow-bed default — field
## crop irrigation is often higher; tune via specs.water_l_per_kg.

## Default light-use efficiency (g dry matter / MJ PAR). Mid-range C3 crop.
const DEFAULT_LUE_G_PER_MJ := 2.0
## Default irrigation demand (L water / kg dry biomass) for a dense grow bed.
const DEFAULT_WATER_L_PER_KG := 50.0
## Default nutrient demand (kg nutrients / kg dry biomass); optional input.
const DEFAULT_NUTRIENT_KG_PER_KG := 0.02
## Default bed area when neither specs.area_m2 nor SoI override is set.
const DEFAULT_AREA_M2 := 10.0


## Northern-hemisphere seasonality (0.35 winter floor → 1.0 midsummer peak).
## Same curve as PbiBiomass — keeps SoI biomass catchment and grow beds aligned.
static func season_factor(month: int) -> float:
	return PbiBiomass.season_factor(month)


## Bed area in m²: manual specs.area_m2, or live SoI disc when use_soi_area.
static func effective_area_m2(specs: Dictionary, soi_area_m2: float = 0.0) -> float:
	if bool(specs.get("use_soi_area", false)) and soi_area_m2 > 0.0:
		return soi_area_m2
	return maxf(float(specs.get("area_m2", DEFAULT_AREA_M2)), 0.0)


## PAR energy incident on the bed over one hour (MJ/h).
## W/m² × m² × 3600 s/h / 1e6 J/MJ.
static func par_mj_per_hour(par_wm2: float, area_m2: float) -> float:
	return maxf(0.0, par_wm2) * maxf(0.0, area_m2) * 3600.0 / 1_000_000.0


## Potential (unstressed) dry biomass rate from light alone (kg/h).
static func potential_biomass_kg_h(par_wm2: float, area_m2: float,
		lue_g_per_mj: float = DEFAULT_LUE_G_PER_MJ, month: int = 6) -> float:
	var mj_h := par_mj_per_hour(par_wm2, area_m2)
	var g_h: float = maxf(0.0, lue_g_per_mj) * mj_h * season_factor(month)
	return g_h / 1000.0


## Stress-limited biomass rate (kg/h). Factors clamp to [0, 1].
## sunlight_factor is the per-node shade / availability multiplier (Phase 5
## writes 3D shade here; default 1.0 = unshaded ambient).
static func biomass_kg_per_hour(par_wm2: float, area_m2: float,
		lue_g_per_mj: float = DEFAULT_LUE_G_PER_MJ, month: int = 6,
		water_factor: float = 1.0, nutrient_factor: float = 1.0,
		sunlight_factor: float = 1.0) -> float:
	var potential := potential_biomass_kg_h(par_wm2, area_m2, lue_g_per_mj, month)
	var f_w := clampf(water_factor, 0.0, 1.0)
	var f_n := clampf(nutrient_factor, 0.0, 1.0)
	var f_s := clampf(sunlight_factor, 0.0, 1.2)
	return potential * f_w * f_n * f_s


## Irrigation demand (L/h) for a given biomass production rate.
static func water_demand_lph(biomass_kg_h: float, water_l_per_kg: float = DEFAULT_WATER_L_PER_KG) -> float:
	return maxf(0.0, biomass_kg_h) * maxf(0.0, water_l_per_kg)


## Nutrient demand (kg/h) for a given biomass production rate.
static func nutrient_demand_kgph(biomass_kg_h: float,
		nutrient_kg_per_kg: float = DEFAULT_NUTRIENT_KG_PER_KG) -> float:
	return maxf(0.0, biomass_kg_h) * maxf(0.0, nutrient_kg_per_kg)


## Resolve LUE / water / nutrient coeffs from plant node specs (with defaults).
static func lue_from_specs(specs: Dictionary) -> float:
	return maxf(float(specs.get("lue_g_per_mj", DEFAULT_LUE_G_PER_MJ)), 0.0)


static func water_l_per_kg_from_specs(specs: Dictionary) -> float:
	return maxf(float(specs.get("water_l_per_kg", DEFAULT_WATER_L_PER_KG)), 0.0)


static func nutrient_kg_per_kg_from_specs(specs: Dictionary) -> float:
	return maxf(float(specs.get("nutrient_kg_per_kg", DEFAULT_NUTRIENT_KG_PER_KG)), 0.0)


## Per-node shade / availability factor (default ambient full sun = 1.0).
static func sunlight_factor_from_specs(specs: Dictionary) -> float:
	if not specs.has("sunlight_factor"):
		return 1.0
	return clampf(float(specs.get("sunlight_factor", 1.0)), 0.0, 1.2)
