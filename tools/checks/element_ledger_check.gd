extends RefCounted

## Resource composition Phase 2 on a real world (sandbox, read-only): the
## ElementLedger over the live graph while the clock runs, the dashboard's
## WATER & NUTRIENTS card, and the inspector's Made of / Mass balance /
## Carries now sections, with shots.
##
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/checks/element_ledger_check.gd -Label element_ledger -Timeout 900
##
## Prints the stocks, water recovery, what does not add up and the leaks
## (the numbers a PNG cannot show), and the ledger's cost in ms.

var _fails := 0
var _dir := "user://screenshots/element_ledger"


func _ok(cond: bool, what: String) -> void:
	print("element-ledger %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails += 1


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	img.save_png("%s/%s.png" % [_dir, name])


func _frames(tree: SceneTree, n: int) -> void:
	for i in n:
		await tree.process_frame


static func _texts(n: Node, out: Array) -> void:
	if n is Label:
		out.append((n as Label).text)
	for c in n.get_children():
		_texts(c, out)


func run(main: Node, harness: Node) -> Dictionary:
	if harness != null and not str(harness.get("_shots_label")).is_empty():
		_dir = "user://screenshots/%s" % str(harness.get("_shots_label"))
	var tree := main.get_tree()
	var sgv: Node = ServiceLocator.graph()
	_ok(sgv != null, "the graph view exists")
	if sgv == null:
		return {"ok": false}
	var model: GraphModel = sgv.get("model") as GraphModel
	# Let the flow engine stamp live wire rates: 60x for a few seconds.
	var ts0: float = float(main.get("time_scale"))
	main.set("time_scale", 60.0 / 3600.0)
	await _frames(tree, 240)
	var t0 := Time.get_ticks_usec()
	var led: Dictionary = {}
	for i in 10:
		led = ElementLedger.compute(model, "root")
	var ms := float(Time.get_ticks_usec() - t0) / 10000.0
	print("element-ledger cost: %.2f ms per compute (%d items, %d wires)" % [ms, model.items.size(), model.connections.size()])
	_ok(ms < 20.0, "the ledger costs under 20 ms on this world (%.2f ms)" % ms)
	var st: Dictionary = led["stock"]
	print("element-ledger stock: %s, usable water %s, bound water %s, C %s, N %s, P %s, K %s, energy %s, food %s kcal" % [
		ElementLedger.fmt_kg(float(st["kg"])), ElementLedger.fmt_water_l(float(st["usable_water_kg"])),
		ElementLedger.fmt_water_l(float(st["bound_water_kg"])),
		ElementLedger.fmt_kg(float((st["elements"] as Dictionary).get("C", 0.0))),
		ElementLedger.fmt_kg(float((st["elements"] as Dictionary).get("N", 0.0))),
		ElementLedger.fmt_kg(float((st["elements"] as Dictionary).get("P", 0.0))),
		ElementLedger.fmt_kg(float((st["elements"] as Dictionary).get("K", 0.0))),
		ElementLedger.fmt_energy_mj(float(st["energy_mj"])), str(int(float(st["food_mj"]) * 239.0))])
	print("element-ledger bound water by kind: ", st["bound_by_kind"])
	var w: Dictionary = led["water"]
	print("element-ledger water: used %.2f L/h, recovered %.2f L/h, ratio %s" % [float(w["used_kg_h"]),
		float(w["recovered_kg_h"]), "—" if is_nan(float(w["ratio"])) else UiText.pct(float(w["ratio"]))])
	var b: Dictionary = led["boundary"]
	print("element-ledger boundary: rain %.2f kg/h, imports %.2f kg/h, exports %.2f kg/h" % [
		float((b["rain"] as Dictionary)["kg_h"]), float((b["imports"] as Dictionary)["kg_h"]),
		float((b["exports"] as Dictionary)["kg_h"])])
	for u in (led["unaccounted"] as Array).slice(0, 8):
		print("element-ledger doesn't add up: %s — %s" % [str(u["name"]), ElementLedger.unaccounted_text(u)])
	for lk in led["leaks"]:
		print("element-ledger lost: %s %s %s" % [str(lk["name"]), str(lk["what"]), str(lk["kinds"])])
	for un in led["unknown"]:
		print("element-ledger unknown make-up: %s (%s)" % [str(un["name"]), str(un["kind"])])
	_ok((led["stores"] as Array).size() > 5, "the world's stores are counted (%d)" % (led["stores"] as Array).size())
	_ok(float(st["usable_water_kg"]) > 0.0, "usable water is stored")
	_ok((led["nodes"] as Dictionary).size() > 3, "live wire flows reach the ledger (%d machines)" % (led["nodes"] as Dictionary).size())
	_ok(not is_nan(float(w["ratio"])), "used water is flowing and the recovery ratio is known")

	sgv.call("open_graph_view")
	await _frames(tree, 30)
	var dash: Node = sgv.get("_graph_dashboard")
	if dash != null:
		dash.call("set_tab", "site")
		dash.call("refresh", true)
		await _frames(tree, 5)
	var mv: Variant = dash.get("_made_of_vbox") if dash != null else null
	if mv is Control:
		var p: Node = (mv as Control).get_parent()
		while p != null and not (p is ScrollContainer):
			p = p.get_parent()
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible(mv as Control)
			await _frames(tree, 3)
		_ok((mv as Control).is_visible_in_tree(), "the WATER & NUTRIENTS card is on screen in the site tab")
	var texts: Array = []
	if mv is Node:
		_texts(mv, texts)
	_ok(texts.has("Water recovery") and texts.has("Nitrogen"), "the dashboard card shows water recovery and nitrogen")
	await _shot(main, "01_dashboard")

	var insp: Node = sgv.get("_inspector_panel")
	var picks := {"urine": "", "proc": "", "wire": ""}
	for it in model.items:
		var d: Dictionary = it
		var sp: Dictionary = d.get("specs", {})
		if str(d.get("type", "")) == "resource" and str(sp.get("resource_kind", "")) == "urine" and picks["urine"] == "":
			picks["urine"] = str(d.get("id", ""))
		if str(d.get("type", "")) == "processor" and str(sp.get("name", "")).begins_with("Urine Nutrient") and picks["proc"] == "":
			picks["proc"] = str(d.get("id", ""))
	if picks["urine"] == "":
		for it2 in model.items:
			var d2: Dictionary = it2
			if str(d2.get("type", "")) == "resource":
				picks["urine"] = str(d2.get("id", ""))
				break
	for key in ["urine", "proc"]:
		if str(picks[key]).is_empty():
			print("element-ledger: no %s on this world" % key)
			continue
		sgv.call("select_item_by_id", str(picks[key]))
		await _frames(tree, 10)
		var it_texts: Array = []
		if insp != null:
			_texts(insp, it_texts)
		var want := "Made of" if key == "urine" else "Mass balance"
		var found := false
		for t in it_texts:
			if str(t).to_lower().find(want.to_lower()) >= 0:
				found = true
		_ok(found, "the inspector shows %s for %s" % [want, str(model.get_item(str(picks[key])).get("specs", {}).get("name", ""))])
		await _shot(main, "02_inspector_%s" % key)
	if sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	main.set("time_scale", ts0)
	print("element-ledger %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	return {"ok": _fails == 0}
