extends SceneTree
## Offline selftest for the food-product data layer
## (plans/FOOD_WASTE_REALISM_PLAN.md Phase 1): PackagingArchetypes (the
## cited mass / volume table and the OFF shape x material mapping) and
## FoodProducts (the OFF v2 parser, hand-pinned against real fixture
## replies in core/food/testdata/, the derived composition with an Atwater
## 4/9/4/2 kcal cross-check, and the shipped catalog + user overlay).
##
## Run: Godot.exe.exe --headless --path . --script core/food/food_products_selftest.gd
## (--import first: FoodProducts / PackagingArchetypes are class_names.)

const EXPECTED_CHECKS := 90

const TD := "res://core/food/testdata/"
## The typed waste kinds Phase 4 adds; every archetype must sort into one.
const WASTE_KINDS := ["pet_waste", "hdpe_waste", "film_waste", "mixed_plastic_waste",
	"alu_waste", "steel_waste", "glass_waste", "cardboard_waste", "paper_waste"]

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps


func _initialize() -> void:
	# Never read or write the player's own product file.
	var tmp_dir := OS.get_environment("TEMP")
	if tmp_dir.is_empty():
		tmp_dir = "user://"
	FoodProducts.user_path = tmp_dir.path_join("simbio_food_selftest.json")
	if FileAccess.file_exists(FoodProducts.user_path):
		DirAccess.remove_absolute(FoodProducts.user_path)
	FoodProducts.reload()

	_test_archetype_table()
	_test_map_off()
	_test_fixture_parse()
	_test_composition()
	_test_catalog()
	_test_user_overlay()

	if FileAccess.file_exists(FoodProducts.user_path):
		DirAccess.remove_absolute(FoodProducts.user_path)
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a runtime error aborted a test?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("FOOD PRODUCTS SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("FOOD PRODUCTS SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fixture(code: String) -> Dictionary:
	var f := FileAccess.open(TD + "off_%s.json" % code, FileAccess.READ)
	if f == null:
		return {}
	var j := JSON.new()
	if j.parse(f.get_as_text()) != OK:
		return {}
	return j.data


# --- the archetype table -----------------------------------------------------

func _test_archetype_table() -> void:
	var ids := PackagingArchetypes.ids()
	_check("table has archetypes", ids.size() >= 15, str(ids.size()))
	var mass_ok := true
	var vol_ok := true
	var kind_ok := true
	var mesh_ok := true
	var src_ok := true
	var est_ok := true
	for aid in ids:
		var a: Dictionary = PackagingArchetypes.get_archetype(aid)
		if float(a.get("mass_g", 0.0)) <= 0.0:
			mass_ok = false
		# Crushed always packs tighter than loose, and both are real volumes.
		if not (float(a.get("loose_l", 0.0)) > float(a.get("crushed_l", 0.0))
				and float(a.get("crushed_l", 0.0)) > 0.0):
			vol_ok = false
		if not WASTE_KINDS.has(str(a.get("waste_kind", ""))):
			kind_ok = false
		if str(a.get("mesh_id", "")).is_empty():
			mesh_ok = false
		if str(a.get("src", "")).is_empty():
			src_ok = false
		if not bool(a.get("est", false)):
			est_ok = false
	_check("every archetype has a mass", mass_ok)
	_check("every archetype: 0 < crushed_l < loose_l", vol_ok)
	_check("every archetype sorts into a typed waste kind", kind_ok)
	_check("every archetype names a mesh", mesh_ok)
	_check("every archetype cites a source", src_ok)
	_check("every archetype is flagged est (they are estimates)", est_ok)
	# The one measured weight: OFF's weight_measured on the Oatly fixture.
	_check("carton_1l carries the measured Tetra Brik weight",
			_near(PackagingArchetypes.mass_g("carton_1l"), 40.4))


func _test_map_off() -> void:
	# Quantity parsing.
	_check("parse '25 cl'", _near(PackagingArchetypes.parse_qty_g_ml("25 cl"), 250.0))
	_check("parse '1 L'", _near(PackagingArchetypes.parse_qty_g_ml("1 L"), 1000.0))
	_check("parse bare '415'", _near(PackagingArchetypes.parse_qty_g_ml("415"), 415.0))
	_check("parse '1 oz (28.3 g)' prefers the metric amount",
			_near(PackagingArchetypes.parse_qty_g_ml("1 oz (28.3 g)"), 28.3, 0.01))
	_check("parse empty -> 0", _near(PackagingArchetypes.parse_qty_g_ml(""), 0.0))
	# Shape x material x size -> archetype.
	_check("PET bottle, 500 ml",
			PackagingArchetypes.map_off("en:bottle", "en:pet-1-polyethylene-terephthalate", "", 500.0) == "pet_bottle_500")
	_check("PET bottle, 1 L",
			PackagingArchetypes.map_off("en:bottle", "en:pet-1-polyethylene-terephthalate", "", 1000.0) == "pet_bottle_1l")
	_check("PET bottle, 2 L",
			PackagingArchetypes.map_off("en:bottle", "en:plastic", "2 l", 0.0) == "pet_bottle_2l")
	_check("glass bottle, wine size",
			PackagingArchetypes.map_off("en:bottle", "en:glass", "75 cl", 0.0) == "glass_bottle_750")
	_check("aluminium can",
			PackagingArchetypes.map_off("en:can", "en:aluminium", "33 cl", 0.0) == "alu_can_355")
	_check("steel can, 415 g",
			PackagingArchetypes.map_off("en:can", "en:steel", "415", 0.0) == "steel_can_400")
	_check("tetra brick",
			PackagingArchetypes.map_off("en:brick", "en:tetra-brik-aseptic", "", 1000.0) == "carton_1l")
	_check("glass jar",
			PackagingArchetypes.map_off("en:jar", "en:glass", "", 400.0) == "glass_jar_400")
	_check("paper bag",
			PackagingArchetypes.map_off("en:bag", "en:paper", "", 0.0) == "paper_bag")
	_check("plastic bag whatever the material tag's language",
			PackagingArchetypes.map_off("en:bag", "es:plastico-metalizado", "", 28.0) == "film_bag")
	_check("untranslated card material ('carton no ondulado')",
			PackagingArchetypes.map_off("en:packet", "es:carton-no-ondulado", "", 500.0) == "card_box_small")
	_check("a bottle cap is a fragment, not a piece",
			PackagingArchetypes.map_off("en:bottle-cap", "en:pet-1-polyethylene-terephthalate", "", 0.0) == "")
	_check("is_fragment_shape(bottle-cap)", PackagingArchetypes.is_fragment_shape("en:bottle-cap"))
	_check("material-only row (a stray PP entry) is not a piece",
			PackagingArchetypes.map_off("", "en:pp-5-polypropylene", "", 0.0) == "")
	_check("unknown shape maps to nothing",
			PackagingArchetypes.map_off("en:net", "en:mystery", "", 0.0) == "")


# --- the OFF parser, pinned against real fixture replies ---------------------

func _test_fixture_parse() -> void:
	# Coca-Cola 1 L: PET bottle + cap + two material-only rows.
	var coke := FoodProducts.parse_off_product(_fixture("5449000054227"))
	_check("coke: parsed", not coke.is_empty())
	_check("coke: name", str(coke.get("name", "")) == "Coca-Cola Original Taste")
	_check("coke: net 1000 g", _near(float(coke.get("net_g", 0.0)), 1000.0))
	_check("coke: serving 250 g", _near(float(coke.get("serving_g", 0.0)), 250.0))
	_check("coke: 42 kcal/100g", _near(float(coke.get("kcal_100g", -1.0)), 42.0))
	_check("coke: category beverage", str(coke.get("category", "")) == "beverage")
	var cp: Array = coke.get("packagings", [])
	_check("coke: exactly the 1 L PET bottle", cp.size() == 1
			and str(cp[0].get("archetype_id", "")) == "pet_bottle_1l"
			and int(cp[0].get("count", 0)) == 1, str(cp))
	_check("coke: cap and stray rows were not 'unmapped'", not coke.has("unmapped"))
	_check("coke: kcal_per_kg 420", _near(FoodProducts.kcal_per_kg(coke), 420.0))
	_check("coke: food_mj_kg 1.757", _near(FoodProducts.food_mj_kg(coke), 42.0 * 0.04184, 1e-3))
	_check("coke: packaging mass 38 g", _near(FoodProducts.packaging_mass_g(coke), 38.0))
	_check("coke: gross 1038 g", _near(FoodProducts.gross_g(coke), 1038.0))
	_check("coke: waste kg by kind", _near(float(FoodProducts.waste_kg_by_kind(coke).get("pet_waste", 0.0)), 0.038))
	_check("coke: loose litres in the bin", _near(FoodProducts.waste_loose_l(coke), 1.85))

	# Heinz Beanz 415 g steel can.
	var beans := FoodProducts.parse_off_product(_fixture("5000157024671"))
	_check("beans: steel_can_400", _one_pack(beans, "steel_can_400"), str(beans.get("packagings")))
	_check("beans: category canned", str(beans.get("category", "")) == "canned")
	_check("beans: kcal 81", _near(float(beans.get("kcal_100g", -1.0)), 81.0))
	_check("beans: fiber 3.9", _near(float(beans.get("fiber_100g", -1.0)), 3.9))
	_check("beans: waste is steel", _near(float(FoodProducts.waste_kg_by_kind(beans).get("steel_waste", 0.0)), 0.055))

	# Nutella 400 g glass jar (fiber missing on the label).
	var nutella := FoodProducts.parse_off_product(_fixture("3017624010701"))
	_check("nutella: glass_jar_400", _one_pack(nutella, "glass_jar_400"), str(nutella.get("packagings")))
	_check("nutella: no fiber key when the label has none", not nutella.has("fiber_100g"))
	_check("nutella: net 400", _near(float(nutella.get("net_g", 0.0)), 400.0))

	# Oatly 1 L aseptic carton.
	var oatly := FoodProducts.parse_off_product(_fixture("7394376616501"))
	_check("oatly: carton_1l", _one_pack(oatly, "carton_1l"), str(oatly.get("packagings")))
	_check("oatly: category beverage", str(oatly.get("category", "")) == "beverage")

	# Barilla 500 g: card box + film window, two pieces.
	var pasta := FoodProducts.parse_off_product(_fixture("8076802085738"))
	var pp: Array = pasta.get("packagings", [])
	_check("pasta: box + film", pp.size() == 2
			and str(pp[0].get("archetype_id", "")) == "card_box_small"
			and str(pp[1].get("archetype_id", "")) == "film_wrap", str(pp))
	_check("pasta: category grains", str(pasta.get("category", "")) == "grains")
	_check("pasta: two waste kinds", FoodProducts.waste_kg_by_kind(pasta).size() == 2)

	# Doritos 1 oz: film bag; serving_quantity arrives as a STRING in OFF.
	var chips := FoodProducts.parse_off_product(_fixture("0028400090896"))
	_check("chips: film_bag", _one_pack(chips, "film_bag"), str(chips.get("packagings")))
	_check("chips: category snacks", str(chips.get("category", "")) == "snacks")
	_check("chips: net ~28.35 g", _near(float(chips.get("net_g", 0.0)), 28.349523125, 1e-3))
	_check("chips: string serving parsed", _near(float(chips.get("serving_g", 0.0)), 28.349, 1e-3))

	# Degenerate replies.
	_check("empty reply -> {}", FoodProducts.parse_off_product({}).is_empty())
	_check("status 0 -> {}", FoodProducts.parse_off_product({"status": 0, "code": "x",
			"product": {"code": "x"}}).is_empty())


func _one_pack(p: Dictionary, aid: String) -> bool:
	var packs: Array = p.get("packagings", [])
	return packs.size() == 1 and str(packs[0].get("archetype_id", "")) == aid \
			and int(packs[0].get("count", 0)) == 1


# --- composition + the Atwater cross-check ------------------------------------

func _test_composition() -> void:
	var nutella := FoodProducts.parse_off_product(_fixture("3017624010701"))
	var row := FoodProducts.composition_for(nutella)
	var mix: Dictionary = row.get("mix", {})
	_check("nutella mix: protein 0.063", _near(float(mix.get("protein", 0.0)), 0.063))
	_check("nutella mix: lipid 0.309", _near(float(mix.get("lipid", 0.0)), 0.309))
	_check("nutella mix: carbohydrate 0.575", _near(float(mix.get("carbohydrate", 0.0)), 0.575))
	_check("nutella mix: salt as nacl", _near(float(mix.get("nacl", 0.0)), 0.001075))
	_check("nutella mix: no fibre key", not mix.has("fibre"))
	_check("nutella row: rest is water", str(row.get("rest", "")) == "H2O")
	_check("nutella row: organic family", str(row.get("family", "")) == "organic")
	_check("nutella row: cites the product", str(row.get("src", "")).contains("3017624010701"))
	var sum := 0.0
	for k in mix:
		sum += float(mix[k])
	_check("nutella mix sums under 1", sum < 1.0, str(sum))
	# Atwater 4/9/4 (+2 fibre) vs the label's kcal, within 15 %.
	_check("nutella: Atwater agrees with the label", _atwater_ok(nutella), _atwater_s(nutella))
	var beans := FoodProducts.parse_off_product(_fixture("5000157024671"))
	_check("beans: Atwater agrees with the label", _atwater_ok(beans), _atwater_s(beans))
	# A product with no macros falls back to the generic food split.
	var bare := {"id": "x", "net_g": 100.0}
	var fb := FoodProducts.composition_for(bare)
	_check("fallback row is the generic food split",
			_near(float(fb.get("mix", {}).get("protein", 0.0)), 0.065))
	_check("fallback kcal density is the generic food's",
			_near(FoodProducts.kcal_per_kg(bare), FoodProducts.FALLBACK_KCAL_PER_KG, 0.5))
	# A label whose parts sum past 1 is scaled back so water stays real.
	var dense := {"id": "d", "kcal_100g": 600.0, "protein_100g": 40.0, "fat_100g": 40.0,
		"carb_100g": 40.0, "fiber_100g": 10.0, "salt_100g": 2.0}
	var dmix: Dictionary = FoodProducts.composition_for(dense).get("mix", {})
	var dsum := 0.0
	for k in dmix:
		dsum += float(dmix[k])
	_check("over-1 label scaled back to 0.98", _near(dsum, 0.98, 1e-3), str(dsum))


func _atwater_kcal(p: Dictionary) -> float:
	return 4.0 * (float(p.get("protein_100g", 0.0)) + float(p.get("carb_100g", 0.0))) \
			+ 9.0 * float(p.get("fat_100g", 0.0)) + 2.0 * float(p.get("fiber_100g", 0.0))


func _atwater_ok(p: Dictionary) -> bool:
	var label := float(p.get("kcal_100g", -1.0))
	if label <= 0.0:
		return false
	var est := _atwater_kcal(p)
	return est / label > 0.85 and est / label < 1.15


func _atwater_s(p: Dictionary) -> String:
	return "label %.1f vs Atwater %.1f" % [float(p.get("kcal_100g", -1.0)), _atwater_kcal(p)]


# --- the shipped catalog -------------------------------------------------------

func _test_catalog() -> void:
	var all := FoodProducts.all_products()
	_check("catalog loads", all.size() >= 6, str(all.size()))
	var packs_ok := true
	var price_ok := true
	var kcal_ok := true
	var mass_ok := true
	for p in all:
		for e in FoodProducts.waste_items_for(p):
			if PackagingArchetypes.get_archetype(e["archetype_id"]).is_empty():
				packs_ok = false
		if float(p.get("price_usd", 0.0)) <= 0.0:
			price_ok = false
		if float(p.get("kcal_100g", -1.0)) < 0.0:
			kcal_ok = false
		# Packaging is lighter than what it wraps + itself.
		if not (FoodProducts.packaging_mass_g(p) < FoodProducts.gross_g(p)):
			mass_ok = false
	_check("every catalog packaging resolves to a known archetype", packs_ok)
	_check("every catalog product is priced", price_ok)
	_check("every catalog product has calories", kcal_ok)
	_check("every catalog product: packaging mass < gross mass", mass_ok)
	var meta := FoodProducts.catalog_meta()
	_check("catalog attributes Open Food Facts",
			str(meta.get("attribution", "")).contains("Open Food Facts"))
	_check("catalog names the ODbL", str(meta.get("license", "")).contains("ODbL"))
	var bev := FoodProducts.by_category("beverage")
	_check("by_category finds the drinks", bev.size() >= 2, str(bev.size()))
	_check("product() finds by barcode",
			str(FoodProducts.product("5449000054227").get("brand", "")) == "Coca-Cola")
	_check("unknown barcode -> {}", FoodProducts.product("000000").is_empty())


# --- the user overlay (TEMP path) ---------------------------------------------

func _test_user_overlay() -> void:
	var rec := {"id": "9900000000001", "name": "Test Ration", "category": "other",
		"net_g": 500.0, "kcal_100g": 400.0, "price_usd": 2.0,
		"packagings": [{"archetype_id": "film_bag", "count": 1}]}
	FoodProducts.add_user_product(rec)
	_check("user product merged over the bundle",
			str(FoodProducts.product("9900000000001").get("name", "")) == "Test Ration")
	FoodProducts.set_price_override("5449000054227", 9.99)
	var p := FoodProducts.product("5449000054227")
	_check("price override applies", _near(float(p.get("price_usd", 0.0)), 9.99))
	_check("override marks the price as the player's", str(p.get("price_src", "")) == "player")
	FoodProducts.set_price_override("5449000054227", -1.0)
	_check("override removed restores the catalog price",
			_near(float(FoodProducts.product("5449000054227").get("price_usd", 0.0)), 1.5))
	_check("shipped product count unchanged by the overlay round trip",
			FoodProducts.all_products().size() >= 7)
