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



## Which array (controller) each PV source in `scope_id` feeds: id -> the
## controller's id. Panels feeding the same controller are one array — the
## freeform snap prefers lining a panel up with its own array.
static func array_keys(model: GraphModel, scope_id: String = "root") -> Dictionary:
	var out := {}
	if model == null:
		return out
	for it in model.get_items_in_scope(scope_id):
		var d: Dictionary = it
		if str(d.get("type", "")) != "controller":
			continue
		var cid := str(d.get("id", ""))
		for sid in PvElectrical.pv_sources_for_controller(model, cid, scope_id):
			if not out.has(str(sid)):
				out[str(sid)] = cid
		# An array with its panels inside is a group, not a source: the panels
		# behind its ports feed the controller, so key the array card by them.
		for pid in PvElectrical.pv_sources_for_controller_flat(model, cid,
				GraphNesting.flat_connections_cached(model)):
			var owner := str(model.get_item(str(pid)).get("parent_compound_id", ""))
			if not owner.is_empty() and not out.has(owner) \
					and GraphSolarArrays.is_solar_array(model.get_item(owner)):
				out[owner] = cid
	return out


## The panels split into their SERIES strings, each in chain order (end to
## end along its series links), strings ordered by where they sit (top first).
## Panels with no series link are strings of one.
static func string_rows(model: GraphModel, panel_ids: Array, scope_id: String = "root") -> Array:
	var conns: Array = model.get_connections_in_scope(scope_id)
	var comps: Array = PvElectrical.connected_components(panel_ids, conns, true)
	var rows: Array = []
	for comp in comps:
		rows.append(_chain_order(model, comp as Array, conns))
	rows.sort_custom(func(a: Array, b: Array) -> bool:
		return _mean_y(model, a) < _mean_y(model, b))
	return rows


static func _mean_y(model: GraphModel, ids: Array) -> float:
	var t := 0.0
	for i in ids:
		t += float(model.get_item(str(i)).get("y", 0.0))
	return t / maxf(float(ids.size()), 1.0)


static func _chain_order(model: GraphModel, comp: Array, conns: Array) -> Array:
	if comp.size() <= 2:
		var c := comp.duplicate()
		c.sort_custom(func(a, b) -> bool:
			return float(model.get_item(str(a)).get("x", 0.0)) < float(model.get_item(str(b)).get("x", 0.0)))
		return c
	var inset := {}
	for i in comp:
		inset[str(i)] = true
	var adj := {}
	for i in comp:
		adj[str(i)] = []
	for c in conns:
		var cd: Dictionary = c
		var a := str(cd.get("source_item_id", ""))
		var b := str(cd.get("target_item_id", ""))
		if inset.has(a) and inset.has(b) and a != b:
			(adj[a] as Array).append(b)
			(adj[b] as Array).append(a)
	# Start at an end of the chain (one neighbour), else the leftmost panel.
	var start := ""
	for i in comp:
		if (adj[str(i)] as Array).size() == 1:
			if start.is_empty() or float(model.get_item(str(i)).get("x", 0.0)) \
					< float(model.get_item(start).get("x", 0.0)):
				start = str(i)
	if start.is_empty():
		start = str(comp[0])
	var out: Array = [start]
	var seen := {start: true}
	var cur := start
	while out.size() < comp.size():
		var nxt := ""
		for n in adj[cur]:
			if not seen.has(str(n)):
				nxt = str(n)
				break
		if nxt.is_empty():
			break
		out.append(nxt)
		seen[nxt] = true
		cur = nxt
	for i in comp:
		if not seen.has(str(i)):
			out.append(str(i))
	return out


## Lay panels out as a clean grid: each entry of `rows` is one row (a series
## string in chain order), rows stacked downward. The grid keeps the top-left
## of the panels' current bounding box, so the array does not jump away.
static func layout_panels_grid(model: GraphModel, rows: Array, gap_x: float = 24.0,
		gap_y: float = 28.0) -> void:
	var min_x := INF
	var min_y := INF
	for r in rows:
		for pid in r:
			var it := model.get_item(str(pid))
			if it.is_empty():
				continue
			min_x = minf(min_x, float(it.get("x", 0.0)))
			min_y = minf(min_y, float(it.get("y", 0.0)))
	if min_x == INF:
		return
	var y := min_y
	for r in rows:
		var x := min_x
		var row_h := 0.0
		for pid in r:
			var it := model.get_item(str(pid))
			if it.is_empty():
				continue
			model.update_item(str(pid), {"x": x, "y": y})
			x += float(it.get("width", 120.0)) + gap_x
			row_h = maxf(row_h, float(it.get("height", 90.0)))
		y += row_h + gap_y
