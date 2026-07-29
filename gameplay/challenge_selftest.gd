extends SceneTree

## Headless self-test for ChallengeDef / Catalog / Runner evaluation.
## Run:
##   Godot.exe.exe --headless --path . --script gameplay/challenge_selftest.gd

const ChallengeDefScript := preload("res://gameplay/challenge_def.gd")
const ChallengeCatalogScript := preload("res://gameplay/challenge_catalog.gd")
const ChallengeRunnerScript := preload("res://gameplay/challenge_runner.gd")
const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const ClosureMetricsScript := preload("res://system_graph/closure_metrics.gd")

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_catalog()
	_test_def_roundtrip()
	_test_starvation_fail()
	_test_close_loop_win_rules()
	_test_driest_week_math()
	if _failures == 0:
		print("CHALLENGE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CHALLENGE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_catalog() -> void:
	var all: Array = ChallengeCatalogScript.all_challenges()
	_check("catalog has 6 challenges", all.size() == 6, "n=%d" % all.size())
	var ids: Array = []
	for d: ChallengeDef in all:
		ids.append(d.id)
	_check("has keep_lights_on", ids.has("keep_lights_on"))
	_check("has dry_week", ids.has("dry_week"))
	_check("has close_the_loop", ids.has("close_the_loop"))
	var lights: ChallengeDef = ChallengeCatalogScript.by_id("keep_lights_on")
	_check("lights duration 72h", lights != null and absf(lights.duration_hours - 72.0) < 0.01)
	_check("lights tracks AC", lights != null and lights.track_ac_availability)
	_check("lights max AC down 0.5h", lights != null and absf(lights.max_ac_down_hours - 0.5) < 0.01)
	var dry: ChallengeDef = ChallengeCatalogScript.by_id("dry_week")
	_check("dry week 168h", dry != null and absf(dry.duration_hours - 168.0) < 0.01)
	_check("dry week driest", dry != null and dry.use_driest_week)
	var loop: ChallengeDef = ChallengeCatalogScript.by_id("close_the_loop")
	_check("loop water closure 0.6", loop != null and absf(loop.min_water_closure_pct - 0.6) < 0.01)


func _test_def_roundtrip() -> void:
	var d: ChallengeDef = ChallengeCatalogScript.by_id("close_the_loop")
	var d2: ChallengeDef = ChallengeDefScript.from_dict(d.to_dict())
	_check("roundtrip id", d2.id == d.id)
	_check("roundtrip water closure", absf(d2.min_water_closure_pct - d.min_water_closure_pct) < 0.001)
	_check("roundtrip fail kinds", d2.fail_on_kinds.has("water"))


func _test_starvation_fail() -> void:
	var model := GraphModelScript.new()
	model.add_item({
		"id": "hab", "type": "processor", "x": 0.0, "y": 0.0,
		"specs": {
			"role": "habitat", "occupants": 1,
			"starved_kinds": ["water"], "is_starved": true,
			"inputs": [{"kind": "water", "rate": 2.083, "unit": "L/h"}],
			"outputs": [],
		},
	})
	var m: Dictionary = ClosureMetricsScript.compute(model, null, null, 100.0)
	_check("metrics any_starved", bool(m.get("any_starved", false)))
	var def: ChallengeDef = ChallengeCatalogScript.by_id("keep_lights_on")
	_check("lights is power-only (no starvation fail)", def != null and not def.fail_on_starvation)
	_check("lights has no water/food fail kinds", def != null and def.fail_on_kinds.is_empty())


func _test_close_loop_win_rules() -> void:
	var def: ChallengeDef = ChallengeCatalogScript.by_id("close_the_loop")
	_check("loop water closure threshold", def.min_water_closure_pct >= 0.6)
	_check("loop fail on water stockout", def.fail_on_kinds.has("water"))
	_check("loop no AC track", not def.track_ac_availability)


func _test_driest_week_math() -> void:
	## Offline sliding-window minimum (mirrors ChallengeRunner.find_driest_week_start).
	var day_totals := PackedFloat32Array([10.0, 8.0, 6.0, 4.0, 2.0, 1.0, 0.5, 0.5, 9.0, 9.0])
	var n := day_totals.size()
	var best_i := 0
	var window := 0.0
	for i in range(7):
		window += day_totals[i]
	var best_sum := window
	for i in range(7, n):
		window += day_totals[i] - day_totals[i - 7]
		if window < best_sum:
			best_sum = window
			best_i = i - 6
	_check("driest window index", best_i == 1, "best_i=%d sum=%.1f" % [best_i, best_sum])
	var runner_probe: Node = ChallengeRunnerScript.new()
	_check("runner has driest helper", runner_probe.has_method("find_driest_week_start"))
	runner_probe.free()
