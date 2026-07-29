extends SceneTree

## Offline self-test for the challenge pre-bake loop (ChallengeBakeEngine).
## Covers the pure/deterministic pieces: step-size policy vs the timeline
## sample caps, prebake ChallengeDef round-trip + span resolution, catalog
## prebake entries, the power-failure accumulator on canned series, and
## bake determinism (two identical EnergyTimeline fills → identical curves).


func _initialize() -> void:
	var fails := 0
	fails += _test_step_policy()
	fails += _test_prebake_def_round_trip()
	fails += _test_catalog_prebake_entries()
	fails += _test_power_fail_accumulator()
	fails += _test_series_fill_determinism()
	if fails == 0:
		print("CHALLENGE BAKE SELFTEST PASS  (5 checks)")
		quit(0)
	else:
		print("CHALLENGE BAKE SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


## Every span preset must fit MAX_SAMPLES with headroom at its chosen step.
func _test_step_policy() -> int:
	for dur in [24.0, 720.0, 8760.0]:
		var step := ChallengeBakeEngine.step_hours_for(float(dur))
		if step < 1.0 / 60.0 - 1e-9:
			push_error("step below one minute for %s h" % str(dur))
			return 1
		var samples := int(ceilf(float(dur) / step))
		if samples > EnergyTimeline.MAX_SAMPLES - 1000:
			push_error("%.0f h at %.4f h/step = %d samples — too close to MAX_SAMPLES" % [
				float(dur), step, samples])
			return 1
		# Steps are whole minutes so sample boundaries stay clean.
		var minutes := step * 60.0
		if absf(minutes - roundf(minutes)) > 1e-6:
			push_error("step for %s h is not a whole minute: %f" % [str(dur), step])
			return 1
	if absf(ChallengeBakeEngine.step_hours_for(24.0) - 1.0 / 60.0) > 1e-9:
		push_error("day span should bake at 1-minute steps")
		return 1
	return 0


func _test_prebake_def_round_trip() -> int:
	var def := ChallengeDef.from_dict({
		"id": "x", "run_mode": "prebake", "span": "month",
		"fail_on_power_failure": true, "fail_on_collapse": true,
		"min_pv_utilization_pct": 95.0,
	})
	if not def.is_prebake() or absf(def.resolved_duration_hours() - 720.0) > 0.01:
		push_error("prebake def span month should resolve to 720 h")
		return 1
	var back := ChallengeDef.from_dict(def.to_dict())
	if not back.is_prebake() or back.span != "month" \
			or not back.fail_on_power_failure or not back.fail_on_collapse \
			or absf(back.min_pv_utilization_pct - 95.0) > 0.01:
		push_error("prebake fields did not round-trip")
		return 1
	# Back-compat: a legacy dict with none of the new keys stays realtime.
	var legacy := ChallengeDef.from_dict({"id": "old", "duration_hours": 72.0})
	if legacy.is_prebake() or absf(legacy.resolved_duration_hours() - 72.0) > 0.01:
		push_error("legacy def must default to realtime / duration_hours")
		return 1
	return 0


func _test_catalog_prebake_entries() -> int:
	var day := ChallengeCatalog.by_id("keep_lights_on_day")
	var month := ChallengeCatalog.by_id("keep_lights_on_month")
	var loop_m := ChallengeCatalog.by_id("close_the_loop_month")
	if day == null or month == null or loop_m == null:
		push_error("prebake catalog entries missing")
		return 1
	if not day.is_prebake() or not day.fail_on_power_failure:
		push_error("prebake day entry misconfigured")
		return 1
	if absf(day.resolved_duration_hours() - 24.0) > 0.01 \
			or absf(month.resolved_duration_hours() - 720.0) > 0.01:
		push_error("prebake spans resolve wrong")
		return 1
	# Realtime originals untouched.
	var classic := ChallengeCatalog.by_id("keep_lights_on")
	if classic == null or classic.is_prebake() \
			or absf(classic.duration_hours - 72.0) > 0.01:
		push_error("classic keep_lights_on must stay realtime/72 h")
		return 1
	return 0


## Canned series: night discharge pins SOC at the floor with net<0 → the
## accumulator must reach the sustain threshold; any recovery resets it.
func _test_power_fail_accumulator() -> int:
	var floor_kwh := 1.6
	var step := 1.0 / 60.0
	var acc := 0.0
	# Healthy discharge above the floor: never accumulates.
	acc = ChallengeBakeEngine.power_fail_accumulate(acc, 5.0, -0.4, floor_kwh, step)
	if acc > 0.0:
		push_error("SOC above floor must not accumulate power-fail time")
		return 1
	# Pinned at the floor while net < 0: accumulates step by step.
	for i in 15:
		acc = ChallengeBakeEngine.power_fail_accumulate(acc, floor_kwh, -0.4, floor_kwh, step)
	if absf(acc - 15.0 * step) > 1e-6:
		push_error("pinned-at-floor accumulation wrong: %f" % acc)
		return 1
	if acc >= ChallengeBakeEngine.POWER_FAIL_SUSTAIN_H:
		push_error("15 minutes should sit exactly at the sustain threshold, not past it")
		return 1
	acc = ChallengeBakeEngine.power_fail_accumulate(acc, floor_kwh, -0.4, floor_kwh, step)
	if acc < ChallengeBakeEngine.POWER_FAIL_SUSTAIN_H - 1e-9:
		push_error("16th pinned minute should cross the 0.25 h sustain threshold")
		return 1
	# Sunrise (net > 0) resets even at the floor.
	acc = ChallengeBakeEngine.power_fail_accumulate(acc, floor_kwh, 0.3, floor_kwh, step)
	if acc != 0.0:
		push_error("positive net must reset the accumulator")
		return 1
	return 0


## Two identical fixed-step fills over the same synthetic evaluator must
## produce byte-identical SOC curves (the determinism the retry loop rests on).
func _test_series_fill_determinism() -> int:
	var curves: Array = []
	for run in 2:
		var tl := EnergyTimeline.new()
		tl.configure(16.0, 0.95, 0.95, 1.6)
		tl.step_hours = 3.0 / 60.0
		tl.set_evaluator(func(abs_h: float) -> Dictionary:
			var hod := fposmod(abs_h, 24.0)
			var solar := maxf(0.0, sin((hod - 6.0) / 12.0 * PI)) * 2.0
			return {"solar_kw": solar, "aux_kw": 0.0, "load_kw": 0.6})
		var start := 1000000.0
		tl.init_anchor(start, 8.0, 0.0, 0.0, 0.6)
		var target := tl.step_of(start + 720.0)
		while tl.last_step() < target:
			tl.fill_forward_chunk(target, 2000)
		var sig := PackedFloat32Array()
		for h in range(0, 720, 7):
			sig.append(float(tl.sample_at(start + float(h)).get("soc_kwh", -1.0)))
		curves.append(sig)
	var a: PackedFloat32Array = curves[0]
	var b: PackedFloat32Array = curves[1]
	if a.size() != b.size():
		push_error("determinism: sample counts differ")
		return 1
	for i in a.size():
		if a[i] != b[i]:
			push_error("determinism: SOC diverged at index %d (%f vs %f)" % [i, a[i], b[i]])
			return 1
	# And the curve actually moved (guard against a trivially-flat fill).
	var moved := false
	for i in a.size():
		if absf(a[i] - a[0]) > 0.1:
			moved = true
			break
	if not moved:
		push_error("determinism check series never changed — evaluator not applied?")
		return 1
	return 0
