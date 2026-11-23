extends SceneTree
## Builds the shipped food catalog (core/food/data/food_catalog.json) from
## cached Open Food Facts replies, through the game's OWN parser
## (FoodProducts.parse_off_product) so the tool and the game can never
## disagree (plans/FOOD_WASTE_REALISM_PLAN.md Phase 2).
##
## Inputs:
##   tools/food/catalog_sources.json   — the curated barcode list
##   tools/food/cache/off_<code>.json  — raw v2 replies (fetch_products.py),
##                                       falling back to core/food/testdata/
##   tools/food/category_prices.json   — price-per-kg estimates by category
##
## Run: Godot.exe.exe --headless --path . --script tools/food/build_catalog.gd
##
## Prints every UNMAPPED packaging tag pair, so the archetype table grows
## deliberately instead of silently dropping packaging.

const SOURCES := "res://tools/food/catalog_sources.json"
const PRICES := "res://tools/food/category_prices.json"
const CACHE_DIR := "res://tools/food/cache"
const FALLBACK_DIR := "res://core/food/testdata"
const OUT := "res://core/food/data/food_catalog.json"

const ATTRIBUTION := "Data from Open Food Facts (https://openfoodfacts.org), licensed under the Open Database License (ODbL). (c) Open Food Facts contributors."


func _initialize() -> void:
	var sources := _json(SOURCES)
	var prices := _json(PRICES)
	var per_kg: Dictionary = prices.get("usd_per_kg", {})
	var min_price := float(prices.get("min_price_usd", 0.5))
	var products: Array = []
	var missing: Array = []
	var unmapped: Dictionary = {}
	for entry in sources.get("products", []):
		var code := str(entry.get("code", ""))
		if code.is_empty():
			continue
		var raw := _json("%s/off_%s.json" % [CACHE_DIR, code])
		if raw.is_empty():
			raw = _json("%s/off_%s.json" % [FALLBACK_DIR, code])
		if raw.is_empty():
			missing.append(code)
			continue
		var rec := FoodProducts.parse_off_product(raw)
		if rec.is_empty():
			missing.append(code)
			continue
		for u in rec.get("unmapped", []):
			unmapped[u] = int(unmapped.get(u, 0)) + 1
		rec.erase("unmapped")
		if entry.has("price_usd"):
			rec["price_usd"] = float(entry["price_usd"])
			rec["price_src"] = "curated"
		else:
			var cat := str(rec.get("category", "other"))
			var usd := maxf(float(per_kg.get(cat, per_kg.get("other", 5.0)))
					* FoodProducts.net_kg(rec), min_price)
			rec["price_usd"] = snappedf(usd, 0.01)
			rec["price_src"] = str(prices.get("src", "category estimate"))
		rec["fetched"] = Time.get_date_string_from_system()
		products.append(rec)
	products.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	var doc := {
		"version": 1,
		"attribution": ATTRIBUTION,
		"license": "ODbL-1.0",
		"generated": Time.get_date_string_from_system(),
		"products": products,
	}
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f == null:
		push_error("cannot write %s" % OUT)
		quit(1)
		return
	f.store_string(JSON.stringify(doc, "\t"))
	f.close()
	print("wrote %s: %d products" % [OUT, products.size()])
	for code in missing:
		print("  MISSING reply for %s (run tools/food/fetch_products.py)" % code)
	for u in unmapped:
		print("  UNMAPPED packaging: %s (x%d) — add it to PackagingArchetypes.map_off" % [u, unmapped[u]])
	quit(0 if missing.is_empty() else 1)


func _json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var j := JSON.new()
	if j.parse(f.get_as_text()) != OK:
		return {}
	return j.data if j.data is Dictionary else {}
