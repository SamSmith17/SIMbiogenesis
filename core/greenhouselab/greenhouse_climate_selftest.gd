extends SceneTree

## Greenhouse climate self-test (offline):
##   Godot --headless --path . --script core/greenhouselab/greenhouse_climate_selftest.gd
## The energy ledger closes; a sunny closed house heats far above the air
## outside; single poly loses more on a clear night than polycarbonate; a sunk
## house with barrels has warmer nights and a smaller daily swing; vents and
## fans hold a hot day down; the crop raises the humidity and fans lower it;
## the glazing sweats on a cold humid night; lights add to the day's light;
## the heater holds its setpoint; rain off the roof; the controller's
## hysteresis and overrides; determinism.

const EXPECTED_CHECKS := 26

var _n := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	_test_ledger()
	_test_sun_and_nights()
	_test_mass_and_ground()
	_test_hot_day()
	_test_humidity()
	_test_lights_heater_rain()
	_test_control()
	if _n != EXPECTED_CHECKS:
		print("FAIL: ran %d checks, expected %d (a test function aborted?)" % [_n, EXPECTED_CHECKS])
		_fails += 1
	print("GREENHOUSE CLIMATE SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


## Synthetic weather at hour-of-run `h`: a daily temperature wave, the sun up
## 6..18 peaking at `el_max`, `ghi_max` at noon.
func _wx(h: float, mean: float, amp: float, el_max: float, ghi_max: float, cloud: float = 0.1,
		rh: float = 70.0, wind: float = 2.0) -> Dictionary:
	var hod := fposmod(h, 24.0)
	var el := -10.0
	var ghi := 0.0
	if hod > 6.0 and hod < 18.0:
		var s := sin(PI * (hod - 6.0) / 12.0)
		el = el_max * s
		ghi = ghi_max * s
	return {"t_out": mean + amp * cos(TAU * (hod - 15.0) / 24.0), "rh_out": rh, "wind": wind, "ghi": ghi,
		"cloud": cloud, "sun_az": 90.0 + (hod - 6.0) * 15.0, "sun_el": el, "rain_mmh": 0.0, "doy": 15.0,
		"hour": hod, "abs_h": 10000.0 * 24.0 + h, "has_real": true}


func _model(spec: Dictionary, monthly: Array = []) -> Dictionary:
	var mc := monthly if not monthly.is_empty() else [-2.0, 0.0, 4.0, 9.0, 14.0, 18.0, 21.0, 20.0, 16.0, 10.0, 4.0, 0.0]
	return GreenhouseClimate.model(GreenhouseDesign.solve(spec), {"monthly_c": mc})


## Run `hours` at `dt` under weather `wx_fn(h)`; returns {min, max, last, st}.
func _run(m: Dictionary, wx_fn: Callable, hours: float, dt: float = 0.25, extra: Dictionary = {}) -> Dictionary:
	var w0: Dictionary = wx_fn.call(0.0)
	var st := GreenhouseClimate.initial_state(m, float(w0["t_out"]), float(w0["rh_out"]), float(w0["doy"]))
	var lo := INF
	var hi := -INF
	var last := {}
	var h := 0.0
	while h < hours - 1e-6:
		var inp: Dictionary = wx_fn.call(h)
		for k in extra:
			inp[k] = extra[k]
		last = GreenhouseClimate.step(m, st, inp, dt)
		if h >= 24.0:
			lo = minf(lo, float(last["t_air"]))
			hi = maxf(hi, float(last["t_air"]))
		h += dt
	return {"min": lo, "max": hi, "last": last, "st": st}


func _test_ledger() -> void:
	var spec := GreenhouseSpec.resolve({"form": "gable", "width_m": 6.0, "length_m": 12.0, "eave_h_m": 2.2,
		"ridge_h_m": 3.6, "mass": {"barrels": 10}, "fans": {"count": 1}, "heater": "electric_1500",
		"beds": {"lights": true}, "ground": {"sink_m": 0.5}})
	var m := _model(spec)
	var r := _run(m, func(h: float) -> Dictionary: return _wx(h, 6.0, 7.0, 35.0, 600.0), 72.0)
	var lg: Dictionary = r["st"]["ledger"]
	var ins := float(lg["sun"]) + float(lg["heater"]) + float(lg["lights"]) + float(lg["ground"])
	var outs := float(lg["skin"]) + float(lg["longwave"]) + float(lg["vent"]) + float(lg["latent"])
	var err := absf(ins - outs - float(lg["stored"])) / maxf(absf(float(lg["sun"])), 1.0)
	_ok(err < 1e-6, "the energy ledger closes (%.9f of the sun)" % err)
	_ok(float(lg["sun"]) > 0.0 and float(lg["skin"]) > 0.0, "the sun came in and heat went out through the skin")
	# Same substeps → identical results whatever the outer step.
	var a := _run(m, func(h: float) -> Dictionary: return _wx(h, 6.0, 7.0, 35.0, 600.0), 30.0, 1.0)
	var b := _run(m, func(h: float) -> Dictionary: return _wx(h, 6.0, 7.0, 35.0, 600.0), 30.0, 0.25)
	_ok(absf(float(a["last"]["t_air"]) - float(b["last"]["t_air"])) < 0.6,
		"hour steps and quarter-hour steps agree (%.2f vs %.2f)" % [float(a["last"]["t_air"]), float(b["last"]["t_air"])])
	var c := _run(m, func(h: float) -> Dictionary: return _wx(h, 6.0, 7.0, 35.0, 600.0), 30.0, 1.0)
	_ok(float(a["last"]["t_air"]) == float(c["last"]["t_air"]), "deterministic")


func _test_sun_and_nights() -> void:
	# A closed polycarbonate house on a sunny cold winter day.
	var pc := GreenhouseSpec.resolve({"form": "gable", "width_m": 6.0, "length_m": 12.0, "eave_h_m": 2.2,
		"ridge_h_m": 3.6, "glazing": {"roof": "pc_twin_8", "walls": "pc_twin_8", "ends": "pc_twin_8"}})
	var m := _model(pc)
	var shut := {"override": {"vent": 0.0, "fans": 0}}
	var r := _run(m, func(h: float) -> Dictionary: return _wx(h, -2.0, 4.0, 28.0, 550.0, 0.0), 48.0, 0.25, shut)
	_ok(float(r["max"]) > 0.0 + 18.0, "a closed house on a sunny winter day gets warm (peak %.1f °C, outside ~2)" % float(r["max"]))
	# Clear calm night: single poly passes long-wave, polycarbonate does not.
	var ps := pc.duplicate(true)
	ps["glazing"] = {"roof": "poly_single", "walls": "poly_single", "ends": "poly_single"}
	var night := func(h: float) -> Dictionary: return _wx(h, 2.0, 2.0, 0.0, 0.0, 0.0, 60.0, 0.5)
	var rp := _run(_model(GreenhouseSpec.resolve(ps)), night, 72.0, 0.25, shut)
	var rc := _run(m, night, 72.0, 0.25, shut)
	_ok(float(rp["min"]) < float(rc["min"]) - 1.0, "single poly loses more on a clear night (%.1f vs %.1f °C)" % [
		float(rp["min"]), float(rc["min"])])
	_ok(float(rp["last"]["t_soil"]) < float(rc["last"]["t_soil"]), "its beds cool more too")


func _test_mass_and_ground() -> void:
	var base := GreenhouseSpec.resolve({"form": "hoop", "width_m": 6.0, "length_m": 14.0, "eave_h_m": 1.2,
		"ridge_h_m": 3.4, "vents": {"sides": "none", "ends": false}})
	var wx := func(h: float) -> Dictionary: return _wx(h, -4.0, 6.0, 25.0, 450.0, 0.1)
	var shut := {"override": {"vent": 0.0}}
	var r0 := _run(_model(base), wx, 120.0, 0.25, shut)
	var mb := base.duplicate(true)
	mb["mass"]["barrels"] = 40
	var r1 := _run(_model(GreenhouseSpec.resolve(mb)), wx, 120.0, 0.25, shut)
	_ok(float(r1["min"]) > float(r0["min"]) + 1.0, "40 barrels lift the coldest night (%.1f vs %.1f °C)" % [
		float(r1["min"]), float(r0["min"])])
	_ok(float(r1["max"]) - float(r1["min"]) < float(r0["max"]) - float(r0["min"]),
		"and shrink the day's swing (%.1f vs %.1f)" % [float(r1["max"]) - float(r1["min"]), float(r0["max"]) - float(r0["min"])])
	var sk := base.duplicate(true)
	sk["ground"] = {"sink_m": 1.5, "berm": "north"}
	var r2 := _run(_model(GreenhouseSpec.resolve(sk)), wx, 120.0, 0.25, shut)
	_ok(float(r2["min"]) > float(r0["min"]), "a sunk, bermed house has warmer nights (%.1f vs %.1f °C)" % [
		float(r2["min"]), float(r0["min"])])
	var m0 := _model(base)
	_ok(GreenhouseClimate.ground_temp(m0, 15.0, 2.0, 0.0) > -2.0 + 2.0, "the ground 2 m down in January is warmer than the month's air")


func _test_hot_day() -> void:
	var s := GreenhouseSpec.resolve({"form": "gable", "width_m": 6.0, "length_m": 12.0, "eave_h_m": 2.2,
		"ridge_h_m": 3.6, "vents": {"ridge": true, "sides": "rollup", "side_h_m": 1.2}, "fans": {"count": 2, "kind": "fan_36"}})
	var m := _model(s)
	var hot := func(h: float) -> Dictionary: return _wx(h, 27.0, 6.0, 70.0, 950.0, 0.0, 40.0, 2.0)
	var shut := _run(m, hot, 48.0, 0.25, {"override": {"vent": 0.0, "fans": 0}})
	var auto := _run(m, hot, 48.0, 0.25)
	_ok(float(shut["max"]) > 50.0, "a shut house on a hot sunny day cooks (%.1f °C)" % float(shut["max"]))
	_ok(float(auto["max"]) < float(shut["max"]) - 15.0, "vents and fans keep it far cooler (%.1f °C)" % float(auto["max"]))
	_ok(float(auto["max"]) < 33.0 + 6.0, "within a few degrees of outside at the peak (%.1f, outside 33)" % float(auto["max"]))


func _test_humidity() -> void:
	var s := GreenhouseSpec.resolve({"form": "gable", "width_m": 6.0, "length_m": 12.0, "eave_h_m": 2.2,
		"ridge_h_m": 3.6, "fans": {"count": 1, "kind": "fan_24"}})
	var m := _model(s)
	var wx := func(h: float) -> Dictionary: return _wx(h, 16.0, 4.0, 45.0, 500.0, 0.3, 55.0)
	var shut := {"override": {"vent": 0.0, "fans": 0}}
	var crop := shut.duplicate(true)
	crop["lai"] = 3.0
	var bare := shut.duplicate(true)
	bare["lai"] = 0.0
	var rc := _run(m, wx, 36.0, 0.25, crop)
	var rb := _run(m, wx, 36.0, 0.25, bare)
	_ok(float(rc["last"]["rh"]) > float(rb["last"]["rh"]) + 5.0, "the crop raises the humidity (%.0f vs %.0f %%)" % [
		float(rc["last"]["rh"]), float(rb["last"]["rh"])])
	var fan := {"override": {"vent": 0.0, "fans": 1}, "lai": 3.0}
	var rf := _run(m, wx, 36.0, 0.25, fan)
	_ok(float(rf["last"]["rh"]) < float(rc["last"]["rh"]), "the fan lowers it (%.0f %%)" % float(rf["last"]["rh"]))
	# A cold humid night: the cover sweats.
	var cold := func(h: float) -> Dictionary: return _wx(h, 0.0, 2.0, 0.0, 0.0, 0.0, 95.0, 0.5)
	var rn := _run(m, cold, 36.0, 0.25, crop)
	_ok(float(rn["st"]["condensate_l"]) > 1.0, "the glazing collects condensation on a cold night (%.1f L)" % float(rn["st"]["condensate_l"]))
	_ok(float(rn["last"]["rh"]) <= 100.0 and float(rn["last"]["rh"]) > 80.0, "the air is near saturation, never past it")


func _test_lights_heater_rain() -> void:
	var s := GreenhouseSpec.resolve({"form": "gable", "width_m": 6.0, "length_m": 12.0, "eave_h_m": 2.2,
		"ridge_h_m": 3.6, "beds": {"lights": true}, "lights": {"ppfd": 200.0, "dli_target": 14.0, "photoperiod_h": 16.0}})
	var m := _model(s)
	var dull := func(h: float) -> Dictionary: return _wx(h, 3.0, 3.0, 15.0, 120.0, 0.9)
	var rl := _run(m, dull, 47.5, 0.25)
	var rd := _run(m, dull, 47.5, 0.25, {"override": {"lights": 0}})
	_ok(float(rl["last"]["dli"]) > float(rd["last"]["dli"]) + 3.0, "the lights add to a dull day's light (%.1f vs %.1f mol)" % [
		float(rl["last"]["dli"]), float(rd["last"]["dli"])])
	var dl := float(rl["last"]["dli"])
	_ok(dl <= 14.0 + 200.0 * 0.25 * 3600.0 / 1e6 + 0.5, "and stop once the target is reached (%.1f)" % dl)
	var h := GreenhouseSpec.resolve({"form": "gable", "width_m": 4.0, "length_m": 6.0, "eave_h_m": 2.0,
		"ridge_h_m": 3.0, "heater": "electric_5000", "control": {"heat_on_c": 5.0, "heat_off_c": 8.0}})
	var rh := _run(_model(h), func(t: float) -> Dictionary: return _wx(t, -8.0, 2.0, 0.0, 0.0, 0.5), 48.0)
	_ok(float(rh["min"]) > 3.5, "a 5 kW heater holds a small house near its setpoint at −8 °C (min %.1f)" % float(rh["min"]))
	var wet := _wx(12.0, 10.0, 0.0, 30.0, 100.0, 1.0)
	wet["rain_mmh"] = 5.0
	var st := GreenhouseClimate.initial_state(m, 10.0, 90.0)
	var out := GreenhouseClimate.step(m, st, wet, 0.25)
	var plan := float(GreenhouseDesign.solve(s)["stats"]["roof_plan_m2"])
	_ok(absf(float(out["rain_lph"]) - plan * 0.9 * 5.0) < 1e-6, "rain off the roof: plan area × 0.9 × mm/h")


func _test_control() -> void:
	var s := GreenhouseSpec.resolve({"form": "gable", "fans": {"count": 1}, "heater": "electric_1500",
		"control": {"vent_open_c": 24.0, "vent_full_c": 30.0, "fan_on_c": 29.0, "fan_off_c": 26.0}})
	var m := _model(s)
	var st := {"t_air": 27.0, "w": 0.008, "fans_on": false, "heater_on": false, "dli": 0.0}
	var c1 := GreenhouseControl.decide(m, st, {"hour": 13.0})
	_ok(absf(float(c1["vent"]) - 0.5) < 1e-6 and not bool(c1["fans"]), "at 27 °C: vents half open, fans still off")
	st["fans_on"] = true
	_ok(bool(GreenhouseControl.decide(m, st, {"hour": 13.0})["fans"]), "fans stay on in the hysteresis band")
	st["t_air"] = 25.0
	_ok(not bool(GreenhouseControl.decide(m, st, {"hour": 13.0})["fans"]), "and go off below fan_off")
	st["t_air"] = 32.0
	var c4 := GreenhouseControl.decide(m, st, {"hour": 13.0, "rain_mmh": 5.0}, {"heater": 1})
	_ok(float(c4["vent"]) <= GreenhouseControl.RAIN_VENT_MAX + 1e-6 and bool(c4["heater"]),
		"rain closes the vents down; an override switches the heater on")
