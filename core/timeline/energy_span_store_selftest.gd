extends SceneTree

## EnergySpanStore (offline): the timeline's persistent solar / load / battery
## curves. A scrub must not erase minutes already simulated; a fill walks both
## ways from the nearest known minute; lived samples win over the fill; load
## peaks stay a band above the average. Run:
##   Godot --headless --path . --script core/timeline/energy_span_store_selftest.gd

const EXPECTED_CHECKS := 22

var _checks := 0
var _fails := 0


func _init() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	print(("  PASS  " if cond else "  FAIL  ") + what)
	if not cond:
		_fails += 1


func _near(a: float, b: float, eps: float = 1e-3) -> bool:
	return absf(a - b) <= eps


func _limits() -> Dictionary:
	return {"cap": 100.0, "ceff": 1.0, "deff": 1.0, "min_kwh": 0.0, "max_c": INF, "max_d": INF}


func _eval(_abs_h: float, _soc: float) -> Dictionary:
	return {"solar_kw": 1.0, "aux_kw": 0.0, "load_kw": 0.0, "load_peak_kw": 1.0, "raw_kw": 1.0}


func _minute(abs_h: float) -> int:
	return int(floor(abs_h * 60.0))


func _lived(store: EnergySpanStore, abs_h: float, soc: float, solar: float, load: float, peak: float) -> void:
	var g := _minute(abs_h)
	store.write_lived_run(g, PackedFloat32Array([soc]), PackedFloat32Array([solar]),
		PackedFloat32Array([0.0]), PackedFloat32Array([load]), PackedFloat32Array([peak]),
		PackedFloat32Array([solar]))


func _run() -> void:
	var S := EnergySpanStore
	var step := 1.0 / 60.0
	_ok(not S.jump_is_scrub(0.01, 0.01, step), "a played tick is not a scrub")
	_ok(S.jump_is_scrub(24.0, 0.0, step), "a day jump while paused is a scrub")
	_ok(S.jump_is_scrub(-24.0, 0.0, step), "a day jump backward is a scrub")
	_ok(not S.jump_is_scrub(1.0, 0.6, step), "one hour inside a fast tick is still play")
	_ok(S.jump_is_scrub(3.0, 0.6, step), "three hours in that same tick is a scrub")

	# Lived minute, then fill two hours forward. The lived sample stays, and
	# SOC at the landing is the integral of 1 kW for those two hours.
	var fwd := EnergySpanStore.new()
	_lived(fwd, 1000.0, 10.0, 0.25, 0.0, 0.25)
	fwd.note_window(1000.0, 1002.0, 1002.0, step)
	var n := fwd.pump(1000000, Callable(self, "_eval"), 1002.0, 10.0, _limits())
	_ok(n > 0, "the forward fill writes the hole (%d samples)" % n)
	var seed := fwd.sample_minute(_minute(1000.0))
	_ok(_near(float(seed.get("solar_kw", -1.0)), 0.25), "the lived minute is still the lived solar")
	_ok(_near(fwd.soc_at_hours(1002.0), 12.0), "two hours at 1 kW lifts SOC from 10 to 12")
	var landing := fwd.sample_minute(_minute(1002.0))
	_ok(_near(float(landing.get("solar_kw", -1.0)), 1.0), "the filled landing uses the evaluator")
	_ok(fwd.pump(1000000, Callable(self, "_eval"), 1002.0, 10.0, _limits()) == 0,
		"a second pass writes nothing")

	# Panning away and filling somewhere else does not drop the lived minute.
	fwd.note_window(1100.0, 1101.0, 1100.5, step)
	fwd.pump(1000000, Callable(self, "_eval"), 1100.5, 10.0, _limits())
	var still := fwd.sample_minute(_minute(1000.0))
	_ok(_near(float(still.get("solar_kw", -1.0)), 0.25), "a scrub to another day keeps the lived minute")

	fwd.truncate_after_hours(1000.5)
	_ok(fwd.sample_minute(_minute(1002.0)).is_empty(), "truncate drops the filled future")
	_ok(_near(float(fwd.sample_minute(_minute(1000.0)).get("solar_kw", -1.0)), 0.25),
		"truncate keeps the lived past")

	# Backward from the same lived minute.
	var back := EnergySpanStore.new()
	_lived(back, 1000.0, 10.0, 0.25, 0.0, 0.25)
	back.note_window(998.0, 1000.0, 998.0, step)
	back.pump(1000000, Callable(self, "_eval"), 998.0, 10.0, _limits())
	_ok(_near(back.soc_at_hours(998.0), 8.0), "two hours backward at 1 kW lowers SOC from 10 to 8")
	_ok(_near(float(back.sample_minute(_minute(1000.0)).get("solar_kw", -1.0)), 0.25),
		"the backward fill does not rewrite the lived minute")

	# The load band: average 0.4, one minute peaking at 6.
	var peaks := EnergySpanStore.new()
	_lived(peaks, 2000.0, 10.0, 0.0, 0.4, 6.0)
	var g := TimelineBinning.grid(2000.0, 2000.0 + step, step)
	var pbins := peaks.bins("load_kw", step, int(g["i0"]), int(g["n"]), 100.0)
	_ok(int(g["n"]) >= 1 and _near(pbins["mean"][0], 0.4) and _near(pbins["mx"][0], 6.0) and _near(pbins["mn"][0], 0.4),
		"a stored spike lifts the load band and leaves the mean")

	# Zoomed out: one sample an hour across the window, SOC stepped by the hour.
	var wide := EnergySpanStore.new()
	wide.note_window(1000.0, 1006.0, 1003.0, 2.0)
	wide.pump(1000000, Callable(self, "_eval"), 1003.0, 10.0, _limits())
	_ok(wide.hour_count() >= 6, "an hourly zoom fills the window (%d hours)" % wide.hour_count())
	_ok(_near(wide.soc_at_hours(1004.0), 11.0), "the next hour is one kWh above the anchor")
	var hg := TimelineBinning.grid(1000.0, 1006.0, 2.0)
	var hbins := wide.bins("solar_kw", 2.0, int(hg["i0"]), int(hg["n"]), 100.0)
	var finite := true
	for i in int(hg["n"]):
		finite = finite and not is_nan(hbins["mean"][i])
	_ok(finite, "every hourly bin in the window has a value")

	# The live tape can be re-stamped and copied without losing the tail.
	var et := EnergyTimeline.new()
	et.configure(100.0, 1.0, 1.0, 0.0)
	et.init_anchor(0.0, 10.0, 0.0, 0.0, 0.0)
	et.record_step(step, 1.0, 0.0, 0.0)
	et.restamp_soc(20.0)
	_ok(_near(et.soc_at(0.0), 20.0) and _near(et.soc_at(step), 20.0 + step),
		"restamp rebuilds the tape from the corrected SOC")
	var sl := et.slice_from(et.first_step())
	_ok((sl["soc"] as PackedFloat32Array).size() == 2, "slice_from copies the tape")
	et.append_known(step * 2.0, 21.0, 1.0, 0.0, 0.0, 1.0, 1.0)
	_ok(_near(et.soc_at(step * 2.0), 21.0), "append_known writes the span's SOC straight through")

	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL  ran %d checks, expected %d (a runtime error aborted a test?)" % [_checks, EXPECTED_CHECKS])
	print("energy_span_store_selftest: %d checks, %d failures — %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(1 if _fails > 0 else 0)
