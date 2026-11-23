extends SceneTree
## Offline selftest for ShoppingPlan (food/waste realism plan Phase 7):
## a hand-computed 2-people x 3-days case over a synthetic two-product
## catalog, menu redistribution, hand edits, the manifest, and the export
## text. Run:
##   Godot --headless --path . --script core/food/shopping_plan_selftest.gd
##
## Carries EXPECTED_CHECKS: a Godot runtime error aborts the enclosing test
## function while the suite still prints PASS otherwise.

const EXPECTED_CHECKS := 27

var _checks := 0
var _failed := 0


func _initialize() -> void:
	_test_hand_case()
	_test_menu_redistribution()
	_test_edits_and_manifest()
	_test_export_text()
	_test_real_catalog()
	if _checks != EXPECTED_CHECKS:
		_failed += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _failed == 0:
		print("SHOPPING PLAN SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("SHOPPING PLAN SELFTEST: %d of %d checks FAILED" % [_failed, _checks])
	quit(0 if _failed == 0 else 1)


func _check(what: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: %s%s" % [what, ("  [" + detail + "]") if not detail.is_empty() else ""])


static func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


## Two synthetic products: a 400 g can at 100 kcal/100g and a 500 g box of
## pasta at 350 kcal/100g (film inner bag), both with real archetype ids so
## the waste rolls up through the real table.
static func _products() -> Array:
	return [
		{"id": "can1", "name": "Beans", "brand": "T", "category": "canned",
			"net_g": 400.0, "kcal_100g": 100.0, "protein_100g": 10.0,
			"price_usd": 2.0, "packagings": [{"archetype_id": "steel_can_400", "count": 1}]},
		{"id": "box1", "name": "Pasta", "brand": "T", "category": "grains",
			"net_g": 500.0, "kcal_100g": 350.0,
			"price_usd": 1.5, "packagings": [
				{"archetype_id": "card_box_small", "count": 1},
				{"archetype_id": "film_bag", "count": 1}]},
	]


func _test_hand_case() -> void:
	var products := _products()
	var menu := ShoppingPlan.default_menu(products)
	_check("default menu lists the two categories at weight 1",
		menu.size() == 2 and _near(float(menu.get("canned", 0.0)), 1.0, 1e-9)
			and _near(float(menu.get("grains", 0.0)), 1.0, 1e-9), str(menu))
	# 2 people x 3 days x 2500 draw kcal/day = 15,000 kcal, 7,500 a category.
	# Beans: ceil(7500 / 400) = 19; pasta: ceil(7500 / 1750) = 5.
	var p := ShoppingPlan.plan(2, 3.0, menu, products)
	var lines: Array = p["lines"]
	_check("two lines planned", lines.size() == 2, str(lines.size()))
	var by_id: Dictionary = {}
	for l in lines:
		by_id[str((l as Dictionary)["product_id"])] = l
	_check("19 cans of beans (7500 kcal at 400 each, rounded up)",
		int((by_id.get("can1", {}) as Dictionary).get("qty", 0)) == 19, str(by_id))
	_check("5 boxes of pasta (7500 kcal at 1750 each)",
		int((by_id.get("box1", {}) as Dictionary).get("qty", 0)) == 5, str(by_id))
	var t: Dictionary = p["totals"]
	_check("cost is 19 x $2 + 5 x $1.50 = $45.50",
		_near(float(t["cost_usd"]), 45.5, 1e-9), "%.2f" % float(t["cost_usd"]))
	_check("kcal is 7600 + 8750 = 16,350",
		_near(float(t["kcal"]), 16350.0, 1e-6), "%.0f" % float(t["kcal"]))
	_check("net mass is 19 x 0.4 + 5 x 0.5 = 10.1 kg",
		_near(float(t["net_kg"]), 10.1, 1e-9))
	# Days covered = kcal / (2500 x 2 people) = 3.27.
	_check("days covered 3.27", _near(float(t["days_covered"]), 16350.0 / 5000.0, 1e-9))
	# Protein per person-day AS BOUGHT: 19 x 400 g x 10 % / 6 = 126.67 g.
	_check("protein 126.7 g/person/day (report-only)",
		_near(float(t["protein_g_day"]), 19.0 * 400.0 * 0.10 / 6.0, 1e-6),
		"%.1f" % float(t["protein_g_day"]))
	# Waste rolls up through the REAL archetype table by count.
	var wk: Dictionary = t["waste_kg_by_kind"]
	_check("steel waste = 19 cans x the table's can mass",
		_near(float(wk.get("steel_waste", 0.0)),
			19.0 * PackagingArchetypes.mass_g("steel_can_400") / 1000.0, 1e-9), str(wk))
	_check("a steel can weighs 55 g (EPA WARM / can makers, est)",
		_near(PackagingArchetypes.mass_g("steel_can_400"), 55.0, 1e-9))
	_check("cardboard and film waste both counted",
		float(wk.get("cardboard_waste", 0.0)) > 0.0 and float(wk.get("film_waste", 0.0)) > 0.0,
		str(wk))
	var wi: Dictionary = t["waste_items"]
	_check("the bins get 19 cans, 5 boxes, 5 bags",
		int(wi.get("steel_can_400", 0)) == 19 and int(wi.get("card_box_small", 0)) == 5
			and int(wi.get("film_bag", 0)) == 5, str(wi))
	_check("loose litres follow the archetypes' bin volumes",
		_near(float(t["waste_l_loose"]),
			19.0 * PackagingArchetypes.loose_l("steel_can_400")
			+ 5.0 * PackagingArchetypes.loose_l("card_box_small")
			+ 5.0 * PackagingArchetypes.loose_l("film_bag"), 1e-9))
	_check("gross beats net by exactly the packaging",
		_near(float(t["gross_kg"]) - float(t["net_kg"]), float(t["waste_kg"]), 1e-9))


func _test_menu_redistribution() -> void:
	var products := _products()
	# A wanted category with no products: its share lands on the others.
	var p := ShoppingPlan.plan(2, 3.0, {"canned": 1.0, "produce": 1.0}, products)
	var lines: Array = p["lines"]
	_check("empty category's share redistributed (all 15,000 kcal on beans)",
		lines.size() == 1 and int((lines[0] as Dictionary)["qty"]) == 38,
		str(lines))
	# A product with no kcal cannot be planned by calories.
	var dud := [{"id": "x", "name": "Mystery", "category": "canned", "net_g": 100.0,
		"price_usd": 1.0, "packagings": []}]
	_check("a kcal-less product is skipped by the planner",
		(ShoppingPlan.plan(2, 3.0, {"canned": 1.0}, dud)["lines"] as Array).is_empty())
	_check("nobody or no days = an empty plan",
		(ShoppingPlan.plan(0, 3.0, {"canned": 1.0}, products)["lines"] as Array).is_empty()
		and (ShoppingPlan.plan(2, 0.0, {"canned": 1.0}, products)["lines"] as Array).is_empty())


func _test_edits_and_manifest() -> void:
	var products := _products()
	# The UI edits a quantity, then rebuilds the totals from the lines.
	var lines := [ShoppingPlan.line_for(products[0], 10), ShoppingPlan.line_for(products[1], 0)]
	var t := ShoppingPlan.totals_for(lines, 2, 3.0)
	_check("a zero-qty line contributes nothing",
		_near(float(t["cost_usd"]), 20.0, 1e-9) and int(t["items"]) == 10, str(t))
	_check("line_for carries per-item waste for the UI",
		(ShoppingPlan.line_for(products[1], 3)["waste"] as Array).size() == 2)
	var m := ShoppingPlan.manifest_for(lines)
	_check("the manifest is {product: qty} with zero-qty lines dropped",
		m.size() == 1 and int(m.get("can1", 0)) == 10, str(m))
	_check("duplicate lines merge in the manifest",
		int(ShoppingPlan.manifest_for([ShoppingPlan.line_for(products[0], 2),
			ShoppingPlan.line_for(products[0], 3)]).get("can1", 0)) == 5)


func _test_export_text() -> void:
	var products := _products()
	var p := ShoppingPlan.plan(2, 3.0, ShoppingPlan.default_menu(products), products)
	var txt := ShoppingPlan.to_text(p, 2, 3.0, {"attribution": "Data from Open Food Facts"})
	_check("the export lists the items and the cost",
		txt.contains("Beans") and txt.contains("$45.50"), txt.left(200))
	_check("the export carries the ODbL attribution",
		txt.contains("Open Food Facts"))
	_check("no attribution line without meta",
		not ShoppingPlan.to_text(p, 2, 3.0).contains("Open Food Facts"))


## The shipped catalog end to end, loosely (its contents will grow).
func _test_real_catalog() -> void:
	var products := FoodProducts.all_products()
	var menu := ShoppingPlan.default_menu(products)
	var p := ShoppingPlan.plan(4, 7.0, menu, products)
	var t: Dictionary = p["totals"]
	_check("the shipped catalog plans a real week",
		(p["lines"] as Array).size() >= 3 and float(t["cost_usd"]) > 0.0
			and float(t["days_covered"]) >= 7.0, str(t))
	_check("the week's cart leaves countable packaging",
		not (t["waste_items"] as Dictionary).is_empty()
			and float(t["waste_kg"]) > 0.0, str(t["waste_items"]))
