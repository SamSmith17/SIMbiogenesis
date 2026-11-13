extends SceneTree

## FlowHistory selftest (offline): a held reading integrates exactly across
## bin edges, windows average over the recorded hours, a scrub back drops the
## future, a long jump counts nothing, old bins are pruned, the dict round
## trip keeps everything.
##
## Carries EXPECTED_CHECKS.
##   godot --headless --path . --script core/flow/flow_history_selftest.gd

const EXPECTED_CHECKS := 9

var _checks := 0
var _fails := 0


func _init() -> void:
	var h := FlowHistory.new()
	h.record(10.0, {"c1": {"key": "water", "value": 6.0}})
	h.record(12.5, {"c1": {"key": "water", "value": 2.0}})
	h.record(13.5, {"c1": {"key": "water", "value": 2.0}})
	var w := h.window(10.0, 14.0)
	_ok(w.has("c1") and absf(float(w["c1"]["mean"]) - (6.0 * 2.5 + 2.0 * 1.0) / 3.5) < 1e-9,
		"held readings integrate exactly over the window")
	_ok(absf(float(w["c1"]["max"]) - 6.0) < 1e-9 and str(w["c1"]["key"]) == "water", "peak and key kept")
	var w2 := h.window(12.0, 13.0)
	_ok(absf(float(w2["c1"]["mean"]) - (6.0 * 0.5 + 2.0 * 0.5)) < 1e-9, "a window cuts across bins exactly")
	h.record(12.0, {"c1": {"key": "water", "value": 1.0}})
	var w3 := h.window(12.0, 14.0)
	_ok(not w3.has("c1") or float(w3["c1"]["hours"]) <= 1.0 + 1e-9, "a scrub back drops what came after")
	var j := FlowHistory.new()
	j.record(0.0, {"c": {"key": "food", "value": 1.0}})
	j.record(100.0, {"c": {"key": "food", "value": 1.0}})
	_ok(j.window(0.0, 100.0).is_empty(), "a long jump counts nothing")
	j.record(101.0, {"c": {"key": "food", "value": 3.0}})
	_ok(absf(float(j.window(100.0, 101.0)["c"]["mean"]) - 1.0) < 1e-9, "recording resumes after a jump")
	var p := FlowHistory.new()
	for i in FlowHistory.MAX_BINS + 20:
		p.record(float(i), {"c": {"key": "water", "value": 1.0}})
	_ok(p.bins.size() <= FlowHistory.MAX_BINS, "old bins are pruned")
	var rt := FlowHistory.from_dict(h.to_dict())
	_ok(var_to_str(rt.window(10.0, 12.0)) == var_to_str(h.window(10.0, 12.0)), "dict round trip")
	_ok(FlowHistory.new().window(0.0, 10.0).is_empty(), "an empty history has no flows")
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("FLOW HISTORY SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)
