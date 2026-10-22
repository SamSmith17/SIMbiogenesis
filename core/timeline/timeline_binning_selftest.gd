extends SceneTree

## TimelineBinning (offline): the timeline's zoom-stable downsampling.
##   * the ladder: one bin per ~3 px, never finer than the data;
##   * ANCHORING: a bin is the same interval wherever the window sits, so two
##     windows a fraction of a bin apart give identical values for every bin
##     they share (the old window-relative bins resampled on every pan);
##   * NESTING: at the next ladder level a bin's min / max are exactly the min /
##     max of the finer bins inside it, its mean their average — zooming out
##     merges, it never reshapes;
##   * a 10-minute SAWTOOTH sampled every minute keeps its full 0..9 range at
##     every zoom (the old mean-per-bin smoothed it to a flat line at some
##     levels and not others);
##   * the hourly-linear weather reader: exact trapezoid mean, edges shared;
##   * step readings (Home Assistant): time-weighted mean, the held value
##     counted in min / max, gaps, nothing after NOW.
## Run: Godot --headless --path . --script core/timeline/timeline_binning_selftest.gd

const EXPECTED_CHECKS := 26

var _checks := 0
var _fails := 0


func _init() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	print(("  PASS  " if cond else "  FAIL  ") + what)
	if not cond:
		_fails += 1


func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps


func _run() -> void:
	var B := TimelineBinning
	# ---- ladder ----
	_ok(_near(B.bin_width(24.0, 1200.0), 5.0 / 60.0, 1e-4), "24 h over 1200 px wants 3.6 min → the 5-minute rung")
	_ok(_near(B.bin_width(168.0, 1200.0), 0.5), "a week → 30-minute bins")
	_ok(_near(B.bin_width(1.0, 1200.0, 1.0 / 60.0), 1.0 / 60.0), "never finer than one sample")
	_ok(B.bin_width(120.0 * 8766.0, 1200.0) >= 2000.0, "120 years still has a width")
	var g := B.grid(10.3, 12.9, 0.5)
	_ok(int(g["i0"]) == 20 and int(g["n"]) == 6, "grid anchored to multiples of the width (%s)" % str(g))

	# ---- a sawtooth, one sample a minute, 10-minute period, 0..9 ----
	var vals := PackedFloat32Array()
	for j in 60 * 48:
		vals.append(float(j % 10))
	var base := 1000.0
	var step := 1.0 / 60.0
	var w1 := 1.0
	var g1 := B.grid(base, base + 48.0, w1)
	var r1 := B.from_regular(vals, base, step, w1, int(g1["i0"]), int(g1["n"]))
	var ok_saw := true
	for k in int(g1["n"]):
		ok_saw = ok_saw and _near(r1["mn"][k], 0.0) and _near(r1["mx"][k], 9.0) and _near(r1["mean"][k], 4.5)
	_ok(ok_saw, "1 h bins: every bin keeps the sawtooth's 0..9 range, mean 4.5")
	var r2 := B.from_regular(vals, base, step, 0.25, int(B.grid(base, base + 48.0, 0.25)["i0"]), int(B.grid(base, base + 48.0, 0.25)["n"]))
	_ok(_near(r2["mn"][3], 0.0) and _near(r2["mx"][3], 9.0), "15-minute bins too")
	var r3 := B.from_regular(vals, base, step, 2.0 / 60.0, int(B.grid(base, base + 1.0, 2.0 / 60.0)["i0"]), 30)
	_ok(_near(r3["mn"][0], 0.0) and _near(r3["mx"][0], 1.0) and _near(r3["mn"][1], 2.0), "2-minute bins resolve the teeth (0–1, 2–3 …)")

	# ---- anchoring: a pan by a fraction of a bin changes nothing shared ----
	var wa := 0.5
	var ga := B.grid(base + 3.10, base + 20.0, wa)
	var gb := B.grid(base + 3.37, base + 20.27, wa)
	var smooth := PackedFloat32Array()
	for j in 60 * 48:
		smooth.append(sin(float(j) * 0.013) * 5.0 + float(j % 7))
	var ra := B.from_regular(smooth, base, step, wa, int(ga["i0"]), int(ga["n"]))
	var rb := B.from_regular(smooth, base, step, wa, int(gb["i0"]), int(gb["n"]))
	var same := true
	var off := int(gb["i0"]) - int(ga["i0"])
	for k in int(gb["n"]):
		var ka := k + off
		if ka < 0 or ka >= int(ga["n"]):
			continue
		same = same and ra["mean"][ka] == rb["mean"][k] and ra["mx"][ka] == rb["mx"][k] and ra["mn"][ka] == rb["mn"][k]
	_ok(same, "two windows a fraction of a bin apart give the same bins")

	# ---- nesting: a 1 h bin = the two 30-minute bins inside it ----
	var gh := B.grid(base, base + 24.0, 1.0)
	var gq := B.grid(base, base + 24.0, 0.5)
	var rh := B.from_regular(smooth, base, step, 1.0, int(gh["i0"]), int(gh["n"]))
	var rq := B.from_regular(smooth, base, step, 0.5, int(gq["i0"]), int(gq["n"]))
	var nest := true
	for k in int(gh["n"]):
		var a := 2 * k
		nest = nest and _near(rh["mx"][k], maxf(rq["mx"][a], rq["mx"][a + 1])) \
			and _near(rh["mn"][k], minf(rq["mn"][a], rq["mn"][a + 1])) \
			and _near(rh["mean"][k], (rq["mean"][a] + rq["mean"][a + 1]) * 0.5, 1e-3)
	_ok(nest, "zooming out merges bins exactly (min / max / mean)")

	# ---- outside the data: gaps ----
	var ro := B.from_regular(vals, base, step, 1.0, int(B.grid(base - 5.0, base, 1.0)["i0"]), 5)
	_ok(is_nan(ro["mean"][0]) and is_nan(ro["mean"][4]), "before the data: gaps, not zeros")
	var vr := B.value_range(r1)
	_ok(_near(vr.x, 0.0) and _near(vr.y, 9.0), "value range spans the band")

	# ---- the hourly-linear weather reader ----
	var calls := [0]
	var f := func(t: float) -> float:
		calls[0] += 1
		# Linear between whole hours: v(h) = h % 3 at each hour.
		var h0 := floorf(t)
		var a0 := fmod(h0, 3.0)
		var a1 := fmod(h0 + 1.0, 3.0)
		return lerpf(a0, a1, t - h0)
	var gw := B.grid(3000.0, 3012.0, 3.0)
	var rw := B.from_function(f, 1.0, 3.0, int(gw["i0"]), int(gw["n"]))
	# Over [3000, 3003): points 0,1,2,0 → trapezoid mean = (0.5 + 1.5 + 1.0) / 3 = 1.0
	_ok(_near(rw["mean"][0], 1.0) and _near(rw["mn"][0], 0.0) and _near(rw["mx"][0], 2.0), "weather bin: exact trapezoid mean, hourly extremes")
	_ok(calls[0] == 13, "bin edges are read once (13 evaluations for 4 three-hour bins, got %d)" % calls[0])
	var gs := B.grid(3000.25, 3000.75, 1.0 / 6.0)
	var rs := B.from_function(f, 1.0, 1.0 / 6.0, int(gs["i0"]), int(gs["n"]))
	_ok(_near(rs["mean"][0], 0.25, 1e-3) and _near(rs["mn"][0], 1.0 / 6.0, 1e-3), "a bin inside one hour follows the line ([0:10, 0:20) → mean 0.25)")
	var gy := B.grid(0.0, 8766.0 * 2.0, 8766.0)
	calls[0] = 0
	B.from_function(f, 1.0, 8766.0, int(gy["i0"]), int(gy["n"]))
	_ok(calls[0] <= 2 * (B.MAX_POINTS_PER_BIN + 1), "a year-wide bin reads at most %d instants (%d)" % [B.MAX_POINTS_PER_BIN + 1, calls[0]])
	var gn := B.from_function(func(_t: float) -> float: return NAN, 1.0, 1.0, 0, 4)
	_ok(is_nan(gn["mean"][2]), "no data → gaps")

	# ---- step readings (Home Assistant) ----
	var ts := PackedFloat64Array([10.0, 10.5, 12.0, 20.0])
	var vs := PackedFloat32Array([1.0, 3.0, 5.0, 7.0])
	var st := B.from_steps(ts, vs, 1.0, 10, 4, 6.0, 13.5)
	# [10,11): 1 for 0.5 h, 3 for 0.5 h → mean 2, min 1, max 3
	_ok(_near(st["mean"][0], 2.0) and _near(st["mn"][0], 1.0) and _near(st["mx"][0], 3.0), "time-weighted mean, both readings in min / max")
	_ok(_near(st["mean"][1], 3.0) and _near(st["mn"][1], 3.0), "a bin with no reading holds the last one")
	_ok(_near(st["mean"][2], 5.0), "the next reading takes over")
	_ok(_near(st["mean"][3], 5.0), "the bin cut at NOW uses only the time before it")
	var st2 := B.from_steps(ts, vs, 1.0, 17, 3, 6.0, INF)
	_ok(is_nan(st2["mean"][1]), "a reading older than the gap limit holds no longer (%s)" % str(st2["mean"]))
	_ok(_near(st2["mean"][0], 5.0), "…but it still holds up to the limit")
	var st3 := B.from_steps(ts, vs, 1.0, 14, 2, 6.0, 13.5)
	_ok(is_nan(st3["mean"][0]) and is_nan(st3["mean"][1]), "nothing after NOW")
	var st4 := B.from_steps(ts, vs, 1.0, 5, 3, 6.0, INF)
	_ok(is_nan(st4["mean"][0]), "nothing before the first reading")

	# ---- unit mapping ----
	var m := B.mapped(r1, func(v: float) -> float: return v * 2.0)
	_ok(_near(m["mx"][0], 18.0) and _near(m["mean"][0], 9.0), "mapped converts every series")

	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL  ran %d checks, expected %d (a runtime error aborted a test?)" % [_checks, EXPECTED_CHECKS])
	print("timeline_binning_selftest: %d checks, %d failures — %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(1 if _fails > 0 else 0)
