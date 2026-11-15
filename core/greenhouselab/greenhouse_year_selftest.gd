extends SceneTree

## GreenhouseCrops + GreenhouseYear (offline, synthetic weather):
##   Godot --headless --path . --script core/greenhouselab/greenhouse_year_selftest.gd
## Crops: nothing grows below the base temperature, warmth speeds a cycle,
## a hard frost loses the planting, lights add growth on a lit bed, harvests
## reach a sane yield. Year: a hoop house at 45°N is warmer than outside in
## winter, ventilates in summer, catches the rain on its roof plan, the
## walipini's coldest night beats a single-poly hoop's, a lit bed adds light
## kWh, the run is deterministic, and it takes how long (printed).

const EXPECTED_CHECKS := 17

var _n := 0
var _fails := 0


func _ok(c: bool, what: String) -> void:
	_n += 1
	if not c:
		_fails += 1
	print("%s: %s" % ["PASS" if c else "FAIL", what])


func _initialize() -> void:
	_test_crops()
	_test_year()
	if _n != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [_n, EXPECTED_CHECKS])
		_fails += 1
	print("GREENHOUSE YEAR SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _one_bed(crop: String, lit: bool = false) -> Dictionary:
	var bed := {"id": "b1", "area_m2": 10.0, "crops": [{"crop": crop, "share": 1.0}]}
	if lit:
		bed["light"] = {"w": 500.0}
	return {"beds": [bed]}


func _days(st: Dictionary, n: int, dy: Dictionary) -> float:
	var kg := 0.0
	for i in n:
		var got := GreenhouseCrops.day(st, dy)
		for k in got:
			kg += float(got[k])
	return kg


func _test_crops() -> void:
	var cold := GreenhouseCrops.new_state(_one_bed("tomato"))
	_days(cold, 60, {"t_mean": 6.0, "t_min": 3.0, "vpd": 0.8, "dli_sun": 15.0})
	_ok(float(cold["growth_kg_dm"]) < 1e-6 and float(cold["plots"][0]["tt"]) < 1e-6,
		"a tomato below its base temperature neither grows nor develops")
	var warm := GreenhouseCrops.new_state(_one_bed("lettuce"))
	var cool := GreenhouseCrops.new_state(_one_bed("lettuce"))
	_days(warm, 20, {"t_mean": 20.0, "t_min": 14.0, "vpd": 0.8, "dli_sun": 17.0})
	_days(cool, 20, {"t_mean": 10.0, "t_min": 6.0, "vpd": 0.8, "dli_sun": 17.0})
	_ok(float(warm["plots"][0]["tt"]) > 1.5 * float(cool["plots"][0]["tt"]), "warmth speeds a lettuce cycle")
	var froze := GreenhouseCrops.new_state(_one_bed("tomato"))
	_days(froze, 1, {"t_mean": 4.0, "t_min": -4.0, "vpd": 0.5, "dli_sun": 8.0})
	_ok(int(froze["lost"]) == 1 and int(froze["frost_days"]) == 1, "a hard frost loses the tomato planting")
	var dark := GreenhouseCrops.new_state(_one_bed("lettuce"))
	var lit := GreenhouseCrops.new_state(_one_bed("lettuce", true))
	_days(dark, 30, {"t_mean": 18.0, "t_min": 12.0, "vpd": 0.8, "dli_sun": 6.0, "dli_lit": 16.0})
	_days(lit, 30, {"t_mean": 18.0, "t_min": 12.0, "vpd": 0.8, "dli_sun": 6.0, "dli_lit": 16.0})
	_ok(float(lit["growth_kg_dm"]) > 2.0 * float(dark["growth_kg_dm"]), "grow lights add growth on a lit bed")
	var y := GreenhouseCrops.new_state(_one_bed("lettuce"))
	var kg := _days(y, 140, {"t_mean": 18.0, "t_min": 12.0, "vpd": 0.8, "dli_sun": 17.0})
	var table := float(CropPhysiology.info("lettuce")["yield"]) * 10.0
	_ok(int(y["cycles"]) >= 2 and kg > 0.5 * table and kg <= GreenhouseCrops.YIELD_CAP * table * float(y["cycles"]) + 1e-3,
		"lettuce harvests %d cycles, %.1f kg on 10 m² (table %.0f kg a cycle)" % [int(y["cycles"]), kg, table])
	var mixed := GreenhouseCrops.new_state({"beds": [{"id": "b", "area_m2": 12.0, "crops": "garden"}]})
	var a := 0.0
	for p in mixed["plots"]:
		a += float(p["area"])
	_ok(absf(a - 12.0) < 1e-3 and (mixed["plots"] as Array).size() > 1, "a garden bed splits its area between its crops")
	_ok(GreenhouseCrops.lai(warm) > GreenhouseCrops.lai(cool), "a further-on canopy transpires through more leaf")


func _test_year() -> void:
	var hoop := GreenhouseDesign.solve(GreenhousePresets.builtin("backyard_hoop")["spec"])
	var tbl := GreenhouseYear.weather_table(45.0, -120.0, null)
	_ok(not bool(tbl["real"]) and (tbl["data"] as PackedFloat32Array).size() == 365 * 24 * GreenhouseYear.COLS,
		"with no weather service the year is synthetic, 8760 hours")
	var mc: Array = tbl["monthly_c"]
	_ok(float(mc[0]) < float(mc[6]) - 10.0, "the synthetic year at 45°N has a winter (%.1f °C) and a summer (%.1f °C)" % [float(mc[0]), float(mc[6])])
	var t0 := Time.get_ticks_msec()
	var r := GreenhouseYear.run(hoop, tbl)
	var ms := Time.get_ticks_msec() - t0
	print("greenhouse year: backyard hoop, 365 days at 1 h in %d ms" % ms)
	var jan: Dictionary = r["months"][0]
	var jul: Dictionary = r["months"][6]
	_ok(float(jan["in_mean"]) > float(jan["out_mean"]) + 1.0, "January: inside %.1f °C vs outside %.1f °C" % [float(jan["in_mean"]), float(jan["out_mean"])])
	_ok(float(jul["vent_h"]) > 100.0, "July: the vents open (%.0f h)" % float(jul["vent_h"]))
	var tot: Dictionary = r["total"]
	var roof := float(hoop["stats"]["roof_plan_m2"])
	var rain_mm := 0.0
	var data: PackedFloat32Array = tbl["data"]
	for i in range(5, data.size(), GreenhouseYear.COLS):
		rain_mm += data[i]
	_ok(absf(float(tot["rain_l"]) - roof * 0.9 * rain_mm) < 1.0 + 0.01 * roof * rain_mm,
		"the roof catches %.0f L of %.0f mm on %.0f m²" % [float(tot["rain_l"]), rain_mm, roof])
	_ok(float(tot["yield_kg"]) > 0.0 and (tot["harvest"] as Dictionary).size() > 0,
		"the beds harvest %.0f kg (%.1f kg/m²) over the year" % [float(tot["yield_kg"]), float(tot["yield_kg_m2"])])
	_ok(ms < 20000, "a year runs in under 20 s (%d ms)" % ms)
	var wal := GreenhouseDesign.solve(GreenhousePresets.builtin("walipini")["spec"])
	var rw := GreenhouseYear.run(wal, tbl)
	_ok(float(rw["total"]["coldest_in"]) > float(tot["coldest_in"]) + 2.0,
		"the walipini's coldest hour (%.1f °C) beats the hoop's (%.1f °C)" % [float(rw["total"]["coldest_in"]), float(tot["coldest_in"])])
	var spec_l: Dictionary = GreenhousePresets.builtin("backyard_hoop")["spec"].duplicate(true)
	spec_l["lights"]["on"] = true
	spec_l["beds"]["lights"] = true
	var rl := GreenhouseYear.run(GreenhouseDesign.solve(spec_l), tbl, {"days": 60})
	_ok(float(rl["total"]["lights_kwh"]) > 10.0, "grow lights over the beds use %.0f kWh in two winter months" % float(rl["total"]["lights_kwh"]))
	var r2 := GreenhouseYear.run(hoop, tbl, {"days": 30})
	var r3 := GreenhouseYear.run(hoop, tbl, {"days": 30})
	_ok(is_equal_approx(float(r2["total"]["vent_h"]), float(r3["total"]["vent_h"]))
		and float(r2["months"][0]["in_min"]) == float(r3["months"][0]["in_min"]), "two runs agree exactly")
