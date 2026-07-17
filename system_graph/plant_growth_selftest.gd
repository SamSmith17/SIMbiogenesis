extends SceneTree

## Offline checks for PlantGrowth (Monteith LUE) — Phase 4 solar PBI consumers.

const PlantGrowthScript := preload("res://system_graph/plant_growth.gd")
const SolarIrradianceScript := preload("res://core/solar_irradiance.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_night_zero()
	fails += _test_par_mj()
	fails += _test_lue_scale()
	fails += _test_water_stress()
	fails += _test_shade_factor()
	fails += _test_season_summer_gt_winter()
	fails += _test_demands()
	fails += _test_area_soi()
	if fails == 0:
		print("PLANT GROWTH SELFTEST PASS  (8 checks)")
		quit(0)
	else:
		print("PLANT GROWTH SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _test_night_zero() -> int:
	var rate := PlantGrowthScript.biomass_kg_per_hour(0.0, 10.0)
	if rate > 1e-9:
		push_error("night PAR=0 should yield 0 biomass got %.6f" % rate)
		return 1
	return 0


func _test_par_mj() -> int:
	# 1000 W/m² PAR over 1 m² for 1 h = 3.6 MJ
	var mj := PlantGrowthScript.par_mj_per_hour(1000.0, 1.0)
	if absf(mj - 3.6) > 0.001:
		push_error("par_mj_per_hour expected 3.6 got %.4f" % mj)
		return 1
	return 0


func _test_lue_scale() -> int:
	# Midsummer (month 6 → season ≈ 1.0): 2 g/MJ × 3.6 MJ/h = 7.2 g/h = 0.0072 kg/h
	var rate := PlantGrowthScript.potential_biomass_kg_h(1000.0, 1.0, 2.0, 6)
	if absf(rate - 0.0072) > 0.0002:
		push_error("potential LUE rate expected ~0.0072 kg/h got %.6f" % rate)
		return 1
	return 0


func _test_water_stress() -> int:
	var full := PlantGrowthScript.biomass_kg_per_hour(800.0, 10.0, 2.0, 6, 1.0, 1.0, 1.0)
	var half := PlantGrowthScript.biomass_kg_per_hour(800.0, 10.0, 2.0, 6, 0.5, 1.0, 1.0)
	if absf(half - full * 0.5) > 1e-9:
		push_error("water_factor 0.5 should halve biomass")
		return 1
	var dry := PlantGrowthScript.biomass_kg_per_hour(800.0, 10.0, 2.0, 6, 0.0, 1.0, 1.0)
	if dry > 1e-12:
		push_error("water_factor 0 should zero biomass")
		return 1
	return 0


func _test_shade_factor() -> int:
	var full := PlantGrowthScript.biomass_kg_per_hour(800.0, 10.0, 2.0, 6, 1.0, 1.0, 1.0)
	var shaded := PlantGrowthScript.biomass_kg_per_hour(800.0, 10.0, 2.0, 6, 1.0, 1.0, 0.4)
	if absf(shaded - full * 0.4) > 1e-9:
		push_error("sunlight_factor 0.4 should scale biomass 0.4×")
		return 1
	return 0


func _test_season_summer_gt_winter() -> int:
	var summer := PlantGrowthScript.potential_biomass_kg_h(800.0, 10.0, 2.0, 6)
	var winter := PlantGrowthScript.potential_biomass_kg_h(800.0, 10.0, 2.0, 1)
	if summer <= winter:
		push_error("June potential should exceed January")
		return 1
	return 0


func _test_demands() -> int:
	var w := PlantGrowthScript.water_demand_lph(0.01, 50.0)
	if absf(w - 0.5) > 1e-9:
		push_error("water demand expected 0.5 L/h got %.4f" % w)
		return 1
	var n := PlantGrowthScript.nutrient_demand_kgph(0.01, 0.02)
	if absf(n - 0.0002) > 1e-12:
		push_error("nutrient demand expected 0.0002 kg/h got %.6f" % n)
		return 1
	return 0


func _test_area_soi() -> int:
	var specs := {"area_m2": 5.0, "use_soi_area": true}
	var a := PlantGrowthScript.effective_area_m2(specs, 100.0)
	if absf(a - 100.0) > 0.01:
		push_error("use_soi_area should take SoI area got %.1f" % a)
		return 1
	var a2 := PlantGrowthScript.effective_area_m2({"area_m2": 5.0}, 100.0)
	if absf(a2 - 5.0) > 0.01:
		push_error("manual area expected 5 got %.1f" % a2)
		return 1
	# PAR fraction sanity vs SolarIrradiance
	var par := SolarIrradianceScript.par_wm2_from_ghi(1000.0)
	if absf(par - 450.0) > 0.01:
		push_error("PAR fraction mismatch")
		return 1
	return 0
