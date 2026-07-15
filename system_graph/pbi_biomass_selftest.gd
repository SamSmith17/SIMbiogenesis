extends SceneTree

## Offline checks for SoI-scaled biomass PBI math.

const PbiBiomassScript := preload("res://system_graph/pbi_biomass.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_season_factor()
	fails += _test_effective_area()
	fails += _test_catchment_output_kind()
	fails += _test_biomass_rates()
	if fails == 0:
		print("PBI BIOMASS SELFTEST PASS  (4 checks)")
		quit(0)
	else:
		print("PBI BIOMASS SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _test_season_factor() -> int:
	var jan := PbiBiomassScript.season_factor(1)
	var jul := PbiBiomassScript.season_factor(7)
	var dec := PbiBiomassScript.season_factor(12)
	if jan < 0.35 or jan > 1.0:
		push_error("season_factor Jan out of range got %.3f" % jan)
		return 1
	if jul < jan:
		push_error("season_factor July should exceed January")
		return 1
	if jul < 0.9 or jul > 1.01:
		push_error("season_factor July expected ~1.0 got %.3f" % jul)
		return 1
	if dec < 0.35 or dec > 1.0:
		push_error("season_factor Dec out of range got %.3f" % dec)
		return 1
	return 0


func _test_effective_area() -> int:
	var manual := PbiBiomassScript.effective_area_m2({"area_m2": 42.0}, 0.0)
	if absf(manual - 42.0) > 0.01:
		push_error("effective_area manual expected 42 got %.2f" % manual)
		return 1
	var soi := PbiBiomassScript.effective_area_m2(
			{"use_soi_area": true, "area_m2": 10.0}, 314159.0)
	if absf(soi - 314159.0) > 0.01:
		push_error("effective_area SoI expected 314159 got %.2f" % soi)
		return 1
	return 0


func _test_catchment_output_kind() -> int:
	if PbiBiomassScript.catchment_output_kind({"catchment_kind": "rain"}) != "water":
		push_error("catchment_output_kind rain should be water")
		return 1
	if PbiBiomassScript.catchment_output_kind({"catchment_kind": "biomass"}) != "biomass":
		push_error("catchment_output_kind biomass should be biomass")
		return 1
	return 0


func _test_biomass_rates() -> int:
	var area := 10000.0
	var month := 6
	var kg_h := PbiBiomassScript.biomass_kg_per_hour(area, month)
	var kg_d := PbiBiomassScript.biomass_kg_per_day(area, month)
	if kg_h <= 0.0:
		push_error("biomass_kg_per_hour should be positive")
		return 1
	if absf(kg_d - kg_h * 24.0) > 0.001:
		push_error("kg/day should equal 24× kg/h")
		return 1
	var expected := area * PbiBiomassScript.NPP_KG_M2_YR / PbiBiomassScript.HOURS_PER_YEAR
	expected *= PbiBiomassScript.season_factor(month)
	if absf(kg_h - expected) > 0.01:
		push_error("biomass_kg_per_hour formula mismatch got %.4f expected %.4f" % [kg_h, expected])
		return 1
	return 0
