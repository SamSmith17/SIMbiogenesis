class_name GraphPvWiring
extends RefCounted

## Auto-connect selected panels in series or parallel to a controller's PV ports.


static func add_pv_connection(model: GraphModel, polarity: String,
		src_id: String, src_handle: String, tgt_id: String, tgt_handle: String,
		scope_id: String = "root") -> void:
	model.add_connection({
		"id": model.generate_connection_id(),
		"source_item_id": src_id,
		"source_handle_id": src_handle,
		"target_item_id": tgt_id,
		"target_handle_id": tgt_handle,
		"polarity": polarity,
		"scope_id": scope_id,
		"voltage_mismatch": false,
	})


static func wire_series(model: GraphModel, panel_ids: Array, controller_id: String,
		scope_id: String = "root") -> void:
	if panel_ids.is_empty() or controller_id.is_empty():
		return
	var ordered: Array = panel_ids.duplicate()
	for i in range(ordered.size() - 1):
		var a := str(ordered[i])
		var b := str(ordered[i + 1])
		add_pv_connection(model, "positive",
			a, "positive", b, "negative", scope_id)
	var first := str(ordered[0])
	var last := str(ordered[ordered.size() - 1])
	add_pv_connection(model, "negative",
		first, "negative", controller_id, "pvNegative", scope_id)
	add_pv_connection(model, "positive",
		last, "positive", controller_id, "pvPositive", scope_id)


static func wire_parallel(model: GraphModel, panel_ids: Array, controller_id: String,
		scope_id: String = "root") -> void:
	if panel_ids.is_empty() or controller_id.is_empty():
		return
	for i in panel_ids.size():
		var pid := str(panel_ids[i])
		add_pv_connection(model, "positive",
			pid, "positive", controller_id, "pvPositive", scope_id)
		add_pv_connection(model, "negative",
			pid, "negative", controller_id, "pvNegative", scope_id)


static func layout_panels_row(model: GraphModel, panel_ids: Array,
		spacing_x: float = 168.0, spacing_y: float = 0.0) -> void:
	if panel_ids.is_empty():
		return
	var cx := 0.0
	var cy := 0.0
	var n := panel_ids.size()
	for pid_v in panel_ids:
		var it := model.get_item(str(pid_v))
		if it.is_empty():
			continue
		cx += float(it.get("x", 0.0)) + float(it.get("width", 120.0)) * 0.5
		cy += float(it.get("y", 0.0)) + float(it.get("height", 90.0)) * 0.5
	cx /= float(n)
	cy /= float(n)
	var total_w := float(n - 1) * spacing_x
	var start_x := cx - total_w * 0.5
	for i in panel_ids.size():
		var pid := str(panel_ids[i])
		var it := model.get_item(pid)
		if it.is_empty():
			continue
		var w := float(it.get("width", 120.0))
		model.update_item(pid, {
			"x": start_x + float(i) * spacing_x - w * 0.5,
			"y": cy - float(it.get("height", 90.0)) * 0.5 + spacing_y,
		})


static func nearest_controller_id(model: GraphModel, panel_ids: Array,
		scope_id: String = "root") -> String:
	if model == null or panel_ids.is_empty():
		return ""
	var cx := 0.0
	var cy := 0.0
	for pid_v in panel_ids:
		var it := model.get_item(str(pid_v))
		if it.is_empty():
			continue
		cx += float(it.get("x", 0.0)) + float(it.get("width", 120.0)) * 0.5
		cy += float(it.get("y", 0.0)) + float(it.get("height", 90.0)) * 0.5
	cx /= float(panel_ids.size())
	cy /= float(panel_ids.size())
	var best := ""
	var best_d := INF
	for item in model.get_items_in_scope(scope_id):
		if not (item is Dictionary):
			continue
		if str((item as Dictionary).get("type", "")) != "controller":
			continue
		var it: Dictionary = item
		var px := float(it.get("x", 0.0)) + float(it.get("width", 120.0)) * 0.5
		var py := float(it.get("y", 0.0)) + float(it.get("height", 90.0)) * 0.5
		var d := Vector2(px - cx, py - cy).length_squared()
		if d < best_d:
			best_d = d
			best = str(it.get("id", ""))
	return best
