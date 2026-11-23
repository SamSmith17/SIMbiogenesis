extends SceneTree
## Offline selftest for StoreItemLedger (plans/FOOD_WASTE_REALISM_PLAN.md
## Phase 5): hand-pinned reads, FIFO determinism, truncation, snapshot and
## persistence round trips, the density fold, the MAX_EVENTS fold into the
## baseline, and a random-operation fuzz against a naive reference
## (the resource_timeline_selftest pattern).
##
## Run: Godot.exe.exe --headless --path . --script core/food/store_item_ledger_selftest.gd

const EXPECTED_CHECKS := 37

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _near(a: float, b: float, eps: float = 1e-9) -> bool:
	return absf(a - b) <= eps


func _initialize() -> void:
	_test_hand_case()
	_test_fifo()
	_test_density()
	_test_fold()
	_test_fuzz()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a runtime error aborted a test?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("STORE ITEM LEDGER SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("STORE ITEM LEDGER SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_hand_case() -> void:
	var led := StoreItemLedger.new()
	_check("fresh ledger is empty", led.is_empty())
	led.set_baseline(100.0, {"beans": 10, "cola": 4}, 10.0 * 0.47 + 4.0 * 1.038)
	_check("baseline counts", led.counts_at(100.0).get("beans") == 10)
	led.record(101.0, "cola", 2, 2.0 * 1.038)
	led.record(102.0, "beans", -3, -3.0 * 0.47)
	_check("counts before an event ignore it", led.counts_at(100.5).get("cola") == 4)
	_check("counts after both events", led.counts_at(103.0).get("beans") == 7
			and led.counts_at(103.0).get("cola") == 6)
	_check("kg follows the events exactly",
			_near(led.kg_at(103.0), 7.0 * 0.47 + 6.0 * 1.038, 1e-9), str(led.kg_at(103.0)))
	_check("backwards read re-answers exactly (cursor rebuild)",
			led.counts_at(101.5).get("cola") == 6 and led.counts_at(101.5).get("beans") == 10)
	_check("total count", led.total_count_at(103.0) == 13)
	# Snapshot round trip.
	var snap := led.snapshot()
	var led2 := StoreItemLedger.new()
	led2.restore(snap)
	_check("snapshot round trip: counts", led2.counts_at(103.0) == led.counts_at(103.0))
	_check("snapshot round trip: kg", _near(led2.kg_at(103.0), led.kg_at(103.0)))
	# Scrub back.
	led.truncate_after(101.5)
	_check("truncate drops the later event", led.counts_at(103.0).get("beans") == 10)
	_check("truncate keeps the earlier one", led.counts_at(103.0).get("cola") == 6)
	led.truncate_after(50.0)
	_check("a scrub past the baseline keeps the baseline",
			led.counts_at(103.0).get("beans") == 10 and led.counts_at(103.0).get("cola") == 4)
	# Persistence (the compact specs state).
	led2.record(104.0, "cola", -6, -6.0 * 1.038)
	var persisted := led2.persist_state(104.0)
	var led3 := StoreItemLedger.new()
	led3.load_persisted(persisted)
	_check("persist: zero-count ids dropped", not led3.counts_at(104.0).has("cola"))
	_check("persist: counts carried", led3.counts_at(104.0).get("beans") == 7)
	_check("persist: kg carried", _near(led3.kg_at(104.0), led2.kg_at(104.0), 1e-9))


func _kg_of(id: String) -> float:
	return {"beans": 0.47, "cola": 1.038, "sack": 5.0}.get(id, 1.0)


func _test_fifo() -> void:
	var led := StoreItemLedger.new()
	led.set_baseline(0.0, {"beans": 4}, 4.0 * 0.47)
	led.record(1.0, "cola", 3, 3.0 * 1.038)
	led.record(2.0, "sack", 2, 10.0)
	var kg_of := Callable(self, "_kg_of")
	# Oldest first: the baseline's beans go before the cola, and the 0.12 kg
	# left after them does not fit a whole cola — strict FIFO stops there.
	var take := led.take_fifo(3.0, 2.0, kg_of)
	_check("fifo takes the oldest id first and stops at the budget", take.size() == 1
			and str(take[0]["id"]) == "beans" and int(take[0]["count"]) == 4, str(take))
	# Deterministic: the same question twice is the same answer.
	_check("fifo is deterministic", str(led.take_fifo(3.0, 2.0, kg_of)) == str(take))
	# A budget smaller than the oldest item takes nothing (strict FIFO).
	var led_b := StoreItemLedger.new()
	led_b.set_baseline(0.0, {"sack": 1}, 5.0)
	led_b.record(1.0, "beans", 2, 0.94)
	_check("strict fifo: a big head-of-line item blocks a small budget",
			led_b.take_fifo(2.0, 1.0, kg_of).is_empty())
	_check("a budget that fits the head takes it",
			int(led_b.take_fifo(2.0, 5.2, kg_of)[0]["count"]) == 1)
	# Events at a future time are not takeable yet.
	_check("fifo respects t", led.take_fifo(1.5, 100.0, kg_of).size() == 2)
	# Taking records back as negative events; the remainder follows.
	var got := led.take_fifo(3.0, 100.0, kg_of)
	var total := 0.0
	for e in got:
		total += float(e["kg"])
		led.record(3.0, str(e["id"]), -int(e["count"]), -float(e["kg"]))
	_check("taking everything empties the ledger", led.total_count_at(3.0) == 0)
	_check("the taken kg is the ledger's kg", _near(total, 4.0 * 0.47 + 3.0 * 1.038 + 10.0, 1e-9))
	_check("kg returns to zero", _near(led.kg_at(3.0), 0.0, 1e-9))


func _test_density() -> void:
	var led := StoreItemLedger.new()
	led.set_baseline(0.0, {}, 10.0)  # 10 kg of unknown bulk
	_check("unknown density falls back", _near(led.density_at(1.0, 1666.0), 1666.0))
	# 10 kg @ fallback 1666 + 10 kg @ 3000 -> 2333.
	led.record_mix(2.0, 10.0, 10.0, 3000.0)
	_check("mix folds by mass", _near(led.density_at(3.0, 1666.0), (10.0 * 1666.0 + 10.0 * 3000.0) / 20.0, 1e-6))
	# Before the mix, still the fallback.
	_check("density is a function of t", _near(led.density_at(1.0, 1666.0), 1666.0))
	# A second mix compounds on the first.
	led.record_mix(4.0, 5.0, 5.0, 1000.0)
	var d2 := (10.0 * 1666.0 + 10.0 * 3000.0) / 20.0
	var d3 := (5.0 * d2 + 5.0 * 1000.0) / 10.0
	_check("a second mix compounds", _near(led.density_at(5.0, 1666.0), d3, 1e-6))
	led.truncate_after(3.0)
	_check("truncate rewinds the density", _near(led.density_at(5.0, 1666.0), d2, 1e-6))


func _test_fold() -> void:
	var led := StoreItemLedger.new()
	led.set_baseline(0.0, {}, 0.0)
	# Enough events to force folds: 2x MAX_EVENTS single-item arrivals spread
	# over 40 days (so the oldest fall past KEEP_H and fold into the baseline).
	var n := StoreItemLedger.MAX_EVENTS * 2
	for i in n:
		var t := 40.0 * 24.0 * float(i) / float(n)
		led.record(t, "beans", 1, 0.47)
	var t_end := 40.0 * 24.0
	_check("fold keeps the running totals exact", led.total_count_at(t_end) == n,
			str(led.total_count_at(t_end)))
	_check("fold keeps the kg exact", _near(led.kg_at(t_end), 0.47 * float(n), 1e-6))
	_check("the log stayed bounded", led.snapshot()["events"].size() <= StoreItemLedger.MAX_EVENTS,
			str(led.snapshot()["events"].size()))


func _test_fuzz() -> void:
	var rng := RandomNumberGenerator.new()
	for run in 3:
		rng.seed = 1000 + run
		var led := StoreItemLedger.new()
		led.set_baseline(0.0, {"a": 5, "b": 2}, 5.0 * 1.0 + 2.0 * 2.0)
		# Naive reference: a flat list of (t, id, dc, dkg), replayed whole
		# for every question.
		var ref: Array = [[0.0, "a", 5, 5.0], [0.0, "b", 2, 4.0]]
		var t := 0.0
		var ok_counts := true
		var ok_kg := true
		for op in 800:
			var roll := rng.randf()
			if roll < 0.55:
				t += rng.randf_range(0.01, 2.0)
				var id: String = ["a", "b", "c"][rng.randi_range(0, 2)]
				var dc := rng.randi_range(-2, 4)
				var dkg := float(dc) * 1.5
				led.record(t, id, dc, dkg)
				ref.append([t, id, dc, dkg])
			elif roll < 0.75:
				# Read at a random time (often backwards).
				var rt := rng.randf_range(0.0, t + 1.0)
				var want: Dictionary = {}
				var want_kg := 0.0
				for e in ref:
					if float(e[0]) <= rt:
						want[e[1]] = int(want.get(e[1], 0)) + int(e[2])
						want_kg += float(e[3])
				for k in want.keys():
					if int(want[k]) <= 0:
						want.erase(k)
				if led.counts_at(rt) != want:
					ok_counts = false
				# kg_at reports a floor of 0 (a ledger below zero is an
				# accounting error upstream, never a real stock).
				if not _near(led.kg_at(rt), maxf(want_kg, 0.0), 1e-6):
					ok_kg = false
			elif roll < 0.85:
				# Scrub back.
				var cut := rng.randf_range(0.0, t)
				led.truncate_after(cut)
				var kept: Array = []
				for e in ref:
					if float(e[0]) <= cut:
						kept.append(e)
				ref = kept
				t = cut
			else:
				# Snapshot round trip mid-run.
				var l2 := StoreItemLedger.new()
				l2.restore(led.snapshot())
				led = l2
		_check("fuzz run %d: counts match the naive reference" % run, ok_counts)
		_check("fuzz run %d: kg matches the naive reference" % run, ok_kg)
