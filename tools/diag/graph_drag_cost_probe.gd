extends RefCounted

## Sandbox: what a node drag costs on the open graph (freeform). For a few
## nodes on screen it runs the canvas's own drag with REAL mouse events
## (press, 30 motions of 2 px a frame, release) and times, per motion, the
## event's own handling and the whole frame it lands in; then the same 30
## motions with no button held (hover only) as the baseline. Also counts how
## far user_rev moves and how many history entries one drag leaves.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/graph_drag_cost_probe.gd

const HI := preload("res://core/terrain/harness/harness_input.gd")


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 200:
		await tree.process_frame
	var v: Node = main.find_child("SystemGraphView", true, false)
	if v == null:
		return {"ok": false, "why": "no SystemGraphView"}
	v.call("open_graph_view")
	for _i in 60:
		await tree.process_frame
	v.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	for _i in 90:
		await tree.process_frame
	var canvas: Control = v.get("_graph_canvas")
	var model: GraphModel = v.get("model")
	var vp := main.get_viewport()
	var center := canvas.size * 0.5
	var picks: Array = []
	var scope := str(canvas.get("active_scope_id"))
	if canvas.has_method("stop_fly"):
		canvas.call("stop_fly")
	# Plain machines and stores at the root, each centred on screen at zoom 1
	# just before it is dragged.
	for it: Dictionary in model.get_items_in_scope(scope):
		var t := str(it.get("type", ""))
		if t in ["compound", "panel"] or bool(it.get("is_virtual", false)) \
				or str(it.get("id", "")).begins_with("pbi_"):
			continue
		picks.append(str(it["id"]))
		if picks.size() >= 4:
			break
	if picks.is_empty():
		return {"ok": false, "why": "no node on screen"}
	print("graphdrag: %d items, %d wires, dragging %s" % [model.items.size(),
		model.connections.size(), str(picks)])
	var ev_ms: Array = []
	var fr_ms: Array = []
	var hov_ev: Array = []
	var hov_fr: Array = []
	var rel_ms: Array = []
	var rev0 := model.user_rev
	var moved_ok := true
	var hist0 := int((v.get("_history") as Object).call("undo_depth"))
	for pk in picks:
		var it: Dictionary = model.get_item(str(pk))
		canvas.set("_zoom", 1.0)
		var sz0: Vector2 = canvas.call("_item_screen_size", it)
		canvas.set("_pan", -(Vector2(float(it.get("x", 0.0)), float(it.get("y", 0.0))) + sz0 * 0.5))
		canvas.queue_redraw()
		for _i in 10:
			await tree.process_frame
		var tl: Vector2 = canvas.call("_item_screen_tl", it, center)
		var sz: Vector2 = canvas.call("_item_screen_size", it)
		var sp: Vector2 = canvas.get_global_transform() * (tl + sz * 0.5)
		var x0 := float(it.get("x", 0.0))
		# Hover baseline: the same path with no button.
		await HI.mouse_move(vp, sp)
		for k in 30:
			var p := sp + Vector2(2.0 * (k + 1), 0.0)
			var t0 := Time.get_ticks_usec()
			HI._push_motion(vp, p, false, false, false)
			hov_ev.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			var tf := Time.get_ticks_usec()
			await tree.process_frame
			hov_fr.append(float(Time.get_ticks_usec() - tf) / 1000.0)
		await HI.mouse_move(vp, sp)
		await HI.mouse_press(vp, sp, true)
		for k in 30:
			var p := sp + Vector2(2.0 * (k + 1), 0.0)
			var t0 := Time.get_ticks_usec()
			HI._push_motion(vp, p, false, false, true)
			ev_ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			var tf := Time.get_ticks_usec()
			await tree.process_frame
			fr_ms.append(float(Time.get_ticks_usec() - tf) / 1000.0)
		var tr := Time.get_ticks_usec()
		HI._push_motion(vp, sp + Vector2(60.0, 0.0), false, false, true)
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = false
		ev.position = sp + Vector2(60.0, 0.0)
		ev.global_position = ev.position
		vp.push_input(ev, true)
		rel_ms.append(float(Time.get_ticks_usec() - tr) / 1000.0)
		for _i in 20:
			await tree.process_frame
		var x1 := float((model.get_item(str(pk)) as Dictionary).get("x", 0.0))
		print("graphdrag: %s moved %.1f px in x" % [str(pk), x1 - x0])
		moved_ok = moved_ok and absf(x1 - x0 - 60.0) < 0.5
	var hist1 := int((v.get("_history") as Object).call("undo_depth"))
	# One Ctrl+Z puts the last dragged node back where it started.
	var last := str(picks[-1])
	var xa := float((model.get_item(last) as Dictionary).get("x", 0.0))
	v.call("_do_undo")
	await tree.process_frame
	var xb := float((model.get_item(last) as Dictionary).get("x", 0.0))
	var undo_ok := absf(xa - xb - 60.0) < 0.5
	print("graphdrag: undo moved %s back %.1f px (%s)" % [last, xa - xb, "PASS" if undo_ok else "FAIL"])
	for a in [ev_ms, fr_ms, hov_ev, hov_fr, rel_ms]:
		a.sort()
	print("graphdrag: drag motion handling median %.2f ms (worst %.2f); frame median %.2f ms (worst %.2f)" % [
		float(ev_ms[ev_ms.size() / 2]), float(ev_ms[-1]), float(fr_ms[fr_ms.size() / 2]), float(fr_ms[-1])])
	print("graphdrag: hover motion handling median %.2f ms; frame median %.2f ms" % [
		float(hov_ev[hov_ev.size() / 2]), float(hov_fr[hov_fr.size() / 2])])
	print("graphdrag: release median %.2f ms; user_rev moved %d over %d drags; history %d -> %d" % [
		float(rel_ms[rel_ms.size() / 2]), model.user_rev - rev0, picks.size(), hist0, hist1])
	var one_each := hist1 - hist0 == picks.size()
	print("graphdrag: every node moved 60 px %s, one undo entry per drag %s" % [
		"PASS" if moved_ok else "FAIL", "PASS" if one_each else "FAIL"])
	return {"ok": moved_ok and one_each and undo_ok}
