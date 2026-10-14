extends SceneTree

## Headless self-test for FestivalVibe (core/population/festival_vibe.gd):
## headcount weighting, the band histogram sum, blocked share from CRITICAL
## needs only, the component ordering, the headline, and the trend ring incl.
## the scrub-back reset. Run --import first.
##   godot --headless --path . --script core/population/festival_vibe_selftest.gd

const EXPECTED_CHECKS := 14

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_compute()
	_test_headline()
	_test_trend()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("FESTIVAL VIBE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("FESTIVAL VIBE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _camp(n: int, morale: float, bands: Array, blocked: Dictionary, departures: int = 0, risk: float = 0.0) -> Dictionary:
	return {"count": n, "mean_morale": morale, "morale_bands": bands, "blocked": blocked,
		"departures": departures, "collapse_risk": risk}


func _test_compute() -> void:
	var empty := FestivalVibe.compute([])
	_check("no camps: zero people, score 0, Fuck This band", int(empty["people"]) == 0
		and float(empty["score"]) == 0.0 and str(empty["label"]) == NpcMorale.label(0.0))
	var a := _camp(100, 0.9, [100, 0, 0, 0, 0, 0], {})
	var b := _camp(20, 0.3, [0, 0, 0, 20, 0, 0], {"thirst": 12, "hygiene": 20}, 3, 0.4)
	var v := FestivalVibe.compute([a, b], 7)
	_check("headcount-weighted mean (100×0.9 + 20×0.3)/120", absf(float(v["score"]) - 0.8) < 1e-9, "score=%.3f" % float(v["score"]))
	_check("band + label follow NpcMorale", str(v["label"]) == NpcMorale.label(0.8))
	var hsum := 0
	for h in (v["histogram"] as Array):
		hsum += int(h)
	_check("histogram sums to the people", hsum == 120 and int(v["people"]) == 120)
	_check("blocked share counts CRITICAL needs only (12 of 120, hygiene ignored)",
		absf(float(v["blocked_share"]) - 0.1) < 1e-9 and not (v["blocked"] as Dictionary).has("hygiene"))
	_check("queueing, departures and the worst collapse risk ride through",
		int(v["queueing"]) == 7 and int(v["departures"]) == 3 and absf(float(v["collapse_risk"]) - 0.4) < 1e-9)
	var comps: Array = v["components"]
	_check("components name the dragging need", comps.size() == 1 and str(comps[0]["need"]) == "thirst"
		and int(comps[0]["people"]) == 12)
	var c := _camp(30, 0.5, [0, 0, 30, 0, 0, 0], {"hunger": 9, "thirst": 9, "bladder": 2})
	var v2 := FestivalVibe.compute([c])
	var order: Array = []
	for cc in (v2["components"] as Array):
		order.append(str(cc["need"]))
	_check("components sort by people then name (deterministic)", order == ["hunger", "thirst", "bladder"], str(order))
	_check("a camp with count 0 is skipped", int(FestivalVibe.compute([_camp(0, 1.0, [], {})])["people"]) == 0)


func _test_headline() -> void:
	var v := FestivalVibe.compute([_camp(40, 0.74, [0, 40, 0, 0, 0, 0], {"bladder": 5})], 38)
	var h := FestivalVibe.headline(v, 0.05)
	_check("headline carries band, score, arrow and the reasons",
		h.begins_with("VIBE ● %s 0.74 ▲" % NpcMorale.label(0.74)) and h.contains("5 blocked on bladder") and h.contains("38 queueing"), h)
	_check("flat trend has no arrow", not FestivalVibe.headline(v, 0.0).contains("▲")
		and not FestivalVibe.headline(v, 0.0).contains("▼"))


func _test_trend() -> void:
	var fv := FestivalVibe.new()
	fv.sample(100.0, 0.5)
	_check("one sample: no trend", fv.trend() == 0.0)
	for i in range(1, 30):
		fv.sample(100.0 + float(i), 0.5 + 0.01 * float(i))
	_check("trend is now minus the oldest sample INSIDE the 24 h window",
		absf(fv.trend() - (0.79 - 0.55)) < 1e-6, "trend=%.4f" % fv.trend())
	fv.sample(50.0, 0.2)
	_check("a scrub-back resets the ring", fv.trend() == 0.0)
