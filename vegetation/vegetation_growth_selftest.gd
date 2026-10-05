extends SceneTree

## Headless self-test for the plant growth model: VegGrowthModel (the pure
## calendar → size function) and VegetationGrowth (its record/settings facade).
## Pure / offline. Run --import first so VegGrowthModel registers.
##   godot --headless --path . --script vegetation/vegetation_growth_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

const HPY := VegetationGrowth.HOURS_PER_YEAR
## A Godot runtime error aborts the enclosing test function while the suite
## still prints PASS, so the check COUNT is pinned too.
const EXPECTED_CHECKS := 109

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_scale_curve()
	_test_lifecycle_senescence()
	_test_height_curve()
	_test_identity()
	_test_life_cycle()
	_test_growth_year()
	_test_seed()
	_test_painted_grove_never_shrinks_together()
	_test_plant_young()
	_test_migration()
	_test_forest_profiles()
	_test_instance_custom()
	_test_shader_mirror_constants()
	_test_settings_with_variant_non_clobber()
	_test_size_var_scales()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)"
			% [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("VEG GROWTH SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG GROWTH SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _approx(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _st(t: float, born: float, maturity: float, life: float, seed: float) -> Dictionary:
	return VegGrowthModel.state(t, born, maturity, life, seed)


# ---- grow-bed crop curve (unchanged; GrowBed reads these directly) ---------

func _test_scale_curve() -> void:
	var gy := 20.0
	_check("seedling scale at age 0",
		_approx(VegetationGrowth.scale_for_age(0.0, gy), VegetationGrowth.SEEDLING_SCALE, 1e-6),
		"got %f" % VegetationGrowth.scale_for_age(0.0, gy))
	_check("full scale at maturity",
		_approx(VegetationGrowth.scale_for_age(gy, gy), 1.0, 1e-6),
		"got %f" % VegetationGrowth.scale_for_age(gy, gy))
	_check("full scale past maturity (clamped)",
		_approx(VegetationGrowth.scale_for_age(gy * 3.0, gy), 1.0, 1e-6))
	var mono := true
	var prev := -1.0
	for i in 21:
		var s := VegetationGrowth.scale_for_age(float(i), gy)
		if s < prev - 1e-6:
			mono = false
		prev = s
	_check("scale monotonic non-decreasing", mono)
	_check("gy<=0 disables growth (scale 1)",
		_approx(VegetationGrowth.scale_for_age(5.0, 0.0), 1.0, 1e-6))


func _test_lifecycle_senescence() -> void:
	var grow_h := 10.0 * HPY
	var sen_h := 5.0 * HPY
	_check("lifecycle seedling",
		_approx(VegetationGrowth.scale_for_lifecycle(0.0, grow_h, sen_h),
			VegetationGrowth.SEEDLING_SCALE, 1e-6))
	_check("lifecycle full at maturity",
		_approx(VegetationGrowth.scale_for_lifecycle(grow_h, grow_h, sen_h), 1.0, 1e-6))
	_check("lifecycle senescent floor",
		_approx(VegetationGrowth.scale_for_lifecycle(grow_h + sen_h, grow_h, sen_h),
			VegetationGrowth.SENESCENT_SCALE, 1e-6))
	_check("stage seed", VegetationGrowth.growth_stage(0.0, grow_h, sen_h) == "seed")
	_check("stage growing", VegetationGrowth.growth_stage(grow_h * 0.5, grow_h, sen_h) == "growing")
	_check("stage full", VegetationGrowth.growth_stage(grow_h, grow_h, sen_h) == "full")
	_check("stage senescent",
		VegetationGrowth.growth_stage(grow_h + sen_h * 0.5, grow_h, sen_h) == "senescent")


# ---- the model --------------------------------------------------------------

func _test_height_curve() -> void:
	_check("seedling height at age 0",
		_approx(VegGrowthModel.height_curve(0.0), VegGrowthModel.SEED_HEIGHT, 1e-9))
	_check("height is EXACTLY 1 at maturity",
		VegGrowthModel.height_curve(1.0) == 1.0)
	_check("height approaches 1 continuously",
		VegGrowthModel.height_curve(0.9999) > 0.999)
	_check("height holds past maturity", VegGrowthModel.height_curve(7.0) == 1.0)
	var mono := true
	var prev := -1.0
	for i in 201:
		var h := VegGrowthModel.height_curve(float(i) / 200.0)
		if h <= prev:
			mono = false
		prev = h
	_check("height strictly increasing to maturity", mono)
	# Sigmoid, not a ramp: slow establishment, then the pole stage.
	_check("slow establishment (10% of the span is < 20% of the height)",
		VegGrowthModel.height_curve(0.1) < 0.2,
		"got %f" % VegGrowthModel.height_curve(0.1))
	_check("half the span is well over half the height",
		VegGrowthModel.height_curve(0.5) > 0.6)
	# Allometry: a young tree is a slender whip with a thin stem.
	var young := _st(5.0, 0.0, 20.0, 200.0, 0.5)
	_check("young crown lags height", float(young["crown"]) < float(young["height"]))
	_check("young girth lags crown", float(young["girth"]) < float(young["crown"]))
	var ripe := _st(20.0, 0.0, 20.0, 200.0, 0.5)
	_check("height, crown and girth are all 1 at maturity",
		float(ripe["height"]) == 1.0 and float(ripe["crown"]) == 1.0
		and _approx(float(ripe["girth"]), 1.0, 1e-9))


func _test_identity() -> void:
	var s := _st(2026.0, 1990.0, 0.0, 250.0, 0.3)
	_check("maturity 0 is the identity",
		float(s["height"]) == 1.0 and float(s["crown"]) == 1.0
		and float(s["girth"]) == 1.0 and float(s["leaf"]) == 1.0
		and float(s["present"]) == 1.0)
	var rec := {"x": 1.0, "z": 2.0, "born_y": 2026.0}
	_check("no growth_year in settings -> full size",
		VegetationGrowth.instance_scale_mult("pine", rec, {"pine_growth_years": 30.0}) == 1.0)
	_check("frozen -> full size",
		VegetationGrowth.instance_scale_mult("pine", rec,
			{"pine_growth_years": 30.0, "growth_year": 2026.0, "growth_frozen": true}) == 1.0)
	_check("species with growth off -> full size",
		VegetationGrowth.instance_scale_mult("grass_lawn", rec,
			{"grass_lawn_growth_years": 0.0, "growth_year": 2026.0}) == 1.0)
	_check("unfrozen seedling really is small (the three above are not vacuous)",
		VegetationGrowth.instance_scale_mult("pine", rec,
			{"pine_growth_years": 30.0, "growth_year": 2026.0}) < 0.05)


func _test_life_cycle() -> void:
	# maturity 20, lifespan 200, seed 0.5 -> gap 3, head start 3 y, decline
	# from 192; later generations repeat every 3 + 200 − 3 = 200 years.
	var m := 20.0
	var life := 200.0
	var sd := 0.5
	_check("gap from seed", _approx(VegGrowthModel.gap_years(sd), 3.0, 1e-9))
	_check("later generations repeat on gap + life − head start",
		_approx(VegGrowthModel.cycle_years(m, life, sd), 200.0, 1e-9))
	var plateau := _st(100.0, 0.0, m, life, sd)
	_check("plateau: full size, full leaf",
		float(plateau["height"]) == 1.0 and float(plateau["leaf"]) == 1.0)
	_check("plateau: the trunk keeps thickening",
		float(plateau["girth"]) > 1.0 and float(plateau["girth"]) < VegGrowthModel.OLD_GIRTH)
	var thinning := _st(194.0, 0.0, m, life, sd)
	_check("decline: foliage thinning, still standing",
		float(thinning["leaf"]) > 0.0 and float(thinning["leaf"]) < 1.0
		and float(thinning["height"]) == 1.0)
	var snag := _st(197.5, 0.0, m, life, sd)
	_check("decline: bare snag at full height",
		float(snag["leaf"]) == 0.0 and float(snag["height"]) == 1.0)
	var falling := _st(199.9, 0.0, m, life, sd)
	_check("decline: the snag comes down", float(falling["height"]) < 0.2)
	var gone := _st(200.0, 0.0, m, life, sd)
	_check("the instant between generations: nothing stands",
		float(gone["present"]) == 0.0 and float(gone["height"]) == 0.0)
	# Advance regeneration: the replacement is a released sapling rising out of
	# the gap, not bare ground followed by a seedling.
	var rising := _st(201.0, 0.0, m, life, sd)
	var released := VegGrowthModel.height_curve(VegGrowthModel.REGEN_HEAD_START)
	_check("regrowth: a sapling is already rising one year into the gap",
		int(rising["generation"]) == 1 and float(rising["present"]) == 1.0
		and float(rising["height"]) > 0.0 and float(rising["height"]) < released)
	var out := _st(203.0, 0.0, m, life, sd)
	_check("regrowth: released at sapling size, not from a seedling",
		_approx(float(out["height"]), released, 1e-6)
		and released > VegGrowthModel.SEED_HEIGHT * 2.0)
	var next := _st(206.0, 0.0, m, life, sd)
	_check("regrowth: then it grows on from its head-start age",
		int(next["generation"]) == 1 and _approx(float(next["age"]), 3.0 + 3.0, 1e-6)
		and float(next["height"]) > released)
	var third := _st(200.0 + 200.0 + 50.0, 0.0, m, life, sd)
	_check("the cycle repeats: generation 2 is full size 50 years in",
		int(third["generation"]) == 2 and float(third["height"]) == 1.0)
	var before := _st(-10.0, 0.0, m, life, sd)
	_check("before it was planted it is a seedling, not a previous generation",
		int(before["generation"]) == 0
		and _approx(float(before["height"]), VegGrowthModel.SEED_HEIGHT, 1e-9))
	# Continuity: no pop anywhere in two full cycles — the snag comes down to
	# nothing and the next sapling rises from nothing.
	var worst := 0.0
	var prev_h := float(_st(0.0, 0.0, m, life, sd)["height"])
	var t := 0.0
	while t < 420.0:
		t += 0.01
		var h := float(_st(t, 0.0, m, life, sd)["height"])
		worst = maxf(worst, absf(h - prev_h))
		prev_h = h
	_check("height is continuous through decline, gap and regrowth",
		worst <= 0.02, "worst step %f" % worst)
	# Pure function: the answer at a date does not depend on what was asked before.
	var a := _st(77.7, 0.0, m, life, sd)
	_st(300.0, 0.0, m, life, sd)
	_st(5.0, 0.0, m, life, sd)
	_check("rewind returns the identical state", a == _st(77.7, 0.0, m, life, sd))
	# The bug this model replaces: lifespan == maturity killed every tree the
	# moment it reached full size.
	_check("a lifespan inside the maturity age is pushed out past it",
		VegGrowthModel.effective_lifespan(20.0, 10.0) == 25.0)
	var guarded := _st(20.0, 0.0, 20.0, 20.0, sd)
	_check("a tree AT maturity is alive and full size even with lifespan == maturity",
		float(guarded["height"]) == 1.0 and float(guarded["leaf"]) == 1.0
		and float(guarded["present"]) == 1.0)
	var hold := _st(5000.0, 0.0, 5.0, 0.0, sd)
	_check("lifespan 0 grows and holds forever",
		float(hold["height"]) == 1.0 and int(hold["generation"]) == 0
		and float(hold["present"]) == 1.0)


func _test_growth_year() -> void:
	var lat := 45.0
	_check("Jan 1 is the whole year",
		_approx(VegGrowthModel.growth_year(2026, 1.0, lat), 2026.0, 1e-6))
	_check("winter stands still",
		_approx(VegGrowthModel.growth_year(2026, 30.0, lat),
			VegGrowthModel.growth_year(2026, 70.0, lat), 1e-6))
	_check("the spring flush lays down most of the year by midsummer",
		VegGrowthModel.growth_year(2026, 172.0, lat) - 2026.0 > 0.6)
	_check("the year is complete after the flush",
		_approx(VegGrowthModel.growth_year(2026, 250.0, lat), 2027.0, 1e-6))
	for site in [45.0, -45.0, 5.0]:
		var mono := true
		var worst := 0.0
		var prev := VegGrowthModel.growth_year(2025, 1.0, site)
		for y in [2025, 2026, 2027]:
			for d in range(1, 366):
				var g := VegGrowthModel.growth_year(y, float(d), site)
				if g < prev - 1e-9:
					mono = false
				worst = maxf(worst, g - prev)
				prev = g
		_check("growth year never runs backward or jumps at lat %.0f" % site,
			mono and worst < 0.02, "mono=%s worst daily step %f" % [mono, worst])
	# Southern spring is October: growing there while the north stands still.
	var s_grow := VegGrowthModel.growth_year(2026, 320.0, -45.0) \
		- VegGrowthModel.growth_year(2026, 290.0, -45.0)
	var n_grow := VegGrowthModel.growth_year(2026, 320.0, 45.0) \
		- VegGrowthModel.growth_year(2026, 290.0, 45.0)
	_check("hemisphere flip: the south grows in October, the north does not",
		s_grow > 0.1 and n_grow < 1e-6, "south %f north %f" % [s_grow, n_grow])
	_check("the tropics grow all year (linear)",
		_approx(VegGrowthModel.growth_year(2026, 183.625, 5.0), 2026.5, 1e-3))
	# Total growth per calendar year is exactly one year everywhere.
	_check("one growth year per calendar year",
		_approx(VegGrowthModel.growth_year(2031, 100.0, -45.0)
			- VegGrowthModel.growth_year(2026, 100.0, -45.0), 5.0, 1e-6))


func _test_seed() -> void:
	_check("seed is deterministic",
		VegGrowthModel.seed01("pine", 12.34, -5.6) == VegGrowthModel.seed01("pine", 12.34, -5.6))
	_check("seed ignores sub-centimetre float noise",
		VegGrowthModel.seed01("pine", 12.34, -5.6) == VegGrowthModel.seed01("pine", 12.3401, -5.6))
	_check("seed differs by species",
		VegGrowthModel.seed01("pine", 12.34, -5.6) != VegGrowthModel.seed01("cedar", 12.34, -5.6))
	var bins := [0, 0, 0, 0, 0, 0, 0, 0]
	var sum := 0.0
	var in_range := true
	for i in 1000:
		var s := VegGrowthModel.seed01("pine", float(i) * 3.0, float(i % 37) * 2.0)
		if s < 0.0 or s >= 1.0:
			in_range = false
		sum += s
		bins[mini(int(s * 8.0), 7)] += 1
	_check("seeds stay in [0, 1)", in_range)
	_check("seeds spread evenly (mean)", _approx(sum / 1000.0, 0.5, 0.05),
		"mean %f" % (sum / 1000.0))
	_check("seeds fill every bin (no sequential-hash clumping)",
		bins.min() > 80, "bins %s" % str(bins))


func _grove(species: String, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"x": 500.0 + float(i % 40) * 4.1, "z": 60.0 + float(i / 40) * 3.7,
			"yaw": 0.0, "scale": 1.0})
	return out


## The Walton regression, generalised: a grove painted in one stroke stands full
## size, and no single year takes a visible bite out of it — ever.
func _test_painted_grove_never_shrinks_together() -> void:
	var settings := {"pine_growth_years": 47.0}
	var t0 := 2026.76
	var grove := _grove("pine", 800)
	for d in grove:
		VegetationGrowth.stamp_established(d, "pine", settings, t0)
	var st := settings.duplicate()
	st["growth_year"] = t0
	var all_full := true
	for d in grove:
		var s := VegetationGrowth.plant_state("pine", d, st)
		if float(s["height"]) != 1.0 or float(s["leaf"]) != 1.0:
			all_full = false
	_check("every painted tree is exactly full size on the day it is painted", all_full)
	var worst_small := 0
	var worst_absent := 0
	var worst_new_deaths := 0
	var prev_gen: Array = []
	for d in grove:
		prev_gen.append(0)
	for yr in 500:
		st["growth_year"] = t0 + float(yr)
		var small := 0
		var absent := 0
		var deaths := 0
		for i in grove.size():
			var s := VegetationGrowth.plant_state("pine", grove[i], st)
			if float(s["present"]) < 0.5:
				absent += 1
			elif float(s["height"]) < 0.5:
				small += 1
			var g := int(s["generation"])
			if g != int(prev_gen[i]):
				deaths += 1
				prev_gen[i] = g
		worst_small = maxi(worst_small, small)
		worst_absent = maxi(worst_absent, absent)
		worst_new_deaths = maxi(worst_new_deaths, deaths)
	_check("over 500 years never more than 10% of the grove is visibly small",
		worst_small <= 80, "worst %d of 800" % worst_small)
	_check("the grove never has a missing tree (regeneration fills every gap)",
		worst_absent == 0, "worst %d of 800" % worst_absent)
	_check("turnover is staggered: at most 3% replaced in any one year",
		worst_new_deaths <= 24, "worst %d of 800" % worst_new_deaths)
	_check("the grove does turn over (the cycle is real, not grow-and-hold)",
		int(prev_gen.max()) >= 1)
	# Shrubs paint full size too, and hold.
	var shrub := {"x": 3.0, "z": 4.0}
	var ss := {"shrub_growth_years": 5.0}
	VegetationGrowth.stamp_established(shrub, "shrub", ss, t0)
	ss["growth_year"] = t0 + 900.0
	_check("a painted shrub is full size and never cycles",
		VegetationGrowth.instance_scale_mult("shrub", shrub, ss) == 1.0)


func _test_plant_young() -> void:
	var settings := {"pine_growth_years": 47.0}
	var t0 := 2026.3
	var d := {"x": 10.0, "z": 20.0}
	VegetationGrowth.stamp_young(d, t0)
	var st := settings.duplicate()
	st["growth_year"] = t0
	_check("planted young: a seedling today",
		_approx(VegetationGrowth.instance_scale_mult("pine", d, st),
			VegGrowthModel.SEED_HEIGHT, 1e-6))
	st["growth_year"] = t0 + 1.0
	var y1 := VegetationGrowth.instance_scale_mult("pine", d, st)
	st["growth_year"] = t0 + 2.0
	var y2 := VegetationGrowth.instance_scale_mult("pine", d, st)
	_check("bigger every year", y2 > y1 and y1 > VegGrowthModel.SEED_HEIGHT)
	st["growth_year"] = t0 + 47.0
	_check("full size at its maturity age",
		VegetationGrowth.instance_scale_mult("pine", d, st) == 1.0)
	st["growth_year"] = t0 - 30.0
	_check("scrubbing before the planting date shows a seedling, not an old tree",
		_approx(VegetationGrowth.instance_scale_mult("pine", d, st),
			VegGrowthModel.SEED_HEIGHT, 1e-6))


func _test_migration() -> void:
	var settings := {"pine_growth_years": 47.0, "grass_lawn_growth_years": 0.0}
	var span := 47.0 * HPY
	var t0 := 2026.76
	var bulk := {
		"pine": [
			{"x": 0.0, "z": 0.0, "birth_h": 22.8 - span},      # the real Walton stamp
			{"x": 5.0, "z": 0.0, "birth_h": 22.8},              # planted young
			{"x": 9.0, "z": 0.0, "birth_h": -span * 0.5},       # half grown
			{"x": 14.0, "z": 0.0},                              # no birth at all
			{"x": 19.0, "z": 0.0, "born_y": 1999.0},            # already migrated
		],
		"cedar": [{"x": 3.0, "z": 0.0, "birth_h": 22.8 - span}],
		"grass_lawn": [{"x": 1.0, "z": 1.0, "birth_h": 22.8}],
	}
	var n := VegetationGrowth.migrate_records(bulk, settings, t0)
	_check("migration touches every legacy record", n == 6, "got %d" % n)
	var any_legacy := false
	for slot in bulk:
		for d in bulk[slot]:
			if (d as Dictionary).has("birth_h"):
				any_legacy = true
	_check("no birth_h survives", not any_legacy)
	var st := settings.duplicate()
	st["growth_year"] = t0
	_check("the Walton stamp migrates to a full-size tree",
		VegetationGrowth.instance_scale_mult("pine", bulk["pine"][0], st) == 1.0
		and VegetationGrowth.instance_scale_mult("cedar", bulk["cedar"][0], st) == 1.0)
	st["growth_year"] = t0 + 3.0
	_check("... which is still full size three years on (it used to die within a day)",
		VegetationGrowth.instance_scale_mult("pine", bulk["pine"][0], st) == 1.0)
	_check("a session-young plant restarts as planted today",
		_approx(float(bulk["pine"][1]["born_y"]), t0, 1e-9))
	_check("a half-grown plant keeps its age",
		_approx(float(bulk["pine"][2]["born_y"]), t0 - 23.5, 1e-6))
	st["growth_year"] = t0
	_check("a record with no birth was drawn full size, and still is",
		VegetationGrowth.instance_scale_mult("pine", bulk["pine"][3], st) == 1.0)
	_check("an already-migrated record is left alone",
		float(bulk["pine"][4]["born_y"]) == 1999.0)
	_check("a growth-off species gets no birth year",
		not (bulk["grass_lawn"][0] as Dictionary).has("born_y"))
	_check("migration is idempotent",
		VegetationGrowth.migrate_records(bulk, settings, t0 + 50.0) == 0)


func _mean_and_small(recs: Array, st: Dictionary) -> Vector3:
	var sum := 0.0
	var small := 0
	var full := 0
	for d in recs:
		var h := VegetationGrowth.instance_scale_mult("pine", d, st)
		sum += h
		if h < 0.5:
			small += 1
		if h >= 0.99:
			full += 1
	var n := float(recs.size())
	return Vector3(sum / n, float(small) / n, float(full) / n)


## Generated forest: no stored birth, derived from the position hash.
func _test_forest_profiles() -> void:
	var recs := _grove("pine", 2000)
	var st := {"pine_growth_years": 30.0, "growth_year": 2026.4, "growth_epoch_y": 2026.4}
	var now := _mean_and_small(recs, st)
	_check("mature profile: most of the stand is full size", now.z > 0.6,
		"full frac %f" % now.z)
	_check("mature profile: only a small minority is young", now.y > 0.005 and now.y < 0.06,
		"small frac %f" % now.y)
	_check("mature profile: at least four trees in five are full size", now.z > 0.8,
		"full frac %f" % now.z)
	st["growth_year"] = 2326.4
	var later := _mean_and_small(recs, st)
	_check("mature profile is STATIONARY (same stand in 300 years)",
		_approx(now.x, later.x, 0.03), "mean %f vs %f" % [now.x, later.x])
	st["growth_year"] = 1500.0
	var past := _mean_and_small(recs, st)
	_check("... and 500 years in the past (never a field of seedlings)",
		_approx(now.x, past.x, 0.03), "mean %f vs %f" % [now.x, past.x])
	var deterministic := VegetationGrowth.record_params("pine", recs[7], st) \
		== VegetationGrowth.record_params("pine", recs[7], st)
	_check("derived birth is deterministic", deterministic)
	st["growth_year"] = 2026.4
	st["forest_age"] = "young"
	var young := _mean_and_small(recs, st)
	_check("young profile: a plantation of saplings at the site epoch",
		young.y > 0.99 and young.z == 0.0, "small %f full %f" % [young.y, young.z])
	st["growth_year"] = 2026.4 + 30.0
	_check("young profile: all full size one maturity later",
		_mean_and_small(recs, st).z > 0.99)
	st["growth_year"] = 2026.4
	st["forest_age"] = "mixed"
	var mixed := _mean_and_small(recs, st)
	_check("mixed profile sits between young and mature",
		mixed.x > young.x + 0.1 and mixed.x < now.x - 0.05,
		"young %f mixed %f mature %f" % [young.x, mixed.x, now.x])


func _test_instance_custom() -> void:
	var st := {"pine_growth_years": 47.0, "shrub_growth_years": 5.0,
		"grass_lawn_growth_years": 0.0}
	var d := {"x": 12.0, "z": 34.0, "born_y": 2010.5}
	var c := VegetationGrowth.instance_custom("cedar", d, st)
	_check("custom.r = born - base year", _approx(c.r, 10.5, 1e-4))
	_check("custom.g = maturity (subspecies reads its family's key)", _approx(c.g, 47.0, 1e-4))
	_check("custom.b = jittered catalog lifespan (cedar 500 x 0.7..1.3)",
		c.b >= 350.0 - 1e-3 and c.b <= 650.0 + 1e-3, "got %f" % c.b)
	_check("custom.a = seed", c.a >= 0.0 and c.a < 1.0
		and _approx(c.a, VegGrowthModel.seed01("cedar", 12.0, 34.0), 1e-6))
	var s := VegetationGrowth.instance_custom("shrub", d, st)
	_check("a shrub grows and holds (lifespan 0)", s.b == 0.0 and s.g > 0.0)
	_check("growth off -> all zero (the shader's identity)",
		VegetationGrowth.instance_custom("grass_lawn", d, st) == Color(0, 0, 0, 0))
	st["growth_frozen"] = true
	_check("frozen -> all zero",
		VegetationGrowth.instance_custom("cedar", d, st) == Color(0, 0, 0, 0))
	st.erase("growth_frozen")
	st["pine_lifespan_years"] = 90.0
	var o := VegetationGrowth.instance_custom("pine", d, st)
	_check("an explicit lifespan setting beats the catalog",
		o.b >= 63.0 - 1e-3 and o.b <= 117.0 + 1e-3, "got %f" % o.b)
	# The CPU answer and the numbers handed to the shader describe one plant.
	st["growth_year"] = 2026.0
	var via_custom := VegGrowthModel.state(2026.0, c.r + VegGrowthModel.BASE_YEAR, c.g, c.b, c.a)
	st.erase("pine_lifespan_years")
	_check("instance_custom round-trips to the same state as plant_state",
		_approx(float(via_custom["height"]),
			VegetationGrowth.instance_scale_mult("cedar", d, st), 1e-5))


## veg_growth.gdshaderinc mirrors VegGrowthModel.state(); its constants are
## parsed out of the shader text so the two cannot drift apart silently.
func _test_shader_mirror_constants() -> void:
	var path := "res://vegetation/veg_growth.gdshaderinc"
	var src := FileAccess.get_file_as_string(path)
	_check("shader include exists", not src.is_empty())
	var want := {
		"VG_CR_K": VegGrowthModel.CR_K, "VG_CR_P": VegGrowthModel.CR_P,
		"VG_SEED_HEIGHT": VegGrowthModel.SEED_HEIGHT,
		"VG_CROWN_EXP": VegGrowthModel.CROWN_EXP, "VG_GIRTH_EXP": VegGrowthModel.GIRTH_EXP,
		"VG_OLD_GIRTH": VegGrowthModel.OLD_GIRTH,
		"VG_DECLINE_FRAC": VegGrowthModel.DECLINE_FRAC,
		"VG_LEAF_LOSS_FRAC": VegGrowthModel.LEAF_LOSS_FRAC,
		"VG_COLLAPSE_FRAC": VegGrowthModel.COLLAPSE_FRAC,
		"VG_GAP_MIN_Y": VegGrowthModel.GAP_MIN_Y, "VG_GAP_SPAN_Y": VegGrowthModel.GAP_SPAN_Y,
		"VG_MIN_LIFE_RATIO": VegGrowthModel.MIN_LIFE_MATURITY_RATIO,
		"VG_REGEN_HEAD_START": VegGrowthModel.REGEN_HEAD_START,
	}
	var bad := ""
	for k in want:
		var re := RegEx.new()
		re.compile("const\\s+float\\s+%s\\s*=\\s*([0-9.]+)\\s*;" % k)
		var m := re.search(src)
		if m == null or not _approx(float(m.get_string(1)), float(want[k]), 1e-6):
			bad += " %s" % k
	_check("every shader constant matches the model", bad.is_empty(), "mismatch:%s" % bad)


func _test_settings_with_variant_non_clobber() -> void:
	# Contract: a USER family edit (declared via the style store's
	# _user_family_keys provenance channel) SCALES the variant's SPECS dims —
	# ratio over the family default — so a family-wide tune resizes every
	# subspecies proportionally instead of flattening them into clones. A bare
	# family value with NO provenance is just a default and loses to SPECS —
	# that absent-provenance case is precisely the fix that makes subspecies
	# real (the old absent-KEY test froze the placeholder bug).
	var player := {"pine_height_m": 25.0, "pine_crown_width_m": 10.0,
		VegStyleStore.KEY_USER_FAMILY: ["pine_height_m", "pine_crown_width_m"]}
	var merged := VegSpeciesCatalog.settings_with_variant(
		"spruce", player, VegetationCardFactory.SPECS)
	# SPECS spruce 21 × (user 25 / family default 17); 6 × (10 / 7).
	_check("variant scales by the USER height ratio",
		_approx(float(merged.get("pine_height_m", 0.0)), 21.0 * 25.0 / 17.0, 1e-3),
		"got %s" % str(merged.get("pine_height_m")))
	_check("variant scales by the USER crown ratio",
		_approx(float(merged.get("pine_crown_width_m", 0.0)), 6.0 * 10.0 / 7.0, 1e-3),
		"got %s" % str(merged.get("pine_crown_width_m")))
	_check("variant stamps species id",
		str(merged.get("_variant_species", "")) == "spruce")
	var bare := VegSpeciesCatalog.settings_with_variant(
		"spruce", {"pine_height_m": 25.0}, VegetationCardFactory.SPECS)
	_check("no provenance -> SPECS wins",
		_approx(float(bare.get("pine_height_m", 0.0)), 21.0, 1e-6),
		"got %s" % str(bare.get("pine_height_m")))
	var empty := VegSpeciesCatalog.settings_with_variant(
		"fir", {}, VegetationCardFactory.SPECS)
	_check("variant fills missing height from SPECS",
		float(empty.get("pine_height_m", 0.0)) > 0.0)


func _test_size_var_scales() -> void:
	var identical := VegetationStyleConfig.scales_from_size_var(0.0)
	_check("size var 0 → identical scales",
		_approx(identical.x, 1.0, 1e-6) and _approx(identical.y, 1.0, 1e-6),
		"got %s" % identical)
	var wide := VegetationStyleConfig.scales_from_size_var(0.5)
	_check("size var 50% → 0.5..1.5",
		_approx(wide.x, 0.5, 1e-6) and _approx(wide.y, 1.5, 1e-6),
		"got %s" % wide)
	var mid := VegetationStyleConfig.scales_from_size_var(0.25)
	_check("size var 25% → 0.75..1.25",
		_approx(mid.x, 0.75, 1e-6) and _approx(mid.y, 1.25, 1e-6),
		"got %s" % mid)
