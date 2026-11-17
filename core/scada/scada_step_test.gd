class_name ScadaStepTest
extends RefCounted
## A PID loop's step test, run on a COPY of the graph (ScadaTune's input).
## The live world is never touched: the graph is copied, the copy gets its
## own flow engine (as an A/B world does), the output is held where it is
## for a while (the reading's own drift), then stepped, and the reading is
## recorded minute by minute.
##
## Only for loops whose reading and output are both on the graph (a tank
## level, a control valve's opening, a machine's switch). Other logic does
## not run in the copy, AC is taken as on, and weather is whatever the host
## answers at that hour: the result is an estimate.

const DT_H := 1.0 / 60.0
const BASE_STEPS := 20
const MAX_STEPS := 480


## → {ok, why, t: [h], pv: [..], u0, du, slope0, fit, gains}.
static func run(model: GraphModel, host: Node, block: Dictionary, now_h: float) -> Dictionary:
	var pv_tag := str(block.get("pv", ""))
	var out_tag := str(block.get("out", ""))
	if model == null or is_nan(ScadaLogicRun.read_model(model, pv_tag)) or is_nan(ScadaLogicRun.read_model(model, out_tag)):
		return {"ok": false, "why": "A step test needs a reading and an output that are both on the graph."}
	var copy := GraphModel.new()
	copy.deserialize(model.serialize().duplicate(true))
	var flow := ResourceFlowEngine.new()
	flow.setup(copy, host)
	var t := now_h
	flow.render_step(t, 0.0, true)
	var u0 := ScadaLogicRun.read_model(copy, out_tag)
	var lo := float(block.get("out_min", 0.0))
	var hi := float(block.get("out_max", 100.0))
	var du := 10.0 if u0 + 10.0 <= hi else -10.0
	if out_tag.begins_with("node."):
		du = 100.0 if u0 < 50.0 else -100.0
	# The reading's drift with the output held.
	var bt: Array = []
	var bp: Array = []
	for i in BASE_STEPS:
		t += DT_H
		flow.render_step(t, DT_H, true)
		bt.append(float(i + 1) * DT_H)
		bp.append(ScadaLogicRun.read_model(copy, pv_tag))
	var slope0 := float(ScadaTune._line(bt, bp, 0)[1])
	ScadaLogicRun.apply_write(copy, out_tag, clampf(u0 + du, lo, hi))
	var ts: Array = [0.0]
	var ps: Array = [float(bp[bp.size() - 1])]
	var is_pct := pv_tag.ends_with(".level")
	for i in MAX_STEPS:
		t += DT_H
		flow.render_step(t, DT_H, true)
		var v := ScadaLogicRun.read_model(copy, pv_tag)
		ts.append(float(i + 1) * DT_H)
		ps.append(v)
		# A tank at an end stop says nothing more.
		if is_pct and (v <= 0.5 or v >= 99.5) and i > 10:
			break
	var f := ScadaTune.fit(ts, ps, du, slope0)
	var g := ScadaTune.gains(f, 3.0 * DT_H)
	return {"ok": bool(g.get("ok", false)), "why": str(g.get("text", f.get("why", ""))), "t": ts, "pv": ps, "u0": u0, "du": du,
		"slope0": slope0, "fit": f, "gains": g}
