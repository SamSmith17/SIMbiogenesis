extends RefCounted

## The Flows lens's torus, moved nodes, wire styles and update cadence on a
## real closed-loop world (sandbox):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/flow_torus_check.gd -Label flow_torus -Timeout 900
## Column: how many layouts 12 s at 60x cost (it used to lay out up to once
## every 0.9 s and rebuild its input on every draw), a wire style from the
## toolbar's own handler reshaping the ribbons, a REAL drag moving a node
## with its ribbons, a REAL click on "Reset positions". Torus: a REAL click
## on its chip, energy nodes on the axis, material nodes on the lobes, the
## loops on shells, a REAL drag, the save state. Prints frame times and the
## numbers a PNG cannot show.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("flowtorus %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout


func _shot(vp: Viewport, dir: String, name: String) -> void:
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _to_vp(c: Control, p: Vector2) -> Vector2:
	return c.get_global_transform_with_canvas() * p


func _chip(lens: GraphFlowLens, kind: String, value: String) -> Dictionary:
	for c in lens.chips:
		if str(c["kind"]) == kind and str(c["value"]) == value:
			return c
	return {}


func _node_screen(canvas: Control, lens: GraphFlowLens, id: String) -> Vector2:
	return GraphFlowLens.to_screen(lens.node_center(id), canvas.size * 0.5, canvas.get("_pan"), float(canvas.get("_zoom")))


## A node whose centre is on screen and clear of the header.
func _draggable(canvas: Control, lens: GraphFlowLens, want_shape: String) -> String:
	var best := ""
	var best_d := INF
	for id in (lens.cur.get("nodes", {}) as Dictionary):
		if want_shape != "" and str(lens.cur["nodes"][id].get("shape", "card")) != want_shape:
			continue
		var p := _node_screen(canvas, lens, str(id))
		if p.x < 40.0 or p.y < 150.0 or p.x > canvas.size.x - 40.0 or p.y > canvas.size.y - 60.0:
			continue
		var d := p.distance_to(canvas.size * 0.5)
		if d < best_d:
			best_d = d
			best = str(id)
	return best


func _frame_ms(tree: SceneTree, seconds: float) -> Array:
	var ts: Array = []
	var t_end := Time.get_ticks_msec() + int(seconds * 1000.0)
	var last := Time.get_ticks_usec()
	while Time.get_ticks_msec() < t_end:
		await tree.process_frame
		var now := Time.get_ticks_usec()
		ts.append(float(now - last) / 1000.0)
		last = now
	ts.sort()
	if ts.is_empty():
		return [0.0, 0.0]
	return [ts[ts.size() / 2], ts[int(float(ts.size()) * 0.95)]]


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := main.get_viewport()
	await _frames(tree, 10)
	var sgv := ServiceLocator.graph()
	_ok(sgv != null, "a graph view")
	if sgv == null:
		return {"ok": false, "fails": _fails}
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	main.set("time_scale", 60.0 / 3600.0)
	sgv.call("open_graph_view")
	await _frames(tree, 6)
	sgv.call("_jump_to_scope_index", 0)
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	await _wait(tree, 2.0)
	var canvas: Control = sgv.get("_graph_canvas")
	var free_ms: Array = await _frame_ms(tree, 4.0)
	print("flowtorus: freeform at 60x — frame median %.1f ms, p95 %.1f ms" % [free_ms[0], free_ms[1]])

	# --- The column -------------------------------------------------------
	var chips: Dictionary = sgv.get("_mode_chip_btns")
	await HarnessInput.click(vp, (chips["flows"] as Button).get_global_rect().get_center())
	await _wait(tree, 2.5)
	_ok(str(canvas.get("view_mode")) == GraphSiteLayout.VIEW_FLOWS, "a real click opens the Flows lens")
	var lens: GraphFlowLens = canvas.call("flows_lens")
	canvas.call("set_flows_shape", "column")
	lens.clear_pins()
	await _wait(tree, 2.0)
	_ok(lens.has_layout() and lens.shape == "column", "the column is laid out")
	var n0 := lens.layouts_done
	var col_ms: Array = await _frame_ms(tree, 12.0)
	var n1 := lens.layouts_done
	print("flowtorus: column at 60x — %d layouts in 12 s, frame median %.1f ms, p95 %.1f ms" % [
		n1 - n0, col_ms[0], col_ms[1]])
	_ok(n1 - n0 <= 3, "the column lays itself out rarely (%d times in 12 s)" % (n1 - n0))
	_shot(vp, dir, "01_column")
	# Wire style from the toolbar's handler.
	var before := {}
	for rb in (lens.cur.get("ribbons", []) as Array):
		if str(rb["kind"]) == LoopSankeyLayout.KIND_FORWARD:
			before[str(rb["id"])] = rb["path"]
	sgv.call("_set_wire_style_override", "orthogonal")
	await _wait(tree, 2.0)
	var reshaped := 0
	var flat := 0
	for rb2 in (lens.cur.get("ribbons", []) as Array):
		if str(rb2["kind"]) != LoopSankeyLayout.KIND_FORWARD:
			continue
		var p: PackedVector2Array = rb2["path"]
		if before.has(str(rb2["id"])) and (before[str(rb2["id"])] as PackedVector2Array) != p:
			reshaped += 1
		for i in range(1, p.size()):
			if absf(p[i].y - p[i - 1].y) < 0.01 and absf(p[i].x - p[i - 1].x) > 4.0:
				flat += 1
				break
	print("flowtorus: orthogonal wires — %d ribbons reshaped, %d with a level run" % [reshaped, flat])
	_ok(reshaped > 0 and flat > 0, "the wire style reshapes the lens's ribbons")
	_shot(vp, dir, "02_column_orthogonal")
	sgv.call("_set_wire_style_override", "metro")
	await _wait(tree, 2.0)
	_shot(vp, dir, "03_column_metro")
	sgv.call("_set_wire_style_override", "metro")   # the same style again turns it off
	await _wait(tree, 2.0)
	_ok(str(canvas.get("wire_style_override")) == "", "back to smooth wires")
	# A REAL drag moves a node.
	var nid := _draggable(canvas, lens, "")
	_ok(nid != "", "a node to drag")
	if nid != "":
		var a := _node_screen(canvas, lens, nid)
		var c0 := lens.node_center(nid)
		await HarnessInput.drag(vp, _to_vp(canvas, a), _to_vp(canvas, a + Vector2(140.0, 60.0)), 14)
		await _wait(tree, 0.5)
		var moved := lens.node_center(nid) - c0
		var want := Vector2(140.0, 60.0) / float(canvas.get("_zoom"))
		print("flowtorus: dragged %s by %s (asked %s)" % [nid, str(moved), str(want)])
		_ok(moved.distance_to(want) < 12.0 / float(canvas.get("_zoom")), "a real drag moves the node under the pointer")
		_ok(lens.pins().has(nid), "the lens keeps where it was put")
		var attached := true
		for rb3 in (lens.cur.get("ribbons", []) as Array):
			var p3: PackedVector2Array = rb3["path"]
			var r: Rect2 = (lens.cur["nodes"][nid]["rect"] as Rect2).grow(3.0)
			if str(rb3["a"]) == nid and not r.has_point(p3[0]):
				attached = false
			if str(rb3["b"]) == nid and not r.has_point(p3[p3.size() - 1]):
				attached = false
		_ok(attached, "its ribbons still end on it")
		_shot(vp, dir, "04_column_dragged")
		# It stays through a relayout.
		lens.force_next()
		lens.sig = ""
		await _wait(tree, 1.5)
		_ok(lens.node_center(nid).distance_to(c0 + moved) < 1.0, "it stays there through the next layout")
		var st: Dictionary = sgv.call("collect_save_state")
		_ok(((st.get("flows_pins", {}) as Dictionary).get("column", {}) as Dictionary).has(nid),
			"the save state carries it")
		var reset := _chip(lens, "reset", "")
		_ok(not reset.is_empty(), "the header offers Reset positions")
		if not reset.is_empty():
			await HarnessInput.click(vp, _to_vp(canvas, (reset["rect"] as Rect2).get_center()))
			await _wait(tree, 0.6)
			_ok(lens.pins().is_empty() and not bool(lens.cur["nodes"][nid].get("pinned", false)) \
				and lens.node_center(nid).distance_to(c0 + moved) > 20.0,
				"a real click on it puts the node back")

	# --- The torus --------------------------------------------------------
	var tchip := _chip(lens, "shape", "torus")
	_ok(not tchip.is_empty(), "the header offers Torus")
	if not tchip.is_empty():
		await HarnessInput.click(vp, _to_vp(canvas, (tchip["rect"] as Rect2).get_center()))
	await _wait(tree, 2.5)
	_ok(str(canvas.get("flows_shape")) == "torus" and str(lens.cur.get("shape", "")) == "torus",
		"a real click lays the scope out as a torus")
	var lay: Dictionary = lens.cur
	var N: Dictionary = lay.get("nodes", {})
	var cards := 0
	var discs := 0
	var off_axis := 0
	var sides := {-1: 0, 1: 0}
	var half := float((lay.get("axis", {}) as Dictionary).get("half", 0.0))
	for id in N:
		if str(N[id]["shape"]) == "card":
			cards += 1
			if absf((N[id]["rect"] as Rect2).get_center().x) > half + 1.0:
				off_axis += 1
		else:
			discs += 1
			sides[int(N[id]["side"])] = int(sides[int(N[id]["side"])]) + 1
	var loops: Array = lay.get("loops", [])
	var rets := 0
	for rb4 in (lay.get("ribbons", []) as Array):
		if str(rb4["kind"]) == LoopSankeyLayout.KIND_RETURN:
			rets += 1
	var ax: Dictionary = lay.get("axis", {})
	print("flowtorus: torus — %d on the axis, %d on the lobes (left %d, right %d), %d loops, %d closing flows, %d shells" % [
		cards, discs, int(sides[-1]), int(sides[1]), loops.size(), rets, (lay.get("guides", []) as Array).size()])
	print("flowtorus: torus — energy in %.0f W, heat out %.0f W" % [float(ax.get("energy_in", 0.0)), float(ax.get("heat_out", 0.0))])
	for lp in loops:
		print("flowtorus:   loop %d — %s" % [int(lp["id"]), ", ".join(PackedStringArray((lp["nodes"] as Array).map(
			func(x: Variant) -> String: return str((lay.get("labels", {}) as Dictionary).get(x, x)))))])
	_ok(cards >= 2 and off_axis == 0, "the energy nodes stand on the axis")
	_ok(discs >= 3, "the material nodes sit on the lobes")
	_ok(int(sides[-1]) > 0 and int(sides[1]) > 0, "both lobes are used")
	_ok(float(ax.get("energy_in", 0.0)) > 0.0 or float(ax.get("heat_out", 0.0)) > 0.0, "energy comes in or heat goes out")
	# A REAL click on "Swap sides" mirrors the lobes.
	var swap := _chip(lens, "swap", "swap")
	_ok(not swap.is_empty() and lens.mirror, "the header offers Swap sides (the lobes start swapped)")
	if not swap.is_empty():
		var before_side := {}
		for ids in N:
			before_side[ids] = int(N[ids]["side"])
		await HarnessInput.click(vp, _to_vp(canvas, (swap["rect"] as Rect2).get_center()))
		await _wait(tree, 2.0)
		var same_n := 0
		var flipped := 0
		for ids2 in (lens.cur.get("nodes", {}) as Dictionary):
			if before_side.has(ids2) and int(before_side[ids2]) != 0:
				same_n += 1
				if int(lens.cur["nodes"][ids2]["side"]) == -int(before_side[ids2]):
					flipped += 1
		print("flowtorus: swap sides — %d of %d lobe nodes changed lobe" % [flipped, same_n])
		_ok(not lens.mirror and same_n > 0 and flipped >= int(float(same_n) * 0.8), "a real click on it swaps the lobes")
		_ok(not bool((sgv.call("collect_save_state") as Dictionary).get("flows_mirror", true)), "the save state carries it")
		_shot(vp, dir, "05b_torus_swapped")
		var swap2 := _chip(lens, "swap", "swap")
		if not swap2.is_empty():
			await HarnessInput.click(vp, _to_vp(canvas, (swap2["rect"] as Rect2).get_center()))
		await _wait(tree, 2.0)
		lay = lens.cur
		N = lay.get("nodes", {})
	var vis := 0
	for id2 in lens.visuals:
		if str(lens.visuals[id2].get("kind", "")) != "":
			vis += 1
	_ok(vis > 0, "the stores carry their levels (%d)" % vis)
	_shot(vp, dir, "05_torus")
	var tor_ms: Array = await _frame_ms(tree, 8.0)
	print("flowtorus: torus at 60x — frame median %.1f ms, p95 %.1f ms" % [tor_ms[0], tor_ms[1]])
	_ok(float(tor_ms[0]) <= maxf(float(free_ms[0]) * 1.6, float(free_ms[0]) + 12.0),
		"the torus costs about what the freeform graph does (%.1f vs %.1f ms)" % [tor_ms[0], free_ms[0]])
	# Zoom in on a lobe.
	var did := _draggable(canvas, lens, "disc")
	_ok(did != "", "a lobe node to drag")
	if did != "":
		var a2 := _node_screen(canvas, lens, did)
		var c1 := lens.node_center(did)
		await HarnessInput.drag(vp, _to_vp(canvas, a2), _to_vp(canvas, a2 + Vector2(-90.0, 70.0)), 14)
		await _wait(tree, 0.5)
		var moved2 := lens.node_center(did) - c1
		_ok(moved2.length() > 40.0 / float(canvas.get("_zoom")) and lens.pins().has(did),
			"a real drag moves a lobe node too")
		# Dragged a little off its shell, it rides the shell.
		lens.clear_pins()
		var ndd: Dictionary = lens.auto["nodes"][did]
		var home := lens.node_center(did)
		var rgd: Dictionary = (lens.auto["rings"] as Array)[int(ndd["ring"])]
		var la := float(lens.auto.get("lobe_a", 0.0))
		# A point a little along the ring and a little off it.
		var on_ring := ToroidFlowLayout.ring_pt(la, rgd, float(ndd["frac"]) + 0.03)
		lens.set_pin(did, on_ring + Vector2(9.0, 7.0))
		var rode := lens.node_center(did)
		var off: float = ToroidFlowLayout.nearest_on_ring(lens.auto, int(ndd["ring"]), rode)[1]
		print("flowtorus: ring ride — %.1f from its ring, %.1f along from home" % [off, rode.distance_to(home)])
		_ok(off < 1.5 and rode.distance_to(home) > 4.0, "dragged along its ring, a lobe node rides it")
		var far_p := home + (home - Vector2(float(int(ndd["side"])) * la, 0.0)).normalized() * -120.0
		lens.set_pin(did, far_p)
		_ok(lens.node_center(did).distance_to(far_p) < 1.0, "pulled well off, it comes free")
		_ok(not (lens.pins_by_shape.get("column", {}) as Dictionary).has(did), "each shape keeps its own moves")
		_shot(vp, dir, "06_torus_dragged")
		lens.clear_pins()
	# A hover lights a loop.
	if not loops.is_empty():
		var first: String = str(((loops[0] as Dictionary)["nodes"] as Array)[0])
		for rb5 in (lay.get("ribbons", []) as Array):
			if int(rb5["loop"]) == int((loops[0] as Dictionary)["id"]):
				var p5: PackedVector2Array = rb5["path"]
				var mid := GraphFlowLens.to_screen(p5[p5.size() / 2], canvas.size * 0.5, canvas.get("_pan"), float(canvas.get("_zoom")))
				await HarnessInput.mouse_move(vp, _to_vp(canvas, mid))
				await _wait(tree, 0.4)
				break
		print("flowtorus: hover loop %d (first node %s)" % [lens.hover_loop, first])
		_ok(lens.hover_loop >= 0, "hovering a loop's ribbon lights the loop")
		_shot(vp, dir, "07_torus_hover_loop")
	# One resource on its own keeps the shape.
	var keys: Array = lens.keys_present
	for k in keys:
		if str(k) != "electricity":
			var ch := _chip(lens, "channel", str(k))
			if not ch.is_empty():
				await HarnessInput.click(vp, _to_vp(canvas, (ch["rect"] as Rect2).get_center()))
				await _wait(tree, 2.0)
				_ok(str(lens.cur.get("shape", "")) == "torus" and str(canvas.get("flows_channel")) == str(k),
					"one resource alone is still a torus (%s)" % str(k))
				_shot(vp, dir, "08_torus_one_resource")
				var all := _chip(lens, "channel", "")
				if not all.is_empty():
					await HarnessInput.click(vp, _to_vp(canvas, (all["rect"] as Rect2).get_center()))
				await _wait(tree, 1.5)
			break
	var w24 := _chip(lens, "window", "24h")
	if not w24.is_empty():
		await HarnessInput.click(vp, _to_vp(canvas, (w24["rect"] as Rect2).get_center()))
		await _wait(tree, 2.5)
		var l24: Dictionary = lens.cur
		print("flowtorus: torus over 24 h — %d nodes, %d loops, %d shells" % [
			(l24.get("nodes", {}) as Dictionary).size(), (l24.get("loops", []) as Array).size(),
			(l24.get("guides", []) as Array).size()])
		_shot(vp, dir, "09_torus_24h")
		var wnow := _chip(lens, "window", "now")
		if not wnow.is_empty():
			await HarnessInput.click(vp, _to_vp(canvas, (wnow["rect"] as Rect2).get_center()))
		await _wait(tree, 1.5)
	# A whole sim week at speed, then the week's window: does this site close
	# any loop, and if not, what breaks it?
	if OS.get_environment("FTC_DAY") != "0":
		main.set("time_scale", 7200.0 / 3600.0)
		await _wait(tree, 95.0)
		main.set("time_scale", 60.0 / 3600.0)
		var wd := _chip(lens, "window", "7d")
		if not wd.is_empty():
			await HarnessInput.click(vp, _to_vp(canvas, (wd["rect"] as Rect2).get_center()))
		await _wait(tree, 3.0)
		var ld: Dictionary = lens.cur
		var labs: Dictionary = ld.get("labels", {})
		print("flowtorus: after a sim week, 7 day window — %d nodes, %d ribbons, %d loops" % [
			(ld.get("nodes", {}) as Dictionary).size(), (ld.get("ribbons", []) as Array).size(),
			(ld.get("loops", []) as Array).size()])
		var crossing := 0
		for rb7 in (ld.get("ribbons", []) as Array):
			if str(rb7["a"]) == "" or str(rb7["b"]) == "":
				continue
			if int(ld["nodes"][str(rb7["a"])]["side"]) * int(ld["nodes"][str(rb7["b"])]["side"]) == -1:
				crossing += 1
		print("flowtorus:   %d of %d ribbons run between the lobes" % [crossing, (ld.get("ribbons", []) as Array).size()])
		for lp2 in (ld.get("loops", []) as Array):
			print("flowtorus:   week loop %d — %s" % [int(lp2["id"]), ", ".join(PackedStringArray((lp2["nodes"] as Array).map(
				func(x: Variant) -> String: return str(labs.get(x, x)))))])
		# Who feeds nothing on (sinks) and who is fed by nothing (sources):
		# where a chain ends is where a loop is left open.
		var has_out := {}
		var has_in := {}
		for rb6 in (ld.get("ribbons", []) as Array):
			if str(rb6["a"]) != "" and str(rb6["b"]) != "":
				has_out[str(rb6["a"])] = true
				has_in[str(rb6["b"])] = true
		var sinks: Array = []
		var sources: Array = []
		for id3 in (ld.get("nodes", {}) as Dictionary):
			if not has_out.has(str(id3)):
				sinks.append(str(labs.get(id3, id3)))
			if not has_in.has(str(id3)):
				sources.append(str(labs.get(id3, id3)))
		print("flowtorus:   chains start at: %s" % ", ".join(PackedStringArray(sources)))
		print("flowtorus:   chains end at: %s" % ", ".join(PackedStringArray(sinks)))
		_shot(vp, dir, "11_torus_after_a_week")
		var wn := _chip(lens, "window", "now")
		if not wn.is_empty():
			await HarnessInput.click(vp, _to_vp(canvas, (wn["rect"] as Rect2).get_center()))
		await _wait(tree, 1.5)
	var st2: Dictionary = sgv.call("collect_save_state")
	_ok(str(st2.get("flows_shape", "")) == "torus", "the save state carries the shape")
	# A closed site in the window view: sun down the axis, a pump and a
	# kitchen doing work, water and nutrients going round.
	var layer := CanvasLayer.new()
	layer.layer = 90
	main.add_child(layer)
	var lv: Control = (load("res://scenes/ui/loop_sankey_view.gd") as GDScript).new()
	lv.size = vp.get_visible_rect().size
	layer.add_child(lv)
	var ns: Array = []
	for nm in ["Array", "Battery", "Inverter", "Lights", "Pump", "Cistern", "People", "Greywater", "Filter", "Beds",
			"Pantry", "Kitchen", "Urine store", "Recovery", "Nutrients", "Rain", "Compost"]:
		ns.append({"id": nm, "label": nm})
	var es: Array = []
	for e3 in [["Array", "Battery", 900.0, "electricity"], ["Battery", "Inverter", 800.0, "electricity"],
			["Inverter", "Lights", 200.0, "electricity"], ["Inverter", "Pump", 250.0, "electricity"],
			["Inverter", "Kitchen", 200.0, "electricity"], ["Inverter", "Recovery", 150.0, "electricity"],
			["Rain", "Cistern", 12.0, "water"], ["Cistern", "Pump", 50.0, "water"], ["Pump", "People", 50.0, "water"],
			["People", "Greywater", 38.0, "water"], ["Greywater", "Filter", 38.0, "water"], ["Filter", "Cistern", 30.0, "water"],
			["Filter", "Beds", 8.0, "water"],
			["Beds", "Pantry", 6.0, "food"], ["Pantry", "Kitchen", 6.0, "food"], ["Kitchen", "People", 6.0, "food"],
			["People", "Urine store", 3.0, "nutrients"], ["Urine store", "Recovery", 3.0, "nutrients"],
			["Recovery", "Nutrients", 2.5, "nutrients"], ["Nutrients", "Beds", 2.5, "nutrients"],
			["Kitchen", "Compost", 1.0, "food"]]:
		es.append({"id": "%s>%s" % [e3[0], e3[1]], "a": e3[0], "b": e3[1], "key": e3[3], "value": e3[2]})
	var cols := {"electricity": Color(0.98, 0.74, 0.26), "water": Color(0.30, 0.80, 0.95),
		"food": Color(0.45, 0.85, 0.45), "nutrients": Color(0.80, 0.55, 0.95)}
	lv.call("set_input", {"nodes": ns, "edges": es,
		"bin": [{"node": "Array", "key": "electricity", "value": 900.0, "label": "sun"},
			{"node": "Rain", "key": "water", "value": 12.0, "label": "rain"}],
		"bout": [{"node": "Lights", "key": "electricity", "value": 200.0, "label": "used"},
			{"node": "Pump", "key": "electricity", "value": 250.0, "label": "used"},
			{"node": "Kitchen", "key": "electricity", "value": 200.0, "label": "used"},
			{"node": "Recovery", "key": "electricity", "value": 150.0, "label": "used"},
			{"node": "Beds", "key": "water", "value": 8.0, "label": "to the air"}],
		"labels": {}, "types": {}, "keys": ["electricity", "water", "food", "nutrients"], "opts": {"thickness": 34.0},
		"visuals": {"Cistern": {"kind": "store", "level": 0.62, "color": cols["water"]},
			"Greywater": {"kind": "store", "level": 0.3, "color": cols["water"]},
			"Pantry": {"kind": "store", "level": 0.8, "color": cols["food"]},
			"Urine store": {"kind": "store", "level": 0.45, "color": cols["nutrients"]},
			"Nutrients": {"kind": "store", "level": 0.2, "color": cols["nutrients"]},
			"Battery": {"kind": "battery", "level": 0.7, "color": Color(0.36, 0.86, 0.52)}}},
		func(k: String, v: float) -> String: return UiText.num(v, "W") if k == "electricity" else "%s/h" % UiText.num(v, "L"),
		func(k: String) -> Color: return cols.get(k, Color(0.6, 0.7, 0.9)),
		func(k: String) -> String: return k.capitalize())
	await _wait(tree, 1.0)
	_shot(vp, dir, "10a_window_column")
	# A REAL click on the window's own Torus chip.
	var tor_chip := Rect2()
	for ch2 in (lv.get("_shape_chips") as Array):
		if str(ch2[1]) == "torus":
			tor_chip = ch2[0]
	_ok(tor_chip.size.x > 0.0, "the window view offers Torus")
	await HarnessInput.click(vp, _to_vp(lv, tor_chip.get_center()))
	await _wait(tree, 1.2)
	var syn: Dictionary = (lv.get("lens") as GraphFlowLens).cur
	print("flowtorus: synthetic closed site — %d loops, %d shells, %.0f %% of water cycled" % [
		(syn.get("loops", []) as Array).size(), (syn.get("guides", []) as Array).size(),
		float(((syn.get("metrics", {}) as Dictionary).get("water", {}) as Dictionary).get("fci", 0.0)) * 100.0])
	_ok(str(syn.get("shape", "")) == "torus" and (syn.get("loops", []) as Array).size() >= 2,
		"a closed site draws its loops as shells round the axis")
	_shot(vp, dir, "10_torus_closed_site")
	layer.queue_free()
	await _wait(tree, 0.3)
	# Back as it was.
	var cchip := _chip(lens, "shape", "column")
	if not cchip.is_empty():
		await HarnessInput.click(vp, _to_vp(canvas, (cchip["rect"] as Rect2).get_center()))
	await _wait(tree, 1.5)
	_ok(str(canvas.get("flows_shape")) == "column", "a real click goes back to the column")
	sgv.call("_on_mode_chip_pressed", GraphSiteLayout.VIEW_FREEFORM)
	await _wait(tree, 0.8)
	return {"ok": _fails.is_empty(), "fails": _fails}
