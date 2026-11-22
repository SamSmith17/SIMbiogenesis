extends SceneTree

## Power signatures (offline): a fridge's inrush, three of them starting together,
## the breaker and the inverter that do or do not trip, a battery that stops
## when it is full, a measured trace, and a scrub that does not keep the
## outage alignment.
##
## Carries EXPECTED_CHECKS; --import first.
##   godot --headless --path . --script system_graph/power_signature_selftest.gd

const EXPECTED_CHECKS := 34

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_steady()
	_test_fridge()
	_test_coincidence()
	_test_breaker()
	_test_inverter()
	_test_battery()
	_test_measured()
	_test_scrub()
	_test_long_window()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("POWER SIGNATURE SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _fridge() -> Dictionary:
	return {"signature_family": "inductive_cyclic", "avg_watts": 150.0, "max_watts": 400.0}


func _test_steady() -> void:
	var specs := {"signature_family": "steady", "avg_watts": 10.0}
	var step := PowerSignature.integrate(specs, 0.0, 1.0, -1.0, "")
	_ok(absf(float(step["peak_w"]) - float(step["mean_w"])) < 0.01, "steady: peak equals mean")
	_ok(absf(float(step["mean_w"]) - 10.0) < 0.01, "steady: mean is avg_watts")
	var plain := {"avg_watts": 50.0}
	_ok(absf(PowerSignature.mean_watts(plain) - 50.0) < 0.01, "no family stays the flat average")


func _test_fridge() -> void:
	var specs := _fridge()
	var shape := PowerSignature.describe(specs, "")
	var inrush := float(shape["inrush_w"])
	var run := float(shape["run_w"])
	_ok(inrush > 1500.0 and inrush < 2500.0, "fridge inrush is about 2000 W (got %.0f)" % inrush)
	_ok(absf(run - 400.0) < 1.0, "fridge run is max_watts")
	_ok(PowerSignature.watts_at(specs, 0.0, 0.0, "") > 1500.0, "at the cycle start the fridge is in inrush")
	_ok(absf(PowerSignature.watts_at(specs, 100.0 / 3600.0, 0.0, "") - run) < 1.0, "mid-run is the plateau")
	var valley := PowerSignature.watts_at(specs, 2000.0 / 3600.0, 0.0, "")
	_ok(valley < 5.0, "the off valley is standby (got %.1f)" % valley)
	var period_h := float(shape["period_s"]) / 3600.0
	var over := PowerSignature.integrate(specs, 0.0, period_h * 12.0, 0.0, "", -1.0, false)
	_ok(absf(float(over["mean_w"]) - 150.0) < 1.5, "twelve cycles average back to 150 W (got %.2f)" % float(over["mean_w"]))


func _test_coincidence() -> void:
	var specs := _fridge()
	var inrush := float(PowerSignature.describe(specs, "a")["inrush_w"])
	var loads: Array = []
	for id in ["a", "b", "c"]:
		loads.append({"id": id, "specs": specs, "breakers": ["brk"]})
	var shared := PowerSignature.coincide(loads, 0.0, 0.2 / 3600.0, 0.0)
	_ok(absf(float(shared["peak_w"]) - 3.0 * inrush) < 50.0,
		"three shared-origin fridges peak at 3x inrush (got %.0f)" % float(shared["peak_w"]))
	var spread: Array = [
		{"id": "a", "specs": specs, "origin_h": 0.0},
		{"id": "b", "specs": specs, "origin_h": -100.0 / 3600.0},
		{"id": "c", "specs": specs, "origin_h": -2000.0 / 3600.0},
	]
	var apart := PowerSignature.coincide(spread, 0.0, 0.15 / 3600.0, -1.0)
	var expect := 0.0
	for ld in spread:
		expect += PowerSignature.watts_at(specs, 0.0, float(ld["origin_h"]), str(ld["id"]))
	_ok(absf(float(apart["peak_w"]) - expect) < 30.0, "spread origins peak at the sum of each phase")
	_ok(float(apart["peak_w"]) < inrush * 2.2, "spread origins are not three inrushes (got %.0f)" % float(apart["peak_w"]))
	var br: Dictionary = shared["by_breaker"]
	var one: Dictionary = br.get("brk", {})
	_ok(float(one.get("peak_w", 0.0)) > inrush * 2.5, "the breaker sees the coincident peak")


func _test_breaker() -> void:
	var specs := BreakerTrip.make_specs("Kitchen", 15.0)
	var mean_only := BreakerTrip.step(specs, 450.0, 1.0)
	_ok(not bool(mean_only.get("tripped", false)), "450 W average does not trip a 15 A breaker")
	var spiked := BreakerTrip.step(specs, 450.0, 1.0, 6000.0)
	_ok(bool(spiked.get("tripped", false)), "6000 W peak trips the 15 A breaker")
	_ok(float(spiked.get("trip_amps", 0.0)) >= 30.0, "the trip is the magnetic element")


func _test_inverter() -> void:
	var surge := PowerSignature.inverter_decision(0.0, 6000.0, 0.5, 0.5, 2000.0, 4000.0, 10.0)
	_ok(bool(surge["tripped"]), "peak above the surge rating trips in one step")
	var headroom := PowerSignature.inverter_decision(0.0, 6000.0, 0.5, 0.0, 3500.0, 7000.0, 10.0)
	_ok(not bool(headroom["tripped"]) and float(headroom["elapsed_s"]) < 2.0,
		"a half-second spike under the surge does not trip")
	var held := PowerSignature.inverter_decision(0.0, 4000.0, 9.0, 0.0, 3500.0, 7000.0, 10.0)
	_ok(not bool(held["tripped"]), "nine sim seconds over the continuous rating holds")
	var trips := PowerSignature.inverter_decision(float(held["elapsed_s"]), 4000.0, 2.0, 0.0, 3500.0, 7000.0, 10.0)
	_ok(bool(trips["tripped"]), "the hold is sim time and trips once it elapses")
	var quiet := PowerSignature.inverter_decision(float(headroom["elapsed_s"]), 400.0, 0.0, 0.0, 3500.0, 7000.0, 10.0)
	_ok(absf(float(quiet["elapsed_s"])) < 0.01, "a quiet step resets the continuous hold")


func _test_battery() -> void:
	var specs := {"signature_family": "battery", "avg_watts": 45.0, "capacity_wh": 70.0}
	_ok(absf(PowerSignature.watts_at(specs, 10.0, 10.0) - 45.0) < 0.5, "a charge starts at the CC rate")
	_ok(PowerSignature.watts_at(specs, 10.0 + 20.0, 10.0) < 1.0, "the charge is idle once the pack is full")
	var over := PowerSignature.integrate(specs, 10.0, 30.0, 10.0, "", -1.0, false)
	_ok(absf(float(over["watt_hours"]) - 70.0) < 2.0,
		"energy delivered approaches the pack, not 45 W forever (got %.1f Wh)" % float(over["watt_hours"]))
	_ok(PowerSignature.watts_at(specs, 1.0e6, -1.0) < 1.0, "with no start stamp a battery is already full")
	_ok(absf(PowerSignature.mean_watts(specs) - 45.0) < 0.5, "the clockless rate stays the charge rate")


func _test_measured() -> void:
	var trace: Array = [[0.0, 10.0], [1.0, 30.0], [2.0, 10.0]]
	var specs := {"signature_family": "steady", "avg_watts": 12.0}
	specs.merge(PowerSignature.apply_trace(specs, trace, true), true)
	_ok(absf(PowerSignature.watts_at(specs, 0.0, 0.0, "") - 10.0) < 0.01, "measured sample at t=0")
	_ok(absf(PowerSignature.watts_at(specs, 1.0 / 3600.0, 0.0, "") - 30.0) < 0.01, "measured sample at the peak vertex")
	var parsed := PowerSignature.parse_csv("t_seconds,watts\n0,10\n1,30\n2,10\n")
	_ok(parsed.size() == 3 and absf(float(parsed[1][1]) - 30.0) < 0.01, "CSV skips the header")
	specs.merge(PowerSignature.clear_trace(specs), true)
	_ok(absf(PowerSignature.watts_at(specs, 1.0 / 3600.0, 0.0, "") - 12.0) < 0.01,
		"clearing the trace restores the generic mean")


func _test_scrub() -> void:
	var specs := _fridge()
	_ok(PowerSignature.watts_at(specs, 5.0, 10.0, "") < 5.0,
		"a window before the outage is not aligned to the inrush")
	_ok(PowerSignature.watts_at(specs, 10.0, 10.0, "") > 1500.0,
		"the restore hour itself is the shared inrush")


func _test_long_window() -> void:
	var specs := _fridge()
	var over := PowerSignature.integrate(specs, 0.0, 49.0, 0.0, "")
	_ok(absf(float(over["peak_w"]) - float(over["mean_w"])) < 1.0,
		"past 48 h the fault peak falls back to the mean")
	_ok(absf(float(over["watt_hours"]) - 150.0 * 49.0) < 150.0, "the long window's energy stays exact")
