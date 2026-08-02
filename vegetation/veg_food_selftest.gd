extends SceneTree

## Headless self-test for the food-forest yield model (veg overhaul Phase 10):
## VegFoodYield's per-polygon summary, the maturity ramp, harvest windows
## (including the ones that wrap the new year), and the harvest rate the flow
## engine integrates. Pure / offline.
##
## Run with:
##   godot --headless --path . --script vegetation/veg_food_selftest.gd

const HPY := VegetationGrowth.HOURS_PER_YEAR

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_maturity_ramp()
	_test_windows()
	_test_harvest_rate()
	_test_summary()
	_test_polygon_bounds()
	_test_maturity_scales_yield()
	if _failures == 0:
		print("VEG FOOD SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG FOOD SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _square(half: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half)])


## --- Maturity ---------------------------------------------------------------

func _test_maturity_ramp() -> void:
	# A sapling bears nothing; yield ramps in over the second half of growth.
	_check("seedling yields nothing",
		is_zero_approx(VegFoodYield.maturity_factor(VegetationGrowth.SEEDLING_SCALE)))
	_check("half-grown yields nothing",
		is_zero_approx(VegFoodYield.maturity_factor(VegFoodYield.YIELD_MATURITY_FLOOR)))
	_check("three-quarter grown yields about half",
		absf(VegFoodYield.maturity_factor(0.75) - 0.5) < 0.01,
		"%.3f" % VegFoodYield.maturity_factor(0.75))
	_check("mature yields fully",
		is_equal_approx(VegFoodYield.maturity_factor(1.0), 1.0))
	_check("over-mature clamps",
		is_equal_approx(VegFoodYield.maturity_factor(1.4), 1.0))
	# Monotonic — a bigger tree never bears less.
	var prev := -1.0
	for i in 21:
		var f := VegFoodYield.maturity_factor(float(i) / 20.0)
		_check("maturity monotonic at %d" % i, f >= prev - 1e-6)
		prev = f


## --- Harvest windows --------------------------------------------------------

func _test_windows() -> void:
	# Apple: late summer into autumn.
	_check("inside a normal window", VegFoodYield.in_window(270, 244, 304))
	_check("before a normal window", not VegFoodYield.in_window(200, 244, 304))
	_check("after a normal window", not VegFoodYield.in_window(340, 244, 304))
	_check("window edges are inclusive",
		VegFoodYield.in_window(244, 244, 304) and VegFoodYield.in_window(304, 244, 304))
	# Orange wraps the new year (doy 335 → 90) — the case a naive
	# start <= doy <= end test gets exactly backwards.
	_check("inside a wrapping window in December", VegFoodYield.in_window(350, 335, 90))
	_check("inside a wrapping window in February", VegFoodYield.in_window(40, 335, 90))
	_check("outside a wrapping window in summer", not VegFoodYield.in_window(200, 335, 90))

	_check("normal window length", VegFoodYield.window_days(244, 304) == 61)
	_check("wrapping window length", VegFoodYield.window_days(335, 90) == 121)
	_check("year-round window", VegFoodYield.window_days(1, 365) == 365)

	_check("days until harvest is zero in season",
		VegFoodYield.days_until_harvest(270, 244, 304) == 0)
	_check("days until an upcoming harvest",
		VegFoodYield.days_until_harvest(200, 244, 304) == 44)
	_check("days until wraps the year",
		VegFoodYield.days_until_harvest(340, 100, 150) == 125,
		str(VegFoodYield.days_until_harvest(340, 100, 150)))


## --- Harvest rate -----------------------------------------------------------

func _test_harvest_rate() -> void:
	# A year's crop is delivered ACROSS the window, so integrating the rate over
	# the window returns the annual yield — this is the property the flow engine
	# depends on for mass to balance.
	var kg := 800.0
	var rate := VegFoodYield.harvest_rate_kg_per_hour(kg, 244, 304)
	var hours := float(VegFoodYield.window_days(244, 304)) * 24.0
	_check("rate integrates to the annual yield",
		is_equal_approx(rate * hours, kg), "%.3f vs %.3f" % [rate * hours, kg])
	# A wrapping window integrates too.
	var wrate := VegFoodYield.harvest_rate_kg_per_hour(kg, 335, 90)
	_check("wrapping rate integrates to the annual yield",
		is_equal_approx(wrate * float(VegFoodYield.window_days(335, 90)) * 24.0, kg))
	# A short window is a more intense harvest than a long one.
	_check("shorter window harvests faster",
		VegFoodYield.harvest_rate_kg_per_hour(kg, 244, 254)
			> VegFoodYield.harvest_rate_kg_per_hour(kg, 1, 365))
	_check("no yield → no rate",
		is_zero_approx(VegFoodYield.harvest_rate_kg_per_hour(0.0, 244, 304)))


## --- Per-area summary -------------------------------------------------------

func _mature_settings() -> Dictionary:
	# growth_now_h far past maturity → every tree renders full size.
	return {"deciduous_growth_years": 10.0, "pine_growth_years": 20.0,
		"growth_now_h": 500.0 * HPY}


func _test_summary() -> void:
	var poly := _square(50.0)
	var bulk := {"apple": [], "pine": []}
	for i in 10:
		(bulk["apple"] as Array).append(
			{"x": float(i) * 2.0, "z": 0.0, "scale": 1.0, "birth_h": 0.0})
	for i in 5:
		(bulk["pine"] as Array).append(
			{"x": float(i) * 2.0, "z": 10.0, "scale": 1.0, "birth_h": 0.0})
	var s := VegFoodYield.summarize(bulk, poly, _mature_settings())
	# Pines are not food — a conifer stand must not read as an orchard.
	_check("only food species counted", int(s["trees"]) == 10, str(s["trees"]))
	_check("non-food species absent from the mix",
		not (s["species_counts"] as Dictionary).has("pine"))
	var apple := VegSpeciesRegistry.food("apple")
	var expect_kg := 10.0 * float(apple["yield_kg_per_year"])
	_check("annual yield is per-tree × count",
		is_equal_approx(float(s["kg_per_year"]), expect_kg),
		"%.1f vs %.1f" % [float(s["kg_per_year"]), expect_kg])
	_check("energy density is the species value",
		is_equal_approx(float(s["kcal_per_kg"]), float(apple["kcal_per_kg"])))
	_check("annual calories follow",
		is_equal_approx(float(s["kcal_per_year"]), expect_kg * float(apple["kcal_per_kg"])))
	_check("harvest window comes from the species",
		int(s["harvest_start_doy"]) == int(apple["harvest_start_doy"])
			and int(s["harvest_end_doy"]) == int(apple["harvest_end_doy"]))
	_check("dominant species reported", str(s["dominant"]) == "apple")

	# Mixed orchard: the window follows the species contributing the most MASS,
	# not the most trees — blending two windows would invent a season neither
	# tree has.
	var mixed := {"apple": [], "walnut": []}
	for i in 3:
		(mixed["apple"] as Array).append(
			{"x": float(i), "z": 0.0, "scale": 1.0, "birth_h": 0.0})
	for i in 20:
		(mixed["walnut"] as Array).append(
			{"x": float(i), "z": 5.0, "scale": 1.0, "birth_h": 0.0})
	var m := VegFoodYield.summarize(mixed, poly, _mature_settings())
	var walnut := VegSpeciesRegistry.food("walnut")
	_check("mixed orchard counts both", int(m["trees"]) == 23)
	_check("dominant is the heavier crop", str(m["dominant"]) == "walnut", str(m))
	_check("window follows the dominant crop",
		int(m["harvest_start_doy"]) == int(walnut["harvest_start_doy"]))
	_check("blended energy density sits between the two",
		float(m["kcal_per_kg"]) > float(apple["kcal_per_kg"])
			and float(m["kcal_per_kg"]) < float(walnut["kcal_per_kg"]),
		"%.0f" % float(m["kcal_per_kg"]))

	# An empty / non-food area yields a clean zero rather than a broken node.
	var empty := VegFoodYield.summarize({"pine": bulk["pine"]}, poly, _mature_settings())
	_check("conifer-only area has no yield", is_zero_approx(float(empty["kg_per_year"])))
	_check("empty bulk is safe", int(VegFoodYield.summarize({}, poly)["trees"]) == 0)
	_check("degenerate polygon is safe",
		int(VegFoodYield.summarize(bulk, PackedVector2Array())["trees"]) == 0)


func _test_polygon_bounds() -> void:
	# Only trees INSIDE the outline count — an orchard next door is not yours.
	var poly := _square(10.0)
	var bulk := {"apple": [
		{"x": 0.0, "z": 0.0, "scale": 1.0, "birth_h": 0.0},
		{"x": 500.0, "z": 500.0, "scale": 1.0, "birth_h": 0.0},
	]}
	var s := VegFoodYield.summarize(bulk, poly, _mature_settings())
	_check("outside trees excluded", int(s["trees"]) == 1, str(s["trees"]))


func _test_maturity_scales_yield() -> void:
	var poly := _square(50.0)
	var young := {"apple": []}
	for i in 10:
		# Planted "now" → seedlings.
		(young["apple"] as Array).append(
			{"x": float(i), "z": 0.0, "scale": 1.0, "birth_h": 10.0 * HPY})
	var st := {"deciduous_growth_years": 10.0, "growth_now_h": 10.0 * HPY}
	var s_young := VegFoodYield.summarize(young, poly, st)
	_check("a fresh planting counts trees", int(s_young["trees"]) == 10)
	_check("a fresh planting yields nothing yet",
		is_zero_approx(float(s_young["kg_per_year"])), str(s_young["kg_per_year"]))
	# Same trees, a decade later.
	var st_old := st.duplicate()
	st_old["growth_now_h"] = 20.0 * HPY
	var s_old := VegFoodYield.summarize(young, poly, st_old)
	_check("the same trees bear once mature",
		float(s_old["kg_per_year"]) > 0.0, str(s_old["kg_per_year"]))
	_check("mature planting reaches the full per-tree yield",
		is_equal_approx(float(s_old["kg_per_year"]),
			10.0 * float(VegSpeciesRegistry.food("apple")["yield_kg_per_year"])))
