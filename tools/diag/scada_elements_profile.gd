extends RefCounted

## Sandbox: what the two once-a-second jobs cost, piece by piece. The SCADA
## tag gather (ScadaHub.refresh) and the element tick
## (SystemGraphView._tick_elements). Each piece runs SEP_RUNS times (default
## 10) at 60x; prints mean and worst ms per piece.
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/scada_elements_profile.gd -Timeout 900

var _us: Dictionary = {}
var _max: Dictionary = {}
var _order: Array = []


func _t(name: String, us: int) -> void:
	if not _us.has(name):
		_order.append(name)
	_us[name] = int(_us.get(name, 0)) + us
	_max[name] = maxi(int(_max.get(name, 0)), us)


## ElementLedger.compute's own parts, timed (its body, in its order).
func _ledger_parts(model: GraphModel) -> void:
	var u := Time.get_ticks_usec()
	var out := {"stock": ElementLedger._empty_stock(), "stores": [], "unknown": [], "nodes": {},
		"boundary": {"rain": ElementLedger._side(), "imports": ElementLedger._side(), "in": ElementLedger._side(),
			"out": ElementLedger._side(), "exports": ElementLedger._side()},
		"unaccounted": [], "leaks": [], "water": {"used_kg_h": 0.0, "recovered_kg_h": 0.0, "ratio": NAN},
		"air": {"out": ElementLedger._side(), "in": ElementLedger._side(), "gases": {}}, "dumped": ElementLedger._side(),
		"edges": [], "scope_id": "root"}
	var items: Array = GraphNesting.walk_items(model, "root")
	var inside: Dictionary = {}
	for it in items:
		inside[str((it as Dictionary).get("id", ""))] = it
	_t("  ledger: walk items", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	ElementLedger._stocks(items, out)
	_t("  ledger: stocks", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	var rate_of: Dictionary = {}
	var mu_of: Dictionary = {}
	for c in model.connections:
		var cd: Dictionary = c
		rate_of[str(cd.get("id", ""))] = float(cd.get("flow_rate", 0.0))
		if cd.get("make_up") is Dictionary:
			mu_of[str(cd.get("id", ""))] = cd["make_up"]
	var nodes: Dictionary = out["nodes"]
	var has_mat_in: Dictionary = {}
	var inflow_to: Dictionary = {}
	var wires: Array = []
	var n_wires := 0
	for fc in GraphNesting.flat_connections_cached(model):
		var f: Dictionary = fc
		if str(f.get("polarity", "")) != "resource":
			continue
		var kind := str(f.get("resource_type", ""))
		if kind.is_empty() or not CompositionCatalog.is_material(kind):
			continue
		var src := str(f.get("source_item_id", ""))
		var tgt := str(f.get("target_item_id", ""))
		if not inside.has(src) and not inside.has(tgt):
			continue
		if inside.has(tgt):
			has_mat_in[tgt] = true
		var rate := float(rate_of.get(str(f.get("id", "")), 0.0))
		if rate <= 0.0:
			continue
		var emb := MakeUp.embodied(kind, rate, mu_of.get(str(f.get("id", "")), {}))
		if not bool(emb["known"]):
			continue
		n_wires += 1
		wires.append({"src": src, "tgt": tgt, "kind": kind, "emb": emb, "rate": rate})
		if inside.has(tgt):
			inflow_to[tgt] = float(inflow_to.get(tgt, 0.0)) + float(emb["kg"])
	_t("  ledger: wires (embodied)", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	for w in wires:
		var si: Dictionary = inside.get(str(w["src"]), {})
		var ti: Dictionary = inside.get(str(w["tgt"]), {})
		if not si.is_empty() and ElementLedger._is_node(si):
			ElementLedger._node(nodes, si)["out"].append({"kind": w["kind"], "emb": w["emb"], "rate": float(w["rate"])})
		if not ti.is_empty() and ElementLedger._is_node(ti):
			ElementLedger._node(nodes, ti)["in"].append({"kind": w["kind"], "emb": w["emb"], "rate": float(w["rate"])})
	_t("  ledger: node lists", Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	ElementLedger._finish_nodes(nodes, out)
	_t("  ledger: finish nodes (%d)" % nodes.size(), Time.get_ticks_usec() - u)
	u = Time.get_ticks_usec()
	ElementLedger._leaks(items, inflow_to, out)
	_t("  ledger: leaks", Time.get_ticks_usec() - u)


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 300:
		await tree.process_frame
	var view: Node = main.find_child("SystemGraphView", true, false)
	if view == null:
		return {"ok": false, "why": "no SystemGraphView"}
	main.set("time_scale", 60.0 / 3600.0)
	for _i in 120:
		await tree.process_frame
	var hub: Node = view.call("scada_hub")
	var model: GraphModel = view.get("model")
	var canvas: Node = view.get("_graph_canvas")
	var fe: Object = view.get("_resource_flow")
	var n := int(OS.get_environment("SEP_RUNS")) if OS.get_environment("SEP_RUNS") != "" else 10
	var counts := {}
	for k in n:
		await tree.process_frame
		await tree.process_frame
		# --- SCADA refresh, piece by piece (its own order) ---
		var u := Time.get_ticks_usec()
		var tags: Array = ScadaTags.graph_tags(model)
		_t("scada: graph_tags", Time.get_ticks_usec() - u)
		counts["graph tags"] = tags.size()
		u = Time.get_ticks_usec()
		tags.append_array(ScadaTags.site_tags(hub.call("_site_power")))
		_t("scada: site_tags", Time.get_ticks_usec() - u)
		u = Time.get_ticks_usec()
		var esp: Array = hub.call("_esp_tags")
		tags.append_array(esp)
		_t("scada: esp_tags", Time.get_ticks_usec() - u)
		u = Time.get_ticks_usec()
		tags.append_array(ScadaTags.ha_tags(hub.call("_ha_states")))
		_t("scada: ha_tags", Time.get_ticks_usec() - u)
		counts["all tags"] = tags.size()
		u = Time.get_ticks_usec()
		(hub.get("_book") as Object).call("set_all", tags)
		_t("scada: book.set_all", Time.get_ticks_usec() - u)
		u = Time.get_ticks_usec()
		ScadaTags.context(esp)
		_t("scada: context", Time.get_ticks_usec() - u)
		u = Time.get_ticks_usec()
		var h := float(hub.call("now_h"))
		(hub.get("_hist") as Object).call("record", (hub.get("_book") as Object).call("all"), h)
		_t("scada: history record", Time.get_ticks_usec() - u)
		u = Time.get_ticks_usec()
		hub.call("refresh")
		_t("scada: refresh() whole", Time.get_ticks_usec() - u)
		# --- element tick, piece by piece ---
		await tree.process_frame
		(view.get("_element_leds") as Dictionary).clear()
		u = Time.get_ticks_usec()
		var led: Variant = view.call("element_ledger", "root")
		_t("elements: element_ledger(root)", Time.get_ticks_usec() - u)
		_ledger_parts(model)
		u = Time.get_ticks_usec()
		(view.get("_element_history") as Object).call("record", float(view.call("_closure_abs_hours")), led)
		_t("elements: history record", Time.get_ticks_usec() - u)
		if canvas != null and canvas.has_method("flow_values_now"):
			u = Time.get_ticks_usec()
			var sampled: Dictionary = canvas.call("flow_values_now")
			_t("elements: canvas.flow_values_now", Time.get_ticks_usec() - u)
			counts["sampled wires"] = sampled.size()
		u = Time.get_ticks_usec()
		view.call("_record_flow_history")
		_t("elements: _record_flow_history whole", Time.get_ticks_usec() - u)
	for k2 in counts.keys():
		print("sep: %s %d" % [k2, int(counts[k2])])
	for name in _order:
		print("sep:   %-40s mean %6.3f ms  worst %6.3f ms" % [name, float(_us[name]) / float(n) / 1000.0,
			float(_max[name]) / 1000.0])
	return {"ok": true}
