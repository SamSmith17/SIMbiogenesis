extends SceneTree

## FlowCompare selftest (offline): the shared width reference is the biggest
## flow of each kind in either version, the difference is B − A per wire
## (a wire only one version has counts whole), small changes drop out, more
## and less of a kind share one scale, boundaries are differenced too, and
## the difference lays out.
##
## Carries EXPECTED_CHECKS.
##   godot --headless --path . --script core/flow/flow_compare_selftest.gd

const EXPECTED_CHECKS := 9

var _checks := 0
var _fails := 0


func _init() -> void:
	var fa := {"nodes": [{"id": "t"}, {"id": "p"}, {"id": "g"}],
		"edges": [{"id": "1", "a": "t", "b": "p", "key": "water", "value": 100.0},
			{"id": "2", "a": "p", "b": "g", "key": "greywater", "value": 80.0},
			{"id": "3", "a": "t", "b": "g", "key": "water", "value": 0.5}],
		"bin": [{"node": "t", "key": "water", "value": 100.0, "label": "rain"}], "bout": [],
		"labels": {"t": "Tank", "p": "People", "g": "Grey"}, "opts": {}}
	var fb := {"nodes": [{"id": "t"}, {"id": "p"}, {"id": "g"}, {"id": "f"}],
		"edges": [{"id": "1", "a": "t", "b": "p", "key": "water", "value": 70.0},
			{"id": "2", "a": "p", "b": "g", "key": "greywater", "value": 80.0},
			{"id": "4", "a": "g", "b": "f", "key": "greywater", "value": 60.0},
			{"id": "3", "a": "t", "b": "g", "key": "water", "value": 0.6}],
		"bin": [{"node": "t", "key": "water", "value": 140.0, "label": "rain"}], "bout": [],
		"labels": {"f": "Filter"}, "opts": {}}
	var refs := FlowCompare.shared_refs(fa, fb)
	_ok(absf(float(refs["water"]) - 140.0) < 1e-9 and absf(float(refs["greywater"]) - 80.0) < 1e-9,
		"one width reference per kind across both versions")
	_ok(absf(float((FlowCompare.with_refs(fa, refs)["opts"] as Dictionary)["refs"]["water"]) - 140.0) < 1e-9,
		"the input carries the shared reference")
	var d := FlowCompare.difference(fa, fb)
	var by := {}
	for e in (d["edges"] as Array):
		by["%s>%s" % [e["a"], e["b"]]] = e
	_ok(by.has("t>p") and str(by["t>p"]["key"]) == "less:water" and absf(float(by["t>p"]["value"]) - 30.0) < 1e-9,
		"B carries 30 less on the supply wire")
	_ok(by.has("g>f") and str(by["g>f"]["key"]) == "more:greywater" and absf(float(by["g>f"]["value"]) - 60.0) < 1e-9,
		"a wire only B has counts whole")
	_ok(not by.has("p>g"), "an unchanged wire drops out")
	_ok(not by.has("t>g"), "a change under 1 % of the kind drops out")
	var opts: Dictionary = d["opts"]
	_ok(absf(float(opts["refs"]["more:water"]) - float(opts["refs"]["less:water"])) < 1e-9,
		"more and less of a kind share one scale")
	_ok((d["bin"] as Array).size() == 1 and str(d["bin"][0]["key"]) == "more:water"
		and absf(float(d["bin"][0]["value"]) - 40.0) < 1e-9, "boundaries are differenced")
	var lay := LoopSankeyLayout.layout(d["nodes"], d["edges"], d["bin"], d["bout"], d["opts"])
	_ok((lay["nodes"] as Dictionary).has("f") and str((d["labels"] as Dictionary)["f"]) == "Filter",
		"the difference lays out with every version's names")
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("FLOW COMPARE SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)
