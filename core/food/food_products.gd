class_name FoodProducts
extends RefCounted
## Real store-bought food products (plans/FOOD_WASTE_REALISM_PLAN.md Phase 1).
##
## A PRODUCT is one barcode: name, net content, calories and macros per
## 100 g, an estimated price, and its packaging as counts of
## PackagingArchetypes pieces. The shipped catalog
## (res://core/food/data/food_catalog.json) is derived from the
## Open Food Facts database (openfoodfacts.org) — © Open Food Facts
## contributors, Open Database License (ODbL); see CREDITS.md — by
## tools/food/build_catalog.py. Products the player adds in game (and
## price overrides) live in user://food_products.json and are merged over
## the bundle.
##
## Record schema (all macro keys optional — missing means unknown):
##   {id (barcode), name, brand, category, net_g, serving_g, kcal_100g,
##    protein_100g, fat_100g, carb_100g, fiber_100g, salt_100g,
##    price_usd, price_src, packagings: [{archetype_id, count}],
##    off_rev, fetched}
##
## Everything here is pure and file-path-parameterised so the selftest
## runs on fixtures and TEMP paths.

const CATALOG_PATH := "res://core/food/data/food_catalog.json"
const USER_PATH := "user://food_products.json"
## Selftests point this at a TEMP file so the player's own products and
## price overrides are never read or written by a test.
static var user_path := USER_PATH

## kcal -> MJ: 1 kcal = 4.184 kJ; per-100g -> per-kg is x10.
const MJ_PER_KCAL_100G := 0.04184
## The generic `food` kind's energy density (CompositionData KINDS.food,
## FAO/WHO/UNU 2007 reference day): the fallback when no product is known.
const FALLBACK_KCAL_PER_KG := 6.97 / 0.004184  # ~1666 kcal/kg

## Coarse menu categories, in display order. `category_of` maps OFF
## categories_tags onto them by keyword.
const CATEGORIES := ["grains", "canned", "produce", "protein", "dairy",
	"snacks", "beverage", "condiments", "baking", "other"]

static var _merged: Array = []
static var _by_id: Dictionary = {}
static var _rev := 0
static var _loaded := false


# --- catalog access ----------------------------------------------------------

static func rev() -> int:
	return _rev


static func reload() -> void:
	_loaded = false
	_rev += 1


static func all_products() -> Array:
	_ensure_loaded()
	return _merged


## The shipped catalog's own header (attribution, license, generated date)
## — the shopping UI's footer line.
static func catalog_meta() -> Dictionary:
	var doc := _load_json(CATALOG_PATH)
	return {"attribution": str(doc.get("attribution", "")), "license": str(doc.get("license", "")),
		"generated": str(doc.get("generated", "")), "version": int(doc.get("version", 0))}


static func product(id: String) -> Dictionary:
	_ensure_loaded()
	return _by_id.get(id, {})


static func by_category(cat: String) -> Array:
	_ensure_loaded()
	var out: Array = []
	for p in _merged:
		if str(p.get("category", "other")) == cat:
			out.append(p)
	return out


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_merged = []
	_by_id = {}
	var shipped := _load_json(CATALOG_PATH)
	for p in shipped.get("products", []):
		if p is Dictionary and p.has("id"):
			_by_id[str(p["id"])] = p
	var user := _load_json(user_path)
	for p in user.get("products", []):
		if p is Dictionary and p.has("id"):
			_by_id[str(p["id"])] = p  # the player's copy wins
	var overrides: Dictionary = user.get("price_overrides", {})
	for id in overrides:
		if _by_id.has(str(id)):
			var rec: Dictionary = (_by_id[str(id)] as Dictionary).duplicate()
			rec["price_usd"] = float(overrides[id])
			rec["price_src"] = "player"
			_by_id[str(id)] = rec
	var ids := _by_id.keys()
	ids.sort()
	for id in ids:
		_merged.append(_by_id[id])


static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var j := JSON.new()
	if j.parse(f.get_as_text()) != OK:
		return {}
	return j.data if j.data is Dictionary else {}


## Append a product the player added (from OffService) and persist it.
static func add_user_product(rec: Dictionary) -> void:
	if not rec.has("id"):
		return
	var user := _load_json(user_path)
	var products: Array = user.get("products", [])
	for i in products.size():
		if products[i] is Dictionary and str(products[i].get("id", "")) == str(rec["id"]):
			products.remove_at(i)
			break
	products.append(rec)
	user["products"] = products
	_save_user(user)
	reload()


static func set_price_override(id: String, usd: float) -> void:
	var user := _load_json(user_path)
	var overrides: Dictionary = user.get("price_overrides", {})
	if usd < 0.0:
		overrides.erase(id)
	else:
		overrides[id] = usd
	user["price_overrides"] = overrides
	_save_user(user)
	reload()


static func _save_user(user: Dictionary) -> void:
	var f := FileAccess.open(user_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(user, "\t"))
	f.close()


# --- derived numbers ---------------------------------------------------------

static func kcal_per_kg(p: Dictionary) -> float:
	var k100 := float(p.get("kcal_100g", -1.0))
	return k100 * 10.0 if k100 >= 0.0 else FALLBACK_KCAL_PER_KG


static func food_mj_kg(p: Dictionary) -> float:
	var k100 := float(p.get("kcal_100g", -1.0))
	return k100 * MJ_PER_KCAL_100G if k100 >= 0.0 else 6.97


static func net_kg(p: Dictionary) -> float:
	return float(p.get("net_g", 0.0)) / 1000.0


## [{archetype_id, count}] — the product's packaging as countable pieces.
static func waste_items_for(p: Dictionary) -> Array:
	var out: Array = []
	for e in p.get("packagings", []):
		if e is Dictionary and str(e.get("archetype_id", "")) != "":
			out.append({"archetype_id": str(e["archetype_id"]), "count": int(e.get("count", 1))})
	return out


static func packaging_mass_g(p: Dictionary) -> float:
	var g := 0.0
	for e in waste_items_for(p):
		g += PackagingArchetypes.mass_g(e["archetype_id"]) * int(e["count"])
	return g


static func gross_g(p: Dictionary) -> float:
	return float(p.get("net_g", 0.0)) + packaging_mass_g(p)


## kg of each typed waste kind one unit of this product leaves behind.
static func waste_kg_by_kind(p: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for e in waste_items_for(p):
		var kind := PackagingArchetypes.waste_kind(e["archetype_id"])
		if kind.is_empty():
			continue
		var kg := PackagingArchetypes.mass_g(e["archetype_id"]) * int(e["count"]) / 1000.0
		out[kind] = float(out.get(kind, 0.0)) + kg
	return out


## Loose bin litres one unit's packaging takes up.
static func waste_loose_l(p: Dictionary) -> float:
	var l := 0.0
	for e in waste_items_for(p):
		l += PackagingArchetypes.loose_l(e["archetype_id"]) * int(e["count"])
	return l


## A CompositionData-KINDS-shaped row for this product's CONTENT (per kg of
## food inside, packaging excluded): macros as the existing components.
## Unknown macros fall back to the generic food split.
static func composition_for(p: Dictionary) -> Dictionary:
	if float(p.get("kcal_100g", -1.0)) < 0.0 or float(p.get("protein_100g", -1.0)) < 0.0:
		# Not enough data: the generic food row applies.
		return {"mix": {"protein": 0.065, "lipid": 0.057, "carbohydrate": 0.224,
			"fibre": 0.013, "food_minerals": 0.011}, "rest": "H2O", "family": "organic",
			"food_mj_kg": food_mj_kg(p), "src": "FAO/WHO/UNU 2007 reference day (fallback)", "est": true}
	var mix := {
		"protein": maxf(float(p.get("protein_100g", 0.0)), 0.0) / 100.0,
		"lipid": maxf(float(p.get("fat_100g", 0.0)), 0.0) / 100.0,
		"carbohydrate": maxf(float(p.get("carb_100g", 0.0)), 0.0) / 100.0,
		"fibre": maxf(float(p.get("fiber_100g", 0.0)), 0.0) / 100.0,
		"nacl": maxf(float(p.get("salt_100g", 0.0)), 0.0) / 100.0,
	}
	for k in mix.keys():
		if mix[k] <= 0.0:
			mix.erase(k)
	# A label whose parts sum past 1 (double-counted sugars, bad entries)
	# is scaled back so `rest: H2O` stays a real remainder.
	var total := 0.0
	for k in mix:
		total += float(mix[k])
	if total > 0.98:
		for k in mix.keys():
			mix[k] = float(mix[k]) * 0.98 / total
	return {"mix": mix, "rest": "H2O", "family": "organic",
		"food_mj_kg": food_mj_kg(p),
		"src": "Open Food Facts label, product %s" % str(p.get("id", "?")), "est": true}


# --- Open Food Facts parsing (pure) ------------------------------------------

## OFF v2 reply (the whole {code, product, status} envelope or a bare
## product dict) -> a product record. Unmappable packaging entries are
## reported under "unmapped" (the curation tool prints them; harmless to
## keep). Returns {} when the reply holds no product.
static func parse_off_product(off_json: Dictionary) -> Dictionary:
	var prod: Dictionary = off_json
	if off_json.has("product") and off_json["product"] is Dictionary:
		if int(off_json.get("status", 1)) != 1:
			return {}
		prod = off_json["product"]
	if prod.is_empty():
		return {}
	var id := str(prod.get("code", off_json.get("code", "")))
	if id.is_empty():
		return {}
	var rec := {"id": id}
	rec["name"] = str(prod.get("product_name", "")).strip_edges()
	var brands := str(prod.get("brands", ""))
	rec["brand"] = brands.get_slice(",", 0).strip_edges()
	rec["category"] = category_of(prod.get("categories_tags", []))
	# Net content: product_quantity is g or ml (1 g ~ 1 ml for packaging
	# and energy sizing — an estimate, said so in the plan).
	var net := _to_float(prod.get("product_quantity", 0.0))
	if net <= 0.0:
		net = PackagingArchetypes.parse_qty_g_ml(str(prod.get("quantity", "")))
	rec["net_g"] = net
	var serving := _to_float(prod.get("serving_quantity", 0.0))
	if serving > 0.0:
		rec["serving_g"] = serving
	var nut: Dictionary = prod.get("nutriments", {})
	var kcal := _nutriment(nut, "energy-kcal_100g")
	if kcal < 0.0:
		var kj := _nutriment(nut, "energy-kj_100g")
		if kj < 0.0:
			kj = _nutriment(nut, "energy_100g")  # energy_* is kJ
		if kj >= 0.0:
			kcal = kj / 4.184
	if kcal >= 0.0:
		rec["kcal_100g"] = kcal
	for pair in [["protein_100g", "proteins_100g"], ["fat_100g", "fat_100g"],
			["carb_100g", "carbohydrates_100g"], ["fiber_100g", "fiber_100g"],
			["salt_100g", "salt_100g"]]:
		var v := _nutriment(nut, pair[1])
		if v >= 0.0:
			rec[pair[0]] = v
	# Packaging: each structured entry -> an archetype; counts merged.
	var counts: Dictionary = {}
	var unmapped: Array = []
	for e in prod.get("packagings", []):
		if not (e is Dictionary):
			continue
		var shape := _tag_str(e.get("shape", ""))
		var material := _tag_str(e.get("material", ""))
		var qty := str(e.get("quantity_per_unit", e.get("quantity", "")))
		var aid := PackagingArchetypes.map_off(shape, material, qty, net)
		if aid.is_empty():
			if not shape.is_empty() and not PackagingArchetypes.is_fragment_shape(shape):
				unmapped.append("%s|%s" % [shape, material])
			continue
		var n := int(maxf(_to_float(e.get("number_of_units", 1.0)), 1.0))
		counts[aid] = int(counts.get(aid, 0)) + n
	var packs: Array = []
	var aids := counts.keys()
	aids.sort()
	for aid in aids:
		packs.append({"archetype_id": aid, "count": int(counts[aid])})
	rec["packagings"] = packs
	if not unmapped.is_empty():
		rec["unmapped"] = unmapped
	var off_rev := int(_to_float(prod.get("rev", 0.0)))
	if off_rev > 0:
		rec["off_rev"] = off_rev
	return rec


const _CATEGORY_KEYWORDS := [
	# snacks before dairy: a flavour word ("nacho cheese tortilla chips")
	# must not out-vote the snack it is on.
	["snacks", ["snack", "chip", "crisp", "biscuit", "cookie", "chocolate", "confection", "candy"]],
	["dairy", ["dairy", "milk", "cheese", "yogurt", "butter"]],
	["canned", ["canned", "preserved", "legume", "bean", "soup"]],
	["grains", ["pasta", "rice", "cereal", "bread", "flour", "grain", "oat"]],
	["protein", ["meat", "fish", "seafood", "egg", "tofu", "nut", "jerky"]],
	["produce", ["fruit", "vegetable", "produce", "salad"]],
	["condiments", ["sauce", "condiment", "spread", "dressing", "spice", "salt", "sugar",
		"sweetener", "syrup", "honey", "oil", "fat"]],
	["baking", ["baking", "yeast"]],
	["beverage", ["beverage", "drink", "water", "juice", "soda", "coffee", "tea"]],
]


## Map OFF categories_tags onto the game's coarse menu categories. OFF
## orders tags general -> specific, and the general ones are umbrellas
## ("plant-based-foods-and-beverages" sits on most foods), so tags are
## walked from the MOST specific end and each tag is matched on its own.
static func category_of(tags: Variant) -> String:
	var list: Array = tags if tags is Array else [tags]
	for i in range(list.size() - 1, -1, -1):
		var t := PackagingArchetypes.strip_tag(str(list[i]))
		if t.is_empty():
			continue
		for pair in _CATEGORY_KEYWORDS:
			for kw in pair[1]:
				if t.contains(kw):
					return str(pair[0])
	return "other"


static func _tag_str(v: Variant) -> String:
	if v is Dictionary:
		return str((v as Dictionary).get("id", ""))
	return str(v)


static func _to_float(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	var s := str(v).strip_edges()
	return s.to_float() if s.is_valid_float() else 0.0


static func _nutriment(nut: Dictionary, key: String) -> float:
	if not nut.has(key):
		return -1.0
	var v := _to_float(nut[key])
	return v if v >= 0.0 else -1.0
