extends SceneTree

## ConduitStyleModel (offline): which rows the style window shows per kind,
## catalog sizes only, pipe_sdr surviving a write, a real kind never keeping a
## free thickness, the spec strip and the warnings.
##   Godot --headless --path . --script system_graph/conduit_style_model_selftest.gd

const EXPECTED_CHECKS := 18

var _n := 0
var _fails := 0


func _check(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [label, detail])
	else:
		print("  ok  %s" % label)


func _initialize() -> void:
	var pvc := ConduitStyleModel.rows("pvc_pipe", {}, true)
	_check("PVC on the solver: size and solver rows, no free thickness or legacy route",
		bool(pvc["size"]) and bool(pvc["solver"]) and not bool(pvc["thickness"]) and not bool(pvc["route_mode"]))
	var flow := ConduitStyleModel.rows("conceptual_flow", {}, false)
	_check("a flow line: free thickness and glow", bool(flow["thickness"]) and bool(flow["glow"])
		and not bool(flow["roughness"]))
	_check("EMT shows its conductors", bool(ConduitStyleModel.rows("emt_conduit", {}, true)["conductors"]))
	var cord := ConduitStyleModel.rows("extension_cord", {}, false)
	_check("a cord off the solver shows slack", bool(cord["slack"]))
	var angles_ok := true
	for t: String in ["pvc_pipe", "romex", "emt_conduit", "copper_type_l"]:
		var r := ConduitStyleModel.rows(t, {}, true)
		if bool(r["allow_45"]) != ConduitSpecs.allowed_angles(t).has(45.0):
			angles_ok = false
	_check("the 45° row only where the kind bends at 45°", angles_ok)
	# Sizes.
	var sc := ConduitStyleModel.size_choices("romex")
	_check("romex comes in gauges", (sc["choices"] as Array).size() >= 3 and not str(sc["key"]).is_empty(),
		str(sc))
	var pv := ConduitStyleModel.size_choices("pvc_pipe")
	_check("PVC comes in Sch40 sizes", (pv["choices"] as Array).size() >= 4 and str(pv["key"]) == "pipe_size_in")
	var st := ConduitStyleModel.set_size({"radius_m": 0.05, "color": Color.RED}, "pvc_pipe", 2.0)
	_check("picking a size writes the size and drops a free thickness",
		absf(float(st["pipe_size_in"]) - 2.0) < 1e-6 and not st.has("radius_m") and st.has("color"))
	_check("size_value reads it back", absf(ConduitStyleModel.size_value("pvc_pipe", st) - 2.0) < 1e-6)
	_check("EMT conductors listed", ConduitStyleModel.conductor_choices().size() >= 3)
	# Writes.
	var dirty := {"pipe_sdr": 11.0, "radius_m": 0.04, "not_a_key": 3, "run_height_m": 1.2, "lane_index": 2}
	var c1 := ConduitStyleModel.clean(dirty, "poly_penstock")
	_check("pipe_sdr survives a write", absf(float(c1.get("pipe_sdr", 0.0)) - 11.0) < 1e-6)
	_check("unknown keys are not written", not c1.has("not_a_key"))
	_check("route keys survive", c1.has("run_height_m") and c1.has("lane_index"))
	_check("a real kind never keeps a free thickness", not ConduitStyleModel.clean(dirty, "pvc_pipe").has("radius_m"))
	_check("a drawn-only kind keeps its thickness", ConduitStyleModel.clean(dirty, "conceptual_flow").has("radius_m"))
	# Strip and warnings.
	var conn := {"conduit_type": "pvc_pipe", "conduit_style": {"pipe_size_in": 1.0}, "route_length_m": 12.0}
	var lines := ConduitStyleModel.spec_lines(conn)
	var labels: Array = []
	for l: Array in lines:
		labels.append(str(l[0]))
	_check("the strip gives size, bend and length", labels.has("Outside") and labels.has("Bends at")
		and labels.has("Length"), str(labels))
	var w := ConduitStyleModel.warnings(conn, {"flags": {"tight": 2, "budget": true}})
	_check("tight bends and a fallback route are warned about", w.size() == 2, str(w))
	print("CONDUIT STYLE MODEL SELFTEST %s  (%d checks)" % ["PASS" if _fails == 0 else "FAIL", _n + 1])
	_check("check count matches EXPECTED_CHECKS", _n + 1 == EXPECTED_CHECKS,
		"ran %d, expected %d" % [_n + 1, EXPECTED_CHECKS])
	quit(0 if _fails == 0 else 1)
