extends RefCounted

## Sandbox, read-only: who fills the time AFTER every _process and before the
## render starts (deferred calls, GUI layout, the delete queue, timers,
## tweens). Graph closed, clock at noon and BISECT_SPEED. A baseline window,
## then one window per candidate node with that node switched off (process
## disabled, a CanvasItem / CanvasLayer also hidden), each put back after.
## Prints the mean frame, the mean time after the scripts, and how many
## frames spent over 20 ms there.
##   tools\harness.ps1 -World walton -RunScript res://tools/bench/deferred_bisect_bench.gd -Timeout 900
## BISECT_IN=<path under Main> bisects that node's children (default: Main's);
## BISECT_ONLY=Name,Name limits the candidates.

const WINDOW_S := 7.0
const SETTLE_S := 1.5
const BISECT_SPEED := 60.0


var _probe: Node = null


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", 12.0)
	main.set("time_scale", BISECT_SPEED / 3600.0)
	var probe_a: Node = load("res://tools/bench/frame_phase_probe.gd").new()
	var probe_b: Node = load("res://tools/bench/frame_phase_probe.gd").new()
	probe_b.set("last", true)
	main.add_child(probe_a)
	main.add_child(probe_b)
	_probe = probe_a
	# Past the load settling (terrain tiles, imagery uploads).
	await _wait(tree, 25.0)
	var cands: Array = []
	var only := OS.get_environment("BISECT_ONLY")
	var only_set := {}
	for t in only.split(",", false):
		only_set[t.strip_edges()] = true
	# BISECT_IN=UILayer bisects that node's children instead of Main's.
	var inside := OS.get_environment("BISECT_IN")
	var parent_node: Node = main.get_node_or_null(inside) if not inside.is_empty() else main
	for parent in [parent_node]:
		if parent == null:
			continue
		for c in parent.get_children():
			if c == probe_a or c == probe_b:
				continue
			if not only_set.is_empty() and not only_set.has(str(c.name)):
				continue
			cands.append(c)
	var base := await _window(tree)
	_print("baseline", base)
	for c in cands:
		var node := c as Node
		if not is_instance_valid(node):
			continue
		var pm := node.process_mode
		var was_vis: Variant = node.get("visible")
		node.process_mode = Node.PROCESS_MODE_DISABLED
		if was_vis != null:
			node.set("visible", false)
		await _wait(tree, SETTLE_S)
		var r := await _window(tree)
		if is_instance_valid(node):
			node.process_mode = pm
			if was_vis != null:
				node.set("visible", was_vis)
		_print(str(node.get_path()).trim_prefix(str(main.get_path())), r)
		await _wait(tree, SETTLE_S)
	var again := await _window(tree)
	_print("baseline again", again)
	return {"ok": true}


func _window(tree: SceneTree) -> Dictionary:
	var n := 0
	var sum_frame := 0.0
	var sum_after := 0.0
	var heavy := 0
	var max_after := 0.0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(WINDOW_S * 1000.0):
		await tree.process_frame
		var ph: Dictionary = _probe.call("phases")
		var a := float(ph.get("after_scripts", 0.0))
		if a > 200.0:
			continue   # a misaligned first frame
		n += 1
		sum_after += a
		max_after = maxf(max_after, a)
		if a > 20.0:
			heavy += 1
		sum_frame += float(ph.get("scripts", 0.0)) + a + float(ph.get("render_main", 0.0)) \
			+ float(ph.get("physics", 0.0)) + float(ph.get("between", 0.0))
	return {"n": n, "frame": sum_frame / maxf(float(n), 1.0),
		"after": sum_after / maxf(float(n), 1.0), "heavy": heavy, "max_after": max_after}


func _print(label: String, r: Dictionary) -> void:
	print("bisect %-46s frames %4d  mean %5.1f ms  after-scripts mean %5.2f max %5.1f  >20 ms in %3d" % [
		label, int(r["n"]), float(r["frame"]), float(r["after"]), float(r["max_after"]), int(r["heavy"])])


func _wait(tree: SceneTree, secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		await tree.process_frame
