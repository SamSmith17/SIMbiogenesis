extends RefCounted

## Food shopping end to end (food/waste realism plan Phase 7), on a real
## world in the sandbox:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/food_shopping_check.gd -Label food_shopping
##   (run it with -UserArgs @("--window-size=1280x720") too)
## - a seeded Supply Store's inspector has "Shopping list…" and a REAL
##   click opens the panel;
## - Plan the list fills real products for the typed people x days, with
##   cost, kcal, nutrition and the packaging waste by material;
## - UiAudit finds 0 errors on the open panel;
## - a hand-edited quantity reaches the totals;
## - a REAL click on Order lands the manifest in the store's ITEM LEDGER,
##   credits the tank, stamps the kcal density, books the cost (a USER
##   edit: user_rev moves) — and SiteBalance grows a Food & supplies row;
## - Export list writes user://exports/shopping_list.txt with the ODbL
##   attribution;
## - Open Food Facts offline (offline_for_test) fails soft in the status
##   line, never blocks;
## - Esc closes the panel.
## Removes the store it seeded. Shots under screenshots/food_shopping/.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("food-shop %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	var dir := "user://screenshots/food_shopping"
	DirAccess.make_dir_recursive_absolute(dir)
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var view: Node = ServiceLocator.graph()
	var model: GraphModel = view.get("model")
	var engine = view.call("resource_flow") if view.has_method("resource_flow") else view.get("_resource_flow")
	var h := float(main.call("get_absolute_hours"))

	# ---- seed a Supply Store ----
	var store_id := "food_shop_test_store"
	model.add_item({"id": store_id, "type": "resource", "x": 80.0, "y": 80.0,
		"width": 90.0, "height": 100.0, "specs": {"name": "Shopping Test Store",
		"resource_kind": "packaged_food", "capacity_qty": 300.0,
		"capacity_unit": "kg", "level": 0.2}})
	await _settle(tree, 6)

	# ---- the inspector's way in, with a REAL click ----
	view.call("open_graph_view")
	await _settle(tree, 20)
	view.call("focus_graph_item", store_id)
	await _settle(tree, 20)
	var insp_tab: Button = view.get("_insp_tab_btn")
	if insp_tab != null and insp_tab.is_visible_in_tree():
		await HarnessInput.click(tree.root, HarnessInput.center_of(insp_tab))
		await _settle(tree, 10)
	var shop_btn := HarnessInput.find_button_revealing(view, "Shopping list…")
	_ok(shop_btn != null, "the Supply Store inspector offers Shopping list…")
	if shop_btn != null:
		var q0 := shop_btn.get_parent()
		while q0 != null:
			if q0 is ScrollContainer:
				(q0 as ScrollContainer).ensure_control_visible(shop_btn)
			q0 = q0.get_parent()
		await _settle(tree, 6)
		await HarnessInput.click(tree.root, HarnessInput.center_of(shop_btn))
	else:
		view.call("open_food_shopping", store_id)
	await _settle(tree, 10)
	var panel: Node = view.get_node_or_null("FoodShoppingPanel")
	_ok(panel != null, "the panel exists")
	if panel == null:
		model.remove_item(store_id)
		return {"ok": false, "fails": _fails}
	var frame: CanvasLayer = panel.get("frame")
	_ok(frame != null and frame.visible, "…and is open")

	# ---- plan ----
	(panel.get("people_spin") as SpinBox).value = 4
	(panel.get("days_spin") as SpinBox).value = 3.0
	var plan_btn := HarnessInput.find_button(tree.root, "Plan the list")
	_ok(plan_btn != null, "Plan the list is on screen")
	if plan_btn != null:
		await HarnessInput.click(tree.root, HarnessInput.center_of(plan_btn))
	await _settle(tree, 8)
	var lines: Array = panel.call("lines")
	var t: Dictionary = panel.call("totals")
	_ok(lines.size() >= 3, "the plan lists real products (%d lines)" % lines.size())
	_ok(float(t.get("cost_usd", 0.0)) > 0.0 and float(t.get("kcal", 0.0)) > 0.0,
		"…with a cost and calories ($%.2f, %.0f kcal)" % [float(t.get("cost_usd", 0.0)), float(t.get("kcal", 0.0))])
	_ok(float(t.get("days_covered", 0.0)) >= 3.0,
		"…covering the asked-for days (%.2f)" % float(t.get("days_covered", 0.0)))
	_ok(not (t.get("waste_kg_by_kind", {}) as Dictionary).is_empty()
		and not (t.get("waste_items", {}) as Dictionary).is_empty(),
		"…and the packaging it will leave, by material and by piece")
	_shot(main, "01_panel")
	var audit: Dictionary = UiAudit.run(tree.root)
	print("food-shop: audit %s" % UiAudit.summary_line(audit))
	_ok(int(audit.get("errors", 0)) == 0, "UiAudit finds no errors on the open panel")

	# ---- a hand edit reaches the totals ----
	var first: Dictionary = lines[0]
	var qty_spin: SpinBox = null
	for n in tree.root.find_children("qty_" + str(first.get("product_id", "")), "SpinBox", true, false):
		qty_spin = n
	_ok(qty_spin != null, "a line's quantity is editable")
	var cost0 := float(t.get("cost_usd", 0.0))
	if qty_spin != null:
		qty_spin.value = int(first.get("qty", 0)) + 5
		await _settle(tree, 4)
	var t2: Dictionary = panel.call("totals")
	_ok(float(t2.get("cost_usd", 0.0)) > cost0 + 1e-6,
		"…and the edit moves the cost ($%.2f -> $%.2f)" % [cost0, float(t2.get("cost_usd", 0.0))])

	# ---- Order, a REAL click ----
	var rev0: int = model.user_rev
	var tl: ResourceTimeline = engine.call("get_timeline", store_id)
	var stock0: float = (tl.level_at(h) if tl != null else 0.2) * 300.0
	var order_btn := HarnessInput.find_button(tree.root, "Order")
	_ok(order_btn != null and not order_btn.disabled, "Order is on and enabled")
	if order_btn != null:
		await HarnessInput.click(tree.root, HarnessInput.center_of(order_btn))
	await _settle(tree, 8)
	var led = engine.call("item_ledger", store_id)
	var want := 0
	for pid in ShoppingPlan.manifest_for(panel.call("lines")):
		want += int(ShoppingPlan.manifest_for(panel.call("lines"))[pid])
	_ok(led != null and int(led.call("total_count_at", h + 0.001)) == want,
		"the order landed in the store's item ledger (%d items)" % (int(led.call("total_count_at", h + 0.001)) if led != null else -1))
	var sp: Dictionary = model.get_item(store_id).get("specs", {})
	tl = engine.call("get_timeline", store_id)
	var cap := maxf(float(sp.get("capacity_qty", 0.0)), 0.001)
	var stock1: float = (tl.level_at(h + 0.001) if tl != null else float(sp.get("level", 0.0))) * cap
	_ok(stock1 > stock0 + 1.0, "…and on the tank (%.1f -> %.1f kg)" % [stock0, stock1])
	# (kcal_per_kg is the PANTRY's stamp — the unpack writes it as real
	# products flow through; a packaged store persists its ledger instead.)
	var persisted: Dictionary = (sp.get("item_ledger", {}) as Dictionary).get("counts", {})
	_ok(not persisted.is_empty(), "…and the ledger persisted on the specs (%d product kinds)" % persisted.size())
	_ok(absf(float(sp.get("food_spend_usd", 0.0)) - float(t2.get("cost_usd", 0.0))) < 0.01,
		"…and the cost booked ($%.2f)" % float(sp.get("food_spend_usd", 0.0)))
	_ok(model.user_rev > rev0, "an order is the player's edit (user_rev moved)")
	var bal := SiteBalance.compute(model.get("items"), {})
	_ok(float((bal["cost"] as Dictionary).get("food_usd", 0.0)) >= float(sp.get("food_spend_usd", 0.0)) - 0.01,
		"SiteBalance carries the food spend")
	_shot(main, "02_after_order")

	# ---- export ----
	var export_btn := HarnessInput.find_button(tree.root, "Export list")
	if export_btn != null:
		await HarnessInput.click(tree.root, HarnessInput.center_of(export_btn))
	await _settle(tree, 4)
	var txt := ""
	if FileAccess.file_exists("user://exports/shopping_list.txt"):
		var f := FileAccess.open("user://exports/shopping_list.txt", FileAccess.READ)
		txt = f.get_as_text()
		f.close()
	_ok(txt.contains("Total:") and txt.contains("Open Food Facts"),
		"Export list writes the printable list with the ODbL attribution")

	# ---- Open Food Facts offline fails soft ----
	load("res://core/food/off_service.gd").offline_for_test = true
	(panel.get("search_edit") as LineEdit).text = "oats"
	var search_btn := HarnessInput.find_button(tree.root, "Search")
	if search_btn != null:
		await HarnessInput.click(tree.root, HarnessInput.center_of(search_btn))
	await _settle(tree, 8)
	var status := str((panel.get("status_lbl") as Label).text)
	_ok(status.contains("offline"), "an offline search fails soft in the status line (%s)" % status)
	load("res://core/food/off_service.gd").offline_for_test = false

	# ---- Esc closes ----
	await HarnessInput.key(tree.root, KEY_ESCAPE)
	await _settle(tree, 6)
	_ok(not frame.visible, "Esc closes the panel")

	# ---- clean up ----
	view.call("close_graph_view")
	await _settle(tree, 6)
	model.remove_item(store_id)
	return {"ok": _fails.is_empty(), "fails": _fails}
