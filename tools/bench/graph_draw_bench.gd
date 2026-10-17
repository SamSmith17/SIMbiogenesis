extends RefCounted

## Freeform graph DRAW bench (perf budget: gv_draw ≤ 4 ms at ~60 nodes / 80
## wires). Runs inside the bootcamp sandbox so the world's own graph is never
## touched: four 15-node solar systems (9 panels as 3S3P, an MPPT, two
## batteries, three loads) = 60 nodes / 76 wires, tidied and framed, then
## PerfMonitor's gv_draw is sampled with flow animating (clock running) and
## again with the clock paused. Dry run only:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/graph_draw_bench.gd
## Prints `graphbench …` lines; no shots dir needed.

const PANEL := "Trainer 300W (40 Voc)"
const MPPT := "Trainer MPPT 150V 30A"
const BATT := "12V 100Ah AGM"
const LOAD := "LED Light"


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	var pm: Node = main.get_node_or_null("/root/PerfMonitor")
	if sgv == null or pm == null:
		return {"ok": false, "why": "no graph view / PerfMonitor"}
	var td: Node = sgv.call("_ensure_tutorial_director")
	td.call("start", str(TutorialCatalog.ordered_ids()[0]))
	await _wait(tree, 1.0)
	var modal: Node = sgv.get("_fault_card_modal")
	if modal != null and modal.has_method("dismiss_all"):
		modal.call("dismiss_all")
	sgv.call("tutorial_clear_graph")
	var model: Object = sgv.get("model")
	var canvas: Control = sgv.get("_graph_canvas")
	var ac_pol := "ac"
	var n_items := 0
	var n_wires := 0
	for s in 4:
		var ox := float(s) * 1100.0
		var panels: Array = []
		for i in 9:
			panels.append(_add(model, PANEL, ox + float(i % 3) * 190.0, float(i / 3) * 150.0))
		var c := _add(model, MPPT, ox + 190.0, 520.0)
		var b1 := _add(model, BATT, ox + 60.0, 760.0)
		var b2 := _add(model, BATT, ox + 260.0, 760.0)
		var loads: Array = []
		for k in 3:
			loads.append(_add(model, LOAD, ox + 460.0 + float(k) * 150.0, 760.0))
		n_items += 15
		for st in 3:
			var a: String = panels[st * 3]
			var m: String = panels[st * 3 + 1]
			var z: String = panels[st * 3 + 2]
			n_wires += _wire(model, a, "positive", m, "negative", "positive")
			n_wires += _wire(model, m, "positive", z, "negative", "positive")
			n_wires += _wire(model, z, "positive", c, "pvPositive", "positive")
			n_wires += _wire(model, a, "negative", c, "pvNegative", "negative")
		n_wires += _wire(model, c, "batteryPositive", b1, "positive", "positive")
		n_wires += _wire(model, c, "batteryNegative", b1, "negative", "negative")
		n_wires += _wire(model, b1, "positive", b2, "positive", "positive")
		n_wires += _wire(model, b1, "negative", b2, "negative", "negative")
		for l in loads:
			n_wires += _wire(model, c, "acOutput", str(l), "input", ac_pol)
	sgv.call("tidy_layout", false, true)
	await _wait(tree, 0.5)
	sgv.call("_fit_canvas_to_content")
	pm.call("set_enabled", true)
	main.set("time_scale", 60.0 / 3600.0)
	await _wait(tree, 2.0)
	var running := await _sample(tree, pm, 40)
	main.set("time_scale", 0.0)
	await _wait(tree, 1.5)
	var paused := await _sample(tree, pm, 30)
	canvas.set("_zoom", 1.2)
	canvas.call("queue_redraw")
	await _wait(tree, 1.5)
	var close := await _sample(tree, pm, 20)
	print("graphbench: %d nodes, %d wires (model %d / %d)" % [n_items, n_wires,
		(model.get("items") as Array).size(), (model.get("connections") as Array).size()])
	for row in [["running", running], ["paused", paused], ["zoom 1.2", close]]:
		var r: Dictionary = row[1]
		print("graphbench %s: gv_draw (F3 HUD, per frame) %.2f ms · one draw %.2f ms (wires %.2f · cards %.2f) · peak %.2f ms · frame %.1f ms" % [
			row[0], float(r["hud"]), float(r["median"]), float(r["wires"]), float(r["cards"]), float(r["peak"]), float(r["frame"])])
	td.call("exit_tutorial")
	await _wait(tree, 0.5)
	# The plan's budget is PerfMonitor's gv_draw (what the F3 HUD shows: a
	# per-frame average). One draw is printed beside it, and held to a frame's
	# headroom (≤ 8 ms) so a redraw can never be the hitch.
	var ok := float(running["hud"]) <= 4.0 and float(running["median"]) <= 8.0
	print("graphbench budget gv_draw ≤ 4 ms per frame and one draw ≤ 8 ms (running): %s" % ("PASS" if ok else "FAIL"))
	return {"ok": ok, "running": running, "paused": paused, "zoom": close}


func _add(model: Object, label: String, x: float, y: float) -> String:
	var preset := TutorialCatalog.find_preset(label)
	var dims := ComponentPresets.spawn_dimensions(preset)
	var iid: String = model.call("generate_item_id")
	model.call("add_item", {"id": iid, "type": str(preset.get("type", "appliance")), "x": x, "y": y,
		"width": dims.x, "height": dims.y, "scope_id": "root",
		"specs": (preset.get("specs", {}) as Dictionary).duplicate(true), "is_virtual": false})
	return iid


func _wire(model: Object, a: String, ah: String, b: String, bh: String, pol: String) -> int:
	model.call("add_connection", {"scope_id": "root", "polarity": pol,
		"source_item_id": a, "source_handle_id": ah, "target_item_id": b, "target_handle_id": bh})
	return 1


func _sample(tree: SceneTree, pm: Node, n: int) -> Dictionary:
	var vals: Array = []
	var hud: Array = []
	var wires: Array = []
	var cards: Array = []
	var peak := 0.0
	var frames: Array = []
	for i in n:
		await _wait(tree, 0.1)
		var snap: Dictionary = pm.call("snapshot")
		var sec: Dictionary = snap.get("sections_ms", {}) as Dictionary
		# Sections are a per-FRAME average and the canvas draws every few
		# frames: divide by draws per frame for the cost of one draw.
		var calls := maxf(float((snap.get("calls", {}) as Dictionary).get("gv_draw", 0.0)), 0.05)
		hud.append(float(sec.get("gv_draw", 0.0)))
		vals.append(float(sec.get("gv_draw", 0.0)) / calls)
		wires.append(float(sec.get("gv_wires", 0.0)) / calls)
		cards.append(float(sec.get("gv_cards", 0.0)) / calls)
		peak = maxf(peak, float((snap.get("sections_peak_ms", {}) as Dictionary).get("gv_draw", 0.0)))
		frames.append(float(snap.get("frame_ms", 0.0)))
	vals.sort()
	hud.sort()
	frames.sort()
	wires.sort()
	cards.sort()
	return {"median": vals[vals.size() / 2], "hud": hud[hud.size() / 2], "peak": peak, "frame": frames[frames.size() / 2],
		"wires": wires[wires.size() / 2], "cards": cards[cards.size() / 2]}


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout
