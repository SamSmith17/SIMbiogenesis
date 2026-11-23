extends Node
## The food shopping panel (plans/FOOD_WASTE_REALISM_PLAN.md Phase 7):
## plan a real shopping list (ShoppingPlan over the FoodProducts catalog),
## see its cost, calories, nutrition and the packaging waste it will leave,
## search Open Food Facts for more products, export the printable list, and
## ORDER it into a Supply Store — the items land in the store's ledger and
## the cost on the site's food spend (SystemGraphView.order_food_delivery,
## a USER edit).
##
## Owned by SystemGraphView (open_food_shopping); one instance, reopened.
## No class_name (ui_compile_selftest sweeps scenes/ui/).

var view = null               # SystemGraphView, duck-typed
var frame: ModalFrame = null

var people_spin: SpinBox = null
var days_spin: SpinBox = null
var store_pick: OptionButton = null
var search_edit: LineEdit = null
var search_btn: Button = null
var results_list: ItemList = null
var add_btn: Button = null
var order_btn: Button = null
var status_lbl: Label = null

var _menu_checks: Dictionary = {}    # category -> CheckBox
var _lines: Array = []               # ShoppingPlan lines (the editable list)
var _lines_grid: GridContainer = null
var _totals_box: VBoxContainer = null
var _results: Array = []             # parsed OFF search hits
var _store_ids: Array = []
var _off_hooked := false


func open(v, store_id: String = "") -> void:
	view = v
	if frame == null:
		_build()
	_fill_stores(store_id)
	if _lines.is_empty():
		plan_now()
	else:
		_refresh_lines()
	frame.open()


func _build() -> void:
	frame = ModalFrame.create(I18n.t("Food shopping"),
		I18n.t("Real products, real costs, and the packaging they leave behind"),
		Vector2(1060, 760), "food_shopping")
	frame.content_max_w = 1000.0
	add_child(frame)

	# --- who, how long, which store ------------------------------------
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	frame.body.add_child(row)
	row.add_child(_lbl(I18n.t("People")))
	people_spin = SpinBox.new()
	people_spin.name = "people_spin"
	people_spin.min_value = 1
	people_spin.max_value = 500
	people_spin.value = 4
	row.add_child(people_spin)
	row.add_child(_lbl(I18n.t("Days")))
	days_spin = SpinBox.new()
	days_spin.name = "days_spin"
	days_spin.min_value = 0.5
	days_spin.max_value = 60.0
	days_spin.step = 0.5
	days_spin.value = 7.0
	row.add_child(days_spin)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_lbl(I18n.t("Deliver to")))
	store_pick = OptionButton.new()
	store_pick.name = "store_pick"
	store_pick.fit_to_longest_item = false
	store_pick.custom_minimum_size.x = 220
	row.add_child(store_pick)

	# --- the menu: which categories to buy from -------------------------
	var menu_row := HFlowContainer.new()
	menu_row.add_theme_constant_override("h_separation", 14)
	frame.body.add_child(menu_row)
	menu_row.add_child(_lbl(I18n.t("Buy:")))
	for cat in FoodProducts.CATEGORIES:
		if FoodProducts.by_category(cat).is_empty():
			continue
		var cb := CheckBox.new()
		cb.name = "menu_" + str(cat)
		cb.text = UiText.sentence(str(cat))
		cb.button_pressed = true
		cb.focus_mode = Control.FOCUS_NONE
		menu_row.add_child(cb)
		_menu_checks[str(cat)] = cb
	var plan_btn := Button.new()
	plan_btn.name = "plan_btn"
	plan_btn.text = I18n.t("Plan the list")
	UITheme.style_button(plan_btn)
	plan_btn.pressed.connect(plan_now)
	menu_row.add_child(plan_btn)

	frame.body.add_child(HSeparator.new())

	# --- the list --------------------------------------------------------
	_lines_grid = GridContainer.new()
	_lines_grid.columns = 6
	_lines_grid.add_theme_constant_override("h_separation", 12)
	_lines_grid.add_theme_constant_override("v_separation", 4)
	frame.body.add_child(_lines_grid)

	_totals_box = VBoxContainer.new()
	_totals_box.add_theme_constant_override("separation", 2)
	frame.body.add_child(_totals_box)

	frame.body.add_child(HSeparator.new())

	# --- add more products (Open Food Facts) ----------------------------
	frame.body.add_child(SectionHeader.make(I18n.t("Add a product (Open Food Facts)")))
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	frame.body.add_child(srow)
	search_edit = LineEdit.new()
	search_edit.name = "search_edit"
	search_edit.placeholder_text = I18n.t("Search by name, or type a barcode")
	search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_edit.text_submitted.connect(func(_t: String) -> void: _on_search())
	srow.add_child(search_edit)
	search_btn = Button.new()
	search_btn.name = "search_btn"
	search_btn.text = I18n.t("Search")
	UITheme.style_button(search_btn)
	search_btn.pressed.connect(_on_search)
	srow.add_child(search_btn)
	results_list = ItemList.new()
	results_list.name = "results_list"
	results_list.custom_minimum_size.y = 96
	results_list.visible = false
	frame.body.add_child(results_list)
	add_btn = Button.new()
	add_btn.name = "add_btn"
	add_btn.text = I18n.t("Add to the list")
	UITheme.style_button(add_btn)
	add_btn.visible = false
	add_btn.pressed.connect(_on_add_result)
	frame.body.add_child(add_btn)
	status_lbl = _lbl("")
	status_lbl.name = "status_lbl"
	status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	frame.body.add_child(status_lbl)

	# ODbL attribution (the bundled catalog's own header).
	var meta := FoodProducts.catalog_meta()
	if not str(meta.get("attribution", "")).is_empty():
		var att := _lbl(str(meta["attribution"]))
		att.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		att.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		att.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		frame.body.add_child(att)

	frame.add_button(I18n.t("Export list"), ModalFrame.SECONDARY, _on_export)
	order_btn = frame.add_button(I18n.t("Order"), ModalFrame.PRIMARY, order_now)
	order_btn.name = "order_btn"


# --- planning and the table ------------------------------------------------

func _menu() -> Dictionary:
	var m: Dictionary = {}
	for cat in _menu_checks:
		if (_menu_checks[cat] as CheckBox).button_pressed:
			m[cat] = 1.0
	return m


func plan_now() -> void:
	var p := ShoppingPlan.plan(int(people_spin.value), float(days_spin.value),
		_menu(), FoodProducts.all_products())
	_lines = p["lines"]
	_refresh_lines()


func lines() -> Array:
	return _lines


func totals() -> Dictionary:
	return ShoppingPlan.totals_for(_lines, int(people_spin.value), float(days_spin.value))


func _refresh_lines() -> void:
	for c in _lines_grid.get_children():
		_lines_grid.remove_child(c)
		c.queue_free()
	for h in [I18n.t("Product"), I18n.t("Qty"), I18n.t("Net"), I18n.t("kcal"),
			I18n.t("Cost"), I18n.t("Packaging")]:
		var hl := _lbl(str(h))
		hl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_lines_grid.add_child(hl)
	for i in _lines.size():
		var l: Dictionary = _lines[i]
		var nm := _lbl(("%s %s" % [str(l.get("brand", "")), str(l.get("name", "?"))]).strip_edges())
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.custom_minimum_size.x = 240
		nm.tooltip_text = str(l.get("product_id", ""))
		_lines_grid.add_child(nm)
		var q := SpinBox.new()
		q.name = "qty_" + str(l.get("product_id", ""))
		q.min_value = 0
		q.max_value = 9999
		q.value = int(l.get("qty", 0))
		q.value_changed.connect(_on_qty.bind(i))
		_lines_grid.add_child(q)
		_lines_grid.add_child(_lbl(UiText.num(float(l.get("net_kg", 0.0)), "kg", 3)))
		_lines_grid.add_child(_lbl(UiText.thousands(int(l.get("kcal", 0.0)))))
		_lines_grid.add_child(_lbl("$%.2f" % float(l.get("cost_usd", 0.0))))
		var w := _lbl(_waste_words(l))
		w.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_lines_grid.add_child(w)
	_refresh_totals()


func _on_qty(v: float, i: int) -> void:
	if i < 0 or i >= _lines.size():
		return
	var pid := str((_lines[i] as Dictionary).get("product_id", ""))
	var p := FoodProducts.product(pid)
	if not p.is_empty():
		_lines[i] = ShoppingPlan.line_for(p, int(v))
	_refresh_totals()


func _waste_words(l: Dictionary) -> String:
	var bits := PackedStringArray()
	for e in l.get("waste", []):
		var n := int(e["count"]) * int(l.get("qty", 0))
		if n > 0:
			bits.append("%d x %s" % [n, PackagingArchetypes.label(str(e["archetype_id"]))])
	return ", ".join(bits)


func _refresh_totals() -> void:
	for c in _totals_box.get_children():
		_totals_box.remove_child(c)
		c.queue_free()
	var t := totals()
	var head := _lbl(I18n.f("Total: {cost} · {kg} of food · {kcal} kcal · covers {days}", {
		"cost": "$%.2f" % float(t.get("cost_usd", 0.0)),
		"kg": UiText.num(float(t.get("net_kg", 0.0)), "kg", 3),
		"kcal": UiText.thousands(int(t.get("kcal", 0.0))),
		"days": UiText.count(int(round(float(t.get("days_covered", 0.0)))), "day")}))
	head.name = "totals_lbl"
	head.add_theme_font_override("font", UITheme.font("semibold"))
	_totals_box.add_child(head)
	# Nutrition, as bought, report-only (plan decision D2).
	var nut := _lbl(I18n.f("Per person a day (as bought): {kcal} kcal · protein {p} · fibre {f} · salt {s}", {
		"kcal": UiText.thousands(int(t.get("kcal_per_person_day", 0.0))),
		"p": UiText.num(float(t.get("protein_g_day", 0.0)), "g", 3),
		"f": UiText.num(float(t.get("fiber_g_day", 0.0)), "g", 2),
		"s": UiText.num(float(t.get("salt_g_day", 0.0)), "g", 2)}))
	nut.name = "nutrition_lbl"
	nut.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_totals_box.add_child(nut)
	var wl := _lbl(I18n.f("Packaging to come back: {kg} · {l} loose in the bins", {
		"kg": UiText.num(float(t.get("waste_kg", 0.0)), "kg", 2),
		"l": UiText.num(float(t.get("waste_l_loose", 0.0)), "L", 2)}))
	wl.name = "waste_lbl"
	wl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_totals_box.add_child(wl)
	var wk: Dictionary = t.get("waste_kg_by_kind", {})
	if not wk.is_empty():
		var kinds := wk.keys()
		kinds.sort()
		var bits := PackedStringArray()
		for kind in kinds:
			bits.append("%s %s" % [ResourceKinds.display_name(str(kind)),
				UiText.num(float(wk[kind]), "kg", 2)])
		var bl := _lbl("    " + " · ".join(bits))
		bl.name = "waste_kinds_lbl"
		bl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		bl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_totals_box.add_child(bl)
	if order_btn != null:
		order_btn.disabled = _store_ids.is_empty() or int(t.get("items", 0)) <= 0


# --- stores and ordering -----------------------------------------------------

func _fill_stores(preselect: String) -> void:
	_store_ids = []
	store_pick.clear()
	var targets: Array = view.food_order_targets() if view != null else []
	for tgt in targets:
		var d := tgt as Dictionary
		_store_ids.append(str(d["id"]))
		store_pick.add_item("%s (%s)" % [str(d["name"]),
			UiText.num(float(d.get("stock_kg", 0.0)), "kg", 2)])
		if str(d["id"]) == preselect:
			store_pick.select(_store_ids.size() - 1)
	if targets.is_empty():
		store_pick.add_item(I18n.t("No supply store on the graph"))
		store_pick.disabled = true
	else:
		store_pick.disabled = false


func order_now() -> void:
	if view == null or _store_ids.is_empty():
		return
	var idx := clampi(store_pick.selected, 0, _store_ids.size() - 1)
	var t := totals()
	var r: Dictionary = view.order_food_delivery(str(_store_ids[idx]),
		ShoppingPlan.manifest_for(_lines), float(t.get("cost_usd", 0.0)))
	if r.is_empty():
		status_lbl.text = I18n.t("Nothing ordered — the list is empty or the store is gone.")
		return
	status_lbl.text = I18n.f("Ordered: {kg} delivered for {cost}.", {
		"kg": UiText.num(float(r.get("kg", 0.0)), "kg", 3),
		"cost": "$%.2f" % float(r.get("cost_usd", 0.0))})
	_fill_stores(str(_store_ids[idx]))


func _on_export() -> void:
	var p := {"lines": _lines, "totals": totals()}
	var txt := ShoppingPlan.to_text(p, int(people_spin.value), float(days_spin.value),
		FoodProducts.catalog_meta())
	DirAccess.make_dir_recursive_absolute("user://exports")
	var path := "user://exports/shopping_list.txt"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(txt)
		f.close()
		status_lbl.text = I18n.f("Saved {path}.", {"path": path})
	else:
		status_lbl.text = I18n.t("Could not write the list.")


# --- Open Food Facts ---------------------------------------------------------

func _hook_off() -> void:
	if _off_hooked:
		return
	var off := get_node_or_null("/root/OffService")
	if off == null:
		return
	_off_hooked = true
	off.product_ready.connect(_on_off_product)
	off.product_failed.connect(func(_code: String, why: String) -> void:
		status_lbl.text = I18n.f("Open Food Facts: {why}", {"why": why}))
	off.search_ready.connect(_on_off_search)
	off.search_failed.connect(func(_q: String, why: String) -> void:
		status_lbl.text = I18n.f("Open Food Facts: {why}", {"why": why}))


func _on_search() -> void:
	_hook_off()
	var off := get_node_or_null("/root/OffService")
	var q := search_edit.text.strip_edges()
	if off == null or q.is_empty():
		return
	status_lbl.text = I18n.t("Asking Open Food Facts…")
	if q.is_valid_int() and q.length() >= 8:
		off.request_product(q)
	else:
		off.request_search(q)


func _on_off_product(_code: String, rec: Dictionary) -> void:
	if rec.is_empty():
		status_lbl.text = I18n.t("No such product.")
		return
	FoodProducts.add_user_product(rec)
	_append_product(rec)
	status_lbl.text = I18n.f("Added {name}.", {"name": str(rec.get("name", rec.get("id", "?")))})


func _on_off_search(_q: String, hits: Array) -> void:
	_results = hits
	results_list.clear()
	for h in hits:
		var d := h as Dictionary
		results_list.add_item("%s %s (%s)" % [str(d.get("brand", "")),
			str(d.get("name", "?")), str(d.get("id", ""))])
	results_list.visible = not hits.is_empty()
	add_btn.visible = not hits.is_empty()
	status_lbl.text = I18n.f("{n} found.", {"n": str(hits.size())}) if not hits.is_empty() \
		else I18n.t("Nothing found.")


func _on_add_result() -> void:
	var sel := results_list.get_selected_items()
	if sel.is_empty() or int(sel[0]) >= _results.size():
		return
	var rec: Dictionary = _results[int(sel[0])]
	FoodProducts.add_user_product(rec)
	_append_product(rec)
	status_lbl.text = I18n.f("Added {name}.", {"name": str(rec.get("name", rec.get("id", "?")))})


func _append_product(rec: Dictionary) -> void:
	var pid := str(rec.get("id", ""))
	for i in _lines.size():
		if str((_lines[i] as Dictionary).get("product_id", "")) == pid:
			_lines[i] = ShoppingPlan.line_for(FoodProducts.product(pid),
				int((_lines[i] as Dictionary).get("qty", 0)) + 1)
			_refresh_lines()
			return
	_lines.append(ShoppingPlan.line_for(FoodProducts.product(pid), 1))
	_refresh_lines()


static func _lbl(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	return l
