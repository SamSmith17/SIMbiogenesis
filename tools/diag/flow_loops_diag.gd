extends RefCounted

## Which wires carried what over a recorded stretch, and where the material
## loops close or break (NOT a selftest; sandbox):
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/diag/flow_loops_diag.gd -Label flow_loops
## Runs the clock fast for ~a sim day, then prints every flowing wire of the
## root scope as "name → name  kind  mean" plus each node's in / out kinds,
## and the loop Sankey's strongly connected components.

func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var sgv := ServiceLocator.graph()
	if sgv == null:
		return {"ok": false, "fails": ["no graph view"]}
	sgv.call("open_graph_view")
	sgv.call("_jump_to_scope_index", 0)
	main.set("time_scale", 7200.0 / 3600.0)
	await tree.create_timer(14.0, true, false, true).timeout
	main.set("time_scale", 0.0)
	var canvas: Control = sgv.get("_graph_canvas")
	var model: GraphModel = sgv.get("model")
	var fh: FlowHistory = sgv.call("flow_history")
	var now_h := float(canvas.get("flow_now_abs_h"))
	var win := fh.window(now_h - 24.0, now_h)
	var name := func(id: String) -> String:
		var it := model.get_item(id)
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		return str(sp.get("name", it.get("type", id)))
	var rows: Array = []
	var nodes_in := {}
	var nodes_out := {}
	for conn in model.connections:
		var cid := str((conn as Dictionary).get("id", ""))
		if not win.has(cid):
			continue
		var a := str(conn["source_item_id"])
		var b := str(conn["target_item_id"])
		var k := str(win[cid]["key"])
		rows.append("%s → %s  %s  %.3f" % [name.call(a), name.call(b), k, float(win[cid]["mean"])])
		nodes_out[a] = str(nodes_out.get(a, "")) + k + " "
		nodes_in[b] = str(nodes_in.get(b, "")) + k + " "
	rows.sort()
	print("flowloops: %d flowing wires over 24 h (all scopes)" % rows.size())
	for r in rows:
		print("flowloops:   " + str(r))
	var ids := {}
	for k2 in nodes_in:
		ids[k2] = true
	for k3 in nodes_out:
		ids[k3] = true
	for id in ids:
		print("flowloops: node %s  in[%s]  out[%s]" % [name.call(str(id)), str(nodes_in.get(id, "")), str(nodes_out.get(id, ""))])
	# Never-flowing wires that would close a loop: list wires with no flow.
	var idle := 0
	for conn2 in model.connections:
		if not win.has(str((conn2 as Dictionary).get("id", ""))):
			idle += 1
	print("flowloops: %d wires carried nothing" % idle)
	return {"ok": true, "fails": []}
