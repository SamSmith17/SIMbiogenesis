extends RefCounted

## Why a pond tank's level moves across a pre-render (diagnostic).
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/pond_level_trace.gd -Label pond_trace -Timeout 600
## Prints the pond tank's spec level beside what its timeline holds at the
## playhead, over a few seconds with the clock held, then across a seek.


func _line(tag: String, model: Object, flow: Object, id: String, now: float) -> void:
	var sp: Dictionary = (model.call("get_item", id) as Dictionary).get("specs", {})
	var tls: Dictionary = flow.get("_timelines") if flow.get("_timelines") != null else {}
	var tl: Object = tls.get(id, null)
	var tl_txt := "no timeline"
	if tl != null:
		var s: Variant = tl.call("sample_at", now) if tl.has_method("sample_at") else null
		tl_txt = "timeline %s" % str(s)
	print("pondtrace %s: level %.6f stock_l %s level_m %s cap %s | %s" % [tag, float(sp.get("level", 0.0)),
		str(sp.get("stock_l", "-")), str(sp.get("level_m", "-")), str(sp.get("capacity_qty", "-")), tl_txt])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var view: Node = ServiceLocator.graph()
	var model: Object = view.get("model")
	var flow: Object = view.call("resource_flow_engine")
	main.set("time_scale", 0.0)
	var id := ""
	for it in (model.get("items") as Array):
		var sp: Dictionary = (it as Dictionary).get("specs", {})
		if str(it.get("type", "")) == "resource" and (bool(sp.get("pond_storage", false)) or str(sp.get("name", "")).begins_with("Pond")):
			id = str(it["id"])
	print("pondtrace: pond tank %s; engine members: %s" % [id, str(flow.get_property_list().filter(func(p: Dictionary) -> bool: return "timeline" in str(p["name"]).to_lower()).map(func(p: Dictionary) -> String: return str(p["name"])))])
	var now := float(main.call("get_absolute_hours"))
	for k in 4:
		_line("held %d" % k, model, flow, id, now)
		for _i in 45:
			await tree.process_frame
	view.call("_begin_sim_writes")
	flow.call("seek_all_tanks", now)
	view.call("_end_sim_writes")
	_line("after seek", model, flow, id, now)
	for _i in 60:
		await tree.process_frame
	_line("1 s later", model, flow, id, now)
	return {"ok": true}
