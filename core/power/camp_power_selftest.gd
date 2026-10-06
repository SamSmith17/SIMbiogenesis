extends SceneTree

## Headless self-test for the simplified per-camp energy model
## (core/power/camp_power_model.gd): SOC conservation through the shared
## EnergyTimeline step, the floor, unserved load, the night lighting term,
## camps stepping independently, and the style defaults. Run --import first.
##   godot --headless --path . --script core/power/camp_power_selftest.gd

const EXPECTED_CHECKS := 21

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_defaults()
	_test_load_profile()
	_test_charge_and_drain()
	_test_floor_and_unserved()
	_test_independence()
	_test_daily_balance()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("CAMP POWER SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CAMP POWER SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_defaults() -> void:
	for style in ["theme_camp", "rv_park", "mixed", "glamping", "car_camping", "tent_village"]:
		var d := CampPowerModel.defaults_for(style)
		_check("%s has the four power numbers" % style, d.has("pv_wp") and d.has("battery_kwh")
			and d.has("inverter_w") and d.has("base_load_w"))
	_check("an unknown style falls back to mixed",
		CampPowerModel.defaults_for("yurt_city") == CampPowerModel.defaults_for("mixed"))
	_check("a tent village is unpowered", float(CampPowerModel.defaults_for("tent_village")["pv_wp"]) == 0.0)


func _test_load_profile() -> void:
	var spec := CampPowerModel.defaults_for("mixed")
	var noon := CampPowerModel.load_kw(spec, 20, 12.0)
	var night := CampPowerModel.load_kw(spec, 20, 22.0)
	_check("lights add per-person load after dusk", night > noon
		and absf((night - noon) * 1000.0 - CampPowerModel.LIGHT_W_PER_PERSON * 20.0) < 1e-6)
	var big := spec.duplicate()
	big["inverter_w"] = 100.0
	_check("the inverter caps the load", absf(CampPowerModel.load_kw(big, 500, 22.0) - 0.1) < 1e-9)


func _test_charge_and_drain() -> void:
	var spec := {"pv_wp": 1000.0, "battery_kwh": 2.0, "inverter_w": 2000.0, "base_load_w": 100.0}
	var st := CampPowerModel.make_state(spec, 0.5)
	CampPowerModel.step(spec, st, 0, 12.0, 0.8, 1.0)
	# pv 0.8 kW − load 0.1 kW = +0.7 kW × 1 h × 0.95 = +0.665 kWh on 1.0
	_check("charging banks the net at the charge efficiency",
		absf(float(st["soc_kwh"]) - (1.0 + 0.7 * CampPowerModel.CHARGE_EFF)) < 1e-6, "soc=%.4f" % float(st["soc_kwh"]))
	_check("ac available while charging", bool(st["ac_available"]))
	var st2 := CampPowerModel.make_state(spec, 0.5)
	CampPowerModel.step(spec, st2, 0, 22.0, 0.0, 1.0)
	# night: load 0.1 kW × 1 h / 0.95 drawn
	_check("draining takes the load at the discharge efficiency",
		absf(float(st2["soc_kwh"]) - (1.0 - 0.1 / CampPowerModel.DISCHARGE_EFF)) < 1e-6)
	_check("hours_left counts to the floor",
		absf(float(st2["hours_left"]) - (float(st2["soc_kwh"]) - 0.2) / 0.1) < 1e-6)
	var full := CampPowerModel.make_state(spec, 1.0)
	CampPowerModel.step(spec, full, 0, 12.0, 0.8, 2.0)
	_check("a full battery stays at capacity", absf(float(full["soc_kwh"]) - 2.0) < 1e-9)


func _test_floor_and_unserved() -> void:
	var spec := {"pv_wp": 0.0, "battery_kwh": 1.0, "inverter_w": 2000.0, "base_load_w": 500.0}
	var st := CampPowerModel.make_state(spec, 0.2)
	CampPowerModel.step(spec, st, 0, 22.0, 0.0, 1.0)
	_check("the battery never drains below the floor", absf(float(st["soc_kwh"]) - 0.1) < 1e-9)
	_check("…and the load it could not carry is unserved", not bool(st["ac_available"])
		and float(st["deficit_kwh"]) > 0.3)
	var nobat := {"pv_wp": 500.0, "battery_kwh": 0.0, "inverter_w": 1000.0, "base_load_w": 100.0}
	var s2 := CampPowerModel.make_state(nobat)
	CampPowerModel.step(nobat, s2, 0, 12.0, 0.8, 1.0)
	_check("no battery: the sun carries the daytime load", bool(s2["ac_available"]))
	CampPowerModel.step(nobat, s2, 0, 22.0, 0.0, 1.0)
	_check("no battery: nothing at night", not bool(s2["ac_available"]))


func _test_independence() -> void:
	var a_spec := CampPowerModel.defaults_for("theme_camp")
	var b_spec := CampPowerModel.defaults_for("car_camping")
	var a := CampPowerModel.make_state(a_spec, 0.8)
	var b := CampPowerModel.make_state(b_spec, 0.8)
	for h in 48:
		var hour := fposmod(float(h), 24.0)
		var sun := maxf(sin((hour - 6.0) / 12.0 * PI), 0.0) * 0.85 if hour > 6.0 and hour < 18.0 else 0.0
		CampPowerModel.step(a_spec, a, 30, hour, sun, 1.0)
		CampPowerModel.step(b_spec, b, 40, hour, sun, 1.0)
	_check("two camps step independently (the big one stays up, the small one does not)",
		CampPowerModel.soc_frac(a_spec, a) > 0.3 and float(b["deficit_kwh"]) > 0.0
		and float(a["deficit_kwh"]) < 1e-6, "a=%.2f b_deficit=%.2f" % [CampPowerModel.soc_frac(a_spec, a), float(b["deficit_kwh"])])


func _test_daily_balance() -> void:
	var bal := CampPowerModel.daily_balance(CampPowerModel.defaults_for("theme_camp"), 30, 5.0)
	_check("daily balance: PV at peak sun hours vs 24 h of load",
		absf(float(bal["pv_kwh"]) - 9.0) < 1e-6 and float(bal["load_kwh"]) > 5.0
		and absf(float(bal["net_kwh"]) - (float(bal["pv_kwh"]) - float(bal["load_kwh"]))) < 1e-9)
