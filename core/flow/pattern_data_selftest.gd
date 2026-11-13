extends SceneTree

## PatternData selftest (offline): a minute series averaged into a day × hour
## grid with gaps left NAN, the finite range, the hourly sampler, the orbit's
## day-to-day drift (a steady cycle 0, a falling store negative) and its
## words, an energy budget as waterfall steps that land on what did work,
## and the bars' running spans.
##
## Carries EXPECTED_CHECKS.
##   godot --headless --path . --script core/flow/pattern_data_selftest.gd

const EXPECTED_CHECKS := 12

var _checks := 0
var _fails := 0


func _init() -> void:
	# Two days of minutes starting at 01:00 on day 0: value = hour of day.
	var v := PackedFloat32Array()
	var base := 24.0 * 100.0 + 1.0
	for i in 47 * 60:
		var t := base + float(i) / 60.0
		v.append(fmod(floor(t), 24.0))
	var g := PatternData.hour_grid(v, base, 1.0 / 60.0, 24.0 * 100.0, 2)
	_ok(g.size() == 48 and is_nan(g[0]), "the hour before the data starts is empty")
	_ok(absf(g[13] - 13.0) < 1e-6 and absf(g[24 + 5] - 5.0) < 1e-6, "each cell is its hour's mean")
	var r := PatternData.finite_range(g)
	_ok(absf(r.x - 0.0) < 1e-6 and absf(r.y - 23.0) < 1e-6, "the range skips the empty cells")
	var h := PatternData.hourly(func(t: float) -> float: return t, 10.2, 13.0)
	_ok(h.size() == 3 and absf(h[0] - 10.5) < 1e-9, "hourly samples at each hour's middle")

	# An orbit: the same daily loop twice drifts nothing; a store losing 10 a
	# day drifts −10.
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	var ys2 := PackedFloat32Array()
	for i in 72:
		var ph := TAU * float(i % 24) / 24.0
		xs.append(50.0 + 30.0 * sin(ph))
		ys.append(50.0 + 20.0 * cos(ph))
		ys2.append(80.0 + 20.0 * cos(ph) - 10.0 * float(i) / 24.0)
	_ok(PatternData.orbit_drift(xs, ys).length() < 1e-4, "a steady daily loop does not drift")
	_ok(absf(PatternData.orbit_drift(xs, ys2).y + 10.0) < 1e-4, "a falling store drifts down by its daily loss")
	_ok(PatternData.drift_words(Vector2.ZERO, Vector2(100, 100), "the battery", "the tank").begins_with("A steady"),
		"a steady cycle in words")
	_ok(PatternData.drift_words(Vector2(0, -10), Vector2(100, 100), "the battery", "the tank")
		== "The tank runs down day by day.", "a store running down in words")

	var f := {"potential": 10.0, "not_used": 4.0, "aux": 1.0, "from_store": 0.5,
		"batt_loss": 0.3, "kept": 0.0, "load": 7.2}
	var steps := PatternData.energy_waterfall(f)
	_ok(steps.size() == 6 and str(steps[0]["kind"]) == "start" and str(steps[-1]["kind"]) == "total",
		"the budget starts with the sun and ends with what did work (empty steps left out)")
	var spans := PatternData.waterfall_spans(steps)
	var run_end := float(spans[spans.size() - 2]["from"])
	_ok(absf(run_end - 7.2) < 1e-9, "the running total lands on what did work")
	_ok(absf(float(spans[1]["from"]) - 6.0) < 1e-9 and absf(float(spans[1]["to"]) - 10.0) < 1e-9,
		"a loss is a bar hanging down from the running total")
	_ok(PatternData.energy_waterfall({}).is_empty(), "no budget for an empty window")
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("PATTERN DATA SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)
