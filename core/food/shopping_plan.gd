class_name ShoppingPlan
extends RefCounted
## A shopping list for a camp (plans/FOOD_WASTE_REALISM_PLAN.md Phase 7):
## how many of which real products feed `people` for `days`, what that
## costs, the calories and macros it carries, and the packaging waste it
## will leave — by material kind AND as countable bottles / cans / boxes
## (PackagingArchetypes), which is what the typed bins fill up with.
##
## Pure static over a product LIST (the caller resolves it from
## FoodProducts), so the selftest runs on synthetic two-product catalogs.
##
## Quantities cover the pantry DRAW, not just what is eaten: the camp
## draws CampProvisioning.draw_kcal_per_person_day() (2500 kcal — 2000
## eaten + the engine's 20 % scrap share), which is what "days of food"
## means for a store. The nutrition totals are per person-day AS BOUGHT
## (before scraps) and report-only (plan decision D2).

## A line's kcal share within a category is split evenly over the
## category's products, then rounded UP to whole items.


## {category: weight} with every category that has a usable product at
## weight 1.0 — the UI's starting menu.
static func default_menu(products: Array) -> Dictionary:
	var menu: Dictionary = {}
	for p in products:
		if _kcal_per_item(p) > 0.0:
			menu[str((p as Dictionary).get("category", "other"))] = 1.0
	return menu


## The plan: {lines: [line...], totals: {...}}. `menu` = {category: weight,
## 0 = leave out}; categories with no usable product are dropped and their
## share goes to the rest. A product with no net content or no calories
## cannot be planned by kcal and is skipped (it can still be hand-added —
## the UI rebuilds totals from edited lines via line_for / totals_for).
static func plan(people: int, days: float, menu: Dictionary, products: Array) -> Dictionary:
	var kcal_total := maxf(float(maxi(people, 0)) * maxf(days, 0.0)
		* CampProvisioning.draw_kcal_per_person_day(), 0.0)
	# Usable products per wanted category, in the caller's (catalog) order.
	var by_cat: Dictionary = {}
	for p in products:
		var pd := p as Dictionary
		if _kcal_per_item(pd) <= 0.0:
			continue
		var cat := str(pd.get("category", "other"))
		if float(menu.get(cat, 0.0)) <= 0.0:
			continue
		var arr: Array = by_cat.get(cat, [])
		arr.append(pd)
		by_cat[cat] = arr
	var weight_sum := 0.0
	for cat in by_cat:
		weight_sum += float(menu.get(cat, 0.0))
	var lines: Array = []
	if kcal_total > 0.0 and weight_sum > 0.0:
		for cat in by_cat:
			var cat_kcal: float = kcal_total * float(menu.get(cat, 0.0)) / weight_sum
			var cat_products: Array = by_cat[cat]
			var each := cat_kcal / float(cat_products.size())
			for pd2 in cat_products:
				var qty := int(ceil(each / _kcal_per_item(pd2) - 1e-9))
				if qty > 0:
					lines.append(line_for(pd2, qty))
	return {"lines": lines, "totals": totals_for(lines, people, days)}


## One list line for `qty` of a product — the shape the UI edits. A line
## carries everything the totals need, so totals_for never resolves the
## product again (and a hand-added product outside the catalog rolls up
## the same way).
static func line_for(p: Dictionary, qty: int) -> Dictionary:
	var n := maxi(qty, 0)
	var net := FoodProducts.net_kg(p) * n
	var by_kind := FoodProducts.waste_kg_by_kind(p)
	var kinds: Dictionary = {}
	var waste_kg := 0.0
	for k in by_kind:
		kinds[k] = float(by_kind[k]) * n
		waste_kg += float(by_kind[k])
	var items: Dictionary = {}
	for e in FoodProducts.waste_items_for(p):
		var aid := str(e["archetype_id"])
		items[aid] = int(items.get(aid, 0)) + int(e["count"]) * n
	var net_g := float(p.get("net_g", 0.0)) * n
	return {
		"product_id": str(p.get("id", "")),
		"name": str(p.get("name", "?")),
		"brand": str(p.get("brand", "")),
		"category": str(p.get("category", "other")),
		"qty": n,
		"net_kg": net,
		"gross_kg": FoodProducts.gross_g(p) / 1000.0 * n,
		"kcal": _kcal_per_item(p) * n,
		"cost_usd": float(p.get("price_usd", 0.0)) * n,
		"waste": FoodProducts.waste_items_for(p),   # per ITEM (the UI's row)
		"waste_kg": waste_kg * n,
		"waste_l": FoodProducts.waste_loose_l(p) * n,
		"waste_kg_by_kind": kinds,
		"waste_items": items,
		"protein_g": net_g * maxf(float(p.get("protein_100g", 0.0)), 0.0) / 100.0,
		"fiber_g": net_g * maxf(float(p.get("fiber_100g", 0.0)), 0.0) / 100.0,
		"salt_g": net_g * maxf(float(p.get("salt_100g", 0.0)), 0.0) / 100.0,
	}


## Roll a set of lines up (the UI calls this again after a hand edit).
## Per-person-day macros are AS BOUGHT (report-only, D2); products with an
## unknown macro simply contribute nothing to that row.
static func totals_for(lines: Array, people: int, days: float) -> Dictionary:
	var t := {
		"cost_usd": 0.0, "net_kg": 0.0, "gross_kg": 0.0, "kcal": 0.0,
		"items": 0, "waste_kg": 0.0, "waste_l_loose": 0.0,
		"waste_kg_by_kind": {}, "waste_items": {},
		"protein_g_day": 0.0, "fiber_g_day": 0.0, "salt_g_day": 0.0,
		"kcal_per_person_day": 0.0, "days_covered": 0.0,
	}
	for ln in lines:
		var l := ln as Dictionary
		var n := int(l.get("qty", 0))
		if n <= 0:
			continue
		t["items"] = int(t["items"]) + n
		t["cost_usd"] = float(t["cost_usd"]) + float(l.get("cost_usd", 0.0))
		t["net_kg"] = float(t["net_kg"]) + float(l.get("net_kg", 0.0))
		t["gross_kg"] = float(t["gross_kg"]) + float(l.get("gross_kg", 0.0))
		t["kcal"] = float(t["kcal"]) + float(l.get("kcal", 0.0))
		t["waste_kg"] = float(t["waste_kg"]) + float(l.get("waste_kg", 0.0))
		t["waste_l_loose"] = float(t["waste_l_loose"]) + float(l.get("waste_l", 0.0))
		var wk: Dictionary = t["waste_kg_by_kind"]
		var lk: Dictionary = l.get("waste_kg_by_kind", {})
		for kind in lk:
			wk[kind] = float(wk.get(kind, 0.0)) + float(lk[kind])
		var wi: Dictionary = t["waste_items"]
		var li: Dictionary = l.get("waste_items", {})
		for aid in li:
			wi[aid] = int(wi.get(aid, 0)) + int(li[aid])
		t["protein_g_day"] = float(t["protein_g_day"]) + float(l.get("protein_g", 0.0))
		t["fiber_g_day"] = float(t["fiber_g_day"]) + float(l.get("fiber_g", 0.0))
		t["salt_g_day"] = float(t["salt_g_day"]) + float(l.get("salt_g", 0.0))
	var pd := float(maxi(people, 1)) * maxf(days, 0.0)
	if pd > 0.0:
		t["protein_g_day"] = float(t["protein_g_day"]) / pd
		t["fiber_g_day"] = float(t["fiber_g_day"]) / pd
		t["salt_g_day"] = float(t["salt_g_day"]) / pd
		t["kcal_per_person_day"] = float(t["kcal"]) / pd
	t["days_covered"] = float(t["kcal"]) \
		/ (CampProvisioning.draw_kcal_per_person_day() * float(maxi(people, 1)))
	return t


## {product_id: qty} — what an Order stamps into the Supply Store's item
## ledger (ResourceFlowEngine.ledger_add_items takes exactly this shape).
static func manifest_for(lines: Array) -> Dictionary:
	var out: Dictionary = {}
	for ln in lines:
		var l := ln as Dictionary
		var n := int(l.get("qty", 0))
		if n > 0:
			out[str(l.get("product_id", ""))] = int(out.get(str(l.get("product_id", "")), 0)) + n
	return out


## The printable list ("Export list"). `meta` = FoodProducts.catalog_meta()
## for the attribution footer; pass {} to leave it off.
static func to_text(p: Dictionary, people: int, days: float, meta: Dictionary = {}) -> String:
	var t: Dictionary = p.get("totals", {})
	var out := PackedStringArray()
	# NOTE: GDScript's % has no "%g" and no "-" (left-align) flag — both
	# error at runtime (the SCADA chart trap). Pad by hand.
	out.append(I18n.f("Shopping list — {people} people, {days} days", {
		"people": str(people), "days": String.num(days, 2).trim_suffix(".00")}))
	out.append("")
	for ln in p.get("lines", []):
		var l := ln as Dictionary
		if int(l.get("qty", 0)) <= 0:
			continue
		var nm := (str(l.get("brand", "")).strip_edges() + " " + str(l.get("name", "?"))).strip_edges()
		out.append("%3d x %s %8s  %s" % [int(l["qty"]), nm.rpad(34),
			"$%.2f" % float(l.get("cost_usd", 0.0)),
			UiText.num(float(l.get("net_kg", 0.0)) * 1000.0, "g", 3)])
	out.append("")
	out.append(I18n.f("Total: {cost} · {kg} of food · {kcal} kcal", {
		"cost": "$%.2f" % float(t.get("cost_usd", 0.0)),
		"kg": UiText.num(float(t.get("net_kg", 0.0)), "kg", 3),
		"kcal": UiText.thousands(int(t.get("kcal", 0.0)))}))
	out.append(I18n.f("Packaging to come back: {kg} ({l} loose in the bins)", {
		"kg": UiText.num(float(t.get("waste_kg", 0.0)), "kg", 2),
		"l": UiText.num(float(t.get("waste_l_loose", 0.0)), "L", 2)}))
	var wk: Dictionary = t.get("waste_kg_by_kind", {})
	var kinds := wk.keys()
	kinds.sort()
	for kind in kinds:
		out.append("  %-22s %s" % [ResourceKinds.display_name(str(kind)),
			UiText.num(float(wk[kind]), "kg", 2)])
	if not str(meta.get("attribution", "")).is_empty():
		out.append("")
		out.append(str(meta["attribution"]))
	return "\n".join(out)


static func _kcal_per_item(p: Dictionary) -> float:
	var k100 := float(p.get("kcal_100g", -1.0))
	if k100 <= 0.0:
		return 0.0
	return FoodProducts.net_kg(p) * k100 * 10.0
